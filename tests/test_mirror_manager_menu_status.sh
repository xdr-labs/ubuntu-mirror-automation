#!/usr/bin/env bash
# Targeted tests: workflow [COMPLETED] labels + Enable HTTP SHA256 heartbeat.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/dp-phase2-common.sh"

export MM_SKIP_ROOT_CHECK=1
# shellcheck source=lib/seed_complete_client_http_set.sh
source "${ROOT}/tests/lib/seed_complete_client_http_set.sh"
export MM_MIRROR_ROOT="${TMP}/mirror"
export MM_SELECTIVE_ROOT="${MM_MIRROR_ROOT}/selective"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_CLIENT_ROOT="${MM_MIRROR_ROOT}/client"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export MM_CONFIG_DIR="${TMP}/config"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.status"
export MM_LOG_DIR="${TMP}/logs"
export MM_STATE_ROOT="${TMP}/runs"
export MM_VERIFY_HTTP_BASE="http://127.0.0.1:9"
export TARGET_DP_VERSION=6.6.0
export OS_CORE_R2_URL="https://example.test/ubuntu-os-core.tar"
mkdir -p "$MM_CONFIG_DIR" "$MM_LOG_DIR" "$MM_SELECTIVE_ROOT" "$MM_CLIENT_ROOT" "$MM_CACHE_ROOT"

engine_resolve_paths() {
  MM_MIRROR_ROOT="${MM_MIRROR_ROOT}"
  MM_SELECTIVE_ROOT="${MM_SELECTIVE_ROOT}"
  MM_DP_PHASE2_ROOT="${MM_DP_PHASE2_ROOT}"
  MM_CLIENT_ROOT="${MM_CLIENT_ROOT}"
  MM_CACHE_ROOT="${MM_CACHE_ROOT}"
}

adjacent_dup_count() {
  awk 'NR>1 && $0==prev {c++} {prev=$0} END{print c+0}' "$1"
}

seed_config() {
  umask 077
  cat >"$MM_CONFIG_FILE" <<EOF
PREPARATION_MODE=FULL
ACPS_USERNAME=demo
ACPS_PASSWORD=secret
MIRROR_SERVER_IP=127.0.0.1
MIRROR_HTTP_URL=http://127.0.0.1
EOF
  chmod 600 "$MM_CONFIG_FILE"
  mm_status_set CONFIGURATION_READY PASS
}

seed_client_files() {
  seed_complete_client_http_set "$MM_CLIENT_ROOT" "${MIRROR_HTTP_URL:-http://127.0.0.1}"     "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  # Menu label tests exercise download fingerprint/status, not signing provenance.
  mm_client_set_current_source() { return 0; }
}

seed_artifacts() {
  local ver=6.6.0
  local dp="${MM_DP_PHASE2_ROOT}/${ver}"
  local bundle="${dp}/dp_bundle_${ver}-current.tar"
  mkdir -p "${MM_SELECTIVE_ROOT}/ubuntu" "${MM_SELECTIVE_ROOT}/shared/offline" "$dp"
  printf 'payload\n' >"${MM_SELECTIVE_ROOT}/ubuntu/marker"
  printf 'RELEASE\n' >"${dp}/release.env"
  # Small fake bundle + matching sidecar
  printf 'BUNDLE_DATA_FOR_TEST\n' >"$bundle"
  (cd "$dp" && sha256sum "dp_bundle_${ver}-current.tar" >"dp_bundle_${ver}-current.tar.sha256")
  seed_client_files
  mm_status_set OS_MIRROR_READY PASS
  mm_status_set R2_OS_CORE_DOWNLOADED PASS
  mm_status_set R2_OS_CORE_CHECKSUM PASS
  mm_status_set PHASE2_BUNDLE_CHECKSUM PASS
  mm_status_set PHASE2_BUNDLE_ENTRY_COUNT 9
  mm_status_set CLIENT_FILES_READY PASS
  mm_status_set DOWNLOAD_PREPARE_RESULT PASS
  mm_status_set LAST_EXECUTION_RESULT PASS
  mm_status_set INSTALL_RESULT PASS
  mm_record_download_validated
}

mock_nginx_ok() {
  mm_nginx_distribution_live() { return 0; }
  mm_http_required_urls_ok() { return 0; }
}

mock_nginx_fail() {
  mm_nginx_distribution_live() { return 1; }
  mm_http_required_urls_ok() { return 1; }
}

reset_status() {
  : >"$MM_STATUS_FILE"
  chmod 600 "$MM_STATUS_FILE"
}

labels_from_collect() {
  mm_collect_workflow_status
  CONFIG_L="$(mm_menu_label "Configuration" "${MM_WF_CONFIG_COMPLETED}")"
  DOWN_L="$(mm_menu_label "Download and Prepare Upgrade Files" "${MM_WF_DOWNLOAD_COMPLETED}")"
  HTTP_L="$(mm_menu_label "Enable HTTP Distribution" "${MM_WF_HTTP_COMPLETED}")"
  READY_L="$(mm_menu_label "Verify Upgrade Readiness" "${MM_WF_READINESS_COMPLETED}")"
  PROG="$(mm_workflow_progress_text)"
}

echo "======== Menu completion cases ========"

# Case 1 — nothing ready
reset_status
rm -f "$MM_CONFIG_FILE"
labels_from_collect
[[ "$CONFIG_L" == "Configuration" ]] || fail "C1 config label=$CONFIG_L"
[[ "$DOWN_L" == "Download and Prepare Upgrade Files" ]] || fail "C1 download"
[[ "$HTTP_L" == "Enable HTTP Distribution" ]] || fail "C1 http"
[[ "$READY_L" == "Verify Upgrade Readiness" ]] || fail "C1 ready"
[[ "${MM_WF_PROGRESS_COUNT}" -eq 0 ]] || fail "C1 progress=${MM_WF_PROGRESS_COUNT}"
COMPLETED_N="$(printf '%s\n' "$CONFIG_L" "$DOWN_L" "$HTTP_L" "$READY_L" | grep -c '\[COMPLETED\]' || true)"
[[ "$COMPLETED_N" -eq 0 ]] && pass "C1 COMPLETED count=0" || fail "C1 COMPLETED=${COMPLETED_N}"

# Case 2 — config only
reset_status
seed_config
labels_from_collect
[[ "$CONFIG_L" == "Configuration [COMPLETED]" ]] || fail "C2 config=$CONFIG_L"
COMPLETED_N="$(printf '%s\n' "$CONFIG_L" "$DOWN_L" "$HTTP_L" "$READY_L" | grep -c '\[COMPLETED\]' || true)"
[[ "$COMPLETED_N" -eq 1 && "${MM_WF_PROGRESS_COUNT}" -eq 1 ]] \
  && pass "C2 config only COMPLETED=1" || fail "C2 count=${COMPLETED_N} progress=${MM_WF_PROGRESS_COUNT}"

# Case 3 — config + artifacts
seed_artifacts
mock_nginx_fail
labels_from_collect
[[ "$CONFIG_L" == "Configuration [COMPLETED]" ]] || fail "C3 config"
[[ "$DOWN_L" == "Download and Prepare Upgrade Files [COMPLETED]" ]] || fail "C3 download=$DOWN_L"
[[ "$HTTP_L" == "Enable HTTP Distribution" ]] || fail "C3 http should not complete"
[[ "${MM_WF_PROGRESS_COUNT}" -eq 2 ]] && pass "C3 progress=2" || fail "C3 progress=${MM_WF_PROGRESS_COUNT}"

# Case 4 — HTTP enabled
mm_status_set HTTP_DISTRIBUTION ENABLED
mm_status_set HTTP_CONFIGURATION_READY PASS
mm_status_set HTTP_ENABLE_RESULT PASS
mock_nginx_ok
labels_from_collect
[[ "$HTTP_L" == "Enable HTTP Distribution [COMPLETED]" ]] || fail "C4 http=$HTTP_L"
[[ "${MM_WF_PROGRESS_COUNT}" -eq 3 ]] && pass "C4 progress=3" || fail "C4 progress=${MM_WF_PROGRESS_COUNT}"

# Case 5 — readiness PASS
mm_status_set UPGRADE_READINESS PASS
mm_record_readiness_validated
labels_from_collect
[[ "$READY_L" == "Verify Upgrade Readiness [COMPLETED]" ]] || fail "C5 ready=$READY_L"
[[ "${MM_WF_PROGRESS_COUNT}" -eq 4 ]] && pass "C5 all COMPLETED" || fail "C5 progress=${MM_WF_PROGRESS_COUNT}"
echo "$PROG" | grep -q 'Progress: 4 of 4' && pass "C5 progress text" || fail "C5 progress text=$PROG"

# Case 6 — nginx stop clears HTTP + readiness
mock_nginx_fail
labels_from_collect
[[ "$HTTP_L" == "Enable HTTP Distribution" ]] || fail "C6 http still completed"
[[ "$READY_L" == "Verify Upgrade Readiness" ]] || fail "C6 ready still completed"
pass "C6 nginx stop clears HTTP/readiness"

# Case 7 — bundle mtime/size change clears download + readiness
mock_nginx_ok
mm_status_set HTTP_DISTRIBUTION ENABLED
mm_status_set HTTP_CONFIGURATION_READY PASS
mm_status_set UPGRADE_READINESS PASS
mm_record_readiness_validated
# mutate bundle
printf 'CHANGED\n' >>"${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar"
labels_from_collect
[[ "$DOWN_L" == "Download and Prepare Upgrade Files" ]] || fail "C7 download still completed"
[[ "$READY_L" == "Verify Upgrade Readiness" ]] || fail "C7 ready still completed"
pass "C7 artifact change clears download/readiness"

# Case 8 — stale readiness PASS + HTTP 404
seed_artifacts
mm_status_set HTTP_DISTRIBUTION ENABLED
mm_status_set HTTP_CONFIGURATION_READY PASS
mm_status_set UPGRADE_READINESS PASS
mm_status_set READINESS_RESULT PASS
mm_status_set READINESS_ARTIFACT_FINGERPRINT "$(mm_artifact_fingerprint)"
mm_status_set READINESS_CONFIG_FINGERPRINT "$(mm_config_fingerprint)"
mm_nginx_distribution_live() { return 0; }
mm_http_required_urls_ok() { return 1; }
labels_from_collect
[[ "$READY_L" == "Verify Upgrade Readiness" ]] || fail "C8 stale readiness visible"
[[ "$HTTP_L" == "Enable HTTP Distribution" ]] || fail "C8 http still completed with 404"
pass "C8 stale readiness + HTTP fail clears labels"

# Case 9 — utility menus never get COMPLETED in dispatch tags
INST="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
if grep -E '"5".*\[COMPLETED\]|"6".*\[COMPLETED\]|"7".*\[COMPLETED\]|"0".*\[COMPLETED\]' "$INST"; then
  fail "C9 utility/exit has COMPLETED in tag"
else
  pass "C9 utility COMPLETED suffix none"
fi

# Case 10 — menu tags remain bare numbers; suffix only in description vars
awk '
  /^cmd_mirror_manager\(\)/ { in_fn=1 }
  in_fn && /"1" "\$\{configuration_label\}"/ { t1=1 }
  in_fn && /"2" "\$\{download_label\}"/ { t2=1 }
  in_fn && /"3" "\$\{http_label\}"/ { t3=1 }
  in_fn && /"4" "\$\{readiness_label\}"/ { t4=1 }
  in_fn && /"1 \[COMPLETED\]"/ { bad=1 }
  in_fn && /^}/ { exit((t1 && t2 && t3 && t4 && !bad) ? 0 : 1) }
' "$INST" && pass "C10 menu dispatch tags 1-4 bare" || fail "C10 menu dispatch tags"

# Menu render must not invoke full SHA helpers
if grep -n 'mm_collect_workflow_status\|mm_configuration_completed\|mm_download_completed\|mm_http_completed\|mm_readiness_completed' \
  "${ROOT}/scripts/lib/mirror_manager_common.sh" | grep -E 'sha256sum|mm_verify_sha256'; then
  fail "menu status collectors call SHA256"
else
  pass "MENU_RENDER_TRIGGERS_30GB_SHA=NO"
fi

echo "======== Enable HTTP SHA256 heartbeat ========"
# Slow sha256sum fixture + 1s heartbeat
WRAP="${TMP}/wrap"
mkdir -p "$WRAP"
cat >"${WRAP}/sha256sum" <<'EOF'
#!/usr/bin/env bash
# Slow enough for >=2 heartbeats at 1s interval.
sleep 2.4
exec /usr/bin/sha256sum "$@"
EOF
chmod +x "${WRAP}/sha256sum"
export PATH="${WRAP}:${PATH}"
export MM_LONG_STEP_HEARTBEAT_SEC=1
export MM_LIVE_PROGRESS=0

HB_DIR="${TMP}/hb"
mkdir -p "$HB_DIR"
printf 'heartbeat-bundle\n' >"${HB_DIR}/bundle.tar"
(cd "$HB_DIR" && /usr/bin/sha256sum bundle.tar >bundle.tar.sha256)

HB_LOG="${TMP}/hb.log"
set +e
( mm_verify_sha256_pair_logged \
  "${HB_DIR}/bundle.tar" \
  "${HB_DIR}/bundle.tar.sha256" \
  "SHA256_VERIFICATION" \
  "Still verifying the Phase 2 bundle SHA256 before enabling HTTP distribution..." \
  "operation=enable-http" ) >"$HB_LOG" 2>&1
HB_RC=$?
set -e
[[ "$HB_RC" -eq 0 ]] || { tail -n 40 "$HB_LOG"; fail "heartbeat verify rc=${HB_RC}"; }

START_N="$(grep -c 'SHA256_VERIFICATION_START' "$HB_LOG" || true)"
HB_N="$(grep -c 'SHA256_VERIFICATION_HEARTBEAT' "$HB_LOG" || true)"
DONE_N="$(grep -c 'SHA256_VERIFICATION_COMPLETE.*result=PASS' "$HB_LOG" || true)"
[[ "$START_N" -eq 1 ]] || fail "START count=${START_N}"
[[ "$HB_N" -ge 2 ]] || fail "HEARTBEAT count=${HB_N}"
[[ "$DONE_N" -eq 1 ]] || fail "COMPLETE count=${DONE_N}"
grep -q 'operation=enable-http' "$HB_LOG" || fail "operation field missing"
grep -q 'Still verifying the Phase 2 bundle SHA256 before enabling HTTP distribution' "$HB_LOG" \
  || fail "human progress missing"
PREV=0
MONO=1
while read -r n; do
  [[ -z "$n" ]] && continue
  if [[ "$n" -lt "$PREV" ]]; then MONO=0; fi
  PREV="$n"
done < <(grep 'SHA256_VERIFICATION_HEARTBEAT' "$HB_LOG" | grep -oE 'elapsed=[0-9]+' | cut -d= -f2)
[[ "$MONO" -eq 1 ]] || fail "elapsed not monotonic"
ADJ="$(adjacent_dup_count "$HB_LOG")"
[[ "$ADJ" -eq 0 ]] || fail "adjacent duplicates=${ADJ}"
pass "ENABLE_HTTP_SHA heartbeat START/HB/COMPLETE"

# Failure preserves rc and emits no PASS
printf 'x' >>"${HB_DIR}/bundle.tar"
FAIL_LOG="${TMP}/hb-fail.log"
set +e
( mm_verify_sha256_pair_logged \
  "${HB_DIR}/bundle.tar" \
  "${HB_DIR}/bundle.tar.sha256" \
  "SHA256_VERIFICATION" \
  "Still verifying..." \
  "operation=enable-http" ) >"$FAIL_LOG" 2>&1
FAIL_RC=$?
set -e
[[ "$FAIL_RC" -ne 0 ]] || fail "mismatch should fail"
if grep -q 'SHA256_VERIFICATION_COMPLETE.*result=PASS' "$FAIL_LOG"; then
  fail "FALSE_PASS on mismatch"
fi
grep -qE 'result=FAIL' "$FAIL_LOG" || fail "FAIL result missing"
# No leaked background sha256sum
LEAK="$(pgrep -af "sha256sum ${HB_DIR}/bundle.tar" || true)"
[[ -z "$LEAK" ]] && pass "FAILURE_RC_PRESERVED BACKGROUND_PROCESS_LEAK=0" \
  || fail "background leak: $LEAK"

# Default heartbeat interval remains 30 when unset
unset MM_LONG_STEP_HEARTBEAT_SEC
HB_DEF="$(mm_long_step_heartbeat_seconds)"
[[ "$HB_DEF" == "30" ]] && pass "ENABLE_HTTP_SHA_HEARTBEAT_INTERVAL=30" \
  || fail "default heartbeat=${HB_DEF}"

# Status file mode 600
mm_status_set TEST_KEY PASS
MODE="$(stat -c '%a' "$MM_STATUS_FILE")"
[[ "$MODE" == "600" ]] && pass "STATE_FILE_MODE=600" || fail "status mode=${MODE}"

echo "======== Summary ========"
echo "PASS=${PASS} FAIL=${FAIL}"
[[ "$FAIL" -eq 0 ]]
