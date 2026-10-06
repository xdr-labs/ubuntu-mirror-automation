#!/usr/bin/env bash
# Regression: a live detached Phase 2 worker must publish canonical identity
# before handoff/monitoring, even when worker-side readiness is slow.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
WORKER_PID=""
STALE_PID=""
cleanup() {
  if [[ -n "${WORKER_PID:-}" ]]; then
    kill "$WORKER_PID" 2>/dev/null || true
  fi
  if [[ -n "${STALE_PID:-}" ]]; then
    kill "$STALE_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

RUNTIME="$TMP/runtime"
LIFECYCLE="$TMP/lifecycle"
LOG="$TMP/bringup.log"
GATE_STARTED="$TMP/worker-gate-started"
GATE_DONE="$TMP/worker-gate-done"
VENDOR_ARGS="$TMP/vendor.args"
OUT="$TMP/wrapper.out"
mkdir -p "$RUNTIME/lib" "$LIFECYCLE"

cp "$ROOT/client/bringup_py3_dp_lifecycle.sh" "$RUNTIME/bringup_py3_dp_lifecycle.sh"
cp "$ROOT/client/lib/dp-phase2-bringup-lifecycle.sh" "$RUNTIME/lib/dp-phase2-bringup-lifecycle.sh"
chmod +x "$RUNTIME/bringup_py3_dp_lifecycle.sh"

cat >"$RUNTIME/lib/dp-phase2-time-readiness.sh" <<'EOF'
dp_phase2_load_time_ref_url() { return 0; }
dp_phase2_bringup_time_gate() {
  TIME_READINESS=PASS_SYNCED
  BRINGUP_READY=YES
  if [[ "${WORKER_MODE:-0}" == "1" ]]; then
    : >"$TEST_GATE_STARTED"
    sleep 3
    : >"$TEST_GATE_DONE"
  fi
  printf '%s\n' "BRINGUP_TIME_GATE=PASS TIME_READINESS=${TIME_READINESS}"
  return 0
}
EOF

cat >"$RUNTIME/lib/dp-phase2-staging-contract.sh" <<'EOF'
dp_phase2_bringup_staging_gate() { return 0; }
EOF

cat >"$RUNTIME/bringup_py3_dp_after_os_upgrade.vendor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$TEST_VENDOR_ARGS"
echo "APT_DEPENDENCY_CHECK=PASS"
exit 0
EOF
chmod +x "$RUNTIME/bringup_py3_dp_after_os_upgrade.vendor.sh"

export TEST_GATE_STARTED="$GATE_STARTED"
export TEST_GATE_DONE="$GATE_DONE"
export TEST_VENDOR_ARGS="$VENDOR_ARGS"
export PHASE2_BRINGUP_DIR="$LIFECYCLE"
export PHASE2_BRINGUP_LOG_DEFAULT="$LOG"
export PHASE2_BRINGUP_MONITOR_SECONDS=1
export PHASE2_BRINGUP_ALLOW_NONROOT=1

set +e
bash "$RUNTIME/bringup_py3_dp_lifecycle.sh" \
  --version 6.6.0 --skip-download --detach >"$OUT" 2>&1
RC=$?
set -e
[[ "$RC" -eq 0 ]] || { cat "$OUT"; fail "detached start rc=$RC"; }
grep -q '^BRINGUP_HANDOFF=PASS$' "$OUT" || { cat "$OUT"; fail "missing handoff PASS"; }

[[ -s "$LIFECYCLE/worker.pid" ]] || fail "worker.pid was not published before handoff"
[[ -s "$LIFECYCLE/worker-start-ticks" ]] || fail "worker-start-ticks was not published before handoff"
WORKER_PID="$(tr -d '\r\n' <"$LIFECYCLE/worker.pid")"
[[ "$WORKER_PID" =~ ^[0-9]+$ ]] || fail "invalid worker pid: $WORKER_PID"
[[ -d "/proc/$WORKER_PID" ]] || fail "published worker pid is not alive at handoff"

RECORDED_TICKS="$(tr -d '\r\n' <"$LIFECYCLE/worker-start-ticks")"
PROC_TICKS="$(awk '{print $22}' "/proc/$WORKER_PID/stat")"
[[ "$RECORDED_TICKS" == "$PROC_TICKS" ]] \
  || fail "start-tick mismatch recorded=$RECORDED_TICKS proc=$PROC_TICKS"

[[ -f "$GATE_STARTED" ]] || fail "worker-side slow gate did not start"
[[ ! -f "$GATE_DONE" ]] || fail "handoff waited for the slow worker gate instead of identity publication"

# This is the exact production failure surface: while worker-side readiness is
# still blocked, the authoritative lifecycle snapshot must see the published
# worker as live and identity-matched rather than STALE_OR_UNKNOWN.
source "$ROOT/client/lib/dp-phase2-bringup-lifecycle.sh"
p2b_status_snapshot
[[ "$BRINGUP_STATE" == "STARTING" ]] \
  || fail "live slow-gate worker state=$BRINGUP_STATE expected STARTING"
[[ "$BRINGUP_WORKER_ALIVE" == "YES" ]] \
  || fail "live slow-gate worker was not detected alive"
[[ "$BRINGUP_PROCESS_IDENTITY_MATCH" == "YES" ]] \
  || fail "live slow-gate worker identity did not match"
pass "slow readiness snapshot stays STARTING with live matching worker"

mapfile -d '' -t WORKER_ARGV <"/proc/$WORKER_PID/cmdline"
WORKER_VERSION_FLAGS=0
for arg in "${WORKER_ARGV[@]}"; do
  [[ "$arg" == "--version" ]] && WORKER_VERSION_FLAGS=$((WORKER_VERSION_FLAGS + 1))
done
[[ "$WORKER_VERSION_FLAGS" -eq 1 ]] \
  || fail "worker argv contains $WORKER_VERSION_FLAGS --version flags"
pass "handoff publishes a coherent live identity before slow worker readiness completes"

# Publication ordering contract: worker.pid is the commit marker. If publication
# is interrupted, observers may see start ticks without a PID, but never a PID
# without its identity anchor.
ORDER_DIR="$TMP/identity-order"
ORDER_LOG="$TMP/identity-order.log"
mkdir -p "$ORDER_DIR"
: >"$ORDER_LOG"
(
  export PHASE2_BRINGUP_DIR="$ORDER_DIR"
  p2b_atomic_write() {
    local dest="$1"
    printf '%s\n' "$(basename "$dest")" >>"$ORDER_LOG"
    cat >"$dest"
  }
  p2b_publish_worker_identity "$BASHPID"
)
mapfile -t IDENTITY_WRITE_ORDER <"$ORDER_LOG"
[[ "${#IDENTITY_WRITE_ORDER[@]}" -eq 2 ]] \
  || fail "identity publication write count=${#IDENTITY_WRITE_ORDER[@]}"
[[ "${IDENTITY_WRITE_ORDER[0]}" == "worker-start-ticks" ]] \
  || fail "identity anchor was not published first"
[[ "${IDENTITY_WRITE_ORDER[1]}" == "worker.pid" ]] \
  || fail "worker.pid was not the publication commit marker"
pass "worker.pid is published last as the identity commit marker"

# STARTING without an identity is pre-handoff, not evidence of a stale worker.
PRE="$TMP/pre-handoff"
export PHASE2_BRINGUP_DIR="$PRE"
mkdir -p "$PRE"
printf '%s\n' STARTING >"$PRE/state"
printf '%s\n' pre-handoff-run >"$PRE/run-id"
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PRE/started-at"
printf '%s\n' "$LOG" >"$PRE/log-path"
p2b_status_snapshot
[[ "$BRINGUP_STATE" == "STARTING" ]] \
  || fail "pre-handoff STARTING without pid became $BRINGUP_STATE"
pass "pre-handoff STARTING state does not false-fail as stale"

# Restore the real lifecycle path and wait for the worker to finish.
export PHASE2_BRINGUP_DIR="$LIFECYCLE"
for _ in $(seq 1 100); do
  STATE="$(tr -d '\r\n' <"$LIFECYCLE/state" 2>/dev/null || true)"
  [[ "$STATE" == "COMPLETED" || "$STATE" == "FAILED" ]] && break
  sleep 0.1
done
STATE="$(tr -d '\r\n' <"$LIFECYCLE/state" 2>/dev/null || true)"
[[ "$STATE" == "COMPLETED" ]] || {
  cat "$OUT"
  tail -n 100 "$LOG" 2>/dev/null || true
  fail "worker terminal state=$STATE"
}

[[ -f "$VENDOR_ARGS" ]] || fail "vendor argv was not captured"
VERSION_FLAGS="$(grep -cx -- '--version' "$VENDOR_ARGS" || true)"
[[ "$VERSION_FLAGS" -eq 1 ]] || {
  cat "$VENDOR_ARGS"
  fail "vendor received $VERSION_FLAGS --version flags"
}
awk '
  $0 == "--version" {
    if (getline v <= 0 || v != "6.6.0") exit 1
    found=1
  }
  END { exit found ? 0 : 1 }
' "$VENDOR_ARGS" || { cat "$VENDOR_ARGS"; fail "vendor target version forwarding is incorrect"; }
pass "worker and vendor each receive exactly one target --version"

# A stale lifecycle record whose PID is still alive must fail closed rather than
# starting a second bringup. Identity mismatch may mean metadata damage, not a
# dead worker, so retry is unsafe until the live process is resolved.
STALE_DIR="$TMP/stale-live"
STALE_LOG="$TMP/stale-live.log"
mkdir -p "$STALE_DIR"
bash -c 'exec -a bringup-stale-worker sleep 30' &
STALE_PID=$!
printf '%s\n' RUNNING >"$STALE_DIR/state"
printf '%s\n' stale-live-run >"$STALE_DIR/run-id"
printf '%s\n' "$STALE_PID" >"$STALE_DIR/worker.pid"
printf '%s\n' 1 >"$STALE_DIR/worker-start-ticks"
printf '%s\n' 6.6.0 >"$STALE_DIR/target-version"
printf '%s\n' "$STALE_LOG" >"$STALE_DIR/log-path"
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$STALE_DIR/started-at"
STALE_BEFORE_RUN_ID="$(cat "$STALE_DIR/run-id")"
set +e
PHASE2_BRINGUP_DIR="$STALE_DIR" PHASE2_BRINGUP_LOG_DEFAULT="$STALE_LOG" \
  bash "$RUNTIME/bringup_py3_dp_lifecycle.sh" \
    --version 6.6.0 --skip-download --detach >"$TMP/stale-live.out" 2>&1
STALE_RC=$?
set -e
[[ "$STALE_RC" -ne 0 ]] || { cat "$TMP/stale-live.out"; fail "live stale worker retry unexpectedly succeeded"; }
grep -q '^BRINGUP_RETRY_BLOCKED=YES$' "$TMP/stale-live.out" \
  || { cat "$TMP/stale-live.out"; fail "live stale worker retry was not explicitly blocked"; }
grep -q '^ACTION=BLOCK_LIVE_STALE_WORKER$' "$TMP/stale-live.out" \
  || fail "live stale worker block action missing"
grep -q '^BRINGUP_WORKER_ALIVE=YES$' "$TMP/stale-live.out" \
  || fail "live stale worker evidence missing"
grep -q '^BRINGUP_PROCESS_IDENTITY_MATCH=NO$' "$TMP/stale-live.out" \
  || fail "identity mismatch evidence missing"
[[ "$(cat "$STALE_DIR/run-id")" == "$STALE_BEFORE_RUN_ID" ]] \
  || fail "blocked retry overwrote stale run-id"
[[ "$(cat "$STALE_DIR/worker.pid")" == "$STALE_PID" ]] \
  || fail "blocked retry replaced stale live worker pid"
kill -0 "$STALE_PID" 2>/dev/null || fail "blocked retry killed the ambiguous live worker"
kill "$STALE_PID" 2>/dev/null || true
wait "$STALE_PID" 2>/dev/null || true
STALE_PID=""
pass "live stale identity mismatch blocks duplicate bringup launch"

# Once the ambiguous PID is actually gone, the same stale lifecycle may use the
# existing retry path. This guards against over-correcting the live-process block.
set +e
PHASE2_BRINGUP_DIR="$STALE_DIR" PHASE2_BRINGUP_LOG_DEFAULT="$STALE_LOG" \
  bash "$RUNTIME/bringup_py3_dp_lifecycle.sh" \
    --version 6.6.0 --skip-download --detach >"$TMP/stale-dead-retry.out" 2>&1
STALE_DEAD_RC=$?
set -e
[[ "$STALE_DEAD_RC" -eq 0 ]] \
  || { cat "$TMP/stale-dead-retry.out"; fail "dead stale worker retry did not proceed"; }
grep -q '^BRINGUP_HANDOFF=PASS$' "$TMP/stale-dead-retry.out" \
  || { cat "$TMP/stale-dead-retry.out"; fail "dead stale worker retry missing handoff"; }
STALE_PID="$(cat "$STALE_DIR/worker.pid")"
[[ "$STALE_PID" =~ ^[0-9]+$ ]] || fail "dead stale retry missing replacement pid"
kill -0 "$STALE_PID" 2>/dev/null || fail "dead stale retry replacement worker not alive"
kill "$STALE_PID" 2>/dev/null || true
wait "$STALE_PID" 2>/dev/null || true
STALE_PID=""
pass "dead stale lifecycle still permits a new verified handoff"

echo "TEST_PHASE2_DETACHED_HANDOFF_IDENTITY=PASS"
