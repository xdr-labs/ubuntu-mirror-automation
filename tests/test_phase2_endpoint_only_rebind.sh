#!/usr/bin/env bash
# Endpoint-only AMI/site rebind must preserve heavy Phase 2 release bytes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/tests/lib/client_finalization_fixture.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
HTTP_PID=""
cleanup() {
  [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "=== test_phase2_endpoint_only_rebind ==="
client_fixture_build_selective "$WORKDIR"
client_fixture_install_runtime "$ROOT" "$WORKDIR"

export MM_PROJECT_ROOT="$ROOT"
export MM_CONFIG_DIR="${WORKDIR}/etc-ubuntu-mirror"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.status"
export MM_WORKFLOW_FILE="${MM_CONFIG_DIR}/dp-upgrade-workflow.state"
export MM_LOG_DIR="${WORKDIR}/logs"
export MM_STATE_ROOT="${WORKDIR}/state"
export MM_MIRROR_ROOT="$CLIENT_FIXTURE_MIRROR_ROOT"
export MM_SELECTIVE_ROOT="$CLIENT_FIXTURE_SELECTIVE"
export MM_CLIENT_ROOT="$CLIENT_FIXTURE_CLIENT_ROOT"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export LOCAL_CLIENT_SIGNING_DIR="$CLIENT_FIXTURE_SIGNING_DIR"
export MM_SKIP_ROOT_CHECK=1
export MM_HERMETIC_TEST_MODE=1
export SKIP_MIRROR_HOST_VALIDATE=1
export CLIENT_BUILD_PIN_URL_ONLY=1
export PREPARATION_MODE=PHASE2_ONLY
export TARGET_DP_VERSION=6.6.0
export PHASE2_TARGET_VERSION=6.6.0
mkdir -p "$MM_CONFIG_DIR" "$MM_LOG_DIR" "$MM_STATE_ROOT" "$MM_CACHE_ROOT"
: >"$MM_STATUS_FILE"

source "${ROOT}/scripts/lib/mirror_manager_common.sh"
source "${ROOT}/scripts/lib/mirror_workflow_state.sh"
source "${ROOT}/scripts/lib/mirror_install_engine.sh"
source "${ROOT}/scripts/lib/local_client_signing.sh"

INSTALLER_LIB="${WORKDIR}/installer-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"/ { next }
  { print }
' "${ROOT}/scripts/install-dp-upgrade-mirror.sh" >"$INSTALLER_LIB"
source "$INSTALLER_LIB"
save_config() {
  local ip="$1"
  PREPARATION_MODE=PHASE2_ONLY
  MIRROR_SERVER_IP="$ip"
  MIRROR_HTTP_URL="http://$ip"
  ACPS_USERNAME=fixture
  ACPS_PASSWORD=fixture-secret
  WORKER_SSH_PASSWORD=
  DL_WORKER_IPS=
  DA_WORKER_IPS=
  PHASE2_TARGET_VERSION=6.6.0
  TARGET_DP_VERSION=6.6.0
  mm_save_gui_config_full >/dev/null
}

old_ip=192.0.2.99
new_ip=192.0.2.100
save_config "$old_ip"
MIRROR_HTTP_URL="http://$old_ip"
RESOLVED_MIRROR_BASE_URL="$MIRROR_HTTP_URL"
RESOLVED_MIRROR_HOST_IPV4="$old_ip"

engine_finalize_local_client_set >"${WORKDIR}/initial-finalize.log" 2>&1   || { cat "${WORKDIR}/initial-finalize.log"; exit 1; }

mm_wf_set_many   "OS_CORE_GENERATION_ID=os-heavy-fixed"   "PHASE2_GENERATION_ID=phase2-heavy-fixed"   "WORKFLOW_STATE=COMMANDS_GENERATED"   "HTTP_PUBLICATION_GENERATION_ID=$(mm_wf_get CLIENT_SET_GENERATION_ID)"   "READINESS_VERIFIED_GENERATION_ID=$(mm_wf_get CLIENT_SET_GENERATION_ID)"   "COMMAND_FILE_GENERATION_ID=$(mm_wf_get CLIENT_SET_GENERATION_ID)"
OS_BEFORE="$(mm_wf_get OS_CORE_GENERATION_ID)"
P2_BEFORE="$(mm_wf_get PHASE2_GENERATION_ID)"
HEAVY_BEFORE="$(
  find "${MM_DP_PHASE2_ROOT}/6.6.0" -type f -print0     | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
)"

save_config "$new_ip"
MIRROR_HTTP_URL="http://$new_ip"
RESOLVED_MIRROR_BASE_URL="$MIRROR_HTTP_URL"
RESOLVED_MIRROR_HOST_IPV4="$new_ip"

[[ "$(mm_wf_get CONFIG_CHANGE_CLASS)" == "PUBLICATION_ENDPOINT" ]]   && pass "endpoint-only classified PUBLICATION_ENDPOINT"   || fail "class=$(mm_wf_get CONFIG_CHANGE_CLASS)"
[[ "$(mm_wf_get NEXT_REQUIRED_ACTION)" == "Enable HTTP Distribution" ]]   && pass "next action is Enable HTTP Distribution"   || fail "next=$(mm_wf_get NEXT_REQUIRED_ACTION)"
[[ "$(mm_wf_get OS_CORE_GENERATION_ID)" == "$OS_BEFORE"    && "$(mm_wf_get PHASE2_GENERATION_ID)" == "$P2_BEFORE" ]]   && pass "heavy generation IDs preserved after IP change"   || fail "heavy generation IDs changed after IP change"

# Exercise the real endpoint-only mutation path. Dry-run is intentionally
# read-only and therefore cannot prove that wrappers are rebound. Hermetic
# mode skips only the host nginx apply after layout/publication validation.
export MM_SKIP_NGINX_APPLY=1
export MM_SKIP_HTTP_VALIDATE=1
export MM_SKIP_BUNDLE_SHA256=1
export MM_LOCK_FILE="${WORKDIR}/publication.lock"
set +e
( engine_enable_http_distribution ) >"${WORKDIR}/enable-http.log" 2>&1
enable_http_rc=$?
set -e
if [[ "$enable_http_rc" -eq 0 ]]; then
  pass "Menu 3 rebind succeeds without Menu 2"
else
  fail "Menu 3 rebind failed rc=$enable_http_rc"
  tail -60 "${WORKDIR}/enable-http.log"
fi
unset MM_SKIP_NGINX_APPLY
grep -q 'HEAVY_ARTIFACT_DOWNLOAD_REQUIRED=NO' "${WORKDIR}/enable-http.log"   && pass "Menu 3 explicitly avoids heavy download"   || fail "missing no-heavy-download evidence"
grep -Fq "MIRROR='http://${new_ip}'" "${MM_CLIENT_ROOT}/upgrade-phase2.sh"   && pass "wrapper rebound to new endpoint"   || fail "wrapper endpoint pin not updated"
mm_phase2_wrapper_trust_anchors_match "$MM_CLIENT_ROOT" "$MM_DP_PHASE2_ROOT" 6.6.0   && pass "local B/P/H anchors match immutable release"   || fail "local B/P/H trust mismatch"

HEAVY_AFTER="$(
  find "${MM_DP_PHASE2_ROOT}/6.6.0" -type f -print0     | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
)"
[[ "$HEAVY_AFTER" == "$HEAVY_BEFORE" ]]   && pass "heavy Phase 2 bytes unchanged"   || fail "heavy Phase 2 bytes mutated"
[[ "$(mm_wf_get OS_CORE_GENERATION_ID)" == "$OS_BEFORE"    && "$(mm_wf_get PHASE2_GENERATION_ID)" == "$P2_BEFORE" ]]   && pass "heavy generation IDs unchanged after Menu 3"   || fail "Menu 3 mutated heavy generation IDs"

HTTP_PORT="$(python3 - <<'PY'
import socket
s=socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$MM_MIRROR_ROOT"   >"${WORKDIR}/http.log" 2>&1 &
HTTP_PID=$!
sleep 0.3
export MM_VERIFY_HTTP_BASE="http://127.0.0.1:${HTTP_PORT}"
export MM_VERIFY_ADVERTISED_HTTP_BASE="$MM_VERIFY_HTTP_BASE"
export MM_SKIP_HTTP_VALIDATE=0
export MM_SKIP_BUNDLE_SHA256=1
# Python http.server does not implement the production nginx deny rules.
# Sensitive-path policy is covered by dedicated nginx/publication tests; this
# regression exercises endpoint republish plus the positive HTTP trust path.
engine_http_probe_must_not_be_public() { printf '404\n'; return 0; }

engine_validate_http_layout >"${WORKDIR}/http-readiness.log" 2>&1   && pass "Menu 4 path validates HTTP B/P/H binding"   || { fail "HTTP readiness path failed"; tail -80 "${WORKDIR}/http-readiness.log"; }

for kv in   CONFIGURATION_READY=PASS ACPS_CONNECTION=PASS ACPS_PHASE2_DOWNLOADED=PASS   ACPS_CHECKSUM=PASS UPSTREAM_BRINGUP_PROVENANCE=PASS UPSTREAM_BRINGUP_DRIFT=NO   PATCHED_BRINGUP_APPLIED=YES PHASE2_BUNDLE_ENTRY_COUNT=9   PHASE2_BUNDLE_CHECKSUM=PASS CLIENT_FILES_READY=PASS HTTP_CONFIGURATION_READY=PASS
do
  mm_status_set "${kv%%=*}" "${kv#*=}"
done
engine_compute_readiness >"${WORKDIR}/readiness.log" 2>&1   && pass "UPGRADE_READINESS=PASS after endpoint rebind"   || { fail "readiness computation failed"; cat "${WORKDIR}/readiness.log"; }

CMD_FILE="${MM_LOG_DIR}/dp-client-upgrade-commands.txt"
gui_build_client_commands "http://$new_ip" single "" "" "" >"$CMD_FILE"
mm_wf_validate_command_file_content "$CMD_FILE" PHASE2_ONLY >"${WORKDIR}/menu7.val"
grep -q 'COMMAND_FILE_BUILD=PASS' "${WORKDIR}/menu7.val"   && grep -q 'COMMAND_FILE_BRINGUP_EXECUTABLE_COUNT=1' "${WORKDIR}/menu7.val"   && ! grep -qE 'UBUNTU 16.04|dp-offline-upgrade-xenial' "$CMD_FILE"   && pass "Menu 7 emits usable Phase 2-only command"   || fail "Menu 7 command validation failed"

# Exercise the actual Menu 7 entry path, not only the command formatter. HTTP
# liveness was already proven above against the local server; stub only the
# nginx-specific completion helper so this case isolates PHASE2_ONLY provenance
# and actual gui_client_instructions preflight/publication behavior.
eval "$(declare -f mm_http_completed | sed '1s/mm_http_completed/_endpoint_real_mm_http_completed/')"
mm_http_completed() { return 0; }
MENU7_ACTUAL_TRACE="${WORKDIR}/menu7-actual.trace"
: >"$MENU7_ACTUAL_TRACE"
mm_whiptail_msg() { printf 'MSG:%s\n' "$*" >>"$MENU7_ACTUAL_TRACE"; return 0; }
mm_menu7_textbox() {
  printf 'VIEW:%s:%s\n' "$1" "$2" >>"$MENU7_ACTUAL_TRACE"
  cp -f "$2" "${WORKDIR}/menu7-actual-command.txt"
  return 0
}
rm -f "$(mm_client_commands_file)"
gui_client_instructions
unset -f mm_http_completed
eval "$(declare -f _endpoint_real_mm_http_completed | sed '1s/_endpoint_real_mm_http_completed/mm_http_completed/')"
unset -f _endpoint_real_mm_http_completed
if [[ -s "${WORKDIR}/menu7-actual-command.txt" ]] \
  && ! grep -q 'BLOCK_REASON=' "$MENU7_ACTUAL_TRACE" \
  && grep -q 'upgrade-phase2.sh' "${WORKDIR}/menu7-actual-command.txt" \
  && ! grep -qE 'UBUNTU 16.04|dp-offline-upgrade-xenial' "${WORKDIR}/menu7-actual-command.txt"; then
  pass "actual Menu 7 PHASE2_ONLY path passes canonical verifier"
else
  cat "$MENU7_ACTUAL_TRACE" >&2
  fail "actual Menu 7 PHASE2_ONLY path blocked or emitted FULL commands"
fi

kill "$HTTP_PID" 2>/dev/null || true
wait "$HTTP_PID" 2>/dev/null || true
HTTP_PID=""

# ---------------------------------------------------------------------------
# FULL mode: the same endpoint-only rebind must preserve both selective OS Core
# and Phase 2 heavy bytes. This closes the AMI/IP-change path with a genuinely
# materialized FULL selective tree, including the /ubuntu publication alias.
# ---------------------------------------------------------------------------
run_full_endpoint_rebind_case() {
  local full="${WORKDIR}/full-endpoint"
  local old=192.0.2.110 new=192.0.2.111
  local os_before os_after p2_before p2_after os_gen_before p2_gen_before

  client_fixture_build_selective "$full" >/dev/null
  client_fixture_install_runtime "$ROOT" "$full" >/dev/null

  export MM_CONFIG_DIR="${full}/etc-ubuntu-mirror"
  export MM_CONFIG_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.conf"
  export MM_STATUS_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.status"
  export MM_WORKFLOW_FILE="${MM_CONFIG_DIR}/dp-upgrade-workflow.state"
  export MM_LOG_DIR="${full}/logs"
  export MM_STATE_ROOT="${full}/state"
  export MM_MIRROR_ROOT="$CLIENT_FIXTURE_MIRROR_ROOT"
  export MM_SELECTIVE_ROOT="$CLIENT_FIXTURE_SELECTIVE"
  export MM_CLIENT_ROOT="$CLIENT_FIXTURE_CLIENT_ROOT"
  export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
  export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
  export LOCAL_CLIENT_SIGNING_DIR="$CLIENT_FIXTURE_SIGNING_DIR"
  export PREPARATION_MODE=FULL TARGET_DP_VERSION=6.6.0 PHASE2_TARGET_VERSION=6.6.0
  export MM_SKIP_ROOT_CHECK=1 MM_HERMETIC_TEST_MODE=1 SKIP_MIRROR_HOST_VALIDATE=1
  export CLIENT_BUILD_PIN_URL_ONLY=1
  export MM_LOCK_FILE="${full}/publication.lock"
  mkdir -p "$MM_CONFIG_DIR" "$MM_LOG_DIR" "$MM_STATE_ROOT" "$MM_CACHE_ROOT"
  : >"$MM_STATUS_FILE"

  # Production FULL publication exposes a stable /ubuntu alias while retaining
  # the per-hop generation tree used for provenance and client construction.
  ln -sfn hops/jammy-to-noble/ubuntu "${MM_SELECTIVE_ROOT}/ubuntu"
  mkdir -p "${MM_SELECTIVE_ROOT}/shared/offline"
  [[ -s "${MM_SELECTIVE_ROOT}/shared/offline/meta-release-lts" ]] \
    || printf 'fixture-meta-release\n' >"${MM_SELECTIVE_ROOT}/shared/offline/meta-release-lts"

  save_full_config() {
    local ip="$1"
    PREPARATION_MODE=FULL
    MIRROR_SERVER_IP="$ip"
    MIRROR_HTTP_URL="http://$ip"
    ACPS_USERNAME=fixture
    ACPS_PASSWORD=fixture-secret
    WORKER_SSH_PASSWORD=
    DL_WORKER_IPS=
    DA_WORKER_IPS=
    TARGET_DP_VERSION=6.6.0
    PHASE2_TARGET_VERSION=6.6.0
    mm_save_gui_config_full >/dev/null
  }

  save_full_config "$old"
  MIRROR_HTTP_URL="http://$old"
  RESOLVED_MIRROR_BASE_URL="$MIRROR_HTTP_URL"
  RESOLVED_MIRROR_HOST_IPV4="$old"
  engine_finalize_local_client_set >"${full}/initial-finalize.log" 2>&1 \
    || { cat "${full}/initial-finalize.log"; return 1; }

  mm_wf_set_many \
    "OS_CORE_GENERATION_ID=os-full-heavy-fixed" \
    "PHASE2_GENERATION_ID=phase2-full-heavy-fixed" \
    "WORKFLOW_STATE=COMMANDS_GENERATED" \
    "HTTP_PUBLICATION_GENERATION_ID=$(mm_wf_get CLIENT_SET_GENERATION_ID)" \
    "READINESS_VERIFIED_GENERATION_ID=$(mm_wf_get CLIENT_SET_GENERATION_ID)" \
    "COMMAND_FILE_GENERATION_ID=$(mm_wf_get CLIENT_SET_GENERATION_ID)"
  os_gen_before="$(mm_wf_get OS_CORE_GENERATION_ID)"
  p2_gen_before="$(mm_wf_get PHASE2_GENERATION_ID)"
  os_before="$(find -L "$MM_SELECTIVE_ROOT" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
  p2_before="$(find "$MM_DP_PHASE2_ROOT/6.6.0" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"

  save_full_config "$new"
  MIRROR_HTTP_URL="http://$new"
  RESOLVED_MIRROR_BASE_URL="$MIRROR_HTTP_URL"
  RESOLVED_MIRROR_HOST_IPV4="$new"
  [[ "$(mm_wf_get CONFIG_CHANGE_CLASS)" == "PUBLICATION_ENDPOINT" ]] || return 2
  [[ "$(mm_wf_get NEXT_REQUIRED_ACTION)" == "Enable HTTP Distribution" ]] || return 3
  [[ "$(mm_wf_get OS_CORE_GENERATION_ID)" == "$os_gen_before" ]] || return 4
  [[ "$(mm_wf_get PHASE2_GENERATION_ID)" == "$p2_gen_before" ]] || return 5

  export MM_SKIP_NGINX_APPLY=1 MM_SKIP_HTTP_VALIDATE=1 MM_SKIP_BUNDLE_SHA256=1
  ( engine_enable_http_distribution ) >"${full}/enable-http.log" 2>&1 \
    || { tail -100 "${full}/enable-http.log"; return 6; }
  unset MM_SKIP_NGINX_APPLY

  grep -q 'Heavy artifact download required: NO' "${full}/enable-http.log" || return 7
  grep -Fq "http://${new}" "${MM_CLIENT_ROOT}/upgrade-phase2.sh" || return 8
  mm_client_set_current_source "$MM_CLIENT_ROOT" >"${full}/current-source.log" 2>&1 \
    || { cat "${full}/current-source.log"; return 9; }
  mm_phase2_wrapper_trust_anchors_match "$MM_CLIENT_ROOT" "$MM_DP_PHASE2_ROOT" 6.6.0 || return 10

  os_after="$(find -L "$MM_SELECTIVE_ROOT" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
  p2_after="$(find "$MM_DP_PHASE2_ROOT/6.6.0" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
  [[ "$os_after" == "$os_before" ]] || return 11
  [[ "$p2_after" == "$p2_before" ]] || return 12
  [[ "$(mm_wf_get OS_CORE_GENERATION_ID)" == "$os_gen_before" ]] || return 13
  [[ "$(mm_wf_get PHASE2_GENERATION_ID)" == "$p2_gen_before" ]] || return 14

  MM_SKIP_HTTP_VALIDATE=1 MM_SKIP_BUNDLE_SHA256=1 engine_validate_http_layout \
    >"${full}/layout.log" 2>&1 || { tail -100 "${full}/layout.log"; return 15; }
  echo "FULL_ENDPOINT_ONLY_REBIND=PASS"
  return 0
}

if ( run_full_endpoint_rebind_case ); then
  pass "FULL endpoint-only rebind preserves OS Core + Phase 2 heavy generations"
else
  full_rc=$?
  fail "FULL endpoint-only rebind failed rc=${full_rc}"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "PHASE2_ENDPOINT_ONLY_REBIND=PASS"
  exit 0
fi
echo "PHASE2_ENDPOINT_ONLY_REBIND=FAIL"
exit 1
