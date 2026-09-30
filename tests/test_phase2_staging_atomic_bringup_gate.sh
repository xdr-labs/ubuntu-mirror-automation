#!/usr/bin/env bash
# Regression: Phase 2 must not leave a runnable bringup controller without an
# authoritative staging PASS + consumable prerequisite state contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="${ROOT}/client/stage-dp-phase2.sh"
WRAP="${ROOT}/client/bringup_py3_dp_lifecycle.sh"
CONTRACT="${ROOT}/client/lib/dp-phase2-staging-contract.sh"
PREREQ="${ROOT}/client/lib/dp-phase2-ubuntu-prerequisites.sh"

FAIL=0
PASS=0
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "======== test_phase2_staging_atomic_bringup_gate ========"

bash -n "$STAGE" && pass "bash -n stage" || fail "bash -n stage"
bash -n "$WRAP" && pass "bash -n lifecycle wrapper" || fail "bash -n lifecycle wrapper"
bash -n "$CONTRACT" && pass "bash -n staging contract" || fail "bash -n staging contract"

# Ordering: runnable controller publish must follow prerequisite staging.
# Use ROOT-absolute paths so this check works under tests/run_all.sh (cwd=tests/).
python3 - "$ROOT" <<'PY' && pass "publish ordering after prerequisites" || fail "publish ordering after prerequisites"
import sys
from pathlib import Path
root = Path(sys.argv[1])
text = (root / "client/stage-dp-phase2.sh").read_text()
# Restrict to stage_main body (after function definitions).
idx = text.rfind("stage_main() {")
body = text[idx:]
prereq = body.find("stage_phase2_ubuntu_prerequisites")
publish = body.find("install_bringup_lifecycle_wrapper")
assert prereq > 0 and publish > 0, (prereq, publish)
assert prereq < publish, "install_bringup_lifecycle_wrapper still precedes prereq staging"
# Historical failure class: publish must not sit before FINAL_VALIDATION in stage_main.
final = body.find('PHASE2_STAGE_PHASE="FINAL_VALIDATION"')
assert final > 0 and final < publish, "controller publish still before FINAL_VALIDATION"
# Mutation start must invalidate contract + retract live controller.
assert "dp_phase2_invalidate_staging_contract" in body
assert "retract_live_bringup_controller" in body
assert "dp_phase2_persist_staging_contract" in body
persist = body.rfind("dp_phase2_persist_staging_contract")
commit = body.rfind("commit_promoted_artifact_tree")
assert persist > 0 and commit > persist, "artifact commit must follow durable staging contract"
wrapper = (root / "client/bringup_py3_dp_lifecycle.sh").read_text()
assert "dp_phase2_bringup_staging_gate" in wrapper
# Prerequisite helpers must exist in the parent lifecycle shell before the
# staging gate runs. Sourcing only inside command substitution loses them.
prereq_source = wrapper.find('source "${LIB_DIR}/dp-phase2-ubuntu-prerequisites.sh"')
staging_source = wrapper.find('source "${LIB_DIR}/dp-phase2-staging-contract.sh"')
assert prereq_source > 0 and staging_source > prereq_source, (prereq_source, staging_source)
PY

grep -q 'dp_phase2_bringup_staging_gate' "$WRAP" \
  && pass "lifecycle invokes staging gate" \
  || fail "lifecycle missing staging gate"

export PHASE2_STAGING_CONTRACT_ENV="${WORKDIR}/staging-result.env"
export PHASE2_BRINGUP_DIR="${WORKDIR}/lifecycle"
export STAGING_DIR="${WORKDIR}/prereq-artifacts"
export PHASE2_STAGING_ARTIFACT_ROOT="${WORKDIR}/aelladeb_py3"
export PHASE2_STAGING_HELPER_MANIFEST="${PHASE2_BRINGUP_DIR}/phase2-helper-generation.manifest"
mkdir -p "$STAGING_DIR" "$PHASE2_STAGING_ARTIFACT_ROOT" "$PHASE2_BRINGUP_DIR" "${WORKDIR}/lib"
printf 'fixture-phase2-helper-generation\n' >"$PHASE2_STAGING_HELPER_MANIFEST"
B_SHA="$(printf 'fixture-bundle-6.6.0' | sha256sum | awk '{print $1}')"
H_SHA="$(sha256sum "$PHASE2_STAGING_HELPER_MANIFEST" | awk '{print $1}')"
P_SHA=""
A_SHA=""

# shellcheck source=/dev/null
source "$CONTRACT"
# shellcheck source=/dev/null
source "$PREREQ"

write_prereq_state() {
  local required="$1"
  local dest="${STAGING_DIR}/phase2-ubuntu-prerequisites.state"
  local identity="${STAGING_DIR}/phase2-ubuntu-prerequisites.identity"
  cat >"$identity" <<EOF
TARGET_DP_VERSION=6.6.0
PHASE2_PREREQ_REQUIRED=${required}
PHASE2_PREREQ_PUBLICATION=PASS
EOF
  P_SHA="$(sha256sum "$identity" | awk '{print $1}')"
  if [[ "$required" == "NO" ]]; then
    cat >"$dest" <<'EOF'
TARGET_DP_VERSION=6.6.0
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PACKAGE_COUNT=0
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=
EOF
  else
    local sha
    sha="$(printf '%064d' 7)"
    printf 'payload\n' >"${STAGING_DIR}/phase2-ubuntu-prerequisites.tar.gz"
    printf '%s  phase2-ubuntu-prerequisites.tar.gz\n' "$sha" \
      >"${STAGING_DIR}/phase2-ubuntu-prerequisites.tar.gz.sha256"
    # Recompute real sha for contract validity.
    sha="$(sha256sum "${STAGING_DIR}/phase2-ubuntu-prerequisites.tar.gz" | awk '{print $1}')"
    printf '%s  phase2-ubuntu-prerequisites.tar.gz\n' "$sha" \
      >"${STAGING_DIR}/phase2-ubuntu-prerequisites.tar.gz.sha256"
    cat >"$dest" <<EOF
TARGET_DP_VERSION=6.6.0
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=1
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=${sha}
EOF
    cat >"${STAGING_DIR}/phase2-ubuntu-prerequisites.manifest.json" <<EOF
{"package_count":1,"sha256":"${sha}"}
EOF
  fi
}

write_artifact_tree() {
  local f
  rm -rf "$PHASE2_STAGING_ARTIFACT_ROOT"
  mkdir -p "$PHASE2_STAGING_ARTIFACT_ROOT"
  for f in     aelladeb_py3_common.tar.gz     aelladeb_py3_common.tar.gz.sha1     aella-uvp-2404_6.6.0ubuntu1_amd64.deb     aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1     images-6.6.0.list     images-6.6.0.tar     images-6.6.0.tar.sha256
  do
    printf 'fixture-%s\n' "$f" >"${PHASE2_STAGING_ARTIFACT_ROOT}/$f"
  done
  A_SHA="$(dp_phase2_artifact_tree_hash 6.6.0)"
}

persist_contract() {
  [[ "$P_SHA" =~ ^[0-9a-f]{64}$ ]] || return 1
  A_SHA="$(dp_phase2_artifact_tree_hash 6.6.0)" || return 1
  [[ "$A_SHA" =~ ^[0-9a-f]{64}$ ]] || return 1
  dp_phase2_persist_staging_contract 6.6.0 "$B_SHA" "$P_SHA" "$H_SHA" "$A_SHA"
}

write_artifact_tree

# 1) Interrupted / incomplete staging: no contract => gate blocks worker start.
rm -f "$PHASE2_STAGING_CONTRACT_ENV"
rm -f "${STAGING_DIR}/phase2-ubuntu-prerequisites.state"
set +e
OUT="$(dp_phase2_bringup_staging_gate 6.6.0 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] \
  && echo "$OUT" | grep -q 'PHASE2_STAGING_GATE=FAIL reason=staging_contract_missing' \
  && echo "$OUT" | grep -q 'VENDOR_BRINGUP_EXECUTED=NO' \
  && echo "$OUT" | grep -q 'REMEDIATION=' \
  && pass "incomplete staging blocks bringup" \
  || fail "incomplete staging should block (rc=${RC})"

# Simulate historical failure: controller present, prereq state absent, no PASS contract.
printf '#!/bin/bash\necho fake\n' >"${WORKDIR}/bringup_py3_dp_after_os_upgrade.sh"
chmod +x "${WORKDIR}/bringup_py3_dp_after_os_upgrade.sh"
set +e
OUT="$(dp_phase2_bringup_staging_gate 6.6.0 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] \
  && echo "$OUT" | grep -q 'staging_contract_missing\|prereq_state_' \
  && pass "controller-without-contract still blocked" \
  || fail "controller-without-contract leaked"

# 2) Invalidate clears a prior PASS (restage / retry safety).
write_prereq_state NO
persist_contract >/dev/null
dp_phase2_bringup_staging_gate 6.6.0 >/dev/null \
  && pass "valid PASS+REQUIRED=NO proceeds" \
  || fail "valid PASS+REQUIRED=NO unexpectedly blocked"
dp_phase2_invalidate_staging_contract "simulated_restage" >/dev/null
set +e
OUT="$(dp_phase2_bringup_staging_gate 6.6.0 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] \
  && echo "$OUT" | grep -q 'staging_contract_missing' \
  && pass "invalidate blocks until staging completes again" \
  || fail "invalidate did not block"

# 3) Completed staging with REQUIRED=NO proceeds.
write_prereq_state NO
persist_contract >/dev/null
OUT="$(dp_phase2_bringup_staging_gate 6.6.0 2>&1)" \
  && echo "$OUT" | grep -q 'PHASE2_STAGING_GATE=PASS' \
  && echo "$OUT" | grep -q 'PHASE2_PREREQ_CONTRACT=not_required' \
  && pass "REQUIRED=NO contract accepted" \
  || fail "REQUIRED=NO contract rejected"

# Production lifecycle import order must leave prerequisite helpers in the
# parent shell. This is the exact failure class that previously sourced the
# helper only inside command substitution and then lost dp2_prereq_find_state.
set +e
PARENT_SCOPE_OUT="$(bash -c '
  set -euo pipefail
  LIB_DIR="$1"
  source "$LIB_DIR/dp-phase2-bringup-lifecycle.sh"
  source "$LIB_DIR/dp-phase2-time-readiness.sh"
  source "$LIB_DIR/dp-phase2-ubuntu-prerequisites.sh"
  source "$LIB_DIR/dp-phase2-staging-contract.sh"
  source "$LIB_DIR/dp-phase2-post-bringup-migration.sh"
  source "$LIB_DIR/dp-phase2-cluster-validation.sh"
  declare -F dp2_prereq_find_state >/dev/null
  dp_phase2_bringup_staging_gate 6.6.0
' _ "${ROOT}/client/lib" 2>&1)"
PARENT_SCOPE_RC=$?
set -e
[[ "$PARENT_SCOPE_RC" -eq 0 ]] \
  && echo "$PARENT_SCOPE_OUT" | grep -q 'PHASE2_STAGING_GATE=PASS' \
  && pass "actual lifecycle import set keeps prerequisite helper in parent scope" \
  || fail "actual lifecycle import set lost prerequisite helper (rc=${PARENT_SCOPE_RC} out=${PARENT_SCOPE_OUT})"

# 3A) B/P/H identity receipt is mandatory and live P/H drift fails closed.
printf 'tamper\n' >>"${STAGING_DIR}/phase2-ubuntu-prerequisites.identity"
set +e
OUT="$(dp_phase2_bringup_staging_gate 6.6.0 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] && echo "$OUT" | grep -q 'prereq_identity_mismatch' \
  && pass "prerequisite identity drift blocked" \
  || fail "prerequisite identity drift not blocked (rc=${RC} out=${OUT})"

write_prereq_state NO
persist_contract >/dev/null
printf 'tamper-helper\n' >>"$PHASE2_STAGING_HELPER_MANIFEST"
set +e
OUT="$(dp_phase2_bringup_staging_gate 6.6.0 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] && echo "$OUT" | grep -q 'helper_generation_identity_mismatch' \
  && pass "helper generation drift blocked" \
  || fail "helper generation drift not blocked (rc=${RC} out=${OUT})"
printf 'fixture-phase2-helper-generation\n' >"$PHASE2_STAGING_HELPER_MANIFEST"
H_SHA="$(sha256sum "$PHASE2_STAGING_HELPER_MANIFEST" | awk '{print $1}')"
write_prereq_state NO
persist_contract >/dev/null
printf 'tamper-artifact\n' >>"${PHASE2_STAGING_ARTIFACT_ROOT}/images-6.6.0.list"
set +e
OUT="$(dp_phase2_bringup_staging_gate 6.6.0 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] && echo "$OUT" | grep -q 'artifact_tree_identity_mismatch' \
  && pass "staged payload tree drift blocked" \
  || fail "staged payload tree drift not blocked (rc=${RC} out=${OUT})"
write_artifact_tree
write_prereq_state NO
persist_contract >/dev/null

cat >"$PHASE2_STAGING_CONTRACT_ENV" <<'EOF'
PHASE2_STAGE_RESULT=PASS
ARTIFACT_STAGING_RESULT=PASS
TARGET_DP_VERSION=6.6.0
EOF
set +e
OUT="$(dp_phase2_bringup_staging_gate 6.6.0 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] && echo "$OUT" | grep -q 'identity_receipt_incomplete' \
  && pass "legacy target-only staging receipt rejected" \
  || fail "legacy target-only receipt unexpectedly accepted (rc=${RC} out=${OUT})"
write_prereq_state NO
persist_contract >/dev/null

# 4) REQUIRED=YES with valid state proceeds; missing state after PASS contract fails.
write_prereq_state YES
persist_contract >/dev/null
OUT="$(dp_phase2_bringup_staging_gate 6.6.0 2>&1)" \
  && echo "$OUT" | grep -q 'PHASE2_STAGING_GATE=PASS' \
  && pass "REQUIRED=YES contract accepted" \
  || fail "REQUIRED=YES contract rejected"
rm -f "${STAGING_DIR}/phase2-ubuntu-prerequisites.state"
set +e
OUT="$(dp_phase2_bringup_staging_gate 6.6.0 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] \
  && echo "$OUT" | grep -q 'prereq_state_state_missing\|reason=prereq_state_state_missing' \
  && pass "PASS contract without prereq state blocked" \
  || fail "PASS without prereq state leaked (rc=${RC} out=${OUT})"

# 5) Target mismatch blocked.
write_prereq_state NO
persist_contract >/dev/null
set +e
OUT="$(dp_phase2_bringup_staging_gate 6.5.0 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] \
  && echo "$OUT" | grep -q 'target_mismatch' \
  && pass "target mismatch blocked" \
  || fail "target mismatch leaked"

# 6) Lifecycle wrapper refuses worker launch when staging gate fails (no setsid).
mkdir -p "${WORKDIR}/wrap-home/lib"
cp -a "${ROOT}/client/lib/dp-phase2-bringup-lifecycle.sh" "${WORKDIR}/wrap-home/lib/"
cp -a "$CONTRACT" "${WORKDIR}/wrap-home/lib/"
cp -a "$PREREQ" "${WORKDIR}/wrap-home/lib/"
cat >"${WORKDIR}/wrap-home/lib/dp-phase2-post-bringup-migration.sh" <<'EOF'
true
EOF
cat >"${WORKDIR}/wrap-home/lib/dp-phase2-cluster-validation.sh" <<'EOF'
true
EOF
# Force time gate pass; leave staging contract absent.
cat >"${WORKDIR}/wrap-home/lib/dp-phase2-time-readiness.sh" <<'EOF'
dp_phase2_load_time_ref_url() { return 0; }
dp_phase2_bringup_time_gate() {
  TIME_READINESS=PASS_SYNCED
  return 0
}
EOF
install -m 0755 "$WRAP" "${WORKDIR}/wrap-home/bringup_py3_dp_lifecycle.sh"
# Vendor sibling required before readiness gates.
printf '#!/bin/bash\necho vendor\n' \
  >"${WORKDIR}/wrap-home/bringup_py3_dp_after_os_upgrade.vendor.sh"
chmod +x "${WORKDIR}/wrap-home/bringup_py3_dp_after_os_upgrade.vendor.sh"
rm -f "$PHASE2_STAGING_CONTRACT_ENV"
export PHASE2_BRINGUP_DIR="${WORKDIR}/lifecycle2"
export PHASE2_BRINGUP_ALLOW_NONROOT=1
mkdir -p "$PHASE2_BRINGUP_DIR"
# Provide a non-empty password file so argv parsing does not fail early.
printf 'x\n' >"${WORKDIR}/worker.pw"
chmod 0600 "${WORKDIR}/worker.pw"
set +e
WRAP_OUT="$(
  bash "${WORKDIR}/wrap-home/bringup_py3_dp_lifecycle.sh" --version 6.6.0 --detach \
    --worker-ips 192.0.2.20 --worker-password-file "${WORKDIR}/worker.pw" 2>&1
)"
WRAP_RC=$?
set -e
# EXIT trap cleanup can mask non-zero status; assert gate failure + no handoff.
if echo "$WRAP_OUT" | grep -q 'PHASE2_STAGING_GATE=FAIL' \
  && echo "$WRAP_OUT" | grep -q 'VENDOR_BRINGUP_EXECUTED=NO\|bringup blocked' \
  && ! echo "$WRAP_OUT" | grep -q 'BRINGUP_HANDOFF=PASS' \
  && ! echo "$WRAP_OUT" | grep -q 'BRINGUP_STAGING_GATE=PASS'; then
  pass "wrapper refuses worker without staging PASS"
else
  fail "wrapper launched without staging PASS (rc=${WRAP_RC} out=${WRAP_OUT})"
fi

# 7) Retry path: after persist+prereq, gate passes (worker launch not required here).
write_prereq_state NO
persist_contract >/dev/null
OUT="$(dp_phase2_bringup_staging_gate 6.6.0 2>&1)" \
  && echo "$OUT" | grep -q 'PHASE2_STAGING_GATE=PASS' \
  && pass "retry after completed staging proceeds" \
  || fail "retry after completed staging blocked"

# 8) Artifact promotion is transactional across post-promotion failures.
export DP_PHASE2_STAGE_LIB_ONLY=1
# shellcheck source=/dev/null
source "$STAGE"
unset DP_PHASE2_STAGE_LIB_ONLY
TARGET_DP_VERSION=6.6.0
TXN="${WORKDIR}/artifact-transaction"
ARTIFACT_DIR="${TXN}/aelladeb_py3"
RUN_ID="txn-test"
mkdir -p "$ARTIFACT_DIR"
printf 'OLD\n' >"${ARTIFACT_DIR}/marker"
ARTIFACT_BACKUP="${ARTIFACT_DIR}.bak.${RUN_ID}"
mv -f "$ARTIFACT_DIR" "$ARTIFACT_BACKUP"
mkdir -p "$ARTIFACT_DIR"
printf 'NEW\n' >"${ARTIFACT_DIR}/marker"
ARTIFACT_PROMOTED=1
ARTIFACT_COMMITTED=0
if rollback_promoted_artifact_tree >"${TXN}.rollback.log" 2>&1 \
  && grep -qx 'OLD' "${ARTIFACT_DIR}/marker" \
  && [[ ! -e "${ARTIFACT_DIR}.bak.${RUN_ID}" ]] \
  && ! compgen -G "${ARTIFACT_DIR}.failed.*" >/dev/null; then
  pass "post-promotion failure restores previous artifact tree"
else
  fail "artifact rollback did not restore previous tree"
  cat "${TXN}.rollback.log" 2>/dev/null || true
fi

# First publication failure removes the uncommitted promoted tree.
rm -rf "$ARTIFACT_DIR" "${ARTIFACT_DIR}.bak."* "${ARTIFACT_DIR}.failed."* 2>/dev/null || true
mkdir -p "$ARTIFACT_DIR"
printf 'NEW-FIRST\n' >"${ARTIFACT_DIR}/marker"
ARTIFACT_BACKUP=""
ARTIFACT_PROMOTED=1
ARTIFACT_COMMITTED=0
if rollback_promoted_artifact_tree >"${TXN}.first.log" 2>&1 && [[ ! -e "$ARTIFACT_DIR" ]]; then
  pass "failed first publication removes uncommitted artifact tree"
else
  fail "failed first publication left consumable artifacts"
fi

# Successful contract commit retains new live tree and removes previous backup.
mkdir -p "$ARTIFACT_DIR" "${ARTIFACT_DIR}.bak.commit"
printf 'NEW-COMMITTED\n' >"${ARTIFACT_DIR}/marker"
printf 'OLD\n' >"${ARTIFACT_DIR}.bak.commit/marker"
ARTIFACT_BACKUP="${ARTIFACT_DIR}.bak.commit"
ARTIFACT_PROMOTED=1
ARTIFACT_COMMITTED=0
if commit_promoted_artifact_tree >"${TXN}.commit.log" 2>&1 \
  && grep -qx 'NEW-COMMITTED' "${ARTIFACT_DIR}/marker" \
  && [[ ! -e "${ARTIFACT_DIR}.bak.commit" ]]; then
  pass "artifact commit retains new tree and removes previous backup"
else
  fail "artifact commit cleanup incorrect"
fi

# Crash recovery: missing PASS contract restores the one retained previous tree.
rm -f "$PHASE2_STAGING_CONTRACT_ENV"
rm -rf "$ARTIFACT_DIR" "${ARTIFACT_DIR}.bak.crash"
mkdir -p "$ARTIFACT_DIR" "${ARTIFACT_DIR}.bak.crash"
printf 'UNCOMMITTED\n' >"${ARTIFACT_DIR}/marker"
printf 'KNOWN-GOOD\n' >"${ARTIFACT_DIR}.bak.crash/marker"
if recover_interrupted_artifact_transaction >"${TXN}.crash.log" 2>&1 \
  && grep -qx 'KNOWN-GOOD' "${ARTIFACT_DIR}/marker" \
  && [[ ! -e "${ARTIFACT_DIR}.bak.crash" ]]; then
  pass "crash recovery restores previous tree when staging contract is absent"
else
  fail "crash recovery failed to restore previous tree"
fi

# Crash recovery after durable PASS treats the retained backup as stale cleanup.
write_prereq_state NO
persist_contract >/dev/null
rm -rf "$ARTIFACT_DIR" "${ARTIFACT_DIR}.bak.committed"
mkdir -p "$ARTIFACT_DIR" "${ARTIFACT_DIR}.bak.committed"
printf 'COMMITTED\n' >"${ARTIFACT_DIR}/marker"
printf 'OLD\n' >"${ARTIFACT_DIR}.bak.committed/marker"
if recover_interrupted_artifact_transaction >"${TXN}.committed.log" 2>&1 \
  && grep -qx 'COMMITTED' "${ARTIFACT_DIR}/marker" \
  && [[ ! -e "${ARTIFACT_DIR}.bak.committed" ]]; then
  pass "crash recovery removes stale backup after durable PASS"
else
  fail "committed crash recovery changed live tree or retained stale backup"
fi

echo "======== summary PASS=${PASS} FAIL=${FAIL} ========"
[[ "$FAIL" -eq 0 ]]
