#!/usr/bin/env bash
# tests/test_mirror_manager_ip_configuration.sh — operator-confirmed Mirror Server IP.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/scripts/lib/mirror_host_ip.sh"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== test_mirror_manager_ip_configuration ==="

make_ip_mock() {
  local dir="$1" route_iface="$2"; shift 2
  mkdir -p "$dir"
  {
    echo '#!/usr/bin/env bash'
    echo 'args="$*"'
    printf 'route_iface=%q\n' "$route_iface"
    echo 'addrs=('
    local entry
    for entry in "$@"; do
      printf '  %q\n' "$entry"
    done
    echo ')'
    cat <<'EOF'
emit() {
  local want_dev="$1" entry iface addr idx=2
  for entry in "${addrs[@]:-}"; do
    [[ -n "$entry" ]] || continue
    iface="${entry%% *}"
    addr="${entry#* }"
    if [[ -n "$want_dev" && "$want_dev" != "$iface" ]]; then continue; fi
    printf '%s: %s    inet %s scope global %s\n' "$idx" "$iface" "$addr" "$iface"
    idx=$((idx + 1))
  done
}
case "$args" in
  "-4 route show default")
    [[ -n "$route_iface" ]] && printf 'default via 192.0.2.1 dev %s proto static\n' "$route_iface"
    ;;
  "-4 -o addr show scope global") emit "" ;;
  "-4 -o addr show dev "*" scope global")
    dev="${args#-4 -o addr show dev }"
    dev="${dev% scope global}"
    emit "$dev"
    ;;
esac
exit 0
EOF
  } >"${dir}/ip"
  chmod +x "${dir}/ip"
}

BIN="${WORKDIR}/bin"
make_ip_mock "$BIN" eth0 "eth0 192.0.2.10/24" "eth0 198.51.100.10/24" "ens160 203.0.113.5/24"
CONF="${WORKDIR}/mm.conf"
STATUS="${WORKDIR}/status.env"
export PATH="${BIN}:/usr/bin:/bin"
export MM_CONFIG_FILE="$CONF"
export MM_STATUS_FILE="$STATUS"
export MM_SKIP_ROOT_CHECK=1

# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "$COMMON"

# Auto-detect is suggestion only (ambiguous primary → no single suggestion).
suggest="$(mirror_host_suggest_primary_ipv4 2>/dev/null || true)"
if [[ -z "$suggest" ]]; then
  pass "auto-detected IP is suggestion (ambiguous → empty)"
else
  fail "expected empty suggestion on ambiguous primary; got ${suggest}"
fi

# Single-IP suggestion path
BIN2="${WORKDIR}/bin2"
make_ip_mock "$BIN2" ens160 "ens160 192.0.2.20/24"
suggest2="$(
  env PATH="${BIN2}:/usr/bin:/bin" bash -c "source '${LIB}'; mirror_host_suggest_primary_ipv4"
)"
[[ "$suggest2" == "192.0.2.20" ]] && pass "auto-detected IP is suggestion=192.0.2.20" \
  || fail "suggestion=${suggest2}"

# Operator-confirmed save
export PATH="${BIN}:/usr/bin:/bin"
# Re-source with current PATH for validate against multi-iface mock
MIRROR_HOST_IP_LIB_LOADED=""
# shellcheck source=../scripts/lib/mirror_host_ip.sh
source "$LIB"
ACPS_USERNAME=u
ACPS_PASSWORD=p
PREPARATION_MODE=FULL
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=""
mm_save_gui_config
grep -q 'MIRROR_SERVER_IP=192.0.2.10' "$CONF" && pass "operator-confirmed IP saved" || fail "IP not saved"
grep -q 'MIRROR_HTTP_URL=http://192.0.2.10' "$CONF" && pass "MIRROR_HTTP_URL derived" || fail "URL not saved"

# Persisted configured IP preferred
: >"${WORKDIR}/empty.conf"
out="$(
  env -i PATH="${BIN}:/usr/bin:/bin" HOME="$WORKDIR" \
    MM_CONFIG_FILE="$CONF" \
    MIRROR_HOST_MIRROR_CONF="${WORKDIR}/empty.conf" \
    bash -c "source '${LIB}'; mirror_host_resolve_and_log" 2>&1
)" && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] \
  && echo "$out" | grep -q 'MIRROR_IP_SOURCE=OPERATOR_CONFIRMED_CONFIG' \
  && echo "$out" | grep -q 'CONFIGURED_MIRROR_SERVER_IP=192.0.2.10'; then
  pass "persisted configured IP preferred (OPERATOR_CONFIRMED_CONFIG)"
else
  fail "resolve: ${out}"
fi

# Invalid IPv4 rejected
if mirror_host_is_usable_ipv4 "999.1.1.1"; then
  fail "invalid IPv4 accepted"
else
  pass "invalid IPv4 rejected"
fi

# Loopback rejected
if mirror_host_is_usable_ipv4 "127.0.0.1"; then
  fail "loopback accepted"
else
  pass "loopback rejected"
fi

# Not on interface rejected
MIRROR_SERVER_IP=203.0.113.99
MIRROR_HTTP_URL=http://203.0.113.99
printf 'MIRROR_SERVER_IP=203.0.113.99\nMIRROR_HTTP_URL=http://203.0.113.99\nACPS_USERNAME=u\nACPS_PASSWORD=p\nPREPARATION_MODE=FULL\n' >"$CONF"
chmod 600 "$CONF"
set +e
req_out="$(mm_require_configured_mirror_server_ip 2>&1)"
req_rc=$?
set -e
[[ "$req_rc" -ne 0 ]] && pass "interface-absent IP rejected" || fail "absent IP accepted: ${req_out}"

# Multiple-interface environment: configured IP used
printf 'MIRROR_SERVER_IP=198.51.100.10\nMIRROR_HTTP_URL=http://198.51.100.10\nACPS_USERNAME=u\nACPS_PASSWORD=p\nPREPARATION_MODE=FULL\n' >"$CONF"
chmod 600 "$CONF"
MIRROR_SERVER_IP=""
MIRROR_HTTP_URL=""
set +e
req_out="$(mm_require_configured_mirror_server_ip 2>&1)"
req_rc=$?
set -e
if [[ "$req_rc" -eq 0 ]] && echo "$req_out" | grep -q 'CONFIGURED_MIRROR_SERVER_IP=198.51.100.10'; then
  pass "multi-interface uses configured IP"
else
  fail "multi-iface configured IP: ${req_out}"
fi

# Client pin uses configured IP
pin_url="$(mm_client_mirror_url 2>/dev/null || true)"
[[ "$pin_url" == "http://198.51.100.10" ]] && pass "CLIENT_PIN_CONFIGURED_IP_TEST=PASS" \
  || fail "client pin=${pin_url}"

# Structural: local vs advertised smoke helpers exist and are distinct
grep -q 'engine_http_local_smoke' "${ROOT}/scripts/lib/mirror_install_engine.sh" \
  && grep -q 'engine_http_advertised_smoke' "${ROOT}/scripts/lib/mirror_install_engine.sh" \
  && pass "localhost smoke and advertised smoke are separate" \
  || fail "smoke helpers missing"

grep -q 'Mirror Server IP' "${ROOT}/scripts/install-dp-upgrade-mirror.sh" \
  && pass "MIRROR_IP_CONFIGURATION_FIELD present in GUI" \
  || fail "GUI field missing"

grep -q 'AUTO_DETECTION_ROLE=CONFIGURATION_SUGGESTION\|mirror_host_suggest_primary_ipv4' \
  "${ROOT}/lib/bootstrap.sh" "${ROOT}/scripts/install-dp-upgrade-mirror.sh" \
  && pass "AUTO_DETECTION_ROLE=suggestion" \
  || fail "suggestion role missing"

# Portable-IP policy on Mirror Manager sources (no historical-IP denylist).
# shellcheck source=lib/portable_ip_policy.sh
source "${ROOT}/tests/lib/portable_ip_policy.sh"
if portable_ip_policy_assert_files "mm-ip-config" \
  "${ROOT}/scripts/lib/mirror_host_ip.sh" \
  "${ROOT}/scripts/lib/mirror_manager_common.sh" \
  "${ROOT}/scripts/install-dp-upgrade-mirror.sh"
then
  pass "no non-portable IPs in Mirror Manager sources"
else
  fail "non-portable IP literals in Mirror Manager sources"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_mirror_manager_ip_configuration PASS ==="
else
  echo "=== test_mirror_manager_ip_configuration FAIL ==="
fi
exit "$FAIL"
