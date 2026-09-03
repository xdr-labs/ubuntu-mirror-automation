#!/usr/bin/env bash
# FAILED lifecycle state must allow a normal start retry with a new run ID.
# --status and --diagnose remain read-only and must not invoke vendor.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/phase2_prereq_fixture.sh
source "${ROOT}/tests/lib/phase2_prereq_fixture.sh"
WRAPPER="${ROOT}/client/bringup_py3_dp_lifecycle.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

export PHASE2_BRINGUP_DIR="${TMP}/lifecycle"
export PHASE2_BRINGUP_LOG_DEFAULT="${TMP}/bringup.log"
export PHASE2_BRINGUP_MONITOR_SECONDS=1
export PHASE2_BRINGUP_ALLOW_NONROOT=1
export BRINGUP_VENDOR_SCRIPT="${TMP}/vendor.sh"
export PHASE2_PREREQ_STATE="${TMP}/phase2-ubuntu-prerequisites.state"
phase2_prereq_write_not_required_state "$PHASE2_PREREQ_STATE"
mkdir -p "$PHASE2_BRINGUP_DIR" "$(dirname "$PHASE2_BRINGUP_LOG_DEFAULT")"

VENDOR_COUNT="${TMP}/vendor.count"
: >"$VENDOR_COUNT"
cat >"$BRINGUP_VENDOR_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '1\\n' >>"$(printf '%q' "$VENDOR_COUNT")"
echo "FATAL: simulated vendor failure"
exit 1
EOF
chmod +x "$BRINGUP_VENDOR_SCRIPT"

run_wrapper() {
  env \
    PHASE2_BRINGUP_DIR="$PHASE2_BRINGUP_DIR" \
    PHASE2_BRINGUP_LOG_DEFAULT="$PHASE2_BRINGUP_LOG_DEFAULT" \
    PHASE2_BRINGUP_MONITOR_SECONDS=1 \
    PHASE2_BRINGUP_ALLOW_NONROOT=1 \
    BRINGUP_VENDOR_SCRIPT="$BRINGUP_VENDOR_SCRIPT" \
    PHASE2_PREREQ_STATE="$PHASE2_PREREQ_STATE" \
    bash "$WRAPPER" "$@"
}

vendor_invocations() {
  wc -l <"$VENDOR_COUNT" | tr -d ' '
}

set +e
run_wrapper --version 6.6.0 --skip-download --detach >"${TMP}/run1.out" 2>&1
run1_rc=$?
set -e
# --detach guarantees verified worker handoff, not that the asynchronous worker
# has already reached the vendor call. Wait briefly for the observable vendor
# invocation instead of racing the detached prerequisite/marker setup path.
for _ in $(seq 1 50); do
  if [[ "$(vendor_invocations)" -ge 1 ]]; then
    break
  fi
  sleep 0.1
done
# Fast vendor failure may return 1 from the starter after FAILED handoff.
[[ "$(vendor_invocations)" -ge 1 ]] || {
  cat "${TMP}/run1.out"
  fail "run 1 did not invoke vendor"
}
# Wait for worker to persist FAILED.
for _ in $(seq 1 30); do
  if [[ -f "${PHASE2_BRINGUP_DIR}/state" ]] \
    && grep -qx 'FAILED' "${PHASE2_BRINGUP_DIR}/state"; then
    break
  fi
  sleep 0.1
done
grep -qx 'FAILED' "${PHASE2_BRINGUP_DIR}/state" \
  || { cat "${TMP}/run1.out"; fail "run 1 did not reach FAILED"; }
RUN_A="$(tr -d '\r\n' <"${PHASE2_BRINGUP_DIR}/run-id")"
[[ -n "$RUN_A" ]] || fail "run 1 missing BRINGUP_RUN_ID"
pass "run 1 vendor failure becomes FAILED (id present)"

COUNT_AFTER_FAIL="$(vendor_invocations)"
set +e
run_wrapper --status >"${TMP}/status.out" 2>&1
status_rc=$?
set -e
[[ "$status_rc" -eq 0 ]] || fail "--status rc=${status_rc}"
grep -q '^BRINGUP_STATE=FAILED$' "${TMP}/status.out" \
  || fail "--status did not report FAILED"
[[ "$(vendor_invocations)" -eq "$COUNT_AFTER_FAIL" ]] \
  || fail "--status invoked vendor"
pass "--status after FAILED does not invoke vendor"

set +e
run_wrapper --diagnose >"${TMP}/diagnose.out" 2>&1
diag_rc=$?
set -e
[[ "$diag_rc" -eq 0 ]] || fail "--diagnose rc=${diag_rc}"
grep -q 'DIAGNOSE_MUTATION=NO' "${TMP}/diagnose.out" \
  || fail "--diagnose missing DIAGNOSE_MUTATION=NO"
[[ "$(vendor_invocations)" -eq "$COUNT_AFTER_FAIL" ]] \
  || fail "--diagnose invoked vendor"
pass "--diagnose after FAILED does not invoke vendor"

set +e
run_wrapper --version 6.6.0 --skip-download --detach >"${TMP}/run2.out" 2>&1
run2_rc=$?
set -e
grep -q '^BRINGUP_RETRY=YES$' "${TMP}/run2.out" \
  || { cat "${TMP}/run2.out"; fail "run 2 missing BRINGUP_RETRY=YES"; }
grep -q "^BRINGUP_PREVIOUS_RUN_ID=${RUN_A}$" "${TMP}/run2.out" \
  || fail "run 2 missing previous run id"
for _ in $(seq 1 30); do
  RUN_B="$(tr -d '\r\n' <"${PHASE2_BRINGUP_DIR}/run-id" 2>/dev/null || true)"
  if [[ -n "$RUN_B" && "$RUN_B" != "$RUN_A" ]]; then
    break
  fi
  sleep 0.1
done
RUN_B="$(tr -d '\r\n' <"${PHASE2_BRINGUP_DIR}/run-id")"
[[ -n "$RUN_B" && "$RUN_B" != "$RUN_A" ]] \
  || fail "run 2 did not allocate a new run id (A=${RUN_A} B=${RUN_B})"
[[ -f "${PHASE2_BRINGUP_DIR}/previous-failed/run-id" ]] \
  || fail "previous FAILED evidence was not archived"
prev_id="$(tr -d '\r\n' <"${PHASE2_BRINGUP_DIR}/previous-failed/run-id")"
[[ "$prev_id" == "$RUN_A" ]] || fail "archived run id mismatch"
for _ in $(seq 1 30); do
  if [[ "$(vendor_invocations)" -gt "$COUNT_AFTER_FAIL" ]]; then
    break
  fi
  sleep 0.1
done
[[ "$(vendor_invocations)" -gt "$COUNT_AFTER_FAIL" ]] \
  || { cat "${TMP}/run2.out"; fail "run 2 did not invoke vendor again"; }
pass "FAILED normal start retries with new run id and vendor re-invoke"

echo "TEST_BRINGUP_LIFECYCLE_FAILED_RETRY=PASS"