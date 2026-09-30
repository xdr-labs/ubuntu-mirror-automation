#!/usr/bin/env bash
# Status PASS must not outlive a failed authoritative workflow receipt write.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

export MM_CONFIG_DIR="$TMP/config"
export MM_WORKFLOW_FILE="$MM_CONFIG_DIR/workflow.state"
export MM_STATUS_FILE="$MM_CONFIG_DIR/status"
export MM_CONFIG_FILE="$MM_CONFIG_DIR/dp-upgrade-mirror.conf"
export MM_PROJECT_ROOT="$ROOT"
export MM_MIRROR_ROOT="$TMP/mirror"
export MM_SELECTIVE_ROOT="$TMP/mirror/selective"
export MM_CLIENT_ROOT="$TMP/mirror/client"
export MM_DP_PHASE2_ROOT="$TMP/mirror/dp-phase2"
export MM_CACHE_ROOT="$TMP/mirror/.install-cache"
export MM_LOG_DIR="$TMP/logs"
export MM_STATE_ROOT="$TMP/runs"
export MM_SKIP_ROOT_CHECK=1
export MM_HERMETIC_TEST_MODE=1
export SKIP_MIRROR_HOST_VALIDATE=1
export PREPARATION_MODE=PHASE2_ONLY
mkdir -p "$MM_CONFIG_DIR" "$MM_SELECTIVE_ROOT/state" "$MM_CLIENT_ROOT" \
  "$MM_DP_PHASE2_ROOT/6.6.0" "$MM_CACHE_ROOT" "$MM_LOG_DIR" "$MM_STATE_ROOT"
: >"$MM_STATUS_FILE"

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/dp-phase2-common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_install_engine.sh"

# Seed a publication generation so readiness can proceed past missing-gen.
cat >"$MM_WORKFLOW_FILE" <<'EOF'
WORKFLOW_STATE=CLIENT_SET_PUBLISHED
CLIENT_SET_GENERATION_ID=gen-fixture-1
HTTP_PUBLICATION_GENERATION_ID=gen-fixture-1
READINESS_VERIFIED_GENERATION_ID=
COMMAND_FILE_GENERATION_ID=
PREPARATION_MODE=PHASE2_ONLY
EOF
chmod 600 "$MM_WORKFLOW_FILE"

mm_status_set HTTP_DISTRIBUTION DISABLED
mm_status_set UPGRADE_READINESS FAIL
mm_status_set READINESS_RESULT ""
mm_status_set HTTP_ENABLE_RESULT ""

# --- HTTP: workflow write failure must not leave ENABLED ---
chmod 444 "$MM_WORKFLOW_FILE"
set +e
mm_record_http_validated >/dev/null 2>&1
http_rc=$?
set -e
chmod 600 "$MM_WORKFLOW_FILE"
http_dist="$(mm_status_get HTTP_DISTRIBUTION)"
http_res="$(mm_status_get HTTP_ENABLE_RESULT)"
wf_state="$(mm_wf_get WORKFLOW_STATE)"
if [[ "$http_rc" -ne 0 && "$http_dist" != "ENABLED" && "$http_res" != "PASS" && "$wf_state" != "HTTP_ENABLED" ]]; then
  pass "HTTP workflow write failure → status not ENABLED/PASS"
else
  fail "HTTP split-brain rc=${http_rc} dist=${http_dist} res=${http_res} wf=${wf_state}"
fi

# Restore writable workflow + successful HTTP mark for readiness tests
cat >"$MM_WORKFLOW_FILE" <<'EOF'
WORKFLOW_STATE=CLIENT_SET_PUBLISHED
CLIENT_SET_GENERATION_ID=gen-fixture-1
HTTP_PUBLICATION_GENERATION_ID=gen-fixture-1
READINESS_VERIFIED_GENERATION_ID=
COMMAND_FILE_GENERATION_ID=
PREPARATION_MODE=PHASE2_ONLY
EOF
chmod 600 "$MM_WORKFLOW_FILE"
mm_status_set HTTP_DISTRIBUTION DISABLED
mm_status_set UPGRADE_READINESS FAIL

mm_record_http_validated >/dev/null 2>&1 \
  || fail "HTTP happy-path record failed"
[[ "$(mm_status_get HTTP_DISTRIBUTION)" == "ENABLED" ]] \
  && [[ "$(mm_wf_get WORKFLOW_STATE)" == "HTTP_ENABLED" ]] \
  && pass "HTTP happy-path status+workflow agree" \
  || fail "HTTP happy-path mismatch"

# --- Readiness: workflow write failure must not leave UPGRADE_READINESS=PASS ---
chmod 444 "$MM_WORKFLOW_FILE"
set +e
mm_record_readiness_validated >/dev/null 2>&1
ready_rc=$?
set -e
chmod 600 "$MM_WORKFLOW_FILE"
ready="$(mm_status_get UPGRADE_READINESS)"
ready_res="$(mm_status_get READINESS_RESULT)"
wf_ready="$(mm_wf_get WORKFLOW_STATE)"
wf_ready_gen="$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)"
if [[ "$ready_rc" -ne 0 && "$ready" != "PASS" && "$ready_res" != "PASS" && "$wf_ready" != "READINESS_VERIFIED" && -z "$wf_ready_gen" ]]; then
  pass "readiness workflow write failure → status not PASS"
else
  fail "readiness split-brain rc=${ready_rc} ready=${ready} res=${ready_res} wf=${wf_ready} gen=${wf_ready_gen}"
fi

# --- Missing publication generation: fail closed, no PASS ---
cat >"$MM_WORKFLOW_FILE" <<'EOF'
WORKFLOW_STATE=CLIENT_SET_PUBLISHED
CLIENT_SET_GENERATION_ID=
HTTP_PUBLICATION_GENERATION_ID=
READINESS_VERIFIED_GENERATION_ID=
COMMAND_FILE_GENERATION_ID=
PREPARATION_MODE=PHASE2_ONLY
EOF
chmod 600 "$MM_WORKFLOW_FILE"
mm_status_set UPGRADE_READINESS FAIL
mm_status_set READINESS_RESULT ""
set +e
mm_record_readiness_validated >/dev/null 2>&1
miss_rc=$?
set -e
[[ "$miss_rc" -ne 0 && "$(mm_status_get UPGRADE_READINESS)" != "PASS" ]] \
  && pass "missing publication generation → fail closed" \
  || fail "missing publication generation left PASS (rc=${miss_rc})"

# --- Retry recovers cleanly after prior failure ---
cat >"$MM_WORKFLOW_FILE" <<'EOF'
WORKFLOW_STATE=HTTP_ENABLED
CLIENT_SET_GENERATION_ID=gen-fixture-2
HTTP_PUBLICATION_GENERATION_ID=gen-fixture-2
READINESS_VERIFIED_GENERATION_ID=
COMMAND_FILE_GENERATION_ID=
PREPARATION_MODE=PHASE2_ONLY
EOF
chmod 600 "$MM_WORKFLOW_FILE"
mm_status_set UPGRADE_READINESS FAIL
mm_record_readiness_validated >/dev/null 2>&1 \
  || fail "readiness retry failed"
[[ "$(mm_status_get UPGRADE_READINESS)" == "PASS" ]] \
  && [[ "$(mm_wf_get WORKFLOW_STATE)" == "READINESS_VERIFIED" ]] \
  && [[ "$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)" == "gen-fixture-2" ]] \
  && pass "readiness retry recovers cleanly" \
  || fail "readiness retry mismatch"

# --- Readiness generation CAS: validation of OLD must never receipt NEW ---
cat >"$MM_WORKFLOW_FILE" <<'EOF'
WORKFLOW_STATE=HTTP_ENABLED
CLIENT_SET_GENERATION_ID=GEN_NEW
HTTP_PUBLICATION_GENERATION_ID=GEN_NEW
READINESS_VERIFIED_GENERATION_ID=
COMMAND_FILE_GENERATION_ID=
PREPARATION_MODE=PHASE2_ONLY
EOF
chmod 600 "$MM_WORKFLOW_FILE"
for kv in \
  'CONFIGURATION_READY=PASS' \
  'ACPS_CONNECTION=PASS' \
  'ACPS_PHASE2_DOWNLOADED=PASS' \
  'ACPS_CHECKSUM=PASS' \
  'UPSTREAM_BRINGUP_PROVENANCE=PASS' \
  'UPSTREAM_BRINGUP_DRIFT=NO' \
  'PATCHED_BRINGUP_APPLIED=YES' \
  'PHASE2_BUNDLE_ENTRY_COUNT=9' \
  'PHASE2_BUNDLE_CHECKSUM=PASS' \
  'CLIENT_FILES_READY=PASS' \
  'HTTP_CONFIGURATION_READY=PASS' \
  'HTTP_DISTRIBUTION=ENABLED'
do
  mm_status_set "${kv%%=*}" "${kv#*=}"
done
TARGET_DP_VERSION=6.6.0
PHASE2_TARGET_VERSION=6.6.0
PREPARATION_MODE=PHASE2_ONLY
MM_READINESS_VALIDATED_GENERATION_ID=GEN_OLD
set +e
cas_out="$(engine_compute_readiness 2>&1)"
cas_rc=$?
set -e
if [[ "$cas_rc" -ne 0 ]] \
  && printf '%s\n' "$cas_out" | grep -q 'reason=publication_generation_changed' \
  && [[ "$(mm_status_get UPGRADE_READINESS)" == "FAIL" ]] \
  && [[ "$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)" != "GEN_NEW" ]]; then
  pass "readiness generation CAS blocks OLD-validation/NEW-receipt TOCTOU"
else
  fail "readiness generation CAS failed rc=${cas_rc} out=${cas_out} ready=$(mm_status_get UPGRADE_READINESS) receipt=$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)"
fi

# Both Menu 4 entry points must hold the publication lock across live
# validation and receipt generation. The behavioral CAS above is the second
# line of defense; this scoped check prevents accidental lock removal.
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
GUI_FN="$(sed -n '/^gui_verify_readiness()/,/^gui_show_status()/p' "$INSTALLER")"
CLI_FN="$(sed -n '/^cmd_verify_readiness()/,/^cmd_diagnose_mirror_runtime()/p' "$INSTALLER")"
for label in GUI CLI; do
  if [[ "$label" == "GUI" ]]; then fn="$GUI_FN"; else fn="$CLI_FN"; fi
  acq_line="$(printf '%s\n' "$fn" | grep -n 'publication_lock_acquire' | head -1 | cut -d: -f1)"
  validate_line="$(printf '%s\n' "$fn" | grep -n 'engine_validate_upgrade_readiness_live' | tail -1 | cut -d: -f1)"
  compute_line="$(printf '%s\n' "$fn" | grep -n 'engine_compute_readiness' | tail -1 | cut -d: -f1)"
  release_line="$(printf '%s\n' "$fn" | grep -n 'publication_lock_release' | tail -1 | cut -d: -f1)"
  if [[ -n "$acq_line" && -n "$validate_line" && -n "$compute_line" && -n "$release_line" ]] \
    && (( acq_line < validate_line && validate_line < compute_line && compute_line < release_line )); then
    pass "${label} readiness validates and receipts under one publication lock"
  else
    fail "${label} readiness publication-lock scope invalid acq=${acq_line} validate=${validate_line} compute=${compute_line} release=${release_line}"
  fi
done

# Menu 7 generation gate still blocks when readiness receipt absent
cat >"$MM_WORKFLOW_FILE" <<'EOF'
WORKFLOW_STATE=HTTP_ENABLED
CLIENT_SET_GENERATION_ID=gen-fixture-3
HTTP_PUBLICATION_GENERATION_ID=gen-fixture-3
READINESS_VERIFIED_GENERATION_ID=
COMMAND_FILE_GENERATION_ID=
PREPARATION_MODE=PHASE2_ONLY
EOF
if mm_wf_readiness_generation_current 2>/dev/null; then
  fail "Menu7 readiness gate passed without verified generation"
else
  pass "Menu7 readiness gate blocked without verified generation"
fi


# --- Menu 7 command publication: receipt failure restores command + workflow + status ---
CMD_DIR="${TMP}/commands"
mkdir -p "$CMD_DIR"
CMD_DEST="${CMD_DIR}/dp-client-upgrade-commands.txt"
CMD_TMP="${CMD_DIR}/candidate.txt"
printf 'KNOWN_GOOD_COMMAND\n' >"$CMD_DEST"
chmod 600 "$CMD_DEST"
cat >"$MM_WORKFLOW_FILE" <<'EOF'
WORKFLOW_STATE=READINESS_VERIFIED
CLIENT_SET_GENERATION_ID=gen-command-1
HTTP_PUBLICATION_GENERATION_ID=gen-command-1
READINESS_VERIFIED_GENERATION_ID=gen-command-1
COMMAND_FILE_GENERATION_ID=
PREPARATION_MODE=PHASE2_ONLY
EOF
chmod 600 "$MM_WORKFLOW_FILE"
cat >"$MM_STATUS_FILE" <<'EOF'
UPGRADE_READINESS=PASS
READINESS_RESULT=PASS
WORKFLOW_STATE=READINESS_VERIFIED
EOF
chmod 600 "$MM_STATUS_FILE"
printf 'NEW_COMMAND\n' >"$CMD_TMP"
cmd_before="$(sha256sum "$CMD_DEST" | awk '{print $1}')"
wf_before="$(sha256sum "$MM_WORKFLOW_FILE" | awk '{print $1}')"
status_before="$(sha256sum "$MM_STATUS_FILE" | awk '{print $1}')"

# Isolate this case to transactionality; structural validator behavior is covered
# by dedicated Menu 7 command-file tests.
mm_wf_validate_command_file_content() {
  printf 'COMMAND_FILE_LINE_COUNT=1\n'
  printf 'COMMAND_FILE_EXECUTABLE_COUNT=1\n'
  printf 'COMMAND_FILE_MAX_BLOCK_LINES=1\n'
  printf 'COMMAND_FILE_CONTINUATION_VALIDATION=PASS\n'
  printf 'COMMAND_FILE_BUILD=PASS\n'
  return 0
}
set +e
cmd_out="$(MM_COMMAND_FILE_FAKE_RECEIPT_FAIL=1 \
  mm_wf_atomic_publish_command_file "$CMD_TMP" "$CMD_DEST" PHASE2_ONLY gen-command-1 2>&1)"
cmd_rc=$?
set -e
cmd_after="$(sha256sum "$CMD_DEST" | awk '{print $1}')"
wf_after="$(sha256sum "$MM_WORKFLOW_FILE" | awk '{print $1}')"
status_after="$(sha256sum "$MM_STATUS_FILE" | awk '{print $1}')"
if [[ "$cmd_rc" -ne 0 ]] \
  && printf '%s\n' "$cmd_out" | grep -q 'COMMAND_FILE_ROLLBACK=PASS previous_restored=YES' \
  && [[ "$cmd_before" == "$cmd_after" ]] \
  && [[ "$(mm_wf_get WORKFLOW_STATE)" == "READINESS_VERIFIED" ]] \
  && [[ -z "$(mm_wf_get COMMAND_FILE_GENERATION_ID)" ]] \
  && [[ "$(mm_status_get WORKFLOW_STATE)" == "READINESS_VERIFIED" ]] \
  && [[ "$(mm_status_get UPGRADE_READINESS)" == "PASS" ]] \
  && [[ "$(mm_status_get READINESS_RESULT)" == "PASS" ]] \
  && [[ -z "$(mm_status_get COMMAND_FILE_GENERATION_ID)" ]]; then
  pass "command receipt failure restores command/workflow/status semantics"
else
  fail "command transaction rollback mismatch rc=${cmd_rc} out=${cmd_out}"
fi
if compgen -G "${CMD_DIR}/.command.previous.*" >/dev/null \
  || compgen -G "${MM_CONFIG_DIR}/.workflow.previous.*" >/dev/null \
  || compgen -G "${MM_CONFIG_DIR}/.status.previous.*" >/dev/null; then
  fail "command transaction left backup files"
else
  pass "command transaction cleans backup files"
fi

# Concurrent unrelated store writes after the command receipt must survive a
# subsequent receipt failure/rollback. Rollback is field-scoped, never raw file
# snapshot replacement.
printf 'KNOWN_GOOD_CONCURRENT\n' >"$CMD_DEST"
cat >"$MM_WORKFLOW_FILE" <<'EOF'
WORKFLOW_STATE=READINESS_VERIFIED
CLIENT_SET_GENERATION_ID=gen-command-2
HTTP_PUBLICATION_GENERATION_ID=gen-command-2
READINESS_VERIFIED_GENERATION_ID=gen-command-2
COMMAND_FILE_GENERATION_ID=
CONFIG_CHANGE_CLASS=NONE
NEXT_REQUIRED_ACTION=NONE
PREPARATION_MODE=PHASE2_ONLY
EOF
cat >"$MM_STATUS_FILE" <<'EOF'
UPGRADE_READINESS=PASS
READINESS_RESULT=PASS
WORKFLOW_STATE=READINESS_VERIFIED
COMMAND_FILE_GENERATION_ID=
EOF
printf 'NEW_CONCURRENT_COMMAND\n' >"$CMD_TMP"
concurrent_cmd_before="$(sha256sum "$CMD_DEST" | awk '{print $1}')"
eval "$(declare -f mm_wf_mark_commands_generated | sed '1s/mm_wf_mark_commands_generated/_txn_real_mm_wf_mark_commands_generated/')"
mm_wf_mark_commands_generated() {
  _txn_real_mm_wf_mark_commands_generated "$@" || return $?
  mm_wf_set CONCURRENT_WRITER PRESERVE_ME || return $?
  mm_status_set CONCURRENT_WRITER PRESERVE_ME || return $?
  return 77
}
set +e
concurrent_out="$(mm_wf_atomic_publish_command_file "$CMD_TMP" "$CMD_DEST" PHASE2_ONLY gen-command-2 2>&1)"
concurrent_rc=$?
set -e
unset -f mm_wf_mark_commands_generated
eval "$(declare -f _txn_real_mm_wf_mark_commands_generated | sed '1s/_txn_real_mm_wf_mark_commands_generated/mm_wf_mark_commands_generated/')"
unset -f _txn_real_mm_wf_mark_commands_generated
if [[ "$concurrent_rc" -ne 0 ]] \
  && [[ "$concurrent_cmd_before" == "$(sha256sum "$CMD_DEST" | awk '{print $1}')" ]] \
  && [[ "$(mm_wf_get CONCURRENT_WRITER)" == "PRESERVE_ME" ]] \
  && [[ "$(mm_status_get CONCURRENT_WRITER)" == "PRESERVE_ME" ]] \
  && [[ "$(mm_wf_get WORKFLOW_STATE)" == "READINESS_VERIFIED" ]] \
  && [[ "$(mm_status_get WORKFLOW_STATE)" == "READINESS_VERIFIED" ]]; then
  pass "command rollback preserves concurrent workflow/status writer"
else
  fail "command rollback lost concurrent writer rc=${concurrent_rc} out=${concurrent_out}"
fi

# --- Workflow succeeds, required status receipt fails: rollback both stores ---
eval "$(declare -f mm_status_set | sed '1s/mm_status_set/_txn_real_mm_status_set/')"
status_fail_transition_case() {
  local label="$1" action="$2" before_wf before_status rc
  before_wf="$(sha256sum "$MM_WORKFLOW_FILE" | awk '{print $1}')"
  before_status="$(sha256sum "$MM_STATUS_FILE" | awk '{print $1}')"
  mm_status_set() { return 77; }
  set +e
  eval "$action" >/dev/null 2>&1
  rc=$?
  set -e
  unset -f mm_status_set
  eval "$(declare -f _txn_real_mm_status_set | sed '1s/_txn_real_mm_status_set/mm_status_set/')"
  if [[ "$rc" -ne 0 ]] \
    && [[ "$before_wf" == "$(sha256sum "$MM_WORKFLOW_FILE" | awk '{print $1}')" ]] \
    && [[ "$before_status" == "$(sha256sum "$MM_STATUS_FILE" | awk '{print $1}')" ]]; then
    pass "$label status failure rolls back workflow+status"
  else
    fail "$label status failure split-brain rc=${rc}"
  fi
}

cat >"$MM_WORKFLOW_FILE" <<'EOF'
WORKFLOW_STATE=CONFIGURED
WORKFLOW_GENERATION_ID=wf-txn
OPERATION_START_CONFIG_SHA256=
PREPARATION_MODE=PHASE2_ONLY
EOF
printf 'UPGRADE_READINESS=FAIL\n' >"$MM_STATUS_FILE"
status_fail_transition_case PREPARED 'mm_wf_mark_prepared phase2-only phase2:test'

cat >"$MM_WORKFLOW_FILE" <<'EOF'
WORKFLOW_STATE=PREPARED
WORKFLOW_GENERATION_ID=wf-txn
PREPARATION_MODE=PHASE2_ONLY
EOF
printf 'UPGRADE_READINESS=FAIL\n' >"$MM_STATUS_FILE"
status_fail_transition_case CLIENT_SET_PUBLISHED \
  'mm_wf_mark_client_set_published gen-txn "" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "" "" SUBSHELL_V2 3 "" "" ""'

cat >"$MM_WORKFLOW_FILE" <<'EOF'
WORKFLOW_STATE=CLIENT_SET_PUBLISHED
CLIENT_SET_GENERATION_ID=gen-txn
HTTP_PUBLICATION_GENERATION_ID=
PREPARATION_MODE=PHASE2_ONLY
EOF
printf 'HTTP_DISTRIBUTION=DISABLED\nUPGRADE_READINESS=FAIL\n' >"$MM_STATUS_FILE"
status_fail_transition_case HTTP_ENABLED 'mm_wf_mark_http_enabled gen-txn'

cat >"$MM_WORKFLOW_FILE" <<'EOF'
WORKFLOW_STATE=HTTP_ENABLED
CLIENT_SET_GENERATION_ID=gen-txn
HTTP_PUBLICATION_GENERATION_ID=gen-txn
READINESS_VERIFIED_GENERATION_ID=
PREPARATION_MODE=PHASE2_ONLY
EOF
printf 'HTTP_DISTRIBUTION=ENABLED\nUPGRADE_READINESS=FAIL\nREADINESS_RESULT=\n' >"$MM_STATUS_FILE"
status_fail_transition_case READINESS_VERIFIED 'mm_wf_mark_readiness_verified'
unset -f _txn_real_mm_status_set

# --- Menu 2 PREPARED receipt failure must propagate; never print PASS ---
TARGET_DP_VERSION=6.6.0
PHASE2_TARGET_VERSION=6.6.0
PREPARATION_MODE=PHASE2_ONLY
mkdir -p "${MM_DP_PHASE2_ROOT}/6.6.0"
printf 'bundle\n' >"${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar"
sha256sum "${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar" \
  >"${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar.sha256"
printf 'TARGET_DP_VERSION=6.6.0\nPHASE2_ARTIFACT_VERSION=6.6.0\n' \
  >"${MM_DP_PHASE2_ROOT}/6.6.0/release.env"
eval "$(declare -f mm_wf_mark_prepared | sed '1s/mm_wf_mark_prepared/_txn_real_mm_wf_mark_prepared/')"
mm_wf_mark_prepared() { return 77; }
set +e
prepared_out="$(mm_record_artifacts_prepared 2>&1)"
prepared_rc=$?
set -e
unset -f mm_wf_mark_prepared
eval "$(declare -f _txn_real_mm_wf_mark_prepared | sed '1s/_txn_real_mm_wf_mark_prepared/mm_wf_mark_prepared/')"
unset -f _txn_real_mm_wf_mark_prepared
if [[ "$prepared_rc" -ne 0 ]] \
  && ! printf '%s\n' "$prepared_out" | grep -q 'HEAVY_ARTIFACTS_PREPARED=PASS'; then
  pass "Menu2 PREPARED receipt failure propagates without PASS"
else
  fail "Menu2 PREPARED receipt failure swallowed rc=${prepared_rc} out=${prepared_out}"
fi

# --- Download receipt partial status failure restores pre-call status ---
eval "$(declare -f mm_status_set | sed '1s/mm_status_set/_txn_real_mm_status_set/')"
printf 'BASELINE=YES\nUPGRADE_READINESS=FAIL\n' >"$MM_STATUS_FILE"
download_status_before="$(sha256sum "$MM_STATUS_FILE" | awk '{print $1}')"
mm_status_set() {
  if [[ "$1" == "DOWNLOAD_ARTIFACT_FINGERPRINT" ]]; then
    return 77
  fi
  _txn_real_mm_status_set "$@"
}
set +e
mm_record_download_validated >/dev/null 2>&1
download_rc=$?
set -e
unset -f mm_status_set
eval "$(declare -f _txn_real_mm_status_set | sed '1s/_txn_real_mm_status_set/mm_status_set/')"
unset -f _txn_real_mm_status_set
if [[ "$download_rc" -ne 0 ]] \
  && [[ "$download_status_before" == "$(sha256sum "$MM_STATUS_FILE" | awk '{print $1}')" ]]; then
  pass "download receipt status failure rolls back partial status"
else
  fail "download receipt status failure left partial PASS/state rc=${download_rc}"
fi

[[ "$FAIL" -eq 0 ]]
echo "ALL STATUS WORKFLOW TRANSACTIONALITY TESTS PASSED"
