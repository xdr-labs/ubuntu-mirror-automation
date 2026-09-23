#!/usr/bin/env bash
# Parent client finalizer must hand the child the publication-lock FD.
# MM_LOCK_FD may be a different install-lock descriptor; forwarding that FD
# makes rebuild-publish-clients.sh reject it and self-BUSY on the real lock.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }

echo "======== test_client_finalizer_inherited_publication_lock ========"

ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
grep -q 'engine_inherited_publication_lock_fd' "$ENGINE" \
  && ! grep -q 'MM_PUBLICATION_LOCK_INHERITED_FD="${MM_LOCK_FD' "$ENGINE" \
  && pass "finalizer does not forward MM_LOCK_FD blindly" \
  || fail "finalizer still forwards MM_LOCK_FD unconditionally"

export MM_PROJECT_ROOT="$ROOT"
export MM_HERMETIC_TEST_MODE=1
export MM_SKIP_ROOT_CHECK=1
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_PUBLICATION_LOCK_PROBE=1
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$MM_CONFIG_DIR/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$MM_CONFIG_DIR/status"
export MM_STATE_DIR="$TMP/state"
export MM_MIRROR_ROOT="$TMP/mirror"
export MM_SELECTIVE_ROOT="$MM_MIRROR_ROOT/selective"
export MM_CLIENT_ROOT="$MM_MIRROR_ROOT/client"
export MM_CACHE_ROOT="$TMP/cache"
export MM_LOCK_FILE="$TMP/publication.lock"
export LOCAL_CLIENT_SIGNING_DIR="$TMP/config/client-signing"
export MIRROR_HTTP_URL="http://mirror.example/ubuntu"
export MIRROR_SERVER_IP=""
mkdir -p "$MM_CONFIG_DIR" "$MM_STATE_DIR" "$MM_CLIENT_ROOT" "$MM_CACHE_ROOT" "$MM_SELECTIVE_ROOT"

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=/dev/null
source "$ENGINE"

# --- split descriptors: publication FD  vs a different install FD ---
publication_lock_acquire
PUB_FD="${PUBLICATION_LOCK_FD}"
exec {INSTALL_FD}>"$TMP/install.lock"
flock -n "$INSTALL_FD"
MM_LOCK_FD="$INSTALL_FD"
MM_LOCK_HELD=1
[[ "$PUB_FD" != "$INSTALL_FD" ]] && pass "publication and install descriptors differ" \
  || fail "test fixture did not open two descriptors pub=${PUB_FD} install=${INSTALL_FD}"

got="$(engine_inherited_publication_lock_fd)"
[[ "$got" == "$PUB_FD" ]] && pass "selector returns publication fd ${PUB_FD} not install fd ${INSTALL_FD}" \
  || fail "selector returned ${got:-empty} want ${PUB_FD}"

rm -f "$MM_STATE_DIR"/client-finalization-*.log
set +e
set +o pipefail
engine_rebuild_publish_local_client_set 1 >"$TMP/finalizer-split.out" 2>"$TMP/finalizer-split.err"
SPLIT_RC=$?
set -o pipefail
set -e
SPLIT_LOG="$(ls -1 "$MM_STATE_DIR"/client-finalization-*.log 2>/dev/null | head -n1 || true)"
SPLIT_FD=""
if [[ -n "$SPLIT_LOG" ]]; then
  SPLIT_FD="$(sed -n 's/.*PUBLICATION_LOCK_ACQUIRED=YES .*fd=\([0-9]*\).*/\1/p' "$SPLIT_LOG" | head -n1)"
fi
[[ "$SPLIT_RC" -eq 0 && "$SPLIT_FD" == "$PUB_FD" && "$SPLIT_FD" != "$INSTALL_FD" ]] \
  && pass "real finalizer child inherited publication fd ${SPLIT_FD}" \
  || fail "split finalizer rc=${SPLIT_RC} child_fd=${SPLIT_FD:-unset} pub=${PUB_FD} install=${INSTALL_FD} log=${SPLIT_LOG:-missing} err=$(cat "$TMP/finalizer-split.err")"

# Child exit must not drop the parent's publication lock.
exec {THIRD}>"$MM_LOCK_FILE"
if flock -n "$THIRD"; then
  fail "publication lock was released by the child finalizer"
  flock -u "$THIRD" || true
else
  pass "parent still holds publication lock after child exit"
fi
eval "exec ${THIRD}>&-"
publication_lock_release
flock -u "$INSTALL_FD" 2>/dev/null || true
eval "exec ${INSTALL_FD}>&-"
MM_LOCK_FD=""
MM_LOCK_HELD=0

# --- production Menu 2 shape: install acquire is the publication lock ---
mm_acquire_install_lock >/dev/null
[[ -n "${PUBLICATION_LOCK_FD}" && "$PUBLICATION_LOCK_FD" == "$MM_LOCK_FD" ]] \
  && pass "install acquire records publication fd ${PUBLICATION_LOCK_FD}" \
  || fail "install acquire left PUBLICATION_LOCK_FD=${PUBLICATION_LOCK_FD:-unset} MM_LOCK_FD=${MM_LOCK_FD:-unset}"
MENU_FD="$MM_LOCK_FD"
rm -f "$MM_STATE_DIR"/client-finalization-*.log
set +e
set +o pipefail
engine_rebuild_publish_local_client_set 1 >"$TMP/finalizer-menu.out" 2>"$TMP/finalizer-menu.err"
MENU_RC=$?
set -o pipefail
set -e
MENU_LOG="$(ls -1 "$MM_STATE_DIR"/client-finalization-*.log 2>/dev/null | head -n1 || true)"
MENU_CHILD_FD=""
if [[ -n "$MENU_LOG" ]]; then
  MENU_CHILD_FD="$(sed -n 's/.*PUBLICATION_LOCK_ACQUIRED=YES .*fd=\([0-9]*\).*/\1/p' "$MENU_LOG" | head -n1)"
fi
[[ "$MENU_RC" -eq 0 && "$MENU_CHILD_FD" == "$MENU_FD" ]] \
  && pass "menu2 finalizer child inherited install-held publication fd ${MENU_CHILD_FD}" \
  || fail "menu2 finalizer rc=${MENU_RC} child_fd=${MENU_CHILD_FD:-unset} parent=${MENU_FD} err=$(cat "$TMP/finalizer-menu.err")"
exec {THIRD}>"$MM_LOCK_FILE"
if flock -n "$THIRD"; then
  fail "menu2 publication lock was released by the child"
  flock -u "$THIRD" || true
else
  pass "menu2 parent still holds publication lock after child exit"
fi
eval "exec ${THIRD}>&-"
mm_release_install_lock

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
echo "ALL PASS"
