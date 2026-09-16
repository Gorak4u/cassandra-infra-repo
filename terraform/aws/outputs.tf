# ===========================================================================
# Outputs
# ===========================================================================

output "nodes" {
  description = "certname -> {instance id, private ip, az, role, rack, instance type}"
  value = {
    for name, inst in aws_instance.node : local.nodes[name].certname => {
      instance_id       = inst.id
      private_ip        = inst.private_ip
      availability_zone = inst.availability_zone
      subnet_id         = inst.subnet_id
      role              = local.nodes[name].role
      rack              = local.nodes[name].rack
      instance_type     = inst.instance_type
      datacenter        = local.nodes[name].datacenter
    }
  }
}

output "seeds" {
  description = <<-EOT
    Seed addresses for this datacentre, for the control repo's

      data/customers/<c>/<env>/products/cassandra/clusters/<id>.yaml

    READ THIS BEFORE USING THEM
    ---------------------------
    1. These are the instances' CURRENT private addresses. EC2 keeps a private
       IP for the life of an instance, so they are stabler than they look --
       but a replaced instance gets a new one, and a stale seed list is a
       cluster that cannot form. For anything past a first experiment, give
       seeds a stable name: a Route53 private-zone record per seed, or an ENI
       created separately and attached, and point Hiera at that.

    2. The Hiera seed list must SPAN datacentres. This output covers only the
       datacentre this stack built, so a multi-DC cluster's seed list is the
       UNION of each stack's output -- per-DC seed lists leave each side
       gossiping only with itself, and a "multi-DC" cluster silently becomes
       two independent rings.
  EOT
  value = [
    for name, inst in aws_instance.node : inst.private_ip
    if local.nodes[name].role == "cassandra_seed"
  ]
}

output "puppetmaster" {
  description = "The master's certname and address, if this stack built one."
  value = {
    for name, inst in aws_instance.node : local.nodes[name].certname => {
      private_ip        = inst.private_ip
      availability_zone = inst.availability_zone
      instance_id       = inst.id
    }
    if local.nodes[name].product == "puppetmaster"
  }
}

output "datacenter" {
  description = "The datacentre this stack built. One stack per datacentre; see locals.tf."
  value       = local.target_dc
}

output "network" {
  description = "Resolved VPC, subnets and security groups, and whether this stack created them."
  value = {
    vpc_id                         = local.vpc_id
    subnet_ids                     = local.subnet_ids
    security_group_ids             = local.security_group_ids
    vpc_created_by_this            = var.create_vpc
    security_group_created_by_this = var.create_security_group
    nat_gateway_created_by_this    = var.create_vpc && var.create_nat_gateway
  }
}

output "iam" {
  description = "Instance profile the nodes run as."
  value = {
    instance_profile = local.instance_profile
    created_by_this  = var.create_iam_role
    ssm_attached     = var.create_iam_role && var.attach_ssm_policy
  }
}

output "sizing" {
  description = <<-EOT
    Instance shape per node, for cross-checking against the JVM heap Hiera
    pins. `infra/bin/check-sizing.py` is the authoritative check and should run
    in CI -- a machine too small for its heap is OOM-killed after a
    clean-looking startup with nothing failing in Puppet.
  EOT
  value = {
    for name, n in local.nodes : n.certname => {
      sizing        = n.sizing
      instance_type = n.instance_type
      ram_mb        = n.ram_mb
    }
  }
}

output "data_volumes" {
  description = <<-EOT
    Attached data volumes. Empty when data_volume_size_gb is 0, which puts
    Cassandra's data on the root volume -- workable for a test, wrong for
    anything else.

    NOTHING FORMATS OR MOUNTS THESE. On NVMe instance types the device is
    /dev/nvme1n1, not the /dev/sdf requested, so resolve it by serial:
      /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_<volume id, no dashes>
  EOT
  value = {
    for name, v in aws_ebs_volume.data : local.nodes[name].certname => {
      volume_id = v.id
      size_gb   = v.size
      type      = v.type
    }
  }
}

output "next_steps" {
  description = "What to do after apply."
  value       = <<-EOT
    1. Put the seed addresses above into the cluster's Hiera file, as the UNION
       across every datacentre's stack.

    2. If this added a datacentre to a LIVE cluster, the nodes have joined as
       EMPTY nodes -- they own no data until the dc is in the replication map,
       and that ALTER is REJECTED while the dc has no live member
       ("Unrecognized strategy option"). So, in order:

         a. confirm the new nodes are UN       nodetool status
         b. add the dc to system_keyspaces_replication in Hiera, re-run agents
         c. stream the data in                 cass-ops rebuild   (per node)
         d. repair                             nodetool repair -full system_auth

    3. Clients must use LOCAL_QUORUM and a DC-aware policy BEFORE step 2b.
       Plain QUORUM starts spanning datacentres the moment the replication map
       changes, and every write then waits on a cross-region ack. That is the
       outage, and it happens at 2b rather than at 2a.

    4. If a node never appears on the master, check EGRESS before reading the
       user-data. With no NAT and no mirror, first boot hangs installing the
       agent and looks exactly like a script bug.
  EOT
}
