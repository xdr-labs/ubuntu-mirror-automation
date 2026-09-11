#!/usr/bin/env bash
# Targeted regression: monitor must ignore historical failure markers.
# Does not run a real upgrade or access a DP.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IN="${ROOT}/client/dp-offline-upgrade-bionic-to-focal.sh.in"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q 'MONITOR_ATTACH_LOG_OFFSET' "$IN" \
  || fail "MONITOR_ATTACH_LOG_OFFSET missing from bionic-to-focal template"
grep -q 'MONITOR_ATTACH_LOG_OFFSET' "$IN" \
  && grep -q 'tail -c' "$IN" \
  || fail "offset-bounded log scan missing"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="${TMP}/offline_os_upgrade.log"

# Historical failure from a previous attempt, then a new successful run.
{
  echo "STATE=FAILED"
  echo "os_upgrade_result=FAIL"
  echo "UPGRADE_FAILED=YES"
  echo "FAIL_STAGE=do-release-upgrade"
} >"$LOG"
OFFSET="$(wc -c <"$LOG" | tr -d '[:space:]')"
{
  echo "STATE=CONFIGURING"
  echo "do-release-upgrade still running"
} >>"$LOG"

cat >"${TMP}/harness.sh" <<'EOS'
hostpath() { printf '%s' "$1"; }
LOG_FILE="$1"
MONITOR_ATTACH_LOG_OFFSET="$2"
MONITOR_LOG_OFFSET="$2"
log_has_terminal_failure_marker() {
  local logf size offset chunk
  logf="$(hostpath "$LOG_FILE")"
  [[ -f "$logf" ]] || return 1
  offset="${MONITOR_ATTACH_LOG_OFFSET:-${MONITOR_LOG_OFFSET:-0}}"
  [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
  size="$(wc -c <"$logf" | tr -d '[:space:]')"
  [[ -n "$size" ]] || size=0
  if [[ "$size" -le "$offset" ]]; then
    return 1
  fi
  chunk="$(tail -c "+$((offset + 1))" "$logf" 2>/dev/null || true)"
  [[ -n "$chunk" ]] || return 1
  printf '%s' "$chunk" | grep -qE 'STATE=FAILED|os_upgrade_result=FAIL|UPGRADE_FAILED=YES|FAIL_STAGE='
}
EOS

# shellcheck disable=SC1090
source "${TMP}/harness.sh" "$LOG" "$OFFSET"
if log_has_terminal_failure_marker; then
  fail "historical STATE=FAILED matched after attach offset"
fi
pass "historical failure markers ignored"

echo "STATE=FAILED" >>"$LOG"
if log_has_terminal_failure_marker; then
  pass "new STATE=FAILED after attach is detected"
else
  fail "current-run STATE=FAILED not detected"
fi

echo "ALL test_monitor_stale_log_offset checks passed"
