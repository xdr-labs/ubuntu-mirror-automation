#!/usr/bin/env bash
# Concurrent mm_wf_set_many writers must not lose updates (stable lock inode).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
LOST_UPDATES=0
REPETITIONS="${WF_CONCURRENT_REPS:-40}"
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }
expect() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

export MM_PROJECT_ROOT="$ROOT"
export MM_CONFIG_DIR="$TMP/config"
export MM_WORKFLOW_FILE="$MM_CONFIG_DIR/workflow.state"
export MM_STATUS_FILE="$MM_CONFIG_DIR/status"
export SKIP_MIRROR_HOST_VALIDATE=1
mkdir -p "$MM_CONFIG_DIR"
: >"$MM_STATUS_FILE"

# shellcheck source=../scripts/lib/mirror_workflow_state.sh
source "${ROOT}/scripts/lib/mirror_workflow_state.sh"

wf_get_local() {
  local key="$1"
  awk -F= -v k="$key" '$1==k { print substr($0, length($1) + 2); exit }' "$MM_WORKFLOW_FILE" 2>/dev/null || true
}

writer_script="$TMP/writer.sh"
cat >"$writer_script" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$1"
WF="$2"
KEY="$3"
VAL="$4"
GATE="${5:-}"
export MM_WORKFLOW_FILE="$WF"
export MM_CONFIG_DIR="$(dirname "$WF")"
export SKIP_MIRROR_HOST_VALIDATE=1
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_workflow_state.sh"
if [[ -n "$GATE" ]]; then
  export MM_WF_TEST_LOCK_HOLD_GATE="$GATE"
fi
mm_wf_set_many "${KEY}=${VAL}"
EOS
chmod 0700 "$writer_script"

# ---------------------------------------------------------------------------
# A. Lock target is a dedicated stable file; state rename does not replace it.
# ---------------------------------------------------------------------------
mm_wf_ensure_file >/dev/null
lockf="$(mm_wf_lock_file)"
expect "lock path is state.lock" test "$lockf" = "${MM_WORKFLOW_FILE}.lock"
mm_wf_set_many "KEY_BASE=base" >/dev/null
expect "dedicated lock file created" test -f "$lockf"
lock_mode="$(stat -c '%a' "$lockf")"
expect "lock file not world-writable mode=${lock_mode}" \
  bash -c '[[ "$1" != *[!0-7]* && $(( 8#$1 & 0002 )) -eq 0 ]]' _ "$lock_mode"
ino_before="$(stat -c '%i' "$lockf")"
mm_wf_set_many "KEY_PROBE=probe" >/dev/null
ino_after="$(stat -c '%i' "$lockf")"
expect "lock inode stable across state rename" test "$ino_before" = "$ino_after"
state_ino_before="$(stat -c '%i' "$MM_WORKFLOW_FILE")"
mm_wf_set_many "KEY_PROBE2=probe2" >/dev/null
state_ino_after="$(stat -c '%i' "$MM_WORKFLOW_FILE")"
# Atomic rename replaces the state path with a new inode from the temp file.
if [[ "$state_ino_before" != "$state_ino_after" ]]; then
  pass "state file replaced by atomic rename (inode changed)"
else
  # Same-inode replace is unusual for mktemp+mv but still acceptable if content is correct.
  expect "state update applied even if inode reused" \
    test "$(wf_get_local KEY_PROBE2)" = "probe2"
fi
expect "state KEY_PROBE2 present after rename" test "$(wf_get_local KEY_PROBE2)" = "probe2"

# ---------------------------------------------------------------------------
# B. Deterministic gated concurrent writers (different keys).
# ---------------------------------------------------------------------------
: >"$MM_WORKFLOW_FILE"
cat >"$MM_WORKFLOW_FILE" <<'EOF'
WORKFLOW_STATE=CONFIGURED
KEY_BASE=base
EOF
chmod 600 "$MM_WORKFLOW_FILE"
GATE="$TMP/gate"
rm -f "${GATE}.held" "${GATE}.hold" "${GATE}.doneA" "${GATE}.doneB"
: >"${GATE}.hold"

bash "$writer_script" "$ROOT" "$MM_WORKFLOW_FILE" KEY_A valueA "$GATE" \
  >"$TMP/outA.log" 2>"$TMP/errA.log" &
pidA=$!
for _ in $(seq 1 500); do
  [[ -f "${GATE}.held" ]] && break
  sleep 0.01
done
expect "writer A acquired and held lock" test -f "${GATE}.held"

bash "$writer_script" "$ROOT" "$MM_WORKFLOW_FILE" KEY_B valueB \
  >"$TMP/outB.log" 2>"$TMP/errB.log" &
pidB=$!

# While A holds the lock, B must not finish (stable lock serializes writers).
blocked=1
for _ in $(seq 1 30); do
  if ! kill -0 "$pidB" 2>/dev/null; then
    blocked=0
    break
  fi
  sleep 0.02
done
expect "writer B blocked while A holds dedicated lock" test "$blocked" -eq 1

rm -f "${GATE}.hold"
wait "$pidA"
rcA=$?
wait "$pidB"
rcB=$?
expect "gated writer A rc=0" test "$rcA" -eq 0
expect "gated writer B rc=0" test "$rcB" -eq 0
expect "gated KEY_BASE preserved" test "$(wf_get_local KEY_BASE)" = "base"
expect "gated KEY_A present" test "$(wf_get_local KEY_A)" = "valueA"
expect "gated KEY_B present" test "$(wf_get_local KEY_B)" = "valueB"

# ---------------------------------------------------------------------------
# C. Repeated concurrent races (real mm_wf_set_many, no mock).
# ---------------------------------------------------------------------------
lost=0
for i in $(seq 1 "$REPETITIONS"); do
  cat >"$MM_WORKFLOW_FILE" <<EOF
WORKFLOW_STATE=CONFIGURED
KEY_BASE=base
ROUND=${i}
EOF
  chmod 600 "$MM_WORKFLOW_FILE"
  SYNC="$TMP/sync.$i"
  mkdir -p "$SYNC"
  (
    # Wait until sibling is ready, then both update.
    : >"$SYNC/readyA"
    while [[ ! -f "$SYNC/readyB" ]]; do sleep 0.001; done
    bash "$writer_script" "$ROOT" "$MM_WORKFLOW_FILE" KEY_A "valueA-$i"
  ) >"$TMP/repA.$i.log" 2>&1 &
  pa=$!
  (
    : >"$SYNC/readyB"
    while [[ ! -f "$SYNC/readyA" ]]; do sleep 0.001; done
    bash "$writer_script" "$ROOT" "$MM_WORKFLOW_FILE" KEY_B "valueB-$i"
  ) >"$TMP/repB.$i.log" 2>&1 &
  pb=$!
  wait "$pa"
  ra=$?
  wait "$pb"
  rb=$?
  if [[ "$ra" -ne 0 || "$rb" -ne 0 ]]; then
    fail "rep $i writer failure rcA=$ra rcB=$rb"
    lost=$((lost + 1))
    continue
  fi
  base="$(wf_get_local KEY_BASE)"
  a="$(wf_get_local KEY_A)"
  b="$(wf_get_local KEY_B)"
  if [[ "$base" != "base" || "$a" != "valueA-$i" || "$b" != "valueB-$i" ]]; then
    fail "rep $i lost update KEY_BASE=$base KEY_A=$a KEY_B=$b"
    lost=$((lost + 1))
  fi
done
LOST_UPDATES=$lost
if [[ "$lost" -eq 0 ]]; then
  pass "concurrent writers ${REPETITIONS}/${REPETITIONS} no lost updates"
else
  fail "concurrent writers lost_updates=${lost}/${REPETITIONS}"
fi

# ---------------------------------------------------------------------------
# D. Unrelated keys preserved under concurrent updates.
# ---------------------------------------------------------------------------
cat >"$MM_WORKFLOW_FILE" <<'EOF'
WORKFLOW_STATE=PREPARED
KEY_BASE=base
KEEP_ME=untouched
OTHER=keep
EOF
chmod 600 "$MM_WORKFLOW_FILE"
bash "$writer_script" "$ROOT" "$MM_WORKFLOW_FILE" KEY_A valueA &
pa=$!
bash "$writer_script" "$ROOT" "$MM_WORKFLOW_FILE" KEY_B valueB &
pb=$!
wait "$pa"; wait "$pb"
expect "unrelated KEEP_ME preserved" test "$(wf_get_local KEEP_ME)" = "untouched"
expect "unrelated OTHER preserved" test "$(wf_get_local OTHER)" = "keep"
expect "unrelated KEY_BASE preserved" test "$(wf_get_local KEY_BASE)" = "base"
expect "unrelated KEY_A present" test "$(wf_get_local KEY_A)" = "valueA"
expect "unrelated KEY_B present" test "$(wf_get_local KEY_B)" = "valueB"

# ---------------------------------------------------------------------------
# E. Fail-closed: unwritable / unreadable state still fails closed.
# ---------------------------------------------------------------------------
chmod 000 "$MM_WORKFLOW_FILE" 2>/dev/null || true
if mm_wf_set_many "KEY_FAIL=should_not" 2>/dev/null; then
  fail "unreadable/unwritable state should fail closed"
else
  pass "unwritable state fails closed"
fi
chmod 600 "$MM_WORKFLOW_FILE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# F. Lock released after process death (no stale exclusive flock).
# ---------------------------------------------------------------------------
HOLD="$TMP/deathgate"
rm -f "${HOLD}.held" "${HOLD}.hold"
: >"${HOLD}.hold"
bash "$writer_script" "$ROOT" "$MM_WORKFLOW_FILE" KEY_DEATH dead1 "$HOLD" \
  >"$TMP/death.log" 2>&1 &
death_pid=$!
for _ in $(seq 1 500); do
  [[ -f "${HOLD}.held" ]] && break
  sleep 0.01
done
expect "death-test writer held lock" test -f "${HOLD}.held"
kill -9 "$death_pid" 2>/dev/null || true
wait "$death_pid" 2>/dev/null || true
rm -f "${HOLD}.hold"
# New writer must acquire promptly (kernel drops flock on process death).
if timeout 5 bash "$writer_script" "$ROOT" "$MM_WORKFLOW_FILE" KEY_AFTER after_death; then
  pass "lock released after process death"
  expect "post-death update applied" test "$(wf_get_local KEY_AFTER)" = "after_death"
else
  fail "lock not released after process death (timeout/acquire fail)"
fi

# Pure-read path does not take the exclusive lock.
expect "pure read KEY_AFTER" test "$(mm_wf_get KEY_AFTER)" = "after_death"
expect "pure read KEY_BASE" test "$(mm_wf_get KEY_BASE)" = "base"

printf '\nCONCURRENT_TEST_REPETITIONS=%s\n' "$REPETITIONS"
printf 'LOST_UPDATES=%s\n' "$LOST_UPDATES"
printf 'DEDICATED_LOCK=%s\n' "$(mm_wf_lock_file)"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
echo "ALL PASS"
exit 0
