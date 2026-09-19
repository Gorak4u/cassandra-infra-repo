#!/usr/bin/env python3
"""Cross-check listener ports (infra) against the ones Hiera configures.

    infra/inventory/defaults.yaml                 ports: {jenkins_http: 8080}
    infra/inventory/customers/<c>/<env>.yaml       ports: {jenkins_http: 8081}
    data/products/jenkins/environments/<env>.yaml
                                                  profile_jenkins_pfpt::http_port: 8081

WHY THIS EXISTS
---------------
The sibling of bin/check-sizing.py, for the other value that spans both halves
of the estate. infra decides what the firewall opens and what the boot-time
health checks poll; Hiera decides what the service binds. Nothing connects
them, and the failure is the quiet kind:

  profile_cassandra_pfpt::native_transport_port is a Hiera parameter. Set it
  to 9142 for a cluster and the security group still opens 9042. The ring
  forms perfectly -- internode gossip is a different port -- and then nothing
  can connect, while cluster-health.sh reports a healthy ring.

That one is hypothetical. This one is not: products/jenkins/environments/
nonprod.yaml has asked for 8081 since it was written, infra/inventory/
defaults.yaml says 8080, and for most of that time BOTH were right, because
jenkins_pfpt never applied http_port at all and every node listened on the
packaged 8080. Making the parameter work is what turned a dormant
disagreement into a live one.

WHAT THIS SCRIPT DOES NOT DO
----------------------------
It is not a Hiera implementation. It consults the layers where a port
legitimately belongs, narrowest first, and reports "not set" rather than
guessing when it finds nothing -- which is itself worth knowing, because a
port set at a broad layer applies to firewalls that were never opened for it.

Usage:
    check-ports.py                  check every customer and environment
    check-ports.py --verbose        show every pair, not just the mismatches
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: python3 -m pip install pyyaml")

HERE = Path(__file__).resolve().parent
INFRA = HERE.parent
INVENTORY = INFRA / "inventory"
CONTROL_REPO = Path(
    os.environ.get("PUPPET_CONTROL_REPO", INFRA.parent / "cassandra-control-repo")
)

# infra port name -> the Hiera key that must agree with it, per product.
#
# Only ports a SERVICE BINDS belong here. ports.cassandra_internode and
# ports.cassandra_jmx are deliberately absent: the module does not expose them
# as parameters, so there is no second value to disagree with and a check would
# be theatre.
PAIRS = [
    {
        "product": "cassandra",
        "infra_key": "cassandra_cql",
        "hiera_key": "profile_cassandra_pfpt::native_transport_port",
    },
    {
        "product": "jenkins",
        "infra_key": "jenkins_http",
        "hiera_key": "profile_jenkins_pfpt::http_port",
    },
]


def load(path: Path) -> dict:
    if not path.is_file():
        return {}
    with path.open() as fh:
        return yaml.safe_load(fh) or {}


def hiera_port(customer: str, env: str, product: str, key: str):
    """Narrowest layer first, the same order Hiera itself would consult.

    Returns (port, where) or (None, None).
    """
    data = CONTROL_REPO / "data"
    candidates = [
        data / "customers" / customer / env / "products" / product / "common.yaml",
        data / "customers" / customer / "products" / product / "common.yaml",
        data / "products" / product / "environments" / f"{env}.yaml",
        data / "products" / product / "common.yaml",
    ]
    for path in candidates:
        value = load(path).get(key)
        if value is not None:
            return value, str(path.relative_to(CONTROL_REPO))
    return None, None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    if not (CONTROL_REPO / "data").is_dir():
        print(f"check-ports: no control repo data at {CONTROL_REPO}/data", file=sys.stderr)
        return 1

    estate_ports = (load(INVENTORY / "defaults.yaml").get("ports") or {})

    failures: list[str] = []
    warnings: list[str] = []
    checked = 0

    envfiles = sorted((INVENTORY / "customers").glob("*/*.yaml"))
    if not envfiles:
        print(f"check-ports: no inventory files under {INVENTORY}/customers", file=sys.stderr)
        return 1

    for envfile in envfiles:
        env = load(envfile)
        customer, environment = env.get("customer"), env.get("environment")
        if not customer or not environment:
            failures.append(f"{envfile}: missing customer or environment")
            continue

        # The env file's own ports block overrides the estate default, exactly
        # as provision.sh resolves it. Reading only defaults.yaml here would
        # report a false mismatch for every environment that overrides one.
        env_ports = {**estate_ports, **(env.get("ports") or {})}
        declared = env.get("products") or {}

        for pair in PAIRS:
            product = pair["product"]
            if product not in declared:
                continue

            infra_port = env_ports.get(pair["infra_key"])
            infra_where = ("inventory/customers/%s/%s.yaml" % (customer, environment)
                           if pair["infra_key"] in (env.get("ports") or {})
                           else "inventory/defaults.yaml")
            label = f"{customer}/{environment}/{product}"

            if infra_port is None:
                failures.append(
                    f"{label}: inventory has no ports.{pair['infra_key']}, so the firewall "
                    "and the boot-time health check have no number to use"
                )
                continue

            port, where = hiera_port(customer, environment, product, pair["hiera_key"])
            if port is None:
                warnings.append(
                    f"{label}: {pair['hiera_key']} is not set at any product layer -- the "
                    f"module default applies, and nothing records that it is {infra_port}"
                )
                continue

            checked += 1
            ok = int(port) == int(infra_port)

            if args.verbose or not ok:
                verdict = "ok" if ok else "FAIL"
                print(f"  {verdict:6} {label}")
                print(f"           infra {infra_port}  ({infra_where})")
                print(f"           hiera {port}  ({where})")

            if not ok:
                failures.append(
                    f"{label}: infra opens {pair['infra_key']}={infra_port} "
                    f"({infra_where}) but Hiera binds {pair['hiera_key']}={port} ({where}). "
                    "This failure is SILENT: the service starts, every Puppet resource is "
                    "green, and nothing can reach it."
                )

    print()
    for w in warnings:
        print(f"warning: {w}")
    for f in failures:
        print(f"FAIL: {f}")

    print(f"\n{checked} port pair(s) checked, {len(failures)} failure(s), "
          f"{len(warnings)} warning(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
