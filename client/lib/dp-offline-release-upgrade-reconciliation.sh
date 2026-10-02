# shellcheck shell=bash
# Shared authoritative release-upgrade state reconciliation + package-transition
# evidence classifier for all OS-hop clients.
#
# Injected into single-file clients at build time via the
# RELEASE_UPGRADE_RECONCILIATION_HELPER template token (see build_client_*.py).
# Directly sourceable by fixture tests with hop PIN_* vars set.
#
# Depends on caller-provided:
#   hostpath, log, die, critical_holds_dir, atomic_write_file (optional),
#   read_os_field, read_state, write_state (optional), pkg_installed_version,
#   persist_release_upgrade_flags (optional), detect_meta_release_encoding_failure_signature
#   (optional), PIN_HOP, PIN_SOURCE_VERSION, PIN_TARGET_VERSION,
#   PIN_SOURCE_CODENAME, PIN_TARGET_CODENAME, STATE_ROOT, LOG_FILE,
#   EC_RESUME, EC_BUSY (optional), TEST_ROOT
#
# Each hop MUST set its own PIN_* and uses hop-scoped baseline/evidence dirs.
# Evidence owned by a completed previous hop is NEVER treated as current-hop
# package mutation.

# --- globals filled by classifier ---
PACKAGE_TRANSITION_CLASS="NONE"
PACKAGE_TRANSITION_EVIDENCE_LINES=""
AUTHORITATIVE_EVIDENCE_COUNT=0
STALE_EVIDENCE_COUNT=0
PRE_TRANSITION_EVIDENCE_COUNT=0
RECONCILIATION_DECISION=""
RESUME_FROM=""
MANUAL_REVIEW_REQUIRED="NO"
SAFE_TO_RERUN="NO"
AUTHORITATIVE_PACKAGE_TRANSITION="NO"
ACTIVE_UPGRADE_PROCESS="NO"
DPKG_AUDIT_STATUS="UNKNOWN"
CORE_PACKAGE_CONSISTENCY="UNKNOWN"
DIAGNOSTIC_BUNDLE_PATH=""
CURRENT_RUN_ID="${CURRENT_RUN_ID:-}"
RECON_BASELINE_LOADED="NO"

# Direct-sourceable reconciliation tests do not always load the durable helper.
# Delegate to the common predicate when present; otherwise use the same
# fail-closed full-output audit semantics locally.
recon_dpkg_audit_has_issues() {
  if declare -F dpkg_audit_has_issues >/dev/null 2>&1; then
    dpkg_audit_has_issues
    return $?
  fi
  local tmp rc=0 errexit_was_on=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/dpkg-audit.XXXXXX" 2>/dev/null)" || return 0
  case $- in *e*) errexit_was_on=1 ;; esac
  set +e
  dpkg --audit >"$tmp" 2>&1
  rc=$?
  if [[ "$errexit_was_on" -eq 1 ]]; then
    set -e
  else
    set +e
  fi
  if [[ "$rc" -ne 0 || -s "$tmp" ]]; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Serialize one destructive client transaction across all four OS-hop clients.
# All hops share one ephemeral /run/lock identity, so two different hop binaries
# cannot race through check -> preflight -> confirmation -> commit. A stale lock
# file is harmless: flock ownership disappears automatically when the process exits.
CLIENT_EXECUTION_LOCK_FD=""
CLIENT_EXECUTION_LOCK_PATH=""

_client_execution_lock_fd_holds_ours() {
  local fd="${1:-}" expected actual
  [[ "$fd" =~ ^[0-9]+$ ]] || return 1
  [[ -e "/proc/self/fd/${fd}" ]] || return 1
  expected="$(hostpath "/run/lock/stellar-offline-os-upgrade-client.lock")"
  expected="$(readlink -f "$expected" 2>/dev/null || printf '%s' "$expected")"
  actual="$(readlink -f "/proc/self/fd/${fd}" 2>/dev/null || true)"
  [[ -n "$actual" && "$actual" == "$expected" ]] || return 1
  flock -n "$fd"
}

client_execution_lock_acquire() {
  local lock dir fd
  if _client_execution_lock_fd_holds_ours "${CLIENT_EXECUTION_LOCK_FD:-}"; then
    return 0
  fi
  CLIENT_EXECUTION_LOCK_FD=""
  CLIENT_EXECUTION_LOCK_PATH=""
  lock="$(hostpath "/run/lock/stellar-offline-os-upgrade-client.lock")"
  dir="$(dirname "$lock")"
  mkdir -p "$dir" || return 1
  exec {fd}>"$lock" || return 1
  if ! flock -n "$fd"; then
    eval "exec ${fd}>&-" 2>/dev/null || true
    return 1
  fi
  CLIENT_EXECUTION_LOCK_FD="$fd"
  CLIENT_EXECUTION_LOCK_PATH="$lock"
  chmod 0600 "$lock" 2>/dev/null || true
  if declare -F log >/dev/null 2>&1; then
    log INFO "CLIENT_EXECUTION_LOCK=ACQUIRED path=/run/lock/stellar-offline-os-upgrade-client.lock"
  fi
  return 0
}

client_execution_lock_release() {
  local fd="${CLIENT_EXECUTION_LOCK_FD:-}"
  [[ "$fd" =~ ^[0-9]+$ ]] || return 0
  flock -u "$fd" 2>/dev/null || true
  eval "exec ${fd}>&-" 2>/dev/null || true
  CLIENT_EXECUTION_LOCK_FD=""
  if declare -F log >/dev/null 2>&1; then
    log INFO "CLIENT_EXECUTION_LOCK=RELEASED"
  fi
  return 0
}

recon_hop_root() {
  hostpath "${STATE_ROOT}/hops/${PIN_HOP}"
}

recon_runs_dir() {
  printf '%s/runs\n' "$(recon_hop_root)"
}

recon_evidence_dir() {
  printf '%s/evidence\n' "$(recon_hop_root)"
}

recon_current_run_link() {
  printf '%s/current-run\n' "$(recon_hop_root)"
}

recon_critical_dir() {
  if declare -F critical_holds_dir >/dev/null 2>&1; then
    critical_holds_dir
  else
    hostpath "${STATE_ROOT}/critical-holds"
  fi
}

recon_atomic_write() {
  local dest="$1"
  local dir tmp
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  tmp="${dest}.tmp.$$.$RANDOM"
  cat >"$tmp"
  if declare -F atomic_write_file >/dev/null 2>&1; then
    # Prefer project helper when available (stdin-based).
    atomic_write_file "$dest" <"$tmp"
    rm -f "$tmp"
  else
    chmod --reference="$dest" "$tmp" 2>/dev/null || chmod 0644 "$tmp" 2>/dev/null || true
    if declare -F durable_fsync_path >/dev/null 2>&1; then
      durable_fsync_path "$tmp" 2>/dev/null || true
    fi
    mv -f "$tmp" "$dest"
    if declare -F durable_fsync_path >/dev/null 2>&1; then
      durable_fsync_path "$(dirname "$dest")" 2>/dev/null || true
    fi
  fi
}

# Target-release core package version heuristics by PIN_TARGET_CODENAME.
# Prefer hop-specific is_*_version_for_pkg when defined.
recon_is_target_version_for_pkg() {
  local pkg="$1" ver="$2"
  [[ -n "$ver" ]] || return 1
  case "${PIN_TARGET_CODENAME:-}" in
    bionic)
      if declare -F is_bionic_version_for_pkg >/dev/null 2>&1; then
        is_bionic_version_for_pkg "$pkg" "$ver"
        return $?
      fi
      case "$pkg" in
        base-files) [[ "$ver" == 10.* ]] && return 0 ;;
        libc6|libc-bin) [[ "$ver" == 2.27* ]] && return 0 ;;
        apt|apt-utils) [[ "$ver" == 1.6* ]] && return 0 ;;
        dpkg) [[ "$ver" == 1.19* ]] && return 0 ;;
        systemd|systemd-sysv|udev) [[ "$ver" == 237* || "$ver" == *237* ]] && return 0 ;;
      esac
      ;;
    focal)
      if declare -F is_focal_version_for_pkg >/dev/null 2>&1; then
        is_focal_version_for_pkg "$pkg" "$ver"
        return $?
      fi
      case "$pkg" in
        base-files) [[ "$ver" == 11* ]] && return 0 ;;
        libc6|libc-bin) [[ "$ver" == 2.31* ]] && return 0 ;;
        apt|apt-utils) [[ "$ver" == 2.0* ]] && return 0 ;;
        dpkg) [[ "$ver" == 1.19.7* || "$ver" == 1.19* ]] && return 0 ;;
        systemd|systemd-sysv|udev) [[ "$ver" == 245* || "$ver" == *245* ]] && return 0 ;;
      esac
      ;;
    jammy)
      if declare -F is_jammy_version_for_pkg >/dev/null 2>&1; then
        is_jammy_version_for_pkg "$pkg" "$ver"
        return $?
      fi
      case "$pkg" in
        base-files) [[ "$ver" == 12* ]] && return 0 ;;
        libc6|libc-bin) [[ "$ver" == 2.35* ]] && return 0 ;;
        apt|apt-utils) [[ "$ver" == 2.4* ]] && return 0 ;;
        dpkg) [[ "$ver" == 1.21* ]] && return 0 ;;
        systemd|systemd-sysv|udev) [[ "$ver" == 249* || "$ver" == *249* ]] && return 0 ;;
      esac
      ;;
    noble)
      if declare -F is_noble_version_for_pkg >/dev/null 2>&1; then
        is_noble_version_for_pkg "$pkg" "$ver"
        return $?
      fi
      case "$pkg" in
        base-files) [[ "$ver" == 13* ]] && return 0 ;;
        libc6|libc-bin) [[ "$ver" == 2.39* ]] && return 0 ;;
        apt|apt-utils) [[ "$ver" == 2.7* || "$ver" == 2.8* ]] && return 0 ;;
        dpkg) [[ "$ver" == 1.22* ]] && return 0 ;;
        systemd|systemd-sysv|udev) [[ "$ver" == 255* || "$ver" == *255* ]] && return 0 ;;
      esac
      ;;
  esac
  return 1
}

recon_is_source_version_for_pkg() {
  local pkg="$1" ver="$2"
  [[ -n "$ver" ]] || return 1
  case "${PIN_SOURCE_CODENAME:-}" in
    xenial)
      case "$pkg" in
        base-files) [[ "$ver" == 9.* ]] && return 0 ;;
        libc6|libc-bin) [[ "$ver" == 2.23* ]] && return 0 ;;
        apt|apt-utils) [[ "$ver" == 1.2* ]] && return 0 ;;
        dpkg) [[ "$ver" == 1.18* ]] && return 0 ;;
        systemd|systemd-sysv|udev) [[ "$ver" == 229* || "$ver" == *229* ]] && return 0 ;;
      esac
      ;;
    bionic)
      case "$pkg" in
        base-files) [[ "$ver" == 10.* ]] && return 0 ;;
        libc6|libc-bin) [[ "$ver" == 2.27* ]] && return 0 ;;
        apt|apt-utils) [[ "$ver" == 1.6* ]] && return 0 ;;
        dpkg) [[ "$ver" == 1.19* ]] && return 0 ;;
        systemd|systemd-sysv|udev) [[ "$ver" == 237* || "$ver" == *237* ]] && return 0 ;;
      esac
      ;;
    focal)
      case "$pkg" in
        base-files) [[ "$ver" == 11* ]] && return 0 ;;
        libc6|libc-bin) [[ "$ver" == 2.31* ]] && return 0 ;;
        apt|apt-utils) [[ "$ver" == 2.0* ]] && return 0 ;;
        dpkg) [[ "$ver" == 1.19* ]] && return 0 ;;
        systemd|systemd-sysv|udev) [[ "$ver" == 245* || "$ver" == *245* ]] && return 0 ;;
      esac
      ;;
    jammy)
      case "$pkg" in
        base-files) [[ "$ver" == 12* ]] && return 0 ;;
        libc6|libc-bin) [[ "$ver" == 2.35* ]] && return 0 ;;
        apt|apt-utils) [[ "$ver" == 2.4* ]] && return 0 ;;
        dpkg) [[ "$ver" == 1.21* ]] && return 0 ;;
        systemd|systemd-sysv|udev) [[ "$ver" == 249* || "$ver" == *249* ]] && return 0 ;;
      esac
      ;;
  esac
  return 1
}

recon_file_inode() {
  local f="$1"
  [[ -e "$f" ]] || { printf '0'; return 0; }
  stat -c '%i' "$f" 2>/dev/null || stat -f '%i' "$f" 2>/dev/null || printf '0'
}

recon_file_size() {
  local f="$1"
  [[ -e "$f" ]] || { printf '0'; return 0; }
  stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f" 2>/dev/null || printf '0'
}

recon_sha256_file() {
  local f="$1"
  [[ -f "$f" ]] || { printf ''; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  else
    printf ''
  fi
}

recon_list_active_upgrade_processes() {
  local self_pid="$$"
  if [[ -n "${TEST_ROOT:-}" ]]; then
    if [[ -f "$(hostpath ${STATE_ROOT}/force-active-upgrade-process)" ]]; then
      printf '1 fake-do-release-upgrade --force-fixture\n'
      return 0
    fi
    return 0
  fi
  if declare -F list_active_upgrade_processes >/dev/null 2>&1; then
    list_active_upgrade_processes
    return 0
  fi
  ps -eo pid=,args= 2>/dev/null | awk -v self="$self_pid" '
    BEGIN { OFS=" " }
    {
      pid=$1; $1=""; sub(/^ /, "", $0); cmd=$0
      if (pid == self) next
      if (cmd ~ /(^|[ \/])(pgrep|grep|awk|ps)([ ]|$)/) next
      keep=0
      if (cmd ~ /dp-offline-upgrade-|stellar-offline-os-upgrade/) keep=1
      if (cmd ~ /(^|[ \/])do-release-upgrade([ ]|$)/) keep=1
      if (cmd ~ /DistUpgrade|ubuntu-release-upgrader/) keep=1
      if (cmd ~ /(^|[ \/])(apt-get|apt)([ ]|$)/ && cmd ~ /(dist-upgrade|full-upgrade)/) keep=1
      if (cmd ~ /(^|[ \/])dpkg([ ]|$)/ && cmd ~ /--(unpack|install|configure)/) keep=1
      if (keep) print pid, cmd
    }
  ' || true
}

recon_append_evidence() {
  # Args: type source path match after_baseline [package] [version]
  local etype="$1" esource="$2" epath="$3" ematch="$4" after="${5:-unknown}"
  local pkg="${6:-}" ver="${7:-}"
  # Sanitize match: drop credentials / overly long lines.
  ematch="$(printf '%s' "$ematch" | tr -d '\r' | cut -c1-160 | sed -E 's/(password|passwd|token|secret)=[^ ]*/\1=***/Ig')"
  PACKAGE_TRANSITION_EVIDENCE_LINES+="EVIDENCE_TYPE=${etype}"$'\n'
  PACKAGE_TRANSITION_EVIDENCE_LINES+="EVIDENCE_SOURCE=${esource}"$'\n'
  PACKAGE_TRANSITION_EVIDENCE_LINES+="EVIDENCE_PATH=${epath}"$'\n'
  PACKAGE_TRANSITION_EVIDENCE_LINES+="EVIDENCE_MATCH=${ematch}"$'\n'
  PACKAGE_TRANSITION_EVIDENCE_LINES+="EVIDENCE_AFTER_BASELINE=${after}"$'\n'
  PACKAGE_TRANSITION_EVIDENCE_LINES+="EVIDENCE_RUN_ID=${CURRENT_RUN_ID:-}"$'\n'
  PACKAGE_TRANSITION_EVIDENCE_LINES+="EVIDENCE_SOURCE_RELEASE=${PIN_SOURCE_VERSION}"$'\n'
  PACKAGE_TRANSITION_EVIDENCE_LINES+="EVIDENCE_TARGET_RELEASE=${PIN_TARGET_VERSION}"$'\n'
  [[ -n "$pkg" ]] && PACKAGE_TRANSITION_EVIDENCE_LINES+="EVIDENCE_PACKAGE=${pkg}"$'\n'
  [[ -n "$ver" ]] && PACKAGE_TRANSITION_EVIDENCE_LINES+="EVIDENCE_INSTALLED_VERSION=${ver}"$'\n'
  PACKAGE_TRANSITION_EVIDENCE_LINES+=$'\n'
}

recon_load_baseline() {
  # Load hop-scoped baseline from current-run if present.
  local link run_dir basef
  RECON_BASELINE_LOADED="NO"
  RECON_BASE_DPKG_INODE=""
  RECON_BASE_DPKG_OFFSET=0
  RECON_BASE_APT_HIST_INODE=""
  RECON_BASE_APT_HIST_OFFSET=0
  RECON_BASE_APT_TERM_INODE=""
  RECON_BASE_APT_TERM_OFFSET=0
  RECON_BASE_DPKG_STATUS_SHA=""
  RECON_BASE_STARTED_UTC=""
  RECON_BASE_DPKG_PREFIX_SHA=""
  RECON_BASE_APT_HIST_PREFIX_SHA=""
  RECON_BASE_APT_TERM_PREFIX_SHA=""
  link="$(recon_current_run_link)"
  if [[ -L "$link" || -f "$link" ]]; then
    run_dir="$(readlink -f "$link" 2>/dev/null || cat "$link" 2>/dev/null || true)"
  else
    run_dir=""
  fi
  [[ -n "$run_dir" && -d "$run_dir" ]] || return 1
  basef="${run_dir}/baseline.env"
  [[ -f "$basef" ]] || return 1
  CURRENT_RUN_ID="$(sed -n 's/^RUN_ID=//p' "$basef" | head -1)"
  RECON_BASE_STARTED_UTC="$(sed -n 's/^RUN_STARTED_UTC=//p' "$basef" | head -1)"
  RECON_BASE_DPKG_INODE="$(sed -n 's/^DPKG_LOG_INODE=//p' "$basef" | head -1)"
  RECON_BASE_DPKG_OFFSET="$(sed -n 's/^DPKG_LOG_OFFSET=//p' "$basef" | head -1)"
  RECON_BASE_DPKG_PREFIX_SHA="$(sed -n 's/^DPKG_LOG_PREFIX_SHA256=//p' "$basef" | head -1)"
  RECON_BASE_APT_HIST_INODE="$(sed -n 's/^APT_HISTORY_INODE=//p' "$basef" | head -1)"
  RECON_BASE_APT_HIST_OFFSET="$(sed -n 's/^APT_HISTORY_OFFSET=//p' "$basef" | head -1)"
  RECON_BASE_APT_HIST_PREFIX_SHA="$(sed -n 's/^APT_HISTORY_PREFIX_SHA256=//p' "$basef" | head -1)"
  RECON_BASE_APT_TERM_INODE="$(sed -n 's/^APT_TERM_INODE=//p' "$basef" | head -1)"
  RECON_BASE_APT_TERM_OFFSET="$(sed -n 's/^APT_TERM_OFFSET=//p' "$basef" | head -1)"
  RECON_BASE_APT_TERM_PREFIX_SHA="$(sed -n 's/^APT_TERM_PREFIX_SHA256=//p' "$basef" | head -1)"
  RECON_BASE_DPKG_STATUS_SHA="$(sed -n 's/^DPKG_STATUS_SHA256=//p' "$basef" | head -1)"
  RECON_BASE_DPKG_OFFSET="${RECON_BASE_DPKG_OFFSET:-0}"
  RECON_BASE_APT_HIST_OFFSET="${RECON_BASE_APT_HIST_OFFSET:-0}"
  RECON_BASE_APT_TERM_OFFSET="${RECON_BASE_APT_TERM_OFFSET:-0}"
  RECON_BASELINE_LOADED="YES"
  return 0
}

recon_prefix_sha() {
  local f="$1" off="$2"
  [[ -f "$f" ]] || { printf ''; return 0; }
  if [[ ! "${off:-0}" =~ ^[0-9]+$ ]] || [[ "$off" -le 0 ]]; then
    printf ''; return 0
  fi
  head -c "$off" "$f" 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}'
}

record_release_upgrade_run_baseline() {
  # Atomic hop-scoped baseline before any release-upgrade package mutation.
  local run_id started run_dir link dpkglog apthist aptterm statusf
  local dpkg_in dpkg_off hist_in hist_off term_in term_off status_sha
  local audit_out bf_ver tmpenv
  run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  run_dir="$(recon_runs_dir)/${run_id}"
  mkdir -p "$run_dir" "$(recon_evidence_dir)"
  dpkglog="$(hostpath /var/log/dpkg.log)"
  apthist="$(hostpath /var/log/apt/history.log)"
  aptterm="$(hostpath /var/log/apt/term.log)"
  statusf="$(hostpath /var/lib/dpkg/status)"
  dpkg_in="$(recon_file_inode "$dpkglog")"
  dpkg_off="$(recon_file_size "$dpkglog")"
  hist_in="$(recon_file_inode "$apthist")"
  hist_off="$(recon_file_size "$apthist")"
  term_in="$(recon_file_inode "$aptterm")"
  term_off="$(recon_file_size "$aptterm")"
  status_sha="$(recon_sha256_file "$statusf")"
  local dpkg_psha hist_psha term_psha
  dpkg_psha="$(recon_prefix_sha "$dpkglog" "$dpkg_off")"
  hist_psha="$(recon_prefix_sha "$apthist" "$hist_off")"
  term_psha="$(recon_prefix_sha "$aptterm" "$term_off")"
  bf_ver=""
  if declare -F pkg_installed_version >/dev/null 2>&1; then
    bf_ver="$(pkg_installed_version base-files)"
  fi
  audit_out="clean"
  if [[ -z "${TEST_ROOT:-}" ]]; then
    if recon_dpkg_audit_has_issues; then
      audit_out="dirty"
    fi
  elif [[ -f "$(hostpath /tmp/dpkg-broken)" ]]; then
    audit_out="dirty"
  fi
  tmpenv="${run_dir}/baseline.env.tmp.$$"
  {
    printf 'RUN_ID=%s\n' "$run_id"
    printf 'RUN_STARTED_UTC=%s\n' "$started"
    printf 'PIN_HOP=%s\n' "${PIN_HOP}"
    printf 'SOURCE_VERSION_ID=%s\n' "${PIN_SOURCE_VERSION}"
    printf 'TARGET_VERSION_ID=%s\n' "${PIN_TARGET_VERSION}"
    printf 'DPKG_LOG_INODE=%s\n' "$dpkg_in"
    printf 'DPKG_LOG_OFFSET=%s\n' "$dpkg_off"
    printf 'DPKG_LOG_PREFIX_SHA256=%s\n' "$dpkg_psha"
    printf 'APT_HISTORY_INODE=%s\n' "$hist_in"
    printf 'APT_HISTORY_OFFSET=%s\n' "$hist_off"
    printf 'APT_HISTORY_PREFIX_SHA256=%s\n' "$hist_psha"
    printf 'APT_TERM_INODE=%s\n' "$term_in"
    printf 'APT_TERM_OFFSET=%s\n' "$term_off"
    printf 'APT_TERM_PREFIX_SHA256=%s\n' "$term_psha"
    printf 'DPKG_STATUS_SHA256=%s\n' "$status_sha"
    printf 'BASE_FILES_VERSION=%s\n' "$bf_ver"
    printf 'DPKG_AUDIT=%s\n' "$audit_out"
  } >"$tmpenv"
  if declare -F durable_fsync_path >/dev/null 2>&1; then
    durable_fsync_path "$tmpenv" 2>/dev/null || true
  fi
  mv -f "$tmpenv" "${run_dir}/baseline.env"
  if declare -F durable_fsync_path >/dev/null 2>&1; then
    durable_fsync_path "$run_dir" 2>/dev/null || true
  fi
  # Also snapshot core package versions.
  {
    local pkg
    for pkg in base-files libc6 apt dpkg systemd systemd-sysv; do
      if declare -F pkg_installed_version >/dev/null 2>&1; then
        printf '%s=%s\n' "$pkg" "$(pkg_installed_version "$pkg")"
      fi
    done
  } >"${run_dir}/core-packages.before"
  link="$(recon_current_run_link)"
  ln -sfn "$run_dir" "${link}.tmp.$$" 2>/dev/null || printf '%s\n' "$run_dir" >"${link}.tmp.$$"
  mv -f "${link}.tmp.$$" "$link"
  CURRENT_RUN_ID="$run_id"
  # Legacy offset file for older runners (hop-specific copy under holds + hop root).
  printf '%s\n' "$dpkg_off" | recon_atomic_write "$(recon_critical_dir)/dpkg_log_offset_before"
  printf '%s\n' "$dpkg_off" | recon_atomic_write "$(recon_hop_root)/dpkg_log_offset_before"
  log INFO "RUN_SCOPED_BASELINE=PASS"
  log INFO "RUN_ID=${run_id}"
  log INFO "BASELINE_HOP=${PIN_HOP}"
  log INFO "DPKG_LOG_OFFSET=${dpkg_off}"
  RECON_BASELINE_LOADED="YES"
  recon_load_baseline || true
}

recon_slice_log_after_baseline() {
  # Args: logfile baseline_inode baseline_offset [baseline_prefix_sha]
  # Prints bytes after baseline; on inode rotation, truncation, or prefix mismatch
  # (inode reuse after rm+create), only lines newer than RUN_STARTED_UTC — never
  # the whole replaced file.
  local logfile="$1" base_inode="$2" base_off="$3" base_psha="${4:-}"
  local cur_inode cur_size rotated=0 cur_psha
  [[ -f "$logfile" ]] || return 0
  cur_inode="$(recon_file_inode "$logfile")"
  cur_size="$(recon_file_size "$logfile")"
  if [[ -n "$base_inode" && "$base_inode" != "0" && "$cur_inode" != "$base_inode" ]]; then
    rotated=1
  fi
  if [[ "${base_off:-0}" =~ ^[0-9]+$ ]] && [[ "$base_off" -gt 0 ]] && [[ "$cur_size" -lt "$base_off" ]]; then
    rotated=1
  fi
  if [[ "$rotated" -eq 0 && -n "$base_psha" && "${base_off:-0}" =~ ^[0-9]+$ ]] && [[ "$base_off" -gt 0 ]]; then
    cur_psha="$(recon_prefix_sha "$logfile" "$base_off")"
    if [[ -n "$cur_psha" && "$cur_psha" != "$base_psha" ]]; then
      rotated=1
    fi
  fi
  if [[ "$rotated" -eq 1 ]]; then
    if [[ -n "${RECON_BASE_STARTED_UTC:-}" ]]; then
      awk -v start="${RECON_BASE_STARTED_UTC}" '
        BEGIN {
          gsub(/[-:TZ]/ "", start)
        }
        {
          line=$0
          ts=substr($0,1,19)
          gsub(/[-:TZ]/ "", ts)
          if (length(start) > 0 && length(ts) > 0 && ts >= start) print line
        }
      ' "$logfile" 2>/dev/null || true
    fi
    return 0
  fi
  if [[ "${base_off:-0}" =~ ^[0-9]+$ ]] && [[ "$base_off" -gt 0 ]]; then
    if [[ "$cur_size" -gt "$base_off" ]]; then
      tail -c +"$((base_off + 1))" "$logfile" 2>/dev/null || true
    fi
  fi
}

collect_package_transition_evidence() {
  PACKAGE_TRANSITION_EVIDENCE_LINES=""
  AUTHORITATIVE_EVIDENCE_COUNT=0
  STALE_EVIDENCE_COUNT=0
  PRE_TRANSITION_EVIDENCE_COUNT=0
  ACTIVE_UPGRADE_PROCESS="NO"
  DPKG_AUDIT_STATUS="CLEAN"
  CORE_PACKAGE_CONSISTENCY="SOURCE_CONSISTENT"
  local ver pkg ivers dpkglog apthist mainlog aptlog slice procs
  local target_pkgs=0 source_pkgs=0
  ver="$(read_os_field VERSION_ID)"

  recon_load_baseline || true

  # Active processes
  procs="$(recon_list_active_upgrade_processes)"
  if [[ -n "$(printf '%s' "$procs" | tr -d '[:space:]')" ]]; then
    ACTIVE_UPGRADE_PROCESS="YES"
    recon_append_evidence "ACTIVE_RELEASE_UPGRADE_PROCESS" "process_table" "ps" \
      "$(printf '%s' "$procs" | head -1)" "n/a"
  fi

  # OS already at target
  if [[ "$ver" == "$PIN_TARGET_VERSION" ]]; then
    recon_append_evidence "TARGET_RELEASE_REACHED" "os-release" "$(hostpath /etc/os-release)" \
      "VERSION_ID=${ver}" "n/a"
  fi

  # Core package consistency
  for pkg in base-files libc6 apt dpkg systemd systemd-sysv; do
    ivers=""
    if [[ -n "${TEST_ROOT:-}" && -f "$(hostpath ${STATE_ROOT}/force-target-core-packages)" ]]; then
      target_pkgs=1
      recon_append_evidence "AUTHORITATIVE_PACKAGE_TRANSITION" "test_fixture" \
        "$(hostpath ${STATE_ROOT}/force-target-core-packages)" "force-target-core-packages" "yes" "$pkg" "fixture"
      break
    fi
    # Fixture roots do not virtualize dpkg; never treat the host's installed
    # package versions as this-hop transition evidence under TEST_ROOT.
    if [[ -n "${TEST_ROOT:-}" ]]; then
      continue
    fi
    if declare -F pkg_installed_version >/dev/null 2>&1; then
      ivers="$(pkg_installed_version "$pkg")"
    fi
    if recon_is_target_version_for_pkg "$pkg" "$ivers"; then
      target_pkgs=$((target_pkgs + 1))
      recon_append_evidence "AUTHORITATIVE_PACKAGE_TRANSITION" "dpkg_status" \
        "$(hostpath /var/lib/dpkg/status)" "target_version" "yes" "$pkg" "$ivers"
    elif recon_is_source_version_for_pkg "$pkg" "$ivers"; then
      source_pkgs=$((source_pkgs + 1))
    fi
  done
  if [[ "$target_pkgs" -gt 0 && "$source_pkgs" -gt 0 && "$ver" == "$PIN_SOURCE_VERSION" ]]; then
    CORE_PACKAGE_CONSISTENCY="MIXED_SOURCE_TARGET"
    recon_append_evidence "MIXED_SOURCE_TARGET_PACKAGES" "dpkg_status" \
      "$(hostpath /var/lib/dpkg/status)" "mixed_core_packages" "yes"
  elif [[ "$target_pkgs" -gt 0 && "$ver" == "$PIN_SOURCE_VERSION" ]]; then
    CORE_PACKAGE_CONSISTENCY="TARGET_CORE_ON_SOURCE_OS"
  fi

  # dpkg audit / interrupted transaction
  if [[ -n "${TEST_ROOT:-}" ]]; then
    if [[ -f "$(hostpath /tmp/dpkg-broken)" ]]; then
      DPKG_AUDIT_STATUS="INTERRUPTED"
      recon_append_evidence "INTERRUPTED_DPKG_TRANSACTION" "test_fixture" \
        "$(hostpath /tmp/dpkg-broken)" "dpkg-broken" "yes"
    fi
    if [[ -f "$(hostpath ${STATE_ROOT}/force-upgrade-transaction-evidence)" ]]; then
      recon_append_evidence "AUTHORITATIVE_PACKAGE_TRANSITION" "test_fixture" \
        "$(hostpath ${STATE_ROOT}/force-upgrade-transaction-evidence)" "force-upgrade-transaction" "yes"
    fi
  else
    if recon_dpkg_audit_has_issues; then
      DPKG_AUDIT_STATUS="INTERRUPTED"
      recon_append_evidence "INTERRUPTED_DPKG_TRANSACTION" "dpkg_audit" "dpkg --audit" \
        "audit_output_present" "yes"
    fi
  fi

  # Current-hop package-transition flag (hop-owned)
  local dir
  dir="$(recon_critical_dir)"
  if [[ -f "$dir/release_upgrade_package_transition_started" ]] \
    && grep -qx 'true' "$dir/release_upgrade_package_transition_started" 2>/dev/null; then
    # If later hops provide ownership check, honour it.
    local owned=1
    if declare -F marker_owned_by_current_hop >/dev/null 2>&1; then
      marker_owned_by_current_hop "$dir/release_upgrade_package_transition_started" || owned=0
    fi
    if [[ "$owned" -eq 1 ]]; then
      recon_append_evidence "AUTHORITATIVE_PACKAGE_TRANSITION" "current_hop_marker" \
        "$dir/release_upgrade_package_transition_started" "package_transition_started=true" "yes"
    else
      recon_append_evidence "STALE_OR_PREBASELINE" "previous_hop_marker" \
        "$dir/release_upgrade_package_transition_started" "foreign_hop_marker" "no"
    fi
  fi

  # Configuration-only traces (sources/meta) — pre-transition, not mutation
  local sl meta
  sl="$(hostpath /etc/apt/sources.list)"
  meta="$(hostpath /etc/update-manager/meta-release)"
  if [[ -f "$sl" ]] && grep -qE "stellar-offline|${PIN_TARGET_CODENAME}" "$sl" 2>/dev/null; then
    recon_append_evidence "PRE_TRANSITION_CONFIGURATION_ONLY" "sources.list" "$sl" \
      "sources_rewrite_or_target_suite" "n/a"
  fi
  if [[ -f "$meta" ]]; then
    recon_append_evidence "PRE_TRANSITION_CONFIGURATION_ONLY" "meta-release" "$meta" \
      "meta_release_present" "n/a"
  fi

  # Log evidence: ONLY post-baseline for current hop. Whole-file scans of stale
  # apt/dpkg/dist-upgrade logs are classified STALE_OR_PREBASELINE, never authoritative.
  dpkglog="$(hostpath /var/log/dpkg.log)"
  apthist="$(hostpath /var/log/apt/history.log)"
  mainlog="$(hostpath /var/log/dist-upgrade/main.log)"
  aptlog="$(hostpath /var/log/dist-upgrade/apt.log)"

  if [[ "$RECON_BASELINE_LOADED" == "YES" ]]; then
    slice="$(recon_slice_log_after_baseline "$dpkglog" "${RECON_BASE_DPKG_INODE}" "${RECON_BASE_DPKG_OFFSET}" "${RECON_BASE_DPKG_PREFIX_SHA}")"
    if printf '%s' "$slice" | grep -q 'startup archives unpack'; then
      recon_append_evidence "AUTHORITATIVE_PACKAGE_TRANSITION" "dpkg.log" "$dpkglog" \
        "startup archives unpack (post-baseline)" "yes"
    fi
    if printf '%s' "$slice" | grep -qiE "status (half-installed|unpacked|installed) .*(libc6|base-files|libc-bin)"; then
      recon_append_evidence "AUTHORITATIVE_PACKAGE_TRANSITION" "dpkg.log" "$dpkglog" \
        "status unpack/install core (post-baseline)" "yes"
    fi
    slice="$(recon_slice_log_after_baseline "$apthist" "${RECON_BASE_APT_HIST_INODE}" "${RECON_BASE_APT_HIST_OFFSET}" "${RECON_BASE_APT_HIST_PREFIX_SHA}")"
    if printf '%s' "$slice" | grep -qiE "^(Install|Upgrade|Remove):"; then
      recon_append_evidence "AUTHORITATIVE_PACKAGE_TRANSITION" "apt/history.log" "$apthist" \
        "Install/Upgrade/Remove (post-baseline)" "yes"
    fi
  else
    # No baseline: any historical apt/dpkg/dist-upgrade hit is STALE for resume gating.
    if [[ -f "$dpkglog" ]] && grep -q 'startup archives unpack' "$dpkglog" 2>/dev/null; then
      recon_append_evidence "STALE_OR_PREBASELINE" "dpkg.log" "$dpkglog" \
        "historical unpack without current-hop baseline" "no"
    fi
    if [[ -f "$apthist" ]] \
      && grep -qiE "Upgrade:|Install:.*${PIN_TARGET_CODENAME}|Commandline:.*do-release-upgrade" "$apthist" 2>/dev/null; then
      recon_append_evidence "STALE_OR_PREBASELINE" "apt/history.log" "$apthist" \
        "historical apt Upgrade/Install without baseline" "no"
    fi
    if [[ -f "$mainlog" ]] \
      && grep -qiE 'apt\.distupgrade|Installing|upgrading packages' "$mainlog" 2>/dev/null; then
      recon_append_evidence "STALE_OR_PREBASELINE" "dist-upgrade/main.log" "$mainlog" \
        "historical dist-upgrade main.log" "no"
    fi
    if [[ -f "$aptlog" ]] && grep -qiE '^(Install|Upgrade|Remove):' "$aptlog" 2>/dev/null; then
      recon_append_evidence "STALE_OR_PREBASELINE" "dist-upgrade/apt.log" "$aptlog" \
        "historical dist-upgrade apt.log" "no"
    fi
  fi

  # Rotated old apt log under TEST_ROOT fixture path
  if [[ -n "${TEST_ROOT:-}" ]]; then
    local rotated
    rotated="$(hostpath /var/log/apt/history.log.1)"
    if [[ -f "$rotated" ]]; then
      recon_append_evidence "STALE_OR_PREBASELINE" "apt/history.log.1" "$rotated" \
        "rotated_history_ignored" "no"
    fi
  fi
}

classify_package_transition_evidence() {
  # Sets PACKAGE_TRANSITION_CLASS and counts from collected evidence.
  collect_package_transition_evidence
  local class="NONE"
  AUTHORITATIVE_EVIDENCE_COUNT=0
  STALE_EVIDENCE_COUNT=0
  PRE_TRANSITION_EVIDENCE_COUNT=0

  if printf '%s' "$PACKAGE_TRANSITION_EVIDENCE_LINES" | grep -q '^EVIDENCE_TYPE=ACTIVE_RELEASE_UPGRADE_PROCESS'; then
    class="ACTIVE_RELEASE_UPGRADE_PROCESS"
  fi
  if printf '%s' "$PACKAGE_TRANSITION_EVIDENCE_LINES" | grep -q '^EVIDENCE_TYPE=TARGET_RELEASE_REACHED'; then
    class="TARGET_RELEASE_REACHED"
  fi
  if printf '%s' "$PACKAGE_TRANSITION_EVIDENCE_LINES" | grep -q '^EVIDENCE_TYPE=MIXED_SOURCE_TARGET_PACKAGES'; then
    class="MIXED_SOURCE_TARGET_PACKAGES"
  fi
  if printf '%s' "$PACKAGE_TRANSITION_EVIDENCE_LINES" | grep -q '^EVIDENCE_TYPE=INTERRUPTED_DPKG_TRANSACTION'; then
    [[ "$class" == "NONE" || "$class" == "STALE_OR_PREBASELINE" || "$class" == "PRE_TRANSITION_CONFIGURATION_ONLY" ]] \
      && class="INTERRUPTED_DPKG_TRANSACTION"
  fi
  if printf '%s' "$PACKAGE_TRANSITION_EVIDENCE_LINES" | grep -q '^EVIDENCE_TYPE=AUTHORITATIVE_PACKAGE_TRANSITION'; then
    # Authoritative wins over stale/pre-config unless already target/active.
    case "$class" in
      TARGET_RELEASE_REACHED|ACTIVE_RELEASE_UPGRADE_PROCESS) ;;
      *) class="AUTHORITATIVE_PACKAGE_TRANSITION" ;;
    esac
  fi

  AUTHORITATIVE_EVIDENCE_COUNT="$(printf '%s' "$PACKAGE_TRANSITION_EVIDENCE_LINES" | grep -c '^EVIDENCE_TYPE=AUTHORITATIVE_PACKAGE_TRANSITION' || true)"
  STALE_EVIDENCE_COUNT="$(printf '%s' "$PACKAGE_TRANSITION_EVIDENCE_LINES" | grep -c '^EVIDENCE_TYPE=STALE_OR_PREBASELINE' || true)"
  PRE_TRANSITION_EVIDENCE_COUNT="$(printf '%s' "$PACKAGE_TRANSITION_EVIDENCE_LINES" | grep -c '^EVIDENCE_TYPE=PRE_TRANSITION_CONFIGURATION_ONLY' || true)"

  if [[ "$class" == "NONE" ]]; then
    if [[ "$PRE_TRANSITION_EVIDENCE_COUNT" -gt 0 ]]; then
      class="PRE_TRANSITION_CONFIGURATION_ONLY"
    elif [[ "$STALE_EVIDENCE_COUNT" -gt 0 ]]; then
      class="STALE_OR_PREBASELINE"
    fi
  fi

  # Ambiguous: legacy flag noise with no clean classification and no source consistency.
  if [[ "$class" == "NONE" ]] && [[ "${RELEASE_UPGRADE_STARTED:-false}" == "true" ]] \
    && [[ "$CORE_PACKAGE_CONSISTENCY" == "UNKNOWN" ]]; then
    class="AMBIGUOUS_LEGACY_EVIDENCE"
  fi

  PACKAGE_TRANSITION_CLASS="$class"
  case "$class" in
    AUTHORITATIVE_PACKAGE_TRANSITION|MIXED_SOURCE_TARGET_PACKAGES|INTERRUPTED_DPKG_TRANSACTION)
      AUTHORITATIVE_PACKAGE_TRANSITION="YES"
      ;;
    *)
      AUTHORITATIVE_PACKAGE_TRANSITION="NO"
      ;;
  esac
}

render_package_transition_evidence() {
  printf 'PACKAGE_TRANSITION_CLASS=%s\n' "${PACKAGE_TRANSITION_CLASS}"
  printf 'AUTHORITATIVE_EVIDENCE_COUNT=%s\n' "${AUTHORITATIVE_EVIDENCE_COUNT}"
  printf 'STALE_EVIDENCE_COUNT=%s\n' "${STALE_EVIDENCE_COUNT}"
  printf 'PRE_TRANSITION_EVIDENCE_COUNT=%s\n' "${PRE_TRANSITION_EVIDENCE_COUNT}"
  printf 'AUTHORITATIVE_PACKAGE_TRANSITION=%s\n' "${AUTHORITATIVE_PACKAGE_TRANSITION}"
  printf 'ACTIVE_UPGRADE_PROCESS=%s\n' "${ACTIVE_UPGRADE_PROCESS}"
  printf 'DPKG_AUDIT=%s\n' "${DPKG_AUDIT_STATUS}"
  printf 'CORE_PACKAGE_CONSISTENCY=%s\n' "${CORE_PACKAGE_CONSISTENCY}"
  printf 'PIN_HOP=%s\n' "${PIN_HOP}"
  printf 'CURRENT_RUN_ID=%s\n' "${CURRENT_RUN_ID:-}"
  printf 'RECON_BASELINE_LOADED=%s\n' "${RECON_BASELINE_LOADED}"
  if [[ -n "$PACKAGE_TRANSITION_EVIDENCE_LINES" ]]; then
    printf '%s' "$PACKAGE_TRANSITION_EVIDENCE_LINES"
  fi
}

recon_write_diagnostic_bundle() {
  local stamp dest
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  dest="$(recon_evidence_dir)/reconciliation-evidence.${stamp}"
  mkdir -p "$dest"
  {
    printf 'CURRENT_OS_VERSION=%s\n' "$(read_os_field VERSION_ID)"
    printf 'PIN_SOURCE_VERSION=%s\n' "$PIN_SOURCE_VERSION"
    printf 'PIN_TARGET_VERSION=%s\n' "$PIN_TARGET_VERSION"
    printf 'PIN_HOP=%s\n' "$PIN_HOP"
    printf 'STATE_VALUE=%s\n' "$(read_state 2>/dev/null || true)"
    printf 'LEGACY_RELEASE_UPGRADE_STARTED=%s\n' "${RELEASE_UPGRADE_STARTED:-false}"
    render_package_transition_evidence
    printf 'RECONCILIATION_DECISION=%s\n' "${RECONCILIATION_DECISION}"
    printf 'SAFE_TO_RERUN=%s\n' "${SAFE_TO_RERUN}"
    printf 'MANUAL_REVIEW_REQUIRED=%s\n' "${MANUAL_REVIEW_REQUIRED}"
  } >"${dest}/report.txt"
  DIAGNOSTIC_BUNDLE_PATH="$dest"
  log INFO "DIAGNOSTIC_BUNDLE_PATH=${dest}"
}

# Backward-compatible boolean: true only for AUTHORITATIVE / mixed / interrupted.
package_transition_evidence_present() {
  classify_package_transition_evidence
  case "$PACKAGE_TRANSITION_CLASS" in
    AUTHORITATIVE_PACKAGE_TRANSITION|MIXED_SOURCE_TARGET_PACKAGES|INTERRUPTED_DPKG_TRANSACTION)
      return 0
      ;;
    TARGET_RELEASE_REACHED)
      # Target reached is not "partial transition evidence" for resume-blocking
      # boolean used by pre-DRO gates; callers interested in target use class.
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# Legacy helper names still referenced by hop templates.
has_upgrade_transaction_evidence() {
  classify_package_transition_evidence
  [[ "$AUTHORITATIVE_PACKAGE_TRANSITION" == "YES" ]]
}

has_target_core_package_contamination() {
  classify_package_transition_evidence
  case "$CORE_PACKAGE_CONSISTENCY" in
    MIXED_SOURCE_TARGET|TARGET_CORE_ON_SOURCE_OS) return 0 ;;
  esac
  return 1
}

recon_backup_legacy_state() {
  local stamp dir hop_root bak
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  dir="$(recon_critical_dir)"
  hop_root="$(recon_hop_root)"
  bak="${hop_root}/legacy-backup.${stamp}"
  mkdir -p "$bak"
  # Never delete; quarantine copies.
  [[ -f "$(hostpath "$STATE_FILE")" ]] && cp -a "$(hostpath "$STATE_FILE")" "$bak/state.legacy.${stamp}" 2>/dev/null || true
  if [[ -d "$dir" ]]; then
    mkdir -p "$bak/flags.legacy.${stamp}"
    cp -a "$dir"/release_upgrade_* "$bak/flags.legacy.${stamp}/" 2>/dev/null || true
    cp -a "$dir"/legacy_state_reconciled "$bak/flags.legacy.${stamp}/" 2>/dev/null || true
    cp -a "$dir"/reconciliation_reason "$bak/flags.legacy.${stamp}/" 2>/dev/null || true
  fi
  log INFO "LEGACY_STATE_BACKUP=PASS"
  log INFO "LEGACY_STATE_BACKUP_PATH=${bak}"
  printf '%s\n' "$bak"
}

classify_previous_release_upgrade_failure() {
  RELEASE_UPGRADE_FAILURE_CLASS=""
  PREVIOUS_FAILURE_CLASS=""
  local ver
  ver="$(read_os_field VERSION_ID)"

  classify_package_transition_evidence

  case "$PACKAGE_TRANSITION_CLASS" in
    AUTHORITATIVE_PACKAGE_TRANSITION|MIXED_SOURCE_TARGET_PACKAGES|INTERRUPTED_DPKG_TRANSACTION|AMBIGUOUS_LEGACY_EVIDENCE)
      RELEASE_UPGRADE_FAILURE_CLASS="PARTIAL_OR_UNKNOWN_MUTATION"
      PREVIOUS_FAILURE_CLASS="$RELEASE_UPGRADE_FAILURE_CLASS"
      PARTIAL_RELEASE_TRANSITION="YES"
      return 1
      ;;
    TARGET_RELEASE_REACHED)
      RELEASE_UPGRADE_FAILURE_CLASS="TARGET_RELEASE_REACHED"
      PREVIOUS_FAILURE_CLASS="$RELEASE_UPGRADE_FAILURE_CLASS"
      PARTIAL_RELEASE_TRANSITION="NO"
      return 0
      ;;
    ACTIVE_RELEASE_UPGRADE_PROCESS)
      RELEASE_UPGRADE_FAILURE_CLASS="ACTIVE_UPGRADE_IN_PROGRESS"
      PREVIOUS_FAILURE_CLASS="$RELEASE_UPGRADE_FAILURE_CLASS"
      PARTIAL_RELEASE_TRANSITION="NO"
      return 1
      ;;
  esac

  if [[ "$ver" == "$PIN_SOURCE_VERSION" ]] \
    && declare -F detect_meta_release_encoding_failure_signature >/dev/null 2>&1 \
    && detect_meta_release_encoding_failure_signature; then
    RELEASE_UPGRADE_FAILURE_CLASS="PRE_MUTATION_META_RELEASE_ENCODING"
    PREVIOUS_FAILURE_CLASS="$RELEASE_UPGRADE_FAILURE_CLASS"
    PARTIAL_RELEASE_TRANSITION="NO"
    log INFO "RELEASE_UPGRADE_FAILURE_CLASS=PRE_MUTATION_CONFIG_PARSE"
    log INFO "RELEASE_UPGRADE_FAILURE_CLASS=${RELEASE_UPGRADE_FAILURE_CLASS}"
    log INFO "RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED=false"
    return 0
  fi

  if [[ "$ver" == "$PIN_SOURCE_VERSION" ]]; then
    # Clean source (stale logs / config-only / none) is auto-resumable.
    case "$PACKAGE_TRANSITION_CLASS" in
      NONE|STALE_OR_PREBASELINE|PRE_TRANSITION_CONFIGURATION_ONLY)
        RELEASE_UPGRADE_FAILURE_CLASS="PRE_MUTATION_CLEAN_SOURCE"
        PREVIOUS_FAILURE_CLASS="PRE_MUTATION_CLEAN_SOURCE"
        PARTIAL_RELEASE_TRANSITION="NO"
        return 0
        ;;
    esac
  fi

  RELEASE_UPGRADE_FAILURE_CLASS="UNCLASSIFIED"
  PREVIOUS_FAILURE_CLASS="$RELEASE_UPGRADE_FAILURE_CLASS"
  PARTIAL_RELEASE_TRANSITION="YES"
  return 1
}

reconcile_legacy_release_upgrade_state() {
  # Migrate legacy release_upgrade_started without treating stale logs as mutation.
  load_release_upgrade_started_flag 2>/dev/null || true
  if declare -F load_release_upgrade_started_flag_for_current_hop >/dev/null 2>&1; then
    load_release_upgrade_started_flag_for_current_hop
  fi
  local dir legacy=0 ver
  dir="$(recon_critical_dir)"
  [[ -f "$dir/release_upgrade_started" ]] && grep -qx 'true' "$dir/release_upgrade_started" && legacy=1

  if [[ "$legacy" -eq 0 && "${RELEASE_UPGRADE_STARTED:-false}" != "true" ]]; then
    return 0
  fi

  ver="$(read_os_field VERSION_ID)"
  classify_package_transition_evidence
  # Log evidence summary without process-substitution (Bash 4.3 + set -e safe).
  local _evid_tmp _line
  _evid_tmp="$(mktemp)"
  render_package_transition_evidence >"$_evid_tmp" || true
  while IFS= read -r _line || [[ -n "${_line:-}" ]]; do
    [[ -n "${_line:-}" ]] || continue
    log INFO "$_line"
  done <"$_evid_tmp"
  rm -f "$_evid_tmp"

  if [[ "$PACKAGE_TRANSITION_CLASS" == "ACTIVE_RELEASE_UPGRADE_PROCESS" ]]; then
    RECONCILIATION_DECISION="BUSY_IN_PROGRESS"
    MANUAL_REVIEW_REQUIRED="NO"
    SAFE_TO_RERUN="NO"
    log ERROR "RECONCILIATION_DECISION=BUSY_IN_PROGRESS"
    log ERROR "ACTIVE_UPGRADE_PROCESS=YES"
    die "${EC_BUSY:-22}" "FAIL_RELEASE_UPGRADE_BUSY"
  fi

  if [[ "$PACKAGE_TRANSITION_CLASS" == "TARGET_RELEASE_REACHED" || "$ver" == "$PIN_TARGET_VERSION" ]]; then
    recon_backup_legacy_state >/dev/null || true
    LEGACY_STATE_RECONCILED="true"
    RECONCILIATION_REASON="TARGET_RELEASE_REACHED"
    RECONCILIATION_DECISION="TARGET_RELEASE_REACHED"
    RESUME_FROM="POSTBOOT_VALIDATION"
    MANUAL_REVIEW_REQUIRED="NO"
    SAFE_TO_RERUN="NO"
    printf 'true\n' | recon_atomic_write "$dir/legacy_state_reconciled"
    printf '%s\n' "$RECONCILIATION_REASON" | recon_atomic_write "$dir/reconciliation_reason"
    if declare -F persist_release_upgrade_flags >/dev/null 2>&1; then
      persist_release_upgrade_flags
    fi
    log INFO "LEGACY_STATE_RECONCILED=true"
    log INFO "RECONCILIATION_DECISION=TARGET_RELEASE_REACHED"
    log INFO "RESUME_FROM=POSTBOOT_VALIDATION"
    log INFO "STATE_RECONCILIATION_WRITE=ATOMIC"
    log INFO "STATE_RECONCILIATION_RESULT=PASS"
    return 0
  fi

  case "$PACKAGE_TRANSITION_CLASS" in
    AUTHORITATIVE_PACKAGE_TRANSITION|MIXED_SOURCE_TARGET_PACKAGES|INTERRUPTED_DPKG_TRANSACTION|AMBIGUOUS_LEGACY_EVIDENCE)
      RECONCILIATION_DECISION="MANUAL_REVIEW"
      MANUAL_REVIEW_REQUIRED="YES"
      SAFE_TO_RERUN="NO"
      AUTHORITATIVE_PACKAGE_TRANSITION="YES"
      recon_write_diagnostic_bundle
      log ERROR "FAIL_RELEASE_UPGRADE_STATE_RECONCILIATION"
      log ERROR "MANUAL_REVIEW_REQUIRED=YES"
      log ERROR "RECONCILIATION_DECISION=MANUAL_REVIEW"
      log ERROR "AUTHORITATIVE_PACKAGE_TRANSITION=YES"
      log ERROR "EVIDENCE_COUNT=${AUTHORITATIVE_EVIDENCE_COUNT}"
      log ERROR "PACKAGE_TRANSITION_CLASS=${PACKAGE_TRANSITION_CLASS}"
      log ERROR "REASON=authoritative_package_transition_evidence"
      die "${EC_RESUME:-29}" "FAIL_RELEASE_UPGRADE_STATE_RECONCILIATION"
      ;;
  esac

  if [[ "${LEGACY_STATE_RECONCILED:-false}" == "true" && -n "${RECONCILIATION_REASON:-}" ]]; then
    log INFO "legacy_state_reconciled=true"
    log INFO "reconciliation_reason=${RECONCILIATION_REASON}"
    RECONCILIATION_DECISION="SAFE_PRE_TRANSITION_RESUME"
    return 0
  fi

  # Safe pre-transition resume: clean source + stale/config-only/none/encoding.
  if [[ "$ver" == "$PIN_SOURCE_VERSION" ]]; then
    case "$PACKAGE_TRANSITION_CLASS" in
      NONE|STALE_OR_PREBASELINE|PRE_TRANSITION_CONFIGURATION_ONLY)
        recon_backup_legacy_state >/dev/null || true
        RELEASE_UPGRADE_INVOCATION_STARTED="true"
        RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
        RELEASE_UPGRADE_STARTED="true"
        LEGACY_STATE_RECONCILED="true"
        RECONCILIATION_REASON="SAFE_PRE_TRANSITION_RESUME:${PACKAGE_TRANSITION_CLASS}"
        RECONCILIATION_DECISION="SAFE_PRE_TRANSITION_RESUME"
        RESUME_FROM="PRE_DRO_CONFIGURATION"
        MANUAL_REVIEW_REQUIRED="NO"
        SAFE_TO_RERUN="YES"
        PREVIOUS_FAILURE_CLASS="PRE_MUTATION_CLEAN_SOURCE"
        PARTIAL_RELEASE_TRANSITION="NO"
        printf 'true\n' | recon_atomic_write "$dir/legacy_state_reconciled"
        printf '%s\n' "$RECONCILIATION_REASON" | recon_atomic_write "$dir/reconciliation_reason"
        printf 'false\n' | recon_atomic_write "$dir/release_upgrade_package_transition_started"
        if declare -F persist_release_upgrade_flags >/dev/null 2>&1; then
          persist_release_upgrade_flags
        fi
        log INFO "LEGACY_STATE_RECONCILED=true"
        log INFO "RECONCILIATION_DECISION=SAFE_PRE_TRANSITION_RESUME"
        log INFO "RECONCILIATION_REASON=${RECONCILIATION_REASON}"
        log INFO "RESUME_FROM=PRE_DRO_CONFIGURATION"
        log INFO "MANUAL_REVIEW_REQUIRED=NO"
        log INFO "STATE_RECONCILIATION_WRITE=ATOMIC"
        log INFO "STATE_RECONCILIATION_RESULT=PASS"
        return 0
        ;;
    esac
  fi

  # Encoding / config-parse still reconcilable.
  if ! classify_previous_release_upgrade_failure; then
    RECONCILIATION_DECISION="MANUAL_REVIEW"
    MANUAL_REVIEW_REQUIRED="YES"
    recon_write_diagnostic_bundle
    log ERROR "FAIL_RELEASE_UPGRADE_STATE_RECONCILIATION"
    log ERROR "MANUAL_REVIEW_REQUIRED=YES"
    log ERROR "PREVIOUS_FAILURE_CLASS=${PREVIOUS_FAILURE_CLASS}"
    die "${EC_RESUME:-29}" "FAIL_RELEASE_UPGRADE_STATE_RECONCILIATION"
  fi

  case "$PREVIOUS_FAILURE_CLASS" in
    PRE_MUTATION_META_RELEASE_ENCODING|PRE_MUTATION_CONFIG_PARSE|PRE_MUTATION_CLEAN_SOURCE|TARGET_RELEASE_REACHED)
      ;;
    *)
      RECONCILIATION_DECISION="MANUAL_REVIEW"
      MANUAL_REVIEW_REQUIRED="YES"
      recon_write_diagnostic_bundle
      log ERROR "FAIL_RELEASE_UPGRADE_STATE_RECONCILIATION"
      log ERROR "MANUAL_REVIEW_REQUIRED=YES"
      die "${EC_RESUME:-29}" "FAIL_RELEASE_UPGRADE_STATE_RECONCILIATION"
      ;;
  esac

  recon_backup_legacy_state >/dev/null || true
  RELEASE_UPGRADE_INVOCATION_STARTED="true"
  RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
  RELEASE_UPGRADE_STARTED="true"
  LEGACY_STATE_RECONCILED="true"
  if [[ "$PREVIOUS_FAILURE_CLASS" == "PRE_MUTATION_META_RELEASE_ENCODING" ]]; then
    RECONCILIATION_REASON="META_RELEASE_CONFIG_PARSE_BEFORE_TRANSACTION"
  elif [[ "$PREVIOUS_FAILURE_CLASS" == "PRE_MUTATION_CLEAN_SOURCE" ]]; then
    RECONCILIATION_REASON="SAFE_PRE_TRANSITION_RESUME:${PACKAGE_TRANSITION_CLASS}"
  else
    RECONCILIATION_REASON="PRE_MUTATION_FAILURE_BEFORE_TRANSACTION"
  fi
  RECONCILIATION_DECISION="SAFE_PRE_TRANSITION_RESUME"
  RESUME_FROM="PRE_DRO_CONFIGURATION"
  MANUAL_REVIEW_REQUIRED="NO"
  SAFE_TO_RERUN="YES"
  printf 'true\n' | recon_atomic_write "$dir/legacy_state_reconciled"
  printf '%s\n' "$RECONCILIATION_REASON" | recon_atomic_write "$dir/reconciliation_reason"
  if declare -F persist_release_upgrade_flags >/dev/null 2>&1; then
    persist_release_upgrade_flags
  fi
  log INFO "release_upgrade_invocation_started=true"
  log INFO "release_upgrade_package_transition_started=false"
  log INFO "LEGACY_STATE_RECONCILED=true"
  log INFO "RECONCILIATION_DECISION=${RECONCILIATION_DECISION}"
  log INFO "reconciliation_reason=${RECONCILIATION_REASON}"
  log INFO "STATE_RECONCILIATION_WRITE=ATOMIC"
  log INFO "STATE_RECONCILIATION_RESULT=PASS"
  return 0
}

assess_safe_resume_from_failed() {
  # Return 0 when FAILED state is a safe pre-mutation resume candidate.
  local ver st
  ver="$(read_os_field VERSION_ID)"
  st="$(read_state)"
  PREVIOUS_FAILURE_DETECTED="YES"
  load_release_upgrade_started_flag 2>/dev/null || true
  if declare -F load_release_upgrade_started_flag_for_current_hop >/dev/null 2>&1; then
    load_release_upgrade_started_flag_for_current_hop
  fi

  classify_package_transition_evidence

  if [[ "$PACKAGE_TRANSITION_CLASS" == "ACTIVE_RELEASE_UPGRADE_PROCESS" ]]; then
    log ERROR "RESUME_SAFETY_VALIDATION=FAIL"
    log ERROR "REASON=active_upgrade_process"
    RECONCILIATION_DECISION="BUSY_IN_PROGRESS"
    return 1
  fi

  if [[ "$ver" == "$PIN_TARGET_VERSION" || "$PACKAGE_TRANSITION_CLASS" == "TARGET_RELEASE_REACHED" ]]; then
    RECONCILIATION_DECISION="TARGET_RELEASE_REACHED"
    RESUME_FROM="POSTBOOT_VALIDATION"
    PREVIOUS_FAILURE_CLASS="TARGET_RELEASE_REACHED"
    PARTIAL_RELEASE_TRANSITION="NO"
    MANUAL_REVIEW_REQUIRED="NO"
    log INFO "RESUME_SAFETY_VALIDATION=PASS"
    log INFO "RESUME_FROM=POSTBOOT_VALIDATION"
    return 0
  fi

  if [[ "$ver" != "$PIN_SOURCE_VERSION" ]]; then
    log ERROR "RESUME_SAFETY_VALIDATION=FAIL"
    log ERROR "REASON=os_not_source_version"
    return 1
  fi

  if [[ "$st" == "FAILED_PRE_DRO" || "$st" == "FAILED_PRE_DRO_STALE" \
     || "$st" == "FAILED_BEFORE_PACKAGE_TRANSITION" ]]; then
    if [[ "${RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED:-false}" != "true" ]] \
      && ! package_transition_evidence_present; then
      PREVIOUS_FAILURE_CLASS="PRE_DRO_FAILURE_BEFORE_TRANSACTION"
      PARTIAL_RELEASE_TRANSITION="NO"
      RESUME_FROM="PRE_DRO_CONFIGURATION"
      RECONCILIATION_DECISION="SAFE_PRE_TRANSITION_RESUME"
      MANUAL_REVIEW_REQUIRED="NO"
      if declare -F verify_prior_critical_hold_resume_consistency >/dev/null 2>&1; then
        verify_prior_critical_hold_resume_consistency
      fi
      if declare -F log_idempotent_prep_states >/dev/null 2>&1; then
        log_idempotent_prep_states
      fi
      log INFO "PREVIOUS_FAILURE_DETECTED=YES"
      log INFO "PREVIOUS_FAILURE_CLASS=${PREVIOUS_FAILURE_CLASS}"
      log INFO "PARTIAL_RELEASE_TRANSITION=NO"
      log INFO "RESUME_SAFETY_VALIDATION=PASS"
      log INFO "RESUME_FROM=${RESUME_FROM}"
      return 0
    fi
  fi

  reconcile_legacy_release_upgrade_state

  if [[ "${RECONCILIATION_DECISION}" == "TARGET_RELEASE_REACHED" ]]; then
    return 0
  fi

  if ! classify_previous_release_upgrade_failure; then
    log ERROR "RESUME_SAFETY_VALIDATION=FAIL"
    log ERROR "PARTIAL_RELEASE_TRANSITION=${PARTIAL_RELEASE_TRANSITION}"
    log ERROR "PREVIOUS_FAILURE_CLASS=${PREVIOUS_FAILURE_CLASS:-UNCLASSIFIED}"
    log ERROR "PACKAGE_TRANSITION_CLASS=${PACKAGE_TRANSITION_CLASS}"
    return 1
  fi

  case "$PREVIOUS_FAILURE_CLASS" in
    PRE_MUTATION_META_RELEASE_ENCODING|PRE_MUTATION_CONFIG_PARSE|PRE_MUTATION_CLEAN_SOURCE|TARGET_RELEASE_REACHED)
      ;;
    *)
      log ERROR "RESUME_SAFETY_VALIDATION=FAIL"
      log ERROR "REASON=failure_class_not_auto_resumable"
      log ERROR "PREVIOUS_FAILURE_CLASS=${PREVIOUS_FAILURE_CLASS}"
      return 1
      ;;
  esac

  if declare -F verify_prior_critical_hold_resume_consistency >/dev/null 2>&1; then
    verify_prior_critical_hold_resume_consistency
  fi
  if declare -F log_idempotent_prep_states >/dev/null 2>&1; then
    log_idempotent_prep_states
  fi

  RESUME_FROM="PRE_DRO_CONFIGURATION"
  RECONCILIATION_DECISION="SAFE_PRE_TRANSITION_RESUME"
  MANUAL_REVIEW_REQUIRED="NO"
  SAFE_TO_RERUN="YES"
  log INFO "PREVIOUS_FAILURE_DETECTED=YES"
  log INFO "PREVIOUS_FAILURE_CLASS=${PREVIOUS_FAILURE_CLASS}"
  log INFO "PARTIAL_RELEASE_TRANSITION=NO"
  log INFO "RESUME_SAFETY_VALIDATION=PASS"
  log INFO "RESUME_FROM=${RESUME_FROM}"
  log INFO "RECONCILIATION_DECISION=${RECONCILIATION_DECISION}"
  return 0
}

diagnose_release_upgrade_state() {
  # Read-only diagnostic. Never mutates apt/dpkg/state/systemd/login/packages.
  classify_package_transition_evidence
  local ver st
  ver="$(read_os_field VERSION_ID)"
  st="$(read_state 2>/dev/null || true)"
  load_release_upgrade_started_flag 2>/dev/null || true

  RECONCILIATION_DECISION="DIAGNOSE_ONLY"
  SAFE_TO_RERUN="NO"
  MANUAL_REVIEW_REQUIRED="NO"
  case "$PACKAGE_TRANSITION_CLASS" in
    NONE|STALE_OR_PREBASELINE|PRE_TRANSITION_CONFIGURATION_ONLY)
      if [[ "$ver" == "$PIN_SOURCE_VERSION" ]]; then
        SAFE_TO_RERUN="YES"
        RECONCILIATION_DECISION="SAFE_PRE_TRANSITION_RESUME"
      fi
      ;;
    TARGET_RELEASE_REACHED)
      RECONCILIATION_DECISION="TARGET_RELEASE_REACHED"
      SAFE_TO_RERUN="NO"
      ;;
    ACTIVE_RELEASE_UPGRADE_PROCESS)
      RECONCILIATION_DECISION="BUSY_IN_PROGRESS"
      SAFE_TO_RERUN="NO"
      ;;
    AUTHORITATIVE_PACKAGE_TRANSITION|MIXED_SOURCE_TARGET_PACKAGES|INTERRUPTED_DPKG_TRANSACTION|AMBIGUOUS_LEGACY_EVIDENCE)
      RECONCILIATION_DECISION="MANUAL_REVIEW"
      MANUAL_REVIEW_REQUIRED="YES"
      SAFE_TO_RERUN="NO"
      ;;
  esac

  printf 'CURRENT_OS_VERSION=%s\n' "$ver"
  printf 'PIN_SOURCE_VERSION=%s\n' "$PIN_SOURCE_VERSION"
  printf 'PIN_TARGET_VERSION=%s\n' "$PIN_TARGET_VERSION"
  printf 'PIN_HOP=%s\n' "$PIN_HOP"
  printf 'STATE_VALUE=%s\n' "$st"
  printf 'LEGACY_RELEASE_UPGRADE_STARTED=%s\n' "${RELEASE_UPGRADE_STARTED:-false}"
  printf 'PACKAGE_TRANSITION_CLASS=%s\n' "$PACKAGE_TRANSITION_CLASS"
  printf 'AUTHORITATIVE_EVIDENCE_COUNT=%s\n' "$AUTHORITATIVE_EVIDENCE_COUNT"
  printf 'STALE_EVIDENCE_COUNT=%s\n' "$STALE_EVIDENCE_COUNT"
  printf 'DPKG_AUDIT=%s\n' "$DPKG_AUDIT_STATUS"
  printf 'CORE_PACKAGE_CONSISTENCY=%s\n' "$CORE_PACKAGE_CONSISTENCY"
  printf 'ACTIVE_UPGRADE_PROCESS=%s\n' "$ACTIVE_UPGRADE_PROCESS"
  printf 'RECONCILIATION_DECISION=%s\n' "$RECONCILIATION_DECISION"
  printf 'SAFE_TO_RERUN=%s\n' "$SAFE_TO_RERUN"
  printf 'MANUAL_REVIEW_REQUIRED=%s\n' "$MANUAL_REVIEW_REQUIRED"
  recon_write_diagnostic_bundle
  return 0
}
