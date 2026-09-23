#!/usr/bin/env bash
# Menu 2 must quiesce live HTTP before mutating publication state.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }

echo "======== test_http_publication_quiesce ========"

export MM_PROJECT_ROOT="$ROOT"
export MM_CONFIG_DIR="$TMP/config"
export MM_STATUS_FILE="$MM_CONFIG_DIR/status"
export MM_STATE_DIR="$TMP/state"
export MM_LOCK_FILE="$TMP/publication.lock"
export MM_HTTP_QUIESCE_LOG="$TMP/quiesce.log"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_HERMETIC_TEST_MODE=1
export MM_SKIP_ROOT_CHECK=1
mkdir -p "$MM_CONFIG_DIR" "$MM_STATE_DIR"
printf 'HTTP_DISTRIBUTION=ENABLED\nUPGRADE_READINESS=PASS\n' >"$MM_STATUS_FILE"

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_install_engine.sh"

engine_disable_http_and_readiness
grep -q 'nginx-stop' "$MM_HTTP_QUIESCE_LOG" \
  && pass "live HTTP quiesce requested before state rewrite" \
  || fail "nginx was not quiesced"
[[ "$(mm_status_get HTTP_DISTRIBUTION)" == "DISABLED" ]] \
  && pass "HTTP_DISTRIBUTION disabled" \
  || fail "HTTP still enabled"
[[ "$(mm_status_get HTTP_PUBLICATION_QUIESCED)" == "YES" ]] \
  && pass "publication marked quiesced" \
  || fail "quiesce marker missing"
[[ "$(mm_status_get UPGRADE_READINESS)" == "FAIL" ]] \
  && pass "readiness fail-closed during maintenance" \
  || fail "readiness not failed closed"

# Not live: no extra stop.
: >"$MM_HTTP_QUIESCE_LOG"
engine_disable_http_and_readiness
[[ ! -s "$MM_HTTP_QUIESCE_LOG" ]] \
  && pass "already-disabled HTTP does not re-stop" \
  || fail "unexpected second nginx-stop"

# systemctl is-active rc=4 is unknown, not inactive. Must not mark quiesced.
cat >"$TMP/systemctl-unknown" <<'EOS'
#!/bin/bash
if [[ "$1" == "is-active" ]]; then
  exit 4
fi
exit 0
EOS
chmod 0700 "$TMP/systemctl-unknown"
export MM_SYSTEMCTL_BIN="$TMP/systemctl-unknown"
printf 'HTTP_DISTRIBUTION=ENABLED\nUPGRADE_READINESS=PASS\nHTTP_PUBLICATION_QUIESCED=NO\n' >"$MM_STATUS_FILE"
set +e
engine_quiesce_live_http_publication >"$TMP/rc4.out" 2>"$TMP/rc4.err"
RC4=$?
set -e
[[ "$RC4" -ne 0 ]] && grep -q 'service_state_unknown rc=4' "$TMP/rc4.err" \
  && pass "is-active rc=4 fails closed" \
  || fail "rc=4 quiesce rc=${RC4} err=$(cat "$TMP/rc4.err")"
[[ "$(mm_status_get HTTP_PUBLICATION_QUIESCED)" != "YES" ]] \
  && pass "rc=4 does not mark publication quiesced" \
  || fail "rc=4 marked quiesced"
[[ "$(mm_status_get HTTP_DISTRIBUTION)" == "ENABLED" ]] \
  && pass "rc=4 leaves HTTP_DISTRIBUTION unchanged" \
  || fail "rc=4 rewrote HTTP_DISTRIBUTION"
unset MM_SYSTEMCTL_BIN

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
echo "ALL PASS"
exit 0
