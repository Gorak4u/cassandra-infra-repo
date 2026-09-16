# ===========================================================================
# Networking -- bring your own, or create
# ===========================================================================
#
# Every resource here is behind a `create_*` flag defaulting to FALSE, because
# in a real project the VPC, subnetwork, NAT and firewall policy belong to a
# networking team with its own change process. Terraform that insists on
# creating them is unusable there.
#
# The pattern throughout: a `resource` with `count = var.create_x ? 1 : 0`, a
# `data` source with the inverse, and a local in locals.tf that picks whichever
# exists -- so nothing downstream has to know which way it went.

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
data "google_compute_network" "existing" {
  count = var.create_network ? 0 : 1
  name  = var.network_name
}

resource "google_compute_network" "this" {
  count = var.create_network ? 1 : 0

  name    = coalesce(var.network_name, "${var.name_prefix}-vpc")
  project = var.project_id

  # Custom mode, not auto. Auto mode creates a subnetwork in EVERY region with
  # predefined ranges, which collides with almost any existing addressing plan
  # and cannot be undone without recreating the VPC.
  auto_create_subnetworks = false

  # Left at the default (regional). Global routing is a deliberate,
  # hard-to-reverse choice about how subnets learn each other's routes.
  routing_mode = "REGIONAL"

  description = "Puppet-managed estate: ${var.customer}/${var.environment}"
}

data "google_compute_subnetwork" "existing" {
  count  = var.create_network ? 0 : 1
  name   = var.subnetwork_name
  region = var.region
}

resource "google_compute_subnetwork" "this" {
  count = var.create_network ? 1 : 0

  name          = coalesce(var.subnetwork_name, "${var.name_prefix}-subnet")
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.this[0].id
  ip_cidr_range = var.subnetwork_cidr

  # Private Google Access, so instances with no external IP can still reach
  # Secret Manager and the metadata-adjacent Google APIs. WITHOUT this, the
  # join-secret lookup in 10-metadata-gcp.sh fails on a node that has no
  # external IP and no NAT -- and it fails as a timeout, which reads as a
  # network problem rather than a missing setting.
  private_ip_google_access = true

  # VPC flow logs. On by default here because this subnet carries a CA and a
  # database; sampled at 0.5 to keep the cost sane.
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ---------------------------------------------------------------------------
# Cloud NAT -- egress for instances with no external IP
# ---------------------------------------------------------------------------
# The instances deliberately have no external IP (see instances.tf), so they
# need SOME egress path to install the Puppet agent from apt.puppet.com and
# Cassandra from its repository.
#
# If you set create_nat = false and the project has no NAT, first boot HANGS
# installing the agent. That looks like a user-data bug and is not -- it is a
# missing route. An internal package mirror removes the need entirely, but
# then the Hiera repo_baseurl must point at that mirror.
resource "google_compute_router" "this" {
  count = var.create_nat ? 1 : 0

  name    = "${var.name_prefix}-router"
  project = var.project_id
  region  = var.region
  network = local.network_id
}

resource "google_compute_router_nat" "this" {
  count = var.create_nat ? 1 : 0

  name    = "${var.name_prefix}-nat"
  project = var.project_id
  region  = var.region
  router  = google_compute_router.this[0].name

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
# Documented here even when create_firewall_rules is false, so a network team
# has an exact specification to reproduce rather than a description.
#
# Every rule is scoped by TAG on both sides. None of these ports may be
# reachable from outside the estate -- 7199 in particular is unauthenticated
# JMX in a default Cassandra install, which is remote code execution to
# anything that can reach it.

resource "google_compute_firewall" "puppet_agent" {
  count = var.create_firewall_rules ? 1 : 0

  name        = "${var.name_prefix}-agent-to-master"
  project     = var.project_id
  network     = local.network_self_link
  description = "Puppet agents to the CA and compile master"
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = [tostring(local.ports.puppet)]
  }

  source_tags = [local.estate_tag]
  target_tags = [local.puppetmaster_tag]
}

resource "google_compute_firewall" "cassandra_internode" {
  count = var.create_firewall_rules ? 1 : 0

  name        = "${var.name_prefix}-cassandra-internode"
  project     = var.project_id
  network     = local.network_self_link
  description = "Cassandra gossip (7000), TLS gossip (7001) and JMX (7199) -- cluster members only"
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports = [
      tostring(local.ports.cassandra_internode),
      tostring(local.ports.cassandra_internode_tls),
      tostring(local.ports.cassandra_jmx),
    ]
  }

  # Both sides are the cassandra tag. Widening the source here is how JMX ends
  # up exposed.
  source_tags = [local.cassandra_tag]
  target_tags = [local.cassandra_tag]
}

resource "google_compute_firewall" "cassandra_cql" {
  count = var.create_firewall_rules ? 1 : 0

  name        = "${var.name_prefix}-cassandra-cql"
  project     = var.project_id
  network     = local.network_self_link
  description = "CQL (9042) -- cluster members plus any explicitly allowed client tags"
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = [tostring(local.ports.cassandra_cql)]
  }

  # Cluster members can always reach each other: the module manages its own
  # schema over CQL. Application access is opt-in by tag, never by CIDR --
  # a subnet-wide rule on 9042 gives every VM in the subnet database access.
  source_tags = concat([local.cassandra_tag], var.cql_client_source_tags)
  target_tags = [local.cassandra_tag]
}

# A default-deny is NOT created here. GCP's implied rules already deny ingress
# and allow egress, so an explicit deny would only add confusion -- and a
# lower-priority deny-all interacts badly with rules owned elsewhere. If your
# estate needs egress restricted, that belongs in the centrally-managed policy
# alongside the package mirror it implies.

# --- Jenkins HTTP, for operators -------------------------------------------
# Not an estate-internal rule: the audience is a browser, so the sources are
# whatever fronts it -- a load balancer's tag, or a VPN/bastion tag. By TAG,
# never a CIDR, and never 0.0.0.0/0: Jenkins runs arbitrary commands against
# the Cassandra fleet through cassy, so reaching this port is equivalent to
# shell on every node.
#
# `count` is gated on the source list being non-empty as well as on
# create_firewall_rules, so the default creates NO RULE and therefore grants
# no access. Deliberate: an unreachable Jenkins is a nuisance, a reachable one
# nobody decided to expose is an incident.
resource "google_compute_firewall" "jenkins_http" {
  count = var.create_firewall_rules && length(var.jenkins_client_source_tags) > 0 ? 1 : 0

  name        = "${var.name_prefix}-jenkins-http"
  project     = var.project_id
  network     = local.network_self_link
  description = "Jenkins HTTP (${local.ports.jenkins_http}) from explicitly allowed tags only"
  direction   = "INGRESS"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = [tostring(local.ports.jenkins_http)]
  }

  source_tags = var.jenkins_client_source_tags
  target_tags = [local.jenkins_tag]
}
