#!/usr/bin/env bash
# tests/test_mirror_host_ip_resolution.sh — authoritative Mirror Host IPv4 resolution.
# Hermetic: every case runs against a mocked `ip` binary in a temp PATH and
# temp config files. RFC 5737 documentation addresses only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/scripts/lib/mirror_host_ip.sh"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== test_mirror_host_ip_resolution ==="
[[ -f "$LIB" ]] || { echo "missing ${LIB}"; exit 1; }

# ---------------------------------------------------------------------------
# Mock `ip` so interface facts are fully controlled.
#   $1 default-route interface ("" for no default route)
#   $2.. "iface addr/prefix" pairs advertised as scope global
# ---------------------------------------------------------------------------
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

# Run the resolver in a clean subshell with a mocked environment.
run_resolver() {
  local bindir="$1" mm_conf="$2" mirror_conf="$3"
  env -i \
    PATH="${bindir}:/usr/bin:/bin" \
    HOME="$WORKDIR" \
    MM_CONFIG_FILE="$mm_conf" \
    MIRROR_HOST_MIRROR_CONF="$mirror_conf" \
    bash -c "source '${LIB}'; mirror_host_resolve_and_log" 2>&1
}

field() { printf '%s\n' "$2" | awk -F= -v k="$1" '$1==k{print $2; exit}'; }

# ---------------------------------------------------------------------------
# 1. Persisted Mirror Manager config A → http://192.0.2.10
# ---------------------------------------------------------------------------
BIN_A="${WORKDIR}/bin-a"
make_ip_mock "$BIN_A" eth0 "eth0 192.0.2.10/24" "docker0 172.17.0.1/16"
printf 'MIRROR_SERVER_IP=192.0.2.10\nMIRROR_HTTP_URL=http://192.0.2.10\n' >"${WORKDIR}/mm-a.conf"
: >"${WORKDIR}/empty.conf"
out="$(run_resolver "$BIN_A" "${WORKDIR}/mm-a.conf" "${WORKDIR}/empty.conf")" && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] \
  && [[ "$(field RESOLVED_MIRROR_BASE_URL "$out")" == "http://192.0.2.10" ]] \
  && [[ "$(field MIRROR_IP_RESOLUTION_SOURCE "$out")" == "OPERATOR_CONFIRMED_CONFIG" ]] \
  && [[ "$(field MIRROR_IP_RESOLUTION_RESULT "$out")" == "PASS" ]]; then
  pass "config A resolves to http://192.0.2.10 from OPERATOR_CONFIRMED_CONFIG"
else
  fail "config A resolution: ${out}"
fi

# ---------------------------------------------------------------------------
# 2. Persisted Mirror Manager config B → http://192.0.2.20
# ---------------------------------------------------------------------------
BIN_B="${WORKDIR}/bin-b"
make_ip_mock "$BIN_B" ens160 "ens160 192.0.2.20/24"
printf 'MIRROR_SERVER_IP=192.0.2.20\nMIRROR_HTTP_URL="http://192.0.2.20"\n' >"${WORKDIR}/mm-b.conf"
out="$(run_resolver "$BIN_B" "${WORKDIR}/mm-b.conf" "${WORKDIR}/empty.conf")" && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] \
  && [[ "$(field RESOLVED_MIRROR_BASE_URL "$out")" == "http://192.0.2.20" ]] \
  && [[ "$(field RESOLVED_MIRROR_HOST_IPV4 "$out")" == "192.0.2.20" ]]; then
  pass "config B resolves to http://192.0.2.20"
else
  fail "config B resolution: ${out}"
fi

# ---------------------------------------------------------------------------
# 3. Ambiguous: multiple global IPv4 on the primary interface → FAIL
# ---------------------------------------------------------------------------
BIN_AMBIG="${WORKDIR}/bin-ambig"
make_ip_mock "$BIN_AMBIG" eth0 "eth0 192.0.2.10/24" "eth0 198.51.100.10/24"
out="$(run_resolver "$BIN_AMBIG" "${WORKDIR}/missing.conf" "${WORKDIR}/empty.conf")" && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] \
  && [[ "$(field MIRROR_IP_RESOLUTION_RESULT "$out")" == "FAIL" ]] \
  && [[ "$(field MIRROR_IPV4_CANDIDATE_COUNT "$out")" == "2" ]] \
  && [[ -z "$(field RESOLVED_MIRROR_BASE_URL "$out")" ]]; then
  pass "ambiguous multi-address host fails closed without picking one"
else
  fail "ambiguous case should fail: ${out}"
fi

# ---------------------------------------------------------------------------
# 4. No default route and no addresses → FAIL
# ---------------------------------------------------------------------------
BIN_NONE="${WORKDIR}/bin-none"
make_ip_mock "$BIN_NONE" ""
out="$(run_resolver "$BIN_NONE" "${WORKDIR}/missing.conf" "${WORKDIR}/empty.conf")" && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] \
  && [[ "$(field MIRROR_IP_RESOLUTION_RESULT "$out")" == "FAIL" ]] \
  && [[ -z "$(field RESOLVED_MIRROR_HOST_IPV4 "$out")" ]]; then
  pass "resolution failure yields empty result, never 127.0.0.1"
else
  fail "no-route case should fail: ${out}"
fi
if printf '%s\n' "$out" | grep -q '127\.0\.0\.1'; then
  fail "loopback fallback present in failure output"
else
  pass "no loopback fallback on failure"
fi

# ---------------------------------------------------------------------------
# 5. Persisted address that is not configured on this host → FAIL
# ---------------------------------------------------------------------------
printf 'MIRROR_HTTP_URL=http://198.51.100.10\n' >"${WORKDIR}/mm-stale.conf"
out="$(run_resolver "$BIN_A" "${WORKDIR}/mm-stale.conf" "${WORKDIR}/empty.conf")" && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] && [[ "$(field MIRROR_IP_RESOLUTION_RESULT "$out")" == "FAIL" ]]; then
  pass "persisted address absent from host fails closed"
else
  fail "stale persisted address should fail: ${out}"
fi

# ---------------------------------------------------------------------------
# 6. mirror.conf fallback and auto-detection
# ---------------------------------------------------------------------------
printf 'MIRROR_IP="192.0.2.10"\nMIRROR_URL=""\n' >"${WORKDIR}/mirror-a.conf"
out="$(run_resolver "$BIN_A" "${WORKDIR}/missing.conf" "${WORKDIR}/mirror-a.conf")" && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] \
  && [[ "$(field MIRROR_IP_RESOLUTION_SOURCE "$out")" == "PERSISTED_MIRROR_CONF" ]] \
  && [[ "$(field RESOLVED_MIRROR_BASE_URL "$out")" == "http://192.0.2.10" ]]; then
  pass "mirror.conf MIRROR_IP is honoured"
else
  fail "mirror.conf fallback: ${out}"
fi

printf 'MIRROR_IP=""\nMIRROR_URL=""\n' >"${WORKDIR}/mirror-empty.conf"
out="$(run_resolver "$BIN_B" "${WORKDIR}/missing.conf" "${WORKDIR}/mirror-empty.conf")" && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] \
  && [[ "$(field MIRROR_IP_RESOLUTION_SOURCE "$out")" == "PRIMARY_IFACE_AUTO" ]] \
  && [[ "$(field MIRROR_PRIMARY_INTERFACE "$out")" == "ens160" ]]; then
  pass "auto-detection uses the default-route interface"
else
  fail "auto-detection: ${out}"
fi

# Virtual interfaces must never be selected.
BIN_DOCKER="${WORKDIR}/bin-docker"
make_ip_mock "$BIN_DOCKER" docker0 "docker0 172.17.0.1/16"
out="$(run_resolver "$BIN_DOCKER" "${WORKDIR}/missing.conf" "${WORKDIR}/empty.conf")" && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "docker0 default route is excluded from resolution"
else
  fail "docker0 must not be selected: ${out}"
fi

# ---------------------------------------------------------------------------
# 7. Environment override wins when the address is on this host (source=ENV)
# ---------------------------------------------------------------------------
out="$(
  env -i PATH="${BIN_A}:/usr/bin:/bin" HOME="$WORKDIR" \
    MM_CONFIG_FILE="${WORKDIR}/mm-a.conf" \
    MIRROR_HOST_MIRROR_CONF="${WORKDIR}/empty.conf" \
    RESOLVED_MIRROR_HOST_IPV4=192.0.2.10 \
    bash -c "source '${LIB}'; mirror_host_resolve_and_log" 2>&1
)" && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] \
  && [[ "$(field MIRROR_IP_RESOLUTION_SOURCE "$out")" == "ENV" ]] \
  && [[ "$(field RESOLVED_MIRROR_BASE_URL "$out")" == "http://192.0.2.10" ]]; then
  pass "RESOLVED_MIRROR_HOST_IPV4 override reports source=ENV"
else
  fail "env override: ${out}"
fi

# ENV override that is not configured on this host must fail closed.
out="$(
  env -i PATH="${BIN_A}:/usr/bin:/bin" HOME="$WORKDIR" \
    MM_CONFIG_FILE="${WORKDIR}/mm-a.conf" \
    MIRROR_HOST_MIRROR_CONF="${WORKDIR}/empty.conf" \
    RESOLVED_MIRROR_HOST_IPV4=192.0.2.20 \
    bash -c "source '${LIB}'; mirror_host_resolve_and_log" 2>&1
)" && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] && [[ "$(field MIRROR_IP_RESOLUTION_RESULT "$out")" == "FAIL" ]]; then
  pass "ENV override absent from host fails closed"
else
  fail "mismatched ENV override should fail: ${out}"
fi

# ---------------------------------------------------------------------------
# 8. Helper behaviour
# ---------------------------------------------------------------------------
helper_out="$(
  env -i PATH="${BIN_A}:/usr/bin:/bin" HOME="$WORKDIR" bash -c "
    source '${LIB}'
    mirror_host_extract_ipv4_from_url http://192.0.2.10:8080/client/x.sh
    mirror_base_url_from_ipv4 192.0.2.10
    mirror_host_extract_ipv4_from_url http://mirror.example.test/ || echo NOT_IPV4
    mirror_host_validate_ipv4_on_host 192.0.2.10 && echo ON_HOST
    mirror_host_validate_ipv4_on_host 198.51.100.10 || echo NOT_ON_HOST
    mirror_host_is_excluded_iface veth123 && echo EXCLUDED_VETH
    mirror_host_is_excluded_iface eth0 || echo INCLUDED_ETH0
  " 2>&1
)"
expected_helper="192.0.2.10
http://192.0.2.10
NOT_IPV4
ON_HOST
NOT_ON_HOST
EXCLUDED_VETH
INCLUDED_ETH0"
if [[ "$helper_out" == "$expected_helper" ]]; then
  pass "URL/interface helpers behave as specified"
else
  fail "helpers: ${helper_out}"
fi

# ---------------------------------------------------------------------------
# 9. Resolution/deploy sources must not bake in non-portable environment IPs
# ---------------------------------------------------------------------------
# shellcheck source=lib/portable_ip_policy.sh
source "${ROOT}/tests/lib/portable_ip_policy.sh"
POLICY_FILES=(
  "${ROOT}/scripts/lib/mirror_host_ip.sh"
  "${ROOT}/scripts/lib/client_mirror_gates.sh"
  "${ROOT}/scripts/rebuild-publish-clients.sh"
  "${ROOT}/scripts/deploy-stage-dp-phase2-client-atomic.sh"
  "${ROOT}/scripts/deploy-dp-phase2-helpers-only.sh"
)
shopt -s nullglob
POLICY_FILES+=("${ROOT}"/scripts/deploy-client-*-atomic.sh)
shopt -u nullglob
if portable_ip_policy_assert_files "mirror-host-sources" "${POLICY_FILES[@]}"; then
  echo "MIRROR_HARDCODED_IP_COUNT=0"
  pass "no non-portable IPs in resolution/deploy sources"
else
  fail "non-portable IP literals in resolution/deploy sources"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_mirror_host_ip_resolution PASS ==="
else
  echo "=== test_mirror_host_ip_resolution FAIL ==="
fi
exit "$FAIL"
