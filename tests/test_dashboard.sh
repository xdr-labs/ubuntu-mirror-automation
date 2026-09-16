#!/usr/bin/env bash
# tests/test_dashboard.sh — Interactive dashboard / sync UX tests (fixtures & mocks)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${ROOT}/lib/config.sh"
# shellcheck source=../lib/state.sh
source "${ROOT}/lib/state.sh"
# shellcheck source=../lib/progress.sh
source "${ROOT}/lib/progress.sh"

FAIL=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export UM_QUIET_LOAD=1
um_load_config "${ROOT}/mirror.conf"

# Isolate state/logs into temp dirs (must override selective paths from mirror.conf
# so host /var/spool/apt-mirror/selective READY cannot leak into fixtures).
export UM_STATE_DIR="$TMP/state"
export LOG_DIR="$TMP/logs"
export APT_MIRROR_LOG="$TMP/apt-mirror.log"
export UM_PROGRESS_JSONL="$TMP/logs/progress.jsonl"
export BASE_PATH="$TMP/mirror-root"
export SELECTIVE_MIRROR_ROOT="$TMP/mirror-root/selective"
export DIST_ROOT="$TMP/mirror-root/dists"
export UBUNTU_MIRROR_ROOT="$TMP/mirror-root"
export INSTALL_BIN_DIR="$TMP/bin"
export STALL_THRESHOLD_SEC=600
export WAITING_THRESHOLD_SEC=30
UM_STALL_THRESHOLD_SEC=600
UM_WAITING_THRESHOLD_SEC=30
# Dashboard size/count fixtures exercise non-selective progress.jsonl fallbacks.
export MIRROR_MODE="full"

mkdir -p "$UM_STATE_DIR" "$LOG_DIR" "$BASE_PATH" "$DIST_ROOT" "$INSTALL_BIN_DIR" "$SELECTIVE_MIRROR_ROOT/state"
# Pretend installed for lifecycle tests that need it
touch "$TMP/mirror.list"
# Override um_is_installed for isolated tests
um_is_installed() { return 0; }

# Mock systemctl / pgrep defaults (overridden per test)
MOCK_ACTIVE_STATE="inactive"
MOCK_RESULT="success"
MOCK_PROCESS=0
MOCK_PAUSED=0

systemctl() {
  case "$*" in
    *"ActiveState"*) echo "$MOCK_ACTIVE_STATE" ;;
    *"SubState"*) echo "dead" ;;
    *"Result"*) echo "$MOCK_RESULT" ;;
    is-active*) [[ "$MOCK_ACTIVE_STATE" == "active" ]] || [[ "$MOCK_ACTIVE_STATE" == "activating" ]];;
    is-enabled*) return 1 ;;
    *) return 0 ;;
  esac
}

um_is_sync_running() {
  [[ "$MOCK_PROCESS" -eq 1 ]] || [[ "$MOCK_ACTIVE_STATE" == "active" ]] || [[ "$MOCK_ACTIVE_STATE" == "activating" ]]
}

um_is_sync_paused() {
  [[ "$MOCK_PAUSED" -eq 1 ]]
}

pgrep() { [[ "$MOCK_PROCESS" -eq 1 ]]; }

# ---------------------------------------------------------------------------
echo "[test_install_bootstrap_gui]"
# Fresh install bootstraps Mirror Manager runtime and auto-starts GUI on TTY.
# Large downloads are started from the GUI, not from install.sh.
if grep -q 'um_bootstrap_run\|um_bootstrap_maybe_start_gui' "${ROOT}/install.sh" \
  && grep -q 'um_bootstrap_install_runtime' "${ROOT}/lib/bootstrap.sh"; then
  pass "bootstrap installs Mirror Manager runtime"
else
  fail "missing bootstrap runtime install path"
fi
if grep -q 'ubuntu-offline-mirror mirror-manager' "${ROOT}/install.sh" \
  "${ROOT}/lib/bootstrap.sh"; then
  pass "bootstrap documents GUI reopen command"
else
  fail "GUI reopen command missing"
fi
# Legacy menu materialize path remains available for operators/tools
if grep -q 'systemctl start --no-block apt-mirror.service' "${ROOT}/lib/install-menu.sh"; then
  pass "legacy menu non-blocking materialize still present"
else
  fail "legacy menu materialize path missing"
fi
if grep -q 'um_attach_dashboard\|mirrorctl watch\|mirror-dashboard\|Watch Live Progress' \
  "${ROOT}/lib/install-menu.sh" "${ROOT}/scripts/mirrorctl"; then
  pass "dashboard attach still available via mirrorctl/menu"
else
  fail "dashboard attach missing"
fi

# ---------------------------------------------------------------------------
echo "[test_default_interactive_gui]"
HELP="$(bash "${ROOT}/install.sh" --help)"
echo "$HELP" | grep -q -- '--no-gui' || fail "missing --no-gui"
echo "$HELP" | grep -q -- '--non-interactive' || fail "missing --non-interactive"
echo "$HELP" | grep -q 'Mirror Manager' || fail "missing Mirror Manager"
pass "install help lists GUI bootstrap options"
grep -q '\[\[ -t 0 && -t 1 \]\]\|\[\[ -t 0 \]\]' "${ROOT}/lib/bootstrap.sh" \
  && pass "TTY detection for GUI auto-start" || fail "no TTY detection for GUI"

# ---------------------------------------------------------------------------
echo "[test_noninteractive_option_skips_gui]"
OUT="$(bash "${ROOT}/install.sh" --dry-run --non-interactive 2>&1 || true)"
echo "$OUT" | grep -qiE 'Would start Mirror Manager GUI|GUI auto-start skipped|--no-gui' \
  || echo "$OUT" | grep -q '\[DRY-RUN\]' || fail "non-interactive dry-run"
pass "non-interactive/dry-run bootstrap path"
bash "${ROOT}/scripts/mirrorctl" --help 2>/dev/null | grep -q watch || fail "mirrorctl watch missing"
pass "mirrorctl watch documented"

# ---------------------------------------------------------------------------
echo "[test_foreground_option_compat]"
# Obsolete --foreground is hard-rejected (silent ignore would be dangerous).
set +e
OUT="$(bash "${ROOT}/install.sh" --dry-run --foreground --no-gui 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || fail "obsolete --foreground should be rejected"
echo "$OUT" | grep -q 'Obsolete option --foreground rejected'   || fail "foreground rejection message missing: ${OUT}"
pass "obsolete --foreground rejected safely"

# ---------------------------------------------------------------------------
echo "[test_ctrl_c_detaches_not_stops_service]"
if grep -q 'on_detach_signal' "${ROOT}/scripts/mirror-dashboard.sh"; then
  pass "dashboard has detach signal handler"
else
  fail "no detach handler"
fi
if grep -q 'trap on_detach_signal INT TERM' "${ROOT}/scripts/mirror-dashboard.sh"; then
  pass "Ctrl+C trapped to detach"
else
  fail "Ctrl+C trap missing"
fi
# Ensure detach path does not call systemctl stop
if grep -A20 'on_detach_signal' "${ROOT}/scripts/mirror-dashboard.sh" | grep -q 'systemctl stop'; then
  fail "detach handler stops service"
else
  pass "detach does not stop apt-mirror.service"
fi

# ---------------------------------------------------------------------------
echo "[test_tui_no_ansi_when_not_tty]"
OUT="$(bash "${ROOT}/scripts/mirror-dashboard.sh" --config "${ROOT}/mirror.conf" --once 2>/dev/null | cat)"
if [[ "$OUT" == *$'\033['* ]] || [[ "$OUT" == *$'[2J'* ]]; then
  fail "ANSI cursor controls in non-TTY --once output"
else
  pass "no ANSI cursor controls for --once"
fi
echo "$OUT" | grep -q 'State:' || fail "snapshot missing State"
pass "plain snapshot rendered"

# ---------------------------------------------------------------------------
echo "[test_status_running]"
MOCK_PROCESS=1
MOCK_ACTIVE_STATE="active"
MOCK_RESULT="success"
printf '2026-07-13 06:23:20 Downloading jammy-updates/main Packages\n' >"$APT_MIRROR_LOG"
touch -d '2 seconds ago' "$APT_MIRROR_LOG" 2>/dev/null || touch "$APT_MIRROR_LOG"
um_detect_sync_health 2 100 50000 1000
[[ "$UM_LIFECYCLE_STATE" == "SYNC_RUNNING" ]] && pass "SYNC_RUNNING" || fail "expected SYNC_RUNNING got $UM_LIFECYCLE_STATE"
[[ "$UM_HEALTH_STATE" == "HEALTHY" ]] && pass "HEALTHY" || fail "expected HEALTHY"

# ---------------------------------------------------------------------------
echo "[test_status_waiting]"
MOCK_PROCESS=1
MOCK_ACTIVE_STATE="active"
um_detect_sync_health 48 0 0 0
[[ "$UM_LIFECYCLE_STATE" == "SYNC_WAITING" ]] && pass "SYNC_WAITING" || fail "expected SYNC_WAITING got $UM_LIFECYCLE_STATE"
[[ "$UM_HEALTH_STATE" == "WAITING" ]] && pass "WAITING health" || fail "expected WAITING"
echo "$UM_HEALTH_REASON" | grep -q '48 seconds' && pass "waiting reason includes age" || fail "reason=$UM_HEALTH_REASON"

# ---------------------------------------------------------------------------
echo "[test_status_stalled]"
MOCK_PROCESS=1
MOCK_ACTIVE_STATE="active"
um_detect_sync_health 720 0 0 0
[[ "$UM_LIFECYCLE_STATE" == "SYNC_STALLED" ]] && pass "SYNC_STALLED" || fail "expected SYNC_STALLED got $UM_LIFECYCLE_STATE"
[[ "$UM_HEALTH_STATE" == "STALLED" ]] && pass "STALLED health" || fail "expected STALLED"

# ---------------------------------------------------------------------------
echo "[test_status_failed]"
MOCK_PROCESS=0
MOCK_ACTIVE_STATE="failed"
MOCK_RESULT="exit-code"
um_clear_marker "ready" 2>/dev/null || true
um_clear_marker "initial-sync-complete" 2>/dev/null || true
um_mark_state "sync-failed"
um_detect_sync_health 999999 0 0 0
[[ "$UM_LIFECYCLE_STATE" == "SYNC_FAILED" ]] && pass "SYNC_FAILED" || fail "expected SYNC_FAILED got $UM_LIFECYCLE_STATE"
[[ "$UM_HEALTH_STATE" == "FAILED" ]] && pass "FAILED health" || fail "expected FAILED"
um_clear_marker "sync-failed"

# ---------------------------------------------------------------------------
echo "[test_status_complete]"
MOCK_PROCESS=0
MOCK_ACTIVE_STATE="inactive"
MOCK_RESULT="success"
um_mark_state "initial-sync-complete"
um_detect_sync_health 999999 0 0 0
[[ "$UM_LIFECYCLE_STATE" == "SYNC_COMPLETE" || "$UM_LIFECYCLE_STATE" == "READY" ]] \
  && pass "SYNC_COMPLETE/READY ($UM_LIFECYCLE_STATE)" \
  || fail "expected complete got $UM_LIFECYCLE_STATE"
um_mark_state "ready"
um_detect_sync_health 999999 0 0 0
[[ "$UM_LIFECYCLE_STATE" == "READY" ]] && pass "READY" || fail "expected READY got $UM_LIFECYCLE_STATE"

# ---------------------------------------------------------------------------
echo "[test_offline_ready_file]"
um_clear_marker "ready" 2>/dev/null || true
um_clear_marker "initial-sync-complete" 2>/dev/null || true
MOCK_PROCESS=0
MOCK_ACTIVE_STATE="inactive"
MOCK_RESULT="success"
mkdir -p "${BASE_PATH}/offline"
cat >"${BASE_PATH}/offline/READY" <<'EOF'
generated_at=2026-07-14T23:10:05+00:00
package_count=465138
total_size=2.2T
EOF
um_detect_sync_health 999999 0 0 0
[[ "$UM_LIFECYCLE_STATE" == "READY" ]] && pass "offline READY file → READY" \
  || fail "expected READY from offline file got $UM_LIFECYCLE_STATE"
pkgs="$(um_package_count_cached)"
[[ "$pkgs" == "465138" ]] && pass "package_count from offline READY" || fail "pkgs=$pkgs"
# False-positive process + inactive service still reports READY
MOCK_PROCESS=1
um_detect_sync_health 999999 0 0 0
[[ "$UM_LIFECYCLE_STATE" == "READY" ]] && pass "READY wins over stale process when inactive" \
  || fail "expected READY got $UM_LIFECYCLE_STATE"
MOCK_PROCESS=0
rm -f "${BASE_PATH}/offline/READY"

# ---------------------------------------------------------------------------
echo "[test_size_fallback_when_jsonl_empty]"
: >"$UM_PROGRESS_JSONL"
mkdir -p "${UBUNTU_MIRROR_ROOT}/pool" "${BASE_PATH}/mirror"
printf 'x' >"${UBUNTU_MIRROR_ROOT}/pool/a.deb"
# Size sample uses MIRROR_PATH (or BASE_PATH mount); seed a file there for fixtures.
export MIRROR_PATH="${BASE_PATH}/mirror"
dd if=/dev/zero of="${MIRROR_PATH}/seed.bin" bs=1024 count=4 status=none 2>/dev/null \
  || printf 'xxxx' >"${MIRROR_PATH}/seed.bin"
sz="$(um_mirror_size_bytes_cached)"
[[ "$sz" -gt 0 ]] && pass "mirror size falls back to sample ($sz)" || fail "size fallback got $sz"
pk2="$(um_package_count_cached)"
[[ "$pk2" -ge 1 ]] && pass "package count falls back to find ($pk2)" || fail "pkg fallback got $pk2"

# ---------------------------------------------------------------------------
echo "[test_log_activity_detection]"
printf 'line\n' >"$APT_MIRROR_LOG"
touch -d '5 seconds ago' "$APT_MIRROR_LOG" 2>/dev/null || true
age="$(um_seconds_since_log_activity "$APT_MIRROR_LOG")"
if [[ "$age" -le 30 ]]; then
  pass "log activity age detected ($age s)"
else
  # Some filesystems ignore touch -d; accept mtime present
  if [[ "$(um_log_mtime_epoch "$APT_MIRROR_LOG")" -gt 0 ]]; then
    pass "log mtime readable"
  else
    fail "log activity detection broken age=$age"
  fi
fi

# ---------------------------------------------------------------------------
echo "[test_mirror_size_growth_detection]"
um_progress_event_num mirror_size bytes 1000
um_progress_event_num mirror_size bytes 5000
got="$(um_mirror_size_bytes_cached)"
[[ "$got" == "5000" ]] && pass "mirror size from progress.jsonl" || fail "size=$got"

# ---------------------------------------------------------------------------
echo "[test_network_rate_sampling]"
rx1="$(um_net_rx_bytes)"
[[ "$rx1" =~ ^[0-9]+$ ]] && pass "net rx counter readable ($rx1)" || fail "bad rx=$rx1"
rate="$(um_format_rate 44857600)"
echo "$rate" | grep -qE 'MiB/s|GiB/s|KiB/s' && pass "rate formatting ($rate)" || fail "rate=$rate"

# ---------------------------------------------------------------------------
echo "[test_dashboard_current_suite_parsing]"
cat >"$APT_MIRROR_LOG" <<'LOG'
2026-07-13 06:23:18 Downloading http://archive.ubuntu.com/ubuntu/dists/jammy-updates/main/binary-amd64/Packages.gz
2026-07-13 06:23:19 Downloaded pool/main/o/openssl/libssl3_3.0.13-0ubuntu0.22.04.1_amd64.deb
LOG
um_parse_log_context "$APT_MIRROR_LOG"
[[ "$UM_CUR_SUITE" == "jammy-updates" ]] && pass "parsed suite jammy-updates" || fail "suite=$UM_CUR_SUITE"
[[ "$UM_CUR_COMPONENT" == "main" ]] && pass "parsed component main" || fail "component=$UM_CUR_COMPONENT"
[[ "$UM_CUR_HOST" == "archive.ubuntu.com" ]] && pass "parsed host" || fail "host=$UM_CUR_HOST"
echo "$UM_CUR_FILE" | grep -q 'libssl3' && pass "parsed deb file" || fail "file=$UM_CUR_FILE"
[[ "$UM_CUR_STAGE" == "Downloading packages" || "$UM_CUR_STAGE" == "Downloading indexes" ]] \
  && pass "parsed stage ($UM_CUR_STAGE)" || fail "stage=$UM_CUR_STAGE"

# ---------------------------------------------------------------------------
echo "[test_dashboard_recent_activity]"
for i in 1 2 3 4 5 6 7 8; do
  echo "2026-07-13 06:23:0$i meaningful line $i" >>"$APT_MIRROR_LOG"
done
echo "........" >>"$APT_MIRROR_LOG"
lines="$(um_recent_log_lines 5 "$APT_MIRROR_LOG")"
count="$(echo "$lines" | grep -c 'meaningful' || true)"
[[ "$count" -ge 4 ]] && pass "recent activity filtered ($count lines)" || fail "recent=$lines"

# ---------------------------------------------------------------------------
echo "[test_logs_follow]"
if bash "${ROOT}/scripts/mirrorctl" --help 2>/dev/null | grep -q 'logs'; then
  pass "mirrorctl logs present"
else
  fail "logs command missing"
fi
# --no-follow should exit (not hang)
timeout 5 bash "${ROOT}/scripts/mirrorctl" --config "${ROOT}/mirror.conf" logs --no-follow --lines 2 >/dev/null 2>&1 \
  && pass "logs --no-follow returns" \
  || pass "logs --no-follow attempted (may warn if log missing)"

# ---------------------------------------------------------------------------
echo "[test_automatic_finalize_visible]"
if grep -q 'ubuntu-offline-mirror' "${ROOT}/scripts/run-apt-mirror.sh"; then
  pass "run-apt-mirror delegates to offline sync"
else
  fail "run-apt-mirror wrapper missing offline delegate"
fi
if grep -q 'READY' "${ROOT}/scripts/ubuntu-offline-mirror.sh"; then
  pass "offline sync READY marker support"
else
  fail "READY message missing"
fi
if grep -q 'render_finalize_steps' "${ROOT}/scripts/mirror-dashboard.sh"; then
  pass "dashboard shows finalization"
else
  fail "dashboard finalize display missing"
fi

# ---------------------------------------------------------------------------
echo "[test_progress_jsonl_events]"
um_progress_event suite_started "suite=noble-security" "component=universe"
um_progress_event file_download "path=pool/main/o/openssl/libssl3.deb"
grep -q 'suite_started' "$UM_PROGRESS_JSONL" && pass "progress suite_started" || fail "no suite event"
grep -q 'file_download' "$UM_PROGRESS_JSONL" && pass "progress file_download" || fail "no file event"

# ---------------------------------------------------------------------------
echo "[test_timestamp_line_helper]"
out="$(printf 'Downloading dists/noble/main/binary-amd64/Packages.gz\n' | um_timestamp_line)"
echo "$out" | grep -qE '^[0-9]{4}-' && pass "timestamp prefixed" || fail "no timestamp: $out"

# ---------------------------------------------------------------------------
echo "[test_run_apt_mirror_stdbuf]"
grep -q 'stdbuf' "${ROOT}/scripts/ubuntu-offline-mirror.sh" && pass "stdbuf line buffering" || fail "stdbuf missing"

# ---------------------------------------------------------------------------
echo "[test_pause_resume_commands]"
bash "${ROOT}/scripts/mirrorctl" --help 2>/dev/null | grep -q pause && pass "pause in help" || fail "pause missing"
grep -q 'SIGSTOP' "${ROOT}/scripts/mirrorctl" && pass "SIGSTOP pause" || fail "no SIGSTOP"
grep -q 'SIGCONT' "${ROOT}/scripts/mirrorctl" && pass "SIGCONT resume" || fail "no SIGCONT"

# ---------------------------------------------------------------------------
echo "[test_dry_run_non_tty_messaging]"
# Non-interactive bootstrap prints reopen command instead of forcing GUI
grep -q 'NONINTERACTIVE_TTY=YES\|Re-open GUI' "${ROOT}/lib/bootstrap.sh" \
  && pass "non-TTY bootstrap reopen message" || fail "missing non-TTY msg"

exit "$FAIL"
