#!/usr/bin/env bash
# mirror_workflow_state.sh must work when sourced alone without mm_info/mm_warn/mm_ok.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_WORKFLOW_FILE="$TMP/workflow.state"
export MM_CONFIG_DIR="$TMP/config"
mkdir -p "$MM_CONFIG_DIR"

run_case() {
  local label="$1"
  local setup="$2"
  local out="$TMP/${label}.out"
  local err="$TMP/${label}.err"
  local rc
  set +e
  env -i \
    PATH="/usr/bin:/bin" \
    HOME="$TMP" \
    MM_WORKFLOW_FILE="$MM_WORKFLOW_FILE" \
    MM_CONFIG_DIR="$MM_CONFIG_DIR" \
    bash --noprofile --norc -c "
set -euo pipefail
${setup}
# shellcheck source=/dev/null
source '${ROOT}/scripts/lib/mirror_workflow_state.sh'
mm_wf_mark_client_set_published 'gen-fixture-1' 'FPRTEST' 'sha-fixture-1'
" >"$out" 2>"$err"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]]
  ! grep -E 'mm_(info|warn|ok): command not found|command not found' "$out" "$err"
  [[ "$(mm_wf_get_from_file WORKFLOW_STATE)" == "CLIENT_SET_PUBLISHED" ]]
  [[ "$(mm_wf_get_from_file CLIENT_SET_GENERATION_ID)" == "gen-fixture-1" ]]
  [[ "$(mm_wf_get_from_file CLIENT_BUILD_INPUT_SHA256)" == "sha-fixture-1" ]]
  printf '%s=PASS\n' "$label"
}

mm_wf_get_from_file() {
  awk -F= -v k="$1" '$1==k { print substr($0, length($1) + 2); exit }' "$MM_WORKFLOW_FILE"
}

# Case A: no logger helpers, no mm_status_set.
rm -f "$MM_WORKFLOW_FILE"
run_case "WORKFLOW_WITHOUT_LOGGER" ":"

# Case B: mm_status_set stub present, still no mm_info.
rm -f "$MM_WORKFLOW_FILE"
run_case "WORKFLOW_WITH_STATUS_STUB" '
mm_status_set() { :; }
'

# Case C: real logger helpers are preferred when defined.
rm -f "$MM_WORKFLOW_FILE"
LOG_CAPTURE="$TMP/logger.capture"
: >"$LOG_CAPTURE"
env -i \
  PATH="/usr/bin:/bin" \
  HOME="$TMP" \
  MM_WORKFLOW_FILE="$MM_WORKFLOW_FILE" \
  MM_CONFIG_DIR="$MM_CONFIG_DIR" \
  LOG_CAPTURE="$LOG_CAPTURE" \
  bash --noprofile --norc -c '
set -euo pipefail
mm_info() { printf "INFO:%s\n" "$*" >>"$LOG_CAPTURE"; }
mm_warn() { printf "WARN:%s\n" "$*" >>"$LOG_CAPTURE"; }
mm_ok() { printf "OK:%s\n" "$*" >>"$LOG_CAPTURE"; }
# shellcheck source=/dev/null
source "'"${ROOT}/scripts/lib/mirror_workflow_state.sh"'"
mm_wf_mark_client_set_published "gen-fixture-2" "FPR2" "sha-fixture-2"
mm_wf_mark_http_enabled "gen-fixture-2"
mm_wf_mark_readiness_verified
' >/dev/null
grep -q '^INFO:WORKFLOW_STATE=CLIENT_SET_PUBLISHED' "$LOG_CAPTURE"
grep -q '^INFO:WORKFLOW_STATE=HTTP_ENABLED' "$LOG_CAPTURE"
grep -q '^OK:UPGRADE_READINESS=PASS' "$LOG_CAPTURE"
[[ "$(mm_wf_get_from_file WORKFLOW_STATE)" == "READINESS_VERIFIED" ]]
[[ "$(mm_wf_get_from_file CLIENT_SET_GENERATION_ID)" == "gen-fixture-2" ]]
echo "WORKFLOW_WITH_LOGGER_DELEGATION=PASS"

# Creating workflow.state must restore umask so later public trees are 0755/0644.
rm -f "$MM_WORKFLOW_FILE"
UMASK_PROBE="$TMP/umask-probe"
rm -rf "$UMASK_PROBE"
env -i \
  PATH="/usr/bin:/bin" \
  HOME="$TMP" \
  MM_WORKFLOW_FILE="$MM_WORKFLOW_FILE" \
  MM_CONFIG_DIR="$MM_CONFIG_DIR" \
  UMASK_PROBE="$UMASK_PROBE" \
  bash --noprofile --norc -c '
set -euo pipefail
umask 022
# shellcheck source=/dev/null
source "'"${ROOT}/scripts/lib/mirror_workflow_state.sh"'"
mm_wf_ensure_file
after="$(umask)"
mkdir -p "$UMASK_PROBE/dir"
printf "x\n" >"$UMASK_PROBE/dir/file.txt"
printf "UMASK_AFTER=%s\n" "$after"
printf "DIR_MODE=%s\n" "$(stat -c %a "$UMASK_PROBE/dir")"
printf "FILE_MODE=%s\n" "$(stat -c %a "$UMASK_PROBE/dir/file.txt")"
printf "STATE_MODE=%s\n" "$(stat -c %a "$MM_WORKFLOW_FILE")"
' >"$TMP/umask.out"
grep -q '^UMASK_AFTER=0022$' "$TMP/umask.out"
grep -q '^DIR_MODE=755$' "$TMP/umask.out"
grep -q '^FILE_MODE=644$' "$TMP/umask.out"
grep -q '^STATE_MODE=600$' "$TMP/umask.out"
echo "WORKFLOW_ENSURE_FILE_UMASK_RESTORED=PASS"

echo "MIRROR_WORKFLOW_STATE_WITHOUT_LOGGER=PASS"
