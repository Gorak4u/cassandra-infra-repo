# ===========================================================================
# Expand the inventory -- the single source of truth for both provisioners
# ===========================================================================
#
# Reads the SAME YAML the local Docker driver reads, so `count: 100` in the
# inventory produces 100 instances here and 100 rows from
# `bin/expand-inventory.py`, with no second list to keep in step.
#
# ONE STACK PER DATACENTRE, for the same reason as GCP: an AWS datacentre is a
# REGION, a provider is configured for one region, and a single plan that can
# destroy two regions at once is a bad afternoon.

locals {
  inventory_root = "${path.module}/../../inventory"
  defaults_file  = "${local.inventory_root}/defaults.yaml"
  env_file       = "${local.inventory_root}/customers/${var.customer}/${var.environment}.yaml"

  defaults = yamldecode(file(local.defaults_file))
  inv      = yamldecode(file(local.env_file))

  domain            = coalesce(var.dns_domain, try(local.inv.domain, null), local.defaults.domain)
  default_os        = coalesce(try(local.inv.os, null), local.defaults.os)
  serialize_default = try(local.defaults.serialize_by_default, true)
  inventory_dc      = local.inv.datacenter
  target_dc         = coalesce(var.datacenter, local.inventory_dc)

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

  # --- Ring join serialisation ----------------------------------------------
  # How long a node waits for the previous node's CQL port before joining the
  # ring anyway. Same precedence as ports: tfvars > customer env file >
  # defaults.yaml. See inventory/defaults.yaml for why the value matters --
  # too low and every node behind a slow bootstrap starts its own, which is
  # exactly what the wait_for chain exists to prevent.
  bootstrap_wait_timeout = coalesce(
    var.bootstrap_wait_timeout,
    try(local.inv.bootstrap_wait_timeout, null),
    try(local.defaults.bootstrap_wait_timeout, null),
    900,
  )

  # --- Control repo ---------------------------------------------------------
  # Precedence: tfvars > customer+environment yaml > defaults.yaml.
  # Follows the same layering as ports and domain, so one inventory YAML
  # drives all three drivers (Docker, GCP, AWS) without duplication.
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

  # products -> clusters -> datacentres -> N nodes.
  #
  # A cluster is EITHER single-DC (count/seed_count at the cluster level) or
  # spans several via a `datacenters:` block. try(a, b, default) is the HCL
  # equivalent of the expander's opt(): datacentre spec first, then cluster
  # spec, then a default.
  #
  # WHY THIS IS TWO FILTERED LISTS AND A concat(), NOT A CONDITIONAL
  # ----------------------------------------------------------------
  # Normalising the two shapes with a ternary is the obvious approach and it
  # does not work -- HCL requires both arms of a conditional to unify to one
  # type:
  #
  #   Error: Inconsistent conditional result types
  #   Type mismatch for object attribute "dc_east": The 'true' value includes
  #   object attribute "count", which is absent in the 'false' value.
  #
  # Giving both arms identical attribute sets does not rescue it either: they
  # are also tuples of different lengths (one entry per datacentre, versus
  # exactly one), and those do not unify. `concat` has no such requirement.
  #
  # THIS GOT PAST `terraform validate` in BOTH stacks. `validate` checks syntax
  # and provider schemas and never evaluates locals against the actual
  # inventory YAML, so it stayed green while `terraform console` and `plan`
  # failed -- and it only became reachable once a cluster in the inventory
  # actually grew a `datacenters:` block. A green validate is not evidence that
  # the inventory expands.
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
          # Optional per-cluster AZ list; [] means "use the stack's
          # var.availability_zones in list order". See the note on subnet_id.
          azs    = try(dcspec.availability_zones, cspec.availability_zones, [])
          sizing = try(dcspec.sizing, cspec.sizing)
          os     = try(dcspec.os, cspec.os, local.default_os)
          # "" rather than null for "not set": an all-null column has no type.
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
          azs         = try(cspec.availability_zones, [])
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

        role = d.role != "" ? d.role : (
          i <= d.seed_count ? "${d.product}_seed" : "${d.product}_node"
        )

        # Rack picks the SUBNET by the same index, and a subnet is in one
        # availability zone -- which is what makes replicas land in different
        # AZs. The rack reaches Cassandra through cassandra-rackdc.properties,
        # and NetworkTopologyStrategy keeps replicas in different racks.
        rack = element(d.racks, i - 1)

        # subnet_ids_safe, not subnet_ids: `element` on an EMPTY list is a hard
        # error during locals evaluation, which happens BEFORE any resource
        # precondition can produce a readable message. The placeholder keeps
        # evaluation alive just long enough for aws_instance.node's
        # precondition to say what is actually wrong.
        # Round-robin either way: `element` indexes MODULO the list length, so
        # six nodes over three zones land a,b,c,a,b,c and rack N lines up with
        # zone N. That wrap is the whole mechanism -- there is no per-node
        # placement anywhere in this repo.
        #
        # With a per-cluster `availability_zones` the node picks its ZONE first
        # and then the subnet in it, so the cluster's placement no longer
        # depends on the order of var.availability_zones. Without one it falls
        # back to indexing the stack's subnet list directly, which is the
        # original behaviour and what every other product still does.
        #
        # The lookup default is a sentinel rather than an error: an unknown key
        # would fail during locals evaluation, which happens BEFORE any
        # precondition can run, and the message would name neither the cluster
        # nor the zone. aws_instance.node's precondition turns it into a
        # readable one.
        subnet_id = length(d.azs) > 0 ? lookup(
          local.subnet_by_az, element(d.azs, i - 1), "AZ-NOT-IN-THIS-VPC"
        ) : element(local.subnet_ids_safe, i - 1)

        sizing = d.sizing
        instance_type = coalesce(
          var.instance_type_override,
          local.defaults.sizing[d.sizing].aws_instance_type,
        )
        ram_mb = local.defaults.sizing[d.sizing].ram_mb

        os = d.os

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
  # which is what an operator states per stack, and aws_instance.node's
  # precondition rejects a node left with neither.
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
  # The SAME four fragments the local driver assembles. Only fragment 2
  # differs -- 10-metadata-aws.sh instead of 10-metadata-local.sh -- and that
  # is the entire cost of running on EC2.
  userdata_dir = "${path.module}/../../user-data"

  role_fragment = {
    puppetmaster   = "30-role-puppetmaster.sh"
    cassandra_seed = "30-role-cassandra-node.sh"
    cassandra_node = "30-role-cassandra-node.sh"
    jenkins        = "30-role-jenkins.sh"
  }

  user_data = {
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
      file("${local.userdata_dir}/10-metadata-aws.sh"),
      file("${local.userdata_dir}/20-common.sh"),
      file("${local.userdata_dir}/${local.role_fragment[n.role]}"),
    ]), "\r\n", "\n")
  }

  # --- Resolved identifiers ----------------------------------------------
  vpc_id = var.create_vpc ? aws_vpc.this[0].id : var.vpc_id

  subnet_ids = var.create_vpc ? (
    [for s in aws_subnet.this : s.id]
  ) : var.subnet_ids

  # See the note on subnet_id in node_list above.
  subnet_ids_safe = length(local.subnet_ids) > 0 ? local.subnet_ids : ["SUBNETS-NOT-CONFIGURED"]

  # Zone -> subnet, for clusters that name their own availability_zones.
  #
  # EMPTY when create_vpc = false, and that is not a gap that can be closed
  # here: subnet_ids are then opaque strings supplied by the caller, and this
  # module has no data source to ask which zone each one is in. A cluster that
  # names zones in that mode gets the sentinel and a precondition failure
  # telling it so, which beats placing nodes in the wrong zones silently.
  subnet_by_az = var.create_vpc ? {
    for s in aws_subnet.this : s.availability_zone => s.id
  } : {}

  security_group_ids = var.create_security_group ? (
    concat([aws_security_group.node[0].id], var.security_group_ids)
  ) : var.security_group_ids

  instance_profile = var.create_iam_role ? (
    aws_iam_instance_profile.node[0].name
  ) : var.iam_instance_profile

  common_tags = merge({
    ManagedBy   = "terraform"
    Stack       = var.name_prefix
    Customer    = var.customer
    Environment = var.environment
    Datacenter  = local.target_dc
  }, var.tags)
}
