
# ===========================================================================
# USER-DATA, fragment 2 of 4: metadata source -- PLATFORM "gcp" (GCE)
# ===========================================================================
#
# Defines load_instance_metadata(). Same contract as every other platform:
# after it returns, the PP_* / PUPPET_* variables are set in the environment.
#
# Reads custom METADATA ATTRIBUTES from the GCE metadata server. Terraform sets
# those; see infra/terraform/gcp/.
#
# THIS FILE IS THE ONLY THING THAT CHANGES to run the same estate on GCE.
# Fragments 1, 3 and 4 are byte-identical to the local build.
#
# GCE is slightly friendlier than EC2 here: custom metadata needs no
# equivalent of AWS's instance_metadata_tags opt-in, and no session token --
# the Metadata-Flavor header is what prevents a browser or a naive HTTP client
# from being tricked into reading it.
#
# Note: GCE metadata ATTRIBUTES are the right home for this, not LABELS.
# Labels are not exposed through the metadata server at all -- reading them
# would need an API call and IAM permissions, which is a lot of machinery for
# a value you can simply pass in.
#
# SECURITY NOTE. Metadata is set by whoever created the instance, so it is no
# more trustworthy than a fact. It does not need to be: the value only SEEDS
# the CSR. The Puppet master's autosign policy validates every extension
# against its allowlist before signing, so a misconfigured instance is refused
# rather than trusted. The security boundary is the CA, not the metadata.
load_instance_metadata() {
  local md='http://metadata.google.internal/computeMetadata/v1'
  local hdr='Metadata-Flavor: Google'

  # Fail fast and by name if this is not GCE, rather than letting ten
  # individual lookups time out one after another.
  curl -sf -H "${hdr}" --retry 3 --retry-delay 2 --max-time 5 "${md}/" >/dev/null ||
    die 'GCE metadata server is not reachable -- is this a Compute Engine instance?'

  # Returns empty on 404 rather than failing, so require_var in the prelude
  # produces the error -- one message naming the missing key.
  _md() { curl -sf -H "${hdr}" --max-time 5 "${md}/instance/attributes/$1" 2>/dev/null; }

  # Identity. Attribute keys are lower-case pp_* to match the Puppet extension
  # shortnames exactly -- one spelling from Terraform through to Hiera.
  export PP_PROJECT="$(_md pp_project)"
  export PP_ENVIRONMENT="$(_md pp_environment)"
  export PP_PRODUCT="$(_md pp_product)"
  export PP_CLUSTER="$(_md pp_cluster)"
  export PP_DATACENTER="$(_md pp_datacenter)"
  export PP_ROLE="$(_md pp_role)"
  export PP_RACK="$(_md pp_rack)"

  # Puppet wiring.
  export PUPPET_SERVER="$(_md puppet_server)"
  export PUPPET_COLLECTION="$(_md puppet_collection)"
  export PUPPET_ENVIRONMENT="$(_md puppet_environment)"
  export WAIT_FOR="$(_md wait_for)"

  # Ports. Terraform sets these from inventory/defaults.yaml. Absent on an
  # instance created before they existed, so 20-common.sh has a fallback.
  export PUPPET_PORT="$(_md puppet_port)"
  export CQL_PORT="$(_md cql_port)"
  export JENKINS_PORT="$(_md jenkins_port)"

  # How long this node waits for the previous one's CQL port before joining
  # the ring anyway. Same source and same fallback rule as the ports.
  export BOOTSTRAP_WAIT_TIMEOUT="$(_md bootstrap_wait_timeout)"

  # --- The certname ------------------------------------------------------
  # DERIVED from the instance's own name by default, and only taken from
  # metadata when explicitly set.
  #
  # This is what lets ONE instance template serve any number of nodes, and it
  # is not a nicety. A Managed Instance Group has a single instance template,
  # so a single set of metadata attributes: if pp_certname came from metadata,
  # every instance in the group would request the SAME certname. That is not a
  # degraded mode -- the second node's CSR collides with the first node's
  # existing certificate, and the node cannot register at all.
  #
  # The GCE instance name is unique within the project and, for a STATEFUL MIG,
  # stable across instance replacement -- which is exactly the property a
  # certname needs, and exactly why stateful MIGs are the right tool for
  # Cassandra rather than ordinary ones.
  #
  # pp_certname is still honoured, for hand-created one-off instances (a
  # compile master, say) where a chosen name is worth having.
  # Exported so 20-common.sh can write it as the `domain` fact.
  export PP_DOMAIN="$(_md pp_domain)"

  PP_CERTNAME="$(_md pp_certname)"
  if [[ -z "${PP_CERTNAME}" ]]; then
    local iname domain
    iname="$(curl -sf -H "${hdr}" --max-time 5 "${md}/instance/name" 2>/dev/null)"
    domain="${PP_DOMAIN}"
    [[ -n "${iname}" ]] || die 'could not read the instance name from metadata'
    [[ -n "${domain}" ]] ||
      die 'no pp_certname and no pp_domain attribute: cannot build a certname'
    # GCE instance names are RFC1035 (lower-case, no dots), so this always
    # produces a well-formed FQDN -- and it must still match the master's
    # autosign_certname_pattern, which for generated names means a pattern
    # like ^[a-z][a-z0-9-]*\.lab\.example\.com$ rather than an enumeration.
    PP_CERTNAME="${iname}.${domain}"
    log "certname derived from the instance name: ${PP_CERTNAME}"
  fi
  export PP_CERTNAME

  # Provenance, recorded as facts. Not identity, so absence is not fatal.
  export INSTANCE_IP="$(curl -sf -H "${hdr}" --max-time 5 \
    "${md}/instance/network-interfaces/0/ip" 2>/dev/null)"
  export IMAGE_NAME="$(curl -sf -H "${hdr}" --max-time 5 \
    "${md}/instance/image" 2>/dev/null | sed 's#.*/##')"
  export PROVISIONER='terraform/gcp'

  # --- The join secret ---------------------------------------------------
  # NOT plain metadata. Instance metadata is readable by anyone with
  # compute.instances.get, and this value is what lets a host join the estate.
  #
  # Fetched from Secret Manager using the instance's own service account: the
  # instance proves its identity to Google, Google hands over the secret,
  # user-data uses it once and then scrubs it from disk (see
  # scrub_join_secret in 20-common.sh). Rotatable without reprovisioning.
  local secret_name
  secret_name="$(_md join_secret_name)"
  if [[ -n "${secret_name}" ]]; then
    local sa_token
    sa_token="$(curl -sf -H "${hdr}" --max-time 5 \
      "${md}/instance/service-accounts/default/token" 2>/dev/null |
      sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
    if [[ -n "${sa_token}" ]]; then
      # The API returns the payload base64-encoded inside JSON.
      export JOIN_SECRET="$(curl -sf --max-time 10 \
        -H "Authorization: Bearer ${sa_token}" \
        "https://secretmanager.googleapis.com/v1/${secret_name}:access" 2>/dev/null |
        sed -n 's/.*"data": *"\([^"]*\)".*/\1/p' | base64 -d 2>/dev/null)"
      [[ -n "${JOIN_SECRET:-}" ]] ||
        warn "could not read secret ${secret_name} -- check the service account's secretmanager.secretAccessor role"
    else
      warn 'no service-account token available; cannot fetch the join secret'
    fi
  else
    log 'no join_secret_name attribute; proceeding without a challengePassword'
  fi

  # --- Control repo (puppetmaster bootstrap) --------------------------------
  # Not sensitive: it is a git URL. Non-master nodes receive the attribute
  # and ignore it -- only 30-role-puppetmaster.sh reads CONTROL_REPO_URL.
  export CONTROL_REPO_URL="$(_md control_repo_url)"

  # Deploy key for private SSH repos. The attribute carries the Secret Manager
  # RESOURCE NAME (projects/.../secrets/.../versions/...), never the key itself
  # -- metadata attributes are readable by anyone with compute.instances.get.
  # The value is fetched here, used once for the git clone, and scrubbed from
  # disk by 30-role-puppetmaster.sh immediately after the clone completes.
  local deploy_key_secret
  deploy_key_secret="$(_md control_repo_deploy_key_secret)"
  if [[ -n "${deploy_key_secret}" ]]; then
    local dk_token
    dk_token="$(curl -sf -H "${hdr}" --max-time 5 \
      "${md}/instance/service-accounts/default/token" 2>/dev/null |
      sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
    if [[ -n "${dk_token}" ]]; then
      export CONTROL_REPO_DEPLOY_KEY="$(curl -sf --max-time 10 \
        -H "Authorization: Bearer ${dk_token}" \
        "https://secretmanager.googleapis.com/v1/${deploy_key_secret}:access" \
        2>/dev/null | sed -n 's/.*"data": *"\([^"]*\)".*/\1/p' | base64 -d 2>/dev/null)"
      [[ -n "${CONTROL_REPO_DEPLOY_KEY:-}" ]] ||
        warn "could not read deploy key ${deploy_key_secret} -- check the service account's secretAccessor role"
    else
      warn 'could not obtain a service-account token; cannot fetch the control repo deploy key'
    fi
  fi

  log "metadata: read from GCE metadata attributes (platform: gcp)"
}
