#!/usr/bin/env bash
# mirror-dashboard.sh — SSH-friendly interactive sync dashboard (TUI)
# Installed as /usr/local/bin/mirror-dashboard; also invoked via: mirrorctl watch
set -euo pipefail

resolve_libs() {
  if [[ -f /usr/local/lib/ubuntu-mirror/common.sh ]]; then
    # shellcheck source=/dev/null
    source /usr/local/lib/ubuntu-mirror/common.sh
    # shellcheck source=/dev/null
    source /usr/local/lib/ubuntu-mirror/config.sh
    # shellcheck source=/dev/null
    source /usr/local/lib/ubuntu-mirror/state.sh
    # shellcheck source=/dev/null
    source /usr/local/lib/ubuntu-mirror/progress.sh
    UM_SRC_ROOT="/usr/local/lib/ubuntu-mirror"
  else
    UM_SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=lib/common.sh
    source "${UM_SRC_ROOT}/lib/common.sh"
    # shellcheck source=lib/config.sh
    source "${UM_SRC_ROOT}/lib/config.sh"
    # shellcheck source=lib/state.sh
    source "${UM_SRC_ROOT}/lib/state.sh"
    # shellcheck source=lib/progress.sh
    source "${UM_SRC_ROOT}/lib/progress.sh"
  fi
}

resolve_libs

UM_CONFIG_ARG=""
DASH_INTERVAL=20
DASH_NO_COLOR=0
DASH_ONCE=0
DASH_RAW=0
DASH_MODE="dashboard"   # dashboard | logs | status
DASH_ATTACH="foreground"
PREV_RX=0
PREV_DISK=0
PREV_SIZE=0
PREV_TS=0
CUR_RX_RATE=0
CUR_DISK_RATE=0
CUR_SIZE_DELTA=0
PAUSE_SUPPORTED=0
# Legacy sync mutation is disabled in production. The dashboard remains useful
# for observation, but Pause/Resume may only be exercised by explicit dual-
# hermetic tests of the retired control plane.
if [[ "${MM_HERMETIC_TEST_MODE:-0}" == "1" \
  && "${MIRRORCTL_ALLOW_LEGACY_MUTATION:-0}" == "1" ]]; then
  PAUSE_SUPPORTED=1
fi

usage() {
  cat <<'EOF'
Usage: mirror-dashboard [OPTIONS]

Live terminal dashboard for Ubuntu Mirror synchronization.

Options:
  --config PATH    Config file
  --interval N     Refresh interval seconds (default 20)
  --no-color       Disable ANSI colors
  --once           Print one snapshot and exit
  --raw            Follow raw apt-mirror.log instead of TUI
  --help           Show help

Keyboard (interactive TUI):
  F  Foreground attach   B  Background detach
  L  Raw log view        S  Detailed status
  P  Pause sync          R  Resume sync
  Q  Detach / quit       Ctrl+C  Detach (sync continues)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        UM_CONFIG_ARG="${2:-}"
        [[ -n "$UM_CONFIG_ARG" ]] || um_die "--config requires a path"
        shift 2
        ;;
      --interval)
        DASH_INTERVAL="${2:-20}"
        shift 2
        ;;
      --no-color) DASH_NO_COLOR=1; shift ;;
      --once) DASH_ONCE=1; shift ;;
      --raw) DASH_RAW=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) um_die "Unknown option: $1" ;;
    esac
  done
}

setup_colors() {
  if [[ "$DASH_NO_COLOR" == "1" ]] || [[ ! -t 1 ]] || [[ "${NO_COLOR:-0}" == "1" ]]; then
    C_RESET="" C_BOLD="" C_DIM="" C_GREEN="" C_YELLOW="" C_RED=""
  else
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
  fi
}

is_tty() { [[ -t 1 ]]; }

hide_cursor() { is_tty && tput civis 2>/dev/null || true; }
show_cursor() { is_tty && tput cnorm 2>/dev/null || true; }
clear_screen() {
  if is_tty; then
    tput clear 2>/dev/null || printf '\033[2J\033[H'
  fi
}
home_cursor() {
  if is_tty; then
    tput cup 0 0 2>/dev/null || printf '\033[H'
  fi
}

cleanup_ui() {
  show_cursor
  if is_tty; then
    tput sgr0 2>/dev/null || true
    printf '\n'
  fi
}

# Ctrl+C / TERM: detach only — never stop apt-mirror.service
on_detach_signal() {
  cleanup_ui
  printf '%sDetached. Synchronization continues in the background.%s\n' "$C_YELLOW" "$C_RESET"
  printf 'Reattach: sudo mirrorctl watch\n'
  printf 'Stop sync: sudo mirrorctl sync stop\n'
  exit 0
}

sample_rates() {
  local now rx disk size dt used_kib
  now="$(date +%s)"
  rx="$(um_net_rx_bytes)"
  disk="$(um_disk_write_sectors)"
  size="$(um_mirror_size_bytes_cached)"
  if [[ "${size:-0}" -eq 0 ]]; then
    # Lightweight fallback: filesystem used blocks * 1024
    used_kib="$(um_df_used_kib "${BASE_PATH:-/}")"
    used_kib="${used_kib:-0}"
    size=$(( used_kib * 1024 ))
  fi

  if [[ "$PREV_TS" -gt 0 ]]; then
    dt=$((now - PREV_TS))
    if [[ "$dt" -lt 1 ]]; then dt=1; fi
    CUR_RX_RATE=$(( (rx - PREV_RX) / dt ))
    if [[ "$CUR_RX_RATE" -lt 0 ]]; then CUR_RX_RATE=0; fi
    # diskstats sectors ~512 bytes
    CUR_DISK_RATE=$(( ((disk - PREV_DISK) * 512) / dt ))
    if [[ "$CUR_DISK_RATE" -lt 0 ]]; then CUR_DISK_RATE=0; fi
    CUR_SIZE_DELTA=$((size - PREV_SIZE))
    if [[ "$CUR_SIZE_DELTA" -lt 0 ]]; then CUR_SIZE_DELTA=0; fi
  fi

  PREV_RX="$rx"
  PREV_DISK="$disk"
  PREV_SIZE="$size"
  PREV_TS="$now"
}

health_color() {
  case "$1" in
    HEALTHY|COMPLETE) printf '%s' "$C_GREEN" ;;
    WAITING) printf '%s' "$C_YELLOW" ;;
    STALLED|FAILED) printf '%s' "$C_RED" ;;
    *) printf '%s' "$C_DIM" ;;
  esac
}

render_finalize_steps() {
  local flog
  flog="$(um_finalize_log_path)"
  if [[ -f "$flog" ]]; then
    tail -n 12 "$flog" 2>/dev/null || true
    return
  fi
  if um_is_mirror_ready; then
    printf '[OK] Mirror state READY\n'
  elif um_has_marker "initial-sync-complete"; then
    printf '[OK] Initial synchronization completed\n'
    printf '[WAITING] Finalization pending — sudo mirrorctl finalize\n'
  fi
}

render_failure_block() {
  local reason err disk_line pct avail_gib avail_kib
  reason="${UM_HEALTH_REASON:-unknown}"
  err="$(um_last_error_from_log)"
  pct="$(um_disk_usage_percent "${BASE_PATH}" 2>/dev/null || echo "?")"
  avail_kib="$(um_df_avail_kib "${BASE_PATH}")"
  avail_kib="${avail_kib:-0}"
  avail_gib=$(( avail_kib / 1024 / 1024 ))
  disk_line="${pct}% used, ${avail_gib} GiB free"

  printf '%sSYNC_FAILED%s\n\n' "$C_RED" "$C_RESET"
  printf 'Reason:\n  %s\n' "$reason"
  if [[ -n "$err" ]]; then
    printf '\nLast meaningful error:\n  %s\n' "$err"
  fi
  printf '\nDisk:\n  %s\n' "$disk_line"
  printf '\nService result: %s\n' "$(um_service_result)"
  printf '\nRecommended action:\n'
  printf '  sudo mirrorctl status\n'
  printf '  sudo mirrorctl recover\n'
  printf '  sudo mirrorctl logs\n'
}

render_dashboard() {
  sample_rates
  um_parse_log_context
  local log_age size_delta net_delta disk_delta
  log_age="$(um_seconds_since_log_activity)"
  size_delta="${CUR_SIZE_DELTA:-0}"
  net_delta="${CUR_RX_RATE:-0}"
  disk_delta="${CUR_DISK_RATE:-0}"
  um_detect_sync_health "$log_age" "$size_delta" "$net_delta" "$disk_delta"

  local host elapsed mirror_bytes pkg_count disk_pct disk_free inode_pct
  local log_bytes suites expected timer_line hc used_kib avail_kib
  host="$(hostname -f 2>/dev/null || hostname || echo unknown)"
  elapsed="$(um_format_duration "$(um_sync_elapsed_sec)")"
  mirror_bytes="$(um_mirror_size_bytes_cached)"
  if [[ "${mirror_bytes:-0}" -eq 0 ]]; then
    used_kib="$(um_df_used_kib "${BASE_PATH}")"
    used_kib="${used_kib:-0}"
    mirror_bytes=$(( used_kib * 1024 ))
  fi
  pkg_count="$(um_package_count_cached)"
  pkg_count="${pkg_count:-0}"
  disk_pct="$(um_disk_usage_percent "${BASE_PATH}" 2>/dev/null || echo "?")"
  avail_kib="$(um_df_avail_kib "${BASE_PATH}")"
  avail_kib="${avail_kib:-0}"
  disk_free="$(um_format_bytes $(( avail_kib * 1024 )))"
  inode_pct="$(um_inode_usage_percent "${BASE_PATH}" 2>/dev/null || echo "?")"
  log_bytes="$(um_log_size_bytes)"
  suites="$(um_suites_with_release)"
  expected="$(um_expected_suite_count)"

  if systemctl is-enabled --quiet apt-mirror.timer 2>/dev/null; then
    timer_line="enabled"
  else
    timer_line="disabled until initial sync completes"
  fi

  hc="$(health_color "${UM_HEALTH_STATE}")"

  local cur_item
  if [[ -n "${UM_CUR_FILE}" ]]; then
    cur_item="$UM_CUR_FILE"
  elif [[ -n "${UM_CUR_SUITE}" ]]; then
    cur_item="${UM_CUR_SUITE}/${UM_CUR_COMPONENT:-?}"
  else
    cur_item="waiting for apt-mirror output"
  fi

  local stage="${UM_CUR_STAGE:-waiting for apt-mirror output}"
  local box_w=60

  # Build frame
  printf '%s┌──────────────── Ubuntu Mirror Installation ────────────────┐%s\n' "$C_BOLD" "$C_RESET"
  printf '│ %-12s %-45s │\n' "Host" "${host:0:45}"
  printf '│ %-12s %-45s │\n' "Mirror URL" "${MIRROR_URL}/ubuntu"
  local profile_label="offline-upgrade-full"
  local profile_support="supported"
  local overall_ready="${UM_LIFECYCLE_STATE}"
  if [[ "${MIRROR_MODE}" == "minimal" ]]; then
    profile_label="minimal (UNSUPPORTED)"
    profile_support="BLOCKED"
    overall_ready="BLOCKED"
    hc="$(health_color FAILED 2>/dev/null || printf '%s' "$hc")"
  fi
  local ready_json="${BASE_PATH}/offline/readiness-validation.json"
  if [[ -f "$ready_json" ]] && command -v python3 >/dev/null 2>&1; then
    overall_ready="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("overall","?"))' "$ready_json" 2>/dev/null || echo "$overall_ready")"
  fi
  printf '│ %-12s %-45s │\n' "Profile" "${profile_label:0:45}"
  printf '│ %-12s %-45s │\n' "Mode" "${MIRROR_MODE}"
  printf '│ %-12s %-45s │\n' "Supported" "${profile_support:0:45}"
  printf '│ %-12s %-45s │\n' "Attachment" "${DASH_ATTACH}"
  printf '│ %-12s %-45s │\n' "Phase" "Initial synchronization"
  printf '│ %-12s %s%-45s%s │\n' "State" "$hc" "${overall_ready}" "$C_RESET"
  printf '│ %-12s %-45s │\n' "Health" "${UM_HEALTH_STATE}"
  printf '│ %-12s %-45s │\n' "Elapsed" "$elapsed"
  printf '│ %-12s %-45s │\n' "Versions" "${UBUNTU_VERSIONS:0:45}"
  printf '│ %-12s %-45s │\n' "Components" "${MIRROR_COMPONENTS:0:45}"
  printf '│ %-12s %-45s │\n' "Pockets" "base updates security backports"
  printf '├────────────────────────────────────────────────────────────┤\n'
  printf '│ %-12s %-45s │\n' "Current stage" "${stage:0:45}"
  printf '│ %-12s %-45s │\n' "Current source" "${UM_CUR_HOST:-${UPSTREAM_MIRROR##*://}}"
  printf '│ %-12s %-45s │\n' "Current suite" "${UM_CUR_SUITE:-—}"
  printf '│ %-12s %-45s │\n' "Component" "${UM_CUR_COMPONENT:-—}"
  printf '│ %-12s %-45s │\n' "Architecture" "${UM_CUR_ARCH:-${DEFAULT_ARCH}}"
  printf '│ %-12s %-45s │\n' "Current file" "${cur_item:0:45}"
  printf '│ %-12s %-45s │\n' "Detail" "${UM_HEALTH_REASON:0:45}"
  printf '├────────────────────────────────────────────────────────────┤\n'
  printf '│ %-12s %-45s │\n' "Mirror size" "$(um_format_bytes "$mirror_bytes")"
  printf '│ %-12s %-45s │\n' "Packages" "$(printf '%s' "$pkg_count" | sed 's/.*/&/; :a; s/\B[0-9]\{3\}\>/,&/; ta') .deb files"
  printf '│ %-12s %-45s │\n' "Disk usage" "${disk_pct}% / ${disk_free} free"
  printf '│ %-12s %-45s │\n' "Inodes" "${inode_pct}% used"
  printf '│ %-12s %-45s │\n' "Suites" "${suites} of ${expected} with Release"
  printf '│ %-12s %-45s │\n' "Network" "$(um_format_rate "$CUR_RX_RATE")"
  printf '│ %-12s %-45s │\n' "Disk write" "$(um_format_rate "$CUR_DISK_RATE")"
  printf '│ %-12s %-45s │\n' "Log size" "$(um_format_bytes "$log_bytes")"
  printf '│ %-12s %-45s │\n' "Last activity" "${log_age} seconds ago"
  printf '│ %-12s %-45s │\n' "Timer" "${timer_line:0:45}"
  printf '├────────────────────────────────────────────────────────────┤\n'
  printf '│ Recent activity%-45s │\n' ""
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Truncate to fit
    printf '│   %-56s │\n' "${line:0:56}"
  done < <(um_recent_log_lines 6)

  if [[ "${UM_LIFECYCLE_STATE}" == "FINALIZING" ]] || [[ "${UM_LIFECYCLE_STATE}" == "SYNC_COMPLETE" ]] || [[ "${UM_LIFECYCLE_STATE}" == "READY" ]]; then
    printf '├────────────────────────────────────────────────────────────┤\n'
    printf '│ Finalization%-47s │\n' ""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      printf '│   %-56s │\n' "${line:0:56}"
    done < <(render_finalize_steps)
  fi

  if [[ "${UM_LIFECYCLE_STATE}" == "SYNC_FAILED" ]]; then
    printf '├────────────────────────────────────────────────────────────┤\n'
    while IFS= read -r line; do
      printf '│ %-58s │\n' "${line:0:58}"
    done < <(render_failure_block)
  fi

  printf '├────────────────────────────────────────────────────────────┤\n'
  if [[ "$PAUSE_SUPPORTED" -eq 1 ]]; then
    printf '│ [F] Foreground  [B] Background  [L] Logs  [S] Status       │\n'
    printf '│ [P] Pause       [R] Resume      [Q] Detach                 │\n'
  else
    printf '│ [F] Foreground  [B] Background  [L] Logs  [S] Status       │\n'
    printf '│ [Q] Detach   Pause: not supported safely by this runtime   │\n'
  fi
  printf '└────────────────────────────────────────────────────────────┘\n'

  # Silence unused
  : "$box_w"
}

render_status_detail() {
  um_detect_sync_health
  cat <<EOF
${C_BOLD}Detailed status${C_RESET}

Lifecycle:  ${UM_LIFECYCLE_STATE}
Health:     ${UM_HEALTH_STATE}
Reason:     ${UM_HEALTH_REASON}
Service:    $(um_service_active_state) / $(um_service_sub_state) (result=$(um_service_result))
Process:    $(um_is_sync_running && echo running || echo not-running)
Paused:     $(um_is_sync_paused && echo yes || echo no)
Log:        ${APT_MIRROR_LOG}
Progress:   $(um_progress_jsonl_path)
Finalize:   $(um_finalize_log_path)

Press any key to return to dashboard...
EOF
}

cmd_pause() {
  if [[ "$PAUSE_SUPPORTED" -ne 1 ]]; then
    return
  fi
  if ! um_is_sync_running && ! pgrep -f 'run-apt-mirror\.sh' >/dev/null 2>&1; then
    return
  fi
  systemctl kill -s SIGSTOP apt-mirror.service 2>/dev/null || true
  # Also stop children if present outside main PID
  local pid
  for pid in $(um_apt_mirror_pids); do
    kill -STOP "$pid" 2>/dev/null || true
  done
  um_progress_event pause "reason=operator"
}

cmd_resume() {
  if [[ "$PAUSE_SUPPORTED" -ne 1 ]]; then
    return
  fi
  systemctl kill -s SIGCONT apt-mirror.service 2>/dev/null || true
  local pid
  for pid in $(um_apt_mirror_pids); do
    kill -CONT "$pid" 2>/dev/null || true
  done
  um_progress_event resume "reason=operator"
}

follow_raw_logs() {
  cleanup_ui
  printf 'Raw log: %s (Ctrl+C returns to dashboard / detaches)\n' "$APT_MIRROR_LOG"
  if [[ -f "$APT_MIRROR_LOG" ]]; then
    tail -n 50 -f "$APT_MIRROR_LOG" || true
  else
    journalctl -u apt-mirror.service -f || true
  fi
}

print_snapshot_plain() {
  # Non-TTY / --once: no cursor control
  sample_rates
  um_parse_log_context
  local log_age
  log_age="$(um_seconds_since_log_activity)"
  um_detect_sync_health "$log_age" "${CUR_SIZE_DELTA:-0}" "${CUR_RX_RATE:-0}" "${CUR_DISK_RATE:-0}"
  cat <<EOF
Ubuntu Mirror Server
Host: $(hostname)
Mirror URL: ${MIRROR_URL}/ubuntu
Mode: ${MIRROR_MODE}
Attachment: ${DASH_ATTACH}
State: ${UM_LIFECYCLE_STATE}
Health: ${UM_HEALTH_STATE}
Reason: ${UM_HEALTH_REASON}
Elapsed: $(um_format_duration "$(um_sync_elapsed_sec)")
Stage: ${UM_CUR_STAGE:-waiting for apt-mirror output}
Suite: ${UM_CUR_SUITE:-—}
File: ${UM_CUR_FILE:-waiting for apt-mirror output}
Mirror size: $(um_format_bytes "$(um_mirror_size_bytes_cached)")
Packages: $(um_package_count_cached)
Disk: $(um_disk_usage_percent "${BASE_PATH}" 2>/dev/null || echo ?)% used
Network: $(um_format_rate "$CUR_RX_RATE")
Last log activity: ${log_age}s ago
EOF
}

handle_key() {
  local key="$1"
  case "$key" in
    q|Q)
      on_detach_signal
      ;;
    b|B)
      DASH_ATTACH="background"
      on_detach_signal
      ;;
    f|F)
      DASH_ATTACH="foreground"
      DASH_MODE="dashboard"
      ;;
    l|L)
      DASH_MODE="logs"
      follow_raw_logs
      DASH_MODE="dashboard"
      hide_cursor
      clear_screen
      ;;
    s|S)
      clear_screen
      render_status_detail
      # wait for key
      read -r -n 1 -t 60 _ || true
      clear_screen
      DASH_MODE="dashboard"
      ;;
    p|P)
      cmd_pause
      ;;
    r|R)
      cmd_resume
      ;;
  esac
}

run_interactive() {
  trap on_detach_signal INT TERM
  trap cleanup_ui EXIT
  hide_cursor
  clear_screen

  # Initial sample so rates are non-zero on second frame
  sample_rates
  sleep 0.3

  local key
  while true; do
    home_cursor
    # Clear to end of screen each frame for clean redraw
    if is_tty; then
      tput ed 2>/dev/null || true
    fi
    render_dashboard

    # Exit automatically when ready (foreground attach stays until complete)
    if [[ "$DASH_ATTACH" == "foreground" ]]; then
      if [[ "${UM_LIFECYCLE_STATE}" == "READY" ]] || [[ "${UM_LIFECYCLE_STATE}" == "SYNC_COMPLETE" ]]; then
        printf '\n%sSynchronization finished (%s).%s\n' "$C_GREEN" "$UM_LIFECYCLE_STATE" "$C_RESET"
        render_finalize_steps
        sleep 2
        break
      fi
      if [[ "${UM_LIFECYCLE_STATE}" == "SYNC_FAILED" ]]; then
        sleep 5
        # Keep showing failure until user detaches
      fi
    fi

    key=""
    # Wait up to DASH_INTERVAL for a key; if read fails instantly (no TTY),
    # sleep so we never busy-loop redraw.
    local t0 t1 elapsed remaining
    t0="$(date +%s)"
    if read -r -n 1 -t "$DASH_INTERVAL" key 2>/dev/null; then
      handle_key "$key"
    else
      t1="$(date +%s)"
      elapsed=$((t1 - t0))
      remaining=$((DASH_INTERVAL - elapsed))
      if [[ "${remaining}" -gt 0 ]]; then
        sleep "${remaining}"
      fi
    fi
  done
  cleanup_ui
}

main() {
  parse_args "$@"
  UM_QUIET_LOAD=1
  um_load_config "$UM_CONFIG_ARG"
  # Silence config "Loaded" noise for TUI
  setup_colors

  # Stall threshold from config if set
  UM_STALL_THRESHOLD_SEC="${STALL_THRESHOLD_SEC:-600}"
  UM_WAITING_THRESHOLD_SEC="${WAITING_THRESHOLD_SEC:-30}"

  if [[ "$DASH_RAW" == "1" ]]; then
    if [[ -f "$APT_MIRROR_LOG" ]]; then
      tail -n 100 -f "$APT_MIRROR_LOG"
    else
      journalctl -u apt-mirror.service -n 100 -f
    fi
    exit 0
  fi

  if [[ "$DASH_ONCE" == "1" ]] || ! is_tty; then
    print_snapshot_plain
    exit 0
  fi

  run_interactive
}

main "$@"
