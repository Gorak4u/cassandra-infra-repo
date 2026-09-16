#!/usr/bin/env bash
# ===========================================================================
# provision.sh -- the lab's cloud provider
# ===========================================================================
#
# Creates RAW machines and nothing else. No Puppet, no JVM, no Cassandra: the
# instances come up as bare as an EC2 or GCE instance from a base image, with
# two things attached that a real cloud also attaches --
#
#   an instance metadata document   (who am I, who is my master)
#   a user-data script              (run once, at first boot, by the instance)
#
# -- and then this script gets out of the way. It does not exec into a node to
# install anything, and it does not run Puppet. Every package and every config
# file on every node arrives because the node asked its Puppet master for a
# catalogue, and the master built one from the control repo's Hiera.
#
# That boundary is the point of the exercise. Everything here is
# INFRASTRUCTURE (Terraform's job in a real estate, in a different repo with a
# different review process); everything in ../cassandra-control-repo is
# CONFIGURATION.
#
# Usage:
#   ./provision.sh teardown     destroy every instance and the network
#   ./provision.sh up           create the network and the raw instances
#   ./provision.sh wait         block until every instance finishes user-data
#   ./provision.sh status       one line per instance: boot, cert, service
#   ./provision.sh verify       end-to-end assertions, exit 1 on any failure
#   ./provision.sh logs <node>  that instance's user-data log
#   ./provision.sh ssh <node>   a shell on an instance
#   ./provision.sh explain <node> <key>
#                               which Hiera layer wins for <key> on <node>,
#                               asked of the master as that node
#   ./provision.sh layers <node>
#                               a table of representative keys and the layer
#                               each one came from -- the precedence order,
#                               demonstrated
#   ./provision.sh render <node>
#                               print the user-data that node would run,
#                               without creating anything. Honours PLATFORM,
#                               so `PLATFORM=aws ./provision.sh render cass1`
#                               shows the EC2 variant from your laptop.
#   ./provision.sh all          teardown, up, wait, verify
#
# Written for bash 3.2 (macOS ships 3.2.57), so no associative arrays and no
# ${var,,}. Parallel indexed arrays instead.

set -uo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO="$(cd "${HERE}/.." && pwd)"
readonly CONTROL_REPO="${PUPPET_CONTROL_REPO:-${REPO}/cassandra-control-repo}"
# The inventory is GENERATED from infra/inventory/ -- one file per customer
# per environment, mirroring the control repo's Hiera layout. See
# bin/expand-inventory.py for why, and for what it validates.
#
# Filters, so a laptop can materialise a slice of an inventory that describes
# far more than it can run:
#   CUSTOMER=amex ENVIRONMENT=nonprod LIMIT=3 ./provision.sh up
readonly INVENTORY_DIR="${HERE}/inventory"
readonly EXPANDER="${HERE}/bin/expand-inventory.py"
readonly SIZING_CHECK="${HERE}/bin/check-sizing.py"
readonly ENSURE_EYAML="${HERE}/bin/ensure-eyaml.sh"
readonly USERDATA_DIR="${HERE}/user-data"
readonly STATE="${HERE}/.state"

readonly PLATFORM="${PLATFORM:-local}"

readonly NETWORK='pupnet'
readonly SUBNET='172.30.30.0/24'

# Puppet Platform collection and environment, and the estate's ports.
#
# ALL FROM inventory/defaults.yaml, not from here. They were literals in this
# script while defaults.yaml already declared them, which is two sources for
# one fact -- and the port copies were worse than untidy: the AWS security
# group, the GCP firewall and the node's own health checks each had their own
# 9042, so setting profile_cassandra_pfpt::native_transport_port in Hiera gave
# you a ring that formed and then refused every client.
#
# The fallbacks are today's values, so an older defaults.yaml still works.
# Defined after inv_default(), which is why this block sits here rather than
# with the other readonlys at the top.

# Which metadata source the assembled user-data will use: selects
# user-data/10-metadata-${PLATFORM}.sh.
#
# 'local' is the only value this script can actually PROVISION -- it creates
# Docker containers and nothing else. The knob exists so that
# `PLATFORM=aws ./provision.sh` can be used to render and inspect exactly the
# user-data a cloud instance would receive, without leaving your laptop:
#
#   PLATFORM=aws ./provision.sh render cass1
#
# Real cloud provisioning is Terraform's job, not this script's. See
# infra/terraform/ and guides/04-provisioning-beyond-the-lab.md.

# The one-time join credential placed in each node's CSR as its
# challengePassword. The master holds only its SHA-256, in
# data/customers/amex/nonprod/products/puppetmaster/clusters/pm.yaml, so the
# plaintext never reaches the CA.
#
# In a real estate this comes from the provisioning system's secret store and
# is per-batch or per-node. Hardcoded here because a lab that needs a vault to
# start is a lab nobody starts.
readonly JOIN_SECRET="${PUPPET_JOIN_SECRET:-amex-nonprod-join-2026}"

# Per-node memory now comes from the inventory's `sizing:` shape (the `mem`
# column of the expansion), not from a constant here -- so a cluster's machine
# size lives next to its node count, and bin/check-sizing.py can cross-check it
# against the JVM heap in Hiera.
#
# The note below is kept because the NUMBER is hard-won and belongs somewhere
# permanent; it now lives in inventory/defaults.yaml under sizing.small.
#
# 2048m is MEASURED, not guessed. A Cassandra node with the 640M heap this
# cluster's Hiera sets settles at about 1.74 GiB RSS -- the heap is only part of
# the footprint, alongside off-heap memtables, the file cache, metaspace and
# direct buffers. An earlier 1400m limit produced a silent crash loop:
#
#   Active: activating (auto-restart) (Result: oom-kill)
#
# with Cassandra's own log showing a clean, complete startup every time, right
# up to the moment the kernel killed it. Nothing in the Puppet run failed, so
# the node reported success and never served CQL.
#
# The master is given the same, having been observed at 1.34 GiB with a 1g
# JRuby heap -- 86% of a 1.56 GiB limit, which is not headroom.


# --- Console --------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi
step() { printf '\n%s==> %s%s\n' "${C_BOLD}${C_BLUE}" "$*" "${C_RESET}"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s[ ok ]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
bad()  { printf '    %s[FAIL]%s %s\n' "${C_RED}" "${C_RESET}" "$*"; }
warn() { printf '    %s[warn]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"; }
die()  { printf '\n%sFATAL%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; exit 1; }

# ===========================================================================
# OS table -- the lab's machine images
# ===========================================================================
# litmusimage images are used because they boot systemd as PID 1, which a
# normal distro image in a container does not. They are otherwise bare: no
# puppet, no java, no iptables, no cron. Verified empirically on
# litmusimage/ubuntu:20.04 -- `command -v puppet java cassandra iptables
# crontab curl` finds nothing at all.
#
# The multi-OS requirement lives here: change an instance's `os` column in
# inventory.conf and nothing else needs to change, because the OS-conditional
# values (package names, truststore paths, repo shapes) come from the
# control repo's os/ Hiera layers.
os_image() {
  case "$1" in
    ubuntu2004) echo 'litmusimage/ubuntu:20.04 linux/arm64' ;;
    ubuntu2204) echo 'litmusimage/ubuntu:22.04 linux/arm64' ;;
    debian11)   echo 'litmusimage/debian:11 linux/arm64' ;;
    rocky8)     echo 'litmusimage/rockylinux:8 linux/arm64' ;;
    rocky9)     echo 'litmusimage/rockylinux:9 linux/arm64' ;;
    *) return 1 ;;
  esac
}

# ===========================================================================
# Inventory
# ===========================================================================
N_CERTNAME=(); N_IP=(); N_OS=(); N_ROLE=(); N_PRODUCT=(); N_CLUSTER=()
N_CUSTOMER=(); N_ENV=(); N_DC=(); N_RACK=(); N_WAIT=(); N_MEM=(); N_SHORT=()
N_PUPPET_SERVER=()

# The master a node talks to is PER NODE (N_PUPPET_SERVER, resolved by the
# expander from the inventory's puppet_server layers), because one customer's
# products can be served by different masters.
#
# MASTER_CERTNAME is something narrower: the master this script's own
# estate-wide subcommands act on -- `ca`, `explain`, the tenancy checks in
# `verify`. Those inspect the CA and compile catalogues, which is a
# single-master operation, so with several masters it is the FIRST in the
# expansion and the others are listed for the operator.
MASTER_CERTNAME=''; MASTER_IP=''; MASTER_ALL=()

# Read one scalar out of defaults.yaml by DOTTED PATH, e.g.
# `inv_default ports.cassandra_cql`. Uses python3, which the expander already
# requires, rather than grepping YAML -- an indentation-sensitive grep is
# exactly the kind of thing that works until someone reformats the file.
#
# Second argument is the fallback, used when the key is absent. Every caller
# passes one, so an older defaults.yaml still works rather than producing an
# empty string that surfaces three steps later as something unrelated.
inv_default() {
  python3 -c "
import yaml
try:
    d = yaml.safe_load(open('${INVENTORY_DIR}/defaults.yaml')) or {}
    for k in '$1'.split('.'):
        d = d[k]
    print(d)
except Exception:
    print('$2')
" 2>/dev/null
}

default_slice() { inv_default "local_slice.$1" ''; }

readonly PUPPET_COLLECTION="$(inv_default puppet.collection 'puppet8')"
readonly PUPPET_ENVIRONMENT="$(inv_default puppet.environment 'production')"

# Ports are the estate-wide defaults until a slice is chosen; read_inventory()
# re-reads them through the customer+environment file, which may override any
# of them. NOT readonly for that reason.
#
# WHY THE OVERRIDE EXISTS. Hiera can set a port per environment -- and does:
# products/jenkins/environments/nonprod.yaml puts every customer's nonprod
# Jenkins on 8081. With only an estate-wide number here, the firewall and this
# script's health checks would be permanently wrong for that tier, and wrong in
# the quiet direction: the service is up, Puppet is green, and the port nobody
# opened is the one it is listening on.
#
# Infra still cannot READ Hiera -- that would invert the dependency. The two
# files state the number independently and bin/check-ports.py compares them.
PORT_PUPPET="$(inv_default ports.puppet '8140')"
PORT_CQL="$(inv_default ports.cassandra_cql '9042')"
PORT_JENKINS="$(inv_default ports.jenkins_http '8080')"

# Control repo URL. Read from defaults.yaml first; overridden per
# customer+environment in read_inventory() below, same pattern as ports.
# Empty on the local driver: the repo is bind-mounted, not cloned.
CONTROL_REPO_URL="$(inv_default 'control_repo_url' '')"

# Read one scalar out of a customer+environment inventory file by dotted path,
# falling back to the value already resolved from defaults.yaml.
inv_env() {
  local envfile="${INVENTORY_DIR}/customers/$1/$2.yaml"
  [[ -f "${envfile}" ]] || { printf '%s\n' "$4"; return; }
  python3 -c "
import yaml
try:
    d = yaml.safe_load(open('${envfile}')) or {}
    for k in '$3'.split('.'):
        d = d[k]
    print(d)
except Exception:
    print('$4')
" 2>/dev/null
}

read_inventory() {
  [[ -x "${EXPANDER}" ]] || die "cannot execute ${EXPANDER}"

  # Expanded into a file rather than read through a pipe, so a generator
  # failure is reported as itself. Through `while read < <(...)` a failed
  # expansion is indistinguishable from an empty inventory, and the error the
  # operator needs is the one the generator printed.
  local expanded="${STATE}/inventory.expanded"
  install -d "${STATE}" 2>/dev/null
  # With no filter, fall back to the default slice in inventory/defaults.yaml.
  # Without this, a bare `up` against an inventory that describes several
  # customers would try to create every node in the estate -- and this machine
  # fits about five containers.
  local slice_customer="${CUSTOMER:-}" slice_env="${ENVIRONMENT:-}"
  if [[ -z "${slice_customer}" && -z "${slice_env}" ]]; then
    slice_customer="$(default_slice customer)"
    slice_env="$(default_slice environment)"
    [[ -n "${slice_customer}" ]] &&
      info "slice: ${slice_customer}/${slice_env} (from inventory/defaults.yaml; override with CUSTOMER= ENVIRONMENT=)"
  fi

  # Now that the slice is known, let its own file override the estate-wide
  # ports. Only applied when both halves are known: a filter on customer alone
  # can span several environments with different numbers, and picking one of
  # them would be a guess.
  if [[ -n "${slice_customer}" && -n "${slice_env}" ]]; then
    PORT_PUPPET="$(inv_env "${slice_customer}" "${slice_env}" ports.puppet "${PORT_PUPPET}")"
    PORT_CQL="$(inv_env "${slice_customer}" "${slice_env}" ports.cassandra_cql "${PORT_CQL}")"
    PORT_JENKINS="$(inv_env "${slice_customer}" "${slice_env}" ports.jenkins_http "${PORT_JENKINS}")"
    CONTROL_REPO_URL="$(inv_env "${slice_customer}" "${slice_env}" control_repo_url "${CONTROL_REPO_URL}")"
  fi

  local filters=()
  [[ -n "${slice_customer}" ]] && filters+=(--customer "${slice_customer}")
  [[ -n "${slice_env}" ]]      && filters+=(--environment "${slice_env}")
  [[ -n "${LIMIT:-}" ]]        && filters+=(--limit "${LIMIT}")

  "${EXPANDER}" ${filters[@]+"${filters[@]}"} > "${expanded}" ||
    die 'inventory expansion failed -- see the error above'

  # One contract with COLUMNS in bin/expand-inventory.py. Adding a column
  # there without adding it here silently lands it in `rest`.
  local certname ip os role product cluster customer env dc rack wait_for mem
  local puppet_server rest
  while read -r certname ip os role product cluster customer env dc rack wait_for mem \
                puppet_server rest; do
    # Skip comments and blank lines.
    case "${certname}" in ''|\#*) continue ;; esac
    [[ -n "${mem}" ]] || die "expanded inventory line for ${certname} has too few columns"

    os_image "${os}" >/dev/null || die "${certname}: unknown os '${os}'; see os_image() in this script"

    N_CERTNAME+=("${certname}")
    N_IP+=("${ip}")
    N_OS+=("${os}")
    N_ROLE+=("${role}")
    N_PRODUCT+=("${product}")
    N_CLUSTER+=("${cluster}")
    N_CUSTOMER+=("${customer}")
    N_ENV+=("${env}")
    N_DC+=("${dc}")
    N_RACK+=("${rack}")
    N_WAIT+=("${wait_for}")
    N_MEM+=("${mem}")
    [[ -n "${puppet_server}" && "${puppet_server}" != '-' ]] ||
      die "${certname}: the expander produced no puppet_server (regenerate: bin/expand-inventory.py)"
    N_PUPPET_SERVER+=("${puppet_server}")
    # Container name: the hostname without the domain, so `docker ps` and
    # `./provision.sh logs cass1` stay short.
    N_SHORT+=("${certname%%.*}")

    if [[ "${role}" == 'puppetmaster' ]]; then
      MASTER_ALL+=("${certname}")
      # First wins. This used to be a hard failure on the second master; it is
      # not any more, because which master serves a node is now the
      # inventory's puppet_server, not "the one master this script found".
      if [[ -z "${MASTER_CERTNAME}" ]]; then
        MASTER_CERTNAME="${certname}"
        MASTER_IP="${ip}"
      fi
    fi
  done < "${expanded}"

  [[ ${#N_CERTNAME[@]} -gt 0 ]] || die 'the expanded inventory declares no instances'
  # The generator already checks this; kept as a belt-and-braces guard because
  # a filter (CUSTOMER=/ENVIRONMENT=) can select a slice that has no master.
  [[ -n "${MASTER_CERTNAME}" ]] ||
    die "the selected inventory slice declares no node with role 'puppetmaster'"

  if (( ${#MASTER_ALL[@]} > 1 )); then
    warn "the slice declares ${#MASTER_ALL[@]} masters (${MASTER_ALL[*]})"
    warn "nodes use the inventory's puppet_server; estate-wide subcommands (ca, explain, verify) act on ${MASTER_CERTNAME} only"
  fi
}

# Index of a node by short name or certname. Echoes the index, or returns 1.
node_index() {
  local want="$1" i
  for i in "${!N_CERTNAME[@]}"; do
    if [[ "${N_CERTNAME[$i]}" == "${want}" || "${N_SHORT[$i]}" == "${want}" ]]; then
      echo "$i"; return 0
    fi
  done
  return 1
}

running() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true; }

# ===========================================================================
# teardown
# ===========================================================================
cmd_teardown() {
  step 'Destroying instances'
  local i name removed=0
  for i in "${!N_SHORT[@]}"; do
    name="${N_SHORT[$i]}"
    if docker inspect "${name}" >/dev/null 2>&1; then
      docker rm -f "${name}" >/dev/null 2>&1 && { ok "removed ${name}"; removed=$((removed + 1)); }
    fi
  done
  (( removed == 0 )) && info 'no instances were present'

  step "Destroying network ${NETWORK}"
  if docker network inspect "${NETWORK}" >/dev/null 2>&1; then
    docker network rm "${NETWORK}" >/dev/null 2>&1 && ok 'removed' || warn 'could not remove'
  else
    info 'not present'
  fi

  step 'Clearing generated per-instance state'
  # The metadata documents and assembled user-data scripts. Regenerated by
  # `up`, so removing them keeps a stale metadata document from a previous
  # inventory out of the next run.
  #
  # .state/cache is KEPT: it holds Forge tarballs, which are pinned by version
  # and therefore immutable. Deleting them would make every teardown/up cycle
  # re-download, which is slow and makes the lab need the network to restart.
  if [[ -d "${STATE}" ]]; then
    find "${STATE}" -maxdepth 1 -mindepth 1 ! -name cache -exec rm -rf {} + &&
      ok "cleared ${STATE} (kept the Forge download cache)"
  else
    info 'no state to clear'
  fi
}

# ===========================================================================
# code deploy -- what r10k does in production
# ===========================================================================
# The control repo's modules/ directory is the r10k target: third-party code,
# pinned in Puppetfile, never edited in place. In this lab it is populated from
# the copies already vendored in the module's spec fixtures, which are the same
# pinned refs Puppetfile names.
#
# This is the ONLY step that writes into the control repo, and it writes only
# to modules/ -- the directory a real deploy owns.
code_deploy() {
  step 'Deploying third-party modules into the control repo (r10k stand-in)'
  local target="${CONTROL_REPO}/modules"
  local fixtures="${CONTROL_REPO}/site-modules/cassandra_pfpt/spec/fixtures/modules"
  local stubs="${CONTROL_REPO}/site-modules/cassandra_pfpt/spec/fixtures/stubs"
  local standins="${REPO}/local-cluster/modules"

  install -d "${target}" || die "could not create ${target}"

  # Pinned third-party dependencies, matching Puppetfile.
  local m
  for m in stdlib firewall augeas_core yumrepo_core cron_core java_ks; do
    if [[ -d "${target}/${m}" ]]; then
      info "${m} already deployed"
      continue
    fi
    if [[ -d "${fixtures}/${m}" && ! -L "${fixtures}/${m}" ]]; then
      cp -R "${fixtures}/${m}" "${target}/${m}" || die "could not deploy ${m}"
      ok "deployed ${m}"
    else
      die "${m} is not available at ${fixtures}/${m}; run 'rake spec_prep' in site-modules/cassandra_pfpt first"
    fi
  done

  # Dependencies not vendored in the spec fixtures, fetched from the Forge --
  # which is what r10k does for every Puppetfile entry. Pinned to the same
  # version Puppetfile names, and cached under .state/ so a rebuild does not
  # re-download.
  #
  # puppetlabs-hocon provides hocon_setting, which puppetmaster_pfpt::jvm needs
  # to edit the nested jruby-puppet block in puppetserver.conf. See the note in
  # that class for why file_line cannot do it.
  local forge_mod forge_ver
  for spec in 'hocon:puppetlabs-hocon:2.0.0'; do
    forge_mod="${spec%%:*}"
    forge_ver="${spec##*:}"
    local slug="${spec#*:}"; slug="${slug%%:*}"

    if [[ -d "${target}/${forge_mod}" ]]; then
      info "${forge_mod} already deployed"
      continue
    fi
    local tarball="${STATE}/cache/${slug}-${forge_ver}.tar.gz"
    install -d "${STATE}/cache"
    if [[ ! -s "${tarball}" ]]; then
      info "fetching ${slug} ${forge_ver} from the Forge"
      curl -fsSL --retry 3 --retry-delay 3 \
        -o "${tarball}" "https://forge.puppet.com/v3/files/${slug}-${forge_ver}.tar.gz" ||
        die "could not download ${slug}-${forge_ver} from the Forge"
    fi
    # The tarball's top directory is <author>-<module>-<version>; the module
    # must be deployed under its bare name or Puppet will not autoload it.
    local unpack="${STATE}/cache/unpack-${forge_mod}"
    rm -rf "${unpack}"; install -d "${unpack}"
    tar -xzf "${tarball}" -C "${unpack}" || die "could not unpack ${tarball}"
    local top
    top="$(find "${unpack}" -maxdepth 1 -mindepth 1 -type d | head -1)"
    [[ -n "${top}" ]] || die "${tarball} contained no module directory"
    mv "${top}" "${target}/${forge_mod}" || die "could not deploy ${forge_mod}"
    rm -rf "${unpack}"
    ok "deployed ${forge_mod} ${forge_ver} (Forge)"
  done

  # Environment dependencies the modules REFERENCE but do not own.
  #
  # cassandra_pfpt::service does `subscribe => Class['::java']` whenever
  # manage_java is false (the production default), and both role classes do
  # `include profile_firewall`. A reference to an undeclared class is a compile
  # error, so without these every catalogue in the estate fails.
  #
  # The local-cluster stand-ins are used rather than the spec stubs: the
  # stand-in `java` installs a real OpenJDK, which the spec stub does not, and
  # the Cassandra package genuinely needs a JVM.
  for m in java profile_firewall; do
    if [[ -d "${target}/${m}" ]]; then
      info "${m} already deployed"
      continue
    fi
    [[ -d "${standins}/${m}" ]] || die "environment stand-in ${m} missing at ${standins}/${m}"
    cp -R "${standins}/${m}" "${target}/${m}" || die "could not deploy ${m}"
    ok "deployed ${m} (environment stand-in)"
  done

  # ssl_certificate is referenced only on the TLS path, which this lab does not
  # enable, but a missing class is a compile error whether the branch is taken
  # or not if anything references the type. Deployed when available.
  if [[ -d "${stubs}/ssl_certificate" && ! -d "${target}/ssl_certificate" ]]; then
    cp -R "${stubs}/ssl_certificate" "${target}/ssl_certificate" && ok 'deployed ssl_certificate (stub)'
  fi

  info "modules/: $(find "${target}" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ') modules"
}

# ===========================================================================
# up
# ===========================================================================
write_metadata() {
  local i="$1" dir="$2"
  local image_spec image
  image_spec="$(os_image "${N_OS[$i]}")"
  image="${image_spec%% *}"

  # The instance metadata document. The equivalent of EC2 instance tags plus
  # the metadata service: the platform's one channel for telling an instance
  # who it is. Mounted read-only, and loaded by userdata.service as an
  # EnvironmentFile.
  #
  # Values are NOT quoted: systemd's EnvironmentFile parser treats quotes as
  # part of the value in some versions, and every value here is a bare token.
  cat > "${dir}/metadata.env" <<META
# INSTANCE METADATA -- generated by infra/provision.sh from inventory.conf.
# Read-only on the instance. Loaded by userdata.service as an EnvironmentFile.

# --- Identity: becomes both facts and CSR extension requests ---
PP_CERTNAME=${N_CERTNAME[$i]}
PP_PROJECT=${N_CUSTOMER[$i]}
PP_ENVIRONMENT=${N_ENV[$i]}
PP_PRODUCT=${N_PRODUCT[$i]}
PP_CLUSTER=${N_CLUSTER[$i]}
PP_DATACENTER=${N_DC[$i]}
PP_ROLE=${N_ROLE[$i]}
PP_RACK=${N_RACK[$i]}
# Everything after the first '.' in the certname. Written as a fact so Hiera
# can interpolate %{facts.domain} instead of hardcoding a suffix. GCP + AWS
# expose pp_domain as its own metadata attribute; on Docker we derive it here.
PP_DOMAIN=${N_CERTNAME[$i]#*.}

# --- Where the catalogue comes from ---
# PER NODE, from the inventory's puppet_server layers -- so one customer's
# cassandra fleet can be served by a different master from the rest of its
# estate. Resolved by bin/expand-inventory.py, never guessed here.
PUPPET_SERVER=${N_PUPPET_SERVER[$i]}
PUPPET_COLLECTION=${PUPPET_COLLECTION}
PUPPET_ENVIRONMENT=${PUPPET_ENVIRONMENT}
PUPPET_RUNINTERVAL=30m

# --- One-time join credential, validated against a SHA-256 held in Hiera ---
JOIN_SECRET=${JOIN_SECRET}

# --- Ring serialisation: Cassandra nodes must join one at a time ---
WAIT_FOR=${N_WAIT[$i]}

# --- Ports, from inventory/defaults.yaml, overridden per environment ---
# So the node's health checks, the AWS security group and the GCP firewall all
# read one number. Each must equal the port Hiera makes the service bind --
# cassandra_cql to native_transport_port, jenkins_http to
# profile_jenkins_pfpt::http_port -- and bin/check-ports.py is what compares
# them, because nothing else does.
PUPPET_PORT=${PORT_PUPPET}
CQL_PORT=${PORT_CQL}
JENKINS_PORT=${PORT_JENKINS}

# --- Control repo (puppetmaster bootstrap, cloud only) ---
# Set from the inventory YAML. The local driver bind-mounts the repo and
# ignores this; cloud drivers (GCP/AWS) use it for git clone at first boot.
CONTROL_REPO_URL=${CONTROL_REPO_URL}

# --- Provenance, recorded as facts on the node ---
INSTANCE_IP=${N_IP[$i]}
IMAGE_NAME=${image}
PROVISIONER=infra/provision.sh
META
  chmod 0644 "${dir}/metadata.env"
}

assemble_userdata() {
  local i="$1" dir="$2"
  local role_part

  # User-data is assembled from FOUR fragments, in this order:
  #
  #   00-prelude.sh                shell options and logging
  #   10-metadata-${PLATFORM}.sh   how the node learns who it is
  #   20-common.sh                 everything else, platform-independent
  #   30-role-<role>.sh            what this role does
  #
  # Concatenated at provisioning time rather than sourced at runtime, so what
  # lands on the instance is a single self-contained file -- which is what
  # user-data IS. Terraform's templatefile() assembles the same four fragments
  # the same way for a cloud; see infra/terraform/.
  #
  # Fragment 2 is the ONLY one that differs between Docker, EC2 and GCE. That
  # is the whole point of the split: supporting a platform is one new file, not
  # a fork of the script.
  case "${N_ROLE[$i]}" in
    puppetmaster)                  role_part='30-role-puppetmaster.sh' ;;
    cassandra_seed|cassandra_node) role_part='30-role-cassandra-node.sh' ;;
    jenkins)                       role_part='30-role-jenkins.sh' ;;
    *) die "${N_CERTNAME[$i]}: no user-data defined for role '${N_ROLE[$i]}'" ;;
  esac

  local fragments=(
    '00-prelude.sh'
    "10-metadata-${PLATFORM}.sh"
    '20-common.sh'
    "${role_part}"
  )

  local f
  for f in "${fragments[@]}"; do
    [[ -f "${USERDATA_DIR}/${f}" ]] || die "missing user-data fragment ${USERDATA_DIR}/${f}"
  done

  # Built into a temporary file and moved into place, so an interrupted
  # assembly cannot leave a half-written script that an instance would then
  # boot and run.
  local tmp="${dir}/.user-data.sh.part"
  ( cd "${USERDATA_DIR}" && cat "${fragments[@]}" ) > "${tmp}" || die 'could not assemble user-data'
  # Refuse to ship something that does not even parse. A syntax error here
  # surfaces on the instance as a first boot that does nothing at all, with
  # the reason buried in a log nobody is watching yet.
  bash -n "${tmp}" || die "assembled user-data for ${N_CERTNAME[$i]} has a syntax error"
  mv "${tmp}" "${dir}/user-data.sh"
  chmod 0755 "${dir}/user-data.sh"
}

cmd_up() {
  command -v docker >/dev/null || die 'docker CLI not found'
  docker info >/dev/null 2>&1 || die "cannot reach a docker daemon at ${DOCKER_HOST:-the default socket}"

  local vm_mem vm_cpu
  vm_mem="$(docker info --format '{{.MemTotal}}')"
  vm_cpu="$(docker info --format '{{.NCPU}}')"
  step "Host: ${vm_cpu} CPUs, $((vm_mem / 1024 / 1024)) MiB RAM"
  info "${#N_CERTNAME[@]} instance(s) from the inventory, sized per cluster"

  # Gate on the sizing cross-check BEFORE creating anything. A machine too
  # small for the JVM heap Hiera pins is a silent runtime failure -- the
  # process is OOM-killed after a clean-looking startup and no Puppet resource
  # fails -- so the only cheap place to catch it is here.
  step 'Checking machine sizing against the Hiera heap'
  if [[ -x "${SIZING_CHECK}" ]]; then
    if "${SIZING_CHECK}" >/tmp/sizing.$$ 2>&1; then
      ok "$(tail -1 /tmp/sizing.$$)"
    else
      sed 's/^/    /' /tmp/sizing.$$
      rm -f /tmp/sizing.$$
      die 'sizing check failed; fix the inventory or the Hiera heap before provisioning'
    fi
    rm -f /tmp/sizing.$$
  else
    warn "${SIZING_CHECK} not executable; skipping the sizing cross-check"
  fi

  # Ensure eyaml keys and encrypted secrets exist before the master boots.
  # Skipped silently if keys are already present (custom keys are honored).
  # Fresh install: generates matched X.509 keypair and encrypts lab defaults
  # from keys/eyaml/plaintext.yaml (created with lab values if missing).
  step 'Ensuring eyaml keys and encrypted secrets'
  if [[ -x "${ENSURE_EYAML}" ]]; then
    "${ENSURE_EYAML}" || die 'eyaml setup failed'
  else
    warn "${ENSURE_EYAML} not executable; skipping automatic eyaml setup"
  fi

  # The control repo is bind-mounted into the master, so its third-party
  # modules must be on disk before the master boots and applies its role.
  code_deploy

  step "Creating network ${NETWORK} (${SUBNET})"
  if docker network inspect "${NETWORK}" >/dev/null 2>&1; then
    info 'already exists'
  else
    docker network create --subnet "${SUBNET}" "${NETWORK}" >/dev/null ||
      die "could not create network ${NETWORK}"
    ok 'created'
  fi

  step 'Creating raw instances'
  info 'Nothing is installed here. Each instance boots and runs its own'
  info 'user-data, which installs the Puppet agent and asks the master for'
  info 'everything else.'

  local i name ip image_spec image platform mem dir
  local role_args
  for i in "${!N_CERTNAME[@]}"; do
    name="${N_SHORT[$i]}"
    ip="${N_IP[$i]}"
    image_spec="$(os_image "${N_OS[$i]}")"
    image="${image_spec%% *}"
    platform="${image_spec##* }"

    if running "${name}"; then
      info "${name} already running"
      continue
    fi
    docker rm -f "${name}" >/dev/null 2>&1

    dir="${STATE}/${name}"
    install -d "${dir}" || die "could not create ${dir}"
    write_metadata "$i" "${dir}"
    assemble_userdata "$i" "${dir}"

    # A directory containing a SYMLINK to the unit, bind-mounted over the
    # instance's multi-user.target.wants/. Verified empirically: a regular unit
    # file bind-mounted into that directory is NOT picked up -- systemd reports
    # the unit 'disabled' and never runs it. The directory entry has to be a
    # symlink, which is why a whole directory is mounted rather than one file.
    #
    # Safe to mount over: the directory is empty in these images, so nothing
    # the image itself enabled is being hidden.
    #
    # PER-INSTANCE, and mounted READ-WRITE. Both matter:
    #
    #   read-write, because this is the directory systemd writes into for
    #   `systemctl enable`. Mounting it read-only silently breaks enabling ANY
    #   unit on the node -- found the hard way: every node reported
    #   "Failed to enable unit: /etc/systemd/system/multi-user.target.wants/
    #   cron.service: Read-only file system", so cron never started and the
    #   Cassandra backup and repair schedules would have been written and
    #   never fired.
    #
    #   per-instance, because a directory shared between instances would let
    #   one node's `systemctl enable` appear on the others.
    install -d "${dir}/wants" || die "could not create ${dir}/wants"
    ln -sf /etc/systemd/system/userdata.service "${dir}/wants/userdata.service"

    # Role-specific run arguments, accumulated in one array.
    #
    # Built as a NON-EMPTY array from the start: in bash 3.2, expanding an
    # empty "${arr[@]}" under `set -u` is an unbound-variable error rather than
    # nothing (bash 4.4 fixed this). macOS ships 3.2.57, so seeding the array
    # with the memory limit -- which every instance needs -- avoids the
    # ${arr[@]+"${arr[@]}"} dance at the call site.
    # From the inventory's sizing shape. bin/check-sizing.py verifies this
    # against the JVM heap in Hiera -- a machine too small for its heap is
    # OOM-killed after a clean-looking startup, with nothing in the Puppet run
    # to show it.
    mem="${N_MEM[$i]}"
    [[ -n "${mem}" && "${mem}" != '-' ]] ||
      die "${N_CERTNAME[$i]}: the inventory produced no memory limit"
    role_args=(--memory "${mem}")

    if [[ "${N_ROLE[$i]}" == 'puppetmaster' ]]; then
      # The master gets the control repo, read-only: it has no business
      # modifying the estate's code, and mounting it ro proves the run never
      # tries to.
      #
      # Mounted at a NEUTRAL PATH, not at
      # /etc/puppetlabs/code/environments/production, and that is not a
      # stylistic choice. The puppet-agent .deb itself ships
      # environments/production/environment.conf, so a read-only mount there
      # makes the agent's own installation fail:
      #
      #   dpkg: error processing archive puppet-agent_8.10.0-1focal_arm64.deb:
      #     unable to create '/etc/puppetlabs/code/environments/production/
      #     environment.conf.dpkg-new': Read-only file system
      #
      # Mounting it read-write instead would be worse: dpkg would write the
      # package's own environment.conf into the developer's checkout.
      #
      # So the mount lands at /opt/control-repo and the master's user-data
      # symlinks the environment path to it AFTER installing the agent.
      role_args+=(-v "${CONTROL_REPO}:/opt/control-repo:ro")

      # eyaml private key: mounted into the master so Puppet can decrypt
      # ENC[PKCS7,...] values in the secrets/ Hiera layers at first boot.
      # The key lives in infra/.state/eyaml/ (gitignored) -- generated once
      # by bin/create-eyaml-keys.sh and never committed.
      # Puppet expects it at /etc/puppetlabs/puppet/eyaml/private_key.pkcs7.pem.
      local eyaml_key="${REPO}/keys/eyaml/private_key.pkcs7.pem"
      if [[ -f "${eyaml_key}" ]]; then
        # The key is mounted read-only, but puppetserver runs as the `puppet`
        # user. Docker bind-mounts preserve the HOST file's uid/gid, which may
        # be root:root -- so chown happens in the container's prelude instead.
        # We use a state-dir copy (chowned to puppet) rather than the source
        # key, so the source file's permissions are never changed by the lab.
        local eyaml_dir="${STATE}/${name}-eyaml"
        install -d -m 0755 "${eyaml_dir}"
        cp "${eyaml_key}" "${eyaml_dir}/private_key.pkcs7.pem"
        # 800 is fine for a bind-mount because Docker maps the host uid; but
        # since puppetserver runs as the puppet uid we chmod 0644 read-only
        # and rely on the ro mount flag to prevent writes.
        chmod 0644 "${eyaml_dir}/private_key.pkcs7.pem"
        local eyaml_pub="${REPO}/cassandra-control-repo/keys/public_key.pkcs7.pem"
        [[ -f "${eyaml_pub}" ]] && cp "${eyaml_pub}" "${eyaml_dir}/public_key.pkcs7.pem" && chmod 0644 "${eyaml_dir}/public_key.pkcs7.pem"
        role_args+=(
          -v "${eyaml_dir}/private_key.pkcs7.pem:/etc/puppetlabs/puppet/eyaml/private_key.pkcs7.pem:ro"
          -v "${eyaml_dir}/public_key.pkcs7.pem:/etc/puppetlabs/puppet/eyaml/public_key.pkcs7.pem:ro"
        )
        log "eyaml private key mounted into ${name}"
      else
        warn "eyaml private key not found at ${eyaml_key}"
        warn "eyaml lookups will fail -- run cassandra-control-repo/bin/create-eyaml-keys.sh"
        warn "and copy the private key to ${eyaml_key}"
      fi

      # Docker resolves a container's NAME on a user-defined network but not
      # its FQDN. Agents address the master by certname (pm1.lab.pfpt) and by
      # the classic compiled-in default (puppet), so both must resolve -- a
      # name that does not resolve surfaces as a TLS name mismatch, which reads
      # as a certificate problem and sends people to the wrong place.
      role_args+=(--network-alias puppet)
    fi
    # Agents get NO copy of the control repo: they have no business holding the
    # estate's code, and mounting it would quietly mask a failure to fetch a
    # catalogue from the master.

    # --privileged + cgroupns=host is what lets systemd run as PID 1 under
    # cgroup v2. Without both, systemd fails to mount its own cgroup hierarchy
    # and the instance never finishes booting.
    #
    # --network-alias: docker resolves the container NAME on a user-defined
    # network, but not the FQDN. The agents address their master by certname
    # (pm1.lab.pfpt) and the classic default name (puppet), so both have to
    # resolve -- a name that does not resolve surfaces as a TLS name mismatch,
    # which reads as a certificate problem and sends people to the wrong place.
    docker run -d \
      --name "${name}" --hostname "${N_CERTNAME[$i]}" \
      --platform "${platform}" \
      --network "${NETWORK}" --ip "${ip}" \
      --network-alias "${N_CERTNAME[$i]}" \
      --privileged --cgroupns=host \
      -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
      --tmpfs /run --tmpfs /run/lock \
      -e container=docker \
      -v "${dir}/metadata.env:/etc/instance-metadata:ro" \
      -v "${dir}/user-data.sh:/usr/local/sbin/user-data.sh:ro" \
      -v "${USERDATA_DIR}/userdata.service:/etc/systemd/system/userdata.service:ro" \
      -v "${dir}/wants:/etc/systemd/system/multi-user.target.wants" \
      "${role_args[@]}" \
      "${image}" /lib/systemd/systemd >/dev/null ||
      die "could not create ${name}"

    ok "${name} (${N_ROLE[$i]}) at ${ip} on ${image}"
  done

  step 'Waiting for systemd'
  for i in "${!N_SHORT[@]}"; do
    name="${N_SHORT[$i]}"
    local tries=0
    until docker exec "${name}" systemctl list-units >/dev/null 2>&1; do
      tries=$(( tries + 1 ))
      (( tries > 60 )) && die "systemd did not come up in ${name} within 120s"
      sleep 2
    done
    ok "${name}: systemd ready, user-data started"
  done

  step 'Instances are provisioning themselves'
  info "Follow one with:  ./provision.sh logs ${N_SHORT[0]}"
  info 'Block until done: ./provision.sh wait'
}

# ===========================================================================
# wait
# ===========================================================================
cmd_wait() {
  # Budget: the master installs a JVM and Puppet Server and creates a CA, then
  # three agents converge one at a time through a single JRuby instance, each
  # installing a JVM and Cassandra. On a cold image cache this is genuinely
  # slow, and a timeout that fires early looks like a failure.
  local timeout="${PROVISION_WAIT_TIMEOUT:-2400}"
  step "Waiting for user-data to finish on ${#N_SHORT[@]} instances (up to ${timeout}s)"

  local start now elapsed i name done_count pending
  start="$(date +%s)"
  while :; do
    done_count=0
    pending=''
    for i in "${!N_SHORT[@]}"; do
      name="${N_SHORT[$i]}"
      if docker exec "${name}" test -f /var/lib/instance/user-data.done 2>/dev/null; then
        done_count=$(( done_count + 1 ))
      else
        pending="${pending} ${name}"
      fi
    done

    now="$(date +%s)"; elapsed=$(( now - start ))
    if (( done_count == ${#N_SHORT[@]} )); then
      ok "all ${done_count} instances finished user-data after ${elapsed}s"
      break
    fi
    if (( elapsed > timeout )); then
      bad "timed out after ${elapsed}s; still pending:${pending}"
      info "inspect with: ./provision.sh logs${pending%% *}"
      return 1
    fi
    printf '\r    %s%3ds%s  %d/%d done, waiting for:%s        ' \
      "${C_DIM}" "${elapsed}" "${C_RESET}" "${done_count}" "${#N_SHORT[@]}" "${pending}"
    sleep 10
  done
  printf '\n'

  # A node can finish user-data unsuccessfully: the marker records the outcome
  # so a partial success is not mistaken for a clean one.
  #
  # AND THE EXIT CODE HAS TO CARRY IT. bad() is only a printf, so this loop
  # used to print [FAIL] and still return 0 -- which meant
  # `./provision.sh up && ./provision.sh wait && ./provision.sh verify`
  # marched straight on to verify with a broken node, and any CI job built on
  # that chain would go green. Observed for real: cass-west2 ended user-data
  # as `cassandra-not-serving` after Cassandra refused to bootstrap, and the
  # chain kept going.
  local status failed=0
  for i in "${!N_SHORT[@]}"; do
    name="${N_SHORT[$i]}"
    status="$(docker exec "${name}" sh -c 'grep "^status=" /var/lib/instance/user-data.done 2>/dev/null | cut -d= -f2' 2>/dev/null)"
    case "${status}" in
      ok) ok "${name}: ${status}" ;;
      # Counted as a failure too: a marker with no status means the script
      # ended in a way it did not anticipate, which is not reassuring.
      '') bad "${name}: no status recorded"; failed=$(( failed + 1 )) ;;
      *)  bad "${name}: ${status}"; failed=$(( failed + 1 )) ;;
    esac
  done

  if (( failed > 0 )); then
    warn "${failed} instance(s) did not finish cleanly -- read ./provision.sh logs <node>"
    return 1
  fi
}

# ===========================================================================
# status
# ===========================================================================
cmd_status() {
  step 'Instance status'
  printf '    %-16s %-14s %-16s %-9s %-8s %-7s %s\n' \
    NODE IP ROLE BOOT CERT PUPPET SERVICE
  printf '    %s\n' '---------------------------------------------------------------------------------------'

  local i name boot cert puppet svc
  for i in "${!N_SHORT[@]}"; do
    name="${N_SHORT[$i]}"

    if ! running "${name}"; then
      printf '    %-16s %-14s %-16s %s\n' "${name}" "${N_IP[$i]}" "${N_ROLE[$i]}" 'not running'
      continue
    fi

    boot="$(docker exec "${name}" sh -c 'grep "^status=" /var/lib/instance/user-data.done 2>/dev/null | cut -d= -f2' 2>/dev/null)"
    [[ -n "${boot}" ]] || boot='running'

    if docker exec "${name}" test -f "/etc/puppetlabs/puppet/ssl/certs/${N_CERTNAME[$i]}.pem" 2>/dev/null; then
      cert='signed'
    else
      cert='-'
    fi

    puppet="$(docker exec "${name}" sh -c '/opt/puppetlabs/bin/puppet --version 2>/dev/null' 2>/dev/null)"
    [[ -n "${puppet}" ]] || puppet='-'

    if [[ "${N_ROLE[$i]}" == 'puppetmaster' ]]; then
      svc="$(docker exec "${name}" sh -c 'systemctl is-active puppetserver 2>/dev/null' 2>/dev/null)"
      svc="puppetserver=${svc:-unknown}"
    else
      svc="$(docker exec "${name}" sh -c 'systemctl is-active cassandra 2>/dev/null' 2>/dev/null)"
      svc="cassandra=${svc:-unknown}"
    fi

    printf '    %-16s %-14s %-16s %-9s %-8s %-7s %s\n' \
      "${name}" "${N_IP[$i]}" "${N_ROLE[$i]}" "${boot}" "${cert}" "${puppet}" "${svc}"
  done
}

# ===========================================================================
# logs / ssh / explain
# ===========================================================================
cmd_logs() {
  local want="${1:-}"
  [[ -n "${want}" ]] || die 'usage: ./provision.sh logs <node>'
  local i; i="$(node_index "${want}")" || die "no such instance: ${want}"
  docker exec "${N_SHORT[$i]}" sh -c 'cat /var/log/user-data.log 2>/dev/null || echo "(user-data has not written a log yet)"'
}

cmd_ssh() {
  local want="${1:-}"
  [[ -n "${want}" ]] || die 'usage: ./provision.sh ssh <node>'
  local i; i="$(node_index "${want}")" || die "no such instance: ${want}"
  docker exec -it "${N_SHORT[$i]}" /bin/bash
}

# Ask the MASTER which Hiera layer wins for a key, evaluated as a given node.
#
# This is the tool that makes the hierarchy debuggable. `--explain` prints every
# layer it consulted, in order, saying for each whether the path existed and
# whether the key was found -- so "why is this node's heap 640M?" has a
# one-command answer instead of being inferred by reading 29 paths by hand.
#
# TWO CAVEATS, both real and worth knowing before trusting the output:
#
#   1. `puppet lookup --node X` needs facts for X. The CLI's vardir is not the
#      same as puppetserver's, so it does not see the facts agents have
#      submitted. The node's own facts are therefore collected and passed with
#      --facts.
#
#   2. It resolves through the FACT-FALLBACK layers, not the trusted ones.
#      There is no TLS session here, so $trusted['extensions'] is empty --
#      `puppet lookup` cannot see a certificate. Each tenancy layer has a
#      trusted path and a fact path pointing at the SAME file, so the answer is
#      the same; but this command is not proof that the trusted path works.
#      `verify` tests that separately, by taking the facts away.
#
#   3. $trusted['certname'] is empty too, which matters MORE than (2) because
#      the NODE layer -- the highest-priority layer in the hierarchy -- is
#      keyed on it and has no fact fallback by design. So `puppet lookup`
#      renders that path as `data/nodes/.yaml`, never matches it, and reports
#      a winner that a real agent run would override. Confirmed on Puppet
#      8.9.0 with every combination of --node, --facts and --compile.
#
#      `puppet lookup --trusted` looks like the answer and is not: the flag is
#      declared at lookup.rb:52 and never read anywhere in the file. The only
#      code path that populates trusted information (lookup.rb:391) needs
#      --compile AND a non-plain node terminus AND a reachable CA route, and
#      falls back with "CA is not available" otherwise.
#
#      Rather than add a spoofable `facts.clientcert` fallback to the single
#      most powerful layer in the hierarchy, the node file is checked
#      SEPARATELY below and reported explicitly.
cmd_explain() {
  local want="${1:-}" key="${2:-}"
  [[ -n "${want}" && -n "${key}" ]] || die 'usage: ./provision.sh explain <node> <hiera-key>'
  local i; i="$(node_index "${want}")" || die "no such instance: ${want}"
  local mi; mi="$(node_index "${MASTER_CERTNAME}")" || die 'master not in inventory'
  local node="${N_SHORT[$i]}" master="${N_SHORT[$mi]}"
  local certname="${N_CERTNAME[$i]}"

  local tmp="${STATE}/${node}-facts.json"
  docker exec "${node}" /opt/puppetlabs/bin/facter --json > "${tmp}" 2>/dev/null ||
    die "could not collect facts from ${node}"
  docker cp "${tmp}" "${master}:/tmp/lookup-facts.json" >/dev/null ||
    die 'could not copy facts to the master'

  # The node layer, checked by hand because the CLI cannot resolve it. Done
  # FIRST and loudly: it outranks everything `puppet lookup` is about to print,
  # so reporting it afterwards would invite reading the wrong answer.
  local nodefile="${CONTROL_REPO}/data/nodes/${certname}.yaml"
  step "Node layer (rank 1) for ${certname}"
  if [[ -f "${nodefile}" ]]; then
    local nodeval
    nodeval="$(docker exec "${master}" /opt/puppetlabs/puppet/bin/ruby -ryaml -e '
      d = YAML.safe_load(File.read(ARGV[0])) || {}
      puts d.key?(ARGV[1]) ? d[ARGV[1]].inspect : "\0"
    ' "/etc/puppetlabs/code/environments/${PUPPET_ENVIRONMENT}/data/nodes/${certname}.yaml" "${key}" 2>/dev/null)"
    if [[ -n "${nodeval}" && "${nodeval}" != $'\0' ]]; then
      warn "data/nodes/${certname}.yaml SETS this key: ${nodeval}"
      warn 'That WINS. Ignore the winner reported below -- the CLI cannot see'
      warn 'this layer (caveat 3 above). Delete the file when the operation'
      warn 'it was created for is over.'
    else
      info "data/nodes/${certname}.yaml exists but does not set ${key}"
    fi
  else
    info "no data/nodes/${certname}.yaml -- nothing overriding at rank 1"
  fi

  step "Resolving ${key} for ${certname}"
  info 'Asked of the master, as that node. Resolves via the fact-fallback'
  info 'layers -- see the caveats above cmd_explain().'
  docker exec "${master}" /opt/puppetlabs/bin/puppet lookup \
    --environment "${PUPPET_ENVIRONMENT}" \
    --node "${certname}" \
    --facts /tmp/lookup-facts.json \
    --explain "${key}"
}

# ===========================================================================
# render -- assemble a node's user-data without creating anything
# ===========================================================================
# Prints the exact script an instance of that role would run, for the platform
# in ${PLATFORM}. Nothing is created and no instance is touched.
#
# The point is to be able to review the CLOUD user-data from a laptop:
#
#   PLATFORM=aws ./provision.sh render cass1 | less
#   PLATFORM=gcp ./provision.sh render pm1 > /tmp/pm1-gcp.sh
#
# Fragments 1, 3 and 4 are byte-identical across platforms; diffing two renders
# shows you that, which is the claim worth being able to check rather than
# trust.
cmd_render() {
  local want="${1:-}"
  [[ -n "${want}" ]] || die 'usage: [PLATFORM=local|aws|gcp] ./provision.sh render <node>'
  local i; i="$(node_index "${want}")" || die "no such instance: ${want}"

  local dir="${STATE}/render-${N_SHORT[$i]}-${PLATFORM}"
  install -d "${dir}" || die "could not create ${dir}"

  # The metadata too, not just the script. The script is IDENTICAL for every
  # node of a role -- everything that makes it this node's run comes from
  # metadata.env, so a render without it cannot answer the question people
  # actually bring to `render`: which master, which cluster, which identity.
  write_metadata "$i" "${dir}"
  assemble_userdata "$i" "${dir}"

  printf '# ===========================================================\n'
  printf '# metadata.env -- the instance metadata document this node reads\n'
  printf '# ===========================================================\n'
  cat "${dir}/metadata.env"
  printf '\n'
  cat "${dir}/user-data.sh"
}

# ===========================================================================
# layers -- which layer wins, for one key or for a representative set
# ===========================================================================
# Answers "where does this value come from?" for a whole set of keys at once,
# as a table. `explain` shows one key in full detail; this shows many keys at a
# glance, which is the view you want when reviewing whether the hierarchy is
# doing what you meant.
#
# Same caveat as cmd_explain: resolved through the FACT-FALLBACK layers,
# because `puppet lookup` has no TLS session and so cannot see a certificate.
# Each tenancy layer's trusted path and fact path point at the same file, so
# the winning FILE is the same either way.
cmd_layers() {
  local want="${1:-cass1}"
  local i; i="$(node_index "${want}")" || die "no such instance: ${want}"
  local mi; mi="$(node_index "${MASTER_CERTNAME}")" || die 'master not in inventory'
  local node="${N_SHORT[$i]}" master="${N_SHORT[$mi]}"

  local tmp="${STATE}/${node}-facts.json"
  docker exec "${node}" /opt/puppetlabs/bin/facter --json > "${tmp}" 2>/dev/null ||
    die "could not collect facts from ${node}"
  docker cp "${tmp}" "${master}:/tmp/lookup-facts.json" >/dev/null ||
    die 'could not copy facts to the master'

  step "Where every value comes from, for ${N_CERTNAME[$i]}"
  info "customer=${N_CUSTOMER[$i]} env=${N_ENV[$i]} product=${N_PRODUCT[$i]} cluster=${N_CLUSTER[$i]}"
  printf '\n    %-46s %-22s %s\n' 'KEY' 'VALUE' 'WINNING LAYER'
  printf '    %s\n' '-------------------------------------------------------------------------------------------------------'

  # One key per level of the hierarchy, deliberately: read top to bottom this
  # is the precedence order itself, demonstrated rather than asserted.
  local keys=(
    'profile_cassandra_pfpt::seeds'
    'profile_cassandra_pfpt::max_heap_size'
    'profile_cassandra_pfpt::num_tokens'
    'profile_cassandra_pfpt::s3_retention_period'
    'profile_cassandra_pfpt::cassandra_version'
    'profile_cassandra_pfpt::repo_baseurl_prefix'
    'profile_cassandra_pfpt::repair_steps_per_table'
    'profile_cassandra_pfpt::endpoint_snitch'
    'profile_cassandra_pfpt::repo_skip_if_unavailable'
    'profile_cassandra_pfpt::manage_java'
  )

  local key out value layer
  for key in "${keys[@]}"; do
    out="$(docker exec "${master}" /opt/puppetlabs/bin/puppet lookup \
      --environment "${PUPPET_ENVIRONMENT}" \
      --node "${N_CERTNAME[$i]}" \
      --facts /tmp/lookup-facts.json \
      --explain "${key}" 2>/dev/null)"

    # The LAST "Found key" line is the winner: --explain prints the hierarchy in
    # order and stops at the first match for the key itself, but the
    # lookup_options pass above it also emits Found/No-such-key lines.
    layer="$(printf '%s' "${out}" | grep -B3 "Found key: \"${key}\"" | grep 'Original path:' | tail -1 |
             sed 's/.*Original path: "//; s/"$//')"
    value="$(printf '%s' "${out}" | grep "Found key: \"${key}\"" | tail -1 |
             sed 's/.*value: //' | tr -d '\n' | cut -c1-20)"
    [[ -n "${layer}" ]] || layer='(not found)'
    [[ -n "${value}" ]] || value='(none)'
    printf '    %-46s %-22s %s\n' "${key#profile_cassandra_pfpt::}" "${value}" "${layer}"
  done
  printf '\n'
  info 'Read top to bottom, that IS the precedence order: the cluster file'
  info 'first, then customer+env, customer+product, customer, product+env,'
  info 'product, environment tier, OS, and finally common.yaml.'
}

# ===========================================================================
# verify
# ===========================================================================
VERIFY_PASS=0
VERIFY_FAIL=0
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ok "${desc}"; VERIFY_PASS=$(( VERIFY_PASS + 1 ))
  else
    bad "${desc}"; VERIFY_FAIL=$(( VERIFY_FAIL + 1 ))
  fi
}
# Assert a command's output contains an expected string, showing what came back
# when it does not. A bare pass/fail on a value check is nearly useless for
# diagnosis.
check_out() {
  local desc="$1" expect="$2"; shift 2
  local out
  out="$("$@" 2>&1)"
  if printf '%s' "${out}" | grep -q -- "${expect}"; then
    ok "${desc}"; VERIFY_PASS=$(( VERIFY_PASS + 1 ))
  else
    bad "${desc}"
    printf '           expected to contain: %s\n' "${expect}"
    printf '           got: %s\n' "$(printf '%s' "${out}" | head -3 | tr '\n' ' ')"
    VERIFY_FAIL=$(( VERIFY_FAIL + 1 ))
  fi
}

cmd_verify() {
  local mi; mi="$(node_index "${MASTER_CERTNAME}")" || die 'master not in inventory'
  local master="${N_SHORT[$mi]}"
  local i name

  step 'The instances were raw'
  # Proves the claim rather than asserting it: the base image carried no
  # Puppet, so everything on these nodes arrived through provisioning.
  check_out 'base image ships no puppet-agent' 'no puppet in image' \
    docker run --rm --platform linux/arm64 --entrypoint sh litmusimage/ubuntu:20.04 \
      -c 'command -v puppet >/dev/null 2>&1 || echo "no puppet in image"'

  step 'Puppet Server'
  check "${master}: puppetserver is active" \
    docker exec "${master}" systemctl is-active --quiet puppetserver
  # Matches the probe's own stdout, not the HTTP body it reads. The body is
  # 'running'; the script prints "puppetserver ready on port N".
  check_out "${master}: reports ready on 8140" 'ready on port 8140' \
    docker exec "${master}" /usr/local/sbin/puppetserver-wait 8140 30
  check_out "${master}: version came from Hiera (8.7.0)" '8.7.0' \
    docker exec "${master}" sh -c 'dpkg -s puppetserver 2>/dev/null | grep ^Version || rpm -q puppetserver'
  check_out "${master}: heap came from Hiera (1g)" '\-Xmx1g' \
    docker exec "${master}" sh -c 'grep ^JAVA_ARGS /etc/default/puppetserver 2>/dev/null || grep ^JAVA_ARGS /etc/sysconfig/puppetserver'
  check_out "${master}: 1 JRuby instance from Hiera" 'max-active-instances: 1' \
    docker exec "${master}" cat /etc/puppetlabs/puppetserver/conf.d/puppetserver.conf
  check "${master}: CA exists" \
    docker exec "${master}" test -f /etc/puppetlabs/puppet/ssl/ca/ca_crt.pem

  step 'Autosign policy'
  check "${master}: policy validator installed" \
    docker exec "${master}" test -x /etc/puppetlabs/puppet/autosign-validate
  check_out "${master}: policy requires pp_cluster" 'pp_cluster' \
    docker exec "${master}" cat /etc/puppetlabs/puppet/autosign-policy.json
  check_out "${master}: policy carries the join-secret digest" '407df445' \
    docker exec "${master}" cat /etc/puppetlabs/puppet/autosign-policy.json
  check_out "${master}: audit log records every signing decision" 'ALLOW' \
    docker exec "${master}" cat /var/log/puppetlabs/puppetserver/autosign.log
  # The negative case is the one that matters. A validator that only ever says
  # yes is not a control, so this hands the LIVE master a real CSR claiming a
  # tenant its allowlist does not permit, and requires a refusal.
  #
  # The CSR is built with Puppet's own API (see tools/make-test-csr.rb) rather
  # than openssl, because the extension-request attribute is a nested
  # SET OF SEQUENCE that is easy to get subtly wrong -- and a malformed CSR
  # would be refused for the wrong reason, which looks exactly like the policy
  # working.
  docker cp "${HERE}/tools/make-test-csr.rb" "${master}:/tmp/make-test-csr.rb" >/dev/null 2>&1
  docker exec "${master}" chmod 0755 /tmp/make-test-csr.rb >/dev/null 2>&1

  # Domain from inventory, so test certnames follow the estate's scheme
  # rather than a hardcoded suffix.
  local DOMAIN
  DOMAIN="$(inv_default 'domain' 'lab.pfpt')"

  # Valid extensions, valid secret, but a tenant this master does not serve.
  docker exec "${master}" sh -c "/tmp/make-test-csr.rb rogue.${DOMAIN} \
    '{\"pp_project\":\"evilcorp\",\"pp_environment\":\"nonprod\",\"pp_product\":\"cassandra\",\"pp_cluster\":\"core\",\"pp_role\":\"cassandra_node\"}' \
    '${JOIN_SECRET}' > /tmp/rogue.pem" >/dev/null 2>&1
  check_out "${master}: REFUSES a CSR claiming another tenant" 'not in the allowlist' \
    docker exec "${master}" sh -c "/etc/puppetlabs/puppet/autosign-validate rogue.${DOMAIN} < /tmp/rogue.pem 2>&1 || true"

  # Correct tenant, but no join secret at all.
  docker exec "${master}" sh -c "/tmp/make-test-csr.rb nosecret.${DOMAIN} \
    '{\"pp_project\":\"amex\",\"pp_environment\":\"nonprod\",\"pp_product\":\"cassandra\",\"pp_cluster\":\"core\",\"pp_role\":\"cassandra_node\"}' \
    > /tmp/nosecret.pem" >/dev/null 2>&1
  check_out "${master}: REFUSES a CSR with no join secret" 'requires a challengePassword' \
    docker exec "${master}" sh -c "/etc/puppetlabs/puppet/autosign-validate nosecret.${DOMAIN} < /tmp/nosecret.pem 2>&1 || true"

  # Everything correct except the certname, which is off this estate's scheme.
  docker exec "${master}" sh -c "/tmp/make-test-csr.rb evil.example.com \
    '{\"pp_project\":\"amex\",\"pp_environment\":\"nonprod\",\"pp_product\":\"cassandra\",\"pp_cluster\":\"core\",\"pp_role\":\"cassandra_node\"}' \
    '${JOIN_SECRET}' > /tmp/badname.pem" >/dev/null 2>&1
  check_out "${master}: REFUSES an off-scheme certname" 'does not match' \
    docker exec "${master}" sh -c '/etc/puppetlabs/puppet/autosign-validate evil.example.com < /tmp/badname.pem 2>&1 || true'

  # And the positive control: the SAME path must still approve a legitimate
  # request, or the three refusals above prove only that it refuses everything.
  docker exec "${master}" sh -c "/tmp/make-test-csr.rb cass9.${DOMAIN} \
    '{\"pp_project\":\"amex\",\"pp_environment\":\"nonprod\",\"pp_product\":\"cassandra\",\"pp_cluster\":\"core\",\"pp_datacenter\":\"dc_east\",\"pp_role\":\"cassandra_node\"}' \
    '${JOIN_SECRET}' > /tmp/good.pem" >/dev/null 2>&1
  check_out "${master}: APPROVES a legitimate CSR (positive control)" 'ALLOW' \
    docker exec "${master}" sh -c "/etc/puppetlabs/puppet/autosign-validate cass9.${DOMAIN} < /tmp/good.pem 2>&1 || true"

  step 'Certificates carry the tenancy extensions'
  # The master included. Verified rather than assumed: `puppetserver ca setup`
  # turns out to read csr_attributes.yaml, so the master's own certificate
  # carries the same six pp_* extensions an agent's does -- which means the
  # master resolves its own Hiera through trusted.extensions after bootstrap,
  # not through the fact fallback it needed for the very first apply.
  check_out "${master}: the master's OWN cert carries pp_project" 'amex' \
    docker exec "${master}" sh -c "openssl x509 -in /etc/puppetlabs/puppet/ssl/certs/${MASTER_CERTNAME}.pem -noout -text | grep -A1 '1.3.6.1.4.1.34380.1.1.7'"

  for i in "${!N_SHORT[@]}"; do
    name="${N_SHORT[$i]}"
    check_out "${name}: certificate is signed" "${N_CERTNAME[$i]}" \
      docker exec "${master}" /opt/puppetlabs/bin/puppetserver ca list --all
    check_out "${name}: cert carries pp_cluster=${N_CLUSTER[$i]}" "${N_CLUSTER[$i]}" \
      docker exec "${name}" sh -c "openssl x509 -in /etc/puppetlabs/puppet/ssl/certs/${N_CERTNAME[$i]}.pem -noout -text | grep -A1 '1.3.6.1.4.1.34380.1.1.16'"
  done

  step 'Hiera composed across layers -- checked on what actually landed'
  # Checked against the FILES ON THE NODE rather than by asking Hiera again.
  #
  # That distinction matters. A `puppet lookup` on the master proves only that
  # Hiera can resolve a value; these checks prove the master actually compiled
  # a catalogue with it and the node applied it. They are also immune to the
  # trusted-vs-facts caveat in cmd_explain, because a value on disk arrived
  # through the real code path.
  #
  # Each value is set at a DIFFERENT layer, so together they show the hierarchy
  # composing rather than one file being read:
  local ci; ci="$(node_index cass1)" || die 'cass1 not in inventory'
  local c1="${N_SHORT[$ci]}"

  check_out 'heap 640M          <- cluster file' '\-Xmx640M' \
    docker exec "${c1}" sh -c 'cat /etc/cassandra/jvm*-server.options /etc/cassandra/jvm.options 2>/dev/null'
  check_out 'cluster_name       <- cluster file' 'amex-nonprod-core' \
    docker exec "${c1}" grep '^cluster_name' /etc/cassandra/cassandra.yaml
  check_out 'num_tokens 16      <- cluster file' '^num_tokens: 16' \
    docker exec "${c1}" grep '^num_tokens' /etc/cassandra/cassandra.yaml
  check_out 'seeds              <- cluster/datacentre file' '172.30.30.11' \
    docker exec "${c1}" grep -A3 'seed_provider' /etc/cassandra/cassandra.yaml
  check_out 'version 4.0.21     <- customer+product file' '4.0.21' \
    docker exec "${c1}" sh -c 'dpkg -s cassandra 2>/dev/null | grep ^Version || rpm -q cassandra'
  check_out 'snitch Gossiping   <- product file' 'GossipingPropertyFileSnitch' \
    docker exec "${c1}" grep '^endpoint_snitch' /etc/cassandra/cassandra.yaml
  check_out 'dc/rack            <- datacentre file + inventory' 'dc=dc_east' \
    docker exec "${c1}" cat /etc/cassandra/cassandra-rackdc.properties
  # In range-repair.sh, NOT in cron: the module schedules repair with a systemd
  # timer (cassandra-repair.timer), and the slice count is baked into the
  # script the timer runs. Checked where the value actually lands.
  check_out 'repair steps 20    <- product+environment file' '\-\-steps. .20' \
    docker exec "${c1}" grep -- '--steps' /usr/local/bin/range-repair.sh
  check_out 'repair timer is scheduled and running' 'cassandra-repair.timer' \
    docker exec "${c1}" systemctl list-timers --all
  # The other half of that same Hiera file: incremental backups OFF in nonprod.
  # Asserted as an ABSENCE, which is the harder direction and the one that
  # silently regresses -- a cron that should not exist is invisible.
  check_out 'full backup cron exists <- product file' 'cass-ops backup' \
    docker exec "${c1}" crontab -l
  if docker exec "${c1}" crontab -l 2>/dev/null | grep -q 'incremental'; then
    bad 'incremental backup cron present, but nonprod Hiera disables it'
    VERIFY_FAIL=$(( VERIFY_FAIL + 1 ))
  else
    ok 'no incremental backup cron <- product+environment file (false)'
    VERIFY_PASS=$(( VERIFY_PASS + 1 ))
  fi

  step 'Tenancy comes from the CERTIFICATE, not from facts'
  # The decisive test. Every tenancy layer in the hierarchy has a
  # trusted.extensions path AND a fact-fallback path pointing at the same file,
  # so a passing run proves nothing about which one was used.
  #
  # So: take the facts away and re-run. If the node still resolves its cluster
  # file -- still wants no change to cassandra.yaml -- the data can only have
  # come from $trusted['extensions'], i.e. from the signed certificate.
  #
  # This is what makes the hierarchy a tenancy boundary rather than a
  # convention: a node that rewrote its own facts to claim another customer
  # would still be served its own certificate's data.
  # The subject is DERIVED, not named. This was pinned to `cass3` and became
  # `FATAL cass3 not in inventory` the moment that node was decommissioned --
  # a hardcoded node name in the one test that has to keep working. The last
  # non-seed Cassandra node is used instead: non-seed because a seed's role
  # differs, last because it is the one most recently added and so the one
  # least likely to have been special-cased by hand.
  local tni=''
  for i in "${!N_SHORT[@]}"; do
    [[ "${N_PRODUCT[$i]}" == 'cassandra' ]] || continue
    [[ "${N_ROLE[$i]}" == 'cassandra_node' ]] || continue
    tni="${i}"
  done
  if [[ -z "${tni}" ]]; then
    # Not a failure: a single-node cluster is all seed. Skipping is honest;
    # counting it as a pass would inflate the total with a test that did not run.
    warn 'no non-seed Cassandra node in the inventory -- skipping the tenancy test'
  else
    local tn="${N_SHORT[$tni]}"
    local factfile='/etc/puppetlabs/facter/facts.d/instance.yaml'

    docker exec "${tn}" mv "${factfile}" "${factfile}.setaside" >/dev/null 2>&1
    # --detailed-exitcodes: 0 means "ran, nothing to change". If Hiera had lost
    # the tenancy layers it would fall back to estate defaults, the heap and
    # cluster name would differ, and this would report changes (exit 2).
    #
    # This is only a usable signal because the catalogue is genuinely
    # change-free on a converged node. It was not: a `notify` in
    # cassandra_pfpt::system_keyspaces reported a change on EVERY run, so this
    # test could never have passed for the right reason. It is a refreshonly
    # exec now.
    local rc=0
    docker exec "${tn}" /opt/puppetlabs/bin/puppet agent --test --noop \
      --detailed-exitcodes --server "${MASTER_CERTNAME}" >/dev/null 2>&1 || rc=$?
    docker exec "${tn}" mv "${factfile}.setaside" "${factfile}" >/dev/null 2>&1

    if [[ "${rc}" == '0' ]]; then
      ok "${tn} resolves its cluster data with NO facts present (trusted.extensions)"
      VERIFY_PASS=$(( VERIFY_PASS + 1 ))
    else
      bad "${tn} with no facts wanted changes (exit ${rc}): tenancy is coming from facts, not the certificate"
      VERIFY_FAIL=$(( VERIFY_FAIL + 1 ))
    fi
  fi

  step 'Cassandra, installed entirely from the master'
  for i in "${!N_SHORT[@]}"; do
    [[ "${N_PRODUCT[$i]}" == 'cassandra' ]] || continue
    name="${N_SHORT[$i]}"
    check "${name}: cassandra service active" \
      docker exec "${name}" systemctl is-active --quiet cassandra
    check_out "${name}: version is the Hiera-pinned 4.0.21" '4.0.21' \
      docker exec "${name}" sh -c 'dpkg -s cassandra 2>/dev/null | grep ^Version || rpm -q cassandra'
  done

  step 'The ring formed'
  local ci1; ci1="$(node_index cass1)" || true
  check_out 'ring is serving (at least one node Up/Normal)' 'UN' \
    docker exec "${N_SHORT[$ci1]}" nodetool status
  # Expected ring size comes from the INVENTORY, not a literal. Hardcoding 3
  # meant adding a fourth node to inventory.conf turned a healthy cluster into
  # a failing check -- which trains people to ignore the check.
  local expected_ring=0 j
  for j in "${!N_PRODUCT[@]}"; do
    [[ "${N_PRODUCT[$j]}" == 'cassandra' ]] && expected_ring=$(( expected_ring + 1 ))
  done

  local up_count
  up_count="$(docker exec "${N_SHORT[$ci1]}" sh -c "nodetool status 2>/dev/null | grep -c '^UN'" 2>/dev/null | tr -d ' ')"
  if [[ "${up_count}" == "${expected_ring}" ]]; then
    ok "all ${expected_ring} Cassandra nodes Up/Normal"; VERIFY_PASS=$(( VERIFY_PASS + 1 ))
  else
    bad "expected ${expected_ring} nodes Up/Normal (from inventory.conf), found ${up_count:-0}"
    VERIFY_FAIL=$(( VERIFY_FAIL + 1 ))
  fi
  check_out 'cluster name came from Hiera' 'amex-nonprod-core' \
    docker exec "${N_SHORT[$ci1]}" nodetool describecluster

  # =========================================================================
  # JENKINS
  # =========================================================================
  # Every per-node check above is gated on product == 'cassandra', so before
  # this section a completely broken Jenkins node passed `verify` in silence --
  # the same "unchecked looks exactly like passed" failure that hid the
  # jenkins/ci cluster from check-sizing.py.
  #
  # The loop is over the inventory, so an estate with no Jenkins runs no checks
  # and claims none.
  local ji
  for ji in "${!N_SHORT[@]}"; do
    [[ "${N_PRODUCT[$ji]}" == 'jenkins' ]] || continue
    name="${N_SHORT[$ji]}"

    step "Jenkins on ${name}, installed entirely from the master"

    check "${name}: jenkins service active" \
      docker exec "${name}" systemctl is-active --quiet jenkins

    # The JVM is NOT a dependency of the jenkins package -- its Debian
    # dependencies are adduser, lsb-base, net-tools, sysvinit-utils and nothing
    # else. It comes from site.pp's $jvm_products instead, so this check is the
    # one that fails if jenkins is ever dropped from that list.
    check "${name}: a JVM is present (site.pp \$jvm_products, not the package)" \
      docker exec "${name}" sh -c 'command -v java >/dev/null'

    # LISTENING ON THE PORT THE INVENTORY OPENED. Not on 8080, and not on
    # whatever the package happened to default to: $http_port was a parameter
    # nothing read, so for a long time Hiera asked for 8081 and every node
    # served 8080 while both files looked correct.
    check "${name}: listening on ${PORT_JENKINS}, the port the inventory opens" \
      docker exec "${name}" sh -c "ss -lnt 2>/dev/null | grep -q ':${PORT_JENKINS} '"

    # Serving, not merely listening. Jenkins binds the port early and then
    # spends a while unpacking its war, so a listening socket is not the same
    # as a working server.
    check "${name}: answers HTTP on ${PORT_JENKINS}" \
      docker exec "${name}" sh -c \
        "curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:${PORT_JENKINS}/login | grep -qE '^(200|403)$'"

    # mikefarah/yq, not the distribution package of the same name: cassy.sh
    # calls `yq -o=json`, which the Python yq rejects. The flag is checked
    # rather than the binary's presence, because a present-but-wrong yq is
    # exactly the failure this is guarding against.
    check "${name}: yq is the Go implementation cassy.sh needs" \
      docker exec "${name}" sh -c "echo 'a: 1' | yq -o=json '.' >/dev/null 2>&1"

    check "${name}: cassy is on PATH" \
      docker exec "${name}" sh -c 'test -x /usr/local/bin/cassy'

    # THE SEED JOB. The module shipped without it for the whole of its life --
    # a clean run produced a Jenkins with plugins, scripts and playbooks and
    # not one job -- so its absence is the regression worth naming.
    check "${name}: the Job DSL seed job exists on disk" \
      docker exec "${name}" sh -c 'test -f /var/lib/jenkins/jobs/cassandra-seed/config.xml'

    # The pipelines and the deployed files must agree about where the scripts
    # are. They did not: the DSL said /var/lib/jenkins/cassandra-scripts in 17
    # places while Puppet deployed to /var/lib/jenkins/scripts.
    check "${name}: the seed DSL points at a directory that exists" \
      docker exec "${name}" sh -c \
        'test -d "$(sed -n "s/.*SCRIPTS_PATH = .\([^'"'"']*\).*/\1/p" /var/lib/jenkins/scripts/seed.groovy | head -1)"'

    # Without this hook the seed job's first build fails with the whole of
    # "ERROR: script not yet approved for use" and the server has no
    # pipelines until a human clicks approve in Manage Jenkins. Everything
    # else above was green when that was discovered.
    check "${name}: the DSL script-approval hook is installed" \
      docker exec "${name}" sh -c \
        'test -f /var/lib/jenkins/init.groovy.d/10-approve-seed-dsl.groovy'

    # It ran, rather than merely existing. An init script that throws is
    # logged and skipped, and Jenkins starts perfectly well without it.
    check_out "${name}: the hook ran at startup" 'pre-approved' \
      docker exec "${name}" sh -c \
        'journalctl -u jenkins --no-pager 2>/dev/null | grep jenkins_pfpt | tail -1'
  done

  step 'Summary'
  printf '    %s%d passed%s, %s%d failed%s\n' \
    "${C_GREEN}" "${VERIFY_PASS}" "${C_RESET}" \
    "$( (( VERIFY_FAIL > 0 )) && printf '%s' "${C_RED}" || printf '%s' "${C_DIM}")" \
    "${VERIFY_FAIL}" "${C_RESET}"
  (( VERIFY_FAIL == 0 ))
}

# ===========================================================================
# main
# ===========================================================================
read_inventory

case "${1:-}" in
  teardown) cmd_teardown ;;
  up)       cmd_up ;;
  wait)     cmd_wait ;;
  status)   cmd_status ;;
  verify)   cmd_verify ;;
  logs)     cmd_logs "${2:-}" ;;
  ssh)      cmd_ssh "${2:-}" ;;
  explain)  cmd_explain "${2:-}" "${3:-}" ;;
  layers)   cmd_layers "${2:-cass1}" ;;
  render)   cmd_render "${2:-}" ;;
  all)      cmd_teardown && cmd_up && cmd_wait; cmd_status; cmd_verify ;;
  *)
    sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
