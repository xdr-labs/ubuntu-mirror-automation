#!/usr/bin/env bash
# Install-lock metadata must not be deleted by a prior owner after handoff.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }

export MM_PROJECT_ROOT="$ROOT"
export MM_LOCK_FILE="$TMP/ubuntu-mirror-manager.lock"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_HERMETIC_TEST_MODE=1
export MM_SKIP_ROOT_CHECK=1

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"

echo "======== test_install_lock_metadata_handoff ========"

# Owner A acquires and writes metadata.
mm_acquire_install_lock >/dev/null
TOKEN_A="${MM_LOCK_OWNER_TOKEN}"
[[ -n "$TOKEN_A" ]] && pass "owner token recorded" || fail "missing owner token"
grep -q "^owner_token=${TOKEN_A}$" "${MM_LOCK_FILE}.meta" \
  && pass "meta stores owner token" || fail "meta missing owner token"

# Simulate handoff: B has acquired (we keep flock via FD but rewrite meta as B
# would after A unlocked). Then A's release must not delete B's meta.
# Because A still holds the flock here, we instead test the ownership check
# by pointing MM_LOCK_OWNER_TOKEN at A while meta belongs to B.
printf 'pid=999\nrun_id=b\nstarted_at=now\nowner_token=OTHER_OWNER\n' >"${MM_LOCK_FILE}.meta"
mm_release_install_lock
if [[ -f "${MM_LOCK_FILE}.meta" ]] && grep -q '^owner_token=OTHER_OWNER$' "${MM_LOCK_FILE}.meta"; then
  pass "release does not delete metadata owned by another holder"
else
  fail "foreign metadata was deleted"
fi

# Own-token release removes metadata while the lock is still held.
mm_acquire_install_lock >/dev/null
TOKEN_OWN="${MM_LOCK_OWNER_TOKEN}"
[[ -f "${MM_LOCK_FILE}.meta" ]] && grep -q "^owner_token=${TOKEN_OWN}$" "${MM_LOCK_FILE}.meta" \
  && pass "reacquire rewrote own metadata" || fail "own metadata missing after reacquire"
mm_release_install_lock
[[ ! -f "${MM_LOCK_FILE}.meta" ]] \
  && pass "own metadata removed before unlock" \
  || fail "own metadata remained after release"

# Concurrent: process A holds, process B is busy, then B acquires after A releases
# and B's meta survives A's exit (ownership check).
holder="$TMP/holder.sh"
cat >"$holder" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$1"
LOCK="$2"
GATE="$3"
export MM_PROJECT_ROOT="$ROOT"
export MM_LOCK_FILE="$LOCK"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_HERMETIC_TEST_MODE=1
export MM_SKIP_ROOT_CHECK=1
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
mm_acquire_install_lock >/dev/null
printf '%s\n' "$MM_LOCK_OWNER_TOKEN" >"${GATE}.tokenA"
: >"${GATE}.held"
while [[ -f "${GATE}.hold" ]]; do sleep 0.01; done
mm_release_install_lock
EOS
chmod 0700 "$holder"

GATE="$TMP/gate"
rm -f "${GATE}.held" "${GATE}.hold" "${GATE}.tokenA"
: >"${GATE}.hold"
bash "$holder" "$ROOT" "$MM_LOCK_FILE" "$GATE" &
pidA=$!
for _ in $(seq 1 500); do
  [[ -f "${GATE}.held" ]] && break
  sleep 0.01
done
[[ -f "${GATE}.held" ]] && pass "holder A acquired" || fail "holder A did not acquire"

set +e
(
  export MM_PROJECT_ROOT="$ROOT"
  export MM_LOCK_FILE
  export SKIP_MIRROR_HOST_VALIDATE=1
  export MM_HERMETIC_TEST_MODE=1
  export MM_SKIP_ROOT_CHECK=1
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/lib/mirror_manager_common.sh"
  mm_acquire_install_lock
) >"$TMP/busy.out" 2>"$TMP/busy.err"
BUSY_RC=$?
set -e
[[ "$BUSY_RC" -ne 0 ]] && grep -q 'INSTALL_LOCK=BUSY' "$TMP/busy.err" \
  && pass "second acquire is busy while A holds" \
  || fail "expected BUSY rc=${BUSY_RC}"

rm -f "${GATE}.hold"
wait "$pidA"

# After A releases, B acquires and writes its own meta; A's process is gone.
mm_acquire_install_lock >/dev/null
TOKEN_B="${MM_LOCK_OWNER_TOKEN}"
TOKEN_A_SAVED="$(cat "${GATE}.tokenA")"
[[ "$TOKEN_B" != "$TOKEN_A_SAVED" ]] && pass "new owner has distinct token" || fail "token reused unexpectedly"
grep -q "^owner_token=${TOKEN_B}$" "${MM_LOCK_FILE}.meta" \
  && pass "new owner metadata present after handoff" \
  || fail "new owner metadata missing"
mm_release_install_lock
[[ ! -f "${MM_LOCK_FILE}.meta" ]] && pass "new owner cleaned own metadata" || fail "new owner meta leftover"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
echo "ALL PASS"
exit 0
