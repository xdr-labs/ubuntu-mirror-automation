#!/usr/bin/env bash
# Dashboard / workflow status combinations for OS vs Phase2 independence and
# generation-bound Upgrade Readiness.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=/dev/null
source "${ROOT}/scripts/ubuntu-offline-mirror-entrypoint.sh"

MM_SELECTIVE_ROOT="$TMP/selective"
MM_CLIENT_ROOT="$TMP/client"
MM_DP_PHASE2_ROOT="$TMP/dp-phase2"
PHASE2_TARGET_VERSION=6.6.0
TARGET_DP_VERSION=6.6.0
PREPARATION_MODE=FULL
MM_WF_PHASE2_RELEASE="$MM_DP_PHASE2_ROOT/6.6.0/release.env"
MM_WF_PHASE2_BUNDLE="$MM_DP_PHASE2_ROOT/6.6.0/dp_bundle_6.6.0-current.tar"
MM_WF_PHASE2_SIDECAR="$MM_WF_PHASE2_BUNDLE.sha256"
mkdir -p "$MM_SELECTIVE_ROOT/ubuntu" "$MM_CLIENT_ROOT" "$(dirname "$MM_WF_PHASE2_RELEASE")"
: >"$MM_WF_PHASE2_RELEASE"
: >"$MM_WF_PHASE2_BUNDLE"
: >"$MM_WF_PHASE2_SIDECAR"

STATUS_R2=PASS
STATUS_OS=PASS
STATUS_BUNDLE=PASS
STATUS_ENTRIES=9
STATUS_LAST=PASS
STATUS_FP=fp-current

mm_configuration_completed() { return 0; }
engine_resolve_paths() { return 0; }
mm_phase2_paths() { return 0; }
mm_is_phase2_only() { return 1; }
mm_client_files_ready() { return 0; }
mm_client_files_ready_phase2() { return 0; }
mm_client_set_current_source() { return 0; }
mm_temps_present() { return 1; }
mm_artifact_fingerprint() { printf '%s\n' "$STATUS_FP"; }
mm_file_bytes() { printf '0\n'; }
mm_ts() { printf '2026-08-07T00:00:00Z\n'; }
mm_status_set() { :; }
mm_status_get() {
  case "$1" in
    PHASE2_BUNDLE_CHECKSUM) printf '%s\n' "$STATUS_BUNDLE" ;;
    PHASE2_BUNDLE_ENTRY_COUNT) printf '%s\n' "$STATUS_ENTRIES" ;;
    OS_MIRROR_READY) printf '%s\n' "$STATUS_OS" ;;
    R2_OS_CORE_CHECKSUM) printf '%s\n' "$STATUS_R2" ;;
    DOWNLOAD_PREPARE_RESULT|LAST_EXECUTION_RESULT|INSTALL_RESULT) printf '%s\n' "$STATUS_LAST" ;;
    DOWNLOAD_ARTIFACT_FINGERPRINT) printf '%s\n' "$STATUS_FP" ;;
    UPGRADE_READINESS) printf '%s\n' "${STATUS_UPGRADE_READINESS:-PASS}" ;;
    *) printf '\n' ;;
  esac
}

expect_os() {
  local want="$1"
  if uom_os_upgrade_files_completed; then
    [[ "$want" == READY ]]
  else
    [[ "$want" == NOT_READY ]]
  fi
}
expect_p2() {
  local want="$1"
  if uom_phase2_bundle_completed; then
    [[ "$want" == READY ]]
  else
    [[ "$want" == NOT_READY ]]
  fi
}

# Case 1
STATUS_R2=PASS STATUS_OS=PASS STATUS_BUNDLE=PASS STATUS_ENTRIES=9
expect_os READY
expect_p2 READY
echo "DASHBOARD_CASE1_PASS_PASS=PASS"

# Case 2
STATUS_R2=REUSED
expect_os READY
expect_p2 READY
echo "DASHBOARD_CASE2_REUSED=PASS"

# Case 3
STATUS_R2=UNKNOWN
expect_os NOT_READY
expect_p2 READY
echo "DASHBOARD_CASE3_UNKNOWN_OS=PASS"

# Case 4
STATUS_R2=PASS STATUS_BUNDLE=FAIL
expect_os READY
expect_p2 NOT_READY
echo "DASHBOARD_CASE4_PHASE2_FAIL=PASS"

# Case 5 / 6: generation-bound readiness via workflow module
export MM_WORKFLOW_FILE="$TMP/workflow.state"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$TMP/config/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$TMP/status"
mkdir -p "$MM_CONFIG_DIR"
: >"$MM_STATUS_FILE"
cat >"$MM_CONFIG_FILE" <<'EOF'
PREPARATION_MODE=FULL
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
ACPS_USERNAME=fixture
ACPS_PASSWORD=fixture
EOF
# Force a clean load of the workflow module in this process.
unset MIRROR_WORKFLOW_STATE_LOADED
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_workflow_state.sh"

PREPARATION_MODE=FULL
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
PHASE2_TARGET_VERSION=6.6.0
mm_wf_mark_configured >/dev/null
GEN="$(mm_wf_get WORKFLOW_GENERATION_ID)"
mm_wf_mark_prepared "os-${GEN}" "p2-${GEN}" >/dev/null
mm_wf_mark_client_set_published "client-${GEN}" "FPR" "inputsha" >/dev/null
mm_wf_mark_http_enabled "client-${GEN}" >/dev/null
mm_wf_mark_readiness_verified >/dev/null
mm_wf_mark_commands_generated "client-${GEN}" >/dev/null

[[ "$(mm_wf_get CLIENT_SET_GENERATION_ID)" == "client-${GEN}" ]]
[[ "$(mm_wf_get HTTP_PUBLICATION_GENERATION_ID)" == "client-${GEN}" ]]
[[ "$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)" == "client-${GEN}" ]]
[[ "$(mm_wf_get COMMAND_FILE_GENERATION_ID)" == "client-${GEN}" ]]
mm_wf_readiness_generation_current
echo "DASHBOARD_CASE6_GENERATION_ALIGNED=PASS"

# Case 5: mismatch demotes readiness
mm_wf_set_many "READINESS_VERIFIED_GENERATION_ID=other-gen"
if mm_wf_readiness_generation_current; then
  echo "DASHBOARD_CASE5_GENERATION_MISMATCH=FAIL" >&2
  exit 1
fi
echo "DASHBOARD_CASE5_GENERATION_MISMATCH=PASS"

# Case 7: logger-less transition still records state (rc=0)
unset -f mm_info mm_warn mm_ok 2>/dev/null || true
export MM_WORKFLOW_FILE="$TMP/workflow2.state"
export MM_CONFIG_FILE="$TMP/config/dp-upgrade-mirror.conf"
rm -f "$MM_WORKFLOW_FILE"
unset MIRROR_WORKFLOW_STATE_LOADED
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_workflow_state.sh"
mm_wf_mark_client_set_published "standalone-gen" "FPRX" "shaX"
[[ "$(mm_wf_get WORKFLOW_STATE)" == "CLIENT_SET_PUBLISHED" ]]
echo "DASHBOARD_CASE7_LOGGERLESS_WORKFLOW=PASS"

echo "DASHBOARD_WORKFLOW_STATUS_CASES=PASS"
