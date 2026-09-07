#!/usr/bin/env bash
# Private ACPS cache/work permission contract: dirs 0700, files 0600.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
DP2="${ROOT}/scripts/lib/dp-phase2-common.sh"
ACPS="${ROOT}/scripts/lib/acps_acquire.sh"
HTTP="${ROOT}/scripts/lib/http_publication_permissions.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_PROJECT_ROOT="$ROOT"
export MM_MIRROR_ROOT="${TMP}/mirror"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export MM_CLIENT_ROOT="${MM_MIRROR_ROOT}/client"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
mkdir -p "$MM_CACHE_ROOT" "$MM_CLIENT_ROOT" "$MM_DP_PHASE2_ROOT"

# shellcheck source=/dev/null
source "$COMMON"
# shellcheck source=/dev/null
source "$DP2"
# shellcheck source=/dev/null
source "$ACPS"
# shellcheck source=/dev/null
source "$HTTP"

dp2_set_version 6.6.0
CACHE="$(acps_cache_dir 6.6.0)"
acps_ensure_private_cache_dir "$CACHE" || fail "ensure private cache dir"
printf 'payload\n' >"${CACHE}/sample.dat"
printf 'partial\n' >"${CACHE}/sample.dat.part"
acps_chmod_private_file "${CACHE}/sample.dat" || fail "chmod file"
acps_chmod_private_file "${CACHE}/sample.dat.part" || fail "chmod part"
acps_write_verified_marker() { :; }  # not needed
# Write a verified-like metadata file via helper path
tmp="${CACHE}/.VERIFIED.tmp.$$"
printf 'ACPS_VERIFIED_FORMAT=1\n' >"$tmp"
acps_chmod_private_file "$tmp"
mv -f "$tmp" "${CACHE}/.VERIFIED"
acps_chmod_private_file "${CACHE}/.VERIFIED"

mode_dir="$(stat -c '%a' "$CACHE")"
mode_file="$(stat -c '%a' "${CACHE}/sample.dat")"
mode_part="$(stat -c '%a' "${CACHE}/sample.dat.part")"
mode_ver="$(stat -c '%a' "${CACHE}/.VERIFIED")"
[[ "$mode_dir" == "700" ]] || fail "cache dir mode=${mode_dir} want=700"
[[ "$mode_file" == "600" ]] || fail "cache file mode=${mode_file} want=600"
[[ "$mode_part" == "600" ]] || fail "part file mode=${mode_part} want=600"
[[ "$mode_ver" == "600" ]] || fail "verified marker mode=${mode_ver} want=600"
pass "ACPS private cache 0700/0600"

# HTTP public tree remains intentionally readable.
printf '#!/bin/bash\necho ok\n' >"${MM_CLIENT_ROOT}/stage-dp-phase2.sh"
chmod 0755 "${MM_CLIENT_ROOT}/stage-dp-phase2.sh"
mm_normalize_http_public_tree_permissions "$MM_CLIENT_ROOT" client \
  || fail "client public normalize failed"
cmode="$(stat -c '%a' "${MM_CLIENT_ROOT}/stage-dp-phase2.sh")"
[[ "$cmode" == "755" ]] || fail "public client script mode=${cmode}"
pass "HTTP public tree still readable as intended"

# Group/world bits must not appear on private cache after enforce.
chmod 0755 "$CACHE" 2>/dev/null || true
chmod 0644 "${CACHE}/sample.dat" 2>/dev/null || true
acps_enforce_private_tree_permissions "$CACHE" || fail "enforce failed"
[[ "$(stat -c '%a' "$CACHE")" == "700" ]] || fail "enforce dir"
[[ "$(stat -c '%a' "${CACHE}/sample.dat")" == "600" ]] || fail "enforce file"
pass "private cache does not remain group/world readable"

echo "ALL ACPS PRIVATE CACHE PERMISSION TESTS PASSED"
