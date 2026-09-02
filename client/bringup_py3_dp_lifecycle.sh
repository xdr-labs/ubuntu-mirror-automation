#!/usr/bin/env bash
# Lifecycle wrapper around vendor bringup_py3_dp_after_os_upgrade.sh.
# Default: start detached worker (SSH-safe) and attach foreground read-only monitor.
# --detach: return after verified handoff. --status/--diagnose: read-only.
set -euo pipefail
set +x

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P2B_WRAPPER_PATH="${SCRIPT_DIR}/${SCRIPT_NAME}"

# Resolve vendor script: prefer sibling .vendor.sh installed by stage-dp-phase2.
VENDOR_BRINGUP="${BRINGUP_VENDOR_SCRIPT:-}"
if [[ -z "$VENDOR_BRINGUP" ]]; then
  if [[ -f "${SCRIPT_DIR}/bringup_py3_dp_after_os_upgrade.vendor.sh" ]]; then
    VENDOR_BRINGUP="${SCRIPT_DIR}/bringup_py3_dp_after_os_upgrade.vendor.sh"
  elif [[ -f "${SCRIPT_DIR}/.bringup_vendor.sh" ]]; then
    VENDOR_BRINGUP="${SCRIPT_DIR}/.bringup_vendor.sh"
  else
    # When this file IS the vendor (legacy), refuse to recurse — require vendor sibling.
    VENDOR_BRINGUP=""
  fi
fi

LIB_DIR="${SCRIPT_DIR}/lib"
if [[ ! -f "${LIB_DIR}/dp-phase2-bringup-lifecycle.sh" ]]; then
  # stage installs libs under /opt or beside wrapper
  for cand in \
    /opt/aelladata/os-upgrade/offline/phase2-bringup/lib \
    /home/aella/ubuntu-mirror-automation/client/lib \
    "${SCRIPT_DIR}/../lib"
  do
    if [[ -f "${cand}/dp-phase2-bringup-lifecycle.sh" ]]; then
      LIB_DIR="$cand"
      break
    fi
  done
fi

# shellcheck source=/dev/null
source "${LIB_DIR}/dp-phase2-bringup-lifecycle.sh"

ATTACH_MONITOR=1
STATUS_ONLY=0
DIAGNOSE_ONLY=0
WORKER_MODE=0
TARGET_VERSION=""
WORKER_PASSWORD_FILE=""
PASSTHRU=()

p2b_store_worker_password() {
  local pw="$1"
  local d f
  d="$(p2b_dir)"
  p2b_ensure_dir
  f="${d}/worker-password"
  printf '%s' "$pw" | p2b_atomic_write "$f" || return 1
  WORKER_PASSWORD_FILE="$f"
  return 0
}

p2b_append_worker_password_file_passthru() {
  [[ -n "${WORKER_PASSWORD_FILE:-}" ]] || return 0
  PASSTHRU+=("--worker-password-file" "$WORKER_PASSWORD_FILE")
}

usage() {
  cat <<EOF
Usage: sudo bash ${SCRIPT_NAME} --version X.Y.Z [options] [-- vendor-args...]

Detached Phase 2 bringup with authoritative lifecycle state and foreground monitor.

Options:
  --version VER       Target DP version (required for start)
  --skip-download     Passed through to vendor bringup
  --worker-ips IPS    Passed through to vendor bringup
  --worker-password PW
                      Legacy: password migrated to a private lifecycle file
                      (not passed on argv). If PW begins with --, use
                      --worker-password=PW so it cannot be parsed as a
                      lifecycle control option.
  --worker-password-file PATH
                      Mode-0600 password file (production path; passed through)
  --standby IPS       Passed through to vendor bringup
  --detach            Return immediately after verified worker handoff
  --status            Read-only lifecycle status
  --diagnose          Read-only diagnostics (status + log tail + markers)
  --worker-mode       Internal: run as lifecycle worker (do not use interactively)
  -h, --help          Show help

Default interactive behavior:
  start detached worker (survives SSH disconnect) + attach read-only monitor.
  Ctrl+C stops the monitor only; the worker continues.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        TARGET_VERSION="${2:-}"
        [[ -n "$TARGET_VERSION" ]] || { echo "ERROR: --version requires a value" >&2; exit 1; }
        PASSTHRU+=("$1" "$2")
        shift 2
        ;;
      --detach)
        ATTACH_MONITOR=0
        shift
        ;;
      --status)
        STATUS_ONLY=1
        shift
        ;;
      --diagnose)
        DIAGNOSE_ONLY=1
        shift
        ;;
      --worker-mode|--lifecycle-worker)
        WORKER_MODE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --worker-password=*)
        local worker_password_value="${1#*=}"
        if [[ -z "$worker_password_value" ]]; then
          echo "ERROR: --worker-password requires a value" >&2
          exit 1
        fi
        p2b_store_worker_password "$worker_password_value" \
          || { echo "ERROR: could not store worker password file" >&2; exit 1; }
        shift
        ;;
      --worker-password-file=*)
        WORKER_PASSWORD_FILE="${1#*=}"
        if [[ -z "$WORKER_PASSWORD_FILE" ]]; then
          echo "ERROR: --worker-password-file requires a path" >&2
          exit 1
        fi
        PASSTHRU+=("--worker-password-file" "$WORKER_PASSWORD_FILE")
        shift
        ;;
      --skip-download|--worker-ips|--worker-password|--worker-password-file|--dry-run|--standby)
        if [[ "$1" == "--worker-password" ]]; then
          if [[ $# -lt 2 || -z "${2:-}" || "$2" == --* ]]; then
            echo "ERROR: $1 requires a value (use --worker-password=VALUE when VALUE begins with --)" >&2
            exit 1
          fi
          p2b_store_worker_password "$2" \
            || { echo "ERROR: could not store worker password file" >&2; exit 1; }
          shift 2
        elif [[ "$1" == "--worker-password-file" ]]; then
          if [[ $# -lt 2 || -z "${2:-}" || "$2" == --* ]]; then
            echo "ERROR: $1 requires a path" >&2
            exit 1
          fi
          WORKER_PASSWORD_FILE="$2"
          PASSTHRU+=("--worker-password-file" "$2")
          shift 2
        elif [[ "$1" == "--worker-ips" || "$1" == "--standby" ]]; then
          if [[ $# -lt 2 || -z "${2:-}" || "$2" == --* ]]; then
            echo "ERROR: $1 requires a value" >&2
            exit 1
          fi
          PASSTHRU+=("$1" "$2")
          shift 2
        else
          PASSTHRU+=("$1")
          shift
        fi
        ;;
      *)
        PASSTHRU+=("$1")
        shift
        ;;
    esac
  done
  p2b_append_worker_password_file_passthru
}

print_diagnose() {
  p2b_print_status
  local d logf
  d="$(p2b_dir)"
  logf="${BRINGUP_LOG:-${PHASE2_BRINGUP_LOG_DEFAULT}}"
  echo "--- LIFECYCLE_FILES ---"
  ls -la "$d" 2>/dev/null || echo "LIFECYCLE_DIR_MISSING"
  echo "--- RESULT_ENV ---"
  if [[ -f "${d}/result.env" ]]; then
    cat "${d}/result.env"
  else
    echo "RESULT_ENV=MISSING"
  fi
  echo "--- COMPLETION_SENTINEL_FILE ---"
  if [[ -f "${d}/completion.sentinel" ]]; then
    cat "${d}/completion.sentinel"
  else
    echo "COMPLETION_SENTINEL_FILE=MISSING"
  fi
  echo "--- TERMINAL_MARKERS_CURRENT_RUN ---"
  if [[ -f "$logf" ]]; then
    # Exact markers only — never unanchored 'Bringup complete:' alone
    grep -nE '^(BRINGUP_TERMINAL_STATE=|BRINGUP_RESULT=|PHASE2_BRINGUP=COMPLETE|IMAGE_IMPORT_|ERROR|FAILED|FATAL|Traceback)' "$logf" \
      | tail -n 40 || true
  fi
  echo "--- LOG_TAIL ---"
  if [[ -f "$logf" ]]; then
    tail -n 40 "$logf" || true
  fi
  echo "--- EXPECTED_CLI_PATHS ---"
  local p
  for p in "${PHASE2_AELLA_CLI_CANDIDATES[@]}"; do
    if [[ -e "$p" ]]; then
      echo "CLI_CANDIDATE=${p} exists=YES"
    else
      echo "CLI_CANDIDATE=${p} exists=NO"
    fi
  done
  if command -v dpkg >/dev/null 2>&1; then
    echo "--- PACKAGE_STATUS ---"
    dpkg -l 'aella-uvp*' 2>/dev/null | tail -n 5 || echo "PACKAGE_STATUS=UNAVAILABLE"
  fi
  echo "DIAGNOSE_MUTATION=NO"
  echo "DIAGNOSE_SIGNALS_SENT=NO"
}

start_or_monitor() {
  local d run_id pid logf started
  d="$(p2b_dir)"
  logf="${PHASE2_BRINGUP_LOG_DEFAULT}"

  if [[ -z "$VENDOR_BRINGUP" || ! -f "$VENDOR_BRINGUP" ]]; then
    echo "ERROR: vendor bringup script not found (expected bringup_py3_dp_after_os_upgrade.vendor.sh beside wrapper)" >&2
    exit 1
  fi

  if ! p2b_acquire_lock; then
    echo "ERROR: could not acquire bringup lifecycle lock" >&2
    exit 1
  fi
  trap 'p2b_release_lock' EXIT

  p2b_status_snapshot
  if [[ "${BRINGUP_STATE}" == "RUNNING" || "${BRINGUP_STATE}" == "STARTING" ]] \
    && [[ "${BRINGUP_WORKER_ALIVE}" == "YES" && "${BRINGUP_PROCESS_IDENTITY_MATCH}" == "YES" ]]; then
    echo "BRINGUP_ALREADY_RUNNING=YES"
    echo "ACTION=MONITOR_EXISTING"
    echo "BRINGUP_WORKER_PID=${BRINGUP_WORKER_PID}"
    echo "BRINGUP_RUN_ID=${BRINGUP_RUN_ID}"
    p2b_release_lock
    trap - EXIT
    if [[ "$ATTACH_MONITOR" -eq 1 ]]; then
      p2b_emit_handoff "${BRINGUP_RUN_ID}" "${BRINGUP_WORKER_PID}" "${BRINGUP_LOG}"
      p2b_monitor_loop "${BRINGUP_RUN_ID}"
      return $?
    fi
    return 0
  fi

  if p2b_current_run_completion_coherent; then
    echo "BRINGUP_ALREADY_COMPLETED=YES"
    p2b_print_status
    if p2b_discover_aella_cli; then
      echo "AELLA_CLI_AVAILABLE=YES"
      echo "AELLA_CLI_PATH=${AELLA_CLI_PATH}"
      echo "NEXT_COMMAND=sudo ${AELLA_CLI_PATH}"
    fi
    return 0
  fi

  if [[ "${BRINGUP_STATE}" == "FAILED" ]]; then
    if [[ "${BRINGUP_WORKER_ALIVE}" == "YES" && "${BRINGUP_PROCESS_IDENTITY_MATCH}" == "YES" ]]; then
      echo "BRINGUP_ALREADY_RUNNING=YES"
      echo "ACTION=MONITOR_EXISTING"
      echo "BRINGUP_WORKER_PID=${BRINGUP_WORKER_PID}"
      echo "BRINGUP_RUN_ID=${BRINGUP_RUN_ID}"
      p2b_release_lock
      trap - EXIT
      if [[ "$ATTACH_MONITOR" -eq 1 ]]; then
        p2b_emit_handoff "${BRINGUP_RUN_ID}" "${BRINGUP_WORKER_PID}" "${BRINGUP_LOG}"
        p2b_monitor_loop "${BRINGUP_RUN_ID}"
        return $?
      fi
      return 0
    fi
    echo "BRINGUP_PREVIOUS_FAILED=YES"
    echo "ACTION=RETRY"
    echo "BRINGUP_RETRY=YES"
    echo "BRINGUP_PREVIOUS_RUN_ID=${BRINGUP_RUN_ID}"
    p2b_archive_failed_run
    echo "BRINGUP_PREVIOUS_FAILED_ARCHIVED=$(p2b_dir)/previous-failed"
  fi

  [[ -n "$TARGET_VERSION" ]] || { echo "ERROR: --version is required to start bringup" >&2; exit 1; }

  run_id="$(p2b_new_run_id)"
  started="$(p2b_utc_now)"
  p2b_ensure_dir
  # Install lifecycle libs for worker re-exec
  mkdir -p "${d}/lib"
  cp -a "${LIB_DIR}/dp-phase2-bringup-lifecycle.sh" "${d}/lib/" 2>/dev/null || true
  if [[ -f "${LIB_DIR}/dp-phase2-ubuntu-prerequisites.sh" ]]; then
    cp -a "${LIB_DIR}/dp-phase2-ubuntu-prerequisites.sh" "${d}/lib/" 2>/dev/null || true
  fi
  chmod 0700 "$d" "${d}/lib" 2>/dev/null || true

  printf '%s\n' "$run_id" | p2b_atomic_write "${d}/run-id"
  printf '%s\n' "$TARGET_VERSION" | p2b_atomic_write "${d}/target-version"
  printf '%s\n' "$logf" | p2b_atomic_write "${d}/log-path"
  printf '%s\n' "$started" | p2b_atomic_write "${d}/started-at"
  rm -f "${d}/completed-at" "${d}/exit-code" "${d}/completion.sentinel" "${d}/result.env" 2>/dev/null || true
  p2b_write_state "STARTING"

  mkdir -p "$(dirname "$logf")" 2>/dev/null || true
  # Detach worker: new session, survives SSH. Worker re-enters this script with --worker-mode.
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$P2B_WRAPPER_PATH" --worker-mode --version "$TARGET_VERSION" "${PASSTHRU[@]}" \
      </dev/null >/dev/null 2>>"$logf" &
  else
    nohup bash "$P2B_WRAPPER_PATH" --worker-mode --version "$TARGET_VERSION" "${PASSTHRU[@]}" \
      </dev/null >/dev/null 2>>"$logf" &
  fi
  pid=$!
  # setsid background pid may be the setsid parent; wait briefly and re-read worker.pid
  sleep 1
  local recorded
  recorded="$(p2b_read_file "${d}/worker.pid")"
  if [[ -n "$recorded" ]]; then
    pid="$recorded"
  fi
  # Verify worker
  local tries=0
  while [[ "$tries" -lt 10 ]]; do
    if p2b_pid_alive_and_matches "$pid" "bringup"; then
      break
    fi
    recorded="$(p2b_read_file "${d}/worker.pid")"
    if [[ -n "$recorded" ]]; then
      pid="$recorded"
    fi
    sleep 0.5
    tries=$((tries + 1))
  done
  if ! p2b_pid_alive_and_matches "$pid" "bringup"; then
    # Worker may have written state already (fast fail)
    p2b_status_snapshot
    if [[ "${BRINGUP_STATE}" == "FAILED" || "${BRINGUP_STATE}" == "COMPLETED" ]]; then
      p2b_release_lock
      trap - EXIT
      p2b_print_status
      return 1
    fi
    echo "ERROR: BRINGUP_HANDOFF=FAIL worker pid not verified" >&2
    p2b_write_state "FAILED"
    p2b_release_lock
    exit 1
  fi

  p2b_emit_handoff "$run_id" "$pid" "$logf"
  p2b_release_lock
  trap - EXIT

  if [[ "$ATTACH_MONITOR" -eq 0 ]]; then
    echo "BRINGUP_MONITOR_MODE=DETACHED"
    echo "BRINGUP_STATUS_COMMAND=sudo bash ${P2B_WRAPPER_PATH} --status"
    return 0
  fi

  # Noninteractive without TTY: detach message
  if [[ ! -t 0 && ! -t 1 ]]; then
    echo "BRINGUP_MONITOR_MODE=AUTO_DETACH_NONINTERACTIVE"
    echo "BRINGUP_STATUS_COMMAND=sudo bash ${P2B_WRAPPER_PATH} --status"
    return 0
  fi

  p2b_monitor_loop "$run_id"
}

main() {
  parse_args "$@"

  if [[ "$STATUS_ONLY" -eq 1 ]]; then
    p2b_print_status
    exit 0
  fi
  if [[ "$DIAGNOSE_ONLY" -eq 1 ]]; then
    print_diagnose
    exit 0
  fi

  if [[ "$WORKER_MODE" -eq 1 ]]; then
    [[ -n "$VENDOR_BRINGUP" && -f "$VENDOR_BRINGUP" ]] \
      || { echo "ERROR: vendor bringup missing in worker mode" >&2; exit 1; }
    # Filter passthru: drop our meta flags already consumed
    p2b_worker_main "$VENDOR_BRINGUP" "${PASSTHRU[@]}"
    exit $?
  fi

  [[ "${EUID}" -eq 0 || "${PHASE2_BRINGUP_ALLOW_NONROOT:-0}" == "1" ]] \
    || { echo "ERROR: must run as root" >&2; exit 1; }

  # Default attach monitor for interactive; honor --detach
  if [[ ! -t 0 || ! -t 1 ]]; then
    # noninteractive may auto-detach unless explicitly attaching
    :
  fi

  start_or_monitor
}

# Lib-only for tests
if [[ "${DP_PHASE2_BRINGUP_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

main "$@"
