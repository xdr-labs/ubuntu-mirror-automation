#!/usr/bin/env bash
# tests/run_pr_gate.sh — Fast PR gate for AWS OS Core completeness (PR #20).
# Does NOT invoke tests/run_all.sh.
# Never contacts a real DP, never modifies/uploads production R2.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

START_TS="$(date +%s)"
FAIL=0

PR_GATE_SCHEDULED=0
PR_GATE_RAN=0
PR_GATE_PASSED=0
PR_GATE_FAILED=0
PR_GATE_SKIPPED=0

AWS_FIELD_REGRESSION_GATE=FAIL
PRODUCTION_LIFECYCLE_ROUNDTRIP=FAIL
CLIENT_FINALIZATION_INTEGRATION=FAIL

run_step() {
  local name="$1"
  shift
  PR_GATE_SCHEDULED=$((PR_GATE_SCHEDULED + 1))
  echo "======== PR_GATE: ${name} ========"
  set +e
  "$@"
  local rc=$?
  set -e
  PR_GATE_RAN=$((PR_GATE_RAN + 1))
  if [[ "$rc" -eq 0 ]]; then
    PR_GATE_PASSED=$((PR_GATE_PASSED + 1))
    echo "OK ${name}"
    case "$name" in
      aws_field_fix) AWS_FIELD_REGRESSION_GATE=PASS ;;
      production_lifecycle_roundtrip) PRODUCTION_LIFECYCLE_ROUNDTRIP=PASS ;;
      client_finalization_integration) CLIENT_FINALIZATION_INTEGRATION=PASS ;;
    esac
    return 0
  fi
  PR_GATE_FAILED=$((PR_GATE_FAILED + 1))
  FAIL=1
  echo "FAIL ${name} (exit=${rc})"
  case "$name" in
    aws_field_fix) AWS_FIELD_REGRESSION_GATE=FAIL ;;
    production_lifecycle_roundtrip) PRODUCTION_LIFECYCLE_ROUNDTRIP=FAIL ;;
    client_finalization_integration) CLIENT_FINALIZATION_INTEGRATION=FAIL ;;
  esac
  return 0
}

# Immediately-required syntax / fixture checks
run_step "bash_n_roundtrip" bash -n tests/test_os_core_r2_roundtrip_integration.sh
run_step "bash_n_client_finalization" bash -n tests/test_client_finalization_local_fs_integration.sh
run_step "bash_n_run_pr_gate" bash -n tests/run_pr_gate.sh
run_step "python_compile_fixture" python3 -m py_compile tests/lib/build_tiny_os_core_lifecycle_fixture.py
run_step "python_compile_os_core" python3 -m py_compile scripts/lib/os_core_package.py
run_step "python_compile_field_fix" python3 -m py_compile tests/test_aws_os_core_completeness_field_fix.py
run_step "python_compile_cross_hop" python3 -m py_compile tests/test_cross_hop_shared_package.py

# Core PR #20 gates (authoritative)
run_step "aws_field_fix" \
  python3 -m unittest tests.test_aws_os_core_completeness_field_fix

run_step "cross_hop_shared_package" \
  python3 -m unittest tests.test_cross_hop_shared_package

run_step "production_lifecycle_roundtrip" \
  bash tests/test_os_core_r2_roundtrip_integration.sh

run_step "client_finalization_integration" \
  bash tests/test_client_finalization_local_fs_integration.sh

END_TS="$(date +%s)"
PR_GATE_DURATION_SECONDS=$((END_TS - START_TS))

echo "======== PR_GATE summary ========"
echo "PR_GATE_SCHEDULED=${PR_GATE_SCHEDULED}"
echo "PR_GATE_RAN=${PR_GATE_RAN}"
echo "PR_GATE_PASSED=${PR_GATE_PASSED}"
echo "PR_GATE_FAILED=${PR_GATE_FAILED}"
echo "PR_GATE_SKIPPED=${PR_GATE_SKIPPED}"
echo "AWS_FIELD_REGRESSION_GATE=${AWS_FIELD_REGRESSION_GATE}"
echo "PRODUCTION_LIFECYCLE_ROUNDTRIP=${PRODUCTION_LIFECYCLE_ROUNDTRIP}"
echo "CLIENT_FINALIZATION_INTEGRATION=${CLIENT_FINALIZATION_INTEGRATION}"
echo "PR_GATE_DURATION_SECONDS=${PR_GATE_DURATION_SECONDS}"

if [[ "$FAIL" -eq 0 && "$PR_GATE_FAILED" -eq 0 && "$PR_GATE_RAN" -eq "$PR_GATE_SCHEDULED" ]]; then
  echo "PR_GATE_RESULT=PASS"
  exit 0
fi
echo "PR_GATE_RESULT=FAIL"
exit 1
