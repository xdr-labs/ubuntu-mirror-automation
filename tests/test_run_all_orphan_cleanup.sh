#!/usr/bin/env bash
# The suite's orphan scavenger must not kill live fixtures in other suites.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d /tmp/tmp.XXXXXXXX)"
live=""
orphan=""
cleanup() {
  [[ -z "$live" ]] || builtin kill -TERM "$live" 2>/dev/null || true
  [[ -z "$orphan" ]] || builtin kill -TERM "$orphan" 2>/dev/null || true
  [[ -z "$live" ]] || wait "$live" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# Source just the production suite helper, never start the actual test suite.
awk '
  /^clear_test_fixture_orphans\(\) \{/ { inside=1 }
  inside { print }
  inside && /^}/ { exit }
' "$ROOT/tests/run_all.sh" > "$tmp/helper.sh"
source "$tmp/helper.sh"
declare -F clear_test_fixture_orphans >/dev/null

# An actively owned fixture is still parented by this test process.
python3 - "$tmp/http-counts" <<'PY' &
import time
time.sleep(60)
PY
live=$!

# A process surviving its launcher is reparented to PID 1: truly orphaned.
(
  python3 - "$tmp/http-counts" <<'PY' &
import time
time.sleep(60)
PY
  printf '%s\n' "$!" > "$tmp/orphan.pid"
)
orphan="$(cat "$tmp/orphan.pid")"
[[ -r "/proc/$live/status" && -r "/proc/$orphan/status" ]]
live_parent="$(awk '/^PPid:/ {print $2; exit}' "/proc/$live/status")"
orphan_parent="$(awk '/^PPid:/ {print $2; exit}' "/proc/$orphan/status")"
[[ "$live_parent" == "$$" ]] || { echo "FAIL: live fixture parent unknown" >&2; exit 1; }
[[ "$orphan_parent" == 1 ]] || { echo "FAIL: orphan fixture parent unknown" >&2; exit 1; }

# Restrict process enumeration to our two fixtures and intercept every signal.
trace="$tmp/signals"
: > "$trace"
ps() { printf '%s\n%s\n' "$live" "$orphan"; }
kill() { printf '%s\n' "$*" >> "$trace"; }
clear_test_fixture_orphans

if grep -qE "[[:space:]]$live$" "$trace"; then
  echo "FAIL: suite cleanup targeted an active fixture" >&2
  exit 1
fi
grep -q -- "-TERM $orphan" "$trace"
grep -q -- "-KILL $orphan" "$trace"
echo "RUN_ALL_ORPHAN_CLEANUP_TEST=PASS"
