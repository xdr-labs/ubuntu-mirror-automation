#!/usr/bin/env bash
# Production regression: new lifecycle wrapper + stale Phase 2 bundle vendor
# that rejects --worker-password must not remain reusable, and staging must
# fail closed before BRINGUP_READY=YES.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
DP2="${ROOT}/scripts/lib/dp-phase2-common.sh"
PATCHED_BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
STAGE="${ROOT}/client/stage-dp-phase2.sh"
WRAPPER="${ROOT}/client/bringup_py3_dp_lifecycle.sh"

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
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_SELECTIVE_ROOT="${MM_MIRROR_ROOT}/selective"
export MM_CLIENT_ROOT="${MM_MIRROR_ROOT}/client"
export TARGET_DP_VERSION=6.6.0
export PHASE2_TARGET_VERSION=6.6.0
mkdir -p "$MM_CACHE_ROOT" "$MM_DP_PHASE2_ROOT" "$MM_LOG_DIR" "$MM_STATE_ROOT" \
  "$MM_CONFIG_DIR" "$MM_SELECTIVE_ROOT" "$MM_CLIENT_ROOT"
: >"$MM_STATUS_FILE"

# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "$COMMON"
# shellcheck source=../scripts/lib/dp-phase2-common.sh
source "$DP2"
# shellcheck source=../scripts/lib/mirror_install_engine.sh
source "$ENGINE"
dp2_set_version 6.6.0

[[ -f "$PATCHED_BRINGUP" ]] || fail "current patched bringup missing"
grep -q -- '--worker-password' "$PATCHED_BRINGUP" \
  || fail "current patched bringup lacks --worker-password"
grep -q -- '--worker-password' "$WRAPPER" \
  || fail "lifecycle wrapper lacks --worker-password passthrough"
CURRENT_SHA="$(sha1sum "$PATCHED_BRINGUP" | awk '{print $1}')"

# Old vendor generation: accepts --version/--skip-download/--worker-ips only.
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

set +e
old_err="$("$OLD_VENDOR" --version 6.6.0 --skip-download \
  --worker-ips "10.20.7.11,10.20.7.12" --worker-password 'Test123!' 2>&1)"
old_rc=$?
set -e
[[ "$old_rc" -ne 0 ]] || fail "old vendor accepted --worker-password"
printf '%s\n' "$old_err" | grep -Fq 'FATAL: Unknown option: --worker-password' \
  || fail "old vendor did not reproduce production FATAL"
printf '%s\n' "$old_err" | grep -Fq 'Test123!' \
  && fail "old vendor error leaked password" || true
pass "old vendor reproduces FATAL: Unknown option: --worker-password"

make_work_tree() {
  local work="$1" bringup_src="$2"
  mkdir -p "$work"
  printf 'common\n' >"${work}/aelladeb_py3_common.tar.gz"
  sha1sum "${work}/aelladeb_py3_common.tar.gz" | awk '{print $1}' \
    >"${work}/aelladeb_py3_common.tar.gz.sha1"
  printf 'uvp\n' >"${work}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb"
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
}

OLD_WORK="${TMP}/old-work"
make_work_tree "$OLD_WORK" "$OLD_VENDOR"
OLD_SHA="$(sha1sum "${OLD_WORK}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
publish_bundle_from_work "$OLD_WORK" "$OLD_SHA"

engine_assess_phase2_final 6.6.0
[[ "$PHASE2_EXISTING_BUNDLE" == "INVALID" ]] \
  || fail "old patched SHA bundle reusable got=${PHASE2_EXISTING_BUNDLE}"
[[ "${PHASE2_EXISTING_INVALID_REASON}" == "patch_generation_missing" ]] \
  || fail "reason want=patch_generation_missing got=${PHASE2_EXISTING_INVALID_REASON}"
pass "reuse assessment rejects old-vendor Phase 2 bundle"

publish_bundle_from_work "$OLD_WORK" ""
printf 'BRINGUP_PATCH_GENERATION=%s\n' \
  "$(python3 "${ROOT}/scripts/lib/patch_dp_phase2_bringup.py" --print-generation | awk -F= '$1=="BRINGUP_PATCH_GENERATION"{print $2; exit}')" \
  >>"${MM_DP_PHASE2_ROOT}/6.6.0/release.env"
printf 'BRINGUP_UPSTREAM_SHA1=70de02dd62409110dadb7553991d1ffb0a79f396\n' \
  >>"${MM_DP_PHASE2_ROOT}/6.6.0/release.env"
engine_assess_phase2_final 6.6.0
[[ "$PHASE2_EXISTING_BUNDLE" == "INVALID" ]] \
  || fail "bundle missing BRINGUP_PATCHED_SHA1 still VALID"
[[ "${PHASE2_EXISTING_INVALID_REASON}" == "patched_bringup_sha_missing" ]] \
  || fail "reason want=patched_bringup_sha_missing got=${PHASE2_EXISTING_INVALID_REASON}"
pass "reuse assessment rejects bundle without BRINGUP_PATCHED_SHA1"

# Rebuild using current patched bringup; large image payload is the small fixture.
NEW_WORK="${TMP}/new-work"
make_work_tree "$NEW_WORK" "$PATCHED_BRINGUP"
mkdir -p "${NEW_WORK}.upstream"
cp -f "${ROOT}/tests/fixtures/dp-phase2/upstream_bringup_unpatched.sh" \
  "${NEW_WORK}.upstream/bringup_py3_dp_after_os_upgrade.sh"
sha1sum "${NEW_WORK}.upstream/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
  >"${NEW_WORK}.upstream/bringup_py3_dp_after_os_upgrade.sh.sha1"
export MM_KEEP_PHASE2_SOURCES=1
BRINGUP_UPSTREAM_SHA1="$(sha1sum "${NEW_WORK}.upstream/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
BRINGUP_PATCH_GENERATION="$(python3 "${ROOT}/scripts/lib/patch_dp_phase2_bringup.py" --print-generation | awk -F= '$1=="BRINGUP_PATCH_GENERATION"{print $2; exit}')"
BRINGUP_PATCHED_SHA1="$CURRENT_SHA"
engine_place_dp_phase2_final "$NEW_WORK" 6.6.0 >/dev/null
NEW_ENV="${MM_DP_PHASE2_ROOT}/6.6.0/release.env"
NEW_BUNDLE="${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar"
grep -q "^BRINGUP_PATCHED_SHA1=${CURRENT_SHA}$" "$NEW_ENV" \
  || fail "regenerated release.env missing current BRINGUP_PATCHED_SHA1"
EXTRACT="${TMP}/extract"
mkdir -p "$EXTRACT"
tar -xf "$NEW_BUNDLE" -C "$EXTRACT" bringup_py3_dp_after_os_upgrade.sh
grep -q -- '--worker-password' "${EXTRACT}/bringup_py3_dp_after_os_upgrade.sh" \
  || fail "regenerated bundle vendor lacks --worker-password"
cmp -s "$PATCHED_BRINGUP" "${EXTRACT}/bringup_py3_dp_after_os_upgrade.sh" \
  || fail "regenerated bundle bringup is not the current patched file"
engine_assess_phase2_final 6.6.0
[[ "$PHASE2_EXISTING_BUNDLE" == "VALID" ]] \
  || fail "rebuilt current bundle not VALID got=${PHASE2_EXISTING_BUNDLE}"
pass "regenerated bundle contains current patched bringup"

# Staging compatibility gate: source helpers only, never execute bringup.
export DP_PHASE2_STAGE_LIB_ONLY=1
# shellcheck source=../client/stage-dp-phase2.sh
source "$STAGE"

VENDOR_BRINGUP_INSTALLED="${TMP}/installed.vendor.sh"
BRINGUP_SCRIPT="${TMP}/installed.wrapper.sh"
cp -f "$OLD_VENDOR" "$VENDOR_BRINGUP_INSTALLED"
cp -f "$WRAPPER" "$BRINGUP_SCRIPT"
set +e
verify_installed_bringup_vendor_compat >/dev/null
compat_rc=$?
set -e
[[ "$compat_rc" -ne 0 ]] || fail "compat gate accepted old vendor"
[[ "${BRINGUP_VENDOR_COMPAT}" == "FAIL" ]] || fail "BRINGUP_VENDOR_COMPAT not FAIL for old vendor"
pass "staging compat rejects vendor without --worker-password"

cp -f "$PATCHED_BRINGUP" "$VENDOR_BRINGUP_INSTALLED"
set +e
verify_installed_bringup_vendor_compat >/dev/null
compat_rc=$?
set -e
[[ "$compat_rc" -eq 0 ]] || fail "compat gate rejected current patched vendor"
[[ "${BRINGUP_VENDOR_COMPAT}" == "PASS" ]] || fail "BRINGUP_VENDOR_COMPAT not PASS for current vendor"
pass "staging compat accepts current patched vendor"

echo "TEST_PHASE2_STALE_BRINGUP_BUNDLE=PASS"
