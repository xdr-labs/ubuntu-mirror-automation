#!/usr/bin/env bash
# shellcheck shell=bash
# Offline upgrade profile helpers — selective discovery-exact SSOT.

# shellcheck disable=SC2317
if [[ -n "${UM_UPGRADE_PROFILE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
UM_UPGRADE_PROFILE_LOADED=1

UM_UPGRADE_PROFILE_NAME="offline-upgrade-selective"
UM_UPGRADE_PROFILE_SCHEMA=2
UM_UPGRADE_SELECTION_MODE="discovery_exact"
UM_UPGRADE_REQUIRED_SERIES="xenial bionic focal jammy noble"
UM_UPGRADE_SUPPORTED_HOPS="xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble"
UM_SELECTIVE_MIRROR_ROOT="/var/spool/apt-mirror/selective"
UM_FULL_MIRROR_SEED_ROOT="/var/spool/apt-mirror/mirror/archive.ubuntu.com/ubuntu"

um_upgrade_profile_path() {
  local cand
  for cand in \
    "${UM_PROJECT_ROOT:-}/config/offline-upgrade-profile.json" \
    "/etc/ubuntu-mirror/offline-upgrade-profile.json" \
    "/usr/local/lib/ubuntu-mirror/offline-upgrade-profile.json"
  do
    if [[ -n "$cand" ]] && [[ -f "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

um_load_upgrade_profile() {
  local path
  path="$(um_upgrade_profile_path)" || {
    um_warn "offline-upgrade-profile.json not found — using built-in selective defaults"
    return 0
  }
  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck disable=SC2016
  eval "$(python3 - "$path" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
print('UM_UPGRADE_PROFILE_NAME=%r' % data.get('profile_name', 'offline-upgrade-selective'))
print('UM_UPGRADE_PROFILE_SCHEMA=%r' % data.get('schema_version', 2))
print('UM_UPGRADE_SELECTION_MODE=%r' % data.get('selection_mode', 'discovery_exact'))
print('UM_UPGRADE_REQUIRED_SERIES=%r' % ' '.join(data.get('series', [])))
print('UM_UPGRADE_SUPPORTED_HOPS=%r' % ' '.join(data.get('supported_hops', [])))
print('UM_SELECTIVE_MIRROR_ROOT=%r' % data.get(
    'selective_mirror_root', '/var/spool/apt-mirror/selective'))
print('UM_FULL_MIRROR_SEED_ROOT=%r' % data.get(
    'full_mirror_seed_root',
    '/var/spool/apt-mirror/mirror/archive.ubuntu.com/ubuntu'))
PY
)"
}

um_unsupported_full_sync_message() {
  cat <<EOF
ERROR: Full apt-mirror sync is not part of the selective offline upgrade profile.

Required profile: ${UM_UPGRADE_PROFILE_NAME}
Selection mode: ${UM_UPGRADE_SELECTION_MODE}
Use: plan-selective → materialize-selective → verify-selective → publish-selective

Status: UNSUPPORTED_FULL_MIRROR_SYNC
No sync was started.
EOF
}

um_unsupported_minimal_message() {
  cat <<EOF
ERROR: Minimal mirror profiles are not supported.

Required profile: ${UM_UPGRADE_PROFILE_NAME}
Selection mode: ${UM_UPGRADE_SELECTION_MODE}

Status: UNSUPPORTED_MINIMAL_PROFILE
No sync was started.
EOF
}

um_reject_minimal_request() {
  local reason="${1:-UNSUPPORTED_MINIMAL_PROFILE}"
  um_load_upgrade_profile 2>/dev/null || true
  um_unsupported_minimal_message >&2
  if [[ -n "${reason}" ]]; then
    printf 'error_code=%s\n' "$reason" >&2
  fi
  return 1
}

um_reject_full_sync_request() {
  local reason="${1:-UNSUPPORTED_FULL_MIRROR_SYNC}"
  um_load_upgrade_profile 2>/dev/null || true
  um_unsupported_full_sync_message >&2
  if [[ -n "${reason}" ]]; then
    printf 'error_code=%s\n' "$reason" >&2
  fi
  return 1
}

um_assert_supported_mirror_mode() {
  local mode="${1:-${MIRROR_MODE:-}}"
  um_load_upgrade_profile 2>/dev/null || true
  case "${mode}" in
    selective|SELECTIVE|offline-upgrade-selective|discovery_exact|"" )
      MIRROR_MODE="selective"
      return 0
      ;;
    minimal|MINIMAL)
      um_reject_minimal_request "UNSUPPORTED_MINIMAL_PROFILE"
      return 1
      ;;
    full|FULL|offline-upgrade-full)
      um_reject_full_sync_request "UNSUPPORTED_FULL_MIRROR_SYNC"
      return 1
      ;;
    *)
      printf 'ERROR: Unsupported MIRROR_MODE=%s (required: selective / offline-upgrade-selective)\n' "$mode" >&2
      printf 'error_code=INCOMPLETE_UPGRADE_PROFILE\n' >&2
      return 1
      ;;
  esac
}

um_resolve_validate_upgrade_profile_py() {
  local cand
  for cand in \
    "${UM_PROJECT_ROOT:-}/scripts/lib/validate_upgrade_profile.py" \
    "/usr/local/lib/ubuntu-mirror/validate_upgrade_profile.py" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/scripts/lib/validate_upgrade_profile.py"
  do
    if [[ -n "$cand" ]] && [[ -f "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

um_run_upgrade_profile_validate() {
  local py mirror_root result_json
  mirror_root="${1:-${BASE_PATH:-/var/spool/apt-mirror}}"
  result_json="${2:-${mirror_root}/offline/upgrade-profile-validation.json}"
  py="$(um_resolve_validate_upgrade_profile_py)" || {
    printf 'ERROR: validate_upgrade_profile.py not found\n' >&2
    return 1
  }
  python3 "$py" validate \
    --mirror-root "$mirror_root" \
    --profile "$(um_upgrade_profile_path 2>/dev/null || true)" \
    --mirror-list "${3:-/etc/apt/mirror.list}" \
    --mirror-conf "${4:-${UM_CONFIG_PATH:-/etc/ubuntu-mirror/mirror.conf}}" \
    --result-json "$result_json" \
    ${UM_PROJECT_ROOT:+--project-root "$UM_PROJECT_ROOT"}
}
