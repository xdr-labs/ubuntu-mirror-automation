#!/usr/bin/env bash
# Structured package-transition evidence classification unit tests (all hops).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/client/lib/dp-offline-release-upgrade-reconciliation.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bash -n "$HELPER" || fail "helper bash -n"

EC_RESUME=29
EC_BUSY=22
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
STATE_FILE="${STATE_ROOT}/state"
LOG_FILE="/var/log/aella/offline_os_upgrade.log"

hostpath() {
  local p="$1"
  if [[ -n "${TEST_ROOT:-}" ]]; then printf '%s%s' "$TEST_ROOT" "$p"; else printf '%s' "$p"; fi
}
log() { local level="$1"; shift; printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >&2; }
die() { local code="$1"; shift; log ERROR "$* (exit=${code})"; exit "$code"; }
read_os_field() {
  local key="$1" f; f="$(hostpath /etc/os-release)"
  [[ -f "$f" ]] || { printf ''; return 0; }
  grep -E "^${key}=" "$f" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}
read_state() {
  local f; f="$(hostpath "$STATE_FILE")"
  if [[ -f "$f" ]]; then tr -d '\r' <"$f" | head -1; else printf ''; fi
}
pkg_installed_version() { printf ''; }
critical_holds_dir() { hostpath "${STATE_ROOT}/critical-holds"; }
atomic_write_file() { local dest="$1"; mkdir -p "$(dirname "$dest")"; cat >"$dest"; }
persist_release_upgrade_flags() { :; }
load_release_upgrade_started_flag() { :; }
detect_meta_release_encoding_failure_signature() { return 1; }

mkfx() {
  local hop="$1" src="$2" scode="$3"
  local fx
  fx="$(mktemp -d "${TMP}/${hop}.XXXX")"
  mkdir -p "$fx/etc" "$fx/opt/aelladata/os-upgrade/offline/critical-holds" \
    "$fx/var/log/apt" "$fx/var/log" "$fx/var/lib/dpkg" "$fx/tmp" \
    "$fx/etc/apt" "$fx/etc/update-manager" "$fx/var/log/aella"
  cat >"$fx/etc/os-release" <<EOF
VERSION_ID="${src}"
VERSION_CODENAME=${scode}
EOF
  printf 'FAILED\n' >"$fx/opt/aelladata/os-upgrade/offline/state"
  printf 'true\n' >"$fx/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_started"
  printf 'false\n' >"$fx/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
  printf 'Status: install ok installed\n' >"$fx/var/lib/dpkg/status"
  printf '%s\n' "$fx"
}

activate_hop() {
  PIN_HOP="$1"
  PIN_SOURCE_VERSION="$2"
  PIN_TARGET_VERSION="$3"
  PIN_SOURCE_CODENAME="$4"
  PIN_TARGET_CODENAME="$5"
  TEST_ROOT="$6"
  RELEASE_UPGRADE_STARTED="true"
  RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
  LEGACY_STATE_RECONCILED="false"
  RECONCILIATION_REASON=""
  CURRENT_RUN_ID=""
  # shellcheck disable=SC1090
  source "$HELPER"
}

# --- Boolean compatibility: legacy flag alone is NOT transition ---
fx="$(mkfx xenial-to-bionic 16.04 xenial)"
activate_hop xenial-to-bionic 16.04 18.04 xenial bionic "$fx"
if package_transition_evidence_present; then
  fail "legacy clean source must not present transition evidence"
fi
classify_package_transition_evidence
[[ "$PACKAGE_TRANSITION_CLASS" == "NONE" || "$PACKAGE_TRANSITION_CLASS" == "STALE_OR_PREBASELINE" ]] \
  || fail "unexpected class=$PACKAGE_TRANSITION_CLASS"
pass "boolean: legacy flag alone → no authoritative transition"

# --- Stale whole-file apt history without baseline ---
fx="$(mkfx bionic-to-focal 18.04 bionic)"
mkdir -p "$fx/var/log/apt"
cat >"$fx/var/log/apt/history.log" <<'EOF'
Start-Date: 2019-01-01  00:00:00
Commandline: do-release-upgrade
Upgrade: libc6:amd64 (2.27)
Install: something:amd64 (focal)
End-Date: 2019-01-01  00:01:00
EOF
activate_hop bionic-to-focal 18.04 20.04 bionic focal "$fx"
classify_package_transition_evidence
[[ "$PACKAGE_TRANSITION_CLASS" == "STALE_OR_PREBASELINE" ]] \
  || fail "expected STALE got $PACKAGE_TRANSITION_CLASS"
[[ "$AUTHORITATIVE_PACKAGE_TRANSITION" == "NO" ]] || fail "stale marked authoritative"
pass "stale apt history (no baseline) → STALE_OR_PREBASELINE"

# --- Post-baseline authoritative slice ---
fx="$(mkfx focal-to-jammy 20.04 focal)"
mkdir -p "$fx/var/log"
printf 'old unpack line that must be ignored\nstartup archives unpack\n' >"$fx/var/log/dpkg.log"
activate_hop focal-to-jammy 20.04 22.04 focal jammy "$fx"
record_release_upgrade_run_baseline
printf 'startup archives unpack\n' >>"$fx/var/log/dpkg.log"
classify_package_transition_evidence
[[ "$PACKAGE_TRANSITION_CLASS" == "AUTHORITATIVE_PACKAGE_TRANSITION" ]] \
  || fail "post-baseline expected AUTHORITATIVE got $PACKAGE_TRANSITION_CLASS"
package_transition_evidence_present || fail "boolean must be true for authoritative"
pass "post-baseline dpkg unpack → AUTHORITATIVE"

# A large post-baseline dpkg log is normal during a real release upgrade.
# A match near the start must not become invisible because grep -q closes
# its read end early while the producer is still writing under pipefail.
fx="$(mkfx focal-to-jammy 20.04 focal)"
activate_hop focal-to-jammy 20.04 22.04 focal jammy "$fx"
printf 'historical baseline\n' >"$fx/var/log/dpkg.log"
record_release_upgrade_run_baseline
python3 - "$fx/var/log/dpkg.log" <<'LARGE_DPKG_FIXTURE'
import sys
with open(sys.argv[1], "ab") as stream:
    stream.write(b"startup archives unpack\n")
    stream.write(b"unrelated dpkg status line\n" * 12000)
LARGE_DPKG_FIXTURE
classify_package_transition_evidence
[[ "$PACKAGE_TRANSITION_CLASS" == "AUTHORITATIVE_PACKAGE_TRANSITION" ]] \
  || fail "large post-baseline dpkg evidence must remain authoritative (got $PACKAGE_TRANSITION_CLASS)"
[[ "$AUTHORITATIVE_PACKAGE_TRANSITION" == "YES" ]] \
  || fail "long log must not clear authoritative package-transition state"
pass "large post-baseline dpkg log earliest authoritative event survives pipefail"

# --- Baseline inode rotation must not swallow whole new log ---
fx="$(mkfx jammy-to-noble 22.04 jammy)"
mkdir -p "$fx/var/log"
printf 'line1\n' >"$fx/var/log/dpkg.log"
activate_hop jammy-to-noble 22.04 24.04 jammy noble "$fx"
record_release_upgrade_run_baseline
# Simulate rotation: replace file (new inode), fill with old-looking content only.
rm -f "$fx/var/log/dpkg.log"
printf '2020-01-01 00:00:00 startup archives unpack\n' >"$fx/var/log/dpkg.log"
classify_package_transition_evidence
# Without matching RUN_STARTED timestamp, rotated old lines should not force AUTHORITATIVE.
[[ "$PACKAGE_TRANSITION_CLASS" != "AUTHORITATIVE_PACKAGE_TRANSITION" ]] \
  || fail "rotated old log classified authoritative"
pass "log rotation does not treat whole file as current mutation"

# --- Render includes required metadata keys ---
fx="$(mkfx xenial-to-bionic 16.04 xenial)"
activate_hop xenial-to-bionic 16.04 18.04 xenial bionic "$fx"
touch "$(hostpath ${STATE_ROOT}/force-upgrade-transaction-evidence)"
classify_package_transition_evidence
out="$(render_package_transition_evidence)"
grep -q 'EVIDENCE_TYPE=' <<<"$out" || fail "missing EVIDENCE_TYPE"
grep -q 'EVIDENCE_SOURCE=' <<<"$out" || fail "missing EVIDENCE_SOURCE"
grep -q 'EVIDENCE_PATH=' <<<"$out" || fail "missing EVIDENCE_PATH"
grep -q 'PIN_HOP=xenial-to-bionic' <<<"$out" || fail "missing PIN_HOP in render"
pass "render_package_transition_evidence metadata"

# --- Hop isolation: baselines live under hops/<PIN_HOP>/ ---
fx="$(mkfx xenial-to-bionic 16.04 xenial)"
activate_hop xenial-to-bionic 16.04 18.04 xenial bionic "$fx"
record_release_upgrade_run_baseline
[[ -d "$fx/opt/aelladata/os-upgrade/offline/hops/xenial-to-bionic/runs" ]] \
  || fail "missing hop-scoped runs dir"
# Second hop on same TEST_ROOT must not read first hop baseline as own.
activate_hop bionic-to-focal 18.04 20.04 bionic focal "$fx"
recon_load_baseline && fail "bionic hop must not load xenial baseline" || true
pass "hop-scoped baselines are isolated"

echo "EXACT_PACKAGE_EVIDENCE_TRIGGER_IDENTIFIED=YES"
echo "RUN_SCOPED_BASELINE=YES"
echo "LOG_INODE_OFFSET_TRACKING=YES"
echo "ALL test_xenial_package_transition_evidence checks passed"
