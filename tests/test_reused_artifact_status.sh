#!/usr/bin/env bash
# Regression coverage for snapshot/reinstall status reconciliation:
# PASS and REUSED are both success, and OS/Phase2 status is independent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Source only function definitions; the entrypoint has an execution guard.
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

STATUS_R2=REUSED
STATUS_OS=PASS
STATUS_BUNDLE=PASS
STATUS_ENTRIES=9
STATUS_LAST=PASS
STATUS_FP=fp-current
WRITES="$TMP/writes"
: >"$WRITES"

mm_configuration_completed() { return 0; }
engine_resolve_paths() { return 0; }
mm_phase2_paths() { return 0; }
mm_is_phase2_only() { [[ "$PREPARATION_MODE" == "PHASE2_ONLY" ]]; }
mm_client_files_ready() { return 0; }
mm_client_files_ready_phase2() { return 0; }
mm_client_set_current_source() { return 0; }
mm_temps_present() { return 1; }
mm_artifact_fingerprint() { printf '%s\n' "$STATUS_FP"; }
mm_file_bytes() { printf '0\n'; }
mm_ts() { printf '2026-08-06T00:00:00Z\n'; }
mm_status_set() { printf '%s=%s\n' "$1" "$2" >>"$WRITES"; }
mm_status_get() {
  case "$1" in
    PHASE2_BUNDLE_CHECKSUM) printf '%s\n' "$STATUS_BUNDLE" ;;
    PHASE2_BUNDLE_ENTRY_COUNT) printf '%s\n' "$STATUS_ENTRIES" ;;
    OS_MIRROR_READY) printf '%s\n' "$STATUS_OS" ;;
    R2_OS_CORE_CHECKSUM) printf '%s\n' "$STATUS_R2" ;;
    DOWNLOAD_PREPARE_RESULT|LAST_EXECUTION_RESULT|INSTALL_RESULT) printf '%s\n' "$STATUS_LAST" ;;
    DOWNLOAD_ARTIFACT_FINGERPRINT) printf '%s\n' "$STATUS_FP" ;;
    HTTP_DISTRIBUTION) printf 'ENABLED\n' ;;
    LOG_PATH) printf '/tmp/test.log\n' ;;
    *) printf '\n' ;;
  esac
}

uom_status_success PASS
uom_status_success REUSED
! uom_status_success FAIL
! uom_status_success ""

# Core regression: a reused, previously verified R2 package is download-complete.
uom_mm_download_completed
echo "REUSED_OS_CORE_DOWNLOAD_COMPLETED=PASS"

# Unknown/non-success checksum still fails closed.
STATUS_R2=UNKNOWN
! uom_mm_download_completed
STATUS_R2=REUSED

# Independent status: a bad OS status must not hide a valid Phase 2 bundle.
STATUS_R2=FAIL
! uom_os_upgrade_files_completed
uom_phase2_bundle_completed
STATUS_R2=REUSED
uom_os_upgrade_files_completed

# Exercise the operator-facing status text with the two states intentionally split.
load_mirror_defaults() { return 0; }
mm_load_gui_config() { return 0; }
mm_normalize_preparation_mode() { return 0; }
mm_force_phase2_target() { return 0; }
mm_collect_workflow_status() {
  MM_WF_CONFIG_COMPLETED=1
  MM_WF_HTTP_COMPLETED=1
}
mm_upgrade_readiness_display() { printf 'PASS\n'; }
mm_preparation_mode_label() { printf 'Full OS Upgrade + Phase 2'; }
mm_workflow_progress_text() { printf 'Progress: 4 of 4 workflow steps completed'; }
STATUS_OUT="$TMP/status.txt"
mm_whiptail_textbox() { cp "$2" "$STATUS_OUT"; }

STATUS_R2=FAIL
uom_gui_show_status
grep -q '^OS Upgrade Files: NOT READY$' "$STATUS_OUT"
grep -q '^DP 6.6.0 Bundle: READY (9 files)$' "$STATUS_OUT"

STATUS_R2=REUSED
uom_gui_show_status
grep -q '^OS Upgrade Files: READY$' "$STATUS_OUT"
grep -q '^DP 6.6.0 Bundle: READY (9 files)$' "$STATUS_OUT"
grep -q '^Upgrade Readiness: PASS$' "$STATUS_OUT"
grep -q '^Progress: 4 of 4 workflow steps completed$' "$STATUS_OUT"

echo "INDEPENDENT_STATUS_DISPLAY=PASS"
echo "REUSED_ARTIFACT_STATUS=PASS"
