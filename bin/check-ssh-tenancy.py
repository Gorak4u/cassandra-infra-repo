#!/usr/bin/env python3
"""Check that Jenkins' SSH reach into the Cassandra fleet respects tenancy.

    data/customers/<c>/<env>/products/cassandra/clusters/<id>.yaml
        profile_cassy_access_pfpt::authorized_keys: ['ssh-ed25519 AAAA... cassy@...']
    data/secrets/customers/<c>/<env>/jenkins.eyaml
        profile_jenkins_pfpt::ssh_private_key: ENC[PKCS7,...]

WHY THIS EXISTS
---------------
Everything else in this estate keys on `trusted.extensions.pp_*`, which comes
from a certificate the Puppet CA signed against an allowlist. That is a real
boundary: a node cannot read another tenancy's Hiera, because it cannot get a
certificate asserting another tenancy's extensions.

Jenkins' access to the Cassandra fleet does NOT run through that boundary, and
this is the one place in the estate where it does not. The CA decides which
node RECEIVES the cassy private key -- that part is certificate-enforced, since
the key lives in a tenancy-scoped .eyaml. But once Jenkins holds it, the
Cassandra node's sshd authenticates the KEY, not the certificate. Nothing on
the Cassandra side asks which tenancy the connection came from.

So the thing that stops customer A's Jenkins reaching customer B's nodes is
simply that A and B were given different keys. That is a property of these
YAML files, not something the CA can enforce -- and a copy-paste of one
`authorized_keys` line into a second tenancy would silently grant exactly the
cross-tenancy access the rest of the design works to prevent. No Puppet run
would fail. No certificate would be refused. Nothing would look wrong.

This script is that missing check, in the same family as check-sizing.py and
check-ports.py: an invariant that spans both repos, that nothing enforces at
runtime, and whose violation is silent.

WHAT IT CHECKS
--------------
  1. No SSH public key is granted access in more than one tenancy.
  2. Every tenancy that grants access has its own jenkins secrets file, so the
     key it grants is provisioned from its own eyaml rather than borrowed.
  3. No granted key is still a plaintext-committed demo key.

Needs the control repo checked out alongside this one. Honours
PUPPET_CONTROL_REPO; defaults to ../cassandra-control-repo.

Usage:
    check-ssh-tenancy.py            report violations only
    check-ssh-tenancy.py --verbose  show every grant, violation or not
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
INFRA = HERE.parent
CONTROL = Path(
    os.environ.get("PUPPET_CONTROL_REPO", INFRA.parent / "cassandra-control-repo")
).resolve()

AUTHORIZED_KEYS = "profile_cassy_access_pfpt::authorized_keys"
SSH_PRIVATE_KEY = "profile_jenkins_pfpt::ssh_private_key"

# 'ssh-ed25519 AAAAC3Nza... comment' -- the middle field is the key itself and
# the only part that matters for identity. Comments differ freely; two entries
# with the same base64 are the same credential however they are labelled.
KEY_RE = re.compile(r"\b(ssh-[a-z0-9-]+|ecdsa-[a-z0-9-]+)\s+([A-Za-z0-9+/=]{40,})")


def load(path: Path) -> dict:
    try:
        with path.open() as fh:
            return yaml.safe_load(fh) or {}
    except (OSError, yaml.YAMLError) as exc:
        print(f"  ! could not read {path}: {exc}", file=sys.stderr)
        return {}


def key_id(entry: str) -> str | None:
    """The base64 body of an SSH public key, or None if this is not one."""
    m = KEY_RE.search(entry)
    return m.group(2) if m else None


def grants() -> list[tuple[str, str, Path, str]]:
    """Every (customer, environment, file, key entry) that grants cassy access."""
    found = []
    root = CONTROL / "data" / "customers"
    for path in sorted(root.rglob("*.yaml")):
        data = load(path)
        entries = data.get(AUTHORIZED_KEYS)
        if not entries:
            continue
        # data/customers/<customer>/<environment>/...
        rel = path.relative_to(root).parts
        customer = rel[0]
        environment = rel[1] if len(rel) > 2 else "(customer-wide)"
        for entry in entries:
            found.append((customer, environment, path, entry))
    return found


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--verbose", action="store_true", help="show every grant, not just violations")
    args = ap.parse_args()

    if not (CONTROL / "data").is_dir():
        print(f"FAIL: no control repo at {CONTROL}", file=sys.stderr)
        print("      set PUPPET_CONTROL_REPO, or check it out beside this repo.", file=sys.stderr)
        return 2

    all_grants = grants()
    if not all_grants:
        print("no cassy SSH grants found; nothing to check")
        return 0

    problems = 0
    seen: dict[str, list[tuple[str, str, Path]]] = {}

    for customer, environment, path, entry in all_grants:
        kid = key_id(entry)
        if kid is None:
            print(f"FAIL {customer}/{environment}: not an SSH public key: {entry[:60]}...")
            problems += 1
            continue

        seen.setdefault(kid, []).append((customer, environment, path))

        if args.verbose:
            rel = path.relative_to(CONTROL)
            print(f"  {customer}/{environment}: {kid[:20]}... in {rel}")

        # 3. A key still labelled as a committed demo key is not a credential,
        #    it is a published one.
        if re.search(r"LAB KEY|not a secret|example|changeme", entry, re.IGNORECASE):
            print(f"FAIL {customer}/{environment}: grants a key labelled as a demo/lab key: {entry[:70]}")
            print("     A key with sudo on every Cassandra node is a real credential.")
            problems += 1

        # 2. The tenancy granting access must provision the key from its own
        #    eyaml, not rely on one that belongs to someone else.
        secrets = CONTROL / "data" / "secrets" / "customers" / customer / environment / "jenkins.eyaml"
        if environment != "(customer-wide)" and not secrets.is_file():
            print(f"FAIL {customer}/{environment}: grants cassy access but has no {secrets.relative_to(CONTROL)}")
            print("     The key it admits is provisioned from some other tenancy's secrets.")
            problems += 1
        elif secrets.is_file() and SSH_PRIVATE_KEY not in load(secrets):
            print(f"FAIL {customer}/{environment}: {secrets.relative_to(CONTROL)} sets no {SSH_PRIVATE_KEY}")
            problems += 1

    # 1. The one the CA cannot enforce: a key admitted by two tenancies.
    for kid, where in seen.items():
        tenancies = {(c, e) for c, e, _ in where}
        if len(tenancies) > 1:
            print(f"FAIL one key is admitted by {len(tenancies)} tenancies: {kid[:20]}...")
            for customer, environment, path in where:
                print(f"     {customer}/{environment}  {path.relative_to(CONTROL)}")
            print("     Whoever holds it can reach every one of them. The Puppet CA")
            print("     cannot stop this: sshd authenticates the key, not the certificate.")
            problems += 1

    tenancy_count = len({(c, e) for c, e, _, _ in all_grants})
    if problems:
        print(f"\n{problems} problem(s) across {len(all_grants)} grant(s) in {tenancy_count} tenancy/ies")
        return 1

    print(f"OK: {len(all_grants)} cassy grant(s) across {tenancy_count} tenancy/ies, no key shared between them")
    return 0


if __name__ == "__main__":
    sys.exit(main())
