#!/usr/bin/env bash
# Shared source DP product version capture / parse / recovery.
# Xenial Bash 4.3 compatible. Never source source-product.env as shell code.
# shellcheck shell=bash
# Schema version 1 — allowlisted KEY=VALUE only.

SOURCE_PRODUCT_ENV_SCHEMA_VERSION_CURRENT=1
SOURCE_PRODUCT_ENV_DEFAULT_PATH="${SOURCE_PRODUCT_ENV_DEFAULT_PATH:-/opt/aelladata/os-upgrade/offline/source-product.env}"
SOURCE_PRODUCT_STATE_ROOT_DEFAULT="${SOURCE_PRODUCT_STATE_ROOT_DEFAULT:-/opt/aelladata/os-upgrade/offline}"
SOURCE_PRODUCT_PHASE1_LOG_DEFAULT="${SOURCE_PRODUCT_PHASE1_LOG_DEFAULT:-/var/log/aella/offline_os_upgrade.log}"
SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT="${SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT:-/opt/aelladata/release-image.yml}"
SOURCE_PRODUCT_EVIDENCE_ROOT_DEFAULT="${SOURCE_PRODUCT_EVIDENCE_ROOT_DEFAULT:-/opt/aelladata/os-upgrade/offline/evidence/source-product-resolution}"
SOURCE_PRODUCT_MIN_AUTHORITATIVE_RELEASE_KEYS=2
SOURCE_PRODUCT_OS_STATE_FILE="${SOURCE_PRODUCT_OS_STATE_FILE:-}"
SOURCE_PRODUCT_BRINGUP_RESULT_ENV="${SOURCE_PRODUCT_BRINGUP_RESULT_ENV:-}"

# Diagnostics populated by spv_resolve_source_dp_version / diagnose helpers.
SPV_SOURCE_PRODUCT_ENV_PATH=""
SPV_SOURCE_PRODUCT_ENV_STATUS=""
SPV_SOURCE_VERSION_CAPTURE_STATUS=""
SPV_PHASE1_LOG_EVIDENCE_PATH=""
SPV_PHASE1_LOG_EVIDENCE_STATUS=""
SPV_PHASE1_LOG_EVIDENCE_RECORD_COUNT=0
SPV_PHASE1_LOG_EVIDENCE_COMPLETE_PASS_COUNT=0
SPV_PHASE1_LOG_EVIDENCE_UNIQUE_VERSION_COUNT=0
SPV_PHASE1_LOG_EVIDENCE_UNDETERMINED_COUNT=0
SPV_RELEASE_IMAGE_PATH=""
SPV_RELEASE_IMAGE_STATUS=""
SPV_RELEASE_IMAGE_AUTHORITATIVE_RECORD_COUNT=0
SPV_RELEASE_IMAGE_UNIQUE_VERSION_COUNT=0
SPV_OPERATOR_SOURCE_VERSION_STATUS=""
SPV_SOURCE_DP_VERSION=""
SPV_SOURCE_DP_VERSION_RAW=""
SPV_SOURCE_DP_VERSION_ORIGIN=""
SPV_SOURCE_DP_VERSION_CHECK=""
SPV_SOURCE_DP_VERSION_RESOLUTION=""
SPV_SOURCE_DP_VERSION_FAILURE_REASON=""
SPV_SOURCE_DP_VERSION_REMEDIATION=""
SPV_SOURCE_DP_VERSION_RECOVERY=""
SPV_DIAG_SUMMARY=""
SPV_PHASE2_ENTRY_MODE=""
SPV_AELLA_CLI_VERSION_DETECTION=""
SPV_AELLA_CLI_VERSION=""
SPV_OS_RELEASE_ID=""
SPV_OS_RELEASE_VERSION_ID=""
SPV_OS_RELEASE_CODENAME=""

spv_utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y%m%dT%H%M%SZ
}

spv_is_strict_product_version() {
  local v="${1-}"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

spv_normalize_dp_version() {
  local raw="${1-}"
  local base
  if [[ -z "$raw" || "$raw" == "null" || "$raw" == "unknown" || "$raw" == "UNKNOWN" \
      || "$raw" == "UNDETERMINED" || "$raw" == "undetermined" ]]; then
    return 1
  fi
  raw="$(printf '%s' "$raw" | sed -E 's/^[^0-9]*//')"
  if [[ "$raw" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-[A-Za-z0-9.-]+)?$ ]]; then
    base="${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^([0-9]+\.[0-9]+)$ ]]; then
    base="${BASH_REMATCH[1]}.0"
  else
    return 1
  fi
  printf '%s' "$base"
  return 0
}

spv_value_has_shell_metachar() {
  local v="${1-}"
  case "$v" in
    *['`$\\;*|&<>(){}[]'!]*|*\"*|*"'"*|*$'\n'*|*$'\r'*) return 0 ;;
  esac
  return 1
}

spv_is_authoritative_release_image_key() {
  case "${1-}" in
    aella-cm-master|aella-cm-bg|aella-cm-user|aella-cm-worker|stellar-conf|stellar-controller)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

spv_is_fake_version_source() {
  case "${1-}" in
    FAKE|fake|TEST|test|DP_OFFLINE_FAKE_DP_VERSION)
      return 0
      ;;
  esac
  return 1
}

spv_allowlisted_env_key() {
  case "${1-}" in
    SOURCE_PRODUCT_ENV_SCHEMA_VERSION) return 0 ;;
    SOURCE_DP_VERSION_RAW) return 0 ;;
    SOURCE_DP_VERSION) return 0 ;;
    SOURCE_DP_VERSION_ORIGIN) return 0 ;;
    SOURCE_DP_VERSION_CHECK) return 0 ;;
    SOURCE_DP_VERSION_CAPTURED_AT) return 0 ;;
    SOURCE_DP_VERSION_CAPTURED_OS) return 0 ;;
    SOURCE_DP_VERSION_CAPTURED_CODENAME) return 0 ;;
    SOURCE_DP_VERSION_CAPTURE_RUN_ID) return 0 ;;
    MIN_SUPPORTED_SOURCE_DP_VERSION) return 0 ;;
    *) return 1 ;;
  esac
}

# Parse allowlisted KEY=VALUE file into prefixed globals: SPV_PARSED_<KEY>
# Rejects duplicates, unknown keys, metacharacters. Does not eval/source.
spv_parse_source_product_env_file() {
  local path="${1-}"
  local line key val seen_keys="" dup=0
  SPV_PARSE_STATUS=""
  SPV_PARSED_SOURCE_PRODUCT_ENV_SCHEMA_VERSION=""
  SPV_PARSED_SOURCE_DP_VERSION_RAW=""
  SPV_PARSED_SOURCE_DP_VERSION=""
  SPV_PARSED_SOURCE_DP_VERSION_ORIGIN=""
  SPV_PARSED_SOURCE_DP_VERSION_CHECK=""
  SPV_PARSED_SOURCE_DP_VERSION_CAPTURED_AT=""
  SPV_PARSED_SOURCE_DP_VERSION_CAPTURED_OS=""
  SPV_PARSED_SOURCE_DP_VERSION_CAPTURED_CODENAME=""
  SPV_PARSED_SOURCE_DP_VERSION_CAPTURE_RUN_ID=""
  SPV_PARSED_MIN_SUPPORTED_SOURCE_DP_VERSION=""

  if [[ -z "$path" || ! -e "$path" ]]; then
    SPV_PARSE_STATUS="MISSING"
    return 1
  fi
  if [[ ! -r "$path" ]]; then
    SPV_PARSE_STATUS="UNREADABLE"
    return 1
  fi
  if [[ ! -f "$path" ]]; then
    SPV_PARSE_STATUS="INVALID_SCHEMA"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ ! "$line" =~ ^([A-Za-z0-9_]+)=(.*)$ ]]; then
      SPV_PARSE_STATUS="INVALID_SCHEMA"
      return 1
    fi
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    val="${val%\"}"
    val="${val#\"}"
    if ! spv_allowlisted_env_key "$key"; then
      SPV_PARSE_STATUS="INVALID_SCHEMA"
      return 1
    fi
    case " ${seen_keys} " in
      *" ${key} "*)
        dup=1
        break
        ;;
    esac
    seen_keys="${seen_keys} ${key}"
    if spv_value_has_shell_metachar "$val"; then
      SPV_PARSE_STATUS="INVALID_SCHEMA"
      return 1
    fi
    case "$key" in
      SOURCE_PRODUCT_ENV_SCHEMA_VERSION) SPV_PARSED_SOURCE_PRODUCT_ENV_SCHEMA_VERSION="$val" ;;
      SOURCE_DP_VERSION_RAW) SPV_PARSED_SOURCE_DP_VERSION_RAW="$val" ;;
      SOURCE_DP_VERSION) SPV_PARSED_SOURCE_DP_VERSION="$val" ;;
      SOURCE_DP_VERSION_ORIGIN) SPV_PARSED_SOURCE_DP_VERSION_ORIGIN="$val" ;;
      SOURCE_DP_VERSION_CHECK) SPV_PARSED_SOURCE_DP_VERSION_CHECK="$val" ;;
      SOURCE_DP_VERSION_CAPTURED_AT) SPV_PARSED_SOURCE_DP_VERSION_CAPTURED_AT="$val" ;;
      SOURCE_DP_VERSION_CAPTURED_OS) SPV_PARSED_SOURCE_DP_VERSION_CAPTURED_OS="$val" ;;
      SOURCE_DP_VERSION_CAPTURED_CODENAME) SPV_PARSED_SOURCE_DP_VERSION_CAPTURED_CODENAME="$val" ;;
      SOURCE_DP_VERSION_CAPTURE_RUN_ID) SPV_PARSED_SOURCE_DP_VERSION_CAPTURE_RUN_ID="$val" ;;
      MIN_SUPPORTED_SOURCE_DP_VERSION) SPV_PARSED_MIN_SUPPORTED_SOURCE_DP_VERSION="$val" ;;
    esac
  done <"$path"

  if [[ "$dup" -eq 1 ]]; then
    SPV_PARSE_STATUS="DUPLICATE_KEY"
    return 1
  fi
  SPV_PARSE_STATUS="OK"
  return 0
}

spv_validate_parsed_pass_record() {
  local schema norm check
  schema="${SPV_PARSED_SOURCE_PRODUCT_ENV_SCHEMA_VERSION:-}"
  # Legacy jammy writers omit schema version; treat as acceptable if PASS + version ok.
  if [[ -n "$schema" && "$schema" != "1" ]]; then
    SPV_PARSE_STATUS="INVALID_SCHEMA"
    return 1
  fi
  check="${SPV_PARSED_SOURCE_DP_VERSION_CHECK:-}"
  if [[ "$check" == "FAIL_UNKNOWN" || "$check" == "FAIL_UNSUPPORTED" || "$check" == "FAIL" ]]; then
    SPV_PARSE_STATUS="RECORDED_FAILURE"
    return 1
  fi
  if [[ "$check" != "PASS" ]]; then
    SPV_PARSE_STATUS="INVALID_SCHEMA"
    return 1
  fi
  norm="${SPV_PARSED_SOURCE_DP_VERSION:-}"
  if [[ -z "$norm" ]]; then
    norm="$(spv_normalize_dp_version "${SPV_PARSED_SOURCE_DP_VERSION_RAW:-}")" || {
      SPV_PARSE_STATUS="INVALID_VERSION"
      return 1
    }
  else
    norm="$(spv_normalize_dp_version "$norm")" || {
      SPV_PARSE_STATUS="INVALID_VERSION"
      return 1
    }
  fi
  if ! spv_is_strict_product_version "$norm"; then
    SPV_PARSE_STATUS="INVALID_VERSION"
    return 1
  fi
  if [[ "$norm" == "UNKNOWN" || "$norm" == "UNDETERMINED" ]]; then
    SPV_PARSE_STATUS="INVALID_VERSION"
    return 1
  fi
  SPV_PARSED_SOURCE_DP_VERSION="$norm"
  return 0
}

# Atomic root-only write. Prefer durable_atomic_write when available (python3);
# otherwise Bash temp+rename with path-targeted sync only (never bare global sync).
# Stdin is buffered once so a durable-write failure can still fall back safely.
spv_atomic_write_file() {
  local dest="$1"
  local mode="${2:-0600}"
  local parent tmp content_file
  parent="$(dirname "$dest")"
  mkdir -p "$parent" || return 1
  chmod 0700 "$parent" 2>/dev/null || true

  content_file="$(mktemp "${TMPDIR:-/tmp}/spv-content.XXXXXX")"
  cat >"$content_file" || { rm -f "$content_file"; return 1; }

  if declare -F durable_atomic_write >/dev/null 2>&1; then
    if cat "$content_file" | durable_atomic_write "source_product_env" "$dest" "$mode"; then
      rm -f "$content_file"
      if [[ "$(id -u)" -eq 0 ]]; then
        chown root:root "$dest" 2>/dev/null || true
        chmod "$mode" "$dest" 2>/dev/null || true
        chmod 0700 "$parent" 2>/dev/null || true
      fi
      return 0
    fi
    # Fall through to Bash path if durable write fails (e.g. missing python3).
  fi

  tmp="${parent}/.$(basename "$dest").tmp.$$.${RANDOM:-0}"
  cat "$content_file" >"$tmp" || { rm -f "$content_file" "$tmp"; return 1; }
  rm -f "$content_file"
  chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
  if [[ "$(id -u)" -eq 0 ]]; then
    chown root:root "$tmp" 2>/dev/null || true
  fi
  # Path-targeted fsync only — never bare `sync`.
  if command -v sync >/dev/null 2>&1; then
    sync "$tmp" 2>/dev/null || true
  fi
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  if command -v sync >/dev/null 2>&1; then
    sync "$parent" 2>/dev/null || true
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    chown root:root "$dest" 2>/dev/null || true
    chmod "$mode" "$dest" 2>/dev/null || true
    chmod 0700 "$parent" 2>/dev/null || true
  fi
  return 0
}

spv_build_env_content() {
  local raw="$1" norm="$2" origin="$3" check="$4"
  local captured_at="$5" captured_os="$6" captured_codename="$7" run_id="$8"
  cat <<EOF
SOURCE_PRODUCT_ENV_SCHEMA_VERSION=${SOURCE_PRODUCT_ENV_SCHEMA_VERSION_CURRENT}
SOURCE_DP_VERSION_RAW=${raw}
SOURCE_DP_VERSION=${norm}
SOURCE_DP_VERSION_ORIGIN=${origin}
SOURCE_DP_VERSION_CHECK=${check}
SOURCE_DP_VERSION_CAPTURED_AT=${captured_at}
SOURCE_DP_VERSION_CAPTURED_OS=${captured_os}
SOURCE_DP_VERSION_CAPTURED_CODENAME=${captured_codename}
SOURCE_DP_VERSION_CAPTURE_RUN_ID=${run_id}
EOF
}

# Persist PASS capture. Never persists UNKNOWN/UNDETERMINED/empty.
# Never overwrites prior PASS with a different version (fail closed).
# Same version is idempotently reused.
spv_persist_source_product_env() {
  local dest="${1:-${SOURCE_PRODUCT_ENV_DEFAULT_PATH}}"
  local raw="${2-}"
  local origin="${3-}"
  local captured_os="${4-}"
  local captured_codename="${5-}"
  local run_id="${6-}"
  local norm check captured_at existing_norm

  SPV_SOURCE_PRODUCT_ENV_PATH="$dest"
  SPV_SOURCE_VERSION_CAPTURE_STATUS=""

  if spv_is_fake_version_source "$origin"; then
    SPV_SOURCE_VERSION_CAPTURE_STATUS="REJECTED_FAKE_SOURCE"
    return 1
  fi
  norm="$(spv_normalize_dp_version "$raw")" || {
    SPV_SOURCE_VERSION_CAPTURE_STATUS="REJECTED_INVALID_VERSION"
    return 1
  }
  if ! spv_is_strict_product_version "$norm"; then
    SPV_SOURCE_VERSION_CAPTURE_STATUS="REJECTED_INVALID_VERSION"
    return 1
  fi
  if spv_value_has_shell_metachar "$norm" || spv_value_has_shell_metachar "$origin"; then
    SPV_SOURCE_VERSION_CAPTURE_STATUS="REJECTED_INVALID_VERSION"
    return 1
  fi
  check="PASS"
  captured_at="$(spv_utc_now)"
  [[ -n "$run_id" ]] || run_id="capture-${captured_at}"
  [[ -n "$origin" ]] || origin="undetermined"

  if [[ -f "$dest" ]]; then
    if spv_parse_source_product_env_file "$dest" && spv_validate_parsed_pass_record; then
      existing_norm="${SPV_PARSED_SOURCE_DP_VERSION}"
      if [[ "$existing_norm" == "$norm" ]]; then
        SPV_SOURCE_VERSION_CAPTURE_STATUS="REUSED"
        SPV_SOURCE_PRODUCT_ENV_STATUS="PASS"
        SPV_SOURCE_DP_VERSION="$existing_norm"
        SPV_SOURCE_DP_VERSION_RAW="${SPV_PARSED_SOURCE_DP_VERSION_RAW:-$existing_norm}"
        SPV_SOURCE_DP_VERSION_ORIGIN="${SPV_PARSED_SOURCE_DP_VERSION_ORIGIN:-$origin}"
        SPV_SOURCE_DP_VERSION_CHECK="PASS"
        return 0
      fi
      SPV_SOURCE_VERSION_CAPTURE_STATUS="VERSION_CONFLICT"
      SPV_SOURCE_PRODUCT_ENV_STATUS="VERSION_CONFLICT"
      return 1
    fi
    # Existing file is not a valid PASS — may replace with new PASS.
  fi

  # Write via temp then validate before rename is handled inside atomic write of full content.
  local content
  content="$(spv_build_env_content "$raw" "$norm" "$origin" "$check" \
    "$captured_at" "$captured_os" "$captured_codename" "$run_id")"
  if ! printf '%s\n' "$content" | spv_atomic_write_file "$dest" 0600; then
    SPV_SOURCE_VERSION_CAPTURE_STATUS="WRITE_FAILED"
    return 1
  fi
  if ! spv_parse_source_product_env_file "$dest" || ! spv_validate_parsed_pass_record; then
    rm -f "$dest"
    SPV_SOURCE_VERSION_CAPTURE_STATUS="WRITE_FAILED"
    return 1
  fi
  SPV_SOURCE_VERSION_CAPTURE_STATUS="WRITTEN"
  SPV_SOURCE_PRODUCT_ENV_STATUS="PASS"
  SPV_SOURCE_DP_VERSION="$norm"
  SPV_SOURCE_DP_VERSION_RAW="$raw"
  SPV_SOURCE_DP_VERSION_ORIGIN="$origin"
  SPV_SOURCE_DP_VERSION_CHECK="PASS"
  return 0
}

# Read existing PASS env. Sets SPV_SOURCE_* on success.
spv_read_source_product_env() {
  local dest="${1:-${SOURCE_PRODUCT_ENV_DEFAULT_PATH}}"
  SPV_SOURCE_PRODUCT_ENV_PATH="$dest"
  SPV_SOURCE_PRODUCT_ENV_STATUS=""
  if [[ ! -e "$dest" ]]; then
    SPV_SOURCE_PRODUCT_ENV_STATUS="MISSING"
    return 1
  fi
  if ! spv_parse_source_product_env_file "$dest"; then
    case "${SPV_PARSE_STATUS}" in
      UNREADABLE) SPV_SOURCE_PRODUCT_ENV_STATUS="UNREADABLE" ;;
      DUPLICATE_KEY) SPV_SOURCE_PRODUCT_ENV_STATUS="DUPLICATE_KEY" ;;
      RECORDED_FAILURE) SPV_SOURCE_PRODUCT_ENV_STATUS="RECORDED_FAILURE" ;;
      INVALID_VERSION) SPV_SOURCE_PRODUCT_ENV_STATUS="INVALID_VERSION" ;;
      *) SPV_SOURCE_PRODUCT_ENV_STATUS="INVALID_SCHEMA" ;;
    esac
    return 1
  fi
  if ! spv_validate_parsed_pass_record; then
    case "${SPV_PARSE_STATUS}" in
      RECORDED_FAILURE) SPV_SOURCE_PRODUCT_ENV_STATUS="RECORDED_FAILURE" ;;
      INVALID_VERSION) SPV_SOURCE_PRODUCT_ENV_STATUS="INVALID_VERSION" ;;
      *) SPV_SOURCE_PRODUCT_ENV_STATUS="INVALID_SCHEMA" ;;
    esac
    return 1
  fi
  SPV_SOURCE_PRODUCT_ENV_STATUS="PASS"
  SPV_SOURCE_DP_VERSION="${SPV_PARSED_SOURCE_DP_VERSION}"
  SPV_SOURCE_DP_VERSION_RAW="${SPV_PARSED_SOURCE_DP_VERSION_RAW:-$SPV_SOURCE_DP_VERSION}"
  SPV_SOURCE_DP_VERSION_ORIGIN="${SPV_PARSED_SOURCE_DP_VERSION_ORIGIN:-source-product.env}"
  SPV_SOURCE_DP_VERSION_CHECK="PASS"
  return 0
}

# Scan Phase 1 structured logs for complete PASS evidence records.
# A complete record requires nearby DP_VERSION + SOURCE + DETECT_STATUS=ok + CONSISTENCY=PASS.
# Later UNDETERMINED does not erase earlier complete PASS evidence.
spv_scan_phase1_log_evidence() {
  local logf="${1:-${SOURCE_PRODUCT_PHASE1_LOG_DEFAULT}}"
  local production_mode="${2:-1}"
  local line ver src status cons
  local -a pass_versions=()
  local record_count=0 complete_pass=0 undetermined=0
  local cur_ver="" cur_src="" cur_status="" cur_cons=""
  local uniq="" v

  SPV_PHASE1_LOG_EVIDENCE_PATH="$logf"
  SPV_PHASE1_LOG_EVIDENCE_STATUS=""
  SPV_PHASE1_LOG_EVIDENCE_RECORD_COUNT=0
  SPV_PHASE1_LOG_EVIDENCE_COMPLETE_PASS_COUNT=0
  SPV_PHASE1_LOG_EVIDENCE_UNIQUE_VERSION_COUNT=0
  SPV_PHASE1_LOG_EVIDENCE_UNDETERMINED_COUNT=0
  SPV_PHASE1_SELECTED_VERSION=""
  SPV_PHASE1_SELECTED_SOURCE=""

  if [[ ! -e "$logf" ]]; then
    SPV_PHASE1_LOG_EVIDENCE_STATUS="MISSING"
    return 1
  fi
  if [[ ! -r "$logf" ]]; then
    SPV_PHASE1_LOG_EVIDENCE_STATUS="UNREADABLE"
    return 1
  fi

  _spv_flush_partial() {
    # Incomplete window — does not vote.
    cur_ver=""
    cur_src=""
    cur_status=""
    cur_cons=""
  }

  _spv_try_complete() {
    if [[ -n "$cur_ver" && -n "$cur_src" && -n "$cur_status" && -n "$cur_cons" ]]; then
      record_count=$((record_count + 1))
      if [[ "$cur_ver" == "UNDETERMINED" || "$cur_status" == "undetermined" ]]; then
        undetermined=$((undetermined + 1))
        _spv_flush_partial
        return 0
      fi
      if [[ "$cur_status" == "ok" && "$cur_cons" == "PASS" ]]; then
        if spv_is_fake_version_source "$cur_src"; then
          if [[ "$production_mode" == "1" ]]; then
            _spv_flush_partial
            return 0
          fi
        fi
        if spv_is_strict_product_version "$cur_ver" || spv_normalize_dp_version "$cur_ver" >/dev/null 2>&1; then
          ver="$(spv_normalize_dp_version "$cur_ver")" || { _spv_flush_partial; return 0; }
          if spv_is_strict_product_version "$ver"; then
            complete_pass=$((complete_pass + 1))
            pass_versions+=("${ver}|${cur_src}")
          fi
        fi
      fi
      _spv_flush_partial
    fi
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ DP_VERSION=([^[:space:]]+) ]]; then
      # Starting a new version field closes any incomplete prior window without voting.
      if [[ -n "$cur_ver" || -n "$cur_src" || -n "$cur_status" || -n "$cur_cons" ]]; then
        # If previous had all four, try_complete; else discard incomplete.
        if [[ -n "$cur_ver" && -n "$cur_src" && -n "$cur_status" && -n "$cur_cons" ]]; then
          _spv_try_complete
        else
          if [[ "$cur_ver" == "UNDETERMINED" || "$cur_status" == "undetermined" ]]; then
            undetermined=$((undetermined + 1))
          fi
          _spv_flush_partial
        fi
      fi
      cur_ver="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" =~ DP_VERSION_SOURCE=([^[:space:]]+) ]]; then
      cur_src="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" =~ DP_VERSION_DETECT_STATUS=([^[:space:]]+) ]]; then
      cur_status="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" =~ DP_VERSION_CONSISTENCY=([^[:space:]]+) ]]; then
      cur_cons="${BASH_REMATCH[1]}"
      _spv_try_complete
      continue
    fi
  done <"$logf"
  # Trailing incomplete undetermined observation still counts.
  if [[ -n "$cur_ver" || -n "$cur_status" ]]; then
    if [[ "$cur_ver" == "UNDETERMINED" || "$cur_status" == "undetermined" ]]; then
      if [[ -z "$cur_cons" ]]; then
        undetermined=$((undetermined + 1))
      else
        _spv_try_complete
      fi
    fi
  fi
  _spv_flush_partial

  SPV_PHASE1_LOG_EVIDENCE_RECORD_COUNT="$record_count"
  SPV_PHASE1_LOG_EVIDENCE_COMPLETE_PASS_COUNT="$complete_pass"
  SPV_PHASE1_LOG_EVIDENCE_UNDETERMINED_COUNT="$undetermined"

  if [[ "$complete_pass" -eq 0 ]]; then
    # Distinguish fake-only vs none
    if [[ "$record_count" -gt 0 ]]; then
      SPV_PHASE1_LOG_EVIDENCE_STATUS="NO_COMPLETE_RECORD"
    else
      SPV_PHASE1_LOG_EVIDENCE_STATUS="NO_COMPLETE_RECORD"
    fi
    return 1
  fi

  uniq=""
  for v in "${pass_versions[@]}"; do
    ver="${v%%|*}"
    case " ${uniq} " in
      *" ${ver} "*) ;;
      *) uniq="${uniq} ${ver}" ;;
    esac
  done
  uniq="${uniq# }"
  SPV_PHASE1_LOG_EVIDENCE_UNIQUE_VERSION_COUNT="$(printf '%s' "$uniq" | tr ' ' '\n' | awk 'NF' | wc -l | tr -d ' ')"

  if [[ "${SPV_PHASE1_LOG_EVIDENCE_UNIQUE_VERSION_COUNT}" -gt 1 ]]; then
    SPV_PHASE1_LOG_EVIDENCE_STATUS="MULTIPLE_VERSIONS"
    return 1
  fi
  if [[ "${SPV_PHASE1_LOG_EVIDENCE_UNIQUE_VERSION_COUNT}" -eq 0 ]]; then
    SPV_PHASE1_LOG_EVIDENCE_STATUS="FAKE_SOURCE_ONLY"
    return 1
  fi

  SPV_PHASE1_SELECTED_VERSION="$(printf '%s' "$uniq" | tr ' ' '\n' | awk 'NF{print; exit}')"
  for v in "${pass_versions[@]}"; do
    ver="${v%%|*}"
    src="${v#*|}"
    if [[ "$ver" == "$SPV_PHASE1_SELECTED_VERSION" ]]; then
      SPV_PHASE1_SELECTED_SOURCE="$src"
      break
    fi
  done
  SPV_PHASE1_LOG_EVIDENCE_STATUS="PASS"
  return 0
}

spv_detect_from_release_image() {
  local image="${1:-${SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT}}"
  local line re key ver tmp uniq_n count malformed=0
  SPV_RELEASE_IMAGE_PATH="$image"
  SPV_RELEASE_IMAGE_STATUS=""
  SPV_RELEASE_IMAGE_AUTHORITATIVE_RECORD_COUNT=0
  SPV_RELEASE_IMAGE_UNIQUE_VERSION_COUNT=0
  SPV_RELEASE_SELECTED_VERSION=""

  if [[ ! -e "$image" ]]; then
    SPV_RELEASE_IMAGE_STATUS="MISSING"
    return 1
  fi
  if [[ ! -r "$image" ]]; then
    SPV_RELEASE_IMAGE_STATUS="UNREADABLE"
    return 1
  fi

  re='^[[:space:]]*([A-Za-z0-9_.-]+):[[:space:]]*(.+)$'
  tmp="$(mktemp "${TMPDIR:-/tmp}/spv-ri.XXXXXX")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ $re ]]; then
      key="${BASH_REMATCH[1]}"
      ver="${BASH_REMATCH[2]}"
      ver="$(printf '%s' "$ver" | sed -E 's/[[:space:]]+$//')"
      if spv_is_authoritative_release_image_key "$key"; then
        if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
          if n="$(spv_normalize_dp_version "$ver")"; then
            printf '%s\n' "$n" >>"$tmp"
          else
            malformed=1
          fi
        else
          malformed=1
        fi
      fi
    fi
  done <"$image"

  if [[ "$malformed" -eq 1 ]]; then
    rm -f "$tmp"
    SPV_RELEASE_IMAGE_STATUS="MALFORMED_AUTHORITATIVE_ENTRY"
    return 1
  fi
  count="$(wc -l <"$tmp" | tr -d ' ')"
  SPV_RELEASE_IMAGE_AUTHORITATIVE_RECORD_COUNT="$count"
  if [[ "$count" -eq 0 ]]; then
    rm -f "$tmp"
    SPV_RELEASE_IMAGE_STATUS="NO_AUTHORITATIVE_KEYS"
    return 1
  fi
  if [[ "$count" -lt "${SOURCE_PRODUCT_MIN_AUTHORITATIVE_RELEASE_KEYS}" ]]; then
    rm -f "$tmp"
    SPV_RELEASE_IMAGE_STATUS="INSUFFICIENT_AUTHORITATIVE_RECORDS"
    return 1
  fi
  sort -u "$tmp" -o "$tmp"
  uniq_n="$(wc -l <"$tmp" | tr -d ' ')"
  SPV_RELEASE_IMAGE_UNIQUE_VERSION_COUNT="$uniq_n"
  if [[ "$uniq_n" -ne 1 ]]; then
    rm -f "$tmp"
    SPV_RELEASE_IMAGE_STATUS="VERSION_CONFLICT"
    return 1
  fi
  ver="$(tr -d '[:space:]' <"$tmp")"
  rm -f "$tmp"
  SPV_RELEASE_SELECTED_VERSION="$ver"
  SPV_RELEASE_IMAGE_STATUS="PASS"
  return 0
}

spv_os_upgrade_state() {
  local state="" f
  if [[ -n "${SOURCE_PRODUCT_OS_STATE_FILE}" && -f "${SOURCE_PRODUCT_OS_STATE_FILE}" ]]; then
    tr -d '\r\n' <"${SOURCE_PRODUCT_OS_STATE_FILE}" || true
    return 0
  fi
  for f in \
    /opt/aelladata/os-upgrade/offline/state \
    /opt/aelladata/os-upgrade/state \
    /var/lib/dp-os-upgrade/state \
    /opt/aelladata/os-upgrade/CURRENT_STATE
  do
    if [[ -f "$f" ]]; then
      state="$(tr -d '\r\n' <"$f" || true)"
      break
    fi
  done
  printf '%s' "$state"
}

spv_bringup_completed_marker() {
  local life="${SOURCE_PRODUCT_BRINGUP_RESULT_ENV:-/opt/aelladata/os-upgrade/offline/phase2-bringup/result.env}"
  if [[ -f "$life" ]] && grep -qE '^BRINGUP_RESULT=PASS$' "$life" 2>/dev/null; then
    return 0
  fi
  if [[ -f /opt/aelladata/os-upgrade/offline/BRINGUP_EXECUTED ]]; then
    return 0
  fi
  return 1
}

# Read /etc/os-release (or SOURCE_PRODUCT_OS_RELEASE_FILE override) into SPV_OS_RELEASE_*.
spv_read_os_release() {
  local f="${SOURCE_PRODUCT_OS_RELEASE_FILE:-/etc/os-release}"
  local line key val
  SPV_OS_RELEASE_ID=""
  SPV_OS_RELEASE_VERSION_ID=""
  SPV_OS_RELEASE_CODENAME=""
  [[ -r "$f" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    val="${val%\"}"
    val="${val#\"}"
    case "$key" in
      ID) SPV_OS_RELEASE_ID="$val" ;;
      VERSION_ID) SPV_OS_RELEASE_VERSION_ID="$val" ;;
      VERSION_CODENAME) SPV_OS_RELEASE_CODENAME="$val" ;;
    esac
  done <"$f"
  [[ -n "$SPV_OS_RELEASE_ID" ]]
}

# Distinguish Native Noble (never ran Phase 1) from Post-Phase1 Noble.
# POST_PHASE1_NOBLE: OS upgrade state is COMPLETED_NOBLE (Phase 1 finished).
# NATIVE_NOBLE: Ubuntu 24.04/noble without Phase 1 completion evidence.
# OTHER: not a Noble Phase2-only entry host.
spv_detect_phase2_entry_mode() {
  local state
  SPV_PHASE2_ENTRY_MODE=""
  state="$(spv_os_upgrade_state)"
  if [[ "$state" == "COMPLETED_NOBLE" ]]; then
    SPV_PHASE2_ENTRY_MODE="POST_PHASE1_NOBLE"
    return 0
  fi
  spv_read_os_release || true
  if [[ "${SPV_OS_RELEASE_ID}" == "ubuntu" ]] \
    && { [[ "${SPV_OS_RELEASE_VERSION_ID}" == "24.04" ]] \
      || [[ "${SPV_OS_RELEASE_CODENAME}" == "noble" ]]; }; then
    SPV_PHASE2_ENTRY_MODE="NATIVE_NOBLE"
    return 0
  fi
  SPV_PHASE2_ENTRY_MODE="OTHER"
  return 0
}

# Strict live aella_cli product version — mirrors Phase1 jammy-to-noble
# capture_aella_cli_show_version + single-version consistency rules.
# Sets SPV_AELLA_CLI_VERSION_DETECTION and SPV_AELLA_CLI_VERSION.
spv_detect_from_aella_cli() {
  local outf rc text line token
  local -a versions=()
  local uniq="" v
  SPV_AELLA_CLI_VERSION_DETECTION=""
  SPV_AELLA_CLI_VERSION=""

  if ! command -v aella_cli >/dev/null 2>&1; then
    SPV_AELLA_CLI_VERSION_DETECTION="MISSING"
    return 1
  fi
  if ! command -v timeout >/dev/null 2>&1; then
    SPV_AELLA_CLI_VERSION_DETECTION="MISSING"
    return 1
  fi

  outf="$(mktemp "${TMPDIR:-/tmp}/spv-aella-cli.XXXXXX")"
  set +e
  timeout 10 sh -c "printf 'show version\nquit\n' | aella_cli" >"$outf" 2>&1
  rc=$?
  set -e
  text="$(cat "$outf" 2>/dev/null || true)"
  rm -f "$outf"

  if [[ "$rc" -eq 124 ]]; then
    SPV_AELLA_CLI_VERSION_DETECTION="TIMEOUT"
    return 1
  fi
  if [[ "$rc" -ne 0 ]]; then
    SPV_AELLA_CLI_VERSION_DETECTION="NONZERO"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    # shellcheck disable=SC2086
    for token in $line; do
      if [[ "$token" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        versions+=("$token")
      elif n="$(spv_normalize_dp_version "$token" 2>/dev/null)"; then
        if spv_is_strict_product_version "$n"; then
          versions+=("$n")
        fi
      fi
    done
  done <<<"$text"

  if [[ "${#versions[@]}" -eq 0 ]]; then
    SPV_AELLA_CLI_VERSION_DETECTION="NO_SEMVER"
    return 1
  fi

  uniq=""
  for v in "${versions[@]}"; do
    case " ${uniq} " in
      *" ${v} "*) ;;
      *) uniq="${uniq} ${v}" ;;
    esac
  done
  uniq="${uniq# }"
  if [[ "$(printf '%s' "$uniq" | tr ' ' '\n' | awk 'NF' | wc -l | tr -d ' ')" -ne 1 ]]; then
    SPV_AELLA_CLI_VERSION_DETECTION="INCONSISTENT"
    return 1
  fi
  SPV_AELLA_CLI_VERSION="$(printf '%s' "$uniq" | tr ' ' '\n' | awk 'NF{print; exit}')"
  SPV_AELLA_CLI_VERSION_DETECTION="PASS"
  return 0
}

spv_write_resolution_evidence() {
  local run_id="${1-}"
  local root="${SOURCE_PRODUCT_EVIDENCE_ROOT_DEFAULT}"
  local dir
  [[ -n "$run_id" ]] || return 0
  dir="${root}/${run_id}"
  mkdir -p "$dir" 2>/dev/null || return 0
  chmod 0700 "$dir" 2>/dev/null || true
  {
    echo "PHASE2_ENTRY_MODE=${SPV_PHASE2_ENTRY_MODE}"
    echo "AELLA_CLI_VERSION_DETECTION=${SPV_AELLA_CLI_VERSION_DETECTION}"
    echo "AELLA_CLI_VERSION=${SPV_AELLA_CLI_VERSION}"
    echo "SOURCE_PRODUCT_ENV_PATH=${SPV_SOURCE_PRODUCT_ENV_PATH}"
    echo "SOURCE_PRODUCT_ENV_STATUS=${SPV_SOURCE_PRODUCT_ENV_STATUS}"
    echo "SOURCE_VERSION_CAPTURE_STATUS=${SPV_SOURCE_VERSION_CAPTURE_STATUS}"
    echo "PHASE1_LOG_EVIDENCE_PATH=${SPV_PHASE1_LOG_EVIDENCE_PATH}"
    echo "PHASE1_LOG_EVIDENCE_STATUS=${SPV_PHASE1_LOG_EVIDENCE_STATUS}"
    echo "PHASE1_LOG_EVIDENCE_RECORD_COUNT=${SPV_PHASE1_LOG_EVIDENCE_RECORD_COUNT}"
    echo "PHASE1_LOG_EVIDENCE_COMPLETE_PASS_COUNT=${SPV_PHASE1_LOG_EVIDENCE_COMPLETE_PASS_COUNT}"
    echo "PHASE1_LOG_EVIDENCE_UNIQUE_VERSION_COUNT=${SPV_PHASE1_LOG_EVIDENCE_UNIQUE_VERSION_COUNT}"
    echo "PHASE1_LOG_EVIDENCE_UNDETERMINED_COUNT=${SPV_PHASE1_LOG_EVIDENCE_UNDETERMINED_COUNT}"
    echo "RELEASE_IMAGE_PATH=${SPV_RELEASE_IMAGE_PATH}"
    echo "RELEASE_IMAGE_STATUS=${SPV_RELEASE_IMAGE_STATUS}"
    echo "RELEASE_IMAGE_AUTHORITATIVE_RECORD_COUNT=${SPV_RELEASE_IMAGE_AUTHORITATIVE_RECORD_COUNT}"
    echo "RELEASE_IMAGE_UNIQUE_VERSION_COUNT=${SPV_RELEASE_IMAGE_UNIQUE_VERSION_COUNT}"
    echo "OPERATOR_SOURCE_VERSION_STATUS=${SPV_OPERATOR_SOURCE_VERSION_STATUS}"
    echo "SOURCE_DP_VERSION=${SPV_SOURCE_DP_VERSION}"
    echo "SOURCE_DP_VERSION_ORIGIN=${SPV_SOURCE_DP_VERSION_ORIGIN}"
    echo "SOURCE_DP_VERSION_RESOLUTION=${SPV_SOURCE_DP_VERSION_RESOLUTION}"
    echo "SOURCE_DP_VERSION_FAILURE_REASON=${SPV_SOURCE_DP_VERSION_FAILURE_REASON}"
    echo "SOURCE_DP_VERSION_RECOVERY=${SPV_SOURCE_DP_VERSION_RECOVERY}"
  } | spv_atomic_write_file "${dir}/summary.env" 0600 || true
}

spv_emit_diagnostics() {
  cat <<EOF
PHASE2_ENTRY_MODE=${SPV_PHASE2_ENTRY_MODE}
AELLA_CLI_VERSION_DETECTION=${SPV_AELLA_CLI_VERSION_DETECTION}
AELLA_CLI_VERSION=${SPV_AELLA_CLI_VERSION}
SOURCE_PRODUCT_ENV_PATH=${SPV_SOURCE_PRODUCT_ENV_PATH}
SOURCE_PRODUCT_ENV_STATUS=${SPV_SOURCE_PRODUCT_ENV_STATUS}
SOURCE_VERSION_CAPTURE_STATUS=${SPV_SOURCE_VERSION_CAPTURE_STATUS}
PHASE1_LOG_EVIDENCE_PATH=${SPV_PHASE1_LOG_EVIDENCE_PATH}
PHASE1_LOG_EVIDENCE_STATUS=${SPV_PHASE1_LOG_EVIDENCE_STATUS}
PHASE1_LOG_EVIDENCE_RECORD_COUNT=${SPV_PHASE1_LOG_EVIDENCE_RECORD_COUNT}
PHASE1_LOG_EVIDENCE_COMPLETE_PASS_COUNT=${SPV_PHASE1_LOG_EVIDENCE_COMPLETE_PASS_COUNT}
PHASE1_LOG_EVIDENCE_UNIQUE_VERSION_COUNT=${SPV_PHASE1_LOG_EVIDENCE_UNIQUE_VERSION_COUNT}
PHASE1_LOG_EVIDENCE_UNDETERMINED_COUNT=${SPV_PHASE1_LOG_EVIDENCE_UNDETERMINED_COUNT}
RELEASE_IMAGE_PATH=${SPV_RELEASE_IMAGE_PATH}
RELEASE_IMAGE_STATUS=${SPV_RELEASE_IMAGE_STATUS}
RELEASE_IMAGE_AUTHORITATIVE_RECORD_COUNT=${SPV_RELEASE_IMAGE_AUTHORITATIVE_RECORD_COUNT}
RELEASE_IMAGE_UNIQUE_VERSION_COUNT=${SPV_RELEASE_IMAGE_UNIQUE_VERSION_COUNT}
OPERATOR_SOURCE_VERSION_STATUS=${SPV_OPERATOR_SOURCE_VERSION_STATUS}
SOURCE_DP_VERSION=${SPV_SOURCE_DP_VERSION}
SOURCE_DP_VERSION_RAW=${SPV_SOURCE_DP_VERSION_RAW}
SOURCE_DP_VERSION_ORIGIN=${SPV_SOURCE_DP_VERSION_ORIGIN}
SOURCE_DP_VERSION_CHECK=${SPV_SOURCE_DP_VERSION_CHECK}
SOURCE_DP_VERSION_RESOLUTION=${SPV_SOURCE_DP_VERSION_RESOLUTION}
SOURCE_DP_VERSION_FAILURE_REASON=${SPV_SOURCE_DP_VERSION_FAILURE_REASON}
SOURCE_DP_VERSION_REMEDIATION=${SPV_SOURCE_DP_VERSION_REMEDIATION}
SOURCE_DP_VERSION_RECOVERY=${SPV_SOURCE_DP_VERSION_RECOVERY}
EOF
}

spv_set_failure() {
  local reason="$1"
  local remediation="${2:-Review the listed evidence sources or provide --source-dp-version only after independently verifying the original DP version.}"
  SPV_SOURCE_DP_VERSION_RESOLUTION="FAIL"
  SPV_SOURCE_DP_VERSION_FAILURE_REASON="$reason"
  SPV_SOURCE_DP_VERSION_REMEDIATION="$remediation"
  SPV_SOURCE_DP_VERSION_CHECK="FAIL"
}

# Full resolution with optional write-back recovery.
# Args:
#   $1 dest env path
#   $2 phase1 log path
#   $3 release-image path
#   $4 operator override (may be empty)
#   $5 allow_write (1=may persist recovery, 0=diagnose read-only)
#   $6 run_id
#   $7 production_mode (1=reject fake sources)
spv_resolve_source_dp_version() {
  local dest="${1:-${SOURCE_PRODUCT_ENV_DEFAULT_PATH}}"
  local logf="${2:-${SOURCE_PRODUCT_PHASE1_LOG_DEFAULT}}"
  local image="${3:-${SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT}}"
  local operator="${4-}"
  local allow_write="${5:-1}"
  local run_id="${6:-}"
  local production_mode="${7:-1}"
  local state op_norm

  SPV_SOURCE_PRODUCT_ENV_PATH="$dest"
  SPV_SOURCE_PRODUCT_ENV_STATUS=""
  SPV_SOURCE_VERSION_CAPTURE_STATUS=""
  SPV_PHASE1_LOG_EVIDENCE_PATH="$logf"
  SPV_PHASE1_LOG_EVIDENCE_STATUS=""
  SPV_RELEASE_IMAGE_PATH="$image"
  SPV_RELEASE_IMAGE_STATUS=""
  SPV_OPERATOR_SOURCE_VERSION_STATUS="NOT_PROVIDED"
  SPV_SOURCE_DP_VERSION=""
  SPV_SOURCE_DP_VERSION_RAW=""
  SPV_SOURCE_DP_VERSION_ORIGIN=""
  SPV_SOURCE_DP_VERSION_CHECK=""
  SPV_SOURCE_DP_VERSION_RESOLUTION=""
  SPV_SOURCE_DP_VERSION_FAILURE_REASON=""
  SPV_SOURCE_DP_VERSION_REMEDIATION=""
  SPV_SOURCE_DP_VERSION_RECOVERY=""
  SPV_AELLA_CLI_VERSION_DETECTION=""
  SPV_AELLA_CLI_VERSION=""
  spv_detect_phase2_entry_mode

  # 1) valid source-product.env
  if spv_read_source_product_env "$dest"; then
    SPV_SOURCE_DP_VERSION_RESOLUTION="PASS"
    SPV_SOURCE_DP_VERSION_RECOVERY="NOT_REQUIRED"
    if [[ -n "$operator" ]]; then
      op_norm="$(spv_normalize_dp_version "$operator")" || {
        SPV_OPERATOR_SOURCE_VERSION_STATUS="INVALID"
        spv_set_failure "OPERATOR_OVERRIDE_INVALID"
        spv_write_resolution_evidence "$run_id"
        return 1
      }
      SPV_OPERATOR_SOURCE_VERSION_STATUS="PROVIDED"
      if [[ "$op_norm" != "$SPV_SOURCE_DP_VERSION" ]]; then
        SPV_OPERATOR_SOURCE_VERSION_STATUS="CONFLICT"
        spv_set_failure "OPERATOR_OVERRIDE_CONFLICT" \
          "Operator --source-dp-version conflicts with authoritative source-product.env; do not override."
        spv_write_resolution_evidence "$run_id"
        return 1
      fi
    fi
    # Native Noble: if live CLI reports a different version, fail closed.
    # Post-Phase1 must NOT consult live CLI (product may be intentionally broken).
    if [[ "${SPV_PHASE2_ENTRY_MODE}" == "NATIVE_NOBLE" ]]; then
      if spv_detect_from_aella_cli; then
        if [[ "$SPV_AELLA_CLI_VERSION" != "$SPV_SOURCE_DP_VERSION" ]]; then
          spv_set_failure "NATIVE_LIVE_CLI_CONFLICT" \
            "Persisted source-product.env conflicts with live aella_cli; refuse silent reconciliation."
          spv_write_resolution_evidence "$run_id"
          return 1
        fi
      fi
      # Live CLI failure (missing/timeout) does not invalidate good persisted evidence.
    fi
    spv_write_resolution_evidence "$run_id"
    return 0
  fi

  # 2) immutable capture already covered by read failure statuses above

  # 3) Phase 1 log recovery (POST_PHASE1 / COMPLETED_NOBLE + bringup not completed)
  #    Never use live aella_cli on this path.
  state="$(spv_os_upgrade_state)"
  if [[ "$state" == "COMPLETED_NOBLE" ]] && ! spv_bringup_completed_marker; then
    if spv_scan_phase1_log_evidence "$logf" "$production_mode"; then
      if [[ "$allow_write" == "1" ]]; then
        if spv_persist_source_product_env "$dest" \
            "$SPV_PHASE1_SELECTED_VERSION" "phase1-log-recovery" \
            "24.04" "noble" "${run_id:-phase1-recovery}"; then
          SPV_SOURCE_DP_VERSION_ORIGIN="phase1-log-recovery"
          SPV_SOURCE_DP_VERSION_RECOVERY="PASS"
          SPV_SOURCE_DP_VERSION_RESOLUTION="PASS"
          SPV_SOURCE_DP_VERSION_CHECK="PASS"
          if [[ -n "$operator" ]]; then
            op_norm="$(spv_normalize_dp_version "$operator")" || {
              SPV_OPERATOR_SOURCE_VERSION_STATUS="INVALID"
              spv_set_failure "OPERATOR_OVERRIDE_INVALID"
              spv_write_resolution_evidence "$run_id"
              return 1
            }
            SPV_OPERATOR_SOURCE_VERSION_STATUS="PROVIDED"
            if [[ "$op_norm" != "$SPV_SOURCE_DP_VERSION" ]]; then
              SPV_OPERATOR_SOURCE_VERSION_STATUS="CONFLICT"
              spv_set_failure "OPERATOR_OVERRIDE_CONFLICT"
              spv_write_resolution_evidence "$run_id"
              return 1
            fi
          fi
          spv_write_resolution_evidence "$run_id"
          return 0
        fi
      else
        # diagnose / read-only: report would-be recovery without writing
        SPV_SOURCE_DP_VERSION="$SPV_PHASE1_SELECTED_VERSION"
        SPV_SOURCE_DP_VERSION_RAW="$SPV_PHASE1_SELECTED_VERSION"
        SPV_SOURCE_DP_VERSION_ORIGIN="phase1-log-recovery"
        SPV_SOURCE_DP_VERSION_CHECK="PASS"
        SPV_SOURCE_DP_VERSION_RESOLUTION="PASS"
        SPV_SOURCE_DP_VERSION_RECOVERY="WOULD_WRITE"
        SPV_SOURCE_VERSION_CAPTURE_STATUS="READ_ONLY_SKIPPED"
        spv_write_resolution_evidence "$run_id"
        return 0
      fi
    else
      case "${SPV_PHASE1_LOG_EVIDENCE_STATUS}" in
        MULTIPLE_VERSIONS)
          spv_set_failure "PHASE1_EVIDENCE_MULTIPLE_VERSIONS"
          spv_write_resolution_evidence "$run_id"
          return 1
          ;;
      esac
    fi
  else
    if [[ -e "$logf" ]]; then
      spv_scan_phase1_log_evidence "$logf" "$production_mode" || true
    else
      SPV_PHASE1_LOG_EVIDENCE_STATUS="MISSING"
    fi
  fi

  # 3b) Native Noble live aella_cli (NOT used for Post-Phase1)
  if [[ "${SPV_PHASE2_ENTRY_MODE}" == "NATIVE_NOBLE" ]]; then
    if spv_detect_from_aella_cli; then
      if [[ "$allow_write" == "1" ]]; then
        if ! spv_persist_source_product_env "$dest" \
            "$SPV_AELLA_CLI_VERSION" "aella_cli-native-noble" \
            "${SPV_OS_RELEASE_VERSION_ID:-24.04}" \
            "${SPV_OS_RELEASE_CODENAME:-noble}" \
            "${run_id:-native-noble}"; then
          if [[ "${SPV_SOURCE_VERSION_CAPTURE_STATUS}" == "VERSION_CONFLICT" ]]; then
            spv_set_failure "SOURCE_PRODUCT_ENV_VERSION_CONFLICT"
            spv_write_resolution_evidence "$run_id"
            return 1
          fi
        fi
      fi
      SPV_SOURCE_DP_VERSION="$SPV_AELLA_CLI_VERSION"
      SPV_SOURCE_DP_VERSION_RAW="$SPV_AELLA_CLI_VERSION"
      SPV_SOURCE_DP_VERSION_ORIGIN="aella_cli-native-noble"
      SPV_SOURCE_DP_VERSION_CHECK="PASS"
      SPV_SOURCE_DP_VERSION_RESOLUTION="PASS"
      SPV_SOURCE_DP_VERSION_RECOVERY="${SPV_SOURCE_DP_VERSION_RECOVERY:-NOT_REQUIRED}"
      if [[ -n "$operator" ]]; then
        op_norm="$(spv_normalize_dp_version "$operator")" || {
          SPV_OPERATOR_SOURCE_VERSION_STATUS="INVALID"
          spv_set_failure "OPERATOR_OVERRIDE_INVALID"
          spv_write_resolution_evidence "$run_id"
          return 1
        }
        SPV_OPERATOR_SOURCE_VERSION_STATUS="PROVIDED"
        if [[ "$op_norm" != "$SPV_SOURCE_DP_VERSION" ]]; then
          SPV_OPERATOR_SOURCE_VERSION_STATUS="CONFLICT"
          spv_set_failure "OPERATOR_OVERRIDE_CONFLICT"
          spv_write_resolution_evidence "$run_id"
          return 1
        fi
      fi
      spv_write_resolution_evidence "$run_id"
      return 0
    fi
    case "${SPV_AELLA_CLI_VERSION_DETECTION}" in
      INCONSISTENT)
        spv_set_failure "AELLA_CLI_INCONSISTENT_VERSIONS" \
          "Live aella_cli reported multiple distinct product versions; refuse to guess."
        spv_write_resolution_evidence "$run_id"
        return 1
        ;;
    esac
    # TIMEOUT / NONZERO / MISSING / NO_SEMVER → fall through to release-image / operator.
  elif [[ "${SPV_PHASE2_ENTRY_MODE}" == "POST_PHASE1_NOBLE" ]]; then
    SPV_AELLA_CLI_VERSION_DETECTION="SKIPPED_POST_PHASE1"
  fi

  # 4) release-image.yml
  if spv_detect_from_release_image "$image"; then
    if [[ "$allow_write" == "1" ]]; then
      spv_persist_source_product_env "$dest" \
        "$SPV_RELEASE_SELECTED_VERSION" "release-image.yml" \
        "" "" "${run_id:-release-image}" || true
    fi
    SPV_SOURCE_DP_VERSION="$SPV_RELEASE_SELECTED_VERSION"
    SPV_SOURCE_DP_VERSION_RAW="$SPV_RELEASE_SELECTED_VERSION"
    SPV_SOURCE_DP_VERSION_ORIGIN="release-image.yml"
    SPV_SOURCE_DP_VERSION_CHECK="PASS"
    SPV_SOURCE_DP_VERSION_RESOLUTION="PASS"
    SPV_SOURCE_DP_VERSION_RECOVERY="${SPV_SOURCE_DP_VERSION_RECOVERY:-NOT_REQUIRED}"
    if [[ -n "$operator" ]]; then
      op_norm="$(spv_normalize_dp_version "$operator")" || {
        SPV_OPERATOR_SOURCE_VERSION_STATUS="INVALID"
        spv_set_failure "OPERATOR_OVERRIDE_INVALID"
        spv_write_resolution_evidence "$run_id"
        return 1
      }
      SPV_OPERATOR_SOURCE_VERSION_STATUS="PROVIDED"
      if [[ "$op_norm" != "$SPV_SOURCE_DP_VERSION" ]]; then
        SPV_OPERATOR_SOURCE_VERSION_STATUS="CONFLICT"
        spv_set_failure "OPERATOR_OVERRIDE_CONFLICT"
        spv_write_resolution_evidence "$run_id"
        return 1
      fi
    fi
    spv_write_resolution_evidence "$run_id"
    return 0
  fi

  # 5) operator override
  if [[ -n "$operator" ]]; then
    op_norm="$(spv_normalize_dp_version "$operator")" || {
      SPV_OPERATOR_SOURCE_VERSION_STATUS="INVALID"
      spv_set_failure "OPERATOR_OVERRIDE_INVALID"
      spv_write_resolution_evidence "$run_id"
      return 1
    }
    if ! spv_is_strict_product_version "$op_norm"; then
      SPV_OPERATOR_SOURCE_VERSION_STATUS="INVALID"
      spv_set_failure "OPERATOR_OVERRIDE_INVALID"
      spv_write_resolution_evidence "$run_id"
      return 1
    fi
    SPV_OPERATOR_SOURCE_VERSION_STATUS="PROVIDED"
    if [[ "$allow_write" == "1" ]]; then
      spv_persist_source_product_env "$dest" "$op_norm" "operator-argument" \
        "" "" "${run_id:-operator}" || true
    fi
    SPV_SOURCE_DP_VERSION="$op_norm"
    SPV_SOURCE_DP_VERSION_RAW="$operator"
    SPV_SOURCE_DP_VERSION_ORIGIN="operator-argument"
    SPV_SOURCE_DP_VERSION_CHECK="PASS"
    SPV_SOURCE_DP_VERSION_RESOLUTION="PASS"
    SPV_SOURCE_DP_VERSION_RECOVERY="OPERATOR"
    spv_write_resolution_evidence "$run_id"
    return 0
  fi

  # 6) fail closed with detailed reason
  SPV_OPERATOR_SOURCE_VERSION_STATUS="NOT_PROVIDED"
  local reason="NO_VALID_AUTHORITATIVE_SOURCE"
  case "${SPV_SOURCE_PRODUCT_ENV_STATUS}" in
    UNREADABLE) reason="SOURCE_PRODUCT_ENV_UNREADABLE" ;;
    DUPLICATE_KEY) reason="SOURCE_PRODUCT_ENV_DUPLICATE_KEY" ;;
    INVALID_SCHEMA) reason="SOURCE_PRODUCT_ENV_INVALID_SCHEMA" ;;
    INVALID_VERSION) reason="SOURCE_PRODUCT_ENV_INVALID_VERSION" ;;
    RECORDED_FAILURE) reason="SOURCE_PRODUCT_ENV_RECORDED_FAILURE" ;;
    VERSION_CONFLICT) reason="SOURCE_PRODUCT_ENV_VERSION_CONFLICT" ;;
  esac
  case "${SPV_PHASE1_LOG_EVIDENCE_STATUS}" in
    MULTIPLE_VERSIONS) reason="PHASE1_EVIDENCE_MULTIPLE_VERSIONS" ;;
    UNREADABLE) reason="PHASE1_EVIDENCE_UNREADABLE" ;;
    FAKE_SOURCE_ONLY) reason="PHASE1_EVIDENCE_FAKE_SOURCE_ONLY" ;;
  esac
  case "${SPV_AELLA_CLI_VERSION_DETECTION}" in
    TIMEOUT) reason="AELLA_CLI_TIMEOUT" ;;
    NONZERO) reason="AELLA_CLI_NONZERO" ;;
    NO_SEMVER) reason="AELLA_CLI_NO_SEMVER" ;;
    INCONSISTENT) reason="AELLA_CLI_INCONSISTENT_VERSIONS" ;;
  esac
  case "${SPV_RELEASE_IMAGE_STATUS}" in
    MALFORMED_AUTHORITATIVE_ENTRY) reason="RELEASE_IMAGE_MALFORMED_AUTHORITATIVE_ENTRY" ;;
    VERSION_CONFLICT) reason="RELEASE_IMAGE_VERSION_CONFLICT" ;;
    INSUFFICIENT_AUTHORITATIVE_RECORDS) reason="RELEASE_IMAGE_INSUFFICIENT_AUTHORITATIVE_RECORDS" ;;
    NO_AUTHORITATIVE_KEYS) reason="RELEASE_IMAGE_NO_AUTHORITATIVE_KEYS" ;;
  esac
  spv_set_failure "$reason"
  spv_write_resolution_evidence "$run_id"
  return 1
}
