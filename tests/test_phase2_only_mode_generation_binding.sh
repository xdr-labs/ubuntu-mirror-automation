#!/usr/bin/env bash
# FULL <-> PHASE2_ONLY mode-switch generation/binding regression (field defect).
#
# CASE A: FULL -> PHASE2_ONLY yields a usable current PHASE2_ONLY generation
# CASE B: FULL selective digest must NOT be reused as PHASE2_ONLY
# CASE C: regeneration publishes coherent PHASE2_ONLY binding
# CASE D: PHASE2_ONLY -> FULL reuses only on exact FULL inputs / regenerates coherently
# CASE E: failed publish preserves live client tree (no mixed generation)
# CASE F: repeated FULL <-> PHASE2_ONLY remains deterministic
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/client_finalization_fixture.sh
source "${ROOT}/tests/lib/client_finalization_fixture.sh"
# shellcheck source=lib/phase2_bundle_trust_fixture.sh
source "${ROOT}/tests/lib/phase2_bundle_trust_fixture.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "=== test_phase2_only_mode_generation_binding ==="

client_fixture_build_selective "$WORKDIR"
client_fixture_install_runtime "$ROOT" "$WORKDIR"

SEL="$CLIENT_FIXTURE_SELECTIVE"
CLIENT_ROOT="$CLIENT_FIXTURE_CLIENT_ROOT"
SIGNING_DIR="$CLIENT_FIXTURE_SIGNING_DIR"
MIRROR_ROOT="$CLIENT_FIXTURE_MIRROR_ROOT"
CACHE="${MIRROR_ROOT}/.install-cache"
FPR="$(tr -d '[:space:]' <"${SIGNING_DIR}/fingerprint" | tr '[:lower:]' '[:upper:]')"
MIRROR_URL="http://192.0.2.99"
export MM_DP_PHASE2_ROOT="${MIRROR_ROOT}/dp-phase2"
phase2_trust_fixture_write_bundle_sidecar "$MM_DP_PHASE2_ROOT" "6.6.0" >/dev/null

export MM_PROJECT_ROOT="$ROOT"
export MM_CONFIG_DIR="${WORKDIR}/etc-ubuntu-mirror"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.status"
export MM_WORKFLOW_FILE="${MM_CONFIG_DIR}/dp-upgrade-workflow.state"
export MM_LOG_DIR="${WORKDIR}/logs"
export MM_STATE_DIR="${WORKDIR}/state"
export MM_MIRROR_ROOT="$MIRROR_ROOT"
export MM_SELECTIVE_ROOT="$SEL"
export MM_CLIENT_ROOT="$CLIENT_ROOT"
export MM_CACHE_ROOT="$CACHE"
export MM_DP_PHASE2_ROOT
export LOCAL_CLIENT_SIGNING_DIR="$SIGNING_DIR"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_HERMETIC_TEST_MODE=1
export CLIENT_BUILD_PIN_URL_ONLY=1
mkdir -p "$MM_CONFIG_DIR" "$MM_LOG_DIR" "$MM_STATE_DIR"
: >"$MM_STATUS_FILE"

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_workflow_state.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_install_engine.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/local_client_signing.sh"

INSTALLER_LIB="${WORKDIR}/installer-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "${ROOT}/scripts/install-dp-upgrade-mirror.sh" >"$INSTALLER_LIB"
# shellcheck disable=SC1090
source "$INSTALLER_LIB"

meta_get() {
  local key="$1"
  mm_parse_env_metadata_get "${CLIENT_ROOT}/client-set.env" "$key" 2>/dev/null || true
}

classify_mode() {
  local mode="$1"
  python3 "${ROOT}/scripts/lib/client_build_provenance.py" classify-client-set \
    --project-root "$ROOT" \
    --client-root "$CLIENT_ROOT" \
    --expected-mirror "$MIRROR_URL" \
    --expected-fingerprint "$FPR" \
    --expected-mode "$mode" \
    --selective-root "$SEL" 2>&1 || true
}

expected_digest() {
  local mode="$1"
  local plan="" disc="" contract=""
  if [[ "$mode" == "FULL" ]]; then
    plan="$(awk -F= '$1=="plan_checksum"{print tolower($2); exit}' "${SEL}/state/READY")"
    disc="$(awk -F= '$1=="discovery_artifact_checksum"{print tolower($2); exit}' "${SEL}/state/READY")"
    contract="$(awk -F= '$1=="aws_semantic_contract_sha256"{print tolower($2); exit}' "${SEL}/state/READY")"
  fi
  python3 "${ROOT}/scripts/lib/client_build_provenance.py" compute \
    --project-root "$ROOT" \
    --mirror-base-url "$MIRROR_URL" \
    --signing-fingerprint "$FPR" \
    --plan-checksum "$plan" \
    --discovery-artifact-checksum "$disc" \
    --aws-semantic-contract-sha256 "$contract" \
    --format env \
    | awk -F= '$1=="CLIENT_BUILD_INPUT_SHA256"{print $2; exit}'
}

run_rebuild() {
  local mode="$1"
  local log="${2:-${WORKDIR}/rebuild-${mode}.log}"
  env \
    PREPARATION_MODE="$mode" \
    MIRROR_HTTP_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_BASE_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_HOST_IPV4="192.0.2.99" \
    LOCAL_CLIENT_SIGNING_DIR="$SIGNING_DIR" \
    CLIENT_HTTP_ROOT="$CLIENT_ROOT" \
    SELECTIVE_ROOT="$SEL" \
    BASE_PATH="$MIRROR_ROOT" \
    MM_DP_PHASE2_ROOT="$MM_DP_PHASE2_ROOT" \
    CACHE_ROOT="$CACHE" \
    MM_CONFIG_DIR="$MM_CONFIG_DIR" \
    MM_WORKFLOW_FILE="$MM_WORKFLOW_FILE" \
    CONTENT_SOURCE=local-fs \
    MM_HERMETIC_TEST_MODE=1 \
    CLIENT_BUILD_PIN_URL_ONLY=1 \
    SKIP_HTTP_VERIFY=1 \
    bash "${ROOT}/scripts/rebuild-publish-clients.sh" \
    >"$log" 2>&1
}

seed_full_ready_workflow() {
  local gen="$1"
  local digest="$2"
  mm_wf_ensure_file
  PREPARATION_MODE=FULL
  mm_wf_store_layer_identities
  mm_wf_set_many \
    "WORKFLOW_STATE=COMMANDS_GENERATED" \
    "WORKFLOW_GENERATION_ID=${gen}" \
    "OS_CORE_GENERATION_ID=os-${gen}" \
    "PHASE2_GENERATION_ID=p2-${gen}" \
    "CLIENT_SET_GENERATION_ID=${gen}" \
    "CLIENT_SIGNING_FINGERPRINT=${FPR}" \
    "CLIENT_BUILD_INPUT_SHA256=${digest}" \
    "HTTP_PUBLICATION_GENERATION_ID=${gen}" \
    "READINESS_VERIFIED_GENERATION_ID=${gen}" \
    "COMMAND_FILE_GENERATION_ID=${gen}" \
    "CONFIG_CHANGE_CLASS=NONE" \
    "NEXT_REQUIRED_ACTION=NONE" \
    "PREPARATION_MODE=FULL"
  mm_status_set CONFIGURATION_READY PASS
  mm_status_set UPGRADE_READINESS PASS
  mm_status_set HTTP_DISTRIBUTION ENABLED
  mm_status_set CLIENT_COMMANDS_MODE FULL
}

save_mode() {
  local mode="$1"
  PREPARATION_MODE="$mode"
  MIRROR_SERVER_IP=192.0.2.99
  MIRROR_HTTP_URL="$MIRROR_URL"
  ACPS_USERNAME=fixture
  ACPS_PASSWORD=fixture-secret
  WORKER_SSH_PASSWORD=
  DL_WORKER_IPS=
  DA_WORKER_IPS=
  PHASE2_TARGET_VERSION=6.6.0
  TARGET_DP_VERSION=6.6.0
  mm_save_gui_config_full >/dev/null
}

finalize_for_mode() {
  local mode="$1"
  PREPARATION_MODE="$mode"
  export PREPARATION_MODE
  MIRROR_HTTP_URL="$MIRROR_URL"
  RESOLVED_MIRROR_BASE_URL="$MIRROR_URL"
  engine_finalize_local_client_set
}

# ---------------------------------------------------------------------------
# Bootstrap: publish a real FULL selective-bound generation
# ---------------------------------------------------------------------------
PREPARATION_MODE=FULL
save_mode FULL
run_rebuild FULL "${WORKDIR}/rebuild-full-initial.log" \
  || { cat "${WORKDIR}/rebuild-full-initial.log" | tail -40; fail "initial FULL rebuild"; exit 1; }

FULL_DIGEST="$(meta_get CLIENT_BUILD_INPUT_SHA256)"
FULL_GEN="$(meta_get CLIENT_SET_GENERATION_ID)"
FULL_MODE="$(meta_get PREPARATION_MODE)"
EXPECTED_FULL="$(expected_digest FULL)"
EXPECTED_P2="$(expected_digest PHASE2_ONLY)"

[[ -n "$FULL_DIGEST" && "$FULL_DIGEST" == "$EXPECTED_FULL" ]] \
  && pass "bootstrap FULL digest matches selective contract" \
  || fail "bootstrap FULL digest mismatch got=${FULL_DIGEST} want=${EXPECTED_FULL}"
[[ "$FULL_MODE" == "FULL" ]] && pass "bootstrap PREPARATION_MODE=FULL" \
  || fail "bootstrap PREPARATION_MODE=${FULL_MODE}"
[[ "$FULL_DIGEST" != "$EXPECTED_P2" ]] \
  && pass "CASE B precondition: FULL digest != PHASE2_ONLY canonical" \
  || fail "CASE B precondition failed: digests unexpectedly equal"

seed_full_ready_workflow "$FULL_GEN" "$FULL_DIGEST"
OS_BEFORE="$(mm_wf_get OS_CORE_GENERATION_ID)"
P2_BEFORE="$(mm_wf_get PHASE2_GENERATION_ID)"

# ---------------------------------------------------------------------------
# CASE B: incompatible FULL generation must not classify as PHASE2_ONLY
# ---------------------------------------------------------------------------
OUT_B="$(classify_mode PHASE2_ONLY)"
if printf '%s\n' "$OUT_B" | grep -q 'CLIENT_SET_STATE=CURRENT_VERIFIED'; then
  fail "CASE B falsely reused FULL generation as PHASE2_ONLY"
else
  pass "OLD_FULL_GENERATION_NOT_REUSED_AS_PHASE2_ONLY=PASS"
fi
if printf '%s\n' "$OUT_B" | grep -Eq 'mode_mismatch|build_input_mismatch'; then
  pass "CASE B reject reason is mode/digest mismatch"
else
  fail "CASE B unexpected classify output: $OUT_B"
fi

# ---------------------------------------------------------------------------
# Mode switch FULL -> PHASE2_ONLY (authoritative config save path)
# ---------------------------------------------------------------------------
save_mode PHASE2_ONLY
CLS="$(mm_wf_get CONFIG_CHANGE_CLASS)"
STATE="$(mm_wf_state)"
[[ "$CLS" == "PREPARE_INPUT" ]] && pass "mode switch class=PREPARE_INPUT" \
  || fail "mode switch class=${CLS}"
# After fix: heavy gens preserved, client binding cleared, state PREPARED.
if [[ "$(mm_wf_get OS_CORE_GENERATION_ID)" == "$OS_BEFORE" \
   && "$(mm_wf_get PHASE2_GENERATION_ID)" == "$P2_BEFORE" ]]; then
  pass "mode switch preserved OS_CORE/PHASE2 generation ids"
else
  fail "mode switch cleared heavy artifact generation ids"
fi
if [[ -z "$(mm_wf_get CLIENT_SET_GENERATION_ID)" ]]; then
  pass "mode switch cleared incompatible CLIENT_SET_GENERATION binding"
else
  # Allow temporary retention only if classify still rejects reuse.
  OUT_HOLD="$(classify_mode PHASE2_ONLY)"
  if printf '%s\n' "$OUT_HOLD" | grep -q 'CLIENT_SET_STATE=CURRENT_VERIFIED'; then
    fail "mode switch left FULL generation bound as current PHASE2_ONLY"
  else
    pass "mode switch retained stale binding but rejected CURRENT reuse"
  fi
fi
case "$STATE" in
  PREPARED|CONFIGURED) pass "mode switch demoted to ${STATE}" ;;
  *) fail "mode switch unexpected state=${STATE}" ;;
esac

LIVE_BEFORE_SHA="$(sha256sum "${CLIENT_ROOT}/client-set.env" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# CASE A/C: finalize/regenerate PHASE2_ONLY coherently
# ---------------------------------------------------------------------------
if finalize_for_mode PHASE2_ONLY >"${WORKDIR}/finalize-p2.log" 2>&1; then
  pass "CASE A finalize PHASE2_ONLY returned success"
else
  fail "CASE A finalize PHASE2_ONLY failed"
  tail -40 "${WORKDIR}/finalize-p2.log" || true
fi

P2_DIGEST="$(meta_get CLIENT_BUILD_INPUT_SHA256)"
P2_GEN="$(meta_get CLIENT_SET_GENERATION_ID)"
P2_MODE="$(meta_get PREPARATION_MODE)"
P2_PLAN="$(meta_get CLIENT_PLAN_CHECKSUM)"
P2_DISC="$(meta_get CLIENT_DISCOVERY_ARTIFACT_CHECKSUM)"
P2_CONTRACT="$(meta_get CLIENT_AWS_SEMANTIC_CONTRACT_SHA256)"
WF_GEN="$(mm_wf_get CLIENT_SET_GENERATION_ID)"
WF_DIGEST="$(mm_wf_get CLIENT_BUILD_INPUT_SHA256)"

[[ "$P2_MODE" == "PHASE2_ONLY" ]] && pass "PHASE2_ONLY_REGENERATION metadata mode" \
  || fail "PHASE2_ONLY metadata mode=${P2_MODE}"
[[ "$P2_DIGEST" == "$EXPECTED_P2" ]] && pass "CLIENT_BUILD_INPUT_SHA256 matches PHASE2_ONLY canonical" \
  || fail "PHASE2_ONLY digest got=${P2_DIGEST} want=${EXPECTED_P2}"
[[ "$P2_DIGEST" != "$FULL_DIGEST" ]] && pass "CASE B/C new digest differs from FULL" \
  || fail "PHASE2_ONLY digest still equals FULL"
[[ -z "$P2_PLAN" && -z "$P2_DISC" && -z "$P2_CONTRACT" ]] \
  && pass "PHASE2_ONLY empty selective tuple" \
  || fail "PHASE2_ONLY selective tuple not empty plan=${P2_PLAN} disc=${P2_DISC} contract=${P2_CONTRACT}"
[[ -n "$P2_GEN" && "$P2_GEN" == "$WF_GEN" ]] \
  && pass "CLIENT_SET_GENERATION_BINDING=PASS" \
  || fail "workflow/client generation mismatch disk=${P2_GEN} wf=${WF_GEN}"
[[ "$WF_DIGEST" == "$P2_DIGEST" ]] && pass "workflow CLIENT_BUILD_INPUT_SHA256 bound" \
  || fail "workflow digest mismatch"
OUT_A="$(classify_mode PHASE2_ONLY)"
printf '%s\n' "$OUT_A" | grep -q 'CLIENT_SET_STATE=CURRENT_VERIFIED' \
  && pass "CASE A CURRENT_VERIFIED for PHASE2_ONLY" \
  || fail "CASE A not CURRENT_VERIFIED: $OUT_A"
printf '%s\n' "$OUT_A" | grep -q 'CLIENT_SET_ACTION=REUSE_CURRENT' \
  && pass "EXACT_GENERATION_BINDING=PASS" \
  || fail "CASE A action not REUSE_CURRENT"

# Menu 7 PHASE2_ONLY command content (no OS hops; one executable bringup).
cmd_file="${MM_LOG_DIR}/dp-client-upgrade-commands.txt"
gui_build_client_commands "$MIRROR_URL" single "" "" "" >"$cmd_file"
mm_wf_validate_command_file_content "$cmd_file" PHASE2_ONLY >"${WORKDIR}/menu7-p2.val"
grep -q 'COMMAND_FILE_BUILD=PASS' "${WORKDIR}/menu7-p2.val" \
  && pass "Menu 7 PHASE2_ONLY COMMAND_FILE_BUILD=PASS" \
  || fail "Menu 7 PHASE2_ONLY validation failed"
grep -q 'COMMAND_FILE_BRINGUP_EXECUTABLE_COUNT=1' "${WORKDIR}/menu7-p2.val" \
  && pass "SEMANTIC_BRINGUP_COUNT=1" \
  || fail "bringup count missing"
grep -qE 'UBUNTU 16.04|dp-offline-upgrade-xenial' "$cmd_file" \
  && fail "PHASE2_ONLY Menu 7 still contains OS hops" \
  || pass "PHASE2_ONLY Menu 7 omits OS hops"

# ---------------------------------------------------------------------------
# CASE E: failed publish preserves live PHASE2_ONLY tree
# ---------------------------------------------------------------------------
LIVE_SHA="$(sha256sum "${CLIENT_ROOT}/client-set.env" | awk '{print $1}')"
LIVE_GEN_E="$P2_GEN"
export MM_PHASE2_HELPERS_FORCE_REPUBLISH=1
export MM_PHASE2_HELPERS_FAKE_SWAP_FAIL=1
if engine_ensure_phase2_helpers >"${WORKDIR}/helpers-fail.log" 2>&1; then
  fail "CASE E injected helper swap failure unexpectedly succeeded"
else
  pass "CASE E helper publish failed closed"
fi
unset MM_PHASE2_HELPERS_FORCE_REPUBLISH MM_PHASE2_HELPERS_FAKE_SWAP_FAIL
AFTER_SHA="$(sha256sum "${CLIENT_ROOT}/client-set.env" | awk '{print $1}')"
AFTER_GEN="$(meta_get CLIENT_SET_GENERATION_ID)"
[[ "$AFTER_SHA" == "$LIVE_SHA" && "$AFTER_GEN" == "$LIVE_GEN_E" ]] \
  && pass "ATOMIC_FAILURE_PRESERVES_LIVE=PASS" \
  || fail "CASE E live generation mutated after failure"

# ---------------------------------------------------------------------------
# CASE D: PHASE2_ONLY -> FULL
# ---------------------------------------------------------------------------
save_mode FULL
if [[ "$(mm_wf_get OS_CORE_GENERATION_ID)" == "$OS_BEFORE" ]]; then
  pass "PHASE2_ONLY->FULL preserved OS_CORE generation id"
else
  fail "PHASE2_ONLY->FULL cleared OS_CORE generation id"
fi
OUT_D0="$(classify_mode FULL)"
if printf '%s\n' "$OUT_D0" | grep -q 'CLIENT_SET_STATE=CURRENT_VERIFIED'; then
  fail "CASE D reused PHASE2_ONLY generation as FULL"
else
  pass "CASE D PHASE2_ONLY generation not reused as FULL"
fi
if finalize_for_mode FULL >"${WORKDIR}/finalize-full.log" 2>&1; then
  pass "CASE D finalize FULL succeeded"
else
  fail "CASE D finalize FULL failed"
  tail -40 "${WORKDIR}/finalize-full.log" || true
fi
FULL2_DIGEST="$(meta_get CLIENT_BUILD_INPUT_SHA256)"
FULL2_MODE="$(meta_get PREPARATION_MODE)"
[[ "$FULL2_MODE" == "FULL" ]] && pass "CASE D PREPARATION_MODE=FULL" \
  || fail "CASE D mode=${FULL2_MODE}"
[[ "$FULL2_DIGEST" == "$EXPECTED_FULL" ]] && pass "CASE D FULL digest restored" \
  || fail "CASE D digest got=${FULL2_DIGEST} want=${EXPECTED_FULL}"
OUT_D1="$(classify_mode FULL)"
printf '%s\n' "$OUT_D1" | grep -q 'CLIENT_SET_STATE=CURRENT_VERIFIED' \
  && pass "CASE D FULL CURRENT_VERIFIED" \
  || fail "CASE D FULL not current: $OUT_D1"

# ---------------------------------------------------------------------------
# CASE F: repeated FULL -> PHASE2_ONLY -> FULL -> PHASE2_ONLY
# ---------------------------------------------------------------------------
DIG_F1="" DIG_F2="" DIG_P1="" DIG_P2=""
save_mode PHASE2_ONLY
finalize_for_mode PHASE2_ONLY >"${WORKDIR}/f-p1.log" 2>&1 || fail "CASE F first PHASE2_ONLY finalize"
DIG_P1="$(meta_get CLIENT_BUILD_INPUT_SHA256)"
save_mode FULL
finalize_for_mode FULL >"${WORKDIR}/f-f1.log" 2>&1 || fail "CASE F first FULL finalize"
DIG_F1="$(meta_get CLIENT_BUILD_INPUT_SHA256)"
save_mode PHASE2_ONLY
finalize_for_mode PHASE2_ONLY >"${WORKDIR}/f-p2.log" 2>&1 || fail "CASE F second PHASE2_ONLY finalize"
DIG_P2="$(meta_get CLIENT_BUILD_INPUT_SHA256)"
save_mode FULL
finalize_for_mode FULL >"${WORKDIR}/f-f2.log" 2>&1 || fail "CASE F second FULL finalize"
DIG_F2="$(meta_get CLIENT_BUILD_INPUT_SHA256)"

[[ "$DIG_P1" == "$EXPECTED_P2" && "$DIG_P2" == "$EXPECTED_P2" ]] \
  && pass "CASE F PHASE2_ONLY digests stable" \
  || fail "CASE F PHASE2_ONLY digests drifted ${DIG_P1} vs ${DIG_P2}"
[[ "$DIG_F1" == "$EXPECTED_FULL" && "$DIG_F2" == "$EXPECTED_FULL" ]] \
  && pass "CASE F FULL digests stable" \
  || fail "CASE F FULL digests drifted ${DIG_F1} vs ${DIG_F2}"
[[ "$DIG_P1" != "$DIG_F1" ]] && pass "REPEATED_MODE_SWITCH_IDEMPOTENT=PASS" \
  || fail "CASE F digests collapsed across modes"

echo
echo "FULL_TO_PHASE2_ONLY=$([[ "$FAIL" -eq 0 ]] && echo PASS || echo FAIL)"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
exit 0
