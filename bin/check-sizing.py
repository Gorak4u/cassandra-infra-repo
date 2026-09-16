#!/usr/bin/env python3
"""Cross-check machine sizing (infra) against JVM heap (Hiera).

    infra/inventory/customers/<c>/<env>.yaml      sizing: small  -> ram_mb 2048
    data/customers/<c>/<env>/products/<p>/clusters/<id>.yaml
                                                  max_heap_size: '640M'

WHY THIS EXISTS
---------------
The two halves of this estate are deliberately separate -- infra creates the
machine, Puppet configures the application -- but sizing is the one value that
spans both and MUST agree. Nothing enforced that, and the failure mode is
silent:

  A Cassandra node with a 640M heap settles at about 1782 MiB RSS. The heap is
  only part of the footprint: off-heap memtables, the file cache, metaspace and
  direct buffers make up the rest. Give it a 1400 MB machine and the kernel
  OOM-kills it in a restart loop -- while Cassandra's own log shows a clean,
  complete startup every time and no Puppet resource fails. The node reports
  success and never serves a query.

That is not hypothetical; it happened while building this lab, and it cost a
full rebuild to diagnose. This script is the check that would have caught it in
CI in under a second.

The model below is ADDITIVE -- a measured fixed overhead plus a modest
allowance -- not a multiplier. See the FOOTPRINT comment for why that
distinction is the correctness of this script rather than a detail.

These are FLOORS, not recommendations: passing means "will probably not be
OOM-killed", not "correctly sized for your workload".

Usage:
    check-sizing.py                 check every customer and environment
    check-sizing.py --verbose       show the arithmetic for each cluster
"""

from __future__ import annotations

import argparse
import re
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
    __import__("os").environ.get("PUPPET_CONTROL_REPO", INFRA.parent / "cassandra-control-repo")
)

# Per-product footprint model.
#
#   required = heap_mb + max(fixed_overhead_mb, heap_mb * variable_fraction)
#
# ADDITIVE, not multiplicative, and that distinction is the whole correctness
# of this script. The first version of it used a flat multiplier derived from
# one measurement -- 640 MiB heap observed at 1782 MiB RSS, so 2.8x -- and
# extrapolated that ratio to every heap size. At a 16 GiB heap it then demanded
# a 41 GiB machine, which is nonsense: most of the non-heap footprint is FIXED,
# not proportional.
#
# Metaspace is a few hundred MB whatever the heap. Cassandra's file cache
# defaults to min(512 MB, heap/4) and is capped. Thread stacks scale with
# concurrency, not heap. So the non-heap cost is a floor plus a modest
# allowance, and the floor is what dominates at small heaps -- which is exactly
# the case that bit this estate.
#
# fixed_overhead_mb is MEASURED on this estate. variable_fraction is an
# engineering allowance, not a measurement, and is documented as such:
#
#   cassandra     640 MiB heap measured at 1782 MiB RSS -> ~1142 MiB non-heap.
#                 1152 is that, rounded. 25% allows for off-heap memtables
#                 growing with data volume on a large node.
#   puppetserver  1 GiB heap measured at ~1430 MiB RSS -> ~400 MiB non-heap.
#                 JRuby interpreters live INSIDE the heap, so there is little
#                 else; the module carries its own separate warning for
#                 instances-vs-heap.
#
#                 CAVEAT, measured later: the JVM's own RSS is not the whole
#                 story on a CONTAINER. pm1 showed puppetserver at 1086 MiB
#                 with -Xmx1g while the container sat at ~1.6 GiB and was
#                 OOM-killed at a 2048 MiB limit -- the agent, systemd and
#                 page cache all count against the cgroup. This model predicts
#                 1536 MiB and PASSED that cluster. It is a floor for the
#                 PROCESS, not a container budget; inventory local_mem for
#                 'medium' was raised to 3072m as a result.
#
# These are FLOORS. Passing means "will probably not be OOM-killed", not
# "correctly sized for your workload".
FOOTPRINT = {
    "cassandra": {
        "key": "profile_cassandra_pfpt::max_heap_size",
        "fixed_overhead_mb": 1152,
        "variable_fraction": 0.25,
        "note": "off-heap memtables, file cache, metaspace, direct buffers",
    },
    "puppetmaster": {
        "key": "profile_puppetmaster_pfpt::java_heap",
        "fixed_overhead_mb": 512,
        "variable_fraction": 0.15,
        "note": "JRuby interpreters live inside the heap; JVM overhead only",
    },
    # MEASURED, after a node was OOM-killed at 2048 MB.
    #
    #   container limit 2048 MB, 61 plugins, no explicit -Xmx
    #   -> OOMKilled=true, status=9/KILL, after a clean Puppet run
    #
    # The immediate cause was the JVM sizing its own heap at a quarter of the
    # HOST's memory rather than the container's -- MaxHeapSize came out at
    # 2988 MB inside a 2048 MB cgroup -- so the first fix is an explicit heap,
    # which profile_jenkins_pfpt::java_heap now supplies. This model is the
    # second half: making the machine big enough for that heap plus everything
    # around it.
    #
    # At idle with a 1g heap the process sits at ~456 MB RSS, which says
    # nothing useful about the ceiling. 768 is the allowance for what a
    # ~60-plugin Jenkins holds OUTSIDE the heap: metaspace is the big one (a
    # plugin is a jar full of classes and each is loaded), plus code cache,
    # one thread stack per executor and per HTTP worker, and Jetty's direct
    # buffers.
    #
    # Honest about its provenance: fixed_overhead_mb is derived from ONE
    # OOM-killed node and one idle measurement, not from a loaded server. It
    # is a floor, and a Jenkins that actually builds things wants more.
    "jenkins": {
        "key": "profile_jenkins_pfpt::java_heap",
        "fixed_overhead_mb": 768,
        "variable_fraction": 0.25,
        "note": "metaspace for ~60 plugins, code cache, executor stacks, Jetty buffers",
    },
}


def parse_mb(value: str) -> int | None:
    """'640M' -> 640, '1g' -> 1024. None if it is not a JVM size."""
    if not isinstance(value, str):
        return None
    m = re.fullmatch(r"\s*(\d+)\s*([kKmMgG])?\s*", value)
    if not m:
        return None
    n = int(m.group(1))
    unit = (m.group(2) or "M").lower()
    return {"k": n // 1024, "m": n, "g": n * 1024}[unit]


def load(path: Path) -> dict:
    if not path.is_file():
        return {}
    with path.open() as fh:
        return yaml.safe_load(fh) or {}


def find_heap(customer: str, env: str, product: str, cluster: str, key: str):
    """Look for the heap at the cluster layer, then the customer+product layer.

    Returns (heap_mb, where). Only the two layers where sizing legitimately
    belongs are consulted -- this is not a Hiera reimplementation, and it does
    not try to be. A value set somewhere else is reported as not found, which
    is itself worth knowing: sizing set at a broad layer applies to machines it
    was never measured against.
    """
    data = CONTROL_REPO / "data"
    # In Hiera precedence order, narrowest first -- the same order Hiera
    # itself would consult these layers, so the value found here is the value
    # a catalogue would get.
    candidates = [
        data / "customers" / customer / env / "products" / product / "clusters" / f"{cluster}.yaml",
        data / "customers" / customer / env / "products" / product / "common.yaml",
        data / "customers" / customer / "products" / product / "common.yaml",
        data / "products" / product / "environments" / f"{env}.yaml",
        data / "products" / product / "common.yaml",
    ]
    for path in candidates:
        value = load(path).get(key)
        if value is not None:
            mb = parse_mb(value)
            rel = path.relative_to(CONTROL_REPO)
            return mb, str(rel)
    return None, None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    if not (CONTROL_REPO / "data").is_dir():
        print(f"check-sizing: no control repo data at {CONTROL_REPO}/data", file=sys.stderr)
        return 1

    defaults = load(INVENTORY / "defaults.yaml")
    sizing_table = defaults.get("sizing") or {}

    # The one slice the local driver actually builds. The local_mem check below
    # is scoped to it on purpose: every prod cluster in the estate has a
    # local_mem far below its cloud ram_mb, and warning about all of them would
    # be nine lines of noise about machines nobody will ever build on a laptop.
    # A check that cries wolf is a check people learn to skip.
    slice_ = defaults.get("local_slice") or {}
    local_slice = (slice_.get("customer"), slice_.get("environment"))

    failures: list[str] = []
    warnings: list[str] = []
    skipped: list[str] = []
    checked = 0

    envfiles = sorted((INVENTORY / "customers").glob("*/*.yaml"))
    if not envfiles:
        print(f"check-sizing: no inventory files under {INVENTORY}/customers", file=sys.stderr)
        return 1

    for envfile in envfiles:
        env = load(envfile)
        customer, environment = env.get("customer"), env.get("environment")
        if not customer or not environment:
            failures.append(f"{envfile}: missing customer or environment")
            continue

        for product, pspec in (env.get("products") or {}).items():
            model = FOOTPRINT.get(product)
            for cluster, cspec in ((pspec or {}).get("clusters") or {}).items():
                cspec = cspec or {}
                shape = sizing_table.get(cspec.get("sizing")) or {}
                ram_mb = shape.get("ram_mb")
                label = f"{customer}/{environment}/{product}/{cluster}"

                if model is None:
                    # Recorded, not just skipped under --verbose.
                    #
                    # A product with no footprint model is UNCHECKED, and an
                    # unchecked cluster that says nothing looks exactly like a
                    # checked one that passed. The jenkins/ci cluster was
                    # invisible this way: the summary said "11 clusters
                    # checked, 0 failures" both before and after it was added.
                    #
                    # No model is invented for a product whose footprint has
                    # not been MEASURED -- a guessed fixed_overhead_mb would
                    # turn this check from evidence into decoration. See the
                    # measurement note at the top of this file.
                    skipped.append(f"{label}: no footprint model for product '{product}'")
                    if args.verbose:
                        print(f"  skip   {label}: no footprint model for product '{product}'")
                    continue
                if not ram_mb:
                    failures.append(f"{label}: sizing '{cspec.get('sizing')}' has no ram_mb")
                    continue

                heap_mb, where = find_heap(customer, environment, product, cluster, model["key"])
                if heap_mb is None:
                    warnings.append(
                        f"{label}: {model['key']} not set at the cluster or customer+product "
                        "layer -- sizing is being inherited from a broader layer that was not "
                        "measured against this machine shape"
                    )
                    continue

                overhead = max(model["fixed_overhead_mb"],
                               int(heap_mb * model["variable_fraction"]))
                required = heap_mb + overhead
                checked += 1
                ok = ram_mb >= required

                if args.verbose or not ok:
                    verdict = "ok" if ok else "FAIL"
                    print(f"  {verdict:6} {label}")
                    print(f"           heap {heap_mb} MB  ({where})")
                    print(f"           + {overhead} MB non-heap = {required} MB required"
                          f"   [{model['note']}]")
                    print(f"           machine {ram_mb} MB ({cspec.get('sizing')})")

                # THE LOCAL DRIVER USES A DIFFERENT NUMBER, and that is how a
                # cluster passes this check and is still OOM-killed.
                #
                # ram_mb is the cloud machine's memory and what everything
                # above validates. provision.sh gives the container local_mem,
                # because a laptop cannot honour 8 or 16 GiB per container. For
                # 'small' they are both 2048 and the difference has never
                # mattered; for every larger shape they differ by 4x or more,
                # and the local container is the smaller one.
                #
                # Reported as a WARNING rather than a failure: an estate that
                # only ever deploys to a cloud is not wrong to have them
                # diverge. It is only wrong if you then build that cluster
                # locally -- which is exactly what happened to jenkins/ci.
                local_mb = parse_mb(shape.get("local_mem") or "")
                if ((customer, environment) == local_slice
                        and local_mb is not None and local_mb < required):
                    failures.append(
                        f"{label}: sizing '{cspec.get('sizing')}' is {ram_mb} MB in the cloud "
                        f"but local_mem is only {local_mb} MB, and a {heap_mb} MB heap needs "
                        f"~{required} MB. This is the LOCAL SLICE (inventory/defaults.yaml), "
                        "so provision.sh will build it at that size and the kernel will "
                        "OOM-kill it after a clean-looking startup."
                    )

                if not ok:
                    failures.append(
                        f"{label}: machine has {ram_mb} MB but a {heap_mb} MB heap needs "
                        f"~{required} MB. Raise 'sizing' in {envfile.relative_to(INFRA)} or lower "
                        f"{model['key']} in {where}. This failure is SILENT at runtime: the "
                        "process is OOM-killed after a clean-looking startup and no Puppet "
                        "resource fails."
                    )

    print()
    for w in warnings:
        print(f"warning: {w}")
    for f in failures:
        print(f"FAIL: {f}")
    for s_ in skipped:
        print(f"unchecked: {s_}")

    print(f"\n{checked} cluster(s) checked, {len(failures)} failure(s), "
          f"{len(warnings)} warning(s), {len(skipped)} unchecked")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
