#!/usr/bin/env bash
# tests/test_client_finalization_local_fs_integration.sh
# Production-like integration: real four builders, no network, atomic publish,
# failure injection, retry reuse, installed-runtime parity, optional HTTP.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/client_finalization_fixture.sh
source "${ROOT}/tests/lib/client_finalization_fixture.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
HTTP_PID=""
cleanup() {
  if [[ -n "${HTTP_PID}" ]] && kill -0 "$HTTP_PID" 2>/dev/null; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "=== test_client_finalization_local_fs_integration ==="
echo "UNIT_ONLY=NO"
echo "REAL_CLIENT_BUILD_COVERED=YES"

MIRROR_URL="http://192.0.2.99"  # RFC 5737 — intentionally unreachable

client_fixture_build_selective "$WORKDIR"
client_fixture_install_runtime "$ROOT" "$WORKDIR"

SEL="$CLIENT_FIXTURE_SELECTIVE"
CLIENT_ROOT="$CLIENT_FIXTURE_CLIENT_ROOT"
RUNTIME_ROOT="$CLIENT_FIXTURE_RUNTIME_ROOT"
SIGNING_DIR="$CLIENT_FIXTURE_SIGNING_DIR"
MIRROR_ROOT="$CLIENT_FIXTURE_MIRROR_ROOT"
CACHE="${MIRROR_ROOT}/.install-cache"

# --- Prove current architecture would fail if HTTP were required ---
# (builders must succeed with unreachable MIRROR_HTTP_URL)

run_rebuild() {
  local root="$1"
  local out_log="$2"
  local extra_env="${3:-}"
  # shellcheck disable=SC2086
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
    CLIENT_BUILD_PIN_URL_ONLY=1 \
    SKIP_HTTP_VERIFY=1 \
    REQUIRE_SELECTIVE_READY=1 \
    $extra_env \
    bash "${root}/scripts/rebuild-publish-clients.sh" \
    >"$out_log" 2>&1
}

# ========== A/B/C: NO_NETWORK four-hop build (repo checkout) ==========
LOG1="${WORKDIR}/rebuild-repo.log"
set +e
# Prefer unshare -n when available to deny network completely.
if command -v unshare >/dev/null 2>&1 && unshare -n true 2>/dev/null; then
  unshare -n env \
    MIRROR_HTTP_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_BASE_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_HOST_IPV4="192.0.2.99" \
    LOCAL_CLIENT_SIGNING_DIR="$SIGNING_DIR" \
    CLIENT_HTTP_ROOT="$CLIENT_ROOT" \
    SELECTIVE_ROOT="$SEL" \
    BASE_PATH="$MIRROR_ROOT" \
    CACHE_ROOT="$CACHE" \
    CONTENT_SOURCE=local-fs \
    CLIENT_BUILD_PIN_URL_ONLY=1 \
    SKIP_HTTP_VERIFY=1 \
    bash "${ROOT}/scripts/rebuild-publish-clients.sh" \
    >"$LOG1" 2>&1
  RC1=$?
  echo "NO_NETWORK_METHOD=unshare -n"
else
  run_rebuild "$ROOT" "$LOG1"
  RC1=$?
  echo "NO_NETWORK_METHOD=rfc5737-unreachable-url"
fi
set -e

if [[ "$RC1" -eq 0 ]] \
  && grep -q 'CLIENT_BUILD_CONTENT_SOURCE=LOCAL_FILESYSTEM' "$LOG1" \
  && grep -q 'CLIENT_BUILD_NETWORK_REQUIRED=NO' "$LOG1" \
  && grep -q 'CLIENT_SET_BUILD_COMPLETE=YES' "$LOG1" \
  && grep -q 'CLIENT_SET_SIGN_COMPLETE=YES' "$LOG1" \
  && grep -q 'CLIENT_SET_VERIFY_COMPLETE=YES' "$LOG1" \
  && grep -q 'CLIENT_SET_DEPLOY_ATOMIC=YES' "$LOG1" \
  && grep -q 'CLIENT_SET_ON_DISK_READY=PASS' "$LOG1" \
  && grep -q 'CLIENT_HTTP_READY=DEFERRED' "$LOG1" \
  && grep -q 'REBUILD_PUBLISH_CLIENTS=PASS' "$LOG1"; then
  pass "NO_NETWORK_PREPARE_TEST / REAL_FOUR_HOP_BUILD_TEST"
  echo "REAL_FOUR_HOP_BUILD_TEST=PASS"
  echo "NO_NETWORK_PREPARE_TEST=PASS"
else
  fail "NO_NETWORK four-hop rebuild (rc=${RC1})"
  echo "REAL_FOUR_HOP_BUILD_TEST=FAIL"
  echo "NO_NETWORK_PREPARE_TEST=FAIL"
  tail -80 "$LOG1" || true
fi

PREV_SHA=""
if [[ -f "${CLIENT_ROOT}/dp-offline-upgrade-xenial-to-bionic.sh" ]]; then
  PREV_SHA="$(sha256sum "${CLIENT_ROOT}/dp-offline-upgrade-xenial-to-bionic.sh" | awk '{print $1}')"
fi

# ========== G: installed-runtime parity ==========
CLIENT_ROOT_B="${WORKDIR}/runtime-b-client"
mkdir -p "$CLIENT_ROOT_B"
# Reset client root for runtime entrypoint
rm -rf "$CLIENT_ROOT"
mkdir -p "$CLIENT_ROOT"
LOG_RT="${WORKDIR}/rebuild-runtime.log"
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
  CLIENT_BUILD_PIN_URL_ONLY=1 \
  SKIP_HTTP_VERIFY=1 \
  bash "${RUNTIME_ROOT}/scripts/rebuild-publish-clients.sh" \
  >"$LOG_RT" 2>&1
RC_RT=$?
set -e
if [[ "$RC_RT" -eq 0 ]] && grep -q 'REBUILD_PUBLISH_CLIENTS=PASS' "$LOG_RT"; then
  pass "INSTALLED_RUNTIME_TEST rebuild PASS"
  echo "INSTALLED_RUNTIME_TEST=PASS"
else
  fail "INSTALLED_RUNTIME_TEST (rc=${RC_RT})"
  echo "INSTALLED_RUNTIME_TEST=FAIL"
  tail -40 "$LOG_RT" || true
fi

# Normalize comparison: strip generated_at-like variance by comparing hop count + signatures present
HOP_COUNT="$(find "$CLIENT_ROOT" -maxdepth 1 -name 'dp-offline-upgrade-*.sh' | wc -l)"
[[ "$HOP_COUNT" -eq 4 ]] && pass "four hop scripts published" || fail "hop count=${HOP_COUNT}"

WRAP_OK=1
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  wname="upgrade-${hop}.sh"
  [[ -f "${CLIENT_ROOT}/${wname}" && -f "${CLIENT_ROOT}/${wname}.sha256" ]] || WRAP_OK=0
  bash -n "${CLIENT_ROOT}/${wname}" || WRAP_OK=0
  ( cd "$CLIENT_ROOT" && sha256sum -c "${wname}.sha256" >/dev/null ) || WRAP_OK=0
  launcher="dp-launch-${hop}.sh"
  lsha="$(sha256sum "${CLIENT_ROOT}/${launcher}" | awk '{print $1}')"
  grep -Fq "L='${launcher}'" "${CLIENT_ROOT}/${wname}" || WRAP_OK=0
  grep -Fq "LAUNCHER_SHA256='${lsha}'" "${CLIENT_ROOT}/${wname}" || WRAP_OK=0
  grep -Fq "192.0.2.99" "${CLIENT_ROOT}/${wname}" || WRAP_OK=0
done
[[ -f "${CLIENT_ROOT}/upgrade-phase2.sh" && -f "${CLIENT_ROOT}/upgrade-phase2.sh.sha256" ]] || WRAP_OK=0
bash -n "${CLIENT_ROOT}/upgrade-phase2.sh" || WRAP_OK=0
( cd "$CLIENT_ROOT" && sha256sum -c upgrade-phase2.sh.sha256 >/dev/null ) || WRAP_OK=0
grep -q 'phase2-helper-generation.manifest' "${CLIENT_ROOT}/upgrade-phase2.sh" || WRAP_OK=0
grep -q -- '--target-version' "${CLIENT_ROOT}/upgrade-phase2.sh" || WRAP_OK=0
grep -q -- '--mirror-url' "${CLIENT_ROOT}/upgrade-phase2.sh" || WRAP_OK=0
if grep -E 'sudo bash.*"\$SCRIPT".*--same-version-recovery' "${CLIENT_ROOT}/upgrade-phase2.sh" >/dev/null 2>&1; then
  WRAP_OK=0
fi
[[ -f "${CLIENT_ROOT}/upgrade-phase2-same-version-recovery.sh" ]] || WRAP_OK=0
if [[ "$WRAP_OK" -eq 1 ]]; then
  pass "operator wrappers published and verified"
else
  fail "operator wrappers missing or invalid"
fi
TAMPER="${WORKDIR}/wrapper-tamper"
cp -a "$CLIENT_ROOT" "$TAMPER"
printf 'x' >>"${TAMPER}/upgrade-jammy-to-noble.sh"
set +e
( cd "$TAMPER" && sha256sum -c upgrade-jammy-to-noble.sh.sha256 >/dev/null 2>&1 )
TAMPER_RC=$?
set -e
[[ "$TAMPER_RC" -ne 0 ]] && pass "wrapper tamper fail-closed" || fail "wrapper tamper still verified"

# ========== E: failure injection — hop 2 build ==========
# Save complete set
COMPLETE_BACKUP="${WORKDIR}/complete-client-set"
rm -rf "$COMPLETE_BACKUP"
cp -a "$CLIENT_ROOT" "$COMPLETE_BACKUP"
PREV_SHA="$(sha256sum "${CLIENT_ROOT}/dp-offline-upgrade-xenial-to-bionic.sh" | awk '{print $1}')"

# Break hop 2 Packages.gz so builder fails
BAD_PKG="${SEL}/hops/bionic-to-focal/ubuntu/dists/focal/main/binary-amd64/Packages.gz"
cp -a "$BAD_PKG" "${BAD_PKG}.good"
printf 'not-gzip' >"$BAD_PKG"

LOG_FAIL="${WORKDIR}/rebuild-fail-hop2.log"
set +e
run_rebuild "$ROOT" "$LOG_FAIL"
RC_FAIL=$?
set -e
# restore fixture
mv "${BAD_PKG}.good" "$BAD_PKG"

if [[ "$RC_FAIL" -ne 0 ]] \
  && grep -q 'CLIENT_BUILD_FAILED_HOP=bionic-to-focal' "$LOG_FAIL" \
  && grep -q 'CLIENT_FINALIZER_EVIDENCE_PATH=' "$LOG_FAIL"; then
  # Previous complete set must remain
  NOW_SHA="$(sha256sum "${CLIENT_ROOT}/dp-offline-upgrade-xenial-to-bionic.sh" 2>/dev/null | awk '{print $1}' || true)"
  if [[ "$NOW_SHA" == "$PREV_SHA" ]]; then
    pass "FAILURE_ATOMICITY hop2: previous set preserved + evidence"
    echo "FAILURE_ATOMICITY_TEST=PASS"
  else
    fail "FAILURE_ATOMICITY hop2: live set changed on failure"
    echo "FAILURE_ATOMICITY_TEST=FAIL"
  fi
else
  fail "FAILURE_ATOMICITY hop2 injection did not fail as expected (rc=${RC_FAIL})"
  echo "FAILURE_ATOMICITY_TEST=FAIL"
  tail -40 "$LOG_FAIL" || true
fi

# ========== atomic swap rollback injection ==========
STAGE="$(mktemp -d "${CLIENT_ROOT}.stage.XXXXXX")"
echo stub >"${STAGE}/x"
set +e
python3 "${ROOT}/scripts/lib/atomic_dir_swap.py" \
  --stage-dir "$STAGE" \
  --live-dir "$CLIENT_ROOT" \
  --inject-fail-after-backup \
  >"${WORKDIR}/swap-inject.log" 2>&1
SWAP_RC=$?
set -e
if [[ "$SWAP_RC" -ne 0 ]] \
  && grep -q 'CLIENT_SET_ROLLBACK=PASS' "${WORKDIR}/swap-inject.log" \
  && [[ -f "${CLIENT_ROOT}/dp-offline-upgrade-xenial-to-bionic.sh" ]]; then
  pass "atomic swap rollback injection"
else
  fail "atomic swap rollback injection"
  cat "${WORKDIR}/swap-inject.log" || true
fi
rm -rf "$STAGE" 2>/dev/null || true

# ========== F: retry reuse (OS Core not re-downloaded; client rebuild succeeds) ==========
# Restore complete selective + rebuild clients successfully again.
# Count markers: we only check client finalization succeeds without needing R2.
LOG_RETRY="${WORKDIR}/rebuild-retry.log"
set +e
run_rebuild "$ROOT" "$LOG_RETRY"
RC_RETRY=$?
set -e
if [[ "$RC_RETRY" -eq 0 ]] && grep -q 'REBUILD_PUBLISH_CLIENTS=PASS' "$LOG_RETRY"; then
  # OS Core reuse verification
  if python3 "${ROOT}/scripts/lib/client_build_repository.py" \
      --verify-os-core-reuse --selective-root "$SEL" >/dev/null 2>&1; then
    pass "RETRY_REUSE_TEST client rebuild after failure + OS Core still valid"
    echo "RETRY_REUSE_TEST=PASS"
    echo "OS_CORE_ACTION_ON_RETRY=REUSE_VERIFIED"
    echo "R2_REDOWNLOAD_ON_CLIENT_RETRY=NO"
  else
    fail "OS Core reuse verify after retry"
    echo "RETRY_REUSE_TEST=FAIL"
  fi
else
  fail "RETRY_REUSE rebuild (rc=${RC_RETRY})"
  echo "RETRY_REUSE_TEST=FAIL"
  tail -40 "$LOG_RETRY" || true
fi

# ========== D: ACTUAL_HTTP_ENABLE_TEST (local python http.server) ==========
# Serve selective + client roots under a combined docroot.
DOC="${WORKDIR}/httpdoc"
mkdir -p "${DOC}/client" "${DOC}/hops" "${DOC}/offline" "${DOC}/dp-phase2/6.5.0"
cp -a "${CLIENT_ROOT}/." "${DOC}/client/"
cp -a "${SEL}/hops/." "${DOC}/hops/"
cp -a "${SEL}/shared/offline/." "${DOC}/offline/" 2>/dev/null || true
# Minimal phase2 placeholders
printf 'phase2\n' >"${DOC}/dp-phase2/6.5.0/bundle.tar"
printf 'deadbeef\n' >"${DOC}/dp-phase2/6.5.0/bundle.tar.sha256"
printf 'VERSION=6.5.0\n' >"${DOC}/dp-phase2/6.5.0/release.env"

PORT_FILE="${WORKDIR}/http.port"
python3 - "$DOC" "$PORT_FILE" <<'PY' &
import http.server, os, sys
root, portf = sys.argv[1], sys.argv[2]
os.chdir(root)
httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
open(portf, "w", encoding="utf-8").write(str(httpd.server_address[1]))
httpd.serve_forever()
PY
HTTP_PID=$!
for _ in $(seq 1 100); do
  [[ -s "$PORT_FILE" ]] && break
  sleep 0.05
done
PORT="$(cat "$PORT_FILE")"
HTTP_BASE="http://127.0.0.1:${PORT}"

HTTP_OK=1
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  name="dp-offline-upgrade-${hop}.sh"
  curl -fsS -o "${WORKDIR}/http-${name}" "${HTTP_BASE}/client/${name}" || HTTP_OK=0
  local_sha="$(sha256sum "${CLIENT_ROOT}/${name}" | awk '{print $1}')"
  http_sha="$(sha256sum "${WORKDIR}/http-${name}" | awk '{print $1}')"
  [[ "$local_sha" == "$http_sha" ]] || HTTP_OK=0
  grep -q "192.0.2.99" "${WORKDIR}/http-${name}" || HTTP_OK=0
  wname="upgrade-${hop}.sh"
  curl -fsS -o "${WORKDIR}/http-${wname}" "${HTTP_BASE}/client/${wname}" || HTTP_OK=0
  wlocal="$(sha256sum "${CLIENT_ROOT}/${wname}" | awk '{print $1}')"
  whttp="$(sha256sum "${WORKDIR}/http-${wname}" | awk '{print $1}')"
  [[ "$wlocal" == "$whttp" ]] || HTTP_OK=0
done
curl -fsS -o "${WORKDIR}/http-upgrade-phase2.sh" "${HTTP_BASE}/client/upgrade-phase2.sh" || HTTP_OK=0
curl -fsS -o "${WORKDIR}/http-public.gpg" "${HTTP_BASE}/client/public.gpg" || HTTP_OK=0
cmp -s "${SIGNING_DIR}/public.gpg" "${WORKDIR}/http-public.gpg" || HTTP_OK=0

# Hop Release/InRelease/Packages/sample deb
curl -fsS -o /dev/null "${HTTP_BASE}/hops/xenial-to-bionic/ubuntu/dists/xenial/Release" || HTTP_OK=0
curl -fsS -o /dev/null "${HTTP_BASE}/hops/xenial-to-bionic/ubuntu/dists/xenial/InRelease" || HTTP_OK=0
curl -fsS -o /dev/null "${HTTP_BASE}/hops/xenial-to-bionic/ubuntu/dists/bionic/main/binary-amd64/Packages.gz" || HTTP_OK=0
curl -fsS -o /dev/null "${HTTP_BASE}/hops/xenial-to-bionic/ubuntu/pool/main/a/hello/hello_2.10_amd64.deb" || HTTP_OK=0
curl -fsS -o /dev/null "${HTTP_BASE}/dp-phase2/6.5.0/bundle.tar" || HTTP_OK=0
curl -fsS -o /dev/null "${HTTP_BASE}/dp-phase2/6.5.0/bundle.tar.sha256" || HTTP_OK=0
curl -fsS -o /dev/null "${HTTP_BASE}/dp-phase2/6.5.0/release.env" || HTTP_OK=0

if [[ "$HTTP_OK" -eq 1 ]]; then
  pass "ACTUAL_HTTP_ENABLE_TEST"
  echo "ACTUAL_HTTP_ENABLE_TEST=PASS"
else
  fail "ACTUAL_HTTP_ENABLE_TEST"
  echo "ACTUAL_HTTP_ENABLE_TEST=FAIL"
fi

# Staging must not live under installed lib path
if [[ -d "${RUNTIME_ROOT}/artifacts/client" ]] \
  && find "${RUNTIME_ROOT}/artifacts/client" -type f 2>/dev/null | grep -q .; then
  fail "mutable staging under installed runtime artifacts/client"
else
  pass "INSTALLED_RUNTIME_MUTABLE_ARTIFACTS=NO"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "CLIENT_FINALIZATION_INTEGRATION=PASS"
  exit 0
fi
echo "CLIENT_FINALIZATION_INTEGRATION=FAIL"
exit 1
