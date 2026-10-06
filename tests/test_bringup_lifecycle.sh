#!/usr/bin/env bash
# Targeted lifecycle state tests: current-run completion, safe monitoring, read-only status.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/client/lib/dp-phase2-bringup-lifecycle.sh"
TMP="$(mktemp -d)"
trap '[[ -n "${WORKER_PID:-}" ]] && kill "$WORKER_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
write_file() { printf '%s\n' "$2" >"$1"; }
run_id="current-run"

export PHASE2_BRINGUP_DIR="${TMP}/lifecycle"
export PHASE2_BRINGUP_LOG_DEFAULT="${TMP}/bringup.log"
export PHASE2_BRINGUP_MONITOR_SECONDS=1
# shellcheck source=/dev/null
source "$LIB"

echo "=== test_bringup_lifecycle ==="

cat >"$PHASE2_BRINGUP_LOG_DEFAULT" <<'EOF'
Bringup complete: run this command when installation completes
Note: run this only after the Bringup complete: line is printed
EOF
if p2b_log_has_anchored_completion "$PHASE2_BRINGUP_LOG_DEFAULT"; then
  fail "instructional completion text was accepted"
fi
pass "instructional text is not completion"

# A production-like active worker and IMAGE_IMPORT records remain RUNNING; CLI
# discovery is deliberately deferred during an active run.
p2b_ensure_dir
bash -c 'exec -a bringup-worker sleep 30' &
WORKER_PID=$!
write_file "$(p2b_dir)/state" RUNNING
write_file "$(p2b_dir)/run-id" "$run_id"
write_file "$(p2b_dir)/worker.pid" "$WORKER_PID"
write_file "$(p2b_dir)/worker-start-ticks" "$(awk '{print $22}' "/proc/${WORKER_PID}/stat")"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
# Persistent vendor log contains an older completed import. The active run must
# ignore all bytes before log-start-offset and require its own run-id marker.
cat >"$PHASE2_BRINGUP_LOG_DEFAULT" <<'EOF'
IMAGE_IMPORT_START namespace=old
IMAGE_IMPORT_PROGRESS namespace=old progress=99%
IMAGE_IMPORT_COMPLETE namespace=old elapsed=00:10:00
Loading images from old run
EOF
write_file "$(p2b_dir)/log-start-offset" "$(wc -c <"$PHASE2_BRINGUP_LOG_DEFAULT" | tr -d ' ')"
{
  echo "PHASE2_LIFECYCLE_RUN_BEGIN run_id=${run_id}"
  echo "IMAGE_IMPORT_START namespace=k8s.io"
  echo "IMAGE_IMPORT_PROGRESS namespace=k8s.io progress=5%"
  echo "IMAGE_IMPORT_PROGRESS namespace=k8s.io progress=53%"
} >>"$PHASE2_BRINGUP_LOG_DEFAULT"
rm -f "$(p2b_dir)/result.env"
p2b_status_snapshot
p2b_print_status >"${TMP}/status.running"
[[ "$BRINGUP_STATE" == RUNNING ]] || fail "running fixture state=${BRINGUP_STATE}"
[[ "$BRINGUP_COMPLETION_SENTINEL" == NOT_PRESENT ]] || fail "unexpected completion sentinel"
[[ "$AELLA_CLI_AVAILABLE" == NOT_CHECKED ]] || fail "CLI was checked while running"
[[ "$IMAGE_IMPORT_PROGRESS" == 53% ]] || fail "image progress=${IMAGE_IMPORT_PROGRESS}"
[[ "$IMAGE_IMPORT_NAMESPACE" == k8s.io ]] || fail "stale namespace leaked: ${IMAGE_IMPORT_NAMESPACE}"
[[ "$IMAGE_IMPORT_STATE" == RUNNING ]] || fail "old COMPLETE leaked into current state: ${IMAGE_IMPORT_STATE}"
[[ "$CURRENT_PHASE" == IMAGE_IMPORT ]] || fail "old phase leaked into current phase: ${CURRENT_PHASE}"
grep -q '^BRINGUP_RESULT=IN_PROGRESS$' "${TMP}/status.running" || fail "missing IN_PROGRESS"
grep -q '^DO_NOT_RUN_AELLA_CLI_YET=YES$' "${TMP}/status.running" || fail "missing DO_NOT_RUN"
pass "running import status is current-run scoped, non-terminal, and read-only"

# Once the import emits COMPLETE, status must no longer claim the current phase
# is still IMAGE_IMPORT while also reporting IMAGE_IMPORT_STATE=DONE.
cat >>"$PHASE2_BRINGUP_LOG_DEFAULT" <<'EOF'
IMAGE_IMPORT_COMPLETE namespace=k8s.io elapsed=00:01:00
EOF
p2b_status_snapshot
[[ "$IMAGE_IMPORT_STATE" == DONE ]] || fail "image import complete state=${IMAGE_IMPORT_STATE}"
[[ "$CURRENT_PHASE" == IMAGE_IMPORT_COMPLETE ]] || fail "image import complete phase=${CURRENT_PHASE}"
[[ "$CURRENT_OPERATION" == image_import_complete ]] || fail "image import complete operation=${CURRENT_OPERATION}"
pass "completed image import has a non-running phase"

# Starting the next namespace resets the progress domain. If its authoritative
# progress is UNKNOWN, do not inherit k8s.io's percentage and do not scrape a
# cpu=NN.N% field as image progress.
cat >>"$PHASE2_BRINGUP_LOG_DEFAULT" <<'EOF'
IMAGE_IMPORT_START namespace=moby
IMAGE_IMPORT_PROGRESS namespace=moby elapsed=00:01:05 process_alive=YES progress=UNKNOWN cpu=37.5%
EOF
p2b_status_snapshot
[[ "$IMAGE_IMPORT_NAMESPACE" == moby ]] || fail "moby namespace=${IMAGE_IMPORT_NAMESPACE}"
[[ -z "$IMAGE_IMPORT_PROGRESS" ]] || fail "UNKNOWN progress fabricated as ${IMAGE_IMPORT_PROGRESS}"
[[ "$IMAGE_IMPORT_STATE" == RUNNING ]] || fail "moby UNKNOWN state=${IMAGE_IMPORT_STATE}"
[[ "$CURRENT_PHASE" == IMAGE_IMPORT ]] || fail "moby UNKNOWN phase=${CURRENT_PHASE}"
pass "namespace switch and UNKNOWN progress do not inherit or fabricate percent"

# An exact sentinel and rc=0 for this run represents completion.
cat >"$(p2b_dir)/result.env" <<EOF
BRINGUP_TERMINAL_STATE=COMPLETED
BRINGUP_RESULT=PASS
BRINGUP_RUN_ID=${run_id}
BRINGUP_EXIT_CODE=0
BRINGUP_COMPLETION_SENTINEL=PASS
EOF
write_file "$(p2b_dir)/state" COMPLETED
p2b_status_snapshot
[[ "$BRINGUP_STATE" == COMPLETED && "$BRINGUP_COMPLETION_SENTINEL" == PASS && "$BRINGUP_EXIT_CODE" == 0 ]] \
  || fail "current exact completion sentinel rejected"
pass "current exact completion sentinel succeeds"

# A prior run's result cannot complete this run.
write_file "$(p2b_dir)/state" RUNNING
write_file "$(p2b_dir)/run-id" new-run
sed -i 's/^BRINGUP_RUN_ID=.*/BRINGUP_RUN_ID=old-run/' "$(p2b_dir)/result.env"
p2b_status_snapshot
[[ "$BRINGUP_COMPLETION_SENTINEL" == NOT_PRESENT ]] || fail "old run sentinel passed current run"
[[ "$IMAGE_IMPORT_STATE" == UNKNOWN ]] || fail "wrong-run log leaked import state=${IMAGE_IMPORT_STATE}"
[[ -z "$IMAGE_IMPORT_PROGRESS" ]] || fail "wrong-run log leaked progress=${IMAGE_IMPORT_PROGRESS}"
[[ "$CURRENT_PHASE" == UNKNOWN ]] || fail "wrong-run log leaked phase=${CURRENT_PHASE}"
pass "old terminal result and wrong-run observability are isolated by run id"

# Dead or mismatched workers cannot masquerade as RUNNING.
write_file "$(p2b_dir)/worker.pid" 999999
p2b_status_snapshot
[[ "$BRINGUP_STATE" == STALE_OR_UNKNOWN ]] || fail "stale PID state=${BRINGUP_STATE}"
if p2b_pid_alive_and_matches "$$" pgrep; then
  fail "diagnostic pgrep self-match accepted as worker"
fi
pass "stale and self-matching worker identities are rejected"

# STARTING without a published identity is allowed only during a finite handoff
# grace. This preserves the real pre-handoff window without allowing an
# abandoned starter record to report IN_PROGRESS forever.
PHASE2_BRINGUP_STARTING_GRACE_SECONDS=5
write_file "$(p2b_dir)/state" STARTING
write_file "$(p2b_dir)/run-id" starting-grace-run
rm -f "$(p2b_dir)/worker.pid" "$(p2b_dir)/worker-start-ticks" "$(p2b_dir)/result.env"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
p2b_status_snapshot
[[ "$BRINGUP_STATE" == STARTING ]] || fail "fresh no-pid STARTING state=$BRINGUP_STATE"
[[ "$BRINGUP_WORKER_ALIVE" == NO ]] || fail "fresh no-pid STARTING unexpectedly alive"
pass "fresh no-pid STARTING remains in handoff grace"

write_file "$(p2b_dir)/started-at" "$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)"
p2b_status_snapshot
[[ "$BRINGUP_STATE" == STALE_OR_UNKNOWN ]] \
  || fail "aged no-pid STARTING state=$BRINGUP_STATE"
pass "aged no-pid STARTING fails closed as stale"

rm -f "$(p2b_dir)/started-at"
p2b_status_snapshot
[[ "$BRINGUP_STATE" == STALE_OR_UNKNOWN ]] \
  || fail "missing-time no-pid STARTING state=$BRINGUP_STATE"
write_file "$(p2b_dir)/started-at" not-a-time
p2b_status_snapshot
[[ "$BRINGUP_STATE" == STALE_OR_UNKNOWN ]] \
  || fail "invalid-time no-pid STARTING state=$BRINGUP_STATE"
pass "unverifiable no-pid STARTING fails closed as stale"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# If the PID is alive but belongs to a different process identity, diagnostics
# must not lie that the worker is GONE. This was visible in the original AWS
# incident and is important for operator recovery decisions.
bash -c 'exec -a unrelated-worker sleep 30' &
MISMATCH_PID=$!
write_file "$(p2b_dir)/state" RUNNING
write_file "$(p2b_dir)/run-id" mismatch-live-run
write_file "$(p2b_dir)/worker.pid" "$MISMATCH_PID"
write_file "$(p2b_dir)/worker-start-ticks" "$(awk '{print $22}' "/proc/${MISMATCH_PID}/stat")"
rm -f "$(p2b_dir)/result.env"
set +e
p2b_monitor_loop mismatch-live-run >"${TMP}/monitor.mismatch" 2>&1
MISMATCH_RC=$?
set -e
kill "$MISMATCH_PID" 2>/dev/null || true
wait "$MISMATCH_PID" 2>/dev/null || true
[[ "$MISMATCH_RC" -ne 0 ]] || fail "live identity mismatch unexpectedly passed"
grep -q 'worker=ALIVE_IDENTITY_MISMATCH' "${TMP}/monitor.mismatch" \
  || fail "live identity mismatch was reported as worker gone"
grep -q '^BRINGUP_WORKER_ALIVE=YES$' "${TMP}/monitor.mismatch" \
  || fail "live identity mismatch missing alive evidence"
grep -q '^BRINGUP_PROCESS_IDENTITY_MATCH=NO$' "${TMP}/monitor.mismatch" \
  || fail "live identity mismatch missing identity evidence"
pass "live identity mismatch is reported accurately instead of worker GONE"

# CLI absence is not failure while running, but is a terminal postcondition after
# a genuine completed result.  Override discovery to avoid host package state.
write_file "$(p2b_dir)/state" COMPLETED
write_file "$(p2b_dir)/run-id" completed-run
cat >"$(p2b_dir)/result.env" <<'EOF'
BRINGUP_TERMINAL_STATE=COMPLETED
BRINGUP_RESULT=PASS
BRINGUP_RUN_ID=completed-run
BRINGUP_EXIT_CODE=0
BRINGUP_COMPLETION_SENTINEL=PASS
EOF
p2b_discover_aella_cli() { AELLA_CLI_AVAILABLE=NO; AELLA_CLI_PATH=""; return 1; }
set +e
p2b_monitor_loop completed-run >"${TMP}/monitor.out" 2>&1
MONITOR_RC=$?
set -e
[[ "$MONITOR_RC" -ne 0 ]] || fail "missing post-completion CLI passed"
grep -q '^BRINGUP_RESULT=FAIL_POSTCONDITION$' "${TMP}/monitor.out" || fail "postcondition failure missing"
grep -q '^BRINGUP_STATE=FAILED$' "${TMP}/monitor.out" || fail "postcondition state missing"
pass "missing CLI is only terminal failure after completion"

# Status/diagnose snapshot has no lifecycle mutation.
before="$(tar -cf - -C "$(p2b_dir)" . | sha256sum | awk '{print $1}')"
p2b_print_status >/dev/null
after="$(tar -cf - -C "$(p2b_dir)" . | sha256sum | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail "status snapshot mutated lifecycle files"
pass "status snapshot is read-only"

echo "TEST_BRINGUP_LIFECYCLE=PASS"
