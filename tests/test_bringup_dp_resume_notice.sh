#!/usr/bin/env bash
# Operator guidance: DP pause may remain after Phase 2 bringup; never auto-resume.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

die() { echo "FATAL: $*" >&2; exit 1; }

[[ -f "$BRINGUP" ]] || die "missing SoT bringup: $BRINGUP"

assert_grep() {
  local pat="$1" file="$2" msg="$3"
  if grep -Eq -- "$pat" "$file"; then
    pass "$msg"
  else
    fail "$msg (pattern=$pat)"
  fi
}

assert_no_grep() {
  local pat="$1" file="$2" msg="$3"
  if grep -Eq -- "$pat" "$file"; then
    fail "$msg (unexpected pattern=$pat)"
  else
    pass "$msg"
  fi
}

echo "======== test_bringup_dp_resume_notice ========"

if bash -n "$BRINGUP"; then
  pass "bash -n bringup SoT"
else
  fail "bash -n bringup SoT"
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
export LOG_FILE="${WORKDIR}/bringup-test.log"
: >"$LOG_FILE"

# --- A: foreground / pre-detach notice (test-mode launcher) ---
A_OUT="${WORKDIR}/pre_detach.out"
if BRINGUP_TEST_EMIT_PRE_DETACH_NOTICE_ONLY=1 bash "$BRINGUP" >"$A_OUT" 2>&1; then
  pass "A test-mode pre-detach exit 0"
else
  fail "A test-mode pre-detach exit 0 (rc=$?)"
fi
assert_grep 'IMPORTANT: DP SERVICE RESUME MAY BE REQUIRED' "$A_OUT" "A EN banner"
assert_no_grep $'\uc548\ub0b4:' "$A_OUT" "A no Korean operator guidance"
assert_grep 'DP_RESUME_AUTOMATIC=NO' "$A_OUT" "A DP_RESUME_AUTOMATIC=NO"
assert_grep 'DP_RESUME_CHECK_REQUIRED_AFTER_BRINGUP=YES' "$A_OUT" "A CHECK_REQUIRED_AFTER_BRINGUP"
assert_grep 'DP_RESUME_EARLIEST_POINT=AFTER_BRINGUP_COMPLETE' "$A_OUT" "A EARLIEST_POINT"
assert_grep 'DP_RESUME_COMMAND=aella_cli_then_resume' "$A_OUT" "A RESUME_COMMAND marker"
assert_grep 'show status' "$A_OUT" "A show status before resume"
assert_no_grep 'DP_PRODUCT_RUNTIME_VALIDATION=PASS' "$A_OUT" "A no false product PASS"

# Source order: pre-detach notice call before detaching message.
if awk '
  /emit_dp_resume_pre_detach_notice$/ && !call { call=NR }
  /detaching bringup so it survives/ && !detach { detach=NR }
  END { exit((call > 0 && detach > 0 && call < detach) ? 0 : 1) }
' "$BRINGUP"; then
  pass "A notice invoked before detach message in source"
else
  fail "A notice invoked before detach message in source"
fi

# --- B: forbid automatic resume execution patterns ---
# Strip quoted operator-guidance strings / comments-only lines for execution scan.
EXEC_SCAN="${WORKDIR}/exec_scan.sh"
# Drop pure comment lines and the operator-notice block (guidance text may say "resume").
awk '
  /^# BEGIN_DP_RESUME_OPERATOR_NOTICE$/ {skip=1; next}
  /^# END_DP_RESUME_OPERATOR_NOTICE$/ {skip=0; next}
  skip {next}
  /^[[:space:]]*#/ {next}
  {print}
' "$BRINGUP" >"$EXEC_SCAN"

if grep -nE 'echo[[:space:]]+resume[[:space:]]*\|[[:space:]]*aella_cli|printf[[:space:]]+['\''"]resume|aella_cli[[:space:]]+resume\b' "$EXEC_SCAN"; then
  fail "B no automatic aella_cli resume pipeline/command"
else
  pass "B no automatic aella_cli resume pipeline/command"
fi
if grep -nE 'expect[[:space:]].*resume|spawn[[:space:]]+aella_cli' "$EXEC_SCAN"; then
  fail "B no expect/spawn aella_cli resume automation"
else
  pass "B no expect/spawn aella_cli resume automation"
fi
if grep -nE ' \|[[:space:]]*aella_cli|aella_cli[[:space:]]*<<|aella_cli[[:space:]]*<' "$EXEC_SCAN"; then
  fail "B no stdin redirection into aella_cli"
else
  pass "B no stdin redirection into aella_cli"
fi
assert_no_grep 'systemctl[[:space:]]+(restart|try-restart)[[:space:]].*resume|resume.*systemctl[[:space:]]+(restart|try-restart)' "$EXEC_SCAN" \
  "B no systemctl restart wired to resume"
assert_no_grep 'kubectl[[:space:]]+scale' "$EXEC_SCAN" "B no kubectl scale resume"

# --- C: post-complete notice ---
C_OUT="${WORKDIR}/post_complete.out"
: >"$LOG_FILE"
if BRINGUP_TEST_EMIT_POST_COMPLETE_NOTICE_ONLY=1 bash "$BRINGUP" >"$C_OUT" 2>&1; then
  pass "C test-mode post-complete exit 0"
else
  fail "C test-mode post-complete exit 0 (rc=$?)"
fi
assert_grep 'NEXT REQUIRED CHECK: DP PAUSE STATE' "$C_OUT" "C EN next-check banner"
assert_grep 'DP_RESUME_CHECK_REQUIRED=YES' "$C_OUT" "C DP_RESUME_CHECK_REQUIRED"
assert_grep 'PRODUCT_VALIDATION_PENDING=YES' "$C_OUT" "C PRODUCT_VALIDATION_PENDING"
assert_grep 'NEXT_REQUIRED_ACTION=CHECK_AELLA_CLI_STATUS_AND_RESUME_IF_PAUSED' "$C_OUT" \
  "C NEXT_REQUIRED_ACTION"
assert_grep 'PHASE2_BRINGUP=COMPLETE' "$C_OUT" "C PHASE2_BRINGUP=COMPLETE"
assert_grep 'DP_PLATFORM_PAUSE_STATE=REQUIRES_OPERATOR_CHECK' "$C_OUT" "C pause requires check"
assert_grep 'DP_PRODUCT_RUNTIME_VALIDATION=NOT_COMPLETE' "$C_OUT" "C product validation not complete"
assert_grep 'may still be paused' "$C_OUT" "C non-assertive paused wording"
assert_no_grep 'DP_PRODUCT_RUNTIME_VALIDATION=PASS' "$C_OUT" "C no product PASS at bringup complete"
assert_grep 'DP_RESUME_CHECK_REQUIRED=YES' "$LOG_FILE" "C notice also appended to LOG_FILE"

# Call site after Bringup complete marker.
if awk '
  /(echo|log) "  Bringup complete:/ && !c {c=NR}
  /emit_dp_resume_post_complete_notice$/ && !p {p=NR}
  END { exit((c>0 && p>0 && p>c) ? 0 : 1) }
' "$BRINGUP"; then
  pass "C post-complete notice after Bringup complete marker"
else
  fail "C post-complete notice after Bringup complete marker"
fi

# --- detach contract preserved ---
assert_grep 'BRINGUP_DETACHED=1 setsid bash "\$0"' "$BRINGUP" "detach setsid preserved"
assert_grep 'AELDEV-71573: detaching bringup' "$BRINGUP" "detach message preserved"
# Launcher exits 0 immediately after backgrounding the detached bringup.
if awk '
  /BRINGUP_DETACHED=1 setsid bash/ {s=NR}
  s && !e && /^[[:space:]]*exit 0$/ {e=NR}
  END { exit((s>0 && e>s && (e-s)<=3) ? 0 : 1) }
' "$BRINGUP"; then
  pass "launcher still exits 0 after detach"
else
  fail "launcher still exits 0 after detach"
fi

# Pause is operator MOTD guidance in Phase 1 hops (not auto-executed here).
if grep -n 'DataProcessor(AIO)> pause' \
  "${ROOT}/client/dp-offline-upgrade-xenial-to-bionic.sh.in" \
  "${ROOT}/client/dp-offline-upgrade-bionic-to-focal.sh.in" >/dev/null; then
  pass "Phase1 MOTD documents manual aella_cli pause"
else
  fail "Phase1 MOTD documents manual aella_cli pause"
fi

if command -v shellcheck >/dev/null 2>&1; then
  NOTICE="${WORKDIR}/notice.sh"
  {
    echo '# shellcheck shell=bash'
    awk '
      /^# BEGIN_DP_RESUME_OPERATOR_NOTICE$/ {keep=1; next}
      /^# END_DP_RESUME_OPERATOR_NOTICE$/ {keep=0; next}
      keep {print}
    ' "$BRINGUP"
  } >"$NOTICE"
  if shellcheck -x -e SC1091,SC2015,SC2034,SC2119,SC2120,SC2317 "$NOTICE"; then
    pass "shellcheck notice helpers"
  else
    fail "shellcheck notice helpers"
  fi
else
  echo "  SKIP: shellcheck not installed"
fi

echo "SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
