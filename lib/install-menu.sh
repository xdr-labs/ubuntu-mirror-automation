#!/usr/bin/env bash
# shellcheck shell=bash
# Interactive installer menu — whiptail TUI (SSH-friendly).
#
# Keyboard model (same as XDR whiptail menus):
#   ↑ / ↓     move in the list
#   Tab       switch focus (list ↔ OK ↔ Cancel)
#   Enter     select / confirm (OK)
#   Esc       leave dialog (same as Cancel)

# shellcheck disable=SC2317
if [[ -n "${UM_INSTALL_MENU_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
UM_INSTALL_MENU_LOADED=1

# Classic dialog look (magenta root, gray window, red selection).
# Full buttons (--fb) use button/actbutton; compact uses compactbutton/actcompactbutton.
# Missing actcompactbutton makes Tab focus on Cancel invisible / unreliable.
um_menu_set_newt_colors() {
  export NEWT_COLORS='
root=white,magenta
border=black,lightgray
window=black,lightgray
shadow=black,blue
title=red,lightgray
button=black,lightgray
actbutton=white,green
compactbutton=black,lightgray
actcompactbutton=white,green
checkbox=black,lightgray
actcheckbox=white,blue
entry=black,lightgray
label=black,lightgray
listbox=black,lightgray
actlistbox=white,red
sellistbox=black,lightgray
actsellistbox=white,red
textbox=black,lightgray
acttextbox=black,lightgray
roottext=black,magenta
emptyscale=,gray
fullscale=,blue
disentry=gray,lightgray
helpline=black,lightgray
'
}

um_menu_is_tty() {
  [[ -t 0 ]] && [[ -t 1 ]]
}

um_menu_has_whiptail() {
  command -v whiptail >/dev/null 2>&1
}

um_should_show_install_menu() {
  if [[ "${UM_FORCE_MENU:-0}" == "1" ]]; then
    um_menu_is_tty || return 1
    return 0
  fi
  if [[ "${UM_NO_MENU:-0}" == "1" ]]; then
    return 1
  fi
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    return 1
  fi
  if [[ "${UM_FULL:-0}" == "1" ]] || [[ "${UM_MINIMAL:-0}" == "1" ]]; then
    return 1
  fi
  if [[ "${UM_NO_SYNC:-0}" == "1" ]]; then
    return 1
  fi
  if [[ "${UM_SYNC_MODE:-auto}" != "auto" ]]; then
    return 1
  fi
  um_menu_is_tty
}

um_menu_existing_data_gib() {
  local root="${BASE_PATH:-/var/spool/apt-mirror}"
  if [[ -d "$root" ]]; then
    du -sb "$root" 2>/dev/null | awk '{printf "%.1f", $1/1024/1024/1024}'
  else
    printf '0'
  fi
}

um_menu_sync_label() {
  if um_is_sync_running 2>/dev/null; then
    printf 'RUNNING'
  elif um_is_mirror_ready 2>/dev/null; then
    printf 'READY'
  elif um_initial_sync_complete 2>/dev/null; then
    printf 'SYNC_COMPLETE'
  elif um_is_installed 2>/dev/null; then
    printf 'INSTALLED'
  else
    printf 'NOT_INSTALLED'
  fi
}

um_menu_status_blurb() {
  local host data_gib sync_label disk_free avail_kib
  host="$(hostname 2>/dev/null || echo unknown)"
  data_gib="$(um_menu_existing_data_gib)"
  sync_label="$(um_menu_sync_label)"
  avail_kib="$(um_df_avail_kib "${BASE_PATH:-/}" 2>/dev/null || echo 0)"
  disk_free="$(( avail_kib / 1024 / 1024 )) GiB free"
  printf '%s | %s | data %s GiB | %s' "$host" "$sync_label" "$data_gib" "$disk_free"
}

um_menu_keys_hint() {
  printf '↑↓ move   Tab = OK/Cancel   Enter = select   Esc = back'
}

# ---------------------------------------------------------------------------
# Whiptail sizing — prefer content fit over full-screen centering.
# Oversized empty text regions steal Tab focus away from OK/Cancel.
# ---------------------------------------------------------------------------

um_term_size() {
  # Sets HEIGHT WIDTH (best-effort).
  if command -v tput >/dev/null 2>&1; then
    HEIGHT="$(tput lines 2>/dev/null || true)"
    WIDTH="$(tput cols 2>/dev/null || true)"
  fi
  [[ -z "${HEIGHT:-}" ]] && HEIGHT=25
  [[ -z "${WIDTH:-}" ]] && WIDTH=100
}

um_calc_menu_size() {
  # um_calc_menu_size <item_count> [min_width] [min_menu_height]
  # Prints: dialog_height dialog_width menu_list_height
  local item_count="$1"
  local min_width="${2:-74}"
  local min_list="${3:-8}"
  local HEIGHT WIDTH dialog_height dialog_width menu_list_height max_list

  um_term_size
  # Header (~5) + buttons (~3) + border; keep list fully visible when possible.
  menu_list_height=$((item_count + 1))
  [[ "${menu_list_height}" -lt "${min_list}" ]] && menu_list_height="${min_list}"
  dialog_height=$((menu_list_height + 10))
  max_list=$((HEIGHT - 12))
  [[ "${max_list}" -lt 6 ]] && max_list=6
  if [[ "${menu_list_height}" -gt "${max_list}" ]]; then
    menu_list_height="${max_list}"
    dialog_height=$((HEIGHT - 2))
  fi
  [[ "${dialog_height}" -gt $((HEIGHT - 2)) ]] && dialog_height=$((HEIGHT - 2))
  [[ "${dialog_height}" -lt 14 ]] && dialog_height=14

  dialog_width=$((WIDTH - 6))
  [[ "${dialog_width}" -lt "${min_width}" ]] && dialog_width="${min_width}"
  [[ "${dialog_width}" -gt 100 ]] && dialog_width=100
  [[ "${dialog_width}" -gt $((WIDTH - 2)) ]] && dialog_width=$((WIDTH - 2))

  echo "${dialog_height} ${dialog_width} ${menu_list_height}"
}

um_calc_dialog_size() {
  # um_calc_dialog_size <line_count> [min_width] [extra_rows]
  # Prints: dialog_height dialog_width  (content-fitted, not full-screen)
  local line_count="${1:-4}"
  local min_width="${2:-70}"
  local extra="${3:-6}"
  local HEIGHT WIDTH dialog_height dialog_width

  um_term_size
  [[ "${line_count}" -lt 1 ]] && line_count=1
  dialog_height=$((line_count + extra))
  [[ "${dialog_height}" -lt 10 ]] && dialog_height=10
  [[ "${dialog_height}" -gt $((HEIGHT - 2)) ]] && dialog_height=$((HEIGHT - 2))
  [[ "${dialog_height}" -gt 28 ]] && dialog_height=28

  dialog_width=$((WIDTH - 6))
  [[ "${dialog_width}" -lt "${min_width}" ]] && dialog_width="${min_width}"
  [[ "${dialog_width}" -gt 96 ]] && dialog_width=96
  [[ "${dialog_width}" -gt $((WIDTH - 2)) ]] && dialog_width=$((WIDTH - 2))

  echo "${dialog_height} ${dialog_width}"
}

# ---------------------------------------------------------------------------
# Whiptail helpers — ALWAYS --fb; never full-screen empty text traps
# Dialog inventory (all go through these helpers):
#   menu     → um_whiptail_menu     (main menu)
#   yesno    → um_whiptail_yesno    (stop/delete/install confirms)
#   msgbox   → um_whiptail_msg      (status, errors, notices)
#   inputbox → um_whiptail_input    (DELETE confirm)
# ---------------------------------------------------------------------------

# Truncate body so msgbox/yesno stay content-fitted (no scrollable text focus trap).
um_whiptail_fit_body() {
  local body="$1" max_lines="${2:-16}"
  local line_count
  line_count="$(printf '%b' "$body" | wc -l)"
  if [[ "${line_count}" -gt "${max_lines}" ]]; then
    printf '%b\n...(truncated)' "$(printf '%b' "$body" | head -n "$((max_lines - 1))")"
  else
    printf '%b' "$body"
  fi
}

um_whiptail_menu() {
  # um_whiptail_menu <title> <text> <tag1> <item1> ...
  local title="$1" text="$2"
  shift 2
  local item_count=$(( $# / 2 ))
  local menu_dims menu_height menu_width menu_list_height menu_msg

  um_menu_set_newt_colors
  menu_dims="$(um_calc_menu_size "${item_count}" 74 8)"
  read -r menu_height menu_width menu_list_height <<< "${menu_dims}"
  # Minimal header only — no vertical centering padding (steals Tab).
  menu_msg="$(printf '%b\n\n%s' "$text" "$(um_menu_keys_hint)")"

  whiptail --title "${title}" --fb \
    --ok-button "OK" --cancel-button "Cancel" \
    --menu "${menu_msg}" \
    "${menu_height}" "${menu_width}" "${menu_list_height}" \
    "$@" \
    3>&1 1>&2 2>&3
}

um_whiptail_yesno() {
  # um_whiptail_yesno <title> <text> [default_no=0]
  local title="$1" text="$2" default_no="${3:-0}"
  local dialog_dims dialog_height dialog_width body line_count
  local -a extra=()

  if ! um_menu_has_whiptail; then
    printf '%s\n%s\n' "$title" "$(printf '%b' "$text")"
    if [[ "$default_no" == "1" ]]; then
      printf '[y/N] '
      local ans
      read -r ans || true
      [[ "$ans" =~ ^[Yy]$ ]]
    else
      printf '[Y/n] '
      local ans
      read -r ans || true
      [[ ! "$ans" =~ ^[Nn]$ ]]
    fi
    return $?
  fi

  [[ "$default_no" == "1" ]] && extra+=(--defaultno)
  um_menu_set_newt_colors
  body="$(um_whiptail_fit_body "$(printf '%b\n\n%s' "$text" "$(um_menu_keys_hint)")" 14)"
  line_count="$(printf '%b' "$body" | wc -l)"
  dialog_dims="$(um_calc_dialog_size "${line_count}" 70 6)"
  read -r dialog_height dialog_width <<< "${dialog_dims}"

  whiptail --title "${title}" --fb \
    --yes-button "OK" --no-button "Cancel" \
    "${extra[@]}" \
    --yesno "${body}" "${dialog_height}" "${dialog_width}"
}

um_whiptail_msg() {
  local title="$1" text="$2" _unused_h="${3:-}" _unused_w="${4:-}"
  local dialog_dims dialog_height dialog_width body line_count

  if ! um_menu_has_whiptail; then
    printf '\n== %s ==\n%b\n' "$title" "$text"
    printf 'Press Enter... '
    read -r _ || true
    return 0
  fi

  um_menu_set_newt_colors
  # Cap lines so the text region never scrolls (scrollable text steals OK focus).
  body="$(um_whiptail_fit_body "$(printf '%b\n\n(Enter = OK)' "$text")" 16)"
  line_count="$(printf '%b' "$body" | wc -l)"
  dialog_dims="$(um_calc_dialog_size "${line_count}" 72 6)"
  read -r dialog_height dialog_width <<< "${dialog_dims}"

  whiptail --title "${title}" --fb --ok-button "OK" \
    --msgbox "${body}" "${dialog_height}" "${dialog_width}" || true
}

um_whiptail_file_msg() {
  local title="$1" file="$2" height="${3:-20}" width="${4:-72}"
  local body
  body="$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$file" 2>/dev/null || cat "$file")"
  um_whiptail_msg "$title" "$body" "$height" "$width"
}

um_whiptail_input() {
  local title="$1" text="$2" default="${3:-}"
  local dialog_dims dialog_height dialog_width body line_count result rc

  if ! um_menu_has_whiptail; then
    printf '%s\n%b\n> ' "$title" "$text"
    local val
    read -r val || true
    printf '%s\n' "${val:-$default}"
    return 0
  fi

  um_menu_set_newt_colors
  body="$(um_whiptail_fit_body "$(printf '%b\n\n%s' "$text" "$(um_menu_keys_hint)")" 12)"
  line_count="$(printf '%b' "$body" | wc -l)"
  dialog_dims="$(um_calc_dialog_size "${line_count}" 70 8)"
  read -r dialog_height dialog_width <<< "${dialog_dims}"

  # Tab: entry ↔ OK ↔ Cancel
  result="$(whiptail --title "${title}" --fb \
    --ok-button "OK" --cancel-button "Cancel" \
    --inputbox "${body}" \
    "${dialog_height}" "${dialog_width}" "${default}" \
    3>&1 1>&2 2>&3)"
  rc=$?
  if [[ ${rc} -ne 0 ]]; then
    echo ""
    return 1
  fi
  echo "${result}"
  return 0
}

um_menu_pause() {
  um_whiptail_msg "Ubuntu Mirror" "Press Enter to return to the menu."
}

# install.sh sets INT/TERM → exit 130. For log/dashboard views, Ctrl+C must
# return to the menu instead of aborting the whole installer.
um_menu_restore_interrupt_trap() {
  trap 'um_error "Interrupted"; exit 130' INT TERM
}

um_menu_run_detachable() {
  # Run "$@" in the background so Ctrl+C is handled here (return to menu),
  # not by install.sh's fatal INT trap.
  # Keep stdin on /dev/tty — background jobs otherwise lose the terminal and
  # dashboard `read -t` fails instantly (busy-refresh loop).
  local child_pid=0
  local detached=0

  trap 'detached=1; if [[ ${child_pid:-0} -gt 0 ]]; then kill "$child_pid" 2>/dev/null || true; fi' INT TERM

  if [[ -r /dev/tty ]]; then
    "$@" </dev/tty &
  else
    "$@" &
  fi
  child_pid=$!
  wait "$child_pid" 2>/dev/null || true
  if [[ "${child_pid}" -gt 0 ]] && kill -0 "$child_pid" 2>/dev/null; then
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  child_pid=0

  um_menu_restore_interrupt_trap
  if [[ "${detached}" -eq 1 ]]; then
    printf '\nReturning to menu...\n'
    sleep 0.3
  fi
  return 0
}

um_menu_run_dashboard() {
  local dash repo
  dash=""
  if [[ -f "${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}/source-repo" ]]; then
    repo="$(tr -d '\r\n' <"${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}/source-repo" 2>/dev/null || true)"
    [[ -x "${repo}/scripts/mirror-dashboard.sh" ]] && dash="${repo}/scripts/mirror-dashboard.sh"
  fi
  [[ -n "$dash" ]] || dash="${UM_PROJECT_ROOT}/scripts/mirror-dashboard.sh"
  [[ -x "$dash" ]] || dash="${INSTALL_BIN_DIR:-/usr/local/bin}/mirror-dashboard"
  [[ -x "$dash" ]] || dash="${UM_PROJECT_ROOT}/scripts/mirror-dashboard.sh"
  if [[ ! -x "$dash" ]]; then
    um_whiptail_msg "Monitor" "Dashboard not installed yet.\n\nInstall offline-upgrade-selective first."
    return 0
  fi
  clear 2>/dev/null || true
  um_menu_run_detachable "$dash" --config "${UM_CONFIG_PATH:-${INSTALL_CONF_DIR}/mirror.conf}"
}

um_menu_show_status() {
  local bin tmp
  bin="${INSTALL_BIN_DIR:-/usr/local/bin}/mirrorctl"
  [[ -x "$bin" ]] || bin="${UM_PROJECT_ROOT}/scripts/mirrorctl"
  tmp="$(mktemp)"
  if [[ -x "$bin" ]]; then
    "$bin" --config "${UM_CONFIG_PATH}" status >"$tmp" 2>&1 || true
  else
    printf 'State: %s\nPath: %s\n' "$(um_menu_sync_label)" "$BASE_PATH" >"$tmp"
  fi
  um_whiptail_file_msg "Status" "$tmp" 22 72
  rm -f "$tmp"
}

um_menu_follow_logs() {
  clear 2>/dev/null || true
  printf 'Following %s (Ctrl+C returns to menu)\n' "${APT_MIRROR_LOG}"
  if [[ -f "${APT_MIRROR_LOG}" ]]; then
    um_menu_run_detachable tail -n 50 -f "${APT_MIRROR_LOG}"
    printf '\n'
  else
    um_whiptail_msg "Logs" "Log not found yet:\n${APT_MIRROR_LOG}"
  fi
}

um_menu_stop_sync() {
  um_require_root
  if ! um_is_sync_running \
    && ! pgrep -f 'ubuntu-offline-mirror\.sh[[:space:]]+(materialize-selective|verify-selective|publish-selective)' >/dev/null 2>&1 \
    && ! pgrep -f '/usr/bin/perl /usr/bin/apt-mirror' >/dev/null 2>&1; then
    um_whiptail_msg "Stop operation" "No selective materialize process is running."
    return 0
  fi
  if ! um_whiptail_yesno "Stop operation" "Stop selective materialize now?\n\nOperation will halt until started again." 1; then
    return 0
  fi
  systemctl kill -s SIGCONT apt-mirror.service 2>/dev/null || true
  systemctl stop apt-mirror.service 2>/dev/null || true
  pkill -f 'ubuntu-offline-mirror\.sh[[:space:]]+(materialize-selective|verify-selective|publish-selective)' 2>/dev/null || true
  pkill -f 'selective_mirror\.py[[:space:]]+materialize' 2>/dev/null || true
  pkill -f '/usr/bin/perl /usr/bin/apt-mirror' 2>/dev/null || true
  um_whiptail_msg "Stop operation" "Stop requested."
}

um_menu_delete_data() {
  um_require_root
  local data_gib confirm
  data_gib="$(um_menu_existing_data_gib)"

  if um_is_sync_running; then
    um_whiptail_msg "Delete data" \
      "A sync is currently RUNNING.\n\nStop it first (menu: Stop running sync),\nthen delete data."
    return 0
  fi

  if ! um_whiptail_yesno "Delete data" \
    "DANGER: Delete existing mirror data?\n\nPath: ${BASE_PATH}\nSize: ~${data_gib} GiB\n\nRemoves selective/, dp-phase2/, client/, .install-cache/, offline/, and legacy mirror/skel/var.\nConfig and nginx are kept." 1; then
    return 0
  fi

  confirm="$(um_whiptail_input "Confirm delete" \
    "Type DELETE to permanently remove product-owned data under:\n${BASE_PATH}" "")" || return 0
  if [[ "$confirm" != "DELETE" ]]; then
    um_whiptail_msg "Delete data" "Cancelled — data not deleted."
    return 0
  fi

  mkdir -p "$BASE_PATH"
  local -a del_targets=(
    "${BASE_PATH}/selective"
    "${BASE_PATH}/dp-phase2"
    "${BASE_PATH}/client"
    "${BASE_PATH}/.install-cache"
    "${BASE_PATH}/offline"
    "${MIRROR_PATH}"
    "${SKEL_PATH}"
    "${VAR_PATH}"
  )
  local t
  for t in "${del_targets[@]}"; do
    [[ -n "$t" ]] || continue
    case "$t" in
      /|"") continue ;;
    esac
    rm -rf "$t"
  done
  um_clear_marker "sync-started" 2>/dev/null || true
  um_clear_marker "sync-failed" 2>/dev/null || true
  um_clear_marker "initial-sync-complete" 2>/dev/null || true
  um_clear_marker "ready" 2>/dev/null || true
  um_clear_marker "finalizing" 2>/dev/null || true
  : >"${APT_MIRROR_LOG}" 2>/dev/null || true
  if declare -F um_progress_jsonl_path >/dev/null 2>&1; then
    : >"$(um_progress_jsonl_path)" 2>/dev/null || true
  fi
  um_whiptail_msg "Delete data" "Mirror data deleted under:\n${BASE_PATH}"
}

um_menu_prepare_install_minimal() {
  # Minimal is blocked for offline 16.04→24.04 upgrades (P0-5).
  if [[ -f "${UM_PROJECT_ROOT}/lib/upgrade-profile.sh" ]]; then
    # shellcheck source=lib/upgrade-profile.sh
    source "${UM_PROJECT_ROOT}/lib/upgrade-profile.sh"
    um_load_upgrade_profile 2>/dev/null || true
  fi
  um_whiptail_msg "UNSUPPORTED_MINIMAL_PROFILE" \
    "Minimal mirrors are not supported for the Ubuntu 16.04 → 24.04 offline upgrade chain.

Required profile: offline-upgrade-selective
Required components: main restricted universe multiverse
Required pockets: base updates security backports

No sync was started. Choose Full / offline-upgrade install instead.

Migration (existing minimal hosts):
  ubuntu-offline-mirror.sh migrate-profile --dry-run
  ubuntu-offline-mirror.sh migrate-profile --confirm"
  return 1
}

um_menu_prepare_install_full() {
  UM_FULL=1
  UM_MINIMAL=0
  UM_FORCE=1
  UM_NO_SYNC=0
  UM_SYNC_MODE="foreground"
  um_resolve_mirror_mode 1 0

  local cap_out
  cap_out="$(mktemp)"
  if ! um_check_sync_capacity "$BASE_PATH" "full" >"$cap_out" 2>&1; then
    um_whiptail_file_msg "Full mode blocked" "$cap_out" 18 72
    rm -f "$cap_out"
    return 1
  fi
  rm -f "$cap_out"

  if ! um_whiptail_yesno "Selective offline upgrade install" \
    "Install / Build Selective Offline Upgrade Mirror?\n\nProfile: offline-upgrade-selective\nSelection: discovery-exact DP upgrade payloads (~3.39 GiB)\nLayout: hop-separated selective snapshots\nReleases: xenial→noble\n\nRuns plan-selective (no full apt-mirror).\nThen start materialize-selective via systemd.\nExisting full mirror seed is preserved." 0; then
    return 1
  fi
  return 0
}

um_menu_resume_materialize() {
  um_require_root
  if um_is_sync_running; then
    um_whiptail_msg "Resume" "Selective materialize already running."
    return 0
  fi
  systemctl start --no-block apt-mirror.service 2>/dev/null || true
  um_whiptail_msg "Resume" "Started selective materialize\n(apt-mirror.service → materialize-selective)."
}

um_menu_fallback_draw() {
  cat <<EOF
┌──────────────── Ubuntu Mirror Server ─────────────────┐
│ $(um_menu_status_blurb)
├───────────────────────────────────────────────────────┤
│  1) Install / Build Selective Offline Upgrade Mirror  │
│  2) Resume Selective Mirror Materialization           │
│  3) Watch Live Progress                               │
│  4) Check Status                                      │
│  5) Follow Logs                                       │
│  6) Stop Current Operation                            │
│  7) Delete Selective Mirror Data                      │
│  8) Quit                                              │
└───────────────────────────────────────────────────────┘
EOF
}

um_install_menu_fallback() {
  local choice
  while true; do
    clear 2>/dev/null || true
    um_menu_fallback_draw
    printf 'Select [1-8]: '
    read -r choice || choice="8"
    case "$choice" in
      1)
        if um_menu_prepare_install_full; then
          UM_MENU_ACTION="install"
          return 0
        fi
        ;;
      2) um_menu_resume_materialize ;;
      3) um_menu_run_dashboard ;;
      4) um_menu_show_status ;;
      5) um_menu_follow_logs ;;
      6) um_menu_stop_sync ;;
      7) um_menu_delete_data ;;
      8|q|Q)
        UM_MENU_ACTION="quit"
        return 0
        ;;
    esac
  done
}

um_install_menu() {
  UM_MENU_ACTION=""

  if [[ -f "${UM_PROJECT_ROOT}/lib/progress.sh" ]]; then
    # shellcheck source=lib/progress.sh
    source "${UM_PROJECT_ROOT}/lib/progress.sh" 2>/dev/null || true
  elif [[ -f /usr/local/lib/ubuntu-mirror/progress.sh ]]; then
    # shellcheck source=/dev/null
    source /usr/local/lib/ubuntu-mirror/progress.sh 2>/dev/null || true
  fi

  if ! um_menu_has_whiptail; then
    um_warn "whiptail not found — using plain text menu"
    um_warn "Install with: apt-get install -y whiptail"
    um_install_menu_fallback
    return $?
  fi

  local choice blurb
  while true; do
    blurb="$(um_menu_status_blurb)"
    # Esc/Cancel: stay on menu (same as XDR installer). Use item 8 to quit.
    choice="$(um_whiptail_menu "Ubuntu Mirror Menu" \
      "Ubuntu Mirror Server

${blurb}" \
      "1" "Install / Build Selective Offline Upgrade Mirror" \
      "2" "Resume Selective Mirror Materialization" \
      "3" "Watch Live Progress" \
      "4" "Check Status" \
      "5" "Follow Logs" \
      "6" "Stop Current Operation" \
      "7" "Delete Selective Mirror Data" \
      "8" "Quit" \
    )" || continue

    [[ -z "${choice}" ]] && continue

    case "$choice" in
      1)
        if um_menu_prepare_install_full; then
          UM_MENU_ACTION="install"
          return 0
        fi
        ;;
      2) um_menu_resume_materialize ;;
      3) um_menu_run_dashboard ;;
      4) um_menu_show_status ;;
      5) um_menu_follow_logs ;;
      6) um_menu_stop_sync ;;
      7) um_menu_delete_data ;;
      8)
        UM_MENU_ACTION="quit"
        return 0
        ;;
    esac
  done
}
