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
| `plan` / `apply` against a live account | ❌ never run | ❌ never run |

**Neither has been applied.** They have been validated and their locals have
been evaluated against the real inventory with `terraform console`, which is a
meaningfully stronger check than `validate` — see the next section — but no
instance has ever been created by either. Treat the first `apply` as the first
test.

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
3. **The join order does not scale.** `wait_for` is a linear chain: each node
   waits for the previous node's CQL port, because Cassandra refuses concurrent
   bootstrap. Correct for a handful of nodes; at 100 it is a multi-hour serial
   build and one dead node wedges the rest forever. Replace it with a lock
   carrying a TTL (a DynamoDB conditional write, or a GCS object precondition):
   acquire, bootstrap, release, and let the TTL break a stuck hold.
4. **No autoscaling.** Deliberately. Cassandra is stateful: a scale-in that
   terminates a node holding replicas is a data-loss event. One instance per
   node, replaced deliberately.
5. **`check-sizing.py` should run in CI.** A machine too small for the JVM heap
   Hiera pins is OOM-killed after a clean-looking startup, with nothing failing
   in Puppet. The `sizing` output exists to be cross-checked against it.
