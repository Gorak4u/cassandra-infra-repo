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
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ---------------------------------------------------------------------
  # REMOTE STATE
  #
  # All values passed at init time so the same code serves every workspace.
  # use_lockfile (provider 5.x+) replaces the old DynamoDB lock table.
  #
  # Option A -- flags at init:
  #   terraform init \
  #     -backend-config="bucket=amex-infra-tfstate" \
  #     -backend-config="key=puppet-estate/amex-nonprod/dc_east/terraform.tfstate" \
  #     -backend-config="region=us-east-1" \
  #     -backend-config="encrypt=true" \
  #     -backend-config="use_lockfile=true"
  #
  # Option B -- a per-workspace backend.hcl (gitignored):
  #   terraform init -backend-config=backend.hcl
  #
  # Create the bucket first:
  #   ./setup-remote-state.sh amex-infra-tfstate us-east-1
  # ---------------------------------------------------------------------
  backend "s3" {
    # All config supplied via -backend-config or backend.hcl at init.
    # See the comment above and setup-remote-state.sh.
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      ManagedBy = "terraform"
    }
  }

  # ---------------------------------------------------------------------
  # ENDPOINT OVERRIDE -- for LocalStack, or any AWS-compatible endpoint
  # ---------------------------------------------------------------------
  # var.aws_endpoint_url defaults to NULL, and a null endpoint means "use the
  # real AWS endpoint for this region". So this block costs nothing in
  # production and is invisible unless someone sets the variable.
  #
  # Set it and the whole stack can be applied against LocalStack running in
  # Docker, which is the only way to exercise the resource graph -- ordering,
  # tags, IMDS options, volume attachment, IAM wiring -- without an AWS
  # account. `terraform validate` does not do that: it checks syntax and
  # provider schemas and never calls an API.
  #
  # What it does NOT test: LocalStack's EC2 instances are mock records, not
  # VMs. Nothing boots, no cloud-init runs, no Puppet agent installs. This
  # proves the Terraform is correct, and says nothing about whether a node
  # builds.
  endpoints {
    ec2            = var.aws_endpoint_url
    iam            = var.aws_endpoint_url
    sts            = var.aws_endpoint_url
    secretsmanager = var.aws_endpoint_url
    kms            = var.aws_endpoint_url
  }

  # Only skipped when an endpoint override is in play. Against real AWS these
  # checks are wanted: they are what turns a missing credential into a clear
  # error instead of a confusing 403 later.
  skip_credentials_validation = var.aws_endpoint_url != null
  skip_requesting_account_id  = var.aws_endpoint_url != null
  skip_metadata_api_check     = var.aws_endpoint_url != null
  skip_region_validation      = var.aws_endpoint_url != null
}
