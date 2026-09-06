#!/usr/bin/env bash
# Lifecycle-owned worker password is removed after COMPLETED/FAILED; external files stay.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="${ROOT}/client/bringup_py3_dp_lifecycle.sh"
LIB="${ROOT}/client/lib/dp-phase2-bringup-lifecycle.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export PHASE2_BRINGUP_DIR="${TMP}/lifecycle"
export PHASE2_BRINGUP_LOG_DEFAULT="${TMP}/bringup.log"
export PHASE2_BRINGUP_ALLOW_NONROOT=1
export DP_PHASE2_BRINGUP_LIB_ONLY=1
mkdir -p "$PHASE2_BRINGUP_DIR"
# shellcheck source=/dev/null
source "$LIB"
# shellcheck source=/dev/null
source "$WRAPPER"

# 7. lifecycle-owned password exists while worker needs it.
p2b_store_worker_password 's3cret!value'
owned="$(p2b_dir)/worker-password"
[[ -f "$owned" ]] || fail "owned password missing while worker would need it"
[[ "$(stat -c '%a' "$owned")" == "600" ]] || fail "owned password mode"
[[ "$WORKER_PASSWORD_FILE_OWNED" == "YES" ]] || fail "OWNED marker not YES"
[[ "$(cat "$owned")" == 's3cret!value' ]] || fail "owned password contents"
pass "lifecycle-owned password exists while worker needs it"

# 8. COMPLETED cleanup
p2b_write_state "COMPLETED"
p2b_cleanup_lifecycle_owned_worker_password
[[ ! -f "$owned" ]] || fail "owned password remained after COMPLETED cleanup"
[[ ! -f "$(p2b_dir)/worker-password.owned" ]] || fail "owned marker remained after COMPLETED"
pass "lifecycle-owned password removed after COMPLETED"

# 9. FAILED cleanup
p2b_store_worker_password 'fail-secret'
p2b_write_state "FAILED"
p2b_cleanup_lifecycle_owned_worker_password
[[ ! -f "$owned" ]] || fail "owned password remained after FAILED cleanup"
pass "lifecycle-owned password removed after FAILED"

# 10. external --worker-password-file is preserved
ext="${TMP}/operator-password"
printf 'external-secret\n' >"$ext"
chmod 0600 "$ext"
WORKER_PASSWORD_FILE="$ext"
WORKER_PASSWORD_FILE_OWNED=NO
rm -f "$(p2b_dir)/worker-password.owned"
p2b_write_state "COMPLETED"
p2b_cleanup_lifecycle_owned_worker_password
[[ -f "$ext" ]] || fail "external password file was deleted"
[[ "$(cat "$ext")" == "external-secret" ]] || fail "external password mutated"
pass "external --worker-password-file preserved after terminal state"

# 11. archived failed-run state contains no plaintext worker password
p2b_store_worker_password 'archive-secret-should-not-leak'
p2b_write_state "FAILED"
printf 'BRINGUP_RESULT=FAIL\n' >"$(p2b_dir)/result.env"
p2b_archive_failed_run
if grep -RIn 'archive-secret-should-not-leak' "$(p2b_dir)/previous-failed" >/dev/null 2>&1; then
  fail "archived failed run leaked plaintext worker password"
fi
[[ ! -f "$(p2b_dir)/previous-failed/worker-password" ]] \
  || fail "archive copied worker-password"
pass "archived failed lifecycle data contains no plaintext worker password"

# Detached worker EXIT trap removes owned password after a fake vendor COMPLETED.
rm -rf "$(p2b_dir)"
p2b_ensure_dir
VENDOR="${TMP}/vendor.sh"
cat >"$VENDOR" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$VENDOR"
p2b_store_worker_password 'worker-run-secret'
run_id="$(p2b_new_run_id)"
printf '%s\n' "$run_id" | p2b_atomic_write "$(p2b_dir)/run-id"
printf '6.6.0\n' | p2b_atomic_write "$(p2b_dir)/target-version"
printf '%s\n' "$PHASE2_BRINGUP_LOG_DEFAULT" | p2b_atomic_write "$(p2b_dir)/log-path"
printf '%s\n' "$(p2b_utc_now)" | p2b_atomic_write "$(p2b_dir)/started-at"
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
WORKER_PASSWORD_FILE="$owned"
WORKER_PASSWORD_FILE_OWNED=YES
set +e
(
  p2b_worker_main "$VENDOR" --version 6.6.0 >/dev/null 2>&1
)
set -e
[[ ! -f "$(p2b_dir)/worker-password" ]] \
  || fail "worker_main left owned password after COMPLETED"
pass "detached worker cleanup after COMPLETED"

# Status/diagnose must not print password contents.
p2b_store_worker_password 'diagnose-secret-xyz'
p2b_print_status >"${TMP}/status.out"
if grep -q 'diagnose-secret-xyz' "${TMP}/status.out"; then
  fail "status printed worker password"
fi
pass "status does not print password contents"

echo "ALL test_lifecycle_password_cleanup checks passed"
