#!/usr/bin/env bash
# dp-os-upgrade-preflight.sh — Phase 1 OS-only preflight (canonical)
#
# Analyzes collect-dp-upgrade-readiness.sh output for Ubuntu LTS hop readiness.
# Emits READY / READY_WITH_WARNINGS / BLOCKED. Does NOT modify the DP host.
# Phase 2 (DP Python/Py3 bringup) is NEVER evaluated as a readiness gate.
#
# Compatible with Bash 4.3+ / Ubuntu 16.04.
# shellcheck disable=SC2034,SC1090,SC1091

# Do not use set -e: individual checks must continue after failures.
set -uo pipefail

umask 077
export LC_ALL=C
export LANG=C

SCRIPT_VERSION="1.1.0"
SCHEMA_VERSION="1.0"
SCRIPT_NAME="dp-os-upgrade-preflight.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/dp-preflight-common.sh
# Prefer canonical lib name; fall back to legacy name
if [[ -f "${SCRIPT_DIR}/lib/dp-os-preflight-common.sh" ]]; then
  # shellcheck source=scripts/lib/dp-os-preflight-common.sh
  source "${SCRIPT_DIR}/lib/dp-os-preflight-common.sh"
else
  # shellcheck source=scripts/lib/dp-preflight-common.sh
  source "${SCRIPT_DIR}/lib/dp-preflight-common.sh"
fi

# ---------------------------------------------------------------------------
# Exit codes
# ---------------------------------------------------------------------------
EXIT_READY=0
EXIT_READY_WITH_WARNINGS=10
EXIT_BLOCKED=20
EXIT_CLI=2
EXIT_INTERNAL=3

# ---------------------------------------------------------------------------
# CLI / globals
# ---------------------------------------------------------------------------
COLLECTION_PATH=""
PACKAGE_SOURCE_MODE=""
PACKAGE_SOURCE_URL=""
BRINGUP_MODE=""
BRINGUP_MODE_LEGACY_SET=0
EXECUTION_PROFILE=""
SNAPSHOT_REFERENCE=""
BACKUP_REFERENCE=""
OUTPUT_DIR="."
POLICY_FILE="${REPO_ROOT}/config/dp-os-upgrade-preflight.conf"
LIVE_CHECK=0
NETWORK_TIMEOUT=10
KEEP_DIRECTORY=0
DISCOVERY_ACK=""
LEGACY_ACTION_NORMALIZED=""
PHASE2_EVALUATED=false
NEXT_HOP=""
OS_UPGRADE_REQUIRED=false
SNAPSHOT_REQUIRED=true

PREFLIGHT_ID=""
RESULT_DIR=""
RESULT_NAME=""
TMP_DIR=""
COLLECTION_ROOT=""
INPUT_TYPE=""
OWNED_TMP=0
STARTED_AT_UTC=""
COMPLETED_AT_UTC=""
DURATION_SECONDS=0
EXECUTION_LOG=""

OVERALL_STATUS="BLOCKED"
EXIT_CODE="$EXIT_BLOCKED"
PASS_COUNT=0
WARNING_COUNT=0
BLOCKER_COUNT=0
UNKNOWN_COUNT=0
SKIPPED_COUNT=0

# Check accumulation (parallel arrays via TSV lines)
CHECKS_TSV_BODY=""
CHECKS_JSON_PARTS=()

# Upgrade plan
PHASE1_REQUIRED=false
PHASE2_REQUIRED=false
PHASE1_HOPS_CSV=""
RECOMMENDED_ACTION="NONE"
SUPPORTED_START=false
UPGRADE_REQUIRED=true
DP_VERSION_RAW=""
DP_VERSION_NORM=""
OS_VERSION=""
OS_CODENAME=""
HOSTNAME_VAL=""
ROLE_CANON=""
CLUSTER_DETECTED="false"
WORKER_IPS_CSV=""

COLLECTOR_SCRIPT_VERSION=""
COLLECTOR_SCHEMA_VERSION=""
COLLECTION_STATUS=""
COLLECTION_ID=""
INTEGRITY_STATUS="invalid"
JSON_PARSER_USED=""

# Policy defaults (overridden by policy file)
POLICY_MIN_SUPPORTED_DP_VERSION="6.2.0"
POLICY_TARGET_DP_VERSION="6.6.0"
POLICY_TARGET_OS_VERSION="24.04"
POLICY_MIN_ROOT_AVAILABLE_BYTES="12884901888"
POLICY_MIN_BOOT_AVAILABLE_BYTES="536870912"
POLICY_MIN_AELLADATA_AVAILABLE_BYTES="5368709120"
POLICY_MIN_INODE_AVAILABLE_PERCENT="10"
POLICY_REQUIRE_AELLA_BASH="true"
POLICY_REQUIRE_ROOT_BASH="true"
POLICY_REQUIRE_SNAPSHOT_OR_BACKUP="true"
POLICY_DEFAULT_EXECUTION_PROFILE="production"
POLICY_PRODUCTION_REQUIRE_SNAPSHOT_OR_BACKUP="true"
POLICY_DISCOVERY_REQUIRE_SNAPSHOT_OR_BACKUP="false"
POLICY_DISCOVERY_REQUIRE_DISPOSABLE_VM_ACK="true"
POLICY_DISCOVERY_DEFAULT_MAX_HOPS="1"
POLICY_DISCOVERY_REQUIRE_NEW_PREFLIGHT_AFTER_HOP="true"
POLICY_DISCOVERY_CAPTURE_PACKAGES="true"
POLICY_DISCOVERY_CAPTURE_FILE_CHANGES="true"
POLICY_DISCOVERY_CAPTURE_PYTHON_INVENTORY="true"
POLICY_DISCOVERY_PRESERVE_APT_CACHE="true"
POLICY_PHASE2_CHECKS_AFFECT_OS_PREFLIGHT="false"
POLICY_MISSING_PHASE2_BUNDLE_WHEN_PHASE2_NOT_REQUIRED="info"
POLICY_THIRD_PARTY_REPOSITORIES="warning"
POLICY_AELLADATA_NOT_SEPARATE_MOUNT="warning"
POLICY_UNKNOWN_NTP_STATUS="blocker"
POLICY_MISSING_PACKAGE_SOURCE_EVIDENCE="blocker"
POLICY_CRITICAL_HELD_PACKAGES="systemd,udev,apt,dpkg,linux-generic,ubuntu-minimal,ubuntu-standard,ubuntu-release-upgrader-core,update-manager-core"
POLICY_SUPPORTED_COLLECTOR_SCRIPT_VERSIONS="1.0.1,1.0.2"
POLICY_SUPPORTED_COLLECTOR_SCHEMA_VERSIONS="1.0"
POLICY_REJECTED_REFERENCE_PLACEHOLDERS="none,n/a,na,unknown,todo,test,later,null,undefined,placeholder,tbd,pending"
POLICY_PROJECT_MANAGES_CRITICAL_HOLDS="false"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
utc_now() { date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u; }
utc_stamp() { date -u +"%Y%m%dT%H%M%SZ" 2>/dev/null || date -u +"%Y%m%dT%H%M%SZ"; }

log() {
  local level="${1:-INFO}"
  shift || true
  local msg="$*"
  local ts line
  ts="$(utc_now)"
  line="${ts} ${level} ${msg}"
  printf '%s\n' "$line" >&2
  if [[ -n "${EXECUTION_LOG:-}" ]]; then
    printf '%s\n' "$line" >>"$EXECUTION_LOG" 2>/dev/null || true
  fi
}
log_info() { log INFO "$*"; }
log_warn() { log WARN "$*"; }
log_error() { log ERROR "$*"; }

die_cli() { log_error "$*"; exit "$EXIT_CLI"; }
die_internal() { log_error "$*"; exit "$EXIT_INTERNAL"; }

cleanup() {
  local rc=$?
  if [[ "$OWNED_TMP" -eq 1 && -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
    rm -rf "$TMP_DIR" 2>/dev/null || true
  fi
  return "$rc"
}

# Only install EXIT trap when executed as a program (not when sourced by tests).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap cleanup EXIT
fi

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --collection PATH --package-source-mode MODE [options]

Phase 1 OS-only preflight. Phase 2 (DP Python/Py3 bringup) is not evaluated.

Required:
  --collection PATH              Collector result directory or .tar.gz
  --package-source-mode MODE     direct | cache | mirror

Required when MODE is cache or mirror:
  --package-source-url URL

Execution profile (default: production):
  --execution-profile PROFILE    production | discovery

Production READY when OS upgrade required:
  --snapshot-reference TEXT and/or --backup-reference TEXT

Discovery: snapshot/backup optional (INFO/WARNING if absent). Disposable VM
acknowledgment is enforced by the OS upgrade orchestrator at install time.

Options:
  --output-dir DIR               Parent for results (default: .)
  --policy FILE                  Policy KEY=VALUE file
  --live-check                   Read-only DNS/HTTP/TCP re-check
  --network-timeout SECONDS      Live-check timeout (default: 10)
  --keep-directory               Keep result directory after tar.gz
  --bringup-mode MODE            DEPRECATED; ignored for Phase 1 verdict
  --help                         Show this help
  --version                      Show version

Canonical recommended_action values:
  RUN_OS_UPGRADE | NO_OS_UPGRADE_REQUIRED | UNSUPPORTED | BLOCKED

Exit codes:
  0   READY
  10  READY_WITH_WARNINGS
  20  BLOCKED
  2   CLI / input error
  3   Integrity / internal error

Read-only: never mutates the host, APT, shells, mounts, or collector input.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --collection)
        [[ $# -ge 2 ]] || die_cli "--collection requires a value"
        COLLECTION_PATH="$2"; shift 2 ;;
      --package-source-mode)
        [[ $# -ge 2 ]] || die_cli "--package-source-mode requires a value"
        PACKAGE_SOURCE_MODE="$2"; shift 2 ;;
      --package-source-url)
        [[ $# -ge 2 ]] || die_cli "--package-source-url requires a value"
        PACKAGE_SOURCE_URL="$2"; shift 2 ;;
      --bringup-mode)
        [[ $# -ge 2 ]] || die_cli "--bringup-mode requires a value"
        BRINGUP_MODE="$2"
        BRINGUP_MODE_LEGACY_SET=1
        shift 2 ;;
      --execution-profile)
        [[ $# -ge 2 ]] || die_cli "--execution-profile requires a value"
        EXECUTION_PROFILE="$2"; shift 2 ;;
      --snapshot-reference)
        [[ $# -ge 2 ]] || die_cli "--snapshot-reference requires a value"
        SNAPSHOT_REFERENCE="$2"; shift 2 ;;
      --backup-reference)
        [[ $# -ge 2 ]] || die_cli "--backup-reference requires a value"
        BACKUP_REFERENCE="$2"; shift 2 ;;
      --output-dir)
        [[ $# -ge 2 ]] || die_cli "--output-dir requires a value"
        OUTPUT_DIR="$2"; shift 2 ;;
      --policy)
        [[ $# -ge 2 ]] || die_cli "--policy requires a value"
        POLICY_FILE="$2"; shift 2 ;;
      --live-check)
        LIVE_CHECK=1; shift ;;
      --network-timeout)
        [[ $# -ge 2 ]] || die_cli "--network-timeout requires a value"
        NETWORK_TIMEOUT="$2"; shift 2 ;;
      --keep-directory)
        KEEP_DIRECTORY=1; shift ;;
      --help|-h)
        usage; exit 0 ;;
      --version)
        printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      *)
        die_cli "unknown option: $1" ;;
    esac
  done
}

validate_cli() {
  [[ -n "$COLLECTION_PATH" ]] || die_cli "--collection is required"
  [[ -n "$PACKAGE_SOURCE_MODE" ]] || die_cli "--package-source-mode is required"

  case "$PACKAGE_SOURCE_MODE" in
    direct|cache|mirror) ;;
    *) die_cli "invalid --package-source-mode: $PACKAGE_SOURCE_MODE (expected direct|cache|mirror)" ;;
  esac

  if [[ -z "$EXECUTION_PROFILE" ]]; then
    EXECUTION_PROFILE="production"
  fi
  case "$EXECUTION_PROFILE" in
    production|discovery) ;;
    *) die_cli "invalid --execution-profile: $EXECUTION_PROFILE (expected production|discovery)" ;;
  esac

  if [[ "$BRINGUP_MODE_LEGACY_SET" -eq 1 ]]; then
    case "$BRINGUP_MODE" in
      online|offline|"") ;;
      *) die_cli "invalid --bringup-mode: $BRINGUP_MODE (expected online|offline); option is deprecated" ;;
    esac
    log_warn "DEPRECATED: --bringup-mode is ignored for Phase 1 OS-only readiness (recorded as informational legacy field only)"
  else
    BRINGUP_MODE=""
  fi

  if [[ "$PACKAGE_SOURCE_MODE" == "cache" || "$PACKAGE_SOURCE_MODE" == "mirror" ]]; then
    [[ -n "$PACKAGE_SOURCE_URL" ]] || die_cli "--package-source-url is required for $PACKAGE_SOURCE_MODE mode"
  fi

  if [[ ! "$NETWORK_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$NETWORK_TIMEOUT" -lt 1 ]]; then
    die_cli "--network-timeout must be a positive integer"
  fi

  if [[ ! -e "$COLLECTION_PATH" ]]; then
    die_cli "collection path does not exist: $COLLECTION_PATH"
  fi
}

apply_profile_snapshot_policy() {
  if [[ "$EXECUTION_PROFILE" == "discovery" ]]; then
    POLICY_REQUIRE_SNAPSHOT_OR_BACKUP="${POLICY_DISCOVERY_REQUIRE_SNAPSHOT_OR_BACKUP}"
    SNAPSHOT_REQUIRED=false
  else
    POLICY_REQUIRE_SNAPSHOT_OR_BACKUP="${POLICY_PRODUCTION_REQUIRE_SNAPSHOT_OR_BACKUP}"
    SNAPSHOT_REQUIRED=true
  fi
}

# ---------------------------------------------------------------------------
# Policy load
# ---------------------------------------------------------------------------
load_policy() {
  local f="$POLICY_FILE"
  [[ -f "$f" ]] || die_cli "policy file not found: $f"
  # Parse into POLICY_* via pf_parse_policy which uses PREFIX_KEY
  # Our parser sets PREFIX_KEY; we map known keys.
  local tmp_prefix="PFPO"
  # Clear previous
  if ! pf_parse_policy "$f" "$tmp_prefix"; then
    die_cli "failed to parse policy file: $f"
  fi
  # Copy known keys if set
  local keys=(
    MIN_SUPPORTED_DP_VERSION TARGET_DP_VERSION TARGET_OS_VERSION
    MIN_ROOT_AVAILABLE_BYTES MIN_BOOT_AVAILABLE_BYTES MIN_AELLADATA_AVAILABLE_BYTES
    MIN_INODE_AVAILABLE_PERCENT REQUIRE_AELLA_BASH REQUIRE_ROOT_BASH
    REQUIRE_SNAPSHOT_OR_BACKUP DEFAULT_EXECUTION_PROFILE
    PRODUCTION_REQUIRE_SNAPSHOT_OR_BACKUP DISCOVERY_REQUIRE_SNAPSHOT_OR_BACKUP
    DISCOVERY_REQUIRE_DISPOSABLE_VM_ACK DISCOVERY_DEFAULT_MAX_HOPS
    DISCOVERY_REQUIRE_NEW_PREFLIGHT_AFTER_HOP DISCOVERY_CAPTURE_PACKAGES
    DISCOVERY_CAPTURE_FILE_CHANGES DISCOVERY_CAPTURE_PYTHON_INVENTORY
    DISCOVERY_PRESERVE_APT_CACHE PHASE2_CHECKS_AFFECT_OS_PREFLIGHT
    MISSING_PHASE2_BUNDLE_WHEN_PHASE2_NOT_REQUIRED
    THIRD_PARTY_REPOSITORIES AELLADATA_NOT_SEPARATE_MOUNT UNKNOWN_NTP_STATUS
    MISSING_PACKAGE_SOURCE_EVIDENCE CRITICAL_HELD_PACKAGES
    SUPPORTED_COLLECTOR_SCRIPT_VERSIONS SUPPORTED_COLLECTOR_SCHEMA_VERSIONS
    REJECTED_REFERENCE_PLACEHOLDERS PROJECT_MANAGES_CRITICAL_HOLDS
  )
  local k varname
  for k in "${keys[@]}"; do
    varname="${tmp_prefix}_${k}"
    if [[ -n "${!varname+x}" && -n "${!varname}" ]]; then
      printf -v "POLICY_${k}" '%s' "${!varname}"
    fi
  done

  # Type checks
  for k in MIN_ROOT_AVAILABLE_BYTES MIN_BOOT_AVAILABLE_BYTES MIN_AELLADATA_AVAILABLE_BYTES MIN_INODE_AVAILABLE_PERCENT; do
    varname="POLICY_${k}"
    if [[ ! "${!varname}" =~ ^[0-9]+$ ]]; then
      die_cli "policy $k must be an integer"
    fi
  done

  if [[ -z "$EXECUTION_PROFILE" ]]; then
    EXECUTION_PROFILE="production"
  fi
  apply_profile_snapshot_policy
}

write_effective_policy() {
  local out="$1"
  cat >"$out" <<EOF
# Effective policy used by ${SCRIPT_NAME} ${SCRIPT_VERSION}
# Source: ${POLICY_FILE}

MIN_SUPPORTED_DP_VERSION=${POLICY_MIN_SUPPORTED_DP_VERSION}
TARGET_DP_VERSION=${POLICY_TARGET_DP_VERSION}
TARGET_OS_VERSION=${POLICY_TARGET_OS_VERSION}
MIN_ROOT_AVAILABLE_BYTES=${POLICY_MIN_ROOT_AVAILABLE_BYTES}
MIN_BOOT_AVAILABLE_BYTES=${POLICY_MIN_BOOT_AVAILABLE_BYTES}
MIN_AELLADATA_AVAILABLE_BYTES=${POLICY_MIN_AELLADATA_AVAILABLE_BYTES}
MIN_INODE_AVAILABLE_PERCENT=${POLICY_MIN_INODE_AVAILABLE_PERCENT}
REQUIRE_AELLA_BASH=${POLICY_REQUIRE_AELLA_BASH}
REQUIRE_ROOT_BASH=${POLICY_REQUIRE_ROOT_BASH}
REQUIRE_SNAPSHOT_OR_BACKUP=${POLICY_REQUIRE_SNAPSHOT_OR_BACKUP}
DEFAULT_EXECUTION_PROFILE=${POLICY_DEFAULT_EXECUTION_PROFILE}
PRODUCTION_REQUIRE_SNAPSHOT_OR_BACKUP=${POLICY_PRODUCTION_REQUIRE_SNAPSHOT_OR_BACKUP}
DISCOVERY_REQUIRE_SNAPSHOT_OR_BACKUP=${POLICY_DISCOVERY_REQUIRE_SNAPSHOT_OR_BACKUP}
DISCOVERY_REQUIRE_DISPOSABLE_VM_ACK=${POLICY_DISCOVERY_REQUIRE_DISPOSABLE_VM_ACK}
DISCOVERY_DEFAULT_MAX_HOPS=${POLICY_DISCOVERY_DEFAULT_MAX_HOPS}
DISCOVERY_REQUIRE_NEW_PREFLIGHT_AFTER_HOP=${POLICY_DISCOVERY_REQUIRE_NEW_PREFLIGHT_AFTER_HOP}
DISCOVERY_CAPTURE_PACKAGES=${POLICY_DISCOVERY_CAPTURE_PACKAGES}
DISCOVERY_CAPTURE_FILE_CHANGES=${POLICY_DISCOVERY_CAPTURE_FILE_CHANGES}
DISCOVERY_CAPTURE_PYTHON_INVENTORY=${POLICY_DISCOVERY_CAPTURE_PYTHON_INVENTORY}
DISCOVERY_PRESERVE_APT_CACHE=${POLICY_DISCOVERY_PRESERVE_APT_CACHE}
PHASE2_CHECKS_AFFECT_OS_PREFLIGHT=${POLICY_PHASE2_CHECKS_AFFECT_OS_PREFLIGHT}
EXECUTION_PROFILE=${EXECUTION_PROFILE}
MISSING_PHASE2_BUNDLE_WHEN_PHASE2_NOT_REQUIRED=${POLICY_MISSING_PHASE2_BUNDLE_WHEN_PHASE2_NOT_REQUIRED}
THIRD_PARTY_REPOSITORIES=${POLICY_THIRD_PARTY_REPOSITORIES}
AELLADATA_NOT_SEPARATE_MOUNT=${POLICY_AELLADATA_NOT_SEPARATE_MOUNT}
UNKNOWN_NTP_STATUS=${POLICY_UNKNOWN_NTP_STATUS}
MISSING_PACKAGE_SOURCE_EVIDENCE=${POLICY_MISSING_PACKAGE_SOURCE_EVIDENCE}
CRITICAL_HELD_PACKAGES=${POLICY_CRITICAL_HELD_PACKAGES}
SUPPORTED_COLLECTOR_SCRIPT_VERSIONS=${POLICY_SUPPORTED_COLLECTOR_SCRIPT_VERSIONS}
SUPPORTED_COLLECTOR_SCHEMA_VERSIONS=${POLICY_SUPPORTED_COLLECTOR_SCHEMA_VERSIONS}
REJECTED_REFERENCE_PLACEHOLDERS=${POLICY_REJECTED_REFERENCE_PLACEHOLDERS}
PROJECT_MANAGES_CRITICAL_HOLDS=${POLICY_PROJECT_MANAGES_CRITICAL_HOLDS}
EOF
}

# ---------------------------------------------------------------------------
# Check recording
# ---------------------------------------------------------------------------
# add_check ID CATEGORY STATUS SEVERITY OBSERVED EXPECTED REASON REMEDIATION EVIDENCE_FILE EVIDENCE_KEY
add_check() {
  local check_id="$1" category="$2" status="$3" severity="$4"
  local observed="$5" expected="$6" reason="$7" remediation="$8"
  local evidence_file="$9" evidence_key="${10}"
  local obs_safe exp_safe reason_safe rem_safe
  # TSV-safe: replace tabs/newlines
  obs_safe="$(printf '%s' "$observed" | tr '\t\n\r' '   ')"
  exp_safe="$(printf '%s' "$expected" | tr '\t\n\r' '   ')"
  reason_safe="$(printf '%s' "$reason" | tr '\t\n\r' '   ')"
  rem_safe="$(printf '%s' "$remediation" | tr '\t\n\r' '   ')"

  local line
  printf -v line '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$check_id" "$category" "$status" "$severity" \
    "$obs_safe" "$exp_safe" "$reason_safe" "$rem_safe" \
    "$evidence_file" "$evidence_key"
  CHECKS_TSV_BODY+="$line"

  local json_part
  json_part="$(cat <<JEOF
    {
      "check_id": "$(pf_json_escape "$check_id")",
      "category": "$(pf_json_escape "$category")",
      "status": "$(pf_json_escape "$status")",
      "severity": "$(pf_json_escape "$severity")",
      "observed": $(pf_json_str_or_null "$observed"),
      "expected": $(pf_json_str_or_null "$expected"),
      "reason": "$(pf_json_escape "$reason")",
      "remediation": "$(pf_json_escape "$remediation")",
      "evidence": "$(pf_json_escape "${evidence_file}:${evidence_key}")"
    }
JEOF
)"
  CHECKS_JSON_PARTS+=("$json_part")

  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    WARN) WARNING_COUNT=$((WARNING_COUNT + 1)) ;;
    FAIL)
      if [[ "$severity" == "BLOCKER" ]]; then
        BLOCKER_COUNT=$((BLOCKER_COUNT + 1))
      else
        WARNING_COUNT=$((WARNING_COUNT + 1))
      fi
      ;;
    UNKNOWN) UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)) ;;
    SKIPPED) SKIPPED_COUNT=$((SKIPPED_COUNT + 1)) ;;
  esac
}

tsv_escape_field() { printf '%s' "$1" | tr '\t\n\r' '   '; }

# ---------------------------------------------------------------------------
# Archive safety / input prepare
# ---------------------------------------------------------------------------
is_safe_archive_entry() {
  local entry="$1"
  # Reject absolute paths
  [[ "$entry" != /* ]] || return 1
  # Reject .. components
  [[ "$entry" != *..* ]] || return 1
  # Reject empty
  [[ -n "$entry" ]] || return 1
  return 0
}

validate_archive_entries() {
  local archive="$1"
  local entries tops=()
  local e top
  while IFS= read -r e; do
    [[ -z "$e" ]] && continue
    is_safe_archive_entry "$e" || {
      log_error "unsafe archive entry rejected: $e"
      return 1
    }
    top="${e%%/*}"
    [[ -n "$top" ]] || continue
    local found=0 t
    for t in "${tops[@]+"${tops[@]}"}"; do
      [[ "$t" == "$top" ]] && found=1 && break
    done
    if [[ "$found" -eq 0 ]]; then
      tops+=("$top")
    fi
  done < <(tar -tzf "$archive" 2>/dev/null)

  if [[ ${#tops[@]} -ne 1 ]]; then
    log_error "archive must contain exactly one top-level root (found ${#tops[@]})"
    return 1
  fi
  # Reject device files / weird types if GNU tar supports --listing details
  if tar --help 2>/dev/null | grep -q -- '--warning'; then
    :
  fi
  printf '%s' "${tops[0]}"
  return 0
}

extract_collection() {
  local archive="$1"
  local dest="$2"
  local top
  top="$(validate_archive_entries "$archive")" || return 1
  mkdir -p "$dest" || return 1
  # Extract without absolute paths; strip leading ./ if any
  if ! tar -xzf "$archive" -C "$dest" 2>/dev/null; then
    log_error "failed to extract archive"
    return 1
  fi
  # Verify no escape via symlink after extract
  local root="${dest}/${top}"
  if [[ ! -d "$root" ]]; then
    log_error "extracted root missing: $root"
    return 1
  fi
  # Check symlinks stay inside root
  local link target
  while IFS= read -r link; do
    [[ -z "$link" ]] && continue
    if [[ -L "$link" ]]; then
      target="$(readlink -f "$link" 2>/dev/null || true)"
      if [[ -n "$target" && "$target" != "$root"* ]]; then
        log_error "symlink escapes collection root: $link -> $target"
        return 1
      fi
    fi
  done < <(find "$root" -type l 2>/dev/null || true)
  printf '%s' "$root"
}

prepare_input() {
  local path="$COLLECTION_PATH"
  if [[ -d "$path" ]]; then
    INPUT_TYPE="directory"
    COLLECTION_ROOT="$(cd "$path" && pwd)"
  elif [[ -f "$path" ]]; then
    case "$path" in
      *.tar.gz|*.tgz)
        INPUT_TYPE="tar.gz"
        TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dp-preflight-XXXXXX")"
        OWNED_TMP=1
        COLLECTION_ROOT="$(extract_collection "$path" "$TMP_DIR")" || die_internal "archive extraction failed"
        ;;
      *)
        die_cli "collection path must be a directory or .tar.gz: $path"
        ;;
    esac
  else
    die_cli "collection path not found: $path"
  fi
  log_info "collection root: $COLLECTION_ROOT (type=$INPUT_TYPE)"
}

# ---------------------------------------------------------------------------
# Collection structure / integrity
# ---------------------------------------------------------------------------
require_file() {
  local rel="$1"
  [[ -f "${COLLECTION_ROOT}/${rel}" ]]
}

require_dir() {
  local rel="$1"
  [[ -d "${COLLECTION_ROOT}/${rel}" ]]
}

validate_collection_structure() {
  local missing=()
  local f
  for f in summary.json summary.txt findings.txt commands.tsv collection.log; do
    require_file "$f" || missing+=("$f")
  done
  for f in system storage apt network dp upgrade data-preservation; do
    require_dir "$f" || missing+=("${f}/")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    add_check INPUT_STRUCTURE integrity FAIL BLOCKER \
      "missing:${missing[*]}" "required collector layout" \
      "Collector result is missing required files or directories" \
      "Re-run collect-dp-upgrade-readiness.sh and provide a complete archive" \
      "collection root" "layout"
    INTEGRITY_STATUS="invalid"
    return 1
  fi

  add_check INPUT_STRUCTURE integrity PASS INFO \
    "ok" "required collector layout" \
    "Required top-level files and directories are present" \
    "none" "collection root" "layout"
  return 0
}

validate_summary_json() {
  local sj="${COLLECTION_ROOT}/summary.json"
  JSON_PARSER_USED="$(pf_detect_json_parser)"
  if ! pf_json_validate_file "$sj"; then
    add_check INPUT_JSON_VALID integrity FAIL BLOCKER \
      "invalid" "valid JSON" \
      "summary.json could not be parsed (parser=${JSON_PARSER_USED})" \
      "Re-collect evidence; do not hand-edit summary.json" \
      "summary.json" "root"
    INTEGRITY_STATUS="invalid"
    return 1
  fi
  add_check INPUT_JSON_VALID integrity PASS INFO \
    "valid(${JSON_PARSER_USED})" "valid JSON" \
    "summary.json parsed successfully" \
    "none" "summary.json" "root"
  return 0
}

csv_contains() {
  local csv="$1" item="$2"
  local IFS=','
  local x
  for x in $csv; do
    [[ "$x" == "$item" ]] && return 0
  done
  return 1
}

load_summary_fields() {
  local sj="${COLLECTION_ROOT}/summary.json"
  COLLECTOR_SCHEMA_VERSION="$(pf_json_get "$sj" schema_version)"
  COLLECTOR_SCRIPT_VERSION="$(pf_json_get "$sj" script_version)"
  COLLECTION_ID="$(pf_json_get "$sj" collection_id)"
  HOSTNAME_VAL="$(pf_json_get "$sj" hostname)"
  OS_VERSION="$(pf_json_get "$sj" os.version_id)"
  OS_CODENAME="$(pf_json_get "$sj" os.codename)"
  DP_VERSION_RAW="$(pf_json_get "$sj" dp.version)"
  local dp_status
  dp_status="$(pf_json_get "$sj" dp.version_status)"
  ROLE_CANON="$(pf_canonical_role "$(pf_json_get "$sj" dp.role)")"
  CLUSTER_DETECTED="$(pf_json_get "$sj" dp.cluster_detected)"
  [[ -z "$CLUSTER_DETECTED" ]] && CLUSTER_DETECTED="false"
  WORKER_IPS_CSV="$(pf_json_get "$sj" dp.worker_ips)"
  COLLECTION_STATUS="$(pf_json_get "$sj" collection.status)"

  if [[ -n "$DP_VERSION_RAW" ]]; then
    DP_VERSION_NORM="$(pf_normalize_version "$DP_VERSION_RAW" || true)"
  fi

  # Version support check
  if csv_contains "$POLICY_SUPPORTED_COLLECTOR_SCHEMA_VERSIONS" "$COLLECTOR_SCHEMA_VERSION" && \
     csv_contains "$POLICY_SUPPORTED_COLLECTOR_SCRIPT_VERSIONS" "$COLLECTOR_SCRIPT_VERSION"; then
    add_check COLLECTOR_VERSION_SUPPORTED integrity PASS INFO \
      "script=${COLLECTOR_SCRIPT_VERSION} schema=${COLLECTOR_SCHEMA_VERSION}" \
      "supported versions" \
      "Collector version is supported" \
      "none" "summary.json" "script_version"
  else
    add_check COLLECTOR_VERSION_SUPPORTED integrity FAIL BLOCKER \
      "script=${COLLECTOR_SCRIPT_VERSION} schema=${COLLECTOR_SCHEMA_VERSION}" \
      "script in [${POLICY_SUPPORTED_COLLECTOR_SCRIPT_VERSIONS}] schema in [${POLICY_SUPPORTED_COLLECTOR_SCHEMA_VERSIONS}]" \
      "Unsupported collector version" \
      "Re-collect with a supported collect-dp-upgrade-readiness.sh" \
      "summary.json" "script_version"
    INTEGRITY_STATUS="unsupported"
  fi

  if [[ "$COLLECTION_STATUS" == "complete" ]]; then
    add_check COLLECTION_STATUS integrity PASS INFO \
      "$COLLECTION_STATUS" "complete|partial(with critical evidence)" \
      "Collection status is complete" \
      "none" "summary.json" "collection.status"
  elif [[ "$COLLECTION_STATUS" == "partial" ]]; then
    add_check COLLECTION_STATUS integrity WARN WARNING \
      "$COLLECTION_STATUS" "complete preferred" \
      "Collection is partial; continuing if critical evidence exists" \
      "Re-run collector if preflight reports missing evidence" \
      "summary.json" "collection.status"
  else
    add_check COLLECTION_STATUS integrity FAIL BLOCKER \
      "${COLLECTION_STATUS:-unknown}" "complete|partial" \
      "Collection status missing or unknown" \
      "Re-run collect-dp-upgrade-readiness.sh" \
      "summary.json" "collection.status"
  fi
}

check_required_evidence() {
  local critical_missing=()
  local sj="${COLLECTION_ROOT}/summary.json"
  local need
  for need in \
    system/users-and-shells.txt \
    storage/target-filesystems.txt \
    apt/held-packages.txt \
    apt/dpkg-audit.txt \
    apt/dpkg-status-check.txt \
    apt/apt-locks.txt \
    apt/source-uris.txt \
    network/ntp-status.txt \
    dp/important-paths.txt \
    dp/version-evidence.txt \
    upgrade/os-upgrade-state.txt
  do
    require_file "$need" || critical_missing+=("$need")
  done

  # Critical summary fields (Phase 1 OS-only: DP product version is not required)
  [[ -n "$OS_VERSION" ]] || critical_missing+=("os.version_id")

  if [[ ${#critical_missing[@]} -gt 0 ]]; then
    add_check REQUIRED_EVIDENCE_PRESENT integrity FAIL BLOCKER \
      "missing:${critical_missing[*]}" "critical evidence set" \
      "Critical evidence required for verdict is missing" \
      "Re-run collector; ensure checks for shells/storage/apt/ntp/dp succeed" \
      "collection root" "critical_evidence"
    return 1
  fi
  add_check REQUIRED_EVIDENCE_PRESENT integrity PASS INFO \
    "present" "critical evidence set" \
    "Critical evidence files and fields are present" \
    "none" "collection root" "critical_evidence"
  INTEGRITY_STATUS="valid"
  return 0
}

# ---------------------------------------------------------------------------
# Upgrade path resolution
# ---------------------------------------------------------------------------
resolve_upgrade_path() {
  local os="$OS_VERSION"
  local dp="$DP_VERSION_NORM"
  local hops=()
  PHASE1_REQUIRED=false
  PHASE2_REQUIRED=false
  RECOMMENDED_ACTION="NONE"
  SUPPORTED_START=false
  UPGRADE_REQUIRED=false
  PHASE1_HOPS_CSV=""

  # OS support
  case "$os" in
    16.04|18.04|20.04|22.04|24.04)
      add_check OS_VERSION_SUPPORTED path PASS INFO \
        "$os ($OS_CODENAME)" "16.04|18.04|20.04|22.04|24.04" \
        "Ubuntu version is in the supported LTS hop chain" \
        "none" "summary.json" "os.version_id"
      ;;
    *)
      RECOMMENDED_ACTION="UNSUPPORTED"
      OS_UPGRADE_REQUIRED=false
      UPGRADE_REQUIRED=false
      add_check OS_VERSION_SUPPORTED path FAIL BLOCKER \
        "${os:-unknown}" "16.04|18.04|20.04|22.04|24.04" \
        "Unsupported Ubuntu version for this upgrade path" \
        "This project only supports Ubuntu LTS hops 16.04→24.04" \
        "summary.json" "os.version_id"
      return
      ;;
  esac

  # DP version: Phase 1 diagnostic only (never BLOCKER). OS hops resolve from OS alone.
  local dp_status
  dp_status="$(pf_json_get "${COLLECTION_ROOT}/summary.json" dp.version_status)"
  if [[ "$dp_status" == "conflicting" ]]; then
    add_check DP_VERSION_DETECTED path PASS INFO \
      "conflicting raw=${DP_VERSION_RAW}" "informational in Phase 1" \
      "DP version evidence conflicts; ignored by Phase 1 OS-only policy (DP_VERSION_GATE=SKIPPED_PHASE1_OS_ONLY)" \
      "none" "summary.json" "dp.version_status"
    add_check DP_VERSION_SUPPORTED path PASS INFO \
      "skipped" "not gated in Phase 1" \
      "DP_VERSION_GATE=SKIPPED_PHASE1_OS_ONLY" \
      "none" "summary.json" "dp.version"
  elif [[ -z "$DP_VERSION_RAW" || -z "$DP_VERSION_NORM" ]]; then
    add_check DP_VERSION_DETECTED path PASS INFO \
      "unknown" "optional in Phase 1" \
      "DP version undetermined; Phase 1 continues (DP_VERSION_GATE=SKIPPED_PHASE1_OS_ONLY)" \
      "none" "summary.json" "dp.version"
    add_check DP_VERSION_SUPPORTED path PASS INFO \
      "skipped" "not gated in Phase 1" \
      "DP_VERSION_GATE=SKIPPED_PHASE1_OS_ONLY" \
      "none" "summary.json" "dp.version"
  else
    add_check DP_VERSION_DETECTED path PASS INFO \
      "raw=${DP_VERSION_RAW} normalized=${DP_VERSION_NORM}" "detectable version" \
      "DP version detected (informational; not a Phase 1 gate)" \
      "none" "summary.json" "dp.version"
    local cmp
    cmp="$(pf_compare_versions "$DP_VERSION_NORM" "$POLICY_MIN_SUPPORTED_DP_VERSION")"
    if [[ "$cmp" == "lt" ]]; then
      add_check DP_VERSION_SUPPORTED path PASS INFO \
        "$DP_VERSION_NORM" "Phase 1 does not gate on DP min version" \
        "DP below former minimum ${POLICY_MIN_SUPPORTED_DP_VERSION}; ignored (DP_VERSION_GATE=SKIPPED_PHASE1_OS_ONLY)" \
        "none" "summary.json" "dp.version"
    elif [[ "$cmp" == "unknown" ]]; then
      add_check DP_VERSION_SUPPORTED path PASS INFO \
        "$DP_VERSION_NORM" "Phase 1 does not gate on DP version compare" \
        "DP_VERSION_GATE=SKIPPED_PHASE1_OS_ONLY" \
        "none" "summary.json" "dp.version"
    else
      add_check DP_VERSION_SUPPORTED path PASS INFO \
        "$DP_VERSION_NORM" ">= ${POLICY_MIN_SUPPORTED_DP_VERSION}" \
        "DP version meets former minimum (informational)" \
        "none" "summary.json" "dp.version"
    fi
  fi
  # Phase 1 supported start is OS-series based, not DP product version.
  SUPPORTED_START=true

  # Phase 1 hops (OS series only)
  case "$os" in
    16.04)
      PHASE1_REQUIRED=true
      hops=("16.04->18.04" "18.04->20.04" "20.04->22.04" "22.04->24.04")
      ;;
    18.04)
      PHASE1_REQUIRED=true
      hops=("18.04->20.04" "20.04->22.04" "22.04->24.04")
      ;;
    20.04)
      PHASE1_REQUIRED=true
      hops=("20.04->22.04" "22.04->24.04")
      ;;
    22.04)
      PHASE1_REQUIRED=true
      hops=("22.04->24.04")
      ;;
    24.04)
      PHASE1_REQUIRED=false
      hops=()
      ;;
  esac

  # Phase 1 OS-only plan. Phase 2 is never evaluated for readiness.
  PHASE2_REQUIRED=false
  PHASE2_EVALUATED=false
  OS_UPGRADE_REQUIRED=false
  NEXT_HOP=""
  local cmp_target
  cmp_target="$(pf_compare_versions "$DP_VERSION_NORM" "$POLICY_TARGET_DP_VERSION")"

  local hops_txt=""
  # Bash 4.3 + set -u: empty "${hops[*]}" is unbound; length-guard before expand.
  if ((${#hops[@]} > 0)); then
    hops_txt="$(IFS=','; printf '%s' "${hops[*]}")"
  fi
  PHASE1_HOPS_CSV="$hops_txt"
  if [[ ${#hops[@]} -gt 0 ]]; then
    NEXT_HOP="${hops[0]}"
  fi

  if [[ "$PHASE1_REQUIRED" == "true" ]]; then
    RECOMMENDED_ACTION="RUN_OS_UPGRADE"
    UPGRADE_REQUIRED=true
    OS_UPGRADE_REQUIRED=true
  else
    RECOMMENDED_ACTION="NO_OS_UPGRADE_REQUIRED"
    UPGRADE_REQUIRED=false
    OS_UPGRADE_REQUIRED=false
  fi

  add_check UPGRADE_PATH_RESOLVED path PASS INFO \
    "phase=OS_ONLY os_upgrade_required=${OS_UPGRADE_REQUIRED} hops=${hops_txt:-none} next_hop=${NEXT_HOP:-none} action=${RECOMMENDED_ACTION} phase2_evaluated=false profile=${EXECUTION_PROFILE}" \
    "OS-only plan" \
    "Upgrade path resolved for Phase 1 OS hops only; Phase 2 was not evaluated" \
    "none" "summary.json" "upgrade_plan"

  if [[ "$os" == "24.04" && "$cmp_target" == "lt" ]]; then
    add_check PHASE2_NOT_EVALUATED path PASS INFO \
      "dp=${DP_VERSION_NORM} target_dp=${POLICY_TARGET_DP_VERSION}" "separate Phase 2 workflow" \
      "OS is at 24.04; DP Python/Py3 bringup was not evaluated by this OS-only preflight" \
      "After collecting a new baseline, run the separate Phase 2 readiness workflow if needed" \
      "summary.json" "upgrade_plan.phase2_evaluated"
  elif [[ "$PHASE1_REQUIRED" == "true" ]]; then
    add_check PHASE2_NOT_EVALUATED path PASS INFO \
      "deferred" "separate Phase 2 after Ubuntu 24.04" \
      "Phase 2 (DP Python/Py3 bringup) is not part of Phase 1 OS preflight" \
      "Reach Ubuntu 24.04 via OS hops, then run a separate Phase 2 workflow" \
      "summary.json" "upgrade_plan.phase2_evaluated"
  else
    add_check PHASE2_NOT_EVALUATED path PASS INFO \
      "not_evaluated" "separate Phase 2 workflow" \
      "No OS upgrade required; Phase 2 was still not evaluated by this tool" \
      "Use the separate Phase 2 workflow if DP Py3 bringup is needed" \
      "summary.json" "upgrade_plan.phase2_evaluated"
  fi

  if [[ "$PHASE1_REQUIRED" == "true" && "$cmp_target" != "lt" ]]; then
    add_check POST_OS_DP_REVALIDATION path PASS INFO \
      "dp_already=${DP_VERSION_NORM} on os=${os}" "informational" \
      "DP software reports ${DP_VERSION_NORM}; OS still requires LTS hops. Intermediate DP application health is not a Phase 1 success criterion." \
      "After Ubuntu 24.04, re-collect and use the separate Phase 2 workflow if needed" \
      "summary.json" "dp.version"
  fi
}

# ---------------------------------------------------------------------------
# Individual check groups
# ---------------------------------------------------------------------------
is_placeholder_reference() {
  local ref="$1"
  local trimmed low
  trimmed="$(printf '%s' "$ref" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$trimmed" ]] && return 0
  low="$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')"
  csv_contains "$POLICY_REJECTED_REFERENCE_PLACEHOLDERS" "$low"
}

check_snapshot() {
  if [[ "${OS_UPGRADE_REQUIRED:-$UPGRADE_REQUIRED}" == "false" ]]; then
    add_check SNAPSHOT_OR_BACKUP_CONFIRMED safety PASS INFO \
      "not_required_for_noop" "optional when no OS upgrade" \
      "No OS upgrade recommended; snapshot gate not required" \
      "none" "cli" "snapshot_reference"
    return
  fi

  local snap_ok=0 bak_ok=0
  if [[ -n "$SNAPSHOT_REFERENCE" ]] && ! is_placeholder_reference "$SNAPSHOT_REFERENCE"; then
    snap_ok=1
  elif [[ -n "$SNAPSHOT_REFERENCE" ]]; then
    if [[ "$EXECUTION_PROFILE" == "discovery" ]]; then
      add_check SNAPSHOT_OR_BACKUP_CONFIRMED safety WARN WARNING \
        "placeholder:$(printf '%s' "$SNAPSHOT_REFERENCE" | tr '\t' ' ')" "non-placeholder or omit" \
        "Snapshot reference looks like a placeholder; discovery allows omitting snapshot" \
        "Provide a real reference or omit for disposable discovery VMs" \
        "cli" "snapshot_reference"
      return
    fi
    add_check SNAPSHOT_OR_BACKUP_CONFIRMED safety FAIL BLOCKER \
      "placeholder:$(printf '%s' "$SNAPSHOT_REFERENCE" | tr '\t' ' ')" "non-placeholder reference" \
      "Snapshot reference looks like a placeholder and is rejected" \
      "Provide a real hypervisor snapshot ID/name/ticket, or a verified backup reference" \
      "cli" "snapshot_reference"
    return
  fi
  if [[ -n "$BACKUP_REFERENCE" ]] && ! is_placeholder_reference "$BACKUP_REFERENCE"; then
    bak_ok=1
  elif [[ -n "$BACKUP_REFERENCE" ]]; then
    if [[ "$EXECUTION_PROFILE" == "discovery" ]]; then
      add_check SNAPSHOT_OR_BACKUP_CONFIRMED safety WARN WARNING \
        "placeholder" "non-placeholder or omit" \
        "Backup reference looks like a placeholder; discovery allows omitting backup" \
        "Provide a verified backup reference or omit for disposable discovery VMs" \
        "cli" "backup_reference"
      return
    fi
    add_check SNAPSHOT_OR_BACKUP_CONFIRMED safety FAIL BLOCKER \
      "placeholder" "non-placeholder reference" \
      "Backup reference looks like a placeholder and is rejected" \
      "Provide a verified full-backup reference" \
      "cli" "backup_reference"
    return
  fi

  if [[ "$snap_ok" -eq 0 && "$bak_ok" -eq 0 ]]; then
    if [[ "$EXECUTION_PROFILE" == "discovery" || "$POLICY_REQUIRE_SNAPSHOT_OR_BACKUP" != "true" ]]; then
      add_check SNAPSHOT_OR_BACKUP_CONFIRMED safety WARN WARNING \
        "none" "optional in discovery" \
        "No VM snapshot or backup reference supplied; discovery allows disposable VMs without rollback" \
        "Orchestrator install still requires --acknowledge-disposable-discovery-vm. Preflight does not create snapshots." \
        "cli" "snapshot_reference"
      return
    fi
    add_check SNAPSHOT_OR_BACKUP_CONFIRMED safety FAIL BLOCKER \
      "none" "snapshot-reference or backup-reference" \
      "No VM snapshot or verified full backup reference was supplied" \
      "Create and verify a restorable VM snapshot (or full backup), then re-run preflight with --snapshot-reference or --backup-reference. Preflight does not create snapshots." \
      "cli" "snapshot_reference"
    return
  fi

  if [[ "$ROLE_CANON" != "AIO" && "$ROLE_CANON" != "WORKER" && -n "$WORKER_IPS_CSV" ]]; then
    add_check SNAPSHOT_OR_BACKUP_CONFIRMED safety WARN WARNING \
      "single_reference_with_workers" "per-node or cluster-wide confirmation" \
      "External workers are listed; one reference does not prove every node is snapshotted" \
      "Confirm master and all worker snapshots/backups in the hypervisor/backup system before upgrade" \
      "cli" "snapshot_reference"
  else
    add_check SNAPSHOT_OR_BACKUP_CONFIRMED safety PASS INFO \
      "provided" "operator-confirmed reference" \
      "Snapshot or backup reference supplied (existence not verified by preflight)" \
      "Operator must verify restore capability in hypervisor/backup system" \
      "cli" "snapshot_reference"
  fi
}

check_shells() {
  local root_shell aella_shell
  root_shell="$(pf_json_get "${COLLECTION_ROOT}/summary.json" shells.root)"
  aella_shell="$(pf_json_get "${COLLECTION_ROOT}/summary.json" shells.aella)"

  if [[ "$POLICY_REQUIRE_ROOT_BASH" == "true" ]]; then
    if [[ -z "$root_shell" ]]; then
      add_check LOGIN_SHELL_ROOT safety FAIL BLOCKER \
        "unknown" "/bin/bash" \
        "root login shell unknown" \
        "Inspect getent passwd root; set shell to /bin/bash before upgrade (do not run from preflight)" \
        "summary.json" "shells.root"
    elif [[ "$root_shell" == "/bin/bash" || "$root_shell" == "/usr/bin/bash" ]]; then
      add_check LOGIN_SHELL_ROOT safety PASS INFO \
        "$root_shell" "/bin/bash" \
        "root shell is bash" \
        "none" "summary.json" "shells.root"
    else
      add_check LOGIN_SHELL_ROOT safety FAIL BLOCKER \
        "$root_shell" "/bin/bash" \
        "root login shell must be /bin/bash before upgrade" \
        "Suggested: sudo chsh -s /bin/bash root ; then re-collect evidence" \
        "summary.json" "shells.root"
    fi
  fi

  if [[ "$POLICY_REQUIRE_AELLA_BASH" == "true" ]]; then
    if [[ -z "$aella_shell" ]]; then
      add_check LOGIN_SHELL_AELLA safety FAIL BLOCKER \
        "unknown" "/bin/bash" \
        "aella login shell unknown" \
        "Inspect getent passwd aella; set shell to /bin/bash before upgrade" \
        "summary.json" "shells.aella"
    elif [[ "$aella_shell" == "/bin/bash" || "$aella_shell" == "/usr/bin/bash" ]]; then
      add_check LOGIN_SHELL_AELLA safety PASS INFO \
        "$aella_shell" "/bin/bash" \
        "aella shell is bash" \
        "none" "summary.json" "shells.aella"
    else
      add_check LOGIN_SHELL_AELLA safety FAIL BLOCKER \
        "$aella_shell" "/bin/bash" \
        "aella login shell must be /bin/bash before upgrade (aella_cli is not allowed)" \
        "Suggested: sudo chsh -s /bin/bash aella ; validate with getent passwd aella ; re-collect evidence" \
        "summary.json" "shells.aella"
    fi
  fi
}

_inode_avail_percent_for_path() {
  # Parse storage/target-filesystems.txt or df-inodes.txt
  local path="$1"
  local tf="${COLLECTION_ROOT}/storage/target-filesystems.txt"
  local line used free total pct
  if [[ -f "$tf" ]]; then
    line="$(awk -F'\t' -v p="$path" 'NR>1 && $1==p {print; exit}' "$tf")"
    if [[ -n "$line" ]]; then
      used="$(printf '%s' "$line" | cut -f8)"
      free="$(printf '%s' "$line" | cut -f9)"
      if [[ "$used" =~ ^[0-9]+$ && "$free" =~ ^[0-9]+$ ]]; then
        total=$((used + free))
        if [[ "$total" -gt 0 ]]; then
          pct=$(( free * 100 / total ))
          printf '%s' "$pct"
          return
        fi
      fi
    fi
  fi
  printf ''
}

check_storage() {
  local sj="${COLLECTION_ROOT}/summary.json"
  local root_avail boot_avail aella_avail mounted
  root_avail="$(pf_json_get "$sj" storage.root_available_bytes)"
  boot_avail="$(pf_json_get "$sj" storage.boot_available_bytes)"
  aella_avail="$(pf_json_get "$sj" storage.aelladata_available_bytes)"
  mounted="$(pf_json_get "$sj" storage.aelladata_mounted)"

  # AELLADATA present
  if grep -qE 'PRESENT[[:space:]].*/opt/aelladata' "${COLLECTION_ROOT}/dp/important-paths.txt" 2>/dev/null || \
     [[ -n "$aella_avail" ]]; then
    add_check AELLADATA_PRESENT storage PASS INFO \
      "present" "exists" \
      "/opt/aelladata is present in evidence" \
      "none" "dp/important-paths.txt" "aelladata"
  else
    add_check AELLADATA_PRESENT storage FAIL BLOCKER \
      "missing" "exists" \
      "/opt/aelladata is missing" \
      "Restore /opt/aelladata before upgrade" \
      "dp/important-paths.txt" "aelladata"
  fi

  # Root free space
  if [[ -z "$root_avail" ]]; then
    add_check ROOT_FREE_SPACE storage FAIL BLOCKER \
      "unknown" ">= ${POLICY_MIN_ROOT_AVAILABLE_BYTES}" \
      "Root free space unknown" \
      "Re-collect storage evidence" \
      "summary.json" "storage.root_available_bytes"
  elif [[ "$root_avail" -lt "$POLICY_MIN_ROOT_AVAILABLE_BYTES" ]]; then
    add_check ROOT_FREE_SPACE storage FAIL BLOCKER \
      "$root_avail" ">= ${POLICY_MIN_ROOT_AVAILABLE_BYTES}" \
      "Insufficient free space on /" \
      "Free space on / (project threshold ~12 GiB) then re-collect" \
      "summary.json" "storage.root_available_bytes"
  else
    add_check ROOT_FREE_SPACE storage PASS INFO \
      "$root_avail" ">= ${POLICY_MIN_ROOT_AVAILABLE_BYTES}" \
      "Root free space meets project threshold" \
      "none" "summary.json" "storage.root_available_bytes"
  fi

  # Boot free space
  if [[ -z "$boot_avail" ]]; then
    add_check BOOT_FREE_SPACE storage FAIL BLOCKER \
      "unknown" ">= ${POLICY_MIN_BOOT_AVAILABLE_BYTES}" \
      "/boot free space unknown" \
      "Re-collect storage evidence" \
      "summary.json" "storage.boot_available_bytes"
  elif [[ "$boot_avail" -lt "$POLICY_MIN_BOOT_AVAILABLE_BYTES" ]]; then
    add_check BOOT_FREE_SPACE storage FAIL BLOCKER \
      "$boot_avail" ">= ${POLICY_MIN_BOOT_AVAILABLE_BYTES}" \
      "Insufficient free space on /boot" \
      "Free space on /boot (project threshold ~512 MiB) then re-collect" \
      "summary.json" "storage.boot_available_bytes"
  else
    add_check BOOT_FREE_SPACE storage PASS INFO \
      "$boot_avail" ">= ${POLICY_MIN_BOOT_AVAILABLE_BYTES}" \
      "/boot free space meets project threshold" \
      "none" "summary.json" "storage.boot_available_bytes"
  fi

  # Separate mount warning
  if [[ "$mounted" == "true" ]]; then
    add_check AELLADATA_SEPARATE_MOUNT storage PASS INFO \
      "true" "optional separate mount" \
      "/opt/aelladata is on a separate mount" \
      "none" "summary.json" "storage.aelladata_mounted"
    # Free space for separate FS
    if [[ -n "$aella_avail" && "$aella_avail" -lt "$POLICY_MIN_AELLADATA_AVAILABLE_BYTES" ]]; then
      add_check AELLADATA_FREE_SPACE storage FAIL BLOCKER \
        "$aella_avail" ">= ${POLICY_MIN_AELLADATA_AVAILABLE_BYTES}" \
        "Insufficient free space on /opt/aelladata filesystem" \
        "Free space on the aelladata filesystem then re-collect" \
        "summary.json" "storage.aelladata_available_bytes"
    else
      add_check AELLADATA_FREE_SPACE storage PASS INFO \
        "${aella_avail:-n/a}" ">= ${POLICY_MIN_AELLADATA_AVAILABLE_BYTES} when separate" \
        "Aelladata free space OK or not separately constrained" \
        "none" "summary.json" "storage.aelladata_available_bytes"
    fi
  else
    if [[ "$POLICY_AELLADATA_NOT_SEPARATE_MOUNT" == "blocker" ]]; then
      add_check AELLADATA_SEPARATE_MOUNT storage FAIL BLOCKER \
        "false" "separate mount preferred" \
        "/opt/aelladata is not a separate mount" \
        "Consider placing /opt/aelladata on a dedicated filesystem (policy=blocker)" \
        "summary.json" "storage.aelladata_mounted"
    else
      add_check AELLADATA_SEPARATE_MOUNT storage WARN WARNING \
        "false" "separate mount recommended" \
        "/opt/aelladata is not a separate mount; OK if root free space is sufficient" \
        "Optional: migrate /opt/aelladata to a dedicated filesystem; not a hard blocker by default" \
        "summary.json" "storage.aelladata_mounted"
    fi
    add_check AELLADATA_FREE_SPACE storage PASS INFO \
      "shared_with_root" "N/A when not separate" \
      "Aelladata shares root filesystem; root free-space check applies" \
      "none" "summary.json" "storage.aelladata_mounted"
  fi

  # Writable / read-only
  local ro
  ro="$(awk -F'\t' 'NR>1 && $1=="/" {print $10; exit}' "${COLLECTION_ROOT}/storage/target-filesystems.txt" 2>/dev/null || true)"
  if [[ "$ro" == "true" ]]; then
    add_check FILESYSTEM_WRITABLE storage FAIL BLOCKER \
      "read-only" "writable" \
      "Root filesystem is read-only" \
      "Remount read-write and investigate filesystem errors; re-collect" \
      "storage/target-filesystems.txt" "read_only"
  else
    add_check FILESYSTEM_WRITABLE storage PASS INFO \
      "writable" "writable" \
      "Root filesystem is not marked read-only" \
      "none" "storage/target-filesystems.txt" "read_only"
  fi

  # Inodes
  local inode_pct
  inode_pct="$(_inode_avail_percent_for_path "/")"
  if [[ -z "$inode_pct" ]]; then
    add_check INODE_AVAILABILITY storage FAIL BLOCKER \
      "unknown" ">= ${POLICY_MIN_INODE_AVAILABLE_PERCENT}%" \
      "Inode availability unknown" \
      "Re-collect df -i / target-filesystems evidence" \
      "storage/target-filesystems.txt" "inodes"
  elif [[ "$inode_pct" -lt "$POLICY_MIN_INODE_AVAILABLE_PERCENT" ]]; then
    add_check INODE_AVAILABILITY storage FAIL BLOCKER \
      "${inode_pct}%" ">= ${POLICY_MIN_INODE_AVAILABLE_PERCENT}%" \
      "Insufficient free inodes on /" \
      "Free inodes on / then re-collect" \
      "storage/target-filesystems.txt" "inodes"
  else
    add_check INODE_AVAILABILITY storage PASS INFO \
      "${inode_pct}%" ">= ${POLICY_MIN_INODE_AVAILABLE_PERCENT}%" \
      "Inode availability meets project threshold" \
      "none" "storage/target-filesystems.txt" "inodes"
  fi
}

check_apt_dpkg() {
  local audit="${COLLECTION_ROOT}/apt/dpkg-audit.txt"
  local statusf="${COLLECTION_ROOT}/apt/dpkg-status-check.txt"
  local locks="${COLLECTION_ROOT}/apt/apt-locks.txt"
  local held="${COLLECTION_ROOT}/apt/held-packages.txt"
  local pending="${COLLECTION_ROOT}/apt/pending-actions.txt"
  local third="${COLLECTION_ROOT}/apt/third-party-repositories.txt"
  local code="${COLLECTION_ROOT}/apt/codename-check.txt"

  # Empty audit/status = clean
  if [[ ! -f "$audit" ]]; then
    add_check DPKG_AUDIT apt FAIL BLOCKER "missing" "present (may be empty)" \
      "dpkg-audit.txt missing" "Re-collect" "apt/dpkg-audit.txt" "content"
  elif grep -q 'NOT_AVAILABLE' "$audit" 2>/dev/null; then
    add_check DPKG_AUDIT apt UNKNOWN WARNING "NOT_AVAILABLE" "clean" \
      "dpkg audit tool not available during collection" "Re-collect on a host with dpkg" "apt/dpkg-audit.txt" "content"
  elif [[ ! -s "$audit" ]] || ! grep -qvE '^[[:space:]]*$' "$audit"; then
    add_check DPKG_AUDIT apt PASS INFO "clean(empty)" "clean" \
      "Empty dpkg audit indicates clean state" "none" "apt/dpkg-audit.txt" "content"
  else
    add_check DPKG_AUDIT apt FAIL BLOCKER "issues_present" "clean" \
      "dpkg --audit reported issues" "Resolve dpkg audit issues then re-collect" "apt/dpkg-audit.txt" "content"
  fi

  if [[ ! -f "$statusf" ]]; then
    add_check DPKG_STATUS apt FAIL BLOCKER "missing" "present (may be empty)" \
      "dpkg-status-check.txt missing" "Re-collect" "apt/dpkg-status-check.txt" "content"
  elif grep -q 'NOT_AVAILABLE' "$statusf" 2>/dev/null; then
    add_check DPKG_STATUS apt UNKNOWN WARNING "NOT_AVAILABLE" "clean" \
      "dpkg -C not available" "Re-collect" "apt/dpkg-status-check.txt" "content"
  elif [[ ! -s "$statusf" ]] || ! grep -qvE '^[[:space:]]*$' "$statusf"; then
    add_check DPKG_STATUS apt PASS INFO "clean(empty)" "clean" \
      "Empty dpkg status check indicates clean state" "none" "apt/dpkg-status-check.txt" "content"
  else
    # Some collectors write a header; treat non-empty carefully
    if grep -qiE 'broken|half-installed|error' "$statusf"; then
      add_check DPKG_STATUS apt FAIL BLOCKER "issues_present" "clean" \
        "dpkg status check reports problems" "Fix dpkg state then re-collect" "apt/dpkg-status-check.txt" "content"
    else
      add_check DPKG_STATUS apt PASS INFO "ok" "clean" \
        "dpkg status check has no broken-package indicators" "none" "apt/dpkg-status-check.txt" "content"
    fi
  fi

  # Locks
  if [[ -f "$locks" ]] && grep -qiE 'in_use=true' "$locks"; then
    add_check APT_LOCK apt FAIL BLOCKER "active_lock" "no active lock" \
      "APT/dpkg lock appears active" "Wait for package operations to finish; do not force unlock without investigation; re-collect" \
      "apt/apt-locks.txt" "in_use"
  else
    add_check APT_LOCK apt PASS INFO "inactive_or_unknown_false" "no active lock" \
      "No active apt/dpkg lock indicated" "none" "apt/apt-locks.txt" "in_use"
  fi

  # Process active (pending-actions / processes)
  if [[ -f "$pending" ]] && grep -qiE 'apt-get|aptitude|dpkg|unattended-upgrade' "$pending" 2>/dev/null; then
    if grep -qiE 'running|active|pid' "$pending"; then
      add_check APT_PROCESS_ACTIVE apt FAIL BLOCKER "active" "none" \
        "Package manager process evidence found" "Wait for completion then re-collect" "apt/pending-actions.txt" "processes"
    else
      add_check APT_PROCESS_ACTIVE apt PASS INFO "none" "none" \
        "No active package manager process indicated" "none" "apt/pending-actions.txt" "processes"
    fi
  else
    add_check APT_PROCESS_ACTIVE apt PASS INFO "none" "none" \
      "No active package manager process indicated" "none" "apt/pending-actions.txt" "processes"
  fi

  # Held packages
  local held_list="" crit_held=()
  if [[ -f "$held" ]] && ! grep -q 'NOT_AVAILABLE' "$held"; then
    held_list="$(grep -vE '^[[:space:]]*$' "$held" | tr '\n' ',' | sed 's/,$//')"
  fi
  if [[ -z "$held_list" ]]; then
    add_check HELD_PACKAGES apt PASS INFO "none" "none or managed" \
      "No held packages recorded" "none" "apt/held-packages.txt" "packages"
    add_check CRITICAL_HELD_PACKAGES apt PASS INFO "none" "no unmanaged critical holds" \
      "No critical held packages" "none" "apt/held-packages.txt" "critical"
  else
    add_check HELD_PACKAGES apt WARN WARNING "$held_list" "review holds" \
      "Held packages are present" "Review holds before upgrade; re-collect after changes" \
      "apt/held-packages.txt" "packages"
    local pkg
    IFS=',' read -r -a _held_arr <<<"$held_list"
    for pkg in "${_held_arr[@]}"; do
      pkg="$(printf '%s' "$pkg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -z "$pkg" ]] && continue
      if csv_contains "$POLICY_CRITICAL_HELD_PACKAGES" "$pkg"; then
        crit_held+=("$pkg")
      fi
    done
    if [[ ${#crit_held[@]} -gt 0 ]]; then
      if [[ "$POLICY_PROJECT_MANAGES_CRITICAL_HOLDS" == "true" ]]; then
        add_check CRITICAL_HELD_PACKAGES apt WARN WARNING \
          "${crit_held[*]}" "managed by project upgrader" \
          "Critical holds present but project policy marks them as managed" \
          "Ensure the OS upgrade orchestrator saves/unholds/restores these packages" \
          "apt/held-packages.txt" "critical"
      else
        add_check CRITICAL_HELD_PACKAGES apt FAIL BLOCKER \
          "${crit_held[*]}" "no unmanaged critical holds" \
          "Critical held packages found and this repository has no explicit unhold/restore logic" \
          "Manually review and unhold only with an approved change plan (e.g. apt-mark unhold ...), then re-collect. Preflight will not unhold." \
          "apt/held-packages.txt" "critical"
      fi
    else
      add_check CRITICAL_HELD_PACKAGES apt PASS INFO "none_critical" "no unmanaged critical holds" \
        "Held packages are not in the critical list" "none" "apt/held-packages.txt" "critical"
    fi
  fi

  # Codename
  if [[ -f "$code" ]] && grep -qiE 'mismatch|conflict' "$code"; then
    add_check APT_SOURCE_CODENAME apt FAIL BLOCKER "mismatch" "matches OS codename" \
      "APT source codename mismatch detected" "Fix sources.list codenames then re-collect" \
      "apt/codename-check.txt" "codename"
  else
    add_check APT_SOURCE_CODENAME apt PASS INFO "ok_or_absent" "matches OS codename" \
      "No APT source codename mismatch indicated" "none" "apt/codename-check.txt" "codename"
  fi

  # Third-party
  if [[ -f "$third" ]] && grep -qvE '^[[:space:]]*(#|$)' "$third"; then
    if [[ "$POLICY_THIRD_PARTY_REPOSITORIES" == "blocker" ]]; then
      add_check THIRD_PARTY_REPOSITORIES apt FAIL BLOCKER "present" "none or approved" \
        "Third-party repositories present" "Disable or approve third-party repos before upgrade; re-collect" \
        "apt/third-party-repositories.txt" "repos"
    else
      add_check THIRD_PARTY_REPOSITORIES apt WARN WARNING "present" "review" \
        "Third-party repositories present" "Review impact on do-release-upgrade; re-collect after changes" \
        "apt/third-party-repositories.txt" "repos"
    fi
  else
    add_check THIRD_PARTY_REPOSITORIES apt PASS INFO "none" "none or approved" \
      "No third-party repositories listed" "none" "apt/third-party-repositories.txt" "repos"
  fi
}

# HTTP status helper from network/http-tests.tsv (substring match; first hit)
http_status_for_url_substr() {
  local substr="$1"
  local f="${COLLECTION_ROOT}/network/http-tests.tsv"
  [[ -f "$f" ]] || { printf ''; return; }
  awk -F'\t' -v s="$substr" 'NR>1 && index($1,s)>0 {
    if ($2 ~ /^[0-9][0-9][0-9]$/) { print $2; exit }
  }' "$f"
}

# Exact URL match (preferred for Xenial archive/security endpoints)
http_status_for_exact_url() {
  local url="$1"
  local f="${COLLECTION_ROOT}/network/http-tests.tsv"
  [[ -f "$f" ]] || { printf ''; return; }
  awk -F'\t' -v u="$url" 'NR>1 && $1==u {
    if ($2 ~ /^[0-9][0-9][0-9]$/) { print $2; exit }
  }' "$f"
}

dns_status_for_host() {
  local host="$1"
  local f="${COLLECTION_ROOT}/network/dns-tests.tsv"
  [[ -f "$f" ]] || { printf ''; return; }
  awk -F'\t' -v h="$host" 'NR>1 && $1==h {print $2; exit}' "$f"
}

# Follow redirects (-L); report final HTTP code; bounded timeouts.
live_http_status() {
  local url="$1"
  if [[ "$LIVE_CHECK" -ne 1 ]]; then
    printf ''
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    printf ''
    return
  fi
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout "$NETWORK_TIMEOUT" --max-time "$NETWORK_TIMEOUT" \
    -L --head "$url" 2>/dev/null || true)"
  if [[ "$code" =~ ^[0-9][0-9][0-9]$ ]]; then
    printf '%s' "$code"
  else
    printf '000'
  fi
}

# Resolve collector evidence, optionally overridden by --live-check.
resolve_http_status() {
  local url="$1"
  local st live
  st="$(http_status_for_exact_url "$url")"
  live="$(live_http_status "$url")"
  if [[ -n "$live" && "$live" != "000" ]]; then
    printf '%s' "$live"
  else
    printf '%s' "$st"
  fi
}

check_repositories() {
  add_check PACKAGE_SOURCE_MODE repository PASS INFO \
    "$PACKAGE_SOURCE_MODE" "direct|cache|mirror" \
    "Package source mode selected" \
    "none" "cli" "package_source_mode"

  local mode="$PACKAGE_SOURCE_MODE"
  local needed_codenames=()
  case "$OS_VERSION" in
    16.04) needed_codenames=(xenial bionic focal jammy noble) ;;
    18.04) needed_codenames=(bionic focal jammy noble) ;;
    20.04) needed_codenames=(focal jammy noble) ;;
    22.04) needed_codenames=(jammy noble) ;;
    24.04) needed_codenames=(noble) ;;
  esac

  # DNS checks (connectivity vs availability separation)
  local dns_a dns_s
  dns_a="$(dns_status_for_host archive.ubuntu.com)"
  dns_s="$(dns_status_for_host security.ubuntu.com)"
  if [[ "$dns_a" == "SUCCESS" || -n "$(live_http_status http://archive.ubuntu.com/)" ]]; then
    add_check DNS_ARCHIVE_UBUNTU network PASS INFO "${dns_a:-live}" "SUCCESS" \
      "archive.ubuntu.com DNS resolution succeeded (connectivity)" \
      "none" "network/dns-tests.tsv" "archive.ubuntu.com"
  elif [[ -z "$dns_a" && "$LIVE_CHECK" -eq 0 && "$mode" != "direct" ]]; then
    add_check DNS_ARCHIVE_UBUNTU network SKIPPED INFO "not_required_for_${mode}" "optional" \
      "Direct archive DNS not required for ${mode} mode without evidence" \
      "none" "network/dns-tests.tsv" "archive.ubuntu.com"
  elif [[ -z "$dns_a" ]]; then
    add_check DNS_ARCHIVE_UBUNTU network UNKNOWN WARNING "no_evidence" "SUCCESS" \
      "No DNS evidence for archive.ubuntu.com" \
      "Re-collect without --skip-network or use --live-check" \
      "network/dns-tests.tsv" "archive.ubuntu.com"
  else
    add_check DNS_ARCHIVE_UBUNTU network FAIL BLOCKER "$dns_a" "SUCCESS" \
      "DNS for archive.ubuntu.com failed" \
      "Fix DNS then re-collect or --live-check" \
      "network/dns-tests.tsv" "archive.ubuntu.com"
  fi

  if [[ "$dns_s" == "SUCCESS" ]]; then
    add_check DNS_SECURITY_UBUNTU network PASS INFO "$dns_s" "SUCCESS" \
      "security.ubuntu.com DNS resolution succeeded" \
      "none" "network/dns-tests.tsv" "security.ubuntu.com"
  elif [[ -z "$dns_s" && "$mode" != "direct" ]]; then
    add_check DNS_SECURITY_UBUNTU network SKIPPED INFO "n/a" "optional" \
      "Skipped for non-direct mode" "none" "network/dns-tests.tsv" "security.ubuntu.com"
  elif [[ -z "$dns_s" ]]; then
    add_check DNS_SECURITY_UBUNTU network UNKNOWN WARNING "no_evidence" "SUCCESS" \
      "No DNS evidence for security.ubuntu.com" \
      "Re-collect network evidence" "network/dns-tests.tsv" "security.ubuntu.com"
  else
    add_check DNS_SECURITY_UBUNTU network FAIL BLOCKER "$dns_s" "SUCCESS" \
      "DNS for security.ubuntu.com failed" \
      "Fix DNS" "network/dns-tests.tsv" "security.ubuntu.com"
  fi

  # Per-release repository availability from collector HTTP tests (direct)
  _repo_check() {
    local check_id="$1" codename="$2" url_substr="$3"
    local st live needed=0 c
    for c in "${needed_codenames[@]}"; do
      [[ "$c" == "$codename" ]] && needed=1
    done
    st="$(http_status_for_url_substr "$url_substr")"
    live="$(live_http_status "http://archive.ubuntu.com/ubuntu/dists/${codename}/Release")"
    [[ -n "$live" && "$live" != "000" ]] && st="$live"

    if [[ "$needed" -eq 0 ]]; then
      add_check "$check_id" repository SKIPPED INFO "${st:-n/a}" "not required for current hops" \
        "${codename} repository not required for remaining hops" \
        "none" "network/http-tests.tsv" "$codename"
      return
    fi

    if [[ "$st" == "200" ]]; then
      add_check "$check_id" repository PASS INFO "http ${st}" "HTTP 200" \
        "${codename} Release available (repository availability)" \
        "none" "network/http-tests.tsv" "$url_substr"
    elif [[ "$st" == "404" ]]; then
      # Connectivity may still be fine — classify as availability failure
      add_check "$check_id" repository FAIL BLOCKER \
        "http 404 (connectivity may still be OK)" "HTTP 200" \
        "${codename} Release returned HTTP 404 — repository availability FAIL (not a DNS/TCP failure)" \
        "Point apt at a source that serves ${codename} (e.g. old-releases or local mirror), then re-collect or --live-check" \
        "network/http-tests.tsv" "$url_substr"
    elif [[ -z "$st" ]]; then
      if [[ "$mode" == "direct" ]]; then
        add_check "$check_id" repository FAIL BLOCKER "no_evidence" "HTTP 200" \
          "No HTTP evidence for ${codename} Release" \
          "Re-collect without --skip-network or use --live-check" \
          "network/http-tests.tsv" "$url_substr"
      else
        add_check "$check_id" repository UNKNOWN WARNING "no_direct_evidence" "HTTP 200 via selected source" \
          "No direct archive evidence for ${codename}; selected ${mode} source must provide it" \
          "Ensure mirror/cache serves ${codename}; use --live-check" \
          "network/http-tests.tsv" "$url_substr"
      fi
    else
      add_check "$check_id" repository FAIL BLOCKER "http ${st}" "HTTP 200" \
        "${codename} Release not available (status ${st})" \
        "Fix repository availability for ${codename}" \
        "network/http-tests.tsv" "$url_substr"
    fi
  }

  # Xenial direct: require archive base + updates + security (HTTP 200).
  # old-releases is NOT a primary endpoint; only a fallback when archive base is unavailable.
  if [[ "$OS_VERSION" == "16.04" && "$mode" == "direct" ]]; then
    local url_base url_upd url_sec url_old
    local st_base st_upd st_sec st_old
    url_base="http://archive.ubuntu.com/ubuntu/dists/xenial/Release"
    url_upd="http://archive.ubuntu.com/ubuntu/dists/xenial-updates/Release"
    url_sec="http://security.ubuntu.com/ubuntu/dists/xenial-security/Release"
    url_old="http://old-releases.ubuntu.com/ubuntu/dists/xenial/Release"
    st_base="$(resolve_http_status "$url_base")"
    st_upd="$(resolve_http_status "$url_upd")"
    st_sec="$(resolve_http_status "$url_sec")"
    st_old="$(resolve_http_status "$url_old")"

    local observed
    observed="archive=${st_base:-n/a} updates=${st_upd:-n/a} security=${st_sec:-n/a} old-releases=${st_old:-n/a}"

    if [[ "$st_base" == "200" && "$st_upd" == "200" && "$st_sec" == "200" ]]; then
      add_check XENIAL_REPOSITORY repository PASS INFO \
        "$observed" "HTTP 200 for archive/updates/security" \
        "Xenial archive base, updates, and security Release available (old-releases not required)" \
        "none" "network/http-tests.tsv" "xenial"
    elif [[ -n "$st_base" && "$st_base" != "200" ]]; then
      # Archive base unavailable — only then consider old-releases fallback
      if [[ "$st_old" == "200" ]]; then
        add_check XENIAL_REPOSITORY repository PASS INFO \
          "$observed" "HTTP 200 via old-releases fallback" \
          "Archive Xenial unavailable; old-releases Xenial Release accepted as fallback" \
          "none" "network/http-tests.tsv" "xenial"
      else
        add_check XENIAL_REPOSITORY repository FAIL BLOCKER \
          "$observed" "HTTP 200 for archive/updates/security (or old-releases fallback)" \
          "Xenial repository unavailable (404 is availability failure, not connectivity failure)" \
          "Ensure archive.ubuntu.com serves xenial/xenial-updates and security.ubuntu.com serves xenial-security; re-collect or --live-check" \
          "network/http-tests.tsv" "xenial"
      fi
    elif [[ -z "$st_base" && -z "$st_upd" && -z "$st_sec" ]]; then
      add_check XENIAL_REPOSITORY repository FAIL BLOCKER \
        "$observed" "HTTP 200 for archive/updates/security" \
        "No Xenial archive/updates/security Release evidence" \
        "Re-collect network checks (must probe archive xenial endpoints) or use --live-check" \
        "network/http-tests.tsv" "xenial"
    else
      add_check XENIAL_REPOSITORY repository FAIL BLOCKER \
        "$observed" "HTTP 200 for archive/updates/security" \
        "One or more required Xenial endpoints missing HTTP 200 (base/updates/security)" \
        "Fix archive/security Xenial repository availability; re-collect or --live-check" \
        "network/http-tests.tsv" "xenial"
    fi
  fi

  if [[ "$mode" == "direct" ]]; then
    _repo_check BIONIC_REPOSITORY bionic "/dists/bionic/Release"
    _repo_check FOCAL_REPOSITORY focal "/dists/focal/Release"
    _repo_check JAMMY_REPOSITORY jammy "/dists/jammy/Release"
    _repo_check NOBLE_REPOSITORY noble "/dists/noble/Release"
  fi

  # meta-release
  local meta_st
  meta_st="$(http_status_for_url_substr "meta-release-lts")"
  if [[ "$PHASE1_REQUIRED" == "true" ]]; then
    if [[ "$meta_st" == "200" ]]; then
      add_check META_RELEASE_METADATA repository PASS INFO "http 200" "HTTP 200" \
        "meta-release-lts available" "none" "network/http-tests.tsv" "meta-release-lts"
    elif [[ "$mode" != "direct" ]]; then
      add_check META_RELEASE_METADATA repository WARN WARNING \
        "${meta_st:-no_evidence}" "HTTP 200 or internal mirror meta-release" \
        "No confirmed meta-release-lts for offline/mirror do-release-upgrade" \
        "Ensure the mirror provides meta-release-lts (or equivalent); apt package mirror alone is not enough" \
        "network/http-tests.tsv" "meta-release-lts"
    else
      add_check META_RELEASE_METADATA repository FAIL BLOCKER \
        "${meta_st:-no_evidence}" "HTTP 200" \
        "meta-release-lts not available" \
        "Fix changelogs.ubuntu.com access or provide mirror meta-release" \
        "network/http-tests.tsv" "meta-release-lts"
    fi
  else
    add_check META_RELEASE_METADATA repository SKIPPED INFO "n/a" "n/a" \
      "Phase 1 not required" "none" "network/http-tests.tsv" "meta-release-lts"
  fi

  # Selected package source (cache/mirror)
  if [[ "$mode" == "direct" ]]; then
    # Check selected apt sources still point at working xenial if on 16.04
    local uris="${COLLECTION_ROOT}/apt/source-uris.txt"
    if [[ "$OS_VERSION" == "16.04" && -f "$uris" ]]; then
      local ax ox au as
      ax="$(resolve_http_status "http://archive.ubuntu.com/ubuntu/dists/xenial/Release")"
      au="$(resolve_http_status "http://archive.ubuntu.com/ubuntu/dists/xenial-updates/Release")"
      as="$(resolve_http_status "http://security.ubuntu.com/ubuntu/dists/xenial-security/Release")"
      ox="$(resolve_http_status "http://old-releases.ubuntu.com/ubuntu/dists/xenial/Release")"
      if [[ "$ax" == "200" && "$au" == "200" && "$as" == "200" ]]; then
        add_check PACKAGE_SOURCE_SELECTED repository PASS INFO \
          "direct archive/updates/security=200" "reachable xenial releases" \
          "Direct mode Xenial archive endpoints available" \
          "none" "apt/source-uris.txt" "uris"
      elif [[ "$ax" == "404" && "$ox" == "200" ]]; then
        add_check PACKAGE_SOURCE_SELECTED repository PASS INFO \
          "direct old-releases fallback" "reachable xenial source" \
          "Archive Xenial unavailable; old-releases fallback accepted" \
          "none" "apt/source-uris.txt" "uris"
      elif [[ "$ax" == "404" || "$au" == "404" || "$as" == "404" ]]; then
        add_check PACKAGE_SOURCE_SELECTED repository FAIL BLOCKER \
          "archive=${ax:-n/a} updates=${au:-n/a} security=${as:-n/a} old-releases=${ox:-n/a}" \
          "HTTP 200 for archive/updates/security" \
          "Selected APT sources cannot fetch required Xenial Release endpoints" \
          "Ensure archive/security serve Xenial; re-collect or --live-check" \
          "apt/source-uris.txt" "uris"
      else
        add_check PACKAGE_SOURCE_SELECTED repository PASS INFO \
          "direct" "reachable releases for hops" \
          "Direct mode package source selection accepted" \
          "none" "apt/source-uris.txt" "uris"
      fi
    else
      add_check PACKAGE_SOURCE_SELECTED repository PASS INFO \
        "direct" "reachable releases for hops" \
        "Direct mode selected" "none" "cli" "package_source_mode"
    fi
    add_check PACKAGE_SOURCE_ALL_HOPS repository PASS INFO \
      "evaluated_via_per_release_checks" "all needed hops" \
      "Per-release checks cover remaining hops" \
      "none" "network/http-tests.tsv" "hops"
  else
    # cache or mirror — require URL evidence or live-check
    local base="${PACKAGE_SOURCE_URL%/}"
    local have_evidence=0
    local c st live_url
    if [[ "$LIVE_CHECK" -eq 1 ]]; then
      for c in "${needed_codenames[@]}"; do
        live_url="${base}/ubuntu/dists/${c}/Release"
        st="$(live_http_status "$live_url")"
        if [[ "$st" != "200" ]]; then
          # try without /ubuntu prefix
          st="$(live_http_status "${base}/dists/${c}/Release")"
        fi
        local cid
        cid="$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')_REPOSITORY"
        if [[ "$st" == "200" ]]; then
          add_check "$cid" repository PASS INFO "live http 200 @ ${base}" "HTTP 200" \
            "${c} Release available via ${mode}" "none" "live-check" "$c"
          have_evidence=1
        else
          add_check "$cid" repository FAIL BLOCKER "live http ${st:-none} @ ${base}" "HTTP 200" \
            "${c} Release not available via selected ${mode} URL" \
            "Populate the ${mode} with ${c} Release/InRelease and package indexes" \
            "live-check" "$c"
        fi
      done
      if [[ "$have_evidence" -eq 1 ]]; then
        add_check PACKAGE_SOURCE_SELECTED repository PASS INFO "$base" "reachable ${mode}" \
          "Live-check confirmed selected package source" "none" "cli" "package_source_url"
        add_check PACKAGE_SOURCE_ALL_HOPS repository PASS INFO "live_verified" "all needed hops" \
          "Live-check covered needed hop releases" "none" "live-check" "hops"
      else
        add_check PACKAGE_SOURCE_SELECTED repository FAIL BLOCKER "$base" "reachable ${mode}" \
          "Live-check could not confirm selected package source" \
          "Fix ${mode} contents and URL" "live-check" "package_source_url"
        add_check PACKAGE_SOURCE_ALL_HOPS repository FAIL BLOCKER "failed" "all needed hops" \
          "Needed hop releases not available on selected source" \
          "Sync mirror/cache for all remaining LTS hops" "live-check" "hops"
      fi
    else
      # No live-check: collector does not probe custom mirror URLs
      if [[ "$POLICY_MISSING_PACKAGE_SOURCE_EVIDENCE" == "unknown" ]]; then
        add_check PACKAGE_SOURCE_SELECTED repository UNKNOWN WARNING \
          "$base (no collector evidence)" "verified ${mode} endpoints" \
          "No evidence that ${mode} URL serves required Release files; --live-check not enabled" \
          "Re-run with --live-check or provide collector evidence for the ${mode}" \
          "cli" "package_source_url"
        add_check PACKAGE_SOURCE_ALL_HOPS repository UNKNOWN WARNING \
          "unverified" "all needed hops" \
          "Cannot confirm all hop repositories on selected ${mode} without evidence" \
          "Use --live-check" "cli" "hops"
      else
        add_check PACKAGE_SOURCE_SELECTED repository FAIL BLOCKER \
          "$base (no collector evidence)" "verified ${mode} endpoints" \
          "Selected ${mode} URL has no Release availability evidence in the collection and --live-check was not used" \
          "Re-run with --live-check against the ${mode}, or collect HTTP evidence for ${base}/.../dists/<codename>/Release" \
          "cli" "package_source_url"
        add_check PACKAGE_SOURCE_ALL_HOPS repository FAIL BLOCKER \
          "unverified" "all needed hops" \
          "Completeness of package source for all remaining hops is not evidenced" \
          "Verify mirror/cache contains xenial→noble as required; use --live-check" \
          "cli" "hops"
      fi
      # Still emit per-release UNKNOWN/FAIL for mirror without evidence when needed
      for c in "${needed_codenames[@]}"; do
        local cid
        cid="$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')_REPOSITORY"
        add_check "$cid" repository FAIL BLOCKER \
          "no_evidence_for_${mode}" "HTTP 200 via ${base}" \
          "No evidence ${c} is available on selected ${mode}" \
          "Populate ${mode} and re-run with --live-check" \
          "cli" "$c"
      done
    fi
  fi

  # RELEASE_METADATA_AVAILABLE alias coverage via META_RELEASE already
  add_check RELEASE_METADATA_AVAILABLE repository PASS INFO \
    "see META_RELEASE_METADATA" "meta-release or equivalent" \
    "Release metadata check recorded under META_RELEASE_METADATA" \
    "none" "network/http-tests.tsv" "meta-release-lts"
}

check_ntp() {
  local sync source
  sync="$(pf_json_get "${COLLECTION_ROOT}/summary.json" time.ntp_synchronized)"
  source="$(pf_json_get "${COLLECTION_ROOT}/summary.json" time.source)"
  if [[ "$sync" == "true" ]]; then
    add_check NTP_SYNCHRONIZED time PASS INFO "synchronized=true (${source})" "synchronized=true" \
      "Clock is synchronized according to collector evidence" \
      "none" "summary.json" "time.ntp_synchronized"
  elif [[ "$sync" == "false" ]]; then
    add_check NTP_SYNCHRONIZED time FAIL BLOCKER "synchronized=false (${source})" "synchronized=true" \
      "Clock is not synchronized; APT Release files are skew-sensitive" \
      "Fix NTP/chrony/timesyncd then re-collect" \
      "summary.json" "time.ntp_synchronized"
  else
    if [[ "$POLICY_UNKNOWN_NTP_STATUS" == "blocker" ]]; then
      add_check NTP_SYNCHRONIZED time FAIL BLOCKER "unknown (${source})" "synchronized=true" \
        "NTP synchronization status unknown" \
        "Ensure timedatectl/chronyc/ntpq evidence is collected" \
        "summary.json" "time.ntp_synchronized"
    else
      add_check NTP_SYNCHRONIZED time UNKNOWN WARNING "unknown (${source})" "synchronized=true" \
        "NTP synchronization status unknown" \
        "Re-collect time sync evidence" \
        "summary.json" "time.ntp_synchronized"
    fi
  fi
}

check_role_cluster() {
  # Phase 1 OS-only: topology/role is diagnostic INFO, never BLOCKER.
  case "$ROLE_CANON" in
    AIO|DL_MASTER|DA_MASTER|MASTER|WORKER)
      add_check DP_ROLE role PASS INFO "$ROLE_CANON" "known role (informational)" \
        "DP role recognized; DP_TOPOLOGY_GATE=SKIPPED_PHASE1_OS_ONLY" \
        "none" "summary.json" "dp.role"
      ;;
    ""|UNKNOWN|UNDETERMINED)
      add_check DP_ROLE role PASS INFO "${ROLE_CANON:-UNDETERMINED}" "optional in Phase 1" \
        "DP topology undetermined; ignored (DP_TOPOLOGY_GATE=SKIPPED_PHASE1_OS_ONLY)" \
        "none" "summary.json" "dp.role"
      ;;
    *)
      add_check DP_ROLE role PASS INFO "${ROLE_CANON}" "informational in Phase 1" \
        "DP role '${ROLE_CANON}' recorded; not gated (DP_TOPOLOGY_GATE=SKIPPED_PHASE1_OS_ONLY)" \
        "none" "summary.json" "dp.role"
      ;;
  esac

  add_check CLUSTER_CONFIGURATION role PASS INFO \
    "cluster_detected=${CLUSTER_DETECTED} role=${ROLE_CANON:-UNDETERMINED} workers=${WORKER_IPS_CSV:-none}" \
    "not gated in Phase 1" \
    "Cluster/topology evidence is informational only for OS-only Phase 1" \
    "none" "summary.json" "dp.cluster_detected"
  add_check WORKER_CONFIGURATION role PASS INFO \
    "${WORKER_IPS_CSV:-none}" "not gated in Phase 1" \
    "Worker inventory ignored by Phase 1 OS-only policy" \
    "none" "summary.json" "dp.worker_ips"
}

check_upgrade_state() {
  local state hop
  state="$(pf_json_get "${COLLECTION_ROOT}/summary.json" upgrade.state)"
  hop="$(pf_json_get "${COLLECTION_ROOT}/summary.json" upgrade.hop_history_detected)"
  local state_file="${COLLECTION_ROOT}/upgrade/os-upgrade-state.txt"
  local raw=""
  if [[ -f "$state_file" ]]; then
    raw="$(tr -d '\0' <"$state_file" | head -c 256 | tr '\n' ' ')"
  fi
  [[ -z "$state" || "$state" == "null" ]] && state=""

  if [[ -z "$state" && "$hop" != "true" ]]; then
    add_check UPGRADE_STATE upgrade PASS INFO "NEW_RUN (no state)" "NEW_RUN|resumable" \
      "No existing OS upgrade state; treating as new run" \
      "none" "summary.json" "upgrade.state"
    add_check HOP_HISTORY upgrade PASS INFO "absent" "absent or consistent" \
      "No hop_history detected" "none" "summary.json" "upgrade.hop_history_detected"
    return
  fi

  local st_upper
  st_upper="$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
  case "$st_upper" in
    ""|NONE|NEW|NEW_RUN)
      add_check UPGRADE_STATE upgrade PASS INFO "NEW_RUN" "NEW_RUN" \
        "Upgrade state empty/new" "none" "upgrade/os-upgrade-state.txt" "state"
      ;;
    INITIALIZED)
      add_check UPGRADE_STATE upgrade WARN WARNING "INITIALIZED" "reviewed before start" \
        "Upgrade state is INITIALIZED; start or resume carefully" \
        "Review orchestrator state before starting" "upgrade/os-upgrade-state.txt" "state"
      ;;
    UPGRADING|RESUMED)
      add_check UPGRADE_STATE upgrade FAIL BLOCKER "$st_upper" "not mid-upgrade for new run" \
        "Upgrade appears in progress; do not start a duplicate run" \
        "Investigate running upgrade; resume via orchestrator only" "upgrade/os-upgrade-state.txt" "state"
      ;;
    BLOCKED|FAILED)
      add_check UPGRADE_STATE upgrade FAIL BLOCKER "$st_upper" "clear or successful resume plan" \
        "Previous upgrade state is ${st_upper}" \
        "Resolve the failed/blocked upgrade before a new run" "upgrade/os-upgrade-state.txt" "state"
      ;;
    COMPLETED)
      if [[ "$OS_VERSION" == "24.04" ]]; then
        add_check UPGRADE_STATE upgrade PASS INFO "COMPLETED on 24.04" "COMPLETED+24.04" \
          "Phase 1 appears completed" "none" "upgrade/os-upgrade-state.txt" "state"
      else
        add_check UPGRADE_STATE upgrade FAIL BLOCKER \
          "COMPLETED but OS=${OS_VERSION}" "COMPLETED only with OS 24.04" \
          "Upgrade state COMPLETED conflicts with current OS version" \
          "Investigate inconsistent state files; do not trust COMPLETED" \
          "upgrade/os-upgrade-state.txt" "state"
      fi
      ;;
    *)
      add_check UPGRADE_STATE upgrade FAIL BLOCKER "${state:-unknown}" "known state enum" \
        "Unrecognized or corrupt upgrade state" \
        "Inspect /opt/aelladata/os-upgrade/state manually" \
        "upgrade/os-upgrade-state.txt" "state"
      ;;
  esac

  if [[ "$hop" == "true" ]]; then
    add_check HOP_HISTORY upgrade WARN WARNING "present" "consistent with plan" \
      "hop_history exists; review before continuing" \
      "Inspect hop_history for partial hops" "summary.json" "upgrade.hop_history_detected"
  else
    add_check HOP_HISTORY upgrade PASS INFO "absent" "absent or consistent" \
      "No hop_history" "none" "summary.json" "upgrade.hop_history_detected"
  fi
}

check_bringup_bundle() {
  # Phase 1: informational evidence only. Never BLOCKER for OS readiness.
  local exists count legacy
  exists="$(pf_json_get "${COLLECTION_ROOT}/summary.json" bringup.aelladeb_py3_exists)"
  count="$(pf_json_get "${COLLECTION_ROOT}/summary.json" bringup.aelladeb_py3_file_count)"
  legacy="$(pf_json_get "${COLLECTION_ROOT}/summary.json" bringup.aelladeb_exists)"

  if [[ "$exists" == "true" && "${count:-0}" -gt 0 ]]; then
    add_check AELLADEB_PY3 bringup PASS INFO "exists files=${count}" "informational only" \
      "aelladeb_py3 evidence present; not used for Phase 1 OS readiness" \
      "Phase 2 is a separate workflow after Ubuntu 24.04" \
      "summary.json" "bringup.aelladeb_py3_exists"
    local sumf="${COLLECTION_ROOT}/dp/aelladeb-py3-summary.txt"
    if [[ -f "$sumf" ]] && grep -q 'bringup_py3_dp_after_os_upgrade.sh' "$sumf"; then
      add_check BRINGUP_SCRIPT bringup PASS INFO "found" "informational only" \
        "Bringup script referenced in collector evidence; not executed by Phase 1" \
        "none" "dp/aelladeb-py3-summary.txt" "script"
    else
      add_check BRINGUP_SCRIPT bringup PASS INFO "not_evidenced" "informational only" \
        "Bringup script not evidenced; Phase 1 OS readiness is unaffected" \
        "Use separate Phase 2 workflow after Ubuntu 24.04 if needed" \
        "dp/aelladeb-py3-summary.txt" "script"
    fi
    add_check BRINGUP_BUNDLE_MANIFEST bringup PASS INFO "see_summary" "informational only" \
      "Bundle summary present (informational)" "none" "dp/aelladeb-py3-summary.txt" "manifest"
    add_check BRINGUP_BUNDLE_CHECKSUM bringup PASS INFO "see_summary" "informational only" \
      "Checksum evidence deferred to bundle summary (informational)" "none" "dp/aelladeb-py3-summary.txt" "checksum"
  else
    local sev_status="PASS" sev="INFO"
    case "$POLICY_MISSING_PHASE2_BUNDLE_WHEN_PHASE2_NOT_REQUIRED" in
      warning) sev_status="WARN"; sev="WARNING" ;;
      blocker)
        sev_status="WARN"; sev="WARNING"
        log_warn "PHASE2_CHECKS_AFFECT_OS_PREFLIGHT is false: refusing to elevate missing Phase 2 bundle to BLOCKER"
        ;;
      *) sev_status="PASS"; sev="INFO" ;;
    esac
    add_check AELLADEB_PY3 bringup "$sev_status" "$sev" \
      "missing (legacy_aelladeb=${legacy:-false})" "informational only" \
      "aelladeb_py3 missing; Phase 1 OS preflight does not require Phase 2 bundles (legacy aelladeb is not a substitute)" \
      "Stage aelladeb_py3 only when preparing the separate Phase 2 workflow" \
      "summary.json" "bringup.aelladeb_py3_exists"
    add_check BRINGUP_SCRIPT bringup PASS INFO "n/a" "informational only" \
      "Bringup script not evaluated as an OS readiness gate" \
      "none" "dp/aelladeb-py3-summary.txt" "script"
    add_check BRINGUP_BUNDLE_MANIFEST bringup PASS INFO "n/a" "informational only" \
      "Phase 2 bundle manifest not required for OS preflight" \
      "none" "dp/aelladeb-py3-summary.txt" "manifest"
    add_check BRINGUP_BUNDLE_CHECKSUM bringup PASS INFO "n/a" "informational only" \
      "Phase 2 bundle checksum not required for OS preflight" \
      "none" "dp/aelladeb-py3-summary.txt" "checksum"
  fi
  if [[ "${BRINGUP_MODE_LEGACY_SET:-0}" -eq 1 ]]; then
    add_check LEGACY_BRINGUP_MODE bringup PASS INFO "${BRINGUP_MODE:-unset}" "deprecated/ignored" \
      "Legacy --bringup-mode was supplied and recorded but does not affect Phase 1 readiness" \
      "Omit --bringup-mode; use the separate Phase 2 workflow later" \
      "cli" "bringup_mode"
  fi
}

check_aelladata_baseline() {
  local sizef="${COLLECTION_ROOT}/data-preservation/aelladata-size-summary.txt"
  local manf="${COLLECTION_ROOT}/data-preservation/aelladata-metadata-manifest.tsv"
  local sumf="${COLLECTION_ROOT}/data-preservation/critical-config-checksums.tsv"
  local notes="${COLLECTION_ROOT}/data-preservation/manifest-notes.txt"

  if [[ -f "$sizef" ]] && grep -qE 'files=[0-9]+|/opt/aelladata' "$sizef"; then
    add_check AELLADATA_BASELINE data PASS INFO "size_summary_present" "baseline evidence" \
      "Aelladata size/file baseline evidence present" \
      "none" "data-preservation/aelladata-size-summary.txt" "summary"
  else
    add_check AELLADATA_BASELINE data WARN WARNING "missing_summary" "baseline evidence" \
      "Aelladata size summary missing or incomplete" \
      "Re-collect data-preservation section" \
      "data-preservation/aelladata-size-summary.txt" "summary"
  fi

  if [[ -f "$sumf" ]] && grep -qE 'cluster-name|release-metadata|release-image' "$sumf"; then
    add_check AELLADATA_CRITICAL_CHECKSUMS data PASS INFO "present" "critical checksums" \
      "Critical config checksums present (cluster-name, release-metadata.yml, release-image.yml)" \
      "none" "data-preservation/critical-config-checksums.tsv" "checksums"
  else
    add_check AELLADATA_CRITICAL_CHECKSUMS data WARN WARNING "missing" "critical checksums" \
      "Critical checksums missing" \
      "Re-collect with data-preservation enabled" \
      "data-preservation/critical-config-checksums.tsv" "checksums"
  fi

  if [[ -f "$manf" ]] && [[ -s "$manf" ]]; then
    local lines
    lines="$(wc -l <"$manf" | tr -d ' ')"
    add_check AELLADATA_MANIFEST data PASS INFO "lines=${lines}" "deep or metadata manifest" \
      "Aelladata metadata manifest present" \
      "none" "data-preservation/aelladata-metadata-manifest.tsv" "manifest"
  else
    add_check AELLADATA_MANIFEST data PASS INFO "optional_absent" "optional deep manifest" \
      "Deep/metadata manifest not present (optional)" \
      "Optional: re-collect with --deep-manifest" \
      "data-preservation/aelladata-metadata-manifest.tsv" "manifest"
  fi
}

# ---------------------------------------------------------------------------
# Overall status
# ---------------------------------------------------------------------------
calculate_overall_status() {
  if [[ "$BLOCKER_COUNT" -gt 0 ]]; then
    OVERALL_STATUS="BLOCKED"
    EXIT_CODE="$EXIT_BLOCKED"
  elif [[ "$WARNING_COUNT" -gt 0 || "$UNKNOWN_COUNT" -gt 0 ]]; then
    OVERALL_STATUS="READY_WITH_WARNINGS"
    EXIT_CODE="$EXIT_READY_WITH_WARNINGS"
  else
    OVERALL_STATUS="READY"
    EXIT_CODE="$EXIT_READY"
  fi
  # No-op special case already sets recommended_action=NONE; status can still be READY
}

# ---------------------------------------------------------------------------
# Output generation
# ---------------------------------------------------------------------------
generate_outputs() {
  local out="$RESULT_DIR"
  mkdir -p "${out}/source"

  # checks.tsv
  {
    printf 'check_id\tcategory\tstatus\tseverity\tobserved\texpected\treason\tremediation\tevidence_file\tevidence_key\n'
    printf '%s' "$CHECKS_TSV_BODY"
  } >"${out}/checks.tsv"

  # blockers / warnings
  {
    printf 'DP Upgrade Preflight Blockers\n'
    printf '==============================\n'
    awk -F'\t' 'NR>1 && $4=="BLOCKER" && $3=="FAIL" {
      printf "%s: %s\n  observed: %s\n  expected: %s\n  remediation: %s\n\n", $1, $7, $5, $6, $8
    }' "${out}/checks.tsv"
  } >"${out}/blockers.txt"

  {
    printf 'DP Upgrade Preflight Warnings\n'
    printf '==============================\n'
    awk -F'\t' 'NR>1 && ($3=="WARN" || ($3=="UNKNOWN") || ($3=="FAIL" && $4=="WARNING")) {
      printf "%s: %s\n  observed: %s\n  remediation: %s\n\n", $1, $7, $5, $8
    }' "${out}/checks.tsv"
  } >"${out}/warnings.txt"

  # evidence map
  {
    printf 'check_id\tevidence_file\tevidence_key\n'
    awk -F'\t' 'NR>1 {printf "%s\t%s\t%s\n",$1,$9,$10}' "${out}/checks.tsv"
  } >"${out}/evidence-map.tsv"

  # input integrity
  {
    printf 'integrity_status=%s\n' "$INTEGRITY_STATUS"
    printf 'input_path=%s\n' "$COLLECTION_PATH"
    printf 'input_type=%s\n' "$INPUT_TYPE"
    printf 'collection_root=%s\n' "$COLLECTION_ROOT"
    printf 'collector_script_version=%s\n' "$COLLECTOR_SCRIPT_VERSION"
    printf 'collector_schema_version=%s\n' "$COLLECTOR_SCHEMA_VERSION"
    printf 'collection_id=%s\n' "$COLLECTION_ID"
    printf 'collection_status=%s\n' "$COLLECTION_STATUS"
    printf 'json_parser=%s\n' "$JSON_PARSER_USED"
  } >"${out}/input-integrity.txt"

  printf 'collector_path=%s\ncollector_type=%s\ncollection_id=%s\nhostname=%s\n' \
    "$COLLECTION_PATH" "$INPUT_TYPE" "$COLLECTION_ID" "$HOSTNAME_VAL" \
    >"${out}/source/collector-reference.txt"

  write_effective_policy "${out}/policy-effective.conf"
  generate_remediation "${out}/remediation.md"
  generate_summary_txt "${out}/preflight-summary.txt"
  generate_summary_json "${out}/preflight-summary.json"
}

generate_remediation() {
  local out="$1"
  {
    printf '# DP Upgrade Preflight Remediation\n\n'
    printf '## Overall Result\n\n%s (exit %s)\n\n' "$OVERALL_STATUS" "$EXIT_CODE"
    printf 'Recommended action: %s\n\n' "$RECOMMENDED_ACTION"
    printf '## Required Before Upgrade\n\n'
    local n=0
    while IFS=$'\t' read -r id cat st sev obs exp reason rem efile ekey; do
      [[ "$id" == "check_id" ]] && continue
      if [[ "$sev" == "BLOCKER" && "$st" == "FAIL" ]]; then
        n=$((n+1))
        printf '### %s. %s\n\n' "$n" "$id"
        printf 'Observed:\n%s\n\n' "$obs"
        printf 'Expected:\n%s\n\n' "$exp"
        printf 'Reason:\n%s\n\n' "$reason"
        printf 'Suggested action:\n%s\n\n' "$rem"
        case "$id" in
          LOGIN_SHELL_*|CRITICAL_HELD_*|HELD_*|ROOT_FREE_*|BOOT_FREE_*|DPKG_*|APT_*|AELLADEB_*|XENIAL_*|*_REPOSITORY|NTP_*)
            printf 'Re-validation: re-run **collector** then preflight.\n\n'
            ;;
          SNAPSHOT_OR_BACKUP_*)
            printf 'Re-validation: same collector archive may be reused; re-run **preflight** with a real reference.\n\n'
            ;;
          PACKAGE_SOURCE_*)
            printf 'Re-validation: re-collect network evidence or re-run preflight with **--live-check**.\n\n'
            ;;
          *)
            printf 'Re-validation: re-run preflight; re-collect if evidence files changed.\n\n'
            ;;
        esac
      fi
    done <"${RESULT_DIR}/checks.tsv"

    if [[ "$n" -eq 0 ]]; then
      printf 'No blockers.\n\n'
    fi

    printf '## Warnings\n\n'
    awk -F'\t' 'NR>1 && ($3=="WARN" || $3=="UNKNOWN") {
      printf "- %s: %s\n", $1, $7
    }' "${RESULT_DIR}/checks.tsv"
    printf '\n## Recommended Re-run\n\n'
    printf '1. Apply blocker remediations (commands above are suggestions only; preflight does not execute them).\n'
    printf '2. Re-run collect-dp-upgrade-readiness.sh when host evidence changed.\n'
    printf '3. Re-run dp-upgrade-preflight.sh against the new (or same) collection.\n'
    printf '4. Only then proceed to the OS upgrade orchestrator.\n'
  } >"$out"
}

generate_summary_txt() {
  local out="$1"
  {
    printf 'DP Upgrade Preflight Summary\n'
    printf '============================\n'
    printf 'preflight_id: %s\n' "$PREFLIGHT_ID"
    printf 'overall_status: %s\n' "$OVERALL_STATUS"
    printf 'exit_code: %s\n' "$EXIT_CODE"
    printf 'hostname: %s\n' "$HOSTNAME_VAL"
    printf 'os: %s (%s)\n' "$OS_VERSION" "$OS_CODENAME"
    printf 'dp_raw: %s\n' "$DP_VERSION_RAW"
    printf 'dp_normalized: %s\n' "$DP_VERSION_NORM"
    printf 'role: %s\n' "$ROLE_CANON"
    printf 'phase1_required: %s\n' "$PHASE1_REQUIRED"
    printf 'phase1_hops: %s\n' "${PHASE1_HOPS_CSV:-none}"
    printf 'phase2_required: %s\n' "$PHASE2_REQUIRED"
    printf 'recommended_action: %s\n' "$RECOMMENDED_ACTION"
    printf 'upgrade_required: %s\n' "$UPGRADE_REQUIRED"
    printf 'pass=%s warning=%s blocker=%s unknown=%s\n' \
      "$PASS_COUNT" "$WARNING_COUNT" "$BLOCKER_COUNT" "$UNKNOWN_COUNT"
    printf 'package_source_mode: %s\n' "$PACKAGE_SOURCE_MODE"
    printf 'bringup_mode: %s\n' "$BRINGUP_MODE"
  } >"$out"
}

generate_summary_json() {
  local out="$1"
  local checks_joined="" i
  for i in "${!CHECKS_JSON_PARTS[@]}"; do
    if [[ "$i" -eq 0 ]]; then
      checks_joined="${CHECKS_JSON_PARTS[$i]}"
    else
      checks_joined+=",
${CHECKS_JSON_PARTS[$i]}"
    fi
  done

  local hops_json="[]"
  if [[ -n "$PHASE1_HOPS_CSV" ]]; then
    hops_json="["
    local first=1 h
    IFS=',' read -r -a _hops <<<"$PHASE1_HOPS_CSV"
    for h in "${_hops[@]}"; do
      [[ -z "$h" ]] && continue
      if [[ "$first" -eq 1 ]]; then
        hops_json+="\"$(pf_json_escape "$h")\""
        first=0
      else
        hops_json+=",\"$(pf_json_escape "$h")\""
      fi
    done
    hops_json+="]"
  fi

  local workers_json="[]"
  if [[ -n "$WORKER_IPS_CSV" ]]; then
    workers_json="["
    local wf=1 w
    IFS=',' read -r -a _wips <<<"$WORKER_IPS_CSV"
    for w in "${_wips[@]}"; do
      [[ -z "$w" ]] && continue
      if [[ "$wf" -eq 1 ]]; then
        workers_json+="\"$(pf_json_escape "$w")\""
        wf=0
      else
        workers_json+=",\"$(pf_json_escape "$w")\""
      fi
    done
    workers_json+="]"
  fi

  local snap_present=false bak_present=false
  [[ -n "$SNAPSHOT_REFERENCE" ]] && ! is_placeholder_reference "$SNAPSHOT_REFERENCE" && snap_present=true
  [[ -n "$BACKUP_REFERENCE" ]] && ! is_placeholder_reference "$BACKUP_REFERENCE" && bak_present=true

  cat >"$out" <<EOF
{
  "schema_version": "$(pf_json_escape "$SCHEMA_VERSION")",
  "script_version": "$(pf_json_escape "$SCRIPT_VERSION")",
  "preflight_id": "$(pf_json_escape "$PREFLIGHT_ID")",
  "started_at_utc": "$(pf_json_escape "$STARTED_AT_UTC")",
  "completed_at_utc": "$(pf_json_escape "$COMPLETED_AT_UTC")",
  "duration_seconds": $(pf_json_num_or_null "$DURATION_SECONDS"),
  "input": {
    "path": "$(pf_json_escape "$COLLECTION_PATH")",
    "type": "$(pf_json_escape "$INPUT_TYPE")",
    "collector_script_version": $(pf_json_str_or_null "$COLLECTOR_SCRIPT_VERSION"),
    "collector_schema_version": $(pf_json_str_or_null "$COLLECTOR_SCHEMA_VERSION"),
    "collector_status": $(pf_json_str_or_null "$COLLECTION_STATUS"),
    "collection_id": $(pf_json_str_or_null "$COLLECTION_ID"),
    "integrity_status": "$(pf_json_escape "$INTEGRITY_STATUS")"
  },
  "target": {
    "hostname": $(pf_json_str_or_null "$HOSTNAME_VAL"),
    "os_version": $(pf_json_str_or_null "$OS_VERSION"),
    "os_codename": $(pf_json_str_or_null "$OS_CODENAME"),
    "dp_version_raw": $(pf_json_str_or_null "$DP_VERSION_RAW"),
    "dp_version_normalized": $(pf_json_str_or_null "$DP_VERSION_NORM"),
    "role": $(pf_json_str_or_null "$ROLE_CANON"),
    "cluster_detected": $(pf_json_bool "$CLUSTER_DETECTED"),
    "worker_ips": ${workers_json}
  },
  "requested_path": {
    "package_source_mode": "$(pf_json_escape "$PACKAGE_SOURCE_MODE")",
    "package_source_url": $(pf_json_str_or_null "$PACKAGE_SOURCE_URL"),
    "execution_profile": "$(pf_json_escape "$EXECUTION_PROFILE")",
    "bringup_mode": $(pf_json_str_or_null "$BRINGUP_MODE"),
    "bringup_mode_deprecated": $( [[ "${BRINGUP_MODE_LEGACY_SET:-0}" -eq 1 ]] && echo true || echo false ),
    "snapshot_reference_present": $(pf_json_bool "$snap_present"),
    "backup_reference_present": $(pf_json_bool "$bak_present"),
    "snapshot_reference": $(pf_json_str_or_null "$SNAPSHOT_REFERENCE"),
    "backup_reference": $(pf_json_str_or_null "$BACKUP_REFERENCE")
  },
  "upgrade_plan": {
    "phase": "OS_ONLY",
    "supported_start": $(pf_json_bool "$SUPPORTED_START"),
    "os_upgrade_required": $(pf_json_bool "${OS_UPGRADE_REQUIRED:-false}"),
    "phase1_required": $(pf_json_bool "$PHASE1_REQUIRED"),
    "phase1_hops": ${hops_json},
    "next_hop": $(pf_json_str_or_null "$NEXT_HOP"),
    "phase2_required": false,
    "phase2_evaluated": false,
    "target_os": "$(pf_json_escape "$POLICY_TARGET_OS_VERSION")",
    "target_dp": "$(pf_json_escape "$POLICY_TARGET_DP_VERSION")",
    "recommended_action": "$(pf_json_escape "$RECOMMENDED_ACTION")",
    "upgrade_required": $(pf_json_bool "$UPGRADE_REQUIRED"),
    "execution_profile": "$(pf_json_escape "$EXECUTION_PROFILE")",
    "snapshot_required": $(pf_json_bool "$SNAPSHOT_REQUIRED")
  },
  "rollback": {
    "required": $(pf_json_bool "$SNAPSHOT_REQUIRED"),
    "snapshot_reference": $(pf_json_str_or_null "$SNAPSHOT_REFERENCE"),
    "backup_reference": $(pf_json_str_or_null "$BACKUP_REFERENCE"),
    "disposable_vm_acknowledged": false,
    "risk": "$(if [[ "$EXECUTION_PROFILE" == "discovery" ]]; then printf '%s' 'VM may not be recoverable after the OS upgrade'; else printf '%s' 'Rollback depends on operator-verified snapshot/backup'; fi)"
  },
  "result": {
    "overall_status": "$(pf_json_escape "$OVERALL_STATUS")",
    "exit_code": ${EXIT_CODE},
    "pass_count": ${PASS_COUNT},
    "warning_count": ${WARNING_COUNT},
    "blocker_count": ${BLOCKER_COUNT},
    "unknown_count": ${UNKNOWN_COUNT}
  },
  "checks": [
${checks_joined}
  ]
}
EOF
}

create_archive() {
  local parent archive
  parent="$(dirname "$RESULT_DIR")"
  archive="${parent}/${RESULT_NAME}.tar.gz"
  tar -C "$parent" -czf "$archive" "$RESULT_NAME" 2>/dev/null || die_internal "failed to create result archive"
  log_info "wrote archive: $archive"
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "${SUDO_USER}:" "$archive" 2>/dev/null || true
    if [[ "$KEEP_DIRECTORY" -eq 1 ]]; then
      chown -R "${SUDO_USER}:" "$RESULT_DIR" 2>/dev/null || true
    fi
  fi
  if [[ "$KEEP_DIRECTORY" -eq 0 ]]; then
    rm -rf "$RESULT_DIR" 2>/dev/null || true
  fi
  printf '%s' "$archive"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  validate_cli
  load_policy
  apply_profile_snapshot_policy
  log_info "execution_profile=${EXECUTION_PROFILE} snapshot_required=${SNAPSHOT_REQUIRED}"

  STARTED_AT_UTC="$(utc_now)"
  local stamp host_safe
  stamp="$(utc_stamp)"

  prepare_input

  # Hostname from summary if possible later; provisional from path
  host_safe="$(pf_sanitize_filename "$(basename "$COLLECTION_ROOT" | sed -E 's/^dp-upgrade-readiness-//;s/-[0-9]{8}T[0-9]{6}Z$//')")"
  [[ -z "$host_safe" ]] && host_safe="unknown"

  RESULT_NAME="dp-os-upgrade-preflight-${host_safe}-${stamp}"
  PREFLIGHT_ID="$RESULT_NAME"
  mkdir -p "$OUTPUT_DIR" || die_cli "cannot create output-dir: $OUTPUT_DIR"
  RESULT_DIR="$(cd "$OUTPUT_DIR" && pwd)/${RESULT_NAME}"
  mkdir -p "$RESULT_DIR" || die_internal "cannot create result dir"
  EXECUTION_LOG="${RESULT_DIR}/execution.log"
  : >"$EXECUTION_LOG"

  log_info "starting preflight ${PREFLIGHT_ID}"
  log_info "json parser: $(pf_detect_json_parser)"

  if ! validate_collection_structure; then
    calculate_overall_status
    COMPLETED_AT_UTC="$(utc_now)"
    generate_outputs
    create_archive >/dev/null
    exit "$EXIT_CODE"
  fi
  if ! validate_summary_json; then
    calculate_overall_status
    COMPLETED_AT_UTC="$(utc_now)"
    generate_outputs
    create_archive >/dev/null
    exit "$EXIT_INTERNAL"
  fi

  load_summary_fields
  # Refresh result name with real hostname if available
  if [[ -n "$HOSTNAME_VAL" ]]; then
    host_safe="$(pf_sanitize_filename "$HOSTNAME_VAL")"
  fi

  check_required_evidence || true

  resolve_upgrade_path
  check_snapshot
  check_shells
  check_storage
  check_apt_dpkg
  check_repositories
  check_ntp
  check_role_cluster
  check_upgrade_state
  check_bringup_bundle
  check_aelladata_baseline

  calculate_overall_status
  COMPLETED_AT_UTC="$(utc_now)"
  # duration
  if command -v date >/dev/null 2>&1; then
    local start_s end_s
    start_s="$(date -u -d "$STARTED_AT_UTC" +%s 2>/dev/null || true)"
    end_s="$(date -u -d "$COMPLETED_AT_UTC" +%s 2>/dev/null || true)"
    if [[ -n "$start_s" && -n "$end_s" ]]; then
      DURATION_SECONDS=$((end_s - start_s))
    fi
  fi

  generate_outputs
  local arch
  arch="$(create_archive)"
  log_info "overall_status=${OVERALL_STATUS} exit=${EXIT_CODE} archive=${arch}"
  exit "$EXIT_CODE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
