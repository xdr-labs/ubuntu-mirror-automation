#!/usr/bin/env bash
# Partial login-shell transaction rollback: FAIL on aella after root changed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

SCRIPT_IN_RAW="${ROOT}/client/dp-offline-upgrade-xenial-to-bionic.sh.in"

HARNESS="${OUT_DIR}/shell-harness.sh"
{
  cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="${DP_OFFLINE_TEST_ROOT:-}"
LOG_FILE="/dev/null"
EC_INTERNAL=99
BACKUP_ROOT="/opt/aelladata/os-upgrade/offline/backup"
hostpath() {
  local p="$1"
  if [[ -n "$TEST_ROOT" ]]; then printf '%s%s' "$TEST_ROOT" "$p"; else printf '%s' "$p"; fi
}
log() { local level="$1"; shift; printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*"; }
die() { local code="$1"; shift; log ERROR "$* (exit=${code})"; exit "$code"; }
utc_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
EOS
  awk '/^change_login_shells\(\)/,/^install_runner_and_units\(\)/ {
    if (/^install_runner_and_units/) exit
    print
  }' "$SCRIPT_IN_RAW"
  printf '%s\n' 'change_login_shells "stamp1"'
} >"$HARNESS"
chmod +x "$HARNESS"

fx="${OUT_DIR}/fx"
mkdir -p "$fx/etc" "$fx/tmp" "$fx/bin" "$fx/opt/aelladata/os-upgrade/offline/backup" \
  "$fx/var/log/aella" "$fx/home/aella"
ln -sf /bin/bash "$fx/bin/bash" 2>/dev/null || true
printf 'NAME="Ubuntu"\nVERSION_ID="16.04"\nVERSION_CODENAME=xenial\n' >"$fx/etc/os-release"
# root non-/bin/bash so it mutates before aella injected failure
printf 'root:x:0:0:root:/root:/bin/sh\naella:x:1000:1000:aella:/home/aella:/usr/bin/aella_cli\n' \
  >"$fx/etc/passwd"

set +e
DP_OFFLINE_TEST_ROOT="$fx" DP_OFFLINE_FAKE_SHELL_CHANGE_FAIL_USER=aella \
  bash "$HARNESS" >"$fx/out.txt" 2>&1
rc=$?
set -e

if [[ "$rc" -ne 0 ]] \
  && grep -q 'LOGIN_SHELL_TRANSACTION_ROLLBACK=BEGIN' "$fx/out.txt" \
  && grep -q '^root:.*:/bin/sh$' "$fx/etc/passwd" \
  && grep -q '^aella:.*:/usr/bin/aella_cli$' "$fx/etc/passwd" \
  && ! grep -qE 'CRITICAL_OS_UNHOLD_BEGIN|do-release-upgrade|DRO_BEGIN' "$fx/out.txt"; then
  pass "root restored, aella original preserved, no DRO"
else
  fail "partial shell rollback contract broken (rc=${rc})"
  cat "$fx/out.txt" || true
  cat "$fx/etc/passwd" || true
fi

[[ "$FAIL" -eq 0 ]]
echo "ALL LOGIN SHELL PARTIAL ROLLBACK TESTS PASSED"
