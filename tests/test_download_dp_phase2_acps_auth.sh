#!/usr/bin/env bash
# Standalone download-dp-phase2.sh must follow the same ACPS auth/TLS policy
# as Mirror Manager (acps_auth.sh): default TLS verify, netrc (not -u), cleanup.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DP2="${ROOT}/scripts/download-dp-phase2.sh"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/acps-run" "$TMP/files" "$TMP/root"
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
# Create the -o destination so download_one can finalize.
out=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-o" ]]; then
    out="$a"
  fi
  prev="$a"
done
if [[ -n "$out" ]]; then
  mkdir -p "$(dirname "$out")"
  printf 'payload\n' >"$out"
fi
exit 0
EOF
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"

# Source download helpers by extracting download_one after loading libs.
# Exercise via a thin harness that sources the same auth module path.
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/dp-phase2-common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/acps_auth.sh"

export ACPS_AUTH_RUN_DIR="$TMP/acps-run"
export ACPS_HOST=acps.example.test
export ACPS_BASE_URL="https://acps.example.test/provision/aelladeb_py3"
export ACPS_BASE_URL_FIXED="$ACPS_BASE_URL"
export ACPS_USERNAME=acpsuser
export ACPS_PASSWORD='demo-standalone-pass'
unset DP_PHASE2_SOURCE_BASE ACPS_EFFECTIVE_BASE || true
ACPS_INSECURE_TLS=0

# --- Static source audit: production path must not hard-code -k/-u ---
if grep -nE -- 'curl_args\+=\(-k -u|curl .* -k .* -u|-k -u "\$\{ACPS_USER\}' "$DP2"; then
  fail "download-dp-phase2 still has unconditional -k/-u ACPS curl"
else
  pass "download-dp-phase2 has no unconditional -k/-u ACPS curl"
fi
grep -q 'acps_auth.sh\|acps_setup_curl_auth' "$DP2" \
  && pass "download-dp-phase2 uses shared acps auth" \
  || fail "download-dp-phase2 missing shared acps auth"

# --- Default: no -k ---
: >"$CURL_LOG"
acps_cleanup_curl_auth
acps_setup_curl_auth
printf '%s\n' "${ACPS_CURL_TLS_ARGS[@]+"${ACPS_CURL_TLS_ARGS[@]}"}" | grep -qx -- '-k' \
  && fail "default TLS args contain -k" || pass "default TLS verify (no -k)"
[[ "${ACPS_CURL_AUTH_ARGS[0]:-}" == "--netrc-file" ]] \
  && pass "standalone auth uses --netrc-file" \
  || fail "standalone auth args not netrc"
NETRC="${ACPS_CURL_NETRC_FILE}"
[[ -f "$NETRC" ]] || fail "netrc missing"
mode="$(stat -c '%a' "$NETRC")"
[[ "$mode" == "600" || "$mode" == "0600" ]] && pass "netrc mode 0600" || fail "netrc mode=${mode}"
if grep -Fq -- "$ACPS_PASSWORD" "$CURL_LOG"; then
  fail "password appeared before any download curl"
else
  pass "password absent from curl log before download"
fi

# Simulate one ACPS download argv composition (same as download_one ACPS branch).
url="${ACPS_EFFECTIVE_BASE%/}/bringup_py3_dp_after_os_upgrade.sh"
part="$TMP/files/bringup_py3_dp_after_os_upgrade.sh.part"
curl_args=(-f -L --continue-at - -o "$part")
curl_args+=(${ACPS_CURL_TLS_ARGS[@]+"${ACPS_CURL_TLS_ARGS[@]}"})
curl_args+=(${ACPS_CURL_AUTH_ARGS[@]+"${ACPS_CURL_AUTH_ARGS[@]}"})
curl "${curl_args[@]}" "$url" >/dev/null 2>&1 || true
if grep -Eq $'[\t ]-k([\t ]|$)' "$CURL_LOG"; then
  fail "default download curl argv includes -k"
else
  pass "default download curl argv has no -k"
fi
if grep -Eq $'[\t ]-u([\t ]|$)' "$CURL_LOG"; then
  fail "download curl argv still contains -u"
else
  pass "download curl argv has no -u"
fi
if grep -Fq -- "$ACPS_PASSWORD" "$CURL_LOG"; then
  fail "password appeared in mocked curl argv"
else
  pass "password absent from mocked curl argv"
fi
acps_cleanup_curl_auth
[[ ! -e "$NETRC" ]] && pass "cleanup removes netrc" || fail "netrc survived cleanup"

# --- ACPS_INSECURE_TLS=1 adds -k with warning ---
: >"$CURL_LOG"
WARN="$TMP/warn.txt"; : >"$WARN"
dp2_warn() { printf '%s\n' "$*" >>"$WARN"; }
ACPS_INSECURE_TLS=1
unset ACPS_EFFECTIVE_BASE || true
acps_setup_curl_auth
printf '%s\n' "${ACPS_CURL_TLS_ARGS[@]+"${ACPS_CURL_TLS_ARGS[@]}"}" | grep -qx -- '-k' \
  && pass "insecure opt-in sets -k" || fail "insecure opt-in missing -k"
grep -q 'ACPS_INSECURE_TLS_WARNING=YES\|ACPS_TLS_VERIFY=DISABLED' "$WARN" \
  && pass "insecure opt-in warns" || fail "insecure opt-in missing warn"
curl_args=(-f -L -o "$TMP/files/x.part")
curl_args+=(${ACPS_CURL_TLS_ARGS[@]+"${ACPS_CURL_TLS_ARGS[@]}"})
curl_args+=(${ACPS_CURL_AUTH_ARGS[@]+"${ACPS_CURL_AUTH_ARGS[@]}"})
curl "${curl_args[@]}" "${ACPS_EFFECTIVE_BASE%/}/x" >/dev/null 2>&1 || true
grep -Eq $'[\t ]-k([\t ]|$)' "$CURL_LOG" \
  && pass "insecure download argv includes -k" || fail "insecure download argv missing -k"
acps_cleanup_curl_auth
ACPS_INSECURE_TLS=0
unset -f dp2_warn 2>/dev/null || true

# --- Fixture/local source base: no auth, no -k ---
: >"$CURL_LOG"
export DP_PHASE2_SOURCE_BASE="http://127.0.0.1:9/fixture"
unset ACPS_EFFECTIVE_BASE || true
acps_setup_curl_auth
[[ "${#ACPS_CURL_AUTH_ARGS[@]}" -eq 0 ]] && pass "fixture path has no auth args" || fail "fixture path has auth"
[[ "${#ACPS_CURL_TLS_ARGS[@]}" -eq 0 ]] && pass "fixture path has no TLS -k" || fail "fixture path has TLS args"
acps_cleanup_curl_auth

echo "SUMMARY fail=${FAIL}"
exit "$FAIL"
