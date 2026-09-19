#!/usr/bin/env bash
# Production Phase 2 downloads the frozen R2 artifact set only.
# No ACPS runtime download, no R2→ACPS fallback, fail-closed integrity.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

R2_BASE='https://downloads.xdr.ooo/dp-os-upgrade/phase2/6.6.0/validated-20260919'
OS_CORE='https://downloads.xdr.ooo/ubuntu-os-core/ubuntu-os-core-xenial-to-noble.tar'
RUNTIME_SCRIPTS=(
  "${ROOT}/scripts/download-dp-phase2.sh"
  "${ROOT}/scripts/lib/acps_auth.sh"
  "${ROOT}/scripts/lib/acps_acquire.sh"
  "${ROOT}/scripts/lib/dp-phase2-common.sh"
  "${ROOT}/scripts/lib/mirror_install_engine.sh"
  "${ROOT}/scripts/lib/mirror_manager_common.sh"
  "${ROOT}/scripts/lib/r2_acquire.sh"
  "${ROOT}/scripts/install-dp-upgrade-mirror.sh"
  "${ROOT}/lib/bootstrap.sh"
)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MM_PROJECT_ROOT="$ROOT"
export MM_SKIP_ROOT_CHECK=1
export MM_MIRROR_ROOT="${TMP}/mirror"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_CONFIG_DIR="${TMP}/config"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/conf"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_LOG_DIR="${TMP}/logs"
export MM_STATE_ROOT="${TMP}/state"
mkdir -p "$MM_CACHE_ROOT" "$MM_DP_PHASE2_ROOT" "$MM_CONFIG_DIR" "$MM_LOG_DIR" "$MM_STATE_ROOT"
: >"$MM_STATUS_FILE"

# ---------------------------------------------------------------------------
# 1. Production Phase 2 resolves artifact URLs to the immutable R2 prefix
# ---------------------------------------------------------------------------
set +e
out="$(
  env -u DP_PHASE2_SOURCE_BASE -u ACPS_BASE_URL -u ACPS_BASE_URL_FIXED -u ACPS_HOST -u ACPS_PATH \
    MM_HERMETIC_TEST_MODE=0 \
    bash -c "
      source '${ROOT}/scripts/lib/dp-phase2-common.sh'
      source '${ROOT}/scripts/lib/acps_auth.sh'
      acps_setup_curl_auth
      printf 'BASE=%s\n' \"\$ACPS_EFFECTIVE_BASE\"
      printf 'R2=%s\n' \"\$PHASE2_R2_BASE_URL_CONSTANT\"
      printf 'RELEASE=%s\n' \"\$PHASE2_R2_VALIDATED_RELEASE_ID\"
      printf 'AUTH_N=%s\n' \"\${#ACPS_CURL_AUTH_ARGS[@]}\"
      phase2_production_source_base
      acps_cleanup_curl_auth
    " 2>&1
)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] \
  && printf '%s' "$out" | grep -qx "BASE=${R2_BASE}" \
  && printf '%s' "$out" | grep -qx "R2=${R2_BASE}" \
  && printf '%s' "$out" | grep -qx 'RELEASE=validated-20260919' \
  && printf '%s' "$out" | grep -qx 'AUTH_N=0' \
  && ! printf '%s' "$out" | grep -q 'acps.stellarcyber.ai' \
  && pass "production Phase 2 source is immutable R2 validated-20260919" \
  || fail "production source is not frozen R2 (rc=${rc} out=${out})"

# Env cannot retarget the frozen prefix.
set +e
out="$(
  env MM_HERMETIC_TEST_MODE=0 \
    PHASE2_R2_BASE_URL_CONSTANT='https://evil.example/latest' \
    ACPS_PRODUCTION_BASE_URL='https://acps.stellarcyber.ai/provision/aelladeb_py3' \
    bash -c "
      source '${ROOT}/scripts/lib/acps_auth.sh'
      acps_setup_curl_auth
      printf 'BASE=%s\n' \"\$ACPS_EFFECTIVE_BASE\"
      acps_cleanup_curl_auth
    " 2>&1
)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] \
  && printf '%s' "$out" | grep -qx "BASE=${R2_BASE}" \
  && ! printf '%s' "$out" | grep -q 'evil.example' \
  && ! printf '%s' "$out" | grep -q 'latest' \
  && pass "production ignores env R2/latest override" \
  || fail "env override retargeted production R2 (rc=${rc} out=${out})"

# ---------------------------------------------------------------------------
# 2. No normal Phase 2 runtime path resolves to ACPS
# ---------------------------------------------------------------------------
runtime_acps_download_assigns=0
for f in "${RUNTIME_SCRIPTS[@]}"; do
  hits="$(
    grep -nE 'ACPS_EFFECTIVE_BASE="https://acps\.stellarcyber\.ai|url="https://acps\.stellarcyber\.ai|PHASE2_R2_BASE_URL_CONSTANT="https://acps\.stellarcyber' "$f" \
      || true
  )"
  if [[ -n "$hits" ]]; then
    runtime_acps_download_assigns=$((runtime_acps_download_assigns + 1))
    fail "runtime download URL assignment to ACPS in ${f}: ${hits}"
  fi
done
[[ "$runtime_acps_download_assigns" -eq 0 ]] \
  && pass "no runtime download URL assignment to ACPS" \
  || true

# Hermetic-only ACPS host default must remain behind MM_HERMETIC_TEST_MODE.
hermetic_guard="$(
  awk '
    /_acps_hermetic_test_mode/ {h=1}
    h && /ACPS_HOST:-acps\.stellarcyber\.ai/ {found=1}
    END { if (found) print "HERMETIC_ONLY"; else print "MISSING_OR_UNGUARDED" }
  ' "${ROOT}/scripts/lib/acps_auth.sh"
)"
[[ "$hermetic_guard" == "HERMETIC_ONLY" ]] \
  && pass "ACPS host default is hermetic-fixture only" \
  || fail "ACPS host default not confined to hermetic fixture (${hermetic_guard})"

for f in "${RUNTIME_SCRIPTS[@]}"; do
  grep -q 'acps_runtime_forbidden' "$f" || continue
  pass "ACPS runtime reject present in $(basename "$f")"
done

# ---------------------------------------------------------------------------
# 3–5. Missing R2 artifact / checksum mismatch / missing required file fail closed
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/dp-phase2-common.sh"
dp2_set_version 6.6.0

FILES="${TMP}/files"
mkdir -p "$FILES"
for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
  printf 'payload-%s\n' "$f" >"${FILES}/${f}"
done
sha1sum "${FILES}/aelladeb_py3_common.tar.gz" | awk '{print $1}' \
  >"${FILES}/aelladeb_py3_common.tar.gz.sha1"
sha1sum "${FILES}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}' \
  >"${FILES}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
sha1sum "${FILES}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
  >"${FILES}/bringup_py3_dp_after_os_upgrade.sh.sha1"
sha256sum "${FILES}/images-6.6.0.tar" | awk '{print $1 "  images-6.6.0.tar"}' \
  >"${FILES}/images-6.6.0.tar.sha256"
seq 1 2 >"${FILES}/images-6.6.0.list"

MAN="${TMP}/manifest.sha256"
: >"$MAN"
(
  cd "$FILES"
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    sha256sum "$f"
  done
) >"$MAN"

set +e
mout="$(phase2_verify_r2_manifest "$FILES" "$MAN" 2>&1)"
mrc=$?
set -e
[[ "$mrc" -eq 0 ]] && printf '%s' "$mout" | grep -q 'PHASE2_R2_MANIFEST=PASS' \
  && pass "matching frozen R2 manifest verifies" \
  || fail "matching R2 manifest should PASS (rc=${mrc} out=${mout})"

# Missing R2 manifest
set +e
mout="$(phase2_verify_r2_manifest "$FILES" "${TMP}/no-such-manifest" 2>&1)"
mrc=$?
set -e
[[ "$mrc" -ne 0 ]] && printf '%s' "$mout" | grep -q 'PHASE2_R2_MANIFEST=FAIL' \
  && pass "missing R2 manifest fails closed" \
  || fail "missing R2 manifest did not fail closed (rc=${mrc})"

# SHA256 mismatch in frozen manifest
awk 'NR==1 {$1="0000000000000000000000000000000000000000000000000000000000000000"} {print}' \
  "$MAN" >"${TMP}/manifest-bad.sha256"
set +e
mout="$(phase2_verify_r2_manifest "$FILES" "${TMP}/manifest-bad.sha256" 2>&1)"
mrc=$?
set -e
[[ "$mrc" -ne 0 ]] && printf '%s' "$mout" | grep -q 'PHASE2_R2_MANIFEST=FAIL' \
  && pass "R2 SHA256 mismatch fails closed" \
  || fail "R2 SHA256 mismatch did not fail closed (rc=${mrc} out=${mout})"

# Vendor sidecar mismatch
printf '0000000000000000000000000000000000000000\n' \
  >"${FILES}/aelladeb_py3_common.tar.gz.sha1"
set +e
mout="$(dp2_verify_payload_checksums "$FILES" 2>&1)"
mrc=$?
set -e
[[ "$mrc" -ne 0 ]] && printf '%s' "$mout" | grep -q 'SHA1_VERIFY=FAIL' \
  && pass "vendor checksum mismatch fails closed" \
  || fail "vendor checksum mismatch did not fail closed (rc=${mrc} out=${mout})"
sha1sum "${FILES}/aelladeb_py3_common.tar.gz" | awk '{print $1}' \
  >"${FILES}/aelladeb_py3_common.tar.gz.sha1"

# Missing required artifact
rm -f "${FILES}/images-6.6.0.tar"
set +e
mout="$(dp2_assert_exact_files_dir "$FILES" 2>&1)"
mrc=$?
set -e
[[ "$mrc" -ne 0 ]] && printf '%s' "$mout" | grep -qE 'REQUIRED_FILE_MISSING=FAIL|FILE_SET=FAIL' \
  && pass "missing required artifact fails closed" \
  || fail "missing required artifact did not fail closed (rc=${mrc} out=${mout})"
printf 'payload-images-6.6.0.tar\n' >"${FILES}/images-6.6.0.tar"
sha256sum "${FILES}/images-6.6.0.tar" | awk '{print $1 "  images-6.6.0.tar"}' \
  >"${FILES}/images-6.6.0.tar.sha256"

# Production identity pin fails closed on a non-frozen bringup.
export MM_HERMETIC_TEST_MODE=0
set +e
mout="$(phase2_verify_r2_frozen_identity "$FILES" 2>&1)"
mrc=$?
set -e
[[ "$mrc" -ne 0 ]] && printf '%s' "$mout" | grep -q 'PHASE2_R2_BRINGUP_IDENTITY=FAIL' \
  && pass "non-frozen bringup identity fails closed" \
  || fail "identity pin did not fail closed (rc=${mrc} out=${mout})"
export MM_HERMETIC_TEST_MODE=1

# Mocked production download of a missing R2 object fails closed and records the R2 URL.
mkdir -p "${TMP}/bin"
CURL_LOG="${TMP}/curl.log"
export CURL_LOG
cat >"${TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
: "${CURL_LOG:?}"
printf '%s\n' "$*" >>"$CURL_LOG"
exit 22
EOF
chmod +x "${TMP}/bin/curl"
export PATH="${TMP}/bin:${PATH}"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/acps_acquire.sh"
export MM_HERMETIC_TEST_MODE=1
export DP_PHASE2_SOURCE_BASE="${R2_BASE}"
unset ACPS_EFFECTIVE_BASE || true
acps_setup_curl_auth
set +e
dout="$(acps_download_one 'images-6.6.0.tar' "${TMP}/dl" 2>&1)"
drc=$?
set -e
[[ "$drc" -ne 0 ]] \
  && grep -q "${R2_BASE}/images-6.6.0.tar" "$CURL_LOG" \
  && ! grep -q 'acps.stellarcyber.ai' "$CURL_LOG" \
  && pass "missing R2 object download fails closed without ACPS" \
  || fail "missing R2 download did not fail closed (rc=${drc} out=${dout} log=$(cat "$CURL_LOG"))"
acps_cleanup_curl_auth
unset DP_PHASE2_SOURCE_BASE

# Production reject if a download URL is somehow ACPS.
export MM_HERMETIC_TEST_MODE=0
ACPS_EFFECTIVE_BASE='https://acps.stellarcyber.ai/provision/aelladeb_py3'
set +e
dout="$(acps_download_one 'images-6.6.0.tar' "${TMP}/dl-acps" 2>&1)"
drc=$?
set -e
[[ "$drc" -ne 0 ]] && printf '%s' "$dout" | grep -q 'acps_runtime_forbidden' \
  && pass "production ACPS download URL is rejected" \
  || fail "ACPS download URL was not rejected (rc=${drc} out=${dout})"
export MM_HERMETIC_TEST_MODE=1
unset ACPS_EFFECTIVE_BASE || true

# ---------------------------------------------------------------------------
# 6. --skip-download / verified local staging performs no R2/ACPS download
# ---------------------------------------------------------------------------
BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
grep -q -- '--skip-download' "$BRINGUP" \
  && pass "bringup --skip-download remains" \
  || fail "bringup --skip-download missing"
grep -q 'Skipping download (--skip-download)' "$BRINGUP" \
  && pass "bringup skip-download does not download" \
  || fail "bringup skip-download log missing"
grep -q 'ACPS_DIRECT_DOWNLOAD=FAIL' "$BRINGUP" \
  && pass "bringup ACPS direct download remains fail-closed" \
  || fail "bringup ACPS fail-closed missing"

STAGE="${ROOT}/client/stage-dp-phase2.sh"
grep -q 'Refusing ACPS/external stellarcyber URL' "$STAGE" \
  && pass "DP stager rejects ACPS as mirror URL" \
  || fail "DP stager ACPS reject missing"

# Verified cache reuse: blocked curl must not be invoked.
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
: >"$CURL_LOG"
set +e
aout="$(acps_acquire_all 6.6.0 2>&1)"
arc=$?
set -e
[[ "$arc" -eq 0 ]] && printf '%s' "$aout" | grep -q 'ACPS_DOWNLOAD=REUSED' \
  && [[ ! -s "$CURL_LOG" ]] \
  && pass "verified local staging performs no R2/ACPS download" \
  || fail "verified cache reuse downloaded (rc=${arc} out=${aout} curl=$(cat "$CURL_LOG"))"

# ---------------------------------------------------------------------------
# 7. Phase 1 Ubuntu OS Core behavior is unchanged (hostname-only R2 domain)
# ---------------------------------------------------------------------------
grep -q "OS_CORE_R2_URL_CONSTANT=\"${OS_CORE}\"" \
  "${ROOT}/scripts/lib/mirror_manager_common.sh" \
  && pass "Phase 1 OS Core R2 URL is downloads.xdr.ooo" \
  || fail "Phase 1 OS Core R2 URL changed"

# Retired R2 hostname must not remain in production runtime or as a fallback.
old_domain_hits=0
for f in "${RUNTIME_SCRIPTS[@]}"; do
  hits="$(grep -n 'xdrsolutions\.uk' "$f" || true)"
  if [[ -n "$hits" ]]; then
    old_domain_hits=$((old_domain_hits + 1))
    fail "production runtime still references xdrsolutions.uk in ${f}: ${hits}"
  fi
done
[[ "$old_domain_hits" -eq 0 ]] \
  && pass "production runtime has no xdrsolutions.uk reference" \
  || true
grep -q 'https://downloads.xdr.ooo/' "${ROOT}/lib/bootstrap.sh" \
  && grep -q 'OUTBOUND_HTTPS=PASS downloads.xdr.ooo' "${ROOT}/lib/bootstrap.sh" \
  && ! grep -q 'xdrsolutions.uk' "${ROOT}/lib/bootstrap.sh" \
  && pass "bootstrap outbound HTTPS checks downloads.xdr.ooo only" \
  || fail "bootstrap still depends on xdrsolutions.uk"
! grep -nE 'xdrsolutions\.uk|xdrsolutions\.uk/' \
  "${ROOT}/scripts/lib/acps_auth.sh" \
  "${ROOT}/scripts/lib/dp-phase2-common.sh" \
  "${ROOT}/scripts/lib/mirror_manager_common.sh" \
  "${ROOT}/scripts/lib/acps_acquire.sh" \
  "${ROOT}/scripts/lib/r2_acquire.sh" \
  && pass "no old-domain fallback in production download source" \
  || fail "old-domain fallback present"
! grep -q 'dp-os-upgrade/phase2' "${ROOT}/scripts/lib/r2_acquire.sh" \
  && pass "OS Core downloader does not use Phase 2 prefix" \
  || fail "OS Core downloader mixed with Phase 2 prefix"
grep -q 'OS_CORE_SOURCE=R2' "${ROOT}/scripts/lib/mirror_manager_common.sh" \
  && pass "Phase 1 source remains R2" \
  || fail "Phase 1 OS_CORE_SOURCE missing"

# ---------------------------------------------------------------------------
# 8. Supported DP version behavior is unchanged
# ---------------------------------------------------------------------------
grep -q 'PHASE2_TARGET_VERSION_FIXED="6.6.0"' \
  "${ROOT}/scripts/lib/mirror_manager_common.sh" \
  && pass "Phase 2 target remains 6.6.0" \
  || fail "Phase 2 target version changed"
dp2_set_version 6.6.0
[[ "${#DP_PHASE2_REQUIRED_FILES[@]}" -eq 9 ]] \
  && pass "Phase 2 required file count remains 9" \
  || fail "required file count=${#DP_PHASE2_REQUIRED_FILES[@]}"
printf '%s\n' "${DP_PHASE2_REQUIRED_FILES[@]}" | grep -qx 'images-6.6.0.tar' \
  && printf '%s\n' "${DP_PHASE2_REQUIRED_FILES[@]}" | grep -qx 'aella-uvp-2404_6.6.0ubuntu1_amd64.deb' \
  && ! printf '%s\n' "${DP_PHASE2_REQUIRED_FILES[@]}" | grep -q '6.5.0' \
  && pass "6.6.0 artifact names unchanged" \
  || fail "6.6.0 required file set changed"

# Frozen identity constants match the validated freeze.
[[ "${PHASE2_R2_BRINGUP_SHA256}" == "6a69ff8671a1bd396efb4d103314cd5d347003fbda957e49a20c99fb5957e622" ]] \
  && [[ "${PHASE2_R2_IMAGES_SHA256}" == "91cf6a2c4de178b616d539e0c22817bf86952ae6020a14f248d32efe9f453fe0" ]] \
  && [[ "${PHASE2_R2_IMAGES_BYTES}" == "29579332096" ]] \
  && pass "frozen R2 identity pins match validated-20260919" \
  || fail "frozen identity pins drifted"

echo "PHASE2_RUNTIME_ACPS_REFERENCE_COUNT=${runtime_acps_download_assigns}"
echo "SUMMARY fail=${FAIL}"
exit "$FAIL"
