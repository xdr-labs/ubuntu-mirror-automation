#!/usr/bin/env bash
# Changing bytes inside an existing selective index file must invalidate
# artifact readiness identity without replacing ubuntu/ directory.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_SKIP_ROOT_CHECK=1
export MM_MIRROR_ROOT="$TMP/mirror"
export MM_SELECTIVE_ROOT="$TMP/mirror/selective"
export MM_DP_PHASE2_ROOT="$TMP/mirror/dp-phase2"
export MM_CLIENT_ROOT="$TMP/mirror/client"
export MM_CACHE_ROOT="$TMP/mirror/.install-cache"
export MM_CONFIG_DIR="$TMP/etc"
export MM_STATUS_FILE="$TMP/etc/status"
export PREPARATION_MODE=FULL
mkdir -p "$MM_CONFIG_DIR" "$MM_SELECTIVE_ROOT/ubuntu/dists/noble/main/binary-amd64" \
  "$MM_DP_PHASE2_ROOT/6.6.0" "$MM_CLIENT_ROOT"

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"

plan="$(python3 -c 'print("ab"*32)')"
disc="$(python3 -c 'print("cd"*32)')"
mkdir -p "${MM_SELECTIVE_ROOT}/state"
cat >"${MM_SELECTIVE_ROOT}/state/READY" <<EOF
READY
selective_plan_checksum=${plan}
plan_checksum=${plan}
discovery_artifact_checksum=${disc}
os_core_payload_manifest_sha256=${disc}
os_core_manifest_sha256=${plan}
EOF

idx="${MM_SELECTIVE_ROOT}/ubuntu/dists/noble/main/binary-amd64/Packages"
printf 'Package: hello\nVersion: 1.0\n' >"$idx"

before="$(mm_selective_os_identity)"
[[ -n "$before" ]] || { echo "FAIL empty identity"; exit 1; }

# Mutate bytes inside existing file; do not replace ubuntu/ directory.
printf 'Package: hello\nVersion: 1.0-evil\n' >"$idx"

after="$(mm_selective_os_identity)"
[[ "$before" != "$after" ]] || {
  echo "FAIL content change did not invalidate identity"
  echo "before=$before"
  echo "after=$after"
  exit 1
}

# Store fingerprint and confirm download completion identity drift signal
export TARGET_DP_VERSION=6.6.0
mm_phase2_paths
printf 'bundle\n' >"${MM_WF_PHASE2_BUNDLE}"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  x\n' \
  >"${MM_WF_PHASE2_SIDECAR}"
printf 'V=1\n' >"${MM_WF_PHASE2_RELEASE}"
fp1="$(mm_artifact_fingerprint)"
printf 'Package: hello\nVersion: 1.0-evil2\n' >"$idx"
fp2="$(mm_artifact_fingerprint)"
[[ "$fp1" != "$fp2" ]] || { echo "FAIL artifact fingerprint unchanged"; exit 1; }
echo "READINESS_STALE=YES"
echo "PASS test_selective_readiness_content_identity"
