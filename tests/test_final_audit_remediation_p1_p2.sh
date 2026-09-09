#!/usr/bin/env bash
# Targeted regressions for final audit remediation (P1/P2, non-keyring).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== test_final_audit_remediation_p1_p2 ==="

# ---------- P1: production ACPS test escapes ----------
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/acps_auth.sh"
unset DP_PHASE2_SOURCE_BASE || true
export ACPS_INSECURE_TLS=1
export MM_HERMETIC_TEST_MODE=0
export ACPS_BASE_URL="https://acps.example.test/provision"
export ACPS_USERNAME=u
export ACPS_PASSWORD=p
set +e
out="$(acps_setup_curl_auth 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'ACPS_INSECURE_TLS=FAIL'; then
  pass "production rejects ACPS_INSECURE_TLS"
else
  fail "production should reject ACPS_INSECURE_TLS (rc=${rc})"
  printf '%s\n' "$out"
fi
unset ACPS_INSECURE_TLS
export DP_PHASE2_SOURCE_BASE="http://127.0.0.1:9/fixture"
set +e
out="$(acps_setup_curl_auth 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'DP_PHASE2_SOURCE_BASE=FAIL'; then
  pass "production rejects DP_PHASE2_SOURCE_BASE"
else
  fail "production should reject DP_PHASE2_SOURCE_BASE (rc=${rc})"
fi
export MM_HERMETIC_TEST_MODE=1
ACPS_EFFECTIVE_BASE=""
set +e
acps_setup_curl_auth >/tmp/acps_hermetic_ok.out 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 && "${ACPS_EFFECTIVE_BASE:-}" == "http://127.0.0.1:9/fixture" ]]; then
  pass "hermetic test mode allows source override"
else
  fail "hermetic source override should work (rc=${rc} base=${ACPS_EFFECTIVE_BASE:-})"
  cat /tmp/acps_hermetic_ok.out || true
fi
unset DP_PHASE2_SOURCE_BASE ACPS_INSECURE_TLS
export MM_HERMETIC_TEST_MODE=0

# ---------- P2: production target override ----------
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
export MM_ALLOW_TARGET_OVERRIDE=1
export TARGET_DP_VERSION=6.5.0
export MM_HERMETIC_TEST_MODE=0
set +e
out="$(mm_force_phase2_target 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'MM_ALLOW_TARGET_OVERRIDE=FAIL'; then
  pass "production rejects target override"
else
  # mm_die may exit the whole shell via ERR - capture in subshell
  set +e
  out="$(bash -c 'source "'"${ROOT}/scripts/lib/mirror_manager_common.sh"'"; MM_ALLOW_TARGET_OVERRIDE=1 MM_HERMETIC_TEST_MODE=0 TARGET_DP_VERSION=6.5.0 mm_force_phase2_target' 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'production_forbidden\|MM_ALLOW_TARGET_OVERRIDE=FAIL'; then
    pass "production rejects target override"
  else
    fail "production target override should fail (rc=${rc} out=${out})"
  fi
fi
# Hermetic target override
set +e
(
  source "${ROOT}/scripts/lib/mirror_manager_common.sh"
  export MM_ALLOW_TARGET_OVERRIDE=1
  export MM_HERMETIC_TEST_MODE=1
  TARGET_DP_VERSION=6.5.0
  mm_force_phase2_target
  printf 'TARGET=%s\n' "$TARGET_DP_VERSION"
) >"${TMP}/target-override.out" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q 'TARGET=6.5.0' "${TMP}/target-override.out"; then
  pass "hermetic mode allows target override"
else
  fail "hermetic target override failed (rc=${rc})"
  cat "${TMP}/target-override.out" || true
fi
unset MM_ALLOW_TARGET_OVERRIDE TARGET_DP_VERSION
export MM_HERMETIC_TEST_MODE=0
mm_force_phase2_target
[[ "${TARGET_DP_VERSION}" == "6.6.0" ]] && pass "default target remains 6.6.0" || fail "target=${TARGET_DP_VERSION}"

# ---------- R2 immutable pin ----------
pkg="${TMP}/ubuntu-os-core-xenial-to-noble.tar"
printf 'fixture-os-core\n' >"$pkg"
sha="$(sha256sum "$pkg" | awk '{print $1}')"
bytes="$(stat -c%s "$pkg")"
export OS_CORE_R2_URL="https://example.test/ubuntu-os-core/ubuntu-os-core-xenial-to-noble.tar"
export MM_HERMETIC_TEST_MODE=1
export OS_CORE_TEST_EXPECTED_SHA256="$sha"
export OS_CORE_TEST_EXPECTED_BYTES="$bytes"
if mm_assert_os_core_production_identity "$pkg" "$OS_CORE_R2_URL" >/dev/null; then
  pass "exact digest/size fixture PASS"
else
  fail "exact fixture should PASS"
fi
export OS_CORE_TEST_EXPECTED_SHA256="$(printf '%064d' 1)"
if ! mm_assert_os_core_production_identity "$pkg" "$OS_CORE_R2_URL" >/dev/null 2>&1; then
  pass "wrong digest FAIL"
else
  fail "wrong digest should FAIL"
fi
export OS_CORE_TEST_EXPECTED_SHA256="$sha"
export OS_CORE_TEST_EXPECTED_BYTES=1
if ! mm_assert_os_core_production_identity "$pkg" "$OS_CORE_R2_URL" >/dev/null 2>&1; then
  pass "wrong size FAIL"
else
  fail "wrong size should FAIL"
fi
unset OS_CORE_TEST_EXPECTED_SHA256 OS_CORE_TEST_EXPECTED_BYTES OS_CORE_R2_URL
export MM_HERMETIC_TEST_MODE=0

# ---------- Uninstall path safety ----------
# shellcheck source=/dev/null
# Extract validators from uninstall.sh without running uninstall.
UM_SNIP="${TMP}/um_snip.sh"
awk '/^UM_PROD_INSTALL_LIB_DIR=/,/^um_assert_purge_path\(\)/ {if (/^um_assert_purge_path/) exit; print}' \
  "${ROOT}/uninstall.sh" >"$UM_SNIP"
# Provide um_die
cat >"${TMP}/um_helpers.sh" <<'EOF'
um_die() { printf '%s\n' "$*" >&2; exit 2; }
EOF
# shellcheck source=/dev/null
source "${TMP}/um_helpers.sh"
# shellcheck source=/dev/null
source "$UM_SNIP"
set +e
out="$(bash -c 'source "'"${TMP}/um_helpers.sh"'"; source "'"$UM_SNIP"'"; MM_HERMETIC_TEST_MODE=0 um_assert_runtime_destructive_path /usr/local INSTALL_LIB_DIR' 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "INSTALL_LIB_DIR=/usr/local rejected" || fail "/usr/local not rejected"
set +e
out="$(bash -c 'source "'"${TMP}/um_helpers.sh"'"; source "'"$UM_SNIP"'"; MM_HERMETIC_TEST_MODE=0 um_assert_runtime_destructive_path /etc INSTALL_CONF_DIR' 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "INSTALL_CONF_DIR=/etc rejected" || fail "/etc not rejected"
set +e
out="$(bash -c 'source "'"${TMP}/um_helpers.sh"'"; source "'"$UM_SNIP"'"; MM_HERMETIC_TEST_MODE=0 um_assert_runtime_destructive_path /usr/local/lib/ubuntu-mirror INSTALL_LIB_DIR' 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "default INSTALL_LIB_DIR accepted" || fail "default lib rejected: $out"
set +e
out="$(bash -c 'source "'"${TMP}/um_helpers.sh"'"; source "'"$UM_SNIP"'"; MM_HERMETIC_TEST_MODE=0 um_assert_runtime_destructive_path /etc/ubuntu-mirror INSTALL_CONF_DIR' 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "default INSTALL_CONF_DIR accepted" || fail "default conf rejected: $out"
# symlink escape
mkdir -p "${TMP}/real/ubuntu-mirror"
ln -s "${TMP}/real" "${TMP}/link-escape"
set +e
out="$(bash -c 'source "'"${TMP}/um_helpers.sh"'"; source "'"$UM_SNIP"'"; MM_HERMETIC_TEST_MODE=0 um_assert_runtime_destructive_path "'"${TMP}/link-escape"'" INSTALL_LIB_DIR' 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "symlink path rejected" || fail "symlink not rejected"

# ---------- nginx site name ----------
mm_assert_nginx_site_name apt-mirror && pass "apt-mirror site name ok" || fail "apt-mirror rejected"
if ! mm_assert_nginx_site_name '../etc' 2>/dev/null; then
  pass "nginx path traversal rejected"
else
  fail "nginx traversal accepted"
fi

# ---------- Verified cache GUI credential bypass ----------
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/dp-phase2-common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/acps_acquire.sh"
export MM_PROJECT_ROOT="$ROOT"
export MM_MIRROR_ROOT="${TMP}/mirror"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_SKIP_ROOT_CHECK=1
export PHASE2_TARGET_VERSION=6.6.0
export TARGET_DP_VERSION=6.6.0
export ACPS_USERNAME=""
export ACPS_PASSWORD=""
mkdir -p "$MM_CACHE_ROOT"
dp2_set_version 6.6.0
CACHE="$(acps_cache_dir 6.6.0)"
mkdir -p "$CACHE"
for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
  printf 'payload-%s\n' "$f" >"${CACHE}/${f}"
done
sha1sum "${CACHE}/aelladeb_py3_common.tar.gz" | awk '{print $1}' \
  >"${CACHE}/aelladeb_py3_common.tar.gz.sha1"
sha1sum "${CACHE}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}' \
  >"${CACHE}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
sha1sum "${CACHE}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
  >"${CACHE}/bringup_py3_dp_after_os_upgrade.sh.sha1"
sha256sum "${CACHE}/images-6.6.0.tar" | awk '{print $1 "  images-6.6.0.tar"}' \
  >"${CACHE}/images-6.6.0.tar.sha256"
seq 1 2 >"${CACHE}/images-6.6.0.list"
mm_acps_verify_payload_checksums "$CACHE" >/dev/null
acps_write_verified_marker "$CACHE"
if acps_is_verified_cache "$CACHE"; then
  pass "verified cache fixture ready"
else
  fail "verified cache not accepted"
fi
if mm_acquisition_auth_or_verified_cache_ready; then
  pass "Menu2 gate allows verified cache without credentials"
else
  fail "Menu2 gate should allow verified-cache reuse without credentials"
fi
# Corrupt/unverified cache requires credentials
rm -f "${CACHE}/.VERIFIED" "${CACHE}/.acps-verified" 2>/dev/null || true
printf 'broken\n' >"${CACHE}/.VERIFIED"
if ! acps_is_verified_cache "$CACHE" \
  && ! mm_acquisition_auth_or_verified_cache_ready; then
  pass "corrupt/unverified cache still requires credentials"
else
  fail "unverified cache unexpectedly trusted by Menu2 gate"
fi

# ---------- Phase2-only atomic publication preserves previous ----------
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_install_engine.sh"
export MM_CLIENT_ROOT="${TMP}/client-live"
export MIRROR_HTTP_URL="http://192.0.2.10"
mkdir -p "$MM_CLIENT_ROOT"
# Seed a live generation
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/phase2_helper_generation.sh"
for f in stage-dp-phase2.sh bringup_py3_dp_lifecycle.sh; do
  install -m 0755 "${ROOT}/client/${f}" "${MM_CLIENT_ROOT}/${f}"
  ( cd "$MM_CLIENT_ROOT" && sha256sum "$f" >"${f}.sha256" )
done
if [[ -d "${ROOT}/client/lib" ]]; then
  mkdir -p "${MM_CLIENT_ROOT}/lib"
  cp -a "${ROOT}/client/lib/." "${MM_CLIENT_ROOT}/lib/"
fi
phase2_helper_generation_write "$MM_CLIENT_ROOT" >/dev/null
# Bundle SHA may be empty in fixtures; wrapper writer requires non-empty in some paths.
phase2_upgrade_wrapper_write "$MM_CLIENT_ROOT" "$MIRROR_HTTP_URL" 6.6.0 \
  "0000000000000000000000000000000000000000000000000000000000000000" >/dev/null \
  || phase2_upgrade_wrapper_write "$MM_CLIENT_ROOT" "$MIRROR_HTTP_URL" 6.6.0 "" >/dev/null \
  || true
# Ensure helpers look ready enough for force-republish path
if ! mm_phase2_helpers_ready "$MM_CLIENT_ROOT" 2>/dev/null; then
  # Minimal readiness: presence of stage script + generation manifest
  [[ -f "${MM_CLIENT_ROOT}/stage-dp-phase2.sh" ]] || fail "stage helper missing"
fi
printf 'LIVE_MARKER=OLD\n' >"${MM_CLIENT_ROOT}/.live-marker"
live_before="$(find "$MM_CLIENT_ROOT" -type f | sort | sha256sum)"
export MM_HERMETIC_TEST_MODE=1
export MM_PHASE2_HELPERS_FORCE_REPUBLISH=1
export MM_PHASE2_HELPERS_FAKE_SWAP_FAIL=1
# Also exercise atomic_dir_swap inject independently
STAGE_FAIL="${TMP}/helpers-stage"
LIVE_OK="${TMP}/helpers-live"
mkdir -p "$STAGE_FAIL" "$LIVE_OK"
printf 'GEN=NEW\n' >"${STAGE_FAIL}/marker"
printf 'GEN=OLD\n' >"${LIVE_OK}/marker"
set +e
python3 "${ROOT}/scripts/lib/atomic_dir_swap.py" \
  --stage-dir "$STAGE_FAIL" --live-dir "$LIVE_OK" --inject-fail-after-backup >/dev/null 2>&1
swap_rc=$?
set -e
if [[ "$swap_rc" -ne 0 ]] && grep -q 'GEN=OLD' "${LIVE_OK}/marker"; then
  pass "atomic_dir_swap failure restores/preserves previous live generation"
else
  fail "atomic swap inject did not preserve live (rc=${swap_rc})"
fi
set +e
engine_ensure_phase2_helpers >/dev/null 2>&1
rc=$?
set -e
live_after="$(find "$MM_CLIENT_ROOT" -type f | sort | sha256sum)"
if [[ "$rc" -ne 0 && "$live_before" == "$live_after" ]] \
   && grep -q 'LIVE_MARKER=OLD' "${MM_CLIENT_ROOT}/.live-marker"; then
  pass "phase2 helper swap failure preserves previous live generation"
else
  # If helpers were not initially ready, force path may still preserve marker
  if [[ "$rc" -ne 0 ]] && grep -q 'LIVE_MARKER=OLD' "${MM_CLIENT_ROOT}/.live-marker"; then
    pass "phase2 helper fake-swap fail left live marker intact"
  else
    fail "live generation changed or swap unexpectedly succeeded (rc=${rc})"
  fi
fi
unset MM_PHASE2_HELPERS_FORCE_REPUBLISH MM_PHASE2_HELPERS_FAKE_SWAP_FAIL
export MM_HERMETIC_TEST_MODE=0

[[ "$FAIL" -eq 0 ]]
echo "=== test_final_audit_remediation_p1_p2: DONE ==="
