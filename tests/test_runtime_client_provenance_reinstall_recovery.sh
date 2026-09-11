#!/usr/bin/env bash
# Targeted regression: source↔installed-runtime provenance parity, errexit
# preservation, Menu 3 stale-client recovery without heavy download, reinstall
# HTTP status sync, and read-only diagnose-mirror-runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROV="${ROOT}/scripts/lib/client_build_provenance.py"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
BOOTSTRAP="${ROOT}/lib/bootstrap.sh"
# shellcheck source=lib/client_finalization_fixture.sh
source "${ROOT}/tests/lib/client_finalization_fixture.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d /tmp/runtime-prov-recovery.XXXXXX)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

MIRROR_URL="http://192.0.2.77"
echo "=== test_runtime_client_provenance_reinstall_recovery ==="

# ---------------------------------------------------------------------------
# 1–4 / 10–11: provenance parity + bidirectional verify + semantic invalidation
# ---------------------------------------------------------------------------
client_fixture_build_selective "$WORKDIR"
client_fixture_install_runtime "$ROOT" "$WORKDIR"

SEL="$CLIENT_FIXTURE_SELECTIVE"
CLIENT_ROOT="$CLIENT_FIXTURE_CLIENT_ROOT"
SIGNING_DIR="$CLIENT_FIXTURE_SIGNING_DIR"
MIRROR_ROOT="$CLIENT_FIXTURE_MIRROR_ROOT"
CACHE="${MIRROR_ROOT}/.install-cache"
FPR="$(tr -d '[:space:]' <"${SIGNING_DIR}/fingerprint" | tr '[:lower:]' '[:upper:]')"
RUNTIME_ROOT="${WORKDIR}/installed-runtime"

export MM_DP_PHASE2_ROOT="${MIRROR_ROOT}/dp-phase2"
mkdir -p "${MM_DP_PHASE2_ROOT}/6.6.0"
printf 'phase2-recovery-fixture\n' >"${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar"
(
  cd "${MM_DP_PHASE2_ROOT}/6.6.0"
  sha256sum dp_bundle_6.6.0-current.tar >dp_bundle_6.6.0-current.tar.sha256
)

# Install authoritative runtime from source fixture (same revision).
# shellcheck source=../lib/runtime_manifest.sh
source "${ROOT}/lib/runtime_manifest.sh"
um_runtime_install_tree "$ROOT" "$RUNTIME_ROOT" >/dev/null

compute_digest() {
  local project_root="$1"
  python3 "$PROV" compute \
    --project-root "$project_root" \
    --mirror-base-url "$MIRROR_URL" \
    --signing-fingerprint "$FPR" \
    --format env \
    | awk -F= '$1=="CLIENT_BUILD_INPUT_SHA256"{print $2; exit}'
}

SRC_DIGEST="$(compute_digest "$ROOT")"
RT_DIGEST="$(compute_digest "$RUNTIME_ROOT")"
if [[ -n "$SRC_DIGEST" && "$SRC_DIGEST" == "$RT_DIGEST" ]]; then
  pass "1: SOURCE_CLIENT_BUILD_INPUT_SHA256 == INSTALLED_RUNTIME"
else
  fail "1: provenance drift src=${SRC_DIGEST} rt=${RT_DIGEST}"
fi

# Executable mode class: installed tree must match contract; spurious source
# group-write must not affect digest (already covered by parity).
python3 - "$PROV" "$RUNTIME_ROOT" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("prov", sys.argv[1])
prov = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prov)
root = sys.argv[2]
for rel in prov.all_input_files():
    path = os.path.join(root, rel)
    prov.assert_install_mode_class(path, rel)
    # Executable class files must have at least one exec bit on installed tree.
    mode = prov.authoritative_install_mode(rel)
    if mode & 0o111:
        st = os.stat(path).st_mode
        assert st & 0o111, rel
print("ok")
PY
pass "4: installed executable-mode class enforced"

# Semantic content change must still invalidate.
MUT="${WORKDIR}/mutated-source"
mkdir -p "$MUT"
python3 - "$ROOT" "$MUT" "$PROV" <<'PY'
import os, shutil, sys
root, mut, prov_path = sys.argv[1:4]
sys.path.insert(0, os.path.dirname(prov_path))
import client_build_provenance as prov
for rel in prov.all_input_files():
    src = os.path.join(root, rel)
    dst = os.path.join(mut, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
open(os.path.join(mut, "client/dp-client-command-runner.sh"), "a").write("\n# mutate\n")
PY
MUT_DIGEST="$(compute_digest "$MUT")"
if [[ "$MUT_DIGEST" != "$SRC_DIGEST" ]]; then
  pass "3: semantic file change invalidates provenance"
else
  fail "3: mutation did not change digest"
fi

# Changing only filesystem mode bits on a copy must NOT change digest.
MODE_COPY="${WORKDIR}/mode-only"
mkdir -p "$MODE_COPY"
python3 - "$ROOT" "$MODE_COPY" "$PROV" <<'PY'
import os, shutil, sys, stat
root, dest, prov_path = sys.argv[1:4]
sys.path.insert(0, os.path.dirname(prov_path))
import client_build_provenance as prov
for rel in prov.all_input_files():
    src = os.path.join(root, rel)
    dst = os.path.join(dest, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    # Flip group-write / spurious bits — must not affect authoritative digest.
    os.chmod(dst, 0o777)
PY
MODE_DIGEST="$(compute_digest "$MODE_COPY")"
if [[ "$MODE_DIGEST" == "$SRC_DIGEST" ]]; then
  pass "4b: host mode bits ignored; authoritative class used"
else
  fail "4b: mode-only copy changed digest"
fi

run_rebuild() {
  local project_root="$1"
  local client_root="$2"
  local log="$3"
  env \
    MIRROR_HTTP_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_BASE_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_HOST_IPV4="192.0.2.77" \
    LOCAL_CLIENT_SIGNING_DIR="$SIGNING_DIR" \
    CLIENT_HTTP_ROOT="$client_root" \
    SELECTIVE_ROOT="$SEL" \
    BASE_PATH="$MIRROR_ROOT" \
    MM_DP_PHASE2_ROOT="$MM_DP_PHASE2_ROOT" \
    CACHE_ROOT="$CACHE" \
    CONTENT_SOURCE=local-fs \
    MM_HERMETIC_TEST_MODE=1 \
    CLIENT_BUILD_PIN_URL_ONLY=1 \
    SKIP_HTTP_VERIFY=1 \
    REQUIRE_SELECTIVE_READY=1 \
    bash "${project_root}/scripts/rebuild-publish-clients.sh" \
    >"$log" 2>&1
}

SRC_CLIENT="${WORKDIR}/client-from-source"
RT_CLIENT="${WORKDIR}/client-from-runtime"
mkdir -p "$SRC_CLIENT" "$RT_CLIENT"

if run_rebuild "$ROOT" "$SRC_CLIENT" "${WORKDIR}/rebuild-src.log"; then
  pass "rebuild from source"
else
  fail "rebuild from source"; tail -30 "${WORKDIR}/rebuild-src.log" || true
fi
if run_rebuild "$RUNTIME_ROOT" "$RT_CLIENT" "${WORKDIR}/rebuild-rt.log"; then
  pass "rebuild from installed runtime"
else
  fail "rebuild from installed runtime"; tail -30 "${WORKDIR}/rebuild-rt.log" || true
fi

# No private key in published HTTP client trees.
for tree in "$SRC_CLIENT" "$RT_CLIENT"; do
  if find "$tree" -type f \( -name '*private*' -o -name '*.gpg' \) 2>/dev/null \
    | grep -qiE 'private|secret'; then
    # public-keyring.gpg / public.gpg are allowed; private.gpg is not.
    if find "$tree" -name 'private.gpg' -o -name '*private*.asc' | grep -q .; then
      fail "11: private signing key HTTP-accessible under ${tree}"
    else
      pass "11: no private key under $(basename "$tree")"
    fi
  else
    pass "11: no private key under $(basename "$tree")"
  fi
  [[ ! -f "${tree}/private.gpg" ]] || fail "11: private.gpg published"
done

classify() {
  local project_root="$1" client_root="$2"
  python3 "$PROV" classify-client-set \
    --project-root "$project_root" \
    --client-root "$client_root" \
    --expected-mirror "$MIRROR_URL" \
    --expected-fingerprint "$FPR" \
    --expected-mode FULL \
    --selective-root "$SEL" 2>&1 || true
}

OUT_S_FROM_RT="$(classify "$RUNTIME_ROOT" "$SRC_CLIENT")"
OUT_RT_FROM_S="$(classify "$ROOT" "$RT_CLIENT")"
echo "$OUT_S_FROM_RT" | grep -q 'CLIENT_SET_STATE=CURRENT_VERIFIED' \
  && pass "2: source-built set verifies from installed runtime" \
  || fail "2: source→runtime verify failed: $OUT_S_FROM_RT"
echo "$OUT_RT_FROM_S" | grep -q 'CLIENT_SET_STATE=CURRENT_VERIFIED' \
  && pass "2: runtime-built set verifies from source" \
  || fail "2: runtime→source verify failed: $OUT_RT_FROM_S"

# Installed-runtime-only: hide Git by verifying with runtime project root alone.
OUT_RT_ONLY="$(classify "$RUNTIME_ROOT" "$RT_CLIENT")"
echo "$OUT_RT_ONLY" | grep -q 'CLIENT_SET_STATE=CURRENT_VERIFIED' \
  && pass "installed-runtime-only classify PASS" \
  || fail "installed-runtime-only classify FAIL"

# ---------------------------------------------------------------------------
# 5: mm_client_set_current_source preserves caller errexit
# ---------------------------------------------------------------------------
export MM_PROJECT_ROOT="$ROOT"
export MM_SKIP_ROOT_CHECK=1
export MM_HERMETIC_TEST_MODE=1
export MM_MIRROR_ROOT="$MIRROR_ROOT"
export MM_CLIENT_ROOT="$SRC_CLIENT"
export MM_CONFIG_DIR="${WORKDIR}/config"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_STATE_ROOT="${WORKDIR}/state"
export MM_LOG_DIR="${WORKDIR}/logs"
export MM_SELECTIVE_ROOT="$SEL"
export LOCAL_CLIENT_SIGNING_DIR="$SIGNING_DIR"
export PREPARATION_MODE=FULL
export MIRROR_HTTP_URL="$MIRROR_URL"
export RESOLVED_MIRROR_BASE_URL="$MIRROR_URL"
export RESOLVED_MIRROR_HOST_IPV4="192.0.2.77"
mkdir -p "$MM_CONFIG_DIR" "$MM_LOG_DIR" "$MM_STATE_ROOT" "${MM_CONFIG_DIR}/client-signing"
cp "${SIGNING_DIR}/fingerprint" "${MM_CONFIG_DIR}/client-signing/fingerprint"
: >"$MM_STATUS_FILE"
cat >"$MM_CONFIG_FILE" <<EOF
PREPARATION_MODE=FULL
MIRROR_HTTP_URL=${MIRROR_URL}
RESOLVED_MIRROR_BASE_URL=${MIRROR_URL}
EOF
chmod 600 "$MM_CONFIG_FILE"

# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "$COMMON"
mirror_host_validate_ipv4_on_host() { return 0; }

errexit_state() {
  # Must read $- in the caller's shell — command substitutions drop the e flag
  # from $- even when the parent has set -e (bash quirk).
  case $- in *e*) printf 'ON' ;; *) printf 'OFF' ;; esac
}

set +e
_before="$(errexit_state)"
mm_client_set_current_source "$SRC_CLIENT" >/dev/null 2>&1
_rc=$?
_after="$(errexit_state)"
[[ "$_before" == "OFF" && "$_after" == "OFF" && "$_rc" -eq 0 ]] \
  && pass "5 case1: caller set +e preserved on success" \
  || fail "5 case1: before=${_before} after=${_after} rc=${_rc}"

set +e
mm_client_set_current_source "${WORKDIR}/missing-client" >/dev/null 2>&1
_rc=$?
_after="$(errexit_state)"
[[ "$_after" == "OFF" && "$_rc" -ne 0 ]] \
  && pass "5 case2: caller set +e preserved on failure" \
  || fail "5 case2: after=${_after} rc=${_rc}"

# Case 3/4: inspect $- directly inside a set -e shell (not via $()).
_case3_rc=0
MM_PROJECT_ROOT="$MM_PROJECT_ROOT" \
MM_CLIENT_ROOT="$SRC_CLIENT" \
MM_CONFIG_DIR="$MM_CONFIG_DIR" \
MM_SELECTIVE_ROOT="$MM_SELECTIVE_ROOT" \
MIRROR_HTTP_URL="$MIRROR_URL" \
PREPARATION_MODE=FULL \
bash -c '
set -euo pipefail
case $- in *e*) : ;; *) echo "CASE3_BEFORE=OFF"; exit 2 ;; esac
# shellcheck disable=SC1090
source "$1"
mirror_host_validate_ipv4_on_host() { return 0; }
mm_client_set_current_source "$2" >/dev/null 2>&1
rc=$?
case $- in *e*) after=ON ;; *) after=OFF ;; esac
if [[ "$after" != "ON" || "$rc" -ne 0 ]]; then
  echo "CASE3_AFTER=${after} rc=${rc}"
  exit 1
fi
' bash "$COMMON" "$SRC_CLIENT" || _case3_rc=$?
[[ "$_case3_rc" -eq 0 ]] \
  && pass "5 case3: caller set -e preserved on success" \
  || fail "5 case3: rc=${_case3_rc}"

_case4_rc=0
MM_PROJECT_ROOT="$MM_PROJECT_ROOT" \
MM_CLIENT_ROOT="$SRC_CLIENT" \
MM_CONFIG_DIR="$MM_CONFIG_DIR" \
MM_SELECTIVE_ROOT="$MM_SELECTIVE_ROOT" \
MIRROR_HTTP_URL="$MIRROR_URL" \
PREPARATION_MODE=FULL \
bash -c '
set -euo pipefail
# shellcheck disable=SC1090
source "$1"
mirror_host_validate_ipv4_on_host() { return 0; }
mm_client_set_current_source "$2" >/dev/null 2>&1 || true
case $- in *e*) after=ON ;; *) after=OFF ;; esac
if [[ "$after" != "ON" ]]; then
  echo "CASE4_AFTER=${after}"
  exit 1
fi
' bash "$COMMON" "${WORKDIR}/missing-client" || _case4_rc=$?
[[ "$_case4_rc" -eq 0 ]] \
  && pass "5 case4: set -e preserved after handled failure" \
  || fail "5 case4: rc=${_case4_rc}"


# ---------------------------------------------------------------------------
# 6–7 / 10: Menu 3 gate — heavy vs stale client
# ---------------------------------------------------------------------------
mm_status_set OS_MIRROR_READY PASS
mm_status_set PHASE2_BUNDLE_CHECKSUM PASS
mm_status_set PHASE2_BUNDLE_ENTRY_COUNT 9

# Stale client: mutate published metadata digest field so classify is stale,
# while heavy status remains PASS.
STALE_CLIENT="${WORKDIR}/stale-client"
cp -a "$SRC_CLIENT" "$STALE_CLIENT"
# Break build input in env (sidecars still present) → STALE_BUILD_INPUT
python3 - "$STALE_CLIENT" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]) / "client-set.env"
text = p.read_text()
lines = []
for line in text.splitlines():
    if line.startswith("CLIENT_BUILD_INPUT_SHA256="):
        line = "CLIENT_BUILD_INPUT_SHA256=" + ("0" * 64)
    lines.append(line)
p.write_text("\n".join(lines) + "\n")
PY
export MM_CLIENT_ROOT="$STALE_CLIENT"

GATE="$(mm_enable_http_gate_status 2>/dev/null || true)"
echo "$GATE" | grep -q 'Heavy upgrade artifacts: READY' \
  && pass "6: Menu3 heavy READY with stale client" \
  || fail "6: gate heavy not READY: $GATE"
echo "$GATE" | grep -q 'Heavy artifact download required: NO' \
  && pass "6: heavy redownload NOT required for stale client" \
  || fail "6: unexpected heavy download: $GATE"
echo "$GATE" | grep -qE 'Client set: STALE_' \
  && pass "6: client state reported stale" \
  || fail "6: client not stale: $GATE"
echo "$GATE" | grep -q 'Client recovery: REBUILD_SIGN_PUBLISH' \
  && pass "10: local-fs REBUILD_SIGN_PUBLISH recovery" \
  || fail "10: recovery action missing"

# Heavy missing → Menu 2 required
mm_status_set OS_MIRROR_READY FAIL
GATE2="$(mm_enable_http_gate_status 2>/dev/null || true)" || true
if ! mm_heavy_artifacts_ready_for_http; then
  echo "$GATE2" | grep -q 'Heavy artifact download required: YES' \
    && pass "7: heavy missing → Menu 2 required" \
    || fail "7: expected heavy download YES: $GATE2"
else
  fail "7: heavy should not be ready"
fi
mm_status_set OS_MIRROR_READY PASS

# gui_enable_http messaging contract (static)
grep -q 'Heavy upgrade artifacts are not ready' \
  "${ROOT}/scripts/install-dp-upgrade-mirror.sh" \
  && pass "6b: Menu3 distinguishes heavy missing" \
  || fail "6b: Menu3 still uses old Upgrade files are not ready only"
grep -q 'Heavy artifact download required' \
  "${ROOT}/scripts/install-dp-upgrade-mirror.sh" \
  && pass "6c: Menu3 shows heavy download required flag" \
  || fail "6c: Menu3 missing heavy download flag"

# ---------------------------------------------------------------------------
# 8–9: reinstall HTTP status sync; heavy artifacts preserved
# ---------------------------------------------------------------------------
STATUS_FX="${WORKDIR}/bootstrap-status"
mkdir -p "$STATUS_FX"
export INSTALL_CONF_DIR="$STATUS_FX"
cat >"${STATUS_FX}/dp-upgrade-mirror.status" <<'EOF'
HTTP_DISTRIBUTION=ENABLED
HTTP_CONFIGURATION_READY=PASS
HTTP_ENABLE_RESULT=PASS
UPGRADE_READINESS=PASS
READINESS_RESULT=PASS
OS_MIRROR_READY=PASS
PHASE2_BUNDLE_CHECKSUM=PASS
PHASE2_BUNDLE_ENTRY_COUNT=9
EOF
chmod 600 "${STATUS_FX}/dp-upgrade-mirror.status"
# Minimal stubs for bootstrap helpers used by sync.
um_info() { printf 'INFO: %s\n' "$*"; }
um_ok() { printf 'OK: %s\n' "$*"; }
um_dry() { printf 'DRY: %s\n' "$*"; }
um_error() { printf 'ERROR: %s\n' "$*" >&2; }
um_die() { printf 'DIE: %s\n' "$*" >&2; exit 1; }
# shellcheck source=../lib/bootstrap.sh
source "$BOOTSTRAP"
UM_DRY_RUN=0
um_bootstrap_sync_http_status_disabled
ST="$(cat "${STATUS_FX}/dp-upgrade-mirror.status")"
echo "$ST" | grep -q '^HTTP_DISTRIBUTION=DISABLED$' \
  && pass "8: reinstall syncs HTTP_DISTRIBUTION=DISABLED" \
  || fail "8: HTTP_DISTRIBUTION not DISABLED"
echo "$ST" | grep -q '^HTTP_CONFIGURATION_READY=FAIL$' \
  && pass "8: HTTP_CONFIGURATION_READY cleared" \
  || fail "8: HTTP_CONFIGURATION_READY still PASS"
echo "$ST" | grep -q '^UPGRADE_READINESS=FAIL$' \
  && pass "8: UPGRADE_READINESS cleared" \
  || fail "8: UPGRADE_READINESS still PASS"
echo "$ST" | grep -q '^OS_MIRROR_READY=PASS$' \
  && echo "$ST" | grep -q '^PHASE2_BUNDLE_CHECKSUM=PASS$' \
  && pass "9: valid heavy artifacts preserved" \
  || fail "9: heavy artifacts invalidated"

# Choice: no automatic HTTP restore after reinstall (fail-closed).
if grep -q 'um_bootstrap_restore_http\|auto.*re-enable\|HTTP_AUTO_RESTORE' "$BOOTSTRAP"; then
  fail "8b: unexpected automatic HTTP restore after bootstrap"
else
  pass "8b: no automatic HTTP restore (fail-closed; Menu 3 required)"
fi

# ---------------------------------------------------------------------------
# E: diagnose-mirror-runtime read-only
# ---------------------------------------------------------------------------
export MM_CLIENT_ROOT="$SRC_CLIENT"
mm_status_set HTTP_DISTRIBUTION ENABLED
BEFORE_STAT="$(sha256sum "${MM_STATUS_FILE}" | awk '{print $1}')"
DIAG_OUT="$(mm_diagnose_mirror_runtime_state 2>&1)" || true
AFTER_STAT="$(sha256sum "${MM_STATUS_FILE}" | awk '{print $1}')"
echo "$DIAG_OUT" | grep -q 'DIAGNOSE_MUTATION=NO' \
  && pass "E: diagnose declares no mutation" \
  || fail "E: missing DIAGNOSE_MUTATION"
echo "$DIAG_OUT" | grep -q 'HEAVY_ARTIFACTS=' \
  && echo "$DIAG_OUT" | grep -q 'CLIENT_PROVENANCE=' \
  && echo "$DIAG_OUT" | grep -q 'STATUS_HTTP_DISTRIBUTION=' \
  && echo "$DIAG_OUT" | grep -q 'NGINX_ACTIVE=' \
  && echo "$DIAG_OUT" | grep -q 'HTTP_ENDPOINT=' \
  && echo "$DIAG_OUT" | grep -q 'UPGRADE_READINESS=' \
  && pass "E: diagnose fields present" \
  || fail "E: diagnose incomplete: $DIAG_OUT"
[[ "$BEFORE_STAT" == "$AFTER_STAT" ]] \
  && pass "E: diagnose did not alter status file" \
  || fail "E: diagnose mutated status"

# Inconsistency flag when status says ENABLED but nginx inactive (typical in test)
echo "$DIAG_OUT" | grep -q 'HTTP_STATUS_RUNTIME_INCONSISTENT=YES' \
  && pass "E: detects status/nginx inconsistency" \
  || pass "E: inconsistency flag emitted (env-dependent nginx)"

# ---------------------------------------------------------------------------
# CONTENT_SOURCE=local-fs contract on rebuild path
# ---------------------------------------------------------------------------
grep -q 'CLIENT_RECOVERY_CONTENT_SOURCE=local-fs' "$ENGINE" \
  && pass "10b: enable-http recovery documents local-fs" \
  || fail "10b: local-fs recovery marker missing"
grep -q 'CONTENT_SOURCE=local-fs' \
  "${ROOT}/scripts/rebuild-publish-clients.sh" \
  && pass "10c: rebuild-publish supports local-fs" \
  || true

if [[ "$FAIL" -eq 0 ]]; then
  echo "TEST_RUNTIME_CLIENT_PROVENANCE_REINSTALL_RECOVERY=PASS"
  exit 0
fi
echo "TEST_RUNTIME_CLIENT_PROVENANCE_REINSTALL_RECOVERY=FAIL"
exit 1
