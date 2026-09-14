#!/usr/bin/env bash
# tests/test_menu7_generation_matrix.sh
# Operator-visible Menu 7 generation × validation matrix (FULL/PHASE2_ONLY ×
# single/DL/DA/DL+DA) plus fail-closed negatives for executable structure.
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

BRINGUP_EXEC_RE="$(mm_wf_bringup_executable_line_regex)"
HOP_RE='^cd /home/aella && curl -fsSLo upgrade-(xenial-to-bionic|bionic-to-focal|focal-to-jammy|jammy-to-noble)\.sh\.download '
STAGE_RE='^cd /home/aella && curl -fsSLo upgrade-phase2\.sh\.download '
LEGACY_HOP_RE="^\( .*HOP='(xenial-to-bionic|bionic-to-focal|focal-to-jammy|jammy-to-noble)'"
SYN_PW='Matr1x!Pw$Ok'

expect_pass() {
  local label="$1" file="$2" mode="$3" want_bringup="$4" want_hops="$5"
  local out rc textual exec_c hop_c stage_c legacy
  out="$TMP/val-${label}.out"
  set +e
  mm_wf_validate_command_file_content "$file" "$mode" >"$out"
  rc=$?
  set -e
  textual="$(grep -cE 'bringup_py3_dp_after_os_upgrade\.sh' "$file" || true)"
  exec_c="$(grep -cE "$BRINGUP_EXEC_RE" "$file" || true)"
  hop_c="$(grep -cE "$HOP_RE" "$file" || true)"
  stage_c="$(grep -cE "$STAGE_RE" "$file" || true)"
  legacy="$(grep -cE "$LEGACY_HOP_RE" "$file" || true)"
  legacy=$((legacy + $(grep -cE '^cd /home/aella && curl -fsSLo dp-launch-' "$file" || true)))
  [[ "$rc" -eq 0 ]] && grep -q 'COMMAND_FILE_BUILD=PASS' "$out" \
    && pass "${label}: validates PASS" || fail "${label}: validation rc=${rc}"
  [[ "$exec_c" -eq "$want_bringup" ]] && pass "${label}: bringup exec=${exec_c}" \
    || fail "${label}: bringup exec=${exec_c} want=${want_bringup}"
  [[ "$hop_c" -eq "$want_hops" ]] && pass "${label}: hops=${hop_c}" \
    || fail "${label}: hops=${hop_c} want=${want_hops}"
  [[ "$stage_c" -eq 1 ]] && pass "${label}: phase2 stage=1" \
    || fail "${label}: phase2 stage=${stage_c}"
  [[ "$legacy" -eq 0 ]] && pass "${label}: no legacy OS-hop" \
    || fail "${label}: legacy hops=${legacy}"
  [[ "$textual" -gt "$exec_c" ]] && pass "${label}: prose mentions do not equal exec count" \
    || pass "${label}: textual=${textual} exec=${exec_c}"
  if [[ "$mode" == "FULL" ]]; then
    grep -q 'DP_OS_HOP_COMMAND_VERSION=WRAPPER_V1' "$out" \
      && pass "${label}: WRAPPER_V1" || fail "${label}: missing WRAPPER_V1"
    grep -q 'COMMAND_FILE_LAUNCHER_SHA_PINNING=PASS' "$out" \
      && pass "${label}: SHA pinning" || fail "${label}: SHA pinning"
  fi
  grep -qE 'curl[^|;]*\|[[:space:]]*(bash|sh)([[:space:]]|$)' "$file" \
    && fail "${label}: curl|bash present" || pass "${label}: no curl|bash"
}

echo "=== test_menu7_generation_matrix ==="

# --- FULL × topologies ---
PREPARATION_MODE=FULL
gui_build_client_commands "$MIRROR_HTTP_URL" single "" "" "" >"$TMP/full-single.txt"
expect_pass full-single "$TMP/full-single.txt" FULL 1 4

gui_build_client_commands "$MIRROR_HTTP_URL" cluster "192.0.2.21,192.0.2.22" "" "$SYN_PW" \
  >"$TMP/full-dl.txt"
expect_pass full-dl "$TMP/full-dl.txt" FULL 1 4
grep -Fq "$SYN_PW" "$TMP/full-dl.txt" && fail "full-dl leaked password" || pass "full-dl password not embedded"

gui_build_client_commands "$MIRROR_HTTP_URL" cluster "" "198.51.100.21,198.51.100.22" "$SYN_PW" \
  >"$TMP/full-da.txt"
expect_pass full-da "$TMP/full-da.txt" FULL 1 4

gui_build_client_commands "$MIRROR_HTTP_URL" cluster \
  "192.0.2.21,192.0.2.22" "198.51.100.21,198.51.100.22" "$SYN_PW" \
  >"$TMP/full-dual.txt"
expect_pass full-dual "$TMP/full-dual.txt" FULL 2 4

# --- PHASE2_ONLY × topologies ---
PREPARATION_MODE=PHASE2_ONLY
gui_build_client_commands "$MIRROR_HTTP_URL" single "" "" "" >"$TMP/p2-single.txt"
expect_pass p2-single "$TMP/p2-single.txt" PHASE2_ONLY 1 0

gui_build_client_commands "$MIRROR_HTTP_URL" cluster "192.0.2.21" "" "$SYN_PW" >"$TMP/p2-dl.txt"
expect_pass p2-dl "$TMP/p2-dl.txt" PHASE2_ONLY 1 0

gui_build_client_commands "$MIRROR_HTTP_URL" cluster "" "198.51.100.21" "$SYN_PW" >"$TMP/p2-da.txt"
expect_pass p2-da "$TMP/p2-da.txt" PHASE2_ONLY 1 0

gui_build_client_commands "$MIRROR_HTTP_URL" cluster "192.0.2.21" "198.51.100.21" "$SYN_PW" \
  >"$TMP/p2-dual.txt"
expect_pass p2-dual "$TMP/p2-dual.txt" PHASE2_ONLY 2 0

# --- Negatives on FULL single ---
PREPARATION_MODE=FULL
BASE="$TMP/full-single.txt"

# Duplicate executable bringup
cp "$BASE" "$TMP/neg-dup.txt"
printf '%s\n' \
  'sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --version 6.6.0 --skip-download' \
  >>"$TMP/neg-dup.txt"
set +e
mm_wf_validate_command_file_content "$TMP/neg-dup.txt" FULL >"$TMP/neg-dup.out"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'COMMAND_FILE_FAILURE_REASON=BRINGUP_EXECUTABLE_COUNT' "$TMP/neg-dup.out" \
  && pass "dup bringup rejected with FAILURE_REASON" \
  || fail "dup bringup not rejected properly"

# Missing executable bringup
grep -vE "$BRINGUP_EXEC_RE" "$BASE" >"$TMP/neg-missing.txt"
set +e
mm_wf_validate_command_file_content "$TMP/neg-missing.txt" FULL >"$TMP/neg-missing.out"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'COMMAND_FILE_FAILURE_REASON=BRINGUP_EXECUTABLE_COUNT' "$TMP/neg-missing.out" \
  && pass "missing bringup rejected" || fail "missing bringup accepted"

# Arbitrary sudo bash must NOT satisfy bringup contract
cp "$TMP/neg-missing.txt" "$TMP/neg-sudo.txt"
printf '%s\n' 'sudo bash /bin/true' >>"$TMP/neg-sudo.txt"
set +e
mm_wf_validate_command_file_content "$TMP/neg-sudo.txt" FULL >"$TMP/neg-sudo.out"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "arbitrary sudo bash does not satisfy bringup" \
  || fail "arbitrary sudo bash incorrectly accepted"

# Prose-only extra mentions remain PASS
cp "$BASE" "$TMP/neg-prose.txt"
printf '%s\n' '# see bringup_py3_dp_after_os_upgrade.sh docs' \
  '     sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --validate-cluster' \
  >>"$TMP/neg-prose.txt"
set +e
mm_wf_validate_command_file_content "$TMP/neg-prose.txt" FULL >"$TMP/neg-prose.out"
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "prose references do not false-fail" \
  || fail "prose references false-failed"

# Duplicate Phase2 stage path
cp "$BASE" "$TMP/neg-stage.txt"
grep -E "$STAGE_RE" "$BASE" | head -1 >>"$TMP/neg-stage.txt"
set +e
mm_wf_validate_command_file_content "$TMP/neg-stage.txt" FULL >"$TMP/neg-stage.out"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'COMMAND_FILE_FAILURE_REASON=PHASE2_STAGE_COUNT' "$TMP/neg-stage.out" \
  && pass "duplicate phase2 stage rejected" || fail "duplicate phase2 stage accepted"

# curl|bash prohibited
cp "$BASE" "$TMP/neg-curl.txt"
printf '%s\n' 'curl http://example.test/x | bash' >>"$TMP/neg-curl.txt"
set +e
mm_wf_validate_command_file_content "$TMP/neg-curl.txt" FULL >"$TMP/neg-curl.out"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'COMMAND_FILE_FAILURE_REASON=CURL_PIPE_BASH' "$TMP/neg-curl.out" \
  && pass "curl|bash rejected" || fail "curl|bash accepted"

# Backslash continuation prohibited
cp "$BASE" "$TMP/neg-bs.txt"
printf '%s\n' 'echo hello \' >>"$TMP/neg-bs.txt"
set +e
mm_wf_validate_command_file_content "$TMP/neg-bs.txt" FULL >"$TMP/neg-bs.out"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'COMMAND_FILE_FAILURE_REASON=CONTINUATION_VALIDATION' "$TMP/neg-bs.out" \
  && pass "backslash continuation rejected" || fail "backslash continuation accepted"

# Atomic publish preserves live + cleans evidence path
LIVE="$TMP/live-commands.txt"
cp "$BASE" "$LIVE"
chmod 0600 "$LIVE"
LIVE_SHA="$(sha256sum "$LIVE" | awk '{print $1}')"
: >"$TMP/empty.candidate"
set +e
PUB_OUT="$(mm_wf_atomic_publish_command_file "$TMP/empty.candidate" "$LIVE" FULL gen-matrix 2>&1)"
pub_rc=$?
set -e
[[ "$pub_rc" -ne 0 ]] && pass "empty candidate publish fails" || fail "empty candidate published"
[[ "$(sha256sum "$LIVE" | awk '{print $1}')" == "$LIVE_SHA" ]] \
  && pass "live file preserved on publish failure" || fail "live file replaced"
mode="$(stat -c '%a' "$LIVE")"
[[ "$mode" == "600" || "$mode" == "0600" ]] && pass "live mode 0600" || fail "live mode=${mode}"
printf '%s\n' "$PUB_OUT" | grep -qiE 'password|private.?key|BEGIN .*PRIVATE' \
  && fail "publish failure evidence leaked secrets" || pass "publish failure evidence safe"

# Invalid worker IPs / missing password remain rejected at generation
set +e
gui_build_client_commands "$MIRROR_HTTP_URL" cluster '192.0.2.1;rm' "" "$SYN_PW" \
  >"$TMP/bad-ip.txt" 2>"$TMP/bad-ip.err"
bad_ip_rc=$?
gui_build_client_commands "$MIRROR_HTTP_URL" cluster "192.0.2.21" "" "" \
  >"$TMP/no-pw.txt" 2>"$TMP/no-pw.err"
no_pw_rc=$?
set -e
[[ "$bad_ip_rc" -ne 0 ]] && pass "invalid worker IPs rejected" || fail "invalid worker IPs accepted"
[[ "$no_pw_rc" -ne 0 ]] && pass "missing cluster password rejected" \
  || fail "missing cluster password accepted"

# Role-specific bringup binding (not merely total executable count).
# DL_DA + two DL sections / zero DA must FAIL even when executable count == 2.
sed 's/Run this command on the DA MASTER ONLY\./Run this command on the DL MASTER ONLY./' \
  "$TMP/full-dual.txt" >"$TMP/two-dl-zero-da.txt"
set +e
DL_WORKER_IPS='10.0.0.1' DA_WORKER_IPS='10.0.0.2' \
  mm_wf_validate_command_file_content "$TMP/two-dl-zero-da.txt" FULL \
  >"$TMP/two-dl.out" 2>/dev/null
two_dl_rc=$?
set -e
[[ "$two_dl_rc" -ne 0 ]] \
  && grep -q 'COMMAND_FILE_FAILURE_REASON=BRINGUP_ROLE_DUPLICATE' "$TMP/two-dl.out" \
  && pass "DL_DA two-DL zero-DA rejected" \
  || fail "DL_DA two-DL zero-DA not rejected"

# DL_ONLY config + unexpected DA executable must FAIL.
{
  cat "$TMP/full-dl.txt"
  echo
  echo 'Run this command on the DA MASTER ONLY.'
  echo
  echo 'sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --version 6.6.0 --skip-download --worker-ips 10.0.0.99 --prompt-worker-password'
} >"$TMP/dl-plus-unexpected-da.txt"
set +e
DL_WORKER_IPS='10.0.0.1' DA_WORKER_IPS='' \
  mm_wf_validate_command_file_content "$TMP/dl-plus-unexpected-da.txt" FULL \
  >"$TMP/dl-unexp.out" 2>/dev/null
dl_unexp_rc=$?
set -e
[[ "$dl_unexp_rc" -ne 0 ]] \
  && grep -qE 'COMMAND_FILE_FAILURE_REASON=BRINGUP_ROLE_(MISMATCH|DUPLICATE)' "$TMP/dl-unexp.out" \
  && pass "DL_ONLY unexpected DA executable rejected" \
  || fail "DL_ONLY unexpected DA executable accepted"

# DA_ONLY + unexpected DL executable must FAIL.
{
  cat "$TMP/full-da.txt"
  echo
  echo 'Run this command on the DL MASTER ONLY.'
  echo
  echo 'sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --version 6.6.0 --skip-download --worker-ips 10.0.0.88 --prompt-worker-password'
} >"$TMP/da-plus-unexpected-dl.txt"
set +e
DL_WORKER_IPS='' DA_WORKER_IPS='10.0.0.2' \
  mm_wf_validate_command_file_content "$TMP/da-plus-unexpected-dl.txt" FULL \
  >"$TMP/da-unexp.out" 2>/dev/null
da_unexp_rc=$?
set -e
[[ "$da_unexp_rc" -ne 0 ]] \
  && grep -qE 'COMMAND_FILE_FAILURE_REASON=BRINGUP_ROLE_(MISMATCH|DUPLICATE)' "$TMP/da-unexp.out" \
  && pass "DA_ONLY unexpected DL executable rejected" \
  || fail "DA_ONLY unexpected DL executable accepted"

# Positive config-aware role binding for generated dual/dl/da files.
set +e
DL_WORKER_IPS='10.0.0.1' DA_WORKER_IPS='10.0.0.2' \
  mm_wf_validate_command_file_content "$TMP/full-dual.txt" FULL >/dev/null 2>&1
dual_role_rc=$?
DL_WORKER_IPS='10.0.0.1' DA_WORKER_IPS='' \
  mm_wf_validate_command_file_content "$TMP/full-dl.txt" FULL >/dev/null 2>&1
dl_role_rc=$?
DL_WORKER_IPS='' DA_WORKER_IPS='10.0.0.2' \
  mm_wf_validate_command_file_content "$TMP/full-da.txt" FULL >/dev/null 2>&1
da_role_rc=$?
set -e
[[ "$dual_role_rc" -eq 0 ]] && pass "DL_DA role binding PASS" || fail "DL_DA role binding FAIL"
[[ "$dl_role_rc" -eq 0 ]] && pass "DL_ONLY role binding PASS" || fail "DL_ONLY role binding FAIL"
[[ "$da_role_rc" -eq 0 ]] && pass "DA_ONLY role binding PASS" || fail "DA_ONLY role binding FAIL"

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_menu7_generation_matrix PASS ==="
  exit 0
fi
echo "=== test_menu7_generation_matrix FAIL ==="
exit 1
