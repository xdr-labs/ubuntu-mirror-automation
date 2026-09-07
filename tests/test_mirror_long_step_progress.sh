#!/usr/bin/env bash
# Long-step heartbeat/progress + redundant SHA256 full-read regression.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
ACPS="${ROOT}/scripts/lib/acps_acquire.sh"
DP2_COMMON="${ROOT}/scripts/lib/dp-phase2-common.sh"
PATCHED_BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

count_exact() {
  local pat="$1" file="$2" n
  n="$(grep -cE "$pat" "$file" 2>/dev/null || true)"
  printf '%s\n' "${n:-0}"
}

adjacent_dup_count() {
  local file="$1"
  awk 'NR>1 && $0==prev { c++ } { prev=$0 } END { print c+0 }' "$file"
}

max_silent_gap() {
  # Approximate gap from structured elapsed= heartbeats / timestamps in log.
  # For synthetic runs we assert heartbeats exist; gap check uses elapsed samples.
  local file="$1"
  local max=0 prev=0 e
  while IFS= read -r e; do
    [[ "$e" =~ ^[0-9]+$ ]] || continue
    if [[ "$prev" -gt 0 ]]; then
      local d=$((e - prev))
      [[ "$d" -gt "$max" ]] && max=$d
    fi
    prev=$e
  done < <(grep -oE 'elapsed=[0-9]+s' "$file" | grep -oE '[0-9]+' || true)
  printf '%s\n' "$max"
}

# --- Structural ---
grep -q 'mm_bg_with_heartbeat' "$COMMON" || fail "mm_bg_with_heartbeat missing"
grep -q 'mm_run_with_file_progress' "$COMMON" || fail "mm_run_with_file_progress missing"
grep -q 'mm_acps_verify_payload_checksums' "$COMMON" || fail "mm_acps_verify_payload_checksums missing"
grep -q 'ACPS_CHECKSUM_VERIFY' "$COMMON" || fail "ACPS_CHECKSUM_VERIFY events missing"
grep -q 'PHASE2_FINAL_SHA256_VERIFY' "$ENGINE" || fail "final SHA256 verify events missing"
grep -q 'ACPS_CACHE_CLEANUP_START' "$ACPS" || fail "cache cleanup START missing"
grep -q 'DP_PHASE2_ATOMIC_PUBLISH_START' "$ENGINE" || fail "atomic publish START missing"
grep -q 'engine_assert_work_ready_for_bundle' "$ENGINE" || fail "work hardlink trust helper missing"
grep -q 'Skipping redundant SHA256' "$ENGINE" || fail "redundant SHA256 skip message missing"
# Must not use inverted rc capture.
if grep -n 'if ! mm_bg_with_heartbeat\|if ! mm_run_with_heartbeat\|if ! mm_run_with_file_progress' "$COMMON" \
  | grep -q 'rc=\$?'; then
  fail "inverted rc capture reintroduced in helpers"
fi
pass "structural long-step helpers"

# --- Throttled synthetic fixture through production place path ---
# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "$COMMON"
# shellcheck source=../scripts/lib/dp-phase2-common.sh
source "$DP2_COMMON"
# shellcheck source=../scripts/lib/acps_acquire.sh
source "$ACPS"
# shellcheck source=../scripts/lib/mirror_install_engine.sh
source "$ENGINE"

export MM_SKIP_ROOT_CHECK=1
export MM_PROJECT_ROOT="$ROOT"
export MM_MIRROR_ROOT="${TMP}/mirror"
export MM_CACHE_ROOT="${TMP}/mirror/.install-cache"
export MM_SELECTIVE_ROOT="${TMP}/mirror/selective"
export MM_DP_PHASE2_ROOT="${TMP}/mirror/dp-phase2"
export MM_STATE_ROOT="${TMP}/state-root"
export MM_STATE_DIR="${TMP}/state"
export MM_CONFIG_DIR="${TMP}/config"
export MM_STATUS_FILE="${TMP}/config/status"
export MM_LOG_FILE="${TMP}/long-step.log"
export DP_PHASE2_LOG_FILE="${TMP}/dp-phase2-sync.log"
export MM_DRY_RUN=0
export MM_KEEP_PHASE2_SOURCES=1
export MM_LONG_STEP_HEARTBEAT_SEC=1
export TARGET_DP_VERSION=6.6.0
mkdir -p "$MM_CACHE_ROOT" "$MM_SELECTIVE_ROOT" "$MM_DP_PHASE2_ROOT" "$MM_STATE_DIR" "$MM_CONFIG_DIR"
: >"$MM_LOG_FILE"
: >"$MM_STATUS_FILE"
: >"${MM_STATE_DIR}/state.env"

dp2_set_version 6.6.0
CACHE="$(acps_cache_dir 6.6.0)"
mkdir -p "$CACHE"

# ~8MiB images tar so SHA256/tar take more than 2s with heartbeat interval=1.
dd if=/dev/urandom of="${CACHE}/images-6.6.0.tar" bs=1M count=8 status=none
sha256sum "${CACHE}/images-6.6.0.tar" | awk '{print $1}' >"${CACHE}/images-6.6.0.tar.sha256"
printf 'common\n' >"${CACHE}/aelladeb_py3_common.tar.gz"
sha1sum "${CACHE}/aelladeb_py3_common.tar.gz" | awk '{print $1}' >"${CACHE}/aelladeb_py3_common.tar.gz.sha1"
printf 'uvp\n' >"${CACHE}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb"
sha1sum "${CACHE}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}' \
  >"${CACHE}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
seq 1 156 >"${CACHE}/images-6.6.0.list"
printf 'SYNTHETIC_UPSTREAM\n' >"${CACHE}/bringup_py3_dp_after_os_upgrade.sh"
sha1sum "${CACHE}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
  >"${CACHE}/bringup_py3_dp_after_os_upgrade.sh.sha1"

# Slow down sha256sum for reliable heartbeats without huge files.
SHA_WRAP="${TMP}/bin"
mkdir -p "$SHA_WRAP"
cat >"${SHA_WRAP}/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Count invocations for full-read regression.
echo "$# $*" >>"${SHA256_CALL_LOG:-/dev/null}"
# Throttle large inputs so heartbeat interval=1 fires at least twice.
if [[ -f "${1:-}" ]]; then
  sz="$(stat -c%s "$1" 2>/dev/null || echo 0)"
  if [[ "$sz" -ge 1048576 ]]; then
    sleep 2.5
  fi
fi
exec /usr/bin/sha256sum "$@"
EOF
chmod +x "${SHA_WRAP}/sha256sum"
export PATH="${SHA_WRAP}:${PATH}"
export SHA256_CALL_LOG="${TMP}/sha256.calls"
: >"$SHA256_CALL_LOG"

# Seed existing final for failure-preserve checks later.
EXIST_DIR="${MM_DP_PHASE2_ROOT}/6.6.0"
mkdir -p "$EXIST_DIR"
printf 'OLD_FINAL_BUNDLE\n' >"${EXIST_DIR}/dp_bundle_6.6.0-current.tar"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  dp_bundle_6.6.0-current.tar\n' \
  >"${EXIST_DIR}/dp_bundle_6.6.0-current.tar.sha256"
printf 'TARGET_DP_VERSION=6.6.0\n' >"${EXIST_DIR}/release.env"
OLD_FP="$(/usr/bin/sha256sum "${EXIST_DIR}/dp_bundle_6.6.0-current.tar" | awk '{print $1}')"

VERIFY_LOG="${TMP}/acps-verify.log"
: >"$VERIFY_LOG"
# Capture stdout/stderr only — do not also append MM_LOG_FILE (would duplicate).
MM_LOG_FILE=""
set +e
mm_acps_verify_payload_checksums "$CACHE" >"$VERIFY_LOG" 2>&1
ACPS_V_RC=$?
set -e
[[ "$ACPS_V_RC" -eq 0 ]] || fail "mm_acps_verify_payload_checksums rc=${ACPS_V_RC}"
acps_write_verified_marker "$CACHE" || fail "acps_write_verified_marker"

ACPS_START="$(count_exact 'ACPS_CHECKSUM_VERIFY_START.*images-6\.6\.0\.tar.*algorithm=SHA256' "$VERIFY_LOG")"
ACPS_HB="$(count_exact 'ACPS_CHECKSUM_VERIFY_HEARTBEAT.*images-6\.6\.0\.tar.*algorithm=SHA256' "$VERIFY_LOG")"
ACPS_DONE="$(count_exact 'ACPS_CHECKSUM_VERIFY_COMPLETE.*images-6\.6\.0\.tar.*algorithm=SHA256.*result=PASS' "$VERIFY_LOG")"
[[ "$ACPS_START" -eq 1 ]] || fail "ACPS SHA256 START count=${ACPS_START}"
[[ "$ACPS_HB" -ge 2 ]] || fail "ACPS SHA256 HEARTBEAT count=${ACPS_HB}"
[[ "$ACPS_DONE" -eq 1 ]] || fail "ACPS SHA256 COMPLETE count=${ACPS_DONE}"
grep -q 'algorithm=SHA1' "$VERIFY_LOG" || fail "SHA1 labeled events missing"
if grep -E 'images-6\.6\.0\.tar.*algorithm=SHA1|algorithm=SHA1.*images-6\.6\.0\.tar' "$VERIFY_LOG"; then
  fail "images tar incorrectly labeled SHA1"
fi
pass "ACPS checksum START/HEARTBEAT/COMPLETE + algorithm labels"

# Count source images full reads so far (verify path only; ignore sidecar hashes).
SOURCE_READS_AFTER_ACPS="$(grep -cE '(^|[[:space:]/])images-6\.6\.0\.tar($|[[:space:]])' "$SHA256_CALL_LOG" || true)"
[[ "$SOURCE_READS_AFTER_ACPS" -eq 1 ]] || fail "expected 1 source images sha256 after ACPS verify got=${SOURCE_READS_AFTER_ACPS}"

WORK="${MM_CACHE_ROOT}/acps-work/6.6.0/long-run"
engine_stage_acps_work_from_cache "$CACHE" "$WORK"
cp -f "$PATCHED_BRINGUP" "${WORK}/bringup_py3_dp_after_os_upgrade.sh"
sha1sum "${WORK}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
  >"${WORK}/bringup_py3_dp_after_os_upgrade.sh.sha1"
BRINGUP_PATCHED_SHA1="$(sha1sum "${WORK}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"

READY_LOG="${TMP}/work-ready.log"
MM_LOG_FILE=""
: >"$READY_LOG"
engine_assert_work_ready_for_bundle "$CACHE" "$WORK" 6.6.0 >"$READY_LOG" 2>&1 || fail "work ready failed"
grep -q 'ACPS_WORK_IMAGES_HARDLINK_TRUSTED=YES' "$READY_LOG" || fail "hardlink trust missing"
# Wrapper logs argv; hardlink path should not appear as a new sha256 target after trust.
REDUNDANT_WORK="$(grep 'images-6.6.0.tar' "$SHA256_CALL_LOG" | grep -c 'acps-work' || true)"
[[ "$REDUNDANT_WORK" -eq 0 ]] || fail "redundant work images sha256 reads=${REDUNDANT_WORK}"
pass "hardlink trust skips redundant work images SHA256"

PLACE_LOG="${TMP}/place.log"
MM_LOG_FILE=""
: >"$PLACE_LOG"
# Slow tar slightly via wrapper for progress samples.
cat >"${SHA_WRAP}/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# When creating (-cf), sleep briefly so progress monitor can sample.
if [[ "${1:-}" == "-cf" ]]; then
  (
    sleep 0.3
    exec /usr/bin/tar "$@"
  ) &
  pid=$!
  # Keep writing delay by syncing after — rely on sha256 throttle mainly.
  wait "$pid"
  rc=$?
  sleep 2.2
  exit "$rc"
fi
exec /usr/bin/tar "$@"
EOF
chmod +x "${SHA_WRAP}/tar"

set +e
# mm_die/dp2_die call exit — isolate in a subshell.
( engine_place_dp_phase2_final "$WORK" 6.6.0 ) >"$PLACE_LOG" 2>&1
PLACE_RC=$?
set -e
[[ "$PLACE_RC" -eq 0 ]] || { tail -n 80 "$PLACE_LOG"; fail "engine_place_dp_phase2_final rc=${PLACE_RC}"; }

COMBINED="${TMP}/combined.log"
cat "$VERIFY_LOG" "$READY_LOG" "$PLACE_LOG" >"$COMBINED"

B_START="$(count_exact 'PHASE2_BUNDLE_CREATE_START' "$PLACE_LOG")"
B_PROG="$(count_exact 'PHASE2_BUNDLE_CREATE_PROGRESS' "$PLACE_LOG")"
B_DONE="$(count_exact 'PHASE2_BUNDLE_CREATE_COMPLETE.*result=PASS' "$PLACE_LOG")"
[[ "$B_START" -eq 1 ]] || fail "bundle CREATE START count=${B_START}"
[[ "$B_PROG" -ge 1 ]] || fail "bundle CREATE PROGRESS count=${B_PROG}"
[[ "$B_DONE" -eq 1 ]] || fail "bundle CREATE COMPLETE count=${B_DONE}"
grep -q 'PROGRESS PHASE2 BUNDLE:' "$PLACE_LOG" || fail "human bundle progress missing"
pass "bundle create START/PROGRESS/COMPLETE"

S_START="$(count_exact 'PHASE2_BUNDLE_SHA256_CREATE_START' "$PLACE_LOG")"
S_HB="$(count_exact 'PHASE2_BUNDLE_SHA256_CREATE_HEARTBEAT' "$PLACE_LOG")"
S_DONE="$(count_exact 'PHASE2_BUNDLE_SHA256_CREATE_COMPLETE.*result=PASS' "$PLACE_LOG")"
[[ "$S_START" -eq 1 ]] || fail "bundle SHA256 CREATE START=${S_START}"
[[ "$S_HB" -ge 2 ]] || fail "bundle SHA256 CREATE HEARTBEAT=${S_HB}"
[[ "$S_DONE" -eq 1 ]] || fail "bundle SHA256 CREATE COMPLETE=${S_DONE}"
pass "bundle SHA256 create START/HEARTBEAT/COMPLETE"

F_START="$(count_exact 'PHASE2_FINAL_SHA256_VERIFY_START' "$PLACE_LOG")"
F_HB="$(count_exact 'PHASE2_FINAL_SHA256_VERIFY_HEARTBEAT' "$PLACE_LOG")"
F_DONE="$(count_exact 'PHASE2_FINAL_SHA256_VERIFY_COMPLETE.*result=PASS' "$PLACE_LOG")"
[[ "$F_START" -eq 1 ]] || fail "final SHA256 START=${F_START}"
[[ "$F_HB" -ge 2 ]] || fail "final SHA256 HEARTBEAT=${F_HB}"
[[ "$F_DONE" -eq 1 ]] || fail "final SHA256 COMPLETE=${F_DONE}"
pass "final SHA256 verify START/HEARTBEAT/COMPLETE"

grep -q 'DP_PHASE2_ATOMIC_PUBLISH_START' "$PLACE_LOG" || fail "ATOMIC_PUBLISH_START missing"
grep -q 'DP_PHASE2_ATOMIC_PUBLISH=PASS' "$PLACE_LOG" || fail "ATOMIC_PUBLISH=PASS missing"

ADJ="$(adjacent_dup_count "$PLACE_LOG")"
[[ "$ADJ" -eq 0 ]] || fail "adjacent duplicate lines=${ADJ}"
pass "PROGRESS_ADJACENT_DUPLICATES=0"

# Full-read counts: source images once; bundle at most twice (create + final verify).
# Sidecar sha256sum calls contain images-6.6.0.tar.sha256 and must not count.
SOURCE_TOTAL="$(grep -cE '(^|[[:space:]/])images-6\.6\.0\.tar($|[[:space:]])' "$SHA256_CALL_LOG" || true)"
[[ "$SOURCE_TOTAL" -eq 1 ]] || fail "SOURCE_IMAGES_SHA256_FULL_READ_COUNT=${SOURCE_TOTAL} want=1"
BUNDLE_READS="$(grep -c 'dp_bundle_6.6.0-current.tar' "$SHA256_CALL_LOG" || true)"
[[ "$BUNDLE_READS" -le 2 ]] || fail "BUNDLE_SHA256_FULL_READ_COUNT=${BUNDLE_READS} want<=2"
[[ "$BUNDLE_READS" -ge 2 ]] || fail "BUNDLE_SHA256_FULL_READ_COUNT=${BUNDLE_READS} want>=2"
pass "full-read counts source=1 bundle=${BUNDLE_READS}"

FINAL_BUNDLE="${EXIST_DIR}/dp_bundle_6.6.0-current.tar"
[[ -f "$FINAL_BUNDLE" ]] || fail "final bundle missing"
ENTRY_COUNT="$(/usr/bin/tar -tf "$FINAL_BUNDLE" | wc -l | tr -d ' ')"
[[ "$ENTRY_COUNT" -eq 9 ]] || fail "bundle entry count=${ENTRY_COUNT}"
NEW_FP="$(/usr/bin/sha256sum "$FINAL_BUNDLE" | awk '{print $1}')"
[[ "$NEW_FP" != "$OLD_FP" ]] || fail "final was not replaced"
pass "final bundle entries=9 and replaced prior artifact"

# --- Failure: source SHA256 mismatch ---
BAD_CACHE="${TMP}/bad-cache"
rm -rf "$BAD_CACHE"
mkdir -p "$BAD_CACHE"
[[ -d "$CACHE" ]] || fail "ACPS cache missing before mismatch test"
cp -a "$CACHE/." "$BAD_CACHE/" || fail "cp bad-cache failed"
# Break only the copy (not the hardlinked cache/work tree).
cp -f "${BAD_CACHE}/images-6.6.0.tar" "${BAD_CACHE}/images-6.6.0.tar.broken"
mv -f "${BAD_CACHE}/images-6.6.0.tar.broken" "${BAD_CACHE}/images-6.6.0.tar"
echo '00' >>"${BAD_CACHE}/images-6.6.0.tar"
FAIL_LOG="${TMP}/fail-sha.log"
MM_LOG_FILE=""
: >"$FAIL_LOG"
set +e
( mm_acps_verify_payload_checksums "$BAD_CACHE" ) >"$FAIL_LOG" 2>&1
FAIL_RC=$?
set -e
[[ "$FAIL_RC" -ne 0 ]] || fail "mismatch should fail"
grep -qE 'ACPS_CHECKSUM_VERIFY_FAIL|SHA256_VERIFY=FAIL' "$FAIL_LOG" || {
  tail -n 40 "$FAIL_LOG"
  fail "FAIL event missing"
}
if grep 'ACPS_CHECKSUM_VERIFY_COMPLETE.*images-6\.6\.0\.tar.*result=PASS' "$FAIL_LOG"; then
  fail "false PASS on images SHA256 mismatch"
fi
grep -qE 'ACPS_CHECKSUM_VERIFY_FAIL.*images-6\.6\.0\.tar|SHA256_VERIFY=FAIL.*images-6\.6\.0\.tar' "$FAIL_LOG" \
  || fail "images SHA256 FAIL event missing"
pass "source SHA256 mismatch preserves non-zero rc"

# --- Failure: preserve existing final on place failure ---
# Restore a known final, then break work file set.
printf 'PRESERVE_ME\n' >"${EXIST_DIR}/dp_bundle_6.6.0-current.tar"
printf 'aaaa' >"${EXIST_DIR}/dp_bundle_6.6.0-current.tar.sha256"
PRES_FP="$(/usr/bin/sha256sum "${EXIST_DIR}/dp_bundle_6.6.0-current.tar" | awk '{print $1}')"
BAD_WORK="${WORK}.broken"
rm -rf "$BAD_WORK"
mkdir -p "$BAD_WORK"
for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
  [[ -e "${WORK}/${f}" ]] || continue
  ln "${WORK}/${f}" "${BAD_WORK}/${f}" 2>/dev/null || cp -f "${WORK}/${f}" "${BAD_WORK}/${f}"
done
rm -f "${BAD_WORK}/images-6.6.0.list"
set +e
( engine_place_dp_phase2_final "$BAD_WORK" 6.6.0 >/dev/null 2>&1 )
BAD_PLACE_RC=$?
set -e
[[ "$BAD_PLACE_RC" -ne 0 ]] || fail "broken place should fail"
[[ -f "${EXIST_DIR}/dp_bundle_6.6.0-current.tar" ]] || fail "final missing after fail"
AFTER_FP="$(/usr/bin/sha256sum "${EXIST_DIR}/dp_bundle_6.6.0-current.tar" | awk '{print $1}')"
[[ "$AFTER_FP" == "$PRES_FP" ]] || fail "existing final changed on failure"
find "$MM_DP_PHASE2_ROOT" -maxdepth 1 -name '6.6.0.new.*' | grep -q . \
  && fail "orphan .new remains" || true
pass "existing final preserved on failure"

# --- Heartbeat process cleanup / command failure ---
FAIL_HB_LOG="${TMP}/fail-hb.log"
MM_LOG_FILE=""
: >"$FAIL_HB_LOG"
set +e
( mm_run_with_heartbeat "TEST_HB" "file=x" "Still testing..." -- bash -c 'sleep 2.2; exit 7' ) \
  >"$FAIL_HB_LOG" 2>&1
HB_RC=$?
set -e
[[ "$HB_RC" -eq 7 ]] || fail "heartbeat helper rc=${HB_RC} want=7"
grep -q 'TEST_HB_FAIL' "$FAIL_HB_LOG" || fail "TEST_HB_FAIL missing"
if grep -q 'TEST_HB_COMPLETE.*PASS' "$FAIL_HB_LOG"; then
  fail "false PASS on failed command"
fi
sleep 0.2
if pgrep -af 'TEST_HB_HEARTBEAT' >/dev/null 2>&1; then
  fail "heartbeat leak"
fi
pass "failure rc preserved + no false PASS + no heartbeat leak"

echo "ALL test_mirror_long_step_progress checks passed"
exit 0
