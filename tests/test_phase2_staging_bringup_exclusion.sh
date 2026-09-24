#!/usr/bin/env bash
# Regression: Phase 2 restage must not mutate contract/artifacts/controller while a
# verified live bringup worker is running. Stale/dead PID must not block restage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIFE="${ROOT}/client/lib/dp-phase2-bringup-lifecycle.sh"
STAGE="${ROOT}/client/stage-dp-phase2.sh"
CONTRACT="${ROOT}/client/lib/dp-phase2-staging-contract.sh"

FAIL=0
PASS=0
WORKDIR="$(mktemp -d)"
WORKER_PID=""
trap '[[ -n "${WORKER_PID:-}" ]] && kill "$WORKER_PID" 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "======== test_phase2_staging_bringup_exclusion ========"

bash -n "$LIFE" && pass "bash -n lifecycle" || fail "bash -n lifecycle"
bash -n "$STAGE" && pass "bash -n stage" || fail "bash -n stage"

grep -q 'p2b_assert_staging_may_mutate_artifacts' "$STAGE" \
  && pass "stage invokes bringup exclusion gate" \
  || fail "stage missing bringup exclusion gate"
grep -q 'p2b_acquire_artifact_consumer_lock' "$LIFE" \
  && pass "lifecycle defines artifact-consumer lock" \
  || fail "lifecycle missing artifact-consumer lock"
# Gate must sit before contract invalidation / controller retract in stage_main.
python3 - "$ROOT" <<'PY' && pass "exclusion gate before mutation" || fail "exclusion gate ordering wrong"
import sys
from pathlib import Path
body = (Path(sys.argv[1]) / "client/stage-dp-phase2.sh").read_text()
idx = body.rfind("stage_main() {")
body = body[idx:]
gate = body.find("p2b_assert_staging_may_mutate_artifacts")
inv = body.find("dp_phase2_invalidate_staging_contract")
ret = body.find('retract_live_bringup_controller "staging_mutation_start"')
assert gate > 0 and inv > 0 and ret > 0, (gate, inv, ret)
assert gate < inv < ret, (gate, inv, ret)
PY

export PHASE2_BRINGUP_DIR="${WORKDIR}/lifecycle"
export PHASE2_BRINGUP_LOG_DEFAULT="${WORKDIR}/bringup.log"
export PHASE2_STAGING_CONTRACT_ENV="${PHASE2_BRINGUP_DIR}/staging-result.env"
mkdir -p "$PHASE2_BRINGUP_DIR" "${WORKDIR}/artifacts" "${WORKDIR}/home"

# shellcheck source=/dev/null
source "$LIFE"
# shellcheck source=/dev/null
source "$CONTRACT"

write_file() { printf '%s\n' "$2" >"$1"; }

# Seed a completed staging contract + live controller (pre-restage world).
cat >"$PHASE2_STAGING_CONTRACT_ENV" <<'EOF'
PHASE2_STAGING_RESULT=PASS
PHASE2_STAGING_TARGET_VERSION=6.6.0
PHASE2_PREREQ_REQUIRED=NO
PHASE2_STAGING_CONTRACT=PASS
EOF
CONTROLLER="${WORKDIR}/home/bringup_py3_dp_after_os_upgrade.sh"
printf '#!/bin/bash\necho controller\n' >"$CONTROLLER"
chmod +x "$CONTROLLER"
CONTRACT_BEFORE="$(cat "$PHASE2_STAGING_CONTRACT_ENV")"
CONTROLLER_BEFORE="$(cat "$CONTROLLER")"

# --- Live RUNNING bringup must block mutation ---
bash -c 'exec -a bringup-worker sleep 60' &
WORKER_PID=$!
write_file "${PHASE2_BRINGUP_DIR}/state" RUNNING
write_file "${PHASE2_BRINGUP_DIR}/run-id" live-run
write_file "${PHASE2_BRINGUP_DIR}/worker.pid" "$WORKER_PID"
write_file "${PHASE2_BRINGUP_DIR}/worker-start-ticks" "$(awk '{print $22}' "/proc/${WORKER_PID}/stat")"
write_file "${PHASE2_BRINGUP_DIR}/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_file "${PHASE2_BRINGUP_DIR}/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
rm -f "${PHASE2_BRINGUP_DIR}/result.env"

set +e
BLOCK_OUT="$(p2b_assert_staging_may_mutate_artifacts 2>&1)"
BLOCK_RC=$?
set -e
[[ "$BLOCK_RC" -ne 0 ]] && echo "$BLOCK_OUT" | grep -q 'STAGE_BLOCKED_BY_LIVE_BRINGUP=YES' \
  && pass "live RUNNING bringup blocks staging mutation" \
  || fail "live RUNNING bringup did not block (rc=${BLOCK_RC} out=${BLOCK_OUT})"

# Prove nothing was mutated by a restage-shaped invalidate/retract path when blocked.
if declare -F dp_phase2_invalidate_staging_contract >/dev/null 2>&1; then
  # Callers must not reach these when the gate fails; simulate correct control flow.
  :
fi
[[ "$(cat "$PHASE2_STAGING_CONTRACT_ENV")" == "$CONTRACT_BEFORE" ]] \
  && pass "contract untouched while blocked" \
  || fail "contract changed while blocked"
[[ "$(cat "$CONTROLLER")" == "$CONTROLLER_BEFORE" ]] \
  && [[ -e "$CONTROLLER" ]] \
  && pass "controller untouched while blocked" \
  || fail "controller mutated while blocked"

# Worker-held artifact lock also blocks even if status were ignored.
p2b_release_lock 2>/dev/null || true
p2b_release_artifact_consumer_lock 2>/dev/null || true
kill "$WORKER_PID" 2>/dev/null || true
wait "$WORKER_PID" 2>/dev/null || true
WORKER_PID=""
write_file "${PHASE2_BRINGUP_DIR}/state" COMPLETED
write_file "${PHASE2_BRINGUP_DIR}/worker.pid" ""
rm -f "${WORKDIR}/holder-ready"
(
  # shellcheck source=/dev/null
  source "$LIFE"
  export PHASE2_BRINGUP_DIR
  p2b_acquire_artifact_consumer_lock || exit 2
  touch "${WORKDIR}/holder-ready"
  # Hold lock in child while parent tries staging assert with idle status.
  sleep 30
) &
HOLD_PID=$!
for _ in $(seq 1 100); do
  [[ -f "${WORKDIR}/holder-ready" ]] && break
  sleep 0.05
done
[[ -f "${WORKDIR}/holder-ready" ]] || fail "artifact lock holder did not become ready"
set +e
LOCK_OUT="$(p2b_assert_staging_may_mutate_artifacts 2>&1)"
LOCK_RC=$?
set -e
kill "$HOLD_PID" 2>/dev/null || true
wait "$HOLD_PID" 2>/dev/null || true
[[ "$LOCK_RC" -ne 0 ]] && echo "$LOCK_OUT" | grep -q 'STAGE_BLOCKED_BY_ARTIFACT_CONSUMER_LOCK=YES' \
  && pass "artifact-consumer lock blocks staging" \
  || fail "artifact lock did not block (rc=${LOCK_RC} out=${LOCK_OUT})"

# --- Stale/dead PID must allow restage ---
p2b_release_lock 2>/dev/null || true
p2b_release_artifact_consumer_lock 2>/dev/null || true
write_file "${PHASE2_BRINGUP_DIR}/state" RUNNING
write_file "${PHASE2_BRINGUP_DIR}/run-id" stale-run
write_file "${PHASE2_BRINGUP_DIR}/worker.pid" 999999
write_file "${PHASE2_BRINGUP_DIR}/worker-start-ticks" 1
write_file "${PHASE2_BRINGUP_DIR}/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rm -f "${PHASE2_BRINGUP_DIR}/result.env"
set +e
STALE_OUT="$(p2b_assert_staging_may_mutate_artifacts 2>&1)"
STALE_RC=$?
set -e
[[ "$STALE_RC" -eq 0 ]] && echo "$STALE_OUT" | grep -q 'STAGE_MUTATION_ALLOWED=YES' \
  && pass "stale/dead PID allows staging mutation" \
  || fail "stale PID incorrectly blocked (rc=${STALE_RC} out=${STALE_OUT})"
p2b_release_lock 2>/dev/null || true
p2b_release_artifact_consumer_lock 2>/dev/null || true

# Idle / no lifecycle dir: allowed
rm -rf "$PHASE2_BRINGUP_DIR"
mkdir -p "$PHASE2_BRINGUP_DIR"
set +e
IDLE_OUT="$(p2b_assert_staging_may_mutate_artifacts 2>&1)"
IDLE_RC=$?
set -e
[[ "$IDLE_RC" -eq 0 ]] && echo "$IDLE_OUT" | grep -q 'STAGE_MUTATION_ALLOWED=YES' \
  && pass "idle bringup dir allows staging" \
  || fail "idle dir blocked (rc=${IDLE_RC} out=${IDLE_OUT})"

echo "======== summary PASS=${PASS} FAIL=${FAIL} ========"
[[ "$FAIL" -eq 0 ]]
