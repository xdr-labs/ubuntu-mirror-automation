#!/usr/bin/env bash
# tests/test_dp_phase2_bundle.sh — DP Phase 2 sync/verify logic with tiny fixtures
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/dp-phase2-common.sh
source "${ROOT}/scripts/lib/dp-phase2-common.sh"
# shellcheck source=lib/phase2_prereq_fixture.sh
source "${ROOT}/tests/lib/phase2_prereq_fixture.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"; [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true' EXIT

FIXTURE="${WORKDIR}/fixture"
mkdir -p "$FIXTURE"

make_payload() {
  local dir="$1"
  mkdir -p "$dir"
  phase2_prereq_write_zero_extra_common "${dir}/aelladeb_py3_common.tar.gz" "common-payload"
  sha1sum "${dir}/aelladeb_py3_common.tar.gz" | awk '{print $1"  /build/server/aelladeb_py3_common.tar.gz"}' \
    >"${dir}/aelladeb_py3_common.tar.gz.sha1"
  printf 'uvp-deb\n' >"${dir}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb"
  sha1sum "${dir}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1"  /abs/path/uvp.deb"}' \
    >"${dir}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
  printf '#!/bin/bash\necho bringup\n' >"${dir}/bringup_py3_dp_after_os_upgrade.sh"
  sha1sum "${dir}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
    >"${dir}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  # 156-line list
  seq 1 156 >"${dir}/images-6.6.0.list"
  printf 'images-tar-body\n' >"${dir}/images-6.6.0.tar"
  sha256sum "${dir}/images-6.6.0.tar" | awk '{print $1"  /build/images-6.6.0.tar"}' \
    >"${dir}/images-6.6.0.tar.sha256"
}

echo "[test] required file list count"
[[ ${#DP_PHASE2_REQUIRED_FILES[@]} -eq 9 ]] && pass "9 required files" || fail "file list size"

echo "[test] checksum first-field with absolute path in second column"
make_payload "$FIXTURE"
dp2_verify_sha1_pair "${FIXTURE}/aelladeb_py3_common.tar.gz" "${FIXTURE}/aelladeb_py3_common.tar.gz.sha1" \
  && pass "sha1 ignores abs path column" || fail "sha1 abs path"
dp2_verify_sha256_pair "${FIXTURE}/images-6.6.0.tar" "${FIXTURE}/images-6.6.0.tar.sha256" \
  && pass "sha256 ignores abs path column" || fail "sha256 abs path"

echo "[test] zero-byte reject"
: >"${WORKDIR}/empty.bin"
if ( dp2_reject_bad_payload "${WORKDIR}/empty.bin" empty.bin ) 2>/dev/null; then
  fail "zero-byte should reject"
else
  pass "zero-byte rejected"
fi

echo "[test] HTML reject"
printf '<!DOCTYPE html><html>err</html>' >"${WORKDIR}/html.bin"
if ( dp2_reject_bad_payload "${WORKDIR}/html.bin" html.bin ) 2>/dev/null; then
  fail "HTML should reject"
else
  pass "HTML rejected"
fi

echo "[test] bad SHA1 reject"
echo 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef  x' >"${FIXTURE}/aelladeb_py3_common.tar.gz.sha1"
if ( dp2_verify_sha1_pair "${FIXTURE}/aelladeb_py3_common.tar.gz" "${FIXTURE}/aelladeb_py3_common.tar.gz.sha1" ) 2>/dev/null; then
  fail "bad sha1 should reject"
else
  pass "bad sha1 rejected"
fi
# restore
make_payload "$FIXTURE"

echo "[test] bad SHA256 reject"
echo 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  x' >"${FIXTURE}/images-6.6.0.tar.sha256"
if ( dp2_verify_sha256_pair "${FIXTURE}/images-6.6.0.tar" "${FIXTURE}/images-6.6.0.tar.sha256" ) 2>/dev/null; then
  fail "bad sha256 should reject"
else
  pass "bad sha256 rejected"
fi
make_payload "$FIXTURE"

echo "[test] bundle tar exact 9 top-level names"
BUNDLE="${WORKDIR}/bundle.tar"
(
  cd "$FIXTURE"
  tar -cf "$BUNDLE" "${DP_PHASE2_REQUIRED_FILES[@]}"
)
dp2_assert_safe_tar_list "$BUNDLE" && pass "safe tar list" || fail "safe tar list"

echo "[test] tar path traversal reject"
BAD="${WORKDIR}/bad.tar"
mkdir -p "${WORKDIR}/trav/files"
printf 'x\n' >"${WORKDIR}/trav/files/aelladeb_py3_common.tar.gz"
# craft a tar with nested path by packaging a subdirectory name
(
  cd "${WORKDIR}/trav"
  tar -cf "$BAD" files/aelladeb_py3_common.tar.gz
)
if ( dp2_assert_safe_tar_list "$BAD" ) 2>/dev/null; then
  fail "nested tar path should reject"
else
  pass "nested tar path rejected"
fi

echo "[test] image list line count warning vs pass"
lines="$(dp2_check_image_list "${FIXTURE}/images-6.6.0.list" | tail -n1)"
[[ "$lines" == "156" ]] && pass "image list 156" || fail "image list count got=${lines}"
printf 'only\none\n' >"${WORKDIR}/short.list"
if out="$(dp2_check_image_list "${WORKDIR}/short.list" 2>&1)"; then
  echo "$out" | grep -q 'WARNING' && pass "non-156 warns but does not fail" || fail "expected WARNING"
else
  fail "non-156 should not hard-fail"
fi

echo "[test] release.env has no secrets helper"
printf 'DP_PHASE2_VERSION=6.6.0\n' >"${WORKDIR}/clean.env"
dp2_release_has_secret "${WORKDIR}/clean.env" && fail "clean env flagged" || pass "clean env OK"
printf 'ACPS_PASS=secret\n' >"${WORKDIR}/dirty.env"
dp2_release_has_secret "${WORKDIR}/dirty.env" && pass "secret detected" || fail "secret not detected"

echo "[test] atomic current + previous + failure preserves current"
DP_ROOT="${WORKDIR}/dp-phase2"
export DP_PHASE2_ROOT="$DP_ROOT"
export DP_PHASE2_VERSION="6.6.0"
export DP_PHASE2_MIN_FREE_GIB="0"
export DP_PHASE2_SKIP_ROOT_CHECK=1
export DP_PHASE2_LOCK_FILE="${WORKDIR}/dp2.lock"
export UOM_LOCK_FILE="${WORKDIR}/uom.lock"
export DP_PHASE2_LOG_FILE="${WORKDIR}/sync.log"
export DP_PHASE2_CLEAN_FAILED_STAGING=1
export PHASE2_PREREQ_INDEX_ROOT="${WORKDIR}/noble-index"
phase2_prereq_write_empty_noble_index "$PHASE2_PREREQ_INDEX_ROOT"

# Local fixture HTTP server
make_payload "${WORKDIR}/http_root"
python3 - "${WORKDIR}/http_root" 8765 <<'PY' &
import http.server, os, sys
os.chdir(sys.argv[1])
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), http.server.SimpleHTTPRequestHandler).serve_forever()
PY
HTTP_PID=$!
sleep 0.4
export DP_PHASE2_SOURCE_BASE="http://127.0.0.1:8765"

# First sync
if ! bash "${ROOT}/scripts/download-dp-phase2-6.6.0.sh" sync; then
  fail "first sync"
else
  pass "first sync"
fi
CUR1="$(readlink -f "${DP_ROOT}/6.6.0/current")"
[[ -d "$CUR1" ]] && pass "current exists" || fail "current missing"
[[ -f "${CUR1}/dp_bundle_6.6.0-current.tar" ]] && pass "stable bundle" || fail "stable bundle"
[[ -f "${CUR1}/release.env" ]] && pass "release.env" || fail "release.env"
grep -q '^TARGET_DP_VERSION=6.6.0$' "${CUR1}/release.env" && pass "TARGET_DP_VERSION in release.env" || fail "TARGET_DP_VERSION"
grep -q '^PHASE2_ARTIFACT_VERSION=6.6.0$' "${CUR1}/release.env" && pass "PHASE2_ARTIFACT_VERSION" || fail "PHASE2_ARTIFACT_VERSION"
if grep -Eiq 'ACPS_PASS|password=' "${CUR1}/release.env"; then
  fail "secret in release.env"
else
  pass "no secret in release.env"
fi
dp2_verify_manifest_sha256 "$CUR1" && pass "manifest verify" || fail "manifest verify"
# hardlink check
ino1="$(stat -c%i "${CUR1}/dp_bundle_"*.tar | head -1)"
ino2="$(stat -c%i "${CUR1}/dp_bundle_6.6.0-current.tar")"
# timestamp bundle + stable should share inode
ts="$(ls "${CUR1}"/dp_bundle_2*.tar 2>/dev/null | head -1 || true)"
if [[ -n "$ts" ]]; then
  [[ "$(stat -c%i "$ts")" == "$(stat -c%i "${CUR1}/dp_bundle_6.6.0-current.tar")" ]] \
    && pass "stable hardlink same inode" || fail "stable hardlink"
fi

# Second sync with changed payload → previous preserved
phase2_prereq_write_zero_extra_common \
  "${WORKDIR}/http_root/aelladeb_py3_common.tar.gz" "common-payload-v2"
sha1sum "${WORKDIR}/http_root/aelladeb_py3_common.tar.gz" | awk '{print $1"  /build/x"}' \
  >"${WORKDIR}/http_root/aelladeb_py3_common.tar.gz.sha1"
sleep 1
if ! bash "${ROOT}/scripts/download-dp-phase2-6.6.0.sh" sync; then
  fail "second sync"
else
  pass "second sync"
fi
CUR2="$(readlink -f "${DP_ROOT}/6.6.0/current")"
PREV="$(readlink -f "${DP_ROOT}/6.6.0/previous" 2>/dev/null || true)"
[[ "$CUR2" != "$CUR1" ]] && pass "current advanced" || fail "current not advanced"
[[ "$PREV" == "$CUR1" ]] && pass "previous preserved" || fail "previous not preserved prev=${PREV}"

# Failure must not move current: break checksum then sync
printf 'corrupt\n' >"${WORKDIR}/http_root/images-6.6.0.tar"
# leave old sha256 → mismatch
if bash "${ROOT}/scripts/download-dp-phase2-6.6.0.sh" sync 2>/dev/null; then
  fail "corrupt sync should fail"
else
  pass "corrupt sync failed"
fi
CUR3="$(readlink -f "${DP_ROOT}/6.6.0/current")"
[[ "$CUR3" == "$CUR2" ]] && pass "current unchanged after failure" || fail "current changed after failure"

echo "[test] verify/status commands"
bash "${ROOT}/scripts/download-dp-phase2-6.6.0.sh" verify && pass "verify" || fail "verify"
bash "${ROOT}/scripts/download-dp-phase2-6.6.0.sh" status | grep -q 'FINAL_VERIFY=PASS' && pass "status" || fail "status"

echo "[test] UOM CLI wiring + bash -n"
grep -q 'sync-dp-phase2' "${ROOT}/scripts/ubuntu-offline-mirror.sh" || fail "missing sync-dp-phase2"
grep -q 'verify-dp-phase2' "${ROOT}/scripts/ubuntu-offline-mirror.sh" || fail "missing verify-dp-phase2"
grep -q 'status-dp-phase2' "${ROOT}/scripts/ubuntu-offline-mirror.sh" || fail "missing status-dp-phase2"
bash -n "${ROOT}/scripts/download-dp-phase2.sh" && pass "bash -n download" || fail "bash -n download"
bash -n "${ROOT}/scripts/download-dp-phase2-6.6.0.sh" && pass "bash -n download wrapper" || fail "bash -n download wrapper"
bash -n "${ROOT}/scripts/lib/dp-phase2-common.sh" && pass "bash -n common" || fail "bash -n common"
bash -n "${ROOT}/scripts/deploy-stage-dp-phase2-client-atomic.sh" && pass "bash -n deploy" || fail "bash -n deploy"

echo "[test] nginx template/generator include /dp-phase2/6.6.0/"
grep -q 'location /dp-phase2/6.6.0/' "${ROOT}/templates/nginx.conf" && pass "template location" || fail "template location"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${ROOT}/lib/config.sh"
um_load_config "${ROOT}/mirror.conf"
gen="$(um_generate_nginx_conf)"
echo "$gen" | grep -q 'location /dp-phase2/6.6.0/' && pass "generator location" || fail "generator location"
echo "$gen" | grep -q 'location /ubuntu/' && pass "ubuntu preserved" || fail "ubuntu"
echo "$gen" | grep -q 'location /offline/' && pass "offline preserved" || fail "offline"
echo "$gen" | grep -q 'location /hops/' && pass "hops preserved" || fail "hops"
echo "$gen" | grep -q 'location /client/' && pass "client preserved" || fail "client"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -e SC1090,SC1091,SC2015,SC2034,SC2119,SC2120,SC2317 \
    "${ROOT}/scripts/lib/dp-phase2-common.sh" \
    "${ROOT}/scripts/download-dp-phase2.sh" \
    "${ROOT}/scripts/download-dp-phase2-6.6.0.sh" \
    && pass "shellcheck dp-phase2" || fail "shellcheck dp-phase2"
else
  echo "  SKIP: shellcheck not installed"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL DP PHASE2 BUNDLE TESTS PASSED"
  exit 0
fi
echo "SOME DP PHASE2 BUNDLE TESTS FAILED"
exit 1
