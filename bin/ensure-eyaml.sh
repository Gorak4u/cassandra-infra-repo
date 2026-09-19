#!/usr/bin/env bash
# ===========================================================================
# ensure-eyaml.sh -- keys + encrypted secrets, made ready
# ===========================================================================
#
# What it does, in order:
#
#   1. If the eyaml keypair is missing, generate a matched X.509 one.
#      keys/eyaml/private_key.pkcs7.pem              PRIVATE (gitignored)
#      cassandra-control-repo/keys/public_key.pkcs7.pem  PUBLIC (committed)
#
#   2. If keys/eyaml/plaintext.yaml is missing, create it with the lab
#      defaults. This file is gitignored -- for production edit the values
#      here before the first run.
#
#   3. Re-encrypt every secret in plaintext.yaml with the current public key
#      and write it into its .eyaml file in the control repo.
#
# Custom keys: drop your own PEM files into keys/eyaml/ and public/ before
# running `provision.sh up`. Step 1 is a no-op then.
# Custom secrets: edit keys/eyaml/plaintext.yaml before the first run.
#
# Idempotent. Safe to re-run.

set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO="$(cd "${HERE}/../.." && pwd)"
readonly PRIV="${REPO}/keys/eyaml/private_key.pkcs7.pem"
readonly PUB="${REPO}/cassandra-control-repo/keys/public_key.pkcs7.pem"
readonly PLAIN="${REPO}/keys/eyaml/plaintext.yaml"
readonly EYAML_DIR="${REPO}/cassandra-control-repo/data/secrets/customers/amex/nonprod"

log() { printf '  [eyaml] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Production guard
# ---------------------------------------------------------------------------
# In production the plaintext.yaml MUST NOT exist. Real secrets come from
# Vault / Secrets Manager, encrypted by developers with the public key.
# See guides/13-secrets-in-production.md.
#
# Set INFRA_MODE=production in the environment (CI, prod pipelines) to fail
# fast if a plaintext file is found.
if [[ "${INFRA_MODE:-lab}" == 'production' ]]; then
  if [[ -f "${PLAIN}" ]]; then
    echo "REFUSED: ${PLAIN} exists but INFRA_MODE=production." >&2
    echo "         Plaintext secrets do not belong on disk in production." >&2
    echo "         Delete this file and follow guides/13-secrets-in-production.md." >&2
    exit 1
  fi
  # Auto-generation is also forbidden -- the keypair must be a ceremony on
  # the master, not something a CI script does.
  if [[ ! -f "${PRIV}" || ! -f "${PUB}" ]]; then
    echo "REFUSED: eyaml keypair missing and INFRA_MODE=production." >&2
    echo "         Keys must be generated on the master (see guides/13)." >&2
    exit 1
  fi
  echo "  [eyaml] production mode: keys present, no plaintext, no auto-gen"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Keypair -- generate if missing (openssl, no interactive prompts)
# ---------------------------------------------------------------------------
if [[ -f "${PRIV}" && -f "${PUB}" ]]; then
  log "keypair present (${PRIV}, ${PUB})"
else
  log 'generating a new eyaml X.509 keypair'
  install -d -m 0700 "$(dirname "${PRIV}")"
  install -d -m 0755 "$(dirname "${PUB}")"

  openssl genrsa -out "${PRIV}" 2048 2>/dev/null
  # X.509 cert, not a raw public key: hiera-eyaml's decrypt uses
  # OpenSSL::X509::Certificate.new, which rejects "BEGIN PUBLIC KEY".
  openssl req -new -x509 \
    -key "${PRIV}" \
    -out "${PUB}" \
    -days 3650 \
    -subj '/CN=hiera-eyaml-lab' 2>/dev/null

  chmod 0600 "${PRIV}"
  chmod 0644 "${PUB}"
  log "wrote ${PRIV} (0600)"
  log "wrote ${PUB} (0644, committable)"
fi

# ---------------------------------------------------------------------------
# 2. Plaintext source of truth -- seed with lab defaults if missing
# ---------------------------------------------------------------------------
if [[ ! -f "${PLAIN}" ]]; then
  log "creating ${PLAIN} with LAB defaults"
  cat > "${PLAIN}" <<'PLAINEOF'
# ===========================================================================
# eyaml plaintext source of truth -- GITIGNORED
# ===========================================================================
# Values here are encrypted with the eyaml public key and written into the
# control repo's data/secrets/**/*.eyaml files by bin/ensure-eyaml.sh.
#
# Edit this file with real values BEFORE the first `provision.sh up` in any
# environment that matters. The lab defaults below match the plaintext values
# that appear elsewhere in the lab and are safe to publish -- change them for
# production.
#
# Rotate a secret: edit the value, re-run `provision.sh up`.
# Rotate the keypair: delete keys/eyaml/, re-run `provision.sh up`.

profile_cassandra_pfpt::cassandra_password: 'LabSmoke#Cass123'
profile_puppetmaster_pfpt::autosign_join_secret: 'amex-nonprod-join-2026'
PLAINEOF
  chmod 0600 "${PLAIN}"
fi

# ---------------------------------------------------------------------------
# 3. Encrypt each secret, write it into its .eyaml file
# ---------------------------------------------------------------------------
# The .eyaml file path is derived from the KEY PREFIX:
#   profile_cassandra_pfpt::*     -> secrets/.../cassandra.eyaml
#   profile_puppetmaster_pfpt::*  -> secrets/.../puppetmaster.eyaml
#   profile_jenkins_pfpt::*       -> secrets/.../jenkins.eyaml
prefix_to_file() {
  case "$1" in
    profile_cassandra_pfpt::*)    echo "${EYAML_DIR}/cassandra.eyaml" ;;
    profile_puppetmaster_pfpt::*) echo "${EYAML_DIR}/puppetmaster.eyaml" ;;
    profile_jenkins_pfpt::*)      echo "${EYAML_DIR}/jenkins.eyaml" ;;
    *) return 1 ;;
  esac
}

command -v eyaml >/dev/null 2>&1 || {
  log "WARN: eyaml not on PATH -- skipping re-encryption"
  log "      install with: gem install hiera-eyaml"
  log "      the existing .eyaml files will be used as-is"
  exit 0
}

install -d "${EYAML_DIR}"

# Read plaintext.yaml with python (avoids yq dependency), one key at a time.
python3 -c "
import yaml, sys
with open('${PLAIN}') as f:
    d = yaml.safe_load(f) or {}
for k, v in d.items():
    print(f'{k}\t{v}')
" | while IFS=$'\t' read -r key value; do
  [[ -n "${key}" ]] || continue
  target="$(prefix_to_file "${key}")" || {
    log "WARN: unknown key prefix in ${PLAIN}: ${key}"
    continue
  }

  encrypted="$(eyaml encrypt \
    -s "${value}" \
    --pkcs7-public-key "${PUB}" \
    --pkcs7-private-key "${PRIV}" \
    --output string 2>/dev/null)" || {
    log "ERROR: failed to encrypt ${key}"
    exit 1
  }

  # Write/update the .eyaml file. If the key already exists, replace its line;
  # otherwise append. Keeps existing header comments intact.
  if [[ -f "${target}" ]] && grep -q "^${key}:" "${target}"; then
    # Escape the encrypted value's slashes/ampersands for sed's replacement.
    esc="$(printf '%s' "${encrypted}" | sed -e 's/[\/&]/\\&/g')"
    sed -i.bak "s|^${key}:.*|${key}: ${esc}|" "${target}" && rm -f "${target}.bak"
  else
    [[ -f "${target}" ]] || printf -- '---\n' > "${target}"
    printf '%s: %s\n' "${key}" "${encrypted}" >> "${target}"
  fi

  log "encrypted ${key} -> $(basename "${target}")"
done

log 'done'
