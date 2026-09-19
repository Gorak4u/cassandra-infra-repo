
# ===========================================================================
# USER-DATA, fragment 2 of 4: metadata source -- PLATFORM "aws" (EC2)
# ===========================================================================
#
# Defines load_instance_metadata(). Same contract as every other platform:
# after it returns, the PP_* / PUPPET_* variables are set in the environment.
#
# Reads INSTANCE TAGS from the Instance Metadata Service. Terraform sets those
# tags; see infra/terraform/aws/.
#
# THIS FILE IS THE ONLY THING THAT CHANGES to run the same estate on EC2.
# Fragments 1, 3 and 4 are byte-identical to the local build.
#
# PREREQUISITE, and it is easy to miss: instance tags are NOT exposed through
# IMDS by default. The instance must be launched with
#
#   metadata_options { instance_metadata_tags = "enabled" }
#
# or every lookup below returns 404 and the node refuses to come up. That
# refusal is correct -- see require_var in the prelude -- but the cause is not
# obvious from the message, so it is named here.
#
# SECURITY NOTE. A tag is set by whoever launched the instance, so it is no
# more trustworthy than a fact. It does not need to be: the tag only SEEDS the
# CSR. The Puppet master's autosign policy validates every extension against
# its allowlist before signing, so a mistagged instance is refused rather than
# trusted. The security boundary is the CA, not the tag.
load_instance_metadata() {
  local imds='http://169.254.169.254/latest'
  local token tag_base

  # IMDSv2: a session token is mandatory on any recently-launched instance, and
  # required outright when the instance sets http_tokens = "required" (which it
  # should -- v1 is what SSRF attacks abuse to read instance credentials).
  token="$(curl -sf -X PUT "${imds}/api/token" \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' \
    --retry 3 --retry-delay 2 --max-time 5)" ||
    die 'could not obtain an IMDSv2 token -- is this an EC2 instance, and is IMDS reachable?'

  tag_base="${imds}/meta-data/tags/instance"

  # Fetch one tag. Returns empty on 404 rather than failing, so require_var in
  # the prelude produces the error -- one message naming the missing key,
  # instead of a curl exit code.
  _md() {
    curl -sf -H "X-aws-ec2-metadata-token: ${token}" --max-time 5 "${tag_base}/$1" 2>/dev/null
  }

  # Identity. Tag keys are lower-case pp_* to match the Puppet extension
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
  # instance created before they existed, so 20-common.sh supplies a fallback.
  export PUPPET_PORT="$(_md puppet_port)"
  export CQL_PORT="$(_md cql_port)"
  export JENKINS_PORT="$(_md jenkins_port)"

  # How long this node waits for the previous one's CQL port before joining
  # the ring anyway. Same source and same fallback rule as the ports.
  export BOOTSTRAP_WAIT_TIMEOUT="$(_md bootstrap_wait_timeout)"

  # --- The certname ------------------------------------------------------
  # DERIVED from the instance id by default, and only taken from a tag when
  # explicitly set.
  #
  # This is what lets ONE launch template serve any number of nodes, and it is
  # not a nicety. An Auto Scaling group has a single launch template, so a
  # single set of tags: if pp_certname came from a tag, every instance would
  # request the SAME certname. That is not a degraded mode -- the second
  # node's CSR collides with the first node's existing certificate, and the
  # node cannot register at all.
  #
  # The instance id rather than the private DNS name (ip-10-0-1-23.ec2.internal):
  # the DNS name encodes the IP, so it changes on replacement, while the id is
  # opaque and unique. Neither SURVIVES replacement, which matters for a
  # stateful node -- a replaced Cassandra node gets a new certname and the old
  # certificate has to be cleaned from the CA. If you need a stable identity
  # across replacement, set pp_certname per instance and do not use an ASG.
  # Exported so 20-common.sh can write it as the `domain` fact.
  export PP_DOMAIN="$(_md pp_domain)"

  PP_CERTNAME="$(_md pp_certname)"
  if [[ -z "${PP_CERTNAME}" ]]; then
    local iid domain
    iid="$(curl -sf -H "X-aws-ec2-metadata-token: ${token}" --max-time 5 \
      "${imds}/meta-data/instance-id" 2>/dev/null)"
    domain="${PP_DOMAIN}"
    [[ -n "${iid}" ]] || die 'could not read the instance id from IMDS'
    [[ -n "${domain}" ]] ||
      die 'no pp_certname and no pp_domain tag: cannot build a certname'
    # Must still match the master's autosign_certname_pattern, which for
    # generated names means a pattern like ^i-[0-9a-f]+\.lab\.example\.com$
    # rather than an enumeration of hostnames.
    PP_CERTNAME="${iid}.${domain}"
    log "certname derived from the instance id: ${PP_CERTNAME}"
  fi
  export PP_CERTNAME

  # Provenance, recorded as facts on the node. Not identity, so a missing value
  # here is not fatal.
  export INSTANCE_IP="$(curl -sf -H "X-aws-ec2-metadata-token: ${token}" --max-time 5 \
    "${imds}/meta-data/local-ipv4" 2>/dev/null)"
  export IMAGE_NAME="$(curl -sf -H "X-aws-ec2-metadata-token: ${token}" --max-time 5 \
    "${imds}/meta-data/ami-id" 2>/dev/null)"
  export PROVISIONER='terraform/aws'

  # --- The aws CLI -------------------------------------------------------
  # Both secrets below are fetched with it, and it is NOT a given: Amazon Linux
  # ships it, Ubuntu's official cloud images do not, and this estate's
  # inventory says os: ubuntu2004. Installed ONCE here, ahead of both fetches.
  #
  # An earlier fix installed it inline at the deploy key instead. That left the
  # join secret -- fetched thirty lines above it -- still guarded by a bare
  # `command -v aws` that was false, so the node booted with no
  # challengePassword and nothing but a warning to say so. Same bug, two call
  # sites, one of them fixed: hence a function, called before either.
  ensure_aws_cli() {
    command -v aws >/dev/null 2>&1 && return 0
    log 'aws CLI absent; installing it to fetch secrets'
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq awscli >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y -q awscli >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
      yum install -y -q awscli >/dev/null 2>&1
    fi
    command -v aws >/dev/null 2>&1
  }

  # --- The join secret ---------------------------------------------------
  # NOT a tag. Tags are readable by anything that can describe the instance,
  # and this value is what lets a host join the estate.
  #
  # Fetched from Secrets Manager using the instance's own IAM role: the
  # instance proves its identity to AWS, AWS hands over the secret, user-data
  # uses it once and then scrubs it from disk (see scrub_join_secret in
  # 20-common.sh). Strictly better than the shared secret the local lab uses,
  # because it can be rotated without reprovisioning anything.
  local secret_id region
  secret_id="$(_md join_secret_id)"
  if [[ -n "${secret_id}" ]]; then
    region="$(curl -sf -H "X-aws-ec2-metadata-token: ${token}" --max-time 5 \
      "${imds}/meta-data/placement/region" 2>/dev/null)"
    if ensure_aws_cli; then
      # tr -d, and not cosmetic. A secret written from a Windows shell can
      # carry a trailing carriage return; it survives Secrets Manager, reaches
      # csr_attributes.yaml, and then the master's validator hashes something
      # different from what was hashed when the digest was recorded. The CSR is
      # denied for "challengePassword does not match" and the two values are
      # indistinguishable in every log that prints them.
      #
      # Stripped HERE rather than trusting whoever created the secret, because
      # this is the last point at which the value is still a shell string. A
      # join secret is base64 or hex by construction, so no legitimate one
      # contains whitespace and nothing is lost by removing it.
      export JOIN_SECRET="$(aws secretsmanager get-secret-value \
        --region "${region}" --secret-id "${secret_id}" \
        --query SecretString --output text 2>/dev/null | tr -d '\r\n[:space:]')"
      [[ -n "${JOIN_SECRET:-}" ]] ||
        warn "could not read secret ${secret_id} -- check the instance profile's secretsmanager:GetSecretValue permission"
    else
      warn 'aws CLI not present and could not be installed; cannot fetch the join secret'
    fi
  else
    log 'no join_secret_id tag; proceeding without a challengePassword'
  fi

  # --- Control repo (puppetmaster bootstrap) --------------------------------
  # Not sensitive: it is a git URL. Non-master nodes receive the tag and ignore
  # it -- only 30-role-puppetmaster.sh reads CONTROL_REPO_URL.
  export CONTROL_REPO_URL="$(_md control_repo_url)"

  # Deploy key for private SSH repos. The tag carries the Secrets Manager
  # SECRET ID, never the key itself -- tags are readable by any process on the
  # instance via IMDS. The value is fetched here and scrubbed from disk by
  # 30-role-puppetmaster.sh immediately after the clone completes.
  local deploy_key_secret_id
  deploy_key_secret_id="$(_md control_repo_deploy_key_secret_id)"
  if [[ -n "${deploy_key_secret_id}" ]]; then
    local dk_region
    dk_region="$(curl -sf -H "X-aws-ec2-metadata-token: ${token}" --max-time 5 \
      "${imds}/meta-data/placement/region" 2>/dev/null)"
    # ensure_aws_cli is defined above, with the reasoning. Without the key
    # 30-role-puppetmaster.sh never sets GIT_SSH_COMMAND and the clone fails as
    # "Host key verification failed", which reads as a known_hosts problem and
    # is nothing of the sort.
    if ensure_aws_cli; then
      export CONTROL_REPO_DEPLOY_KEY="$(aws secretsmanager get-secret-value \
        --region "${dk_region}" --secret-id "${deploy_key_secret_id}" \
        --query SecretString --output text 2>/dev/null)"
      [[ -n "${CONTROL_REPO_DEPLOY_KEY:-}" ]] ||
        warn "could not read deploy key ${deploy_key_secret_id} -- check the instance profile's GetSecretValue permission"
    else
      warn 'aws CLI not present and could not be installed; cannot fetch the control repo deploy key'
    fi
  fi

  log "metadata: read from EC2 IMDSv2 tags (platform: aws)"
}
