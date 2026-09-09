#!/usr/bin/env bash
# Menu2 auth gate: verified ACPS cache may proceed without credentials.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_PROJECT_ROOT="$ROOT"
export MM_MIRROR_ROOT="${TMP}/mirror"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_CONFIG_DIR="${TMP}/config"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/config"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_SKIP_ROOT_CHECK=1
export PHASE2_TARGET_VERSION=6.6.0
export TARGET_DP_VERSION=6.6.0
export ACPS_USERNAME=""
export ACPS_PASSWORD=""
mkdir -p "$MM_CACHE_ROOT" "$MM_CONFIG_DIR" "$MM_DP_PHASE2_ROOT"
: >"$MM_STATUS_FILE"
cat >"$MM_CONFIG_FILE" <<'EOF'
PREPARATION_MODE=PHASE2_ONLY
PHASE2_TARGET_VERSION=6.6.0
TARGET_DP_VERSION=6.6.0
ACPS_USERNAME=
ACPS_PASSWORD=
EOF

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/dp-phase2-common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/acps_acquire.sh"

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
acps_write_verified_marker "$CACHE" || fail "write verified marker"

mm_acquisition_auth_ready && fail "empty creds should not satisfy auth-only gate"
mm_acps_verified_cache_reuse_available || fail "verified cache reuse unavailable"
mm_acquisition_auth_or_verified_cache_ready \
  || fail "verified cache + empty creds should allow Menu2"
pass "valid verified cache + empty creds → Menu2 auth gate allows"

printf 'x' >>"${CACHE}/images-6.6.0.tar"
mm_acps_verified_cache_reuse_available \
  && fail "corrupt cache still reusable" || true
mm_acquisition_auth_or_verified_cache_ready \
  && fail "corrupt cache + empty creds should FAIL" \
  || pass "corrupt/unverified + empty creds → credentials required"

echo "ALL MENU2 VERIFIED CACHE NO-CREDS TESTS PASSED"
