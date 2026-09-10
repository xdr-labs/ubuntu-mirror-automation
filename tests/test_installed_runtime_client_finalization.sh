#!/usr/bin/env bash
# tests/test_installed_runtime_client_finalization.sh
# Targeted installed-runtime four-hop smoke: authoritative manifest runtime,
# production-shaped selective fixture, unreachable mirror URL, real builders,
# local signing, staged checksum, atomic publish. HTTP verify skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/client_finalization_fixture.sh
source "${ROOT}/tests/lib/client_finalization_fixture.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== test_installed_runtime_client_finalization ==="
echo "TARGETED_INSTALLED_RUNTIME_ONLY=YES"

MIRROR_URL="http://192.0.2.99"  # RFC 5737 — intentionally unreachable

client_fixture_build_selective "$WORKDIR"
client_fixture_install_runtime "$ROOT" "$WORKDIR"

SEL="$CLIENT_FIXTURE_SELECTIVE"
CLIENT_ROOT="$CLIENT_FIXTURE_CLIENT_ROOT"
RUNTIME_ROOT="$CLIENT_FIXTURE_RUNTIME_ROOT"
SIGNING_DIR="$CLIENT_FIXTURE_SIGNING_DIR"
MIRROR_ROOT="$CLIENT_FIXTURE_MIRROR_ROOT"
CACHE="${MIRROR_ROOT}/.install-cache"

# Confirm manifest-installed critical modules (no wildcard leftovers required).
[[ -f "${RUNTIME_ROOT}/scripts/lib/client_build_repository.py" ]] \
  && pass "CLIENT_BUILD_REPOSITORY_INSTALLED=YES" \
  || fail "CLIENT_BUILD_REPOSITORY_INSTALLED=NO"
[[ -f "${RUNTIME_ROOT}/scripts/lib/atomic_dir_swap.py" ]] \
  && pass "ATOMIC_DIR_SWAP_INSTALLED=YES" \
  || fail "ATOMIC_DIR_SWAP_INSTALLED=NO"

# Ensure fixture did not copy non-manifest python (e.g. selective_mirror.py)
if [[ -f "${RUNTIME_ROOT}/scripts/lib/selective_mirror.py" ]]; then
  fail "non-manifest selective_mirror.py present (wildcard leak?)"
else
  pass "no non-manifest python leak"
fi

LOG="${WORKDIR}/rebuild-installed-runtime.log"
set +e
env \
  MIRROR_HTTP_URL="$MIRROR_URL" \
  RESOLVED_MIRROR_BASE_URL="$MIRROR_URL" \
  RESOLVED_MIRROR_HOST_IPV4="192.0.2.99" \
  LOCAL_CLIENT_SIGNING_DIR="$SIGNING_DIR" \
  CLIENT_HTTP_ROOT="$CLIENT_ROOT" \
  SELECTIVE_ROOT="$SEL" \
  BASE_PATH="$MIRROR_ROOT" \
  CACHE_ROOT="$CACHE" \
  CONTENT_SOURCE=local-fs \
  MM_HERMETIC_TEST_MODE=1 \
  CLIENT_BUILD_PIN_URL_ONLY=1 \
  SKIP_HTTP_VERIFY=1 \
  REQUIRE_SELECTIVE_READY=1 \
  bash "${RUNTIME_ROOT}/scripts/rebuild-publish-clients.sh" \
  >"$LOG" 2>&1
RC=$?
set -e

echo "----- rebuild log (tail) -----"
tail -60 "$LOG" || true

check_log() {
  local pat="$1"
  if grep -q "$pat" "$LOG"; then
    pass "$pat"
    return 0
  fi
  fail "missing $pat"
  return 1
}

if [[ "$RC" -ne 0 ]]; then
  fail "rebuild-publish-clients rc=${RC}"
fi

check_log 'CLIENT_BUILD_CONTENT_SOURCE=LOCAL_FILESYSTEM'
check_log 'CLIENT_BUILD_NETWORK_REQUIRED=NO'
check_log 'CLIENT_SET_BUILD_COMPLETE=YES'
check_log 'CLIENT_SET_SIGN_COMPLETE=YES'
check_log 'CLIENT_SET_PREPUBLISH_VERIFY=PASS'
check_log 'CLIENT_SET_ATOMIC_SWAP=PASS'
check_log 'CLIENT_SET_ON_DISK_READY=PASS'
check_log 'REBUILD_PUBLISH_CLIENTS=PASS'
check_log 'CLIENT_PUBLIC_BINARY_KEYRING_BUILD=PASS'
check_log 'CLIENT_PUBLIC_BINARY_KEYRING_FORMAT=OPENPGP_BINARY'
check_log 'CLIENT_PUBLIC_BINARY_KEYRING_FINGERPRINT=PASS'
check_log 'CLIENT_MANIFEST_GPGV_VERIFY=PASS hop=xenial-to-bionic'
check_log 'CLIENT_MANIFEST_GPGV_VERIFY=PASS hop=bionic-to-focal'
check_log 'CLIENT_MANIFEST_GPGV_VERIFY=PASS hop=focal-to-jammy'
check_log 'CLIENT_MANIFEST_GPGV_VERIFY=PASS hop=jammy-to-noble'

for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  check_log "CLIENT_BUILD_COMPLETE hop=${hop}"
  [[ -f "${CLIENT_ROOT}/dp-offline-upgrade-${hop}.sh" ]] \
    && pass "published ${hop}" \
    || fail "missing published ${hop}"
done

[[ -f "${CLIENT_ROOT}/public-keyring.gpg" ]] \
  && pass "published public-keyring.gpg" \
  || fail "missing public-keyring.gpg"
[[ -f "${CLIENT_ROOT}/public.gpg" ]] \
  && pass "published public.gpg (armor compat)" \
  || fail "missing public.gpg"
head -n1 "${CLIENT_ROOT}/public.gpg" | grep -qx -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' \
  && pass "ARMORED_KEY_FORMAT=ASCII_ARMOR" \
  || fail "public.gpg not armored"
if head -n1 "${CLIENT_ROOT}/public-keyring.gpg" | grep -q 'BEGIN PGP'; then
  fail "public-keyring.gpg is armored"
else
  pass "BINARY_KEYRING_FORMAT=OPENPGP_BINARY"
fi

# Private key must not appear under HTTP client root
if [[ -f "${CLIENT_ROOT}/private.gpg" ]]; then
  fail "PRIVATE_KEY_HTTP_PUBLISHED=YES"
else
  pass "PRIVATE_KEY_HTTP_PUBLISHED=NO"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "REAL_FOUR_HOP_INSTALLED_RUNTIME_BUILD=PASS"
  echo "INSTALLED_RUNTIME_FOUR_HOP_BUILD=PASS"
  exit 0
fi
echo "REAL_FOUR_HOP_INSTALLED_RUNTIME_BUILD=FAIL"
echo "INSTALLED_RUNTIME_FOUR_HOP_BUILD=FAIL"
exit 1
