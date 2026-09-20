#!/usr/bin/env bash
# install.sh — Fresh Ubuntu 24.04 bootstrap for DP Upgrade Mirror Manager
# Default: sudo ./install.sh
#   host preflight → packages → dirs → runtime → nginx base → GUI
# Large Cloudflare R2 downloads are NOT started here; use the GUI menu.
set -euo pipefail

UM_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${UM_PROJECT_ROOT}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${UM_PROJECT_ROOT}/lib/config.sh"
# shellcheck source=lib/state.sh
source "${UM_PROJECT_ROOT}/lib/state.sh"
# shellcheck source=lib/bootstrap.sh
source "${UM_PROJECT_ROOT}/lib/bootstrap.sh"

# Bootstrap installs the authoritative runtime first. Replace only the public
# /usr/local/bin entrypoint afterward with the small Menu 7 presentation wrapper.
# The core runtime remains under /usr/local/lib and all non-GUI commands delegate
# to it unchanged.
eval "$(
  declare -f um_bootstrap_install_runtime \
    | sed '1s/^um_bootstrap_install_runtime[[:space:]]*()/_um_bootstrap_install_runtime_core ()/'
)"
um_bootstrap_install_runtime() {
  _um_bootstrap_install_runtime_core
  local bindir="${INSTALL_BIN_DIR:-/usr/local/bin}"
  local wrapper="${UM_PROJECT_ROOT}/scripts/ubuntu-offline-mirror-entrypoint.sh"
  local tmp
  [[ -f "$wrapper" ]] || um_die "RUNTIME_SOURCE_FILE_MISSING=${wrapper}"
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would install Menu 7 normal-width entrypoint at ${bindir}/ubuntu-offline-mirror"
    return 0
  fi
  mkdir -p "$bindir"
  tmp="${bindir}/.ubuntu-offline-mirror.tmp.$$"
  install -m 0755 "$wrapper" "$tmp"
  mv -f "$tmp" "${bindir}/ubuntu-offline-mirror"
  um_ok "MENU7_NORMAL_WIDTH_ENTRYPOINT=PASS path=${bindir}/ubuntu-offline-mirror"
}

UM_DRY_RUN=0
UM_FORCE=0
UM_VERBOSE=0
UM_NO_GUI=0
UM_CONFIG_ARG=""
UM_FORMAT_DEVICE=0

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [OPTIONS]

Bootstrap a clean Ubuntu 24.04 LTS amd64 host as a DP Ubuntu Upgrade
Mirror Manager server.

Single workflow:
  OS Core source  = Cloudflare R2 (fixed URL in code)
  Phase 2 source  = Cloudflare R2 (immutable validated release)
  DP client       = Mirror Server HTTP only

What this installer does:
  1. Ubuntu 24.04 / amd64 / root / systemd preflight
  2. Install required packages (nginx, whiptail, curl, python3, ...)
  3. Prepare mirror directories (no mkfs / no destructive disk ops)
  4. Install Mirror Manager runtime (works without the git checkout)
  5. Install nginx base site (direct selective tree; no current/previous)
  6. On an interactive TTY, start the Mirror Manager GUI

What this installer does NOT do:
  - Download the R2 OS Core package
  - Download Phase 2 artifacts from the immutable R2 release
  - Start background mirror synchronization
  - Create generation trees (current / previous / releases)

After install, reopen the GUI with:
  sudo ubuntu-offline-mirror mirror-manager

Options:
  --help              Show this help
  --config PATH       Use a custom mirror.conf for path defaults
  --dry-run           Show planned actions without changing the system
  --no-gui            Do not auto-start the GUI (print reopen command)
  --non-interactive   Alias for --no-gui (CI / scripted install)
  --verbose           Show detailed output
  --force             Replace managed configuration after backup

Examples:
  sudo ./install.sh
  sudo ./install.sh --dry-run
  sudo ./install.sh --non-interactive
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
      --dry-run) UM_DRY_RUN=1; shift ;;
      --no-gui|--non-interactive) UM_NO_GUI=1; shift ;;
      --verbose) UM_VERBOSE=1; shift ;;
      --force) UM_FORCE=1; shift ;;
      # Hidden expert option — never advertised as Quick Start
      --format-device) UM_FORMAT_DEVICE=1; shift ;;
      # Obsolete selective-install flags: hard error (silent no-op is dangerous)
      --no-sync|--selective|--menu|--no-menu|--foreground|--background|--start-sync|--skip-packages)
        um_die "Obsolete option $1 rejected — bootstrap uses Mirror Manager workflow only (see --help)"
        ;;
      --full)
        um_die "UNSUPPORTED_FULL_MIRROR_SYNC: use Mirror Manager workflow (sudo ./install.sh)"
        ;;
      --minimal)
        um_die "UNSUPPORTED_MINIMAL_PROFILE: use Mirror Manager workflow (sudo ./install.sh)"
        ;;
      -h|--help) usage; exit 0 ;;
      --validate) UM_VERBOSE=1; shift ;;
      *) um_die "Unknown option: $1 (see --help)" ;;
    esac
  done
}

main() {
  parse_args "$@"
  um_setup_trap

  if [[ -z "${UM_CONFIG_ARG}" ]] && [[ -f "${UM_PROJECT_ROOT}/mirror.conf" ]]; then
    UM_CONFIG_ARG="${UM_PROJECT_ROOT}/mirror.conf"
  fi

  UM_QUIET_LOAD=0
  if [[ -n "${UM_CONFIG_ARG}" ]]; then
    um_load_config "$UM_CONFIG_ARG"
  else
    # Minimal defaults when mirror.conf is absent
    BASE_PATH="${BASE_PATH:-/var/spool/apt-mirror}"
    SELECTIVE_MIRROR_ROOT="${SELECTIVE_MIRROR_ROOT:-${BASE_PATH}/selective}"
    SELECTIVE_NGINX_ROOT="${SELECTIVE_NGINX_ROOT:-${SELECTIVE_MIRROR_ROOT}}"
    DP_PHASE2_ROOT="${DP_PHASE2_ROOT:-${BASE_PATH}/dp-phase2}"
    LOG_DIR="${LOG_DIR:-/var/log/ubuntu-mirror}"
    INSTALL_BIN_DIR="${INSTALL_BIN_DIR:-/usr/local/bin}"
    INSTALL_LIB_DIR="${INSTALL_LIB_DIR:-/usr/local/lib/ubuntu-mirror}"
    INSTALL_CONF_DIR="${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}"
    BACKUP_DIR="${BACKUP_DIR:-/var/backups/ubuntu-mirror}"
    NGINX_SITE_NAME="${NGINX_SITE_NAME:-apt-mirror}"
    NGINX_DISABLE_DEFAULT="${NGINX_DISABLE_DEFAULT:-true}"
  fi

  # Force direct selective root (never .../current)
  SELECTIVE_NGINX_ROOT="${SELECTIVE_MIRROR_ROOT:-${BASE_PATH}/selective}"

  um_set_log_file "${LOG_DIR}/install.log"
  um_ensure_log_dir

  # Optional DATA_DEVICE mount only — never format unless hidden --format-device
  if [[ -n "${DATA_DEVICE:-}" ]] && [[ "${UM_FORMAT_DEVICE}" != "1" ]]; then
    if ! um_path_mounted "$BASE_PATH" 2>/dev/null; then
      if findmnt -n -S "$DATA_DEVICE" >/dev/null 2>&1; then
        :
      elif [[ "${UM_DRY_RUN}" == "1" ]]; then
        um_dry "Would mount DATA_DEVICE=${DATA_DEVICE} at ${BASE_PATH} (no format)"
      elif [[ -b "$DATA_DEVICE" ]]; then
        mkdir -p "$BASE_PATH"
        if ! mountpoint -q "$BASE_PATH" 2>/dev/null; then
          um_warn "DATA_DEVICE=${DATA_DEVICE} is set but not mounted; mount it manually before large downloads"
        fi
      fi
    fi
  fi

  um_bootstrap_run
}

main "$@"
