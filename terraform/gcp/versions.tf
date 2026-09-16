# ===========================================================================
# Provider and Terraform version constraints
# ===========================================================================
# Pinned with `~>`, not left open. An unpinned provider means `terraform init`
# on a different day can produce a different plan from the same code, which
# destroys the only thing Terraform is really for: being able to explain a
# change.

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  # ---------------------------------------------------------------------
  # REMOTE STATE
  #
  # Bucket and prefix are passed at init time so the same code serves every
  # environment and workspace without a code change. Values cannot be
  # Terraform variables here -- that is a language constraint, not an oversight.
  #
  # Option A -- flags at init:
  #   terraform init \
  #     -backend-config="bucket=amex-infra-tfstate" \
  #     -backend-config="prefix=puppet-estate/amex-nonprod/dc_east"
  #
  # Option B -- a per-workspace backend.hcl (gitignored):
  #   echo 'bucket = "amex-infra-tfstate"'             >> backend.hcl
  #   echo 'prefix = "puppet-estate/amex-nonprod/dc_east"' >> backend.hcl
  #   terraform init -backend-config=backend.hcl
  #
  # Create the bucket first:
  #   ./setup-remote-state.sh <project-id> amex-infra-tfstate
  # ---------------------------------------------------------------------
  backend "gcs" {
    # Bucket and prefix supplied via -backend-config or backend.hcl at init.
    # See the comment above and setup-remote-state.sh.
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
