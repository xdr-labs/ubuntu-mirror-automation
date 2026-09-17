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

# Primary GID failure
getent() {
  case "$*" in
    "passwd aella") printf 'aella:x:1000:27::/home/aella:/bin/bash\n' ;;
    "group 27") return 1 ;;
    *) return 1 ;;
  esac
}
set +e
out="$(resolve_aella_ownership 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'not resolvable' && pass "GID resolve STOP" || fail "GID resolve should STOP"

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL DP PHASE2 OWNERSHIP TESTS PASSED"
  exit 0
fi
echo "SOME DP PHASE2 OWNERSHIP TESTS FAILED"
exit 1
