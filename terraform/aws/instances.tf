# ===========================================================================
# Instances
# ===========================================================================
#
# Raw EC2 instances. Nothing is installed here: each one gets an identity as
# TAGS and a user-data script, and then Terraform is done. Every package and
# config file on every node arrives because the node asked the Puppet master
# for a catalogue.

resource "aws_instance" "node" {
  for_each = local.nodes

  ami           = var.ami_id
  instance_type = each.value.instance_type
  subnet_id     = each.value.subnet_id
  key_name      = var.key_name

  vpc_security_group_ids = local.security_group_ids
  iam_instance_profile   = local.instance_profile

  # No public IP. Nothing in this estate needs an inbound route from the
  # internet, and the CA port least of all. Egress goes through the NAT gateway
  # (see network.tf) or an internal mirror.
  associate_public_ip_address = false

  # ---------------------------------------------------------------------
  # GZIPPED, because EC2 caps user-data at 16 KiB
  # ---------------------------------------------------------------------
  # The four assembled fragments are ~31 KB for a Cassandra node and ~34 KB
  # for the master -- roughly DOUBLE the limit. Plain `user_data` is refused at
  # plan time:
  #
  #   Error: expected length of user_data to be in the range (0 - 16384)
  #
  # That is EC2's limit, not LocalStack's or Terraform's: real AWS rejects it
  # identically. It is also why GCP needs none of this -- a metadata value
  # there can be 256 KB, so the same script travels uncompressed.
  #
  # cloud-init detects the gzip magic bytes and decompresses before running the
  # script, so this needs no cooperation from the fragments themselves and they
  # stay byte-identical to the ones the local driver uses.
  #
  # Measured, all three sizes, because they are easy to confuse:
  #
  #             script    gzipped   gzip+base64   (limit 16384)
  #   node      31361     11629     15480
  #   master    33698     12173     16232
  #
  # AWS never sees the 31 KB script -- the gzip bytes ARE its "raw" user-data,
  # and the base64 of those is what travels. Both of the numbers AWS could be
  # measuring are therefore under the limit, but the MASTER has only ~150 bytes
  # of base64 headroom, so the precondition below fails the plan rather than
  # letting one more comment in 30-role-puppetmaster.sh turn into a truncated
  # boot script.
  #
  # Verified by round-tripping out of state: base64 15480 -> 31364 decoded,
  # all four fragments present, `#!/bin/bash` first.
  user_data_base64 = base64gzip(local.user_data[each.key])

  # ---------------------------------------------------------------------
  # THE IDENTITY
  # ---------------------------------------------------------------------
  # Read by 10-metadata-aws.sh from IMDS, written into the node's CSR as
  # extension requests, validated by the master's autosign policy, and signed
  # into its certificate -- after which they are trusted.extensions, which is
  # what every tenancy layer in hiera.yaml keys on.
  #
  # TAGS, not user-data parameters, and that is the point: instance_metadata_
  # tags below makes them readable from IMDS at
  # /latest/meta-data/tags/instance/<key>, so ONE user-data script serves every
  # node in the estate. Bake the identity into the script instead and you have
  # N scripts to keep in step, which is how a node ends up in the wrong
  # customer's Hiera.
  #
  # Keys are lower-case pp_* to match the Puppet extension shortnames exactly,
  # so there is one spelling from here through to Hiera.
  #
  # Tags are set by whoever created the instance, so they are no more
  # trustworthy than a fact -- and they do not need to be. They only SEED the
  # CSR; the master validates every extension against its allowlist before
  # signing. The CA is the security boundary, not this block.
  tags = merge(
    local.common_tags,
    {
      # The Name tag carries the CERTNAME. An instance's name is its identity
      # here, and renaming it means reissuing a certificate -- so this is not
      # cosmetic and not derived from var.name_prefix.
      Name = each.value.certname

      pp_certname    = each.value.certname
      pp_project     = local.inv.customer
      pp_environment = local.inv.environment
      pp_product     = each.value.product
      pp_cluster     = each.value.cluster
      pp_datacenter  = each.value.datacenter
      pp_role        = each.value.role
      pp_rack        = each.value.rack

      # The fallback 10-metadata-aws.sh uses to BUILD a certname from the
      # instance id when pp_certname is absent. Passed even though pp_certname
      # is set, so that a node created from this same configuration by an Auto
      # Scaling group (which cannot carry a per-node certname) still works.
      pp_domain = local.domain

      # PER NODE, not per stack: resolved from the inventory's puppet_server
      # layers, falling back to var.puppet_server. So one customer's cassandra
      # fleet can be served by a different master from the rest of its estate
      # without a second stack or a second tfvars file.
      puppet_server      = each.value.puppet_server
      puppet_collection  = var.puppet_collection
      puppet_environment = var.puppet_environment

      # Serialises ring joins. Empty for the first node in a datacentre.
      # Cassandra REFUSES concurrent bootstrap ("Other bootstrapping/leaving/
      # moving nodes detected"), so this turns a hard failure into a queue.
      wait_for = each.value.wait_for

      # Only the secret's ID, never its value. Tags are readable by anyone with
      # ec2:DescribeTags and by every process on the instance via IMDS, and
      # this value is what lets a host join the estate -- so the instance
      # fetches it from Secrets Manager with its own instance role instead.
      join_secret_id = var.join_secret_id == null ? "" : var.join_secret_id

      sizing = each.value.sizing

      # Control repo URL: cloned by the Puppet master at first boot. Non-master
      # nodes receive the tag and ignore it. Not sensitive -- git URLs are not
      # credentials.
      control_repo_url = local.control_repo_url

      # Secrets Manager secret ID of the SSH deploy key for the control repo.
      # The ID, never the value -- tags are readable by any process on the
      # instance via IMDS. The master fetches the key using its IAM role,
      # uses it for the initial clone, then scrubs it from disk.
      control_repo_deploy_key_secret_id = (
        local.control_repo_deploy_key_secret_id != null
        ? local.control_repo_deploy_key_secret_id
        : ""
      )

      # Ports, from inventory/defaults.yaml. The node's own health checks read
      # these instead of hardcoding 9042/8140, so the security group above and
      # the script below cannot disagree -- which they silently would if the
      # cluster set a non-default native_transport_port.
      puppet_port  = local.ports.puppet
      cql_port     = local.ports.cassandra_cql
      jenkins_port = local.ports.jenkins_http
    },
    var.extra_tags_per_node,
  )

  # root_block_device.tags, NOT the instance-level `volume_tags`.
  #
  # `volume_tags` applies to EVERY volume attached to the instance, including
  # ones this stack created separately -- so it FIGHTS aws_ebs_volume.data.
  # Caught on a second plan against LocalStack, which wanted to update both
  # instances in place forever:
  #
  #   ~ volume_tags = {
  #       ~ "Name"          = "cass1.lab.pfpt-data" -> "cass1.lab.pfpt"
  #       - "pp_certname"   = "cass1.lab.pfpt" -> null
  #       - "pp_cluster"    = "core"           -> null
  #       - "pp_datacenter" = "dec_east"       -> null
  #
  # Not just a perpetual diff: APPLYING it strips the identifying tags off the
  # volume holding a replica, which is how you end up with an unlabelled
  # orphaned EBS volume and no way to tell which node it belonged to. Scoping
  # the tags to the root device leaves the data volume's own tags alone.
  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = var.root_volume_type
    encrypted   = true
    kms_key_id  = var.kms_key_id

    tags = merge(local.common_tags, { Name = "${each.value.certname}-root" })

    # The root volume goes with the instance. Cassandra's data does not live
    # here -- see aws_ebs_volume.data below.
    delete_on_termination = true
  }

  # ---------------------------------------------------------------------
  # IMDSv2, REQUIRED
  # ---------------------------------------------------------------------
  # http_tokens = "required" disables IMDSv1. That is not box-ticking here: the
  # instance role can read the join secret, and IMDSv1's unauthenticated GET is
  # reachable through any SSRF in anything running on the node. v2's PUT-then-
  # GET with a token is not.
  #
  # instance_metadata_tags = "enabled" is what makes the tags above readable
  # from IMDS at all. WITHOUT IT the identity block above is invisible to the
  # node, every pp_* comes back empty, the CSR carries no extensions, and the
  # master's autosign policy refuses to sign -- leaving the node at
  # --waitforcert forever. It looks exactly like a network problem.
  metadata_options {
    http_endpoint          = "enabled"
    http_tokens            = "required"
    instance_metadata_tags = "enabled"

    # 2 is enough to leave the instance and reach IMDS. A larger value lets a
    # containerised process on the node reach IMDS through the docker bridge,
    # which is the same SSRF exposure by another route.
    http_put_response_hop_limit = 2
  }

  # ---------------------------------------------------------------------
  # Protecting stateful nodes from Terraform itself
  # ---------------------------------------------------------------------
  # Default TRUE, unlike most Terraform. These are database nodes holding the
  # only copy of some token ranges, and a `terraform destroy` against the wrong
  # workspace is a data-loss event.
  disable_api_termination = var.disable_api_termination

  lifecycle {
    # Re-running user-data means re-registering the node, and on a Cassandra
    # node that means a new certname and a rebuild. So a change to the script
    # must NOT silently recreate a live instance -- roll it deliberately.
    #
    # The consequence, stated plainly: editing a user-data fragment does not
    # affect existing nodes. It affects the next node created. That is correct
    # for stateful infrastructure and it does surprise people.
    #
    # ami is ignored for the same reason: a new AMI id in tfvars must not
    # replace a live replica as a side effect of an unrelated apply.
    ignore_changes = [user_data_base64, ami]

    precondition {
      # AWS EC2 limit: user-data must be <= 16384 bytes AFTER base64 decode.
      # `user_data_base64 = base64gzip(...)` sends gzipped bytes, so what AWS
      # measures is the gzipped size -- not the base64 string length.
      #
      # Terraform lacks a direct gzip() function, so we back-compute:
      # a base64 string of length L represents (L * 3 / 4) raw bytes (ignoring
      # padding). AWS's 16384-byte limit therefore corresponds to a base64
      # length of ceil(16384 * 4 / 3) = 21846.
      #
      # Concrete measurements at time of writing:
      #   puppetmaster  gzipped 13848 B  |  base64 18465 chars  --> fits
      #   cassandra     gzipped 12463 B  |  base64 16621 chars  --> fits
      #   jenkins       gzipped 11721 B  |  base64 15629 chars  --> fits
      #
      # A margin under the limit rather than at it. When this trips, TRIM
      # comments in the affected fragment before adding S3 staging complexity
      # -- there is typically 5+ KiB of prose to lose.
      condition     = length(base64gzip(local.user_data[each.key])) <= 21500
      error_message = "user-data for ${each.value.certname} exceeds EC2's 16 KiB decoded limit (base64 length > 21500). The role fragment has grown; trim comments first, and only if that is not enough move the bulk into the Puppet catalogue or stage from S3."
    }

    precondition {
      # An instance with no master boots, installs the agent, and then sits
      # there unconfigured -- an EC2 charge with no Cassandra on it and nothing
      # failed. Cheaper to reject at plan time.
      condition     = length(each.value.puppet_server) > 0
      error_message = "No puppet_server for ${each.value.certname}. Set it in the inventory (on the product, cluster or datacentre -- see inventory/defaults.yaml for the precedence), or pass var.puppet_server as this stack's fallback."
    }

    precondition {
      condition     = length(local.subnet_ids) > 0
      error_message = "No subnets. Either set create_vpc = true with availability_zones, or pass subnet_ids for an existing VPC. Order matters: rack N lands in subnet N, which is what spreads replicas across availability zones."
    }

    precondition {
      condition     = length(local.security_group_ids) > 0
      error_message = "No security groups. Either set create_security_group = true, or pass security_group_ids. With neither, instances land in the VPC default group and internode gossip on 7000 will not pass."
    }

    precondition {
      # A tag-based identity that IMDS cannot serve is the single most
      # confusing failure in this stack, so it is refused at plan time.
      condition     = var.create_iam_role || var.iam_instance_profile != null || var.join_secret_id == null
      error_message = "join_secret_id is set but no instance profile is available to read it. Set create_iam_role = true (with join_secret_arn) or pass iam_instance_profile."
    }
  }
}

# ===========================================================================
# Data volume for Cassandra
# ===========================================================================
# /var/lib/cassandra on its own EBS volume. Two reasons this matters: data on
# the root volume means a full disk takes the OS down with it, and it means the
# data cannot outlive the instance.
#
# NOTHING HERE FORMATS OR MOUNTS IT. That is deliberate: a Terraform-side mkfs
# is a data-loss waiting to happen on re-apply. Do it in Puppet (a filesystem
# resource guarded on the device), which can be idempotent about an existing
# filesystem in a way Terraform cannot.
resource "aws_ebs_volume" "data" {
  for_each = {
    for name, n in local.nodes : name => n
    if var.data_volume_size_gb > 0 && n.product == "cassandra"
  }

  availability_zone = aws_instance.node[each.key].availability_zone
  size              = var.data_volume_size_gb
  type              = var.data_volume_type
  iops              = var.data_volume_iops
  encrypted         = true
  kms_key_id        = var.kms_key_id

  tags = merge(local.common_tags, {
    Name          = "${each.value.certname}-data"
    pp_certname   = each.value.certname
    pp_cluster    = each.value.cluster
    pp_datacenter = each.value.datacenter
  })

  lifecycle {
    # The single most important line in this file. Without it, a change to size
    # or type can destroy and recreate the volume holding a replica.
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  for_each = aws_ebs_volume.data

  # NVMe-backed instance types (anything m5/m6i/r6i and newer) ignore this name
  # and expose the volume as /dev/nvme1n1 etc. Whatever mounts it must resolve
  # the device by its serial -- /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_
  # <volume-id-without-dashes> -- and not by this path. A fstab entry on
  # /dev/sdf survives exactly until the first reboot on a new instance family.
  device_name = var.data_device_name
  volume_id   = each.value.id
  instance_id = aws_instance.node[each.key].id

  # false by default in this provider, which is what we want: detaching a
  # volume from a running database node should fail rather than proceed.
  force_detach = false

  # A separate resource rather than an ebs_block_device block on the instance,
  # so resizing or detaching the volume does not require touching the instance.
}
