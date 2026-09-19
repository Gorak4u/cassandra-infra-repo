
# ===========================================================================
# USER-DATA, fragment 3 of 4: common bootstrap (platform-independent)
# ===========================================================================
#
# Identical on Docker, EC2 and GCE. Nothing in this file knows which platform
# it is on -- fragment 2 has already put the identity in the environment.
#
# What it does, and deliberately nothing more:
#
#   1. install the prerequisites Puppet itself cannot install (see below)
#   2. install the Puppet agent from the Puppet Platform repository
#   3. record the instance's identity as FACTS
#   4. record the same identity as CSR EXTENSION REQUESTS, which is what
#      actually binds it to the node's certificate
#   5. point the agent at its Puppet master
#
# No JVM, no Cassandra, no tuning. The node is told who it is and where its
# master is, and every other decision is the master's to make from Hiera. If
# this script decided anything about Cassandra, the Hiera hierarchy would stop
# being the single source of truth.

# --- Identity ------------------------------------------------------------
# The whole platform interface, in one call and one list. Adding a platform
# means writing one 10-metadata-*.sh that satisfies this and nothing else.
load_instance_metadata

# Ports come from inventory/defaults.yaml via the platform's metadata. They are
# NOT in the required list below, and the fallbacks here are the safety net for
# one specific case: an instance created before the ports existed in metadata,
# whose tags or attributes simply do not carry them. Failing such a node would
# turn a cosmetic gap into an outage.
#
# These are a FALLBACK, not a second source of truth. If they are ever the
# values actually in use, the platform did not pass the metadata -- check that
# rather than editing these.
: "${PUPPET_PORT:=8140}"
: "${CQL_PORT:=9042}"
: "${JENKINS_PORT:=8080}"
: "${BOOTSTRAP_WAIT_TIMEOUT:=900}"
export PUPPET_PORT CQL_PORT JENKINS_PORT BOOTSTRAP_WAIT_TIMEOUT

for v in PP_CERTNAME PP_PROJECT PP_ENVIRONMENT PP_PRODUCT PP_CLUSTER \
         PP_DATACENTER PP_ROLE PUPPET_SERVER PUPPET_COLLECTION PUPPET_ENVIRONMENT; do
  require_var "$v"
done

log "=========================================================="
log "instance ${PP_CERTNAME}"
log "  tenant      ${PP_PROJECT} / ${PP_ENVIRONMENT}"
log "  product     ${PP_PRODUCT}, cluster ${PP_CLUSTER}"
log "  role        ${PP_ROLE} in ${PP_DATACENTER}"
log "  master      ${PUPPET_SERVER} (${PUPPET_COLLECTION}, env ${PUPPET_ENVIRONMENT})"
log "=========================================================="

# --- OS detection ---------------------------------------------------------
# os-release rather than uname: the package manager, the repository URL shape
# and the prerequisite package names all differ by family, and Ubuntu's family
# IS Debian so the codename is what actually distinguishes focal from jammy.
[[ -r /etc/os-release ]] || die '/etc/os-release is missing; cannot identify this OS'
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_CODENAME="${VERSION_CODENAME:-}"
OS_MAJOR="${VERSION_ID%%.*}"

case "${OS_ID}" in
  ubuntu|debian)          OS_FAMILY='debian' ;;
  rhel|centos|rocky|almalinux) OS_FAMILY='el' ;;
  *) die "unsupported OS '${OS_ID}'; extend this case statement to add it" ;;
esac
log "os: ${OS_ID} ${VERSION_ID} (${OS_FAMILY}, codename '${OS_CODENAME:-none}')"

# --- 1. Prerequisites Puppet cannot install for itself --------------------
# iptables and cron are HARD PREREQUISITES of the Cassandra and Puppet Server
# modules, not things a Puppet run can install on its way past. Both the
# `firewall` and `cron` providers PREFETCH at the start of the transaction, so
# on a host with no iptables binary the run fails during prefetch -- before any
# resource is applied, and therefore before any ordering edge in the catalogue
# could have installed it:
#
#   Error: Could not prefetch firewall provider 'iptables':
#          Command iptables_save is missing
#
# There is no way to fix that from inside a catalogue. It has to come from the
# image or from user-data, which is here. Production RHEL images normally carry
# both, which is why this is rarely noticed -- until someone uses a minimal or
# hardened image and a whole class is silently skipped.
install_prerequisites() {
  log 'installing prerequisites (iptables, cron, curl, ca-certificates)'
  if [[ "${OS_FAMILY}" == 'debian' ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || return 1
    # iptables-persistent pulls in netfilter-persistent, which owns the
    # save/restore the firewall module's rules rely on surviving a reboot.
    apt-get install -y -qq \
      curl ca-certificates gnupg \
      iptables iptables-persistent netfilter-persistent \
      cron || return 1
  else
    "${PKG_MGR}" install -y -q \
      curl ca-certificates \
      iptables iptables-services \
      cronie || return 1
  fi
}

if [[ "${OS_FAMILY}" == 'el' ]]; then
  PKG_MGR='yum'
  command -v dnf >/dev/null 2>&1 && PKG_MGR='dnf'
else
  PKG_MGR='apt-get'
fi

install_prerequisites || die 'could not install prerequisites'

# cron must be RUNNING, not merely installed: the Cassandra module schedules
# backups and repairs as cron entries, and an installed-but-stopped cron means
# they are written and never fire -- which looks exactly like success.
#
# `enable` and `start` are separate steps, on purpose. They fail for different
# reasons and only one of them is fatal to the schedule: enable writes a
# symlink into /etc/systemd/system/multi-user.target.wants (so it fails if that
# path is not writable), while start is what actually gets cron running now.
# Collapsing them into `enable --now` means a failure to enable also skips the
# start, and the schedule is silently dead.
#
# Errors are NOT suppressed. An earlier version sent both to /dev/null and the
# only symptom was a one-line warning with no cause -- the actual message
# ("Read-only file system") was the entire diagnosis.
if [[ "${OS_FAMILY}" == 'debian' ]]; then CRON_UNIT='cron'; else CRON_UNIT='crond'; fi

if systemctl enable "${CRON_UNIT}" 2>&1 | sed 's/^/      /'; then
  log "${CRON_UNIT} enabled at boot"
else
  warn "could not enable ${CRON_UNIT} at boot; it will not survive a restart"
fi

if systemctl start "${CRON_UNIT}" 2>&1 | sed 's/^/      /'; then
  if systemctl is-active --quiet "${CRON_UNIT}"; then
    log "${CRON_UNIT} is running"
  else
    warn "${CRON_UNIT} start reported success but the unit is not active; scheduled backups and repairs will NOT fire"
  fi
else
  warn "could not start ${CRON_UNIT}; scheduled backups and repairs will NOT fire"
fi

# --- 2. The Puppet agent --------------------------------------------------
# Installed from the Puppet Platform repository named by PUPPET_COLLECTION.
# The release package is used rather than a hand-written apt source plus key,
# because Puppet's signing key rotates and the release package is what carries
# the new one.
install_puppet_agent() {
  if [[ -x "${PUPPET_BIN}" ]]; then
    log "puppet-agent already present: $(${PUPPET_BIN} --version)"
    return 0
  fi

  log "installing puppet-agent from ${PUPPET_COLLECTION}"
  if [[ "${OS_FAMILY}" == 'debian' ]]; then
    [[ -n "${OS_CODENAME}" ]] || return 1
    local deb="/tmp/${PUPPET_COLLECTION}-release.deb"
    curl -fsSL --retry 3 --retry-delay 5 \
      -o "${deb}" "https://apt.puppet.com/${PUPPET_COLLECTION}-release-${OS_CODENAME}.deb" || return 1
    dpkg -i "${deb}" || return 1
    rm -f "${deb}"
    apt-get update -qq || return 1
    apt-get install -y -qq puppet-agent || return 1
  else
    "${PKG_MGR}" install -y -q \
      "https://yum.puppet.com/${PUPPET_COLLECTION}-release-el-${OS_MAJOR}.noarch.rpm" || return 1
    "${PKG_MGR}" install -y -q puppet-agent || return 1
  fi

  [[ -x "${PUPPET_BIN}" ]] || return 1
  log "installed puppet-agent $(${PUPPET_BIN} --version)"
}

install_puppet_agent || die 'could not install puppet-agent'

install -d -m 0755 /etc/puppetlabs/puppet /etc/puppetlabs/facter/facts.d "${MARKER_DIR}"

# --- 3. Identity as FACTS -------------------------------------------------
# An external facts file, which Facter reads on every run. These are the FACT
# FALLBACK half of the Hiera hierarchy: every tenancy layer has a
# trusted.extensions path and a facts path, and the trusted one is listed
# first so it always wins once a signed certificate exists.
#
# Facts are still needed, for two reasons:
#
#   1. The Puppet master bootstraps itself with `puppet apply` BEFORE it has a
#      certificate, so on that run trusted.extensions is empty and the fact
#      fallback is the only thing that can resolve its Hiera.
#   2. They are readable with `facter -p` on the box, which makes "what does
#      this node think it is?" answerable without decoding a certificate.
#
# They are NOT a security boundary. A fact is written here, on the node, so a
# compromised node can rewrite it and claim another tenant. That is exactly why
# the hierarchy prefers the certificate, and why the master's autosign policy
# refuses to sign a CSR that does not carry the extensions.
log 'writing instance facts to /etc/puppetlabs/facter/facts.d/instance.yaml'
cat > /etc/puppetlabs/facter/facts.d/instance.yaml <<FACTS
---
# MANAGED BY USER-DATA at first boot. Not a security boundary: see the note in
# the generating script. The authoritative copy of this identity is the node's
# certificate extensions.

# --- Hiera hierarchy keys (fact-fallback layers) ---
customer: '${PP_PROJECT}'
customer_environment: '${PP_ENVIRONMENT}'
product: '${PP_PRODUCT}'
cluster_id: '${PP_CLUSTER}'
datacenter: '${PP_DATACENTER}'
puppet_role: '${PP_ROLE}'

# Domain (everything after the first '.' in the certname). Written as a fact
# so Hiera can interpolate '%{facts.domain}' anywhere the estate's domain
# appears -- dns_alt_names, ssh_node_pattern, autosign_certname_pattern.
# No file in the control repo should hardcode a domain suffix.
domain: '${PP_DOMAIN:-${PP_CERTNAME#*.}}'

# --- Topology ---
rack: '${PP_RACK:-rack1}'
instance_ip: '${INSTANCE_IP:-}'

# --- Provenance: who built this node, when, and from what ---
# Worth recording because the first question about any surprising node is
# "when was this provisioned and by what?", and the answer is otherwise
# archaeology across shell history and container logs.
provisioner: '${PROVISIONER:-infra/provision.sh}'
provisioned_at: '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
provisioned_os: '${OS_ID} ${VERSION_ID}'
image_name: '${IMAGE_NAME:-}'

# --- Puppet ---
puppet_server: '${PUPPET_SERVER}'
puppet_collection: '${PUPPET_COLLECTION}'
puppet_environment: '${PUPPET_ENVIRONMENT}'
FACTS
chmod 0644 /etc/puppetlabs/facter/facts.d/instance.yaml

# --- 3b. Neutralise the ec2_userdata fact (AWS only) ----------------------
# instances.tf sends user-data as base64gzip() -- the master's script is ~31 KB
# and EC2 caps plain user_data at 16 KB. cloud-init decompresses it, so the boot
# is fine, but IMDS still serves the raw gzip at /latest/user-data and Facter
# publishes those bytes as `ec2_userdata`. Puppet serialises the fact set to
# JSON before asking for a catalogue, gzip is not UTF-8, so every agent run dies
# with "Could not render to json: source sequence is illegal/malformed utf-8"
# -- a message naming neither user-data nor gzip.
#
# External facts outrank built-in ones in Facter, so defining the name here
# replaces the value. Better than blocklisting the EC2 group in facter.conf:
# that also drops the useful ec2_metadata, and a bad facter.conf breaks Facter.
if [[ "${PROVISIONER:-}" == 'terraform/aws' ]]; then
  log 'overriding ec2_userdata (gzipped user-data is not valid UTF-8)'
  printf -- "---\n# MANAGED BY USER-DATA: see 20-common.sh. Empty on purpose.\nec2_userdata: ''\n" \
    > /etc/puppetlabs/facter/facts.d/ec2-userdata-override.yaml
  chmod 0644 /etc/puppetlabs/facter/facts.d/ec2-userdata-override.yaml
fi

# --- 4. Identity as CSR EXTENSION REQUESTS --------------------------------
# THIS is the part that matters. These extensions are written into the
# certificate signing request, the master's autosign policy validates them
# against its allowlist, and once signed they are part of the certificate for
# its whole life -- surfacing as $trusted['extensions'] in every catalogue.
#
# They cannot be changed afterwards without revoking and reissuing, which is
# what makes them usable as a tenancy boundary when a fact is not.
#
# Order matters: this file MUST exist before the agent generates its key and
# CSR. An agent that has already submitted a CSR will not add extensions to it
# later -- the certificate has to be revoked and the node re-registered, so
# getting this wrong on first boot means cleaning up by hand.
#
# All six are REGISTERED Puppet shortnames (OIDs under
# 1.3.6.1.4.1.34380.1.1), so no custom OID registration is needed on the
# master. Verified against the installed Puppet's own OID table.
log 'writing CSR extension requests to /etc/puppetlabs/puppet/csr_attributes.yaml'
cat > /etc/puppetlabs/puppet/csr_attributes.yaml <<CSR
---
extension_requests:
  pp_project: '${PP_PROJECT}'
  pp_environment: '${PP_ENVIRONMENT}'
  pp_product: '${PP_PRODUCT}'
  pp_cluster: '${PP_CLUSTER}'
  pp_datacenter: '${PP_DATACENTER}'
  pp_role: '${PP_ROLE}'
CSR

# The join secret goes in the CSR's challengePassword, as a custom attribute.
#
# Custom attributes are NOT copied into the signed certificate -- they exist
# only in the CSR -- which makes them exactly right for a one-time
# provisioning credential and exactly wrong for anything Hiera needs later.
#
# The master holds only a SHA-256 of this value, so the secret itself is never
# on the CA.
if [[ -n "${JOIN_SECRET:-}" ]]; then
  cat >> /etc/puppetlabs/puppet/csr_attributes.yaml <<CSR
custom_attributes:
  # One-time join credential. Removed from disk below, once the certificate
  # has been issued and this file can no longer be of use to anyone.
  challengePassword: '${JOIN_SECRET}'
CSR
fi
# 0600 while it holds the secret: the file is readable by the agent, which runs
# as root, and by nothing else.
chmod 0600 /etc/puppetlabs/puppet/csr_attributes.yaml

# --- 5. Point the agent at its master -------------------------------------
# A minimal puppet.conf: certname, which master, which environment. Everything
# else is the master's to decide.
#
# On a Puppet Server node this file is REPLACED by puppetmaster_pfpt::config
# during the bootstrap run below; what is written here only has to be enough to
# compile that first catalogue.
log "writing puppet.conf pointing at ${PUPPET_SERVER}"
cat > /etc/puppetlabs/puppet/puppet.conf <<CONF
# WRITTEN BY USER-DATA at first boot.
[main]
certname = ${PP_CERTNAME}
server = ${PUPPET_SERVER}
environment = ${PUPPET_ENVIRONMENT}
runinterval = ${PUPPET_RUNINTERVAL:-30m}

[agent]
report = true
# Spread scheduled runs out so four agents do not all hit a single-JRuby
# master at the same second.
splay = true
splaylimit = 60
CONF
chmod 0644 /etc/puppetlabs/puppet/puppet.conf

# --- Helpers used by the role-specific part below -------------------------

# Wait for a TCP port to accept a connection. Uses bash's /dev/tcp rather than
# nc, which is not installed on any of the base images and would be one more
# prerequisite to carry.
wait_for_port() {
  local host="$1" port="$2" timeout="${3:-300}" what="${4:-${host}:${port}}"
  local waited=0
  log "waiting for ${what} (up to ${timeout}s)"
  while (( waited < timeout )); do
    if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
      log "${what} is accepting connections after ${waited}s"
      return 0
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
  warn "${what} did not accept connections within ${timeout}s"
  return 1
}

# Run the agent, treating Puppet's detailed exit codes correctly.
#
#   0  ran, no changes
#   2  ran, made changes            <- SUCCESS, and the usual first-run result
#   4  ran, at least one failure
#   6  ran, made changes AND failed
#
# Conflating 2 with failure is the single most common mistake in scripts that
# drive Puppet, and it makes a perfectly good first run look broken.
run_agent() {
  local attempt="$1" extra=("${@:2}")
  local rc=0
  "${PUPPET_BIN}" agent --test \
    --detailed-exitcodes \
    --server "${PUPPET_SERVER}" \
    --environment "${PUPPET_ENVIRONMENT}" \
    "${extra[@]}" || rc=$?

  case "${rc}" in
    0) log "agent run ${attempt}: no changes (exit 0)"; return 0 ;;
    2) log "agent run ${attempt}: applied changes (exit 2)"; return 0 ;;
    4|6) warn "agent run ${attempt}: resources FAILED (exit ${rc})"; return 1 ;;
    1) warn "agent run ${attempt}: could not compile or connect (exit 1)"; return 1 ;;
    *) warn "agent run ${attempt}: unexpected exit ${rc}"; return 1 ;;
  esac
}

# Drop the one-time join secret once the certificate exists. Leaving it on disk
# would mean every node in the estate carries a credential that can register
# another node, indefinitely.
scrub_join_secret() {
  local cert="/etc/puppetlabs/puppet/ssl/certs/${PP_CERTNAME}.pem"
  [[ -f "${cert}" ]] || return 0
  grep -q 'challengePassword' /etc/puppetlabs/puppet/csr_attributes.yaml 2>/dev/null || return 0

  log 'certificate issued; removing the one-time join secret from disk'
  # The extension_requests are kept: they are a readable record of what this
  # node asked for, and they are already public inside its certificate.
  sed -i '/^custom_attributes:/,$d' /etc/puppetlabs/puppet/csr_attributes.yaml
  sed -i '/^  # One-time join credential/,$d' /etc/puppetlabs/puppet/csr_attributes.yaml
  chmod 0644 /etc/puppetlabs/puppet/csr_attributes.yaml
}

# Record completion. userdata.service has ConditionPathExists=!<marker>, so
# this is what makes provisioning once-per-instance rather than once-per-boot.
finish() {
  local status="$1"
  {
    echo "status=${status}"
    echo "certname=${PP_CERTNAME}"
    echo "role=${PP_ROLE}"
    echo "finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${MARKER}"
  log "user-data finished: ${status}"
  [[ "${status}" == 'ok' ]] || exit 1
  exit 0
}
