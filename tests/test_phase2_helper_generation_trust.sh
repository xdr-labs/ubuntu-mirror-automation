#!/usr/bin/env bash
# Phase 2 helper generation-bound trust: no helper is sourced/executed until
# its bytes match the pinned generation manifest.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="${ROOT}/client/stage-dp-phase2.sh"
GEN_LIB="${ROOT}/scripts/lib/phase2_helper_generation.sh"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
PROGRESS="${ROOT}/client/lib/dp-phase2-operation-progress.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
HTTP_PID=""
cleanup() {
  if [[ -n "$HTTP_PID" ]]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# shellcheck source=/dev/null
source "$GEN_LIB"

copy_unit() {
  local dest="$1"
  mkdir -p "${dest}/lib"
  cp -a "${ROOT}/client/stage-dp-phase2.sh" "${dest}/stage-dp-phase2.sh"
  cp -a "${ROOT}/client/bringup_py3_dp_lifecycle.sh" "${dest}/bringup_py3_dp_lifecycle.sh"
  cp -a "${ROOT}/client/lib/dp-offline-source-product-version.sh" \
    "${dest}/lib/dp-offline-source-product-version.sh"
  cp -a "${ROOT}/client/lib/dp-phase2-operation-progress.sh" \
    "${dest}/lib/dp-phase2-operation-progress.sh"
  cp -a "${ROOT}/client/lib/dp-phase2-bringup-lifecycle.sh" \
    "${dest}/lib/dp-phase2-bringup-lifecycle.sh"
  cp -a "${ROOT}/client/lib/dp-phase2-ubuntu-prerequisites.sh" \
    "${dest}/lib/dp-phase2-ubuntu-prerequisites.sh"
  phase2_helper_generation_write "$dest" >/dev/null
  chmod +x "${dest}/stage-dp-phase2.sh" "${dest}/bringup_py3_dp_lifecycle.sh"
}

UNIT="${TMP}/good"
copy_unit "$UNIT"
phase2_helper_generation_verify "$UNIT" || fail "correct same-generation helper set"
pass "correct same-generation helper set PASS"

# Modify one helper byte → FAIL before source
SENTINEL="${TMP}/sentinel.touched"
BAD="${TMP}/bad-byte"
copy_unit "$BAD"
printf 'x' >>"${BAD}/lib/dp-offline-source-product-version.sh"
set +e
bash "${BAD}/stage-dp-phase2.sh" --help >"${TMP}/bad-byte.out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "modified helper still sourced"
grep -q 'PHASE2_HELPER_GENERATION=FAIL' "${TMP}/bad-byte.out" \
  || fail "modified helper missing FAIL marker"
pass "modify one helper byte FAIL before source"

# Replace one helper with previous-generation copy
PREV="${TMP}/prev"
copy_unit "$PREV"
printf '# previous-generation helper\ntrue\n' \
  >"${PREV}/lib/dp-phase2-operation-progress.sh"
set +e
bash "${PREV}/stage-dp-phase2.sh" --help >"${TMP}/prev.out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "previous-generation helper accepted"
grep -q 'PHASE2_HELPER_GENERATION=FAIL' "${TMP}/prev.out" \
  || fail "previous-generation missing FAIL"
pass "previous-generation helper FAIL"

# Modify helper manifest → FAIL against pinned identity
MANI="${TMP}/mani"
copy_unit "$MANI"
good_sha="$(phase2_helper_generation_sha256 "${MANI}/phase2-helper-generation.manifest")"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  stage-dp-phase2.sh\n' \
  >"${MANI}/phase2-helper-generation.manifest"
set +e
bash "${MANI}/stage-dp-phase2.sh" --help >"${TMP}/mani.out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "modified manifest accepted"
grep -q 'PHASE2_HELPER_GENERATION=FAIL' "${TMP}/mani.out" \
  || fail "modified manifest missing FAIL"
pass "modified manifest FAIL against generation identity"

# malformed / missing manifest
MISS="${TMP}/miss"
copy_unit "$MISS"
rm -f "${MISS}/phase2-helper-generation.manifest"
set +e
bash "${MISS}/stage-dp-phase2.sh" --help >"${TMP}/miss.out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "missing manifest accepted"
grep -q 'reason=manifest_missing' "${TMP}/miss.out" || fail "missing manifest reason"
pass "missing manifest FAIL"

EMPTY="${TMP}/empty"
copy_unit "$EMPTY"
: >"${EMPTY}/phase2-helper-generation.manifest"
set +e
bash "${EMPTY}/stage-dp-phase2.sh" --help >"${TMP}/empty.out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "empty manifest accepted"
pass "malformed/empty manifest FAIL"

# valid bash -n but wrong hash
SYN="${TMP}/syn"
copy_unit "$SYN"
cat >"${SYN}/lib/dp-phase2-ubuntu-prerequisites.sh" <<'EOF'
#!/usr/bin/env bash
# syntactically valid, wrong generation
true
EOF
bash -n "${SYN}/lib/dp-phase2-ubuntu-prerequisites.sh"
set +e
bash "${SYN}/stage-dp-phase2.sh" --help >"${TMP}/syn.out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "bash -n wrong-hash helper accepted"
grep -q 'PHASE2_HELPER_GENERATION=FAIL' "${TMP}/syn.out" \
  || fail "wrong-hash helper missing FAIL"
pass "valid bash -n but wrong hash FAIL"

# sentinel helper: integrity failure must occur before sentinel runs
SENT="${TMP}/sent"
copy_unit "$SENT"
cat >"${SENT}/lib/dp-offline-source-product-version.sh" <<EOF
#!/usr/bin/env bash
touch '${SENTINEL}'
SOURCE_HELPER_LOADED=YES
EOF
rm -f "$SENTINEL"
set +e
bash "${SENT}/stage-dp-phase2.sh" --help >"${TMP}/sent.out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "sentinel helper was sourced"
[[ ! -e "$SENTINEL" ]] || fail "sentinel ran before integrity failure"
pass "sentinel helper did not run on integrity failure"

# lifecycle wrapper + ubuntu-prerequisites are in the generation unit
grep -q 'bringup_py3_dp_lifecycle.sh' "${UNIT}/phase2-helper-generation.manifest" \
  || fail "lifecycle wrapper not in generation manifest"
grep -q 'lib/dp-phase2-ubuntu-prerequisites.sh' "${UNIT}/phase2-helper-generation.manifest" \
  || fail "ubuntu-prerequisites helper not in generation manifest"
pass "lifecycle wrapper and ubuntu-prerequisites covered by generation"

# Menu 7 command remains copy/paste valid and pins the wrapper hash.
# Inner generation-manifest SHA256 lives inside upgrade-phase2.sh.
export MM_PROJECT_ROOT="$ROOT"
export MM_CLIENT_ROOT="$UNIT"
export SKIP_MIRROR_HOST_VALIDATE=1
phase2_upgrade_wrapper_write "$UNIT" "http://192.0.2.10" "6.5.0" >/dev/null
LIB_INST="${TMP}/installer-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$INSTALLER" >"$LIB_INST"
# shellcheck disable=SC1090
source "$LIB_INST"
cmd="$(gui_phase2_stage_command_line "http://192.0.2.10" "6.5.0")"
printf '%s\n' "$cmd" >"${TMP}/menu7.sh"
[[ "$(wc -l <"${TMP}/menu7.sh" | tr -d ' ')" == "1" ]] || fail "Menu 7 Phase 2 command not one line"
bash -n "${TMP}/menu7.sh" || fail "Menu 7 Phase 2 command bash -n"
wrapper_sha="$(sha256sum "${UNIT}/upgrade-phase2.sh" | awk '{print $1}')"
grep -Fq "$wrapper_sha" "${TMP}/menu7.sh" || fail "Menu 7 command missing pinned wrapper SHA"
grep -q 'upgrade-phase2.sh' "${TMP}/menu7.sh" || fail "Menu 7 command missing upgrade-phase2.sh"
grep -q 'for F in' "${TMP}/menu7.sh" && fail "helper download loop leaked into Menu 7" \
  || pass "helper download loop not visible"
pinned="$(gui_phase2_helper_generation_sha256)"
grep -Fq "H='${pinned}'" "${UNIT}/upgrade-phase2.sh" || fail "wrapper missing pinned generation SHA"
grep -q "GEN='phase2-helper-generation.manifest'" "${UNIT}/upgrade-phase2.sh" \
  || fail "wrapper missing generation manifest"
grep -q 'sha256sum -c "$GEN"' "${UNIT}/upgrade-phase2.sh" \
  || fail "wrapper missing helper hash verification"
# The wrapper must return from sudo normally so its EXIT trap removes the mktemp tree.
grep -Fq 'trap '\''rm -rf "$W"'\'' EXIT' "${UNIT}/upgrade-phase2.sh" \
  || fail "wrapper missing temp cleanup EXIT trap"
grep -Fq 'sudo bash "./$SCRIPT" --target-version "$VER" --mirror-url "$MIRROR"' \
  "${UNIT}/upgrade-phase2.sh" || fail "wrapper missing Phase 2 stage invocation"
if grep -E 'sudo bash.*"\$SCRIPT".*--same-version-recovery' "${UNIT}/upgrade-phase2.sh" >/dev/null 2>&1; then
  fail "normal wrapper must not force same-version-recovery"
fi
[[ -f "${UNIT}/upgrade-phase2-same-version-recovery.sh" ]] || fail "recovery wrapper missing"
grep -Fq 'CONFIRM_SAME_VERSION_RECOVERY=YES' "${UNIT}/upgrade-phase2-same-version-recovery.sh" \
  || fail "recovery confirmation gate missing"
if grep -q '^exec sudo bash ' "${UNIT}/upgrade-phase2.sh"; then
  fail "exec bypasses wrapper EXIT cleanup trap"
fi
pass "Phase 2 wrapper preserves temp cleanup after stage"
grep -qE 'curl[^|]*\|[[:space:]]*bash' "${TMP}/menu7.sh" && fail "curl|bash introduced" \
  || pass "no curl|bash in generated command"
if grep -Ei 'password|secret|ACPS_PASSWORD|WORKER_SSH_PASSWORD' "${TMP}/menu7.sh"; then
  fail "password/secret in generated command"
fi
pass "Menu 7 Phase 2 command remains copy/paste valid"
pass "no password/secret in generated command"

# Legacy fetch without a trusted manifest fails closed (no bash -n source path)
LEG="${TMP}/legacy"
mkdir -p "$LEG"
cp -a "$STAGE" "${LEG}/stage-dp-phase2.sh"
chmod +x "${LEG}/stage-dp-phase2.sh"
set +e
bash "${LEG}/stage-dp-phase2.sh" --help --mirror-url "http://127.0.0.1:1" \
  >"${TMP}/legacy.out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "legacy missing-unit path succeeded"
grep -q 'manifest_missing\|PHASE2_HELPER_GENERATION=FAIL' "${TMP}/legacy.out" \
  || fail "legacy path missing fail-closed marker"
pass "legacy helper fetch fail-closed without trusted generation"

# Controller dependency fetch also requires the local trusted manifest
# shellcheck source=/dev/null
source "$PROGRESS"
export _STAGE_LIB_DIR="${TMP}/ctrl/lib"
export MIRROR_URL="http://127.0.0.1:1"
mkdir -p "${TMP}/ctrl/lib"
set +e
dp2_prepare_bringup_controller_dependencies >"${TMP}/ctrl.out" 2>&1
crc=$?
set -e
[[ "$crc" -ne 0 ]] || fail "controller fetch without manifest succeeded"
grep -q 'reason=manifest_missing' "${TMP}/ctrl.out" \
  || fail "controller fetch missing manifest_missing"
pass "controller dependency fetch fail-closed without generation manifest"

# Same-generation download/reuse via prepare
HTTP_ROOT="${TMP}/http"
CLIENT_ROOT="${HTTP_ROOT}/client"
copy_unit "$CLIENT_ROOT"
PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$HTTP_ROOT" \
  >"${TMP}/http.log" 2>&1 &
HTTP_PID=$!
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:${PORT}/client/stage-dp-phase2.sh" >/dev/null 2>&1 && break
  sleep 0.1
done
WORK="${TMP}/work"
mkdir -p "${WORK}/lib"
cp -a "${CLIENT_ROOT}/phase2-helper-generation.manifest" \
  "${WORK}/phase2-helper-generation.manifest"
export _STAGE_LIB_DIR="${WORK}/lib"
export MIRROR_URL="http://127.0.0.1:${PORT}"
dp2_prepare_bringup_controller_dependencies >"${TMP}/prep.out" 2>&1 \
  || { cat "${TMP}/prep.out"; fail "same-generation controller download"; }
grep -q 'PHASE2_CONTROLLER_DEPENDENCIES=PASS' "${TMP}/prep.out" \
  || fail "controller PASS missing"
grep -q 'PHASE2_CONTROLLER_DEPENDENCY=DOWNLOAD path=bringup_py3_dp_lifecycle.sh' "${TMP}/prep.out" \
  || fail "lifecycle wrapper not downloaded under generation check"
pass "same-generation helper download PASS"

echo "PHASE2_HELPER_GENERATION_TRUST=PASS"
exit 0
