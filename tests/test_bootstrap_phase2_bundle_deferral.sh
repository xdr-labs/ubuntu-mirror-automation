#!/usr/bin/env bash
# tests/test_bootstrap_phase2_bundle_deferral.sh
# Real-host sequencing: OS Core READY + Mirror URL must not make a missing
# target 6.6.0 Phase 2 bundle fail install. Full finalization stays fail-closed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../lib/bootstrap.sh
source "${ROOT}/lib/bootstrap.sh"
# shellcheck source=lib/phase2_bundle_trust_fixture.sh
source "${ROOT}/tests/lib/phase2_bundle_trust_fixture.sh"
# shellcheck source=lib/seed_complete_client_http_set.sh
source "${ROOT}/tests/lib/seed_complete_client_http_set.sh"
# shellcheck source=lib/client_finalization_fixture.sh
source "${ROOT}/tests/lib/client_finalization_fixture.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

MIRROR_IP="192.0.2.66"
MIRROR_URL="http://${MIRROR_IP}"
TARGET_VER="6.6.0"

setup_host() {
  local base="$1"
  mkdir -p \
    "${base}/var/spool/apt-mirror/selective/state" \
    "${base}/var/spool/apt-mirror/selective/keys" \
    "${base}/var/spool/apt-mirror/client" \
    "${base}/var/spool/apt-mirror/dp-phase2" \
    "${base}/etc/ubuntu-mirror" \
    "${base}/usr/local/bin" \
    "${base}/usr/local/lib/ubuntu-mirror"
  printf 'READY\n' >"${base}/var/spool/apt-mirror/selective/state/READY"
  printf 'SELECTIVE-KEY\n' >"${base}/var/spool/apt-mirror/selective/keys/ubuntu-mirror-selective.gpg"
  cat >"${base}/etc/ubuntu-mirror/dp-upgrade-mirror.conf" <<EOF
PREPARATION_MODE=FULL
MIRROR_SERVER_IP=${MIRROR_IP}
MIRROR_HTTP_URL=${MIRROR_URL}
EOF
  chmod 600 "${base}/etc/ubuntu-mirror/dp-upgrade-mirror.conf"
}

run_deploy() {
  local base="$1"
  env \
    UM_PROJECT_ROOT="$ROOT" \
    BASE_PATH="${base}/var/spool/apt-mirror" \
    INSTALL_CONF_DIR="${base}/etc/ubuntu-mirror" \
    INSTALL_LIB_DIR="${base}/usr/local/lib/ubuntu-mirror" \
    INSTALL_BIN_DIR="${base}/usr/local/bin" \
    SKIP_MIRROR_HOST_VALIDATE=1 \
    UM_BOOTSTRAP_ALLOW_SIGNING_DIR_OVERRIDE=0 \
    PHASE2_TARGET_VERSION="$TARGET_VER" \
    TARGET_DP_VERSION="$TARGET_VER" \
    bash -c '
      set -euo pipefail
      source "'"${ROOT}"'/lib/common.sh"
      source "'"${ROOT}"'/lib/bootstrap.sh"
      um_bootstrap_deploy_client_http_artifacts
    ' 2>&1
}

client_tree_inventory() {
  local root="$1"
  (
    cd "$root" || exit 1
    find . -type f -print0 | sort -z | xargs -0 sha256sum
  )
}

echo "======== 1. OS Core READY + Mirror URL + NO 6.6.0 bundle (optional 6.5.0) ========"
HOST1="${WORKDIR}/host1"
setup_host "$HOST1"
BASE1="${HOST1}/var/spool/apt-mirror"
# Old 6.5.0 content must not satisfy 6.6.0 readiness.
phase2_trust_fixture_write_bundle_sidecar "${BASE1}/dp-phase2" "6.5.0" "old-650-bundle" >/dev/null

set +e
out1="$(run_deploy "$HOST1")"
rc1=$?
set -e
[[ "$rc1" -eq 0 ]] && pass "bootstrap PASS without 6.6.0 bundle" || fail "bootstrap FAIL rc=${rc1}"
echo "$out1" | grep -q 'CLIENT_SET_BUILD=DEFERRED_UNTIL_PHASE2_BUNDLE' \
  && pass "CLIENT_SET_BUILD=DEFERRED_UNTIL_PHASE2_BUNDLE" \
  || fail "missing CLIENT_SET_BUILD=DEFERRED_UNTIL_PHASE2_BUNDLE"
echo "$out1" | grep -q 'PHASE2_UPGRADE_WRAPPER=DEFERRED' \
  && pass "PHASE2_UPGRADE_WRAPPER=DEFERRED" \
  || fail "missing PHASE2_UPGRADE_WRAPPER=DEFERRED"
echo "$out1" | grep -q 'TARGET_PHASE2_BUNDLE_READY=NO' \
  && pass "TARGET_PHASE2_BUNDLE_READY=NO" \
  || fail "missing TARGET_PHASE2_BUNDLE_READY=NO"
echo "$out1" | grep -q 'REBUILD_PUBLISH_CLIENTS=PASS\|CLIENT_SET_BUILD_COMPLETE=YES' \
  && fail "full client rebuild ran unexpectedly" \
  || pass "no full client rebuild"
# Empty tree may receive helpers-only; must not invent upgrade-phase2.sh without SHA.
if [[ -f "${BASE1}/client/upgrade-phase2.sh" ]]; then
  fail "PHASE2_UPGRADE_WRAPPER created without trusted SHA"
else
  pass "no untrusted upgrade-phase2.sh"
fi
if [[ -f "${BASE1}/client/dp-offline-upgrade-xenial-to-bionic.sh" ]]; then
  fail "hop client published without Phase 2 bundle"
else
  pass "hop clients not published without bundle"
fi

# Old 6.5.0 must not be accepted as 6.6.0 ready.
sha650="$(
  MM_DP_PHASE2_ROOT="${BASE1}/dp-phase2" \
    bash -c '
      source "'"${ROOT}"'/scripts/lib/phase2_helper_generation.sh"
      phase2_published_bundle_sha256 6.5.0
    '
)"
set +e
sha660_absent="$(
  MM_DP_PHASE2_ROOT="${BASE1}/dp-phase2" \
    bash -c '
      source "'"${ROOT}"'/scripts/lib/phase2_helper_generation.sh"
      phase2_published_bundle_sha256 6.6.0
    ' 2>/dev/null
)"
rc660=$?
set -e
[[ -n "$sha650" && "$sha650" =~ ^[0-9a-fA-F]{64}$ ]] \
  && pass "6.5.0 sidecar readable" || fail "6.5.0 sidecar"
[[ "$rc660" -ne 0 || -z "$sha660_absent" ]] \
  && pass "OLD_650_BUNDLE_ACCEPTED_AS_660_READY=NO" \
  || fail "6.5.0 incorrectly satisfied 6.6.0"

echo "======== 2. Existing published client set unchanged when 6.6.0 absent ========"
HOST2="${WORKDIR}/host2"
setup_host "$HOST2"
BASE2="${HOST2}/var/spool/apt-mirror"
CLIENT2="${BASE2}/client"
seed_complete_client_http_set "$CLIENT2" "$MIRROR_URL"
# Marker proving mixed-generation merge would be detectable
printf 'EXISTING-GENERATION-MARKER\n' >"${CLIENT2}/.generation-marker"
phase2_trust_fixture_write_bundle_sidecar "${BASE2}/dp-phase2" "6.5.0" "old-only" >/dev/null
BEFORE_INV="$(client_tree_inventory "$CLIENT2")"
BEFORE_HASH="$(printf '%s\n' "$BEFORE_INV" | sha256sum | awk '{print $1}')"

set +e
out2="$(run_deploy "$HOST2")"
rc2=$?
set -e
[[ "$rc2" -eq 0 ]] && pass "bootstrap PASS with existing client set" || fail "existing-set bootstrap FAIL"
echo "$out2" | grep -q 'EXISTING_CLIENT_SET=PRESERVED' \
  && pass "EXISTING_CLIENT_SET=PRESERVED" || fail "EXISTING_CLIENT_SET not preserved"
echo "$out2" | grep -q 'PHASE2_UPGRADE_WRAPPER=DEFERRED' \
  && pass "wrapper deferred with existing set" || fail "wrapper not deferred"
AFTER_INV="$(client_tree_inventory "$CLIENT2")"
AFTER_HASH="$(printf '%s\n' "$AFTER_INV" | sha256sum | awk '{print $1}')"
[[ "$BEFORE_HASH" == "$AFTER_HASH" ]] \
  && pass "existing client tree byte-identical" \
  || fail "existing client tree changed"
[[ -f "${CLIENT2}/.generation-marker" ]] \
  && pass "generation marker intact" || fail "generation marker missing"
# Helpers-only merge would rewrite stage-dp-phase2 / generation manifest; prove absent.
if echo "$out2" | grep -q 'CLIENT_SET_BUILD_COMPLETE=YES'; then
  fail "partial/full rebuild occurred"
else
  pass "no partial client set publish"
fi

echo "======== 3. Fresh empty client tree + no target bundle still PASS ========"
HOST3="${WORKDIR}/host3"
setup_host "$HOST3"
BASE3="${HOST3}/var/spool/apt-mirror"
rm -rf "${BASE3}/client"
mkdir -p "${BASE3}/client"
set +e
out3="$(run_deploy "$HOST3")"
rc3=$?
set -e
[[ "$rc3" -eq 0 ]] && pass "empty client tree bootstrap PASS" || fail "empty tree FAIL"
echo "$out3" | grep -q 'CLIENT_SET_BUILD=DEFERRED_UNTIL_PHASE2_BUNDLE' \
  && pass "empty tree deferred until Phase 2 bundle" || fail "empty tree deferral"
[[ ! -f "${BASE3}/client/upgrade-phase2.sh" ]] \
  && pass "empty tree: no untrusted wrapper" || fail "empty tree created wrapper"

echo "======== 4. Valid 6.6.0 bundle → full rebuild + trusted wrapper ========"
client_fixture_require || fail "client fixture prerequisites"
FIX4="${WORKDIR}/fix4"
client_fixture_build_selective "$FIX4"
client_fixture_install_runtime "$ROOT" "$FIX4"
BASE4="$CLIENT_FIXTURE_MIRROR_ROOT"
SEL4="$CLIENT_FIXTURE_SELECTIVE"
CLIENT4="$CLIENT_FIXTURE_CLIENT_ROOT"
SIGN4="$CLIENT_FIXTURE_SIGNING_DIR"
mkdir -p "${FIX4}/etc/ubuntu-mirror" "${FIX4}/usr/local/bin"
# Point bootstrap confdir at the fixture signing + mirror URL.
# client_fixture_install_runtime already placed keys under SIGN4.
ln -sfn "$SIGN4" "${FIX4}/etc/ubuntu-mirror/client-signing"
cat >"${FIX4}/etc/ubuntu-mirror/dp-upgrade-mirror.conf" <<EOF
PREPARATION_MODE=FULL
MIRROR_SERVER_IP=${MIRROR_IP}
MIRROR_HTTP_URL=${MIRROR_URL}
EOF
chmod 600 "${FIX4}/etc/ubuntu-mirror/dp-upgrade-mirror.conf"
bundle_sha="$(
  MM_DP_PHASE2_ROOT="${BASE4}/dp-phase2" \
    bash -c '
      source "'"${ROOT}"'/scripts/lib/phase2_helper_generation.sh"
      phase2_published_bundle_sha256 6.6.0
    '
)"
[[ "$bundle_sha" =~ ^[0-9a-fA-F]{64}$ ]] || fail "fixture 6.6.0 bundle sha missing"

set +e
out4="$(
  env \
    UM_PROJECT_ROOT="$ROOT" \
    BASE_PATH="$BASE4" \
    SELECTIVE_MIRROR_ROOT="$SEL4" \
    INSTALL_CONF_DIR="${FIX4}/etc/ubuntu-mirror" \
    INSTALL_LIB_DIR="${FIX4}/usr/local/lib/ubuntu-mirror" \
    INSTALL_BIN_DIR="${FIX4}/usr/local/bin" \
    SKIP_MIRROR_HOST_VALIDATE=1 \
    UM_BOOTSTRAP_ALLOW_SIGNING_DIR_OVERRIDE=1 \
    LOCAL_CLIENT_SIGNING_DIR="$SIGN4" \
    PHASE2_TARGET_VERSION="$TARGET_VER" \
    TARGET_DP_VERSION="$TARGET_VER" \
    MM_DP_PHASE2_ROOT="${BASE4}/dp-phase2" \
    bash -c '
      set -euo pipefail
      source "'"${ROOT}"'/lib/common.sh"
      source "'"${ROOT}"'/lib/bootstrap.sh"
      um_bootstrap_deploy_client_http_artifacts
    ' 2>&1
)"
rc4=$?
set -e
if [[ "$rc4" -eq 0 ]] \
  && echo "$out4" | grep -q 'TARGET_PHASE2_BUNDLE_READY=YES' \
  && [[ -f "${CLIENT4}/upgrade-phase2.sh" ]]
then
  pass "full finalization with 6.6.0 bundle PASS"
  embedded="$(
    awk -F"'" '/^B=/{print $2; exit}' "${CLIENT4}/upgrade-phase2.sh"
  )"
  [[ "$embedded" == "$bundle_sha" ]] \
    && pass "embedded bundle SHA matches published" \
    || fail "embedded=${embedded} published=${bundle_sha}"
  ( cd "$CLIENT4" && sha256sum -c upgrade-phase2.sh.sha256 >/dev/null ) \
    && pass "upgrade-phase2.sh sidecar verifies" \
    || fail "sidecar verify"
  grep -Fq -- '--expected-bundle-sha256' "${CLIENT4}/upgrade-phase2.sh" \
    && pass "wrapper pins --expected-bundle-sha256" \
    || fail "missing --expected-bundle-sha256"
  echo "$out4" | grep -q 'CLIENT_SET_DEPLOY_ATOMIC=YES\|INSTALL_ATOMICALLY_PUBLISHES_FULL_SET=YES' \
    && pass "atomic publish PASS" || fail "atomic publish evidence missing"
else
  fail "full rebuild with 6.6.0 bundle (rc=${rc4})"
  printf '%s\n' "$out4" | tail -80
fi

echo "======== 5. Invalid/missing 6.6.0 SHA: bootstrap defers; rebuild fails closed ========"
HOST5="${WORKDIR}/host5"
setup_host "$HOST5"
BASE5="${HOST5}/var/spool/apt-mirror"
mkdir -p "${BASE5}/dp-phase2/6.6.0"
# Tar present but SHA sidecar missing → not ready
printf 'incomplete-bundle\n' >"${BASE5}/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar"
set +e
out5="$(run_deploy "$HOST5")"
rc5=$?
set -e
[[ "$rc5" -eq 0 ]] && pass "bootstrap defers on missing SHA" || fail "bootstrap should defer missing SHA"
echo "$out5" | grep -q 'PHASE2_UPGRADE_WRAPPER=DEFERRED' \
  && pass "missing SHA → DEFERRED" || fail "missing SHA not deferred"

# Invalid SHA content
printf 'not-a-sha256  dp_bundle_6.6.0-current.tar\n' \
  >"${BASE5}/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar.sha256"
set +e
out5b="$(run_deploy "$HOST5")"
rc5b=$?
set -e
[[ "$rc5b" -eq 0 ]] && pass "bootstrap defers on invalid SHA" || fail "bootstrap should defer invalid SHA"
echo "$out5b" | grep -q 'TARGET_PHASE2_BUNDLE_READY=NO' \
  && pass "invalid SHA → TARGET_PHASE2_BUNDLE_READY=NO" \
  || fail "invalid SHA accepted"

# Explicit complete finalization must fail closed at Phase 2 wrapper (not defer).
# Reuse production-shaped selective tree from case 4 so rebuild reaches wrapper write.
FIX5_CLIENT="${WORKDIR}/fix5-client"
mkdir -p "$FIX5_CLIENT"
rm -f "${BASE4}/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar.sha256"
printf 'not-a-sha256  dp_bundle_6.6.0-current.tar\n' \
  >"${BASE4}/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar.sha256"
set +e
rebuild_out="$(
  env \
    MIRROR_HTTP_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_BASE_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_HOST_IPV4="$MIRROR_IP" \
    LOCAL_CLIENT_SIGNING_DIR="$SIGN4" \
    CLIENT_HTTP_ROOT="$FIX5_CLIENT" \
    SELECTIVE_ROOT="$SEL4" \
    BASE_PATH="$BASE4" \
    CACHE_ROOT="${BASE4}/.install-cache" \
    MM_DP_PHASE2_ROOT="${BASE4}/dp-phase2" \
    PHASE2_TARGET_VERSION="$TARGET_VER" \
    CONTENT_SOURCE=local-fs \
    SKIP_HTTP_VERIFY=1 \
    CLIENT_BUILD_PIN_URL_ONLY=1 \
    REQUIRE_SELECTIVE_READY=1 \
    bash "${ROOT}/scripts/rebuild-publish-clients.sh" 2>&1
)"
rebuild_rc=$?
set -e
[[ "$rebuild_rc" -ne 0 ]] \
  && pass "FULL_FINALIZATION_WITHOUT_660_BUNDLE=FAIL (fail-closed)" \
  || fail "rebuild unexpectedly PASS without valid SHA"
echo "$rebuild_out" | grep -qE 'PHASE2_UPGRADE_WRAPPER=FAIL|bundle_sha_missing|bundle_sha_invalid' \
  && pass "FULL_FINALIZATION_FAILS_CLOSED=YES" \
  || {
    fail "rebuild missing fail-closed evidence"
    printf '%s\n' "$rebuild_out" | tail -40
  }

if [[ "$FAIL" -eq 0 ]]; then
  echo "TEST_BOOTSTRAP_PHASE2_BUNDLE_DEFERRAL=PASS"
  exit 0
fi
echo "TEST_BOOTSTRAP_PHASE2_BUNDLE_DEFERRAL=FAIL"
exit 1
