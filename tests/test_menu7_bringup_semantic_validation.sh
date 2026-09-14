#!/usr/bin/env bash
# tests/test_menu7_bringup_semantic_validation.sh
# Regression: Menu 7 must validate executable bringup invocations, not arbitrary
# textual mentions of bringup_py3_dp_after_os_upgrade.sh (field false-negative).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_PROJECT_ROOT="$ROOT"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_LOG_DIR="$TMP/logs"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$TMP/config/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$TMP/config/status"
export MM_CLIENT_ROOT="$TMP/client"
export PREPARATION_MODE=FULL
export PHASE2_TARGET_VERSION=6.6.0
export TARGET_DP_VERSION=6.6.0
export MIRROR_HTTP_URL="http://192.0.2.10"
mkdir -p "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$MM_CLIENT_ROOT/lib"
: >"$MM_STATUS_FILE"

python3 "$ROOT/scripts/lib/build_client_launchers.py" \
  --project-root "$ROOT" \
  --output-dir "$MM_CLIENT_ROOT" \
  --mirror-base-url "$MIRROR_HTTP_URL" \
  --signing-fingerprint "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
  --expected-keyring-sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" \
    --expected-client-build-input-sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >/dev/null

# shellcheck source=/dev/null
source "$ROOT/scripts/lib/phase2_helper_generation.sh"
install -m 0755 "$ROOT/client/stage-dp-phase2.sh" "$MM_CLIENT_ROOT/stage-dp-phase2.sh"
install -m 0755 "$ROOT/client/bringup_py3_dp_lifecycle.sh" "$MM_CLIENT_ROOT/bringup_py3_dp_lifecycle.sh"
while IFS= read -r f; do
  [[ "$f" == lib/* ]] || continue
  install -m 0755 "$ROOT/client/$f" "$MM_CLIENT_ROOT/$f"
done < <(phase2_helper_generation_files)
phase2_helper_generation_write "$MM_CLIENT_ROOT" >/dev/null
# shellcheck source=lib/phase2_bundle_trust_fixture.sh
source "$ROOT/tests/lib/phase2_bundle_trust_fixture.sh"
phase2_trust_fixture_export_dp_phase2_root "$TMP" >/dev/null
phase2_trust_fixture_write_bundle_sidecar "$MM_DP_PHASE2_ROOT" "6.6.0" >/dev/null
phase2_upgrade_wrapper_write "$MM_CLIENT_ROOT" "$MIRROR_HTTP_URL" "6.6.0" >/dev/null

LIB="$TMP/installer-lib.sh"
awk -v sd="$ROOT/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$INSTALLER" >"$LIB"
# shellcheck disable=SC1090
source "$LIB"
# shellcheck source=../scripts/lib/mirror_workflow_state.sh
source "$ROOT/scripts/lib/mirror_workflow_state.sh"

BRINGUP_EXEC_RE='^sudo bash /home/aella/bringup_py3_dp_after_os_upgrade\.sh --version [0-9]+\.[0-9]+\.[0-9]+ --skip-download( --worker-ips [^[:space:]]+ --prompt-worker-password)?$'

echo "=== test_menu7_bringup_semantic_validation ==="

# --- A. FULL: >2 textual mentions, exactly 1 executable, validation PASS ---
FULL="$TMP/full.txt"
gui_build_client_commands "$MIRROR_HTTP_URL" single "" >"$FULL"
TEXTUAL_FULL="$(grep -cE 'bringup_py3_dp_after_os_upgrade\.sh' "$FULL" || true)"
EXEC_FULL="$(grep -cE "$BRINGUP_EXEC_RE" "$FULL" || true)"
[[ "$TEXTUAL_FULL" -gt 2 ]] && pass "A FULL textual bringup mentions >2 ($TEXTUAL_FULL)" \
  || fail "A FULL textual bringup mentions not >2 ($TEXTUAL_FULL)"
[[ "$EXEC_FULL" -eq 1 ]] && pass "A FULL executable bringup count=1" \
  || fail "A FULL executable bringup count=$EXEC_FULL"
mm_wf_validate_command_file_content "$FULL" FULL >"$TMP/full-val.out"
grep -q 'COMMAND_FILE_BUILD=PASS' "$TMP/full-val.out" && pass "A FULL COMMAND_FILE_BUILD=PASS" \
  || fail "A FULL COMMAND_FILE_BUILD not PASS"
grep -q 'COMMAND_FILE_BRINGUP_EXECUTABLE_COUNT=1' "$TMP/full-val.out" \
  && pass "A FULL BRINGUP_EXECUTABLE_COUNT=1" || fail "A FULL BRINGUP_EXECUTABLE_COUNT missing"

# --- B. PHASE2_ONLY: same semantic behavior ---
PREPARATION_MODE=PHASE2_ONLY
P2="$TMP/phase2-only.txt"
gui_build_client_commands "$MIRROR_HTTP_URL" single "" >"$P2"
TEXTUAL_P2="$(grep -cE 'bringup_py3_dp_after_os_upgrade\.sh' "$P2" || true)"
EXEC_P2="$(grep -cE "$BRINGUP_EXEC_RE" "$P2" || true)"
[[ "$TEXTUAL_P2" -gt 2 ]] && pass "B PHASE2_ONLY textual mentions >2 ($TEXTUAL_P2)" \
  || fail "B PHASE2_ONLY textual mentions not >2 ($TEXTUAL_P2)"
[[ "$EXEC_P2" -eq 1 ]] && pass "B PHASE2_ONLY executable count=1" \
  || fail "B PHASE2_ONLY executable count=$EXEC_P2"
mm_wf_validate_command_file_content "$P2" PHASE2_ONLY >"$TMP/p2-val.out"
grep -q 'COMMAND_FILE_BUILD=PASS' "$TMP/p2-val.out" && pass "B PHASE2_ONLY COMMAND_FILE_BUILD=PASS" \
  || fail "B PHASE2_ONLY COMMAND_FILE_BUILD not PASS"
grep -q 'COMMAND_FILE_BRINGUP_EXECUTABLE_COUNT=1' "$TMP/p2-val.out" \
  && pass "B PHASE2_ONLY BRINGUP_EXECUTABLE_COUNT=1" || fail "B PHASE2_ONLY count missing"

# --- C. Duplicate executable bringup must FAIL ---
PREPARATION_MODE=FULL
DUP="$TMP/full-dup.txt"
cp "$FULL" "$DUP"
printf '%s\n' \
  'sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --version 6.6.0 --skip-download' \
  >>"$DUP"
set +e
mm_wf_validate_command_file_content "$DUP" FULL >"$TMP/dup-val.out"
DUP_RC=$?
set -e
[[ "$DUP_RC" -ne 0 ]] && pass "C duplicate executable returns failure" \
  || fail "C duplicate executable unexpectedly passed"
grep -q 'COMMAND_FILE_BUILD=FAIL' "$TMP/dup-val.out" && pass "C BUILD=FAIL" \
  || fail "C missing BUILD=FAIL"
grep -q 'COMMAND_FILE_BRINGUP_EXECUTABLE_VALIDATION=FAIL' "$TMP/dup-val.out" \
  && pass "C BRINGUP_EXECUTABLE_VALIDATION=FAIL" \
  || fail "C missing BRINGUP_EXECUTABLE_VALIDATION=FAIL"
grep -q 'COMMAND_FILE_BRINGUP_EXECUTABLE_COUNT=2' "$TMP/dup-val.out" \
  && pass "C executable count=2 evidence" || fail "C count=2 evidence missing"

# --- D. Prose/reference-only mentions must NOT change semantic count ---
PROSE="$TMP/full-prose.txt"
cp "$FULL" "$PROSE"
cat >>"$PROSE" <<'EOF'
# Documentation reference only:
#   see also bringup_py3_dp_after_os_upgrade.sh checksum sidecar
#   operators may later run indented:
     sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --validate-cluster
EOF
TEXTUAL_PROSE="$(grep -cE 'bringup_py3_dp_after_os_upgrade\.sh' "$PROSE" || true)"
EXEC_PROSE="$(grep -cE "$BRINGUP_EXEC_RE" "$PROSE" || true)"
[[ "$TEXTUAL_PROSE" -gt "$TEXTUAL_FULL" ]] && pass "D prose increased textual count ($TEXTUAL_PROSE)" \
  || fail "D prose did not increase textual count"
[[ "$EXEC_PROSE" -eq 1 ]] && pass "D prose did not change executable count" \
  || fail "D executable count changed to $EXEC_PROSE"
mm_wf_validate_command_file_content "$PROSE" FULL >"$TMP/prose-val.out"
grep -q 'COMMAND_FILE_BUILD=PASS' "$TMP/prose-val.out" && pass "D prose-only still PASS" \
  || fail "D prose-only unexpectedly FAIL"
grep -q 'COMMAND_FILE_BRINGUP_EXECUTABLE_COUNT=1' "$TMP/prose-val.out" \
  && pass "D semantic count remains 1" || fail "D semantic count changed"

# --- E. Missing executable bringup must FAIL ---
MISSING="$TMP/full-missing.txt"
grep -vE "$BRINGUP_EXEC_RE" "$FULL" >"$MISSING"
set +e
mm_wf_validate_command_file_content "$MISSING" FULL >"$TMP/missing-val.out"
MISS_RC=$?
set -e
[[ "$MISS_RC" -ne 0 ]] && pass "E missing executable returns failure" \
  || fail "E missing executable unexpectedly passed"
grep -q 'COMMAND_FILE_BRINGUP_EXECUTABLE_COUNT=0' "$TMP/missing-val.out" \
  && pass "E executable count=0" || fail "E count=0 evidence missing"
grep -q 'COMMAND_FILE_BRINGUP_EXECUTABLE_VALIDATION=FAIL' "$TMP/missing-val.out" \
  && pass "E BRINGUP_EXECUTABLE_VALIDATION=FAIL" \
  || fail "E missing validation fail key"

# --- F. Existing FULL wrapper contracts ---
grep -q 'COMMAND_FILE_OS_HOP_COUNT=4' "$TMP/full-val.out" && pass "F OS_HOP_COUNT=4" \
  || fail "F OS_HOP_COUNT"
grep -q 'COMMAND_FILE_OS_HOP_LAUNCHER_COUNT=4' "$TMP/full-val.out" && pass "F OS_HOP_LAUNCHER_COUNT=4" \
  || fail "F OS_HOP_LAUNCHER_COUNT"
grep -q 'COMMAND_FILE_OS_HOP_LEGACY_BLOCK_COUNT=0' "$TMP/full-val.out" \
  && pass "F OS_HOP_LEGACY_BLOCK_COUNT=0" || fail "F legacy hop blocks"
grep -q 'COMMAND_FILE_LAUNCHER_SHA_PINNING=PASS' "$TMP/full-val.out" \
  && pass "F launcher SHA pinning PASS" || fail "F SHA pinning"
grep -q 'DP_OS_HOP_COMMAND_VERSION=WRAPPER_V1' "$TMP/full-val.out" \
  && pass "F WRAPPER_V1" || fail "F WRAPPER_V1"

# Failure evidence must include FAILURE_REASON
EVID="$TMP/evid.txt"
printf '%s\n' 'COMMAND_FILE_BUILD=FAIL' 'COMMAND_FILE_FAILURE_REASON=BRINGUP_EXECUTABLE_COUNT' \
  'COMMAND_FILE_BRINGUP_EXECUTABLE_COUNT=0' \
  'COMMAND_FILE_PHASE2_WRAPPER_VALIDATION=FAIL' >"$EVID"
LOGGED="$TMP/logged.txt"
mm_error() { printf '%s\n' "$*" >>"$LOGGED"; }
mm_wf_log_command_file_validation_evidence "$EVID"
grep -q 'MENU7_COMMAND_FILE_VALIDATION COMMAND_FILE_FAILURE_REASON=BRINGUP_EXECUTABLE_COUNT' "$LOGGED" \
  && pass "logger emits FAILURE_REASON" || fail "logger missing FAILURE_REASON"
grep -q 'MENU7_COMMAND_FILE_VALIDATION COMMAND_FILE_BRINGUP_EXECUTABLE_COUNT=0' "$LOGGED" \
  && pass "logger emits bringup executable evidence" \
  || fail "logger missing bringup evidence"
grep -q 'MENU7_COMMAND_FILE_VALIDATION COMMAND_FILE_PHASE2_WRAPPER_VALIDATION=FAIL' "$LOGGED" \
  && pass "logger emits phase2 wrapper evidence" \
  || fail "logger missing phase2 evidence"
# Ensure we never log password-bearing lines from a command body.
SECRET_EVID="$TMP/secret-evid.txt"
printf '%s\n' 'COMMAND_FILE_BUILD=FAIL' \
  'sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --worker-ips 1.2.3.4 --prompt-worker-password' \
  >"$SECRET_EVID"
: >"$LOGGED"
mm_wf_log_command_file_validation_evidence "$SECRET_EVID"
if grep -qiE 'password|worker-ips|sudo bash' "$LOGGED"; then
  fail "logger leaked command/secret-bearing content"
else
  pass "logger skips non-evidence lines"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_menu7_bringup_semantic_validation PASS ==="
  exit 0
fi
echo "=== test_menu7_bringup_semantic_validation FAIL ==="
exit 1
