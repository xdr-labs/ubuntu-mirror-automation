# --- Offline LXD inventory / removal / target-transition guard -----------------

LXD_WAITREADY_TIMEOUT_SECS="${DP_OFFLINE_LXD_WAITREADY_TIMEOUT_SECS:-${LXD_WAITREADY_TIMEOUT_SECS:-120}}"
LXD_COMMAND_TIMEOUT_SECS="${DP_OFFLINE_LXD_COMMAND_TIMEOUT_SECS:-${DP_OFFLINE_LXD_INVENTORY_TIMEOUT_SECS:-${LXD_COMMAND_TIMEOUT_SECS:-30}}}"
LXD_INVENTORY_MAX_ATTEMPTS="${DP_OFFLINE_LXD_INVENTORY_MAX_ATTEMPTS:-${LXD_INVENTORY_MAX_ATTEMPTS:-2}}"
LXD_INVENTORY_TIMEOUT_SECS="${LXD_COMMAND_TIMEOUT_SECS}"
LXD_INVENTORY_BACKOFF_SECS="${DP_OFFLINE_LXD_INVENTORY_BACKOFF_SECS:-${LXD_INVENTORY_BACKOFF_SECS:-2}}"
LXD_INVENTORY_WALL_CLOCK_SECS="${DP_OFFLINE_LXD_INVENTORY_WALL_CLOCK_SECS:-${LXD_INVENTORY_WALL_CLOCK_SECS:-300}}"
LXD_PROGRESS_HEARTBEAT_SECS="${DP_OFFLINE_LXD_PROGRESS_HEARTBEAT_SECS:-${LXD_PROGRESS_HEARTBEAT_SECS:-30}}"
LXD_PREFLIGHT_CLASS="${LXD_PREFLIGHT_CLASS:-}"
LXD_OFFLINE_UPGRADE_POLICY="${LXD_OFFLINE_UPGRADE_POLICY:-}"
LXD_INVENTORY_EVIDENCE="${LXD_INVENTORY_EVIDENCE:-}"
_LXD_RUNTIME_STARTED_BY_US=0
_LXD_SERVICE_INITIAL_ACTIVE=0
_LXD_SOCKET_INITIAL_ACTIVE=0
_LXD_SERVICE_INITIAL_ENABLED=0

lxd_validate_inventory_timeouts() {
  local n
  for n in LXD_WAITREADY_TIMEOUT_SECS LXD_COMMAND_TIMEOUT_SECS LXD_INVENTORY_MAX_ATTEMPTS LXD_INVENTORY_WALL_CLOCK_SECS LXD_PROGRESS_HEARTBEAT_SECS; do
    [[ "${!n}" =~ ^[0-9]+$ ]] || case "$n" in
      LXD_WAITREADY_TIMEOUT_SECS) printf -v "$n" '%s' 120 ;;
      LXD_COMMAND_TIMEOUT_SECS) printf -v "$n" '%s' 30 ;;
      LXD_INVENTORY_MAX_ATTEMPTS) printf -v "$n" '%s' 2 ;;
      LXD_PROGRESS_HEARTBEAT_SECS) printf -v "$n" '%s' 30 ;;
      *) printf -v "$n" '%s' 300 ;;
    esac
  done
  # Use if/then: bare `((expr)) && assign` is fine, but keep clamps explicit.
  if (( LXD_WAITREADY_TIMEOUT_SECS < 30 )); then LXD_WAITREADY_TIMEOUT_SECS=30; fi
  if (( LXD_WAITREADY_TIMEOUT_SECS > 600 )); then LXD_WAITREADY_TIMEOUT_SECS=600; fi
  if (( LXD_COMMAND_TIMEOUT_SECS < 5 )); then LXD_COMMAND_TIMEOUT_SECS=5; fi
  if (( LXD_COMMAND_TIMEOUT_SECS > 120 )); then LXD_COMMAND_TIMEOUT_SECS=120; fi
  if (( LXD_INVENTORY_MAX_ATTEMPTS < 1 )); then LXD_INVENTORY_MAX_ATTEMPTS=1; fi
  if (( LXD_INVENTORY_MAX_ATTEMPTS > 3 )); then LXD_INVENTORY_MAX_ATTEMPTS=3; fi
  if (( LXD_INVENTORY_WALL_CLOCK_SECS < 60 )); then LXD_INVENTORY_WALL_CLOCK_SECS=60; fi
  if (( LXD_INVENTORY_WALL_CLOCK_SECS > 900 )); then LXD_INVENTORY_WALL_CLOCK_SECS=900; fi
  if (( LXD_PROGRESS_HEARTBEAT_SECS < 1 )); then LXD_PROGRESS_HEARTBEAT_SECS=1; fi
  if (( LXD_PROGRESS_HEARTBEAT_SECS > 300 )); then LXD_PROGRESS_HEARTBEAT_SECS=300; fi
  LXD_INVENTORY_TIMEOUT_SECS="$LXD_COMMAND_TIMEOUT_SECS"
}

lxd_unit_is_active() {
  local unit="$1"
  [[ -n "${TEST_ROOT:-}" && -f "$(hostpath "/tmp/lxd-unit-active-${unit}")" ]] && return 0
  "$SYSTEMCTL_BIN" is-active --quiet "$unit" >/dev/null 2>&1
}

lxd_unit_is_enabled() {
  local unit="$1"
  [[ -n "${TEST_ROOT:-}" && -f "$(hostpath "/tmp/lxd-unit-enabled-${unit}")" ]] && return 0
  "$SYSTEMCTL_BIN" is-enabled --quiet "$unit" >/dev/null 2>&1
}

lxd_record_initial_runtime_state() {
  local evid="$1"
  local en_rc=2
  if lxd_unit_is_active lxd.service; then
    _LXD_SERVICE_INITIAL_ACTIVE=1
  else
    _LXD_SERVICE_INITIAL_ACTIVE=0
  fi
  if lxd_unit_is_active lxd.socket; then
    _LXD_SOCKET_INITIAL_ACTIVE=1
  else
    _LXD_SOCKET_INITIAL_ACTIVE=0
  fi
  set +e
  lxd_unit_is_enabled lxd.service
  en_rc=$?
  set -e
  case "$en_rc" in
    0) _LXD_SERVICE_INITIAL_ENABLED=1 ;;
    1) _LXD_SERVICE_INITIAL_ENABLED=0 ;;
    *) _LXD_SERVICE_INITIAL_ENABLED=2 ;;
  esac
  {
    printf 'LXD_SERVICE_INITIAL_ACTIVE=%s\n' "$([[ "$_LXD_SERVICE_INITIAL_ACTIVE" -eq 1 ]] && echo YES || echo NO)"
    printf 'LXD_SOCKET_INITIAL_ACTIVE=%s\n' "$([[ "$_LXD_SOCKET_INITIAL_ACTIVE" -eq 1 ]] && echo YES || echo NO)"
    case "$_LXD_SERVICE_INITIAL_ENABLED" in
      1) printf 'LXD_SERVICE_INITIAL_ENABLED=YES\n' ;;
      0) printf 'LXD_SERVICE_INITIAL_ENABLED=NO\n' ;;
      *) printf 'LXD_SERVICE_INITIAL_ENABLED=UNKNOWN\n' ;;
    esac
  } >"${evid}/service-before.txt"
  log INFO "LXD_SERVICE_INITIAL_ACTIVE=$([[ "$_LXD_SERVICE_INITIAL_ACTIVE" -eq 1 ]] && echo YES || echo NO)"
  log INFO "LXD_SOCKET_INITIAL_ACTIVE=$([[ "$_LXD_SOCKET_INITIAL_ACTIVE" -eq 1 ]] && echo YES || echo NO)"
  case "$_LXD_SERVICE_INITIAL_ENABLED" in
    1) log INFO "LXD_SERVICE_INITIAL_ENABLED=YES" ;;
    0) log INFO "LXD_SERVICE_INITIAL_ENABLED=NO" ;;
    *) log INFO "LXD_SERVICE_INITIAL_ENABLED=UNKNOWN" ;;
  esac
}

lxd_start_runtime_for_inventory() {
  local cold=NO rc=0
  local bin="${SYSTEMCTL_BIN:-systemctl}"
  if [[ "$_LXD_SERVICE_INITIAL_ACTIVE" -eq 1 ]]; then
    log INFO "LXD_COLD_START_DETECTED=NO"
    return 0
  fi
  cold=YES
  log INFO "LXD_COLD_START_DETECTED=YES"
  set +e
  if [[ "$_LXD_SOCKET_INITIAL_ACTIVE" -eq 0 ]]; then
    "$bin" start lxd.socket >/dev/null 2>&1
  fi
  "$bin" start lxd.service >/dev/null 2>&1
  rc=$?
  set -e
  if [[ -n "${TEST_ROOT:-}" ]]; then
    mkdir -p "$(hostpath /tmp)"
    : >"$(hostpath /tmp/lxd-unit-active-lxd.service)"
    : >"$(hostpath /tmp/lxd-unit-active-lxd.socket)"
    rc=0
  fi
  if [[ "$rc" -eq 0 ]]; then
    _LXD_RUNTIME_STARTED_BY_US=1
  fi
  return 0
}

lxd_restore_runtime_state() {
  local evid="${1:-}"
  local bin="${SYSTEMCTL_BIN:-systemctl}"
  if [[ "$_LXD_RUNTIME_STARTED_BY_US" -eq 1 && "$_LXD_SERVICE_INITIAL_ACTIVE" -eq 0 ]]; then
    set +e
    "$bin" stop lxd.service >/dev/null 2>&1
    if [[ "$_LXD_SOCKET_INITIAL_ACTIVE" -eq 0 ]]; then
      "$bin" stop lxd.socket >/dev/null 2>&1
    fi
    set -e
    if [[ -n "${TEST_ROOT:-}" ]]; then
      rm -f "$(hostpath /tmp/lxd-unit-active-lxd.service)" \
        "$(hostpath /tmp/lxd-unit-active-lxd.socket)" 2>/dev/null || true
    fi
    log INFO "LXD_RUNTIME_RESTORE=INACTIVE"
  fi
  if [[ -n "$evid" ]]; then
    {
      printf 'LXD_RUNTIME_STARTED_BY_US=%s\n' "$_LXD_RUNTIME_STARTED_BY_US"
      if [[ "$_LXD_SERVICE_INITIAL_ACTIVE" -eq 1 ]]; then
        printf 'LXD_SERVICE_INITIAL_ACTIVE=YES\n'
      else
        printf 'LXD_SERVICE_INITIAL_ACTIVE=NO\n'
      fi
      if [[ "$_LXD_SOCKET_INITIAL_ACTIVE" -eq 1 ]]; then
        printf 'LXD_SOCKET_INITIAL_ACTIVE=YES\n'
      else
        printf 'LXD_SOCKET_INITIAL_ACTIVE=NO\n'
      fi
    } >"${evid}/service-after.txt"
  fi
  _LXD_RUNTIME_STARTED_BY_US=0
  return 0
}

lxd_pkg_installed_p() {
  local pkg="$1" status
  if [[ -n "${TEST_ROOT:-}" ]]; then
    status="$(awk -v p="$pkg" '
      $1=="Package:" { hit=($2==p) } hit && $1=="Status:" { print; exit }
    ' "$(hostpath /var/lib/dpkg/status)" 2>/dev/null || true)"
    if [[ "$status" == *"install ok installed"* ]]; then
      return 0
    fi
    return 1
  fi
  status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
  if [[ "$status" == *"install ok installed"* ]]; then
    return 0
  fi
  return 1
}

lxd_write_inventory_evidence() {
  local evid_dir="$1"
  shift
  mkdir -p "$evid_dir"
  {
    printf 'UTC=%s\n' "$(utc_now)"
    printf 'CLASS_HINT=%s\n' "${1:-}"
    printf '%s\n' '---'
    cat
  } >"${evid_dir}/inventory.txt"
  LXD_INVENTORY_EVIDENCE="${evid_dir}/inventory.txt"
  log INFO "LXD_INVENTORY_EVIDENCE=${LXD_INVENTORY_EVIDENCE}"
}

lxd_run_timed() {
  local out="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$LXD_COMMAND_TIMEOUT_SECS" "$@" >"$out" 2>&1
  else
    "$@" >"$out" 2>&1
  fi
}

lxd_run_with_heartbeat() {
  # Run a potentially long command while keeping raw stdout/stderr in evidence.
  # Completion is polled independently from the log cadence so a short command
  # is never delayed by a 30-second heartbeat interval.
  # Usage: lxd_run_with_heartbeat NAME OUT ERR -- command [args...]
  local name="$1" out="$2" err="$3"
  shift 3
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  if [[ "$#" -eq 0 ]]; then
    log ERROR "${name}_END rc=2 elapsed_secs=0"
    return 2
  fi

  local heartbeat="${LXD_PROGRESS_HEARTBEAT_SECS:-30}"
  local start now elapsed next_heartbeat pid rc=0 errexit_was_set=0
  case "$-" in *e*) errexit_was_set=1 ;; esac
  if [[ ! "$heartbeat" =~ ^[0-9]+$ || "$heartbeat" -lt 1 ]]; then
    heartbeat=30
  fi

  mkdir -p "$(dirname "$out")" "$(dirname "$err")"
  log INFO "${name}_BEGIN"
  "$@" >"$out" 2>"$err" &
  pid=$!
  start="$(date +%s)"
  next_heartbeat="$heartbeat"

  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      now="$(date +%s)"
      elapsed=$((now - start))
      if (( elapsed >= next_heartbeat )); then
        log INFO "${name}_PROGRESS=RUNNING elapsed_secs=${elapsed}"
        while (( next_heartbeat <= elapsed )); do
          next_heartbeat=$((next_heartbeat + heartbeat))
        done
      fi
    fi
  done

  set +e
  wait "$pid"
  rc=$?
  if [[ "$errexit_was_set" -eq 1 ]]; then
    set -e
  else
    set +e
  fi
  now="$(date +%s)"
  elapsed=$((now - start))
  log INFO "${name}_END rc=${rc} elapsed_secs=${elapsed}"
  return "$rc"
}

lxd_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

lxd_is_first_run_banner_line() {
  case "$1" in
    "If this is your first time running LXD on this machine, you should also run: lxd init"|\
    "To start your first container, try: lxc launch "*) return 0 ;;
  esac
  return 1
}

lxd_dir_has_entries_p() {
  local d="$1"
  [[ -d "$d" ]] && find "$d" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .
}

lxd_classify_container_csv_file() {
  local f="$1" out="$2" line name state running=0 stopped=0 unexpected=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    lxd_is_first_run_banner_line "$line" && continue
    [[ "$line" == *,* ]] || { unexpected=1; continue; }
    name="$(lxd_trim "${line%%,*}")"
    state="$(lxd_trim "${line#*,}")"; state="$(lxd_trim "${state%%,*}")"
    state="$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')"
    [[ -n "$name" && -n "$state" ]] || { unexpected=1; continue; }
    case "$state" in RUNNING|STARTING) running=1 ;; STOPPED|FROZEN|ERROR|ABORTING|STOPPING) stopped=1 ;; *) stopped=1 ;; esac
  done <"$f"
  printf 'RUNNING=%s\nSTOPPED=%s\nUNEXPECTED=%s\n' "$running" "$stopped" "$unexpected" >"$out"
}

lxd_image_list_nonempty_p() {
  local f="$1" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && ! lxd_is_first_run_banner_line "$line" && return 0
  done <"$f"
  return 1
}

lxd_extract_storage_pool_names() {
  local out="$1" src="$2" line field
  : >"$out"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    lxd_is_first_run_banner_line "$line" && continue
    case "$line" in
      "+"*) ;; "|"*) field="$(lxd_trim "${line#|}")"; field="$(lxd_trim "${field%%|*}")"; [[ -z "$field" || "$field" == NAME ]] || printf '%s\n' "$field" >>"$out" ;;
      *) return 1 ;;
    esac
  done <"$src"
}

lxd_storage_volume_table_indicates_use_p() {
  local f="$1" line field
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    lxd_is_first_run_banner_line "$line" && continue
    case "$line" in
      "+"*) ;; "|"*) field="$(lxd_trim "${line#|}")"; field="$(printf '%s' "${field%%|*}" | tr '[:upper:]' '[:lower:]')"
        case "$field" in type) ;; custom|container|image|virtual-machine) return 0 ;; esac ;;
      *) return 2 ;;
    esac
  done <"$f"
  return 1
}

lxd_storage_volume_table_parseable_p() {
  local f="$1" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    lxd_is_first_run_banner_line "$line" && continue
    case "$line" in "+"*|"|"*) ;; *) return 1 ;; esac
  done <"$f"
}

lxd_classify_instances_json() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    a=json.load(open(sys.argv[1]))
    running=stopped=0
    for x in a:
        s=str(x.get("status","")).upper()
        if s in ("RUNNING","STARTING"): running=1
        else: stopped=1
    open(sys.argv[2],"w").write("RUNNING=%d\nSTOPPED=%d\nUNEXPECTED=0\n"%(running,stopped))
except Exception: sys.exit(2)
PY
}

lxd_images_json_nonempty_p() {
  python3 - "$1" <<'PY'
import json, sys
try: sys.exit(0 if json.load(open(sys.argv[1])) else 1)
except Exception: sys.exit(2)
PY
}

lxd_extract_storage_pool_names_json() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    a=json.load(open(sys.argv[1]))
    with open(sys.argv[2],"w") as o:
        for x in a:
            n=x.get("name") if isinstance(x,dict) else str(x)
            if n: o.write(n+"\n")
except Exception: sys.exit(2)
PY
}

lxd_storage_volumes_json_indicates_use_p() {
  python3 - "$1" <<'PY'
import json, sys
try:
    a=json.load(open(sys.argv[1]))
    sys.exit(0 if any(str(x.get("type","")).lower() in ("custom","container","image","virtual-machine") for x in a) else 1)
except Exception: sys.exit(2)
PY
}

lxd_waitready_once() {
  local evid="$1" attempt="$2" out="${evid}/waitready-attempt-${attempt}.stdout" err="${evid}/waitready-attempt-${attempt}.stderr"
  local start end rc mode=""
  if dp_offline_hermetic_fixtures_enabled; then
    mode="${DP_OFFLINE_FAKE_LXD_WAITREADY:-}"
  fi
  start="$(date +%s)"
  log INFO "LXD_WAITREADY_ATTEMPT=${attempt}"
  set +e
  case "$mode" in
    ok) : >"$out"; : >"$err"; rc=0 ;;
    hang) timeout "$LXD_WAITREADY_TIMEOUT_SECS" sleep $((LXD_WAITREADY_TIMEOUT_SECS + 5)) >"$out" 2>"$err"; rc=$? ;;
    fail-then-ok) [[ "$attempt" -eq 1 ]] && { printf 'fake failure\n' >"$err"; rc=1; } || { : >"$out"; rc=0; } ;;
    delay) timeout "$LXD_WAITREADY_TIMEOUT_SECS" sleep "${DP_OFFLINE_FAKE_LXD_WAITREADY_DELAY_SECS:-1}" >"$out" 2>"$err"; rc=$? ;;
    fail) printf 'fake failure\n' >"$err"; rc=1 ;;
    *) timeout "$LXD_WAITREADY_TIMEOUT_SECS" lxd waitready --timeout "$LXD_WAITREADY_TIMEOUT_SECS" >"$out" 2>"$err"; rc=$? ;;
  esac
  set -e
  end="$(date +%s)"
  printf '%s\n' "$rc" >"${evid}/waitready-attempt-${attempt}.rc"
  printf 'LXD_WAITREADY_ATTEMPT_%s_DURATION_SECONDS=%s\n' "$attempt" "$((end-start))" >>"${evid}/durations.env"
  log INFO "LXD_WAITREADY_RC=${rc}"
  log INFO "LXD_WAITREADY_DURATION_SECONDS=$((end-start))"
  if [[ "$rc" -eq 0 ]]; then
    log INFO "LXD_DAEMON_READY=YES"
    log INFO "LXD_DAEMON_READY_TIME_SECONDS=$((end-start))"
    return 0
  fi
  log ERROR "LXD_DAEMON_READY=NO"
  return "$rc"
}

lxd_is_cold_start_failure() {
  local rc="$1" errf="$2"
  [[ "$rc" -eq 124 || "$rc" -eq 137 ]] && return 0
  grep -qiE 'not running|connection refused|daemon|timeout|timed out|failed to connect' "$errf" 2>/dev/null
}

lxd_write_filesystem_evidence() {
  local evid="$1" d
  : >"${evid}/filesystem.txt"
  for d in /var/lib/lxd/containers /var/lib/lxd/images /var/lib/lxd/storage-pools /var/snap/lxd/common/lxd/containers; do
    printf 'DIR=%s\n' "$d" >>"${evid}/filesystem.txt"
    find "$(hostpath "$d")" -mindepth 1 -maxdepth 2 -print 2>/dev/null >>"${evid}/filesystem.txt" || true
  done
}

lxd_run_inventory_commands() {
  local evid="$1" attempt="$2" rc pools="${evid}/storage-pools.names" pool
  local complete=1 flags="${evid}/instance-flags.env"
  local json_ok=0
  : >"${evid}/errors.txt"
  : >"$pools"
  rm -f "${evid}/.has_running" "${evid}/.has_stopped" "${evid}/.has_images" "${evid}/.has_storage" 2>/dev/null || true

  # First-attempt-only timeout fixture (cold-start retry path).
  if dp_offline_hermetic_fixtures_enabled && [[ "${DP_OFFLINE_FAKE_LXD_TIMEOUT:-0}" == "1" ]]; then
    if [[ "${DP_OFFLINE_FAKE_LXD_TIMEOUT_ONCE:-1}" == "1" && "$attempt" -eq 1 ]]; then
      printf 'TIMEOUT=lxc list\n' >>"${evid}/errors.txt"
      printf 'ATTEMPT=%s\nCOMPLETE=0\n' "$attempt" >"${evid}/inventory-attempt-${attempt}.env"
      return 124
    elif [[ "${DP_OFFLINE_FAKE_LXD_TIMEOUT_ONCE:-1}" != "1" ]]; then
      printf 'TIMEOUT=lxc list\n' >>"${evid}/errors.txt"
      printf 'ATTEMPT=%s\nCOMPLETE=0\n' "$attempt" >"${evid}/inventory-attempt-${attempt}.env"
      return 124
    fi
  fi

  if dp_offline_hermetic_fixtures_enabled && [[ "${DP_OFFLINE_FAKE_LXD_JSON_PARSE_FAIL:-0}" == "1" ]]; then
    printf 'PARSE_FAIL=instances.json\n' >>"${evid}/errors.txt"
    printf 'ATTEMPT=%s\nCOMPLETE=0\n' "$attempt" >"${evid}/inventory-attempt-${attempt}.env"
    return 1
  fi

  # Instances: prefer JSON; fall back to CSV on parse/flag failure (LXD 3.0.3).
  set +e
  lxd_run_timed "${evid}/instances.json" lxc list --format=json
  rc=$?
  set -e
  json_ok=0
  if [[ "$rc" -eq 0 ]]; then
    set +e
    lxd_classify_instances_json "${evid}/instances.json" "$flags"
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]] && json_ok=1
  elif [[ "$rc" -eq 124 ]]; then
    printf 'TIMEOUT=lxc list\n' >>"${evid}/errors.txt"
    complete=0
  fi
  if [[ "$json_ok" -eq 0 && "$complete" -eq 1 ]]; then
    set +e
    lxd_run_timed "${evid}/instances.csv" lxc list --format csv -c ns
    rc=$?
    set -e
    cp -f "${evid}/instances.csv" "${evid}/lxc-list.txt" 2>/dev/null || true
    if [[ "$rc" -eq 124 ]]; then
      printf 'TIMEOUT=lxc list\n' >>"${evid}/errors.txt"
      complete=0
    elif [[ "$rc" -ne 0 ]]; then
      printf 'FAIL=lxc list rc=%s\n' "$rc" >>"${evid}/errors.txt"
      complete=0
    else
      lxd_classify_container_csv_file "${evid}/instances.csv" "$flags"
      if [[ "$(awk -F= '$1=="UNEXPECTED"{print $2; exit}' "$flags" 2>/dev/null || echo 0)" == "1" ]]; then
        printf 'UNEXPECTED_LXC_LIST_OUTPUT=1\n' >>"${evid}/errors.txt"
        complete=0
      fi
    fi
  fi

  # Images
  if [[ "$complete" -eq 1 ]]; then
    set +e
    lxd_run_timed "${evid}/images.json" lxc image list --format=json
    rc=$?
    set -e
    json_ok=0
    if [[ "$rc" -eq 0 ]]; then
      set +e
      lxd_images_json_nonempty_p "${evid}/images.json"
      rc=$?
      set -e
      if [[ "$rc" -eq 0 ]]; then
        touch "${evid}/.has_images"
        json_ok=1
      elif [[ "$rc" -eq 1 ]]; then
        json_ok=1
      fi
    fi
    if [[ "$json_ok" -eq 0 ]]; then
      set +e
      lxd_run_timed "${evid}/images.csv" lxc image list --format csv -c l
      rc=$?
      set -e
      cp -f "${evid}/images.csv" "${evid}/lxc-image-list.txt" 2>/dev/null || true
      if [[ "$rc" -eq 124 ]]; then
        printf 'TIMEOUT=lxc image list\n' >>"${evid}/errors.txt"
        complete=0
      elif [[ "$rc" -ne 0 ]]; then
        printf 'FAIL=lxc image list rc=%s\n' "$rc" >>"${evid}/errors.txt"
        complete=0
      elif lxd_image_list_nonempty_p "${evid}/images.csv"; then
        touch "${evid}/.has_images"
      fi
    else
      cp -f "${evid}/images.json" "${evid}/lxc-image-list.txt" 2>/dev/null || true
    fi
  fi

  # Storage pools (LXD 3.0.3: no --format → table fallback)
  if [[ "$complete" -eq 1 ]]; then
    set +e
    lxd_run_timed "${evid}/storage-pools.json" lxc storage list --format=json
    rc=$?
    set -e
    json_ok=0
    if [[ "$rc" -eq 0 ]]; then
      set +e
      lxd_extract_storage_pool_names_json "${evid}/storage-pools.json" "$pools"
      rc=$?
      set -e
      [[ "$rc" -eq 0 ]] && json_ok=1
    fi
    if [[ "$json_ok" -eq 0 ]]; then
      set +e
      lxd_run_timed "${evid}/storage-pools.table" lxc storage list
      rc=$?
      set -e
      cp -f "${evid}/storage-pools.table" "${evid}/lxc-storage-list.txt" 2>/dev/null || true
      if [[ "$rc" -eq 124 ]]; then
        printf 'TIMEOUT=lxc storage list\n' >>"${evid}/errors.txt"
        complete=0
      elif [[ "$rc" -ne 0 ]]; then
        printf 'FAIL=lxc storage list rc=%s\n' "$rc" >>"${evid}/errors.txt"
        complete=0
      elif ! lxd_extract_storage_pool_names "$pools" "${evid}/storage-pools.table"; then
        printf 'UNPARSEABLE=lxc storage list\n' >>"${evid}/errors.txt"
        complete=0
      fi
    fi
  fi

  if [[ "$complete" -eq 1 && -s "$pools" ]]; then
    touch "${evid}/.has_storage"
    while IFS= read -r pool || [[ -n "$pool" ]]; do
      [[ -n "$pool" ]] || continue
      set +e
      lxd_run_timed "${evid}/storage-volumes-${pool}.json" lxc storage volume list "$pool" --format=json
      rc=$?
      set -e
      json_ok=0
      if [[ "$rc" -eq 0 ]]; then
        set +e
        lxd_storage_volumes_json_indicates_use_p "${evid}/storage-volumes-${pool}.json"
        rc=$?
        set -e
        if [[ "$rc" -eq 0 ]]; then
          touch "${evid}/.has_storage"
          json_ok=1
        elif [[ "$rc" -eq 1 ]]; then
          json_ok=1
        fi
      fi
      if [[ "$json_ok" -eq 0 ]]; then
        set +e
        lxd_run_timed "${evid}/storage-volumes-${pool}.table" lxc storage volume list "$pool"
        rc=$?
        set -e
        {
          printf 'POOL=%s rc=%s\n' "$pool" "$rc"
          cat "${evid}/storage-volumes-${pool}.table" 2>/dev/null || true
          printf '\n'
        } >>"${evid}/lxc-storage-volume-list.txt"
        if [[ "$rc" -eq 124 ]]; then
          printf 'TIMEOUT=lxc storage volume list pool=%s\n' "$pool" >>"${evid}/errors.txt"
          complete=0
        elif [[ "$rc" -ne 0 ]]; then
          printf 'FAIL=lxc storage volume list pool=%s rc=%s\n' "$pool" "$rc" >>"${evid}/errors.txt"
          complete=0
        elif ! lxd_storage_volume_table_parseable_p "${evid}/storage-volumes-${pool}.table"; then
          printf 'UNPARSEABLE=lxc storage volume list pool=%s\n' "$pool" >>"${evid}/errors.txt"
          complete=0
        else
          set +e
          lxd_storage_volume_table_indicates_use_p "${evid}/storage-volumes-${pool}.table"
          rc=$?
          set -e
          if [[ "$rc" -eq 0 ]]; then
            touch "${evid}/.has_storage"
          elif [[ "$rc" -eq 2 ]]; then
            printf 'UNPARSEABLE=lxc storage volume list pool=%s\n' "$pool" >>"${evid}/errors.txt"
            complete=0
          fi
        fi
      fi
    done <"$pools"
  fi

  if [[ -f "$flags" ]]; then
    [[ "$(awk -F= '$1=="RUNNING"{print $2; exit}' "$flags" 2>/dev/null || true)" == "1" ]] && touch "${evid}/.has_running"
    [[ "$(awk -F= '$1=="STOPPED"{print $2; exit}' "$flags" 2>/dev/null || true)" == "1" ]] && touch "${evid}/.has_stopped"
  else
    complete=0
  fi

  printf 'ATTEMPT=%s\nCOMPLETE=%s\n' "$attempt" "$complete" >"${evid}/inventory-attempt-${attempt}.env"
  # Explicit returns: under `set -e`, a failing `[[ complete -eq 1 ]]` as the
  # function's last command can abort the caller via RETURN-trap inheritance.
  if [[ "$complete" -eq 1 ]]; then
    return 0
  fi
  return 1
}

lxd_set_class_policy() {
  case "$1" in
    LXD_NOT_INSTALLED) LXD_OFFLINE_UPGRADE_POLICY=SKIP_NO_DEB_LXD ;;
    LXD_INSTALLED_UNUSED) LXD_OFFLINE_UPGRADE_POLICY=REMOVE_UNUSED_DEB_LXD_BEFORE_DRO ;;
    *) LXD_OFFLINE_UPGRADE_POLICY=FAIL_CLOSED ;;
  esac
}

collect_and_classify_lxd_inventory() {
  local stamp evid attempt=1 start rc=0 complete=0 cold=0 installed=0
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"; evid="$(hostpath "${STATE_ROOT}/evidence/lxd-inventory/${stamp}")"
  mkdir -p "$evid"; LXD_INVENTORY_EVIDENCE="${evid}/inventory.txt"; lxd_validate_inventory_timeouts
  if dp_offline_hermetic_fixtures_enabled && [[ -n "${DP_OFFLINE_FAKE_LXD_CLASS:-}" ]]; then
    LXD_PREFLIGHT_CLASS="$DP_OFFLINE_FAKE_LXD_CLASS"
    case "$LXD_PREFLIGHT_CLASS" in LXD_NOT_INSTALLED|LXD_INSTALLED_UNUSED|LXD_IN_USE|LXD_AMBIGUOUS) ;; *) LXD_PREFLIGHT_CLASS=LXD_AMBIGUOUS ;; esac
    lxd_set_class_policy "$LXD_PREFLIGHT_CLASS"
    printf 'FAKE_CLASS=%s\nFAKE_CONTAINERS=%s\nFAKE_IMAGES=%s\nFAKE_STORAGE=%s\n' "$LXD_PREFLIGHT_CLASS" "${DP_OFFLINE_FAKE_LXD_CONTAINERS:-}" "${DP_OFFLINE_FAKE_LXD_IMAGES:-}" "${DP_OFFLINE_FAKE_LXD_STORAGE:-}" | lxd_write_inventory_evidence "$evid" "$LXD_PREFLIGHT_CLASS"
    return 0
  fi
  # Default TEST_ROOT fixtures: no LXD unless planted under the fake root.
  if [[ -n "${TEST_ROOT:-}" ]]; then
    if [[ -f "$(hostpath /var/lib/dpkg/status)" ]] \
      && grep -qE '^Package:[[:space:]]*(lxd|lxd-client)$' "$(hostpath /var/lib/dpkg/status)" 2>/dev/null; then
      :
    else
      LXD_PREFLIGHT_CLASS=LXD_NOT_INSTALLED
      lxd_set_class_policy "$LXD_PREFLIGHT_CLASS"
      printf 'TEST_ROOT_DEFAULT=LXD_NOT_INSTALLED\n' | lxd_write_inventory_evidence "$evid" "$LXD_PREFLIGHT_CLASS"
      printf 'CLASS=%s\n' "$LXD_PREFLIGHT_CLASS" >"${evid}/final-classification.env"
      log INFO "LXD_PREFLIGHT_CLASS=${LXD_PREFLIGHT_CLASS}"
      log INFO "LXD_OFFLINE_UPGRADE_POLICY=${LXD_OFFLINE_UPGRADE_POLICY}"
      return 0
    fi
  fi
  {
    printf 'DPKG_LXD=\n'
    if [[ -n "${TEST_ROOT:-}" && -f "$(hostpath /var/lib/dpkg/status)" ]]; then
      awk '
        $1 == "Package:" && ($2 == "lxd" || $2 == "lxd-client") {
          pkg=$2; ver=""; st=""; inpkg=1; next
        }
        inpkg && $1 == "Package:" {
          if (pkg != "") printf "%s\t%s\t%s\n", pkg, st, ver
          pkg=""; inpkg=0
        }
        inpkg && $1 == "Status:" {
          st=$2; for (i=3;i<=NF;i++) st=st" "$i
        }
        inpkg && $1 == "Version:" { ver=$2 }
        END { if (inpkg && pkg != "") printf "%s\t%s\t%s\n", pkg, st, ver }
      ' "$(hostpath /var/lib/dpkg/status)" || true
    else
      dpkg-query -W -f='${Package}\t${Status}\t${Version}\n' lxd lxd-client 2>/dev/null || true
    fi
    printf 'DPKG_END\n'
  } >"${evid}/packages.txt"
  cp -f "${evid}/packages.txt" "${evid}/dpkg.txt" 2>/dev/null || true
  if lxd_pkg_installed_p lxd || lxd_pkg_installed_p lxd-client; then
    installed=1
  fi
  if [[ "$installed" -eq 0 ]]; then
    LXD_PREFLIGHT_CLASS=LXD_NOT_INSTALLED
    lxd_set_class_policy "$LXD_PREFLIGHT_CLASS"
    cat "${evid}/dpkg.txt" | lxd_write_inventory_evidence "$evid" "$LXD_PREFLIGHT_CLASS"
    printf 'CLASS=%s\n' "$LXD_PREFLIGHT_CLASS" >"${evid}/final-classification.env"
    log INFO "LXD_PREFLIGHT_CLASS=${LXD_PREFLIGHT_CLASS}"
    log INFO "LXD_OFFLINE_UPGRADE_POLICY=${LXD_OFFLINE_UPGRADE_POLICY}"
    return 0
  fi
  lxd_write_filesystem_evidence "$evid"
  lxd_record_initial_runtime_state "$evid"
  # shellcheck disable=SC2064
  trap 'lxd_restore_runtime_state "'"$evid"'"' RETURN
  lxd_start_runtime_for_inventory || true
  # Fixtures without waitready binary: treat as ready unless hang/fail forced.
  if dp_offline_hermetic_fixtures_enabled && [[ -z "${DP_OFFLINE_FAKE_LXD_WAITREADY:-}" && -n "${TEST_ROOT:-}" ]]; then
    export DP_OFFLINE_FAKE_LXD_WAITREADY=ok
  fi
  start="$(date +%s)"
  while [[ "$attempt" -le "$LXD_INVENTORY_MAX_ATTEMPTS" && $(( $(date +%s) - start )) -lt "$LXD_INVENTORY_WALL_CLOCK_SECS" ]]; do
    rc=0
    lxd_waitready_once "$evid" "$attempt" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      rc=0
      # `|| rc=$?` keeps set -e from aborting collect on incomplete inventory.
      lxd_run_inventory_commands "$evid" "$attempt" || rc=$?
      if [[ "$rc" -eq 0 ]]; then
        complete=1
        break
      fi
      # Retry incomplete inventory once on cold-start / timeout.
      if [[ "$attempt" -lt "$LXD_INVENTORY_MAX_ATTEMPTS" ]]; then
        if [[ "$rc" -eq 124 ]] || lxd_is_cold_start_failure "$rc" "${evid}/errors.txt" \
          || [[ "$_LXD_SERVICE_INITIAL_ACTIVE" -eq 0 ]]; then
          cold=1
          attempt=$((attempt + 1))
          sleep "$LXD_INVENTORY_BACKOFF_SECS"
          continue
        fi
      fi
      break
    fi
    if lxd_is_cold_start_failure "$rc" "${evid}/waitready-attempt-${attempt}.stderr"; then
      cold=1
    fi
    if [[ "$attempt" -lt "$LXD_INVENTORY_MAX_ATTEMPTS" ]] && [[ "$cold" -eq 1 || "$rc" -eq 124 ]]; then
      attempt=$((attempt + 1))
      sleep "$LXD_INVENTORY_BACKOFF_SECS"
      continue
    fi
    break
  done
  # Filesystem evidence is only corroboration after a complete daemon API read.
  # Never classify UNUSED from filesystem alone.
  if [[ "$complete" -eq 1 ]]; then
    lxd_dir_has_entries_p "$(hostpath /var/lib/lxd/containers)" && touch "${evid}/.has_stopped"
    lxd_dir_has_entries_p "$(hostpath /var/lib/lxd/images)" && touch "${evid}/.has_images"
    # Populated storage-pool dirs reinforce in-use only when API already saw pools
    # or explicit volume use; empty default dirs must not flip UNUSED→IN_USE alone.
    if [[ -f "${evid}/.has_storage" ]] && lxd_dir_has_entries_p "$(hostpath /var/lib/lxd/storage-pools)"; then
      touch "${evid}/.has_storage"
    fi
    lxd_dir_has_entries_p "$(hostpath /var/snap/lxd/common/lxd/containers)" && touch "${evid}/.has_stopped"
  fi
  if [[ "$complete" -ne 1 ]]; then
    LXD_PREFLIGHT_CLASS=LXD_AMBIGUOUS
  elif [[ -f "${evid}/.has_running" || -f "${evid}/.has_stopped" || -f "${evid}/.has_images" || -f "${evid}/.has_storage" ]]; then
    LXD_PREFLIGHT_CLASS=LXD_IN_USE
  else
    LXD_PREFLIGHT_CLASS=LXD_INSTALLED_UNUSED
  fi
  case "${DP_OFFLINE_FAKE_LXD_CONTAINERS:-}" in
    running|stopped) LXD_PREFLIGHT_CLASS=LXD_IN_USE ;;
  esac
  case "${DP_OFFLINE_FAKE_LXD_IMAGES:-}" in
    yes|1) LXD_PREFLIGHT_CLASS=LXD_IN_USE ;;
  esac
  case "${DP_OFFLINE_FAKE_LXD_STORAGE:-}" in
    yes|1) LXD_PREFLIGHT_CLASS=LXD_IN_USE ;;
  esac
  lxd_set_class_policy "$LXD_PREFLIGHT_CLASS"
  {
    printf 'CLASS=%s\n' "$LXD_PREFLIGHT_CLASS"
    printf 'POLICY=%s\n' "$LXD_OFFLINE_UPGRADE_POLICY"
    printf 'COMPLETE=%s\n' "$complete"
    printf 'COLD_START_FAILURE=%s\n' "$cold"
    if [[ -f "${evid}/.has_running" ]]; then printf 'HAS_RUNNING=1\n'; else printf 'HAS_RUNNING=0\n'; fi
    if [[ -f "${evid}/.has_stopped" ]]; then printf 'HAS_STOPPED=1\n'; else printf 'HAS_STOPPED=0\n'; fi
    if [[ -f "${evid}/.has_images" ]]; then printf 'HAS_IMAGE=1\n'; else printf 'HAS_IMAGE=0\n'; fi
    if [[ -f "${evid}/.has_storage" ]]; then printf 'HAS_STORAGE=1\n'; else printf 'HAS_STORAGE=0\n'; fi
    if [[ "$LXD_PREFLIGHT_CLASS" == LXD_AMBIGUOUS ]]; then printf 'AMBIGUOUS=1\n'; else printf 'AMBIGUOUS=0\n'; fi
  } >"${evid}/summary.env"
  cp -f "${evid}/summary.env" "${evid}/final-classification.env"
  {
    cat "${evid}/dpkg.txt"
    cat "${evid}/summary.env"
    if [[ -f "${evid}/errors.txt" ]]; then
      cat "${evid}/errors.txt"
    fi
  } | lxd_write_inventory_evidence "$evid" "$LXD_PREFLIGHT_CLASS"
  log INFO "LXD_PREFLIGHT_CLASS=${LXD_PREFLIGHT_CLASS}"
  log INFO "LXD_OFFLINE_UPGRADE_POLICY=${LXD_OFFLINE_UPGRADE_POLICY}"
  lxd_restore_runtime_state "$evid"
}

lxd_emit_preflight_failure_context() {
  local pts="false"
  local retry="YES"
  local block=""
  local os_ver=""
  if [[ "${RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED:-false}" == "true" ]] \
    || [[ "${PACKAGE_TRANSITION_STARTED:-false}" == "true" ]] \
    || [[ "${PACKAGE_TRANSITION_STARTED:-NO}" == "YES" ]]; then
    pts="true"
    retry="NO"
    block="PACKAGE_TRANSITION_STARTED"
  fi
  os_ver="$(read_os_field VERSION_ID 2>/dev/null || true)"
  os_ver="${os_ver:-${PIN_SOURCE_VERSION:-unknown}}"
  log ERROR "FAILURE_STAGE=LXD_PREFLIGHT"
  log ERROR "FAILURE_RETRY_SAFE=${retry}"
  log ERROR "PACKAGE_TRANSITION_STARTED=${pts}"
  log ERROR "CURRENT_OS=${os_ver}"
  if [[ "$retry" == "YES" ]]; then
    log ERROR "RERUN_ALLOWED=YES"
    log ERROR "RERUN_BLOCK_REASON="
  else
    log ERROR "RERUN_ALLOWED=NO"
    log ERROR "RERUN_BLOCK_REASON=${block}"
  fi
}

lxd_preflight_gate() {
  collect_and_classify_lxd_inventory
  case "$LXD_PREFLIGHT_CLASS" in
    LXD_NOT_INSTALLED|LXD_INSTALLED_UNUSED)
      log INFO "LXD_PREFLIGHT_GATE=PASS"
      return 0
      ;;
    LXD_IN_USE)
      log ERROR "FAIL_LXD_IN_USE_OFFLINE_UPGRADE_UNSUPPORTED"
      log ERROR "LXD_PREFLIGHT_CLASS=${LXD_PREFLIGHT_CLASS}"
      log ERROR "LXD_OFFLINE_UPGRADE_POLICY=${LXD_OFFLINE_UPGRADE_POLICY}"
      lxd_emit_preflight_failure_context
      die "$EC_LXD" "FAIL_LXD_IN_USE_OFFLINE_UPGRADE_UNSUPPORTED"
      ;;
    LXD_AMBIGUOUS|*)
      log ERROR "FAIL_LXD_USAGE_CANNOT_BE_PROVEN_SAFE"
      log ERROR "LXD_PREFLIGHT_CLASS=${LXD_PREFLIGHT_CLASS:-LXD_AMBIGUOUS}"
      log ERROR "LXD_OFFLINE_UPGRADE_POLICY=FAIL_CLOSED"
      lxd_emit_preflight_failure_context
      die "$EC_LXD" "FAIL_LXD_USAGE_CANNOT_BE_PROVEN_SAFE"
      ;;
  esac
}

lxd_is_allowlisted_removal_pkg() {
  local pkg="$1" a
  for a in $LXD_REMOVAL_ALLOWLIST; do
    [[ "$pkg" == "$a" ]] && return 0
  done
  return 1
}

lxd_is_critical_removal_pkg() {
  local pkg="$1" c
  for c in $CRITICAL_HOLD_PACKAGES; do
    [[ "$pkg" == "$c" ]] && return 0
  done
  case "$pkg" in
    linux-image-*|linux-headers-*|linux-modules-*|linux-generic*|linux-virtual*)
      return 0
      ;;
  esac
  return 1
}

simulate_unused_lxd_removal() {
  # apt-get -s remove; populate evid. Return 0 only when safe.
  local evid="$1"
  local sim="${evid}/removal-simulation.txt"
  local unexpected=0 critical_hit=0
  local line pkg

  mkdir -p "$evid"
  if dp_offline_hermetic_fixtures_enabled && [[ -n "${DP_OFFLINE_FAKE_LXD_REMOVAL_SIM:-}" ]]; then
    printf '%s\n' "$DP_OFFLINE_FAKE_LXD_REMOVAL_SIM" >"$sim"
  else
    set +e
    DEBIAN_FRONTEND=noninteractive apt-get -s -y remove $LXD_REMOVAL_TARGETS \
      >"$sim" 2>"${evid}/removal-simulation.err"
    set -e
  fi

  # Parse Remv lines: "Remv pkg [ver]" or "Remv pkg*"
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      Remv\ *)
        pkg="$(printf '%s\n' "$line" | awk '{print $2}' | tr -d '*')"
        [[ -n "$pkg" ]] || continue
        if lxd_is_critical_removal_pkg "$pkg"; then
          critical_hit=1
          log ERROR "LXD_REMOVAL_CRITICAL_PACKAGE=${pkg}"
        fi
        if ! lxd_is_allowlisted_removal_pkg "$pkg"; then
          unexpected=$((unexpected + 1))
          log ERROR "LXD_REMOVAL_UNEXPECTED_PACKAGE=${pkg}"
        fi
        ;;
    esac
  done <"$sim"

  log INFO "LXD_REMOVAL_UNEXPECTED_PACKAGE_COUNT=${unexpected}"
  if [[ "$critical_hit" -ne 0 ]]; then
    log ERROR "LXD_REMOVAL_SIMULATION=FAIL"
    log ERROR "FAIL_LXD_REMOVAL_WOULD_TOUCH_CRITICAL_PACKAGE"
    return 1
  fi
  if [[ "$unexpected" -ne 0 ]]; then
    log ERROR "LXD_REMOVAL_SIMULATION=FAIL"
    log ERROR "FAIL_LXD_REMOVAL_UNEXPECTED_PACKAGES"
    return 1
  fi
  log INFO "LXD_REMOVAL_SIMULATION=PASS"
  return 0
}

apply_lxd_noinstall_pin() {
  # Prevent Focal transitional lxd from being reselected after removal.
  local pin
  pin="$(hostpath /etc/apt/preferences.d/99-stellar-offline-no-lxd-transition)"
  mkdir -p "$(dirname "$pin")"
  cat >"$pin" <<'EOF'
Package: lxd lxd-client lxd-tools
Pin: release *
Pin-Priority: -1
EOF
  log INFO "LXD_NOINSTALL_PIN=INSTALLED path=${pin}"
}

scan_package_maintainer_network_risk() {
  # Fail if staged/candidate lxd maintainer scripts reference Snap Store.
  local evid="$1"
  local hit=0
  local f

  mkdir -p "$evid"
  : >"${evid}/network-risk-scan.txt"
  for f in \
    /var/lib/dpkg/info/lxd.preinst \
    /var/lib/dpkg/info/lxd.postinst \
    /var/lib/dpkg/info/lxd.prerm \
    /var/lib/dpkg/info/lxd.postrm \
    /var/lib/dpkg/info/lxd-client.preinst \
    /var/lib/dpkg/info/lxd-client.postinst; do
    if [[ -n "${TEST_ROOT:-}" ]]; then
      f="$(hostpath "$f")"
    fi
    [[ -f "$f" ]] || continue
    if grep -qiE 'api\.snapcraft\.io|snapcraft\.io|snap[[:space:]]+install|from the .* track' "$f" 2>/dev/null; then
      printf 'HIT=%s\n' "$f" >>"${evid}/network-risk-scan.txt"
      hit=1
    fi
  done

  # Also scan apt-cache show for remaining candidate descriptions (informational),
  # but only fail when an installed/candidate preinst would still run.
  if dp_offline_hermetic_fixtures_enabled && [[ "${DP_OFFLINE_FAKE_LXD_NETWORK_RISK:-}" == "1" ]]; then
    hit=1
    printf 'HIT=FAKE_NETWORK_RISK\n' >>"${evid}/network-risk-scan.txt"
  fi

  if [[ "$hit" -ne 0 ]]; then
    # After unused removal + pin, residual scripts on disk for purged packages are OK
    # only if packages are not selected. Selection is checked separately.
    if [[ "${LXD_TARGET_TRANSITION_SELECTED:-}" == "YES" ]]; then
      log ERROR "PACKAGE_MAINTAINER_NETWORK_RISK_SCAN=FAIL"
      return 1
    fi
  fi
  log INFO "PACKAGE_MAINTAINER_NETWORK_RISK_SCAN=PASS"
  return 0
}

guard_lxd_target_transition() {
  # Verify target plan will not select Focal transitional lxd.
  local evid="$1"
  local sim="${evid}/target-plan-sim.txt"
  local selected=0 rc=0
  local force_selected=""
  if dp_offline_hermetic_fixtures_enabled; then
    force_selected="${DP_OFFLINE_FAKE_LXD_TARGET_SELECTED:-}"
  fi

  mkdir -p "$evid"
  if [[ -n "$force_selected" ]]; then
    if [[ "$force_selected" == "YES" ]]; then
      selected=1
      printf 'FAKE_SELECTED=YES\n' >"$sim"
    else
      printf 'FAKE_SELECTED=NO\n' >"$sim"
    fi
  elif [[ -n "${TEST_ROOT:-}" ]]; then
    # Fixtures without explicit force: assume not selected after pin.
    printf 'TEST_ROOT_DEFAULT_SELECTED=NO\n' >"$sim"
  else
    set +e
    lxd_run_with_heartbeat LXD_TARGET_PLAN_SIMULATION "$sim" "${evid}/target-plan-sim.err" -- \
      env DEBIAN_FRONTEND=noninteractive apt-get -s -y dist-upgrade
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      log WARN "LXD_TARGET_PLAN_SIMULATION_NONZERO_RC=${rc}"
    fi
    if grep -qiE '^Inst lxd |^Inst lxd-client |^Conf lxd |^Conf lxd-client ' "$sim" 2>/dev/null; then
      selected=1
    fi
    _lxd_pol="$(apt-cache policy lxd 2>/dev/null || true)"
    _lxd_cand="$(cross_release_candidate_from_policy "${_lxd_pol}")"
    if printf '%s\n' "${_lxd_cand}" | grep -qiE '1:0\.|transitional'; then
      # Candidate exists but pin should make it non-installable; Inst line is authoritative.
      :
    fi
  fi

  if [[ "$selected" -eq 1 ]]; then
    LXD_TARGET_TRANSITION_SELECTED="YES"
    LXD_TARGET_TRANSITION_GUARD="FAIL"
    log ERROR "LXD_TARGET_TRANSITION_SELECTED=YES"
    log ERROR "LXD_TARGET_TRANSITION_GUARD=FAIL"
    log ERROR "FAIL_LXD_TARGET_TRANSITION_RESELECTED"
    return 1
  fi
  LXD_TARGET_TRANSITION_SELECTED="NO"
  LXD_TARGET_TRANSITION_GUARD="PASS"
  log INFO "LXD_TARGET_TRANSITION_SELECTED=NO"
  log INFO "LXD_TARGET_TRANSITION_GUARD=PASS"
  return 0
}

remove_unused_lxd_before_dro() {
  # Post-confirmation, pre-package-mutation. Only for LXD_INSTALLED_UNUSED.
  local stamp evid rc=0

  if [[ "$LXD_PREFLIGHT_CLASS" != "LXD_INSTALLED_UNUSED" ]]; then
    log INFO "LXD_REMOVAL_RESULT=SKIPPED class=${LXD_PREFLIGHT_CLASS:-unset}"
    # Still pin + guard when not installed so transitional package cannot appear.
    stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    evid="$(hostpath "${STATE_ROOT}/evidence/lxd-removal/${stamp}")"
    mkdir -p "$evid"
    apply_lxd_noinstall_pin
    guard_lxd_target_transition "$evid" || die "$EC_LXD" "FAIL_LXD_TARGET_TRANSITION_RESELECTED"
    LXD_TARGET_TRANSITION_SELECTED="${LXD_TARGET_TRANSITION_SELECTED:-NO}"
    scan_package_maintainer_network_risk "$evid" || die "$EC_LXD" "FAIL_PACKAGE_MAINTAINER_NETWORK_RISK"
    return 0
  fi

  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  evid="$(hostpath "${STATE_ROOT}/evidence/lxd-removal/${stamp}")"
  mkdir -p "$evid"

  if ! simulate_unused_lxd_removal "$evid"; then
    die "$EC_LXD" "FAIL_LXD_REMOVAL_SIMULATION"
  fi

  if dp_offline_hermetic_fixtures_enabled && [[ -n "${TEST_ROOT:-}" && -z "${DP_OFFLINE_FAKE_LXD_DO_REMOVE:-}" ]]; then
    # Fixture path: record simulated success without mutating host.
    log INFO "LXD_REMOVAL_RESULT=PASS"
    log INFO "LXD_POST_REMOVAL_DPKG_AUDIT=PASS"
    log INFO "LXD_POST_REMOVAL_APT_CHECK=PASS"
    apply_lxd_noinstall_pin
    guard_lxd_target_transition "$evid" || die "$EC_LXD" "FAIL_LXD_TARGET_TRANSITION_RESELECTED"
    scan_package_maintainer_network_risk "$evid" || die "$EC_LXD" "FAIL_PACKAGE_MAINTAINER_NETWORK_RISK"
    return 0
  fi

  set +e
  lxd_run_with_heartbeat LXD_REMOVAL_EXEC "${evid}/removal.out" "${evid}/removal.err" -- \
    env DEBIAN_FRONTEND=noninteractive apt-get -y remove $LXD_REMOVAL_TARGETS
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    log ERROR "LXD_REMOVAL_RESULT=FAIL"
    die "$EC_LXD" "FAIL_LXD_REMOVAL_EXEC"
  fi
  log INFO "LXD_REMOVAL_RESULT=PASS"
  log INFO "LXD_REMOVAL_PACKAGE=lxd"
  log INFO "LXD_REMOVAL_PACKAGE=lxd-client"

  set +e
  dpkg --audit >"${evid}/dpkg-audit.txt" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    log ERROR "LXD_POST_REMOVAL_DPKG_AUDIT=FAIL"
    die "$EC_LXD" "FAIL_LXD_POST_REMOVAL_DPKG_AUDIT"
  fi
  log INFO "LXD_POST_REMOVAL_DPKG_AUDIT=PASS"

  set +e
  apt-get check >"${evid}/apt-check.txt" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    log ERROR "LXD_POST_REMOVAL_APT_CHECK=FAIL"
    die "$EC_LXD" "FAIL_LXD_POST_REMOVAL_APT_CHECK"
  fi
  log INFO "LXD_POST_REMOVAL_APT_CHECK=PASS"

  apply_lxd_noinstall_pin
  guard_lxd_target_transition "$evid" || die "$EC_LXD" "FAIL_LXD_TARGET_TRANSITION_RESELECTED"
  scan_package_maintainer_network_risk "$evid" || die "$EC_LXD" "FAIL_PACKAGE_MAINTAINER_NETWORK_RISK"
  return 0
}

classify_lxd_snap_transition_failure() {
  # Return 0 if logs show Focal transitional lxd → Snap Store failure.
  local mainlog aptlog dpkglog
  mainlog="$(_hp /var/log/dist-upgrade/main.log)"
  aptlog="$(_hp /var/log/dist-upgrade/apt.log)"
  dpkglog="$(_hp /var/log/dpkg.log)"
  if grep -qiE 'api\.snapcraft\.io|Installing the LXD snap|cannot install "lxd"|snap store' \
      "$LOG_FILE" "$mainlog" "$aptlog" "$dpkglog" 2>/dev/null; then
    return 0
  fi
  if grep -qiE 'lxd.*pre-installation script|new lxd package pre-installation' \
      "$LOG_FILE" "$dpkglog" 2>/dev/null \
    && grep -qiE 'snap' "$LOG_FILE" "$dpkglog" 2>/dev/null; then
    return 0
  fi
  return 1
}

emit_lxd_snap_failure_fields() {
  FAILURE_CLASS="OFFLINE_LXD_SNAP_TRANSITION"
  log ERROR "FAILURE_CLASS=OFFLINE_LXD_SNAP_TRANSITION"
  log ERROR "FAILURE_PACKAGE=lxd,lxd-client"
  log ERROR "FAILURE_EXTERNAL_ENDPOINT=api.snapcraft.io"
  log ERROR "FAILURE_STAGE=PACKAGE_TRANSACTION"
  log ERROR "FAILURE_RETRY_SAFE=NO"
  log ERROR "FAILURE_RESTORE_REQUIRED=YES"
}
