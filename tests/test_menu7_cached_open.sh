#!/usr/bin/env bash
# Menu 7 cached-open path: already-current command file must not trigger
# HTTP smoke, heavy hashing, client rebuild, or command rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
WF="${ROOT}/scripts/lib/mirror_workflow_state.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_PROJECT_ROOT="$ROOT"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_HERMETIC_TEST_MODE=1
export MM_LOG_DIR="$TMP/logs"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$TMP/config/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$TMP/config/status"
export MM_WORKFLOW_FILE="$TMP/config/workflow.env"
export MM_CLIENT_ROOT="$TMP/client"
export SCRIPT_DIR="${ROOT}/scripts"
export PREPARATION_MODE=PHASE2_ONLY
export MIRROR_SERVER_IP=192.0.2.10
export MIRROR_HTTP_URL=http://192.0.2.10
export TARGET_DP_VERSION=6.6.0
export PHASE2_TARGET_VERSION=6.6.0
export MM_SKIP_HTTP_VALIDATE=1
mkdir -p "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$MM_CLIENT_ROOT" "$TMP/bin" "$TMP/counts"

: >"$MM_STATUS_FILE"
: >"$MM_WORKFLOW_FILE"

# Operation counters (deterministic contract; not wall-clock).
: >"$TMP/counts/network"
: >"$TMP/counts/heavy_hash"
: >"$TMP/counts/client_rebuild"
: >"$TMP/counts/command_rebuild"

cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo 1 >>"${COUNT_DIR}/network"
echo "000"
exit 1
EOF
chmod +x "$TMP/bin/curl"

cat >"$TMP/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
echo 1 >>"${COUNT_DIR}/heavy_hash"
exec /usr/bin/sha256sum "$@"
EOF
chmod +x "$TMP/bin/sha256sum"

export COUNT_DIR="$TMP/counts"
export PATH="$TMP/bin:/usr/bin:/bin"

LIB="$TMP/installer-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$INSTALLER" >"$LIB"
# shellcheck disable=SC1090
source "$LIB"
# shellcheck disable=SC1090
source "$COMMON"
# shellcheck disable=SC1090
source "$WF" 2>/dev/null || true

GEN="gen-menu7-cached-1"
mm_status_set CONFIGURATION_READY PASS
mm_status_set DOWNLOAD_PREPARE_RESULT PASS
mm_status_set DOWNLOAD_ARTIFACT_FINGERPRINT "fp-test"
mm_status_set HTTP_DISTRIBUTION ENABLED
mm_status_set HTTP_CONFIGURATION_READY PASS
mm_status_set UPGRADE_READINESS PASS
mm_status_set READINESS_RESULT PASS
mm_status_set READINESS_ARTIFACT_FINGERPRINT "fp-test"
mm_status_set CLIENT_COMMANDS_MODE PHASE2_ONLY

# Minimal workflow generation bindings.
{
  echo "READINESS_VERIFIED_GENERATION_ID=${GEN}"
  echo "COMMAND_FILE_GENERATION_ID=${GEN}"
  echo "CLIENT_SET_GENERATION_ID=${GEN}"
  echo "HTTP_PUBLICATION_GENERATION_ID=${GEN}"
  echo "DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2"
  echo "CONFIG_COMMAND_SHA256=deadbeef"
  echo "WORKFLOW_STATE=COMMANDS_GENERATED"
} >"$MM_WORKFLOW_FILE"

# Stub heavy helpers that Menu 7 must not need on cached open.
mm_wf_commands_preflight() { return 0; }
mm_client_commands_stale() { return 1; } # not stale
mm_menu7_command_file_generation_current() { return 0; }
mm_wf_get() {
  case "$1" in
    READINESS_VERIFIED_GENERATION_ID|COMMAND_FILE_GENERATION_ID|CLIENT_SET_GENERATION_ID|HTTP_PUBLICATION_GENERATION_ID)
      printf '%s\n' "$GEN"
      ;;
    DP_COMMAND_BLOCK_VERSION) printf 'SUBSHELL_V2\n' ;;
    CONFIG_COMMAND_SHA256) printf 'deadbeef\n' ;;
    *) printf '\n' ;;
  esac
}
engine_http_local_smoke() { echo 1 >>"$COUNT_DIR/network"; return 0; }
engine_http_advertised_smoke() { echo 1 >>"$COUNT_DIR/network"; return 0; }
gui_build_client_commands() {
  echo 1 >>"$COUNT_DIR/command_rebuild"
  echo "SHOULD_NOT_REBUILD"
}
mm_wf_atomic_publish_command_file() {
  echo 1 >>"$COUNT_DIR/command_rebuild"
  return 0
}
mm_client_set_current_source() {
  echo 1 >>"$COUNT_DIR/client_rebuild"
  return 0
}

CMD_FILE="$(mm_client_commands_file)"
cat >"$CMD_FILE" <<'EOF'
DP Client Upgrade Commands
==========================
DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2
STEP 0 — CACHED
cd /home/aella && curl -fsSLo upgrade-phase2.sh.download http://192.0.2.10/client/upgrade-phase2.sh && printf '%s  %s\n' '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' 'upgrade-phase2.sh.download' | sha256sum -c - && mv -f upgrade-phase2.sh.download upgrade-phase2.sh && bash ./upgrade-phase2.sh
EOF

# Avoid interactive viewer: stub textbox.
mm_menu7_textbox() {
  printf 'VIEWED\t%s\n' "$2" >>"$TMP/view.log"
  return 0
}
mm_whiptail_msg() { printf 'MSG\t%s\n' "$*" >>"$TMP/msg.log"; return 0; }

unset MENU7_CACHED_OPEN_PATH || true
gui_client_instructions

[[ "${MENU7_CACHED_OPEN_PATH:-}" == "PASS" ]] \
  && pass "MENU7_CACHED_OPEN_PATH=PASS" \
  || fail "MENU7_CACHED_OPEN_PATH=${MENU7_CACHED_OPEN_PATH:-UNSET}"

grep -q 'VIEWED' "$TMP/view.log" && pass "viewer invoked on cached open" \
  || fail "viewer not invoked"

NETWORK_CALL_COUNT="$(wc -l <"$TMP/counts/network" | tr -d ' ')"
HEAVY_HASH_COUNT="$(wc -l <"$TMP/counts/heavy_hash" | tr -d ' ')"
CLIENT_REBUILD_COUNT="$(wc -l <"$TMP/counts/client_rebuild" | tr -d ' ')"
COMMAND_REBUILD_COUNT="$(wc -l <"$TMP/counts/command_rebuild" | tr -d ' ')"

[[ "$NETWORK_CALL_COUNT" -eq 0 ]] && pass "NETWORK_CALL_COUNT=0" \
  || fail "NETWORK_CALL_COUNT=${NETWORK_CALL_COUNT}"
[[ "$HEAVY_HASH_COUNT" -eq 0 ]] && pass "HEAVY_HASH_COUNT=0" \
  || fail "HEAVY_HASH_COUNT=${HEAVY_HASH_COUNT}"
[[ "$CLIENT_REBUILD_COUNT" -eq 0 ]] && pass "CLIENT_REBUILD_COUNT=0" \
  || fail "CLIENT_REBUILD_COUNT=${CLIENT_REBUILD_COUNT}"
[[ "$COMMAND_REBUILD_COUNT" -eq 0 ]] && pass "COMMAND_REBUILD_COUNT=0" \
  || fail "COMMAND_REBUILD_COUNT=${COMMAND_REBUILD_COUNT}"

# Static contract: default Menu 7 path must not call smoke unless opted in.
if awk '/^gui_client_instructions\(\)/,/^}/' "$INSTALLER" | grep -q 'engine_http_local_smoke'; then
  awk '/^gui_client_instructions\(\)/,/^}/' "$INSTALLER" | grep -q 'MM_MENU7_HTTP_SMOKE' \
    && pass "HTTP smoke gated behind MM_MENU7_HTTP_SMOKE" \
    || fail "HTTP smoke not gated"
else
  pass "HTTP smoke absent from Menu 7"
fi

echo "NETWORK_CALL_COUNT=${NETWORK_CALL_COUNT}"
echo "HEAVY_HASH_COUNT=${HEAVY_HASH_COUNT}"
echo "CLIENT_REBUILD_COUNT=${CLIENT_REBUILD_COUNT}"
echo "COMMAND_REBUILD_COUNT=${COMMAND_REBUILD_COUNT}"
echo "MENU7_CACHED_OPEN_PATH=${MENU7_CACHED_OPEN_PATH}"
echo "CACHED_OPEN_REGRESSION=PASS"

if [[ "$FAIL" -ne 0 ]]; then
  echo "TEST_MENU7_CACHED_OPEN=FAIL"
  exit 1
fi
echo "TEST_MENU7_CACHED_OPEN=PASS"
exit 0
