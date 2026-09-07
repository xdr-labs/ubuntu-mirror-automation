#!/usr/bin/env bash
# SSH host-key policy: accept-new + persistent known_hosts; no trust-all SSH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

echo "=== test_bringup_ssh_host_keys ==="
[[ -f "$BRINGUP" ]] || { echo "missing bringup: $BRINGUP" >&2; exit 1; }

grep -q 'StrictHostKeyChecking=no' "$BRINGUP" \
  && fail "StrictHostKeyChecking=no still present" \
  || pass "no StrictHostKeyChecking=no"

grep -q 'UserKnownHostsFile=/dev/null' "$BRINGUP" \
  && fail "UserKnownHostsFile=/dev/null still present" \
  || pass "no UserKnownHostsFile=/dev/null"

grep -q 'StrictHostKeyChecking=accept-new' "$BRINGUP" \
  || fail "accept-new policy missing"
pass "StrictHostKeyChecking=accept-new present"

grep -q 'init_phase2_ssh_known_hosts' "$BRINGUP" \
  || fail "init_phase2_ssh_known_hosts missing"
pass "known_hosts init helper present"

grep -q '/var/lib/dp-phase2-bringup' "$BRINGUP" \
  || fail "project-owned ssh state dir missing"
pass "project-owned ssh state dir referenced"

grep -q 'sshpass -p aelladata' "$BRINGUP" \
  && fail "hardcoded overlay2/esdata sshpass -p aelladata still present" \
  || pass "no hardcoded sshpass -p aelladata"

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_bringup_ssh_host_keys PASS ==="
else
  echo "=== test_bringup_ssh_host_keys FAIL ==="
fi
exit "$FAIL"
