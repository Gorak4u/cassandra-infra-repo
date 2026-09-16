
# ===========================================================================
# USER-DATA, fragment 2 of 4: metadata source -- PLATFORM "local" (Docker)
# ===========================================================================
#
# Defines load_instance_metadata(). Contract, identical for every platform:
#
#   after this function returns, these are set in the environment --
#     PP_CERTNAME PP_PROJECT PP_ENVIRONMENT PP_PRODUCT PP_CLUSTER
#     PP_DATACENTER PP_ROLE PP_RACK
#     PUPPET_SERVER PUPPET_COLLECTION PUPPET_ENVIRONMENT
#     JOIN_SECRET WAIT_FOR INSTANCE_IP IMAGE_NAME PROVISIONER
#
# On this platform there is almost nothing to do, because a container has no
# metadata service. provision.sh generates a per-instance file and mounts it
# read-only at /etc/instance-metadata, and userdata.service loads it with
# EnvironmentFile= -- so the values are already in the environment before this
# script starts.
#
# WHY A FILE AND NOT `docker run -e`
# ----------------------------------
# systemd is PID 1 here, and systemd does not pass its own environment on to
# the services it starts. Variables set with `-e` reach PID 1 and stop there.
# This cost a debugging round to discover.
load_instance_metadata() {
  local mdfile='/etc/instance-metadata'

  # Checked explicitly even though systemd has already read it: if the mount is
  # missing, systemd's EnvironmentFile= fails SILENTLY and every variable is
  # simply unset. Without this check the failure surfaces as ten confusing
  # "missing PP_*" errors instead of one that names the cause.
  [[ -r "${mdfile}" ]] ||
    die "${mdfile} is not readable -- provision.sh should have mounted it read-only"

  # Belt and braces: source it directly too, so the script also works when run
  # by hand for debugging rather than by userdata.service.
  # shellcheck disable=SC1090
  set -a; . "${mdfile}"; set +a

  log "metadata: read from ${mdfile} (platform: local/docker)"
}
