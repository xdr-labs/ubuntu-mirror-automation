#!/usr/bin/env bash
# P0 systemd/retry semantics and P2 validate CLI fail-closed tests.
# Hermetic fake-root only. Never touches a real DP or host upgrade.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${ROOT}/scripts/dp-os-upgrade-only.sh"
RUNNER="${ROOT}/scripts/dp-os-upgrade-runner.sh"
LIB="${ROOT}/scripts/lib/dp-os-upgrade-common.sh"
FIX="${ROOT}/tests/fixtures/dp-os-upgrade"
CONF="${ROOT}/config/dp-os-upgrade.conf"
UNITS="${ROOT}/systemd"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

setup_fake_root() {
  local name="${1:-base}"
  FAKE="${WORKDIR}/${name}"
  STUBS="${FAKE}/stubs"
  rm -rf "$FAKE"
  mkdir -p "$STUBS" \
    "$FAKE/opt/aelladata" \
    "$FAKE/etc/apt/sources.list.d" \
    "$FAKE/var/lib/dpkg" \
    "$FAKE/var/log/aella" \
    "$FAKE/run/lock" \
    "$FAKE/tmp" \
    "$FAKE/proc/sys/kernel/random" \
    "$FAKE/etc/systemd/system"
  cp -a "$FIX/xenial-before/etc/os-release" "$FAKE/etc/os-release"
  cp -a "$FIX/xenial-before/etc/hostname" "$FAKE/etc/hostname"
  cp -a "$FIX/xenial-before/opt/aelladata/." "$FAKE/opt/aelladata/"
  printf 'boot-initial\n' >"$FAKE/proc/sys/kernel/random/boot_id"
  printf 'deb http://archive.ubuntu.com/ubuntu xenial main\n' >"$FAKE/etc/apt/sources.list"
  : >"$FAKE/run/ntp-synchronized"
  for cmd in apt-get apt dpkg apt-mark do-release-upgrade systemctl reboot curl timedatectl; do
    cat >"$STUBS/$cmd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
me="$(basename "$0")"
log="${DP_OS_UPGRADE_TEST_ROOT}/tmp/stub-commands.log"
mkdir -p "$(dirname "$log")"
printf '%s %s\n' "$me" "$*" >>"$log"
case "$me" in
  dpkg)
    case "${1:-}" in --audit|-C) exit 0 ;; *) exit 0 ;; esac
    ;;
  systemctl)
    echo "systemctl $*" >>"${DP_OS_UPGRADE_TEST_ROOT}/tmp/systemctl.log"
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
    chmod +x "$STUBS/$cmd"
  done
  export DP_OS_UPGRADE_TEST_MODE=1
  export DP_OS_UPGRADE_TEST_ROOT="$FAKE"
  export DP_OS_UPGRADE_COMMAND_PATH="$STUBS"
  export DP_OS_UPGRADE_SIMULATE_ROOT=1
  export DP_OS_UPGRADE_FAKE_HOSTNAME=ready-aio
  export DP_OS_UPGRADE_FAKE_OS_VERSION=16.04
  export DP_OS_UPGRADE_FAKE_OS_CODENAME=xenial
  export DP_OS_UPGRADE_FAKE_DP_VERSION=6.5.0
  export DP_OS_UPGRADE_HTTP_OK_ALL=1
  export DP_OS_UPGRADE_FAKE_NTP=1
  export DP_OS_UPGRADE_FAKE_APT_LOCK=0
  export PATH="${STUBS}:${PATH}"
  export OSU_CONFIG_FILE="$CONF"
}

write_min_state() {
  ST_REVISION="${ST_REVISION:-1}"
  ST_HOSTNAME="${ST_HOSTNAME:-ready-aio}"
  ST_SOURCE_OS="${ST_SOURCE_OS:-16.04}"
  ST_SOURCE_CODENAME="${ST_SOURCE_CODENAME:-xenial}"
  ST_CURRENT_OS="${ST_CURRENT_OS:-16.04}"
  ST_CURRENT_CODENAME="${ST_CURRENT_CODENAME:-xenial}"
  ST_TARGET_OS="${ST_TARGET_OS:-18.04}"
  ST_TARGET_CODENAME="${ST_TARGET_CODENAME:-bionic}"
  ST_CURRENT_HOP="${ST_CURRENT_HOP:-1}"
  ST_TOTAL_HOPS="${ST_TOTAL_HOPS:-4}"
  ST_ATTEMPT="${ST_ATTEMPT:-1}"
  ST_PREFLIGHT_ID="${ST_PREFLIGHT_ID:-pf-retry}"
  ST_PREFLIGHT_COMPLETED_AT="${ST_PREFLIGHT_COMPLETED_AT:-2026-08-17T00:00:00Z}"
  ST_SNAPSHOT_REF="${ST_SNAPSHOT_REF:-s}"
  ST_PKG_MODE="${ST_PKG_MODE:-mirror}"
  ST_PKG_URL="${ST_PKG_URL:-http://192.0.2.10}"
  ST_WARNING_ACCEPTANCES="${ST_WARNING_ACCEPTANCES:-[]}"
  ST_RETRYABLE="${ST_RETRYABLE:-false}"
  ST_RETRY_COUNT="${ST_RETRY_COUNT:-0}"
  ST_PAUSE_REQUESTED="${ST_PAUSE_REQUESTED:-false}"
  ST_CREATED_AT="${ST_CREATED_AT:-2026-08-17T00:00:00Z}"
  ST_FINAL_TARGET_OS="${ST_FINAL_TARGET_OS:-24.04}"
  ST_FINAL_TARGET_CODENAME="${ST_FINAL_TARGET_CODENAME:-noble}"
  ST_EXECUTION_PROFILE="${ST_EXECUTION_PROFILE:-production}"
  ST_EXECUTE_AUTHORIZED="${ST_EXECUTE_AUTHORIZED:-true}"
  ST_DESTRUCTIVE_ACK_VERIFIED="${ST_DESTRUCTIVE_ACK_VERIFIED:-true}"
  osu_write_state_json "$(osu_build_state_json)"
}

run_retry() {
  set +e
  bash "$RUNNER" --retry >"$WORKDIR/stdout" 2>"$WORKDIR/stderr"
  RC=$?
  set -e
}

run_cli() {
  set +e
  bash "$CLI" "$@" >"$WORKDIR/stdout" 2>"$WORKDIR/stderr"
  RC=$?
  set -e
}

assert_retry_skip() {
  local label="$1" state_before="$2"
  local state_after
  [[ "$RC" -eq 0 ]] || { fail "$label rc=$RC"; return; }
  grep -q 'DP_OS_RETRY_ACTION=SKIPPED' "$WORKDIR/stdout" "$WORKDIR/stderr" \
    || { fail "$label missing SKIPPED marker"; return; }
  grep -q 'DP_OS_RETRY_ACTION=EXECUTE' "$WORKDIR/stdout" "$WORKDIR/stderr" \
    && { fail "$label unexpectedly EXECUTE"; return; }
  state_after="$(osu_json_get "$(osu_state_path)" current_state)"
  [[ "$state_after" == "$state_before" ]] || {
    fail "$label state mutated ${state_before}->${state_after}"
    return
  }
  if [[ -f "$FAKE/tmp/stub-commands.log" ]] && \
     grep -qE '^(apt-get|apt|dpkg|do-release-upgrade|reboot) ' "$FAKE/tmp/stub-commands.log"; then
    fail "$label invoked package/reboot commands"
    return
  fi
  pass "$label"
}

# ---------------------------------------------------------------------------
# systemd unit architecture
# ---------------------------------------------------------------------------
echo "[test] systemd retry architecture"
if grep -Eiq '^Requires=.*dp-os-upgrade-resume\.service' "$UNITS/dp-os-upgrade-resume.timer"; then
  fail "timer must not Require the resume service"
else
  pass "timer has no Requires=resume.service"
fi
if grep -Eiq '^Wants=.*dp-os-upgrade-resume\.service' "$UNITS/dp-os-upgrade-resume.timer"; then
  fail "timer must not Wants= the resume service"
else
  pass "timer has no Wants=resume.service"
fi
grep -q '^Unit=dp-os-upgrade-resume.service$' "$UNITS/dp-os-upgrade-resume.timer" \
  && pass "timer Unit= resume service" \
  || fail "timer missing Unit="
if grep -Eiq '^Conflicts=.*dp-os-upgrade\.service' "$UNITS/dp-os-upgrade-resume.service"; then
  fail "resume service must not Conflicts= main service"
else
  pass "resume service has no Conflicts=main"
fi
if command -v systemd-analyze >/dev/null 2>&1; then
  if systemd-analyze verify \
      "$UNITS/dp-os-upgrade.service" \
      "$UNITS/dp-os-upgrade-resume.service" \
      "$UNITS/dp-os-upgrade-resume.timer" 2>"$WORKDIR/sa.err"; then
    pass "systemd-analyze verify"
  else
    if grep -qiE 'Failed|error' "$WORKDIR/sa.err" && ! grep -qi 'does not exist' "$WORKDIR/sa.err"; then
      fail "systemd-analyze: $(cat "$WORKDIR/sa.err")"
    else
      pass "systemd-analyze verify (path warnings ok)"
    fi
  fi
else
  echo "  SKIPPED: systemd-analyze not installed"
fi

# POLICY_AUTO_RETRY_ENABLED gates timer enablement
CLI_LIB="$WORKDIR/cli-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$CLI" >"$CLI_LIB"
setup_fake_root policy
# shellcheck disable=SC1090
source "$CLI_LIB"
osu_init_test_mode
osu_load_config "$CONF"
POLICY_AUTO_RETRY_ENABLED=false
: >"$FAKE/tmp/systemctl.log"
_install_systemd_units >/dev/null
if grep -q 'enable dp-os-upgrade-resume.timer' "$FAKE/tmp/systemctl.log"; then
  fail "AUTO_RETRY_ENABLED=false still enabled timer"
else
  pass "AUTO_RETRY_ENABLED=false does not enable timer"
fi
grep -q 'disable dp-os-upgrade-resume.timer' "$FAKE/tmp/systemctl.log" \
  && pass "AUTO_RETRY_ENABLED=false disables timer" \
  || fail "AUTO_RETRY_ENABLED=false did not disable timer"
POLICY_AUTO_RETRY_ENABLED=true
: >"$FAKE/tmp/systemctl.log"
_install_systemd_units >/dev/null
grep -q 'enable dp-os-upgrade-resume.timer' "$FAKE/tmp/systemctl.log" \
  && pass "AUTO_RETRY_ENABLED=true enables timer" \
  || fail "AUTO_RETRY_ENABLED=true did not enable timer"

# ---------------------------------------------------------------------------
# MODE=retry semantic matrix
# ---------------------------------------------------------------------------
echo "[test] MODE=retry state gating"

retry_state_skip() {
  local name="$1" state="$2" retryable="${3:-false}"
  setup_fake_root "$name"
  # shellcheck disable=SC1090
  source "$LIB"
  osu_init_test_mode
  osu_load_config "$CONF"
  mkdir -p "$OSU_STATE_DIR"
  ST_STATE="$state"
  ST_RETRYABLE="$retryable"
  write_min_state
  : >"$FAKE/tmp/stub-commands.log"
  run_retry
  assert_retry_skip "retry $state retryable=$retryable" "$state"
}

retry_state_skip initialized INITIALIZED false
retry_state_skip running HOP_RELEASE_UPGRADE_RUNNING false
retry_state_skip reboot REBOOT_REQUIRED false
retry_state_skip completed COMPLETED false
retry_state_skip failed FAILED false
retry_state_skip paused PAUSED false
retry_state_skip blocked_nr BLOCKED false

setup_fake_root blocked_yes
# shellcheck disable=SC1090
source "$LIB"
osu_init_test_mode
osu_load_config "$CONF"
mkdir -p "$OSU_STATE_DIR/runtime" "$OSU_STATE_DIR/hops"
ST_STATE=BLOCKED
ST_RETRYABLE=true
write_min_state
osu_pin_runtime
osu_write_operator_approval true false pf-retry '[]' || true
: >"$FAKE/tmp/stub-commands.log"
run_retry
if grep -q 'DP_OS_RETRY_ACTION=EXECUTE' "$WORKDIR/stdout" "$WORKDIR/stderr"; then
  pass "BLOCKED retryable=true enters retry path"
else
  fail "BLOCKED retryable=true missing EXECUTE marker"
fi
[[ "$RC" -eq 0 || "$RC" -eq 20 || "$RC" -eq 30 || "$RC" -eq 40 || "$RC" -eq 41 || "$RC" -eq 22 ]] \
  || fail "BLOCKED retryable=true unexpected rc=$RC"

# lock busy + MODE=retry → skip rc=0
setup_fake_root lock_retry
# shellcheck disable=SC1090
source "$LIB"
osu_init_test_mode
osu_load_config "$CONF"
mkdir -p "$OSU_STATE_DIR"
ST_STATE=BLOCKED
ST_RETRYABLE=true
write_min_state
(
  # shellcheck disable=SC1090
  source "$LIB"
  osu_init_test_mode
  osu_load_config "$CONF"
  osu_acquire_lock || exit 1
  sleep 20
) &
holder=$!
for _ in $(seq 1 50); do
  [[ "$(osu_lock_classify)" == "HELD_LIVE" ]] && break
  sleep 0.1
done
: >"$FAKE/tmp/stub-commands.log"
run_retry
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
[[ "$RC" -eq 0 ]] || fail "retry lock-busy rc=$RC"
grep -q 'reason=runner_lock_busy' "$WORKDIR/stdout" "$WORKDIR/stderr" \
  && pass "retry lock-busy SKIPPED" \
  || fail "retry lock-busy missing marker"
if [[ -f "$FAKE/tmp/stub-commands.log" ]] && \
   grep -qE '^(apt-get|do-release-upgrade|reboot) ' "$FAKE/tmp/stub-commands.log"; then
  fail "retry lock-busy invoked upgrade commands"
else
  pass "retry lock-busy did not invoke apt/dro/reboot"
fi
state_after="$(osu_json_get "$(osu_state_path)" current_state)"
[[ "$state_after" == "BLOCKED" ]] && pass "retry lock-busy state unchanged" \
  || fail "retry lock-busy mutated state=$state_after"

# lock busy + normal resume still fail-closed
setup_fake_root lock_resume
# shellcheck disable=SC1090
source "$LIB"
osu_init_test_mode
osu_load_config "$CONF"
mkdir -p "$OSU_STATE_DIR/runtime"
ST_STATE=INITIALIZED
ST_RETRYABLE=false
write_min_state
osu_pin_runtime
(
  # shellcheck disable=SC1090
  source "$LIB"
  osu_init_test_mode
  osu_load_config "$CONF"
  osu_acquire_lock || exit 1
  sleep 20
) &
holder=$!
for _ in $(seq 1 50); do
  [[ "$(osu_lock_classify)" == "HELD_LIVE" ]] && break
  sleep 0.1
done
set +e
bash "$RUNNER" --resume >"$WORKDIR/stdout" 2>"$WORKDIR/stderr"
RC=$?
set -e
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
[[ "$RC" -ne 0 ]] && pass "normal resume lock-busy fail-closed rc=$RC" \
  || fail "normal resume lock-busy unexpectedly rc=0"

# ---------------------------------------------------------------------------
# validate CLI
# ---------------------------------------------------------------------------
echo "[test] validate CLI fail-closed"

run_validate_case() {
  local name="$1"
  setup_fake_root "$name"
  # shellcheck disable=SC1090
  source "$LIB"
  osu_init_test_mode
  osu_load_config "$CONF"
  mkdir -p "$OSU_STATE_DIR"
}

run_validate_case v_hop
ST_STATE=HOP_VALIDATING
ST_TARGET_OS=20.04
ST_TARGET_CODENAME=focal
ST_CURRENT_OS=18.04
ST_CURRENT_CODENAME=bionic
write_min_state
export DP_OS_UPGRADE_FAKE_OS_VERSION=18.04
export DP_OS_UPGRADE_FAKE_OS_CODENAME=bionic
run_cli validate
[[ "$RC" -ne 0 ]] && grep -q 'validate: FAIL reason=os_mismatch' "$WORKDIR/stdout" \
  && pass "HOP_VALIDATING current!=target FAIL" \
  || fail "HOP_VALIDATING mismatch rc=$RC out=$(cat "$WORKDIR/stdout")"

run_validate_case v_done
ST_STATE=COMPLETED
ST_FINAL_TARGET_OS=24.04
ST_FINAL_TARGET_CODENAME=noble
ST_CURRENT_OS=22.04
ST_CURRENT_CODENAME=jammy
write_min_state
export DP_OS_UPGRADE_FAKE_OS_VERSION=22.04
export DP_OS_UPGRADE_FAKE_OS_CODENAME=jammy
run_cli validate
[[ "$RC" -ne 0 ]] && grep -q 'validate: FAIL reason=os_mismatch' "$WORKDIR/stdout" \
  && pass "COMPLETED current!=final FAIL" \
  || fail "COMPLETED mismatch rc=$RC out=$(cat "$WORKDIR/stdout")"

run_validate_case v_code
ST_STATE=HOP_VALIDATING
ST_TARGET_OS=20.04
ST_TARGET_CODENAME=focal
write_min_state
export DP_OS_UPGRADE_FAKE_OS_VERSION=20.04
export DP_OS_UPGRADE_FAKE_OS_CODENAME=jammy
run_cli validate
[[ "$RC" -ne 0 ]] && grep -q 'validate: FAIL reason=codename_mismatch' "$WORKDIR/stdout" \
  && pass "codename mismatch FAIL" \
  || fail "codename mismatch rc=$RC out=$(cat "$WORKDIR/stdout")"

run_validate_case v_aella
ST_STATE=HOP_VALIDATING
ST_TARGET_OS=18.04
ST_TARGET_CODENAME=bionic
write_min_state
rm -rf "$FAKE/opt/aelladata"
export DP_OS_UPGRADE_FAKE_OS_VERSION=18.04
export DP_OS_UPGRADE_FAKE_OS_CODENAME=bionic
run_cli validate
[[ "$RC" -ne 0 ]] && grep -q 'validate: FAIL reason=aelladata_missing' "$WORKDIR/stdout" \
  && pass "missing aelladata FAIL" \
  || fail "missing aelladata rc=$RC out=$(cat "$WORKDIR/stdout")"

run_validate_case v_ok
ST_STATE=HOP_VALIDATING
ST_TARGET_OS=18.04
ST_TARGET_CODENAME=bionic
ST_CURRENT_OS=18.04
ST_CURRENT_CODENAME=bionic
write_min_state
before_state="$(sha256sum "$(osu_state_path)" | awk '{print $1}')"
before_sum="$(sha256sum "$(osu_state_sha_path)" | awk '{print $1}')"
export DP_OS_UPGRADE_FAKE_OS_VERSION=18.04
export DP_OS_UPGRADE_FAKE_OS_CODENAME=bionic
# os-release must match fake version for osu_current_os_* fallback
cat >"$FAKE/etc/os-release" <<'EOF'
NAME="Ubuntu"
VERSION_ID="18.04"
VERSION_CODENAME=bionic
ID=ubuntu
EOF
run_cli validate
[[ "$RC" -eq 0 ]] && grep -q 'validate: OK (read-only)' "$WORKDIR/stdout" \
  && pass "matching hop validate PASS" \
  || fail "matching validate rc=$RC out=$(cat "$WORKDIR/stdout")"
after_state="$(sha256sum "$(osu_state_path)" | awk '{print $1}')"
after_sum="$(sha256sum "$(osu_state_sha_path)" | awk '{print $1}')"
[[ "$before_state" == "$after_state" && "$before_sum" == "$after_sum" ]] \
  && pass "validate does not mutate state.json/checksum" \
  || fail "validate mutated state"

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASS"
exit 0
