
# ===========================================================================
# USER-DATA, fragment 4 of 4: role 'jenkins'
# ===========================================================================
#
# This script does NOT install Jenkins. It installs nothing at all.
#
# It waits for the master, then runs the agent. Everything the node becomes --
# the Jenkins package and its version, the pinned plugin set, the cassy
# orchestration script and its playbooks, and the Job DSL seed job that
# generates every Cassandra pipeline -- arrives in the catalogue the master
# compiles from Hiera, keyed on the certificate extensions this node presented
# when it registered.
#
# Identical in shape to 30-role-cassandra-node.sh, and deliberately so: the
# provisioning layer does not know what a product is. The differences are that
# there is no ring to join, so no WAIT_FOR handling, and the self-check is an
# HTTP listener rather than a CQL port.

# --- Wait for the CA and the compiler -------------------------------------
# The master may be built by its own user-data at the same time this node is
# booting, so this is a genuine race on first boot. An agent that starts too
# early fails to get a certificate and can leave a CSR an operator has to
# clean up.
wait_for_port "${PUPPET_SERVER}" "${PUPPET_PORT}" 900 "puppet master ${PUPPET_SERVER}:${PUPPET_PORT}" ||
  die "puppet master ${PUPPET_SERVER} never came up; this node cannot be configured"

# --- Register and converge ------------------------------------------------
# The first run submits the CSR carrying this node's pp_project /
# pp_environment / pp_product / pp_cluster / pp_datacenter / pp_role, has it
# validated and autosigned by the master's policy, then fetches and applies
# the catalogue.
#
# NOTE FOR A MULTI-MASTER ESTATE: this node's master comes from the
# inventory's puppet_server, and that master's autosign policy must allow
# pp_product=jenkins and pp_role=jenkins. If it does not, the CSR is refused
# and --waitforcert means this waits rather than exits -- which looks exactly
# like a network problem. See guides/09.
log "registering with ${PUPPET_SERVER} and fetching the first catalogue"

converged='no'
for attempt in 1 2 3; do
  if run_agent "${attempt}" --waitforcert 20; then
    converged='yes'
    break
  fi
  # Retried because the failures seen here are ordering races a second pass
  # resolves: the master's JRuby busy compiling for another node, or a package
  # mirror timing out. A real misconfiguration fails all three the same way.
  #
  # Jenkins' own first start is slow -- it unpacks its war and loads the
  # plugins this catalogue just downloaded -- so the module's service resource
  # can time out on a loaded host while the service is in fact coming up.
  warn 'retrying agent run in 45s'
  sleep 45
done

scrub_join_secret

if [[ "${converged}" != 'yes' ]]; then
  die 'node did not converge after 3 agent runs; see the runs above for the failing resource'
fi

# --- Confirm Jenkins actually came up ------------------------------------
# A successful Puppet run means every resource applied, which is NOT the same
# as Jenkins serving: the unit can be active while Jenkins is still unpacking,
# or refusing to start because a pinned plugin's dependency is missing.
#
# Checked on this node's OWN address rather than localhost -- the same false
# negative that bit the Cassandra fragment, where a localhost check could
# never succeed because the service binds a specific address.
if [[ "${PP_PRODUCT}" == 'jenkins' ]]; then
  self_addr="${INSTANCE_IP:-${PP_CERTNAME}}"
  if wait_for_port "${self_addr}" "${JENKINS_PORT}" 600 "Jenkins HTTP on ${self_addr}:${JENKINS_PORT}"; then
    log "Jenkins is serving on ${self_addr}:${JENKINS_PORT}"

    # The seed job is the thing that makes this node useful, and it is the
    # part that was missing from the module entirely. Report whether it landed
    # so a half-configured server is visible here rather than discovered when
    # somebody goes looking for a pipeline.
    if [[ -f /var/lib/jenkins/jobs/cassandra-seed/config.xml ]]; then
      log 'seed job present; run it once to generate the Cassandra pipelines'
    else
      warn 'no seed job on disk -- profile_jenkins_pfpt::manage_seed_job may be false'
    fi
  else
    warn 'Puppet converged but Jenkins is not serving HTTP on this node'
    warn 'usually a plugin dependency: journalctl -u jenkins | grep -i "failed to load"'
    finish jenkins-not-serving
  fi
fi

finish ok
