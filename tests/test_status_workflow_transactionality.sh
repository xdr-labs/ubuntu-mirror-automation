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

[[ "$FAIL" -eq 0 ]]
echo "ALL STATUS WORKFLOW TRANSACTIONALITY TESTS PASSED"
