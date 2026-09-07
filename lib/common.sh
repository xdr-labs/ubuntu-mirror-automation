#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for Ubuntu Mirror Server automation.
# Sourced by install/validate/mirrorctl/client scripts.

# Prevent double-source
# shellcheck disable=SC2317
if [[ -n "${UM_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
UM_COMMON_LOADED=1

set -o errexit
set -o nounset
set -o pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
um_script_dir() {
  local src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  cd "$(dirname "$src")" && pwd
}

UM_PROJECT_ROOT="${UM_PROJECT_ROOT:-}"
if [[ -z "$UM_PROJECT_ROOT" ]]; then
  # Prefer caller location: .../ubuntu-mirror-server/<script>
  _um_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  UM_PROJECT_ROOT="$_um_here"
  unset _um_here
fi

UM_LIB_DIR="${UM_LIB_DIR:-$UM_PROJECT_ROOT/lib}"
UM_TEMPLATE_DIR="${UM_TEMPLATE_DIR:-$UM_PROJECT_ROOT/templates}"

# ---------------------------------------------------------------------------
# Colors / output
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-0}" != "1" ]]; then
  UM_C_RED=$'\033[0;31m'
  UM_C_GREEN=$'\033[0;32m'
  UM_C_YELLOW=$'\033[0;33m'
  UM_C_BLUE=$'\033[0;34m'
  UM_C_BOLD=$'\033[1m'
  UM_C_RESET=$'\033[0m'
else
  UM_C_RED="" UM_C_GREEN="" UM_C_YELLOW="" UM_C_BLUE="" UM_C_BOLD="" UM_C_RESET=""
fi

um_ts() { date '+%Y-%m-%d %H:%M:%S'; }
um_date_tag() { date '+%Y%m%d'; }
um_datetime_tag() { date '+%Y%m%d-%H%M%S'; }

um_log_file="${UM_LOG_FILE:-}"

um_set_log_file() {
  um_log_file="$1"
  export um_log_file
}

um_ensure_log_dir() {
  local dir
  dir="$(dirname "${um_log_file:-/var/log/ubuntu-mirror/install.log}")"
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" 2>/dev/null || true
  fi
  # Fall back to a private log directory if the system log dir is not writable.
  # Avoid the shared predictable path /tmp/ubuntu-mirror-logs.
  if [[ -n "${um_log_file:-}" ]] && [[ ! -w "$dir" ]]; then
    local base fallback_dir
    base="$(basename "$um_log_file")"
    if [[ "$(id -u)" -eq 0 ]]; then
      fallback_dir="/run/ubuntu-mirror-logs"
      mkdir -p "$fallback_dir" 2>/dev/null || true
      chmod 0700 "$fallback_dir" 2>/dev/null || true
    else
      fallback_dir="$(mktemp -d "${TMPDIR:-/tmp}/ubuntu-mirror-logs.XXXXXX" 2>/dev/null || true)"
      if [[ -n "$fallback_dir" ]]; then
        chmod 0700 "$fallback_dir" 2>/dev/null || true
      fi
    fi
    if [[ -n "${fallback_dir:-}" && -d "$fallback_dir" ]]; then
      um_log_file="${fallback_dir}/${base}"
    fi
  fi
}

um_log() {
  local level="$1"
  shift
  local msg="$*"
  local line
  line="$(um_ts) [$level] $msg"
  case "$level" in
    ERROR) printf '%s%s%s\n' "$UM_C_RED" "$line" "$UM_C_RESET" >&2 ;;
    WARN)  printf '%s%s%s\n' "$UM_C_YELLOW" "$line" "$UM_C_RESET" >&2 ;;
    INFO)  printf '%s%s%s\n' "$UM_C_BLUE" "$line" "$UM_C_RESET" ;;
    OK)    printf '%s%s%s\n' "$UM_C_GREEN" "$line" "$UM_C_RESET" ;;
    *)     printf '%s\n' "$line" ;;
  esac
  if [[ -n "${um_log_file:-}" ]] && [[ "${UM_DRY_RUN:-0}" != "1" ]]; then
    um_ensure_log_dir
    if [[ -d "$(dirname "$um_log_file")" ]]; then
      printf '%s\n' "$line" >>"$um_log_file" 2>/dev/null || true
    fi
  fi
}

um_info()  { um_log INFO "$*"; }
um_ok()    { um_log OK "$*"; }
um_warn()  { um_log WARN "$*"; }
um_error() { um_log ERROR "$*"; }

um_die() {
  um_error "$*"
  exit "${2:-1}"
}

# ---------------------------------------------------------------------------
# Privileges / dry-run
# ---------------------------------------------------------------------------
um_is_root() { [[ "$(id -u)" -eq 0 ]]; }

um_require_root() {
  if ! um_is_root; then
    um_die "This operation requires root. Re-run with sudo." 2
  fi
}

um_run() {
  # Execute a command, or print it in dry-run mode.
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    printf '[DRY-RUN] Would run: %s\n' "$*"
    return 0
  fi
  "$@"
}

um_dry() {
  printf '[DRY-RUN] %s\n' "$*"
}

um_run_shell() {
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_info "DRY-RUN: $*"
    return 0
  fi
  bash -c "$*"
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
um_backup_session_dir() {
  # Session backup root: /var/backups/ubuntu-mirror/<timestamp>/
  if [[ -n "${UM_BACKUP_SESSION:-}" ]]; then
    printf '%s\n' "$UM_BACKUP_SESSION"
    return
  fi
  UM_BACKUP_SESSION="${BACKUP_DIR:-/var/backups/ubuntu-mirror}/$(um_datetime_tag)"
  printf '%s\n' "$UM_BACKUP_SESSION"
}

um_backup_file() {
  # Usage: um_backup_file <path> [backup_dir]
  # Only call when content will change. Stores under session timestamp dir.
  local path="$1"
  local bdir="${2:-}"
  local base dest

  if [[ ! -e "$path" ]]; then
    return 0
  fi
  if [[ -z "$bdir" ]]; then
    bdir="$(um_backup_session_dir)"
  fi
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    printf '[DRY-RUN] Would backup %s -> %s/\n' "$path" "$bdir"
    return 0
  fi

  mkdir -p "$bdir"
  base="$(basename "$path")"
  dest="$bdir/${base}"
  if [[ -e "$dest" ]]; then
    dest="$bdir/${base}.$(um_datetime_tag)"
  fi
  cp -a "$path" "$dest"
  um_ok "Backup created: $dest"
  printf '%s\n' "$dest"
}

# ---------------------------------------------------------------------------
# Atomic install of files
# ---------------------------------------------------------------------------
um_install_file() {
  # um_install_file <src> <dest> [mode]
  local src="$1"
  local dest="$2"
  local mode="${3:-0644}"
  local tmp dir

  if [[ ! -f "$src" ]]; then
    um_die "Template/source missing: $src"
  fi

  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    um_info "Unchanged: $dest"
    return 0
  fi

  if [[ -e "$dest" ]]; then
    um_backup_file "$dest" >/dev/null || true
  fi

  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would install $src -> $dest (mode $mode)"
    return 0
  fi

  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  tmp="${dest}.tmp.$$"
  cp "$src" "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dest"
  um_ok "Installed: $dest"
}

um_write_file() {
  # um_write_file <dest> <mode> <<EOF ... EOF  (via stdin)
  local dest="$1"
  local mode="${2:-0644}"
  local tmp dir content

  content="$(cat)"
  if [[ -f "$dest" ]]; then
    if printf '%s' "$content" | cmp -s - "$dest"; then
      um_info "Unchanged: $dest"
      return 0
    fi
    um_backup_file "$dest" >/dev/null || true
  fi

  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_info "DRY-RUN: write $dest (mode $mode)"
    return 0
  fi

  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  tmp="${dest}.tmp.$$"
  printf '%s' "$content" >"$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dest"
  um_ok "Wrote: $dest"
}

# ---------------------------------------------------------------------------
# Detection helpers
# ---------------------------------------------------------------------------
# Authoritative Mirror Host IPv4. Delegates to scripts/lib/mirror_host_ip.sh so
# build, deploy and GUI paths all agree on one address. Fails closed: callers
# get an empty value and non-zero status rather than a loopback placeholder that
# would be baked into client artifacts.
um_detect_primary_ip() {
  local candidate ip=""
  if ! declare -F mirror_host_resolve_ipv4 >/dev/null 2>&1; then
    for candidate in \
      "${UM_PROJECT_ROOT:-}/scripts/lib/mirror_host_ip.sh" \
      "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/scripts/lib/mirror_host_ip.sh"
    do
      [[ -n "$candidate" && -f "$candidate" ]] || continue
      # shellcheck source=/dev/null
      source "$candidate"
      break
    done
  fi
  if ! declare -F mirror_host_resolve_ipv4 >/dev/null 2>&1; then
    um_error "MIRROR_IP_RESOLUTION_RESULT=FAIL mirror_host_ip.sh not found"
    return 1
  fi
  ip="$(mirror_host_resolve_ipv4)" || return 1
  [[ -n "$ip" ]] || return 1
  printf '%s\n' "$ip"
}

um_command_exists() { command -v "$1" >/dev/null 2>&1; }

um_sha256_file() {
  # um_sha256_file <path> → hex digest or empty
  local path="${1:-}"
  [[ -n "$path" && -f "$path" ]] || { printf '\n'; return 1; }
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" 2>/dev/null | awk '{print $1}'
  else
    openssl dgst -sha256 "$path" 2>/dev/null | awk '{print $NF}'
  fi
}

um_path_mounted() {
  local path="$1"
  findmnt -n -T "$path" >/dev/null 2>&1
}

um_disk_usage_percent() {
  local path="$1"
  df -P "$path" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

um_df_total_kib() {
  local path="${1:-.}" out
  out="$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $2+0}')" || true
  printf '%s\n' "${out:-0}"
}

um_df_avail_kib() {
  local path="${1:-.}" out
  out="$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4+0}')" || true
  printf '%s\n' "${out:-0}"
}

# ---------------------------------------------------------------------------
# Mirror capacity / projected download size
# ---------------------------------------------------------------------------
# apt-mirror has no dry-run; we use documented archive size estimates and
# subtract whatever is already present under BASE_PATH.

um_projected_mirror_gib() {
  local mode="${1:-${MIRROR_MODE:-selective}}"
  case "$mode" in
    selective|SELECTIVE|offline-upgrade-selective|discovery_exact)
      printf '%s\n' "${PROJECTED_SIZE_GIB_SELECTIVE:-20}"
      ;;
    full|FULL|offline-upgrade-full)
      printf '%s\n' "${PROJECTED_SIZE_GIB_FULL:-900}"
      ;;
    minimal|MINIMAL)
      printf '%s\n' "${PROJECTED_SIZE_GIB_MINIMAL:-320}"
      ;;
    *)
      printf '%s\n' "${PROJECTED_SIZE_GIB_SELECTIVE:-20}"
      ;;
  esac
}

um_existing_mirror_gib() {
  local root="${1:-${BASE_PATH:-/var/spool/apt-mirror}}"
  local bytes=0
  if [[ -d "$root" ]]; then
    bytes="$(du -sb "$root" 2>/dev/null | awk '{print $1+0}')" || bytes=0
  fi
  # GiB, integer
  printf '%s\n' "$(( ${bytes:-0} / 1024 / 1024 / 1024 ))"
}

um_remaining_download_gib() {
  local projected existing remaining
  projected="$(um_projected_mirror_gib "${1:-${MIRROR_MODE:-full}}")"
  existing="$(um_existing_mirror_gib "${2:-${BASE_PATH:-/var/spool/apt-mirror}}")"
  remaining=$((projected - existing))
  if [[ "$remaining" -lt 0 ]]; then remaining=0; fi
  printf '%s\n' "$remaining"
}

um_disk_reserve_gib() {
  # Reserve at least DISK_RESERVE_PERCENT of total filesystem (default 20%).
  local path="${1:-${BASE_PATH:-/}}"
  local pct total_kib reserve_kib
  pct="${DISK_RESERVE_PERCENT:-20}"
  total_kib="$(um_df_total_kib "$path")"
  reserve_kib=$(( total_kib * pct / 100 ))
  printf '%s\n' "$(( reserve_kib / 1024 / 1024 ))"
}

# Print a human capacity report; return 0 if sync is allowed, 1 if blocked.
um_check_sync_capacity() {
  local path="${1:-${BASE_PATH:-/var/spool/apt-mirror}}"
  local mode="${2:-${MIRROR_MODE:-full}}"
  local total_kib avail_kib total_gib avail_gib
  local projected remaining reserve usable
  local reserve_pct="${DISK_RESERVE_PERCENT:-20}"

  if [[ ! -d "$path" ]]; then
    mkdir -p "$path" 2>/dev/null || true
  fi
  if [[ ! -d "$path" ]]; then
    um_error "Cannot evaluate disk capacity: $path missing"
    return 1
  fi

  total_kib="$(um_df_total_kib "$path")"
  avail_kib="$(um_df_avail_kib "$path")"
  total_gib=$(( total_kib / 1024 / 1024 ))
  avail_gib=$(( avail_kib / 1024 / 1024 ))
  projected="$(um_projected_mirror_gib "$mode")"
  remaining="$(um_remaining_download_gib "$mode" "$path")"
  reserve="$(um_disk_reserve_gib "$path")"
  usable=$(( avail_gib - reserve ))
  if [[ "$usable" -lt 0 ]]; then usable=0; fi

  printf 'Disk capacity check (%s mode):\n' "$mode"
  printf '  Filesystem total:     %s GiB\n' "$total_gib"
  printf '  Available now:        %s GiB\n' "$avail_gib"
  printf '  Safety reserve:       %s GiB (%s%% of total)\n' "$reserve" "$reserve_pct"
  printf '  Usable for download:  %s GiB\n' "$usable"
  printf '  Projected mirror size:%s GiB\n' "$projected"
  printf '  Remaining to download:%s GiB\n' "$remaining"

  # Never allow a sync that would consume the safety reserve.
  if [[ "$remaining" -gt "$usable" ]]; then
    um_error "Projected download (${remaining} GiB) exceeds usable space (${usable} GiB)"
    um_error "Refusing to start sync — free disk or expand storage."
    if [[ "$mode" == "full" || "$mode" == "FULL" || "$mode" == "offline-upgrade-full" ]]; then
      um_error "offline-upgrade-full (~${projected} GiB) is not safe on this disk with a ${reserve_pct}% reserve."
      um_error "Minimal mirrors are unsupported (UNSUPPORTED_MINIMAL_PROFILE)."
      um_error "Expand storage, then: sudo ./install.sh --full"
    fi
    return 1
  fi

  # Extra guard: ~1TB class disks must not run full unless clearly enough headroom
  # (usable already enforced above; this message clarifies operator intent).
  if [[ "$mode" == "full" || "$mode" == "FULL" || "$mode" == "offline-upgrade-full" ]] && [[ "$total_gib" -le 1100 ]]; then
    local free_after=$(( avail_gib - remaining ))
    local free_after_pct=0
    if [[ "$total_gib" -gt 0 ]]; then
      free_after_pct=$(( free_after * 100 / total_gib ))
    fi
    if [[ "$free_after_pct" -lt "$reserve_pct" ]]; then
      um_error "offline-upgrade-full on ~1TB disk would leave ~${free_after_pct}% free (< ${reserve_pct}% reserve)"
      um_error "Refusing sync. Expand storage; minimal mode is not supported."
      return 1
    fi
  fi

  um_ok "Capacity OK for ${mode} sync (remaining ${remaining} GiB <= usable ${usable} GiB)"
  return 0
}

um_confirm() {
  # um_confirm "message" — returns 0 if yes. Skipped in non-interactive.
  local msg="$1"
  if [[ "${UM_NON_INTERACTIVE:-0}" == "1" ]]; then
    return 0
  fi
  local ans
  read -r -p "$msg [y/N] " ans || true
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Trap / cleanup
# ---------------------------------------------------------------------------
UM_CLEANUP_FUNCS=()

um_register_cleanup() {
  UM_CLEANUP_FUNCS+=("$1")
}

um_cleanup() {
  local fn
  local code=$?
  for fn in "${UM_CLEANUP_FUNCS[@]:-}"; do
    [[ -n "$fn" ]] || continue
    "$fn" || true
  done
  return "$code"
}

um_setup_trap() {
  trap 'um_cleanup' EXIT
  trap 'um_error "Interrupted"; exit 130' INT TERM
}

# ---------------------------------------------------------------------------
# Validation result helpers (PASS/WARNING/FAIL)
# ---------------------------------------------------------------------------
UM_PASS_COUNT=0
UM_WARN_COUNT=0
UM_FAIL_COUNT=0

um_result_reset() {
  UM_PASS_COUNT=0
  UM_WARN_COUNT=0
  UM_FAIL_COUNT=0
}

um_result() {
  local status="$1"
  local name="$2"
  local detail="${3:-}"
  case "$status" in
    PASS)
      ((UM_PASS_COUNT++)) || true
      printf '%s[PASS]%s    %s%s%s\n' "$UM_C_GREEN" "$UM_C_RESET" "$name" \
        "${detail:+ — }" "${detail}"
      ;;
    WARNING)
      ((UM_WARN_COUNT++)) || true
      printf '%s[WARNING]%s %s%s%s\n' "$UM_C_YELLOW" "$UM_C_RESET" "$name" \
        "${detail:+ — }" "${detail}"
      ;;
    FAIL)
      ((UM_FAIL_COUNT++)) || true
      printf '%s[FAIL]%s    %s%s%s\n' "$UM_C_RED" "$UM_C_RESET" "$name" \
        "${detail:+ — }" "${detail}"
      ;;
    *)
      um_error "Unknown result status: $status"
      ;;
  esac
}

um_result_summary() {
  printf '\n%sValidation summary:%s PASS=%s WARNING=%s FAIL=%s\n' \
    "$UM_C_BOLD" "$UM_C_RESET" "$UM_PASS_COUNT" "$UM_WARN_COUNT" "$UM_FAIL_COUNT"
  if [[ "$UM_FAIL_COUNT" -gt 0 ]]; then
    return 2
  fi
  if [[ "$UM_WARN_COUNT" -gt 0 ]]; then
    return 1
  fi
  return 0
}
