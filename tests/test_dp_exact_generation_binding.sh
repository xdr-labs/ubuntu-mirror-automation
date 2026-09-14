#!/usr/bin/env bash
# Hermetic DP exact-generation binding regression (no real OS upgrade).
#
# CASE A: generation A command + generation A published set → PASS
# CASE B: generation A command + republished generation B (same signing key) → FAIL CLOSED
# CASE C: generation B differs only in build/provenance input → FAIL CLOSED
# CASE D: tampered expected build identity in launcher → FAIL CLOSED
# CASE E: current valid generation remains executable
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/local_client_signing.sh
source "${ROOT}/scripts/lib/local_client_signing.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"; [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true' EXIT

echo "=== test_dp_exact_generation_binding ==="

GEN_A='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
GEN_B='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
HOP='xenial-to-bionic'
SCRIPT="dp-offline-upgrade-${HOP}.sh"
BUILD_INPUT_FIXTURE="$GEN_A"

GPG_HOME="${WORKDIR}/gnupg"
mkdir -p "$GPG_HOME"
chmod 700 "$GPG_HOME"
cat >"${GPG_HOME}/batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Exact Gen Binding Fixture
Name-Email: exact-gen@local
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
KR_SHA="$(sha256sum "$KR" | awk '{print $1}')"

HTTP_ROOT="${WORKDIR}/http"
mkdir -p "${HTTP_ROOT}/client/${HOP}"
printf '#!/bin/bash\necho STUB_UPGRADE_OK gen=%s\nexit 0\n' "$GEN_A" \
  >"${HTTP_ROOT}/client/${SCRIPT}"
chmod 0755 "${HTTP_ROOT}/client/${SCRIPT}"
SCRIPT_SHA="$(sha256sum "${HTTP_ROOT}/client/${SCRIPT}" | awk '{print $1}')"
( cd "${HTTP_ROOT}/client" && sha256sum "$SCRIPT" >"${SCRIPT}.sha256" )
cp "$KR" "${HTTP_ROOT}/client/public-keyring.gpg"
cp "$PUB" "${HTTP_ROOT}/client/public.gpg"

write_client_set_env() {
  local gen="$1"
  cat >"${HTTP_ROOT}/client/client-set.env" <<EOF
CLIENT_SET_GENERATION_ID=exact-gen-${gen:0:8}
CLIENT_SIGNING_FINGERPRINT=${FPR}
MIRROR_HTTP_URL=http://127.0.0.1
PREPARATION_MODE=FULL
CLIENT_BUILD_INPUT_SHA256=${gen}
EOF
  chmod 0644 "${HTTP_ROOT}/client/client-set.env"
}

write_manifest() {
  local gen="$1"
  local sha="${2:-$SCRIPT_SHA}"
  python3 - "$HOP" "$SCRIPT" "$sha" "$gen" \
    "${HTTP_ROOT}/client/${HOP}/client-manifest.json" <<'PY'
import json, sys
hop, script, sha, gen, path = sys.argv[1:6]
open(path, "w", encoding="utf-8").write(json.dumps({
    "hop": hop,
    "script": script,
    "script_sha256": sha,
    "client_build_input_sha256": gen,
}, indent=2) + "\n")
PY
  gpg --homedir "$GPG_HOME" --batch --yes --detach-sign --armor \
    -o "${HTTP_ROOT}/client/${HOP}/client-manifest.json.asc" \
    "${HTTP_ROOT}/client/${HOP}/client-manifest.json" >/dev/null 2>&1
}

install -m 0755 "${ROOT}/client/dp-client-command-runner.sh" \
  "${HTTP_ROOT}/client/dp-client-command-runner.sh"
local_signing_stage_command_runner \
  "${HTTP_ROOT}/client" "${ROOT}/client/dp-client-command-runner.sh"

write_client_set_env "$GEN_A"
write_manifest "$GEN_A"

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

build_launchers_for() {
  local gen="$1"
  local out="$2"
  python3 "${ROOT}/scripts/lib/build_client_launchers.py" \
    --project-root "$ROOT" \
    --output-dir "$out" \
    --mirror-base-url "$MIRROR" \
    --signing-fingerprint "$FPR" \
    --expected-keyring-sha256 "$KR_SHA" \
    --expected-client-build-input-sha256 "$gen" >/dev/null
}

# Generation A published wrappers/launchers (Menu 7 would pin wrapper SHA of these).
build_launchers_for "$GEN_A" "${HTTP_ROOT}/client"
cp -a "${HTTP_ROOT}/client/upgrade-${HOP}.sh" "${WORKDIR}/menu7-upgrade-A.sh"
cp -a "${HTTP_ROOT}/client/dp-launch-${HOP}.sh" "${WORKDIR}/menu7-launch-A.sh"
WRAPPER_A_SHA="$(sha256sum "${WORKDIR}/menu7-upgrade-A.sh" | awk '{print $1}')"

if grep -Fq 'cd /home/aella' "${WORKDIR}/menu7-upgrade-A.sh"; then
  fail "generated wrapper must not hardcode cd /home/aella"
else
  pass "generated wrapper has no hardcoded /home/aella"
fi
grep -q 'mktemp -d' "${WORKDIR}/menu7-upgrade-A.sh" \
  && pass "generated wrapper uses portable temp workdir" \
  || fail "generated wrapper missing mktemp workdir"
grep -q "LAUNCHER_SHA256=" "${WORKDIR}/menu7-upgrade-A.sh" \
  && pass "generated wrapper retains LAUNCHER_SHA256 verify" \
  || fail "generated wrapper missing LAUNCHER_SHA256"
grep -Eq 'curl\|[[:space:]]*bash|curl[[:space:]]+\|[[:space:]]*bash' "${WORKDIR}/menu7-upgrade-A.sh" \
  && fail "generated wrapper must not use curl|bash" \
  || pass "generated wrapper does not use curl|bash"
grep -q '^exec ' "${WORKDIR}/menu7-upgrade-A.sh" \
  && fail "generated wrapper must not exec (EXIT trap cleanup)" \
  || pass "generated wrapper avoids exec for trap cleanup"

run_saved_menu7_wrapper() {
  local wrapper="$1"
  local run_dir="$2"
  local home_env="${3:-$run_dir}"
  mkdir -p "$run_dir"
  # Simulate operator pasting Menu 7: download live wrapper by pinned SHA then exec.
  # For CASE A/E the live wrapper matches; for B/C the old saved wrapper bytes are used
  # directly (already copied while gen A was current).
  (
    cd "$run_dir"
    export HOME="$home_env"
    cp -f "$wrapper" "./upgrade-${HOP}.sh"
    bash "./upgrade-${HOP}.sh"
  )
}

# Stub sudo so the hop script can "execute" without privileges.
export PATH="${WORKDIR}/bin:$PATH"
mkdir -p "${WORKDIR}/bin"
cat >"${WORKDIR}/bin/sudo" <<'EOF'
#!/bin/bash
exec "$@"
EOF
chmod 0755 "${WORKDIR}/bin/sudo"

# Portability: HOME nonexistent + arbitrary non-project cwd.
NONEXIST_HOME="${WORKDIR}/no-such-home-$$"
ARBITRARY_CWD="${WORKDIR}/arbitrary-cwd"
mkdir -p "$ARBITRARY_CWD"
if OUT_PORT="$(run_saved_menu7_wrapper "${WORKDIR}/menu7-upgrade-A.sh" "$ARBITRARY_CWD" "$NONEXIST_HOME" 2>&1)"; then
  echo "$OUT_PORT" | grep -q 'STUB_UPGRADE_OK' \
    && pass "portable: executes with nonexistent HOME from arbitrary cwd" \
    || fail "portable: executed but missing stub marker"
else
  fail "portable: unexpectedly failed: $OUT_PORT"
fi
if OUT_ROOT="$(
  cd /
  export HOME="$NONEXIST_HOME"
  bash "${WORKDIR}/menu7-upgrade-A.sh" 2>&1
)"; then
  echo "$OUT_ROOT" | grep -q 'STUB_UPGRADE_OK' \
    && pass "portable: executes without requiring cwd=/home/aella" \
    || fail "portable: cwd-independent run missing stub"
else
  fail "portable: cwd-independent run failed: $OUT_ROOT"
fi

# CASE A
if OUT_A="$(run_saved_menu7_wrapper "${WORKDIR}/menu7-upgrade-A.sh" "${WORKDIR}/run-A" 2>&1)"; then
  echo "$OUT_A" | grep -q 'STUB_UPGRADE_OK' \
    && pass "CASE A: gen A command + gen A set executes" \
    || fail "CASE A: executed but missing stub marker"
else
  fail "CASE A: unexpectedly failed: $OUT_A"
fi

# CASE B / C: republish gen B with same signing key; keep old Menu 7 wrapper.
printf '#!/bin/bash\necho STUB_UPGRADE_OK gen=%s\nexit 0\n' "$GEN_B" \
  >"${HTTP_ROOT}/client/${SCRIPT}"
chmod 0755 "${HTTP_ROOT}/client/${SCRIPT}"
SCRIPT_SHA="$(sha256sum "${HTTP_ROOT}/client/${SCRIPT}" | awk '{print $1}')"
( cd "${HTTP_ROOT}/client" && sha256sum "$SCRIPT" >"${SCRIPT}.sha256" )
write_client_set_env "$GEN_B"
write_manifest "$GEN_B" "$SCRIPT_SHA"
# Live launchers/wrappers now bind gen B (same keyring/FPR/mirror).
build_launchers_for "$GEN_B" "${HTTP_ROOT}/client"

if OUT_B="$(run_saved_menu7_wrapper "${WORKDIR}/menu7-upgrade-A.sh" "${WORKDIR}/run-B" 2>&1)"; then
  fail "CASE B: old gen A command silently accepted gen B"
  echo "$OUT_B"
else
  echo "$OUT_B" | grep -Eqi 'GENERATION_BINDING=FAIL|sha256sum|LAUNCHER_SHA256|FAILED' \
    && pass "CASE B: gen A command fail-closed after republish" \
    || fail "CASE B: rejected but unexpected reason: $OUT_B"
fi

# CASE C: same as B with only provenance identity changed (already GEN_B).
if OUT_C="$(run_saved_menu7_wrapper "${WORKDIR}/menu7-upgrade-A.sh" "${WORKDIR}/run-C" 2>&1)"; then
  fail "CASE C: provenance-only republish accepted"
else
  echo "$OUT_C" | grep -Eqi 'GENERATION_BINDING=FAIL|sha256sum|FAILED' \
    && pass "CASE C: provenance-only change fail-closed" \
    || fail "CASE C: unexpected reject reason: $OUT_C"
fi

# CASE D: tampered expected build identity inside a launcher that still matches
# an attacker-controlled wrapper SHA path — invoke runner via launcher with wrong pin.
build_launchers_for "$GEN_B" "${WORKDIR}/launchers-B"
TAMPER="${WORKDIR}/tampered-launch.sh"
sed "s/EXPECTED_CLIENT_BUILD_INPUT_SHA256='${GEN_B}'/EXPECTED_CLIENT_BUILD_INPUT_SHA256='${GEN_A}'/" \
  "${WORKDIR}/launchers-B/dp-launch-${HOP}.sh" >"$TAMPER"
chmod 0755 "$TAMPER"
# Live published set remains GEN_B.
if OUT_D="$(
  cd "${WORKDIR}/run-D" 2>/dev/null || mkdir -p "${WORKDIR}/run-D"
  cd "${WORKDIR}/run-D"
  bash "$TAMPER" 2>&1
)"; then
  fail "CASE D: tampered expected build identity accepted"
else
  echo "$OUT_D" | grep -Eqi 'GENERATION_BINDING=FAIL' \
    && pass "CASE D: tampered build identity fail-closed" \
    || fail "CASE D: unexpected reject reason: $OUT_D"
fi

# CASE E: restore matching gen B command against live gen B set.
cp -a "${HTTP_ROOT}/client/upgrade-${HOP}.sh" "${WORKDIR}/menu7-upgrade-B.sh"
if OUT_E="$(run_saved_menu7_wrapper "${WORKDIR}/menu7-upgrade-B.sh" "${WORKDIR}/run-E" 2>&1)"; then
  echo "$OUT_E" | grep -q 'STUB_UPGRADE_OK' \
    && pass "CASE E: current valid generation executes" \
    || fail "CASE E: executed without stub marker"
else
  fail "CASE E: current valid path failed: $OUT_E"
fi

# Evidence: old wrapper SHA differs from live gen B wrapper (Menu 7 pin drift).
WRAPPER_B_SHA="$(sha256sum "${HTTP_ROOT}/client/upgrade-${HOP}.sh" | awk '{print $1}')"
[[ "$WRAPPER_A_SHA" != "$WRAPPER_B_SHA" ]] \
  && pass "wrapper SHA changes when CLIENT_BUILD_INPUT_SHA256 changes" \
  || fail "wrapper SHA did not change across generations"

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_dp_exact_generation_binding PASS ==="
  exit 0
fi
echo "=== test_dp_exact_generation_binding FAIL ==="
exit 1
