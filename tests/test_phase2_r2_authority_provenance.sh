#!/usr/bin/env bash
# Phase 2 R2 release-identity binding, manifest hard-pin, redirect authority,
# and Phase 1 production URL binding (pre-E2E closure).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

export MM_PROJECT_ROOT="$ROOT"
export MM_HERMETIC_TEST_MODE=1
export MM_MIRROR_ROOT="${TMP}/mirror"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_SELECTIVE_ROOT="${MM_MIRROR_ROOT}/selective"
export MM_STATE_DIR="${TMP}/state"
export MM_LOG_DIR="${TMP}/logs"
export MM_CONFIG_DIR="${TMP}/config"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/config"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_SKIP_ROOT_CHECK=1
mkdir -p "$MM_CACHE_ROOT" "$MM_STATE_DIR" "$MM_CONFIG_DIR" "$MM_LOG_DIR" \
  "$MM_DP_PHASE2_ROOT" "$MM_SELECTIVE_ROOT"
: >"$MM_STATUS_FILE"

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/dp-phase2-common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/acps_acquire.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_install_engine.sh"

dp2_set_version 6.6.0

[[ "${PHASE2_R2_MANIFEST_SHA256}" == "606e2967652ad4d0f0bfad4a23b562217a062ea17ccb54c47d2a5ea8bdf7c898" ]] \
  || fail "manifest hard-pin constant missing/wrong"
[[ "${PHASE2_R2_MANIFEST_BYTES}" == "956" ]] \
  || fail "manifest bytes hard-pin missing/wrong"
pass "manifest hard-pin constants present"

# --- release.env identity classification ---
ENVF="${TMP}/release.env"
cat >"$ENVF" <<EOF
TARGET_DP_VERSION=6.6.0
PHASE2_ARTIFACT_VERSION=6.6.0
SOURCE_HOST=acps
SOURCE_PATH=provision
ACPS_SOURCE_VERSION=6.6.0
STABLE_BUNDLE_NAME=$(dp2_stable_bundle_name)
EOF
reason="$(phase2_release_env_r2_identity_reason "$ENVF" || true)"
[[ "$reason" == "r2_release_identity_missing" ]] \
  || fail "old ACPS final reason want=r2_release_identity_missing got=${reason}"
pass "A: old ACPS final lacks R2 identity"

cat >"$ENVF" <<EOF
PHASE2_SOURCE=R2
SOURCE_HOST=downloads.xdr.ooo
SOURCE_PATH=/dp-os-upgrade/phase2/6.6.0/validated-20260919
PHASE2_R2_VALIDATED_RELEASE_ID=some-other-release
PHASE2_R2_MANIFEST_SHA256=${PHASE2_R2_MANIFEST_SHA256}
EOF
reason="$(phase2_release_env_r2_identity_reason "$ENVF" || true)"
[[ "$reason" == "r2_release_identity_mismatch" ]] \
  || fail "wrong release id reason want=r2_release_identity_mismatch got=${reason}"
pass "B: wrong release id invalidates"

cat >"$ENVF" <<EOF
PHASE2_SOURCE=R2
SOURCE_HOST=downloads.xdr.ooo
SOURCE_PATH=/dp-os-upgrade/phase2/6.6.0/validated-20260919
PHASE2_R2_VALIDATED_RELEASE_ID=${PHASE2_R2_VALIDATED_RELEASE_ID}
PHASE2_R2_MANIFEST_SHA256=0000000000000000000000000000000000000000000000000000000000000000
EOF
reason="$(phase2_release_env_r2_identity_reason "$ENVF" || true)"
[[ "$reason" == "r2_manifest_identity_mismatch" ]] \
  || fail "wrong manifest id reason want=r2_manifest_identity_mismatch got=${reason}"
pass "C: wrong manifest id invalidates"

phase2_emit_r2_release_provenance >"$ENVF"
phase2_release_env_r2_identity_reason "$ENVF" \
  || fail "correct provenance should validate"
grep -Fxq 'PHASE2_SOURCE=R2' "$ENVF" || fail "provenance missing PHASE2_SOURCE"
grep -Fxq "PHASE2_R2_VALIDATED_RELEASE_ID=${PHASE2_R2_VALIDATED_RELEASE_ID}" "$ENVF" \
  || fail "provenance missing release id"
grep -Fxq "PHASE2_R2_MANIFEST_SHA256=${PHASE2_R2_MANIFEST_SHA256}" "$ENVF" \
  || fail "provenance missing manifest id"
grep -Fxq 'SOURCE_HOST=downloads.xdr.ooo' "$ENVF" || fail "provenance missing host"
pass "shared provenance emitter binds validated-20260919"

# --- verified cache format 1 vs 2 ---
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

# Legacy format-1 marker is accepted only in hermetic mode.
{
  printf 'ACPS_VERIFIED_FORMAT=1\n'
  printf 'VERIFIED_AT=2026-01-01T00:00:00Z\n'
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    fp="$(acps_file_metadata_fp "${CACHE}/${f}")"
    if acps_is_checksum_sidecar "$f"; then
      cid="$(acps_sidecar_checksum_id "${CACHE}/${f}")"
    else
      cid="$(acps_payload_checksum_id "$CACHE" "$f")"
    fi
    printf 'FILE path=%s fp=%s checksum_id=%s\n' "$f" "$fp" "$cid"
  done
} >"${CACHE}/.VERIFIED"
acps_is_verified_cache "$CACHE" \
  || fail "hermetic should accept legacy format-1"
export MM_HERMETIC_TEST_MODE=0
acps_is_verified_cache "$CACHE" \
  && fail "production must reject legacy format-1" || true
pass "D: legacy format-1 blocked in production"

export MM_HERMETIC_TEST_MODE=1
acps_write_verified_marker "$CACHE" || fail "write format-2 marker"
grep -q '^ACPS_VERIFIED_FORMAT=2$' "${CACHE}/.VERIFIED" || fail "expected format 2"
grep -Fxq "PHASE2_R2_VALIDATED_RELEASE_ID=${PHASE2_R2_VALIDATED_RELEASE_ID}" \
  "${CACHE}/.VERIFIED" || fail "marker missing release id"
grep -Fxq "PHASE2_R2_MANIFEST_SHA256=${PHASE2_R2_MANIFEST_SHA256}" \
  "${CACHE}/.VERIFIED" || fail "marker missing manifest id"
grep -Fxq "PHASE2_R2_OBJECT_PREFIX=${PHASE2_R2_OBJECT_PREFIX_CONSTANT}" \
  "${CACHE}/.VERIFIED" || fail "marker missing object prefix"
export MM_HERMETIC_TEST_MODE=0
acps_is_verified_cache "$CACHE" \
  || fail "production must accept current format-2 identity-bound marker"
pass "E: current verified cache reusable in production"

# Wrong release id in format-2 marker
sed -i "s/PHASE2_R2_VALIDATED_RELEASE_ID=${PHASE2_R2_VALIDATED_RELEASE_ID}/PHASE2_R2_VALIDATED_RELEASE_ID=other/" \
  "${CACHE}/.VERIFIED"
acps_is_verified_cache "$CACHE" \
  && fail "wrong release id in marker must not reuse" || true
pass "verified cache wrong release id blocked"

# Restore correct marker
export MM_HERMETIC_TEST_MODE=1
acps_write_verified_marker "$CACHE" || fail "rewrite marker"

# --- manifest hard pin / tamper ---
MAN="${TMP}/manifest.sha256"
: >"$MAN"
(
  cd "$CACHE"
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    sha256sum "$f"
  done
) >"$MAN"
export PHASE2_R2_TEST_MANIFEST_SHA256="$(sha256sum "$MAN" | awk '{print $1}')"
export PHASE2_R2_TEST_MANIFEST_BYTES="$(stat -c%s "$MAN")"
phase2_verify_r2_manifest_identity "$MAN" >/dev/null \
  || fail "matching test manifest should PASS"
pass "hard-pinned manifest identity PASS path"

# F: change one byte of manifest
printf 'x' >>"$MAN"
set +e
mout="$(phase2_verify_r2_manifest_identity "$MAN" 2>&1)"
mrc=$?
set -e
[[ "$mrc" -ne 0 ]] && printf '%s' "$mout" | grep -q 'PHASE2_R2_MANIFEST_IDENTITY=FAIL' \
  && pass "F: manifest tamper fails closed" \
  || fail "manifest tamper did not fail (rc=${mrc} out=${mout})"

# G: artifact + matching modified manifest still fails production pin
export MM_HERMETIC_TEST_MODE=0
unset PHASE2_R2_TEST_MANIFEST_SHA256 PHASE2_R2_TEST_MANIFEST_BYTES
printf 'tampered-payload\n' >"${CACHE}/aelladeb_py3_common.tar.gz"
(
  cd "$CACHE"
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    sha256sum "$f"
  done
) >"$MAN"
set +e
mout="$(phase2_verify_r2_manifest_identity "$MAN" 2>&1)"
mrc=$?
set -e
[[ "$mrc" -ne 0 ]] && printf '%s' "$mout" | grep -qE 'sha256_mismatch|size_mismatch' \
  && pass "G: artifact+manifest tamper fails hard pin" \
  || fail "artifact+manifest tamper should fail pin (rc=${mrc} out=${mout})"

# --- Phase 1 production URL binding ---
export OS_CORE_R2_URL="https://example.invalid/foo.tar"
mm_bind_os_core_r2_url
[[ "${OS_CORE_R2_URL}" == "${OS_CORE_R2_URL_CONSTANT}" ]] \
  || fail "H: production must rebind OS_CORE_R2_URL to constant"
pass "H: production Phase1 URL override blocked"

export MM_HERMETIC_TEST_MODE=1
export OS_CORE_R2_URL="http://127.0.0.1:9/fixture.tar"
mm_bind_os_core_r2_url
[[ "${OS_CORE_R2_URL}" == "http://127.0.0.1:9/fixture.tar" ]] \
  || fail "hermetic OS_CORE_R2_URL override should remain"
pass "hermetic Phase1 URL override allowed"

# --- Phase 2 source override remains forbidden in production ---
export MM_HERMETIC_TEST_MODE=0
export DP_PHASE2_SOURCE_BASE="https://example.invalid/phase2"
set +e
err="$(acps_setup_curl_auth 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && printf '%s' "$err" | grep -q 'production_forbidden' \
  && pass "I: production DP_PHASE2_SOURCE_BASE rejected" \
  || fail "DP_PHASE2_SOURCE_BASE should be rejected (rc=${rc} err=${err})"
unset DP_PHASE2_SOURCE_BASE

# --- redirect authority (mock curl) ---
MOCK_BIN="${TMP}/bin"
mkdir -p "$MOCK_BIN"
cat >"${MOCK_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
# Emit a configured effective URL for -w '%{url_effective}' probes.
for a in "$@"; do
  if [[ "$a" == "%{url_effective}" || "$a" == *"url_effective"* ]]; then
    printf '%s' "${MOCK_EFFECTIVE_URL:-https://downloads.xdr.ooo/ok}"
    exit 0
  fi
done
# Fall through for other curl uses in this process — should not happen here.
exit 0
EOF
chmod +x "${MOCK_BIN}/curl"
export PATH="${MOCK_BIN}:${PATH}"

export MM_HERMETIC_TEST_MODE=0
export MOCK_EFFECTIVE_URL="https://acps.stellarcyber.ai/provision/aelladeb_py3/x"
set +e
out="$(phase2_assert_r2_effective_url "https://downloads.xdr.ooo/x" "t" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'R2_REDIRECT_AUTHORITY=FAIL' \
  && pass "J: redirect to ACPS blocked" \
  || fail "redirect to ACPS should FAIL (rc=${rc} out=${out})"

export MOCK_EFFECTIVE_URL="https://xdrsolutions.uk/ubuntu-os-core/x"
set +e
out="$(phase2_assert_r2_effective_url "https://downloads.xdr.ooo/x" "t" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'R2_REDIRECT_AUTHORITY=FAIL' \
  && pass "K: redirect to xdrsolutions.uk blocked" \
  || fail "redirect to xdrsolutions.uk should FAIL (rc=${rc} out=${out})"

export MOCK_EFFECTIVE_URL="https://evil.example/steal"
set +e
out="$(phase2_assert_r2_effective_url "https://downloads.xdr.ooo/x" "t" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'R2_REDIRECT_AUTHORITY=FAIL' \
  && pass "other host redirect blocked" \
  || fail "other host redirect should FAIL (rc=${rc} out=${out})"

export MOCK_EFFECTIVE_URL="https://downloads.xdr.ooo/dp-os-upgrade/phase2/6.6.0/validated-20260919/manifest.sha256"
phase2_assert_r2_effective_url "https://downloads.xdr.ooo/x" "t" >/dev/null \
  || fail "same-host effective URL should PASS"
pass "same-host redirect authority PASS"

# --- config save strips ACPS credentials ---
export MM_HERMETIC_TEST_MODE=1
export PATH="$(printf '%s' "$PATH" | sed "s|^${MOCK_BIN}:||")"
PREPARATION_MODE=FULL
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
WORKER_SSH_PASSWORD=""
DL_WORKER_IPS=""
DA_WORKER_IPS=""
ACPS_USERNAME=legacy
ACPS_PASSWORD=legacy-secret
mm_save_gui_config_full >/dev/null
grep -q 'ACPS_USERNAME\|ACPS_PASSWORD' "$MM_CONFIG_FILE" \
  && fail "saved config must not persist ACPS credentials" || true
[[ -z "${ACPS_USERNAME:-}" && -z "${ACPS_PASSWORD:-}" ]] \
  || fail "in-memory ACPS credentials should be cleared on save"
pass "production config save strips ACPS credentials"

echo "ALL PHASE2 R2 AUTHORITY/PROVENANCE TESTS PASSED"
