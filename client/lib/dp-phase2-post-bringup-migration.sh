#!/usr/bin/env bash
# Post-bringup skipped-version schema migration decision (operator-required).
# shellcheck shell=bash
#
# Historical vendor/QA procedures may require a manual schema/data migration
# after Phase 2 bringup when older DP releases (6.2/6.3/6.4) skip intermediate
# DP versions en route to the target (normally 6.6.0). This repository does not
# ship upgrade_script.sh and does not auto-execute it.
#
# States:
#   NOT_REQUIRED | REQUIRED | PASS | FAIL
#
# DP_UPGRADE_COMPLETE must remain NO while status is REQUIRED.

POST_BRINGUP_MIGRATION_ENV_DEFAULT="${POST_BRINGUP_MIGRATION_ENV_DEFAULT:-/opt/aelladata/os-upgrade/offline/phase2-bringup/post-bringup-migration.env}"
# Sources that historically skip intermediate DP schema generations when
# upgrading directly to a later target. Exact auto-invocation of
# /opt/aelladata/da-upgrade/scripts/upgrade_script.sh is NOT proven safe here.
POST_BRINGUP_MIGRATION_REQUIRED_MINOR_PREFIXES=("6.2" "6.3" "6.4")

p2b_migration_env_path() {
  printf '%s' "${POST_BRINGUP_MIGRATION_ENV:-${POST_BRINGUP_MIGRATION_ENV_DEFAULT}}"
}

p2b_migration_minor_prefix() {
  local ver="${1-}"
  if [[ "$ver" =~ ^([0-9]+\.[0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# Decide whether operator post-bringup migration is required.
# Prints: NOT_REQUIRED | REQUIRED
p2b_decide_post_bringup_migration() {
  local source="${1-}" target="${2-}" cmp prefix p
  if [[ -z "$source" || -z "$target" ]]; then
    printf 'REQUIRED'
    return 0
  fi
  if [[ "$source" == "$target" ]]; then
    printf 'NOT_REQUIRED'
    return 0
  fi
  if declare -F compare_dp_versions >/dev/null 2>&1; then
    cmp="$(compare_dp_versions "$source" "$target" 2>/dev/null || printf 'unknown')"
  elif command -v dpkg >/dev/null 2>&1; then
    if dpkg --compare-versions "$source" eq "$target" 2>/dev/null; then
      cmp=eq
    elif dpkg --compare-versions "$source" lt "$target" 2>/dev/null; then
      cmp=lt
    else
      cmp=unknown
    fi
  else
    cmp=unknown
  fi
  if [[ "$cmp" != "lt" ]]; then
    # Same or newer source, or uncomparable → do not invent REQUIRED.
    printf 'NOT_REQUIRED'
    return 0
  fi
  prefix="$(p2b_migration_minor_prefix "$source" || true)"
  for p in "${POST_BRINGUP_MIGRATION_REQUIRED_MINOR_PREFIXES[@]}"; do
    if [[ "$prefix" == "$p" ]]; then
      printf 'REQUIRED'
      return 0
    fi
  done
  printf 'NOT_REQUIRED'
  return 0
}

p2b_persist_post_bringup_migration_decision() {
  local source="${1-}" target="${2-}" decision="${3-}"
  local dest parent tmp
  dest="$(p2b_migration_env_path)"
  parent="$(dirname "$dest")"
  if ! mkdir -p "$parent"; then
    echo "ERROR: POST_BRINGUP_MIGRATION_PERSIST=FAIL reason=mkdir path=${parent}" >&2
    return 1
  fi
  chmod 0700 "$parent" 2>/dev/null || true
  [[ -n "$decision" ]] || decision="$(p2b_decide_post_bringup_migration "$source" "$target")"
  tmp="${dest}.tmp.$$.${RANDOM:-0}"
  local req_action=NO
  [[ "$decision" == "REQUIRED" ]] && req_action=YES
  {
    echo "SOURCE_DP_VERSION=${source}"
    echo "TARGET_DP_VERSION=${target}"
    echo "POST_BRINGUP_MIGRATION=${decision}"
    echo "POST_BRINGUP_MIGRATION_DECISION_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "POST_BRINGUP_MIGRATION_EXECUTION=OPERATOR_REQUIRED"
    echo "REQUIRED_POST_BRINGUP_ACTION=${req_action}"
    echo "POST_BRINGUP_MIGRATION_OPERATOR_COMMAND=sudo bash /opt/aelladata/da-upgrade/scripts/upgrade_script.sh ${target}"
    echo "POST_BRINGUP_MIGRATION_RECORD_COMMAND=sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --record-post-bringup-migration PASS|FAIL"
  } >"$tmp" || {
    rm -f "$tmp"
    echo "ERROR: POST_BRINGUP_MIGRATION_PERSIST=FAIL reason=write path=${dest}" >&2
    return 1
  }
  chmod 0600 "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    echo "ERROR: POST_BRINGUP_MIGRATION_PERSIST=FAIL reason=rename path=${dest}" >&2
    return 1
  fi
  POST_BRINGUP_MIGRATION="$decision"
  REQUIRED_POST_BRINGUP_ACTION="$req_action"
  return 0
}

p2b_load_post_bringup_migration() {
  local dest line key val
  dest="$(p2b_migration_env_path)"
  POST_BRINGUP_MIGRATION="${POST_BRINGUP_MIGRATION:-NOT_CHECKED}"
  REQUIRED_POST_BRINGUP_ACTION="${REQUIRED_POST_BRINGUP_ACTION:-UNKNOWN}"
  POST_BRINGUP_MIGRATION_SOURCE="${POST_BRINGUP_MIGRATION_SOURCE:-}"
  POST_BRINGUP_MIGRATION_TARGET="${POST_BRINGUP_MIGRATION_TARGET:-}"
  [[ -f "$dest" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      POST_BRINGUP_MIGRATION) POST_BRINGUP_MIGRATION="$val" ;;
      REQUIRED_POST_BRINGUP_ACTION) REQUIRED_POST_BRINGUP_ACTION="$val" ;;
      SOURCE_DP_VERSION) POST_BRINGUP_MIGRATION_SOURCE="$val" ;;
      TARGET_DP_VERSION) POST_BRINGUP_MIGRATION_TARGET="$val" ;;
    esac
  done <"$dest"
  return 0
}

p2b_record_post_bringup_migration() {
  local result="${1-}" dest
  case "$result" in
    PASS|FAIL) ;;
    *)
      echo "ERROR: --record-post-bringup-migration requires PASS or FAIL" >&2
      return 1
      ;;
  esac
  p2b_load_post_bringup_migration || true
  dest="$(p2b_migration_env_path)"
  if [[ ! -f "$dest" ]]; then
    echo "ERROR: migration decision file missing: ${dest}" >&2
    return 1
  fi
  # Preserve source/target; update status only.
  local source target
  source="${POST_BRINGUP_MIGRATION_SOURCE:-}"
  target="${POST_BRINGUP_MIGRATION_TARGET:-}"
  local req_action=YES
  [[ "$result" == "PASS" ]] && req_action=NO
  {
    echo "SOURCE_DP_VERSION=${source}"
    echo "TARGET_DP_VERSION=${target}"
    echo "POST_BRINGUP_MIGRATION=${result}"
    echo "POST_BRINGUP_MIGRATION_RECORDED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "POST_BRINGUP_MIGRATION_EXECUTION=OPERATOR_REQUIRED"
    echo "REQUIRED_POST_BRINGUP_ACTION=${req_action}"
    echo "POST_BRINGUP_MIGRATION_OPERATOR_COMMAND=sudo bash /opt/aelladata/da-upgrade/scripts/upgrade_script.sh ${target}"
    echo "POST_BRINGUP_MIGRATION_RECORD_COMMAND=sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --record-post-bringup-migration PASS|FAIL"
  } >"${dest}.tmp.$$"
  chmod 0600 "${dest}.tmp.$$" 2>/dev/null || true
  mv -f "${dest}.tmp.$$" "$dest"
  POST_BRINGUP_MIGRATION="$result"
  REQUIRED_POST_BRINGUP_ACTION="$req_action"
  echo "POST_BRINGUP_MIGRATION=${result}"
  return 0
}

# Emit completion semantics fields. Bringup process PASS never implies cluster ready.
p2b_emit_completion_semantics() {
  local bringup_pass="${1:-NO}"
  local cluster_validation="${2:-PENDING}"
  local migration
  p2b_load_post_bringup_migration || true
  migration="${POST_BRINGUP_MIGRATION:-NOT_CHECKED}"
  local dp_complete=NO
  if [[ "$bringup_pass" == "YES" \
    && "$cluster_validation" == "PASS" \
    && ( "$migration" == "NOT_REQUIRED" || "$migration" == "PASS" ) ]]; then
    dp_complete=YES
  fi
  cat <<EOF
BRINGUP_PROCESS_SUCCESS=${bringup_pass}
CLUSTER_VALIDATION=${cluster_validation}
POST_BRINGUP_MIGRATION=${migration}
REQUIRED_POST_BRINGUP_ACTION=${REQUIRED_POST_BRINGUP_ACTION:-UNKNOWN}
DP_UPGRADE_COMPLETE=${dp_complete}
EOF
}
