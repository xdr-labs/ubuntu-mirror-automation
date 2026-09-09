#!/usr/bin/env bash
# P0: public-keyring exact trust — reject attacker-extra-key bypass.
# Hermetic: legitimate key + attacker key; attacker-signed runner must not execute.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/local_client_signing.sh
source "${ROOT}/scripts/lib/local_client_signing.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"; [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true' EXIT

echo "=== test_keyring_exact_trust_binding ==="

gen_key() {
  local home="$1" name="$2" email="$3"
  mkdir -p "$home"
  chmod 700 "$home"
  cat >"${home}/batch" <<EOF
Key-Type: RSA
Key-Length: 2048
Name-Real: ${name}
Name-Email: ${email}
Expire-Date: 0
%no-protection
%commit
EOF
  gpg --homedir "$home" --batch --gen-key "${home}/batch" >/dev/null 2>&1
}

# Legitimate Mirror signing key
LEG_HOME="${WORKDIR}/gnupg-legit"
gen_key "$LEG_HOME" "Legit Mirror" "legit@local"
LEG_PUB="${WORKDIR}/legit-public.gpg"
LEG_PRIV="${WORKDIR}/legit-private.gpg"
gpg --homedir "$LEG_HOME" --batch --export --armor >"$LEG_PUB"
gpg --homedir "$LEG_HOME" --batch --export-secret-keys --armor >"$LEG_PRIV"
LEG_FPR="$(local_signing_fingerprint_of "$LEG_PUB")"
LEG_KR="${WORKDIR}/legit-keyring.gpg"
local_signing_build_binary_keyring "$LEG_PUB" "$LEG_KR"
LEG_SHA="$(sha256sum "$LEG_KR" | awk '{print $1}')"

# Attacker key
ATK_HOME="${WORKDIR}/gnupg-atk"
gen_key "$ATK_HOME" "Attacker" "attacker@evil"
ATK_PUB="${WORKDIR}/atk-public.gpg"
gpg --homedir "$ATK_HOME" --batch --export --armor >"$ATK_PUB"
ATK_FPR="$(local_signing_fingerprint_of "$ATK_PUB")"

# Combined keyring: legit + attacker (fingerprint gate would pass without SHA pin)
COMBINED="${WORKDIR}/combined-keyring.gpg"
{
  cat "$LEG_KR"
  gpg --batch --dearmor <"$ATK_PUB"
} >"$COMBINED"
COMBINED_SHA="$(sha256sum "$COMBINED" | awk '{print $1}')"
[[ "$COMBINED_SHA" != "$LEG_SHA" ]] \
  && pass "combined keyring SHA differs from legit" \
  || fail "combined SHA unexpectedly equals legit"

# One-byte modified keyring
MODIFIED="${WORKDIR}/modified-keyring.gpg"
cp "$LEG_KR" "$MODIFIED"
printf '\x00' | dd of="$MODIFIED" bs=1 seek=0 conv=notrunc status=none 2>/dev/null \
  || python3 -c "p='$MODIFIED'; d=open(p,'rb').read(); open(p,'wb').write(bytes([d[0]^1])+d[1:])"
MOD_SHA="$(sha256sum "$MODIFIED" | awk '{print $1}')"
[[ "$MOD_SHA" != "$LEG_SHA" ]] && pass "one-byte modified SHA differs" || fail "modified SHA same"

HTTP_ROOT="${WORKDIR}/http"
HOP="xenial-to-bionic"
SCRIPT="dp-offline-upgrade-${HOP}.sh"
mkdir -p "${HTTP_ROOT}/client/${HOP}"

# Stub hop script that must NOT run for malicious cases
printf '#!/bin/bash\necho RUNNER_EXECUTED\nexit 0\n' >"${HTTP_ROOT}/client/${SCRIPT}"
chmod 0755 "${HTTP_ROOT}/client/${SCRIPT}"
SCRIPT_SHA="$(sha256sum "${HTTP_ROOT}/client/${SCRIPT}" | awk '{print $1}')"
( cd "${HTTP_ROOT}/client" && sha256sum "$SCRIPT" >"${SCRIPT}.sha256" )

install -m 0755 "${ROOT}/client/dp-client-command-runner.sh" \
  "${HTTP_ROOT}/client/dp-client-command-runner.sh"
LOCAL_SIGNING_PRIVATE_KEY="$LEG_PRIV"
LOCAL_SIGNING_PUBLIC_KEY="$LEG_PUB"
LOCAL_KEY_FINGERPRINT="$LEG_FPR"
local_signing_stage_command_runner "${HTTP_ROOT}/client" \
  "${ROOT}/client/dp-client-command-runner.sh"

cat >"${HTTP_ROOT}/client/client-set.env" <<EOF
CLIENT_SET_GENERATION_ID=keyring-trust-fixture
CLIENT_SIGNING_FINGERPRINT=${LEG_FPR}
MIRROR_HTTP_URL=http://127.0.0.1
PREPARATION_MODE=FULL
EOF

write_manifest() {
  local signer_home="$1"
  python3 - "$HOP" "$SCRIPT" "$SCRIPT_SHA" \
    "${HTTP_ROOT}/client/${HOP}/client-manifest.json" <<'PY'
import json, sys
hop, script, sha, path = sys.argv[1:5]
open(path, "w", encoding="utf-8").write(json.dumps({
    "hop": hop,
    "script": script,
    "script_sha256": sha,
}, indent=2) + "\n")
PY
  gpg --homedir "$signer_home" --batch --yes --detach-sign --armor \
    -o "${HTTP_ROOT}/client/${HOP}/client-manifest.json.asc" \
    "${HTTP_ROOT}/client/${HOP}/client-manifest.json" >/dev/null 2>&1
}

# Legitimate signed hop manifest
write_manifest "$LEG_HOME"

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
  --signing-fingerprint "$LEG_FPR" \
  --expected-keyring-sha256 "$LEG_SHA" >/dev/null

LAUNCHER="${HTTP_ROOT}/client/dp-launch-${HOP}.sh"
grep -q "EXPECTED_KEYRING_SHA256='${LEG_SHA}'" "$LAUNCHER" \
  && pass "launcher embeds keyring SHA" || fail "launcher missing keyring SHA"

run_launcher() {
  local kr_src="$1"
  local out="$2"
  cp -f "$kr_src" "${HTTP_ROOT}/client/public-keyring.gpg"
  set +e
  (
    cd "$(mktemp -d)"
    # Avoid real sudo: stub for runner final exec is still after trust checks.
    export PATH="${WORKDIR}/bin:${PATH}"
    mkdir -p "${WORKDIR}/bin"
    printf '#!/bin/bash\necho SUDO_STUB\nexit 0\n' >"${WORKDIR}/bin/sudo"
    chmod +x "${WORKDIR}/bin/sudo"
    bash "$LAUNCHER"
  ) >"$out" 2>&1
  echo $?
  set -e
}

# --- PASS: correct legitimate keyring ---
cp -f "$LEG_KR" "${HTTP_ROOT}/client/public-keyring.gpg"
# Re-sign runner-manifest with legit (already staged)
rc="$(run_launcher "$LEG_KR" "${WORKDIR}/out-pass.txt")"
if [[ "$rc" -eq 0 ]] && ! grep -q 'KEYRING_TRUST=FAIL' "${WORKDIR}/out-pass.txt"; then
  pass "correct keyring accepted"
else
  fail "correct keyring should PASS (rc=${rc})"
  tail -30 "${WORKDIR}/out-pass.txt" || true
fi

# --- FAIL: one-byte modified keyring ---
rc="$(run_launcher "$MODIFIED" "${WORKDIR}/out-mod.txt")"
if [[ "$rc" -ne 0 ]] && grep -q 'KEYRING_TRUST=FAIL' "${WORKDIR}/out-mod.txt"; then
  pass "one-byte-modified keyring rejected"
else
  fail "modified keyring should FAIL (rc=${rc})"
  tail -30 "${WORKDIR}/out-mod.txt" || true
fi

# --- FAIL: combined legit+attacker keyring with attacker-signed runner manifest ---
# Replace runner-manifest signature with attacker signature while keeping
# runner bytes; also resign hop client-manifest with attacker.
cp -f "$COMBINED" "${HTTP_ROOT}/client/public-keyring.gpg"
gpg --homedir "$ATK_HOME" --batch --yes --detach-sign --armor \
  -o "${HTTP_ROOT}/client/runner-manifest.asc" \
  "${HTTP_ROOT}/client/runner-manifest" >/dev/null 2>&1
write_manifest "$ATK_HOME"

rc="$(run_launcher "$COMBINED" "${WORKDIR}/out-atk.txt")"
if [[ "$rc" -ne 0 ]] \
   && grep -q 'KEYRING_TRUST=FAIL' "${WORKDIR}/out-atk.txt" \
   && ! grep -q 'RUNNER_EXECUTED\|SUDO_STUB' "${WORKDIR}/out-atk.txt"; then
  pass "attacker extra key + malicious signature rejected (KEYRING_TRUST=FAIL)"
else
  fail "attacker keyring must FAIL before runner execute (rc=${rc})"
  tail -40 "${WORKDIR}/out-atk.txt" || true
fi

# Independent runner check with wrong SHA
cp -f "$LEG_KR" "${HTTP_ROOT}/client/public-keyring.gpg"
write_manifest "$LEG_HOME"
set +e
(
  cd "$(mktemp -d)"
  curl -fsSLo public-keyring.gpg "${MIRROR}/client/public-keyring.gpg"
  bash "${HTTP_ROOT}/client/dp-client-command-runner.sh" \
    "$MIRROR" "$HOP" "$SCRIPT" "$LEG_FPR" "$COMBINED_SHA"
) >"${WORKDIR}/out-runner-sha.txt" 2>&1
rrc=$?
set -e
if [[ "$rrc" -ne 0 ]] && grep -q 'KEYRING_TRUST=FAIL' "${WORKDIR}/out-runner-sha.txt"; then
  pass "runner independently rejects keyring SHA mismatch"
else
  fail "runner SHA mismatch should FAIL (rc=${rrc})"
  tail -20 "${WORKDIR}/out-runner-sha.txt" || true
fi

[[ "$FAIL" -eq 0 ]]
echo "=== test_keyring_exact_trust_binding: DONE ==="
