#!/usr/bin/env bash
# Hermetic regression for audit-confirmed false-ready, completed-topology
# reentry, and disappearance of per-hop DEBs after mirror readiness.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
source "$ROOT/client/lib/dp-phase2-cluster-validation.sh"

bad=$'DataProcessor(DL-master)> show status\nNot all cluster nodes are ready, 1 out of 3 nodes joined\nAll host services are ready\nLicense is valid\n20 out of 20 indices are still recovering'
result="$(p2b_analyze_aella_status_text "$bad")"
grep -qx 'CLUSTER_RUNTIME_READINESS=NOT_READY' <<<"$result"
grep -qx 'CLUSTER_VALIDATION_RECORDABLE_PASS=NO' <<<"$result"
grep -qx 'CLUSTER_SIGNAL_DEGRADED=YES' <<<"$result"
echo 'PASS: incomplete cluster cannot be READY'

# Even a complete snapshot plus an explicit degraded snapshot must fail closed.
mixed=$'DataProcessor(DL-master)> show status\nAll cluster nodes are ready\nAll host services are ready\nLicense is valid\nNot all cluster nodes are ready, 1 out of 3 nodes joined'
grep -qx 'CLUSTER_RUNTIME_READINESS=NOT_READY'   <<<"$(p2b_analyze_aella_status_text "$mixed")"
healthy=$'DataProcessor(DL-master)> show status\nAll cluster nodes are ready\nAll host services are ready\nLicense is valid\nAll 20 indices ready'
grep -qx 'CLUSTER_RUNTIME_READINESS=READY'   <<<"$(p2b_analyze_aella_status_text "$healthy")"
da=$'DataProcessor(DA-master)> show status\nAll cluster nodes are ready\nAll host services are ready\nSystem Ready'
grep -qx 'CLUSTER_RUNTIME_READINESS=READY'   <<<"$(p2b_analyze_aella_status_text "$da")"
echo 'PASS: healthy DL/DA and mixed-status protections'

export PHASE2_BRINGUP_DIR="$TMP/bringup"
export PHASE2_BRINGUP_LOG_DEFAULT="$TMP/bringup.log"
export PHASE2_BRINGUP_ALLOW_NONROOT=1
export BRINGUP_VENDOR_SCRIPT="$TMP/vendor.sh"
printf '#!/bin/bash\nexit 87\n' >"$BRINGUP_VENDOR_SCRIPT"
chmod 700 "$BRINGUP_VENDOR_SCRIPT"
mkdir -p "$PHASE2_BRINGUP_DIR"
printf 'COMPLETED\n' >"$PHASE2_BRINGUP_DIR/state"
printf 'run-audit\n' >"$PHASE2_BRINGUP_DIR/run-id"
printf '6.6.0\n' >"$PHASE2_BRINGUP_DIR/target-version"
printf '0\n' >"$PHASE2_BRINGUP_DIR/exit-code"
cat >"$PHASE2_BRINGUP_DIR/result.env" <<'EOF'
BRINGUP_RUN_ID=run-audit
BRINGUP_TERMINAL_STATE=COMPLETED
BRINGUP_RESULT=PASS
BRINGUP_EXIT_CODE=0
BRINGUP_COMPLETION_SENTINEL=PASS
EOF
printf 'workers=192.0.2.10;standby=\n' >"$PHASE2_BRINGUP_DIR/orchestration-topology"
wrapper="$ROOT/client/bringup_py3_dp_lifecycle.sh"
bash "$wrapper" --version 6.6.0 --worker-ips 192.0.2.10 --detach >"$TMP/same.out"
grep -qx 'BRINGUP_ALREADY_COMPLETED=YES' "$TMP/same.out"
if bash "$wrapper" --version 6.6.0 --worker-ips 192.0.2.11 --detach >"$TMP/different.out"; then
  echo 'FAIL: changed workers accepted' >&2; exit 1
fi
grep -qx 'ACTION=BLOCK_COMPLETED_TOPOLOGY_MISMATCH' "$TMP/different.out"
if bash "$wrapper" --version 6.6.0 --worker-ips 192.0.2.10 --standby 192.0.2.20 --detach >"$TMP/standby.out"; then
  echo 'FAIL: changed standby accepted' >&2; exit 1
fi
grep -qx 'BRINGUP_RETRY_BLOCKED=YES' "$TMP/standby.out"
rm "$PHASE2_BRINGUP_DIR/orchestration-topology"
if bash "$wrapper" --version 6.6.0 --worker-ips 192.0.2.10 --detach >"$TMP/legacy.out"; then
  echo 'FAIL: legacy topology incorrectly trusted' >&2; exit 1
fi
grep -qx 'FAILURE_REASON=COMPLETED_TOPOLOGY_UNVERIFIED_OR_CHANGED' "$TMP/legacy.out"
bash "$wrapper" --version 6.6.0 --detach >"$TMP/status.out"
grep -qx 'BRINGUP_ALREADY_COMPLETED=YES' "$TMP/status.out"
[[ "$(cat "$PHASE2_BRINGUP_DIR/state")" == 'COMPLETED' ]]
[[ ! -f "$PHASE2_BRINGUP_DIR/worker-password" ]]
echo 'PASS: completed bringup routing fail-closed without rerun'

export MM_SKIP_ROOT_CHECK=1 MM_MIRROR_ROOT="$TMP/mirror"   MM_SELECTIVE_ROOT="$TMP/mirror/selective"   MM_DP_PHASE2_ROOT="$TMP/mirror/dp-phase2"   MM_CLIENT_ROOT="$TMP/mirror/client" MM_CACHE_ROOT="$TMP/mirror/.install-cache"   MM_CONFIG_DIR="$TMP/etc" MM_STATUS_FILE="$TMP/etc/status" PREPARATION_MODE=FULL
mkdir -p "$MM_SELECTIVE_ROOT/state" "$MM_SELECTIVE_ROOT/ubuntu"   "$MM_SELECTIVE_ROOT/hops/xenial-to-bionic/ubuntu/pool/main/a"   "$MM_SELECTIVE_ROOT/hops/bionic-to-focal/ubuntu/pool/main/b"
printf 'selective_plan_checksum=%064d\ndiscovery_artifact_checksum=%064d\n' 0 0 >"$MM_SELECTIVE_ROOT/state/READY"
source "$ROOT/scripts/lib/mirror_manager_common.sh"
f1="$MM_SELECTIVE_ROOT/hops/xenial-to-bionic/ubuntu/pool/main/a/a.deb"
f2="$MM_SELECTIVE_ROOT/hops/bionic-to-focal/ubuntu/pool/main/b/b.deb"
printf 'a\n' >"$f1"; printf 'b\n' >"$f2"
before="$(mm_selective_pool_witness)"
legacy_fp="$(mm_selective_os_identity)"
[[ -n "$before" && "$before" == "$(mm_selective_pool_witness)" ]]
# Legacy Download receipt remains unchanged by the new pool check.
mm_status_get() { [[ "$1" == "READINESS_POOL_WITNESS" ]] && printf '%s' "$before"; }
mm_selective_pool_witness_current
rm "$f1"
after="$(mm_selective_pool_witness)"
[[ "$before" != "$after" ]] || { echo 'FAIL: hop1 removal unseen' >&2; exit 1; }
if mm_selective_pool_witness_current; then
  echo 'FAIL: stale pool witness accepted' >&2; exit 1
fi
[[ "$legacy_fp" == "$(mm_selective_os_identity)" ]] || {
  echo 'FAIL: legacy Download fingerprint invalidated' >&2; exit 1
}
rm "$f2"
[[ "$after" != "$(mm_selective_pool_witness)" ]] || {
  echo 'FAIL: hop2 removal unseen' >&2; exit 1;
}
echo 'PASS: per-hop pool witness detects removal without staling Download receipt'
