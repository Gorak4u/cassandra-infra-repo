#!/usr/bin/env bash
# ===========================================================================
# setup-remote-state.sh -- create the GCS bucket for Terraform remote state
# ===========================================================================
# Run ONCE per GCP project, before the first `terraform init`.
#
# Usage:
#   ./setup-remote-state.sh <project-id> <bucket-name> [region]
#
# Example:
#   ./setup-remote-state.sh amex-nonprod-data amex-infra-tfstate us-central1
set -euo pipefail

PROJECT="${1:?usage: $0 <project-id> <bucket-name> [region]}"
BUCKET="${2:?usage: $0 <project-id> <bucket-name> [region]}"
REGION="${3:-us-central1}"

if gsutil ls -p "${PROJECT}" "gs://${BUCKET}" >/dev/null 2>&1; then
  echo "Bucket gs://${BUCKET} already exists"
else
  # -b on: uniform bucket-level access (IAM only, no per-object ACLs)
  gsutil mb -p "${PROJECT}" -l "${REGION}" -b on "gs://${BUCKET}"
  echo "Created gs://${BUCKET} in ${REGION}"
fi

# Versioning keeps every state revision — essential for recovering from a
# corrupted apply or accidental state deletion.
gsutil versioning set on "gs://${BUCKET}"
echo "Versioning enabled on gs://${BUCKET}"

echo ""
echo "Done. Initialise Terraform for your workspace:"
echo ""
echo "  Option A — flags at init:"
echo "    terraform init \\"
echo "      -backend-config=\"bucket=${BUCKET}\" \\"
echo "      -backend-config=\"prefix=puppet-estate/<customer>-<env>/<dc>\""
echo ""
echo "  Option B — backend.hcl (gitignored, one per workspace):"
echo "    cat > backend.hcl <<EOF"
echo "    bucket = \"${BUCKET}\""
echo "    prefix = \"puppet-estate/<customer>-<env>/<dc>\""
echo "    EOF"
echo "    terraform init -backend-config=backend.hcl"
