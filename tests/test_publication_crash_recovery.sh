#!/usr/bin/env bash
# Crash/recovery contract for Phase 2 and selective publication transactions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
DP2="${ROOT}/scripts/lib/dp-phase2-common.sh"
ACPS="${ROOT}/scripts/lib/acps_acquire.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_PROJECT_ROOT="$ROOT"
export MM_MIRROR_ROOT="${TMP}/mirror"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_SELECTIVE_ROOT="${MM_MIRROR_ROOT}/selective"
export MM_STATE_DIR="${TMP}/state"
export MM_LOG_DIR="${TMP}/logs"
export MM_CONFIG_DIR="${TMP}/config"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_SKIP_ROOT_CHECK=1
mkdir -p "$MM_CACHE_ROOT" "$MM_STATE_DIR" "$MM_CONFIG_DIR" "$MM_LOG_DIR" \
  "$MM_DP_PHASE2_ROOT"

# shellcheck source=/dev/null
source "$COMMON"
# shellcheck source=/dev/null
source "$DP2"
# shellcheck source=/dev/null
source "$ACPS"
# shellcheck source=/dev/null
source "$ENGINE"

dp2_set_version 6.6.0
VER=6.6.0
STABLE="$(dp2_stable_bundle_name)"

seed_complete_candidate() {
  local cand="$1"
  mkdir -p "$cand"
  # Minimal 9-entry tar matching DP_PHASE2_REQUIRED_FILES names.
  local work="${TMP}/seed-work"
  rm -rf "$work"
  mkdir -p "$work"
  local f
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    printf 'payload-%s\n' "$f" >"${work}/${f}"
  done
  # Real checksums for sidecars that are themselves required members.
  sha1sum "${work}/aelladeb_py3_common.tar.gz" | awk '{print $1}' \
    >"${work}/aelladeb_py3_common.tar.gz.sha1"
  sha1sum "${work}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}' \
    >"${work}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
  sha1sum "${work}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
    >"${work}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  sha256sum "${work}/images-6.6.0.tar" | awk '{print $1 "  images-6.6.0.tar"}' \
    >"${work}/images-6.6.0.tar.sha256"
  seq 1 2 >"${work}/images-6.6.0.list"
  (
    cd "$work"
    tar -cf "${cand}/${STABLE}" "${DP_PHASE2_REQUIRED_FILES[@]}"
  )
  sha256sum "${cand}/${STABLE}" | awk '{print $1 "  '"${STABLE}"'"}' \
    >"${cand}/${STABLE}.sha256"
  cat >"${cand}/release.env" <<EOF
TARGET_DP_VERSION=${VER}
PHASE2_ARTIFACT_VERSION=${VER}
DP_PHASE2_VERSION=${VER}
STABLE_BUNDLE_NAME=${STABLE}
FILE_COUNT=9
VERIFICATION_RESULT=PASS
EOF
}

# 1) Incomplete .new from dead PID → deleted
INCOMPLETE="${MM_DP_PHASE2_ROOT}/${VER}.new.999001"
mkdir -p "$INCOMPLETE"
printf 'partial\n' >"${INCOMPLETE}/not-a-bundle"
engine_recover_phase2_publication_transactions "$VER" >"${TMP}/rec1.log" 2>&1
[[ ! -e "$INCOMPLETE" ]] || fail "incomplete .new was not deleted"
grep -q 'PHASE2_STALE_TRANSACTION_ACTION=DELETE' "${TMP}/rec1.log" \
  || fail "missing DELETE action for incomplete"
grep -q 'PHASE2_RECOVERY_SCAN=PASS' "${TMP}/rec1.log" || fail "scan marker missing"
pass "Phase2 incomplete .new deleted before disk preflight"

# 2) Complete valid .new from dead PID → recovered/promoted
COMPLETE="${MM_DP_PHASE2_ROOT}/${VER}.new.999002"
seed_complete_candidate "$COMPLETE"
engine_recover_phase2_publication_transactions "$VER" >"${TMP}/rec2.log" 2>&1
[[ -d "${MM_DP_PHASE2_ROOT}/${VER}" ]] || fail "complete .new was not promoted"
[[ ! -e "$COMPLETE" ]] || fail "promoted candidate still present as .new"
grep -q 'PHASE2_STALE_TRANSACTION_CLASS=COMPLETE_RECOVERABLE' "${TMP}/rec2.log" \
  || fail "missing COMPLETE_RECOVERABLE class"
grep -q 'PHASE2_STALE_TRANSACTION_ACTION=RECOVER' "${TMP}/rec2.log" \
  || fail "missing RECOVER action"
grep -q 'PHASE2_TRANSACTION_RECOVERY=PASS' "${TMP}/rec2.log" || fail "recovery pass missing"
pass "Phase2 complete .new recovered/promoted"

# 14) Idempotent second recovery
engine_recover_phase2_publication_transactions "$VER" >"${TMP}/rec2b.log" 2>&1
[[ -d "${MM_DP_PHASE2_ROOT}/${VER}" ]] || fail "final disappeared on second recovery"
grep -q 'PHASE2_STALE_TRANSACTION_FOUND=NO' "${TMP}/rec2b.log" \
  || fail "second recovery should find no stale txn"
pass "recovery idempotent"

# 3) Invalid .new never promoted
rm -rf "${MM_DP_PHASE2_ROOT}/${VER}"
INVALID="${MM_DP_PHASE2_ROOT}/${VER}.new.999003"
seed_complete_candidate "$INVALID"
echo 'CORRUPT' >>"${INVALID}/${STABLE}"
engine_recover_phase2_publication_transactions "$VER" >"${TMP}/rec3.log" 2>&1
[[ ! -e "$INVALID" ]] || fail "invalid .new not deleted"
[[ ! -e "${MM_DP_PHASE2_ROOT}/${VER}" ]] || fail "invalid .new was promoted"
grep -q 'PHASE2_STALE_TRANSACTION_ACTION=DELETE' "${TMP}/rec3.log" \
  || fail "invalid should DELETE"
pass "Phase2 invalid .new never promoted"

# 4) Active current .new preserved
ACTIVE="${MM_DP_PHASE2_ROOT}/${VER}.new.$$"
mkdir -p "$ACTIVE"
printf 'active-work\n' >"${ACTIVE}/partial"
engine_recover_phase2_publication_transactions "$VER" >"${TMP}/rec4.log" 2>&1
[[ -d "$ACTIVE" ]] || fail "active .new was removed"
grep -q 'PHASE2_STALE_TRANSACTION_ACTION=IGNORE_ACTIVE' "${TMP}/rec4.log" \
  || fail "active txn should IGNORE_ACTIVE"
rm -rf "$ACTIVE"
pass "active current .new preserved"

# 5) Crash after source cleanup before final rename → complete .new recoverable
CRASH="${MM_DP_PHASE2_ROOT}/${VER}.new.999005"
seed_complete_candidate "$CRASH"
# Simulate gone ACPS cache (cleanup already ran).
rm -rf "$(acps_cache_dir "$VER")"
engine_recover_phase2_publication_transactions "$VER" >"${TMP}/rec5.log" 2>&1
[[ -d "${MM_DP_PHASE2_ROOT}/${VER}" ]] || fail "post-cleanup complete .new not recovered"
grep -q 'PHASE2_STALE_TRANSACTION_ACTION=RECOVER' "${TMP}/rec5.log" \
  || fail "post-cleanup recover missing"
pass "crash after source cleanup before rename recovers complete .new"

# 6) Selective interrupted transaction recovery
rm -rf "${MM_SELECTIVE_ROOT}" "${MM_SELECTIVE_ROOT}".new.* "${MM_SELECTIVE_ROOT}".old.* 2>/dev/null || true
SEL_NEW="${MM_SELECTIVE_ROOT}.new.999006"
SEL_OLD="${MM_SELECTIVE_ROOT}.old.999006"
mkdir -p "${SEL_OLD}/hops" "${SEL_NEW}/hops"
printf 'old-ready\n' >"${SEL_OLD}/marker"
# Incomplete new (no READY) with live missing → restore old
engine_recover_selective_publication_transactions >"${TMP}/sel1.log" 2>&1
[[ -d "${MM_SELECTIVE_ROOT}" ]] || fail "selective old not restored"
[[ -f "${MM_SELECTIVE_ROOT}/marker" ]] || fail "restored selective content missing"
grep -q 'SELECTIVE_STALE_TRANSACTION_ACTION=RESTORE_OLD' "${TMP}/sel1.log" \
  || fail "missing RESTORE_OLD"
grep -q 'OS_CORE_TRANSACTION_RECOVERY=PASS' "${TMP}/sel1.log" || fail "os recovery pass"
pass "selective incomplete new + old restored"

# Complete new with READY when live missing → recover new
rm -rf "${MM_SELECTIVE_ROOT}"
SEL_NEW="${MM_SELECTIVE_ROOT}.new.999007"
mkdir -p "${SEL_NEW}/state" "${SEL_NEW}/hops"
printf 'ready\n' >"${SEL_NEW}/state/READY"
engine_recover_selective_publication_transactions >"${TMP}/sel2.log" 2>&1
[[ -f "${MM_SELECTIVE_ROOT}/state/READY" ]] || fail "selective new not recovered"
grep -q 'SELECTIVE_STALE_TRANSACTION_ACTION=RECOVER' "${TMP}/sel2.log" \
  || fail "missing selective RECOVER"
pass "selective complete new recovered"

# Stale old with live present → delete old
SEL_OLD="${MM_SELECTIVE_ROOT}.old.999008"
mkdir -p "$SEL_OLD"
engine_recover_selective_publication_transactions >"${TMP}/sel3.log" 2>&1
[[ ! -e "$SEL_OLD" ]] || fail "stale selective.old not deleted"
pass "selective stale old deleted when live present"

echo "ALL PUBLICATION CRASH RECOVERY TESTS PASSED"
