#!/usr/bin/env bash
# tests/test_client_os_userspace_matrix.sh
# Authoritative builders → generated clients exercised in Ubuntu 16.04–24.04 containers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/client_finalization_fixture.sh
source "${ROOT}/tests/lib/client_finalization_fixture.sh"

FAIL=0
BLOCKED=0
RESULT="PASS"

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; RESULT="FAIL"; }

WORKDIR="$(mktemp -d /tmp/test-os-userspace-matrix.XXXXXX)"

cleanup() {
  sudo rm -rf "$WORKDIR" 2>/dev/null || rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

report_blocked() {
  local reason="$1"
  echo "TEST_CLIENT_OS_USERSPACE_MATRIX=BLOCKED"
  echo "BLOCKED_REASON=${reason}"
  echo "=== test_client_os_userspace_matrix BLOCKED ==="
  BLOCKED=1
  exit 2
}

docker_cmd() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    sudo docker "$@"
  else
    return 1
  fi
}

probe_image() {
  local image="$1"
  local want_ver="$2"
  local want_apt_re="$3"
  docker_cmd image inspect "$image" >/dev/null 2>&1 || return 1
  local out id
  id="$(docker_cmd image inspect --format='{{.Id}}' "$image")"
  out="$(docker_cmd run --rm "$image" bash -c '
    set -e
    vid=""
    if [[ -f /etc/os-release ]]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      vid="${VERSION_ID:-}"
    fi
    apt_line="$(apt-get --version 2>/dev/null | head -1 || true)"
    printf "VERSION_ID=%s\nAPT_VERSION=%s\n" "$vid" "$apt_line"
  ' 2>/dev/null || true)"
  local vid apt_line
  vid="$(printf '%s\n' "$out" | sed -n 's/^VERSION_ID=//p' | head -1)"
  apt_line="$(printf '%s\n' "$out" | sed -n 's/^APT_VERSION=//p' | head -1)"
  echo "IMAGE=${image}"
  echo "IMAGE_ID=${id}"
  echo "VERSION_ID=${vid}"
  echo "APT_VERSION=${apt_line}"
  [[ "$vid" == "$want_ver" ]] || return 1
  [[ "$apt_line" =~ $want_apt_re ]] || return 1
  return 0
}

init_docker() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  else
    report_blocked "docker daemon unavailable"
  fi
}

run_hop_case() {
  local hop="$1"
  local image="$2"
  local want_ver="$3"
  local want_apt_re="$4"
  local source="$5"
  local client_script="${CLIENT_ROOT}/dp-offline-upgrade-${hop}.sh"

  echo "--- hop ${hop} / ${image} ---"
  if ! probe_image "$image" "$want_ver" "$want_apt_re"; then
    fail "${hop}: image ${image} missing or wrong VERSION_ID/apt"
    return 0
  fi
  pass "${hop}: image gate VERSION_ID=${want_ver}"
  [[ -f "$client_script" ]] || { fail "${hop}: generated client missing"; return 0; }

  local case_dir="${WORKDIR}/${hop}"
  mkdir -p "${case_dir}/built"
  cp -a "$client_script" "${case_dir}/built/"

  cat >"${case_dir}/container-check.sh" <<INNER
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. /etc/os-release
apt_line="\$(apt-get --version 2>/dev/null | head -1 || true)"
echo "CONTAINER_VERSION_ID=\${VERSION_ID:-}"
echo "CONTAINER_APT=\${apt_line}"
[[ "\${VERSION_ID:-}" == "${want_ver}" ]] || exit 1
[[ "\${apt_line}" =~ ${want_apt_re} ]] || exit 1
bash -n "/fixture/built/dp-offline-upgrade-${hop}.sh"
grep -q 'run_temporary_local_apt_authentication_preflight' "/fixture/built/dp-offline-upgrade-${hop}.sh" || exit 1
grep -q 'release-upgrade-reconciliation' "/fixture/built/dp-offline-upgrade-${hop}.sh" || exit 1
echo "HOP_CASE=PASS"
INNER
  chmod +x "${case_dir}/container-check.sh"

  bash -n "${case_dir}/built/dp-offline-upgrade-${hop}.sh" \
    && pass "${hop}: host bash -n PASS" \
    || { fail "${hop}: host bash -n FAIL"; return 0; }
  grep -q 'run_temporary_local_apt_authentication_preflight' "${case_dir}/built/dp-offline-upgrade-${hop}.sh" \
    && pass "${hop}: APT preflight embedded" \
    || fail "${hop}: APT preflight missing"
  grep -q 'release-upgrade-reconciliation' "${case_dir}/built/dp-offline-upgrade-${hop}.sh" \
    && pass "${hop}: reconciliation embedded" \
    || fail "${hop}: reconciliation missing"

  set +e
  timeout 60 "${DOCKER[@]}" run --rm \
    -v "${case_dir}:/fixture:ro" \
    "$image" \
    bash /fixture/container-check.sh \
    >"${case_dir}/docker.out" 2>"${case_dir}/docker.err"
  local drc=$?
  set -e
  cat "${case_dir}/docker.out"
  if [[ "$drc" -eq 0 ]]; then
    pass "${hop}: container userspace checks PASS"
  else
    fail "${hop}: container checks FAIL rc=${drc}"
    tail -20 "${case_dir}/docker.err" || true
  fi
}

echo "=== test_client_os_userspace_matrix ==="

if ! command -v gpg >/dev/null 2>&1; then
  report_blocked "gpg unavailable"
fi
init_docker

client_fixture_require
client_fixture_build_selective "$WORKDIR"
client_fixture_install_runtime "$ROOT" "$WORKDIR"

SEL_ROOT="${WORKDIR}/selective"
CLIENT_ROOT="${WORKDIR}/runtime/var/spool/apt-mirror/client"
SIGNING_DIR="${WORKDIR}/runtime/etc/ubuntu-mirror/client-signing"
MIRROR_ROOT="${WORKDIR}/runtime/var/spool/apt-mirror"
CACHE="${MIRROR_ROOT}/.install-cache"
MIRROR_URL="http://192.0.2.50"

echo "Building four-hop client set via rebuild-publish-clients.sh..."
if ! env \
  MIRROR_HTTP_URL="$MIRROR_URL" \
  RESOLVED_MIRROR_BASE_URL="$MIRROR_URL" \
  RESOLVED_MIRROR_HOST_IPV4="192.0.2.50" \
  LOCAL_CLIENT_SIGNING_DIR="$SIGNING_DIR" \
  CLIENT_HTTP_ROOT="$CLIENT_ROOT" \
  SELECTIVE_ROOT="$SEL_ROOT" \
  BASE_PATH="$MIRROR_ROOT" \
  CACHE_ROOT="$CACHE" \
  CONTENT_SOURCE=local-fs \
  MM_HERMETIC_TEST_MODE=1 \
  CLIENT_BUILD_PIN_URL_ONLY=1 \
  SKIP_HTTP_VERIFY=1 \
  REQUIRE_SELECTIVE_READY=1 \
  bash "${ROOT}/scripts/rebuild-publish-clients.sh" \
  >"${WORKDIR}/rebuild.log" 2>&1
then
  fail "rebuild-publish-clients failed"
  tail -30 "${WORKDIR}/rebuild.log" || true
else
  pass "authoritative four-hop rebuild PASS"
fi

run_hop_case xenial-to-bionic ubuntu:16.04 16.04 'apt[[:space:]]1\.2\.' xenial
run_hop_case bionic-to-focal ubuntu:18.04 18.04 'apt[[:space:]]1\.6\.' bionic
run_hop_case focal-to-jammy ubuntu:20.04 20.04 'apt[[:space:]]2\.0\.' focal
run_hop_case jammy-to-noble ubuntu:22.04 22.04 'apt[[:space:]]2\.4\.' jammy

echo "--- noble target-side helper syntax ---"
if probe_image ubuntu:24.04 24.04 'apt[[:space:]]2\.[78]\.'; then
  pass "noble: VERSION_ID=24.04 apt 2.7+/2.8.x"
  set +e
  "${DOCKER[@]}" run --rm -v "${ROOT}:/repo:ro" ubuntu:24.04 \
    bash -n /repo/client/lib/dp-offline-apt-preflight-sandbox.sh \
    >"${WORKDIR}/noble-helper.out" 2>"${WORKDIR}/noble-helper.err"
  nrc=$?
  "${DOCKER[@]}" run --rm -v "${ROOT}:/repo:ro" ubuntu:24.04 \
    bash -n /repo/client/lib/dp-offline-release-upgrade-reconciliation.sh \
    >>"${WORKDIR}/noble-helper.out" 2>>"${WORKDIR}/noble-helper.err"
  nrc2=$?
  set -e
  [[ "$nrc" -eq 0 && "$nrc2" -eq 0 ]] && pass "noble: shared helper bash -n PASS" \
    || fail "noble: shared helper bash -n FAIL"
else
  fail "noble: image gate failed"
fi

if [[ "$BLOCKED" -eq 1 ]]; then
  exit 2
fi
if [[ "$FAIL" -eq 0 ]]; then
  echo "TEST_CLIENT_OS_USERSPACE_MATRIX=PASS"
  echo "=== test_client_os_userspace_matrix PASS ==="
  exit 0
fi
echo "TEST_CLIENT_OS_USERSPACE_MATRIX=${RESULT}"
echo "=== test_client_os_userspace_matrix ${RESULT} ==="
exit 1
