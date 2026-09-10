#!/usr/bin/env bash
# Lightweight post-bringup cluster validation / operator confirmation.
# shellcheck shell=bash
# BRINGUP_RESULT=PASS is process success only — never DP_UPGRADE_COMPLETE.

CLUSTER_VALIDATION_ENV_DEFAULT="${CLUSTER_VALIDATION_ENV_DEFAULT:-/opt/aelladata/os-upgrade/offline/phase2-bringup/cluster-validation.env}"

p2b_cluster_validation_env_path() {
  printf '%s' "${CLUSTER_VALIDATION_ENV:-${CLUSTER_VALIDATION_ENV_DEFAULT}}"
}

p2b_emit_mtu_warning() {
  local line iface mtu warned=0
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
      echo "WARNING: iface=${iface} uses jumbo MTU=${mtu}; intermediate switching/path MTU must support it before Phase 2 bringup"
      warned=1
    fi
  done
  # Note: warned in subshell; always emit advisory footer.
  echo "PHASE2_MTU_PREFLIGHT=DONE"
  echo "PHASE2_MTU_HARD_FAIL=NO"
  return 0
}

p2b_run_cluster_validation_surface() {
  # Collect vendor-native status surfaces for operator review. Does not invent
  # a new definition of cluster health. Returns 0 after emitting evidence.
  local cli="${AELLA_CLI_PATH:-}"
  echo "CLUSTER_VALIDATION_SURFACE=START"
  if [[ -z "$cli" ]] && declare -F p2b_discover_aella_cli >/dev/null 2>&1; then
    p2b_discover_aella_cli || true
    cli="${AELLA_CLI_PATH:-}"
  fi
  if [[ -n "$cli" && -x "$cli" ]]; then
    echo "CLUSTER_CHECK=aella_cli_show_status"
    # Prefer non-interactive pipe into aella_cli when available.
    if [[ -n "${DP_PHASE2_FAKE_AELLA_STATUS:-}" ]]; then
      printf '%s\n' "${DP_PHASE2_FAKE_AELLA_STATUS}"
    else
      printf 'show status\n' | "$cli" 2>/dev/null || echo "AELLA_CLI_SHOW_STATUS=UNAVAILABLE"
    fi
  else
    echo "CLUSTER_CHECK=aella_cli_show_status"
    echo "AELLA_CLI_SHOW_STATUS=UNAVAILABLE"
  fi
  for cmd in "kubectl get nodes" "kubectl get pods -A" "helm list -A"; do
    echo "CLUSTER_CHECK=${cmd// /_}"
    if [[ -n "${DP_PHASE2_FAKE_K8S:-}" ]]; then
      printf '%s\n' "${DP_PHASE2_FAKE_K8S}"
    elif command -v "${cmd%% *}" >/dev/null 2>&1; then
      # shellcheck disable=SC2086
      $cmd 2>/dev/null || echo "CLUSTER_CHECK_RESULT=UNAVAILABLE"
    else
      echo "CLUSTER_CHECK_RESULT=COMMAND_MISSING"
    fi
  done
  echo "CLUSTER_VALIDATION_SURFACE=DONE"
  echo "CLUSTER_VALIDATION=PENDING"
  echo "DP_UPGRADE_COMPLETE=NO"
  echo "NEXT_ACTION=Review aella_cli show status / kubectl / helm output; then record PASS with --record-cluster-validation PASS only when the cluster is ready"
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
