#!/usr/bin/env bash
# Backup the Puppet CA to encrypted S3/GCS. Run on the Puppet master via cron.
#
# WHY THIS MATTERS: if pm1 dies without a CA backup, every node certificate
# must be reissued -- which means every node has to be re-registered, which
# means downtime for the whole estate. The CA is the master's most important
# state.
#
# What gets backed up:
#   /etc/puppetlabs/puppet/ssl/ca/       (CA cert + private key)
#   /etc/puppetlabs/puppet/ssl/certs/    (signed certificates)
#   /etc/puppetlabs/puppet/ssl/private_keys/  (per-cert private keys)
#   /opt/puppetlabs/server/data/puppetserver/certificate-authority/  (autosign inventory)
#   /etc/puppetlabs/puppet/eyaml/        (eyaml keypair)
#
# Usage:
#   BACKUP_S3_BUCKET=my-puppet-ca-backups ./backup-puppet-ca.sh          (AWS)
#   BACKUP_GCS_BUCKET=my-puppet-ca-backups ./backup-puppet-ca.sh          (GCP)
#   BACKUP_KMS_KEY_ID=alias/puppet-ca-backup ./backup-puppet-ca.sh        (encryption)
#
# Cron entry:
#   0 3 * * * /opt/puppetlabs/bin/backup-puppet-ca.sh

set -euo pipefail

readonly HOSTNAME_S=$(hostname -s)
readonly TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
readonly TARBALL=/tmp/puppet-ca-${HOSTNAME_S}-${TIMESTAMP}.tar.gz
readonly RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-90}

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# --- What to back up ------------------------------------------------------
tar_paths=(
  /etc/puppetlabs/puppet/ssl/ca
  /etc/puppetlabs/puppet/ssl/certs
  /etc/puppetlabs/puppet/ssl/private_keys
  /etc/puppetlabs/puppet/ssl/public_keys
  /etc/puppetlabs/puppet/eyaml
  /etc/puppetlabs/puppet/autosign-policy.json
  /etc/puppetlabs/puppet/csr_attributes.yaml
)
# The autosign inventory (in-memory when service is running; on-disk file too)
[[ -d /opt/puppetlabs/server/data/puppetserver/certificate-authority ]] &&
  tar_paths+=(/opt/puppetlabs/server/data/puppetserver/certificate-authority)

log "creating ${TARBALL}"
tar czf "${TARBALL}" "${tar_paths[@]}" 2>/dev/null || {
  log "ERROR: tar failed"
  exit 1
}

log "size: $(du -h "${TARBALL}" | cut -f1)"

# --- Upload ---------------------------------------------------------------
if [[ -n "${BACKUP_S3_BUCKET:-}" ]]; then
  DEST="s3://${BACKUP_S3_BUCKET}/puppet-ca/${HOSTNAME_S}/${TIMESTAMP}.tar.gz"
  args=(s3 cp "${TARBALL}" "${DEST}")
  if [[ -n "${BACKUP_KMS_KEY_ID:-}" ]]; then
    args+=(--sse aws:kms --sse-kms-key-id "${BACKUP_KMS_KEY_ID}")
  else
    args+=(--sse AES256)
  fi
  log "uploading to ${DEST}"
  aws "${args[@]}" || { log "ERROR: aws s3 cp failed"; exit 1; }

  # Retention: delete anything older than RETENTION_DAYS from this host's prefix
  aws s3 ls "s3://${BACKUP_S3_BUCKET}/puppet-ca/${HOSTNAME_S}/" |
    awk -v cutoff="$(date -u -d "${RETENTION_DAYS} days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"${RETENTION_DAYS}"d +%Y-%m-%d)" \
        '$1 < cutoff { print $4 }' |
    while read -r old; do
      log "removing old backup: ${old}"
      aws s3 rm "s3://${BACKUP_S3_BUCKET}/puppet-ca/${HOSTNAME_S}/${old}"
    done

elif [[ -n "${BACKUP_GCS_BUCKET:-}" ]]; then
  DEST="gs://${BACKUP_GCS_BUCKET}/puppet-ca/${HOSTNAME_S}/${TIMESTAMP}.tar.gz"
  log "uploading to ${DEST}"
  gsutil cp "${TARBALL}" "${DEST}" || { log "ERROR: gsutil cp failed"; exit 1; }
  # GCS retention is best done via a bucket lifecycle rule set once at bucket
  # creation; not managed here.

else
  log "ERROR: set BACKUP_S3_BUCKET or BACKUP_GCS_BUCKET"
  exit 1
fi

# --- Cleanup --------------------------------------------------------------
rm -f "${TARBALL}"
log "done"
