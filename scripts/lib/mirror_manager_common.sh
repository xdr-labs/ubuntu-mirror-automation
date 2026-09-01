#!/usr/bin/env bash
# scripts/lib/mirror_manager_common.sh — shared helpers for DP Upgrade Mirror Manager
# shellcheck shell=bash
set +x

if [[ -n "${MIRROR_MANAGER_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
MIRROR_MANAGER_COMMON_LOADED=1

MM_PROJECT_ROOT="${MM_PROJECT_ROOT:-}"
MM_MIRROR_ROOT="${MM_MIRROR_ROOT:-/var/spool/apt-mirror}"
MM_SELECTIVE_ROOT="${MM_SELECTIVE_ROOT:-${MM_MIRROR_ROOT}/selective}"
MM_DP_PHASE2_ROOT="${MM_DP_PHASE2_ROOT:-${MM_MIRROR_ROOT}/dp-phase2}"
MM_CLIENT_ROOT="${MM_CLIENT_ROOT:-${MM_MIRROR_ROOT}/client}"
MM_LOG_DIR="${MM_LOG_DIR:-/var/log/ubuntu-mirror-automation}"
MM_STATE_ROOT="${MM_STATE_ROOT:-/var/lib/ubuntu-mirror-automation/runs}"
MM_CONFIG_DIR="${MM_CONFIG_DIR:-/etc/ubuntu-mirror}"
MM_CONFIG_FILE="${MM_CONFIG_FILE:-${MM_CONFIG_DIR}/dp-upgrade-mirror.conf}"
MM_STATUS_FILE="${MM_STATUS_FILE:-${MM_CONFIG_DIR}/dp-upgrade-mirror.status}"
MM_LOCK_FILE="${MM_LOCK_FILE:-/run/ubuntu-mirror-manager.lock}"
MM_CACHE_ROOT="${MM_CACHE_ROOT:-${MM_MIRROR_ROOT}/.install-cache}"
MM_VERIFY_HTTP_BASE="${MM_VERIFY_HTTP_BASE:-http://127.0.0.1}"
MM_SKIP_ROOT_CHECK="${MM_SKIP_ROOT_CHECK:-0}"

# Authoritative Mirror Host IPv4 resolution (single source of truth).
# shellcheck source=mirror_host_ip.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mirror_host_ip.sh"
# HTTP public-tree permission contract (nginx-readable publish).
# shellcheck source=http_publication_permissions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/http_publication_permissions.sh"
# Generation-bound workflow state machine.
# shellcheck source=mirror_workflow_state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mirror_workflow_state.sh"

# Fixed ACPS endpoint (not user-editable). Credentials come from GUI config only.
ACPS_BASE_URL_FIXED="${ACPS_BASE_URL_FIXED:-https://acps.stellarcyber.ai/provision/aelladeb_py3}"

# Cloudflare R2 OS Core package URL — single code constant (custom domain).
# Checksum sidecar is derived as "${OS_CORE_R2_URL}.sha256" (no separate constant).
# Tests may override via environment: OS_CORE_R2_URL=http://127.0.0.1:<port>/pkg.tar
# shellcheck disable=SC2034
OS_CORE_R2_URL_CONSTANT="https://xdrsolutions.uk/ubuntu-os-core/ubuntu-os-core-xenial-to-noble.tar"
: "${OS_CORE_R2_URL:=${OS_CORE_R2_URL_CONSTANT}}"

MM_LOCK_FD=""
MM_LOCK_HELD=0
MM_RUN_ID="${MM_RUN_ID:-}"
MM_LOG_FILE="${MM_LOG_FILE:-}"
MM_STATE_DIR="${MM_STATE_DIR:-}"
MM_DRY_RUN="${MM_DRY_RUN:-0}"
MM_FILES_CHANGED="${MM_FILES_CHANGED:-NO}"

# Immutable production Phase 2 target. Saved workflow/config/environment
# must not restore a previous target (e.g. 6.5.0). Tests may set
# MM_ALLOW_TARGET_OVERRIDE=1 to exercise non-production versions.
PHASE2_TARGET_VERSION_FIXED="6.6.0"
PHASE2_TARGET_VERSION="${PHASE2_TARGET_VERSION_FIXED}"
TARGET_DP_VERSION="${PHASE2_TARGET_VERSION}"

# FULL = Ubuntu 16.04→24.04 OS hops + Phase 2
# PHASE2_ONLY = DP already on Ubuntu 24.04; Phase 2 artifacts only
PREPARATION_MODE="${PREPARATION_MODE:-FULL}"

ACPS_USERNAME="${ACPS_USERNAME:-}"
ACPS_PASSWORD="${ACPS_PASSWORD:-}"
WORKER_SSH_PASSWORD="${WORKER_SSH_PASSWORD:-}"
DL_WORKER_IPS="${DL_WORKER_IPS:-}"
DA_WORKER_IPS="${DA_WORKER_IPS:-}"

# Bash-safe quoting for generated operator commands (passwords with $ ! @ # & etc.).
mm_shell_quote() {
  printf '%q' "$1"
}

# Reject dangerous roots and paths that escape an approved root before rm -rf.
# approved_root may be empty only when MM_ALLOW_ARBITRARY_TEST_ROOTS=1 (tests).
mm_path_is_forbidden_root() {
  local p="$1"
  case "$p" in
    /|/etc|/var|/var/lib|/var/log|/home|/opt|/usr|/bin|/sbin|/lib|/lib64|/boot|/root|/tmp)
      return 0
      ;;
  esac
  return 1
}

mm_assert_safe_destructive_path() {
  local path="$1"
  local approved_root="${2:-}"
  local label="${3:-path}"
  local resolved approved_resolved parent
  [[ -n "$path" ]] || {
    printf 'DESTRUCTIVE_PATH=FAIL label=%s reason=empty\n' "$label" >&2
    return 1
  }
  # Resolve when the path (or parent) exists; otherwise normalize lexically.
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
  # Collapse duplicate slashes / trailing slash for comparisons.
  resolved="${resolved%/}"
  [[ -n "$resolved" ]] || resolved="/"
  if mm_path_is_forbidden_root "$resolved"; then
    printf 'DESTRUCTIVE_PATH=FAIL label=%s reason=forbidden_root path=%s\n' "$label" "$resolved" >&2
    return 1
  fi
  # Refuse symlink-at-path when it escapes approved_root (if provided).
  if [[ -n "$approved_root" ]]; then
    if [[ -e "$approved_root" ]]; then
      approved_resolved="$(realpath -m "$approved_root" 2>/dev/null || printf '%s' "$approved_root")"
    else
      approved_resolved="${approved_root%/}"
    fi
    approved_resolved="${approved_resolved%/}"
    if mm_path_is_forbidden_root "$approved_resolved"; then
      printf 'DESTRUCTIVE_PATH=FAIL label=%s reason=approved_root_forbidden path=%s\n' \
        "$label" "$approved_resolved" >&2
      return 1
    fi
    case "$resolved" in
      "$approved_resolved"|"$approved_resolved"/*) ;;
      *)
        printf 'DESTRUCTIVE_PATH=FAIL label=%s reason=outside_approved_root path=%s root=%s\n' \
          "$label" "$resolved" "$approved_resolved" >&2
        return 1
        ;;
    esac
  elif [[ "${MM_ALLOW_ARBITRARY_TEST_ROOTS:-0}" != "1" ]]; then
    printf 'DESTRUCTIVE_PATH=FAIL label=%s reason=approved_root_required path=%s\n' \
      "$label" "$resolved" >&2
    return 1
  fi
  # Minimum depth: refuse deleting shallow paths like /var/spool
  local depth
  depth="$(awk -F/ '{print NF-1}' <<<"$resolved")"
  if [[ "$depth" -lt 3 ]]; then
    printf 'DESTRUCTIVE_PATH=FAIL label=%s reason=insufficient_depth path=%s\n' \
      "$label" "$resolved" >&2
    return 1
  fi
  return 0
}

# Parse KEY=VALUE metadata; duplicate keys always fail (no first/last-wins).
# Prints value of requested key to stdout when key is set; with no key prints nothing
# but still validates. Returns 1 on parse/duplicate errors.
mm_parse_env_metadata_get() {
  local file="$1"
  local want="${2:-}"
  local line key value
  local -A seen=()
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || return 1
    key="${line%%=*}"
    value="${line#*=}"
    [[ "$key" =~ ^[A-Z0-9_]+$ ]] || return 1
    if [[ -n "${seen[$key]:-}" ]]; then
      printf 'METADATA_DUPLICATE_KEY=%s file=%s\n' "$key" "$file" >&2
      return 1
    fi
    seen["$key"]=1
    if [[ -n "$want" && "$key" == "$want" ]]; then
      printf '%s\n' "$value"
    fi
  done <"$file"
  if [[ -n "$want" && -z "${seen[$want]:-}" ]]; then
    return 1
  fi
  return 0
}

# Empty password is allowed when no worker IPs are configured.
# One or more worker IPs require a non-empty worker SSH password.
mm_validate_worker_ssh_password() {
  local password="$1"
  local worker_ips="${2:-}"
  if [[ -n "$worker_ips" && -z "$password" ]]; then
    return 1
  fi
  return 0
}

mm_force_phase2_target() {
  PHASE2_TARGET_VERSION="${PHASE2_TARGET_VERSION_FIXED:-6.6.0}"
  if [[ "${MM_ALLOW_TARGET_OVERRIDE:-0}" == "1" ]]; then
    TARGET_DP_VERSION="${TARGET_DP_VERSION:-${PHASE2_TARGET_VERSION}}"
  else
    TARGET_DP_VERSION="${PHASE2_TARGET_VERSION}"
  fi
  DP_PHASE2_VERSION="${TARGET_DP_VERSION}"
}

mm_normalize_preparation_mode() {
  case "${PREPARATION_MODE:-}" in
    FULL|PHASE2_ONLY) ;;
    full) PREPARATION_MODE=FULL ;;
    phase2_only|PHASE2|phase2) PREPARATION_MODE=PHASE2_ONLY ;;
    *) PREPARATION_MODE=FULL ;;
  esac
}

mm_preparation_mode_label() {
  mm_normalize_preparation_mode
  case "${PREPARATION_MODE}" in
    PHASE2_ONLY) printf 'Phase 2 Only' ;;
    *) printf 'Full OS Upgrade + Phase 2' ;;
  esac
}

mm_is_phase2_only() {
  mm_normalize_preparation_mode
  [[ "${PREPARATION_MODE}" == "PHASE2_ONLY" ]]
}

mm_config_footer_text() {
  cat <<'EOF'
Starting DP Version: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0
Phase 2 Target:      6.6.0 (fixed)
DP OS version: 16.04

If the DP is already running Ubuntu 24.04, select Phase 2 Only.
EOF
}

mm_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
mm_run_id() { date -u +%Y%m%dT%H%M%SZ; }

mm_redact() {
  sed -E \
    -e 's/(ACPS_PASSWORD|ACPS_PASS|ACPS_TOKEN|PASSWORD|TOKEN|PASSWD|WORKER_SSH_PASSWORD)=[^[:space:]]+/\1=***/Ig' \
    -e 's/(--worker-password(=|[[:space:]]+))([^[:space:]]+)/\1***/g' \
    -e 's/(-u[[:space:]]+)[^[:space:]]+/\1***/g' \
    -e 's#(://[^:/@]+:)[^@/]+@#\1***@#g' \
    -e 's/Authorization:[[:space:]]*Basic[[:space:]]+[^[:space:]]+/Authorization: Basic ***/Ig' \
    -e 's/Authorization:[[:space:]]*Bearer[[:space:]]+[^[:space:]]+/Authorization: Bearer ***/Ig'
}

# Operator-facing command/report files may mention operational detail but must
# never be world-readable when they can contain secrets or routing evidence.
MM_PRIVATE_FILE_MODE="${MM_PRIVATE_FILE_MODE:-0600}"
MM_PRIVATE_DIR_MODE="${MM_PRIVATE_DIR_MODE:-0700}"
MM_PUBLIC_FILE_MODE="${MM_PUBLIC_FILE_MODE:-0644}"

mm_format_bytes() {
  local b="${1:-0}"
  if ! [[ "$b" =~ ^[0-9]+$ ]]; then
    printf '%s' "$b"
    return 0
  fi
  if [[ "$b" -ge $((1024 * 1024 * 1024)) ]]; then
    awk -v n="$b" 'BEGIN { printf "%.2f GiB", n / (1024*1024*1024) }'
  elif [[ "$b" -ge $((1024 * 1024)) ]]; then
    awk -v n="$b" 'BEGIN { printf "%.1f MiB", n / (1024*1024) }'
  elif [[ "$b" -ge 1024 ]]; then
    awk -v n="$b" 'BEGIN { printf "%.1f KiB", n / 1024 }'
  else
    printf '%s B' "$b"
  fi
}

mm_format_rate() {
  local bps="${1:-0}"
  if ! [[ "$bps" =~ ^[0-9]+$ ]]; then
    printf '%s' "$bps"
    return 0
  fi
  printf '%s/s' "$(mm_format_bytes "$bps")"
}

mm_log() {
  local level="$1"; shift
  local msg="$*"
  local line
  line="$(mm_ts) [${level}] ${msg}"
  line="$(printf '%s\n' "$line" | mm_redact)"
  case "$level" in
    ERROR|WARN) printf '%s\n' "$line" >&2 ;;
    *) printf '%s\n' "$line" ;;
  esac
  # Always mirror progress to the controlling terminal so GUI capture cannot hide it.
  if [[ "${MM_LIVE_PROGRESS:-0}" == "1" ]]; then
    if { printf '%s\n' "$line" >/dev/tty; } 2>/dev/null; then
      :
    fi
  fi
  if [[ -n "${MM_LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "$MM_LOG_FILE")" 2>/dev/null || true
    printf '%s\n' "$line" >>"$MM_LOG_FILE" 2>/dev/null || true
  fi
}
mm_info() { mm_log INFO "$*"; }
mm_warn() { mm_log WARN "$*"; }
mm_error() { mm_log ERROR "$*"; }
mm_ok() { mm_log OK "$*"; }
mm_die() { mm_error "$*"; exit 1; }

mm_progress_line() {
  # Human-readable download progress for operators watching the terminal.
  local label="$1" downloaded="$2" expected="$3" elapsed="$4" rate="$5"
  local pct="--" down_h exp_h rate_h
  down_h="$(mm_format_bytes "$downloaded")"
  if [[ "$expected" =~ ^[0-9]+$ && "$expected" -gt 0 ]]; then
    pct=$((downloaded * 100 / expected))
    [[ "$pct" -gt 100 ]] && pct=100
    exp_h="$(mm_format_bytes "$expected")"
  else
    exp_h="unknown"
  fi
  if [[ "$rate" =~ ^[0-9]+$ ]]; then
    rate_h="$(mm_format_rate "$rate")"
  else
    rate_h="--"
  fi
  mm_info "PROGRESS ${label}: ${down_h} / ${exp_h} (${pct}%) elapsed=${elapsed}s rate=${rate_h}"
}

# Long-running Download/Prepare steps: heartbeat every N seconds (tests may set 1).
MM_LONG_STEP_HEARTBEAT_SEC="${MM_LONG_STEP_HEARTBEAT_SEC:-30}"

mm_long_step_heartbeat_seconds() {
  local hb="${MM_LONG_STEP_HEARTBEAT_SEC:-30}"
  if ! [[ "$hb" =~ ^[1-9][0-9]*$ ]]; then
    hb=30
  fi
  printf '%s\n' "$hb"
}

mm_set_phase() {
  local phase="$1"
  mm_info "DP_PHASE=${phase}"
  mm_info "Phase: ${phase}"
}

mm_human_lines() {
  # Emit one human-readable INFO line per argument (no adjacent duplicates).
  local line prev=""
  for line in "$@"; do
    [[ -n "$line" ]] || continue
    [[ "$line" == "$prev" ]] && continue
    mm_info "$line"
    prev="$line"
  done
}

# Last successful command stdout from mm_bg_with_heartbeat (not mixed into logs).
MM_LONG_STEP_LAST_STDOUT=""
MM_LONG_STEP_LAST_ELAPSED=0

# Background a command with heartbeat only. Caller emits START/COMPLETE.
# Sets MM_LONG_STEP_LAST_STDOUT and MM_LONG_STEP_LAST_ELAPSED. Preserves child rc.
# Usage: mm_bg_with_heartbeat EVENT_PREFIX "k=v ..." "human still..." -- cmd args...
mm_bg_with_heartbeat() {
  local event_prefix="$1"
  local fields="$2"
  local human_still="${3:-Still working...}"
  shift 3
  if [[ "${1:-}" != "--" ]]; then
    mm_die "mm_bg_with_heartbeat: expected -- before command"
  fi
  shift

  local start_ts hb_secs hb_pid="" cmd_pid="" rc=0 elapsed
  local out err last_hb_line="" hb_line
  MM_LONG_STEP_LAST_STDOUT=""
  MM_LONG_STEP_LAST_ELAPSED=0
  start_ts="$(date +%s)"
  hb_secs="$(mm_long_step_heartbeat_seconds)"
  out="$(mktemp)"
  err="$(mktemp)"

  "$@" >"$out" 2>"$err" &
  cmd_pid=$!

  _mm_hb_cleanup() {
    kill "$cmd_pid" 2>/dev/null || true
    kill "$hb_pid" 2>/dev/null || true
  }
  trap '_mm_hb_cleanup' INT TERM

  (
    while kill -0 "$cmd_pid" 2>/dev/null; do
      sleep "$hb_secs" || break
      kill -0 "$cmd_pid" 2>/dev/null || break
      elapsed=$(( $(date +%s) - start_ts ))
      hb_line="${event_prefix}_HEARTBEAT ${fields} elapsed=${elapsed}s status=running"
      if [[ "$hb_line" != "$last_hb_line" ]]; then
        mm_info "$hb_line"
        mm_human_lines \
          "$human_still" \
          "Elapsed: ${elapsed} seconds" \
          "The program is running normally."
        last_hb_line="$hb_line"
      fi
    done
  ) &
  hb_pid=$!

  if wait "$cmd_pid"; then
    rc=0
  else
    rc=$?
  fi

  if [[ -n "$hb_pid" ]]; then
    kill "$hb_pid" 2>/dev/null || true
    wait "$hb_pid" 2>/dev/null || true
  fi
  trap - INT TERM

  elapsed=$(( $(date +%s) - start_ts ))
  MM_LONG_STEP_LAST_ELAPSED="$elapsed"
  if [[ "$rc" -eq 0 ]]; then
    MM_LONG_STEP_LAST_STDOUT="$(cat "$out")"
    rm -f "$out" "$err"
    return 0
  fi
  mm_redact <"$err" >&2 || true
  rm -f "$out" "$err"
  return "$rc"
}

# Run a command with START / HEARTBEAT / COMPLETE|FAIL. Preserves child rc.
# Usage: mm_run_with_heartbeat EVENT_PREFIX "k=v ..." "human still..." -- cmd args...
mm_run_with_heartbeat() {
  local event_prefix="$1"
  local fields="$2"
  local human_still="${3:-Still working...}"
  shift 3
  if [[ "${1:-}" != "--" ]]; then
    mm_die "mm_run_with_heartbeat: expected -- before command"
  fi
  shift
  local rc=0
  mm_info "${event_prefix}_START ${fields}"
  # Do not toggle set -e here — it would leak into the caller.
  mm_bg_with_heartbeat "$event_prefix" "$fields" "$human_still" -- "$@" && rc=0 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    mm_ok "${event_prefix}_COMPLETE ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=PASS"
    return 0
  fi
  mm_error "${event_prefix}_FAIL ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=FAIL rc=${rc}"
  return "$rc"
}

# Like mm_run_with_heartbeat but also reports growing output-file size as progress.
# Usage: mm_run_with_file_progress EVENT_PREFIX "k=v" OUT_FILE EXPECTED_BYTES "human still" -- cmd...
mm_run_with_file_progress() {
  local event_prefix="$1"
  local fields="$2"
  local out_file="$3"
  local expected_bytes="$4"
  local human_still="${5:-Still working...}"
  shift 5
  if [[ "${1:-}" != "--" ]]; then
    mm_die "mm_run_with_file_progress: expected -- before command"
  fi
  shift

  local start_ts hb_secs hb_pid="" cmd_pid="" rc=0 elapsed
  local err last_prog="" written pct written_h expected_h prog_line
  start_ts="$(date +%s)"
  hb_secs="$(mm_long_step_heartbeat_seconds)"
  err="$(mktemp)"

  mm_info "${event_prefix}_START ${fields}"

  "$@" 2>"$err" &
  cmd_pid=$!

  _mm_prog_cleanup() {
    kill "$cmd_pid" 2>/dev/null || true
    kill "$hb_pid" 2>/dev/null || true
  }
  trap '_mm_prog_cleanup' INT TERM

  (
    while kill -0 "$cmd_pid" 2>/dev/null; do
      sleep "$hb_secs" || break
      kill -0 "$cmd_pid" 2>/dev/null || break
      elapsed=$(( $(date +%s) - start_ts ))
      written=0
      [[ -f "$out_file" ]] && written="$(stat -c%s "$out_file" 2>/dev/null || echo 0)"
      pct="UNKNOWN"
      if [[ "$expected_bytes" =~ ^[0-9]+$ && "$expected_bytes" -gt 0 ]]; then
        pct=$((written * 100 / expected_bytes))
        [[ "$pct" -gt 100 ]] && pct=100
      fi
      prog_line="${event_prefix}_PROGRESS written_bytes=${written} expected_bytes=${expected_bytes:-UNKNOWN} percentage=${pct} elapsed=${elapsed}s"
      [[ "$prog_line" == "$last_prog" ]] && continue
      last_prog="$prog_line"
      mm_info "$prog_line"
      written_h="$(mm_format_bytes "$written")"
      if [[ "$expected_bytes" =~ ^[0-9]+$ && "$expected_bytes" -gt 0 ]]; then
        expected_h="$(mm_format_bytes "$expected_bytes")"
        mm_info "PROGRESS PHASE2 BUNDLE: ${written_h} / approximately ${expected_h} (${pct}%) elapsed=${elapsed}s"
      else
        mm_info "PROGRESS PHASE2 BUNDLE: ${written_h} / approximately unknown (--) elapsed=${elapsed}s"
      fi
      mm_human_lines "$human_still" "Elapsed: ${elapsed} seconds" "The program is running normally."
    done
  ) &
  hb_pid=$!

  if wait "$cmd_pid"; then
    rc=0
  else
    rc=$?
  fi

  if [[ -n "$hb_pid" ]]; then
    kill "$hb_pid" 2>/dev/null || true
    wait "$hb_pid" 2>/dev/null || true
  fi
  trap - INT TERM

  elapsed=$(( $(date +%s) - start_ts ))
  if [[ "$rc" -eq 0 ]]; then
    written=0
    [[ -f "$out_file" ]] && written="$(stat -c%s "$out_file" 2>/dev/null || echo 0)"
    mm_ok "${event_prefix}_COMPLETE ${fields} actual_bytes=${written} elapsed=${elapsed}s result=PASS"
    rm -f "$err"
    return 0
  fi
  mm_redact <"$err" >&2 || true
  mm_error "${event_prefix}_FAIL ${fields} elapsed=${elapsed}s result=FAIL rc=${rc}"
  rm -f "$err"
  return "$rc"
}

# Write "HEX  basename" sidecar with heartbeat around the full-file read.
mm_sha256_write_sidecar_logged() {
  local file="$1"
  local sidecar="$2"
  local event_prefix="$3"
  local fields="$4"
  local human_still="$5"
  local base hex rc=0
  base="$(basename "$file")"
  mm_info "${event_prefix}_START ${fields}"
  mm_human_lines \
    "Calculating the SHA256 checksum of the newly created Phase 2 bundle." \
    "The bundle is large, so this step may take 5–10 minutes." \
    "The program is still running normally." \
    "Please wait and do not interrupt the process."
  mm_bg_with_heartbeat "$event_prefix" "$fields" \
    "Still calculating Phase 2 bundle SHA256..." -- sha256sum "$file" && rc=0 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    mm_error "${event_prefix}_FAIL ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=FAIL rc=${rc}"
    return "$rc"
  fi
  hex="$(printf '%s\n' "$MM_LONG_STEP_LAST_STDOUT" | awk '{print $1; exit}')"
  [[ -n "$hex" ]] || {
    mm_error "${event_prefix}_FAIL ${fields} reason=empty_hash"
    return 1
  }
  printf '%s  %s\n' "$hex" "$base" >"$sidecar" || {
    mm_error "${event_prefix}_FAIL ${fields} reason=sidecar_write"
    return 1
  }
  mm_ok "${event_prefix}_COMPLETE ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=PASS"
  return 0
}

# Verify data+sidecar SHA256 with labeled START/HEARTBEAT/COMPLETE.
# Optional 5th arg: extra fields (e.g. operation=enable-http).
mm_verify_sha256_pair_logged() {
  local data_file="$1"
  local checksum_file="$2"
  local event_prefix="$3"
  local human_still="${4:-Still verifying SHA256...}"
  local extra_fields="${5:-}"
  local expected actual bytes fields rc=0
  expected="$(dp2_read_hash_field "$checksum_file")"
  dp2_validate_sha256_hex "$expected" || {
    mm_error "${event_prefix}_FAIL file=$(basename "$data_file") reason=bad_hash_format"
    return 1
  }
  bytes="$(stat -c%s "$data_file" 2>/dev/null || echo 0)"
  fields="bundle=${data_file} file=$(basename "$data_file") algorithm=SHA256 bytes=${bytes}"
  # Prefer shorter fields when path is long — keep basename form for ACPS.
  if [[ "$event_prefix" == ACPS_CHECKSUM_VERIFY ]]; then
    fields="file=$(basename "$data_file") algorithm=SHA256 bytes=${bytes}"
  elif [[ "$event_prefix" == PHASE2_FINAL_SHA256_VERIFY ]]; then
    fields="bundle=${data_file} bytes=${bytes}"
  elif [[ "$event_prefix" == SHA256_VERIFICATION ]]; then
    fields="file=$(basename "$data_file") bytes=${bytes} algorithm=SHA256"
  fi
  if [[ -n "$extra_fields" ]]; then
    fields="${extra_fields} ${fields}"
  fi
  mm_info "${event_prefix}_START ${fields}"
  mm_bg_with_heartbeat "$event_prefix" "$fields" "$human_still" -- sha256sum "$data_file" && rc=0 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    mm_error "${event_prefix}_COMPLETE ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=FAIL rc=${rc}"
    return "$rc"
  fi
  actual="$(printf '%s\n' "$MM_LONG_STEP_LAST_STDOUT" | awk '{print $1; exit}')"
  if [[ "${expected,,}" != "${actual,,}" ]]; then
    mm_error "SHA256_VERIFY=FAIL file=$(basename "$data_file") expected=${expected} actual=${actual}"
    mm_error "${event_prefix}_COMPLETE ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=FAIL"
    return 1
  fi
  mm_ok "${event_prefix}_COMPLETE ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=PASS"
  if [[ -n "$extra_fields" ]]; then
    mm_ok "SHA256_VERIFY=PASS ${extra_fields} file=$(basename "$data_file")"
  else
    mm_ok "SHA256_VERIFY=PASS file=$(basename "$data_file")"
  fi
  return 0
}

# Verify SHA1 pair with explicit algorithm label (no SHA256 confusion).
mm_verify_sha1_pair_logged() {
  local data_file="$1"
  local checksum_file="$2"
  local event_prefix="${3:-ACPS_CHECKSUM_VERIFY}"
  local expected actual bytes fields start_ts elapsed
  expected="$(dp2_read_hash_field "$checksum_file")"
  dp2_validate_sha1_hex "$expected" || {
    mm_error "${event_prefix}_FAIL file=$(basename "$data_file") algorithm=SHA1 reason=bad_hash_format"
    return 1
  }
  bytes="$(stat -c%s "$data_file" 2>/dev/null || echo 0)"
  fields="file=$(basename "$data_file") algorithm=SHA1 bytes=${bytes}"
  start_ts="$(date +%s)"
  mm_info "${event_prefix}_START ${fields}"
  mm_human_lines "Verifying SHA1 checksum of $(basename "$data_file")."
  actual="$(sha1sum "$data_file" | awk '{print $1}')"
  elapsed=$(( $(date +%s) - start_ts ))
  if [[ "${expected,,}" != "${actual,,}" ]]; then
    mm_error "SHA1_VERIFY=FAIL file=$(basename "$data_file") expected=${expected} actual=${actual}"
    mm_error "${event_prefix}_FAIL ${fields} elapsed=${elapsed}s result=FAIL"
    return 1
  fi
  mm_ok "${event_prefix}_COMPLETE ${fields} elapsed=${elapsed}s result=PASS"
  mm_ok "SHA1_VERIFY=PASS file=$(basename "$data_file")"
  return 0
}

# ACPS payload checksums with correct SHA1/SHA256 labels and heartbeat on images tar.
mm_acps_verify_payload_checksums() {
  local files_dir="$1"
  local ver="${DP_PHASE2_VERSION}"
  local img bytes img_h
  mm_set_phase "Verifying ACPS Checksums"
  mm_verify_sha1_pair_logged \
    "${files_dir}/aelladeb_py3_common.tar.gz" \
    "${files_dir}/aelladeb_py3_common.tar.gz.sha1" \
    || return 1
  mm_verify_sha1_pair_logged \
    "${files_dir}/aella-uvp-2404_${ver}ubuntu1_amd64.deb" \
    "${files_dir}/aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1" \
    || return 1
  mm_verify_sha1_pair_logged \
    "${files_dir}/bringup_py3_dp_after_os_upgrade.sh" \
    "${files_dir}/bringup_py3_dp_after_os_upgrade.sh.sha1" \
    || return 1
  img="${files_dir}/images-${ver}.tar"
  bytes="$(stat -c%s "$img" 2>/dev/null || echo 0)"
  img_h="$(mm_format_bytes "$bytes")"
  mm_human_lines \
    "Verifying SHA256 checksum of images-${ver}.tar." \
    "This file is approximately ${img_h}." \
    "Verification may take 5–10 minutes depending on disk performance." \
    "The program is still running normally." \
    "Please wait and do not interrupt the process."
  mm_verify_sha256_pair_logged \
    "$img" \
    "${img}.sha256" \
    "ACPS_CHECKSUM_VERIFY" \
    "Still verifying images-${ver}.tar SHA256..." \
    || return 1
  return 0
}

mm_require_root() {
  if [[ "${MM_SKIP_ROOT_CHECK}" == "1" ]]; then
    return 0
  fi
  if [[ "${EUID}" -ne 0 ]]; then
    # Operator-facing guidance (official entry is always sudo).
    cat >&2 <<'EOF'
This command requires sudo.
Run: sudo ubuntu-offline-mirror mirror-manager
EOF
    mm_die "ROOT_REQUIRED=FAIL"
  fi
  mm_ok "ROOT_REQUIRED=PASS"
}

mm_require_cmds() {
  local c missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    mm_die "COMMANDS_MISSING=FAIL missing=${missing[*]}"
  fi
}

mm_validate_dp_version() {
  local ver="$1"
  [[ -n "$ver" ]] || mm_die "TARGET_DP_VERSION=FAIL empty"
  if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    mm_die "TARGET_DP_VERSION=FAIL invalid=${ver}"
  fi
}

mm_assert_regular_file() {
  local path="$1"
  local label="${2:-$path}"
  [[ -e "$path" ]] || mm_die "FILE_MISSING=FAIL file=${label}"
  if [[ -L "$path" ]]; then
    mm_die "SYMLINK_FORBIDDEN=FAIL file=${label}"
  fi
  [[ -f "$path" ]] || mm_die "NOT_REGULAR_FILE=FAIL file=${label}"
}

mm_load_gui_config() {
  PREPARATION_MODE="${PREPARATION_MODE:-FULL}"
  ACPS_USERNAME="${ACPS_USERNAME:-}"
  ACPS_PASSWORD="${ACPS_PASSWORD:-}"
  WORKER_SSH_PASSWORD="${WORKER_SSH_PASSWORD:-}"
  DL_WORKER_IPS="${DL_WORKER_IPS:-}"
  DA_WORKER_IPS="${DA_WORKER_IPS:-}"
  MIRROR_HTTP_URL="${MIRROR_HTTP_URL:-}"
  MIRROR_SERVER_IP="${MIRROR_SERVER_IP:-}"
  if [[ -f "${MM_CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "${MM_CONFIG_FILE}"
    set +a
  fi
  # Legacy version fields from older configs are ignored (never required).
  unset CURRENT_DP_VERSION SOURCE_DP_VERSION 2>/dev/null || true
  mm_normalize_preparation_mode
  mm_force_phase2_target
  ACPS_USERNAME="${ACPS_USERNAME:-${ACPS_USER:-}}"
  ACPS_PASSWORD="${ACPS_PASSWORD:-${ACPS_PASS:-}}"
  WORKER_SSH_PASSWORD="${WORKER_SSH_PASSWORD:-}"
  DL_WORKER_IPS="${DL_WORKER_IPS:-}"
  DA_WORKER_IPS="${DA_WORKER_IPS:-}"
  MIRROR_HTTP_URL="${MIRROR_HTTP_URL:-}"
  MIRROR_SERVER_IP="${MIRROR_SERVER_IP:-}"
  # Derive missing field from the other when only one is present.
  if [[ -z "${MIRROR_SERVER_IP}" && -n "${MIRROR_HTTP_URL}" ]]; then
    MIRROR_SERVER_IP="$(mirror_host_extract_ipv4_from_url "${MIRROR_HTTP_URL}" || true)"
  fi
  if [[ -n "${MIRROR_SERVER_IP}" && -z "${MIRROR_HTTP_URL}" ]]; then
    MIRROR_HTTP_URL="$(mirror_base_url_from_ipv4 "${MIRROR_SERVER_IP}" || true)"
  fi
  ACPS_BASE_URL="${ACPS_BASE_URL_FIXED}"
}

# Persist GUI config.
# Usage: mm_save_gui_config [full|merge]
#   full  (default) — every in-memory GUI field is authoritative, including
#         explicit empty (clears DL/DA workers, worker password, etc.).
#   merge — empty in-memory fields fall back to disk so partial/internal
#         updates (e.g. URL-only) cannot wipe unrelated credentials.
mm_save_gui_config() {
  local save_mode="${1:-full}"
  local prev_mode="" cmd_file
  local mem_user="${ACPS_USERNAME-}"
  local mem_pass="${ACPS_PASSWORD-}"
  local mem_worker_pass="${WORKER_SSH_PASSWORD-}"
  local mem_dl_worker_ips="${DL_WORKER_IPS-}"
  local mem_da_worker_ips="${DA_WORKER_IPS-}"
  local mem_mirror="${MIRROR_HTTP_URL-}"
  local mem_ip="${MIRROR_SERVER_IP-}"
  local mem_mode="${PREPARATION_MODE-}"
  local disk_user="" disk_pass="" disk_worker_pass="" disk_dl_worker_ips="" disk_da_worker_ips="" disk_mirror="" disk_ip=""
  local disk_mode=""

  case "$save_mode" in
    full|merge) ;;
    *)
      mm_error "CONFIGURATION_SAVE=FAIL reason=invalid_save_mode mode=${save_mode}"
      return 1
      ;;
  esac

  if [[ -f "${MM_CONFIG_FILE}" ]]; then
    prev_mode="$(awk -F= '/^PREPARATION_MODE=/{print substr($0,index($0,"=")+1); exit}' "${MM_CONFIG_FILE}" 2>/dev/null || true)"
    # Read disk values in a subshell so we do not clobber caller memory.
    # shellcheck disable=SC1090
    eval "$(
      set -a
      # shellcheck source=/dev/null
      source "${MM_CONFIG_FILE}"
      set +a
      printf 'disk_user=%s\n' "$(printf '%q' "${ACPS_USERNAME:-}")"
      printf 'disk_pass=%s\n' "$(printf '%q' "${ACPS_PASSWORD:-}")"
      printf 'disk_worker_pass=%s\n' "$(printf '%q' "${WORKER_SSH_PASSWORD:-}")"
      printf 'disk_dl_worker_ips=%s\n' "$(printf '%q' "${DL_WORKER_IPS:-}")"
      printf 'disk_da_worker_ips=%s\n' "$(printf '%q' "${DA_WORKER_IPS:-}")"
      printf 'disk_mirror=%s\n' "$(printf '%q' "${MIRROR_HTTP_URL:-}")"
      printf 'disk_ip=%s\n' "$(printf '%q' "${MIRROR_SERVER_IP:-}")"
      printf 'disk_mode=%s\n' "$(printf '%q' "${PREPARATION_MODE:-}")"
    )"
  fi

  if [[ "$save_mode" == "merge" ]]; then
    # Partial/internal persistence: preserve unrelated disk values when memory
    # left a field empty/unset.
    ACPS_USERNAME="${mem_user:-$disk_user}"
    ACPS_PASSWORD="${mem_pass:-$disk_pass}"
    WORKER_SSH_PASSWORD="${mem_worker_pass:-$disk_worker_pass}"
    DL_WORKER_IPS="${mem_dl_worker_ips:-$disk_dl_worker_ips}"
    DA_WORKER_IPS="${mem_da_worker_ips:-$disk_da_worker_ips}"
    MIRROR_HTTP_URL="${mem_mirror:-$disk_mirror}"
    MIRROR_SERVER_IP="${mem_ip:-$disk_ip}"
    PREPARATION_MODE="${mem_mode:-${disk_mode:-${prev_mode:-FULL}}}"
  else
    # Authoritative full GUI save: explicit empty clears the setting.
    ACPS_USERNAME="${mem_user}"
    ACPS_PASSWORD="${mem_pass}"
    WORKER_SSH_PASSWORD="${mem_worker_pass}"
    DL_WORKER_IPS="${mem_dl_worker_ips}"
    DA_WORKER_IPS="${mem_da_worker_ips}"
    MIRROR_HTTP_URL="${mem_mirror}"
    MIRROR_SERVER_IP="${mem_ip}"
    PREPARATION_MODE="${mem_mode:-${prev_mode:-FULL}}"
  fi

  # Keep MIRROR_SERVER_IP and MIRROR_HTTP_URL consistent.
  if [[ -n "${MIRROR_SERVER_IP}" ]]; then
    MIRROR_HTTP_URL="$(mirror_base_url_from_ipv4 "${MIRROR_SERVER_IP}" || true)"
  elif [[ -n "${MIRROR_HTTP_URL}" ]]; then
    MIRROR_SERVER_IP="$(mirror_host_extract_ipv4_from_url "${MIRROR_HTTP_URL}" || true)"
  fi

  mm_normalize_preparation_mode
  mm_force_phase2_target
  mkdir -p "$(dirname "$MM_CONFIG_FILE")"
  local tmp old_umask
  tmp="$(mktemp)"
  old_umask="$(umask)"
  umask 077
  # printf %q so passwords with spaces/$/\` survive a later `source`.
  {
    printf '%s\n' "# DP Upgrade Mirror Manager configuration (managed by GUI)"
    printf '%s\n' "# Do not store secrets in world-readable locations."
    printf '%s\n' "# Phase 2 target is fixed at ${PHASE2_TARGET_VERSION} (not user-editable)."
    printf 'PREPARATION_MODE=%s\n' "$(printf '%q' "${PREPARATION_MODE}")"
    printf 'ACPS_USERNAME=%s\n' "$(printf '%q' "${ACPS_USERNAME}")"
    printf 'ACPS_PASSWORD=%s\n' "$(printf '%q' "${ACPS_PASSWORD}")"
    printf 'WORKER_SSH_PASSWORD=%s\n' "$(printf '%q' "${WORKER_SSH_PASSWORD}")"
    printf 'DL_WORKER_IPS=%s\n' "$(printf '%q' "${DL_WORKER_IPS}")"
    printf 'DA_WORKER_IPS=%s\n' "$(printf '%q' "${DA_WORKER_IPS}")"
    printf 'MIRROR_SERVER_IP=%s\n' "$(printf '%q' "${MIRROR_SERVER_IP}")"
    printf 'MIRROR_HTTP_URL=%s\n' "$(printf '%q' "${MIRROR_HTTP_URL}")"
  } >"$tmp"
  umask "$old_umask"
  chmod 600 "$tmp"
  mv -f "$tmp" "$MM_CONFIG_FILE"
  chmod 600 "$MM_CONFIG_FILE"
  if [[ "${EUID}" -eq 0 ]]; then
    chown root:root "$MM_CONFIG_FILE" 2>/dev/null || true
  fi
  # Mode change invalidates previously generated client commands.
  if [[ -n "$prev_mode" && "$prev_mode" != "${PREPARATION_MODE}" ]]; then
    cmd_file="$(mm_client_commands_file)"
    if [[ -f "$cmd_file" ]]; then
      rm -f "$cmd_file" 2>/dev/null || true
      mm_info "CLIENT_COMMANDS_STALE=YES reason=preparation_mode_changed old=${prev_mode} new=${PREPARATION_MODE}"
    fi
    mm_status_set CLIENT_COMMANDS_MODE ""
  fi
  # Single authoritative invalidation decision for this persistence.
  if declare -F mm_wf_invalidate_after_config_change >/dev/null 2>&1; then
    mm_wf_invalidate_after_config_change
  elif declare -F mm_wf_mark_configured >/dev/null 2>&1; then
    mm_wf_mark_configured
  fi
  mm_ok "CONFIGURATION_SAVED=PASS path=${MM_CONFIG_FILE} mode=${PREPARATION_MODE} save=${save_mode}"
}

# Authoritative full GUI Save (explicit empty clears).
mm_save_gui_config_full() {
  mm_save_gui_config full
}

# Partial/internal merge save (empty memory does not wipe disk).
mm_merge_gui_config() {
  mm_save_gui_config merge
}

# Public HTTP base clients use (no trailing slash). Never logs credentials.
mm_client_mirror_url() {
  local url host
  mm_load_gui_config
  # Prefer operator-confirmed Mirror Server IP.
  if [[ -n "${MIRROR_SERVER_IP:-}" ]]; then
    if ! mirror_host_is_usable_ipv4 "${MIRROR_SERVER_IP}"; then
      mm_error "MIRROR_SERVER_IP=${MIRROR_SERVER_IP} is not a usable IPv4"
      return 1
    fi
    if ! mirror_host_validate_ipv4_on_host "${MIRROR_SERVER_IP}"; then
      mm_error "MIRROR_SERVER_IP=${MIRROR_SERVER_IP} is not configured on this host"
      return 1
    fi
    MIRROR_HTTP_URL="$(mirror_base_url_from_ipv4 "${MIRROR_SERVER_IP}")"
    printf '%s\n' "$MIRROR_HTTP_URL"
    return 0
  fi
  url="${MIRROR_HTTP_URL:-}"
  url="${url%/}"
  if [[ -n "$url" ]] && [[ "$url" =~ ^https?://[A-Za-z0-9._:-]+(/.*)?$ ]]; then
    host="$(mirror_host_extract_ipv4_from_url "$url" || true)"
    if [[ -z "$host" ]]; then
      # Operator-configured DNS name: nothing to validate against interfaces.
      printf '%s\n' "$url"
      return 0
    fi
    if mirror_host_validate_ipv4_on_host "$host"; then
      printf '%s\n' "$url"
      return 0
    fi
    mm_warn "MIRROR_HTTP_URL=${url} is not configured on this host; re-resolving"
  fi
  # Resolution record goes to stderr so callers can capture the URL on stdout.
  mirror_host_resolve_and_log >&2 || return 1
  [[ -n "${RESOLVED_MIRROR_BASE_URL:-}" ]] || return 1
  MIRROR_HTTP_URL="$RESOLVED_MIRROR_BASE_URL"
  MIRROR_SERVER_IP="${RESOLVED_MIRROR_HOST_IPV4:-}"
  printf '%s\n' "$RESOLVED_MIRROR_BASE_URL"
}

# Require operator-confirmed Mirror Server IP for prepare / enable-http.
# Auto-detection is not authoritative here.
mm_require_configured_mirror_server_ip() {
  local ip url
  mm_load_gui_config
  ip="${MIRROR_SERVER_IP:-}"
  if [[ -z "$ip" && -n "${MIRROR_HTTP_URL:-}" ]]; then
    ip="$(mirror_host_extract_ipv4_from_url "${MIRROR_HTTP_URL}" || true)"
  fi
  if [[ -z "$ip" ]]; then
    mm_error "MIRROR_IP_SOURCE=MISSING"
    mm_error "MIRROR_SERVER_IP_REQUIRED=YES"
    mm_info "Set Mirror Server IP in Configuration before Download and Prepare / Enable HTTP"
    return 1
  fi
  if ! mirror_host_is_usable_ipv4 "$ip"; then
    mm_error "MIRROR_SERVER_IP_INVALID=${ip}"
    return 1
  fi
  if ! mirror_host_validate_ipv4_on_host "$ip"; then
    mm_error "MIRROR_IP_INTERFACE_VALIDATION=FAIL ip=${ip}"
    mm_error "configured Mirror Server IP is not on an active non-excluded interface"
    return 1
  fi
  url="$(mirror_base_url_from_ipv4 "$ip")"
  MIRROR_SERVER_IP="$ip"
  MIRROR_HTTP_URL="$url"
  RESOLVED_MIRROR_HOST_IPV4="$ip"
  RESOLVED_MIRROR_BASE_URL="$url"
  MIRROR_IP_SOURCE=OPERATOR_CONFIRMED_CONFIG
  MIRROR_IP_RESOLUTION_SOURCE=OPERATOR_CONFIRMED_CONFIG
  mm_info "MIRROR_IP_SOURCE=OPERATOR_CONFIRMED_CONFIG"
  mm_info "CONFIGURED_MIRROR_SERVER_IP=${ip}"
  mm_info "CONFIGURED_MIRROR_BASE_URL=${url}"
  mm_ok "MIRROR_IP_INTERFACE_VALIDATION=PASS"
  return 0
}

mm_validate_source_dp_version() {
  local ver="$1"
  local cmp
  # Strict X.Y.Z only — reject empty, v-prefix, partial, metacharacters, newlines.
  [[ -n "$ver" ]] || return 1
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  # Policy floor matches stage-dp-phase2.sh MIN_SUPPORTED_SOURCE_DP_VERSION=6.2.0
  case "$ver" in
    6.2.0|6.3.0|6.4.0|6.5.0) return 0 ;;
  esac
  [[ "$ver" =~ ^6\.[0-9]+\.[0-9]+$ ]] || return 1
  # Reject below 6.2.0 via version sort.
  cmp="$(printf '%s\n' "6.2.0" "$ver" | sort -V | head -1)"
  [[ "$cmp" == "6.2.0" ]] || return 1
  return 0
}

# Comma-separated IPv4 list for --worker-ips. Rejects shell metacharacters,
# invalid octets, duplicates, and broadcast/unspecified addresses.
mm_validate_worker_ips() {
  local raw="$1"
  local cleaned item octet parts seen
  # Reject newlines / CR explicitly before stripping other whitespace.
  [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || return 1
  cleaned="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [[ -n "$cleaned" ]] || return 1
  # Trailing / leading comma or empty items.
  [[ "$cleaned" != *, && "$cleaned" != ,* && "$cleaned" != *,,* ]] || return 1
  # Allow only digits, dots, and commas.
  [[ "$cleaned" =~ ^[0-9.,]+$ ]] || return 1
  IFS=',' read -r -a _mm_ips <<<"$cleaned"
  [[ "${#_mm_ips[@]}" -ge 1 ]] || return 1
  seen="|"
  for item in "${_mm_ips[@]}"; do
    [[ -n "$item" ]] || return 1
    [[ "$item" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    parts=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}")
    for octet in "${parts[@]}"; do
      if (( 10#$octet > 255 )); then
        return 1
      fi
    done
    [[ "$item" != "0.0.0.0" && "$item" != "255.255.255.255" ]] || return 1
    if [[ "$seen" == *"|${item}|"* ]]; then
      return 1
    fi
    seen="${seen}${item}|"
  done
  printf '%s\n' "$cleaned"
}

# Operator-facing Upgrade Readiness label for status screens.
# Exactly one of: PASS | NOT VERIFIED | NOT READY | FAIL (never blank).
mm_upgrade_readiness_display() {
  local readiness_result
  # Suppress path-resolution INFO lines from nested completed-check helpers.
  if mm_readiness_completed >/dev/null 2>&1; then
    printf 'PASS\n'
    return 0
  fi
  if ! mm_configuration_completed >/dev/null 2>&1 \
    || ! mm_download_completed >/dev/null 2>&1 \
    || ! mm_http_completed >/dev/null 2>&1; then
    printf 'NOT READY\n'
    return 0
  fi
  readiness_result="$(mm_status_get READINESS_RESULT)"
  if [[ "$readiness_result" == "FAIL" ]]; then
    printf 'FAIL\n'
    return 0
  fi
  printf 'NOT VERIFIED\n'
}

mm_artifacts_ready_for_http() {
  local bundle_ck os_ready
  bundle_ck="$(mm_status_get PHASE2_BUNDLE_CHECKSUM)"
  [[ "$bundle_ck" == "PASS" ]] || return 1
  if mm_is_phase2_only; then
    mm_client_files_ready_phase2 "${MM_CLIENT_ROOT}" || return 1
    return 0
  fi
  os_ready="$(mm_status_get OS_MIRROR_READY)"
  [[ "$os_ready" == "PASS" ]] || return 1
  mm_client_files_ready "${MM_CLIENT_ROOT}" || return 1
  mm_client_set_current_source "${MM_CLIENT_ROOT}" >/dev/null 2>&1 || return 1
  return 0
}

mm_http_distribution_enabled() {
  local v
  v="$(mm_status_get HTTP_DISTRIBUTION)"
  [[ "$v" == "ENABLED" ]]
}

mm_client_commands_file() {
  printf '%s/dp-client-upgrade-commands.txt\n' "${MM_LOG_DIR:-/var/log/ubuntu-mirror-automation}"
}

mm_client_commands_stale() {
  local f mode_saved ready cmd_gen ver stored_cmd cur_cmd
  f="$(mm_client_commands_file)"
  [[ -f "$f" && -s "$f" ]] || return 0
  # Legacy / non-SUBSHELL_V2 command files are always stale.
  if ! grep -qE '^DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2$' "$f"; then
    return 0
  fi
  mm_normalize_preparation_mode
  if [[ "${PREPARATION_MODE}" == "FULL" ]]; then
    if ! grep -qE '^DP_OS_HOP_COMMAND_VERSION=WRAPPER_V1$' "$f"; then
      return 0
    fi
    # Legacy launcher or three-line OS-hop bootstrap blocks are stale.
    if grep -qE "^\( .*HOP=" "$f"; then
      return 0
    fi
    if grep -qE '^cd /home/aella && curl -fsSLo dp-launch-' "$f"; then
      return 0
    fi
    if ! grep -qE '^cd /home/aella && curl -fsSLo upgrade-' "$f"; then
      return 0
    fi
  fi
  # Phase 2 operator command must be the upgrade-phase2.sh wrapper one-liner.
  if grep -qE 'BASH_SUBSHELL|DP_COMMAND_SUBSHELL_REQUIRED=YES' "$f"; then
    return 0
  fi
  if ! grep -qE '^cd /home/aella && curl -fsSLo upgrade-phase2\.sh\.download ' "$f"; then
    return 0
  fi
  mode_saved="$(mm_status_get CLIENT_COMMANDS_MODE)"
  [[ "$mode_saved" == "${PREPARATION_MODE}" ]] || return 0
  if declare -F mm_wf_get >/dev/null 2>&1; then
    ready="$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)"
    cmd_gen="$(mm_wf_get COMMAND_FILE_GENERATION_ID)"
    ver="$(mm_wf_get DP_COMMAND_BLOCK_VERSION)"
    [[ -n "$ready" && -n "$cmd_gen" && "$ready" == "$cmd_gen" ]] || return 0
    [[ "$ver" == "SUBSHELL_V2" ]] || return 0
    # Readiness-relevant identity must still match.
    if declare -F mm_wf_readiness_identity_matches >/dev/null 2>&1; then
      mm_wf_readiness_identity_matches || return 0
    else
      mm_wf_config_matches_current || return 0
    fi
    # Worker-routing / command identity changes stale Menu 7 without
    # requiring Download and Prepare.
    if declare -F mm_wf_command_identity_sha256 >/dev/null 2>&1; then
      stored_cmd="$(mm_wf_get CONFIG_COMMAND_SHA256)"
      cur_cmd="$(mm_wf_command_identity_sha256 || true)"
      [[ -n "$stored_cmd" && -n "$cur_cmd" && "$stored_cmd" == "$cur_cmd" ]] || return 0
    fi
  fi
  return 1
}

mm_mark_client_commands_fresh() {
  local ready
  mm_normalize_preparation_mode
  mm_status_set CLIENT_COMMANDS_MODE "${PREPARATION_MODE}"
  mm_status_set CLIENT_COMMANDS_GENERATED_AT "$(mm_ts)"
  if declare -F mm_wf_get >/dev/null 2>&1; then
    ready="$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)"
    if [[ -n "$ready" ]] && declare -F mm_wf_mark_commands_generated >/dev/null 2>&1; then
      mm_wf_mark_commands_generated "$ready"
    fi
  fi
}

# Base operator configuration (mode + pinned target). Does NOT require ACPS
# credentials — those are acquisition-auth inputs only.
mm_config_base_ready() {
  mm_load_gui_config
  mm_normalize_preparation_mode
  case "${PREPARATION_MODE}" in
    FULL|PHASE2_ONLY) ;;
    *) return 1 ;;
  esac
  mm_force_phase2_target
  [[ "${TARGET_DP_VERSION}" == "${PHASE2_TARGET_VERSION}" ]] || return 1
  return 0
}

# ACPS credentials required only when a new ACPS acquisition needs them.
mm_acquisition_auth_ready() {
  mm_load_gui_config
  [[ -n "${ACPS_USERNAME:-}" ]] || return 1
  [[ -n "${ACPS_PASSWORD:-}" ]] || return 1
  return 0
}

# Historical name: base config ready. Prefer mm_config_base_ready /
# mm_acquisition_auth_ready for new call sites that need the distinction.
mm_config_ready() {
  mm_config_base_ready
}

mm_r2_url_configured() {
  [[ -n "${OS_CORE_R2_URL:-}" ]]
}

mm_status_set() {
  local key="$1"
  local val="$2"
  local f="${MM_STATUS_FILE}"
  local tmp dir old_umask
  dir="$(dirname "$f")"
  mkdir -p "$dir"
  if [[ ! -f "$f" ]]; then
    old_umask="$(umask)"
    umask 077
    : >"$f"
    umask "$old_umask"
    chmod 600 "$f" 2>/dev/null || true
  fi
  tmp="$(mktemp "${dir}/.status.XXXXXX")"
  old_umask="$(umask)"
  umask 077
  if [[ -f "$f" ]] && grep -q "^${key}=" "$f" 2>/dev/null; then
    awk -F= -v k="$key" -v v="$val" 'BEGIN{done=0} $1==k && !done {print k"="v; done=1; next} {print} END{if(!done) print k"="v}' "$f" >"$tmp"
  elif [[ -f "$f" ]]; then
    cat "$f" >"$tmp"
    printf '%s=%s\n' "$key" "$val" >>"$tmp"
  else
    printf '%s=%s\n' "$key" "$val" >"$tmp"
  fi
  umask "$old_umask"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$f"
  chmod 600 "$f" 2>/dev/null || true
}

mm_status_get() {
  local key="$1"
  local f="${MM_STATUS_FILE}"
  [[ -f "$f" ]] || { printf ''; return 0; }
  awk -F= -v k="$key" '$1==k { print substr($0, length($1) + 2); exit }' "$f"
}

# Cheap file identity for menu completion (no full-file hash).
# Format: path|dev:inode:size:mtime_ns_or_sec
# NOTE: For DIRECTORIES this only reflects directory metadata, not child
# content. Do not use directory fingerprints for OS readiness identity.
mm_file_fingerprint() {
  local path="$1"
  local st
  [[ -e "$path" ]] || { printf ''; return 1; }
  # Bind device:inode:size:mtime_ns for verified-metadata reuse.
  st="$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print("%d:%d:%d:%d" % (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns))' "$path" 2>/dev/null || true)"
  if [[ -z "$st" ]]; then
    st="$(stat -c '%d:%i:%s:%y' "$path" 2>/dev/null || true)"
  fi
  [[ -n "$st" ]] || { printf ''; return 1; }
  printf '%s|%s\n' "$path" "$st"
}

# Semantic configuration identity for readiness/staleness (NOT inode/mtime).
# Physical mm_file_fingerprint remains available for artifact identity checks.
mm_config_fingerprint() {
  if declare -F mm_wf_readiness_identity_sha256 >/dev/null 2>&1; then
    mm_wf_readiness_identity_sha256 2>/dev/null || printf ''
  elif declare -F mm_wf_config_sha256 >/dev/null 2>&1; then
    # Legacy fallback: content digest, still not inode/mtime.
    mm_wf_config_sha256 2>/dev/null || printf ''
  else
    printf ''
  fi
}

# Physical config file identity (inode/mtime). Do not use for semantic
# readiness decisions — atomic rewrite of identical content must not stale.
mm_config_file_fingerprint() {
  local path="${MM_CONFIG_FILE}"
  mm_file_fingerprint "$path" 2>/dev/null || printf ''
}

mm_phase2_paths() {
  mm_force_phase2_target
  local ver="${TARGET_DP_VERSION}"
  local dp="${MM_DP_PHASE2_ROOT}/${ver}"
  local stable
  if command -v dp2_stable_bundle_name >/dev/null 2>&1; then
    stable="$(dp2_stable_bundle_name 2>/dev/null || printf 'dp_bundle_%s-current.tar' "$ver")"
  else
    stable="dp_bundle_${ver}-current.tar"
  fi
  MM_WF_PHASE2_DIR="$dp"
  MM_WF_PHASE2_BUNDLE="${dp}/${stable}"
  MM_WF_PHASE2_SIDECAR="${dp}/${stable}.sha256"
  MM_WF_PHASE2_RELEASE="${dp}/release.env"
  MM_WF_PHASE2_STABLE="$stable"
}

# Lightweight selective OS identity bound to READY provenance + index witnesses.
# Does NOT hash the multi-GB pool. Directory inode/mtime alone is insufficient:
# mutating an existing Packages/InRelease (or READY provenance) changes this.
mm_selective_os_identity() {
  local ready="${MM_SELECTIVE_ROOT}/state/READY"
  local plan="" disc="" payload="" manifest="" release_id="" indexes="" ubuntu
  [[ -f "$ready" ]] || { printf ''; return 1; }
  plan="$(awk -F= '$1=="selective_plan_checksum"{print substr($0,index($0,"=")+1);exit}' "$ready")"
  [[ -n "$plan" ]] || plan="$(awk -F= '$1=="plan_checksum"{print substr($0,index($0,"=")+1);exit}' "$ready")"
  disc="$(awk -F= '$1=="discovery_artifact_checksum"{print substr($0,index($0,"=")+1);exit}' "$ready")"
  payload="$(awk -F= '$1=="os_core_payload_manifest_sha256"{print substr($0,index($0,"=")+1);exit}' "$ready")"
  manifest="$(awk -F= '$1=="os_core_manifest_sha256"{print substr($0,index($0,"=")+1);exit}' "$ready")"
  release_id="$(awk -F= '$1=="os_core_release_id"{print substr($0,index($0,"=")+1);exit}' "$ready")"
  [[ -n "$plan" && -n "$disc" ]] || { printf ''; return 1; }
  ubuntu="${MM_SELECTIVE_ROOT}/ubuntu"
  if [[ -e "$ubuntu" ]]; then
    indexes="$(
      find -L "$ubuntu" \( -path '*/dists/*/InRelease' -o -path '*/dists/*/Packages' \
        -o -path '*/dists/*/Packages.gz' \) -type f 2>/dev/null \
        | LC_ALL=C sort \
        | while IFS= read -r f; do
            mm_file_fingerprint "$f" 2>/dev/null || true
          done \
        | sha256sum | awk '{print $1}'
    )"
  fi
  printf 'plan=%s;disc=%s;payload=%s;manifest=%s;release=%s;indexes=%s\n' \
    "$plan" "$disc" "${payload:-}" "${manifest:-}" "${release_id:-}" "${indexes:-}"
}

mm_artifact_fingerprint() {
  # Phase 2 identity always; OS-mirror identity only for FULL mode.
  # OS identity is generation/provenance-bound (READY + index witnesses),
  # never the ubuntu/ directory inode alone.
  local os_fp bundle_fp side_fp rel_fp
  mm_phase2_paths
  os_fp=""
  if ! mm_is_phase2_only; then
    os_fp="$(mm_selective_os_identity 2>/dev/null || true)"
  fi
  bundle_fp="$(mm_file_fingerprint "${MM_WF_PHASE2_BUNDLE}" 2>/dev/null || true)"
  side_fp="$(mm_file_fingerprint "${MM_WF_PHASE2_SIDECAR}" 2>/dev/null || true)"
  rel_fp="$(mm_file_fingerprint "${MM_WF_PHASE2_RELEASE}" 2>/dev/null || true)"
  printf 'mode=%s;os=%s;bundle=%s;sidecar=%s;release=%s\n' \
    "${PREPARATION_MODE:-FULL}" "${os_fp}" "${bundle_fp}" "${side_fp}" "${rel_fp}"
}

mm_temps_present() {
  # Incomplete publish leftovers invalidate Download completion.
  if [[ -d "${MM_DP_PHASE2_ROOT}" ]] \
    && find "${MM_DP_PHASE2_ROOT}" -maxdepth 1 \( -name '*.new.*' -o -name '*.old.*' \) \
      -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi
  if [[ -d "${MM_CACHE_ROOT}" ]] \
    && find "${MM_CACHE_ROOT}" \( -name '*.part' -o -name '*.download' -o -name '*.new.*' \) \
      -type f -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi
  return 1
}

mm_configuration_completed() {
  local mode
  [[ -f "${MM_CONFIG_FILE}" ]] || return 1
  mode="$(stat -c '%a' "${MM_CONFIG_FILE}" 2>/dev/null || true)"
  [[ "$mode" == "600" ]] || return 1
  [[ -r "${MM_CONFIG_FILE}" ]] || return 1
  mm_load_gui_config
  mm_config_ready || return 1
  # FULL mode requires the R2 URL constant; PHASE2_ONLY does not use R2.
  if ! mm_is_phase2_only; then
    mm_r2_url_configured || return 1
  fi
  if [[ -n "${MIRROR_HTTP_URL:-}" ]]; then
    [[ "${MIRROR_HTTP_URL}" =~ ^https?://[A-Za-z0-9._:-]+(/.*)?$ ]] || return 1
  fi
  [[ "$(mm_status_get CONFIGURATION_READY)" == "PASS" ]] || return 1
  return 0
}

mm_download_completed() {
  local stored_fp current_fp entries bundle_ck os_ready
  mm_configuration_completed || return 1
  engine_resolve_paths 2>/dev/null || true
  mm_phase2_paths
  [[ -f "${MM_WF_PHASE2_RELEASE}" ]] || return 1
  [[ -f "${MM_WF_PHASE2_BUNDLE}" ]] || return 1
  [[ -f "${MM_WF_PHASE2_SIDECAR}" ]] || return 1
  bundle_ck="$(mm_status_get PHASE2_BUNDLE_CHECKSUM)"
  entries="$(mm_status_get PHASE2_BUNDLE_ENTRY_COUNT)"
  # PASS and REUSED are both successful validations (entrypoint uom_status_success).
  case "$bundle_ck" in
    PASS|REUSED) ;;
    *) return 1 ;;
  esac
  [[ "$entries" == "9" ]] || return 1
  if mm_is_phase2_only; then
    mm_client_files_ready_phase2 "${MM_CLIENT_ROOT}" || return 1
  else
    [[ -d "${MM_SELECTIVE_ROOT}/ubuntu" || -L "${MM_SELECTIVE_ROOT}/ubuntu" ]] || return 1
    os_ready="$(mm_status_get OS_MIRROR_READY)"
    case "$os_ready" in
      PASS|REUSED) ;;
      *) return 1 ;;
    esac
    case "$(mm_status_get R2_OS_CORE_CHECKSUM)" in
      PASS|REUSED) ;;
      *) return 1 ;;
    esac
    mm_client_files_ready "${MM_CLIENT_ROOT}" || return 1
    mm_client_set_current_source "${MM_CLIENT_ROOT}" >/dev/null 2>&1 || return 1
  fi
  case "$(mm_status_get DOWNLOAD_PREPARE_RESULT)" in
    PASS|REUSED) ;;
    *)
      case "$(mm_status_get LAST_EXECUTION_RESULT)" in
        PASS|REUSED) ;;
        *)
          case "$(mm_status_get INSTALL_RESULT)" in
            PASS|REUSED) ;;
            *) return 1 ;;
          esac
          ;;
      esac
      ;;
  esac
  if mm_temps_present; then
    return 1
  fi
  current_fp="$(mm_artifact_fingerprint)"
  stored_fp="$(mm_status_get DOWNLOAD_ARTIFACT_FINGERPRINT)"
  if [[ -z "$stored_fp" ]]; then
    # Pure read: missing verified fingerprint is NOT VERIFIED. Do not mint
    # identity during status/menu rendering.
    return 1
  fi
  [[ "$stored_fp" == "$current_fp" ]] || return 1
  return 0
}

mm_http_probe_ok() {
  # Fast localhost probes for menu rendering (200-only reachability).
  local url="$1"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout "${MM_MENU_HTTP_CONNECT_TIMEOUT:-2}" \
    --max-time "${MM_MENU_HTTP_MAX_TIME:-3}" \
    "$url" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]]
}

# Fetch a small text URL body (empty on failure). Used for publication identity.
mm_http_fetch_text() {
  local url="$1"
  curl -sS --connect-timeout "${MM_MENU_HTTP_CONNECT_TIMEOUT:-2}" \
    --max-time "${MM_MENU_HTTP_MAX_TIME:-3}" \
    "$url" 2>/dev/null || true
}

# Bind HTTP readiness to the published client-set generation, not HTTP 200 alone.
mm_http_publication_identity_ok() {
  local base="${MM_VERIFY_HTTP_BASE:-http://127.0.0.1}"
  local expected="" live_body="" live_gen="" live_sha="" local_sha=""
  expected="$(mm_status_get HTTP_PUBLICATION_GENERATION_ID 2>/dev/null || true)"
  [[ -z "$expected" ]] && expected="$(mm_wf_get HTTP_PUBLICATION_GENERATION_ID 2>/dev/null || true)"
  [[ -z "$expected" ]] && expected="$(mm_wf_get CLIENT_SET_GENERATION_ID 2>/dev/null || true)"
  [[ -z "$expected" ]] && expected="$(mm_status_get CLIENT_SET_GENERATION_ID 2>/dev/null || true)"
  [[ -n "$expected" ]] || return 1
  live_body="$(mm_http_fetch_text "${base}/client/client-set.env")"
  [[ -n "$live_body" ]] || return 1
  live_gen="$(printf '%s\n' "$live_body" | awk -F= '
    $1=="CLIENT_SET_GENERATION_ID" { c++; if (c==1) v=substr($0,index($0,"=")+1) }
    END { if (c!=1) exit 2; print v }
  ')" || return 1
  [[ -n "$live_gen" && "$live_gen" == "$expected" ]] || return 1
  # Lightweight wrapper binding: HTTP sha256 sidecar must match local published file.
  if [[ -f "${MM_CLIENT_ROOT}/upgrade-phase2.sh.sha256" ]]; then
    local_sha="$(awk '{print $1; exit}' "${MM_CLIENT_ROOT}/upgrade-phase2.sh.sha256")"
    live_sha="$(mm_http_fetch_text "${base}/client/upgrade-phase2.sh.sha256" | awk '{print $1; exit}')"
    [[ -n "$local_sha" && -n "$live_sha" && "$local_sha" == "$live_sha" ]] || return 1
  fi
  return 0
}

mm_http_required_urls_ok() {
  local ver="${TARGET_DP_VERSION:-${PHASE2_TARGET_VERSION}}"
  local base="${MM_VERIFY_HTTP_BASE:-http://127.0.0.1}"
  local stable
  mm_phase2_paths
  stable="${MM_WF_PHASE2_STABLE}"
  mm_http_probe_ok "${base}/dp-phase2/${ver}/release.env" || return 1
  mm_http_probe_ok "${base}/dp-phase2/${ver}/${stable}.sha256" || return 1
  mm_http_probe_ok "${base}/client/stage-dp-phase2.sh" || return 1
  mm_http_probe_ok "${base}/client/stage-dp-phase2.sh.sha256" || return 1
  mm_http_probe_ok "${base}/client/upgrade-phase2.sh" || return 1
  mm_http_probe_ok "${base}/client/client-set.env" || return 1
  if ! mm_is_phase2_only; then
    mm_http_probe_ok "${base}/client/dp-offline-upgrade-xenial-to-bionic.sh" || return 1
    mm_http_probe_ok "${base}/client/dp-launch-xenial-to-bionic.sh" || return 1
    mm_http_probe_ok "${base}/client/dp-launch-bionic-to-focal.sh" || return 1
    mm_http_probe_ok "${base}/client/dp-launch-focal-to-jammy.sh" || return 1
    mm_http_probe_ok "${base}/client/dp-launch-jammy-to-noble.sh" || return 1
    mm_http_probe_ok "${base}/client/upgrade-xenial-to-bionic.sh" || return 1
    mm_http_probe_ok "${base}/client/upgrade-bionic-to-focal.sh" || return 1
    mm_http_probe_ok "${base}/client/upgrade-focal-to-jammy.sh" || return 1
    mm_http_probe_ok "${base}/client/upgrade-jammy-to-noble.sh" || return 1
    mm_http_probe_ok "${base}/offline/meta-release-lts" || return 1
  fi
  mm_http_publication_identity_ok || return 1
  return 0
}

mm_nginx_distribution_live() {
  local nginx_bin systemctl_bin site_en
  nginx_bin="${MM_NGINX_BIN:-nginx}"
  systemctl_bin="${MM_SYSTEMCTL_BIN:-systemctl}"
  site_en="${MM_NGINX_SITE_ENABLED:-/etc/nginx/sites-enabled/${MM_NGINX_SITE_NAME:-apt-mirror}}"
  command -v "$systemctl_bin" >/dev/null 2>&1 || return 1
  "$systemctl_bin" is-active --quiet nginx 2>/dev/null || return 1
  command -v "$nginx_bin" >/dev/null 2>&1 || return 1
  "$nginx_bin" -t >/dev/null 2>&1 || return 1
  [[ -e "$site_en" ]] || return 1
  return 0
}

mm_http_completed() {
  mm_download_completed || return 1
  [[ "$(mm_status_get HTTP_DISTRIBUTION)" == "ENABLED" ]] || return 1
  [[ "$(mm_status_get HTTP_CONFIGURATION_READY)" == "PASS" ]] || return 1
  mm_nginx_distribution_live || return 1
  mm_http_required_urls_ok || return 1
  return 0
}

mm_readiness_completed() {
  local stored_art cur_art stored_cfg cur_cfg
  mm_configuration_completed || return 1
  mm_download_completed || return 1
  mm_http_completed || return 1
  [[ "$(mm_status_get UPGRADE_READINESS)" == "PASS" ]] || return 1
  [[ "$(mm_status_get READINESS_RESULT)" == "PASS" \
    || "$(mm_status_get UPGRADE_READINESS)" == "PASS" ]] || return 1
  cur_art="$(mm_artifact_fingerprint)"
  stored_art="$(mm_status_get READINESS_ARTIFACT_FINGERPRINT)"
  if [[ -z "$stored_art" ]]; then
    # Pure read: readiness without stored artifact identity is NOT VERIFIED.
    return 1
  fi
  [[ "$stored_art" == "$cur_art" ]] || return 1
  cur_cfg="$(mm_config_fingerprint)"
  stored_cfg="$(mm_status_get READINESS_CONFIG_FINGERPRINT)"
  if [[ -n "$stored_cfg" && "$stored_cfg" != "$cur_cfg" ]]; then
    return 1
  fi
  return 0
}

# Populate MM_WF_* for menu + status screens (cheap; no full SHA256).
mm_collect_workflow_status() {
  MM_WF_CONFIG_COMPLETED=0
  MM_WF_DOWNLOAD_COMPLETED=0
  MM_WF_HTTP_COMPLETED=0
  MM_WF_READINESS_COMPLETED=0
  MM_WF_PROGRESS_COUNT=0
  mm_load_gui_config
  engine_resolve_paths 2>/dev/null || true
  if mm_configuration_completed; then
    MM_WF_CONFIG_COMPLETED=1
    MM_WF_PROGRESS_COUNT=$((MM_WF_PROGRESS_COUNT + 1))
  fi
  if mm_download_completed; then
    MM_WF_DOWNLOAD_COMPLETED=1
    MM_WF_PROGRESS_COUNT=$((MM_WF_PROGRESS_COUNT + 1))
  fi
  if mm_http_completed; then
    MM_WF_HTTP_COMPLETED=1
    MM_WF_PROGRESS_COUNT=$((MM_WF_PROGRESS_COUNT + 1))
  fi
  if mm_readiness_completed; then
    MM_WF_READINESS_COMPLETED=1
    MM_WF_PROGRESS_COUNT=$((MM_WF_PROGRESS_COUNT + 1))
  fi
}

mm_menu_label() {
  local base="$1"
  local completed="${2:-0}"
  if [[ "$completed" == "1" ]]; then
    printf '%s [COMPLETED]\n' "$base"
  else
    printf '%s\n' "$base"
  fi
}

mm_workflow_progress_text() {
  printf 'Progress: %s of 4 workflow steps completed\n' "${MM_WF_PROGRESS_COUNT:-0}"
}

mm_record_config_validated() {
  # Marks configuration as operator-validated. Does NOT independently reset
  # the workflow — mm_save_gui_config already performed the single scoped
  # invalidation decision. Calling mm_wf_mark_configured here would defeat
  # no-op / worker-only preservation.
  mm_status_set CONFIGURATION_READY PASS
  mm_status_set CONFIG_FINGERPRINT "$(mm_config_fingerprint)"
  mm_status_set CONFIG_VALIDATED_AT "$(mm_ts)"
  if declare -F mm_status_set >/dev/null 2>&1 && declare -F mm_wf_get >/dev/null 2>&1; then
    local change_class next_action
    change_class="$(mm_wf_get CONFIG_CHANGE_CLASS 2>/dev/null || true)"
    next_action="$(mm_wf_get NEXT_REQUIRED_ACTION 2>/dev/null || true)"
    [[ -n "$change_class" ]] && mm_status_set CONFIG_CHANGE_CLASS "$change_class"
    [[ -n "$next_action" ]] && mm_status_set NEXT_REQUIRED_ACTION "$next_action"
  fi
  # First-time / missing workflow: ensure CONFIGURED exists without demoting
  # an already-advanced workflow.
  if declare -F mm_wf_state >/dev/null 2>&1 && declare -F mm_wf_mark_configured >/dev/null 2>&1; then
    local st
    st="$(mm_wf_state 2>/dev/null || true)"
    case "$st" in
      ""|UNCONFIGURED)
        mm_wf_mark_configured
        ;;
    esac
  fi
}

mm_record_artifacts_prepared() {
  local os_gen="" p2_gen="" ready sidecar release
  engine_resolve_paths 2>/dev/null || true
  mm_phase2_paths
  if ! mm_is_phase2_only; then
    ready="${MM_SELECTIVE_ROOT}/state/READY"
    [[ -f "$ready" ]] || return 1
    os_gen="oscore:$(sha256sum "$ready" | awk '{print $1}')"
  else
    os_gen="phase2-only"
  fi
  sidecar="${MM_WF_PHASE2_SIDECAR}"
  release="${MM_WF_PHASE2_RELEASE}"
  [[ -f "$sidecar" && -f "$release" ]] || return 1
  p2_gen="phase2:$(cat "$sidecar" "$release" | sha256sum | awk '{print $1}')"
  if declare -F mm_wf_mark_prepared >/dev/null 2>&1; then
    mm_wf_mark_prepared "$os_gen" "$p2_gen"
  fi
  mm_info "HEAVY_ARTIFACTS_PREPARED=PASS OS_CORE_GENERATION_ID=${os_gen} PHASE2_GENERATION_ID=${p2_gen}"
}

mm_record_download_validated() {
  local fp
  engine_resolve_paths 2>/dev/null || true
  mm_phase2_paths
  fp="$(mm_artifact_fingerprint)"
  mm_status_set DOWNLOAD_PREPARE_RESULT PASS
  mm_status_set DOWNLOAD_VALIDATED_AT "$(mm_ts)"
  mm_status_set DOWNLOAD_ARTIFACT_FINGERPRINT "$fp"
  mm_status_set PHASE2_BUNDLE_SIZE "$(mm_file_bytes "${MM_WF_PHASE2_BUNDLE}")"
  mm_status_set PHASE2_BUNDLE_MTIME "$(stat -c '%Y' "${MM_WF_PHASE2_BUNDLE}" 2>/dev/null || echo 0)"
  mm_status_set PHASE2_SIDECAR_MTIME "$(stat -c '%Y' "${MM_WF_PHASE2_SIDECAR}" 2>/dev/null || echo 0)"
  # Changing artifacts invalidates readiness until Menu 4 re-runs.
  mm_status_set READINESS_RESULT ""
  mm_status_set READINESS_ARTIFACT_FINGERPRINT ""
  mm_status_set UPGRADE_READINESS FAIL
  # Workflow PREPARED is recorded before client finalization. Do not
  # demote a freshly published/reused current client set back to PREPARED here.
}

mm_record_http_validated() {
  mm_status_set HTTP_ENABLE_RESULT PASS
  mm_status_set HTTP_VALIDATED_AT "$(mm_ts)"
  mm_status_set HTTP_DISTRIBUTION ENABLED
  mm_status_set HTTP_CONFIGURATION_READY PASS
  if declare -F mm_wf_mark_http_enabled >/dev/null 2>&1; then
    mm_wf_mark_http_enabled
  fi
}

mm_record_readiness_validated() {
  local fp
  fp="$(mm_artifact_fingerprint)"
  mm_status_set READINESS_RESULT PASS
  mm_status_set READINESS_VALIDATED_AT "$(mm_ts)"
  mm_status_set READINESS_ARTIFACT_FINGERPRINT "$fp"
  mm_status_set READINESS_CONFIG_FINGERPRINT "$(mm_config_fingerprint)"
  mm_status_set UPGRADE_READINESS PASS
  if declare -F mm_wf_mark_readiness_verified >/dev/null 2>&1; then
    mm_wf_mark_readiness_verified
  fi
}

mm_state_init() {
  MM_RUN_ID="${MM_RUN_ID:-$(mm_run_id)}"
  MM_STATE_DIR="${MM_STATE_ROOT}/${MM_RUN_ID}"
  MM_LOG_FILE="${MM_LOG_DIR}/mirror-manager-${MM_RUN_ID}.log"
  mkdir -p "$MM_STATE_DIR" "$(dirname "$MM_LOG_FILE")"
  {
    printf 'INSTALLATION_MODE_COUNT=1\n'
    printf 'OS_CORE_SOURCE=R2\n'
    printf 'DP_PHASE2_SOURCE=ACPS\n'
    printf 'CLIENT_DOWNLOAD_SOURCE=MIRROR_SERVER_ONLY\n'
    printf 'PROJECT_ROLLBACK_SUPPORTED=NO\n'
    printf 'RUN_ID=%s\n' "$MM_RUN_ID"
    printf 'STARTED_AT=%s\n' "$(mm_ts)"
  } >"${MM_STATE_DIR}/state.env"
  cp -f "${MM_STATE_DIR}/state.env" "${MM_STATE_DIR}/report.env"
}

mm_state_set() {
  local key="$1"
  local val="$2"
  mm_status_set "$key" "$val"
  local f="${MM_STATE_DIR:-}/state.env"
  [[ -n "${MM_STATE_DIR:-}" ]] || return 0
  mkdir -p "$MM_STATE_DIR"
  if [[ -f "$f" ]] && grep -q "^${key}=" "$f" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    awk -F= -v k="$key" -v v="$val" 'BEGIN{done=0} $1==k && !done {print k"="v; done=1; next} {print} END{if(!done) print k"="v}' "$f" >"$tmp"
    mv -f "$tmp" "$f"
  else
    printf '%s=%s\n' "$key" "$val" >>"$f"
  fi
  cp -f "$f" "${MM_STATE_DIR}/report.env" 2>/dev/null || true
}

mm_acquire_install_lock() {
  local new_fd
  mkdir -p "$(dirname "$MM_LOCK_FILE")"
  exec {new_fd}>"$MM_LOCK_FILE"
  if ! flock -n "$new_fd"; then
    eval "exec ${new_fd}>&-" 2>/dev/null || true
    mm_die "INSTALL_LOCK=BUSY path=${MM_LOCK_FILE}"
  fi
  MM_LOCK_FD="$new_fd"
  MM_LOCK_HELD=1
  printf 'pid=%s\nstarted_at=%s\n' "$$" "$(mm_ts)" >"${MM_LOCK_FILE}.meta"
  mm_ok "INSTALL_LOCK=PASS"
}

mm_release_install_lock() {
  if [[ "${MM_LOCK_HELD:-0}" == "1" && -n "${MM_LOCK_FD:-}" ]]; then
    flock -u "$MM_LOCK_FD" 2>/dev/null || true
    eval "exec ${MM_LOCK_FD}>&-" 2>/dev/null || true
    MM_LOCK_FD=""
    MM_LOCK_HELD=0
  fi
  rm -f "${MM_LOCK_FILE}.meta" 2>/dev/null || true
}

mm_free_bytes() {
  local path="$1"
  if [[ -n "${MM_MOCK_AVAILABLE_BYTES:-}" ]]; then
    printf '%s\n' "$MM_MOCK_AVAILABLE_BYTES"
    return 0
  fi
  mkdir -p "$path" 2>/dev/null || true
  local kib
  kib="$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ "$kib" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$((kib * 1024))"
    return 0
  fi
  df -PB1 "$path" 2>/dev/null | awk 'NR==2 {print $4}'
}

mm_file_bytes() {
  local f="$1"
  if [[ -f "$f" ]]; then
    stat -c%s "$f"
  else
    printf '0'
  fi
}

mm_fs_size_bytes() {
  local path="$1"
  if [[ -n "${MM_MOCK_FS_SIZE_BYTES:-}" ]]; then
    printf '%s\n' "$MM_MOCK_FS_SIZE_BYTES"
    return 0
  fi
  mkdir -p "$path" 2>/dev/null || true
  local kib
  kib="$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $2}')"
  if [[ "$kib" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$((kib * 1024))"
    return 0
  fi
  df -PB1 "$path" 2>/dev/null | awk 'NR==2 {print $2}'
}

mm_calc_disk_requirements() {
  # Preflight runs after the R2 package is already on disk, so package bytes are
  # reflected in CURRENT_AVAILABLE and must not be double-counted.
  #
  # OS materialization and Phase 2 build run sequentially. Future free-space
  # need is therefore max(OS_STAGE_EXTRA, PHASE2_STAGE_EXTRA) + SAFETY_RESERVE.
  #
  # Valid existing finals are REUSED (no ACPS/bundle bytes). Invalid finals are
  # deleted before rebuild, so their size is not part of future required.
  # Peak Phase 2 large data is at most ACPS source + new bundle (2 copies).
  #
  # TOTAL_CAPACITY_BASED_PROJECTED_PEAK_BYTES reports peak used capacity
  # (current used + sequential stage peak) for operator sizing guidance.
  local os_pkg_bytes payload_bytes acps_bytes ver existing_bundle
  local reserve_floor_bytes reserve_pct_bytes fs_size_bytes metadata_oh
  local stage_peak_bytes current_used_bytes existing_final_bytes
  local reuse_phase2=0 one_copy=0
  os_pkg_bytes="${OS_CORE_PACKAGE_BYTES:-0}"
  payload_bytes="${OS_CORE_PAYLOAD_BYTES:-0}"
  acps_bytes="${ACPS_EXPECTED_BYTES:-0}"
  [[ "$os_pkg_bytes" =~ ^[0-9]+$ ]] || os_pkg_bytes=0
  [[ "$payload_bytes" =~ ^[0-9]+$ ]] || payload_bytes=0
  [[ "$acps_bytes" =~ ^[0-9]+$ ]] || acps_bytes=0
  metadata_oh=$((512 * 1024 * 1024))

  if [[ "${PHASE2_BUNDLE_ACTION:-}" == "REUSE" || "${PHASE2_REBUILD_REQUIRED:-}" == "NO" ]]; then
    reuse_phase2=1
    acps_bytes=0
  elif [[ "${PHASE2_REBUILD_SOURCE:-}" == "EXISTING_FINAL" ]]; then
    acps_bytes=0
  fi

  DISK_PREFLIGHT_R2_REQUIRED_BYTES=0
  DISK_PREFLIGHT_ACPS_SOURCE_BYTES=$acps_bytes
  # Bundle output is approximately the ACPS source tree size (9-file tar).
  DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES=$acps_bytes
  PHASE2_ACPS_SOURCE_REQUIRED_BYTES=$DISK_PREFLIGHT_ACPS_SOURCE_BYTES
  PHASE2_BUNDLE_OUTPUT_REQUIRED_BYTES=$DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES
  VALID_FINAL_REBUILD_REQUIRED_BYTES=0
  if [[ "$reuse_phase2" -eq 1 ]]; then
    PHASE2_REBUILD_REQUIRED=NO
  else
    PHASE2_REBUILD_REQUIRED="${PHASE2_REBUILD_REQUIRED:-YES}"
  fi

  # Existing final (if still present) already reduces df available.
  DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES=0
  existing_final_bytes=0
  ver="${TARGET_DP_VERSION:-${DP_PHASE2_VERSION:-6.6.0}}"
  existing_bundle="${MM_DP_PHASE2_ROOT:-${MM_MIRROR_ROOT:-/var/spool/apt-mirror}/dp-phase2}/${ver}/dp_bundle_${ver}-current.tar"
  if [[ -f "$existing_bundle" ]]; then
    existing_final_bytes="$(mm_file_bytes "$existing_bundle")"
    [[ "$existing_final_bytes" =~ ^[0-9]+$ ]] || existing_final_bytes=0
  fi
  DISK_PREFLIGHT_EXISTING_FINAL_BYTES=$existing_final_bytes

  DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES=$((payload_bytes + metadata_oh))
  if [[ "$reuse_phase2" -eq 1 ]]; then
    # Valid final reuse: Phase 2 adds only metadata-level free-space need.
    DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES=$metadata_oh
  elif [[ "${PHASE2_REBUILD_SOURCE:-}" == "EXISTING_FINAL" ]]; then
    # Local rebuild from the existing final: extract one extra copy, then
    # delete the old final before writing .new. Never three simultaneous copies.
    one_copy="${PHASE2_EXISTING_FINAL_BYTES:-0}"
    [[ "$one_copy" =~ ^[0-9]+$ ]] || one_copy=0
    if [[ "$one_copy" -eq 0 ]]; then
      one_copy=$existing_final_bytes
    fi
    DISK_PREFLIGHT_ACPS_SOURCE_BYTES=0
    DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES=$one_copy
    PHASE2_ACPS_SOURCE_REQUIRED_BYTES=0
    PHASE2_BUNDLE_OUTPUT_REQUIRED_BYTES=$one_copy
    DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES=$((one_copy + metadata_oh))
  else
    DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES=$((
      DISK_PREFLIGHT_ACPS_SOURCE_BYTES
      + DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES
      + metadata_oh
    ))
  fi
  PHASE2_STAGE_REQUIRED_BYTES=$DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES
  mm_normalize_preparation_mode
  if mm_is_phase2_only; then
    # PHASE2_ONLY never materializes OS; OS stage peak is not required.
    DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES=0
    stage_peak_bytes=$DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES
    DISK_PREFLIGHT_R2_REQUIRED_BYTES=0
  elif [[ "$DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES" -gt "$DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES" ]]; then
    stage_peak_bytes=$DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES
  else
    stage_peak_bytes=$DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES
  fi
  DISK_PREFLIGHT_SEQUENTIAL_STAGE_PEAK_BYTES=$stage_peak_bytes
  DISK_PREFLIGHT_TEMP_OVERHEAD_BYTES=$metadata_oh
  DISK_PREFLIGHT_PREPARATION_MODE="${PREPARATION_MODE}"

  reserve_floor_bytes=$((10 * 1024 * 1024 * 1024))
  fs_size_bytes="$(mm_fs_size_bytes "${MM_MIRROR_ROOT}")"
  [[ "$fs_size_bytes" =~ ^[0-9]+$ ]] || fs_size_bytes=0
  if [[ -n "${MM_MOCK_SAFETY_RESERVE_BYTES:-}" ]]; then
    DISK_PREFLIGHT_SAFETY_RESERVE_BYTES="$MM_MOCK_SAFETY_RESERVE_BYTES"
  else
    reserve_pct_bytes=$((fs_size_bytes / 10))
    if [[ "$reserve_pct_bytes" -gt "$reserve_floor_bytes" ]]; then
      DISK_PREFLIGHT_SAFETY_RESERVE_BYTES=$reserve_pct_bytes
    else
      DISK_PREFLIGHT_SAFETY_RESERVE_BYTES=$reserve_floor_bytes
    fi
  fi
  [[ "$DISK_PREFLIGHT_SAFETY_RESERVE_BYTES" =~ ^[0-9]+$ ]] \
    || DISK_PREFLIGHT_SAFETY_RESERVE_BYTES=$reserve_floor_bytes

  # Compat aliases used by older logs/tests.
  OS_MATERIALIZE_TEMP_BYTES=$payload_bytes
  DP_BUILD_TEMP_BYTES=$DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES
  SAFETY_MARGIN_BYTES=$DISK_PREFLIGHT_SAFETY_RESERVE_BYTES

  CURRENT_AVAILABLE_BASED_REQUIRED_BYTES=$((
    stage_peak_bytes + DISK_PREFLIGHT_SAFETY_RESERVE_BYTES
  ))
  DISK_PREFLIGHT_TOTAL_REQUIRED_BYTES=$CURRENT_AVAILABLE_BASED_REQUIRED_BYTES
  TOTAL_REQUIRED_BYTES=$CURRENT_AVAILABLE_BASED_REQUIRED_BYTES

  DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES="$(mm_free_bytes "${MM_MIRROR_ROOT}")"
  AVAILABLE_BYTES="$DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES"
  [[ -n "$AVAILABLE_BYTES" && "$AVAILABLE_BYTES" =~ ^[0-9]+$ ]] \
    || mm_die "DISK_PREFLIGHT=FAIL cannot_read_df"

  if [[ "$fs_size_bytes" -ge "$AVAILABLE_BYTES" ]]; then
    current_used_bytes=$((fs_size_bytes - AVAILABLE_BYTES))
  else
    current_used_bytes=0
  fi
  TOTAL_CAPACITY_BASED_PROJECTED_PEAK_BYTES=$((current_used_bytes + stage_peak_bytes))
  DISK_PREFLIGHT_PROJECTED_PEAK_BYTES=$TOTAL_CAPACITY_BASED_PROJECTED_PEAK_BYTES

  if [[ "$AVAILABLE_BYTES" -lt "$TOTAL_REQUIRED_BYTES" ]]; then
    DISK_PREFLIGHT_RESULT=FAIL
    DISK_PREFLIGHT=FAIL
  else
    DISK_PREFLIGHT_RESULT=PASS
    DISK_PREFLIGHT=PASS
  fi

  mm_info "MIRROR_SERVER_DISK=100GB"
  mm_info "OS_CORE_PACKAGE_BYTES=${os_pkg_bytes}"
  mm_info "OS_CORE_PAYLOAD_BYTES=${payload_bytes}"
  mm_info "ACPS_EXPECTED_BYTES=${acps_bytes}"
  mm_info "PHASE2_BUNDLE_ACTION=${PHASE2_BUNDLE_ACTION:-}"
  mm_info "PHASE2_REBUILD_REQUIRED=${PHASE2_REBUILD_REQUIRED}"
  mm_info "PHASE2_ACPS_SOURCE_REQUIRED_BYTES=${PHASE2_ACPS_SOURCE_REQUIRED_BYTES}"
  mm_info "PHASE2_BUNDLE_OUTPUT_REQUIRED_BYTES=${PHASE2_BUNDLE_OUTPUT_REQUIRED_BYTES}"
  mm_info "PHASE2_STAGE_REQUIRED_BYTES=${PHASE2_STAGE_REQUIRED_BYTES}"
  mm_info "VALID_FINAL_REBUILD_REQUIRED_BYTES=${VALID_FINAL_REBUILD_REQUIRED_BYTES}"
  mm_info "OS_MATERIALIZE_TEMP_BYTES=${OS_MATERIALIZE_TEMP_BYTES}"
  mm_info "DP_BUILD_TEMP_BYTES=${DP_BUILD_TEMP_BYTES}"
  mm_info "DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES=${DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES}"
  mm_info "DISK_PREFLIGHT_R2_REQUIRED_BYTES=${DISK_PREFLIGHT_R2_REQUIRED_BYTES}"
  mm_info "DISK_PREFLIGHT_ACPS_SOURCE_BYTES=${DISK_PREFLIGHT_ACPS_SOURCE_BYTES}"
  mm_info "DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES=${DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES}"
  mm_info "DISK_PREFLIGHT_EXISTING_FINAL_BYTES=${DISK_PREFLIGHT_EXISTING_FINAL_BYTES}"
  mm_info "DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES=${DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES}"
  mm_info "DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES=${DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES}"
  mm_info "DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES=${DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES}"
  mm_info "DISK_PREFLIGHT_SEQUENTIAL_STAGE_PEAK_BYTES=${DISK_PREFLIGHT_SEQUENTIAL_STAGE_PEAK_BYTES}"
  mm_info "DISK_PREFLIGHT_TEMP_OVERHEAD_BYTES=${DISK_PREFLIGHT_TEMP_OVERHEAD_BYTES}"
  mm_info "DISK_PREFLIGHT_SAFETY_RESERVE_BYTES=${DISK_PREFLIGHT_SAFETY_RESERVE_BYTES}"
  mm_info "CURRENT_AVAILABLE_BASED_REQUIRED_BYTES=${CURRENT_AVAILABLE_BASED_REQUIRED_BYTES}"
  mm_info "TOTAL_CAPACITY_BASED_PROJECTED_PEAK_BYTES=${TOTAL_CAPACITY_BASED_PROJECTED_PEAK_BYTES}"
  mm_info "DISK_PREFLIGHT_TOTAL_REQUIRED_BYTES=${DISK_PREFLIGHT_TOTAL_REQUIRED_BYTES}"
  mm_info "TOTAL_REQUIRED_BYTES=${TOTAL_REQUIRED_BYTES}"
  mm_info "AVAILABLE_BYTES=${AVAILABLE_BYTES}"
  mm_info "DISK_PREFLIGHT_RESULT=${DISK_PREFLIGHT_RESULT}"
  mm_info "DISK_PREFLIGHT=${DISK_PREFLIGHT}"
  [[ "$DISK_PREFLIGHT" == "PASS" ]] || mm_die "DISK_PREFLIGHT=FAIL"
}

mm_mark_changed() {
  MM_FILES_CHANGED=YES
  mm_state_set FILES_CHANGED YES
}

mm_configured_label() {
  local val="$1"
  if [[ -n "$val" ]]; then
    printf 'configured'
  else
    printf 'not configured'
  fi
}

# Required HTTP client artifacts (must be real files; empty directory is FAIL)
MM_CLIENT_REQUIRED_FILES=(
  dp-offline-upgrade-xenial-to-bionic.sh
  dp-offline-upgrade-xenial-to-bionic.sh.sha256
  dp-offline-upgrade-bionic-to-focal.sh
  dp-offline-upgrade-bionic-to-focal.sh.sha256
  dp-offline-upgrade-focal-to-jammy.sh
  dp-offline-upgrade-focal-to-jammy.sh.sha256
  dp-offline-upgrade-jammy-to-noble.sh
  dp-offline-upgrade-jammy-to-noble.sh.sha256
  dp-launch-xenial-to-bionic.sh
  dp-launch-xenial-to-bionic.sh.sha256
  dp-launch-bionic-to-focal.sh
  dp-launch-bionic-to-focal.sh.sha256
  dp-launch-focal-to-jammy.sh
  dp-launch-focal-to-jammy.sh.sha256
  dp-launch-jammy-to-noble.sh
  dp-launch-jammy-to-noble.sh.sha256
  upgrade-xenial-to-bionic.sh
  upgrade-xenial-to-bionic.sh.sha256
  upgrade-bionic-to-focal.sh
  upgrade-bionic-to-focal.sh.sha256
  upgrade-focal-to-jammy.sh
  upgrade-focal-to-jammy.sh.sha256
  upgrade-jammy-to-noble.sh
  upgrade-jammy-to-noble.sh.sha256
  upgrade-phase2.sh
  upgrade-phase2.sh.sha256
  stage-dp-phase2.sh
  stage-dp-phase2.sh.sha256
  dp-client-command-runner.sh
  dp-client-command-runner.sh.sha256
  runner-manifest
  runner-manifest.asc
  public-keyring.gpg
  client-set.env
)

MM_CLIENT_PHASE2_REQUIRED_FILES=(
  stage-dp-phase2.sh
  stage-dp-phase2.sh.sha256
  upgrade-phase2.sh
  upgrade-phase2.sh.sha256
  bringup_py3_dp_lifecycle.sh
  phase2-helper-generation.manifest
  lib/dp-offline-source-product-version.sh
  lib/dp-phase2-operation-progress.sh
  lib/dp-phase2-bringup-lifecycle.sh
  lib/dp-phase2-ubuntu-prerequisites.sh
)

mm_client_files_ready_phase2() {
  local root="${1:-${MM_CLIENT_ROOT}}"
  local f
  [[ -d "$root" ]] || return 1
  for f in "${MM_CLIENT_PHASE2_REQUIRED_FILES[@]}"; do
    [[ -f "${root}/${f}" ]] || return 1
  done
  (cd "$root" && sha256sum -c stage-dp-phase2.sh.sha256 >/dev/null 2>&1) || return 1
  (cd "$root" && sha256sum -c upgrade-phase2.sh.sha256 >/dev/null 2>&1) || return 1
  bash -n "${root}/upgrade-phase2.sh" || return 1
  grep -q 'phase2-helper-generation.manifest' "${root}/upgrade-phase2.sh" || return 1
  grep -q 'stage-dp-phase2.sh' "${root}/upgrade-phase2.sh" || return 1
  grep -q -- '--target-version' "${root}/upgrade-phase2.sh" || return 1
  grep -q -- '--mirror-url' "${root}/upgrade-phase2.sh" || return 1
  # Normal wrapper must NOT force same-version recovery on every invocation.
  if grep -E 'sudo bash.*"\$SCRIPT".*--same-version-recovery' "${root}/upgrade-phase2.sh" \
    >/dev/null 2>&1; then
    return 1
  fi
  [[ -f "${root}/upgrade-phase2-same-version-recovery.sh" ]] || return 1
  grep -q 'CONFIRM_SAME_VERSION_RECOVERY=YES' \
    "${root}/upgrade-phase2-same-version-recovery.sh" || return 1
  if grep -qE 'curl[^|;]*\|[[:space:]]*(bash|sh)([[:space:]]|$)' "${root}/upgrade-phase2.sh"; then
    return 1
  fi
  if [[ -f "${MM_PROJECT_ROOT:-}/scripts/lib/phase2_helper_generation.sh" ]]; then
    # shellcheck source=/dev/null
    source "${MM_PROJECT_ROOT}/scripts/lib/phase2_helper_generation.sh"
    phase2_helper_generation_verify "$root" || return 1
    local gen_sha
    gen_sha="$(phase2_helper_generation_sha256 "${root}/phase2-helper-generation.manifest")" || return 1
    grep -Fq "H='${gen_sha}'" "${root}/upgrade-phase2.sh" || return 1
  else
    (cd "$root" && sha256sum -c phase2-helper-generation.manifest >/dev/null 2>&1) || return 1
  fi
  return 0
}

mm_client_files_ready() {
  local root="${1:-${MM_CLIENT_ROOT}}"
  local f
  [[ -d "$root" ]] || return 1
  for f in "${MM_CLIENT_REQUIRED_FILES[@]}"; do
    [[ -f "${root}/${f}" ]] || return 1
  done
  for f in \
    dp-offline-upgrade-xenial-to-bionic.sh \
    dp-offline-upgrade-bionic-to-focal.sh \
    dp-offline-upgrade-focal-to-jammy.sh \
    dp-offline-upgrade-jammy-to-noble.sh \
    dp-launch-xenial-to-bionic.sh \
    dp-launch-bionic-to-focal.sh \
    dp-launch-focal-to-jammy.sh \
    dp-launch-jammy-to-noble.sh \
    upgrade-xenial-to-bionic.sh \
    upgrade-bionic-to-focal.sh \
    upgrade-focal-to-jammy.sh \
    upgrade-jammy-to-noble.sh \
    upgrade-phase2.sh \
    stage-dp-phase2.sh \
    dp-client-command-runner.sh
  do
    (cd "$root" && sha256sum -c "${f}.sha256" >/dev/null 2>&1) || return 1
  done
  # Signed runner checksum manifest must match the sidecar.
  [[ -f "${root}/runner-manifest" && -f "${root}/runner-manifest.asc" ]] || return 1
  cmp -s "${root}/runner-manifest" "${root}/dp-client-command-runner.sh.sha256" || return 1
  mm_client_launchers_ready "$root" || return 1
  return 0
}

# Local pre-readiness launcher contract for FULL mode.
mm_client_launchers_ready() {
  local root="${1:-${MM_CLIENT_ROOT}}"
  local hop launcher meta_key meta_sha file_sha mirror fpr
  local wrapper wrapper_sha wkey wmeta
  local meta="${root}/client-set.env"
  [[ -d "$root" && -f "$meta" ]] || return 1
  mm_parse_env_metadata_get "$meta" >/dev/null || return 1
  mirror="$(mm_parse_env_metadata_get "$meta" CLIENT_MIRROR_BASE_URL 2>/dev/null || true)"
  [[ -z "$mirror" ]] && mirror="$(mm_parse_env_metadata_get "$meta" MIRROR_HTTP_URL 2>/dev/null || true)"
  fpr="$(mm_parse_env_metadata_get "$meta" CLIENT_SIGNING_FINGERPRINT)" || return 1
  fpr="${fpr^^}"
  fpr="${fpr// /}"
  [[ -n "$mirror" && -n "$fpr" ]] || return 1
  mm_parse_env_metadata_get "$meta" CLIENT_LAUNCHER_SCHEMA_VERSION >/dev/null || return 1
  for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
    launcher="dp-launch-${hop}.sh"
    [[ -f "${root}/${launcher}" && -s "${root}/${launcher}" ]] || return 1
    [[ -f "${root}/${launcher}.sha256" ]] || return 1
    (cd "$root" && sha256sum -c "${launcher}.sha256" >/dev/null 2>&1) || return 1
    file_sha="$(sha256sum "${root}/${launcher}" | awk '{print $1}')"
    meta_key="CLIENT_LAUNCHER_$(printf '%s' "$hop" | tr 'a-z-' 'A-Z_')_SHA256"
    meta_sha="$(mm_parse_env_metadata_get "$meta" "$meta_key")" || return 1
    [[ -n "$meta_sha" && "$meta_sha" == "$file_sha" ]] || return 1
    grep -q "HOP='${hop}'" "${root}/${launcher}" || return 1
    grep -Fq "${mirror%/}" "${root}/${launcher}" || return 1
    grep -q "EXPECTED_FPR='${fpr}'" "${root}/${launcher}" || return 1
    grep -q 'dp-client-command-runner.sh' "${root}/${launcher}" || return 1
    if grep -qE 'BEGIN PGP PRIVATE KEY|ACPS_PASS|PASSWORD=' "${root}/${launcher}"; then
      return 1
    fi
    bash -n "${root}/${launcher}" || return 1
    wrapper="upgrade-${hop}.sh"
    [[ -f "${root}/${wrapper}" && -s "${root}/${wrapper}" ]] || return 1
    [[ -f "${root}/${wrapper}.sha256" ]] || return 1
    (cd "$root" && sha256sum -c "${wrapper}.sha256" >/dev/null 2>&1) || return 1
    wrapper_sha="$(sha256sum "${root}/${wrapper}" | awk '{print $1}')"
    wkey="CLIENT_WRAPPER_$(printf '%s' "$hop" | tr 'a-z-' 'A-Z_')_SHA256"
    wmeta="$(mm_parse_env_metadata_get "$meta" "$wkey")" || return 1
    [[ -n "$wmeta" && "$wmeta" == "$wrapper_sha" ]] || return 1
    grep -Fq "${launcher}" "${root}/${wrapper}" || return 1
    grep -Fq "LAUNCHER_SHA256='${file_sha}'" "${root}/${wrapper}" || return 1
    grep -Fq "${mirror%/}" "${root}/${wrapper}" || return 1
    bash -n "${root}/${wrapper}" || return 1
    if grep -qE 'curl[^|;]*\|[[:space:]]*(bash|sh)([[:space:]]|$)' "${root}/${wrapper}"; then
      return 1
    fi
  done
  [[ -f "${root}/upgrade-phase2.sh" && -f "${root}/upgrade-phase2.sh.sha256" ]] || return 1
  (cd "$root" && sha256sum -c upgrade-phase2.sh.sha256 >/dev/null 2>&1) || return 1
  bash -n "${root}/upgrade-phase2.sh" || return 1
  return 0
}

# Verify that an existing full client set was built by the currently installed
# builders/templates/helpers, not merely that its files and old sidecars exist.
mm_client_set_current_source() {
  local root="${1:-${MM_CLIENT_ROOT}}"
  local module="${MM_PROJECT_ROOT}/scripts/lib/client_build_provenance.py"
  local mirror="${MIRROR_HTTP_URL:-}" expected_fpr="" mode="${PREPARATION_MODE:-FULL}"
  local out rc=0
  [[ -f "$module" ]] || return 1
  [[ -f "${root}/client-set.env" ]] || return 1
  if [[ -z "$mirror" && -n "${MIRROR_SERVER_IP:-}" ]]; then
    mirror="http://${MIRROR_SERVER_IP}"
  fi
  if [[ -f "${MM_CONFIG_DIR}/client-signing/fingerprint" ]]; then
    expected_fpr="$(tr -d '[:space:]' <"${MM_CONFIG_DIR}/client-signing/fingerprint" | tr '[:lower:]' '[:upper:]')"
  elif [[ -n "${LOCAL_KEY_FINGERPRINT:-}" ]]; then
    expected_fpr="${LOCAL_KEY_FINGERPRINT}"
  fi
  set +e
  out="$(python3 "$module" verify-client-set \
    --project-root "$MM_PROJECT_ROOT" \
    --client-root "$root" \
    --expected-mirror "$mirror" \
    --expected-fingerprint "$expected_fpr" \
    --expected-mode "$mode" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    printf '%s\n' "$out" >&2
    return "$rc"
  fi
  printf '%s\n' "$out"
  return 0
}

# Authoritative long-operation wrapper with stable log contract.
# OPERATION_START name=<name> target=<sanitized>
# OPERATION_HEARTBEAT name=<name> elapsed_seconds=<n>
# OPERATION_END name=<name> rc=<rc> elapsed_seconds=<n>
mm_run_long_operation() {
  local name="$1"
  local target="$2"
  shift 2
  if [[ "${1:-}" != "--" ]]; then
    mm_die "mm_run_long_operation: expected -- before command"
  fi
  shift
  local start_ts hb_secs hb_pid="" cmd_pid="" rc=0 elapsed sanitized
  sanitized="$(basename "$target" 2>/dev/null || printf '%s' "$target")"
  sanitized="${sanitized//[^A-Za-z0-9._+-]/_}"
  start_ts="$(date +%s)"
  hb_secs="$(mm_long_step_heartbeat_seconds)"
  mm_info "OPERATION_START name=${name} target=${sanitized}"
  "$@" &
  cmd_pid=$!
  _mm_op_cleanup() {
    kill "$cmd_pid" 2>/dev/null || true
    kill "$hb_pid" 2>/dev/null || true
  }
  trap '_mm_op_cleanup' INT TERM
  (
    while kill -0 "$cmd_pid" 2>/dev/null; do
      sleep "$hb_secs" || break
      kill -0 "$cmd_pid" 2>/dev/null || break
      elapsed=$(( $(date +%s) - start_ts ))
      mm_info "OPERATION_HEARTBEAT name=${name} elapsed_seconds=${elapsed}"
    done
  ) &
  hb_pid=$!
  if wait "$cmd_pid"; then rc=0; else rc=$?; fi
  if [[ -n "$hb_pid" ]]; then
    kill "$hb_pid" 2>/dev/null || true
    wait "$hb_pid" 2>/dev/null || true
  fi
  trap - INT TERM
  elapsed=$(( $(date +%s) - start_ts ))
  mm_info "OPERATION_END name=${name} rc=${rc} elapsed_seconds=${elapsed}"
  return "$rc"
}

mm_check_client_files_ready() {
  local ok=0
  if mm_is_phase2_only; then
    mm_client_files_ready_phase2 "${MM_CLIENT_ROOT}" && ok=1
  else
    mm_client_files_ready "${MM_CLIENT_ROOT}" && ok=1
  fi
  if [[ "$ok" -eq 1 ]]; then
    mm_state_set CLIENT_FILES_READY PASS
    mm_ok "CLIENT_FILES_READY=PASS"
    return 0
  fi
  mm_state_set CLIENT_FILES_READY FAIL
  mm_error "CLIENT_FILES_READY=FAIL (required scripts/checksums missing under ${MM_CLIENT_ROOT})"
  return 1
}

# Phase 2 helper scripts only (no OS-hop clients). Used by PHASE2_ONLY mode.
mm_phase2_helpers_ready() {
  mm_client_files_ready_phase2 "${1:-${MM_CLIENT_ROOT}}"
}

mm_check_phase2_helpers_ready() {
  if mm_phase2_helpers_ready "${MM_CLIENT_ROOT}"; then
    mm_state_set PHASE2_HELPERS_READY PASS
    mm_ok "PHASE2_HELPERS_READY=PASS"
    return 0
  fi
  mm_state_set PHASE2_HELPERS_READY FAIL
  mm_error "PHASE2_HELPERS_READY=FAIL (generation-bound Phase 2 helper unit missing under ${MM_CLIENT_ROOT})"
  return 1
}

# Count published OS-hop client scripts under CLIENT_HTTP_ROOT (0..4).
mm_count_published_hop_clients() {
  local root="${1:-${MM_CLIENT_ROOT}}"
  local n=0 hop
  for hop in \
    xenial-to-bionic \
    bionic-to-focal \
    focal-to-jammy \
    jammy-to-noble
  do
    [[ -f "${root}/dp-offline-upgrade-${hop}.sh" ]] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# Preflight before Download and Prepare: build/sign tooling must exist.
# Does NOT require generated hop clients (those are produced after OS Core READY).
mm_check_client_build_prerequisites_ready() {
  local root="${MM_PROJECT_ROOT:-}"
  local libdir rebuild prereq_fail=0 f
  local mirror_url signing_base

  [[ -n "$root" && -d "$root" ]] || {
    mm_error "CLIENT_BUILD_PREREQUISITES_READY=FAIL MM_PROJECT_ROOT unset"
    mm_state_set CLIENT_BUILD_PREREQUISITES_READY FAIL
    return 1
  }
  libdir="${root}/scripts/lib"
  rebuild="${root}/scripts/rebuild-publish-clients.sh"

  for f in \
    "${root}/client/dp-offline-upgrade-xenial-to-bionic.sh.in" \
    "${root}/client/dp-offline-upgrade-bionic-to-focal.sh.in" \
    "${root}/client/dp-offline-upgrade-focal-to-jammy.sh.in" \
    "${root}/client/dp-offline-upgrade-jammy-to-noble.sh.in" \
    "${root}/client/dp-client-hop-launcher.sh.in" \
    "${libdir}/build_client_xenial_to_bionic.py" \
    "${libdir}/build_client_bionic_to_focal.py" \
    "${libdir}/build_client_focal_to_jammy.py" \
    "${libdir}/build_client_jammy_to_noble.py" \
    "${libdir}/build_client_launchers.py" \
    "${libdir}/client_build_repository.py" \
    "${libdir}/client_build_provenance.py" \
    "${libdir}/atomic_dir_swap.py" \
    "${libdir}/mirror_host_ip.sh" \
    "${libdir}/local_client_signing.sh" \
    "${libdir}/client_mirror_gates.sh" \
    "$rebuild"
  do
    if [[ ! -f "$f" ]]; then
      mm_error "CLIENT_BUILD_PREREQ_MISSING=${f}"
      prereq_fail=1
    fi
  done
  if [[ ! -x "$rebuild" && ! -f "$rebuild" ]]; then
    mm_error "CLIENT_BUILD_PREREQ_MISSING=${rebuild}"
    prereq_fail=1
  elif [[ ! -x "$rebuild" ]]; then
    chmod +x "$rebuild" 2>/dev/null || true
    if [[ ! -x "$rebuild" ]]; then
      mm_error "CLIENT_BUILD_PREREQ_NOT_EXECUTABLE=${rebuild}"
      prereq_fail=1
    fi
  fi

  for f in gpg python3 sha256sum; do
    if ! command -v "$f" >/dev/null 2>&1; then
      mm_error "CLIENT_BUILD_PREREQ_CMD_MISSING=${f}"
      prereq_fail=1
    fi
  done

  # Prefer an explicit signing dir, then MM_CONFIG_DIR, then the GUI config
  # directory (tests write MM_CONFIG_FILE under a temp workdir). Never require
  # write access to /etc when a temp config path is already in use.
  signing_base="${MM_CONFIG_DIR:-}"
  if [[ -z "$signing_base" && -n "${MM_CONFIG_FILE:-}" ]]; then
    signing_base="$(dirname "$MM_CONFIG_FILE")"
  fi
  signing_base="${signing_base:-/etc/ubuntu-mirror}"
  # shellcheck source=local_client_signing.sh
  source "${libdir}/local_client_signing.sh"
  LOCAL_CLIENT_SIGNING_DIR="${LOCAL_CLIENT_SIGNING_DIR:-${signing_base}/client-signing}"
  export LOCAL_CLIENT_SIGNING_DIR
  if ! local_signing_ensure_keypair; then
    mm_error "CLIENT_BUILD_PREREQ_SIGNING_KEY=FAIL"
    prereq_fail=1
  fi

  # Private key must never be present under the HTTP client document root.
  if [[ -d "${MM_CLIENT_ROOT:-}" ]]; then
    if ! local_signing_assert_private_not_published "${MM_CLIENT_ROOT}"; then
      mm_error "CLIENT_BUILD_PREREQ_PRIVATE_KEY_EXPOSED=YES"
      prereq_fail=1
    fi
  fi
  # Repo must not ship a private key under client/ or config templates.
  if find "${root}/client" "${root}/config" -type f \( -name 'private.gpg' -o -name '*private*.gpg' \) 2>/dev/null | grep -q .; then
    mm_error "CLIENT_BUILD_PREREQ_PRIVATE_KEY_IN_TREE=YES"
    prereq_fail=1
  fi

  if mm_is_phase2_only; then
    mm_info "OS_HOP_CLIENT_FILES_REQUIRED=NO"
    # Phase 2 helpers come from install/bootstrap; require the source helper exists.
    if [[ ! -f "${root}/client/stage-dp-phase2.sh" ]]; then
      mm_error "CLIENT_BUILD_PREREQ_MISSING=${root}/client/stage-dp-phase2.sh"
      prereq_fail=1
    fi
  else
    # Resolve / validate Mirror HTTP URL (do not require hop clients yet).
    if ! mirror_url="$(mm_client_mirror_url)"; then
      mm_error "CLIENT_BUILD_PREREQ_MIRROR_URL=FAIL"
      prereq_fail=1
    else
      MIRROR_HTTP_URL="$mirror_url"
      mm_info "CLIENT_BUILD_PREREQ_MIRROR_URL=${mirror_url}"
    fi
  fi

  if [[ "$prereq_fail" -ne 0 ]]; then
    mm_state_set CLIENT_BUILD_PREREQUISITES_READY FAIL
    mm_error "CLIENT_BUILD_PREREQUISITES_READY=FAIL"
    return 1
  fi
  mm_state_set CLIENT_BUILD_PREREQUISITES_READY PASS
  mm_ok "CLIENT_BUILD_PREREQUISITES_READY=PASS"
  return 0
}
