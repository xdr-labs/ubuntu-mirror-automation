#!/usr/bin/env bash
# Hermetic tests of audit fixes. No package changes, vendor bringup or network.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
source "$ROOT/client/lib/dp-phase2-cluster-validation.sh"
assert_status() {
  local label="$1" expected="$2" value="$3" result
  result="$(p2b_analyze_aella_status_text "$value")"
  grep -qx "CLUSTER_RUNTIME_READINESS=$expected" <<<"$result" || {
    echo "FAIL status $label expected $expected" >&2; exit 1;
  }
  if [[ "$expected" == NOT_READY ]]; then
    grep -qx 'CLUSTER_VALIDATION_RECORDABLE_PASS=NO' <<<"$result"
  fi
  echo "PASS status $label"
}
healthy=$'DataProcessor(DL-master)> show status\nAll cluster nodes are ready\nAll host services are ready\nLicense is valid\nAll 23 indices ready'
assert_status healthy READY "$healthy"
assert_status healthy_da READY $'DataProcessor(DA-master)> show status\nAll cluster nodes are ready\nAll host services are ready\nSystem Ready'
# Some verified field outputs omit the CLI prompt. Preserve their readiness.
assert_status no_prompt READY $'All cluster nodes are ready\nAll host services are ready\nLicense is valid'
assert_status benign_alert_counter READY "$healthy"$'\nCritical alerts: 0'
assert_status benign_missing_pods READY "$healthy"$'\n52 pods running, at least 54 expected\nMissing pods: processor, zookeeper'
while IFS='|' read -r label line; do
  [[ -n "$label" ]] || continue
  assert_status "$label" NOT_READY "$healthy"$'\n'"$line"
done <<'CASES'
nodes_not_ready|Not all cluster nodes are ready
services_not_ready|Not all host services are ready
nodes_joined|1 out of 3 nodes joined
indices_recovering|20 out of 20 indices are still recovering
combined_nodes|Not all cluster nodes are ready, 1 out of 3 nodes joined
cluster_red|Cluster health: RED
cluster_yellow|Cluster health: YELLOW
indices_red|indices: 3 red
indices_yellow|indices: 3 yellow, 4 unassigned
some_indices|Some indices are recovering
some_services|Some host services are not ready
provision|Provision service not ready
warning_nodes|Warning: 2 nodes are not ready
license_invalid|License is invalid
fatal|FATAL: bringup failed
CASES

# Current-run worker status must be independently evidenced; local/AIO status
# keeps its historical completion output but cannot claim a cluster-wide PASS.
source "$ROOT/client/lib/dp-phase2-post-bringup-migration.sh"
POST_BRINGUP_MIGRATION=NOT_REQUIRED
p2b_load_post_bringup_migration() { :; }
p2b_dir() { echo "$T/lifecycle"; }
p2b_read_file() { if [[ -f "$1" ]]; then cat "$1"; fi; }
p2b_current_run_log_contains() { [[ -r "$1" ]] && grep -qx "$2" "$1"; }
mkdir -p "$T/lifecycle"
echo "$T/worker.log" > "$T/lifecycle/log-path"
assert_complete() {
  local label="$1" complete="$2" cluster="$3" worker="$4" out
  out="$(p2b_emit_completion_semantics YES PASS)"
  grep -qx "DP_UPGRADE_COMPLETE=$complete" <<<"$out" || { echo "FAIL completion $label"; exit 1; }
  grep -qx "DP_CLUSTER_UPGRADE_COMPLETE=$cluster" <<<"$out" || { echo "FAIL cluster $label"; exit 1; }
  grep -qx "DP_WORKER_READINESS=$worker" <<<"$out" || { echo "FAIL worker $label"; exit 1; }
  echo "PASS completion $label"
}
assert_complete local_only YES NO NOT_CHECKED
echo 'workers=192.0.2.10;standby=' > "$T/lifecycle/orchestration-topology"
assert_complete worker_unverified NO NO NOT_VERIFIED
echo 'WORKER_ORCHESTRATION=FAIL' > "$T/worker.log"
assert_complete worker_failed NO NO NOT_VERIFIED
echo 'WORKER_ORCHESTRATION=PASS' > "$T/worker.log"
assert_complete worker_verified YES YES PASS

# Directly execute each production template's pre-DRO rollback function with
# only the side-effecting helpers mocked. Verify failed restores are not PASS.
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  src="$ROOT/client/dp-offline-upgrade-$hop.sh.in"
  awk '/^runner_pre_dro_rollback\(\)/{inside=1} inside{print} inside&&/^}$/{exit}' "$src" > "$T/rollback.fn"
  [[ -s "$T/rollback.fn" ]]
  for failure in none apt shell; do
    (
      source "$T/rollback.fn"
      PRE_DRO_ROLLBACK_DONE=0
      dro_transaction_started() { return 1; }
      restore_critical_holds_pre_upgrade() { return 0; }
      restore_apt_sources_pre_upgrade() { [[ "$failure" != apt ]]; }
      restore_login_shells_pre_upgrade() { [[ "$failure" != shell ]]; }
      clear_runner_pid() { :; }
      log() { printf '%s %s\n' "$1" "$2" >> "$T/log"; }
      : > "$T/log"
      runner_pre_dro_rollback
      if [[ "$failure" == none ]]; then
        grep -qx 'INFO PRE_DRO_ROLLBACK_RESULT=PASS' "$T/log"
      else
        grep -qx 'ERROR PRE_DRO_ROLLBACK_RESULT=INCOMPLETE' "$T/log"
      fi
    ) || { echo "FAIL rollback $hop $failure" >&2; exit 1; }
  done
  echo "PASS rollback $hop"
done
echo 'TEST_CONSOLIDATED_AUDIT_BEHAVIORS=PASS'
