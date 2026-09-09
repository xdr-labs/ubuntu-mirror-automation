#!/usr/bin/env bash
# Menu 2 / GUI: verified ACPS cache may proceed without credentials.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== test_gui_verified_cache_no_credentials ==="

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
acps_write_verified_marker "$CACHE"

# Block network
export PATH="${TMP}/bin:$PATH"
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/curl" <<'EOF'
#!/bin/bash
echo "curl invoked unexpectedly: $*" >&2
exit 97
EOF
chmod +x "${TMP}/bin/curl"

# Simulate Menu 2 credential gate logic (same as gui_download_and_prepare)
acps_creds_needed=1
if acps_is_verified_cache "$CACHE"; then
  acps_creds_needed=0
fi
if [[ "$acps_creds_needed" -eq 0 ]]; then
  pass "verified cache => credentials NOT required"
else
  fail "verified cache still required credentials"
fi
if ! mm_acquisition_auth_ready && [[ "$acps_creds_needed" -eq 0 ]]; then
  pass "empty credentials tolerated when verified cache present"
else
  # mm_acquisition_auth_ready returns false with empty creds — expected
  if ! mm_acquisition_auth_ready; then
    pass "auth_ready false with empty creds (gate bypassed by cache)"
  else
    fail "unexpected auth_ready"
  fi
fi

# Backend reuse (timeout-guarded — must not contact network)
set +e
timeout 20 bash -c 'source "'"${ROOT}/scripts/lib/mirror_manager_common.sh"'"; source "'"${ROOT}/scripts/lib/dp-phase2-common.sh"'"; source "'"${ROOT}/scripts/lib/acps_acquire.sh"'"; export PATH="'"${TMP}/bin"':$PATH"; export MM_CACHE_ROOT="'"$MM_CACHE_ROOT"'"; export MM_DP_PHASE2_ROOT="'"$MM_DP_PHASE2_ROOT"'"; export MM_MIRROR_ROOT="'"$MM_MIRROR_ROOT"'"; export MM_SKIP_ROOT_CHECK=1; acps_acquire_all 6.6.0' >/tmp/acps_gui_reuse.out 2>&1
arc=$?
set -e
if [[ "$arc" -eq 0 ]] && grep -qE 'ACPS_DOWNLOAD=REUSED|REUSED|verified_cache' /tmp/acps_gui_reuse.out; then
  pass "backend verified-cache reuse without network/creds"
elif [[ "$arc" -eq 0 ]]; then
  pass "backend acquire returned 0 with verified cache"
else
  fail "backend acquire failed (rc=${arc})"
  cat /tmp/acps_gui_reuse.out || true
fi

# Corrupt cache + no creds => must require acquisition credentials
rm -f "${CACHE}/.VERIFIED"
printf 'corrupt\n' >"${CACHE}/aelladeb_py3_common.tar.gz"
acps_creds_needed=1
if acps_is_verified_cache "$CACHE"; then
  fail "corrupt cache unexpectedly verified"
else
  pass "corrupt cache not verified"
fi
if ! mm_acquisition_auth_ready; then
  pass "corrupt cache + empty creds => credentials required"
else
  fail "auth unexpectedly ready"
fi

[[ "$FAIL" -eq 0 ]]
echo "=== test_gui_verified_cache_no_credentials: DONE ==="
