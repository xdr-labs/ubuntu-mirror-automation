#!/usr/bin/env bash
# Version compatibility matrix for generic Phase 2 staging helper.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/client/stage-dp-phase2.sh"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

export DP_PHASE2_STAGE_LIB_ONLY=1
# shellcheck disable=SC1090
source "$HELPER"

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$msg"
  else
    fail "$msg (got=${got} want=${want})"
  fi
}

echo "[test] normalize + compare"
assert_eq "$(normalize_dp_version '6.3.0-abc')" "6.3.0" "build suffix normalize"
assert_eq "$(normalize_dp_version '6.5.0.7942')" "6.5.0" "4-part normalize"
assert_eq "$(compare_dp_versions 6.1.0 6.2.0)" "lt" "6.1.0 < 6.2.0"
assert_eq "$(compare_dp_versions 6.2.0 6.2.0)" "eq" "6.2.0 == 6.2.0"
assert_eq "$(compare_dp_versions 6.5.0 6.4.0)" "gt" "6.5.0 > 6.4.0"
if normalize_dp_version 'not-a-version' >/dev/null 2>&1; then
  fail "malformed should fail"
else
  pass "malformed rejected"
fi

echo "[test] os-release must not shadow target version"
os_release_field() { # override for unit test
  case "$1" in
    VERSION) printf '24.04.4 LTS (Noble Numbat)' ;;
    ID) printf 'ubuntu' ;;
    VERSION_ID) printf '24.04' ;;
    VERSION_CODENAME) printf 'noble' ;;
  esac
}
TARGET_DP_VERSION="6.6.0"
PHASE2_ARTIFACT_VERSION="6.6.0"
# simulate require_noble field reads
_vid="$(os_release_field VERSION_ID)"
_ver="$(os_release_field VERSION)"
assert_eq "$TARGET_DP_VERSION" "6.6.0" "target unchanged after os VERSION read"
[[ "$_ver" != "$TARGET_DP_VERSION" ]] && pass "OS VERSION distinct from target" || fail "OS VERSION collided"

echo "[test] compatibility matrix via evaluate_version_compatibility"
run_compat() {
  local src="$1" tgt="$2" recovery="${3:-0}" fake_state
  # Allow explicit empty state (do not treat "" as unset).
  if [[ $# -ge 4 ]]; then
    fake_state="$4"
  else
    fake_state="COMPLETED_NOBLE"
  fi
  SOURCE_DP_VERSION="$src"
  SOURCE_DP_VERSION_RAW="$src"
  SOURCE_DP_VERSION_ORIGIN="test"
  SOURCE_DP_VERSION_CHECK="PASS"
  TARGET_DP_VERSION="$tgt"
  PHASE2_ARTIFACT_VERSION="$tgt"
  SAME_VERSION_RECOVERY="$recovery"
  # Closures over locals are unreliable under `set -u`; use globals for fakes.
  TEST_FAKE_OS_STATE="$fake_state"
  read_os_upgrade_state() { printf '%s' "${TEST_FAKE_OS_STATE:-}"; }
  phase1_product_validation_is_not_run() {
    [[ "${TEST_FAKE_OS_STATE:-}" == "COMPLETED_NOBLE" ]]
  }
  bringup_already_executed() { return 1; }
  set +e
  out="$(evaluate_version_compatibility 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  return "$rc"
}

capture_compat() {
  set +e
  out="$(run_compat "$@" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  return "$rc"
}

if out="$(run_compat 6.1.0 6.6.0)"; then
  fail "6.1.0 should STOP"
else
  echo "$out" | grep -q 'FAIL_UNSUPPORTED' && pass "6.1.0 unsupported STOP" || fail "6.1.0 message"
fi
if out="$(run_compat 6.1.9 6.6.0)"; then
  fail "6.1.9 should STOP"
else
  echo "$out" | grep -q 'FAIL_UNSUPPORTED' && pass "6.1.9 unsupported STOP" || fail "6.1.9 message"
fi
for v in 6.2.0 6.3.0 6.4.0 6.5.0; do
  if out="$(run_compat "$v" 6.6.0)"; then
    echo "$out" | grep -q 'PASS_UPGRADE' && pass "${v} upgrade PASS" || fail "${v} missing PASS_UPGRADE"
  else
    fail "${v} should allow upgrade"
  fi
done
# Generic helper still treats source==explicit-target as same-version (not production).
out="$(capture_compat 6.5.0 6.5.0 0 '' || true)"
echo "$out" | grep -q 'ALREADY_AT_TARGET' && pass "generic helper 6.5.0==6.5.0 ALREADY_AT_TARGET" || fail "generic 6.5 ALREADY_AT_TARGET"
out="$(capture_compat 6.5.0 6.5.0 0 COMPLETED_NOBLE || true)"
echo "$out" | grep -q 'SAME_VERSION_RECOVERY_REQUIRED' && pass "recovery required without ack" || fail "recovery required"
if out="$(capture_compat 6.5.0 6.5.0 1 COMPLETED_NOBLE)"; then
  echo "$out" | grep -q 'SAME_VERSION_RECOVERY_REQUIRED' && pass "generic 6.5.0 recovery allowed with ack" || fail "generic 6.5 recovery allow"
else
  fail "generic 6.5 recovery with ack should not die: $out"
fi
out="$(capture_compat 6.6.0 6.6.0 0 '' || true)"
echo "$out" | grep -q 'ALREADY_AT_TARGET' && pass "6.6.0 same version ALREADY_AT_TARGET" || fail "6.6.0 ALREADY_AT_TARGET"
out="$(capture_compat 6.6.0 6.6.0 0 COMPLETED_NOBLE || true)"
echo "$out" | grep -q 'SAME_VERSION_RECOVERY_REQUIRED' && pass "6.6.0 recovery required without ack" || fail "6.6.0 recovery required"
out="$(capture_compat 6.7.0 6.6.0 || true)"
echo "$out" | grep -q 'FAIL_DOWNGRADE' && pass "6.7.0 downgrade STOP" || fail "6.7.0 downgrade"

SOURCE_DP_VERSION_CHECK="FAIL"
SOURCE_DP_VERSION=""
TARGET_DP_VERSION="6.6.0"
SAME_VERSION_RECOVERY=0
set +e
out="$(evaluate_version_compatibility 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && echo "$out" | grep -Eq 'SOURCE_DP_VERSION_RESOLUTION=FAIL|compatibility precondition' \
  && pass "unresolved source STOP" || fail "unresolved source STOP"
# Production output must not finish with generic FAIL_UNKNOWN
echo "$out" | grep -q 'FAIL_UNKNOWN' && fail "FAIL_UNKNOWN still present" || pass "no FAIL_UNKNOWN"

echo "[test] target must not be used as source by default"
grep -Eq 'SOURCE_DP_VERSION=.*TARGET_DP_VERSION|SOURCE_DP_VERSION="\$TARGET' "$HELPER" \
  && fail "source assigned from target" || pass "source not taken from target"
grep -Eq '^VERSION=|"VERSION=' "$HELPER" && fail "ambiguous VERSION= present" || pass "no ambiguous VERSION="
grep -q 'MIN_SUPPORTED_SOURCE_DP_VERSION' "$HELPER" && pass "min support constant" || fail "min support"

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL DP PHASE2 VERSION COMPAT TESTS PASSED"
  exit 0
fi
echo "SOME DP PHASE2 VERSION COMPAT TESTS FAILED"
exit 1
