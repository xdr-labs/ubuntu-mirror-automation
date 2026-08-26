#!/usr/bin/env bash
# ubuntu-offline-mirror.sh — Integrated offline Ubuntu upgrade mirror sync/verify/status/freeze
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_project_root() {
  if [[ -f "${SCRIPT_DIR}/../lib/offline.sh" ]]; then
    cd "${SCRIPT_DIR}/.." && pwd
    return
  fi
  if [[ -f /usr/local/lib/ubuntu-mirror/offline.sh ]]; then
    printf '%s\n' /usr/local/lib/ubuntu-mirror
    return
  fi
  if [[ -f "${SCRIPT_DIR}/offline.sh" ]]; then
    printf '%s\n' "$SCRIPT_DIR"
    return
  fi
  printf '%s\n' "$SCRIPT_DIR"
}

PROJECT_ROOT="$(resolve_project_root)"
if [[ -f "${PROJECT_ROOT}/lib/offline.sh" ]]; then
  # shellcheck source=lib/offline.sh
  source "${PROJECT_ROOT}/lib/offline.sh"
elif [[ -f /usr/local/lib/ubuntu-mirror/offline.sh ]]; then
  # shellcheck source=/dev/null
  source /usr/local/lib/ubuntu-mirror/offline.sh
elif [[ -f "${SCRIPT_DIR}/../lib/offline.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/../lib/offline.sh"
else
  echo "ERROR: cannot find offline.sh library" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Defaults: environment wins, then /etc/default/ubuntu-offline-mirror, then built-ins
# ---------------------------------------------------------------------------
# Capture caller/environment overrides before assigning built-in defaults.
_UOM_ENV_KEYS=(
  PUBLIC_BASE_URL MIRROR_ROOT UPSTREAM_BASE_URL META_RELEASE_URL MIN_FREE_GB
  DEFAULT_ARCH ALLOWED_HOSTS EXTRA_ALLOWED_HOSTS RUN_CLEAN ALLOW_ROOT_FS_MIRROR
  SKIP_APT_MIRROR UBUNTU_KEYRING LOG_FILE LOCK_FILE CURL_CONNECT_TIMEOUT
  CURL_MAX_TIME CURL_RETRIES VERIFY_HTTP_BASE UBUNTU_RELEASES UPGRADER_DISTS
  SUITE_SUFFIXES COMPONENTS META_CHAIN_DISTS SYNC_RANDOMIZED_DELAY_SEC
)
declare -A _UOM_ENV_SET=()
declare -A _UOM_ENV_VAL=()
for _k in "${_UOM_ENV_KEYS[@]}"; do
  if [[ -n "${!_k+x}" ]]; then
    _UOM_ENV_SET["$_k"]=1
    _UOM_ENV_VAL["$_k"]="${!_k}"
  fi
done
unset _k

PUBLIC_BASE_URL="http://ubuntu-mirror.local"
MIRROR_ROOT="/var/spool/apt-mirror"
UPSTREAM_BASE_URL="http://archive.ubuntu.com/ubuntu"
META_RELEASE_URL="http://changelogs.ubuntu.com/meta-release-lts"
MIN_FREE_GB=50
DEFAULT_ARCH="amd64"
ALLOWED_HOSTS="changelogs.ubuntu.com archive.ubuntu.com security.ubuntu.com old-releases.ubuntu.com"
EXTRA_ALLOWED_HOSTS=""
RUN_CLEAN=true
ALLOW_ROOT_FS_MIRROR=false
SKIP_APT_MIRROR=false
UBUNTU_KEYRING="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
LOG_FILE="/var/log/ubuntu-offline-mirror.log"
LOCK_FILE="/run/ubuntu-offline-mirror.lock"
CURL_CONNECT_TIMEOUT=30
CURL_MAX_TIME=600
CURL_RETRIES=3
VERIFY_HTTP_BASE="http://127.0.0.1"
UBUNTU_RELEASES="xenial bionic focal jammy noble"
UPGRADER_DISTS="bionic focal jammy noble"
SUITE_SUFFIXES="updates security backports"
COMPONENTS="main restricted universe multiverse"
META_CHAIN_DISTS="xenial bionic focal jammy noble"

load_defaults_file() {
  local f="/etc/default/ubuntu-offline-mirror"
  [[ -f "$f" ]] || return 0
  # shellcheck disable=SC1090,SC1091
  set -a
  # shellcheck disable=SC1091
  source "$f"
  set +a
}

load_defaults_file

# Re-apply environment overrides (highest precedence)
if [[ ${#_UOM_ENV_SET[@]} -gt 0 ]]; then
  for _k in "${!_UOM_ENV_SET[@]}"; do
    printf -v "$_k" '%s' "${_UOM_ENV_VAL[$_k]}"
  done
fi
unset _k
unset _UOM_ENV_SET _UOM_ENV_VAL _UOM_ENV_KEYS

MIRROR_PATH="${MIRROR_ROOT}/mirror"
SKEL_PATH="${MIRROR_ROOT}/skel"
VAR_PATH="${MIRROR_ROOT}/var"
UBUNTU_ROOT="${MIRROR_PATH}/archive.ubuntu.com/ubuntu"
DIST_ROOT="${UBUNTU_ROOT}/dists"
OFFLINE_DIR="${MIRROR_ROOT}/offline"
READY_MARKER="${OFFLINE_DIR}/READY"
FROZEN_MARKER="${OFFLINE_DIR}/FROZEN"
META_UPSTREAM="${OFFLINE_DIR}/meta-release-lts.upstream"
META_LOCAL="${OFFLINE_DIR}/meta-release-lts"
MANIFEST_JSON="${OFFLINE_DIR}/manifest.json"
SHA256SUMS="${OFFLINE_DIR}/SHA256SUMS"
SYNC_STATE="${OFFLINE_DIR}/last-sync.json"
SNAPSHOT_INFO="${OFFLINE_DIR}/snapshot.json"
ANNOUNCE_DIR="${OFFLINE_DIR}/announcements"

SYNC_STARTED=""
SYNC_ENDED=""
SNAPSHOT_ID=""
TMP_DIR=""
LOCK_FD=""
LOCK_HELD=0
LOCK_COMMAND=""
LOCK_HOP=""
LOCK_MODE=""
LOCK_ACQUIRED_AT=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }
iso_now() { date -Is; }

log() {
  local level="$1"; shift
  local msg="$*"
  local line
  line="$(ts) [${level}] ${msg}"
  case "$level" in
    ERROR) printf '%s\n' "$line" >&2 ;;
    WARN)  printf '%s\n' "$line" >&2 ;;
    *)     printf '%s\n' "$line" ;;
  esac
  if [[ -n "${LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
  fi
}
info() { log INFO "$*"; }
warn() { log WARN "$*"; }
error() { log ERROR "$*"; }
die() { error "$*"; exit 1; }
ok() { log OK "$*"; }

# Global exclusive lock (advisory flock). Exclusivity is the open FD + flock,
# not the mere presence of LOCK_FILE. Metadata is diagnostic only.
_uom_lock_meta_path() {
  printf '%s\n' "${LOCK_FILE}.meta"
}

_uom_write_lock_meta() {
  local meta tmp
  meta="$(_uom_lock_meta_path)"
  tmp="${meta}.tmp.$$"
  {
    printf 'pid=%s\n' "$$"
    printf 'started_at=%s\n' "${LOCK_ACQUIRED_AT:-$(iso_now)}"
    printf 'command=%s\n' "${LOCK_COMMAND:-unknown}"
    printf 'hop=%s\n' "${LOCK_HOP:-}"
    printf 'hostname=%s\n' "$(hostname 2>/dev/null || printf 'unknown')"
    printf 'lock_mode=%s\n' "${LOCK_MODE:-STANDALONE}"
  } >"$tmp"
  mv -f "$tmp" "$meta"
}

_uom_read_lock_meta_field() {
  local key="$1" meta
  meta="$(_uom_lock_meta_path)"
  [[ -f "$meta" ]] || return 1
  awk -F= -v k="$key" '$1==k {print substr($0, index($0,"=")+1); exit}' "$meta" 2>/dev/null
}

release_global_lock() {
  if [[ "${LOCK_HELD:-0}" != "1" ]] && [[ -z "${LOCK_FD:-}" ]]; then
    return 0
  fi
  local meta
  meta="$(_uom_lock_meta_path)"
  if [[ -n "${LOCK_FD:-}" ]]; then
    flock -u "$LOCK_FD" 2>/dev/null || true
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
    LOCK_FD=""
  fi
  LOCK_HELD=0
  rm -f "$meta" 2>/dev/null || true
  info "LOCK_RELEASED=PASS"
}

acquire_global_lock_once() {
  # Acquire the global lock exactly once per process.
  # Re-open/{LOCK_FD} reuse must never happen: bash allocates a *new* FD on
  # each `exec {var}>file`, leaving the previous FD (and flock) open — that
  # caused FAIL on verify/publish nested under refresh-hop-selective.
  local cmd="${1:-unknown}"
  local hop="${2:-}"
  local mode="${3:-STANDALONE}"
  local new_fd="" meta owner_pid active_cmd active_hop

  if [[ "${LOCK_HELD:-0}" == "1" ]]; then
    error "FAIL_SELECTIVE_ORCHESTRATION_REENTRANT_LOCK"
    error "PARENT_COMMAND=${LOCK_COMMAND:-unknown}"
    error "CHILD_COMMAND=${cmd}"
    [[ -n "${LOCK_HOP:-}" ]] && error "PARENT_HOP=${LOCK_HOP}"
    [[ -n "$hop" ]] && error "CHILD_HOP=${hop}"
    error "LOCK_PATH=${LOCK_FILE}"
    die "Reentrant global lock acquire refused (same process already holds ${LOCK_FILE})"
  fi

  mkdir -p "$(dirname "$LOCK_FILE")"
  # Fresh empty varname → bash allocates one new FD; never reuse LOCK_FD here.
  exec {new_fd}>"$LOCK_FILE"
  if ! flock -n "$new_fd"; then
    eval "exec ${new_fd}>&-" 2>/dev/null || true
    meta="$(_uom_lock_meta_path)"
    owner_pid="$(_uom_read_lock_meta_field pid || true)"
    active_cmd="$(_uom_read_lock_meta_field command || true)"
    active_hop="$(_uom_read_lock_meta_field hop || true)"
    error "FAIL_SELECTIVE_MIRROR_LOCK_BUSY"
    error "LOCK_PATH=${LOCK_FILE}"
    if [[ -n "$owner_pid" ]]; then
      error "LOCK_OWNER_PID=${owner_pid}"
    fi
    if [[ -n "$active_cmd" ]]; then
      error "ACTIVE_COMMAND=${active_cmd}"
    fi
    if [[ -n "$active_hop" ]]; then
      error "ACTIVE_HOP=${active_hop}"
    fi
    die "Another ubuntu-offline-mirror process holds ${LOCK_FILE}"
  fi

  # Stale metadata with no flock owner: overwrite after successful acquire.
  LOCK_FD="$new_fd"
  LOCK_HELD=1
  LOCK_COMMAND="$cmd"
  LOCK_HOP="$hop"
  LOCK_MODE="$mode"
  LOCK_ACQUIRED_AT="$(iso_now)"
  _uom_write_lock_meta
  ok "LOCK_ACQUIRED=PASS LOCK_MODE=${LOCK_MODE} command=${cmd}${hop:+ hop=${hop}}"
}

# Legacy alias used by non-selective commands (sync, freeze, …).
acquire_lock() {
  acquire_global_lock_once "${1:-ubuntu-offline-mirror}" "${2:-}" "${3:-STANDALONE}"
}

cleanup_tmp() {
  if [[ -n "${TMP_DIR:-}" ]] && [[ -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}

cleanup_on_exit() {
  release_global_lock
  cleanup_tmp
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

invalidate_ready() {
  if [[ -f "$READY_MARKER" ]]; then
    mv -f "$READY_MARKER" "${READY_MARKER}.invalid.$(date +%s)" 2>/dev/null \
      || rm -f "$READY_MARKER"
    warn "READY marker invalidated"
  fi
  rm -f /var/lib/ubuntu-mirror/ready /var/lib/ubuntu-mirror/initial-sync-complete 2>/dev/null || true
}

resolve_validate_upgrade_profile_py() {
  local cand
  for cand in \
    "${PROJECT_ROOT}/scripts/lib/validate_upgrade_profile.py" \
    "/usr/local/lib/ubuntu-mirror/validate_upgrade_profile.py" \
    "${SCRIPT_DIR}/lib/validate_upgrade_profile.py"
  do
    if [[ -f "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

resolve_upgrade_profile_json() {
  local cand
  for cand in \
    "${PROJECT_ROOT}/config/offline-upgrade-profile.json" \
    "/etc/ubuntu-mirror/offline-upgrade-profile.json" \
    "/usr/local/lib/ubuntu-mirror/offline-upgrade-profile.json"
  do
    if [[ -f "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

assert_upgrade_profile_allowed() {
  # Block minimal / incomplete configs before any download work.
  local conf mode
  conf="/etc/ubuntu-mirror/mirror.conf"
  [[ -f "$conf" ]] || conf="${PROJECT_ROOT}/mirror.conf"
  if [[ -f "$conf" ]]; then
    mode="$(awk -F= '/^MIRROR_MODE=/{gsub(/"/, "", $2); print $2; exit}' "$conf" 2>/dev/null || true)"
    case "${mode}" in
      minimal|MINIMAL)
        cat >&2 <<EOF
ERROR: Minimal mirror profiles are not supported.

Required profile: offline-upgrade-selective
Selection mode: discovery_exact

error_code=UNSUPPORTED_MINIMAL_PROFILE
No sync was started.
EOF
        return 1
        ;;
      full|FULL|offline-upgrade-full)
        cat >&2 <<EOF
ERROR: Full apt-mirror sync is not part of offline-upgrade-selective.

Use: plan-selective → materialize-selective → verify-selective → publish-selective

error_code=UNSUPPORTED_FULL_MIRROR_SYNC
No sync was started.
EOF
        return 1
        ;;
    esac
  fi
  local py profile ml
  py="$(resolve_validate_upgrade_profile_py)" || {
    warn "validate_upgrade_profile.py missing — skipping pre-sync profile gate"
    return 0
  }
  profile="$(resolve_upgrade_profile_json)" || return 0
  ml="/etc/apt/mirror.list"
  [[ -f "$ml" ]] || ml="${PROJECT_ROOT}/templates/mirror.list"
  mkdir -p "$OFFLINE_DIR"
  set +e
  python3 "$py" check-profile \
    --mirror-root "$MIRROR_ROOT" \
    --profile "$profile" \
    --mirror-list "$ml" \
    --mirror-conf "${conf}" \
    --project-root "$PROJECT_ROOT" \
    --result-json "${OFFLINE_DIR}/upgrade-profile-check.json"
  local rc=$?
  set -e
  return "$rc"
}

validate_upgrade_profile_gate() {
  local py profile
  py="$(resolve_validate_upgrade_profile_py)" || {
    error "validate_upgrade_profile.py not found"
    return 1
  }
  profile="$(resolve_upgrade_profile_json)" || {
    error "offline-upgrade-profile.json not found"
    return 1
  }
  mkdir -p "$OFFLINE_DIR"
  set +e
  python3 "$py" validate \
    --mirror-root "$MIRROR_ROOT" \
    --ubuntu-root "$UBUNTU_ROOT" \
    --profile "$profile" \
    --mirror-list "${MIRROR_LIST_PATH:-/etc/apt/mirror.list}" \
    --mirror-conf "${MIRROR_CONF_PATH:-/etc/ubuntu-mirror/mirror.conf}" \
    --project-root "$PROJECT_ROOT" \
    --result-json "${OFFLINE_DIR}/readiness-validation.json" \
    --skip-external-gates \
    "$@" 2>&1 | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
require_cmds() {
  local c missing=()
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required commands: ${missing[*]}"
  fi
}

allowlist_hosts() {
  local all
  all="${ALLOWED_HOSTS} ${EXTRA_ALLOWED_HOSTS}"
  # Also allow host from UPSTREAM_BASE_URL and META_RELEASE_URL
  all="${all} $(uom_url_host "$UPSTREAM_BASE_URL") $(uom_url_host "$META_RELEASE_URL")"
  printf '%s\n' "$all"
}

assert_url_allowed() {
  local url="$1"
  local host
  host="$(uom_url_host "$url")"
  if ! uom_host_allowed "$host" "$(allowlist_hosts)"; then
    die "Refusing download from non-allowlisted host: ${host} (url=${url})"
  fi
}

# (lock helpers defined near logging; see acquire_global_lock_once)

# ---------------------------------------------------------------------------
# Disk / mount checks
# ---------------------------------------------------------------------------
path_fs_source() {
  findmnt -n -o SOURCE -T "$1" 2>/dev/null || echo unknown
}

path_fs_target() {
  findmnt -n -o TARGET -T "$1" 2>/dev/null || echo unknown
}

check_mirror_mount() {
  local target src root_src
  mkdir -p "$MIRROR_ROOT"
  target="$(path_fs_target "$MIRROR_ROOT")"
  src="$(path_fs_source "$MIRROR_ROOT")"
  root_src="$(path_fs_source /)"

  if [[ "$target" == "/" ]] || [[ "$src" == "$root_src" ]]; then
    if [[ "${ALLOW_ROOT_FS_MIRROR}" == "true" ]]; then
      warn "MIRROR_ROOT ${MIRROR_ROOT} is on OS root filesystem (${src}) — ALLOW_ROOT_FS_MIRROR=true"
      return 0
    fi
    die "MIRROR_ROOT ${MIRROR_ROOT} is on OS root filesystem (${src}). Mount a dedicated data disk or set ALLOW_ROOT_FS_MIRROR=true"
  fi
  ok "MIRROR_ROOT on dedicated mount: ${target} <- ${src}"
}

check_disk_space() {
  local avail_kb avail_gb inodes_free
  if [[ ! -w "$MIRROR_ROOT" ]]; then
    die "MIRROR_ROOT not writable: $MIRROR_ROOT"
  fi
  avail_kb="$(df -Pk "$MIRROR_ROOT" | awk 'NR==2 {print $4}')"
  avail_gb=$(( avail_kb / 1024 / 1024 ))
  inodes_free="$(df -Pi "$MIRROR_ROOT" | awk 'NR==2 {print $4}')"
  info "Disk free: ${avail_gb} GiB; inodes free: ${inodes_free}"
  if [[ "$avail_gb" -lt "$MIN_FREE_GB" ]]; then
    die "Insufficient free space: ${avail_gb} GiB < MIN_FREE_GB=${MIN_FREE_GB}"
  fi
  if [[ "${inodes_free}" -lt 100000 ]]; then
    die "Insufficient free inodes: ${inodes_free}"
  fi
  if [[ -d "$UBUNTU_ROOT" ]]; then
    info "Existing mirror size: $(du -sh "$MIRROR_ROOT" 2>/dev/null | awk '{print $1}')"
  fi
}

# ---------------------------------------------------------------------------
# Safe download
# ---------------------------------------------------------------------------
# Download URL to dest. Returns 0 on success; non-zero on failure (does not exit).
try_download() {
  local url="$1"
  local dest="$2"
  local tmp host final_url http_code size rc

  assert_url_allowed "$url"
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp "${TMP_DIR:-/tmp}/dl.XXXXXX")"

  set +e
  http_code="$(curl --fail --location --silent --show-error \
    --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
    --max-time "${CURL_MAX_TIME}" \
    --retry "${CURL_RETRIES}" \
    --retry-delay 2 \
    -o "$tmp" \
    -w '%{http_code}|%{url_effective}' \
    "$url")"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    rm -f "$tmp"
    error "Download failed (curl rc=${rc}): $url"
    return 1
  fi

  final_url="${http_code#*|}"
  http_code="${http_code%%|*}"
  if [[ "$http_code" != "200" ]]; then
    rm -f "$tmp"
    error "Download HTTP ${http_code}: $url"
    return 1
  fi

  host="$(uom_url_host "$final_url")"
  if ! uom_host_allowed "$host" "$(allowlist_hosts)"; then
    rm -f "$tmp"
    error "Redirect target host not allowlisted: ${host} (from ${url})"
    return 1
  fi

  size="$(stat -c%s "$tmp" 2>/dev/null || echo 0)"
  if [[ "$size" -eq 0 ]]; then
    rm -f "$tmp"
    error "Refusing zero-byte download: $url"
    return 1
  fi
  if uom_is_probably_html "$tmp"; then
    rm -f "$tmp"
    error "Download looks like HTML error page: $url"
    return 1
  fi

  mv -f "$tmp" "$dest"
  chmod 0644 "$dest"
  ok "Downloaded $(basename "$dest") (${size} bytes)"
  return 0
}

safe_download() {
  try_download "$1" "$2" || die "Required download failed: $1"
}

# Quiet download for optional assets (404 → return 1 without ERROR spam)
try_download_optional() {
  local url="$1"
  local dest="$2"
  local tmp host final_url http_code size rc host_check

  host_check="$(uom_url_host "$url")"
  if ! uom_host_allowed "$host_check" "$(allowlist_hosts)"; then
    error "Refusing download from non-allowlisted host: ${host_check}"
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp "${TMP_DIR:-/tmp}/dl.XXXXXX")"

  set +e
  http_code="$(curl --fail --location --silent --show-error \
    --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
    --max-time "${CURL_MAX_TIME}" \
    --retry 1 \
    -o "$tmp" \
    -w '%{http_code}|%{url_effective}' \
    "$url" 2>/dev/null)"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    rm -f "$tmp"
    return 1
  fi
  final_url="${http_code#*|}"
  http_code="${http_code%%|*}"
  [[ "$http_code" == "200" ]] || { rm -f "$tmp"; return 1; }
  host="$(uom_url_host "$final_url")"
  uom_host_allowed "$host" "$(allowlist_hosts)" || { rm -f "$tmp"; return 1; }
  size="$(stat -c%s "$tmp" 2>/dev/null || echo 0)"
  [[ "$size" -gt 0 ]] || { rm -f "$tmp"; return 1; }
  uom_is_probably_html "$tmp" && { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dest"
  chmod 0644 "$dest"
  return 0
}

# ---------------------------------------------------------------------------
# Release upgrader sync
# ---------------------------------------------------------------------------
upgrader_dir_for() {
  local dist="$1"
  printf '%s/%s-updates/main/dist-upgrader-all/current\n' "$DIST_ROOT" "$dist"
}

sync_release_upgraders() {
  info "Syncing release upgraders from meta-release-lts"
  mkdir -p "$OFFLINE_DIR" "$ANNOUNCE_DIR" "$TMP_DIR"

  safe_download "$META_RELEASE_URL" "$META_UPSTREAM"

  local dist stanza tool sig release_notes release_notes_html release_file
  local dest_dir dest_tool dest_sig
  local allow
  allow="$(allowlist_hosts)"

  for dist in $UPGRADER_DISTS; do
    stanza="$(uom_extract_dist_stanza "$META_UPSTREAM" "$dist")"
    [[ -n "$stanza" ]] || die "Dist ${dist} missing from meta-release-lts"

    tool="$(uom_stanza_get "$stanza" UpgradeTool)"
    sig="$(uom_stanza_get "$stanza" UpgradeToolSignature)"
    [[ -n "$tool" ]] || die "UpgradeTool missing for Dist ${dist}"
    [[ -n "$sig" ]] || die "UpgradeToolSignature missing for Dist ${dist}"

    assert_url_allowed "$tool"
    assert_url_allowed "$sig"

    dest_dir="$(upgrader_dir_for "$dist")"
    mkdir -p "$dest_dir"
    dest_tool="${dest_dir}/${dist}.tar.gz"
    dest_sig="${dest_dir}/${dist}.tar.gz.gpg"

    safe_download "$tool" "$dest_tool"
    safe_download "$sig" "$dest_sig"

    # Optional announcement / notes files
    release_notes="$(uom_stanza_get "$stanza" ReleaseNotes)"
    release_notes_html="$(uom_stanza_get "$stanza" ReleaseNotesHtml)"
    release_file="$(uom_stanza_get "$stanza" Release-File)"

    local optional_url optional_name optional_dest
    for optional_url in "$release_notes" "$release_notes_html"; do
      [[ -n "$optional_url" ]] || continue
      if ! uom_host_allowed "$(uom_url_host "$optional_url")" "$allow"; then
        die "ReleaseNotes host not allowlisted for ${dist}: $optional_url"
      fi
      optional_name="$(basename "$(uom_url_path "$optional_url")")"
      optional_dest="${dest_dir}/${optional_name}"
      if try_download_optional "$optional_url" "$optional_dest"; then
        cp -f "$optional_dest" "${ANNOUNCE_DIR}/${optional_name}"
      else
        warn "Optional announcement unavailable for ${dist}: $optional_url"
      fi
    done

    # Probe common announcement names next to the upgrader when present upstream
    local name probe
    for name in ReleaseAnnouncement ReleaseAnnouncement.html \
                EOLReleaseAnnouncement EOLReleaseAnnouncement.html \
                DevelReleaseAnnouncement DevelReleaseAnnouncement.html; do
      if [[ -f "${dest_dir}/${name}" ]]; then
        cp -f "${dest_dir}/${name}" "${ANNOUNCE_DIR}/${name}"
        continue
      fi
      probe="${UPSTREAM_BASE_URL}/dists/${dist}-updates/main/dist-upgrader-all/current/${name}"
      if try_download_optional "$probe" "${dest_dir}/${name}"; then
        cp -f "${dest_dir}/${name}" "${ANNOUNCE_DIR}/${name}"
      fi
    done

    info "Release-File for ${dist}: ${release_file:-none}"
  done
}

verify_upgrader_gpg() {
  local dist="$1"
  local tool sig
  tool="$(upgrader_dir_for "$dist")/${dist}.tar.gz"
  sig="$(upgrader_dir_for "$dist")/${dist}.tar.gz.gpg"

  [[ -f "$tool" ]] || { error "Missing upgrader tarball: $tool"; return 1; }
  [[ -f "$sig" ]] || { error "Missing upgrader signature: $sig"; return 1; }
  [[ "$(stat -c%s "$tool")" -gt 0 ]] || { error "Zero-byte tarball: $tool"; return 1; }
  [[ "$(stat -c%s "$sig")" -gt 0 ]] || { error "Zero-byte signature: $sig"; return 1; }
  if uom_is_probably_html "$tool"; then
    error "Tarball looks like HTML: $tool"
    return 1
  fi
  [[ -f "$UBUNTU_KEYRING" ]] || { error "Keyring missing: $UBUNTU_KEYRING"; return 1; }

  if gpgv --keyring "$UBUNTU_KEYRING" "$sig" "$tool" >/dev/null 2>&1; then
    ok "GPG OK: ${dist}.tar.gz"
    return 0
  fi
  error "GPG verification failed: ${dist}.tar.gz"
  return 1
}

verify_all_upgraders() {
  local dist rc=0
  for dist in $UPGRADER_DISTS; do
    verify_upgrader_gpg "$dist" || rc=1
  done
  return "$rc"
}

# ---------------------------------------------------------------------------
# Local meta-release-lts
# ---------------------------------------------------------------------------
build_local_meta() {
  info "Building local meta-release-lts -> $META_LOCAL"
  mkdir -p "$OFFLINE_DIR"
  [[ -f "$META_UPSTREAM" ]] || die "Missing upstream meta: $META_UPSTREAM"

  local tmp
  tmp="$(mktemp "${TMP_DIR}/meta.XXXXXX")"
  # shellcheck disable=SC2086
  if ! uom_build_local_meta "$META_UPSTREAM" "$PUBLIC_BASE_URL" $META_CHAIN_DISTS >"$tmp"; then
    rm -f "$tmp"
    die "Failed to build local meta-release-lts"
  fi
  if ! uom_local_meta_urls_ok "$tmp" "$PUBLIC_BASE_URL"; then
    rm -f "$tmp"
    die "Local meta-release-lts still contains external URLs"
  fi
  # Extra guard: UpgradeTool must not contain archive.ubuntu.com etc.
  if grep -E 'UpgradeTool(Signature)?:.*(archive|security|old-releases|changelogs)\.ubuntu\.com' "$tmp" >/dev/null; then
    rm -f "$tmp"
    die "Local meta still references external Ubuntu hosts in UpgradeTool fields"
  fi
  mv -f "$tmp" "$META_LOCAL"
  chmod 0644 "$META_LOCAL"
  ok "Wrote $META_LOCAL"
}

# ---------------------------------------------------------------------------
# Suite / APT verification
# ---------------------------------------------------------------------------
suite_has_release_meta() {
  local suite="$1"
  local d="${DIST_ROOT}/${suite}"
  if [[ -f "${d}/InRelease" ]] && [[ "$(stat -c%s "${d}/InRelease")" -gt 0 ]]; then
    return 0
  fi
  if [[ -f "${d}/Release" ]] && [[ "$(stat -c%s "${d}/Release")" -gt 0 ]] \
    && [[ -f "${d}/Release.gpg" ]] && [[ "$(stat -c%s "${d}/Release.gpg")" -gt 0 ]]; then
    return 0
  fi
  return 1
}

suite_has_packages_index() {
  local suite="$1"
  local comp="$2"
  local base="${DIST_ROOT}/${suite}/${comp}/binary-amd64"
  local f
  for f in Packages.xz Packages.gz Packages; do
    if [[ -f "${base}/${f}" ]] && [[ "$(stat -c%s "${base}/${f}")" -gt 0 ]]; then
      return 0
    fi
  done
  return 1
}

valid_until_of_suite() {
  local suite="$1"
  local f=""
  if [[ -f "${DIST_ROOT}/${suite}/InRelease" ]]; then
    f="${DIST_ROOT}/${suite}/InRelease"
  elif [[ -f "${DIST_ROOT}/${suite}/Release" ]]; then
    f="${DIST_ROOT}/${suite}/Release"
  else
    printf 'n/a\n'
    return
  fi
  awk -F': ' '/^Valid-Until:/ {print $2; exit}' "$f" || printf 'none\n'
}

verify_all_suites_fs() {
  local suite comp rc=0
  # shellcheck disable=SC2086
  while IFS= read -r suite; do
    [[ -n "$suite" ]] || continue
    if ! suite_has_release_meta "$suite"; then
      error "Suite ${suite}: missing InRelease/Release(+gpg)"
      rc=1
      continue
    fi
    for comp in $COMPONENTS; do
      if ! suite_has_packages_index "$suite" "$comp"; then
        error "Suite ${suite}/${comp}: missing amd64 Packages index"
        rc=1
      fi
    done
    info "Suite ${suite}: OK (Valid-Until=$(valid_until_of_suite "$suite"))"
  done < <(uom_all_suites "$UBUNTU_RELEASES" "$SUITE_SUFFIXES")
  return "$rc"
}

http_check() {
  local url="$1"
  local code size ctype body
  body="$(mktemp "${TMP_DIR:-/tmp}/http.XXXXXX")"
  code="$(curl -sS -o "$body" --max-time 30 -w '%{http_code}' "${VERIFY_HTTP_BASE}${url}" || echo 000)"
  size="$(stat -c%s "$body" 2>/dev/null || echo 0)"
  ctype="$(file -b --mime-type "$body" 2>/dev/null || echo unknown)"
  rm -f "$body"
  printf '%s %s %s\n' "$code" "$size" "$ctype"
}

verify_http_endpoints() {
  local rc=0
  local path code size ctype
  local paths=(
    /offline/meta-release-lts
    /offline/meta-release-lts.upstream
    /offline/manifest.json
    /offline/SHA256SUMS
  )
  # Suite metadata samples (archive prefix)
  local suite
  # shellcheck disable=SC2086
  while IFS= read -r suite; do
    paths+=("/ubuntu/dists/${suite}/InRelease")
  done < <(uom_all_suites "$UBUNTU_RELEASES" "$SUITE_SUFFIXES")

  # Security pocket via distinct /ubuntu-security/ prefix (same on-disk tree)
  local release
  for release in $UBUNTU_RELEASES; do
    paths+=("/ubuntu-security/dists/${release}-security/InRelease")
  done

  local dist
  for dist in $UPGRADER_DISTS; do
    paths+=("/ubuntu/dists/${dist}-updates/main/dist-upgrader-all/current/${dist}.tar.gz")
    paths+=("/ubuntu/dists/${dist}-updates/main/dist-upgrader-all/current/${dist}.tar.gz.gpg")
  done

  for path in "${paths[@]}"; do
    # InRelease may 404 if only Release+Release.gpg — try Release fallback
    read -r code size ctype <<<"$(http_check "$path")"
    if [[ "$path" == */InRelease ]] && [[ "$code" != "200" ]]; then
      local alt="${path%/InRelease}/Release"
      read -r code size ctype <<<"$(http_check "$alt")"
      path="$alt"
    fi
    if [[ "$code" != "200" ]]; then
      error "HTTP ${code} for ${path}"
      rc=1
      continue
    fi
    if [[ "$size" -eq 0 ]]; then
      error "HTTP 200 but zero length: ${path}"
      rc=1
      continue
    fi
    if [[ "$path" == *.tar.gz ]] && [[ "$ctype" == text/html ]]; then
      error "tar.gz endpoint returned HTML: ${path}"
      rc=1
      continue
    fi
    ok "HTTP 200 ${path} (${size} bytes)"
  done

  # READY may be absent during mid-sync verify failure path — optional here
  return "$rc"
}

resolve_validate_security_py() {
  local cand
  for cand in \
    "${PROJECT_ROOT}/scripts/lib/validate_security_compat.py" \
    "/usr/local/lib/ubuntu-mirror/validate_security_compat.py" \
    "${SCRIPT_DIR}/lib/validate_security_compat.py"
  do
    if [[ -f "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

resolve_sync_release_upgraders_py() {
  local cand
  for cand in \
    "${PROJECT_ROOT}/scripts/lib/sync_release_upgraders.py" \
    "/usr/local/lib/ubuntu-mirror/sync_release_upgraders.py" \
    "${SCRIPT_DIR}/lib/sync_release_upgraders.py"
  do
    if [[ -f "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

resolve_sync_legacy_releases_py() {
  local cand
  for cand in \
    "${PROJECT_ROOT}/scripts/lib/sync_legacy_releases.py" \
    "/usr/local/lib/ubuntu-mirror/sync_legacy_releases.py" \
    "${SCRIPT_DIR}/lib/sync_legacy_releases.py"
  do
    if [[ -f "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

run_release_upgraders_tool() {
  local cmd="$1"
  shift || true
  local py result_json
  py="$(resolve_sync_release_upgraders_py)" || die "sync_release_upgraders.py not found"
  result_json="${OFFLINE_DIR}/release-upgrader-validation.json"
  mkdir -p "$OFFLINE_DIR"
  info "release-upgrader ${cmd}: starting (result -> ${result_json})"
  set +e
  python3 "$py" "$cmd" \
    --mirror-root "$MIRROR_ROOT" \
    --ubuntu-root "$UBUNTU_ROOT" \
    --public-base-url "$PUBLIC_BASE_URL" \
    --meta-release-url "$META_RELEASE_URL" \
    --upgrader-dists "$UPGRADER_DISTS" \
    --meta-chain-dists "$META_CHAIN_DISTS" \
    --keyring "$UBUNTU_KEYRING" \
    --allowed-hosts "$(allowlist_hosts)" \
    --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
    --max-time "${CURL_MAX_TIME}" \
    --retries "${CURL_RETRIES}" \
    --result-json "$result_json" \
    "$@" 2>&1 | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

sync_release_upgraders_py() {
  run_release_upgraders_tool sync
}

validate_release_upgraders_py() {
  local -a extra=()
  if systemctl is-active --quiet nginx 2>/dev/null; then
    extra+=(--http-base "${VERIFY_HTTP_BASE}")
  fi
  run_release_upgraders_tool validate "${extra[@]}"
}

validate_security_compat() {
  local py
  local -a args
  py="$(resolve_validate_security_py)" || {
    warn "validate_security_compat.py not found — skipping security compat check"
    return 0
  }
  require_cmds python3
  mkdir -p "$OFFLINE_DIR"
  args=(
    --mirror-root "$MIRROR_ROOT"
    --ubuntu-root "$UBUNTU_ROOT"
    --require-by-hash
    --result-json "${OFFLINE_DIR}/security-validation.json"
  )
  if systemctl is-active --quiet nginx 2>/dev/null; then
    args+=(--http-base "${VERIFY_HTTP_BASE}")
  fi
  if [[ -d "${PROJECT_ROOT}/artifacts/upgrade-discovery" ]]; then
    args+=(--discovery-root "${PROJECT_ROOT}/artifacts/upgrade-discovery")
  fi
  info "security repository compatibility check"
  set +e
  python3 "$py" "${args[@]}" 2>&1 | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

run_legacy_releases_tool() {
  local cmd="$1"
  shift || true
  local py
  py="$(resolve_sync_legacy_releases_py)" || die "sync_legacy_releases.py not found"
  require_cmds python3
  mkdir -p "$OFFLINE_DIR"
  local -a args=(
    "$cmd"
    --mirror-root "$MIRROR_ROOT"
    --ubuntu-root "$UBUNTU_ROOT"
    --series xenial
    --target-series bionic
    --suite-suffixes "$SUITE_SUFFIXES"
    --components "$COMPONENTS"
    --arch "$DEFAULT_ARCH"
    --connect-timeout "${CURL_CONNECT_TIMEOUT}"
    --max-time "${CURL_MAX_TIME}"
    --retries "${CURL_RETRIES}"
    --result-json "${OFFLINE_DIR}/legacy-release-validation.json"
    --xenial-result-json "${OFFLINE_DIR}/xenial-validation.json"
  )
  if [[ -d "${PROJECT_ROOT}/artifacts/upgrade-discovery" ]]; then
    args+=(--discovery-root "${PROJECT_ROOT}/artifacts/upgrade-discovery")
  fi
  info "legacy-releases ${cmd}: starting (result -> ${OFFLINE_DIR}/legacy-release-validation.json)"
  set +e
  python3 "$py" "${args[@]}" "$@" 2>&1 | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

sync_legacy_releases_py() {
  run_legacy_releases_tool sync-validate
}

validate_legacy_releases_py() {
  run_legacy_releases_tool validate
}

restore_legacy_releases_py() {
  run_legacy_releases_tool restore-live
}

apt_update_test_release() {
  local release="$1"
  local work
  work="$(mktemp -d "${TMP_DIR}/apt-${release}.XXXXXX")"
  mkdir -p "${work}/etc/apt/apt.conf.d" "${work}/etc/apt/preferences.d" \
           "${work}/var/lib/apt/lists/partial" "${work}/var/cache/apt/archives/partial" \
           "${work}/var/lib/dpkg" "${work}/etc/apt/trusted.gpg.d"
  chmod -R a+rwX "$work"

  if [[ -f "$UBUNTU_KEYRING" ]]; then
    cp -f "$UBUNTU_KEYRING" "${work}/etc/apt/trusted.gpg.d/ubuntu-archive-keyring.gpg"
  fi
  : >"${work}/var/lib/dpkg/status"
  : >"${work}/etc/apt/apt.conf"

  # Disable optional index targets not required for package lookup (dep11/cnf/icons).
  # Full apt-mirror sync still downloads them for client use; verify focuses on Packages.
  cat >"${work}/etc/apt/apt.conf.d/99-uom-verify" <<'EOF'
Acquire::Languages "none";
Acquire::IndexTargets::deb::DEP-11::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons-small::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons-large::DefaultEnabled "false";
Acquire::IndexTargets::deb::CNF::DefaultEnabled "false";
EOF

  cat >"${work}/etc/apt/sources.list" <<EOF
deb [arch=amd64] ${VERIFY_HTTP_BASE}/ubuntu ${release} ${COMPONENTS}
deb [arch=amd64] ${VERIFY_HTTP_BASE}/ubuntu ${release}-updates ${COMPONENTS}
deb [arch=amd64] ${VERIFY_HTTP_BASE}/ubuntu ${release}-security ${COMPONENTS}
deb [arch=amd64] ${VERIFY_HTTP_BASE}/ubuntu ${release}-backports ${COMPONENTS}
EOF

  local apt_opts=(
    -o "Dir=${work}"
    -o "Dir::State=${work}/var/lib/apt"
    -o "Dir::Cache=${work}/var/cache/apt"
    -o "Dir::Etc=${work}/etc/apt"
    -o "Dir::Etc::sourcelist=${work}/etc/apt/sources.list"
    -o "Dir::Etc::sourceparts=-"
    -o "Dir::Etc::parts=${work}/etc/apt/apt.conf.d"
    -o "Dir::Etc::main=${work}/etc/apt/apt.conf"
    -o "Dir::Etc::preferences=${work}/etc/apt/preferences"
    -o "Dir::Etc::preferencesparts=${work}/etc/apt/preferences.d"
    -o "Dir::State::status=${work}/var/lib/dpkg/status"
    -o "Acquire::Check-Valid-Until=false"
    -o "Acquire::Languages=none"
    -o "APT::Get::List-Cleanup=true"
    -o "APT::Sandbox::User=root"
  )

  local update_log="${work}/apt-update.log"
  set +e
  apt-get "${apt_opts[@]}" update -qq >"$update_log" 2>&1
  local urc=$?
  set -e

  # Prefer success; if apt still complains about optional indexes, continue when
  # InRelease/Packages were clearly acquired for the base suite.
  if [[ "$urc" -ne 0 ]]; then
    if ! ls "${work}/var/lib/apt/lists/"*"_dists_${release}_InRelease" >/dev/null 2>&1 \
      && ! ls "${work}/var/lib/apt/lists/"*"_dists_${release}_Release" >/dev/null 2>&1; then
      error "apt-get update failed for ${release}"
      cat "$update_log" >&2 || true
      return 1
    fi
    # Hard-fail only when Packages indexes are missing
    if ! ls "${work}/var/lib/apt/lists/"*"_dists_${release}_"*"_binary-amd64_Packages"* >/dev/null 2>&1; then
      error "apt-get update failed for ${release} (no Packages lists)"
      cat "$update_log" >&2 || true
      return 1
    fi
    warn "apt-get update for ${release} reported errors but core indexes are present; continuing package queries"
  fi

  local pkg
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    if ! apt-cache "${apt_opts[@]}" show "$pkg" >/dev/null 2>&1; then
      if zgrep -h "^Package: ${pkg}$" "${DIST_ROOT}/${release}"/*/binary-amd64/Packages* 2>/dev/null \
        | head -1 | grep -q .; then
        error "Package ${pkg} present in Packages but not visible via apt-cache (${release})"
        return 1
      fi
      error "Required package missing for ${release}: ${pkg}"
      return 1
    fi
  done < <(uom_required_packages_for "$release")

  ok "Isolated apt-get update + package query OK: ${release}"
  return 0
}

verify_apt_all_releases() {
  local r rc=0
  require_cmds apt-get apt-cache
  for r in $UBUNTU_RELEASES; do
    apt_update_test_release "$r" || rc=1
  done
  return "$rc"
}

# ---------------------------------------------------------------------------
# Manifests
# ---------------------------------------------------------------------------
write_sha256sums() {
  info "Writing SHA256SUMS"
  local tmp
  tmp="$(mktemp "${TMP_DIR}/sha.XXXXXX")"
  {
    [[ -f "$META_LOCAL" ]] && printf '%s  %s\n' "$(uom_file_sha256 "$META_LOCAL")" "offline/meta-release-lts"
    [[ -f "$META_UPSTREAM" ]] && printf '%s  %s\n' "$(uom_file_sha256 "$META_UPSTREAM")" "offline/meta-release-lts.upstream"
    local dist
    for dist in $UPGRADER_DISTS; do
      local t s
      t="$(upgrader_dir_for "$dist")/${dist}.tar.gz"
      s="$(upgrader_dir_for "$dist")/${dist}.tar.gz.gpg"
      [[ -f "$t" ]] && printf '%s  %s\n' "$(uom_file_sha256 "$t")" "ubuntu/dists/${dist}-updates/main/dist-upgrader-all/current/${dist}.tar.gz"
      [[ -f "$s" ]] && printf '%s  %s\n' "$(uom_file_sha256 "$s")" "ubuntu/dists/${dist}-updates/main/dist-upgrader-all/current/${dist}.tar.gz.gpg"
    done
    if [[ -f /etc/apt/mirror.list ]]; then
      printf '%s  %s\n' "$(uom_file_sha256 /etc/apt/mirror.list)" "etc/apt/mirror.list"
    fi
    if [[ -f /etc/default/ubuntu-offline-mirror ]]; then
      printf '%s  %s\n' "$(uom_file_sha256 /etc/default/ubuntu-offline-mirror)" "etc/default/ubuntu-offline-mirror"
    fi
  } >"$tmp"
  mv -f "$tmp" "$SHA256SUMS"
  ok "Wrote $SHA256SUMS"
}

write_manifest() {
  info "Writing manifest.json"
  local tmp pkg_count total_bytes
  tmp="$(mktemp "${TMP_DIR}/man.XXXXXX")"
  pkg_count=0
  total_bytes=0
  if [[ -d "$UBUNTU_ROOT" ]]; then
    pkg_count="$(find "$UBUNTU_ROOT" -type f -name '*.deb' 2>/dev/null | wc -l | tr -d ' ')"
    total_bytes="$(du -sb "$MIRROR_ROOT" 2>/dev/null | awk '{print $1}')"
  fi

  # Build file inventory for offline + upgrader + key suite metadata (not all debs)
  local files_json="["
  local first=1
  local f rel size mtime ftype
  while IFS= read -r -d '' f; do
    rel="${f#"$MIRROR_ROOT"/}"
    size="$(stat -c%s "$f")"
    mtime="$(stat -c%Y "$f")"
    ftype="$(file -b --mime-type "$f" 2>/dev/null || echo unknown)"
    if [[ "$first" -eq 1 ]]; then first=0; else files_json+=","; fi
    files_json+=$(jq -nc --arg p "$rel" --argjson s "$size" --argjson m "$mtime" --arg t "$ftype" \
      '{path:$p,size:$s,mtime:$m,type:$t}')
  done < <(
    {
      find "$OFFLINE_DIR" -type f \( -name 'meta-release-lts*' -o -name 'READY*' -o -name 'FROZEN*' \
        -o -name 'manifest.json' -o -name 'SHA256SUMS' -o -name 'snapshot.json' -o -name 'last-sync.json' \) -print0 2>/dev/null
      local dist
      for dist in $UPGRADER_DISTS; do
        find "$(upgrader_dir_for "$dist")" -maxdepth 1 -type f -print0 2>/dev/null
      done
      # shellcheck disable=SC2086
      while IFS= read -r suite; do
        for f in InRelease Release Release.gpg; do
          [[ -f "${DIST_ROOT}/${suite}/${f}" ]] && printf '%s\0' "${DIST_ROOT}/${suite}/${f}"
        done
      done < <(uom_all_suites "$UBUNTU_RELEASES" "$SUITE_SUFFIXES")
    }
  )

  files_json+="]"

  local suites_json="["
  first=1
  local suite vu
  # shellcheck disable=SC2086
  while IFS= read -r suite; do
    vu="$(valid_until_of_suite "$suite")"
    if [[ "$first" -eq 1 ]]; then first=0; else suites_json+=","; fi
    suites_json+=$(jq -nc --arg s "$suite" --arg v "$vu" '{suite:$s,"valid_until":$v}')
  done < <(uom_all_suites "$UBUNTU_RELEASES" "$SUITE_SUFFIXES")
  suites_json+="]"

  jq -n \
    --arg generated "$(iso_now)" \
    --arg hostname "$(hostname -f 2>/dev/null || hostname)" \
    --arg public "$PUBLIC_BASE_URL" \
    --arg arch "$DEFAULT_ARCH" \
    --arg releases "$UBUNTU_RELEASES" \
    --arg snapshot "${SNAPSHOT_ID:-}" \
    --argjson packages "$pkg_count" \
    --argjson bytes "${total_bytes:-0}" \
    --argjson files "$files_json" \
    --argjson suites "$suites_json" \
    '{
      generated_at: $generated,
      hostname: $hostname,
      public_base_url: $public,
      architecture: $arch,
      releases: ($releases|split(" ")),
      snapshot_id: $snapshot,
      package_count: $packages,
      total_bytes: $bytes,
      suites: $suites,
      files: $files,
      excluded: [
        "i386 packages",
        "source packages (deb-src)",
        "Ubuntu Pro/ESM",
        "PPAs",
        "Docker CE external repos",
        "NVIDIA/CUDA external repos",
        "Snap packages",
        "Vendor-specific private APT repos"
      ]
    }' >"$tmp"
  mv -f "$tmp" "$MANIFEST_JSON"
  ok "Wrote $MANIFEST_JSON"
}

write_ready_marker() {
  local pkg_count total_h req_sum content_sum profile_name schema_ver
  pkg_count="$(find "$UBUNTU_ROOT" -type f -name '*.deb' 2>/dev/null | wc -l | tr -d ' ')"
  total_h="$(du -sh "$MIRROR_ROOT" 2>/dev/null | awk '{print $1}')"
  profile_name="offline-upgrade-full"
  schema_ver="1"
  req_sum=""
  content_sum=""
  local req_json="${PROJECT_ROOT}/artifacts/upgrade-discovery/analysis/offline-upgrade-requirements.json"
  if [[ -f "$req_json" ]]; then
    req_sum="$(sha256sum "$req_json" 2>/dev/null | awk '{print $1}')"
  fi
  if [[ -d "${DIST_ROOT}" ]]; then
    content_sum="$(
      find "$DIST_ROOT" -maxdepth 2 \( -name InRelease -o -name Release \) -type f -printf '%P %s %T@\n' 2>/dev/null \
        | sort | sha256sum | awk '{print $1}'
    )"
  fi
  local profile_json
  profile_json="$(resolve_upgrade_profile_json 2>/dev/null || true)"
  if [[ -n "$profile_json" ]] && command -v python3 >/dev/null 2>&1; then
    profile_name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("profile_name","offline-upgrade-full"))' "$profile_json" 2>/dev/null || echo offline-upgrade-full)"
    schema_ver="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("schema_version",1))' "$profile_json" 2>/dev/null || echo 1)"
  fi
  local xenial_id="" meta_id=""
  if [[ -f "${OFFLINE_DIR}/xenial-validation.json" ]]; then
    xenial_id="$(jq -r '.active_snapshot_id // .snapshot_id // empty' "${OFFLINE_DIR}/xenial-validation.json" 2>/dev/null || true)"
  fi
  if [[ -f "${OFFLINE_DIR}/release-upgrader-validation.json" ]]; then
    meta_id="$(jq -r '.meta_release_snapshot_id // .snapshot_id // empty' "${OFFLINE_DIR}/release-upgrader-validation.json" 2>/dev/null || true)"
  fi
  mkdir -p "$OFFLINE_DIR"
  cat >"$READY_MARKER" <<EOF
generated_at=$(iso_now)
sync_started=${SYNC_STARTED}
sync_ended=${SYNC_ENDED:-$(iso_now)}
hostname=$(hostname -f 2>/dev/null || hostname)
public_base_url=${PUBLIC_BASE_URL}
architecture=${DEFAULT_ARCH}
releases=${UBUNTU_RELEASES}
upgrader_dists=${UPGRADER_DISTS}
total_size=${total_h}
package_count=${pkg_count}
upgrader_gpg=verified
manifest=${MANIFEST_JSON}
sha256sums=${SHA256SUMS}
snapshot_id=${SNAPSHOT_ID}
profile_name=${profile_name}
schema_version=${schema_ver}
overall=READY
requirement_manifest_checksum=${req_sum}
mirror_content_manifest_checksum=${content_sum}
active_xenial_snapshot_id=${xenial_id}
meta_release_snapshot_id=${meta_id}
gate_repository_profile=PASS
gate_repository_payload=PASS
gate_by_hash=PASS
gate_security_compat=PASS
gate_release_upgraders=PASS
gate_legacy_xenial=PASS
EOF
  # Keep mirrorctl/state markers in sync with offline READY
  mkdir -p /var/lib/ubuntu-mirror 2>/dev/null || true
  date -Is >/var/lib/ubuntu-mirror/ready 2>/dev/null || true
  date -Is >/var/lib/ubuntu-mirror/initial-sync-complete 2>/dev/null || true
  rm -f /var/lib/ubuntu-mirror/sync-failed /var/lib/ubuntu-mirror/sync-started 2>/dev/null || true
  ok "READY marker written: $READY_MARKER"
}

# ---------------------------------------------------------------------------
# apt-mirror
# ---------------------------------------------------------------------------
run_apt_mirror() {
  if [[ "${SKIP_APT_MIRROR}" == "true" ]]; then
    warn "SKIP_APT_MIRROR=true — skipping apt-mirror"
    return 0
  fi
  require_cmds apt-mirror
  info "Starting apt-mirror"
  local rc
  set +e
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL /usr/bin/apt-mirror 2>&1 | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}
  else
    /usr/bin/apt-mirror 2>&1 | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}
  fi
  set -e
  return "$rc"
}

maybe_run_clean() {
  if [[ "${RUN_CLEAN}" != "true" ]]; then
    info "RUN_CLEAN=false — skipping clean.sh"
    return 0
  fi
  local clean="${VAR_PATH}/clean.sh"
  if [[ ! -x "$clean" ]] && [[ ! -f "$clean" ]]; then
    warn "clean.sh not found at $clean — skipping"
    return 0
  fi
  info "Running clean.sh"
  local rc
  set +e
  bash "$clean" 2>&1 | tee -a "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

# ---------------------------------------------------------------------------
# Supplemental by-hash sync / validate / stale cleanup
# ---------------------------------------------------------------------------
resolve_sync_by_hash_py() {
  local cand
  for cand in \
    "${PROJECT_ROOT}/scripts/lib/sync_by_hash.py" \
    "/usr/local/lib/ubuntu-mirror/sync_by_hash.py" \
    "${SCRIPT_DIR}/lib/sync_by_hash.py"
  do
    if [[ -f "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

run_by_hash_tool() {
  local cmd="$1"
  shift
  local py
  py="$(resolve_sync_by_hash_py)" || die "sync_by_hash.py not found"
  require_cmds python3
  local result_json="${OFFLINE_DIR}/by-hash-${cmd}.json"
  case "$cmd" in
    sync-validate) result_json="${OFFLINE_DIR}/by-hash-validation.json" ;;
    validate) result_json="${OFFLINE_DIR}/by-hash-validation.json" ;;
    sync) result_json="${OFFLINE_DIR}/by-hash-sync.json" ;;
    cleanup) result_json="${OFFLINE_DIR}/by-hash-cleanup.json" ;;
  esac
  mkdir -p "$OFFLINE_DIR"
  info "by-hash ${cmd}: starting (result -> ${result_json})"
  set +e
  python3 "$py" "$cmd" \
    --mirror-root "$MIRROR_ROOT" \
    --ubuntu-root "$UBUNTU_ROOT" \
    --upstream-base-url "$UPSTREAM_BASE_URL" \
    --default-arch "${DEFAULT_ARCH}" \
    --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
    --max-time "${CURL_MAX_TIME}" \
    --retries "${CURL_RETRIES}" \
    --result-json "$result_json" \
    "$@" 2>&1 | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

sync_by_hash_indexes() {
  run_by_hash_tool sync
}

validate_by_hash_indexes() {
  run_by_hash_tool validate
}

# Sync + validate + safe stale cleanup (only removes unreferenced by-hash files)
sync_validate_cleanup_by_hash() {
  run_by_hash_tool sync-validate
}

# ---------------------------------------------------------------------------
# Selective mirror paths / helpers
# ---------------------------------------------------------------------------
SELECTIVE_MIRROR_ROOT="${SELECTIVE_MIRROR_ROOT:-${MIRROR_ROOT}/selective}"
FULL_MIRROR_SEED_ROOT="${FULL_MIRROR_SEED_ROOT:-${MIRROR_PATH}}"
DISCOVERY_ROOT="${DISCOVERY_ROOT:-${PROJECT_ROOT}/artifacts/upgrade-discovery}"
SELECTIVE_PLAN="${SELECTIVE_PLAN:-${DISCOVERY_ROOT}/analysis/selective-mirror-plan.json}"

resolve_selective_mirror_py() {
  local cand
  for cand in \
    "${PROJECT_ROOT}/scripts/lib/selective_mirror.py" \
    "/usr/local/lib/ubuntu-mirror/selective_mirror.py"
  do
    [[ -f "$cand" ]] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

resolve_validate_selective_py() {
  local cand
  for cand in \
    "${PROJECT_ROOT}/scripts/lib/validate_selective_mirror.py" \
    "/usr/local/lib/ubuntu-mirror/validate_selective_mirror.py"
  do
    [[ -f "$cand" ]] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

resolve_build_selective_plan_py() {
  local cand
  for cand in \
    "${PROJECT_ROOT}/scripts/build-selective-mirror-plan.py" \
    "/usr/local/lib/ubuntu-mirror/build-selective-mirror-plan.py"
  do
    [[ -f "$cand" ]] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

# Write refresh-hop-selective orchestration state (diagnostic / resume).
_uom_write_refresh_state() {
  local phase="$1"
  local hop="${2:-}"
  local failure_code="${3:-}"
  local failure_summary="${4:-}"
  local state_dir="${SELECTIVE_MIRROR_ROOT}/state"
  local out="${state_dir}/refresh-orchestration.json"
  local tmp="${out}.tmp.$$"
  local plan_ck="" disc_ck="" started="" pub_gen=""
  mkdir -p "$state_dir" 2>/dev/null || true
  if [[ -f "$SELECTIVE_PLAN" ]]; then
    plan_ck="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('plan_checksum') or '')" "$SELECTIVE_PLAN" 2>/dev/null || true)"
    disc_ck="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('discovery_artifact_checksum') or '')" "$SELECTIVE_PLAN" 2>/dev/null || true)"
  fi
  if [[ -f "$out" ]]; then
    started="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('started_at') or '')" "$out" 2>/dev/null || true)"
  fi
  [[ -n "$started" ]] || started="$(iso_now)"
  if [[ -d "${SELECTIVE_MIRROR_ROOT}/published" ]]; then
    pub_gen="$(readlink -f "${SELECTIVE_MIRROR_ROOT}/published" 2>/dev/null || printf '%s' "${SELECTIVE_MIRROR_ROOT}/published")"
  fi
  if ! python3 -c "
import json, sys, datetime, os
out, phase, hop, started, plan_ck, disc_ck, staging, pub_gen, fcode, fsum = sys.argv[1:11]
doc = {
  'command': 'refresh-hop-selective',
  'hop': hop,
  'phase': phase,
  'started_at': started,
  'updated_at': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S+00:00'),
  'plan_checksum': plan_ck,
  'discovery_checksum': disc_ck,
  'staging_root': staging,
  'published_generation': pub_gen,
  'failure_code': fcode,
  'failure_summary': fsum,
}
tmp = out + '.tmp.' + str(os.getpid())
with open(tmp, 'w') as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write('\n')
os.rename(tmp, out)
" "$out" "$phase" "$hop" "$started" "$plan_ck" "$disc_ck" \
    "${SELECTIVE_MIRROR_ROOT}/staging" "$pub_gen" "$failure_code" "$failure_summary" 2>/dev/null; then
    printf '{"command":"refresh-hop-selective","hop":"%s","phase":"%s","updated_at":"%s"}\n' \
      "$hop" "$phase" "$(iso_now)" >"$tmp"
    mv -f "$tmp" "$out" 2>/dev/null || true
  fi
  info "REFRESH_PHASE=${phase}${hop:+ hop=${hop}}"
}

cmd_plan_selective_impl() {
  require_cmds python3
  local py
  py="$(resolve_build_selective_plan_py)" || die "build-selective-mirror-plan.py not found"
  mkdir -p "${DISCOVERY_ROOT}/analysis"
  mkdir -p "${SELECTIVE_MIRROR_ROOT}/state" 2>/dev/null || true

  # Pocket provenance indexes (Packages only — not pool, not publish).
  # Prefer dedicated pocket-indexes tree; fall back to full-mirror seed if present.
  local pocket_root="${POCKET_INDEX_ROOT:-${DISCOVERY_ROOT}/analysis/pocket-indexes/ubuntu}"
  local fetch_py="${PROJECT_ROOT}/scripts/fetch-pocket-packages-indexes.py"
  if [[ ! -f "${pocket_root}/dists/bionic/main/binary-amd64/Packages" ]]; then
    if [[ -f "${FULL_MIRROR_SEED_ROOT}/dists/bionic/main/binary-amd64/Packages" ]] \
       || [[ -f "${FULL_MIRROR_SEED_ROOT}/dists/bionic/main/binary-amd64/Packages.gz" ]]; then
      pocket_root="$FULL_MIRROR_SEED_ROOT"
      log "Using full-mirror seed as pocket-index-root: ${pocket_root}"
    elif [[ -f "$fetch_py" ]]; then
      log "Fetching Packages indexes for pocket provenance → ${pocket_root}"
      python3 "$fetch_py" --out-root "$pocket_root" --series bionic \
        || die "pocket Packages index fetch FAIL (required for provenance; refusing suite=bionic default)"
    else
      die "pocket-index-root missing Packages and fetch helper not found: ${pocket_root}"
    fi
  else
    log "Using pocket-index-root: ${pocket_root}"
  fi

  log "Building selective mirror plan from ${DISCOVERY_ROOT}"
  set +e
  python3 "$py" \
    --discovery-root "$DISCOVERY_ROOT" \
    --seed-root "$FULL_MIRROR_SEED_ROOT" \
    --pocket-index-root "$pocket_root" \
    --output-dir "${DISCOVERY_ROOT}/analysis" \
    --profile-name offline-upgrade-selective
  local rc=$?
  set -e
  if [[ -f "$SELECTIVE_PLAN" ]]; then
    cp -f "$SELECTIVE_PLAN" "${SELECTIVE_MIRROR_ROOT}/state/plan.json" 2>/dev/null || true
  fi
  [[ "$rc" -eq 0 ]] || die "plan-selective FAIL"
  ok "plan-selective PASS → ${SELECTIVE_PLAN}"
}

cmd_plan_selective() {
  # plan is read-mostly; no global lock required for standalone use
  cmd_plan_selective_impl "$@"
}

cmd_materialize_selective_impl() {
  require_cmds python3
  local py hop_arg=() reuse_args=()
  py="$(resolve_selective_mirror_py)" || { error "selective_mirror.py not found"; return 1; }
  [[ -f "$SELECTIVE_PLAN" ]] || { error "plan missing; run plan-selective first: $SELECTIVE_PLAN"; return 1; }
  rm -f "${SELECTIVE_MIRROR_ROOT}/state/READY" 2>/dev/null || true
  local debug_args=()
  if [[ "${SELECTIVE_MIRROR_DEBUG:-${UM_DEBUG:-0}}" =~ ^(1|true|yes|on)$ ]]; then
    debug_args+=(--debug)
  fi
  if [[ -n "${1:-}" ]]; then
    hop_arg+=(--hop "$1")
    info "REQUESTED_HOP=$1"
  fi
  # Optional SHA256-verified reuse roots (e.g. quarantined staging); never moves published.
  local rr
  for rr in ${SELECTIVE_REUSE_ROOTS:-}; do
    [[ -n "$rr" ]] || continue
    reuse_args+=(--reuse-root "$rr")
  done
  # --allow-resume: reuse PASS staging when plan/discovery provenance matches
  # (avoids re-downloading multi-GB trees after orchestration interrupt).
  # --hop limits acquisition to that hop only (does not materialize the full chain).
  python3 "$py" materialize \
    --plan "$SELECTIVE_PLAN" \
    --selective-root "$SELECTIVE_MIRROR_ROOT" \
    --allow-resume \
    "${hop_arg[@]}" \
    "${reuse_args[@]}" \
    "${debug_args[@]}" \
    || { error "materialize-selective FAIL (see stderr and ${SELECTIVE_MIRROR_ROOT}/state/failed-downloads.json)"; return 1; }
  ok "materialize-selective complete (not published)"
  return 0
}

cmd_quarantine_staging_selective_impl() {
  require_cmds python3
  local py evidence_dir="${1:-}"
  py="$(resolve_selective_mirror_py)" || { error "selective_mirror.py not found"; return 1; }
  local args=(quarantine-staging --selective-root "$SELECTIVE_MIRROR_ROOT")
  if [[ -n "$evidence_dir" ]]; then
    args+=(--evidence-dir "$evidence_dir")
  fi
  python3 "$py" "${args[@]}" \
    || { error "quarantine-staging-selective FAIL"; return 1; }
  ok "quarantine-staging-selective PASS (staging renamed; not deleted)"
  return 0
}

cmd_quarantine_staging_selective() {
  acquire_global_lock_once "quarantine-staging-selective" "" "STANDALONE"
  cmd_quarantine_staging_selective_impl "$@" || die "quarantine-staging-selective FAIL"
}

cmd_materialize_selective() {
  acquire_global_lock_once "materialize-selective" "" "STANDALONE"
  cmd_materialize_selective_impl "$@" || die "materialize-selective FAIL"
}

cmd_verify_selective_impl() {
  require_cmds python3
  local py hop="${1:-}"
  py="$(resolve_validate_selective_py)" || { error "validate_selective_mirror.py not found"; return 1; }
  [[ -f "$SELECTIVE_PLAN" ]] || { error "plan missing; run plan-selective first"; return 1; }
  mkdir -p "${SELECTIVE_MIRROR_ROOT}/state" 2>/dev/null || true
  cp -f "$SELECTIVE_PLAN" "${SELECTIVE_MIRROR_ROOT}/state/plan.json" 2>/dev/null || true
  # Pre-publish only: validates staging. Never depends on production nginx
  # or selective/current (those are post-publish smoke tests inside publish-selective).
  local args=(
    --plan "$SELECTIVE_PLAN"
    --selective-root "$SELECTIVE_MIRROR_ROOT"
    --mirror-root "$MIRROR_ROOT"
    --phase pre_publish
    --result-json "${SELECTIVE_MIRROR_ROOT}/state/verify-result.json"
  )
  if [[ -n "$hop" ]]; then
    args+=(--hop "$hop")
    info "VERIFY_HOP=$hop"
  fi
  # Isolated APT against staging file:// repos (default on; set VERIFY_SELECTIVE_APT=0 to skip)
  if [[ "${VERIFY_SELECTIVE_APT:-1}" != "0" ]]; then
    args+=(--run-apt)
  fi
  python3 "$py" "${args[@]}" || { error "verify-selective FAIL (pre-publish / staging)"; return 1; }
  ok "verify-selective PASS (pre-publish; not published; READY not written)"
  return 0
}

cmd_verify_selective() {
  acquire_global_lock_once "verify-selective" "" "STANDALONE"
  cmd_verify_selective_impl "$@" || die "verify-selective FAIL (pre-publish / staging)"
}

cmd_publish_selective_impl() {
  require_cmds python3
  local py
  py="$(resolve_selective_mirror_py)" || { error "selective_mirror.py not found"; return 1; }
  [[ -f "$SELECTIVE_PLAN" ]] || { error "plan missing; run plan-selective first"; return 1; }
  # Atomic publish + post-publish concrete HTTP endpoint smoke + READY
  # Preflight (inside selective_mirror.py): effective nginx root must be
  # SELECTIVE_MIRROR_ROOT/current or SELECTIVE_NGINX_EFFECTIVE_ROOT_MISMATCH.
  python3 "$py" publish \
    --selective-root "$SELECTIVE_MIRROR_ROOT" \
    --plan "$SELECTIVE_PLAN" \
    --http-base "${VERIFY_HTTP_BASE}" \
    || { error "publish-selective FAIL"; return 1; }
  ok "publish-selective complete (post-publish HTTP PASS; READY written)"
  return 0
}

cmd_publish_selective() {
  acquire_global_lock_once "publish-selective" "" "STANDALONE"
  cmd_publish_selective_impl "$@" || die "publish-selective FAIL"
}

cmd_quarantine_hop_selective_impl() {
  # Mark a contaminated hop NOT_READY/QUARANTINED without destroying other hops.
  require_cmds python3
  local hop="${1:-}"
  [[ -n "$hop" ]] || die "usage: quarantine-hop-selective <hop>  (e.g. xenial-to-bionic)"
  PYTHONPATH="${PROJECT_ROOT}/scripts/lib${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -c "
import json, sys
from validate_selective_mirror import quarantine_hop
r = quarantine_hop(sys.argv[1], sys.argv[2], reason='FAIL_SOURCE_SUITE_TARGET_PACKAGE_CONTAMINATION')
print(json.dumps(r, indent=2))
" "$SELECTIVE_MIRROR_ROOT" "$hop" || die "quarantine-hop-selective FAIL"
  ok "quarantine-hop-selective: ${hop} → QUARANTINED (READY cleared; other hops untouched)"
}

cmd_quarantine_hop_selective() {
  cmd_quarantine_hop_selective_impl "$@"
}

cmd_refresh_hop_selective_impl() {
  # Internal: assumes global lock already held. Never re-executes this script / public cmds.
  local hop="${1:-xenial-to-bionic}"
  log "refresh-hop-selective: hop=${hop} (selective only; no full mirror)"
  info "LOCK_MODE=OUTER_ORCHESTRATION"

  # Quarantine existing contaminated publish of this hop before rematerialize.
  if [[ -d "${SELECTIVE_MIRROR_ROOT}/published/hops/${hop}" ]] \
    || [[ -d "${SELECTIVE_MIRROR_ROOT}/current/hops/${hop}" ]]; then
    _uom_write_refresh_state "QUARANTINED" "$hop"
    cmd_quarantine_hop_selective_impl "$hop" || true
  fi

  _uom_write_refresh_state "PLAN_READY" "$hop"
  cmd_plan_selective_impl

  info "REFRESH_PHASE=MATERIALIZE"
  if ! cmd_materialize_selective_impl "$hop"; then
    _uom_write_refresh_state "FAILED" "$hop" "SELECTIVE_MATERIALIZE_FAILED" \
      "materialize-selective failed"
    die "materialize-selective FAIL"
  fi
  _uom_write_refresh_state "MATERIALIZED" "$hop"
  info "REFRESH_PHASE=VERIFY"
  if ! cmd_verify_selective_impl "$hop"; then
    _uom_write_refresh_state "FAILED" "$hop" "SELECTIVE_PREPUBLISH_VERIFY_FAILED" \
      "verify-selective failed; publish skipped; quarantine retained"
    die "verify-selective FAIL — publish skipped; quarantine retained"
  fi
  info "VERIFY_RESULT=PASS"
  _uom_write_refresh_state "VERIFIED" "$hop"

  info "REFRESH_PHASE=PUBLISH"
  if ! cmd_publish_selective_impl; then
    _uom_write_refresh_state "FAILED" "$hop" "SELECTIVE_PUBLISH_FAILED" \
      "publish-selective failed; quarantine retained"
    die "publish-selective FAIL — quarantine retained"
  fi
  info "PUBLISH_RESULT=PASS"
  _uom_write_refresh_state "PUBLISHED" "$hop"
  ok "refresh-hop-selective complete for ${hop} (READY only if verify+publish PASS)"
}

cmd_refresh_hop_selective() {
  # Official single orchestration: one global lock for the entire hop refresh.
  # Calls *_impl only — never re-enters public entry points / re-executes this script.
  local hop="${1:-xenial-to-bionic}"
  acquire_global_lock_once "refresh-hop-selective" "$hop" "OUTER_ORCHESTRATION"
  cmd_refresh_hop_selective_impl "$hop"
}

cmd_migrate_selective_runtime() {
  # Refresh installed CLI/libs/config only. Never touch selective READY/published.
  require_cmds python3 sha256sum
  if [[ "$(id -u)" -ne 0 ]] && [[ "${UM_ALLOW_NONROOT_MIGRATE:-0}" != "1" ]]; then
    die "migrate-selective-runtime requires root (or UM_ALLOW_NONROOT_MIGRATE=1 for tests)"
  fi
  # Prefer checkout that contains this script when invoked from the repo.
  local src_root=""
  if [[ -f "${SCRIPT_DIR}/../scripts/mirrorctl" ]] && [[ -f "${SCRIPT_DIR}/../lib/config.sh" ]]; then
    src_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
  elif [[ -f "${PROJECT_ROOT}/scripts/mirrorctl" ]]; then
    src_root="$PROJECT_ROOT"
  fi
  if [[ -n "$src_root" ]] && [[ -f "${src_root}/lib/config.sh" ]]; then
    # shellcheck source=/dev/null
    source "${src_root}/lib/common.sh"
    # shellcheck source=/dev/null
    source "${src_root}/lib/config.sh"
  elif [[ -f /usr/local/lib/ubuntu-mirror/config.sh ]]; then
    # shellcheck source=/dev/null
    source /usr/local/lib/ubuntu-mirror/common.sh
    # shellcheck source=/dev/null
    source /usr/local/lib/ubuntu-mirror/config.sh
  else
    die "config.sh not found for migrate-selective-runtime"
  fi
  if [[ -z "$src_root" ]]; then
    src_root="$(um_runtime_source_root 2>/dev/null || true)"
  fi
  [[ -n "$src_root" ]] || die "Cannot locate repository checkout (need scripts/mirrorctl). Set /etc/ubuntu-mirror/source-repo"
  UM_PROJECT_ROOT="$src_root"
  um_migrate_selective_runtime "$src_root" || die "migrate-selective-runtime FAIL"
  ok "migrate-selective-runtime complete (selective repository untouched)"
}

cmd_migrate_nginx_selective() {
  # Idempotent legacy → selective nginx site migration (no publish).
  if [[ -f "${PROJECT_ROOT}/lib/config.sh" ]]; then
    # shellcheck source=../lib/config.sh
    source "${PROJECT_ROOT}/lib/common.sh"
    # shellcheck source=../lib/config.sh
    source "${PROJECT_ROOT}/lib/config.sh"
  elif [[ -f /usr/local/lib/ubuntu-mirror/config.sh ]]; then
    # shellcheck source=/dev/null
    source /usr/local/lib/ubuntu-mirror/common.sh
    # shellcheck source=/dev/null
    source /usr/local/lib/ubuntu-mirror/config.sh
  else
    die "config.sh not found for nginx migration"
  fi
  UM_PROJECT_ROOT="${UM_PROJECT_ROOT:-$PROJECT_ROOT}"
  um_load_config "${UM_CONFIG_PATH:-${PROJECT_ROOT}/mirror.conf}" 2>/dev/null || \
    um_load_config "${PROJECT_ROOT}/mirror.conf"
  SELECTIVE_MIRROR_ROOT="${SELECTIVE_MIRROR_ROOT:-${MIRROR_ROOT}/selective}"
  SELECTIVE_NGINX_ROOT="${SELECTIVE_NGINX_ROOT:-${SELECTIVE_MIRROR_ROOT}/current}"
  um_migrate_nginx_selective_site || die "migrate-nginx-selective FAIL"
  local root
  root="$(um_selective_nginx_root)"
  ok "migrate-nginx-selective complete (effective root target: ${root})"
  if command -v nginx >/dev/null 2>&1; then
    nginx -T 2>/dev/null | grep -E '^\s*root\s+' | head -5 || true
  fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_sync() {
  if [[ -f "${PROJECT_ROOT}/lib/upgrade-profile.sh" ]]; then
    # shellcheck source=../lib/upgrade-profile.sh
    source "${PROJECT_ROOT}/lib/upgrade-profile.sh"
    um_load_upgrade_profile 2>/dev/null || true
    if [[ "${UM_UPGRADE_PROFILE_NAME:-}" == "offline-upgrade-selective" ]] || \
       [[ "${UM_UPGRADE_SELECTION_MODE:-}" == "discovery_exact" ]]; then
      um_reject_full_sync_request "UNSUPPORTED_FULL_MIRROR_SYNC" || true
      die "sync blocked under selective profile; use plan-selective → materialize-selective → verify-selective → publish-selective"
    fi
  fi
  die "sync-full-legacy is disabled; existing full mirror seed is preserved at ${FULL_MIRROR_SEED_ROOT:-$MIRROR_PATH}"
}

cmd_sync_full_legacy() {
  die "sync-full-legacy intentionally disabled (no apt-mirror auto-run). Seed preserved."
}

cmd_verify() {
  # Selective profile: verify-selective is the primary gate.
  if [[ -f "${PROJECT_ROOT}/lib/upgrade-profile.sh" ]]; then
    # shellcheck source=../lib/upgrade-profile.sh
    source "${PROJECT_ROOT}/lib/upgrade-profile.sh"
    um_load_upgrade_profile 2>/dev/null || true
    if [[ "${UM_UPGRADE_PROFILE_NAME:-}" == "offline-upgrade-selective" ]] || \
       [[ "${UM_UPGRADE_SELECTION_MODE:-}" == "discovery_exact" ]]; then
      cmd_verify_selective "$@"
      return $?
    fi
  fi
  require_cmds curl gpgv jq sha256sum file apt-get apt-cache python3
  acquire_lock
  TMP_DIR="$(mktemp -d /tmp/uom-XXXXXX)"
  invalidate_ready

  local rc=0
  assert_upgrade_profile_allowed || rc=1
  verify_all_suites_fs || rc=1
  validate_upgrade_profile_gate || rc=1

  if ! validate_by_hash_indexes; then
    error "by-hash validation failed"
    rc=1
  fi

  if ! validate_security_compat; then
    error "security repository compatibility failed"
    rc=1
  fi

  if ! validate_release_upgraders_py; then
    error "release upgrader validation failed"
    rc=1
  fi

  if ! validate_legacy_releases_py; then
    error "legacy release validation failed"
    rc=1
  fi

  if ! systemctl is-active --quiet nginx 2>/dev/null; then
    error "nginx is not active — verify requires local HTTP"
    rc=1
  else
    # Temporarily treat missing manifest as regenerable
    write_sha256sums
    write_manifest
    verify_http_endpoints || rc=1
    verify_apt_all_releases || rc=1
  fi

  if [[ "$rc" -ne 0 ]]; then
    die "verify failed — READY not written (overall=BLOCKED)"
  fi

  SYNC_STARTED="$(jq -r '.started // empty' "$SYNC_STATE" 2>/dev/null || true)"
  SYNC_ENDED="$(iso_now)"
  SNAPSHOT_ID="$(jq -r '.snapshot_id // empty' "$SYNC_STATE" 2>/dev/null || true)"
  [[ -n "$SNAPSHOT_ID" ]] || SNAPSHOT_ID="verify-$(date +%Y%m%d-%H%M%S)"
  write_ready_marker
  ok "verify passed — READY refreshed"
}

cmd_sync_by_hash() {
  require_cmds python3 curl sha256sum
  acquire_lock
  TMP_DIR="$(mktemp -d /tmp/uom-XXXXXX)"
  mkdir -p "$OFFLINE_DIR"
  sync_by_hash_indexes || die "by-hash sync failed"
  ok "by-hash sync complete"
}

cmd_validate_by_hash() {
  require_cmds python3 sha256sum
  acquire_lock
  TMP_DIR="$(mktemp -d /tmp/uom-XXXXXX)"
  mkdir -p "$OFFLINE_DIR"
  validate_by_hash_indexes || die "by-hash validation failed"
  ok "by-hash validation PASS"
}

cmd_status() {
  echo "=== Ubuntu Offline Mirror Status (selective) ==="
  echo "Hostname:        $(hostname -f 2>/dev/null || hostname)"
  echo "PUBLIC_BASE_URL: $PUBLIC_BASE_URL"
  echo "MIRROR_ROOT:     $MIRROR_ROOT"
  echo "SELECTIVE_ROOT:  ${SELECTIVE_MIRROR_ROOT}"
  echo "SEED_ROOT:       ${FULL_MIRROR_SEED_ROOT}"
  echo "Mount:           $(path_fs_target "$MIRROR_ROOT") <- $(path_fs_source "$MIRROR_ROOT")"
  echo "Disk:            $(df -h "$MIRROR_ROOT" 2>/dev/null | awk 'NR==2 {printf "used=%s avail=%s (%s)", $3,$4,$5}')"
  local profile_name="offline-upgrade-selective"
  if [[ -f "${PROJECT_ROOT}/lib/upgrade-profile.sh" ]]; then
    # shellcheck source=../lib/upgrade-profile.sh
    source "${PROJECT_ROOT}/lib/upgrade-profile.sh"
    um_load_upgrade_profile 2>/dev/null || true
    profile_name="${UM_UPGRADE_PROFILE_NAME:-$profile_name}"
  fi
  echo "profile_name:    $profile_name"
  if [[ -f "$SELECTIVE_PLAN" ]]; then
    python3 - "$SELECTIVE_PLAN" "${SELECTIVE_MIRROR_ROOT}" <<'PY' 2>/dev/null || true
import json, os, sys
plan=json.load(open(sys.argv[1]))
root=sys.argv[2]
state=os.path.join(root,'state')
c=plan.get('counts') or {}
s=plan.get('sizes') or {}

def load_first(*names):
    for n in names:
        p=os.path.join(state,n)
        if os.path.isfile(p):
            return json.load(open(p))
    return {}

mat=load_first('materialize.json')
ver=load_first('verify-result.json','verify.json')
pub=load_first('publish-result.json','publish.json')
failed=load_first('failed-downloads.json')
stats=mat.get('stats') or {}
expected=int(c.get('unique_deb_sha256') or 0)
downloaded=int(stats.get('downloaded') or 0)
exists=int(stats.get('exists') or 0)
reused=int(stats.get('hardlink') or 0)+int(stats.get('reflink') or 0)+int(stats.get('copy') or 0)
verified='NOT_RUN'
if ver:
    verified=ver.get('verified_files', ver.get('verified_deb_count', ver.get('validation_result')))
pre=ver.get('validation_result') if ver else 'NOT_RUN'
pub_st=pub.get('validation_result') if pub else 'NOT_RUN'
post='NOT_RUN'
if pub:
    post=(pub.get('gates') or {}).get('post_publish_http') or pub.get('validation_result') or 'NOT_RUN'
ready=os.path.isfile(os.path.join(state,'READY'))
cur=os.path.join(root,'current')
cur_tgt=os.readlink(cur) if os.path.islink(cur) else ('published' if os.path.isdir(os.path.join(root,'published')) else '-')
last_err='-'
if failed.get('error_code') or failed.get('exception_message'):
    last_err=failed.get('error_code') or failed.get('exception_message')
elif pub.get('errors'):
    last_err=pub['errors'][0]
elif ver.get('errors'):
    last_err=ver['errors'][0]
print('plan_validation:        %s' % plan.get('validation_result'))
print('materialize:            %s' % (mat.get('validation_result') or 'NOT_RUN'))
print('pre_publish_verify:     %s' % pre)
print('publish:                %s' % pub_st)
print('post_publish_http:      %s' % post)
print('READY:                  %s' % ('YES' if ready else 'NO'))
print('current_published:      %s' % cur_tgt)
print('rollback_status:        %s' % (pub.get('rollback_result') or ('performed' if pub.get('rollback_performed') else 'none')))
print('plan_checksum:          %s' % (plan.get('plan_checksum') or ver.get('plan_checksum') or ver.get('selective_plan_checksum') or '-'))
print('discovery_checksum:     %s' % (plan.get('discovery_artifact_checksum') or ver.get('discovery_artifact_checksum') or '-'))
print('last_error:             %s' % last_err)
print('expected_file_count:    %s' % expected)
print('downloaded_count:       %s' % downloaded)
print('verified_count:         %s' % verified)
print('skipped_existing_count: %s' % exists)
print('reused_seed_count:      %s' % reused)
print('failed_count:           %s' % (1 if failed else 0))
print('unresolved_count:       %s' % c.get('unresolved_deb_payloads'))
print('downloaded_bytes:       %s' % stats.get('bytes_downloaded', s.get('download_bytes')))
print('total_expected_bytes:   %s' % s.get('unique_deb_bytes'))
print('selected_package_count: %s' % c.get('unique_packages_by_name_arch_version'))
print('validation_result:      %s' % (ver.get('validation_result') or plan.get('validation_result')))
PY
  else
    echo "plan:             missing (run plan-selective)"
  fi
  if [[ -d "${SELECTIVE_MIRROR_ROOT}/published" ]]; then
    echo "published size:  $(du -sh "${SELECTIVE_MIRROR_ROOT}/published" 2>/dev/null | awk '{print $1}')"
  elif [[ -d "${SELECTIVE_MIRROR_ROOT}/staging" ]]; then
    echo "staging size:    $(du -sh "${SELECTIVE_MIRROR_ROOT}/staging" 2>/dev/null | awk '{print $1}')"
  fi
  if [[ -d "$FULL_MIRROR_SEED_ROOT" ]]; then
    echo "seed present:    yes (preserved; not deleted by automation)"
  else
    echo "seed present:    no"
  fi
  echo "nginx:           $(systemctl is-active nginx 2>/dev/null || echo unknown)"
  if systemctl list-timers apt-mirror.timer --no-pager 2>/dev/null | grep -q apt-mirror; then
    echo "Timer:           present (should be disabled under selective profile)"
    echo "Timer enabled:   $(systemctl is-enabled apt-mirror.timer 2>/dev/null || echo unknown)"
  else
    echo "Timer:           not registered / inactive"
  fi
}

cmd_freeze() {
  require_cmds curl gpgv jq
  acquire_lock
  TMP_DIR="$(mktemp -d /tmp/uom-XXXXXX)"

  if pgrep -f '/usr/bin/apt-mirror' >/dev/null 2>&1; then
    die "Refuse freeze: apt-mirror process is running"
  fi
  if systemctl is-active --quiet apt-mirror.service 2>/dev/null; then
    die "Refuse freeze: apt-mirror.service is active"
  fi

  info "freeze: running verify first"
  # Release lock before nested verify? We hold lock — call verify internals directly
  invalidate_ready
  local rc=0
  assert_upgrade_profile_allowed || rc=1
  verify_all_suites_fs || rc=1
  validate_upgrade_profile_gate || rc=1
  validate_by_hash_indexes || rc=1
  validate_security_compat || rc=1
  validate_release_upgraders_py || rc=1
  validate_legacy_releases_py || rc=1
  if systemctl is-active --quiet nginx; then
    write_sha256sums
    write_manifest
    verify_http_endpoints || rc=1
    verify_apt_all_releases || rc=1
  else
    error "nginx inactive"
    rc=1
  fi
  [[ "$rc" -eq 0 ]] || die "freeze aborted: verify failed"

  info "Disabling apt-mirror.timer"
  systemctl stop apt-mirror.timer 2>/dev/null || true
  systemctl disable apt-mirror.timer 2>/dev/null || true

  SNAPSHOT_ID="freeze-$(date +%Y%m%d-%H%M%S)"
  SYNC_STARTED="$(jq -r '.started // empty' "$SYNC_STATE" 2>/dev/null || true)"
  SYNC_ENDED="$(iso_now)"
  write_sha256sums
  write_manifest
  write_ready_marker

  jq -n \
    --arg id "$SNAPSHOT_ID" \
    --arg at "$(iso_now)" \
    --arg host "$(hostname -f 2>/dev/null || hostname)" \
    --arg public "$PUBLIC_BASE_URL" \
    --arg size "$(du -sh "$MIRROR_ROOT" 2>/dev/null | awk '{print $1}')" \
    '{snapshot_id:$id,frozen_at:$at,hostname:$host,public_base_url:$public,mirror_size:$size,ready:true}' \
    >"$SNAPSHOT_INFO"

  cat >"$FROZEN_MARKER" <<EOF
frozen_at=$(iso_now)
snapshot_id=${SNAPSHOT_ID}
public_base_url=${PUBLIC_BASE_URL}
hostname=$(hostname -f 2>/dev/null || hostname)
timer=disabled
note=Mirror is frozen for closed-network transfer. Re-enable timer only after unfreeze on an internet-connected host.
EOF

  echo
  ok "FROZEN — mirror is ready to disconnect from the internet and move"
  echo "  READY:   $READY_MARKER"
  echo "  FROZEN:  $FROZEN_MARKER"
  echo "  Snapshot:$SNAPSHOT_INFO"
  echo "  Timer:   disabled"
}

cmd_sha256_all() {
  # Optional full-tree SHA256 (expensive) — not part of default sync
  require_cmds sha256sum find
  local out="${1:-${OFFLINE_DIR}/SHA256SUMS.all}"
  info "Computing full-tree SHA256 (this may take a long time) -> $out"
  mkdir -p "$(dirname "$out")"
  local tmp
  tmp="$(mktemp)"
  (
    cd "$MIRROR_ROOT"
    find . -type f -print0 | sort -z | xargs -0 sha256sum
  ) >"$tmp"
  mv -f "$tmp" "$out"
  ok "Wrote $out"
}

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} <command>

Primary (fresh Ubuntu 24.04 Mirror Manager workflow):
  mirror-manager          Interactive whiptail manager (R2 OS Core + ACPS Phase 2)
  enable-http             Enable nginx HTTP distribution (non-interactive)
  verify-readiness        Print UPGRADE_READINESS (non-interactive)

  Bootstrap a clean host with: sudo ./install.sh
  Re-open GUI after install:   sudo ubuntu-offline-mirror mirror-manager

Client script builders (optional / development):
  build-client-xenial-to-bionic
  build-client-bionic-to-focal
  build-client-focal-to-jammy
  build-client-jammy-to-noble

Legacy selective tooling (not the default install path):
  plan-selective / materialize-selective / verify-selective / publish-selective
  quarantine-staging-selective / quarantine-hop-selective / refresh-hop-selective
  migrate-nginx-selective / migrate-selective-runtime / status
  sync-dp-phase2 / verify-dp-phase2 / status-dp-phase2
  check-profile / validate-profile / migrate-profile
  sync-release-upgraders / validate-release-upgraders
  sync-legacy-releases / validate-legacy-releases / freeze-xenial-snapshot
  sync-by-hash / validate-by-hash / freeze / sha256-all

Blocked:
  sync                      UNSUPPORTED_FULL_MIRROR_SYNC
  sync-full-legacy          Disabled

Config: /etc/default/ubuntu-offline-mirror
Mirror root: ${SELECTIVE_MIRROR_ROOT}
EOF
}

# Resolve the mirror base every generated client is pinned to.
# Precedence: explicit --mirror-base / PUBLIC_BASE_URL when it names a real host,
# then the persisted Mirror Manager URL, then authoritative host IPv4 detection.
# Never falls back to a hardcoded address; prints the resolved base on stdout.
uom_resolve_client_mirror_base() {
  local candidate="${1:-}" host
  local lib="${PROJECT_ROOT}/scripts/lib/mirror_host_ip.sh"

  candidate="${candidate%/}"
  if [[ -z "$candidate" || "$candidate" == "http://ubuntu-mirror.local" ]]; then
    if [[ -f /etc/default/ubuntu-offline-mirror ]]; then
      candidate="$(set +u; # shellcheck source=/dev/null
        source /etc/default/ubuntu-offline-mirror
        printf '%s' "${PUBLIC_BASE_URL:-}")"
      candidate="${candidate%/}"
    fi
  fi

  [[ -f "$lib" ]] || return 1
  # shellcheck source=/dev/null
  source "$lib"

  if [[ -n "$candidate" && "$candidate" != "http://ubuntu-mirror.local" ]]; then
    host="$(mirror_host_extract_ipv4_from_url "$candidate" || true)"
    if [[ -z "$host" ]] || mirror_host_validate_ipv4_on_host "$host"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    warn "PUBLIC_BASE_URL/--mirror-base ${candidate} is not configured on this host; re-resolving"
  fi

  mirror_host_resolve_and_log >&2 || return 1
  [[ -n "${RESOLVED_MIRROR_BASE_URL:-}" ]] || return 1
  printf '%s\n' "$RESOLVED_MIRROR_BASE_URL"
}

cmd_build_client_xenial_to_bionic() {
  require_cmds python3 gpg gpgv curl sha256sum
  local py mirror_base out_dir skip_sign=0 deploy_nginx=0
  py="${PROJECT_ROOT}/scripts/lib/build_client_xenial_to_bionic.py"
  [[ -f "$py" ]] || die "build_client_xenial_to_bionic.py not found"
  mirror_base="${PUBLIC_BASE_URL:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mirror-base)
        mirror_base="${2:-}"; shift 2 || die "--mirror-base requires URL" ;;
      --mirror-base=*)
        mirror_base="${1#*=}"; shift ;;
      --skip-sign)
        # Unsigned test builds are isolated under artifacts/client-unsigned-test
        # and never written to artifacts/client or nginx.
        skip_sign=1; shift ;;
      --deploy-nginx)
        deploy_nginx=1; shift ;;
      *)
        die "unknown build-client argument: $1" ;;
    esac
  done
  mirror_base="$(uom_resolve_client_mirror_base "$mirror_base" || true)"
  [[ -n "$mirror_base" && "$mirror_base" != "http://ubuntu-mirror.local" ]] \
    || die "MIRROR_BASE_RESOLUTION=FAIL pass --mirror-base or set MIRROR_HTTP_URL; host IPv4 could not be resolved"
  if [[ "$skip_sign" -eq 1 ]]; then
    out_dir="${PROJECT_ROOT}/artifacts/client-unsigned-test"
  else
    out_dir="${PROJECT_ROOT}/artifacts/client"
  fi
  mkdir -p "$out_dir"
  info "Building xenial→bionic client script (mirror_base=${mirror_base} skip_sign=${skip_sign})"
  local args=(
    --project-root "$PROJECT_ROOT"
    --mirror-base "$mirror_base"
    --selective-root "${SELECTIVE_MIRROR_ROOT:-${MIRROR_ROOT}/selective}"
    --output-dir "$out_dir"
  )
  [[ "$skip_sign" -eq 1 ]] && args+=(--skip-sign)
  # Production nginx publish is opt-in and still goes through signature gates
  # inside the builder; prefer scripts/deploy-client-xenial-to-bionic-atomic.sh.
  if [[ "$deploy_nginx" -eq 1 ]]; then
    [[ "$skip_sign" -eq 0 ]] || die "--deploy-nginx incompatible with --skip-sign"
    args+=(--deploy-nginx-root "${MIRROR_ROOT}/client")
  fi
  python3 "$py" "${args[@]}"
  ok "client artifact ready under ${out_dir}"
  if [[ -f "${out_dir}/dp-offline-upgrade-xenial-to-bionic.sh.sha256" ]]; then
    cat "${out_dir}/dp-offline-upgrade-xenial-to-bionic.sh.sha256"
  fi
}


cmd_build_client_bionic_to_focal() {
  require_cmds python3 gpg gpgv curl sha256sum
  local py mirror_base out_dir skip_sign=0 deploy_nginx=0
  py="${PROJECT_ROOT}/scripts/lib/build_client_bionic_to_focal.py"
  [[ -f "$py" ]] || die "build_client_bionic_to_focal.py not found"
  mirror_base="${PUBLIC_BASE_URL:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mirror-base)
        mirror_base="${2:-}"; shift 2 || die "--mirror-base requires URL" ;;
      --mirror-base=*)
        mirror_base="${1#*=}"; shift ;;
      --skip-sign)
        # Unsigned test builds are isolated under artifacts/client-unsigned-test
        # and never written to artifacts/client or nginx.
        skip_sign=1; shift ;;
      --deploy-nginx)
        deploy_nginx=1; shift ;;
      *)
        die "unknown build-client argument: $1" ;;
    esac
  done
  mirror_base="$(uom_resolve_client_mirror_base "$mirror_base" || true)"
  [[ -n "$mirror_base" && "$mirror_base" != "http://ubuntu-mirror.local" ]] \
    || die "MIRROR_BASE_RESOLUTION=FAIL pass --mirror-base or set MIRROR_HTTP_URL; host IPv4 could not be resolved"
  if [[ "$skip_sign" -eq 1 ]]; then
    out_dir="${PROJECT_ROOT}/artifacts/client-unsigned-test"
  else
    out_dir="${PROJECT_ROOT}/artifacts/client"
  fi
  mkdir -p "$out_dir"
  info "Building bionic→focal client script (mirror_base=${mirror_base} skip_sign=${skip_sign})"
  local args=(
    --project-root "$PROJECT_ROOT"
    --mirror-base "$mirror_base"
    --selective-root "${SELECTIVE_MIRROR_ROOT:-${MIRROR_ROOT}/selective}"
    --output-dir "$out_dir"
  )
  [[ "$skip_sign" -eq 1 ]] && args+=(--skip-sign)
  # Production nginx publish is opt-in and still goes through signature gates
  # inside the builder; prefer scripts/deploy-client-bionic-to-focal-atomic.sh.
  if [[ "$deploy_nginx" -eq 1 ]]; then
    [[ "$skip_sign" -eq 0 ]] || die "--deploy-nginx incompatible with --skip-sign"
    args+=(--deploy-nginx-root "${MIRROR_ROOT}/client")
  fi
  python3 "$py" "${args[@]}"
  ok "client artifact ready under ${out_dir}"
  if [[ -f "${out_dir}/dp-offline-upgrade-bionic-to-focal.sh.sha256" ]]; then
    cat "${out_dir}/dp-offline-upgrade-bionic-to-focal.sh.sha256"
  fi
}

cmd_build_client_focal_to_jammy() {
  require_cmds python3 gpg gpgv curl sha256sum
  local py mirror_base out_dir skip_sign=0 deploy_nginx=0
  py="${PROJECT_ROOT}/scripts/lib/build_client_focal_to_jammy.py"
  [[ -f "$py" ]] || die "build_client_focal_to_jammy.py not found"
  mirror_base="${PUBLIC_BASE_URL:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mirror-base)
        mirror_base="${2:-}"; shift 2 || die "--mirror-base requires URL" ;;
      --mirror-base=*)
        mirror_base="${1#*=}"; shift ;;
      --skip-sign)
        # Unsigned test builds are isolated under artifacts/client-unsigned-test
        # and never written to artifacts/client or nginx.
        skip_sign=1; shift ;;
      --deploy-nginx)
        deploy_nginx=1; shift ;;
      *)
        die "unknown build-client argument: $1" ;;
    esac
  done
  mirror_base="$(uom_resolve_client_mirror_base "$mirror_base" || true)"
  [[ -n "$mirror_base" && "$mirror_base" != "http://ubuntu-mirror.local" ]] \
    || die "MIRROR_BASE_RESOLUTION=FAIL pass --mirror-base or set MIRROR_HTTP_URL; host IPv4 could not be resolved"
  if [[ "$skip_sign" -eq 1 ]]; then
    out_dir="${PROJECT_ROOT}/artifacts/client-unsigned-test"
  else
    out_dir="${PROJECT_ROOT}/artifacts/client"
  fi
  mkdir -p "$out_dir"
  info "Building focal→jammy client script (mirror_base=${mirror_base} skip_sign=${skip_sign})"
  local args=(
    --project-root "$PROJECT_ROOT"
    --mirror-base "$mirror_base"
    --selective-root "${SELECTIVE_MIRROR_ROOT:-${MIRROR_ROOT}/selective}"
    --output-dir "$out_dir"
  )
  [[ "$skip_sign" -eq 1 ]] && args+=(--skip-sign)
  # Production nginx publish is opt-in and still goes through signature gates
  # inside the builder; prefer scripts/deploy-client-focal-to-jammy-atomic.sh.
  if [[ "$deploy_nginx" -eq 1 ]]; then
    [[ "$skip_sign" -eq 0 ]] || die "--deploy-nginx incompatible with --skip-sign"
    args+=(--deploy-nginx-root "${MIRROR_ROOT}/client")
  fi
  python3 "$py" "${args[@]}"
  ok "client artifact ready under ${out_dir}"
  if [[ -f "${out_dir}/dp-offline-upgrade-focal-to-jammy.sh.sha256" ]]; then
    cat "${out_dir}/dp-offline-upgrade-focal-to-jammy.sh.sha256"
  fi
}

cmd_build_client_jammy_to_noble() {
  require_cmds python3 gpg gpgv curl sha256sum
  local py mirror_base out_dir skip_sign=0 deploy_nginx=0
  py="${PROJECT_ROOT}/scripts/lib/build_client_jammy_to_noble.py"
  [[ -f "$py" ]] || die "build_client_jammy_to_noble.py not found"
  mirror_base="${PUBLIC_BASE_URL:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mirror-base)
        mirror_base="${2:-}"; shift 2 || die "--mirror-base requires URL" ;;
      --mirror-base=*)
        mirror_base="${1#*=}"; shift ;;
      --skip-sign)
        # Unsigned test builds are isolated under artifacts/client-unsigned-test
        # and never written to artifacts/client or nginx.
        skip_sign=1; shift ;;
      --deploy-nginx)
        deploy_nginx=1; shift ;;
      *)
        die "unknown build-client argument: $1" ;;
    esac
  done
  mirror_base="$(uom_resolve_client_mirror_base "$mirror_base" || true)"
  [[ -n "$mirror_base" && "$mirror_base" != "http://ubuntu-mirror.local" ]] \
    || die "MIRROR_BASE_RESOLUTION=FAIL pass --mirror-base or set MIRROR_HTTP_URL; host IPv4 could not be resolved"
  if [[ "$skip_sign" -eq 1 ]]; then
    out_dir="${PROJECT_ROOT}/artifacts/client-unsigned-test"
  else
    out_dir="${PROJECT_ROOT}/artifacts/client"
  fi
  mkdir -p "$out_dir"
  info "Building jammy→noble client script (mirror_base=${mirror_base} skip_sign=${skip_sign})"
  local args=(
    --project-root "$PROJECT_ROOT"
    --mirror-base "$mirror_base"
    --selective-root "${SELECTIVE_MIRROR_ROOT:-${MIRROR_ROOT}/selective}"
    --output-dir "$out_dir"
  )
  [[ "$skip_sign" -eq 1 ]] && args+=(--skip-sign)
  # Production nginx publish is opt-in and still goes through signature gates
  # inside the builder; prefer scripts/deploy-client-jammy-to-noble-atomic.sh.
  if [[ "$deploy_nginx" -eq 1 ]]; then
    [[ "$skip_sign" -eq 0 ]] || die "--deploy-nginx incompatible with --skip-sign"
    args+=(--deploy-nginx-root "${MIRROR_ROOT}/client")
  fi
  python3 "$py" "${args[@]}"
  ok "client artifact ready under ${out_dir}"
  if [[ -f "${out_dir}/dp-offline-upgrade-jammy-to-noble.sh.sha256" ]]; then
    cat "${out_dir}/dp-offline-upgrade-jammy-to-noble.sh.sha256"
  fi
}

cmd_check_profile() {
  require_cmds python3
  assert_upgrade_profile_allowed || die "profile check FAIL"
  ok "profile check PASS"
}

cmd_validate_profile() {
  require_cmds python3
  acquire_lock
  mkdir -p "$OFFLINE_DIR"
  validate_upgrade_profile_gate || die "validate-profile FAIL"
  ok "validate-profile PASS"
}

cmd_migrate_profile() {
  require_cmds python3
  local py profile
  py="$(resolve_validate_upgrade_profile_py)" || die "validate_upgrade_profile.py not found"
  profile="$(resolve_upgrade_profile_json)" || die "offline-upgrade-profile.json not found"
  mkdir -p "$OFFLINE_DIR"
  local args=()
  local a
  for a in "$@"; do
    args+=("$a")
  done
  set +e
  python3 "$py" migrate-profile \
    --mirror-root "$MIRROR_ROOT" \
    --profile "$profile" \
    --mirror-list /etc/apt/mirror.list \
    --mirror-conf /etc/ubuntu-mirror/mirror.conf \
    --project-root "$PROJECT_ROOT" \
    --result-json "${OFFLINE_DIR}/profile-migration.json" \
    "${args[@]}"
  local rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || die "migrate-profile failed"
  ok "migrate-profile finished (sync not started)"
}

cmd_sync_legacy_releases() {
  require_cmds python3 curl
  acquire_lock
  TMP_DIR="$(mktemp -d /tmp/uom-XXXXXX)"
  mkdir -p "$OFFLINE_DIR"
  sync_legacy_releases_py || die "legacy release sync failed"
  ok "legacy release sync complete"
}

cmd_validate_legacy_releases() {
  require_cmds python3
  acquire_lock
  TMP_DIR="$(mktemp -d /tmp/uom-XXXXXX)"
  mkdir -p "$OFFLINE_DIR"
  validate_legacy_releases_py || die "legacy release validation failed"
  ok "legacy release validation PASS"
}

cmd_freeze_xenial_snapshot() {
  require_cmds python3
  acquire_lock
  TMP_DIR="$(mktemp -d /tmp/uom-XXXXXX)"
  mkdir -p "$OFFLINE_DIR"
  run_legacy_releases_tool freeze-snapshot || die "freeze-xenial-snapshot failed"
  ok "Xenial active snapshot frozen"
}

cmd_sync_release_upgraders() {
  require_cmds python3 curl gpgv
  acquire_lock
  TMP_DIR="$(mktemp -d /tmp/uom-XXXXXX)"
  mkdir -p "$OFFLINE_DIR" "$ANNOUNCE_DIR"
  sync_release_upgraders_py || die "release upgrader sync failed"
  ok "release upgrader sync complete"
}

cmd_validate_release_upgraders() {
  require_cmds python3 gpgv
  acquire_lock
  TMP_DIR="$(mktemp -d /tmp/uom-XXXXXX)"
  mkdir -p "$OFFLINE_DIR"
  validate_release_upgraders_py || die "release upgrader validation failed"
  ok "release upgrader validation PASS"
}

_dp_phase2_script() {
  local cand
  for cand in \
    "${PROJECT_ROOT}/scripts/download-dp-phase2.sh" \
    "/usr/local/lib/ubuntu-mirror/download-dp-phase2.sh" \
    "${SCRIPT_DIR}/download-dp-phase2.sh" \
    "${PROJECT_ROOT}/scripts/download-dp-phase2-6.6.0.sh" \
    "/usr/local/lib/ubuntu-mirror/download-dp-phase2-6.6.0.sh" \
    "${SCRIPT_DIR}/download-dp-phase2-6.6.0.sh"
  do
    if [[ -f "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

cmd_sync_dp_phase2() {
  local script
  script="$(_dp_phase2_script)" || die "download-dp-phase2.sh not found"
  # Dedicated lock inside download script; also refuses if UOM global lock is busy.
  # Does not acquire UOM global lock (avoids blocking verify-selective readers wrongly,
  # and avoids re-entrancy issues). Selective READY is never touched.
  info "DP_PHASE2_SYNC_START script=${script}"
  DP_PHASE2_LOG_FILE="${DP_PHASE2_LOG_FILE:-/var/log/ubuntu-mirror/dp-phase2-sync.log}" \
    bash "$script" --version "${DP_PHASE2_VERSION:-${DP_PHASE2_VERSION_DEFAULT:-6.6.0}}" sync
}

cmd_verify_dp_phase2() {
  local script
  script="$(_dp_phase2_script)" || die "download-dp-phase2.sh not found"
  bash "$script" --version "${DP_PHASE2_VERSION:-${DP_PHASE2_VERSION_DEFAULT:-6.6.0}}" verify
}

cmd_status_dp_phase2() {
  local script
  script="$(_dp_phase2_script)" || die "download-dp-phase2.sh not found"
  bash "$script" --version "${DP_PHASE2_VERSION:-${DP_PHASE2_VERSION_DEFAULT:-6.6.0}}" status
}

_mirror_manager_script() {
  local cand
  for cand in \
    "${PROJECT_ROOT}/scripts/install-dp-upgrade-mirror.sh" \
    "/usr/local/lib/ubuntu-mirror/scripts/install-dp-upgrade-mirror.sh" \
    "/usr/local/lib/ubuntu-mirror/install-dp-upgrade-mirror.sh" \
    "${SCRIPT_DIR}/install-dp-upgrade-mirror.sh"
  do
    if [[ -f "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

cmd_mirror_manager() {
  local script
  script="$(_mirror_manager_script)" || die "install-dp-upgrade-mirror.sh not found"
  bash "$script" mirror-manager "$@"
}

cmd_enable_http() {
  local script
  script="$(_mirror_manager_script)" || die "install-dp-upgrade-mirror.sh not found"
  bash "$script" enable-http "$@"
}

cmd_verify_readiness() {
  local script
  script="$(_mirror_manager_script)" || die "install-dp-upgrade-mirror.sh not found"
  bash "$script" verify-readiness "$@"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    plan-selective) shift; cmd_plan_selective "$@" ;;
    materialize-selective) shift; cmd_materialize_selective "$@" ;;
    verify-selective) shift; cmd_verify_selective "$@" ;;
    publish-selective) shift; cmd_publish_selective "$@" ;;
    quarantine-hop-selective) shift; cmd_quarantine_hop_selective "$@" ;;
    quarantine-staging-selective) shift; cmd_quarantine_staging_selective "$@" ;;
    refresh-hop-selective) shift; cmd_refresh_hop_selective "$@" ;;
    migrate-nginx-selective) shift; cmd_migrate_nginx_selective "$@" ;;
    migrate-selective-runtime) shift; cmd_migrate_selective_runtime "$@" ;;
    sync) shift; cmd_sync "$@" ;;
    sync-full-legacy) shift; cmd_sync_full_legacy "$@" ;;
    verify) shift; cmd_verify "$@" ;;
    check-profile) shift; cmd_check_profile "$@" ;;
    validate-profile) shift; cmd_validate_profile "$@" ;;
    migrate-profile) shift; cmd_migrate_profile "$@" ;;
    sync-by-hash) shift; cmd_sync_by_hash "$@" ;;
    validate-by-hash) shift; cmd_validate_by_hash "$@" ;;
    sync-release-upgraders) shift; cmd_sync_release_upgraders "$@" ;;
    validate-release-upgraders) shift; cmd_validate_release_upgraders "$@" ;;
    sync-legacy-releases) shift; cmd_sync_legacy_releases "$@" ;;
    validate-legacy-releases) shift; cmd_validate_legacy_releases "$@" ;;
    freeze-xenial-snapshot) shift; cmd_freeze_xenial_snapshot "$@" ;;
    status) shift; cmd_status "$@" ;;
    freeze) shift; cmd_freeze "$@" ;;
    sha256-all) shift; cmd_sha256_all "$@" ;;
    build-client-xenial-to-bionic) shift; cmd_build_client_xenial_to_bionic "$@" ;;
    build-client-bionic-to-focal) shift; cmd_build_client_bionic_to_focal "$@" ;;
    build-client-focal-to-jammy) shift; cmd_build_client_focal_to_jammy "$@" ;;
    build-client-jammy-to-noble) shift; cmd_build_client_jammy_to_noble "$@" ;;
    sync-dp-phase2) shift; cmd_sync_dp_phase2 "$@" ;;
    verify-dp-phase2) shift; cmd_verify_dp_phase2 "$@" ;;
    status-dp-phase2) shift; cmd_status_dp_phase2 "$@" ;;
    mirror-manager) shift; cmd_mirror_manager "$@" ;;
    enable-http) shift; cmd_enable_http "$@" ;;
    verify-readiness) shift; cmd_verify_readiness "$@" ;;
    -h|--help|help|"") usage; [[ -n "$cmd" ]] || exit 1; exit 0 ;;
    *) die "Unknown command: $cmd (see --help)" ;;
  esac
}

main "$@"
