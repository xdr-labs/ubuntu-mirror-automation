#!/usr/bin/env bash
# Enable HTTP: nginx enable fail-closed + transactional publication topology restore.
# Uses temp dirs and mock nginx/systemctl only. Does not touch production nginx.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

export MM_CONFIG_DIR="${WORKDIR}/etc-ubuntu-mirror"
export MM_WORKFLOW_FILE="${MM_CONFIG_DIR}/dp-upgrade-workflow.state"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.status"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.conf"
export MM_STATE_ROOT="${WORKDIR}/state-root"
export MM_LOG_DIR="${WORKDIR}/logs"
export MM_PROJECT_ROOT="$ROOT"
export MM_SKIP_ROOT_CHECK=1
export MM_SKIP_HTTP_VALIDATE=1
export MM_SKIP_BUNDLE_SHA256=1
export MM_SKIP_NGINX_APPLY=0
export SKIP_MIRROR_HOST_VALIDATE=1
export TARGET_DP_VERSION=6.6.0
mkdir -p "$MM_CONFIG_DIR" "$MM_LOG_DIR" "$MM_STATE_ROOT"

# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=../scripts/lib/dp-phase2-common.sh
source "${ROOT}/scripts/lib/dp-phase2-common.sh"
# shellcheck source=../scripts/lib/acps_acquire.sh
source "${ROOT}/scripts/lib/acps_acquire.sh"
# shellcheck source=../scripts/lib/r2_acquire.sh
source "${ROOT}/scripts/lib/r2_acquire.sh"
# shellcheck source=../scripts/lib/mirror_install_engine.sh
source "${ROOT}/scripts/lib/mirror_install_engine.sh"
# shellcheck source=lib/seed_complete_client_http_set.sh
source "${ROOT}/tests/lib/seed_complete_client_http_set.sh"

MOCKBIN="${WORKDIR}/mockbin"
mkdir -p "$MOCKBIN"
cat >"${MOCKBIN}/nginx" <<'EOF'
#!/bin/bash
if [[ "${MM_NGINX_TEST_FAIL:-0}" == "1" ]]; then
  echo "nginx: fail" >&2
  exit 1
fi
exit 0
EOF
cat >"${MOCKBIN}/systemctl" <<'EOF'
#!/bin/bash
state="${MOCK_SYSTEMCTL_STATE:?}"
mkdir -p "$state"
printf '%s\n' "$*" >>"${state}/calls.log"
cmd="${1:-}"
case "$cmd" in
  is-active)
    [[ -f "${state}/active" ]] && exit 0 || exit 1
    ;;
  is-enabled)
    [[ -f "${state}/enabled" ]] && exit 0 || exit 1
    ;;
  enable)
    if [[ -f "${state}/enable_fail" ]]; then
      exit 1
    fi
    if [[ -f "${state}/enable_noop" ]]; then
      exit 0
    fi
    : >"${state}/enabled"
    exit 0
    ;;
  disable)
    rm -f "${state}/enabled"
    exit 0
    ;;
  start|reload|restart)
    if [[ -f "${state}/start_fail" ]]; then
      exit 1
    fi
    : >"${state}/active"
    exit 0
    ;;
  stop)
    rm -f "${state}/active"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "${MOCKBIN}/nginx" "${MOCKBIN}/systemctl"
export PATH="${MOCKBIN}:${PATH}"
export MM_NGINX_BIN="${MOCKBIN}/nginx"
export MM_SYSTEMCTL_BIN="${MOCKBIN}/systemctl"

HTTP_ROOT="${WORKDIR}/http-layout"
mkdir -p "${HTTP_ROOT}/selective/hops/jammy-to-noble/ubuntu" \
  "${HTTP_ROOT}/selective/shared/offline" \
  "${HTTP_ROOT}/client" \
  "${HTTP_ROOT}/dp-phase2/6.6.0"
ln -sfn hops/jammy-to-noble/ubuntu "${HTTP_ROOT}/selective/ubuntu"
seed_complete_client_http_set "${HTTP_ROOT}/client" "http://192.0.2.10" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
printf 'TARGET_DP_VERSION=6.6.0\n' >"${HTTP_ROOT}/dp-phase2/6.6.0/release.env"
mkdir -p "${HTTP_ROOT}/dp-phase2/6.6.0/extras"
cat >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.state" <<'EOF'
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PACKAGE_COUNT=0
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
EOF
tar -cf "${HTTP_ROOT}/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar" \
  -C "${HTTP_ROOT}/dp-phase2/6.6.0" release.env
(
  cd "${HTTP_ROOT}/dp-phase2/6.6.0"
  sha256sum dp_bundle_6.6.0-current.tar >dp_bundle_6.6.0-current.tar.sha256
)
printf 'prepared-artifact\n' >"${HTTP_ROOT}/client/.prepared-marker"
printf 'prepared-bundle\n' >"${HTTP_ROOT}/dp-phase2/6.6.0/.prepared-marker"

export MM_MIRROR_ROOT="$HTTP_ROOT"
export MM_SELECTIVE_ROOT="${HTTP_ROOT}/selective"
export MM_DP_PHASE2_ROOT="${HTTP_ROOT}/dp-phase2"
export MM_CLIENT_ROOT="${HTTP_ROOT}/client"
printf 'TARGET_DP_VERSION=6.6.0\nACPS_USERNAME=u\nACPS_PASSWORD=p\nMIRROR_SERVER_IP=192.0.2.10\nMIRROR_HTTP_URL=http://192.0.2.10\n' \
  >"$MM_CONFIG_FILE"
chmod 600 "$MM_CONFIG_FILE"
dp2_set_version 6.6.0

ngx_case=0
setup_nginx_case() {
  ngx_case=$((ngx_case + 1))
  local base="${WORKDIR}/nginx-case-${ngx_case}"
  NGINX_AVAIL="${base}/sites-available"
  NGINX_EN="${base}/sites-enabled"
  mkdir -p "$NGINX_AVAIL" "$NGINX_EN"
  export MM_NGINX_SITE_AVAIL="${NGINX_AVAIL}/apt-mirror"
  export MM_NGINX_SITE_ENABLED="${NGINX_EN}/apt-mirror"
  MOCK_SYSTEMCTL_STATE="${base}/systemctl-state"
  mkdir -p "$MOCK_SYSTEMCTL_STATE"
  export MOCK_SYSTEMCTL_STATE
  rm -f "${MOCK_SYSTEMCTL_STATE}/"*
  : >"$MM_STATUS_FILE"
  mm_status_set HTTP_DISTRIBUTION DISABLED
  mm_state_set HTTP_DISTRIBUTION_READY NO
}

run_enable_http() {
  env \
    MM_PROJECT_ROOT="$ROOT" \
    MM_MIRROR_ROOT="$MM_MIRROR_ROOT" \
    MM_SELECTIVE_ROOT="$MM_SELECTIVE_ROOT" \
    MM_DP_PHASE2_ROOT="$MM_DP_PHASE2_ROOT" \
    MM_CLIENT_ROOT="$MM_CLIENT_ROOT" \
    MM_SKIP_ROOT_CHECK=1 \
    MM_SKIP_HTTP_VALIDATE=1 \
    MM_SKIP_BUNDLE_SHA256=1 \
    MM_SKIP_NGINX_APPLY=0 \
    SKIP_MIRROR_HOST_VALIDATE=1 \
    MM_NGINX_SITE_AVAIL="$MM_NGINX_SITE_AVAIL" \
    MM_NGINX_SITE_ENABLED="$MM_NGINX_SITE_ENABLED" \
    MM_NGINX_BIN="$MM_NGINX_BIN" \
    MM_SYSTEMCTL_BIN="$MM_SYSTEMCTL_BIN" \
    MOCK_SYSTEMCTL_STATE="$MOCK_SYSTEMCTL_STATE" \
    MM_NGINX_TEST_FAIL="${MM_NGINX_TEST_FAIL:-0}" \
    MM_HTTP_VALIDATE_MOCK_FAIL="${MM_HTTP_VALIDATE_MOCK_FAIL:-0}" \
    TARGET_DP_VERSION=6.6.0 \
    MM_STATUS_FILE="$MM_STATUS_FILE" \
    MM_CONFIG_FILE="$MM_CONFIG_FILE" \
    MM_WORKFLOW_FILE="$MM_WORKFLOW_FILE" \
    MM_CONFIG_DIR="$MM_CONFIG_DIR" \
    MM_STATE_ROOT="$MM_STATE_ROOT" \
    MM_LOG_DIR="$MM_LOG_DIR" \
    PATH="$PATH" \
    bash -c '
      set -euo pipefail
      source "'"${ROOT}"'/scripts/lib/mirror_manager_common.sh"
      source "'"${ROOT}"'/scripts/lib/dp-phase2-common.sh"
      source "'"${ROOT}"'/scripts/lib/acps_acquire.sh"
      source "'"${ROOT}"'/scripts/lib/r2_acquire.sh"
      source "'"${ROOT}"'/scripts/lib/mirror_install_engine.sh"
      dp2_set_version 6.6.0
      engine_enable_http_distribution
    '
}

artifacts_preserved() {
  [[ -f "${HTTP_ROOT}/client/.prepared-marker" ]] \
    && [[ -f "${HTTP_ROOT}/dp-phase2/6.6.0/.prepared-marker" ]] \
    && [[ -f "${HTTP_ROOT}/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar" ]]
}

echo "======== P2 enable fail-closed ========"

setup_nginx_case
if run_enable_http >/dev/null; then
  [[ "$(mm_status_get HTTP_DISTRIBUTION)" == "ENABLED" ]] \
    && [[ "$(mm_status_get HTTP_DISTRIBUTION_READY)" == "YES" ]] \
    && [[ -f "${MOCK_SYSTEMCTL_STATE}/enabled" ]] \
    && pass "enable succeeds -> ENABLED + is-enabled" \
    || fail "enable success did not persist ENABLED/is-enabled"
else
  fail "enable success path returned nonzero"
fi

setup_nginx_case
: >"${MOCK_SYSTEMCTL_STATE}/enable_fail"
set +e
run_enable_http >/dev/null 2>&1
rc_en=$?
set -e
if [[ "$rc_en" -ne 0 ]] \
  && [[ "$(mm_status_get HTTP_DISTRIBUTION)" != "ENABLED" ]] \
  && [[ "$(mm_status_get HTTP_DISTRIBUTION_READY)" != "YES" ]] \
  && [[ "$(mm_status_get HTTP_ENABLE_RESULT)" == "FAIL" ]] \
  && [[ ! -e "$MM_NGINX_SITE_AVAIL" ]] \
  && [[ ! -e "$MM_NGINX_SITE_ENABLED" ]]; then
  pass "enable command nonzero -> FAIL + rollback"
else
  fail "enable command nonzero false-PASS or skipped rollback rc=${rc_en} dist=$(mm_status_get HTTP_DISTRIBUTION) ready=$(mm_status_get HTTP_DISTRIBUTION_READY)"
fi

setup_nginx_case
: >"${MOCK_SYSTEMCTL_STATE}/enable_noop"
set +e
run_enable_http >/dev/null 2>&1
rc_noop=$?
set -e
if [[ "$rc_noop" -ne 0 ]] \
  && [[ "$(mm_status_get HTTP_DISTRIBUTION)" != "ENABLED" ]] \
  && [[ "$(mm_status_get HTTP_DISTRIBUTION_READY)" != "YES" ]] \
  && [[ "$(mm_status_get HTTP_ENABLE_RESULT)" == "FAIL" ]]; then
  pass "enable rc=0 but is-enabled false -> FAIL + rollback"
else
  fail "enable noop false-PASS rc=${rc_noop} dist=$(mm_status_get HTTP_DISTRIBUTION)"
fi

setup_nginx_case
: >"${MOCK_SYSTEMCTL_STATE}/enabled"
: >"${MOCK_SYSTEMCTL_STATE}/active"
if run_enable_http >/dev/null; then
  [[ -f "${MOCK_SYSTEMCTL_STATE}/enabled" ]] \
    && [[ -f "${MOCK_SYSTEMCTL_STATE}/active" ]] \
    && [[ "$(mm_status_get HTTP_DISTRIBUTION)" == "ENABLED" ]] \
    && pass "existing enabled nginx remains valid" \
    || fail "existing enabled nginx not preserved as valid"
else
  fail "existing enabled nginx enable path failed"
fi

echo "======== P3-A nginx topology rollback ========"

# A. no previous site -> failed apply removes newly created site
setup_nginx_case
export MM_NGINX_TEST_FAIL=1
set +e
run_enable_http >/dev/null 2>&1
rc_a=$?
set -e
unset MM_NGINX_TEST_FAIL
if [[ "$rc_a" -ne 0 ]] \
  && [[ ! -e "$MM_NGINX_SITE_AVAIL" ]] \
  && [[ ! -e "$MM_NGINX_SITE_ENABLED" ]]; then
  pass "A no previous site: failed apply removes new site"
else
  fail "A leftover new site after failure avail=$(ls -l "$MM_NGINX_SITE_AVAIL" 2>&1 || true)"
fi

# B. previous sites-available config restored byte-for-byte
setup_nginx_case
printf 'OLD_AVAIL_BYTES unique-prev-config\n' >"$MM_NGINX_SITE_AVAIL"
cp -a "$MM_NGINX_SITE_AVAIL" "${WORKDIR}/expected-b"
export MM_NGINX_TEST_FAIL=1
set +e
run_enable_http >/dev/null 2>&1
set -e
unset MM_NGINX_TEST_FAIL
if cmp -s "${WORKDIR}/expected-b" "$MM_NGINX_SITE_AVAIL"; then
  pass "B previous sites-available restored byte-for-byte"
else
  fail "B sites-available not restored: $(cat "$MM_NGINX_SITE_AVAIL" 2>/dev/null || echo missing)"
fi

# C. previous sites-enabled symlink to another target restored
setup_nginx_case
printf 'other-site\n' >"${NGINX_AVAIL}/other"
ln -sfn "${NGINX_AVAIL}/other" "$MM_NGINX_SITE_ENABLED"
export MM_NGINX_TEST_FAIL=1
set +e
run_enable_http >/dev/null 2>&1
set -e
unset MM_NGINX_TEST_FAIL
if [[ -L "$MM_NGINX_SITE_ENABLED" ]] \
  && [[ "$(readlink "$MM_NGINX_SITE_ENABLED")" == "${NGINX_AVAIL}/other" ]]; then
  pass "C previous sites-enabled symlink target restored"
else
  fail "C enabled topology=$(ls -l "$MM_NGINX_SITE_ENABLED" 2>&1 || true)"
fi

# D. default site existed -> restored
setup_nginx_case
ln -sfn /dev/null "${NGINX_EN}/default"
export MM_NGINX_TEST_FAIL=1
set +e
run_enable_http >/dev/null 2>&1
set -e
unset MM_NGINX_TEST_FAIL
if [[ -L "${NGINX_EN}/default" ]] && [[ "$(readlink "${NGINX_EN}/default")" == "/dev/null" ]]; then
  pass "D default site restored after failure"
else
  fail "D default missing or wrong target=$(ls -l "${NGINX_EN}/default" 2>&1 || true)"
fi

# E. default site absent originally -> remains absent
setup_nginx_case
export MM_NGINX_TEST_FAIL=1
set +e
run_enable_http >/dev/null 2>&1
set -e
unset MM_NGINX_TEST_FAIL
if [[ ! -e "${NGINX_EN}/default" && ! -L "${NGINX_EN}/default" ]]; then
  pass "E default remains absent"
else
  fail "E default unexpectedly present"
fi

# F. nginx active/enabled state restored
setup_nginx_case
: >"${MOCK_SYSTEMCTL_STATE}/active"
# previously disabled
export MM_NGINX_TEST_FAIL=1
set +e
run_enable_http >/dev/null 2>&1
set -e
unset MM_NGINX_TEST_FAIL
if [[ -f "${MOCK_SYSTEMCTL_STATE}/active" ]] \
  && [[ ! -f "${MOCK_SYSTEMCTL_STATE}/enabled" ]]; then
  pass "F service active restored and enabled stays disabled"
else
  fail "F service state active=$(ls "${MOCK_SYSTEMCTL_STATE}/active" 2>&1) enabled=$(ls "${MOCK_SYSTEMCTL_STATE}/enabled" 2>&1)"
fi

setup_nginx_case
: >"${MOCK_SYSTEMCTL_STATE}/enabled"
export MM_NGINX_TEST_FAIL=1
set +e
run_enable_http >/dev/null 2>&1
set -e
unset MM_NGINX_TEST_FAIL
if [[ -f "${MOCK_SYSTEMCTL_STATE}/enabled" ]] \
  && [[ ! -f "${MOCK_SYSTEMCTL_STATE}/active" ]]; then
  pass "F previously enabled stays enabled; inactive stays stopped"
else
  fail "F enabled/inactive restore failed"
fi

# G. successful Menu 3 does not restore old configuration
setup_nginx_case
printf 'OLD_SHOULD_NOT_RETURN\n' >"$MM_NGINX_SITE_AVAIL"
printf 'other\n' >"${NGINX_AVAIL}/other"
ln -sfn "${NGINX_AVAIL}/other" "$MM_NGINX_SITE_ENABLED"
ln -sfn /dev/null "${NGINX_EN}/default"
if run_enable_http >/dev/null; then
  if grep -q 'OLD_SHOULD_NOT_RETURN' "$MM_NGINX_SITE_AVAIL"; then
    fail "G success restored old available config"
  elif [[ "$(readlink "$MM_NGINX_SITE_ENABLED")" != "$MM_NGINX_SITE_AVAIL" ]]; then
    fail "G success did not publish new enabled symlink"
  elif [[ -e "${NGINX_EN}/default" || -L "${NGINX_EN}/default" ]]; then
    fail "G success left default site in place"
  elif [[ "$(mm_status_get HTTP_DISTRIBUTION)" != "ENABLED" ]]; then
    fail "G success did not mark ENABLED"
  else
    pass "G success publishes new config and does not restore old"
  fi
else
  fail "G success path failed"
fi

if artifacts_preserved; then
  pass "prepared artifacts remain untouched"
else
  fail "prepared artifacts were modified or removed"
fi

echo "======== DONE fail=${FAIL} ========"
exit "$FAIL"
