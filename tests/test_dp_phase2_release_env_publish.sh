#!/usr/bin/env bash
# tests/test_dp_phase2_release_env_publish.sh — release.env publisher mode/secret/cleanup/HTTP
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISHER="${ROOT}/scripts/update-dp-phase2-release-env-atomic.sh"
HELPERS_ONLY="${ROOT}/scripts/deploy-dp-phase2-helpers-only.sh"
HELPER="${ROOT}/client/stage-dp-phase2.sh"
COMMON="${ROOT}/scripts/lib/dp-phase2-common.sh"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
HTTP_PID=""
cleanup_all() {
  [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup_all EXIT

# shellcheck source=../scripts/lib/dp-phase2-common.sh
source "$COMMON"

make_fixture() {
  local base="$1"
  local mode="${2:-600}"
  local ver="${3:-6.6.0}"
  local current="${base}/${ver}/current"
  mkdir -p "$current" "${base}/ready-state"
  printf 'READY_FIXTURE\n' >"${base}/ready-state/READY"
  # Stable bundle stub (inode/size tracked; never a real 30GB artifact)
  printf 'bundle-stub\n' >"${current}/dp_bundle_${ver}-current.tar"
  cat >"${current}/release.env" <<EOF
TARGET_DP_VERSION=${ver}
PHASE2_ARTIFACT_VERSION=${ver}
DP_PHASE2_VERSION=${ver}
STABLE_BUNDLE_NAME=dp_bundle_${ver}-current.tar
FILE_COUNT=9
VERIFICATION_RESULT=PASS
RELEASE_ID=test-release-1
CREATED_AT=2026-07-26T15:59:11Z
EOF
  chmod "$mode" "${current}/release.env"
}

run_publisher() {
  local root="$1"
  local ver="${2:-6.6.0}"
  shift 2 || true
  DP_PHASE2_SKIP_ROOT_CHECK=1 \
    DP_PHASE2_ROOT="$root" \
    READY_PATH="${root}/ready-state/READY" \
    "$@" \
    bash "$PUBLISHER" "$ver"
}

echo "[test] A. syntax"
bash -n "$PUBLISHER" && pass "publisher bash -n" || fail "publisher bash -n"
bash -n "$HELPERS_ONLY" && pass "helpers-only bash -n" || fail "helpers-only bash -n"
bash -n "${ROOT}/scripts/deploy-stage-dp-phase2-client-atomic.sh" && pass "deploy-helpers bash -n" || fail "deploy-helpers bash -n"
bash -n "$HELPER" && pass "canonical helper bash -n" || fail "canonical helper bash -n"
bash -n "${ROOT}/client/stage-dp-phase2-6.6.0.sh" && pass "compat helper bash -n" || fail "compat helper bash -n"

# Ambiguous VERSION= must not remain in publisher
if grep -nE '^VERSION=' "$PUBLISHER"; then
  fail "publisher still has ambiguous VERSION="
else
  pass "publisher has no ambiguous VERSION="
fi
grep -q 'TARGET_DP_VERSION=' "$PUBLISHER" && pass "TARGET_DP_VERSION variable present" || fail "TARGET_DP_VERSION missing"

echo "[test] B. mode regression"
for start_mode in 600 644; do
  fx="${WORKDIR}/mode-${start_mode}"
  make_fixture "$fx" "$start_mode"
  before_sha="$(sha256sum "${fx}/ready-state/READY" | awk '{print $1}')"
  before_inode="$(stat -c '%i %s' "${fx}/6.6.0/current/dp_bundle_6.6.0-current.tar")"
  out="$(run_publisher "$fx" 6.6.0)"
  echo "$out" | grep -q 'RELEASE_ENV_MODE=644' && pass "mode start=${start_mode} -> 644 reported" \
    || fail "mode start=${start_mode} report"
  [[ "$(stat -c '%a' "${fx}/6.6.0/current/release.env")" == "644" ]] \
    && pass "mode start=${start_mode} -> 644 on disk" \
    || fail "mode start=${start_mode} disk"
  after_sha="$(sha256sum "${fx}/ready-state/READY" | awk '{print $1}')"
  after_inode="$(stat -c '%i %s' "${fx}/6.6.0/current/dp_bundle_6.6.0-current.tar")"
  [[ "$before_sha" == "$after_sha" ]] && pass "READY unchanged mode=${start_mode}" || fail "READY changed"
  [[ "$before_inode" == "$after_inode" ]] && pass "bundle inode/size unchanged mode=${start_mode}" \
    || fail "bundle changed"
done

# umask 077 must still yield 644
fx="${WORKDIR}/umask077"
make_fixture "$fx" 600
(
  umask 077
  run_publisher "$fx" 6.6.0 >/dev/null
)
[[ "$(stat -c '%a' "${fx}/6.6.0/current/release.env")" == "644" ]] \
  && pass "umask 077 still yields 644" || fail "umask 077 mode"

echo "[test] C. content"
fx="${WORKDIR}/content"
make_fixture "$fx" 600
# Add an extra preserved key
printf 'IMAGE_LIST_COUNT=156\n' >>"${fx}/6.6.0/current/release.env"
run_publisher "$fx" 6.6.0 >/dev/null
envf="${fx}/6.6.0/current/release.env"
grep -qE '^TARGET_DP_VERSION=6.6.0$' "$envf" && pass "TARGET_DP_VERSION first-class" || fail "TARGET_DP_VERSION"
grep -qE '^PHASE2_ARTIFACT_VERSION=6.6.0$' "$envf" && pass "PHASE2_ARTIFACT_VERSION" || fail "PHASE2"
grep -qE '^DP_PHASE2_VERSION=6.6.0$' "$envf" && pass "deprecated DP_PHASE2_VERSION preserved" || fail "DP_PHASE2_VERSION"
grep -qE '^IMAGE_LIST_COUNT=156$' "$envf" && pass "existing key preserved" || fail "key preserve"
grep -qE '^STABLE_BUNDLE_NAME=dp_bundle_6.6.0-current.tar$' "$envf" && pass "STABLE_BUNDLE_NAME" || fail "stable"
[[ "$(grep -cE '^TARGET_DP_VERSION=' "$envf")" -eq 1 ]] && pass "no duplicate TARGET" || fail "dup TARGET"
[[ "$(grep -cE '^PHASE2_ARTIFACT_VERSION=' "$envf")" -eq 1 ]] && pass "no duplicate PHASE2" || fail "dup PHASE2"
grep -Eq '^VERSION=' "$envf" && fail "ambiguous VERSION= in output" || pass "no VERSION= in output"

fx="${WORKDIR}/badver"
make_fixture "$fx" 600
before="$(sha256sum "${fx}/6.6.0/current/release.env" | awk '{print $1}')"
set +e
out="$(run_publisher "$fx" 'not.a.version' 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "malformed target version STOP" || fail "malformed should STOP"
after="$(sha256sum "${fx}/6.6.0/current/release.env" | awk '{print $1}')"
[[ "$before" == "$after" ]] && pass "malformed does not mutate release.env" || fail "malformed mutated"

echo "[test] D. secret rejection"
for secret_line in \
  'PASSWORD=hunter2' \
  'TOKEN=abc' \
  'PRIVATE_KEY=-----BEGIN' \
  'AUTHORIZATION=Bearer x' \
  'ACPS_PASS=secret' \
  'COOKIE=session=1' \
  'ACCESS_KEY=AKIA' \
  'credential=foo'
do
  fx="${WORKDIR}/secret-$(printf '%s' "$secret_line" | tr -c 'A-Za-z0-9' '_')"
  make_fixture "$fx" 600
  printf '%s\n' "$secret_line" >>"${fx}/6.6.0/current/release.env"
  before="$(sha256sum "${fx}/6.6.0/current/release.env" | awk '{print $1}')"
  set +e
  out="$(run_publisher "$fx" 6.6.0 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] && pass "secret rejected: ${secret_line%%=*}" || fail "secret not rejected: ${secret_line}"
  after="$(sha256sum "${fx}/6.6.0/current/release.env" | awk '{print $1}')"
  [[ "$before" == "$after" ]] && pass "secret no mutate: ${secret_line%%=*}" || fail "secret mutated"
  # no temp leftovers
  if compgen -G "${fx}/6.6.0/current/.release.env.*" >/dev/null 2>&1; then
    fail "temp leftover after secret reject: ${secret_line%%=*}"
  else
    pass "temp clean after secret reject: ${secret_line%%=*}"
  fi
done

# Clean env must not be flagged
printf 'TARGET_DP_VERSION=6.6.0\nSOURCE_HOST=acps.example.internal\nSOURCE_PATH=/data/path\n' \
  >"${WORKDIR}/clean.env"
dp2_release_has_secret "${WORKDIR}/clean.env" && fail "clean SOURCE_HOST flagged" || pass "clean SOURCE_HOST OK"

echo "[test] E. invariants (pointer/READY/bundle)"
fx="${WORKDIR}/invariants"
make_fixture "$fx" 600
# Simulate current as symlink (production layout)
rel="${fx}/6.6.0/releases/20260726T155911Z"
mkdir -p "$rel"
mv "${fx}/6.6.0/current/"* "$rel/"
rmdir "${fx}/6.6.0/current"
ln -sfn "$rel" "${fx}/6.6.0/current"
ready_before="$(sha256sum "${fx}/ready-state/READY" | awk '{print $1}')"
bundle_before="$(stat -c '%i %s' "${fx}/6.6.0/current/dp_bundle_6.6.0-current.tar")"
current_before="$(readlink -f "${fx}/6.6.0/current")"
bundle_sha_before="$(sha256sum "${fx}/6.6.0/current/dp_bundle_6.6.0-current.tar" | awk '{print $1}')"
run_publisher "$fx" 6.6.0 >/dev/null
ready_after="$(sha256sum "${fx}/ready-state/READY" | awk '{print $1}')"
bundle_after="$(stat -c '%i %s' "${fx}/6.6.0/current/dp_bundle_6.6.0-current.tar")"
current_after="$(readlink -f "${fx}/6.6.0/current")"
bundle_sha_after="$(sha256sum "${fx}/6.6.0/current/dp_bundle_6.6.0-current.tar" | awk '{print $1}')"
[[ "$ready_before" == "$ready_after" ]] && pass "READY SHA unchanged" || fail "READY SHA"
[[ "$bundle_before" == "$bundle_after" ]] && pass "bundle inode/size unchanged" || fail "bundle inode"
[[ "$current_before" == "$current_after" ]] && pass "current pointer unchanged" || fail "current pointer"
[[ "$bundle_sha_before" == "$bundle_sha_after" ]] && pass "stable bundle contents unchanged" || fail "bundle contents"

echo "[test] F. cleanup"
fx="${WORKDIR}/cleanup-ok"
make_fixture "$fx" 600
run_publisher "$fx" 6.6.0 >/dev/null
if compgen -G "${fx}/6.6.0/current/.release.env.*" >/dev/null 2>&1; then
  fail "temp left after success"
else
  pass "no .release.env.* after success"
fi

# Metadata generation failure (malformed) — already checked; force replace failure
fx="${WORKDIR}/cleanup-fail-replace"
make_fixture "$fx" 600
before="$(sha256sum "${fx}/6.6.0/current/release.env" | awk '{print $1}')"
set +e
out="$(DP_PHASE2_RELEASE_ENV_ATOMIC_FAIL_REPLACE=1 run_publisher "$fx" 6.6.0 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "forced replace failure exits non-zero" || fail "forced replace should fail"
after="$(sha256sum "${fx}/6.6.0/current/release.env" | awk '{print $1}')"
[[ "$before" == "$after" ]] && pass "replace failure leaves release.env unchanged" || fail "replace failure mutated"
if compgen -G "${fx}/6.6.0/current/.release.env.*" >/dev/null 2>&1; then
  fail "temp left after replace failure"
else
  pass "temp cleaned after replace failure"
fi

echo "[test] G. HTTP fixture (canonical URL, no /current/)"
fx="${WORKDIR}/http"
make_fixture "$fx" 600
run_publisher "$fx" 6.6.0 >/dev/null
# Simulate nginx alias: /dp-phase2/6.6.0/ -> current/
HTTP_ROOT="${WORKDIR}/http_root"
mkdir -p "${HTTP_ROOT}/dp-phase2/6.6.0"
cp -a "${fx}/6.6.0/current/release.env" "${HTTP_ROOT}/dp-phase2/6.6.0/release.env"
# Trap: wrong canonical would look under current/current/
mkdir -p "${HTTP_ROOT}/dp-phase2/6.6.0/current"
printf 'WRONG_NESTED\n' >"${HTTP_ROOT}/dp-phase2/6.6.0/current/release.env"

python3 - "$HTTP_ROOT" 8767 <<'PY' &
import http.server, os, sys
os.chdir(sys.argv[1])
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), http.server.SimpleHTTPRequestHandler).serve_forever()
PY
HTTP_PID=$!
sleep 0.3

code="$(curl -sS -o "${WORKDIR}/http-body" -w '%{http_code}' --max-time 10 \
  'http://127.0.0.1:8767/dp-phase2/6.6.0/release.env')"
[[ "$code" == "200" ]] && pass "canonical HTTP 200" || fail "canonical HTTP code=${code}"
fs_sha="$(sha256sum "${fx}/6.6.0/current/release.env" | awk '{print $1}')"
http_sha="$(sha256sum "${WORKDIR}/http-body" | awk '{print $1}')"
[[ "$fs_sha" == "$http_sha" ]] && pass "HTTP body SHA == filesystem SHA" || fail "HTTP SHA mismatch"
grep -q 'WRONG_NESTED' "${WORKDIR}/http-body" && fail "served nested /current/ path" || pass "did not serve nested current"
# helpers-only must document canonical URL only
if grep -nE '/dp-phase2/\$\{TARGET_DP_VERSION\}/current/release\.env|/dp-phase2/.*/current/release\.env' "$HELPERS_ONLY"; then
  fail "helpers-only uses non-canonical /current/release.env URL"
else
  pass "helpers-only uses canonical release.env URL"
fi
grep -q '/dp-phase2/${TARGET_DP_VERSION}/release.env' "$HELPERS_ONLY" \
  && pass "helpers-only canonical pattern present" || fail "helpers-only canonical missing"

echo "[test] H. permissions (non-root fixture keeps uid/gid, mode 644)"
fx="${WORKDIR}/perms"
make_fixture "$fx" 600
uid_before="$(stat -c '%u' "${fx}/6.6.0/current/release.env")"
gid_before="$(stat -c '%g' "${fx}/6.6.0/current/release.env")"
run_publisher "$fx" 6.6.0 >/dev/null
uid_after="$(stat -c '%u' "${fx}/6.6.0/current/release.env")"
gid_after="$(stat -c '%g' "${fx}/6.6.0/current/release.env")"
mode_after="$(stat -c '%a' "${fx}/6.6.0/current/release.env")"
[[ "$uid_before" == "$uid_after" && "$gid_before" == "$gid_after" ]] \
  && pass "uid/gid preserved in fixture" || fail "uid/gid changed"
[[ "$mode_after" == "644" ]] && pass "mode 644 without root:root force" || fail "mode not 644"

echo "[test] I. helper release.env crosscheck with new metadata"
fx="${WORKDIR}/crosscheck"
make_fixture "$fx" 600
run_publisher "$fx" 6.6.0 >/dev/null
# Rebuild HTTP tree with published env
rm -f "${HTTP_ROOT}/dp-phase2/6.6.0/release.env"
cp -a "${fx}/6.6.0/current/release.env" "${HTTP_ROOT}/dp-phase2/6.6.0/release.env"
set +e
out="$(
  DP_PHASE2_STAGE_LIB_ONLY=1
  # shellcheck disable=SC1090
  source "$HELPER"
  MIRROR_URL="http://127.0.0.1:8767"
  TARGET_DP_VERSION="6.6.0"
  load_release_env_from_mirror
  echo CROSSCHECK_DONE
)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'RELEASE_ENV_CROSSCHECK=PASS'; then
  pass "helper crosscheck PASS with published metadata"
else
  fail "helper crosscheck failed: ${out}"
fi

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -e SC1091,SC2015,SC2034,SC2119,SC2120,SC2317 "$PUBLISHER" \
    && pass "shellcheck publisher" || fail "shellcheck publisher"
  shellcheck -x -e SC1091,SC2015,SC2034,SC2119,SC2120,SC2317 "$HELPERS_ONLY" \
    && pass "shellcheck helpers-only" || fail "shellcheck helpers-only"
else
  echo "  SKIP: shellcheck not installed"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL DP PHASE2 RELEASE ENV PUBLISH TESTS PASSED"
  exit 0
fi
echo "SOME DP PHASE2 RELEASE ENV PUBLISH TESTS FAILED"
exit 1
