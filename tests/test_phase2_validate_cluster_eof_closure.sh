#!/usr/bin/env bash
# Targeted regressions for Real E2E --validate-cluster EOF loop + cluster semantics.
# Does NOT run tests/run_all.sh. Does NOT touch Real AWS DP / AWP DP.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CV="${ROOT}/client/lib/dp-phase2-cluster-validation.sh"
LIFE="${ROOT}/client/lib/dp-phase2-bringup-lifecycle.sh"
MIG="${ROOT}/client/lib/dp-phase2-post-bringup-migration.sh"
WRAP="${ROOT}/client/bringup_py3_dp_lifecycle.sh"
FAIL=0
PASS=0
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "======== test_phase2_validate_cluster_eof_closure ========"

bash -n "$CV" && bash -n "$LIFE" && bash -n "$MIG" && bash -n "$WRAP" \
  && pass "bash -n cluster validation / lifecycle / migration / wrapper" \
  || fail "bash -n"

# shellcheck source=/dev/null
source "$CV"
# shellcheck source=/dev/null
source "$MIG"

BIN="${WORKDIR}/bin"
mkdir -p "$BIN"

# ---------------------------------------------------------------------------
# Field-bug reproduction: Python cmd.Cmd converts stdin EOF → literal "EOF"
# ---------------------------------------------------------------------------
cat >"${BIN}/aella_cli_cmd_eof.py" <<'PY'
#!/usr/bin/env python3
"""Minimal cmd.Cmd replica of production aella_cli EOF behavior."""
import cmd
import sys

STATUS = """Welcome to Data Processor

3 pods running, at least 54 expected
System paused. Type resume in cli to start data processor services
All cluster nodes are ready
All host services are ready
"""

class FakeDP(cmd.Cmd):
    prompt = "DataProcessor(AIO)> "
    intro = "Welcome to Data Processor\n"

    def do_show(self, arg):
        if arg.strip() == "status":
            print(STATUS)
        else:
            print("*** Unknown syntax: show %s" % arg)

    def do_quit(self, arg):
        return True

    def do_exit(self, arg):
        return True

    # Intentionally NO do_EOF — matches field CLI that loops on EOFError.
    def default(self, line):
        print("*** Unknown syntax: %s" % line)

if __name__ == "__main__":
    FakeDP().cmdloop()
PY
chmod +x "${BIN}/aella_cli_cmd_eof.py"

# Old buggy stdin pattern (show status only) MUST reproduce field failure text.
OLD_OUT="${WORKDIR}/old-eof.out"
set +e
# Bound the reproduction so the infinite loop cannot hang the test harness.
timeout --kill-after=1 2 bash -c \
  "printf 'show status\n' | python3 '${BIN}/aella_cli_cmd_eof.py'" \
  >"$OLD_OUT" 2>&1
OLD_RC=$?
set -e
if grep -q '\*\*\* Unknown syntax: EOF' "$OLD_OUT"; then
  pass "field failure reproduced: *** Unknown syntax: EOF (old stdin pattern)"
else
  fail "could not reproduce field EOF loop text: $(head -n 20 "$OLD_OUT")"
fi
[[ "$OLD_RC" -ne 0 ]] \
  && pass "old EOF loop does not exit cleanly (rc=${OLD_RC})" \
  || fail "old EOF loop unexpectedly exited 0"

# Fixed driver must NOT emit literal EOF command against the same CLI.
FIX_OUT="${WORKDIR}/fixed.out"
set +e
P2B_AELLA_CLI_STATUS_TIMEOUT_SEC=10 P2B_AELLA_CLI_KILL_GRACE_SEC=1 \
  p2b_aella_cli_show_status_bounded "${BIN}/aella_cli_cmd_eof.py" 10 \
  >"$FIX_OUT" 2>&1
FIX_RC=$?
set -e
if grep -q '\*\*\* Unknown syntax: EOF' "$FIX_OUT"; then
  fail "fixed driver still produced Unknown syntax: EOF"
else
  pass "fixed driver never emits Unknown syntax: EOF"
fi
grep -q 'AELLA_CLI_SHOW_STATUS=OK' "$FIX_OUT" \
  && grep -q 'AELLA_CLI_EXIT_REASON=CLEAN_QUIT' "$FIX_OUT" \
  && [[ "$FIX_RC" -eq 0 ]] \
  && pass "normal successful CLI exit via show status + quit" \
  || fail "clean quit path: rc=${FIX_RC} $(tail -n 20 "$FIX_OUT")"
grep -q 'System paused' "$FIX_OUT" \
  && pass "paused DP status text collected" \
  || fail "paused status missing from fixed driver output"

# Prove stdin bytes never include the token EOF as a command.
cat >"${BIN}/aella_cli_capture_stdin.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cap="${AELLA_CLI_STDIN_CAPTURE:?}"
: >"$cap"
while IFS= read -r line || [[ -n "$line" ]]; do
  printf '%s\n' "$line" >>"$cap"
  case "$line" in
    "show status")
      printf '%s\n' "52 pods running, at least 54 expected"
      printf '%s\n' "Missing pods: processor, zookeeper"
      printf '%s\n' "All cluster nodes are ready"
      printf '%s\n' "All host services are ready"
      printf '%s\n' "License is valid"
      printf '%s\n' "All 23 indices ready"
      printf '%s\n' "All DGA models are ready"
      printf '%s\n' "Provision service is ready"
      ;;
    quit|exit) exit 0 ;;
    EOF)
      echo "*** Unknown syntax: EOF"
      # Match field hang if EOF ever arrives
      while true; do echo "*** Unknown syntax: EOF"; sleep 0.05; done
      ;;
    *) echo "*** Unknown syntax: $line" ;;
  esac
done
# If stdin closes without quit, mimic cmd.Cmd EOF → literal EOF loop.
echo "*** Unknown syntax: EOF"
while true; do echo "*** Unknown syntax: EOF"; sleep 0.05; done
EOF
chmod +x "${BIN}/aella_cli_capture_stdin.sh"

CAP="${WORKDIR}/stdin.cap"
set +e
AELLA_CLI_STDIN_CAPTURE="$CAP" \
  P2B_AELLA_CLI_STATUS_TIMEOUT_SEC=8 P2B_AELLA_CLI_KILL_GRACE_SEC=1 \
  p2b_aella_cli_show_status_bounded "${BIN}/aella_cli_capture_stdin.sh" 8 \
  >"${WORKDIR}/cap.out" 2>&1
CAP_RC=$?
set -e
[[ -f "$CAP" ]] || fail "stdin capture missing"
if grep -qx 'EOF' "$CAP"; then
  fail "literal EOF command was sent on stdin"
else
  pass "stdin never contains literal EOF command"
fi
grep -qx 'show status' "$CAP" && grep -qx 'quit' "$CAP" \
  && pass "stdin lifecycle is show status then quit" \
  || fail "stdin capture unexpected: $(cat "$CAP")"
[[ "$CAP_RC" -eq 0 ]] \
  && pass "capture CLI exited cleanly under fixed driver" \
  || fail "capture CLI rc=${CAP_RC}"

# ---------------------------------------------------------------------------
# Hung CLI → bounded explicit failure + child cleanup
# ---------------------------------------------------------------------------
cat >"${BIN}/aella_cli_hang.sh" <<'EOF'
#!/usr/bin/env bash
# Ignore quit; sleep forever (field hang analogue).
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    "show status") echo "hanging after status"; ;;
    *) : ;;
  esac
done
sleep 3600
EOF
chmod +x "${BIN}/aella_cli_hang.sh"

set +e
P2B_AELLA_CLI_STATUS_TIMEOUT_SEC=2 P2B_AELLA_CLI_KILL_GRACE_SEC=1 \
  p2b_aella_cli_show_status_bounded "${BIN}/aella_cli_hang.sh" 2 \
  >"${WORKDIR}/hang.out" 2>&1
HANG_RC=$?
set -e
[[ "$HANG_RC" -eq 3 ]] \
  && grep -q 'AELLA_CLI_EXIT_REASON=TIMEOUT' "${WORKDIR}/hang.out" \
  && pass "hung CLI returns bounded TIMEOUT failure" \
  || fail "hung CLI: rc=${HANG_RC} $(cat "${WORKDIR}/hang.out")"
# No leftover hang processes from this binary path
if pgrep -f "${BIN}/aella_cli_hang.sh" >/dev/null 2>&1; then
  fail "orphaned aella_cli_hang.sh still running"
  pkill -9 -f "${BIN}/aella_cli_hang.sh" 2>/dev/null || true
else
  pass "hung CLI child reaped (no orphan)"
fi

# ---------------------------------------------------------------------------
# CLI terminated by signal
# ---------------------------------------------------------------------------
cat >"${BIN}/aella_cli_signal.sh" <<'EOF'
#!/usr/bin/env bash
# Die to SIGTERM shortly after start (simulates external kill / signal path).
trap 'exit 143' TERM
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    "show status") echo "status before signal"; sleep 30 ;;
    quit) exit 0 ;;
  esac
done
sleep 30
EOF
chmod +x "${BIN}/aella_cli_signal.sh"

set +e
P2B_AELLA_CLI_STATUS_TIMEOUT_SEC=2 P2B_AELLA_CLI_KILL_GRACE_SEC=1 \
  p2b_aella_cli_show_status_bounded "${BIN}/aella_cli_signal.sh" 2 \
  >"${WORKDIR}/sig.out" 2>&1
SIG_RC=$?
set -e
# Timeout path reaps with TERM/KILL → TIMEOUT or SIGNAL; both are bounded failures.
if [[ "$SIG_RC" -eq 3 || "$SIG_RC" -eq 5 ]]; then
  pass "CLI terminated by signal/timeout is bounded failure (rc=${SIG_RC})"
else
  fail "signal path unexpected rc=${SIG_RC}: $(cat "${WORKDIR}/sig.out")"
fi
if pgrep -f "${BIN}/aella_cli_signal.sh" >/dev/null 2>&1; then
  fail "orphaned signal CLI remains"
  pkill -9 -f "${BIN}/aella_cli_signal.sh" 2>/dev/null || true
else
  pass "signal CLI child cleaned up"
fi

# ---------------------------------------------------------------------------
# Malformed / unexpected CLI output
# ---------------------------------------------------------------------------
cat >"${BIN}/aella_cli_malformed.sh" <<'EOF'
#!/usr/bin/env bash
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    "show status")
      echo "garbled@@@ not a status"
      echo "something weird happened"
      ;;
    quit|exit) exit 0 ;;
  esac
done
EOF
chmod +x "${BIN}/aella_cli_malformed.sh"
set +e
p2b_aella_cli_show_status_bounded "${BIN}/aella_cli_malformed.sh" 5 \
  >"${WORKDIR}/mal.out" 2>&1
MAL_RC=$?
set -e
[[ "$MAL_RC" -eq 0 ]] \
  && grep -q 'AELLA_CLI_SHOW_STATUS=OK' "${WORKDIR}/mal.out" \
  && pass "malformed status still exits cleanly (operator reviews text)" \
  || fail "malformed: rc=${MAL_RC}"
ANAL_MAL="$(p2b_analyze_aella_status_text "$(cat "${WORKDIR}/mal.out")")"
echo "$ANAL_MAL" | grep -q 'CLUSTER_STATUS_SUMMARY=NOT_READY_OR_INCOMPLETE' \
  && echo "$ANAL_MAL" | grep -q 'CLUSTER_VALIDATION_RECORDABLE_PASS=NO' \
  && pass "malformed/unexpected output not recordable PASS" \
  || fail "malformed analysis: $ANAL_MAL"

# ---------------------------------------------------------------------------
# PAUSED detection + guidance
# ---------------------------------------------------------------------------
PAUSED_TXT="$(cat <<'EOF'
Welcome to Data Processor
3 pods running, at least 54 expected
System paused. Type resume in cli to start data processor services
All cluster nodes are ready
All host services are ready
EOF
)"
ANAL_P="$(p2b_analyze_aella_status_text "$PAUSED_TXT")"
echo "$ANAL_P" | grep -q 'CLUSTER_STATUS_PAUSED=YES' \
  && echo "$ANAL_P" | grep -q 'CLUSTER_STATUS_SUMMARY=PAUSED' \
  && echo "$ANAL_P" | grep -q 'CLUSTER_VALIDATION_RECORDABLE_PASS=NO' \
  && echo "$ANAL_P" | grep -q 'resume' \
  && pass "PAUSED detection blocks recordable PASS and guides resume" \
  || fail "PAUSED analysis: $ANAL_P"

# Field final operational state: 52/54 with missing pods — still authoritative.
READY_TXT="$(cat <<'EOF'
52 pods running, at least 54 expected
Missing pods: processor, zookeeper
142 images installed on host
All images to run microservices are ready
All images to support platform are ready
CM certificates ready
License is valid
DNS server has been setup
All cluster nodes are ready
Using management interface only
All host services are ready
All DGA models are ready
All 23 indices ready
Provision service is ready
The OTP was verified successfully
EOF
)"
ANAL_R="$(p2b_analyze_aella_status_text "$READY_TXT")"
echo "$ANAL_R" | grep -q 'CLUSTER_STATUS_PAUSED=NO' \
  && echo "$ANAL_R" | grep -q 'CLUSTER_SIGNAL_NODES_READY=YES' \
  && echo "$ANAL_R" | grep -q 'CLUSTER_SIGNAL_HOST_SERVICES_READY=YES' \
  && echo "$ANAL_R" | grep -q 'CLUSTER_SIGNAL_LICENSE_VALID=YES' \
  && echo "$ANAL_R" | grep -q 'CLUSTER_SIGNAL_POD_COUNT_IS_HARD_GATE=NO' \
  && echo "$ANAL_R" | grep -q 'CLUSTER_STATUS_SUMMARY=AUTHORITATIVE_SIGNALS_PRESENT' \
  && echo "$ANAL_R" | grep -q 'CLUSTER_VALIDATION_RECORDABLE_PASS=OPERATOR_JUDGEMENT' \
  && pass "field 52/54 + missing pods does not hard-fail; authoritative signals noted" \
  || fail "ready analysis: $ANAL_R"

# ---------------------------------------------------------------------------
# Full --validate-cluster surface with fake CLI (paused)
# ---------------------------------------------------------------------------
export AELLA_CLI_PATH="${BIN}/aella_cli_capture_stdin.sh"
export AELLA_CLI_STDIN_CAPTURE="${WORKDIR}/surf.cap"
export DP_PHASE2_ADMIN_KUBECONFIG="${WORKDIR}/missing-admin.conf"
unset DP_PHASE2_FAKE_AELLA_STATUS DP_PHASE2_FAKE_K8S || true
# Override capture CLI to emit paused status
cat >"${BIN}/aella_cli_paused.sh" <<'EOF'
#!/usr/bin/env bash
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    "show status")
      echo "System paused. Type resume in cli to start data processor services"
      echo "All cluster nodes are ready"
      ;;
    quit|exit) exit 0 ;;
    EOF) echo "*** Unknown syntax: EOF"; while true; do sleep 1; done ;;
  esac
done
echo "*** Unknown syntax: EOF"
while true; do sleep 1; done
EOF
chmod +x "${BIN}/aella_cli_paused.sh"
export AELLA_CLI_PATH="${BIN}/aella_cli_paused.sh"
set +e
p2b_run_cluster_validation_surface >"${WORKDIR}/surface-paused.txt" 2>&1
SURF_RC=$?
set -e
[[ "$SURF_RC" -eq 0 ]] || fail "paused surface rc=${SURF_RC}"
grep -q 'CLUSTER_STATUS_PAUSED=YES' "${WORKDIR}/surface-paused.txt" \
  && grep -q 'DP_RESUME_AUTOMATIC=NO' "${WORKDIR}/surface-paused.txt" \
  && grep -q 'CLUSTER_VALIDATION=PENDING' "${WORKDIR}/surface-paused.txt" \
  && grep -q 'OPERATOR_SEQUENCE=START' "${WORKDIR}/surface-paused.txt" \
  && ! grep -q '\*\*\* Unknown syntax: EOF' "${WORKDIR}/surface-paused.txt" \
  && pass "validate-cluster surface handles PAUSED without EOF loop" \
  || fail "paused surface: $(cat "${WORKDIR}/surface-paused.txt")"

# ---------------------------------------------------------------------------
# MTU informational (jumbo not a hard gate)
# ---------------------------------------------------------------------------
MTU_OUT="$(DP_PHASE2_FAKE_IP_MTU=$'2: ens5: <BROADCAST> mtu 9001 qdisc mq state UP' p2b_emit_mtu_warning)"
echo "$MTU_OUT" | grep -q 'INTERFACE_MTU iface=ens5 mtu=9001' \
  && echo "$MTU_OUT" | grep -q 'PHASE2_MTU_HARD_FAIL=NO' \
  && echo "$MTU_OUT" | grep -qi 'informational' \
  && ! echo "$MTU_OUT" | grep -qi 'must support it before Phase 2' \
  && pass "MTU jumbo warning is informational hard-fail=NO" \
  || fail "MTU output: $MTU_OUT"

# ---------------------------------------------------------------------------
# Migration contract preserved (6.3.0 → 6.6.0 REQUIRED, not auto-run)
# ---------------------------------------------------------------------------
export POST_BRINGUP_MIGRATION_ENV="${WORKDIR}/mig.env"
dec="$(p2b_decide_post_bringup_migration 6.3.0 6.6.0)"
[[ "$dec" == "REQUIRED" ]] \
  && pass "6.3.0→6.6.0 migration REQUIRED" \
  || fail "migration decision=$dec"
p2b_persist_post_bringup_migration_decision 6.3.0 6.6.0 REQUIRED
grep -q '^POST_BRINGUP_MIGRATION=REQUIRED$' "$POST_BRINGUP_MIGRATION_ENV" \
  && grep -q '^REQUIRED_POST_BRINGUP_ACTION=YES$' "$POST_BRINGUP_MIGRATION_ENV" \
  && grep -q 'upgrade_script.sh 6.6.0' "$POST_BRINGUP_MIGRATION_ENV" \
  && pass "migration decision persisted fail-closed" \
  || fail "migration persist $(cat "$POST_BRINGUP_MIGRATION_ENV")"
# Completion blocked while cluster PENDING
comp="$(p2b_emit_completion_semantics YES PENDING)"
echo "$comp" | grep -q 'DP_UPGRADE_COMPLETE=NO' \
  && echo "$comp" | grep -q 'POST_BRINGUP_MIGRATION=REQUIRED' \
  && pass "DP_UPGRADE_COMPLETE blocked while migration REQUIRED + cluster PENDING" \
  || fail "completion semantics: $comp"

# ---------------------------------------------------------------------------
# Failed validation must not corrupt completed bringup state
# ---------------------------------------------------------------------------
BR_DIR="${WORKDIR}/phase2-bringup"
mkdir -p "$BR_DIR"
export PHASE2_BRINGUP_DIR="$BR_DIR"
printf 'COMPLETED\n' >"${BR_DIR}/state"
printf 'run-e2e-1\n' >"${BR_DIR}/run-id"
printf '0\n' >"${BR_DIR}/exit-code"
cat >"${BR_DIR}/completion.sentinel" <<'EOF'
BRINGUP_COMPLETION_SENTINEL=PASS
BRINGUP_RUN_ID=run-e2e-1
EOF
cat >"${BR_DIR}/result.env" <<'EOF'
BRINGUP_RESULT=PASS
BRINGUP_TERMINAL_STATE=COMPLETED
BRINGUP_RUN_ID=run-e2e-1
EOF
# Snapshot before failed validation
cp -a "$BR_DIR" "${WORKDIR}/bringup-before"
export CLUSTER_VALIDATION_ENV="${WORKDIR}/cluster-validation.env"
# Force CLI failure (hang → timeout) through validation surface
export AELLA_CLI_PATH="${BIN}/aella_cli_hang.sh"
export P2B_AELLA_CLI_STATUS_TIMEOUT_SEC=2
export P2B_AELLA_CLI_KILL_GRACE_SEC=1
VAL_RC=0
p2b_run_cluster_validation_surface >"${WORKDIR}/val-fail.txt" 2>&1 || VAL_RC=$?
[[ "$VAL_RC" -ne 0 ]] \
  && pass "failed validation returns nonzero (rc=${VAL_RC})" \
  || fail "failed validation should be nonzero"
# Ensure hang child is gone before continuing
pkill -9 -f "${BIN}/aella_cli_hang.sh" 2>/dev/null || true
sleep 0.2
# Bringup artifacts unchanged
if diff -qr "${WORKDIR}/bringup-before" "$BR_DIR" >/dev/null; then
  pass "failed validation does not mutate completed bringup state"
else
  fail "bringup state mutated: $(diff -qr "${WORKDIR}/bringup-before" "$BR_DIR" || true)"
fi
grep -q 'CLUSTER_VALIDATION=PENDING' "${WORKDIR}/val-fail.txt" \
  && pass "failed validation leaves CLUSTER_VALIDATION=PENDING" \
  || fail "validation pending missing"
# record FAIL must also leave bringup untouched
p2b_record_cluster_validation FAIL >/dev/null
if diff -qr "${WORKDIR}/bringup-before" "$BR_DIR" >/dev/null; then
  pass "record-cluster-validation FAIL preserves bringup state"
else
  fail "record FAIL mutated bringup state"
fi
grep -q '^CLUSTER_VALIDATION=FAIL$' "$CLUSTER_VALIDATION_ENV" \
  && pass "cluster validation FAIL recorded separately" \
  || fail "cluster validation env"

# ---------------------------------------------------------------------------
# Operator guidance present in lifecycle source
# ---------------------------------------------------------------------------
grep -q 'OPERATOR_POST_BRINGUP_SEQUENCE=START' "$LIFE" \
  && grep -q 'DP_RESUME_AUTOMATIC=NO' "$LIFE" \
  && grep -q -- '--validate-cluster' "$LIFE" \
  && pass "lifecycle post-bringup operator sequence present" \
  || fail "lifecycle guidance missing"
grep -q 'BRINGUP_ALREADY_COMPLETED=YES' "$WRAP" \
  && grep -q -- '--validate-cluster' "$WRAP" \
  && pass "completed bringup reentry points at validate-cluster" \
  || fail "reentry guidance"
# Production driver must send quit (not bare show status / not literal EOF)
grep -q "printf 'show status\\\\nquit\\\\n'" "$CV" \
  && pass "production driver sends show status + quit" \
  || fail "production driver stdin contract missing"
! grep -nE "printf 'show status\\\\n'\\s*\\|" "$CV" \
  && pass "production driver no longer pipes show-status-only" \
  || fail "show-status-only pipe still present"
! grep -nE "printf .*EOF" "$CV" | grep -v 'Unknown syntax' | grep -v 'LITERAL_EOF' \
  && pass "no printf of EOF token as CLI input in production driver" \
  || true  # informational; detailed check below
if grep -nE "printf 'EOF|printf \"EOF|echo EOF|echo 'EOF'" "$CV"; then
  fail "production code prints EOF token toward CLI"
else
  pass "production code does not echo EOF token to CLI"
fi

# ---------------------------------------------------------------------------
# Wrapper flag wiring
# ---------------------------------------------------------------------------
grep -q -- '--validate-cluster' "$WRAP" \
  && grep -q 'p2b_run_cluster_validation_surface' "$WRAP" \
  && pass "wrapper wires --validate-cluster" \
  || fail "wrapper validate-cluster wiring"

echo "SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
