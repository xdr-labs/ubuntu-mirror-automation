#!/usr/bin/env bash
# Production must fail closed on ACPS/TLS/target test escapes unless hermetic.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# --- ACPS_INSECURE_TLS production ---
set +e
out="$(
  env -u DP_PHASE2_SOURCE_BASE MM_HERMETIC_TEST_MODE=0 ACPS_INSECURE_TLS=1 \
    ACPS_BASE_URL='https://acps.example.test/p' ACPS_USERNAME=u ACPS_PASSWORD=p \
    bash -c "source '${ROOT}/scripts/lib/acps_auth.sh'; acps_setup_curl_auth" 2>&1
)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'ACPS_INSECURE_TLS=FAIL' \
  && pass "production + ACPS_INSECURE_TLS=1 → FAIL" \
  || fail "production ACPS_INSECURE_TLS not rejected (rc=${rc})"

# --- DP_PHASE2_SOURCE_BASE production ---
set +e
out="$(
  env MM_HERMETIC_TEST_MODE=0 DP_PHASE2_SOURCE_BASE='http://evil.example/acps' \
    bash -c "source '${ROOT}/scripts/lib/acps_auth.sh'; acps_setup_curl_auth" 2>&1
)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'DP_PHASE2_SOURCE_BASE=FAIL' \
  && pass "production + DP_PHASE2_SOURCE_BASE=http://evil → FAIL" \
  || fail "production DP_PHASE2_SOURCE_BASE not rejected (rc=${rc})"

# --- MM_ALLOW_TARGET_OVERRIDE production ---
set +e
out="$(
  env MM_HERMETIC_TEST_MODE=0 MM_ALLOW_TARGET_OVERRIDE=1 TARGET_DP_VERSION=6.5.0 \
    bash -c "source '${ROOT}/scripts/lib/mirror_manager_common.sh'; mm_force_phase2_target; printf 'TARGET=%s\n' \"\$TARGET_DP_VERSION\"" 2>&1
)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -qE 'production_forbidden|MM_ALLOW_TARGET_OVERRIDE=FAIL'; then
  pass "production + MM_ALLOW_TARGET_OVERRIDE=1 → FAIL closed"
elif [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'TARGET=6.6.0'; then
  pass "production + override → target remains 6.6.0"
else
  fail "production target override not fail-closed (rc=${rc} out=${out})"
fi

# --- Hermetic mode allows overrides ---
set +e
out="$(
  env MM_HERMETIC_TEST_MODE=1 DP_PHASE2_SOURCE_BASE='http://127.0.0.1:9/fixture' \
    bash -c "source '${ROOT}/scripts/lib/acps_auth.sh'; acps_setup_curl_auth; printf 'BASE=%s\n' \"\$ACPS_EFFECTIVE_BASE\"" 2>&1
)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'BASE=http://127.0.0.1:9/fixture' \
  && pass "hermetic mode allows DP_PHASE2_SOURCE_BASE" \
  || fail "hermetic source override failed (rc=${rc})"

set +e
out="$(
  env MM_HERMETIC_TEST_MODE=1 MM_ALLOW_TARGET_OVERRIDE=1 \
    bash -c "source '${ROOT}/scripts/lib/mirror_manager_common.sh'; TARGET_DP_VERSION=6.5.0; mm_force_phase2_target; printf 'TARGET=%s\n' \"\$TARGET_DP_VERSION\"" 2>&1
)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'TARGET=6.5.0' \
  && pass "hermetic mode allows target override" \
  || fail "hermetic target override failed (rc=${rc})"

AUTH_RUN="$(mktemp -d)"
set +e
out="$(
  env MM_HERMETIC_TEST_MODE=1 ACPS_INSECURE_TLS=1 \
    ACPS_BASE_URL='https://acps.example.test/p' ACPS_USERNAME=u ACPS_PASSWORD=p \
    ACPS_AUTH_RUN_DIR="$AUTH_RUN" \
    bash -c "source '${ROOT}/scripts/lib/acps_auth.sh'; acps_setup_curl_auth; printf '%s\n' \"\${ACPS_CURL_TLS_ARGS[*]}\"; acps_cleanup_curl_auth" 2>&1
)"
rc=$?
set -e
rm -rf "$AUTH_RUN"
[[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -qx -- '-k' \
  && pass "hermetic mode allows ACPS_INSECURE_TLS=-k" \
  || fail "hermetic insecure TLS failed (rc=${rc} out=${out})"

[[ "$FAIL" -eq 0 ]]
echo "ALL PRODUCTION SECURITY ESCAPE TESTS PASSED"
