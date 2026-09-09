#!/usr/bin/env bash
# tests/test_dp_client_command_execution.sh
# Execute a generated three-line hop command against a local HTTP fixture with stubs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
# shellcheck source=../scripts/lib/local_client_signing.sh
source "${ROOT}/scripts/lib/local_client_signing.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"; [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true' EXIT

echo "=== test_dp_client_command_execution ==="

# --- signing fixture ---
GPG_HOME="${WORKDIR}/gnupg"
mkdir -p "$GPG_HOME"
chmod 700 "$GPG_HOME"
cat >"${GPG_HOME}/batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Command Exec Fixture
Name-Email: cmd-exec@local
Expire-Date: 0
%no-protection
%commit
EOF
gpg --homedir "$GPG_HOME" --batch --gen-key "${GPG_HOME}/batch" >/dev/null 2>&1
PUB="${WORKDIR}/public.gpg"
PRIV="${WORKDIR}/private.gpg"
gpg --homedir "$GPG_HOME" --batch --export --armor >"$PUB"
gpg --homedir "$GPG_HOME" --batch --export-secret-keys --armor >"$PRIV"
FPR="$(local_signing_fingerprint_of "$PUB")"
KR="${WORKDIR}/public-keyring.gpg"
local_signing_build_binary_keyring "$PUB" "$KR"
LOCAL_SIGNING_PRIVATE_KEY="$PRIV"
LOCAL_SIGNING_PUBLIC_KEY="$PUB"
LOCAL_KEY_FINGERPRINT="$FPR"

# --- HTTP fixture tree ---
HTTP_ROOT="${WORKDIR}/http"
HOP="xenial-to-bionic"
SCRIPT="dp-offline-upgrade-${HOP}.sh"
mkdir -p "${HTTP_ROOT}/client/${HOP}"
printf '#!/bin/bash\necho REAL_UPGRADE_SHOULD_NOT_RUN\nexit 99\n' \
  >"${HTTP_ROOT}/client/${SCRIPT}"
chmod 0755 "${HTTP_ROOT}/client/${SCRIPT}"
SCRIPT_SHA="$(sha256sum "${HTTP_ROOT}/client/${SCRIPT}" | awk '{print $1}')"
( cd "${HTTP_ROOT}/client" && sha256sum "$SCRIPT" >"${SCRIPT}.sha256" )
cp "$KR" "${HTTP_ROOT}/client/public-keyring.gpg"
cp "$PUB" "${HTTP_ROOT}/client/public.gpg"
cat >"${HTTP_ROOT}/client/client-set.env" <<EOF
CLIENT_SET_GENERATION_ID=fixture-gen-1
CLIENT_SIGNING_FINGERPRINT=${FPR}
MIRROR_HTTP_URL=http://127.0.0.1
PREPARATION_MODE=FULL
EOF
chmod 0644 "${HTTP_ROOT}/client/client-set.env"

# Publish authenticated command-runner
install -m 0755 "${ROOT}/client/dp-client-command-runner.sh" \
  "${HTTP_ROOT}/client/dp-client-command-runner.sh"
if ! local_signing_stage_command_runner \
  "${HTTP_ROOT}/client" "${ROOT}/client/dp-client-command-runner.sh"
then
  fail "failed to stage command runner into fixture"
fi

write_manifest() {
  local sha="${1:-$SCRIPT_SHA}"
  python3 - "$HOP" "$SCRIPT" "$sha" "${HTTP_ROOT}/client/${HOP}/client-manifest.json" <<'PY'
import json, sys
hop, script, sha, path = sys.argv[1:5]
open(path, "w", encoding="utf-8").write(json.dumps({
    "hop": hop,
    "script": script,
    "script_sha256": sha,
    "fixture": True,
}, indent=2) + "\n")
PY
  gpg --homedir "$GPG_HOME" --batch --yes --detach-sign --armor \
    -o "${HTTP_ROOT}/client/${HOP}/client-manifest.json.asc" \
    "${HTTP_ROOT}/client/${HOP}/client-manifest.json" >/dev/null 2>&1
}
write_manifest

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 - "$HTTP_ROOT" "$PORT" <<'PY' >/dev/null 2>"${WORKDIR}/http.log" &
import http.server, os, sys
os.chdir(sys.argv[1])
port = int(sys.argv[2])
http.server.ThreadingHTTPServer(("127.0.0.1", port), http.server.SimpleHTTPRequestHandler).serve_forever()
PY
HTTP_PID=$!
sleep 0.3
MIRROR="http://127.0.0.1:${PORT}"
python3 "${ROOT}/scripts/lib/build_client_launchers.py" \
  --project-root "$ROOT" \
  --output-dir "${HTTP_ROOT}/client" \
  --mirror-base-url "$MIRROR" \
  --signing-fingerprint "$FPR" \
    --expected-keyring-sha256 "$(sha256sum "$KR" | awk '{print $1}')" >/dev/null
export MM_CLIENT_ROOT="${HTTP_ROOT}/client"
LAUNCHER="dp-launch-${HOP}.sh"
LAUNCHER_SHA="$(sha256sum "${HTTP_ROOT}/client/${LAUNCHER}" | awk '{print $1}')"

LIB="${WORKDIR}/installer-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$INSTALLER" >"$LIB"
# shellcheck disable=SC1090
source "$LIB"

block="$(gui_client_hop_command_line "$MIRROR" "$SCRIPT" "$LAUNCHER_SHA")"
[[ "$(printf '%s\n' "$block" | wc -l | tr -d ' ')" == "1" ]] \
  && pass "generator emits one physical line" \
  || fail "generator not one physical line"
printf '%s\n' "$block" >"${WORKDIR}/cmd.sh"
grep -q "'${LAUNCHER_SHA}'" "${WORKDIR}/cmd.sh" \
  && pass "literal launcher SHA pinned in command" \
  || fail "launcher SHA missing from command"
grep -q 'mktemp -d' "${HTTP_ROOT}/client/${LAUNCHER}" \
  && pass "isolated workdir present in launcher" \
  || fail "isolated workdir missing"
grep -q 'dp-client-command-runner.sh' "${HTTP_ROOT}/client/${LAUNCHER}" \
  && pass "launcher references runner" \
  || fail "runner missing from launcher"

DP_HOME="${WORKDIR}/dp-home"
mkdir -p "$DP_HOME"
printf 'keep-me\n' >"${DP_HOME}/precious.txt"

STUB_RUNS="${WORKDIR}/stub.runs"
: >"$STUB_RUNS"
STUB_BIN="${WORKDIR}/bin"
mkdir -p "$STUB_BIN"
cat >"${STUB_BIN}/sudo" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "bash" && "\${2:-}" == "./${SCRIPT}" ]]; then
  echo "\$@" >>"${STUB_RUNS}"
  exit 0
fi
exec /usr/bin/sudo "\$@"
EOF
chmod +x "${STUB_BIN}/sudo"

sed "s|cd /home/aella|cd '${DP_HOME}'|g" \
  "${WORKDIR}/cmd.sh" >"${WORKDIR}/cmd.run.sh"

run_cmd() {
  env PATH="${STUB_BIN}:/usr/bin:/bin" bash "${WORKDIR}/cmd.run.sh"
}

# --- SHA mismatch protection ---
: >"$STUB_RUNS"
bad_sha_cmd="$(gui_client_hop_command_line "$MIRROR" "$SCRIPT" "$(printf '%064d' 1)")"
sed "s|cd /home/aella|cd '${DP_HOME}'|g" <<<"$bad_sha_cmd" >"${WORKDIR}/partial1.sh"
set +e
env PATH="${STUB_BIN}:/usr/bin:/bin" bash "${WORKDIR}/partial1.sh" >/dev/null 2>&1
p1_rc=$?
set -e
[[ "$(wc -l <"$STUB_RUNS" | tr -d ' ')" == "0" ]] \
  && pass "wrong launcher SHA never runs client" \
  || fail "wrong launcher SHA executed client"

# --- 1) Happy path ---
: >"$STUB_RUNS"
set +e
run_cmd >"${WORKDIR}/happy.out" 2>"${WORKDIR}/happy.err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "full launcher command execution rc=0" || {
  fail "full launcher command execution rc=${rc}"
  cat "${WORKDIR}/happy.err" || true
}
[[ "$(wc -l <"$STUB_RUNS" | tr -d ' ')" == "1" ]] \
  && pass "stub upgrade client executed once" \
  || fail "stub runs=$(wc -l <"$STUB_RUNS")"
[[ -f "${DP_HOME}/precious.txt" ]] && pass "pre-existing home files preserved" \
  || fail "precious.txt deleted"

# --- 2) Bad SHA256 (manifest) → 0 stub runs ---
write_manifest "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
: >"$STUB_RUNS"
set +e
run_cmd >"${WORKDIR}/badsha.out" 2>"${WORKDIR}/badsha.err"
badsha_rc=$?
set -e
[[ "$badsha_rc" -ne 0 ]] && pass "bad manifest SHA256 fails command" || fail "bad SHA256 should fail"
[[ "$(wc -l <"$STUB_RUNS" | tr -d ' ')" == "0" ]] \
  && pass "SHA256_FAILURE_PREVENTS_UPGRADE_EXECUTION=YES" \
  || fail "stub ran after SHA256 failure"
write_manifest

# --- 3) Bad signature → 0 stub runs ---
printf '{"hop":"%s","script":"%s","script_sha256":"%s","tampered":true}\n' \
  "$HOP" "$SCRIPT" "$SCRIPT_SHA" \
  >"${HTTP_ROOT}/client/${HOP}/client-manifest.json"
: >"$STUB_RUNS"
set +e
run_cmd >"${WORKDIR}/badsig.out" 2>"${WORKDIR}/badsig.err"
bad_rc=$?
set -e
[[ "$bad_rc" -ne 0 ]] && pass "bad signature fails command" || fail "bad signature should fail"
[[ "$(wc -l <"$STUB_RUNS" | tr -d ' ')" == "0" ]] \
  && pass "SIGNATURE_FAILURE_PREVENTS_UPGRADE_EXECUTION=YES" \
  || fail "stub ran after signature failure"
write_manifest

# --- 4) Fingerprint mismatch → 0 runs ---
: >"$STUB_RUNS"
bad_block="$(gui_client_hop_command_line "$MIRROR" "$SCRIPT" "$(printf '%064d' 2)")"
sed "s|cd /home/aella|cd '${DP_HOME}'|g" \
  <<<"$bad_block" >"${WORKDIR}/cmd.badfpr.sh"
set +e
env PATH="${STUB_BIN}:/usr/bin:/bin" bash "${WORKDIR}/cmd.badfpr.sh" >/dev/null 2>&1
fpr_rc=$?
set -e
[[ "$fpr_rc" -ne 0 ]] && pass "wrong launcher SHA fails" || fail "wrong launcher SHA should fail"
[[ "$(wc -l <"$STUB_RUNS" | tr -d ' ')" == "0" ]] \
  && pass "LAUNCHER_SHA_MISMATCH_PREVENTS_UPGRADE_EXECUTION=YES" \
  || fail "stub ran after fingerprint mismatch"

# --- 5) Corrupt public-keyring → 0 runs ---
printf 'CORRUPT\n' >"${HTTP_ROOT}/client/public-keyring.gpg"
: >"$STUB_RUNS"
set +e
run_cmd >/dev/null 2>&1
kr_rc=$?
set -e
[[ "$kr_rc" -ne 0 ]] && pass "corrupt keyring fails" || fail "corrupt keyring should fail"
[[ "$(wc -l <"$STUB_RUNS" | tr -d ' ')" == "0" ]] \
  && pass "corrupt keyring prevents upgrade" \
  || fail "stub ran with corrupt keyring"
cp "$KR" "${HTTP_ROOT}/client/public-keyring.gpg"

# --- 6) HTTP 404 → 0 runs ---
rm -f "${HTTP_ROOT}/client/${SCRIPT}"
: >"$STUB_RUNS"
set +e
run_cmd >/dev/null 2>&1
miss_rc=$?
set -e
[[ "$miss_rc" -ne 0 ]] && pass "HTTP 404 fails command" || fail "404 should fail"
[[ "$(wc -l <"$STUB_RUNS" | tr -d ' ')" == "0" ]] \
  && pass "HTTP_404_PREVENTS_UPGRADE_EXECUTION=YES" \
  || fail "stub ran after 404"
[[ -f "${DP_HOME}/precious.txt" ]] && pass "HTTP failure does not delete home evidence" \
  || fail "precious.txt removed on HTTP failure"

# restore script for remaining checks
printf '#!/bin/bash\necho REAL\n' >"${HTTP_ROOT}/client/${SCRIPT}"
chmod 0755 "${HTTP_ROOT}/client/${SCRIPT}"
SCRIPT_SHA="$(sha256sum "${HTTP_ROOT}/client/${SCRIPT}" | awk '{print $1}')"
( cd "${HTTP_ROOT}/client" && sha256sum "$SCRIPT" >"${SCRIPT}.sha256" )
write_manifest

# --- 7) Missing public-keyring → fail closed ---
rm -f "${HTTP_ROOT}/client/public-keyring.gpg"
: >"$STUB_RUNS"
set +e
run_cmd >/dev/null 2>&1
miss_kr_rc=$?
set -e
[[ "$miss_kr_rc" -ne 0 ]] && pass "missing public-keyring fail closed" \
  || fail "missing keyring should fail"
[[ "$(wc -l <"$STUB_RUNS" | tr -d ' ')" == "0" ]] \
  && pass "missing keyring prevents upgrade" \
  || fail "stub ran without keyring"

# --- 8) Malformed command validation ---
# shellcheck source=../scripts/lib/mirror_workflow_state.sh
source "${ROOT}/scripts/lib/mirror_workflow_state.sh"
if mm_wf_validate_os_hop_launcher_at "${WORKDIR}/cmd.sh" 1 "$HOP" "$MIRROR" >/dev/null; then
  pass "valid launcher hop command accepted"
else
  fail "valid hop launcher rejected"
fi
# Tampered: curl|bash must fail validation
printf '%s\n' "cd /home/aella && curl -fsSL ${MIRROR}/client/${LAUNCHER} | bash" \
  >"${WORKDIR}/pipe.sh"
if mm_wf_validate_os_hop_launcher_at "${WORKDIR}/pipe.sh" 1 "$HOP" "$MIRROR" >/dev/null 2>&1; then
  fail "curl|bash should fail validation"
else
  pass "curl|bash fails validation"
fi
# Sidecar trust anchor must fail validation
printf '%s\n' "cd /home/aella && curl -fsSLo ${LAUNCHER}.download ${MIRROR}/client/${LAUNCHER} && curl -fsSLo ${LAUNCHER}.sha256 ${MIRROR}/client/${LAUNCHER}.sha256 && sha256sum -c ${LAUNCHER}.sha256 && mv -f ${LAUNCHER}.download ${LAUNCHER} && bash ./${LAUNCHER}" \
  >"${WORKDIR}/sidecar.sh"
if mm_wf_validate_os_hop_launcher_at "${WORKDIR}/sidecar.sh" 1 "$HOP" "$MIRROR" >/dev/null 2>&1; then
  fail "HTTP sidecar trust should fail validation"
else
  pass "HTTP sidecar trust fails validation"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_dp_client_command_execution PASS ==="
  echo "GENERATED_LAUNCHER_EXECUTION_TEST=PASS"
  exit 0
fi
echo "=== test_dp_client_command_execution FAIL ==="
exit 1
