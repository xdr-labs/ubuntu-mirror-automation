#!/usr/bin/env bash
# Phase 2 prerequisite extract: no SIGPIPE false-negative, fail-closed
# missing/ambiguous/corrupt archives, wrapper diagnostics, VALID-final reuse.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/phase2_prereq_fixture.sh
source "${ROOT}/tests/lib/phase2_prereq_fixture.sh"
# shellcheck source=lib/seed_complete_client_http_set.sh
source "${ROOT}/tests/lib/seed_complete_client_http_set.sh"

PREPARE="${ROOT}/scripts/prepare-phase2-ubuntu-prerequisites.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
DP2="${ROOT}/scripts/lib/dp-phase2-common.sh"
ACPS="${ROOT}/scripts/lib/acps_acquire.sh"
R2="${ROOT}/scripts/lib/r2_acquire.sh"
PATCHED_BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"

FAIL=0
PASS=0
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "======== test_phase2_prereq_extract_sigpipe ========"

bash -n "$PREPARE" && pass "bash -n prepare script" || fail "bash -n prepare script"
bash -n "$ENGINE" && pass "bash -n engine" || fail "bash -n engine"

if grep -nE 'tar[[:space:]]+-tzf.*\|[[:space:]]*grep[[:space:]]+-q|grep[[:space:]]+.*py3-apt-packages.*\|[[:space:]]*head' \
  "$PREPARE"
then
  fail "prepare script still uses early-exit tar listing consumers"
else
  pass "prepare script has no grep -q / head after tar -t"
fi

write_inner_py3() {
  local dest="$1"
  local inner="${WORKDIR}/inner-$$"
  rm -rf "$inner"
  mkdir -p "$inner"
  printf 'payload-ok\n' >"${inner}/marker.txt"
  tar -czf "$dest" -C "$inner" marker.txt
  rm -rf "$inner"
}

write_tiny_uvp_deb() {
  local dest="$1"
  local pkg_work="${WORKDIR}/tiny-uvp-$$"
  rm -rf "$pkg_work"
  mkdir -p "${pkg_work}/DEBIAN"
  cat >"${pkg_work}/DEBIAN/control" <<'EOF'
Package: aella-uvp-2404
Version: 6.6.0ubuntu1
Architecture: amd64
Maintainer: fixture@example.com
Description: hermetic UVP fixture
EOF
  mkdir -p "$(dirname "$dest")"
  dpkg-deb -Zgzip --build "$pkg_work" "$dest" >/dev/null
  rm -rf "$pkg_work"
}

write_large_early_member_common() {
  local dest="$1"
  local pad_count="${2:-4000}"
  python3 - "$dest" "$pad_count" <<'PY'
import os, sys, tarfile, tempfile
dest, pad_count = sys.argv[1], int(sys.argv[2])
os.makedirs(os.path.dirname(dest) or '.', exist_ok=True)
work = tempfile.mkdtemp(prefix='phase2-large-common-')
inner = os.path.join(work, 'py3-apt-packages.tar.gz')
with tarfile.open(inner, 'w:gz') as tf:
    info = tarfile.TarInfo('marker.txt')
    data = b'payload-ok\n'
    info.size = len(data)
    tf.addfile(info, fileobj=__import__('io').BytesIO(data))
with tarfile.open(dest, 'w:gz') as tf:
    tf.add(inner, arcname='py3-apt-packages.tar.gz')
    pad = b'x' * 64
    for i in range(pad_count):
        info = tarfile.TarInfo('zz-pad-%05d.dat' % i)
        info.size = len(pad)
        tf.addfile(info, fileobj=__import__('io').BytesIO(pad))
PY
}

# ---------------------------------------------------------------------------
# A. Large archive, matching member early: helper succeeds, no rc=141
# ---------------------------------------------------------------------------
LARGE="${WORKDIR}/large-common.tar.gz"
write_large_early_member_common "$LARGE" 4000
MATCH_POS="$(tar -tzf "$LARGE" | grep -n 'py3-apt-packages.tar.gz$' | head -n1)"
echo "  INFO: large archive match=${MATCH_POS} members=$(tar -tzf "$LARGE" | wc -l)"

set +e
set -o pipefail
tar -tzf "$LARGE" | grep -q 'py3-apt-packages.tar.gz$'
OLD_Q_RC=$?
set +o pipefail
set -e
[[ "$OLD_Q_RC" -eq 141 ]] \
  && pass "A old tar|grep -q still SIGPIPE rc=141 (baseline)" \
  || fail "A expected old grep -q SIGPIPE 141 got=${OLD_Q_RC}"

EXTRACT_A="${WORKDIR}/extract-a"
set +e
A_OUT="$(
  set -euo pipefail
  # shellcheck source=/dev/null
  source "$PREPARE"
  dp2_extract_py3_apt_from_common "$LARGE" "$EXTRACT_A"
  echo EXTRACT_RC=$?
  if [[ -f "${EXTRACT_A}/py3-apt-packages.tar.gz" ]]; then
    echo EXTRACTED=YES
  else
    echo EXTRACTED=NO
  fi
)"
A_WRAP=$?
set -e
echo "$A_OUT" | grep -q 'EXTRACT_RC=0' \
  && echo "$A_OUT" | grep -q 'EXTRACTED=YES' \
  && [[ "$A_WRAP" -eq 0 ]] \
  && pass "A helper extracts early member from large archive" \
  || fail "A helper false-negative: wrap=${A_WRAP} out=${A_OUT}"
echo "$A_OUT" | grep -q 'EXTRACT_RC=141' \
  && fail "A helper returned rc=141" \
  || true

# ---------------------------------------------------------------------------
# B. Missing member → reason=py3_apt_missing
# ---------------------------------------------------------------------------
MISSING="${WORKDIR}/missing-common.tar.gz"
mkdir -p "${WORKDIR}/missing-src"
printf 'nope\n' >"${WORKDIR}/missing-src/readme.txt"
tar -czf "$MISSING" -C "${WORKDIR}/missing-src" readme.txt
NOBLE="${WORKDIR}/noble"
phase2_prereq_write_empty_noble_index "$NOBLE"
OUT_B="${WORKDIR}/out-b"
set +e
PHASE2_PREREQ_ACPS_COMMON="$MISSING" \
  PHASE2_PREREQ_INDEX_ROOT="$NOBLE" \
  PHASE2_PREREQ_OUT_DIR="${WORKDIR}/extras-b" \
  DP_PHASE2_VERSION=6.6.0 \
  bash "$PREPARE" 6.6.0 >"$OUT_B" 2>&1
B_RC=$?
set -e
[[ "$B_RC" -ne 0 ]] \
  && grep -q 'PHASE2_PREREQ=FAIL reason=py3_apt_missing' "$OUT_B" \
  && pass "B missing member reason=py3_apt_missing rc=${B_RC}" \
  || { echo "---- B ----"; cat "$OUT_B"; fail "B missing member"; }

# ---------------------------------------------------------------------------
# C. Multiple matching members → fail closed
# ---------------------------------------------------------------------------
MULTI="${WORKDIR}/multi-common.tar.gz"
mkdir -p "${WORKDIR}/multi-a" "${WORKDIR}/multi-b"
write_inner_py3 "${WORKDIR}/multi-a/py3-apt-packages.tar.gz"
write_inner_py3 "${WORKDIR}/multi-b/py3-apt-packages.tar.gz"
tar -czf "$MULTI" -C "${WORKDIR}" multi-a/py3-apt-packages.tar.gz multi-b/py3-apt-packages.tar.gz
OUT_C="${WORKDIR}/out-c"
set +e
PHASE2_PREREQ_ACPS_COMMON="$MULTI" \
  PHASE2_PREREQ_INDEX_ROOT="$NOBLE" \
  PHASE2_PREREQ_OUT_DIR="${WORKDIR}/extras-c" \
  DP_PHASE2_VERSION=6.6.0 \
  bash "$PREPARE" 6.6.0 >"$OUT_C" 2>&1
C_RC=$?
set -e
[[ "$C_RC" -ne 0 ]] \
  && grep -q 'PHASE2_PREREQ=FAIL reason=py3_apt_ambiguous' "$OUT_C" \
  && ! grep -q 'PHASE2_PREREQ=PASS' "$OUT_C" \
  && pass "C ambiguous members fail closed" \
  || { echo "---- C ----"; cat "$OUT_C"; fail "C ambiguous members"; }

# ---------------------------------------------------------------------------
# D. Corrupted common tar
# ---------------------------------------------------------------------------
CORRUPT="${WORKDIR}/corrupt-common.tar.gz"
printf 'this-is-not-gzip\n' >"$CORRUPT"
OUT_D="${WORKDIR}/out-d"
set +e
PHASE2_PREREQ_ACPS_COMMON="$CORRUPT" \
  PHASE2_PREREQ_INDEX_ROOT="$NOBLE" \
  PHASE2_PREREQ_OUT_DIR="${WORKDIR}/extras-d" \
  DP_PHASE2_VERSION=6.6.0 \
  bash "$PREPARE" 6.6.0 >"$OUT_D" 2>&1
D_RC=$?
set -e
[[ "$D_RC" -ne 0 ]] \
  && grep -qE 'PHASE2_PREREQ=FAIL reason=py3_apt_(archive_invalid|missing)' "$OUT_D" \
  && ! grep -q 'PHASE2_PREREQ=PASS' "$OUT_D" \
  && pass "D corrupt archive fail closed" \
  || { echo "---- D ----"; cat "$OUT_D"; fail "D corrupt archive"; }

# ---------------------------------------------------------------------------
# E. Production prepare path reaches Python resolver after extraction
# ---------------------------------------------------------------------------
GOOD="${WORKDIR}/good-common.tar.gz"
phase2_prereq_write_zero_extra_common "$GOOD" "hermetic-ok"
OUT_E="${WORKDIR}/out-e"
set +e
PHASE2_PREREQ_ACPS_COMMON="$GOOD" \
  PHASE2_PREREQ_INDEX_ROOT="$NOBLE" \
  PHASE2_PREREQ_OUT_DIR="${WORKDIR}/extras-e" \
  PHASE2_PREREQ_ARCHIVE_BASE="http://127.0.0.1:1/ubuntu" \
  PHASE2_PREREQ_SECURITY_BASE="http://127.0.0.1:1/ubuntu" \
  DP_PHASE2_VERSION=6.6.0 \
  bash "$PREPARE" 6.6.0 >"$OUT_E" 2>&1
E_RC=$?
set -e
[[ "$E_RC" -eq 0 ]] \
  && grep -q 'PHASE2_PREREQ=PASS' "$OUT_E" \
  && grep -qE 'PHASE2_PREREQ_(PACKAGE_COUNT|ROOTS|CLOSURE)=' "$OUT_E" \
  && [[ -f "${WORKDIR}/extras-e/phase2-ubuntu-prerequisites.state" ]] \
  && pass "E prepare script reaches Python resolver after extract" \
  || { echo "---- E ----"; cat "$OUT_E"; fail "E production prepare path"; }

# ---------------------------------------------------------------------------
# F. Engine wrapper surfaces child reason before generic rc
# ---------------------------------------------------------------------------
export MM_PROJECT_ROOT="$ROOT"
export MM_SKIP_ROOT_CHECK=1
export MM_MIRROR_ROOT="${WORKDIR}/mirror-f"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export MM_STATE_ROOT="${WORKDIR}/state-f"
export MM_STATE_DIR="${WORKDIR}/state-f/run"
export MM_LOG_DIR="${WORKDIR}/logs-f"
export MM_CONFIG_DIR="${WORKDIR}/config-f"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_SELECTIVE_ROOT="${MM_MIRROR_ROOT}/selective"
export MM_CLIENT_ROOT="${MM_MIRROR_ROOT}/client"
export MM_LOCK_FILE="${WORKDIR}/install-f.lock"
export TARGET_DP_VERSION=6.6.0
export PHASE2_TARGET_VERSION=6.6.0
export PREPARATION_MODE=PHASE2_ONLY
export SKIP_MIRROR_HOST_VALIDATE=1
mkdir -p "$MM_CLIENT_ROOT" "$MM_CACHE_ROOT" "$MM_DP_PHASE2_ROOT" "$MM_LOG_DIR" \
  "$MM_STATE_DIR" "$MM_CONFIG_DIR" \
  "${MM_SELECTIVE_ROOT}/hops/jammy-to-noble/ubuntu"
phase2_prereq_write_empty_noble_index \
  "${MM_SELECTIVE_ROOT}/hops/jammy-to-noble/ubuntu"
cat >"$MM_CONFIG_FILE" <<'EOF'
PREPARATION_MODE=PHASE2_ONLY
TARGET_DP_VERSION=6.6.0
ACPS_USERNAME=testuser
ACPS_PASSWORD=testpass
OS_CORE_R2_URL=http://127.0.0.1:9/os-core.tar
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
EOF
chmod 600 "$MM_CONFIG_FILE"

# shellcheck source=/dev/null
source "$COMMON"
# shellcheck source=/dev/null
source "$DP2"
# shellcheck source=/dev/null
source "$ACPS"
# shellcheck source=/dev/null
source "$R2"
# shellcheck source=/dev/null
source "$ENGINE"
mm_state_init 2>/dev/null || true
dp2_set_version 6.6.0

WORK_F="${WORKDIR}/work-f"
mkdir -p "$WORK_F"
cp -a "$MISSING" "${WORK_F}/aelladeb_py3_common.tar.gz"
OUT_F="${WORKDIR}/out-f"
set +e
( engine_prepare_phase2_ubuntu_prerequisites "$WORK_F" ) >"$OUT_F" 2>&1
F_RC=$?
set -e
REASON_LINE="$(grep -n 'reason=py3_apt_missing' "$OUT_F" | head -n1 | cut -d: -f1 || true)"
GENERIC_LINE="$(grep -n 'PHASE2_PREREQ_BUILD=FAIL rc=' "$OUT_F" | head -n1 | cut -d: -f1 || true)"
if [[ -n "$REASON_LINE" && -n "$GENERIC_LINE" && "$REASON_LINE" -lt "$GENERIC_LINE" ]] \
  && [[ "$F_RC" -ne 0 ]]
then
  pass "F child reason visible before generic wrapper rc"
else
  echo "---- F ----"
  cat "$OUT_F"
  fail "F wrapper diagnostics reason=${REASON_LINE} generic=${GENERIC_LINE} rc=${F_RC}"
fi

# ---------------------------------------------------------------------------
# G. VALID final + preserved prereq source: REUSE, no ACPS, no rebuild
# ---------------------------------------------------------------------------
export MM_MIRROR_ROOT="${WORKDIR}/mirror-g"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export MM_STATE_ROOT="${WORKDIR}/state-g"
export MM_STATE_DIR="${WORKDIR}/state-g/run"
export MM_LOG_DIR="${WORKDIR}/logs-g"
export MM_CONFIG_DIR="${WORKDIR}/config-g"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_SELECTIVE_ROOT="${MM_MIRROR_ROOT}/selective"
export MM_CLIENT_ROOT="${MM_MIRROR_ROOT}/client"
export MM_LOCK_FILE="${WORKDIR}/install-g.lock"
export MM_MOCK_AVAILABLE_BYTES=$((80 * 1024 * 1024 * 1024))
export MM_MOCK_FS_SIZE_BYTES=$((100 * 1000 * 1000 * 1000))
export MM_MOCK_SAFETY_RESERVE_BYTES=$((10 * 1024 * 1024 * 1024))
export OS_CORE_PACKAGE_BYTES=100
export OS_CORE_PAYLOAD_BYTES=200
export ACPS_EXPECTED_BYTES=300
export ACPS_USERNAME=testuser
export ACPS_PASSWORD=testpass
export OS_CORE_R2_URL='http://127.0.0.1:9/os-core.tar'
export PREPARATION_MODE=PHASE2_ONLY
mkdir -p "$MM_CLIENT_ROOT" "$MM_CACHE_ROOT" "$MM_DP_PHASE2_ROOT" "$MM_LOG_DIR" \
  "$MM_STATE_DIR" "$MM_CONFIG_DIR"
seed_complete_client_http_set "$MM_CLIENT_ROOT" "http://192.0.2.10" \
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
phase2_prereq_write_empty_noble_index \
  "${MM_SELECTIVE_ROOT}/hops/jammy-to-noble/ubuntu"
cat >"$MM_CONFIG_FILE" <<'EOF'
PREPARATION_MODE=PHASE2_ONLY
TARGET_DP_VERSION=6.6.0
ACPS_USERNAME=testuser
ACPS_PASSWORD=testpass
OS_CORE_R2_URL=http://127.0.0.1:9/os-core.tar
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
EOF
chmod 600 "$MM_CONFIG_FILE"

# Re-source engine in this env. Functions already defined; refresh paths via exports.
mm_state_init 2>/dev/null || true
dp2_set_version 6.6.0

make_acps_work_tree() {
  local work="$1"
  mkdir -p "$work"
  phase2_prereq_write_zero_extra_common "${work}/aelladeb_py3_common.tar.gz" "reuse-common"
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
  local work="${WORKDIR}/valid-work"
  local dest="${MM_DP_PHASE2_ROOT}/6.6.0"
  local stable="dp_bundle_6.6.0-current.tar"
  local patched_sha gen
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
}

COUNTERS="${WORKDIR}/counters"
mkdir -p "$COUNTERS"
reset_counters() {
  printf '0\n' >"${COUNTERS}/acps"
  printf '0\n' >"${COUNTERS}/place"
}
bump() {
  local f="${COUNTERS}/$1"
  local n
  n="$(cat "$f" 2>/dev/null || echo 0)"
  printf '%s\n' "$((n + 1))" >"$f"
}
count_of() { cat "${COUNTERS}/$1"; }

eval "$(declare -f engine_place_dp_phase2_final | sed '1s/engine_place_dp_phase2_final/real_engine_place_dp_phase2_final/')"
engine_place_dp_phase2_final() {
  bump place
  real_engine_place_dp_phase2_final "$@"
}
acps_acquire_all() { bump acps; }
acps_setup_curl_auth() { return 0; }
acps_test_connection() { return 0; }
acps_expected_bytes_hint() { printf '%s\n' 300; }
engine_preflight_host() { return 0; }
mm_acquire_install_lock() { return 0; }
mm_release_install_lock() { return 0; }
engine_assert_same_filesystem_layout() { return 0; }
engine_finalize_local_client_set() {
  seed_complete_client_http_set "$MM_CLIENT_ROOT" "http://192.0.2.10" \
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  mm_status_set CLIENT_FILES_READY PASS
  mm_ok "CLIENT_SET_FINALIZATION=PASS (prereq-reuse fixture)"
  return 0
}
engine_rebuild_publish_local_client_set() {
  seed_complete_client_http_set "$MM_CLIENT_ROOT" "http://192.0.2.10" \
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  return 0
}
mm_client_set_current_source() { return 0; }
mm_check_client_build_prerequisites_ready() {
  mm_state_set CLIENT_BUILD_PREREQUISITES_READY PASS
  return 0
}

make_valid_final
PRESERVED="$(engine_phase2_prereq_src_dir 6.6.0)"
mkdir -p "$PRESERVED"
phase2_prereq_write_zero_extra_common "${PRESERVED}/aelladeb_py3_common.tar.gz" "preserved"
sha1sum "${PRESERVED}/aelladeb_py3_common.tar.gz" | awk '{print $1}' \
  >"${PRESERVED}/aelladeb_py3_common.tar.gz.sha1"
write_tiny_uvp_deb "${PRESERVED}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb"
sha1sum "${PRESERVED}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}' \
  >"${PRESERVED}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
FINAL_BEFORE="$(sha256sum "${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar" | awk '{print $1}')"

reset_counters
OUT_G="${WORKDIR}/out-g"
set +e
( engine_download_and_prepare ) >"$OUT_G" 2>&1
G_RC=$?
set -e
FINAL_AFTER="$(sha256sum "${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar" | awk '{print $1}')"
if [[ "$G_RC" -eq 0 ]] \
  && grep -q 'PHASE2_EXISTING_BUNDLE=VALID' "$OUT_G" \
  && grep -q 'PHASE2_BUNDLE_ACTION=REUSE' "$OUT_G" \
  && grep -q 'ACPS_DOWNLOAD_REQUIRED=NO' "$OUT_G" \
  && grep -q 'PHASE2_BUNDLE_REBUILD_REQUIRED=NO' "$OUT_G" \
  && grep -q 'PHASE2_PREREQ=PASS' "$OUT_G" \
  && [[ "$(count_of acps)" -eq 0 ]] \
  && [[ "$(count_of place)" -eq 0 ]] \
  && [[ "$FINAL_BEFORE" == "$FINAL_AFTER" ]] \
  && [[ -f "${PRESERVED}/aelladeb_py3_common.tar.gz" ]] \
  && [[ -f "${MM_DP_PHASE2_ROOT}/6.6.0/extras/phase2-ubuntu-prerequisites.state" ]]
then
  pass "G VALID final reuse: no ACPS, no rebuild, prereq retried, final preserved"
else
  echo "---- G ----"
  echo "rc=${G_RC} acps=$(count_of acps) place=$(count_of place)"
  echo "final_before=${FINAL_BEFORE} final_after=${FINAL_AFTER}"
  cat "$OUT_G"
  fail "G valid final reuse"
fi

echo "SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
