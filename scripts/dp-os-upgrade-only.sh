#!/usr/bin/env bash
# scripts/dp-os-upgrade-only.sh — Phase 1 Ubuntu OS upgrade orchestrator CLI
# Compatible with Bash 4.3+ / Ubuntu 16.04.
# Default is read-only. Mutating install requires --execute and destructive ack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSU_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export OSU_ROOT
# shellcheck source=lib/dp-os-upgrade-common.sh
source "${SCRIPT_DIR}/lib/dp-os-upgrade-common.sh"

SUBCOMMAND=""
PREFLIGHT_PATH=""
CONFIG_PATH=""
JSON_OUT=0
FOLLOW=0
LOG_LINES=50
LOG_HOP=""
PAUSE_REASON=""
EXECUTE=0
DESTRUCTIVE_ACK=""
PKG_MODE_OVERRIDE=""
PKG_URL_OVERRIDE=""
SNAPSHOT_OVERRIDE=""
BACKUP_OVERRIDE=""
EXECUTION_PROFILE=""
STOP_AFTER_OS=""
MAX_HOPS=""
DISCOVERY_ACK=""
EXPORT_HOP=""
EXPORT_OUTPUT_DIR="."
EXPORT_KEEP_DIR=0
ORPHAN_ARCHIVE_ACK=""

usage() {
  cat <<'EOF'
Usage: dp-os-upgrade-only.sh <subcommand> [options]

Phase 1 only: Ubuntu LTS hops through 24.04. Does NOT run DP bringup / Phase 2.

Subcommands:
  check                   Read-only preflight + live safety evaluation
  plan                    Read-only hop / source / reboot plan
  install                 Initialize state and start Phase 1 (requires safety gates)
  status                  Show current upgrade state (--json supported)
  resume                  Resume from existing state (optionally with new --preflight)
  continue                Continue after CHECKPOINT_REACHED with a fresh preflight
  validate                Read-only validation of current hop / final OS
  pause                   Request pause at next safe boundary
  unpause                 Clear pause marker
  logs                    Show recent logs (--follow, --hop, --lines)
  report                  Regenerate reports from current state
  export-artifacts        Export hop discovery artifacts as tar.gz
  archive-orphaned-state  Safely mv orphaned state dir (never deletes)
  repair-runtime          Replace pinned runtime from repo (no upgrade steps)
  diagnose                Classify partial upgrade state (read-only)
  request-reboot          Request reboot only when release-upgrade success evidence exists
  recover-lock            Recover stale lock metadata (never clears a live holder)
  recover-not-started     Demote false REBOOT_* when do-release-upgrade never ran
  recover-current-release-update
                          Verify current-release apt completed; resume without re-running it
  recover-resume-dispatch Recover stuck HOP_PRECHECK after illegal resume dispatch
                          (no apt / do-release-upgrade / reboot)
  service-install         Install systemd units (does not start upgrade)
  service-remove          Remove systemd units (COMPLETED / uninitialized only)
  help                    Show this help
  version                 Show version

Profiles:
  --execution-profile production|discovery   (default: production)
  --stop-after-os VERSION                    next LTS only (no skip); applied to plan
  --max-hops N                               mutually exclusive with --stop-after-os
  Discovery defaults to max-hops=1 and requires disposable VM ack.

Install safety (all required for real changes):
  --preflight PATH
  --execute
  --acknowledge-destructive-upgrade 'I_UNDERSTAND_THIS_OS_UPGRADE_IS_DESTRUCTIVE'
  discovery also requires:
  --acknowledge-disposable-discovery-vm 'I_UNDERSTAND_THIS_DISCOVERY_VM_MAY_BE_LOST'

Orphan archive:
  --acknowledge-orphan-archive 'I_UNDERSTAND_THE_ORPHANED_STATE_WILL_BE_ARCHIVED'

READY_WITH_WARNINGS additionally requires either:
  --accept-warning ID (repeatable)
  or --accept-all-warnings --approval-reference REF \
     --acknowledge-all-warnings 'I_ACCEPT_ALL_PREFLIGHT_WARNINGS'

Exit codes:
  0 success (query commands may return 0 even if state is BLOCKED)
  2 CLI/input error
  3 state/integrity/internal error
  10 warning acceptance required
  20 BLOCKED
  21 PAUSED
  22 RESUME_REQUIRED
  30 FAILED
  40 COMPLETED / Phase 1 no-op complete
  41 CHECKPOINT_REACHED (discovery hop complete; new preflight required)

Environment (tests only):
  DP_OS_UPGRADE_TEST_MODE=1
  DP_OS_UPGRADE_TEST_ROOT=/path/fake-root
  DP_OS_UPGRADE_COMMAND_PATH=/path/stubs
EOF
}

parse_global_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      check|plan|install|status|resume|continue|validate|pause|unpause|logs|report|export-artifacts|archive-orphaned-state|repair-runtime|diagnose|request-reboot|recover-lock|recover-not-started|recover-current-release-update|recover-resume-dispatch|service-install|service-remove|help|version)
        SUBCOMMAND="$1"; shift; break ;;
      -h|--help) SUBCOMMAND=help; shift; break ;;
      --version) SUBCOMMAND=version; shift; break ;;
      *)
        printf 'Unknown argument before subcommand: %s\n' "$1" >&2
        exit "$EXIT_CLI"
        ;;
    esac
  done
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --preflight) PREFLIGHT_PATH="${2:-}"; shift 2 ;;
      --config) CONFIG_PATH="${2:-}"; shift 2 ;;
      --execute) EXECUTE=1; shift ;;
      --acknowledge-destructive-upgrade) DESTRUCTIVE_ACK="${2:-}"; shift 2 ;;
      --accept-warning) OSU_ACCEPTED_WARNINGS="${OSU_ACCEPTED_WARNINGS} ${2:-}"; shift 2 ;;
      --accept-all-warnings) OSU_ACCEPT_ALL_WARNINGS=1; shift ;;
      --approval-reference) OSU_APPROVAL_REFERENCE="${2:-}"; shift 2 ;;
      --acknowledge-all-warnings) OSU_ALL_WARNINGS_ACK="${2:-}"; shift 2 ;;
      --package-source-mode) PKG_MODE_OVERRIDE="${2:-}"; shift 2 ;;
      --package-source-url) PKG_URL_OVERRIDE="${2:-}"; shift 2 ;;
      --snapshot-reference) SNAPSHOT_OVERRIDE="${2:-}"; shift 2 ;;
      --backup-reference) BACKUP_OVERRIDE="${2:-}"; shift 2 ;;
      --execution-profile) EXECUTION_PROFILE="${2:-}"; shift 2 ;;
      --stop-after-os) STOP_AFTER_OS="${2:-}"; shift 2 ;;
      --max-hops) MAX_HOPS="${2:-}"; shift 2 ;;
      --acknowledge-disposable-discovery-vm) DISCOVERY_ACK="${2:-}"; shift 2 ;;
      --acknowledge-orphan-archive) ORPHAN_ARCHIVE_ACK="${2:-}"; shift 2 ;;
      --output-dir) EXPORT_OUTPUT_DIR="${2:-}"; shift 2 ;;
      --keep-directory) EXPORT_KEEP_DIR=1; shift ;;
      --json) JSON_OUT=1; shift ;;
      --follow) FOLLOW=1; shift ;;
      --lines) LOG_LINES="${2:-50}"; shift 2 ;;
      --hop) LOG_HOP="${2:-}"; EXPORT_HOP="${2:-}"; shift 2 ;;
      --reason) PAUSE_REASON="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)
        printf 'Unknown option: %s\n' "$1" >&2
        exit "$EXIT_CLI"
        ;;
    esac
  done
}

cmd_version() {
  printf 'dp-os-upgrade-only.sh %s (schema %s)\n' "$OSU_SCRIPT_VERSION" "$OSU_SCHEMA_VERSION"
}

cmd_check() {
  [[ -n "$PREFLIGHT_PATH" ]] || osu_die_cli "--preflight is required for check"
  trap 'osu_cleanup_tmp' EXIT
  osu_prepare_preflight_input "$PREFLIGHT_PATH" || exit "$EXIT_INTEGRITY"
  osu_load_preflight_summary || exit "$EXIT_INTEGRITY"
  printf 'Preflight: %s\n' "$PF_ID"
  printf 'Overall: %s\n' "$PF_OVERALL"
  printf 'Recommended: %s\n' "$PF_RECOMMENDED"
  # PF_HOSTNAME is set by osu_load_preflight_summary (not ST_HOSTNAME).
  # shellcheck disable=SC2153
  printf 'Hostname: %s (current: %s)\n' "$PF_HOSTNAME" "$(osu_current_hostname)"
  printf 'OS: %s (%s)\n' "$PF_OS_VERSION" "$PF_OS_CODENAME"
  printf 'Phase1 hops: %s\n' "${PF_PHASE1_HOPS}"
  printf 'Package source: %s %s\n' "$PF_PACKAGE_SOURCE_MODE" "$(osu_redact_url "$PF_PACKAGE_SOURCE_URL")"
  printf 'Phase2 executed by this tool: false\n'

  local rc=0
  osu_gate_preflight_status || rc=$EXIT_BLOCKED
  if [[ "$rc" -eq 0 ]]; then
    osu_check_preflight_freshness || rc=$EXIT_BLOCKED
  fi
  if [[ "$rc" -eq 0 ]]; then
    osu_gate_identity_match || rc=$EXIT_BLOCKED
  fi
  if [[ "$rc" -eq 0 ]]; then
    osu_gate_recommended_action || rc=$EXIT_BLOCKED
  fi
  if [[ "$rc" -eq 0 ]]; then
    osu_note_snapshot_operator_responsibility
  fi
  if [[ "$PF_OVERALL" == "READY_WITH_WARNINGS" ]]; then
    if ! osu_validate_warning_acceptances; then
      printf '\nWarning acceptance required (exit 10). Use --accept-warning ID ...\n'
      osu_list_warning_ids | sed 's/^/  - /'
      rc=$EXIT_WARNINGS
    fi
  fi
  # Live check is read-only and must not create /opt/aelladata/os-upgrade
  if ! osu_live_precheck; then
    printf '\nLive precheck: FAIL (%s)\n' "${LIVE_PRECHECK_REASONS:-}"
    [[ "$rc" -eq 0 ]] && rc=$EXIT_BLOCKED
  else
    printf '\nLive precheck: PASS\n'
  fi
  printf '\ncheck complete (read-only; no OS changes)\n'
  exit "$rc"
}

cmd_plan() {
  [[ -n "$PREFLIGHT_PATH" ]] || osu_die_cli "--preflight is required for plan"
  if [[ -n "$STOP_AFTER_OS" && -n "$MAX_HOPS" ]]; then
    osu_die_cli "--stop-after-os and --max-hops are mutually exclusive"
  fi
  osu_prepare_preflight_input "$PREFLIGHT_PATH" || exit "$EXIT_INTEGRITY"
  osu_load_preflight_summary || exit "$EXIT_INTEGRITY"

  if [[ -n "$STOP_AFTER_OS" ]]; then
    osu_validate_stop_after_os "$PF_OS_VERSION" "$STOP_AFTER_OS" || exit "$EXIT_CLI"
  fi

  local full_hops effective_hops remaining_hops reboot_count=0 effective_count=0
  local expected_end="COMPLETED"
  full_hops="$(osu_plan_hops "$PF_OS_VERSION")" || true
  if printf '%s\n' "$full_hops" | grep -qx UNSUPPORTED; then
    osu_die_blocked "unsupported starting OS: $PF_OS_VERSION"
  fi
  effective_hops="$(osu_effective_plan_hops "$PF_OS_VERSION" "$STOP_AFTER_OS" "$MAX_HOPS")" || exit "$EXIT_CLI"
  if printf '%s\n' "$effective_hops" | grep -qx UNSUPPORTED; then
    osu_die_blocked "unsupported starting OS: $PF_OS_VERSION"
  fi
  effective_count="$(osu_count_hop_lines "$effective_hops")"
  reboot_count="$effective_count"
  remaining_hops="$(osu_remaining_plan_hops "$PF_OS_VERSION" "$effective_hops")"
  if [[ -n "$STOP_AFTER_OS" || -n "$MAX_HOPS" ]]; then
    if [[ "$(osu_count_hop_lines "$remaining_hops")" -gt 0 ]]; then
      expected_end="CHECKPOINT_REACHED"
    fi
  fi
  if [[ "$effective_count" -eq 0 ]]; then
    expected_end="COMPLETED"
  fi

  printf 'Phase 1 plan (read-only)\n'
  printf '========================\n'
  printf 'start_os: %s (%s)\n' "$PF_OS_VERSION" "$PF_OS_CODENAME"
  printf 'final_os: %s (%s)\n' "$POLICY_TARGET_OS_VERSION" "$POLICY_TARGET_OS_CODENAME"
  if [[ -n "$STOP_AFTER_OS" ]]; then
    printf 'stop_after_os: %s\n' "$STOP_AFTER_OS"
  fi
  if [[ -n "$MAX_HOPS" ]]; then
    printf 'max_hops: %s\n' "$MAX_HOPS"
  fi
  printf 'effective_hops: %s\n' "$effective_count"
  printf 'expected_reboots: %s\n' "$reboot_count"
  printf 'expected_end_state: %s\n' "$expected_end"
  printf 'recommended_action: %s\n' "$PF_RECOMMENDED"
  printf 'package_source_mode: %s\n' "$PF_PACKAGE_SOURCE_MODE"
  printf 'package_source_url: %s\n' "$(osu_redact_url "$PF_PACKAGE_SOURCE_URL")"
  printf 'snapshot_reference: %s\n' "${PF_SNAPSHOT_REF:-none}"
  printf 'backup_reference: %s\n' "${PF_BACKUP_REF:-none}"
  printf '\nEffective hops (this run):\n'
  if [[ -z "$effective_hops" ]]; then
    printf '  (none — already on target; Phase 1 no-op)\n'
  else
    local i=1 line
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      printf '  %d. %s\n' "$i" "$line"
      i=$((i+1))
    done <<< "$effective_hops"
  fi
  if [[ "$(osu_count_hop_lines "$remaining_hops")" -gt 0 ]]; then
    printf '\nRemaining hops (reference only; not executed this run):\n'
    i=1
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      printf '  %d. %s\n' "$i" "$line"
      i=$((i+1))
    done <<< "$remaining_hops"
  fi
  printf '\nExpected file changes (when install --execute):\n'
  printf '  /etc/apt/sources.list (official Ubuntu rewrite)\n'
  printf '  /etc/apt/sources.list.d/* third-party -> *.disabled-by-dp-os-upgrade\n'
  printf '  /etc/apt/apt.conf.d/99dp-os-upgrade-proxy (cache mode)\n'
  printf '  /opt/aelladata/os-upgrade/** state and hop artifacts\n'
  printf '  systemd units for resume\n'
  printf '\nWarning IDs requiring acceptance if READY_WITH_WARNINGS:\n'
  osu_list_warning_ids | sed 's/^/  - /' || printf '  (none)\n'
  printf '\nPhase 2 (DP bringup) is OUT OF SCOPE and will not run.\n'
  printf 'Next hop is not auto-executed after expected_end_state=%s.\n' "$expected_end"
}

cmd_install() {
  [[ -n "$PREFLIGHT_PATH" ]] || osu_die_cli "--preflight is required for install"

  # 1) Preflight BLOCKED gate is absolute first — before root/orphan/state/profile.
  osu_prepare_preflight_input "$PREFLIGHT_PATH" || exit "$EXIT_INTEGRITY"
  osu_load_preflight_summary || exit "$EXIT_INTEGRITY"
  if [[ "$PF_OVERALL" == "BLOCKED" ]]; then
    osu_gate_preflight_status || true
    local id
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      printf 'blocker: %s\n' "$id" >&2
    done < <(osu_list_blocker_ids)
    osu_log ERROR "install refused: preflight overall_status=BLOCKED (no changes made; cannot override)"
    exit "$EXIT_BLOCKED"
  fi

  if [[ "$EXECUTE" -ne 1 ]]; then
    osu_log ERROR "install refused: --execute not provided (no changes made)"
    exit "$EXIT_CLI"
  fi
  if [[ "$DESTRUCTIVE_ACK" != "$POLICY_DESTRUCTIVE_ACK_PHRASE" ]]; then
    osu_log ERROR "install refused: destructive acknowledgment phrase mismatch (no changes made)"
    exit "$EXIT_CLI"
  fi
  # Resolve execution profile early (default production)
  if [[ -z "$EXECUTION_PROFILE" ]]; then
    EXECUTION_PROFILE="${POLICY_DEFAULT_EXECUTION_PROFILE:-production}"
  fi
  case "$EXECUTION_PROFILE" in
    production|discovery) ;;
    *) osu_die_cli "invalid --execution-profile: $EXECUTION_PROFILE" ;;
  esac
  OSU_EXECUTION_PROFILE="$EXECUTION_PROFILE"
  OSU_DISCOVERY_ACK="$DISCOVERY_ACK"
  if [[ -n "$STOP_AFTER_OS" && -n "$MAX_HOPS" ]]; then
    osu_die_cli "--stop-after-os and --max-hops are mutually exclusive"
  fi
  if [[ "$EXECUTION_PROFILE" == "discovery" && -z "$STOP_AFTER_OS" && -z "$MAX_HOPS" ]]; then
    MAX_HOPS="${POLICY_DISCOVERY_DEFAULT_MAX_HOPS:-1}"
  fi
  osu_require_root_for_mutate || exit "$EXIT_CLI"

  osu_gate_preflight_status || exit "$EXIT_BLOCKED"

  if [[ "$PF_OVERALL" == "READY_WITH_WARNINGS" ]]; then
    if ! osu_validate_warning_acceptances; then
      printf 'Unaccepted warning IDs:\n' >&2
      osu_list_warning_ids | sed 's/^/  - /' >&2
      exit "$EXIT_WARNINGS"
    fi
  else
    OSU_WARNING_ACCEPTANCE_JSON='[]'
  fi

  # Optional CLI overrides must match preflight
  local mode url
  mode="${PKG_MODE_OVERRIDE:-$PF_PACKAGE_SOURCE_MODE}"
  url="${PKG_URL_OVERRIDE:-$PF_PACKAGE_SOURCE_URL}"
  osu_gate_package_source_match "${PKG_MODE_OVERRIDE}" "${PKG_URL_OVERRIDE}" || exit "$EXIT_BLOCKED"
  # Snapshot notes are external; their values cannot gate this upgrade.
  # A CLI note differing from a preflight note proves nothing about
  # hypervisor snapshot existence or restore safety.

  # Profile must match preflight (default production on legacy fixtures)
  if [[ -z "${PF_EXECUTION_PROFILE:-}" ]]; then
    PF_EXECUTION_PROFILE="production"
  fi
  osu_gate_execution_profile_match "$EXECUTION_PROFILE" || exit "$EXIT_BLOCKED"
  osu_gate_discovery_ack || exit "$EXIT_CLI"

  if [[ -n "$STOP_AFTER_OS" ]]; then
    osu_validate_stop_after_os "$PF_OS_VERSION" "$STOP_AFTER_OS" || exit "$EXIT_CLI"
  fi
  # Discovery must not auto-run full chain without hop limit
  if [[ "$EXECUTION_PROFILE" == "discovery" && -z "$STOP_AFTER_OS" && -z "$MAX_HOPS" ]]; then
    MAX_HOPS="${POLICY_DISCOVERY_DEFAULT_MAX_HOPS:-1}"
  fi
  if [[ "$EXECUTION_PROFILE" == "discovery" && -n "$STOP_AFTER_OS" ]]; then
    local next
    next="$(osu_next_lts_version "$PF_OS_VERSION")" || true
    if [[ -n "$next" && "$STOP_AFTER_OS" != "$next" ]]; then
      osu_die_cli "discovery refuses multi-hop stop-after-os=${STOP_AFTER_OS}; next hop is ${next}. Use max-hops=1 / stop-after-os=${next} or continue after checkpoint."
    fi
  fi

  osu_check_preflight_freshness || exit "$EXIT_BLOCKED"
  osu_gate_identity_match || exit "$EXIT_BLOCKED"
  osu_gate_recommended_action || exit "$EXIT_BLOCKED"
  osu_note_snapshot_operator_responsibility

  if [[ "$PF_RECOMMENDED" == "RUN_PHASE2" ]]; then
    osu_die_blocked "Phase 2 only — this orchestrator will not run Phase 2"
  fi

  if ! osu_is_supported_os "$PF_OS_VERSION"; then
    osu_die_blocked "unsupported OS: $PF_OS_VERSION"
  fi

  # 2) Orphan / existing-state gates only after preflight passed
  if osu_detect_orphaned_state; then
    osu_die_integrity "orphaned upgrade evidence detected without valid state.json — recovery required (use archive-orphaned-state)"
  fi

  if [[ -f "$(osu_state_path)" ]]; then
    if ! osu_verify_state_checksum; then
      osu_die_integrity "existing state checksum mismatch — refusing fresh init"
    fi
    local cur
    cur="$(osu_json_get "$(osu_state_path)" current_state)"
    case "$cur" in
      COMPLETED|NEW|"") ;;
      CHECKPOINT_REACHED)
        osu_log ERROR "existing state=CHECKPOINT_REACHED — use continue with a new --preflight"
        exit "$EXIT_CLI"
        ;;
      *)
        osu_log ERROR "existing state=$cur — use resume, not install"
        exit "$EXIT_CLI"
        ;;
    esac
  fi

  # 3) Live precheck before any durable state directory creation
  if ! osu_live_precheck; then
    osu_log ERROR "live precheck failed: ${LIVE_PRECHECK_REASONS}"
    exit "$EXIT_BLOCKED"
  fi

  # 4) First durable writes — only after all gates passed
  mkdir -p "$OSU_STATE_DIR"/{logs,reports,hops,runtime}
  chmod 0700 "$OSU_STATE_DIR"
  if ! osu_acquire_lock; then
    exit "$EXIT_INTEGRITY"
  fi
  trap 'osu_release_lock; osu_cleanup_tmp' EXIT
  # The successful install precheck ran before STATE_DIR existed. Promote its
  # audit evidence only now, after all no-mutation safety gates have passed.
  if ! osu_persist_live_precheck_evidence "$OSU_STATE_DIR"; then
    osu_log ERROR "failed to persist live precheck evidence"
    exit "$EXIT_INTEGRITY"
  fi

  local hops_text total effective_hops effective_total
  hops_text="$(osu_plan_hops "$PF_OS_VERSION")"
  total="$(osu_hop_count "$PF_OS_VERSION")"
  effective_hops="$(osu_effective_plan_hops "$PF_OS_VERSION" "$STOP_AFTER_OS" "$MAX_HOPS")" || exit "$EXIT_CLI"
  effective_total="$(osu_count_hop_lines "$effective_hops")"

  ST_REVISION=0
  ST_STATE=NEW
  ST_HOSTNAME="$PF_HOSTNAME"
  ST_SOURCE_OS="$PF_OS_VERSION"
  ST_SOURCE_CODENAME="$PF_OS_CODENAME"
  ST_CURRENT_OS="$PF_OS_VERSION"
  ST_CURRENT_CODENAME="$PF_OS_CODENAME"
  ST_FINAL_TARGET_OS="$POLICY_TARGET_OS_VERSION"
  ST_FINAL_TARGET_CODENAME="$POLICY_TARGET_OS_CODENAME"
  ST_CURRENT_HOP=0
  ST_TOTAL_HOPS="$total"
  ST_ATTEMPT=1
  ST_PREFLIGHT_ID="$PF_ID"
  ST_PREFLIGHT_COMPLETED_AT="$PF_COMPLETED_AT"
  ST_SNAPSHOT_REF="$PF_SNAPSHOT_REF"
  ST_BACKUP_REF="$PF_BACKUP_REF"
  ST_PKG_MODE="$mode"
  ST_PKG_URL="$url"
  ST_WARNING_ACCEPTANCES="$OSU_WARNING_ACCEPTANCE_JSON"
  ST_LAST_STEP="install_start"
  ST_LAST_ERROR=""
  ST_BLOCK_REASON=""
  ST_RETRYABLE=false
  ST_RETRY_COUNT=0
  ST_PAUSE_REQUESTED=false
  ST_CREATED_AT="$(osu_utc_now)"
  ST_TARGET_OS=""
  ST_TARGET_CODENAME=""
  ST_EXECUTION_PROFILE="$EXECUTION_PROFILE"
  ST_STOP_AFTER_OS="$STOP_AFTER_OS"
  ST_MAX_HOPS="$MAX_HOPS"
  ST_DISCOVERY_ACKNOWLEDGED="$( [[ "$EXECUTION_PROFILE" == "discovery" && "$DISCOVERY_ACK" == "$POLICY_DISCOVERY_DISPOSABLE_VM_ACK_PHRASE" ]] && echo true || echo false )"
  ST_SNAPSHOT_REQUIRED=false
  ST_SNAPSHOT_PRESENT=false # No code-verified off-host snapshot fact exists.
  ST_CURRENT_RUN_HOP_LIMIT="${MAX_HOPS:-$effective_total}"
  ST_CHECKPOINT_REASON=""
  ST_NEW_PREFLIGHT_REQUIRED=false
  ST_ARTIFACT_CAPTURE_STATUS="pending"
  ST_ARTIFACT_EXPORT_STATUS=""
  ST_HOPS_THIS_RUN=0
  ST_NEXT_ACTION="RUN_OS_UPGRADE"
  OSU_STOP_AFTER_OS="$STOP_AFTER_OS"
  OSU_MAX_HOPS="$MAX_HOPS"

  osu_write_effective_config "${OSU_STATE_DIR}/policy-effective.conf"
  mkdir -p "${OSU_STATE_DIR}/approvals"
  local discovery_ok=false
  if [[ "$EXECUTION_PROFILE" == "discovery" && "$DISCOVERY_ACK" == "$POLICY_DISCOVERY_DISPOSABLE_VM_ACK_PHRASE" ]]; then
    discovery_ok=true
  elif [[ "$EXECUTION_PROFILE" != "discovery" ]]; then
    discovery_ok=false
  fi
  # Durable execute authorization (survives pinned-runtime re-source / systemd resume)
  osu_write_operator_approval true "$discovery_ok" "$PF_ID" "$OSU_WARNING_ACCEPTANCE_JSON" || {
    osu_log ERROR "failed to persist operator approval"
    exit "$EXIT_INTEGRITY"
  }

  osu_write_state_json "$(osu_build_state_json)"
  osu_transition_state PREFLIGHT_ACCEPTED "preflight_accepted"

  osu_pin_runtime
  osu_capture_original_system_state
  osu_write_source_plan "$mode" "$url" "$PF_OS_CODENAME"

  # Copy preflight reference (do not modify original)
  mkdir -p "${OSU_STATE_DIR}/preflight-reference"
  cp -a "${OSU_PREFLIGHT_ROOT}/preflight-summary.json" "${OSU_STATE_DIR}/preflight-reference/"
  cp -a "${OSU_PREFLIGHT_ROOT}/checks.tsv" "${OSU_STATE_DIR}/preflight-reference/" 2>/dev/null || true

  osu_transition_state INITIALIZED "initialized"

  if [[ "$total" -eq 0 ]]; then
    # Already on 24.04 — validate and COMPLETED; no Phase 2
    if osu_post_hop_validate "$POLICY_TARGET_OS_VERSION" "$POLICY_TARGET_OS_CODENAME"; then
      osu_transition_state COMPLETED "phase1_noop_complete"
      osu_generate_reports
      printf 'Phase 1 OS upgrade completed.\nUbuntu 24.04 validation passed.\nDP bringup has not been executed.\n'
      exit "$EXIT_COMPLETED"
    else
      osu_set_failed "noop_validation_failed"
      exit "$EXIT_FAILED"
    fi
  fi

  # Install systemd units into test or real system (service-install logic)
  _install_systemd_units || osu_log WARN "systemd unit install skipped/failed"

  # Hand off to runner (release CLI lock so runner can acquire).
  # Runner loads durable authorization from state/approval — do not rely on env alone.
  local runner="${OSU_STATE_DIR}/runtime/dp-os-upgrade-runner.sh"
  export DP_OS_UPGRADE_TEST_MODE DP_OS_UPGRADE_TEST_ROOT DP_OS_UPGRADE_COMMAND_PATH
  export DP_OS_UPGRADE_SIMULATE_ROOT DP_OS_UPGRADE_FAKE_HOSTNAME DP_OS_UPGRADE_FAKE_OS_VERSION
  export DP_OS_UPGRADE_FAKE_OS_CODENAME DP_OS_UPGRADE_FAKE_DP_VERSION DP_OS_UPGRADE_HTTP_OK_ALL
  export DP_OS_UPGRADE_FAKE_NTP DP_OS_UPGRADE_FAKE_APT_LOCK
  export OSU_ROOT
  osu_release_lock
  trap 'osu_cleanup_tmp' EXIT
  bash "$runner" --from-install
}

_install_systemd_units() {
  local unitdir
  unitdir="$(osu_hostpath /etc/systemd/system)"
  mkdir -p "$unitdir"
  local src="${OSU_ROOT}/systemd"
  [[ -d "$src" ]] || return 1
  cp -a "$src/dp-os-upgrade.service" "$unitdir/" 2>/dev/null || return 1
  cp -a "$src/dp-os-upgrade-resume.service" "$unitdir/" 2>/dev/null || true
  cp -a "$src/dp-os-upgrade-resume.timer" "$unitdir/" 2>/dev/null || true
  # Rewrite ExecStart to pinned runtime
  local runtime_runner="${POLICY_STATE_DIR}/runtime/dp-os-upgrade-runner.sh"
  if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
    # Keep unit text pointing at production path; runner invoked directly in tests
    :
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable dp-os-upgrade.service 2>/dev/null || true
    if [[ "${POLICY_AUTO_RETRY_ENABLED}" == "true" ]]; then
      systemctl enable dp-os-upgrade-resume.timer 2>/dev/null || true
    else
      systemctl disable dp-os-upgrade-resume.timer 2>/dev/null || true
      osu_log INFO "DP_OS_RETRY_TIMER=NOT_ENABLED policy=AUTO_RETRY_ENABLED=false"
    fi
  fi
  return 0
}

cmd_status() {
  if [[ ! -f "$(osu_state_path)" ]]; then
    if osu_detect_orphaned_state; then
      printf 'status: ORPHANED_STATE / RECOVERY_REQUIRED\n'
      [[ "$JSON_OUT" -eq 1 ]] && printf '{"current_state":"ORPHANED_STATE"}\n'
      exit 0
    fi
    printf 'status: NO_STATE\n'
    [[ "$JSON_OUT" -eq 1 ]] && printf '{"current_state":"NO_STATE"}\n'
    exit 0
  fi
  if ! osu_verify_state_checksum; then
    printf 'status: STATE_CHECKSUM_MISMATCH\n'
    exit "$EXIT_INTEGRITY"
  fi
  if [[ "$JSON_OUT" -eq 1 ]]; then
    cat "$(osu_state_path)"
    exit 0
  fi
  osu_load_state_into_vars || exit "$EXIT_INTEGRITY"
  printf 'current_state: %s\n' "$ST_STATE"
  printf 'hostname: %s\n' "$ST_HOSTNAME"
  printf 'source_os: %s (%s)\n' "$ST_SOURCE_OS" "$ST_SOURCE_CODENAME"
  printf 'current_os: %s (%s)\n' "$ST_CURRENT_OS" "$ST_CURRENT_CODENAME"
  printf 'hop_target: %s (%s)\n' "$ST_TARGET_OS" "$ST_TARGET_CODENAME"
  printf 'hop: %s / %s\n' "$ST_CURRENT_HOP" "$ST_TOTAL_HOPS"
  printf 'attempt: %s\n' "$ST_ATTEMPT"
  printf 'retryable: %s retry_count: %s\n' "$ST_RETRYABLE" "$ST_RETRY_COUNT"
  printf 'pause_requested: %s\n' "$ST_PAUSE_REQUESTED"
  printf 'block_reason: %s\n' "${ST_BLOCK_REASON:-none}"
  printf 'last_error: %s\n' "${ST_LAST_ERROR:-none}"
  printf 'execute_authorized: %s\n' "${ST_EXECUTE_AUTHORIZED:-false}"
  printf 'phase2_executed: false\n'
  case "$ST_STATE" in
    PAUSED) exit 0 ;;
    BLOCKED) exit 0 ;;
    FAILED) exit 0 ;;
    COMPLETED) exit 0 ;;
    *) exit 0 ;;
  esac
}

cmd_resume() {
  osu_require_root_for_mutate || exit "$EXIT_CLI"
  [[ -f "$(osu_state_path)" ]] || osu_die_cli "no state to resume"
  osu_verify_state_checksum || osu_die_integrity "state checksum mismatch"
  osu_load_state_into_vars || exit "$EXIT_INTEGRITY"
  if osu_pause_active || [[ "$ST_STATE" == "PAUSED" ]]; then
    osu_log ERROR "paused — run unpause before resume"
    exit "$EXIT_PAUSED"
  fi
  case "$ST_STATE" in
    COMPLETED)
      printf 'already COMPLETED — Phase 2 was not executed\n'
      exit "$EXIT_COMPLETED"
      ;;
    CHECKPOINT_REACHED)
      if [[ -n "$PREFLIGHT_PATH" ]]; then
        osu_log ERROR "CHECKPOINT_REACHED with --preflight: use continue subcommand"
        exit "$EXIT_CLI"
      fi
      printf 'CHECKPOINT_REACHED — new collector/preflight required before next hop; Phase 2 not evaluated\n'
      exit "${EXIT_CHECKPOINT:-41}"
      ;;
    FAILED)
      osu_log ERROR "state FAILED — automatic resume refused"
      exit "$EXIT_FAILED"
      ;;
    BLOCKED)
      if [[ "$ST_RETRYABLE" != "true" ]]; then
        osu_log ERROR "non-retryable BLOCKED — operator action required"
        exit "$EXIT_BLOCKED"
      fi
      ;;
  esac

  # Sticky false-reboot / recover-not-started path requires a fresh preflight archive.
  if [[ "${ST_NEW_PREFLIGHT_REQUIRED:-false}" == "true" || "$ST_STATE" == "RESUME_REQUIRED" ]]; then
    if [[ -z "$PREFLIGHT_PATH" ]]; then
      osu_die_cli "resume requires --preflight <new-preflight.tar.gz> (new_preflight_required=${ST_NEW_PREFLIGHT_REQUIRED:-false}, state=${ST_STATE})"
    fi
  fi

  if [[ -n "$PREFLIGHT_PATH" ]]; then
    if [[ "${EXECUTE:-0}" -ne 1 ]]; then
      osu_log ERROR "resume with --preflight refused: --execute not provided (no changes made)"
      exit "$EXIT_CLI"
    fi
    if [[ "$DESTRUCTIVE_ACK" != "$POLICY_DESTRUCTIVE_ACK_PHRASE" ]]; then
      osu_die_cli "resume with --preflight requires --acknowledge-destructive-upgrade '${POLICY_DESTRUCTIVE_ACK_PHRASE}'"
    fi
    if [[ -z "$EXECUTION_PROFILE" ]]; then
      EXECUTION_PROFILE="${ST_EXECUTION_PROFILE:-production}"
    fi
    OSU_EXECUTION_PROFILE="$EXECUTION_PROFILE"
    OSU_DISCOVERY_ACK="$DISCOVERY_ACK"
    osu_gate_discovery_ack || exit "$EXIT_CLI"
    osu_prepare_preflight_input "$PREFLIGHT_PATH" || exit "$EXIT_INTEGRITY"
    osu_load_preflight_summary || exit "$EXIT_INTEGRITY"
    osu_gate_execution_profile_match "$EXECUTION_PROFILE" || exit "$EXIT_BLOCKED"
    osu_check_preflight_freshness || exit "$EXIT_BLOCKED"
    osu_gate_preflight_status || exit "$EXIT_BLOCKED"
    osu_gate_identity_match || exit "$EXIT_BLOCKED"
    local cur_os
    cur_os="$(osu_current_os_version)"
    if [[ "$PF_OS_VERSION" != "$cur_os" ]]; then
      osu_die_blocked "new preflight OS ${PF_OS_VERSION} does not match current OS ${cur_os}"
    fi
    if [[ -n "${ST_PREFLIGHT_ID:-}" && "$PF_ID" == "$ST_PREFLIGHT_ID" ]]; then
      osu_die_blocked "resume --preflight requires a new preflight_id (got same ${PF_ID})"
    fi
    osu_gate_recommended_action || exit "$EXIT_BLOCKED"
    osu_note_snapshot_operator_responsibility
    if [[ "$PF_OVERALL" == "READY_WITH_WARNINGS" ]]; then
      if ! osu_validate_warning_acceptances; then
        osu_log ERROR "resume --preflight: warning acceptance required"
        exit "${EXIT_WARNINGS:-10}"
      fi
      ST_WARNING_ACCEPTANCES="${OSU_WARNING_ACCEPTANCE_JSON:-[]}"
    elif [[ -n "${OSU_ACCEPTED_WARNINGS// /}" || "$OSU_ACCEPT_ALL_WARNINGS" -eq 1 ]]; then
      # Operator passed acceptances — persist even if overall flipped to READY
      if osu_validate_warning_acceptances 2>/dev/null; then
        if [[ "${OSU_WARNING_ACCEPTANCE_JSON:-[]}" != "[]" ]]; then
          ST_WARNING_ACCEPTANCES="$OSU_WARNING_ACCEPTANCE_JSON"
        fi
      fi
    fi
    # Preserve prior durable acceptances when new preflight is READY with none required
    if [[ -z "${ST_WARNING_ACCEPTANCES:-}" || "${ST_WARNING_ACCEPTANCES}" == "null" ]]; then
      ST_WARNING_ACCEPTANCES='[]'
    fi
    ST_PREFLIGHT_ID="$PF_ID"
    ST_PREFLIGHT_COMPLETED_AT="$PF_COMPLETED_AT"
    ST_NEW_PREFLIGHT_REQUIRED=false
    if [[ "${ST_LAST_STEP:-}" == "current_release_updated" ]]; then
      ST_NEXT_ACTION="RUN_RELEASE_UPGRADE"
    else
      ST_NEXT_ACTION="RUN_OS_UPGRADE"
    fi
    ST_EXECUTION_PROFILE="$EXECUTION_PROFILE"
    mkdir -p "${OSU_STATE_DIR}/preflight-reference"
    cp -a "${OSU_PREFLIGHT_ROOT}/preflight-summary.json" "${OSU_STATE_DIR}/preflight-reference/"
    local discovery_ok=false
    if [[ "$EXECUTION_PROFILE" == "discovery" && "$DISCOVERY_ACK" == "$POLICY_DISCOVERY_DISPOSABLE_VM_ACK_PHRASE" ]]; then
      discovery_ok=true
    fi
    osu_write_operator_approval true "$discovery_ok" "$PF_ID" "${ST_WARNING_ACCEPTANCES:-[]}" || {
      osu_log ERROR "failed to persist resume operator approval"
      exit "$EXIT_INTEGRITY"
    }
    # Keep last_successful_step across resume when recovering mid-hop
    local keep_step="${ST_LAST_STEP:-}"
    if [[ "$ST_STATE" == "RESUME_REQUIRED" || "$ST_STATE" == "REBOOT_REQUIRED" || "$ST_STATE" == "REBOOT_REQUESTED" ]]; then
      osu_transition_state HOP_PRECHECK "resume_with_new_preflight" || {
        ST_STATE=HOP_PRECHECK
        osu_write_state_json "$(osu_build_state_json)" || true
      }
    fi
    if [[ "$keep_step" == "current_release_updated" ]]; then
      ST_LAST_STEP="current_release_updated"
      ST_NEXT_ACTION="RUN_RELEASE_UPGRADE"
    elif [[ -z "${ST_LAST_STEP:-}" || "${ST_LAST_STEP}" == "resume_with_new_preflight" ]]; then
      ST_LAST_STEP="${keep_step:-before_release_upgrade}"
    fi
    osu_write_state_json "$(osu_build_state_json)" || exit "$EXIT_INTEGRITY"
    osu_append_event "resume_preflight_accepted" "preflight_id=${PF_ID};warnings=$(printf '%s' "${ST_WARNING_ACCEPTANCES:-[]}" | wc -c)"
  fi

  osu_verify_runtime || { osu_set_blocked "runtime_checksum_mismatch" false; exit "$EXIT_BLOCKED"; }

  # Authorize without misleading ERROR when an explicit resume re-approval will rewrite approval.
  local auth_status
  auth_status="$(osu_probe_execute_authorization)" || true
  if [[ "$auth_status" == "OK" ]]; then
    OSU_EXECUTE=1
  else
    case "$auth_status" in
      APPROVAL_CHECKSUM_MISMATCH|APPROVAL_SHA_MISMATCH|APPROVAL_MISSING|STATE_NOT_AUTHORIZED|DESTRUCTIVE_ACK_MISSING|DISCOVERY_ACK_MISSING|APPROVAL_FIELD_MISMATCH)
        if [[ "${EXECUTE:-0}" -ne 1 ]]; then
          osu_die_integrity "resume refused: ${auth_status} — re-run with --execute and destructive ack to re-authorize (fail closed)"
        fi
        if [[ "$DESTRUCTIVE_ACK" != "$POLICY_DESTRUCTIVE_ACK_PHRASE" ]]; then
          osu_die_cli "resume re-authorization requires --acknowledge-destructive-upgrade '${POLICY_DESTRUCTIVE_ACK_PHRASE}'"
        fi
        local discovery_ok=false
        if [[ "${ST_EXECUTION_PROFILE:-production}" == "discovery" ]]; then
          if [[ "$DISCOVERY_ACK" != "$POLICY_DISCOVERY_DISPOSABLE_VM_ACK_PHRASE" ]]; then
            osu_die_cli "discovery resume re-authorization requires --acknowledge-disposable-discovery-vm '${POLICY_DISCOVERY_DISPOSABLE_VM_ACK_PHRASE}'"
          fi
          discovery_ok=true
        fi
        osu_reauthorize_execute_for_resume "$discovery_ok" || osu_die_integrity "resume refused: re-authorization failed"
        ;;
      *)
        osu_apply_execute_authorization || osu_die_integrity "resume refused: durable execute authorization invalid (${auth_status})"
        ;;
    esac
  fi

  # Validate under a short-lived lock, then release so the runner owns the lock
  # (same handoff pattern as install — avoids CLI/runner self-deadlock).
  if ! osu_acquire_lock; then exit "$EXIT_INTEGRITY"; fi
  export DP_OS_UPGRADE_TEST_MODE DP_OS_UPGRADE_TEST_ROOT DP_OS_UPGRADE_COMMAND_PATH
  export OSU_ROOT
  local runner="${OSU_STATE_DIR}/runtime/dp-os-upgrade-runner.sh"
  [[ -f "$runner" ]] || { osu_release_lock; osu_die_integrity "pinned runner missing — run repair-runtime"; }
  osu_release_lock
  trap 'osu_cleanup_tmp' EXIT
  bash "$runner" --resume
}

cmd_validate() {
  local osver code expected_ver expected_code have_state=0
  if [[ -f "$(osu_state_path)" ]]; then
    osu_verify_state_checksum || exit "$EXIT_INTEGRITY"
    osu_load_state_into_vars || exit "$EXIT_INTEGRITY"
    have_state=1
  fi
  osver="$(osu_current_os_version)"
  code="$(osu_current_os_codename)"
  printf 'current_os: %s (%s)\n' "$osver" "$code"
  printf 'current_state: %s\n' "${ST_STATE:-NO_STATE}"
  if [[ -d "$(osu_hostpath /opt/aelladata)" ]]; then
    printf 'aelladata: present\n'
  else
    printf 'aelladata: MISSING\n'
    printf 'validate: FAIL reason=aelladata_missing\n'
    exit "$EXIT_FAILED"
  fi
  if [[ "$have_state" -eq 0 ]]; then
    printf 'validate: OK (read-only, no durable state)\n'
    exit 0
  fi

  case "${ST_STATE:-}" in
    HOP_VALIDATING|RESUMED|HOP_COMPLETED)
      expected_ver="${ST_TARGET_OS:-}"
      expected_code="${ST_TARGET_CODENAME:-}"
      if [[ -z "$expected_ver" ]]; then
        printf 'validate: FAIL reason=missing_hop_target state=%s\n' "$ST_STATE"
        exit "$EXIT_FAILED"
      fi
      if [[ "$osver" != "$expected_ver" ]]; then
        printf 'validate: FAIL reason=os_mismatch current=%s expected=%s state=%s\n' \
          "$osver" "$expected_ver" "$ST_STATE"
        exit "$EXIT_FAILED"
      fi
      if [[ -n "$expected_code" && "$code" != "$expected_code" ]]; then
        printf 'validate: FAIL reason=codename_mismatch current=%s expected=%s state=%s\n' \
          "$code" "$expected_code" "$ST_STATE"
        exit "$EXIT_FAILED"
      fi
      if ! osu_post_hop_validate "$expected_ver" "$expected_code"; then
        printf 'validate: FAIL reason=post_hop_validate state=%s current=%s expected=%s\n' \
          "$ST_STATE" "$osver" "$expected_ver"
        exit "$EXIT_FAILED"
      fi
      ;;
    COMPLETED)
      expected_ver="${ST_FINAL_TARGET_OS:-$POLICY_TARGET_OS_VERSION}"
      expected_code="${ST_FINAL_TARGET_CODENAME:-$POLICY_TARGET_OS_CODENAME}"
      if [[ "$osver" != "$expected_ver" ]]; then
        printf 'validate: FAIL reason=os_mismatch current=%s expected=%s state=COMPLETED\n' \
          "$osver" "$expected_ver"
        exit "$EXIT_FAILED"
      fi
      if [[ -n "$expected_code" && "$code" != "$expected_code" ]]; then
        printf 'validate: FAIL reason=codename_mismatch current=%s expected=%s state=COMPLETED\n' \
          "$code" "$expected_code"
        exit "$EXIT_FAILED"
      fi
      if ! osu_post_hop_validate "$expected_ver" "$expected_code"; then
        printf 'validate: FAIL reason=post_hop_validate state=COMPLETED current=%s expected=%s\n' \
          "$osver" "$expected_ver"
        exit "$EXIT_FAILED"
      fi
      ;;
  esac
  printf 'validate: OK (read-only)\n'
}

cmd_pause() {
  mkdir -p "$OSU_STATE_DIR"
  osu_request_pause "${PAUSE_REASON:-operator_request}"
  if [[ -f "$(osu_state_path)" ]]; then
    osu_load_state_into_vars || true
    ST_PAUSE_REQUESTED=true
    ST_PAUSE_REASON="${PAUSE_REASON:-operator_request}"
    osu_write_state_json "$(osu_build_state_json)" || true
  fi
  printf 'pause requested — will stop at next safe boundary (apt/dpkg/do-release-upgrade not killed)\n'
}

cmd_unpause() {
  osu_clear_pause
  if [[ -f "$(osu_state_path)" ]]; then
    osu_load_state_into_vars || true
    if [[ "$ST_STATE" == "PAUSED" ]]; then
      # Move to resumable prior-ish state
      ST_PAUSE_REQUESTED=false
      osu_transition_state RESUMED "unpaused" || {
        ST_STATE=RESUMED
        osu_write_state_json "$(osu_build_state_json)" || true
      }
    else
      ST_PAUSE_REQUESTED=false
      osu_write_state_json "$(osu_build_state_json)" || true
    fi
  fi
  printf 'unpaused — run resume to continue\n'
}

cmd_logs() {
  local lf="${OSU_LOG_FILE}"
  if [[ -n "$LOG_HOP" ]]; then
    local hd
    hd="$(find "${OSU_STATE_DIR}/hops" -maxdepth 1 -type d -name "hop-$(printf '%02d' "$LOG_HOP")-*" 2>/dev/null | head -1 || true)"
    if [[ -n "$hd" && -f "${hd}/commands.tsv" ]]; then
      lf="${hd}/commands.tsv"
    fi
  fi
  if [[ ! -f "$lf" ]]; then
    printf 'no logs yet at %s\n' "$lf"
    exit 0
  fi
  if [[ "$FOLLOW" -eq 1 ]]; then
    tail -n "$LOG_LINES" -f "$lf"
  else
    tail -n "$LOG_LINES" "$lf"
  fi
}

cmd_report() {
  if [[ -f "$(osu_state_path)" ]]; then
    osu_load_state_into_vars || true
  fi
  osu_generate_reports
  printf 'reports written under %s/reports\n' "$OSU_STATE_DIR"
}


cmd_continue() {
  # Continue after CHECKPOINT_REACHED with a fresh preflight for the next hop.
  [[ -n "$PREFLIGHT_PATH" ]] || osu_die_cli "--preflight is required for continue"
  osu_require_root_for_mutate || exit "$EXIT_CLI"
  [[ -f "$(osu_state_path)" ]] || osu_die_cli "no state to continue"
  osu_verify_state_checksum || osu_die_integrity "state checksum mismatch"
  osu_load_state_into_vars || exit "$EXIT_INTEGRITY"
  if [[ "$ST_STATE" != "CHECKPOINT_REACHED" ]]; then
    osu_die_cli "continue requires CHECKPOINT_REACHED (current=${ST_STATE})"
  fi
  if [[ "$EXECUTE" -ne 1 ]]; then
    osu_log ERROR "continue refused: --execute not provided (no changes made)"
    exit "$EXIT_CLI"
  fi
  if [[ "$DESTRUCTIVE_ACK" != "$POLICY_DESTRUCTIVE_ACK_PHRASE" ]]; then
    osu_log ERROR "continue refused: destructive acknowledgment phrase mismatch"
    exit "$EXIT_CLI"
  fi
  if [[ -z "$EXECUTION_PROFILE" ]]; then
    EXECUTION_PROFILE="${ST_EXECUTION_PROFILE:-production}"
  fi
  OSU_EXECUTION_PROFILE="$EXECUTION_PROFILE"
  OSU_DISCOVERY_ACK="$DISCOVERY_ACK"
  osu_gate_discovery_ack || exit "$EXIT_CLI"

  osu_prepare_preflight_input "$PREFLIGHT_PATH" || exit "$EXIT_INTEGRITY"
  osu_load_preflight_summary || exit "$EXIT_INTEGRITY"
  osu_gate_execution_profile_match "$EXECUTION_PROFILE" || exit "$EXIT_BLOCKED"
  osu_check_preflight_freshness || exit "$EXIT_BLOCKED"
  osu_gate_preflight_status || exit "$EXIT_BLOCKED"
  osu_gate_identity_match || exit "$EXIT_BLOCKED"
  # New preflight must match current OS after checkpoint
  local cur
  cur="$(osu_current_os_version)"
  if [[ "$PF_OS_VERSION" != "$cur" ]]; then
    osu_die_blocked "new preflight OS ${PF_OS_VERSION} does not match current OS ${cur}"
  fi
  if [[ "$PF_ID" == "$ST_PREFLIGHT_ID" ]]; then
    osu_die_blocked "continue requires a new preflight_id (got same ${PF_ID})"
  fi
  osu_gate_recommended_action || exit "$EXIT_BLOCKED"
  osu_note_snapshot_operator_responsibility

  if [[ -n "$STOP_AFTER_OS" && -n "$MAX_HOPS" ]]; then
    osu_die_cli "--stop-after-os and --max-hops are mutually exclusive"
  fi
  if [[ "$EXECUTION_PROFILE" == "discovery" && -z "$STOP_AFTER_OS" && -z "$MAX_HOPS" ]]; then
    MAX_HOPS="${POLICY_DISCOVERY_DEFAULT_MAX_HOPS:-1}"
  fi
  if [[ -n "$STOP_AFTER_OS" ]]; then
    osu_validate_stop_after_os "$cur" "$STOP_AFTER_OS" || exit "$EXIT_CLI"
  fi

  ST_PREFLIGHT_ID="$PF_ID"
  ST_PREFLIGHT_COMPLETED_AT="$PF_COMPLETED_AT"
  ST_STOP_AFTER_OS="$STOP_AFTER_OS"
  ST_MAX_HOPS="$MAX_HOPS"
  ST_CURRENT_RUN_HOP_LIMIT="${MAX_HOPS:-}"
  ST_HOPS_THIS_RUN=0
  ST_NEW_PREFLIGHT_REQUIRED=false
  ST_CHECKPOINT_REASON=""
  ST_NEXT_ACTION="RUN_OS_UPGRADE"
  ST_EXECUTION_PROFILE="$EXECUTION_PROFILE"
  mkdir -p "${OSU_STATE_DIR}/preflight-reference"
  cp -a "${OSU_PREFLIGHT_ROOT}/preflight-summary.json" "${OSU_STATE_DIR}/preflight-reference/"
  local discovery_ok=false
  if [[ "$EXECUTION_PROFILE" == "discovery" && "$DISCOVERY_ACK" == "$POLICY_DISCOVERY_DISPOSABLE_VM_ACK_PHRASE" ]]; then
    discovery_ok=true
  fi
  osu_write_operator_approval true "$discovery_ok" "$PF_ID" "${ST_WARNING_ACCEPTANCES:-[]}" || {
    osu_log ERROR "failed to persist continue operator approval"
    exit "$EXIT_INTEGRITY"
  }
  osu_transition_state INITIALIZED "continue_with_new_preflight" || {
    ST_STATE=INITIALIZED
    osu_write_state_json "$(osu_build_state_json)" || true
  }

  export DP_OS_UPGRADE_TEST_MODE DP_OS_UPGRADE_TEST_ROOT DP_OS_UPGRADE_COMMAND_PATH
  export DP_OS_UPGRADE_SIMULATE_ROOT DP_OS_UPGRADE_FAKE_HOSTNAME DP_OS_UPGRADE_FAKE_OS_VERSION
  export DP_OS_UPGRADE_FAKE_OS_CODENAME DP_OS_UPGRADE_FAKE_DP_VERSION DP_OS_UPGRADE_HTTP_OK_ALL
  export DP_OS_UPGRADE_FAKE_NTP DP_OS_UPGRADE_FAKE_APT_LOCK
  export OSU_ROOT
  bash "${OSU_STATE_DIR}/runtime/dp-os-upgrade-runner.sh" --from-install
}

cmd_repair_runtime() {
  osu_require_root_for_mutate || exit "$EXIT_CLI"
  [[ -f "$(osu_state_path)" ]] || osu_die_cli "no state — nothing to repair"
  osu_verify_state_checksum || osu_die_integrity "state checksum mismatch"
  if ! osu_acquire_lock; then exit "$EXIT_INTEGRITY"; fi
  trap 'osu_release_lock; osu_cleanup_tmp' EXIT
  osu_repair_runtime || exit "$EXIT_BLOCKED"
  printf 'runtime repaired under %s/runtime\n' "$OSU_STATE_DIR"
  printf 'OS upgrade steps were not executed.\n'
  printf 'Next: review diagnose/status, then resume if appropriate.\n'
}

cmd_diagnose() {
  if [[ ! -f "$(osu_state_path)" ]]; then
    if osu_detect_orphaned_state; then
      printf 'classification: BLOCKED\n'
      printf 'reason: orphaned_state_without_valid_state_json\n'
      printf 'recommended_action: operator_intervention\n'
      exit "$EXIT_BLOCKED"
    fi
    printf 'classification: NO_STATE\n'
    printf 'recommended_action: none\n'
    exit 0
  fi
  if ! osu_verify_state_checksum; then
    printf 'classification: BLOCKED\n'
    printf 'reason: state_checksum_mismatch\n'
    printf 'recommended_action: operator_intervention\n'
    exit "$EXIT_INTEGRITY"
  fi
  osu_load_state_into_vars || exit "$EXIT_INTEGRITY"
  local cur code auth_ok=false classification evidence lock_class action auth_status
  cur="$(osu_current_os_version)"
  code="$(osu_current_os_codename)"
  auth_status="$(osu_probe_execute_authorization)" || true
  [[ "$auth_status" == "OK" ]] && auth_ok=true
  OSU_EXECUTE=0
  evidence="$(osu_hop_release_upgrade_evidence)"
  lock_class="$(osu_lock_classify)"
  case "$ST_STATE" in
    COMPLETED) classification="COMPLETED" ;;
    FAILED) classification="FAILED" ;;
    BLOCKED) classification="BLOCKED" ;;
    PAUSED) classification="PAUSED" ;;
    CHECKPOINT_REACHED) classification="CHECKPOINT_REACHED" ;;
    REBOOT_REQUIRED|REBOOT_REQUESTED|RESUME_REQUIRED|HOP_SOURCE_PREPARING|HOP_SOURCE_READY|HOP_CURRENT_RELEASE_UPDATING|HOP_RELEASE_UPGRADE_STARTING|HOP_RELEASE_UPGRADE_RUNNING|HOP_VALIDATING|HOP_PRECHECK|RESUMED)
      classification="$(osu_classify_in_progress_hop)"
      ;;
    *) classification="$ST_STATE" ;;
  esac
  action="$(osu_recommended_recovery_action "$classification")"
  local aux
  aux="$(osu_hop_dro_aux_evidence 2>/dev/null || true)"
  local resume_stage
  resume_stage="$(osu_resolve_resume_stage 2>/dev/null || true)"
  printf 'classification: %s\n' "$classification"
  printf 'resume_stage: %s\n' "${resume_stage:-}"
  printf 'current_state: %s\n' "$ST_STATE"
  printf 'last_successful_step: %s\n' "${ST_LAST_STEP:-}"
  printf 'next_action: %s\n' "${ST_NEXT_ACTION:-}"
  printf 'current_os: %s (%s)\n' "$cur" "$code"
  printf 'hop_target: %s (%s)\n' "${ST_TARGET_OS:-}" "${ST_TARGET_CODENAME:-}"
  printf 'hop: %s / %s\n' "${ST_CURRENT_HOP:-}" "${ST_TOTAL_HOPS:-}"
  printf 'execute_authorized: %s\n' "$auth_ok"
  printf 'auth_status: %s\n' "$auth_status"
  printf 'release_upgrade_evidence: %s\n' "$evidence"
  if [[ -n "$aux" ]]; then
    printf 'dro_aux_evidence: %s\n' "$aux"
  fi
  printf 'new_preflight_required: %s\n' "${ST_NEW_PREFLIGHT_REQUIRED:-false}"
  printf 'lock_class: %s\n' "$lock_class"
  printf 'reboot_required_file: %s\n' "$( [[ -f "$(osu_hostpath /var/run/reboot-required)" ]] && echo yes || echo no )"
  printf 'recommended_action: %s\n' "$action"
  printf 'phase2_executed: false\n'
  case "$classification" in
    REBOOT_REQUIRED|RESUME_REQUIRED|CONTINUE_SOURCE_PREPARATION|CONTINUE_CURRENT_RELEASE_UPDATE|CONTINUE_RELEASE_UPGRADE|CONTINUE_POST_UPGRADE_REBOOT)
      exit "$EXIT_RESUME_REQUIRED" ;;
    BLOCKED|BLOCKED_INCONSISTENT_EVIDENCE) exit "$EXIT_BLOCKED" ;;
    FAILED) exit "$EXIT_FAILED" ;;
    *) exit 0 ;;
  esac
}

cmd_recover_resume_dispatch() {
  osu_require_root_for_mutate || exit "$EXIT_CLI"
  [[ -f "$(osu_state_path)" ]] || osu_die_cli "no state"
  osu_verify_state_checksum || osu_die_integrity "state checksum mismatch"
  osu_load_state_into_vars || exit "$EXIT_INTEGRITY"
  local lock_class
  lock_class="$(osu_lock_classify)"
  if [[ "$lock_class" != "FREE" ]]; then
    osu_die_blocked "recover-resume-dispatch refused: lock_class=${lock_class} (need FREE)"
  fi
  if ! osu_acquire_lock; then exit "$EXIT_INTEGRITY"; fi
  trap 'osu_release_lock; osu_cleanup_tmp' EXIT
  : >"$(osu_hostpath /tmp/stub-commands.log)" 2>/dev/null || true
  if ! osu_recover_resume_dispatch; then
    osu_load_state_into_vars || true
    printf 'recovery_refused: current_state=%s\n' "${ST_STATE:-unknown}"
    printf 'block_reason: %s\n' "${ST_BLOCK_REASON:-${ST_LAST_ERROR:-refused}}"
    printf 'OS upgrade / reboot were not executed.\n'
    exit "$EXIT_BLOCKED"
  fi
  if [[ -f "$(osu_hostpath /tmp/stub-commands.log)" ]] && \
     grep -qE '^(apt-get|apt|dpkg|do-release-upgrade|reboot|systemctl reboot)' \
       "$(osu_hostpath /tmp/stub-commands.log)" 2>/dev/null; then
    osu_die_integrity "recover-resume-dispatch unexpectedly invoked package/reboot commands"
  fi
  osu_load_state_into_vars || true
  printf 'recovered: current_state=%s\n' "${ST_STATE}"
  printf 'last_successful_step: %s\n' "${ST_LAST_STEP}"
  printf 'next_action: %s\n' "${ST_NEXT_ACTION}"
  printf 'current_hop: %s\n' "${ST_CURRENT_HOP}"
  printf 'current_os: %s\n' "${ST_CURRENT_OS}"
  printf 'target_os: %s\n' "${ST_TARGET_OS}"
  printf 'last_error: %s\n' "${ST_LAST_ERROR:-null}"
  printf 'block_reason: %s\n' "${ST_BLOCK_REASON:-null}"
  printf 'new_preflight_required: %s\n' "${ST_NEW_PREFLIGHT_REQUIRED}"
  printf 'Destructive release upgrade/reboot: NOT RUN\n'
  printf 'Next: new collector/preflight, then:\n'
  printf '  dp-os-upgrade-only.sh resume --preflight <new-preflight.tar.gz> --execute ...\n'
  exit "$EXIT_RESUME_REQUIRED"
}

cmd_recover_not_started() {
  osu_require_root_for_mutate || exit "$EXIT_CLI"
  [[ -f "$(osu_state_path)" ]] || osu_die_cli "no state"
  osu_verify_state_checksum || osu_die_integrity "state checksum mismatch"
  osu_load_state_into_vars || exit "$EXIT_INTEGRITY"
  local lock_class
  lock_class="$(osu_lock_classify)"
  if [[ "$lock_class" != "FREE" ]]; then
    osu_die_blocked "recover-not-started refused: lock_class=${lock_class} (need FREE)"
  fi
  if ! osu_acquire_lock; then exit "$EXIT_INTEGRITY"; fi
  trap 'osu_release_lock; osu_cleanup_tmp' EXIT
  : >"$(osu_hostpath /tmp/stub-commands.log)" 2>/dev/null || true
  osu_recover_not_started || exit "$EXIT_BLOCKED"
  # Guard: recover must not invoke apt / do-release-upgrade / reboot.
  if [[ -f "$(osu_hostpath /tmp/stub-commands.log)" ]] && \
     grep -qE '^(apt-get|apt|dpkg|do-release-upgrade|reboot|systemctl reboot)' \
       "$(osu_hostpath /tmp/stub-commands.log)" 2>/dev/null; then
    osu_die_integrity "recover-not-started unexpectedly invoked package/reboot commands"
  fi
  printf 'recovered: current_state=RESUME_REQUIRED\n'
  printf 'last_successful_step: %s\n' "${ST_LAST_STEP:-before_release_upgrade}"
  printf 'next_action: %s\n' "${ST_NEXT_ACTION:-RUN_OS_UPGRADE}"
  printf 'new_preflight_required: %s\n' "${ST_NEW_PREFLIGHT_REQUIRED:-true}"
  printf 'hops_completed_this_run: %s\n' "${ST_HOPS_THIS_RUN:-0}"
  printf 'OS upgrade / reboot were not executed.\n'
  printf 'Next: collect fresh preflight, then:\n'
  printf '  dp-os-upgrade-only.sh resume --preflight <new-preflight.tar.gz> --execute ...\n'
}

cmd_recover_current_release_update() {
  osu_require_root_for_mutate || exit "$EXIT_CLI"
  [[ -f "$(osu_state_path)" ]] || osu_die_cli "no state"
  osu_verify_state_checksum || osu_die_integrity "state checksum mismatch"
  osu_load_state_into_vars || exit "$EXIT_INTEGRITY"
  local lock_class
  lock_class="$(osu_lock_classify)"
  if [[ "$lock_class" != "FREE" ]]; then
    osu_die_blocked "recover-current-release-update refused: lock_class=${lock_class} (need FREE)"
  fi
  if ! osu_acquire_lock; then exit "$EXIT_INTEGRITY"; fi
  trap 'osu_release_lock; osu_cleanup_tmp' EXIT
  : >"$(osu_hostpath /tmp/stub-commands.log)" 2>/dev/null || true
  if ! osu_recover_current_release_update; then
    osu_load_state_into_vars || true
    printf 'recovery_refused: current_state=%s\n' "${ST_STATE:-unknown}"
    printf 'block_reason: %s\n' "${ST_BLOCK_REASON:-${ST_LAST_ERROR:-verification_failed}}"
    printf 'OS upgrade / reboot were not executed.\n'
    exit "$EXIT_BLOCKED"
  fi
  # Guard: allow dpkg --audit / apt-get check / apt-get -s only; never install/dro/reboot
  if [[ -f "$(osu_hostpath /tmp/stub-commands.log)" ]]; then
    if grep -qE '^(do-release-upgrade|reboot|systemctl)' \
         "$(osu_hostpath /tmp/stub-commands.log)" 2>/dev/null; then
      osu_die_integrity "recover-current-release-update unexpectedly invoked reboot/dro"
    fi
    if grep -E '^apt-get ' "$(osu_hostpath /tmp/stub-commands.log)" 2>/dev/null \
         | grep -vqE '^apt-get (check|-s| --simulate)'; then
      osu_die_integrity "recover-current-release-update unexpectedly invoked mutating apt-get"
    fi
  fi
  osu_load_state_into_vars || true
  printf 'recovered: current_state=%s\n' "${ST_STATE}"
  printf 'last_successful_step: %s\n' "${ST_LAST_STEP}"
  printf 'current_hop: %s\n' "${ST_CURRENT_HOP}"
  printf 'current_os: %s\n' "${ST_CURRENT_OS}"
  printf 'target_os: %s\n' "${ST_TARGET_OS}"
  printf 'next_action: %s\n' "${ST_NEXT_ACTION}"
  printf 'retryable: %s\n' "${ST_RETRYABLE}"
  printf 'last_error: %s\n' "${ST_LAST_ERROR:-null}"
  printf 'block_reason: %s\n' "${ST_BLOCK_REASON:-null}"
  printf 'new_preflight_required: %s\n' "${ST_NEW_PREFLIGHT_REQUIRED}"
  printf 'hops_completed_this_run: %s\n' "${ST_HOPS_THIS_RUN:-0}"
  printf 'Destructive release upgrade/reboot: NOT RUN\n'
  printf 'Next: repair-runtime (if needed), diagnose, new collector/preflight, then:\n'
  printf '  dp-os-upgrade-only.sh resume --preflight <new-preflight.tar.gz> --execute ...\n'
  exit "$EXIT_RESUME_REQUIRED"
}

cmd_request_reboot() {
  osu_require_root_for_mutate || exit "$EXIT_CLI"
  [[ -f "$(osu_state_path)" ]] || osu_die_cli "no state"
  osu_verify_state_checksum || osu_die_integrity "state checksum mismatch"
  osu_load_state_into_vars || exit "$EXIT_INTEGRITY"
  local evidence classification
  evidence="$(osu_hop_release_upgrade_evidence)"
  classification="$(osu_classify_in_progress_hop)"
  if [[ "$evidence" != "SUCCESS" ]]; then
    osu_die_blocked "request-reboot refused: release upgrade success evidence missing (evidence=${evidence}, classification=${classification})"
  fi
  if [[ "$classification" != "REBOOT_REQUIRED" ]]; then
    osu_die_blocked "request-reboot refused: classification=${classification} (need REBOOT_REQUIRED)"
  fi
  if [[ "${EXECUTE:-0}" -ne 1 ]]; then
    # Prefer durable auth already on disk; --execute only required when re-auth needed
    if ! osu_apply_execute_authorization; then
      osu_die_integrity "request-reboot refused: durable execute authorization missing — re-run with --execute and destructive ack"
    fi
  else
    if ! osu_apply_execute_authorization; then
      if [[ "$DESTRUCTIVE_ACK" != "$POLICY_DESTRUCTIVE_ACK_PHRASE" ]]; then
        osu_die_cli "request-reboot re-authorization requires --acknowledge-destructive-upgrade '${POLICY_DESTRUCTIVE_ACK_PHRASE}'"
      fi
      local discovery_ok=false
      if [[ "${ST_EXECUTION_PROFILE:-production}" == "discovery" ]]; then
        if [[ "$DISCOVERY_ACK" != "$POLICY_DISCOVERY_DISPOSABLE_VM_ACK_PHRASE" ]]; then
          osu_die_cli "discovery request-reboot re-authorization requires --acknowledge-disposable-discovery-vm '${POLICY_DISCOVERY_DISPOSABLE_VM_ACK_PHRASE}'"
        fi
        discovery_ok=true
      fi
      osu_reauthorize_execute_for_resume "$discovery_ok" || osu_die_integrity "request-reboot re-authorization failed"
    fi
  fi
  if ! osu_acquire_lock; then exit "$EXIT_INTEGRITY"; fi
  trap 'osu_release_lock; osu_cleanup_tmp' EXIT
  if [[ "$ST_STATE" == "REBOOT_REQUESTED" ]]; then
    osu_transition_state REBOOT_REQUIRED "request_reboot_requeue" || osu_die_integrity "cannot requeue reboot"
  elif [[ "$ST_STATE" != "REBOOT_REQUIRED" ]]; then
    osu_transition_state REBOOT_REQUIRED "request_reboot_classified" || osu_die_blocked "cannot enter REBOOT_REQUIRED from ${ST_STATE}"
  fi
  osu_request_reboot || exit "$EXIT_BLOCKED"
  printf 'reboot requested (release-upgrade success evidence present)\n'
  if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
    exit 0
  fi
  exit "$EXIT_RESUME_REQUIRED"
}

cmd_recover_lock() {
  osu_require_root_for_mutate || exit "$EXIT_CLI"
  local classification
  classification="$(osu_lock_classify)"
  printf 'lock_class: %s\n' "$classification"
  case "$classification" in
    FREE)
      printf 'lock already free — nothing to recover\n'
      exit 0
      ;;
    HELD_LIVE|BLOCKED_ACTIVITY)
      osu_die_blocked "recover-lock refused: lock_class=${classification} (live holder or apt/dro activity)"
      ;;
    STALE)
      osu_recover_stale_lock || exit "$EXIT_INTEGRITY"
      printf 'stale lock recovered\n'
      exit 0
      ;;
    *)
      osu_die_integrity "recover-lock: unexpected lock_class=${classification}"
      ;;
  esac
}

cmd_export_artifacts() {
  [[ -f "$(osu_state_path)" ]] || osu_die_cli "no state — nothing to export"
  osu_load_state_into_vars || exit "$EXIT_INTEGRITY"
  if ! declare -F osu_export_artifacts >/dev/null 2>&1; then
    osu_die_cli "artifact export helpers unavailable"
  fi
  osu_export_artifacts "${EXPORT_HOP:-}" "$EXPORT_OUTPUT_DIR" "$EXPORT_KEEP_DIR"
}

cmd_archive_orphaned_state() {
  osu_require_root_for_mutate || exit "$EXIT_CLI"
  if [[ "$ORPHAN_ARCHIVE_ACK" != "${POLICY_ORPHAN_ARCHIVE_ACK_PHRASE:-$OSU_ORPHAN_ARCHIVE_ACK_DEFAULT}" ]]; then
    osu_die_cli "archive-orphaned-state requires --acknowledge-orphan-archive '${POLICY_ORPHAN_ARCHIVE_ACK_PHRASE:-$OSU_ORPHAN_ARCHIVE_ACK_DEFAULT}'"
  fi
  if osu_os_upgrade_activity_present; then
    osu_die_cli "refusing archive: apt/dpkg/do-release-upgrade/dp-os-upgrade process is active"
  fi
  if osu_apt_lock_active; then
    osu_die_cli "refusing archive: apt/dpkg lock is active"
  fi

  local state_dir parent base stamp dest
  state_dir="$OSU_STATE_DIR"
  printf 'current_os: %s (%s)\n' "$(osu_current_os_version)" "$(osu_current_os_codename)"

  if [[ ! -e "$state_dir" ]]; then
    osu_die_cli "nothing to archive: $state_dir does not exist"
  fi
  if [[ -f "$(osu_state_path)" ]]; then
    if osu_verify_state_checksum 2>/dev/null; then
      osu_die_cli "refusing archive: valid state.json present — use status/resume/continue instead"
    fi
    osu_log WARN "state.json present but checksum invalid — treating as orphaned evidence"
  fi

  parent="$(dirname "$state_dir")"
  base="$(basename "$state_dir")"
  stamp="$(osu_utc_stamp)"
  dest="${parent}/${base}.orphaned-${stamp}"
  if [[ -e "$dest" ]]; then
    osu_die_integrity "archive destination already exists: $dest"
  fi
  mv "$state_dir" "$dest" || osu_die_integrity "failed to mv $state_dir -> $dest"
  printf 'archived_orphaned_state: %s\n' "$dest"
  printf 'note: directory was moved, not deleted\n'
}

cmd_service_install() {
  osu_require_root_for_mutate || exit "$EXIT_CLI"
  _install_systemd_units || osu_die_cli "failed to install units"
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify \
      "$(osu_hostpath /etc/systemd/system/dp-os-upgrade.service)" \
      "$(osu_hostpath /etc/systemd/system/dp-os-upgrade-resume.service)" \
      "$(osu_hostpath /etc/systemd/system/dp-os-upgrade-resume.timer)" 2>/dev/null || true
  fi
  printf 'systemd units installed; upgrade not started\n'
}

cmd_service_remove() {
  osu_require_root_for_mutate || exit "$EXIT_CLI"
  if [[ -f "$(osu_state_path)" ]]; then
    osu_load_state_into_vars || true
    case "$ST_STATE" in
      COMPLETED|NEW|"") ;;
      *)
        osu_log ERROR "refuse service-remove while state=$ST_STATE"
        exit "$EXIT_CLI"
        ;;
    esac
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now dp-os-upgrade-resume.timer 2>/dev/null || true
    systemctl disable dp-os-upgrade.service 2>/dev/null || true
  fi
  rm -f "$(osu_hostpath /etc/systemd/system/dp-os-upgrade.service)" \
        "$(osu_hostpath /etc/systemd/system/dp-os-upgrade-resume.service)" \
        "$(osu_hostpath /etc/systemd/system/dp-os-upgrade-resume.timer)"
  printf 'systemd units removed\n'
}

main() {
  osu_init_test_mode || exit "$EXIT_CLI"
  parse_global_args "$@"
  [[ -n "$SUBCOMMAND" ]] || { usage; exit "$EXIT_CLI"; }

  case "$SUBCOMMAND" in
    help) usage; exit 0 ;;
    version) cmd_version; exit 0 ;;
  esac

  osu_load_config "$CONFIG_PATH" || exit "$EXIT_CLI"
  # check/plan/diagnose remain non-mutating; install/continue set durable auth explicitly.
  OSU_EXECUTE=0
  case "$SUBCOMMAND" in
    check|plan|status|validate|logs|report|diagnose|help|version)
      OSU_EXECUTE=0
      ;;
    *)
      # Mutating subcommands still require durable auth or install gates; do not
      # elevate solely from a one-shot CLI flag except inside install/continue.
      OSU_EXECUTE=0
      ;;
  esac

  case "$SUBCOMMAND" in
    check) cmd_check ;;
    plan) cmd_plan ;;
    install) cmd_install ;;
    status) cmd_status ;;
    resume) cmd_resume ;;
    continue) cmd_continue ;;
    validate) cmd_validate ;;
    pause) cmd_pause ;;
    unpause) cmd_unpause ;;
    logs) cmd_logs ;;
    report) cmd_report ;;
    export-artifacts) cmd_export_artifacts ;;
    archive-orphaned-state) cmd_archive_orphaned_state ;;
    repair-runtime) cmd_repair_runtime ;;
    diagnose) cmd_diagnose ;;
    request-reboot) cmd_request_reboot ;;
    recover-lock) cmd_recover_lock ;;
    recover-not-started) cmd_recover_not_started ;;
    recover-current-release-update) cmd_recover_current_release_update ;;
    recover-resume-dispatch) cmd_recover_resume_dispatch ;;
    service-install) cmd_service_install ;;
    service-remove) cmd_service_remove ;;
    *)
      printf 'Unknown subcommand: %s\n' "$SUBCOMMAND" >&2
      exit "$EXIT_CLI"
      ;;
  esac
}

main "$@"
