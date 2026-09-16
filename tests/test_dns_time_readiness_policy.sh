#!/usr/bin/env bash
# Fixture coverage for Noble DNS recovery and time readiness. Never touches host services/network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POSTBOOT_POLICY="${ROOT}/client/dp-postboot-readiness-policy.sh.inc"
STAGE="${ROOT}/client/stage-dp-phase2.sh"
TIME_LIB="${ROOT}/client/lib/dp-phase2-time-readiness.sh"
TEMPLATE="${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh.in"
BUILDER="${ROOT}/scripts/lib/build_client_jammy_to_noble.py"
FAIL=0

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }

for f in "$POSTBOOT_POLICY" "$STAGE" "$TIME_LIB" "$TEMPLATE" "$BUILDER"; do
  [[ -f "$f" ]] || { fail "missing ${f}"; continue; }
done
[[ "$FAIL" -eq 0 ]] || exit "$FAIL"

bash -n "$POSTBOOT_POLICY" && pass "postboot policy bash -n" || fail "postboot policy bash -n"
bash -n "$STAGE" && pass "phase2 stage bash -n" || fail "phase2 stage bash -n"
grep -q '@@POSTBOOT_POLICY_LIB@@' "$TEMPLATE" && pass "postboot policy placeholder" || fail "postboot policy placeholder"
grep -q 'dp-postboot-readiness-policy.sh.inc' "$BUILDER" && pass "builder loads postboot policy" || fail "builder loads postboot policy"
if python3 - "$BUILDER" "$ROOT" <<'PY'
import runpy
import sys
ns = runpy.run_path(sys.argv[1])
ns["load_postboot_policy"](sys.argv[2])
PY
then
  pass "builder validates postboot policy contract"
else
  fail "builder postboot policy validation"
fi
grep -q "printf 'DP_MAX_CLOCK_SKEW_SECONDS=%s" "$TEMPLATE" \
  && pass "clock skew override persisted" || fail "clock skew override not persisted"
grep -q 'check_ntp_bringup_readiness || true' "$STAGE" && pass "artifact staging survives time-not-ready" || fail "stage hard-fails on time readiness"
grep -q 'WARNING: no internal NTP source detected; continuing because local clock readiness passed' "$TIME_LIB" \
  && pass "internal NTP is warning-only" || fail "missing warning-only internal NTP policy"
if grep -Eq 'INTERNAL_NTP_REQUIREMENT=NOT_SATISFIED.*BRINGUP_READY=NO|do not run bringup until internal NTP' "$STAGE"; then
  fail "legacy internal-NTP hard gate remains"
else
  pass "legacy internal-NTP hard gate removed"
fi
if grep -Eq '(^|[[:space:]])(ifdown|ifup|reboot)([[:space:]]|$)|systemctl[[:space:]]+(restart|try-restart)[[:space:]]+(networking|NetworkManager|systemd-networkd)' "$POSTBOOT_POLICY"; then
  fail "DNS policy contains network restart/reboot"
else
  pass "DNS policy has no network restart/reboot"
fi
if grep -q 'bringup_py3' "$POSTBOOT_POLICY"; then
  fail "postboot policy executes bringup"
else
  pass "postboot policy does not execute bringup"
fi

grep -q 'UPGRADE_MODE="OS_ONLY_PHASE1"' "$TEMPLATE" && pass "Phase 1 remains OS-only" || fail "Phase 1 OS-only policy"
grep -q 'log INFO "BRINGUP_EXECUTED=NO"' "$TEMPLATE" && pass "Phase 1 never executes bringup" || fail "Phase 1 bringup execution contract"
# Postboot apt health check (not later hop-prep apt-get check sites).
apt_line="$(grep -n 'apt-get check >/dev/null 2>&1 || { log ERROR "broken deps"' "$TEMPLATE" | head -1 | cut -d: -f1 || true)"
route_line="$(grep -n 'DEFAULT_ROUTE_CHECK=PASS' "$TEMPLATE" | tail -1 | cut -d: -f1 || true)"
dns_line="$(grep -n 'check_and_repair_dns_resolver' "$TEMPLATE" | tail -1 | cut -d: -f1 || true)"
time_line="$(grep -n 'check_time_readiness' "$TEMPLATE" | tail -1 | cut -d: -f1 || true)"
complete_line="$(grep -n 'write_state COMPLETED_NOBLE' "$TEMPLATE" | tail -1 | cut -d: -f1 || true)"
if [[ "$apt_line" =~ ^[0-9]+$ && "$route_line" =~ ^[0-9]+$ && "$dns_line" =~ ^[0-9]+$ \
      && "$time_line" =~ ^[0-9]+$ && "$complete_line" =~ ^[0-9]+$ ]] \
   && ((apt_line < route_line && route_line < dns_line && dns_line < time_line && time_line < complete_line)); then
  pass "Noble postboot order apt -> route -> DNS -> time -> COMPLETED_NOBLE"
else
  fail "invalid Noble postboot validation order"
fi

# shellcheck source=../client/dp-postboot-readiness-policy.sh.inc
source "$POSTBOOT_POLICY"

make_dns_fixture() {
  FIX="$(mktemp -d)"
  BIN="$FIX/bin"
  mkdir -p "$BIN" "$FIX/etc/network" "$FIX/etc/systemd/resolved.conf.d" \
    "$FIX/run/systemd/resolve" "$FIX/state"
  printf 'inactive\n' >"$FIX/state/active"
  printf 'masked\n' >"$FIX/state/enabled"
  : >"$FIX/state/calls"
  cat >"$BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
root="${DP_POSTBOOT_TEST_ROOT:?}"
printf '%s\n' "$*" >>"$root/state/calls"
case "$1" in
  is-enabled) cat "$root/state/enabled"; [[ "$(cat "$root/state/enabled")" != masked && "$(cat "$root/state/enabled")" != disabled ]] ;;
  is-active) cat "$root/state/active"; [[ "$(cat "$root/state/active")" == active ]] ;;
  unmask) printf 'disabled\n' >"$root/state/enabled" ;;
  enable)
    printf 'enabled\n' >"$root/state/enabled"
    if [[ " $* " == *" --now "* ]]; then
      printf 'active\n' >"$root/state/active"
      mkdir -p "$root/run/systemd/resolve"
      printf 'nameserver 127.0.0.53\n' >"$root/run/systemd/resolve/stub-resolv.conf"
      dns="$(awk -F= '/^DNS=/{print $2}' "$root/etc/systemd/resolved.conf.d/20-dp-static-dns.conf" 2>/dev/null || true)"
      : >"$root/run/systemd/resolve/resolv.conf"
      for ip in $dns; do printf 'nameserver %s\n' "$ip" >>"$root/run/systemd/resolve/resolv.conf"; done
    fi
    ;;
  stop) printf 'inactive\n' >"$root/state/active" ;;
  start) printf 'active\n' >"$root/state/active" ;;
  mask) printf 'masked\n' >"$root/state/enabled" ;;
  disable) printf 'disabled\n' >"$root/state/enabled" ;;
  *) exit 0 ;;
esac
MOCK
  cat >"$BIN/resolvectl" <<'MOCK'
#!/usr/bin/env bash
root="${DP_POSTBOOT_TEST_ROOT:?}"
awk '/^nameserver /{print "Global: "$2}' "$root/run/systemd/resolve/resolv.conf" 2>/dev/null
MOCK
  cat >"$BIN/getent" <<'MOCK'
#!/usr/bin/env bash
[[ "${DNS_TEST_RESOLVE:-pass}" == pass ]] || exit 2
printf '203.0.113.10 STREAM fixture\n'
MOCK
  chmod +x "$BIN"/*
  export DP_POSTBOOT_TEST_ROOT="$FIX"
  export SYSTEMCTL_BIN="$BIN/systemctl" RESOLVECTL_BIN="$BIN/resolvectl" GETENT_BIN="$BIN/getent"
  export DNS_TEST_RESOLVE=pass
}

cleanup_dns_fixture() {
  rm -rf "$FIX"
  unset DP_POSTBOOT_TEST_ROOT SYSTEMCTL_BIN RESOLVECTL_BIN GETENT_BIN DNS_TEST_RESOLVE
}

make_dns_fixture
printf 'nameserver 10.1.1.53\n' >"$FIX/etc/resolv.conf"
check_and_repair_dns_resolver >/dev/null
[[ "$DNS_RESOLVER_STATE" == HEALTHY_STATIC && "$DNS_RESOLVER_REPAIR" == NOT_REQUIRED ]] \
  && pass "healthy static resolver no-op" || fail "healthy static resolver"
[[ ! -e "$FIX/etc/systemd/resolved.conf.d/20-dp-static-dns.conf" ]] \
  && pass "static resolver not modified" || fail "static resolver modified"
cleanup_dns_fixture

make_dns_fixture
ln -s ../run/systemd/resolve/stub-resolv.conf "$FIX/etc/resolv.conf"
printf 'nameserver 127.0.0.53\n' >"$FIX/run/systemd/resolve/stub-resolv.conf"
printf 'active\n' >"$FIX/state/active"; printf 'enabled\n' >"$FIX/state/enabled"
check_and_repair_dns_resolver >/dev/null
[[ "$DNS_RESOLVER_STATE" == HEALTHY_SYSTEMD_RESOLVED && "$DNS_RESOLVER_REPAIR" == NOT_REQUIRED ]] \
  && pass "healthy systemd-resolved no-op" || fail "healthy systemd-resolved"
cleanup_dns_fixture

make_dns_fixture
rm -f "$FIX/run/systemd/resolve/stub-resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$FIX/etc/resolv.conf"
printf 'auto eth0\niface eth0 inet static\n  dns-nameservers 10.20.30.40 10.20.30.40\n' >"$FIX/etc/network/interfaces"
check_and_repair_dns_resolver >/dev/null
[[ "$DNS_RESOLVER_STATE" == RECOVERED_SYSTEMD_RESOLVED && "$DNS_RESOLVER_REPAIR" == PASS ]] \
  && pass "broken stub auto-repair" || fail "broken stub auto-repair"
[[ "$(grep '^DNS=' "$FIX/etc/systemd/resolved.conf.d/20-dp-static-dns.conf")" == 'DNS=10.20.30.40' ]] \
  && pass "internal DNS dynamic and deduplicated" || fail "internal DNS handling"
: >"$FIX/state/calls"
check_and_repair_dns_resolver >/dev/null
[[ "$DNS_RESOLVER_STATE" == HEALTHY_SYSTEMD_RESOLVED && "$DNS_RESOLVER_REPAIR" == NOT_REQUIRED ]] \
  && pass "DNS repair idempotent" || fail "DNS repair idempotency"
cleanup_dns_fixture

make_dns_fixture
ln -s ../run/systemd/resolve/stub-resolv.conf "$FIX/etc/resolv.conf"
printf 'auto eth0\niface eth0 inet static\n' >"$FIX/etc/network/interfaces"
set +e; check_and_repair_dns_resolver >/dev/null; rc=$?; set -e
[[ "$rc" -ne 0 && "$DNS_RESOLVER_REPAIR" == FAIL ]] && pass "broken stub without DNS fails" || fail "missing-DNS failure"
[[ ! -e "$FIX/etc/systemd/resolved.conf.d/20-dp-static-dns.conf" ]] && pass "missing-DNS no mutation" || fail "missing-DNS mutation"
cleanup_dns_fixture

make_dns_fixture
mkdir -p "$FIX/run/other"; printf 'nameserver 1.1.1.1\n' >"$FIX/run/other/resolv.conf"
ln -s ../run/other/resolv.conf "$FIX/etc/resolv.conf"
check_and_repair_dns_resolver >/dev/null
[[ "$DNS_RESOLVER_STATE" == UNKNOWN_LAYOUT && "$DNS_RESOLVER_REPAIR" == NOT_ATTEMPTED ]] \
  && pass "unknown resolver layout no repair" || fail "unknown resolver layout"
cleanup_dns_fixture

make_dns_fixture
ln -s ../run/systemd/resolve/stub-resolv.conf "$FIX/etc/resolv.conf"
printf 'dns-nameservers 8.8.8.8 1.1.1.1\n' >"$FIX/etc/network/interfaces"
check_and_repair_dns_resolver >/dev/null
[[ "$DNS_RESOLVER_STATE" == RECOVERED_SYSTEMD_RESOLVED && "$DNS_SERVERS_CONFIGURED" == 8.8.8.8,1.1.1.1 ]] \
  && pass "public DNS accepted without hardcoding" || fail "public DNS fixture"
cleanup_dns_fixture

make_dns_fixture
ln -s ../run/systemd/resolve/stub-resolv.conf "$FIX/etc/resolv.conf"
printf 'dns-nameservers 10.0.0.53\n' >"$FIX/etc/network/interfaces"
export DNS_TEST_RESOLVE=fail
set +e; check_and_repair_dns_resolver >/dev/null; rc=$?; set -e
[[ "$rc" -ne 0 && "$DNS_RESOLVER_REPAIR" == FAIL ]] && pass "resolution failure triggers rollback" || fail "resolution rollback result"
[[ ! -e "$FIX/etc/systemd/resolved.conf.d/20-dp-static-dns.conf" ]] && pass "rollback removes generated drop-in" || fail "rollback drop-in"
[[ "$(cat "$FIX/state/enabled")" == masked && "$(cat "$FIX/state/active")" == inactive ]] \
  && pass "rollback restores masked/inactive" || fail "rollback service state"
if grep -Eqi 'restart|ifdown|ifup|reboot|bringup' "$FIX/state/calls"; then
  fail "DNS repair invoked forbidden action"
else
  pass "DNS repair invokes no interface restart/reboot/bringup"
fi
cleanup_dns_fixture

run_time_case() {
  local name="$1" expected="$2" ready="$3" source_class="$4"
  shift 4
  local td mock key val ref httpdate rc out
  td="$(mktemp -d)"; mock="$td/bin"; mkdir -p "$mock"
  cat >"$mock/getent" <<'MOCK'
#!/usr/bin/env bash
case "${2:-}" in
  time.google.com|pool.ntp.org) printf '216.239.35.0 STREAM fixture\n' ;;
  ntp.internal) printf '10.10.1.2 STREAM fixture\n' ;;
  *) exit 2 ;;
esac
MOCK
  chmod +x "$mock/getent"
  for spec in "$@"; do
    key="${spec%%=*}"; val="${spec#*=}"
    case "$key" in
      ntpwait_rc)
        printf '#!/usr/bin/env bash\nexit %s\n' "$val" >"$mock/ntpwait"; chmod +x "$mock/ntpwait" ;;
      ntpq_p) printf '%b' "$val" >"$td/ntpq_p" ;;
      ntpq_rv) printf '%b' "$val" >"$td/ntpq_rv" ;;
      timedatectl) printf '%b' "$val" >"$td/timedatectl" ;;
      http_skew)
        ref=$(( $(date -u +%s) - val ))
        httpdate="$(date -u -d "@$ref" '+%a, %d %b %Y %H:%M:%S GMT')"
        printf '%s' "$httpdate" >"$td/httpdate" ;;
      curl_fail) : >"$td/curl_fail" ;;
    esac
  done
  if [[ -f "$td/ntpq_p" || -f "$td/ntpq_rv" ]]; then
    cat >"$mock/ntpq" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == rv ]]; then cat "$td/ntpq_rv" 2>/dev/null; else cat "$td/ntpq_p" 2>/dev/null; fi
MOCK
    chmod +x "$mock/ntpq"
  fi
  if [[ -f "$td/timedatectl" ]]; then
    printf '#!/usr/bin/env bash\ncat %q\n' "$td/timedatectl" >"$mock/timedatectl"; chmod +x "$mock/timedatectl"
  fi
  cat >"$mock/curl" <<MOCK
#!/usr/bin/env bash
[[ -f "$td/curl_fail" ]] && exit 22
[[ -f "$td/httpdate" ]] || exit 22
printf 'HTTP/1.1 200 OK\\r\\nDate: %s\\r\\n\\r\\n' "\$(cat "$td/httpdate")"
MOCK
  chmod +x "$mock/curl"

  set +e
  # Fixture mirror base (RFC 5737): HTTP Date fallback must use the client pin,
  # never a hardcoded environment address.
  PATH="$mock:$PATH" GETENT_BIN=getent CURL_BIN=curl NTPQ_BIN=ntpq NTPWAIT_BIN=ntpwait TIMEDATECTL_BIN=timedatectl \
    PIN_MIRROR_BASE="http://192.0.2.10" \
    check_time_readiness >"$td/out" 2>&1
  rc=$?
  set -e
  out="$(cat "$td/out")"
  [[ "$TIME_READINESS" == "$expected" ]] || { fail "$name readiness expected=${expected} actual=${TIME_READINESS}"; printf '%s\n' "$out"; }
  [[ "$BRINGUP_READY" == "$ready" ]] || fail "$name BRINGUP_READY expected=${ready} actual=${BRINGUP_READY}"
  [[ "$NTP_SOURCE_CLASS" == "$source_class" ]] || fail "$name source expected=${source_class} actual=${NTP_SOURCE_CLASS}"
  if [[ "$TIME_READINESS" == "$expected" && "$BRINGUP_READY" == "$ready" && "$NTP_SOURCE_CLASS" == "$source_class" ]]; then
    pass "$name"
  fi
  if [[ "$ready" == YES && "$rc" -ne 0 ]] || [[ "$ready" == NO && "$rc" -eq 0 ]]; then
    fail "$name return code does not match readiness"
  fi
  rm -rf "$td"
}

P_PUBLIC='     remote           refid      st t when poll reach   delay   offset   jitter\n==============================================================================\n*time.google.com  .GOOG. 1 u 2 64 377 1.0 0.5 0.2\n'
R_SYNC='associd=0 status=0615 leap=00, stratum=2\n'
run_time_case "ntpwait success" PASS_SYNCED YES PUBLIC ntpwait_rc=0 "ntpq_p=$P_PUBLIC" "ntpq_rv=$R_SYNC"
run_time_case "selected peer plus leap=00" PASS_SYNCED YES PUBLIC ntpwait_rc=1 "ntpq_p=$P_PUBLIC" "ntpq_rv=$R_SYNC"
run_time_case "timedatectl synchronized with NTP service n/a" PASS_SYNCED YES UNKNOWN ntpwait_rc=1 \
  'timedatectl=System clock synchronized: yes\nNTP service: n/a\n' curl_fail=1
P_300='     remote           refid      st t when poll reach   delay   offset   jitter\n==============================================================================\n+10.1.1.5 .GPS. 1 u 2 64 377 1.0 300000.0 0.2\n'
run_time_case "unsynchronized skew exactly 300 seconds" PASS_WITH_WARNING YES INTERNAL ntpwait_rc=1 \
  "ntpq_p=$P_300" 'ntpq_rv=leap=11\n' 'timedatectl=System clock synchronized: no\n'
P_301='     remote           refid      st t when poll reach   delay   offset   jitter\n==============================================================================\n+10.1.1.5 .GPS. 1 u 2 64 377 1.0 301000.0 0.2\n'
run_time_case "clock skew over threshold" FAIL_CLOCK_SKEW NO INTERNAL ntpwait_rc=1 \
  "ntpq_p=$P_301" 'ntpq_rv=leap=11\n' 'timedatectl=System clock synchronized: no\n'
run_time_case "HTTP Date fallback" PASS_WITH_WARNING YES UNKNOWN ntpwait_rc=1 \
  'timedatectl=System clock synchronized: no\n' http_skew=120
run_time_case "time reference unavailable" FAIL_TIME_UNVERIFIABLE NO UNKNOWN ntpwait_rc=1 \
  'timedatectl=System clock synchronized: no\n' curl_fail=1

# Public-only NTP must remain ready and emit the warning-only contract.
td="$(mktemp -d)"; mkdir -p "$td/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$td/bin/ntpwait"
cat >"$td/bin/ntpq" <<MOCK
#!/usr/bin/env bash
if [[ "\${1:-}" == rv ]]; then printf '%b' '$R_SYNC'; else printf '%b' '$P_PUBLIC'; fi
MOCK
cat >"$td/bin/getent" <<'MOCK'
#!/usr/bin/env bash
printf '216.239.35.0 STREAM fixture\n'
MOCK
chmod +x "$td/bin"/*
set +e
PATH="$td/bin:$PATH" GETENT_BIN=getent NTPQ_BIN=ntpq NTPWAIT_BIN=ntpwait check_time_readiness >"$td/out" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 && "$NTP_SOURCE_CLASS" == PUBLIC && "$BRINGUP_READY" == YES ]] \
  && pass "public NTP only does not block" || fail "public NTP only blocked"
grep -q 'WARNING: no internal NTP source detected; continuing because local clock readiness passed' "$td/out" \
  && pass "public-only warning emitted" || fail "public-only warning missing"
rm -rf "$td"

# Active ntpsec configuration is also a source-class input even without ntpq output.
td="$(mktemp -d)"; mkdir -p "$td/etc/ntpsec"
printf 'server 192.168.50.20 iburst\npool pool.ntp.org iburst\n' >"$td/etc/ntpsec/ntp.conf"
DP_POSTBOOT_TEST_ROOT="$td" GETENT_BIN=getent classify_ntp_sources ""
[[ "$NTP_SOURCE_CLASS" == INTERNAL ]] && pass "ntp.conf internal source classification" || fail "ntp.conf source classification"
rm -rf "$td"; unset DP_POSTBOOT_TEST_ROOT

# Threshold accepts positive integers only.
td="$(mktemp -d)"; mkdir -p "$td/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$td/bin/ntpwait"; chmod +x "$td/bin/ntpwait"
set +e
PATH="$td/bin:$PATH" DP_MAX_CLOCK_SKEW_SECONDS=0 NTPWAIT_BIN=ntpwait check_time_readiness >"$td/out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 && "$BRINGUP_READY" == NO ]] && pass "invalid clock-skew threshold rejected" || fail "invalid threshold accepted"
grep -q 'must be a positive integer' "$td/out" && pass "invalid threshold diagnostic" || fail "invalid threshold diagnostic"
rm -rf "$td"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -e SC1091,SC2015,SC2034,SC2119,SC2120,SC2317 "$POSTBOOT_POLICY" "$STAGE" "$0" \
    && pass "shellcheck changed policy files" || fail "shellcheck changed policy files"
else
  printf 'WARNING: shellcheck not installed (SKIP)\n'
fi

if [[ "$FAIL" -eq 0 ]]; then
  printf 'ALL DNS/TIME READINESS POLICY TESTS PASSED\n'
  exit 0
fi
printf 'SOME DNS/TIME READINESS POLICY TESTS FAILED\n' >&2
exit 1
