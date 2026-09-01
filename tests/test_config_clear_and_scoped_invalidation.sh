#!/usr/bin/env bash
# C01–C07 / I01–I12 / G01–G06: config clear persistence + scoped invalidation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }
expect() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 0755 "$TMP"

export MM_PROJECT_ROOT="$ROOT"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$MM_CONFIG_DIR/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$MM_CONFIG_DIR/status"
export MM_WORKFLOW_FILE="$MM_CONFIG_DIR/workflow.state"
export MM_LOG_DIR="$TMP/logs"
export MM_CLIENT_ROOT="$TMP/mirror/client"
export SKIP_MIRROR_HOST_VALIDATE=1
mkdir -p "$MM_CONFIG_DIR" "$MM_LOG_DIR" "$MM_CLIENT_ROOT/lib"
: >"$MM_STATUS_FILE"

python3 "$ROOT/scripts/lib/build_client_launchers.py" \
  --project-root "$ROOT" \
  --output-dir "$MM_CLIENT_ROOT" \
  --mirror-base-url "http://192.0.2.10" \
  --signing-fingerprint "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" >/dev/null
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/phase2_helper_generation.sh"
install -m 0755 "$ROOT/client/stage-dp-phase2.sh" "$MM_CLIENT_ROOT/stage-dp-phase2.sh"
install -m 0755 "$ROOT/client/bringup_py3_dp_lifecycle.sh" "$MM_CLIENT_ROOT/bringup_py3_dp_lifecycle.sh"
for hf in dp-offline-source-product-version.sh dp-phase2-operation-progress.sh \
  dp-phase2-bringup-lifecycle.sh dp-phase2-ubuntu-prerequisites.sh
do
  install -m 0755 "$ROOT/client/lib/${hf}" "$MM_CLIENT_ROOT/lib/${hf}"
done
phase2_helper_generation_write "$MM_CLIENT_ROOT" >/dev/null
phase2_upgrade_wrapper_write "$MM_CLIENT_ROOT" "http://192.0.2.10" "6.6.0" >/dev/null

# shellcheck source=/dev/null
source "$ROOT/scripts/lib/mirror_manager_common.sh"

seed_ready_workflow() {
  local state="${1:-COMMANDS_GENERATED}"
  mm_wf_ensure_file
  mm_wf_store_layer_identities
  local gen="gen-ready-1"
  mm_wf_set_many \
    "WORKFLOW_STATE=${state}" \
    "WORKFLOW_GENERATION_ID=${gen}" \
    "OS_CORE_GENERATION_ID=os-${gen}" \
    "PHASE2_GENERATION_ID=p2-${gen}" \
    "CLIENT_SET_GENERATION_ID=${gen}" \
    "CLIENT_SIGNING_FINGERPRINT=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
    "HTTP_PUBLICATION_GENERATION_ID=${gen}" \
    "READINESS_VERIFIED_GENERATION_ID=${gen}" \
    "COMMAND_FILE_GENERATION_ID=${gen}" \
    "CONFIG_CHANGE_CLASS=NONE" \
    "NEXT_REQUIRED_ACTION=NONE"
  mm_status_set CONFIGURATION_READY PASS
  mm_status_set UPGRADE_READINESS PASS
  mm_status_set READINESS_RESULT PASS
  mm_status_set HTTP_DISTRIBUTION ENABLED
  mm_status_set HTTP_CONFIGURATION_READY PASS
  mm_status_set DOWNLOAD_PREPARE_RESULT PASS
  mm_status_set CLIENT_COMMANDS_MODE "${PREPARATION_MODE:-FULL}"
  mm_status_set READINESS_CONFIG_FINGERPRINT "$(mm_config_fingerprint)"
}

load_conf() {
  # shellcheck disable=SC1090
  set -a; source "$MM_CONFIG_FILE"; set +a
}

echo "=== config clear + scoped invalidation ==="

# --- C01 clear all workers ---
PREPARATION_MODE=PHASE2_ONLY
PHASE2_TARGET_VERSION=6.6.0
TARGET_DP_VERSION=6.6.0
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
ACPS_USERNAME=fixture
ACPS_PASSWORD=fixture-secret
DL_WORKER_IPS=192.0.2.21,192.0.2.22
DA_WORKER_IPS=192.0.2.31
WORKER_SSH_PASSWORD='Clu$ter!Pass'
mm_save_gui_config_full >/dev/null
load_conf
expect "C01a seeded workers present" test -n "${DL_WORKER_IPS}" -a -n "${DA_WORKER_IPS}" -a -n "${WORKER_SSH_PASSWORD}"

DL_WORKER_IPS=""
DA_WORKER_IPS=""
WORKER_SSH_PASSWORD=""
mm_save_gui_config_full >/dev/null
unset DL_WORKER_IPS DA_WORKER_IPS WORKER_SSH_PASSWORD
mm_load_gui_config
expect "C01 clear all remains empty" \
  test -z "${DL_WORKER_IPS}" -a -z "${DA_WORKER_IPS}" -a -z "${WORKER_SSH_PASSWORD}"

# --- C02 clear DL only ---
DL_WORKER_IPS=192.0.2.21
DA_WORKER_IPS=192.0.2.31
WORKER_SSH_PASSWORD='Clu$ter!Pass'
mm_save_gui_config_full >/dev/null
DL_WORKER_IPS=""
mm_save_gui_config_full >/dev/null
mm_load_gui_config
expect "C02 DL cleared DA retained" \
  test -z "${DL_WORKER_IPS}" -a "${DA_WORKER_IPS}" = "192.0.2.31"

# --- C03 clear DA only ---
DL_WORKER_IPS=192.0.2.21
DA_WORKER_IPS=192.0.2.31
WORKER_SSH_PASSWORD='Clu$ter!Pass'
mm_save_gui_config_full >/dev/null
DA_WORKER_IPS=""
mm_save_gui_config_full >/dev/null
mm_load_gui_config
expect "C03 DA cleared DL retained" \
  test "${DL_WORKER_IPS}" = "192.0.2.21" -a -z "${DA_WORKER_IPS}"

# --- C04 clear password with no workers ---
DL_WORKER_IPS=""
DA_WORKER_IPS=""
WORKER_SSH_PASSWORD='temp'
mm_save_gui_config_full >/dev/null
WORKER_SSH_PASSWORD=""
mm_save_gui_config_full >/dev/null
mm_load_gui_config
expect "C04 password cleared for AIO" test -z "${WORKER_SSH_PASSWORD}"

# --- C05 worker IP + empty password rejected at validation helper ---
expect "C05 password required with workers" \
  bash -c 'source "'"$ROOT"'/scripts/lib/mirror_manager_common.sh"; ! mm_validate_worker_ssh_password "" "192.0.2.21"'

# --- C06 cancel edit: in-memory change without save leaves disk ---
DL_WORKER_IPS=192.0.2.21
DA_WORKER_IPS=""
WORKER_SSH_PASSWORD='KeepMe'
mm_save_gui_config_full >/dev/null
DL_WORKER_IPS=""
# Cancel = do not call save; reload from disk.
mm_load_gui_config
expect "C06 cancel preserves disk DL" test "${DL_WORKER_IPS}" = "192.0.2.21"

# --- C07 special-char password roundtrip; no secret in workflow/status ---
DL_WORKER_IPS=192.0.2.21
DA_WORKER_IPS=""
WORKER_SSH_PASSWORD='p$ss"wo'\''rd`!'
mm_save_gui_config_full >/dev/null
mm_load_gui_config
expect "C07 special password roundtrip" test "${WORKER_SSH_PASSWORD}" = 'p$ss"wo'\''rd`!'
if grep -F 'p$ss' "$MM_WORKFLOW_FILE" "$MM_STATUS_FILE" 2>/dev/null; then
  fail "C07 password leaked into workflow/status"
else
  pass "C07 password absent from workflow/status"
fi

# --- merge must not wipe unrelated fields ---
ACPS_USERNAME=fixture
ACPS_PASSWORD=fixture-secret
DL_WORKER_IPS=192.0.2.21
DA_WORKER_IPS=192.0.2.31
WORKER_SSH_PASSWORD='KeepCluster'
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
mm_save_gui_config_full >/dev/null
ACPS_USERNAME=""
ACPS_PASSWORD=""
DL_WORKER_IPS=""
DA_WORKER_IPS=""
WORKER_SSH_PASSWORD=""
MIRROR_HTTP_URL=http://192.0.2.10
mm_merge_gui_config >/dev/null
mm_load_gui_config
expect "merge preserves ACPS username" test "${ACPS_USERNAME}" = "fixture"
expect "merge preserves DL workers" test "${DL_WORKER_IPS}" = "192.0.2.21"

# --- I01 no-op save preserves generations ---
PREPARATION_MODE=PHASE2_ONLY
ACPS_USERNAME=fixture
ACPS_PASSWORD=fixture-secret
DL_WORKER_IPS=""
DA_WORKER_IPS=""
WORKER_SSH_PASSWORD=""
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
mm_save_gui_config_full >/dev/null
seed_ready_workflow COMMANDS_GENERATED
os_before="$(mm_wf_get OS_CORE_GENERATION_ID)"
p2_before="$(mm_wf_get PHASE2_GENERATION_ID)"
client_before="$(mm_wf_get CLIENT_SET_GENERATION_ID)"
ready_before="$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)"
cmd_before="$(mm_wf_get COMMAND_FILE_GENERATION_ID)"
state_before="$(mm_wf_state)"
mm_save_gui_config_full >/dev/null
mm_record_config_validated
expect "I01 state unchanged" test "$(mm_wf_state)" = "$state_before"
expect "I01 OS gen preserved" test "$(mm_wf_get OS_CORE_GENERATION_ID)" = "$os_before"
expect "I01 Phase2 gen preserved" test "$(mm_wf_get PHASE2_GENERATION_ID)" = "$p2_before"
expect "I01 client gen preserved" test "$(mm_wf_get CLIENT_SET_GENERATION_ID)" = "$client_before"
expect "I01 readiness gen preserved" test "$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)" = "$ready_before"
expect "I01 command gen preserved" test "$(mm_wf_get COMMAND_FILE_GENERATION_ID)" = "$cmd_before"
expect "I01 change class NONE" test "$(mm_wf_get CONFIG_CHANGE_CLASS)" = "NONE"
expect "I01 next action NONE" test "$(mm_wf_get NEXT_REQUIRED_ACTION)" = "NONE"

# --- I02 atomic rewrite identical config: semantic readiness fingerprint stable ---
fp1="$(mm_config_fingerprint)"
# Force inode/mtime change via rewrite of identical content.
mm_save_gui_config_full >/dev/null
fp2="$(mm_config_fingerprint)"
expect "I02 semantic fingerprint stable across rewrite" test "$fp1" = "$fp2"
phys1="$(mm_config_file_fingerprint || true)"
# physical may change; ensure readiness identity helper ignores it
expect "I02 readiness identity matches after rewrite" mm_wf_readiness_identity_matches

# --- I03 worker IP only ---
seed_ready_workflow COMMANDS_GENERATED
DL_WORKER_IPS=192.0.2.21
WORKER_SSH_PASSWORD='Clu$ter!Pass'
mm_save_gui_config_full >/dev/null
expect "I03 class COMMAND_ROUTING" test "$(mm_wf_get CONFIG_CHANGE_CLASS)" = "COMMAND_ROUTING"
expect "I03 state demoted to READINESS_VERIFIED" test "$(mm_wf_state)" = "READINESS_VERIFIED"
expect "I03 OS preserved" test "$(mm_wf_get OS_CORE_GENERATION_ID)" = "os-gen-ready-1"
expect "I03 Phase2 preserved" test "$(mm_wf_get PHASE2_GENERATION_ID)" = "p2-gen-ready-1"
expect "I03 client preserved" test "$(mm_wf_get CLIENT_SET_GENERATION_ID)" = "gen-ready-1"
expect "I03 readiness preserved" test "$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)" = "gen-ready-1"
expect "I03 commands cleared" test -z "$(mm_wf_get COMMAND_FILE_GENERATION_ID)"
expect "I03 next=Regenerate Client Commands" \
  test "$(mm_wf_get NEXT_REQUIRED_ACTION)" = "Regenerate Client Commands"

# --- I04 worker password only ---
DL_WORKER_IPS=192.0.2.21
WORKER_SSH_PASSWORD='Clu$ter!Pass'
mm_save_gui_config_full >/dev/null
seed_ready_workflow COMMANDS_GENERATED
WORKER_SSH_PASSWORD='NewPass!99'
mm_save_gui_config_full >/dev/null
expect "I04 class COMMAND_ROUTING" test "$(mm_wf_get CONFIG_CHANGE_CLASS)" = "COMMAND_ROUTING"
expect "I04 readiness preserved" test "$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)" = "gen-ready-1"
expect "I04 commands cleared" test -z "$(mm_wf_get COMMAND_FILE_GENERATION_ID)"

# --- I05 cluster -> single ---
DL_WORKER_IPS=192.0.2.21
DA_WORKER_IPS=192.0.2.31
WORKER_SSH_PASSWORD='Clu$ter!Pass'
mm_save_gui_config_full >/dev/null
seed_ready_workflow COMMANDS_GENERATED
# Build prior command file with worker flags then clear.
LIB="$TMP/installer-lib.sh"
awk -v sd="$ROOT/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$ROOT/scripts/install-dp-upgrade-mirror.sh" >"$LIB"
# shellcheck disable=SC1090
source "$LIB"
cmd_file="$(mm_client_commands_file)"
gui_build_client_commands "$MIRROR_HTTP_URL" cluster "192.0.2.21" "192.0.2.31" 'Clu$ter!Pass' >"$cmd_file"
grep -q -- '--worker-ips' "$cmd_file" || fail "I05 setup cluster commands"
DL_WORKER_IPS=""
DA_WORKER_IPS=""
WORKER_SSH_PASSWORD=""
mm_save_gui_config_full >/dev/null
expect "I05 class COMMAND_ROUTING" test "$(mm_wf_get CONFIG_CHANGE_CLASS)" = "COMMAND_ROUTING"
expect "I05 readiness preserved" test "$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)" = "gen-ready-1"
expect "I05 prior command file removed" test ! -f "$cmd_file"
# Regenerate AIO
gui_build_client_commands "$MIRROR_HTTP_URL" single "" "" "" >"$cmd_file"
if grep -E -- '--worker-ips|--worker-password' "$cmd_file"; then
  fail "I05/G01 AIO command still has worker flags"
else
  pass "I05/G01 AIO command has no worker flags"
fi
grep -q 'bringup_py3_dp_after_os_upgrade.sh --version 6.6.0 --skip-download$' "$cmd_file" \
  || grep -q 'bringup_py3_dp_after_os_upgrade.sh --version 6.6.0 --skip-download' "$cmd_file" \
  || fail "I05 AIO bringup line missing"
pass "I05 AIO bringup line present"

# --- I06 single -> cluster ---
DL_WORKER_IPS=""
DA_WORKER_IPS=""
WORKER_SSH_PASSWORD=""
mm_save_gui_config_full >/dev/null
seed_ready_workflow COMMANDS_GENERATED
DL_WORKER_IPS=192.0.2.21
WORKER_SSH_PASSWORD='Clu$ter!Pass'
mm_save_gui_config_full >/dev/null
expect "I06 class COMMAND_ROUTING" test "$(mm_wf_get CONFIG_CHANGE_CLASS)" = "COMMAND_ROUTING"
gui_build_client_commands "$MIRROR_HTTP_URL" cluster "192.0.2.21" "" 'Clu$ter!Pass' >"$cmd_file"
grep -q -- '--worker-ips' "$cmd_file" || fail "G02 --worker-ips missing"
grep -Fq '192.0.2.21' "$cmd_file" || fail "G02 DL worker ips missing"
grep -q -- '--worker-password' "$cmd_file" || fail "G02 worker password missing"
pass "G02 DL master worker command correct"

# --- I07 ACPS credential only ---
ACPS_USERNAME=fixture
ACPS_PASSWORD=fixture-secret
DL_WORKER_IPS=""
DA_WORKER_IPS=""
WORKER_SSH_PASSWORD=""
mm_save_gui_config_full >/dev/null
seed_ready_workflow COMMANDS_GENERATED
mm_status_set ACPS_CONNECTION PASS
ACPS_PASSWORD='new-acps-secret'
mm_save_gui_config_full >/dev/null
expect "I07 class AUTH_CREDENTIAL" test "$(mm_wf_get CONFIG_CHANGE_CLASS)" = "AUTH_CREDENTIAL"
expect "I07 readiness preserved" test "$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)" = "gen-ready-1"
expect "I07 client preserved" test "$(mm_wf_get CLIENT_SET_GENERATION_ID)" = "gen-ready-1"
expect "I07 commands preserved" test "$(mm_wf_get COMMAND_FILE_GENERATION_ID)" = "gen-ready-1"
expect "I07 ACPS status cleared" test -z "$(mm_status_get ACPS_CONNECTION)"
expect "I07 next NONE" test "$(mm_wf_get NEXT_REQUIRED_ACTION)" = "NONE"

# --- I08 mirror IP change ---
ACPS_PASSWORD=fixture-secret
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
mm_save_gui_config_full >/dev/null
seed_ready_workflow COMMANDS_GENERATED
MIRROR_SERVER_IP=192.0.2.20
MIRROR_HTTP_URL=http://192.0.2.20
mm_save_gui_config_full >/dev/null
expect "I08 class PUBLICATION_ENDPOINT" test "$(mm_wf_get CONFIG_CHANGE_CLASS)" = "PUBLICATION_ENDPOINT"
expect "I08 demote PREPARED" test "$(mm_wf_state)" = "PREPARED"
expect "I08 OS preserved" test "$(mm_wf_get OS_CORE_GENERATION_ID)" = "os-gen-ready-1"
expect "I08 Phase2 preserved" test "$(mm_wf_get PHASE2_GENERATION_ID)" = "p2-gen-ready-1"
expect "I08 client cleared" test -z "$(mm_wf_get CLIENT_SET_GENERATION_ID)"
expect "I08 readiness cleared" test -z "$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)"

# --- I09 FULL -> PHASE2_ONLY ---
PREPARATION_MODE=FULL
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
mm_save_gui_config_full >/dev/null
seed_ready_workflow COMMANDS_GENERATED
PREPARATION_MODE=PHASE2_ONLY
mm_save_gui_config_full >/dev/null
expect "I09 class PREPARE_INPUT" test "$(mm_wf_get CONFIG_CHANGE_CLASS)" = "PREPARE_INPUT"
expect "I09 demote CONFIGURED" test "$(mm_wf_state)" = "CONFIGURED"
expect "I09 next Download and Prepare" \
  test "$(mm_wf_get NEXT_REQUIRED_ACTION)" = "Download and Prepare"

# --- I10 PHASE2_ONLY -> FULL ---
PREPARATION_MODE=PHASE2_ONLY
mm_save_gui_config_full >/dev/null
seed_ready_workflow COMMANDS_GENERATED
PREPARATION_MODE=FULL
mm_save_gui_config_full >/dev/null
expect "I10 class PREPARE_INPUT" test "$(mm_wf_get CONFIG_CHANGE_CLASS)" = "PREPARE_INPUT"
expect "I10 demote CONFIGURED" test "$(mm_wf_state)" = "CONFIGURED"

# --- I11/I12 command file + dashboard markers ---
PREPARATION_MODE=PHASE2_ONLY
DL_WORKER_IPS=192.0.2.21
WORKER_SSH_PASSWORD='Clu$ter!Pass'
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
mm_save_gui_config_full >/dev/null
seed_ready_workflow COMMANDS_GENERATED
gui_build_client_commands "$MIRROR_HTTP_URL" cluster "192.0.2.21" "" 'Clu$ter!Pass' >"$cmd_file"
mm_wf_set_many "COMMAND_FILE_GENERATION_ID=gen-ready-1" "CONFIG_COMMAND_SHA256=$(mm_wf_command_identity_sha256)"
mm_status_set CLIENT_COMMANDS_MODE PHASE2_ONLY
# Change routing → commands must be stale / file removed
DL_WORKER_IPS=192.0.2.22
mm_save_gui_config_full >/dev/null
if mm_client_commands_stale; then
  pass "I11 command file not current after routing change"
else
  fail "I11 command file still considered fresh after routing change"
fi
expect "I12 CONFIG_CHANGE_CLASS set" test -n "$(mm_wf_get CONFIG_CHANGE_CLASS)"
expect "I12 NEXT_REQUIRED_ACTION set" test -n "$(mm_wf_get NEXT_REQUIRED_ACTION)"
msg="$(mm_wf_operator_save_message)"
echo "$msg" | grep -q 'Client commands changed' || fail "I12 operator message missing command guidance"
pass "I12 operator save message accurate"

# --- G03/G04 DA and DL+DA ---
gui_build_client_commands "$MIRROR_HTTP_URL" cluster "" "192.0.2.31" 'Clu$ter!Pass' >"$cmd_file"
grep -q -- '--worker-ips' "$cmd_file" || fail "G03 --worker-ips missing"
grep -Fq '192.0.2.31' "$cmd_file" || fail "G03 DA worker ips"
pass "G03 DA master worker command correct"
gui_build_client_commands "$MIRROR_HTTP_URL" cluster "192.0.2.21" "192.0.2.31" 'Clu$ter!Pass' >"$cmd_file"
grep -Fq '192.0.2.21' "$cmd_file" || fail "G04 DL list"
grep -Fq '192.0.2.31' "$cmd_file" || fail "G04 DA list"
pass "G04 DL+DA independent lists"

# --- G05/G06 special chars: flag present, plaintext absent from command file/status ---
special='a b$c`d!"e'
gui_build_client_commands "$MIRROR_HTTP_URL" cluster "192.0.2.21" "" "$special" >"$cmd_file"
grep -q -- '--worker-password' "$cmd_file" || fail "G05 password flag missing"
if grep -Fqs -- "$special" "$cmd_file"; then
  fail "G05 plaintext special-char password embedded in command file"
else
  pass "G05 special-char password absent from command file"
fi
if grep -Fqs -- "$special" "$MM_STATUS_FILE" "$MM_WORKFLOW_FILE" 2>/dev/null; then
  fail "G06 password leaked to status/workflow"
else
  pass "G06 password absent from status/workflow"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "TEST_CONFIG_CLEAR_AND_SCOPED_INVALIDATION=FAIL"
  exit 1
fi
echo "TEST_CONFIG_CLEAR_AND_SCOPED_INVALIDATION=PASS"
