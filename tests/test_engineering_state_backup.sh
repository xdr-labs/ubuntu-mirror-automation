#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/engineering-state-backup.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

state="$tmp/state/os-upgrade"
mkdir -p "$state"
printf 'COMPLETE\n' > "$state/status"
archive="$tmp/state-backup.tgz"

ENGINEERING_STATE_ROOT="$state" bash "$SCRIPT" backup "$archive" >"$tmp/backup.out"
grep -q '^ENGINEERING_STATE_BACKUP=PASS ' "$tmp/backup.out"
[[ -s "$archive" ]]

ENGINEERING_STATE_ROOT="$state" bash "$SCRIPT" verify "$archive" >"$tmp/verify.out"
grep -q '^ENGINEERING_STATE_RESTORE_TEST=PASS ' "$tmp/verify.out"

if ENGINEERING_STATE_ROOT="$state" bash "$SCRIPT" backup "$archive" >/dev/null 2>&1; then
  echo "FAIL: backup unexpectedly overwrote an existing archive" >&2
  exit 1
fi

wrong="$tmp/wrong.tgz"
mkdir -p "$tmp/other"
printf 'x\n' > "$tmp/other/file"
tar -czf "$wrong" -C "$tmp" other
if ENGINEERING_STATE_ROOT="$state" bash "$SCRIPT" verify "$wrong" >/dev/null 2>&1; then
  echo "FAIL: verify accepted an archive without the durable state root" >&2
  exit 1
fi

echo "ENGINEERING_STATE_BACKUP_TEST=PASS"
