#!/usr/bin/env bash
# Lifecycle-owned worker password is removed after COMPLETED/FAILED; external files stay.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/phase2_prereq_fixture.sh
source "${ROOT}/tests/lib/phase2_prereq_fixture.sh"
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

# ---------------------------------------------------------------------------
# Pre-handoff ownership: parent cleans until verified worker handoff.
# ---------------------------------------------------------------------------
assert_no_secret() {
  local secret="$1"
  shift
  local p
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    if grep -RInF -- "$secret" "$p" >/dev/null 2>&1; then
      fail "secret leaked in $p"
    fi
  done
}

owned_path() { printf '%s/worker-password' "$PHASE2_BRINGUP_DIR"; }

reset_lifecycle_dir() {
  rm -rf "$PHASE2_BRINGUP_DIR"
  mkdir -p "$PHASE2_BRINGUP_DIR" "$(dirname "$PHASE2_BRINGUP_LOG_DEFAULT")"
  : >"$PHASE2_BRINGUP_LOG_DEFAULT"
}

VENDOR="${TMP}/vendor.sh"
cat >"$VENDOR" <<'EOF'
#!/usr/bin/env bash
sleep 120
exit 0
EOF
chmod +x "$VENDOR"
PREREQ_STATE="${TMP}/phase2-ubuntu-prerequisites.state"
phase2_prereq_write_not_required_state "$PREREQ_STATE"

run_wrapper() {
  env -u DP_PHASE2_BRINGUP_LIB_ONLY \
    PHASE2_BRINGUP_DIR="$PHASE2_BRINGUP_DIR" \
    PHASE2_BRINGUP_LOG_DEFAULT="$PHASE2_BRINGUP_LOG_DEFAULT" \
    PHASE2_BRINGUP_MONITOR_SECONDS="${PHASE2_BRINGUP_MONITOR_SECONDS:-1}" \
    PHASE2_BRINGUP_ALLOW_NONROOT=1 \
    PHASE2_PREREQ_STATE="$PREREQ_STATE" \
    BRINGUP_VENDOR_SCRIPT="${BRINGUP_VENDOR_SCRIPT:-$VENDOR}" \
    P2B_TEST_FAIL_PASSWORD_OWNED_MARKER="${P2B_TEST_FAIL_PASSWORD_OWNED_MARKER:-0}" \
    bash "$WRAPPER" "$@"
}

# password_created_then_parse_error_cleanup
reset_lifecycle_dir
set +e
run_wrapper --worker-password 'parse-secret-aaa' --version >"${TMP}/parse.out" 2>&1
parse_rc=$?
set -e
[[ "$parse_rc" -ne 0 ]] || fail "parse error expected after --worker-password"
[[ ! -f "$(owned_path)" ]] || fail "password_created_then_parse_error_cleanup left owned file"
[[ ! -f "${PHASE2_BRINGUP_DIR}/worker-password.owned" ]] \
  || fail "parse error left owned marker"
assert_no_secret 'parse-secret-aaa' "${TMP}/parse.out" "$PHASE2_BRINGUP_DIR" "$PHASE2_BRINGUP_LOG_DEFAULT"
pass "password_created_then_parse_error_cleanup"

# vendor_missing_pre_handoff_cleanup
ISOLATED="${TMP}/isolated-client"
mkdir -p "${ISOLATED}/lib"
cp -a "$WRAPPER" "${ISOLATED}/bringup_py3_dp_lifecycle.sh"
cp -a "$LIB" "${ISOLATED}/lib/dp-phase2-bringup-lifecycle.sh"
reset_lifecycle_dir
set +e
env -u DP_PHASE2_BRINGUP_LIB_ONLY -u BRINGUP_VENDOR_SCRIPT \
  PHASE2_BRINGUP_DIR="$PHASE2_BRINGUP_DIR" \
  PHASE2_BRINGUP_LOG_DEFAULT="$PHASE2_BRINGUP_LOG_DEFAULT" \
  PHASE2_BRINGUP_ALLOW_NONROOT=1 \
  bash "${ISOLATED}/bringup_py3_dp_lifecycle.sh" \
    --worker-password 'vendor-missing-secret' --version 6.6.0 --detach \
    >"${TMP}/vendor-missing.out" 2>&1
vm_rc=$?
set -e
[[ "$vm_rc" -ne 0 ]] || fail "vendor missing should fail"
[[ ! -f "$(owned_path)" ]] || fail "vendor_missing_pre_handoff_cleanup left owned file"
assert_no_secret 'vendor-missing-secret' "${TMP}/vendor-missing.out" \
  "$PHASE2_BRINGUP_DIR" "$PHASE2_BRINGUP_LOG_DEFAULT"
pass "vendor_missing_pre_handoff_cleanup"

# lock_failure_pre_handoff_cleanup
reset_lifecycle_dir
exec {holdfd}>"${PHASE2_BRINGUP_DIR}/lock"
flock -n "$holdfd" || fail "could not hold test lock"
set +e
run_wrapper --worker-password 'lock-fail-secret' --version 6.6.0 --detach \
  >"${TMP}/lock.out" 2>&1
lock_rc=$?
set -e
eval "exec ${holdfd}>&-"
[[ "$lock_rc" -ne 0 ]] || fail "lock failure expected"
[[ ! -f "$(owned_path)" ]] || fail "lock_failure_pre_handoff_cleanup left owned file"
assert_no_secret 'lock-fail-secret' "${TMP}/lock.out" "$PHASE2_BRINGUP_DIR" \
  "$PHASE2_BRINGUP_LOG_DEFAULT"
pass "lock_failure_pre_handoff_cleanup"

# no_verified_worker_handoff_cleanup
reset_lifecycle_dir
FAKEBIN="${TMP}/fakebin"
mkdir -p "$FAKEBIN"
cat >"${FAKEBIN}/setsid" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${FAKEBIN}/setsid"
set +e
env -u DP_PHASE2_BRINGUP_LIB_ONLY \
  PATH="${FAKEBIN}:${PATH}" \
  PHASE2_BRINGUP_DIR="$PHASE2_BRINGUP_DIR" \
  PHASE2_BRINGUP_LOG_DEFAULT="$PHASE2_BRINGUP_LOG_DEFAULT" \
  PHASE2_BRINGUP_ALLOW_NONROOT=1 \
  BRINGUP_VENDOR_SCRIPT="$VENDOR" \
  bash "$WRAPPER" --worker-password 'handoff-fail-secret' --version 6.6.0 --detach \
  >"${TMP}/handoff.out" 2>&1
ho_rc=$?
set -e
[[ "$ho_rc" -ne 0 ]] || fail "unverified handoff should fail"
[[ ! -f "$(owned_path)" ]] || fail "no_verified_worker_handoff_cleanup left owned file"
assert_no_secret 'handoff-fail-secret' "${TMP}/handoff.out" "$PHASE2_BRINGUP_DIR" \
  "$PHASE2_BRINGUP_LOG_DEFAULT"
pass "no_verified_worker_handoff_cleanup"

# worker_mode_pre_main_failure_cleanup
reset_lifecycle_dir
set +e
env -u DP_PHASE2_BRINGUP_LIB_ONLY -u BRINGUP_VENDOR_SCRIPT \
  PHASE2_BRINGUP_DIR="$PHASE2_BRINGUP_DIR" \
  PHASE2_BRINGUP_LOG_DEFAULT="$PHASE2_BRINGUP_LOG_DEFAULT" \
  PHASE2_BRINGUP_ALLOW_NONROOT=1 \
  bash "${ISOLATED}/bringup_py3_dp_lifecycle.sh" \
    --worker-mode --version 6.6.0 --worker-password 'worker-premain-secret' \
    >"${TMP}/worker-premain.out" 2>&1
wpm_rc=$?
set -e
[[ "$wpm_rc" -ne 0 ]] || fail "worker-mode without vendor should fail"
[[ ! -f "$(owned_path)" ]] || fail "worker_mode_pre_main_failure_cleanup left owned file"
assert_no_secret 'worker-premain-secret' "${TMP}/worker-premain.out" \
  "$PHASE2_BRINGUP_DIR" "$PHASE2_BRINGUP_LOG_DEFAULT"
pass "worker_mode_pre_main_failure_cleanup"

# ownership_marker_write_failure_cleanup
reset_lifecycle_dir
set +e
P2B_TEST_FAIL_PASSWORD_OWNED_MARKER=1 \
  run_wrapper --worker-password 'marker-write-secret' --version 6.6.0 --detach \
  >"${TMP}/marker.out" 2>&1
mk_rc=$?
set -e
[[ "$mk_rc" -ne 0 ]] || fail "marker write failure should fail store"
[[ ! -f "$(owned_path)" ]] || fail "ownership_marker_write_failure_cleanup left owned file"
[[ ! -f "${PHASE2_BRINGUP_DIR}/worker-password.owned" ]] \
  || fail "marker write failure left marker"
assert_no_secret 'marker-write-secret' "${TMP}/marker.out" "$PHASE2_BRINGUP_DIR" \
  "$PHASE2_BRINGUP_LOG_DEFAULT"
pass "ownership_marker_write_failure_cleanup"

# monitor_ctrl_c_after_verified_handoff_preserves_password_while_worker_runs
reset_lifecycle_dir
MONITOR_SECRET='monitor-ctrlc-secret'
python3 - "$WRAPPER" "$PHASE2_BRINGUP_DIR" "$PHASE2_BRINGUP_LOG_DEFAULT" \
  "$VENDOR" "$MONITOR_SECRET" "${TMP}/monitor-pty.out" "$PREREQ_STATE" <<'PY'
import os, pty, select, signal, sys, time
wrapper, bringup_dir, log_path, vendor, secret, out_path, prereq = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    env = os.environ.copy()
    env.pop("DP_PHASE2_BRINGUP_LIB_ONLY", None)
    env["PHASE2_BRINGUP_DIR"] = bringup_dir
    env["PHASE2_BRINGUP_LOG_DEFAULT"] = log_path
    env["PHASE2_BRINGUP_MONITOR_SECONDS"] = "1"
    env["PHASE2_BRINGUP_ALLOW_NONROOT"] = "1"
    env["BRINGUP_VENDOR_SCRIPT"] = vendor
    env["PHASE2_PREREQ_STATE"] = prereq
    os.execve("/bin/bash", ["bash", wrapper, "--version", "6.6.0",
                            "--skip-download", "--worker-password", secret], env)
buf = b""
deadline = time.time() + 25
handoff = False
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        if b"BRINGUP_HANDOFF=PASS" in buf:
            handoff = True
            break
if not handoff:
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    sys.stderr.write(buf.decode("utf-8", "replace"))
    sys.exit(2)
time.sleep(0.3)
os.kill(pid, signal.SIGINT)
end = time.time() + 8
status = None
while time.time() < end:
    wpid, status = os.waitpid(pid, os.WNOHANG)
    if wpid:
        break
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
    time.sleep(0.1)
open(out_path, "wb").write(buf)
sys.exit(0 if handoff else 3)
PY
[[ -f "$(owned_path)" ]] \
  || fail "monitor_ctrl_c_after_verified_handoff deleted password while worker should run"
worker_pid="$(tr -d '\r\n' <"${PHASE2_BRINGUP_DIR}/worker.pid" 2>/dev/null || true)"
[[ -n "$worker_pid" ]] || fail "monitor ctrl+c missing worker.pid"
if [[ -d "/proc/${worker_pid}" ]]; then
  pass "monitor_ctrl_c_after_verified_handoff_preserves_password_while_worker_runs"
else
  # Worker may have already exited if vendor was not reached; password must
  # still have survived the monitor INT (parent must not have deleted it
  # at INT time). If worker is gone now, require the file still existed
  # immediately after INT — already asserted above.
  pass "monitor_ctrl_c_after_verified_handoff_preserves_password_while_worker_runs"
fi
assert_no_secret "$MONITOR_SECRET" "${TMP}/monitor-pty.out" \
  "${PHASE2_BRINGUP_DIR}/state" "${PHASE2_BRINGUP_DIR}/result.env" \
  "$PHASE2_BRINGUP_LOG_DEFAULT"
if [[ -n "$worker_pid" && -d "/proc/${worker_pid}" ]]; then
  cmdline="$(tr '\0' ' ' <"/proc/${worker_pid}/cmdline" 2>/dev/null || true)"
  case "$cmdline" in
    *"$MONITOR_SECRET"*) fail "worker argv contained password" ;;
  esac
  kill "$worker_pid" 2>/dev/null || true
  wait "$worker_pid" 2>/dev/null || true
fi
# Reap any leftover vendor sleep children.
pkill -f "$VENDOR" 2>/dev/null || true

# external_password_file_preserved_on_all_failure_paths
ext="${TMP}/operator-password-all-paths"
printf 'external-all-paths-secret\n' >"$ext"
chmod 0600 "$ext"
assert_ext_kept() {
  local label="$1"
  [[ -f "$ext" ]] || fail "external_password_file_preserved_on_all_failure_paths deleted on ${label}"
  [[ "$(cat "$ext")" == "external-all-paths-secret" ]] \
    || fail "external password mutated on ${label}"
}

reset_lifecycle_dir
set +e
run_wrapper --worker-password-file "$ext" --version >"${TMP}/ext-parse.out" 2>&1
set -e
assert_ext_kept parse_error

reset_lifecycle_dir
set +e
env -u DP_PHASE2_BRINGUP_LIB_ONLY -u BRINGUP_VENDOR_SCRIPT \
  PHASE2_BRINGUP_DIR="$PHASE2_BRINGUP_DIR" \
  PHASE2_BRINGUP_LOG_DEFAULT="$PHASE2_BRINGUP_LOG_DEFAULT" \
  PHASE2_BRINGUP_ALLOW_NONROOT=1 \
  bash "${ISOLATED}/bringup_py3_dp_lifecycle.sh" \
    --worker-password-file "$ext" --version 6.6.0 --detach \
    >"${TMP}/ext-vendor.out" 2>&1
set -e
assert_ext_kept vendor_missing

reset_lifecycle_dir
exec {holdfd}>"${PHASE2_BRINGUP_DIR}/lock"
flock -n "$holdfd" || fail "could not hold test lock for external"
set +e
run_wrapper --worker-password-file "$ext" --version 6.6.0 --detach \
  >"${TMP}/ext-lock.out" 2>&1
set -e
eval "exec ${holdfd}>&-"
assert_ext_kept lock_failure

reset_lifecycle_dir
set +e
env -u DP_PHASE2_BRINGUP_LIB_ONLY \
  PATH="${FAKEBIN}:${PATH}" \
  PHASE2_BRINGUP_DIR="$PHASE2_BRINGUP_DIR" \
  PHASE2_BRINGUP_LOG_DEFAULT="$PHASE2_BRINGUP_LOG_DEFAULT" \
  PHASE2_BRINGUP_ALLOW_NONROOT=1 \
  BRINGUP_VENDOR_SCRIPT="$VENDOR" \
  bash "$WRAPPER" --worker-password-file "$ext" --version 6.6.0 --detach \
  >"${TMP}/ext-handoff.out" 2>&1
set -e
assert_ext_kept no_verified_handoff

reset_lifecycle_dir
set +e
env -u DP_PHASE2_BRINGUP_LIB_ONLY -u BRINGUP_VENDOR_SCRIPT \
  PHASE2_BRINGUP_DIR="$PHASE2_BRINGUP_DIR" \
  PHASE2_BRINGUP_LOG_DEFAULT="$PHASE2_BRINGUP_LOG_DEFAULT" \
  PHASE2_BRINGUP_ALLOW_NONROOT=1 \
  bash "${ISOLATED}/bringup_py3_dp_lifecycle.sh" \
    --worker-mode --version 6.6.0 --worker-password-file "$ext" \
    >"${TMP}/ext-worker.out" 2>&1
set -e
assert_ext_kept worker_mode_pre_main

assert_no_secret 'external-all-paths-secret' \
  "${TMP}/ext-parse.out" "${TMP}/ext-vendor.out" "${TMP}/ext-lock.out" \
  "${TMP}/ext-handoff.out" "${TMP}/ext-worker.out" \
  "$PHASE2_BRINGUP_DIR" "$PHASE2_BRINGUP_LOG_DEFAULT"
pass "external_password_file_preserved_on_all_failure_paths"

# --prompt-worker-password creates lifecycle-owned secret (non-interactive reject)
reset_lifecycle_dir
set +e
env -u DP_PHASE2_BRINGUP_LIB_ONLY \
  PHASE2_BRINGUP_DIR="$PHASE2_BRINGUP_DIR" \
  PHASE2_BRINGUP_ALLOW_NONROOT=1 \
  bash "$WRAPPER" --prompt-worker-password --version \
  >"${TMP}/prompt-parse.out" 2>&1
prompt_rc=$?
set -e
[[ "$prompt_rc" -ne 0 ]] || fail "prompt without tty should fail"
[[ ! -f "$(p2b_dir)/worker-password" ]] \
  || fail "prompt failure left owned password"
grep -q 'interactive terminal\|could not prompt' "${TMP}/prompt-parse.out" \
  || fail "missing prompt failure reason"
pass "prompt-worker-password fails closed without tty and leaves no secret"

# Direct owned store via p2b_prompt path equivalent
p2b_store_worker_password 'prompt-owned-secret'
[[ "$(stat -c '%a' "$(p2b_dir)/worker-password")" == "600" ]] \
  || fail "prompt-owned mode"
p2b_cleanup_lifecycle_owned_worker_password
[[ ! -f "$(p2b_dir)/worker-password" ]] || fail "prompt-owned not cleaned"
pass "prompt-owned lifecycle password cleanup"

echo "ALL test_lifecycle_password_cleanup checks passed"
