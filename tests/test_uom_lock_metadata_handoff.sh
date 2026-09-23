#!/usr/bin/env bash
# Legacy UOM lock metadata must not be deleted by a prior owner after handoff.
# Exercises scripts/ubuntu-offline-mirror.sh acquire/release, not a copied fixture.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UOM="${ROOT}/scripts/ubuntu-offline-mirror.sh"
TMP="$(mktemp -d)"
GATE="${TMP}/gate"
PID_B=""
FAIL=0

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }

cleanup() {
  if [[ -n "${PID_B}" ]]; then
    kill "$PID_B" 2>/dev/null || true
    wait "$PID_B" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

source_uom() {
  export MM_HERMETIC_TEST_MODE=1
  export UOM_SOURCE_ONLY=1
  export LOCK_FILE="${TMP}/uom.lock"
  export LOG_FILE="${TMP}/uom-a.log"
  export MM_LOCK_FILE="${TMP}/publication.lock"
  export MIRROR_ROOT="${TMP}/mirror"
  # shellcheck source=/dev/null
  source "$UOM"
  trap - EXIT INT TERM
  trap cleanup EXIT
}

echo "======== test_uom_lock_metadata_handoff ========"

grep -Fq 'owner_token' "$UOM" \
  && pass "production lock metadata records owner_token" \
  || fail "production metadata writer missing owner_token"
# The post-unlock unconditional delete was the handoff bug.
if awk '
  $0 ~ /^release_global_lock\(\)/ { in_fn=1 }
  in_fn && $0 ~ /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ && $0 !~ /^release_global_lock\(\)/ { exit }
  in_fn && /publication_lock_release/ { after_pub=1 }
  in_fn && after_pub && /rm -f/ { bad=1 }
  END { exit bad ? 0 : 1 }
' "$UOM"; then
  fail "release still removes metadata after publication unlock"
else
  pass "release does not remove metadata after publication unlock"
fi

source_uom

acquire_global_lock_once "sync" "" "STANDALONE" >/dev/null
TOKEN_A="${UOM_LOCK_OWNER_TOKEN}"
[[ -n "$TOKEN_A" ]] && pass "owner token recorded" || fail "missing owner token"
grep -q "^owner_token=${TOKEN_A}$" "${LOCK_FILE}.meta" \
  && pass "meta stores owner token" || fail "meta missing owner token"

# Ownership check while A still holds the flock: foreign metadata must survive.
printf 'pid=999\nstarted_at=now\ncommand=sync\nhop=\nhostname=test\nlock_mode=STANDALONE\nowner_token=OTHER_OWNER\n' \
  >"${LOCK_FILE}.meta"
release_global_lock >/dev/null
if [[ -f "${LOCK_FILE}.meta" ]] && grep -q '^owner_token=OTHER_OWNER$' "${LOCK_FILE}.meta"; then
  pass "release does not delete metadata owned by another holder"
else
  fail "foreign metadata was deleted"
fi

acquire_global_lock_once "sync" "" "STANDALONE" >/dev/null
TOKEN_OWN="${UOM_LOCK_OWNER_TOKEN}"
[[ -n "$TOKEN_OWN" && "$TOKEN_OWN" != "$TOKEN_A" ]] \
  && pass "reacquire minted a new owner token" \
  || fail "owner token was not replaced"
grep -q "^owner_token=${TOKEN_OWN}$" "${LOCK_FILE}.meta" \
  && pass "reacquire rewrote own metadata" || fail "own metadata missing after reacquire"
release_global_lock >/dev/null
[[ ! -f "${LOCK_FILE}.meta" ]] \
  && pass "own metadata removed before unlock" \
  || fail "own metadata remained after release"

# Deterministic handoff: A's release unlocks, then a hook lets B acquire and
# write metadata before A's release returns. A's trailing work must not delete it.
acquire_global_lock_once "sync" "" "STANDALONE" >/dev/null
TOKEN_BEFORE="${UOM_LOCK_OWNER_TOKEN}"

uom_lock_release_after_unlock_hook() {
  : >"${GATE}.unlocked"
  local _
  for _ in $(seq 1 1500); do
    [[ -f "${GATE}.b_holding" ]] && return 0
    sleep 0.02
  done
  : >"${GATE}.hook_timeout"
  return 0
}

cat >"${TMP}/holder-b.sh" <<EOS
#!/usr/bin/env bash
set -euo pipefail
export MM_HERMETIC_TEST_MODE=1
export UOM_SOURCE_ONLY=1
export LOCK_FILE="${LOCK_FILE}"
export LOG_FILE="${TMP}/uom-b.log"
export MM_LOCK_FILE="${MM_LOCK_FILE}"
export MIRROR_ROOT="${MIRROR_ROOT}"
# shellcheck source=/dev/null
source "${UOM}"
trap - EXIT INT TERM
for _ in \$(seq 1 1500); do
  [[ -f "${GATE}.unlocked" ]] && break
  sleep 0.02
done
[[ -f "${GATE}.unlocked" ]] || { echo "B missed unlock" >&2; exit 1; }
acquire_global_lock_once "sync" "" "STANDALONE" >/dev/null
printf '%s\n' "\$UOM_LOCK_OWNER_TOKEN" >"${GATE}.tokenB"
: >"${GATE}.b_holding"
for _ in \$(seq 1 1500); do
  [[ -f "${GATE}.a_done" ]] && break
  sleep 0.02
done
[[ -f "${GATE}.a_done" ]] || { echo "B timed out waiting for A" >&2; exit 1; }
release_global_lock >/dev/null
EOS
chmod 0700 "${TMP}/holder-b.sh"
bash "${TMP}/holder-b.sh" &
PID_B=$!

release_global_lock >/dev/null
TOKEN_B=""
[[ -f "${GATE}.tokenB" ]] && TOKEN_B="$(cat "${GATE}.tokenB")"
if [[ -f "${GATE}.hook_timeout" ]]; then
  fail "successor did not acquire before prior release returned"
elif [[ -n "$TOKEN_B" && "$TOKEN_B" != "$TOKEN_BEFORE" && -f "${LOCK_FILE}.meta" ]] \
  && grep -q "^owner_token=${TOKEN_B}$" "${LOCK_FILE}.meta"; then
  pass "successor metadata survives prior owner release"
else
  fail "successor metadata missing after prior owner release tokenB=${TOKEN_B:-empty}"
fi

set +e
busy_out="$(acquire_global_lock_once "sync" "" "STANDALONE" 2>&1)"
busy_rc=$?
set -e
if [[ "$busy_rc" -ne 0 ]] && printf '%s\n' "$busy_out" | grep -qE 'PUBLICATION_LOCK=BUSY|FAIL_SELECTIVE_MIRROR_LOCK_BUSY'; then
  pass "successor still holds the lock after prior release"
else
  fail "expected busy while successor holds rc=${busy_rc}"
fi

: >"${GATE}.a_done"
wait "$PID_B"
b_rc=$?
PID_B=""
[[ "$b_rc" -eq 0 ]] && pass "successor released cleanly" || fail "successor exit rc=${b_rc}"
[[ ! -f "${LOCK_FILE}.meta" ]] \
  && pass "successor removed its own metadata" \
  || fail "successor metadata remained after its release"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
echo "ALL PASS"
exit 0
