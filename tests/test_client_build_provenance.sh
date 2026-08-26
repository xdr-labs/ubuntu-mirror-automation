#!/usr/bin/env bash
# tests/test_client_build_provenance.sh — authoritative build provenance cases 1–12.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROV="${ROOT}/scripts/lib/client_build_provenance.py"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
# shellcheck source=lib/client_finalization_fixture.sh
source "${ROOT}/tests/lib/client_finalization_fixture.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
SCRATCH=""
cleanup() {
  [[ -z "$SCRATCH" ]] || rm -rf "$SCRATCH"
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

MIRROR_URL="http://192.0.2.99"
MIRROR_URL_B="http://192.0.2.100"

echo "=== test_client_build_provenance ==="

client_fixture_build_selective "$WORKDIR"
client_fixture_install_runtime "$ROOT" "$WORKDIR"

SEL="$CLIENT_FIXTURE_SELECTIVE"
CLIENT_ROOT="$CLIENT_FIXTURE_CLIENT_ROOT"
SIGNING_DIR="$CLIENT_FIXTURE_SIGNING_DIR"
MIRROR_ROOT="$CLIENT_FIXTURE_MIRROR_ROOT"
CACHE="${MIRROR_ROOT}/.install-cache"
FPR="$(tr -d '[:space:]' <"${SIGNING_DIR}/fingerprint" | tr '[:lower:]' '[:upper:]')"

run_rebuild() {
  local project_root="${1:-$ROOT}"
  local client_root="${2:-$CLIENT_ROOT}"
  local log="${3:-${WORKDIR}/rebuild.log}"
  env \
    MIRROR_HTTP_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_BASE_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_HOST_IPV4="192.0.2.99" \
    LOCAL_CLIENT_SIGNING_DIR="$SIGNING_DIR" \
    CLIENT_HTTP_ROOT="$client_root" \
    SELECTIVE_ROOT="$SEL" \
    BASE_PATH="$MIRROR_ROOT" \
    CACHE_ROOT="$CACHE" \
    CONTENT_SOURCE=local-fs \
    CLIENT_BUILD_PIN_URL_ONLY=1 \
    SKIP_HTTP_VERIFY=1 \
    REQUIRE_SELECTIVE_READY=1 \
    bash "${project_root}/scripts/rebuild-publish-clients.sh" \
    >"$log" 2>&1
}

compute_digest() {
  local project_root="$1"
  local mirror="${2:-$MIRROR_URL}"
  local fpr_local="${3:-$FPR}"
  python3 "$PROV" compute \
    --project-root "$project_root" \
    --mirror-base-url "$mirror" \
    --signing-fingerprint "$fpr_local" \
    --format env \
    | awk -F= '$1=="CLIENT_BUILD_INPUT_SHA256"{print $2; exit}'
}

classify_client() {
  local project_root="$1"
  local client_root="$2"
  local mirror="${3:-$MIRROR_URL}"
  local fpr_local="${4:-$FPR}"
  python3 "$PROV" classify-client-set \
    --project-root "$project_root" \
    --client-root "$client_root" \
    --expected-mirror "$mirror" \
    --expected-fingerprint "$fpr_local" \
    --expected-mode FULL 2>&1
}

make_scratch() {
  SCRATCH="$(mktemp -d)"
  rsync -a --exclude='.git' --exclude='artifacts' "$ROOT/" "$SCRATCH/"
}

# --- Build baseline published client set ---
LOG="${WORKDIR}/baseline-rebuild.log"
if ! run_rebuild "$ROOT" "$CLIENT_ROOT" "$LOG"; then
  fail "baseline rebuild-publish-clients (see ${LOG})"
  tail -40 "$LOG" || true
else
  pass "baseline client set published"
fi

[[ -f "${CLIENT_ROOT}/client-set.env" ]] \
  && pass "client-set.env present" \
  || fail "client-set.env missing"

GOLDEN_CLIENT="${WORKDIR}/golden-client"
cp -a "$CLIENT_ROOT" "$GOLDEN_CLIENT"

DIGEST_A="$(compute_digest "$ROOT")"
DIGEST_B="$(compute_digest "$ROOT")"
if [[ -n "$DIGEST_A" && "$DIGEST_A" == "$DIGEST_B" ]]; then
  pass "case 1: unchanged input → same digest"
else
  fail "case 1: digest unstable (${DIGEST_A} vs ${DIGEST_B})"
fi

OUT="$(classify_client "$ROOT" "$CLIENT_ROOT" || true)"
echo "$OUT" | grep -q 'CLIENT_SET_STATE=CURRENT_VERIFIED' \
  && pass "case 1: CURRENT_VERIFIED" \
  || fail "case 1: not CURRENT_VERIFIED"
echo "$OUT" | grep -q 'CLIENT_SET_ACTION=REUSE_CURRENT' \
  && pass "case 1: REUSE_CURRENT" \
  || fail "case 1: not REUSE_CURRENT"

# --- engine_assess_client_set_for_finalize (production path) ---
export MM_PROJECT_ROOT="$ROOT"
export MM_SKIP_ROOT_CHECK=1
export MM_MIRROR_ROOT="$MIRROR_ROOT"
export MM_CLIENT_ROOT="$CLIENT_ROOT"
export MM_CONFIG_DIR="${WORKDIR}/config"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_STATE_ROOT="${WORKDIR}/state"
export MM_LOG_DIR="${WORKDIR}/logs"
export MM_SELECTIVE_ROOT="$SEL"
export LOCAL_CLIENT_SIGNING_DIR="$SIGNING_DIR"
export PREPARATION_MODE=FULL
export MIRROR_HTTP_URL="$MIRROR_URL"
mkdir -p "$MM_CONFIG_DIR" "$MM_LOG_DIR" "$MM_STATE_ROOT"
cat >"$MM_CONFIG_FILE" <<EOF
PREPARATION_MODE=FULL
MIRROR_HTTP_URL=${MIRROR_URL}
RESOLVED_MIRROR_BASE_URL=${MIRROR_URL}
EOF
mkdir -p "${MM_CONFIG_DIR}/client-signing"
cp "${SIGNING_DIR}/fingerprint" "${MM_CONFIG_DIR}/client-signing/fingerprint"
export RESOLVED_MIRROR_BASE_URL="$MIRROR_URL"
export RESOLVED_MIRROR_HOST_IPV4="192.0.2.99"
mirror_host_validate_ipv4_on_host() { return 0; }
chmod 600 "$MM_CONFIG_FILE"
: >"$MM_STATUS_FILE"

# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "$COMMON"
mirror_host_validate_ipv4_on_host() { return 0; }
# shellcheck source=../scripts/lib/mirror_install_engine.sh
source "$ENGINE"

engine_assess_client_set_for_finalize || true
if [[ "$CLIENT_SET_STATE" == "CURRENT_VERIFIED" && "$CLIENT_SET_ACTION" == "REUSE_CURRENT" ]]; then
  pass "engine assess: REUSE_CURRENT for current set"
else
  fail "engine assess current: state=${CLIENT_SET_STATE} action=${CLIENT_SET_ACTION}"
fi

assert_digest_changes() {
  local label="$1"
  local rel="$2"
  make_scratch
  local before after
  before="$(compute_digest "$ROOT")"
  printf '\n# mutation\n' >>"${SCRATCH}/${rel}"
  after="$(compute_digest "$SCRATCH")"
  if [[ "$before" != "$after" ]]; then
    pass "case ${label}: digest changed"
  else
    fail "case ${label}: digest unchanged after ${rel} mutation"
  fi
  rm -rf "$SCRATCH"
  SCRATCH=""
}

assert_digest_changes 2 "scripts/lib/build_client_xenial_to_bionic.py"
assert_digest_changes 3 "client/dp-offline-upgrade-xenial-to-bionic.sh.in"
assert_digest_changes 4 "client/dp-client-command-runner.sh"
assert_digest_changes 5 "client/lib/dp-offline-apt-preflight-sandbox.sh"
assert_digest_changes 6 "client/lib/dp-offline-release-upgrade-reconciliation.sh"
assert_digest_changes "6b" "client/dp-client-hop-launcher.sh.in"
assert_digest_changes "6c" "scripts/lib/build_client_launchers.py"

# Case 7: command-block version (mutate constant in scratch copy)
make_scratch
BEFORE7="$(compute_digest "$ROOT")"
sed -i 's/COMMAND_BLOCK_VERSION = "SUBSHELL_V2"/COMMAND_BLOCK_VERSION = "SUBSHELL_V2_TEST"/' \
  "${SCRATCH}/scripts/lib/client_build_provenance.py"
AFTER7="$(compute_digest "$SCRATCH")"
if [[ "$BEFORE7" != "$AFTER7" ]]; then
  pass "case 7: command-block version change → digest changes"
else
  fail "case 7: command-block version did not change digest"
fi
rm -rf "$SCRATCH"
SCRATCH=""

# Case 8: mirror URL
M8A="$(compute_digest "$ROOT" "$MIRROR_URL")"
M8B="$(compute_digest "$ROOT" "$MIRROR_URL_B")"
if [[ "$M8A" != "$M8B" ]]; then
  pass "case 8: mirror URL change → digest changes"
else
  fail "case 8: mirror URL did not change digest"
fi

# Case 9: signing fingerprint (compute pin only — classify uses STALE_SIGNING_IDENTITY)
FPR_B="FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
F9A="$(compute_digest "$ROOT" "$MIRROR_URL" "$FPR")"
F9B="$(compute_digest "$ROOT" "$MIRROR_URL" "$FPR_B")"
if [[ "$F9A" != "$F9B" ]]; then
  pass "case 9: signing fingerprint change → digest changes"
else
  fail "case 9: fingerprint did not change digest"
fi
OUT9="$(classify_client "$ROOT" "$GOLDEN_CLIENT" "$MIRROR_URL" "$FPR_B" || true)"
if echo "$OUT9" | grep -q 'CLIENT_SET_STATE=STALE_SIGNING_IDENTITY'; then
  pass "case 9: STALE_SIGNING_IDENTITY on fingerprint mismatch"
elif echo "$OUT9" | grep -q 'CLIENT_SET_STATE=STALE_BUILD_INPUT'; then
  pass "case 9: STALE_BUILD_INPUT on fingerprint mismatch"
else
  fail "case 9: expected stale signing/build state"
fi

# Case 10: timestamp / generated output only → digest unchanged
DIGEST10A="$(compute_digest "$ROOT")"
MUT_ROOT="${WORKDIR}/mut-client"
cp -a "$GOLDEN_CLIENT" "$MUT_ROOT"
if [[ -f "${MUT_ROOT}/client-set.env" ]]; then
  echo "CLIENT_BUILD_CREATED_UTC=2099-01-01T00:00:00Z" >>"${MUT_ROOT}/client-set.env"
fi
if [[ -f "${MUT_ROOT}/dp-offline-upgrade-xenial-to-bionic.sh" ]]; then
  echo "# generated-output-marker" >>"${MUT_ROOT}/dp-offline-upgrade-xenial-to-bionic.sh"
fi
DIGEST10B="$(compute_digest "$ROOT")"
if [[ "$DIGEST10A" == "$DIGEST10B" ]]; then
  pass "case 10: timestamp/generated-output only → digest unchanged"
else
  fail "case 10: digest changed on non-input mutation"
fi

# Case 11: legacy metadata → stale rebuild
LEGACY_ROOT="${WORKDIR}/legacy-client"
cp -a "$GOLDEN_CLIENT" "$LEGACY_ROOT"
grep -v '^CLIENT_BUILD_INPUT_SHA256=' "${LEGACY_ROOT}/client-set.env" \
  | grep -v '^CLIENT_PROVENANCE_SCHEMA_VERSION=' \
  >"${LEGACY_ROOT}/client-set.env.tmp" || true
mv "${LEGACY_ROOT}/client-set.env.tmp" "${LEGACY_ROOT}/client-set.env"
OUT11="$(classify_client "$ROOT" "$LEGACY_ROOT" || true)"
echo "$OUT11" | grep -q 'CLIENT_SET_STATE=STALE_LEGACY_METADATA' \
  && pass "case 11: STALE_LEGACY_METADATA" \
  || fail "case 11: legacy metadata not stale"
echo "$OUT11" | grep -q 'CLIENT_SET_ACTION=REBUILD_SIGN_PUBLISH' \
  && pass "case 11: REBUILD_SIGN_PUBLISH" \
  || fail "case 11: legacy missing REBUILD action"

# Case 12: tampered client → reuse rejected
TAMPER_ROOT="${WORKDIR}/tampered-client"
cp -a "$GOLDEN_CLIENT" "$TAMPER_ROOT"
printf '\n# tamper\n' >>"${TAMPER_ROOT}/dp-offline-upgrade-xenial-to-bionic.sh"
OUT12="$(classify_client "$ROOT" "$TAMPER_ROOT" || true)"
echo "$OUT12" | grep -qE 'CLIENT_SET_STATE=(INVALID|STALE_BUILD_INPUT)' \
  && pass "case 12: tampered client rejected" \
  || fail "case 12: tampered client not rejected"
echo "$OUT12" | grep -q 'CLIENT_SET_ACTION=REBUILD_SIGN_PUBLISH' \
  && pass "case 12: REBUILD_SIGN_PUBLISH on tamper" \
  || fail "case 12: tamper missing rebuild action"

# Wrapper tamper after publication → integrity FAIL (sidecar/metadata).
WRAP_TAMPER="${WORKDIR}/wrapper-tampered-client"
cp -a "$GOLDEN_CLIENT" "$WRAP_TAMPER"
[[ -f "${WRAP_TAMPER}/upgrade-jammy-to-noble.sh" ]] \
  && pass "golden set contains OS wrappers" \
  || fail "golden set missing OS wrappers"
[[ -f "${WRAP_TAMPER}/upgrade-phase2.sh" ]] \
  && pass "golden set contains upgrade-phase2.sh" \
  || fail "golden set missing upgrade-phase2.sh"
printf 'x' >>"${WRAP_TAMPER}/upgrade-jammy-to-noble.sh"
OUT_WT="$(classify_client "$ROOT" "$WRAP_TAMPER" || true)"
echo "$OUT_WT" | grep -qE 'CLIENT_SET_STATE=INVALID' \
  && pass "wrapper tamper: INVALID" \
  || fail "wrapper tamper not rejected (${OUT_WT})"
MISS_WRAP="${WORKDIR}/missing-wrapper-client"
cp -a "$GOLDEN_CLIENT" "$MISS_WRAP"
rm -f "${MISS_WRAP}/upgrade-focal-to-jammy.sh"
OUT_MW="$(classify_client "$ROOT" "$MISS_WRAP" || true)"
echo "$OUT_MW" | grep -qE 'CLIENT_SET_STATE=INVALID' \
  && pass "missing required wrapper: INVALID" \
  || fail "missing wrapper not rejected"
export MM_CLIENT_ROOT="$MISS_WRAP"
if mm_client_files_ready "$MISS_WRAP"; then
  fail "missing wrapper still CLIENT_FILES_READY"
else
  pass "missing wrapper makes client readiness FAIL"
fi
export MM_CLIENT_ROOT="$CLIENT_ROOT"

# Wrapper-generation source change invalidates published set.
make_scratch
printf '\n# wrapper-generation-mutation\n' >>"${SCRATCH}/scripts/lib/build_client_launchers.py"
OUT_WG="$(classify_client "$SCRATCH" "$GOLDEN_CLIENT" || true)"
echo "$OUT_WG" | grep -q 'CLIENT_SET_STATE=STALE_BUILD_INPUT' \
  && pass "wrapper generator change: STALE_BUILD_INPUT" \
  || fail "wrapper generator change not stale"
echo "$OUT_WG" | grep -q 'CLIENT_SET_ACTION=REBUILD_SIGN_PUBLISH' \
  && pass "wrapper generator change: REBUILD_SIGN_PUBLISH" \
  || fail "wrapper generator change missing rebuild action"
rm -rf "$SCRATCH"
SCRATCH=""

# Stale build input via engine after scratch mutation on builder
make_scratch
printf '\n# stale-builder\n' >>"${SCRATCH}/scripts/lib/build_client_jammy_to_noble.py"
STALE_CLIENT="${WORKDIR}/stale-client"
cp -a "$GOLDEN_CLIENT" "$STALE_CLIENT"
export MM_PROJECT_ROOT="$SCRATCH"
export MM_CLIENT_ROOT="$STALE_CLIENT"
engine_assess_client_set_for_finalize || true
if [[ "$CLIENT_SET_STATE" == "STALE_BUILD_INPUT" \
  || "$CLIENT_SET_STATE" == "STALE_LEGACY_METADATA" \
  || "$CLIENT_SET_STATE" == "STALE_SIGNING_IDENTITY" ]]; then
  pass "engine assess: stale state=${CLIENT_SET_STATE} for stale builder tree"
else
  fail "engine assess stale: state=${CLIENT_SET_STATE} action=${CLIENT_SET_ACTION}"
fi
[[ "$CLIENT_SET_ACTION" == "REBUILD_SIGN_PUBLISH" ]] \
  && pass "engine assess: REBUILD_SIGN_PUBLISH for stale" \
  || fail "engine assess stale action=${CLIENT_SET_ACTION}"
export MM_PROJECT_ROOT="$ROOT"
rm -rf "$SCRATCH"
SCRATCH=""

# --- Phase 2 helper CURRENT-SOURCE freshness ---
# A published helper generation can be internally valid while current source
# has moved on. CLIENT_BUILD_INPUT_SHA256 must include every file listed by
# phase2_helper_generation_files() plus the generator itself.
# shellcheck source=../scripts/lib/phase2_helper_generation.sh
source "${ROOT}/scripts/lib/phase2_helper_generation.sh"
PHASE2_HELPER_N=0
while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  PHASE2_HELPER_N=$((PHASE2_HELPER_N + 1))
  assert_digest_changes "phase2-helper-${PHASE2_HELPER_N}" "client/${rel}"
done < <(phase2_helper_generation_files)
[[ "$PHASE2_HELPER_N" -gt 0 ]] \
  && pass "phase2 helper set: ${PHASE2_HELPER_N} files bound into provenance" \
  || fail "phase2 helper set: phase2_helper_generation_files returned empty"
assert_digest_changes "phase2-generator" "scripts/lib/phase2_helper_generation.sh"

# Production bug: published client set stays internally valid; only current
# source Phase 2 helper bytes change → STALE_BUILD_INPUT, not CURRENT_VERIFIED.
make_scratch
printf '\n# stale-phase2-helper-source\n' >>"${SCRATCH}/client/lib/dp-phase2-bringup-lifecycle.sh"
DIGEST_HELPER_BEFORE="$(compute_digest "$ROOT")"
DIGEST_HELPER_AFTER="$(compute_digest "$SCRATCH")"
if [[ -n "$DIGEST_HELPER_BEFORE" && "$DIGEST_HELPER_BEFORE" != "$DIGEST_HELPER_AFTER" ]]; then
  pass "phase2 helper-only source change → digest changed"
else
  fail "phase2 helper-only source change did not change digest"
fi
HELPER_STALE_CLIENT="${WORKDIR}/helper-stale-client"
cp -a "$GOLDEN_CLIENT" "$HELPER_STALE_CLIENT"
OUT_HELPER="$(classify_client "$SCRATCH" "$HELPER_STALE_CLIENT" || true)"
echo "$OUT_HELPER" | grep -q 'CLIENT_SET_STATE=STALE_BUILD_INPUT' \
  && pass "phase2 helper-only: CLIENT_SET_STATE=STALE_BUILD_INPUT" \
  || fail "phase2 helper-only: state not STALE_BUILD_INPUT (${OUT_HELPER})"
echo "$OUT_HELPER" | grep -q 'CLIENT_SET_ACTION=REBUILD_SIGN_PUBLISH' \
  && pass "phase2 helper-only: CLIENT_SET_ACTION=REBUILD_SIGN_PUBLISH" \
  || fail "phase2 helper-only: action not REBUILD_SIGN_PUBLISH"
echo "$OUT_HELPER" | grep -q 'CLIENT_SET_STATE=CURRENT_VERIFIED' \
  && fail "phase2 helper-only: false CURRENT_VERIFIED reuse" \
  || true
echo "$OUT_HELPER" | grep -q 'CLIENT_SET_ACTION=REUSE_CURRENT' \
  && fail "phase2 helper-only: false REUSE_CURRENT" \
  || true

export MM_PROJECT_ROOT="$SCRATCH"
export MM_CLIENT_ROOT="$HELPER_STALE_CLIENT"
engine_assess_client_set_for_finalize || true
if [[ "$CLIENT_SET_STATE" == "STALE_BUILD_INPUT" ]]; then
  pass "engine helper-only: CLIENT_SET_STATE=STALE_BUILD_INPUT"
else
  fail "engine helper-only: state=${CLIENT_SET_STATE} action=${CLIENT_SET_ACTION}"
fi
[[ "$CLIENT_SET_ACTION" == "REBUILD_SIGN_PUBLISH" ]] \
  && pass "engine helper-only: CLIENT_SET_ACTION=REBUILD_SIGN_PUBLISH" \
  || fail "engine helper-only: action=${CLIENT_SET_ACTION}"
export MM_PROJECT_ROOT="$ROOT"
export MM_CLIENT_ROOT="$CLIENT_ROOT"
rm -rf "$SCRATCH"
SCRATCH=""

OUT_UNCHANGED="$(classify_client "$ROOT" "$GOLDEN_CLIENT" || true)"
echo "$OUT_UNCHANGED" | grep -q 'CLIENT_SET_STATE=CURRENT_VERIFIED' \
  && pass "unchanged source: CLIENT_SET_STATE=CURRENT_VERIFIED" \
  || fail "unchanged source: not CURRENT_VERIFIED"
echo "$OUT_UNCHANGED" | grep -q 'CLIENT_SET_ACTION=REUSE_CURRENT' \
  && pass "unchanged source: CLIENT_SET_ACTION=REUSE_CURRENT" \
  || fail "unchanged source: not REUSE_CURRENT"

# mm_record_download_validated must not demote CLIENT_SET_PUBLISHED
export MM_DP_PHASE2_ROOT="${MIRROR_ROOT}/dp-phase2"
mkdir -p "${MM_DP_PHASE2_ROOT}/6.6.0"
printf 'phase2-fixture\n' >"${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar"
(
  cd "${MM_DP_PHASE2_ROOT}/6.6.0"
  sha256sum dp_bundle_6.6.0-current.tar >dp_bundle_6.6.0-current.tar.sha256
)
cat >"${MM_DP_PHASE2_ROOT}/6.6.0/release.env" <<EOF
TARGET_DP_VERSION=6.6.0
PHASE2_ARTIFACT_VERSION=6.6.0
STABLE_BUNDLE_NAME=dp_bundle_6.6.0-current.tar
EOF
export MM_WORKFLOW_FILE="${MM_CONFIG_DIR}/dp-upgrade-workflow.state"
# shellcheck source=../scripts/lib/mirror_workflow_state.sh
source "${ROOT}/scripts/lib/mirror_workflow_state.sh"
mm_wf_mark_client_set_published \
  "test-gen-001" "$FPR" "$DIGEST_A" "$(git -C "$ROOT" rev-parse HEAD)" \
  "$(sha256sum "${ROOT}/lib/runtime_manifest.sh" | awk '{print $1}')" \
  "SUBSHELL_V2" "1"
[[ "$(mm_wf_state)" == "CLIENT_SET_PUBLISHED" ]] \
  && pass "workflow pre-record: CLIENT_SET_PUBLISHED" \
  || fail "workflow setup: $(mm_wf_state)"
mm_record_download_validated
[[ "$(mm_wf_state)" == "CLIENT_SET_PUBLISHED" ]] \
  && pass "mm_record_download_validated: CLIENT_SET_PUBLISHED preserved" \
  || fail "mm_record_download_validated demoted to $(mm_wf_state)"

if [[ "$FAIL" -eq 0 ]]; then
  echo "TEST_CLIENT_BUILD_PROVENANCE=PASS"
  exit 0
fi
echo "TEST_CLIENT_BUILD_PROVENANCE=FAIL"
exit 1
