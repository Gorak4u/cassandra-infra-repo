#!/usr/bin/env bash
# ===========================================================================
# test-with-localstack.sh -- apply the AWS Terraform against a LocalStack mock
# ===========================================================================
#
# What this proves:
#   - the resource graph is coherent (no `plan` errors)
#   - IAM role + instance profile + policy attach are correct
#   - VPC / subnets / NAT / route tables / security groups wire up
#   - EC2 tags carry the pp_* identity
#   - user-data gzip fits under EC2's 16 KiB limit (plan-time precondition)
#   - IMDSv2 + instance_metadata_tags = "enabled" is set on every instance
#
# What it does NOT prove:
#   - Nothing boots. LocalStack's EC2 instances are mock records.
#   - No Puppet agent installs, no CSR is signed, no catalog compiles.
#   - Cloud-init never runs the user-data.
#
# Usage:
#   ./test-with-localstack.sh apply    (default -- create the graph)
#   ./test-with-localstack.sh show     (list what LocalStack thinks exists)
#   ./test-with-localstack.sh destroy
#   ./test-with-localstack.sh clean    (destroy + remove workspace + kill container)

set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORKSPACE='ls-dc_east'
readonly LS_ENDPOINT='http://localhost:4566'
readonly TFVARS='localstack.tfvars'

export AWS_ACCESS_KEY_ID='test'
export AWS_SECRET_ACCESS_KEY='test'
export AWS_DEFAULT_REGION='us-east-1'

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '  [ ok ] %s\n' "$*"; }
die()  { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

ensure_localstack() {
  if ! curl -sf "${LS_ENDPOINT}/_localstack/health" >/dev/null 2>&1; then
    step 'Starting LocalStack in Docker'
    docker rm -f localstack >/dev/null 2>&1 || true
    docker run -d --name localstack \
      -p 4566:4566 \
      -e SERVICES=ec2,iam,secretsmanager,sts,s3,kms \
      localstack/localstack:3 >/dev/null || die 'could not start LocalStack'
    printf '    waiting for services'
    for i in $(seq 1 60); do
      if curl -sf "${LS_ENDPOINT}/_localstack/health" 2>/dev/null | grep -q '"ec2": "available"'; then
        printf ' ready\n'; return
      fi
      printf '.'; sleep 2
    done
    die 'LocalStack did not become ready'
  else
    ok "LocalStack already running at ${LS_ENDPOINT}"
  fi
}

seed_prerequisites() {
  step 'Seeding LocalStack with the join secret and the S3 backend bucket'

  # Create the join secret LocalStack refuses to hand out if it does not
  # exist. Value is meaningless -- LocalStack does not validate GetSecretValue.
  aws --endpoint-url="${LS_ENDPOINT}" secretsmanager create-secret \
    --name 'amex/nonprod/puppet-join-secret' \
    --secret-string 'localstack-mock-secret' >/dev/null 2>&1 || true

  local arn
  arn="$(aws --endpoint-url="${LS_ENDPOINT}" secretsmanager describe-secret \
          --secret-id 'amex/nonprod/puppet-join-secret' \
          --query ARN --output text 2>/dev/null)"
  [[ -n "${arn}" && "${arn}" != None ]] || die 'could not resolve the LocalStack secret ARN'
  ok "join secret ARN: ${arn}"
  echo "${arn}" > "${HERE}/.localstack-secret-arn"

  # Terraform's backend block requires a real bucket even for a mock. Create
  # it in LocalStack's S3 so `terraform init -backend-config` succeeds.
  aws --endpoint-url="${LS_ENDPOINT}" s3api create-bucket \
    --bucket 'ls-tfstate' >/dev/null 2>&1 || true
  ok 'S3 backend bucket: ls-tfstate'
}

tf_init() {
  step 'terraform init (backend targets LocalStack S3)'
  cd "${HERE}"
  # Point Terraform's S3 backend at LocalStack. The AWS_ENDPOINT_URL_* env
  # vars (provider 5.x+) route ALL AWS SDK calls -- including backend --
  # through the LocalStack endpoint, without editing versions.tf.
  export AWS_ENDPOINT_URL_S3="${LS_ENDPOINT}"
  export AWS_ENDPOINT_URL_DYNAMODB="${LS_ENDPOINT}"
  export AWS_ENDPOINT_URL_STS="${LS_ENDPOINT}"

  # Nuke prior .terraform so the backend config below is picked up fresh.
  rm -rf .terraform .terraform.lock.hcl

  # Terraform 1.5.x S3 backend syntax (older keys than the 1.11+ endpoints{}).
  # Newer Terraform accepts these too, so this works across versions.
  terraform init -input=false \
    -backend-config="bucket=ls-tfstate" \
    -backend-config="key=puppet-estate/localstack/terraform.tfstate" \
    -backend-config="region=us-east-1" \
    -backend-config="encrypt=false" \
    -backend-config="skip_credentials_validation=true" \
    -backend-config="skip_metadata_api_check=true" \
    -backend-config="skip_region_validation=true" \
    -backend-config="force_path_style=true" \
    -backend-config="endpoint=${LS_ENDPOINT}" >/dev/null || die 'init failed'
  ok "backend: s3://ls-tfstate (LocalStack)"
}

tf_apply() {
  step 'terraform apply'
  cd "${HERE}"
  local arn=''
  [[ -f .localstack-secret-arn ]] && arn="$(cat .localstack-secret-arn)"

  local args=(-var-file="${TFVARS}" -input=false -auto-approve)
  [[ -n "${arn}" ]] && args+=(-var "join_secret_arn=${arn}")

  terraform apply "${args[@]}" || die 'apply failed'
}

tf_show_summary() {
  step 'What LocalStack thinks exists'
  cd "${HERE}"
  printf '\n  --- Instances ---\n'
  aws --endpoint-url="${LS_ENDPOINT}" ec2 describe-instances \
    --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0],InstanceType,PrivateIpAddress]' \
    --output table

  printf '\n  --- Security groups ---\n'
  aws --endpoint-url="${LS_ENDPOINT}" ec2 describe-security-groups \
    --query 'SecurityGroups[].[GroupName,GroupId,Description]' --output table

  printf '\n  --- Instance IMDSv2 posture ---\n'
  aws --endpoint-url="${LS_ENDPOINT}" ec2 describe-instances \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`].Value|[0],MetadataOptions.HttpTokens,MetadataOptions.InstanceMetadataTags]' \
    --output table

  printf '\n  --- The pp_* identity on one instance (proves tags land right) ---\n'
  local first
  first="$(aws --endpoint-url="${LS_ENDPOINT}" ec2 describe-instances \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)"
  aws --endpoint-url="${LS_ENDPOINT}" ec2 describe-tags \
    --filters "Name=resource-id,Values=${first}" \
    --query 'Tags[?starts_with(Key, `pp_`) || Key==`Name` || Key==`wait_for`].[Key,Value]' \
    --output table
}

tf_destroy() {
  step 'terraform destroy'
  cd "${HERE}"
  # prevent_destroy on aws_ebs_volume.data blocks destroy. Same in real AWS,
  # by design -- a destroy against the wrong workspace is a data-loss event.
  # For the mock, we -target-remove the state entries first.
  terraform state list 2>/dev/null | grep 'aws_ebs_volume.data' | while read -r r; do
    terraform state rm "${r}" >/dev/null 2>&1 || true
  done
  terraform destroy -var-file="${TFVARS}" -input=false -auto-approve
}

case "${1:-apply}" in
  apply)
    ensure_localstack
    seed_prerequisites
    tf_init
    tf_apply
    tf_show_summary
    step 'Done'
    printf '  All resources created against LocalStack. See "%s show" for a list.\n' "$0"
    ;;
  show)     tf_show_summary ;;
  destroy)  tf_destroy ;;
  clean)
    tf_destroy || true
    terraform workspace select default >/dev/null 2>&1 || true
    terraform workspace delete "${WORKSPACE}" 2>/dev/null || true
    docker rm -f localstack >/dev/null 2>&1 || true
    rm -f "${HERE}/.localstack-secret-arn"
    ok 'cleaned up LocalStack, workspace, cache'
    ;;
  *)
    printf 'usage: %s {apply|show|destroy|clean}\n' "$0" >&2
    exit 1
    ;;
esac
