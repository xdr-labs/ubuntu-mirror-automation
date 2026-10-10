#!/usr/bin/env bash
# Hermetic internal-JSON fallback test: large collector summaries must not
# lose schema_version at the beginning due to SIGPIPE under pipefail.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/dp-preflight-common.sh"
fx="$(mktemp)"
trap 'rm -f "$fx"' EXIT
python3 - "$fx" <<'PY'
import json
import sys
with open(sys.argv[1], 'w') as f:
    json.dump({"schema_version": "1.0", "hostname": "dp-fixture", "padding": "x" * 320000}, f, indent=2)
PY
set +e
out="$(pf_json_get_internal "$fx" schema_version)"
rc=$?
set -e
if [[ "$rc" -ne 0 || "$out" != "1.0" ]]; then
    echo "FAIL: internal parser lost schema_version with large valid JSON (rc=$rc out=$out)" >&2
    exit 1
fi
echo "PASS: internal parser preserves schema_version for 320KB valid collector JSON"
