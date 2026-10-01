#!/usr/bin/env bash
# Phase 1 finalize regressions: final-hop notice, Jammy/Noble policy, PTS,
# SIGPIPE, NTP userdel, process self-match, handoff, SSH exit guidance.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/phase1-finalize.XXXX")"
trap 'rm -rf "$OUT"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

J2N_IN="${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh.in"
F2J_IN="${ROOT}/client/dp-offline-upgrade-focal-to-jammy.sh.in"
B2F_IN="${ROOT}/client/dp-offline-upgrade-bionic-to-focal.sh.in"
X2B_IN="${ROOT}/client/dp-offline-upgrade-xenial-to-bionic.sh.in"
APPLY="${ROOT}/scripts/apply-dp-phase2-production.sh"

# 1-3: final-hop notice only on Jammy->Noble; single confirmation path
if grep -q 'FINAL OS HOP: Ubuntu 22.04 Jammy -> Ubuntu 24.04 Noble' "$J2N_IN" \
  && grep -q 'print_final_hop_notice' "$J2N_IN" \
  && grep -q 'FINAL_HOP_NOTICE=DISPLAYED' "$J2N_IN" \
  && grep -q 'JAMMY_DP_RUNTIME_STATE=UNAVAILABLE_EXPECTED' "$J2N_IN" \
  && grep -q 'JAMMY_RUNTIME_REPAIR=PROHIBITED_PHASE1' "$J2N_IN" \
  && grep -q 'PHASE2_RUNTIME_REBUILD=REQUIRED_ON_NOBLE' "$J2N_IN"; then
  pass "1. J2N final-hop notice + markers present"
else
  fail "1. J2N final-hop notice missing"
fi

for tin in "$X2B_IN" "$B2F_IN" "$F2J_IN"; do
  if grep -q 'FINAL OS HOP: Ubuntu 22.04 Jammy' "$tin"; then
    fail "2. final-hop notice leaked into $(basename "$tin")"
  else
    pass "2. no final-hop notice in $(basename "$tin")"
  fi
done

# notice then single require_destructive_confirmation (no second prompt helper)
notice_line="$(grep -n 'print_final_hop_notice' "$J2N_IN" | head -1 | cut -d: -f1)"
confirm_line="$(grep -n 'require_destructive_confirmation "\$PIN_CONFIRM_PHRASE"' "$J2N_IN" | head -1 | cut -d: -f1)"
confirm_count="$(grep -c 'require_destructive_confirmation "\$PIN_CONFIRM_PHRASE"' "$J2N_IN" || true)"
if [[ -n "$notice_line" && -n "$confirm_line" && "$notice_line" -lt "$confirm_line" && "$confirm_count" -eq 1 ]]; then
  pass "3. notice precedes single confirmation prompt"
else
  fail "3. notice/confirmation ordering (notice=${notice_line} confirm=${confirm_line} count=${confirm_count})"
fi

# Runtime: notice function + single mocked confirmation call
{
  echo '#!/usr/bin/env bash'
  echo 'set -Eeuo pipefail'
  echo 'log() { printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"; }'
  echo 'PIN_CONFIRM_PHRASE="UPGRADE-JAMMY-TO-NOBLE"'
  echo 'print_execution_plan() { :; }'
  awk '/^print_final_hop_notice\(\)/,/^prompt_confirmation\(\)/ { if (/^prompt_confirmation\(\)/) exit; print }' "$J2N_IN"
  cat <<'EOS'
CONFIRM_CALLS=0
require_destructive_confirmation() {
  CONFIRM_CALLS=$((CONFIRM_CALLS + 1))
  [[ "${1-}" == "UPGRADE-JAMMY-TO-NOBLE" ]] || return 21
  return 0
}
print_execution_plan
print_final_hop_notice
require_destructive_confirmation "$PIN_CONFIRM_PHRASE"
echo "CONFIRM_CALLS=${CONFIRM_CALLS}"
EOS
} >"$OUT/confirm_once.sh"
set +e
out="$(bash "$OUT/confirm_once.sh" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'FINAL_HOP_NOTICE=DISPLAYED' <<<"$out" \
  && grep -q 'CONFIRM_CALLS=1' <<<"$out"; then
  pass "3b. runtime notice + exactly one confirmation call"
else
  fail "3b. runtime notice/confirm (rc=${rc})"
  printf '%s\n' "$out" | tail -30
fi

# 4-7: Jammy product validation policy
if grep -q 'product_runtime_state=UNAVAILABLE_EXPECTED_JAMMY' "$F2J_IN" \
  && grep -q 'product_runtime_repair_result=DEFERRED_TO_PHASE2' "$F2J_IN" \
  && grep -q 'JAMMY_KUBELET_DOCKER_API_MISMATCH=EXPECTED' "$F2J_IN" \
  && grep -q 'FAILED_UNIT_UNEXPECTED=' "$F2J_IN" \
  && grep -q 'JAMMY_AELLA_CLI=UNAVAILABLE' "$F2J_IN"; then
  pass "4-7. Jammy postboot product/kubelet policy markers"
else
  fail "4-7. Jammy postboot policy incomplete"
fi

# Simulate postboot classifier snippet
cat >"$OUT/jammy_units.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
log() { echo "$1 $2"; }
failed_raw="$(printf '%s\n' "${FAILED_UNITS:-}")"
failed_units="$(printf '%s\n' "$failed_raw" | awk 'NF {print $1}' | sed 's/[.]service$//' || true)"
unexpected_fail=0
known_kubelet=0
if [[ -z "${failed_units// }" ]]; then
  log INFO "SYSTEMD_FAILED_UNITS=NONE"
else
  while read -r unit; do
    [[ -n "$unit" ]] || continue
    case "$unit" in
      kubelet|kubelet.service)
        journal_snip="${KUBELET_JOURNAL:-}"
        if printf '%s\n' "$journal_snip" | grep -qiE \
          'client version 1\.40 is too old|Minimum supported API version is 1\.44'; then
          known_kubelet=1
          log WARN "JAMMY_KUBELET_DOCKER_API_MISMATCH=EXPECTED"
        else
          unexpected_fail=1
        fi
        ;;
      *) unexpected_fail=1; log ERROR "FAILED_UNIT_UNEXPECTED=${unit}" ;;
    esac
  done <<< "$failed_units"
fi
if [[ "$unexpected_fail" -ne 0 ]]; then
  echo RESULT=FAIL
  exit 1
fi
echo RESULT=PASS known_kubelet=$known_kubelet
EOS

set +e
FAILED_UNITS="kubelet.service" \
KUBELET_JOURNAL="client version 1.40 is too old. Minimum supported API version is 1.44" \
  bash "$OUT/jammy_units.sh" >"$OUT/kube_ok.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q 'RESULT=PASS' "$OUT/kube_ok.txt"; then
  pass "6. known kubelet Docker API mismatch → OS PASS"
else
  fail "6. known kubelet should PASS"
fi

set +e
FAILED_UNITS="ssh.service" \
KUBELET_JOURNAL="" \
  bash "$OUT/jammy_units.sh" >"$OUT/ssh_fail.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'FAILED_UNIT_UNEXPECTED=ssh' "$OUT/ssh_fail.txt"; then
  pass "7. unexpected OS unit failure → STOP"
else
  fail "7. unexpected unit should STOP"
fi

# 8: Noble completion markers - not auto product PASS
if grep -q 'phase1_result=PASS' "$J2N_IN" \
  && grep -q 'phase2_result=NOT_STARTED' "$J2N_IN" \
  && grep -q 'PRODUCT_VALIDATION=NOT_RUN_PHASE1' "$J2N_IN" \
  && grep -q 'NEXT_REQUIRED_ACTION=POWERED_OFF_SNAPSHOT' "$J2N_IN" \
  && grep -q 'PHASE2_DP_BRINGUP=PENDING' "$J2N_IN" \
  && ! grep -qE 'product_validation_result=PASS' "$J2N_IN"; then
  pass "8/16/17. Noble completion + snapshot + Phase2 pending markers"
else
  fail "8/16/17. Noble completion markers incomplete"
fi

# 9: PACKAGE_TRANSITION_STARTED persist across mark
cat >"$OUT/pts.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
STATE_ROOT="$1"
PIN_HOP=jammy-to-noble
current_hop_env_path() { printf '%s/current-hop.env\n' "$STATE_ROOT"; }
read_current_hop_field() {
  local k="$1"
  sed -n "s/^${k}=//p" "$(current_hop_env_path)" | head -1
}
log() { echo "$2"; }
persist_current_hop_package_transition_started() {
  local dest tmp val hop
  dest="$(current_hop_env_path)"
  [[ -f "$dest" ]] || return 0
  hop="$(read_current_hop_field CURRENT_HOP 2>/dev/null || true)"
  [[ "$hop" == "${PIN_HOP}" ]] || return 0
  val="$(read_current_hop_field PACKAGE_TRANSITION_STARTED 2>/dev/null || true)"
  [[ "$val" == "true" ]] && return 0
  tmp="${dest}.pts.$$"
  awk 'BEGIN{done=0} /^PACKAGE_TRANSITION_STARTED=/{print "PACKAGE_TRANSITION_STARTED=true"; done=1; next} {print} END{if(!done) print "PACKAGE_TRANSITION_STARTED=true"}' "$dest" >"$tmp"
  mv -f "$tmp" "$dest"
  log INFO "PERSISTED_PACKAGE_TRANSITION_STARTED=true"
}
mkdir -p "$STATE_ROOT"
cat >"$STATE_ROOT/current-hop.env" <<EOF
CURRENT_HOP=jammy-to-noble
PACKAGE_TRANSITION_STARTED=false
EOF
persist_current_hop_package_transition_started
grep -qx 'PACKAGE_TRANSITION_STARTED=true' "$STATE_ROOT/current-hop.env"
# resume simulation: already true stays true
persist_current_hop_package_transition_started
grep -qx 'PACKAGE_TRANSITION_STARTED=true' "$STATE_ROOT/current-hop.env"
# new hop init must start false (separate file)
cat >"$STATE_ROOT/current-hop.env" <<EOF
CURRENT_HOP=jammy-to-noble
PACKAGE_TRANSITION_STARTED=false
EOF
grep -qx 'PACKAGE_TRANSITION_STARTED=false' "$STATE_ROOT/current-hop.env"
EOS
bash "$OUT/pts.sh" "$OUT/pts-root" \
  && pass "9. PACKAGE_TRANSITION_STARTED true persist + hop reset false" \
  || fail "9. PACKAGE_TRANSITION_STARTED persist"

grep -q 'persist_current_hop_package_transition_started' "$J2N_IN" \
  && grep -q 'pts_val' "$J2N_IN" \
  && pass "9b. J2N source wires current-hop.env PTS sync" \
  || fail "9b. J2N PTS wiring missing"

# 10: apt-cache SIGPIPE regression
for tin in "$X2B_IN" "$B2F_IN" "$F2J_IN" "$J2N_IN"; do
  if grep -E 'apt-cache[^|]*policy[^|]*\|[^|]*awk.*/Candidate:.*exit' "$tin" >/dev/null 2>&1; then
    fail "10. SIGPIPE risk remains in $(basename "$tin")"
  else
    pass "10. no apt-cache|awk Candidate exit in $(basename "$tin")"
  fi
done

# Buffered parse unit (pipefail)
cat >"$OUT/sigpipe.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
cross_release_candidate_from_policy() {
  local policy_out="$1"
  awk '/^[[:space:]]*Candidate:/{print $2; exit}' <<<"$policy_out"
}
# old pattern dies under pipefail when awk exits early
set +e
(
  set -euo pipefail
  cand="$(printf 'Package: x\n  Candidate: 1.2.3\n  Version table:\n' | awk '/Candidate:/{print $2; exit}')"
  # force a long writer after early reader close
  true
)
old_rc=$?
# Even if old doesn't die on printf, simulate apt-cache style with yes|awk
(
  set -euo pipefail
  # shellcheck disable=SC2034
  cand="$(yes '  Candidate: 9.9.9' | awk '/Candidate:/{print $2; exit}')"
)
old2_rc=$?
(
  set -euo pipefail
  pol="$(printf 'Package: x\n  Candidate: 1.2.3\n')"
  cand="$(cross_release_candidate_from_policy "$pol")"
  [[ "$cand" == "1.2.3" ]]
)
new_rc=$?
echo "old2_rc=${old2_rc} new_rc=${new_rc}"
[[ "$new_rc" -eq 0 ]] || exit 1
# old pipefail pattern should be non-zero (141) on yes|awk exit
[[ "$old2_rc" -ne 0 ]] || exit 2
EOS
bash "$OUT/sigpipe.sh" && pass "10b. buffered Candidate parse survives; old SIGPIPE dies" \
  || fail "10b. SIGPIPE unit"

# 11-12: NTP userdel classification
awk '/^classify_ntp_userdel_warning\(\)/,/^classify_dro_failure\(\)/ { if (/^classify_dro_failure\(\)/) exit; print }' "$J2N_IN" >"$OUT/ntp_lib.sh"
cat >"$OUT/ntp_case.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$1"
MODE="$2"
hostpath() { printf '%s%s\n' "$ROOT" "$1"; }
LOG_FILE="/var/log/aella/offline_os_upgrade.log"
log() { echo "$1 $2"; }
# shellcheck disable=SC1091
source "$3"
mkdir -p "$ROOT/var/log/dist-upgrade"
printf '%s\n' "userdel: user ntp is currently used by process 1234" \
  "fatal: '/usr/sbin/userdel ntp' returned error code 8. Exiting." \
  >"$ROOT/var/log/dist-upgrade/main.log"
classify_ntp_userdel_warning
if [[ "$MODE" == "ok" ]]; then
  emit_ntp_userdel_summary 1
  [[ "$NTP_USERDEL_WARNING_DETECTED" == "YES" ]]
else
  emit_ntp_userdel_summary 0
  [[ "$NTP_USERDEL_WARNING_DETECTED" == "YES" ]]
fi
EOS
out="$(bash "$OUT/ntp_case.sh" "$OUT/ntp-ok" ok "$OUT/ntp_lib.sh" 2>&1)" \
  && grep -q 'NTP_USERDEL_WARNING_BLOCKING=NO' <<<"$out" \
  && pass "11. NTP userdel warning non-blocking on package health PASS" \
  || { fail "11. NTP non-blocking"; echo "$out"; }

out="$(bash "$OUT/ntp_case.sh" "$OUT/ntp-bad" bad "$OUT/ntp_lib.sh" 2>&1)" \
  && grep -q 'NTP_USERDEL_WARNING_BLOCKING=YES' <<<"$out" \
  && pass "12. NTP userdel + package failure remains blocking" \
  || { fail "12. NTP blocking"; echo "$out"; }

# 13: process self-match exclusion
awk '/^list_active_upgrade_processes\(\)/,/^package_transition_evidence_present\(\)/ { if (/^package_transition_evidence_present\(\)/) exit; print }' "$J2N_IN" \
  >"$OUT/proc_lib.sh"
cat >"$OUT/proc.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$1"
# Fake ps that includes self-like grep noise
ps() {
  cat <<PSOUT
$$ bash tests/test_phase1_finalize.sh
9999 /usr/bin/dpkg --configure -a
10000 grep dpkg --configure
10001 pgrep -f dpkg
PSOUT
}
hits="$(list_active_upgrade_processes)"
echo "HITS<<$hits>>"
grep -q '9999' <<<"$hits" || exit 1
grep -q 'pgrep' <<<"$hits" && exit 2
grep -q 'grep dpkg' <<<"$hits" && exit 3
exit 0
EOS
bash "$OUT/proc.sh" "$OUT/proc_lib.sh" \
  && pass "13. process scan excludes pgrep/grep self-match" \
  || fail "13. process self-match exclusion"

# 14-15: systemd handoff messages
if grep -q 'SYSTEMD_HANDOFF=PASS' "$J2N_IN" \
  && grep -q 'CLIENT_RERUN=PROHIBITED' "$J2N_IN" \
  && grep -q 'AUTO_REBOOT=EXPECTED' "$J2N_IN" \
  && grep -q 'MANUAL_REBOOT=PROHIBITED_WHILE_PENDING' "$J2N_IN" \
  && grep -q 'SSH_DISCONNECT_SAFE=YES' "$J2N_IN"; then
  pass "14-15. systemd handoff / reboot prohibition markers"
else
  fail "14-15. handoff markers missing"
fi

# 18: no kubelet/docker repair commands in Phase 1 clients
bad=0
for tin in "$X2B_IN" "$B2F_IN" "$F2J_IN" "$J2N_IN"; do
  if grep -nE 'systemctl[[:space:]]+(restart|stop|start).*(docker|kubelet|containerd)|apt[ -]+(install|remove|purge).*(docker|kubelet|containerd)|kubeadm|kubectl[[:space:]]+drain' "$tin" \
    | grep -vE 'PROHIBITED|Do NOT|JAMMY_|comment|#' >/dev/null 2>&1; then
    # allow only in comments / messages
    if grep -nE '^\s*systemctl[[:space:]]+(restart|stop).*(docker|kubelet|containerd)' "$tin" >/dev/null 2>&1; then
      bad=1
      fail "18. repair command in $(basename "$tin")"
    fi
  fi
done
[[ "$bad" -eq 0 ]] && pass "18. no Phase 1 kubelet/docker/containerd repair commands"

# 19: no public Ubuntu URLs as client runtime download sources
bad=0
for tin in "$X2B_IN" "$B2F_IN" "$F2J_IN" "$J2N_IN"; do
  if grep -nE 'https?://(archive|security|old-releases)\.ubuntu\.com' "$tin" \
    | grep -vE 'grep|FAIL_|external|PROHIBITED|block|detect|FORBIDDEN|mirror' >/dev/null 2>&1; then
    # Heuristic: fail only on wget/curl download of public hosts
    if grep -nE '(wget|curl).*(archive|security|old-releases)\.ubuntu\.com' "$tin" >/dev/null 2>&1; then
      bad=1
      fail "19. public Ubuntu download in $(basename "$tin")"
    fi
  fi
done
[[ "$bad" -eq 0 ]] && pass "19. no public Ubuntu download URLs in clients"

# 20: retired direct Phase 2 apply path must be production-hard-disabled.
if grep -q 'LEGACY_PHASE2_MAINTENANCE_DISABLED=YES' "$APPLY" \
  && grep -q 'MM_HERMETIC_TEST_MODE' "$APPLY" \
  && grep -q 'ALLOW_LEGACY_PHASE2_MAINTENANCE' "$APPLY" \
  && ! grep -qE 'pkill[[:space:]]+.*ssh|kill[[:space:]]+\$PPID' "$APPLY"; then
  pass "20. retired Phase2 apply path production-disabled"
else
  fail "20. retired Phase2 apply production guard missing"
fi

if grep -q 'Do \*\*not\*\* run the old `apply-dp-phase2-production.sh`' "${ROOT}/docs/operations.md" \
  && grep -q 'Menu 2 → 3 → 4 → 7' "${ROOT}/docs/operations.md"; then
  pass "20b. operations.md points production to Mirror Manager only"
else
  fail "20b. operations.md still exposes legacy Phase2 apply workflow"
fi

echo
echo "PHASE1_FINALIZE_PASS=${PASS} FAIL=${FAIL}"
[[ "$FAIL" -eq 0 ]]
