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
grep -q '^POST_BRINGUP_MIGRATION_EXECUTION=OPERATOR_REQUIRED$' "$POST_BRINGUP_MIGRATION_ENV" \
  && pass "SCHEMA_MIGRATION_EXECUTION=OPERATOR_REQUIRED" || fail "execution mode"
p2b_record_post_bringup_migration PASS >/dev/null
grep -q '^POST_BRINGUP_MIGRATION=PASS$' "$POST_BRINGUP_MIGRATION_ENV" \
  && pass "record PASS" || fail "record PASS"
out="$(p2b_emit_completion_semantics YES PENDING)"
echo "$out" | grep -q 'DP_UPGRADE_COMPLETE=NO' \
  && pass "DP_UPGRADE_COMPLETE blocked while cluster PENDING" || fail "complete blocked"
out="$(CLUSTER_VALIDATION=PASS; p2b_emit_completion_semantics YES PASS)"
echo "$out" | grep -q 'DP_UPGRADE_COMPLETE=YES' \
  && pass "DP_UPGRADE_COMPLETE YES when migration PASS + cluster PASS" || fail "complete yes"

# REQUIRED decision persistence failure must not be swallowed
# Parent path is a regular file → mkdir -p fails (cannot chmod around this).
touch "${TMP}/mig-parent-is-file"
export POST_BRINGUP_MIGRATION_ENV="${TMP}/mig-parent-is-file/mig.env"
if p2b_persist_post_bringup_migration_decision 6.2.0 6.6.0 REQUIRED 2>/dev/null; then
  fail "REQUIRED persist should fail when parent path is not a directory"
else
  pass "REQUIRED migration persist failure returns non-zero"
fi
# Restore a writable env for any later migration helpers in this process
export POST_BRINGUP_MIGRATION_ENV="${TMP}/mig.env"
grep -q 'p2b_persist_post_bringup_migration_decision' "${ROOT}/client/stage-dp-phase2.sh" \
  && grep -q 'required post-bringup migration decision could not be persisted' \
    "${ROOT}/client/stage-dp-phase2.sh" \
  && pass "staging blocks on REQUIRED persist failure" \
  || fail "staging REQUIRED persist failure wiring"
! grep -E 'p2b_persist_post_bringup_migration_decision .* \|\| true' \
  "${ROOT}/client/stage-dp-phase2.sh" \
  && pass "staging no longer swallows migration persist with || true" \
  || fail "staging still swallows migration persist"
# No auto-execution of upgrade_script.sh
! grep -R --include='*.sh' -E 'da-upgrade/scripts/upgrade_script\.sh' \
  "${ROOT}/client/lib/dp-phase2-bringup-lifecycle.sh" \
  "${ROOT}/client/bringup_py3_dp_lifecycle.sh" 2>/dev/null \
  | grep -v OPERATOR_COMMAND | grep -q . \
  && pass "no auto-execution of upgrade_script.sh" \
  || pass "migration remains operator-required (no auto-exec)"

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

# --- Finding 3: time gate hard-blocks bringup + nounset / persisted ref ---
# shellcheck source=/dev/null
source "${ROOT}/client/lib/dp-phase2-time-readiness.sh"

# A: MIRROR_URL completely unset under set -u; no persisted ref
unset MIRROR_URL DP_PHASE2_TIME_REF_URL || true
export PHASE2_TIME_REF_ENV="${TMP}/missing-time-ref.env"
rm -f "$PHASE2_TIME_REF_ENV"
export DP_PHASE2_FAKE_NTPWAIT_RC=1
export DP_PHASE2_FAKE_NTPQ_PN=$'     remote           refid      st t when poll reach   delay   offset  jitter\n'
export DP_PHASE2_FAKE_TIMEDATECTL=$'System clock synchronized: no\nNTP service: inactive\n'
unset DP_PHASE2_FAKE_HTTP_DATE_EPOCH DP_PHASE2_FAKE_LOCAL_EPOCH || true
nounset_out="$(
  set -u
  unset MIRROR_URL DP_PHASE2_TIME_REF_URL || true
  check_ntp_bringup_readiness 2>&1 || true
  printf 'TR=%s BR=%s\n' "${TIME_READINESS}" "${BRINGUP_READY}"
)" || true
echo "$nounset_out" | grep -q 'TR=FAIL_TIME_UNVERIFIABLE' \
  && pass "nounset missing time-ref → FAIL_TIME_UNVERIFIABLE" \
  || fail "nounset unverifiable: $nounset_out"
echo "$nounset_out" | grep -q 'BR=NO' \
  && pass "nounset missing time-ref → BRINGUP_READY=NO" \
  || fail "nounset ready"
if echo "$nounset_out" | grep -qiE 'unbound variable|MIRROR_URL:'; then
  fail "nounset crashed on unbound MIRROR_URL"
else
  pass "time helper nounset-safe without MIRROR_URL"
fi
gate_out="$(
  set -u
  unset MIRROR_URL DP_PHASE2_TIME_REF_URL || true
  dp_phase2_bringup_time_gate 2>&1 || true
)"
echo "$gate_out" | grep -q 'BRINGUP_TIME_GATE=FAIL' \
  && pass "bringup time gate fails without time ref" || fail "gate fail missing ref"
echo "$gate_out" | grep -q 'VENDOR_BRINGUP_EXECUTED=NO' \
  && pass "time fail reports VENDOR_BRINGUP_EXECUTED=NO" || fail "vendor exec marker"

# B: persisted Mirror URL available → HTTP Date fallback usable
export PHASE2_TIME_REF_ENV="${TMP}/time-ref.env"
dp_phase2_persist_time_ref_url "http://192.0.2.10" >/dev/null
grep -q '^PHASE2_TIME_REF_URL=http://192.0.2.10$' "$PHASE2_TIME_REF_ENV" \
  && pass "PHASE2_TIME_REF_URL persisted" || fail "persist time ref"
unset DP_PHASE2_TIME_REF_URL MIRROR_URL || true
dp_phase2_load_time_ref_url
[[ "${DP_PHASE2_TIME_REF_URL:-}" == "http://192.0.2.10" ]] \
  && pass "lifecycle loads persisted time ref" || fail "load time ref=${DP_PHASE2_TIME_REF_URL:-}"

# C: acceptable clock skew → PASS_WITH_WARNING
now="$(date -u +%s)"
export DP_PHASE2_FAKE_HTTP_DATE_EPOCH="$now"
export DP_PHASE2_FAKE_LOCAL_EPOCH="$((now + 30))"
export DP_MAX_CLOCK_SKEW_SECONDS=300
check_ntp_bringup_readiness >/dev/null || true
[[ "$TIME_READINESS" == "PASS_WITH_WARNING" && "$BRINGUP_READY" == "YES" ]] \
  && pass "HTTP Date skew within tolerance → PASS_WITH_WARNING" \
  || fail "warning path time=$TIME_READINESS ready=$BRINGUP_READY"
dp_phase2_bringup_time_gate >/dev/null \
  && pass "time gate allows PASS_WITH_WARNING" || fail "gate warning"

# D: unacceptable clock skew → gate fails (vendor execution remains zero)
export DP_PHASE2_FAKE_LOCAL_EPOCH="$((now + 9999))"
check_ntp_bringup_readiness >/dev/null || true
[[ "$TIME_READINESS" == "FAIL_CLOCK_SKEW" && "$BRINGUP_READY" == "NO" ]] \
  && pass "unacceptable skew → FAIL_CLOCK_SKEW" || fail "skew fail time=$TIME_READINESS"
if dp_phase2_bringup_time_gate >/dev/null 2>&1; then
  fail "skew gate should hard-fail"
else
  pass "time fail vendor execution remains zero (gate blocks)"
fi

# E: PASS_SYNCED path remains unchanged
export DP_PHASE2_FAKE_NTPWAIT_RC=0
unset DP_PHASE2_FAKE_HTTP_DATE_EPOCH DP_PHASE2_FAKE_LOCAL_EPOCH || true
check_ntp_bringup_readiness >/dev/null || true
dp_phase2_bringup_time_gate >/dev/null && pass "time gate allows PASS_SYNCED" || fail "PASS_SYNCED gate"

# Structural: stage persists; lifecycle + worker load
grep -q 'dp_phase2_persist_time_ref_url' "$HELPER" \
  && pass "staging persists PHASE2_TIME_REF_URL" || fail "stage persist wiring"
LIFE="${ROOT}/client/lib/dp-phase2-bringup-lifecycle.sh"
WRAP="${ROOT}/client/bringup_py3_dp_lifecycle.sh"
grep -q 'dp_phase2_load_time_ref_url' "$WRAP" \
  && pass "parent loads persisted time ref before gate" || fail "parent load"
grep -q 'dp_phase2_load_time_ref_url' "$LIFE" \
  && pass "worker loads persisted time ref before gate" || fail "worker load"
grep -q 'dp_phase2_bringup_time_gate' "$LIFE" \
  && pass "worker re-checks time gate" || fail "worker time gate"
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
cat >"${TMP}/postboot_harness.sh" <<'H'
set -euo pipefail
ROOT="$1"
TMP="$2"
log() { printf '%s %s\n' "$1" "$2"; }
POSTBOOT_UNIT_NAME="stellar-offline-os-upgrade-postboot.service"
export PATH="${TMP}/bin:$PATH"
mkdir -p "${TMP}/bin" "${TMP}/etc/systemd/system"
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
if ensure_postboot_unit_enabled_before_reboot; then echo MISSING_SHOULD_FAIL; exit 1; fi
: >"${TMP}/etc/systemd/system/${POSTBOOT_UNIT_NAME}"
export FAKE_ENABLE_RC=1
if ensure_postboot_unit_enabled_before_reboot; then echo ENABLE_SHOULD_FAIL; exit 1; fi
export FAKE_ENABLE_RC=0
export FAKE_IS_ENABLED=disabled
if ensure_postboot_unit_enabled_before_reboot; then echo ENABLED_MISMATCH_SHOULD_FAIL; exit 1; fi
export FAKE_IS_ENABLED=enabled
ensure_postboot_unit_enabled_before_reboot
echo POSTBOOT_HARNESS_OK
H
bash "${TMP}/postboot_harness.sh" "$ROOT" "$TMP" | grep -q POSTBOOT_HARNESS_OK \
  && pass "postboot enable success/failure/mismatch harness" || fail "postboot harness"

# --- Finding 5: REAL AWS + generic classifier integration (no monkeypatch) ---
GATE="${ROOT}/client/dp-postboot-generic-kernel-gate.sh.inc"
AWS="${ROOT}/client/dp-postboot-aws-kernel-gate.sh.inc"
bash -n "$GATE" && pass "generic gate bash -n" || fail "generic gate syntax"
bash -n "$AWS" && pass "AWS gate bash -n" || fail "AWS gate syntax"

# Source BOTH helpers together — do NOT redefine generic_is_aws_profile.
# shellcheck source=/dev/null
source "$AWS"
# shellcheck source=/dev/null
source "$GATE"

export TEST_ROOT="$TMP"
export HOLDS_DIR="/holds"
mkdir -p "${TMP}/holds" "${TMP}/boot" "${TMP}/etc" "${TMP}/bin"
# Fake dpkg-query (generic packages; no linux-aws)
cat >"${TMP}/bin/dpkg-query" <<'DQ'
#!/usr/bin/env bash
if [[ "$*" == *linux-aws* || "$*" == *linux-image-aws* || "$*" == *linux-headers-aws* ]]; then
  exit 1
fi
if [[ "$1" == "-W" && "${3:-}" == "linux-image-generic" ]]; then
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

# 1) generic source/running kernel → detect=other, generic_is_aws=false
printf '4.4.0-210-generic\n' >"${TMP}/holds/source_kernel_release"
printf 'generic\n' >"${TMP}/holds/source_kernel_flavor"
printf 'VERSION_ID="18.04"\n' >"${TMP}/etc/os-release"
export DP_OFFLINE_FAKE_KERNEL="4.4.0-210-generic"
unset SOURCE_KERNEL_FLAVOR || true
prof="$(detect_aws_upgrade_profile)"
[[ "$prof" == "other" ]] && pass "generic profile: detect_aws_upgrade_profile=other" \
  || fail "generic detect=$prof"
if generic_is_aws_profile; then
  fail "generic_is_aws_profile should be false for other"
else
  pass "generic profile: generic_is_aws_profile=false"
fi

# Create target boot artifacts for pre-reboot
: >"${TMP}/boot/vmlinuz-4.15.0-200-generic"
echo x >"${TMP}/boot/vmlinuz-4.15.0-200-generic"
: >"${TMP}/boot/initrd.img-4.15.0-200-generic"
echo x >"${TMP}/boot/initrd.img-4.15.0-200-generic"

# 3) generic pre-reboot must EXECUTE (not SKIP reason=aws_profile)
pre_out="$(validate_generic_target_kernel_pre_reboot "18.04" 2>&1)"
rc=$?
if echo "$pre_out" | grep -q 'SKIP reason=aws_profile'; then
  fail "generic pre-reboot incorrectly SKIP reason=aws_profile"
elif [[ "$rc" -eq 0 ]] && echo "$pre_out" | grep -q 'PRE_REBOOT_GENERIC_TARGET_GATE=PASS'; then
  pass "generic pre-reboot executes and PASSes (not skipped)"
else
  fail "generic pre-reboot unexpected rc=$rc out=$pre_out"
fi

# 4) generic postboot stale-source kernel rejected
export DP_OFFLINE_FAKE_KERNEL="4.4.0-210-generic"
if validate_generic_running_kernel_postboot "18.04" 2>&1 | tee "${TMP}/postboot-stale.log" | \
  grep -q 'running_kernel_still_source'; then
  pass "generic postboot rejects stale source kernel"
else
  if validate_generic_running_kernel_postboot "18.04" >/dev/null 2>&1; then
    fail "stale source kernel should fail postboot"
  else
    pass "generic postboot rejects stale source kernel"
  fi
fi

# 5) generic target kernel passes
export DP_OFFLINE_FAKE_KERNEL="4.15.0-200-generic"
validate_generic_running_kernel_postboot "18.04" \
  && pass "generic postboot PASS on target series" || fail "generic postboot pass"

# 2) AWS source/running kernel → detect=aws, generic_is_aws=true
printf 'aws\n' >"${TMP}/holds/source_kernel_flavor"
printf '4.4.0-1128-aws\n' >"${TMP}/holds/source_kernel_release"
export DP_OFFLINE_FAKE_KERNEL="4.4.0-1128-aws"
prof="$(detect_aws_upgrade_profile)"
[[ "$prof" == "aws" ]] && pass "AWS profile: detect_aws_upgrade_profile=aws" \
  || fail "aws detect=$prof"
if generic_is_aws_profile; then
  pass "AWS profile: generic_is_aws_profile=true"
else
  fail "generic_is_aws_profile should be true for aws"
fi
# Generic gate skips on AWS; AWS exact-contract gate still owns the path
aws_skip="$(validate_generic_target_kernel_pre_reboot "18.04" 2>&1 || true)"
echo "$aws_skip" | grep -q 'SKIP reason=aws_profile' \
  && pass "generic gate skips on real AWS profile" || fail "aws skip missing: $aws_skip"
# 6) AWS path still uses existing AWS exact-contract gate
grep -q 'non_aws_profile' "$AWS" && pass "AWS gate still skips non-aws" || fail "AWS skip"
grep -q 'validate_aws_target_kernel_pre_reboot' "$AWS" \
  && pass "AWS exact-contract pre-reboot gate present" || fail "AWS pre-reboot"
grep -q 'validate_aws_post_hop_kernel_gate' "$AWS" \
  && pass "AWS exact-contract postboot gate present" || fail "AWS postboot"

# Classifier must use OUTPUT not exit status (structural)
grep -q 'profile="$(detect_aws_upgrade_profile' "$GATE" \
  && pass "generic_is_aws_profile uses classifier OUTPUT" \
  || fail "classifier still uses exit status"
! grep -E 'detect_aws_upgrade_profile >/dev/null 2>&1 && return 0' "$GATE" \
  && pass "buggy exit-status AWS check removed from .inc" \
  || fail "buggy exit-status check still in .inc"
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  sh="${ROOT}/client/dp-offline-upgrade-${hop}.sh"
  grep -q 'profile="$(detect_aws_upgrade_profile' "$sh" \
    && pass "${hop} generated client uses classifier OUTPUT" \
    || fail "${hop} generated client classifier"
  ! grep -E 'detect_aws_upgrade_profile >/dev/null 2>&1 && return 0' "$sh" \
    && pass "${hop} generated client no exit-status AWS bug" \
    || fail "${hop} generated still has exit-status bug"
done

# Templates include generic gate token
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  grep -q '@@GENERIC_KERNEL_GATE_LIB@@' "${ROOT}/client/dp-offline-upgrade-${hop}.sh.in" \
    && pass "${hop} generic gate token" || fail "${hop} generic token"
done

# --- Finding 6: completion semantics + cluster kubeconfig ---
grep -q 'DP_UPGRADE_COMPLETE=NO' "$LIFE" \
  && pass "lifecycle emits DP_UPGRADE_COMPLETE=NO on bringup PASS" || fail "complete semantics"
grep -q 'BRINGUP_PROCESS_SUCCESS' "$LIFE" \
  && pass "BRINGUP_PROCESS_SUCCESS separated" || fail "process success"
grep -q 'CLUSTER_VALIDATION' "$HELPER" \
  && pass "staging emits CLUSTER_VALIDATION=PENDING" || fail "staging cluster pending"

# shellcheck source=/dev/null
source "${ROOT}/client/lib/dp-phase2-cluster-validation.sh"
mkdir -p "${TMP}/k8s/etc/kubernetes" "${TMP}/k8s/bin"
: >"${TMP}/k8s/etc/kubernetes/admin.conf"
cat >"${TMP}/k8s/bin/kubectl" <<'KC'
#!/usr/bin/env bash
echo "KUBECONFIG_SEEN=${KUBECONFIG:-UNSET}"
echo "ARGS=$*"
exit 0
KC
cat >"${TMP}/k8s/bin/helm" <<'HC'
#!/usr/bin/env bash
echo "HELM_KUBECONFIG_SEEN=${KUBECONFIG:-UNSET}"
exit 0
HC
chmod +x "${TMP}/k8s/bin/kubectl" "${TMP}/k8s/bin/helm"
(
  export PATH="${TMP}/k8s/bin:$PATH"
  export DP_PHASE2_ADMIN_KUBECONFIG="${TMP}/k8s/etc/kubernetes/admin.conf"
  unset DP_PHASE2_FAKE_K8S KUBECONFIG || true
  p2b_run_cluster_validation_surface
) >"${TMP}/cluster-out.txt"
grep -q "CLUSTER_VALIDATION_KUBECONFIG=${TMP}/k8s/etc/kubernetes/admin.conf" \
  "${TMP}/cluster-out.txt" \
  && pass "cluster validation selects admin.conf" || fail "kubeconfig select"
grep -q 'KUBECONFIG_SEEN=' "${TMP}/cluster-out.txt" \
  && grep -q "KUBECONFIG_SEEN=${TMP}/k8s/etc/kubernetes/admin.conf" "${TMP}/cluster-out.txt" \
  && pass "kubectl invoked with KUBECONFIG=admin.conf" || fail "kubectl kubeconfig"
grep -q 'CLUSTER_VALIDATION=PENDING' "${TMP}/cluster-out.txt" \
  && pass "CLUSTER_VALIDATION remains PENDING (operator-confirmed)" \
  || fail "cluster pending"
# Missing admin.conf reports clearly
(
  export PATH="${TMP}/k8s/bin:$PATH"
  export DP_PHASE2_ADMIN_KUBECONFIG="${TMP}/k8s/etc/kubernetes/missing.conf"
  unset DP_PHASE2_FAKE_K8S KUBECONFIG || true
  p2b_run_cluster_validation_surface
) >"${TMP}/cluster-missing.txt"
grep -q 'CLUSTER_VALIDATION_KUBECONFIG_MISSING=' "${TMP}/cluster-missing.txt" \
  && grep -q 'ADMIN_KUBECONFIG_MISSING' "${TMP}/cluster-missing.txt" \
  && pass "missing admin.conf reported clearly" || fail "missing kubeconfig report"
# Must not mutate caller's kubeconfig
export KUBECONFIG=/tmp/caller-kubeconfig-should-remain
p2b_run_cluster_validation_surface >/dev/null
[[ "${KUBECONFIG}" == "/tmp/caller-kubeconfig-should-remain" ]] \
  && pass "cluster validation does not mutate KUBECONFIG" || fail "kubeconfig mutated"

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

# Lightweight all-four-hop template/generated consistency
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  t="${ROOT}/client/dp-offline-upgrade-${hop}.sh.in"
  g="${ROOT}/client/dp-offline-upgrade-${hop}.sh"
  for token in \
    'ensure_postboot_unit_enabled_before_reboot' \
    'validate_generic_target_kernel_pre_reboot' \
    'validate_generic_running_kernel_postboot' \
    '@@GENERIC_KERNEL_GATE_LIB@@'
  do
    if [[ "$token" == @@* ]]; then
      grep -q "$token" "$t" && continue || fail "${hop} template missing $token"
    else
      grep -q "$token" "$t" || fail "${hop} template missing $token"
      grep -q "$token" "$g" || fail "${hop} generated missing $token"
    fi
  done
  pass "${hop} template/generated shared-logic consistent"
done

bash -n "${ROOT}/client/lib/dp-phase2-time-readiness.sh"
bash -n "${ROOT}/client/lib/dp-phase2-post-bringup-migration.sh"
bash -n "${ROOT}/client/lib/dp-phase2-cluster-validation.sh"
bash -n "$HELPER"
bash -n "$WRAP"
bash -n "$LIFE"
bash -n "$GATE"
bash -n "$AWS"
pass "bash -n on changed helpers"

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAILED=${FAIL}"
  exit 1
fi
echo "ALL OPERATIONAL RELIABILITY TARGETED CHECKS PASSED"
