#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_SKIP_ROOT_CHECK=1
export MM_HERMETIC_TEST_MODE=1
export MM_ALLOW_ARBITRARY_TEST_ROOTS=0
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"

assert_fail() {
  local label="$1"; shift
  set +e
  "$@" >/dev/null 2>&1
  local rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || { echo "FAIL expected reject: $label"; exit 1; }
  echo "PASS reject $label"
}

approved="$TMP/cache/client-build"
mkdir -p "$approved/gen1"

assert_fail root mm_assert_safe_destructive_path "/" "$approved" ARTIFACT_DIR
assert_fail varlib mm_assert_safe_destructive_path "/var/lib" "$approved" ARTIFACT_DIR
assert_fail outside mm_assert_safe_destructive_path "/tmp/other/gen" "$approved" ARTIFACT_DIR

# symlink escape
mkdir -p "$TMP/outside/secret" "$TMP/cache"
ln -sfn "$TMP/outside" "$TMP/cache/client-build-link"
assert_fail symlink_escape mm_assert_safe_destructive_path \
  "$TMP/cache/client-build-link/secret" "$approved" ARTIFACT_DIR

mm_assert_safe_destructive_path "$approved/gen1" "$approved" ARTIFACT_DIR
echo "PASS valid production-shaped path"

# rebuild-publish-clients local guard via env override
export BASE_PATH="$TMP/mirror"
export CACHE_ROOT="$TMP/mirror/.install-cache"
export CLIENT_HTTP_ROOT="$TMP/mirror/client"
export SELECTIVE_ROOT="$TMP/mirror/selective"
mkdir -p "$SELECTIVE_ROOT/state" "$CLIENT_HTTP_ROOT" "$CACHE_ROOT/client-build"
printf 'READY\n' >"$SELECTIVE_ROOT/state/READY"
# Minimal skip path: invoke guard function by extracting from script
# shellcheck source=/dev/null
source /dev/null
bash -c '
  ROOT="'"$ROOT"'"
  source "'"$ROOT"'/scripts/lib/mirror_host_ip.sh"
  source "'"$ROOT"'/scripts/lib/client_mirror_gates.sh"
  source "'"$ROOT"'/scripts/lib/local_client_signing.sh"
  source "'"$ROOT"'/scripts/lib/http_publication_permissions.sh"
  # Load only the guard by evaluating the function from the script head is hard;
  # call mm helper instead.
' 

export ARTIFACT_DIR=/
set +e
out="$(
  BASE_PATH="$TMP/mirror" \
  CACHE_ROOT="$TMP/mirror/.install-cache" \
  CLIENT_HTTP_ROOT="$TMP/mirror/client" \
  SELECTIVE_ROOT="$TMP/mirror/selective" \
  ARTIFACT_DIR=/ \
  MM_HERMETIC_TEST_MODE=1 \
  REQUIRE_SELECTIVE_READY=0 \
  SKIP_BUILD=1 \
  SKIP_DEPLOY=1 \
  SKIP_HTTP_VERIFY=1 \
  bash "${ROOT}/scripts/rebuild-publish-clients.sh" --skip-build --skip-deploy --skip-http-verify 2>&1
)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL ARTIFACT_DIR=/ accepted"; echo "$out"; exit 1; }
echo "$out" | grep -q 'DESTRUCTIVE_PATH=FAIL\|ARTIFACT_DIR_UNSAFE' \
  || { echo "FAIL missing unsafe marker"; echo "$out"; exit 1; }
echo "PASS ARTIFACT_DIR=/ rejected by rebuild-publish-clients"

# CLIENT_HTTP_ROOT must not accept an unrelated tree in production
set +e
out="$(
  BASE_PATH="$TMP/mirror" \
  CACHE_ROOT="$TMP/mirror/.install-cache" \
  CLIENT_HTTP_ROOT="$TMP/unrelated/client" \
  SELECTIVE_ROOT="$TMP/mirror/selective" \
  ARTIFACT_DIR="$TMP/mirror/.install-cache/client-build/genx" \
  MM_HERMETIC_TEST_MODE=0 \
  REQUIRE_SELECTIVE_READY=1 \
  SKIP_BUILD=1 \
  SKIP_DEPLOY=1 \
  SKIP_HTTP_VERIFY=1 \
  bash "${ROOT}/scripts/rebuild-publish-clients.sh" --skip-build --skip-deploy --skip-http-verify 2>&1
)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL unrelated CLIENT_HTTP_ROOT accepted in production"; echo "$out"; exit 1; }
echo "$out" | grep -qE 'CLIENT_HTTP_ROOT=FAIL|CLIENT_HTTP_ROOT_UNSAFE|outside_approved_root|must_equal_BASE_PATH' \
  || { echo "FAIL missing CLIENT_HTTP_ROOT containment marker"; echo "$out"; exit 1; }
echo "PASS unrelated CLIENT_HTTP_ROOT rejected in production"

# Valid BASE_PATH/client is accepted (guard only; skip build/deploy)
mkdir -p "$TMP/mirror/client" "$TMP/mirror/selective/state" "$TMP/mirror/.install-cache/client-build"
printf 'READY\n' >"$TMP/mirror/selective/state/READY"
set +e
out="$(
  BASE_PATH="$TMP/mirror" \
  CACHE_ROOT="$TMP/mirror/.install-cache" \
  CLIENT_HTTP_ROOT="$TMP/mirror/client" \
  SELECTIVE_ROOT="$TMP/mirror/selective" \
  ARTIFACT_DIR="$TMP/mirror/.install-cache/client-build/geny" \
  MM_HERMETIC_TEST_MODE=1 \
  REQUIRE_SELECTIVE_READY=0 \
  SKIP_BUILD=1 \
  SKIP_DEPLOY=1 \
  SKIP_HTTP_VERIFY=1 \
  bash "${ROOT}/scripts/rebuild-publish-clients.sh" --skip-build --skip-deploy --skip-http-verify 2>&1
)"
rc=$?
set -e
# May fail later for missing selective content; must not fail the CLIENT_HTTP_ROOT guard.
echo "$out" | grep -qE 'CLIENT_HTTP_ROOT=FAIL|CLIENT_HTTP_ROOT_UNSAFE' \
  && { echo "FAIL valid CLIENT_HTTP_ROOT rejected"; echo "$out"; exit 1; }
echo "PASS valid BASE_PATH/client not rejected by containment guard"

echo "PASS test_destructive_path_guards"
