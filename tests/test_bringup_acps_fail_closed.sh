#!/usr/bin/env bash
# Patched production bringup must not embed ACPS credentials or allow direct download.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
PATCHER="${ROOT}/scripts/lib/patch_dp_phase2_bringup.py"
F1A73="${ROOT}/tests/fixtures/dp-phase2/production-f1a73/bringup_py3_dp_after_os_upgrade.sh"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

echo "=== test_bringup_acps_fail_closed ==="
[[ -f "$BRINGUP" ]] || { echo "missing bringup: $BRINGUP" >&2; exit 1; }

grep -qE "ACPS_PASS='[^']+'" "$BRINGUP" \
  && fail "static ACPS_PASS literal still present" \
  || pass "no static ACPS_PASS literal"

grep -qE 'ACPS_PASSWORD=' "$BRINGUP" \
  && fail "ACPS_PASSWORD assignment present" \
  || pass "no ACPS_PASSWORD assignment"

grep -q 'ACPS_DIRECT_DOWNLOAD=FAIL' "$BRINGUP" \
  || fail "ACPS_DIRECT_DOWNLOAD=FAIL marker missing"
pass "ACPS direct download fail-closed marker present"

grep -q 'phase2_acps_direct_download_fail_closed' "$BRINGUP" \
  || fail "phase2_acps_direct_download_fail_closed helper missing"
pass "ACPS fail-closed helper present"

# Patched output must not curl with embedded ACPS_PASS for artifact download.
if grep -q 'curl.*ACPS_PASS' "$BRINGUP"; then
  fail "curl still references ACPS_PASS"
else
  pass "no curl -u with ACPS_PASS in patched bringup"
fi

# --skip-download path must remain (Mirror Manager contract).
grep -q -- '--skip-download' "$BRINGUP" \
  || fail "--skip-download support missing"
pass "--skip-download still supported"

# Patcher validates on production upstream fixture.
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
if python3 "$PATCHER" --validate --upstream "$F1A73" >"$OUT" 2>&1; then
  pass "patcher validate on f1a73 upstream"
else
  fail "patcher validate on f1a73 upstream"
  cat "$OUT"
fi
grep -q 'BRINGUP_PATCH_COMPAT=PASS' "$OUT" || fail "BRINGUP_PATCH_COMPAT=PASS missing"

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_bringup_acps_fail_closed PASS ==="
else
  echo "=== test_bringup_acps_fail_closed FAIL ==="
fi
exit "$FAIL"
