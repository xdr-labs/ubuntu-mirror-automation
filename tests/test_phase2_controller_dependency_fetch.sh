#!/usr/bin/env bash
# Regression: Phase 2 extraction prefetches the complete bringup controller unit
# when an older Menu 7 command downloaded only the stage/source/progress files.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROGRESS="${ROOT}/client/lib/dp-phase2-operation-progress.sh"
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

export DP_PHASE2_HEARTBEAT_SECONDS=1
# shellcheck source=/dev/null
source "$PROGRESS"

HTTP_ROOT="${TMP}/http"
CLIENT_ROOT="${HTTP_ROOT}/client"
WORK_ROOT="${TMP}/work"
mkdir -p "${CLIENT_ROOT}/lib" "${WORK_ROOT}/lib" "${TMP}/extract"

cat >"${CLIENT_ROOT}/bringup_py3_dp_lifecycle.sh" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/dp-phase2-bringup-lifecycle.sh"
WRAPPER
cat >"${CLIENT_ROOT}/lib/dp-phase2-bringup-lifecycle.sh" <<'LIB'
#!/usr/bin/env bash
set -euo pipefail
phase2_lifecycle_test_marker() { :; }
LIB
cat >"${CLIENT_ROOT}/lib/dp-offline-source-product-version.sh" <<'LIB'
#!/usr/bin/env bash
SOURCE_HELPER_LOADED=YES
LIB
cat >"${CLIENT_ROOT}/lib/dp-phase2-operation-progress.sh" <<'LIB'
#!/usr/bin/env bash
PROGRESS_HELPER_LOADED=YES
LIB
cat >"${CLIENT_ROOT}/lib/dp-phase2-ubuntu-prerequisites.sh" <<'LIB'
#!/usr/bin/env bash
PREREQ_HELPER_LOADED=YES
LIB
cat >"${CLIENT_ROOT}/lib/dp-phase2-time-readiness.sh" <<'LIB'
#!/usr/bin/env bash
TIME_HELPER_LOADED=YES
LIB
cat >"${CLIENT_ROOT}/lib/dp-phase2-post-bringup-migration.sh" <<'LIB'
#!/usr/bin/env bash
MIGRATION_HELPER_LOADED=YES
LIB
cat >"${CLIENT_ROOT}/lib/dp-phase2-cluster-validation.sh" <<'LIB'
#!/usr/bin/env bash
CLUSTER_HELPER_LOADED=YES
LIB
# Dummy stage script so the generation manifest can list the complete unit.
printf '#!/usr/bin/env bash\ntrue\n' >"${CLIENT_ROOT}/stage-dp-phase2.sh"
chmod +x "${CLIENT_ROOT}/stage-dp-phase2.sh" "${CLIENT_ROOT}/bringup_py3_dp_lifecycle.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/phase2_helper_generation.sh"
phase2_helper_generation_write "$CLIENT_ROOT" >/dev/null
cp -a "${CLIENT_ROOT}/phase2-helper-generation.manifest" \
  "${WORK_ROOT}/phase2-helper-generation.manifest"

PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$HTTP_ROOT" \
  >"${TMP}/http.log" 2>&1 &
HTTP_PID=$!
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:${PORT}/client/bringup_py3_dp_lifecycle.sh" \
    >/dev/null 2>&1 && break
  sleep 0.1
done

_STAGE_LIB_DIR="${WORK_ROOT}/lib"
MIRROR_URL="http://127.0.0.1:${PORT}"
export _STAGE_LIB_DIR MIRROR_URL

OUT="${TMP}/extract.out"
dp2_run_extract_with_progress phase2_tar_extract "${TMP}/extract" -- \
  bash -c 'printf extracted >"$1/payload.txt"' _ "${TMP}/extract" \
  >"$OUT" 2>&1

grep -q '^PHASE2_CONTROLLER_DEPENDENCY=DOWNLOAD path=bringup_py3_dp_lifecycle.sh$' "$OUT"
grep -q '^PHASE2_CONTROLLER_DEPENDENCY=DOWNLOAD path=lib/dp-phase2-bringup-lifecycle.sh$' "$OUT"
grep -q '^PHASE2_CONTROLLER_DEPENDENCY=DOWNLOAD path=lib/dp-offline-source-product-version.sh$' "$OUT"
grep -q '^PHASE2_CONTROLLER_DEPENDENCY=DOWNLOAD path=lib/dp-phase2-operation-progress.sh$' "$OUT"
grep -q '^PHASE2_CONTROLLER_DEPENDENCY=DOWNLOAD path=lib/dp-phase2-ubuntu-prerequisites.sh$' "$OUT"
grep -q '^PHASE2_CONTROLLER_DEPENDENCY=DOWNLOAD path=lib/dp-phase2-time-readiness.sh$' "$OUT"
grep -q '^PHASE2_CONTROLLER_DEPENDENCY=DOWNLOAD path=lib/dp-phase2-post-bringup-migration.sh$' "$OUT"
grep -q '^PHASE2_CONTROLLER_DEPENDENCY=DOWNLOAD path=lib/dp-phase2-cluster-validation.sh$' "$OUT"
grep -q '^PHASE2_CONTROLLER_DEPENDENCIES=PASS$' "$OUT"
grep -q '^OPERATION_END name=phase2_tar_extract rc=0 ' "$OUT"
test -s "${WORK_ROOT}/bringup_py3_dp_lifecycle.sh"
test -s "${WORK_ROOT}/lib/dp-phase2-bringup-lifecycle.sh"
test -s "${WORK_ROOT}/lib/dp-offline-source-product-version.sh"
test -s "${WORK_ROOT}/lib/dp-phase2-operation-progress.sh"
test -s "${WORK_ROOT}/lib/dp-phase2-ubuntu-prerequisites.sh"
test -s "${WORK_ROOT}/lib/dp-phase2-time-readiness.sh"
test -s "${WORK_ROOT}/lib/dp-phase2-post-bringup-migration.sh"
test -s "${WORK_ROOT}/lib/dp-phase2-cluster-validation.sh"
bash -n "${WORK_ROOT}/bringup_py3_dp_lifecycle.sh"
bash -n "${WORK_ROOT}/lib/dp-phase2-bringup-lifecycle.sh"
grep -q '^extracted$' "${TMP}/extract/payload.txt"

# A second run must reuse the local controller unit and avoid another download.
REUSE_OUT="${TMP}/reuse.out"
dp2_run_extract_with_progress phase2_tar_extract "${TMP}/extract" -- \
  bash -c 'printf reused >"$1/reused.txt"' _ "${TMP}/extract" \
  >"$REUSE_OUT" 2>&1
grep -q '^PHASE2_CONTROLLER_DEPENDENCY=REUSED path=bringup_py3_dp_lifecycle.sh$' "$REUSE_OUT"
grep -q '^PHASE2_CONTROLLER_DEPENDENCY=REUSED path=lib/dp-phase2-bringup-lifecycle.sh$' "$REUSE_OUT"
grep -q '^PHASE2_CONTROLLER_DEPENDENCY=REUSED path=lib/dp-offline-source-product-version.sh$' "$REUSE_OUT"
grep -q '^PHASE2_CONTROLLER_DEPENDENCY=REUSED path=lib/dp-phase2-operation-progress.sh$' "$REUSE_OUT"
grep -q '^PHASE2_CONTROLLER_DEPENDENCY=REUSED path=lib/dp-phase2-ubuntu-prerequisites.sh$' "$REUSE_OUT"
grep -q '^PHASE2_CONTROLLER_DEPENDENCY=REUSED path=lib/dp-phase2-time-readiness.sh$' "$REUSE_OUT"
grep -q '^PHASE2_CONTROLLER_DEPENDENCY=REUSED path=lib/dp-phase2-post-bringup-migration.sh$' "$REUSE_OUT"
grep -q '^PHASE2_CONTROLLER_DEPENDENCY=REUSED path=lib/dp-phase2-cluster-validation.sh$' "$REUSE_OUT"
grep -q '^reused$' "${TMP}/extract/reused.txt"

# Invalid controller payload must fail before extraction begins.
rm -f "${WORK_ROOT}/lib/dp-phase2-bringup-lifecycle.sh"
printf '<html>bad</html>\n' >"${CLIENT_ROOT}/lib/dp-phase2-bringup-lifecycle.sh"
FAIL_OUT="${TMP}/fail.out"
set +e
dp2_run_extract_with_progress phase2_tar_extract "${TMP}/extract" -- \
  bash -c 'printf should-not-run >"$1/invalid.txt"' _ "${TMP}/extract" \
  >"$FAIL_OUT" 2>&1
RC=$?
set -e
[[ "$RC" -eq 1 ]]
grep -q '^PHASE2_CONTROLLER_DEPENDENCY=FAIL path=lib/dp-phase2-bringup-lifecycle.sh reason=hash_mismatch$' "$FAIL_OUT"
grep -q '^OPERATION_END name=phase2_tar_extract rc=1 elapsed_seconds=0$' "$FAIL_OUT"
test ! -e "${TMP}/extract/invalid.txt"

echo 'PHASE2_CONTROLLER_DEPENDENCY_FETCH=PASS'
echo 'PHASE2_CONTROLLER_DEPENDENCY_REUSE=PASS'
echo 'PHASE2_CONTROLLER_DEPENDENCY_FAIL_CLOSED=PASS'
