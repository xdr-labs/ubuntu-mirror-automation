#!/usr/bin/env bash
# Regression: interrupted ACPS downloads must reduce future disk-growth needs
# without reducing the full Phase 2 bundle output estimate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
DP2_COMMON="${ROOT}/scripts/lib/dp-phase2-common.sh"
ACPS="${ROOT}/scripts/lib/acps_acquire.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MM_MIRROR_ROOT="${TMP}/mirror"
MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
MM_SELECTIVE_ROOT="${MM_MIRROR_ROOT}/selective"
MM_STATE_ROOT="${TMP}/state"
MM_STATE_DIR="${MM_STATE_ROOT}/run"
MM_LOG_DIR="${TMP}/logs"
MM_CONFIG_DIR="${TMP}/config"
MM_CONFIG_FILE="${MM_CONFIG_DIR}/config"
MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
mkdir -p "$MM_CACHE_ROOT" "$MM_STATE_DIR" "$MM_CONFIG_DIR"

# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "$COMMON"
# shellcheck source=../scripts/lib/dp-phase2-common.sh
source "$DP2_COMMON"
# shellcheck source=../scripts/lib/acps_acquire.sh
source "$ACPS"

# Small deterministic fixture for the per-file remote-size-bounded resume scan.
DP_PHASE2_VERSION=6.6.0
TARGET_DP_VERSION=6.6.0
DP_PHASE2_REQUIRED_FILES=(complete.bin partial.bin missing.bin oversized.bin)
CACHE="$(acps_cache_dir "$DP_PHASE2_VERSION")"
mkdir -p "$CACHE" "${TMP}/bin"
truncate -s 80 "${CACHE}/complete.bin"
truncate -s 150 "${CACHE}/partial.bin.part"
truncate -s 450 "${CACHE}/oversized.bin.part"

cat >"${TMP}/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  */complete.bin) n=100 ;;
  */partial.bin) n=200 ;;
  */missing.bin) n=300 ;;
  */oversized.bin) n=400 ;;
  *) exit 22 ;;
esac
printf 'HTTP/1.1 302 Found\r\nContent-Length: 7\r\n\r\n'
printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "$n"
EOF_CURL
chmod +x "${TMP}/bin/curl"
PATH="${TMP}/bin:${PATH}"
ACPS_CURL_AUTH_ARGS=()
ACPS_CURL_TLS_ARGS=()

expected="$(acps_expected_bytes_hint "http://fixture")"
[[ "$expected" -eq 1000 ]] || fail "expected bytes should be 1000, got ${expected}"
acps_load_disk_preflight_state "$expected" "$DP_PHASE2_VERSION"
[[ "$ACPS_COMPLETED_CACHE_BYTES" -eq 80 ]] \
  || fail "completed credit expected=80 actual=${ACPS_COMPLETED_CACHE_BYTES}"
[[ "$ACPS_PARTIAL_BYTES" -eq 550 ]] \
  || fail "partial credit expected=550 actual=${ACPS_PARTIAL_BYTES}"
[[ "$ACPS_REUSABLE_ON_DISK_BYTES" -eq 630 ]] \
  || fail "reusable expected=630 actual=${ACPS_REUSABLE_ON_DISK_BYTES}"
[[ "$ACPS_REMAINING_DOWNLOAD_BYTES" -eq 370 ]] \
  || fail "remaining expected=370 actual=${ACPS_REMAINING_DOWNLOAD_BYTES}"
pass "per-file resume bytes are bounded by final Content-Length"

# Reproduce the observed 2026-08-08 field failure exactly:
#   expected ACPS = 30,307,522,091
#   completed files = 360,908,248
#   images-6.6.0.tar.part = 15,706,435,584
#   physical available = 68,987,588,608
# Old logic required 71,889,333,334 and failed. Correct future growth is
# remaining ACPS + full bundle + 512MiB metadata + 10GiB reserve.
cat >"$(acps_disk_preflight_state_file 6.6.0)" <<'EOF_STATE'
ACPS_PREFLIGHT_VERSION=6.6.0
ACPS_EXPECTED_BYTES=30307522091
ACPS_COMPLETED_CACHE_BYTES=360908248
ACPS_PARTIAL_BYTES=15706435584
ACPS_REUSABLE_ON_DISK_BYTES=16067343832
ACPS_REMAINING_DOWNLOAD_BYTES=14240178259
EOF_STATE

PREPARATION_MODE=FULL
PHASE2_BUNDLE_ACTION=CREATE
PHASE2_REBUILD_REQUIRED=YES
OS_CORE_PACKAGE_BYTES=0
OS_CORE_PAYLOAD_BYTES=0
ACPS_EXPECTED_BYTES=30307522091
MM_MOCK_AVAILABLE_BYTES=68987588608
MM_MOCK_FS_SIZE_BYTES=$((95 * 1024 * 1024 * 1024))
MM_MOCK_SAFETY_RESERVE_BYTES=$((10 * 1024 * 1024 * 1024))

mm_calc_disk_requirements >/dev/null

[[ "$DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES" -eq 68987588608 ]] \
  || fail "physical available bytes changed: ${DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES}"
[[ "$ACPS_REUSABLE_ON_DISK_BYTES" -eq 16067343832 ]] \
  || fail "field reusable bytes mismatch: ${ACPS_REUSABLE_ON_DISK_BYTES}"
[[ "$DISK_PREFLIGHT_ACPS_SOURCE_BYTES" -eq 14240178259 ]] \
  || fail "remaining source expected=14240178259 actual=${DISK_PREFLIGHT_ACPS_SOURCE_BYTES}"
[[ "$DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES" -eq 30307522091 ]] \
  || fail "bundle output must remain full expected size"
[[ "$DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES" -eq 45084571262 ]] \
  || fail "phase2 stage expected=45084571262 actual=${DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES}"
[[ "$TOTAL_REQUIRED_BYTES" -eq 55821989502 ]] \
  || fail "total required expected=55821989502 actual=${TOTAL_REQUIRED_BYTES}"
[[ "$DISK_PREFLIGHT_RESULT" == "PASS" ]] \
  || fail "observed interrupted-download case must PASS"
pass "observed 15GiB ACPS partial no longer causes false disk preflight failure"

echo "ALL ACPS RESUME DISK PREFLIGHT TESTS PASSED"
