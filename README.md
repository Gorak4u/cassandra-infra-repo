# `infra/` — the provisioning layer

This directory creates **raw machines**. It installs nothing on them.

That separation is the whole point, so it is worth stating plainly:

| | `infra/` (this directory) | `../cassandra-control-repo/` |
|---|---|---|
| Answers | *what machines exist* | *what runs on them* |
| Equivalent to | Terraform / CloudFormation | the Puppet control repo |
| In production | separate repo, separate review | separate repo, separate review |
| Touches | Docker, networks, metadata | packages, config, services |

`provision.sh` never runs Puppet and never execs into a node to install
anything. Every package and every config file on every node arrives because
the node asked its Puppet master for a catalogue.

## Quick start

```bash
./provision.sh all
```

That is: `teardown`, `up`, `wait`, `status`, `verify`. Expect 15–25 minutes on
a cold image cache — three instances each download a Puppet agent, and two of
them a JVM (pm1 for PuppetServer, jenkins1 and cass1 for their products).

## What actually happens

```
provision.sh up
    │
    ├── deploys third-party modules into the control repo's modules/
    │     (what `r10k deploy environment` does in production)
    │
    ├── creates the pupnet bridge, 172.30.30.0/24
    │
    └── creates 3 containers from a BARE systemd image, each with:
          /etc/instance-metadata          <- instance metadata document
          /usr/local/sbin/user-data.sh    <- assembled user-data
          userdata.service + a wants/ symlink
        …and then stops.

each instance, on its own, at first boot
    │
    ├── systemd starts userdata.service
    │
    ├── 00-common.sh
    │     installs iptables, cron, curl        (Puppet cannot: see below)
    │     installs puppet-agent from apt.puppet.com
    │     writes facts.d/instance.yaml          <- identity as facts
    │     writes csr_attributes.yaml            <- identity as cert extensions
    │     writes puppet.conf pointing at pm1
    │
    ├── pm1: 30-role-puppetmaster.sh
    │     git clone control_repo_url (from inventory YAML, cloud only)
    │     r10k puppetfile install
    │     puppet apply -e 'include role_puppetmaster_pfpt'   (masterless)
    │       -> puppetserver 8.7.0, CA, autosign policy, JVM sizing
    │     then runs its own agent against itself
    │
    ├── jenkins1: 30-role-jenkins.sh
    │     waits for pm1:8140
    │     puppet agent -t
    │       -> Jenkins, plugins, seed job, cassy.sh, SSH key
    │
    └── cass1: 30-role-cassandra-node.sh
          waits for pm1:8140
          puppet agent -t
            -> CSR with pp_* extensions
            -> master's policy validator checks them against its allowlist
            -> autosigned
            -> catalogue
            -> JVM, Cassandra 4.0.21, config, service, schema, cron
```

## Why `iptables` and `cron` are in user-data and not in Puppet

They cannot be in Puppet. Both the `firewall` and `cron` providers **prefetch**
at the start of the transaction, so on a host with no `iptables` binary the run
fails before any resource is applied:

```
Error: Could not prefetch firewall provider 'iptables':
       Command iptables_save is missing
```

No ordering edge inside a catalogue can fix that — prefetch happens first. So
they are hard prerequisites of the image or of user-data. Production RHEL
images normally carry both, which is why this is rarely noticed until someone
uses a minimal image and a whole class is silently skipped.

## Adding a node

Edit the inventory YAML:

```yaml
# infra/inventory/customers/amex/nonprod.yaml
# in the cassandra/core/dc_east block:
count: 2          # was 1
seed_count: 1     # replaces the explicit role: 'cassandra_seed'
# remove: role: 'cassandra_seed'
```

The single-node cluster used an explicit `role:` because `seed_count >= count`
is an error. Going to 2 nodes, `seed_count: 1` makes cass1 the seed and cass2
the joining non-seed.

Then:

```bash
cd infra
./bin/expand-inventory.py --customer amex --environment nonprod   # review
./provision.sh up       # creates only the new node
./provision.sh wait && ./provision.sh verify
docker exec cass1 nodetool cleanup   # pre-existing node only
```

Nothing else changes. Not the control repo, not Hiera, not the master. The new
node boots, presents `pp_cluster: core`, and the master serves it the same
cluster file cass1 uses.

## Changing what the nodes run

Edit **one Hiera file** and re-run the agents:

```bash
vi ../cassandra-control-repo/data/customers/amex/nonprod/products/cassandra/clusters/core.yaml
docker exec cass1 /opt/puppetlabs/bin/puppet agent -t
```

The control repo is bind-mounted read-only into the master, and
`environment_timeout` is `0` for this cluster, so an edit is live immediately
with no deploy step.

## Changing the OS

Change the `os` column. `provision.sh` has the image table; the
OS-conditional configuration (package names, truststore paths, repository
shape) comes from the control repo's `data/os/` layers, so no other change is
needed:

```
cass3.lab.pfpt  172.30.30.13  rocky9  cassandra_node  ...
```

## Useful commands

```bash
./provision.sh status                 # boot state, cert state, service state
./provision.sh logs cass1             # that instance's user-data log
./provision.sh ssh pm1                # a shell on an instance
./provision.sh layers cass1           # which layer every value came from
./provision.sh explain cass1 profile_cassandra_pfpt::max_heap_size
./provision.sh verify                 # end-to-end assertions
```

### `layers` — the precedence order, demonstrated

```
KEY                        VALUE                 WINNING LAYER
seeds                      [...]                 customers/<c>/<env>/products/<p>/clusters/<id>/<dc>.yaml
max_heap_size              "640M"                customers/<c>/<env>/products/<p>/clusters/<id>.yaml
num_tokens                 16                    customers/<c>/<env>/products/<p>/clusters/<id>.yaml
s3_retention_period        7                     customers/<c>/<env>/common.yaml
cassandra_version          "4.0.21"              customers/<c>/products/<p>/common.yaml
repo_baseurl_prefix        "https://artifacts…"  customers/<c>/common.yaml
repair_steps_per_table     20                    products/<p>/environments/<env>.yaml
endpoint_snitch            "GossipingProperty…"  products/<p>/common.yaml
repo_skip_if_unavailable   true                  environments/<env>.yaml
```

Ten keys, each set at a **different** layer. Read top to bottom, that is the
precedence order — cluster first, then customer+env, customer+product,
customer, product+env, product, environment tier, OS, and finally
`common.yaml`.

### `explain` — one key, in full detail

Reach for it when a value is surprising: it prints every Hiera layer consulted,
in order, saying whether each path existed and whether the key was found.

Two caveats, documented above `cmd_explain()` in the script. The important one:
it resolves through the **fact-fallback** layers, because `puppet lookup` has no
TLS session and therefore cannot see a certificate. You can watch this in the
output — the trusted paths collapse to `customers///products//clusters/.yaml`
and are skipped. Each tenancy layer's trusted path and fact path point at the
same file, so the winning file is the same either way, but this command is
**not** proof that the trusted path works.

`verify` tests that separately, and decisively: it moves a node's facts aside
and re-runs the agent. Still no changes means the data can only have come from
the signed certificate.

## Files

| File | Purpose |
|---|---|
| `provision.sh` | the whole provisioning layer |
| `inventory/customers/<customer>/<env>.yaml` | which machines exist, sizing, roles, IP ranges |
| `inventory/defaults.yaml` | estate-wide defaults (ports, shapes, domain, Puppet collection) |
| `user-data/userdata.service` | the systemd unit that runs user-data at first boot |
| `user-data/00-prelude.sh` | user-data part 1: shell options and logging |
| `user-data/10-metadata-local.sh` | user-data part 2: reads identity from metadata.env (Docker) |
| `user-data/20-common.sh` | user-data part 3: prerequisites, agent install, facts, CSR |
| `user-data/30-role-puppetmaster.sh` | user-data part 4 for the master |
| `user-data/30-role-cassandra-node.sh` | user-data part 4 for Cassandra nodes |
| `user-data/30-role-jenkins.sh` | user-data part 4 for Jenkins |
| `.state/` | generated per-instance metadata and assembled user-data |

`.state/` is regenerated by `up` and removed by `teardown`, so a stale metadata
document from a previous inventory cannot leak into the next run.

## The join secret

Each node puts a shared secret in its CSR's `challengePassword`. The master
holds only its SHA-256, in the Puppet master's cluster file, so the plaintext
never reaches the CA. After the certificate is issued, user-data removes the
secret from the node's disk — otherwise every node in the estate would
permanently carry a credential that can register another node.

It is one secret shared by every node, so rotating it means reprovisioning.
Adequate for a lab and for a closed network; not a substitute for per-node
provisioning credentials. Override it with `PUPPET_JOIN_SECRET`, and update the
digest in
`data/customers/amex/nonprod/products/puppetmaster/clusters/pm.yaml` to match:

```bash
printf 'your-secret' | shasum -a 256
```
