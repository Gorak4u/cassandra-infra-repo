
# ===========================================================================
# USER-DATA, fragment 4 of 4: roles 'cassandra_seed' and 'cassandra_node'
# ===========================================================================
#
# This script does NOT install Cassandra. It installs nothing at all.
#
# It waits for the master, then runs the agent. Everything the node becomes --
# the JVM, the Cassandra package and its version, the heap, the seeds, the
# snitch, the schema, the firewall rules, the backup and repair cron entries --
# arrives in the catalogue the master compiles from Hiera, keyed on the
# certificate extensions this node presented when it registered.
#
# That is the property worth having: to change what these nodes run, edit the
# cluster's Hiera file. Nothing in the provisioning layer changes, and no
# node is rebuilt.

# --- Wait for the CA and the compiler -------------------------------------
# The master is built by its own user-data at the same time as these nodes are
# booting, so this is a genuine race on first boot rather than a theoretical
# one. An agent that starts too early fails to get a certificate and, worse,
# can leave a CSR the operator has to clean up.
#
# A generous budget: the master has to install a JVM and Puppet Server, create
# a CA and warm a JRuby interpreter before it can answer anything.
wait_for_port "${PUPPET_SERVER}" "${PUPPET_PORT}" 900 "puppet master ${PUPPET_SERVER}:${PUPPET_PORT}" ||
  die "puppet master ${PUPPET_SERVER} never came up; this node cannot be configured"

# --- Serialise joining the ring ------------------------------------------
# Cassandra requires nodes to join ONE AT A TIME. Two nodes bootstrapping
# simultaneously can calculate overlapping token ranges, and the result is a
# ring that looks healthy and owns some ranges twice -- which surfaces much
# later as inconsistent reads rather than as a startup error.
#
# The dependency comes from the inventory's wait_for column, so the ordering is
# infrastructure data rather than logic buried in here. Port 9042 (CQL) is the
# right signal: the process being up is not enough, the node has to be serving.
#
# Non-fatal on timeout, and that is deliberate. If the previous node is broken,
# a correct-but-stuck chain means the whole cluster never forms and the only
# diagnostic is three nodes waiting. Proceeding produces one clear failure on
# the node that is actually broken.
if [[ -n "${WAIT_FOR:-}" && "${WAIT_FOR}" != '-' ]]; then
  wait_for_port "${WAIT_FOR}" "${CQL_PORT}" 900 "Cassandra on ${WAIT_FOR}:${CQL_PORT}" ||
    warn "${WAIT_FOR} is not serving CQL; joining anyway, which may race its bootstrap"
  # Cassandra reports 9042 open slightly before it has finished announcing
  # itself in gossip. A short settle avoids the next node starting its own
  # bootstrap inside that window.
  log 'letting the previous node settle in gossip for 30s'
  sleep 30
else
  log 'first node in the ring; nothing to wait for'
fi

# --- Register and converge ------------------------------------------------
# The first run does the real work: submits the CSR carrying this node's
# pp_project / pp_environment / pp_product / pp_cluster / pp_datacenter /
# pp_role, has it validated and autosigned by the master's policy, fetches the
# catalogue, and applies it. On a Cassandra node that means a JVM, a package, a
# configuration file, a service, and then schema.
#
# --waitforcert rather than failing immediately: the CSR is autosigned in
# milliseconds when the policy passes, but the round trip is not instant.
#
# If the policy REJECTS this node -- wrong tenant, missing extension, bad join
# secret -- waitforcert means it waits rather than exiting. That is the correct
# behaviour for a node whose certificate a human might sign by hand, and the
# reason the wait is bounded: the run fails and the log says so, instead of
# hanging until the systemd timeout with no explanation.
log "registering with ${PUPPET_SERVER} and fetching the first catalogue"

converged='no'
for attempt in 1 2 3; do
  if run_agent "${attempt}" --waitforcert 20; then
    converged='yes'
    break
  fi
  # Retried because the failures seen here are ordering races that a second
  # pass resolves: the master's single JRuby instance busy compiling for
  # another node, a package mirror timing out, or Cassandra's service taking
  # longer than the module's start timeout on a loaded host. A real
  # misconfiguration fails all three with the same error.
  warn 'retrying agent run in 45s'
  sleep 45
done

scrub_join_secret

if [[ "${converged}" != 'yes' ]]; then
  die 'node did not converge after 3 agent runs; see the runs above for the failing resource'
fi

# --- Confirm the node actually joined ------------------------------------
# A successful Puppet run means every resource applied, which is NOT the same
# as Cassandra having joined the ring: the service can start, fail to gossip,
# and sit there. Checking here means the failure is reported on the node that
# has it, at the moment it happens, rather than being discovered later as a
# missing replica.
if [[ "${PP_PRODUCT}" == 'cassandra' ]]; then
  # The node's OWN address, not localhost.
  #
  # Cassandra binds CQL to listen_address, which this cluster's Hiera sets to
  # the node's address -- so loopback is never bound:
  #
  #   LISTEN 172.30.30.11:9042
  #
  # An earlier version checked localhost:9042 and could therefore never
  # succeed. Two perfectly healthy nodes were marked 'cassandra-not-serving':
  # a FALSE NEGATIVE, not a functional failure, because the cross-node waits
  # above address their target by FQDN and worked correctly -- which is why the
  # ring formed while the self-check said otherwise. That combination is the
  # worst kind of monitoring bug: it reports a problem that is not there, and
  # trains you to ignore the check that would report a real one.
  self_addr="${INSTANCE_IP:-${PP_CERTNAME}}"
  if wait_for_port "${self_addr}" "${CQL_PORT}" 300 "local Cassandra CQL port on ${self_addr}:${CQL_PORT}"; then
    if [[ -x /usr/bin/nodetool ]] || command -v nodetool >/dev/null 2>&1; then
      log 'ring as this node sees it:'
      nodetool status 2>&1 | sed 's/^/    /' || warn 'nodetool status failed'
    fi
  else
    warn 'Puppet converged but Cassandra is not serving CQL on this node'
    finish cassandra-not-serving
  fi
fi

finish ok
