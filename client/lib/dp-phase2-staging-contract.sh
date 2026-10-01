#!/usr/bin/env bash
# Phase 2 staging completion contract (authoritative PASS evidence for bringup).
# Staging invalidates this at mutation start and persists PASS only after
# artifacts, prerequisites, and bringup controller publication succeed.
# shellcheck shell=bash

if ! declare -F log >/dev/null 2>&1; then
  log() { printf '%s\n' "$*"; }
fi

PHASE2_STAGING_CONTRACT_ENV_DEFAULT="${PHASE2_STAGING_CONTRACT_ENV_DEFAULT:-/opt/aelladata/os-upgrade/offline/phase2-bringup/staging-result.env}"
PHASE2_STAGING_HELPER_MANIFEST_DEFAULT="${PHASE2_STAGING_HELPER_MANIFEST_DEFAULT:-/opt/aelladata/os-upgrade/offline/phase2-bringup/phase2-helper-generation.manifest}"
PHASE2_STAGING_ARTIFACT_ROOT_DEFAULT="${PHASE2_STAGING_ARTIFACT_ROOT_DEFAULT:-/opt/aelladata/aelladeb_py3}"

dp_phase2_staging_helper_manifest_path() {
  if [[ -n "${PHASE2_STAGING_HELPER_MANIFEST:-}" ]]; then
    printf '%s' "$PHASE2_STAGING_HELPER_MANIFEST"
    return 0
  fi
  if declare -F p2b_dir >/dev/null 2>&1; then
    printf '%s/phase2-helper-generation.manifest' "$(p2b_dir)"
    return 0
  fi
  printf '%s' "$PHASE2_STAGING_HELPER_MANIFEST_DEFAULT"
}

dp_phase2_staging_artifact_root() {
  printf '%s' "${PHASE2_STAGING_ARTIFACT_ROOT:-$PHASE2_STAGING_ARTIFACT_ROOT_DEFAULT}"
}

dp_phase2_artifact_tree_hash() {
  local target="${1:-}" root f
  [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  root="$(dp_phase2_staging_artifact_root)"
  [[ -d "$root" ]] || return 1
  (
    cd "$root" || exit 1
    for f in \
      aelladeb_py3_common.tar.gz \
      aelladeb_py3_common.tar.gz.sha1 \
      "aella-uvp-2404_${target}ubuntu1_amd64.deb" \
      "aella-uvp-2404_${target}ubuntu1_amd64.deb.sha1" \
      "images-${target}.list" \
      "images-${target}.tar" \
      "images-${target}.tar.sha256"
    do
      [[ -f "$f" ]] || exit 1
      sha256sum "$f"
    done
  ) | sha256sum | awk '{print tolower($1)}'
}

dp_phase2_staging_contract_env_path() {
  if [[ -n "${PHASE2_STAGING_CONTRACT_ENV:-}" ]]; then
    printf '%s' "$PHASE2_STAGING_CONTRACT_ENV"
    return 0
  fi
  if declare -F p2b_dir >/dev/null 2>&1; then
    printf '%s/staging-result.env' "$(p2b_dir)"
    return 0
  fi
  printf '%s' "$PHASE2_STAGING_CONTRACT_ENV_DEFAULT"
}

dp_phase2_invalidate_staging_contract() {
  local dest parent reason="${1:-staging_mutation}"
  dest="$(dp_phase2_staging_contract_env_path)"
  parent="$(dirname "$dest")"
  mkdir -p "$parent" 2>/dev/null || true
  chmod 0700 "$parent" 2>/dev/null || true
  rm -f "$dest" 2>/dev/null || true
  log "PHASE2_STAGING_CONTRACT=INVALIDATED reason=${reason} path=${dest}"
  return 0
}

# Persist authoritative staging PASS.
# Args: target_dp_version bundle_sha256 prereq_identity_sha256 helper_generation_sha256 artifact_tree_sha256
dp_phase2_persist_staging_contract() {
  local target="${1:-}" bundle_sha="${2:-}" prereq_sha="${3:-}" helper_sha="${4:-}" artifact_sha="${5:-}"
  local dest parent tmp
  [[ -n "$target" ]] || return 1
  [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  bundle_sha="$(printf '%s' "$bundle_sha" | tr 'A-F' 'a-f')"
  prereq_sha="$(printf '%s' "$prereq_sha" | tr 'A-F' 'a-f')"
  helper_sha="$(printf '%s' "$helper_sha" | tr 'A-F' 'a-f')"
  artifact_sha="$(printf '%s' "$artifact_sha" | tr 'A-F' 'a-f')"
  [[ "$bundle_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$prereq_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$helper_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$artifact_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  dest="$(dp_phase2_staging_contract_env_path)"
  parent="$(dirname "$dest")"
  mkdir -p "$parent" || return 1
  chmod 0700 "$parent" 2>/dev/null || true
  tmp="${dest}.tmp.$$.${RANDOM:-0}"
  {
    echo "PHASE2_STAGE_RESULT=PASS"
    echo "ARTIFACT_STAGING_RESULT=PASS"
    echo "TARGET_DP_VERSION=${target}"
    echo "PHASE2_BUNDLE_SHA256=${bundle_sha}"
    echo "PHASE2_PREREQ_IDENTITY_SHA256=${prereq_sha}"
    echo "PHASE2_HELPER_GENERATION_SHA256=${helper_sha}"
    echo "PHASE2_ARTIFACT_TREE_SHA256=${artifact_sha}"
    echo "PHASE2_STAGING_CONTRACT_PERSISTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  log "PHASE2_STAGING_CONTRACT=PASS path=${dest} target=${target} B=${bundle_sha} P=${prereq_sha} H=${helper_sha} A=${artifact_sha}"
  return 0
}

dp_phase2_staging_contract_read_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -F= -v k="$key" '$1==k {print $2; exit}' "$file"
}

# Validate consumable prerequisite state for REQUIRED=YES and REQUIRED=NO.
# Uses dp2_prereq_* helpers when available; otherwise fail closed.
dp_phase2_staging_contract_validate_prereq_state() {
  local state="" verdict="" state_rc=0 prev_e=0
  if ! declare -F dp2_prereq_find_state >/dev/null 2>&1 \
    || ! declare -F dp2_prereq_validate_state_contract >/dev/null 2>&1; then
    # Source prereq lib from common locations when gate runs in lifecycle.
    local cand
    for cand in \
      "${LIB_DIR:-}/dp-phase2-ubuntu-prerequisites.sh" \
      "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dp-phase2-ubuntu-prerequisites.sh" \
      "/opt/aelladata/os-upgrade/offline/phase2-bringup/lib/dp-phase2-ubuntu-prerequisites.sh"
    do
      if [[ -f "$cand" ]]; then
        # shellcheck source=/dev/null
        source "$cand"
        break
      fi
    done
  fi
  if ! declare -F dp2_prereq_find_state >/dev/null 2>&1 \
    || ! declare -F dp2_prereq_validate_state_contract >/dev/null 2>&1; then
    printf '%s\n' "prereq_helpers_missing"
    return 1
  fi
  if ! state="$(dp2_prereq_find_state)"; then
    printf '%s\n' "state_missing"
    return 1
  fi
  [[ $- == *e* ]] && prev_e=1
  set +e
  verdict="$(dp2_prereq_validate_state_contract "$state")"
  state_rc=$?
  [[ "$prev_e" -eq 1 ]] && set -e
  if [[ "$state_rc" -ne 0 ]]; then
    printf '%s\n' "${verdict:-state_invalid}"
    return 1
  fi
  printf '%s\n' "${verdict:-ok}"
  return 0
}

# Hard gate before detached worker launch.
# Arg: expected target version (required).
# On failure prints diagnostics to stdout and returns non-zero.
dp_phase2_bringup_staging_gate() {
  local want_target="${1:-}"
  local dest result artifact_result got_target prereq_verdict
  local bundle_sha prereq_sha helper_sha artifact_sha helper_manifest helper_actual
  local prereq_state prereq_identity prereq_actual artifact_actual
  dest="$(dp_phase2_staging_contract_env_path)"

  if [[ -z "$want_target" ]]; then
    echo "PHASE2_STAGING_GATE=FAIL reason=target_missing"
    echo "VENDOR_BRINGUP_EXECUTED=NO"
    echo "REMEDIATION=Re-run Phase 2 staging (stage-dp-phase2.sh) to completion, then retry bringup."
    return 1
  fi

  if [[ ! -f "$dest" ]]; then
    echo "PHASE2_STAGING_GATE=FAIL reason=staging_contract_missing path=${dest}"
    echo "ARTIFACT_STAGING_RESULT=MISSING"
    echo "PHASE2_STAGE_RESULT=MISSING"
    echo "VENDOR_BRINGUP_EXECUTED=NO"
    echo "REMEDIATION=Phase 2 staging did not finish with PASS (or was invalidated by a later staging attempt). Re-run stage-dp-phase2.sh through FINAL_VALIDATION + prerequisite staging + bringup controller publication, then retry bringup. Verified bundle cache may be reused; a full ~30GB re-download is not required when VERIFIED cache exists."
    return 1
  fi

  result="$(dp_phase2_staging_contract_read_value "$dest" PHASE2_STAGE_RESULT || true)"
  artifact_result="$(dp_phase2_staging_contract_read_value "$dest" ARTIFACT_STAGING_RESULT || true)"
  got_target="$(dp_phase2_staging_contract_read_value "$dest" TARGET_DP_VERSION || true)"
  bundle_sha="$(dp_phase2_staging_contract_read_value "$dest" PHASE2_BUNDLE_SHA256 || true)"
  prereq_sha="$(dp_phase2_staging_contract_read_value "$dest" PHASE2_PREREQ_IDENTITY_SHA256 || true)"
  helper_sha="$(dp_phase2_staging_contract_read_value "$dest" PHASE2_HELPER_GENERATION_SHA256 || true)"
  artifact_sha="$(dp_phase2_staging_contract_read_value "$dest" PHASE2_ARTIFACT_TREE_SHA256 || true)"
  bundle_sha="$(printf '%s' "$bundle_sha" | tr 'A-F' 'a-f')"
  prereq_sha="$(printf '%s' "$prereq_sha" | tr 'A-F' 'a-f')"
  helper_sha="$(printf '%s' "$helper_sha" | tr 'A-F' 'a-f')"
  artifact_sha="$(printf '%s' "$artifact_sha" | tr 'A-F' 'a-f')"

  if [[ "$result" != "PASS" ]]; then
    echo "PHASE2_STAGING_GATE=FAIL reason=stage_result_not_pass value=${result:-empty}"
    echo "PHASE2_STAGE_RESULT=${result:-MISSING}"
    echo "VENDOR_BRINGUP_EXECUTED=NO"
    echo "REMEDIATION=Re-run Phase 2 staging until PHASE2_STAGE_RESULT=PASS, then retry bringup."
    return 1
  fi
  if [[ "$artifact_result" != "PASS" ]]; then
    echo "PHASE2_STAGING_GATE=FAIL reason=artifact_staging_not_pass value=${artifact_result:-empty}"
    echo "ARTIFACT_STAGING_RESULT=${artifact_result:-MISSING}"
    echo "VENDOR_BRINGUP_EXECUTED=NO"
    echo "REMEDIATION=Re-run Phase 2 staging until ARTIFACT_STAGING_RESULT=PASS, then retry bringup."
    return 1
  fi
  if [[ "$got_target" != "$want_target" ]]; then
    echo "PHASE2_STAGING_GATE=FAIL reason=target_mismatch want=${want_target} got=${got_target:-empty}"
    echo "VENDOR_BRINGUP_EXECUTED=NO"
    echo "REMEDIATION=Re-run Phase 2 staging for target ${want_target}, then retry bringup with matching --version."
    return 1
  fi
  if [[ ! "$bundle_sha" =~ ^[0-9a-f]{64}$ || ! "$prereq_sha" =~ ^[0-9a-f]{64}$ \
    || ! "$helper_sha" =~ ^[0-9a-f]{64}$ || ! "$artifact_sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "PHASE2_STAGING_GATE=FAIL reason=identity_receipt_incomplete"
    echo "VENDOR_BRINGUP_EXECUTED=NO"
    echo "REMEDIATION=Re-run Phase 2 staging with the current generation-bound wrapper so B/P/H/A identities are persisted."
    return 1
  fi

  helper_manifest="$(dp_phase2_staging_helper_manifest_path)"
  if [[ ! -f "$helper_manifest" ]]; then
    echo "PHASE2_STAGING_GATE=FAIL reason=helper_manifest_missing path=${helper_manifest}"
    echo "VENDOR_BRINGUP_EXECUTED=NO"
    return 1
  fi
  helper_actual="$(sha256sum "$helper_manifest" | awk '{print tolower($1)}')"
  if [[ "$helper_actual" != "$helper_sha" ]]; then
    echo "PHASE2_STAGING_GATE=FAIL reason=helper_generation_identity_mismatch expected=${helper_sha} actual=${helper_actual}"
    echo "VENDOR_BRINGUP_EXECUTED=NO"
    return 1
  fi

  artifact_actual="$(dp_phase2_artifact_tree_hash "$want_target" 2>/dev/null || true)"
  if [[ ! "$artifact_actual" =~ ^[0-9a-f]{64}$ ]]; then
    echo "PHASE2_STAGING_GATE=FAIL reason=artifact_tree_identity_unavailable"
    echo "VENDOR_BRINGUP_EXECUTED=NO"
    return 1
  fi
  if [[ "$artifact_actual" != "$artifact_sha" ]]; then
    echo "PHASE2_STAGING_GATE=FAIL reason=artifact_tree_identity_mismatch expected=${artifact_sha} actual=${artifact_actual}"
    echo "VENDOR_BRINGUP_EXECUTED=NO"
    return 1
  fi

  local prev_e=0
  [[ $- == *e* ]] && prev_e=1
  set +e
  prereq_verdict="$(dp_phase2_staging_contract_validate_prereq_state)"
  local prereq_rc=$?
  [[ "$prev_e" -eq 1 ]] && set -e
  if [[ "$prereq_rc" -ne 0 ]]; then
    echo "PHASE2_STAGING_GATE=FAIL reason=prereq_state_${prereq_verdict:-invalid}"
    echo "PHASE2_PREREQ_CONTRACT=${prereq_verdict:-invalid}"
    echo "VENDOR_BRINGUP_EXECUTED=NO"
    echo "REMEDIATION=Prerequisite state is missing or incomplete under the artifact staging directory. Re-run stage-dp-phase2.sh so phase2-ubuntu-prerequisites.state is published (REQUIRED=YES or REQUIRED=NO), then retry bringup."
    return 1
  fi
  prereq_state="$(dp2_prereq_find_state 2>/dev/null || true)"
  prereq_identity="$(dirname "$prereq_state")/phase2-ubuntu-prerequisites.identity"
  if [[ -z "$prereq_state" || ! -f "$prereq_identity" ]]; then
    echo "PHASE2_STAGING_GATE=FAIL reason=prereq_identity_missing"
    echo "VENDOR_BRINGUP_EXECUTED=NO"
    return 1
  fi
  prereq_actual="$(sha256sum "$prereq_identity" | awk '{print tolower($1)}')"
  if [[ "$prereq_actual" != "$prereq_sha" ]]; then
    echo "PHASE2_STAGING_GATE=FAIL reason=prereq_identity_mismatch expected=${prereq_sha} actual=${prereq_actual}"
    echo "VENDOR_BRINGUP_EXECUTED=NO"
    return 1
  fi

  echo "PHASE2_STAGING_GATE=PASS"
  echo "PHASE2_STAGE_RESULT=PASS"
  echo "ARTIFACT_STAGING_RESULT=PASS"
  echo "PHASE2_PREREQ_CONTRACT=${prereq_verdict}"
  echo "TARGET_DP_VERSION=${got_target}"
  echo "PHASE2_BUNDLE_SHA256=${bundle_sha}"
  echo "PHASE2_PREREQ_IDENTITY_SHA256=${prereq_sha}"
  echo "PHASE2_HELPER_GENERATION_SHA256=${helper_sha}"
  echo "PHASE2_ARTIFACT_TREE_SHA256=${artifact_sha}"
  return 0
}
