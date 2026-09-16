#!/usr/bin/env python3
"""Expand the per-customer infra inventory into a flat node table.

    infra/inventory/defaults.yaml                    shared defaults
    infra/inventory/customers/<customer>/<env>.yaml  one file per tenant+env
                          |
                          |  this script
                          v
    a flat, 12-column table that provision.sh parses directly

WHY A GENERATOR
---------------
The flat table used to be hand-maintained, one line per node with eleven
columns, and customer / environment / datacentre / os repeated on every line.
That is tolerable at four nodes and unusable at a hundred: growing a cluster
meant a hundred near-identical lines, a hundred hand-picked addresses, and a
hand-written join chain ninety-nine links long.

Here, growing a cluster is `count:`. Everything else -- names, addresses, seed
roles, racks, join ordering -- is derived, and the derivation is checked.

WHY IT EMITS THE OLD FORMAT
---------------------------
provision.sh's parser is unchanged. The generator slots in underneath it, so
the part that actually creates machines carries no new risk. Terraform reads
the YAML directly instead and never sees this output.

Usage:
    expand-inventory.py                          every customer and environment
    expand-inventory.py --customer amex          one customer
    expand-inventory.py --customer amex --environment nonprod
    expand-inventory.py --limit 3                first N nodes per cluster
    expand-inventory.py --format yaml            structured, for inspection
"""

from __future__ import annotations

import argparse
import ipaddress
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: python3 -m pip install pyyaml")

HERE = Path(__file__).resolve().parent
INVENTORY = HERE.parent / "inventory"

# The column order provision.sh parses. Changing it means changing the `read`
# in read_inventory() too -- they are one contract, so they are stated here
# rather than left implicit.
COLUMNS = [
    "certname", "ip", "os", "role", "product", "cluster",
    "customer", "environment", "datacenter", "rack", "wait_for", "mem",
    "puppet_server",
]


class InventoryError(Exception):
    """A problem with the inventory itself, reported without a traceback."""


def load_yaml(path: Path) -> dict:
    try:
        with path.open() as fh:
            return yaml.safe_load(fh) or {}
    except yaml.YAMLError as exc:
        raise InventoryError(f"{path}: invalid YAML: {exc}") from exc
    except OSError as exc:
        raise InventoryError(f"{path}: {exc.strerror}") from exc


def environment_files(customer: str | None, environment: str | None) -> list[Path]:
    root = INVENTORY / "customers"
    if not root.is_dir():
        raise InventoryError(f"{root} does not exist")

    customers = [root / customer] if customer else sorted(p for p in root.iterdir() if p.is_dir())
    for c in customers:
        if not c.is_dir():
            raise InventoryError(f"no such customer: {c.name} (looked in {root})")

    files: list[Path] = []
    for c in customers:
        envs = [c / f"{environment}.yaml"] if environment else sorted(c.glob("*.yaml"))
        for e in envs:
            if not e.is_file():
                raise InventoryError(f"no such environment file: {e}")
            files.append(e)

    if not files:
        raise InventoryError("the inventory declares no customer/environment files")
    return files


def expand(defaults: dict, envfile: Path, limit: int | None) -> list[dict]:
    """Expand one customer/environment file into node records."""
    env = load_yaml(envfile)
    where = envfile.relative_to(INVENTORY.parent)

    for key in ("customer", "environment", "datacenter"):
        if not env.get(key):
            raise InventoryError(f"{where}: missing required key '{key}'")

    domain = env.get("domain", defaults.get("domain"))
    if not domain:
        raise InventoryError(f"{where}: no domain, and no default")

    sizing_table = defaults.get("sizing") or {}
    default_os = env.get("os", defaults.get("os"))
    serialize_default = defaults.get("serialize_by_default", True)

    # Addresses are only meaningful for the local driver; a cloud assigns them.
    # Absent subnet simply means every ip comes out as '-'.
    subnet = env.get("subnet")
    hosts: list[str] = []
    if subnet:
        try:
            hosts = [str(h) for h in ipaddress.ip_network(subnet, strict=True).hosts()]
        except ValueError as exc:
            raise InventoryError(f"{where}: bad subnet {subnet!r}: {exc}") from exc

    nodes: list[dict] = []

    products = env.get("products") or {}
    if not products:
        raise InventoryError(f"{where}: declares no products")

    # Master resolution, broad layers only -- the narrow ones (cluster,
    # datacentre) are resolved by opt() inside _expand_dc(). Unset stays None
    # and is filled in by _resolve_puppet_servers() once every node is known,
    # because the implicit answer is "the puppetmaster in this expansion" and
    # that cannot be known until the expansion exists.
    ps_estate = (defaults.get("puppet") or {}).get("server")
    ps_env = env.get("puppet_server", ps_estate)

    for product, pspec in products.items():
        pspec = pspec or {}
        clusters = pspec.get("clusters") or {}
        if not clusters:
            raise InventoryError(f"{where}: product '{product}' declares no clusters")

        # THE PER-PRODUCT LAYER: one customer's cassandra fleet on one master
        # and its jenkins fleet on another. Stated once for the product rather
        # than repeated in every cluster underneath it.
        ps_product = pspec.get("puppet_server", ps_env)

        for cluster, cspec in clusters.items():
            cspec = cspec or {}

            # A cluster may either be single-DC (count/seed_count/ip_offset at
            # the cluster level, using the file's `datacenter`) or span several
            # datacentres via a `datacenters:` block.
            #
            # The multi-DC shape mirrors the Hiera layout exactly --
            #   clusters/<id>.yaml          cluster-wide
            #   clusters/<id>/<dc>.yaml     one datacentre of it
            # -- so the same mental model covers both sides of the estate.
            #
            # Single-DC is expressed as a one-entry datacentres block, so
            # there is ONE code path below rather than two that drift.
            dc_block = cspec.get("datacenters")
            if dc_block:
                for k in ("count", "seed_count", "ip_offset"):
                    if k in cspec:
                        raise InventoryError(
                            f"{where}: {product}/{cluster}: '{k}' is per-datacentre when a "
                            "'datacenters:' block is present -- move it inside the datacentre"
                        )
                dc_specs = {dc: (spec or {}) for dc, spec in dc_block.items()}
            else:
                dc_specs = {env["datacenter"]: cspec}

            for dc_name, dcspec in dc_specs.items():
                nodes.extend(_expand_dc(
                    where=where, env=env, defaults=defaults, sizing_table=sizing_table,
                    product=product, cluster=cluster, cluster_spec=cspec,
                    dc_name=dc_name, dcspec=dcspec, default_os=default_os, domain=domain,
                    serialize_default=serialize_default, subnet=subnet, hosts=hosts,
                    limit=limit, puppet_server_default=ps_product,
                ))

    _chain_by_cluster(nodes)
    return nodes


def _expand_dc(*, where, env, defaults, sizing_table, product, cluster, cluster_spec,
               dc_name, dcspec, default_os, domain, serialize_default, subnet, hosts, limit,
               puppet_server_default=None):
    """Expand one datacentre's worth of one cluster.

    Values are looked up in the datacentre spec first, then the cluster spec --
    so `sizing` and `serialize` can be stated once for the whole cluster while
    `count`, `ip_offset` and `racks` differ per datacentre. That is almost
    always what you want: a cluster is one machine shape spread across sites.
    """
    def opt(key, default=None):
        if key in dcspec:
            return dcspec[key]
        if key in cluster_spec:
            return cluster_spec[key]
        return default

    nodes: list[dict] = []
    label = f"{product}/{cluster}/{dc_name}"

    count = opt("count")
    if not isinstance(count, int) or count < 1:
        raise InventoryError(
            f"{where}: {label}: count must be a positive integer, got {count!r}"
        )

    effective = min(count, limit) if limit else count

    sizing_name = opt("sizing")
    if sizing_name not in sizing_table:
        raise InventoryError(
            f"{where}: {label}: unknown sizing {sizing_name!r}; "
            f"defaults.yaml defines {sorted(sizing_table) or 'none'}"
        )
    mem = sizing_table[sizing_name].get("local_mem") or "-"

    node_os = opt("os", default_os)
    if not node_os:
        raise InventoryError(f"{where}: {label}: no os, and no default")

    # Name prefix. Explicit wins; otherwise the cluster name, which is
    # right for a singleton like 'pm' and wrong for nothing in
    # particular -- but be explicit for anything long-lived, because
    # renaming means reissuing every certificate in the cluster.
    prefix = opt("name_prefix", cluster)

    # Roles. A product with a seed concept splits the first
    # seed_count nodes off; anything else takes one role for all.
    seed_count = opt("seed_count", 0)
    role = opt("role")
    if role is None and seed_count == 0:
        raise InventoryError(
            f"{where}: {label}: needs either 'role' or 'seed_count'"
        )
    if seed_count and seed_count >= count:
        raise InventoryError(
            f"{where}: {label}: seed_count {seed_count} must be fewer than "
            f"count {count} -- a ring where every node is a seed can come up as several "
            "independent one-node clusters"
        )

    racks = opt("racks") or ["rack1"]
    serialize = opt("serialize", serialize_default)

    # Narrowest two layers of master resolution. A datacentre-level value is
    # how a regional compile master gets expressed: one cluster, one control
    # repo, a nearer master per site.
    puppet_server = opt("puppet_server", puppet_server_default)

    offset = opt("ip_offset")
    if subnet and offset is None:
        raise InventoryError(
            f"{where}: {label}: subnet is set, so ip_offset is required"
        )

    previous: str = "-"
    for i in range(1, effective + 1):
        certname = f"{prefix}{i}.{domain}"

        if subnet:
            # hosts[] is zero-based and starts at .1, so an ip_offset of
            # 11 means .11 -- which is what a reader expects.
            index = offset + i - 2
            if index < 0 or index >= len(hosts):
                raise InventoryError(
                    f"{where}: {label}: node {i} falls outside {subnet} "
                    f"(ip_offset {offset}); the subnet holds {len(hosts)} addresses"
                )
            ip = hosts[index]
        else:
            ip = "-"

        if seed_count:
            node_role = f"{product}_seed" if i <= seed_count else f"{product}_node"
        else:
            node_role = role

        nodes.append({
            "certname": certname,
            "ip": ip,
            "os": node_os,
            "role": node_role,
            "product": product,
            "cluster": cluster,
            "customer": env["customer"],
            "environment": env["environment"],
            "datacenter": dc_name,
            "rack": racks[(i - 1) % len(racks)],
            # A linear chain, which is correct for a handful of nodes
            # and wrong at scale -- 100 nodes is a 7-hour serial build
            # and one dead node wedges the rest. Cloud deployments
            # should use a lock with a TTL instead.
            #
            # Set per-DATACENTRE here and then RE-LINKED ACROSS THE WHOLE
            # CLUSTER by _chain_by_cluster(). See that function for why.
            "wait_for": previous if serialize else "-",
            "mem": mem,
            # "-" means "nothing stated at any layer". Filled in by
            # _resolve_puppet_servers() from the expansion's own master.
            "puppet_server": puppet_server or "-",
            # Internal: not in COLUMNS, so it never reaches the table.
            "_serialize": serialize,
        })
        previous = certname

    return nodes


def _chain_by_cluster(nodes: list[dict]) -> None:
    """Re-link wait_for so the chain spans a cluster's DATACENTRES, not just
    each one separately.

    WHY THIS EXISTS -- a real failure, from a from-scratch multi-DC build:

        java.lang.UnsupportedOperationException: Other bootstrapping/leaving/
        moving nodes detected, cannot bootstrap while
        cassandra.consistent.rangemovement is true.
        Nodes detected, bootstrapping: /172.30.30.12:7000

    _expand_dc() keeps `previous` in its own scope, so every datacentre began
    a fresh chain: dc_east ran cass1 -> cass2 while dc_west ran
    cass-west1 -> cass-west2, in parallel. But Cassandra's refusal to
    bootstrap concurrently is CLUSTER-WIDE, not per-datacentre. cass-west2
    started joining while cass2 was still joining, and Cassandra killed it.

    It stayed hidden for a long time because dc_west was previously added to
    an ALREADY-BUILT dc_east -- sequential by circumstance. Only a build of
    both datacentres at once races, which is exactly what `provision.sh up`
    does.

    NOT NEEDED BY TERRAFORM, and worth knowing why: there, one datacentre is
    one stack with its own state, so the chain cannot span them anyway. The
    equivalent guarantee is operational -- do not apply two datacentre stacks
    concurrently. Guide 06 states that ordering.

    Nodes with serialize off keep wait_for "-" and are skipped entirely, so
    they neither wait nor are waited on.
    """
    last: dict[tuple, str] = {}
    for n in nodes:
        if not n.get("_serialize"):
            continue
        key = (n["customer"], n["environment"], n["product"], n["cluster"])
        n["wait_for"] = last.get(key, "-")
        last[key] = n["certname"]


def _resolve_puppet_servers(nodes: list[dict]) -> None:
    """Fill in every node whose master no layer stated.

    Runs after the whole expansion, because the implicit answer is "a
    puppetmaster in this expansion" and that is not knowable earlier.

    SCOPE OF THE IMPLICIT FALLBACK
    ------------------------------
    Narrowest first, and deliberately NOT the whole expansion:

      1. a master in the same customer+environment
      2. failing that, a master in the same CUSTOMER

    Step 2 exists for acme/staging, which has no master of its own and is
    served by acme/prod's -- stated in that file.

    A whole-expansion fallback looks simpler and is wrong: an unfiltered run
    covers every customer, so "the master" would mean amex/nonprod's master
    for globex's nodes. It only ever appeared to work because a filtered slice
    happened to contain exactly one. Widening past the customer is never
    right -- masters are a tenancy boundary.

    WHY THE AMBIGUOUS CASE IS AN ERROR
    ----------------------------------
    Before this existed, provision.sh simply refused an inventory with two
    masters. Allowing several means the question "which one?" now has to be
    answered for every node, and guessing is the one option that must not be
    taken: a node pointed at the wrong master is signed by the wrong CA and
    gets a catalogue from the wrong control repo. If it is signed at all it
    converges -- to the wrong configuration, with a clean green run. So an
    expansion with more than one master must state the mapping.
    """
    masters = [n for n in nodes if n["role"] == "puppetmaster"]
    errors: list[str] = []

    for n in nodes:
        if n["puppet_server"] != "-":
            continue

        # A master runs an agent against its OWN catalogue, so it is its own
        # server regardless of how many others exist.
        if n["role"] == "puppetmaster":
            n["puppet_server"] = n["certname"]
            continue

        in_env = sorted(
            m["certname"] for m in masters
            if (m["customer"], m["environment"]) == (n["customer"], n["environment"])
        )
        in_customer = sorted(
            m["certname"] for m in masters if m["customer"] == n["customer"]
        )
        candidates, scope = (
            (in_env, f"{n['customer']}/{n['environment']}") if in_env
            else (in_customer, f"customer {n['customer']}")
        )

        if len(candidates) == 1:
            n["puppet_server"] = candidates[0]
        elif not candidates:
            errors.append(
                f"{n['certname']}: no puppet_server at any layer, and no node with role "
                f"'puppetmaster' in customer {n['customer']} to fall back to -- either "
                "include the master in the slice, or state puppet_server (see the "
                "precedence list in inventory/defaults.yaml)"
            )
        else:
            errors.append(
                f"{n['certname']}: no puppet_server at any layer, and {scope} has "
                f"{len(candidates)} masters ({', '.join(candidates)}) -- which one is "
                "ambiguous, so state it on the product, cluster or datacentre"
            )

    # A stated name that IS in this expansion but is not a master is always a
    # mistake -- a typo'd or stale certname. A stated name that is absent is
    # not checked: acme/staging legitimately points at acme/prod's master, and
    # in the cloud the value is usually a load-balancer record that is not an
    # inventory node at all.
    by_certname = {n["certname"]: n for n in nodes}
    for n in nodes:
        target = by_certname.get(n["puppet_server"])
        if target is not None and target["role"] != "puppetmaster":
            errors.append(
                f"{n['certname']}: puppet_server {n['puppet_server']} is a node in this "
                f"expansion with role '{target['role']}', not 'puppetmaster'"
            )

    if errors:
        raise InventoryError("inventory is invalid:\n  - " + "\n  - ".join(errors))


def validate(nodes: list[dict]) -> None:
    """Catch the mistakes that are silent rather than loud."""
    seen_names: dict[str, str] = {}
    seen_ips: dict[str, str] = {}
    errors: list[str] = []

    for n in nodes:
        # Two nodes with one certname is the worst of these: the second node's
        # CSR collides with the first node's certificate and it cannot
        # register at all.
        if n["certname"] in seen_names:
            errors.append(
                f"duplicate certname {n['certname']}: "
                f"{seen_names[n['certname']]} and {n['customer']}/{n['environment']}"
            )
        seen_names[n["certname"]] = f"{n['customer']}/{n['environment']}"

        if n["ip"] != "-":
            if n["ip"] in seen_ips:
                errors.append(
                    f"duplicate address {n['ip']}: {seen_ips[n['ip']]} and {n['certname']} "
                    "-- check the ip_offset ranges do not overlap"
                )
            seen_ips[n["ip"]] = n["certname"]

    # A wait_for pointing at a node that is not being created would block that
    # node until its timeout, which looks like a hung build.
    names = set(seen_names)
    for n in nodes:
        if n["wait_for"] != "-" and n["wait_for"] not in names:
            errors.append(
                f"{n['certname']} waits for {n['wait_for']}, which is not in this expansion "
                "(a --limit that cut the chain, or a typo)"
            )

    # "This expansion has no master" used to be checked here, unconditionally.
    # It now belongs to _resolve_puppet_servers(), which only complains about
    # the nodes that actually NEED the implicit fallback -- so a slice whose
    # nodes all name their master explicitly is valid without one, which is
    # exactly the acme/staging case.

    if errors:
        raise InventoryError("inventory is invalid:\n  - " + "\n  - ".join(errors))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--customer")
    ap.add_argument("--environment")
    ap.add_argument("--limit", type=int,
                    help="take at most N nodes per cluster -- lets a laptop run a slice "
                         "of an inventory that describes hundreds")
    ap.add_argument("--format", choices=("table", "yaml"), default="table")
    args = ap.parse_args()

    try:
        defaults = load_yaml(INVENTORY / "defaults.yaml")
        nodes: list[dict] = []
        for f in environment_files(args.customer, args.environment):
            nodes.extend(expand(defaults, f, args.limit))
        # After the loop, deliberately: the implicit master is "the
        # puppetmaster in this expansion", and an expansion can span several
        # environment files -- acme/staging has no master of its own and is
        # served by acme/prod's.
        _resolve_puppet_servers(nodes)
        validate(nodes)
    except InventoryError as exc:
        print(f"expand-inventory: {exc}", file=sys.stderr)
        return 1

    if args.format == "yaml":
        yaml.safe_dump(nodes, sys.stdout, default_flow_style=False, sort_keys=False)
        return 0

    # Whitespace-aligned so the generated file is as readable as the
    # hand-written one it replaces -- this output is what an operator looks at
    # when something is wrong.
    widths = {c: max(len(c), max((len(str(n[c])) for n in nodes), default=0)) for c in COLUMNS}
    print("# GENERATED by infra/bin/expand-inventory.py -- do not edit.")
    print("# Source: infra/inventory/. Regenerate rather than patching this.")
    print("#")
    print("# " + "  ".join(c.ljust(widths[c]) for c in COLUMNS).rstrip())
    for n in nodes:
        print("  " + "  ".join(str(n[c]).ljust(widths[c]) for c in COLUMNS).rstrip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
