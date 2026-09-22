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
python3 - <<'PY' && pass "publish ordering after prerequisites" || fail "publish ordering after prerequisites"
from pathlib import Path
text = Path("client/stage-dp-phase2.sh").read_text()
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
assert "dp_phase2_bringup_staging_gate" in Path("client/bringup_py3_dp_lifecycle.sh").read_text()
PY

grep -q 'dp_phase2_bringup_staging_gate' "$WRAP" \
  && pass "lifecycle invokes staging gate" \
  || fail "lifecycle missing staging gate"

export PHASE2_STAGING_CONTRACT_ENV="${WORKDIR}/staging-result.env"
export PHASE2_BRINGUP_DIR="${WORKDIR}/lifecycle"
export STAGING_DIR="${WORKDIR}/artifacts"
mkdir -p "$STAGING_DIR" "$PHASE2_BRINGUP_DIR" "${WORKDIR}/lib"

# shellcheck source=/dev/null
source "$CONTRACT"
# shellcheck source=/dev/null
source "$PREREQ"

write_prereq_state() {
  local required="$1"
  local dest="${STAGING_DIR}/phase2-ubuntu-prerequisites.state"
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
dp_phase2_persist_staging_contract 6.6.0 >/dev/null
write_prereq_state NO
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
dp_phase2_persist_staging_contract 6.6.0 >/dev/null
write_prereq_state NO
OUT="$(dp_phase2_bringup_staging_gate 6.6.0 2>&1)" \
  && echo "$OUT" | grep -q 'PHASE2_STAGING_GATE=PASS' \
  && echo "$OUT" | grep -q 'PHASE2_PREREQ_CONTRACT=not_required' \
  && pass "REQUIRED=NO contract accepted" \
  || fail "REQUIRED=NO contract rejected"

# 4) REQUIRED=YES with valid state proceeds; missing state after PASS contract fails.
write_prereq_state YES
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
dp_phase2_persist_staging_contract 6.6.0 >/dev/null
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
dp_phase2_persist_staging_contract 6.6.0 >/dev/null
OUT="$(dp_phase2_bringup_staging_gate 6.6.0 2>&1)" \
  && echo "$OUT" | grep -q 'PHASE2_STAGING_GATE=PASS' \
  && pass "retry after completed staging proceeds" \
  || fail "retry after completed staging blocked"

echo "======== summary PASS=${PASS} FAIL=${FAIL} ========"
[[ "$FAIL" -eq 0 ]]
