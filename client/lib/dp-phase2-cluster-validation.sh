#!/usr/bin/env bash
# Lightweight post-bringup cluster validation / operator confirmation.
# shellcheck shell=bash
# BRINGUP_RESULT=PASS is process success only — never DP_UPGRADE_COMPLETE.

CLUSTER_VALIDATION_ENV_DEFAULT="${CLUSTER_VALIDATION_ENV_DEFAULT:-/opt/aelladata/os-upgrade/offline/phase2-bringup/cluster-validation.env}"
# Bounded wall-clock for non-interactive aella_cli show status (seconds).
P2B_AELLA_CLI_STATUS_TIMEOUT_SEC="${P2B_AELLA_CLI_STATUS_TIMEOUT_SEC:-45}"
# Extra grace after SIGTERM before SIGKILL (seconds).
P2B_AELLA_CLI_KILL_GRACE_SEC="${P2B_AELLA_CLI_KILL_GRACE_SEC:-3}"

p2b_cluster_validation_env_path() {
  printf '%s' "${CLUSTER_VALIDATION_ENV:-${CLUSTER_VALIDATION_ENV_DEFAULT}}"
}

p2b_emit_mtu_warning() {
  local line iface mtu
  echo "PHASE2_MTU_PREFLIGHT=START"
  if [[ -n "${DP_PHASE2_FAKE_IP_MTU:-}" ]]; then
    printf '%s\n' "${DP_PHASE2_FAKE_IP_MTU}"
  else
    ip -o link show 2>/dev/null || true
  fi | while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ mtu[[:space:]]+([0-9]+) ]] || continue
    mtu="${BASH_REMATCH[1]}"
    iface="$(printf '%s\n' "$line" | awk -F': ' '{print $2}' | awk '{print $1}')"
    [[ -n "$iface" ]] || continue
    case "$iface" in
      lo|docker*|br-*|veth*|flannel*|cni*|virbr*) continue ;;
    esac
    echo "INTERFACE_MTU iface=${iface} mtu=${mtu}"
    if [[ "$mtu" -gt 1500 ]]; then
      # Informational only — customer paths often use jumbo frames successfully.
      # Do not require MTU 1500, path-level jumbo ping, or Mirror Server MTU match.
      echo "WARNING: iface=${iface} uses jumbo MTU=${mtu} (informational; Phase 2 does not require changing it)"
    fi
  done
  echo "PHASE2_MTU_PREFLIGHT=DONE"
  echo "PHASE2_MTU_HARD_FAIL=NO"
  return 0
}

# Best-effort reap by PID and optional process group. Never blocks unbounded.
p2b_aella_cli_reap_pid() {
  local pid="${1-}" grace="${2:-${P2B_AELLA_CLI_KILL_GRACE_SEC}}"
  local waited=0 pgid=""
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 0
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    if [[ -n "$pgid" && "$pgid" =~ ^[0-9]+$ ]]; then
      kill -TERM -- "-${pgid}" 2>/dev/null || true
    fi
    while kill -0 "$pid" 2>/dev/null; do
      if [[ "$waited" -ge "$grace" ]]; then
        kill -KILL "$pid" 2>/dev/null || true
        if [[ -n "$pgid" && "$pgid" =~ ^[0-9]+$ ]]; then
          kill -KILL -- "-${pgid}" 2>/dev/null || true
        fi
        break
      fi
      sleep 1
      waited=$((waited + 1))
    done
  fi
  wait "$pid" 2>/dev/null || true
  return 0
}

# Non-interactive aella_cli show status.
#
# ROOT CAUSE (Real E2E): piping only "show status\n" closes stdin. Python
# cmd.Cmd-style aella_cli converts the next EOFError into the literal command
# string "EOF", prints "*** Unknown syntax: EOF", and loops forever.
#
# Contract:
# - Never send the literal token "EOF" on stdin.
# - Always send an explicit quit after show status.
# - Bound wall-clock; reap children on timeout/signal.
# - Failure to terminate is an explicit validation failure, not a hang.
p2b_aella_cli_show_status_bounded() {
  local cli="${1-}"
  local timeout_sec="${2:-${P2B_AELLA_CLI_STATUS_TIMEOUT_SEC}}"
  local outf errf pidfile
  local cli_pid="" rc=0 timed_out=0
  local output="" unknown_eof=0 orphan_left=0
  local grace="${P2B_AELLA_CLI_KILL_GRACE_SEC}"

  [[ -n "$cli" && -x "$cli" ]] || {
    echo "AELLA_CLI_SHOW_STATUS=UNAVAILABLE"
    echo "AELLA_CLI_EXIT_REASON=CLI_MISSING"
    return 1
  }
  [[ "$timeout_sec" =~ ^[0-9]+$ && "$timeout_sec" -gt 0 ]] || timeout_sec=45
  [[ "$grace" =~ ^[0-9]+$ && "$grace" -gt 0 ]] || grace=3

  outf="$(mktemp)"
  errf="$(mktemp)"
  pidfile="$(mktemp)"

  # shellcheck disable=SC2064
  trap 'p2b_aella_cli_reap_pid "$(cat "'"$pidfile"'" 2>/dev/null || true)" 1; rm -f "'"$outf"'" "'"$errf"'" "'"$pidfile"'"; trap - INT TERM' INT TERM

  # Critical stdin contract: "show status" then "quit".
  # Never rely on pipe-close. Never write the characters EOF as a command.
  # GNU timeout --kill-after bounds hung CLIs that ignore SIGTERM.
  local prev_e=0
  [[ $- == *e* ]] && prev_e=1
  set +e
  printf 'show status\nquit\n' \
    | timeout --kill-after="${grace}" "${timeout_sec}" \
        bash -c 'printf "%s\n" "$$" >"$1"; exec "$2"' _ "$pidfile" "$cli" \
        >"$outf" 2>"$errf"
  rc=$?
  [[ "$prev_e" -eq 1 ]] && set -e

  cli_pid="$(cat "$pidfile" 2>/dev/null || true)"
  output="$(cat "$outf" "$errf" 2>/dev/null || true)"
  printf '%s\n' "$output"

  if printf '%s\n' "$output" | grep -qE '\*\*\* Unknown syntax:[[:space:]]*EOF'; then
    unknown_eof=1
  fi

  # timeout returns 124 on wall-clock expiry (before kill-after SIGKILL).
  if [[ "$rc" -eq 124 ]]; then
    timed_out=1
  fi

  # Reap anything still alive (Ctrl-C path, ignored signals, etc.).
  if [[ -n "$cli_pid" ]] && kill -0 "$cli_pid" 2>/dev/null; then
    orphan_left=1
    p2b_aella_cli_reap_pid "$cli_pid" "$grace"
  fi
  # Also reap by matching executable name under this session if pidfile missed.
  if [[ -n "$cli_pid" ]] && kill -0 "$cli_pid" 2>/dev/null; then
    orphan_left=1
    p2b_aella_cli_reap_pid "$cli_pid" 1
  fi

  rm -f "$outf" "$errf" "$pidfile"
  trap - INT TERM

  if [[ "$unknown_eof" -eq 1 ]]; then
    echo "AELLA_CLI_SHOW_STATUS=FAIL"
    echo "AELLA_CLI_EXIT_REASON=LITERAL_EOF_COMMAND"
    echo "AELLA_CLI_EOF_LOOP=DETECTED"
    echo "ERROR: aella_cli received literal EOF as a command (stdin lifecycle bug)"
    return 2
  fi
  if [[ "$timed_out" -eq 1 ]]; then
    echo "AELLA_CLI_SHOW_STATUS=FAIL"
    echo "AELLA_CLI_EXIT_REASON=TIMEOUT"
    echo "AELLA_CLI_TIMEOUT_SEC=${timeout_sec}"
    echo "ERROR: aella_cli show status exceeded ${timeout_sec}s; child process reaped"
    return 3
  fi
  if [[ "$orphan_left" -eq 1 ]]; then
    if [[ -n "$cli_pid" ]] && kill -0 "$cli_pid" 2>/dev/null; then
      echo "AELLA_CLI_SHOW_STATUS=FAIL"
      echo "AELLA_CLI_EXIT_REASON=ORPHAN_REMAINING"
      echo "ERROR: aella_cli still alive after reap attempts"
      return 4
    fi
    echo "AELLA_CLI_CHILD_REAPED=YES"
  fi
  # timeout uses 137 for SIGKILL in some versions; >128 means signalled.
  if [[ "$rc" -gt 128 ]]; then
    echo "AELLA_CLI_SHOW_STATUS=FAIL"
    echo "AELLA_CLI_EXIT_REASON=SIGNAL"
    echo "AELLA_CLI_WAIT_STATUS=${rc}"
    return 5
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "AELLA_CLI_SHOW_STATUS=FAIL"
    echo "AELLA_CLI_EXIT_REASON=NONZERO_EXIT"
    echo "AELLA_CLI_EXIT_CODE=${rc}"
    return 6
  fi
  echo "AELLA_CLI_SHOW_STATUS=OK"
  echo "AELLA_CLI_EXIT_REASON=CLEAN_QUIT"
  return 0
}

# Parse aella_cli show status text into operator-facing signals.
# Does NOT auto-PASS cluster validation. Pod "at least N expected" is
# informational — field E2E showed healthy DP with 52/54 and missing
# role-dependent pods while Web UI / show version remained operational.
p2b_analyze_aella_status_text() {
  local text="${1-}"
  local paused=NO
  local nodes_ready=NO
  local host_services_ready=NO
  local license_valid=NO
  local indices_ready=NO
  local models_ready=NO
  local provision_ready=NO
  local critical_fail=NO
  local pods_line=""
  local missing_pods=""
  local authoritative_ready=NO

  if printf '%s\n' "$text" | grep -qiE 'System paused\.[[:space:]]*Type resume'; then
    paused=YES
  fi
  if printf '%s\n' "$text" | grep -qiE 'All cluster nodes are ready'; then
    nodes_ready=YES
  fi
  if printf '%s\n' "$text" | grep -qiE 'All host services are ready'; then
    host_services_ready=YES
  fi
  if printf '%s\n' "$text" | grep -qiE 'License is valid'; then
    license_valid=YES
  fi
  if printf '%s\n' "$text" | grep -qiE 'All[[:space:]]+[0-9]+[[:space:]]+indices ready'; then
    indices_ready=YES
  fi
  if printf '%s\n' "$text" | grep -qiE 'All DGA models are ready'; then
    models_ready=YES
  fi
  if printf '%s\n' "$text" | grep -qiE 'Provision service is ready'; then
    provision_ready=YES
  fi
  if printf '%s\n' "$text" | grep -qiE 'CRITICAL|FATAL|Bringup failed|License is (invalid|expired)'; then
    critical_fail=YES
  fi

  pods_line="$(printf '%s\n' "$text" | grep -E '[0-9]+ pods running, at least [0-9]+ expected' | head -n1 || true)"
  missing_pods="$(printf '%s\n' "$text" | grep -E '^Missing pods:' | head -n1 || true)"

  echo "CLUSTER_STATUS_PAUSED=${paused}"
  echo "CLUSTER_SIGNAL_NODES_READY=${nodes_ready}"
  echo "CLUSTER_SIGNAL_HOST_SERVICES_READY=${host_services_ready}"
  echo "CLUSTER_SIGNAL_LICENSE_VALID=${license_valid}"
  echo "CLUSTER_SIGNAL_INDICES_READY=${indices_ready}"
  echo "CLUSTER_SIGNAL_MODELS_READY=${models_ready}"
  echo "CLUSTER_SIGNAL_PROVISION_READY=${provision_ready}"
  echo "CLUSTER_SIGNAL_CRITICAL_FAIL=${critical_fail}"
  if [[ -n "$pods_line" ]]; then
    echo "CLUSTER_SIGNAL_PODS_LINE=${pods_line}"
  fi
  if [[ -n "$missing_pods" ]]; then
    echo "CLUSTER_SIGNAL_MISSING_PODS=${missing_pods}"
  fi
  echo "CLUSTER_SIGNAL_POD_COUNT_IS_HARD_GATE=NO"

  if [[ "$paused" == "YES" ]]; then
    echo "CLUSTER_STATUS_SUMMARY=PAUSED"
    echo "OPERATOR_ACTION_REQUIRED=YES"
    echo "OPERATOR_NEXT_STEP=Run: sudo /usr/bin/aella_cli   then inside CLI: resume"
    echo "OPERATOR_NEXT_STEP_AFTER_RESUME=Wait for services; re-run --validate-cluster; do not record PASS while paused"
    echo "CLUSTER_VALIDATION_RECORDABLE_PASS=NO"
    return 0
  fi

  if [[ "$critical_fail" == "YES" ]]; then
    echo "CLUSTER_STATUS_SUMMARY=CRITICAL_SIGNAL"
    echo "CLUSTER_VALIDATION_RECORDABLE_PASS=NO"
    return 0
  fi

  if [[ "$nodes_ready" == "YES" \
    && "$host_services_ready" == "YES" \
    && "$license_valid" == "YES" ]]; then
    authoritative_ready=YES
  fi

  if [[ "$authoritative_ready" == "YES" ]]; then
    echo "CLUSTER_STATUS_SUMMARY=AUTHORITATIVE_SIGNALS_PRESENT"
    echo "CLUSTER_VALIDATION_RECORDABLE_PASS=OPERATOR_JUDGEMENT"
    echo "OPERATOR_NOTE=Pod count 'at least N expected' is informational; missing role-dependent pods alone do not force FAIL when nodes/host services/license readiness signals are present"
  else
    echo "CLUSTER_STATUS_SUMMARY=NOT_READY_OR_INCOMPLETE"
    echo "CLUSTER_VALIDATION_RECORDABLE_PASS=NO"
    echo "OPERATOR_NEXT_STEP=Inspect show status; if paused, resume; then re-run --validate-cluster"
  fi
  return 0
}

p2b_emit_validate_cluster_operator_guidance() {
  local wrapper="${P2B_WRAPPER_PATH:-/home/aella/bringup_py3_dp_after_os_upgrade.sh}"
  cat <<EOF
OPERATOR_SEQUENCE=START
1) Bringup process success is separate from cluster readiness and upgrade complete.
2) If CLUSTER_STATUS_PAUSED=YES:
     sudo /usr/bin/aella_cli
     # then inside aella_cli:
     resume
     show status
3) After services start (or if not paused), re-check:
     sudo bash ${wrapper} --validate-cluster
4) If POST_BRINGUP_MIGRATION=REQUIRED (6.2/6.3/6.4 → target), run the vendor
   migration manually (never auto-executed by this wrapper), then:
     sudo bash ${wrapper} --record-post-bringup-migration PASS
5) Record cluster PASS only when authoritative readiness signals look healthy
   AND the DP is not paused (pod 'at least N expected' is not a hard gate):
     sudo bash ${wrapper} --record-cluster-validation PASS
6) DP_UPGRADE_COMPLETE=YES only when bringup PASS + migration NOT_REQUIRED|PASS
   + CLUSTER_VALIDATION=PASS.
OPERATOR_SEQUENCE=END
DP_RESUME_AUTOMATIC=NO
CLUSTER_VALIDATION_AUTO_PASS=NO
EOF
}

p2b_run_cluster_validation_surface() {
  # Collect vendor-native status surfaces for operator review. Does not invent
  # a new definition of cluster health. Returns 0 after emitting evidence unless
  # the aella_cli driver itself fails (EOF-loop / timeout / orphan).
  local cli="${AELLA_CLI_PATH:-}"
  local admin_kubeconfig="${DP_PHASE2_ADMIN_KUBECONFIG:-/etc/kubernetes/admin.conf}"
  local kubectl_env=()
  local status_rc=0
  local status_text=""
  local tmp_status=""

  echo "CLUSTER_VALIDATION_SURFACE=START"
  if [[ -z "$cli" ]] && declare -F p2b_discover_aella_cli >/dev/null 2>&1; then
    p2b_discover_aella_cli || true
    cli="${AELLA_CLI_PATH:-}"
  fi
  if [[ -n "$cli" && -x "$cli" ]]; then
    echo "CLUSTER_CHECK=aella_cli_show_status"
    if [[ -n "${DP_PHASE2_FAKE_AELLA_STATUS:-}" ]]; then
      # Test/fake path still runs analysis + guidance; stdin lifecycle is covered
      # by dedicated fake CLIs that exercise p2b_aella_cli_show_status_bounded.
      printf '%s\n' "${DP_PHASE2_FAKE_AELLA_STATUS}"
      status_text="${DP_PHASE2_FAKE_AELLA_STATUS}"
      echo "AELLA_CLI_SHOW_STATUS=OK"
      echo "AELLA_CLI_EXIT_REASON=FAKE_STATUS"
    else
      tmp_status="$(mktemp)"
      local prev_e=0
      [[ $- == *e* ]] && prev_e=1
      set +e
      p2b_aella_cli_show_status_bounded "$cli" "${P2B_AELLA_CLI_STATUS_TIMEOUT_SEC}" >"$tmp_status"
      status_rc=$?
      [[ "$prev_e" -eq 1 ]] && set -e
      cat "$tmp_status"
      status_text="$(cat "$tmp_status")"
      rm -f "$tmp_status"
      if [[ "$status_rc" -ne 0 ]]; then
        echo "CLUSTER_VALIDATION=PENDING"
        echo "DP_UPGRADE_COMPLETE=NO"
        echo "CLUSTER_VALIDATION_SURFACE=FAIL"
        echo "NEXT_ACTION=aella_cli status collection failed (see AELLA_CLI_EXIT_REASON); bringup state is unchanged; fix/retry --validate-cluster"
        p2b_emit_validate_cluster_operator_guidance
        return "$status_rc"
      fi
    fi
    p2b_analyze_aella_status_text "$status_text"
  else
    echo "CLUSTER_CHECK=aella_cli_show_status"
    echo "AELLA_CLI_SHOW_STATUS=UNAVAILABLE"
    echo "AELLA_CLI_EXIT_REASON=CLI_MISSING"
  fi
  if [[ -n "${DP_PHASE2_FAKE_K8S:-}" ]]; then
    :
  elif [[ -f "$admin_kubeconfig" ]]; then
    # Vendor procedures use admin.conf explicitly. Do not mutate the caller's
    # kubeconfig; only prefix the read-only kubectl/helm validation surface.
    kubectl_env=(env "KUBECONFIG=${admin_kubeconfig}")
    echo "CLUSTER_VALIDATION_KUBECONFIG=${admin_kubeconfig}"
  else
    echo "CLUSTER_VALIDATION_KUBECONFIG_MISSING=${admin_kubeconfig}"
  fi
  for cmd in "kubectl get nodes" "kubectl get pods -A" "helm list -A"; do
    echo "CLUSTER_CHECK=${cmd// /_}"
    if [[ -n "${DP_PHASE2_FAKE_K8S:-}" ]]; then
      printf '%s\n' "${DP_PHASE2_FAKE_K8S}"
    elif [[ "${#kubectl_env[@]}" -eq 0 && ! -f "$admin_kubeconfig" ]]; then
      echo "CLUSTER_CHECK_RESULT=ADMIN_KUBECONFIG_MISSING path=${admin_kubeconfig}"
    elif command -v "${cmd%% *}" >/dev/null 2>&1; then
      # shellcheck disable=SC2086
      "${kubectl_env[@]}" $cmd 2>/dev/null || echo "CLUSTER_CHECK_RESULT=UNAVAILABLE"
    else
      echo "CLUSTER_CHECK_RESULT=COMMAND_MISSING"
    fi
  done
  echo "CLUSTER_VALIDATION_SURFACE=DONE"
  echo "CLUSTER_VALIDATION=PENDING"
  echo "DP_UPGRADE_COMPLETE=NO"
  p2b_emit_validate_cluster_operator_guidance
  echo "NEXT_ACTION=Review signals above; record PASS with --record-cluster-validation PASS only when not paused and authoritative readiness looks healthy"
  return 0
}

p2b_record_cluster_validation() {
  local result="${1-}" dest
  case "$result" in
    PASS|FAIL|PENDING) ;;
    *)
      echo "ERROR: --record-cluster-validation requires PASS, FAIL, or PENDING" >&2
      return 1
      ;;
  esac
  dest="$(p2b_cluster_validation_env_path)"
  mkdir -p "$(dirname "$dest")"
  {
    echo "CLUSTER_VALIDATION=${result}"
    echo "CLUSTER_VALIDATION_RECORDED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"${dest}.tmp.$$"
  chmod 0600 "${dest}.tmp.$$" 2>/dev/null || true
  mv -f "${dest}.tmp.$$" "$dest"
  CLUSTER_VALIDATION="$result"
  echo "CLUSTER_VALIDATION=${result}"
  if [[ "$result" != "PASS" ]]; then
    echo "DP_UPGRADE_COMPLETE=NO"
  fi
  return 0
}

p2b_load_cluster_validation() {
  local dest
  dest="$(p2b_cluster_validation_env_path)"
  CLUSTER_VALIDATION="${CLUSTER_VALIDATION:-PENDING}"
  [[ -f "$dest" ]] || return 1
  CLUSTER_VALIDATION="$(awk -F= '$1=="CLUSTER_VALIDATION"{print substr($0,index($0,"=")+1);exit}' "$dest" 2>/dev/null || echo PENDING)"
  return 0
}
