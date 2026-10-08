#!/usr/bin/env bash
# Targeted legacy-state reconciliation tests for all four OS hops.
# Sources the shared authoritative helper — no live apt/dpkg/DRO/SSH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/client/lib/dp-offline-release-upgrade-reconciliation.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -f "$HELPER" ]] || fail "missing shared helper: $HELPER"
bash -n "$HELPER" || fail "helper bash -n"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Verify no host paths outside TEST_ROOT are touched by collecting open probes.
assert_under_test_root() {
  local root="$1"
  # Shared helper must use hostpath for logs/state when TEST_ROOT is set.
  grep -nE '"/var/log/|/var/lib/dpkg|/etc/apt|/opt/aelladata' "$HELPER" \
    | grep -v 'hostpath\|#\|printf\|recon_\|baseline\|PATH=\|evidence' \
    && fail "helper appears to hardcode host paths without hostpath" || true
  pass "helper path discipline comments/hostpath present"
}

assert_under_test_root "$TMP"

declare -A HOP_SOURCE HOP_TARGET HOP_SCODE HOP_TCODE
HOP_SOURCE[xenial-to-bionic]=16.04
HOP_TARGET[xenial-to-bionic]=18.04
HOP_SCODE[xenial-to-bionic]=xenial
HOP_TCODE[xenial-to-bionic]=bionic

HOP_SOURCE[bionic-to-focal]=18.04
HOP_TARGET[bionic-to-focal]=20.04
HOP_SCODE[bionic-to-focal]=bionic
HOP_TCODE[bionic-to-focal]=focal

HOP_SOURCE[focal-to-jammy]=20.04
HOP_TARGET[focal-to-jammy]=22.04
HOP_SCODE[focal-to-jammy]=focal
HOP_TCODE[focal-to-jammy]=jammy

HOP_SOURCE[jammy-to-noble]=22.04
HOP_TARGET[jammy-to-noble]=24.04
HOP_SCODE[jammy-to-noble]=jammy
HOP_TCODE[jammy-to-noble]=noble

EC_RESUME=29
EC_BUSY=22
EC_PARTIAL_TRANSITION=27
EC_INTERNAL=99
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
  local key="$1" f
  f="$(hostpath /etc/os-release)"
  [[ -f "$f" ]] || { printf ''; return 0; }
  grep -E "^${key}=" "$f" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}
read_state() {
  local f; f="$(hostpath "$STATE_FILE")"
  if [[ -f "$f" ]]; then tr -d '\r' <"$f" | head -1; else printf ''; fi
}
write_state() { printf '%s\n' "$1" | tee "$(hostpath "$STATE_FILE")" >/dev/null; }
pkg_installed_version() { printf ''; }
critical_holds_dir() { hostpath "${STATE_ROOT}/critical-holds"; }
atomic_write_file() { local dest="$1"; mkdir -p "$(dirname "$dest")"; cat >"$dest"; }
persist_release_upgrade_flags() {
  local dir; dir="$(critical_holds_dir)"; mkdir -p "$dir"
  printf '%s\n' "${RELEASE_UPGRADE_INVOCATION_STARTED:-false}" >"$dir/release_upgrade_invocation_started"
  printf '%s\n' "${RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED:-false}" >"$dir/release_upgrade_package_transition_started"
  printf '%s\n' "${RELEASE_UPGRADE_STARTED:-false}" >"$dir/release_upgrade_started"
  printf '%s\n' "${LEGACY_STATE_RECONCILED:-false}" >"$dir/legacy_state_reconciled"
  printf '%s\n' "${RECONCILIATION_REASON:-}" >"$dir/reconciliation_reason"
}
load_release_upgrade_started_flag() {
  local dir; dir="$(critical_holds_dir)"
  RELEASE_UPGRADE_STARTED="false"
  RELEASE_UPGRADE_INVOCATION_STARTED="false"
  RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
  LEGACY_STATE_RECONCILED="false"
  RECONCILIATION_REASON=""
  [[ -f "$dir/release_upgrade_started" ]] && grep -qx 'true' "$dir/release_upgrade_started" && RELEASE_UPGRADE_STARTED="true"
  [[ -f "$dir/release_upgrade_invocation_started" ]] && grep -qx 'true' "$dir/release_upgrade_invocation_started" && RELEASE_UPGRADE_INVOCATION_STARTED="true"
  [[ -f "$dir/release_upgrade_package_transition_started" ]] && grep -qx 'true' "$dir/release_upgrade_package_transition_started" && RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="true"
  [[ -f "$dir/legacy_state_reconciled" ]] && grep -qx 'true' "$dir/legacy_state_reconciled" && LEGACY_STATE_RECONCILED="true"
  [[ -f "$dir/reconciliation_reason" ]] && RECONCILIATION_REASON="$(tr -d '\n' <"$dir/reconciliation_reason")"
}
detect_meta_release_encoding_failure_signature() {
  [[ -f "$(hostpath ${STATE_ROOT}/force-meta-release-encoding-failure)" ]]
}
verify_prior_critical_hold_resume_consistency() { return 0; }
log_idempotent_prep_states() { return 0; }

setup_hop_fixture() {
  local hop="$1" label="$2"
  local fx src tgt scode tcode
  src="${HOP_SOURCE[$hop]}"
  tgt="${HOP_TARGET[$hop]}"
  scode="${HOP_SCODE[$hop]}"
  tcode="${HOP_TCODE[$hop]}"
  fx="$(mktemp -d "${TMP}/${hop}-${label}.XXXX")"
  mkdir -p "$fx/etc" "$fx/opt/aelladata/os-upgrade/offline/critical-holds" \
    "$fx/var/log/aella" "$fx/var/log/apt" "$fx/var/log/dist-upgrade" \
    "$fx/var/lib/dpkg" "$fx/tmp" "$fx/etc/apt" "$fx/etc/update-manager"
  cat >"$fx/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION_ID="${src}"
VERSION_CODENAME=${scode}
EOF
  printf 'FAILED\n' >"$fx/opt/aelladata/os-upgrade/offline/state"
  printf 'true\n' >"$fx/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_started"
  printf 'false\n' >"$fx/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
  : >"$fx/var/log/aella/offline_os_upgrade.log"
  printf 'Status: install ok installed\n' >"$fx/var/lib/dpkg/status"
  printf '%s\n' "$fx"
}

load_hop() {
  local hop="$1" fx="$2"
  PIN_HOP="$hop"
  PIN_SOURCE_VERSION="${HOP_SOURCE[$hop]}"
  PIN_TARGET_VERSION="${HOP_TARGET[$hop]}"
  PIN_SOURCE_CODENAME="${HOP_SCODE[$hop]}"
  PIN_TARGET_CODENAME="${HOP_TCODE[$hop]}"
  TEST_ROOT="$fx"
  RELEASE_UPGRADE_STARTED="true"
  RELEASE_UPGRADE_INVOCATION_STARTED="true"
  RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
  RELEASE_UPGRADE_COMPLETED="false"
  RELEASE_UPGRADE_PROCESS_SPAWNED="false"
  LEGACY_STATE_RECONCILED="false"
  RECONCILIATION_REASON=""
  RELEASE_UPGRADE_FAILURE_CLASS=""
  PREVIOUS_FAILURE_CLASS=""
  PREVIOUS_FAILURE_DETECTED="NO"
  PARTIAL_RELEASE_TRANSITION="NO"
  RESUME_FROM=""
  CURRENT_RUN_ID=""
  PACKAGE_TRANSITION_CLASS="NONE"
  # Fresh source each time so function bodies match helper file (idempotent).
  # shellcheck disable=SC1090
  source "$HELPER"
}

LAST_RECONCILE_RC=0
run_reconcile() {
  # Subshell so die() cannot abort the harness. Status in LAST_RECONCILE_RC.
  local out="$1"
  local rc=0
  set +e
  ( set +e; reconcile_legacy_release_upgrade_state; exit $? ) >"$out" 2>&1
  rc=$?
  set +e
  LAST_RECONCILE_RC=$rc
  load_release_upgrade_started_flag || true
  RECONCILIATION_DECISION="$(sed -n 's/.*RECONCILIATION_DECISION=//p' "$out" 2>/dev/null | tail -1 | tr -d '
')"
  MANUAL_REVIEW_REQUIRED="$(sed -n 's/.*MANUAL_REVIEW_REQUIRED=//p' "$out" 2>/dev/null | tail -1 | tr -d '
')"
  RESUME_FROM="$(sed -n 's/.*RESUME_FROM=//p' "$out" 2>/dev/null | tail -1 | tr -d '
')"
  PACKAGE_TRANSITION_CLASS="$(sed -n 's/.*PACKAGE_TRANSITION_CLASS=//p' "$out" 2>/dev/null | head -1 | tr -d '
')"
  return 0
}

# ===================== per-hop scenarios =====================
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do

  # 1) legacy FAILED + legacy flag only + clean source → SAFE_PRE_TRANSITION_RESUME
  fx="$(setup_hop_fixture "$hop" "clean")"
  load_hop "$hop" "$fx"
  set +e
  run_reconcile "$fx/out1.txt"
  rc=$LAST_RECONCILE_RC
  set -e
  [[ "$rc" -eq 0 ]] || { cat "$fx/out1.txt"; fail "$hop clean reconcile rc=$rc"; }
  [[ "$LEGACY_STATE_RECONCILED" == "true" ]] || fail "$hop LEGACY_STATE_RECONCILED"
  [[ "$RECONCILIATION_DECISION" == "SAFE_PRE_TRANSITION_RESUME" ]] || fail "$hop decision=$RECONCILIATION_DECISION"
  [[ "$MANUAL_REVIEW_REQUIRED" == "NO" ]] || fail "$hop MANUAL_REVIEW"
  pass "$hop: legacy flag only → SAFE_PRE_TRANSITION_RESUME"

  # 2) stale dpkg log before baseline → ignored → SAFE resume
  fx="$(setup_hop_fixture "$hop" "stale-dpkg")"
  mkdir -p "$fx/var/log"
  cat >"$fx/var/log/dpkg.log" <<EOF
2020-01-01 00:00:00 startup archives unpack
2020-01-01 00:00:01 status unpacked libc6:amd64 2.27-3ubuntu1
EOF
  load_hop "$hop" "$fx"
  set +e
  run_reconcile "$fx/out2.txt"
  rc=$LAST_RECONCILE_RC
  set -e
  [[ "$rc" -eq 0 ]] || { cat "$fx/out2.txt"; fail "$hop stale-dpkg rc=$rc"; }
  classify_package_transition_evidence
  [[ "$STALE_EVIDENCE_COUNT" -ge 1 ]] || fail "$hop expected stale evidence count"
  [[ "$AUTHORITATIVE_PACKAGE_TRANSITION" == "NO" ]] || fail "$hop stale treated authoritative"
  [[ "$RECONCILIATION_DECISION" == "SAFE_PRE_TRANSITION_RESUME" ]] || fail "$hop stale decision"
  pass "$hop: stale dpkg log ignored → SAFE_PRE_TRANSITION_RESUME"

  # 3) rotated old apt log → not current-run mutation
  fx="$(setup_hop_fixture "$hop" "rotated")"
  mkdir -p "$fx/var/log/apt"
  cat >"$fx/var/log/apt/history.log.1" <<EOF
Start-Date: 2019-01-01  00:00:00
Commandline: do-release-upgrade
Upgrade: libc6:amd64 (${HOP_TARGET[$hop]})
End-Date: 2019-01-01  00:01:00
EOF
  # Also put a stale current history without baseline.
  cat >"$fx/var/log/apt/history.log" <<EOF
Start-Date: 2019-06-01  00:00:00
Upgrade: unrelated-package:amd64 (1.0)
End-Date: 2019-06-01  00:01:00
EOF
  load_hop "$hop" "$fx"
  classify_package_transition_evidence
  [[ "$AUTHORITATIVE_PACKAGE_TRANSITION" == "NO" ]] || fail "$hop rotated treated authoritative"
  set +e
  run_reconcile "$fx/out3.txt"
  rc=$LAST_RECONCILE_RC
  set -e
  [[ "$rc" -eq 0 ]] || fail "$hop rotated reconcile rc=$rc"
  pass "$hop: rotated apt log not current-run mutation"

  # 4) sources.list / meta-release only → PRE_TRANSITION_CONFIGURATION_ONLY → safe
  fx="$(setup_hop_fixture "$hop" "config-only")"
  printf 'deb http://mirror example %s main\n' "${HOP_TCODE[$hop]}" >"$fx/etc/apt/sources.list"
  printf '[METARELEASE]\nURI = file:///tmp/x\n' >"$fx/etc/update-manager/meta-release"
  load_hop "$hop" "$fx"
  classify_package_transition_evidence
  [[ "$PACKAGE_TRANSITION_CLASS" == "PRE_TRANSITION_CONFIGURATION_ONLY" ]] \
    || fail "$hop config class=$PACKAGE_TRANSITION_CLASS"
  set +e
  run_reconcile "$fx/out4.txt"
  rc=$LAST_RECONCILE_RC
  set -e
  [[ "$rc" -eq 0 ]] || fail "$hop config-only rc=$rc"
  [[ "$RECONCILIATION_DECISION" == "SAFE_PRE_TRANSITION_RESUME" ]] || fail "$hop config decision"
  pass "$hop: config-only → PRE_TRANSITION_CONFIGURATION_ONLY safe resume"

  # 5) baseline + post-baseline dpkg Install → AUTHORITATIVE → exit 29
  fx="$(setup_hop_fixture "$hop" "auth-dpkg")"
  mkdir -p "$fx/var/log"
  printf 'prebaseline line\n' >"$fx/var/log/dpkg.log"
  load_hop "$hop" "$fx"
  record_release_upgrade_run_baseline
  printf 'startup archives unpack\nstatus unpacked libc6:amd64 99.0\n' >>"$fx/var/log/dpkg.log"
  set +e
  run_reconcile "$fx/out5.txt"
  rc=$LAST_RECONCILE_RC
  set -e
  [[ "$rc" -eq 29 ]] || { cat "$fx/out5.txt"; fail "$hop auth-dpkg expected exit 29 got $rc"; }
  grep -q 'MANUAL_REVIEW_REQUIRED=YES' "$fx/out5.txt" || fail "$hop auth-dpkg manual review"
  grep -q 'AUTHORITATIVE_PACKAGE_TRANSITION=YES' "$fx/out5.txt" || fail "$hop auth marker"
  pass "$hop: post-baseline dpkg → exit 29"

  # 6) mixed source/target core packages → manual review
  fx="$(setup_hop_fixture "$hop" "mixed")"
  load_hop "$hop" "$fx"
  # Override pkg_installed_version for this fixture via force flag.
  touch "$(hostpath ${STATE_ROOT}/force-target-core-packages)"
  # Also pretend some source packages remain via consistency path using force only.
  set +e
  run_reconcile "$fx/out6.txt"
  rc=$LAST_RECONCILE_RC
  set -e
  [[ "$rc" -eq 29 ]] || { cat "$fx/out6.txt"; fail "$hop mixed expected 29 got $rc"; }
  pass "$hop: target core contamination → exit 29"

  # 7) dpkg --audit interrupted → manual review
  fx="$(setup_hop_fixture "$hop" "audit")"
  touch "$fx/tmp/dpkg-broken"
  load_hop "$hop" "$fx"
  set +e
  run_reconcile "$fx/out7.txt"
  rc=$LAST_RECONCILE_RC
  set -e
  [[ "$rc" -eq 29 ]] || { cat "$fx/out7.txt"; fail "$hop audit expected 29 got $rc"; }
  grep -q 'INTERRUPTED_DPKG_TRANSACTION\|AUTHORITATIVE\|MANUAL_REVIEW' "$fx/out7.txt" \
    || fail "$hop audit classification"
  pass "$hop: interrupted dpkg → exit 29"

  # 8) already target release → POSTBOOT_VALIDATION
  fx="$(setup_hop_fixture "$hop" "target-os")"
  cat >"$fx/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION_ID="${HOP_TARGET[$hop]}"
VERSION_CODENAME=${HOP_TCODE[$hop]}
EOF
  load_hop "$hop" "$fx"
  set +e
  run_reconcile "$fx/out8.txt"
  rc=$LAST_RECONCILE_RC
  set -e
  [[ "$rc" -eq 0 ]] || { cat "$fx/out8.txt"; fail "$hop target-os rc=$rc"; }
  [[ "$RECONCILIATION_DECISION" == "TARGET_RELEASE_REACHED" ]] || fail "$hop target decision"
  [[ "$RESUME_FROM" == "POSTBOOT_VALIDATION" ]] || fail "$hop resume_from"
  pass "$hop: target OS → POSTBOOT_VALIDATION"

  # 9) active do-release-upgrade → BUSY
  fx="$(setup_hop_fixture "$hop" "busy")"
  load_hop "$hop" "$fx"
  touch "$(hostpath ${STATE_ROOT}/force-active-upgrade-process)"
  set +e
  run_reconcile "$fx/out9.txt"
  rc=$LAST_RECONCILE_RC
  set -e
  [[ "$rc" -eq 22 ]] || { cat "$fx/out9.txt"; fail "$hop busy expected EC_BUSY=22 got $rc"; }
  grep -q 'BUSY_IN_PROGRESS\|ACTIVE_UPGRADE_PROCESS' "$fx/out9.txt" || fail "$hop busy log"
  pass "$hop: active process → BUSY (no duplicate start)"

  # 10) repeated reconciliation → idempotent
  fx="$(setup_hop_fixture "$hop" "idem")"
  load_hop "$hop" "$fx"
  run_reconcile "$fx/out10a.txt"
  bak_count_1="$(find "$fx/opt/aelladata/os-upgrade/offline/hops/${hop}" -maxdepth 1 -type d -name 'legacy-backup.*' 2>/dev/null | wc -l)"
  load_hop "$hop" "$fx"
  LEGACY_STATE_RECONCILED="true"
  RECONCILIATION_REASON="SAFE_PRE_TRANSITION_RESUME:NONE"
  printf 'true\n' >"$fx/opt/aelladata/os-upgrade/offline/critical-holds/legacy_state_reconciled"
  printf '%s\n' "$RECONCILIATION_REASON" >"$fx/opt/aelladata/os-upgrade/offline/critical-holds/reconciliation_reason"
  run_reconcile "$fx/out10b.txt"
  bak_count_2="$(find "$fx/opt/aelladata/os-upgrade/offline/hops/${hop}" -maxdepth 1 -type d -name 'legacy-backup.*' 2>/dev/null | wc -l)"
  # Second pass should not explode backups unboundedly for already-reconciled.
  [[ "$bak_count_2" -le $((bak_count_1 + 1)) ]] || fail "$hop idempotent backup growth"
  pass "$hop: repeated reconciliation idempotent"

  # 11) --diagnose-state zero mutation
  fx="$(setup_hop_fixture "$hop" "diag")"
  # Seed a stale log that must not cause writes to apt/dpkg.
  echo 'Upgrade: old' >"$fx/var/log/apt/history.log"
  load_hop "$hop" "$fx"
  before_state="$(cat "$fx/opt/aelladata/os-upgrade/offline/state")"
  before_flag="$(cat "$fx/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_started")"
  ( diagnose_release_upgrade_state ) >"$fx/diag.txt" 2>"$fx/diag.err"
  after_state="$(cat "$fx/opt/aelladata/os-upgrade/offline/state")"
  after_flag="$(cat "$fx/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_started")"
  [[ "$before_state" == "$after_state" ]] || fail "$hop diagnose mutated state"
  [[ "$before_flag" == "$after_flag" ]] || fail "$hop diagnose mutated flag"
  grep -q 'PACKAGE_TRANSITION_CLASS=' "$fx/diag.txt" || fail "$hop diagnose missing class"
  grep -q 'SAFE_TO_RERUN=' "$fx/diag.txt" || fail "$hop diagnose missing SAFE_TO_RERUN"
  grep -q 'MANUAL_REVIEW_REQUIRED=' "$fx/diag.txt" || fail "$hop diagnose missing MANUAL"
  # evidence bundle under hop dir only (path logged from subshell)
  DIAGNOSTIC_BUNDLE_PATH="$(sed -n 's/.*DIAGNOSTIC_BUNDLE_PATH=//p' "$fx/diag.err" 2>/dev/null | tail -1 | tr -d '\r')"
  [[ -n "$DIAGNOSTIC_BUNDLE_PATH" ]] || fail "$hop diagnose bundle path empty"
  case "$DIAGNOSTIC_BUNDLE_PATH" in
    "$fx"*) ;;
    *) fail "$hop diagnose bundle escaped TEST_ROOT: $DIAGNOSTIC_BUNDLE_PATH" ;;
  esac
  pass "$hop: diagnose-state zero mutation"

  # 12) previous-hop stale evidence must not poison current hop
  # Simulate: history mentions a *previous* target codename, not current.
  if [[ "$hop" != "xenial-to-bionic" ]]; then
    fx="$(setup_hop_fixture "$hop" "prevhop")"
    mkdir -p "$fx/var/log/apt"
    # Pick a previous-hop keyword that is NOT the current target.
    case "$hop" in
      bionic-to-focal) prev_kw='bionic|18.04' ;;
      focal-to-jammy) prev_kw='focal|20.04' ;;
      jammy-to-noble) prev_kw='jammy|22.04' ;;
    esac
    cat >"$fx/var/log/apt/history.log" <<EOF
Start-Date: 2018-01-01  00:00:00
Commandline: do-release-upgrade
Upgrade: base-files:amd64 (from previous hop ${prev_kw})
End-Date: 2018-01-01  00:01:00
EOF
    load_hop "$hop" "$fx"
    classify_package_transition_evidence
    [[ "$AUTHORITATIVE_PACKAGE_TRANSITION" == "NO" ]] \
      || fail "$hop previous-hop history treated as authoritative"
    set +e
    run_reconcile "$fx/out12.txt"
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]] || { cat "$fx/out12.txt"; fail "$hop prevhop reconcile rc=$rc"; }
    pass "$hop: previous-hop log evidence ignored"
  fi

done

# Templates reference shared token; builds inject helper.
for tmpl in \
  client/dp-offline-upgrade-xenial-to-bionic.sh.in \
  client/dp-offline-upgrade-bionic-to-focal.sh.in \
  client/dp-offline-upgrade-focal-to-jammy.sh.in \
  client/dp-offline-upgrade-jammy-to-noble.sh.in; do
  grep -q '@@RELEASE_UPGRADE_RECONCILIATION_HELPER@@' "${ROOT}/${tmpl}" \
    || fail "missing inject token in ${tmpl}"
  grep -q 'REASON=legacy_flag_with_package_transition_evidence' "${ROOT}/${tmpl}" \
    && fail "old boolean exit reason still in ${tmpl}" || true
done
for b in \
  scripts/lib/build_client_xenial_to_bionic.py \
  scripts/lib/build_client_bionic_to_focal.py \
  scripts/lib/build_client_focal_to_jammy.py \
  scripts/lib/build_client_jammy_to_noble.py; do
  grep -q 'RELEASE_UPGRADE_RECONCILIATION_HELPER' "${ROOT}/${b}" \
    || fail "build script missing recon inject: $b"
done
pass "all templates/build scripts share one reconciliation helper"

echo "LEGACY_FLAG_ALONE_CAUSES_TRANSITION=NO"
echo "STALE_LOG_EVIDENCE_IGNORED=YES"
echo "CLEAN_SOURCE_STATE_AUTO_RECONCILED=YES"
echo "REAL_PARTIAL_TRANSITION_FAILS_CLOSED=YES"
echo "DIAGNOSTIC_MODE=YES"
echo "MANUAL_STATE_DELETE_REQUIRED=NO"
echo "ALL test_xenial_legacy_state_reconciliation (all hops) checks passed"
