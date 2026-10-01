#!/usr/bin/env bash
# P1 regression: DOWNLOAD_ARTIFACT_FINGERPRINT is generation-bound evidence.
# Missing stored fingerprint => NOT VERIFIED / fail closed; read/status paths
# must never mint it. Public entrypoint must not override core semantics.
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

mm_configuration_completed() { return 0; }
mm_client_files_ready() { return 0; }
mm_client_files_ready_phase2() { return 0; }
mm_client_set_current_source() { return 0; }
mm_temps_present() { return 1; }
mm_artifact_fingerprint() { printf '%s\n' "${FP_CURRENT:-fp-current}"; }

mm_status_set PHASE2_BUNDLE_CHECKSUM PASS
mm_status_set PHASE2_BUNDLE_ENTRY_COUNT 9
mm_status_set OS_MIRROR_READY PASS
mm_status_set R2_OS_CORE_CHECKSUM PASS
mm_status_set DOWNLOAD_PREPARE_RESULT PASS

# --- A. Missing stored fingerprint: fail closed, do not mint ---
mm_status_set DOWNLOAD_ARTIFACT_FINGERPRINT ""
STATUS_BEFORE="$(cksum "$MM_STATUS_FILE" | awk '{print $1" "$2}')"
if mm_download_completed; then
  fail "A: mm_download_completed succeeded without stored fingerprint"
fi
STATUS_AFTER="$(cksum "$MM_STATUS_FILE" | awk '{print $1" "$2}')"
[[ "$STATUS_BEFORE" == "$STATUS_AFTER" ]] \
  || fail "A: status file mutated when fingerprint missing"
[[ -z "$(mm_status_get DOWNLOAD_ARTIFACT_FINGERPRINT)" ]] \
  || fail "A: DOWNLOAD_ARTIFACT_FINGERPRINT was minted during readiness read"
pass "A: missing fingerprint fails closed without minting"

# --- B. Matching stored fingerprint: readiness succeeds ---
FP_CURRENT=fp-match
mm_status_set DOWNLOAD_ARTIFACT_FINGERPRINT "fp-match"
mm_download_completed || fail "B: matching fingerprint should succeed"
pass "B: matching fingerprint succeeds"

# --- C. Mismatched stored fingerprint: fail closed ---
FP_CURRENT=fp-current
mm_status_set DOWNLOAD_ARTIFACT_FINGERPRINT "fp-stale"
if mm_download_completed; then
  fail "C: mismatched fingerprint should fail closed"
fi
[[ "$(mm_status_get DOWNLOAD_ARTIFACT_FINGERPRINT)" == "fp-stale" ]] \
  || fail "C: stored fingerprint must remain unchanged on mismatch"
pass "C: mismatched fingerprint fails closed"

# --- D. Public entrypoint parity: overrides must not alter core contract ---
if grep -E '^[[:space:]]*uom_mm_download_completed|^[[:space:]]*mm_status_set[[:space:]]+DOWNLOAD_ARTIFACT_FINGERPRINT' \
  "${ROOT}/scripts/ubuntu-offline-mirror-entrypoint.sh" >/dev/null; then
  fail "D: entrypoint still overrides or mints DOWNLOAD_ARTIFACT_FINGERPRINT"
fi
! grep -q 'uom_mm_download_completed' \
  "${ROOT}/scripts/ubuntu-offline-mirror-entrypoint.sh" \
  || fail "D: obsolete uom_mm_download_completed still present in entrypoint"

CORE_DEF="$(declare -f mm_download_completed)"
[[ -n "$CORE_DEF" ]] || fail "D: core mm_download_completed missing"

# shellcheck source=/dev/null
source "${ROOT}/scripts/ubuntu-offline-mirror-entrypoint.sh"
uom_install_status_overrides

! declare -F uom_mm_download_completed >/dev/null 2>&1 \
  || fail "D: uom_mm_download_completed should not exist"
AFTER_DEF="$(declare -f mm_download_completed)"
[[ "$CORE_DEF" == "$AFTER_DEF" ]] \
  || fail "D: public entrypoint overrides altered mm_download_completed"

mm_status_set DOWNLOAD_ARTIFACT_FINGERPRINT ""
STATUS_BEFORE="$(cksum "$MM_STATUS_FILE" | awk '{print $1" "$2}')"
if mm_download_completed; then
  fail "D: post-override mm_download_completed succeeded without fingerprint"
fi
STATUS_AFTER="$(cksum "$MM_STATUS_FILE" | awk '{print $1" "$2}')"
[[ "$STATUS_BEFORE" == "$STATUS_AFTER" ]] \
  || fail "D: public path minted status when fingerprint missing"
[[ -z "$(mm_status_get DOWNLOAD_ARTIFACT_FINGERPRINT)" ]] \
  || fail "D: public path minted DOWNLOAD_ARTIFACT_FINGERPRINT"
pass "D: public entrypoint preserves core fail-closed fingerprint contract"

# --- E. Production Menu 4 never trusts same-stat metadata as byte integrity ---
# This reproduces the exact audit case: mutate one byte in place, then restore
# the original nanosecond mtime so dev/inode/size/mtime fingerprint is unchanged.
# Readiness must still perform the cryptographic SHA256 and fail closed.
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/dp-phase2-common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_install_engine.sh"
BUNDLE="${TMP}/same-stat-bundle"
SIDECAR="${BUNDLE}.sha256"
printf '0123456789abcdef\n' >"$BUNDLE"
sha256sum "$BUNDLE" | awk '{print $1"  same-stat-bundle"}' >"$SIDECAR"
FP_BEFORE="$(mm_file_fingerprint "$BUNDLE")"
python3 - "$BUNDLE" <<'PY'
import os, sys
p=sys.argv[1]
st=os.stat(p)
with open(p, 'r+b') as f:
    b=f.read(1)
    f.seek(0)
    f.write(b'X' if b != b'X' else b'Y')
os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
PY
FP_AFTER="$(mm_file_fingerprint "$BUNDLE")"
[[ "$FP_BEFORE" == "$FP_AFTER" ]] || fail "E: same-stat reproduction did not preserve fingerprint"

MM_HERMETIC_TEST_MODE=0
MM_SKIP_HTTP_VALIDATE=0
MM_SKIP_BUNDLE_SHA256=1
TARGET_DP_VERSION=6.6.0
PHASE2_TARGET_VERSION=6.6.0
mm_http_distribution_enabled() { return 0; }
mm_download_completed() { return 0; }
mm_wf_get() {
  [[ "$1" == "HTTP_PUBLICATION_GENERATION_ID" ]] && printf 'gen-same-stat\n'
}
engine_validate_http_layout() {
  [[ "${MM_SKIP_BUNDLE_SHA256:-0}" != "1" ]] || return 88
  ( cd "$(dirname "$BUNDLE")" && sha256sum -c "$(basename "$SIDECAR")" >/dev/null 2>&1 )
}
set +e
SAME_STAT_OUT="$(engine_validate_upgrade_readiness_live 2>&1)"
SAME_STAT_RC=$?
set -e
[[ "$SAME_STAT_RC" -ne 0 ]] || fail "E: same-stat corrupted bundle incorrectly reached readiness PASS"
printf '%s\n' "$SAME_STAT_OUT" | grep -q 'READINESS_BUNDLE_SHA256_MODE=FULL_HASH_CRYPTOGRAPHIC_REVALIDATION' \
  || fail "E: production readiness did not force full cryptographic hash"
pass "E: same-stat bundle corruption is cryptographically revalidated and rejected"

echo "ALL test_download_fingerprint_fail_closed checks passed"
