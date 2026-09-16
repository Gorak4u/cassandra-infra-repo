# ===========================================================================
# Identity -- bring your own, or create
# ===========================================================================
#
# The instances need exactly one permission: read the join secret. That is the
# whole point of fetching it from Secret Manager rather than passing it as
# metadata -- the instance proves its identity to Google, Google hands over the
# secret, and user-data scrubs it from disk once the certificate is issued.
#
# Strictly better than the shared secret the local lab hardcodes, because it
# can be rotated without reprovisioning anything.

resource "google_service_account" "node" {
  count = var.create_service_account ? 1 : 0

  account_id   = "${var.name_prefix}-node"
  project      = var.project_id
  display_name = "Puppet estate node (${var.customer}/${var.environment})"
  description  = "Managed by terraform. Reads only the estate join secret."
}

# Scoped to the ONE secret, by resource, not by project role.
#
# A project-level roles/secretmanager.secretAccessor would let any node in the
# estate read every secret in the project -- including other tenants'. The
# blast radius of a compromised node is exactly what this binding decides.
resource "google_secret_manager_secret_iam_member" "join_secret" {
  count = var.join_secret_id != null && var.grant_join_secret_access ? 1 : 0

  project   = var.project_id
  secret_id = var.join_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.service_account}"
}

# Scoped to the deploy key secret only, by the same reasoning as join_secret:
# a project-level accessor role would let a compromised node read every secret.
resource "google_secret_manager_secret_iam_member" "deploy_key" {
  count = local.control_repo_deploy_key_secret_id != null && var.grant_deploy_key_access ? 1 : 0

  project   = var.project_id
  secret_id = local.control_repo_deploy_key_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.service_account}"
}

# ---------------------------------------------------------------------------
# What is deliberately NOT here
# ---------------------------------------------------------------------------
# No logging or monitoring writer roles. Those belong to whatever observability
# stack the estate runs, and granting them here would silently couple this
# module to a choice it should not be making.
#
# No secret CREATION. The join secret's value is a credential; creating it in
# Terraform would put the plaintext in state, which is readable by anyone with
# access to the state bucket. Create it out of band:
#
#   printf 'your-join-secret' | \
#     gcloud secrets create puppet-estate-join --data-file=- --replication-policy=automatic
#
# ...then put its SHA-256 in the master's Hiera as
# autosign_challenge_password_sha256:
#
#   printf 'your-join-secret' | shasum -a 256
