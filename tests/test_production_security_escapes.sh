#!/usr/bin/env bash
# Production must fail closed on ACPS/TLS/target/test escapes unless dual-hermetic.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# --- ACPS_INSECURE_TLS production ---
set +e
out="$(
  env -u DP_PHASE2_SOURCE_BASE -u ACPS_BASE_URL -u ACPS_BASE_URL_FIXED -u ACPS_HOST -u ACPS_PATH \
    MM_HERMETIC_TEST_MODE=0 ACPS_INSECURE_TLS=1 \
    ACPS_USERNAME=u ACPS_PASSWORD=p \
    bash -c "source '${ROOT}/scripts/lib/acps_auth.sh'; acps_setup_curl_auth" 2>&1
)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'ACPS_INSECURE_TLS=FAIL' \
  && pass "production + ACPS_INSECURE_TLS=1 → FAIL" \
  || fail "production ACPS_INSECURE_TLS not rejected (rc=${rc} out=${out})"

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

# --- Production ACPS URL / host / path overrides (Finding 2) ---
assert_acps_prod_reject() {
  local label="$1"
  shift
  set +e
  out="$(
    env -u DP_PHASE2_SOURCE_BASE MM_HERMETIC_TEST_MODE=0 ACPS_USERNAME=u ACPS_PASSWORD=p \
      "$@" \
      bash -c "source '${ROOT}/scripts/lib/acps_auth.sh'; acps_setup_curl_auth" 2>&1
  )"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -qE 'production_forbidden|ACPS_(BASE_URL|BASE_URL_FIXED|HOST|PATH)=FAIL' \
    && pass "production ${label} → FAIL" \
    || fail "production ${label} not rejected (rc=${rc} out=${out})"
}

assert_acps_prod_reject "ACPS_BASE_URL=evil" ACPS_BASE_URL='https://evil.example/acps'
assert_acps_prod_reject "ACPS_BASE_URL_FIXED=evil" ACPS_BASE_URL_FIXED='https://evil.example/acps'
assert_acps_prod_reject "ACPS_HOST=evil" ACPS_HOST='evil.example'
assert_acps_prod_reject "ACPS_PATH=override" ACPS_PATH='/evil/path'

# Production effective base + netrc machine always acps.stellarcyber.ai
PROD_AUTH="$(mktemp -d)"
set +e
out="$(
  env -u DP_PHASE2_SOURCE_BASE -u ACPS_BASE_URL -u ACPS_BASE_URL_FIXED -u ACPS_HOST -u ACPS_PATH \
    MM_HERMETIC_TEST_MODE=0 ACPS_USERNAME=u ACPS_PASSWORD=p \
    bash -c "
      source '${ROOT}/scripts/lib/acps_auth.sh'
      # Force default run dir under temp by making /run unusable for this process
      unset ACPS_AUTH_RUN_DIR
      TMPDIR='${PROD_AUTH}' acps_setup_curl_auth
      printf 'BASE=%s\n' \"\$ACPS_EFFECTIVE_BASE\"
      if [[ -n \"\${ACPS_CURL_NETRC_FILE:-}\" && -f \"\${ACPS_CURL_NETRC_FILE}\" ]]; then
        awk '/^machine /{print; exit}' \"\$ACPS_CURL_NETRC_FILE\"
        mode=\$(stat -c '%a' \"\$ACPS_CURL_NETRC_FILE\")
        printf 'NETRC_MODE=%s\n' \"\$mode\"
      fi
      acps_cleanup_curl_auth
    " 2>&1
)"
rc=$?
set -e
rm -rf "$PROD_AUTH"
[[ "$rc" -eq 0 ]] \
  && printf '%s' "$out" | grep -q 'BASE=https://acps.stellarcyber.ai/provision/aelladeb_py3' \
  && printf '%s' "$out" | grep -q 'machine acps.stellarcyber.ai' \
  && printf '%s' "$out" | grep -q 'NETRC_MODE=600' \
  && pass "production netrc machine=acps.stellarcyber.ai mode=600" \
  || fail "production fixed endpoint/netrc host failed (rc=${rc} out=${out})"

# --- ACPS_AUTH_RUN_DIR production rejection (Finding 5) ---
EVIL_RUN="$(mktemp -d)"
evil_mode_before="$(stat -c '%a' "$EVIL_RUN")"
set +e
out="$(
  env -u DP_PHASE2_SOURCE_BASE MM_HERMETIC_TEST_MODE=0 \
    ACPS_USERNAME=u ACPS_PASSWORD=p ACPS_AUTH_RUN_DIR="$EVIL_RUN" \
    bash -c "source '${ROOT}/scripts/lib/acps_auth.sh'; acps_setup_curl_auth" 2>&1
)"
rc=$?
set -e
evil_mode_after="$(stat -c '%a' "$EVIL_RUN")"
[[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'ACPS_AUTH_RUN_DIR=FAIL' \
  && [[ "$evil_mode_before" == "$evil_mode_after" ]] \
  && [[ ! -e "${EVIL_RUN}/netrc" ]] \
  && pass "production ACPS_AUTH_RUN_DIR rejected; dir mode unchanged" \
  || fail "production ACPS_AUTH_RUN_DIR not safe (rc=${rc} mode ${evil_mode_before}->${evil_mode_after})"
rm -rf "$EVIL_RUN"

# Hermetic AUTH_RUN_DIR: 0700/0600 + cleanup
AUTH_RUN="$(mktemp -d)"
chmod 755 "$AUTH_RUN"
set +e
out="$(
  env MM_HERMETIC_TEST_MODE=1 ACPS_INSECURE_TLS=1 \
    ACPS_BASE_URL='https://acps.example.test/p' ACPS_USERNAME=u ACPS_PASSWORD=p \
    ACPS_AUTH_RUN_DIR="$AUTH_RUN" \
    bash -c "
      source '${ROOT}/scripts/lib/acps_auth.sh'
      acps_setup_curl_auth
      printf 'DIR_MODE=%s\n' \"\$(stat -c '%a' \"\$ACPS_AUTH_RUN_DIR\")\"
      printf 'NETRC_MODE=%s\n' \"\$(stat -c '%a' \"\$ACPS_CURL_NETRC_FILE\")\"
      printf 'NETRC_HOST=%s\n' \"\$(awk '/^machine /{print \$2; exit}' \"\$ACPS_CURL_NETRC_FILE\")\"
      acps_cleanup_curl_auth
      if [[ -f '${AUTH_RUN}/netrc' ]]; then echo NETRC_REMAINS=1; else echo NETRC_REMAINS=0; fi
    " 2>&1
)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] \
  && printf '%s' "$out" | grep -q 'DIR_MODE=700' \
  && printf '%s' "$out" | grep -q 'NETRC_MODE=600' \
  && printf '%s' "$out" | grep -q 'NETRC_HOST=acps.example.test' \
  && printf '%s' "$out" | grep -q 'NETRC_REMAINS=0' \
  && pass "hermetic ACPS_AUTH_RUN_DIR 0700/0600 + cleanup" \
  || fail "hermetic ACPS_AUTH_RUN_DIR perms/cleanup failed (rc=${rc} out=${out})"
rm -rf "$AUTH_RUN"

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

# --- Compact dual-hermetic escape matrix (Finding 3) ---
# Each escape alone must NOT bypass; dual opt-in required.
matrix_case() {
  local label="$1"
  local alone_env="$2"
  local dual_env="$3"
  local probe="$4"
  local alone_out alone_rc dual_out dual_rc

  set +e
  alone_out="$(env MM_HERMETIC_TEST_MODE=0 $alone_env bash -c "$probe" 2>&1)"
  alone_rc=$?
  dual_out="$(env $dual_env bash -c "$probe" 2>&1)"
  dual_rc=$?
  set -e

  case "$label" in
    MM_SKIP_ROOT_CHECK)
      # alone: non-root must still fail; dual: skip allowed
      if [[ "$(id -u)" -eq 0 ]]; then
        pass "matrix ${label}: skip (running as root)"
        return 0
      fi
      [[ "$alone_rc" -ne 0 ]] || { fail "matrix ${label}: alone unexpectedly passed"; return; }
      [[ "$dual_rc" -eq 0 ]] && pass "matrix ${label}: alone blocked, dual allowed" \
        || fail "matrix ${label}: dual failed (rc=${dual_rc})"
      ;;
    DP_PHASE2_SKIP_ROOT_CHECK)
      if [[ "$(id -u)" -eq 0 ]]; then
        pass "matrix ${label}: skip (running as root)"
        return 0
      fi
      [[ "$alone_rc" -ne 0 ]] || { fail "matrix ${label}: alone unexpectedly passed"; return; }
      [[ "$dual_rc" -eq 0 ]] && pass "matrix ${label}: alone blocked, dual allowed" \
        || fail "matrix ${label}: dual failed (rc=${dual_rc})"
      ;;
    SKIP_MIRROR_HOST_VALIDATE)
      # alone must not short-circuit validate of a non-local IP
      [[ "$alone_rc" -ne 0 ]] || { fail "matrix ${label}: alone unexpectedly passed"; return; }
      [[ "$dual_rc" -eq 0 ]] && pass "matrix ${label}: alone blocked, dual allowed" \
        || fail "matrix ${label}: dual failed (rc=${dual_rc})"
      ;;
    MM_ALLOW_ARBITRARY_TEST_ROOTS)
      [[ "$alone_rc" -ne 0 ]] || { fail "matrix ${label}: alone unexpectedly passed"; return; }
      [[ "$dual_rc" -eq 0 ]] && pass "matrix ${label}: alone blocked, dual allowed" \
        || fail "matrix ${label}: dual failed (rc=${dual_rc})"
      ;;
    MM_CLIENT_FINALIZATION_MODE)
      [[ "$alone_rc" -ne 0 ]] && printf '%s' "$alone_out" | grep -q 'MM_CLIENT_FINALIZATION_MODE=FAIL' \
        && pass "matrix ${label}: alone blocked" \
        || fail "matrix ${label}: alone not blocked (rc=${alone_rc})"
      ;;
    UM_BOOTSTRAP_ALLOW_UNSUPPORTED_OS)
      [[ "$alone_rc" -ne 0 ]] && printf '%s' "$alone_out" | grep -q 'UM_BOOTSTRAP_ALLOW_UNSUPPORTED_OS=FAIL\|production_forbidden' \
        && pass "matrix ${label}: alone blocked" \
        || fail "matrix ${label}: alone not blocked (rc=${alone_rc} out=${alone_out})"
      ;;
    *) fail "matrix unknown label ${label}" ;;
  esac
}

matrix_case MM_SKIP_ROOT_CHECK \
  "MM_SKIP_ROOT_CHECK=1" \
  "MM_HERMETIC_TEST_MODE=1 MM_SKIP_ROOT_CHECK=1" \
  "source '${ROOT}/scripts/lib/mirror_manager_common.sh'; mm_require_root"

matrix_case DP_PHASE2_SKIP_ROOT_CHECK \
  "DP_PHASE2_SKIP_ROOT_CHECK=1" \
  "MM_HERMETIC_TEST_MODE=1 DP_PHASE2_SKIP_ROOT_CHECK=1" \
  "source '${ROOT}/scripts/lib/dp-phase2-common.sh'; dp2_require_root"

matrix_case SKIP_MIRROR_HOST_VALIDATE \
  "SKIP_MIRROR_HOST_VALIDATE=1" \
  "MM_HERMETIC_TEST_MODE=1 SKIP_MIRROR_HOST_VALIDATE=1" \
  "source '${ROOT}/scripts/lib/mirror_host_ip.sh'; mirror_host_validate_ipv4_on_host 203.0.113.50"

matrix_case MM_ALLOW_ARBITRARY_TEST_ROOTS \
  "MM_ALLOW_ARBITRARY_TEST_ROOTS=1" \
  "MM_HERMETIC_TEST_MODE=1 MM_ALLOW_ARBITRARY_TEST_ROOTS=1" \
  "source '${ROOT}/scripts/lib/mirror_manager_common.sh'; mm_assert_safe_destructive_path '${ROOT}/tests' '' ARTIFACT_DIR"

matrix_case MM_CLIENT_FINALIZATION_MODE \
  "MM_CLIENT_FINALIZATION_MODE=verify-only" \
  "MM_HERMETIC_TEST_MODE=1 MM_CLIENT_FINALIZATION_MODE=verify-only" \
  "source '${ROOT}/scripts/lib/mirror_manager_common.sh'; source '${ROOT}/scripts/lib/mirror_install_engine.sh'; engine_finalize_local_client_set"

matrix_case UM_BOOTSTRAP_ALLOW_UNSUPPORTED_OS \
  "UM_BOOTSTRAP_ALLOW_UNSUPPORTED_OS=1" \
  "MM_HERMETIC_TEST_MODE=1 UM_BOOTSTRAP_ALLOW_UNSUPPORTED_OS=1" \
  "source '${ROOT}/lib/bootstrap.sh'; um_bootstrap_os_gate"

[[ "$FAIL" -eq 0 ]]
echo "ALL PRODUCTION SECURITY ESCAPE TESTS PASSED"
