#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/engineering-state-backup.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

state="$tmp/state/os-upgrade"
mkdir -p "$state/offline"
printf 'COMPLETE\n' > "$state/offline/state"
archive="$tmp/state-backup.tgz"
before="$(sha256sum "$state/offline/state" | awk '{print $1}')"

ENGINEERING_STATE_ROOT="$state" bash "$SCRIPT" backup "$archive" > "$tmp/backup.out"
grep -q '^ENGINEERING_STATE_BACKUP=PASS ' "$tmp/backup.out"
[[ -s "$archive" && ! -L "$archive" ]]
[[ "$(stat -c %a "$archive")" == 600 ]]

ENGINEERING_STATE_ROOT="$state" bash "$SCRIPT" verify "$archive" > "$tmp/verify.out"
grep -q '^ENGINEERING_STATE_RESTORE_TEST=PASS ' "$tmp/verify.out"
grep -q '^ENGINEERING_STATE_RESTORE_PROBE=PASS .* bytes=9$' "$tmp/verify.out"
[[ "$(sha256sum "$state/offline/state" | awk '{print $1}')" == "$before" ]]

# Backups must not overwrite an existing destination, nor archive their own output.
if ENGINEERING_STATE_ROOT="$state" bash "$SCRIPT" backup "$archive" >/dev/null 2>&1; then
  echo "FAIL: backup unexpectedly overwrote an existing archive" >&2
  exit 1
fi
if ENGINEERING_STATE_ROOT="$state" bash "$SCRIPT" backup "$state/inside.tgz" >/dev/null 2>&1; then
  echo "FAIL: backup accepted an archive inside its source root" >&2
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

# A structurally valid but path-escaping member must not pass the restore probe.
malicious="$tmp/malicious.tgz"
python3 - "$malicious" "${state#/}" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as t:
    root = tarfile.TarInfo(sys.argv[2])
    root.type = tarfile.DIRTYPE
    t.addfile(root)
    payload = b"malicious"
    entry = tarfile.TarInfo(sys.argv[2] + "/../../escaped")
    entry.size = len(payload)
    t.addfile(entry, io.BytesIO(payload))
PY
if ENGINEERING_STATE_ROOT="$state" bash "$SCRIPT" verify "$malicious" > "$tmp/evil.out" 2>&1; then
  echo "FAIL: verify accepted an archive path traversal" >&2
  exit 1
fi
[[ ! -e "$tmp/escaped" ]]

# A corrupted archive cannot claim an archive-integrity or restore PASS.
head -c 10 "$archive" > "$tmp/truncated.tgz"
if ENGINEERING_STATE_ROOT="$state" bash "$SCRIPT" verify "$tmp/truncated.tgz" >/dev/null 2>&1; then
  echo "FAIL: verify accepted a truncated archive" >&2
  exit 1
fi

# The root-owned backup must never reopen a predictable ${archive}.tmp.$$ path.
# These are literal source-code strings, not shell variables to expand here.
# shellcheck disable=SC2016
if ! grep -Fq 'mktemp "$archive.tmp.XXXXXXXX"' "$SCRIPT"; then
  echo "FAIL: secure mktemp staging is absent" >&2
  exit 1
fi
# shellcheck disable=SC2016
if grep -Fq 'tmp="${archive}.tmp.$$"' "$SCRIPT"; then
  echo "FAIL: predictable staging filename returned" >&2
  exit 1
fi
echo "ENGINEERING_STATE_BACKUP_TEST=PASS"
