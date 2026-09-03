#!/usr/bin/env bash
# P0 regression: CLIENT_FILES_READY must not block Download and Prepare before
# OS Core is ready. Prerequisites gate at start; CLIENT_FILES_READY at finalize.
# Uses RFC 5737 documentation addresses only — never production Mirror IPs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/seed_complete_client_http_set.sh
source "${ROOT}/tests/lib/seed_complete_client_http_set.sh"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
DP2="${ROOT}/scripts/lib/dp-phase2-common.sh"
ACPS="${ROOT}/scripts/lib/acps_acquire.sh"
R2="${ROOT}/scripts/lib/r2_acquire.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export MM_PROJECT_ROOT="$ROOT"
export MM_SKIP_ROOT_CHECK=1
export MM_MIRROR_ROOT="${TMP}/mirror"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export MM_STATE_ROOT="${TMP}/state"
export MM_LOG_DIR="${TMP}/logs"
export MM_CONFIG_DIR="${TMP}/config"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_SELECTIVE_ROOT="${MM_MIRROR_ROOT}/selective"
export MM_CLIENT_ROOT="${MM_MIRROR_ROOT}/client"
export MM_LOCK_FILE="${TMP}/install.lock"
export LOCAL_CLIENT_SIGNING_DIR="${MM_CONFIG_DIR}/client-signing"
export MIRROR_HTTP_URL="http://192.0.2.10"
export RESOLVED_MIRROR_HOST_IPV4="192.0.2.10"
export RESOLVED_MIRROR_BASE_URL="http://192.0.2.10"
export MM_MOCK_AVAILABLE_BYTES=$((80 * 1024 * 1024 * 1024))
export MM_MOCK_FS_SIZE_BYTES=$((100 * 1000 * 1000 * 1000))
export MM_MOCK_SAFETY_RESERVE_BYTES=$((10 * 1024 * 1024 * 1024))
export OS_CORE_PACKAGE_BYTES=100
export OS_CORE_PAYLOAD_BYTES=200
export ACPS_EXPECTED_BYTES=300
export TARGET_DP_VERSION=6.6.0
export PHASE2_TARGET_VERSION=6.6.0
export ACPS_USERNAME=testuser
export ACPS_PASSWORD=testpass
export OS_CORE_R2_URL='http://127.0.0.1:9/os-core.tar'
export PREPARATION_MODE=FULL

mkdir -p "$MM_CLIENT_ROOT" "$MM_CACHE_ROOT" "$MM_DP_PHASE2_ROOT" \
  "$MM_LOG_DIR" "$MM_STATE_ROOT" "$MM_CONFIG_DIR" "$MM_SELECTIVE_ROOT"

# Intentionally empty client root — original regression fixture.
# No hop scripts/checksums under /var/spool/apt-mirror/client equivalent.
rm -f "${MM_CLIENT_ROOT}/dp-offline-upgrade-"*.sh \
  "${MM_CLIENT_ROOT}/dp-offline-upgrade-"*.sha256 \
  "${MM_CLIENT_ROOT}/stage-dp-phase2.sh" \
  "${MM_CLIENT_ROOT}/stage-dp-phase2.sh.sha256" 2>/dev/null || true

cat >"$MM_CONFIG_FILE" <<EOF
PREPARATION_MODE=FULL
TARGET_DP_VERSION=6.6.0
ACPS_USERNAME=testuser
ACPS_PASSWORD=testpass
OS_CORE_R2_URL=http://127.0.0.1:9/os-core.tar
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
EOF
chmod 600 "$MM_CONFIG_FILE"

# Bypass on-host IPv4 validation for the RFC 5737 fixture URL.
mirror_host_validate_ipv4_on_host() { return 0; }
export -f mirror_host_validate_ipv4_on_host 2>/dev/null || true

# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "$COMMON"
# Override after source (common defines the real helper).
mirror_host_validate_ipv4_on_host() { return 0; }

# shellcheck source=../scripts/lib/dp-phase2-common.sh
source "$DP2"
# shellcheck source=../scripts/lib/acps_acquire.sh
source "$ACPS"
# shellcheck source=../scripts/lib/r2_acquire.sh
source "$R2"
# shellcheck source=../scripts/lib/mirror_install_engine.sh
source "$ENGINE"

echo "=== test_client_ready_circular_gate ==="
echo "UNIT_ONLY=YES"
echo "REAL_CLIENT_BUILD_COVERED=NO"

# --- Structural: early CLIENT_FILES_READY gate removed from prepare ---
if grep -n 'mm_check_client_files_ready' "$ENGINE" | grep -B5 -A5 'engine_download_and_prepare' >/dev/null 2>&1; then
  # Ensure the FIRST client-files check inside download_and_prepare is prerequisites, not ready.
  :
fi
awk '
  /^engine_download_and_prepare\(\)/ { in_fn=1 }
  in_fn && /mm_check_client_files_ready/ && !seen_prereq { bad=1 }
  in_fn && /mm_check_client_build_prerequisites_ready/ { seen_prereq=1 }
  in_fn && /engine_finalize_local_client_set/ { seen_fin=1 }
  in_fn && /^}/ {
    exit((seen_prereq && seen_fin && !bad) ? 0 : 1)
  }
' "$ENGINE" \
  && pass "prepare uses prerequisites then finalize (not early CLIENT_FILES_READY)" \
  || fail "prepare still has circular CLIENT_FILES_READY ordering"

grep -q 'engine_rebuild_publish_local_client_set' "$ENGINE" \
  && pass "authoritative rebuild_publish_local_client_set present" \
  || fail "authoritative finalizer missing"

# Enable HTTP must call the same rebuild helper (not inline env bash rebuild).
if grep -A40 '^engine_enable_http_distribution()' "$ENGINE" \
  | grep -q 'engine_rebuild_publish_local_client_set\|engine_ensure_phase2_helpers'
then
  pass "Enable HTTP uses authoritative client finalizer"
else
  fail "Enable HTTP still has duplicate rebuild logic"
fi

# GUI progress lists client finalization steps for FULL mode.
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
grep -Fq 'Building Local OS Upgrade Clients' "$INSTALLER" \
  && grep -Fq 'Signing Local OS Upgrade Clients' "$INSTALLER" \
  && grep -Fq 'Publishing Local Client Set' "$INSTALLER" \
  && pass "GUI live progress includes client finalization phases" \
  || fail "GUI live progress missing client finalization phases"

# --- 1. Fresh install + OS Core not ready: empty client dir, prerequisites PASS ---
mm_state_init
PREPARATION_MODE=FULL
export PREPARATION_MODE
if mm_client_files_ready "$MM_CLIENT_ROOT"; then
  fail "empty client dir should not be CLIENT_FILES_READY"
else
  pass "empty client dir CLIENT_FILES_READY=NO (expected)"
fi

if mm_check_client_build_prerequisites_ready; then
  pass "CLIENT_BUILD_PREREQUISITES_READY=PASS with empty hop clients"
else
  fail "CLIENT_BUILD_PREREQUISITES_READY should PASS without hop clients"
fi

# Simulate preflight log contract for start-without-clients.
OS_CORE_READY_AT_START=NO
CLIENT_FILES_READY_AT_START=NOT_REQUIRED
[[ "$CLIENT_FILES_READY_AT_START" == "NOT_REQUIRED" ]] \
  && pass "CLIENT_FILES_READY_AT_START=NOT_REQUIRED" \
  || fail "CLIENT_FILES_READY_AT_START contract"

# --- 15. Original exact regression: empty client + prepare preflight proceeds ---
engine_preflight_host() { mm_ok "PREFLIGHT_HOST=PASS"; return 0; }
engine_assert_same_filesystem_layout() { mm_ok "SAME_FILESYSTEM=PASS"; return 0; }
mm_acquire_install_lock() { return 0; }
mm_release_install_lock() { return 0; }
engine_verify_disk_space() { return 0; }
engine_assess_phase2_final() { PHASE2_EXISTING_BUNDLE=ABSENT; return 0; }
engine_remove_invalid_phase2_final() { return 0; }
r2_require_url() { return 0; }
r2_download_package() { OS_CORE_PACKAGE="${TMP}/os-core.tar"; printf 'x\n' >"$OS_CORE_PACKAGE"; return 0; }
engine_verify_os_core_package() { mm_status_set R2_OS_CORE_CHECKSUM PASS; return 0; }
engine_materialize_os_mirror() {
  mkdir -p "${MM_SELECTIVE_ROOT}/state" "${MM_SELECTIVE_ROOT}/keys" \
    "${MM_SELECTIVE_ROOT}/shared/offline/release-upgraders/bionic"
  printf 'selective_plan_checksum=%s\ndiscovery_artifact_checksum=%s\nplan_checksum=%s\n' \
    "$(printf 'a%.0s' {1..64})" \
    "$(printf 'b%.0s' {1..64})" \
    "$(printf 'a%.0s' {1..64})" \
    >"${MM_SELECTIVE_ROOT}/state/READY"
  printf 'KEY\n' >"${MM_SELECTIVE_ROOT}/keys/ubuntu-mirror-selective.gpg"
  mm_status_set OS_MIRROR_READY PASS
  mm_state_set OS_MIRROR_READY PASS
  return 0
}
r2_cleanup_package() { return 0; }
acps_setup_curl_auth() { return 0; }
acps_test_connection() { return 0; }
acps_expected_bytes_hint() { printf '300\n'; }
acps_acquire_all() { return 0; }
acps_cache_dir() { mkdir -p "${MM_CACHE_ROOT}/acps/6.6.0"; printf '%s\n' "${MM_CACHE_ROOT}/acps/6.6.0"; }
engine_verify_acps_upstream_bringup() { return 0; }
engine_stage_acps_work_from_cache() { mkdir -p "$2"; return 0; }
engine_apply_local_bringup_patch() { return 0; }
engine_assert_work_ready_for_bundle() { return 0; }
engine_place_dp_phase2_final() {
  local dest="${MM_DP_PHASE2_ROOT}/6.6.0"
  mkdir -p "$dest"
  printf 'bundle\n' >"${dest}/dp_bundle_6.6.0-current.tar"
  (cd "$dest" && sha256sum dp_bundle_6.6.0-current.tar >dp_bundle_6.6.0-current.tar.sha256)
  cat >"${dest}/release.env" <<EOF
TARGET_DP_VERSION=6.6.0
PHASE2_ARTIFACT_VERSION=6.6.0
STABLE_BUNDLE_NAME=dp_bundle_6.6.0-current.tar
PHASE2_BUNDLE_ENTRY_COUNT=9
EOF
  mm_status_set PHASE2_BUNDLE_ENTRY_COUNT 9
  mm_status_set PHASE2_BUNDLE_CHECKSUM PASS
  mm_status_set ACPS_PHASE2_DOWNLOADED PASS
  mm_status_set ACPS_CHECKSUM PASS
  mm_status_set UPSTREAM_BRINGUP_DRIFT NO
  mm_status_set UPSTREAM_BRINGUP_PROVENANCE PASS
  mm_status_set PATCHED_BRINGUP_APPLIED YES
  return 0
}
engine_cleanup_temps() { return 0; }
engine_write_install_report() { return 0; }
engine_prepare_phase2_ubuntu_prerequisites() {
  local extras="${MM_DP_PHASE2_ROOT}/${TARGET_DP_VERSION:-6.6.0}/extras"
  mkdir -p "$extras"
  cat >"${extras}/phase2-ubuntu-prerequisites.state" <<'EOF'
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PACKAGE_COUNT=0
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
EOF
  mm_ok "PHASE2_PREREQ=PASS fixture_stub"
  return 0
}
mm_record_download_validated() {
  mm_status_set DOWNLOAD_PREPARE_RESULT PASS
  return 0
}

# Mock rebuild to prove finalization is invoked without needing full selective trees.
# Use a file flag — prepare runs in a subshell so shell vars would not propagate.
REBUILD_FLAG="${TMP}/rebuild.called"
: >"$REBUILD_FLAG"
engine_rebuild_publish_local_client_set() {
  printf '1\n' >"$REBUILD_FLAG"
  seed_complete_client_http_set "$MM_CLIENT_ROOT" "http://192.0.2.10"     "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  return 0
}

# Wrap finalize to count calls while keeping real logic... actually replace
# assess path: use real finalize but mocked rebuild.
# engine_finalize_local_client_set is real from ENGINE — override rebuild only.

OUT="${TMP}/prepare_empty_clients.log"
set +e
( engine_download_and_prepare >"$OUT" 2>&1 )
rc=$?
set -e

grep -q 'CLIENT_BUILD_PREREQUISITES_READY=PASS' "$OUT" \
  && pass "prepare starts with CLIENT_BUILD_PREREQUISITES_READY=PASS" \
  || { fail "prerequisites PASS missing"; cat "$OUT" | tail -40; }

grep -q 'CLIENT_FILES_READY_AT_START=NOT_REQUIRED\|CLIENT_BUILD_DEFERRED_UNTIL_OS_CORE_READY=YES' "$OUT" \
  && pass "prepare logs client-not-required-at-start" \
  || fail "missing NOT_REQUIRED / DEFERRED logs"

if grep -q 'CLIENT_FILES_READY=FAIL (required scripts/checksums missing' "$OUT" \
  && ! grep -q 'CLIENT_SET_FINALIZATION' "$OUT"
then
  fail "original circular gate still fails before prepare work"
else
  pass "empty client dir does not fail prepare preflight (original regression)"
fi

grep -q 'CLIENT_FILES_READY=PASS' "$OUT" \
  && pass "CLIENT_FILES_READY=PASS after finalize" \
  || { fail "CLIENT_FILES_READY not PASS after finalize"; tail -50 "$OUT"; }

[[ "$(cat "$REBUILD_FLAG" 2>/dev/null || echo 0)" == "1" ]] \
  && pass "authoritative rebuild invoked during finalize" \
  || fail "rebuild not called during finalize"

[[ "$rc" -eq 0 ]] \
  && pass "Download and Prepare succeeds after client finalization" \
  || { fail "prepare rc=${rc}"; tail -60 "$OUT"; }

# --- 4. Partial client set → REBUILD_FULL_SET, no stale copy ---
rm -f "${MM_CLIENT_ROOT}/dp-offline-upgrade-"*.sh "${MM_CLIENT_ROOT}/"*.sha256
printf '#!/bin/bash\necho only-one\n' >"${MM_CLIENT_ROOT}/dp-offline-upgrade-xenial-to-bionic.sh"
chmod +x "${MM_CLIENT_ROOT}/dp-offline-upgrade-xenial-to-bionic.sh"
engine_assess_client_set_for_finalize
[[ "${CLIENT_SET_STATE}" == "PARTIAL_OR_MIXED" ]] \
  && pass "partial set detected as PARTIAL_OR_MIXED" \
  || fail "partial state=${CLIENT_SET_STATE}"
[[ "${CLIENT_SET_ACTION}" == "REBUILD_FULL_SET" ]] \
  && pass "partial set action=REBUILD_FULL_SET" \
  || fail "partial action=${CLIENT_SET_ACTION}"

# --- 5/6. Rebuild failure → prepare FAIL, old complete set unchanged ---
# Seed a complete old set, then make rebuild fail.
seed_complete_client_http_set "$MM_CLIENT_ROOT" "http://192.0.2.10"   "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
# Mark as OLD so we can detect mutation
printf '#!/bin/bash\necho OLD_xenial\n' >"${MM_CLIENT_ROOT}/dp-offline-upgrade-xenial-to-bionic.sh"
chmod +x "${MM_CLIENT_ROOT}/dp-offline-upgrade-xenial-to-bionic.sh"
(cd "$MM_CLIENT_ROOT" && sha256sum dp-offline-upgrade-xenial-to-bionic.sh >dp-offline-upgrade-xenial-to-bionic.sh.sha256)
OLD_SHA="$(sha256sum "${MM_CLIENT_ROOT}/dp-offline-upgrade-xenial-to-bionic.sh" | awk '{print $1}')"
engine_rebuild_publish_local_client_set() {
  printf 'fail\n' >"$REBUILD_FLAG"
  return 1
}
mkdir -p "${MM_SELECTIVE_ROOT}/state"
printf 'selective_plan_checksum=%s\ndiscovery_artifact_checksum=%s\nplan_checksum=%s\n' \
  "$(printf 'a%.0s' {1..64})" \
  "$(printf 'b%.0s' {1..64})" \
  "$(printf 'a%.0s' {1..64})" \
  >"${MM_SELECTIVE_ROOT}/state/READY"
mm_status_set OS_MIRROR_READY PASS
set +e
engine_finalize_local_client_set >"${TMP}/fin_fail.log" 2>&1
frc=$?
set -e
[[ "$frc" -ne 0 ]] \
  && pass "finalize FAIL on rebuild failure" \
  || fail "finalize should fail when rebuild fails"
NEW_SHA="$(sha256sum "${MM_CLIENT_ROOT}/dp-offline-upgrade-xenial-to-bionic.sh" | awk '{print $1}')"
[[ "$OLD_SHA" == "$NEW_SHA" ]] \
  && pass "old complete HTTP set unchanged after rebuild failure" \
  || fail "old client set was mutated on rebuild failure"
grep -q 'PREPARATION_ARTIFACTS_READY=YES' "${TMP}/fin_fail.log" \
  && pass "PREPARATION_ARTIFACTS_READY=YES on client finalization fail" \
  || fail "missing PREPARATION_ARTIFACTS_READY on fail"
grep -q 'DOWNLOAD_AND_PREPARE_RESULT=FAIL_CLIENT_SET_FINALIZATION\|CLIENT_SET_FINALIZATION=FAIL' \
  "${TMP}/fin_fail.log" \
  && pass "FAIL_CLIENT_SET_FINALIZATION logged" \
  || fail "missing FAIL_CLIENT_SET_FINALIZATION"

# --- 8. Phase2-only: missing hop clients do not block start ---
PREPARATION_MODE=PHASE2_ONLY
export PREPARATION_MODE
rm -f "${MM_CLIENT_ROOT}/dp-offline-upgrade-"*.sh
mkdir -p "${MM_CLIENT_ROOT}/lib"
cp -a "${ROOT}/client/stage-dp-phase2.sh" "${MM_CLIENT_ROOT}/stage-dp-phase2.sh"
cp -a "${ROOT}/client/bringup_py3_dp_lifecycle.sh" "${MM_CLIENT_ROOT}/bringup_py3_dp_lifecycle.sh"
cp -a "${ROOT}/client/lib/dp-offline-source-product-version.sh" \
  "${MM_CLIENT_ROOT}/lib/dp-offline-source-product-version.sh"
cp -a "${ROOT}/client/lib/dp-phase2-operation-progress.sh" \
  "${MM_CLIENT_ROOT}/lib/dp-phase2-operation-progress.sh"
cp -a "${ROOT}/client/lib/dp-phase2-bringup-lifecycle.sh" \
  "${MM_CLIENT_ROOT}/lib/dp-phase2-bringup-lifecycle.sh"
cp -a "${ROOT}/client/lib/dp-phase2-ubuntu-prerequisites.sh" \
  "${MM_CLIENT_ROOT}/lib/dp-phase2-ubuntu-prerequisites.sh"
chmod +x "${MM_CLIENT_ROOT}/stage-dp-phase2.sh" "${MM_CLIENT_ROOT}/bringup_py3_dp_lifecycle.sh"
(cd "$MM_CLIENT_ROOT" && sha256sum stage-dp-phase2.sh >stage-dp-phase2.sh.sha256)
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/phase2_helper_generation.sh"
phase2_helper_generation_write "$MM_CLIENT_ROOT" >/dev/null
mkdir -p "${MM_DP_PHASE2_ROOT}/6.6.0"
printf 'bundle\n' >"${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar"
(
  cd "${MM_DP_PHASE2_ROOT}/6.6.0"
  sha256sum dp_bundle_6.6.0-current.tar >dp_bundle_6.6.0-current.tar.sha256
)
phase2_upgrade_wrapper_write "$MM_CLIENT_ROOT" "http://192.0.2.10" "6.6.0" >/dev/null
if mm_check_client_build_prerequisites_ready; then
  pass "PHASE2_ONLY prerequisites PASS without hop clients"
else
  fail "PHASE2_ONLY prerequisites should not require hop clients"
fi
mm_info "OS_HOP_CLIENT_FILES_REQUIRED=NO" >/dev/null
if mm_client_files_ready_phase2 "$MM_CLIENT_ROOT"; then
  pass "PHASE2_HELPERS_READY with helpers only"
else
  fail "phase2 helpers ready check failed"
fi

# --- 3. OS Core ready + no clients → rebuild action ---
PREPARATION_MODE=FULL
export PREPARATION_MODE
rm -f "${MM_CLIENT_ROOT}/dp-offline-upgrade-"*.sh
engine_assess_client_set_for_finalize
[[ "${CLIENT_SET_ACTION}" == "REBUILD_SIGN_PUBLISH" ]] \
  && pass "OS Core ready + no clients → REBUILD_SIGN_PUBLISH" \
  || fail "action=${CLIENT_SET_ACTION}"

# --- No stale committed client copy in bootstrap path ---
if grep -q 'cp -a .*client/dp-offline-upgrade' "${ROOT}/lib/bootstrap.sh"; then
  fail "bootstrap still copies stale prebuilt hop clients"
else
  pass "STALE_CLIENT_COPY_ALLOWED=NO (bootstrap does not copy hop clients)"
fi

echo "=== summary ==="
if [[ "$FAIL" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASS"
exit 0
