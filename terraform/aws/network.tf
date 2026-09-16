# ===========================================================================
# Networking -- bring your own, or create
# ===========================================================================
#
# Every resource here is behind a `create_*` boolean that defaults to FALSE.
# The common production case is an account that already has a VPC, subnets and
# centrally-managed security groups, so the default behaviour of this stack is
# to CREATE NOTHING and only place instances.
#
# The rules are written out in full even when this stack does not create them,
# so a network team has an exact specification to reproduce.

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  count = var.create_vpc ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = var.name_prefix })
}

# Private subnets, one per availability zone.
#
# ORDER IS LOAD-BEARING. locals.tf picks a subnet by rack index
# (element(local.subnet_ids, i - 1)), so rack N lands in AZ N. That is the
# whole mechanism by which NetworkTopologyStrategy's rack-awareness turns into
# real availability-zone separation of replicas. Shuffle this list and replicas
# quietly share an AZ while `nodetool status` still shows different racks.
resource "aws_subnet" "this" {
  count = var.create_vpc ? length(var.availability_zones) : 0

  vpc_id            = aws_vpc.this[0].id
  availability_zone = var.availability_zones[count.index]

  # Carved out of the VPC CIDR rather than hand-maintained. var.subnet_newbits
  # defaults to 4, i.e. a /20 per AZ out of a /16 -- 4094 usable addresses,
  # enough for a large cluster.
  cidr_block = cidrsubnet(var.vpc_cidr, var.subnet_newbits, count.index)

  # No public IPs. Nothing in this estate needs an inbound route from the
  # internet, and the CA port least of all.
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-${var.availability_zones[count.index]}"
    Tier = "private"
  })
}

# ---------------------------------------------------------------------------
# Egress
# ---------------------------------------------------------------------------
# The instances have no public IP, so they need SOME egress path to install the
# Puppet agent from apt.puppet.com and Cassandra from its repository.
#
# WITH NO NAT AND NO MIRROR, FIRST BOOT HANGS installing the agent. It looks
# exactly like a user-data bug and is not -- so if a fresh node never appears
# on the master, check egress before reading the script.
resource "aws_internet_gateway" "this" {
  count = var.create_vpc && var.create_nat_gateway ? 1 : 0

  vpc_id = aws_vpc.this[0].id
  tags   = merge(local.common_tags, { Name = "${var.name_prefix}-igw" })
}

# One public subnet to host the NAT gateway. Carved from the TOP of the VPC
# CIDR so it cannot collide with the private subnets, which are allocated
# upwards from 0. The last index at this prefix length is
# 2^subnet_newbits - 1, derived rather than written as a literal so changing
# subnet_newbits does not silently overlap a private subnet.
resource "aws_subnet" "nat" {
  count = var.create_vpc && var.create_nat_gateway ? 1 : 0

  vpc_id                  = aws_vpc.this[0].id
  availability_zone       = var.availability_zones[0]
  cidr_block              = cidrsubnet(var.vpc_cidr, var.subnet_newbits, pow(2, var.subnet_newbits) - 1)
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-nat"
    Tier = "public"
  })
}

resource "aws_eip" "nat" {
  count      = var.create_vpc && var.create_nat_gateway ? 1 : 0
  domain     = "vpc"
  tags       = merge(local.common_tags, { Name = "${var.name_prefix}-nat" })
  depends_on = [aws_internet_gateway.this]
}

# A SINGLE NAT gateway, in one AZ, and that is a deliberate trade worth
# stating: it is cheaper, and it is a single point of failure for egress. If
# that AZ goes, nodes elsewhere cannot reach the package repositories --
# which does NOT stop a running Cassandra node or a Puppet run against an
# already-installed agent, but does stop a NEW node from building.
#
# For production egress-critical estates, create one NAT per AZ and one route
# table per subnet. Left as one here because the alternative doubles a
# per-hour cost for a failure mode that delays a build rather than causing an
# outage.
resource "aws_nat_gateway" "this" {
  count = var.create_vpc && var.create_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.nat[0].id
  tags          = merge(local.common_tags, { Name = var.name_prefix })
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  count = var.create_vpc && var.create_nat_gateway ? 1 : 0

  vpc_id = aws_vpc.this[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }
  tags = merge(local.common_tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_route_table_association" "public" {
  count = var.create_vpc && var.create_nat_gateway ? 1 : 0

  subnet_id      = aws_subnet.nat[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table" "private" {
  count = var.create_vpc ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  # Only when a NAT exists. A private route table with no default route is the
  # correct shape for an estate served entirely by an internal mirror and VPC
  # endpoints.
  dynamic "route" {
    for_each = var.create_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[0].id
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-private" })
}

resource "aws_route_table_association" "private" {
  count = var.create_vpc ? length(aws_subnet.this) : 0

  subnet_id      = aws_subnet.this[count.index].id
  route_table_id = aws_route_table.private[0].id
}

# ---------------------------------------------------------------------------
# Security group
# ---------------------------------------------------------------------------
# Default false: security groups are usually centrally managed. The rules below
# are the complete set this estate needs, so they can be reproduced exactly.
#
# SELF-REFERENTIAL, not CIDR-based. Every internode rule is scoped to members
# of this same group, so the blast radius of the rule is "machines in this
# estate" rather than "anything in the subnet". A CIDR rule on 7000 lets
# anything that gets an address in the VPC join the gossip ring.
resource "aws_security_group" "node" {
  count = var.create_security_group ? 1 : 0

  name_prefix = "${var.name_prefix}-node-"
  description = "Puppet-managed Cassandra estate: internode, CQL, JMX, agent"
  vpc_id      = local.vpc_id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-node" })

  lifecycle {
    # A security group cannot be deleted while an ENI uses it, so replacing one
    # in place deadlocks. name_prefix + create_before_destroy is the documented
    # way out.
    create_before_destroy = true
  }
}

# --- Egress ----------------------------------------------------------------
# Wide open outbound. Narrowing this is worthwhile and is left to the operator
# because the correct answer is site-specific: it depends on whether you use
# apt.puppet.com or a mirror, and whether Secrets Manager is reached over a VPC
# endpoint or the internet. A too-narrow egress rule here would break the
# build in a way that looks like a user-data bug.
resource "aws_vpc_security_group_egress_rule" "all" {
  count = var.create_security_group ? 1 : 0

  security_group_id = aws_security_group.node[0].id
  description       = "All egress: package repos, Secrets Manager, SSM"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Puppet agent -> master ------------------------------------------------
# 8140 within the estate. Also needed BY the master (it runs an agent against
# itself), which the self-reference covers.
resource "aws_vpc_security_group_ingress_rule" "puppet" {
  count = var.create_security_group ? 1 : 0

  security_group_id            = aws_security_group.node[0].id
  description                  = "Puppet agent -> Puppet Server"
  from_port                    = local.ports.puppet
  to_port                      = local.ports.puppet
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.node[0].id
}

# --- Cassandra internode ---------------------------------------------------
# 7000 cleartext, 7001 TLS. BOTH are opened because which one is live is a
# Hiera decision (profile_cassandra_pfpt::ssl_enabled), and a security group
# that disagrees with Hiera produces a cluster that forms and then silently
# fails to gossip -- nodes show as DN with nothing in the logs but timeouts.
resource "aws_vpc_security_group_ingress_rule" "internode" {
  count = var.create_security_group ? 1 : 0

  security_group_id            = aws_security_group.node[0].id
  description                  = "Cassandra internode (${local.ports.cassandra_internode} plain, ${local.ports.cassandra_internode_tls} TLS)"
  from_port                    = local.ports.cassandra_internode
  to_port                      = local.ports.cassandra_internode_tls
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.node[0].id
}

# --- JMX -------------------------------------------------------------------
# nodetool. Estate-internal only, never widened: JMX is remote code execution
# by design.
resource "aws_vpc_security_group_ingress_rule" "jmx" {
  count = var.create_security_group ? 1 : 0

  security_group_id            = aws_security_group.node[0].id
  description                  = "JMX / nodetool -- estate-internal only"
  from_port                    = local.ports.cassandra_jmx
  to_port                      = local.ports.cassandra_jmx
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.node[0].id
}

# --- CQL, within the estate ------------------------------------------------
# The nodes need this from each other: the module lays down schema and rotates
# the superuser password over CQL, and cluster-health.sh probes it.
resource "aws_vpc_security_group_ingress_rule" "cql_internal" {
  count = var.create_security_group ? 1 : 0

  security_group_id            = aws_security_group.node[0].id
  description                  = "CQL between estate members (schema, health)"
  from_port                    = local.ports.cassandra_cql
  to_port                      = local.ports.cassandra_cql
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.node[0].id
}

# --- CQL, for applications -------------------------------------------------
# One rule per client security group. By GROUP, never by CIDR: the module
# manages its own schema over CQL with a superuser, so anything that can reach
# 9042 and guess the password owns the cluster.
resource "aws_vpc_security_group_ingress_rule" "cql_clients" {
  for_each = var.create_security_group ? toset(var.cql_client_security_group_ids) : toset([])

  security_group_id            = aws_security_group.node[0].id
  description                  = "CQL from application security group ${each.value}"
  from_port                    = local.ports.cassandra_cql
  to_port                      = local.ports.cassandra_cql
  ip_protocol                  = "tcp"
  referenced_security_group_id = each.value
}

# --- Jenkins HTTP, for operators -------------------------------------------
# Not an estate-internal rule: the audience is a browser, so the sources are
# whatever fronts it -- a load balancer's group, or a VPN/bastion group. By
# GROUP, never by CIDR, and never 0.0.0.0/0: Jenkins runs arbitrary commands
# against the Cassandra fleet through cassy, so reaching this port is
# equivalent to shell on every node.
#
# Empty by default, which means NO RULE and therefore no access. Deliberate:
# an unreachable Jenkins is a nuisance, and a reachable one that nobody
# decided to expose is an incident.
resource "aws_vpc_security_group_ingress_rule" "jenkins_http" {
  for_each = var.create_security_group ? toset(var.jenkins_client_security_group_ids) : toset([])

  security_group_id            = aws_security_group.node[0].id
  description                  = "Jenkins HTTP from ${each.value}"
  from_port                    = local.ports.jenkins_http
  to_port                      = local.ports.jenkins_http
  ip_protocol                  = "tcp"
  referenced_security_group_id = each.value
}
