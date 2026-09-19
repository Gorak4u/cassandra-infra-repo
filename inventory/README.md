# `infra/inventory/` — what machines exist

One file per customer per environment, **mirroring the control repo's Hiera
layout** so there is one mental model for the whole estate rather than two:

```
infra/inventory/customers/amex/nonprod.yaml        <- what MACHINES exist
data/customers/amex/nonprod/products/…/clusters/   <- what RUNS on them
```

```
inventory/
  defaults.yaml                  shared defaults + machine shapes + local slice
  customers/
    amex/nonprod.yaml            ← the local lab's slice
    amex/prod.yaml
    acme/prod.yaml               two Cassandra clusters
    acme/staging.yaml            no master — served by acme/prod's
    globex/prod.yaml
```

Today that is **35 nodes from 5 files, 125 lines of YAML** — and `count: 9`
becoming `count: 200` leaves it at 125 lines.

## Why not one line per node

That is what this replaced, and it fails in a specific way. At four nodes a
flat table is fine. At a hundred it means a hundred near-identical lines,
`customer` / `environment` / `datacenter` / `os` repeated on every one, a
hundred hand-picked addresses, and a join chain ninety-nine links long. Every
one of those is a place to make a silent mistake.

Here, growing a cluster is one integer. Names, addresses, seed roles, racks and
join ordering are **derived**, and the derivation is checked.

## Adding things

**A node** — one integer:

```yaml
cassandra:
  clusters:
    core:
      count: 5        # was 4
```

**A cluster** — one block here, one Hiera file in the control repo:

```yaml
      analytics:
        count: 3
        seed_count: 2
        name_prefix: 'acme-analytics'
        sizing: 'large'
        ip_offset: 40
```

**A customer** — one new file. Nothing else changes.

**A second Puppet master**, serving one product (or cluster, or datacentre) —
one cluster of the `puppetmaster` product, and one `puppet_server` line on
whatever it serves:

```yaml
products:
  puppetmaster:
    clusters:
      pm:       { count: 1, role: 'puppetmaster', name_prefix: 'pm-prod',      sizing: 'large', ip_offset: 10, serialize: false }
      pm-data:  { count: 1, role: 'puppetmaster', name_prefix: 'pm-prod-data', sizing: 'large', ip_offset: 20, serialize: false }

  cassandra:
    puppet_server: 'pm-prod-data1.lab.pfpt'    # every cluster, DC and node of it
    clusters:
      core: { count: 6, ... }
```

`puppet_server` resolves narrowest-first — datacentre, cluster, **product**,
environment file, `defaults.yaml`, then implicitly the `puppetmaster` in the
same customer+environment (widening to the customer, and no further). A node
with `role: puppetmaster` is always its own server. The full list, with the
reasoning, is in `defaults.yaml` next to the key.

> The inventory only decides what a node is **told** — it becomes
> `PUPPET_SERVER` in the instance metadata. What *enforces* the split is
> `autosign_allowed_extensions` on each master in the control repo. Set both,
> or the separation is decorative. `guides/09-split-the-estate-across-several-masters.md`
> in **cassandra-control-repo** has the whole procedure, including the
> join-secret step that is easy to miss. It is not linked relatively because it
> lives in the other repo, and this one is public.
>
> One thing that guide cannot tell you, because it is Terraform-side: unlike
> `bin/expand-inventory.py`, the AWS stack has **no implicit fallback** to
> "the puppetmaster in this expansion". `terraform/aws/locals.tf` walks
> datacentre, cluster, product, environment file, then `var.puppet_server`, and
> stops. A slice that expands cleanly here can still fail at
> `terraform plan` with "No puppet_server for <certname>". State it explicitly
> for anything you intend to apply.

## The three tools

```bash
./bin/expand-inventory.py                     # the whole estate
./bin/expand-inventory.py --customer amex --environment nonprod
./bin/expand-inventory.py --limit 3           # a laptop-sized slice
./bin/expand-inventory.py --format yaml       # structured

./bin/check-sizing.py --verbose               # machine RAM vs the Hiera heap
./bin/check-ports.py --verbose                # firewall ports vs the Hiera ports
```

Both checks exist for the same reason: a value that spans infra and the control
repo, that nothing connects at runtime, and whose mismatch is silent. **Run
both in CI.**

`provision.sh` calls the expander itself; you rarely run it by hand. It emits
the same flat table the hand-written file used, so the part of `provision.sh`
that actually creates machines was not touched by any of this.

### What the expander refuses

Each of these is a mistake that is otherwise silent:

| Rejected | Why it matters |
|---|---|
| duplicate certname | the second node's CSR collides with the first node's certificate — it cannot register at all |
| duplicate address | two containers, one IP |
| overlapping `ip_offset` | the usual cause of the above |
| `count` beyond the subnet | fails at node 245 of a `/24`, not at node 1 |
| `seed_count >= count` | a ring where every node is a seed can come up as several independent one-node clusters |
| unknown `sizing` | names the shapes that do exist |
| no master for a node, and none to fall back to | that node would boot and never be configured |
| two masters in the slice and no `puppet_server` | ambiguous — see below; guessing converges a node to the wrong configuration with a clean green run |
| `puppet_server` naming a non-master node | a typo'd or stale certname |
| `wait_for` outside the expansion | the node waits until timeout, which looks like a hung build |

### What `check-sizing.py` is for

Sizing is the one value that spans both halves of the estate, and the two must
agree:

```
infra   sizing: small      ->  ram_mb 2048      the machine
Hiera   max_heap_size      ->  '640M'           the JVM inside it
```

A mismatch is **silent**. A Cassandra node with a 640 MB heap settles at about
1782 MiB RSS; give it a 1400 MB machine and the kernel OOM-kills it in a
restart loop while Cassandra's own log shows a clean startup and no Puppet
resource fails. That is not hypothetical — it happened while building this lab
and cost a full rebuild to diagnose.

`provision.sh up` gates on this check, and it should run in CI.

It found two genuine inconsistencies the first time it ran
(`acme/prod/analytics` and `acme/staging/core` both had heap equal to machine
RAM), and a bug in its own first model: a multiplier measured at a 640 MB heap,
extrapolated to 16 GB, demanded a 41 GB machine. The model is additive now —
a measured fixed overhead plus an allowance — which is why the numbers hold at
both ends.

## Which slice the local driver builds

The inventory describes the whole estate; `provision.sh` can only create Docker
containers, and this machine fits about five. So `defaults.yaml` names a
default:

```yaml
local_slice:
  customer: 'amex'
  environment: 'nonprod'
```

Override per invocation:

```bash
CUSTOMER=acme ENVIRONMENT=prod LIMIT=2 ./provision.sh up
```

Terraform ignores `local_slice` entirely — it reads these files directly and
builds whichever slice its own configuration selects.

## Machine shapes

A cluster asks for `sizing: small`, not for a machine type, and `defaults.yaml`
resolves that name per platform:

| shape | cpu | ram_mb | local | GCP | AWS |
|---|---|---|---|---|---|
| small | 2 | 2048 | 2048m | e2-small | t3.small |
| medium | 2 | 8192 | 2048m | e2-standard-2 | m6i.large |
| large | 4 | 16384 | 2048m | n2-highmem-2 | r6i.large |
| xlarge | 8 | 65536 | 2048m | n2-highmem-8 | r6i.2xlarge |

`ram_mb` is authoritative and is what `check-sizing.py` uses. If you add a
shape, make the per-platform names actually correspond to it — otherwise the
check validates against the wrong number and passes when it should not.

`local_mem` is what the local driver actually gives a container, because a
laptop cannot honour 16 GiB of them. That is a lab compromise, and it is the
reason `check-sizing.py` validates `ram_mb`: the check is about whether the
*production* shape is right.

**But the two diverge, and a cluster can pass the check and still be
OOM-killed.** They agree for `small` (2048/2048), which is why it has never
bitten the Cassandra nodes; for every larger shape `local_mem` is far below
`ram_mb`. `check-sizing.py` therefore *also* checks `local_mem` — but only for
the slice `local_slice` names, since that is the only one the local driver
will ever build, and warning about production clusters nobody will build on a
laptop is nine lines of noise that teaches people to ignore the check.

`large` is 3072m rather than 2048m for exactly this reason: a Jenkins with a
pipeline plugin set was OOM-killed at 2048m.

## What does NOT belong here

| | |
|---|---|
| JVM heap, GC, Cassandra settings | Hiera — Puppet configures the application |
| cluster name, seeds, replication | Hiera |
| package versions | Hiera |
| **machine shape, node count, addressing** | **here** |

The seam: this directory decides *what machines exist and how big they are*.
Everything about what runs on them is keyed on the identity stamped here and
resolved from the control repo.
