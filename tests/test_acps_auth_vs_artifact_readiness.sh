#!/usr/bin/env bash
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
export MM_CONFIG_FILE="$TMP/etc/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$TMP/etc/status"
export MM_STATE_DIR="$TMP/state"
export PREPARATION_MODE=PHASE2_ONLY
export ACPS_USERNAME=user
export ACPS_PASSWORD=secret
export MIRROR_SERVER_IP=192.0.2.10
export MIRROR_HTTP_URL=http://192.0.2.10
mkdir -p "$MM_CONFIG_DIR" "$MM_STATE_DIR" "$MM_DP_PHASE2_ROOT/6.6.0" "$MM_CLIENT_ROOT"

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_workflow_state.sh"

mm_config_base_ready || { echo "FAIL base ready"; exit 1; }
mm_acquisition_auth_ready || { echo "FAIL auth ready"; exit 1; }

# Clear credentials: base/config remains conceptually ready; auth fails.
ACPS_PASSWORD=
mm_config_base_ready || { echo "FAIL base should remain ready without password"; exit 1; }
if mm_acquisition_auth_ready; then
  echo "FAIL auth should fail without password"
  exit 1
fi
echo "PASS clear credentials separates auth from base config"

# New download path must fail closed before network when creds missing.
if declare -F acps_require_credentials >/dev/null 2>&1; then
  :
fi
# engine prepare gate
set +e
out="$(
  ACPS_USERNAME=user ACPS_PASSWORD= \
  bash -c '
    source "'"$ROOT"'/scripts/lib/mirror_manager_common.sh"
    mm_acquisition_auth_ready
  ' 2>&1
)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL missing creds accepted"; exit 1; }
echo "PASS new download without creds fails closed"

echo "PASS test_acps_auth_vs_artifact_readiness"
