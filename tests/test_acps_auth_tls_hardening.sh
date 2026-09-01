#!/usr/bin/env bash
# ACPS auth/TLS hardening: default TLS verify, netrc (not -u), cleanup, set -u.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_PROJECT_ROOT="$ROOT"
export MM_LOG_DIR="$TMP/logs"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$TMP/config/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$TMP/config/status"
export MM_CACHE_ROOT="$TMP/cache"
export ACPS_AUTH_RUN_DIR="$TMP/acps-run"
mkdir -p "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$MM_CACHE_ROOT" "$ACPS_AUTH_RUN_DIR" "$TMP/bin"
: >"$MM_STATUS_FILE"

CURL_LOG="$TMP/curl.argv"
export CURL_LOG
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
: "${CURL_LOG:?}"
{
  printf 'ARGV'
  for a in "$@"; do
    printf '\t%s' "$a"
  done
  printf '\n'
} >>"$CURL_LOG"
# Satisfy http_code probes used by acps_test_connection.
for a in "$@"; do
  if [[ "$a" == *'%{http_code}'* ]]; then
    printf '200'
    exit 0
  fi
done
exit 0
EOF
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/acps_acquire.sh"

ACPS_USERNAME=acpsuser
ACPS_PASSWORD='demo-pass'
unset ACPS_EFFECTIVE_BASE DP_PHASE2_SOURCE_BASE || true
ACPS_INSECURE_TLS=0

# --- Default: no -k ---
: >"$CURL_LOG"
acps_cleanup_curl_auth
acps_setup_curl_auth
acps_test_connection >/dev/null 2>&1 || true
if grep -Eq $'[\t ]-k([\t ]|$)' "$CURL_LOG"; then
  fail "default ACPS_INSECURE_TLS added -k to curl argv"
else
  pass "default TLS verify does not add -k"
fi
printf '%s\n' "${ACPS_CURL_TLS_ARGS[@]+"${ACPS_CURL_TLS_ARGS[@]}"}" | grep -qx -- '-k' \
  && fail "default TLS args unexpectedly contain -k" || true
acps_cleanup_curl_auth

# --- ACPS_INSECURE_TLS=1: warn and use -k ---
: >"$CURL_LOG"
WARN_LOG="$TMP/warn.log"
: >"$WARN_LOG"
mm_warn() { printf '%s\n' "$*" >>"$WARN_LOG"; }
ACPS_INSECURE_TLS=1
unset ACPS_EFFECTIVE_BASE || true
acps_setup_curl_auth
printf '%s\n' "${ACPS_CURL_TLS_ARGS[@]+"${ACPS_CURL_TLS_ARGS[@]}"}" | grep -qx -- '-k' \
  && pass "ACPS_INSECURE_TLS=1 sets -k in TLS args" \
  || fail "ACPS_INSECURE_TLS=1 did not set -k"
grep -q 'ACPS_INSECURE_TLS_WARNING=YES\|ACPS_TLS_VERIFY=DISABLED' "$WARN_LOG" \
  && pass "ACPS_INSECURE_TLS=1 emits warn" \
  || fail "ACPS_INSECURE_TLS=1 missing warn"
acps_test_connection >/dev/null 2>&1 || true
grep -Eq $'[\t ]-k([\t ]|$)' "$CURL_LOG" \
  && pass "ACPS_INSECURE_TLS=1 curl argv includes -k" \
  || fail "curl argv missing -k when insecure"
acps_cleanup_curl_auth
ACPS_INSECURE_TLS=0
unset -f mm_warn 2>/dev/null || true

# --- netrc auth, never -u user:pass; password not in argv ---
SPECIAL_PASS='p$ss"wo'\''rd`!#@&'
ACPS_PASSWORD="$SPECIAL_PASS"
unset ACPS_EFFECTIVE_BASE || true
: >"$CURL_LOG"
acps_setup_curl_auth
[[ "${ACPS_CURL_AUTH_ARGS[0]:-}" == "--netrc-file" ]] \
  && pass "acps_setup_curl_auth uses --netrc-file" \
  || fail "auth args[0] not --netrc-file (got ${ACPS_CURL_AUTH_ARGS[*]:-})"
printf '%s\n' "${ACPS_CURL_AUTH_ARGS[@]+"${ACPS_CURL_AUTH_ARGS[@]}"}" \
  | grep -E '^-u$' >/dev/null && fail "auth args still use -u" || true
[[ -n "${ACPS_CURL_NETRC_FILE:-}" && -f "${ACPS_CURL_NETRC_FILE}" ]] \
  || fail "netrc file missing"
netrc_mode="$(stat -c '%a' "${ACPS_CURL_NETRC_FILE}")"
[[ "$netrc_mode" == "600" || "$netrc_mode" == "0600" ]] \
  && pass "netrc file mode 0600" \
  || fail "netrc mode=${netrc_mode}"
grep -Fq "password ${SPECIAL_PASS}" "${ACPS_CURL_NETRC_FILE}" \
  && pass "special password characters survive in netrc" \
  || fail "special password not preserved in netrc"
acps_test_connection >/dev/null 2>&1 || true
if grep -Fq -- "$SPECIAL_PASS" "$CURL_LOG"; then
  fail "password appeared in mocked curl argv"
else
  pass "password absent from mocked curl argv"
fi
if grep -Eq $'[\t ]-u([\t ]|$)' "$CURL_LOG"; then
  fail "curl argv still contains -u"
else
  pass "curl argv has no -u user:pass"
fi
NETRC_PATH="${ACPS_CURL_NETRC_FILE}"
acps_cleanup_curl_auth
[[ ! -e "$NETRC_PATH" ]] \
  && pass "acps_cleanup_curl_auth removes netrc" \
  || fail "netrc still present after cleanup"
[[ -z "${ACPS_CURL_NETRC_FILE:-}" ]] \
  && pass "ACPS_CURL_NETRC_FILE cleared" \
  || fail "ACPS_CURL_NETRC_FILE not cleared"

# --- set -u safe around auth setup ---
set +e
out="$(
  set -euo pipefail
  unset ACPS_EFFECTIVE_BASE ACPS_CURL_NETRC_FILE || true
  ACPS_USERNAME=u
  ACPS_PASSWORD='x'
  ACPS_AUTH_RUN_DIR="$TMP/acps-run-u"
  mkdir -p "$ACPS_AUTH_RUN_DIR"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/lib/mirror_manager_common.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/lib/acps_acquire.sh"
  acps_setup_curl_auth
  printf 'BASE=%s\n' "${ACPS_EFFECTIVE_BASE}"
  acps_cleanup_curl_auth
)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "acps_setup_curl_auth safe under set -u" \
  || fail "set -u broke acps_setup_curl_auth (rc=$rc out=$out)"

echo "SUMMARY fail=${FAIL}"
exit "$FAIL"
