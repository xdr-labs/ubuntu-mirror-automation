#!/usr/bin/env bash
# Immutable R2 production identity pin (small fixtures; no 3.5GB download).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"

pkg="${TMP}/ubuntu-os-core-xenial-to-noble.tar"
printf 'fixture-os-core-payload\n' >"$pkg"
sha="$(sha256sum "$pkg" | awk '{print $1}')"
bytes="$(stat -c%s "$pkg")"
printf '%s  %s\n' "$sha" "$(basename "$pkg")" >"${pkg}.sha256"

export MM_HERMETIC_TEST_MODE=1
export OS_CORE_R2_URL="https://example.test/ubuntu-os-core/ubuntu-os-core-xenial-to-noble.tar"
export OS_CORE_TEST_EXPECTED_SHA256="$sha"
export OS_CORE_TEST_EXPECTED_BYTES="$bytes"

if mm_assert_os_core_production_identity "$pkg" "$OS_CORE_R2_URL" >/dev/null; then
  pass "exact known digest/size → PASS"
else
  fail "exact fixture should PASS"
fi

export OS_CORE_TEST_EXPECTED_SHA256="$(printf '%064d' 1)"
if ! mm_assert_os_core_production_identity "$pkg" "$OS_CORE_R2_URL" >/dev/null 2>&1; then
  pass "wrong digest → FAIL"
else
  fail "wrong digest should FAIL"
fi

export OS_CORE_TEST_EXPECTED_SHA256="$sha"
export OS_CORE_TEST_EXPECTED_BYTES=1
if ! mm_assert_os_core_production_identity "$pkg" "$OS_CORE_R2_URL" >/dev/null 2>&1; then
  pass "wrong size → FAIL"
else
  fail "wrong size should FAIL"
fi

# Non-production hermetic URL without expected override → skip (PASS)
unset OS_CORE_TEST_EXPECTED_SHA256 OS_CORE_TEST_EXPECTED_BYTES
export OS_CORE_R2_URL="http://127.0.0.1:9/fixture-core.tar"
if mm_assert_os_core_production_identity "$pkg" "$OS_CORE_R2_URL" >/dev/null; then
  pass "hermetic non-production URL skips pin"
else
  fail "hermetic fixture URL should skip production pin"
fi

[[ "$FAIL" -eq 0 ]]
echo "ALL R2 IMMUTABLE IDENTITY PIN TESTS PASSED"
