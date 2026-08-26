#!/usr/bin/env bash
# shellcheck shell=bash
# Config loading and derived paths for Ubuntu Mirror Server.

# shellcheck disable=SC2317
if [[ -n "${UM_CONFIG_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
UM_CONFIG_LOADED=1

# Defaults (overridden by mirror.conf). Exported for consumers after um_load_config.
# shellcheck disable=SC2034
{
MIRROR_HOSTNAME="_"
MIRROR_PORT="80"
MIRROR_URL=""
MIRROR_IP=""
BASE_PATH="/var/spool/apt-mirror"
DATA_DEVICE=""
DATA_FSTYPE="ext4"
DATA_MOUNT_OPTS="defaults,noatime"
DISK_WARN_PERCENT="80"
DISK_CRIT_PERCENT="90"
# Minimum free GiB warning for default (offline-upgrade-full) sync
MIN_FREE_GIB="350"
# Keep at least this percent of the filesystem free after sync
DISK_RESERVE_PERCENT="20"
# Projected apt-mirror footprint (GiB) used for pre-sync capacity checks
PROJECTED_SIZE_GIB_MINIMAL="320"
PROJECTED_SIZE_GIB_FULL="700"
UPSTREAM_MIRROR="http://archive.ubuntu.com/ubuntu"
DEFAULT_ARCH="amd64"
NTHREADS="20"
# Offline upgrade mirror default: selective (offline-upgrade-selective).
# full / minimal are rejected by um_resolve_mirror_mode.
MIRROR_MODE="selective"
UBUNTU_VERSIONS="xenial bionic focal jammy noble"
SUITE_SUFFIXES="updates security backports"
INCLUDE_SOURCE="false"
# Dedicated data-disk enforcement for offline mirror (override via defaults file)
ALLOW_ROOT_FS_MIRROR="false"
MIN_FREE_GB="50"
PUBLIC_BASE_URL=""
SYNC_RANDOMIZED_DELAY_SEC="900"
RUN_CLEAN="true"
NGINX_SITE_NAME="apt-mirror"
NGINX_LISTEN_IPV6="true"
NGINX_DEFAULT_SERVER="true"
NGINX_DISABLE_DEFAULT="true"
SYNC_ON_CALENDAR="*-*-* 02:00:00"
SYNC_PERSISTENT="true"
LOG_DIR="/var/log/ubuntu-mirror"
APT_MIRROR_LOG="/var/log/apt-mirror.log"
APT_MIRROR_INITIAL_LOG="/var/log/apt-mirror-initial.log"
NGINX_ACCESS_LOG="/var/log/nginx/apt-mirror-access.log"
NGINX_ERROR_LOG="/var/log/nginx/apt-mirror-error.log"
INSTALL_BIN_DIR="${INSTALL_BIN_DIR:-/usr/local/bin}"
INSTALL_LIB_DIR="${INSTALL_LIB_DIR:-/usr/local/lib/ubuntu-mirror}"
INSTALL_CONF_DIR="${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/ubuntu-mirror}"
HTTP_TIMEOUT_SEC="10"
HEALTH_HTTP_LATENCY_WARN_MS="500"
HEALTH_LOG_ERROR_WARN="20"
STALL_THRESHOLD_SEC="600"
WAITING_THRESHOLD_SEC="30"
ALLOW_FORMAT="false"
ALLOW_DELETE_MIRROR_DATA="false"
}

um_resolve_config_path() {
  local given="${1:-}"
  if [[ -n "$given" ]]; then
    if [[ -f "$given" ]]; then
      printf '%s\n' "$(cd "$(dirname "$given")" && pwd)/$(basename "$given")"
      return 0
    fi
    um_die "Config not found: $given"
  fi
  # Prefer installed config, then project root
  if [[ -f "${INSTALL_CONF_DIR}/mirror.conf" ]]; then
    printf '%s\n' "${INSTALL_CONF_DIR}/mirror.conf"
    return 0
  fi
  if [[ -f "${UM_PROJECT_ROOT}/mirror.conf" ]]; then
    printf '%s\n' "${UM_PROJECT_ROOT}/mirror.conf"
    return 0
  fi
  um_die "No mirror.conf found. Pass --config PATH"
}

um_load_config() {
  local path
  path="$(um_resolve_config_path "${1:-}")"
  # shellcheck disable=SC1090
  source "$path"
  UM_CONFIG_PATH="$path"

  # Derived paths
  MIRROR_PATH="${MIRROR_PATH:-$BASE_PATH/mirror}"
  SKEL_PATH="${SKEL_PATH:-$BASE_PATH/skel}"
  VAR_PATH="${VAR_PATH:-$BASE_PATH/var}"
  CLEAN_SCRIPT="${CLEAN_SCRIPT:-$VAR_PATH/clean.sh}"
  UBUNTU_MIRROR_ROOT="${UBUNTU_MIRROR_ROOT:-$MIRROR_PATH/archive.ubuntu.com/ubuntu}"
  DIST_ROOT="${DIST_ROOT:-$UBUNTU_MIRROR_ROOT/dists}"
  # Canonical selective tree (direct; no current/previous generation symlink)
  SELECTIVE_MIRROR_ROOT="${SELECTIVE_MIRROR_ROOT:-$BASE_PATH/selective}"
  SELECTIVE_NGINX_ROOT="${SELECTIVE_NGINX_ROOT:-$SELECTIVE_MIRROR_ROOT}"

  # Disk capacity defaults
  DISK_RESERVE_PERCENT="${DISK_RESERVE_PERCENT:-20}"
  PROJECTED_SIZE_GIB_MINIMAL="${PROJECTED_SIZE_GIB_MINIMAL:-320}"
  PROJECTED_SIZE_GIB_FULL="${PROJECTED_SIZE_GIB_FULL:-700}"
  MIN_FREE_GIB="${MIN_FREE_GIB:-350}"

  # DP Phase 2 (6.6.0) is immutable. Stale mirror.conf (e.g. 6.5.0) must not
  # restore a previous production target.
  DP_PHASE2_ENABLED="${DP_PHASE2_ENABLED:-true}"
  if [[ "${MM_ALLOW_TARGET_OVERRIDE:-0}" == "1" ]]; then
    DP_PHASE2_VERSION="${DP_PHASE2_VERSION:-6.6.0}"
  else
    DP_PHASE2_VERSION="6.6.0"
  fi
  DP_PHASE2_ROOT="${DP_PHASE2_ROOT:-${BASE_PATH}/dp-phase2}"
  DP_PHASE2_MIN_FREE_GIB="${DP_PHASE2_MIN_FREE_GIB:-70}"
  DP_PHASE2_PUBLIC_PATH="/dp-phase2/${DP_PHASE2_VERSION}/"
  DP_PHASE2_KEEP_PREVIOUS="${DP_PHASE2_KEEP_PREVIOUS:-true}"

  um_apply_mirror_mode_components

  if [[ -z "${MIRROR_IP}" ]]; then
    MIRROR_IP="$(um_detect_primary_ip || true)"
  fi
  if [[ -z "${MIRROR_URL}" && -n "${MIRROR_IP}" ]]; then
    if [[ "${MIRROR_PORT}" == "80" ]]; then
      MIRROR_URL="http://${MIRROR_IP}"
    else
      MIRROR_URL="http://${MIRROR_IP}:${MIRROR_PORT}"
    fi
  fi

  mkdir -p "${LOG_DIR}" 2>/dev/null || true
  # Stall detection defaults (seconds)
  STALL_THRESHOLD_SEC="${STALL_THRESHOLD_SEC:-600}"
  WAITING_THRESHOLD_SEC="${WAITING_THRESHOLD_SEC:-30}"
  if [[ "${UM_QUIET_LOAD:-0}" != "1" ]]; then
    um_info "Loaded config: $UM_CONFIG_PATH"
  fi
}

um_apply_mirror_mode_components() {
  case "${MIRROR_MODE}" in
    selective|SELECTIVE|offline-upgrade-selective|discovery_exact|"")
      MIRROR_MODE="selective"
      MIRROR_COMPONENTS="main restricted universe multiverse"
      ;;
    full|FULL|offline-upgrade-full)
      # Legacy label — rejected by um_resolve_mirror_mode / upgrade-profile.
      MIRROR_MODE="full"
      MIRROR_COMPONENTS="main restricted universe multiverse"
      ;;
    minimal|MINIMAL)
      MIRROR_MODE="minimal"
      MIRROR_COMPONENTS="main restricted"
      ;;
    *)
      um_die "Invalid MIRROR_MODE='$MIRROR_MODE' (supported: selective / offline-upgrade-selective)"
      ;;
  esac
}

# Resolve install/runtime mode.
# Supported: selective (offline-upgrade-selective). full apt-mirror and minimal are rejected.
um_resolve_mirror_mode() {
  local want_full="${1:-0}"
  local want_minimal="${2:-0}"
  if [[ -f "${UM_PROJECT_ROOT:-}/lib/upgrade-profile.sh" ]]; then
    # shellcheck source=lib/upgrade-profile.sh
    source "${UM_PROJECT_ROOT}/lib/upgrade-profile.sh"
  fi
  if [[ "$want_minimal" == "1" ]]; then
    um_reject_minimal_request "UNSUPPORTED_MINIMAL_PROFILE" 2>/dev/null || true
    um_die "UNSUPPORTED_MINIMAL_PROFILE: minimal mirrors are not supported" 2
  fi
  if [[ "$want_full" == "1" ]]; then
    um_reject_full_sync_request "UNSUPPORTED_FULL_MIRROR_SYNC" 2>/dev/null || true
    um_die "UNSUPPORTED_FULL_MIRROR_SYNC: use plan-selective / materialize-selective" 2
  fi
  case "${MIRROR_MODE}" in
    selective|SELECTIVE|offline-upgrade-selective|discovery_exact|"")
      MIRROR_MODE="selective"
      ;;
    full|FULL|offline-upgrade-full)
      um_reject_full_sync_request "UNSUPPORTED_FULL_MIRROR_SYNC" 2>/dev/null || true
      um_die "UNSUPPORTED_FULL_MIRROR_SYNC: MIRROR_MODE=full is not supported" 2
      ;;
    minimal|MINIMAL)
      um_reject_minimal_request "UNSUPPORTED_MINIMAL_PROFILE" 2>/dev/null || true
      um_die "UNSUPPORTED_MINIMAL_PROFILE: MIRROR_MODE=minimal is not supported" 2
      ;;
    *)
      MIRROR_MODE="selective"
      ;;
  esac
  um_apply_mirror_mode_components
  SUITE_SUFFIXES="updates security backports"
}

um_persist_mirror_mode_to_conf() {
  # Ensure installed mirror.conf matches the resolved mode / suites.
  local conf="${1:-${INSTALL_CONF_DIR}/mirror.conf}"
  [[ -f "$conf" ]] || return 0
  if grep -qE '^MIRROR_MODE=' "$conf" 2>/dev/null; then
    sed -i "s/^MIRROR_MODE=.*/MIRROR_MODE=\"${MIRROR_MODE}\"/" "$conf"
  else
    printf '\nMIRROR_MODE="%s"\n' "$MIRROR_MODE" >>"$conf"
  fi
  if grep -qE '^SUITE_SUFFIXES=' "$conf" 2>/dev/null; then
    sed -i "s/^SUITE_SUFFIXES=.*/SUITE_SUFFIXES=\"${SUITE_SUFFIXES}\"/" "$conf"
  else
    printf 'SUITE_SUFFIXES="%s"\n' "$SUITE_SUFFIXES" >>"$conf"
  fi
}

# Set or append KEY="value" in a conf file (preserves unrelated keys).
um_conf_set_key() {
  local conf="$1" key="$2" value="$3"
  local tmp
  [[ -f "$conf" ]] || return 1
  tmp="$(mktemp "${conf}.XXXXXX")"
  if grep -qE "^${key}=" "$conf" 2>/dev/null; then
    # shellcheck disable=SC2001
    sed "s|^${key}=.*|${key}=\"${value}\"|" "$conf" >"$tmp"
  else
    cat "$conf" >"$tmp"
    printf '\n%s="%s"\n' "$key" "$value" >>"$tmp"
  fi
  chmod --reference="$conf" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
  mv -f "$tmp" "$conf"
}

# Read-modify-write: add/correct selective fields; preserve operator values.
# Returns 0 always; prints "changed" or "unchanged" on stdout when UM_CONF_MIGRATE_VERBOSE=1.
um_migrate_selective_runtime_config() {
  local conf="${1:-${INSTALL_CONF_DIR}/mirror.conf}"
  local base_path sel_root seed_root mode projected
  local before after backup=""
  [[ -f "$conf" ]] || return 1

  # shellcheck disable=SC1090
  before="$(um_sha256_file "$conf" 2>/dev/null || true)"
  # Parse existing BASE_PATH without sourcing whole conf (avoids side effects).
  base_path="$(awk -F= '/^BASE_PATH=/ {gsub(/"/,"",$2); print $2; exit}' "$conf" 2>/dev/null || true)"
  base_path="${base_path:-${BASE_PATH:-/var/spool/apt-mirror}}"
  sel_root="$(awk -F= '/^SELECTIVE_MIRROR_ROOT=/ {gsub(/"/,"",$2); print $2; exit}' "$conf" 2>/dev/null || true)"
  sel_root="${sel_root:-${base_path}/selective}"
  seed_root="$(awk -F= '/^FULL_MIRROR_SEED_ROOT=/ {gsub(/"/,"",$2); print $2; exit}' "$conf" 2>/dev/null || true)"
  seed_root="${seed_root:-${base_path}/mirror/archive.ubuntu.com/ubuntu}"
  projected="$(awk -F= '/^PROJECTED_SIZE_GIB_SELECTIVE=/ {gsub(/"/,"",$2); print $2; exit}' "$conf" 2>/dev/null || true)"
  projected="${projected:-20}"
  mode="selective"

  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would migrate selective fields in $conf"
    return 0
  fi

  backup="$(um_backup_file "$conf" 2>/dev/null || true)"
  um_conf_set_key "$conf" "MIRROR_MODE" "$mode" || return 1
  um_conf_set_key "$conf" "SELECTIVE_MIRROR_ROOT" "$sel_root" || return 1
  um_conf_set_key "$conf" "SELECTIVE_NGINX_ROOT" "${sel_root}/current" || return 1
  um_conf_set_key "$conf" "FULL_MIRROR_SEED_ROOT" "$seed_root" || return 1
  um_conf_set_key "$conf" "PROJECTED_SIZE_GIB_SELECTIVE" "$projected" || return 1
  um_conf_set_key "$conf" "SUITE_SUFFIXES" "${SUITE_SUFFIXES:-updates security backports}" || return 1

  # Always pin production Phase 2 target; do not preserve stale 6.5.0.
  um_conf_set_key "$conf" "DP_PHASE2_VERSION" "6.6.0" || return 1
  um_conf_set_key "$conf" "DP_PHASE2_PUBLIC_PATH" "/dp-phase2/6.6.0/" || return 1
  if ! grep -qE '^DP_PHASE2_ENABLED=' "$conf" 2>/dev/null; then
    um_conf_set_key "$conf" "DP_PHASE2_ENABLED" "${DP_PHASE2_ENABLED:-true}" || return 1
  fi
  if ! grep -qE '^DP_PHASE2_ROOT=' "$conf" 2>/dev/null; then
    um_conf_set_key "$conf" "DP_PHASE2_ROOT" "${DP_PHASE2_ROOT:-${base_path}/dp-phase2}" || return 1
  fi
  if ! grep -qE '^DP_PHASE2_MIN_FREE_GIB=' "$conf" 2>/dev/null; then
    um_conf_set_key "$conf" "DP_PHASE2_MIN_FREE_GIB" "${DP_PHASE2_MIN_FREE_GIB:-70}" || return 1
  fi
  if ! grep -qE '^DP_PHASE2_KEEP_PREVIOUS=' "$conf" 2>/dev/null; then
    um_conf_set_key "$conf" "DP_PHASE2_KEEP_PREVIOUS" "${DP_PHASE2_KEEP_PREVIOUS:-true}" || return 1
  fi

  after="$(um_sha256_file "$conf" 2>/dev/null || true)"
  if [[ -n "$before" && "$before" == "$after" && -n "$backup" ]]; then
    # No content change — drop duplicate backup if identical
    :
  fi
  MIRROR_MODE="$mode"
  SELECTIVE_MIRROR_ROOT="$sel_root"
  SELECTIVE_NGINX_ROOT="${sel_root}/current"
  FULL_MIRROR_SEED_ROOT="$seed_root"
  return 0
}

# Canonical mirrorctl path policy: /usr/local/bin/mirrorctl (file),
# /usr/local/sbin/mirrorctl → symlink to canonical.
um_mirrorctl_canonical_path() {
  printf '%s\n' "${INSTALL_BIN_DIR:-/usr/local/bin}/mirrorctl"
}

um_mirrorctl_aux_path() {
  printf '%s\n' "${UM_MIRRORCTL_AUX_PATH:-/usr/local/sbin/mirrorctl}"
}

um_uom_install_path() {
  printf '%s\n' "${UM_UOM_INSTALL_PATH:-/usr/local/sbin/ubuntu-offline-mirror.sh}"
}

um_runtime_source_root() {
  # Prefer git checkout recorded at install, then caller UM_PROJECT_ROOT, then sibling of this lib.
  local repo
  if [[ -n "${UM_PROJECT_ROOT:-}" ]] && [[ -f "${UM_PROJECT_ROOT}/scripts/mirrorctl" ]]; then
    printf '%s\n' "$UM_PROJECT_ROOT"
    return 0
  fi
  if [[ -f "${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}/source-repo" ]]; then
    repo="$(tr -d '\r\n' <"${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}/source-repo" 2>/dev/null || true)"
    if [[ -n "$repo" ]] && [[ -f "${repo}/scripts/mirrorctl" ]]; then
      printf '%s\n' "$repo"
      return 0
    fi
  fi
  if [[ -f /usr/local/lib/ubuntu-mirror/config.sh ]]; then
    # Installed libs alone cannot provide scripts/; require checkout.
    :
  fi
  return 1
}

# Returns 0 if installed runtime differs from repository sources (drift).
um_has_runtime_drift() {
  local src_root canon aux conf svc
  local src_sum dst_sum
  src_root="$(um_runtime_source_root 2>/dev/null || true)"
  [[ -n "$src_root" ]] || return 0  # unknown source → treat as drift to force refresh path

  canon="$(um_mirrorctl_canonical_path)"
  if [[ ! -f "$canon" ]]; then
    return 0
  fi
  src_sum="$(um_sha256_file "${src_root}/scripts/mirrorctl")"
  dst_sum="$(um_sha256_file "$canon")"
  [[ "$src_sum" == "$dst_sum" ]] || return 0

  aux="$(um_mirrorctl_aux_path)"
  if [[ -e "$aux" ]]; then
    if [[ ! -L "$aux" ]]; then
      return 0
    fi
    if [[ "$(readlink -f "$aux" 2>/dev/null || true)" != "$(readlink -f "$canon" 2>/dev/null || true)" ]]; then
      return 0
    fi
  else
    return 0
  fi

  conf="${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}/mirror.conf"
  if [[ -f "$conf" ]]; then
    grep -qE '^MIRROR_MODE="?selective"?' "$conf" 2>/dev/null || return 0
    grep -qE '^SELECTIVE_MIRROR_ROOT=' "$conf" 2>/dev/null || return 0
  else
    return 0
  fi

  if [[ ! -f "${INSTALL_LIB_DIR:-/usr/local/lib/ubuntu-mirror}/upgrade-profile.sh" ]]; then
    return 0
  fi
  if [[ ! -f "${INSTALL_LIB_DIR:-/usr/local/lib/ubuntu-mirror}/selective_mirror.py" ]]; then
    return 0
  fi
  src_sum="$(um_sha256_file "${src_root}/lib/state.sh")"
  dst_sum="$(um_sha256_file "${INSTALL_LIB_DIR:-/usr/local/lib/ubuntu-mirror}/state.sh")"
  [[ "$src_sum" == "$dst_sum" ]] || return 0

  svc="${UM_SYSTEMD_DIR:-/etc/systemd/system}/apt-mirror.service"
  if [[ -f "$svc" ]]; then
    grep -q 'materialize-selective' "$svc" 2>/dev/null || return 0
  fi

  return 1  # no drift
}

# Atomic install helper with explicit rollback bookkeeping.
# UM_MIGRATE_ROLLBACK_STACK holds "dest|backup" pairs (newline-separated).
um_migrate_atomic_install() {
  local src="$1" dest="$2" mode="${3:-0644}"
  local tmp dir backup=""
  [[ -f "$src" ]] || return 1
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  if [[ -e "$dest" ]]; then
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
      um_info "Unchanged: $dest"
      return 0
    fi
    backup="$(um_backup_file "$dest" 2>/dev/null || true)"
  fi
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would install $src -> $dest (mode $mode)"
    return 0
  fi
  tmp="${dest}.tmp.$$"
  if ! cp "$src" "$tmp"; then
    um_error "Failed to stage $dest"
    rm -f "$tmp"
    return 1
  fi
  chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
  chown root:root "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$dest"; then
    um_error "Failed to atomically install $dest"
    rm -f "$tmp"
    return 1
  fi
  chown root:root "$dest" 2>/dev/null || true
  chmod "$mode" "$dest" || return 1
  if [[ -n "$backup" ]]; then
    UM_MIGRATE_ROLLBACK_STACK+="${dest}|${backup}"$'\n'
  fi
  um_ok "Installed: $dest"
}

um_migrate_rollback() {
  local line dest backup
  [[ -n "${UM_MIGRATE_ROLLBACK_STACK:-}" ]] || return 0
  um_warn "Rolling back selective runtime migration..."
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    dest="${line%%|*}"
    backup="${line#*|}"
    if [[ -n "$dest" && -n "$backup" && -e "$backup" ]]; then
      cp -a "$backup" "$dest"
      um_ok "Restored: $dest"
    fi
  done < <(printf '%s' "$UM_MIGRATE_ROLLBACK_STACK" | tac 2>/dev/null || printf '%s' "$UM_MIGRATE_ROLLBACK_STACK")
}

# Idempotent non-destructive runtime migration:
# updates installed mirrorctl/libs/config/systemd unit only.
# Never touches selective staging/published/READY/current.
um_migrate_selective_runtime() {
  local src_root canon aux conf libdir bindir confdir systemd_dir
  local result_json rc=0
  local src_sum dst_sum

  src_root="${1:-$(um_runtime_source_root 2>/dev/null || true)}"
  [[ -n "$src_root" ]] || {
    um_error "Cannot locate repository source root (scripts/mirrorctl)"
    return 1
  }
  [[ -f "${src_root}/scripts/mirrorctl" ]] || {
    um_error "mirrorctl missing in source: ${src_root}/scripts/mirrorctl"
    return 1
  }
  bash -n "${src_root}/scripts/mirrorctl" || {
    um_error "mirrorctl syntax check failed"
    return 1
  }

  # Honour caller/env overrides (tests use a fake install root).
  bindir="${INSTALL_BIN_DIR:-/usr/local/bin}"
  libdir="${INSTALL_LIB_DIR:-/usr/local/lib/ubuntu-mirror}"
  confdir="${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}"
  systemd_dir="${UM_SYSTEMD_DIR:-/etc/systemd/system}"
  [[ -n "${BACKUP_DIR:-}" ]] || BACKUP_DIR="/var/backups/ubuntu-mirror"
  canon="${bindir}/mirrorctl"
  aux="$(um_mirrorctl_aux_path)"
  conf="${confdir}/mirror.conf"
  result_json="${BASE_PATH:-/var/spool/apt-mirror}/selective/state/runtime-migration.json"
  # Allow test roots to redirect result json
  if [[ -n "${UM_MIGRATE_RESULT_JSON:-}" ]]; then
    result_json="$UM_MIGRATE_RESULT_JSON"
  fi

  UM_MIGRATE_ROLLBACK_STACK=""
  um_ok "Source root: $src_root"
  um_ok "Canonical mirrorctl: $canon"

  # Preflight checksums
  src_sum="$(um_sha256_file "${src_root}/scripts/mirrorctl")"
  dst_sum="$(um_sha256_file "$canon" 2>/dev/null || true)"
  um_info "repo mirrorctl sha256: $src_sum"
  um_info "installed mirrorctl sha256: ${dst_sum:-missing}"

  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would migrate selective runtime from $src_root"
    um_has_runtime_drift && um_dry "Drift detected" || um_dry "No drift (idempotent no-op likely)"
    return 0
  fi

  # Install tools / libs (atomic + rollback bookkeeping)
  um_migrate_atomic_install "${src_root}/scripts/mirrorctl" "$canon" 0755 || rc=1
  um_migrate_atomic_install "${src_root}/scripts/mirror-dashboard.sh" "${bindir}/mirror-dashboard" 0755 || rc=1
  local uom_dest
  uom_dest="$(um_uom_install_path)"
  mkdir -p "$(dirname "$uom_dest")"
  um_migrate_atomic_install "${src_root}/scripts/ubuntu-offline-mirror.sh" "$uom_dest" 0755 || rc=1
  if [[ "${UM_DRY_RUN:-0}" != "1" ]]; then
    ln -sfn "$uom_dest" "${bindir}/ubuntu-offline-mirror" 2>/dev/null || true
  fi

  local f
  for f in common.sh config.sh state.sh progress.sh install-menu.sh offline.sh upgrade-profile.sh; do
    if [[ -f "${src_root}/lib/${f}" ]]; then
      um_migrate_atomic_install "${src_root}/lib/${f}" "${libdir}/${f}" 0644 || rc=1
    fi
  done
  for f in selective_mirror.py validate_selective_mirror.py validate_upgrade_profile.py \
           derive_upgrade_requirements.py sync_by_hash.py validate_security_compat.py \
           sync_release_upgraders.py validate_release_upgraders.py \
           sync_legacy_releases.py validate_legacy_releases.py; do
    if [[ -f "${src_root}/scripts/lib/${f}" ]]; then
      um_migrate_atomic_install "${src_root}/scripts/lib/${f}" "${libdir}/${f}" 0644 || rc=1
    fi
  done
  if [[ -f "${src_root}/scripts/lib/dp-phase2-common.sh" ]]; then
    mkdir -p "${libdir}/lib"
    um_migrate_atomic_install "${src_root}/scripts/lib/dp-phase2-common.sh" \
      "${libdir}/lib/dp-phase2-common.sh" 0644 || rc=1
  fi
  if [[ -f "${src_root}/scripts/download-dp-phase2-6.6.0.sh" ]]; then
    um_migrate_atomic_install "${src_root}/scripts/download-dp-phase2-6.6.0.sh" \
      "${libdir}/download-dp-phase2-6.6.0.sh" 0755 || rc=1
  fi
  if [[ -f "${src_root}/scripts/download-dp-phase2-6.5.0.sh" ]]; then
    um_migrate_atomic_install "${src_root}/scripts/download-dp-phase2-6.5.0.sh" \
      "${libdir}/download-dp-phase2-6.5.0.sh" 0755 || rc=1
  fi
  if [[ -f "${src_root}/scripts/deploy-stage-dp-phase2-client-atomic.sh" ]]; then
    um_migrate_atomic_install "${src_root}/scripts/deploy-stage-dp-phase2-client-atomic.sh" \
      "${libdir}/deploy-stage-dp-phase2-client-atomic.sh" 0755 || rc=1
  fi
  if [[ -f "${src_root}/scripts/build-selective-mirror-plan.py" ]]; then
    um_migrate_atomic_install "${src_root}/scripts/build-selective-mirror-plan.py" \
      "${libdir}/build-selective-mirror-plan.py" 0644 || rc=1
  fi
  if [[ -f "${src_root}/config/offline-upgrade-profile.json" ]]; then
    mkdir -p "$confdir"
    um_migrate_atomic_install "${src_root}/config/offline-upgrade-profile.json" \
      "${confdir}/offline-upgrade-profile.json" 0644 || rc=1
    um_migrate_atomic_install "${src_root}/config/offline-upgrade-profile.json" \
      "${libdir}/offline-upgrade-profile.json" 0644 || rc=1
  fi
  if [[ -f "${src_root}/config/offline-upgrade-exceptions.json" ]]; then
    um_migrate_atomic_install "${src_root}/config/offline-upgrade-exceptions.json" \
      "${confdir}/offline-upgrade-exceptions.json" 0644 || rc=1
  fi

  # Normalize symlink: sbin -> bin canonical
  if [[ "${UM_DRY_RUN:-0}" != "1" ]]; then
    if [[ -e "$aux" && ! -L "$aux" ]]; then
      um_backup_file "$aux" >/dev/null || true
      rm -f "$aux"
    fi
    mkdir -p "$(dirname "$aux")"
    ln -sfn "$canon" "$aux"
    um_ok "Symlink: $aux -> $canon"
  fi

  # Config merge (preserve operator values)
  if [[ -f "$conf" ]]; then
    if ! um_migrate_selective_runtime_config "$conf"; then
      rc=1
    else
      um_ok "Config selective fields migrated: $conf"
    fi
  else
    um_warn "No runtime config at $conf — installing from source mirror.conf"
    um_migrate_atomic_install "${src_root}/mirror.conf" "$conf" 0644 || rc=1
    um_migrate_selective_runtime_config "$conf" || true
  fi

  # systemd unit content only (no start / no timer enable)
  mkdir -p "$systemd_dir"
  local svc_tmp
  svc_tmp="$(mktemp)"
  um_generate_systemd_service >"$svc_tmp"
  if [[ -f "${systemd_dir}/apt-mirror.service" ]] && cmp -s "$svc_tmp" "${systemd_dir}/apt-mirror.service"; then
    um_info "Unchanged: ${systemd_dir}/apt-mirror.service"
    rm -f "$svc_tmp"
  else
    um_migrate_atomic_install "$svc_tmp" "${systemd_dir}/apt-mirror.service" 0644 || rc=1
    rm -f "$svc_tmp"
  fi

  # Verify installed mirrorctl checksum
  dst_sum="$(um_sha256_file "$canon" 2>/dev/null || true)"
  if [[ "$dst_sum" != "$src_sum" ]]; then
    um_error "Post-install checksum mismatch for mirrorctl"
    rc=1
  fi

  # Read-only status smoke (does not mutate selective state)
  if [[ "$rc" -eq 0 ]] && [[ -x "$canon" ]]; then
    if ! bash -n "$canon"; then
      um_error "Installed mirrorctl failed bash -n"
      rc=1
    fi
  fi

  if [[ "$rc" -ne 0 ]]; then
    um_migrate_rollback
    um_error "migrate-selective-runtime FAILED (rollback applied)"
    return 1
  fi

  mkdir -p "$(dirname "$result_json")" 2>/dev/null || true
  cat >"$result_json" <<EOF
{
  "migration": "selective-runtime",
  "result": "PASS",
  "source_root": "$(printf '%s' "$src_root" | sed 's/"/\\"/g')",
  "canonical_mirrorctl": "$canon",
  "mirrorctl_sha256": "$dst_sum",
  "config": "$conf",
  "generated_at": "$(date -Is)",
  "destructive_ops": false,
  "selective_state_touched": false
}
EOF
  um_ok "migrate-selective-runtime PASS (mirrorctl=${dst_sum:0:12}…)"
  um_ok "Result: $result_json"
  # Record source-repo for future watch/dashboard preference
  mkdir -p "$confdir"
  printf '%s\n' "$src_root" >"${confdir}/source-repo"
  return 0
}

um_upstream_host_path() {
  # From http://archive.ubuntu.com/ubuntu -> archive.ubuntu.com/ubuntu
  local url="${UPSTREAM_MIRROR}"
  url="${url#http://}"
  url="${url#https://}"
  url="${url%/}"
  printf '%s\n' "$url"
}

um_components_for_mode() {
  printf '%s\n' "$MIRROR_COMPONENTS"
}

um_generate_mirror_list() {
  # Print apt-mirror mirror.list content to stdout
  local components host_path suite ver suffix
  components="$(um_components_for_mode)"
  host_path="$(um_upstream_host_path)"

  cat <<EOF
############# config ##################
set base_path    ${BASE_PATH}
set mirror_path  \$base_path/mirror
set skel_path    \$base_path/skel
set var_path     \$base_path/var
set cleanscript  \$var_path/clean.sh
set defaultarch  ${DEFAULT_ARCH}
set nthreads     ${NTHREADS}
set _tilde 0
############# end config ##############

# Offline LTS upgrade chain (amd64 only)
# INCLUDED: official Ubuntu amd64 packages (main/restricted/universe/multiverse),
#           kernels, headers, and dependencies for release upgrades.
# EXCLUDED: i386, deb-src, Ubuntu Pro/ESM, PPAs, Docker CE, NVIDIA/CUDA,
#           Snap packages, vendor/private APT repositories.

EOF

  for ver in ${UBUNTU_VERSIONS}; do
    cat <<EOF
# Ubuntu ${ver}
deb ${UPSTREAM_MIRROR} ${ver} ${components}
EOF
    for suffix in ${SUITE_SUFFIXES}; do
      [[ -n "$suffix" ]] || continue
      suite="${ver}-${suffix}"
      cat <<EOF
deb ${UPSTREAM_MIRROR} ${suite} ${components}
EOF
    done
    if [[ "${INCLUDE_SOURCE}" == "true" ]]; then
      cat <<EOF
deb-src ${UPSTREAM_MIRROR} ${ver} ${components}
EOF
      for suffix in ${SUITE_SUFFIXES}; do
        [[ -n "$suffix" ]] || continue
        suite="${ver}-${suffix}"
        cat <<EOF
deb-src ${UPSTREAM_MIRROR} ${suite} ${components}
EOF
      done
    fi
    printf '\n'
  done

  # clean directive uses the host/path form expected by apt-mirror
  printf 'clean http://%s\n' "$host_path"
}

um_nginx_template_path() {
  local candidates=(
    "${UM_PROJECT_ROOT:-}/templates/nginx.conf"
    "${INSTALL_LIB_DIR:-/usr/local/lib/ubuntu-mirror}/templates/nginx.conf"
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/templates/nginx.conf"
  )
  local p
  for p in "${candidates[@]}"; do
    [[ -n "$p" && -f "$p" ]] || continue
    printf '%s\n' "$p"
    return 0
  done
  return 1
}

um_selective_nginx_root() {
  # Single materialized selective tree (no current → published symlink).
  printf '%s\n' "${SELECTIVE_NGINX_ROOT:-${SELECTIVE_MIRROR_ROOT:-${BASE_PATH}/selective}}"
}

# Generate selective nginx site from templates/nginx.conf (SSOT).
# Canonical document root: SELECTIVE_MIRROR_ROOT (direct; no current/previous)
um_generate_nginx_conf() {
  local tpl=""
  local sel_root="${SELECTIVE_MIRROR_ROOT:-${BASE_PATH}/selective}"
  local sel_current
  sel_current="$(um_selective_nginx_root)"
  local listen_extra=""
  local default_flag=""
  local server_name="${MIRROR_HOSTNAME:-_}"
  local rendered

  if [[ "${NGINX_DEFAULT_SERVER}" == "true" ]]; then
    default_flag=" default_server"
  fi
  if [[ "${NGINX_LISTEN_IPV6}" == "true" ]]; then
    listen_extra="    listen [::]:${MIRROR_PORT}${default_flag};"
  fi

  local dp2_root="${DP_PHASE2_ROOT:-${BASE_PATH}/dp-phase2}"
  local dp2_ver="${DP_PHASE2_VERSION:-6.6.0}"
  local dp2_final="${dp2_root}/${dp2_ver}"

  if tpl="$(um_nginx_template_path)"; then
    rendered="$(sed \
      -e "s|/var/spool/apt-mirror/selective|${sel_root}|g" \
      -e "s|/var/spool/apt-mirror/client|${BASE_PATH}/client|g" \
      -e "s|/var/spool/apt-mirror/dp-phase2/6.6.0|${dp2_final}|g" \
      -e "s|/var/spool/apt-mirror/dp-phase2|${dp2_root}|g" \
      -e "s|listen 80 default_server;|listen ${MIRROR_PORT}${default_flag};|g" \
      -e "s|listen \\[::\\]:80 default_server;|listen [::]:${MIRROR_PORT}${default_flag};|g" \
      -e "s|listen 80;|listen ${MIRROR_PORT};|g" \
      -e "s|listen \\[::\\]:80;|listen [::]:${MIRROR_PORT};|g" \
      -e "s|server_name _;|server_name ${server_name};|g" \
      -e "s|/var/log/nginx/apt-mirror-access.log|${NGINX_ACCESS_LOG}|g" \
      -e "s|/var/log/nginx/apt-mirror-error.log|${NGINX_ERROR_LOG}|g" \
      "$tpl")"
    if [[ "${NGINX_LISTEN_IPV6}" != "true" ]]; then
      rendered="$(printf '%s\n' "$rendered" | sed -e '/listen \[::\]/d')"
    fi
    printf '%s\n' "$rendered"
    return 0
  fi

  # Fallback when template is unavailable (should not happen in normal installs)
  cat <<EOF
# Managed by ubuntu-mirror-server — selective offline upgrade mirror
server {
    listen ${MIRROR_PORT}${default_flag};
${listen_extra}

    server_name ${server_name};

    root ${sel_current};
    autoindex on;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /hops/ {
        alias ${sel_current}/hops/;
        autoindex on;
    }

    location = /ubuntu {
        return 301 /ubuntu/;
    }
    location /ubuntu/ {
        alias ${sel_current}/ubuntu/;
        autoindex on;
    }

    location = /ubuntu-security {
        return 301 /ubuntu-security/;
    }
    location /ubuntu-security/ {
        alias ${sel_current}/ubuntu/;
        autoindex on;
    }

    location = /offline {
        return 301 /offline/;
    }
    location /offline/ {
        alias ${sel_current}/shared/offline/;
        autoindex off;
        default_type text/plain;
    }

    location = /keys/ubuntu-mirror-selective.gpg {
        alias ${sel_root}/keys/ubuntu-mirror-selective.gpg;
        default_type application/pgp-keys;
    }

    location = /client {
        return 301 /client/;
    }
    location /client/ {
        alias ${BASE_PATH}/client/;
        autoindex on;
        default_type text/plain;
    }

    location = /dp-phase2 {
        return 301 /dp-phase2/;
    }
    location = /dp-phase2/ {
        return 301 /dp-phase2/${dp2_ver}/;
    }
    location = /dp-phase2/${dp2_ver} {
        return 301 /dp-phase2/${dp2_ver}/;
    }
    location /dp-phase2/${dp2_ver}/ {
        alias ${dp2_final}/;
        autoindex on;
        default_type application/octet-stream;
    }

    location ~ /\\.\\. {
        return 403;
    }

    access_log ${NGINX_ACCESS_LOG};
    error_log ${NGINX_ERROR_LOG};
}
EOF
}

# Idempotent migration of the managed apt-mirror site to selective canonical root.
# Preserves site name + port 80; does not touch other nginx sites.
# On nginx -t failure, restores the previous sites-available file.
um_migrate_nginx_selective_site() {
  local site_avail="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
  local site_en="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
  local expected_root
  expected_root="$(um_selective_nginx_root)"
  local ngx_tmp backup="" stamp site_new
  local changed=0

  ngx_tmp="$(mktemp)"
  um_generate_nginx_conf >"$ngx_tmp"

  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would migrate nginx site ${site_avail} → root ${expected_root}"
    rm -f "$ngx_tmp"
    return 0
  fi

  stamp="$(date +%Y%m%d%H%M%S)"
  if [[ -f "$site_avail" ]] && cmp -s "$ngx_tmp" "$site_avail"; then
    um_ok "nginx site already selective-canonical: $site_avail"
  else
    if [[ -f "$site_avail" ]]; then
      backup="${site_avail}.bak.${stamp}"
      cp -a "$site_avail" "$backup"
      um_ok "nginx backup: $backup"
    fi
    # Atomic replace in the same directory as sites-available
    site_new="${site_avail}.new.${stamp}"
    cp "$ngx_tmp" "$site_new"
    chmod 0644 "$site_new"
    mv -f "$site_new" "$site_avail"
    changed=1
    um_ok "Installed selective nginx site: $site_avail (root ${expected_root})"
  fi

  ln -sfn "$site_avail" "$site_en"
  if [[ ! -L "$site_en" ]] || [[ "$(readlink -f "$site_en")" != "$(readlink -f "$site_avail")" ]]; then
    rm -f "$ngx_tmp"
    um_error "sites-enabled link failed: $site_en"
    return 1
  fi
  um_ok "sites-enabled: $site_en -> $(readlink -f "$site_en")"

  if [[ "${NGINX_DISABLE_DEFAULT}" == "true" ]] && [[ -e /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
    um_ok "Disabled nginx default site"
    changed=1
  fi

  if ! command -v nginx >/dev/null 2>&1; then
    rm -f "$ngx_tmp"
    um_error "nginx binary not found"
    return 1
  fi

  if ! nginx -t; then
    um_error "nginx -t failed after selective site update"
    if [[ -n "$backup" && -f "$backup" ]]; then
      cp -a "$backup" "$site_avail"
      um_warn "Restored previous nginx site from $backup"
      nginx -t >/dev/null 2>&1 || true
    fi
    rm -f "$ngx_tmp"
    return 1
  fi
  um_ok "nginx -t passed (selective root ${expected_root})"

  if [[ "$changed" -eq 1 ]]; then
    if systemctl is-active --quiet nginx 2>/dev/null; then
      systemctl reload nginx
      um_ok "nginx reloaded"
    else
      um_warn "nginx not active — config migrated; start nginx before publish-selective"
    fi
  fi

  rm -f "$ngx_tmp"
  return 0
}

um_generate_systemd_service() {
  # SSOT aligned with templates/apt-mirror.service (selective materialize).
  cat <<EOF
[Unit]
Description=Ubuntu Selective Offline Mirror Materialize Service
After=network-online.target
Wants=network-online.target
Conflicts=apt-mirror-full.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ubuntu-offline-mirror.sh materialize-selective
StandardOutput=journal
StandardError=journal
User=root
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=infinity
KillMode=control-group
SendSIGKILL=no

[Install]
WantedBy=multi-user.target
EOF
}

um_generate_systemd_timer() {
  local persistent_line=""
  local delay="${SYNC_RANDOMIZED_DELAY_SEC:-900}"
  if [[ "${SYNC_PERSISTENT}" == "true" ]]; then
    persistent_line="Persistent=true"
  else
    persistent_line="Persistent=false"
  fi
  cat <<EOF
[Unit]
Description=Daily Ubuntu Offline Mirror Sync

[Timer]
OnCalendar=${SYNC_ON_CALENDAR}
${persistent_line}
RandomizedDelaySec=${delay}
Unit=apt-mirror.service

[Install]
WantedBy=timers.target
EOF
}
