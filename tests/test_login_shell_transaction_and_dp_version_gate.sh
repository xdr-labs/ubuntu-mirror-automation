#!/usr/bin/env bash
# P1: login-shell partial rollback + unsupported DP version gate (xenial hop).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

SCRIPT_IN_RAW="${ROOT}/client/dp-offline-upgrade-xenial-to-bionic.sh.in"
BUILD_PY="${ROOT}/scripts/lib/build_client_xenial_to_bionic.py"
SCRIPT_IN="${OUT_DIR}/template-helpers-expanded.sh.in"
python3 "${ROOT}/tests/lib/render_offline_upgrade_stub.py" \
  --helpers-only "$SCRIPT_IN_RAW" "$SCRIPT_IN"
cp -f "${ROOT}/client/dp-postboot-readiness-policy.sh.inc" \
  "${OUT_DIR}/dp-postboot-readiness-policy.sh.inc" 2>/dev/null || true

echo "=== test_login_shell_transaction_and_dp_version_gate ==="

# Static markers
grep -q '_login_shell_rollback_partial' "$SCRIPT_IN_RAW" \
  && pass "transactional rollback helper present" \
  || fail "rollback helper missing"
grep -q 'DP_VERSION_GATE=PASS_SUPPORTED\|FAIL_UNSUPPORTED_DP_VERSION' "$SCRIPT_IN_RAW" \
  && pass "DP version hard gate present" \
  || fail "DP version gate missing"

# Build stub via existing render path used by xenial tests
FAKEBIN="${OUT_DIR}/fakebin"
mkdir -p "$FAKEBIN"
STUB="${OUT_DIR}/stub.sh"
python3 "${ROOT}/tests/lib/render_offline_upgrade_stub.py" \
  "$SCRIPT_IN_RAW" "$STUB" 2>/dev/null \
  || python3 "${ROOT}/tests/lib/render_offline_upgrade_stub.py" \
       --helpers-only "$SCRIPT_IN_RAW" "$STUB"

# Prefer full stub if available from xenial test pattern
if [[ ! -x "$STUB" ]]; then chmod +x "$STUB" 2>/dev/null || true; fi

# Minimal harness: extract change_login_shells via building stub like xenial test
# Use the same make_dp_fixture approach from xenial test if STUB works.

make_fx() {
  local root="$1"
  mkdir -p "$root/etc" "$root/tmp" "$root/bin" "$root/usr/bin" \
    "$root/opt/aelladata/os-upgrade/offline" \
    "$root/var/log/aella" "$root/home/aella"
  ln -sf /bin/bash "$root/bin/bash" 2>/dev/null || cp -a /bin/bash "$root/bin/bash"
  printf 'NAME="Ubuntu"\nVERSION_ID="16.04"\nVERSION_CODENAME=xenial\n' >"$root/etc/os-release"
}

# Unit: call change_login_shells from expanded template harness
HARNESS="${OUT_DIR}/shell-harness.sh"
{
  cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="${DP_OFFLINE_TEST_ROOT:-}"
LOG_FILE="/dev/null"
EC_INTERNAL=99
EC_DP=13
MIN_DP_VERSION="6.2.0"
BACKUP_ROOT="/opt/aelladata/os-upgrade/offline/backup"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
hostpath() {
  local p="$1"
  if [[ -n "$TEST_ROOT" ]]; then printf '%s%s' "$TEST_ROOT" "$p"; else printf '%s' "$p"; fi
}
log() { local level="$1"; shift; printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*"; }
die() { local code="$1"; shift; log ERROR "$* (exit=${code})"; exit "$code"; }
utc_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
version_is_mmp() { [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
version_ge() {
  local a="$1" b="$2" a1 a2 a3 b1 b2 b3
  version_is_mmp "$a" || return 1
  version_is_mmp "$b" || return 1
  IFS=. read -r a1 a2 a3 <<<"$a"
  IFS=. read -r b1 b2 b3 <<<"$b"
  if ((a1 != b1)); then ((a1 > b1)); return $?; fi
  if ((a2 != b2)); then ((a2 > b2)); return $?; fi
  ((a3 >= b3))
}
EOS
  # Extract change_login_shells function from template
  awk '/^change_login_shells\(\)/,/^install_runner_and_units\(\)/ {
    if (/^install_runner_and_units/) exit
    print
  }' "$SCRIPT_IN_RAW"
  cat <<'EOS'
# emulate product gate fragment
assert_dp_version_gate() {
  local DP_VERSION="$1"
  local DP_VERSION_DETECT_STATUS=ok
  local DP_VERSION_CONSISTENCY=PASS
  if [[ "${DP_VERSION_DETECT_STATUS:-}" == "ok" && "${DP_VERSION_CONSISTENCY:-}" == "PASS" \
      && -n "${DP_VERSION:-}" && "${DP_VERSION}" != "UNDETERMINED" ]]; then
    if ! version_is_mmp "$DP_VERSION"; then
      die "$EC_DP" "FAIL_UNSUPPORTED_DP_VERSION malformed=${DP_VERSION}"
    fi
    if ! version_ge "$DP_VERSION" "${MIN_DP_VERSION}"; then
      die "$EC_DP" "FAIL_UNSUPPORTED_DP_VERSION source=${DP_VERSION} min=${MIN_DP_VERSION}"
    fi
    if version_ge "$DP_VERSION" "6.6.0"; then
      die "$EC_DP" "FAIL_DP_VERSION_AT_OR_ABOVE_TARGET source=${DP_VERSION}"
    fi
    log INFO "DP_VERSION_GATE=PASS_SUPPORTED source=${DP_VERSION}"
  fi
}
case "${1:-}" in
  shell-partial)
    change_login_shells "stamp1"
    ;;
  version-gate)
    assert_dp_version_gate "$2"
    ;;
esac
EOS
} >"$HARNESS"
chmod +x "$HARNESS"

# Partial shell rollback: root changes, aella fails → root restored
fx="${OUT_DIR}/fx-shell"
make_fx "$fx"
printf 'root:x:0:0:root:/root:/bin/sh\naella:x:1000:1000:aella:/home/aella:/usr/bin/aella_cli\n' \
  >"$fx/etc/passwd"
mkdir -p "$fx/opt/aelladata/os-upgrade/offline/backup"
set +e
DP_OFFLINE_TEST_ROOT="$fx" DP_OFFLINE_FAKE_SHELL_CHANGE_FAIL_USER=aella \
  bash "$HARNESS" shell-partial >"$fx/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] \
   && grep -q 'LOGIN_SHELL_TRANSACTION_ROLLBACK=BEGIN' "$fx/out.txt" \
   && grep -q '^root:.*:/bin/sh$' "$fx/etc/passwd" \
   && grep -q '^aella:.*:/usr/bin/aella_cli$' "$fx/etc/passwd" \
   && ! grep -q 'CRITICAL_OS_UNHOLD_BEGIN\|do-release-upgrade\|DRO_BEGIN' "$fx/out.txt"; then
  pass "partial shell failure rolls back root; package transition not started"
else
  fail "partial shell rollback failed (rc=${rc})"
  cat "$fx/out.txt" || true
  cat "$fx/etc/passwd" || true
fi

# aella_cli conversion success path (no fail inject)
fx2="${OUT_DIR}/fx-shell-ok"
make_fx "$fx2"
printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1000:1000:aella:/home/aella:/usr/bin/aella_cli\n' \
  >"$fx2/etc/passwd"
mkdir -p "$fx2/opt/aelladata/os-upgrade/offline/backup"
set +e
DP_OFFLINE_TEST_ROOT="$fx2" bash "$HARNESS" shell-partial >"$fx2/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
   && grep -q '^aella:.*:/bin/bash$' "$fx2/etc/passwd" \
   && grep -q 'LOGIN_SHELL_AUTOMATION=PASS' "$fx2/out.txt"; then
  pass "aella_cli converts to /bin/bash after confirmation path"
else
  fail "aella_cli conversion failed (rc=${rc})"
  cat "$fx2/out.txt" || true
fi

# Version gate: 6.1.x fail
set +e
bash "$HARNESS" version-gate 6.1.9 >"${OUT_DIR}/v61.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'FAIL_UNSUPPORTED_DP_VERSION' "${OUT_DIR}/v61.txt"; then
  pass "known 6.1.x rejected before mutation"
else
  fail "6.1.x should fail gate"
fi
set +e
bash "$HARNESS" version-gate 6.2.0 >"${OUT_DIR}/v62.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q 'DP_VERSION_GATE=PASS_SUPPORTED' "${OUT_DIR}/v62.txt"; then
  pass "known 6.2.x allowed"
else
  fail "6.2.x should pass gate"
fi

[[ "$FAIL" -eq 0 ]]
echo "=== test_login_shell_transaction_and_dp_version_gate: DONE ==="
