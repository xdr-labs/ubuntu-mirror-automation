#!/usr/bin/env bash
# Stage DP Phase 2 artifacts from the internal Ubuntu mirror onto a DP host.
# Downloads + places files only. NEVER runs bringup or mutates cluster services.
#
# Version model (do not conflate):
#   MIN_SUPPORTED_SOURCE_DP_VERSION  — policy floor (6.2.0)
#   SOURCE_DP_VERSION                — detected/supplied product version on the DP
#   TARGET_DP_VERSION                — selected Phase 2 artifact bundle version
set -euo pipefail
set +x

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Peek --mirror-url before helper sourcing so a complete published unit that is
# missing one helper can fetch that helper and verify it against the trusted
# generation manifest. A sidecar-only / bash -n fetch is never sufficient.
_STAGE_EARLY_MIRROR=""
_stage_early_args=("$@")
for ((_stage_i = 0; _stage_i < ${#_stage_early_args[@]}; _stage_i++)); do
  if [[ "${_stage_early_args[_stage_i]}" == "--mirror-url" ]]; then
    _STAGE_EARLY_MIRROR="${_stage_early_args[_stage_i + 1]:-}"
    break
  fi
done
_STAGE_EARLY_MIRROR="${_STAGE_EARLY_MIRROR%/}"

PHASE2_HELPER_GENERATION_MANIFEST_NAME="phase2-helper-generation.manifest"
PHASE2_HELPER_GENERATION_FILES=(
  stage-dp-phase2.sh
  bringup_py3_dp_lifecycle.sh
  lib/dp-offline-source-product-version.sh
  lib/dp-phase2-operation-progress.sh
  lib/dp-phase2-bringup-lifecycle.sh
  lib/dp-phase2-ubuntu-prerequisites.sh
)

_stage_generation_manifest_hash_for() {
  local man="$1" rel="$2"
  awk -v p="$rel" '$2 == p {print $1; exit}' "$man" 2>/dev/null || true
}

_stage_fetch_helper_verified() {
  local dest="$1"
  local rel="$2"
  local man="${SCRIPT_DIR}/${PHASE2_HELPER_GENERATION_MANIFEST_NAME}"
  local expected tmp url actual
  [[ -f "$man" ]] || return 1
  expected="$(_stage_generation_manifest_hash_for "$man" "$rel")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  [[ -n "$_STAGE_EARLY_MIRROR" ]] || return 1
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp "$(dirname "$dest")/.stage-helper.XXXXXX")"
  url="${_STAGE_EARLY_MIRROR}/client/${rel}"
  if ! curl -fsSL --connect-timeout 30 --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
    rm -f "$tmp"
    printf 'ERROR: PHASE2_HELPER_GENERATION=FAIL reason=download_failed path=%s\n' "$rel" >&2
    return 1
  fi
  actual="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "${actual,,}" != "${expected,,}" ]]; then
    rm -f "$tmp"
    printf 'ERROR: PHASE2_HELPER_GENERATION=FAIL reason=hash_mismatch path=%s\n' "$rel" >&2
    return 1
  fi
  chmod 0755 "$tmp"
  mv -f "$tmp" "$dest"
  return 0
}

_stage_verify_generation_unit() {
  local man="${SCRIPT_DIR}/${PHASE2_HELPER_GENERATION_MANIFEST_NAME}"
  local rel dest expected listed
  if [[ ! -s "$man" ]]; then
    printf 'ERROR: PHASE2_HELPER_GENERATION=FAIL reason=manifest_missing\n' >&2
    printf 'ERROR: this Phase 2 client unit is incomplete; copy the current Menu 7 Phase 2 command\n' >&2
    return 1
  fi
  for rel in "${PHASE2_HELPER_GENERATION_FILES[@]}"; do
    dest="${SCRIPT_DIR}/${rel}"
    expected="$(_stage_generation_manifest_hash_for "$man" "$rel")"
    if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
      printf 'ERROR: PHASE2_HELPER_GENERATION=FAIL reason=required_file_unlisted path=%s\n' "$rel" >&2
      return 1
    fi
    if [[ ! -s "$dest" ]]; then
      if ! _stage_fetch_helper_verified "$dest" "$rel"; then
        printf 'ERROR: PHASE2_HELPER_GENERATION=FAIL reason=helper_missing path=%s\n' "$rel" >&2
        return 1
      fi
    fi
  done
  if ! (cd "$SCRIPT_DIR" && sha256sum -c "$PHASE2_HELPER_GENERATION_MANIFEST_NAME" >/dev/null); then
    printf 'ERROR: PHASE2_HELPER_GENERATION=FAIL reason=hash_mismatch\n' >&2
    return 1
  fi
  printf 'PHASE2_HELPER_GENERATION=PASS\n'
  return 0
}

_STAGE_LIB_DIR="${SCRIPT_DIR}/lib"
mkdir -p "${_STAGE_LIB_DIR}"
_stage_verify_generation_unit || exit 1
# shellcheck source=/dev/null
source "${_STAGE_LIB_DIR}/dp-offline-source-product-version.sh"
# shellcheck source=/dev/null
source "${_STAGE_LIB_DIR}/dp-phase2-operation-progress.sh"

readonly MIN_SUPPORTED_SOURCE_DP_VERSION="6.2.0"
# No built-in mirror address: the address is site-specific and a stale default
# silently points the DP at the wrong (or no) mirror. --mirror-url is required.
DEFAULT_MIRROR_URL=""
MIRROR_URL="$DEFAULT_MIRROR_URL"
ARTIFACT_DIR="/opt/aelladata/aelladeb_py3"
BRINGUP_DIR="/home/aella"
BRINGUP_SCRIPT="${BRINGUP_DIR}/bringup_py3_dp_after_os_upgrade.sh"
SOURCE_PRODUCT_ENV="/opt/aelladata/os-upgrade/offline/source-product.env"
MIN_AELLADATA_GIB=70
MIN_ROOT_GIB=20

TARGET_DP_VERSION=""
PHASE2_ARTIFACT_VERSION=""
EXPECTED_BUNDLE_SHA256=""
SOURCE_DP_VERSION=""
SOURCE_DP_VERSION_RAW=""
SOURCE_DP_VERSION_ORIGIN=""
SOURCE_DP_VERSION_CHECK=""
TARGET_VERSION_COMPATIBILITY=""
OPERATOR_SOURCE_DP_VERSION=""
SAME_VERSION_RECOVERY=0
KEEP_CACHE=0
DIAGNOSE_SOURCE_VERSION=0
PHASE2_STAGE_PHASE=""
BUNDLE_DOWNLOAD_ATTEMPTED="NO"
ARTIFACT_MUTATION_ATTEMPTED="NO"
BRINGUP_INSTALL_ATTEMPTED="NO"
LIFECYCLE_WRAPPER_SRC="${SCRIPT_DIR}/bringup_py3_dp_lifecycle.sh"
VENDOR_BRINGUP_INSTALLED="${BRINGUP_DIR}/bringup_py3_dp_after_os_upgrade.vendor.sh"

AELLA_UID=""
AELLA_PRIMARY_GID=""
AELLA_PRIMARY_GROUP=""
AELLA_OWNERSHIP_CHECK=""

ARTIFACT_CACHE_RESULT=""
ARTIFACT_CHECKSUM_RESULT=""
PHASE2_STAGE_RESULT=""
NTP_BRINGUP_READINESS="NOT_CHECKED"
TIME_READINESS="NOT_CHECKED"
CLOCK_SKEW_SECONDS=""
MAX_CLOCK_SKEW_SECONDS=""
NTP_SOURCE_CLASS="UNKNOWN"
NTP_SELECTED_PEER=""
INTERNAL_NTP_REQUIREMENT=""
BRINGUP_READY="NO"
BRINGUP_EXECUTED="NO"
BRINGUP_VENDOR_COMPAT=""

RUN_ID=""
STAGE_ROOT=""
NEW_ART=""
CACHE_DIR=""
LOCK_FD=""
LOCK_HELD=0
REQUIRED_BUNDLE_FILES=()
ARTIFACT_FILES=()

usage() {
  cat <<EOF
Usage: sudo bash ${SCRIPT_NAME} --target-version X.Y.Z [options]

Stages DP Phase 2 artifact files from the internal mirror.
Does NOT execute bringup_py3_dp_after_os_upgrade.sh.

Required:
  --target-version VER     Phase 2 artifact / bundle target version
  --mirror-url URL         Internal mirror base (e.g. http://192.0.2.10)
  --expected-bundle-sha256 HEX  Pre-trusted dp_bundle SHA256 from bootstrap chain

Options:
  --source-dp-version VER  Explicit source DP product version (operator override)
  --same-version-recovery  Allow source==target when COMPLETED_NOBLE recovery applies
  --keep-cache             Keep verified bundle cache after successful staging
  --diagnose-source-version  Read-only source version diagnosis (no download/mutation)
  -h, --help               Show this help

Source version resolution priority:
  1) ${SOURCE_PRODUCT_ENV}
  2) immutable capture evidence (same path)
  3) structured Phase 1 log evidence (COMPLETED_NOBLE recovery)
  4) authoritative keys in /opt/aelladata/release-image.yml
  5) --source-dp-version (origin=operator-argument)
  6) fail closed with source-specific diagnostics (no FAIL_UNKNOWN)
EOF
}

log() { printf '%s\n' "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  PHASE2_STAGE_RESULT="${PHASE2_STAGE_RESULT:-FAIL}"
  exit 1
}

cleanup() {
  local rc=$?
  if [[ "$LOCK_HELD" -eq 1 && -n "$LOCK_FD" ]]; then
    flock -u "$LOCK_FD" 2>/dev/null || true
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
    LOCK_HELD=0
  fi
  if [[ -n "$STAGE_ROOT" && -d "$STAGE_ROOT" ]]; then
    rm -rf "$STAGE_ROOT" 2>/dev/null || true
    STAGE_ROOT=""
  fi
  if [[ -n "$NEW_ART" && -d "$NEW_ART" ]]; then
    rm -rf "$NEW_ART" 2>/dev/null || true
    NEW_ART=""
  fi
  return "$rc"
}
if [[ "${DP_PHASE2_STAGE_LIB_ONLY:-0}" != "1" ]]; then
  trap cleanup EXIT
fi

normalize_dp_version() {
  local raw="${1-}"
  local base
  if [[ -z "$raw" || "$raw" == "null" || "$raw" == "unknown" || "$raw" == "UNKNOWN" ]]; then
    return 1
  fi
  raw="$(printf '%s' "$raw" | sed -E 's/^[^0-9]*//')"
  if [[ "$raw" =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    base="${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^([0-9]+\.[0-9]+)([.-]|$) ]]; then
    base="${BASH_REMATCH[1]}.0"
  else
    return 1
  fi
  printf '%s' "$base"
  return 0
}

compare_dp_versions() {
  # Prints: lt | eq | gt | unknown. Uses dpkg when available.
  local a="${1-}" b="${2-}"
  if [[ -z "$a" || -z "$b" ]]; then
    printf 'unknown'
    return 1
  fi
  if ! [[ "$a" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$b" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'unknown'
    return 1
  fi
  if command -v dpkg >/dev/null 2>&1; then
    if dpkg --compare-versions "$a" eq "$b"; then printf 'eq'; return 0; fi
    if dpkg --compare-versions "$a" lt "$b"; then printf 'lt'; return 0; fi
    if dpkg --compare-versions "$a" gt "$b"; then printf 'gt'; return 0; fi
    printf 'unknown'
    return 1
  fi
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$a"
  IFS=. read -r b1 b2 b3 <<<"$b"
  if (( a1 < b1 )); then printf 'lt'; return 0; fi
  if (( a1 > b1 )); then printf 'gt'; return 0; fi
  if (( a2 < b2 )); then printf 'lt'; return 0; fi
  if (( a2 > b2 )); then printf 'gt'; return 0; fi
  if (( a3 < b3 )); then printf 'lt'; return 0; fi
  if (( a3 > b3 )); then printf 'gt'; return 0; fi
  printf 'eq'
  return 0
}

set_target_bundle_files() {
  local ver="$1"
  REQUIRED_BUNDLE_FILES=(
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
  ARTIFACT_FILES=(
    aelladeb_py3_common.tar.gz
    aelladeb_py3_common.tar.gz.sha1
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb"
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1"
    "images-${ver}.list"
    "images-${ver}.tar"
    "images-${ver}.tar.sha256"
  )
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target-version|--target-dp-version)
        TARGET_DP_VERSION="${2:-}"
        [[ -n "$TARGET_DP_VERSION" ]] || die "--target-version requires a value"
        shift 2
        ;;
      --source-dp-version)
        OPERATOR_SOURCE_DP_VERSION="${2:-}"
        [[ -n "$OPERATOR_SOURCE_DP_VERSION" ]] || die "--source-dp-version requires a value"
        shift 2
        ;;
      --mirror-url)
        MIRROR_URL="${2:-}"
        [[ -n "$MIRROR_URL" ]] || die "--mirror-url requires a value"
        shift 2
        ;;
      --expected-bundle-sha256)
        EXPECTED_BUNDLE_SHA256="${2:-}"
        [[ -n "$EXPECTED_BUNDLE_SHA256" ]] || die "--expected-bundle-sha256 requires a value"
        shift 2
        ;;
      --same-version-recovery)
        SAME_VERSION_RECOVERY=1
        shift
        ;;
      --keep-cache)
        KEEP_CACHE=1
        shift
        ;;
      --diagnose-source-version)
        DIAGNOSE_SOURCE_VERSION=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
  MIRROR_URL="${MIRROR_URL%/}"
  # diagnose-source-version may omit --mirror-url (read-only, no download)
  if [[ "$DIAGNOSE_SOURCE_VERSION" -eq 0 ]]; then
    [[ -n "$MIRROR_URL" ]] || die "--mirror-url is required (internal mirror base, e.g. http://192.0.2.10)"
  fi
  if [[ -n "$MIRROR_URL" ]]; then
    if [[ "$MIRROR_URL" == *acps.stellarcyber.ai* ]] || [[ "$MIRROR_URL" == *stellarcyber.ai* ]]; then
      die "Refusing ACPS/external stellarcyber URL; use internal mirror only"
    fi
  fi
  if [[ "$DIAGNOSE_SOURCE_VERSION" -eq 0 ]]; then
    [[ -n "$TARGET_DP_VERSION" ]] || die "--target-version is required"
  elif [[ -z "$TARGET_DP_VERSION" ]]; then
    TARGET_DP_VERSION="0.0.0"
  fi
  local norm
  norm="$(normalize_dp_version "$TARGET_DP_VERSION")" || die "malformed --target-version: ${TARGET_DP_VERSION}"
  TARGET_DP_VERSION="$norm"
  readonly TARGET_DP_VERSION
  PHASE2_ARTIFACT_VERSION="$TARGET_DP_VERSION"
  readonly PHASE2_ARTIFACT_VERSION
  if [[ "$DIAGNOSE_SOURCE_VERSION" -eq 0 ]]; then
    set_target_bundle_files "$TARGET_DP_VERSION"
  fi
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "must run as root"
}

# Read OS identity without sourcing /etc/os-release (avoids VERSION shadowing).
os_release_field() {
  local key="$1"
  local f="/etc/os-release"
  [[ -r "$f" ]] || { printf ''; return 0; }
  grep -E "^${key}=" "$f" | head -1 | cut -d= -f2- | tr -d '"'
}

require_noble() {
  [[ -f /etc/os-release ]] || die "/etc/os-release missing"
  local id vid codename
  id="$(os_release_field ID)"
  vid="$(os_release_field VERSION_ID)"
  codename="$(os_release_field VERSION_CODENAME)"
  [[ "$id" == "ubuntu" ]] || die "Ubuntu required"
  [[ "$vid" == "24.04" ]] || die "Ubuntu 24.04 required (got ${vid:-unknown})"
  [[ "$codename" == "noble" ]] || die "VERSION_CODENAME=noble required (got ${codename:-unknown})"
}

free_gib() {
  local path="$1"
  local kib
  kib="$(df -Pk "$path" | awk 'NR==2 {print $4}')"
  echo $((kib / 1024 / 1024))
}

require_space() {
  [[ -d /opt/aelladata ]] || die "/opt/aelladata missing"
  local aella_free root_free
  aella_free="$(free_gib /opt/aelladata)"
  root_free="$(free_gib /)"
  [[ "$aella_free" -ge "$MIN_AELLADATA_GIB" ]] || die "/opt/aelladata free ${aella_free}GiB < ${MIN_AELLADATA_GIB}GiB"
  [[ "$root_free" -ge "$MIN_ROOT_GIB" ]] || die "/ free ${root_free}GiB < ${MIN_ROOT_GIB}GiB"
}

resolve_aella_ownership() {
  id -u aella >/dev/null 2>&1 || die "aella account missing"
  local shell
  shell="$(getent passwd aella | awk -F: '{print $7}')"
  [[ "$shell" == "/bin/bash" ]] || die "aella shell must be /bin/bash (got ${shell})"

  AELLA_UID="$(id -u aella)"
  AELLA_PRIMARY_GID="$(id -g aella)"
  AELLA_PRIMARY_GROUP="$(id -gn aella)"
  [[ "$AELLA_UID" =~ ^[0-9]+$ ]] || die "AELLA_UID not numeric"
  [[ "$AELLA_PRIMARY_GID" =~ ^[0-9]+$ ]] || die "AELLA_PRIMARY_GID not numeric"
  [[ -n "$AELLA_PRIMARY_GROUP" ]] || die "AELLA_PRIMARY_GROUP empty"
  getent group "$AELLA_PRIMARY_GID" >/dev/null 2>&1 \
    || die "primary GID ${AELLA_PRIMARY_GID} not resolvable via getent group"
  AELLA_OWNERSHIP_CHECK="PASS"
  log "AELLA_UID=${AELLA_UID}"
  log "AELLA_PRIMARY_GID=${AELLA_PRIMARY_GID}"
  log "AELLA_PRIMARY_GROUP=${AELLA_PRIMARY_GROUP}"
  log "AELLA_OWNERSHIP_CHECK=${AELLA_OWNERSHIP_CHECK}"
}

read_os_upgrade_state() {
  local state=""
  local candidates=(
    /opt/aelladata/os-upgrade/offline/state
    /opt/aelladata/os-upgrade/state
    /var/lib/dp-os-upgrade/state
    /opt/aelladata/os-upgrade/CURRENT_STATE
  )
  local f
  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then
      state="$(tr -d '\r\n' <"$f" || true)"
      break
    fi
  done
  printf '%s' "$state"
}

require_os_upgrade_state() {
  local state
  state="$(read_os_upgrade_state)"
  if [[ -n "$state" && "$state" != "COMPLETED_NOBLE" ]]; then
    die "OS upgrade state is '${state}', require COMPLETED_NOBLE or absent"
  fi
}

phase1_product_validation_is_not_run() {
  local logf evidence
  for logf in /var/log/aella/offline_os_upgrade.log /opt/aelladata/os-upgrade/offline/*.log; do
    [[ -f "$logf" ]] || continue
    if grep -Eq 'product_validation_result=NOT_RUN_PHASE1|PRODUCT_VALIDATION=NOT_RUN_PHASE1|JAMMY_PRODUCT_VALIDATION=NOT_RUN_PHASE1' "$logf" 2>/dev/null; then
      return 0
    fi
  done
  # Marker files written by Phase 1 finalize path
  for evidence in \
    /opt/aelladata/os-upgrade/offline/product_validation_result \
    /opt/aelladata/os-upgrade/offline/PRODUCT_VALIDATION
  do
    if [[ -f "$evidence" ]] && grep -Eq 'NOT_RUN_PHASE1' "$evidence" 2>/dev/null; then
      return 0
    fi
  done
  # COMPLETED_NOBLE with no prior bringup is the common recovery posture
  local state
  state="$(read_os_upgrade_state)"
  [[ "$state" == "COMPLETED_NOBLE" ]] || return 1
  [[ ! -x "$BRINGUP_SCRIPT" ]] || return 1
  return 0
}

bringup_already_executed() {
  if [[ -f /opt/aelladata/os-upgrade/offline/BRINGUP_EXECUTED ]]; then
    return 0
  fi
  if grep -Eq 'BRINGUP_EXECUTED=YES|bringup_py3_dp_after_os_upgrade' /var/log/aella/offline_os_upgrade.log 2>/dev/null; then
    # log mention alone is weak; require explicit YES marker elsewhere
    :
  fi
  return 1
}

require_dpkg_apt_clean() {
  local audit
  audit="$(dpkg --audit 2>&1 || true)"
  [[ -z "${audit// }" ]] || die "dpkg --audit reports issues"
  apt-get check >/dev/null || die "apt-get check failed"
}

# Detect real upgrade/package-manager processes without matching ps/awk/grep or this helper.
require_no_active_os_upgrade() {
  local hits
  hits="$(ps -eo pid=,ppid=,comm=,args= | awk -v self_pid="$$" -v self_ppid="$PPID" '
    $1 == self_pid { next }
    $1 == self_ppid { next }
    $3 == "ps" || $3 == "awk" || $3 == "grep" || $3 == "sed" { next }
    # Skip this helper and its wrappers (comm is usually bash)
    $0 ~ /stage-dp-phase2/ { next }
    $0 ~ /test_dp_phase2/ { next }

    $0 ~ /[d]p-offline-upgrade-/ { print; next }
    $0 ~ /[d]p-os-upgrade-runner/ { print; next }
    $0 ~ /[u]buntu-release-upgrader/ { print; next }
    $0 ~ /[d]o-release-upgrade/ { print; next }

    $3 == "apt-get" || $4 ~ /(^|[[:space:]/])apt-get([:]|$)/ {
      # Ignore short-lived read-only checks that may still appear in the snapshot
      if ($0 ~ /apt-get[[:space:]]+check/) next
      print
      next
    }
    $3 == "dpkg" || $4 ~ /(^|[[:space:]/])dpkg([:]|$)/ {
      if ($0 ~ /dpkg[[:space:]]+--audit/) next
      print
      next
    }
  ' || true)"

  if [[ -n "${hits// }" ]]; then
    printf '%s\n' "$hits" >&2
    die "active OS upgrade process detected"
  fi
}

is_probably_html() {
  local f="$1"
  LC_ALL=C grep -a -m1 -E -q '<(!DOCTYPE[[:space:]]+)?[Hh][Tt][Mm][Ll]' \
    < <(head -c 256 "$f" 2>/dev/null | tr -d '\000')
}

read_hash() { awk 'NF {print $1; exit}' "$1"; }

verify_sha1_pair() {
  local data="$1" sum="$2"
  local expected actual
  expected="$(read_hash "$sum")"
  [[ "$expected" =~ ^[0-9a-fA-F]{40}$ ]] || die "bad sha1 format in $(basename "$sum")"
  if ! dp2_run_with_heartbeat "phase2_verify_sha1_$(basename "$data")" "$data" -- \
      bash -c "actual=\$(sha1sum \"$data\" | awk '{print \$1}'); printf '%s' \"\$actual\" >\"${data}.sha1.actual\""
  then
    die "sha1 computation failed for $(basename "$data")"
  fi
  actual="$(cat "${data}.sha1.actual")"
  rm -f "${data}.sha1.actual"
  [[ "${expected,,}" == "${actual,,}" ]] || die "sha1 mismatch for $(basename "$data")"
}

verify_sha256_pair() {
  local data="$1" sum="$2"
  local expected actual fsize
  expected="$(read_hash "$sum")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "bad sha256 format in $(basename "$sum")"
  fsize="$(stat -c%s "$data" 2>/dev/null || echo 0)"
  log "SHA256_FILE_SIZE_BYTES=${fsize} file=$(basename "$data")"
  if ! dp2_run_with_heartbeat "phase2_verify_sha256_$(basename "$data")" "$data" -- \
      bash -c "actual=\$(sha256sum \"$data\" | awk '{print \$1}'); printf '%s' \"\$actual\" >\"${data}.sha256.actual\""
  then
    die "sha256 computation failed for $(basename "$data")"
  fi
  actual="$(cat "${data}.sha256.actual")"
  rm -f "${data}.sha256.actual"
  [[ "${expected,,}" == "${actual,,}" ]] || die "sha256 mismatch for $(basename "$data")"
}

assert_tar_regular_files_only() {
  local bundle="$1"
  if ! tar -tvf "$bundle" | awk '
    {
      t = substr($1, 1, 1)
      if (t != "-") {
        bad = 1
      }
    }
    END { exit bad ? 1 : 0 }
  '; then
    die "bundle tar member type validation failed (regular files only)"
  fi
}

assert_safe_tar_list() {
  local bundle="$1"
  PHASE2_STAGE_PHASE="VALIDATE_TAR_CONTENTS"
  log "PHASE2_STAGE_PHASE=${PHASE2_STAGE_PHASE}"
  local tmp lines
  if ! dp2_run_with_heartbeat phase2_tar_member_type_validation "$bundle" -- \
      assert_tar_regular_files_only "$bundle"
  then
    die "bundle tar member type validation failed (regular files only)"
  fi
  tmp="$(mktemp)"
  if ! dp2_run_with_heartbeat phase2_tar_list_validation "$bundle" -- \
      bash -c "tar -tf \"$bundle\" >\"$tmp\""
  then
    rm -f "$tmp"
    die "tar list validation failed"
  fi
  lines="$(wc -l <"$tmp" | tr -d ' ')"
  [[ "$lines" -eq 9 ]] || { rm -f "$tmp"; die "bundle entry count ${lines} != 9"; }
  if grep -E -q '(^/|^\.\./|/\.\./|/)' "$tmp"; then
    rm -f "$tmp"
    die "unsafe paths in bundle tar"
  fi
  local want got
  want="$(printf '%s\n' "${REQUIRED_BUNDLE_FILES[@]}" | sort)"
  got="$(sort "$tmp")"
  rm -f "$tmp"
  [[ "$want" == "$got" ]] || die "bundle file list mismatch"
}

artifact_manifest_hash() {
  local dir="$1"
  local f
  (
    cd "$dir"
    for f in "${ARTIFACT_FILES[@]}"; do
      [[ -f "$f" ]] || exit 1
      sha256sum "$f"
    done
  ) | sha256sum | awk '{print $1}'
}

is_authoritative_release_image_key() {
  spv_is_authoritative_release_image_key "${1:-}"
}

detect_source_from_release_image() {
  if spv_detect_from_release_image "/opt/aelladata/release-image.yml"; then
    SOURCE_DP_VERSION_RAW="$SPV_RELEASE_SELECTED_VERSION"
    SOURCE_DP_VERSION="$SPV_RELEASE_SELECTED_VERSION"
    SOURCE_DP_VERSION_ORIGIN="release-image.yml"
    return 0
  fi
  return 1
}

detect_source_from_persisted_env() {
  if spv_read_source_product_env "$SOURCE_PRODUCT_ENV"; then
    SOURCE_DP_VERSION_RAW="$SPV_SOURCE_DP_VERSION_RAW"
    SOURCE_DP_VERSION="$SPV_SOURCE_DP_VERSION"
    SOURCE_DP_VERSION_ORIGIN="$SPV_SOURCE_DP_VERSION_ORIGIN"
    return 0
  fi
  return 1
}

emit_source_resolution_failure() {
  spv_emit_diagnostics
  log "SOURCE_DP_VERSION_RESOLUTION=FAIL"
  log "SOURCE_DP_VERSION_FAILURE_REASON=${SPV_SOURCE_DP_VERSION_FAILURE_REASON}"
  log "SOURCE_DP_VERSION_REMEDIATION=${SPV_SOURCE_DP_VERSION_REMEDIATION}"
  log "BUNDLE_DOWNLOAD_ATTEMPTED=${BUNDLE_DOWNLOAD_ATTEMPTED}"
  log "ARTIFACT_MUTATION_ATTEMPTED=${ARTIFACT_MUTATION_ATTEMPTED}"
  log "BRINGUP_INSTALL_ATTEMPTED=${BRINGUP_INSTALL_ATTEMPTED}"
}

resolve_source_dp_version() {
  local allow_write=1
  local run_id
  SOURCE_DP_VERSION=""
  SOURCE_DP_VERSION_RAW=""
  SOURCE_DP_VERSION_ORIGIN=""
  SOURCE_DP_VERSION_CHECK=""
  PHASE2_STAGE_PHASE="RESOLVE_SOURCE_VERSION"
  log "PHASE2_STAGE_PHASE=${PHASE2_STAGE_PHASE}"
  run_id="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"

  if ! spv_resolve_source_dp_version \
      "$SOURCE_PRODUCT_ENV" \
      "/var/log/aella/offline_os_upgrade.log" \
      "/opt/aelladata/release-image.yml" \
      "$OPERATOR_SOURCE_DP_VERSION" \
      "$allow_write" \
      "$run_id" \
      1; then
    SOURCE_DP_VERSION_CHECK="FAIL"
    SOURCE_DP_VERSION="${SPV_SOURCE_DP_VERSION:-}"
    SOURCE_DP_VERSION_RAW="${SPV_SOURCE_DP_VERSION_RAW:-}"
    SOURCE_DP_VERSION_ORIGIN="${SPV_SOURCE_DP_VERSION_ORIGIN:-}"
    emit_source_resolution_failure
    die "SOURCE_DP_VERSION_RESOLUTION=FAIL reason=${SPV_SOURCE_DP_VERSION_FAILURE_REASON}"
  fi

  SOURCE_DP_VERSION="$SPV_SOURCE_DP_VERSION"
  SOURCE_DP_VERSION_RAW="$SPV_SOURCE_DP_VERSION_RAW"
  SOURCE_DP_VERSION_ORIGIN="$SPV_SOURCE_DP_VERSION_ORIGIN"
  SOURCE_DP_VERSION_CHECK="PASS"
  spv_emit_diagnostics
  log "SOURCE_DP_VERSION_ORIGIN=${SOURCE_DP_VERSION_ORIGIN}"
  log "SOURCE_DP_VERSION=${SOURCE_DP_VERSION}"
  log "SOURCE_DP_VERSION_RESOLUTION=PASS"
  return 0
}

diagnose_source_version_main() {
  PHASE2_STAGE_PHASE="RESOLVE_SOURCE_VERSION"
  log "PHASE2_STAGE_PHASE=${PHASE2_STAGE_PHASE}"
  log "DIAGNOSE_SOURCE_VERSION=YES"
  log "DIAGNOSE_READ_ONLY=YES"
  local run_id
  run_id="diagnose-$(date -u +%Y%m%dT%H%M%SZ)"
  if spv_resolve_source_dp_version \
      "$SOURCE_PRODUCT_ENV" \
      "/var/log/aella/offline_os_upgrade.log" \
      "/opt/aelladata/release-image.yml" \
      "$OPERATOR_SOURCE_DP_VERSION" \
      0 \
      "$run_id" \
      1; then
    SOURCE_DP_VERSION="$SPV_SOURCE_DP_VERSION"
    SOURCE_DP_VERSION_RAW="$SPV_SOURCE_DP_VERSION_RAW"
    SOURCE_DP_VERSION_ORIGIN="$SPV_SOURCE_DP_VERSION_ORIGIN"
    SOURCE_DP_VERSION_CHECK="PASS"
    spv_emit_diagnostics
    log "SOURCE_DP_VERSION_RESOLUTION=PASS"
    log "BUNDLE_DOWNLOAD_ATTEMPTED=NO"
    log "ARTIFACT_MUTATION_ATTEMPTED=NO"
    log "BRINGUP_INSTALL_ATTEMPTED=NO"
    return 0
  fi
  SOURCE_DP_VERSION_CHECK="FAIL"
  emit_source_resolution_failure
  return 1
}

evaluate_version_compatibility() {
  local cmp_min cmp_tgt state
  if [[ "$SOURCE_DP_VERSION_CHECK" != "PASS" || -z "$SOURCE_DP_VERSION" ]]; then
    SOURCE_DP_VERSION_CHECK="FAIL"
    die "SOURCE_DP_VERSION_RESOLUTION=FAIL (compatibility precondition)"
  fi
  cmp_min="$(compare_dp_versions "$SOURCE_DP_VERSION" "$MIN_SUPPORTED_SOURCE_DP_VERSION")"
  if [[ "$cmp_min" == "lt" ]]; then
    SOURCE_DP_VERSION_CHECK="FAIL_UNSUPPORTED"
    die "SOURCE_DP_VERSION_CHECK=FAIL_UNSUPPORTED source=${SOURCE_DP_VERSION} min=${MIN_SUPPORTED_SOURCE_DP_VERSION}"
  fi
  if [[ "$cmp_min" == "unknown" ]]; then
    SOURCE_DP_VERSION_CHECK="FAIL"
    die "SOURCE_DP_VERSION_RESOLUTION=FAIL reason=VERSION_COMPARE_FAILED"
  fi
  SOURCE_DP_VERSION_CHECK="PASS"

  cmp_tgt="$(compare_dp_versions "$SOURCE_DP_VERSION" "$TARGET_DP_VERSION")"
  case "$cmp_tgt" in
    lt)
      TARGET_VERSION_COMPATIBILITY="PASS_UPGRADE"
      ;;
    gt)
      TARGET_VERSION_COMPATIBILITY="FAIL_DOWNGRADE"
      die "TARGET_VERSION_COMPATIBILITY=FAIL_DOWNGRADE source=${SOURCE_DP_VERSION} target=${TARGET_DP_VERSION}"
      ;;
    eq)
      state="$(read_os_upgrade_state)"
      if [[ "$state" == "COMPLETED_NOBLE" ]] && \
         phase1_product_validation_is_not_run && \
         ! bringup_already_executed && \
         [[ "$SAME_VERSION_RECOVERY" -eq 1 ]]; then
        TARGET_VERSION_COMPATIBILITY="SAME_VERSION_RECOVERY_REQUIRED"
        log "TARGET_VERSION_COMPATIBILITY=SAME_VERSION_RECOVERY_REQUIRED"
        log "PREREQUISITE: powered-off VM snapshot/backup confirmed by operator"
      elif [[ "$state" == "COMPLETED_NOBLE" ]] && \
            phase1_product_validation_is_not_run && \
            ! bringup_already_executed && \
            [[ "$SAME_VERSION_RECOVERY" -eq 0 ]]; then
        TARGET_VERSION_COMPATIBILITY="SAME_VERSION_RECOVERY_REQUIRED"
        die "TARGET_VERSION_COMPATIBILITY=SAME_VERSION_RECOVERY_REQUIRED (pass --same-version-recovery after snapshot)"
      elif [[ "$state" == "COMPLETED_NOBLE" ]]; then
        TARGET_VERSION_COMPATIBILITY="SAME_VERSION_RECOVERY_BLOCKED"
        die "TARGET_VERSION_COMPATIBILITY=SAME_VERSION_RECOVERY_BLOCKED
Safe same-version recovery could not be confirmed.

Do not run destructive bringup until the DP recovery state is verified."
      else
        TARGET_VERSION_COMPATIBILITY="ALREADY_AT_TARGET"
        die "TARGET_VERSION_COMPATIBILITY=ALREADY_AT_TARGET
DP ${TARGET_DP_VERSION} is already healthy on Ubuntu 24.04.
No Phase 2 recovery is required."
      fi
      ;;
    *)
      die "TARGET_VERSION_COMPATIBILITY=FAIL source/target compare unknown"
      ;;
  esac
  log "SOURCE_DP_VERSION_CHECK=${SOURCE_DP_VERSION_CHECK}"
  log "TARGET_VERSION_COMPATIBILITY=${TARGET_VERSION_COMPATIBILITY}"
}

load_release_env_from_mirror() {
  PHASE2_STAGE_PHASE="VERIFY_RELEASE_ENV"
  log "PHASE2_STAGE_PHASE=${PHASE2_STAGE_PHASE}"
  local url="${MIRROR_URL}/dp-phase2/${TARGET_DP_VERSION}/release.env"
  local tmp
  tmp="$(mktemp)"
  if ! curl -fsS --connect-timeout 15 --max-time 60 -o "$tmp" "$url"; then
    rm -f "$tmp"
    die "failed to fetch release.env from ${url}"
  fi
  is_probably_html "$tmp" && { rm -f "$tmp"; die "release.env looks like HTML"; }
  local rel_target rel_art rel_ver stable
  rel_target="$(grep -E '^(TARGET_DP_VERSION|PHASE2_ARTIFACT_VERSION|DP_PHASE2_VERSION)=' "$tmp" | head -1 | cut -d= -f2- | tr -d '"')"
  # Prefer explicit fields when present
  if grep -qE '^TARGET_DP_VERSION=' "$tmp"; then
    rel_target="$(grep -E '^TARGET_DP_VERSION=' "$tmp" | head -1 | cut -d= -f2- | tr -d '"')"
  elif grep -qE '^PHASE2_ARTIFACT_VERSION=' "$tmp"; then
    rel_target="$(grep -E '^PHASE2_ARTIFACT_VERSION=' "$tmp" | head -1 | cut -d= -f2- | tr -d '"')"
  elif grep -qE '^DP_PHASE2_VERSION=' "$tmp"; then
    rel_target="$(grep -E '^DP_PHASE2_VERSION=' "$tmp" | head -1 | cut -d= -f2- | tr -d '"')"
  fi
  rel_art="$(grep -E '^PHASE2_ARTIFACT_VERSION=' "$tmp" | head -1 | cut -d= -f2- | tr -d '"' || true)"
  rel_ver="$(normalize_dp_version "${rel_target:-}")" || {
    rm -f "$tmp"
    die "release.env target version malformed: ${rel_target}"
  }
  [[ "$rel_ver" == "$TARGET_DP_VERSION" ]] || {
    rm -f "$tmp"
    die "release.env target ${rel_ver} != requested ${TARGET_DP_VERSION}"
  }
  if [[ -n "$rel_art" ]]; then
    rel_art="$(normalize_dp_version "$rel_art")" || true
    [[ -z "$rel_art" || "$rel_art" == "$TARGET_DP_VERSION" ]] \
      || { rm -f "$tmp"; die "PHASE2_ARTIFACT_VERSION mismatch"; }
  fi
  stable="$(grep -E '^STABLE_BUNDLE_NAME=' "$tmp" | head -1 | cut -d= -f2- | tr -d '"' || true)"
  if [[ -n "$stable" && "$stable" != "dp_bundle_${TARGET_DP_VERSION}-current.tar" ]]; then
    rm -f "$tmp"
    die "STABLE_BUNDLE_NAME mismatch: ${stable}"
  fi
  rm -f "$tmp"
  log "RELEASE_ENV_CROSSCHECK=PASS target=${TARGET_DP_VERSION}"
}

acquire_stage_lock() {
  local lockfile="${CACHE_DIR}/.stage.lock"
  mkdir -p "$CACHE_DIR"
  local new_fd
  exec {new_fd}>"$lockfile"
  if ! flock -n "$new_fd"; then
    eval "exec ${new_fd}>&-" 2>/dev/null || true
    die "concurrent Phase 2 staging lock busy: ${lockfile}"
  fi
  LOCK_FD="$new_fd"
  LOCK_HELD=1
  log "STAGE_LOCK=PASS path=${lockfile}"
}

ensure_verified_bundle() {
  local bundle_url sha_url
  local cache_tar="${CACHE_DIR}/bundle.tar"
  local cache_part="${CACHE_DIR}/bundle.tar.part"
  local cache_sha="${CACHE_DIR}/bundle.tar.sha256"
  local verified_marker="${CACHE_DIR}/VERIFIED"
  local bytes_total="UNKNOWN" mode expected sidecar_hash
  bundle_url="${MIRROR_URL}/dp-phase2/${TARGET_DP_VERSION}/dp_bundle_${TARGET_DP_VERSION}-current.tar"
  sha_url="${bundle_url}.sha256"

  [[ -n "$EXPECTED_BUNDLE_SHA256" ]] || die "PRETRUSTED_BUNDLE_HASH=MISSING"
  [[ "$EXPECTED_BUNDLE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || die "PRETRUSTED_BUNDLE_HASH=INVALID"
  expected="${EXPECTED_BUNDLE_SHA256,,}"

  PHASE2_STAGE_PHASE="DOWNLOAD_BUNDLE"
  log "PHASE2_STAGE_PHASE=${PHASE2_STAGE_PHASE}"
  log "DOWNLOAD_CHECKSUM url=$(dp2_progress_sanitize_target "$sha_url")"
  BUNDLE_DOWNLOAD_ATTEMPTED="YES"
  if ! dp2_run_with_heartbeat phase2_bundle_checksum_fetch "$sha_url" -- \
      curl -fsSL --connect-timeout 30 --retry 5 -o "${cache_sha}.tmp" "$sha_url"
  then
    die "bundle checksum download failed"
  fi
  mv -f "${cache_sha}.tmp" "$cache_sha"
  sidecar_hash="$(read_hash "$cache_sha")"
  if [[ "$sidecar_hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
    if [[ "${sidecar_hash,,}" == "$expected" ]]; then
      log "SIDECAR_CROSSCHECK=PASS"
    else
      log "SIDECAR_CROSSCHECK=FAIL sidecar=${sidecar_hash} pretrusted=${expected}"
    fi
  else
    log "SIDECAR_CROSSCHECK=SKIP sidecar_format_invalid"
  fi

  # Best-effort Content-Length for progress (do not invent if unavailable)
  bytes_total="$(curl -fsSI --connect-timeout 10 --max-time 15 "$bundle_url" 2>/dev/null \
    | awk -F': ' 'BEGIN{IGNORECASE=1} /^Content-Length:/ {gsub(/\r/,"",$2); print $2; exit}')"
  [[ "$bytes_total" =~ ^[0-9]+$ ]] || bytes_total="UNKNOWN"

  if [[ -f "$verified_marker" && -f "$cache_tar" ]]; then
    PHASE2_STAGE_PHASE="VERIFY_BUNDLE_SHA256"
    log "PHASE2_STAGE_PHASE=${PHASE2_STAGE_PHASE}"
    local actual fsize
    fsize="$(stat -c%s "$cache_tar" 2>/dev/null || echo 0)"
    log "SHA256_FILE_SIZE_BYTES=${fsize}"
    if ! dp2_run_with_heartbeat phase2_cached_bundle_sha256 "$cache_tar" -- \
        bash -c "actual=\$(sha256sum \"$cache_tar\" | awk '{print \$1}'); printf '%s' \"\$actual\" >\"${cache_tar}.actual\""
    then
      die "cached bundle sha256 failed"
    fi
    actual="$(cat "${cache_tar}.actual")"
    rm -f "${cache_tar}.actual"
    if [[ "${expected,,}" == "${actual,,}" ]]; then
      ARTIFACT_CACHE_RESULT="REUSED"
      ARTIFACT_CHECKSUM_RESULT="PASS"
      log "ARTIFACT_CACHE_RESULT=REUSED"
      return 0
    fi
    log "ARTIFACT_CACHE_STALE=removing mismatched verified cache"
    rm -f "$verified_marker" "$cache_tar"
  fi

  if [[ -f "$cache_tar" ]]; then
    PHASE2_STAGE_PHASE="VERIFY_BUNDLE_SHA256"
    log "PHASE2_STAGE_PHASE=${PHASE2_STAGE_PHASE}"
    local actual
    if ! dp2_run_with_heartbeat phase2_existing_bundle_sha256 "$cache_tar" -- \
        bash -c "actual=\$(sha256sum \"$cache_tar\" | awk '{print \$1}'); printf '%s' \"\$actual\" >\"${cache_tar}.actual\""
    then
      die "existing bundle sha256 failed"
    fi
    actual="$(cat "${cache_tar}.actual")"
    rm -f "${cache_tar}.actual"
    if [[ "${expected,,}" == "${actual,,}" ]]; then
      : >"$verified_marker"
      ARTIFACT_CACHE_RESULT="REUSED"
      ARTIFACT_CHECKSUM_RESULT="PASS"
      log "ARTIFACT_CACHE_RESULT=REUSED"
      return 0
    fi
    rm -f "$cache_tar"
  fi

  ARTIFACT_CACHE_RESULT="DOWNLOADED"
  if [[ -f "$cache_part" && -s "$cache_part" ]]; then
    ARTIFACT_CACHE_RESULT="RESUMED"
    mode="RESUME"
    log "ARTIFACT_CACHE_RESULT=RESUMED"
    if ! dp2_run_download_with_progress phase2_bundle_download "$mode" "$cache_part" "$bytes_total" \
        curl -fsSL --connect-timeout 30 --retry 5 --retry-delay 5 \
        --continue-at - -o "$cache_part" "$bundle_url"
    then
      log "RESUME_UNSUPPORTED=falling back to full download"
      rm -f "$cache_part"
      ARTIFACT_CACHE_RESULT="DOWNLOADED"
      mode="FULL"
      if ! dp2_run_download_with_progress phase2_bundle_download "$mode" "$cache_part" "$bytes_total" \
          curl -fsSL --connect-timeout 30 --retry 5 --retry-delay 5 \
          -o "$cache_part" "$bundle_url"
      then
        die "bundle download failed"
      fi
    fi
  else
    mode="FULL"
    log "ARTIFACT_CACHE_RESULT=DOWNLOADED"
    if ! dp2_run_download_with_progress phase2_bundle_download "$mode" "$cache_part" "$bytes_total" \
        curl -fsSL --connect-timeout 30 --retry 5 --retry-delay 5 \
        -o "$cache_part" "$bundle_url"
    then
      die "bundle download failed"
    fi
  fi
  [[ -s "$cache_part" ]] || die "empty bundle download"
  is_probably_html "$cache_part" && die "bundle looks like HTML"

  PHASE2_STAGE_PHASE="VERIFY_BUNDLE_SHA256"
  log "PHASE2_STAGE_PHASE=${PHASE2_STAGE_PHASE}"
  local actual fsize
  fsize="$(stat -c%s "$cache_part" 2>/dev/null || echo 0)"
  log "SHA256_FILE_SIZE_BYTES=${fsize}"
  if ! dp2_run_with_heartbeat phase2_downloaded_bundle_sha256 "$cache_part" -- \
      bash -c "actual=\$(sha256sum \"$cache_part\" | awk '{print \$1}'); printf '%s' \"\$actual\" >\"${cache_part}.actual\""
  then
    die "downloaded bundle sha256 failed"
  fi
  actual="$(cat "${cache_part}.actual")"
  rm -f "${cache_part}.actual"
  if [[ "${expected,,}" != "${actual,,}" ]]; then
    rm -f "$cache_part" "$verified_marker"
    die "bundle sha256 mismatch (cache discarded)"
  fi
  mv -f "$cache_part" "$cache_tar"
  : >"$verified_marker"
  ARTIFACT_CHECKSUM_RESULT="PASS"
  log "ARTIFACT_CHECKSUM_RESULT=PASS"
}

# --- Time readiness / NTP source classification (Phase 2 staging guidance) ---
# Read-only. Does not configure NTP. Staging always places artifacts; bringup is never executed here.
# INTERNAL NTP absence alone never sets BRINGUP_READY=NO.

dp_phase2_max_clock_skew_seconds() {
  local raw="${DP_MAX_CLOCK_SKEW_SECONDS:-300}"
  if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$raw"
    return 0
  fi
  # Invalid values are rejected by check_ntp_bringup_readiness; keep a safe display default here.
  printf '300'
}

dp_phase2_ipv4_is_loopback_or_linklocal() {
  local ip="$1" a b
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b _ _ <<<"$ip"
  [[ "$a" == "127" ]] && return 0
  [[ "$a" == "169" && "$b" == "254" ]] && return 0
  return 1
}

dp_phase2_ipv4_is_internal_ntp() {
  # RFC1918 only. Loopback/link-local are not valid NTP sources.
  local ip="$1" a b
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  dp_phase2_ipv4_is_loopback_or_linklocal "$ip" && return 1
  IFS=. read -r a b _ _ <<<"$ip"
  [[ "$a" == "10" ]] && return 0
  [[ "$a" == "172" && "$b" -ge 16 && "$b" -le 31 ]] && return 0
  [[ "$a" == "192" && "$b" == "168" ]] && return 0
  return 1
}

dp_phase2_collect_ntp_sources() {
  # Prints candidate server/pool tokens (IP or hostname), one per line.
  local out conf line tok
  out=""
  if [[ -n "${DP_PHASE2_FAKE_NTPQ_PN:-}" ]]; then
    out="${DP_PHASE2_FAKE_NTPQ_PN}"
  elif command -v ntpq >/dev/null 2>&1; then
    out="$(ntpq -pn 2>/dev/null || ntpq -p 2>/dev/null || true)"
  fi
  if [[ -n "$out" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ [[:space:]]*remote[[:space:]]+refid ]] && continue
      [[ "$line" =~ ^=+$ ]] && continue
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      tok="$(printf '%s\n' "${line#"${line%%[![:space:]]*}"}" | awk '{print $1}')"
      tok="${tok#[*+#\-x\. ]}"
      [[ -n "$tok" && "$tok" != "remote" ]] || continue
      printf '%s\n' "$tok"
    done <<<"$out"
  fi
  conf="${DP_PHASE2_FAKE_NTP_CONF:-/etc/ntpsec/ntp.conf}"
  if [[ -r "$conf" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      if [[ "$line" =~ ^[[:space:]]*(server|pool)[[:space:]]+([^[:space:]]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"
      fi
    done <"$conf"
  fi
}

classify_ntp_source_class() {
  # Sets NTP_SOURCE_CLASS=INTERNAL|PUBLIC|UNKNOWN and INTERNAL_NTP_REQUIREMENT informational only.
  local tok has_internal=0 has_public=0 has_any=0
  NTP_SOURCE_CLASS="UNKNOWN"
  INTERNAL_NTP_REQUIREMENT="NOT_EVALUATED"
  while IFS= read -r tok || [[ -n "$tok" ]]; do
    [[ -n "$tok" ]] || continue
    has_any=1
    if [[ "$tok" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      if dp_phase2_ipv4_is_loopback_or_linklocal "$tok"; then
        continue
      fi
      if dp_phase2_ipv4_is_internal_ntp "$tok"; then
        has_internal=1
      else
        has_public=1
      fi
    else
      # Hostname → treat as public NTP source candidate (not RFC1918 IP).
      has_public=1
    fi
  done < <(dp_phase2_collect_ntp_sources | awk 'NF && !seen[$0]++')

  if [[ "$has_internal" -eq 1 ]]; then
    NTP_SOURCE_CLASS="INTERNAL"
    INTERNAL_NTP_REQUIREMENT="SATISFIED"
  elif [[ "$has_public" -eq 1 ]]; then
    NTP_SOURCE_CLASS="PUBLIC"
    INTERNAL_NTP_REQUIREMENT="NOT_SATISFIED"
  elif [[ "$has_any" -eq 0 ]]; then
    NTP_SOURCE_CLASS="UNKNOWN"
    INTERNAL_NTP_REQUIREMENT="NOT_SATISFIED"
  else
    NTP_SOURCE_CLASS="UNKNOWN"
    INTERNAL_NTP_REQUIREMENT="NOT_SATISFIED"
  fi
}

dp_phase2_ntpq_selected_peer() {
  local out line trimmed tally peer
  NTP_SELECTED_PEER=""
  if [[ -n "${DP_PHASE2_FAKE_NTPQ_PN:-}" ]]; then
    out="${DP_PHASE2_FAKE_NTPQ_PN}"
  elif command -v ntpq >/dev/null 2>&1; then
    out="$(ntpq -pn 2>/dev/null || ntpq -p 2>/dev/null || true)"
  else
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ [[:space:]]*remote[[:space:]]+refid ]] && continue
    [[ "$line" =~ ^=+$ ]] && continue
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$trimmed" ]] || continue
    tally="${trimmed:0:1}"
    [[ "$tally" == "*" ]] || continue
    peer="$(printf '%s\n' "$trimmed" | awk '{print $1}')"
    peer="${peer:1}"
    [[ -n "$peer" ]] || continue
    NTP_SELECTED_PEER="$peer"
    return 0
  done <<<"$out"
  return 1
}

dp_phase2_ntpq_leap_ok() {
  local rv
  if [[ -n "${DP_PHASE2_FAKE_NTPQ_RV:-}" ]]; then
    rv="${DP_PHASE2_FAKE_NTPQ_RV}"
  elif command -v ntpq >/dev/null 2>&1; then
    rv="$(ntpq -c rv 2>/dev/null || true)"
  else
    return 1
  fi
  printf '%s\n' "$rv" | grep -qE '(^|[[:space:],])leap=00([[:space:],]|$)'
}

dp_phase2_timedatectl_synchronized() {
  local td
  if [[ -n "${DP_PHASE2_FAKE_TIMEDATECTL:-}" ]]; then
    td="${DP_PHASE2_FAKE_TIMEDATECTL}"
  elif command -v timedatectl >/dev/null 2>&1; then
    td="$(timedatectl status 2>/dev/null || true)"
  else
    return 1
  fi
  # ntpsec often reports "NTP service: n/a" — that alone is not a failure.
  printf '%s\n' "$td" | grep -qiE 'System clock synchronized:[[:space:]]*yes'
}

dp_phase2_ntpwait_ok() {
  if [[ -n "${DP_PHASE2_FAKE_NTPWAIT_RC:-}" ]]; then
    [[ "${DP_PHASE2_FAKE_NTPWAIT_RC}" == "0" ]]
    return $?
  fi
  command -v ntpwait >/dev/null 2>&1 || return 1
  ntpwait >/dev/null 2>&1
}

dp_phase2_clock_skew_from_ntpq_seconds() {
  # Prints integer seconds (abs) from reachable peer offsets (ntpq offset is ms).
  local out line trimmed reach offset abs_ms best_ms=""
  if [[ -n "${DP_PHASE2_FAKE_NTPQ_PN:-}" ]]; then
    out="${DP_PHASE2_FAKE_NTPQ_PN}"
  elif command -v ntpq >/dev/null 2>&1; then
    out="$(ntpq -pn 2>/dev/null || ntpq -p 2>/dev/null || true)"
  else
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ [[:space:]]*remote[[:space:]]+refid ]] && continue
    [[ "$line" =~ ^=+$ ]] && continue
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$trimmed" ]] || continue
    reach="$(printf '%s\n' "$trimmed" | awk '{print $7}')"
    offset="$(printf '%s\n' "$trimmed" | awk '{print $9}')"
    [[ "$reach" =~ ^[0-9]+$ && "$reach" != "0" ]] || continue
    [[ "$offset" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]] || continue
    abs_ms="$(awk -v o="$offset" 'BEGIN { x=o+0; if (x<0) x=-x; printf "%d", x+0.5 }')"
    if [[ -z "$best_ms" ]] || [[ "$abs_ms" -lt "$best_ms" ]]; then
      best_ms="$abs_ms"
    fi
  done <<<"$out"
  [[ -n "$best_ms" ]] || return 1
  # ms → seconds (round)
  awk -v ms="$best_ms" 'BEGIN { printf "%d", (ms/1000)+0.5 }'
}

dp_phase2_clock_skew_from_http_date_seconds() {
  # Compare local UTC epoch to HTTP Date from internal mirror.
  local url headers date_hdr remote_epoch local_epoch skew
  url="${DP_PHASE2_TIME_REF_URL:-${MIRROR_URL}}"
  url="${url%/}"
  if [[ -n "${DP_PHASE2_FAKE_HTTP_DATE_EPOCH:-}" ]]; then
    remote_epoch="${DP_PHASE2_FAKE_HTTP_DATE_EPOCH}"
    [[ "$remote_epoch" =~ ^[0-9]+$ ]] || return 1
  else
    headers="$(curl -fsSI --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || true)"
    [[ -n "$headers" ]] || return 1
    date_hdr="$(printf '%s\n' "$headers" | awk -F': ' 'BEGIN{IGNORECASE=1} /^Date:/ {sub(/\r$/,"",$2); print $2; exit}')"
    [[ -n "$date_hdr" ]] || return 1
    remote_epoch="$(date -u -d "$date_hdr" +%s 2>/dev/null || true)"
    [[ "$remote_epoch" =~ ^[0-9]+$ ]] || return 1
  fi
  if [[ -n "${DP_PHASE2_FAKE_LOCAL_EPOCH:-}" ]]; then
    local_epoch="${DP_PHASE2_FAKE_LOCAL_EPOCH}"
  else
    local_epoch="$(date -u +%s)"
  fi
  [[ "$local_epoch" =~ ^[0-9]+$ ]] || return 1
  skew=$(( local_epoch - remote_epoch ))
  [[ "$skew" -lt 0 ]] && skew=$(( -skew ))
  printf '%s' "$skew"
}

check_ntp_bringup_readiness() {
  # Time readiness is the bringup gate. NTP_SOURCE_CLASS is informational only.
  local skew="" synced=0
  TIME_READINESS="FAIL_TIME_UNVERIFIABLE"
  BRINGUP_READY="NO"
  CLOCK_SKEW_SECONDS=""
  MAX_CLOCK_SKEW_SECONDS="$(dp_phase2_max_clock_skew_seconds)"
  NTP_SELECTED_PEER=""
  classify_ntp_source_class
  log "NTP_SOURCE_CLASS=${NTP_SOURCE_CLASS}"
  log "INTERNAL_NTP_REQUIREMENT=${INTERNAL_NTP_REQUIREMENT}"

  _dp_phase2_warn_if_no_internal_ntp() {
    if [[ "$NTP_SOURCE_CLASS" != "INTERNAL" ]]; then
      log "WARNING: no internal NTP source detected; continuing because local clock readiness passed"
    fi
  }

  if dp_phase2_ntpwait_ok; then
    synced=1
    dp_phase2_ntpq_selected_peer || true
    TIME_READINESS="PASS_SYNCED"
    BRINGUP_READY="YES"
    NTP_BRINGUP_READINESS="PASS"
    log "TIME_READINESS=PASS_SYNCED (ntpwait)"
    _dp_phase2_warn_if_no_internal_ntp
    log "BRINGUP_READY=YES"
    return 0
  fi

  if dp_phase2_ntpq_selected_peer && dp_phase2_ntpq_leap_ok; then
    synced=1
  elif dp_phase2_timedatectl_synchronized; then
    synced=1
    dp_phase2_ntpq_selected_peer || true
  fi

  if [[ "$synced" -eq 1 ]]; then
    TIME_READINESS="PASS_SYNCED"
    BRINGUP_READY="YES"
    NTP_BRINGUP_READINESS="PASS"
    log "TIME_READINESS=PASS_SYNCED"
    log "NTP_SELECTED_PEER=${NTP_SELECTED_PEER:-}"
    _dp_phase2_warn_if_no_internal_ntp
    log "BRINGUP_READY=YES"
    return 0
  fi

  # Unsynchronized: evaluate clock skew against ntpq offsets, then HTTP Date.
  skew="$(dp_phase2_clock_skew_from_ntpq_seconds 2>/dev/null || true)"
  if [[ -z "$skew" ]]; then
    skew="$(dp_phase2_clock_skew_from_http_date_seconds 2>/dev/null || true)"
  fi

  if [[ -n "$skew" && "$skew" =~ ^[0-9]+$ ]]; then
    CLOCK_SKEW_SECONDS="$skew"
    log "CLOCK_SKEW_SECONDS=${CLOCK_SKEW_SECONDS}"
    log "MAX_CLOCK_SKEW_SECONDS=${MAX_CLOCK_SKEW_SECONDS}"
    if [[ "$skew" -le "$MAX_CLOCK_SKEW_SECONDS" ]]; then
      TIME_READINESS="PASS_WITH_WARNING"
      BRINGUP_READY="YES"
      NTP_BRINGUP_READINESS="PASS"
      log "TIME_READINESS=PASS_WITH_WARNING"
      log "WARNING: NTP sync unconfirmed; clock skew within tolerance — bringup guidance allowed"
      _dp_phase2_warn_if_no_internal_ntp
      log "BRINGUP_READY=YES"
      return 0
    fi
    TIME_READINESS="FAIL_CLOCK_SKEW"
    BRINGUP_READY="NO"
    NTP_BRINGUP_READINESS="FAIL"
    log "TIME_READINESS=FAIL_CLOCK_SKEW"
    log "BRINGUP_READY=NO"
    return 0
  fi

  TIME_READINESS="FAIL_TIME_UNVERIFIABLE"
  BRINGUP_READY="NO"
  NTP_BRINGUP_READINESS="FAIL"
  log "TIME_READINESS=FAIL_TIME_UNVERIFIABLE"
  log "BRINGUP_READY=NO"
  return 0
}

emit_final_report() {
  cat <<EOF
MIN_SUPPORTED_SOURCE_DP_VERSION=${MIN_SUPPORTED_SOURCE_DP_VERSION}
SOURCE_DP_VERSION=${SOURCE_DP_VERSION}
SOURCE_DP_VERSION_RAW=${SOURCE_DP_VERSION_RAW}
SOURCE_DP_VERSION_ORIGIN=${SOURCE_DP_VERSION_ORIGIN}
SOURCE_DP_VERSION_CHECK=${SOURCE_DP_VERSION_CHECK}
TARGET_DP_VERSION=${TARGET_DP_VERSION}
PHASE2_ARTIFACT_VERSION=${PHASE2_ARTIFACT_VERSION}
TARGET_VERSION_COMPATIBILITY=${TARGET_VERSION_COMPATIBILITY}
AELLA_UID=${AELLA_UID}
AELLA_PRIMARY_GID=${AELLA_PRIMARY_GID}
AELLA_PRIMARY_GROUP=${AELLA_PRIMARY_GROUP}
AELLA_OWNERSHIP_CHECK=${AELLA_OWNERSHIP_CHECK}
ARTIFACT_CACHE_RESULT=${ARTIFACT_CACHE_RESULT}
ARTIFACT_CHECKSUM_RESULT=${ARTIFACT_CHECKSUM_RESULT}
PHASE2_STAGE_RESULT=${PHASE2_STAGE_RESULT}
TIME_READINESS=${TIME_READINESS}
CLOCK_SKEW_SECONDS=${CLOCK_SKEW_SECONDS}
MAX_CLOCK_SKEW_SECONDS=${MAX_CLOCK_SKEW_SECONDS}
NTP_SOURCE_CLASS=${NTP_SOURCE_CLASS}
NTP_SELECTED_PEER=${NTP_SELECTED_PEER}
INTERNAL_NTP_REQUIREMENT=${INTERNAL_NTP_REQUIREMENT}
NTP_BRINGUP_READINESS=${NTP_BRINGUP_READINESS}
BRINGUP_READY=${BRINGUP_READY}
BRINGUP_EXECUTED=${BRINGUP_EXECUTED}
BRINGUP_VENDOR_COMPAT=${BRINGUP_VENDOR_COMPAT}
ARTIFACT_DIR=${ARTIFACT_DIR}
BRINGUP_SCRIPT=${BRINGUP_SCRIPT}
AELLA_CLI_AVAILABLE_BEFORE_BRINGUP=NOT_REQUIRED
AELLA_CLI_CHECK_EARLIEST_POINT=AFTER_BRINGUP_RESULT_PASS
EOF
  if [[ "$BRINGUP_READY" == "YES" ]] \
    && [[ "$TIME_READINESS" == "PASS_SYNCED" || "$TIME_READINESS" == "PASS_WITH_WARNING" ]]; then
    cat <<EOF
NEXT_COMMAND=sudo bash ${BRINGUP_SCRIPT} --version ${TARGET_DP_VERSION} --skip-download
NEXT_COMMAND_BEHAVIOR=START_DETACHED_WORKER_AND_ATTACH_MONITOR
NEXT_COMMAND_NOTE=Only run after TIME_READINESS=PASS_SYNCED|PASS_WITH_WARNING and operator snapshot confirmation. Default attaches a foreground monitor; use --detach to return after handoff. Do not check aella_cli until BRINGUP_RESULT=PASS.
EOF
  else
    cat <<EOF
NEXT_COMMAND=NOT_READY
NEXT_COMMAND_NOTE=Fix local clock readiness (skew/unverifiable time) before bringup; staging does not execute bringup; missing internal NTP alone is not a hard gate
EOF
  fi
}

stage_phase2_ubuntu_prerequisites() {
  local extras_base="${MIRROR_URL}/dp-phase2/${TARGET_DP_VERSION}/extras"
  local state_name="phase2-ubuntu-prerequisites.state"
  local name="phase2-ubuntu-prerequisites.tar.gz"
  local state_url="${extras_base}/${state_name}"
  local url="${extras_base}/${name}"
  local dest="${ARTIFACT_DIR}/${name}"
  local state_dest="${ARTIFACT_DIR}/${state_name}"
  local tmp sha_url sha_dest required count build publication artifact_name sha
  tmp="$(mktemp "${ARTIFACT_DIR}/.${state_name}.XXXXXX")"
  if ! curl -fsSL --connect-timeout 15 --max-time 30 --retry 2 -o "$tmp" "$state_url"; then
    rm -f "$tmp"
    log "PHASE2_PREREQ_STAGE=FAIL reason=state_not_published"
    return 1
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    log "PHASE2_PREREQ_STAGE=FAIL reason=state_empty"
    return 1
  fi
  mv -f "$tmp" "$state_dest"
  chown "${AELLA_UID}:${AELLA_PRIMARY_GID}" "$state_dest" 2>/dev/null || true
  required="$(awk -F= '$1=="PHASE2_PREREQ_REQUIRED"{print $2; exit}' "$state_dest")"
  count="$(awk -F= '$1=="PHASE2_PREREQ_PACKAGE_COUNT"{print $2; exit}' "$state_dest")"
  build="$(awk -F= '$1=="PHASE2_PREREQ_BUILD"{print $2; exit}' "$state_dest")"
  publication="$(awk -F= '$1=="PHASE2_PREREQ_PUBLICATION"{print $2; exit}' "$state_dest")"
  artifact_name="$(awk -F= '$1=="PHASE2_PREREQ_ARTIFACT"{print $2; exit}' "$state_dest")"
  sha="$(awk -F= '$1=="PHASE2_PREREQ_SHA256"{print $2; exit}' "$state_dest")"
  log "PHASE2_PREREQ_REQUIRED=${required:-unknown} PHASE2_PREREQ_PACKAGE_COUNT=${count:-unknown} PHASE2_PREREQ_BUILD=${build:-unknown} PHASE2_PREREQ_PUBLICATION=${publication:-unknown}"
  retract_staged_phase2_prereq_artifacts() {
    # Remove only the currently consumable prerequisite artifact set.
    rm -f "$dest" "${dest}.sha256" "${ARTIFACT_DIR}/phase2-ubuntu-prerequisites.manifest.json"
  }
  if [[ "$build" != "PASS" ]]; then
    retract_staged_phase2_prereq_artifacts
    log "PHASE2_PREREQ_STAGE=FAIL reason=build_not_pass"
    return 1
  fi
  if [[ "$publication" != "PASS" ]]; then
    retract_staged_phase2_prereq_artifacts
    log "PHASE2_PREREQ_STAGE=FAIL reason=publication_not_pass"
    return 1
  fi
  if [[ -z "$count" ]]; then
    log "PHASE2_PREREQ_STAGE=FAIL reason=count_missing"
    return 1
  fi
  if [[ ! "$count" =~ ^[0-9]+$ ]]; then
    log "PHASE2_PREREQ_STAGE=FAIL reason=count_nonnumeric"
    return 1
  fi
  if [[ "$required" == "NO" ]]; then
    retract_staged_phase2_prereq_artifacts
    if [[ "$count" != "0" ]]; then
      log "PHASE2_PREREQ_STAGE=FAIL reason=count_nonzero_when_not_required"
      return 1
    fi
    log "PHASE2_PREREQ_STAGE=NOT_REQUIRED"
    return 0
  fi
  if [[ "$required" != "YES" ]]; then
    log "PHASE2_PREREQ_STAGE=FAIL reason=state_invalid required=${required}"
    return 1
  fi
  if [[ "$count" -le 0 ]]; then
    log "PHASE2_PREREQ_STAGE=FAIL reason=count_not_positive"
    return 1
  fi
  if [[ "$artifact_name" != "$name" ]]; then
    log "PHASE2_PREREQ_STAGE=FAIL reason=artifact_name_invalid"
    return 1
  fi
  if [[ ! "$sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
    log "PHASE2_PREREQ_STAGE=FAIL reason=sha256_missing"
    return 1
  fi
  tmp="$(mktemp "${ARTIFACT_DIR}/.${name}.XXXXXX")"
  if ! curl -fsSL --connect-timeout 15 --max-time 120 --retry 2 -o "$tmp" "$url"; then
    rm -f "$tmp"
    log "PHASE2_PREREQ_STAGE=FAIL reason=artifact_http"
    return 1
  fi
  if [[ ! -s "$tmp" ]] \
    || head -c 256 "$tmp" | tr -d '\0' | grep -qiE '<!DOCTYPE[[:space:]]*html|<html[[:space:]]|<html>'; then
    rm -f "$tmp"
    log "PHASE2_PREREQ_STAGE=FAIL reason=invalid_payload"
    return 1
  fi
  sha_url="${url}.sha256"
  sha_dest="${dest}.sha256"
  if ! curl -fsSL --connect-timeout 15 --max-time 30 -o "${sha_dest}.tmp" "$sha_url"; then
    rm -f "$tmp" "${sha_dest}.tmp"
    log "PHASE2_PREREQ_STAGE=FAIL reason=sha256_missing"
    return 1
  fi
  mv -f "${sha_dest}.tmp" "$sha_dest"
  local expected actual
  expected="$(awk 'NF {print $1; exit}' "$sha_dest")"
  actual="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ -z "$expected" || "${expected,,}" != "${actual,,}" || "${sha,,}" != "${actual,,}" ]]; then
    rm -f "$tmp" "$sha_dest"
    log "PHASE2_PREREQ_STAGE=FAIL reason=sha256"
    return 1
  fi
  local manifest_dest="${ARTIFACT_DIR}/phase2-ubuntu-prerequisites.manifest.json"
  if ! curl -fsSL --connect-timeout 15 --max-time 30 \
    -o "${manifest_dest}.tmp" \
    "${extras_base}/phase2-ubuntu-prerequisites.manifest.json"; then
    rm -f "$tmp" "$sha_dest" "${manifest_dest}.tmp"
    log "PHASE2_PREREQ_STAGE=FAIL reason=manifest_http"
    return 1
  fi
  mv -f "${manifest_dest}.tmp" "$manifest_dest"
  mv -f "$tmp" "$dest"
  chown "${AELLA_UID}:${AELLA_PRIMARY_GID}" "$dest" 2>/dev/null || true
  chown "${AELLA_UID}:${AELLA_PRIMARY_GID}" "$sha_dest" 2>/dev/null || true
  chown "${AELLA_UID}:${AELLA_PRIMARY_GID}" "$manifest_dest" 2>/dev/null || true
  log "PHASE2_PREREQ_STAGE=PASS path=${dest}"
  return 0
}

install_bringup_lifecycle_wrapper() {
  PHASE2_STAGE_PHASE="PUBLISH_BRINGUP_CONTROLLER"
  log "PHASE2_STAGE_PHASE=${PHASE2_STAGE_PHASE}"
  BRINGUP_INSTALL_ATTEMPTED="YES"
  local wrapper_src vendor_src lib_dest
  vendor_src="${STAGE_ROOT}/bringup_py3_dp_after_os_upgrade.sh"
  wrapper_src="$LIFECYCLE_WRAPPER_SRC"
  if [[ ! -f "$wrapper_src" ]]; then
    if ! _stage_fetch_helper_verified "$LIFECYCLE_WRAPPER_SRC" "bringup_py3_dp_lifecycle.sh"; then
      die "lifecycle wrapper missing and generation-verified download failed"
    fi
    wrapper_src="$LIFECYCLE_WRAPPER_SRC"
  fi

  install -o "$AELLA_UID" -g "$AELLA_PRIMARY_GID" -m 0755 \
    "$vendor_src" "$VENDOR_BRINGUP_INSTALLED"
  install -o "$AELLA_UID" -g "$AELLA_PRIMARY_GID" -m 0644 \
    "${STAGE_ROOT}/bringup_py3_dp_after_os_upgrade.sh.sha1" \
    "${VENDOR_BRINGUP_INSTALLED}.sha1"
  verify_sha1_pair "$VENDOR_BRINGUP_INSTALLED" "${VENDOR_BRINGUP_INSTALLED}.sha1"

  install -o root -g root -m 0755 "$wrapper_src" "$BRINGUP_SCRIPT"
  # Install lifecycle libs beside offline evidence for worker re-exec
  lib_dest="/opt/aelladata/os-upgrade/offline/phase2-bringup/lib"
  mkdir -p "$lib_dest"
  chmod 0700 "$(dirname "$lib_dest")" "$lib_dest" 2>/dev/null || true
  install -o root -g root -m 0600 \
    "${_STAGE_LIB_DIR}/dp-phase2-bringup-lifecycle.sh" \
    "${lib_dest}/dp-phase2-bringup-lifecycle.sh"
  # Also place lib next to wrapper for SCRIPT_DIR/lib resolution
  mkdir -p "${BRINGUP_DIR}/lib"
  install -o root -g root -m 0644 \
    "${_STAGE_LIB_DIR}/dp-phase2-bringup-lifecycle.sh" \
    "${BRINGUP_DIR}/lib/dp-phase2-bringup-lifecycle.sh"
  if [[ -f "${_STAGE_LIB_DIR}/dp-phase2-ubuntu-prerequisites.sh" ]]; then
    install -o root -g root -m 0600 \
      "${_STAGE_LIB_DIR}/dp-phase2-ubuntu-prerequisites.sh" \
      "${lib_dest}/dp-phase2-ubuntu-prerequisites.sh"
    install -o root -g root -m 0644 \
      "${_STAGE_LIB_DIR}/dp-phase2-ubuntu-prerequisites.sh" \
      "${BRINGUP_DIR}/lib/dp-phase2-ubuntu-prerequisites.sh"
  fi

  local bu bg
  bu="$(stat -c '%u' "$VENDOR_BRINGUP_INSTALLED")"
  bg="$(stat -c '%g' "$VENDOR_BRINGUP_INSTALLED")"
  [[ "$bu" == "$AELLA_UID" && "$bg" == "$AELLA_PRIMARY_GID" ]] \
    || die "vendor bringup ownership mismatch uid=${bu} gid=${bg}"
  log "BRINGUP_LIFECYCLE_WRAPPER=INSTALLED path=${BRINGUP_SCRIPT}"
  log "BRINGUP_VENDOR_SCRIPT=${VENDOR_BRINGUP_INSTALLED}"
}

# Static compatibility check: installed vendor must accept the current
# --worker-password contract used by Menu 7 and the lifecycle wrapper.
# Never executes bringup.
verify_installed_bringup_vendor_compat() {
  local vendor="$VENDOR_BRINGUP_INSTALLED"
  local wrapper="$BRINGUP_SCRIPT"
  BRINGUP_VENDOR_COMPAT="FAIL"
  if [[ ! -f "$vendor" ]]; then
    log "BRINGUP_VENDOR_COMPAT=FAIL reason=vendor_missing"
    return 1
  fi
  if [[ ! -f "$wrapper" ]]; then
    log "BRINGUP_VENDOR_COMPAT=FAIL reason=wrapper_missing"
    return 1
  fi
  if ! grep -q -- '--worker-password' "$wrapper"; then
    log "BRINGUP_VENDOR_COMPAT=FAIL reason=wrapper_missing_worker_password"
    return 1
  fi
  if ! grep -q -- '--worker-password' "$vendor"; then
    log "BRINGUP_VENDOR_COMPAT=FAIL reason=vendor_missing_worker_password"
    return 1
  fi
  if ! grep -q 'WORKER_IPS requires --worker-password\|--worker-ips requires --worker-password\|--worker-ips/--standby requires --worker-password-file' "$vendor"; then
    log "BRINGUP_VENDOR_COMPAT=FAIL reason=vendor_missing_worker_password_validation"
    return 1
  fi
  BRINGUP_VENDOR_COMPAT="PASS"
  log "BRINGUP_VENDOR_COMPAT=PASS"
  return 0
}

stage_main() {
  parse_args "$@"

  if [[ "$DIAGNOSE_SOURCE_VERSION" -eq 1 ]]; then
    diagnose_source_version_main
    return $?
  fi

  require_root
  require_noble
  # Prove TARGET is not shadowed by os-release VERSION
  local os_version_field
  os_version_field="$(os_release_field VERSION)"
  [[ "$TARGET_DP_VERSION" != "$os_version_field" ]] || true
  [[ "$TARGET_DP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "TARGET_DP_VERSION corrupted after OS checks: ${TARGET_DP_VERSION}"

  require_space
  resolve_aella_ownership
  require_os_upgrade_state
  require_dpkg_apt_clean
  require_no_active_os_upgrade

  # Source version MUST resolve before any bundle/cache/artifact mutation.
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
  resolve_source_dp_version
  evaluate_version_compatibility
  load_release_env_from_mirror

  CACHE_DIR="/opt/aelladata/.dp-phase2-cache/${TARGET_DP_VERSION}"
  STAGE_ROOT="/opt/aelladata/.aelladeb_py3.stage.${RUN_ID}"
  acquire_stage_lock
  ensure_verified_bundle

  ARTIFACT_MUTATION_ATTEMPTED="YES"
  mkdir -p "$STAGE_ROOT"
  local cache_tar="${CACHE_DIR}/bundle.tar"
  assert_safe_tar_list "$cache_tar"

  PHASE2_STAGE_PHASE="EXTRACT_BUNDLE"
  log "PHASE2_STAGE_PHASE=${PHASE2_STAGE_PHASE}"
  if ! dp2_run_extract_with_progress phase2_tar_extract "$STAGE_ROOT" -- \
      tar -xf "$cache_tar" -C "$STAGE_ROOT"
  then
    die "bundle extraction failed"
  fi

  PHASE2_STAGE_PHASE="VERIFY_EXTRACTED_ARTIFACTS"
  log "PHASE2_STAGE_PHASE=${PHASE2_STAGE_PHASE}"
  local f
  for f in "${REQUIRED_BUNDLE_FILES[@]}"; do
    [[ -f "${STAGE_ROOT}/${f}" ]] || die "missing extracted file ${f}"
    [[ -s "${STAGE_ROOT}/${f}" ]] || die "zero-byte extracted file ${f}"
  done
  verify_sha1_pair "${STAGE_ROOT}/aelladeb_py3_common.tar.gz" "${STAGE_ROOT}/aelladeb_py3_common.tar.gz.sha1"
  verify_sha1_pair \
    "${STAGE_ROOT}/aella-uvp-2404_${TARGET_DP_VERSION}ubuntu1_amd64.deb" \
    "${STAGE_ROOT}/aella-uvp-2404_${TARGET_DP_VERSION}ubuntu1_amd64.deb.sha1"
  verify_sha1_pair "${STAGE_ROOT}/bringup_py3_dp_after_os_upgrade.sh" "${STAGE_ROOT}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  verify_sha256_pair \
    "${STAGE_ROOT}/images-${TARGET_DP_VERSION}.tar" \
    "${STAGE_ROOT}/images-${TARGET_DP_VERSION}.tar.sha256"

  install_bringup_lifecycle_wrapper
  if ! verify_installed_bringup_vendor_compat; then
    BRINGUP_READY="NO"
    PHASE2_STAGE_RESULT="FAIL"
    log "BRINGUP_READY=NO"
    log "PHASE2_STAGE_RESULT=FAIL"
    die "installed vendor bringup is incompatible with --worker-password"
  fi

  PHASE2_STAGE_PHASE="PUBLISH_ARTIFACTS"
  log "PHASE2_STAGE_PHASE=${PHASE2_STAGE_PHASE}"
  NEW_ART="${ARTIFACT_DIR}.new.${RUN_ID}"
  rm -rf "$NEW_ART"
  mkdir -p "$NEW_ART"
  _phase2_copy_artifacts() {
    local f
    for f in "${ARTIFACT_FILES[@]}"; do
      cp -a "${STAGE_ROOT}/${f}" "${NEW_ART}/${f}"
    done
  }
  if ! dp2_run_with_heartbeat phase2_artifact_copy "$NEW_ART" -- _phase2_copy_artifacts; then
    die "artifact copy failed"
  fi

  PHASE2_STAGE_PHASE="APPLY_OWNERSHIP"
  log "PHASE2_STAGE_PHASE=${PHASE2_STAGE_PHASE}"
  if ! dp2_run_with_heartbeat phase2_chown_artifacts "$NEW_ART" -- \
      chown -R "${AELLA_UID}:${AELLA_PRIMARY_GID}" "$NEW_ART"
  then
    die "artifact chown failed"
  fi

  PHASE2_STAGE_PHASE="FINAL_VALIDATION"
  log "PHASE2_STAGE_PHASE=${PHASE2_STAGE_PHASE}"
  if [[ ! -e "$ARTIFACT_DIR" ]]; then
    mv -f "$NEW_ART" "$ARTIFACT_DIR"
    NEW_ART=""
  else
    if [[ -d "$ARTIFACT_DIR" ]]; then
      local old_h new_h
      old_h="$(artifact_manifest_hash "$ARTIFACT_DIR" 2>/dev/null || true)"
      if ! dp2_run_with_heartbeat phase2_manifest_hash "$NEW_ART" -- \
          du -sb "$NEW_ART"
      then
        die "manifest precheck failed"
      fi
      new_h="$(artifact_manifest_hash "$NEW_ART" 2>/dev/null || true)"
      if [[ -n "$old_h" && -n "$new_h" && "$old_h" == "$new_h" ]]; then
        log "ARTIFACT_REUSE=PASS identical manifest"
        rm -rf "$NEW_ART"
        NEW_ART=""
      else
        local bak="${ARTIFACT_DIR}.bak.${RUN_ID}"
        if [[ -e "$bak" ]]; then
          die "backup path already exists: ${bak}"
        fi
        mv -f "$ARTIFACT_DIR" "$bak"
        mv -f "$NEW_ART" "$ARTIFACT_DIR"
        NEW_ART=""
        log "ARTIFACT_BACKUP=${bak}"
      fi
    else
      die "${ARTIFACT_DIR} exists and is not a directory"
    fi
  fi

  # Re-verify final ownership on a sample artifact
  local sample="${ARTIFACT_DIR}/images-${TARGET_DP_VERSION}.tar"
  [[ -f "$sample" ]] || die "final artifact missing ${sample}"
  local bu bg
  bu="$(stat -c '%u' "$sample")"
  bg="$(stat -c '%g' "$sample")"
  [[ "$bu" == "$AELLA_UID" && "$bg" == "$AELLA_PRIMARY_GID" ]] \
    || die "artifact ownership mismatch uid=${bu} gid=${bg}"

  # Separate Phase 2 Ubuntu prerequisite artifact (not part of the 9 ACPS files).
  stage_phase2_ubuntu_prerequisites || die "PHASE2_PREREQ_STAGE=FAIL"

  rm -rf "$STAGE_ROOT"
  STAGE_ROOT=""

  if [[ "$KEEP_CACHE" -eq 0 ]]; then
    rm -f "${CACHE_DIR}/bundle.tar" "${CACHE_DIR}/bundle.tar.part" \
      "${CACHE_DIR}/bundle.tar.sha256" "${CACHE_DIR}/VERIFIED"
    log "ARTIFACT_CACHE_CLEANUP=PASS"
  else
    log "ARTIFACT_CACHE_CLEANUP=SKIPPED (--keep-cache)"
  fi

  PHASE2_STAGE_PHASE="TIME_READINESS"
  log "PHASE2_STAGE_PHASE=${PHASE2_STAGE_PHASE}"
  check_ntp_bringup_readiness || true
  PHASE2_STAGE_RESULT="PASS"
  BRINGUP_EXECUTED="NO"
  emit_final_report
}

# Allow tests to source functions without executing main.
if [[ "${DP_PHASE2_STAGE_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

stage_main "$@"
