#!/usr/bin/env bash
# Hermetic Phase 1 report: real Python inventory evidence must report true
# even when many files trigger find | grep -q SIGPIPE.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/dp-os-upgrade-common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OSU_STATE_DIR="$TMP/os-upgrade"
ST_HOSTNAME='fixture-dp'
ST_SOURCE_OS='16.04'
ST_STATE='COMPLETED'
mkdir -p "$OSU_STATE_DIR/hops/hop-01/python-3.5/inventory" "$TMP/host"
for n in $(seq -w 1 4000); do : > "$OSU_STATE_DIR/hops/hop-01/python-3.5/inventory/python-package-${n}.txt"; done
osu_current_os_version() { printf '24.04'; }
osu_hostpath() { printf '%s%s' "$TMP/host" "$1"; }
osu_generate_reports >/dev/null
python3 - "$OSU_STATE_DIR/reports/phase1-summary.json" <<'PY'
import json, sys
report=json.load(open(sys.argv[1]))
assert report['python_inventory_captured'] is True, "Python inventory falsely reported missing"
print('PASS: large real Python inventory reported captured')
PY
