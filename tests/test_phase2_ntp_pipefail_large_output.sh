#!/usr/bin/env bash
# Hermetic regression: long native NTP responses must not lose an early positive signal
# when grep -q closes before printf writes the whole payload under pipefail.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../client/lib/dp-phase2-time-readiness.sh
source "$ROOT/client/lib/dp-phase2-time-readiness.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
padding="$(python3 - <<'PY'
print('irrelevant NTP status fields ' * 12000)
PY
)"
DP_PHASE2_FAKE_NTPQ_RV=$'leap=00, stratum=2\n'"$padding"
dp_phase2_ntpq_leap_ok || fail "healthy leap=00 disappeared in long ntpq -c rv status"
pass "long ntpq rv preserves early leap=00"
DP_PHASE2_FAKE_TIMEDATECTL=$'System clock synchronized: yes\n'"$padding"
dp_phase2_timedatectl_synchronized || fail "healthy timedatectl synchronized=yes disappeared in long status"
pass "long timedatectl status preserves early synchronized=yes"
DP_PHASE2_FAKE_NTPQ_RV=$'leap=11, stratum=2\n'"$padding"
if dp_phase2_ntpq_leap_ok; then fail "unsynchronized leap=11 accepted"; fi
pass "leap=11 fail-closed"
DP_PHASE2_FAKE_TIMEDATECTL=$'System clock synchronized: no\n'"$padding"
if dp_phase2_timedatectl_synchronized; then fail "unsynchronized timedatectl accepted"; fi
pass "synchronized=no fail-closed"
