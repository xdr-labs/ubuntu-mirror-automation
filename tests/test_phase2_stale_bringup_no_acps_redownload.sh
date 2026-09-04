#!/usr/bin/env bash
# Production regression: after a successful Menu 2 run the ACPS cache is gone.
# A later patched-bringup change must rebuild the final from the existing
# verified bundle with zero ACPS network acquisition. Corrupt finals must not
# be trusted and must fall back to ACPS recovery.
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
UPSTREAM_FIXTURE="${ROOT}/tests/fixtures/dp-phase2/upstream_bringup_unpatched.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# TEST-LOCAL project trust-root: synthetic fixture digests must never enter
# the repository production allowlist. Mirror scripts from ROOT; replace only
# the allowlist under this temporary MM_PROJECT_ROOT.
SHADOW_ROOT="${TMP}/proj"
mkdir -p "${SHADOW_ROOT}/vendor"
cp -a "${ROOT}/vendor/dp-phase2" "${SHADOW_ROOT}/vendor/dp-phase2"
SYNTH_SHA256="$(sha256sum "$UPSTREAM_FIXTURE" | awk '{print $1}')"
cat >"${SHADOW_ROOT}/vendor/dp-phase2/approved-upstream-bringup.sha256" <<EOF
# TEST-LOCAL allowlist — not production provenance
${SYNTH_SHA256}  upstream_bringup_unpatched
EOF
ln -sfn "${ROOT}/scripts" "${SHADOW_ROOT}/scripts"
ln -sfn "${ROOT}/client" "${SHADOW_ROOT}/client"
ln -sfn "${ROOT}/lib" "${SHADOW_ROOT}/lib"
ln -sfn "${ROOT}/config" "${SHADOW_ROOT}/config"
ln -sfn "${ROOT}/templates" "${SHADOW_ROOT}/templates" 2>/dev/null || true

export MM_PROJECT_ROOT="$SHADOW_ROOT"
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
export TARGET_DP_VERSION=6.6.0
export PHASE2_TARGET_VERSION=6.6.0
export ACPS_USERNAME=testuser
export ACPS_PASSWORD=testpass
export OS_CORE_R2_URL='http://127.0.0.1:9/os-core.tar'
export PREPARATION_MODE=PHASE2_ONLY
export SKIP_MIRROR_HOST_VALIDATE=1

mkdir -p "$MM_CLIENT_ROOT" "$MM_CACHE_ROOT" "$MM_DP_PHASE2_ROOT" "$MM_LOG_DIR" \
  "$MM_STATE_ROOT" "$MM_CONFIG_DIR"
seed_complete_client_http_set "$MM_CLIENT_ROOT" "http://192.0.2.10" \
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

write_cfg() {
  cat >"$MM_CONFIG_FILE" <<EOF
PREPARATION_MODE=PHASE2_ONLY
TARGET_DP_VERSION=6.6.0
ACPS_USERNAME=testuser
ACPS_PASSWORD=testpass
OS_CORE_R2_URL=http://127.0.0.1:9/os-core.tar
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
EOF
  chmod 600 "$MM_CONFIG_FILE"
}
write_cfg

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

CURRENT_SHA="$(sha1sum "$PATCHED_BRINGUP" | awk '{print $1}')"
CURRENT_GEN="$(python3 "${ROOT}/scripts/lib/patch_dp_phase2_bringup.py" --print-generation \
  | awk -F= '$1=="BRINGUP_PATCH_GENERATION"{print $2; exit}')"
UPSTREAM_FIXTURE_SHA="$(sha1sum "$UPSTREAM_FIXTURE" | awk '{print $1}')"

engine_rebuild_publish_local_client_set() {
  seed_complete_client_http_set "$MM_CLIENT_ROOT" "http://192.0.2.10" \
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  return 0
}
engine_finalize_local_client_set() {
  seed_complete_client_http_set "$MM_CLIENT_ROOT" "http://192.0.2.10" \
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  mm_status_set CLIENT_FILES_READY PASS
  mm_ok "CLIENT_SET_FINALIZATION=PASS (stale-bringup no-acps fixture)"
  return 0
}
mm_client_set_current_source() { return 0; }
engine_assert_same_filesystem_layout() { return 0; }
engine_preflight_host() { return 0; }
mm_acquire_install_lock() { return 0; }
mm_release_install_lock() { return 0; }
mm_check_client_build_prerequisites_ready() {
  mm_state_set CLIENT_BUILD_PREREQUISITES_READY PASS
  mm_ok "CLIENT_BUILD_PREREQUISITES_READY=PASS"
  return 0
}
acps_setup_curl_auth() { return 0; }
acps_test_connection() { return 0; }
acps_expected_bytes_hint() { printf '300\n'; }

OLD_VENDOR="${TMP}/old-vendor.sh"
cat >"$OLD_VENDOR" <<'EOF'
#!/bin/bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) shift 2 ;;
    --skip-download|--dry-run) shift ;;
    --worker-ips) shift 2 ;;
    *)
      echo "FATAL: Unknown option: $1"
      exit 1
      ;;
  esac
done
echo "OLD_VENDOR_RAN=YES"
EOF
chmod +x "$OLD_VENDOR"

make_work_tree() {
  local work="$1" bringup_src="$2"
  mkdir -p "$work"
  printf 'common-payload\n' >"${work}/aelladeb_py3_common.tar.gz"
  sha1sum "${work}/aelladeb_py3_common.tar.gz" | awk '{print $1}' \
    >"${work}/aelladeb_py3_common.tar.gz.sha1"
  printf 'uvp-payload\n' >"${work}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb"
  sha1sum "${work}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}' \
    >"${work}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
  cp -f "$bringup_src" "${work}/bringup_py3_dp_after_os_upgrade.sh"
  sha1sum "${work}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
    >"${work}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  seq 1 156 >"${work}/images-6.6.0.list"
  printf 'images-body\n' >"${work}/images-6.6.0.tar"
  sha256sum "${work}/images-6.6.0.tar" | awk '{print $1}' \
    >"${work}/images-6.6.0.tar.sha256"
}

publish_bundle_from_work() {
  local work="$1" patched_sha="${2:-}"
  local dest="${MM_DP_PHASE2_ROOT}/6.6.0"
  local stable="dp_bundle_6.6.0-current.tar"
  rm -rf "$dest"
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
  cat >"${dest}/release.env" <<EOF
TARGET_DP_VERSION=6.6.0
PHASE2_ARTIFACT_VERSION=6.6.0
STABLE_BUNDLE_NAME=${stable}
PHASE2_BUNDLE_ENTRY_COUNT=9
EOF
  if [[ -n "$patched_sha" ]]; then
    printf 'BRINGUP_PATCHED_SHA1=%s\n' "$patched_sha" >>"${dest}/release.env"
  fi
  printf 'BRINGUP_UPSTREAM_SHA1=%s\n' "$UPSTREAM_FIXTURE_SHA" >>"${dest}/release.env"
  cp -f "$UPSTREAM_FIXTURE" "${dest}/bringup_py3_dp_after_os_upgrade.sh.upstream"
  sha1sum "${dest}/bringup_py3_dp_after_os_upgrade.sh.upstream" | awk '{print $1}' \
    >"${dest}/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1"
}

COUNTERS="${TMP}/counters"
mkdir -p "$COUNTERS"
reset_counters() {
  printf '0\n' >"${COUNTERS}/acps"
}
bump() {
  local f="${COUNTERS}/$1"
  local n
  n="$(cat "$f" 2>/dev/null || echo 0)"
  printf '%s\n' "$((n + 1))" >"$f"
}
count_of() { cat "${COUNTERS}/$1"; }

install_fail_closed_acps() {
  acps_acquire_all() {
    bump acps
    echo "ACPS network acquisition must not occur for stale bringup-only rebuild" >&2
    return 1
  }
}

install_recovery_acps() {
  acps_acquire_all() {
    bump acps
    local cache
    cache="$(acps_cache_dir 6.6.0)"
    make_work_tree "$cache" "$UPSTREAM_FIXTURE"
  }
}

run_prepare_to() {
  local log="$1"
  : >"$log"
  if ( engine_download_and_prepare >"$log" 2>&1 ); then
    return 0
  fi
  return 1
}

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

assert_rebuilt_current_final() {
  local dest="${MM_DP_PHASE2_ROOT}/6.6.0"
  local stable="dp_bundle_6.6.0-current.tar"
  local extract="${TMP}/extract-$$"
  local expected actual inner_sha published_sha
  [[ -f "${dest}/${stable}" ]] || fail "rebuilt final bundle missing"
  [[ -f "${dest}/${stable}.sha256" ]] || fail "rebuilt sidecar missing"
  grep -q "^BRINGUP_PATCH_GENERATION=${CURRENT_GEN}$" "${dest}/release.env" \
    || fail "regenerated release.env missing current BRINGUP_PATCH_GENERATION"
  published_sha="$(grep -E '^BRINGUP_PATCHED_SHA1=' "${dest}/release.env" | head -1 | cut -d= -f2-)"
  [[ -n "$published_sha" ]] || fail "regenerated release.env missing BRINGUP_PATCHED_SHA1"
  expected="$(awk '{print $1}' "${dest}/${stable}.sha256")"
  actual="$(sha256sum "${dest}/${stable}" | awk '{print $1}')"
  [[ "${expected,,}" == "${actual,,}" ]] || fail "regenerated final SHA256 does not verify"
  rm -rf "$extract"
  mkdir -p "$extract"
  tar -xf "${dest}/${stable}" -C "$extract" bringup_py3_dp_after_os_upgrade.sh
  grep -q -- '--worker-password' "${extract}/bringup_py3_dp_after_os_upgrade.sh" \
    || fail "regenerated bundle still has old vendor without --worker-password"
  inner_sha="$(sha1sum "${extract}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
  [[ "${published_sha,,}" == "${inner_sha,,}" ]] \
    || fail "published BRINGUP_PATCHED_SHA1 does not match inner bringup"
  cmp -s "$PATCHED_BRINGUP" "${extract}/bringup_py3_dp_after_os_upgrade.sh" \
    && fail "regenerated bundle is the frozen vendor full copy" || true
  grep -q 'OLD_VENDOR_RAN=YES' "${extract}/bringup_py3_dp_after_os_upgrade.sh" \
    && fail "old vendor still present in regenerated bundle" || true
  rm -rf "$extract"
}

# --- 1. Stale patched SHA, no ACPS cache: rebuild from existing final ---
OLD_WORK="${TMP}/old-work"
make_work_tree "$OLD_WORK" "$OLD_VENDOR"
OLD_SHA="$(sha1sum "${OLD_WORK}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
publish_bundle_from_work "$OLD_WORK" "$OLD_SHA"
rm -rf "${MM_CACHE_ROOT}/acps"
[[ ! -e "${MM_CACHE_ROOT}/acps" ]] || fail "ACPS cache must be absent for this regression"

engine_assess_phase2_final 6.6.0
[[ "$PHASE2_EXISTING_BUNDLE" == "INVALID" ]] \
  || fail "stale bundle not INVALID got=${PHASE2_EXISTING_BUNDLE}"
[[ "${PHASE2_EXISTING_INVALID_REASON}" == "patch_generation_missing" ]] \
  || fail "reason want=patch_generation_missing got=${PHASE2_EXISTING_INVALID_REASON}"
[[ "${PHASE2_EXISTING_FINAL_INTEGRITY}" == "PASS" ]] \
  || fail "stale but verified final integrity want=PASS got=${PHASE2_EXISTING_FINAL_INTEGRITY}"
engine_phase2_existing_final_reusable \
  || fail "verified stale-bringup final should be a local rebuild source"
pass "stale patched SHA is INVALID with proven integrity"

reset_counters
install_fail_closed_acps
mm_status_set HTTP_DISTRIBUTION ENABLED
OUT="${TMP}/prepare_stale.log"
run_prepare_to "$OUT" || { cat "$OUT"; fail "stale-bringup local rebuild prepare failed"; }
grep -q 'PHASE2_EXISTING_BUNDLE=INVALID' "$OUT" || fail "INVALID assess missing"
grep -q 'PHASE2_EXISTING_INVALID_REASON=patch_generation_missing' "$OUT" \
  || fail "PHASE2_EXISTING_INVALID_REASON missing"
grep -q 'PHASE2_REBUILD_SOURCE=EXISTING_FINAL' "$OUT" \
  || fail "PHASE2_REBUILD_SOURCE=EXISTING_FINAL missing"
grep -q 'ACPS_DOWNLOAD_REQUIRED=NO reason=existing_final_reuse' "$OUT" \
  || fail "existing_final_reuse download skip missing"
grep -q 'ACPS_REDOWNLOAD_AVOIDED=YES' "$OUT" || fail "ACPS_REDOWNLOAD_AVOIDED=YES missing"
grep -q 'verified_cache_reuse' "$OUT" && fail "must not claim verified_cache_reuse" || true
grep -q 'PHASE2_BUNDLE_ACTION=REBUILD' "$OUT" || fail "REBUILD action missing"
[[ "$(count_of acps)" -eq 0 ]] || fail "ACPS_ACQUIRE_INVOCATIONS=$(count_of acps) want=0"
assert_rebuilt_current_final
engine_assess_phase2_final 6.6.0
[[ "$PHASE2_EXISTING_BUNDLE" == "VALID" ]] \
  || fail "rebuilt final not VALID got=${PHASE2_EXISTING_BUNDLE}"
[[ "$(mm_status_get HTTP_DISTRIBUTION)" == "DISABLED" ]] \
  || fail "HTTP still ENABLED during/after stale rebuild"
find "$MM_DP_PHASE2_ROOT" -maxdepth 1 -name '6.6.0.old.*' | grep -q . \
  && fail ".old leftover after local rebuild" || true
echo "ACPS_ACQUIRE_INVOCATIONS=$(count_of acps)"
pass "stale bringup + no ACPS cache rebuilds from existing final (ACPS=0)"

# --- 2. Older generation missing BRINGUP_PATCHED_SHA1: still no ACPS download ---
publish_bundle_from_work "$OLD_WORK" ""
rm -rf "${MM_CACHE_ROOT}/acps"
engine_assess_phase2_final 6.6.0
[[ "$PHASE2_EXISTING_BUNDLE" == "INVALID" ]] \
  || fail "missing SHA bundle not INVALID"
[[ "${PHASE2_EXISTING_INVALID_REASON}" == "patch_generation_missing" ]] \
  || fail "reason want=patch_generation_missing got=${PHASE2_EXISTING_INVALID_REASON}"
[[ "${PHASE2_EXISTING_FINAL_INTEGRITY}" == "PASS" ]] \
  || fail "missing-SHA verified final integrity want=PASS"
reset_counters
install_fail_closed_acps
OUT="${TMP}/prepare_missing_sha.log"
run_prepare_to "$OUT" || { cat "$OUT"; fail "missing-SHA local rebuild prepare failed"; }
grep -q 'PHASE2_REBUILD_SOURCE=EXISTING_FINAL' "$OUT" \
  || fail "missing-SHA path did not use EXISTING_FINAL"
[[ "$(count_of acps)" -eq 0 ]] || fail "missing-SHA ACPS_ACQUIRE_INVOCATIONS=$(count_of acps) want=0"
assert_rebuilt_current_final
pass "missing BRINGUP_PATCHED_SHA1 rebuilds from verified final (ACPS=0)"

# --- 3. Stale SHA + corrupt sidecar: must NOT reuse; ACPS recovery invoked ---
publish_bundle_from_work "$OLD_WORK" "$OLD_SHA"
printf '0000000000000000000000000000000000000000000000000000000000000000  dp_bundle_6.6.0-current.tar\n' \
  >"${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar.sha256"
rm -rf "${MM_CACHE_ROOT}/acps"
engine_assess_phase2_final 6.6.0
[[ "$PHASE2_EXISTING_BUNDLE" == "INVALID" ]] \
  || fail "corrupt sidecar not INVALID"
[[ "${PHASE2_EXISTING_INVALID_REASON}" == "sha256" ]] \
  || fail "corrupt sidecar reason want=sha256 got=${PHASE2_EXISTING_INVALID_REASON}"
engine_phase2_existing_final_reusable \
  && fail "corrupt final must not be a local rebuild source" || true
reset_counters
install_recovery_acps
OUT="${TMP}/prepare_corrupt.log"
run_prepare_to "$OUT" || { cat "$OUT"; fail "corrupt-final ACPS recovery prepare failed"; }
grep -q 'PHASE2_EXISTING_INVALID_REASON=sha256' "$OUT" || fail "sha256 reason missing in prepare log"
grep -q 'PHASE2_REBUILD_SOURCE=ACPS' "$OUT" || fail "PHASE2_REBUILD_SOURCE=ACPS missing"
grep -q 'ACPS_DOWNLOAD_REQUIRED=YES' "$OUT" || fail "ACPS_DOWNLOAD_REQUIRED=YES missing"
grep -q 'INVALID_EXISTING_BUNDLE_ACTION=DELETE_BEFORE_REBUILD' "$OUT" \
  || fail "corrupt final was not deleted before ACPS rebuild"
[[ "$(count_of acps)" -eq 1 ]] || fail "corrupt fallback ACPS_ACQUIRE_INVOCATIONS=$(count_of acps) want=1"
assert_rebuilt_current_final
echo "ACPS_ACQUIRE_INVOCATIONS=$(count_of acps)"
pass "corrupt stale final fails closed and invokes ACPS recovery"

# --- 4. Outer SHA256 PASS, inner images SHA256 FAIL: must NOT reuse ---
publish_bundle_from_work "$OLD_WORK" "$OLD_SHA"
INNER_WORK="${TMP}/inner-corrupt-work"
rm -rf "$INNER_WORK"
mkdir -p "$INNER_WORK"
tar -xf "${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar" -C "$INNER_WORK"
# Mutate images tar only. Keep images-6.6.0.tar.sha256 and both SHA1 pairs.
printf 'images-body-CORRUPT-INNER\n' >"${INNER_WORK}/images-6.6.0.tar"
dest="${MM_DP_PHASE2_ROOT}/6.6.0"
stable="dp_bundle_6.6.0-current.tar"
tar -cf "${dest}/${stable}" -C "$INNER_WORK" \
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

outer_expected="$(awk '{print $1}' "${dest}/${stable}.sha256")"
outer_actual="$(sha256sum "${dest}/${stable}" | awk '{print $1}')"
[[ "${outer_expected,,}" == "${outer_actual,,}" ]] \
  || fail "crafted outer SHA256 sidecar does not match rewritten tar"
dp2_assert_safe_tar_list "${dest}/${stable}" >/dev/null \
  || fail "crafted outer tar list is not safe/required-entry exact"
inner_expected="$(awk '{print $1}' "${INNER_WORK}/images-6.6.0.tar.sha256")"
inner_actual="$(sha256sum "${INNER_WORK}/images-6.6.0.tar" | awk '{print $1}')"
[[ "${inner_expected,,}" != "${inner_actual,,}" ]] \
  || fail "inner images SHA256 still matches; corruption did not take"
common_expected="$(tr -d '[:space:]' <"${INNER_WORK}/aelladeb_py3_common.tar.gz.sha1")"
common_actual="$(sha1sum "${INNER_WORK}/aelladeb_py3_common.tar.gz" | awk '{print $1}')"
[[ "${common_expected,,}" == "${common_actual,,}" ]] \
  || fail "common SHA1 pair should remain valid"
uvp_expected="$(tr -d '[:space:]' <"${INNER_WORK}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1")"
uvp_actual="$(sha1sum "${INNER_WORK}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}')"
[[ "${uvp_expected,,}" == "${uvp_actual,,}" ]] \
  || fail "uvp SHA1 pair should remain valid"
echo "OUTER_SHA256_PASS_IN_TEST=YES"
echo "INNER_IMAGES_SHA256_FAIL_IN_TEST=YES"

rm -rf "${MM_CACHE_ROOT}/acps"
engine_assess_phase2_final 6.6.0
[[ "$PHASE2_EXISTING_BUNDLE" == "INVALID" ]] \
  || fail "inner-corrupt bundle not INVALID got=${PHASE2_EXISTING_BUNDLE}"
[[ "${PHASE2_EXISTING_INVALID_REASON}" == "inner_images_sha256" ]] \
  || fail "inner-corrupt reason want=inner_images_sha256 got=${PHASE2_EXISTING_INVALID_REASON}"
[[ "${PHASE2_EXISTING_FINAL_INTEGRITY}" != "PASS" ]] \
  || fail "inner-corrupt integrity must not be PASS"
engine_phase2_existing_final_reusable \
  && fail "inner-corrupt final must not be a local rebuild source" || true
echo "LOCAL_REUSE_REJECTED=YES"

reset_counters
install_recovery_acps
OUT="${TMP}/prepare_inner_corrupt.log"
run_prepare_to "$OUT" || { cat "$OUT"; fail "inner-corrupt ACPS recovery prepare failed"; }
grep -q 'PHASE2_EXISTING_INVALID_REASON=inner_images_sha256' "$OUT" \
  || fail "inner_images_sha256 reason missing in prepare log"
grep -q 'PHASE2_INNER_IMAGES_SHA256=FAIL' "$OUT" \
  || fail "PHASE2_INNER_IMAGES_SHA256=FAIL missing"
grep -q 'SHA1_VERIFY=PASS file=aelladeb_py3_common.tar.gz' "$OUT" \
  || fail "common SHA1 pair was not verified before rejecting reuse"
grep -q 'SHA1_VERIFY=PASS file=aella-uvp-2404_6.6.0ubuntu1_amd64.deb' "$OUT" \
  || fail "uvp SHA1 pair was not verified before rejecting reuse"
grep -q 'PHASE2_REBUILD_SOURCE=ACPS' "$OUT" || fail "PHASE2_REBUILD_SOURCE=ACPS missing"
grep -q 'ACPS_DOWNLOAD_REQUIRED=YES' "$OUT" || fail "ACPS_DOWNLOAD_REQUIRED=YES missing"
grep -q 'INVALID_EXISTING_BUNDLE_ACTION=DELETE_BEFORE_REBUILD' "$OUT" \
  || fail "inner-corrupt final was not deleted before ACPS rebuild"
grep -q 'PHASE2_REBUILD_SOURCE=EXISTING_FINAL' "$OUT" \
  && fail "inner-corrupt bundle must not be selected as EXISTING_FINAL" || true
[[ "$(count_of acps)" -eq 1 ]] || fail "inner-corrupt ACPS_ACQUIRE_INVOCATIONS=$(count_of acps) want=1"
assert_rebuilt_current_final
REBUILT_EXTRACT="${TMP}/rebuilt-inner-check"
rm -rf "$REBUILT_EXTRACT"
mkdir -p "$REBUILT_EXTRACT"
tar -xf "${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar" -C "$REBUILT_EXTRACT" \
  images-6.6.0.tar
grep -q 'CORRUPT-INNER' "${REBUILT_EXTRACT}/images-6.6.0.tar" \
  && fail "corrupt existing final became the source of the new bundle" || true
echo "ACPS_ACQUIRE_INVOCATIONS=$(count_of acps)"
pass "inner images SHA256 fail-closed; ACPS recovery; corrupt final not reused"

echo "TEST_PHASE2_STALE_BRINGUP_NO_ACPS_REDOWNLOAD=PASS"
