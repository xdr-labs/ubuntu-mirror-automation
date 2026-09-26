#!/usr/bin/env bash
# scripts/install-dp-upgrade-mirror.sh — DP Ubuntu Upgrade Mirror Manager (whiptail TUI)
# Single workflow: R2 OS Core + immutable R2 Phase 2 → one HTTP artifact set.
# Sensor-Installer style: dynamic sizing, --fb, inputbox/passwordbox/msgbox/textbox.
set -euo pipefail
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MM_PROJECT_ROOT="${MM_PROJECT_ROOT:-$PROJECT_ROOT}"
PROJECT_ROOT="$MM_PROJECT_ROOT"

# shellcheck source=lib/mirror_manager_common.sh
source "${SCRIPT_DIR}/lib/mirror_manager_common.sh"
# shellcheck source=lib/dp-phase2-common.sh
source "${SCRIPT_DIR}/lib/dp-phase2-common.sh"
# shellcheck source=lib/acps_acquire.sh
source "${SCRIPT_DIR}/lib/acps_acquire.sh"
# shellcheck source=lib/r2_acquire.sh
source "${SCRIPT_DIR}/lib/r2_acquire.sh"
# shellcheck source=lib/mirror_install_engine.sh
source "${SCRIPT_DIR}/lib/mirror_install_engine.sh"

cleanup() {
  local rc=$?
  mm_release_install_lock
  if [[ "$rc" -ne 0 && -n "${MM_STATE_DIR:-}" ]]; then
    mm_state_set INSTALL_RESULT FAIL 2>/dev/null || true
  fi
}
trap cleanup EXIT

load_mirror_defaults() {
  if [[ -f "${PROJECT_ROOT}/mirror.conf" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${PROJECT_ROOT}/mirror.conf"
    set +a
  fi
  if [[ -f /etc/ubuntu-mirror/mirror.conf ]]; then
    set -a
    # shellcheck source=/dev/null
    source /etc/ubuntu-mirror/mirror.conf
    set +a
  fi
  MM_MIRROR_ROOT="${MM_MIRROR_ROOT:-${BASE_PATH:-/var/spool/apt-mirror}}"
  MM_SELECTIVE_ROOT="${MM_SELECTIVE_ROOT:-${SELECTIVE_MIRROR_ROOT:-${MM_MIRROR_ROOT}/selective}}"
  MM_DP_PHASE2_ROOT="${MM_DP_PHASE2_ROOT:-${DP_PHASE2_ROOT:-${MM_MIRROR_ROOT}/dp-phase2}}"
  MM_CLIENT_ROOT="${MM_CLIENT_ROOT:-${MM_MIRROR_ROOT}/client}"
  # Client signing keys are NOT an R2 publisher trust root. Production R2
  # trust is HTTPS + mandatory SHA256 until R2_OS_CORE_PUBLISHER_PUBLIC_KEY
  # is explicitly configured. Do not copy CLIENT_SIGNING_PUBLIC_KEY here.
  R2_OS_CORE_PUBLISHER_PUBLIC_KEY="${R2_OS_CORE_PUBLISHER_PUBLIC_KEY:-}"
}

# ---------------------------------------------------------------------------
# Whiptail helpers (Sensor Installer style)
# ---------------------------------------------------------------------------
mm_term_size() {
  if command -v tput >/dev/null 2>&1; then
    HEIGHT="$(tput lines 2>/dev/null || true)"
    WIDTH="$(tput cols 2>/dev/null || true)"
  fi
  if [[ -z "${HEIGHT:-}" ]]; then HEIGHT=25; fi
  if [[ -z "${WIDTH:-}" ]]; then WIDTH=100; fi
  return 0
}

mm_calc_menu_size() {
  # Args: item_count [min_width] [min_list] [text_lines]
  # text_lines sizes the instruction/footer block so Configuration's exact
  # footer is not clipped by a fixed +12 chrome allowance.
  local item_count="$1"
  local min_width="${2:-74}"
  local min_list="${3:-8}"
  local text_lines="${4:-4}"
  mm_term_size
  [[ "${text_lines}" =~ ^[0-9]+$ ]] || text_lines=4
  [[ "${text_lines}" -lt 1 ]] && text_lines=1
  local menu_list_height=$((item_count + 1))
  [[ "${menu_list_height}" -lt "${min_list}" ]] && menu_list_height="${min_list}"
  # chrome ≈ title/borders/button row; text_lines is the --menu instruction block.
  # Whiptail often hides the final instruction line unless one spare row remains.
  local chrome=10
  local dialog_height=$((menu_list_height + text_lines + chrome))
  local max_height=$((HEIGHT - 2))
  [[ "${max_height}" -lt 16 ]] && max_height=16
  # Prefer keeping instruction/footer text visible: shrink list before clipping text.
  if [[ "${dialog_height}" -gt "${max_height}" ]]; then
    local overflow=$((dialog_height - max_height))
    local min_visible=2
    [[ "${item_count}" -gt 0 && "${item_count}" -lt "${min_visible}" ]] && min_visible="${item_count}"
    if [[ "${menu_list_height}" -gt "${min_visible}" ]]; then
      local can=$((menu_list_height - min_visible))
      [[ "${can}" -gt "${overflow}" ]] && can="${overflow}"
      menu_list_height=$((menu_list_height - can))
      dialog_height=$((menu_list_height + text_lines + chrome))
    fi
    [[ "${dialog_height}" -gt "${max_height}" ]] && dialog_height="${max_height}"
  fi
  [[ "${dialog_height}" -lt 16 ]] && dialog_height=16
  [[ "${dialog_height}" -gt "${max_height}" ]] && dialog_height="${max_height}"
  local dialog_width=$((WIDTH - 6))
  [[ "${dialog_width}" -lt "${min_width}" ]] && dialog_width="${min_width}"
  [[ "${dialog_width}" -gt 100 ]] && dialog_width=100
  [[ "${dialog_width}" -gt $((WIDTH - 2)) ]] && dialog_width=$((WIDTH - 2))
  echo "${dialog_height} ${dialog_width} ${menu_list_height}"
}

mm_calc_dialog_size() {
  local line_count="${1:-4}"
  local min_width="${2:-70}"
  local extra="${3:-6}"
  mm_term_size
  [[ "${line_count}" -lt 1 ]] && line_count=1
  local dialog_height=$((line_count + extra))
  [[ "${dialog_height}" -lt 10 ]] && dialog_height=10
  [[ "${dialog_height}" -gt $((HEIGHT - 2)) ]] && dialog_height=$((HEIGHT - 2))
  [[ "${dialog_height}" -gt 28 ]] && dialog_height=28
  local dialog_width=$((WIDTH - 6))
  [[ "${dialog_width}" -lt "${min_width}" ]] && dialog_width="${min_width}"
  [[ "${dialog_width}" -gt 96 ]] && dialog_width=96
  [[ "${dialog_width}" -gt $((WIDTH - 2)) ]] && dialog_width=$((WIDTH - 2))
  echo "${dialog_height} ${dialog_width}"
}

mm_has_whiptail() { command -v whiptail >/dev/null 2>&1; }

mm_whiptail_menu() {
  local title="$1" text="$2"
  shift 2
  local item_count=$(( $# / 2 ))
  local text_lines menu_dims menu_height menu_width menu_list_height
  text_lines="$(printf '%b' "$text" | wc -l)"
  text_lines="${text_lines#"${text_lines%%[![:space:]]*}"}"
  text_lines="${text_lines%"${text_lines##*[![:space:]]}"}"
  menu_dims="$(mm_calc_menu_size "${item_count}" 74 8 "${text_lines}")"
  read -r menu_height menu_width menu_list_height <<< "${menu_dims}"
  if ! mm_has_whiptail; then
    printf '%s\n%s\n' "$title" "$text"
    local i=1 tag
    while [[ $# -gt 0 ]]; do
      printf '  %s) %s\n' "$1" "$2"
      shift 2
    done
    read -r -p "Select: " tag || true
    printf '%s\n' "$tag"
    return 0
  fi
  whiptail --title "${title}" --fb \
    --ok-button "OK" --cancel-button "Cancel" \
    --menu "${text}" \
    "${menu_height}" "${menu_width}" "${menu_list_height}" \
    "$@" \
    3>&1 1>&2 2>&3
}

mm_whiptail_msg() {
  local title="$1" text="$2"
  if ! mm_has_whiptail; then
    printf '\n== %s ==\n%b\n' "$title" "$text"
    printf 'Press Enter... '; read -r _ || true
    return 0
  fi
  local body line_count dims h w
  body="$(printf '%b\n\n(Enter = OK)' "$text")"
  line_count="$(printf '%b' "$body" | wc -l)"
  dims="$(mm_calc_dialog_size "${line_count}" 72 6)"
  read -r h w <<< "$dims"
  whiptail --title "${title}" --fb --ok-button "OK" \
    --msgbox "${body}" "${h}" "${w}" || true
}

mm_whiptail_input() {
  local title="$1" text="$2" default="${3:-}"
  if ! mm_has_whiptail; then
    printf '%s\n%b\n[%s]> ' "$title" "$text" "$default"
    local val; read -r val || true
    printf '%s\n' "${val:-$default}"
    return 0
  fi
  local body line_count dims h w result rc
  body="$(printf '%b' "$text")"
  line_count="$(printf '%b' "$body" | wc -l)"
  dims="$(mm_calc_dialog_size "${line_count}" 70 8)"
  read -r h w <<< "$dims"
  result="$(whiptail --title "${title}" --fb \
    --ok-button "OK" --cancel-button "Cancel" \
    --inputbox "${body}" "${h}" "${w}" "${default}" \
    3>&1 1>&2 2>&3)" || rc=$?
  rc="${rc:-0}"
  if [[ "$rc" -ne 0 ]]; then
    echo ""
    return 1
  fi
  echo "${result}"
  return 0
}

mm_whiptail_password() {
  local title="$1" text="$2"
  if ! mm_has_whiptail; then
    printf '%s\n%b\n> ' "$title" "$text"
    local val; read -r -s val || true
    printf '\n'
    printf '%s\n' "$val"
    return 0
  fi
  local body line_count dims h w result rc
  body="$(printf '%b' "$text")"
  line_count="$(printf '%b' "$body" | wc -l)"
  dims="$(mm_calc_dialog_size "${line_count}" 70 8)"
  read -r h w <<< "$dims"
  result="$(whiptail --title "${title}" --fb \
    --ok-button "OK" --cancel-button "Cancel" \
    --passwordbox "${body}" "${h}" "${w}" \
    3>&1 1>&2 2>&3)" || rc=$?
  rc="${rc:-0}"
  if [[ "$rc" -ne 0 ]]; then
    echo ""
    return 1
  fi
  echo "${result}"
  return 0
}

mm_whiptail_textbox() {
  local title="$1" file="$2"
  mm_term_size
  local h=$((HEIGHT - 4)) w=$((WIDTH - 6))
  [[ "$h" -lt 12 ]] && h=12
  [[ "$w" -lt 60 ]] && w=60
  if ! mm_has_whiptail; then
    printf '\n== %s ==\n' "$title"
    cat "$file"
    printf 'Press Enter... '; read -r _ || true
    return 0
  fi
  whiptail --title "${title}" --fb --textbox "$file" "$h" "$w" || true
  return 0
}

# Disable common xterm mouse-tracking modes so SSH clients keep native
# click/drag text selection while Menu 7 is open (and after it closes).
mm_menu7_disable_mouse_tracking() {
  local seq=$'\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1015l'
  local ttydev=""
  # Only write when `tty` resolves a real device; avoids bash redirect noise
  # in non-TTY harnesses where /dev/tty exists but cannot be opened.
  ttydev="$(tty 2>/dev/null || true)"
  if [[ -n "$ttydev" && -c "$ttydev" ]]; then
    { printf '%s' "$seq" >"$ttydev"; } 2>/dev/null || true
  fi
  return 0
}

# Restore terminal attributes for the next whiptail main-menu paint.
# Deliberately does NOT call `clear` or `reset`: clear after dialog left a
# blank SSH frame until Ctrl-C (original Menu 7 hang). Prefer the smallest
# restore that lets whiptail repaint immediately.
mm_menu7_tty_restore() {
  local ttydev=""
  mm_menu7_disable_mouse_tracking
  ttydev="$(tty 2>/dev/null || true)"
  if [[ -n "$ttydev" && -c "$ttydev" ]]; then
    { tput sgr0 || true
      tput cnorm || true
      stty sane || true
    } </dev/null >"$ttydev" 2>/dev/null || true
  fi
  return 0
}

# Menu 7 only: framed dialog --textbox (same GUI family as Mirror Manager).
# --no-mouse keeps SSH click/drag selection. Exit label is "Return".
# NEVER call clear after dialog — that blanked the next whiptail main menu.
# Scroll: Up/Down/PgUp/PgDn/Home/End (dialog textbox). Enter/ESC return.
mm_menu7_textbox() {
  local title="$1" file="$2"
  local h w dialog_bin=""
  mm_term_size
  h=$((HEIGHT - 4))
  w=$((WIDTH - 6))
  if [[ "$h" -lt 12 ]]; then h=12; fi
  if [[ "$w" -lt 60 ]]; then w=60; fi
  dialog_bin="$(command -v dialog 2>/dev/null || true)"
  if [[ -z "$dialog_bin" || ! -x "$dialog_bin" ]]; then
    mm_whiptail_msg "${title}" \
      "MENU7_VIEWER=FAIL
MENU7_VIEWER_REASON=dialog_missing

dialog is required to view DP client upgrade commands.
Install dialog and reopen Menu 7 from the main menu."
    return 1
  fi
  if [[ ! -f "$file" ]]; then
    mm_whiptail_msg "${title}" \
      "MENU7_VIEWER=FAIL
MENU7_VIEWER_REASON=command_file_missing"
    return 1
  fi
  mm_menu7_disable_mouse_tracking
  # --no-mouse must be on argv (do not rely only on DIALOGOPTS).
  "$dialog_bin" --no-mouse --title "${title}" --exit-label "Return" \
    --textbox "$file" "$h" "$w" || true
  mm_menu7_tty_restore
  return 0
}

mm_has_dialog() {
  command -v dialog >/dev/null 2>&1
}

mm_whiptail_infobox() {
  # Non-blocking notice that remains visible until the next whiptail dialog.
  # Always returns 0 so callers never inherit dialog exit status.
  local title="$1" text="$2"
  if ! mm_has_whiptail; then
    if [[ -w /dev/tty ]]; then
      {
        printf '\n== %s ==\n' "$title"
        printf '%b\n\n' "$text"
      } >/dev/tty 2>/dev/null || true
    else
      printf '\n== %s ==\n' "$title"
      printf '%b\n\n' "$text"
    fi
    return 0
  fi
  local body line_count dims h w
  body="$(printf '%b' "$text")"
  line_count="$(printf '%b' "$body" | wc -l)"
  dims="$(mm_calc_dialog_size "${line_count}" 72 6)"
  read -r h w <<< "$dims"
  whiptail --title "${title}" --fb --infobox "${body}" "${h}" "${w}" || true
  return 0
}

# Operator notice before long Phase 2 bundle SHA256 (legacy helper; prefer live progress).
gui_show_sha256_wait_notice() {
  local operation="$1"
  local file="$2"
  local lead="${3:-Verifying the SHA256 checksum of the Phase 2 bundle.}"
  local body
  body="${lead}

The bundle is large, so this step may take several minutes depending on disk performance.

The program is still running normally.
Please wait and do not interrupt the process or close this terminal.

HTTP configuration will continue automatically after verification completes."
  mm_info "SHA256_VERIFICATION_START operation=${operation} file=${file} message=\"large file; this may take several minutes\""
  mm_whiptail_infobox "SHA256 Verification in Progress" "$body"
  return 0
}

# Emit GUI_TRANSITION timing when debug/instrumentation is enabled.
# Normal production UI stays quiet (no per-transition noise).
mm_gui_transition_log() {
  local action="$1" elapsed_ms="$2"
  if [[ "${MM_DEBUG_GUI:-0}" == "1" || "${MM_GUI_TRANSITION_LOG:-0}" == "1" ]]; then
    printf 'GUI_TRANSITION action=%s elapsed_ms=%s\n' "$action" "$elapsed_ms" >&2
  fi
  return 0
}

mm_gui_now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s000
}

# Isolate GUI actions from set -e: backend FAIL must show a dialog, not exit the menu.
gui_run_action() {
  local action_name="$1"
  shift
  local action_rc=0 start_ms end_ms elapsed_ms=0
  start_ms="$(mm_gui_now_ms)"
  if [[ "${MM_DEBUG_GUI:-0}" == "1" ]]; then
    mm_info "GUI_ACTION_START action=${action_name}"
  fi
  "$@" || action_rc=$?
  end_ms="$(mm_gui_now_ms)"
  elapsed_ms=$((end_ms - start_ms))
  [[ "$elapsed_ms" -lt 0 ]] && elapsed_ms=0
  mm_gui_transition_log "$action_name" "$elapsed_ms"
  if [[ "${MM_DEBUG_GUI:-0}" == "1" ]]; then
    mm_info "GUI_ACTION_END action=${action_name} rc=${action_rc}"
  fi
  if [[ "$action_rc" -ne 0 ]]; then
    mm_whiptail_msg \
      "${action_name} — Error" \
      "The operation failed with exit code ${action_rc}.

See View Logs for details.

Press OK, Cancel, or ESC to return to the main menu." || true
  fi
  if [[ "${MM_DEBUG_GUI:-0}" == "1" ]]; then
    mm_info "GUI_MENU_RETURN action=${action_name}"
  fi
  return 0
}

mm_whiptail_yesno() {
  # OK/Yes → 0; Cancel/No → 1
  local title="$1" text="$2"
  if ! mm_has_whiptail; then
    printf '%s\n%b\n[Y/n]> ' "$title" "$text"
    local ans; read -r ans || true
    case "${ans:-Y}" in
      Y|y|yes|YES|"") return 0 ;;
      *) return 1 ;;
    esac
  fi
  local body line_count dims h w
  body="$(printf '%b' "$text")"
  line_count="$(printf '%b' "$body" | wc -l)"
  dims="$(mm_calc_dialog_size "${line_count}" 70 6)"
  read -r h w <<< "$dims"
  whiptail --title "${title}" --fb \
    --yes-button "OK" --no-button "Cancel" \
    --yesno "${body}" "${h}" "${w}"
}

# ---------------------------------------------------------------------------
# GUI screens
# ---------------------------------------------------------------------------
gui_configuration() {
  mm_load_gui_config
  while true; do
    local choice mode_label footer detected_ip ip_label
    mm_normalize_preparation_mode
    mm_force_phase2_target
    mode_label="$(mm_preparation_mode_label)"
    footer="$(mm_config_footer_text)"
    detected_ip="$(mirror_host_suggest_primary_ipv4 2>/dev/null || true)"
    if [[ -n "${MIRROR_SERVER_IP:-}" ]]; then
      ip_label="${MIRROR_SERVER_IP}"
    elif [[ -n "$detected_ip" ]]; then
      ip_label="(suggested ${detected_ip})"
    else
      ip_label="(not set)"
    fi
    # Trailing blank line: newt/whiptail can clip the final instruction line otherwise.
    choice="$(mm_whiptail_menu "Configuration" \
      "Preparation Mode: ${mode_label}
Mirror Server IP: ${ip_label}
DL Worker IPs: ${DL_WORKER_IPS:-(not set)}
DA Worker IPs: ${DA_WORKER_IPS:-(not set)}
Worker SSH Password (aella): $(mm_configured_label "$WORKER_SSH_PASSWORD")
OS Core Source: Cloudflare R2
Phase 2 Source: Cloudflare R2

${footer}
" \
      "1" "Preparation Mode" \
      "2" "Mirror Server IP" \
      "3" "DL Worker IP addresses" \
      "4" "DA Worker IP addresses" \
      "5" "Worker SSH Password (aella)" \
      "6" "Test R2 Connection" \
      "7" "Save Configuration" \
      "0" "Back")" || return 0
    case "$choice" in
      1)
        local mode_choice
        mode_choice="$(mm_whiptail_menu "Preparation Mode" \
          "Select how this Mirror Server prepares artifacts.

Full OS Upgrade + Phase 2:
  DP starts on Ubuntu 16.04 and upgrades to Ubuntu 24.04, then Phase 2.

Phase 2 Only:
  DP is already running Ubuntu 24.04. Skip OS Core / OS hops." \
          "1" "Full OS Upgrade + Phase 2" \
          "2" "Phase 2 Only — DP is already running Ubuntu 24.04")" || continue
        case "$mode_choice" in
          1) PREPARATION_MODE=FULL ;;
          2) PREPARATION_MODE=PHASE2_ONLY ;;
          *) continue ;;
        esac
        ;;
      2)
        local ip_in suggest_msg default_ip
        suggest_msg=""
        default_ip="${MIRROR_SERVER_IP:-}"
        detected_ip="$(mirror_host_suggest_primary_ipv4 2>/dev/null || true)"
        if [[ -n "$detected_ip" ]]; then
          suggest_msg="Detected Mirror Server IP: ${detected_ip}

Auto-detection is a suggestion only. Confirm or edit the value to save."
          [[ -z "$default_ip" ]] && default_ip="$detected_ip"
        else
          suggest_msg="No single primary-interface IPv4 was detected.
Enter the IPv4 address clients should use to reach this Mirror Server."
        fi
        ip_in="$(mm_whiptail_input "Mirror Server IP" \
          "${suggest_msg}" \
          "${default_ip}")" || continue
        ip_in="$(printf '%s' "$ip_in" | tr -d '[:space:]')"
        if ! mirror_host_is_usable_ipv4 "$ip_in"; then
          mm_whiptail_msg "Mirror Server IP" \
            "Invalid IPv4 address: ${ip_in}

Loopback, link-local, and 0.0.0.0 are not allowed."
          continue
        fi
        if ! mirror_host_validate_ipv4_on_host "$ip_in"; then
          mm_whiptail_msg "Mirror Server IP" \
            "${ip_in} is not configured on any active non-excluded interface.

Choose an address that exists on this host."
          continue
        fi
        MIRROR_SERVER_IP="$ip_in"
        MIRROR_HTTP_URL="$(mirror_base_url_from_ipv4 "$ip_in")"
        ;;
      3)
        local dl_in dl_clean
        dl_in="$(mm_whiptail_input "DL Worker IP addresses" \
          "Enter worker IP addresses belonging to the DL cluster.
Do not include the DL master IP.

Management IP addresses or cluster IP addresses can be used.
Cluster IP addresses are recommended when reachable from the DL master.

Separate multiple IP addresses with commas.
Leave empty if there are no DL workers.

Example:
192.0.2.23,192.0.2.24" \
          "${DL_WORKER_IPS:-}")" || continue
        dl_clean="$(printf '%s' "$dl_in" | tr -d '[:space:]')"
        if [[ -n "$dl_clean" ]]; then
          dl_clean="$(mm_validate_worker_ips "$dl_clean")" || {
            mm_whiptail_msg "Invalid DL Worker IPs" \
              "Provide a comma-separated list of valid IPv4 addresses.
Do not include the DL master IP, trailing commas, duplicates, or shell metacharacters."
            continue
          }
        fi
        DL_WORKER_IPS="$dl_clean"
        ;;
      4)
        local da_in da_clean
        da_in="$(mm_whiptail_input "DA Worker IP addresses" \
          "Enter worker IP addresses belonging to the DA cluster.
Do not include the DA master IP.

Management IP addresses or cluster IP addresses can be used.
Cluster IP addresses are recommended when reachable from the DA master.

Separate multiple IP addresses with commas.
Leave empty if there are no DA workers.

Example:
192.0.2.25,192.0.2.26" \
          "${DA_WORKER_IPS:-}")" || continue
        da_clean="$(printf '%s' "$da_in" | tr -d '[:space:]')"
        if [[ -n "$da_clean" ]]; then
          da_clean="$(mm_validate_worker_ips "$da_clean")" || {
            mm_whiptail_msg "Invalid DA Worker IPs" \
              "Provide a comma-separated list of valid IPv4 addresses.
Do not include the DA master IP, trailing commas, duplicates, or shell metacharacters."
            continue
          }
        fi
        DA_WORKER_IPS="$da_clean"
        ;;
      5)
        local wp
        wp="$(mm_whiptail_password "Worker SSH Password (aella)" \
          "Common aella SSH password used by each cluster master to access its workers.

Required when DL Worker IPs or DA Worker IPs are configured.
May be left empty for AIO/single-node deployments.")" || continue
        WORKER_SSH_PASSWORD="$wp"
        ;;
      6)
        load_mirror_defaults
        engine_resolve_paths
        if acps_test_connection; then
          mm_status_set PHASE2_R2_CONNECTION PASS
          mm_whiptail_msg "Cloudflare R2" "R2_CONNECTION=PASS\n\nSource: ${PHASE2_R2_BASE_URL_CONSTANT}"
        else
          mm_status_set PHASE2_R2_CONNECTION FAIL
          mm_whiptail_msg "Cloudflare R2" "R2_CONNECTION=FAIL\n\nSource: ${PHASE2_R2_BASE_URL_CONSTANT}"
        fi
        ;;
      7)
        local normalized_dl="" normalized_da=""
        if [[ -n "${DL_WORKER_IPS:-}" ]]; then
          normalized_dl="$(mm_validate_worker_ips "${DL_WORKER_IPS}")" || {
            mm_whiptail_msg "Configuration" "DL Worker IP addresses are invalid. Re-enter them with menu 3."
            continue
          }
        fi
        if [[ -n "${DA_WORKER_IPS:-}" ]]; then
          normalized_da="$(mm_validate_worker_ips "${DA_WORKER_IPS}")" || {
            mm_whiptail_msg "Configuration" "DA Worker IP addresses are invalid. Re-enter them with menu 4."
            continue
          }
        fi
        DL_WORKER_IPS="$normalized_dl"
        DA_WORKER_IPS="$normalized_da"
        if [[ -n "${DL_WORKER_IPS}${DA_WORKER_IPS}" ]] \
          && ! mm_validate_worker_ssh_password "${WORKER_SSH_PASSWORD:-}" "${DL_WORKER_IPS}${DA_WORKER_IPS}"; then
          mm_whiptail_msg "Configuration" \
            "Worker SSH Password (aella) is required when DL or DA worker IPs are configured.

Set it with menu 5 before saving."
          continue
        fi
        mm_force_phase2_target
        if [[ -z "${MIRROR_SERVER_IP:-}" ]]; then
          mm_whiptail_msg "Configuration" \
            "Mirror Server IP is required before Save.

Use 2) Mirror Server IP to confirm the advertised address."
          continue
        fi
        if ! mirror_host_is_usable_ipv4 "${MIRROR_SERVER_IP}" \
          || ! mirror_host_validate_ipv4_on_host "${MIRROR_SERVER_IP}"; then
          mm_whiptail_msg "Configuration" \
            "Mirror Server IP ${MIRROR_SERVER_IP} failed validation.

Re-enter a usable IPv4 present on this host."
          continue
        fi
        MIRROR_HTTP_URL="$(mirror_base_url_from_ipv4 "${MIRROR_SERVER_IP}")"
        mm_save_gui_config_full
        mm_record_config_validated
        mm_status_set PREPARATION_MODE "${PREPARATION_MODE}"
        mm_status_set PHASE2_TARGET_VERSION "${PHASE2_TARGET_VERSION}"
        local save_msg
        if declare -F mm_wf_operator_save_message >/dev/null 2>&1; then
          save_msg="$(mm_wf_operator_save_message)"
        else
          save_msg="Configuration saved."
        fi
        mm_whiptail_msg "Configuration" \
          "${save_msg}

Preparation Mode: $(mm_preparation_mode_label)
Mirror Server IP: ${MIRROR_SERVER_IP}
Phase 2 Target: ${PHASE2_TARGET_VERSION} (fixed)

Saving configuration does NOT start the download."
        ;;
      0|"") return 0 ;;
    esac
  done
}

gui_download_and_prepare() {
  load_mirror_defaults
  mm_load_gui_config
  mm_normalize_preparation_mode
  mm_force_phase2_target
  # Phase 2 production source is public R2. ACPS credentials are not required
  # for Download and Prepare.
  if ! mm_config_base_ready; then
    mm_whiptail_msg "Configuration required" \
      "Set Preparation Mode and Mirror Server IP first (target is fixed at ${PHASE2_TARGET_VERSION})."
    return 0
  fi
  if declare -F mm_acps_verified_cache_reuse_available >/dev/null 2>&1 \
    && mm_acps_verified_cache_reuse_available; then
    mm_info "PHASE2_CONNECTION=NOT_REQUIRED reason=verified_cache_reuse_gui"
    mm_info "ACPS_DOWNLOAD_REQUIRED=NO reason=verified_cache_reuse"
    ACPS_DOWNLOAD_REQUIRED=NO
  fi
  if ! mm_require_configured_mirror_server_ip; then
    mm_whiptail_msg "Mirror Server IP required" \
      "Confirm Mirror Server IP in Configuration before Download and Prepare.

Use menu 1 → 2) Mirror Server IP, then Save Configuration."
    return 0
  fi
  if ! mm_is_phase2_only && ! mm_r2_url_configured; then
    mm_whiptail_msg "CONFIGURATION_REQUIRED" \
      "OS Core R2 URL is not configured.

Set OS_CORE_R2_URL_CONSTANT in:
scripts/lib/mirror_manager_common.sh

Then re-run Download and Prepare."
    return 0
  fi
  local confirm_body
  if mm_is_phase2_only; then
    confirm_body="Download and prepare Phase 2 Only files for DP ${PHASE2_TARGET_VERSION}?

This mode skips R2 OS Core and OS hop repositories.
OK / Enter starts the download.
Live progress prints in the terminal (no empty waits).
Long checksum steps print bytes read, percent, throughput, and an approximate ETA every 30 seconds. ETA can vary on newly restored EBS volumes. If progress counters are unavailable, a heartbeat is printed instead."
  else
    confirm_body="Download and prepare Full OS Upgrade + Phase 2 files for DP ${PHASE2_TARGET_VERSION}?

OK / Enter starts the download.
Live progress prints in the terminal (no empty waits).
Long checksum steps print bytes read, percent, throughput, and an approximate ETA every 30 seconds. ETA can vary on newly restored EBS volumes. If progress counters are unavailable, a heartbeat is printed instead."
  fi
  if ! mm_whiptail_yesno "Confirm" "${confirm_body}"; then
    return 0
  fi

  # Leave the whiptail UI so operators can see live download/prepare progress.
  # Do not use a blocking msgbox that requires OK before work starts.
  clear 2>/dev/null || true
  cat <<EOF
============================================================
Download and Prepare — live progress
Preparation Mode: $(mm_preparation_mode_label)
Phase 2 Target: ${PHASE2_TARGET_VERSION}
EOF
  if mm_is_phase2_only; then
    cat <<EOF

Phases (names appear as each step starts):
  1. Downloading Phase 2 Artifacts
  2. Verifying Phase 2 Checksums
  3. Preparing Patched Bringup Script
  4. Creating Phase 2 Bundle
  5. Calculating Bundle SHA256
  6. Verifying Published Bundle
  7. Cleaning Temporary Files
  8. Publishing Phase 2 Artifacts
  9. Publishing Phase 2 Helper Clients

R2 OS Core download is NOT run in Phase 2 Only mode.
OS-hop client files are NOT required in Phase 2 Only mode.
EOF
  else
    cat <<EOF

Phases (names appear as each step starts):
  1. Downloading OS Core Artifacts
  2. Verifying OS Core Artifacts
  3. Downloading Phase 2 Artifacts
  4. Verifying Phase 2 Checksums
  5. Preparing Patched Bringup Script
  6. Creating Phase 2 Bundle
  7. Calculating Bundle SHA256
  8. Verifying Published Bundle
  9. Cleaning Temporary Files
 10. Publishing Phase 2 Artifacts
 11. Building Local OS Upgrade Clients
 12. Signing Local OS Upgrade Clients
 13. Publishing Local Client Set
 14. Verifying Local Client Files
EOF
  fi
  cat <<EOF

Long checksum steps print bytes read, percent, throughput, and an approximate ETA every 30 seconds.
ETA is approximate and can vary on newly restored or AMI-backed EBS volumes.
If progress counters are unavailable, a heartbeat is printed instead.
Do not interrupt or close this terminal.
============================================================

EOF
  export MM_LIVE_PROGRESS=1
  local tmp backend_rc=0
  tmp="$(mktemp)"
  set +e
  # Capture transcript for the result textbox. Live progress is mirrored to
  # /dev/tty by mm_log under MM_LIVE_PROGRESS — do not also tee to the
  # terminal (that created exact adjacent duplicate progress lines).
  engine_download_and_prepare >"$tmp" 2>&1
  backend_rc=$?
  set -e
  unset MM_LIVE_PROGRESS

  printf '\n------------------------------------------------------------\n'
  if [[ "$backend_rc" -eq 0 ]]; then
    printf 'Download and Prepare finished: PASS\n'
  else
    printf 'Download and Prepare finished: FAIL (see log above)\n'
    # Persist evidence path into the result transcript (GUI tmp is deleted after).
    {
      echo
      echo "---- client finalization evidence (persistent) ----"
      grep -E 'CLIENT_FINALIZER_EVIDENCE_PATH=|CLIENT_FINALIZER_ERROR_SUMMARY=|CLIENT_BUILD_FAILED_|CLIENT_FINALIZER_FAILED_' "$tmp" 2>/dev/null || true
      evid="$(grep -E 'CLIENT_FINALIZER_EVIDENCE_PATH=' "$tmp" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
      if [[ -n "$evid" && -f "$evid" ]]; then
        echo "EVIDENCE_TAIL:"
        tail -n 40 "$evid" 2>/dev/null || true
      fi
    } >>"$tmp"
  fi
  printf 'Press Enter to return to the menu...\n'
  read -r _ || true

  if [[ "$backend_rc" -eq 0 ]]; then
    mm_whiptail_textbox "Download and Prepare — PASS" "$tmp" || true
  else
    mm_whiptail_textbox "Download and Prepare — FAIL" "$tmp" || true
  fi
  rm -f "$tmp"
  return 0
}

gui_enable_http() {
  load_mirror_defaults
  mm_load_gui_config
  engine_resolve_paths
  local gate_msg="" heavy_ready=0
  gate_msg="$(mm_enable_http_gate_status 2>/dev/null)" && heavy_ready=1 || heavy_ready=0
  if [[ "$heavy_ready" -ne 1 ]]; then
    mm_whiptail_msg "Enable HTTP Distribution" \
      "Heavy upgrade artifacts are not ready.

${gate_msg}

Run:
2 Download and Prepare Upgrade Files

before enabling HTTP distribution.
Do NOT skip Menu 2 when OS Core or Phase 2 is missing/invalid."
    return 0
  fi
  # Heavy artifacts are ready. Stale/missing clients recover via local
  # REBUILD_SIGN_PUBLISH inside engine_enable_http_distribution — never Menu 2.
  if ! mm_artifacts_ready_for_http 2>/dev/null; then
    mm_info "Heavy upgrade artifacts: READY"
    mm_info "$(printf '%s\n' "$gate_msg" | grep -E '^(Client set|Client recovery|Heavy artifact download required):' || true)"
    mm_info "CLIENT_RECOVERY=REBUILD_SIGN_PUBLISH (local-fs only; no R2 download)"
  else
    mm_info "Heavy upgrade artifacts: READY"
    mm_info "Client set: CURRENT_VERIFIED"
    mm_info "Heavy artifact download required: NO"
  fi
  dp2_set_version "${TARGET_DP_VERSION}"
  local backend_rc=0 tmp stable bytes errexit_was_on=0
  stable="$(dp2_stable_bundle_name)"
  bytes="$(stat -c%s "${MM_DP_PHASE2_ROOT}/${TARGET_DP_VERSION}/${stable}" 2>/dev/null || echo 0)"

  # Leave whiptail so SHA256 heartbeats are visible (same pattern as Download).
  clear 2>/dev/null || true
  cat <<EOF
============================================================
Enable HTTP Distribution — live progress
Preparation Mode: $(mm_preparation_mode_label)
Phase 2 Target: ${PHASE2_TARGET_VERSION}
Phase 2 bundle: ${stable}
Size: $(mm_format_bytes "$bytes")

$(printf '%s\n' "$gate_msg")

Verifying the Phase 2 bundle SHA256 before enabling HTTP distribution.
Stale client sets are rebuilt/signed locally (no heavy re-download).
Long checksum steps print bytes read, percent, throughput, and an approximate ETA every 30 seconds.
ETA is approximate and can vary on newly restored or AMI-backed EBS volumes.
Do not interrupt or close this terminal.
============================================================

EOF
  export MM_LIVE_PROGRESS=1
  export MM_SHA256_OPERATION=enable-http
  tmp="$(mktemp)"
  case $- in *e*) errexit_was_on=1 ;; esac
  set +e
  # Capture transcript for the result textbox. Live progress is mirrored to
  # /dev/tty by mm_log under MM_LIVE_PROGRESS — do not also tee.
  engine_enable_http_distribution >"$tmp" 2>&1
  backend_rc=$?
  if [[ "$errexit_was_on" -eq 1 ]]; then
    set -e
  else
    set +e
  fi
  unset MM_LIVE_PROGRESS
  unset MM_SHA256_OPERATION

  printf '\n------------------------------------------------------------\n'
  if [[ "$backend_rc" -eq 0 ]]; then
    printf 'Enable HTTP Distribution finished: PASS\n'
  else
    printf 'Enable HTTP Distribution finished: FAIL (see log above)\n'
  fi
  printf 'Press Enter to return to the menu...\n'
  read -r _ || true

  if [[ "$backend_rc" -eq 0 ]]; then
    mm_whiptail_textbox "HTTP Distribution — ENABLED" "$tmp" || true
  else
    mm_whiptail_textbox "HTTP Distribution — FAIL" "$tmp" || true
  fi
  rm -f "$tmp"
  # Backend failure is already shown; keep the main menu alive.
  return 0
}

gui_verify_readiness() {
  # Menu 4 is artifact/network readiness only (HTTP layout + published client
  # generation binding). It intentionally does NOT generate or dry-validate
  # Menu 7 operator commands — those require topology/worker credentials and
  # remain Menu 7-only. UPGRADE_READINESS=PASS can therefore coexist with a
  # later Menu 7 generation failure (invalid worker config, command grammar).
  load_mirror_defaults
  mm_load_gui_config
  engine_resolve_paths
  local tmp http_rc=0 ready_line="" backend_rc=0
  tmp="$(mktemp)"
  if ! mm_http_distribution_enabled; then
    cat >"$tmp" <<EOF
UPGRADE_READINESS=FAIL

HTTP distribution is not enabled.

Run:
3 Enable HTTP Distribution

before verifying upgrade readiness.
EOF
    mm_status_set UPGRADE_READINESS FAIL
    mm_status_set READINESS_RESULT FAIL
    mm_whiptail_textbox "Verify Upgrade Readiness" "$tmp" || true
    rm -f "$tmp"
    return 0
  fi
  dp2_set_version "${TARGET_DP_VERSION}"
  {
    printf 'Preparation Mode: %s\n' "$(mm_preparation_mode_label)"
    printf 'Phase 2 Target: %s\n' "${PHASE2_TARGET_VERSION}"
    printf 'HTTP Distribution: %s\n' "$(mm_status_get HTTP_DISTRIBUTION)"
  } >"$tmp"

  clear 2>/dev/null || true
  cat <<EOF
============================================================
Verify Upgrade Readiness — live progress
Preparation Mode: $(mm_preparation_mode_label)
Phase 2 Target: ${PHASE2_TARGET_VERSION}

HTTP URL checks and status validation run next.
If a Phase 2 SHA256 check is required, progress (bytes, percent, throughput, approximate ETA) prints every 30 seconds.
ETA is approximate and can vary on newly restored or AMI-backed EBS volumes.
Do not interrupt or close this terminal.
============================================================

EOF
  export MM_LIVE_PROGRESS=1
  export MM_SHA256_OPERATION=verify-readiness
  set +e
  # Prefer fingerprint skip when artifacts match last Download verify.
  if mm_download_completed; then
    export MM_SKIP_BUNDLE_SHA256=1
  fi
  ( engine_validate_http_layout ) >>"$tmp" 2>&1
  http_rc=$?
  unset MM_SKIP_BUNDLE_SHA256
  set -e
  if [[ "$http_rc" -eq 0 ]]; then
    printf 'HTTP URL checks: PASS\n' >>"$tmp"
  else
    printf 'HTTP URL checks: FAIL\n' >>"$tmp"
    mm_status_set UPGRADE_READINESS FAIL
    mm_status_set READINESS_RESULT FAIL
    printf 'UPGRADE_READINESS=FAIL\n' >>"$tmp"
    unset MM_LIVE_PROGRESS
    unset MM_SHA256_OPERATION
    printf '\nPress Enter to return to the menu...\n'
    read -r _ || true
    mm_whiptail_textbox "Verify Upgrade Readiness" "$tmp" || true
    rm -f "$tmp"
    return 0
  fi
  set +e
  ready_line="$(engine_compute_readiness 2>>"$tmp")"
  backend_rc=$?
  set -e
  printf '%s\n' "$ready_line" >>"$tmp"
  unset MM_LIVE_PROGRESS
  unset MM_SHA256_OPERATION
  printf '\n------------------------------------------------------------\n'
  if [[ "$backend_rc" -eq 0 ]]; then
    printf 'Verify Upgrade Readiness finished: PASS\n'
  else
    printf 'Verify Upgrade Readiness finished: FAIL\n'
  fi
  printf 'Press Enter to return to the menu...\n'
  read -r _ || true
  mm_whiptail_textbox "Verify Upgrade Readiness" "$tmp" || true
  rm -f "$tmp"
  return 0
}

gui_show_status() {
  load_mirror_defaults
  mm_load_gui_config
  mm_normalize_preparation_mode
  mm_force_phase2_target
  engine_resolve_paths
  local tmp ver config_state os_state bundle_state http_state ready_state start_os final_os
  ver="${PHASE2_TARGET_VERSION}"
  mm_collect_workflow_status
  if [[ "${MM_WF_CONFIG_COMPLETED}" == "1" ]]; then
    config_state="PASS"
  else
    config_state="FAIL"
  fi
  if mm_is_phase2_only; then
    start_os="Ubuntu 24.04"
    final_os="Ubuntu 24.04"
    os_state="NOT REQUIRED"
  else
    start_os="Ubuntu 16.04"
    final_os="Ubuntu 24.04"
    if [[ "${MM_WF_DOWNLOAD_COMPLETED}" == "1" ]]; then
      os_state="READY"
    else
      os_state="NOT READY"
    fi
  fi
  if [[ "${MM_WF_DOWNLOAD_COMPLETED}" == "1" ]]; then
    bundle_state="READY (9 files)"
  else
    bundle_state="NOT READY"
  fi
  if [[ "${MM_WF_HTTP_COMPLETED}" == "1" ]]; then
    http_state="ENABLED"
  else
    http_state="$(mm_status_get HTTP_DISTRIBUTION)"
    [[ -n "$http_state" ]] || http_state="DISABLED"
    [[ "$http_state" == "ENABLED" ]] || http_state="DISABLED"
  fi
  ready_state="$(mm_upgrade_readiness_display)"
  [[ -n "$ready_state" ]] || ready_state="NOT VERIFIED"
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
DP Upgrade Mirror Status
========================

Supported Starting DP Versions: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0
Phase 2 Target: ${ver}
Preparation Mode: $(mm_preparation_mode_label)
Starting OS: ${start_os}
Final OS: ${final_os}
Configuration: ${config_state}
OS Upgrade Files: ${os_state}
DP ${ver} Bundle: ${bundle_state}
HTTP Distribution: ${http_state}
Upgrade Readiness: ${ready_state}
Last Operation: $(mm_status_get LAST_EXECUTION_RESULT)
Log File: $(mm_status_get LOG_PATH)

$(mm_workflow_progress_text)
EOF
  mm_whiptail_textbox "Current Status" "$tmp" || true
  rm -f "$tmp"
  return 0
}

gui_view_logs() {
  local log
  log="$(mm_status_get LOG_PATH)"
  if [[ -z "$log" || ! -f "$log" ]]; then
    # newest log
    log="$(ls -1t "${MM_LOG_DIR}"/mirror-manager-*.log 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "$log" || ! -f "$log" ]]; then
    mm_whiptail_msg "Logs" "No mirror-manager log found yet."
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  # redact before display
  mm_redact <"$log" >"$tmp" || true
  mm_whiptail_textbox "Logs — ${log}" "$tmp" || true
  rm -f "$tmp"
  return 0
}

# Resolve local signing fingerprint for command trust pinning.
# Prefer workflow state, then on-disk fingerprint file, then public key.
gui_expected_signing_fingerprint() {
  local fpr="" confdir
  if declare -F mm_wf_get >/dev/null 2>&1; then
    fpr="$(mm_wf_get CLIENT_SIGNING_FINGERPRINT)"
  fi
  if [[ -z "$fpr" ]]; then
    confdir="${MM_CONFIG_DIR:-/etc/ubuntu-mirror}"
    if [[ -f "${confdir}/client-signing/fingerprint" ]]; then
      fpr="$(tr -d '[:space:]' <"${confdir}/client-signing/fingerprint")"
    fi
  fi
  if [[ -z "$fpr" && -f "${confdir:-/etc/ubuntu-mirror}/client-signing/public.gpg" ]]; then
    if declare -F local_signing_fingerprint_of >/dev/null 2>&1; then
      fpr="$(local_signing_fingerprint_of "${confdir}/client-signing/public.gpg" || true)"
    fi
  fi
  fpr="${fpr^^}"
  fpr="${fpr// /}"
  [[ -n "$fpr" && ${#fpr} -eq 40 ]] || return 1
  printf '%s\n' "$fpr"
}

# DP_OS_HOP_COMMAND_VERSION=WRAPPER_V1
# One physical-line OS-hop operator command:
#   cd /home/aella
#   curl upgrade-<hop>.sh into *.download
#   verify literal wrapper SHA256 embedded in the command (not an HTTP sidecar)
#   mv verified download to final wrapper name
#   bash ./upgrade-<hop>.sh
# The wrapper then verifies the existing dp-launch-<hop>.sh SHA256 and executes it.
# Phase 2 uses the same one-line wrapper bootstrap for upgrade-phase2.sh.
# Inner Phase 2 trust (generation-manifest SHA256 + helper hashes) lives inside
# upgrade-phase2.sh (DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2 semantics).
gui_client_wrapper_sha256() {
  local name="$1"
  local root="${MM_CLIENT_ROOT:-}"
  local path sha
  [[ -n "$name" ]] || return 1
  if [[ -n "$root" && -f "${root}/${name}" ]]; then
    path="${root}/${name}"
  elif [[ -n "${MM_PROJECT_ROOT:-}" && -f "${MM_PROJECT_ROOT}/client/${name}" ]]; then
    path="${MM_PROJECT_ROOT}/client/${name}"
  else
    return 1
  fi
  sha="$(sha256sum "$path" | awk '{print $1}')"
  [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s\n' "$sha"
}

gui_client_launcher_sha256() {
  local hop="$1"
  [[ -n "$hop" ]] || return 1
  gui_client_wrapper_sha256 "dp-launch-${hop}.sh"
}

gui_client_hop_command_line() {
  local mirror="$1" script="$2"
  local hop="${script#dp-offline-upgrade-}"
  hop="${hop%.sh}"
  local wrapper="upgrade-${hop}.sh"
  local sha="${3:-}"
  local url
  mirror="${mirror%/}"
  if [[ -z "$sha" ]]; then
    sha="$(gui_client_wrapper_sha256 "$wrapper" 2>/dev/null || true)"
  fi
  if [[ -z "$sha" || ! "$sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "MENU7_WRAPPER_MISSING=${wrapper}" >&2
    return 1
  fi
  url="${mirror}/client/${wrapper}"
  # Exactly one physical line. SHA is the operator trust anchor (not HTTP sidecar).
  printf '%s\n' \
    "cd /home/aella && curl -fsSLo ${wrapper}.download ${url} && printf '%s  %s\\n' '${sha}' '${wrapper}.download' | sha256sum -c - && mv -f ${wrapper}.download ${wrapper} && bash ./${wrapper}"
}

# Backward-compatible names used by older tests/callers.
gui_client_hop_command_block() {
  gui_client_hop_command_line "$@"
}

gui_client_hop_command() {
  gui_client_hop_command_line "$@"
}

# Phase 2 staging: one physical WRAPPER_V1 line. Inner SUBSHELL_V2 bootstrap
# (generation-manifest SHA256 + helper hashes + stage-dp-phase2.sh) lives in
# the published upgrade-phase2.sh wrapper.
gui_phase2_helper_generation_manifest_path() {
  if [[ -n "${MM_CLIENT_ROOT:-}" && -f "${MM_CLIENT_ROOT}/phase2-helper-generation.manifest" ]]; then
    printf '%s\n' "${MM_CLIENT_ROOT}/phase2-helper-generation.manifest"
    return 0
  fi
  if [[ -n "${MM_PROJECT_ROOT:-}" && -f "${MM_PROJECT_ROOT}/client/phase2-helper-generation.manifest" ]]; then
    printf '%s\n' "${MM_PROJECT_ROOT}/client/phase2-helper-generation.manifest"
    return 0
  fi
  return 1
}

gui_phase2_helper_generation_sha256() {
  local path sha
  path="$(gui_phase2_helper_generation_manifest_path 2>/dev/null || true)"
  [[ -n "$path" && -f "$path" ]] || return 1
  sha="$(sha256sum "$path" | awk '{print $1}')"
  [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s\n' "$sha"
}

gui_phase2_stage_command_line() {
  local mirror="$1"
  local wrapper="upgrade-phase2.sh"
  local sha="${3:-}"
  local url
  mirror="${mirror%/}"
  if [[ -z "$sha" ]]; then
    sha="$(gui_client_wrapper_sha256 "$wrapper" 2>/dev/null || true)"
  fi
  if [[ -z "$sha" || ! "$sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "MENU7_WRAPPER_MISSING=${wrapper}" >&2
    return 1
  fi
  url="${mirror}/client/${wrapper}"
  printf '%s\n' \
    "cd /home/aella && curl -fsSLo ${wrapper}.download ${url} && printf '%s  %s\\n' '${sha}' '${wrapper}.download' | sha256sum -c - && mv -f ${wrapper}.download ${wrapper} && bash ./${wrapper}"
}

gui_phase2_stage_command_block() {
  gui_phase2_stage_command_line "$@"
}

# Compact cluster execution guidance for Menu 7 (FULL and PHASE2_ONLY).
gui_cluster_execution_rule() {
  local common_label="$1"
  local bringup_label="$2"
  local a_label="$3"
  local b_label="$4"
  cat <<EOF
CLUSTER
-------
${common_label}:
Run on every DP node being upgraded
(DL master, all DL workers, DA master, and all DA workers).

${bringup_label}:
Run on masters only:
• ${a_label}: DL master only
• ${b_label}: DA master only

Do not run ${bringup_label} manually on workers.
Each master starts Phase 2 on its own workers.

EOF
}

gui_cluster_stage_guidance() {
  local step="$1"
  local next="$2"
  cat <<EOF
CLUSTER:
Run ${step} on every DP node being upgraded.
Complete ${step} on ALL nodes before ${next}.
Use the SAME staging command on every node.
EOF
}

gui_aio_stage_guidance() {
  local step="$1"
  cat <<EOF
AIO:
Run ${step} on this DP only.
EOF
}

# Cluster bringup one-liner that prompts for the worker SSH password at runtime.
# The Mirror Manager config still requires WORKER_SSH_PASSWORD to be set (proves
# credentials were configured), but the published command file must never contain
# the plaintext password. The staged lifecycle wrapper owns prompting and
# credential cleanup via --prompt-worker-password (never a Menu 7 mktemp orphan).
gui_cluster_bringup_command_line() {
  local ver="$1"
  local worker_ips="$2"
  # Single physical line for Menu 7 copy/paste. Password is read by the
  # lifecycle wrapper; it is never embedded in the saved command file.
  # worker_ips is embedded raw so the outer mm_shell_quote escapes it once.
  printf 'sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --version %s --skip-download --worker-ips %s --prompt-worker-password\n' \
    "$ver" "$worker_ips"
}

# STEP 8A/8B (FULL) and STEP 5A/5B (PHASE2_ONLY) master bringup section.
gui_emit_cluster_master_bringup() {
  local step_id="$1"
  local role="$2"
  local worker_ips="$3"
  local bringup_cmd="$4"
  cat <<EOF
${step_id} — ${role} CLUSTER MASTER
--------------------------------

EOF
  if [[ -n "$bringup_cmd" ]]; then
    cat <<EOF
Run this command on the ${role} MASTER ONLY.

Configured ${role} workers:
${worker_ips}

Do NOT run this command manually on ${role} workers.
The ${role} master starts worker bringup automatically.

The command prompts for the worker SSH password at runtime.
The password is not stored in this command file.

Copy and paste the following entire line into the ${role} master terminal:

${bringup_cmd}

EOF
  else
    cat <<EOF
${role} cluster bringup command was not generated because
${role} Worker IPs are not configured.

EOF
  fi
}

gui_build_client_commands() {
  # Writes command text to stdout.
  # Args: mirror topology dl_worker_ips da_worker_ips [worker_password]
  # Uses PREPARATION_MODE from config (FULL or PHASE2_ONLY).
  # OS-hop commands are one physical WRAPPER_V1 line each.
  # Phase 2 stage is shared by DL/DA and is one WRAPPER_V1 line; inner
  # SUBSHELL_V2 helper bootstrap lives inside upgrade-phase2.sh.
  local mirror="$1" topology="$2" dl_worker_ips="${3:-}" da_worker_ips="${4:-}"
  local worker_password="${WORKER_SSH_PASSWORD:-}"
  if [[ $# -ge 5 ]]; then
    worker_password="$5"
  fi
  mm_normalize_preparation_mode
  mm_force_phase2_target
  local ver="${PHASE2_TARGET_VERSION}"
  local snap_line stage_cmd bringup_cmd dl_bringup_cmd="" da_bringup_cmd="" prereq_cmd hop2 hop3 hop4 hop5
  local hop_copy_guide
  local cluster_rule="" step6_where step2_where
  if [[ "$topology" == "cluster" ]]; then
    snap_line="Create a full snapshot of every DP node."
  else
    snap_line="Create a full snapshot of the DP."
  fi
  stage_cmd="$(gui_phase2_stage_command_line "$mirror" "$ver")" || return 1
  hop2="$(gui_client_hop_command_line "$mirror" "dp-offline-upgrade-xenial-to-bionic.sh")" || return 1
  hop3="$(gui_client_hop_command_line "$mirror" "dp-offline-upgrade-bionic-to-focal.sh")" || return 1
  hop4="$(gui_client_hop_command_line "$mirror" "dp-offline-upgrade-focal-to-jammy.sh")" || return 1
  hop5="$(gui_client_hop_command_line "$mirror" "dp-offline-upgrade-jammy-to-noble.sh")" || return 1
  if [[ "$topology" == "cluster" ]]; then
    if [[ -z "$dl_worker_ips" && -z "$da_worker_ips" ]]; then
      echo "CLUSTER_WORKER_IPS_REQUIRED=YES" >&2
      return 1
    fi
    # Fail closed on malformed worker IP lists even when callers bypass Menu 7.
    if [[ -n "$dl_worker_ips" ]]; then
      dl_worker_ips="$(mm_validate_worker_ips "$dl_worker_ips")" || {
        echo "DL_WORKER_IPS_INVALID=YES" >&2
        return 1
      }
    fi
    if [[ -n "$da_worker_ips" ]]; then
      da_worker_ips="$(mm_validate_worker_ips "$da_worker_ips")" || {
        echo "DA_WORKER_IPS_INVALID=YES" >&2
        return 1
      }
    fi
    # Password must be configured in Mirror Manager, but is never written into
    # the published command file (runtime prompt instead).
    if ! mm_validate_worker_ssh_password "$worker_password" "${dl_worker_ips}${da_worker_ips}"; then
      echo "WORKER_SSH_PASSWORD_REQUIRED=YES" >&2
      return 1
    fi
    if [[ -n "$dl_worker_ips" ]]; then
      dl_bringup_cmd="$(gui_cluster_bringup_command_line "$ver" "$dl_worker_ips")"
      dl_bringup_cmd="${dl_bringup_cmd%$'\n'}"
    fi
    if [[ -n "$da_worker_ips" ]]; then
      da_bringup_cmd="$(gui_cluster_bringup_command_line "$ver" "$da_worker_ips")"
      da_bringup_cmd="${da_bringup_cmd%$'\n'}"
    fi
  else
    bringup_cmd="sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --version ${ver} --skip-download"
  fi
  prereq_cmd="set -euo pipefail; . /etc/os-release; test \"\$ID\" = ubuntu; test \"\$VERSION_ID\" = 24.04; test \"\$VERSION_CODENAME\" = noble; getent passwd aella root | awk -F: '\$7!=\"/bin/bash\"{exit 1}'; avail_root=\$(df -BG --output=avail / | awk 'NR==2{gsub(/G/,\"\"); print}'); avail_data=\$(df -BG --output=avail /opt/aelladata 2>/dev/null | awk 'NR==2{gsub(/G/,\"\"); print}'); test \"\${avail_root:-0}\" -ge 20; test \"\${avail_data:-0}\" -ge 70; ! pgrep -fa 'apt-get|dpkg|do-release-upgrade|dp-offline-upgrade' >/dev/null"

  hop_copy_guide='Copy and paste the following entire line into the DP terminal:'

  if [[ "$topology" == "cluster" ]]; then
    if mm_is_phase2_only; then
      cluster_rule="$(gui_cluster_execution_rule "STEPS 0–4" "STEP 5" "STEP 5A" "STEP 5B")"
    else
      cluster_rule="$(gui_cluster_execution_rule "STEPS 0–7" "STEP 8" "STEP 8A" "STEP 8B")"
    fi
    step6_where="$(gui_cluster_stage_guidance "STEP 7" "STEP 8")"
    step2_where="$(gui_cluster_stage_guidance "STEP 4" "STEP 5")"
  else
    step6_where="$(gui_aio_stage_guidance "STEP 7")"
    step2_where="$(gui_aio_stage_guidance "STEP 4")"
    cluster_rule=""
  fi

  if mm_is_phase2_only; then
    cat <<EOF
DP Phase 2 Upgrade Commands
===========================

DP Target Version: ${ver}
Required OS: Ubuntu 24.04
Mirror Server: ${mirror}

QUICK FLOW
----------
0 Precheck → 1 Pause → 2 Power off + snapshot → 3 Prerequisites
→ 4 Phase 2 staging → 5 Bringup → 6 Resume if needed → 7 Verify health

IMPORTANT
---------
• Run all commands on the DP, not on the Mirror Server.
• Snapshot/checkpoint only while the DP VM/node is powered off.
• Do not edit the generated commands.
• If DP ${ver} is already healthy on Ubuntu 24.04, stop.

${cluster_rule}
NAVIGATION
----------
↑ / ↓      Move up and down
Home       Go to the top
End        Go to the bottom

Commands are also saved to:
  $(mm_client_commands_file)

DETAILS
-------
Supported Starting DP Versions: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0
Starting DP Version is detected automatically on the DP.
Do not edit the stage command to add a source version.
DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2

STEP 0 — DP PRECHECK
--------------------
Run aella_cli and check current DP status before making any change.

Confirm there is no unexpected critical condition that should block the upgrade.

STEP 1 — PAUSE DP
-----------------
Run aella_cli and pause the DP.

Confirm:
  System paused.

Do not continue until the DP is paused.
Do not run pause in the Linux bash shell.

STEP 2 — POWER OFF / SNAPSHOT CHECKPOINT / POWER ON
---------------------------------------------------
After the DP is paused, power off the DP VM/node from the hypervisor or cloud console.
${snap_line}

Do not continue until the snapshot/checkpoint is complete.
Power the DP VM/node back on and confirm it is reachable.
Do not resume DP services.

STEP 3 — VERIFY UBUNTU 24.04 AND PREREQUISITES
----------------------------------------------
Confirm before staging (~30+ GiB):
• Ubuntu 24.04 Noble
• aella/root login shell is /bin/bash
• free space: root ≥20GiB, /opt/aelladata ≥70GiB

${hop_copy_guide}

${prereq_cmd}

STEP 4 — PHASE 2 STAGING
------------------------
Stage and verify the DP ${ver} Phase 2 files.

${step2_where}

${hop_copy_guide}

${stage_cmd}

EOF
    if [[ "$topology" == "cluster" ]]; then
      cat <<EOF
STEP 5 — DP ${ver} BRINGUP
--------------------------
After STEP 4 on ALL nodes, run masters only.

Management or cluster IPs may be used for --worker-ips.
Cluster IP addresses are recommended when reachable.

EOF
      gui_emit_cluster_master_bringup "STEP 5A" "DL" "$dl_worker_ips" "$dl_bringup_cmd"
      gui_emit_cluster_master_bringup "STEP 5B" "DA" "$da_worker_ips" "$da_bringup_cmd"
    else
      cat <<EOF
STEP 5 — DP ${ver} BRINGUP
--------------------------
AIO:
Run Phase 2 bringup on this DP.

${hop_copy_guide}

${bringup_cmd}

EOF
    fi
    cat <<EOF
STEP 6 — RESUME DP SERVICES WHEN REQUIRED
-----------------------------------------
BRINGUP_RESULT=PASS means bringup succeeded.
It does NOT mean DP_UPGRADE_COMPLETE=YES.
The DP may still be paused.

1) Collect status:
     sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --validate-cluster

2) If paused, resume inside aella_cli only:
     sudo /usr/bin/aella_cli
       resume
       show status
   Do not run resume in the Linux bash shell.

3) Re-check:
     sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --validate-cluster

STEP 7 — VERIFY DP HEALTH / RECORD COMPLETION
---------------------------------------------
Confirm readiness signals such as:
• All cluster nodes are ready
• All host services are ready
• License is valid
• Indices / models / provision ready when shown
• No explicit critical failure

Pod count phrases like "at least N expected" are informational.

If SOURCE DP was 6.2 / 6.3 / 6.4, run schema migration
(operator-run; never auto-executed):
  sudo bash /opt/aelladata/da-upgrade/scripts/upgrade_script.sh ${ver}
Then:
  sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --record-post-bringup-migration PASS

When not paused, healthy, and migration recorded PASS:
  sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --record-cluster-validation PASS

DP_UPGRADE_COMPLETE=YES only after bringup PASS + migration OK + CLUSTER_VALIDATION=PASS.

EOF
  else
    cat <<EOF
DP Client Upgrade Commands
==========================

Upgrade: Ubuntu 16.04 → 24.04
DP Target Version: ${ver}
Mirror Server: ${mirror}

QUICK FLOW
----------
0 Precheck → 1 Pause → 2 Power off + snapshot → 3–6 OS upgrades
→ 7 Phase 2 staging → 8 Bringup → 9 Resume if needed → 10 Verify health

IMPORTANT
---------
• Run all commands on the DP, not on the Mirror Server.
• Upgrade only ONE DP node at a time.
• Snapshot/checkpoint only while the DP VM/node is powered off.
• Do not resume DP services between OS upgrade hops.
• Do not edit the generated commands.

${cluster_rule}
NAVIGATION
----------
↑ / ↓      Move up and down
Home       Go to the top
End        Go to the bottom

Commands are also saved to:
  $(mm_client_commands_file)

DETAILS
-------
Supported Starting DP Versions: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0
Starting DP Version is detected automatically on the DP.
Do not edit the stage command to add a source version.
DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2
DP_OS_HOP_COMMAND_VERSION=WRAPPER_V1

STEP 0 — DP PRECHECK
--------------------
Run aella_cli and check current DP status before making any change.

Confirm the DP is in the expected starting state and there is no unexpected
critical condition that should block the upgrade.

STEP 1 — PAUSE DP
-----------------
Run aella_cli and pause the DP.

Confirm:
  System paused.

Do not continue until the DP is paused.
Do not run pause in the Linux bash shell.
Do not resume DP services between OS upgrade hops.

STEP 2 — POWER OFF / SNAPSHOT CHECKPOINT / POWER ON
---------------------------------------------------
After the DP is paused, power off the DP VM/node from the hypervisor or cloud console.
${snap_line}

Do not continue until the snapshot/checkpoint is complete.
Power the DP VM/node back on and confirm it is reachable.
Do not resume DP services.

STEP 3 — UBUNTU 16.04 → 18.04
------------------------------
Run the generated command below.
The DP reboots automatically.
The Xenial-to-Bionic client automatically sets the aella and root login
shells to /bin/bash after upgrade confirmation.

${hop_copy_guide}

${hop2}

STEP 4 — UBUNTU 18.04 → 20.04
------------------------------
Run the generated command below.

${hop_copy_guide}

${hop3}

STEP 5 — UBUNTU 20.04 → 22.04
------------------------------
Run the generated command below.

${hop_copy_guide}

${hop4}

STEP 6 — UBUNTU 22.04 → 24.04
------------------------------
Run the generated command below.

${hop_copy_guide}

${hop5}

STEP 7 — PHASE 2 STAGING
------------------------
Stage and verify the DP ${ver} Phase 2 files.

${step6_where}

${hop_copy_guide}

${stage_cmd}

EOF
    if [[ "$topology" == "cluster" ]]; then
      cat <<EOF
STEP 8 — DP ${ver} BRINGUP
--------------------------
Cluster:
After STEP 7 on ALL nodes, run masters only.

Management or cluster IPs may be used for --worker-ips.
Cluster IP addresses are recommended when reachable.

Do not run STEP 8 manually on workers.

EOF
      gui_emit_cluster_master_bringup "STEP 8A" "DL" "$dl_worker_ips" "$dl_bringup_cmd"
      gui_emit_cluster_master_bringup "STEP 8B" "DA" "$da_worker_ips" "$da_bringup_cmd"
    else
      cat <<EOF
STEP 8 — DP ${ver} BRINGUP
--------------------------
AIO:
Run Phase 2 bringup on this DP.

${hop_copy_guide}

${bringup_cmd}

EOF
    fi
    cat <<EOF
STEP 9 — RESUME DP SERVICES WHEN REQUIRED
-----------------------------------------
BRINGUP_RESULT=PASS means bringup succeeded.
It does NOT mean DP_UPGRADE_COMPLETE=YES.
The DP may still be paused.

1) Collect status:
     sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --validate-cluster

2) If paused, resume inside aella_cli only:
     sudo /usr/bin/aella_cli
       resume
       show status
   Do not run resume in the Linux bash shell.

3) Re-check:
     sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --validate-cluster

STEP 10 — VERIFY DP HEALTH / RECORD COMPLETION
----------------------------------------------
Confirm readiness signals such as:
• All cluster nodes are ready
• All host services are ready
• License is valid
• Indices / models / provision ready when shown
• No explicit critical failure

Pod count phrases like "at least N expected" are informational.

If SOURCE DP was 6.2 / 6.3 / 6.4, run schema migration
(operator-run; never auto-executed):
  sudo bash /opt/aelladata/da-upgrade/scripts/upgrade_script.sh ${ver}
Then:
  sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --record-post-bringup-migration PASS

When not paused, healthy, and migration recorded PASS:
  sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --record-cluster-validation PASS

DP_UPGRADE_COMPLETE=YES only after bringup PASS + migration OK + CLUSTER_VALIDATION=PASS.

Status may take several minutes after resume.
Do not treat the DP as healthy immediately after resume.

EOF
  fi
  if [[ "$topology" == "cluster" ]]; then
    cat <<EOF
CLUSTER STATUS
--------------
Run the status check on the cluster master.
Confirm all workers are ready.
Confirm DL first, then DA.

EOF
  fi
}

gui_client_instructions() {
  load_mirror_defaults
  mm_load_gui_config
  mm_normalize_preparation_mode
  mm_force_phase2_target
  engine_resolve_paths
  local ver="${PHASE2_TARGET_VERSION}"
  local mirror topology dl_worker_ips="" da_worker_ips="" out_file tmp title ready_gen
  local block_msg

  # Lightweight readiness preflight — never show commands when blocked.
  if ! mm_wf_commands_preflight; then
    block_msg="DP_CLIENT_COMMANDS_AVAILABLE=NO
BLOCK_REASON=${MM_WF_BLOCK_REASON:-UNKNOWN}
REQUIRED_ACTION=${MM_WF_REQUIRED_ACTION:-Verify Upgrade Readiness}

Menu 7 will not display upgrade commands until the workflow
generation contract is satisfied.

Typical next steps:
  3. Enable HTTP Distribution
  4. Verify Upgrade Readiness
  then reopen this menu."
    mm_whiptail_msg "DP Client Upgrade Commands — Blocked" "$block_msg"
    return 0
  fi

  out_file="$(mm_client_commands_file)"
  if mm_is_phase2_only; then
    title="DP Phase 2 Upgrade Commands"
  else
    title="DP Client Upgrade Commands"
  fi

  # Fast path: when Menu 4 already verified this generation and the published
  # command file is current, view it read-only. Do NOT re-run HTTP smoke or
  # rebuild/sign commands merely because the operator opened Menu 7.
  if ! mm_client_commands_stale \
    && [[ -f "$out_file" && -s "$out_file" ]] \
    && mm_menu7_command_file_generation_current; then
    export MENU7_CACHED_OPEN_PATH=PASS
    mm_menu7_textbox "$title" "$out_file" || true
    return 0
  fi

  # Rebuild path only: command file missing/stale/invalid for this generation.
  # HTTP smoke remains Menu 3/4 authoritative work — not a Menu 7 view tax.
  # Optional MM_MENU7_HTTP_SMOKE=1 re-enables smoke for diagnostics.
  if [[ "${MM_MENU7_HTTP_SMOKE:-0}" == "1" ]]; then
    if declare -F engine_http_local_smoke >/dev/null 2>&1; then
      if [[ "${MM_SKIP_HTTP_VALIDATE:-0}" != "1" ]] \
        && ! engine_http_local_smoke >/dev/null 2>&1; then
        mm_whiptail_msg "DP Client Upgrade Commands — Blocked" \
          "DP_CLIENT_COMMANDS_AVAILABLE=NO
BLOCK_REASON=LOCAL_HTTP_SMOKE_FAIL
REQUIRED_ACTION=Enable HTTP Distribution"
        return 0
      fi
    fi
    if declare -F engine_http_advertised_smoke >/dev/null 2>&1; then
      if [[ "${MM_SKIP_HTTP_VALIDATE:-0}" != "1" ]] \
        && ! engine_http_advertised_smoke >/dev/null 2>&1; then
        mm_whiptail_msg "DP Client Upgrade Commands — Blocked" \
          "DP_CLIENT_COMMANDS_AVAILABLE=NO
BLOCK_REASON=ADVERTISED_HTTP_SMOKE_FAIL
REQUIRED_ACTION=Enable HTTP Distribution"
        return 0
      fi
    fi
  fi

  mirror="$(mm_client_mirror_url)" || {
    mm_whiptail_msg "DP Client Upgrade Commands" \
      "DP_CLIENT_COMMANDS_AVAILABLE=NO
BLOCK_REASON=MIRROR_URL_UNRESOLVED
REQUIRED_ACTION=Configuration

Set Mirror Server IP in Configuration before generating commands."
    return 0
  }
  # Persist resolved URL for next runs (no secrets). Merge so a URL-only
  # persistence cannot wipe legacy compatibility auth fields or worker settings.
  if [[ -z "${MIRROR_HTTP_URL:-}" ]]; then
    MIRROR_HTTP_URL="$mirror"
    mm_merge_gui_config >/dev/null 2>&1 || true
  fi

  if mm_client_commands_stale; then
    mm_whiptail_msg "Client Commands" \
      "Previously generated commands are stale relative to the current
workflow generation.

New commands will be generated for: $(mm_preparation_mode_label)"
  fi

  dl_worker_ips="${DL_WORKER_IPS:-}"
  da_worker_ips="${DA_WORKER_IPS:-}"
  if [[ -n "$dl_worker_ips" ]]; then
    dl_worker_ips="$(mm_validate_worker_ips "$dl_worker_ips")" || {
      mm_whiptail_msg "Invalid DL Worker IPs" \
        "Fix DL Worker IP addresses in Configuration, save, then reopen Menu 7."
      return 0
    }
  fi
  if [[ -n "$da_worker_ips" ]]; then
    da_worker_ips="$(mm_validate_worker_ips "$da_worker_ips")" || {
      mm_whiptail_msg "Invalid DA Worker IPs" \
        "Fix DA Worker IP addresses in Configuration, save, then reopen Menu 7."
      return 0
    }
  fi
  if [[ -n "${dl_worker_ips}${da_worker_ips}" ]]; then
    topology="cluster"
    if ! mm_validate_worker_ssh_password "${WORKER_SSH_PASSWORD:-}" "${dl_worker_ips}${da_worker_ips}"; then
      mm_whiptail_msg "Worker SSH Password required" \
        "Set Worker SSH Password (aella) in Configuration before generating cluster Phase 2 commands."
      return 0
    fi
  else
    topology="single"
  fi

  tmp="$(mktemp)"
  export MENU7_CACHED_OPEN_PATH=MISS
  gui_build_client_commands "$mirror" "$topology" "$dl_worker_ips" "$da_worker_ips" "${WORKER_SSH_PASSWORD:-}" >"$tmp"
  ready_gen="$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)"
  if ! mm_wf_atomic_publish_command_file "$tmp" "$out_file" "${PREPARATION_MODE}" "$ready_gen"; then
    # Candidate never replaces live; delete after validation evidence is logged.
    rm -f "$tmp"
    mm_whiptail_msg "DP Client Upgrade Commands" \
      "COMMAND_FILE_BUILD=FAIL

Generated command content failed validation.
The previous live command file (if any) was preserved.

Required action: Regenerate Full-mode artifacts / Verify Upgrade Readiness"
    return 0
  fi
  # Successful publish moves tmp into place; rm is a no-op if already gone.
  rm -f "$tmp"
  # Show the full step list in one scrollable viewer — no secondary menu,
  # no less pager, no terminal reprint after GUI close.
  mm_menu7_textbox "$title" "$out_file" || true
  return 0
}

cmd_mirror_manager() {
  export MM_GUI_MODE=1
  # Official entry: sudo ubuntu-offline-mirror mirror-manager (root only).
  # Check before loading root-owned config/logs to avoid raw Permission denied.
  mm_require_root
  load_mirror_defaults
  engine_resolve_paths
  mm_load_gui_config
  if [[ "${MM_FORCE_MENU:-0}" != "1" ]] && { [[ ! -t 0 ]] || [[ ! -t 1 ]]; }; then
    cat <<EOF
NON_INTERACTIVE_TTY=FAIL
Use: sudo $0 mirror-manager   (interactive TTY)
Or:  sudo ./scripts/ubuntu-offline-mirror.sh mirror-manager
EOF
    exit 1
  fi
  while true; do
    local choice="" menu_rc=0
    local configuration_label download_label http_label readiness_label progress_line
    local menu_start_ms menu_end_ms
    menu_start_ms="$(mm_gui_now_ms)"
    mm_collect_workflow_status
    configuration_label="$(mm_menu_label "Configuration" "${MM_WF_CONFIG_COMPLETED}")"
    download_label="$(mm_menu_label "Download and Prepare Upgrade Files" "${MM_WF_DOWNLOAD_COMPLETED}")"
    http_label="$(mm_menu_label "Enable HTTP Distribution" "${MM_WF_HTTP_COMPLETED}")"
    readiness_label="$(mm_menu_label "Verify Upgrade Readiness" "${MM_WF_READINESS_COMPLETED}")"
    progress_line="$(mm_workflow_progress_text)"
    menu_end_ms="$(mm_gui_now_ms)"
    mm_gui_transition_log "main_menu_redraw" "$((menu_end_ms - menu_start_ms))"
    choice="$(mm_whiptail_menu \
      "DP Ubuntu Upgrade Mirror Manager" \
      "Workflow: Configuration → Download → Enable HTTP → Verify Readiness
${progress_line}
Cancel/ESC returns here; choose 0 to Exit." \
      "1" "${configuration_label}" \
      "2" "${download_label}" \
      "3" "${http_label}" \
      "4" "${readiness_label}" \
      "5" "Show Current Status" \
      "6" "View Logs" \
      "7" "Show DP Client Upgrade Commands" \
      "0" "Exit")" || menu_rc=$?
    # Cancel/ESC on the main menu must NOT drop to the shell; only "0 Exit" leaves.
    if [[ "$menu_rc" -ne 0 ]]; then
      continue
    fi
    case "$choice" in
      1) gui_run_action "Configuration" gui_configuration ;;
      2) gui_run_action "Download and Prepare" gui_download_and_prepare ;;
      3) gui_run_action "Enable HTTP Distribution" gui_enable_http ;;
      4) gui_run_action "Verify Upgrade Readiness" gui_verify_readiness ;;
      5) gui_run_action "Show Current Status" gui_show_status ;;
      6) gui_run_action "View Logs" gui_view_logs ;;
      7) gui_run_action "DP Client Upgrade Commands" gui_client_instructions ;;
      0)
        # GUI_EXITS_ONLY_ON_EXPLICIT_ZERO
        return 0
        ;;
      "")
        continue
        ;;
      *)
        mm_whiptail_msg "Invalid selection" "Unknown menu selection: ${choice}" || true
        ;;
    esac
  done
}

# Non-interactive helpers for tests
cmd_download_and_prepare() {
  mm_require_root
  load_mirror_defaults
  engine_download_and_prepare
}

cmd_verify_readiness() {
  mm_require_root
  load_mirror_defaults
  mm_load_gui_config
  engine_resolve_paths
  engine_compute_readiness
}

cmd_diagnose_mirror_runtime() {
  # Read-only: no root required for diagnosis of local status/nginx state,
  # but load the same path resolution as other commands.
  load_mirror_defaults
  mm_load_gui_config 2>/dev/null || true
  engine_resolve_paths 2>/dev/null || true
  mm_diagnose_mirror_runtime_state
}

cmd_enable_http() {
  mm_require_root
  load_mirror_defaults
  engine_enable_http_distribution
}

usage() {
  cat <<EOF
Usage: $0 <command>

DP Ubuntu Upgrade Mirror Manager (single workflow: R2 OS Core + immutable R2 Phase 2).

Fresh hosts should bootstrap with: sudo ./install.sh
Re-open GUI after install:         sudo ubuntu-offline-mirror mirror-manager

Commands:
  mirror-manager          Interactive whiptail Mirror Manager (default)
  download-and-prepare    Non-interactive prepare (saved config + fixed R2 URL)
  verify-readiness        Print UPGRADE_READINESS
  enable-http             Install/enable nginx site and smoke-test HTTP
  diagnose-mirror-runtime Read-only heavy/client/HTTP/nginx/readiness snapshot
EOF
}

main() {
  local cmd="${1:-mirror-manager}"
  if [[ "$cmd" == "-h" || "$cmd" == "--help" || "$cmd" == "help" ]]; then
    usage
    exit 0
  fi
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mirror-root)
        MM_MIRROR_ROOT="${2:-}"
        MM_SELECTIVE_ROOT="${MM_MIRROR_ROOT}/selective"
        MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
        MM_CLIENT_ROOT="${MM_MIRROR_ROOT}/client"
        shift 2
        ;;
      --dry-run) MM_DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) mm_die "Unknown argument: $1" ;;
    esac
  done
  case "$cmd" in
    mirror-manager|install-menu) cmd_mirror_manager ;;
    download-and-prepare) cmd_download_and_prepare ;;
    verify-readiness) cmd_verify_readiness ;;
    enable-http) cmd_enable_http ;;
    diagnose-mirror-runtime) cmd_diagnose_mirror_runtime ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
