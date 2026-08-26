#!/usr/bin/env bash
# Full Phase 2 client helper unit publication + helper-only refresh invariants.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HTTP_PID=""
cleanup() {
  if [[ -n "$HTTP_PID" ]]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

DEST_ROOT="${TMP}/client"
READY_PATH="${TMP}/READY"
DP_PHASE2_ROOT="${TMP}/dp-phase2"
TARGET_DP_VERSION=6.6.0
mkdir -p "$DEST_ROOT" \
  "${DP_PHASE2_ROOT}/${TARGET_DP_VERSION}/current" \
  "$(dirname "$READY_PATH")"

printf 'READY_FIXTURE\n' >"$READY_PATH"
READY_HASH="$(sha256sum "$READY_PATH" | awk '{print $1}')"
BUNDLE="${DP_PHASE2_ROOT}/${TARGET_DP_VERSION}/current/dp_bundle_${TARGET_DP_VERSION}-current.tar"
# Small fixture bundle (not 30GB).
printf 'bundle-fixture\n' >"$BUNDLE"
ln -sfn "${DP_PHASE2_ROOT}/${TARGET_DP_VERSION}/current" \
  "${DP_PHASE2_ROOT}/${TARGET_DP_VERSION}/current-link" 2>/dev/null || true
# deploy helpers-only expects CURRENT symlink/dir + release.env
CURRENT="${DP_PHASE2_ROOT}/${TARGET_DP_VERSION}/current"
cat >"${CURRENT}/release.env" <<EOF
TARGET_DP_VERSION=${TARGET_DP_VERSION}
PHASE2_ARTIFACT_VERSION=${TARGET_DP_VERSION}
DP_PHASE2_VERSION=${TARGET_DP_VERSION}
STABLE_BUNDLE_NAME=dp_bundle_${TARGET_DP_VERSION}-current.tar
VERIFICATION_RESULT=PASS
EOF
chmod 0644 "${CURRENT}/release.env"
BUNDLE_STAT_BEFORE="$(stat -c '%i %s' "$(readlink -f "$BUNDLE")")"
BUNDLE_HASH_BEFORE="$(sha256sum "$(readlink -f "$BUNDLE")" | awk '{print $1}')"
CURRENT_BEFORE="$(readlink -f "$CURRENT")"

PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)"
# Serve DEST_ROOT parent so /client/... maps correctly.
HTTP_ROOT="$TMP"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$HTTP_ROOT" \
  >"${TMP}/http.log" 2>&1 &
HTTP_PID=$!
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && break
  sleep 0.1
done

export DEST_ROOT READY_PATH
export DP_PHASE2_SKIP_ROOT_CHECK=1
export SKIP_HTTP_VERIFY=1
export MIRROR_BASE="http://127.0.0.1:${PORT}"
export MIRROR_LOCAL="http://127.0.0.1:${PORT}"
export DP_PHASE2_ROOT
export TARGET_DP_VERSION
export RESOLVED_MIRROR_BASE_URL="http://127.0.0.1:${PORT}"

bash "${ROOT}/scripts/deploy-stage-dp-phase2-client-atomic.sh" >"${TMP}/deploy.out"

UNIT=(
  stage-dp-phase2.sh
  stage-dp-phase2.sh.sha256
  stage-dp-phase2-6.6.0.sh
  stage-dp-phase2-6.6.0.sh.sha256
  bringup_py3_dp_lifecycle.sh
  bringup_py3_dp_lifecycle.sh.sha256
  lib/dp-offline-source-product-version.sh
  lib/dp-phase2-operation-progress.sh
  lib/dp-phase2-bringup-lifecycle.sh
  lib/dp-phase2-ubuntu-prerequisites.sh
  phase2-helper-generation.manifest
  upgrade-phase2.sh
  upgrade-phase2.sh.sha256
)

for f in "${UNIT[@]}"; do
  [[ -f "${DEST_ROOT}/${f}" ]]
  [[ -s "${DEST_ROOT}/${f}" ]]
done
[[ "$(stat -c '%a' "${DEST_ROOT}/stage-dp-phase2.sh")" == "755" ]]
[[ "$(stat -c '%a' "${DEST_ROOT}/stage-dp-phase2.sh.sha256")" == "644" ]]
[[ "$(stat -c '%a' "${DEST_ROOT}/bringup_py3_dp_lifecycle.sh")" == "755" ]]
[[ "$(stat -c '%a' "${DEST_ROOT}/lib/dp-phase2-operation-progress.sh")" == "755" ]]

# No temp/partial leftovers.
! find "$DEST_ROOT" -name '*.tmp.*' | grep -q .

# HTTP 200 + SHA match for the required operator unit.
for f in \
  stage-dp-phase2.sh \
  stage-dp-phase2.sh.sha256 \
  bringup_py3_dp_lifecycle.sh \
  lib/dp-offline-source-product-version.sh \
  lib/dp-phase2-operation-progress.sh \
  lib/dp-phase2-bringup-lifecycle.sh \
  lib/dp-phase2-ubuntu-prerequisites.sh \
  phase2-helper-generation.manifest \
  upgrade-phase2.sh
do
  code="$(curl -sS -o "${TMP}/http-${f////_}" -w '%{http_code}' \
    "http://127.0.0.1:${PORT}/client/${f}")"
  [[ "$code" == "200" ]]
  fs_sha="$(sha256sum "${DEST_ROOT}/${f}" | awk '{print $1}')"
  http_sha="$(sha256sum "${TMP}/http-${f////_}" | awk '{print $1}')"
  [[ "$fs_sha" == "$http_sha" ]]
done

echo "PHASE2_FULL_CLIENT_UNIT_PUBLISH=PASS"

# Helper-only refresh must not touch READY / bundle / current.
# Seed an older helper content marker, then redeploy from canonical sources.
printf 'OLD_HELPER\n' >"${DEST_ROOT}/lib/dp-phase2-operation-progress.sh"
OLD_HELPER_SHA="$(sha256sum "${DEST_ROOT}/lib/dp-phase2-operation-progress.sh" | awk '{print $1}')"

# Metadata-only path still verifies; full helper-only redeploy via atomic script.
bash "${ROOT}/scripts/deploy-stage-dp-phase2-client-atomic.sh" >"${TMP}/redeploy.out"
NEW_HELPER_SHA="$(sha256sum "${DEST_ROOT}/lib/dp-phase2-operation-progress.sh" | awk '{print $1}')"
[[ "$NEW_HELPER_SHA" != "$OLD_HELPER_SHA" ]]
[[ "$(sha256sum "$READY_PATH" | awk '{print $1}')" == "$READY_HASH" ]]
[[ "$(stat -c '%i %s' "$(readlink -f "$BUNDLE")")" == "$BUNDLE_STAT_BEFORE" ]]
[[ "$(sha256sum "$(readlink -f "$BUNDLE")" | awk '{print $1}')" == "$BUNDLE_HASH_BEFORE" ]]
[[ "$(readlink -f "$CURRENT")" == "$CURRENT_BEFORE" ]]

echo "PHASE2_HELPER_ONLY_REFRESH_INVARIANTS=PASS"
