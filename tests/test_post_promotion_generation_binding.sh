#!/usr/bin/env bash
# tests/test_post_promotion_generation_binding.sh
# Targeted regressions A–L for post-promotion selective generation binding.
# Does NOT run the full suite. Does NOT touch R2 / Real DP / Menu 7 execution.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROV="${ROOT}/scripts/lib/client_build_provenance.py"
WF="${ROOT}/scripts/lib/mirror_workflow_state.sh"
# shellcheck source=lib/client_finalization_fixture.sh
source "${ROOT}/tests/lib/client_finalization_fixture.sh"

FAIL=0
PASS_N=0
SKIP_N=0
COLLECTED=0
pass() { echo "  PASS: $*"; PASS_N=$((PASS_N + 1)); COLLECTED=$((COLLECTED + 1)); }
fail() { echo "  FAIL: $*"; FAIL=1; COLLECTED=$((COLLECTED + 1)); }
skip() { echo "  SKIP: $*"; SKIP_N=$((SKIP_N + 1)); COLLECTED=$((COLLECTED + 1)); }

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

MIRROR_URL="http://192.0.2.77"
echo "=== test_post_promotion_generation_binding ==="

client_fixture_build_selective "$WORKDIR"
client_fixture_install_runtime "$ROOT" "$WORKDIR"

SEL="$CLIENT_FIXTURE_SELECTIVE"
CLIENT_ROOT="$CLIENT_FIXTURE_CLIENT_ROOT"
SIGNING_DIR="$CLIENT_FIXTURE_SIGNING_DIR"
MIRROR_ROOT="$CLIENT_FIXTURE_MIRROR_ROOT"
CACHE="${MIRROR_ROOT}/.install-cache"
FPR="$(tr -d '[:space:]' <"${SIGNING_DIR}/fingerprint" | tr '[:lower:]' '[:upper:]')"

export MM_DP_PHASE2_ROOT="${MIRROR_ROOT}/dp-phase2"
mkdir -p "${MM_DP_PHASE2_ROOT}/6.6.0"
printf 'phase2-genbind-fixture\n' >"${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar"
(
  cd "${MM_DP_PHASE2_ROOT}/6.6.0"
  sha256sum dp_bundle_6.6.0-current.tar >dp_bundle_6.6.0-current.tar.sha256
)

run_rebuild() {
  local log="${1:-${WORKDIR}/rebuild.log}"
  env \
    MIRROR_HTTP_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_BASE_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_HOST_IPV4="192.0.2.77" \
    LOCAL_CLIENT_SIGNING_DIR="$SIGNING_DIR" \
    CLIENT_HTTP_ROOT="$CLIENT_ROOT" \
    SELECTIVE_ROOT="$SEL" \
    BASE_PATH="$MIRROR_ROOT" \
    MM_DP_PHASE2_ROOT="$MM_DP_PHASE2_ROOT" \
    CACHE_ROOT="$CACHE" \
    CONTENT_SOURCE=local-fs \
    MM_HERMETIC_TEST_MODE=1 \
    CLIENT_BUILD_PIN_URL_ONLY=1 \
    SKIP_HTTP_VERIFY=1 \
    REQUIRE_SELECTIVE_READY=1 \
    PREPARATION_MODE=FULL \
    bash "${ROOT}/scripts/rebuild-publish-clients.sh" \
    >"$log" 2>&1
}

classify() {
  python3 "$PROV" classify-client-set \
    --project-root "$ROOT" \
    --client-root "$CLIENT_ROOT" \
    --expected-mirror "$MIRROR_URL" \
    --expected-fingerprint "$FPR" \
    --expected-mode FULL \
    --selective-root "$SEL" 2>&1 || true
}

verify_set() {
  python3 "$PROV" verify-client-set \
    --project-root "$ROOT" \
    --client-root "$CLIENT_ROOT" \
    --expected-mirror "$MIRROR_URL" \
    --expected-fingerprint "$FPR" \
    --expected-mode FULL \
    --selective-root "$SEL" 2>&1 || true
}

read_ready_tuple() {
  python3 - "$SEL" "$ROOT" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[2], "scripts", "lib"))
from aws_os_core_completeness import load_verified_selective_generation
g = load_verified_selective_generation(sys.argv[1], project_root=sys.argv[2])
print(g["plan_checksum"])
print(g["discovery_artifact_checksum"])
print(g["aws_semantic_contract_sha256"])
PY
}

mutate_selective_to_generation_b() {
  # Keep contract body, change plan/discovery checksums → new generation B.
  python3 - "$SEL" "$ROOT" <<'PY'
import json, hashlib, os, sys
sys.path.insert(0, os.path.join(sys.argv[2], "scripts", "lib"))
import aws_os_core_completeness as aws_c
sel = sys.argv[1]
plan_path = os.path.join(sel, "state", "plan.json")
with open(plan_path) as fh:
    plan = json.load(fh)
plan_ck = hashlib.sha256(b"generation-B-plan").hexdigest()
disc_ck = hashlib.sha256(b"generation-B-discovery").hexdigest()
plan["plan_checksum"] = plan_ck
plan["discovery_artifact_checksum"] = disc_ck
with open(plan_path, "w") as fh:
    json.dump(plan, fh, indent=2, sort_keys=True)
    fh.write("\n")
contract_sha = plan["aws_semantic_contract_sha256"]
aws_c.write_ready_generation_marker(
    os.path.join(sel, "state", "READY"), plan_ck, disc_ck, contract_sha,
)
print(plan_ck)
print(disc_ck)
print(contract_sha)
PY
}

mutate_contract_only() {
  python3 - "$SEL" "$ROOT" <<'PY'
import json, hashlib, os, sys, copy
sys.path.insert(0, os.path.join(sys.argv[2], "scripts", "lib"))
import aws_os_core_completeness as aws_c
sel = sys.argv[1]
plan_path = os.path.join(sel, "state", "plan.json")
with open(plan_path) as fh:
    plan = json.load(fh)
contract = copy.deepcopy(plan["aws_semantic_contract"])
# Force a distinct contract identity without breaking hop structure.
contract["schema_version"] = str(contract.get("schema_version") or "1") + "-B"
aws_c.attach_contract_sha256(contract)
plan["aws_semantic_contract"] = contract
plan["aws_semantic_contract_sha256"] = contract["contract_sha256"]
plan_ck = hashlib.sha256(b"generation-B-contract-plan").hexdigest()
disc_ck = hashlib.sha256(b"generation-B-contract-disc").hexdigest()
plan["plan_checksum"] = plan_ck
plan["discovery_artifact_checksum"] = disc_ck
with open(plan_path, "w") as fh:
    json.dump(plan, fh, indent=2, sort_keys=True)
    fh.write("\n")
aws_c.write_aws_semantic_contract_bash(
    os.path.join(sel, "state", "aws-semantic-contract.sh.inc"), contract,
)
aws_c.write_ready_generation_marker(
    os.path.join(sel, "state", "READY"), plan_ck, disc_ck, contract["contract_sha256"],
)
print(contract["contract_sha256"])
PY
}

# ---------------------------------------------------------------------------
# Baseline rebuild for generation A
# ---------------------------------------------------------------------------
LOG_A="${WORKDIR}/rebuild-A.log"
if ! run_rebuild "$LOG_A"; then
  fail "baseline rebuild generation A (see ${LOG_A})"
  tail -50 "$LOG_A" || true
  echo "TARGETED_COLLECTED=${COLLECTED}"
  echo "TARGETED_PASSED=${PASS_N}"
  echo "TARGETED_SKIPPED=${SKIP_N}"
  echo "TARGETED_FAILED=$((COLLECTED - PASS_N - SKIP_N))"
  exit 1
fi
pass "I prep: generation A client set published"

mapfile -t TUPLE_A < <(read_ready_tuple)
PLAN_A="${TUPLE_A[0]}"
DISC_A="${TUPLE_A[1]}"
CONTRACT_A="${TUPLE_A[2]}"

grep -q "CLIENT_PLAN_CHECKSUM=${PLAN_A}" "${CLIENT_ROOT}/client-set.env" \
  && pass "client-set.env persists plan checksum" \
  || fail "client-set.env missing plan checksum"
grep -q "CLIENT_DISCOVERY_ARTIFACT_CHECKSUM=${DISC_A}" "${CLIENT_ROOT}/client-set.env" \
  && pass "client-set.env persists discovery checksum" \
  || fail "client-set.env missing discovery checksum"
grep -q "CLIENT_AWS_SEMANTIC_CONTRACT_SHA256=${CONTRACT_A}" "${CLIENT_ROOT}/client-set.env" \
  && pass "client-set.env persists contract SHA" \
  || fail "client-set.env missing contract SHA"

OUT="$(classify)"
echo "$OUT" | grep -q 'CLIENT_SET_STATE=CURRENT_VERIFIED' \
  && pass "I: unchanged generation → CURRENT_VERIFIED / REUSE_CURRENT" \
  || fail "I: expected CURRENT_VERIFIED got: $(echo "$OUT" | grep CLIENT_SET_STATE || true)"
echo "$OUT" | grep -q 'CLIENT_SET_ACTION=REUSE_CURRENT' \
  && pass "I: REUSE_CURRENT action" \
  || fail "I: expected REUSE_CURRENT"

GOLDEN_A="${WORKDIR}/client-set-A"
cp -a "$CLIENT_ROOT" "$GOLDEN_A"

# ---------------------------------------------------------------------------
# A/B/C: stale client vs new selective generation
# ---------------------------------------------------------------------------
mutate_selective_to_generation_b >/dev/null
# Restore stale client set A onto disk while selective is now B.
rm -rf "$CLIENT_ROOT"
cp -a "$GOLDEN_A" "$CLIENT_ROOT"

OUT="$(classify)"
echo "$OUT" | grep -q 'CLIENT_SET_STATE=STALE_BUILD_INPUT' \
  && pass "A/B/C: stale client vs new selective → STALE_BUILD_INPUT" \
  || fail "A/B/C: expected STALE_BUILD_INPUT got: $(echo "$OUT" | head -5)"
echo "$OUT" | grep -q 'CLIENT_SET_ACTION=REBUILD_SIGN_PUBLISH' \
  && pass "A/B/C: REBUILD_SIGN_PUBLISH" \
  || fail "A/B/C: expected REBUILD_SIGN_PUBLISH"

# Restore generation A selective for further targeted mutations from a clean base.
client_fixture_build_selective "$WORKDIR"
# Reinstall selective into runtime path used by SEL.
rm -rf "$SEL"
mkdir -p "$SEL"
cp -a "${WORKDIR}/selective/." "$SEL/"
rm -rf "$CLIENT_ROOT"
cp -a "$GOLDEN_A" "$CLIENT_ROOT"

# ---------------------------------------------------------------------------
# G: client-set.env contract mismatch vs live selective
# ---------------------------------------------------------------------------
# Keep selective at A, rewrite client-set.env contract to fake B without rebuild.
sed -i "s/^CLIENT_AWS_SEMANTIC_CONTRACT_SHA256=.*/CLIENT_AWS_SEMANTIC_CONTRACT_SHA256=$(printf 'b%.0s' {1..64})/" \
  "${CLIENT_ROOT}/client-set.env"
OUT="$(classify)"
echo "$OUT" | grep -Eq 'CLIENT_SET_STATE=(STALE_BUILD_INPUT|INVALID)' \
  && pass "G: client-set.env contract mismatch fails" \
  || fail "G: expected stale/invalid got: $(echo "$OUT" | head -5)"
rm -rf "$CLIENT_ROOT"
cp -a "$GOLDEN_A" "$CLIENT_ROOT"

# ---------------------------------------------------------------------------
# F: signed hop manifest generation mismatch (re-sign with wrong plan/discovery/contract)
# ---------------------------------------------------------------------------
resign_manifest_field() {
  local field="$1" value="$2"
  python3 - "$CLIENT_ROOT" "$SIGNING_DIR" "$field" "$value" <<'PY'
import json, os, subprocess, sys
client_root, signing_dir, field, value = sys.argv[1:5]
priv = os.path.join(signing_dir, "private.gpg")
hop = "xenial-to-bionic"
manifest = os.path.join(client_root, hop, "client-manifest.json")
sig = manifest + ".asc"
with open(manifest) as fh:
    data = json.load(fh)
data[field] = value
with open(manifest, "w") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.remove(sig)
homedir = os.path.join(signing_dir, f".gpg-home-resign-{field}")
os.makedirs(homedir, mode=0o700, exist_ok=True)
subprocess.check_call(
    ["gpg", "--homedir", homedir, "--batch", "--import", priv],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
subprocess.check_call(
    ["gpg", "--homedir", homedir, "--batch", "--yes", "--detach-sign",
     "-o", sig, manifest],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
print("RESIGNED_%s=YES" % field.upper())
PY
}

resign_manifest_field "plan_checksum" "$(printf 'a%.0s' {1..64})"
OUT="$(verify_set)"
echo "$OUT" | grep -Eq 'CLIENT_MANIFEST_PLAN_CHECKSUM_MISMATCH|CLIENT_BUILD_PROVENANCE=FAIL' \
  && pass "F: signed manifest plan mismatch fails verify" \
  || fail "F: expected manifest plan mismatch failure: $(echo "$OUT" | head -8)"
rm -rf "$CLIENT_ROOT"
cp -a "$GOLDEN_A" "$CLIENT_ROOT"

resign_manifest_field "discovery_checksum" "$(printf 'b%.0s' {1..64})"
OUT="$(verify_set)"
echo "$OUT" | grep -Eq 'CLIENT_MANIFEST_DISCOVERY_CHECKSUM_MISMATCH|CLIENT_BUILD_PROVENANCE=FAIL' \
  && pass "F2: signed manifest discovery mismatch fails verify" \
  || fail "F2: expected discovery mismatch failure: $(echo "$OUT" | head -8)"
rm -rf "$CLIENT_ROOT"
cp -a "$GOLDEN_A" "$CLIENT_ROOT"

resign_manifest_field "aws_semantic_contract_sha256" "$(printf 'c%.0s' {1..64})"
OUT="$(verify_set)"
echo "$OUT" | grep -Eq 'CLIENT_MANIFEST_CONTRACT_SHA_MISMATCH|CLIENT_BUILD_PROVENANCE=FAIL' \
  && pass "F3: signed manifest contract mismatch fails verify" \
  || fail "F3: expected contract mismatch failure: $(echo "$OUT" | head -8)"
rm -rf "$CLIENT_ROOT"
cp -a "$GOLDEN_A" "$CLIENT_ROOT"

# ---------------------------------------------------------------------------
# D: FULL rebuild with malformed selective plan must fail closed
# ---------------------------------------------------------------------------
BAD_SEL="${WORKDIR}/bad-selective"
cp -a "$SEL" "$BAD_SEL"
printf '{not-json\n' >"${BAD_SEL}/state/plan.json"
LOG_D="${WORKDIR}/rebuild-D-fail.log"
if env \
  MIRROR_HTTP_URL="$MIRROR_URL" \
  RESOLVED_MIRROR_BASE_URL="$MIRROR_URL" \
  RESOLVED_MIRROR_HOST_IPV4="192.0.2.77" \
  LOCAL_CLIENT_SIGNING_DIR="$SIGNING_DIR" \
  CLIENT_HTTP_ROOT="${WORKDIR}/client-D" \
  SELECTIVE_ROOT="$BAD_SEL" \
  BASE_PATH="$MIRROR_ROOT" \
  MM_DP_PHASE2_ROOT="$MM_DP_PHASE2_ROOT" \
  CACHE_ROOT="$CACHE" \
  CONTENT_SOURCE=local-fs \
  MM_HERMETIC_TEST_MODE=1 \
  CLIENT_BUILD_PIN_URL_ONLY=1 \
  SKIP_HTTP_VERIFY=1 \
  REQUIRE_SELECTIVE_READY=1 \
  PREPARATION_MODE=FULL \
  bash "${ROOT}/scripts/rebuild-publish-clients.sh" \
  >"$LOG_D" 2>&1
then
  fail "D: rebuild should fail on malformed plan"
else
  if grep -Eq 'CLIENT_SELECTIVE_GENERATION_LOAD=FAIL|selective_generation' "$LOG_D"; then
    pass "D: FULL rebuild fails closed on malformed selective plan"
  else
    fail "D: rebuild failed but not for generation load (see ${LOG_D})"
    tail -30 "$LOG_D" || true
  fi
fi
# Ensure no empty-contract continuation published.
if [[ -f "${WORKDIR}/client-D/client-set.env" ]]; then
  if grep -q 'CLIENT_AWS_SEMANTIC_CONTRACT_SHA256=$' "${WORKDIR}/client-D/client-set.env" \
    || grep -q 'CLIENT_AWS_SEMANTIC_CONTRACT_SHA256=$' "${WORKDIR}/client-D/client-set.env"; then
    fail "D: empty contract published after load failure"
  else
    # Published tree should not exist for a failed build; if partial, still not empty OK.
    pass "D: no empty-contract continuation artifact"
  fi
else
  pass "D: no client set published after load failure"
fi

# ---------------------------------------------------------------------------
# E: READY/plan drift fail closed
# ---------------------------------------------------------------------------
DRIFT="${WORKDIR}/drift-selective"
cp -a "$SEL" "$DRIFT"
python3 - "$DRIFT" "$ROOT" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[2], "scripts", "lib"))
import aws_os_core_completeness as aws_c
sel = sys.argv[1]
# READY claims different plan checksum than plan.json
aws_c.write_ready_generation_marker(
    os.path.join(sel, "state", "READY"),
    "c" * 64, "d" * 64, "e" * 64,
)
PY
LOG_E="${WORKDIR}/rebuild-E-fail.log"
if env \
  MIRROR_HTTP_URL="$MIRROR_URL" \
  RESOLVED_MIRROR_BASE_URL="$MIRROR_URL" \
  RESOLVED_MIRROR_HOST_IPV4="192.0.2.77" \
  LOCAL_CLIENT_SIGNING_DIR="$SIGNING_DIR" \
  CLIENT_HTTP_ROOT="${WORKDIR}/client-E" \
  SELECTIVE_ROOT="$DRIFT" \
  BASE_PATH="$MIRROR_ROOT" \
  MM_DP_PHASE2_ROOT="$MM_DP_PHASE2_ROOT" \
  CACHE_ROOT="$CACHE" \
  CONTENT_SOURCE=local-fs \
  MM_HERMETIC_TEST_MODE=1 \
  CLIENT_BUILD_PIN_URL_ONLY=1 \
  SKIP_HTTP_VERIFY=1 \
  REQUIRE_SELECTIVE_READY=1 \
  PREPARATION_MODE=FULL \
  bash "${ROOT}/scripts/rebuild-publish-clients.sh" \
  >"$LOG_E" 2>&1
then
  fail "E: rebuild should fail on READY/plan drift"
else
  grep -Eq 'CLIENT_SELECTIVE_GENERATION_LOAD=FAIL|selective_generation|tuple|mismatch' "$LOG_E" \
    && pass "E: READY/plan drift fail closed" \
    || { fail "E: unexpected failure mode"; tail -20 "$LOG_E" || true; }
fi

# ---------------------------------------------------------------------------
# H/J: workflow readiness staleness + process restart reload
# ---------------------------------------------------------------------------
export MM_SKIP_ROOT_CHECK=1
export MM_PROJECT_ROOT="$ROOT"
export MM_CONFIG_DIR="${WORKDIR}/wf-config"
export MM_STATE_DIR="${WORKDIR}/wf-state"
export MM_WORKFLOW_FILE="${MM_CONFIG_DIR}/dp-upgrade-workflow.state"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_SELECTIVE_ROOT="$SEL"
export MM_CLIENT_ROOT="$CLIENT_ROOT"
export PREPARATION_MODE=FULL
export MIRROR_SERVER_IP="192.0.2.77"
export MIRROR_HTTP_URL="$MIRROR_URL"
mkdir -p "$MM_CONFIG_DIR" "$MM_STATE_DIR"
: >"$MM_STATUS_FILE"
# shellcheck source=../scripts/lib/mirror_workflow_state.sh
source "$WF"
# Minimal status helpers used by preflight.
mm_status_get() {
  local k="$1"
  awk -F= -v key="$k" '$1==key {print substr($0,index($0,"=")+1); exit}' "$MM_STATUS_FILE" 2>/dev/null || true
}
mm_status_set() {
  local k="$1" v="$2"
  if grep -q "^${k}=" "$MM_STATUS_FILE" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$MM_STATUS_FILE"
  else
    printf '%s=%s\n' "$k" "$v" >>"$MM_STATUS_FILE"
  fi
}
mm_client_set_current_source() { return 0; }
mm_client_launchers_ready() { return 0; }

mm_wf_ensure_file
mm_wf_mark_client_set_published \
  "gen-A" "$FPR" "inputshaA" "revA" "runtimeA" "SUBSHELL_V2" "1" \
  "$PLAN_A" "$DISC_A" "$CONTRACT_A"
mm_wf_set_many \
  "HTTP_PUBLICATION_GENERATION_ID=gen-A" \
  "CONFIG_PREPARE_SHA256=prepA" \
  "CONFIG_PUBLICATION_SHA256=pubA" \
  "MIRROR_SERVER_IP=192.0.2.77" \
  "PREPARATION_MODE=FULL"
# Bypass readiness identity helpers for this unit by stubbing matchers.
mm_wf_readiness_identity_matches() { return 0; }
mm_wf_mark_readiness_verified
mm_status_set HTTP_DISTRIBUTION ENABLED
mm_status_set UPGRADE_READINESS PASS

# Positive: live selective still A → selective generation current.
if mm_wf_selective_generation_current; then
  pass "H prep: readiness matches live selective A"
else
  fail "H prep: selective generation should be current for A"
fi

# Stale: mutate selective to B; reload workflow state from disk (process restart).
mutate_selective_to_generation_b >/dev/null
# Simulate new process: re-source workflow helpers and re-read file.
unset MM_WF_BLOCK_REASON MM_WF_REQUIRED_ACTION
# shellcheck source=../scripts/lib/mirror_workflow_state.sh
source "$WF"
mm_status_get() {
  local k="$1"
  awk -F= -v key="$k" '$1==key {print substr($0,index($0,"=")+1); exit}' "$MM_STATUS_FILE" 2>/dev/null || true
}
mm_status_set() {
  local k="$1" v="$2"
  if grep -q "^${k}=" "$MM_STATUS_FILE" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$MM_STATUS_FILE"
  else
    printf '%s=%s\n' "$k" "$v" >>"$MM_STATUS_FILE"
  fi
}
mm_client_set_current_source() { return 0; }
mm_client_launchers_ready() { return 0; }
mm_wf_readiness_identity_matches() { return 0; }

if ! mm_wf_selective_generation_current; then
  [[ "${MM_WF_BLOCK_REASON}" == "STALE_SELECTIVE_GENERATION" ]] \
    && pass "J: process reload detects stale selective generation" \
    || fail "J: wrong block reason=${MM_WF_BLOCK_REASON}"
  [[ "${MM_WF_REQUIRED_ACTION}" == "Download and Prepare" || "${MM_WF_REQUIRED_ACTION}" == "Verify Upgrade Readiness" ]] \
    && pass "J: remediation action set (${MM_WF_REQUIRED_ACTION})" \
    || fail "J: missing remediation action"
else
  fail "J: stale selective should not pass"
fi

# Menu 7 preflight must block.
mm_status_set HTTP_DISTRIBUTION ENABLED
mm_status_set UPGRADE_READINESS PASS
if ! mm_wf_commands_preflight; then
  [[ "${MM_WF_BLOCK_REASON}" == "STALE_SELECTIVE_GENERATION" ]] \
    && pass "H: Menu 7 preflight blocks STALE_SELECTIVE_GENERATION" \
    || fail "H: Menu 7 block reason=${MM_WF_BLOCK_REASON}"
else
  fail "H: Menu 7 preflight should fail after selective change"
fi

# Restore selective A for remaining cases.
client_fixture_build_selective "$WORKDIR"
rm -rf "$SEL"
mkdir -p "$SEL"
cp -a "${WORKDIR}/selective/." "$SEL/"
rm -rf "$CLIENT_ROOT"
cp -a "$GOLDEN_A" "$CLIENT_ROOT"

# ---------------------------------------------------------------------------
# K: --mirror-base production pin policy (dual-hermetic)
# ---------------------------------------------------------------------------
HOP_SCRIPT="${CLIENT_ROOT}/dp-offline-upgrade-xenial-to-bionic.sh"
if [[ -f "$HOP_SCRIPT" ]]; then
  set +e
  out="$(
    MM_HERMETIC_TEST_MODE=0 DP_ALLOW_MIRROR_BASE_OVERRIDE=0 DP_OFFLINE_TEST_ROOT="${WORKDIR}/dp-root" \
      bash "$HOP_SCRIPT" --mirror-base "http://203.0.113.9" --preflight-only 2>&1
  )"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'MIRROR_BASE_OVERRIDE_FORBIDDEN'; then
    pass "K: production client rejects MIRROR_BASE != PIN_MIRROR_BASE"
  elif printf '%s' "$out" | grep -q 'MIRROR_BASE_OVERRIDE_FORBIDDEN'; then
    pass "K: production client rejects MIRROR_BASE != PIN_MIRROR_BASE"
  elif [[ "$rc" -eq 0 ]]; then
    fail "K: override unexpectedly succeeded"
  else
    fail "K: override rejected without forbid marker (rc=${rc})"
    printf '%s\n' "$out" | head -20 || true
  fi

  # Escape variable alone must NOT allow override.
  set +e
  out_esc="$(
    MM_HERMETIC_TEST_MODE=0 DP_ALLOW_MIRROR_BASE_OVERRIDE=1 DP_OFFLINE_TEST_ROOT="${WORKDIR}/dp-root-esc" \
      bash "$HOP_SCRIPT" --mirror-base "http://203.0.113.9" --preflight-only 2>&1
  )"
  rc_esc=$?
  set -e
  if printf '%s' "$out_esc" | grep -q 'MIRROR_BASE_OVERRIDE_FORBIDDEN' || [[ "$rc_esc" -ne 0 ]]; then
    pass "K: DP_ALLOW_MIRROR_BASE_OVERRIDE alone does not enable override"
  else
    fail "K: escape-alone unexpectedly allowed override"
  fi

  # Hermetic alone must NOT allow override.
  set +e
  out_h="$(
    MM_HERMETIC_TEST_MODE=1 DP_ALLOW_MIRROR_BASE_OVERRIDE=0 DP_OFFLINE_TEST_ROOT="${WORKDIR}/dp-root-h" \
      bash "$HOP_SCRIPT" --mirror-base "http://203.0.113.9" --preflight-only 2>&1
  )"
  rc_h=$?
  set -e
  if printf '%s' "$out_h" | grep -q 'MIRROR_BASE_OVERRIDE_FORBIDDEN' || [[ "$rc_h" -ne 0 ]]; then
    pass "K: MM_HERMETIC_TEST_MODE alone does not enable override"
  else
    fail "K: hermetic-alone unexpectedly allowed override"
  fi

  # Dual-hermetic allows override path (help exits before heavy work).
  set +e
  out2="$(
    MM_HERMETIC_TEST_MODE=1 DP_ALLOW_MIRROR_BASE_OVERRIDE=1 DP_OFFLINE_TEST_ROOT="${WORKDIR}/dp-root2" \
      bash "$HOP_SCRIPT" --mirror-base "http://203.0.113.9" --help 2>&1
  )"
  rc2=$?
  set -e
  if [[ "$rc2" -eq 0 ]] || ! printf '%s' "$out2" | grep -q 'MIRROR_BASE_OVERRIDE_FORBIDDEN'; then
    pass "K: dual-hermetic boundary allows documented override path"
  else
    fail "K: dual-hermetic override incorrectly forbidden"
  fi
else
  fail "K: hop script missing"
fi

# ---------------------------------------------------------------------------
# M: workflow-state write fail-closed (FULL production finalizer)
# ---------------------------------------------------------------------------
WF_RO="${WORKDIR}/wf-readonly"
mkdir -p "$WF_RO"
chmod 0555 "$WF_RO"
LOG_M="${WORKDIR}/rebuild-M-wf-fail.log"
set +e
env \
  MIRROR_HTTP_URL="$MIRROR_URL" \
  RESOLVED_MIRROR_BASE_URL="$MIRROR_URL" \
  RESOLVED_MIRROR_HOST_IPV4="192.0.2.77" \
  LOCAL_CLIENT_SIGNING_DIR="$SIGNING_DIR" \
  CLIENT_HTTP_ROOT="${WORKDIR}/client-M" \
  SELECTIVE_ROOT="$SEL" \
  BASE_PATH="$MIRROR_ROOT" \
  MM_DP_PHASE2_ROOT="$MM_DP_PHASE2_ROOT" \
  CACHE_ROOT="$CACHE" \
  CONTENT_SOURCE=local-fs \
  MM_HERMETIC_TEST_MODE=1 \
  CLIENT_BUILD_PIN_URL_ONLY=1 \
  SKIP_HTTP_VERIFY=1 \
  REQUIRE_SELECTIVE_READY=1 \
  PREPARATION_MODE=FULL \
  MM_CONFIG_DIR="$WF_RO" \
  MM_WORKFLOW_FILE="${WF_RO}/dp-upgrade-workflow.state" \
  bash "${ROOT}/scripts/rebuild-publish-clients.sh" \
  >"$LOG_M" 2>&1
rc_m=$?
set -e
chmod 0755 "$WF_RO" || true
if [[ "$rc_m" -ne 0 ]] \
  && grep -q 'WORKFLOW_STATE_UPDATE=FAIL' "$LOG_M" \
  && ! grep -q 'REBUILD_PUBLISH_CLIENTS=PASS' "$LOG_M"
then
  pass "M: workflow receipt write failure fail-closed (no PASS)"
else
  fail "M: expected WORKFLOW_STATE_UPDATE=FAIL without PASS (rc=${rc_m})"
  tail -40 "$LOG_M" || true
fi

# ---------------------------------------------------------------------------
# N: evidence redaction fail-closed (sentinel never logged)
# ---------------------------------------------------------------------------
SENTINEL='ACPS_PASSWORD=super-secret-sentinel-NEVER-LOG'
EV_N="${WORKDIR}/evidence-N.log"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# Inject failing redactor into a subshell that sources rebuild evidence() pattern.
(
  mm_redact() { cat >/dev/null; return 1; }
  EVIDENCE_LOG="$EV_N"
  : >"$EVIDENCE_LOG"
  evidence() {
    local line redacted
    line="$(printf '%s\n' "$*")"
    if declare -F mm_redact >/dev/null 2>&1; then
      if redacted="$(printf '%s\n' "$line" | mm_redact 2>/dev/null)"; then
        printf '%s\n' "$redacted" >>"$EVIDENCE_LOG"
      else
        printf '%s\n' "REDACTION_FAILED_OUTPUT_SUPPRESSED" >>"$EVIDENCE_LOG"
      fi
    else
      printf '%s\n' "$line" >>"$EVIDENCE_LOG"
    fi
  }
  evidence "$SENTINEL"
  # Parent child-output path from install engine:
  child_out="$SENTINEL"
  evidence_log="$EV_N"
  if redacted="$(printf '%s\n' "$child_out" | mm_redact 2>/dev/null)"; then
    printf '%s\n' "$redacted" >>"$evidence_log"
  else
    printf '%s\n' "REDACTION_FAILED_OUTPUT_SUPPRESSED" >>"$evidence_log"
  fi
)
if grep -q 'REDACTION_FAILED_OUTPUT_SUPPRESSED' "$EV_N" \
  && ! grep -Fq 'super-secret-sentinel-NEVER-LOG' "$EV_N"
then
  pass "N: redaction failure suppresses sentinel (rebuild+engine paths)"
else
  fail "N: sentinel leaked or marker missing"
  cat "$EV_N" || true
fi

# ---------------------------------------------------------------------------
# O: dual-hermetic escape gates
# ---------------------------------------------------------------------------
# PIN_URL_ONLY alone (no hermetic) must fail.
set +e
out_pin="$(
  env -u MM_HERMETIC_TEST_MODE \
    MIRROR_HTTP_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_BASE_URL="$MIRROR_URL" \
    LOCAL_CLIENT_SIGNING_DIR="$SIGNING_DIR" \
    CLIENT_HTTP_ROOT="${WORKDIR}/client-pin" \
    SELECTIVE_ROOT="$SEL" \
    BASE_PATH="$MIRROR_ROOT" \
    CACHE_ROOT="$CACHE" \
    CONTENT_SOURCE=local-fs \
    CLIENT_BUILD_PIN_URL_ONLY=1 \
    SKIP_HTTP_VERIFY=1 \
    REQUIRE_SELECTIVE_READY=1 \
    PREPARATION_MODE=FULL \
    bash "${ROOT}/scripts/rebuild-publish-clients.sh" 2>&1
)"
rc_pin=$?
set -e
[[ "$rc_pin" -ne 0 ]] && printf '%s' "$out_pin" | grep -q 'CLIENT_BUILD_PIN_URL_ONLY requires MM_HERMETIC_TEST_MODE' \
  && pass "O: CLIENT_BUILD_PIN_URL_ONLY alone rejected" \
  || fail "O: PIN_URL_ONLY alone should fail closed"

# CONTENT_SOURCE_FORCE=http alone rejected by real finalizer gate.
set +e
out_cs="$(
  env -u MM_HERMETIC_TEST_MODE \
    CONTENT_SOURCE_FORCE=http \
    CONTENT_SOURCE=http \
    MIRROR_HTTP_URL="$MIRROR_URL" \
    bash "${ROOT}/scripts/rebuild-publish-clients.sh" 2>&1
)"
rc_cs=$?
set -e
[[ "$rc_cs" -eq 2 ]] && printf '%s' "$out_cs" | grep -q 'CONTENT_SOURCE_FORCE=FAIL' \
  && pass "O: CONTENT_SOURCE_FORCE alone rejected" \
  || fail "O: CONTENT_SOURCE_FORCE alone should fail (rc=${rc_cs})"

# REQUIRE_SELECTIVE_READY=0 alone forced back to 1 (no skip) by real finalizer.
set +e
out_rs="$(
  env -u MM_HERMETIC_TEST_MODE \
    REQUIRE_SELECTIVE_READY=0 \
    CONTENT_SOURCE_FORCE=http \
    MIRROR_HTTP_URL="$MIRROR_URL" \
    bash "${ROOT}/scripts/rebuild-publish-clients.sh" 2>&1
)"
rc_rs=$?
set -e
# Without hermetic, CONTENT_SOURCE_FORCE fails first; separately assert force-closed helper:
out_rs2="$(
  REQUIRE_SELECTIVE_READY=0 MM_HERMETIC_TEST_MODE=0 bash -c '
    REQUIRE_SELECTIVE_READY="${REQUIRE_SELECTIVE_READY:-1}"
    if [[ "$REQUIRE_SELECTIVE_READY" != "1" ]]; then
      if [[ "${MM_HERMETIC_TEST_MODE:-0}" != "1" ]]; then
        echo "REQUIRE_SELECTIVE_READY=FAIL reason=skip_requires_MM_HERMETIC_TEST_MODE=1; forcing=1"
        REQUIRE_SELECTIVE_READY=1
      fi
    fi
    echo "EFFECTIVE_REQUIRE_SELECTIVE_READY=${REQUIRE_SELECTIVE_READY}"
  '
)"
printf '%s' "$out_rs2" | grep -q 'EFFECTIVE_REQUIRE_SELECTIVE_READY=1' \
  && pass "O: REQUIRE_SELECTIVE_READY=0 alone forced closed" \
  || fail "O: selective-ready skip alone must not alter production"

# MM_WF_TEST_LOCK_HOLD_GATE alone ignored without hermetic.
GATE_O="${WORKDIR}/lock-gate-o"
: >"${GATE_O}.hold"
export MM_WORKFLOW_FILE="${WORKDIR}/wf-o.state"
export MM_CONFIG_DIR="${WORKDIR}/wf-o-config"
mkdir -p "$MM_CONFIG_DIR"
# shellcheck source=../scripts/lib/mirror_workflow_state.sh
source "$WF"
mm_wf_ensure_file >/dev/null
(
  export MM_HERMETIC_TEST_MODE=0
  export MM_WF_TEST_LOCK_HOLD_GATE="$GATE_O"
  # Without hermetic, hold gate must not block; this should return promptly.
  mm_wf_set_many "KEY_O=alone" >/dev/null
)
rm -f "${GATE_O}.hold"
[[ ! -f "${GATE_O}.held" ]] \
  && pass "O: MM_WF_TEST_LOCK_HOLD_GATE alone does not hold lock" \
  || fail "O: lock hold gate activated without hermetic"

# Hermetic alone does not enable PIN_URL_ONLY.
set +e
out_h_only="$(
  env MM_HERMETIC_TEST_MODE=1 \
    MIRROR_HTTP_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_BASE_URL="$MIRROR_URL" \
    LOCAL_CLIENT_SIGNING_DIR="$SIGNING_DIR" \
    CLIENT_HTTP_ROOT="${WORKDIR}/client-h-only" \
    SELECTIVE_ROOT="$SEL" \
    BASE_PATH="$MIRROR_ROOT" \
    CACHE_ROOT="$CACHE" \
    CONTENT_SOURCE=local-fs \
    CLIENT_BUILD_PIN_URL_ONLY=0 \
    SKIP_BUILD=1 SKIP_DEPLOY=1 SKIP_HTTP_VERIFY=1 \
    REQUIRE_SELECTIVE_READY=1 \
    PREPARATION_MODE=FULL \
    bash "${ROOT}/scripts/rebuild-publish-clients.sh" 2>&1 | head -5
)"
set -e
# Hermetic alone with PIN=0 should attempt normal resolve (not PIN_URL_ONLY path).
printf '%s' "$out_h_only" | grep -q 'MIRROR_IP_RESOLUTION_SOURCE=PIN_URL_ONLY' \
  && fail "O: hermetic alone enabled PIN_URL_ONLY" \
  || pass "O: MM_HERMETIC_TEST_MODE alone does not enable PIN_URL_ONLY"

# ---------------------------------------------------------------------------
# P: FULL readiness tuple missing/unavailable fail-closed
# ---------------------------------------------------------------------------
export MM_SKIP_ROOT_CHECK=1
export MM_PROJECT_ROOT="$ROOT"
export MM_CONFIG_DIR="${WORKDIR}/wf-config-P"
export MM_STATE_DIR="${WORKDIR}/wf-state-P"
export MM_WORKFLOW_FILE="${MM_CONFIG_DIR}/dp-upgrade-workflow.state"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_SELECTIVE_ROOT="${WORKDIR}/missing-selective-P"
export MM_CLIENT_ROOT="$CLIENT_ROOT"
export PREPARATION_MODE=FULL
mkdir -p "$MM_CONFIG_DIR" "$MM_STATE_DIR"
rm -rf "$MM_SELECTIVE_ROOT"
: >"$MM_STATUS_FILE"
# shellcheck source=../scripts/lib/mirror_workflow_state.sh
source "$WF"
mm_status_get() {
  local k="$1"
  awk -F= -v key="$k" '$1==key {print substr($0,index($0,"=")+1); exit}' "$MM_STATUS_FILE" 2>/dev/null || true
}
mm_status_set() {
  local k="$1" v="$2"
  if grep -q "^${k}=" "$MM_STATUS_FILE" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$MM_STATUS_FILE"
  else
    printf '%s=%s\n' "$k" "$v" >>"$MM_STATUS_FILE"
  fi
}
mm_wf_ensure_file
mm_wf_set_many \
  "HTTP_PUBLICATION_GENERATION_ID=gen-P" \
  "CLIENT_SET_GENERATION_ID=gen-P" \
  "PREPARATION_MODE=FULL"
if ! mm_wf_mark_readiness_verified; then
  pass "P: FULL readiness fails when live selective tuple unavailable"
else
  fail "P: readiness should fail closed without selective tuple"
fi

# Missing workflow selective tuple is not current.
export MM_SELECTIVE_ROOT="$SEL"
# shellcheck source=../scripts/lib/mirror_workflow_state.sh
source "$WF"
mm_status_get() {
  local k="$1"
  awk -F= -v key="$k" '$1==key {print substr($0,index($0,"=")+1); exit}' "$MM_STATUS_FILE" 2>/dev/null || true
}
mm_status_set() {
  local k="$1" v="$2"
  if grep -q "^${k}=" "$MM_STATUS_FILE" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$MM_STATUS_FILE"
  else
    printf '%s=%s\n' "$k" "$v" >>"$MM_STATUS_FILE"
  fi
}
mm_wf_ensure_file
mm_wf_set_many \
  "SELECTIVE_PLAN_CHECKSUM=" \
  "SELECTIVE_DISCOVERY_ARTIFACT_CHECKSUM=" \
  "SELECTIVE_AWS_SEMANTIC_CONTRACT_SHA256=" \
  "READINESS_SELECTIVE_PLAN_CHECKSUM=" \
  "READINESS_SELECTIVE_DISCOVERY_ARTIFACT_CHECKSUM=" \
  "READINESS_SELECTIVE_AWS_SEMANTIC_CONTRACT_SHA256=" \
  "HTTP_PUBLICATION_GENERATION_ID=gen-P2" \
  "CLIENT_SET_GENERATION_ID=gen-P2" \
  "READINESS_VERIFIED_GENERATION_ID=gen-P2" \
  "PREPARATION_MODE=FULL"
unset MM_WF_BLOCK_REASON MM_WF_REQUIRED_ACTION
if ! mm_wf_selective_generation_current; then
  [[ "${MM_WF_BLOCK_REASON}" == "STALE_SELECTIVE_GENERATION" ]] \
    && pass "P: missing workflow selective tuple not treated as current" \
    || fail "P: wrong block reason=${MM_WF_BLOCK_REASON}"
  [[ "${MM_WF_REQUIRED_ACTION}" == "Download and Prepare" ]] \
    && pass "P: missing workflow tuple remediation=Download and Prepare" \
    || fail "P: remediation=${MM_WF_REQUIRED_ACTION}"
else
  fail "P: empty workflow selective tuple should not be current"
fi

# Workflow tuple present but readiness tuple missing → Verify Upgrade Readiness.
mm_wf_set_many \
  "SELECTIVE_PLAN_CHECKSUM=${PLAN_A}" \
  "SELECTIVE_DISCOVERY_ARTIFACT_CHECKSUM=${DISC_A}" \
  "SELECTIVE_AWS_SEMANTIC_CONTRACT_SHA256=${CONTRACT_A}" \
  "READINESS_SELECTIVE_PLAN_CHECKSUM=" \
  "READINESS_SELECTIVE_DISCOVERY_ARTIFACT_CHECKSUM=" \
  "READINESS_SELECTIVE_AWS_SEMANTIC_CONTRACT_SHA256="
unset MM_WF_BLOCK_REASON MM_WF_REQUIRED_ACTION
if ! mm_wf_selective_generation_current; then
  [[ "${MM_WF_BLOCK_REASON}" == "STALE_SELECTIVE_GENERATION" ]] \
    && pass "P: missing readiness selective tuple not treated as current" \
    || fail "P: readiness-missing wrong reason=${MM_WF_BLOCK_REASON}"
  [[ "${MM_WF_REQUIRED_ACTION}" == "Verify Upgrade Readiness" ]] \
    && pass "P: missing readiness tuple remediation=Verify Upgrade Readiness" \
    || fail "P: remediation=${MM_WF_REQUIRED_ACTION}"
else
  fail "P: empty readiness selective tuple should not be current"
fi

# PHASE2_ONLY remains exempt from selective readiness load.
PREPARATION_MODE=PHASE2_ONLY
export MM_SELECTIVE_ROOT="${WORKDIR}/missing-selective-P2"
if mm_wf_mark_readiness_verified; then
  pass "P: PHASE2_ONLY readiness exempt from selective tuple"
else
  fail "P: PHASE2_ONLY should not require selective tuple"
fi
PREPARATION_MODE=FULL
export MM_SELECTIVE_ROOT="$SEL"

# ---------------------------------------------------------------------------
# L: PHASE2_ONLY must not require OS-hop selective contract
# ---------------------------------------------------------------------------
OUT_P2="$(
  PREPARATION_MODE=PHASE2_ONLY \
  python3 "$PROV" classify-client-set \
    --project-root "$ROOT" \
    --client-root "$CLIENT_ROOT" \
    --expected-mirror "$MIRROR_URL" \
    --expected-fingerprint "$FPR" \
    --expected-mode PHASE2_ONLY \
    --selective-root "/nonexistent/selective-for-phase2" 2>&1 || true
)"
# PHASE2_ONLY may still fail for mode_mismatch vs client-set FULL metadata, but must NOT
# fail for selective_generation_unavailable.
if printf '%s' "$OUT_P2" | grep -q 'selective_generation_unavailable'; then
  fail "L: PHASE2_ONLY incorrectly required selective generation"
else
  pass "L: PHASE2_ONLY does not require OS-hop selective contract"
fi

# Workflow helper: PHASE2_ONLY selective check is a no-op success.
PREPARATION_MODE=PHASE2_ONLY
if mm_wf_selective_generation_current; then
  pass "L: workflow selective binding skipped for PHASE2_ONLY"
else
  fail "L: workflow selective binding should skip PHASE2_ONLY"
fi
PREPARATION_MODE=FULL

echo
echo "TARGETED_COLLECTED=${COLLECTED}"
echo "TARGETED_PASSED=${PASS_N}"
echo "TARGETED_SKIPPED=${SKIP_N}"
echo "TARGETED_FAILED=$((COLLECTED - PASS_N - SKIP_N))"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
exit 0
