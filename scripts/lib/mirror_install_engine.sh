#!/usr/bin/env bash
# scripts/lib/mirror_install_engine.sh — R2+ACPS (FULL) or ACPS-only (PHASE2_ONLY)
# Preparation mode comes from GUI config. No current/previous/release lifecycle.
# shellcheck shell=bash
set +x

if [[ -n "${MIRROR_INSTALL_ENGINE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
MIRROR_INSTALL_ENGINE_LOADED=1

# Requires: mirror_manager_common.sh, dp-phase2-common.sh, acps_acquire.sh, r2_acquire.sh

engine_preflight_host() {
  mm_require_root
  mm_require_cmds bash curl tar sha1sum sha256sum awk flock stat df readlink mv ln find mkdir chmod python3 mktemp sed grep gpg
  mm_ok "PREFLIGHT_HOST=PASS"
}

# Authoritative local client-set rebuild/sign/atomic-publish entrypoint.
# Used by Download and Prepare finalization, Enable HTTP, and repair paths.
# Arg1: SKIP_HTTP_VERIFY (default 1 — nginx may still be disabled during prepare).
# Builds from local selective filesystem only; MIRROR_HTTP_URL is a runtime pin.
engine_rebuild_publish_local_client_set() {
  local skip_http="${1:-1}"
  local rebuild="${MM_PROJECT_ROOT}/scripts/rebuild-publish-clients.sh"
  local mirror_url libdir
  local staging_root signing_dir generation_id evidence_log
  local rc=0
  local child_out=""
  local failed_hop="" failed_stage="" error_summary=""

  [[ -f "$rebuild" ]] || {
    mm_error "CLIENT_FINALIZER_MISSING=${rebuild}"
    return 1
  }
  libdir="${MM_PROJECT_ROOT}/scripts/lib"
  # shellcheck source=local_client_signing.sh
  source "${libdir}/local_client_signing.sh"

  mm_set_phase "Building Local OS Upgrade Clients"
  if ! mirror_url="$(mm_client_mirror_url)"; then
    mm_error "CLIENT_SET_MIRROR_URL=FAIL"
    return 1
  fi
  MIRROR_HTTP_URL="$mirror_url"
  export MIRROR_HTTP_URL

  signing_dir="${LOCAL_CLIENT_SIGNING_DIR:-${MM_CONFIG_DIR}/client-signing}"
  LOCAL_CLIENT_SIGNING_DIR="$signing_dir"
  export LOCAL_CLIENT_SIGNING_DIR
  local_signing_ensure_keypair || {
    mm_error "CLIENT_SET_SIGNING_KEY=FAIL"
    return 1
  }

  generation_id="$(mm_run_id)-$$"
  staging_root="${MM_CACHE_ROOT:-${MM_MIRROR_ROOT}/.install-cache}/client-build/${generation_id}"
  mkdir -p "$(dirname "$staging_root")" "$MM_CLIENT_ROOT"
  if [[ -n "${MM_STATE_DIR:-}" ]]; then
    evidence_log="${MM_STATE_DIR}/client-finalization-${generation_id}.log"
  else
    mkdir -p /var/log/ubuntu-mirror-automation 2>/dev/null || true
    evidence_log="/var/log/ubuntu-mirror-automation/client-finalization-${generation_id}.log"
    if [[ ! -d "$(dirname "$evidence_log")" ]] || [[ ! -w "$(dirname "$evidence_log")" ]]; then
      evidence_log="${MM_CACHE_ROOT:-${MM_MIRROR_ROOT}/.install-cache}/client-finalization-${generation_id}.log"
      mkdir -p "$(dirname "$evidence_log")"
    fi
  fi

  mm_set_phase "Signing Local OS Upgrade Clients"
  mm_info "CLIENT_FINALIZATION_ENTRYPOINT=rebuild-publish-clients.sh"
  mm_info "PARTIAL_CLIENT_DEPLOY_ALLOWED=NO"
  mm_info "STALE_CLIENT_COPY_ALLOWED=NO"
  mm_info "CLIENT_BUILD_CONTENT_SOURCE=LOCAL_FILESYSTEM"
  mm_info "CLIENT_BUILD_NETWORK_REQUIRED=NO"
  mm_info "CLIENT_BUILD_GENERATION_ID=${generation_id}"
  mm_info "CLIENT_BUILD_STAGING_PATH=${staging_root}"
  mm_info "CLIENT_FINALIZER_COMMAND_START"

  mm_set_phase "Publishing Local Client Set"
  set +e
  child_out="$(
    env \
      MIRROR_HTTP_URL="$MIRROR_HTTP_URL" \
      RESOLVED_MIRROR_BASE_URL="${RESOLVED_MIRROR_BASE_URL:-$MIRROR_HTTP_URL}" \
      LOCAL_CLIENT_SIGNING_DIR="$LOCAL_CLIENT_SIGNING_DIR" \
      CLIENT_HTTP_ROOT="${MM_CLIENT_ROOT}" \
      SELECTIVE_ROOT="${MM_SELECTIVE_ROOT}" \
      BASE_PATH="${MM_MIRROR_ROOT}" \
      CACHE_ROOT="${MM_CACHE_ROOT:-${MM_MIRROR_ROOT}/.install-cache}" \
      ARTIFACT_DIR="$staging_root" \
      CLIENT_BUILD_GENERATION_ID="$generation_id" \
      CLIENT_FINALIZATION_EVIDENCE_LOG="$evidence_log" \
      CONTENT_SOURCE=local-fs \
      SKIP_HTTP_VERIFY="$skip_http" \
      bash "$rebuild" 2>&1
  )"
  rc=$?
  set -e

  # Persist child output (redacted) and surface key lines.
  {
    printf '%s\n' "$child_out"
  } | mm_redact >>"$evidence_log" 2>/dev/null || printf '%s\n' "$child_out" >>"$evidence_log"
  chmod 0600 "$evidence_log" 2>/dev/null || true

  failed_hop="$(printf '%s\n' "$child_out" | sed -n 's/^CLIENT_BUILD_FAILED_HOP=//p' | tail -1)"
  failed_stage="$(printf '%s\n' "$child_out" | sed -n 's/^CLIENT_BUILD_FAILED_STAGE=//p' | tail -1)"
  error_summary="$(printf '%s\n' "$child_out" | grep -E '^(CLIENT_BUILD_ERROR=|BuildError|Traceback|Error:|CLIENT_SET_ERROR=)' | tail -3 | tr '\n' '|' | sed 's/|$//')"
  [[ -n "$error_summary" ]] || error_summary="$(printf '%s\n' "$child_out" | tail -5 | tr '\n' '|' | sed 's/|$//')"

  mm_info "CLIENT_FINALIZER_COMMAND_EXIT_CODE=${rc}"
  mm_info "CLIENT_FINALIZER_EVIDENCE_PATH=${evidence_log}"
  if [[ -n "$failed_hop" ]]; then
    mm_info "CLIENT_FINALIZER_FAILED_HOP=${failed_hop}"
  fi
  if [[ -n "$failed_stage" ]]; then
    mm_info "CLIENT_FINALIZER_FAILED_STAGE=${failed_stage}"
  fi

  if [[ "$rc" -ne 0 ]]; then
    mm_error "CLIENT_SET_REBUILD_PUBLISH=FAIL"
    mm_error "CLIENT_FINALIZER_ERROR_SUMMARY=${error_summary}"
    # Show last relevant evidence lines on the live terminal.
    printf '%s\n' "$child_out" | grep -E 'ERROR|FAIL|Traceback|BuildError|CLIENT_BUILD_' | tail -20 \
      | while IFS= read -r line; do mm_error "$line"; done || true
    return 1
  fi

  # Propagate important success markers from child.
  printf '%s\n' "$child_out" | grep -E '^(CLIENT_SET_|ALL_FOUR_|CLIENT_BUILD_|CLIENT_HTTP_|REBUILD_PUBLISH)' \
    | while IFS= read -r line; do mm_info "$line"; done || true

  if [[ "$skip_http" != "1" ]]; then
    mm_set_phase "Verifying Local HTTP Clients"
    mm_info "CLIENT_HTTP_READY=PASS"
  else
    mm_set_phase "Verifying Local Client Files"
    mm_info "CLIENT_HTTP_READY=DEFERRED"
    mm_info "CLIENT_HTTP_VERIFY=DEFERRED_UNTIL_ENABLE_HTTP"
    mm_info "CLIENT_SET_ON_DISK_READY=PASS"
  fi
  return 0
}

# Ensure Phase 2 helper scripts are published (no OS-hop clients).
engine_ensure_phase2_helpers() {
  local root="${MM_PROJECT_ROOT}"
  local dest="${MM_CLIENT_ROOT}"
  local stage f

  if mm_phase2_helpers_ready "$dest"; then
    mm_check_phase2_helpers_ready
    return 0
  fi

  mkdir -p "$dest"
  stage="$(mktemp -d "${dest}.helpers.XXXXXX")"
  chmod 0755 "$stage"
  for f in stage-dp-phase2.sh stage-dp-phase2-6.6.0.sh stage-dp-phase2-6.5.0.sh bringup_py3_dp_lifecycle.sh; do
    if [[ -f "${root}/client/${f}" ]]; then
      install -m 0755 "${root}/client/${f}" "${stage}/${f}"
      ( cd "$stage" && sha256sum "$f" >"${f}.sha256" )
    fi
  done
  if [[ -d "${root}/client/lib" ]]; then
    mkdir -p "${stage}/lib"
    chmod 0755 "${stage}/lib"
    cp -a "${root}/client/lib/." "${stage}/lib/"
  fi
  if [[ -f "${root}/scripts/lib/phase2_helper_generation.sh" ]]; then
    # shellcheck source=/dev/null
    source "${root}/scripts/lib/phase2_helper_generation.sh"
    if ! phase2_helper_generation_write "$stage" >/dev/null; then
      rm -rf "$stage"
      return 1
    fi
  else
    rm -rf "$stage"
    return 1
  fi
  local mirror="${MIRROR_HTTP_URL:-${RESOLVED_MIRROR_BASE_URL:-}}"
  mirror="${mirror%/}"
  if [[ -z "$mirror" ]] && declare -F mm_client_mirror_url >/dev/null 2>&1; then
    mirror="$(mm_client_mirror_url 2>/dev/null || true)"
    mirror="${mirror%/}"
  fi
  if [[ -z "$mirror" ]]; then
    rm -rf "$stage"
    return 1
  fi
  local bundle_sha=""
  bundle_sha="$(phase2_published_bundle_sha256 "${PHASE2_TARGET_VERSION:-6.6.0}" 2>/dev/null || true)"
  if ! phase2_upgrade_wrapper_write "$stage" "$mirror" \
    "${PHASE2_TARGET_VERSION:-6.6.0}" "$bundle_sha" >/dev/null
  then
    rm -rf "$stage"
    return 1
  fi
  if declare -F mm_normalize_http_public_tree_permissions >/dev/null 2>&1; then
    mm_normalize_http_public_tree_permissions "$stage" client || {
      rm -rf "$stage"
      return 1
    }
  else
    chmod 0755 "$stage"
  fi
  chmod 0755 "$dest" 2>/dev/null || true
  cp -a "${stage}/." "$dest/"
  rm -rf "$stage"
  if declare -F mm_normalize_http_public_tree_permissions >/dev/null 2>&1; then
    mm_normalize_http_public_tree_permissions "$dest" client || true
  fi
  mm_check_phase2_helpers_ready
}

# Decide whether the existing hop client set can be reused or must be rebuilt.
# Sets: CLIENT_SET_STATE, CLIENT_SET_ACTION, CLIENT_SET_PRESENT_AT_START
engine_assess_client_set_for_finalize() {
  local root="${MM_CLIENT_ROOT}"
  local n mirror_url hop name
  local pin_ok=1

  CLIENT_SET_PRESENT_AT_START=NO
  CLIENT_SET_STATE=ABSENT
  CLIENT_SET_ACTION=REBUILD_SIGN_PUBLISH

  n="$(mm_count_published_hop_clients "$root")"
  if [[ "$n" -eq 0 ]]; then
    CLIENT_SET_STATE=ABSENT
    CLIENT_SET_ACTION=REBUILD_SIGN_PUBLISH
    return 0
  fi
  if [[ "$n" -lt 4 ]]; then
    CLIENT_SET_STATE=PARTIAL_OR_MIXED
    CLIENT_SET_ACTION=REBUILD_FULL_SET
    CLIENT_SET_PRESENT_AT_START=YES
    return 0
  fi

  CLIENT_SET_PRESENT_AT_START=YES
  if ! mm_client_files_ready "$root"; then
    CLIENT_SET_STATE=PARTIAL_OR_MIXED
    CLIENT_SET_ACTION=REBUILD_FULL_SET
    return 0
  fi

  mirror_url="$(mm_client_mirror_url 2>/dev/null || true)"
  mirror_url="${mirror_url%/}"
  if [[ -z "$mirror_url" ]]; then
    CLIENT_SET_STATE=INVALID_PIN
    CLIENT_SET_ACTION=REBUILD_SIGN_PUBLISH
    return 0
  fi

  # shellcheck source=client_mirror_gates.sh
  source "${MM_PROJECT_ROOT}/scripts/lib/client_mirror_gates.sh"
  for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
    name="dp-offline-upgrade-${hop}.sh"
    if ! client_assert_mirror_base_match "${root}/${name}" "$mirror_url" >/dev/null 2>&1; then
      pin_ok=0
      break
    fi
  done
  if [[ "$pin_ok" -ne 1 ]]; then
    CLIENT_SET_STATE=STALE_OR_WRONG_PIN
    CLIENT_SET_ACTION=REBUILD_SIGN_PUBLISH
    return 0
  fi

  local provenance_out provenance_rc=0 state_line action_line reason_line expected_fpr=""
  if [[ -f "${MM_CONFIG_DIR}/client-signing/fingerprint" ]]; then
    expected_fpr="$(tr -d '[:space:]' <"${MM_CONFIG_DIR}/client-signing/fingerprint" | tr '[:lower:]' '[:upper:]')"
  elif [[ -n "${LOCAL_KEY_FINGERPRINT:-}" ]]; then
    expected_fpr="${LOCAL_KEY_FINGERPRINT}"
  fi
  set +e
  provenance_out="$(python3 "${MM_PROJECT_ROOT}/scripts/lib/client_build_provenance.py" classify-client-set \
    --project-root "$MM_PROJECT_ROOT" \
    --client-root "$root" \
    --expected-mirror "$mirror_url" \
    --expected-fingerprint "$expected_fpr" \
    --expected-mode "${PREPARATION_MODE:-FULL}" 2>&1)"
  provenance_rc=$?
  set -e
  state_line="$(printf '%s\n' "$provenance_out" | awk -F= '$1=="CLIENT_SET_STATE"{print $2; exit}')"
  action_line="$(printf '%s\n' "$provenance_out" | awk -F= '$1=="CLIENT_SET_ACTION"{print $2; exit}')"
  reason_line="$(printf '%s\n' "$provenance_out" | awk -F= '$1=="CLIENT_SET_REASON"{print substr($0,index($0,"=")+1); exit}')"
  if [[ -z "$state_line" ]]; then
    if [[ "$provenance_rc" -eq 0 ]]; then
      state_line=CURRENT_VERIFIED
      action_line=REUSE_CURRENT
    else
      state_line=STALE_BUILD_INPUT
      action_line=REBUILD_SIGN_PUBLISH
    fi
  fi
  CLIENT_SET_STATE="$state_line"
  CLIENT_SET_ACTION="$action_line"
  # Compatibility aliases used by older callers/tests.
  if [[ "$CLIENT_SET_ACTION" == "REUSE_VERIFIED" ]]; then
    CLIENT_SET_ACTION=REUSE_CURRENT
  fi
  printf '%s\n' "$provenance_out" | while IFS= read -r line; do
    [[ -n "$line" ]] && mm_info "$line"
  done || true
  [[ -n "$reason_line" ]] && mm_info "CLIENT_SET_REASON=${reason_line}"
  return 0
}
engine_bind_reused_client_set_workflow() {
  local meta="${MM_CLIENT_ROOT}/client-set.env"
  local gen fpr input_sha source_rev runtime_sha command_ver schema_ver
  [[ -f "$meta" ]] || return 1
  # Reject duplicate authoritative keys (no first/last-wins ambiguity).
  mm_parse_env_metadata_get "$meta" >/dev/null || return 1
  gen="$(mm_parse_env_metadata_get "$meta" CLIENT_SET_GENERATION_ID)" || return 1
  fpr="$(mm_parse_env_metadata_get "$meta" CLIENT_SIGNING_FINGERPRINT)" || return 1
  input_sha="$(mm_parse_env_metadata_get "$meta" CLIENT_BUILD_INPUT_SHA256)" || return 1
  source_rev="$(mm_parse_env_metadata_get "$meta" CLIENT_SOURCE_REVISION 2>/dev/null || true)"
  [[ -z "$source_rev" ]] && source_rev="$(mm_parse_env_metadata_get "$meta" CLIENT_BUILD_SOURCE_REVISION 2>/dev/null || true)"
  runtime_sha="$(mm_parse_env_metadata_get "$meta" CLIENT_RUNTIME_MANIFEST_SHA256 2>/dev/null || true)"
  command_ver="$(mm_parse_env_metadata_get "$meta" CLIENT_COMMAND_BLOCK_VERSION 2>/dev/null || true)"
  schema_ver="$(mm_parse_env_metadata_get "$meta" CLIENT_PROVENANCE_SCHEMA_VERSION 2>/dev/null || true)"
  [[ -n "$gen" && -n "$fpr" && -n "$input_sha" ]] || return 1
  mm_wf_mark_client_set_published "$gen" "$fpr" "$input_sha" "$source_rev" "$runtime_sha" "$command_ver" "$schema_ver"
  mm_info "CLIENT_SET_WORKFLOW_REBOUND=PASS CLIENT_SET_GENERATION_ID=${gen}"
}

# Post-preparation finalization: build/sign/publish clients (FULL) or helpers (PHASE2_ONLY).
# CLIENT_FILES_READY is required here — never before preparation starts.
#
# MM_CLIENT_FINALIZATION_MODE=verify-only — test/fixture hook: only verify the
# on-disk client set (used by synthetic Mirror Manager tests whose OS Core
# packages lack full hop/upgrader trees required for a real rebuild).
engine_finalize_local_client_set() {
  local os_ready=NO

  mm_normalize_preparation_mode
  if [[ "${MM_CLIENT_FINALIZATION_MODE:-full}" == "verify-only" ]]; then
    mm_info "CLIENT_FINALIZATION_MODE=verify-only"
    mm_set_phase "Verifying Local Client Files"
    if ! mm_check_client_files_ready; then
      mm_error "CLIENT_SET_FINALIZATION=FAIL"
      mm_info "PREPARATION_ARTIFACTS_READY=YES"
      mm_info "DOWNLOAD_AND_PREPARE_RESULT=FAIL_CLIENT_SET_FINALIZATION"
      return 1
    fi
    mm_ok "CLIENT_SET_FINALIZATION=PASS"
    return 0
  fi

  if mm_is_phase2_only; then
    mm_info "OS_HOP_CLIENT_FILES_REQUIRED=NO"
    mm_info "CLIENT_FILES_READY_AT_START=NOT_REQUIRED"
    mm_set_phase "Publishing Phase 2 Helper Clients"
    if ! engine_ensure_phase2_helpers; then
      mm_error "CLIENT_SET_FINALIZATION=FAIL"
      mm_info "PREPARATION_ARTIFACTS_READY=YES"
      mm_info "DOWNLOAD_AND_PREPARE_RESULT=FAIL_CLIENT_SET_FINALIZATION"
      return 1
    fi
    if ! mm_check_client_files_ready; then
      mm_error "CLIENT_SET_FINALIZATION=FAIL"
      mm_info "PREPARATION_ARTIFACTS_READY=YES"
      mm_info "DOWNLOAD_AND_PREPARE_RESULT=FAIL_CLIENT_SET_FINALIZATION"
      return 1
    fi
    mm_ok "CLIENT_SET_FINALIZATION=PASS"
    return 0
  fi

  if [[ -f "${MM_SELECTIVE_ROOT}/state/READY" ]] \
    || [[ "$(mm_status_get OS_MIRROR_READY)" == "PASS" ]]; then
    os_ready=YES
  fi
  mm_info "OS_CORE_READY_AT_FINALIZE=${os_ready}"

  if [[ "$os_ready" != "YES" ]]; then
    mm_error "CLIENT_SET_FINALIZATION=FAIL OS Core/selective not READY"
    mm_info "PREPARATION_ARTIFACTS_READY=YES"
    mm_info "DOWNLOAD_AND_PREPARE_RESULT=FAIL_CLIENT_SET_FINALIZATION"
    return 1
  fi

  # READY must exist with verified non-empty provenance checksums (created during
  # OS Core materialize from package manifest + payload.sha256, or legacy selective).
  if ! engine_verify_selective_ready_provenance; then
    mm_error "SELECTIVE_READY_VERIFY=FAIL"
    mm_error "CLIENT_SET_FINALIZATION=FAIL"
    mm_info "PREPARATION_ARTIFACTS_READY=YES"
    mm_info "DOWNLOAD_AND_PREPARE_RESULT=FAIL_CLIENT_SET_FINALIZATION"
    return 1
  fi

  engine_assess_client_set_for_finalize
  mm_info "CLIENT_SET_PRESENT_AT_START=${CLIENT_SET_PRESENT_AT_START}"
  mm_info "CLIENT_SET_STATE=${CLIENT_SET_STATE}"
  mm_info "CLIENT_SET_ACTION=${CLIENT_SET_ACTION}"

  if [[ "${CLIENT_SET_ACTION}" == "REUSE_CURRENT" || "${CLIENT_SET_ACTION}" == "REUSE_VERIFIED" ]]; then
    mm_info "CLIENT_SET_ACTION=REUSE_CURRENT"
    mm_set_phase "Verifying Local Client Files"
    if mm_check_client_files_ready && engine_bind_reused_client_set_workflow; then
      mm_info "CLIENT_SET_ON_DISK_READY=PASS"
      mm_info "CLIENT_HTTP_READY=DEFERRED"
      mm_ok "CLIENT_SET_FINALIZATION=PASS"
      return 0
    fi
    mm_warn "CLIENT_SET_REUSE_FAILED — falling through to full rebuild"
    CLIENT_SET_ACTION=REBUILD_SIGN_PUBLISH
  fi

  if [[ "${CLIENT_SET_STATE}" == "PARTIAL_OR_MIXED" ]]; then
    mm_info "CLIENT_SET_STATE=PARTIAL_OR_MIXED"
    mm_info "CLIENT_SET_ACTION=REBUILD_FULL_SET"
    mm_info "STALE_CLIENT_COPY_ALLOWED=NO"
  fi

  if ! engine_rebuild_publish_local_client_set 1; then
    mm_error "CLIENT_SET_FINALIZATION=FAIL"
    mm_info "PREPARATION_ARTIFACTS_READY=YES"
    mm_info "DOWNLOAD_AND_PREPARE_RESULT=FAIL_CLIENT_SET_FINALIZATION"
    mm_state_set CLIENT_SET_FINALIZATION FAIL
    mm_status_set DOWNLOAD_PREPARE_RESULT FAIL_CLIENT_SET_FINALIZATION
    return 1
  fi

  mm_set_phase "Verifying Local Client Files"
  if ! mm_check_client_files_ready; then
    mm_error "CLIENT_SET_FINALIZATION=FAIL"
    mm_info "PREPARATION_ARTIFACTS_READY=YES"
    mm_info "DOWNLOAD_AND_PREPARE_RESULT=FAIL_CLIENT_SET_FINALIZATION"
    mm_state_set CLIENT_SET_FINALIZATION FAIL
    mm_status_set DOWNLOAD_PREPARE_RESULT FAIL_CLIENT_SET_FINALIZATION
    return 1
  fi
  mm_info "CLIENT_SET_ON_DISK_READY=PASS"
  mm_info "CLIENT_HTTP_READY=DEFERRED"
  mm_state_set CLIENT_SET_FINALIZATION PASS
  mm_ok "CLIENT_SET_FINALIZATION=PASS"
  mm_ok "ALL_FOUR_CLIENTS_BUILT_AFTER_OS_CORE_READY=YES"
  return 0
}

engine_resolve_paths() {
  MM_MIRROR_ROOT="${MM_MIRROR_ROOT:-/var/spool/apt-mirror}"
  MM_SELECTIVE_ROOT="${MM_SELECTIVE_ROOT:-${MM_MIRROR_ROOT}/selective}"
  MM_DP_PHASE2_ROOT="${MM_DP_PHASE2_ROOT:-${MM_MIRROR_ROOT}/dp-phase2}"
  MM_CLIENT_ROOT="${MM_CLIENT_ROOT:-${MM_MIRROR_ROOT}/client}"
  DP_PHASE2_ROOT="$MM_DP_PHASE2_ROOT"
  MM_CACHE_ROOT="${MM_CACHE_ROOT:-${MM_MIRROR_ROOT}/.install-cache}"
  # GUI mode: keep path init in the log file, but do not spam the TTY
  # (operators otherwise see only these three lines when a menu action exits).
  if [[ "${MM_GUI_MODE:-0}" == "1" ]]; then
    if [[ -n "${MM_LOG_FILE:-}" ]]; then
      mkdir -p "$(dirname "$MM_LOG_FILE")" 2>/dev/null || true
      local _line
      for _line in \
        "MIRROR_ROOT=${MM_MIRROR_ROOT}" \
        "SELECTIVE_ROOT=${MM_SELECTIVE_ROOT}" \
        "DP_PHASE2_ROOT=${MM_DP_PHASE2_ROOT}"
      do
        printf '%s\n' "$(mm_ts) [INFO] ${_line}" | mm_redact >>"$MM_LOG_FILE" 2>/dev/null || true
      done
    fi
    return 0
  fi
  mm_info "MIRROR_ROOT=${MM_MIRROR_ROOT}"
  mm_info "SELECTIVE_ROOT=${MM_SELECTIVE_ROOT}"
  mm_info "DP_PHASE2_ROOT=${MM_DP_PHASE2_ROOT}"
}

engine_verify_disk_space() {
  mm_calc_disk_requirements
}

engine_assert_same_filesystem_layout() {
  # Hard links and atomic renames require one device for mirror root, cache,
  # selective, and dp-phase2. Split mounts force full copies and break the
  # 100GB-class peak model — fail closed with an explicit operator message.
  local paths=("$MM_MIRROR_ROOT" "$MM_CACHE_ROOT" "$MM_SELECTIVE_ROOT" "$MM_DP_PHASE2_ROOT")
  local p dev root_dev
  for p in "${paths[@]}"; do
    mkdir -p "$p" || mm_die "SAME_FILESYSTEM=FAIL mkdir path=${p}"
  done
  root_dev="$(stat -c %d "$MM_MIRROR_ROOT")"
  [[ "$root_dev" =~ ^[0-9]+$ ]] || mm_die "SAME_FILESYSTEM=FAIL cannot_stat root=${MM_MIRROR_ROOT}"
  for p in "${paths[@]}"; do
    dev="$(stat -c %d "$p")"
    if [[ "$dev" != "$root_dev" ]]; then
      mm_error "SAME_FILESYSTEM=FAIL path=${p} device=${dev} root_device=${root_dev}"
      mm_error "Place .install-cache, selective, and dp-phase2 on the same filesystem as ${MM_MIRROR_ROOT}."
      mm_error "Cross-filesystem layouts require full ~30GiB copies and are not supported for 100GB-class disks."
      mm_die "SAME_FILESYSTEM=FAIL"
    fi
  done
  mm_ok "SAME_FILESYSTEM=PASS device=${root_dev}"
}

# Files at or above this size must be hard-linked (never silently copied).
MM_LARGE_FILE_COPY_THRESHOLD_BYTES="${MM_LARGE_FILE_COPY_THRESHOLD_BYTES:-$((64 * 1024 * 1024))}"

engine_link_acps_file_into_work() {
  local src="$1"
  local dst="$2"
  local sz
  [[ -f "$src" ]] || mm_die "ACPS_WORK_STAGE=FAIL missing_src=${src}"
  sz="$(stat -c%s "$src" 2>/dev/null || echo 0)"
  [[ "$sz" =~ ^[0-9]+$ ]] || sz=0
  if ln "$src" "$dst" 2>/dev/null; then
    mm_info "ACPS_WORK_HARDLINK file=$(basename "$src") bytes=${sz}"
    return 0
  fi
  if [[ "$sz" -ge "$MM_LARGE_FILE_COPY_THRESHOLD_BYTES" ]]; then
    mm_error "ACPS_WORK_STAGE=FAIL large_file_hardlink_failed file=$(basename "$src") bytes=${sz}"
    mm_error "Refusing automatic full copy of large ACPS payload (same-filesystem hard link required)."
    mm_die "ACPS_WORK_STAGE=FAIL hardlink_required"
  fi
  cp -f "$src" "$dst" || mm_die "ACPS_WORK_STAGE=FAIL file=$(basename "$src")"
  mm_info "ACPS_WORK_SMALL_COPY file=$(basename "$src") bytes=${sz}"
}

engine_stage_acps_work_from_cache() {
  local cache="$1"
  local work="$2"
  local f verified=0
  # Capture verification before hardlink: linking updates inode ctime and would
  # otherwise invalidate a metadata-bound .VERIFIED marker.
  if declare -F acps_is_verified_cache >/dev/null 2>&1 \
    && acps_is_verified_cache "$cache"; then
    verified=1
  fi
  rm -rf "$work"
  mkdir -p "$work" || mm_die "ACPS_WORK_STAGE=FAIL mkdir"
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    case "$f" in
      bringup_py3_dp_after_os_upgrade.sh|bringup_py3_dp_after_os_upgrade.sh.sha1)
        continue
        ;;
    esac
    engine_link_acps_file_into_work "${cache}/${f}" "${work}/${f}"
  done
  if [[ "$verified" -eq 1 ]] && declare -F acps_write_verified_marker >/dev/null 2>&1; then
    acps_write_verified_marker "$cache" || true
  fi
}

# Inner checksums for payloads reused from an existing final. Bringup is excluded
# because it will be replaced. Always verify images-*.tar against its sidecar;
# a matching outer bundle hash does not prove inner payload checksums.
engine_verify_reused_final_payloads() {
  local files_dir="$1"
  local ver="${2:-$DP_PHASE2_VERSION}"
  local f
  for f in \
    aelladeb_py3_common.tar.gz \
    aelladeb_py3_common.tar.gz.sha1 \
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb" \
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1" \
    "images-${ver}.list" \
    "images-${ver}.tar" \
    "images-${ver}.tar.sha256"
  do
    [[ -f "${files_dir}/${f}" ]] || return 1
    dp2_reject_bad_payload "${files_dir}/${f}" "$f" || return 1
  done
  mm_verify_sha1_pair_logged \
    "${files_dir}/aelladeb_py3_common.tar.gz" \
    "${files_dir}/aelladeb_py3_common.tar.gz.sha1" \
    || return 1
  mm_verify_sha1_pair_logged \
    "${files_dir}/aella-uvp-2404_${ver}ubuntu1_amd64.deb" \
    "${files_dir}/aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1" \
    || return 1
  mm_verify_sha256_pair_logged \
    "${files_dir}/images-${ver}.tar" \
    "${files_dir}/images-${ver}.tar.sha256" \
    "ACPS_CHECKSUM_VERIFY" \
    "Still verifying reused images-${ver}.tar SHA256..." \
    || return 1
  return 0
}

# Extract unchanged ACPS payloads from a verified existing final. Never mutates
# the old tar in place. Caller replaces bringup, then releases the old final
# before writing .new so peak stays at two large copies.
engine_stage_work_from_existing_final() {
  local ver="$1"
  local work="$2"
  local dest bundle sidecar
  dp2_set_version "$ver"
  dest="$(engine_phase2_final_dir "$ver")"
  bundle="${dest}/$(dp2_stable_bundle_name)"
  sidecar="${bundle}.sha256"

  [[ -f "$bundle" && ! -L "$bundle" ]] \
    || mm_die "PHASE2_EXISTING_FINAL_SOURCE=FAIL bundle_missing"
  [[ -f "$sidecar" && ! -L "$sidecar" ]] \
    || mm_die "PHASE2_EXISTING_FINAL_SOURCE=FAIL sidecar_missing"

  mm_info "PHASE2_REBUILD_SOURCE=EXISTING_FINAL"
  mm_set_phase "Validating Existing Phase 2 Bundle For Rebuild"
  if [[ "${PHASE2_EXISTING_FINAL_INTEGRITY:-}" != "PASS" ]]; then
    if ! mm_verify_sha256_pair_logged \
      "$bundle" "$sidecar" "PHASE2_EXISTING_SHA256_VERIFY" \
      "Still verifying the existing Phase 2 bundle SHA256..."
    then
      mm_die "PHASE2_EXISTING_FINAL_SOURCE=FAIL sha256"
    fi
  fi
  if ! dp2_assert_safe_tar_list "$bundle" >/dev/null; then
    mm_die "PHASE2_EXISTING_FINAL_SOURCE=FAIL tar_entries"
  fi

  rm -rf "$work"
  mkdir -p "$work" || mm_die "PHASE2_EXISTING_FINAL_EXTRACT=FAIL mkdir"
  mm_set_phase "Extracting Phase 2 Payloads For Local Rebuild"
  mm_human_lines \
    "Extracting unchanged ACPS payloads from the existing Phase 2 bundle." \
    "Only the patched bringup script will be replaced." \
    "This does not download ACPS over the network."
  if ! mm_run_with_heartbeat \
    "PHASE2_EXISTING_FINAL_EXTRACT" \
    "bundle=$(basename "$bundle") dest=${work}" \
    "Still extracting unchanged Phase 2 payloads from the existing final bundle..." \
    -- tar -xf "$bundle" -C "$work"
  then
    rm -rf "$work"
    mm_die "PHASE2_EXISTING_FINAL_EXTRACT=FAIL"
  fi
  if ! dp2_assert_exact_files_dir "$work"; then
    rm -rf "$work"
    mm_die "PHASE2_EXISTING_FINAL_EXTRACT=FAIL file_set"
  fi
  rm -f "${work}/bringup_py3_dp_after_os_upgrade.sh" \
    "${work}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  if ! engine_verify_reused_final_payloads "$work" "$ver"; then
    rm -rf "$work"
    mm_die "PHASE2_EXISTING_FINAL_PAYLOADS=FAIL"
  fi
  mm_ok "PHASE2_EXISTING_FINAL_EXTRACT=PASS"
}

engine_phase2_prereq_src_dir() {
  local ver="${1:-${TARGET_DP_VERSION:-${PHASE2_TARGET_VERSION}}}"
  printf '%s/phase2-prereq-src/%s\n' "${MM_CACHE_ROOT}" "$ver"
}

engine_preserve_phase2_prereq_sources() {
  # Copy the small ACPS metadata payloads needed to resolve Ubuntu extras
  # before engine_cleanup_phase2_sources drops the ~30GiB work tree.
  local files_src="$1"
  local ver="${2:-${TARGET_DP_VERSION}}"
  local dest f
  dest="$(engine_phase2_prereq_src_dir "$ver")"
  mkdir -p "$dest" || return 1
  for f in \
    aelladeb_py3_common.tar.gz \
    aelladeb_py3_common.tar.gz.sha1 \
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb" \
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1"
  do
    [[ -f "${files_src}/${f}" ]] || continue
    cp -a "${files_src}/${f}" "${dest}/${f}"
  done
  [[ -f "${dest}/aelladeb_py3_common.tar.gz" ]]
}

engine_cleanup_phase2_sources() {
  # Drop ACPS source/work as soon as the verified bundle .new no longer needs them.
  local ver="${1:-${TARGET_DP_VERSION:-}}"
  if [[ -n "$ver" ]]; then
    acps_cleanup_cache "$ver" || true
  fi
  rm -rf "${MM_CACHE_ROOT}/acps-work" "${MM_CACHE_ROOT}/dp-build" 2>/dev/null || true
}

engine_verify_os_core_package() {
  local package="$1"
  mm_assert_regular_file "$package" "os-core-package"
  OS_CORE_PACKAGE_BYTES="$(mm_file_bytes "$package")"
  local py="${MM_PROJECT_ROOT}/scripts/lib/os_core_package.py"
  local out
  out="$(python3 "$py" verify --package "$package" ${OS_CORE_PUBLIC_KEY:+--public-key "$OS_CORE_PUBLIC_KEY"} )"
  printf '%s\n' "$out"
  OS_CORE_PAYLOAD_BYTES="$(printf '%s\n' "$out" | awk -F= '/^PAYLOAD_BYTES=/{print $2; exit}')"
  OS_CORE_RELEASE_ID="$(printf '%s\n' "$out" | awk -F= '/^RELEASE_ID=/{print $2; exit}')"
  OS_CORE_PAYLOAD_BYTES="${OS_CORE_PAYLOAD_BYTES:-0}"
  mm_state_set R2_OS_CORE_CHECKSUM PASS
  mm_ok "VERIFY_OS_CORE=PASS release_id=${OS_CORE_RELEASE_ID}"
}

engine_verify_selective_ready_provenance() {
  local ready="${MM_SELECTIVE_ROOT}/state/READY"
  local out
  if [[ ! -f "$ready" ]]; then
    mm_error "SELECTIVE_READY_VERIFY=FAIL reason=missing"
    return 1
  fi
  out="$(python3 "${MM_PROJECT_ROOT}/scripts/lib/os_core_package.py" \
    verify-selective-ready --ready-path "$ready" 2>&1)" || {
    mm_error "SELECTIVE_READY_VERIFY=FAIL reason=verify"
    printf '%s\n' "$out" | while IFS= read -r line; do mm_error "$line"; done
    return 1
  }
  printf '%s\n' "$out" | while IFS= read -r line; do
    case "$line" in
      SELECTIVE_READY_VERIFY=*|SELECTIVE_PLAN_CHECKSUM=*|DISCOVERY_ARTIFACT_CHECKSUM=*|OS_CORE_PROVENANCE_SOURCE=*)
        mm_info "$line"
        ;;
    esac
  done
  mm_ok "SELECTIVE_READY_VERIFY=PASS"
  return 0
}

# On-disk OS Core reuse gate: READY + four hops + InRelease + Packages + sample deb
# + upgraders + selective key. Status files alone are insufficient.
engine_assess_os_core_for_prepare() {
  OS_CORE_ACTION=DOWNLOAD_VERIFY_MATERIALIZE
  R2_DOWNLOAD_REQUIRED=YES
  OS_MATERIALIZE_REQUIRED=YES
  OS_CORE_READY_AT_START=NO

  if [[ ! -f "${MM_SELECTIVE_ROOT}/state/READY" ]]; then
    return 0
  fi
  if ! engine_verify_selective_ready_provenance >/dev/null 2>&1; then
    return 0
  fi
  local out
  out="$(python3 "${MM_PROJECT_ROOT}/scripts/lib/client_build_repository.py" \
    --verify-os-core-reuse --selective-root "${MM_SELECTIVE_ROOT}" 2>&1)" || {
    mm_info "OS_CORE_ON_DISK_VERIFY=FAIL"
    printf '%s\n' "$out" | while IFS= read -r line; do mm_info "$line"; done || true
    return 0
  }
  printf '%s\n' "$out" | while IFS= read -r line; do
    case "$line" in
      OS_CORE_*) mm_info "$line" ;;
    esac
  done || true
  OS_CORE_READY_AT_START=YES
  OS_CORE_ACTION=REUSE_VERIFIED
  R2_DOWNLOAD_REQUIRED=NO
  OS_MATERIALIZE_REQUIRED=NO
  return 0
}

engine_write_selective_ready_from_os_core() {
  # Write verified READY into selective_tmp using package metadata still at pkg_root.
  local pkg_root="$1"
  local selective_tmp="$2"
  local payload_root="${3:-}"
  local out line
  local args=(
    write-selective-ready
    --package-root "$pkg_root"
    --selective-root "$selective_tmp"
  )
  if [[ -n "$payload_root" ]]; then
    args+=(--payload-root "$payload_root")
  fi
  out="$(python3 "${MM_PROJECT_ROOT}/scripts/lib/os_core_package.py" "${args[@]}" 2>&1)" || {
    mm_error "SELECTIVE_READY_VERIFY=FAIL reason=write_from_os_core"
    printf '%s\n' "$out" >&2
    return 1
  }
  while IFS= read -r line; do
    case "$line" in
      OS_CORE_PROVENANCE_SOURCE=*|OS_CORE_MANIFEST_SHA256=*|OS_CORE_PAYLOAD_MANIFEST_SHA256=*|\
      SELECTIVE_PLAN_CHECKSUM=*|DISCOVERY_ARTIFACT_CHECKSUM=*|SELECTIVE_READY_ACTION=*|\
      SELECTIVE_READY_VERIFY=*|SELECTIVE_READY_PATH=*)
        mm_info "$line"
        ;;
      OS_CORE_ERROR=*)
        mm_error "$line"
        return 1
        ;;
    esac
  done <<<"$out"
  [[ -f "${selective_tmp}/state/READY" ]] || {
    mm_error "SELECTIVE_READY_VERIFY=FAIL reason=ready_not_written"
    return 1
  }
  return 0
}

engine_materialize_os_mirror() {
  # Extract verified OS Core into selective root directly (no current/previous/releases).
  # Same-filesystem: rename payload into place (no second full copy). Cross-device: cp fallback.
  # Writes verified selective/state/READY provenance into the staged tree BEFORE rename.
  local package="$1"
  local staging_extract
  staging_extract="${MM_CACHE_ROOT}/os-core-extract/$(mm_run_id)"
  local final_tmp="${MM_SELECTIVE_ROOT}.new.$$"
  local pkg_root

  if [[ "${MM_DRY_RUN}" == "1" ]]; then
    mm_info "DRY_RUN skip materialize_os_mirror"
    return 0
  fi

  rm -rf "$staging_extract" "$final_tmp"
  python3 "${MM_PROJECT_ROOT}/scripts/lib/os_core_package.py" extract-staging \
    --package "$package" \
    --staging-dir "$staging_extract" \
    ${OS_CORE_PUBLIC_KEY:+--public-key "$OS_CORE_PUBLIC_KEY"} \
    || mm_die "OS_CORE_EXTRACT=FAIL"

  pkg_root="${staging_extract}/ubuntu-os-core"
  local payload="${pkg_root}/payload"
  [[ -d "$payload" ]] || mm_die "OS_CORE_PAYLOAD_MISSING"
  [[ -f "${pkg_root}/manifest.json" ]] || mm_die "OS_CORE_MANIFEST_MISSING"
  [[ -f "${pkg_root}/payload.sha256" ]] || mm_die "OS_CORE_PAYLOAD_SHA256_MISSING"

  local hop
  for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
    [[ -d "${payload}/hops/${hop}" ]] || mm_die "OS_MIRROR_READY=FAIL hop=${hop}"
  done

  mkdir -p "$(dirname "$final_tmp")"
  local src_dev dst_dev
  src_dev="$(stat -c %d "$payload")"
  dst_dev="$(stat -c %d "$(dirname "$final_tmp")")"
  if [[ "$src_dev" == "$dst_dev" ]]; then
    mv -f "$payload" "$final_tmp" || mm_die "OS_MIRROR_STAGE_MOVE=FAIL"
  else
    mkdir -p "$final_tmp"
    cp -a "$payload"/. "$final_tmp"/ || mm_die "OS_MIRROR_STAGE_COPY=FAIL"
    rm -rf "$payload"
  fi

  # Ensure ubuntu alias for nginx /ubuntu/
  if [[ ! -e "${final_tmp}/ubuntu" ]]; then
    ln -sfn hops/jammy-to-noble/ubuntu "${final_tmp}/ubuntu"
  fi

  # Authoritative provenance → selective READY inside the staged tree (atomic with publish).
  # Uses verified package manifest.json + payload.sha256 still at pkg_root.
  engine_write_selective_ready_from_os_core "$pkg_root" "$final_tmp" "$final_tmp" \
    || mm_die "SELECTIVE_READY_FROM_OS_CORE=FAIL"

  # Preserve keys/ if present outside payload.
  local keys_backup=""
  if [[ -d "${MM_SELECTIVE_ROOT}/keys" ]]; then
    keys_backup="${MM_CACHE_ROOT}/keys-backup.$$"
    rm -rf "$keys_backup"
    cp -a "${MM_SELECTIVE_ROOT}/keys" "$keys_backup" || mm_die "OS_KEYS_BACKUP=FAIL"
  fi

  local old="${MM_SELECTIVE_ROOT}.old.$$"
  rm -rf "$old"
  if [[ -d "$MM_SELECTIVE_ROOT" ]]; then
    mv -f "$MM_SELECTIVE_ROOT" "$old" || mm_die "OS_MIRROR_OLD_MOVE=FAIL"
  fi
  if ! mv -f "$final_tmp" "$MM_SELECTIVE_ROOT"; then
    [[ -e "$old" && ! -e "$MM_SELECTIVE_ROOT" ]] && mv -f "$old" "$MM_SELECTIVE_ROOT" 2>/dev/null || true
    mm_die "OS_MIRROR_PUBLISH_MOVE=FAIL"
  fi
  if [[ -n "$keys_backup" && -d "$keys_backup" ]]; then
    # Prefer package keys; only restore backup when package shipped none.
    if [[ ! -d "${MM_SELECTIVE_ROOT}/keys" ]]; then
      mv -f "$keys_backup" "${MM_SELECTIVE_ROOT}/keys" || mm_die "OS_KEYS_RESTORE=FAIL"
    else
      rm -rf "$keys_backup"
    fi
  fi
  rm -rf "$old" "$staging_extract"

  # Explicitly do not create current/previous/published.previous/os-core-releases
  rm -rf \
    "${MM_SELECTIVE_ROOT}/current" \
    "${MM_SELECTIVE_ROOT}/previous" \
    "${MM_SELECTIVE_ROOT}/published" \
    "${MM_SELECTIVE_ROOT}/published.previous" \
    "${MM_SELECTIVE_ROOT}/os-core-releases" \
    "${MM_SELECTIVE_ROOT}/releases" 2>/dev/null || true

  # Post-rename provenance gate — OS_MIRROR_READY only after READY verifies.
  engine_verify_selective_ready_provenance \
    || mm_die "SELECTIVE_READY_VERIFY=FAIL after materialize"

  mm_mark_changed
  mm_state_set OS_MIRROR_READY PASS
  mm_status_set OS_MIRROR_READY PASS
  mm_ok "OS_MIRROR_MATERIALIZE=PASS path=${MM_SELECTIVE_ROOT}"
}

# Offline Ubuntu prerequisite closure is prepared from ACPS metadata.
# Failures here fail Download and Prepare closed. Never optional.
engine_prepare_phase2_ubuntu_prerequisites() {
  local script="${MM_PROJECT_ROOT}/scripts/prepare-phase2-ubuntu-prerequisites.sh"
  local work="${1:-}"
  local extras out rc=0 child_log line
  [[ -f "$script" ]] || mm_die "PHASE2_PREREQ=FAIL reason=prepare_script_missing"
  mm_set_phase "Preparing Phase 2 Ubuntu Prerequisites"
  if [[ -z "$work" || ! -f "${work}/aelladeb_py3_common.tar.gz" ]]; then
    local preserved
    preserved="$(engine_phase2_prereq_src_dir)"
    if [[ -f "${preserved}/aelladeb_py3_common.tar.gz" ]]; then
      work="$preserved"
    fi
  fi
  extras="${MM_DP_PHASE2_ROOT}/${TARGET_DP_VERSION}/extras"
  mkdir -p "$extras"
  child_log="$(mktemp "${TMPDIR:-/tmp}/phase2-prereq-child.XXXXXX")"
  set +e
  DP_PHASE2_VERSION="${TARGET_DP_VERSION}" \
    DP_PHASE2_ROOT="${MM_DP_PHASE2_ROOT}" \
    MM_SELECTIVE_ROOT="${MM_SELECTIVE_ROOT}" \
    PHASE2_PREREQ_WORK_DIR="$work" \
    PHASE2_PREREQ_OUT_DIR="$extras" \
    bash "$script" "${TARGET_DP_VERSION}" >"$child_log" 2>&1
  rc=$?
  set -e
  # Replay child stdout/stderr through mm_log so Menu 2 live progress
  # (/dev/tty + MM_LOG_FILE) shows the specific reason before the generic rc.
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == *'=FAIL'* || "$line" == *'[ERROR]'* ]]; then
      mm_error "$line"
    else
      mm_info "$line"
    fi
  done < "$child_log"
  rm -f "$child_log"
  if [[ "$rc" -ne 0 ]]; then
    mm_error "PHASE2_PREREQ_BUILD=FAIL rc=${rc}"
    mm_die "PHASE2_PREREQ=FAIL rc=${rc}"
  fi
  [[ -f "${extras}/phase2-ubuntu-prerequisites.state" ]] \
    || mm_die "PHASE2_PREREQ=FAIL reason=state_missing"
  while IFS= read -r out; do
    [[ -n "$out" ]] && mm_info "$out"
  done < "${extras}/phase2-ubuntu-prerequisites.state"
  python3 "${MM_PROJECT_ROOT}/scripts/lib/phase2_ubuntu_prerequisites.py" \
    validate-state --dest "$extras" \
    || mm_die "PHASE2_PREREQ=FAIL reason=state_contract"
  local required count sha
  required="$(awk -F= '$1=="PHASE2_PREREQ_REQUIRED"{print $2; exit}' \
    "${extras}/phase2-ubuntu-prerequisites.state")"
  count="$(awk -F= '$1=="PHASE2_PREREQ_PACKAGE_COUNT"{print $2; exit}' \
    "${extras}/phase2-ubuntu-prerequisites.state")"
  sha="$(awk -F= '$1=="PHASE2_PREREQ_SHA256"{print $2; exit}' \
    "${extras}/phase2-ubuntu-prerequisites.state")"
  engine_record_phase2_prereq_release_identity
  mm_ok "PHASE2_PREREQ=PASS required=${required} count=${count} sha256=${sha}"
}

engine_bringup_sha1_of() {
  sha1sum "$1" | awk '{print $1}'
}

# Previously known unmodified ACPS bringup SHA1. Observability / change
# detection only — never a production blocking gate.
engine_bringup_reference_sha1() {
  local baseline="${MM_PROJECT_ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1"
  [[ -f "$baseline" ]] || mm_die "UPSTREAM_BASELINE_MISSING path=${baseline}"
  awk '{print $1; exit}' "$baseline"
}

# Coarse layout checks before the deterministic patcher runs. Missing =>
# incompatible upstream (fatal), distinct from reference-SHA drift (warning).
# This is NOT BRINGUP_PATCH_COMPAT. Fine-grained exact-anchor checks and
# BRINGUP_PATCH_COMPAT live only in patch_dp_phase2_bringup.py.
engine_bringup_required_upstream_anchors() {
  printf '%s\n' \
    'parse_args()' \
    'orchestrate_workers()' \
    'load_local_images()' \
    'images import' \
    'join_k8s_cluster()' \
    'install_python3()'
}

# Markers that must be present after project patches are generated onto
# the current upstream. A no-op or incomplete generation is a patch
# failure, not drift.
engine_bringup_required_patch_result_markers() {
  printf '%s\n' \
    '# BEGIN_IMAGE_IMPORT_HEARTBEAT' \
    'run_image_import_with_heartbeat' \
    'emit_dp_resume_notice_line' \
    '--worker-password' \
    'wait_for_master_token_api' \
    'validate_expected_cluster_nodes' \
    'validate_apt_dependency_graph' \
    'MASTER_TOKEN_API_READY' \
    'CLUSTER_JOIN_STATE' \
    'APT_DEPENDENCY_CHECK' \
    'CRITICAL_PYTHON_RUNTIME' \
    'WORKER_RESULT' \
    'copy_phase2_prereq_contract_to_worker' \
    'normalize_remote_orchestration_nodes'
}

# vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh is a reference / golden
# output for a known upstream generation. It is NOT the production input
# that replaces a freshly downloaded ACPS file.
engine_bringup_reference_patched_path() {
  printf '%s\n' "${MM_PROJECT_ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
}

engine_bringup_patcher_py() {
  printf '%s\n' "${MM_PROJECT_ROOT}/scripts/lib/patch_dp_phase2_bringup.py"
}

# Identity of the project patch layer. Same upstream + changed generation
# requires a bundle rebuild. Never derived from the frozen vendor full copy.
engine_current_bringup_patch_generation() {
  local py
  py="$(engine_bringup_patcher_py)"
  [[ -f "$py" ]] || return 1
  python3 "$py" --print-generation | awk -F= '$1=="BRINGUP_PATCH_GENERATION"{print $2; exit}'
}

engine_phase2_saved_upstream_path() {
  local ver="${1:-${TARGET_DP_VERSION:-${PHASE2_TARGET_VERSION}}}"
  printf '%s/%s/bringup_py3_dp_after_os_upgrade.sh.upstream\n' \
    "${MM_DP_PHASE2_ROOT}" "$ver"
}

# Immutable ACPS copy lives beside the 9-file work set, never inside it
# (dp2_assert_exact_files_dir rejects extra files in the tar source).
engine_phase2_work_upstream_path() {
  printf '%s.upstream/bringup_py3_dp_after_os_upgrade.sh\n' "${1%/}"
}

# Cheap inner bringup digest: extract only the small script from the 30GiB tar.
engine_phase2_inner_bringup_sha1() {
  local bundle="$1"
  tar -xOf "$bundle" bringup_py3_dp_after_os_upgrade.sh 2>/dev/null | sha1sum | awk '{print $1}'
}

engine_bringup_fail() {
  local event="$1"
  mm_error "${event}=FAIL"
  mm_error "INSTALL_RESULT=FAIL"
  mm_state_set HTTP_DISTRIBUTION_READY NO
  mm_die "${event}=FAIL"
}

engine_bringup_require_nonempty() {
  local file="$1"
  [[ -f "$file" ]] || engine_bringup_fail "UPSTREAM_BRINGUP_MISSING"
  [[ -s "$file" ]] || engine_bringup_fail "UPSTREAM_BRINGUP_EMPTY"
}

engine_bringup_require_bash_n() {
  local file="$1" event="$2"
  if ! bash -n "$file" >/dev/null 2>&1; then
    engine_bringup_fail "$event"
  fi
  mm_ok "${event}=PASS"
}

engine_bringup_require_markers() {
  local file="$1" event="$2"
  shift 2
  local missing=() marker
  for marker in "$@"; do
    grep -qF -- "$marker" "$file" || missing+=("$marker")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    mm_error "${event}=FAIL"
    mm_error "${event}_MISSING=${missing[*]}"
    mm_error "INSTALL_RESULT=FAIL"
    mm_state_set HTTP_DISTRIBUTION_READY NO
    mm_die "${event}=FAIL"
  fi
  mm_ok "${event}=PASS"
}

# Authoritative integrity check: downloaded bytes vs current ACPS .sha1 sidecar.
engine_verify_acps_bringup_sidecar() {
  local files_dir="$1"
  local upstream_file="${files_dir}/bringup_py3_dp_after_os_upgrade.sh"
  local sidecar="${files_dir}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  local expected actual
  engine_bringup_require_nonempty "$upstream_file"
  [[ -f "$sidecar" ]] || engine_bringup_fail "ACPS_BRINGUP_SIDECAR_MISSING"
  expected="$(dp2_read_hash_field "$sidecar")"
  dp2_validate_sha1_hex "$expected" || engine_bringup_fail "ACPS_BRINGUP_SIDECAR_FORMAT"
  actual="$(engine_bringup_sha1_of "$upstream_file")"
  if [[ "${expected,,}" != "${actual,,}" ]]; then
    mm_error "ACPS_BRINGUP_CHECKSUM=FAIL"
    mm_error "ACPS_BRINGUP_EXPECTED_SHA1=${expected}"
    mm_error "ACPS_BRINGUP_ACTUAL_SHA1=${actual}"
    mm_error "INSTALL_RESULT=FAIL"
    mm_state_set HTTP_DISTRIBUTION_READY NO
    mm_die "ACPS_BRINGUP_CHECKSUM=FAIL"
  fi
  BRINGUP_UPSTREAM_SHA1="$actual"
  mm_ok "ACPS_BRINGUP_CHECKSUM=PASS sha1=${actual}"
}

engine_verify_acps_upstream_bringup() {
  local files_dir="$1"
  local upstream_file="${files_dir}/bringup_py3_dp_after_os_upgrade.sh"
  local reference actual
  local anchors=()

  engine_verify_acps_bringup_sidecar "$files_dir"
  actual="${BRINGUP_UPSTREAM_SHA1}"
  reference="$(engine_bringup_reference_sha1)"

  if [[ "${reference,,}" != "${actual,,}" ]]; then
    mm_warn "UPSTREAM_BRINGUP_CHANGED=YES"
    mm_info "PREVIOUS_KNOWN_SHA1=${reference}"
    mm_info "CURRENT_UPSTREAM_SHA1=${actual}"
    mm_warn "UPSTREAM_BRINGUP_DRIFT=NON_BLOCKING"
    mm_state_set UPSTREAM_BRINGUP_DRIFT NON_BLOCKING
  else
    mm_state_set UPSTREAM_BRINGUP_DRIFT NO
    mm_ok "VERIFY_ACPS_UPSTREAM=PASS sha1=${actual}"
  fi

  engine_bringup_require_bash_n "$upstream_file" "UPSTREAM_BRINGUP_SYNTAX"

  # Single source of truth: the production patch generator. Layout markers
  # are extra evidence, not a substitute PASS that can disagree with --validate.
  engine_bringup_validate_patcher "$upstream_file"
  mapfile -t anchors < <(engine_bringup_required_upstream_anchors)
  engine_bringup_require_markers "$upstream_file" "UPSTREAM_LAYOUT_ANCHORS" "${anchors[@]}"
}

# Run the deterministic patcher in-memory. Never prints BRINGUP_PATCH_COMPAT=PASS
# unless the generator applied every transform and produced a distinct result.
engine_bringup_validate_patcher() {
  local upstream_file="$1"
  local py out rc=0
  local fail_transform="" fail_reason=""
  py="$(engine_bringup_patcher_py)"
  [[ -f "$py" ]] || mm_die "BRINGUP_PATCHER_MISSING path=${py}"
  engine_bringup_require_nonempty "$upstream_file"
  set +e
  out="$(python3 "$py" --validate --upstream "$upstream_file" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  if [[ "$rc" -ne 0 ]]; then
    fail_transform="$(printf '%s\n' "$out" | awk 'sub(/^BRINGUP_PATCH_COMPAT_FAIL_TRANSFORM=/, "") { print; exit }')"
    fail_reason="$(printf '%s\n' "$out" | awk 'sub(/^BRINGUP_PATCH_COMPAT_FAIL_REASON=/, "") { print; exit }')"
    mm_error "BRINGUP_PATCH_COMPAT=FAIL"
    mm_error "PATCHED_BRINGUP_GENERATION=FAIL"
    if [[ -n "$fail_transform" ]]; then
      mm_error "BRINGUP_PATCH_COMPAT_FAIL_TRANSFORM=${fail_transform}"
    fi
    if [[ -n "$fail_reason" ]]; then
      mm_error "BRINGUP_PATCH_COMPAT_FAIL_REASON=${fail_reason}"
    fi
    engine_bringup_fail "BRINGUP_PATCH_COMPAT"
  fi
  printf '%s\n' "$out" | grep -qx 'BRINGUP_PATCH_COMPAT=PASS' \
    || engine_bringup_fail "BRINGUP_PATCH_COMPAT"
  printf '%s\n' "$out" | grep -qx 'PATCHED_BRINGUP_GENERATION=PASS' \
    || engine_bringup_fail "PATCHED_BRINGUP_GENERATION"
  mm_ok "BRINGUP_PATCH_COMPAT=PASS"
  mm_ok "PATCHED_BRINGUP_GENERATION=PASS"
}

# Generate FINAL_BRINGUP = current ACPS upstream + project patch layer.
# upstream_src is the immutable ACPS file (cache or saved .upstream copy).
# files_dir receives the generated patched script + patched SHA sidecar.
# Never copies vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh over upstream.
# Never rewrites the ACPS sidecar to the patched digest.
engine_apply_local_bringup_patch() {
  local files_dir="$1"
  local upstream_src="${2:-}"
  local dest="${files_dir}/bringup_py3_dp_after_os_upgrade.sh"
  local dest_sidecar="${dest}.sha1"
  local saved_upstream saved_upstream_sidecar
  local py out rc=0
  local markers=()
  local fail_transform="" fail_reason=""
  py="$(engine_bringup_patcher_py)"
  saved_upstream="$(engine_phase2_work_upstream_path "$files_dir")"
  saved_upstream_sidecar="${saved_upstream}.sha1"

  if [[ -z "$upstream_src" ]]; then
    if [[ -f "$saved_upstream" ]]; then
      upstream_src="$saved_upstream"
    else
      mm_die "UPSTREAM_BRINGUP_MISSING reason=patch_input"
    fi
  fi
  [[ -f "$py" ]] || mm_die "BRINGUP_PATCHER_MISSING path=${py}"
  engine_bringup_require_nonempty "$upstream_src"
  if [[ "${MM_DRY_RUN}" == "1" ]]; then
    mm_info "DRY_RUN skip apply_local_bringup_patch"
    return 0
  fi
  mm_set_phase "Preparing Patched Bringup Script"
  mm_info "BRINGUP_PATCH_MODEL=fresh_upstream_plus_project_layer"
  mm_info "Field operators must not edit bringup_py3_dp_after_os_upgrade.sh by hand."

  mkdir -p "$files_dir" "$(dirname "$saved_upstream")" \
    || engine_bringup_fail "BRINGUP_PATCH_APPLY"
  if [[ "$(readlink -f "$upstream_src" 2>/dev/null || true)" != "$(readlink -f "$saved_upstream" 2>/dev/null || true)" ]]; then
    cp -f "$upstream_src" "$saved_upstream" || engine_bringup_fail "BRINGUP_UPSTREAM_PRESERVE"
  fi
  # Preserve the authentic ACPS sidecar next to the immutable copy only.
  # Never rewrite the ACPS sidecar to the patched digest.
  if [[ -f "${upstream_src}.sha1" && "${upstream_src}.sha1" != "$saved_upstream_sidecar" ]]; then
    cp -f "${upstream_src}.sha1" "$saved_upstream_sidecar" || true
  elif [[ ! -f "$saved_upstream_sidecar" ]]; then
    sha1sum "$saved_upstream" | awk '{print $1"  bringup_py3_dp_after_os_upgrade.sh"}' \
      >"$saved_upstream_sidecar"
  fi
  BRINGUP_UPSTREAM_SHA1="$(engine_bringup_sha1_of "$saved_upstream")"
  mm_info "BRINGUP_UPSTREAM_SHA1=${BRINGUP_UPSTREAM_SHA1}"

  set +e
  out="$(python3 "$py" --upstream "$saved_upstream" --output "$dest" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  BRINGUP_PATCH_GENERATION="$(printf '%s\n' "$out" | awk -F= '$1=="BRINGUP_PATCH_GENERATION"{print $2; exit}')"
  BRINGUP_PATCHED_SHA1="$(printf '%s\n' "$out" | awk -F= '$1=="BRINGUP_PATCHED_SHA1"{print $2; exit}')"
  if [[ "$rc" -ne 0 ]]; then
    fail_transform="$(printf '%s\n' "$out" | awk 'sub(/^BRINGUP_PATCH_COMPAT_FAIL_TRANSFORM=/, "") { print; exit }')"
    fail_reason="$(printf '%s\n' "$out" | awk 'sub(/^BRINGUP_PATCH_COMPAT_FAIL_REASON=/, "") { print; exit }')"
    mm_error "BRINGUP_PATCH_COMPAT=FAIL"
    mm_error "PATCHED_BRINGUP_GENERATION=FAIL"
    if [[ -n "$fail_transform" ]]; then
      mm_error "BRINGUP_PATCH_COMPAT_FAIL_TRANSFORM=${fail_transform}"
    fi
    if [[ -n "$fail_reason" ]]; then
      mm_error "BRINGUP_PATCH_COMPAT_FAIL_REASON=${fail_reason}"
    fi
    engine_bringup_fail "BRINGUP_PATCH_COMPAT"
  fi
  [[ -n "${BRINGUP_PATCH_GENERATION:-}" ]] || engine_bringup_fail "BRINGUP_PATCH_GENERATION"
  [[ -n "${BRINGUP_PATCHED_SHA1:-}" ]] || engine_bringup_fail "BRINGUP_PATCHED_SHA1"
  mm_ok "BRINGUP_PATCH_COMPAT=PASS"
  mm_ok "PATCHED_BRINGUP_GENERATION=PASS"
  mm_info "BRINGUP_PATCH_GENERATION=${BRINGUP_PATCH_GENERATION}"

  # Patched sidecar is the generated digest, never the ACPS upstream hash.
  sha1sum "$dest" | awk '{print $1"  bringup_py3_dp_after_os_upgrade.sh"}' >"$dest_sidecar"
  if [[ "${BRINGUP_PATCHED_SHA1,,}" != "$(engine_bringup_sha1_of "$dest")" ]]; then
    engine_bringup_fail "PATCHED_BRINGUP_SHA1"
  fi
  if [[ "${BRINGUP_PATCHED_SHA1,,}" == "${BRINGUP_UPSTREAM_SHA1,,}" ]]; then
    engine_bringup_fail "PATCHED_BRINGUP_UNCHANGED"
  fi
  mapfile -t markers < <(engine_bringup_required_patch_result_markers)
  engine_bringup_require_markers "$dest" "BRINGUP_PATCH_RESULT" "${markers[@]}"
  engine_bringup_require_bash_n "$dest" "PATCHED_BRINGUP_SYNTAX"
  mm_state_set PATCHED_BRINGUP_APPLIED YES
  mm_ok "PATCHED_BRINGUP_APPLIED=YES sha1=${BRINGUP_PATCHED_SHA1}"
}

# After hardlink staging + patched bringup: trust cache-verified large payloads
# when device/inode match. Re-verify only the replaced bringup SHA1.
engine_assert_work_ready_for_bundle() {
  local cache_dir="$1"
  local work_dir="$2"
  local ver="${3:-$DP_PHASE2_VERSION}"
  local img_c img_w c_dev c_ino w_dev w_ino
  dp2_assert_exact_files_dir "$work_dir" || return 1
  img_c="${cache_dir}/images-${ver}.tar"
  img_w="${work_dir}/images-${ver}.tar"
  [[ -f "$img_c" && -f "$img_w" ]] || mm_die "ACPS_WORK_IMAGES_MISSING"
  c_dev="$(stat -c %d "$img_c")"
  c_ino="$(stat -c %i "$img_c")"
  w_dev="$(stat -c %d "$img_w")"
  w_ino="$(stat -c %i "$img_w")"
  if [[ "$c_dev" == "$w_dev" && "$c_ino" == "$w_ino" ]]; then
    if declare -F acps_is_verified_cache >/dev/null 2>&1 \
      && acps_is_verified_cache "$cache_dir"; then
      mm_ok "ACPS_WORK_IMAGES_HARDLINK_TRUSTED=YES device=${c_dev} inode=${c_ino}"
      mm_info "Skipping redundant SHA256 of hard-linked images-${ver}.tar (already verified in ACPS cache)."
      mm_verify_sha1_pair_logged \
        "${work_dir}/bringup_py3_dp_after_os_upgrade.sh" \
        "${work_dir}/bringup_py3_dp_after_os_upgrade.sh.sha1" \
        "ACPS_CHECKSUM_VERIFY" || return 1
      return 0
    fi
    mm_warn "ACPS_WORK_IMAGES_HARDLINK_TRUSTED=NO reason=cache_not_verified cache=${c_dev}:${c_ino}"
  else
    mm_warn "ACPS_WORK_IMAGES_HARDLINK_TRUSTED=NO cache=${c_dev}:${c_ino} work=${w_dev}:${w_ino}"
  fi
  mm_acps_verify_payload_checksums "$work_dir" || return 1
  return 0
}

engine_phase2_final_dir() {
  local ver="${1:-${TARGET_DP_VERSION:-${PHASE2_TARGET_VERSION}}}"
  printf '%s/%s\n' "${MM_DP_PHASE2_ROOT}" "$ver"
}

engine_phase2_mark_existing() {
  local state="$1"
  local reason="${2:-}"
  PHASE2_EXISTING_BUNDLE="$state"
  case "$state" in
    VALID)
      PHASE2_EXISTING_INVALID_REASON=""
      mm_info "PHASE2_EXISTING_BUNDLE=VALID"
      ;;
    ABSENT)
      PHASE2_EXISTING_INVALID_REASON=""
      mm_info "PHASE2_EXISTING_BUNDLE=ABSENT"
      ;;
    INVALID)
      PHASE2_EXISTING_INVALID_REASON="$reason"
      mm_warn "PHASE2_EXISTING_BUNDLE=INVALID reason=${reason}"
      mm_info "PHASE2_EXISTING_INVALID_REASON=${reason}"
      ;;
    *)
      PHASE2_EXISTING_INVALID_REASON=""
      mm_info "PHASE2_EXISTING_BUNDLE=${state}"
      ;;
  esac
}

# Stale patched-bringup / patch-generation may reuse a fully verified existing
# final when an immutable upstream copy is saved beside the bundle. Integrity
# or upstream-content failures must not.
engine_phase2_existing_final_reusable() {
  local saved
  saved="$(engine_phase2_saved_upstream_path "${TARGET_DP_VERSION:-${PHASE2_TARGET_VERSION}}")"
  case "${PHASE2_EXISTING_INVALID_REASON:-}" in
    patched_bringup_changed|patched_bringup_sha_missing|patch_generation_changed|patch_generation_missing)
      [[ "${PHASE2_EXISTING_FINAL_INTEGRITY:-}" == "PASS" ]] || return 1
      [[ -f "$saved" && -s "$saved" ]] || return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# Inner SHA1 pairs + images tar SHA256 from an existing final, without trusting
# the outer bundle hash. Small files are extracted to a temp dir; the ~30GiB
# images tar is stream-hashed so assess does not need another on-disk copy.
engine_phase2_verify_inner_payloads_in_bundle() {
  local bundle="$1"
  local ver="${2:-$DP_PHASE2_VERSION}"
  local tmp expected actual
  local common="aelladeb_py3_common.tar.gz"
  local uvp="aella-uvp-2404_${ver}ubuntu1_amd64.deb"
  local img="images-${ver}.tar"
  PHASE2_EXISTING_INTEGRITY_FAIL_REASON=""
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/phase2-inner-verify.XXXXXX")" || {
    PHASE2_EXISTING_INTEGRITY_FAIL_REASON=inner_payload_extract
    return 1
  }
  if ! tar -xf "$bundle" -C "$tmp" \
    "$common" "${common}.sha1" \
    "$uvp" "${uvp}.sha1" \
    "${img}.sha256"
  then
    rm -rf "$tmp"
    PHASE2_EXISTING_INTEGRITY_FAIL_REASON=inner_payload_extract
    mm_error "PHASE2_INNER_PAYLOAD_VERIFY=FAIL reason=extract"
    return 1
  fi
  if ! mm_verify_sha1_pair_logged "${tmp}/${common}" "${tmp}/${common}.sha1"; then
    rm -rf "$tmp"
    PHASE2_EXISTING_INTEGRITY_FAIL_REASON=inner_sha1
    mm_error "PHASE2_INNER_PAYLOAD_VERIFY=FAIL reason=inner_sha1 file=${common}"
    return 1
  fi
  if ! mm_verify_sha1_pair_logged "${tmp}/${uvp}" "${tmp}/${uvp}.sha1"; then
    rm -rf "$tmp"
    PHASE2_EXISTING_INTEGRITY_FAIL_REASON=inner_sha1
    mm_error "PHASE2_INNER_PAYLOAD_VERIFY=FAIL reason=inner_sha1 file=${uvp}"
    return 1
  fi
  expected="$(dp2_read_hash_field "${tmp}/${img}.sha256" | tr '[:upper:]' '[:lower:]')"
  if ! dp2_validate_sha256_hex "$expected"; then
    rm -rf "$tmp"
    PHASE2_EXISTING_INTEGRITY_FAIL_REASON=inner_images_sha256
    mm_error "PHASE2_INNER_PAYLOAD_VERIFY=FAIL reason=bad_inner_hash_format"
    return 1
  fi
  mm_info "PHASE2_INNER_IMAGES_SHA256_VERIFY_START file=${img} algorithm=SHA256"
  mm_human_lines \
    "Verifying SHA256 checksum of ${img} inside the existing Phase 2 bundle." \
    "Outer bundle SHA256 is not sufficient for local rebuild reuse."
  if ! mm_bg_with_heartbeat \
    "PHASE2_INNER_IMAGES_SHA256_VERIFY" \
    "file=${img} algorithm=SHA256" \
    "Still verifying inner ${img} SHA256..." \
    -- bash -c 'tar -xOf "$1" "$2" | sha256sum' _ "$bundle" "$img"
  then
    rm -rf "$tmp"
    PHASE2_EXISTING_INTEGRITY_FAIL_REASON=inner_images_sha256
    mm_error "PHASE2_INNER_PAYLOAD_VERIFY=FAIL reason=inner_images_sha256"
    return 1
  fi
  actual="$(printf '%s\n' "${MM_LONG_STEP_LAST_STDOUT:-}" | awk '{print $1; exit}' | tr '[:upper:]' '[:lower:]')"
  if [[ "$expected" != "$actual" ]]; then
    mm_error "SHA256_VERIFY=FAIL file=${img} expected=${expected} actual=${actual}"
    mm_error "PHASE2_INNER_IMAGES_SHA256=FAIL"
    mm_error "PHASE2_INNER_PAYLOAD_VERIFY=FAIL reason=inner_images_sha256"
    PHASE2_EXISTING_INTEGRITY_FAIL_REASON=inner_images_sha256
    rm -rf "$tmp"
    return 1
  fi
  mm_ok "SHA256_VERIFY=PASS file=${img}"
  mm_ok "PHASE2_INNER_PAYLOAD_VERIFY=PASS"
  rm -rf "$tmp"
  return 0
}

# Outer SHA256 + exact safe tar list. Does not mark the generation VALID.
# store_valid_cache=1 records the VALID-reuse fingerprint after a full hash.
engine_phase2_verify_existing_final_integrity() {
  local ver="$1"
  local bundle="$2"
  local sidecar="$3"
  local envf="$4"
  local store_valid_cache="${5:-0}"
  local reuse_fp expected_hash cached_fp cached_hash tar_helper schema="1"
  PHASE2_EXISTING_FINAL_INTEGRITY=FAIL
  PHASE2_EXISTING_INTEGRITY_FAIL_REASON=""
  expected_hash="$(dp2_read_hash_field "$sidecar" | tr '[:upper:]' '[:lower:]')"
  reuse_fp="schema=${schema}|$(mm_file_fingerprint "$bundle" 2>/dev/null || true)|$(mm_file_fingerprint "$sidecar" 2>/dev/null || true)|$(mm_file_fingerprint "$envf" 2>/dev/null || true)|sha=${expected_hash}"
  cached_fp="$(mm_status_get PHASE2_REUSE_VERIFIED_FINGERPRINT)"
  cached_hash="$(mm_status_get PHASE2_REUSE_VERIFIED_SHA256)"
  if [[ -n "$reuse_fp" && "$reuse_fp" == "$cached_fp" && "$expected_hash" == "$cached_hash" \
    && "$(mm_status_get PHASE2_BUNDLE_CHECKSUM)" == "PASS" ]]; then
    mm_info "PHASE2_BUNDLE_VERIFY_MODE=VERIFIED_METADATA_REUSE"
    mm_info "PHASE2_BUNDLE_FULL_HASH_REQUIRED=NO"
    mm_info "PHASE2_BUNDLE_VERIFICATION_RECORD_MATCH=YES"
    mm_info "PHASE2_EXISTING_VERIFY_CACHE=HIT"
  else
    mm_info "PHASE2_BUNDLE_VERIFY_MODE=FULL_HASH"
    mm_info "PHASE2_BUNDLE_FULL_HASH_REQUIRED=YES"
    mm_info "PHASE2_BUNDLE_VERIFICATION_RECORD_MATCH=NO"
    mm_info "PHASE2_EXISTING_VERIFY_CACHE=MISS"
    if ! mm_verify_sha256_pair_logged \
      "$bundle" "$sidecar" "PHASE2_EXISTING_SHA256_VERIFY" \
      "Still verifying the existing Phase 2 bundle SHA256..."
    then
      PHASE2_EXISTING_INTEGRITY_FAIL_REASON=sha256
      return 1
    fi
    tar_helper="${MM_PROJECT_ROOT}/scripts/lib/dp-phase2-common.sh"
    if ! mm_run_with_heartbeat \
      "PHASE2_EXISTING_TAR_VERIFY" \
      "bundle=$(basename "$bundle")" \
      "Still validating the existing Phase 2 bundle file list..." \
      -- bash -c 'source "$1"; dp2_set_version "$2"; dp2_assert_safe_tar_list "$3" >/dev/null' \
      _ "$tar_helper" "$ver" "$bundle"
    then
      PHASE2_EXISTING_INTEGRITY_FAIL_REASON=tar_entries
      return 1
    fi
    if [[ "$store_valid_cache" == "1" ]]; then
      mm_status_set PHASE2_REUSE_VERIFIED_FINGERPRINT "$reuse_fp"
      mm_status_set PHASE2_REUSE_VERIFIED_SHA256 "$expected_hash"
      mm_status_set PHASE2_BUNDLE_CHECKSUM PASS
      mm_info "PHASE2_EXISTING_VERIFY_CACHE=STORED"
    fi
  fi
  PHASE2_EXISTING_FINAL_INTEGRITY=PASS
  return 0
}

engine_assess_phase2_final() {
  # Sets PHASE2_EXISTING_BUNDLE=VALID|INVALID|ABSENT for the fixed Phase 2 final.
  # PHASE2_EXISTING_INVALID_REASON names the INVALID cause. Stale patched
  # bringup still runs outer SHA256 + tar validation so a verified final can
  # be the local rebuild source without another ACPS download.
  local ver="${1:-${TARGET_DP_VERSION:-${PHASE2_TARGET_VERSION}}}"
  local dest envf bundle sidecar stable
  local target_field artifact_field stable_field
  local current_gen published_gen published_patched published_upstream
  local inner_patched cache_dir cache_bringup cache_upstream
  local bringup_invalid_reason="" store_cache=0
  PHASE2_EXISTING_BUNDLE=ABSENT
  PHASE2_EXISTING_INVALID_REASON=""
  PHASE2_EXISTING_FINAL_INTEGRITY=""
  PHASE2_EXISTING_INTEGRITY_FAIL_REASON=""
  dp2_set_version "$ver"
  dest="$(engine_phase2_final_dir "$ver")"
  stable="$(dp2_stable_bundle_name)"
  envf="${dest}/release.env"
  bundle="${dest}/${stable}"
  sidecar="${dest}/${stable}.sha256"

  if [[ ! -e "$dest" ]]; then
    engine_phase2_mark_existing ABSENT
    return 0
  fi
  if [[ ! -d "$dest" ]]; then
    engine_phase2_mark_existing INVALID not_directory
    return 0
  fi
  # Obsolete generation layouts are never treated as a valid single-final bundle.
  if [[ -e "${dest}/releases" || -e "${dest}/current" || -e "${dest}/previous" \
    || -e "${dest}/files" || -e "${dest}/.staging" ]]; then
    engine_phase2_mark_existing INVALID obsolete_generation_layout
    return 0
  fi
  if [[ ! -f "$envf" || -L "$envf" ]]; then
    engine_phase2_mark_existing INVALID release_env
    return 0
  fi
  if [[ ! -f "$bundle" || -L "$bundle" ]]; then
    engine_phase2_mark_existing INVALID bundle_missing_or_symlink
    return 0
  fi
  if [[ ! -f "$sidecar" || -L "$sidecar" ]]; then
    engine_phase2_mark_existing INVALID sidecar_missing_or_symlink
    return 0
  fi
  target_field="$(grep -E '^TARGET_DP_VERSION=' "$envf" | head -1 | cut -d= -f2- || true)"
  artifact_field="$(grep -E '^PHASE2_ARTIFACT_VERSION=' "$envf" | head -1 | cut -d= -f2- || true)"
  stable_field="$(grep -E '^STABLE_BUNDLE_NAME=' "$envf" | head -1 | cut -d= -f2- || true)"
  if [[ "$target_field" != "$ver" || "$artifact_field" != "$ver" ]]; then
    engine_phase2_mark_existing INVALID version_mismatch
    return 0
  fi
  if [[ "$stable_field" != "$stable" ]]; then
    engine_phase2_mark_existing INVALID stable_name_mismatch
    return 0
  fi
  if dp2_release_has_secret "$envf"; then
    engine_phase2_mark_existing INVALID release_env_secret
    return 0
  fi
  # Reuse identity is (upstream SHA, patch-generation, inner patched SHA).
  # The frozen vendor full copy is not an authority for reuse.
  current_gen="$(engine_current_bringup_patch_generation 2>/dev/null || true)"
  current_gen="$(printf '%s' "$current_gen" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  published_gen="$(grep -E '^BRINGUP_PATCH_GENERATION=' "$envf" | head -1 | cut -d= -f2- || true)"
  published_gen="$(printf '%s' "$published_gen" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  published_patched="$(grep -E '^BRINGUP_PATCHED_SHA1=' "$envf" | head -1 | cut -d= -f2- || true)"
  published_patched="$(printf '%s' "$published_patched" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  published_upstream="$(grep -E '^BRINGUP_UPSTREAM_SHA1=' "$envf" | head -1 | cut -d= -f2- || true)"
  published_upstream="$(printf '%s' "$published_upstream" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  if [[ -z "$current_gen" ]]; then
    engine_phase2_mark_existing INVALID local_patch_generation_missing
    return 0
  fi
  if [[ -z "$published_gen" ]]; then
    bringup_invalid_reason=patch_generation_missing
    mm_info "CURRENT_BRINGUP_PATCH_GENERATION=${current_gen}"
  elif [[ "$published_gen" != "$current_gen" ]]; then
    bringup_invalid_reason=patch_generation_changed
    mm_info "PUBLISHED_BRINGUP_PATCH_GENERATION=${published_gen}"
    mm_info "CURRENT_BRINGUP_PATCH_GENERATION=${current_gen}"
  else
    mm_info "BRINGUP_PATCH_GENERATION_MATCH=YES generation=${current_gen}"
  fi
  if [[ -z "$bringup_invalid_reason" ]]; then
    if [[ -z "$published_patched" ]]; then
      bringup_invalid_reason=patched_bringup_sha_missing
    else
      inner_patched="$(engine_phase2_inner_bringup_sha1 "$bundle" 2>/dev/null || true)"
      inner_patched="$(printf '%s' "$inner_patched" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
      if [[ -z "$inner_patched" ]]; then
        bringup_invalid_reason=patched_bringup_sha_missing
      elif [[ "$published_patched" != "$inner_patched" ]]; then
        bringup_invalid_reason=patched_bringup_changed
        mm_info "PUBLISHED_PATCHED_BRINGUP_SHA1=${published_patched}"
        mm_info "INNER_PATCHED_BRINGUP_SHA1=${inner_patched}"
      else
        mm_info "PATCHED_BRINGUP_SHA1_MATCH=YES sha1=${published_patched}"
      fi
    fi
  fi
  if [[ -z "$bringup_invalid_reason" && -z "$published_upstream" ]]; then
    bringup_invalid_reason=upstream_sha_missing
  fi
  # A verified ACPS cache with a different upstream SHA must not keep the old
  # generated bringup published.
  if [[ -z "$bringup_invalid_reason" && -n "$published_upstream" ]] \
    && declare -F acps_cache_dir >/dev/null 2>&1; then
    cache_dir="$(acps_cache_dir "$ver" 2>/dev/null || true)"
    cache_bringup="${cache_dir}/bringup_py3_dp_after_os_upgrade.sh"
    if [[ -n "$cache_dir" && -f "$cache_bringup" ]]; then
      cache_upstream="$(engine_bringup_sha1_of "$cache_bringup" 2>/dev/null || true)"
      cache_upstream="$(printf '%s' "$cache_upstream" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
      if [[ -n "$cache_upstream" && "$cache_upstream" != "$published_upstream" ]]; then
        bringup_invalid_reason=upstream_bringup_changed
        mm_info "PUBLISHED_BRINGUP_UPSTREAM_SHA1=${published_upstream}"
        mm_info "CACHE_BRINGUP_UPSTREAM_SHA1=${cache_upstream}"
        mm_warn "UPSTREAM_BRINGUP_CHANGED=YES"
      fi
    fi
  fi
  # Integrity is required both to mark VALID and to allow stale-bringup local
  # rebuild from this final. Fail closed: outer sha256/tar_entries and inner
  # payload checksums win over a stale patched-bringup SHA.
  [[ -z "$bringup_invalid_reason" ]] && store_cache=1
  if ! engine_phase2_verify_existing_final_integrity \
    "$ver" "$bundle" "$sidecar" "$envf" "$store_cache"
  then
    engine_phase2_mark_existing INVALID \
      "${PHASE2_EXISTING_INTEGRITY_FAIL_REASON:-sha256}"
    return 0
  fi
  if [[ -n "$bringup_invalid_reason" ]]; then
    if ! engine_phase2_verify_inner_payloads_in_bundle "$bundle" "$ver"; then
      PHASE2_EXISTING_FINAL_INTEGRITY=FAIL
      engine_phase2_mark_existing INVALID \
        "${PHASE2_EXISTING_INTEGRITY_FAIL_REASON:-inner_images_sha256}"
      return 0
    fi
    engine_phase2_mark_existing INVALID "$bringup_invalid_reason"
    return 0
  fi
  engine_phase2_mark_existing VALID
  return 0
}

engine_disable_http_and_readiness() {
  mm_status_set HTTP_DISTRIBUTION DISABLED
  mm_state_set HTTP_DISTRIBUTION_READY NO
  mm_status_set HTTP_CONFIGURATION_READY FAIL
  mm_status_set UPGRADE_READINESS FAIL
  mm_status_set READINESS_RESULT ""
  mm_status_set READINESS_ARTIFACT_FINGERPRINT ""
}

engine_remove_invalid_phase2_final() {
  local ver="${1:-${TARGET_DP_VERSION:-${PHASE2_TARGET_VERSION}}}"
  local dest
  dest="$(engine_phase2_final_dir "$ver")"
  engine_disable_http_and_readiness
  mm_info "INVALID_EXISTING_BUNDLE_ACTION=DELETE_BEFORE_REBUILD"
  mm_info "INVALID_FINAL_REMOVED=YES path=${dest}"
  rm -rf "$dest"
  # Stale publish debris only. Keep ACPS/R2 .part files for resume.
  find "${MM_DP_PHASE2_ROOT}" -maxdepth 1 \( -name "${ver}.new.*" -o -name "${ver}.old.*" \) \
    -exec rm -rf {} + 2>/dev/null || true
  find "${MM_CACHE_ROOT}" -type f \( -name '*.download' -o -name '*.new.*' \) \
    -delete 2>/dev/null || true
  mm_ok "INVALID_FINAL_REMOVED=YES"
}

# After payloads are extracted into work, drop the old final so .new does not
# create a third ~30GiB copy. HTTP/readiness stay invalid until publish.
engine_release_phase2_final_after_extract() {
  local ver="${1:-${TARGET_DP_VERSION:-${PHASE2_TARGET_VERSION}}}"
  local dest
  dest="$(engine_phase2_final_dir "$ver")"
  engine_disable_http_and_readiness
  mm_info "PHASE2_EXISTING_FINAL_RELEASED_AFTER_EXTRACT=YES path=${dest}"
  rm -rf "$dest"
  find "${MM_DP_PHASE2_ROOT}" -maxdepth 1 \( -name "${ver}.new.*" -o -name "${ver}.old.*" \) \
    -exec rm -rf {} + 2>/dev/null || true
}

engine_mark_phase2_reused() {
  local ver="${1:-${TARGET_DP_VERSION:-${PHASE2_TARGET_VERSION}}}"
  mm_info "PHASE2_EXISTING_BUNDLE=VALID"
  mm_info "PHASE2_BUNDLE_ACTION=REUSE"
  mm_info "ACPS_DOWNLOAD_REQUIRED=NO"
  mm_info "PHASE2_BUNDLE_REBUILD_REQUIRED=NO"
  mm_info "FINAL_PHASE2_BUNDLE_COUNT=1"
  mm_info "VALID_EXISTING_BUNDLE_ACTION=REUSE"
  mm_info "NORMAL_ACPS_REDOWNLOAD=NO"
  mm_info "NORMAL_BUNDLE_REBUILD=NO"
  mm_status_set ACPS_CONNECTION REUSED
  mm_status_set ACPS_PHASE2_DOWNLOADED REUSED
  mm_status_set ACPS_CHECKSUM REUSED
  mm_status_set UPSTREAM_BRINGUP_DRIFT NO
  mm_status_set PATCHED_BRINGUP_APPLIED YES
  mm_status_set PHASE2_BUNDLE_ENTRY_COUNT 9
  mm_status_set PHASE2_BUNDLE_CHECKSUM PASS
  mm_state_set ACPS_CONNECTION REUSED
  mm_state_set ACPS_PHASE2_DOWNLOADED REUSED
  mm_state_set ACPS_CHECKSUM REUSED
  mm_state_set PHASE2_BUNDLE_ENTRY_COUNT 9
  mm_state_set PHASE2_BUNDLE_CHECKSUM PASS
  mm_state_set PHASE2_BUNDLE_ACTION REUSE
  mm_status_set PHASE2_TARGET_VERSION "${ver}"
}

engine_place_dp_phase2_final() {
  # Build the ~30GiB bundle directly in the atomic publish directory.
  # Avoids an intermediate dp-build copy of files + a second full bundle copy.
  # Valid finals are never replaced here — caller must REUSE or delete INVALID first.
  local files_src="$1"
  local ver="$2"
  dp2_set_version "$ver"
  DP_PHASE2_ROOT="$MM_DP_PHASE2_ROOT"

  if [[ "${MM_DRY_RUN}" == "1" ]]; then
    mm_info "DRY_RUN skip place_dp_phase2_final"
    return 0
  fi

  local dest="${MM_DP_PHASE2_ROOT}/${ver}"
  local dest_tmp="${dest}.new.$$"
  local list_count stable actual work_upstream
  local expected_input_bytes=0 f sz publish_start publish_elapsed
  local uvp_sha1 images_sha256
  rm -rf "$dest_tmp"
  # Stray .old from older builds — never used as rollback in this workflow.
  find "${MM_DP_PHASE2_ROOT}" -maxdepth 1 -name "${ver}.old.*" -exec rm -rf {} + 2>/dev/null || true
  mkdir -p "$dest_tmp" || mm_die "DP_PHASE2_STAGE_CREATE=FAIL"

  # File-set + patched bringup only. Large ACPS payloads were verified once at
  # cache acquire and are same-inode hardlinks — do not re-read ~30GiB here.
  if ! (
    dp2_assert_exact_files_dir "$files_src"
    dp2_verify_sha1_pair \
      "${files_src}/bringup_py3_dp_after_os_upgrade.sh" \
      "${files_src}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  ); then
    rm -rf "$dest_tmp"
    mm_die "DP_PHASE2_SOURCE_VALIDATE=FAIL"
  fi
  list_count="$(dp2_check_image_list "${files_src}/images-${ver}.list" | tail -n1)" \
    || { rm -rf "$dest_tmp"; mm_die "DP_PHASE2_IMAGE_LIST=FAIL"; }
  stable="$(dp2_stable_bundle_name)"

  expected_input_bytes=0
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    sz="$(stat -c%s "${files_src}/${f}" 2>/dev/null || echo 0)"
    expected_input_bytes=$((expected_input_bytes + sz))
  done

  mm_set_phase "Creating Phase 2 Bundle"
  mm_human_lines \
    "Creating the Phase 2 deployment bundle." \
    "The bundle is approximately 28–30 GiB." \
    "This step may take several minutes depending on disk performance." \
    "The program is still running normally." \
    "Please wait and do not close this terminal."
  # Bundle is written directly as ${dest_tmp}/${stable} (no intermediate copy).
  if ! mm_run_with_file_progress \
    "PHASE2_BUNDLE_CREATE" \
    "bundle=${stable} expected_input_bytes=${expected_input_bytes} destination=${dest_tmp}/${stable}" \
    "${dest_tmp}/${stable}" \
    "$expected_input_bytes" \
    "Still creating the Phase 2 deployment bundle..." \
    -- bash -c 'cd "$1" || exit 1; tar -cf "$2" "${@:3}"' \
       _ "$files_src" "${dest_tmp}/${stable}" "${DP_PHASE2_REQUIRED_FILES[@]}"
  then
    rm -rf "$dest_tmp"
    mm_die "DP_PHASE2_BUNDLE_BUILD=FAIL"
  fi
  dp2_assert_safe_tar_list "${dest_tmp}/${stable}" \
    || { rm -rf "$dest_tmp"; mm_die "DP_PHASE2_BUNDLE_TAR=FAIL"; }

  mm_set_phase "Calculating Bundle SHA256"
  if ! mm_sha256_write_sidecar_logged \
    "${dest_tmp}/${stable}" \
    "${dest_tmp}/${stable}.sha256" \
    "PHASE2_BUNDLE_SHA256_CREATE" \
    "bundle=${stable} bytes=$(stat -c%s "${dest_tmp}/${stable}")" \
    "Still calculating Phase 2 bundle SHA256..."
  then
    rm -rf "$dest_tmp"
    mm_die "DP_PHASE2_BUNDLE_SHA256_WRITE=FAIL"
  fi
  # Sidecar was just produced from this exact .new file; skip an immediate
  # second full read. Final published bytes are verified after atomic rename.

  # Validate generated patched bringup inside the file set that was just tarred.
  # Do not require equality with the repository vendor full copy.
  actual="$(sha1sum "${files_src}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
  if [[ -n "${BRINGUP_PATCHED_SHA1:-}" && "${actual,,}" != "${BRINGUP_PATCHED_SHA1,,}" ]]; then
    rm -rf "$dest_tmp"
    mm_die "VALIDATE_DP=FAIL patched_bringup_sha1"
  fi
  BRINGUP_PATCHED_SHA1="$actual"
  if [[ -z "${BRINGUP_PATCH_GENERATION:-}" ]]; then
    BRINGUP_PATCH_GENERATION="$(engine_current_bringup_patch_generation 2>/dev/null || true)"
  fi
  work_upstream="$(engine_phase2_work_upstream_path "$files_src")"
  if [[ -z "${BRINGUP_UPSTREAM_SHA1:-}" && -f "$work_upstream" ]]; then
    BRINGUP_UPSTREAM_SHA1="$(engine_bringup_sha1_of "$work_upstream")"
  fi
  if [[ -f "$work_upstream" ]]; then
    cp -f "$work_upstream" \
      "${dest_tmp}/bringup_py3_dp_after_os_upgrade.sh.upstream" || {
      rm -rf "$dest_tmp"
      mm_die "BRINGUP_UPSTREAM_PRESERVE=FAIL"
    }
    if [[ -f "${work_upstream}.sha1" ]]; then
      cp -f "${work_upstream}.sha1" \
        "${dest_tmp}/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1" || true
    else
      sha1sum "${dest_tmp}/bringup_py3_dp_after_os_upgrade.sh.upstream" \
        | awk '{print $1"  bringup_py3_dp_after_os_upgrade.sh.upstream"}' \
        >"${dest_tmp}/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1"
    fi
  fi

  local created_at commit
  created_at="$(mm_ts)"
  commit="$(git -C "${MM_PROJECT_ROOT}" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
  uvp_sha1="$(dp2_read_hash_field "${files_src}/aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1")"
  images_sha256="$(dp2_read_hash_field "${files_src}/images-${ver}.tar.sha256")"
  dp2_validate_sha1_hex "$uvp_sha1" || { rm -rf "$dest_tmp"; mm_die "UVP_SHA1=FAIL"; }
  dp2_validate_sha256_hex "$images_sha256" || { rm -rf "$dest_tmp"; mm_die "IMAGES_SHA256=FAIL"; }
  cat >"${dest_tmp}/release.env" <<EOF
TARGET_DP_VERSION=${ver}
PHASE2_ARTIFACT_VERSION=${ver}
# Deprecated alias for older consumers; prefer TARGET_DP_VERSION.
DP_PHASE2_VERSION=${ver}
CREATED_AT=${created_at}
FILE_COUNT=${DP_PHASE2_FILE_COUNT}
STABLE_BUNDLE_NAME=${stable}
IMAGE_LIST_COUNT=${list_count}
SOURCE_HOST=acps
SOURCE_PATH=provision
VERIFICATION_RESULT=PASS
SOURCE_REPOSITORY_COMMIT=${commit}
BRINGUP_UPSTREAM_SHA1=${BRINGUP_UPSTREAM_SHA1:-}
BRINGUP_PATCH_GENERATION=${BRINGUP_PATCH_GENERATION:-}
BRINGUP_PATCHED_SHA1=${BRINGUP_PATCHED_SHA1}
UVP_VERSION=${ver}
UVP_SHA1=${uvp_sha1}
IMAGES_VERSION=${ver}
IMAGES_SHA256=${images_sha256}
ACPS_SOURCE_VERSION=${ver}
EOF
  if dp2_release_has_secret "${dest_tmp}/release.env"; then
    rm -rf "$dest_tmp"
    mm_die "RELEASE_ENV_SECRET=FAIL"
  fi

  # Preserve small ACPS metadata for the Ubuntu extra-package closure before
  # dropping the large work tree.
  engine_preserve_phase2_prereq_sources "$files_src" "$ver" \
    || mm_die "PHASE2_PREREQ_SOURCE_PRESERVE=FAIL"

  # .new is fully built — free ACPS source/work before rename so peak is only
  # source(+bundle in .new) then final alone. Keep MM_KEEP_PHASE2_SOURCES=1
  # only for debugging (not for production 100GB-class hosts).
  if [[ "${MM_KEEP_PHASE2_SOURCES:-0}" != "1" ]]; then
    engine_cleanup_phase2_sources "$ver"
  fi

  sync -f "${dest_tmp}/${stable}" 2>/dev/null || sync

  # Atomic publish: .new.<pid> → final. Valid finals are never replaced here.
  # Invalid leftovers (if any) are removed — no .old rollback generation.
  mm_set_phase "Publishing Phase 2 Artifacts"
  publish_start="$(date +%s)"
  mm_info "DP_PHASE2_ATOMIC_PUBLISH_START dest=${dest} bundle=${stable}"
  mm_info "MAX_LARGE_ARTIFACT_COPIES=2"
  mkdir -p "$(dirname "$dest")" || { rm -rf "$dest_tmp"; mm_die "DP_PHASE2_DEST_PARENT=FAIL"; }
  if [[ -e "$dest" ]]; then
    mm_warn "PHASE2_FINAL_PREEXISTING=REMOVE path=${dest}"
    rm -rf "$dest"
  fi
  if ! mv -f "$dest_tmp" "$dest"; then
    rm -rf "$dest_tmp"
    mm_die "DP_PHASE2_PUBLISH_MOVE=FAIL"
  fi
  publish_elapsed=$(( $(date +%s) - publish_start ))
  mm_ok "DP_PHASE2_ATOMIC_PUBLISH=PASS dest=${dest} bundle=${stable} elapsed=${publish_elapsed}s"

  mm_set_phase "Verifying Published Bundle"
  mm_human_lines \
    "Verifying the published Phase 2 bundle before marking it ready." \
    "This is the final integrity check and may take several minutes."
  if ! mm_verify_sha256_pair_logged \
    "${dest}/${stable}" \
    "${dest}/${stable}.sha256" \
    "PHASE2_FINAL_SHA256_VERIFY" \
    "Still verifying the published Phase 2 bundle SHA256..."
  then
    rm -rf "$dest"
    mm_die "DP_PHASE2_PUBLISHED_SHA256=FAIL"
  fi
  if ! dp2_assert_safe_tar_list "${dest}/${stable}"; then
    rm -rf "$dest"
    mm_die "DP_PHASE2_PUBLISHED_TAR=FAIL"
  fi

  # Ensure obsolete generation paths are absent under this version root
  rm -rf "${dest}/releases" "${dest}/current" "${dest}/previous" \
    "${dest}/.staging" "${dest}/files" 2>/dev/null || true
  find "${MM_DP_PHASE2_ROOT}" -maxdepth 1 -name "${ver}.old.*" -exec rm -rf {} + 2>/dev/null || true

  PHASE2_BUNDLE_ENTRY_COUNT="${DP_PHASE2_FILE_COUNT}"
  mm_state_set PHASE2_BUNDLE_ENTRY_COUNT "$PHASE2_BUNDLE_ENTRY_COUNT"
  mm_state_set PHASE2_BUNDLE_CHECKSUM PASS
  mm_state_set PHASE2_BUNDLE_ACTION "${PHASE2_BUNDLE_ACTION:-CREATE}"
  mm_mark_changed
  mm_ok "DP_PHASE2_FINAL=PASS path=${dest} bundle=${stable}"
  mm_info "FINAL_PHASE2_BUNDLE_COUNT=1"
}

engine_validate_phase2_prereq_http_layout() {
  local dp="$1"
  local extras="${dp}/extras"
  local state="${extras}/phase2-ubuntu-prerequisites.state"
  local py="${MM_PROJECT_ROOT}/scripts/lib/phase2_ubuntu_prerequisites.py"
  [[ -f "$state" ]] || {
    mm_error "HTTP_LAYOUT=FAIL missing ${state}"
    return 1
  }
  if ! python3 "$py" validate-state --dest "$extras"; then
    mm_error "HTTP_LAYOUT=FAIL phase2_prereq_state_contract"
    return 1
  fi
  local required count
  required="$(awk -F= '$1=="PHASE2_PREREQ_REQUIRED"{print $2; exit}' "$state")"
  count="$(awk -F= '$1=="PHASE2_PREREQ_PACKAGE_COUNT"{print $2; exit}' "$state")"
  if [[ "$required" == "NO" ]]; then
    mm_info "PHASE2_PREREQ_HTTP=NOT_REQUIRED"
    return 0
  fi
  mm_info "PHASE2_PREREQ_HTTP=REQUIRED count=${count}"
  return 0
}

engine_record_phase2_prereq_release_identity() {
  local ver="${TARGET_DP_VERSION:-}"
  local envf="${MM_DP_PHASE2_ROOT}/${ver}/release.env"
  local state="${MM_DP_PHASE2_ROOT}/${ver}/extras/phase2-ubuntu-prerequisites.state"
  local tmp required count sha build publication
  [[ -n "$ver" && -f "$envf" && -f "$state" ]] || return 0
  required="$(awk -F= '$1=="PHASE2_PREREQ_REQUIRED"{print $2; exit}' "$state")"
  count="$(awk -F= '$1=="PHASE2_PREREQ_PACKAGE_COUNT"{print $2; exit}' "$state")"
  sha="$(awk -F= '$1=="PHASE2_PREREQ_SHA256"{print $2; exit}' "$state")"
  build="$(awk -F= '$1=="PHASE2_PREREQ_BUILD"{print $2; exit}' "$state")"
  publication="$(awk -F= '$1=="PHASE2_PREREQ_PUBLICATION"{print $2; exit}' "$state")"
  tmp="$(mktemp "${envf}.prereq.XXXXXX")"
  grep -vE '^PHASE2_PREREQ_(REQUIRED|PACKAGE_COUNT|SHA256|BUILD|PUBLICATION)=' "$envf" >"$tmp" || true
  {
    printf 'PHASE2_PREREQ_REQUIRED=%s\n' "$required"
    printf 'PHASE2_PREREQ_PACKAGE_COUNT=%s\n' "$count"
    printf 'PHASE2_PREREQ_SHA256=%s\n' "$sha"
    printf 'PHASE2_PREREQ_BUILD=%s\n' "$build"
    printf 'PHASE2_PREREQ_PUBLICATION=%s\n' "$publication"
  } >>"$tmp"
  if python3 "${MM_PROJECT_ROOT}/scripts/lib/phase2_ubuntu_prerequisites.py" \
    validate-state --dest "${MM_DP_PHASE2_ROOT}/${ver}/extras" >/dev/null
  then
    mv -f "$tmp" "$envf"
    chmod 0644 "$envf" 2>/dev/null || true
  else
    rm -f "$tmp"
    mm_die "PHASE2_PREREQ=FAIL reason=release_identity_state"
  fi
}

engine_validate_http_layout() {
  # Validate on-disk layout matching client HTTP URL contract (no production nginx reload).
  mm_force_phase2_target
  local ver="${TARGET_DP_VERSION}"
  local sel="$MM_SELECTIVE_ROOT"
  local dp="${MM_DP_PHASE2_ROOT}/${ver}"
  local stable bundle sidecar fp op human
  stable="$(dp2_stable_bundle_name)"
  bundle="${dp}/${stable}"
  sidecar="${dp}/${stable}.sha256"

  if ! mm_is_phase2_only; then
    [[ -d "${sel}/ubuntu" || -L "${sel}/ubuntu" ]] || mm_die "HTTP_LAYOUT=FAIL missing /ubuntu tree"
    [[ -d "${sel}/shared/offline" ]] || mm_die "HTTP_LAYOUT=FAIL missing /offline tree"
  fi
  [[ -d "${MM_CLIENT_ROOT}" ]] || mkdir -p "${MM_CLIENT_ROOT}"
  [[ -f "${dp}/release.env" ]] || mm_die "HTTP_LAYOUT=FAIL missing release.env"
  [[ -f "$bundle" ]] || mm_die "HTTP_LAYOUT=FAIL missing ${stable}"
  [[ -f "$sidecar" ]] || mm_die "HTTP_LAYOUT=FAIL missing ${stable}.sha256"
  engine_validate_phase2_prereq_http_layout "$dp" \
    || mm_die "HTTP_LAYOUT=FAIL phase2_prereq"

  # Full SHA256 only when needed. Menu status collection must set MM_SKIP_BUNDLE_SHA256=1.
  # Within one Enable HTTP run, verify once then reuse via MM_BUNDLE_SHA256_DONE_FP.
  if [[ "${MM_SKIP_BUNDLE_SHA256:-0}" != "1" ]]; then
    fp="$(mm_file_fingerprint "$bundle" 2>/dev/null || true)"
    if [[ -n "${MM_BUNDLE_SHA256_DONE_FP:-}" && -n "$fp" && "${MM_BUNDLE_SHA256_DONE_FP}" == "$fp" ]]; then
      mm_info "SHA256_VERIFICATION_SKIP reason=already_verified_this_run file=${stable}"
    else
      op="${MM_SHA256_OPERATION:-layout}"
      human="Still verifying the Phase 2 bundle SHA256..."
      case "$op" in
        enable-http)
          human="Still verifying the Phase 2 bundle SHA256 before enabling HTTP distribution..."
          ;;
        verify-readiness)
          human="Still verifying the Phase 2 bundle SHA256 for upgrade readiness..."
          ;;
      esac
      if ! mm_verify_sha256_pair_logged \
        "$bundle" \
        "$sidecar" \
        "SHA256_VERIFICATION" \
        "$human" \
        "operation=${op}"
      then
        mm_die "HTTP_LAYOUT=FAIL sha256"
      fi
      MM_BUNDLE_SHA256_DONE_FP="$fp"
    fi
  fi

  # Refuse generation structures
  if [[ -L "${dp}/current" || -L "${dp}/previous" || -d "${dp}/releases" ]]; then
    mm_die "HTTP_LAYOUT=FAIL generation_structure_present"
  fi
  if [[ -L "${sel}/current" || -e "${sel}/published.previous" ]]; then
    mm_die "HTTP_LAYOUT=FAIL selective_generation_structure_present"
  fi

  if [[ "${MM_SKIP_HTTP_VALIDATE:-0}" == "1" ]]; then
    # Pre-nginx layout checks defer live probes; never WARN as a network failure.
    if [[ "${MM_HTTP_VALIDATE_DEFER:-0}" == "1" ]]; then
      mm_info "HTTP_VALIDATION=DEFERRED reason=nginx_not_enabled_yet"
      mm_info "HTTP validation will run after nginx is enabled."
    else
      mm_info "HTTP_VALIDATION=DEFERRED reason=skip_http_validate"
    fi
    mm_state_set HTTP_CONFIGURATION_READY PASS
    return 0
  fi

  if [[ "${MM_HTTP_VALIDATE_MOCK_FAIL:-0}" == "1" ]]; then
    mm_error "HTTP_VALIDATION=FAIL mock"
    mm_state_set HTTP_CONFIGURATION_READY FAIL
    return 1
  fi

  local stable_name
  stable_name="$(dp2_stable_bundle_name)"
  # A. Local nginx smoke — service/alias/filesystem (never classify as IP detection).
  if ! engine_http_local_smoke "$ver" "$stable_name"; then
    mm_state_set HTTP_CONFIGURATION_READY FAIL
    return 1
  fi
  # B. Advertised address smoke — configured Mirror Server IP / routing.
  if ! engine_http_advertised_smoke "$ver" "$stable_name"; then
    mm_state_set HTTP_CONFIGURATION_READY FAIL
    return 1
  fi
  mm_state_set HTTP_CONFIGURATION_READY PASS
  mm_ok "HTTP_VALIDATION=PASS"
  return 0
}

# Build the concrete artifact URL list for a given HTTP base.
engine_http_smoke_urls() {
  local base="${1%/}"
  local ver="$2"
  local stable="$3"
  local urls=(
    "${base}/client/stage-dp-phase2.sh"
    "${base}/client/stage-dp-phase2.sh.sha256"
    "${base}/client/upgrade-phase2.sh"
    "${base}/client/public-keyring.gpg"
    "${base}/dp-phase2/${ver}/release.env"
    "${base}/dp-phase2/${ver}/${stable}.sha256"
  )
  if ! mm_is_phase2_only; then
    urls+=(
      "${base}/ubuntu/"
      "${base}/ubuntu-security/"
      "${base}/offline/meta-release-lts"
      "${base}/client/dp-offline-upgrade-xenial-to-bionic.sh"
      "${base}/client/dp-offline-upgrade-xenial-to-bionic.sh.sha256"
      "${base}/client/dp-launch-xenial-to-bionic.sh"
      "${base}/client/dp-launch-bionic-to-focal.sh"
      "${base}/client/dp-launch-focal-to-jammy.sh"
      "${base}/client/dp-launch-jammy-to-noble.sh"
      "${base}/client/upgrade-xenial-to-bionic.sh"
      "${base}/client/upgrade-bionic-to-focal.sh"
      "${base}/client/upgrade-focal-to-jammy.sh"
      "${base}/client/upgrade-jammy-to-noble.sh"
      "${base}/client/public.gpg"
    )
  fi
  local extras_state="${MM_DP_PHASE2_ROOT}/${ver}/extras/phase2-ubuntu-prerequisites.state"
  if [[ -f "$extras_state" ]]; then
    urls+=("${base}/dp-phase2/${ver}/extras/phase2-ubuntu-prerequisites.state")
    local required
    required="$(awk -F= '$1=="PHASE2_PREREQ_REQUIRED"{print $2; exit}' "$extras_state")"
    if [[ "$required" == "YES" ]]; then
      urls+=(
        "${base}/dp-phase2/${ver}/extras/phase2-ubuntu-prerequisites.tar.gz"
        "${base}/dp-phase2/${ver}/extras/phase2-ubuntu-prerequisites.tar.gz.sha256"
        "${base}/dp-phase2/${ver}/extras/phase2-ubuntu-prerequisites.manifest.json"
      )
    fi
  fi
  local u
  for u in "${urls[@]}"; do
    printf '%s\n' "$u"
  done
}

engine_http_probe_url() {
  local u="$1"
  local body code bytes
  body="$(mktemp)"
  code="$(curl -sS -o "$body" -w '%{http_code}' --connect-timeout 5 --max-time 15 "$u" 2>/dev/null || echo 000)"
  bytes="$(wc -c <"$body" | tr -d ' ')"
  rm -f "$body"
  if [[ "$code" != "200" ]]; then
    printf '%s\n' "$code"
    return 1
  fi
  if ! [[ "$bytes" =~ ^[0-9]+$ ]] || [[ "$bytes" -le 0 ]]; then
    # Stable reason token for operators + regression greps (empty_body).
    mm_error "HTTP_PROBE=FAIL reason=empty_body url=$(basename "$u" 2>/dev/null || printf '%s' "$u")"
    printf '%s\n' "$code"
    return 1
  fi
  printf '%s\n' "$code"
  return 0
}

engine_nginx_error_log_tail() {
  local log="${MM_NGINX_ERROR_LOG:-/var/log/nginx/error.log}"
  if [[ -f "$log" && -r "$log" ]]; then
    tail -n 20 "$log" 2>/dev/null | tr '\n' '|' | sed 's/|$//'
  fi
}

engine_http_local_smoke() {
  local ver="${1:-${TARGET_DP_VERSION}}"
  local stable="${2:-}"
  local base u code
  [[ -n "$stable" ]] || stable="$(dp2_stable_bundle_name)"
  base="${MM_VERIFY_HTTP_BASE:-http://127.0.0.1}"
  base="${base%/}"
  mm_info "HTTP_LOCAL_SMOKE_START base=${base}"
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    if ! code="$(engine_http_probe_url "$u")"; then
      mm_error "HTTP_LOCAL_SMOKE=FAIL"
      mm_error "HTTP_FAILURE_CLASS=NGINX_OR_FILESYSTEM"
      mm_error "HTTP_STATUS_CODE=${code}"
      mm_error "url=${u}"
      mm_error "NGINX_ERROR_LOG_TAIL=$(engine_nginx_error_log_tail)"
      return 1
    fi
    mm_info "HTTP_LOCAL_CHECK url=${u} code=${code}"
  done < <(engine_http_smoke_urls "$base" "$ver" "$stable")
  mm_ok "HTTP_LOCAL_SMOKE=PASS"
  return 0
}

engine_http_advertised_smoke() {
  local ver="${1:-${TARGET_DP_VERSION}}"
  local stable="${2:-}"
  local base u code configured
  [[ -n "$stable" ]] || stable="$(dp2_stable_bundle_name)"

  # Prefer operator-confirmed Mirror Server IP; fall back to MIRROR_HTTP_URL.
  configured="${MIRROR_SERVER_IP:-}"
  if [[ -z "$configured" ]]; then
    mm_load_gui_config
    configured="${MIRROR_SERVER_IP:-}"
  fi
  if [[ -z "$configured" && -n "${MIRROR_HTTP_URL:-}" ]]; then
    configured="$(mirror_host_extract_ipv4_from_url "${MIRROR_HTTP_URL}" || true)"
  fi
  if [[ -z "$configured" && -n "${RESOLVED_MIRROR_HOST_IPV4:-}" ]]; then
    configured="${RESOLVED_MIRROR_HOST_IPV4}"
  fi
  if [[ -z "$configured" ]]; then
    mm_error "HTTP_ADVERTISED_SMOKE=FAIL"
    mm_error "HTTP_FAILURE_CLASS=ADVERTISED_ADDRESS_OR_NETWORK"
    mm_error "reason=no_configured_mirror_server_ip"
    return 1
  fi
  base="http://${configured}"
  # Allow test override of advertised probe base without changing configured IP.
  if [[ -n "${MM_VERIFY_ADVERTISED_HTTP_BASE:-}" ]]; then
    base="${MM_VERIFY_ADVERTISED_HTTP_BASE}"
  fi
  base="${base%/}"
  # Skip redundant advertised probe when it is the same as local base (unit tests).
  if [[ "$base" == "${MM_VERIFY_HTTP_BASE:-http://127.0.0.1}" ]]; then
    mm_info "HTTP_ADVERTISED_SMOKE=SKIPPED reason=same_as_local_base"
    mm_ok "HTTP_ADVERTISED_SMOKE=PASS"
    return 0
  fi
  mm_info "HTTP_ADVERTISED_SMOKE_START base=${base}"
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    if ! code="$(engine_http_probe_url "$u")"; then
      mm_error "HTTP_ADVERTISED_SMOKE=FAIL"
      mm_error "HTTP_FAILURE_CLASS=ADVERTISED_ADDRESS_OR_NETWORK"
      mm_error "HTTP_STATUS_CODE=${code}"
      mm_error "url=${u}"
      return 1
    fi
    mm_info "HTTP_ADVERTISED_CHECK url=${u} code=${code}"
  done < <(engine_http_smoke_urls "$base" "$ver" "$stable")
  mm_ok "HTTP_ADVERTISED_SMOKE=PASS"
  return 0
}

engine_cleanup_temps() {
  local ver="${TARGET_DP_VERSION:-}"
  r2_cleanup_package || true
  engine_cleanup_phase2_sources "$ver"
  rm -rf "${MM_CACHE_ROOT}/os-core-extract" 2>/dev/null || true
  find "${MM_CACHE_ROOT}" \( -name '*.part' -o -name '*.download' -o -name '*.new.*' \) \
    -type f -delete 2>/dev/null || true
  # Stale version dirs left by interrupted publishes.
  find "${MM_DP_PHASE2_ROOT}" -maxdepth 1 \( -name '*.new.*' -o -name '*.old.*' \) \
    -exec rm -rf {} + 2>/dev/null || true
  mm_ok "TEMP_CLEANUP=PASS"
}

engine_compute_readiness() {
  local f="${MM_STATUS_FILE}"
  local keys=(
    CONFIGURATION_READY
    ACPS_CONNECTION
    ACPS_PHASE2_DOWNLOADED
    ACPS_CHECKSUM
    UPSTREAM_BRINGUP_DRIFT
    PATCHED_BRINGUP_APPLIED
    PHASE2_BUNDLE_ENTRY_COUNT
    PHASE2_BUNDLE_CHECKSUM
    CLIENT_FILES_READY
    HTTP_CONFIGURATION_READY
  )
  local k v all=PASS
  mm_normalize_preparation_mode
  if ! mm_is_phase2_only; then
    keys+=(
      R2_OS_CORE_DOWNLOADED
      R2_OS_CORE_CHECKSUM
      OS_MIRROR_READY
    )
  fi
  # Readiness requires HTTP distribution enabled (menu order: enable before verify).
  if ! mm_http_distribution_enabled; then
    all=FAIL
  fi
  for k in "${keys[@]}"; do
    v="$(mm_status_get "$k")"
    case "$k" in
      UPSTREAM_BRINGUP_DRIFT)
        # NO = unchanged vs reference; NON_BLOCKING = changed but ACPS sidecar OK.
        [[ "$v" == "NO" || "$v" == "NON_BLOCKING" ]] || all=FAIL
        ;;
      PHASE2_BUNDLE_ENTRY_COUNT)
        [[ "$v" == "9" ]] || all=FAIL
        ;;
      PATCHED_BRINGUP_APPLIED)
        [[ "$v" == "YES" || "$v" == "PASS" ]] || all=FAIL
        ;;
      *)
        [[ "$v" == "PASS" || "$v" == "YES" || "$v" == "REUSED" ]] || all=FAIL
        ;;
    esac
  done
  mm_force_phase2_target
  mm_status_set TARGET_DP_VERSION "${TARGET_DP_VERSION}"
  mm_status_set PHASE2_TARGET_VERSION "${PHASE2_TARGET_VERSION}"
  mm_status_set PREPARATION_MODE "${PREPARATION_MODE}"
  mm_status_set UPGRADE_READINESS "$all"
  if [[ "$all" == "PASS" ]]; then
    mm_record_readiness_validated
  else
    mm_status_set READINESS_RESULT FAIL
  fi
  printf 'UPGRADE_READINESS=%s\n' "$all"
  [[ "$all" == "PASS" ]]
}

engine_write_install_report() {
  local result="${1:-PASS}"
  mm_state_set INSTALL_RESULT "$result"
  mm_state_set FINISHED_AT "$(mm_ts)"
  mm_state_set FILES_CHANGED "${MM_FILES_CHANGED}"
  mm_status_set LAST_EXECUTION_RESULT "$result"
  mm_status_set LOG_PATH "${MM_LOG_FILE:-}"
  if [[ -n "${MM_STATE_DIR:-}" ]]; then
    cp -f "${MM_STATE_DIR}/state.env" "${MM_STATE_DIR}/report.env" 2>/dev/null || true
    mm_info "REPORT_PATH=${MM_STATE_DIR}/report.env"
  fi
  printf 'INSTALL_RESULT=%s\n' "$result"
  printf 'FILES_CHANGED=%s\n' "${MM_FILES_CHANGED}"
  printf 'RUN_ID=%s\n' "${MM_RUN_ID:-}"
}

engine_download_and_prepare() {
  local cache work dest stable saved_upstream
  mm_load_gui_config
  mm_normalize_preparation_mode
  mm_force_phase2_target
  engine_resolve_paths
  mm_state_init
  mm_state_set PREPARATION_MODE "${PREPARATION_MODE}"
  mm_state_set PHASE2_TARGET_VERSION "${PHASE2_TARGET_VERSION}"
  mm_state_set DP_PHASE2_SOURCE ACPS
  if mm_is_phase2_only; then
    mm_state_set OS_CORE_SOURCE NOT_REQUIRED
  else
    mm_state_set OS_CORE_SOURCE R2
  fi

  if ! mm_config_base_ready; then
    mm_state_set CONFIGURATION_READY FAIL
    mm_die "CONFIGURATION_READY=FAIL"
  fi
  if ! mm_acquisition_auth_ready; then
    mm_state_set ACPS_AUTH_READY FAIL
    mm_die "ACQUISITION_AUTH_READY=FAIL reason=missing_acps_credentials"
  fi
  mm_state_set CONFIGURATION_READY PASS
  mm_state_set ACPS_AUTH_READY PASS
  if ! mm_require_configured_mirror_server_ip; then
    mm_die "MIRROR_SERVER_IP_REQUIRED=YES"
  fi
  mm_validate_dp_version "$TARGET_DP_VERSION"
  [[ "$TARGET_DP_VERSION" == "$PHASE2_TARGET_VERSION" ]] \
    || mm_die "PHASE2_TARGET=FAIL expected=${PHASE2_TARGET_VERSION} got=${TARGET_DP_VERSION}"
  dp2_set_version "$TARGET_DP_VERSION"

  engine_preflight_host
  mm_acquire_install_lock
  # Bind long-running prepare to the config identity observed at start so a
  # concurrent Save cannot publish PREPARED for a stale generation.
  if declare -F mm_wf_set >/dev/null 2>&1; then
    mm_wf_set OPERATION_START_CONFIG_SHA256 "$(mm_wf_config_sha256 || true)" || true
  fi
  engine_assert_same_filesystem_layout

  # Build tooling must exist before preparation. Generated hop clients are NOT
  # required yet — they are produced after OS Core is READY (avoids circular gate).
  mkdir -p "$MM_CLIENT_ROOT"
  if ! mm_check_client_build_prerequisites_ready; then
    mm_die "CLIENT_BUILD_PREREQUISITES_READY=FAIL"
  fi
  mm_info "CLIENT_FILES_READY_REQUIRED_BEFORE_PREPARE=NO"
  if mm_is_phase2_only; then
    mm_info "OS_HOP_CLIENT_FILES_REQUIRED=NO"
    mm_info "CLIENT_FILES_READY_AT_START=NOT_REQUIRED"
  else
    engine_assess_os_core_for_prepare
    mm_info "OS_CORE_READY_AT_START=${OS_CORE_READY_AT_START}"
    mm_info "OS_CORE_ACTION=${OS_CORE_ACTION}"
    mm_info "R2_DOWNLOAD_REQUIRED=${R2_DOWNLOAD_REQUIRED}"
    mm_info "OS_MATERIALIZE_REQUIRED=${OS_MATERIALIZE_REQUIRED}"
    if [[ "${OS_CORE_READY_AT_START}" == "YES" ]]; then
      if mm_client_files_ready "${MM_CLIENT_ROOT}"; then
        mm_info "CLIENT_SET_PRESENT_AT_START=YES"
      else
        mm_info "CLIENT_SET_PRESENT_AT_START=NO"
        mm_info "CLIENT_FILES_READY_AT_START=NOT_REQUIRED"
      fi
    else
      mm_info "CLIENT_FILES_READY_AT_START=NOT_REQUIRED"
      mm_info "CLIENT_BUILD_DEFERRED_UNTIL_OS_CORE_READY=YES"
    fi
  fi

  # Decide Phase 2 action before any large Phase 2 download/build.
  engine_assess_phase2_final "$TARGET_DP_VERSION"
  case "${PHASE2_EXISTING_BUNDLE}" in
    VALID)
      PHASE2_BUNDLE_ACTION=REUSE
      PHASE2_REBUILD_REQUIRED=NO
      ACPS_DOWNLOAD_REQUIRED=NO
      PHASE2_REBUILD_SOURCE=NONE
      ACPS_REDOWNLOAD_AVOIDED=NO
      ;;
    INVALID)
      PHASE2_BUNDLE_ACTION=REBUILD
      PHASE2_REBUILD_REQUIRED=YES
      mm_info "PHASE2_EXISTING_INVALID_REASON=${PHASE2_EXISTING_INVALID_REASON:-}"
      engine_disable_http_and_readiness
      if engine_phase2_existing_final_reusable; then
        # Keep the verified final until payloads are extracted. Do not claim
        # verified_cache_reuse — the source is the existing final bundle.
        PHASE2_REBUILD_SOURCE=EXISTING_FINAL
        ACPS_DOWNLOAD_REQUIRED=NO
        ACPS_REDOWNLOAD_AVOIDED=YES
        dest="$(engine_phase2_final_dir "$TARGET_DP_VERSION")"
        stable="$(dp2_stable_bundle_name)"
        PHASE2_EXISTING_FINAL_BYTES="$(mm_file_bytes "${dest}/${stable}" 2>/dev/null || echo 0)"
        mm_info "PHASE2_REBUILD_SOURCE=EXISTING_FINAL"
        mm_info "ACPS_DOWNLOAD_REQUIRED=NO reason=existing_final_reuse"
        mm_info "ACPS_REDOWNLOAD_AVOIDED=YES"
        mm_info "MAX_LARGE_ARTIFACT_COPIES=2"
      else
        PHASE2_REBUILD_SOURCE=ACPS
        ACPS_REDOWNLOAD_AVOIDED=NO
        if declare -F acps_is_verified_cache >/dev/null 2>&1 \
          && acps_is_verified_cache "$(acps_cache_dir "$TARGET_DP_VERSION")" 2>/dev/null; then
          ACPS_DOWNLOAD_REQUIRED=NO
          mm_info "ACPS_DOWNLOAD_REQUIRED=NO reason=verified_cache_reuse"
        else
          ACPS_DOWNLOAD_REQUIRED=YES
          mm_info "ACPS_DOWNLOAD_REQUIRED=YES"
        fi
        mm_info "PHASE2_REBUILD_SOURCE=ACPS"
        engine_remove_invalid_phase2_final "$TARGET_DP_VERSION"
        mm_info "MAX_LARGE_ARTIFACT_COPIES=2"
      fi
      ;;
    *)
      PHASE2_BUNDLE_ACTION=CREATE
      PHASE2_REBUILD_REQUIRED=YES
      ACPS_DOWNLOAD_REQUIRED=YES
      PHASE2_REBUILD_SOURCE=ACPS
      ACPS_REDOWNLOAD_AVOIDED=NO
      PHASE2_EXISTING_BUNDLE=ABSENT
      mm_info "PHASE2_EXISTING_BUNDLE=ABSENT"
      mm_info "PHASE2_BUNDLE_ACTION=CREATE"
      mm_info "PHASE2_REBUILD_SOURCE=ACPS"
      mm_info "MAX_LARGE_ARTIFACT_COPIES=2"
      ;;
  esac
  mm_info "PHASE2_BUNDLE_ACTION=${PHASE2_BUNDLE_ACTION}"
  export PHASE2_BUNDLE_ACTION PHASE2_REBUILD_REQUIRED ACPS_DOWNLOAD_REQUIRED
  export PHASE2_REBUILD_SOURCE ACPS_REDOWNLOAD_AVOIDED
  export PHASE2_EXISTING_INVALID_REASON PHASE2_EXISTING_FINAL_BYTES

  if mm_is_phase2_only; then
    # PHASE2_ONLY must never download R2 OS Core.
    mm_info "PHASE2_ONLY_R2_DOWNLOAD_COUNT=0"
    mm_status_set R2_OS_CORE_DOWNLOADED NOT_REQUIRED
    mm_status_set R2_OS_CORE_CHECKSUM NOT_REQUIRED
    mm_status_set OS_MIRROR_READY NOT_REQUIRED
    OS_CORE_PACKAGE_BYTES=0
    OS_CORE_PAYLOAD_BYTES=0
  elif [[ "${OS_CORE_ACTION:-DOWNLOAD_VERIFY_MATERIALIZE}" == "REUSE_VERIFIED" ]]; then
    mm_info "OS_CORE_ACTION=REUSE_VERIFIED"
    mm_info "VERIFY_OR_ACQUIRE_OS_CORE=REUSE_VERIFIED"
    mm_info "R2_DOWNLOAD_REQUIRED=NO"
    mm_info "HEAVY_ARTIFACT_ACTION=REUSE_VERIFIED"
    mm_info "R2_DOWNLOAD_REQUIRED=NO"
    mm_info "OS_MATERIALIZE_REQUIRED=NO"
    mm_status_set R2_OS_CORE_DOWNLOADED REUSED
    mm_status_set R2_OS_CORE_CHECKSUM REUSED
    mm_status_set OS_MIRROR_READY PASS
    OS_CORE_PACKAGE_BYTES=0
    OS_CORE_PAYLOAD_BYTES=0
  else
    mm_set_phase "Downloading OS Core Artifacts"
    r2_require_url
    r2_download_package
    mm_set_phase "Verifying OS Core Artifacts"
    engine_verify_os_core_package "$OS_CORE_PACKAGE"
  fi

  if [[ "${PHASE2_BUNDLE_ACTION}" == "REUSE" ]]; then
    ACPS_EXPECTED_BYTES=0
  elif [[ "${PHASE2_REBUILD_SOURCE}" == "EXISTING_FINAL" ]]; then
    ACPS_EXPECTED_BYTES=0
    mm_info "ACPS_CONNECTION=NOT_REQUIRED reason=existing_final_reuse"
    mm_status_set ACPS_CONNECTION REUSED
    mm_state_set ACPS_CONNECTION REUSED
  else
    if [[ -z "${DP_PHASE2_SOURCE_BASE:-}" ]]; then
      ACPS_BASE_URL="$ACPS_BASE_URL_FIXED"
    fi
    acps_setup_curl_auth
    if acps_test_connection; then
      mm_state_set ACPS_CONNECTION PASS
    else
      mm_state_set ACPS_CONNECTION FAIL
      acps_cleanup_curl_auth
      mm_die "ACPS_CONNECTION=FAIL"
    fi
    ACPS_EXPECTED_BYTES="$(acps_expected_bytes_hint "${ACPS_EFFECTIVE_BASE:-}")"
    ACPS_EXPECTED_BYTES="${ACPS_EXPECTED_BYTES:-0}"
    # Drop netrc before long OS/materialize work; acps_acquire_all reinstalls.
    acps_cleanup_curl_auth
  fi
  engine_verify_disk_space

  if [[ "${MM_DRY_RUN}" == "1" ]]; then
    mm_info "DRY_RUN=YES"
    engine_write_install_report PASS
    printf 'DRY_RUN=YES\nFILES_CHANGED=NO\n'
    return 0
  fi

  if ! mm_is_phase2_only; then
    if [[ "${OS_CORE_ACTION:-}" == "REUSE_VERIFIED" ]]; then
      mm_info "OS_MATERIALIZE_REQUIRED=NO"
      mm_ok "OS_MIRROR_MATERIALIZE=REUSED"
    else
      engine_materialize_os_mirror "$OS_CORE_PACKAGE"
      # Free R2 package immediately after OS materialize — before Phase 2 peak.
      r2_cleanup_package || true
      mm_info "R2_PACKAGE_REMOVED_AFTER_MATERIALIZE=YES"
      mm_info "R2_PACKAGE_PRESENT_DURING_PHASE2_BUILD=NO"
    fi
  fi

  if [[ "${PHASE2_BUNDLE_ACTION}" == "REUSE" ]]; then
    engine_mark_phase2_reused "$TARGET_DP_VERSION"
    engine_prepare_phase2_ubuntu_prerequisites
    engine_cleanup_temps
    mm_state_set HTTP_DISTRIBUTION_READY NO
    mm_status_set HTTP_DISTRIBUTION DISABLED
    mm_info "VERIFY_OR_REBUILD_CURRENT_CLIENT_SET=START"
    mm_info "PUBLISH_CURRENT_CLIENT_SET=PENDING"
    mm_record_artifacts_prepared || mm_die "HEAVY_ARTIFACTS_PREPARED=FAIL"
    if ! engine_finalize_local_client_set; then
      mm_die "DOWNLOAD_AND_PREPARE=FAIL_CLIENT_SET_FINALIZATION"
    fi
    mm_info "CLIENT_FILES_READY_REQUIRED_AFTER_PREPARE=YES"
    mm_record_download_validated
    engine_write_install_report PASS
    mm_ok "DOWNLOAD_AND_PREPARE=PASS mode=${PREPARATION_MODE} phase2=REUSE"
    return 0
  fi

  # CREATE/REBUILD: remeasure free space after R2 cleanup + invalid final removal.
  engine_verify_disk_space

  work="${MM_CACHE_ROOT}/acps-work/${TARGET_DP_VERSION}/$(mm_run_id)"
  if [[ "${PHASE2_REBUILD_SOURCE}" == "EXISTING_FINAL" ]]; then
    engine_stage_work_from_existing_final "$TARGET_DP_VERSION" "$work"
    saved_upstream="$(engine_phase2_saved_upstream_path "$TARGET_DP_VERSION")"
    [[ -f "$saved_upstream" ]] || mm_die "BRINGUP_UPSTREAM_COPY_MISSING path=${saved_upstream}"
    # Patch from the saved immutable upstream before deleting the old final.
    engine_apply_local_bringup_patch "$work" "$saved_upstream"
    # Release the old final before writing .new (peak = work + new tar).
    engine_release_phase2_final_after_extract "$TARGET_DP_VERSION"
    engine_place_dp_phase2_final "$work" "$TARGET_DP_VERSION"
    engine_prepare_phase2_ubuntu_prerequisites "$work"
    mm_status_set ACPS_PHASE2_DOWNLOADED REUSED
    mm_status_set ACPS_CHECKSUM REUSED
    mm_status_set UPSTREAM_BRINGUP_DRIFT NO
    mm_state_set ACPS_PHASE2_DOWNLOADED REUSED
    mm_state_set ACPS_CHECKSUM REUSED
  else
    acps_acquire_all "$TARGET_DP_VERSION"
    cache="$(acps_cache_dir "$TARGET_DP_VERSION")"
    [[ -d "$cache" ]] || mm_die "ACPS_CACHE_MISSING"

    engine_verify_acps_upstream_bringup "$cache"

    # Unchanged large ACPS files are hard-linked (same inode); only the
    # generated patched bringup is a new small file. Cache upstream stays
    # immutable. No cache→work full tree copy.
    engine_stage_acps_work_from_cache "$cache" "$work"
    engine_apply_local_bringup_patch "$work" \
      "${cache}/bringup_py3_dp_after_os_upgrade.sh"
    engine_assert_work_ready_for_bundle "$cache" "$work" "$TARGET_DP_VERSION" \
      || mm_die "ACPS_WORK_VALIDATE=FAIL"
    engine_place_dp_phase2_final "$work" "$TARGET_DP_VERSION"
    engine_prepare_phase2_ubuntu_prerequisites "$work"
  fi

  engine_cleanup_temps

  mm_state_set HTTP_DISTRIBUTION_READY NO
  mm_status_set HTTP_DISTRIBUTION DISABLED
  mm_info "VERIFY_OR_REBUILD_CURRENT_CLIENT_SET=START"
  mm_info "PUBLISH_CURRENT_CLIENT_SET=PENDING"
  mm_record_artifacts_prepared || mm_die "HEAVY_ARTIFACTS_PREPARED=FAIL"
  if ! engine_finalize_local_client_set; then
    mm_die "DOWNLOAD_AND_PREPARE=FAIL_CLIENT_SET_FINALIZATION"
  fi
  mm_info "CLIENT_FILES_READY_REQUIRED_AFTER_PREPARE=YES"
  mm_record_download_validated
  engine_write_install_report PASS
  mm_ok "DOWNLOAD_AND_PREPARE=PASS mode=${PREPARATION_MODE} phase2=${PHASE2_BUNDLE_ACTION}"
}

engine_render_nginx_site() {
  # Render nginx site for the single final selective + Phase 2 layout.
  local tpl=""
  local base="${MM_MIRROR_ROOT}"
  local ver="${TARGET_DP_VERSION:-6.6.0}"
  local candidates=(
    "${MM_PROJECT_ROOT}/templates/nginx.conf"
    "${MM_PROJECT_ROOT}/../templates/nginx.conf"
    /usr/local/lib/ubuntu-mirror/templates/nginx.conf
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      tpl="$c"
      break
    fi
  done
  [[ -n "$tpl" ]] || mm_die "NGINX_TEMPLATE=FAIL"
  sed \
    -e "s|/var/spool/apt-mirror/selective|${base}/selective|g" \
    -e "s|/var/spool/apt-mirror/client|${base}/client|g" \
    -e "s|/var/spool/apt-mirror/dp-phase2/6.6.0|${base}/dp-phase2/${ver}|g" \
    -e "s|/var/spool/apt-mirror/dp-phase2|${base}/dp-phase2|g" \
    -e "s|/dp-phase2/6.6.0/|/dp-phase2/${ver}/|g" \
    -e "s|location = /dp-phase2/6.6.0|location = /dp-phase2/${ver}|g" \
    "$tpl"
}

engine_nginx_bin() { printf '%s\n' "${MM_NGINX_BIN:-nginx}"; }
engine_systemctl_bin() { printf '%s\n' "${MM_SYSTEMCTL_BIN:-systemctl}"; }

engine_enable_http_distribution() {
  # Real nginx enable: layout check → permission closure → site install →
  # nginx -t → enable/reload → local + advertised HTTP smoke.
  # On any failure: restore previous site config/service state; preserve artifacts.
  mm_load_gui_config
  engine_resolve_paths
  dp2_set_version "$TARGET_DP_VERSION"
  # Heartbeat-labeled SHA256 during Enable HTTP (once per run via DONE_FP).
  export MM_SHA256_OPERATION="${MM_SHA256_OPERATION:-enable-http}"
  MM_BUNDLE_SHA256_DONE_FP=""

  # Require operator-confirmed Mirror Server IP before enabling HTTP.
  if ! mm_require_configured_mirror_server_ip; then
    mm_status_set HTTP_DISTRIBUTION DISABLED
    mm_state_set HTTP_DISTRIBUTION_READY NO
    mm_die "HTTP_DISTRIBUTION=FAIL MIRROR_SERVER_IP_REQUIRED"
  fi

  # Ensure host-pinned clients exist via the same authoritative finalizer used
  # by Download and Prepare (no duplicate rebuild logic).
  # First check is silent (on-disk presence only) to avoid duplicate CLIENT_FILES_READY logs.
  local clients_on_disk=0
  if mm_is_phase2_only; then
    mm_client_files_ready_phase2 "${MM_CLIENT_ROOT}" && clients_on_disk=1
    if [[ "$clients_on_disk" -ne 1 ]]; then
      mm_info "OS_HOP_CLIENT_FILES_REQUIRED=NO"
      mm_info "CLIENT_FILES_ON_DISK_READY=NO"
      engine_ensure_phase2_helpers || true
    fi
  else
    # Keep Enable HTTP aligned with Download-and-Prepare: verify-only fixtures
    # ship complete on-disk clients without selective hop trees for a rebuild.
    if [[ "${MM_CLIENT_FINALIZATION_MODE:-full}" == "verify-only" ]]; then
      mm_info "CLIENT_FINALIZATION_MODE=verify-only"
      if mm_client_files_ready "${MM_CLIENT_ROOT}"; then
        clients_on_disk=1
      fi
    else
      engine_assess_client_set_for_finalize
      mm_info "CLIENT_SET_STATE=${CLIENT_SET_STATE}"
      mm_info "CLIENT_SET_ACTION=${CLIENT_SET_ACTION}"
      if [[ "$CLIENT_SET_ACTION" == "REUSE_CURRENT" || "$CLIENT_SET_ACTION" == "REUSE_VERIFIED" ]]; then
        clients_on_disk=1
        engine_bind_reused_client_set_workflow \
          || mm_die "HTTP_DISTRIBUTION=FAIL client workflow binding"
      elif [[ -f "${MM_SELECTIVE_ROOT}/state/READY" ]]; then
        mm_info "CLIENT_FILES_ON_DISK_READY=STALE_OR_MISSING — rebuilding current source"
        mm_info "DOWNLOAD_PREPARE_USES_AUTHORITATIVE_CLIENT_FINALIZER=YES"
        engine_rebuild_publish_local_client_set 1 \
          || mm_die "HTTP_DISTRIBUTION=FAIL client rebuild"
        clients_on_disk=1
      fi
    fi
  fi
  if [[ "$clients_on_disk" -eq 1 ]]; then
    mm_info "CLIENT_FILES_ON_DISK_READY=PASS"
  fi

  # Single authoritative CLIENT_FILES_READY log for this Enable HTTP run.
  if ! mm_check_client_files_ready; then
    mm_status_set HTTP_DISTRIBUTION DISABLED
    mm_state_set HTTP_DISTRIBUTION_READY NO
    mm_die "HTTP_DISTRIBUTION=FAIL CLIENT_FILES_READY"
  fi
  mm_info "ENABLE_HTTP_USES_AUTHORITATIVE_CLIENT_FINALIZER=YES"

  # Normalize + verify HTTP public tree permissions before touching nginx.
  chmod 0755 "${MM_MIRROR_ROOT}" 2>/dev/null || true
  if [[ -d "${MM_CLIENT_ROOT}" ]]; then
    mm_normalize_http_public_tree_permissions "${MM_CLIENT_ROOT}" client \
      || mm_die "HTTP_DISTRIBUTION=FAIL CLIENT_PUBLIC_PERMISSION_NORMALIZE"
  fi
  if [[ -d "${MM_DP_PHASE2_ROOT}" ]]; then
    mm_normalize_http_public_tree_permissions "${MM_DP_PHASE2_ROOT}" phase2 \
      || mm_die "HTTP_DISTRIBUTION=FAIL PHASE2_PUBLIC_PERMISSION_NORMALIZE"
  fi
  if [[ -d "${MM_SELECTIVE_ROOT}" ]]; then
    # Ensure nginx can traverse the selective root (avoid chmod -R / full-tree walk).
    chmod 0755 "${MM_SELECTIVE_ROOT}" 2>/dev/null || true
    for _sel_sub in ubuntu shared offline keys hops; do
      [[ -d "${MM_SELECTIVE_ROOT}/${_sel_sub}" ]] || continue
      chmod 0755 "${MM_SELECTIVE_ROOT}/${_sel_sub}" 2>/dev/null || true
    done
    if [[ -d "${MM_SELECTIVE_ROOT}/shared/offline" ]]; then
      chmod 0755 "${MM_SELECTIVE_ROOT}/shared" "${MM_SELECTIVE_ROOT}/shared/offline" 2>/dev/null || true
    fi
  fi
  if ! mm_verify_http_publication_permission_closure \
    "${MM_MIRROR_ROOT}" "${MM_CLIENT_ROOT}" "${MM_DP_PHASE2_ROOT}" "$TARGET_DP_VERSION"
  then
    mm_status_set HTTP_DISTRIBUTION DISABLED
    mm_state_set HTTP_DISTRIBUTION_READY NO
    mm_die "HTTP_DISTRIBUTION=FAIL HTTP_PUBLICATION_PERMISSION_CLOSURE"
  fi
  mm_ok "CLIENT_FILES_PERMISSION_READY=PASS"

  # Layout validation without requiring live HTTP yet (defer probes until nginx is up)
  local prev_skip="${MM_SKIP_HTTP_VALIDATE:-0}"
  local prev_defer="${MM_HTTP_VALIDATE_DEFER:-0}"
  MM_SKIP_HTTP_VALIDATE=1
  MM_HTTP_VALIDATE_DEFER=1
  if ! engine_validate_http_layout; then
    MM_SKIP_HTTP_VALIDATE="$prev_skip"
    MM_HTTP_VALIDATE_DEFER="$prev_defer"
    mm_status_set HTTP_DISTRIBUTION DISABLED
    mm_state_set HTTP_DISTRIBUTION_READY NO
    mm_die "HTTP_DISTRIBUTION=FAIL layout"
  fi
  MM_SKIP_HTTP_VALIDATE="$prev_skip"
  MM_HTTP_VALIDATE_DEFER="$prev_defer"

  if [[ "${MM_DRY_RUN}" == "1" ]]; then
    mm_info "DRY_RUN skip nginx enable"
    mm_status_set HTTP_DISTRIBUTION ENABLED
    mm_state_set HTTP_DISTRIBUTION_READY YES
    mm_record_http_validated
    mm_ok "HTTP_DISTRIBUTION=ENABLED (dry-run)"
    return 0
  fi

  # Unit-test hook: layout already validated; skip writing /etc/nginx (see bootstrap tests for full path).
  if [[ "${MM_SKIP_NGINX_APPLY:-0}" == "1" ]]; then
    mm_warn "NGINX_APPLY=SKIPPED_TEST"
    mm_status_set HTTP_DISTRIBUTION ENABLED
    mm_state_set HTTP_DISTRIBUTION_READY YES
    mm_status_set HTTP_CONFIGURATION_READY PASS
    mm_record_http_validated
    mm_ok "HTTP_DISTRIBUTION=ENABLED"
    return 0
  fi

  local site_name="${MM_NGINX_SITE_NAME:-apt-mirror}"
  local site_avail="${MM_NGINX_SITE_AVAIL:-/etc/nginx/sites-available/${site_name}}"
  local site_en="${MM_NGINX_SITE_ENABLED:-/etc/nginx/sites-enabled/${site_name}}"
  local nginx_bin systemctl_bin ngx_tmp backup=""
  local prev_active=0 prev_enabled=0
  local prev_avail_existed=0
  local prev_en_kind=missing prev_en_target="" prev_en_backup=""
  local prev_default_kind=missing prev_default_target="" prev_default_backup=""
  local default_site
  nginx_bin="$(engine_nginx_bin)"
  systemctl_bin="$(engine_systemctl_bin)"
  default_site="$(dirname "$site_en")/default"

  command -v "$nginx_bin" >/dev/null 2>&1 || mm_die "NGINX_PACKAGE=FAIL binary missing"
  command -v "$systemctl_bin" >/dev/null 2>&1 || mm_die "SYSTEMCTL=FAIL missing"

  if "$systemctl_bin" is-active --quiet nginx 2>/dev/null; then
    prev_active=1
  fi
  if "$systemctl_bin" is-enabled --quiet nginx 2>/dev/null; then
    prev_enabled=1
  fi

  ngx_tmp="$(mktemp)"
  engine_render_nginx_site >"$ngx_tmp"
  if grep -qE 'selective/current|published\.previous' "$ngx_tmp"; then
    rm -f "$ngx_tmp"
    mm_die "NGINX_CONFIG=FAIL generation path reference"
  fi

  mkdir -p "$(dirname "$site_avail")" "$(dirname "$site_en")"
  # Snapshot only the Menu 3 publication topology (not a recursive /etc/nginx backup).
  if [[ -e "$site_avail" || -L "$site_avail" ]]; then
    prev_avail_existed=1
    backup="${site_avail}.bak.mm.$(date -u +%Y%m%d%H%M%S)"
    cp -a "$site_avail" "$backup"
  fi
  if [[ -L "$site_en" ]]; then
    prev_en_kind=symlink
    prev_en_target="$(readlink "$site_en")"
  elif [[ -f "$site_en" ]]; then
    prev_en_kind=file
    prev_en_backup="${site_en}.bak.mm.en.$(date -u +%Y%m%d%H%M%S)"
    cp -a "$site_en" "$prev_en_backup"
  elif [[ -e "$site_en" ]]; then
    prev_en_kind=other
    prev_en_backup="${site_en}.bak.mm.en.$(date -u +%Y%m%d%H%M%S)"
    cp -a "$site_en" "$prev_en_backup"
  fi
  if [[ -L "$default_site" ]]; then
    prev_default_kind=symlink
    prev_default_target="$(readlink "$default_site")"
  elif [[ -f "$default_site" ]]; then
    prev_default_kind=file
    prev_default_backup="${default_site}.bak.mm.default.$(date -u +%Y%m%d%H%M%S)"
    cp -a "$default_site" "$prev_default_backup"
  elif [[ -e "$default_site" ]]; then
    prev_default_kind=other
    prev_default_backup="${default_site}.bak.mm.default.$(date -u +%Y%m%d%H%M%S)"
    cp -a "$default_site" "$prev_default_backup"
  fi

  install -m 0644 "$ngx_tmp" "$site_avail"
  rm -f "$ngx_tmp"
  ln -sfn "$site_avail" "$site_en"
  if [[ -e "$default_site" || -L "$default_site" ]]; then
    rm -f "$default_site"
  fi

  local restore_nginx
  restore_nginx() {
    local rollback_config=FAIL rollback_svc=FAIL
    if [[ "$prev_avail_existed" -eq 1 && -n "${backup:-}" && -e "$backup" ]]; then
      cp -a "$backup" "$site_avail"
    else
      rm -f "$site_avail" 2>/dev/null || true
    fi
    case "${prev_en_kind}" in
      symlink)
        ln -sfn "$prev_en_target" "$site_en"
        ;;
      file|other)
        rm -f "$site_en" 2>/dev/null || true
        if [[ -n "${prev_en_backup:-}" && -e "$prev_en_backup" ]]; then
          cp -a "$prev_en_backup" "$site_en"
        fi
        ;;
      *)
        rm -f "$site_en" 2>/dev/null || true
        ;;
    esac
    case "${prev_default_kind}" in
      symlink)
        ln -sfn "$prev_default_target" "$default_site"
        ;;
      file|other)
        rm -f "$default_site" 2>/dev/null || true
        if [[ -n "${prev_default_backup:-}" && -e "$prev_default_backup" ]]; then
          cp -a "$prev_default_backup" "$default_site"
        fi
        ;;
      *)
        rm -f "$default_site" 2>/dev/null || true
        ;;
    esac
    rollback_config=PASS
    mm_ok "NGINX_ROLLBACK_CONFIG=PASS"
    mm_warn "NGINX_ROLLBACK=YES restored previous publication topology"
    if command -v "$nginx_bin" >/dev/null 2>&1; then
      "$nginx_bin" -t >/dev/null 2>&1 || true
    fi
    if command -v "$systemctl_bin" >/dev/null 2>&1; then
      if [[ "$prev_active" -eq 1 ]]; then
        "$systemctl_bin" reload nginx 2>/dev/null \
          || "$systemctl_bin" restart nginx 2>/dev/null \
          || true
      else
        "$systemctl_bin" stop nginx 2>/dev/null || true
      fi
      if [[ "$prev_enabled" -eq 1 ]]; then
        "$systemctl_bin" enable nginx 2>/dev/null || true
      else
        "$systemctl_bin" disable nginx 2>/dev/null || true
      fi
      rollback_svc=PASS
      mm_ok "NGINX_ROLLBACK_SERVICE_STATE=PASS"
    fi
    mm_status_set HTTP_DISTRIBUTION DISABLED
    mm_state_set HTTP_DISTRIBUTION_READY NO
    mm_status_set HTTP_ENABLE_RESULT FAIL
    mm_info "HTTP_ENABLE_RESULT=FAIL"
    mm_info "HTTP_DISTRIBUTION=DISABLED"
    mm_info "PREPARED_ARTIFACTS_PRESERVED=YES"
    mm_info "NGINX_ROLLBACK_CONFIG=${rollback_config}"
    mm_info "NGINX_ROLLBACK_SERVICE_STATE=${rollback_svc}"
  }

  if [[ "${MM_NGINX_TEST_FAIL:-0}" == "1" ]] || ! "$nginx_bin" -t; then
    restore_nginx
    mm_die "NGINX_TEST=FAIL"
  fi
  mm_ok "NGINX_TEST=PASS"

  if ! "$systemctl_bin" enable nginx >/dev/null 2>&1; then
    restore_nginx
    mm_die "NGINX_ENABLE=FAIL"
  fi
  if ! "$systemctl_bin" is-enabled --quiet nginx 2>/dev/null; then
    restore_nginx
    mm_die "NGINX_ENABLE=FAIL"
  fi
  if "$systemctl_bin" is-active --quiet nginx 2>/dev/null; then
    if ! "$systemctl_bin" reload nginx; then
      "$systemctl_bin" restart nginx || {
        restore_nginx
        mm_die "NGINX_RELOAD=FAIL"
      }
    fi
  else
    "$systemctl_bin" start nginx || {
      restore_nginx
      mm_die "NGINX_START=FAIL"
    }
  fi
  mm_ok "NGINX_ENABLE=PASS"

  # Concrete artifact HTTP smoke (root URL / is not a failure criterion)
  if [[ "${MM_SKIP_HTTP_VALIDATE:-0}" != "1" ]]; then
    if [[ "${MM_HTTP_VALIDATE_MOCK_FAIL:-0}" == "1" ]] || ! engine_validate_http_layout; then
      restore_nginx
      mm_die "HTTP_SMOKE=FAIL"
    fi
  else
    # Test-only path: live probes intentionally skipped. Never WARN as network failure.
    mm_state_set HTTP_CONFIGURATION_READY PASS
    mm_info "HTTP_VALIDATION=DEFERRED reason=skip_http_validate"
  fi

  mm_status_set HTTP_DISTRIBUTION ENABLED
  mm_state_set HTTP_DISTRIBUTION_READY YES
  mm_status_set HTTP_CONFIGURATION_READY PASS
  mm_status_set HTTP_ENABLE_RESULT PASS
  mm_record_http_validated
  mm_info "CLIENT_HTTP_READY=PASS"
  mm_ok "HTTP_DISTRIBUTION=ENABLED"
}
