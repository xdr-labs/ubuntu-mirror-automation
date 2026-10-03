#!/usr/bin/env bash
# Supplemental Engineering System backup contract for durable OS-upgrade state.
# Hypervisor snapshots remain the primary rollback mechanism.
set -euo pipefail
umask 077

usage() {
  echo "Usage: $0 backup|verify ARCHIVE" >&2
  exit 2
}

mode="${1:-}"
archive="${2:-}"
[[ "$mode" == "backup" || "$mode" == "verify" ]] || usage
[[ "$archive" == /* ]] || { echo "ERROR: archive path must be absolute" >&2; exit 2; }

state_root="${ENGINEERING_STATE_ROOT:-/opt/aelladata/os-upgrade}"
[[ "$state_root" == /* ]] || { echo "ERROR: state root must be absolute" >&2; exit 2; }
state_rel="${state_root#/}"
[[ -n "$state_rel" ]] || { echo "ERROR: refusing filesystem-root backup" >&2; exit 2; }

if [[ "$mode" == "backup" ]]; then
  [[ -d "$state_root" ]] || { echo "ERROR: durable state root missing: $state_root" >&2; exit 3; }
  [[ ! -e "$archive" && ! -L "$archive" ]] || { echo "ERROR: archive already exists" >&2; exit 3; }
  parent="$(dirname "$archive")"
  [[ -d "$parent" ]] || { echo "ERROR: archive parent missing: $parent" >&2; exit 3; }
  tmp="${archive}.tmp.$$"
  trap 'rm -f "$tmp"' EXIT
  tar --one-file-system --numeric-owner -czf "$tmp" -C / "$state_rel"
  tar -tzf "$tmp" >/dev/null
  mv "$tmp" "$archive"
  trap - EXIT
  echo "ENGINEERING_STATE_BACKUP=PASS archive=$archive state_root=$state_root"
  exit 0
fi

[[ -f "$archive" && ! -L "$archive" ]] || { echo "ERROR: backup archive missing or unsafe" >&2; exit 3; }
tar -tzf "$archive" >/dev/null
found=0
while IFS= read -r entry; do
  if [[ "$entry" == "$state_rel" || "$entry" == "$state_rel/"* ]]; then
    found=1
    break
  fi
done < <(tar -tzf "$archive")
[[ "$found" -eq 1 ]] || { echo "ERROR: archive does not contain expected durable state root" >&2; exit 3; }
echo "ENGINEERING_STATE_RESTORE_TEST=PASS archive=$archive state_root=$state_root"
