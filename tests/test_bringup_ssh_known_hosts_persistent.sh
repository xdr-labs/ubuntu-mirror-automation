#!/usr/bin/env bash
# Worker SSH known_hosts: persistent project state, exact modes, no /tmp downgrade.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAG="${ROOT}/scripts/lib/phase2_bringup_patch/fragment_credential_ssh.sh"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Source fragment with a local die() for harness use.
die() { echo "DIE: $*" >&2; exit 2; }
# shellcheck source=/dev/null
source "$FRAG"

# --- Static: known_hosts init must not fall back to /tmp ---
if awk '
  /^init_phase2_ssh_known_hosts\(\)/ {infn=1; next}
  infn && /^}/ {exit(bad ? 1 : 0)}
  infn && /\/tmp\/dp-phase2-bringup|TMPDIR/ {bad=1}
  END {if (!infn) exit 1}
' "$FRAG"; then
  pass "init_phase2_ssh_known_hosts has no /tmp fallback"
else
  fail "init_phase2_ssh_known_hosts still references /tmp"
fi

grep -q 'StrictHostKeyChecking=accept-new' "$FRAG" \
  && pass "accept-new policy present" || fail "accept-new missing"
grep -q 'UserKnownHostsFile=${PHASE2_SSH_KNOWN_HOSTS_FILE}' "$FRAG" \
  && pass "UserKnownHostsFile uses project known_hosts" || fail "UserKnownHostsFile missing"

# --- Persistent path success + exact modes ---
STATE="$TMP/var-lib-dp-phase2-bringup"
export PHASE2_SSH_STATE_DIR="$STATE"
unset PHASE2_SSH_KNOWN_HOSTS_FILE || true
init_phase2_ssh_known_hosts
[[ "$PHASE2_SSH_STATE_DIR" == "$STATE" ]] \
  && pass "persistent state dir retained" || fail "state dir changed to ${PHASE2_SSH_STATE_DIR}"
[[ "$PHASE2_SSH_KNOWN_HOSTS_FILE" == "${STATE}/known_hosts" ]] \
  && pass "known_hosts under persistent dir" || fail "known_hosts path=${PHASE2_SSH_KNOWN_HOSTS_FILE}"
dmode="$(stat -c '%a' "$STATE")"
fmode="$(stat -c '%a' "$PHASE2_SSH_KNOWN_HOSTS_FILE")"
[[ "$dmode" == "700" || "$dmode" == "0700" ]] && pass "state dir mode 0700" || fail "dir mode=${dmode}"
[[ "$fmode" == "600" || "$fmode" == "0600" ]] && pass "known_hosts mode 0600" || fail "file mode=${fmode}"
[[ "$SSH_OPTS" == "$SCP_OPTS" ]] && pass "SSH and SCP share same opts" || fail "SSH/SCP opts differ"
printf '%s\n' "$SSH_OPTS" | grep -q "UserKnownHostsFile=${PHASE2_SSH_KNOWN_HOSTS_FILE}" \
  && pass "SSH opts pin known_hosts path" || fail "SSH opts missing known_hosts"
printf '%s\n' "$SCP_OPTS" | grep -q "UserKnownHostsFile=${PHASE2_SSH_KNOWN_HOSTS_FILE}" \
  && pass "SCP opts pin same known_hosts path" || fail "SCP opts missing known_hosts"
printf '%s\n' "$SSH_OPTS" | grep -q 'StrictHostKeyChecking=accept-new' \
  && pass "changed-key policy is accept-new (rejects changed keys)" \
  || fail "accept-new missing from runtime opts"
case "$PHASE2_SSH_KNOWN_HOSTS_FILE" in
  */dp-phase2-bringup-*/known_hosts|/tmp/dp-phase2-bringup-*/known_hosts)
    fail "production known_hosts used process-local /tmp path"
    ;;
  *)
    pass "no production process-local /tmp known_hosts"
    ;;
esac

# --- Persistent state creation failure → fail closed ---
BLOCK="$TMP/unwritable"
mkdir -p "$BLOCK"
chmod 000 "$BLOCK"
export PHASE2_SSH_STATE_DIR="${BLOCK}/nested-state"
unset PHASE2_SSH_KNOWN_HOSTS_FILE || true
set +e
out="$(init_phase2_ssh_known_hosts 2>&1)"
rc=$?
set -e
chmod 700 "$BLOCK"
[[ "$rc" -ne 0 ]] && pass "unwritable state dir fails closed" || fail "unwritable state dir unexpectedly succeeded"
printf '%s\n' "$out" | grep -q 'SSH_KNOWN_HOSTS=FAIL' \
  && pass "failure emits SSH_KNOWN_HOSTS=FAIL" || fail "missing SSH_KNOWN_HOSTS=FAIL"
printf '%s\n' "$out" | grep -q '/tmp/dp-phase2-bringup' \
  && fail "failure still fell back to /tmp" || pass "failure did not fall back to /tmp"

# --- Generated/vendor bringup inherits persistent policy ---
BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
if [[ -f "$BRINGUP" ]]; then
  grep -q 'init_phase2_ssh_known_hosts' "$BRINGUP" \
    && pass "vendor bringup has known_hosts init" || fail "vendor missing known_hosts init"
  if awk '
    /^init_phase2_ssh_known_hosts\(\)/ {infn=1; next}
    infn && /^}/ {exit 0}
    infn && /\/tmp\/dp-phase2-bringup/ {bad=1}
    END {exit(bad?1:0)}
  ' "$BRINGUP"; then
    pass "vendor known_hosts init has no /tmp downgrade"
  else
    fail "vendor known_hosts init still has /tmp downgrade"
  fi
fi

echo "SUMMARY fail=${FAIL}"
exit "$FAIL"
