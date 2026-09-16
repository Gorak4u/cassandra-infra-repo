# ===========================================================================
# Variables -- every one overridable from tfvars
# ===========================================================================
#
# THE CENTRAL DESIGN CHOICE: bring your own, or create.
#
# A real GCP project almost always has a VPC, a subnetwork, firewall policy and
# Cloud NAT already, owned by a networking team with its own change process.
# Terraform that insists on creating those is unusable there. Equally, a fresh
# sandbox project has none of it and you want one command.
#
# So every piece of surrounding infrastructure has a `create_*` boolean:
#
#   create_network = false  -> look the existing one up by name (the default,
#                              because it is the production case)
#   create_network = true   -> create it, once
#
# The defaults are all `false`. Creating network infrastructure should be a
# deliberate, stated act, not what happens when you forget a variable.

# ---------------------------------------------------------------------------
# Project and location
# ---------------------------------------------------------------------------
variable "project_id" {
  description = "GCP project id."
  type        = string
}

variable "region" {
  description = "GCP region for regional resources (subnetwork, NAT, router)."
  type        = string
}

variable "zones" {
  description = <<-EOT
    Zones to place instances in, round-robined by RACK.

    This is how a Cassandra cluster becomes zone-redundant: the inventory's
    `racks:` list maps positionally onto this list, the rack lands in
    cassandra-rackdc.properties, and NetworkTopologyStrategy then keeps
    replicas in different racks -- which here means different zones.

    So len(zones) should be >= len(racks), and the ORDER is significant. A
    single zone is valid for a lab and is not zone-redundant.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.zones) > 0
    error_message = "At least one zone is required."
  }
}

# ---------------------------------------------------------------------------
# Which slice of the inventory to build
# ---------------------------------------------------------------------------
variable "customer" {
  description = <<-EOT
    Customer whose inventory file to read:
    infra/inventory/customers/<customer>/<environment>.yaml

    The SAME file the local Docker driver reads. One description of the estate,
    two provisioners -- which is the whole reason the inventory is YAML rather
    than the bespoke table it started as.
  EOT
  type        = string
}

variable "environment" {
  description = "Environment within that customer (nonprod, prod, staging)."
  type        = string
}

variable "datacenter" {
  description = <<-EOT
    Which datacentre of the inventory this stack builds.

    Null (default) means the environment file's top-level `datacenter`, which
    is correct for a single-DC estate.

    ONE STACK PER DATACENTRE. A cluster's `datacenters:` block may name several
    sites, but a GCP datacentre is a REGION and a provider is configured for
    one region -- so multi-region means running this stack once per region,
    each with its own state and its own `region`/`zones`.

    That is not a workaround: separate state per region is what you want. A
    single plan that can destroy two regions at once is a bad afternoon.
  EOT
  type        = string
  default     = null
}

variable "products" {
  description = <<-EOT
    Restrict to these products, e.g. ["cassandra"]. Empty means every product
    in the inventory file.

    Useful when the Puppet master already exists (built once, separately) and
    you only want to add Cassandra nodes -- a very common real case.
  EOT
  type        = list(string)
  default     = []
}

variable "clusters" {
  description = "Restrict to these clusters. Empty means all of them."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------
variable "dns_domain" {
  description = <<-EOT
    Certname suffix. Defaults to the inventory's `domain`, so normally leave
    this null.

    Must match the Puppet master's autosign_certname_pattern in Hiera or every
    CSR is refused. Prefer a subdomain you own; '.internal' is reserved by
    ICANN for exactly this if you want a guarantee.
  EOT
  type        = string
  default     = null
}

variable "name_prefix" {
  description = <<-EOT
    Prefix for the SURROUNDING resources this stack creates (network,
    firewall, service account). Not for instances -- those are named by the
    inventory, because an instance name becomes a certname and renaming one
    means reissuing a certificate.
  EOT
  type        = string
  default     = "puppet-estate"
}

variable "labels" {
  description = "Labels applied to everything this stack creates."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Networking -- bring your own, or create
# ---------------------------------------------------------------------------
variable "create_network" {
  description = <<-EOT
    false (default): use the existing network named in `network_name`.
    true: create a custom-mode VPC and a subnetwork.

    Default false because a shared VPC owned by a networking team is the
    production norm, and creating a second one is rarely what anybody wants.
  EOT
  type        = bool
  default     = false
}

variable "network_name" {
  description = "Existing VPC name when create_network is false; the name to create when true."
  type        = string
  default     = null
}

variable "subnetwork_name" {
  description = "Existing subnetwork name when create_network is false; the name to create when true."
  type        = string
  default     = null
}

variable "subnetwork_cidr" {
  description = "Primary CIDR for the subnetwork. Only used when create_network is true."
  type        = string
  default     = "10.80.0.0/20"
}

variable "create_nat" {
  description = <<-EOT
    Create a Cloud Router and Cloud NAT for egress.

    The instances get NO external IP, so they need SOME egress path to install
    packages from apt.puppet.com and the Cassandra repository. Existing
    projects normally already have this -- hence default false. If you set this
    false and have no NAT, first boot hangs installing the Puppet agent, which
    looks like a user-data bug and is not.

    An internal package mirror removes the need entirely; if you use one,
    remember the Hiera repo_baseurl must point at it.
  EOT
  type        = bool
  default     = false
}

variable "create_firewall_rules" {
  description = <<-EOT
    Create the firewall rules this estate needs (Puppet 8140, Cassandra
    internode 7000/7001, JMX 7199, CQL 9042).

    Default false: firewall policy is usually centrally managed, and the rules
    are documented in firewall.tf so a network team can reproduce them. Set
    true in a sandbox.
  EOT
  type        = bool
  default     = false
}

variable "cql_client_source_tags" {
  description = <<-EOT
    Extra network tags allowed to reach CQL (9042), for your applications.

    Only used when create_firewall_rules is true. Cluster members can always
    reach each other. Do NOT widen 9042 to a whole subnet: the module manages
    its own schema over CQL with a superuser.
  EOT
  type        = list(string)
  default     = []
}

variable "network_tags" {
  description = "Extra network tags on every instance, for rules you manage elsewhere."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Identity -- bring your own, or create
# ---------------------------------------------------------------------------
variable "create_service_account" {
  description = <<-EOT
    false (default): use `service_account_email`.
    true: create one, with access to the join secret only.
  EOT
  type        = bool
  default     = false
}

variable "service_account_email" {
  description = "Existing service account for the instances, when create_service_account is false."
  type        = string
  default     = null
}

variable "service_account_scopes" {
  description = <<-EOT
    OAuth scopes. cloud-platform plus IAM conditions rather than narrow legacy
    scopes: scopes are the old mechanism and interact badly with IAM. The
    effective permission is whatever IAM grants -- which, for a created
    account, is one secret.
  EOT
  type        = list(string)
  default     = ["https://www.googleapis.com/auth/cloud-platform"]
}

# ---------------------------------------------------------------------------
# The join secret
# ---------------------------------------------------------------------------
variable "join_secret_id" {
  description = <<-EOT
    Secret Manager secret holding the estate join secret. Its SHA-256 must be
    in the master's Hiera as autosign_challenge_password_sha256.

    Null means no challengePassword: nodes then rely on the extension
    allowlist and the certname pattern alone. That is weaker, and deliberately
    allowed, because it is better than a secret nobody rotates.
  EOT
  type        = string
  default     = null
}

variable "join_secret_version" {
  description = "Secret version to read. 'latest' follows rotation; pin a number to freeze it."
  type        = string
  default     = "latest"
}

variable "grant_join_secret_access" {
  description = <<-EOT
    Grant the instances' service account secretAccessor on join_secret_id.

    Set false if IAM is managed elsewhere -- common where a security team owns
    all bindings. The grant is scoped to the one secret; a project-level role
    would let any node read every secret in the project.
  EOT
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Puppet
# ---------------------------------------------------------------------------
variable "puppet_server" {
  description = <<-EOT
    FALLBACK master for nodes the inventory does not assign one. The name
    agents use to reach it. Must appear in that master's dns_alt_names in
    Hiera, or the TLS handshake fails with a name mismatch -- which reads as a
    certificate problem and sends people entirely the wrong way.

    A stable DNS name (a Cloud DNS private record, or a load balancer in front
    of several compile masters), never an instance's IP.

    THE INVENTORY WINS OVER THIS. Set puppet_server in
    inventory/customers/<c>/<e>.yaml -- on a product, a cluster or a
    datacentre -- when different parts of one customer's estate are served by
    different masters; then this is only the default for whatever is left. Put
    it in the inventory rather than here whenever it is a property of the
    estate, so the local driver and both clouds agree without a third copy.

    Optional only in the sense that the inventory may supply it. A node left
    with no master from either source is rejected by
    google_compute_instance.node's precondition rather than built and left
    unconfigured.
  EOT
  type        = string
  default     = null
}

variable "puppet_collection" {
  description = "Puppet Platform collection. Must agree with the puppet_version pinned in Hiera."
  type        = string
  default     = "puppet8"
}

variable "puppet_environment" {
  description = "Puppet environment, i.e. the control repo branch r10k deployed."
  type        = string
  default     = "production"
}

# ---------------------------------------------------------------------------
# Instances
# ---------------------------------------------------------------------------
variable "boot_image" {
  description = <<-EOT
    Base image, e.g. "ubuntu-os-cloud/ubuntu-2204-lts".

    Must be a systemd distro the user-data supports -- Ubuntu 20.04/22.04,
    Debian 11/12, RHEL/Rocky 8/9 (see the case statement in 20-common.sh) --
    and must run cloud-init, which every stock image does.

    Deliberately RAW. Do not bake Puppet in: the node installs its own agent
    and asks the master for everything else. A baked agent also means a baked
    puppet.conf, which is how fleets end up pointed at a master that no longer
    exists.
  EOT
  type        = string
}

variable "machine_type_override" {
  description = <<-EOT
    Override the machine type the inventory's `sizing:` shape resolves to.

    An escape hatch for capacity or quota problems in one region. Using it
    means bypassing check-sizing.py's guarantee that the machine fits the JVM
    heap Hiera pins -- and that mismatch is SILENT at runtime: the process is
    OOM-killed after a clean-looking startup with nothing failing in Puppet.
    Prefer editing the sizing shape.
  EOT
  type        = string
  default     = null
}

variable "boot_disk_size_gb" {
  description = "Boot disk size. See data_disk_size_gb for why Cassandra data should not live here."
  type        = number
  default     = 50
}

variable "boot_disk_type" {
  description = "pd-balanced, pd-ssd or pd-standard."
  type        = string
  default     = "pd-balanced"
}

variable "data_disk_size_gb" {
  description = <<-EOT
    Separate persistent disk for /var/lib/cassandra. 0 disables it.

    Strongly recommended for anything real, for two reasons: data on the boot
    disk means a full disk takes the OS down with it, and it means the data
    cannot outlive the instance.

    NOTE: this stack ATTACHES the disk; nothing formats or mounts it. That is
    deliberate -- a Terraform-side mkfs is a data-loss waiting to happen on
    re-apply. Do it in Puppet (a filesystem resource guarded on the device) or
    in a disk-setup step in user-data.
  EOT
  type        = number
  default     = 0
}

variable "data_disk_type" {
  description = "Type for the data disk."
  type        = string
  default     = "pd-ssd"
}

variable "deletion_protection" {
  description = <<-EOT
    Deletion protection on every instance.

    Default TRUE, unlike most Terraform. These are stateful database nodes: a
    `terraform destroy` run against the wrong workspace is a data-loss event,
    and the inconvenience of turning this off deliberately is much smaller than
    the alternative.
  EOT
  type        = bool
  default     = true
}

variable "allow_stopping_for_update" {
  description = <<-EOT
    Let Terraform stop an instance to apply a change that needs it (machine
    type, for instance).

    Default FALSE: on a Cassandra node an unexpected stop is an outage and
    possibly a repair. Change machine types deliberately, one node at a time,
    with the ring checked in between.
  EOT
  type        = bool
  default     = false
}

variable "metadata" {
  description = "Extra instance metadata, merged over what this stack sets."
  type        = map(string)
  default     = {}
}

variable "enable_shielded_vm" {
  description = "Secure Boot, vTPM and integrity monitoring. Requires a UEFI-capable image."
  type        = bool
  default     = true
}

variable "enable_oslogin" {
  description = <<-EOT
    OS Login, so SSH access is governed by IAM rather than by metadata keys.
    Recommended: metadata SSH keys are hard to audit and harder to revoke.
  EOT
  type        = bool
  default     = true
}

variable "ports" {
  description = <<-EOT
    Override individual ports from inventory/defaults.yaml, e.g.
    { cassandra_cql = 9142 }.

    Empty (default) uses the inventory. Keys: puppet, cassandra_internode,
    cassandra_internode_tls, cassandra_jmx, cassandra_cql.

    cassandra_cql MUST equal profile_cassandra_pfpt::native_transport_port in
    Hiera. Nothing enforces that, and a mismatch is quiet: the ring forms
    (internode is a different port) and then nothing can connect.
  EOT
  type        = map(number)
  default     = {}
}

# ---------------------------------------------------------------------------
# Control repo
# ---------------------------------------------------------------------------
variable "control_repo_url" {
  description = <<-EOT
    Git URL of the Puppet control repo, cloned by the master at first boot.
    HTTPS or SSH.

    Examples:
      https://github.com/your-org/cassandra-control-repo.git   (public / token)
      git@github.com:your-org/cassandra-control-repo.git       (SSH deploy key)

    For SSH URLs also set control_repo_deploy_key_secret_id. For HTTPS with a
    token, embed the token in the URL (store the whole URL as a secret and
    retrieve it at boot, or use the deploy key mechanism with a credential
    helper).

    Null (default) means the repo is NOT cloned at boot. That is correct for
    the local Docker driver, which bind-mounts the checkout. Every
    cloud-provisioned master needs this set.
  EOT
  type        = string
  default     = null
}

variable "control_repo_deploy_key_secret_id" {
  description = <<-EOT
    Secret Manager secret ID holding the SSH private key for the control repo
    (for SSH URLs). The secret's value must be the raw PEM key -- not base64,
    not JSON.

    The master fetches it at boot, uses it for the initial clone, then scrubs
    it from disk. Subsequent r10k runs use the credential configured by the
    puppetmaster_pfpt module in Hiera.

    Null (default) means no deploy key. Public HTTPS repos do not need one.

    The service account must have roles/secretmanager.secretAccessor on this
    secret. Set grant_deploy_key_access = true to have this stack create that
    binding.
  EOT
  type        = string
  default     = null
}

variable "grant_deploy_key_access" {
  description = <<-EOT
    Grant the instances' service account secretAccessor on
    control_repo_deploy_key_secret_id.

    Set false if IAM is managed outside this stack. Only effective when
    control_repo_deploy_key_secret_id is also set.
  EOT
  type        = bool
  default     = true
}

variable "jenkins_client_source_tags" {
  description = <<-EOT
    Network tags allowed to reach Jenkins' HTTP port (inventory
    ports.jenkins_http, default 8080).

    EMPTY BY DEFAULT, which creates no firewall rule and therefore grants no
    access. That is the safe direction: Jenkins runs arbitrary commands
    against the Cassandra fleet through cassy, so reaching this port is
    equivalent to shell on every node in the cluster.

    By TAG, never a CIDR, and never 0.0.0.0/0. Point it at a load balancer's
    tag or a VPN/bastion tag.
  EOT
  type        = list(string)
  default     = []
}
