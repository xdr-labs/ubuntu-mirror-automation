#!/usr/bin/env bash
# Ownership: numeric UID/primary GID (literal group aella forbidden).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/client/stage-dp-phase2.sh"
WRAP="${ROOT}/client/stage-dp-phase2-6.5.0.sh"
FRAGMENT="${ROOT}/scripts/lib/phase2_bringup_patch/fragment_compat.sh"
PATCHER="${ROOT}/scripts/lib/patch_dp_phase2_bringup.py"
VENDOR_BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

OWNERSHIP_SCAN_PATHS=(
  "$HELPER"
  "$WRAP"
  "$FRAGMENT"
  "$PATCHER"
  "$VENDOR_BRINGUP"
)
# Also scan every fragment under phase2_bringup_patch/
while IFS= read -r -d '' f; do
  OWNERSHIP_SCAN_PATHS+=("$f")
done < <(find "${ROOT}/scripts/lib/phase2_bringup_patch" -type f -print0 2>/dev/null)

echo "[test] static: no literal aella group ownership"
# Match ownership mutations only (not `id -g aella` lookups).
if grep -En -- 'chown[[:space:]]+aella:aella|install[[:space:]]+-o[[:space:]]+aella|[[:space:]]-g[[:space:]]+aella[[:space:]]+-m' \
  "${OWNERSHIP_SCAN_PATHS[@]}"; then
  fail "literal aella group present"
else
  pass "no -g aella / aella:aella across stage+patch+vendor"
fi

echo "[test] fragment resolves numeric id -u/-g aella (not aella:aella)"
grep -Eq 'id -u aella' "$FRAGMENT" \
  && grep -Eq 'id -g aella' "$FRAGMENT" \
  && ! grep -Eq 'chown[[:space:]]+aella:aella' "$FRAGMENT" \
  && pass "fragment uses id -u/-g aella" \
  || fail "fragment missing numeric aella identity resolution"

echo "[test] runtime numeric ownership install"
export DP_PHASE2_STAGE_LIB_ONLY=1
# shellcheck disable=SC1090
source "$HELPER"

# Fake id/getent for aella with primary group != aella
id() {
  case "$*" in
    "-u aella") printf '1000\n' ;;
    "-g aella") printf '27\n' ;;
    "-gn aella") printf 'sudo\n' ;;
    "-u") printf '0\n' ;;
    *) command id "$@" ;;
  esac
}
getent() {
  case "$*" in
    "passwd aella") printf 'aella:x:1000:27::/home/aella:/bin/bash\n' ;;
    "group 27") printf 'sudo:x:27:\n' ;;
    *) command getent "$@" ;;
  esac
}

resolve_aella_ownership
assert_vals() {
  [[ "$AELLA_UID" == "1000" ]] && pass "UID=1000" || fail "UID"
  [[ "$AELLA_PRIMARY_GID" == "27" ]] && pass "GID=27" || fail "GID"
  [[ "$AELLA_PRIMARY_GROUP" == "sudo" ]] && pass "GROUP=sudo" || fail "GROUP"
  [[ "$AELLA_OWNERSHIP_CHECK" == "PASS" ]] && pass "OWNERSHIP_CHECK" || fail "OWNERSHIP_CHECK"
}
assert_vals

# Exercise install with numeric ids into temp paths
SRC="${WORKDIR}/bringup.sh"
DST="${WORKDIR}/out.sh"
printf '#!/bin/bash\necho hi\n' >"$SRC"
cu="$(command id -u)"; cg="$(command id -g)"
install -o "$cu" -g "$cg" -m 0755 "$SRC" "$DST"
[[ "$(stat -c '%u' "$DST")" == "$cu" ]] && pass "install numeric uid" || fail "install uid"
[[ "$(stat -c '%g' "$DST")" == "$cg" ]] && pass "install numeric gid" || fail "install gid"

# Run the preflight as an unconditional call in a fresh strict Bash process.
# Putting the function itself in an if/|| condition would mask the set -e bug.
cat >"${WORKDIR}/ownership-case.sh" <<'CASE'
#!/usr/bin/env bash
set -euo pipefail
export DP_PHASE2_STAGE_LIB_ONLY=1
source "$1"
fixture_case="$2"
id() {
  case "$*" in
    "-u aella")
      [[ "$fixture_case" != "uid_lookup_failed" ]] || return 1
      if [[ "$fixture_case" == "invalid_uid" ]]; then printf 'invalid\n'; else printf '1000\n'; fi ;;
    "-g aella")
      [[ "$fixture_case" != "gid_lookup_failed" ]] || return 1
      if [[ "$fixture_case" == "invalid_gid" ]]; then printf 'invalid\n'; else printf '1000\n'; fi ;;
    "-gn aella")
      if [[ "$fixture_case" == "missing_group" ]]; then
        printf '1000\n'
        printf 'id: cannot find name for group ID 1000\n' >&2
        return 1
      fi
      printf 'aella\n' ;;
    "-u") printf '0\n' ;;
    *) command id "$@" ;;
  esac
}
getent() {
  case "$*" in
    "passwd aella")
      local record='aella:x:1000:1000::/home/aella:/bin/bash'
      case "$fixture_case" in
        missing_passwd) return 2 ;;
        duplicate_passwd) printf '%s\n%s\n' "$record" "$record"; return 0 ;;
        wrong_account) record='root:x:1000:1000::/home/aella:/bin/bash' ;;
        mismatched_uid) record='aella:x:1001:1000::/home/aella:/bin/bash' ;;
        mismatched_gid) record='aella:x:1000:1001::/home/aella:/bin/bash' ;;
        wrong_shell) record='aella:x:1000:1000::/home/aella:/bin/false' ;;
      esac
      printf '%s\n' "$record" ;;
    "group 1000")
      [[ "$fixture_case" != "missing_group" ]] || return 2
      printf 'aella:x:1000:\n' ;;
    *) return 2 ;;
  esac
}
resolve_aella_ownership
printf 'OWNERSHIP_PREFLIGHT_CONTINUED=%s:%s:%s\n' \
  "$AELLA_UID" "$AELLA_PRIMARY_GID" "$AELLA_PRIMARY_GROUP"
CASE

echo "[test] missing group name preserves numeric aella identity under set -e"
set +e
bash "${WORKDIR}/ownership-case.sh" "$HELPER" missing_group >"${WORKDIR}/missing_group.out" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q '^OWNERSHIP_PREFLIGHT_CONTINUED=1000:1000:UNRESOLVED$' "${WORKDIR}/missing_group.out" \
  && grep -q '^AELLA_PRIMARY_GROUP_LOOKUP=WARN .*gid=1000' "${WORKDIR}/missing_group.out" \
  && grep -q '^AELLA_OWNERSHIP_CHECK=PASS$' "${WORKDIR}/missing_group.out"; then
  pass "unresolved group name continues with verified UID/GID 1000:1000"
else
  cat "${WORKDIR}/missing_group.out"
  fail "unresolved group name should not abort numeric ownership preflight"
fi

expect_ownership_stop() {
  local fixture_case="$1" diagnostic="$2" rc
  set +e
  bash "${WORKDIR}/ownership-case.sh" "$HELPER" "$fixture_case" >"${WORKDIR}/${fixture_case}.out" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]] \
    && grep -q -- "$diagnostic" "${WORKDIR}/${fixture_case}.out" \
    && ! grep -q '^OWNERSHIP_PREFLIGHT_CONTINUED=' "${WORKDIR}/${fixture_case}.out"; then
    pass "${fixture_case} stops before staging"
  else
    cat "${WORKDIR}/${fixture_case}.out"
    fail "${fixture_case} must stop with ${diagnostic}"
  fi
}
expect_ownership_stop missing_passwd 'reason=passwd_lookup_failed'
expect_ownership_stop duplicate_passwd 'reason=invalid_passwd_record'
expect_ownership_stop wrong_account 'reason=invalid_passwd_record'
expect_ownership_stop uid_lookup_failed 'reason=uid_lookup_failed'
expect_ownership_stop gid_lookup_failed 'reason=gid_lookup_failed'
expect_ownership_stop invalid_uid 'AELLA_UID not numeric'
expect_ownership_stop invalid_gid 'AELLA_PRIMARY_GID not numeric'
expect_ownership_stop mismatched_uid 'reason=passwd_id_mismatch'
expect_ownership_stop mismatched_gid 'reason=passwd_id_mismatch'
expect_ownership_stop wrong_shell 'PHASE2_AELLA_SHELL_PREFLIGHT=FAIL'

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL DP PHASE2 OWNERSHIP TESTS PASSED"
  exit 0
fi
echo "SOME DP PHASE2 OWNERSHIP TESTS FAILED"
exit 1
