#!/usr/bin/env bash
# Pure-read status checks + legacy CONFIG_SHA256 migration classification.
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
mm_phase2_paths
: >"${MM_WF_PHASE2_RELEASE}"
: >"${MM_WF_PHASE2_BUNDLE}"
: >"${MM_WF_PHASE2_SIDECAR}"

# Minimal stubs so download/readiness reach the fingerprint gate.
mm_configuration_completed() { return 0; }
mm_client_files_ready() { return 0; }
mm_client_files_ready_phase2() { return 0; }
mm_client_set_current_source() { return 0; }
mm_temps_present() { return 1; }
mm_nginx_distribution_live() { return 0; }
mm_http_required_urls_ok() { return 0; }
mm_artifact_fingerprint() { printf 'fp-current\n'; }

mm_status_set PHASE2_BUNDLE_CHECKSUM PASS
mm_status_set PHASE2_BUNDLE_ENTRY_COUNT 9
mm_status_set OS_MIRROR_READY PASS
mm_status_set R2_OS_CORE_CHECKSUM PASS
mm_status_set DOWNLOAD_PREPARE_RESULT PASS
mm_status_set HTTP_DISTRIBUTION ENABLED
mm_status_set HTTP_CONFIGURATION_READY PASS
mm_status_set UPGRADE_READINESS PASS
mm_status_set READINESS_RESULT PASS
# Explicitly leave fingerprints empty.
mm_status_set DOWNLOAD_ARTIFACT_FINGERPRINT ""
mm_status_set READINESS_ARTIFACT_FINGERPRINT ""

STATUS_BEFORE="$(cksum "$MM_STATUS_FILE" | awk '{print $1" "$2}')"
WRITES_BEFORE="$(wc -c <"$MM_STATUS_FILE" | tr -d ' ')"

if mm_download_completed; then
  fail "mm_download_completed succeeded without stored fingerprint"
fi
STATUS_AFTER_DL="$(cksum "$MM_STATUS_FILE" | awk '{print $1" "$2}')"
[[ "$STATUS_BEFORE" == "$STATUS_AFTER_DL" ]] \
  || fail "mm_download_completed wrote status when fingerprint missing"
# Also ensure no fingerprint was minted.
[[ -z "$(mm_status_get DOWNLOAD_ARTIFACT_FINGERPRINT)" ]] \
  || fail "DOWNLOAD_ARTIFACT_FINGERPRINT was minted during pure read"
pass "mm_download_completed is pure-read without fingerprint"

if mm_readiness_completed; then
  fail "mm_readiness_completed succeeded without stored fingerprint"
fi
STATUS_AFTER_RD="$(cksum "$MM_STATUS_FILE" | awk '{print $1" "$2}')"
[[ "$STATUS_BEFORE" == "$STATUS_AFTER_RD" ]] \
  || fail "mm_readiness_completed wrote status when fingerprint missing"
[[ -z "$(mm_status_get READINESS_ARTIFACT_FINGERPRINT)" ]] \
  || fail "READINESS_ARTIFACT_FINGERPRINT was minted during pure read"
WRITES_AFTER="$(wc -c <"$MM_STATUS_FILE" | tr -d ' ')"
[[ "$WRITES_BEFORE" == "$WRITES_AFTER" ]] \
  || fail "status file size changed during pure-read checks"
pass "mm_readiness_completed is pure-read without fingerprint"

# --- Legacy workflow: CONFIG_SHA256 set, empty layered hashes ---
# Different current config → LEGACY_UNKNOWN (not NONE).
rm -f "$MM_WORKFLOW_FILE"
mm_wf_ensure_file
mm_wf_set_many \
  "CONFIG_SHA256=deadbeefcafebabe000000000000000000000000000000000000000000000000" \
  "CONFIG_PREPARE_SHA256=" \
  "CONFIG_PUBLICATION_SHA256=" \
  "CONFIG_COMMAND_SHA256=" \
  "CONFIG_AUTH_SHA256="
mm_wf_classify_config_change
[[ "$MM_WF_CONFIG_CHANGE_CLASS" == "LEGACY_UNKNOWN" ]] \
  || fail "expected LEGACY_UNKNOWN got ${MM_WF_CONFIG_CHANGE_CLASS}"
[[ "$MM_WF_CONFIG_CHANGE_CLASS" != "NONE" ]] || fail "legacy mismatch must not be NONE"
pass "legacy mismatched CONFIG_SHA256 → LEGACY_UNKNOWN"

# Same CONFIG_SHA256 as current composite → NONE migration.
cur_sha="$(mm_wf_config_sha256)"
[[ -n "$cur_sha" ]] || fail "current config sha empty"
mm_wf_set_many \
  "CONFIG_SHA256=${cur_sha}" \
  "CONFIG_PREPARE_SHA256=" \
  "CONFIG_PUBLICATION_SHA256=" \
  "CONFIG_COMMAND_SHA256=" \
  "CONFIG_AUTH_SHA256="
mm_wf_classify_config_change
[[ "$MM_WF_CONFIG_CHANGE_CLASS" == "NONE" ]] \
  || fail "expected NONE migration got ${MM_WF_CONFIG_CHANGE_CLASS}"
[[ "${MM_WF_STALE_REASON}" == "migrated_layer_identities" ]] \
  || fail "expected migrated_layer_identities reason got ${MM_WF_STALE_REASON}"
pass "legacy matching CONFIG_SHA256 → NONE migration"

echo "ALL test_workflow_pure_reads_and_legacy checks passed"
