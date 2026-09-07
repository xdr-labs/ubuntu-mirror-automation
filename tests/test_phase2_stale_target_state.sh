#!/usr/bin/env bash
# Stale PHASE2_TARGET_VERSION=6.5.0 normalizes at mutation boundaries; pure reads do not mutate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_PROJECT_ROOT="$ROOT"
export MM_LOG_DIR="$TMP/logs"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$TMP/config/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$TMP/config/status"
export MM_WORKFLOW_FILE="$TMP/config/workflow.state"
export MM_CLIENT_ROOT="$TMP/client"
export MM_SELECTIVE_ROOT="$TMP/selective"
export MM_DP_PHASE2_ROOT="$TMP/dp-phase2"
mkdir -p "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$MM_CLIENT_ROOT" \
  "$MM_SELECTIVE_ROOT/ubuntu" "$MM_DP_PHASE2_ROOT/6.6.0"
: >"$MM_STATUS_FILE"

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"

PREPARATION_MODE=FULL
PHASE2_TARGET_VERSION=6.6.0
TARGET_DP_VERSION=6.6.0
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
ACPS_USERNAME=u
ACPS_PASSWORD=p
WORKER_SSH_PASSWORD=''
DL_WORKER_IPS=''
DA_WORKER_IPS=''
mm_save_gui_config >/dev/null

mm_wf_ensure_file
# Simulate leftover 6.5.0 identity with current 6.6.0 artifacts.
mm_wf_set_many \
  "PHASE2_TARGET_VERSION=6.5.0" \
  "WORKFLOW_STATE=PREPARED" \
  "PHASE2_GENERATION_ID=keep-me" \
  "OS_CORE_GENERATION_ID=keep-os" \
  "READINESS_VERIFIED_GENERATION_ID=stale-ready" \
  "COMMAND_FILE_GENERATION_ID=stale-cmd"
printf 'TARGET_DP_VERSION=6.6.0\nPHASE2_ARTIFACT_VERSION=6.6.0\n' \
  >"${MM_DP_PHASE2_ROOT}/6.6.0/release.env"
: >"${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar"
: >"${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar.sha256"

# 16. Pure read must not mutate.
WF_BEFORE="$(cksum "$MM_WORKFLOW_FILE" | awk '{print $1" "$2}')"
mm_wf_get PHASE2_TARGET_VERSION >/dev/null
mm_download_completed >/dev/null 2>&1 || true
if declare -F mm_readiness_completed >/dev/null 2>&1; then
  mm_readiness_completed >/dev/null 2>&1 || true
fi
WF_AFTER_READ="$(cksum "$MM_WORKFLOW_FILE" | awk '{print $1" "$2}')"
[[ "$WF_BEFORE" == "$WF_AFTER_READ" ]] || fail "pure read mutated workflow.state"
[[ "$(mm_wf_get PHASE2_TARGET_VERSION)" == "6.5.0" ]] \
  || fail "pure read changed stale target"
pass "pure read workflow functions still do not mutate state"

# 15. Mutation boundary normalizes 6.5.0 → 6.6.0 without deleting artifacts.
mm_wf_normalize_fixed_phase2_target || fail "normalize failed"
[[ "$(mm_wf_get PHASE2_TARGET_VERSION)" == "6.6.0" ]] \
  || fail "stale target remains $(mm_wf_get PHASE2_TARGET_VERSION)"
[[ "$(mm_wf_get PHASE2_GENERATION_ID)" == "keep-me" ]] \
  || fail "normalize deleted PHASE2_GENERATION_ID"
[[ "$(mm_wf_get OS_CORE_GENERATION_ID)" == "keep-os" ]] \
  || fail "normalize deleted OS_CORE_GENERATION_ID"
[[ -z "$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)" ]] \
  || fail "stale readiness generation not invalidated"
[[ -z "$(mm_wf_get COMMAND_FILE_GENERATION_ID)" ]] \
  || fail "stale command generation not invalidated"
[[ -f "${MM_DP_PHASE2_ROOT}/6.6.0/release.env" ]] \
  || fail "normalize deleted 6.6.0 artifacts"
grep -q 'PHASE2_TARGET_VERSION_FIXED="6.6.0"' \
  "${ROOT}/scripts/lib/mirror_manager_common.sh" \
  || fail "fixed target is not 6.6.0"
pass "stale 6.5.0 state normalizes to 6.6.0 without deleting artifacts"

# Config save also normalizes.
mm_wf_set_many "PHASE2_TARGET_VERSION=6.5.0"
mm_save_gui_config >/dev/null
[[ "$(mm_wf_get PHASE2_TARGET_VERSION)" == "6.6.0" ]] \
  || fail "config save left stale 6.5.0"
pass "configuration save normalizes stale target"

echo "ALL test_phase2_stale_target_state checks passed"
