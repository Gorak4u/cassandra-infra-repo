
# ===========================================================================
# USER-DATA, fragment 4 of 4: role 'puppetmaster'
# ===========================================================================
#
# Solves the bootstrap problem: this node must become the thing that
# configures every other node, so it cannot be configured BY one.
#
# The standard answer, and the one used here, is a MASTERLESS RUN. The node
# applies the very same role class from the very same control repo with
# `puppet apply`, and the result is a running Puppet Server. After that it is
# managed like anything else -- by an agent, against itself.
#
# Nothing about the master's configuration is decided in this script. The
# Puppet Server version, its heap, its JRuby instance count, its DNS alt names,
# its autosign policy and its allowlist all come from Hiera, resolved through
# the same 29-layer hierarchy every other node uses. This script only decides
# WHEN to run.

readonly CODEDIR='/etc/puppetlabs/code'
readonly ENV_DIR="${CODEDIR}/environments/${PUPPET_ENVIRONMENT}"
readonly MOUNTED_REPO='/opt/control-repo'

log "bootstrapping Puppet Server, environment '${PUPPET_ENVIRONMENT}'"

# --- Put the control repo where Puppet looks for environments -------------
# In this lab the repo is bind-mounted read-only at /opt/control-repo and
# symlinked into place here, so an edit to a manifest or a Hiera file on the
# developer's machine is live on the master with no deploy step.
#
# It is NOT mounted directly at ${ENV_DIR}, and the reason is worth recording:
# the puppet-agent package itself ships
# environments/production/environment.conf, so a read-only mount at that path
# makes the agent's own installation fail during unpack --
#
#   dpkg: error processing archive puppet-agent_8.10.0-1focal_arm64.deb:
#     unable to create '.../production/environment.conf.dpkg-new':
#     Read-only file system
#
# -- and mounting it read-write instead would be worse, because dpkg would then
# write the package's own environment.conf into the developer's checkout.
#
# The symlink is created AFTER the agent is installed, which is why this runs
# here in fragment 4 and not in the common fragment.
#
# In production this block is where the code arrives by a real mechanism
# instead: `git clone` plus `r10k deploy environment`, or a pre-baked image.
# Which one is a genuine decision -- cloning in user-data means the master
# needs a deploy key at first boot -- and CONTROL_REPO_URL is plumbed through
# the metadata for exactly that case.
install -d -m 0755 "${CODEDIR}/environments"

if [[ -d "${MOUNTED_REPO}" ]]; then
  # The agent package left its own stub environment here. Replacing it with the
  # real control repo is the point of this step.
  if [[ -e "${ENV_DIR}" && ! -L "${ENV_DIR}" ]]; then
    log "replacing the package's stub environment at ${ENV_DIR}"
    rm -rf "${ENV_DIR}" || die "could not remove ${ENV_DIR}"
  fi
  ln -sfn "${MOUNTED_REPO}" "${ENV_DIR}" || die "could not link ${ENV_DIR} -> ${MOUNTED_REPO}"
  log "${ENV_DIR} -> ${MOUNTED_REPO} (read-only mount)"
elif [[ -n "${CONTROL_REPO_URL:-}" ]]; then
  log "no repo mounted; cloning ${CONTROL_REPO_URL}"
  rm -rf "${ENV_DIR}"

  # An SSH remote with no key is a guaranteed failure, and left to itself it
  # fails as the WRONG error. Without CONTROL_REPO_DEPLOY_KEY the block below
  # never runs, so GIT_SSH_COMMAND is unset, so git uses plain ssh with default
  # host checking and the clone dies with
  #
  #   Host key verification failed.
  #
  # -- which sends you to known_hosts and StrictHostKeyChecking, neither of
  # which is the problem. The problem is that there is no key. Said here, by
  # name, before a single git command runs.
  if [[ "${CONTROL_REPO_URL}" =~ ^(git@|ssh://) ]] && [[ -z "${CONTROL_REPO_DEPLOY_KEY:-}" ]]; then
    die "no deploy key for ${CONTROL_REPO_URL}. CONTROL_REPO_DEPLOY_KEY is empty, so this clone would fail as a host key error. Check, in order: the control_repo_deploy_key_secret_id tag on this instance, the instance profile's secretsmanager:GetSecretValue on that secret, and whether the aws CLI is installed (Ubuntu images do not ship it)."
  fi

  # Private repos: write the deploy key before the clone and scrub it after.
  # GIT_SSH_COMMAND scopes the key to this process only -- it never touches the
  # SSH agent, so it cannot be used by any other process on the node.
  if [[ -n "${CONTROL_REPO_DEPLOY_KEY:-}" ]]; then
    install -d -m 0700 /root/.ssh
    printf '%s\n' "${CONTROL_REPO_DEPLOY_KEY}" > /root/.ssh/id_control_repo
    chmod 0600 /root/.ssh/id_control_repo
    # accept-new: trust the host key on first contact without prompting.
    # BatchMode: fail immediately rather than hanging on any interactive prompt.
    export GIT_SSH_COMMAND='ssh -i /root/.ssh/id_control_repo -o StrictHostKeyChecking=accept-new -o BatchMode=yes'
    log 'deploy key written for the clone'
  fi

  # --branch: the control repo's branches ARE its environments.
  git clone --branch "${PUPPET_ENVIRONMENT}" "${CONTROL_REPO_URL}" "${ENV_DIR}" ||
    die "could not clone ${CONTROL_REPO_URL} (branch: ${PUPPET_ENVIRONMENT})"

  # Scrub immediately: the key is not needed again. r10k's own credential
  # (configured by the puppetmaster_pfpt module from Hiera) handles subsequent
  # deploys. Leaving it on disk would give any process running as root a
  # persistent read credential for the control repo.
  if [[ -f /root/.ssh/id_control_repo ]]; then
    rm -f /root/.ssh/id_control_repo
    unset GIT_SSH_COMMAND CONTROL_REPO_DEPLOY_KEY
    log 'deploy key removed from disk'
  fi

  # r10k: install third-party modules from the Puppetfile so the bootstrap
  # apply has everything it needs to compile the first catalogue.
  #
  # The puppetmaster_pfpt module installs r10k permanently and configures it
  # for ongoing deploys; this covers only the bootstrap.
  #
  # Lookup order:
  #   1. System PATH -- present when the base image pre-installs r10k.
  #      The recommended approach for AWS, where user-data is size-constrained.
  #   2. Puppet's gem environment -- used on GCP and other unconstrained
  #      platforms. Requires internet access to rubygems.org or an internal
  #      gem mirror (Cloud NAT satisfies this on GCP).
  # NOT `local`: this fragment runs at top level, not inside a function, and
  # bash refuses it there --
  #
  #   /var/lib/cloud/instance/scripts/part-001: line 768:
  #   local: can only be used in a function
  #
  # Harmless in the end, because the assignments below set it as a global
  # anyway, but it printed an error into the boot log on every single run and
  # sent whoever read it looking for a bug that was not there.
  r10k_bin=''
  if command -v r10k >/dev/null 2>&1; then
    r10k_bin='r10k'
  elif [[ -x /opt/puppetlabs/puppet/bin/r10k ]]; then
    r10k_bin='/opt/puppetlabs/puppet/bin/r10k'
  else
    log 'r10k not found; installing via puppet gem (requires internet access)'
    /opt/puppetlabs/puppet/bin/gem install r10k --no-document 2>&1 | sed 's/^/  /' ||
      die 'gem install r10k failed; pre-install r10k in the base image or stage via S3'
    r10k_bin='/opt/puppetlabs/puppet/bin/r10k'
  fi

  log "deploying Puppetfile modules (${r10k_bin})"
  "${r10k_bin}" puppetfile install \
    --puppetfile "${ENV_DIR}/Puppetfile" \
    --moduledir  "${ENV_DIR}/modules" 2>&1 | sed 's/^/  /' ||
    die 'r10k puppetfile install failed; check the Puppetfile and Forge connectivity'
else
  die "no control repo at ${MOUNTED_REPO} and CONTROL_REPO_URL is unset; nothing to apply"
fi

for required in "${ENV_DIR}/manifests/site.pp" "${ENV_DIR}/hiera.yaml" "${ENV_DIR}/environment.conf"; do
  [[ -f "${required}" ]] || die "control repo at ${ENV_DIR} is incomplete: ${required} is missing"
done
log "control repo present: $(find "${ENV_DIR}/data" -name '*.yaml' | wc -l | tr -d ' ') Hiera files, \
$(find "${ENV_DIR}/site-modules" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ') site modules"

# --- Masterless apply -----------------------------------------------------
# --environment makes Puppet read this environment's own environment.conf (for
# modulepath) and hiera.yaml (for data), so the masterless run resolves exactly
# what a catalogue compiled by the server later will.
#
# On THIS run $trusted['extensions'] is empty -- there is no certificate yet,
# because the CA does not exist until this run creates it. Every tenancy layer
# in the hierarchy therefore resolves through its FACT fallback, which is why
# 00-common.sh wrote those facts. This is the one node in the estate, and the
# one run on it, that genuinely needs them.
#
# From the NEXT run onwards it does not: verified on a live master that
# `puppetserver ca setup` reads csr_attributes.yaml, so the master's own
# certificate ends up carrying all six pp_* extensions exactly as an agent's
# does, and it resolves Hiera through trusted.extensions like everything else.
# (It also gains pp_cli_auth, which ca setup adds for CA CLI authorisation.)
# The facts remain as a migration aid and as a way to answer "what does this
# node think it is?" without decoding a certificate.
run_apply() {
  local attempt="$1"
  local rc=0
  "${PUPPET_BIN}" apply \
    --environment "${PUPPET_ENVIRONMENT}" \
    --detailed-exitcodes \
    --write-catalog-summary \
    -e 'include role_puppetmaster_pfpt' || rc=$?

  case "${rc}" in
    0) log "apply ${attempt}: no changes (exit 0)"; return 0 ;;
    2) log "apply ${attempt}: applied changes (exit 2)"; return 0 ;;
    *) warn "apply ${attempt}: exit ${rc}"; return 1 ;;
  esac
}

# Up to three attempts. Not papering over failures -- the failures this retries
# are specifically ordering races that resolve themselves on a second pass:
# a package whose post-install has not finished creating the `puppet` user when
# a File resource wants to chown to it, and the first CA generation racing the
# service start. A genuine misconfiguration fails all three and the log shows
# the same error three times, which is itself the diagnosis.
bootstrapped='no'
for attempt in 1 2 3; do
  if run_apply "${attempt}"; then
    bootstrapped='yes'
    break
  fi
  warn "retrying bootstrap apply in 20s"
  sleep 20
done
[[ "${bootstrapped}" == 'yes' ]] && log 'Puppet Server bootstrap apply succeeded' ||
  die 'Puppet Server bootstrap failed after 3 attempts; see the apply output above'

# --- Prove the server is actually serving ---------------------------------
# The apply declaring success is not the same as the server being usable: the
# module's own readiness gate only fires when it restarts the service, so on a
# steady-state run nothing has checked. Agents are about to depend on this, and
# a master that is up but not answering produces failures on three other nodes
# that look like their problem.
# localhost is CORRECT here, unlike the Cassandra self-check in the sibling
# script. puppetmaster_pfpt writes webserver.conf with ssl-host = 0.0.0.0, so
# loopback is bound. Cassandra binds CQL to listen_address only, which is the
# node's own address and never loopback -- do not "fix" this one by symmetry
# with that one.
wait_for_port localhost "${PUPPET_PORT}" 300 "puppetserver on localhost:${PUPPET_PORT}" ||
  die "puppetserver is not listening on ${PUPPET_PORT} after a successful apply"

# --- Become a managed node ------------------------------------------------
# From here the master is managed the same way as everything else: by an agent
# run against itself, through the server, with a real certificate.
#
# This also gets the master a certificate carrying its pp_* extensions, so that
# subsequent runs resolve Hiera through trusted.extensions like every other
# node instead of through the fact fallback.
#
# --waitforcert: the master autosigns its own CSR via the policy validator, and
# that takes a moment. Without it the run fails outright on the first attempt
# rather than waiting the couple of seconds needed.
log 'running the agent against the newly built master'
agent_ok='no'
for attempt in 1 2 3; do
  if run_agent "${attempt}" --waitforcert 15; then
    agent_ok='yes'
    break
  fi
  warn 'retrying agent run in 30s'
  sleep 30
done

scrub_join_secret

if [[ "${agent_ok}" == 'yes' ]]; then
  log 'master is up and managing itself'
  finish ok
fi

# The server is running and serving catalogues -- the apply and the port check
# both passed -- so the estate is usable even though the master's own agent run
# did not converge. Reported as a failure so it is not silently ignored, but
# deliberately AFTER the server is confirmed up, so the diagnosis is "the
# master could not manage itself" and not "the master never came up".
warn 'puppetserver is serving, but the master could not converge against itself'
finish agent-failed
