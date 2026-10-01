#!/usr/bin/env bash
# P1 regressions: dpkg audit must fail closed and OS-hop clients must serialize
# fresh-start destructive transactions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="${ROOT}/client/dp-offline-upgrade-xenial-to-bionic.sh"
DURABLE="${ROOT}/client/lib/dp-offline-durable-write.sh"
RECON="${ROOT}/client/lib/dp-offline-release-upgrade-reconciliation.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# 1) Common predicate: clean only when dpkg itself succeeds and emits nothing.
(
  # shellcheck disable=SC1090
  source "$DURABLE"
  dpkg() { return 0; }
  if dpkg_audit_has_issues; then
    exit 1
  fi
) || fail "clean dpkg audit was classified unsafe"
pass "clean dpkg audit is clean"

(
  # shellcheck disable=SC1090
  source "$DURABLE"
  dpkg() { return 42; }
  dpkg_audit_has_issues
) || fail "dpkg audit command failure was treated as clean"
pass "dpkg audit command failure fails closed"

(
  # shellcheck disable=SC1090
  source "$DURABLE"
  dpkg() {
    local i
    for i in $(seq 1 200000); do
      printf 'package-needs-audit-%s\n' "$i"
    done
  }
  dpkg_audit_has_issues
) || fail "large dirty dpkg audit was treated as clean"
pass "large dirty dpkg audit fails closed without SIGPIPE false-negative"

# The direct-source reconciliation helper has the same fallback contract.
(
  unset -f dpkg_audit_has_issues 2>/dev/null || true
  STATE_ROOT=/opt/aelladata/os-upgrade/offline
  PIN_HOP=xenial-to-bionic
  PIN_SOURCE_VERSION=16.04
  PIN_TARGET_VERSION=18.04
  PIN_SOURCE_CODENAME=xenial
  PIN_TARGET_CODENAME=bionic
  LOG_FILE=/tmp/unused.log
  TEST_ROOT=""
  hostpath() { printf '%s' "$1"; }
  # shellcheck disable=SC1090
  source "$RECON"
  dpkg() { return 42; }
  recon_dpkg_audit_has_issues
) || fail "reconciliation fallback treated dpkg audit failure as clean"
pass "reconciliation dpkg audit fallback fails closed"

if rg -n 'dpkg --audit 2>/dev/null \| grep -q \.' \
    "${ROOT}"/client/dp-offline-upgrade-*.sh.in \
    "${ROOT}"/client/dp-offline-upgrade-*.sh \
    "$RECON" >/tmp/dpkg-audit-pipe-regression.$$ 2>&1; then
  cat /tmp/dpkg-audit-pipe-regression.$$ >&2 || true
  rm -f /tmp/dpkg-audit-pipe-regression.$$
  fail "raw dpkg audit | grep -q safety pipeline remains"
fi
rm -f /tmp/dpkg-audit-pipe-regression.$$
pass "all OS-hop dpkg audit gates avoid grep-q pipelines"

# A caller-supplied environment value must never spoof lock ownership. The
# helper resets inherited lock state and validates any reused descriptor against
# the exact runtime lock path before accepting it.
(
  lock_root="$(mktemp -d)"
  trap 'rm -rf "$lock_root"' EXIT
  TEST_ROOT="$lock_root"
  STATE_ROOT=/opt/aelladata/os-upgrade/offline
  PIN_HOP=xenial-to-bionic
  PIN_SOURCE_VERSION=16.04
  PIN_TARGET_VERSION=18.04
  PIN_SOURCE_CODENAME=xenial
  PIN_TARGET_CODENAME=bionic
  LOG_FILE=/tmp/unused.log
  CLIENT_EXECUTION_LOCK_FD=1
  CLIENT_EXECUTION_LOCK_PATH=/tmp/not-the-lock
  hostpath() { printf '%s%s' "$TEST_ROOT" "$1"; }
  log() { :; }
  # shellcheck disable=SC1090
  source "$RECON"
  [[ -z "$CLIENT_EXECUTION_LOCK_FD" ]] || exit 1
  client_execution_lock_acquire || exit 1
  fd="$CLIENT_EXECUTION_LOCK_FD"
  actual="$(readlink -f "/proc/self/fd/${fd}")"
  expected="$(readlink -f "$TEST_ROOT/run/lock/stellar-offline-os-upgrade-client.lock")"
  [[ "$actual" == "$expected" ]] || exit 1
  client_execution_lock_release
) || fail "caller-supplied lock FD/path spoofed execution-lock ownership"
pass "execution lock ignores inherited FD/path spoofing"

# 2) Dynamic concurrency regression. Two fresh clients against the same
# root must never both enter commit. The loser must fail at the shared flock,
# and it must not roll back the winner's persistent source configuration.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p \
  "$TMP/etc/apt/sources.list.d" \
  "$TMP/etc/apt/apt.conf.d" \
  "$TMP/etc/update-manager" \
  "$TMP/etc/systemd/system" \
  "$TMP/opt/aelladata" \
  "$TMP/var/log/aella" \
  "$TMP/usr/local/sbin" \
  "$TMP/tmp" \
  "$TMP/boot" \
  "$TMP/var/lib/dpkg/updates"

cat >"$TMP/etc/os-release" <<'EOF'
NAME="Ubuntu"
VERSION_ID="16.04"
VERSION_CODENAME=xenial
PRETTY_NAME="Ubuntu 16.04.7 LTS"
EOF
cat >"$TMP/opt/aelladata/release-metadata.yml" <<'EOF'
version: 1591228779
role: aio
EOF
cat >"$TMP/opt/aelladata/release-image.yml" <<'EOF'
aella-cm-bg: 6.2.0.1-aaaaaaaa
aella-cm-master: 6.2.0.1-aaaaaaaa
EOF
printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1000:1000:aella:/home/aella:/bin/bash\n' \
  >"$TMP/etc/passwd"
printf 'deb http://archive.ubuntu.com/ubuntu xenial main\n' >"$TMP/etc/apt/sources.list"
printf 'deb http://ppa.launchpad.net/example/ppa/ubuntu xenial main\n' \
  >"$TMP/etc/apt/sources.list.d/example-ppa.list"
cat >"$TMP/etc/update-manager/release-upgrades" <<'EOF'
[DEFAULT]
Prompt=normal
EOF
cat >"$TMP/etc/update-manager/meta-release" <<'EOF'
[METARELEASE]
URI = http://changelogs.ubuntu.com/meta-release
URI_LTS = http://changelogs.ubuntu.com/meta-release-lts
EOF

run_client() {
  local id="$1"
  set +e
  MM_HERMETIC_TEST_MODE=1 \
  DP_OFFLINE_TEST_ROOT="$TMP" \
  DP_OFFLINE_FAKE_DP_VERSION=6.2.0 \
  DP_OFFLINE_FAKE_ROLE=AIO \
  DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  DP_OFFLINE_FAKE_CONFIRM=UPGRADE-XENIAL-TO-BIONIC \
    bash "$CLIENT" --mirror-base http://192.0.2.10 >"$TMP/out.$id" 2>&1
  local rc=$?
  set -e
  printf '%s\n' "$rc" >"$TMP/rc.$id"
}

run_client A &
pa=$!
run_client B &
pb=$!
wait "$pa" || true
wait "$pb" || true

rc_a="$(cat "$TMP/rc.A")"
rc_b="$(cat "$TMP/rc.B")"
if [[ "$rc_a" == "0" && "$rc_b" == "22" ]]; then
  winner=A; loser=B
elif [[ "$rc_b" == "0" && "$rc_a" == "22" ]]; then
  winner=B; loser=A
else
  echo "A_RC=$rc_a B_RC=$rc_b" >&2
  tail -40 "$TMP/out.A" >&2 || true
  tail -40 "$TMP/out.B" >&2 || true
  fail "concurrent fresh clients were not serialized as one success plus EC_BUSY"
fi
grep -q 'CLIENT_EXECUTION_LOCK=BUSY' "$TMP/out.$loser" \
  || fail "concurrent loser did not report execution-lock contention"
pass "concurrent fresh clients serialize at execution lock"

grep -q '192.0.2.10/hops/xenial-to-bionic/ubuntu' "$TMP/etc/apt/sources.list" \
  || fail "winner local mirror source was rolled back"
if grep -RqiE 'archive\.ubuntu\.com|security\.ubuntu\.com|ppa\.launchpad\.net' \
    "$TMP/etc/apt/sources.list" "$TMP/etc/apt/sources.list.d" 2>/dev/null; then
  fail "loser rollback restored external apt source after winner success"
fi
[[ ! -f "$TMP/etc/apt/sources.list.d/example-ppa.list" ]] \
  || fail "loser rollback restored third-party PPA after winner success"
[[ "$(cat "$TMP/opt/aelladata/os-upgrade/offline/state")" == "CONFIGURING" ]] \
  || fail "unexpected final hermetic state"
pass "loser cannot roll back winner persistent configuration"

lock="$TMP/run/lock/stellar-offline-os-upgrade-client.lock"
[[ -f "$lock" ]] || fail "shared execution lock file missing"
flock -n "$lock" true || fail "execution lock remained held after clients exited"
pass "execution lock releases automatically after client exit"

# Every hop must acquire the same runtime lock before handle_existing_state.
for f in "${ROOT}"/client/dp-offline-upgrade-*.sh.in; do
  grep -q 'client_execution_lock_acquire' "$f" \
    || fail "$(basename "$f") missing execution lock"
  grep -q 'CLIENT_EXECUTION_LOCK=BUSY path=/run/lock/stellar-offline-os-upgrade-client.lock' "$f" \
    || fail "$(basename "$f") missing common lock identity"
done
pass "all four hop templates use the shared execution lock"

echo "TEST_DP_CLIENT_P1_SAFETY=PASS"
