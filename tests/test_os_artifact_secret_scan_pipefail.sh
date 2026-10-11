#!/usr/bin/env bash
# Hermetic RED/GREEN: Phase 1 evidence export must refuse all secret-like files
# even when many matches make find | grep -q SIGPIPE under pipefail.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/dp-os-upgrade-artifacts.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
OSU_STATE_DIR="$tmp/state"
export OSU_STATE_DIR
ST_HOSTNAME="fixture"
osu_utc_stamp() { printf '20261011T001800Z'; }
osu_log() { :; }
osu_state_path() { printf '%s/state.json' "$OSU_STATE_DIR"; }
source_dir="$OSU_STATE_DIR/hops/hop-01-xenial-to-bionic"
mkdir -p "$source_dir" "$tmp/export"
# Dummy empty files only: no credentials and no live DP paths.
for n in $(seq -w 1 650); do : >"$source_dir/test-password-$n"; done
for ((i=0; i<12; i++)); do
  if osu_export_artifacts 1 "$tmp/export" 0 >/dev/null 2>&1; then
    echo "FAIL: exporter allowed a secret-like file under pipefail (iteration $i)" >&2
    exit 1
  fi
  compgen -G "$tmp/export/*.tar.gz" >/dev/null &&
    { echo "FAIL: exported archive despite secret-like names" >&2; exit 1; }
done
printf 'PASS: all 12 secret-like file scans reject export\n'
# Control: a clean non-secret directory remains exportable in a local fixture.
rm -f "$source_dir"/test-password-*
printf 'fixture evidence\n' >"$source_dir/public-events.txt"
out="$(osu_export_artifacts 1 "$tmp/export" 0)"
[[ -f "$out" ]] || { echo "FAIL: clean fixture could not export" >&2; exit 1; }
printf 'PASS: clean fixture remains exportable\n'
