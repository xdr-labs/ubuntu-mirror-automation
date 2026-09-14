#!/usr/bin/env bash
# scripts/dp-os-upgrade-runner.sh — Phase 1 hop executor (pinned runtime copy)
# Compatible with Bash 4.3+ / Ubuntu 16.04.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Prefer sibling common library (runtime pin) then repo path
if [[ -f "${SCRIPT_DIR}/dp-os-upgrade-common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/dp-os-upgrade-common.sh"
  OSU_ROOT="${OSU_ROOT:-}"
elif [[ -f "${SCRIPT_DIR}/lib/dp-os-upgrade-common.sh" ]]; then
  # shellcheck source=lib/dp-os-upgrade-common.sh
  source "${SCRIPT_DIR}/lib/dp-os-upgrade-common.sh"
  OSU_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
else
  printf 'ERROR: cannot locate dp-os-upgrade-common.sh\n' >&2
  exit 3
fi

MODE="run"
for arg in "$@"; do
  case "$arg" in
    --from-install) MODE="from-install" ;;
    --resume) MODE="resume" ;;
    --retry) MODE="retry" ;;
  esac
done

osu_init_test_mode || exit "$EXIT_CLI"
osu_load_config "${OSU_CONFIG_FILE:-}" || exit "$EXIT_CLI"
# Durable authorization (state + operator-approval) is applied in runner_init_state.
# Do not treat a transient exported OSU_EXECUTE as sufficient on its own.
OSU_EXECUTE=0

# When running from pinned runtime, OSU_ROOT may be empty — recover from state
if [[ -z "${OSU_ROOT:-}" ]]; then
  if [[ -f "${OSU_STATE_DIR}/policy-effective.conf" ]]; then
    OSU_ROOT="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")" # best effort
  fi
fi

runner_init_state() {
  [[ -f "$(osu_state_path)" ]] || { osu_log ERROR "no state.json"; exit "$EXIT_INTEGRITY"; }
  osu_verify_state_checksum || { osu_log ERROR "state checksum mismatch"; exit "$EXIT_INTEGRITY"; }
  osu_load_state_into_vars || exit "$EXIT_INTEGRITY"
  osu_verify_runtime || { osu_set_blocked "runtime_checksum_changed" false; exit "$EXIT_BLOCKED"; }
  if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
    # Test harness authorizes via install-written approval when present; else allow.
    if ! osu_apply_execute_authorization; then
      OSU_EXECUTE=1
    fi
  else
    osu_apply_execute_authorization || {
      osu_log ERROR "runner refused: durable execute authorization missing/invalid"
      exit "$EXIT_INTEGRITY"
    }
  fi
}

# Advance OS fake version in test mode after a hop
runner_simulate_os_advance() {
  local to_ver="$1" to_code="$2"
  if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
    export DP_OS_UPGRADE_FAKE_OS_VERSION="$to_ver"
    export DP_OS_UPGRADE_FAKE_OS_CODENAME="$to_code"
    local osr
    osr="$(osu_hostpath /etc/os-release)"
    mkdir -p "$(dirname "$osr")"
    cat >"$osr" <<EOF
NAME="Ubuntu"
VERSION_ID="${to_ver}"
VERSION_CODENAME=${to_code}
ID=ubuntu
EOF
  fi
}

runner_setup_hop_dirs() {
  local hop_num="$1" from_code="$2" to_code="$3"
  local name
  name="$(osu_hop_dirname "$hop_num" "$from_code" "$to_code")"
  OSU_CURRENT_HOP_DIR="${OSU_STATE_DIR}/hops/${name}"
  mkdir -p "$OSU_CURRENT_HOP_DIR"/{repository-before,repository-after,dist-upgrade,apt}
  printf '%s' "$OSU_CURRENT_HOP_DIR"
}

runner_write_hop_plan() {
  local hop_dir="$1" from_ver="$2" from_code="$3" to_ver="$4" to_code="$5"
  cat >"${hop_dir}/plan.json" <<EOF
{
  "from_os": "${from_ver}",
  "from_codename": "${from_code}",
  "to_os": "${to_ver}",
  "to_codename": "${to_code}",
  "package_source_mode": "$(osu_json_escape "${ST_PKG_MODE}")",
  "phase2": false
}
EOF
}

runner_snapshot_before() {
  local hop_dir="$1"
  local osr
  osr="$(osu_hostpath /etc/os-release)"
  [[ -f "$osr" ]] && cp -a "$osr" "${hop_dir}/os-before.txt"
  osu_read_held_packages >"${hop_dir}/held-before.txt" || true
  if [[ -f "${OSU_STATE_DIR}/original-system-state/critical-checksums.tsv" ]]; then
    cp -a "${OSU_STATE_DIR}/original-system-state/critical-checksums.tsv" "${hop_dir}/critical-checksums-before.tsv"
  fi
  if [[ -f "$(osu_hostpath /etc/apt/sources.list)" ]]; then
    cp -a "$(osu_hostpath /etc/apt/sources.list)" "${hop_dir}/repository-before/sources.list" || true
  fi
  if declare -F osu_capture_hop_artifacts >/dev/null 2>&1; then
    osu_capture_hop_artifacts "$hop_dir" before || osu_log WARN "artifact before-capture warning"
  fi
}

runner_snapshot_after() {
  local hop_dir="$1"
  local osr
  osr="$(osu_hostpath /etc/os-release)"
  [[ -f "$osr" ]] && cp -a "$osr" "${hop_dir}/os-after.txt"
  osu_read_held_packages >"${hop_dir}/held-after.txt" || true
  if [[ -f "${OSU_STATE_DIR}/original-system-state/critical-checksums.tsv" ]]; then
    cp -a "${OSU_STATE_DIR}/original-system-state/critical-checksums.tsv" "${hop_dir}/critical-checksums-after.tsv"
  fi
  if [[ -f "$(osu_hostpath /etc/apt/sources.list)" ]]; then
    cp -a "$(osu_hostpath /etc/apt/sources.list)" "${hop_dir}/repository-after/sources.list" || true
  fi
  if declare -F osu_capture_hop_artifacts >/dev/null 2>&1; then
    osu_capture_hop_artifacts "$hop_dir" after || osu_log WARN "artifact after-capture warning"
  fi
}

runner_run_do_release_upgrade() {
  local hop_dir="$1" to_code="$2"
  # Noninteractive; options vary by Ubuntu version — use conservative set
  # Never invent unsupported flags for xenial.
  local args=(-f DistUpgradeViewNonInteractive)
  # Frontend noninteractive via env in osu_run_command
  if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
    osu_run_command "${ST_CURRENT_HOP}" "do-release-upgrade" "simulated do-release-upgrade to ${to_code}" \
      "${POLICY_DO_RELEASE_UPGRADE_TIMEOUT_SECONDS}" false -- \
      do-release-upgrade "${args[@]}" || return 1
    # Stub should advance OS; if not, runner_simulate_os_advance is called by caller
    return 0
  fi
  osu_run_command "${ST_CURRENT_HOP}" "do-release-upgrade" "do-release-upgrade" \
    "${POLICY_DO_RELEASE_UPGRADE_TIMEOUT_SECONDS}" false -- \
    do-release-upgrade "${args[@]}" || return 1
  # Collect dist-upgrade logs
  if [[ -d "$(osu_hostpath /var/log/dist-upgrade)" ]]; then
    cp -a "$(osu_hostpath /var/log/dist-upgrade)/." "${hop_dir}/dist-upgrade/" 2>/dev/null || true
  fi
  return 0
}

runner_execute_hop() {
  local hop_num="$1" from_ver="$2" from_code="$3" to_ver="$4" to_code="$5"
  local hop_dir

  ST_CURRENT_HOP="$hop_num"
  ST_CURRENT_OS="$from_ver"
  ST_CURRENT_CODENAME="$from_code"
  ST_TARGET_OS="$to_ver"
  ST_TARGET_CODENAME="$to_code"
  ST_ATTEMPT=$(( ${ST_ATTEMPT:-0} + 1 ))

  hop_dir="$(runner_setup_hop_dirs "$hop_num" "$from_code" "$to_code")"
  OSU_CURRENT_HOP_DIR="$hop_dir"
  runner_write_hop_plan "$hop_dir" "$from_ver" "$from_code" "$to_ver" "$to_code"

  osu_transition_state HOP_PRECHECK "hop_precheck" || return 1
  if osu_honor_pause_boundary; then exit "$EXIT_PAUSED"; fi

  # Confirm current OS matches hop source
  local cur
  cur="$(osu_current_os_version)"
  if [[ "$cur" != "$from_ver" ]]; then
    # If already at target (resume after reboot), skip to validate
    if [[ "$cur" == "$to_ver" ]]; then
      osu_transition_state HOP_VALIDATING "already_at_target" || { osu_set_failed "cannot_transition_already_at_target"; return 1; }
      if osu_post_hop_validate "$to_ver" "$to_code"; then
        runner_snapshot_after "$hop_dir"
        cat >"${hop_dir}/validation.json" <<EOF
{"status":"PASS","os":"${to_ver}","codename":"${to_code}"}
EOF
        cat >"${hop_dir}/result.json" <<EOF
{"status":"HOP_COMPLETED","from":"${from_ver}","to":"${to_ver}"}
EOF
        osu_transition_state HOP_COMPLETED "hop_completed"
        return 0
      else
        osu_set_failed "post_reboot_validation_failed"
        return 1
      fi
    fi
    osu_set_failed "os_state_conflict current=$cur expected=$from_ver"
    return 1
  fi

  # Live precheck
  if ! osu_live_precheck; then
    # classify retryable
    case "${LIVE_PRECHECK_REASONS}" in
      *apt_lock*|*ntp_unsynchronized*)
        osu_set_blocked "${LIVE_PRECHECK_REASONS}" true
        ;;
      *)
        osu_set_blocked "${LIVE_PRECHECK_REASONS}" false
        ;;
    esac
    return 1
  fi

  if ! osu_manage_critical_holds_if_enabled; then
    osu_set_blocked "critical_holds_unmanaged" false
    return 1
  fi

  # Shared resume-stage resolver (same as mid-hop dispatcher / transition targets)
  local resume_stage target_state
  resume_stage="$(osu_resolve_resume_stage)"
  target_state="$(osu_resume_stage_target_state "$resume_stage")"
  osu_log INFO "hop dispatch resume_stage=${resume_stage} target_state=${target_state:-none}"

  case "$resume_stage" in
    CONTINUE_RELEASE_UPGRADE)
      runner_continue_release_upgrade "$hop_num" "$hop_dir" "$from_ver" "$from_code" "$to_ver" "$to_code"
      return $?
      ;;
    CONTINUE_CURRENT_RELEASE_UPDATE)
      runner_continue_current_release_update "$hop_num" "$hop_dir" "$from_ver" "$from_code" "$to_ver" "$to_code"
      return $?
      ;;
    BLOCKED_INCONSISTENT_EVIDENCE)
      osu_set_blocked "inconsistent_resume_evidence" false
      return 1
      ;;
    CONTINUE_SOURCE_PREPARATION|"")
      ;;
    *)
      # Fresh hop / unknown stage: fall through to source preparation
      ;;
  esac

  # Fresh install / early hop: HOP_PRECHECK -> HOP_SOURCE_PREPARING
  osu_transition_state HOP_SOURCE_PREPARING "source_preparing" || return 1
  if osu_honor_pause_boundary; then exit "$EXIT_PAUSED"; fi

  runner_snapshot_before "$hop_dir"
  osu_backup_apt_sources
  osu_disable_third_party_repos

  if ! osu_verify_hop_repository "$ST_PKG_MODE" "$ST_PKG_URL" "$from_code"; then
    case "$ST_PKG_MODE" in
      mirror|cache) osu_set_blocked "repository_unavailable_${from_code}" true ;;
      *) osu_set_blocked "repository_unavailable_${from_code}" false ;;
    esac
    return 1
  fi
  # Also verify target release metadata exists for next hop planning
  if ! osu_verify_hop_repository "$ST_PKG_MODE" "$ST_PKG_URL" "$to_code"; then
    osu_set_blocked "target_repository_unavailable_${to_code}" false
    return 1
  fi

  osu_apply_sources_for_hop "$ST_PKG_MODE" "$ST_PKG_URL" "$from_code"
  osu_write_source_plan "$ST_PKG_MODE" "$ST_PKG_URL" "$from_code"
  osu_transition_state HOP_SOURCE_READY "source_ready" || return 1

  runner_continue_current_release_update "$hop_num" "$hop_dir" "$from_ver" "$from_code" "$to_ver" "$to_code"
  return $?
}

# Current-release apt update then release upgrade (skips repository source preparation).
runner_continue_current_release_update() {
  local hop_num="$1" hop_dir="$2" from_ver="$3" from_code="$4" to_ver="$5" to_code="$6"

  if [[ "${ST_LAST_STEP:-}" == "current_release_updated" ]]; then
    osu_log INFO "last_successful_step=current_release_updated — skipping current-release apt update"
    runner_continue_release_upgrade "$hop_num" "$hop_dir" "$from_ver" "$from_code" "$to_ver" "$to_code"
    return $?
  fi

  case "$ST_STATE" in
    HOP_CURRENT_RELEASE_UPDATING) ;;
    *)
      osu_transition_state HOP_CURRENT_RELEASE_UPDATING "current_release_updating" || return 1
      ;;
  esac
  if osu_honor_pause_boundary; then exit "$EXIT_PAUSED"; fi

  osu_run_command "$hop_num" "dpkg_configure" "dpkg --configure -a" 600 true -- dpkg --configure -a || true
  osu_run_command "$hop_num" "apt_fix" "apt-get -f install" 600 true -- apt-get -y -f install || {
    osu_set_failed "apt_fix_failed"; return 1
  }
  osu_run_command "$hop_num" "apt_update" "apt-get update" "${POLICY_APT_UPDATE_TIMEOUT_SECONDS}" true -- apt-get update || {
    osu_set_blocked "apt_update_failed" true; return 1
  }
  osu_run_command "$hop_num" "apt_full_upgrade" "apt-get dist-upgrade (current release)" \
    "${POLICY_APT_UPDATE_TIMEOUT_SECONDS}" true -- apt-get -y dist-upgrade || {
    osu_set_failed "current_release_upgrade_failed"; return 1
  }
  ST_LAST_STEP="current_release_updated"
  ST_NEXT_ACTION="RUN_RELEASE_UPGRADE"
  osu_write_state_json "$(osu_build_state_json)" || { osu_set_failed "state_persistence_failed"; return 1; }

  runner_continue_release_upgrade "$hop_num" "$hop_dir" "$from_ver" "$from_code" "$to_ver" "$to_code"
  return $?
}

# Release-upgrade phase only: upgrader-core + do-release-upgrade (no source prep / apt update).
# Transition: HOP_PRECHECK (or mid states) -> HOP_RELEASE_UPGRADE_STARTING
runner_continue_release_upgrade() {
  local hop_num="$1" hop_dir="$2" from_ver="$3" from_code="$4" to_ver="$5" to_code="$6"

  # Preserve verified current-release completion across state step labels
  ST_LAST_STEP="current_release_updated"
  ST_NEXT_ACTION="RUN_RELEASE_UPGRADE"
  osu_write_state_json "$(osu_build_state_json)" || { osu_set_failed "state_persistence_failed"; return 1; }
  if osu_honor_pause_boundary; then exit "$EXIT_PAUSED"; fi

  case "$ST_STATE" in
    HOP_RELEASE_UPGRADE_STARTING|HOP_RELEASE_UPGRADE_RUNNING) ;;
    *)
      osu_transition_state HOP_RELEASE_UPGRADE_STARTING "release_upgrade_starting" || return 1
      ST_LAST_STEP="current_release_updated"
      ST_NEXT_ACTION="RUN_RELEASE_UPGRADE"
      ;;
  esac
  osu_write_state_json "$(osu_build_state_json)" || return 1

  osu_run_command "$hop_num" "upgrader_core" "ensure ubuntu-release-upgrader-core" 600 true -- \
    apt-get -y install ubuntu-release-upgrader-core || true

  if osu_honor_pause_boundary; then exit "$EXIT_PAUSED"; fi

  if [[ "$ST_STATE" != "HOP_RELEASE_UPGRADE_RUNNING" ]]; then
    osu_transition_state HOP_RELEASE_UPGRADE_RUNNING "release_upgrade_running" || return 1
    ST_LAST_STEP="current_release_updated"
    ST_NEXT_ACTION="RUN_RELEASE_UPGRADE"
    osu_write_state_json "$(osu_build_state_json)" || { osu_set_failed "state_persistence_failed"; return 1; }
  fi
  if ! runner_run_do_release_upgrade "$hop_dir" "$to_code"; then
    osu_set_failed "do_release_upgrade_failed"
    return 1
  fi

  # In test mode, advance OS representation now (simulates upgrade before reboot)
  runner_simulate_os_advance "$to_ver" "$to_code"

  # Require reboot for each hop by policy
  osu_transition_state REBOOT_REQUIRED "reboot_required" || return 1
  cat >"${hop_dir}/result.json" <<EOF
{"status":"REBOOT_REQUIRED","from":"${from_ver}","to":"${to_ver}"}
EOF
  if osu_honor_pause_boundary; then exit "$EXIT_PAUSED"; fi

  # Ensure systemd resume enabled (best effort)
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable dp-os-upgrade.service 2>/dev/null || true
  fi

  osu_request_reboot || return 1

  # In test mode, continue as if reboot happened
  if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
    mkdir -p "$(dirname "$(osu_hostpath /proc/sys/kernel/random/boot_id)")"
    printf 'boot-%s\n' "$(osu_utc_stamp)" >"$(osu_hostpath /proc/sys/kernel/random/boot_id)"
    osu_transition_state RESUMED "post_reboot_resumed" || return 1
    osu_transition_state HOP_VALIDATING "post_reboot_validating" || return 1
    if ! osu_post_hop_validate "$to_ver" "$to_code"; then
      osu_set_failed "post_hop_validation_failed"
      return 1
    fi
    runner_snapshot_after "$hop_dir"
    cat >"${hop_dir}/validation.json" <<EOF
{"status":"PASS","os":"${to_ver}","codename":"${to_code}"}
EOF
    cat >"${hop_dir}/result.json" <<EOF
{"status":"HOP_COMPLETED","from":"${from_ver}","to":"${to_ver}"}
EOF
    ST_CURRENT_OS="$to_ver"
    ST_CURRENT_CODENAME="$to_code"
    osu_transition_state HOP_COMPLETED "hop_completed" || return 1
    return 0
  fi

  # Production: exit after reboot request; systemd will resume
  exit "$EXIT_RESUME_REQUIRED"
}

runner_handle_reboot_resume() {
  case "$ST_STATE" in
    REBOOT_REQUESTED|REBOOT_REQUIRED)
      local cur_boot cur classification evidence
      cur_boot="$(osu_boot_id)"
      cur="$(osu_current_os_version)"
      classification="$(osu_classify_in_progress_hop)"
      evidence="$(osu_hop_release_upgrade_evidence)"
      osu_log INFO "reboot-resume classification=${classification} evidence=${evidence} os=${cur}"

      case "$classification" in
        FAILED)
          osu_set_failed "release_upgrade_failed_before_reboot"
          return 1
          ;;
        BLOCKED|BLOCKED_INCONSISTENT_EVIDENCE)
          osu_set_blocked "reboot_state_without_clear_upgrade_evidence" false
          return 1
          ;;
        RESUME_REQUIRED|CONTINUE_SOURCE_PREPARATION|CONTINUE_CURRENT_RELEASE_UPDATE|CONTINUE_RELEASE_UPGRADE)
          # Sticky REBOOT_* without success evidence — demote; do not reboot or re-run dro blindly.
          osu_log WARN "REBOOT state without release-upgrade success evidence — demoting for resume (evidence=${evidence})"
          if [[ "$evidence" == "NOT_STARTED" ]]; then
            local hop_dir rs
            hop_dir="$(osu_current_hop_dir || true)"
            if [[ -n "$hop_dir" && -f "${hop_dir}/result.json" ]]; then
              rs="$(osu_json_get "${hop_dir}/result.json" status 2>/dev/null || true)"
              if [[ "$rs" == "REBOOT_REQUIRED" ]]; then
                osu_backup_false_reboot_result || true
              fi
            fi
            if [[ "${ST_LAST_STEP:-}" == "current_release_updated" ]]; then
              ST_LAST_STEP="current_release_updated"
              ST_NEXT_ACTION="RUN_RELEASE_UPGRADE"
            else
              ST_LAST_STEP="before_release_upgrade"
              ST_NEXT_ACTION="RUN_OS_UPGRADE"
            fi
            ST_NEW_PREFLIGHT_REQUIRED=true
            ST_HOPS_THIS_RUN=0
            osu_transition_state RESUME_REQUIRED "demote_false_reboot_not_started" || {
              osu_set_blocked "cannot_demote_false_reboot_state" false
              return 1
            }
            osu_log ERROR "false REBOOT demoted to RESUME_REQUIRED — run recover-not-started or resume --preflight (refusing blind dro)"
            return 1
          else
            # Unclear-but-classified-resume: park in release-upgrade-starting for mid-hop review
            osu_transition_state HOP_RELEASE_UPGRADE_STARTING "demote_false_reboot_resume" || {
              osu_set_blocked "cannot_demote_false_reboot_state" false
              return 1
            }
          fi
          osu_write_state_json "$(osu_build_state_json)" || { osu_set_failed "state_persistence_failed"; return 1; }
          runner_resume_mid_hop
          return $?
          ;;
        REBOOT_REQUIRED|CONTINUE_POST_UPGRADE_REBOOT)
          ;;
        *)
          osu_set_blocked "unexpected_reboot_classification:${classification}" false
          return 1
          ;;
      esac

      if [[ "$evidence" != "SUCCESS" ]]; then
        osu_set_blocked "reboot_refused_without_success_evidence:${evidence}" false
        return 1
      fi

      if [[ -n "${ST_BOOT_ID:-}" && "$cur_boot" == "$ST_BOOT_ID" && "$OSU_TEST_MODE" -eq 0 ]]; then
        # Same boot: reboot never happened (e.g. prior auth bug) or still pending.
        # Do not re-run do-release-upgrade; re-request reboot only with success evidence.
        if [[ -n "${ST_TARGET_OS:-}" && "$cur" == "$ST_TARGET_OS" ]]; then
          osu_log WARN "boot_id unchanged but OS already at ${cur} — re-requesting reboot"
          if [[ "$ST_STATE" == "REBOOT_REQUESTED" ]]; then
            osu_transition_state REBOOT_REQUIRED "reboot_requeue" || return 1
          fi
          osu_request_reboot || return 1
          exit "$EXIT_RESUME_REQUIRED"
        fi
        osu_log WARN "boot_id unchanged after REBOOT_REQUESTED — waiting for real reboot (no dro re-run)"
        exit "$EXIT_RESUME_REQUIRED"
      fi
      if [[ "$ST_STATE" == "REBOOT_REQUIRED" && "$OSU_TEST_MODE" -eq 0 ]]; then
        osu_request_reboot || return 1
        exit "$EXIT_RESUME_REQUIRED"
      fi
      if [[ "$ST_STATE" == "REBOOT_REQUIRED" ]]; then
        osu_request_reboot || return 1
      fi
      # Post-reboot path: OS must already reflect hop target
      if [[ -n "${ST_TARGET_OS:-}" && "$cur" != "$ST_TARGET_OS" ]]; then
        osu_set_blocked "post_reboot_os_still_${cur}_expected_${ST_TARGET_OS}" false
        return 1
      fi
      osu_transition_state RESUMED "boot_resumed" || return 1
      osu_transition_state HOP_VALIDATING "validating_after_reboot" || return 1
      if ! osu_post_hop_validate "$ST_TARGET_OS" "$ST_TARGET_CODENAME"; then
        cur="$(osu_current_os_version)"
        if [[ "$cur" == "$ST_CURRENT_OS" ]]; then
          osu_set_blocked "reboot_incomplete_still_on_${cur}" false
          return 1
        fi
        osu_set_failed "wrong_target_os_after_reboot"
        return 1
      fi
      local hop_dir
      hop_dir="$(runner_setup_hop_dirs "$ST_CURRENT_HOP" "$ST_CURRENT_CODENAME" "$ST_TARGET_CODENAME")"
      runner_snapshot_after "$hop_dir"
      cat >"${hop_dir}/validation.json" <<EOF
{"status":"PASS","os":"${ST_TARGET_OS}","codename":"${ST_TARGET_CODENAME}"}
EOF
      ST_CURRENT_OS="$ST_TARGET_OS"
      ST_CURRENT_CODENAME="$ST_TARGET_CODENAME"
      osu_transition_state HOP_COMPLETED "hop_completed"
      ;;
  esac
  return 0
}

runner_resume_mid_hop() {
  local classification evidence target_state hop_dir
  # Same resolver as hop dispatch / transition target mapping
  classification="$(osu_resolve_resume_stage)"
  evidence="$(osu_hop_release_upgrade_evidence)"
  target_state="$(osu_resume_stage_target_state "$classification")"
  osu_log INFO "mid-hop classification=${classification} evidence=${evidence} state=${ST_STATE} os=$(osu_current_os_version) target_state=${target_state:-none}"
  case "$classification" in
    REBOOT_REQUIRED|CONTINUE_POST_UPGRADE_REBOOT)
      if [[ "$evidence" != "SUCCESS" ]]; then
        local cur
        cur="$(osu_current_os_version)"
        if [[ -n "${ST_TARGET_OS:-}" && "$cur" == "$ST_TARGET_OS" ]]; then
          :
        else
          osu_set_blocked "classified_reboot_without_success_evidence:${evidence}" false
          return 1
        fi
      fi
      if [[ "$ST_STATE" != "REBOOT_REQUIRED" && "$ST_STATE" != "REBOOT_REQUESTED" ]]; then
        osu_transition_state REBOOT_REQUIRED "classified_reboot_required" || {
          osu_set_blocked "cannot_transition_to_reboot_required" false
          return 1
        }
      fi
      hop_dir="$(runner_setup_hop_dirs "$ST_CURRENT_HOP" "$ST_CURRENT_CODENAME" "$ST_TARGET_CODENAME")"
      if [[ ! -f "${hop_dir}/result.json" ]]; then
        cat >"${hop_dir}/result.json" <<EOF
{"status":"REBOOT_REQUIRED","from":"${ST_CURRENT_OS}","to":"${ST_TARGET_OS}","classified":true}
EOF
      fi
      osu_request_reboot || return 1
      if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
        return 0
      fi
      exit "$EXIT_RESUME_REQUIRED"
      ;;
    VALIDATE)
      osu_transition_state HOP_VALIDATING "classified_validate" || { osu_set_failed "cannot_transition_classified_validate"; return 1; }
      if osu_post_hop_validate "$ST_TARGET_OS" "$ST_TARGET_CODENAME"; then
        hop_dir="$(runner_setup_hop_dirs "$ST_CURRENT_HOP" "$ST_CURRENT_CODENAME" "$ST_TARGET_CODENAME")"
        runner_snapshot_after "$hop_dir"
        ST_CURRENT_OS="$ST_TARGET_OS"
        ST_CURRENT_CODENAME="$ST_TARGET_CODENAME"
        osu_transition_state HOP_COMPLETED "hop_completed"
        return 0
      fi
      osu_set_blocked "post_upgrade_validation_failed" false
      return 1
      ;;
    CONTINUE_RELEASE_UPGRADE)
      hop_dir="$(runner_setup_hop_dirs "$ST_CURRENT_HOP" "$ST_CURRENT_CODENAME" "$ST_TARGET_CODENAME")"
      OSU_CURRENT_HOP_DIR="$hop_dir"
      ST_ATTEMPT=$(( ${ST_ATTEMPT:-0} + 1 ))
      runner_write_hop_plan "$hop_dir" "$ST_CURRENT_OS" "$ST_CURRENT_CODENAME" "$ST_TARGET_OS" "$ST_TARGET_CODENAME"
      if [[ "$ST_STATE" == "HOP_PRECHECK" || "$ST_STATE" == "RESUME_REQUIRED" ]]; then
        if [[ "$ST_STATE" == "RESUME_REQUIRED" ]]; then
          osu_transition_state HOP_PRECHECK "resume_release_upgrade" || { osu_set_failed "cannot_transition_resume_release_upgrade"; return 1; }
        fi
        # HOP_PRECHECK -> HOP_RELEASE_UPGRADE_STARTING (never HOP_SOURCE_PREPARING)
        runner_continue_release_upgrade "$ST_CURRENT_HOP" "$hop_dir" \
          "$ST_CURRENT_OS" "$ST_CURRENT_CODENAME" "$ST_TARGET_OS" "$ST_TARGET_CODENAME"
        return $?
      fi
      runner_continue_release_upgrade "$ST_CURRENT_HOP" "$hop_dir" \
        "$ST_CURRENT_OS" "$ST_CURRENT_CODENAME" "$ST_TARGET_OS" "$ST_TARGET_CODENAME"
      return $?
      ;;
    CONTINUE_CURRENT_RELEASE_UPDATE)
      hop_dir="$(runner_setup_hop_dirs "$ST_CURRENT_HOP" "$ST_CURRENT_CODENAME" "$ST_TARGET_CODENAME")"
      OSU_CURRENT_HOP_DIR="$hop_dir"
      ST_ATTEMPT=$(( ${ST_ATTEMPT:-0} + 1 ))
      runner_write_hop_plan "$hop_dir" "$ST_CURRENT_OS" "$ST_CURRENT_CODENAME" "$ST_TARGET_OS" "$ST_TARGET_CODENAME"
      if [[ "$ST_STATE" != "HOP_CURRENT_RELEASE_UPDATING" && "$ST_STATE" != "HOP_SOURCE_READY" ]]; then
        if [[ "$ST_STATE" != "HOP_PRECHECK" ]]; then
          osu_transition_state HOP_PRECHECK "resume_current_release" || { osu_set_failed "cannot_transition_resume_current_release"; return 1; }
        fi
      fi
      if ! osu_live_precheck; then
        case "${LIVE_PRECHECK_REASONS}" in
          *apt_lock*|*ntp_unsynchronized*) osu_set_blocked "${LIVE_PRECHECK_REASONS}" true ;;
          *) osu_set_blocked "${LIVE_PRECHECK_REASONS}" false ;;
        esac
        return 1
      fi
      runner_continue_current_release_update "$ST_CURRENT_HOP" "$hop_dir" \
        "$ST_CURRENT_OS" "$ST_CURRENT_CODENAME" "$ST_TARGET_OS" "$ST_TARGET_CODENAME"
      return $?
      ;;
    CONTINUE_SOURCE_PREPARATION)
      runner_execute_hop "$ST_CURRENT_HOP" "$ST_CURRENT_OS" "$ST_CURRENT_CODENAME" "$ST_TARGET_OS" "$ST_TARGET_CODENAME"
      return $?
      ;;
    BLOCKED_INCONSISTENT_EVIDENCE)
      osu_set_blocked "inconsistent_resume_evidence" false
      return 1
      ;;
    RESUME_REQUIRED)
      if [[ "$evidence" == "NOT_STARTED" ]]; then
        osu_log INFO "release upgrade not started — resolving resume stage without reboot"
        if [[ "${ST_LAST_STEP:-}" == "current_release_updated" ]]; then
          hop_dir="$(runner_setup_hop_dirs "$ST_CURRENT_HOP" "$ST_CURRENT_CODENAME" "$ST_TARGET_CODENAME")"
          OSU_CURRENT_HOP_DIR="$hop_dir"
          if [[ "$ST_STATE" != "HOP_PRECHECK" ]]; then
            osu_transition_state HOP_PRECHECK "resume_not_started_release" || { osu_set_failed "cannot_transition_resume_not_started_release"; return 1; }
          fi
          runner_continue_release_upgrade "$ST_CURRENT_HOP" "$hop_dir" \
            "$ST_CURRENT_OS" "$ST_CURRENT_CODENAME" "$ST_TARGET_OS" "$ST_TARGET_CODENAME"
          return $?
        fi
        if [[ "$ST_STATE" != "HOP_PRECHECK" && "$ST_STATE" != "HOP_SOURCE_PREPARING" && "$ST_STATE" != "HOP_SOURCE_READY" && "$ST_STATE" != "HOP_CURRENT_RELEASE_UPDATING" ]]; then
          osu_transition_state HOP_PRECHECK "resume_not_started" || { osu_set_failed "cannot_transition_resume_not_started"; return 1; }
        fi
        runner_execute_hop "$ST_CURRENT_HOP" "$ST_CURRENT_OS" "$ST_CURRENT_CODENAME" "$ST_TARGET_OS" "$ST_TARGET_CODENAME"
        return $?
      fi
      osu_log WARN "release upgrade appears in progress/pending — not re-running do-release-upgrade"
      osu_set_blocked "mid_hop_resume_required_manual_review" false
      return 1
      ;;
    FAILED)
      osu_set_failed "mid_hop_classification_failed"
      return 1
      ;;
    *)
      osu_set_blocked "mid_hop_requires_operator_review:${classification}" false
      return 1
      ;;
  esac
}

runner_enter_checkpoint() {
  local cur
  cur="$(osu_current_os_version)"
  ST_CURRENT_OS="$cur"
  ST_CURRENT_CODENAME="$(osu_current_os_codename)"
  ST_NEW_PREFLIGHT_REQUIRED=true
  ST_NEXT_ACTION="RECOLLECT_AND_REPREFLIGHT"
  osu_transition_state CHECKPOINT_REACHED "checkpoint_reached" "${ST_CHECKPOINT_REASON:-hop_limit}"
  osu_generate_reports
  osu_log INFO "CHECKPOINT_REACHED at ${cur}: ${ST_CHECKPOINT_REASON:-}. New collector/preflight required. Phase 2 not evaluated."
  exit "${EXIT_CHECKPOINT:-41}"
}

runner_next_hop_or_complete() {
  local cur
  cur="$(osu_current_os_version)"

  # If we just finished a hop, count it and maybe checkpoint before planning next
  if [[ "${ST_STATE}" == "HOP_COMPLETED" ]]; then
    ST_HOPS_THIS_RUN=$(( ${ST_HOPS_THIS_RUN:-0} + 1 ))
    ST_CURRENT_OS="$cur"
    ST_CURRENT_CODENAME="$(osu_current_os_codename)"
    osu_write_state_json "$(osu_build_state_json)" || { osu_set_failed "state_persistence_failed"; return 1; }
    if declare -F osu_should_checkpoint_after_hop >/dev/null 2>&1 && osu_should_checkpoint_after_hop "$cur"; then
      runner_enter_checkpoint
    fi
  fi

  if [[ "$cur" == "$POLICY_TARGET_OS_VERSION" ]]; then
    if ! osu_post_hop_validate "$POLICY_TARGET_OS_VERSION" "$POLICY_TARGET_OS_CODENAME"; then
      osu_set_failed "final_validation_failed"
      exit "$EXIT_FAILED"
    fi
    ST_NEXT_ACTION="RUN_SEPARATE_PHASE2_WORKFLOW"
    ST_NEW_PREFLIGHT_REQUIRED=false
    osu_transition_state COMPLETED "phase1_completed"
    osu_generate_reports
    osu_log INFO "Phase 1 OS upgrade completed. Ubuntu 24.04 validation passed. DP Python/Py3 upgrade was not evaluated or executed."
    exit "$EXIT_COMPLETED"
  fi

  # Refuse auto-continue from CHECKPOINT without new preflight
  if [[ "${ST_STATE}" == "CHECKPOINT_REACHED" ]]; then
    osu_log INFO "CHECKPOINT_REACHED — runner no-op; recollect and repreflight required"
    exit "${EXIT_CHECKPOINT:-41}"
  fi

  local line from_ver from_code to_ver to_code hop_num rest
  local -a hop_lines=()
  mapfile -t hop_lines < <(osu_plan_hops "$cur" || true)
  line="${hop_lines[0]:-}"
  if [[ -z "$line" || "$line" == UNSUPPORTED ]]; then
    osu_set_failed "cannot_plan_next_hop_from_${cur}"
    exit "$EXIT_FAILED"
  fi
  from_ver="${line%%:*}"
  rest="${line#*:}"
  from_code="${rest%%->*}"
  rest="${rest#*>}"
  to_ver="${rest%%:*}"
  to_code="${rest##*:}"

  # current_hop advances only after a hop completes (HOP_COMPLETED) or on first plan.
  # Never increment when retrying/resuming an incomplete hop (e.g. HOP_PRECHECK after failure).
  if [[ "${ST_STATE}" == "HOP_COMPLETED" || "${ST_CURRENT_HOP:-0}" -eq 0 ]]; then
    hop_num=$(( ${ST_CURRENT_HOP:-0} + 1 ))
  else
    hop_num="${ST_CURRENT_HOP}"
    osu_log INFO "reusing in-progress current_hop=${hop_num} (not incrementing before OS/boot validation)"
    # Prefer durable hop endpoints from state when present
    if [[ -n "${ST_CURRENT_OS:-}" && -n "${ST_TARGET_OS:-}" ]]; then
      from_ver="$ST_CURRENT_OS"
      from_code="${ST_CURRENT_CODENAME:-$from_code}"
      to_ver="$ST_TARGET_OS"
      to_code="${ST_TARGET_CODENAME:-$to_code}"
    fi
  fi
  if [[ "$from_ver" != "$cur" ]]; then
    osu_set_failed "lts_skip_rejected"
    exit "$EXIT_FAILED"
  fi

  # Discovery/production hop-limit before starting another hop when already at limit
  if declare -F osu_should_checkpoint_after_hop >/dev/null 2>&1; then
    # If max hops already reached before starting, checkpoint
    if [[ -n "${ST_MAX_HOPS:-}" && "${ST_HOPS_THIS_RUN:-0}" -ge "${ST_MAX_HOPS}" ]]; then
      ST_CHECKPOINT_REASON="max_hops_${ST_MAX_HOPS}"
      runner_enter_checkpoint
    fi
  fi

  if osu_honor_pause_boundary; then exit "$EXIT_PAUSED"; fi
  runner_execute_hop "$hop_num" "$from_ver" "$from_code" "$to_ver" "$to_code"
}

# MODE=retry is strictly retry-only. A timer firing while a normal runner
# holds the lock is expected and must exit 0 without mutating state.
runner_retry_begin() {
  local lock_class
  lock_class="$(osu_lock_classify 2>/dev/null || true)"
  case "$lock_class" in
    HELD_LIVE|BLOCKED_ACTIVITY)
      osu_log INFO "DP_OS_RETRY_ACTION=SKIPPED reason=runner_lock_busy lock_class=${lock_class}"
      exit 0
      ;;
  esac
  if ! osu_acquire_lock; then
    osu_log INFO "DP_OS_RETRY_ACTION=SKIPPED reason=runner_lock_busy"
    exit 0
  fi
  trap 'osu_release_lock' EXIT

  if [[ ! -f "$(osu_state_path)" ]]; then
    osu_log INFO "DP_OS_RETRY_ACTION=SKIPPED reason=no_state"
    exit 0
  fi
  osu_verify_state_checksum || {
    osu_log ERROR "state checksum mismatch"
    exit "$EXIT_INTEGRITY"
  }
  osu_load_state_into_vars || exit "$EXIT_INTEGRITY"

  if [[ "${ST_STATE:-}" != "BLOCKED" || "${ST_RETRYABLE}" != "true" ]]; then
    osu_log INFO "DP_OS_RETRY_ACTION=SKIPPED reason=state_not_retryable state=${ST_STATE:-unknown} retryable=${ST_RETRYABLE:-false}"
    exit 0
  fi
  osu_log INFO "DP_OS_RETRY_ACTION=EXECUTE state=BLOCKED retryable=true"
  runner_init_state
}

main() {
  if [[ "$MODE" == "retry" ]]; then
    runner_retry_begin
  else
    if ! osu_acquire_lock; then
      osu_log ERROR "unable to acquire lock"
      exit "$EXIT_INTEGRITY"
    fi
    trap 'osu_release_lock' EXIT
    runner_init_state
  fi

  case "$ST_STATE" in
    COMPLETED)
      osu_log INFO "COMPLETED — runner no-op; Phase 2 not executed"
      exit "$EXIT_COMPLETED"
      ;;
    CHECKPOINT_REACHED)
      osu_log INFO "CHECKPOINT_REACHED — runner no-op; new preflight required"
      exit "${EXIT_CHECKPOINT:-41}"
      ;;
    FAILED)
      osu_log ERROR "FAILED — refusing automatic run"
      exit "$EXIT_FAILED"
      ;;
    PAUSED)
      osu_log ERROR "PAUSED"
      exit "$EXIT_PAUSED"
      ;;
    BLOCKED)
      if [[ "$ST_RETRYABLE" != "true" || "$MODE" != "retry" ]]; then
        if [[ "$MODE" != "resume" || "$ST_RETRYABLE" != "true" ]]; then
          osu_log ERROR "BLOCKED (retryable=${ST_RETRYABLE})"
          exit "$EXIT_BLOCKED"
        fi
      fi
      # retryable resume / MODE=retry: go back to hop precheck
      osu_transition_state HOP_PRECHECK "retry_from_blocked" || { osu_set_failed "cannot_transition_retry_from_blocked"; return 1; }
      ;;
  esac

  if osu_pause_active; then
    osu_transition_state PAUSED "pause_marker" || { osu_set_failed "cannot_transition_pause_marker"; exit "${EXIT_FAILED:-30}"; }
    exit "$EXIT_PAUSED"
  fi

  case "$ST_STATE" in
    REBOOT_REQUESTED|REBOOT_REQUIRED)
      if ! runner_handle_reboot_resume; then
        osu_load_state_into_vars || true
        if [[ "$ST_STATE" == "RESUME_REQUIRED" ]]; then
          exit "$EXIT_RESUME_REQUIRED"
        fi
        exit "$EXIT_FAILED"
      fi
      osu_load_state_into_vars || true
      # If still waiting on reboot after handle, stop; demoted hops fall through.
      if [[ "$ST_STATE" == "REBOOT_REQUESTED" || "$ST_STATE" == "REBOOT_REQUIRED" ]]; then
        exit "$EXIT_RESUME_REQUIRED"
      fi
      if [[ "$ST_STATE" == "RESUME_REQUIRED" ]]; then
        exit "$EXIT_RESUME_REQUIRED"
      fi
      ;;
    RESUME_REQUIRED)
      osu_log ERROR "RESUME_REQUIRED — refusing runner until resume --preflight (new_preflight_required=${ST_NEW_PREFLIGHT_REQUIRED:-false})"
      exit "$EXIT_RESUME_REQUIRED"
      ;;
  esac

  case "$ST_STATE" in
    INITIALIZED|HOP_COMPLETED|RESUMED|PREFLIGHT_ACCEPTED)
      runner_next_hop_or_complete
      # Loop remaining hops in test mode
      while [[ "$(osu_current_os_version)" != "$POLICY_TARGET_OS_VERSION" ]]; do
        case "$(osu_read_state_field current_state)" in
          HOP_COMPLETED|RESUMED|INITIALIZED) ;;
          COMPLETED) break ;;
          CHECKPOINT_REACHED) exit "${EXIT_CHECKPOINT:-41}" ;;
          PAUSED) exit "$EXIT_PAUSED" ;;
          BLOCKED) exit "$EXIT_BLOCKED" ;;
          FAILED) exit "$EXIT_FAILED" ;;
          REBOOT_REQUESTED|REBOOT_REQUIRED)
            if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
              osu_load_state_into_vars
              runner_handle_reboot_resume || exit "$EXIT_FAILED"
            else
              exit "$EXIT_RESUME_REQUIRED"
            fi
            ;;
          *) break ;;
        esac
        osu_load_state_into_vars
        runner_next_hop_or_complete || break
      done
      osu_load_state_into_vars
      if [[ "$(osu_current_os_version)" == "$POLICY_TARGET_OS_VERSION" && "$ST_STATE" != "COMPLETED" ]]; then
        osu_transition_state COMPLETED "phase1_completed"
        osu_generate_reports
      fi
      ;;
    HOP_PRECHECK)
      # Incomplete hop after resume --preflight: reuse current_hop (do not plan hop N+1).
      if [[ "${ST_CURRENT_HOP:-0}" -gt 0 && -n "${ST_TARGET_OS:-}" ]]; then
        runner_resume_mid_hop || exit "$EXIT_BLOCKED"
      else
        runner_next_hop_or_complete
      fi
      ;;
    HOP_SOURCE_PREPARING|HOP_SOURCE_READY|HOP_CURRENT_RELEASE_UPDATING|HOP_RELEASE_UPGRADE_STARTING|HOP_RELEASE_UPGRADE_RUNNING|HOP_VALIDATING)
      # Resume mid-hop carefully — never blindly re-run do-release-upgrade
      if [[ -z "${ST_TARGET_OS:-}" ]]; then
        runner_next_hop_or_complete
      else
        runner_resume_mid_hop || exit "$EXIT_BLOCKED"
      fi
      ;;
    *)
      osu_log ERROR "runner refused for state=$ST_STATE"
      exit "$EXIT_BLOCKED"
      ;;
  esac

  osu_load_state_into_vars || true
  case "$ST_STATE" in
    COMPLETED) exit "$EXIT_COMPLETED" ;;
    CHECKPOINT_REACHED) exit "${EXIT_CHECKPOINT:-41}" ;;
    PAUSED) exit "$EXIT_PAUSED" ;;
    BLOCKED) exit "$EXIT_BLOCKED" ;;
    FAILED) exit "$EXIT_FAILED" ;;
    REBOOT_REQUESTED|REBOOT_REQUIRED) exit "$EXIT_RESUME_REQUIRED" ;;
    *) exit 0 ;;
  esac
}

main "$@"
