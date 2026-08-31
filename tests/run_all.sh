#!/usr/bin/env bash
# tests/run_all.sh — Run all project tests with bounded timeouts and orphan cleanup.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
cd "$(dirname "${BASH_SOURCE[0]}")"

# shellcheck source=lib/worktree_fingerprint.sh
source "${ROOT}/tests/lib/worktree_fingerprint.sh"

DEFAULT_TIMEOUT_SECS="${TEST_TIMEOUT_SECS:-300}"
# test_dp_os_upgrade.sh alone is ~9 minutes on this host; keep headroom.
LONG_TIMEOUT_SECS="${TEST_LONG_TIMEOUT_SECS:-900}"
FAIL=0
INTEGRATION_RAN=0
INTEGRATION_PASS=0

TEST_LIST=(
  test_install.sh
  test_validate.sh
  test_validate_fixture.sh
  test_nginx.sh
  test_systemd.sh
  test_simplified_install.sh
  test_fresh_bootstrap.sh
  test_dashboard.sh
  test_offline_mirror.sh
  test_upgrade_profile.py
  test_selective_mirror.py
  test_aws_selective_mirror_union.py
  test_selective_orchestration_lock.sh
  test_selective_runtime_migration.py
  test_sync_by_hash.py
  test_security_compat.py
  test_release_upgraders.py
  test_legacy_releases.py
  test_analyze_upgrade_discovery.py
  test_collect_dp_upgrade_readiness.sh
  test_dp_upgrade_preflight.sh
  test_dp_os_upgrade.sh
  test_dp_os_upgrade_retry_and_validate.sh
  test_discover_upgrade_requirements.sh
  test_destructive_confirmation.sh
  test_phase1_finalize.sh
  test_ntp_pre_transition_quiesce.sh
  test_ntp_dns_postboot_policy.sh
  test_dns_time_readiness_policy.sh
  test_dp_offline_upgrade_xenial_to_bionic.sh
  test_postboot_shebang_and_state_machine.sh
  test_durable_write_and_lxd_coldstart.sh
  test_lxd_long_operation_heartbeat.sh
  test_dp_offline_upgrade_bionic_to_focal.sh
  test_dp_offline_upgrade_focal_to_jammy.sh
  test_dp_offline_upgrade_jammy_to_noble.sh
  test_dp_phase2_bundle.sh
  test_dp_phase2_client_stage.sh
  test_dp_phase2_release_env_publish.sh
  test_dp_phase2_version_compat.sh
  test_phase2_target_660.sh
  test_dp_phase2_ownership.sh
  test_dp_phase2_cache_resume.sh
  test_acps_resume_disk_preflight.sh
  test_dp_phase2_process_detect.sh
  test_dp_upgrade_mirror_manager.sh
  test_gui_client_commands.sh
  test_bringup_worker_password.sh
  test_bringup_acps_sha_policy.sh
  test_patch_dp_phase2_bringup.py
  test_phase2_bringup_fresh_upstream.sh
  test_bringup_lifecycle.sh
  test_bringup_lifecycle_run_contract.sh
  test_bringup_lifecycle_failed_retry.sh
  test_mirror_download_and_space_regressions.sh
  test_phase2_bundle_reuse_disk.sh
  test_phase2_stale_bringup_bundle.sh
  test_phase2_stale_bringup_no_acps_redownload.sh
  test_mirror_long_step_progress.sh
  test_mirror_manager_menu_status.sh
  test_bringup_image_import_heartbeat.sh
  test_bringup_dp_resume_notice.sh
  test_phase2_ubuntu_prerequisites.py
  test_phase2_virtual_provides.py
  test_phase2_prereq_dpkg_rc.sh
  test_phase2_prereq_stage_failclosed.sh
  test_phase2_prereq_worker_contract.sh
  test_phase2_prereq_version_aware.sh
  test_phase2_prereq_extract_sigpipe.sh
  test_phase2_cluster_readiness.sh
  test_phase2_remote_orchestration_semantics.sh
  test_phase2_remote_hardening.sh
  test_client_manifest_signing.sh
  test_worktree_isolation.sh
  test_distupgrade_config_ascii.sh
  test_distupgrade_source_compat.py
  test_prepare_backup_staging.sh
  test_migrate_apt_mirror_to_root.sh
  test_mirror_host_ip_resolution.sh
  test_mirror_manager_ip_configuration.sh
  test_http_publication_permissions.sh
  test_http_enable_local_smoke.sh
  test_http_enable_nginx_transaction.sh
  test_workflow_kv_getters.sh
  test_client_mirror_pin_gates.sh
  test_per_mirror_local_signing.sh
  test_client_ready_circular_gate.sh
  test_os_core_selective_ready_provenance.sh
  test_client_finalization_local_fs_integration.sh
  test_client_build_provenance.sh
  test_phase2_existing_reuse_progress.sh
  test_client_os_userspace_matrix.sh
  test_menu7_normal_width_display.sh
  test_phase2_extract_progress_separator.sh
  test_phase2_controller_dependency_fetch.sh
  test_phase2_helper_generation_trust.sh
  test_acps_verified_cache_metadata.sh
  test_reused_artifact_status.sh
  test_mirror_workflow_state_without_logger.sh
  test_current_hop_env_path_runner.sh
  test_phase2_complete_client_unit_publish.sh
  test_dashboard_workflow_status_cases.sh
  test_acps_effective_base_setu.sh
)

# Integration tests required for FULL_SUITE=PASS (real builders, not mocked finalizer).
INTEGRATION_REQUIRED=(
  test_client_finalization_local_fs_integration.sh
)

is_long_test() {
  case "$1" in
    test_dp_offline_upgrade_*.sh|test_dp_os_upgrade.sh|test_dp_upgrade_preflight.sh|test_selective_mirror.py|test_offline_mirror.sh|test_dp_upgrade_mirror_manager.sh|test_client_finalization_local_fs_integration.sh|test_client_os_userspace_matrix.sh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

clear_test_fixture_orphans() {
  # Only clear known test fixture patterns — never touch production upgrade processes.
  # Orphan local HTTP fixtures (discover-upgrade origin.port / phase2 http-counts)
  # accumulate across interrupted suites and can thrash a low-RAM host enough for
  # test_selective_mirror.py to exceed LONG_TIMEOUT_SECS under run_all.
  local pid cmd signal
  for signal in TERM KILL; do
    while IFS= read -r pid; do
      pid="${pid#"${pid%%[![:space:]]*}"}"
      pid="${pid%"${pid##*[![:space:]]}"}"
      [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || continue
      [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
      [[ -r "/proc/${pid}/cmdline" ]] || continue
      cmd="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
      if [[ "$cmd" == *fixture-dp-offline-upgrade* || "$cmd" == */fake-*upgrade* || "$cmd" == *worktree-isolation-child* ]]; then
        kill "-${signal}" "$pid" 2>/dev/null || true
        continue
      fi
      # python3 - /tmp/tmp.*/origin{,2,3}.port   OR   python3 - /tmp/tmp.*/http <port> .../http-counts
      # Also Mirror Manager fixture servers that record http-counts under /tmp.
      if [[ "$cmd" == python3\ -\ /tmp/tmp.* ]] && \
         { [[ "$cmd" == *origin.port* || "$cmd" == *origin2.port* || "$cmd" == *origin3.port* || "$cmd" == *http-counts* ]]; }; then
        kill "-${signal}" "$pid" 2>/dev/null || true
      fi
    done < <(ps -eo pid= 2>/dev/null || true)
    [[ "$signal" == TERM ]] && sleep 0.5 || true
  done
}

FP_BASE="$(mktemp -d)"
FP_CUR="$(mktemp -d)"
trap 'rm -rf "$FP_BASE" "$FP_CUR"' EXIT

echo "======== Clearing leftover test fixture orphans ========"
clear_test_fixture_orphans

echo "======== Capturing worktree baseline fingerprint ========"
# Existing intentional Phase 2 (or other) dirty files are part of the baseline.
# run_all must not introduce *additional* tracked/untracked drift beyond this.
worktree_save_fingerprint "$ROOT" "$FP_BASE"
echo "BASELINE_TRACKED_LINES=$(wc -l <"${FP_BASE}/tracked.sha256")"
echo "BASELINE_UNTRACKED_LINES=$(wc -l <"${FP_BASE}/untracked.list")"

check_contamination_after() {
  local label="$1"
  rm -rf "$FP_CUR"
  mkdir -p "$FP_CUR"
  worktree_save_fingerprint "$ROOT" "$FP_CUR"
  if ! worktree_diff_fingerprint "$FP_BASE" "$FP_CUR"; then
    echo "RUN_ALL_WORKTREE_CONTAMINATION=FAIL after=${label}"
    FAIL=1
    return 1
  fi
  echo "RUN_ALL_WORKTREE_CONTAMINATION=PASS after=${label}"
  return 0
}

run_one() {
  local t="$1"
  local timeout_secs="$DEFAULT_TIMEOUT_SECS"
  local rc=0
  if is_long_test "$t"; then
    timeout_secs="$LONG_TIMEOUT_SECS"
  fi
  echo "======== Running $t (timeout=${timeout_secs}s) ========"
  set +e
  # Default timeout places the command in its own process group so TERM/KILL
  # apply to the whole tree (children included).
  # Drop stale fixture env so handoff/runner matching and monitor policy stay isolated.
  if [[ "$t" == *.py ]]; then
    env -u STELLAR_OFFLINE_TEST_ROOT -u DP_OFFLINE_TEST_HANDOFF -u DETACH_AFTER_HANDOFF \
      timeout --signal=TERM --kill-after=30s "$timeout_secs" python3 "$t"
    rc=$?
  else
    env -u STELLAR_OFFLINE_TEST_ROOT -u DP_OFFLINE_TEST_HANDOFF -u DETACH_AFTER_HANDOFF \
      timeout --signal=TERM --kill-after=30s "$timeout_secs" bash "$t"
    rc=$?
  fi
  set -e
  for req in "${INTEGRATION_REQUIRED[@]}"; do
    if [[ "$t" == "$req" ]]; then
      INTEGRATION_RAN=$((INTEGRATION_RAN + 1))
      if [[ "$rc" -eq 0 ]]; then
        INTEGRATION_PASS=$((INTEGRATION_PASS + 1))
      fi
    fi
  done
  if [[ "$rc" -eq 0 ]]; then
    echo "OK $t"
  elif [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
    echo "FAIL $t (TIMEOUT)"
    FAIL=1
    echo "---- process tree snapshot ----"
    ps -efH || true
  else
    echo "FAIL $t (exit=${rc})"
    FAIL=1
  fi
  clear_test_fixture_orphans
  check_contamination_after "$t" || true
  echo
}

for t in "${TEST_LIST[@]}"; do
  run_one "$t"
done

# ShellCheck + bash -n on product scripts (tests have their own shellcheck;
# artifacts/ holds generated client copies; vendor/ is upstream bringup;
# client hop scripts are validated by dedicated offline-upgrade tests + bash -n).
echo "======== Syntax & ShellCheck ========"
mapfile -t SCRIPTS < <(
  find "$ROOT" -type f \( -name '*.sh' -o -name 'mirrorctl' -o -name 'install.sh' -o -name 'uninstall.sh' -o -name 'validate.sh' \) \
    ! -path '*/.git/*' \
    ! -path '*/tests/*' \
    ! -path '*/artifacts/*' \
    ! -path '*/vendor/*' \
    ! -path '*/client/dp-offline-upgrade-*.sh'
)
for s in "${SCRIPTS[@]}"; do
  bash -n "$s" || FAIL=1
done

# Also bash -n the large client hop scripts and vendor bringup (syntax only).
mapfile -t EXTRA_BASH_N < <(
  find "$ROOT" -type f \( -path '*/client/dp-offline-upgrade-*.sh' -o -path '*/vendor/dp-phase2/*.sh' \) ! -path '*/.git/*'
)
for s in "${EXTRA_BASH_N[@]}"; do
  bash -n "$s" || FAIL=1
done

if command -v shellcheck >/dev/null 2>&1; then
  # Fail the suite on ShellCheck errors only; info/warning style noise is tracked
  # separately and must not mask a green functional suite.
  # SC1090/SC1091: dynamic source paths (runtime-resolved; -x follows source= hints)
  # SC1003/SC2009/SC2012/SC2016/SC2185/SC2094/SC2001/SC2002: intentional patterns
  #   (JSON escape, ps|grep process evidence collection, ls|wc counts, literal $ in quotes)
  # SC2148/SC2221/SC2222/SC2086/SC2318: known shared-lib style patterns (shebang-less
  #   injectables, overlapping case arms, intentional word-split apt args, local reuse)
  if ! (cd "$ROOT" && shellcheck -x --severity=error -e \
    SC1090,SC1091,SC2015,SC2034,SC2119,SC2120,SC2317,SC1003,SC2009,SC2012,SC2016,SC2185,SC2094,SC2001,SC2002,SC2148,SC2221,SC2222,SC2086,SC2318 \
    "${SCRIPTS[@]}"); then
    FAIL=1
  fi
else
  echo "WARNING: shellcheck not installed (SKIP)"
fi

clear_test_fixture_orphans
left="$(ps -eo args= | grep -E 'fixture-dp-offline-upgrade|worktree-isolation-child|python3 - /tmp/tmp\..*(origin\.port|origin2\.port|origin3\.port|http-counts)' | grep -v grep || true)"
if [[ -n "${left// }" ]]; then
  echo "WARNING: leftover matching processes after suite:"
  printf '%s\n' "$left"
  FAIL=1
fi

echo "======== Final worktree contamination check ========"
check_contamination_after "suite_end" || true

# FULL_SUITE requires every listed integration test to have executed and passed.
if [[ "${#INTEGRATION_REQUIRED[@]}" -gt 0 ]]; then
  if [[ "$INTEGRATION_RAN" -lt "${#INTEGRATION_REQUIRED[@]}" ]] \
    || [[ "$INTEGRATION_PASS" -lt "${#INTEGRATION_REQUIRED[@]}" ]]; then
    echo "FULL_SUITE_RESULT=FAIL (integration coverage incomplete ran=${INTEGRATION_RAN} pass=${INTEGRATION_PASS} required=${#INTEGRATION_REQUIRED[@]})"
    FAIL=1
  fi
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "RUN_ALL_ADDITIONAL_TRACKED_DIFF=0"
  echo "RUN_ALL_ADDITIONAL_UNTRACKED_FILES=0"
  echo "UNIT_TESTS=PASS"
  echo "REAL_FOUR_HOP_BUILD_TEST=PASS"
  echo "INSTALLED_RUNTIME_TEST=PASS"
  echo "NO_NETWORK_PREPARE_TEST=PASS"
  echo "ACTUAL_HTTP_ENABLE_TEST=PASS"
  echo "RETRY_REUSE_TEST=PASS"
  echo "FAILURE_ATOMICITY_TEST=PASS"
  echo "FULL_SUITE_RESULT=PASS"
  echo "ALL TESTS PASSED"
  exit 0
fi
echo "FULL_SUITE_RESULT=FAIL"
echo "SOME TESTS FAILED"
exit 1
