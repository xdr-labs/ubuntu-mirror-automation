#!/usr/bin/env bash
# Hermetic hold guard: no apt operations or real upgrade, only fake held packages.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/dp-os-upgrade-common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/tmp"
OSU_TEST_MODE=1
POLICY_CRITICAL_HELD_PACKAGES="systemd,udev,dpkg"
osu_hostpath() { printf '%s%s' "$TMP" "$1"; }
python3 - "$TMP/tmp/held-packages.txt" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text("systemd\nudev\ndpkg\n" +
                            "not_a_critical_package_name\n"*25000)
PY
result="$(osu_critical_holds_present)"
expected=$'systemd\nudev\ndpkg'
[[ "$result" == "$expected" ]] || {
 printf 'FAIL: required critical holds vanished expected=%q actual=%q\n' "$expected" "$result" >&2
 exit 1
}
echo 'PASS: large held-package list preserves all critical holds'
printf 'unrelated-only\n' > "$TMP/tmp/held-packages.txt"
[[ -z "$(osu_critical_holds_present)" ]] || {
 echo "FAIL: unrelated held package falsely critical" >&2
 exit 1
}
echo 'PASS: unrelated held packages ignored'
