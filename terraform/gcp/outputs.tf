# ===========================================================================
# Outputs
# ===========================================================================

output "nodes" {
  description = "certname -> {name, internal ip, zone, role, rack, machine type}"
  value = {
    for name, inst in google_compute_instance.node : local.nodes[name].certname => {
      instance_name = inst.name
      internal_ip   = inst.network_interface[0].network_ip
      zone          = inst.zone
      role          = local.nodes[name].role
      rack          = local.nodes[name].rack
      machine_type  = inst.machine_type
      datacenter    = local.nodes[name].datacenter
    }
  }
}

output "seeds" {
  description = <<-EOT
    Seed addresses for this datacentre, for the control repo's

      data/customers/<c>/<env>/products/cassandra/clusters/<id>.yaml

    READ THIS BEFORE USING THEM
    ---------------------------
    1. These are EPHEMERAL internal addresses. They change if an instance is
       recreated, and a stale seed list is a cluster that cannot form. For
       anything past a first experiment, reserve static internal addresses
       (google_compute_address with address_type = "INTERNAL") or use a Cloud
       DNS private zone, and point Hiera at those.

    2. The Hiera seed list must SPAN datacentres. This output covers only the
       datacentre this stack built, so a multi-DC cluster's seed list is the
       union of each stack's output -- per-DC seed lists leave each side
       gossiping only with itself, and a "multi-DC" cluster silently becomes
       two independent rings.
  EOT
  value = [
    for name, inst in google_compute_instance.node :
    inst.network_interface[0].network_ip
    if local.nodes[name].role == "cassandra_seed"
  ]
}

output "puppetmaster" {
  description = "The master's certname and address, if this stack built one."
  value = {
    for name, inst in google_compute_instance.node : local.nodes[name].certname => {
      internal_ip = inst.network_interface[0].network_ip
      zone        = inst.zone
    }
    if local.nodes[name].product == "puppetmaster"
  }
}

output "datacenter" {
  description = "The datacentre this stack built. One stack per datacentre; see locals.tf."
  value       = local.target_dc
}

output "network" {
  description = "Resolved network and subnetwork, and whether this stack created them."
  value = {
    network_id      = local.network_id
    subnetwork_id   = local.subnetwork_id
    created_by_this = var.create_network
  }
}

output "service_account" {
  description = "Service account the instances run as."
  value = {
    email           = local.service_account
    created_by_this = var.create_service_account
  }
}

output "sizing" {
  description = <<-EOT
    Machine shape per cluster, for cross-checking against the JVM heap Hiera
    pins. `infra/bin/check-sizing.py` is the authoritative check and should run
    in CI -- a machine too small for its heap is OOM-killed after a
    clean-looking startup with nothing failing in Puppet.
  EOT
  value = {
    for name, n in local.nodes : n.certname => {
      sizing       = n.sizing
      machine_type = n.machine_type
      ram_mb       = n.ram_mb
    }
  }
}

output "next_steps" {
  description = "What to do after apply."
  value       = <<-EOT
    1. Put the seed addresses above into the cluster's Hiera file, as the UNION
       across every datacentre's stack.

    2. If this added a datacentre to a LIVE cluster, the nodes have joined as
       EMPTY nodes -- they own no data until dc is in the replication map, and
       that ALTER is rejected while the dc has no live member. So, in order:

         a. confirm the new nodes are UN       nodetool status
         b. add the dc to system_keyspaces_replication in Hiera, re-run agents
         c. stream the data in                 cass-ops rebuild   (per node)
         d. repair

    3. Clients must use LOCAL_QUORUM and a DC-aware policy BEFORE step 2b.
       Plain QUORUM starts spanning datacentres the moment the replication map
       changes, and every write then waits on a cross-region ack. That is the
       outage, and it happens at 2b rather than at 2a.
  EOT
}
