#!/bin/bash
# ===========================================================================
# USER-DATA, fragment 1 of 4: prelude
# ===========================================================================
#
# GENERATED FILE on the instance -- assembled by infra/provision.sh (or by
# Terraform's templatefile(), for a cloud) from four fragments:
#
#   00-prelude.sh                 this file: shell options and logging
#   10-metadata-<platform>.sh     PLATFORM-SPECIFIC: how the node learns who
#                                 it is. The ONLY fragment that differs
#                                 between Docker, EC2 and GCE.
#   20-common.sh                  everything else, identical everywhere
#   30-role-<role>.sh             what this particular role does
#
# Editing the assembled file on a running instance has no effect on the next
# one. Edit the fragments.
#
# Runs ONCE, at first boot, as root.
#
# WHY FOUR FRAGMENTS
# ------------------
# So that supporting a new platform is one new file rather than a fork of the
# whole script. The entire interface between the platform and the node is ten
# environment variables (see 20-common.sh), and fragment 2 is the only thing
# that has to know how to obtain them.
#
# The order is load-bearing: the shebang must be first, the metadata fragment
# only DEFINES load_instance_metadata(), and 20-common.sh is what calls it --
# after the logging functions below exist, so a metadata failure can report
# itself properly.

# NOT `set -e`. Every failure below is handled explicitly with a message naming
# what failed, because the only diagnostic anyone gets from a failed first boot
# is this log. `set -e` would abort with no context at all.
set -uo pipefail

readonly MARKER_DIR='/var/lib/instance'
readonly MARKER="${MARKER_DIR}/user-data.done"
readonly PUPPET_BIN='/opt/puppetlabs/bin/puppet'

log()  { printf '[user-data %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
warn() { printf '[user-data %s] WARN  %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf '[user-data %s] FATAL %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

# Every identity value is REQUIRED. A node that does not know its own tenant
# must not come up guessing: a wrong guess resolves every tenancy layer in the
# Hiera hierarchy to estate-wide defaults, and the node then looks perfectly
# healthy while running another customer's configuration.
require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] ||
    die "instance metadata is missing ${name} -- see fragment 10-metadata-* for where it should have come from"
}
