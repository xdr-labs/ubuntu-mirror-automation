#!/usr/bin/env bash
# Verified ACPS cache must work offline without credentials/network.
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
export MM_CLIENT_ROOT="${MM_MIRROR_ROOT}/client"
export MM_STATE_DIR="${TMP}/state"
export MM_LOG_DIR="${TMP}/logs"
export MM_CONFIG_DIR="${TMP}/config"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/config"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_SKIP_ROOT_CHECK=1
export PREPARATION_MODE=PHASE2_ONLY
export PHASE2_TARGET_VERSION=6.6.0
export TARGET_DP_VERSION=6.6.0
export MIRROR_SERVER_IP=192.0.2.10
export ACPS_USERNAME=""
export ACPS_PASSWORD=""

mkdir -p "$MM_CACHE_ROOT" "$MM_STATE_DIR" "$MM_CONFIG_DIR" "$MM_LOG_DIR" \
  "$MM_DP_PHASE2_ROOT" "$MM_SELECTIVE_ROOT" "$MM_CLIENT_ROOT"
: >"$MM_STATUS_FILE"
cat >"$MM_CONFIG_FILE" <<'EOF'
PREPARATION_MODE=PHASE2_ONLY
PHASE2_TARGET_VERSION=6.6.0
TARGET_DP_VERSION=6.6.0
MIRROR_SERVER_IP=192.0.2.10
ACPS_USERNAME=
ACPS_PASSWORD=
EOF

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

seed_verified_cache() {
  local dir="$1"
  mkdir -p "$dir"
  local f
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    printf 'payload-%s\n' "$f" >"${dir}/${f}"
  done
  sha1sum "${dir}/aelladeb_py3_common.tar.gz" | awk '{print $1}' \
    >"${dir}/aelladeb_py3_common.tar.gz.sha1"
  sha1sum "${dir}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}' \
    >"${dir}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
  sha1sum "${dir}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
    >"${dir}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  sha256sum "${dir}/images-6.6.0.tar" | awk '{print $1 "  images-6.6.0.tar"}' \
    >"${dir}/images-6.6.0.tar.sha256"
  seq 1 2 >"${dir}/images-6.6.0.list"
  mm_acps_verify_payload_checksums "$dir" >/dev/null
  acps_write_verified_marker "$dir" || fail "write verified marker"
}

# Block network: curl always fails if invoked.
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl should not be called in offline verified-cache reuse" >&2
exit 97
EOF
chmod +x "${TMP}/bin/curl"
export PATH="${TMP}/bin:${PATH}"

seed_verified_cache "$CACHE"
acps_is_verified_cache "$CACHE" || fail "seeded cache not verified"
pass "VALID_VERIFIED_ACPS_CACHE=YES"

# Acquire with empty credentials + blocked network must REUSE.
if ! acps_acquire_all 6.6.0 >"${TMP}/acq.log" 2>&1; then
  fail "verified cache acquire_all failed offline: $(cat "${TMP}/acq.log")"
fi
grep -q 'ACPS_DOWNLOAD=REUSED' "${TMP}/acq.log" || fail "missing REUSED"
pass "verified cache reused offline without ACPS connection"

# Planning helper: local bytes available without network.
bytes="$(acps_local_verified_cache_bytes 6.6.0)" \
  || fail "local verified cache bytes failed"
[[ "$bytes" =~ ^[1-9][0-9]*$ ]] || fail "local bytes not positive: ${bytes}"
pass "local verified cache bytes=${bytes}"

# Unverified cache + empty credentials must fail closed at auth gate simulation.
rm -f "${CACHE}/.VERIFIED"
printf 'timestamp-only\n' >"${CACHE}/.VERIFIED"
acps_is_verified_cache "$CACHE" && fail "timestamp-only marker trusted" \
  || pass "timestamp-only marker rejected"

# Engine decision path: without verified marker, acquisition auth required.
PHASE2_BUNDLE_ACTION=CREATE
PHASE2_REBUILD_SOURCE=ACPS
ACPS_DOWNLOAD_REQUIRED=YES
if mm_acquisition_auth_ready; then
  fail "empty credentials unexpectedly ready"
fi
pass "UNVERIFIED_CACHE_NO_CREDENTIALS fail-closed at auth"

# Corrupt cache: mutate payload, empty credentials → not verified, auth required.
seed_verified_cache "$CACHE"
printf 'CORRUPT\n' >>"${CACHE}/images-6.6.0.tar"
acps_is_verified_cache "$CACHE" && fail "corrupt cache still verified" \
  || pass "corrupt cache invalidates verification"
if mm_acquisition_auth_ready; then
  fail "corrupt cache empty credentials unexpectedly ready"
fi
pass "ACPS_CACHE_CORRUPT + empty credentials fail-closed"

# Restore verified and confirm ABSENT path sets ACPS_DOWNLOAD_REQUIRED=NO
seed_verified_cache "$CACHE"
rm -rf "${MM_DP_PHASE2_ROOT}/6.6.0"
# Mimic engine ABSENT branch decision.
if acps_is_verified_cache "$(acps_cache_dir 6.6.0)"; then
  ACPS_DOWNLOAD_REQUIRED=NO
else
  ACPS_DOWNLOAD_REQUIRED=YES
fi
[[ "$ACPS_DOWNLOAD_REQUIRED" == "NO" ]] || fail "ABSENT+verified should not require download"
pass "ABSENT final + verified cache → ACPS_DOWNLOAD_REQUIRED=NO"

# Menu2 auth gate: verified cache + empty creds → allow
unset ACPS_DOWNLOAD_REQUIRED || true
ACPS_USERNAME=""
ACPS_PASSWORD=""
seed_verified_cache "$CACHE"
mm_acquisition_auth_or_verified_cache_ready \
  || fail "verified cache + empty creds should allow Menu2 auth gate"
pass "Menu2 verified-cache auth gate allows without credentials"

# Menu2 auth gate: corrupt/unverified + empty creds → FAIL
printf 'CORRUPT\n' >>"${CACHE}/images-6.6.0.tar"
mm_acquisition_auth_or_verified_cache_ready \
  && fail "corrupt cache + empty creds should fail Menu2 auth gate" \
  || pass "Menu2 corrupt-cache auth gate requires credentials"

echo "ALL VERIFIED ACPS OFFLINE REUSE TESTS PASSED"
