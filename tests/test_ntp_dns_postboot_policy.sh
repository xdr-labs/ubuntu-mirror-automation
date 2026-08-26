#!/usr/bin/env bash
# Fixture tests: Jammy→Noble DNS repair + Phase 2 time readiness policy.
# Never mutates real /etc/resolv.conf, systemd, or network interfaces.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/ntp-dns-policy.XXXX")"
trap 'rm -rf "$OUT"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

J2N_IN="${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh.in"
STAGE="${ROOT}/client/stage-dp-phase2.sh"
POSTBOOT_POLICY="${ROOT}/client/dp-postboot-readiness-policy.sh.inc"
X2B_IN="${ROOT}/client/dp-offline-upgrade-xenial-to-bionic.sh.in"
B2F_IN="${ROOT}/client/dp-offline-upgrade-bionic-to-focal.sh.in"
F2J_IN="${ROOT}/client/dp-offline-upgrade-focal-to-jammy.sh.in"

[[ -f "$J2N_IN" && -f "$STAGE" && -f "$POSTBOOT_POLICY" ]] || { echo "missing sources"; exit 1; }

bash -n "$POSTBOOT_POLICY" || { echo "postboot policy syntax error"; exit 1; }

# Hop isolation: other hops must not gain this postboot DNS repair policy.
other_ok=1
for hop_in in "$X2B_IN" "$B2F_IN" "$F2J_IN"; do
  if rg -q 'BEGIN_DP_POSTBOOT_DNS_TIME_POLICY|check_and_repair_dns_resolver|TIME_READINESS=PASS_WITH_WARNING|@@POSTBOOT_POLICY_LIB@@' "$hop_in"; then
    fail "hop-isolation: unexpected DNS/time policy in $(basename "$hop_in")"
    other_ok=0
  fi
done
[[ "$other_ok" -eq 1 ]] && pass "hop-isolation: other 3 hops unchanged"

# Phase 1 OS-only: preflight must not hard-gate on NTP sync alone.
if grep -q 'NTP_SYNC=UNCONFIRMED (informational; not a Phase 1 hard gate)' "$J2N_IN" \
  && grep -q 'TIME_READINESS=PREFLIGHT_INFORMATIONAL_ONLY' "$J2N_IN"; then
  pass "Phase 1 OS-only NTP sync remains non-blocking"
else
  fail "Phase 1 NTP informational policy missing"
fi

# Builder/single-file contract.
grep -q '@@POSTBOOT_POLICY_LIB@@' "$J2N_IN" \
  && pass "Jammy→Noble template has postboot policy placeholder" \
  || fail "missing @@POSTBOOT_POLICY_LIB@@ placeholder"
grep -q 'dp-postboot-readiness-policy.sh.inc' "${ROOT}/scripts/lib/build_client_jammy_to_noble.py" \
  && pass "builder loads postboot policy include" \
  || fail "builder missing postboot policy include"

# NTP quiesce / staging artifact-only contracts preserved.
grep -q 'ensure_legacy_ntp_quiesced_before_package_transition' "$J2N_IN" \
  && pass "NTP quiesce patch retained" || fail "NTP quiesce missing"
grep -q 'NEVER runs bringup\|Does NOT execute bringup\|BRINGUP_EXECUTED="NO"' "$STAGE" \
  && pass "Phase 2 staging still does not execute bringup" || fail "bringup contract broken"
grep -q 'check_ntp_bringup_readiness || true' "$STAGE" \
  && pass "staging survives time-not-ready" || fail "staging hard-fails on time readiness"

# Postboot order: DNS before COMPLETED_NOBLE; time before COMPLETED_NOBLE.
if grep -q 'check_and_repair_dns_resolver' "$J2N_IN" \
  && grep -q 'check_time_readiness' "$J2N_IN" \
  && grep -q 'not recording COMPLETED_NOBLE' "$J2N_IN"; then
  pass "postboot records COMPLETED_NOBLE only after DNS+time"
else
  fail "postboot COMPLETED_NOBLE ordering markers missing"
fi

# No hardcoded public DNS in repair path.
if grep -nE '8\.8\.8\.8|1\.1\.1\.1|9\.9\.9\.9' "$POSTBOOT_POLICY" | grep -viE 'comment|#'; then
  fail "hardcoded public DNS in policy lib"
else
  pass "no hardcoded public DNS in repair lib"
fi

# DNS repair must not restart NICs / reboot / bringup (ignore comments).
if rg -n '^\s*(ifdown|ifup|reboot|shutdown)\b|systemctl restart networking|ip link set|bringup_py3' "$POSTBOOT_POLICY"; then
  fail "DNS lib must not restart network/reboot/bringup"
else
  pass "DNS repair avoids NIC restart/reboot/bringup"
fi

# shellcheck source=../client/dp-postboot-readiness-policy.sh.inc
source "$POSTBOOT_POLICY"

make_dns_fixture() {
  FIX="$(mktemp -d "${OUT}/dns.XXXX")"
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

# =============================================================================
# DNS fixture cases (via dp-postboot-readiness-policy.sh.inc)
# =============================================================================

make_dns_fixture
ln -s ../run/systemd/resolve/stub-resolv.conf "$FIX/etc/resolv.conf"
printf 'nameserver 127.0.0.53\n' >"$FIX/run/systemd/resolve/stub-resolv.conf"
printf 'active\n' >"$FIX/state/active"; printf 'enabled\n' >"$FIX/state/enabled"
check_and_repair_dns_resolver >/dev/null
[[ "$DNS_RESOLVER_STATE" == "HEALTHY_SYSTEMD_RESOLVED" && "$DNS_RESOLVER_REPAIR" == "NOT_REQUIRED" ]] \
  && pass "DNS healthy systemd-resolved no-op" || fail "DNS healthy systemd-resolved"
cleanup_dns_fixture

make_dns_fixture
printf 'nameserver 10.0.0.53\n' >"$FIX/etc/resolv.conf"
check_and_repair_dns_resolver >/dev/null
[[ "$DNS_RESOLVER_STATE" == "HEALTHY_STATIC" && "$DNS_RESOLVER_REPAIR" == "NOT_REQUIRED" ]] \
  && pass "DNS healthy static no-op" || fail "DNS healthy static"
[[ ! -e "$FIX/etc/systemd/resolved.conf.d/20-dp-static-dns.conf" ]] \
  && pass "static resolver not modified" || fail "static resolver modified"
cleanup_dns_fixture

make_dns_fixture
rm -f "$FIX/run/systemd/resolve/stub-resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$FIX/etc/resolv.conf"
printf 'auto eth0\niface eth0 inet static\n  dns-nameservers 10.50.1.10 10.50.1.11\n' >"$FIX/etc/network/interfaces"
check_and_repair_dns_resolver >/dev/null
[[ "$DNS_RESOLVER_REPAIR" == "PASS" && "$DNS_RESOLVER_STATE" == "RECOVERED_SYSTEMD_RESOLVED" ]] \
  && pass "DNS broken stub auto-repair with internal DNS" || fail "DNS auto-repair internal"
grep -q 'DNS=10.50.1.10 10.50.1.11' "$FIX/etc/systemd/resolved.conf.d/20-dp-static-dns.conf" \
  && pass "internal DNS dynamic from interfaces" || fail "internal DNS drop-in"
[[ "$(readlink "$FIX/etc/resolv.conf")" == "../run/systemd/resolve/stub-resolv.conf" ]] \
  && pass "resolv.conf symlink unchanged" || fail "resolv.conf symlink changed"
cleanup_dns_fixture

make_dns_fixture
ln -s ../run/systemd/resolve/stub-resolv.conf "$FIX/etc/resolv.conf"
printf 'auto eth0\niface eth0 inet dhcp\n' >"$FIX/etc/network/interfaces"
set +e; check_and_repair_dns_resolver >/dev/null; rc=$?; set -e
[[ "$rc" -ne 0 && "$DNS_RESOLVER_REPAIR" == "FAIL" ]] \
  && pass "DNS broken stub without DNS config FAIL no mutation" || fail "DNS no-config FAIL"
[[ ! -e "$FIX/etc/systemd/resolved.conf.d/20-dp-static-dns.conf" ]] \
  && pass "missing-DNS no mutation" || fail "missing-DNS mutation"
cleanup_dns_fixture

make_dns_fixture
mkdir -p "$FIX/run/foo"
ln -s ../run/foo/other-resolv.conf "$FIX/etc/resolv.conf"
printf 'nameserver 1.2.3.4\n' >"$FIX/run/foo/other-resolv.conf"
check_and_repair_dns_resolver >/dev/null
[[ "$DNS_RESOLVER_STATE" == "UNKNOWN_LAYOUT" && "$DNS_RESOLVER_REPAIR" == "NOT_ATTEMPTED" ]] \
  && pass "DNS unknown layout no mutation" || fail "DNS unknown layout"
cleanup_dns_fixture

make_dns_fixture
ln -s ../run/systemd/resolve/stub-resolv.conf "$FIX/etc/resolv.conf"
printf 'iface eth0 inet static\n  dns-nameservers 10.9.9.9\n' >"$FIX/etc/network/interfaces"
export DNS_TEST_RESOLVE=fail
set +e; check_and_repair_dns_resolver >/dev/null; rc=$?; set -e
[[ "$rc" -ne 0 && "$DNS_RESOLVER_REPAIR" == "FAIL" ]] \
  && pass "DNS repair rollback on resolution failure" || fail "DNS repair rollback"
[[ ! -e "$FIX/etc/systemd/resolved.conf.d/20-dp-static-dns.conf" ]] \
  && pass "rollback removes generated drop-in" || fail "rollback drop-in"
[[ "$(cat "$FIX/state/enabled")" == masked && "$(cat "$FIX/state/active")" == inactive ]] \
  && pass "rollback restores masked/inactive" || fail "rollback service state"
cleanup_dns_fixture

make_dns_fixture
ln -s ../run/systemd/resolve/stub-resolv.conf "$FIX/etc/resolv.conf"
printf 'iface eth0 inet static\n  dns-nameservers 8.8.8.8 8.8.4.4\n' >"$FIX/etc/network/interfaces"
check_and_repair_dns_resolver >/dev/null
[[ "$DNS_RESOLVER_REPAIR" == "PASS" ]] \
  && pass "DNS repair with public addresses from interfaces" || fail "DNS public from interfaces"
grep -q 'DNS=8.8.8.8 8.8.4.4' "$FIX/etc/systemd/resolved.conf.d/20-dp-static-dns.conf" \
  && pass "public DNS written from interfaces" || fail "public DNS drop-in"
cleanup_dns_fixture

make_dns_fixture
ln -s ../run/systemd/resolve/stub-resolv.conf "$FIX/etc/resolv.conf"
printf 'nameserver 127.0.0.53\n' >"$FIX/run/systemd/resolve/stub-resolv.conf"
printf 'active\n' >"$FIX/state/active"; printf 'enabled\n' >"$FIX/state/enabled"
printf 'iface eth0 inet static\n  dns-nameservers 10.1.1.1\n' >"$FIX/etc/network/interfaces"
check_and_repair_dns_resolver >/dev/null
s1="$DNS_RESOLVER_STATE"
check_and_repair_dns_resolver >/dev/null
s2="$DNS_RESOLVER_STATE"
[[ "$s1" == "HEALTHY_SYSTEMD_RESOLVED" && "$s2" == "HEALTHY_SYSTEMD_RESOLVED" ]] \
  && pass "DNS check idempotent on healthy resolved" || fail "DNS idempotent"
cleanup_dns_fixture

# =============================================================================
# Time readiness via stage-dp-phase2.sh (LIB_ONLY)
# =============================================================================
export DP_PHASE2_STAGE_LIB_ONLY=1
# shellcheck disable=SC1090
source "$STAGE"

ntpq_selected=$'     remote           refid      st t when poll reach   delay   offset  jitter\n==============================================================================\n*10.1.2.3        LOCAL            1 u  10  64  377    0.100    0.500   0.200\n'
ntpq_public=$'     remote           refid      st t when poll reach   delay   offset  jitter\n==============================================================================\n*216.239.35.0    .GOOG.           1 u  10  64  377   10.000    1.000   0.500\n'
ntpq_skew_ok=$'     remote           refid      st t when poll reach   delay   offset  jitter\n==============================================================================\n+10.1.2.3        LOCAL            1 u  10  64  377    0.100  120000.0  0.200\n'
ntpq_skew_bad=$'     remote           refid      st t when poll reach   delay   offset  jitter\n==============================================================================\n+10.1.2.3        LOCAL            1 u  10  64  377    0.100  400000.0  0.200\n'

(
  unset DP_PHASE2_FAKE_NTPQ_PN DP_PHASE2_FAKE_NTPQ_RV DP_PHASE2_FAKE_TIMEDATECTL
  unset DP_PHASE2_FAKE_HTTP_DATE_EPOCH DP_PHASE2_FAKE_LOCAL_EPOCH
  export DP_PHASE2_FAKE_NTPWAIT_RC=0
  export DP_PHASE2_FAKE_NTPQ_PN="$ntpq_public"
  export DP_PHASE2_FAKE_NTP_CONF="/nonexistent"
  check_ntp_bringup_readiness
  [[ "$TIME_READINESS" == "PASS_SYNCED" && "$BRINGUP_READY" == "YES" ]]
) && pass "time: ntpwait → PASS_SYNCED" || fail "time: ntpwait"

(
  export DP_PHASE2_FAKE_NTPWAIT_RC=1
  export DP_PHASE2_FAKE_NTPQ_PN="$ntpq_selected"
  export DP_PHASE2_FAKE_NTPQ_RV="associd=0 status=0x0000 leap=00, stratum=3"
  export DP_PHASE2_FAKE_TIMEDATECTL=$'System clock synchronized: no\nNTP service: n/a\n'
  export DP_PHASE2_FAKE_NTP_CONF="/nonexistent"
  check_ntp_bringup_readiness
  [[ "$TIME_READINESS" == "PASS_SYNCED" && "$BRINGUP_READY" == "YES" ]]
  [[ "$NTP_SOURCE_CLASS" == "INTERNAL" ]]
) && pass "time: selected peer + leap=00 → PASS_SYNCED" || fail "time: selected+leap"

(
  export DP_PHASE2_FAKE_NTPWAIT_RC=1
  export DP_PHASE2_FAKE_NTPQ_PN=""
  export DP_PHASE2_FAKE_NTPQ_RV=""
  export DP_PHASE2_FAKE_TIMEDATECTL=$'System clock synchronized: yes\nNTP service: n/a\n'
  export DP_PHASE2_FAKE_NTP_CONF="/nonexistent"
  check_ntp_bringup_readiness
  [[ "$TIME_READINESS" == "PASS_SYNCED" && "$BRINGUP_READY" == "YES" ]]
) && pass "time: timedatectl sync + n/a → PASS_SYNCED" || fail "time: timedatectl n/a"

(
  export DP_PHASE2_FAKE_NTPWAIT_RC=1
  export DP_PHASE2_FAKE_NTPQ_PN="$ntpq_skew_ok"
  export DP_PHASE2_FAKE_NTPQ_RV="leap=11"
  export DP_PHASE2_FAKE_TIMEDATECTL=$'System clock synchronized: no\nNTP service: n/a\n'
  export DP_PHASE2_FAKE_NTP_CONF="/nonexistent"
  unset DP_MAX_CLOCK_SKEW_SECONDS
  check_ntp_bringup_readiness
  [[ "$TIME_READINESS" == "PASS_WITH_WARNING" && "$BRINGUP_READY" == "YES" ]]
  [[ "$CLOCK_SKEW_SECONDS" -le 300 ]]
) && pass "time: skew≤300 → PASS_WITH_WARNING" || fail "time: skew ok"

(
  export DP_PHASE2_FAKE_NTPWAIT_RC=1
  export DP_PHASE2_FAKE_NTPQ_PN="$ntpq_skew_bad"
  export DP_PHASE2_FAKE_NTPQ_RV="leap=11"
  export DP_PHASE2_FAKE_TIMEDATECTL=$'System clock synchronized: no\nNTP service: n/a\n'
  export DP_PHASE2_FAKE_NTP_CONF="/nonexistent"
  check_ntp_bringup_readiness
  [[ "$TIME_READINESS" == "FAIL_CLOCK_SKEW" && "$BRINGUP_READY" == "NO" ]]
) && pass "time: skew>300 → FAIL_CLOCK_SKEW" || fail "time: skew bad"

(
  export DP_PHASE2_FAKE_NTPWAIT_RC=1
  export DP_PHASE2_FAKE_NTPQ_PN=""
  export DP_PHASE2_FAKE_NTPQ_RV=""
  export DP_PHASE2_FAKE_TIMEDATECTL=$'System clock synchronized: no\nNTP service: n/a\n'
  export DP_PHASE2_FAKE_NTP_CONF="/nonexistent"
  unset DP_PHASE2_FAKE_HTTP_DATE_EPOCH DP_PHASE2_FAKE_LOCAL_EPOCH
  export DP_PHASE2_FAKE_HTTP_DATE_EPOCH="not-an-epoch"
  check_ntp_bringup_readiness
  [[ "$TIME_READINESS" == "FAIL_TIME_UNVERIFIABLE" && "$BRINGUP_READY" == "NO" ]]
) && pass "time: no reference → FAIL_TIME_UNVERIFIABLE" || fail "time: unverifiable"

(
  export DP_PHASE2_FAKE_NTPWAIT_RC=1
  export DP_PHASE2_FAKE_NTPQ_PN="$ntpq_public"
  export DP_PHASE2_FAKE_NTPQ_RV="leap=00 status=0x0000"
  export DP_PHASE2_FAKE_TIMEDATECTL=$'System clock synchronized: no\nNTP service: n/a\n'
  export DP_PHASE2_FAKE_NTP_CONF="/nonexistent"
  out="$(check_ntp_bringup_readiness 2>&1)"
  [[ "$TIME_READINESS" == "PASS_SYNCED" && "$BRINGUP_READY" == "YES" ]]
  [[ "$NTP_SOURCE_CLASS" == "PUBLIC" ]]
  [[ "$INTERNAL_NTP_REQUIREMENT" == "NOT_SATISFIED" ]]
  printf '%s\n' "$out" | grep -q 'WARNING: no internal NTP source detected'
) && pass "time: public NTP only warns but BRINGUP_READY=YES" || fail "time: public NTP"

(
  export DP_PHASE2_FAKE_NTPWAIT_RC=1
  export DP_PHASE2_FAKE_NTPQ_PN=""
  export DP_PHASE2_FAKE_NTPQ_RV=""
  export DP_PHASE2_FAKE_TIMEDATECTL=$'System clock synchronized: no\nNTP service: inactive\n'
  export DP_PHASE2_FAKE_NTP_CONF="/nonexistent"
  export DP_PHASE2_FAKE_HTTP_DATE_EPOCH=1000000
  export DP_PHASE2_FAKE_LOCAL_EPOCH=1000100
  check_ntp_bringup_readiness
  [[ "$TIME_READINESS" == "PASS_WITH_WARNING" && "$BRINGUP_READY" == "YES" ]]
  [[ "$INTERNAL_NTP_REQUIREMENT" == "NOT_SATISFIED" ]]
) && pass "time: no internal NTP alone does not fail" || fail "time: no internal only"

(
  TARGET_DP_VERSION=6.6.0
  BRINGUP_SCRIPT=/home/aella/bringup_py3_dp_after_os_upgrade.sh
  TIME_READINESS=PASS_WITH_WARNING
  BRINGUP_READY=YES
  CLOCK_SKEW_SECONDS=12
  MAX_CLOCK_SKEW_SECONDS=300
  NTP_SOURCE_CLASS=PUBLIC
  NTP_SELECTED_PEER=""
  INTERNAL_NTP_REQUIREMENT=NOT_SATISFIED
  NTP_BRINGUP_READINESS=PASS
  PHASE2_STAGE_RESULT=PASS
  BRINGUP_EXECUTED=NO
  ARTIFACT_CACHE_RESULT=HIT
  ARTIFACT_CHECKSUM_RESULT=PASS
  SOURCE_DP_VERSION=6.4.0
  SOURCE_DP_VERSION_RAW=6.4.0
  SOURCE_DP_VERSION_ORIGIN=test
  SOURCE_DP_VERSION_CHECK=PASS
  PHASE2_ARTIFACT_VERSION=6.6.0
  TARGET_VERSION_COMPATIBILITY=PASS
  AELLA_UID=1000
  AELLA_PRIMARY_GID=1000
  AELLA_PRIMARY_GROUP=aella
  AELLA_OWNERSHIP_CHECK=PASS
  ARTIFACT_DIR=/opt/aelladata/aelladeb_py3
  rep="$(emit_final_report)"
  printf '%s\n' "$rep" | grep -q '^NEXT_COMMAND=sudo bash'
  printf '%s\n' "$rep" | grep -q '^TIME_READINESS=PASS_WITH_WARNING'
  printf '%s\n' "$rep" | grep -q '^BRINGUP_EXECUTED=NO'
) && pass "report: NEXT_COMMAND on PASS_WITH_WARNING" || fail "report NEXT_COMMAND"

(
  export DP_PHASE2_FAKE_NTPWAIT_RC=1
  export DP_PHASE2_FAKE_NTPQ_PN=""
  export DP_PHASE2_FAKE_NTPQ_RV="sync_unspec, leap=11"
  export DP_PHASE2_FAKE_TIMEDATECTL=$'System clock synchronized: yes\nNTP service: n/a\n'
  export DP_PHASE2_FAKE_NTP_CONF="/nonexistent"
  check_ntp_bringup_readiness
  [[ "$TIME_READINESS" == "PASS_SYNCED" ]]
) && pass "time: sync_unspec alone does not fail" || fail "time: sync_unspec"

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL NTP/DNS POSTBOOT POLICY CHECKS PASSED (${PASS})"
  exit 0
fi
echo "SOME NTP/DNS POSTBOOT POLICY CHECKS FAILED (pass=${PASS} fail=${FAIL})"
exit 1
