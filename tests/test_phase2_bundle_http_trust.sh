#!/usr/bin/env bash
# tests/test_phase2_bundle_http_trust.sh — pre-trusted dp_bundle SHA256 binding (F1)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/client/stage-dp-phase2.sh"
GEN_LIB="${ROOT}/scripts/lib/phase2_helper_generation.sh"
# shellcheck source=lib/phase2_bundle_trust_fixture.sh
source "${ROOT}/tests/lib/phase2_bundle_trust_fixture.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
HTTP_PID=""
trap '[[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT

export DP_PHASE2_STAGE_LIB_ONLY=1
export DP_PHASE2_HEARTBEAT_SECONDS=1
# shellcheck disable=SC1090
source "$HELPER"

TARGET_DP_VERSION="6.6.0"
PHASE2_ARTIFACT_VERSION="6.6.0"
set_target_bundle_files "$TARGET_DP_VERSION"

make_http_bundle() {
  local payload="${1:-good-bundle-payload}"
  local rel="${WORKDIR}/http/dp-phase2/6.6.0"
  local tmpf="${WORKDIR}/files"
  mkdir -p "$rel" "$tmpf"
  for f in "${REQUIRED_BUNDLE_FILES[@]}"; do
    case "$f" in
      *.sha1|*.sha256) continue ;;
      *.sh) printf '#!/bin/bash\necho bringup\n' >"${tmpf}/$f" ;;
      *.list) seq 1 3 >"${tmpf}/$f" ;;
      *) printf '%s\n' "$payload" >"${tmpf}/$f" ;;
    esac
  done
  sha1sum "${tmpf}/aelladeb_py3_common.tar.gz" | awk '{print $1}' >"${tmpf}/aelladeb_py3_common.tar.gz.sha1"
  sha1sum "${tmpf}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}' >"${tmpf}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
  sha1sum "${tmpf}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' >"${tmpf}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  sha256sum "${tmpf}/images-6.6.0.tar" | awk '{print $1}' >"${tmpf}/images-6.6.0.tar.sha256"
  (
    cd "$tmpf"
    tar -cf "${rel}/dp_bundle_6.6.0-current.tar" "${REQUIRED_BUNDLE_FILES[@]}"
  )
  sha256sum "${rel}/dp_bundle_6.6.0-current.tar" \
    | awk '{print $1"  dp_bundle_6.6.0-current.tar"}' \
    >"${rel}/dp_bundle_6.6.0-current.tar.sha256"
  awk 'NF {print $1; exit}' "${rel}/dp_bundle_6.6.0-current.tar.sha256"
}

start_http() {
  HTTP_PORT="$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)"
  python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "${WORKDIR}/http" \
    >"${WORKDIR}/http.log" 2>&1 &
  HTTP_PID=$!
  sleep 0.3
  MIRROR_URL="http://127.0.0.1:${HTTP_PORT}"
}

run_ensure() {
  CACHE_DIR="${1:?cache dir required}"
  mkdir -p "$CACHE_DIR"
  LOCK_HELD=0
  LOCK_FD=""
  ensure_verified_bundle
}

GOOD_HASH="$(make_http_bundle good)"
start_http

echo "[test] correct pretrusted hash PASS"
CACHE="${WORKDIR}/cache-good"
EXPECTED_BUNDLE_SHA256="$GOOD_HASH"
run_ensure "$CACHE"
[[ "$ARTIFACT_CHECKSUM_RESULT" == "PASS" ]] && pass "pretrusted good hash" || fail "pretrusted good hash"

echo "[test] correct HTTP sidecar but malicious bundle FAIL"
CACHE="${WORKDIR}/cache-mal-bundle"
rm -rf "$CACHE"
printf 'malicious-bundle-body\n' >"${WORKDIR}/http/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar"
EXPECTED_BUNDLE_SHA256="$GOOD_HASH"
set +e
out="$(run_ensure "$CACHE" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "malicious bundle rejected" || fail "malicious bundle should fail"
echo "$out" | grep -q 'bundle sha256 mismatch' && pass "malicious bundle mismatch" \
  || fail "malicious bundle missing mismatch"
make_http_bundle good >/dev/null

echo "[test] malicious bundle + matching malicious sidecar FAIL (pretrusted differs)"
CACHE="${WORKDIR}/cache-mal-both"
rm -rf "$CACHE"
printf 'other-evil-payload\n' >"${WORKDIR}/http/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar"
sha256sum "${WORKDIR}/http/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar" \
  | awk '{print $1"  dp_bundle_6.6.0-current.tar"}' \
  >"${WORKDIR}/http/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar.sha256"
EXPECTED_BUNDLE_SHA256="$GOOD_HASH"
set +e
out="$(run_ensure "$CACHE" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "pretrusted blocks aligned evil sidecar" || fail "aligned evil sidecar should fail"
echo "$out" | grep -q 'SIDECAR_CROSSCHECK=FAIL' && pass "sidecar crosscheck logged" \
  || fail "missing SIDECAR_CROSSCHECK=FAIL"
make_http_bundle good >/dev/null

echo "[test] stale wrapper hash after bundle replacement FAIL"
OLD_HASH="$(make_http_bundle old-wrapper-bound)"
CLIENT="${WORKDIR}/client-stale"
mkdir -p "$CLIENT/lib"
cp -a "${ROOT}/client/stage-dp-phase2.sh" "$CLIENT/"
cp -a "${ROOT}/client/bringup_py3_dp_lifecycle.sh" "$CLIENT/"
cp -a "${ROOT}/client/lib/"*.sh "$CLIENT/lib/"
# shellcheck source=/dev/null
source "$GEN_LIB"
phase2_helper_generation_write "$CLIENT" >/dev/null
export MM_DP_PHASE2_ROOT="${WORKDIR}/published"
mkdir -p "${MM_DP_PHASE2_ROOT}/6.6.0"
cp "${WORKDIR}/http/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar" \
  "${MM_DP_PHASE2_ROOT}/6.6.0/"
cp "${WORKDIR}/http/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar.sha256" \
  "${MM_DP_PHASE2_ROOT}/6.6.0/"
phase2_upgrade_wrapper_write "$CLIENT" "$MIRROR_URL" "6.6.0" >/dev/null
STALE_B="$(awk -F"'" '/^B=/ {print $2; exit}' "$CLIENT/upgrade-phase2.sh")"
[[ "$STALE_B" == "$OLD_HASH" ]] && pass "wrapper bound to old hash" || fail "wrapper stale setup"
NEW_HASH="$(make_http_bundle replaced-bundle-v2)"
[[ "$NEW_HASH" != "$STALE_B" ]] && pass "bundle replaced on mirror" || fail "bundle replacement setup"
CACHE="${WORKDIR}/cache-stale-wrapper"
rm -rf "$CACHE"
EXPECTED_BUNDLE_SHA256="$STALE_B"
set +e
out="$(run_ensure "$CACHE" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "stale wrapper hash fails closed" || fail "stale wrapper should fail"

echo "[test] regenerated wrapper bound to new bundle PASS"
cp "${WORKDIR}/http/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar" \
  "${MM_DP_PHASE2_ROOT}/6.6.0/"
cp "${WORKDIR}/http/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar.sha256" \
  "${MM_DP_PHASE2_ROOT}/6.6.0/"
phase2_upgrade_wrapper_write "$CLIENT" "$MIRROR_URL" "6.6.0" >/dev/null
FRESH_B="$(awk -F"'" '/^B=/ {print $2; exit}' "$CLIENT/upgrade-phase2.sh")"
[[ "$FRESH_B" == "$NEW_HASH" ]] && pass "regenerated wrapper hash" || fail "regenerated wrapper hash"
CACHE="${WORKDIR}/cache-fresh-wrapper"
rm -rf "$CACHE"
EXPECTED_BUNDLE_SHA256="$FRESH_B"
run_ensure "$CACHE"
[[ "$ARTIFACT_CHECKSUM_RESULT" == "PASS" ]] && pass "fresh wrapper verifies bundle" \
  || fail "fresh wrapper verify"

echo "[test] malformed expected hash FAIL"
CACHE="${WORKDIR}/cache-bad-hash"
rm -rf "$CACHE"
EXPECTED_BUNDLE_SHA256="not-a-valid-sha256"
set +e
out="$(run_ensure "$CACHE" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "malformed pretrusted rejected" || fail "malformed pretrusted should fail"
echo "$out" | grep -q 'PRETRUSTED_BUNDLE_HASH=INVALID' && pass "invalid marker" \
  || fail "missing PRETRUSTED_BUNDLE_HASH=INVALID"

echo "[test] missing expected hash in production path FAIL CLOSED"
CACHE="${WORKDIR}/cache-missing"
rm -rf "$CACHE"
EXPECTED_BUNDLE_SHA256=""
set +e
out="$(run_ensure "$CACHE" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "missing pretrusted fail closed" || fail "missing pretrusted should fail"
echo "$out" | grep -q 'PRETRUSTED_BUNDLE_HASH=MISSING' && pass "missing marker" \
  || fail "missing PRETRUSTED_BUNDLE_HASH=MISSING"

if [[ "$FAIL" -eq 0 ]]; then
  echo "TEST_PHASE2_BUNDLE_HTTP_TRUST=PASS"
  exit 0
fi
echo "TEST_PHASE2_BUNDLE_HTTP_TRUST=FAIL"
exit 1
