# ===========================================================================
# Expand the inventory -- the single source of truth for both provisioners
# ===========================================================================
#
# Reads the SAME YAML the local Docker driver reads:
#
#   infra/inventory/defaults.yaml
#   infra/inventory/customers/<customer>/<environment>.yaml
#
# so `count: 100` in that file produces 100 instances here and 100 rows from
# `bin/expand-inventory.py`, with no second list to keep in step. That is the
# reason the inventory is YAML rather than the bespoke table it started as.
#
# Nothing here is hand-enumerated. Names, roles, racks and zones are derived,
# by the same rules the Python expander uses -- and `make check` in the README
# diffs the two to prove they agree.
#
# ONE STACK PER DATACENTRE
# ------------------------
# A cluster's `datacenters:` block may name several sites, but a GCP datacentre
# is a REGION, and a provider is configured for one region. So this stack
# builds ONE datacentre, selected by var.datacenter, and multi-region means
# running it once per region with its own state.
#
# That is not a limitation being worked around -- separate state per region is
# what you want anyway. A single plan that can destroy two regions at once is
# a bad afternoon.

locals {
  inventory_root = "${path.module}/../../inventory"
  defaults_file  = "${local.inventory_root}/defaults.yaml"
  env_file       = "${local.inventory_root}/customers/${var.customer}/${var.environment}.yaml"

  defaults = yamldecode(file(local.defaults_file))
  inv      = yamldecode(file(local.env_file))

  # Precedence: tfvars > the environment file > defaults.yaml. The same shape
  # as the Hiera hierarchy, so the mental model carries over.
  domain            = coalesce(var.dns_domain, try(local.inv.domain, null), local.defaults.domain)
  default_os        = coalesce(try(local.inv.os, null), local.defaults.os)
  serialize_default = try(local.defaults.serialize_by_default, true)
  inventory_dc      = local.inv.datacenter

  # Which datacentre this stack builds. Defaults to the environment file's
  # top-level `datacenter`, which is correct for a single-DC estate.
  target_dc = coalesce(var.datacenter, local.inventory_dc)

  # --- Ports --------------------------------------------------------------
  # From the INVENTORY, not from here. They have to agree with Hiera's
  # profile_cassandra_pfpt::native_transport_port and with the health checks in
  # provision.sh and the user-data fragments, and four hardcoded copies of the
  # same number is how that stops being true. See inventory/defaults.yaml.
  #
  # Precedence, same shape as every other value: tfvars > the customer's
  # environment file > defaults.yaml. var.ports defaults to {} so it changes
  # nothing unless someone sets it.
  ports = merge(
    local.defaults.ports,
    try(local.inv.ports, {}),
    var.ports,
  )

  # --- Control repo ---------------------------------------------------------
  # Precedence: tfvars > customer+environment yaml > defaults.yaml.
  # Follows the same layering as ports and domain, so one inventory YAML
  # drives all three drivers (Docker, GCP, AWS) without duplication.
  #
  # try(coalesce(...), "") collapses to "" when nothing sets it -- non-master
  # stacks (cassandra-only) legitimately have no URL.
  control_repo_url = try(coalesce(
    var.control_repo_url,
    try(local.inv.control_repo_url, null),
    try(local.defaults.control_repo_url, null),
  ), "")

  control_repo_deploy_key_secret_id = (
    var.control_repo_deploy_key_secret_id != null ? var.control_repo_deploy_key_secret_id :
    try(local.inv.control_repo_deploy_key_secret_id,
    try(local.defaults.control_repo_deploy_key_secret_id, null))
  )

  wanted_products = length(var.products) > 0 ? var.products : keys(local.inv.products)

  # --- Which master a node talks to ---------------------------------------
  # The two BROAD layers, in the same precedence order bin/expand-inventory.py
  # uses, so one inventory answers this question identically for Docker, EC2
  # and GCE. The narrow layers (product, cluster, datacentre) are picked up in
  # dc_specs_* below; the per-node resolution is in node_list.
  #
  # Full precedence, highest first:
  #   datacenters.<dc>.puppet_server
  #   clusters.<c>.puppet_server
  #   products.<p>.puppet_server        <- one product, one master
  #   <envfile>.puppet_server
  #   defaults.yaml puppet.server
  #   var.puppet_server                 <- this stack's fallback
  #   the node's own certname, for a puppetmaster
  #
  # "" means "nothing stated": an all-null column has no type in HCL.
  puppet_server_broad = try(local.inv.puppet_server, local.defaults.puppet.server, "")

  # --- Expansion ---------------------------------------------------------
  # products -> clusters -> datacentres -> N nodes.
  #
  # A cluster is EITHER single-DC (count/seed_count at the cluster level, using
  # the file's `datacenter`) or spans several via a `datacenters:` block. The
  # single-DC form is normalised into a one-entry map so there is one code path
  # rather than two that drift -- exactly what expand-inventory.py does.
  #
  # try(a, b, default) is the HCL equivalent of the expander's opt(): the
  # datacentre spec wins, then the cluster spec, then a default. So `sizing`
  # and `serialize` can be stated once per cluster while `count`, `ip_offset`
  # and `racks` differ per datacentre.
  #
  # WHY THIS IS TWO FILTERED LISTS AND A concat(), NOT A CONDITIONAL
  # ----------------------------------------------------------------
  # The obvious way to unify the two cluster shapes is a ternary:
  #
  #   for dc_name, dcspec in (
  #     try(cspec.datacenters, null) != null
  #     ? cspec.datacenters
  #     : { (local.inventory_dc) = cspec }
  #   )
  #
  # It reads well and it does not work:
  #
  #   Error: Inconsistent conditional result types
  #   Type mismatch for object attribute "dc_east": The 'true' value includes
  #   object attribute "count", which is absent in the 'false' value.
  #
  # HCL requires both arms of a conditional to unify to one type, and a map of
  # datacentre specs is not the same type as a map holding a cluster spec.
  # Normalising both arms to identical attribute sets does not rescue it
  # either: the arms are also tuples of DIFFERENT LENGTHS (one entry per
  # datacentre, versus exactly one), and those do not unify.
  #
  # `concat` has no such requirement, so the two shapes are collected
  # separately by a filter and joined. The precedence is resolved here rather
  # than deeper in, which also means node_list below reads one flat shape.
  #
  # THIS GOT PAST `terraform validate`. Worth knowing, because it is the whole
  # reason to distrust a green validate: `validate` checks syntax and provider
  # schemas, and never evaluates locals against the actual inventory YAML. It
  # surfaced only on `terraform console` / `plan`, and only once a cluster in
  # the inventory actually grew a `datacenters:` block.
  dc_specs_multi = flatten([
    for product, pspec in local.inv.products : [
      for cluster, cspec in pspec.clusters : [
        for dc_name, dcspec in cspec.datacenters : {
          product     = product
          cluster     = cluster
          datacenter  = dc_name
          count       = try(dcspec.count, cspec.count)
          name_prefix = try(dcspec.name_prefix, cspec.name_prefix, cluster)
          seed_count  = try(dcspec.seed_count, cspec.seed_count, 0)
          racks       = try(dcspec.racks, cspec.racks, ["rack1"])
          sizing      = try(dcspec.sizing, cspec.sizing)
          os          = try(dcspec.os, cspec.os, local.default_os)
          # "" rather than null for "not set": null forces the attribute's type
          # to be inferred from another entry, and an all-null column has no
          # type at all.
          role      = try(dcspec.role, cspec.role, "")
          serialize = try(dcspec.serialize, cspec.serialize, local.serialize_default)

          puppet_server = try(
            dcspec.puppet_server, cspec.puppet_server, pspec.puppet_server,
            local.puppet_server_broad,
          )
        }
      ] if try(cspec.datacenters, null) != null
    ] if contains(local.wanted_products, product)
  ])

  dc_specs_single = flatten([
    for product, pspec in local.inv.products : [
      for cluster, cspec in pspec.clusters : [
        {
          product     = product
          cluster     = cluster
          datacenter  = local.inventory_dc
          count       = cspec.count
          name_prefix = try(cspec.name_prefix, cluster)
          seed_count  = try(cspec.seed_count, 0)
          racks       = try(cspec.racks, ["rack1"])
          sizing      = cspec.sizing
          os          = try(cspec.os, local.default_os)
          role        = try(cspec.role, "")
          serialize   = try(cspec.serialize, local.serialize_default)

          puppet_server = try(
            cspec.puppet_server, pspec.puppet_server, local.puppet_server_broad,
          )
        }
      ] if try(cspec.datacenters, null) == null
    ] if contains(local.wanted_products, product)
  ])

  dc_specs = [
    for d in concat(local.dc_specs_multi, local.dc_specs_single) : d
    if d.datacenter == local.target_dc &&
    (length(var.clusters) == 0 || contains(var.clusters, d.cluster))
  ]

  node_list_raw = flatten([
    for d in local.dc_specs : [
      for i in range(1, d.count + 1) : {
        # The instance name IS the certname stem. GCE names must be RFC1035
        # (lower case, no dots), so the bare name goes on the instance and the
        # FQDN travels as metadata -- see instances.tf.
        name     = "${d.name_prefix}${i}"
        certname = "${d.name_prefix}${i}.${local.domain}"

        # Whatever the inventory stated, unresolved. Finished in node_list
        # below, which needs `role` and `certname` -- and an object literal
        # cannot reference its own attributes.
        puppet_server_inv = d.puppet_server

        product    = d.product
        cluster    = d.cluster
        datacenter = d.datacenter
        index      = i

        # Either an explicit role for the whole cluster, or the first
        # seed_count nodes are seeds.
        role = d.role != "" ? d.role : (
          i <= d.seed_count ? "${d.product}_seed" : "${d.product}_node"
        )

        # Racks round-robin, and the rack picks the ZONE by the same index.
        # That is what makes replicas land in different zones: the rack reaches
        # Cassandra through cassandra-rackdc.properties, and
        # NetworkTopologyStrategy keeps replicas in different racks.
        rack = element(d.racks, i - 1)
        zone = element(var.zones, i - 1)

        sizing = d.sizing
        machine_type = coalesce(
          var.machine_type_override,
          local.defaults.sizing[d.sizing].gcp_machine_type,
        )
        ram_mb = local.defaults.sizing[d.sizing].ram_mb

        os = d.os

        # Serialised ring joins, within a datacentre. A linear chain is correct
        # for a handful of nodes and wrong at scale -- 100 nodes is a multi-hour
        # serial build and one dead node wedges the rest forever. See the note
        # in instances.tf for the lock alternative.
        # PER-DATACENTRE, unavoidably: one datacentre is one stack with its
        # own state, so this chain cannot reference a node in another. But
        # Cassandra's refusal to bootstrap concurrently is CLUSTER-WIDE, so
        # applying two datacentre stacks of one cluster at the same time
        # breaks a node with "Other bootstrapping/leaving/moving nodes
        # detected" -- observed for real on the local driver, which does build
        # every datacentre at once and now chains across them.
        #
        # Here the guarantee is operational: apply one datacentre, wait for UN,
        # then the next. Stated in guides/08 and in the next_steps output.
        wait_for = d.serialize && i > 1 ? "${d.name_prefix}${i - 1}.${local.domain}" : ""
      }
    ]
  ])

  # Finish the master resolution now that role and certname are known.
  #
  # NOTE THE DIFFERENCE FROM THE LOCAL DRIVER, and it is not an oversight:
  # bin/expand-inventory.py can fall back to "the puppetmaster in this
  # expansion" because it sees the whole customer at once. A stack here sees
  # ONE datacentre of one slice and usually contains no master at all -- the
  # master is built once, separately. So the fallback is var.puppet_server,
  # which is what an operator states per stack, and
  # google_compute_instance.node's precondition rejects a node left with
  # neither.
  node_list = [
    for n in local.node_list_raw : merge(n, {
      puppet_server = (
        n.puppet_server_inv != "" ? n.puppet_server_inv :
        n.role == "puppetmaster" ? n.certname :
        var.puppet_server != null ? var.puppet_server : ""
      )
    })
  ]

  nodes = { for n in local.node_list : n.name => n }

  # --- User-data ---------------------------------------------------------
  # The SAME four fragments the local driver assembles, in the same order.
  # Only fragment 2 differs -- 10-metadata-gcp.sh instead of
  # 10-metadata-local.sh -- and that is the entire cost of running on GCE.
  #
  # No templating: the fragments take no Terraform variables. Everything a node
  # needs to know arrives as instance metadata, which is what keeps the script
  # byte-identical across platforms and reviewable on its own.
  userdata_dir = "${path.module}/../../user-data"

  role_fragment = {
    puppetmaster   = "30-role-puppetmaster.sh"
    cassandra_seed = "30-role-cassandra-node.sh"
    cassandra_node = "30-role-cassandra-node.sh"
    jenkins        = "30-role-jenkins.sh"
  }

  startup_script = {
    # replace() strips carriage returns, and it is not paranoia. A checkout on
    # Windows with core.autocrlf=true rewrites these fragments with CRLF, file()
    # reads them verbatim, and the node then boots into
    #
    #   line 56: $'\r': command not found
    #   line 84: syntax error near unexpected token `$'{\r''
    #
    # .gitattributes pins these files to LF so it should not arise, but that
    # only governs a checkout of THIS repo with THAT file present. A tarball, an
    # editor that "helpfully" converts on save, or a clone taken before the
    # attribute landed all reach here the same way -- and the failure surfaces
    # on a booting instance rather than at plan time, which is the expensive
    # place to find it. One function call makes the whole class impossible.
    for name, n in local.nodes : name => replace(join("\n", [
      file("${local.userdata_dir}/00-prelude.sh"),
      file("${local.userdata_dir}/10-metadata-gcp.sh"),
      file("${local.userdata_dir}/20-common.sh"),
      file("${local.userdata_dir}/${local.role_fragment[n.role]}"),
    ]), "\r\n", "\n")
  }

  # --- Resolved identifiers ----------------------------------------------
  # One place that decides between "the thing we created" and "the thing that
  # already existed", so nothing downstream has to branch.
  network_id = var.create_network ? (
    google_compute_network.this[0].id
  ) : data.google_compute_network.existing[0].id

  network_self_link = var.create_network ? (
    google_compute_network.this[0].self_link
  ) : data.google_compute_network.existing[0].self_link

  subnetwork_id = var.create_network ? (
    google_compute_subnetwork.this[0].id
  ) : data.google_compute_subnetwork.existing[0].id

  service_account = var.create_service_account ? (
    google_service_account.node[0].email
  ) : var.service_account_email

  # --- Network tags ------------------------------------------------------
  # Firewall rules key on these rather than on CIDRs, so a rule follows the
  # machine's role instead of its address.
  estate_tag       = var.name_prefix
  cassandra_tag    = "${var.name_prefix}-cassandra"
  puppetmaster_tag = "${var.name_prefix}-puppetmaster"
  jenkins_tag      = "${var.name_prefix}-jenkins"

  product_tag = {
    cassandra    = local.cassandra_tag
    puppetmaster = local.puppetmaster_tag
    jenkins      = local.jenkins_tag
  }

  common_labels = merge({
    managed_by  = "terraform"
    stack       = var.name_prefix
    customer    = var.customer
    environment = var.environment
    datacenter  = local.target_dc
  }, var.labels)
}
