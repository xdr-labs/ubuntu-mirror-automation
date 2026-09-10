#!/usr/bin/env bash
# Workflow/status KV getters: empty values, embedded '=', generation fail-closed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

export MM_CONFIG_DIR="$TMP/config"
export MM_WORKFLOW_FILE="$MM_CONFIG_DIR/workflow.state"
export MM_STATUS_FILE="$MM_CONFIG_DIR/status"
export MM_CONFIG_FILE="$MM_CONFIG_DIR/dp-upgrade-mirror.conf"
export MM_PROJECT_ROOT="$ROOT"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_HERMETIC_TEST_MODE=1
mkdir -p "$MM_CONFIG_DIR"
: >"$MM_STATUS_FILE"

# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "${ROOT}/scripts/lib/mirror_manager_common.sh"

expect_eq() {
  local label="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$label"
  else
    fail "$label got=[$got] want=[$want]"
  fi
}

cat >"$MM_WORKFLOW_FILE" <<'EOF'
WORKFLOW_STATE=HTTP_ENABLED
CLIENT_SET_GENERATION_ID=
HTTP_PUBLICATION_GENERATION_ID=
READINESS_VERIFIED_GENERATION_ID=
COMMAND_FILE_GENERATION_ID=
SOME_KEY=a=b=c
VALUE_KEY=value
DUP=first
DUP=second
EOF

expect_eq "wf KEY= -> empty" "$(mm_wf_get CLIENT_SET_GENERATION_ID)" ""
expect_eq "wf KEY=value" "$(mm_wf_get VALUE_KEY)" "value"
expect_eq "wf KEY=a=b=c" "$(mm_wf_get SOME_KEY)" "a=b=c"
expect_eq "wf unknown key" "$(mm_wf_get NO_SUCH_KEY)" ""
expect_eq "wf first duplicate key" "$(mm_wf_get DUP)" "first"
expect_eq "wf HTTP_PUBLICATION_GENERATION_ID empty" "$(mm_wf_get HTTP_PUBLICATION_GENERATION_ID)" ""
expect_eq "wf READINESS_VERIFIED_GENERATION_ID empty" "$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)" ""
expect_eq "wf COMMAND_FILE_GENERATION_ID empty" "$(mm_wf_get COMMAND_FILE_GENERATION_ID)" ""

cat >"$MM_STATUS_FILE" <<'EOF'
HTTP_DISTRIBUTION=DISABLED
CLIENT_SET_GENERATION_ID=
HTTP_PUBLICATION_GENERATION_ID=
READINESS_VERIFIED_GENERATION_ID=
COMMAND_FILE_GENERATION_ID=
SOME_KEY=a=b=c
VALUE_KEY=value
DUP=first
DUP=second
UPGRADE_READINESS=FAIL
EOF

expect_eq "status KEY= -> empty" "$(mm_status_get CLIENT_SET_GENERATION_ID)" ""
expect_eq "status KEY=value" "$(mm_status_get VALUE_KEY)" "value"
expect_eq "status KEY=a=b=c" "$(mm_status_get SOME_KEY)" "a=b=c"
expect_eq "status unknown key" "$(mm_status_get NO_SUCH_KEY)" ""
expect_eq "status first duplicate key" "$(mm_status_get DUP)" "first"

got_empty="$(mm_wf_get CLIENT_SET_GENERATION_ID)"
if [[ -z "$got_empty" ]]; then
  pass "empty generation is genuinely empty for [[ -z ]]"
else
  fail "empty generation treated as nonempty got=[$got_empty]"
fi

# Empty publication generation must not mark readiness PASS.
set +e
mm_wf_mark_readiness_verified >/dev/null 2>&1
empty_ready_rc=$?
set -e
[[ "$empty_ready_rc" -ne 0 ]] && pass "empty pub gen readiness mark fails closed" \
  || fail "empty pub gen readiness mark unexpectedly succeeded"
expect_eq "empty pub gen does not set WORKFLOW_STATE=READINESS_VERIFIED" \
  "$(mm_wf_get WORKFLOW_STATE)" "HTTP_ENABLED"
expect_eq "empty pub gen leaves READINESS_VERIFIED_GENERATION_ID empty" \
  "$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)" ""
expect_eq "empty pub gen does not set UPGRADE_READINESS=PASS" \
  "$(mm_status_get UPGRADE_READINESS)" "FAIL"

if mm_wf_readiness_generation_current; then
  fail "readiness generation current passed on empty generations"
else
  pass "readiness generation current fail-closed on empty generations"
fi

if mm_wf_mark_commands_generated >/dev/null 2>&1; then
  fail "commands generated succeeded on empty readiness generation"
else
  pass "command generation fail-closed on empty readiness generation"
fi
expect_eq "COMMAND_FILE_GENERATION_ID stays empty" "$(mm_wf_get COMMAND_FILE_GENERATION_ID)" ""

# HTTP readiness generation: empty HTTP_PUBLICATION_GENERATION_ID cannot match a real ready gen.
mm_wf_set_many \
  "WORKFLOW_STATE=READINESS_VERIFIED" \
  "CLIENT_SET_GENERATION_ID=" \
  "HTTP_PUBLICATION_GENERATION_ID=" \
  "READINESS_VERIFIED_GENERATION_ID=" \
  "COMMAND_FILE_GENERATION_ID="
mm_status_set HTTP_DISTRIBUTION ENABLED
mm_status_set UPGRADE_READINESS PASS
if mm_wf_readiness_generation_current; then
  fail "HTTP/readiness generation PASS with empty generation values"
else
  pass "empty generation values cannot make readiness generation PASS"
fi

# Stale KEY= string must never be usable as a generation id after the getter fix.
if [[ "$(mm_wf_get CLIENT_SET_GENERATION_ID)" == "CLIENT_SET_GENERATION_ID=" ]]; then
  fail "getter still returns KEY= for empty value"
else
  pass "getter does not return KEY= for empty value"
fi

echo "======== DONE fail=${FAIL} ========"
exit "$FAIL"
