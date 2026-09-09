#!/usr/bin/env bash
# uninstall.sh — Safely remove Ubuntu Mirror Server automation components.
# NEVER deletes mirror package data unless --purge-data --force is given.
set -euo pipefail

UM_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${UM_PROJECT_ROOT}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${UM_PROJECT_ROOT}/lib/config.sh"
# shellcheck source=lib/runtime_manifest.sh
source "${UM_PROJECT_ROOT}/lib/runtime_manifest.sh"

UM_DRY_RUN=0
UM_FORCE=0
UM_PURGE_DATA=0
UM_PURGE_PACKAGES=0
UM_NON_INTERACTIVE=0
UM_CONFIG_ARG=""

usage() {
  cat <<'EOF'
Usage: sudo ./uninstall.sh [OPTIONS]

Removes automation units, nginx site, and installed helper scripts.
Does NOT delete mirrored packages unless --purge-data --force.

Options:
  --config PATH      Config path
  --dry-run          Show actions only
  --force            Required for destructive options
  --purge-data       Delete product-owned mirror data under BASE_PATH (DANGEROUS)
  --purge-packages   apt-get remove apt-mirror (nginx left installed)
  -h, --help         Show help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) UM_CONFIG_ARG="${2:-}"; shift 2 ;;
      --dry-run) UM_DRY_RUN=1; shift ;;
      --force) UM_FORCE=1; shift ;;
      --non-interactive) UM_NON_INTERACTIVE=1; shift ;;
      --purge-data) UM_PURGE_DATA=1; shift ;;
      --purge-packages) UM_PURGE_PACKAGES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) um_die "Unknown option: $1" ;;
    esac
  done
}

stop_units() {
  um_info "Stopping apt-mirror timer/service"
  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_info "DRY-RUN: systemctl disable --now apt-mirror.timer"
    return 0
  fi
  systemctl disable --now apt-mirror.timer 2>/dev/null || true
  systemctl stop apt-mirror.service 2>/dev/null || true
  if pgrep -f '/usr/bin/apt-mirror' >/dev/null 2>&1; then
    um_warn "apt-mirror process still running — not killing automatically"
    um_warn "Stop manually if needed: pkill -f /usr/bin/apt-mirror"
  fi
}

remove_systemd() {
  local files=(
    /etc/systemd/system/apt-mirror.service
    /etc/systemd/system/apt-mirror.timer
  )
  local f
  for f in "${files[@]}"; do
    if [[ -e "$f" ]]; then
      um_backup_file "$f" >/dev/null || true
      um_run rm -f "$f"
    fi
  done
  if [[ "$UM_DRY_RUN" != "1" ]]; then
    systemctl daemon-reload || true
  fi
}

remove_nginx_site() {
  local name="${NGINX_SITE_NAME:-apt-mirror}"
  local avail="/etc/nginx/sites-available/${name}"
  local enabled="/etc/nginx/sites-enabled/${name}"
  if [[ -e "$enabled" ]]; then
    um_run rm -f "$enabled"
  fi
  if [[ -e "$avail" ]]; then
    um_backup_file "$avail" >/dev/null || true
    um_run rm -f "$avail"
  fi
  if um_command_exists nginx && [[ "$UM_DRY_RUN" != "1" ]]; then
    if nginx -t 2>/dev/null; then
      systemctl reload nginx || true
    fi
  fi
}

# Symmetric with bootstrap install: remove runtime tree + current entrypoints.
remove_bins() {
  local bins=(
    mirrorctl mirror-status.sh mirror-recovery.sh validate.sh
    client-setup.sh client-validate.sh
    ubuntu-offline-mirror
  )
  local b
  for b in "${bins[@]}"; do
    um_run rm -f "${INSTALL_BIN_DIR}/${b}"
  done
  um_run rm -f /usr/local/sbin/mirrorctl
  local sbin_link="${UM_UOM_INSTALL_PATH:-/usr/local/sbin/ubuntu-offline-mirror.sh}"
  um_run rm -f "$sbin_link"
  # Drop other installed script entrypoint names if present as direct bins.
  local ep
  for ep in "${UM_RUNTIME_SCRIPT_ENTRYPOINTS[@]}"; do
    um_run rm -f "${INSTALL_BIN_DIR}/${ep}"
    um_run rm -f "/usr/local/sbin/${ep}"
  done
  # Bind recursive deletes to independent approved install locations (fail closed).
  # Approved roots are NOT derived from the candidate path.
  um_assert_runtime_destructive_path "${INSTALL_LIB_DIR}" "INSTALL_LIB_DIR"
  um_run rm -rf "${INSTALL_LIB_DIR}"
  # Keep INSTALL_CONF_DIR unless force — operator may want mirror.conf
  if [[ "$UM_FORCE" == "1" ]]; then
    um_assert_runtime_destructive_path "${INSTALL_CONF_DIR}" "INSTALL_CONF_DIR"
    um_run rm -rf "${INSTALL_CONF_DIR}"
  else
    um_info "Keeping ${INSTALL_CONF_DIR} (use --force to remove)"
  fi
}

restore_mirror_list_note() {
  if [[ -f /etc/apt/mirror.list ]]; then
    um_backup_file /etc/apt/mirror.list >/dev/null || true
    um_warn "Left /etc/apt/mirror.list in place (backed up). Remove manually if desired."
  fi
}

# Production authoritative recursive-delete targets. Independent trust boundary:
# never derived from INSTALL_* candidate paths.
UM_PROD_INSTALL_LIB_DIR="/usr/local/lib/ubuntu-mirror"
UM_PROD_INSTALL_CONF_DIR="/etc/ubuntu-mirror"

# Resolve the approved exact path for a runtime/config recursive delete.
# Hermetic tests may set MM_HERMETIC_TEST_MODE=1 and UM_TEST_APPROVED_ROOT=<tmp>
# to mirror production layout under a dedicated test prefix.
um_approved_runtime_path_for_label() {
  local label="$1"
  local base
  if [[ "${MM_HERMETIC_TEST_MODE:-0}" == "1" && -n "${UM_TEST_APPROVED_ROOT:-}" ]]; then
    base="${UM_TEST_APPROVED_ROOT%/}"
    case "$label" in
      INSTALL_LIB_DIR) printf '%s\n' "${base}/usr/local/lib/ubuntu-mirror"; return 0 ;;
      INSTALL_CONF_DIR) printf '%s\n' "${base}/etc/ubuntu-mirror"; return 0 ;;
    esac
    return 1
  fi
  case "$label" in
    INSTALL_LIB_DIR) printf '%s\n' "${UM_PROD_INSTALL_LIB_DIR}"; return 0 ;;
    INSTALL_CONF_DIR) printf '%s\n' "${UM_PROD_INSTALL_CONF_DIR}"; return 0 ;;
  esac
  return 1
}

# Validate configurable runtime/config dirs before rm -rf against the independent
# approved location for the label (not dirname of the candidate).
um_assert_runtime_destructive_path() {
  local path="$1"
  local label="${2:-path}"
  local approved_root resolved approved_resolved parent depth
  [[ -n "$path" ]] || um_die "DESTRUCTIVE_PATH=FAIL label=${label} reason=empty"
  approved_root="$(um_approved_runtime_path_for_label "$label")" \
    || um_die "DESTRUCTIVE_PATH=FAIL label=${label} reason=unknown_label"
  [[ -n "$approved_root" ]] || um_die "DESTRUCTIVE_PATH=FAIL label=${label} reason=empty_approved_root"
  if [[ -L "$path" ]]; then
    um_die "DESTRUCTIVE_PATH=FAIL label=${label} reason=symlink path=${path}"
  fi
  if [[ -e "$path" ]]; then
    resolved="$(realpath -m "$path" 2>/dev/null || readlink -f "$path" 2>/dev/null || printf '%s' "$path")"
  else
    parent="$(dirname "$path")"
    if [[ -d "$parent" ]]; then
      resolved="$(realpath -m "$parent" 2>/dev/null || printf '%s' "$parent")/$(basename "$path")"
    else
      resolved="$path"
    fi
  fi
  resolved="${resolved%/}"
  [[ -n "$resolved" ]] || resolved="/"
  case "$resolved" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/local|/var|/var/lib)
      um_die "DESTRUCTIVE_PATH=FAIL label=${label} reason=forbidden_root path=${resolved}"
      ;;
  esac
  if [[ -e "$approved_root" ]]; then
    approved_resolved="$(realpath -m "$approved_root" 2>/dev/null || printf '%s' "$approved_root")"
  else
    approved_resolved="${approved_root%/}"
  fi
  approved_resolved="${approved_resolved%/}"
  # Candidate must equal the approved exact location (or a nested path under it).
  case "$resolved" in
    "$approved_resolved"|"$approved_resolved"/*) ;;
    *)
      um_die "DESTRUCTIVE_PATH=FAIL label=${label} reason=outside_approved_root path=${resolved} root=${approved_resolved}"
      ;;
  esac
  depth="$(awk -F/ '{print NF-1}' <<<"$resolved")"
  local min_depth=3
  if [[ "$label" == "INSTALL_CONF_DIR" ]]; then
    # /etc/ubuntu-mirror is depth 2; hermetic ${TMP}/etc/ubuntu-mirror is deeper.
    if [[ "$approved_resolved" == "/etc/ubuntu-mirror" || "$approved_resolved" == */etc/ubuntu-mirror ]]; then
      min_depth=2
    fi
  fi
  if [[ "$depth" -lt "$min_depth" ]]; then
    um_die "DESTRUCTIVE_PATH=FAIL label=${label} reason=insufficient_depth path=${resolved}"
  fi
  return 0
}

# Validate a product-owned path before rm -rf. Rejects /, empty, shallow,
# symlink escape outside BASE_PATH, and unexpected parents.
um_assert_purge_path() {
  local path="$1"
  local approved="${2:-$BASE_PATH}"
  local resolved approved_resolved parent depth
  [[ -n "$path" ]] || um_die "PURGE_PATH=FAIL reason=empty"
  [[ -n "$approved" ]] || um_die "PURGE_PATH=FAIL reason=empty_base"
  if [[ -L "$path" ]]; then
    um_die "PURGE_PATH=FAIL reason=symlink path=${path}"
  fi
  if [[ -e "$path" ]]; then
    resolved="$(realpath -m "$path" 2>/dev/null || readlink -f "$path" 2>/dev/null || printf '%s' "$path")"
  else
    parent="$(dirname "$path")"
    if [[ -d "$parent" ]]; then
      resolved="$(realpath -m "$parent" 2>/dev/null || printf '%s' "$parent")/$(basename "$path")"
    else
      resolved="$path"
    fi
  fi
  resolved="${resolved%/}"
  [[ -n "$resolved" ]] || resolved="/"
  case "$resolved" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      um_die "PURGE_PATH=FAIL reason=forbidden_root path=${resolved}"
      ;;
  esac
  if [[ -e "$approved" ]]; then
    approved_resolved="$(realpath -m "$approved" 2>/dev/null || printf '%s' "$approved")"
  else
    approved_resolved="${approved%/}"
  fi
  approved_resolved="${approved_resolved%/}"
  case "$resolved" in
    "$approved_resolved"|"$approved_resolved"/*) ;;
    *)
      um_die "PURGE_PATH=FAIL reason=outside_base path=${resolved} base=${approved_resolved}"
      ;;
  esac
  depth="$(awk -F/ '{print NF-1}' <<<"$resolved")"
  if [[ "$depth" -lt 3 ]]; then
    um_die "PURGE_PATH=FAIL reason=insufficient_depth path=${resolved}"
  fi
  return 0
}

purge_data() {
  if [[ "$UM_PURGE_DATA" != "1" ]]; then
    return 0
  fi
  if [[ "$UM_FORCE" != "1" ]]; then
    um_die "--purge-data requires --force"
  fi
  local base="${BASE_PATH}"
  [[ -n "$base" ]] || um_die "PURGE_DATA=FAIL reason=empty_BASE_PATH"
  um_assert_purge_path "$base" "$base"

  # Current-generation product-owned large-data roots (plus legacy apt-mirror).
  local -a targets=(
    "${base}/selective"
    "${base}/dp-phase2"
    "${base}/client"
    "${base}/.install-cache"
    "${base}/offline"
    "${MIRROR_PATH}"
    "${SKEL_PATH}"
    "${VAR_PATH}"
  )
  local t
  um_warn "DESTRUCTIVE purge authorized for product-owned paths under ${base}"
  for t in "${targets[@]}"; do
    um_info "PURGE_CANDIDATE=${t}"
  done
  if [[ "$UM_NON_INTERACTIVE" != "1" ]]; then
    um_confirm "Confirm deletion of listed product-owned paths under ${base} ?" \
      || um_die "Aborted"
  fi
  for t in "${targets[@]}"; do
    [[ -n "$t" ]] || continue
    um_assert_purge_path "$t" "$base"
    if [[ -e "$t" || -L "$t" ]]; then
      um_info "PURGE_DELETE=${t}"
      um_run rm -rf "$t"
    else
      um_info "PURGE_SKIP_MISSING=${t}"
    fi
  done
  um_ok "Mirror data removed"
}

purge_packages() {
  if [[ "$UM_PURGE_PACKAGES" != "1" ]]; then
    return 0
  fi
  if [[ "$UM_FORCE" != "1" ]]; then
    um_die "--purge-packages requires --force"
  fi
  um_run apt-get remove -y apt-mirror || true
  um_warn "nginx left installed (shared service)"
}

main() {
  parse_args "$@"
  um_setup_trap
  if [[ "$UM_DRY_RUN" != "1" ]]; then
    um_require_root
  fi
  um_load_config "$UM_CONFIG_ARG"
  um_set_log_file "${LOG_DIR}/uninstall.log"
  um_ensure_log_dir
  um_info "=== Uninstall begin ==="

  stop_units
  remove_systemd
  remove_nginx_site
  remove_bins
  restore_mirror_list_note
  purge_data
  purge_packages

  um_ok "=== Uninstall finished ==="
  um_info "Backups under ${BACKUP_DIR}; logs under ${LOG_DIR}"
}

main "$@"
