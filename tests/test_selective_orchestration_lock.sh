#!/usr/bin/env bash
# Lock / orchestration tests for refresh-hop-selective (fixture only; no live mirror).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UOM="${ROOT}/scripts/ubuntu-offline-mirror.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d /tmp/uom-orch-XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Production-equivalent lock helpers (same algorithm as ubuntu-offline-mirror.sh).
ts() { date '+%Y-%m-%d %H:%M:%S'; }
iso_now() { date -Is; }
log() { local level="$1"; shift; printf '%s [%s] %s\n' "$(ts)" "$level" "$*" >&2; }
info() { log INFO "$*"; }
error() { log ERROR "$*"; }
die() { error "$*"; exit 1; }
ok() { log OK "$*"; }

_uom_lock_meta_path() { printf '%s\n' "${LOCK_FILE}.meta"; }

_uom_write_lock_meta() {
  local meta tmp
  meta="$(_uom_lock_meta_path)"
  tmp="${meta}.tmp.$$"
  {
    printf 'pid=%s\n' "$$"
    printf 'started_at=%s\n' "${LOCK_ACQUIRED_AT:-$(iso_now)}"
    printf 'command=%s\n' "${LOCK_COMMAND:-unknown}"
    printf 'hop=%s\n' "${LOCK_HOP:-}"
    printf 'hostname=%s\n' "$(hostname 2>/dev/null || printf 'unknown')"
    printf 'lock_mode=%s\n' "${LOCK_MODE:-STANDALONE}"
    printf 'owner_token=%s\n' "${UOM_LOCK_OWNER_TOKEN:-}"
  } >"$tmp"
  mv -f "$tmp" "$meta"
}

_uom_read_lock_meta_field() {
  local key="$1" meta
  meta="$(_uom_lock_meta_path)"
  [[ -f "$meta" ]] || return 1
  awk -F= -v k="$key" '$1==k {print substr($0, index($0,"=")+1); exit}' "$meta" 2>/dev/null
}

release_global_lock() {
  if [[ "${LOCK_HELD:-0}" != "1" ]] && [[ -z "${LOCK_FD:-}" ]]; then
    return 0
  fi
  local meta meta_token=""
  meta="$(_uom_lock_meta_path)"
  if [[ "${LOCK_HELD:-0}" == "1" && -n "${LOCK_FD:-}" && -n "${UOM_LOCK_OWNER_TOKEN:-}" && -f "$meta" ]]; then
    meta_token="$(_uom_read_lock_meta_field owner_token || true)"
    if [[ "$meta_token" == "$UOM_LOCK_OWNER_TOKEN" ]]; then
      rm -f "$meta" 2>/dev/null || true
    fi
  fi
  if [[ -n "${LOCK_FD:-}" ]]; then
    flock -u "$LOCK_FD" 2>/dev/null || true
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
    LOCK_FD=""
  fi
  LOCK_HELD=0
  UOM_LOCK_OWNER_TOKEN=""
  info "LOCK_RELEASED=PASS"
}

acquire_global_lock_once() {
  local cmd="${1:-unknown}"
  local hop="${2:-}"
  local mode="${3:-STANDALONE}"
  local new_fd="" owner_pid active_cmd active_hop

  if [[ "${LOCK_HELD:-0}" == "1" ]]; then
    error "FAIL_SELECTIVE_ORCHESTRATION_REENTRANT_LOCK"
    error "PARENT_COMMAND=${LOCK_COMMAND:-unknown}"
    error "CHILD_COMMAND=${cmd}"
    die "Reentrant global lock acquire refused"
  fi

  mkdir -p "$(dirname "$LOCK_FILE")"
  exec {new_fd}>"$LOCK_FILE"
  if ! flock -n "$new_fd"; then
    eval "exec ${new_fd}>&-" 2>/dev/null || true
    owner_pid="$(_uom_read_lock_meta_field pid || true)"
    active_cmd="$(_uom_read_lock_meta_field command || true)"
    active_hop="$(_uom_read_lock_meta_field hop || true)"
    error "FAIL_SELECTIVE_MIRROR_LOCK_BUSY"
    error "LOCK_PATH=${LOCK_FILE}"
    [[ -n "$owner_pid" ]] && error "LOCK_OWNER_PID=${owner_pid}"
    [[ -n "$active_cmd" ]] && error "ACTIVE_COMMAND=${active_cmd}"
    [[ -n "$active_hop" ]] && error "ACTIVE_HOP=${active_hop}"
    die "Another ubuntu-offline-mirror process holds ${LOCK_FILE}"
  fi

  LOCK_FD="$new_fd"
  LOCK_HELD=1
  LOCK_COMMAND="$cmd"
  LOCK_HOP="$hop"
  LOCK_MODE="$mode"
  LOCK_ACQUIRED_AT="$(iso_now)"
  UOM_LOCK_OWNER_TOKEN="$$:$(date +%s%N)"
  _uom_write_lock_meta
  ok "LOCK_ACQUIRED=PASS LOCK_MODE=${LOCK_MODE} command=${cmd}"
}

# --- structural checks against production script (grep file directly) ---
grep -Fq 'acquire_global_lock_once "verify-selective"' "$UOM" \
  && pass "standalone verify acquires lock once" || fail "verify lock acquire"
grep -Fq 'acquire_global_lock_once "publish-selective"' "$UOM" \
  && pass "standalone publish acquires lock once" || fail "publish lock acquire"
grep -Fq 'acquire_global_lock_once "refresh-hop-selective"' "$UOM" \
  && pass "refresh acquires lock once" || fail "refresh lock acquire"
grep -Fq 'acquire_global_lock_once "materialize-selective"' "$UOM" \
  && pass "standalone materialize acquires lock once" || fail "materialize lock acquire"

refresh_pub="$(sed -n '/^cmd_refresh_hop_selective()/,/^cmd_migrate_selective_runtime()/p' "$UOM")"
acq_count="$(printf '%s\n' "$refresh_pub" | grep -c 'acquire_global_lock_once' || true)"
[[ "$acq_count" -eq 1 ]] && pass "refresh public acquires lock exactly once" \
  || fail "refresh acquire count=$acq_count"

refresh_impl="$(sed -n '/^cmd_refresh_hop_selective_impl()/,/^cmd_refresh_hop_selective()/p' "$UOM")"
printf '%s\n' "$refresh_impl" | grep -q 'cmd_verify_selective_impl' \
  && pass "refresh calls verify impl" || fail "refresh verify impl"
printf '%s\n' "$refresh_impl" | grep -q 'cmd_publish_selective_impl' \
  && pass "refresh calls publish impl" || fail "refresh publish impl"
printf '%s\n' "$refresh_impl" | grep -q 'cmd_materialize_selective_impl' \
  && pass "refresh calls materialize impl" || fail "refresh materialize impl"

# Reject real re-exec forms; comments mentioning "$0" are OK.
if printf '%s\n' "$refresh_impl" | grep -E '^[^#]*("\$0"|ubuntu-offline-mirror\.sh (verify|publish|materialize)-selective)' >/dev/null; then
  fail "refresh must not re-exec public script"
else
  pass "refresh has no public script recursive invocation"
fi
if printf '%s\n' "$refresh_impl" | grep -E '(^|[[:space:]])cmd_(verify|publish|materialize)_selective([[:space:]]|$)' >/dev/null; then
  fail "refresh must not call public cmd_* (only *_impl)"
else
  pass "refresh does not call public selective cmds"
fi

grep -Fq 'exec {new_fd}>"$LOCK_FILE"' "$UOM" \
  && pass "acquire opens fresh new_fd (not LOCK_FD reuse)" \
  || fail "acquire must use fresh FD variable"

printf '%s\n' "$refresh_impl" | grep -Eiq 'apt-mirror|cmd_sync_full|[[:space:]]cmd_sync[[:space:]]' \
  && fail "refresh must not call full mirror" \
  || pass "refresh has no full mirror invocation"

grep -Fq 'release_global_lock' "$UOM" \
  && pass "script defines release_global_lock" || fail "missing release"
grep -Fq 'cleanup_on_exit' "$UOM" \
  && pass "script uses cleanup_on_exit trap" || fail "missing cleanup trap"
grep -Fq 'FAIL_SELECTIVE_ORCHESTRATION_REENTRANT_LOCK' "$UOM" \
  && pass "reentrant error code present" || fail "missing reentrant code"
grep -Fq 'FAIL_SELECTIVE_MIRROR_LOCK_BUSY' "$UOM" \
  && pass "busy error code present" || fail "missing busy code"
grep -Fq -- '--allow-resume' "$UOM" \
  && pass "materialize passes --allow-resume" || fail "missing allow-resume"
grep -Fq 'refresh-orchestration.json' "$UOM" \
  && pass "orchestration state file recorded" || fail "missing orchestration state"

# --- behavioral: old self-flock bug shape ---
LOCK_FILE="${TMP}/oldbug.lock"
: >"$LOCK_FILE"
bash -c '
LOCK_FILE="'"$LOCK_FILE"'"
LOCK_FD=""
exec {LOCK_FD}>"$LOCK_FILE"
flock -n "$LOCK_FD" || exit 10
exec {LOCK_FD}>"$LOCK_FILE"
if flock -n "$LOCK_FD"; then exit 11; fi
exit 0
' && pass "documents old self-flock conflict shape" || fail "self-flock probe"

# --- reentrant ---
LOCK_FILE="${TMP}/reentry.lock"
LOCK_FD=""; LOCK_HELD=0; LOCK_COMMAND=""; LOCK_HOP=""; LOCK_MODE=""; LOCK_ACQUIRED_AT=""; UOM_LOCK_OWNER_TOKEN=""
acquire_global_lock_once "refresh-hop-selective" "xenial-to-bionic" "OUTER_ORCHESTRATION"
set +e
out="$(acquire_global_lock_once "verify-selective" "" "STANDALONE" 2>&1)"
rc=$?
set -e
printf '%s\n' "$out" | grep -q FAIL_SELECTIVE_ORCHESTRATION_REENTRANT_LOCK \
  && pass "reentrant → FAIL_SELECTIVE_ORCHESTRATION_REENTRANT_LOCK" \
  || fail "reentrant error code"
printf '%s\n' "$out" | grep -q "PARENT_COMMAND=refresh-hop-selective" \
  && pass "reentrant reports PARENT_COMMAND" || fail "PARENT_COMMAND"
printf '%s\n' "$out" | grep -q "CHILD_COMMAND=verify-selective" \
  && pass "reentrant reports CHILD_COMMAND" || fail "CHILD_COMMAND"
[[ "$rc" -ne 0 ]] && pass "reentrant exits non-zero" || fail "reentrant exit"
release_global_lock

# --- concurrent A holds, B blocked ---
LOCK_A="${TMP}/concurrent.lock"
: >"$LOCK_A"
(
  exec 9>"$LOCK_A"
  flock -n 9 || exit 1
  printf 'pid=%s\nstarted_at=now\ncommand=refresh-hop-selective\nhop=xenial-to-bionic\nhostname=test\nlock_mode=OUTER_ORCHESTRATION\n' "$$" >"${LOCK_A}.meta"
  sleep 5
) &
HOLDER_PID=$!
sleep 0.2
LOCK_FILE="$LOCK_A"
LOCK_FD=""; LOCK_HELD=0; LOCK_COMMAND=""; LOCK_HOP=""; LOCK_MODE=""; LOCK_ACQUIRED_AT=""; UOM_LOCK_OWNER_TOKEN=""
set +e
out="$(acquire_global_lock_once "verify-selective" "" "STANDALONE" 2>&1)"
rc=$?
set -e
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
printf '%s\n' "$out" | grep -q FAIL_SELECTIVE_MIRROR_LOCK_BUSY \
  && pass "concurrent B → FAIL_SELECTIVE_MIRROR_LOCK_BUSY" \
  || fail "concurrent lock busy rc=$rc out=$out"
printf '%s\n' "$out" | grep -q "ACTIVE_COMMAND=refresh-hop-selective" \
  && pass "busy includes ACTIVE_COMMAND" || fail "ACTIVE_COMMAND missing"
printf '%s\n' "$out" | grep -q "ACTIVE_HOP=xenial-to-bionic" \
  && pass "busy includes ACTIVE_HOP" || fail "ACTIVE_HOP missing"

# --- stale meta + free flock ---
STALE="${TMP}/stale.lock"
: >"$STALE"
printf 'pid=999999\ncommand=ghost\nhop=\n' >"${STALE}.meta"
LOCK_FILE="$STALE"
LOCK_FD=""; LOCK_HELD=0; LOCK_COMMAND=""; LOCK_HOP=""; LOCK_MODE=""; LOCK_ACQUIRED_AT=""; UOM_LOCK_OWNER_TOKEN=""
acquire_global_lock_once "verify-selective" "" "STANDALONE"
grep -q 'command=verify-selective' "${STALE}.meta" \
  && pass "stale meta overwritten after acquire" || fail "stale meta not rewritten"
release_global_lock
[[ ! -f "${STALE}.meta" ]] && pass "release removes meta" || fail "meta remains"
bash -c 'exec 8>"'"$STALE"'"; flock -n 8' \
  && pass "stale lock file with no owner allows new flock" \
  || fail "could not flock after release"

# --- TERM releases via EXIT (separate bash process; $$ in subshell is parent!) ---
TERM_LOCK="${TMP}/term.lock"
bash -c '
LOCK_FILE="'"$TERM_LOCK"'"
LOCK_FD=""; LOCK_HELD=0; LOCK_COMMAND=""; LOCK_HOP=""; LOCK_MODE=""; LOCK_ACQUIRED_AT=""
ts() { date "+%Y-%m-%d %H:%M:%S"; }
iso_now() { date -Is; }
log() { local level="$1"; shift; printf "%s [%s] %s\n" "$(ts)" "$level" "$*" >&2; }
info() { log INFO "$*"; }
error() { log ERROR "$*"; }
die() { error "$*"; exit 1; }
ok() { log OK "$*"; }
_uom_lock_meta_path() { printf "%s\n" "${LOCK_FILE}.meta"; }
_uom_write_lock_meta() {
  local meta tmp; meta="$(_uom_lock_meta_path)"; tmp="${meta}.tmp.$$"
  { printf "pid=%s\n" "$$"; printf "command=%s\n" "${LOCK_COMMAND:-}"; printf "hop=%s\n" "${LOCK_HOP:-}"; } >"$tmp"
  mv -f "$tmp" "$meta"
}
release_global_lock() {
  if [[ "${LOCK_HELD:-0}" != "1" ]] && [[ -z "${LOCK_FD:-}" ]]; then return 0; fi
  local meta="$(_uom_lock_meta_path)"
  if [[ "${LOCK_HELD:-0}" == "1" && -n "${LOCK_FD:-}" ]]; then rm -f "$meta" 2>/dev/null || true; fi
  if [[ -n "${LOCK_FD:-}" ]]; then flock -u "$LOCK_FD" 2>/dev/null || true; eval "exec ${LOCK_FD}>&-" 2>/dev/null || true; LOCK_FD=""; fi
  LOCK_HELD=0
}
acquire_global_lock_once() {
  local cmd="$1" hop="${2:-}" mode="${3:-}" new_fd=""
  exec {new_fd}>"$LOCK_FILE"
  flock -n "$new_fd" || exit 2
  LOCK_FD="$new_fd"; LOCK_HELD=1; LOCK_COMMAND="$cmd"; LOCK_HOP="$hop"; LOCK_MODE="$mode"
  _uom_write_lock_meta
}
trap release_global_lock EXIT
trap "exit 143" TERM
acquire_global_lock_once "refresh-hop-selective" "xenial-to-bionic" "OUTER_ORCHESTRATION"
kill -TERM $$
sleep 3
' &
TPID=$!
wait "$TPID" 2>/dev/null || true
bash -c 'exec 8>"'"$TERM_LOCK"'"; flock -n 8' \
  && pass "TERM releases flock" || fail "TERM did not release flock"
[[ ! -f "${TERM_LOCK}.meta" ]] && pass "TERM cleans meta" || fail "TERM left meta"

bash --version | head -1 | grep -qE 'version 4\.[3-9]|version [5-9]|version [1-9][0-9]' \
  && pass "bash >= 4.3 available" || fail "bash too old"

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL selective orchestration lock CHECKS PASSED ($PASS)"
  exit 0
fi
echo "SOME selective orchestration lock CHECKS FAILED (pass=$PASS fail=$FAIL)"
exit 1
