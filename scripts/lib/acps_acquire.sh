#!/usr/bin/env bash
# scripts/lib/acps_acquire.sh — ACPS Phase 2 download (GUI credentials, no hardcoded secrets)
# shellcheck shell=bash
set +x

if [[ -n "${ACPS_ACQUIRE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
ACPS_ACQUIRE_LOADED=1

# Expects mirror_manager_common.sh and dp-phase2-common.sh already sourced.
# Auth/TLS (netrc, ACPS_INSECURE_TLS) lives in acps_auth.sh — shared with
# standalone scripts/download-dp-phase2.sh.

# shellcheck source=acps_auth.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/acps_auth.sh"

ACPS_CURL_CONNECT_TIMEOUT="${ACPS_CURL_CONNECT_TIMEOUT:-30}"
ACPS_CURL_RETRIES="${ACPS_CURL_RETRIES:-5}"
ACPS_CURL_RETRY_DELAY="${ACPS_CURL_RETRY_DELAY:-5}"
ACPS_PROGRESS_INTERVAL_SEC="${ACPS_PROGRESS_INTERVAL_SEC:-3}"

acps_cache_dir() {
  local ver="${1:-$DP_PHASE2_VERSION}"
  printf '%s/acps/%s\n' "${MM_CACHE_ROOT}" "$ver"
}

acps_work_dir_root() {
  printf '%s/acps-work\n' "${MM_CACHE_ROOT}"
}

# Private ACPS cache/work trees: directories 0700, files 0600.
# Public HTTP artifacts must never use these helpers.
acps_chmod_private_dir() {
  local path="$1"
  local want="${MM_PRIVATE_DIR_MODE:-0700}"
  chmod "$want" "$path" || return 1
  local actual
  actual="$(stat -c '%a' "$path" 2>/dev/null || true)"
  actual="${actual#"${actual%%[!0]*}"}"
  local want_n="${want#"${want%%[!0]*}"}"
  [[ -n "$actual" ]] || actual=0
  [[ -n "$want_n" ]] || want_n=0
  [[ "$actual" == "$want_n" ]]
}

acps_chmod_private_file() {
  local path="$1"
  local want="${MM_PRIVATE_FILE_MODE:-0600}"
  chmod "$want" "$path" || return 1
  local actual
  actual="$(stat -c '%a' "$path" 2>/dev/null || true)"
  actual="${actual#"${actual%%[!0]*}"}"
  local want_n="${want#"${want%%[!0]*}"}"
  [[ -n "$actual" ]] || actual=0
  [[ -n "$want_n" ]] || want_n=0
  [[ "$actual" == "$want_n" ]]
}

acps_ensure_private_cache_dir() {
  local dir="$1"
  mkdir -p "$dir" || return 1
  # Harden parents under .install-cache/acps and acps-work.
  local cur="$dir"
  local cache_root="${MM_CACHE_ROOT}"
  while [[ -n "$cur" && "$cur" != "/" && "$cur" != "$cache_root" ]]; do
    acps_chmod_private_dir "$cur" || return 1
    case "$(basename "$cur")" in
      acps|acps-work) break ;;
    esac
    cur="$(dirname "$cur")"
  done
  if [[ -d "${cache_root}/acps" ]]; then
    acps_chmod_private_dir "${cache_root}/acps" || true
  fi
  if [[ -d "${cache_root}/acps-work" ]]; then
    acps_chmod_private_dir "${cache_root}/acps-work" || true
  fi
  return 0
}

acps_enforce_private_tree_permissions() {
  local root="$1"
  local path
  [[ -d "$root" ]] || return 0
  acps_chmod_private_dir "$root" || return 1
  while IFS= read -r -d '' path; do
    acps_chmod_private_dir "$path" || return 1
  done < <(find "$root" -mindepth 1 -type d -print0 2>/dev/null)
  while IFS= read -r -d '' path; do
    acps_chmod_private_file "$path" || return 1
  done < <(find "$root" -type f -print0 2>/dev/null)
  return 0
}

# Metadata-bound verified-cache contract.
# Fast reuse trusts .VERIFIED only when every required file's mutation-sensitive
# identity still matches the marker written after a successful checksum pass.
# Large payloads are not SHA256-read on an unchanged cache; checksum sidecars
# (small) are re-hashed because they are the payload trust source.
acps_file_metadata_fp() {
  local path="$1"
  # size|dev|ino|mtime_epoch|ctime_epoch
  stat -c '%s|%d|%i|%Y|%Z' "$path" 2>/dev/null || true
}

acps_is_checksum_sidecar() {
  case "$1" in
    *.sha1|*.sha256) return 0 ;;
    *) return 1 ;;
  esac
}

acps_sidecar_checksum_id() {
  local path="$1"
  sha256sum "$path" 2>/dev/null | awk '{print $1}'
}

acps_payload_checksum_id() {
  local dir="$1" name="$2"
  local side=""
  case "$name" in
    *.sha1|*.sha256) return 0 ;;
  esac
  if [[ -f "${dir}/${name}.sha256" ]]; then
    side="${dir}/${name}.sha256"
  elif [[ -f "${dir}/${name}.sha1" ]]; then
    side="${dir}/${name}.sha1"
  else
    printf '\n'
    return 0
  fi
  awk 'NF {print $1; exit}' "$side" 2>/dev/null || true
}

acps_write_verified_marker() {
  local dir="$1"
  local tmp f fp cid
  tmp="${dir}/.VERIFIED.tmp.$$"
  {
    printf 'ACPS_VERIFIED_FORMAT=1\n'
    printf 'VERIFIED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
      fp="$(acps_file_metadata_fp "${dir}/${f}")"
      [[ -n "$fp" ]] || { rm -f "$tmp"; return 1; }
      if acps_is_checksum_sidecar "$f"; then
        cid="$(acps_sidecar_checksum_id "${dir}/${f}")"
      else
        cid="$(acps_payload_checksum_id "$dir" "$f")"
      fi
      printf 'FILE path=%s fp=%s checksum_id=%s\n' "$f" "$fp" "$cid"
    done
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  acps_chmod_private_file "$tmp" 2>/dev/null || chmod 0600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "${dir}/.VERIFIED"
  acps_chmod_private_file "${dir}/.VERIFIED" 2>/dev/null || true
}

acps_is_verified_cache() {
  # Trust .VERIFIED only when format=1 metadata still matches on-disk files.
  # Legacy timestamp-only / malformed markers never reuse.
  local dir="$1"
  local marker="${dir}/.VERIFIED"
  local f line path fp stored_fp stored_cid cur_fp cur_cid fmt
  [[ -f "$marker" ]] || return 1
  fmt="$(head -n 1 "$marker" 2>/dev/null || true)"
  [[ "$fmt" == "ACPS_VERIFIED_FORMAT=1" ]] || return 1

  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    [[ -f "${dir}/${f}" ]] || return 1
  done
  if ! (
    set +e
    for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
      dp2_reject_bad_payload "${dir}/${f}" "$f" >/dev/null 2>&1 || exit 1
    done
    exit 0
  ); then
    return 1
  fi

  local -A seen_paths=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == FILE' '* ]] || continue
    path="$(printf '%s\n' "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^path=/) {print substr($i,6); exit}}')"
    stored_fp="$(printf '%s\n' "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^fp=/) {print substr($i,4); exit}}')"
    stored_cid="$(printf '%s\n' "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^checksum_id=/) {print substr($i,13); exit}}')"
    [[ -n "$path" && -n "$stored_fp" ]] || return 1
    [[ -f "${dir}/${path}" ]] || return 1
    cur_fp="$(acps_file_metadata_fp "${dir}/${path}")"
    [[ "$cur_fp" == "$stored_fp" ]] || return 1
    if acps_is_checksum_sidecar "$path"; then
      cur_cid="$(acps_sidecar_checksum_id "${dir}/${path}")"
      [[ -n "$stored_cid" && "$cur_cid" == "$stored_cid" ]] || return 1
    else
      cur_cid="$(acps_payload_checksum_id "$dir" "$path")"
      if [[ -n "$stored_cid" && -n "$cur_cid" && "$cur_cid" != "$stored_cid" ]]; then
        return 1
      fi
    fi
    seen_paths["$path"]=1
  done <"$marker"

  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    [[ -n "${seen_paths[$f]:-}" ]] || return 1
  done
  return 0
}

acps_disk_preflight_state_file() {
  local ver="${1:-${DP_PHASE2_VERSION:-${TARGET_DP_VERSION:-6.6.0}}}"
  if [[ -n "${MM_STATE_DIR:-}" ]]; then
    printf '%s/acps-disk-preflight.env\n' "$MM_STATE_DIR"
  else
    printf '%s/.acps-disk-preflight-%s.env\n' "${MM_CACHE_ROOT}" "$ver"
  fi
}

# Resolve remote size for a required ACPS artifact. Never treat unknown as 0.
# 1) HEAD/GET -I -L → final response Content-Length
# 2) Range: bytes=0-0 → Content-Range TOTAL
# Returns 0 and prints a positive integer, or 1 with empty stdout on failure.
acps_remote_content_length() {
  local base="$1"
  local name="$2"
  local url cl err headers cr total
  url="${base%/}/${name}"
  err="$(mktemp)"
  headers="$(
    curl -sS -I -L --connect-timeout "$ACPS_CURL_CONNECT_TIMEOUT" \
      ${ACPS_CURL_AUTH_ARGS[@]+"${ACPS_CURL_AUTH_ARGS[@]}"} \
      ${ACPS_CURL_TLS_ARGS[@]+"${ACPS_CURL_TLS_ARGS[@]}"} \
      "$url" 2>"$err" | tr -d '\r'
  )" || true
  cl="$(
    printf '%s\n' "$headers" \
      | awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="content-length"{v=$2} END{print v}'
  )"
  if [[ "$cl" =~ ^[1-9][0-9]*$ ]]; then
    rm -f "$err"
    printf '%s\n' "$cl"
    return 0
  fi

  # Fallback: Range probe for Content-Range: bytes 0-0/TOTAL
  headers="$(
    curl -sS -I -L --connect-timeout "$ACPS_CURL_CONNECT_TIMEOUT" \
      -H 'Range: bytes=0-0' \
      ${ACPS_CURL_AUTH_ARGS[@]+"${ACPS_CURL_AUTH_ARGS[@]}"} \
      ${ACPS_CURL_TLS_ARGS[@]+"${ACPS_CURL_TLS_ARGS[@]}"} \
      "$url" 2>"$err" | tr -d '\r'
  )" || true
  cr="$(
    printf '%s\n' "$headers" \
      | awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="content-range"{v=$2} END{print v}'
  )"
  # Also try a 1-byte GET if HEAD omitted Content-Range.
  if [[ -z "$cr" ]]; then
    headers="$(
      curl -sS -L --connect-timeout "$ACPS_CURL_CONNECT_TIMEOUT" \
        -H 'Range: bytes=0-0' -D - -o /dev/null \
        ${ACPS_CURL_AUTH_ARGS[@]+"${ACPS_CURL_AUTH_ARGS[@]}"} \
        ${ACPS_CURL_TLS_ARGS[@]+"${ACPS_CURL_TLS_ARGS[@]}"} \
        "$url" 2>"$err" | tr -d '\r'
    )" || true
    cr="$(
      printf '%s\n' "$headers" \
        | awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="content-range"{v=$2} END{print v}'
    )"
  fi
  rm -f "$err"
  total="$(
    printf '%s\n' "$cr" \
      | sed -nE 's/^[Bb][Yy][Tt][Ee][Ss][[:space:]]+[0-9]+-[0-9]+\/([0-9]+).*$/\1/p'
  )"
  if [[ "$total" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "$total"
    return 0
  fi
  return 1
}

# Sum sizes of a verified local ACPS cache (no network). Fail closed if incomplete.
acps_local_verified_cache_bytes() {
  local ver="${1:-${DP_PHASE2_VERSION:-${TARGET_DP_VERSION:-6.6.0}}}"
  local cache name sz total=0
  cache="$(acps_cache_dir "$ver")"
  acps_is_verified_cache "$cache" || return 1
  for name in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    [[ -f "${cache}/${name}" ]] || return 1
    sz="$(stat -c%s "${cache}/${name}" 2>/dev/null || echo 0)"
    [[ "$sz" =~ ^[0-9]+$ ]] || return 1
    total=$((total + sz))
  done
  printf '%s\n' "$total"
}

acps_collect_disk_preflight_state() {
  # Build a per-file, remote-size-bounded resume snapshot. This function is
  # called inside command substitution by acps_expected_bytes_hint(), so stdout
  # must contain only the aggregate expected byte count.
  local base="$1"
  local ver="${2:-${DP_PHASE2_VERSION:-${TARGET_DP_VERSION:-6.6.0}}}"
  local cache state tmp name expected local_bytes credited
  local total=0 completed=0 partial=0 reusable remaining

  cache="$(acps_cache_dir "$ver")"
  state="$(acps_disk_preflight_state_file "$ver")"
  mkdir -p "$(dirname "$state")" 2>/dev/null || true
  acps_ensure_private_cache_dir "$(dirname "$state")" 2>/dev/null || true

  for name in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    if ! expected="$(acps_remote_content_length "$base" "$name")"; then
      if declare -F mm_error >/dev/null 2>&1; then
        mm_error "ACPS_REMOTE_SIZE_UNKNOWN=YES file=${name}"
        mm_error "DISK_PREFLIGHT=FAIL"
      else
        printf 'ACPS_REMOTE_SIZE_UNKNOWN=YES file=%s\n' "$name" >&2
        printf 'DISK_PREFLIGHT=FAIL\n' >&2
      fi
      return 1
    fi
    if [[ ! "$expected" =~ ^[1-9][0-9]*$ ]]; then
      if declare -F mm_error >/dev/null 2>&1; then
        mm_error "ACPS_REMOTE_SIZE_UNKNOWN=YES file=${name} value=${expected:-}"
        mm_error "DISK_PREFLIGHT=FAIL"
      else
        printf 'ACPS_REMOTE_SIZE_UNKNOWN=YES file=%s\n' "$name" >&2
        printf 'DISK_PREFLIGHT=FAIL\n' >&2
      fi
      return 1
    fi
    total=$((total + expected))

    # Credit only bytes that curl will actually reuse. Final files take
    # precedence because acps_download_one() skips them; otherwise .part is
    # resumed with --continue-at -. Bound each credit by that file's remote
    # Content-Length so an oversized/stale partial cannot hide another file's
    # future growth requirement.
    local_bytes=0
    credited=0
    if [[ -f "${cache}/${name}" ]]; then
      local_bytes="$(stat -c%s "${cache}/${name}" 2>/dev/null || echo 0)"
      [[ "$local_bytes" =~ ^[0-9]+$ ]] || local_bytes=0
      if [[ "$local_bytes" -gt "$expected" ]]; then
        credited="$expected"
      else
        credited="$local_bytes"
      fi
      completed=$((completed + credited))
    elif [[ -f "${cache}/${name}.part" ]]; then
      local_bytes="$(stat -c%s "${cache}/${name}.part" 2>/dev/null || echo 0)"
      [[ "$local_bytes" =~ ^[0-9]+$ ]] || local_bytes=0
      if [[ "$local_bytes" -gt "$expected" ]]; then
        credited="$expected"
      else
        credited="$local_bytes"
      fi
      partial=$((partial + credited))
    fi
  done

  reusable=$((completed + partial))
  if [[ "$reusable" -gt "$total" ]]; then
    reusable="$total"
  fi
  remaining=$((total - reusable))

  tmp="$(mktemp "${state}.tmp.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/acps-preflight.XXXXXX")"
  {
    printf 'ACPS_PREFLIGHT_VERSION=%s\n' "$ver"
    printf 'ACPS_EXPECTED_BYTES=%s\n' "$total"
    printf 'ACPS_COMPLETED_CACHE_BYTES=%s\n' "$completed"
    printf 'ACPS_PARTIAL_BYTES=%s\n' "$partial"
    printf 'ACPS_REUSABLE_ON_DISK_BYTES=%s\n' "$reusable"
    printf 'ACPS_REMAINING_DOWNLOAD_BYTES=%s\n' "$remaining"
  } >"$tmp"
  chmod 0600 "$tmp" 2>/dev/null || true
  if [[ -d "$(dirname "$state")" && -w "$(dirname "$state")" ]]; then
    mv -f "$tmp" "$state"
  else
    rm -f "$tmp"
  fi

  printf '%s\n' "$total"
}

acps_expected_bytes_hint() {
  local base="$1"
  local ver="${DP_PHASE2_VERSION:-${TARGET_DP_VERSION:-6.6.0}}"
  acps_collect_disk_preflight_state "$base" "$ver"
}

acps_load_disk_preflight_state() {
  # Load the resume snapshot only when it matches the exact expected byte total
  # and target version for this run. Any missing/malformed/mismatched state
  # fails conservative: no reusable bytes are credited.
  local expected="$1"
  local ver="$2"
  local state stored_expected stored_ver completed partial reusable

  ACPS_COMPLETED_CACHE_BYTES=0
  ACPS_PARTIAL_BYTES=0
  ACPS_REUSABLE_ON_DISK_BYTES=0
  ACPS_REMAINING_DOWNLOAD_BYTES="$expected"

  state="$(acps_disk_preflight_state_file "$ver")"
  [[ -f "$state" ]] || return 0

  stored_ver="$(awk -F= '$1=="ACPS_PREFLIGHT_VERSION"{print substr($0,index($0,"=")+1);exit}' "$state" 2>/dev/null || true)"
  stored_expected="$(awk -F= '$1=="ACPS_EXPECTED_BYTES"{print $2;exit}' "$state" 2>/dev/null || true)"
  completed="$(awk -F= '$1=="ACPS_COMPLETED_CACHE_BYTES"{print $2;exit}' "$state" 2>/dev/null || true)"
  partial="$(awk -F= '$1=="ACPS_PARTIAL_BYTES"{print $2;exit}' "$state" 2>/dev/null || true)"

  [[ "$stored_ver" == "$ver" && "$stored_expected" == "$expected" ]] || return 0
  [[ "$completed" =~ ^[0-9]+$ ]] || return 0
  [[ "$partial" =~ ^[0-9]+$ ]] || return 0

  reusable=$((completed + partial))
  if [[ "$reusable" -gt "$expected" ]]; then
    reusable="$expected"
  fi

  ACPS_COMPLETED_CACHE_BYTES="$completed"
  ACPS_PARTIAL_BYTES="$partial"
  ACPS_REUSABLE_ON_DISK_BYTES="$reusable"
  ACPS_REMAINING_DOWNLOAD_BYTES=$((expected - reusable))
  return 0
}

# ACPS-aware override of mirror_manager_common.sh:mm_calc_disk_requirements().
# The generic calculator sees only aggregate ACPS size and therefore used to
# double-count already-downloaded final/.part files after an interrupted run:
# df(available) already excluded those bytes, while the calculator reserved the
# full ACPS source again. Keep the bundle output at the full remote size, but
# reserve only the remaining ACPS download growth. All other peak/safety logic
# intentionally mirrors the common implementation.
mm_calc_disk_requirements() {
  local os_pkg_bytes payload_bytes acps_bytes acps_remaining_bytes ver existing_bundle
  local reserve_floor_bytes reserve_pct_bytes fs_size_bytes metadata_oh
  local stage_peak_bytes current_used_bytes existing_final_bytes
  local reuse_phase2=0 one_copy=0

  os_pkg_bytes="${OS_CORE_PACKAGE_BYTES:-0}"
  payload_bytes="${OS_CORE_PAYLOAD_BYTES:-0}"
  acps_bytes="${ACPS_EXPECTED_BYTES:-0}"
  [[ "$os_pkg_bytes" =~ ^[0-9]+$ ]] || os_pkg_bytes=0
  [[ "$payload_bytes" =~ ^[0-9]+$ ]] || payload_bytes=0
  [[ "$acps_bytes" =~ ^[0-9]+$ ]] || acps_bytes=0
  metadata_oh=$((512 * 1024 * 1024))
  ver="${TARGET_DP_VERSION:-${DP_PHASE2_VERSION:-6.6.0}}"

  ACPS_COMPLETED_CACHE_BYTES=0
  ACPS_PARTIAL_BYTES=0
  ACPS_REUSABLE_ON_DISK_BYTES=0
  ACPS_REMAINING_DOWNLOAD_BYTES="$acps_bytes"

  if [[ "${PHASE2_BUNDLE_ACTION:-}" == "REUSE" || "${PHASE2_REBUILD_REQUIRED:-}" == "NO" ]]; then
    reuse_phase2=1
    acps_bytes=0
    ACPS_REMAINING_DOWNLOAD_BYTES=0
  elif [[ "${PHASE2_REBUILD_SOURCE:-}" == "EXISTING_FINAL" ]]; then
    acps_bytes=0
    ACPS_REMAINING_DOWNLOAD_BYTES=0
  else
    acps_load_disk_preflight_state "$acps_bytes" "$ver"
  fi
  acps_remaining_bytes="${ACPS_REMAINING_DOWNLOAD_BYTES:-$acps_bytes}"
  [[ "$acps_remaining_bytes" =~ ^[0-9]+$ ]] || acps_remaining_bytes="$acps_bytes"
  if [[ "$acps_remaining_bytes" -gt "$acps_bytes" ]]; then
    acps_remaining_bytes="$acps_bytes"
  fi

  DISK_PREFLIGHT_R2_REQUIRED_BYTES=0
  # Already-downloaded ACPS bytes are reflected in df available and are reused
  # in place. Only future source growth consumes additional free space.
  DISK_PREFLIGHT_ACPS_SOURCE_BYTES=$acps_remaining_bytes
  # The final tar is still created at the complete remote ACPS size.
  DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES=$acps_bytes
  PHASE2_ACPS_SOURCE_REQUIRED_BYTES=$DISK_PREFLIGHT_ACPS_SOURCE_BYTES
  PHASE2_BUNDLE_OUTPUT_REQUIRED_BYTES=$DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES
  VALID_FINAL_REBUILD_REQUIRED_BYTES=0
  if [[ "$reuse_phase2" -eq 1 ]]; then
    PHASE2_REBUILD_REQUIRED=NO
  else
    PHASE2_REBUILD_REQUIRED="${PHASE2_REBUILD_REQUIRED:-YES}"
  fi

  DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES=0
  existing_final_bytes=0
  existing_bundle="${MM_DP_PHASE2_ROOT:-${MM_MIRROR_ROOT:-/var/spool/apt-mirror}/dp-phase2}/${ver}/dp_bundle_${ver}-current.tar"
  if [[ -f "$existing_bundle" ]]; then
    existing_final_bytes="$(mm_file_bytes "$existing_bundle")"
    [[ "$existing_final_bytes" =~ ^[0-9]+$ ]] || existing_final_bytes=0
  fi
  DISK_PREFLIGHT_EXISTING_FINAL_BYTES=$existing_final_bytes

  DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES=$((payload_bytes + metadata_oh))
  if [[ "$reuse_phase2" -eq 1 ]]; then
    DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES=$metadata_oh
  elif [[ "${PHASE2_REBUILD_SOURCE:-}" == "EXISTING_FINAL" ]]; then
    one_copy="${PHASE2_EXISTING_FINAL_BYTES:-0}"
    [[ "$one_copy" =~ ^[0-9]+$ ]] || one_copy=0
    if [[ "$one_copy" -eq 0 ]]; then
      one_copy=$existing_final_bytes
    fi
    DISK_PREFLIGHT_ACPS_SOURCE_BYTES=0
    DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES=$one_copy
    PHASE2_ACPS_SOURCE_REQUIRED_BYTES=0
    PHASE2_BUNDLE_OUTPUT_REQUIRED_BYTES=$one_copy
    DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES=$((one_copy + metadata_oh))
  else
    DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES=$((
      DISK_PREFLIGHT_ACPS_SOURCE_BYTES
      + DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES
      + metadata_oh
    ))
  fi
  PHASE2_STAGE_REQUIRED_BYTES=$DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES
  mm_normalize_preparation_mode
  if mm_is_phase2_only; then
    DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES=0
    stage_peak_bytes=$DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES
    DISK_PREFLIGHT_R2_REQUIRED_BYTES=0
  elif [[ "$DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES" -gt "$DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES" ]]; then
    stage_peak_bytes=$DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES
  else
    stage_peak_bytes=$DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES
  fi
  DISK_PREFLIGHT_SEQUENTIAL_STAGE_PEAK_BYTES=$stage_peak_bytes
  DISK_PREFLIGHT_TEMP_OVERHEAD_BYTES=$metadata_oh
  DISK_PREFLIGHT_PREPARATION_MODE="${PREPARATION_MODE}"

  reserve_floor_bytes=$((10 * 1024 * 1024 * 1024))
  fs_size_bytes="$(mm_fs_size_bytes "${MM_MIRROR_ROOT}")"
  [[ "$fs_size_bytes" =~ ^[0-9]+$ ]] || fs_size_bytes=0
  if [[ -n "${MM_MOCK_SAFETY_RESERVE_BYTES:-}" ]]; then
    DISK_PREFLIGHT_SAFETY_RESERVE_BYTES="$MM_MOCK_SAFETY_RESERVE_BYTES"
  else
    reserve_pct_bytes=$((fs_size_bytes / 10))
    if [[ "$reserve_pct_bytes" -gt "$reserve_floor_bytes" ]]; then
      DISK_PREFLIGHT_SAFETY_RESERVE_BYTES=$reserve_pct_bytes
    else
      DISK_PREFLIGHT_SAFETY_RESERVE_BYTES=$reserve_floor_bytes
    fi
  fi
  [[ "$DISK_PREFLIGHT_SAFETY_RESERVE_BYTES" =~ ^[0-9]+$ ]] \
    || DISK_PREFLIGHT_SAFETY_RESERVE_BYTES=$reserve_floor_bytes

  OS_MATERIALIZE_TEMP_BYTES=$payload_bytes
  DP_BUILD_TEMP_BYTES=$DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES
  SAFETY_MARGIN_BYTES=$DISK_PREFLIGHT_SAFETY_RESERVE_BYTES

  CURRENT_AVAILABLE_BASED_REQUIRED_BYTES=$((
    stage_peak_bytes + DISK_PREFLIGHT_SAFETY_RESERVE_BYTES
  ))
  DISK_PREFLIGHT_TOTAL_REQUIRED_BYTES=$CURRENT_AVAILABLE_BASED_REQUIRED_BYTES
  TOTAL_REQUIRED_BYTES=$CURRENT_AVAILABLE_BASED_REQUIRED_BYTES

  DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES="$(mm_free_bytes "${MM_MIRROR_ROOT}")"
  AVAILABLE_BYTES="$DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES"
  [[ -n "$AVAILABLE_BYTES" && "$AVAILABLE_BYTES" =~ ^[0-9]+$ ]] \
    || mm_die "DISK_PREFLIGHT=FAIL cannot_read_df"

  if [[ "$fs_size_bytes" -ge "$AVAILABLE_BYTES" ]]; then
    current_used_bytes=$((fs_size_bytes - AVAILABLE_BYTES))
  else
    current_used_bytes=0
  fi
  TOTAL_CAPACITY_BASED_PROJECTED_PEAK_BYTES=$((current_used_bytes + stage_peak_bytes))
  DISK_PREFLIGHT_PROJECTED_PEAK_BYTES=$TOTAL_CAPACITY_BASED_PROJECTED_PEAK_BYTES

  if [[ "$AVAILABLE_BYTES" -lt "$TOTAL_REQUIRED_BYTES" ]]; then
    DISK_PREFLIGHT_RESULT=FAIL
    DISK_PREFLIGHT=FAIL
  else
    DISK_PREFLIGHT_RESULT=PASS
    DISK_PREFLIGHT=PASS
  fi

  mm_info "MIRROR_SERVER_DISK=100GB"
  mm_info "OS_CORE_PACKAGE_BYTES=${os_pkg_bytes}"
  mm_info "OS_CORE_PAYLOAD_BYTES=${payload_bytes}"
  mm_info "ACPS_EXPECTED_BYTES=${acps_bytes}"
  mm_info "ACPS_COMPLETED_CACHE_BYTES=${ACPS_COMPLETED_CACHE_BYTES:-0}"
  mm_info "ACPS_PARTIAL_BYTES=${ACPS_PARTIAL_BYTES:-0}"
  mm_info "ACPS_REUSABLE_ON_DISK_BYTES=${ACPS_REUSABLE_ON_DISK_BYTES:-0}"
  mm_info "ACPS_REMAINING_DOWNLOAD_BYTES=${ACPS_REMAINING_DOWNLOAD_BYTES:-0}"
  mm_info "PHASE2_BUNDLE_ACTION=${PHASE2_BUNDLE_ACTION:-}"
  mm_info "PHASE2_REBUILD_REQUIRED=${PHASE2_REBUILD_REQUIRED}"
  mm_info "PHASE2_ACPS_SOURCE_REQUIRED_BYTES=${PHASE2_ACPS_SOURCE_REQUIRED_BYTES}"
  mm_info "PHASE2_BUNDLE_OUTPUT_REQUIRED_BYTES=${PHASE2_BUNDLE_OUTPUT_REQUIRED_BYTES}"
  mm_info "PHASE2_STAGE_REQUIRED_BYTES=${PHASE2_STAGE_REQUIRED_BYTES}"
  mm_info "VALID_FINAL_REBUILD_REQUIRED_BYTES=${VALID_FINAL_REBUILD_REQUIRED_BYTES}"
  mm_info "OS_MATERIALIZE_TEMP_BYTES=${OS_MATERIALIZE_TEMP_BYTES}"
  mm_info "DP_BUILD_TEMP_BYTES=${DP_BUILD_TEMP_BYTES}"
  mm_info "DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES=${DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES}"
  mm_info "DISK_PREFLIGHT_R2_REQUIRED_BYTES=${DISK_PREFLIGHT_R2_REQUIRED_BYTES}"
  mm_info "DISK_PREFLIGHT_ACPS_SOURCE_BYTES=${DISK_PREFLIGHT_ACPS_SOURCE_BYTES}"
  mm_info "DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES=${DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES}"
  mm_info "DISK_PREFLIGHT_EXISTING_FINAL_BYTES=${DISK_PREFLIGHT_EXISTING_FINAL_BYTES}"
  mm_info "DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES=${DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES}"
  mm_info "DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES=${DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES}"
  mm_info "DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES=${DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES}"
  mm_info "DISK_PREFLIGHT_SEQUENTIAL_STAGE_PEAK_BYTES=${DISK_PREFLIGHT_SEQUENTIAL_STAGE_PEAK_BYTES}"
  mm_info "DISK_PREFLIGHT_TEMP_OVERHEAD_BYTES=${DISK_PREFLIGHT_TEMP_OVERHEAD_BYTES}"
  mm_info "DISK_PREFLIGHT_SAFETY_RESERVE_BYTES=${DISK_PREFLIGHT_SAFETY_RESERVE_BYTES}"
  mm_info "CURRENT_AVAILABLE_BASED_REQUIRED_BYTES=${CURRENT_AVAILABLE_BASED_REQUIRED_BYTES}"
  mm_info "TOTAL_CAPACITY_BASED_PROJECTED_PEAK_BYTES=${TOTAL_CAPACITY_BASED_PROJECTED_PEAK_BYTES}"
  mm_info "DISK_PREFLIGHT_TOTAL_REQUIRED_BYTES=${DISK_PREFLIGHT_TOTAL_REQUIRED_BYTES}"
  mm_info "TOTAL_REQUIRED_BYTES=${TOTAL_REQUIRED_BYTES}"
  mm_info "AVAILABLE_BYTES=${AVAILABLE_BYTES}"
  mm_info "DISK_PREFLIGHT_RESULT=${DISK_PREFLIGHT_RESULT}"
  mm_info "DISK_PREFLIGHT=${DISK_PREFLIGHT}"
  [[ "$DISK_PREFLIGHT" == "PASS" ]] || mm_die "DISK_PREFLIGHT=FAIL"
}

acps_test_connection() {
  # Probe an authenticated artifact, not the directory index.
  # ACPS nginx returns 403 for "/" even with valid Basic auth (no autoindex),
  # which previously caused false ACPS_CONNECTION=FAIL.
  local owned=0
  local probe="${ACPS_CONNECTION_PROBE_FILE:-aelladeb_py3_common.tar.gz.sha1}"
  local url code
  # Standalone callers get a private auth session; callers that already ran
  # acps_setup_curl_auth keep their session for subsequent HEAD/download work.
  if [[ -z "${ACPS_EFFECTIVE_BASE:-}" || ( ${#ACPS_CURL_AUTH_ARGS[@]} -eq 0 && -z "${DP_PHASE2_SOURCE_BASE:-}" ) ]]; then
    acps_setup_curl_auth
    owned=1
  fi
  url="${ACPS_EFFECTIVE_BASE%/}/${probe}"
  code="$(
    curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 30 \
      ${ACPS_CURL_TLS_ARGS[@]+"${ACPS_CURL_TLS_ARGS[@]}"} \
      ${ACPS_CURL_AUTH_ARGS[@]+"${ACPS_CURL_AUTH_ARGS[@]}"} \
      -I -L "$url" 2>/dev/null || true
  )"
  code="${code:-000}"
  [[ "$owned" -eq 1 ]] && acps_cleanup_curl_auth
  # curl may print "000" on failure; ignore non-numeric garbage
  [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
  if [[ "$code" == "000" ]]; then
    mm_error "ACPS_CONNECTION=FAIL code=${code} url=${probe}"
    return 1
  fi
  if [[ "$code" == "401" ]]; then
    mm_error "ACPS_CONNECTION=FAIL auth code=${code}"
    return 1
  fi
  if [[ "$code" == "403" ]]; then
    mm_error "ACPS_CONNECTION=FAIL forbidden code=${code} url=${probe}"
    return 1
  fi
  if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
    mm_ok "ACPS_CONNECTION=PASS code=${code} probe=${probe}"
    return 0
  fi
  # 404 after auth usually means wrong version/path, not bad password.
  mm_error "ACPS_CONNECTION=FAIL unexpected code=${code} probe=${probe}"
  return 1
}

acps_download_one() {
  local name="$1"
  local dest_dir="$2"
  local part="${dest_dir}/${name}.part"
  local final="${dest_dir}/${name}"
  local url="${ACPS_EFFECTIVE_BASE%/}/${name}"
  local start_ts now elapsed downloaded expected pct rate
  local curl_args=(
    -f -L
    --connect-timeout "$ACPS_CURL_CONNECT_TIMEOUT"
    --retry "$ACPS_CURL_RETRIES"
    --retry-delay "$ACPS_CURL_RETRY_DELAY"
    --retry-all-errors
    --continue-at -
    -o "$part"
  )
  curl_args+=(${ACPS_CURL_TLS_ARGS[@]+"${ACPS_CURL_TLS_ARGS[@]}"})
  curl_args+=(${ACPS_CURL_AUTH_ARGS[@]+"${ACPS_CURL_AUTH_ARGS[@]}"})

  mkdir -p "$dest_dir"
  acps_ensure_private_cache_dir "$dest_dir" 2>/dev/null || true
  if [[ -f "$final" ]]; then
    mm_info "ACPS_DOWNLOAD_SKIP_EXISTING file=${name}"
    acps_chmod_private_file "$final" 2>/dev/null || true
    return 0
  fi

  mm_info "ACPS_DOWNLOAD_START file=${name}"
  start_ts="$(date +%s)"
  expected=""
  local cl err_head
  err_head="$(mktemp)"
  cl="$(
    curl -sS -I -L --connect-timeout "$ACPS_CURL_CONNECT_TIMEOUT" \
      ${ACPS_CURL_TLS_ARGS[@]+"${ACPS_CURL_TLS_ARGS[@]}"} \
      ${ACPS_CURL_AUTH_ARGS[@]+"${ACPS_CURL_AUTH_ARGS[@]}"} \
      "$url" 2>"$err_head" | tr -d '\r' \
      | awk -F': ' 'tolower($1)=="content-length"{v=$2} END{print v}'
  )" || true
  rm -f "$err_head"
  if [[ "$cl" =~ ^[1-9][0-9]*$ ]]; then
    expected="$cl"
  fi

  local err progress_pid=""
  err="$(mktemp)"
  (
    while true; do
      sleep "$ACPS_PROGRESS_INTERVAL_SEC" || break
      now="$(date +%s)"
      elapsed=$((now - start_ts))
      downloaded=0
      [[ -f "$part" ]] && downloaded="$(stat -c%s "$part" 2>/dev/null || echo 0)"
      pct="UNKNOWN"
      rate="UNKNOWN"
      if [[ -n "$expected" && "$expected" -gt 0 ]]; then
        pct=$((downloaded * 100 / expected))
      fi
      if [[ "$elapsed" -gt 0 ]]; then
        rate=$((downloaded / elapsed))
      fi
      mm_info "ACPS_DOWNLOAD_PROGRESS file=${name} downloaded_bytes=${downloaded} expected_bytes=${expected:-UNKNOWN} percentage=${pct} elapsed=${elapsed}s rate_bps=${rate}"
      mm_progress_line "ACPS ${name}" "$downloaded" "${expected:-}" "$elapsed" "$rate"
    done
  ) &
  progress_pid=$!

  # Preserve real curl rc: `if ! curl; then rc=$?` yields 0 inside the then-branch.
  local rc=0
  if curl "${curl_args[@]}" "$url" 2>"$err"; then
    rc=0
  else
    rc=$?
  fi
  if [[ -n "$progress_pid" ]]; then
    kill "$progress_pid" 2>/dev/null || true
    wait "$progress_pid" 2>/dev/null || true
  fi

  if [[ "$rc" -ne 0 ]]; then
    mm_redact <"$err" >&2 || true
    rm -f "$err"
    mm_error "ACPS_DOWNLOAD_FAILED file=${name} curl_rc=${rc}"
    return "$rc"
  fi
  rm -f "$err"

  if ! dp2_reject_bad_payload "$part" "$name"; then
    rm -f "$part"
    mm_error "ACPS_DOWNLOAD_FAILED file=${name} reason=bad_payload"
    return 1
  fi
  mv -f "$part" "$final" || {
    mm_error "ACPS_DOWNLOAD_FAILED file=${name} reason=finalize"
    return 1
  }
  acps_chmod_private_file "$final" 2>/dev/null || true
  now="$(date +%s)"
  elapsed=$((now - start_ts))
  downloaded="$(stat -c%s "$final")"
  pct="UNKNOWN"
  rate="UNKNOWN"
  if [[ -n "$expected" && "$expected" -gt 0 ]]; then
    pct=$((downloaded * 100 / expected))
  fi
  if [[ "$elapsed" -gt 0 ]]; then
    rate=$((downloaded / elapsed))
  fi
  mm_info "ACPS_DOWNLOAD_PROGRESS file=${name} downloaded_bytes=${downloaded} expected_bytes=${expected:-UNKNOWN} percentage=${pct} elapsed=${elapsed}s rate_bps=${rate} final=yes"
  mm_progress_line "ACPS ${name}" "$downloaded" "${expected:-}" "$elapsed" "$rate"
  mm_ok "ACPS_DOWNLOAD_COMPLETE file=${name} size=${downloaded} elapsed=${elapsed}s"
  return 0
}

acps_acquire_all() {
  local ver="$1"
  local cache
  cache="$(acps_cache_dir "$ver")"
  acps_ensure_private_cache_dir "$cache" || mm_die "ACPS_CACHE_PERMS=FAIL path=${cache}"

  mm_set_phase "Downloading ACPS Artifacts"
  # Verified unchanged cache must reuse without contacting ACPS or requiring
  # credentials. Auth is only needed when a download is about to start.
  if acps_is_verified_cache "$cache"; then
    # Do not chmod payload files on the reuse path — that updates ctime and
    # would invalidate the metadata-bound .VERIFIED marker.
    acps_chmod_private_dir "$cache" 2>/dev/null || true
    mm_ok "ACPS_DOWNLOAD=REUSED cache=${cache}"
    mm_state_set ACPS_PHASE2_DOWNLOADED REUSED
    mm_state_set ACPS_CHECKSUM PASS
    return 0
  fi

  acps_setup_curl_auth

  rm -f "${cache}/.VERIFIED"

  local name
  for name in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    if ! acps_download_one "$name" "$cache"; then
      mm_state_set ACPS_PHASE2_DOWNLOADED FAIL
      acps_cleanup_curl_auth
      mm_die "ACPS_DOWNLOAD=FAIL file=${name}"
    fi
    acps_chmod_private_file "${cache}/${name}" 2>/dev/null || true
  done

  dp2_assert_exact_files_dir "$cache"
  # Final checksum authority: on failure invalidate only the corrupt payload
  # finals so a subsequent Menu 2 retry redownloads those files (not unrelated
  # valid large artifacts that already passed verification).
  if ! mm_acps_verify_payload_checksums "$cache" 1; then
    mm_state_set ACPS_CHECKSUM FAIL
    rm -f "${cache}/.VERIFIED"
    acps_cleanup_curl_auth
    mm_die "ACPS_CHECKSUM=FAIL"
  fi
  mm_state_set ACPS_CHECKSUM PASS
  # Permissions before the metadata-bound marker so ctime is stable afterward.
  acps_enforce_private_tree_permissions "$cache" || mm_die "ACPS_CACHE_PERMS=FAIL"
  if ! acps_write_verified_marker "$cache"; then
    rm -f "${cache}/.VERIFIED"
    acps_cleanup_curl_auth
    mm_die "ACPS_VERIFIED_MARKER=FAIL"
  fi
  acps_cleanup_curl_auth
  mm_ok "ACPS_DOWNLOAD=PASS"
  mm_state_set ACPS_PHASE2_DOWNLOADED PASS
}

acps_cleanup_cache() {
  local ver="$1"
  local cache start_ts elapsed
  cache="$(acps_cache_dir "$ver")"
  start_ts="$(date +%s)"
  mm_set_phase "Cleaning Temporary Files"
  mm_info "ACPS_CACHE_CLEANUP_START cache=${cache}"
  rm -rf "$cache"
  # Fallback state path is used only when no run state directory exists.
  if [[ -z "${MM_STATE_DIR:-}" ]]; then
    rm -f "$(acps_disk_preflight_state_file "$ver")" 2>/dev/null || true
  fi
  elapsed=$(( $(date +%s) - start_ts ))
  mm_info "ACPS_CACHE_CLEANUP_COMPLETE elapsed=${elapsed}s"
  mm_info "ACPS_CACHE_CLEANUP=DONE"
}
