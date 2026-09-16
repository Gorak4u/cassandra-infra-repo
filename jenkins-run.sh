#!/usr/bin/env bash
# jenkins-run.sh -- trigger a Jenkins job from the host via docker exec
#
# Usage:
#   ./jenkins-run.sh <job-name> [PARAM=value ...]
#
# Examples:
#   ./jenkins-run.sh "Cassandra - Command" NODE_LIST=cass1.lab.pfpt "CASSY_COMMAND=sudo cass-ops health"
#   ./jenkins-run.sh "Cassandra - Restart" NODE_LIST=cass1.lab.pfpt
#   ./jenkins-run.sh "Cassandra - Repair"  NODE_LIST=cass1.lab.pfpt
#   ./jenkins-run.sh cassandra-seed

set -euo pipefail

JENKINS_HOST="127.0.0.1:8081"
JENKINS_USER="admin"
JENKINS_PASS="98daa1c8aefc40c38693dc533df0b77f"
CONTAINER="jenkins1"

JOB="${1:-}"
[[ -n "$JOB" ]] || { echo "Usage: $0 <job-name> [PARAM=value ...]"; exit 1; }
shift

# URL-encode a string (needs python3, which is already on jenkins1)
urlencode() { python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1"; }

# Jobs inside the Cassandra folder need the folder prefix
if [[ "$JOB" == Cassandra\ * ]]; then
  JOB_PATH="Cassandra/job/$(urlencode "$JOB")"
else
  JOB_PATH="$(urlencode "$JOB")"
fi

# Build the parameter string
PARAM_ARGS=""
for kv in "$@"; do
  KEY="${kv%%=*}"
  VAL="${kv#*=}"
  PARAM_ARGS="${PARAM_ARGS}&${KEY}=$(urlencode "$VAL")"
done

docker exec "$CONTAINER" bash -c "
  COOKIEJAR=\$(mktemp)
  BASE=\"http://${JENKINS_USER}:${JENKINS_PASS}@${JENKINS_HOST}\"

  # Get CSRF crumb
  CRUMB_JSON=\$(curl -sf -c \"\$COOKIEJAR\" -b \"\$COOKIEJAR\" \"\$BASE/crumbIssuer/api/json\")
  FIELD=\$(echo \"\$CRUMB_JSON\" | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField'])\")
  VALUE=\$(echo \"\$CRUMB_JSON\" | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['crumb'])\")

  # Trigger the build
  if [[ -n \"${PARAM_ARGS}\" ]]; then
    BUILD_URL=\"\$BASE/job/${JOB_PATH}/buildWithParameters?${PARAM_ARGS#&}\"
  else
    BUILD_URL=\"\$BASE/job/${JOB_PATH}/build\"
  fi

  STATUS=\$(curl -sf -o /dev/null -w '%{http_code}' \\
    -c \"\$COOKIEJAR\" -b \"\$COOKIEJAR\" \\
    -X POST -H \"\$FIELD: \$VALUE\" \\
    \"\$BUILD_URL\")
  rm -f \"\$COOKIEJAR\"

  if [[ \"\$STATUS\" == 201 ]]; then
    echo \"[ok] Job '${JOB}' triggered (HTTP 201)\"
    echo \"     Check logs: docker exec ${CONTAINER} cat /var/lib/jenkins/jobs/${JOB_PATH//\\/jobs\\//-}/builds/lastBuild/log 2>/dev/null\"
  else
    echo \"[FAIL] Got HTTP \$STATUS for job '${JOB}'\"
    exit 1
  fi
"
