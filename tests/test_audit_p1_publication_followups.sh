#!/usr/bin/env bash
# Deterministic regressions for independent audit findings P1-A through P1-G.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }

echo "======== test_audit_p1_publication_followups ========"

export MM_PROJECT_ROOT="$ROOT"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$MM_CONFIG_DIR/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$MM_CONFIG_DIR/status"
export MM_STATE_DIR="$TMP/state"
export MM_STATE_ROOT="$TMP/runs"
export MM_LOCK_FILE="$TMP/publication.lock"
export MM_MIRROR_ROOT="$TMP/mirror"
export MM_SELECTIVE_ROOT="$TMP/mirror/selective"
export MM_DP_PHASE2_ROOT="$TMP/mirror/dp-phase2"
export MM_CLIENT_ROOT="$TMP/mirror/client"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_HERMETIC_TEST_MODE=1
export MM_SKIP_ROOT_CHECK=1
export MM_HTTP_QUIESCE_LOG="$TMP/quiesce.log"
mkdir -p "$MM_CONFIG_DIR" "$MM_STATE_DIR" "$MM_MIRROR_ROOT"
printf 'PREPARATION_MODE=PHASE2_ONLY\nMIRROR_SERVER_IP=192.0.2.10\n' >"$MM_CONFIG_FILE"
printf 'HTTP_DISTRIBUTION=ENABLED\nUPGRADE_READINESS=PASS\n' >"$MM_STATUS_FILE"

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_install_engine.sh"

# --- P1-A: nginx stop failure must not be reported as success or rewrite gates ---
cat >"$TMP/systemctl-stop-fails" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >>"${SYSTEMCTL_LOG:?}"
if [[ "$1" == "is-active" ]]; then
  if [[ -f "${SYSTEMCTL_STOPPED_FLAG:?}" ]]; then
    exit 3
  fi
  exit 0
fi
if [[ "$1" == "stop" ]]; then
  echo STOP_FAILED >&2
  exit 1
fi
exit 0
EOS
chmod 0700 "$TMP/systemctl-stop-fails"
export MM_SYSTEMCTL_BIN="$TMP/systemctl-stop-fails"
export SYSTEMCTL_LOG="$TMP/sc.log"
export SYSTEMCTL_STOPPED_FLAG="$TMP/stopped"
: >"$SYSTEMCTL_LOG"
rm -f "$SYSTEMCTL_STOPPED_FLAG"
set +e
engine_disable_http_and_readiness >"$TMP/a.out" 2>"$TMP/a.err"
ARC=$?
set -e
[[ "$ARC" -ne 0 ]] && pass "P1-A quiesce failure returns nonzero" || fail "P1-A rc=${ARC}"
[[ "$(mm_status_get HTTP_DISTRIBUTION)" == "ENABLED" ]] \
  && pass "P1-A HTTP_DISTRIBUTION unchanged after stop failure" \
  || fail "P1-A distribution rewritten to $(mm_status_get HTTP_DISTRIBUTION)"
[[ "$(mm_status_get UPGRADE_READINESS)" == "PASS" ]] \
  && pass "P1-A readiness not rewritten after stop failure" \
  || fail "P1-A readiness rewritten to $(mm_status_get UPGRADE_READINESS)"
grep -q 'STOP_FAILED' "$TMP/a.err" && pass "P1-A stop failure visible" || fail "P1-A stop failure hidden"
[[ "$(mm_status_get HTTP_PUBLICATION_QUIESCED)" != "YES" ]] \
  && pass "P1-A not marked quiesced" || fail "P1-A marked quiesced despite stop failure"

# --- P1-B: stale DISABLED status must still consult live nginx ---
printf 'HTTP_DISTRIBUTION=DISABLED\nUPGRADE_READINESS=FAIL\n' >"$MM_STATUS_FILE"
cat >"$TMP/systemctl-active" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >>"${SYSTEMCTL_LOG:?}"
if [[ "$1" == "is-active" ]]; then
  if [[ -f "${SYSTEMCTL_STOPPED_FLAG:?}" ]]; then
    exit 3
  fi
  exit 0
fi
if [[ "$1" == "stop" ]]; then
  : >"${SYSTEMCTL_STOPPED_FLAG:?}"
  exit 0
fi
exit 0
EOS
chmod 0700 "$TMP/systemctl-active"
export MM_SYSTEMCTL_BIN="$TMP/systemctl-active"
: >"$SYSTEMCTL_LOG"
rm -f "$SYSTEMCTL_STOPPED_FLAG"
set +e
engine_quiesce_live_http_publication >"$TMP/b.out" 2>"$TMP/b.err"
BRC=$?
set -e
[[ "$BRC" -eq 0 ]] && pass "P1-B live nginx stop succeeds" || fail "P1-B rc=${BRC}"
grep -q 'is-active' "$SYSTEMCTL_LOG" && pass "P1-B systemctl consulted despite DISABLED status" \
  || fail "P1-B systemctl not called"
grep -q '^stop nginx$' "$SYSTEMCTL_LOG" && pass "P1-B nginx stop issued" || fail "P1-B stop missing"
[[ -f "$SYSTEMCTL_STOPPED_FLAG" ]] && pass "P1-B stop observed" || fail "P1-B stop flag missing"

# --- P1-C: Menu 2 REUSE quiesces before prerequisite/client mutation ---
python3 - "$ROOT" <<'PY' && pass "P1-C quiesce precedes REUSE mutation in prepare" || fail "P1-C ordering"
import sys
from pathlib import Path
body = (Path(sys.argv[1]) / "scripts/lib/mirror_install_engine.sh").read_text()
idx = body.rfind("engine_download_and_prepare() {")
body = body[idx:]
end = body.find("\nengine_render_nginx_site()")
body = body[:end]
gate = body.find("engine_disable_http_and_readiness")
reuse = body.find('PHASE2_BUNDLE_ACTION}" == "REUSE"')
prereq = body.find("engine_prepare_phase2_ubuntu_prerequisites")
assert gate > 0 and reuse > 0 and prereq > 0
assert gate < reuse < prereq, (gate, reuse, prereq)
PY

unset MM_SYSTEMCTL_BIN
export MM_LOCK_FILE="$TMP/menu2.lock"
printf 'HTTP_DISTRIBUTION=ENABLED\n' >"$MM_STATUS_FILE"
: >"$MM_HTTP_QUIESCE_LOG"
ORDER="$TMP/order"
: >"$ORDER"
mm_require_configured_mirror_server_ip() { return 0; }
engine_preflight_host() { return 0; }
engine_assert_same_filesystem_layout() { return 0; }
engine_recover_publication_transactions() { return 0; }
engine_phase2_migrate_legacy_public_upstream() { return 0; }
mm_check_client_build_prerequisites_ready() { return 0; }
engine_assess_phase2_final() { PHASE2_EXISTING_BUNDLE=VALID; }
engine_verify_disk_space() { return 0; }
engine_mark_phase2_reused() { echo MARK >>"$ORDER"; }
engine_prepare_phase2_ubuntu_prerequisites() {
  printf 'PREREQ quiesced=%s\n' "$(mm_status_get HTTP_PUBLICATION_QUIESCED)" >>"$ORDER"
}
engine_cleanup_temps() { return 0; }
mm_record_artifacts_prepared() { return 0; }
engine_finalize_local_client_set() { echo FINALIZE >>"$ORDER"; return 0; }
mm_record_download_validated() { return 0; }
engine_write_install_report() { return 0; }
export PREPARATION_MODE=PHASE2_ONLY
export TARGET_DP_VERSION=6.6.0
export PHASE2_TARGET_VERSION=6.6.0
export MIRROR_SERVER_IP=192.0.2.10
export MM_DRY_RUN=0
export PHASE2_EXISTING_INVALID_REASON=""
export PHASE2_EXISTING_FINAL_BYTES=0
set +e
set +u
engine_download_and_prepare >"$TMP/reuse.out" 2>"$TMP/reuse.err"
RRC=$?
set -e
set -u
[[ "$RRC" -eq 0 ]] && pass "P1-C REUSE prepare returned 0" || { fail "P1-C REUSE rc=${RRC}"; tail -40 "$TMP/reuse.err" >&2; }
grep -q 'nginx-stop' "$MM_HTTP_QUIESCE_LOG" && pass "P1-C quiesce recorded during REUSE" || fail "P1-C no quiesce"
grep -q 'PREREQ quiesced=YES' "$ORDER" \
  && pass "P1-C prerequisite mutation saw publication already quiesced" \
  || fail "P1-C prerequisite ran before quiesce: $(cat "$ORDER" 2>/dev/null || true)"

# --- P1-D: unwritable status directory must not return success; lock is released ---
RODIR="$TMP/status-ro"
mkdir -p "$RODIR"
export MM_STATUS_FILE="$RODIR/status"
printf 'UPGRADE_READINESS=PASS\n' >"$MM_STATUS_FILE"
: >"${MM_STATUS_FILE}.lock"
chmod a-w "$RODIR"
set +e
mm_status_set UPGRADE_READINESS FAIL >"$TMP/d.out" 2>"$TMP/d.err"
DRC=$?
set -e
chmod u+w "$RODIR" || true
[[ "$DRC" -ne 0 ]] && pass "P1-D status write failure returns nonzero" || fail "P1-D rc=${DRC}"
grep -q 'STATUS_WRITE=FAIL' "$TMP/d.err" && pass "P1-D write failure reported" || fail "P1-D error hidden: $(cat "$TMP/d.err")"
[[ -z "${MM_STATUS_LOCK_FD:-}" ]] && pass "P1-D status lock released after write failure" \
  || fail "P1-D status lock still held fd=${MM_STATUS_LOCK_FD}"
grep -q '^UPGRADE_READINESS=PASS$' "$MM_STATUS_FILE" \
  && pass "P1-D readiness value unchanged" || fail "P1-D readiness mutated"
export MM_STATUS_FILE="$MM_CONFIG_DIR/status"

# --- P1-E / P1-F via legacy verifier ---
export DP_PHASE2_LIB_ONLY=1
export DP_PHASE2_ROOT="$TMP/dp"
export DP_PHASE2_VERSION=6.6.0
export DP_PHASE2_SKIP_ROOT_CHECK=1
export DP_PHASE2_LOCK_FILE="$TMP/dp2.lock"
export DP_PHASE2_LOG_FILE="$TMP/dp2.log"
# shellcheck source=/dev/null
source "${ROOT}/scripts/download-dp-phase2.sh"
trap - EXIT
BAD="$TMP/dp/6.6.0/releases/bad"
mkdir -p "$BAD/extras"
cat >"$BAD/extras/phase2-ubuntu-prerequisites.state" <<'EOF'
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=FAIL
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=1
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=deadbeef
TARGET_DP_VERSION=6.6.0
EOF
set +e
( trap - EXIT; verify_release_prereq_contract "$BAD" ) >"$TMP/e.out" 2>"$TMP/e.err"
ERC=$?
set -e
[[ "$ERC" -ne 0 ]] && pass "P1-E bad prerequisite contract rejected" || fail "P1-E accepted rc=${ERC}"

# Identical nine files with missing extras must not be a successful no-op.
CURREL="${TMP}/dp/6.6.0/releases/cur"
INCOMING="$TMP/incoming/files"
mkdir -p "$CURREL/files" "$INCOMING"
dp2_set_version 6.6.0
for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
  printf 'same-%s\n' "$f" >"${CURREL}/files/${f}"
  cp -f "${CURREL}/files/${f}" "${INCOMING}/${f}"
done
ln -sfn "$CURREL" "${TMP}/dp/6.6.0/current"
rm -rf "${CURREL}/extras"
set +e
maybe_skip_identical_current "$INCOMING" >"$TMP/f.out" 2>"$TMP/f.err"
FRC=$?
set -e
[[ "$FRC" -ne 0 ]] && pass "P1-F identical bytes without extras do not no-op" || fail "P1-F skip rc=${FRC}"

# Production sync refuses the obsolete generation layout and creates no current pointer.
LEGACY_ROOT="$TMP/legacy-sync"
set +e
(
  unset DP_PHASE2_ALLOW_LEGACY_GENERATION_SYNC
  unset DP_PHASE2_LIB_ONLY
  export DP_PHASE2_SKIP_ROOT_CHECK=1
  export MM_HERMETIC_TEST_MODE=1
  export DP_PHASE2_ROOT="$LEGACY_ROOT"
  export DP_PHASE2_LOG_FILE="$TMP/legacy-sync.log"
  export DP_PHASE2_LOCK_FILE="$TMP/legacy-sync.lock"
  bash "${ROOT}/scripts/download-dp-phase2.sh" --version 6.6.0 sync
) >"$TMP/g.out" 2>"$TMP/g.err"
GRC=$?
set -e
[[ "$GRC" -ne 0 ]] && grep -q 'LEGACY_SYNC_DP_PHASE2=DISABLED' "$TMP/g.out" \
  && [[ ! -e "${LEGACY_ROOT}/6.6.0/current" ]] \
  && pass "P1-G production legacy sync disabled" \
  || fail "P1-G sync not disabled rc=${GRC} out=$(cat "$TMP/g.out") err=$(cat "$TMP/g.err")"

# Real client publisher probe takes the publication lock.
HOLD="$TMP/hold"
rm -f "${HOLD}.ready" "${HOLD}.stop"
: >"${HOLD}.stop"
(
  export MM_LOCK_FILE
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/lib/publication_lock.sh"
  publication_lock_acquire
  : >"${HOLD}.ready"
  while [[ -f "${HOLD}.stop" ]]; do sleep 0.05; done
  publication_lock_release
) &
HPID=$!
for _ in $(seq 1 100); do
  [[ -f "${HOLD}.ready" ]] && break
  sleep 0.02
done
set +e
MM_LOCK_FILE="$MM_LOCK_FILE" MM_PUBLICATION_LOCK_PROBE=1 \
  bash "${ROOT}/scripts/rebuild-publish-clients.sh" >"$TMP/pub.out" 2>"$TMP/pub.err"
PRC=$?
set -e
rm -f "${HOLD}.stop"
wait "$HPID" || true
[[ "$PRC" -ne 0 ]] && grep -q 'PUBLICATION_LOCK=BUSY' "$TMP/pub.err" \
  && pass "P1-G standalone client publisher blocks on publication lock" \
  || fail "P1-G publisher probe rc=${PRC} err=$(cat "$TMP/pub.err")"

# Selective mutator entry shares that lock.
HOLD2="$TMP/hold2"
rm -f "${HOLD2}.ready" "${HOLD2}.stop"
: >"${HOLD2}.stop"
(
  export MM_LOCK_FILE
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/lib/publication_lock.sh"
  publication_lock_acquire
  : >"${HOLD2}.ready"
  while [[ -f "${HOLD2}.stop" ]]; do sleep 0.05; done
  publication_lock_release
) &
HPID2=$!
for _ in $(seq 1 100); do
  [[ -f "${HOLD2}.ready" ]] && break
  sleep 0.02
done
set +e
MM_LOCK_FILE="$MM_LOCK_FILE" bash "${ROOT}/scripts/ubuntu-offline-mirror.sh" publish-selective \
  >"$TMP/sel.out" 2>"$TMP/sel.err"
SRC=$?
set -e
rm -f "${HOLD2}.stop"
wait "$HPID2" || true
[[ "$SRC" -ne 0 ]] && grep -q 'PUBLICATION_LOCK=BUSY' "$TMP/sel.err" \
  && pass "P1-G selective publish blocks on publication lock" \
  || fail "P1-G selective rc=${SRC} err=$(tail -5 "$TMP/sel.err")"

# Reproduced suite failure: non-root hermetic acquire must not open /run, and
# must not block on a leftover holder of the shared non-hermetic fallback.
if [[ "${EUID}" -ne 0 ]]; then
  GLOBAL="${TMPDIR:-/tmp}/ubuntu-mirror-publication.lock"
  exec {gfd}>"$GLOBAL"
  if ! flock -n "$gfd"; then
    fail "could not hold shared fallback for isolation check"
  else
    unset MM_LOCK_FILE
    unset PUBLICATION_LOCK_FILE
    set +e
    mm_acquire_install_lock >"$TMP/run.out" 2>"$TMP/run.err"
    RRC2=$?
    set -e
    [[ "$RRC2" -eq 0 ]] \
      && [[ "${MM_LOCK_FILE}" == "${TMPDIR:-/tmp}/ubuntu-mirror-publication.$$.lock" ]] \
      && pass "non-root hermetic install lock is per-process off /run" \
      || fail "non-root install lock rc=${RRC2} path=${MM_LOCK_FILE:-} err=$(cat "$TMP/run.err")"
    mm_release_install_lock || true
    flock -u "$gfd" 2>/dev/null || true
    eval "exec ${gfd}>&-" 2>/dev/null || true
  fi
fi

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
echo "ALL PASS"
exit 0
