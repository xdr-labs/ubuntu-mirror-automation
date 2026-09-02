#!/usr/bin/env bash
# ACPS_EFFECTIVE_BASE must be safe under set -u before acps_setup_curl_auth.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/acps_acquire.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1) Disk-estimate / preflight path: hint before auth setup under set -u.
unset ACPS_EFFECTIVE_BASE || true
set +e
out="$(
  set -euo pipefail
  unset ACPS_EFFECTIVE_BASE || true
  ACPS_EXPECTED_BYTES="$(acps_expected_bytes_hint "${ACPS_EFFECTIVE_BASE:-}")"
  printf 'HINT=%s\n' "${ACPS_EXPECTED_BYTES}"
)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "acps hint under set -u without ACPS_EFFECTIVE_BASE" \
  || fail "unbound ACPS_EFFECTIVE_BASE under set -u (rc=$rc out=$out)"

# 2) After auth setup, base must be initialized (fixed URL contract).
unset ACPS_EFFECTIVE_BASE || true
ACPS_USERNAME=demo
ACPS_PASSWORD=demo
acps_setup_curl_auth
[[ -n "${ACPS_EFFECTIVE_BASE:-}" ]] \
  && pass "ACPS_EFFECTIVE_BASE set by acps_setup_curl_auth" \
  || fail "ACPS_EFFECTIVE_BASE empty after acps_setup_curl_auth"

# 3) Missing credentials must fail closed with a clear error (not unbound).
unset ACPS_EFFECTIVE_BASE ACPS_USERNAME ACPS_PASSWORD DP_PHASE2_SOURCE_BASE || true
set +e
err="$(
  set -euo pipefail
  unset ACPS_EFFECTIVE_BASE ACPS_USERNAME ACPS_PASSWORD DP_PHASE2_SOURCE_BASE || true
  acps_setup_curl_auth 2>&1
)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && echo "$err" | grep -q 'ACPS_USERNAME=FAIL\|ACPS_PASSWORD=FAIL' \
  && pass "missing ACPS credentials fail-closed" \
  || fail "missing credentials did not fail closed (rc=$rc err=$err)"

echo "SUMMARY fail=${FAIL}"
exit "$FAIL"
