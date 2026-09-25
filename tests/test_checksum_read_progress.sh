#!/usr/bin/env bash
# Checksum read progress: normal, missing counters, failure, fast exit, exit race.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
DP2="${ROOT}/scripts/lib/dp-phase2-common.sh"
PHASE2_PROGRESS="${ROOT}/client/lib/dp-phase2-operation-progress.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_SKIP_ROOT_CHECK=1
export MM_PROJECT_ROOT="$ROOT"
export MM_MIRROR_ROOT="${TMP}/mirror"
export MM_CACHE_ROOT="${TMP}/mirror/.install-cache"
export MM_SELECTIVE_ROOT="${TMP}/mirror/selective"
export MM_DP_PHASE2_ROOT="${TMP}/mirror/dp-phase2"
export MM_STATE_ROOT="${TMP}/state"
export MM_STATE_DIR="${TMP}/state"
export MM_CONFIG_DIR="${TMP}/config"
export MM_STATUS_FILE="${TMP}/config/status"
export MM_LOG_FILE=""
export MM_LONG_STEP_HEARTBEAT_SEC=1
mkdir -p "$MM_CACHE_ROOT" "$MM_SELECTIVE_ROOT" "$MM_DP_PHASE2_ROOT" "$MM_STATE_DIR" "$MM_CONFIG_DIR"
: >"$MM_STATUS_FILE"

# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "$COMMON"
# shellcheck source=../scripts/lib/dp-phase2-common.sh
source "$DP2"
# shellcheck source=../client/lib/dp-phase2-operation-progress.sh
source "$PHASE2_PROGRESS"

no_hundred() {
  local file="$1"
  if grep -Eq 'percent=100([^0-9.]|$)|Percent  : 100%' "$file"; then
    fail "misleading 100% in $file"
  fi
}

# --- normal progress ---
DATA="${TMP}/payload.bin"
dd if=/dev/zero of="$DATA" bs=1M count=4 status=none
HASH="$(sha256sum "$DATA" | awk '{print $1}')"
printf '%s  payload.bin\n' "$HASH" >"${DATA}.sha256"
WRAP="${TMP}/bin"
mkdir -p "$WRAP"
cat >"${WRAP}/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -f "${1:-}" ]]; then
  sz="$(stat -c%s "$1" 2>/dev/null || echo 0)"
  if [[ "$sz" -ge 1048576 ]]; then
    sleep 2.4
  fi
fi
exec /usr/bin/sha256sum "$@"
EOF
chmod +x "${WRAP}/sha256sum"
export PATH="${WRAP}:${PATH}"

LOG="${TMP}/normal.log"
mm_verify_sha256_pair_logged "$DATA" "${DATA}.sha256" "CHECKSUM_PROGRESS_TEST" \
  "Still verifying..." >"$LOG" 2>&1 || fail "normal verify failed"
grep -q 'CHECKSUM_PROGRESS_TEST_COMPLETE .*result=PASS' "$LOG" || fail "normal PASS missing"
if [[ -r /proc/self/io ]]; then
  grep -q 'CHECKSUM_PROGRESS_TEST_PROGRESS ' "$LOG" || fail "normal PROGRESS missing"
  grep -q 'read_bytes=' "$LOG" || fail "read_bytes missing"
  grep -q 'rate_mib_s=' "$LOG" || fail "rate missing"
  grep -q 'eta=' "$LOG" || fail "eta missing"
  grep -q 'Progress :' "$LOG" || fail "human progress missing"
  grep -q 'ETA is approximate' "$LOG" || fail "ETA caveat missing"
  no_hundred "$LOG"
fi
pass "normal progress"

# --- counters unavailable: heartbeat fallback ---
export MM_CHECKSUM_PROGRESS_IO_ROOT="${TMP}/no-proc-io"
LOG2="${TMP}/fallback.log"
mm_verify_sha256_pair_logged "$DATA" "${DATA}.sha256" "CHECKSUM_FALLBACK_TEST" \
  "Still verifying..." >"$LOG2" 2>&1 || fail "fallback verify failed"
grep -q 'CHECKSUM_FALLBACK_TEST_HEARTBEAT ' "$LOG2" || fail "heartbeat fallback missing"
if grep -q 'CHECKSUM_FALLBACK_TEST_PROGRESS ' "$LOG2"; then
  fail "progress emitted without counters"
fi
grep -q 'CHECKSUM_FALLBACK_TEST_COMPLETE .*result=PASS' "$LOG2" || fail "fallback PASS missing"
unset MM_CHECKSUM_PROGRESS_IO_ROOT
pass "missing counters fall back to heartbeat"

# --- checksum failure stays fail-closed and is not 100% success ---
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  payload.bin\n' \
  >"${DATA}.sha256"
LOG3="${TMP}/fail.log"
set +e
mm_verify_sha256_pair_logged "$DATA" "${DATA}.sha256" "CHECKSUM_FAIL_TEST" \
  "Still verifying..." >"$LOG3" 2>&1
FAIL_RC=$?
set -e
[[ "$FAIL_RC" -ne 0 ]] || fail "mismatch returned success"
if grep -q 'CHECKSUM_FAIL_TEST_COMPLETE .*result=PASS' "$LOG3"; then
  fail "mismatch reported PASS"
fi
grep -q 'result=FAIL' "$LOG3" || fail "mismatch missing FAIL"
no_hundred "$LOG3"
pass "checksum failure stays fail-closed"

# --- fast exit: no fabricated 100%, PASS only after success ---
SMALL="${TMP}/small.bin"
printf 'fast\n' >"$SMALL"
SMALL_HASH="$(/usr/bin/sha256sum "$SMALL" | awk '{print $1}')"
printf '%s  small.bin\n' "$SMALL_HASH" >"${SMALL}.sha256"
export MM_LONG_STEP_HEARTBEAT_SEC=30
LOG4="${TMP}/fast.log"
mm_verify_sha256_pair_logged "$SMALL" "${SMALL}.sha256" "CHECKSUM_FAST_TEST" \
  "Still verifying..." >"$LOG4" 2>&1 || fail "fast verify failed"
grep -q 'CHECKSUM_FAST_TEST_COMPLETE .*result=PASS' "$LOG4" || fail "fast PASS missing"
no_hundred "$LOG4"
pass "fast exit does not report 100%"

# --- process-exit race: reading a dead pid must not fail the checksum ---
sleep 0.1 &
DEAD=$!
wait "$DEAD" || true
if _mm_proc_rchar "$DEAD"; then
  fail "dead pid rchar unexpectedly succeeded"
fi
export MM_LONG_STEP_HEARTBEAT_SEC=1
LOG5="${TMP}/race.log"
# Command exits during the first sample window.
mm_verify_sha256_pair_logged "$SMALL" "${SMALL}.sha256" "CHECKSUM_RACE_TEST" \
  "Still verifying..." >"$LOG5" 2>&1 || fail "exit-race verify failed"
grep -q 'CHECKSUM_RACE_TEST_COMPLETE .*result=PASS' "$LOG5" || fail "exit-race PASS missing"
no_hundred "$LOG5"
pass "process-exit race does not fail the checksum"

# Phase 2 client heartbeat keeps the liveness line and adds read fields for sha256.
export DP_PHASE2_HEARTBEAT_SECONDS=1
LOG6="${TMP}/dp2.log"
dp2_run_with_heartbeat phase2_existing_bundle_sha256 "$DATA" -- \
  "${WRAP}/sha256sum" "$DATA" >"$LOG6" 2>&1 || fail "dp2 sha256 failed"
grep -q 'OPERATION_END name=phase2_existing_bundle_sha256 rc=0 ' "$LOG6" \
  || fail "dp2 end missing"
if [[ -r /proc/self/io ]]; then
  grep -q 'read_bytes=' "$LOG6" || fail "dp2 read_bytes missing"
  grep -q 'status=running' "$LOG6" || fail "dp2 status missing"
  no_hundred "$LOG6"
fi
pass "phase2 client checksum progress"

echo "TEST_CHECKSUM_READ_PROGRESS=PASS"
