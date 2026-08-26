#!/usr/bin/env bash
# Download, verify, bundle, and atomically publish DP Phase 2 artifacts from ACPS.
# Does NOT run bringup. Does NOT touch selective/current or READY.
#
# Usage:
#   sudo bash scripts/download-dp-phase2.sh [--version X.Y.Z] <sync|verify|status>
set -euo pipefail

# Never enable shell xtrace (would risk leaking credentials).
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/dp-phase2-common.sh
source "${SCRIPT_DIR}/lib/dp-phase2-common.sh"

# ---------------------------------------------------------------------------
# ACPS credentials — loaded from Mirror Manager GUI config or environment.
# Never hardcode username/password in this repository.
# Never enable set -x; never print ACPS_PASS / ACPS_PASSWORD.
# ---------------------------------------------------------------------------
ACPS_HOST="${ACPS_HOST:-acps.stellarcyber.ai}"
ACPS_PATH="${ACPS_PATH:-/provision/aelladeb_py3}"
ACPS_BASE_URL="${ACPS_BASE_URL:-https://${ACPS_HOST}${ACPS_PATH}}"
ACPS_USER="${ACPS_USER:-${ACPS_USERNAME:-}}"
ACPS_PASS="${ACPS_PASS:-${ACPS_PASSWORD:-}}"

_load_acps_credentials_from_gui_config() {
  local cfg="${DP_UPGRADE_MIRROR_CONFIG:-/etc/ubuntu-mirror/dp-upgrade-mirror.conf}"
  # Config is mode 600 (root). Non-root callers (unit tests, operators without sudo)
  # must not abort on Permission denied — fall through to ACPS_* environment.
  if [[ -f "$cfg" && -r "$cfg" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "$cfg"
    set +a
    ACPS_USER="${ACPS_USER:-${ACPS_USERNAME:-}}"
    ACPS_PASS="${ACPS_PASS:-${ACPS_PASSWORD:-}}"
  fi
}
_load_acps_credentials_from_gui_config

DP_PHASE2_VERSION="${DP_PHASE2_VERSION:-${DP_PHASE2_VERSION_DEFAULT}}"
DP_PHASE2_ROOT="${DP_PHASE2_ROOT:-/var/spool/apt-mirror/dp-phase2}"
DP_PHASE2_MIN_FREE_GIB="${DP_PHASE2_MIN_FREE_GIB:-70}"
DP_PHASE2_KEEP_PREVIOUS="${DP_PHASE2_KEEP_PREVIOUS:-true}"
DP_PHASE2_LOCK_FILE="${DP_PHASE2_LOCK_FILE:-/run/ubuntu-mirror-dp-phase2.lock}"
UOM_LOCK_FILE="${UOM_LOCK_FILE:-/run/ubuntu-offline-mirror.lock}"
DP_PHASE2_LOG_FILE="${DP_PHASE2_LOG_FILE:-/var/log/ubuntu-mirror/dp-phase2-sync.log}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-30}"
CURL_MAX_TIME="${CURL_MAX_TIME:-0}"
CURL_RETRIES="${CURL_RETRIES:-5}"
CURL_RETRY_DELAY="${CURL_RETRY_DELAY:-5}"

# Test/fixture hook: when set, download from this HTTP base (no ACPS auth, no -k).
# Production sync must leave this empty.
DP_PHASE2_SOURCE_BASE="${DP_PHASE2_SOURCE_BASE:-}"

LOCK_FD=""
LOCK_HELD=0
STAGING_DIR=""
PUBLISHED=0
CLI_VERSION=""

cleanup() {
  local rc=$?
  if [[ "$LOCK_HELD" -eq 1 && -n "$LOCK_FD" ]]; then
    flock -u "$LOCK_FD" 2>/dev/null || true
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
    LOCK_HELD=0
  fi
  if [[ "$PUBLISHED" -ne 1 && -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    # Leave failed staging for diagnosis unless explicitly requested clean
    if [[ "${DP_PHASE2_CLEAN_FAILED_STAGING:-0}" == "1" ]]; then
      rm -rf "$STAGING_DIR" 2>/dev/null || true
    fi
  fi
  if [[ "$rc" -ne 0 ]]; then
    dp2_error "SYNC_RESULT=FAIL exit=${rc}"
  fi
}
trap cleanup EXIT

acquire_dp2_lock() {
  local new_fd
  mkdir -p "$(dirname "$DP_PHASE2_LOCK_FILE")"
  # Refuse if selective/OS mirror orchestration holds the global UOM lock.
  if [[ -e "$UOM_LOCK_FILE" ]]; then
    local ufd
    exec {ufd}>>"$UOM_LOCK_FILE"
    if ! flock -n "$ufd"; then
      eval "exec ${ufd}>&-" 2>/dev/null || true
      dp2_die "UOM_LOCK_BUSY=FAIL path=${UOM_LOCK_FILE} (OS mirror orchestration active)"
    fi
    flock -u "$ufd" 2>/dev/null || true
    eval "exec ${ufd}>&-" 2>/dev/null || true
  fi

  exec {new_fd}>"$DP_PHASE2_LOCK_FILE"
  if ! flock -n "$new_fd"; then
    eval "exec ${new_fd}>&-" 2>/dev/null || true
    dp2_die "DP_PHASE2_LOCK_BUSY=FAIL path=${DP_PHASE2_LOCK_FILE}"
  fi
  LOCK_FD="$new_fd"
  LOCK_HELD=1
  dp2_ok "DP_PHASE2_LOCK=PASS path=${DP_PHASE2_LOCK_FILE}"
}

download_one() {
  local name="$1"
  local dest_dir="$2"
  local part="${dest_dir}/${name}.part"
  local final="${dest_dir}/${name}"
  local url
  local curl_args=(
    -f
    -L
    --connect-timeout "$CURL_CONNECT_TIMEOUT"
    --retry "$CURL_RETRIES"
    --retry-delay "$CURL_RETRY_DELAY"
    --retry-all-errors
    -o "$part"
  )
  if [[ "$CURL_MAX_TIME" != "0" ]]; then
    curl_args+=(--max-time "$CURL_MAX_TIME")
  fi

  if [[ -n "$DP_PHASE2_SOURCE_BASE" ]]; then
    url="${DP_PHASE2_SOURCE_BASE%/}/${name}"
    # Internal/fixture HTTP — no -k, no ACPS userinfo
    curl_args+=(--continue-at -)
  else
    url="${ACPS_BASE_URL}/${name}"
    [[ -n "$ACPS_USER" && -n "$ACPS_PASS" ]] || \
      dp2_die "ACPS_CREDENTIALS=FAIL set via Mirror Manager Configuration or ACPS_USERNAME/ACPS_PASSWORD env"
    # ACPS only: -k and -u (never put password in URL)
    curl_args+=(-k -u "${ACPS_USER}:${ACPS_PASS}" --continue-at -)
  fi

  dp2_info "DOWNLOAD_START file=${name}"
  # Redirect curl stderr to a scrubbed temp log (avoid credential leakage)
  local err
  err="$(mktemp)"
  if ! curl "${curl_args[@]}" "$url" 2>"$err"; then
    # Scrub userinfo-like patterns before surfacing
    sed -E 's/:[^:@/]+@/:***@/g; s/(-u[[:space:]]+)[^[:space:]]+/\1***/g' "$err" >&2 || true
    rm -f "$err"
    dp2_die "DOWNLOAD=FAIL file=${name}"
  fi
  rm -f "$err"

  dp2_reject_bad_payload "$part" "$name"
  mv -f "$part" "$final"
  dp2_ok "DOWNLOAD=PASS file=${name} size=$(stat -c%s "$final")"
}

create_bundle() {
  local files_dir="$1"
  local bundle_path="$2"
  local tmp="${bundle_path}.part"
  rm -f "$tmp"
  (
    cd "$files_dir"
    tar -cf "$tmp" "${DP_PHASE2_REQUIRED_FILES[@]}"
  )
  dp2_assert_safe_tar_list "$tmp"
  mv -f "$tmp" "$bundle_path"
  dp2_ok "BUNDLE_CREATE=PASS name=$(basename "$bundle_path") size=$(stat -c%s "$bundle_path")"
}

write_release_env() {
  local release_dir="$1"
  local run_id="$2"
  local bundle_name="$3"
  local list_count="$4"
  local created_at
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat >"${release_dir}/release.env" <<EOF
TARGET_DP_VERSION=${DP_PHASE2_VERSION}
PHASE2_ARTIFACT_VERSION=${DP_PHASE2_VERSION}
# Deprecated alias for older consumers; prefer TARGET_DP_VERSION.
DP_PHASE2_VERSION=${DP_PHASE2_VERSION}
CREATED_AT=${created_at}
RUN_ID=${run_id}
FILE_COUNT=${DP_PHASE2_FILE_COUNT}
BUNDLE_NAME=${bundle_name}
STABLE_BUNDLE_NAME=$(dp2_stable_bundle_name)
IMAGE_LIST_COUNT=${list_count}
SOURCE_HOST=${ACPS_HOST}
SOURCE_PATH=${ACPS_PATH}
VERIFICATION_RESULT=PASS
EOF
  if dp2_release_has_secret "${release_dir}/release.env"; then
    dp2_die "RELEASE_ENV_SECRET=FAIL"
  fi
  dp2_ok "RELEASE_ENV=PASS"
}

maybe_skip_identical_current() {
  local files_dir="$1"
  local version_root
  version_root="$(dp2_version_root)"
  local current="${version_root}/current"
  [[ -L "$current" && -d "$current" ]] || return 1
  local cur_files="${current}/files"
  [[ -d "$cur_files" ]] || return 1

  local f
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    [[ -f "${cur_files}/${f}" && -f "${files_dir}/${f}" ]] || return 1
    local a b
    a="$(sha256sum "${cur_files}/${f}" | awk '{print $1}')"
    b="$(sha256sum "${files_dir}/${f}" | awk '{print $1}')"
    [[ "$a" == "$b" ]] || return 1
  done
  return 0
}

publish_atomic() {
  local staging="$1"
  local run_id="$2"
  local version_root
  version_root="$(dp2_version_root)"
  local releases="${version_root}/releases"
  local dest="${releases}/${run_id}"
  local current="${version_root}/current"
  local previous="${version_root}/previous"

  mkdir -p "$releases"
  if [[ -e "$dest" ]]; then
    dp2_die "RELEASE_EXISTS=FAIL path=${dest}"
  fi
  mv -f "$staging" "$dest"
  STAGING_DIR=""
  PUBLISHED=1

  if [[ -L "$current" ]]; then
    local prev_target prev_id
    prev_target="$(readlink -f "$current" 2>/dev/null || true)"
    prev_id="$(basename "$prev_target")"
    if [[ -n "$prev_id" && -d "$prev_target" && "$prev_id" != "$run_id" ]]; then
      if [[ "${DP_PHASE2_KEEP_PREVIOUS}" == "true" ]]; then
        dp2_atomic_symlink "releases/${prev_id}" "$previous"
        dp2_ok "PREVIOUS_PRESERVED=PASS id=${prev_id}"
      fi
    fi
  fi

  dp2_atomic_symlink "releases/${run_id}" "$current"
  dp2_ok "ATOMIC_PUBLISH=PASS current=releases/${run_id}"

  # Prune old releases (keep current + previous)
  local keep_ids=()
  local cur_id prev_id
  cur_id="$(basename "$(readlink -f "$current" 2>/dev/null || true)")"
  [[ -n "$cur_id" ]] && keep_ids+=("$cur_id")
  if [[ -L "$previous" ]]; then
    prev_id="$(basename "$(readlink -f "$previous" 2>/dev/null || true)")"
    [[ -n "$prev_id" ]] && keep_ids+=("$prev_id")
  fi
  local d base
  for d in "${releases}"/*; do
    [[ -d "$d" ]] || continue
    base="$(basename "$d")"
    local keep=0 k
    for k in "${keep_ids[@]:-}"; do
      [[ "$base" == "$k" ]] && keep=1 && break
    done
    if [[ "$keep" -eq 0 ]]; then
      local quarantine="${version_root}/.retired"
      mkdir -p "$quarantine"
      mv -f "$d" "${quarantine}/${base}.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || rm -rf "$d"
      dp2_info "RELEASE_RETIRED=PASS id=${base}"
    fi
  done

  # Clean old staging dirs
  local staging_root="${DP_PHASE2_ROOT}/.staging"
  if [[ -d "$staging_root" ]]; then
    find "$staging_root" -mindepth 1 -maxdepth 1 -type d -mtime +0 -exec rm -rf {} + 2>/dev/null || true
    # Also remove empty/stale same-run leftovers
    find "$staging_root" -mindepth 1 -maxdepth 1 -type d ! -name "${run_id}" -exec rm -rf {} + 2>/dev/null || true
  fi
}

verify_release_dir() {
  local release_dir="$1"
  local files_dir="${release_dir}/files"
  [[ -d "$files_dir" ]] || dp2_die "VERIFY=FAIL missing files/"
  local f
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    dp2_reject_bad_payload "${files_dir}/${f}" "$f"
  done
  dp2_assert_exact_files_dir "$files_dir"
  dp2_verify_payload_checksums "$files_dir"
  dp2_check_image_list "${files_dir}/images-${DP_PHASE2_VERSION}.list" >/dev/null
  local stable
  stable="$(dp2_stable_bundle_name)"
  [[ -f "${release_dir}/${stable}" ]] || dp2_die "VERIFY=FAIL missing ${stable}"
  [[ -f "${release_dir}/${stable}.sha256" ]] || dp2_die "VERIFY=FAIL missing ${stable}.sha256"
  dp2_verify_sha256_pair "${release_dir}/${stable}" "${release_dir}/${stable}.sha256"
  dp2_assert_safe_tar_list "${release_dir}/${stable}"
  [[ -f "${release_dir}/release.env" ]] || dp2_die "VERIFY=FAIL missing release.env"
  dp2_release_has_secret "${release_dir}/release.env" && dp2_die "VERIFY=FAIL secret in release.env"
  local env_target
  env_target="$(grep -E '^(TARGET_DP_VERSION|PHASE2_ARTIFACT_VERSION|DP_PHASE2_VERSION)=' "${release_dir}/release.env" | head -1 | cut -d= -f2-)"
  [[ "$env_target" == "$DP_PHASE2_VERSION" ]] || dp2_die "VERIFY=FAIL release.env version=${env_target} want=${DP_PHASE2_VERSION}"
  dp2_verify_manifest_sha256 "$release_dir"
  dp2_ok "VERIFY_RELEASE=PASS path=${release_dir}"
}

cmd_sync() {
  dp2_require_root
  dp2_require_cmds curl tar sha1sum sha256sum awk flock stat df readlink mv ln find mkdir chmod
  acquire_dp2_lock

  local version_root
  version_root="$(dp2_version_root)"
  mkdir -p "$version_root" "${DP_PHASE2_ROOT}/.staging"
  dp2_require_free_gib "$DP_PHASE2_ROOT" "$DP_PHASE2_MIN_FREE_GIB"

  local run_id
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  STAGING_DIR="${DP_PHASE2_ROOT}/.staging/${run_id}"
  mkdir -p "${STAGING_DIR}/files"
  dp2_info "STAGING_DIR=${STAGING_DIR}"

  local name
  for name in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    download_one "$name" "${STAGING_DIR}/files"
    # Re-check reserve space during large downloads
    dp2_require_free_gib "$DP_PHASE2_ROOT" "$DP_PHASE2_MIN_FREE_GIB"
  done

  dp2_assert_exact_files_dir "${STAGING_DIR}/files"
  dp2_verify_payload_checksums "${STAGING_DIR}/files"
  local list_count
  list_count="$(dp2_check_image_list "${STAGING_DIR}/files/images-${DP_PHASE2_VERSION}.list" | tail -n1)"

  if maybe_skip_identical_current "${STAGING_DIR}/files"; then
    dp2_ok "SKIP_REPUBLISH=PASS reason=identical_current"
    rm -rf "$STAGING_DIR"
    STAGING_DIR=""
    PUBLISHED=1
    dp2_ok "SYNC_RESULT=PASS action=noop"
    return 0
  fi

  local ts_bundle bundle_name stable
  ts_bundle="$(date -u +%Y%m%d_%H%M%S)"
  bundle_name="dp_bundle_${ts_bundle}.tar"
  stable="$(dp2_stable_bundle_name)"
  create_bundle "${STAGING_DIR}/files" "${STAGING_DIR}/${bundle_name}"
  # Hard link stable name to avoid duplicating ~30GiB
  ln -f "${STAGING_DIR}/${bundle_name}" "${STAGING_DIR}/${stable}"
  sha256sum "${STAGING_DIR}/${bundle_name}" | awk '{print $1"  '"${bundle_name}"'"}' >"${STAGING_DIR}/${bundle_name}.sha256"
  sha256sum "${STAGING_DIR}/${stable}" | awk '{print $1"  '"${stable}"'"}' >"${STAGING_DIR}/${stable}.sha256"

  write_release_env "$STAGING_DIR" "$run_id" "$bundle_name" "$list_count"
  dp2_write_manifest_sha256 "$STAGING_DIR"
  verify_release_dir "$STAGING_DIR"

  publish_atomic "$STAGING_DIR" "$run_id"
  verify_release_dir "$(readlink -f "$(dp2_current_dir)")"

  # Separate prerequisite artifact; never mutates the 9-file ACPS bundle.
  if [[ -f "${SCRIPT_DIR}/prepare-phase2-ubuntu-prerequisites.sh" ]]; then
    DP_PHASE2_ROOT="$DP_PHASE2_ROOT" \
      bash "${SCRIPT_DIR}/prepare-phase2-ubuntu-prerequisites.sh" "$DP_PHASE2_VERSION" \
      || dp2_die "PHASE2_PREREQ=FAIL (Download and Prepare cannot continue)"
  else
    dp2_die "PHASE2_PREREQ=FAIL reason=prepare_script_missing"
  fi

  dp2_ok "SYNC_RESULT=PASS run_id=${run_id} bundle=${bundle_name} stable=${stable}"
  printf 'DP_PHASE2_SYNC_RESULT=PASS\n'
  printf 'RUN_ID=%s\n' "$run_id"
  printf 'CURRENT=%s\n' "$(readlink -f "$(dp2_current_dir)")"
  printf 'STABLE_BUNDLE=%s\n' "$stable"
}

cmd_verify() {
  dp2_require_cmds tar sha1sum sha256sum awk stat readlink find
  local version_root current
  version_root="$(dp2_version_root)"
  current="${version_root}/current"
  [[ -L "$current" ]] || dp2_die "CURRENT_SYMLINK=FAIL missing"
  local target
  target="$(readlink -f "$current")"
  [[ -d "$target" ]] || dp2_die "CURRENT_SYMLINK=FAIL dangling"
  verify_release_dir "$target"

  local public_path="${DP_PHASE2_PUBLIC_PATH:-/dp-phase2/${DP_PHASE2_VERSION}/}"
  local expected_alias="${version_root}/current/"
  dp2_ok "NGINX_PATH_EXPECT=PASS public_path=${public_path} alias=${expected_alias}"

  # Permission sanity
  [[ -r "${target}/release.env" ]] || dp2_die "PERMISSION=FAIL release.env unreadable"
  dp2_ok "VERIFY_DP_PHASE2=PASS current=${target}"
}

cmd_status() {
  local version_root current previous
  version_root="$(dp2_version_root)"
  current="${version_root}/current"
  previous="${version_root}/previous"
  printf 'TARGET_DP_VERSION=%s\n' "$DP_PHASE2_VERSION"
  printf 'PHASE2_ARTIFACT_VERSION=%s\n' "$DP_PHASE2_VERSION"
  printf 'DP_PHASE2_VERSION=%s\n' "$DP_PHASE2_VERSION"
  printf 'DP_PHASE2_ROOT=%s\n' "$DP_PHASE2_ROOT"
  printf 'VERSION_ROOT=%s\n' "$version_root"
  if [[ -L "$current" ]]; then
    printf 'CURRENT_TARGET=%s\n' "$(readlink -f "$current" 2>/dev/null || readlink "$current")"
  else
    printf 'CURRENT_TARGET=\n'
  fi
  if [[ -L "$previous" ]]; then
    printf 'PREVIOUS_TARGET=%s\n' "$(readlink -f "$previous" 2>/dev/null || readlink "$previous")"
  else
    printf 'PREVIOUS_TARGET=\n'
  fi
  local stable release_env
  stable="$(dp2_stable_bundle_name)"
  if [[ -L "$current" && -f "${current}/${stable}" ]]; then
    printf 'BUNDLE_NAME=%s\n' "$stable"
    printf 'BUNDLE_SIZE=%s\n' "$(stat -c%s "${current}/${stable}")"
    printf 'BUNDLE_SHA256_FILE=%s\n' "${stable}.sha256"
  fi
  release_env="${current}/release.env"
  if [[ -f "$release_env" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "$release_env"
    set +a
    printf 'CREATED_AT=%s\n' "${CREATED_AT:-}"
    printf 'RUN_ID=%s\n' "${RUN_ID:-}"
    printf 'IMAGE_LIST_COUNT=%s\n' "${IMAGE_LIST_COUNT:-}"
    printf 'VERIFICATION_RESULT=%s\n' "${VERIFICATION_RESULT:-}"
  fi
  printf 'PUBLIC_PATH=%s\n' "${DP_PHASE2_PUBLIC_PATH:-/dp-phase2/${DP_PHASE2_VERSION}/}"
  printf 'PUBLIC_URL=%s\n' "${MIRROR_URL:-}${DP_PHASE2_PUBLIC_PATH:-/dp-phase2/${DP_PHASE2_VERSION}/}"
  if [[ -d "$DP_PHASE2_ROOT" ]]; then
    printf 'DISK_USAGE=%s\n' "$(du -sh "$DP_PHASE2_ROOT" 2>/dev/null | awk '{print $1}')"
    printf 'FREE_GIB=%s\n' "$(( $(dp2_free_kib "$DP_PHASE2_ROOT") / 1024 / 1024 ))"
  fi
  local verify_rc=1
  if [[ -L "$current" ]]; then
    if cmd_verify >/dev/null 2>&1; then
      verify_rc=0
    fi
  fi
  if [[ "$verify_rc" -eq 0 ]]; then
    printf 'FINAL_VERIFY=PASS\n'
  else
    printf 'FINAL_VERIFY=FAIL_OR_PENDING\n'
  fi
}

usage() {
  cat <<EOF
Usage: $0 [--version X.Y.Z] <sync|verify|status>

  --version VER   Target Phase 2 artifact version (default: ${DP_PHASE2_VERSION_DEFAULT})
  sync            Download 9 ACPS files, verify, bundle, atomic publish
  verify          Offline verify of current release
  status          Print current/previous/bundle/disk status
EOF
}

main() {
  local cmd=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        CLI_VERSION="${2:-}"
        [[ -n "$CLI_VERSION" ]] || dp2_die "--version requires a value"
        shift 2
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      sync|verify|status)
        cmd="$1"
        shift
        break
        ;;
      "")
        break
        ;;
      *)
        dp2_die "Unknown argument: $1"
        ;;
    esac
  done
  if [[ -n "$CLI_VERSION" ]]; then
    DP_PHASE2_VERSION="$CLI_VERSION"
  fi
  dp2_set_version "$DP_PHASE2_VERSION"
  case "$cmd" in
    sync) cmd_sync ;;
    verify) cmd_verify ;;
    status) cmd_status ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
