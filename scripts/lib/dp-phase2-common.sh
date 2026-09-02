#!/usr/bin/env bash
# Shared helpers for DP Phase 2 offline bundle sync/verify/stage.
# shellcheck shell=bash

DP_PHASE2_VERSION_DEFAULT="6.6.0"
DP_PHASE2_FILE_COUNT=9
DP_PHASE2_REQUIRED_FILES=()

dp2_set_version() {
  local ver="${1:-}"
  [[ -n "$ver" ]] || dp2_die "dp2_set_version requires a version"
  if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    dp2_die "dp2_set_version malformed version=${ver}"
  fi
  DP_PHASE2_VERSION="$ver"
  TARGET_DP_VERSION="$ver"
  PHASE2_ARTIFACT_VERSION="$ver"
  DP_PHASE2_REQUIRED_FILES=(
    aelladeb_py3_common.tar.gz
    aelladeb_py3_common.tar.gz.sha1
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb"
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1"
    bringup_py3_dp_after_os_upgrade.sh
    bringup_py3_dp_after_os_upgrade.sh.sha1
    "images-${ver}.list"
    "images-${ver}.tar"
    "images-${ver}.tar.sha256"
  )
}

# Default to configured/current artifact target until caller overrides.
dp2_set_version "${DP_PHASE2_VERSION:-$DP_PHASE2_VERSION_DEFAULT}"

dp2_log() {
  local level="$1"
  shift
  local msg="$*"
  local line ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y%m%dT%H%M%SZ)"
  line="${ts} [${level}] ${msg}"
  printf '%s\n' "$line"
  if [[ -n "${DP_PHASE2_LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "$DP_PHASE2_LOG_FILE")" 2>/dev/null || true
    printf '%s\n' "$line" >>"$DP_PHASE2_LOG_FILE" 2>/dev/null || true
  fi
}

dp2_info() { dp2_log INFO "$*"; }
dp2_warn() { dp2_log WARN "$*"; }
dp2_error() { dp2_log ERROR "$*"; }
dp2_ok() { dp2_log OK "$*"; }
dp2_die() { dp2_error "$*"; exit 1; }

dp2_require_root() {
  if [[ "${DP_PHASE2_SKIP_ROOT_CHECK:-0}" == "1" ]]; then
    return 0
  fi
  [[ "${EUID}" -eq 0 ]] || dp2_die "ROOT_REQUIRED=FAIL must run as root"
  dp2_ok "ROOT_REQUIRED=PASS"
}

dp2_require_cmds() {
  local c missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    dp2_die "COMMANDS_MISSING=FAIL missing=${missing[*]}"
  fi
  dp2_ok "COMMANDS_REQUIRED=PASS"
}

dp2_free_kib() {
  local path="$1"
  df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}'
}

dp2_require_free_gib() {
  local path="$1"
  local min_gib="$2"
  local free_kib free_gib
  mkdir -p "$path" 2>/dev/null || true
  free_kib="$(dp2_free_kib "$path")"
  [[ -n "$free_kib" && "$free_kib" =~ ^[0-9]+$ ]] || dp2_die "FREE_SPACE_CHECK=FAIL path=${path}"
  free_gib=$((free_kib / 1024 / 1024))
  if [[ "$free_gib" -lt "$min_gib" ]]; then
    dp2_die "FREE_SPACE_CHECK=FAIL free_gib=${free_gib} min_gib=${min_gib} path=${path}"
  fi
  dp2_ok "FREE_SPACE_CHECK=PASS free_gib=${free_gib} min_gib=${min_gib}"
}

dp2_is_probably_html() {
  local f="$1"
  if LC_ALL=C grep -a -m1 -E -q '<(!DOCTYPE[[:space:]]+)?[Hh][Tt][Mm][Ll]' \
      < <(head -c 256 "$f" 2>/dev/null | tr -d '\000'); then
    return 0
  fi
  return 1
}

dp2_reject_bad_payload() {
  local f="$1"
  local label="${2:-$f}"
  [[ -f "$f" ]] || dp2_die "FILE_EXISTS=FAIL file=${label}"
  local sz
  sz="$(stat -c%s "$f" 2>/dev/null || echo 0)"
  if [[ "${sz:-0}" -eq 0 ]]; then
    dp2_die "ZERO_BYTE=FAIL file=${label}"
  fi
  if dp2_is_probably_html "$f"; then
    dp2_die "HTML_PAYLOAD=FAIL file=${label}"
  fi
}

dp2_read_hash_field() {
  local checksum_file="$1"
  awk 'NF {print $1; exit}' "$checksum_file"
}

dp2_validate_sha1_hex() {
  local h="$1"
  [[ "$h" =~ ^[0-9a-fA-F]{40}$ ]]
}

dp2_validate_sha256_hex() {
  local h="$1"
  [[ "$h" =~ ^[0-9a-fA-F]{64}$ ]]
}

dp2_verify_sha1_pair() {
  local data_file="$1"
  local checksum_file="$2"
  local expected actual
  expected="$(dp2_read_hash_field "$checksum_file")"
  dp2_validate_sha1_hex "$expected" || dp2_die "SHA1_FORMAT=FAIL file=$(basename "$checksum_file") hash=${expected}"
  actual="$(sha1sum "$data_file" | awk '{print $1}')"
  if [[ "${expected,,}" != "${actual,,}" ]]; then
    dp2_die "SHA1_VERIFY=FAIL file=$(basename "$data_file") expected=${expected} actual=${actual}"
  fi
  dp2_ok "SHA1_VERIFY=PASS file=$(basename "$data_file")"
}

dp2_verify_sha256_pair() {
  local data_file="$1"
  local checksum_file="$2"
  local expected actual
  expected="$(dp2_read_hash_field "$checksum_file")"
  dp2_validate_sha256_hex "$expected" || dp2_die "SHA256_FORMAT=FAIL file=$(basename "$checksum_file") hash=${expected}"
  actual="$(sha256sum "$data_file" | awk '{print $1}')"
  if [[ "${expected,,}" != "${actual,,}" ]]; then
    dp2_die "SHA256_VERIFY=FAIL file=$(basename "$data_file") expected=${expected} actual=${actual}"
  fi
  dp2_ok "SHA256_VERIFY=PASS file=$(basename "$data_file")"
}

dp2_expected_file_set() {
  printf '%s\n' "${DP_PHASE2_REQUIRED_FILES[@]}" | sort
}

# Fail closed when a directory mixes target-version artifacts (e.g. target
# 6.6.0 with images-6.5.0.tar or aella-uvp-*6.5.0*). Silent fallback is
# forbidden: versionless bringup_py3_dp_after_os_upgrade.sh must never be
# paired with a different UVP/images generation than DP_PHASE2_VERSION.
dp2_reject_mixed_generation() {
  local dir="$1"
  local ver="${DP_PHASE2_VERSION}"
  local f
  [[ -n "$ver" ]] || dp2_die "MIXED_GENERATION=FAIL reason=target_version_unset"
  [[ -d "$dir" ]] || dp2_die "MIXED_GENERATION=FAIL reason=dir_missing dir=${dir}"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
      aella-uvp-*)
        if [[ "$f" != "aella-uvp-2404_${ver}ubuntu1_amd64.deb" \
           && "$f" != "aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1" ]]; then
          dp2_die "MIXED_GENERATION=FAIL file=${f} target=${ver}"
        fi
        ;;
      images-*)
        if [[ "$f" != "images-${ver}.list" \
           && "$f" != "images-${ver}.tar" \
           && "$f" != "images-${ver}.tar.sha256" ]]; then
          dp2_die "MIXED_GENERATION=FAIL file=${f} target=${ver}"
        fi
        ;;
    esac
  done < <(find "$dir" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null)
  dp2_ok "MIXED_GENERATION=PASS target=${ver}"
}

dp2_assert_exact_files_dir() {
  local dir="$1"
  local f
  local missing_flag=0
  local extra_flag=0
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    if [[ ! -f "${dir}/${f}" ]]; then
      dp2_error "REQUIRED_FILE_MISSING=FAIL file=${f}"
      missing_flag=1
    fi
  done
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if ! printf '%s\n' "${DP_PHASE2_REQUIRED_FILES[@]}" | grep -qxF "$f"; then
      dp2_error "EXTRA_FILE=FAIL file=${f}"
      extra_flag=1
    fi
  done < <(find "$dir" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort)
  [[ "$missing_flag" -eq 0 && "$extra_flag" -eq 0 ]] || dp2_die "FILE_SET=FAIL dir=${dir}"
  dp2_reject_mixed_generation "$dir" || return 1
  local count
  count="$(find "$dir" -maxdepth 1 -type f | wc -l | tr -d ' ')"
  [[ "$count" -eq "$DP_PHASE2_FILE_COUNT" ]] || dp2_die "FILE_COUNT=FAIL got=${count} want=${DP_PHASE2_FILE_COUNT}"
  dp2_ok "FILE_SET=PASS count=${count}"
}

dp2_assert_tar_regular_files_only() {
  local bundle="$1"
  # Defense-in-depth before root extraction: tar -tf name checks alone accept
  # symlinks/hardlinks/devices with expected top-level names.
  if ! tar -tvf "$bundle" | awk '
    {
      t = substr($1, 1, 1)
      if (t != "-") {
        bad = 1
      }
    }
    END { exit bad ? 1 : 0 }
  '; then
    dp2_die "TAR_MEMBER_TYPE=FAIL bundle=$(basename "$bundle") (regular files only)"
  fi
}

dp2_assert_safe_tar_list() {
  local bundle="$1"
  local list tmp
  dp2_assert_tar_regular_files_only "$bundle"
  tmp="$(mktemp)"
  tar -tf "$bundle" >"$tmp" || {
    rm -f "$tmp"
    dp2_die "TAR_LIST=FAIL bundle=$(basename "$bundle")"
  }
  local lines
  lines="$(wc -l <"$tmp" | tr -d ' ')"
  if [[ "$lines" -ne "$DP_PHASE2_FILE_COUNT" ]]; then
    rm -f "$tmp"
    dp2_die "TAR_ENTRY_COUNT=FAIL got=${lines} want=${DP_PHASE2_FILE_COUNT}"
  fi
  if grep -E -q '(^/|^\.\./|/\.\./|^\.\.$)' "$tmp"; then
    rm -f "$tmp"
    dp2_die "TAR_PATH_TRAVERSAL=FAIL bundle=$(basename "$bundle")"
  fi
  if grep -E -q '/' "$tmp"; then
    rm -f "$tmp"
    dp2_die "TAR_NESTED_PATH=FAIL bundle=$(basename "$bundle") (top-level names only)"
  fi
  local sorted_tar sorted_want
  sorted_tar="$(sort "$tmp")"
  sorted_want="$(dp2_expected_file_set)"
  if [[ "$sorted_tar" != "$sorted_want" ]]; then
    dp2_error "TAR_NAMES_MISMATCH=FAIL"
    dp2_error "got<<EOF"
    printf '%s\n' "$sorted_tar" >&2 || true
    dp2_error "EOF"
    rm -f "$tmp"
    dp2_die "TAR_NAMES=FAIL"
  fi
  rm -f "$tmp"
  dp2_ok "TAR_LIST=PASS entries=${lines}"
}

dp2_verify_payload_checksums() {
  local files_dir="$1"
  local ver="${DP_PHASE2_VERSION}"
  dp2_verify_sha1_pair \
    "${files_dir}/aelladeb_py3_common.tar.gz" \
    "${files_dir}/aelladeb_py3_common.tar.gz.sha1"
  dp2_verify_sha1_pair \
    "${files_dir}/aella-uvp-2404_${ver}ubuntu1_amd64.deb" \
    "${files_dir}/aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1"
  dp2_verify_sha1_pair \
    "${files_dir}/bringup_py3_dp_after_os_upgrade.sh" \
    "${files_dir}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  dp2_verify_sha256_pair \
    "${files_dir}/images-${ver}.tar" \
    "${files_dir}/images-${ver}.tar.sha256"
}

dp2_check_image_list() {
  local list_file="$1"
  local lines
  [[ -f "$list_file" ]] || dp2_die "IMAGE_LIST=FAIL missing"
  [[ -r "$list_file" ]] || dp2_die "IMAGE_LIST=FAIL unreadable"
  local sz
  sz="$(stat -c%s "$list_file" 2>/dev/null || echo 0)"
  [[ "$sz" -gt 0 ]] || dp2_die "IMAGE_LIST=FAIL zero-byte"
  lines="$(wc -l <"$list_file" | tr -d ' ')"
  if [[ "$lines" -eq 156 ]]; then
    dp2_ok "IMAGE_LIST_COUNT=PASS lines=${lines}"
  else
    dp2_warn "IMAGE_LIST_COUNT=WARNING lines=${lines} expected_hint=156 (not failing solely on line count)"
  fi
  printf '%s\n' "$lines"
}

dp2_write_manifest_sha256() {
  local release_dir="$1"
  local out="${release_dir}/manifest.sha256"
  local tmp
  tmp="$(mktemp "${release_dir}/.manifest.XXXXXX")"
  (
    cd "$release_dir" || exit 1
    find . -type f ! -name 'manifest.sha256' ! -name '.manifest.*' -printf '%P\n' \
      | LC_ALL=C sort \
      | while IFS= read -r rel; do
          sha256sum "$rel"
        done
  ) >"$tmp"
  mv -f "$tmp" "$out"
  chmod 0644 "$out"
  dp2_ok "MANIFEST_SHA256=PASS path=manifest.sha256"
}

dp2_verify_manifest_sha256() {
  local release_dir="$1"
  local manifest="${release_dir}/manifest.sha256"
  [[ -f "$manifest" ]] || dp2_die "MANIFEST_VERIFY=FAIL missing"
  if grep -E -q '(^|/ )manifest\.sha256$' "$manifest" || awk '{print $2}' "$manifest" | grep -qx 'manifest.sha256'; then
    dp2_die "MANIFEST_SELF_REF=FAIL"
  fi
  (
    cd "$release_dir" || exit 1
    while read -r hash path; do
      [[ -n "$hash" && -n "$path" ]] || continue
      [[ -f "$path" ]] || dp2_die "MANIFEST_VERIFY=FAIL missing_path=${path}"
      local actual
      actual="$(sha256sum "$path" | awk '{print $1}')"
      if [[ "${hash,,}" != "${actual,,}" ]]; then
        dp2_die "MANIFEST_VERIFY=FAIL path=${path}"
      fi
    done <manifest.sha256
  )
  dp2_ok "MANIFEST_VERIFY=PASS"
}

dp2_atomic_symlink() {
  local target="$1"
  local linkpath="$2"
  local parent tmp
  parent="$(dirname "$linkpath")"
  mkdir -p "$parent"
  tmp="${linkpath}.tmp.$$"
  ln -sfn "$target" "$tmp"
  mv -Tf "$tmp" "$linkpath"
}

dp2_release_has_secret() {
  # True when release.env (or similar metadata) appears to contain credentials.
  # Host/path fields (SOURCE_HOST, SOURCE_PATH) are allowed; credential keys are not.
  local f="$1"
  [[ -f "$f" ]] || return 1
  if grep -Eiq \
    '^[[:space:]]*(ACPS_PASS|ACPS_PASSWORD|ACPS_TOKEN|PASSWORD|PASSWD|SECRET|TOKEN|PRIVATE_KEY|ACCESS_KEY|CREDENTIAL|CREDENTIALS|AUTHORIZATION|AUTH_TOKEN|COOKIE|API_KEY)[[:space:]]*=' \
    "$f" 2>/dev/null; then
    return 0
  fi
  if grep -Eiq \
    '(^|[^A-Za-z0-9_])(password|passwd|secret|token|private_key|access_key|credential|authorization|cookie)[[:space:]]*[:=]' \
    "$f" 2>/dev/null; then
    return 0
  fi
  return 1
}

dp2_version_root() {
  local root="${DP_PHASE2_ROOT:-/var/spool/apt-mirror/dp-phase2}"
  local ver="${DP_PHASE2_VERSION:-$DP_PHASE2_VERSION_DEFAULT}"
  printf '%s\n' "${root}/${ver}"
}

dp2_current_dir() {
  printf '%s/current\n' "$(dp2_version_root)"
}

dp2_stable_bundle_name() {
  local ver="${DP_PHASE2_VERSION:-$DP_PHASE2_VERSION_DEFAULT}"
  printf 'dp_bundle_%s-current.tar\n' "$ver"
}
