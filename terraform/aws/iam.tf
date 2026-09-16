# ===========================================================================
# IAM -- bring your own, or create
# ===========================================================================
#
# Default FALSE. In most real accounts instance roles are created by a separate
# team with its own review, and this stack should consume one by name.
#
# When it does create one, the role's ONLY permission is reading one secret.
# That is the entire privilege an instance in this estate needs from AWS: it
# gets its identity from instance tags (free, via IMDS) and everything else
# from the Puppet master.

data "aws_iam_policy_document" "assume_role" {
  count = var.create_iam_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  count = var.create_iam_role ? 1 : 0

  name_prefix        = "${var.name_prefix}-node-"
  assume_role_policy = data.aws_iam_policy_document.assume_role[0].json
  tags               = local.common_tags
}

resource "aws_iam_instance_profile" "node" {
  count = var.create_iam_role ? 1 : 0

  name_prefix = "${var.name_prefix}-node-"
  role        = aws_iam_role.node[0].name
  tags        = local.common_tags
}

# ---------------------------------------------------------------------------
# The join secret -- one ARN, never a wildcard
# ---------------------------------------------------------------------------
# SCOPED TO ONE ARN on purpose. `secretsmanager:GetSecretValue` on "*" would
# let any node in the estate read every secret in the account, which turns a
# single compromised Cassandra node into an account-wide credential leak. That
# is why var.join_secret_arn exists separately from var.join_secret_id: the id
# is what the instance looks up, the ARN is what the policy is pinned to.
data "aws_iam_policy_document" "join_secret" {
  count = var.create_iam_role && var.join_secret_arn != null ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.join_secret_arn]
  }
}

resource "aws_iam_role_policy" "join_secret" {
  count = var.create_iam_role && var.join_secret_arn != null ? 1 : 0

  name_prefix = "join-secret-"
  role        = aws_iam_role.node[0].id
  policy      = data.aws_iam_policy_document.join_secret[0].json
}

# ---------------------------------------------------------------------------
# Control repo deploy key -- one ARN, never a wildcard
# ---------------------------------------------------------------------------
# Follows the same pattern as join_secret: the id is what the instance looks
# up at boot, the ARN is what the policy is pinned to, and the separation
# prevents a wildcard from widening access to every secret in the account.
data "aws_iam_policy_document" "deploy_key" {
  count = var.create_iam_role && var.control_repo_deploy_key_secret_arn != null ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.control_repo_deploy_key_secret_arn]
  }
}

resource "aws_iam_role_policy" "deploy_key" {
  count = var.create_iam_role && var.control_repo_deploy_key_secret_arn != null ? 1 : 0

  name_prefix = "control-repo-deploy-key-"
  role        = aws_iam_role.node[0].id
  policy      = data.aws_iam_policy_document.deploy_key[0].json
}

# ---------------------------------------------------------------------------
# Session Manager
# ---------------------------------------------------------------------------
# Recommended, and on by default when this stack creates the role: it removes
# the need for inbound SSH entirely, needs no bastion, and leaves an audit
# trail. The alternative is an ingress rule on 22 plus a key pair whose private
# half has to live somewhere.
#
# Needs the SSM agent in the AMI (present on Amazon Linux and Ubuntu's official
# images, absent from many minimal Debian ones) and a route to the SSM
# endpoints -- via the NAT gateway, or VPC endpoints in a no-egress account.
resource "aws_iam_role_policy_attachment" "ssm" {
  count = var.create_iam_role && var.attach_ssm_policy ? 1 : 0

  role       = aws_iam_role.node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
