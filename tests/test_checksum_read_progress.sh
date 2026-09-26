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

# Two-stage pipeline counts the same bytes in tar and sha256sum. Progress
# must not sum those readers or sit at 99.9% while the checksum is still early.
SLOW="${TMP}/slow-sha256sum"
cat >"$SLOW" <<'EOF'
#!/usr/bin/env bash
sleep 2.4
exec /usr/bin/sha256sum
EOF
chmod +x "$SLOW"
dd if=/dev/zero of="${TMP}/pipe-member" bs=1M count=2 status=none
tar -C "$TMP" -cf "${TMP}/pipe-bundle.tar" pipe-member
bash -c 'tar -xOf "$1" "$2" | "$3"' _ "${TMP}/pipe-bundle.tar" pipe-member "$SLOW" >/dev/null &
PIPE_PID=$!
sleep 0.4
if _mm_checksum_authoritative_rchar "$PIPE_PID" >/dev/null; then
  kill "$PIPE_PID" 2>/dev/null || true
  wait "$PIPE_PID" 2>/dev/null || true
  fail "pipeline rchar was accepted as one checksum stream"
fi
wait "$PIPE_PID" || fail "pipeline reader command failed"
export MM_LONG_STEP_HEARTBEAT_SEC=1
export MM_CHECKSUM_PROGRESS_TOTAL_BYTES="$(stat -c%s "${TMP}/pipe-bundle.tar")"
export MM_CHECKSUM_PROGRESS_FILE="pipe-member"
LOGP="${TMP}/pipe.log"
mm_bg_with_heartbeat CHECKSUM_PIPE_TEST "file=pipe-member" \
  "Still verifying inner images SHA256..." -- \
  bash -c 'tar -xOf "$1" "$2" | "$3"' _ "${TMP}/pipe-bundle.tar" pipe-member "$SLOW" \
  >"$LOGP" 2>&1 || fail "pipeline heartbeat command failed"
if grep -q 'CHECKSUM_PIPE_TEST_PROGRESS ' "$LOGP"; then
  fail "pipeline emitted byte progress"
fi
grep -q 'CHECKSUM_PIPE_TEST_HEARTBEAT ' "$LOGP" || fail "pipeline heartbeat missing"
if grep -Eq 'percent=99\.9|Percent  : 99\.9%' "$LOGP"; then
  fail "pipeline reported 99.9% before completion"
fi
unset MM_CHECKSUM_PROGRESS_TOTAL_BYTES MM_CHECKSUM_PROGRESS_FILE \
  MM_CHECKSUM_RCHAR_BASE MM_CHECKSUM_PROGRESS_LAST_LINE
pass "pipeline checksum falls back to heartbeat"

# Verifier hashes the bytes it will extract. An earlier external digest of
# replaced bytes must not be accepted.
PY="${ROOT}/scripts/lib/os_core_package.py"
MUT="${TMP}/mutate.bin"
printf 'before-replace\n' >"$MUT"
MUT_OLD="$(/usr/bin/sha256sum "$MUT" | awk '{print $1}')"
printf '%s  mutate.bin\n' "$MUT_OLD" >"${MUT}.sha256"
printf 'after-replace\n' >"$MUT"
python3 "$PY" verify --package "$MUT" >"${TMP}/mut.out" 2>"${TMP}/mut.err" || true
if grep -q '^OUTER_SHA256=PASS$' "${TMP}/mut.out"; then
  fail "verify accepted a package that no longer matches its sidecar"
fi
grep -q 'OUTER_SHA256_FAIL' "${TMP}/mut.err" || fail "replaced package was not rejected"
if python3 "$PY" verify --help 2>&1 | grep -q recorded-outer-sha256; then
  fail "verify still accepts a caller-supplied digest"
fi
pass "verify hashes the current package bytes"

# shellcheck source=../scripts/lib/mirror_install_engine.sh
source "${ROOT}/scripts/lib/mirror_install_engine.sh"
# The fail-closed case above replaced the sidecar. Restore it for the pin.
HASH="$(/usr/bin/sha256sum "$DATA" | awk '{print $1}')"
printf '%s  payload.bin\n' "$HASH" >"${DATA}.sha256"
export MM_HERMETIC_TEST_MODE=1
export OS_CORE_TEST_EXPECTED_SHA256="$HASH"
export OS_CORE_TEST_EXPECTED_BYTES="$(stat -c%s "$DATA")"
LOGI="${TMP}/identity.log"
mm_assert_os_core_production_identity "$DATA" "http://hermetic.example/os-core-fixture.tar" \
  >"$LOGI" 2>&1 || fail "production identity failed: $(cat "$LOGI")"
grep -q 'OS_CORE_PRODUCTION_IDENTITY=PASS' "$LOGI" || fail "identity PASS missing"
if [[ -r /proc/self/io ]]; then
  grep -q 'OS_CORE_PRODUCTION_IDENTITY_PROGRESS ' "$LOGI" || fail "identity progress missing"
fi
no_hundred "$LOGI"
pass "production identity hash shows progress"
unset OS_CORE_TEST_EXPECTED_SHA256 OS_CORE_TEST_EXPECTED_BYTES MM_HERMETIC_TEST_MODE

mm_assert_os_core_production_identity() { return 0; }
unset R2_OS_CORE_PUBLISHER_PUBLIC_KEY || true
cat >"${WRAP}/python3" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "$PY" && "\${2:-}" == verify ]]; then
  joined="\$*"
  case "\$joined" in
    *--recorded-outer-sha256*) echo "recorded digest bypass" >&2; exit 4 ;;
  esac
  [[ -n "\${MM_CHECKSUM_PROGRESS_TOTAL_BYTES:-}" ]] || { echo "progress total unset" >&2; exit 3; }
  [[ -n "\${MM_CHECKSUM_PROGRESS_DONE_FILE:-}" ]] || { echo "done file unset" >&2; exit 3; }
  sleep 1.2
  : >"\${MM_CHECKSUM_PROGRESS_DONE_FILE}"
  sleep 2.2
  printf '%s\n' OUTER_SHA256=PASS OS_CORE_VERIFY=PASS RELEASE_ID=oscore-progress PAYLOAD_BYTES=1
  exit 0
fi
exec /usr/bin/python3 "\$@"
EOF
chmod +x "${WRAP}/python3"
hash -r
LOGC="${TMP}/os-core-progress.log"
if ! (
  engine_verify_os_core_package "$DATA"
) >"$LOGC" 2>&1; then
  cat "$LOGC" >&2
  fail "os core verify failed"
fi
grep -q 'OS_CORE_SHA256_VERIFY_START .*phase=outer-sha256' "$LOGC" || fail "outer SHA start missing"
grep -q 'OS_CORE_SHA256_VERIFY_HEARTBEAT ' "$LOGC" || fail "post-hash heartbeat missing"
grep -q 'VERIFY_OS_CORE=PASS' "$LOGC" || fail "VERIFY_OS_CORE=PASS missing"
if [[ -r /proc/self/io ]]; then
  grep -q 'OS_CORE_SHA256_VERIFY_PROGRESS ' "$LOGC" || fail "outer SHA progress missing"
fi
if grep -Eq 'percent=99\.9|Percent  : 99\.9%' "$LOGC"; then
  fail "os core verify reported 99.9% before completion"
fi
no_hundred "$LOGC"
pass "os core outer SHA progress then contents heartbeat"

# bash -c 'sha256sum | awk' must not report 0% from the wrapper while the
# descendant reader has the file open.
cat >"${WRAP}/sha256sum" <<'EOF'
#!/usr/bin/env python3
import hashlib, sys, time
h = hashlib.sha256()
with open(sys.argv[1], "rb") as fh:
    while True:
        chunk = fh.read(1024 * 1024)
        if not chunk:
            break
        h.update(chunk)
        time.sleep(0.8)
print(h.hexdigest())
EOF
chmod +x "${WRAP}/sha256sum"
LOGB="${TMP}/bash-c-sha.log"
dp2_run_with_heartbeat phase2_bash_c_sha256 "$DATA" -- \
  bash -c 'actual=$(sha256sum "$1" | awk "{print \$1}"); printf "%s\n" "$actual"' \
  _ "$DATA" >"$LOGB" 2>&1 || fail "bash -c sha256 failed: $(tail -20 "$LOGB")"
if [[ -r /proc/self/io ]]; then
  grep -q 'read_bytes=' "$LOGB" || fail "bash -c progress missing read_bytes"
  if ! awk '
    /read_bytes=/ {
      for (i = 1; i <= NF; i++) if ($i ~ /^read_bytes=/) {
        split($i, a, "=")
        if (a[2] + 0 > 0) ok = 1
      }
    }
    END { exit ok ? 0 : 1 }
  ' "$LOGB"; then
    fail "bash -c stayed at 0 bytes while sha256sum was reading"
  fi
  no_hundred "$LOGB"
fi
pass "bash -c checksum tracks the reader"

echo "TEST_CHECKSUM_READ_PROGRESS=PASS"
