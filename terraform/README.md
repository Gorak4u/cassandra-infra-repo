# `infra/terraform/` — provisioning on a real cloud

`../provision.sh` creates Docker containers and nothing else. It is the **local
development loop**: fast, disposable, and deliberately not a cloud abstraction.

For AWS and GCP, Terraform is the provisioner. Both stacks read the **same
inventory YAML** the local driver reads, so `count: 3` is stated once and means
three containers or three instances depending on which driver runs.

## Status

| | AWS | GCP |
|---|---|---|
| `versions.tf` `variables.tf` `locals.tf` | ✅ | ✅ |
| `network.tf` `iam.tf` `instances.tf` `outputs.tf` | ✅ | ✅ |
| `terraform.tfvars.example` | ✅ | ✅ |
| `terraform fmt` / `validate` | ✅ | ✅ |
| Inventory expansion evaluated against real YAML | ✅ | ✅ |
| `plan`, bring-your-own network | ✅ 9 instances | ⚠️ needs credentials — see below |
| `plan`, managed network | ✅ 36 resources | ✅ 17 resources |
| `apply` against a live account | ✅ once, then destroyed | ❌ never run |

**AWS has been applied once.** A five-node estate (one master, three Cassandra,
one Jenkins) was created and later destroyed. It was not a clean run: the
master needed hand-applied Hiera, the eyaml private key had to be placed by
hand, and two Cassandra nodes never finished joining the ring. So the stack
provably creates the infrastructure, and the end-to-end path is **not** yet
proven repeatable.

**GCP now plans, for the first time.** The managed-network shape
(`create_network = true`, with NAT, firewall rules and a service account)
plans to 17 resources: a network, a subnetwork, a router and NAT, three
firewall rules, a service account, and three instances each with a data disk
and its attachment. The inventory expands correctly — cass1/cass2/cass3 at
`e2-small` from `sizing: small` — which is the part `validate` never checks.
**GCP has still never been applied.** Treat its first `apply` as its first
real test.

### Why GCP's bring-your-own-network shape cannot be plan-verified offline

A difference between the two stacks worth knowing before you rely on CI for
either. AWS's bring-your-own path takes ids from tfvars, and its only `data`
sources are `aws_iam_policy_document`, which Terraform evaluates locally — so
both AWS shapes plan with dummy credentials and no account. GCP's equivalent
path *looks up* the existing network:

```hcl
data "google_compute_network"    "existing" { count = var.create_network ? 0 : 1 }
data "google_compute_subnetwork" "existing" { count = var.create_network ? 0 : 1 }
```

Those are real API reads, so that shape fails at plan time without working
credentials:

```
Error: Error when reading or editing Network Not Found : shared-nonprod-vpc
```

That is not a defect — reading the real VPC is the point, and it catches a
wrong network name before an apply rather than after. But it does mean the
GCP BYO shape cannot be gated in a credential-free CI job the way both AWS
shapes can. Verify it against a real project, or with a service account
limited to `compute.networks.get` and `compute.subnetworks.get`.

Both AWS plan shapes have CI jobs in `.github/workflows/terraform-ci.yml`.
They need no credentials and no state — `init -backend=false` against dummy
tfvars — and they exercise the preconditions on `aws_instance.node` in both
their firing and passing directions. Note the two shapes need **different
inventory slices**: `amex/nonprod` names per-cluster `availability_zones`,
which cannot be honoured when the module does not own the VPC, so the
bring-your-own-network job plans `amex/prod` instead.

**Those jobs no longer fire on their own.** Every workflow in this repo was
switched to `workflow_dispatch` only; the original `push`/`pull_request`
triggers are commented out directly beneath, so re-enabling is uncommenting
them. Until then these plans are something a person runs — by hand, or from
the Actions tab — not a gate. GCP's managed-network plan is credential-free
too and could be gated the same way; its bring-your-own shape cannot (see
below).

## `terraform validate` is not evidence that this works

Worth stating loudly because it cost real time here. `validate` checks syntax
and provider schemas. It **never evaluates `locals` against the inventory
YAML**, so both stacks passed `validate` while being unable to `plan` at all:

```
Error: Inconsistent conditional result types
Type mismatch for object attribute "dc_east": The 'true' value includes
object attribute "count", which is absent in the 'false' value.
```

Both normalised the two cluster shapes (single-DC vs a `datacenters:` block)
with a conditional, and HCL requires both arms of a conditional to unify to one
type. Normalising the arms to identical attribute sets does not rescue it
either — the arms are also tuples of different lengths. Both now use two
filtered lists and a `concat`, which has no unification requirement.

It only became reachable once a cluster in the inventory actually grew a
`datacenters:` block, which is exactly the kind of latent breakage a green
`validate` hides. So check expansion directly:

```bash
cd aws   # or gcp
terraform console -var-file=your.tfvars <<< 'keys(local.nodes)'
terraform console -var-file=your.tfvars <<< 'local.nodes["cass2"]'
```

```
{ "certname" = "cass2.nonprod.amex.internal"   "datacenter" = "dc_east"
  "instance_type" = "t3.small"                 "rack" = "rack1"
  "role" = "cassandra_node"                    "subnet_id" = "subnet-bbbb2222"
  "wait_for" = "cass1.nonprod.amex.internal" }
```

## The central design choice: bring your own, or create

A real account already has a VPC, subnets, security groups and IAM roles, owned
by teams with their own change processes. Terraform that insists on creating
those is unusable there. A fresh sandbox has none of it and you want one
command.

So **every piece of surrounding infrastructure is behind a `create_*` boolean
that defaults to `false`.** Say nothing and the stack creates instances only.

| | AWS | GCP |
|---|---|---|
| Network | `create_vpc` | `create_network` |
| Egress | `create_nat_gateway` | `create_nat` |
| Firewall | `create_security_group` | `create_firewall_rules` |
| Identity | `create_iam_role` | `create_service_account` |

`terraform.tfvars.example` in each directory shows **both** cases in full —
bring-your-own as the active configuration, create-everything commented below
it. Every variable is overridable from tfvars; there are no hardcoded ids.

## One stack per datacentre

An AWS datacentre is a region and a GCP one is a region; a provider is
configured for one. So multi-region means running the stack once per region
with its own state — which is what you want anyway, because a single plan that
can destroy two regions at once is a bad afternoon.

```bash
terraform workspace new amex-nonprod-dc_east
terraform apply -var-file=amex-nonprod-dc_east.tfvars
```

`var.datacenter` selects which datacentre of the inventory file to build.

## Why not add cloud drivers to `provision.sh`?

Because that means reimplementing Terraform in bash, badly. The two use cases
genuinely differ: local wants speed and disposability, cloud wants state,
plan/apply and drift detection.

What makes them interchangeable is not shared code — it is a **shared
contract**, narrow enough to write down in full:

```
The platform must give the instance these values, and run its user-data once:

  PP_CERTNAME       PP_PROJECT     PP_ENVIRONMENT   PP_PRODUCT
  PP_CLUSTER        PP_DATACENTER  PP_ROLE          PP_RACK
  PUPPET_SERVER     PUPPET_COLLECTION               PUPPET_ENVIRONMENT
  JOIN_SECRET       WAIT_FOR       INSTANCE_IP      IMAGE_NAME
```

All three provisioners satisfy exactly that. Everything above it — the control
repo, Hiera, the autosign policy, every module — is untouched.

On AWS those values arrive as **instance tags** read from IMDS, which is why
`instance_metadata_tags = "enabled"` is not optional: without it the identity
block is invisible to the node, every `pp_*` is empty, the CSR carries no
extensions, the master refuses to sign, and the node waits at `--waitforcert`
forever looking like a network problem. On GCP they arrive as metadata
attributes, which are readable by default.

Neither is a security boundary. Tags and metadata are set by whoever created
the instance, so they are no more trustworthy than a fact — they only **seed**
the CSR. The master validates every extension against its allowlist before
signing. **The CA is the boundary.**

## What is shared, and what differs

The user-data fragments in `../user-data/` are shared verbatim:

| Fragment | Local | AWS | GCP |
|---|---|---|---|
| `00-prelude.sh` | ✅ same | ✅ same | ✅ same |
| `10-metadata-*.sh` | `local` | `aws` | `gcp` |
| `20-common.sh` | ✅ same | ✅ same | ✅ same |
| `30-role-*.sh` | ✅ same | ✅ same | ✅ same |

Verify that claim rather than trusting it:

```bash
cd ..
diff <(PLATFORM=local ./provision.sh render cass1 | sed -n '/fragment 3 of 4/,$p') \
     <(PLATFORM=aws   ./provision.sh render cass1 | sed -n '/fragment 3 of 4/,$p')
```

Two things **disappear** on a real cloud, and both were container workarounds:

- `userdata.service` and the `multi-user.target.wants` symlink — cloud-init
  runs user-data natively.
- The mounted `/etc/instance-metadata` file — there is a real metadata service.

## Protecting stateful nodes from Terraform itself

Several defaults here are the **opposite** of usual Terraform, on purpose.
These are database nodes holding the only copy of some token ranges.

| | AWS | GCP | Default |
|---|---|---|---|
| Termination protection | `disable_api_termination` | `deletion_protection` | **true** |
| Stop to change machine type | — | `allow_stopping_for_update` | **false** |
| Data volume | `prevent_destroy` | `prevent_destroy` | always |
| `user_data` / `startup-script` changes | `ignore_changes` | `ignore_changes` | always |
| Image/AMI changes | `ignore_changes` | `ignore_changes` | always |

The last two have a consequence worth stating plainly: **editing a user-data
fragment does not affect existing nodes.** It affects the next node created.
Re-running user-data means re-registering the node, and on a Cassandra node
that means a new certname and a rebuild — so it must be a deliberate roll, not
a side effect of an unrelated apply.

Nothing formats or mounts the data volume, on either cloud. A Terraform-side
`mkfs` is a data-loss waiting to happen on re-apply; do it in Puppet, with a
filesystem resource guarded on the device. On AWS, resolve the device **by
serial** (`/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_<volume-id>`): NVMe
instance types ignore the requested `/dev/sdf`, and an fstab entry on `/dev/sdf`
survives exactly until the first reboot on a new instance family.

## Before you run this in anger

1. **Seeds.** The cluster's Hiera file names seed addresses literally, and a
   replaced instance gets a new one. Reserve static internal addresses, or use
   private DNS names, and point Hiera at those. The `seeds` output says this
   too. A multi-DC cluster's Hiera seed list is the **union** of each stack's
   output — per-DC seed lists leave each side gossiping only with itself, and a
   "multi-DC" cluster silently becomes two independent rings.
2. **Egress.** Instances have no public address. With no NAT and no internal
   mirror, first boot **hangs** installing the Puppet agent — and it looks
   exactly like a user-data bug. Check egress before reading the script.
3. **The join order does not scale, and its timeout is the sharp edge.**
   `wait_for` is a linear chain: each node waits for the previous node's CQL
   port, because Cassandra refuses concurrent bootstrap. Correct for a handful
   of nodes; at 100 it is a multi-hour serial build.

   A dead node does **not** wedge the rest — on timeout a node logs a warning
   and joins anyway, deliberately, so one broken machine produces one clear
   failure instead of an estate of nodes all waiting on the one in front. The
   cost of that choice is that **the timeout has to exceed a real bootstrap**,
   or the chain silently stops serialising: every node behind a slow
   bootstrap times out and starts its own, concurrently, which is the exact
   thing the chain exists to prevent. It was hardcoded at 900s — fine for an
   empty lab node, badly wrong for a production one streaming hundreds of GB.

   It is now `bootstrap_wait_timeout`, set in `inventory/defaults.yaml`,
   overridable per customer+environment and per stack (`-var`), and carried to
   the node as an instance tag (AWS) or metadata attribute (GCP). Raise it
   above the worst-case bootstrap for the largest node you run. The default
   stays 900 because that is right for the lab this repo builds by default.

   None of that makes the chain parallel. For that, replace it with a lock
   carrying a TTL (a DynamoDB conditional write, or a GCS object
   precondition): acquire, bootstrap, release, and let the TTL break a stuck
   hold. Deliberately **not** implemented here — an untested distributed lock
   in the boot path of a stateful database is worse than a slow serial build:
   fail closed and every node wedges, fail open and you get the concurrent
   bootstrap this whole mechanism exists to avoid. Build it against a real
   account, with a test that proves both failure directions.
4. **No autoscaling.** Deliberately. Cassandra is stateful: a scale-in that
   terminates a node holding replicas is a data-loss event. One instance per
   node, replaced deliberately.
5. **`check-sizing.py` cannot run in THIS repo's CI.** It compares an infra
   value against the Hiera that sets it, so it needs cassandra-control-repo
   checked out alongside; the built-in `GITHUB_TOKEN` is scoped to one
   repository. Run it wherever both halves are present — it honours
   `PUPPET_CONTROL_REPO` and defaults to `../cassandra-control-repo`. It
   matters because a machine too small for the JVM heap Hiera pins is
   OOM-killed after a clean-looking startup, with nothing failing in Puppet.
