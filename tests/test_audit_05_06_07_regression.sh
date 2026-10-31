#!/usr/bin/env bash
# Hermetic reproduction of verified audit defects. Never executes real apt,
# dpkg, vendor release upgrade, systemctl or host OS mutations.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "=== AUD-05: pre-DRO hold rollback/reentry on four hops ==="

# Extract actual function implementations rather than reimplementing a mock.
extract() {
  local src="$1" output="$2"
  shift 2
  python3 - "$src" "$output" "$@" <<'PYEX'
import pathlib, re, sys
source=pathlib.Path(sys.argv[1]).read_text()
parts=[]
for fn in sys.argv[3:]:
    start=re.search(r'^'+re.escape(fn)+r'\(\) \{\n',source,re.M)
    assert start, 'missing '+fn
    end=re.search(r'^\}\n',source[start.end():],re.M)
    assert end, 'unterminated '+fn
    parts.append(source[start.start():start.end()+end.end()])
pathlib.Path(sys.argv[2]).write_text('\n\n'.join(parts))
PYEX
}

for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  extract "$ROOT/client/dp-offline-upgrade-$hop.sh.in" "$TMP/functions.sh" \
    unhold_critical_os_packages restore_critical_os_holds_if_safe \
    reconcile_critical_hold_state verify_prior_critical_hold_resume_consistency
  mkdir -p "$TMP/$hop"
  bash -c '
    set -euo pipefail
    T="$1" FUN="$2"
    STATE_ROOT="$T/state"
    mkdir -p "$STATE_ROOT/critical-holds"
    printf "systemd\nudev\n" >"$T/held"
    EC_CRITICAL_HOLD=26
    PLANNED_CRITICAL_OS_HOLDS="systemd udev"
    DETECTED_PRODUCT_HOLDS=""
    DETECTED_ALL_HOLDS="systemd udev"
    CRITICAL_HOLDS_REMOVED=""
    CRITICAL_HOLD_RESTORE_ON_EXIT=0
    RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED=false
    TRANSITION_ACTIVE=false
    utc_now() { date -u "+%Y-%m-%dT%H:%M:%SZ"; }
    critical_holds_dir() { printf "%s/critical-holds" "$STATE_ROOT"; }
    list_held_packages() { cat "$T/held"; }
    is_package_currently_held() { grep -Fxq -- "$1" "$T/held"; }
    apt_mark_unhold_pkg() { grep -Fvx -- "$1" "$T/held" >"$T/next" || true; mv "$T/next" "$T/held"; }
    apt_mark_hold_pkg() { if ! is_package_currently_held "$1"; then printf "%s\n" "$1" >>"$T/held"; fi; }
    atomic_write_file() { cat >"$1"; }
    write_critical_holds_state_json() {
      printf "{ \"restore_attempted\": %s, \"restore_result\": \"%s\", \"release_upgrade_started\": false }\n" "$2" "$3" \
        >"$(critical_holds_dir)/critical-holds-state.json"
    }
    load_release_upgrade_started_flag() {
      RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="$TRANSITION_ACTIVE"
    }
    package_transition_evidence_present() { [[ "$TRANSITION_ACTIVE" == true ]]; }
    log() { :; }
    die() { local rc="$1"; shift; exit "$rc"; }
    source "$FUN"
    unhold_critical_os_packages
    [[ ! -s "$T/held" ]] || exit 51
    restore_critical_os_holds_if_safe injected_pre_upgrade_failure
    [[ "$(sort "$T/held" | paste -sd,)" == systemd,udev ]] || exit 52
    reconcile_critical_hold_state
    verify_prior_critical_hold_resume_consistency
    # Previous successful rollback is only a permission to re-plan, never to
    # automatically restart the package transition.
    [[ "$PLANNED_CRITICAL_OS_HOLDS" == "systemd udev" ]] || exit 53
    dir="$(critical_holds_dir)"
    # Bad or missing receipts must retain the old fail-closed result.
    printf "FAIL\n" >"$dir/restore-result"
    write_critical_holds_state_json accepted false FAIL failure
    set +e
    ( verify_prior_critical_hold_resume_consistency )
    rc=$?
    set -e
    [[ "$rc" == 26 ]] || exit 54
    rm -f "$dir/restore-result"
    set +e
    ( verify_prior_critical_hold_resume_consistency )
    rc=$?
    set -e
    [[ "$rc" == 26 ]] || exit 55
    # Partial re-hold must not bypass the mismatch guard.
    printf "PASS\n" >"$dir/restore-result"
    printf "systemd\n" >"$T/held"
    set +e
    ( verify_prior_critical_hold_resume_consistency )
    rc=$?
    set -e
    [[ "$rc" == 26 ]] || exit 56
    printf "systemd\nudev\n" >"$T/held"
    TRANSITION_ACTIVE=true
    set +e
    ( verify_prior_critical_hold_resume_consistency )
    rc=$?
    set -e
    [[ "$rc" == 26 ]] || exit 57
    TRANSITION_ACTIVE=false
    # New unhold operation must remove stale rollback evidence.
    unhold_critical_os_packages
    [[ ! -e "$dir/restore-result" ]] || exit 58
    [[ ! -s "$T/held" ]] || exit 59
  ' _ "$TMP/$hop" "$TMP/functions.sh" || { echo "FAIL: AUD05 $hop"; exit 1; }
  # Runner rollback status may not claim PASS if hold restoration failed.
  extract "$ROOT/client/dp-offline-upgrade-$hop.sh.in" "$TMP/runner.sh" runner_pre_dro_rollback
  for hold_rc in 0 7; do
    bash -c '
      set -euo pipefail
      source "$1"
      EXPECTED_RC="$2"
      PRE_DRO_ROLLBACK_DONE=0
      dro_transaction_started() { return 1; }
      restore_critical_holds_pre_upgrade() { return "$EXPECTED_RC"; }
      restore_apt_sources_pre_upgrade() { return 0; }
      restore_login_shells_pre_upgrade() { return 0; }
      clear_runner_pid() { :; }
      log() { printf "%s %s\n" "$1" "$2"; }
      runner_pre_dro_rollback
    ' _ "$TMP/runner.sh" "$hold_rc" >"$TMP/runner-status.txt"
    if [[ "$hold_rc" == 0 ]]; then
      grep -qx 'INFO PRE_DRO_ROLLBACK_RESULT=PASS' "$TMP/runner-status.txt"
    else
      grep -qx 'ERROR CRITICAL_OS_HOLD_RESTORE_RESULT=FAIL' "$TMP/runner-status.txt"
      grep -qx 'ERROR PRE_DRO_ROLLBACK_RESULT=INCOMPLETE' "$TMP/runner-status.txt"
      ! grep -qx 'INFO PRE_DRO_ROLLBACK_RESULT=PASS' "$TMP/runner-status.txt"
    fi
  done
  echo "PASS: AUD05 $hop rollback replan + unsafe reentry rejected"
done

echo "=== AUD-06: dpkg audit status and output ==="
bash -c '
  set -euo pipefail
  T="$1" LIB="$2"
  mkdir -p "$T/opt/aelladata"
  source "$LIB"
  osu_hostpath() { printf "%s%s" "$T" "$1"; }
  osu_current_os_version() { printf 24.04; }
  osu_current_os_codename() { printf noble; }
  osu_verify_critical_checksums() { return 0; }
  osu_log() { :; }
  DP_AUDIT_CASE=clean
  dpkg() {
    case "$DP_AUDIT_CASE" in
      clean) return 0;;
      whitespace) printf "  \n \t\n"; return 0;;
      dirty) printf "half-configured package\n"; return 0;;
      error) printf "I/O error\n"; return 2;;
    esac
  }
  osu_post_hop_validate 24.04 noble
  DP_AUDIT_CASE=whitespace
  osu_post_hop_validate 24.04 noble
  for kind in dirty error; do
    DP_AUDIT_CASE="$kind"
    if osu_post_hop_validate 24.04 noble; then exit 61; fi
  done
' _ "$TMP/osu" "$ROOT/scripts/lib/dp-os-upgrade-common.sh"
echo "PASS: AUD06 clean/whitespace PASS, dirty/error FAIL"

echo "=== AUD-07: source OS cannot inherit target completion ==="
extract "$ROOT/client/dp-offline-upgrade-xenial-to-bionic.sh.in" "$TMP/state.sh" \
  handle_existing_state
for os in 16.04 18.04; do
  set +e
  bash -c '
    source "$1"; OS="$2"; EC_STATE=27; EC_OS=11
    read_state() { printf COMPLETED_BIONIC; }
    read_os_field() { printf "%s" "$OS"; }
    detect_upgrade_already_running() { return 1; }
    live_upgrade_evidence_present() { return 1; }
    allow_live_systemctl() { return 1; }
    log() { :; }
    die() { local rc="$1"; shift; exit "$rc"; }
    handle_existing_state
    exit 90
  ' _ "$TMP/state.sh" "$os"
  rc=$?
  set -e
  case "$os:$rc" in
    16.04:27|18.04:0) echo "PASS: AUD07 $os rc=$rc" ;;
    *) echo "FAIL: AUD07 $os rc=$rc"; exit 1 ;;
  esac
done
echo "TEST_AUDIT_05_06_07_REGRESSION=PASS"
