#!/usr/bin/env bash
# ===========================================================================
# bootstrap-account.sh -- everything before the first cassandra apply
# ===========================================================================
#
# Sequence:
#   1. Create the Terraform state bucket        (versioning, KMS, no-public)
#   2. Create the join secret in Secrets Manager (random 32-byte)
#   3. Print the SHA-256 to paste into Hiera
#   4. Create the Route 53 record for the master
#   5. Apply the Terraform stack, PUPPETMASTER ONLY
#   6. Wait for the master's user-data to finish
#
# After this exits successfully, do the eyaml key ceremony on the master
# (guides/13-secrets-in-production.md) and then apply the Cassandra stack.
#
# Idempotent. Safe to re-run: existing resources are detected and reused.
#
# Usage:
#   ./bootstrap-account.sh <tfvars-file>
#     e.g. ./bootstrap-account.sh amex-nonprod-dc_east.tfvars

set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${1:?usage: $0 <tfvars-file>}"
[[ -f "${HERE}/${TFVARS}" ]] || { echo "no such file: ${HERE}/${TFVARS}"; exit 1; }

# --- LocalStack mode ------------------------------------------------------
# Set AWS_ENDPOINT_URL (e.g. http://localhost:4566) to run against LocalStack.
# The script then:
#   - routes every aws CLI call through --endpoint-url
#   - passes -var aws_endpoint_url=... to Terraform
#   - skips the SSM wait (LocalStack Community does not implement it)
#   - skips Route 53 (LocalStack Community does not implement it)
# This is how the flow is exercised in the lab without a real AWS account.
AWS_ENDPOINT="${AWS_ENDPOINT_URL:-}"
LOCALSTACK_MODE='no'
if [[ -n "${AWS_ENDPOINT}" ]]; then
  LOCALSTACK_MODE='yes'
  export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
  export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
fi
aws_() {
  if [[ -n "${AWS_ENDPOINT}" ]]; then aws --endpoint-url="${AWS_ENDPOINT}" "$@"
  else                                 aws "$@"
  fi
}

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '  [ ok ] %s\n' "$*"; }
info() { printf '         %s\n' "$*"; }
die()  { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

# --- Read what we need from the tfvars, without a full terraform init ------
extract() {
  # BSD/macOS sed does not support \s -- use [[:space:]] and be conservative
  # about what the line format looks like.
  grep -E "^[[:space:]]*$1[[:space:]]*=" "${HERE}/${TFVARS}" | head -1 \
    | sed -E 's/^[^=]+=[[:space:]]*"([^"]+)".*/\1/'
}

CUSTOMER="$(extract customer)"
ENVIRONMENT="$(extract environment)"
DATACENTER="$(extract datacenter)"
REGION="$(extract region)"
DNS_DOMAIN="$(extract dns_domain)"
PUPPET_SERVER="$(extract puppet_server)"
JOIN_SECRET_NAME="$(extract join_secret_id)"

STATE_BUCKET="${CUSTOMER}-${ENVIRONMENT}-tfstate"

for var in CUSTOMER ENVIRONMENT DATACENTER REGION DNS_DOMAIN PUPPET_SERVER JOIN_SECRET_NAME; do
  [[ -n "${!var}" ]] || die "${var} not set in ${TFVARS}"
done

step "Bootstrapping ${CUSTOMER}/${ENVIRONMENT}/${DATACENTER} in ${REGION}"
info "state bucket:  s3://${STATE_BUCKET}"
info "join secret:   ${JOIN_SECRET_NAME}"
info "puppet server: ${PUPPET_SERVER}"

# ---------------------------------------------------------------------------
# 1. State bucket
# ---------------------------------------------------------------------------
step '1/5  Terraform state bucket'
if [[ "${LOCALSTACK_MODE}" == 'yes' ]]; then
  aws_ s3api create-bucket --bucket "${STATE_BUCKET}" >/dev/null 2>&1 || true
else
  "${HERE}/setup-remote-state.sh" "${STATE_BUCKET}" "${REGION}" >/dev/null || die 'state bucket failed'
fi
ok "s3://${STATE_BUCKET}"

# ---------------------------------------------------------------------------
# 2. Join secret
# ---------------------------------------------------------------------------
step '2/5  Estate join secret'
if aws_ secretsmanager describe-secret --secret-id "${JOIN_SECRET_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  ok "already exists"
  JOIN_SECRET_VALUE="$(aws_ secretsmanager get-secret-value \
    --secret-id "${JOIN_SECRET_NAME}" --region "${REGION}" \
    --query SecretString --output text)"
else
  JOIN_SECRET_VALUE="$(openssl rand -base64 32 | tr -d '\n')"
  aws_ secretsmanager create-secret \
    --name "${JOIN_SECRET_NAME}" \
    --secret-string "${JOIN_SECRET_VALUE}" \
    --region "${REGION}" >/dev/null || die 'create-secret failed'
  ok "created (32 random bytes)"
fi

JOIN_SECRET_ARN="$(aws_ secretsmanager describe-secret \
  --secret-id "${JOIN_SECRET_NAME}" --region "${REGION}" \
  --query ARN --output text)"
JOIN_SECRET_SHA="$(printf '%s' "${JOIN_SECRET_VALUE}" | shasum -a 256 | cut -d' ' -f1)"

info "ARN:    ${JOIN_SECRET_ARN}"
info "SHA256: ${JOIN_SECRET_SHA}"

# ---------------------------------------------------------------------------
# 3. Hiera update prompt
# ---------------------------------------------------------------------------
step '3/5  Hiera update required (paste this into the master cluster file)'

readonly PM_HIERA="../../../cassandra-control-repo/data/customers/${CUSTOMER}/${ENVIRONMENT}/products/puppetmaster/clusters/pm.yaml"
cat <<HIERA_MSG

  Edit:  ${PM_HIERA}
  Set:
    profile_puppetmaster_pfpt::autosign_challenge_password_sha256: '${JOIN_SECRET_SHA}'

  Commit and push. Then continue with step 4.

  Press ENTER when done (or Ctrl-C to stop here).
HIERA_MSG
read -r

# Sanity-check they actually did it
if [[ -f "${HERE}/${PM_HIERA}" ]] && ! grep -q "${JOIN_SECRET_SHA}" "${HERE}/${PM_HIERA}"; then
  echo "WARN: ${PM_HIERA} does not contain the SHA yet. Continuing anyway."
fi

# ---------------------------------------------------------------------------
# 4. Terraform init + apply, master only
# ---------------------------------------------------------------------------
step '4/5  Building the Puppet master'
cd "${HERE}"

cat > backend.hcl <<EOF
bucket  = "${STATE_BUCKET}"
key     = "puppet-estate/${CUSTOMER}-${ENVIRONMENT}/${DATACENTER}/terraform.tfstate"
region  = "${REGION}"
encrypt = true
EOF
ok 'backend.hcl written'

rm -rf .terraform .terraform.lock.hcl
if [[ "${LOCALSTACK_MODE}" == 'yes' ]]; then
  terraform init -input=false \
    -backend-config=backend.hcl \
    -backend-config="skip_credentials_validation=true" \
    -backend-config="skip_metadata_api_check=true" \
    -backend-config="skip_region_validation=true" \
    -backend-config="force_path_style=true" \
    -backend-config="endpoint=${AWS_ENDPOINT}" >/dev/null || die 'terraform init failed'
else
  terraform init -backend-config=backend.hcl -input=false >/dev/null || die 'terraform init failed'
fi
terraform workspace select "${CUSTOMER}-${ENVIRONMENT}-${DATACENTER}" 2>/dev/null || \
  terraform workspace new "${CUSTOMER}-${ENVIRONMENT}-${DATACENTER}" >/dev/null
ok "workspace: $(terraform workspace show)"

terraform apply -input=false -auto-approve \
  -var-file="${TFVARS}" \
  -var 'products=["puppetmaster"]' \
  -var "join_secret_arn=${JOIN_SECRET_ARN}" || die 'master apply failed'
ok 'master created'

# ---------------------------------------------------------------------------
# 5. Route 53 record + wait
# ---------------------------------------------------------------------------
step '5/5  DNS + wait for master convergence'

# Get the master's private IP from Terraform state
MASTER_IP="$(terraform state show 'aws_instance.node["pm1"]' 2>/dev/null | grep 'private_ip' | head -1 | awk '{print $3}' | tr -d '"')"
INSTANCE_ID="$(terraform state show 'aws_instance.node["pm1"]' 2>/dev/null | grep -E '^\s+id\s+=' | head -1 | awk '{print $3}' | tr -d '"')"
[[ -n "${MASTER_IP}" ]] || die 'could not read master private IP from state'
info "master IP: ${MASTER_IP}"
info "instance:  ${INSTANCE_ID}"

if [[ "${LOCALSTACK_MODE}" == 'yes' ]]; then
  info 'LocalStack mode -- Route 53 and SSM wait skipped (mock does not implement them)'
  info 'In real AWS: this step upserts an A record and waits for user-data.done'
else
  # Route 53 upsert
  HOSTED_ZONE_ID="$(aws_ route53 list-hosted-zones-by-name --dns-name "${DNS_DOMAIN}" \
    --query 'HostedZones[0].Id' --output text 2>/dev/null | sed 's|/hostedzone/||')"

  if [[ -n "${HOSTED_ZONE_ID}" && "${HOSTED_ZONE_ID}" != None ]]; then
    aws_ route53 change-resource-record-sets \
      --hosted-zone-id "${HOSTED_ZONE_ID}" \
      --change-batch "{
        \"Changes\": [{
          \"Action\": \"UPSERT\",
          \"ResourceRecordSet\": {
            \"Name\": \"${PUPPET_SERVER}\",
            \"Type\": \"A\",
            \"TTL\": 300,
            \"ResourceRecords\": [{\"Value\": \"${MASTER_IP}\"}]
          }
        }]
      }" >/dev/null || die 'Route 53 update failed'
    ok "${PUPPET_SERVER} -> ${MASTER_IP}"
  else
    info "no Route 53 hosted zone for ${DNS_DOMAIN} -- add ${PUPPET_SERVER} -> ${MASTER_IP} manually"
  fi

  # Wait for the master to finish user-data via SSM
  info "waiting for master user-data to complete (up to 15 min)..."
  for i in $(seq 1 90); do
    cmd_id="$(aws_ ssm send-command \
      --instance-ids "${INSTANCE_ID}" \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["test -f /var/lib/instance/user-data.done && cat /var/lib/instance/user-data.done | head -1 || echo pending"]' \
      --query 'Command.CommandId' --output text 2>/dev/null)"

    if [[ -n "${cmd_id}" ]]; then
      sleep 5
      out="$(aws_ ssm get-command-invocation \
        --command-id "${cmd_id}" \
        --instance-id "${INSTANCE_ID}" \
        --query StandardOutputContent --output text 2>/dev/null)"
      case "${out}" in
        status=ok*) ok 'master user-data finished (status=ok)'; break ;;
        status=*)   die "master finished with ${out}" ;;
      esac
    fi

    printf '.'
    sleep 10
  done
fi

# ---------------------------------------------------------------------------
# Handoff
# ---------------------------------------------------------------------------
cat <<DONE

===========================================================================
Bootstrap complete. Now do the eyaml key ceremony on the master:

  aws ssm start-session --target ${INSTANCE_ID}

  # inside the session:
  sudo openssl genrsa -out /etc/puppetlabs/puppet/eyaml/private_key.pkcs7.pem 4096
  sudo openssl req -new -x509 \\
    -key /etc/puppetlabs/puppet/eyaml/private_key.pkcs7.pem \\
    -out /etc/puppetlabs/puppet/eyaml/public_key.pkcs7.pem \\
    -days 3650 -subj '/CN=eyaml-${CUSTOMER}-${ENVIRONMENT}'
  sudo chown puppet:puppet /etc/puppetlabs/puppet/eyaml/*.pem
  sudo chmod 0600 /etc/puppetlabs/puppet/eyaml/private_key.pkcs7.pem

  # ESCROW the private key (age or KMS) -- see guides/13
  # Then copy the PUBLIC key to your laptop and commit to git:
  #   scp <master>:/etc/puppetlabs/puppet/eyaml/public_key.pkcs7.pem \\
  #     cassandra-control-repo/keys/public_key.pkcs7.pem

Then apply the workload (Cassandra nodes):

  terraform apply -var-file=${TFVARS}

===========================================================================
DONE
