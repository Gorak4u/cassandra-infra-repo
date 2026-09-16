#!/usr/bin/env bash
# ===========================================================================
# setup-remote-state.sh -- create the S3 bucket for Terraform remote state
# ===========================================================================
# Run ONCE per AWS account/region, before the first `terraform init`.
# use_lockfile (AWS provider 5.x+) replaces the old DynamoDB lock table.
#
# Usage:
#   ./setup-remote-state.sh <bucket-name> <region>
#
# Example:
#   ./setup-remote-state.sh amex-infra-tfstate us-east-1
set -euo pipefail

BUCKET="${1:?usage: $0 <bucket-name> <region>}"
REGION="${2:?usage: $0 <bucket-name> <region>}"

if aws s3api head-bucket --bucket "${BUCKET}" --region "${REGION}" 2>/dev/null; then
  echo "Bucket s3://${BUCKET} already exists"
else
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "${BUCKET}" \
      --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi
  echo "Created s3://${BUCKET} in ${REGION}"
fi

# Versioning: keeps every state revision for recovery
aws s3api put-bucket-versioning \
  --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled
echo "Versioning enabled"

# Encryption at rest using the account's default KMS key
aws s3api put-bucket-encryption \
  --bucket "${BUCKET}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'
echo "Server-side encryption (KMS) enabled"

# Block all public access — state buckets must never be public
aws s3api put-public-access-block \
  --bucket "${BUCKET}" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
echo "Public access blocked"

echo ""
echo "Done. Initialise Terraform for your workspace:"
echo ""
echo "  Option A — flags at init:"
echo "    terraform init \\"
echo "      -backend-config=\"bucket=${BUCKET}\" \\"
echo "      -backend-config=\"key=puppet-estate/<customer>-<env>/<dc>/terraform.tfstate\" \\"
echo "      -backend-config=\"region=${REGION}\" \\"
echo "      -backend-config=\"encrypt=true\" \\"
echo "      -backend-config=\"use_lockfile=true\""
echo ""
echo "  Option B — backend.hcl (gitignored, one per workspace):"
echo "    cat > backend.hcl <<EOF"
echo "    bucket       = \"${BUCKET}\""
echo "    key          = \"puppet-estate/<customer>-<env>/<dc>/terraform.tfstate\""
echo "    region       = \"${REGION}\""
echo "    encrypt      = true"
echo "    use_lockfile = true"
echo "    EOF"
echo "    terraform init -backend-config=backend.hcl"
