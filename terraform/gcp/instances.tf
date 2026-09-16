# ===========================================================================
# Instances
# ===========================================================================
#
# Raw VMs. Nothing is installed here: each one gets an identity as metadata and
# a user-data script, and then Terraform is done. Every package and config file
# on every node arrives because the node asked the Puppet master for a
# catalogue.

resource "google_compute_instance" "node" {
  for_each = local.nodes

  # GCE instance names must be RFC1035 -- lower case, no dots -- so the bare
  # name goes here and the FQDN travels as the pp_certname metadata attribute.
  # They are different things, and conflating them gives a node a certname the
  # master's autosign pattern refuses.
  name         = each.value.name
  project      = var.project_id
  zone         = each.value.zone
  machine_type = each.value.machine_type

  labels = merge(local.common_labels, {
    product = each.value.product
    cluster = each.value.cluster
    role    = each.value.role
    rack    = each.value.rack
    sizing  = each.value.sizing
  })

  tags = distinct(concat(
    [local.estate_tag, local.product_tag[each.value.product]],
    var.network_tags,
  ))

  boot_disk {
    auto_delete = true

    initialize_params {
      image  = var.boot_image
      size   = var.boot_disk_size_gb
      type   = var.boot_disk_type
      labels = local.common_labels
    }
  }

  network_interface {
    subnetwork = local.subnetwork_id

    # No access_config block, deliberately: NO EXTERNAL IP. Nothing in this
    # estate needs an inbound route from the internet, and the CA port least of
    # all. Egress goes through Cloud NAT (see network.tf) or an internal
    # mirror.
  }

  # ---------------------------------------------------------------------
  # THE IDENTITY
  # ---------------------------------------------------------------------
  # Read by 10-metadata-gcp.sh, written into the node's CSR as extension
  # requests, validated by the master's autosign policy, and signed into its
  # certificate -- after which they are trusted.extensions, which is what
  # every tenancy layer in hiera.yaml keys on.
  #
  # Keys are lower-case pp_* to match the Puppet extension shortnames exactly,
  # so there is one spelling from here through to Hiera.
  #
  # Metadata is set by whoever created the instance, so it is no more
  # trustworthy than a fact -- and it does not need to be. It only SEEDS the
  # CSR; the master validates every extension against its allowlist before
  # signing. The CA is the security boundary, not this block.
  metadata = merge(
    {
      pp_certname    = each.value.certname
      pp_project     = local.inv.customer
      pp_environment = local.inv.environment
      pp_product     = each.value.product
      pp_cluster     = each.value.cluster
      pp_datacenter  = each.value.datacenter
      pp_role        = each.value.role
      pp_rack        = each.value.rack

      # The fallback 10-metadata-gcp.sh uses to BUILD a certname from the
      # instance name when pp_certname is absent. Passed even though
      # pp_certname is set, so that a node created from this same template by
      # an instance group (which cannot carry a per-node certname) still works.
      pp_domain = local.domain

      # Ports, from inventory/defaults.yaml. The node's own health checks read
      # these instead of hardcoding 9042/8140, so the firewall rules and the
      # script cannot disagree.
      puppet_port  = local.ports.puppet
      cql_port     = local.ports.cassandra_cql
      jenkins_port = local.ports.jenkins_http

      # PER NODE, not per stack: resolved from the inventory's puppet_server
      # layers, falling back to var.puppet_server. So one customer's cassandra
      # fleet can be served by a different master from the rest of its estate
      # without a second stack or a second tfvars file.
      puppet_server      = each.value.puppet_server
      puppet_collection  = var.puppet_collection
      puppet_environment = var.puppet_environment

      # Serialises ring joins. Empty for the first node in a datacentre.
      wait_for = each.value.wait_for

      # Only the secret's RESOURCE NAME, never its value. Instance metadata is
      # readable by anyone with compute.instances.get, and this value is what
      # lets a host join the estate -- so the instance fetches it from Secret
      # Manager with its own service account instead.
      join_secret_name = var.join_secret_id == null ? "" : (
        "projects/${var.project_id}/secrets/${var.join_secret_id}/versions/${var.join_secret_version}"
      )

      # Control repo URL: cloned by the Puppet master at first boot when no
      # bind-mount is present (i.e., every cloud-provisioned master). Non-master
      # nodes receive the attribute and ignore it -- only 30-role-puppetmaster.sh
      # reads CONTROL_REPO_URL.
      control_repo_url = local.control_repo_url

      # Secret Manager RESOURCE NAME of the SSH deploy key for the control repo.
      # Non-sensitive: it is a resource identifier, not the key itself.
      # The master fetches the actual key from Secret Manager at boot, uses it
      # for the initial git clone, then scrubs it from disk.
      control_repo_deploy_key_secret = (
        local.control_repo_deploy_key_secret_id != null
        ? "projects/${var.project_id}/secrets/${local.control_repo_deploy_key_secret_id}/versions/latest"
        : ""
      )

      # cloud-init runs this. No userdata.service and no
      # multi-user.target.wants symlink: that whole mechanism is a container
      # workaround and disappears here.
      startup-script = local.startup_script[each.key]

      # IAM-governed SSH rather than metadata keys, which are hard to audit and
      # harder to revoke.
      enable-oslogin = var.enable_oslogin ? "TRUE" : "FALSE"
    },
    var.metadata,
  )

  service_account {
    email  = local.service_account
    scopes = var.service_account_scopes
  }

  dynamic "shielded_instance_config" {
    for_each = var.enable_shielded_vm ? [1] : []
    content {
      enable_secure_boot          = true
      enable_vtpm                 = true
      enable_integrity_monitoring = true
    }
  }

  # ---------------------------------------------------------------------
  # Protecting stateful nodes from Terraform itself
  # ---------------------------------------------------------------------
  # Defaults that are the OPPOSITE of most Terraform, on purpose. These are
  # database nodes holding the only copy of some token ranges.
  deletion_protection = var.deletion_protection

  # false by default: on a Cassandra node an unexpected stop is an outage and
  # possibly a repair. Change machine types deliberately, one node at a time,
  # with the ring checked in between.
  allow_stopping_for_update = var.allow_stopping_for_update

  lifecycle {
    # Re-running user-data means re-registering the node, and on a Cassandra
    # node that means a new certname and a rebuild. So a change to the script
    # must NOT silently recreate a live instance -- roll it deliberately.
    #
    # The consequence, stated plainly: editing a user-data fragment does not
    # affect existing nodes. It affects the next node created. That is the
    # correct behaviour for stateful infrastructure and it does surprise
    # people, so it is worth knowing.
    ignore_changes = [
      metadata["startup-script"],
      boot_disk[0].initialize_params[0].image,
    ]

    precondition {
      # An instance with no master boots, installs the agent, and then sits
      # there unconfigured -- a GCE charge with no Cassandra on it and nothing
      # failed. Cheaper to reject at plan time.
      condition     = length(each.value.puppet_server) > 0
      error_message = "No puppet_server for ${each.value.certname}. Set it in the inventory (on the product, cluster or datacentre -- see inventory/defaults.yaml for the precedence), or pass var.puppet_server as this stack's fallback."
    }
  }

  depends_on = [
    google_secret_manager_secret_iam_member.join_secret,
  ]
}

# ===========================================================================
# Data disk for Cassandra
# ===========================================================================
# /var/lib/cassandra on its own persistent disk. Two reasons this matters:
# data on the boot disk means a full disk takes the OS down with it, and it
# means the data cannot outlive the instance.
#
# NOTHING HERE FORMATS OR MOUNTS IT. That is deliberate: a Terraform-side mkfs
# is a data-loss waiting to happen on re-apply. Do it in Puppet (a filesystem
# resource guarded on the device) or in a disk-setup step in user-data, both of
# which can be idempotent about an existing filesystem in a way Terraform
# cannot.
resource "google_compute_disk" "data" {
  for_each = {
    for name, n in local.nodes : name => n
    if var.data_disk_size_gb > 0 && n.product == "cassandra"
  }

  name    = "${each.value.name}-data"
  project = var.project_id
  zone    = each.value.zone
  size    = var.data_disk_size_gb
  type    = var.data_disk_type
  labels  = local.common_labels

  lifecycle {
    # The single most important line in this file. Without it, a change to
    # size or type can destroy and recreate the disk holding a replica.
    prevent_destroy = true
  }
}

resource "google_compute_attached_disk" "data" {
  for_each = google_compute_disk.data

  disk        = each.value.id
  instance    = google_compute_instance.node[each.key].id
  zone        = each.value.zone
  device_name = "cassandra-data"

  # A separate resource rather than an attached_disk block on the instance, so
  # detaching or resizing the disk does not require touching the instance.
}
