#!/usr/bin/env bash
# Phase1 hop DP version gate: known <6.2.0 fails; 6.2.x allowed; undetermined continues.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

HARNESS="${OUT_DIR}/version-harness.sh"
cat >"$HARNESS" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
EC_DP=13
MIN_DP_VERSION="6.2.0"
log() { local level="$1"; shift; printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*"; }
die() { local code="$1"; shift; log ERROR "$* (exit=${code})"; exit "$code"; }
version_is_mmp() { [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
version_ge() {
  local a="$1" b="$2" a1 a2 a3 b1 b2 b3
  version_is_mmp "$a" || return 1
  version_is_mmp "$b" || return 1
  IFS=. read -r a1 a2 a3 <<<"$a"
  IFS=. read -r b1 b2 b3 <<<"$b"
  if ((a1 != b1)); then ((a1 > b1)); return $?; fi
  if ((a2 != b2)); then ((a2 > b2)); return $?; fi
  ((a3 >= b3))
}
# Mirror Phase1 gate from xenial .in (known unsupported hard-fail; undetermined continues).
assert_dp_version_gate() {
  local DP_VERSION="${1:-}"
  local DP_VERSION_DETECT_STATUS="${2:-ok}"
  local DP_VERSION_CONSISTENCY="${3:-PASS}"
  if [[ "${DP_VERSION_DETECT_STATUS}" == "ok" && "${DP_VERSION_CONSISTENCY}" == "PASS" \
      && -n "${DP_VERSION}" && "${DP_VERSION}" != "UNDETERMINED" ]]; then
    if ! version_is_mmp "$DP_VERSION"; then
      log ERROR "DP_VERSION_GATE=FAIL_MALFORMED version=${DP_VERSION}"
      die "$EC_DP" "FAIL_UNSUPPORTED_DP_VERSION malformed=${DP_VERSION}"
    fi
    if ! version_ge "$DP_VERSION" "${MIN_DP_VERSION}"; then
      log ERROR "DP_VERSION_GATE=FAIL_UNSUPPORTED source=${DP_VERSION} min=${MIN_DP_VERSION}"
      die "$EC_DP" "FAIL_UNSUPPORTED_DP_VERSION source=${DP_VERSION} min=${MIN_DP_VERSION}"
    fi
    if version_ge "$DP_VERSION" "6.6.0"; then
      log ERROR "DP_VERSION_GATE=FAIL_AT_OR_ABOVE_TARGET source=${DP_VERSION} target=6.6.0"
      die "$EC_DP" "FAIL_DP_VERSION_AT_OR_ABOVE_TARGET source=${DP_VERSION}"
    fi
    log INFO "DP_VERSION_GATE=PASS_SUPPORTED source=${DP_VERSION} min=${MIN_DP_VERSION}"
  else
    log INFO "DP_VERSION_GATE=UNDETERMINED_CONTINUE"
  fi
}
assert_dp_version_gate "$@"
EOS
chmod +x "$HARNESS"

# Ensure .in still contains the production gate
grep -q 'FAIL_UNSUPPORTED_DP_VERSION' \
  "${ROOT}/client/dp-offline-upgrade-xenial-to-bionic.sh.in" \
  || fail "xenial .in missing unsupported DP gate"

set +e
bash "$HARNESS" 6.1.9 >"${OUT_DIR}/v61.txt" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'FAIL_UNSUPPORTED_DP_VERSION' "${OUT_DIR}/v61.txt" \
  && pass "known 6.1.x fails before mutation" \
  || fail "6.1.x should fail gate"

set +e
bash "$HARNESS" 6.2.0 >"${OUT_DIR}/v62.txt" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'DP_VERSION_GATE=PASS_SUPPORTED' "${OUT_DIR}/v62.txt" \
  && pass "known 6.2.x allowed through version gate" \
  || fail "6.2.x should pass gate"

set +e
bash "$HARNESS" "" undetermined "" >"${OUT_DIR}/vu.txt" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'DP_VERSION_GATE=UNDETERMINED_CONTINUE' "${OUT_DIR}/vu.txt" \
  && pass "undetermined remains non-hard-gated" \
  || fail "undetermined should continue"

[[ "$FAIL" -eq 0 ]]
echo "ALL PHASE1 UNSUPPORTED DP VERSION GATE TESTS PASSED"
