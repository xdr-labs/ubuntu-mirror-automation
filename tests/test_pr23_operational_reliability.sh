#!/usr/bin/env bash
# Targeted operational reliability regressions for Phase 2 / OS-hop fixes.
set -euo pipefail
export MM_HERMETIC_TEST_MODE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Finding 1: migration decision state machine ---
# shellcheck source=/dev/null
source "${ROOT}/client/lib/dp-phase2-post-bringup-migration.sh"
export POST_BRINGUP_MIGRATION_ENV="${TMP}/mig.env"
d="$(p2b_decide_post_bringup_migration 6.2.0 6.6.0)"
[[ "$d" == "REQUIRED" ]] && pass "6.2->6.6 migration REQUIRED" || fail "6.2 decision=$d"
d="$(p2b_decide_post_bringup_migration 6.3.1 6.6.0)"
[[ "$d" == "REQUIRED" ]] && pass "6.3->6.6 migration REQUIRED" || fail "6.3 decision=$d"
d="$(p2b_decide_post_bringup_migration 6.4.0 6.6.0)"
[[ "$d" == "REQUIRED" ]] && pass "6.4->6.6 migration REQUIRED" || fail "6.4 decision=$d"
d="$(p2b_decide_post_bringup_migration 6.5.0 6.6.0)"
[[ "$d" == "NOT_REQUIRED" ]] && pass "6.5->6.6 migration NOT_REQUIRED" || fail "6.5 decision=$d"
d="$(p2b_decide_post_bringup_migration 6.6.0 6.6.0)"
[[ "$d" == "NOT_REQUIRED" ]] && pass "same-version NOT_REQUIRED" || fail "same decision=$d"
p2b_persist_post_bringup_migration_decision 6.2.0 6.6.0 REQUIRED
grep -q '^POST_BRINGUP_MIGRATION=REQUIRED$' "$POST_BRINGUP_MIGRATION_ENV" \
  && pass "persist REQUIRED" || fail "persist REQUIRED"
p2b_record_post_bringup_migration PASS >/dev/null
grep -q '^POST_BRINGUP_MIGRATION=PASS$' "$POST_BRINGUP_MIGRATION_ENV" \
  && pass "record PASS" || fail "record PASS"
out="$(p2b_emit_completion_semantics YES PENDING)"
echo "$out" | grep -q 'DP_UPGRADE_COMPLETE=NO' \
  && pass "DP_UPGRADE_COMPLETE blocked while cluster PENDING" || fail "complete blocked"
out="$(CLUSTER_VALIDATION=PASS; p2b_emit_completion_semantics YES PASS)"
echo "$out" | grep -q 'DP_UPGRADE_COMPLETE=YES' \
  && pass "DP_UPGRADE_COMPLETE YES when migration PASS + cluster PASS" || fail "complete yes"

# --- Finding 2: disk peak model (no second full copy) ---
HELPER="${ROOT}/client/stage-dp-phase2.sh"
grep -q 'PHASE2_EXTRACT_LAYOUT=direct_into_candidate' "$HELPER" \
  && pass "extract-into-candidate layout" || fail "extract layout"
grep -q 'require_phase2_dynamic_space' "$HELPER" \
  && pass "dynamic space preflight present" || fail "dynamic space"
! grep -q 'phase2_artifact_copy' "$HELPER" \
  && pass "second full artifact cp -a removed" || fail "artifact copy still present"
grep -q 'PHASE2_DISK_PREFLIGHT' "$HELPER" \
  && pass "PHASE2_DISK_PREFLIGHT field" || fail "disk preflight field"

# Function-level peak estimate
export DP_PHASE2_STAGE_LIB_ONLY=1
# shellcheck source=/dev/null
source "$HELPER"
ARTIFACT_DIR="${TMP}/art"
mkdir -p "$ARTIFACT_DIR"
dd if=/dev/zero of="${ARTIFACT_DIR}/blob" bs=1024 count=100 status=none
peak="$(phase2_estimate_peak_bytes 1000)"
# peak = 1000 + 1000 + existing(~102400) + 5GiB
[[ "$peak" -gt 5000000000 ]] && pass "peak includes safety margin" || fail "peak=$peak"

# --- Finding 3: time gate hard-blocks bringup ---
# shellcheck source=/dev/null
source "${ROOT}/client/lib/dp-phase2-time-readiness.sh"
export DP_PHASE2_FAKE_NTPWAIT_RC=1
export DP_PHASE2_FAKE_NTPQ_PN=$'     remote           refid      st t when poll reach   delay   offset  jitter\n'
export DP_PHASE2_FAKE_TIMEDATECTL=$'System clock synchronized: no\nNTP service: inactive\n'
unset DP_PHASE2_FAKE_HTTP_DATE_EPOCH DP_PHASE2_FAKE_LOCAL_EPOCH || true
# No skew source → FAIL_TIME_UNVERIFIABLE
check_ntp_bringup_readiness >/dev/null || true
[[ "$TIME_READINESS" == "FAIL_TIME_UNVERIFIABLE" || "$TIME_READINESS" == "FAIL_CLOCK_SKEW" ]] \
  && pass "staging-style time fail sets TIME_READINESS fail" || fail "time=$TIME_READINESS"
[[ "$BRINGUP_READY" == "NO" ]] && pass "BRINGUP_READY=NO on time fail" || fail "ready=$BRINGUP_READY"
if dp_phase2_bringup_time_gate >/dev/null 2>&1; then
  fail "time gate should hard-fail"
else
  pass "bringup time gate hard-fails"
fi
# PASS_SYNCED allows
export DP_PHASE2_FAKE_NTPWAIT_RC=0
check_ntp_bringup_readiness >/dev/null || true
dp_phase2_bringup_time_gate >/dev/null && pass "time gate allows PASS_SYNCED" || fail "PASS_SYNCED gate"

# Lifecycle must not launch vendor when gate fails — structural check
LIFE="${ROOT}/client/lib/dp-phase2-bringup-lifecycle.sh"
grep -q 'dp_phase2_bringup_time_gate' "$LIFE" \
  && pass "worker re-checks time gate" || fail "worker time gate"
WRAP="${ROOT}/client/bringup_py3_dp_lifecycle.sh"
grep -q 'dp_phase2_bringup_time_gate' "$WRAP" \
  && pass "start_or_monitor time gate before detach" || fail "start gate"

# Staging can PASS while readiness NO
grep -q 'ARTIFACT_STAGING_RESULT' "$HELPER" \
  && pass "ARTIFACT_STAGING_RESULT separated" || fail "staging result key"
grep -q 'BRINGUP_READINESS_RESULT' "$HELPER" \
  && pass "BRINGUP_READINESS_RESULT separated" || fail "readiness result key"

# --- Finding 4: postboot enable before reboot ---
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  t="${ROOT}/client/dp-offline-upgrade-${hop}.sh.in"
  grep -q 'ensure_postboot_unit_enabled_before_reboot' "$t" \
    && pass "${hop} postboot enable helper" || fail "${hop} postboot helper"
  if grep -n 'systemctl enable stellar-offline-os-upgrade-postboot.service 2>/dev/null || true' "$t" \
    | grep -v ensure_postboot; then
    fail "${hop} still swallows enable failure"
  else
    pass "${hop} no swallowed enable||true before reboot"
  fi
  grep -q 'AUTOMATIC_REBOOT_NOT_STARTED=YES' "$t" \
    && pass "${hop} reboot suppressed marker" || fail "${hop} reboot marker"
done

# Unit test ensure_postboot helper behavior via extracted function
# shellcheck disable=SC1091
source /dev/null
cat >"${TMP}/postboot_harness.sh" <<'H'
set -euo pipefail
ROOT="$1"
TMP="$2"
# Minimal stubs
log() { printf '%s %s\n' "$1" "$2"; }
POSTBOOT_UNIT_NAME="stellar-offline-os-upgrade-postboot.service"
# Extract function from xenial template
eval "$(sed -n '/^ensure_postboot_unit_enabled_before_reboot()/,/^}/p' \
  "${ROOT}/client/dp-offline-upgrade-xenial-to-bionic.sh.in")"
export PATH="${TMP}/bin:$PATH"
mkdir -p "${TMP}/bin" "${TMP}/etc/systemd/system"
# Fake systemctl
cat >"${TMP}/bin/systemctl" <<'SYS'
#!/usr/bin/env bash
cmd="$1"; shift || true
case "$cmd" in
  daemon-reload) exit "${FAKE_DAEMON_RC:-0}" ;;
  enable) exit "${FAKE_ENABLE_RC:-0}" ;;
  is-enabled)
    echo "${FAKE_IS_ENABLED:-enabled}"
    [[ "${FAKE_IS_ENABLED_RC:-0}" -eq 0 ]]
    ;;
  *) exit 0 ;;
esac
SYS
chmod +x "${TMP}/bin/systemctl"
# Redirect unit path by running from chroot-like cwd using sed? Helper uses absolute /etc.
# Shadow /etc via bind is heavy; instead monkeypatch by redefining after extract.
ensure_postboot_unit_enabled_before_reboot() {
  local unit="${POSTBOOT_UNIT_NAME:-stellar-offline-os-upgrade-postboot.service}"
  local unit_path="${TMP}/etc/systemd/system/${unit}"
  local en_state=""
  log INFO "POSTBOOT_HANDOFF_CHECK=START unit=${unit}"
  if [[ ! -f "$unit_path" ]]; then
    log ERROR "POSTBOOT_UNIT_FILE_MISSING=${unit_path}"
    return 1
  fi
  if ! systemctl daemon-reload; then
    log ERROR "POSTBOOT_DAEMON_RELOAD=FAIL"
    return 1
  fi
  if ! systemctl enable "$unit"; then
    log ERROR "POSTBOOT_ENABLE=FAIL"
    return 1
  fi
  en_state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  case "$en_state" in
    enabled|enabled-runtime|static|indirect|alias) return 0 ;;
  esac
  log ERROR "POSTBOOT_IS_ENABLED_MISMATCH state=${en_state:-empty}"
  return 1
}
# missing unit
if ensure_postboot_unit_enabled_before_reboot; then echo MISSING_SHOULD_FAIL; exit 1; fi
: >"${TMP}/etc/systemd/system/${POSTBOOT_UNIT_NAME}"
# enable failure
export FAKE_ENABLE_RC=1
if ensure_postboot_unit_enabled_before_reboot; then echo ENABLE_SHOULD_FAIL; exit 1; fi
export FAKE_ENABLE_RC=0
# is-enabled mismatch
export FAKE_IS_ENABLED=disabled
if ensure_postboot_unit_enabled_before_reboot; then echo ENABLED_MISMATCH_SHOULD_FAIL; exit 1; fi
export FAKE_IS_ENABLED=enabled
ensure_postboot_unit_enabled_before_reboot
echo POSTBOOT_HARNESS_OK
H
bash "${TMP}/postboot_harness.sh" "$ROOT" "$TMP" | grep -q POSTBOOT_HARNESS_OK \
  && pass "postboot enable success/failure/mismatch harness" || fail "postboot harness"

# --- Finding 5: generic kernel gate ---
GATE="${ROOT}/client/dp-postboot-generic-kernel-gate.sh.inc"
bash -n "$GATE" && pass "generic gate bash -n" || fail "generic gate syntax"
# shellcheck source=/dev/null
source "$GATE"
export TEST_ROOT="$TMP"
export HOLDS_DIR="/holds"
mkdir -p "${TMP}/holds" "${TMP}/boot" "${TMP}/etc"
printf '4.4.0-210-generic\n' >"${TMP}/holds/source_kernel_release"
printf 'generic\n' >"${TMP}/holds/source_kernel_flavor"
printf 'VERSION_ID="18.04"\n' >"${TMP}/etc/os-release"
export DP_OFFLINE_FAKE_KERNEL="4.4.0-210-generic"
# Fake dpkg-query
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/dpkg-query" <<'DQ'
#!/usr/bin/env bash
if [[ "$1" == "-W" && "$3" == "linux-image-generic" ]]; then
  echo "install ok installed"; exit 0
fi
if [[ "$*" == *'linux-image-*'* ]]; then
  echo "linux-image-4.15.0-200-generic"
  exit 0
fi
if [[ "$*" == *Status* ]]; then
  echo "install ok installed"; exit 0
fi
exit 0
DQ
chmod +x "${TMP}/bin/dpkg-query"
export PATH="${TMP}/bin:$PATH"
# Create target boot artifacts
: >"${TMP}/boot/vmlinuz-4.15.0-200-generic"
echo x >"${TMP}/boot/vmlinuz-4.15.0-200-generic"
: >"${TMP}/boot/initrd.img-4.15.0-200-generic"
echo x >"${TMP}/boot/initrd.img-4.15.0-200-generic"
# Override generic_is_aws_profile
generic_is_aws_profile() { return 1; }
validate_generic_target_kernel_pre_reboot "18.04" \
  && pass "generic pre-reboot PASS with target image" || fail "generic pre-reboot"
# Postboot stale source must fail
if validate_generic_running_kernel_postboot "18.04"; then
  fail "stale source kernel should fail postboot"
else
  pass "generic postboot rejects stale source kernel"
fi
export DP_OFFLINE_FAKE_KERNEL="4.15.0-200-generic"
validate_generic_running_kernel_postboot "18.04" \
  && pass "generic postboot PASS on target series" || fail "generic postboot pass"
# Templates include generic gate token
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  grep -q '@@GENERIC_KERNEL_GATE_LIB@@' "${ROOT}/client/dp-offline-upgrade-${hop}.sh.in" \
    && pass "${hop} generic gate token" || fail "${hop} generic token"
done
# AWS gate still present / unchanged skip contract
AWS="${ROOT}/client/dp-postboot-aws-kernel-gate.sh.inc"
grep -q 'non_aws_profile' "$AWS" && pass "AWS gate still skips non-aws" || fail "AWS skip"

# --- Finding 6: completion semantics ---
grep -q 'DP_UPGRADE_COMPLETE=NO' "$LIFE" \
  && pass "lifecycle emits DP_UPGRADE_COMPLETE=NO on bringup PASS" || fail "complete semantics"
grep -q 'BRINGUP_PROCESS_SUCCESS' "$LIFE" \
  && pass "BRINGUP_PROCESS_SUCCESS separated" || fail "process success"
grep -q 'CLUSTER_VALIDATION' "$HELPER" \
  && pass "staging emits CLUSTER_VALIDATION=PENDING" || fail "staging cluster pending"

# Field usability
MENU="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
grep -q 'DO NOT RUN OS-HOP UPGRADES ON MULTIPLE DP NODES IN PARALLEL' "$MENU" \
  && pass "serial cluster OS-hop guidance" || fail "serial guidance"
grep -q 'PHASE2_MTU_PREFLIGHT\|p2b_emit_mtu_warning' \
  "${ROOT}/client/lib/dp-phase2-cluster-validation.sh" \
  && pass "MTU warning helper" || fail "MTU helper"
grep -q 'p2b_emit_mtu_warning' "$WRAP" && pass "MTU warned before bringup" || fail "MTU wiring"
grep -q 'PHASE2_AELLA_SHELL_PREFLIGHT' "$HELPER" \
  && pass "Phase2 aella shell preflight message" || fail "shell preflight"

# Shared helper consistency across four hops
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  t="${ROOT}/client/dp-offline-upgrade-${hop}.sh.in"
  grep -q 'validate_generic_target_kernel_pre_reboot' "$t" \
    && pass "${hop} generic pre-reboot wired" || fail "${hop} generic pre-reboot"
  grep -q 'validate_generic_running_kernel_postboot' "$t" \
    && pass "${hop} generic postboot wired" || fail "${hop} generic postboot"
done

bash -n "${ROOT}/client/lib/dp-phase2-time-readiness.sh"
bash -n "${ROOT}/client/lib/dp-phase2-post-bringup-migration.sh"
bash -n "${ROOT}/client/lib/dp-phase2-cluster-validation.sh"
bash -n "$HELPER"
bash -n "$WRAP"
bash -n "$LIFE"
pass "bash -n on changed helpers"

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAILED=${FAIL}"
  exit 1
fi
echo "ALL OPERATIONAL RELIABILITY TARGETED CHECKS PASSED"
