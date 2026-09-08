#!/usr/bin/env bash
# Field regression: verified ACPS cache reuse must credit completed/reusable
# bytes in disk preflight (remaining download=0). Unverified/corrupt cache
# must not reduce the required download estimate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
DP2="${ROOT}/scripts/lib/dp-phase2-common.sh"
ACPS="${ROOT}/scripts/lib/acps_acquire.sh"

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

mkdir -p "$MM_CACHE_ROOT" "$MM_STATE_DIR" "$MM_CONFIG_DIR" "$MM_LOG_DIR" \
  "$MM_DP_PHASE2_ROOT" "$MM_SELECTIVE_ROOT" "$MM_CLIENT_ROOT"
: >"$MM_STATUS_FILE"

# shellcheck source=/dev/null
source "$COMMON"
# shellcheck source=/dev/null
source "$DP2"
# shellcheck source=/dev/null
source "$ACPS"

DP_PHASE2_VERSION=6.6.0
TARGET_DP_VERSION=6.6.0
dp2_set_version 6.6.0
CACHE="$(acps_cache_dir 6.6.0)"

seed_verified_cache() {
  local dir="$1"
  mkdir -p "$dir"
  local f
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    printf 'payload-%s\n' "$f" >"${dir}/${f}"
  done
  # Non-trivial size so accounting is clearly non-zero (field scale miniaturized).
  truncate -s 29949 "${dir}/images-6.6.0.tar"
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

# ---------------------------------------------------------------------------
# Positive: exact field class — verified cache, download NOT required,
# no network-produced resume state. Pre-fix wrongly set remaining=expected.
# ---------------------------------------------------------------------------
seed_verified_cache "$CACHE"
acps_is_verified_cache "$CACHE" || fail "seeded cache not verified"
BYTES="$(acps_local_verified_cache_bytes 6.6.0)" \
  || fail "local verified cache bytes failed"
[[ "$BYTES" =~ ^[1-9][0-9]*$ ]] || fail "bytes not positive: ${BYTES}"

# Deliberately omit writing state first — reproduce pre-fix handoff gap,
# then use the authoritative recorder the engine now calls.
rm -f "$(acps_disk_preflight_state_file 6.6.0)"
acps_record_verified_cache_disk_state 6.6.0 >/dev/null \
  || fail "record verified cache disk state failed"
[[ "$ACPS_EXPECTED_BYTES" -eq "$BYTES" ]] || fail "record expected mismatch"
[[ "$ACPS_COMPLETED_CACHE_BYTES" -eq "$BYTES" ]] || fail "record completed mismatch"
[[ "$ACPS_REUSABLE_ON_DISK_BYTES" -eq "$BYTES" ]] || fail "record reusable mismatch"
[[ "$ACPS_REMAINING_DOWNLOAD_BYTES" -eq 0 ]] || fail "record remaining must be 0"
pass "authoritative verified-cache disk state recorded"

PREPARATION_MODE=PHASE2_ONLY
PHASE2_BUNDLE_ACTION=CREATE
PHASE2_REBUILD_REQUIRED=YES
PHASE2_REBUILD_SOURCE=ACPS
ACPS_DOWNLOAD_REQUIRED=NO
ACPS_EXPECTED_BYTES="$BYTES"
OS_CORE_PACKAGE_BYTES=0
OS_CORE_PAYLOAD_BYTES=0
# Enough for one Phase2 output + safety reserve, not a second ACPS download.
MM_MOCK_SAFETY_RESERVE_BYTES=$((10 * 1024 * 1024 * 1024))
MM_MOCK_AVAILABLE_BYTES=$((BYTES + 512 * 1024 * 1024 + MM_MOCK_SAFETY_RESERVE_BYTES + 4096))
MM_MOCK_FS_SIZE_BYTES=$((BYTES * 3 + 20 * 1024 * 1024 * 1024))

mm_calc_disk_requirements >/dev/null

[[ "$ACPS_EXPECTED_BYTES" -eq "$BYTES" ]] \
  || fail "expected bytes changed: ${ACPS_EXPECTED_BYTES}"
[[ "$ACPS_COMPLETED_CACHE_BYTES" -eq "$BYTES" ]] \
  || fail "completed expected=${BYTES} actual=${ACPS_COMPLETED_CACHE_BYTES}"
[[ "$ACPS_REUSABLE_ON_DISK_BYTES" -eq "$BYTES" ]] \
  || fail "reusable expected=${BYTES} actual=${ACPS_REUSABLE_ON_DISK_BYTES}"
[[ "$ACPS_REMAINING_DOWNLOAD_BYTES" -eq 0 ]] \
  || fail "remaining must be 0 (field bug), got ${ACPS_REMAINING_DOWNLOAD_BYTES}"
[[ "$DISK_PREFLIGHT_ACPS_SOURCE_BYTES" -eq 0 ]] \
  || fail "ACPS source growth must be 0, got ${DISK_PREFLIGHT_ACPS_SOURCE_BYTES}"
[[ "$DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES" -eq "$BYTES" ]] \
  || fail "Phase2 output must still be budgeted at ${BYTES}"
[[ "$DISK_PREFLIGHT_SAFETY_RESERVE_BYTES" -eq "$MM_MOCK_SAFETY_RESERVE_BYTES" ]] \
  || fail "safety reserve not preserved"
[[ "$DISK_PREFLIGHT_RESULT" == "PASS" ]] \
  || fail "disk preflight must PASS with verified cache credit"
pass "FIELD_REPRO verified_cache_reuse disk accounting PASS"

# ---------------------------------------------------------------------------
# Same decision path WITHOUT pre-written state: mm_calc must re-derive from
# verified cache (not leave remaining=expected).
# ---------------------------------------------------------------------------
rm -f "$(acps_disk_preflight_state_file 6.6.0)"
ACPS_COMPLETED_CACHE_BYTES=0
ACPS_PARTIAL_BYTES=0
ACPS_REUSABLE_ON_DISK_BYTES=0
ACPS_REMAINING_DOWNLOAD_BYTES="$BYTES"
ACPS_EXPECTED_BYTES="$BYTES"
ACPS_DOWNLOAD_REQUIRED=NO
PHASE2_REBUILD_SOURCE=ACPS
PHASE2_BUNDLE_ACTION=CREATE
PHASE2_REBUILD_REQUIRED=YES
mm_calc_disk_requirements >/dev/null
[[ "$ACPS_COMPLETED_CACHE_BYTES" -eq "$BYTES" ]] \
  || fail "fallback completed expected=${BYTES} actual=${ACPS_COMPLETED_CACHE_BYTES}"
[[ "$ACPS_REMAINING_DOWNLOAD_BYTES" -eq 0 ]] \
  || fail "fallback remaining must be 0, got ${ACPS_REMAINING_DOWNLOAD_BYTES}"
[[ "$DISK_PREFLIGHT_RESULT" == "PASS" ]] \
  || fail "fallback disk preflight must PASS"
pass "mm_calc re-derives verified cache credit when state file absent"

# ---------------------------------------------------------------------------
# Negative: local files exist but verification fails → no reusable credit.
# ---------------------------------------------------------------------------
printf 'CORRUPT\n' >>"${CACHE}/images-6.6.0.tar"
acps_is_verified_cache "$CACHE" && fail "corrupt cache still verified"
acps_record_verified_cache_disk_state 6.6.0 >/dev/null 2>&1 \
  && fail "corrupt cache must not record reusable disk state" \
  || pass "corrupt cache rejected by record_verified_cache_disk_state"

rm -f "$(acps_disk_preflight_state_file 6.6.0)"
# Simulate a mistaken ACPS_DOWNLOAD_REQUIRED=NO with unverifiable cache and
# a stale/expected byte total — must fail closed (no reusable credit).
ACPS_EXPECTED_BYTES="$BYTES"
ACPS_DOWNLOAD_REQUIRED=NO
PHASE2_REBUILD_SOURCE=ACPS
PHASE2_BUNDLE_ACTION=CREATE
PHASE2_REBUILD_REQUIRED=YES
ACPS_COMPLETED_CACHE_BYTES=0
ACPS_REUSABLE_ON_DISK_BYTES=0
ACPS_REMAINING_DOWNLOAD_BYTES="$BYTES"
# Budget enough free space that disk PASS/FAIL does not hide accounting: we
# assert remaining/completed fields, which must stay fail-closed.
MM_MOCK_AVAILABLE_BYTES=$((
  2 * BYTES + 512 * 1024 * 1024 + MM_MOCK_SAFETY_RESERVE_BYTES + 1024 * 1024
))
mm_calc_disk_requirements >/dev/null
[[ "$ACPS_COMPLETED_CACHE_BYTES" -eq 0 ]] \
  || fail "corrupt cache must not count completed=${ACPS_COMPLETED_CACHE_BYTES}"
[[ "$ACPS_REUSABLE_ON_DISK_BYTES" -eq 0 ]] \
  || fail "corrupt cache must not count reusable=${ACPS_REUSABLE_ON_DISK_BYTES}"
[[ "$ACPS_REMAINING_DOWNLOAD_BYTES" -eq "$BYTES" ]] \
  || fail "corrupt remaining expected=${BYTES} actual=${ACPS_REMAINING_DOWNLOAD_BYTES}"
[[ "$DISK_PREFLIGHT_ACPS_SOURCE_BYTES" -eq "$BYTES" ]] \
  || fail "corrupt path must still budget full ACPS download growth"
pass "CORRUPT_CACHE_NEGATIVE no reusable credit / remaining intact"

echo "ALL VERIFIED CACHE DISK ACCOUNTING TESTS PASSED"
