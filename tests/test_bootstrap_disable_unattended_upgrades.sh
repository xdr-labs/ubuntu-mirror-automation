#!/usr/bin/env bash
# tests/test_bootstrap_disable_unattended_upgrades.sh
# Focused hermetic coverage for mirror-server unattended-upgrade disable.
# Does not touch production apt/systemctl; uses mock systemctl + fake apt.conf.d.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../lib/bootstrap.sh
source "${ROOT}/lib/bootstrap.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

MOCKBIN="${WORKDIR}/mockbin"
APT_DIR="${WORKDIR}/apt.conf.d"
CONF="${APT_DIR}/99ubuntu-mirror-disable-unattended-upgrade"
STATE="${WORKDIR}/units.state"
LOG="${STATE}.log"
mkdir -p "$MOCKBIN" "$APT_DIR"

# STATE lines:
#   1: apt-daily-upgrade.timer active|inactive|absent
#   2: apt-daily-upgrade.timer enabled|disabled|absent
#   3: apt-daily-upgrade.service active|inactive|absent
#   4: apt-daily-upgrade.service enabled|disabled|absent
printf 'active\nenabled\ninactive\ndisabled\n' >"$STATE"
: >"$LOG"

cat >"${MOCKBIN}/systemctl" <<'EOF'
#!/bin/bash
STATE_FILE="${UM_MOCK_SYSTEMCTL_STATE:?}"
LOG_FILE="${STATE_FILE}.log"
cmd="${1:-}"
shift || true
while [[ "${1:-}" == --* ]]; do shift; done
unit="${1:-}"

unit_line() {
  case "$1" in
    apt-daily-upgrade.timer) printf '1 2\n' ;;
    apt-daily-upgrade.service) printf '3 4\n' ;;
    *) printf '0 0\n' ;;
  esac
}

read_pair() {
  local act_line en_line
  read -r act_line en_line < <(unit_line "$1")
  if [[ "$act_line" -eq 0 ]]; then
    ACT="unknown"
    EN="unknown"
    return 0
  fi
  ACT="$(sed -n "${act_line}p" "$STATE_FILE")"
  EN="$(sed -n "${en_line}p" "$STATE_FILE")"
}

write_pair() {
  local act_line en_line
  read -r act_line en_line < <(unit_line "$1")
  [[ "$act_line" -eq 0 ]] && return 0
  local lines
  mapfile -t lines <"$STATE_FILE"
  while [[ "${#lines[@]}" -lt 4 ]]; do lines+=("inactive"); done
  lines[$((act_line - 1))]="$2"
  lines[$((en_line - 1))]="$3"
  printf '%s\n' "${lines[@]}" >"$STATE_FILE"
}

case "$cmd" in
  cat)
    read_pair "$unit"
    if [[ "$ACT" == "absent" || "$EN" == "absent" ]]; then
      echo "No files found for ${unit}" >&2
      exit 1
    fi
    echo "# mock unit ${unit}"
    exit 0
    ;;
  is-active)
    read_pair "$unit"
    if [[ "$ACT" == "absent" ]]; then
      exit 4
    fi
    [[ "$ACT" == "active" ]] && exit 0
    exit 3
    ;;
  is-enabled)
    read_pair "$unit"
    if [[ "$EN" == "absent" ]]; then
      echo "not-found" >&2
      exit 4
    fi
    if [[ "$EN" == "enabled" ]]; then
      echo "enabled"
      exit 0
    fi
    echo "disabled"
    exit 1
    ;;
  stop)
    if [[ "${UM_MOCK_STOP_FAIL:-0}" == "1" ]]; then
      echo "Failed to stop ${unit}" >&2
      exit 1
    fi
    read_pair "$unit"
    write_pair "$unit" "inactive" "$EN"
    echo "stop:${unit}" >>"$LOG_FILE"
    exit 0
    ;;
  disable)
    if [[ "${UM_MOCK_DISABLE_FAIL:-0}" == "1" ]]; then
      echo "Failed to disable ${unit}" >&2
      exit 1
    fi
    read_pair "$unit"
    write_pair "$unit" "$ACT" "disabled"
    echo "disable:${unit}" >>"$LOG_FILE"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "${MOCKBIN}/systemctl"

export UM_BOOTSTRAP_SYSTEMCTL_BIN="${MOCKBIN}/systemctl"
export UM_MOCK_SYSTEMCTL_STATE="$STATE"
export UM_BOOTSTRAP_APT_PERIODIC_CONF="$CONF"

run_disable() {
  env \
    UM_BOOTSTRAP_SYSTEMCTL_BIN="$UM_BOOTSTRAP_SYSTEMCTL_BIN" \
    UM_MOCK_SYSTEMCTL_STATE="$STATE" \
    UM_BOOTSTRAP_APT_PERIODIC_CONF="$CONF" \
    UM_MOCK_STOP_FAIL="${UM_MOCK_STOP_FAIL:-0}" \
    UM_MOCK_DISABLE_FAIL="${UM_MOCK_DISABLE_FAIL:-0}" \
    UM_DRY_RUN="${UM_DRY_RUN:-0}" \
    bash -c '
      set -euo pipefail
      source "'"${ROOT}"'/lib/common.sh"
      source "'"${ROOT}"'/lib/bootstrap.sh"
      um_bootstrap_disable_unattended_upgrades
    ' 2>&1
}

echo "======== A. disable when timer enabled/active ========"
printf 'active\nenabled\ninactive\ndisabled\n' >"$STATE"
: >"$LOG"
rm -f "$CONF"
set +e
out_a="$(run_disable)"
rc_a=$?
set -e
[[ "$rc_a" -eq 0 ]] && pass "disable PASS" || fail "disable FAIL rc=${rc_a}"
echo "$out_a" | grep -q 'UNATTENDED_UPGRADE_APT_CONF=PASS' \
  && pass "APT conf installed" || fail "APT conf log"
echo "$out_a" | grep -q 'UNATTENDED_UPGRADE_DISABLE=PASS' \
  && pass "UNATTENDED_UPGRADE_DISABLE=PASS" || fail "DISABLE=PASS"
echo "$out_a" | grep -q 'APT_PERIODIC_UNATTENDED_UPGRADE=0' \
  && pass "policy marker 0" || fail "policy marker"
[[ -f "$CONF" ]] && grep -qE 'APT::Periodic::Unattended-Upgrade[[:space:]]+"0"' "$CONF" \
  && pass "conf has Unattended-Upgrade \"0\"" || fail "conf content"
grep -qE '^[[:space:]]*APT::Periodic::Update-Package-Lists' "$CONF" \
  && fail "must not set Update-Package-Lists in drop-in" \
  || pass "package-list refresh not disabled"
grep -q 'stop:apt-daily-upgrade.timer' "$LOG" && pass "timer stop" || fail "timer stop"
grep -q 'disable:apt-daily-upgrade.timer' "$LOG" && pass "timer disable" || fail "timer disable"
[[ "$(sed -n '1p' "$STATE")" == "inactive" ]] && pass "timer inactive" || fail "timer not inactive"
[[ "$(sed -n '2p' "$STATE")" == "disabled" ]] && pass "timer disabled" || fail "timer not disabled"

echo "======== B. idempotent re-run ========"
: >"$LOG"
set +e
out_b="$(run_disable)"
rc_b=$?
set -e
[[ "$rc_b" -eq 0 ]] && pass "idempotent PASS" || fail "idempotent FAIL"
echo "$out_b" | grep -q 'UNATTENDED_UPGRADE_APT_CONF=PASS unchanged' \
  && pass "conf unchanged on re-run" || fail "conf should be unchanged"
echo "$out_b" | grep -q 'UNATTENDED_UPGRADE_DISABLE=PASS' \
  && pass "idempotent DISABLE=PASS" || fail "idempotent DISABLE"
[[ ! -s "$LOG" ]] && pass "no unnecessary stop/disable" || fail "spurious systemctl: $(cat "$LOG")"

echo "======== C. dry-run does not write ========"
rm -f "$CONF"
printf 'active\nenabled\ninactive\ndisabled\n' >"$STATE"
: >"$LOG"
set +e
out_c="$(UM_DRY_RUN=1 run_disable)"
rc_c=$?
set -e
[[ "$rc_c" -eq 0 ]] && pass "dry-run PASS" || fail "dry-run FAIL"
echo "$out_c" | grep -qi 'Would disable unattended' \
  && pass "dry-run message" || fail "dry-run message"
[[ ! -f "$CONF" ]] && pass "dry-run no conf write" || fail "dry-run wrote conf"
[[ ! -s "$LOG" ]] && pass "dry-run no systemctl" || fail "dry-run touched systemctl"

echo "======== D. absent units are safe ========"
printf 'absent\nabsent\nabsent\nabsent\n' >"$STATE"
: >"$LOG"
rm -f "$CONF"
set +e
out_d="$(run_disable)"
rc_d=$?
set -e
[[ "$rc_d" -eq 0 ]] && pass "absent units PASS" || fail "absent units FAIL"
echo "$out_d" | grep -q 'UNATTENDED_UPGRADE_UNIT_ABSENT=apt-daily-upgrade.timer' \
  && pass "timer absent noted" || fail "timer absent note"
echo "$out_d" | grep -q 'UNATTENDED_UPGRADE_DISABLE=PASS' \
  && pass "absent still DISABLE=PASS" || fail "absent DISABLE"
[[ -f "$CONF" ]] && pass "conf still written when units absent" || fail "conf missing when units absent"

echo "======== E. stop failure is fail-closed ========"
printf 'active\nenabled\ninactive\ndisabled\n' >"$STATE"
: >"$LOG"
export UM_MOCK_STOP_FAIL=1
set +e
out_e="$(run_disable)"
rc_e=$?
set -e
unset UM_MOCK_STOP_FAIL
[[ "$rc_e" -ne 0 ]] && pass "stop failure non-zero" || fail "stop failure should FAIL"
echo "$out_e" | grep -q 'UNATTENDED_UPGRADE_DISABLE=FAIL' \
  && pass "DISABLE=FAIL on stop" || fail "DISABLE=FAIL missing on stop"

echo "======== F. function is wired into bootstrap run phases ========"
grep -q 'um_bootstrap_disable_unattended_upgrades' "${ROOT}/lib/bootstrap.sh" \
  && pass "helper defined" || fail "helper missing"
awk '
  /phase "Disable unattended package upgrades"/ { p=1 }
  p && /um_bootstrap_disable_unattended_upgrades/ { found=1 }
  END { exit(found ? 0 : 1) }
' "${ROOT}/lib/bootstrap.sh" \
  && pass "wired into um_bootstrap_run" || fail "not wired into um_bootstrap_run"

echo "======== DONE fail=${FAIL} ========"
exit "$FAIL"
