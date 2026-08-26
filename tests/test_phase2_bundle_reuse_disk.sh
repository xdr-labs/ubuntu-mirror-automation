#!/usr/bin/env bash
# Phase 2 valid-bundle REUSE, invalid delete-before-rebuild, R2 early cleanup, 100GB disk.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/seed_complete_client_http_set.sh
source "${ROOT}/tests/lib/seed_complete_client_http_set.sh"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
DP2="${ROOT}/scripts/lib/dp-phase2-common.sh"
ACPS="${ROOT}/scripts/lib/acps_acquire.sh"
R2="${ROOT}/scripts/lib/r2_acquire.sh"
PATCHED_BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

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
export PREPARATION_MODE=PHASE2_ONLY

mkdir -p "$MM_CLIENT_ROOT" "$MM_CACHE_ROOT" "$MM_DP_PHASE2_ROOT" "$MM_LOG_DIR" "$MM_STATE_ROOT" "$MM_CONFIG_DIR"
seed_complete_client_http_set "$MM_CLIENT_ROOT" "http://192.0.2.10"   "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

write_cfg() {
  local mode="$1"
  cat >"$MM_CONFIG_FILE" <<EOF
PREPARATION_MODE=${mode}
TARGET_DP_VERSION=6.6.0
ACPS_USERNAME=testuser
ACPS_PASSWORD=testpass
OS_CORE_R2_URL=http://127.0.0.1:9/os-core.tar
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
EOF
  chmod 600 "$MM_CONFIG_FILE"
}
export SKIP_MIRROR_HOST_VALIDATE=1
write_cfg PHASE2_ONLY

# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "$COMMON"
# shellcheck source=../scripts/lib/dp-phase2-common.sh
source "$DP2"
# shellcheck source=../scripts/lib/acps_acquire.sh
source "$ACPS"
# shellcheck source=../scripts/lib/r2_acquire.sh
source "$R2"
# shellcheck source=../scripts/lib/mirror_install_engine.sh
source "$ENGINE"

dp2_set_version 6.6.0

# This suite validates Phase 2 bundle REUSE / disk accounting. Client rebuild is
# out of scope — keep a complete on-disk set and skip provenance rebuild.
engine_rebuild_publish_local_client_set() {
  seed_complete_client_http_set "$MM_CLIENT_ROOT" "http://192.0.2.10" \
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  return 0
}
engine_finalize_local_client_set() {
  seed_complete_client_http_set "$MM_CLIENT_ROOT" "http://192.0.2.10" \
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  mm_status_set CLIENT_FILES_READY PASS
  mm_ok "CLIENT_SET_FINALIZATION=PASS (phase2-reuse fixture)"
  return 0
}
mm_client_set_current_source() { return 0; }

make_acps_work_tree() {
  local work="$1"
  mkdir -p "$work"
  printf 'common\n' >"${work}/aelladeb_py3_common.tar.gz"
  sha1sum "${work}/aelladeb_py3_common.tar.gz" | awk '{print $1}' \
    >"${work}/aelladeb_py3_common.tar.gz.sha1"
  printf 'uvp\n' >"${work}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb"
  sha1sum "${work}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}' \
    >"${work}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
  cp -f "$PATCHED_BRINGUP" "${work}/bringup_py3_dp_after_os_upgrade.sh"
  sha1sum "${work}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
    >"${work}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  seq 1 156 >"${work}/images-6.6.0.list"
  printf 'images-body\n' >"${work}/images-6.6.0.tar"
  sha256sum "${work}/images-6.6.0.tar" | awk '{print $1}' >"${work}/images-6.6.0.tar.sha256"
}

make_valid_final() {
  local work="${TMP}/valid-work"
  local dest="${MM_DP_PHASE2_ROOT}/6.6.0"
  local stable="dp_bundle_6.6.0-current.tar"
  local patched_sha
  rm -rf "$dest" "$work"
  make_acps_work_tree "$work"
  mkdir -p "$dest"
  tar -cf "${dest}/${stable}" -C "$work" \
    aelladeb_py3_common.tar.gz \
    aelladeb_py3_common.tar.gz.sha1 \
    aella-uvp-2404_6.6.0ubuntu1_amd64.deb \
    aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1 \
    bringup_py3_dp_after_os_upgrade.sh \
    bringup_py3_dp_after_os_upgrade.sh.sha1 \
    images-6.6.0.list \
    images-6.6.0.tar \
    images-6.6.0.tar.sha256
  (cd "$dest" && sha256sum "$stable" >"${stable}.sha256")
  patched_sha="$(sha1sum "$PATCHED_BRINGUP" | awk '{print $1}')"
  gen="$(python3 "${ROOT}/scripts/lib/patch_dp_phase2_bringup.py" --print-generation \
    | awk -F= '$1=="BRINGUP_PATCH_GENERATION"{print $2; exit}')"
  cat >"${dest}/release.env" <<EOF
TARGET_DP_VERSION=6.6.0
PHASE2_ARTIFACT_VERSION=6.6.0
STABLE_BUNDLE_NAME=${stable}
PHASE2_BUNDLE_ENTRY_COUNT=9
BRINGUP_PATCHED_SHA1=${patched_sha}
BRINGUP_PATCH_GENERATION=${gen}
BRINGUP_UPSTREAM_SHA1=70de02dd62409110dadb7553991d1ffb0a79f396
EOF
  cp -f "${ROOT}/tests/fixtures/dp-phase2/upstream_bringup_unpatched.sh" \
    "${dest}/bringup_py3_dp_after_os_upgrade.sh.upstream"
  sha1sum "${dest}/bringup_py3_dp_after_os_upgrade.sh.upstream" | awk '{print $1}' \
    >"${dest}/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1"
  [[ -f "${dest}/${stable}" ]] || fail "make_valid_final missing bundle"
}

COUNTERS="${TMP}/counters"
mkdir -p "$COUNTERS"
reset_counters() {
  printf '0\n' >"${COUNTERS}/acps"
  printf '0\n' >"${COUNTERS}/place"
  printf '0\n' >"${COUNTERS}/r2"
  printf '0\n' >"${COUNTERS}/r2_cleanup"
  printf '0\n' >"${COUNTERS}/materialize"
  printf '0\n' >"${COUNTERS}/r2_during_phase2"
}
bump() {
  local f="${COUNTERS}/$1"
  local n
  n="$(cat "$f" 2>/dev/null || echo 0)"
  printf '%s\n' "$((n + 1))" >"$f"
}
count_of() { cat "${COUNTERS}/$1"; }
reset_counters

# Capture real place implementation, then wrap for call counting.
eval "$(declare -f engine_place_dp_phase2_final | sed '1s/engine_place_dp_phase2_final/real_engine_place_dp_phase2_final/')"
engine_place_dp_phase2_final() {
  bump place
  real_engine_place_dp_phase2_final "$@"
}

install_create_mocks() {
  acps_acquire_all() {
    bump acps
    if find "${MM_CACHE_ROOT}/r2" -type f 2>/dev/null | grep -q .; then
      printf '1\n' >"${COUNTERS}/r2_during_phase2"
    fi
    local cache
    cache="$(acps_cache_dir 6.6.0)"
    make_acps_work_tree "$cache"
  }
  engine_stage_acps_work_from_cache() {
    local cache="$1" work="$2" f
    rm -rf "$work"
    mkdir -p "$work"
    for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
      case "$f" in
        bringup_py3_dp_after_os_upgrade.sh|bringup_py3_dp_after_os_upgrade.sh.sha1) continue ;;
      esac
      ln "${cache}/${f}" "${work}/${f}" 2>/dev/null || cp -f "${cache}/${f}" "${work}/${f}"
    done
  }
  engine_apply_local_bringup_patch() {
    cp -f "$PATCHED_BRINGUP" "${1}/bringup_py3_dp_after_os_upgrade.sh"
    sha1sum "${1}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
      >"${1}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  }
  engine_assert_work_ready_for_bundle() { return 0; }
  engine_verify_acps_upstream_bringup() { return 0; }
}

acps_setup_curl_auth() { return 0; }
acps_test_connection() { return 0; }
acps_expected_bytes_hint() { printf '%s\n' "${ACPS_EXPECTED_BYTES:-300}"; }
r2_download_package() {
  bump r2
  mkdir -p "${MM_CACHE_ROOT}/r2"
  OS_CORE_PACKAGE="${MM_CACHE_ROOT}/r2/os-core.tar"
  printf 'r2-package\n' >"$OS_CORE_PACKAGE"
  OS_CORE_PACKAGE_BYTES="$(stat -c%s "$OS_CORE_PACKAGE")"
  mm_status_set R2_OS_CORE_DOWNLOADED PASS
}
r2_cleanup_package() {
  bump r2_cleanup
  rm -f "${MM_CACHE_ROOT}/r2/"*.tar "${MM_CACHE_ROOT}/r2/"*.sha256 2>/dev/null || true
  return 0
}
engine_verify_os_core_package() {
  mm_status_set R2_OS_CORE_CHECKSUM PASS
  OS_CORE_PAYLOAD_BYTES=200
  return 0
}
engine_materialize_os_mirror() {
  bump materialize
  mkdir -p "${MM_SELECTIVE_ROOT}/hops/xenial-to-bionic" "${MM_SELECTIVE_ROOT}/state"
  cat >"${MM_SELECTIVE_ROOT}/state/READY" <<EOF
selective_plan_checksum=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
discovery_artifact_checksum=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
os_core_provenance_source=PACKAGE_MANIFEST_AND_PAYLOAD_SHA256
EOF
  mm_status_set OS_MIRROR_READY PASS
  mm_state_set OS_MIRROR_READY PASS
  return 0
}
engine_assert_same_filesystem_layout() { return 0; }
engine_preflight_host() { return 0; }
mm_acquire_install_lock() { return 0; }
mm_release_install_lock() { return 0; }
# Disk/reuse fixtures do not ship a full selective tree; skip client finalization.
engine_finalize_local_client_set() {
  mm_state_set CLIENT_FILES_READY PASS
  mm_status_set CLIENT_FILES_READY PASS
  mm_ok "CLIENT_FILES_READY=PASS"
  mm_ok "CLIENT_SET_FINALIZATION=PASS (test mock)"
  return 0
}
mm_check_client_build_prerequisites_ready() {
  mm_state_set CLIENT_BUILD_PREREQUISITES_READY PASS
  mm_ok "CLIENT_BUILD_PREREQUISITES_READY=PASS"
  return 0
}

install_create_mocks

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

# Avoid $(...) pipe deadlock when place/heartbeat emits large progress logs.
# Run in a subshell so install flock is released between prepares.
run_prepare_to() {
  local log="$1"
  : >"$log"
  if ( engine_download_and_prepare >"$log" 2>&1 ); then
    return 0
  fi
  return 1
}

# --- 1. Valid existing bundle → REUSE ---
make_valid_final
engine_assess_phase2_final 6.6.0
[[ "$PHASE2_EXISTING_BUNDLE" == "VALID" ]] || fail "assess should be VALID got=${PHASE2_EXISTING_BUNDLE}"
reset_counters
write_cfg PHASE2_ONLY
PREPARATION_MODE=PHASE2_ONLY
OUT="${TMP}/prepare1.log"
run_prepare_to "$OUT" || { cat "$OUT"; fail "PHASE2_ONLY REUSE prepare failed"; }
grep -q 'PHASE2_BUNDLE_ACTION=REUSE' "$OUT" || fail "REUSE action missing"
grep -q 'ACPS_DOWNLOAD_REQUIRED=NO' "$OUT" || fail "ACPS_DOWNLOAD_REQUIRED missing"
grep -q 'FINAL_PHASE2_BUNDLE_COUNT=1' "$OUT" || fail "FINAL_PHASE2_BUNDLE_COUNT missing"
[[ "$(count_of acps)" -eq 0 ]] || fail "valid REUSE ACPS acquire count=$(count_of acps)"
[[ "$(count_of place)" -eq 0 ]] || fail "valid REUSE place count=$(count_of place)"
[[ "$(count_of r2)" -eq 0 ]] || fail "PHASE2_ONLY R2 download count=$(count_of r2)"
find "$MM_DP_PHASE2_ROOT" -maxdepth 1 -name '6.6.0.new.*' | grep -q . && fail ".new on REUSE" || true
find "$MM_DP_PHASE2_ROOT" -maxdepth 1 -name '6.6.0.old.*' | grep -q . && fail ".old on REUSE" || true
pass "1 VALID existing bundle REUSE (ACPS=0 place=0 .new=0 .old=0)"

# --- 6/7 FULL REUSE ---
reset_counters
write_cfg FULL
PREPARATION_MODE=FULL
OUT="${TMP}/prepare_full_reuse.log"
run_prepare_to "$OUT" || { cat "$OUT"; fail "FULL REUSE prepare failed"; }
grep -q 'PHASE2_BUNDLE_ACTION=REUSE' "$OUT" || fail "FULL REUSE missing"
grep -q 'R2_PACKAGE_REMOVED_AFTER_MATERIALIZE=YES' "$OUT" || fail "R2 early cleanup missing"
[[ "$(count_of acps)" -eq 0 ]] || fail "FULL REUSE ACPS=$(count_of acps)"
[[ "$(count_of place)" -eq 0 ]] || fail "FULL REUSE place=$(count_of place)"
[[ "$(count_of r2)" -eq 1 ]] || fail "FULL should still download R2 count=$(count_of r2)"
[[ "$(count_of materialize)" -eq 1 ]] || fail "FULL should materialize OS count=$(count_of materialize)"
pass "6/7 FULL REUSE keeps OS path; Phase2 ACPS/place=0"

# --- 2. Missing bundle → CREATE ---
rm -rf "${MM_DP_PHASE2_ROOT}/6.6.0"
reset_counters
write_cfg PHASE2_ONLY
PREPARATION_MODE=PHASE2_ONLY
OUT="${TMP}/prepare_create.log"
run_prepare_to "$OUT" || { cat "$OUT"; fail "CREATE prepare failed"; }
grep -q 'PHASE2_BUNDLE_ACTION=CREATE' "$OUT" || fail "CREATE action missing"
[[ "$(count_of acps)" -eq 1 ]] || fail "CREATE ACPS count=$(count_of acps)"
[[ "$(count_of place)" -eq 1 ]] || fail "CREATE place count=$(count_of place)"
[[ -f "${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar" ]] || fail "CREATE final missing"
find "$MM_DP_PHASE2_ROOT" -maxdepth 1 -name '6.6.0.old.*' | grep -q . && fail ".old on CREATE" || true
pass "2 missing bundle CREATE atomic final count=1"

# --- 3. Invalid SHA256 ---
printf '0000000000000000000000000000000000000000000000000000000000000000  dp_bundle_6.6.0-current.tar\n' \
  >"${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar.sha256"
mm_status_set HTTP_DISTRIBUTION ENABLED
reset_counters
OLD_MARK="${MM_DP_PHASE2_ROOT}/6.6.0/SHOULD_BE_REMOVED"
printf 'x\n' >"$OLD_MARK"
OUT="${TMP}/prepare_invalid_sha.log"
run_prepare_to "$OUT" || { cat "$OUT"; fail "INVALID sha rebuild failed"; }
grep -q 'PHASE2_EXISTING_BUNDLE=INVALID' "$OUT" || fail "INVALID assess missing"
grep -q 'INVALID_FINAL_REMOVED=YES' "$OUT" || fail "INVALID remove missing"
grep -q 'PHASE2_BUNDLE_ACTION=REBUILD' "$OUT" || fail "REBUILD action missing"
[[ ! -e "$OLD_MARK" ]] || fail "invalid final not removed before rebuild"
[[ "$(count_of acps)" -eq 1 ]] || fail "INVALID rebuild ACPS=$(count_of acps)"
find "$MM_DP_PHASE2_ROOT" -maxdepth 1 -name '6.6.0.old.*' | grep -q . && fail ".old on INVALID rebuild" || true
[[ "$(mm_status_get HTTP_DISTRIBUTION)" == "DISABLED" ]] \
  || fail "HTTP not DISABLED after invalid rebuild path"
pass "3 invalid SHA256 deletes final before ACPS; no .old"

# --- 4. Invalid release.env ---
make_valid_final
printf 'TARGET_DP_VERSION=9.9.9\nPHASE2_ARTIFACT_VERSION=9.9.9\nSTABLE_BUNDLE_NAME=dp_bundle_6.6.0-current.tar\n' \
  >"${MM_DP_PHASE2_ROOT}/6.6.0/release.env"
printf "0\n" >"${COUNTERS}/acps"
OUT="${TMP}/prepare_invalid_env.log"
run_prepare_to "$OUT" || { cat "$OUT"; fail "invalid env rebuild failed"; }
grep -q 'INVALID_FINAL_REMOVED=YES' "$OUT" || fail "invalid env not removed"
pass "4 invalid release.env rebuild (no old preserve)"

# --- 5. Interrupted partial download resume (.part kept) ---
PART="${MM_CACHE_ROOT}/acps/6.6.0/images-6.6.0.tar.part"
mkdir -p "$(dirname "$PART")"
printf 'partial-bytes\n' >"$PART"
engine_remove_invalid_phase2_final 6.6.0 >/dev/null || true
[[ -f "$PART" ]] || fail "ACPS .part must survive invalid-final cleanup"
pass "5 partial .part retained for resume"

# --- 8. R2 cleanup ordering during CREATE FULL ---
rm -rf "${MM_DP_PHASE2_ROOT}/6.6.0"
reset_counters
write_cfg FULL
PREPARATION_MODE=FULL
OUT="${TMP}/prepare_full_create.log"
run_prepare_to "$OUT" || { cat "$OUT"; fail "FULL CREATE failed"; }
grep -q 'R2_PACKAGE_PRESENT_DURING_PHASE2_BUILD=NO' "$OUT" || fail "R2 present marker missing"
[[ "$(count_of r2_during_phase2)" -eq 0 ]] || fail "R2 package still present during Phase 2"
[[ "$(count_of r2_cleanup)" -ge 1 ]] || fail "r2_cleanup not called"
pass "8 R2 removed after materialize before Phase 2"

# --- 9. hardlink / max copies ---
grep -q 'hardlink_required' "$ENGINE" || fail "hardlink refusal missing"
grep -q 'MAX_LARGE_ARTIFACT_COPIES=2' "$ENGINE" || fail "MAX_LARGE_ARTIFACT_COPIES missing"
pass "9 MAX_LARGE_ARTIFACT_COPIES=2 + hardlink required"

# --- REUSE disk zeros ---
PHASE2_BUNDLE_ACTION=REUSE
PHASE2_REBUILD_REQUIRED=NO
ACPS_EXPECTED_BYTES=30307553280
PREPARATION_MODE=PHASE2_ONLY
mm_calc_disk_requirements >/dev/null
[[ "$PHASE2_ACPS_SOURCE_REQUIRED_BYTES" -eq 0 ]] || fail "REUSE phase2 acps bytes"
[[ "$PHASE2_BUNDLE_OUTPUT_REQUIRED_BYTES" -eq 0 ]] || fail "REUSE phase2 bundle bytes"
pass "REUSE disk preflight Phase2 required bytes=0"

# --- patched bringup generation mismatch invalidates reuse ---
make_valid_final
sed -i 's/^BRINGUP_PATCHED_SHA1=.*/BRINGUP_PATCHED_SHA1=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' \
  "${MM_DP_PHASE2_ROOT}/6.6.0/release.env"
engine_assess_phase2_final 6.6.0
[[ "$PHASE2_EXISTING_BUNDLE" == "INVALID" ]] \
  || fail "stale patched bringup SHA should be INVALID got=${PHASE2_EXISTING_BUNDLE}"
[[ "${PHASE2_EXISTING_INVALID_REASON}" == "patched_bringup_changed" ]] \
  || fail "stale SHA reason want=patched_bringup_changed got=${PHASE2_EXISTING_INVALID_REASON}"
pass "stale BRINGUP_PATCHED_SHA1 invalidates existing bundle"

make_valid_final
grep -v '^BRINGUP_PATCHED_SHA1=' "${MM_DP_PHASE2_ROOT}/6.6.0/release.env" \
  >"${TMP}/release.env.nosha"
mv -f "${TMP}/release.env.nosha" "${MM_DP_PHASE2_ROOT}/6.6.0/release.env"
engine_assess_phase2_final 6.6.0
[[ "$PHASE2_EXISTING_BUNDLE" == "INVALID" ]] \
  || fail "missing patched bringup SHA should be INVALID got=${PHASE2_EXISTING_BUNDLE}"
[[ "${PHASE2_EXISTING_INVALID_REASON}" == "patched_bringup_sha_missing" ]] \
  || fail "missing SHA reason want=patched_bringup_sha_missing got=${PHASE2_EXISTING_INVALID_REASON}"
pass "missing BRINGUP_PATCHED_SHA1 invalidates existing bundle"

[[ "$PHASE2_TARGET_VERSION" == "6.6.0" ]] || fail "phase2 target"
pass "13 workflow markers (target 6.6.0 fixed)"

# --- 100GB-class EXISTING_FINAL local-rebuild disk preflight ---
# Production case: ~100GB filesystem, ~30GiB existing final, no ACPS cache,
# stale BRINGUP_PATCHED_SHA1, verified final eligible for local rebuild.
# Peak must be one extra copy + metadata + 10GiB safety — not
# existing + ACPS download + extracted source + new final.
make_valid_final
sed -i 's/^BRINGUP_PATCHED_SHA1=.*/BRINGUP_PATCHED_SHA1=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' \
  "${MM_DP_PHASE2_ROOT}/6.6.0/release.env"
engine_assess_phase2_final 6.6.0
[[ "$PHASE2_EXISTING_BUNDLE" == "INVALID" ]] \
  || fail "100GB stale bundle not INVALID got=${PHASE2_EXISTING_BUNDLE}"
[[ "${PHASE2_EXISTING_INVALID_REASON}" == "patched_bringup_changed" ]] \
  || fail "100GB reason want=patched_bringup_changed got=${PHASE2_EXISTING_INVALID_REASON}"
[[ "${PHASE2_EXISTING_FINAL_INTEGRITY}" == "PASS" ]] \
  || fail "100GB verified final integrity want=PASS got=${PHASE2_EXISTING_FINAL_INTEGRITY}"
engine_phase2_existing_final_reusable \
  || fail "100GB verified stale-bringup final should be a local rebuild source"
rm -rf "${MM_CACHE_ROOT}/acps"
[[ ! -e "${MM_CACHE_ROOT}/acps" ]] || fail "ACPS cache must be absent for 100GB regression"

REAL_SOURCE=30307553280
GIB=$((1024 * 1024 * 1024))
METADATA_OH=$((512 * 1024 * 1024))
SAFETY=$((10 * GIB))
BUNDLE_100="${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar"
truncate -s "$REAL_SOURCE" "$BUNDLE_100"
[[ "$(mm_file_bytes "$BUNDLE_100")" -eq "$REAL_SOURCE" ]] \
  || fail "sparse existing final size want=${REAL_SOURCE} got=$(mm_file_bytes "$BUNDLE_100")"

write_cfg PHASE2_ONLY
PREPARATION_MODE=PHASE2_ONLY
PHASE2_BUNDLE_ACTION=REBUILD
PHASE2_REBUILD_REQUIRED=YES
PHASE2_REBUILD_SOURCE=EXISTING_FINAL
ACPS_DOWNLOAD_REQUIRED=NO
PHASE2_EXISTING_FINAL_BYTES="$REAL_SOURCE"
ACPS_EXPECTED_BYTES="$REAL_SOURCE"
MM_MOCK_AVAILABLE_BYTES=$((80 * GIB))
MM_MOCK_FS_SIZE_BYTES=$((100 * 1000 * 1000 * 1000))
MM_MOCK_SAFETY_RESERVE_BYTES=$SAFETY
export PHASE2_BUNDLE_ACTION PHASE2_REBUILD_REQUIRED PHASE2_REBUILD_SOURCE
export ACPS_DOWNLOAD_REQUIRED PHASE2_EXISTING_FINAL_BYTES ACPS_EXPECTED_BYTES
export PREPARATION_MODE

mm_calc_disk_requirements >/dev/null
[[ "$PHASE2_REBUILD_SOURCE" == "EXISTING_FINAL" ]] \
  || fail "disk preflight mutated PHASE2_REBUILD_SOURCE=${PHASE2_REBUILD_SOURCE}"
[[ "$ACPS_DOWNLOAD_REQUIRED" == "NO" ]] \
  || fail "disk preflight mutated ACPS_DOWNLOAD_REQUIRED=${ACPS_DOWNLOAD_REQUIRED}"
[[ "$PHASE2_ACPS_SOURCE_REQUIRED_BYTES" -eq 0 ]] \
  || fail "EXISTING_FINAL must not reserve ACPS download got=${PHASE2_ACPS_SOURCE_REQUIRED_BYTES}"
[[ "$DISK_PREFLIGHT_ACPS_SOURCE_BYTES" -eq 0 ]] \
  || fail "DISK_PREFLIGHT_ACPS_SOURCE_BYTES want=0 got=${DISK_PREFLIGHT_ACPS_SOURCE_BYTES}"
[[ "$DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES" -eq "$REAL_SOURCE" ]] \
  || fail "bundle output want=${REAL_SOURCE} got=${DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES}"
[[ "$PHASE2_BUNDLE_OUTPUT_REQUIRED_BYTES" -eq "$REAL_SOURCE" ]] \
  || fail "PHASE2_BUNDLE_OUTPUT_REQUIRED_BYTES want=${REAL_SOURCE} got=${PHASE2_BUNDLE_OUTPUT_REQUIRED_BYTES}"
[[ "$DISK_PREFLIGHT_EXISTING_FINAL_BYTES" -eq "$REAL_SOURCE" ]] \
  || fail "existing final bytes want=${REAL_SOURCE} got=${DISK_PREFLIGHT_EXISTING_FINAL_BYTES}"
correct_stage=$((REAL_SOURCE + METADATA_OH))
[[ "$DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES" -eq "$correct_stage" ]] \
  || fail "stage extra want=${correct_stage} got=${DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES}"
[[ "$DISK_PREFLIGHT_SEQUENTIAL_STAGE_PEAK_BYTES" -eq "$correct_stage" ]] \
  || fail "sequential peak want=${correct_stage} got=${DISK_PREFLIGHT_SEQUENTIAL_STAGE_PEAK_BYTES}"
[[ "$DISK_PREFLIGHT_SAFETY_RESERVE_BYTES" -eq "$SAFETY" ]] \
  || fail "safety reserve weakened want=${SAFETY} got=${DISK_PREFLIGHT_SAFETY_RESERVE_BYTES}"
correct_required=$((correct_stage + SAFETY))
[[ "$TOTAL_REQUIRED_BYTES" -eq "$correct_required" ]] \
  || fail "required want=${correct_required} got=${TOTAL_REQUIRED_BYTES}"
[[ "$CURRENT_AVAILABLE_BASED_REQUIRED_BYTES" -eq "$correct_required" ]] \
  || fail "available-based required want=${correct_required} got=${CURRENT_AVAILABLE_BASED_REQUIRED_BYTES}"
[[ "$DISK_PREFLIGHT_RESULT" == "PASS" ]] \
  || fail "100GB-class EXISTING_FINAL preflight want=PASS got=${DISK_PREFLIGHT_RESULT}"
[[ "$AVAILABLE_BYTES" -ge "$TOTAL_REQUIRED_BYTES" ]] \
  || fail "100GB-class available ${AVAILABLE_BYTES} < required ${TOTAL_REQUIRED_BYTES}"
# Naive four-copy reservation: existing + ACPS download + extracted + new final.
wrong_required=$((REAL_SOURCE * 4 + METADATA_OH + SAFETY))
[[ "$wrong_required" -gt "$AVAILABLE_BYTES" ]] \
  || fail "naive four-copy required ${wrong_required} should exceed 80GiB available"
[[ "$TOTAL_REQUIRED_BYTES" -lt "$wrong_required" ]] \
  || fail "production required ${TOTAL_REQUIRED_BYTES} must be below four-copy ${wrong_required}"
echo "DISK_100GB_EXISTING_FINAL_STAGE_BYTES=${DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES}"
echo "DISK_100GB_EXISTING_FINAL_REQUIRED_BYTES=${TOTAL_REQUIRED_BYTES}"
echo "DISK_100GB_EXISTING_FINAL_WRONG_FOUR_COPY_BYTES=${wrong_required}"
echo "ACPS_DOWNLOAD_REQUIRED=${ACPS_DOWNLOAD_REQUIRED}"
echo "PHASE2_REBUILD_SOURCE=${PHASE2_REBUILD_SOURCE}"
pass "100GB-class EXISTING_FINAL disk preflight accounts one extra copy only"

echo "ALL PHASE2 BUNDLE REUSE / DISK TESTS PASSED"
