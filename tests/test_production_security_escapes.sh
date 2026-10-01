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

# Production effective base is the immutable R2 prefix; no ACPS netrc.
PROD_AUTH="$(mktemp -d)"
set +e
out="$(
  env -u DP_PHASE2_SOURCE_BASE -u ACPS_BASE_URL -u ACPS_BASE_URL_FIXED -u ACPS_HOST -u ACPS_PATH \
    MM_HERMETIC_TEST_MODE=0 ACPS_USERNAME=u ACPS_PASSWORD=p \
    bash -c "
      source '${ROOT}/scripts/lib/acps_auth.sh'
      unset ACPS_AUTH_RUN_DIR
      TMPDIR='${PROD_AUTH}' acps_setup_curl_auth
      printf 'BASE=%s\n' \"\$ACPS_EFFECTIVE_BASE\"
      printf 'AUTH_ARGS=%s\n' \"\${ACPS_CURL_AUTH_ARGS[*]:-}\"
      acps_cleanup_curl_auth
    " 2>&1
)"
rc=$?
set -e
rm -rf "$PROD_AUTH"
[[ "$rc" -eq 0 ]] \
  && printf '%s' "$out" | grep -q 'BASE=https://downloads.xdr.ooo/dp-os-upgrade/phase2/6.6.0/validated-20260919' \
  && ! printf '%s' "$out" | grep -q 'acps.stellarcyber.ai' \
  && ! printf '%s' "$out" | grep -q -- '--netrc-file' \
  && pass "production Phase 2 source is immutable R2; no ACPS netrc" \
  || fail "production R2 source/netrc-free failed (rc=${rc} out=${out})"

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

# --- Production Phase 2 source is immutable R2 (ACPS_PRODUCTION_BASE_URL env ignored) ---
set +e
out="$(
  env -u DP_PHASE2_SOURCE_BASE -u ACPS_BASE_URL -u ACPS_BASE_URL_FIXED -u ACPS_HOST -u ACPS_PATH \
    MM_HERMETIC_TEST_MODE=0 ACPS_USERNAME=u ACPS_PASSWORD=p \
    ACPS_PRODUCTION_BASE_URL='https://evil.example/acps' \
    bash -c "
      source '${ROOT}/scripts/lib/acps_auth.sh'
      TMPDIR='$(mktemp -d)' acps_setup_curl_auth
      printf 'CONST=%s\n' \"\$ACPS_PRODUCTION_BASE_URL\"
      printf 'BASE=%s\n' \"\$ACPS_EFFECTIVE_BASE\"
      printf 'AUTH_ARGS=%s\n' \"\${ACPS_CURL_AUTH_ARGS[*]:-}\"
      acps_cleanup_curl_auth
    " 2>&1
)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] \
  && printf '%s' "$out" | grep -q 'CONST=https://acps.stellarcyber.ai/provision/aelladeb_py3' \
  && printf '%s' "$out" | grep -q 'BASE=https://downloads.xdr.ooo/dp-os-upgrade/phase2/6.6.0/validated-20260919' \
  && ! printf '%s' "$out" | grep -q 'evil.example' \
  && pass "production ACPS_PRODUCTION_BASE_URL=evil ignored; R2 endpoint retained" \
  || fail "ACPS_PRODUCTION_BASE_URL env override not ignored (rc=${rc} out=${out})"

# Evil production constant + matching ACPS_BASE_URL must NOT become self-consistent.
assert_acps_prod_reject "ACPS_PRODUCTION_BASE_URL=evil + ACPS_BASE_URL=evil" \
  ACPS_PRODUCTION_BASE_URL='https://evil.example/acps' \
  ACPS_BASE_URL='https://evil.example/acps'

# Standalone download-dp-phase2.sh must keep the immutable R2 production source.
set +e
out="$(
  env MM_HERMETIC_TEST_MODE=0 ACPS_PRODUCTION_BASE_URL='https://evil.example/acps' \
    PHASE2_R2_BASE_URL_CONSTANT='https://evil.example/r2' \
    bash -c "
      source '${ROOT}/scripts/lib/dp-phase2-common.sh'
      source '${ROOT}/scripts/lib/acps_auth.sh'
      printf 'R2_CONST=%s\n' \"\$PHASE2_R2_BASE_URL_CONSTANT\"
      TMPDIR='$(mktemp -d)' acps_setup_curl_auth
      printf 'BASE=%s\n' \"\$ACPS_EFFECTIVE_BASE\"
      acps_cleanup_curl_auth
    " 2>&1
)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] \
  && printf '%s' "$out" | grep -q 'R2_CONST=https://downloads.xdr.ooo/dp-os-upgrade/phase2/6.6.0/validated-20260919' \
  && printf '%s' "$out" | grep -q 'BASE=https://downloads.xdr.ooo/dp-os-upgrade/phase2/6.6.0/validated-20260919' \
  && ! grep -qE 'PHASE2_R2_BASE_URL_CONSTANT="\$\{PHASE2_R2_BASE_URL_CONSTANT' \
    "${ROOT}/scripts/lib/dp-phase2-common.sh" \
  && ! grep -qE 'PHASE2_R2_BASE_URL_CONSTANT="\$\{PHASE2_R2_BASE_URL_CONSTANT' \
    "${ROOT}/scripts/lib/acps_auth.sh" \
  && pass "standalone download-dp-phase2 immutable R2 production source" \
  || fail "standalone Phase 2 R2 constant still env-overridable (rc=${rc} out=${out})"

# --- DP OS-hop client fixture escapes (Finding residual blocker 2) ---
CLIENT_TMP="$(mktemp -d)"
RENDER="${ROOT}/tests/lib/render_offline_upgrade_stub.py"
XENIAL_IN="${ROOT}/client/dp-offline-upgrade-xenial-to-bionic.sh.in"
XENIAL_STUB="${CLIENT_TMP}/xenial-stub.sh"
python3 "$RENDER" --helpers-only "$XENIAL_IN" "$XENIAL_STUB"
# Pin mirror base to the CLI value so production fixture checks are reached.
# Remaining pin / optional-lib tokens become no-ops (not executable commands).
sed -i \
  -e "s|@@MIRROR_BASE@@|http://127.0.0.1:9|g" \
  -e "s|@@[A-Z0-9_]*@@|: # pin-stub|g" \
  "$XENIAL_STUB"
bash -n "$XENIAL_STUB" || fail "xenial fixture stub bash -n"

# All four hops must contain the shared hermetic gate.
FOUR_HOPS_OK=1
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  tin="${ROOT}/client/dp-offline-upgrade-${hop}.sh.in"
  tsh="${ROOT}/client/dp-offline-upgrade-${hop}.sh"
  if ! grep -q 'dp_offline_enforce_production_fixture_policy' "$tin" \
    || ! grep -q '@@HERMETIC_ESCAPES_HELPER@@' "$tin" \
    || ! grep -q 'dp_offline_enforce_production_fixture_policy' "$tsh"; then
    FOUR_HOPS_OK=0
    fail "hop ${hop} missing shared hermetic fixture gate"
  fi
done
[[ "$FOUR_HOPS_OK" -eq 1 ]] && pass "all four hops share hermetic fixture escape policy"

assert_client_prod_reject() {
  local label="$1"
  shift
  set +e
  out="$(
    env MM_HERMETIC_TEST_MODE=0 DP_ALLOW_MIRROR_BASE_OVERRIDE=0 \
      "$@" \
      bash "$XENIAL_STUB" --mirror-base 'http://127.0.0.1:9' --preflight-only 2>&1
  )"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -qE 'FIXTURE_ESCAPE_PRODUCTION_FORBIDDEN' \
    && pass "production client ${label} → FAIL" \
    || fail "production client ${label} not rejected (rc=${rc} out=${out})"
}

assert_client_prod_reject "DP_OFFLINE_TEST_ROOT=/tmp/x" DP_OFFLINE_TEST_ROOT=/tmp/x
assert_client_prod_reject "DP_OFFLINE_FAKE_DP_VERSION=6.6.0" DP_OFFLINE_FAKE_DP_VERSION=6.6.0
assert_client_prod_reject "DP_OFFLINE_FAKE_ROLE=aio" DP_OFFLINE_FAKE_ROLE=aio
assert_client_prod_reject "TEST_ROOT+FAKE_MIRROR_TRUST" \
  DP_OFFLINE_TEST_ROOT=/tmp/x DP_OFFLINE_FAKE_MIRROR_TRUST=1
assert_client_prod_reject "TEST_ROOT+FAKE_CONFIRM" \
  DP_OFFLINE_TEST_ROOT=/tmp/x DP_OFFLINE_FAKE_CONFIRM=UPGRADE-XENIAL-TO-BIONIC
assert_client_prod_reject "SYSTEMCTL_BIN=/bin/true" SYSTEMCTL_BIN=/bin/true

# Positive dual-hermetic: TEST_ROOT accepted under MM_HERMETIC_TEST_MODE=1
# (preflight may still fail later — must NOT die on fixture policy).
set +e
out="$(
  env MM_HERMETIC_TEST_MODE=1 DP_OFFLINE_TEST_ROOT="${CLIENT_TMP}/fx" \
    bash "$XENIAL_STUB" --mirror-base 'http://127.0.0.1:9' --preflight-only 2>&1
)"
rc=$?
set -e
if printf '%s' "$out" | grep -q 'FIXTURE_ESCAPE_PRODUCTION_FORBIDDEN'; then
  fail "hermetic DP_OFFLINE_TEST_ROOT incorrectly rejected"
else
  pass "hermetic DP_OFFLINE_TEST_ROOT permitted by fixture policy (rc=${rc})"
fi
rm -rf "$CLIENT_TMP"

# --- Mirror Manager HTTP/readiness escape hardening ---
assert_mm_http_escape_reject() {
  local name="$1"
  set +e
  out="$(env MM_HERMETIC_TEST_MODE=0 MM_PROJECT_ROOT="$ROOT" "${name}=1" \
    bash -c "source '${ROOT}/scripts/lib/mirror_manager_common.sh'; source '${ROOT}/scripts/lib/mirror_install_engine.sh'; engine_enable_http_distribution" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q "${name}=FAIL reason=production_forbidden" \
    && pass "production ${name}=1 blocked" \
    || fail "production ${name}=1 not blocked (rc=${rc} out=${out})"
}

assert_mm_http_escape_reject MM_SKIP_NGINX_APPLY
assert_mm_http_escape_reject MM_SKIP_HTTP_VALIDATE
assert_mm_http_escape_reject MM_SKIP_BUNDLE_SHA256

for svc_override in MM_NGINX_BIN MM_SYSTEMCTL_BIN MM_NGINX_SITE_AVAIL MM_NGINX_SITE_ENABLED; do
  set +e
  out="$(env MM_HERMETIC_TEST_MODE=0 MM_PROJECT_ROOT="$ROOT" "${svc_override}=/bin/true" \
    bash -c "
      source '${ROOT}/scripts/lib/mirror_manager_common.sh'
      source '${ROOT}/scripts/lib/mirror_install_engine.sh'
      engine_assert_production_service_overrides_safe
    " 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -q "${svc_override}=FAIL reason=production_forbidden" \
    && pass "production ${svc_override} override blocked" \
    || fail "production ${svc_override} override not blocked rc=${rc} out=${out}"
done

set +e
out="$(MM_HERMETIC_TEST_MODE=0 MM_VERIFY_HTTP_BASE=http://192.0.2.200 \
  bash -c "
    source '${ROOT}/scripts/lib/mirror_manager_common.sh'
    source '${ROOT}/scripts/lib/mirror_install_engine.sh'
    engine_http_local_smoke 6.6.0 dp_bundle_6.6.0-current.tar
  " 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -q 'MM_VERIFY_HTTP_BASE=FAIL reason=production_forbidden' \
  && pass "production local HTTP probe override blocked" \
  || fail "production local HTTP probe override not blocked rc=${rc}"

set +e
out="$(MM_HERMETIC_TEST_MODE=0 MM_VERIFY_ADVERTISED_HTTP_BASE=http://127.0.0.1:9 MIRROR_SERVER_IP=192.0.2.10 \
  bash -c "
    source '${ROOT}/scripts/lib/mirror_manager_common.sh'
    source '${ROOT}/scripts/lib/mirror_install_engine.sh'
    engine_http_advertised_smoke 6.6.0 dp_bundle_6.6.0-current.tar
  " 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -q 'MM_VERIFY_ADVERTISED_HTTP_BASE=FAIL reason=production_forbidden' \
  && pass "production advertised HTTP probe override blocked" \
  || fail "production advertised HTTP probe override not blocked rc=${rc}"

set +e
MM_HERMETIC_TEST_MODE=0 MM_NGINX_BIN=/bin/true MM_SYSTEMCTL_BIN=/bin/true \
  mm_nginx_distribution_live >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] \
  && pass "production common nginx/systemctl override blocked" \
  || fail "production common nginx/systemctl override not blocked"

# --dry-run must be read-only and must not mint HTTP/workflow PASS receipts.
DRY_ROOT="$(mktemp -d)"
mkdir -p "$DRY_ROOT/mirror"
set +e
out="$(env MM_DRY_RUN=1 MM_HERMETIC_TEST_MODE=0 MM_PROJECT_ROOT="$ROOT" \
  MM_CONFIG_DIR="$DRY_ROOT/etc" MM_CONFIG_FILE="$DRY_ROOT/etc/dp-upgrade-mirror.conf" \
  MM_STATUS_FILE="$DRY_ROOT/status" MM_WORKFLOW_FILE="$DRY_ROOT/workflow" \
  MM_MIRROR_ROOT="$DRY_ROOT/mirror" MM_SELECTIVE_ROOT="$DRY_ROOT/mirror/selective" \
  MM_DP_PHASE2_ROOT="$DRY_ROOT/mirror/dp-phase2" MM_CLIENT_ROOT="$DRY_ROOT/mirror/client" \
  MM_CACHE_ROOT="$DRY_ROOT/mirror/.install-cache" \
  bash -c "source '${ROOT}/scripts/lib/mirror_manager_common.sh'; source '${ROOT}/scripts/lib/mirror_install_engine.sh'; engine_enable_http_distribution" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'HTTP_WORKFLOW_RECEIPT_WRITTEN=NO' \
  && [[ ! -e "$DRY_ROOT/status" && ! -e "$DRY_ROOT/workflow" ]] \
  && pass "enable-http dry-run is receipt-free/read-only" \
  || fail "enable-http dry-run mutated authoritative state (rc=${rc} out=${out})"
rm -rf "$DRY_ROOT"

# Download-and-Prepare dry-run must also be strictly read-only: no run/status/
# workflow state and no HTTP quiesce before returning.
DRY_ROOT="$(mktemp -d)"
mkdir -p "$DRY_ROOT/mirror"
set +e
out="$(env MM_DRY_RUN=1 MM_HERMETIC_TEST_MODE=0 MM_PROJECT_ROOT="$ROOT" \
  PREPARATION_MODE=PHASE2_ONLY MIRROR_SERVER_IP=192.0.2.10 \
  MM_CONFIG_DIR="$DRY_ROOT/etc" MM_CONFIG_FILE="$DRY_ROOT/etc/dp-upgrade-mirror.conf" \
  MM_STATUS_FILE="$DRY_ROOT/status" MM_WORKFLOW_FILE="$DRY_ROOT/workflow" \
  MM_STATE_ROOT="$DRY_ROOT/runs" MM_LOG_DIR="$DRY_ROOT/logs" \
  MM_MIRROR_ROOT="$DRY_ROOT/mirror" MM_SELECTIVE_ROOT="$DRY_ROOT/mirror/selective" \
  MM_DP_PHASE2_ROOT="$DRY_ROOT/mirror/dp-phase2" MM_CLIENT_ROOT="$DRY_ROOT/mirror/client" \
  MM_CACHE_ROOT="$DRY_ROOT/mirror/.install-cache" \
  bash -c "
    source '${ROOT}/scripts/lib/mirror_manager_common.sh'
    source '${ROOT}/scripts/lib/mirror_install_engine.sh'
    mm_require_configured_mirror_server_ip(){ return 0; }
    dp2_set_version(){ :; }
    engine_download_and_prepare
  " 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && printf '%s\n' "$out" | grep -q 'DRY_RUN_WORKFLOW_RECEIPT_WRITTEN=NO' \
  && printf '%s\n' "$out" | grep -q 'DRY_RUN_HTTP_QUIESCE=NO' \
  && [[ ! -e "$DRY_ROOT/status" && ! -e "$DRY_ROOT/workflow" && ! -e "$DRY_ROOT/runs" ]]; then
  pass "download-and-prepare dry-run is state/HTTP-quiesce free"
else
  fail "download-and-prepare dry-run mutated authoritative state (rc=${rc} out=${out})"
fi
rm -rf "$DRY_ROOT"

# verify-readiness --dry-run runs the authoritative live gate against sandboxed
# receipt copies and must preserve the real status/workflow byte-for-byte.
VERIFY_ROOT="$(mktemp -d)"
mkdir -p "$VERIFY_ROOT/etc" "$VERIFY_ROOT/mirror"
cat >"$VERIFY_ROOT/etc/dp-upgrade-mirror.conf" <<'EOF'
PREPARATION_MODE=PHASE2_ONLY
MIRROR_SERVER_IP=192.0.2.10
TARGET_DP_VERSION=6.6.0
PHASE2_TARGET_VERSION=6.6.0
EOF
cat >"$VERIFY_ROOT/etc/status" <<'EOF'
HTTP_DISTRIBUTION=ENABLED
UPGRADE_READINESS=PASS
READINESS_RESULT=PASS
EOF
cat >"$VERIFY_ROOT/etc/workflow" <<'EOF'
WORKFLOW_STATE=READINESS_VERIFIED
CLIENT_SET_GENERATION_ID=gen-dry-readiness
HTTP_PUBLICATION_GENERATION_ID=gen-dry-readiness
READINESS_VERIFIED_GENERATION_ID=gen-dry-readiness
PREPARATION_MODE=PHASE2_ONLY
EOF
chmod 600 "$VERIFY_ROOT/etc/dp-upgrade-mirror.conf" "$VERIFY_ROOT/etc/status" "$VERIFY_ROOT/etc/workflow"
status_before="$(sha256sum "$VERIFY_ROOT/etc/status" | awk '{print $1}')"
wf_before="$(sha256sum "$VERIFY_ROOT/etc/workflow" | awk '{print $1}')"
set +e
verify_out="$(env MM_HERMETIC_TEST_MODE=1 MM_SKIP_ROOT_CHECK=1 \
  MM_CONFIG_DIR="$VERIFY_ROOT/etc" \
  MM_CONFIG_FILE="$VERIFY_ROOT/etc/dp-upgrade-mirror.conf" \
  MM_STATUS_FILE="$VERIFY_ROOT/etc/status" \
  MM_WORKFLOW_FILE="$VERIFY_ROOT/etc/workflow" \
  MM_STATE_ROOT="$VERIFY_ROOT/runs" MM_LOG_DIR="$VERIFY_ROOT/logs" \
  bash "${ROOT}/scripts/install-dp-upgrade-mirror.sh" verify-readiness \
    --dry-run --mirror-root "$VERIFY_ROOT/mirror" 2>&1)"
verify_rc=$?
set -e
status_after="$(sha256sum "$VERIFY_ROOT/etc/status" | awk '{print $1}')"
wf_after="$(sha256sum "$VERIFY_ROOT/etc/workflow" | awk '{print $1}')"
if printf '%s\n' "$verify_out" | grep -q 'DRY_RUN_WORKFLOW_RECEIPT_WRITTEN=NO' \
  && [[ "$status_before" == "$status_after" && "$wf_before" == "$wf_after" ]]; then
  pass "verify-readiness dry-run preserves real receipts (rc=${verify_rc})"
else
  fail "verify-readiness dry-run mutated real receipts rc=${verify_rc} out=${verify_out}"
fi
rm -rf "$VERIFY_ROOT"

set +e
interactive_out="$(bash "${ROOT}/scripts/install-dp-upgrade-mirror.sh" mirror-manager --dry-run 2>&1)"
interactive_rc=$?
set -e
[[ "$interactive_rc" -ne 0 ]] \
  && printf '%s\n' "$interactive_out" | grep -q 'DRY_RUN_INTERACTIVE_UNSUPPORTED=YES' \
  && pass "interactive mirror-manager dry-run rejected explicitly" \
  || fail "interactive mirror-manager dry-run was not rejected rc=${interactive_rc}"

# The shared readiness gate must propagate a live HTTP validation failure.
set +e
out="$(MM_PROJECT_ROOT="$ROOT" MM_HERMETIC_TEST_MODE=1 TARGET_DP_VERSION=6.6.0 PHASE2_TARGET_VERSION=6.6.0 \
  bash -c "
    source '${ROOT}/scripts/lib/mirror_manager_common.sh'
    source '${ROOT}/scripts/lib/mirror_install_engine.sh'
    mm_http_distribution_enabled(){ return 0; }
    mm_download_completed(){ return 0; }
    engine_validate_http_layout(){ return 9; }
    mm_status_set(){ :; }
    mm_error(){ printf '%s\\n' \"\$*\" >&2; }
    dp2_set_version(){ :; }
    engine_validate_upgrade_readiness_live
  " 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'reason=live_http_validation' \
  && pass "shared readiness gate fails on live HTTP validation failure" \
  || fail "shared readiness gate swallowed HTTP failure (rc=${rc} out=${out})"
grep -q 'engine_validate_upgrade_readiness_live' "${ROOT}/scripts/install-dp-upgrade-mirror.sh" \
  && pass "CLI/GUI source includes shared readiness live gate" \
  || fail "shared readiness live gate not wired"

# Exact helper generation must not source an ambient developer checkout.
if grep -RInF '/home/aella/ubuntu-mirror-automation/client/lib' \
    "${ROOT}/client" "${ROOT}/scripts/lib/phase2_bringup_patch" >/dev/null 2>&1 \
  || grep -RInF '/home/aella/lib/' \
    "${ROOT}/client" "${ROOT}/scripts/lib/phase2_bringup_patch" >/dev/null 2>&1; then
  fail "Phase 2 helper/patch tree still falls back to ambient developer paths"
else
  pass "Phase 2 helper/patch tree uses generation-owned/canonical libs only"
fi

# Mirror Manager subprocess helpers must preserve the caller errexit state.
for fn in engine_rebuild_publish_local_client_set engine_bringup_validate_patcher engine_apply_local_bringup_patch; do
  body="$(awk -v f="$fn" '$0 ~ "^" f "\\(\\)" {on=1} on{print} on && /^}/ {exit}' "${ROOT}/scripts/lib/mirror_install_engine.sh")"
  if grep -q 'errexit_was_on' <<<"$body" \
    && grep -q 'case \$- in \*e\*' <<<"$body" \
    && grep -q 'set +e' <<<"$body" \
    && grep -q 'set -e' <<<"$body"; then
    pass "${fn} preserves caller errexit contract"
  else
    fail "${fn} missing caller-errexit preservation"
  fi
done

[[ "$FAIL" -eq 0 ]]
echo "ALL PRODUCTION SECURITY ESCAPE TESTS PASSED"
