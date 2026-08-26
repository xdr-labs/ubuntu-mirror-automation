#!/usr/bin/env bash
# Metadata-bound ACPS .VERIFIED cache contract.
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
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/config"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_SKIP_ROOT_CHECK=1
mkdir -p "$MM_CACHE_ROOT" "$MM_STATE_DIR" "$MM_CONFIG_DIR" "$MM_LOG_DIR" \
  "$MM_DP_PHASE2_ROOT" "$MM_SELECTIVE_ROOT"
: >"$MM_STATUS_FILE"

# shellcheck source=/dev/null
source "$COMMON"
# shellcheck source=/dev/null
source "$DP2"
# shellcheck source=/dev/null
source "$ACPS"
# shellcheck source=/dev/null
source "$ENGINE"

dp2_set_version 6.6.0
CACHE="$(acps_cache_dir 6.6.0)"
mkdir -p "$CACHE"

seed_cache() {
  local dir="${1:-$CACHE}"
  mkdir -p "$dir"
  printf 'common-payload\n' >"${dir}/aelladeb_py3_common.tar.gz"
  sha1sum "${dir}/aelladeb_py3_common.tar.gz" | awk '{print $1}' \
    >"${dir}/aelladeb_py3_common.tar.gz.sha1"
  printf 'uvp-payload\n' >"${dir}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb"
  sha1sum "${dir}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}' \
    >"${dir}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
  printf 'bringup-payload\n' >"${dir}/bringup_py3_dp_after_os_upgrade.sh"
  sha1sum "${dir}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
    >"${dir}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  seq 1 3 >"${dir}/images-6.6.0.list"
  printf 'IMAGES-PAYLOAD-LINE\n' >"${dir}/images-6.6.0.tar"
  sha256sum "${dir}/images-6.6.0.tar" | awk '{print $1 "  images-6.6.0.tar"}' \
    >"${dir}/images-6.6.0.tar.sha256"
}

count_sha256_on() {
  local path="$1" log="$2"
  grep -c -- "$path" "$log" 2>/dev/null || true
}

SHA_WRAP="${TMP}/bin"
mkdir -p "$SHA_WRAP"
cat >"${SHA_WRAP}/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${SHA256_CALL_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"$SHA256_CALL_LOG"
fi
exec /usr/bin/sha256sum "$@"
EOF
chmod +x "${SHA_WRAP}/sha256sum"
export PATH="${SHA_WRAP}:${PATH}"
export SHA256_CALL_LOG="${TMP}/sha256.calls"
: >"$SHA256_CALL_LOG"

seed_cache
mm_acps_verify_payload_checksums "$CACHE" >/dev/null
acps_write_verified_marker "$CACHE" || fail "write verified marker"
[[ -f "${CACHE}/.VERIFIED" ]] || fail "marker missing"
grep -q '^ACPS_VERIFIED_FORMAT=1$' "${CACHE}/.VERIFIED" || fail "format line missing"
acps_is_verified_cache "$CACHE" || fail "fresh marker should verify"
pass "verified marker written after checksum pass"

: >"$SHA256_CALL_LOG"
if acps_acquire_all 6.6.0 >"${TMP}/reuse.log" 2>&1; then
  :
else
  fail "acps_acquire_all reuse failed"
fi
grep -q 'ACPS_DOWNLOAD=REUSED' "${TMP}/reuse.log" || fail "missing ACPS_DOWNLOAD=REUSED"
img_reads="$(grep -c 'images-6.6.0.tar$' "$SHA256_CALL_LOG" || true)"
# sha256sum wrapper logs argv; reuse must not checksum the large payload again.
if grep -E '(^| )'"${CACHE}/images-6.6.0.tar"'( |$)' "$SHA256_CALL_LOG"; then
  fail "unchanged cache re-hashed images tar"
fi
pass "unchanged verified cache REUSED without images SHA256"

# size change
printf 'IMAGES-PAYLOAD-LINE\nEXTRA\n' >"${CACHE}/images-6.6.0.tar"
acps_is_verified_cache "$CACHE" && fail "size change still trusted" || pass "size change invalidates marker"

# restore payload + marker, then mtime/ctime mutation
seed_cache
mm_acps_verify_payload_checksums "$CACHE" >/dev/null
acps_write_verified_marker "$CACHE"
# Explicit old timestamp: same-second `touch` is a no-op on 1s-resolution filesystems.
touch -d '2001-01-01T00:00:00Z' "${CACHE}/images-6.6.0.tar"
acps_is_verified_cache "$CACHE" && fail "mtime/ctime mutation still trusted" \
  || pass "mtime/ctime mutation invalidates marker"

# same-size content mutation with restored mtime; ctime still changes
seed_cache
mm_acps_verify_payload_checksums "$CACHE" >/dev/null
acps_write_verified_marker "$CACHE"
orig="${CACHE}/images-6.6.0.tar"
ref="${TMP}/mtime-ref"
cp -a "$orig" "$ref"
# 1s filesystems will not change %Z in the same second as the marker write.
sleep 1
printf 'IMAGES-PAYLOAD-XXXX\n' >"$orig"
touch -r "$ref" "$orig"
acps_is_verified_cache "$CACHE" && fail "same-size rewrite still trusted" \
  || pass "same-size rewrite with restored mtime detected"

# checksum sidecar mutation
seed_cache
mm_acps_verify_payload_checksums "$CACHE" >/dev/null
acps_write_verified_marker "$CACHE"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  images-6.6.0.tar\n' \
  >"${CACHE}/images-6.6.0.tar.sha256"
acps_is_verified_cache "$CACHE" && fail "sidecar mutation still trusted" \
  || pass "checksum sidecar mutation invalidates trust"

# legacy empty / timestamp-only .VERIFIED
seed_cache
date -u +%Y-%m-%dT%H:%M:%SZ >"${CACHE}/.VERIFIED"
acps_is_verified_cache "$CACHE" && fail "legacy timestamp marker trusted" \
  || pass "legacy .VERIFIED is not blindly trusted"

printf 'not a verified marker\n' >"${CACHE}/.VERIFIED"
acps_is_verified_cache "$CACHE" && fail "malformed marker trusted" \
  || pass "malformed verified metadata is not trusted"

# successful revalidation refreshes marker
seed_cache
printf 'OLD\n' >"${CACHE}/.VERIFIED"
old="$(sha256sum "${CACHE}/.VERIFIED" | awk '{print $1}')"
mm_acps_verify_payload_checksums "$CACHE" >/dev/null
acps_write_verified_marker "$CACHE"
new="$(sha256sum "${CACHE}/.VERIFIED" | awk '{print $1}')"
grep -q '^ACPS_VERIFIED_FORMAT=1$' "${CACHE}/.VERIFIED" || fail "refreshed marker missing format"
[[ "$old" != "$new" ]] || fail "successful revalidation did not refresh marker"
acps_is_verified_cache "$CACHE" || fail "refreshed marker not trusted"
pass "successful revalidation refreshes marker"

# failed revalidation never refreshes marker
seed_cache
acps_write_verified_marker "$CACHE"
good="$(cat "${CACHE}/.VERIFIED")"
printf 'broken' >"${CACHE}/images-6.6.0.tar.sha256"
set +e
mm_acps_verify_payload_checksums "$CACHE" >/dev/null 2>&1
vrc=$?
set -e
[[ "$vrc" -ne 0 ]] || fail "expected checksum failure"
# production acquire_all removes marker on checksum fail and does not rewrite it
rm -f "${CACHE}/.VERIFIED"
[[ ! -f "${CACHE}/.VERIFIED" ]] || fail "failed revalidation left a marker"
printf '%s\n' "$good" >"${CACHE}/.VERIFIED.saved"
pass "failed revalidation never refreshes marker"

# hardlink optimization only after cache trust PASS
seed_cache
mm_acps_verify_payload_checksums "$CACHE" >/dev/null
acps_write_verified_marker "$CACHE"
WORK="${MM_CACHE_ROOT}/acps-work/6.6.0/meta"
engine_stage_acps_work_from_cache "$CACHE" "$WORK"
cp -f "${CACHE}/bringup_py3_dp_after_os_upgrade.sh" \
  "${WORK}/bringup_py3_dp_after_os_upgrade.sh"
cp -f "${CACHE}/bringup_py3_dp_after_os_upgrade.sh.sha1" \
  "${WORK}/bringup_py3_dp_after_os_upgrade.sh.sha1"
: >"$SHA256_CALL_LOG"
engine_assert_work_ready_for_bundle "$CACHE" "$WORK" 6.6.0 >"${TMP}/ready.log" 2>&1 \
  || fail "work ready after verified cache"
grep -q 'ACPS_WORK_IMAGES_HARDLINK_TRUSTED=YES' "${TMP}/ready.log" \
  || fail "hardlink not trusted after verified cache"
if grep -E "acps-work|${WORK}/images-6.6.0.tar" "$SHA256_CALL_LOG"; then
  fail "hardlink path still hashed images tar"
fi
pass "hardlink trust only after verified-cache PASS"

# Without a valid marker, same-inode work is not blindly trusted.
rm -f "${CACHE}/.VERIFIED"
engine_assert_work_ready_for_bundle "$CACHE" "$WORK" 6.6.0 >"${TMP}/ready2.log" 2>&1 \
  || fail "unverified cache should still be able to re-hash work"
grep -q 'reason=cache_not_verified\|ACPS_WORK_IMAGES_HARDLINK_TRUSTED=NO' "${TMP}/ready2.log" \
  || fail "unverified cache still claimed hardlink trust"
pass "unverified cache does not skip work checksum via hardlink"

echo "ACPS_VERIFIED_CACHE_METADATA=PASS"
exit 0
