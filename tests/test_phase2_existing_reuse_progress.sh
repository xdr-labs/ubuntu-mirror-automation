#!/usr/bin/env bash
# tests/test_phase2_existing_reuse_progress.sh
# Sparse Phase 2 bundle fixture: heartbeat on first verify, cache HIT on second,
# metadata change forces full hash again. Heavy vs client planes noted.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
DP2="${ROOT}/scripts/lib/dp-phase2-common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
SHA_WRAP="${TMP}/bin"
LOG="${TMP}/assess.log"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$SHA_WRAP"
cat >"${SHA_WRAP}/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -f "${1:-}" ]]; then
  sz="$(stat -c%s "$1" 2>/dev/null || echo 0)"
  if [[ "$sz" -ge 4096 ]]; then
    sleep 2.5
  fi
fi
exec /usr/bin/sha256sum "$@"
EOF
chmod +x "${SHA_WRAP}/sha256sum"
export PATH="${SHA_WRAP}:${PATH}"

export MM_PROJECT_ROOT="$ROOT"
export MM_SKIP_ROOT_CHECK=1
export MM_MIRROR_ROOT="${TMP}/mirror"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_SELECTIVE_ROOT="${MM_MIRROR_ROOT}/selective"
export MM_CLIENT_ROOT="${MM_MIRROR_ROOT}/client"
export MM_STATE_ROOT="${TMP}/state"
export MM_CONFIG_DIR="${TMP}/config"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_LOG_FILE="${TMP}/mirror-manager.log"
export MM_LONG_STEP_HEARTBEAT_SEC=1
export TARGET_DP_VERSION=6.6.0
export PHASE2_TARGET_VERSION=6.6.0
mkdir -p "$MM_CACHE_ROOT" "$MM_SELECTIVE_ROOT" "$MM_CLIENT_ROOT" \
  "$MM_STATE_ROOT" "$MM_CONFIG_DIR"
: >"$MM_STATUS_FILE"
: >"$MM_LOG_FILE"

# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "$COMMON"
# shellcheck source=../scripts/lib/dp-phase2-common.sh
source "$DP2"
# shellcheck source=../scripts/lib/mirror_install_engine.sh
source "$ENGINE"

dp2_set_version 6.6.0

make_sparse_bundle() {
  local dest="${MM_DP_PHASE2_ROOT}/6.6.0"
  local stable="dp_bundle_6.6.0-current.tar"
  local work="${TMP}/phase2-work"
  local ver="6.6.0"
  local f
  rm -rf "$dest" "$work"
  mkdir -p "$dest" "$work"
  for f in \
    aelladeb_py3_common.tar.gz \
    aelladeb_py3_common.tar.gz.sha1 \
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb" \
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1" \
    bringup_py3_dp_after_os_upgrade.sh \
    bringup_py3_dp_after_os_upgrade.sh.sha1 \
    "images-${ver}.list" \
    "images-${ver}.tar.sha256"
  do
    printf 'fixture-%s\n' "$f" >"${work}/${f}"
  done
  seq 1 156 >"${work}/images-${ver}.list"
  dd if=/dev/urandom of="${work}/images-${ver}.tar" bs=8K count=1 status=none
  /usr/bin/sha256sum "${work}/images-${ver}.tar" | awk '{print $1}' \
    >"${work}/images-${ver}.tar.sha256"
  tar -cf "${dest}/${stable}" -C "$work" \
    aelladeb_py3_common.tar.gz \
    aelladeb_py3_common.tar.gz.sha1 \
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb" \
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1" \
    bringup_py3_dp_after_os_upgrade.sh \
    bringup_py3_dp_after_os_upgrade.sh.sha1 \
    "images-${ver}.list" \
    "images-${ver}.tar" \
    "images-${ver}.tar.sha256"
  (
    cd "$dest"
    /usr/bin/sha256sum "$stable" >"${stable}.sha256"
  )
  cat >"${dest}/release.env" <<EOF
TARGET_DP_VERSION=6.6.0
PHASE2_ARTIFACT_VERSION=6.6.0
STABLE_BUNDLE_NAME=${stable}
PHASE2_BUNDLE_ENTRY_COUNT=9
BRINGUP_PATCHED_SHA1=$(sha1sum "${work}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')
BRINGUP_PATCH_GENERATION=$(python3 "${ROOT}/scripts/lib/patch_dp_phase2_bringup.py" --print-generation | awk -F= '$1=="BRINGUP_PATCH_GENERATION"{print $2; exit}')
BRINGUP_UPSTREAM_SHA1=70de02dd62409110dadb7553991d1ffb0a79f396
EOF
}

run_assess() {
  : >"$LOG"
  set +e
  engine_assess_phase2_final 6.6.0 >>"$LOG" 2>&1
  ASSESS_RC=$?
  set -e
}

echo "=== test_phase2_existing_reuse_progress ==="

make_sparse_bundle

PHASE2_EXISTING_BUNDLE=ABSENT
START1="$(date +%s)"
run_assess
RC1=$ASSESS_RC
ELAPSED1=$(( $(date +%s) - START1 ))
[[ "$RC1" -eq 0 ]] || { cat "$LOG"; fail "first assess rc=${RC1}"; }
[[ "${PHASE2_EXISTING_BUNDLE:-}" == "VALID" ]] \
  || fail "first assess bundle=${PHASE2_EXISTING_BUNDLE:-unset}"
grep -q 'PHASE2_EXISTING_SHA256_VERIFY_START' "$LOG" \
  || fail "PHASE2_EXISTING_SHA256_VERIFY_START missing"
grep -q 'PHASE2_EXISTING_SHA256_VERIFY_HEARTBEAT' "$LOG" \
  || fail "PHASE2_EXISTING_SHA256_VERIFY_HEARTBEAT missing"
grep -q 'PHASE2_EXISTING_TAR_VERIFY_START' "$LOG" \
  || fail "PHASE2_EXISTING_TAR_VERIFY_START missing"
grep -q 'PHASE2_EXISTING_VERIFY_CACHE=STORED' "$LOG" \
  || fail "PHASE2_EXISTING_VERIFY_CACHE=STORED missing"
grep -q 'PHASE2_BUNDLE_VERIFY_MODE=FULL_HASH' "$LOG" \
  || fail "PHASE2_BUNDLE_VERIFY_MODE=FULL_HASH missing on first run"
[[ "$ELAPSED1" -ge 2 ]] \
  || fail "first run too fast (${ELAPSED1}s) — heartbeat path not exercised"
pass "first run: heartbeat + CACHE=STORED (${ELAPSED1}s)"

START2="$(date +%s)"
run_assess
RC2=$ASSESS_RC
ELAPSED2=$(( $(date +%s) - START2 ))
[[ "$RC2" -eq 0 ]] || { cat "$LOG"; fail "second assess rc=${RC2}"; }
grep -q 'PHASE2_EXISTING_VERIFY_CACHE=HIT' "$LOG" \
  || fail "PHASE2_EXISTING_VERIFY_CACHE=HIT missing on second run"
grep -q 'PHASE2_BUNDLE_VERIFY_MODE=VERIFIED_METADATA_REUSE' "$LOG" \
  || fail "PHASE2_BUNDLE_VERIFY_MODE=VERIFIED_METADATA_REUSE missing"
grep -q 'PHASE2_BUNDLE_FULL_HASH_REQUIRED=NO' "$LOG" \
  || fail "PHASE2_BUNDLE_FULL_HASH_REQUIRED=NO missing"
[[ "$ELAPSED2" -lt 2 ]] \
  || fail "second run too slow (${ELAPSED2}s) — cache miss?"
pass "second run: CACHE=HIT fast (${ELAPSED2}s)"

# Changing bundle metadata forces full hash again
echo "PHASE2_ARTIFACT_VERSION=6.6.0" >>"${MM_DP_PHASE2_ROOT}/6.6.0/release.env"
mm_status_set PHASE2_REUSE_VERIFIED_FINGERPRINT ""
mm_status_set PHASE2_REUSE_VERIFIED_SHA256 ""
START3="$(date +%s)"
run_assess
RC3=$ASSESS_RC
ELAPSED3=$(( $(date +%s) - START3 ))
[[ "$RC3" -eq 0 ]] || { cat "$LOG"; fail "third assess rc=${RC3}"; }
grep -q 'PHASE2_BUNDLE_VERIFY_MODE=FULL_HASH' "$LOG" \
  || fail "metadata change did not force FULL_HASH"
grep -q 'PHASE2_EXISTING_VERIFY_CACHE=STORED' "$LOG" \
  || fail "metadata change did not re-store cache"
[[ "$ELAPSED3" -ge 2 ]] \
  || fail "metadata change verify too fast (${ELAPSED3}s)"
pass "metadata change forces full hash again (${ELAPSED3}s)"

# Conceptual: heavy plane reuse independent of client plane (engine markers)
grep -q 'engine_assess_client_set_for_finalize' "$ENGINE" \
  && grep -q 'engine_assess_phase2_final' "$ENGINE" \
  && pass "heavy (Phase2 assess) and client (assess_client_set) planes are separate entrypoints" \
  || fail "plane separation markers missing"

echo "PHASE2_BUNDLE_VERIFY_MODE logged on assess (see LOG above)"
pass "PHASE2_BUNDLE_VERIFY_MODE contract present"

echo "TEST_PHASE2_EXISTING_REUSE_PROGRESS=PASS"
exit 0
