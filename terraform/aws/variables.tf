# ===========================================================================
# Variables -- every one overridable from tfvars
# ===========================================================================
#
# THE CENTRAL DESIGN CHOICE: bring your own, or create.
#
# A real AWS account almost always has a VPC, subnets, security groups and IAM
# roles already, owned by teams with their own change processes. Terraform that
# insists on creating those is unusable there. Equally, a fresh sandbox account
# has none of it and you want one command.
#
# So every piece of surrounding infrastructure has a `create_*` boolean,
# defaulting to FALSE. Creating network or IAM resources should be a
# deliberate, stated act, not what happens when you forget a variable.

variable "region" {
  description = "AWS region. One stack per region -- see var.datacenter."
  type        = string
}

# ---------------------------------------------------------------------------
# Which slice of the inventory to build
# ---------------------------------------------------------------------------
variable "customer" {
  description = <<-EOT
    Customer whose inventory file to read:
    infra/inventory/customers/<customer>/<environment>.yaml

    The SAME file the local Docker driver reads. One description of the estate,
    two provisioners.
  EOT
  type        = string
}

variable "environment" {
  description = "Environment within that customer (nonprod, prod, staging)."
  type        = string
}

variable "datacenter" {
  description = <<-EOT
    Which datacentre of the inventory this stack builds. Null means the
    environment file's top-level `datacenter`.

    ONE STACK PER DATACENTRE: an AWS datacentre is a REGION, a provider is
    configured for one region, so multi-region means running this once per
    region with its own state. That is what you want anyway -- a single plan
    that can destroy two regions at once is a bad afternoon.
  EOT
  type        = string
  default     = null
}

variable "products" {
  description = <<-EOT
    Restrict to these products, e.g. ["cassandra"]. Empty means all.

    Useful when the Puppet master already exists (built once, separately) and
    you only want to add Cassandra nodes -- a very common real case.
  EOT
  type        = list(string)
  default     = []
}

variable "clusters" {
  description = "Restrict to these clusters. Empty means all."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------
variable "dns_domain" {
  description = <<-EOT
    Certname suffix. Defaults to the inventory's `domain`.

    Must match the master's autosign_certname_pattern in Hiera or every CSR is
    refused. Prefer a subdomain you own; '.internal' is reserved by ICANN for
    exactly this.
  EOT
  type        = string
  default     = null
}

variable "name_prefix" {
  description = <<-EOT
    Prefix for the SURROUNDING resources this stack creates. Not for
    instances -- those are named by the inventory, because an instance's Name
    tag carries its certname and renaming means reissuing a certificate.
  EOT
  type        = string
  default     = "puppet-estate"
}

variable "tags" {
  description = "Tags applied to everything this stack creates."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Networking -- bring your own, or create
# ---------------------------------------------------------------------------
variable "create_vpc" {
  description = <<-EOT
    false (default): use `vpc_id` and `subnet_ids`.
    true: create a VPC, private subnets, and a NAT gateway.

    Default false because a shared VPC is the production norm.
  EOT
  type        = bool
  default     = false
}

variable "vpc_id" {
  description = "Existing VPC, when create_vpc is false."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = <<-EOT
    Existing PRIVATE subnets, when create_vpc is false. Order is significant:
    nodes round-robin across this list by rack index, so one subnet per
    availability zone is what gives you AZ-spread replicas.

    Private, not public. Nothing in this estate needs an inbound route from
    the internet, and the CA port least of all -- egress belongs on a NAT
    gateway or an internal mirror.
  EOT
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "CIDR for the VPC. Only used when create_vpc is true."
  type        = string
  default     = "10.80.0.0/16"
}

variable "availability_zones" {
  description = <<-EOT
    AZs to create subnets in. Only used when create_vpc is true.

    len(azs) should be >= len(racks) in the inventory, and the ORDER matters:
    rack N lands in AZ N, and that is what keeps replicas apart.
  EOT
  type        = list(string)
  default     = []
}

variable "create_nat_gateway" {
  description = <<-EOT
    Create a NAT gateway for egress. Only used when create_vpc is true.

    The instances have no public IP, so they need SOME egress path to install
    the Puppet agent from apt.puppet.com and Cassandra from its repository. If
    there is no NAT and no mirror, first boot HANGS installing the agent --
    which looks like a user-data bug and is not.
  EOT
  type        = bool
  default     = true
}

variable "create_security_group" {
  description = <<-EOT
    Create the security group this estate needs (Puppet 8140, Cassandra
    internode 7000/7001, JMX 7199, CQL 9042).

    Default false: security groups are usually centrally managed, and the rules
    are documented in network.tf so a network team can reproduce them exactly.
    When true, the created group is ADDED to `security_group_ids`.
  EOT
  type        = bool
  default     = false
}

variable "security_group_ids" {
  description = "Existing security groups to attach. Combined with the created one when create_security_group is true."
  type        = list(string)
  default     = []
}

variable "cql_client_security_group_ids" {
  description = <<-EOT
    Security groups allowed to reach CQL (9042), for your applications.

    Only used when create_security_group is true. Cluster members can always
    reach each other. Never widen 9042 to a CIDR: the module manages its own
    schema over CQL with a superuser.
  EOT
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# IAM -- bring your own, or create
# ---------------------------------------------------------------------------
variable "create_iam_role" {
  description = <<-EOT
    false (default): use `iam_instance_profile`.
    true: create a role and instance profile whose ONLY permission is reading
    the join secret.
  EOT
  type        = bool
  default     = false
}

variable "iam_instance_profile" {
  description = "Existing instance profile NAME, when create_iam_role is false."
  type        = string
  default     = null
}

variable "attach_ssm_policy" {
  description = <<-EOT
    Attach AmazonSSMManagedInstanceCore, so Session Manager works without SSH
    or a bastion.

    Recommended: it removes the need for inbound SSH entirely. Only used when
    create_iam_role is true.
  EOT
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# The join secret
# ---------------------------------------------------------------------------
variable "join_secret_id" {
  description = <<-EOT
    Secrets Manager secret id or name holding the estate join secret. Its
    SHA-256 must be in the master's Hiera as
    autosign_challenge_password_sha256.

    Null means no challengePassword: nodes rely on the extension allowlist and
    certname pattern alone. Weaker, and deliberately allowed, because it beats
    a secret nobody rotates.
  EOT
  type        = string
  default     = null
}

variable "join_secret_arn" {
  description = <<-EOT
    ARN of that same secret, for the IAM policy.

    Separate from join_secret_id because the policy must be scoped to one
    ARN -- a wildcard would let any node in the estate read every secret in the
    account.
  EOT
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Puppet
# ---------------------------------------------------------------------------
variable "puppet_server" {
  description = <<-EOT
    FALLBACK master for nodes the inventory does not assign one. The name
    agents use to reach it. Must appear in that master's dns_alt_names in
    Hiera, or the TLS handshake fails with a name mismatch -- which reads as a
    certificate problem and sends people the wrong way.

    A stable DNS name (a Route53 record, or an NLB in front of several compile
    masters), never an instance's private IP.

    THE INVENTORY WINS OVER THIS. Set puppet_server in
    inventory/customers/<c>/<e>.yaml -- on a product, a cluster or a
    datacentre -- when different parts of one customer's estate are served by
    different masters; then this is only the default for whatever is left. Put
    it in the inventory rather than here whenever it is a property of the
    estate, so the local driver and both clouds agree without a third copy.

    Optional only in the sense that the inventory may supply it. A node left
    with no master from either source is rejected by aws_instance.node's
    precondition rather than built and left unconfigured.
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
variable "ami_id" {
  description = <<-EOT
    Base AMI. Must be a systemd distro the user-data supports -- Ubuntu
    20.04/22.04, Debian 11/12, RHEL/Rocky 8/9 -- and must run cloud-init.

    Deliberately RAW. Do not bake Puppet in: the node installs its own agent
    and asks the master for everything else. A baked agent also means a baked
    puppet.conf, which is how fleets end up pointed at a master that no longer
    exists.

    NOTE: the aws CLI must be present for the join secret to be readable. It is
    on Amazon Linux and is NOT on stock Ubuntu or Debian AMIs -- either add it
    to the AMI or install it in 10-metadata-aws.sh before the secret lookup.
  EOT
  type        = string
}

variable "instance_type_override" {
  description = <<-EOT
    Override the instance type the inventory's `sizing:` shape resolves to.

    An escape hatch for capacity or quota problems. Using it bypasses
    check-sizing.py's guarantee that the machine fits the JVM heap Hiera pins,
    and that mismatch is SILENT at runtime: the process is OOM-killed after a
    clean-looking startup with nothing failing in Puppet. Prefer editing the
    sizing shape.
  EOT
  type        = string
  default     = null
}

variable "key_name" {
  description = <<-EOT
    EC2 key pair for SSH. Null (default) means none -- use Session Manager
    instead, which needs no inbound port and leaves an audit trail.
  EOT
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "Root volume size. See data_volume_size_gb for why Cassandra data should not live here."
  type        = number
  default     = 50
}

variable "root_volume_type" {
  description = "Root volume type."
  type        = string
  default     = "gp3"
}

variable "data_volume_size_gb" {
  description = <<-EOT
    Separate EBS volume for /var/lib/cassandra. 0 disables it.

    Strongly recommended: data on the root volume means a full disk takes the
    OS down with it, and it means the data cannot outlive the instance.

    NOTE: this stack ATTACHES the volume; nothing formats or mounts it. That is
    deliberate -- a Terraform-side mkfs is a data-loss waiting to happen on
    re-apply. Do it in Puppet (a filesystem resource guarded on the device).
  EOT
  type        = number
  default     = 0
}

variable "data_volume_type" {
  description = "Data volume type. gp3 for most workloads; io2 where you need provisioned IOPS."
  type        = string
  default     = "gp3"
}

variable "data_volume_iops" {
  description = "Provisioned IOPS for the data volume. Null uses the type's default."
  type        = number
  default     = null
}

variable "kms_key_id" {
  description = <<-EOT
    KMS key for EBS encryption. Null uses the account's default EBS key.

    Volumes are ALWAYS encrypted; this only chooses the key.
  EOT
  type        = string
  default     = null
}

variable "disable_api_termination" {
  description = <<-EOT
    Termination protection on every instance.

    Default TRUE, unlike most Terraform. These are stateful database nodes: a
    `terraform destroy` against the wrong workspace is a data-loss event, and
    the inconvenience of turning this off deliberately is much smaller than the
    alternative.
  EOT
  type        = bool
  default     = true
}

variable "extra_tags_per_node" {
  description = "Extra tags merged onto every instance. Useful for cost allocation."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Local testing
# ---------------------------------------------------------------------------
variable "aws_endpoint_url" {
  description = <<-EOT
    Override every AWS service endpoint, e.g. "http://localhost:4566" for
    LocalStack. Null (default) uses real AWS.

    This exists so the stack can be applied for real against a mock, which is
    the only way to exercise the resource graph without an account --
    `terraform validate` never calls an API.

    Setting it also skips credential, account-id, IMDS and region validation,
    because none of those are meaningful against a mock.

    IT DOES NOT TEST THE NODE BUILD. LocalStack's EC2 instances are mock
    records, not VMs: nothing boots, no cloud-init runs, no Puppet agent
    installs. Use ../../provision.sh for that.
  EOT
  type        = string
  default     = null
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

variable "subnet_newbits" {
  description = <<-EOT
    Additional prefix bits when carving per-AZ subnets out of vpc_cidr.
    4 (default) gives a /20 per AZ from a /16: 4094 usable addresses.

    Only used when create_vpc is true. The NAT subnet takes the LAST index at
    this prefix length, so raising this shrinks every subnet and moves the NAT
    subnet with it -- which is why it is derived rather than a literal.
  EOT
  type        = number
  default     = 4
}

variable "data_device_name" {
  description = <<-EOT
    Device name requested for the Cassandra data volume.

    NVMe-backed instance types (m5/m6i/r6i and newer) IGNORE this and expose
    the volume as /dev/nvme1n1. Whatever mounts it must resolve the device by
    serial -- /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_<volume-id> --
    not by this path: an fstab entry on /dev/sdf survives exactly until the
    first reboot on a new instance family.
  EOT
  type        = string
  default     = "/dev/sdf"
}

# ---------------------------------------------------------------------------
# Control repo
# ---------------------------------------------------------------------------
variable "control_repo_url" {
  description = <<-EOT
    Git URL of the Puppet control repo, cloned by the master at first boot.
    HTTPS or SSH.

    Null (default) means the repo is NOT cloned at boot. That is correct for
    the local Docker driver. Every cloud-provisioned master needs this set.

    NOTE: the master user-data script includes r10k module deployment, which
    adds to the gzipped user-data size. AWS caps user-data at 16 KiB gzipped.
    If the limit is exceeded, Terraform's plan-time precondition rejects it
    with a clear message. Pre-install r10k in the base AMI to avoid the
    gem-install step and keep within the limit.
  EOT
  type        = string
  default     = null
}

variable "control_repo_deploy_key_secret_id" {
  description = <<-EOT
    Secrets Manager secret id (NOT the ARN) holding the SSH private key for
    the control repo. Used when control_repo_url is an SSH URL.

    The secret's value must be the raw PEM key. The master fetches it at boot,
    uses it once for the initial clone, then scrubs it from disk.

    Null (default) means no deploy key.

    The instance role must allow secretsmanager:GetSecretValue on this secret.
    Provide control_repo_deploy_key_secret_arn and set create_iam_role = true
    to have this stack add that permission.
  EOT
  type        = string
  default     = null
}

variable "control_repo_deploy_key_secret_arn" {
  description = <<-EOT
    ARN of the deploy key secret, for the IAM policy.

    Separate from control_repo_deploy_key_secret_id because the policy must
    be scoped to one ARN -- a wildcard would let any node read every secret in
    the account. Follow the same pattern as join_secret_arn.
  EOT
  type        = string
  default     = null
}

variable "jenkins_client_security_group_ids" {
  description = <<-EOT
    Security groups allowed to reach Jenkins' HTTP port (inventory
    ports.jenkins_http, default 8080).

    EMPTY BY DEFAULT, which creates no rule and therefore grants no access.
    That is the safe direction: Jenkins runs arbitrary commands against the
    Cassandra fleet through cassy, so reaching this port is equivalent to
    shell on every node in the cluster.

    By GROUP, never a CIDR, and never 0.0.0.0/0. Point it at a load
    balancer's group or a VPN/bastion group.
  EOT
  type        = list(string)
  default     = []
}
