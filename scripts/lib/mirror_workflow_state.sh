#!/usr/bin/env bash
# scripts/lib/mirror_workflow_state.sh — generation-bound Mirror workflow state
# shellcheck shell=bash
#
# Authoritative workflow phases (monotonic; invalidation demotes):
#   UNCONFIGURED → CONFIGURED → PREPARED → CLIENT_SET_PUBLISHED
#   → HTTP_ENABLED → READINESS_VERIFIED → COMMANDS_GENERATED
#
# Success is never inferred from stale files, boolean flags alone, or past PASS
# strings. Generations must match across config → client set → HTTP → readiness
# → commands.

if [[ -n "${MIRROR_WORKFLOW_STATE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
MIRROR_WORKFLOW_STATE_LOADED=1

# Default path; prefer live MM_WORKFLOW_FILE / MM_CONFIG_DIR at call time (see mm_wf_file).
MM_WORKFLOW_FILE="${MM_WORKFLOW_FILE:-}"

# ---------------------------------------------------------------------------
# Logger wrappers (standalone-safe)
# ---------------------------------------------------------------------------
# This module may be sourced before mirror_manager logging helpers exist
# (rebuild-publish-clients, isolated tests, etc.). Logging must never turn a
# successful workflow mutation into rc=127 / WORKFLOW_STATE_UPDATE=SKIPPED.
mm_wf_info() {
  if declare -F mm_info >/dev/null 2>&1; then
    mm_info "$@"
    return 0
  fi
  printf 'INFO: %s\n' "$*"
  return 0
}

mm_wf_warn() {
  if declare -F mm_warn >/dev/null 2>&1; then
    mm_warn "$@"
    return 0
  fi
  printf 'WARN: %s\n' "$*" >&2
  return 0
}

mm_wf_ok() {
  if declare -F mm_ok >/dev/null 2>&1; then
    mm_ok "$@"
    return 0
  fi
  printf 'OK: %s\n' "$*"
  return 0
}

# ---------------------------------------------------------------------------
# Low-level atomic KV store
# ---------------------------------------------------------------------------
mm_wf_file() {
  # Resolve at call time so tests/callers can set MM_CONFIG_DIR after sourcing.
  if [[ -n "${MM_WORKFLOW_FILE:-}" ]]; then
    printf '%s\n' "${MM_WORKFLOW_FILE}"
  else
    printf '%s\n' "${MM_CONFIG_DIR:-/etc/ubuntu-mirror}/dp-upgrade-workflow.state"
  fi
}

mm_wf_new_generation_id() {
  printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "${RANDOM}$$"
}

mm_wf_atomic_write_file() {
  local dest="$1"
  local src="$2"
  local dir mode old_umask tmp
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  mode="$(stat -c '%a' "$dest" 2>/dev/null || printf '600')"
  tmp="$(mktemp "${dir}/.wf.XXXXXX")"
  old_umask="$(umask)"
  umask 077
  cat "$src" >"$tmp"
  umask "$old_umask"
  chmod "$mode" "$tmp" 2>/dev/null || chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dest"
  chmod "$mode" "$dest" 2>/dev/null || chmod 600 "$dest" 2>/dev/null || true
}

mm_wf_ensure_file() {
  local f
  f="$(mm_wf_file)"
  if [[ -f "$f" && ! -r "$f" ]]; then
    # Existing root-owned state must not abort non-root callers under set -e.
    mm_wf_warn "WORKFLOW_STATE_UNREADABLE path=${f}"
    return 1
  fi
  if [[ ! -f "$f" ]]; then
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
    umask 077
    if ! cat >"$f" <<EOF
WORKFLOW_STATE=UNCONFIGURED
WORKFLOW_GENERATION_ID=
CONFIG_SHA256=
PREPARATION_MODE=
MIRROR_SERVER_IP=
MIRROR_HTTP_URL=
PHASE2_TARGET_VERSION=6.6.0
OS_CORE_GENERATION_ID=
PHASE2_GENERATION_ID=
CLIENT_SET_GENERATION_ID=
CLIENT_SIGNING_FINGERPRINT=
CLIENT_BUILD_INPUT_SHA256=
CLIENT_SOURCE_REVISION=
CLIENT_RUNTIME_MANIFEST_SHA256=
CLIENT_COMMAND_BLOCK_VERSION=
CLIENT_PROVENANCE_SCHEMA_VERSION=
HTTP_PUBLICATION_GENERATION_ID=
READINESS_VERIFIED_GENERATION_ID=
COMMAND_FILE_GENERATION_ID=
CREATED_UTC=
VERIFIED_UTC=
HTTP_REENABLE_REQUIRED=
EOF
    then
      return 1
    fi
    chmod 600 "$f" 2>/dev/null || true
  fi
}

mm_wf_get() {
  local key="$1"
  local f
  f="$(mm_wf_file)"
  # Missing or unreadable → empty (do not abort callers under set -e).
  [[ -f "$f" && -r "$f" ]] || { printf ''; return 0; }
  awk -F= -v k="$key" '$1==k { print substr($0, length($1) + 2); exit }' "$f" 2>/dev/null || true
}

mm_wf_set_many() {
  # Usage: mm_wf_set_many KEY=VAL KEY=VAL ...
  # Atomic multi-key update of the workflow state file.
  local f tmp line key val k2
  local -A updates=()
  local -A cur=()
  mm_wf_ensure_file || return 1
  f="$(mm_wf_file)"
  [[ -r "$f" && -w "$f" ]] || {
    mm_wf_warn "WORKFLOW_STATE_NOT_WRITABLE path=${f}"
    return 1
  }
  for line in "$@"; do
    key="${line%%=*}"
    val="${line#*=}"
    [[ -n "$key" ]] || continue
    updates["$key"]="$val"
  done
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    cur["${line%%=*}"]="${line#*=}"
  done <"$f"
  for k2 in "${!updates[@]}"; do
    cur["$k2"]="${updates[$k2]}"
  done
  tmp="$(mktemp "$(dirname "$f")/.wfset.XXXXXX")"
  {
    for k2 in \
      WORKFLOW_STATE WORKFLOW_GENERATION_ID CONFIG_SHA256 PREPARATION_MODE \
      MIRROR_SERVER_IP MIRROR_HTTP_URL PHASE2_TARGET_VERSION \
      OS_CORE_GENERATION_ID PHASE2_GENERATION_ID CLIENT_SET_GENERATION_ID \
      CLIENT_SIGNING_FINGERPRINT CLIENT_BUILD_INPUT_SHA256 \
      CLIENT_SOURCE_REVISION CLIENT_RUNTIME_MANIFEST_SHA256 \
      CLIENT_COMMAND_BLOCK_VERSION CLIENT_PROVENANCE_SCHEMA_VERSION \
      HTTP_PUBLICATION_GENERATION_ID \
      READINESS_VERIFIED_GENERATION_ID COMMAND_FILE_GENERATION_ID \
      CREATED_UTC VERIFIED_UTC HTTP_REENABLE_REQUIRED
    do
      if [[ -n "${cur[$k2]+x}" ]]; then
        printf '%s=%s\n' "$k2" "${cur[$k2]}"
        unset "cur[$k2]"
      fi
    done
    for k2 in "${!cur[@]}"; do
      printf '%s=%s\n' "$k2" "${cur[$k2]}"
    done
  } >"$tmp"
  mm_wf_atomic_write_file "$f" "$tmp"
  rm -f "$tmp"
}

mm_wf_set() {
  local key="$1" val="$2"
  mm_wf_set_many "${key}=${val}"
}

# ---------------------------------------------------------------------------
# Config identity
# ---------------------------------------------------------------------------
mm_wf_config_sha256() {
  local f="${MM_CONFIG_FILE:-/etc/ubuntu-mirror/dp-upgrade-mirror.conf}"
  if [[ ! -f "$f" ]]; then
    printf ''
    return 1
  fi
  # Content digest of operator-relevant keys only (stable across rewrite order).
  # shellcheck disable=SC1090
  (
    set -a
    # shellcheck source=/dev/null
    source "$f"
    set +a
    printf 'PREPARATION_MODE=%s\n' "${PREPARATION_MODE:-}"
    printf 'MIRROR_SERVER_IP=%s\n' "${MIRROR_SERVER_IP:-}"
    printf 'MIRROR_HTTP_URL=%s\n' "${MIRROR_HTTP_URL:-}"
    printf 'ACPS_USERNAME=%s\n' "${ACPS_USERNAME:-}"
    # Password contributes to identity without logging it.
    if [[ -n "${ACPS_PASSWORD:-}" ]]; then
      printf 'ACPS_PASSWORD_SHA256=%s\n' \
        "$(printf '%s' "${ACPS_PASSWORD}" | sha256sum | awk '{print $1}')"
    else
      printf 'ACPS_PASSWORD_SHA256=\n'
    fi
    # Include cluster command-routing inputs only when set so existing AIO
    # configs keep their identity hash.
    if [[ -n "${WORKER_SSH_PASSWORD:-}" ]]; then
      printf 'WORKER_SSH_PASSWORD_SHA256=%s\n' \
        "$(printf '%s' "${WORKER_SSH_PASSWORD}" | sha256sum | awk '{print $1}')"
    fi
    [[ -n "${DL_WORKER_IPS:-}" ]] && printf 'DL_WORKER_IPS=%s\n' "${DL_WORKER_IPS}"
    [[ -n "${DA_WORKER_IPS:-}" ]] && printf 'DA_WORKER_IPS=%s\n' "${DA_WORKER_IPS}"
  ) | sha256sum | awk '{print $1}'
}

mm_wf_state() {
  local s
  s="$(mm_wf_get WORKFLOW_STATE)"
  printf '%s\n' "${s:-UNCONFIGURED}"
}

# ---------------------------------------------------------------------------
# Phase transitions + invalidation
# ---------------------------------------------------------------------------
mm_wf_mark_configured() {
  local gen sha mode ip url
  mm_wf_ensure_file
  gen="$(mm_wf_new_generation_id)"
  sha="$(mm_wf_config_sha256 || true)"
  mode="${PREPARATION_MODE:-FULL}"
  ip="${MIRROR_SERVER_IP:-}"
  url="${MIRROR_HTTP_URL:-}"
  mm_wf_set_many \
    "WORKFLOW_STATE=CONFIGURED" \
    "WORKFLOW_GENERATION_ID=${gen}" \
    "CONFIG_SHA256=${sha}" \
    "PREPARATION_MODE=${mode}" \
    "MIRROR_SERVER_IP=${ip}" \
    "MIRROR_HTTP_URL=${url}" \
    "PHASE2_TARGET_VERSION=${PHASE2_TARGET_VERSION:-6.6.0}" \
    "OS_CORE_GENERATION_ID=" \
    "PHASE2_GENERATION_ID=" \
    "CLIENT_SET_GENERATION_ID=" \
    "CLIENT_SIGNING_FINGERPRINT=" \
    "CLIENT_BUILD_INPUT_SHA256=" \
    "CLIENT_SOURCE_REVISION=" \
    "CLIENT_RUNTIME_MANIFEST_SHA256=" \
    "CLIENT_COMMAND_BLOCK_VERSION=" \
    "CLIENT_PROVENANCE_SCHEMA_VERSION=" \
    "HTTP_PUBLICATION_GENERATION_ID=" \
    "READINESS_VERIFIED_GENERATION_ID=" \
    "COMMAND_FILE_GENERATION_ID=" \
    "CREATED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "VERIFIED_UTC=" \
    "HTTP_REENABLE_REQUIRED="
  if declare -F mm_status_set >/dev/null 2>&1; then
    mm_status_set WORKFLOW_STATE CONFIGURED
    mm_status_set WORKFLOW_GENERATION_ID "$gen"
    mm_status_set CONFIG_SHA256 "$sha"
    mm_status_set UPGRADE_READINESS FAIL
    mm_status_set READINESS_RESULT ""
    mm_status_set CLIENT_COMMANDS_MODE ""
  fi
  mm_wf_info "WORKFLOW_STATE=CONFIGURED WORKFLOW_GENERATION_ID=${gen} CONFIG_SHA256=${sha}"
}

# Config change invalidates everything after CONFIGURED.
mm_wf_invalidate_after_config_change() {
  local prev_sha new_sha prev_ip prev_mode prev_fpr
  if ! mm_wf_ensure_file; then
    mm_wf_warn "WORKFLOW_STATE_UPDATE=SKIPPED reason=unreadable_or_unwritable"
    return 0
  fi
  prev_sha="$(mm_wf_get CONFIG_SHA256)"
  prev_ip="$(mm_wf_get MIRROR_SERVER_IP)"
  prev_mode="$(mm_wf_get PREPARATION_MODE)"
  prev_fpr="$(mm_wf_get CLIENT_SIGNING_FINGERPRINT)"
  new_sha="$(mm_wf_config_sha256 || true)"
  if [[ -n "$prev_sha" && "$prev_sha" == "$new_sha" ]]; then
    # Still refresh IP/mode mirrors; no demotion if identity unchanged.
    mm_wf_set_many \
      "PREPARATION_MODE=${PREPARATION_MODE:-FULL}" \
      "MIRROR_SERVER_IP=${MIRROR_SERVER_IP:-}" \
      "MIRROR_HTTP_URL=${MIRROR_HTTP_URL:-}" \
      || return 0
    return 0
  fi
  mm_wf_mark_configured || return 0
  if [[ -n "$prev_mode" && "$prev_mode" != "${PREPARATION_MODE:-}" ]]; then
    mm_wf_info "WORKFLOW_STALE reason=preparation_mode_changed old=${prev_mode} new=${PREPARATION_MODE:-}"
  fi
  if [[ -n "$prev_ip" && "$prev_ip" != "${MIRROR_SERVER_IP:-}" ]]; then
    mm_wf_info "WORKFLOW_STALE reason=mirror_server_ip_changed"
  fi
  if [[ -n "$prev_fpr" ]]; then
    mm_wf_info "WORKFLOW_STALE reason=config_identity_changed clearing_client_http_readiness_commands"
  fi
}

mm_wf_mark_prepared() {
  local gen os_gen p2_gen
  gen="$(mm_wf_get WORKFLOW_GENERATION_ID)"
  [[ -n "$gen" ]] || gen="$(mm_wf_new_generation_id)"
  os_gen="${1:-$(mm_wf_new_generation_id)}"
  p2_gen="${2:-$(mm_wf_new_generation_id)}"
  mm_wf_set_many \
    "WORKFLOW_STATE=PREPARED" \
    "WORKFLOW_GENERATION_ID=${gen}" \
    "CONFIG_SHA256=$(mm_wf_config_sha256 || true)" \
    "PREPARATION_MODE=${PREPARATION_MODE:-FULL}" \
    "MIRROR_SERVER_IP=${MIRROR_SERVER_IP:-}" \
    "MIRROR_HTTP_URL=${MIRROR_HTTP_URL:-}" \
    "OS_CORE_GENERATION_ID=${os_gen}" \
    "PHASE2_GENERATION_ID=${p2_gen}" \
    "CLIENT_SET_GENERATION_ID=" \
    "HTTP_PUBLICATION_GENERATION_ID=" \
    "READINESS_VERIFIED_GENERATION_ID=" \
    "COMMAND_FILE_GENERATION_ID=" \
    "VERIFIED_UTC="
  if declare -F mm_status_set >/dev/null 2>&1; then
    mm_status_set WORKFLOW_STATE PREPARED
    mm_status_set OS_CORE_GENERATION_ID "$os_gen"
    mm_status_set PHASE2_GENERATION_ID "$p2_gen"
    mm_status_set UPGRADE_READINESS FAIL
  fi
  mm_wf_info "WORKFLOW_STATE=PREPARED OS_CORE_GENERATION_ID=${os_gen} PHASE2_GENERATION_ID=${p2_gen}"
}

mm_wf_mark_client_set_published() {
  local client_gen fpr input_sha source_rev runtime_sha command_ver schema_ver
  client_gen="${1:-$(mm_wf_new_generation_id)}"
  fpr="${2:-}"
  input_sha="${3:-}"
  source_rev="${4:-}"
  runtime_sha="${5:-}"
  command_ver="${6:-SUBSHELL_V2}"
  schema_ver="${7:-1}"
  mm_wf_set_many \
    "WORKFLOW_STATE=CLIENT_SET_PUBLISHED" \
    "CLIENT_SET_GENERATION_ID=${client_gen}" \
    "CLIENT_SIGNING_FINGERPRINT=${fpr}" \
    "CLIENT_BUILD_INPUT_SHA256=${input_sha}" \
    "CLIENT_SOURCE_REVISION=${source_rev}" \
    "CLIENT_RUNTIME_MANIFEST_SHA256=${runtime_sha}" \
    "CLIENT_COMMAND_BLOCK_VERSION=${command_ver}" \
    "CLIENT_PROVENANCE_SCHEMA_VERSION=${schema_ver}" \
    "HTTP_PUBLICATION_GENERATION_ID=" \
    "READINESS_VERIFIED_GENERATION_ID=" \
    "COMMAND_FILE_GENERATION_ID=" \
    "VERIFIED_UTC="
  if declare -F mm_status_set >/dev/null 2>&1; then
    mm_status_set WORKFLOW_STATE CLIENT_SET_PUBLISHED
    mm_status_set CLIENT_SET_GENERATION_ID "$client_gen"
    mm_status_set CLIENT_SIGNING_FINGERPRINT "$fpr"
    mm_status_set CLIENT_BUILD_INPUT_SHA256 "$input_sha"
    mm_status_set UPGRADE_READINESS FAIL
  fi
  mm_wf_info "WORKFLOW_STATE=CLIENT_SET_PUBLISHED CLIENT_SET_GENERATION_ID=${client_gen} CLIENT_BUILD_INPUT_SHA256=${input_sha}"
}

mm_wf_mark_http_enabled() {
  local pub_gen client_gen
  client_gen="$(mm_wf_get CLIENT_SET_GENERATION_ID)"
  pub_gen="${1:-${client_gen}}"
  [[ -n "$pub_gen" ]] || pub_gen="$(mm_wf_new_generation_id)"
  mm_wf_set_many \
    "WORKFLOW_STATE=HTTP_ENABLED" \
    "HTTP_PUBLICATION_GENERATION_ID=${pub_gen}" \
    "READINESS_VERIFIED_GENERATION_ID=" \
    "COMMAND_FILE_GENERATION_ID=" \
    "HTTP_REENABLE_REQUIRED=" \
    "VERIFIED_UTC="
  if declare -F mm_status_set >/dev/null 2>&1; then
    mm_status_set WORKFLOW_STATE HTTP_ENABLED
    mm_status_set HTTP_PUBLICATION_GENERATION_ID "$pub_gen"
    mm_status_set HTTP_DISTRIBUTION ENABLED
    mm_status_set UPGRADE_READINESS FAIL
  fi
  mm_wf_info "WORKFLOW_STATE=HTTP_ENABLED HTTP_PUBLICATION_GENERATION_ID=${pub_gen}"
}

mm_wf_mark_http_disabled() {
  local reason="${1:-}"
  mm_wf_set_many \
    "WORKFLOW_STATE=CLIENT_SET_PUBLISHED" \
    "HTTP_PUBLICATION_GENERATION_ID=" \
    "READINESS_VERIFIED_GENERATION_ID=" \
    "COMMAND_FILE_GENERATION_ID=" \
    "HTTP_REENABLE_REQUIRED=YES" \
    "VERIFIED_UTC="
  if declare -F mm_status_set >/dev/null 2>&1; then
    mm_status_set HTTP_DISTRIBUTION DISABLED
    mm_status_set UPGRADE_READINESS FAIL
    mm_status_set HTTP_REENABLE_REQUIRED YES
  fi
  mm_wf_warn "WORKFLOW_HTTP_DISABLED reason=${reason:-unspecified} HTTP_REENABLE_REQUIRED=YES"
}

mm_wf_mark_readiness_verified() {
  local pub_gen
  pub_gen="$(mm_wf_get HTTP_PUBLICATION_GENERATION_ID)"
  [[ -n "$pub_gen" ]] || pub_gen="$(mm_wf_get CLIENT_SET_GENERATION_ID)"
  if [[ -z "$pub_gen" ]]; then
    # Status-file-only callers (unit tests / partial UI paths) may validate
    # readiness before a generation-bound HTTP publication exists.
    mm_wf_warn "WORKFLOW_READINESS_SKIPPED reason=missing_publication_generation"
    return 0
  fi
  mm_wf_set_many \
    "WORKFLOW_STATE=READINESS_VERIFIED" \
    "READINESS_VERIFIED_GENERATION_ID=${pub_gen}" \
    "COMMAND_FILE_GENERATION_ID=" \
    "VERIFIED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if declare -F mm_status_set >/dev/null 2>&1; then
    mm_status_set WORKFLOW_STATE READINESS_VERIFIED
    mm_status_set READINESS_VERIFIED_GENERATION_ID "$pub_gen"
    mm_status_set UPGRADE_READINESS PASS
    mm_status_set READINESS_RESULT PASS
  fi
  mm_wf_ok "UPGRADE_READINESS=PASS READINESS_VERIFIED_GENERATION_ID=${pub_gen}"
}

mm_wf_mark_commands_generated() {
  local ready_gen cmd_gen
  ready_gen="$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)"
  cmd_gen="${1:-${ready_gen}}"
  [[ -n "$cmd_gen" ]] || return 1
  mm_wf_set_many \
    "WORKFLOW_STATE=COMMANDS_GENERATED" \
    "COMMAND_FILE_GENERATION_ID=${cmd_gen}" \
    "DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2"
  if declare -F mm_status_set >/dev/null 2>&1; then
    mm_status_set WORKFLOW_STATE COMMANDS_GENERATED
    mm_status_set COMMAND_FILE_GENERATION_ID "$cmd_gen"
    mm_status_set CLIENT_COMMANDS_MODE "${PREPARATION_MODE:-FULL}"
    mm_status_set CLIENT_COMMANDS_GENERATED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  mm_wf_info "WORKFLOW_STATE=COMMANDS_GENERATED COMMAND_FILE_GENERATION_ID=${cmd_gen} DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2"
}

# Invalidate HTTP/readiness/commands after client republish or signing change.
mm_wf_invalidate_after_client_republish() {
  mm_wf_set_many \
    "WORKFLOW_STATE=CLIENT_SET_PUBLISHED" \
    "HTTP_PUBLICATION_GENERATION_ID=" \
    "READINESS_VERIFIED_GENERATION_ID=" \
    "COMMAND_FILE_GENERATION_ID=" \
    "VERIFIED_UTC="
  if declare -F mm_status_set >/dev/null 2>&1; then
    mm_status_set UPGRADE_READINESS FAIL
    mm_status_set READINESS_RESULT ""
  fi
}

# ---------------------------------------------------------------------------
# Consistency checks (generation binding)
# ---------------------------------------------------------------------------
mm_wf_config_matches_current() {
  local stored current
  stored="$(mm_wf_get CONFIG_SHA256)"
  current="$(mm_wf_config_sha256 || true)"
  [[ -n "$stored" && -n "$current" && "$stored" == "$current" ]]
}

mm_wf_readiness_generation_current() {
  local ready pub client
  ready="$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)"
  pub="$(mm_wf_get HTTP_PUBLICATION_GENERATION_ID)"
  client="$(mm_wf_get CLIENT_SET_GENERATION_ID)"
  [[ -n "$ready" ]] || return 1
  [[ "$ready" == "$pub" || "$ready" == "$client" ]] || return 1
  [[ "$(mm_wf_get WORKFLOW_STATE)" == "READINESS_VERIFIED" \
    || "$(mm_wf_get WORKFLOW_STATE)" == "COMMANDS_GENERATED" ]] || return 1
  if declare -F mm_status_get >/dev/null 2>&1; then
    [[ "$(mm_status_get UPGRADE_READINESS)" == "PASS" ]] || return 1
  fi
  mm_wf_config_matches_current || return 1
  return 0
}

# Lightweight Menu 7 preflight. Sets MM_WF_BLOCK_REASON / MM_WF_REQUIRED_ACTION.
# shellcheck disable=SC2034 # exported for Menu 7 GUI consumption
mm_wf_commands_preflight() {
  MM_WF_BLOCK_REASON=""
  MM_WF_REQUIRED_ACTION=""
  export MM_WF_BLOCK_REASON MM_WF_REQUIRED_ACTION
  local mode ip state ready pub

  if declare -F mm_normalize_preparation_mode >/dev/null 2>&1; then
    mm_normalize_preparation_mode
  fi
  mode="${PREPARATION_MODE:-}"
  case "$mode" in
    FULL|PHASE2_ONLY) ;;
    *)
      MM_WF_BLOCK_REASON="PREPARATION_MODE_INVALID"
      MM_WF_REQUIRED_ACTION="Configuration"
      return 1
      ;;
  esac

  ip="${MIRROR_SERVER_IP:-}"
  if [[ -z "$ip" ]]; then
    MM_WF_BLOCK_REASON="MIRROR_SERVER_IP_NOT_OPERATOR_CONFIRMED"
    MM_WF_REQUIRED_ACTION="Configuration"
    return 1
  fi

  if ! mm_wf_config_matches_current; then
    MM_WF_BLOCK_REASON="STALE_CONFIG_SHA256"
    MM_WF_REQUIRED_ACTION="Verify Upgrade Readiness"
    return 1
  fi

  state="$(mm_wf_state)"
  if [[ "$(mm_status_get HTTP_DISTRIBUTION 2>/dev/null || true)" != "ENABLED" ]] \
    && [[ "$state" != "HTTP_ENABLED" && "$state" != "READINESS_VERIFIED" && "$state" != "COMMANDS_GENERATED" ]]; then
    MM_WF_BLOCK_REASON="HTTP_NOT_ENABLED"
    MM_WF_REQUIRED_ACTION="Enable HTTP Distribution"
    return 1
  fi

  if [[ "$(mm_status_get UPGRADE_READINESS 2>/dev/null || true)" != "PASS" ]]; then
    MM_WF_BLOCK_REASON="UPGRADE_READINESS_NOT_PASS"
    MM_WF_REQUIRED_ACTION="Verify Upgrade Readiness"
    return 1
  fi

  ready="$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)"
  pub="$(mm_wf_get HTTP_PUBLICATION_GENERATION_ID)"
  if [[ -z "$ready" || -z "$pub" || "$ready" != "$pub" ]]; then
    MM_WF_BLOCK_REASON="READINESS_GENERATION_MISMATCH"
    MM_WF_REQUIRED_ACTION="Verify Upgrade Readiness"
    return 1
  fi

  if [[ -z "$(mm_wf_get CLIENT_SET_GENERATION_ID)" ]]; then
    MM_WF_BLOCK_REASON="CLIENT_SET_GENERATION_MISSING"
    MM_WF_REQUIRED_ACTION="Download and Prepare"
    return 1
  fi

  if [[ -z "$(mm_wf_get CLIENT_SIGNING_FINGERPRINT)" ]]; then
    MM_WF_BLOCK_REASON="CLIENT_SIGNING_FINGERPRINT_MISSING"
    MM_WF_REQUIRED_ACTION="Download and Prepare"
    return 1
  fi
  if declare -F mm_client_set_current_source >/dev/null 2>&1; then
    if ! mm_client_set_current_source "${MM_CLIENT_ROOT:-}" >/dev/null 2>&1; then
      MM_WF_BLOCK_REASON="STALE_CLIENT_BUILD_INPUT"
      MM_WF_REQUIRED_ACTION="Download and Prepare"
      return 1
    fi
  fi

  # FULL mode requires current-generation launchers and wrappers before Menu 7.
  if [[ "$mode" == "FULL" ]] && declare -F mm_client_launchers_ready >/dev/null 2>&1; then
    if ! mm_client_launchers_ready "${MM_CLIENT_ROOT:-}" >/dev/null 2>&1; then
      MM_WF_BLOCK_REASON="launcher_generation_mismatch"
      MM_WF_REQUIRED_ACTION="Run Download and Prepare Upgrade Files"
      return 1
    fi
  fi
  if [[ "$mode" == "PHASE2_ONLY" ]] && declare -F mm_client_files_ready_phase2 >/dev/null 2>&1; then
    if ! mm_client_files_ready_phase2 "${MM_CLIENT_ROOT:-}" >/dev/null 2>&1; then
      MM_WF_BLOCK_REASON="phase2_wrapper_missing"
      MM_WF_REQUIRED_ACTION="Run Download and Prepare Upgrade Files"
      return 1
    fi
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Command file validation + atomic publish
# ---------------------------------------------------------------------------
# Reconstruct a controlled backslash-continued command block for inspection
# (does not execute). Removes only: trailing \ + newline + continuation indent.
mm_wf_reconstruct_command_block() {
  local block="$1"
  printf '%s\n' "$block" | sed -E 's/\\[[:space:]]*$//' | sed -E 's/^[[:space:]]+//' | tr -d '\n'
  printf '\n'
}

# Validate the upgrade-phase2.sh WRAPPER_V1 one-liner.
mm_wf_validate_phase2_wrapper_at() {
  local file="$1" expected_mirror="${2:-}"
  local line wrapper download_name
  line="$(grep -E '^cd /home/aella && curl -fsSLo upgrade-phase2\.sh\.download ' "$file" | head -1 || true)"
  [[ -n "$line" ]] || {
    printf 'COMMAND_FILE_PHASE2_WRAPPER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_PHASE2_WRAPPER_MISSING=YES\n'
    return 1
  }
  if [[ "$line" =~ \\[[:space:]]*$ ]]; then
    printf 'COMMAND_FILE_PHASE2_WRAPPER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_PHASE2_WRAPPER_BACKSLASH=YES\n'
    return 1
  fi
  wrapper="upgrade-phase2.sh"
  download_name="${wrapper}.download"
  printf '%s\n' "$line" | grep -qE "'[0-9A-Fa-f]{64}'" || {
    printf 'COMMAND_FILE_PHASE2_WRAPPER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_PHASE2_WRAPPER_SHA_PINNING=FAIL\n'
    return 1
  }
  printf '%s\n' "$line" | grep -qE "sha256sum -c - && mv -f ${download_name} ${wrapper} && bash \./${wrapper}" || {
    printf 'COMMAND_FILE_PHASE2_WRAPPER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_PHASE2_WRAPPER_SHA_PINNING=FAIL\n'
    return 1
  }
  if printf '%s\n' "$line" | grep -qE 'curl[^|;]*\|[[:space:]]*(bash|sh)([[:space:]]|$)'; then
    printf 'COMMAND_FILE_PHASE2_WRAPPER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_CURL_PIPE_BASH=YES\n'
    return 1
  fi
  if printf '%s\n' "$line" | grep -qE '\.sha256|for F in|BASH_SUBSHELL|mktemp|phase2-helper-generation\.manifest'; then
    printf 'COMMAND_FILE_PHASE2_WRAPPER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_PHASE2_LEGACY_BOOTSTRAP=YES\n'
    return 1
  fi
  if [[ -n "$expected_mirror" ]]; then
    printf '%s\n' "$line" | grep -Fq "${expected_mirror%/}/client/${wrapper}" || {
      printf 'COMMAND_FILE_PHASE2_WRAPPER_VALIDATION=FAIL\n'
      printf 'COMMAND_FILE_PHASE2_WRAPPER_MIRROR_URL=FAIL\n'
      return 1
    }
  fi
  printf 'COMMAND_FILE_PHASE2_WRAPPER_SHA_PINNING=PASS\n'
  return 0
}

# Validate one OS-hop WRAPPER_V1 one-line command at file line number.
# Prints evidence; returns 0 on PASS.
mm_wf_validate_os_hop_launcher_at() {
  local file="$1" start_line="$2" expected_hop="${3:-}" expected_mirror="${4:-}"
  local line wrapper sha download_name url_part
  line="$(sed -n "${start_line}p" "$file")"
  [[ -n "$line" ]] || {
    printf 'COMMAND_FILE_OS_HOP_LAUNCHER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_HOP_LAUNCHER_EMPTY=YES\n'
    return 1
  }
  # Exactly one physical line: no backslash continuation, no subshell block.
  if [[ "$line" =~ \\[[:space:]]*$ ]]; then
    printf 'COMMAND_FILE_OS_HOP_LAUNCHER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_HOP_LAUNCHER_BACKSLASH=YES\n'
    return 1
  fi
  [[ "$line" != '('* ]] || {
    printf 'COMMAND_FILE_OS_HOP_LAUNCHER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_OS_HOP_LEGACY_BLOCK=YES\n'
    return 1
  }
  printf '%s\n' "$line" | grep -qE '^cd /home/aella && ' || {
    printf 'COMMAND_FILE_OS_HOP_LAUNCHER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_HOP_LAUNCHER_PREFIX=FAIL\n'
    return 1
  }
  wrapper="$(printf '%s\n' "$line" | sed -nE 's/.*bash \.\/(upgrade-[a-z0-9-]+\.sh).*/\1/p')"
  [[ -n "$wrapper" ]] || {
    printf 'COMMAND_FILE_OS_HOP_LAUNCHER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_HOP_LAUNCHER_BASH_TARGET=MISSING\n'
    return 1
  }
  if [[ -n "$expected_hop" && "$wrapper" != "upgrade-${expected_hop}.sh" ]]; then
    printf 'COMMAND_FILE_OS_HOP_LAUNCHER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_HOP_LAUNCHER_NAME_MISMATCH=YES\n'
    return 1
  fi
  download_name="${wrapper}.download"
  printf '%s\n' "$line" | grep -qE "curl -fsSLo ${download_name} " || {
    printf 'COMMAND_FILE_OS_HOP_LAUNCHER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_HOP_LAUNCHER_DOWNLOAD_NAME=FAIL\n'
    return 1
  }
  if ! printf '%s\n' "$line" | grep -qE "'[0-9A-Fa-f]{64}'"; then
    printf 'COMMAND_FILE_OS_HOP_LAUNCHER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_LAUNCHER_SHA_PINNING=FAIL\n'
    return 1
  fi
  if ! printf '%s\n' "$line" | grep -qE "sha256sum -c - && mv -f ${download_name} ${wrapper} && bash \./${wrapper}"; then
    printf 'COMMAND_FILE_OS_HOP_LAUNCHER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_LAUNCHER_SHA_PINNING=FAIL\n'
    return 1
  fi
  # SHA verify before mv; mv before bash.
  local sha_pos mv_pos bash_pos
  sha_pos="$(python3 -c 'import sys; s=sys.argv[1]; print(s.find("sha256sum -c -"))' "$line")"
  mv_pos="$(python3 -c 'import sys; s=sys.argv[1]; n=sys.argv[2]; print(s.find(n))' "$line" "mv -f ${download_name} ${wrapper}")"
  bash_pos="$(python3 -c 'import sys; s=sys.argv[1]; n=sys.argv[2]; print(s.find(n))' "$line" "bash ./${wrapper}")"
  if [[ "$sha_pos" -lt 0 || "$mv_pos" -lt 0 || "$bash_pos" -lt 0 \
    || "$sha_pos" -ge "$mv_pos" || "$mv_pos" -ge "$bash_pos" ]]; then
    printf 'COMMAND_FILE_OS_HOP_LAUNCHER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_LAUNCHER_ORDER=FAIL\n'
    return 1
  fi
  if printf '%s\n' "$line" | grep -qE 'curl[^|;]*\|[[:space:]]*(bash|sh)([[:space:]]|$)'; then
    printf 'COMMAND_FILE_OS_HOP_LAUNCHER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_CURL_PIPE_BASH=YES\n'
    return 1
  fi
  if printf '%s\n' "$line" | grep -qE '\.sha256'; then
    printf 'COMMAND_FILE_OS_HOP_LAUNCHER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_HTTP_SIDECAR_TRUST_ANCHOR=YES\n'
    return 1
  fi
  if printf '%s\n' "$line" | grep -qE 'EXPECTED_FPR=|gpgv |GNUPGHOME=|for f in|dp-launch-'; then
    printf 'COMMAND_FILE_OS_HOP_LAUNCHER_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_OS_HOP_LEGACY_BOOTSTRAP=YES\n'
    return 1
  fi
  if [[ -n "$expected_mirror" ]]; then
    url_part="${expected_mirror%/}/client/${wrapper}"
    printf '%s\n' "$line" | grep -Fq "$url_part" || {
      printf 'COMMAND_FILE_OS_HOP_LAUNCHER_VALIDATION=FAIL\n'
      printf 'COMMAND_FILE_HOP_LAUNCHER_MIRROR_URL=FAIL\n'
      return 1
    }
  fi
  return 0
}

# Legacy name kept for callers; rejects three-line OS-hop blocks.
mm_wf_validate_os_hop_block_at() {
  local file="$1" start_line="$2"
  local l1
  l1="$(sed -n "${start_line}p" "$file")"
  if [[ "$l1" == '('* ]]; then
    printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_OS_HOP_LEGACY_BLOCK=YES\n'
    return 1
  fi
  mm_wf_validate_os_hop_launcher_at "$file" "$start_line"
}

mm_wf_validate_command_file_content() {
  # Args: file mode(FULL|PHASE2_ONLY)
  # Prints COMMAND_FILE_* evidence lines; returns 0 only when structure is valid.
  local file="$1" mode="$2"
  local lines exec_count hop_count stage_count bringup_count
  local xenial bionic focal jammy
  local max_phys=0 max_block_lines=0 block_count=0 hop_block_count=0
  local lineno line
  local -a hop_starts=()
  local launcher_count=0 legacy_hop_count=0
  local mirror_url="${MIRROR_HTTP_URL:-}"

  if [[ ! -f "$file" || ! -s "$file" ]]; then
    printf 'COMMAND_FILE_BUILD=FAIL\n'
    printf 'COMMAND_FILE_EMPTY=YES\n'
    return 1
  fi

  if ! grep -qE '^DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2$' "$file"; then
    printf 'COMMAND_FILE_BUILD=FAIL\n'
    printf 'COMMAND_FILE_BLOCK_VERSION=FAIL\n'
    printf 'COMMAND_FILE_LEGACY_NON_SUBSHELL=YES\n'
    return 1
  fi
  printf 'DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2\n'
  printf 'COMMAND_FILE_PHASE2_BLOCK_VERSION=SUBSHELL_V2\n'

  lines="$(wc -l <"$file" | tr -d ' ')"
  # Legacy Phase 2 subshell copy blocks must not appear in operator commands.
  exec_count="$(grep -cE '^\( .*cd /home/aella && ' "$file" || true)"
  hop_count="$(grep -cE "^cd /home/aella && curl -fsSLo upgrade-(xenial-to-bionic|bionic-to-focal|focal-to-jammy|jammy-to-noble)\.sh\.download " "$file" || true)"
  launcher_count="$hop_count"
  legacy_hop_count="$(grep -cE "^\( .*HOP='(xenial-to-bionic|bionic-to-focal|focal-to-jammy|jammy-to-noble)'" "$file" || true)"
  legacy_hop_count=$((legacy_hop_count + $(grep -cE '^cd /home/aella && curl -fsSLo dp-launch-' "$file" || true)))
  stage_count="$(grep -cE '^cd /home/aella && curl -fsSLo upgrade-phase2\.sh\.download ' "$file" || true)"
  bringup_count="$(grep -cE 'bringup_py3_dp_after_os_upgrade\.sh' "$file" || true)"
  xenial="$(grep -cE '^cd /home/aella && curl -fsSLo upgrade-xenial-to-bionic\.sh\.download ' "$file" || true)"
  bionic="$(grep -cE '^cd /home/aella && curl -fsSLo upgrade-bionic-to-focal\.sh\.download ' "$file" || true)"
  focal="$(grep -cE '^cd /home/aella && curl -fsSLo upgrade-focal-to-jammy\.sh\.download ' "$file" || true)"
  jammy="$(grep -cE '^cd /home/aella && curl -fsSLo upgrade-jammy-to-noble\.sh\.download ' "$file" || true)"

  block_count="$exec_count"
  hop_block_count="$hop_count"

  max_phys=0
  lineno=0
  hop_starts=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    [[ ${#line} -gt "$max_phys" ]] && max_phys=${#line}
    if [[ "$line" == 'cd /home/aella && curl -fsSLo upgrade-'*'.download '* \
      && "$line" != 'cd /home/aella && curl -fsSLo upgrade-phase2.sh.download '* ]]; then
      hop_starts+=("$lineno")
    fi
  done <"$file"

  printf 'COMMAND_FILE_MODE=%s\n' "$mode"
  printf 'COMMAND_FILE_LINE_COUNT=%s\n' "$lines"
  printf 'COMMAND_FILE_EXECUTABLE_COUNT=%s\n' "$((stage_count + hop_count))"
  printf 'COMMAND_FILE_COMMAND_BLOCK_COUNT=%s\n' "$block_count"
  printf 'COMMAND_FILE_OS_HOP_COUNT=%s\n' "$hop_count"
  printf 'COMMAND_FILE_OS_HOP_BLOCK_COUNT=%s\n' "$hop_block_count"
  printf 'COMMAND_FILE_OS_HOP_LAUNCHER_COUNT=%s\n' "$launcher_count"
  printf 'COMMAND_FILE_OS_HOP_LEGACY_BLOCK_COUNT=%s\n' "$legacy_hop_count"
  printf 'COMMAND_FILE_MAX_PHYSICAL_LINE_LENGTH=%s\n' "$max_phys"

  if grep -qE 'curl[^|;]*\|[[:space:]]*(bash|sh)([[:space:]]|$)' "$file"; then
    printf 'COMMAND_FILE_BUILD=FAIL\n'
    printf 'COMMAND_FILE_CURL_PIPE_BASH=YES\n'
    return 1
  fi
  if grep -qE 'BASH_SUBSHELL|DP_COMMAND_SUBSHELL_REQUIRED=YES|for F in' "$file"; then
    printf 'COMMAND_FILE_BUILD=FAIL\n'
    printf 'COMMAND_FILE_PHASE2_LEGACY_SUBSHELL=YES\n'
    return 1
  fi

  case "$mode" in
    FULL)
      if ! grep -qE '^DP_OS_HOP_COMMAND_VERSION=WRAPPER_V1$' "$file"; then
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_OS_HOP_COMMAND_VERSION=FAIL\n'
        return 1
      fi
      printf 'DP_OS_HOP_COMMAND_VERSION=WRAPPER_V1\n'
      for n in 0 1 2 3 4 5 6 7 8 9; do
        if ! grep -qE "STEP ${n} —|Step ${n} —" "$file"; then
          printf 'COMMAND_FILE_BUILD=FAIL\n'
          printf 'COMMAND_FILE_MISSING_STEP=%s\n' "$n"
          return 1
        fi
      done
      if [[ "$legacy_hop_count" -ne 0 ]]; then
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_OS_HOP_LEGACY_BLOCK_COUNT=%s\n' "$legacy_hop_count"
        return 1
      fi
      if [[ "$hop_count" -ne 4 ]]; then
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_OS_HOP_COUNT=%s\n' "$hop_count"
        printf 'COMMAND_FILE_OS_HOP_LAUNCHER_VALIDATION=FAIL\n'
        return 1
      fi
      [[ "$xenial" -eq 1 && "$bionic" -eq 1 && "$focal" -eq 1 && "$jammy" -eq 1 ]] || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_HOP_COVERAGE=FAIL\n'
        return 1
      }
      [[ "$stage_count" -eq 1 ]] || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_PHASE2_STAGE_COUNT=%s\n' "$stage_count"
        return 1
      }
      if [[ "$bringup_count" -lt 1 || "$bringup_count" -gt 2 ]]; then
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_BRINGUP_COUNT=%s\n' "$bringup_count"
        return 1
      fi
      # Bringup still uses sudo bash; OS-hop/Phase2 wrapper operator commands must not.
      grep -q "sudo bash" "$file" || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_SUDO_BASH=MISSING\n'
        return 1
      }
      if grep -qE "^\( .*HOP=" "$file"; then
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_OS_HOP_LEGACY_BLOCK=YES\n'
        return 1
      fi

      local hops=(xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble)
      local idx=0 hs
      for hs in "${hop_starts[@]}"; do
        if ! mm_wf_validate_os_hop_launcher_at "$file" "$hs" "${hops[$idx]}" "$mirror_url"; then
          printf 'COMMAND_FILE_BUILD=FAIL\n'
          return 1
        fi
        idx=$((idx + 1))
      done
      printf 'COMMAND_FILE_LAUNCHER_SHA_PINNING=PASS\n'

      if ! mm_wf_validate_phase2_wrapper_at "$file" "$mirror_url"; then
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        return 1
      fi

      lineno=0
      while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        if [[ "$line" =~ \\[[:space:]]*$ ]]; then
          printf 'COMMAND_FILE_BUILD=FAIL\n'
          printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
          printf 'COMMAND_FILE_ARBITRARY_BACKSLASH=YES\n'
          printf 'COMMAND_FILE_ARBITRARY_BACKSLASH_LINE=%s\n' "$lineno"
          return 1
        fi
      done <"$file"
      max_block_lines=1
      ;;
    PHASE2_ONLY)
      if [[ "$hop_count" -ne 0 || "$legacy_hop_count" -ne 0 ]]; then
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_OS_HOP_COUNT=%s\n' "$hop_count"
        printf 'COMMAND_FILE_OS_HOP_LAUNCHER_COUNT=%s\n' "$launcher_count"
        return 1
      fi
      printf 'COMMAND_FILE_OS_HOP_LAUNCHER_COUNT=0\n'
      printf 'COMMAND_FILE_OS_HOP_LEGACY_BLOCK_COUNT=0\n'
      grep -q 'Required OS: Ubuntu 24.04' "$file" || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_REQUIRED_OS=MISSING\n'
        return 1
      }
      [[ "$stage_count" -eq 1 ]] || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_PHASE2_STAGE_COUNT=%s\n' "$stage_count"
        return 1
      }
      if [[ "$bringup_count" -lt 1 || "$bringup_count" -gt 2 ]]; then
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_BRINGUP_COUNT=%s\n' "$bringup_count"
        return 1
      fi
      grep -q "sudo bash" "$file" || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_SUDO_BASH=MISSING\n'
        return 1
      }
      max_block_lines=1
      if ! mm_wf_validate_phase2_wrapper_at "$file" "$mirror_url"; then
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        return 1
      fi
      lineno=0
      while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        if [[ "$line" =~ \\[[:space:]]*$ ]]; then
          printf 'COMMAND_FILE_BUILD=FAIL\n'
          printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
          return 1
        fi
      done <"$file"
      ;;
    *)
      printf 'COMMAND_FILE_BUILD=FAIL\n'
      printf 'COMMAND_FILE_MODE_INVALID=%s\n' "$mode"
      return 1
      ;;
  esac

  printf 'COMMAND_FILE_MAX_BLOCK_LINES=%s\n' "$max_block_lines"
  printf 'COMMAND_FILE_CONTINUATION_VALIDATION=PASS\n'
  printf 'COMMAND_FILE_BUILD=PASS\n'
  return 0
}

mm_wf_atomic_publish_command_file() {
  # Args: tmp_file dest_file mode readiness_generation_id
  local tmp="$1" dest="$2" mode="$3" ready_gen="$4"
  local evidence sha
  evidence="$(mktemp)"
  if ! mm_wf_validate_command_file_content "$tmp" "$mode" | tee "$evidence"; then
    printf 'COMMAND_FILE_ATOMIC_PUBLISH=FAIL\n'
    cat "$evidence"
    rm -f "$evidence"
    return 1
  fi
  sha="$(sha256sum "$tmp" | awk '{print $1}')"
  mkdir -p "$(dirname "$dest")"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$dest"
  chmod 0644 "$dest"
  mm_wf_mark_commands_generated "$ready_gen"
  printf 'COMMAND_FILE_BUILD=PASS\n'
  printf 'COMMAND_FILE_MODE=%s\n' "$mode"
  printf 'COMMAND_FILE_GENERATION_ID=%s\n' "$ready_gen"
  printf 'COMMAND_FILE_SHA256=%s\n' "$sha"
  printf 'COMMAND_FILE_ATOMIC_PUBLISH=PASS\n'
  printf 'COMMAND_FILE_VALID_FOR_READINESS_GENERATION=%s\n' "$ready_gen"
  # Re-emit counts from evidence
  grep -E '^COMMAND_FILE_(LINE|EXECUTABLE|OS_HOP|COMMAND_BLOCK|OS_HOP_BLOCK|OS_HOP_LAUNCHER|OS_HOP_LEGACY_BLOCK)_COUNT=' "$evidence" || true
  grep -E '^COMMAND_FILE_(MAX_BLOCK_LINES|MAX_PHYSICAL_LINE_LENGTH|CONTINUATION_VALIDATION|LAUNCHER_SHA_PINNING|PHASE2_BLOCK_VERSION)=' "$evidence" || true
  grep -E '^DP_(COMMAND_BLOCK_VERSION|OS_HOP_COMMAND_VERSION)=' "$evidence" || true
  rm -f "$evidence"
  return 0
}

# Write client-set generation metadata into a published client root.
mm_wf_write_client_set_metadata() {
  local dest="$1" gen="$2" fpr="$3" mirror_url="$4" mode="$5"
  local input_sha="${6:-}" source_rev="${7:-}" runtime_sha="${8:-}"
  local builders_sha="${9:-}" templates_sha="${10:-}" helpers_sha="${11:-}"
  local runner_sha="${12:-}" command_ver="${13:-SUBSHELL_V2}"
  local schema_ver="${14:-1}" tree_state="${15:-}" mirror_pin="${16:-${mirror_url}}"
  local created_utc="${17:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  local launcher_schema="${18:-${CLIENT_LAUNCHER_SCHEMA_VERSION:-1}}"
  local meta="${dest}/client-set.env"
  local hop lname lsha meta_key wname wsha wkey
  cat >"${meta}.tmp" <<EOF
CLIENT_SET_GENERATION_ID=${gen}
CLIENT_SIGNING_FINGERPRINT=${fpr}
MIRROR_HTTP_URL=${mirror_url}
PREPARATION_MODE=${mode}
PHASE2_TARGET_VERSION=${PHASE2_TARGET_VERSION:-6.6.0}
CLIENT_PROVENANCE_SCHEMA_VERSION=${schema_ver}
CLIENT_BUILD_INPUT_SHA256=${input_sha}
CLIENT_SOURCE_REVISION=${source_rev}
CLIENT_SOURCE_TREE_STATE=${tree_state}
CLIENT_RUNTIME_MANIFEST_SHA256=${runtime_sha}
CLIENT_BUILDERS_SHA256=${builders_sha}
CLIENT_TEMPLATES_SHA256=${templates_sha}
CLIENT_SHARED_HELPERS_SHA256=${helpers_sha}
CLIENT_RUNNER_SHA256=${runner_sha}
CLIENT_COMMAND_BLOCK_VERSION=${command_ver}
CLIENT_LAUNCHER_SCHEMA_VERSION=${launcher_schema}
CLIENT_MIRROR_BASE_URL=${mirror_pin}
CLIENT_BUILD_CREATED_UTC=${created_utc}
CREATED_UTC=${created_utc}
EOF
  for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
    lname="dp-launch-${hop}.sh"
    if [[ -f "${dest}/${lname}.sha256" ]]; then
      lsha="$(awk '{print $1; exit}' "${dest}/${lname}.sha256")"
      meta_key="CLIENT_LAUNCHER_$(printf '%s' "$hop" | tr 'a-z-' 'A-Z_')_SHA256"
      printf '%s=%s\n' "$meta_key" "$lsha" >>"${meta}.tmp"
    fi
    wname="upgrade-${hop}.sh"
    if [[ -f "${dest}/${wname}.sha256" ]]; then
      wsha="$(awk '{print $1; exit}' "${dest}/${wname}.sha256")"
      wkey="CLIENT_WRAPPER_$(printf '%s' "$hop" | tr 'a-z-' 'A-Z_')_SHA256"
      printf '%s=%s\n' "$wkey" "$wsha" >>"${meta}.tmp"
    fi
  done
  if [[ -f "${dest}/upgrade-phase2.sh.sha256" ]]; then
    printf 'CLIENT_WRAPPER_PHASE2_SHA256=%s\n' \
      "$(awk '{print $1; exit}' "${dest}/upgrade-phase2.sh.sha256")" >>"${meta}.tmp"
  fi
  chmod 0644 "${meta}.tmp"
  mv -f "${meta}.tmp" "$meta"
  chmod 0644 "$meta"
}

# Xenial-compatible fingerprint extraction from a binary keyring file.
# Prints uppercase 40-hex primary fingerprint or fails.
mm_wf_keyring_fingerprint() {
  local keyring="$1"
  local fpr
  [[ -f "$keyring" && -s "$keyring" ]] || return 1
  # Prefer --with-colons (available on Xenial GnuPG 1.4+/2.x).
  fpr="$(gpg --batch --no-default-keyring --keyring "$keyring" \
    --with-colons --fingerprint 2>/dev/null \
    | awk -F: '/^fpr:/{print $10; exit}')"
  if [[ -z "$fpr" ]]; then
    fpr="$(gpg --batch --no-default-keyring --keyring "$keyring" \
      --fingerprint 2>/dev/null \
      | awk '/key fingerprint =/{gsub(/ /,"",$0); sub(/^.*=/,"",$0); print; exit}')"
  fi
  [[ -n "$fpr" ]] || return 1
  fpr="${fpr^^}"
  fpr="${fpr// /}"
  [[ ${#fpr} -eq 40 ]] || return 1
  printf '%s\n' "$fpr"
}
