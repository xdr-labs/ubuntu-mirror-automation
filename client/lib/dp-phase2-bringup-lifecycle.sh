#!/usr/bin/env bash
# Phase 2 bringup lifecycle state — authoritative run identity, completion sentinel.
# shellcheck shell=bash
# Never treat instructional "Bringup complete:" text as completion.

PHASE2_BRINGUP_DIR_DEFAULT="${PHASE2_BRINGUP_DIR_DEFAULT:-/opt/aelladata/os-upgrade/offline/phase2-bringup}"
PHASE2_BRINGUP_LOG_DEFAULT="${PHASE2_BRINGUP_LOG_DEFAULT:-/var/log/aella/aella_py3_bringup.log}"
PHASE2_BRINGUP_MONITOR_SECONDS="${PHASE2_BRINGUP_MONITOR_SECONDS:-30}"

# Known aella_cli paths (bounded discovery — never full filesystem scan)
PHASE2_AELLA_CLI_CANDIDATES=(
  /usr/bin/aella_cli
  /usr/local/bin/aella_cli
  /opt/aella/bin/aella_cli
  /opt/aelladata/bin/aella_cli
)

p2b_dir() {
  printf '%s' "${PHASE2_BRINGUP_DIR:-${PHASE2_BRINGUP_DIR_DEFAULT}}"
}

p2b_ensure_dir() {
  local d
  d="$(p2b_dir)"
  mkdir -p "$d"
  chmod 0700 "$d" 2>/dev/null || true
  if [[ "$(id -u)" -eq 0 ]]; then
    chown root:root "$d" 2>/dev/null || true
  fi
}

p2b_atomic_write() {
  local dest="$1"
  local parent tmp
  parent="$(dirname "$dest")"
  mkdir -p "$parent"
  chmod 0700 "$parent" 2>/dev/null || true
  tmp="${dest}.tmp.$$.${RANDOM:-0}"
  cat >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || true
  if [[ "$(id -u)" -eq 0 ]]; then
    chown root:root "$tmp" 2>/dev/null || true
  fi
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$dest" 2>/dev/null || true
  return 0
}

p2b_read_file() {
  local f="$1"
  [[ -f "$f" ]] || { printf ''; return 0; }
  tr -d '\r' <"$f" | head -1 | tr -d '\n'
}

p2b_utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

p2b_new_run_id() {
  date -u +%Y%m%dT%H%M%SZ-$$-${RANDOM:-0}
}

# Validate PID identity: cmdline must contain expected token; reject pgrep self-match.
p2b_pid_alive_and_matches() {
  local pid="$1"
  local expect_token="${2:-bringup}"
  local cmdline start_file recorded_start proc_start
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ -d "/proc/${pid}" ]] || return 1
  cmdline="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
  [[ -n "$cmdline" ]] || return 1
  # Reject diagnostic tools matching themselves
  case "$cmdline" in
    *pgrep*|*pidof*" ${expect_token}"*) return 1 ;;
  esac
  case "$cmdline" in
    *"${expect_token}"*) ;;
    *) return 1 ;;
  esac
  start_file="$(p2b_dir)/worker-start-ticks"
  recorded_start="$(p2b_read_file "$start_file")"
  if [[ -z "$recorded_start" ]]; then
    recorded_start="$(p2b_read_file "$(p2b_dir)/worker-start-time")"
  fi
  if [[ -n "$recorded_start" && -r "/proc/${pid}/stat" ]]; then
    # Field 22 is starttime (clock ticks); soft check only when recorded.
    proc_start="$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || true)"
    if [[ -n "$proc_start" && -n "$recorded_start" && "$recorded_start" =~ ^[0-9]+$ ]]; then
      # Allow equality match of recorded starttime tick when present.
      if [[ "$proc_start" != "$recorded_start" ]]; then
        # Also accept if recorded value was epoch seconds (legacy) — skip hard fail.
        if [[ "$recorded_start" -gt 1000000000 ]]; then
          :
        else
          return 1
        fi
      fi
    fi
  fi
  return 0
}

p2b_read_state() {
  p2b_read_file "$(p2b_dir)/state"
}

p2b_write_state() {
  local st="$1"
  p2b_ensure_dir
  printf '%s\n' "$st" | p2b_atomic_write "$(p2b_dir)/state"
}

p2b_write_result_env() {
  local run_id="$1" worker_pid="$2" target="$3" started="$4" completed="$5"
  local exit_code="$6" result="$7" terminal="$8" log_path="$9"
  p2b_ensure_dir
  {
    echo "BRINGUP_TERMINAL_STATE=${terminal}"
    echo "BRINGUP_RESULT=${result}"
    echo "BRINGUP_RUN_ID=${run_id}"
    echo "BRINGUP_WORKER_PID=${worker_pid}"
    echo "BRINGUP_TARGET_VERSION=${target}"
    echo "BRINGUP_STARTED_AT=${started}"
    echo "BRINGUP_COMPLETED_AT=${completed}"
    echo "BRINGUP_EXIT_CODE=${exit_code}"
    echo "BRINGUP_LOG_PATH=${log_path}"
    echo "BRINGUP_COMPLETION_SENTINEL=$([ "$terminal" = "COMPLETED" ] && echo PASS || echo FAIL)"
  } | p2b_atomic_write "$(p2b_dir)/result.env"
}

# Deterministic FAILED lifecycle artifacts. Does not return.
p2b_fail_run() {
  local d="$1"
  local run_id="$2"
  local worker_pid="$3"
  local target="$4"
  local started="$5"
  local logf="$6"
  local rc="$7"
  local reason="$8"
  local completed
  completed="$(p2b_utc_now)"
  printf '%s\n' "$rc" | p2b_atomic_write "${d}/exit-code"
  printf '%s\n' "$completed" | p2b_atomic_write "${d}/completed-at"
  {
    echo "BRINGUP_TERMINAL_STATE=FAILED"
    echo "BRINGUP_RESULT=FAIL"
    echo "FAILURE_REASON=${reason}"
    echo "BRINGUP_EXIT_CODE=${rc}"
    echo "BRINGUP_RUN_ID=${run_id}"
    echo "BRINGUP_COMPLETION_SENTINEL=FAIL"
  } | p2b_atomic_write "${d}/completion.sentinel"
  p2b_write_result_env "$run_id" "$worker_pid" "$target" "$started" "$completed" "$rc" "FAIL" "FAILED" "$logf"
  p2b_write_state "FAILED"
  exit "$rc"
}

p2b_read_log_start_offset() {
  local off
  off="$(p2b_read_file "$(p2b_dir)/log-start-offset")"
  if [[ ! "$off" =~ ^[0-9]+$ ]]; then
    printf '0'
    return 0
  fi
  printf '%s' "$off"
}

p2b_current_run_log_marker_line() {
  local run_id="${1:-}"
  [[ -n "$run_id" ]] || run_id="$(p2b_read_file "$(p2b_dir)/run-id")"
  printf 'PHASE2_LIFECYCLE_RUN_BEGIN run_id=%s' "$run_id"
}

p2b_write_current_run_log_marker() {
  local logf="$1"
  local run_id="${2:-}"
  local line
  [[ -n "$run_id" ]] || run_id="$(p2b_read_file "$(p2b_dir)/run-id")"
  if [[ -z "$logf" || -z "$run_id" ]]; then
    return 1
  fi
  if [[ ! "$run_id" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    return 1
  fi
  mkdir -p "$(dirname "$logf")" 2>/dev/null || true
  line="$(p2b_current_run_log_marker_line "$run_id")"
  printf '%s\n' "$line" >>"$logf" || return 1
}

# Offset-scoped bytes only. Does not prove current-run identity.
# Never loads the whole file into memory.
# Return codes:
#   0  offset-scoped view streamed (may be empty if offset==size)
#   1  log file missing
#   2  truncation/rotation: recorded offset is past current size
p2b_current_run_log_offset_stream() {
  local logf="$1"
  local offset="${2:-}"
  local size
  if [[ -z "$offset" ]]; then
    offset="$(p2b_read_log_start_offset)"
  fi
  if [[ ! -f "$logf" ]]; then
    return 1
  fi
  if [[ ! "$offset" =~ ^[0-9]+$ ]]; then
    return 2
  fi
  size="$(wc -c <"$logf" | tr -d ' ')"
  if [[ ! "$size" =~ ^[0-9]+$ ]]; then
    return 2
  fi
  if [[ "$offset" -gt "$size" ]]; then
    return 2
  fi
  # GNU tail -c +N is 1-based: skip the first `offset` bytes.
  tail -c "+$((offset + 1))" "$logf"
  return 0
}

# Drain stdin while searching. grep -q / head close the pipe on the first match
# and can SIGPIPE a still-writing producer; under pipefail that becomes a
# false FAIL on valid current-run evidence. These consumers always read to EOF.
p2b_stdin_has_exact_line() {
  awk -v m="$1" '$0 == m { found = 1 } END { exit found ? 0 : 1 }'
}

p2b_stdin_has_ere() {
  awk -v pat="$1" '$0 ~ pat { found = 1 } END { exit found ? 0 : 1 }'
}

# Current-run evidence is valid only when the active run-id marker exists in
# the offset-scoped stream. Historical pre-offset bytes are never searched.
# Return codes:
#   0  current run-id marker present in scoped stream
#   1  log file missing
#   2  truncation/rotation or invalid offset
#   3  marker missing or belongs to a different run-id
p2b_current_run_log_identity_valid() {
  local logf="$1"
  local run_id="${2:-}"
  local offset="${3:-}"
  local marker prev_e=0 stream_rc=0 grep_rc=0
  [[ -n "$run_id" ]] || run_id="$(p2b_read_file "$(p2b_dir)/run-id")"
  if [[ ! -f "$logf" ]]; then
    return 1
  fi
  if [[ -z "$run_id" || ! "$run_id" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    return 3
  fi
  marker="$(p2b_current_run_log_marker_line "$run_id")"
  [[ $- == *e* ]] && prev_e=1
  set +e
  p2b_current_run_log_offset_stream "$logf" "$offset" >/dev/null
  stream_rc=$?
  if [[ "$stream_rc" -ne 0 ]]; then
    [[ "$prev_e" -eq 1 ]] && set -e
    return "$stream_rc"
  fi
  p2b_current_run_log_offset_stream "$logf" "$offset" | p2b_stdin_has_exact_line "$marker"
  grep_rc=$?
  [[ "$prev_e" -eq 1 ]] && set -e
  if [[ "$grep_rc" -eq 0 ]]; then
    return 0
  fi
  return 3
}

# Stream current-run log bytes only when offset arithmetic and run identity
# are both valid. Never loads the whole file into memory.
# Return codes:
#   0  current-run view streamed
#   1  log file missing
#   2  current-run evidence invalid (truncation/rotation/missing or wrong marker)
p2b_current_run_log_stream() {
  local logf="$1"
  local offset="${2:-}"
  local ident_rc=0 prev_e=0
  [[ $- == *e* ]] && prev_e=1
  set +e
  p2b_current_run_log_identity_valid "$logf" "" "$offset"
  ident_rc=$?
  [[ "$prev_e" -eq 1 ]] && set -e
  if [[ "$ident_rc" -ne 0 ]]; then
    if [[ "$ident_rc" -eq 1 ]]; then
      return 1
    fi
    return 2
  fi
  p2b_current_run_log_offset_stream "$logf" "$offset"
  return 0
}

# Return codes:
#   0  pattern found in a valid current-run stream
#   1  valid current-run stream, pattern absent
#   2  current-run stream invalid (never treat as pattern-absent)
p2b_current_run_log_contains() {
  local logf="$1"
  local pattern="$2"
  local prev_e=0 stream_rc=0 grep_rc=0
  [[ $- == *e* ]] && prev_e=1
  set +e
  p2b_current_run_log_stream "$logf" >/dev/null
  stream_rc=$?
  if [[ "$stream_rc" -ne 0 ]]; then
    [[ "$prev_e" -eq 1 ]] && set -e
    # Missing/truncated/wrong-run evidence is invalid, not "pattern absent".
    return 2
  fi
  p2b_current_run_log_stream "$logf" | p2b_stdin_has_ere "$pattern"
  grep_rc=$?
  [[ "$prev_e" -eq 1 ]] && set -e
  if [[ "$grep_rc" -eq 0 ]]; then
    return 0
  fi
  if [[ "$grep_rc" -eq 1 ]]; then
    return 1
  fi
  return 2
}

# Probe current-run identity. Return codes match p2b_current_run_log_stream:
#   0 valid, nonzero invalid. Callers must not treat nonzero as success.
p2b_require_current_run_log_identity() {
  local logf="$1"
  local prev_e=0 ident_rc=0
  [[ $- == *e* ]] && prev_e=1
  set +e
  p2b_current_run_log_stream "$logf" >/dev/null
  ident_rc=$?
  [[ "$prev_e" -eq 1 ]] && set -e
  return "$ident_rc"
}

# Exact anchored vendor completion line for current run context (optional corroboration).
# Does NOT accept instructional text. Pattern: timestamped "Bringup complete:" at line start
# after optional spaces, not preceded by instructional keywords on same line.
p2b_log_has_anchored_completion() {
  local logf="$1"
  local run_started_epoch="${2:-0}"
  local stream_rc=0 prev_e=0
  [[ -f "$logf" ]] || return 1
  # Prefer machine-readable PHASE2_BRINGUP=COMPLETE written by post notice — still not
  # sufficient alone; lifecycle sentinel is authoritative. This is corroboration only.
  # Historical log bytes before log-start-offset are ignored.
  [[ $- == *e* ]] && prev_e=1
  set +e
  p2b_current_run_log_stream "$logf" >/dev/null
  stream_rc=$?
  [[ "$prev_e" -eq 1 ]] && set -e
  if [[ "$stream_rc" -ne 0 ]]; then
    return 1
  fi
  p2b_current_run_log_stream "$logf" | awk -v since="$run_started_epoch" '
    /^[[:space:]]*\[[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:.]+\][[:space:]]+Bringup complete:/ { found=1 }
    /^[[:space:]]*Bringup complete:[[:space:]]/ {
      # Reject lines that are clearly instructional
      if ($0 ~ /Completes when|run this command|when installation completes|Wait until|shows:/) next
      if ($0 ~ /IMPORTANT|Do NOT|NEXT_COMMAND/) next
      found=1
    }
    END { exit found ? 0 : 1 }
  ' 2>/dev/null
}

p2b_discover_aella_cli() {
  local p
  AELLA_CLI_PATH=""
  AELLA_CLI_AVAILABLE="NO"
  # Clean login-compatible PATH check
  if command -v aella_cli >/dev/null 2>&1; then
    AELLA_CLI_PATH="$(command -v aella_cli)"
    AELLA_CLI_AVAILABLE="YES"
    return 0
  fi
  for p in "${PHASE2_AELLA_CLI_CANDIDATES[@]}"; do
    if [[ -x "$p" ]]; then
      AELLA_CLI_PATH="$p"
      AELLA_CLI_AVAILABLE="YES"
      return 0
    fi
  done
  return 1
}

p2b_parse_image_import_progress() {
  local logf="${1:-${PHASE2_BRINGUP_LOG_DEFAULT}}"
  IMAGE_IMPORT_STATE="UNKNOWN"
  IMAGE_IMPORT_PROGRESS=""
  IMAGE_IMPORT_NAMESPACE=""
  if [[ ! -f "$logf" ]]; then
    return 1
  fi
  # Read last IMAGE_IMPORT_* records — do not invent percentages.
  local line last_prog="" last_ns="" started=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ IMAGE_IMPORT_START ]]; then
      started=1
      IMAGE_IMPORT_STATE="RUNNING"
      if [[ "$line" =~ namespace=([^[:space:]]+) ]]; then
        last_ns="${BASH_REMATCH[1]}"
      fi
    fi
    if [[ "$line" =~ IMAGE_IMPORT_PROGRESS ]]; then
      started=1
      IMAGE_IMPORT_STATE="RUNNING"
      if [[ "$line" =~ progress=([0-9]+%?) ]]; then
        last_prog="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ([0-9]+)% ]]; then
        last_prog="${BASH_REMATCH[1]}%"
      fi
      if [[ "$line" =~ namespace=([^[:space:]]+) ]]; then
        last_ns="${BASH_REMATCH[1]}"
      fi
    fi
    if [[ "$line" =~ IMAGE_IMPORT_END|IMAGE_IMPORT_COMPLETE ]]; then
      IMAGE_IMPORT_STATE="DONE"
    fi
  done <"$logf"
  IMAGE_IMPORT_PROGRESS="$last_prog"
  IMAGE_IMPORT_NAMESPACE="$last_ns"
  if [[ "$started" -eq 1 && "$IMAGE_IMPORT_STATE" == "UNKNOWN" ]]; then
    IMAGE_IMPORT_STATE="RUNNING"
  fi
  return 0
}

p2b_current_phase_from_log() {
  local logf="${1:-${PHASE2_BRINGUP_LOG_DEFAULT}}"
  CURRENT_PHASE="UNKNOWN"
  CURRENT_OPERATION="UNKNOWN"
  [[ -f "$logf" ]] || return 1
  local line
  # Prefer last IMAGE_IMPORT markers; else last conspicuous phase line.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ IMAGE_IMPORT_START ]]; then
      CURRENT_PHASE="IMAGE_IMPORT"
      CURRENT_OPERATION="image_import"
    elif [[ "$line" =~ IMAGE_IMPORT_PROGRESS ]]; then
      CURRENT_PHASE="IMAGE_IMPORT"
      CURRENT_OPERATION="image_import"
    elif [[ "$line" =~ Installing\ Docker|Install\ Docker ]]; then
      CURRENT_PHASE="DOCKER"
      CURRENT_OPERATION="install_docker"
    elif [[ "$line" =~ load_local_images|Loading\ images ]]; then
      CURRENT_PHASE="LOAD_IMAGES"
      CURRENT_OPERATION="load_images"
    fi
  done <"$logf"
}

p2b_status_snapshot() {
  local d pid state run_id started logf alive="NO" identity="NO"
  local result_file result_run_id result_terminal="NO" sentinel="NOT_PRESENT" exit_code="" elapsed=""
  local result_env="" terminal_state=""
  d="$(p2b_dir)"
  state="$(p2b_read_state)"
  [[ -n "$state" ]] || state="NOT_STARTED"
  run_id="$(p2b_read_file "${d}/run-id")"
  pid="$(p2b_read_file "${d}/worker.pid")"
  started="$(p2b_read_file "${d}/started-at")"
  logf="$(p2b_read_file "${d}/log-path")"
  [[ -n "$logf" ]] || logf="${PHASE2_BRINGUP_LOG_DEFAULT}"
  result_file="${d}/result.env"
  exit_code="$(p2b_read_file "${d}/exit-code")"

  if [[ -n "$pid" ]] && p2b_pid_alive_and_matches "$pid" "bringup"; then
    alive="YES"
    identity="YES"
  elif [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    alive="YES"
    identity="NO"
  fi

  if [[ -f "$result_file" ]]; then
    result_run_id="$(grep -E '^BRINGUP_RUN_ID=' "$result_file" 2>/dev/null | head -1 | cut -d= -f2-)"
    # A terminal result belongs only to the active lifecycle run.  A retained
    # result from a previous run must never make the new run look complete.
    if [[ -n "$run_id" && "$result_run_id" != "$run_id" ]]; then
      result_run_id=""
    fi
  fi
  if [[ -f "$result_file" && -n "${result_run_id:-}" ]]; then
    if grep -qE '^BRINGUP_TERMINAL_STATE=(COMPLETED|FAILED)$' "$result_file" 2>/dev/null; then
      result_terminal="YES"
    fi
    terminal_state="$(grep -E '^BRINGUP_TERMINAL_STATE=' "$result_file" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    result_env="$(grep -E '^BRINGUP_RESULT=' "$result_file" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    if grep -qE '^BRINGUP_COMPLETION_SENTINEL=PASS$' "$result_file" 2>/dev/null; then
      sentinel="PASS"
    elif grep -qE '^BRINGUP_COMPLETION_SENTINEL=' "$result_file" 2>/dev/null; then
      sentinel="$(grep -E '^BRINGUP_COMPLETION_SENTINEL=' "$result_file" | head -1 | cut -d= -f2-)"
    fi
    if [[ -z "$exit_code" ]]; then
      exit_code="$(grep -E '^BRINGUP_EXIT_CODE=' "$result_file" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    fi
  fi

  # Stale PID detection
  if [[ "$state" == "RUNNING" || "$state" == "STARTING" ]]; then
    if [[ "$alive" != "YES" || "$identity" != "YES" ]]; then
      if [[ "$result_terminal" != "YES" ]]; then
        state="STALE_OR_UNKNOWN"
      fi
    fi
  fi

  if [[ -n "$started" ]]; then
    local start_epoch now_epoch
    start_epoch="$(date -u -d "$started" +%s 2>/dev/null || true)"
    now_epoch="$(date -u +%s)"
    if [[ -n "$start_epoch" ]]; then
      elapsed=$((now_epoch - start_epoch))
    fi
  fi

  p2b_parse_image_import_progress "$logf" || true
  p2b_current_phase_from_log "$logf" || true

  AELLA_CLI_AVAILABLE="NOT_CHECKED"
  AELLA_CLI_PATH=""
  if [[ "$state" == "COMPLETED" ]] || [[ "$sentinel" == "PASS" ]]; then
    p2b_discover_aella_cli || true
  fi

  BRINGUP_STATE="$state"
  BRINGUP_RUN_ID="$run_id"
  BRINGUP_WORKER_PID="$pid"
  BRINGUP_WORKER_ALIVE="$alive"
  BRINGUP_PROCESS_IDENTITY_MATCH="$identity"
  BRINGUP_STARTED_AT="$started"
  BRINGUP_ELAPSED_SECONDS="${elapsed:-}"
  BRINGUP_COMPLETION_SENTINEL="$sentinel"
  BRINGUP_EXIT_CODE="$exit_code"
  BRINGUP_TERMINAL_STATE="${terminal_state:-}"
  BRINGUP_RESULT_ENV="${result_env:-}"
  BRINGUP_LOG="$logf"
}

# A lifecycle PASS requires a coherent current-run terminal record. A persisted
# state=COMPLETED file is not sufficient by itself.
p2b_current_run_completion_coherent() {
  [[ "${BRINGUP_STATE:-}" == "COMPLETED" ]] || return 1
  [[ -n "${BRINGUP_RUN_ID:-}" ]] || return 1
  [[ "${BRINGUP_TERMINAL_STATE:-}" == "COMPLETED" ]] || return 1
  [[ "${BRINGUP_RESULT_ENV:-}" == "PASS" ]] || return 1
  [[ "${BRINGUP_EXIT_CODE:-}" == "0" ]] || return 1
  [[ "${BRINGUP_COMPLETION_SENTINEL:-}" == "PASS" ]] || return 1
  return 0
}

p2b_print_status() {
  p2b_status_snapshot
  local result="UNKNOWN"
  local do_not="YES"
  case "${BRINGUP_STATE}" in
    RUNNING|STARTING)
      result="IN_PROGRESS"
      do_not="YES"
      AELLA_CLI_AVAILABLE="${AELLA_CLI_AVAILABLE:-NOT_CHECKED}"
      ;;
    COMPLETED)
      if p2b_current_run_completion_coherent \
        && [[ "${AELLA_CLI_AVAILABLE}" == "YES" ]]; then
        result="PASS"
        do_not="NO"
      elif p2b_current_run_completion_coherent; then
        result="FAIL_POSTCONDITION"
        do_not="NO"
      else
        result="FAIL_INCONSISTENT_STATE"
        do_not="YES"
      fi
      ;;
    FAILED|STALE_OR_UNKNOWN)
      result="FAIL"
      do_not="YES"
      ;;
    NOT_STARTED)
      result="NOT_STARTED"
      do_not="YES"
      ;;
  esac
  BRINGUP_RESULT="$result"
  cat <<EOF
BRINGUP_STATE=${BRINGUP_STATE}
BRINGUP_RESULT=${BRINGUP_RESULT}
BRINGUP_RUN_ID=${BRINGUP_RUN_ID}
BRINGUP_WORKER_PID=${BRINGUP_WORKER_PID}
BRINGUP_WORKER_ALIVE=${BRINGUP_WORKER_ALIVE}
BRINGUP_PROCESS_IDENTITY_MATCH=${BRINGUP_PROCESS_IDENTITY_MATCH}
BRINGUP_STARTED_AT=${BRINGUP_STARTED_AT}
BRINGUP_ELAPSED_SECONDS=${BRINGUP_ELAPSED_SECONDS}
BRINGUP_COMPLETION_SENTINEL=${BRINGUP_COMPLETION_SENTINEL}
BRINGUP_EXIT_CODE=${BRINGUP_EXIT_CODE}
CURRENT_PHASE=${CURRENT_PHASE:-UNKNOWN}
CURRENT_OPERATION=${CURRENT_OPERATION:-UNKNOWN}
IMAGE_IMPORT_STATE=${IMAGE_IMPORT_STATE:-UNKNOWN}
IMAGE_IMPORT_PROGRESS=${IMAGE_IMPORT_PROGRESS:-}
AELLA_CLI_AVAILABLE=${AELLA_CLI_AVAILABLE}
AELLA_CLI_PATH=${AELLA_CLI_PATH:-}
AELLA_CLI_READY=$([ "$do_not" = YES ] && echo NO || echo YES)
DO_NOT_RUN_AELLA_CLI_YET=${do_not}
BRINGUP_LOG=${BRINGUP_LOG}
EOF
}

p2b_archive_failed_run() {
  local d dest f
  d="$(p2b_dir)"
  dest="${d}/previous-failed"
  rm -rf "$dest"
  mkdir -p "$dest"
  chmod 0700 "$dest" 2>/dev/null || true
  for f in state result.env completion.sentinel run-id exit-code \
    completed-at started-at log-path worker.pid worker-start-ticks target-version \
    log-start-offset
  do
    if [[ -f "${d}/${f}" ]]; then
      cp -a "${d}/${f}" "${dest}/${f}" 2>/dev/null || true
    fi
  done
}

p2b_acquire_lock() {
  local d lockfd
  d="$(p2b_dir)"
  p2b_ensure_dir
  exec {lockfd}>"${d}/lock"
  if ! flock -n "$lockfd"; then
    eval "exec ${lockfd}>&-" 2>/dev/null || true
    return 1
  fi
  P2B_LOCK_FD="$lockfd"
  return 0
}

p2b_release_lock() {
  if [[ -n "${P2B_LOCK_FD:-}" ]]; then
    flock -u "$P2B_LOCK_FD" 2>/dev/null || true
    eval "exec ${P2B_LOCK_FD}>&-" 2>/dev/null || true
    P2B_LOCK_FD=""
  fi
}

# Worker body: run vendor script, write exact completion sentinel.
p2b_worker_main() {
  local vendor="$1"
  shift
  local d run_id target logf started completed rc=0 start_tick
  local marker_rc=0 current_log_rc=0 apt_log_rc=0 orch_fail_rc=0
  local orch_pass_rc=0 final_log_rc=0
  d="$(p2b_dir)"
  run_id="$(p2b_read_file "${d}/run-id")"
  target="$(p2b_read_file "${d}/target-version")"
  logf="$(p2b_read_file "${d}/log-path")"
  [[ -n "$logf" ]] || logf="${PHASE2_BRINGUP_LOG_DEFAULT}"
  started="$(p2b_read_file "${d}/started-at")"
  mkdir -p "$(dirname "$logf")" 2>/dev/null || true

  # Record log byte offset so completion markers can be scoped to this run.
  if [[ -f "$logf" ]]; then
    printf '%s\n' "$(wc -c <"$logf" | tr -d ' ')" | p2b_atomic_write "${d}/log-start-offset"
  else
    printf '0\n' | p2b_atomic_write "${d}/log-start-offset"
  fi
  # Identity marker lives in the current-run stream (after the recorded offset).
  # Secondary log gates must not accept a later truncated/regrown file as the
  # same stream if this marker is gone. This is not a completion sentinel.
  # Marker write is mandatory: do not start vendor bringup without it.
  prev_e=0
  [[ $- == *e* ]] && prev_e=1
  set +e
  p2b_write_current_run_log_marker "$logf" "$run_id"
  marker_rc=$?
  [[ "$prev_e" -eq 1 ]] && set -e
  if [[ "$marker_rc" -ne 0 ]]; then
    rc=1
    p2b_fail_run "$d" "$run_id" "$$" "$target" "$started" "$logf" "$rc" "CURRENT_RUN_LOG_MARKER_WRITE"
  fi
  p2b_write_state "RUNNING"
  printf '%s\n' "$$" | p2b_atomic_write "${d}/worker.pid"
  if [[ -r /proc/$$/stat ]]; then
    start_tick="$(awk '{print $22}' /proc/$$/stat)"
    printf '%s\n' "$start_tick" | p2b_atomic_write "${d}/worker-start-ticks"
  fi

  export BRINGUP_DETACHED=1
  export BRINGUP_LIFECYCLE_MANAGED=1

  # Offline Ubuntu prerequisites before vendor Phase 2 (ACPS artifacts untouched).
  local prereq_lib
  for prereq_lib in \
    "${d}/lib/dp-phase2-ubuntu-prerequisites.sh" \
    "${LIB_DIR:-}/dp-phase2-ubuntu-prerequisites.sh" \
    "/home/aella/lib/dp-phase2-ubuntu-prerequisites.sh"
  do
    if [[ -f "$prereq_lib" ]]; then
      # shellcheck source=/dev/null
      source "$prereq_lib"
      if declare -F dp2_install_phase2_ubuntu_prerequisites >/dev/null 2>&1; then
        prev_e=0
        [[ $- == *e* ]] && prev_e=1
        set +e
        dp2_install_phase2_ubuntu_prerequisites >>"$logf" 2>&1
        rc=$?
        [[ "$prev_e" -eq 1 ]] && set -e
        if [[ "$rc" -ne 0 ]]; then
          completed="$(p2b_utc_now)"
          printf '%s\n' "$rc" | p2b_atomic_write "${d}/exit-code"
          printf '%s\n' "$completed" | p2b_atomic_write "${d}/completed-at"
          {
            echo "BRINGUP_TERMINAL_STATE=FAILED"
            echo "BRINGUP_RESULT=FAIL"
            echo "FAILURE_REASON=PHASE2_PREREQ_INSTALL"
            echo "BRINGUP_EXIT_CODE=${rc}"
            echo "BRINGUP_RUN_ID=${run_id}"
            echo "BRINGUP_COMPLETION_SENTINEL=FAIL"
          } | p2b_atomic_write "${d}/completion.sentinel"
          p2b_write_result_env "$run_id" "$$" "$target" "$started" "$completed" "$rc" "FAIL" "FAILED" "$logf"
          p2b_write_state "FAILED"
          exit "$rc"
        fi
      fi
      break
    fi
  done

  prev_e=0
  [[ $- == *e* ]] && prev_e=1
  set +e
  # Keep vendor stdout discarded; stderr+log via vendor's own logging when possible.
  bash "$vendor" "$@" >>"$logf" 2>&1
  rc=$?
  [[ "$prev_e" -eq 1 ]] && set -e

  completed="$(p2b_utc_now)"
  printf '%s\n' "$rc" | p2b_atomic_write "${d}/exit-code"
  printf '%s\n' "$completed" | p2b_atomic_write "${d}/completed-at"

  if [[ "$rc" -eq 0 ]]; then
    # Current-run log identity is a mandatory prerequisite for any secondary
    # log-based PASS decision. Invalid evidence is not "pattern absent".
    prev_e=0
    [[ $- == *e* ]] && prev_e=1
    set +e
    p2b_require_current_run_log_identity "$logf"
    current_log_rc=$?
    [[ "$prev_e" -eq 1 ]] && set -e
    if [[ "$current_log_rc" -ne 0 ]]; then
      rc=1
      p2b_fail_run "$d" "$run_id" "$$" "$target" "$started" "$logf" "$rc" "CURRENT_RUN_LOG_IDENTITY_INVALID"
    fi

    # Remote orchestration runs cannot become PASS unless the vendor recorded
    # WORKER_ORCHESTRATION=PASS. Per-target hostname Ready validation in the
    # vendor script is authoritative; global Ready-count equality is not.
    local want_remote=""
    local arg next=""
    for arg in "$@"; do
      if [[ -n "$next" ]]; then
        want_remote="$arg"
        next=""
        continue
      fi
      if [[ "$arg" == "--worker-ips" || "$arg" == "--standby" ]]; then
        next=1
      fi
    done
    prev_e=0
    [[ $- == *e* ]] && prev_e=1
    set +e
    p2b_current_run_log_contains "$logf" 'APT_DEPENDENCY_CHECK=FAIL'
    apt_log_rc=$?
    [[ "$prev_e" -eq 1 ]] && set -e
    case "$apt_log_rc" in
      0)
        rc=1
        p2b_fail_run "$d" "$run_id" "$$" "$target" "$started" "$logf" "$rc" "APT_DEPENDENCY_CHECK"
        ;;
      1)
        ;;
      *)
        rc=1
        p2b_fail_run "$d" "$run_id" "$$" "$target" "$started" "$logf" "$rc" "CURRENT_RUN_LOG_IDENTITY_INVALID"
        ;;
    esac
    prev_e=0
    [[ $- == *e* ]] && prev_e=1
    set +e
    p2b_current_run_log_contains "$logf" 'WORKER_ORCHESTRATION=FAIL'
    orch_fail_rc=$?
    [[ "$prev_e" -eq 1 ]] && set -e
    case "$orch_fail_rc" in
      0)
        rc=1
        p2b_fail_run "$d" "$run_id" "$$" "$target" "$started" "$logf" "$rc" "WORKER_ORCHESTRATION"
        ;;
      1)
        ;;
      *)
        rc=1
        p2b_fail_run "$d" "$run_id" "$$" "$target" "$started" "$logf" "$rc" "CURRENT_RUN_LOG_IDENTITY_INVALID"
        ;;
    esac
    if [[ -n "$want_remote" ]]; then
      prev_e=0
      [[ $- == *e* ]] && prev_e=1
      set +e
      p2b_current_run_log_contains "$logf" 'WORKER_ORCHESTRATION=PASS'
      orch_pass_rc=$?
      [[ "$prev_e" -eq 1 ]] && set -e
      case "$orch_pass_rc" in
        0)
          ;;
        1)
          rc=1
          p2b_fail_run "$d" "$run_id" "$$" "$target" "$started" "$logf" "$rc" "WORKER_ORCHESTRATION"
          ;;
        *)
          rc=1
          p2b_fail_run "$d" "$run_id" "$$" "$target" "$started" "$logf" "$rc" "CURRENT_RUN_LOG_IDENTITY_INVALID"
          ;;
      esac
    fi
    # Identity may change after the last secondary check (copytruncate). AIO
    # and cluster both require a final valid current-run stream before PASS.
    prev_e=0
    [[ $- == *e* ]] && prev_e=1
    set +e
    p2b_require_current_run_log_identity "$logf"
    final_log_rc=$?
    [[ "$prev_e" -eq 1 ]] && set -e
    if [[ "$final_log_rc" -ne 0 ]]; then
      rc=1
      p2b_fail_run "$d" "$run_id" "$$" "$target" "$started" "$logf" "$rc" "CURRENT_RUN_LOG_IDENTITY_INVALID"
    fi
    # Write machine-readable sentinel bound to this run — authoritative completion.
    {
      echo "BRINGUP_TERMINAL_STATE=COMPLETED"
      echo "BRINGUP_RESULT=PASS"
      echo "BRINGUP_COMPLETED_AT=${completed}"
      echo "BRINGUP_EXIT_CODE=0"
      echo "BRINGUP_RUN_ID=${run_id}"
      echo "BRINGUP_WORKER_PID=$$"
      echo "BRINGUP_TARGET_VERSION=${target}"
      echo "BRINGUP_STARTED_AT=${started}"
      echo "BRINGUP_LOG_PATH=${logf}"
      echo "BRINGUP_COMPLETION_SENTINEL=PASS"
    } | p2b_atomic_write "${d}/completion.sentinel"

    p2b_write_result_env "$run_id" "$$" "$target" "$started" "$completed" 0 "PASS" "COMPLETED" "$logf"
    p2b_write_state "COMPLETED"
    # Postcondition CLI check is performed by monitor/status, not here alone.
  else
    {
      echo "BRINGUP_TERMINAL_STATE=FAILED"
      echo "BRINGUP_RESULT=FAIL"
      echo "BRINGUP_COMPLETED_AT=${completed}"
      echo "BRINGUP_EXIT_CODE=${rc}"
      echo "BRINGUP_RUN_ID=${run_id}"
      echo "BRINGUP_WORKER_PID=$$"
      echo "BRINGUP_TARGET_VERSION=${target}"
      echo "BRINGUP_STARTED_AT=${started}"
      echo "BRINGUP_LOG_PATH=${logf}"
      echo "BRINGUP_COMPLETION_SENTINEL=FAIL"
    } | p2b_atomic_write "${d}/completion.sentinel"
    p2b_write_result_env "$run_id" "$$" "$target" "$started" "$completed" "$rc" "FAIL" "FAILED" "$logf"
    p2b_write_state "FAILED"
  fi
  exit "$rc"
}

p2b_emit_handoff() {
  local run_id="$1" pid="$2" logf="$3"
  cat <<EOF
BRINGUP_HANDOFF=PASS
BRINGUP_STATE=RUNNING
BRINGUP_RUN_ID=${run_id}
BRINGUP_WORKER_PID=${pid}
BRINGUP_LOG=${logf}
BRINGUP_MONITOR_MODE=FOREGROUND_READ_ONLY
BRINGUP_SURVIVES_SSH_DISCONNECT=YES
AELLA_CLI_READY=NO
AELLA_CLI_AVAILABLE=NOT_CHECKED
DO_NOT_RUN_AELLA_CLI_YET=YES
EOF
}

p2b_monitor_loop() {
  local run_id="$1"
  local d pid logf state start_epoch now elapsed last_log_age
  local monitor_stopped=0
  d="$(p2b_dir)"
  logf="$(p2b_read_file "${d}/log-path")"
  [[ -n "$logf" ]] || logf="${PHASE2_BRINGUP_LOG_DEFAULT}"

  trap 'monitor_stopped=1' INT TERM

  while true; do
    if [[ "$monitor_stopped" -eq 1 ]]; then
      cat <<EOF
BRINGUP_MONITOR_STOPPED=YES
BRINGUP_WORKER_CONTINUES=YES
BRINGUP_STATUS_COMMAND=sudo bash ${P2B_WRAPPER_PATH:-/home/aella/bringup_py3_dp_after_os_upgrade.sh} --status
BRINGUP_LOG_COMMAND=sudo tail -n 100 ${logf}
EOF
      return 130
    fi

    p2b_status_snapshot
    state="${BRINGUP_STATE}"
    pid="${BRINGUP_WORKER_PID}"
    elapsed="${BRINGUP_ELAPSED_SECONDS:-0}"
    last_log_age="UNKNOWN"
    if [[ -f "$logf" ]]; then
      local mtime now_e
      mtime="$(stat -c %Y "$logf" 2>/dev/null || echo 0)"
      now_e="$(date -u +%s)"
      last_log_age=$((now_e - mtime))
    fi

    if p2b_current_run_completion_coherent; then
      # Verified completion — check CLI postcondition
      AELLA_CLI_AVAILABLE="NO"
      AELLA_CLI_PATH=""
      if p2b_discover_aella_cli; then
        cat <<EOF
BRINGUP_PROGRESS run_id=${run_id} state=COMPLETED elapsed_seconds=${elapsed} worker=GONE last_log_age_seconds=${last_log_age} current_phase=COMPLETE current_operation=done
BRINGUP_RESULT=PASS
BRINGUP_STATE=COMPLETED
BRINGUP_COMPLETION_SENTINEL=PASS
BRINGUP_EXIT_CODE=0
AELLA_CLI_AVAILABLE=YES
AELLA_CLI_PATH=${AELLA_CLI_PATH}
AELLA_CLI_READY=YES
DO_NOT_RUN_AELLA_CLI_YET=NO
NEXT_COMMAND=sudo ${AELLA_CLI_PATH}

After bringup completes, run:
  sudo ${AELLA_CLI_PATH}

Then inside the CLI:
  show status

If the status contains:
  System paused. Type resume in cli to start data processor services

then run:
  resume
  show status

DP_RESUME_AUTOMATIC=NO
EOF
        return 0
      fi
      p2b_write_state "FAILED"
      {
        echo "BRINGUP_TERMINAL_STATE=FAILED"
        echo "BRINGUP_RESULT=FAIL_POSTCONDITION"
        echo "FAILURE_REASON=AELLA_CLI_MISSING_AFTER_BRINGUP_COMPLETE"
        echo "BRINGUP_RUN_ID=${run_id}"
      } | p2b_atomic_write "${d}/result.env"
      cat <<EOF
BRINGUP_RESULT=FAIL_POSTCONDITION
BRINGUP_STATE=FAILED
AELLA_CLI_AVAILABLE=NO
FAILURE_REASON=AELLA_CLI_MISSING_AFTER_BRINGUP_COMPLETE
EXPECTED_PACKAGE_STATUS=aella_cli not found in PATH or known install paths
NEXT_ACTION=Review the current run's bringup log and installed UVP package
EOF
      return 1
    fi

    if [[ "$state" == "COMPLETED" ]]; then
      cat <<EOF
BRINGUP_PROGRESS run_id=${run_id} state=COMPLETED elapsed_seconds=${elapsed} worker=${BRINGUP_WORKER_ALIVE} last_log_age_seconds=${last_log_age} current_phase=${CURRENT_PHASE:-UNKNOWN} current_operation=${CURRENT_OPERATION:-UNKNOWN}
BRINGUP_RESULT=FAIL_INCONSISTENT_STATE
BRINGUP_STATE=COMPLETED
BRINGUP_COMPLETION_SENTINEL=${BRINGUP_COMPLETION_SENTINEL}
BRINGUP_EXIT_CODE=${BRINGUP_EXIT_CODE}
AELLA_CLI_AVAILABLE=NOT_CHECKED
DO_NOT_RUN_AELLA_CLI_YET=YES
FAILURE_REASON=INCONSISTENT_COMPLETION_RECORD
EOF
      return 1
    fi

    if [[ "$state" == "FAILED" ]]; then
      cat <<EOF
BRINGUP_PROGRESS run_id=${run_id} state=FAILED elapsed_seconds=${elapsed} worker=${BRINGUP_WORKER_ALIVE} last_log_age_seconds=${last_log_age} current_phase=${CURRENT_PHASE:-UNKNOWN} current_operation=${CURRENT_OPERATION:-UNKNOWN}
BRINGUP_RESULT=FAIL
BRINGUP_STATE=FAILED
BRINGUP_COMPLETION_SENTINEL=${BRINGUP_COMPLETION_SENTINEL}
BRINGUP_EXIT_CODE=${BRINGUP_EXIT_CODE}
AELLA_CLI_AVAILABLE=NOT_CHECKED
DO_NOT_RUN_AELLA_CLI_YET=YES
EOF
      return 1
    fi

    if [[ "$state" == "STALE_OR_UNKNOWN" ]]; then
      cat <<EOF
BRINGUP_PROGRESS run_id=${run_id} state=STALE_OR_UNKNOWN elapsed_seconds=${elapsed} worker=GONE last_log_age_seconds=${last_log_age} current_phase=${CURRENT_PHASE:-UNKNOWN} current_operation=${CURRENT_OPERATION:-UNKNOWN}
BRINGUP_RESULT=FAIL
BRINGUP_STATE=STALE_OR_UNKNOWN
FAILURE_REASON=STALE_PID_OR_MISSING_TERMINAL_RESULT
AELLA_CLI_AVAILABLE=NOT_CHECKED
DO_NOT_RUN_AELLA_CLI_YET=YES
EOF
      return 1
    fi

    # Still running
    local worker_flag="GONE"
    [[ "${BRINGUP_WORKER_ALIVE}" == "YES" && "${BRINGUP_PROCESS_IDENTITY_MATCH}" == "YES" ]] && worker_flag="ALIVE"
    cat <<EOF
BRINGUP_PROGRESS run_id=${run_id} state=RUNNING elapsed_seconds=${elapsed} worker=${worker_flag} last_log_age_seconds=${last_log_age} current_phase=${CURRENT_PHASE:-UNKNOWN} current_operation=${CURRENT_OPERATION:-UNKNOWN}
BRINGUP_RESULT=IN_PROGRESS
AELLA_CLI_AVAILABLE=NOT_CHECKED
AELLA_CLI_READY=NO
DO_NOT_RUN_AELLA_CLI_YET=YES
EOF
    if [[ "${IMAGE_IMPORT_STATE:-}" == "RUNNING" || -n "${IMAGE_IMPORT_PROGRESS:-}" ]]; then
      cat <<EOF
IMAGE_IMPORT_PROGRESS namespace=${IMAGE_IMPORT_NAMESPACE:-UNKNOWN} progress=${IMAGE_IMPORT_PROGRESS:-UNKNOWN} process_alive=${worker_flag}
IMAGE_IMPORT_STATE=${IMAGE_IMPORT_STATE:-RUNNING}
EOF
    fi

    sleep "${PHASE2_BRINGUP_MONITOR_SECONDS}"
  done
}
