#!/usr/bin/env bash
# Hermetic Phase 1 orphan-state gate: real log evidence must not disappear
# on a directory with many matching log files under Bash pipefail.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/dp-os-upgrade-common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OSU_STATE_DIR="$TMP/os-upgrade"
mkdir -p "$OSU_STATE_DIR/logs"
for n in $(seq -w 1 4000); do : > "$OSU_STATE_DIR/logs/upgrade-evidence-${n}.log"; done
osu_detect_orphaned_state || {
  echo 'FAIL: log-only orphan upgrade state was ignored under pipefail' >&2
  exit 1
}
echo 'PASS: log-only orphan upgrade state detected despite many log files'
rm -rf "$OSU_STATE_DIR/logs"
mkdir -p "$OSU_STATE_DIR/logs"
if osu_detect_orphaned_state; then
  echo 'FAIL: empty logs directory counted as upgrade progress' >&2
  exit 1
fi
echo 'PASS: empty log directory does not invent orphan evidence'
