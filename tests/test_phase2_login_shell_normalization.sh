#!/usr/bin/env bash
# Phase 2-only aella login-shell normalization, hermetic: never mutate host accounts.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/fixture.sh" <<'CASE'
#!/usr/bin/env bash
set -euo pipefail
export DP_PHASE2_STAGE_LIB_ONLY=1
source "$1"
scenario="$2"
state="$3"
case "$scenario" in
  already_bash) shell=/bin/bash ;;
  usr_bin_bash) shell=/usr/bin/bash ;;
  unsupported) shell=/bin/false ;;
  *) shell=/usr/bin/aella_cli ;;
esac
printf 'aella:x:1000:27::/home/aella:%s\n' "$shell" >"$state"
getent() {
  [[ "$*" == 'passwd aella' ]] || return 2
  cat "$state"
}
id() {
  case "$*" in
    '-u aella') printf '1000\n' ;;
    '-g aella') printf '27\n' ;;
    '-gn aella') printf 'sudo\n' ;;
    *) command id "$@" ;;
  esac
}
usermod() {
  printf 'MOCK_USERMOD=%s\n' "$*"
  [[ "$*" == '-s /bin/bash aella' ]] || return 2
  [[ "$scenario" != usermod_error ]] || return 1
  [[ "$scenario" != no_effect ]] || return 0
  sed -i 's#/usr/bin/aella_cli$#/bin/bash#;s#/usr/bin/bash$#/bin/bash#' "$state"
  if [[ "$scenario" == identity_change ]]; then
    sed -i 's/^aella:x:1000:/aella:x:1001:/' "$state"
  fi
}
resolve_aella_ownership
normalize_phase2_aella_login_shell
printf 'NORMALIZATION_DONE=YES\n'
CASE

check() {
  local scenario="$1" expect="$2" marker="$3" rc=0
  bash "$TMP/fixture.sh" "$ROOT/client/stage-dp-phase2.sh" "$scenario" "$TMP/$scenario.passwd" \
    >"$TMP/$scenario.out" 2>&1 || rc=$?
  if [[ "$expect" == pass ]]; then
    [[ "$rc" -eq 0 ]] || { cat "$TMP/$scenario.out"; return 1; }
    grep -Fq 'NORMALIZATION_DONE=YES' "$TMP/$scenario.out"
    grep -Fq -- "$marker" "$TMP/$scenario.out"
    grep -q ':/bin/bash$' "$TMP/$scenario.passwd"
  else
    [[ "$rc" -ne 0 ]] || { cat "$TMP/$scenario.out"; return 1; }
    grep -Fq -- "$marker" "$TMP/$scenario.out"
    ! grep -Fq 'NORMALIZATION_DONE=YES' "$TMP/$scenario.out"
  fi
  printf 'PASS: phase2 shell fixture %s\n' "$scenario"
}
check already_bash pass 'PHASE2_AELLA_SHELL_CHANGE=UNCHANGED'
! grep -q '^MOCK_USERMOD=' "$TMP/already_bash.out"
check usr_bin_bash pass 'PHASE2_AELLA_SHELL_CHANGE=CHANGED from=/usr/bin/bash'
check stellar_cli pass 'PHASE2_AELLA_SHELL_CHANGE=CHANGED from=/usr/bin/aella_cli'
check unsupported fail 'PHASE2_AELLA_SHELL_PREFLIGHT=FAIL reason=unsupported_shell'
! grep -q '^MOCK_USERMOD=' "$TMP/unsupported.out"
check usermod_error fail 'PHASE2_AELLA_SHELL_CHANGE=FAIL reason=usermod_failed'
check no_effect fail 'PHASE2_AELLA_SHELL_CHANGE=FAIL reason=verify_mismatch'
check identity_change fail 'PHASE2_AELLA_SHELL_CHANGE=FAIL reason=verify_mismatch'

echo 'PHASE2_LOGIN_SHELL_NORMALIZATION=PASS'
