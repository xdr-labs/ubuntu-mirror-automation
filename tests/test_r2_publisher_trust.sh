#!/usr/bin/env bash
# R2 OS Core trust: HTTPS + mandatory SHA256. Client signing key is not a publisher root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/client_finalization_fixture.sh
source "${ROOT}/tests/lib/client_finalization_fixture.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_PROJECT_ROOT="$ROOT"
export MM_SKIP_ROOT_CHECK=1
export MM_MIRROR_ROOT="${TMP}/mirror"
export MM_CACHE_ROOT="${TMP}/cache"
export MM_LOG_DIR="${TMP}/logs"
export MM_CONFIG_DIR="${TMP}/config"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_CLIENT_ROOT="${TMP}/client"
export LOCAL_CLIENT_SIGNING_DIR="${TMP}/client-signing"
mkdir -p "$MM_CACHE_ROOT" "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$MM_CLIENT_ROOT" \
  "$LOCAL_CLIENT_SIGNING_DIR"
: >"$MM_STATUS_FILE"
printf 'CLIENT-PUB\n' >"${LOCAL_CLIENT_SIGNING_DIR}/public.gpg"
printf 'CLIENT-PUB\n' >"${MM_CLIENT_ROOT}/public.gpg"
export CLIENT_SIGNING_PUBLIC_KEY="${LOCAL_CLIENT_SIGNING_DIR}/public.gpg"

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_install_engine.sh"

# 12. local client signing key is not accepted as implicit R2 publisher trust root.
export R2_OS_CORE_PUBLISHER_PUBLIC_KEY="$CLIENT_SIGNING_PUBLIC_KEY"
if pub="$(engine_r2_publisher_public_key)"; then
  fail "client signing key was accepted as R2 publisher key: ${pub}"
fi
unset R2_OS_CORE_PUBLISHER_PUBLIC_KEY
if pub="$(engine_r2_publisher_public_key 2>/dev/null)"; then
  fail "implicit publisher key resolved: ${pub}"
fi
pass "client signing key is not an implicit R2 publisher trust root"

# Build a CURRENT schema OS Core package via production builder + fixture tree.
client_fixture_build_selective "$TMP"
SEL="${TMP}/selective"
client_fixture_plant_aws_contract_debs "$SEL" "$ROOT" >/dev/null
OUT="${TMP}/os-core-out"
mkdir -p "$OUT"
python3 "${ROOT}/scripts/lib/os_core_package.py" build \
  --selective-root "$SEL" \
  --output-dir "$OUT" \
  --project-root "$ROOT" \
  --release-id r2trust001 \
  >/dev/null
PKG="$(find "$OUT" -maxdepth 1 -name 'ubuntu-os-core-*.tar' | head -1)"
[[ -n "$PKG" && -f "$PKG" ]] || fail "os_core build did not produce package"
sha256sum "$PKG" | awk '{print $1"  " FILENAME}' FILENAME="$(basename "$PKG")" >"${PKG}.sha256"

# 13. no-.asc + mandatory SHA256 remains valid for current schema.
set +e
out="$(python3 "${ROOT}/scripts/lib/os_core_package.py" verify --package "$PKG" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "unsigned SHA256 package verify rc=${rc} out=${out}"
printf '%s\n' "$out" | grep -q 'OUTER_SHA256=PASS' || fail "missing OUTER_SHA256=PASS"
printf '%s\n' "$out" | grep -q 'SIGNATURE=ABSENT' || fail "missing SIGNATURE=ABSENT"
pass "no-.asc + mandatory SHA256 path remains valid"

# 14. unexpected .asc without configured publisher key fails closed.
printf 'not-a-real-signature\n' >"${PKG}.sha256.asc"
set +e
out="$(python3 "${ROOT}/scripts/lib/os_core_package.py" verify --package "$PKG" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "unexpected .asc without publisher key succeeded"
printf '%s\n' "$out" | grep -q 'publisher_public_key_unconfigured\|SIGNATURE_PRESENT_BUT_NO_PUBLIC_KEY' \
  || fail "missing fail-closed trust error: ${out}"
pass "unexpected .asc without publisher key fails closed"

# Passing the client signing key as --public-key is refused by engine helper.
export R2_OS_CORE_PUBLISHER_PUBLIC_KEY="$CLIENT_SIGNING_PUBLIC_KEY"
if engine_r2_publisher_public_key >/dev/null 2>&1; then
  fail "engine still treats client signing key as publisher"
fi
pass "engine refuses client signing key as R2 publisher"

# Source must not default OS_CORE_PUBLIC_KEY from client signing.
if grep -n 'OS_CORE_PUBLIC_KEY="$CLIENT_SIGNING_PUBLIC_KEY"' \
  "${ROOT}/scripts/install-dp-upgrade-mirror.sh"; then
  fail "install still copies CLIENT_SIGNING_PUBLIC_KEY into OS_CORE_PUBLIC_KEY"
fi
pass "install does not copy client signing key into OS_CORE_PUBLIC_KEY"

echo "ALL test_r2_publisher_trust checks passed"
