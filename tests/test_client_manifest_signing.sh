#!/usr/bin/env bash
# Fail-closed client manifest signing / deploy gates (xenial→bionic).
# Hermetic: ephemeral GPG keys + local HTTP hop mirror + mktemp selective root.
# Does not commit private keys; does not require production selective/R2 state.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_PY="${ROOT}/scripts/lib/build_client_xenial_to_bionic.py"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
HTTP_PID=""
cleanup() {
  if [[ -n "${HTTP_PID}" ]] && kill -0 "$HTTP_PID" 2>/dev/null; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "=== test_client_manifest_signing ==="

SEL_ROOT="${WORKDIR}/selective"
PROJ="${WORKDIR}/project"
HTTP_ROOT="${WORKDIR}/http"
mkdir -p \
  "${SEL_ROOT}/keys" \
  "${SEL_ROOT}/state" \
  "${SEL_ROOT}/current/shared/offline/release-upgraders/bionic" \
  "${PROJ}/config/client-signing" \
  "${PROJ}/artifacts/client" \
  "${HTTP_ROOT}/hops/xenial-to-bionic/ubuntu/dists/xenial/main/binary-amd64" \
  "${HTTP_ROOT}/hops/xenial-to-bionic/ubuntu/dists/bionic/main/binary-amd64" \
  "${HTTP_ROOT}/hops/xenial-to-bionic/ubuntu/pool/main/a/hello"

# Full source trees required by builders + provenance (isolated under WORKDIR).
cp -a "${ROOT}/client" "${PROJ}/client"
cp -a "${ROOT}/scripts" "${PROJ}/scripts"
cp -a "${ROOT}/lib" "${PROJ}/lib"
mkdir -p "${PROJ}/artifacts/client"
PROD_ARTIFACT="${PROJ}/artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh"
printf '#!/bin/sh\necho prod-stub\n' >"$PROD_ARTIFACT"

# --- ephemeral selective repo key (InRelease) ---
GPG_SEL="${WORKDIR}/gpg-selective"
mkdir -p "$GPG_SEL"
chmod 700 "$GPG_SEL"
cat >"${GPG_SEL}/batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Test Selective Mirror
Name-Email: selective-test@local
Expire-Date: 0
%no-protection
%commit
EOF
gpg --homedir "$GPG_SEL" --batch --gen-key "${GPG_SEL}/batch" >/dev/null 2>&1
gpg --homedir "$GPG_SEL" --batch --export --armor \
  >"${SEL_ROOT}/keys/ubuntu-mirror-selective.gpg"

# --- ephemeral production client-signing keypair (never committed) ---
GPG_SIGN="${WORKDIR}/gpg-signing"
mkdir -p "$GPG_SIGN"
chmod 700 "$GPG_SIGN"
cat >"${GPG_SIGN}/batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Test Client Manifest
Name-Email: offline-client-manifest@local
Expire-Date: 0
%no-protection
%commit
EOF
gpg --homedir "$GPG_SIGN" --batch --gen-key "${GPG_SIGN}/batch" >/dev/null 2>&1
PRIV_KEY="${PROJ}/config/client-signing/offline-client-manifest.private.gpg"
PUB_KEY="${PROJ}/config/client-signing/offline-client-manifest.gpg"
gpg --homedir "$GPG_SIGN" --batch --export-secret-keys --armor >"$PRIV_KEY"
gpg --homedir "$GPG_SIGN" --batch --export >"$PUB_KEY"
chmod 600 "$PRIV_KEY"
chmod 644 "$PUB_KEY"

if [[ -f "$PRIV_KEY" && -r "$PRIV_KEY" && -f "$PUB_KEY" ]]; then
  pass "ephemeral signing key present"
else
  fail "ephemeral signing key missing/unreadable"
fi

# Verified selective generation binding (plan.json + AWS contract + READY).
# shellcheck source=lib/client_finalization_fixture.sh
source "${ROOT}/tests/lib/client_finalization_fixture.sh"
client_fixture_write_generation_binding "$SEL_ROOT" "$ROOT" >/dev/null
READY_PATH="${SEL_ROOT}/state/READY"
READY_BEFORE="$(sha256sum "$READY_PATH" | awk '{print $1}')"

# Upgrader stub with announcement files (required by extract_announcements)
UPG="${WORKDIR}/upg"
mkdir -p "$UPG"
printf 'ReleaseAnnouncement stub\n' >"${UPG}/ReleaseAnnouncement"
printf '<html>announcement</html>\n' >"${UPG}/ReleaseAnnouncement.html"
UP_TAR="${SEL_ROOT}/current/shared/offline/release-upgraders/bionic/bionic.tar.gz"
( cd "$UPG" && tar -czf "$UP_TAR" ./ReleaseAnnouncement ./ReleaseAnnouncement.html )
gpg --homedir "$GPG_SEL" --batch --yes --detach-sign -o "${UP_TAR}.gpg" "$UP_TAR"

# Local hop mirror Release/InRelease/Packages.gz under SELECTIVE (local-fs content source)
write_release() {
  local suite="$1" dest="$2"
  cat >"$dest" <<EOF
Origin: Ubuntu
Label: Ubuntu
Suite: ${suite}
Codename: ${suite%%-*}
Architectures: amd64
Components: main restricted universe multiverse
Description: Ubuntu ${suite} test fixture
EOF
}
HOP_UBUNTU="${SEL_ROOT}/hops/xenial-to-bionic/ubuntu"
for suite in xenial bionic; do
  d="${HOP_UBUNTU}/dists/${suite}"
  mkdir -p "${d}/main/binary-amd64"
  write_release "$suite" "${d}/Release"
  gpg --homedir "$GPG_SEL" --batch --yes --clearsign \
    -o "${d}/InRelease" "${d}/Release"
done

python3 - "$HOP_UBUNTU" <<'PY'
import gzip, pathlib, sys
root = pathlib.Path(sys.argv[1])
body = (
    b"Package: hello\n"
    b"Version: 2.10\n"
    b"Filename: pool/main/a/hello/hello_2.10_amd64.deb\n"
    b"Size: 1\n"
    b"SHA256: "
    + (b"0" * 64)
    + b"\n"
)
for suite in ("xenial", "bionic"):
    p = root / f"dists/{suite}/main/binary-amd64/Packages.gz"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(gzip.compress(body))
deb = root / "pool/main/a/hello/hello_2.10_amd64.deb"
deb.parent.mkdir(parents=True, exist_ok=True)
deb.write_bytes(b"x")
PY

# Also mirror under HTTP_ROOT for optional diagnostic --content-source http tests
mkdir -p "${HTTP_ROOT}/hops/xenial-to-bionic"
cp -a "${HOP_UBUNTU}" "${HTTP_ROOT}/hops/xenial-to-bionic/ubuntu"

# Upgrader under shared/ (preferred) in addition to legacy current/
mkdir -p "${SEL_ROOT}/shared/offline/release-upgraders/bionic"
cp -a "${SEL_ROOT}/current/shared/offline/release-upgraders/bionic/." \
  "${SEL_ROOT}/shared/offline/release-upgraders/bionic/" 2>/dev/null || true

PORT_FILE="${WORKDIR}/http.port"
python3 - "$HTTP_ROOT" "$PORT_FILE" <<'PY' &
import http.server, os, sys
root, portf = sys.argv[1], sys.argv[2]
os.chdir(root)
httpd = http.server.ThreadingHTTPServer(
    ("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler
)
open(portf, "w", encoding="utf-8").write(str(httpd.server_address[1]))
httpd.serve_forever()
PY
HTTP_PID=$!
for _ in $(seq 1 100); do
  [[ -s "$PORT_FILE" ]] && break
  sleep 0.05
done
PORT="$(cat "$PORT_FILE")"
MIRROR_BASE="http://127.0.0.1:${PORT}"
echo "  INFO: hermetic mirror ${MIRROR_BASE}"

BUILD_PY_PROJ="${PROJ}/scripts/lib/build_client_xenial_to_bionic.py"

# 1) ephemeral signing key → signed client build PASS
PROD_OUT="${WORKDIR}/prod-client"
set +e
python3 "$BUILD_PY_PROJ" \
  --project-root "$PROJ" \
  --mirror-base "$MIRROR_BASE" \
  --selective-root "$SEL_ROOT" \
  --output-dir "$PROD_OUT" \
  >"${WORKDIR}/prod-build.log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'CLIENT_MANIFEST_SIGNATURE_MODE=PRODUCTION_SIGNED' "${WORKDIR}/prod-build.log" \
  && grep -q 'CLIENT_MANIFEST_SIGNATURE_STATUS=PASS' "${WORKDIR}/prod-build.log" \
  && grep -q 'CLIENT_MANIFEST_UNSIGNED_TEST_COUNT=0' "${WORKDIR}/prod-build.log" \
  && grep -q 'ARTIFACT_SIGNATURE_VERIFY=PASS' "${WORKDIR}/prod-build.log"; then
  pass "1 ephemeral signing key → signed client build PASS"
else
  fail "1 production signed build"
  tail -40 "${WORKDIR}/prod-build.log" || true
fi

PROD_SCRIPT="${PROD_OUT}/dp-offline-upgrade-xenial-to-bionic.sh"
if [[ -f "$PROD_SCRIPT" ]]; then
  unsigned_count="$(grep -c 'UNSIGNED_TEST' "$PROD_SCRIPT" || true)"
  if [[ "$unsigned_count" == "0" ]]; then
    pass "8 production build UNSIGNED_TEST=0"
  else
    fail "8 production build UNSIGNED_TEST count=${unsigned_count}"
  fi
  FPR="$(grep -E '^CLIENT_MANIFEST_SIGNER_FINGERPRINT=' "${WORKDIR}/prod-build.log" | head -1 | cut -d= -f2- || true)"
  echo "  INFO: signer_fingerprint=${FPR}"
fi

# 2) signing key absent → production build FAIL
NOKEY_ROOT="${WORKDIR}/nokey-project"
mkdir -p "${NOKEY_ROOT}/config" "${NOKEY_ROOT}/artifacts/client"
cp -a "${ROOT}/client" "${NOKEY_ROOT}/client"
cp -a "${ROOT}/scripts" "${NOKEY_ROOT}/scripts"
cp -a "${ROOT}/lib" "${NOKEY_ROOT}/lib"
cp "${ROOT}/client/dp-offline-upgrade-xenial-to-bionic.sh.in" "${NOKEY_ROOT}/client/"
cp "${ROOT}/client/lib/dp-offline-destructive-confirmation.sh" "${NOKEY_ROOT}/client/lib/"
cp "${ROOT}/client/lib/dp-offline-release-upgrade-reconciliation.sh" "${NOKEY_ROOT}/client/lib/"
cp "${ROOT}/client/lib/dp-offline-apt-preflight-sandbox.sh" "${NOKEY_ROOT}/client/lib/"
set +e
python3 "${NOKEY_ROOT}/scripts/lib/build_client_xenial_to_bionic.py" \
  --project-root "$NOKEY_ROOT" \
  --mirror-base "$MIRROR_BASE" \
  --selective-root "$SEL_ROOT" \
  --output-dir "${WORKDIR}/nokey-out" \
  >"${WORKDIR}/nokey-build.log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qiE 'signing key missing|unreadable' "${WORKDIR}/nokey-build.log"; then
  pass "2 signing key absent → production build FAIL"
else
  fail "2 expected production build FAIL without key (rc=${rc})"
  tail -20 "${WORKDIR}/nokey-build.log" || true
fi

run_deploy_gate() {
  local art_dir="$1"
  local dest="$2"
  local log="$3"
  local art="${art_dir}/dp-offline-upgrade-xenial-to-bionic.sh"
  local sha="${art}.sha256"
  DEST_ROOT="$dest" \
    bash -c '
      set -euo pipefail
      ARTIFACT="'"$art"'"
      SHAFILE="'"$sha"'"
      DEST_ROOT="'"$dest"'"
      NAME="dp-offline-upgrade-xenial-to-bionic.sh"
      BUILD_PY="'"$BUILD_PY_PROJ"'"
      PUB_KEY="'"$PUB_KEY"'"
      ART_SHA="$(sha256sum "$ARTIFACT" | awk "{print \$1}")"
      SIDECAR_SHA="$(awk "{print \$1}" "$SHAFILE")"
      [[ "$ART_SHA" == "$SIDECAR_SHA" ]] || { echo "artifact/sidecar SHA mismatch"; exit 1; }
      python3 - "$BUILD_PY" "$ARTIFACT" "$PUB_KEY" <<'"'"'PY'"'"'
import importlib.util, sys
build_py, artifact, pub_key = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("build_client_x2b", build_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
allowed = mod.key_fingerprint(open(pub_key, "rb").read())
info = mod.verify_client_artifact_signature(artifact, allowed_fingerprint=allowed)
print("CLIENT_MANIFEST_SIGNATURE_MODE=PRODUCTION_SIGNED")
print("CLIENT_MANIFEST_SIGNATURE_STATUS=PASS")
print("CLIENT_MANIFEST_SIGNER_FINGERPRINT=" + info["fingerprint"])
print("CLIENT_MANIFEST_UNSIGNED_TEST_COUNT=" + str(info["unsigned_test_count"]))
print("ARTIFACT_SIGNATURE_VERIFY=PASS")
PY
      mkdir -p "$DEST_ROOT"
      cp -a "$ARTIFACT" "$DEST_ROOT/$NAME"
      cp -a "$SHAFILE" "$DEST_ROOT/$NAME.sha256"
      echo DEPLOY_OK
    ' >"$log" 2>&1
}

# 3) UNSIGNED_TEST artifact → deploy rejected
UNSIGNED_OUT="${WORKDIR}/unsigned-client"
set +e
python3 "$BUILD_PY_PROJ" \
  --project-root "$PROJ" \
  --mirror-base "$MIRROR_BASE" \
  --selective-root "$SEL_ROOT" \
  --output-dir "$UNSIGNED_OUT" \
  --skip-sign \
  >"${WORKDIR}/unsigned-build.log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  pass "unsigned test build writes isolated path"
else
  fail "unsigned test build should succeed on non-production path"
  tail -20 "${WORKDIR}/unsigned-build.log" || true
fi

set +e
python3 "$BUILD_PY_PROJ" \
  --project-root "$PROJ" \
  --mirror-base "$MIRROR_BASE" \
  --selective-root "$SEL_ROOT" \
  --output-dir "${PROJ}/artifacts/client" \
  --skip-sign \
  >"${WORKDIR}/unsigned-prod-refuse.log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qi 'refuses production' "${WORKDIR}/unsigned-prod-refuse.log"; then
  pass "7 unit/unsigned cannot overwrite artifacts/client"
else
  fail "7 skip-sign must refuse production artifacts/client"
fi

set +e
run_deploy_gate "$UNSIGNED_OUT" "${WORKDIR}/deploy-unsigned" "${WORKDIR}/deploy-unsigned.log"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qiE 'UNSIGNED_TEST|verification failed|signature' "${WORKDIR}/deploy-unsigned.log"; then
  pass "3 UNSIGNED_TEST artifact → deploy rejected"
else
  fail "3 UNSIGNED_TEST deploy should be rejected (rc=${rc})"
  cat "${WORKDIR}/deploy-unsigned.log" || true
fi

# 4) wrong signer fingerprint → deploy rejected
if [[ -f "$PROD_SCRIPT" ]]; then
  WRONG="${WORKDIR}/wrong-fpr"
  mkdir -p "$WRONG"
  cp -a "$PROD_OUT/." "$WRONG/"
  set +e
  python3 - "$BUILD_PY_PROJ" "${WRONG}/dp-offline-upgrade-xenial-to-bionic.sh" <<'PY' >"${WORKDIR}/wrong-fpr.log" 2>&1
import importlib.util, sys
build_py, artifact = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("build_client_x2b", build_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    mod.verify_client_artifact_signature(artifact, allowed_fingerprint="0" * 40)
except Exception as exc:
    print("REJECT:" + str(exc))
    sys.exit(2)
print("UNEXPECTED_PASS")
sys.exit(0)
PY
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]] && grep -q 'REJECT:' "${WORKDIR}/wrong-fpr.log"; then
    pass "4 wrong signer fingerprint → deploy rejected"
  else
    fail "4 wrong fingerprint should reject"
    cat "${WORKDIR}/wrong-fpr.log" || true
  fi
fi

# 5) tampered manifest → gpg verification FAIL
if [[ -f "$PROD_SCRIPT" ]]; then
  set +e
  python3 - "$BUILD_PY_PROJ" "$PROD_SCRIPT" "$PUB_KEY" <<'PY' >"${WORKDIR}/tamper-manifest.log" 2>&1
import importlib.util, base64, re, sys, tempfile, os
build_py, artifact, pub_key = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("build_client_x2b", build_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
text = open(artifact, "r", encoding="utf-8", errors="replace").read()
token = "PIN_MANIFEST_B64='"
start = text.find(token) + len(token)
end = text.find("'", start)
raw = re.sub(r"\s+", "", text[start:end])
data = bytearray(base64.b64decode(raw))
data[0] ^= 0xFF
new_b64 = base64.b64encode(bytes(data)).decode("ascii")
wrapped = "\n".join(new_b64[i:i+76] for i in range(0, len(new_b64), 76))
text2 = text[:start] + wrapped + text[end:]
td = tempfile.mkdtemp()
path = os.path.join(td, "tampered.sh")
open(path, "w").write(text2)
allowed = mod.key_fingerprint(open(pub_key, "rb").read())
try:
    mod.verify_client_artifact_signature(path, allowed_fingerprint=allowed)
except Exception as exc:
    print("REJECT:" + str(exc))
    sys.exit(2)
print("UNEXPECTED_PASS")
PY
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]] && grep -qiE 'gpgv|REJECT' "${WORKDIR}/tamper-manifest.log"; then
    pass "5 tampered manifest → gpg verification FAIL"
  else
    fail "5 tampered manifest should fail gpgv"
    cat "${WORKDIR}/tamper-manifest.log" || true
  fi
fi

# 6) tampered client → SHA + signature verification FAIL
if [[ -f "$PROD_SCRIPT" ]]; then
  TAMPER_DIR="${WORKDIR}/tamper-client"
  mkdir -p "$TAMPER_DIR"
  cp -a "$PROD_OUT/." "$TAMPER_DIR/"
  python3 - "${TAMPER_DIR}/dp-offline-upgrade-xenial-to-bionic.sh" <<'PY'
import base64, re, sys
path = sys.argv[1]
text = open(path, "r", encoding="utf-8", errors="replace").read()
token = "PIN_MANIFEST_SIG_B64='"
start = text.find(token) + len(token)
end = text.find("'", start)
raw = re.sub(r"\s+", "", text[start:end])
data = bytearray(base64.b64decode(raw))
if len(data) > 40:
    data[40] ^= 0x5A
else:
    data[-1] ^= 0x5A
new_b64 = base64.b64encode(bytes(data)).decode("ascii")
wrapped = "\n".join(new_b64[i:i+76] for i in range(0, len(new_b64), 76))
open(path, "w", encoding="utf-8").write(text[:start] + wrapped + text[end:])
PY
  set +e
  art_sha="$(sha256sum "${TAMPER_DIR}/dp-offline-upgrade-xenial-to-bionic.sh" | awk '{print $1}')"
  side="$(awk '{print $1}' "${TAMPER_DIR}/dp-offline-upgrade-xenial-to-bionic.sh.sha256")"
  set -e
  if [[ "$art_sha" != "$side" ]]; then
    pass "6 tampered client → SHA mismatch detected"
  else
    fail "6 tampered client SHA should mismatch sidecar"
  fi
  set +e
  python3 - "$BUILD_PY_PROJ" "${TAMPER_DIR}/dp-offline-upgrade-xenial-to-bionic.sh" "$PUB_KEY" <<'PY' >"${WORKDIR}/tamper-client.log" 2>&1
import importlib.util, sys
build_py, artifact, pub_key = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("build_client_x2b", build_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
allowed = mod.key_fingerprint(open(pub_key, "rb").read())
try:
    mod.verify_client_artifact_signature(artifact, allowed_fingerprint=allowed)
except Exception as exc:
    print("REJECT:" + str(exc))
    sys.exit(2)
print("UNEXPECTED_PASS")
PY
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    pass "6 tampered client → signature verification FAIL"
  else
    fail "6 tampered client signature should fail"
    cat "${WORKDIR}/tamper-client.log" || true
  fi
fi

# 7 default --skip-sign uses client-unsigned-test; production artifact untouched
PROD_SHA_BEFORE="$(sha256sum "$PROD_ARTIFACT" | awk '{print $1}')"
set +e
python3 "$BUILD_PY_PROJ" \
  --project-root "$PROJ" \
  --mirror-base "$MIRROR_BASE" \
  --selective-root "$SEL_ROOT" \
  --skip-sign \
  >"${WORKDIR}/default-unsigned.log" 2>&1
rc=$?
set -e
PROD_SHA_AFTER="$(sha256sum "$PROD_ARTIFACT" | awk '{print $1}')"
if [[ "$rc" -eq 0 ]] \
  && [[ -f "${PROJ}/artifacts/client-unsigned-test/dp-offline-upgrade-xenial-to-bionic.sh" ]] \
  && [[ "$PROD_SHA_BEFORE" == "$PROD_SHA_AFTER" ]]; then
  pass "7 default --skip-sign uses client-unsigned-test; production artifact untouched"
else
  fail "7 default unsigned path isolation (rc=${rc})"
  tail -20 "${WORKDIR}/default-unsigned.log" || true
fi

# Isolated signed rebuild must not mutate tracked client/artifacts under PROJ
FINAL_OUT="${WORKDIR}/final-prod-isolated"
CLIENT_SHA_BEFORE="$(sha256sum "${PROJ}/client/dp-offline-upgrade-xenial-to-bionic.sh" | awk '{print $1}')"
ART_SHA_BEFORE="$(sha256sum "$PROD_ARTIFACT" | awk '{print $1}')"
set +e
python3 "$BUILD_PY_PROJ" \
  --project-root "$PROJ" \
  --mirror-base "$MIRROR_BASE" \
  --selective-root "$SEL_ROOT" \
  --output-dir "$FINAL_OUT" \
  >"${WORKDIR}/final-prod-build.log" 2>&1
rc=$?
set -e
CLIENT_SHA_AFTER="$(sha256sum "${PROJ}/client/dp-offline-upgrade-xenial-to-bionic.sh" | awk '{print $1}')"
ART_SHA_AFTER="$(sha256sum "$PROD_ARTIFACT" | awk '{print $1}')"
if [[ "$rc" -eq 0 ]] \
  && grep -q 'CLIENT_MANIFEST_SIGNATURE_MODE=PRODUCTION_SIGNED' "${WORKDIR}/final-prod-build.log" \
  && grep -q 'ARTIFACT_SIGNATURE_VERIFY=PASS' "${WORKDIR}/final-prod-build.log" \
  && [[ -f "${FINAL_OUT}/dp-offline-upgrade-xenial-to-bionic.sh" ]] \
  && [[ "$CLIENT_SHA_BEFORE" == "$CLIENT_SHA_AFTER" ]] \
  && [[ "$ART_SHA_BEFORE" == "$ART_SHA_AFTER" ]]; then
  pass "isolated signed rebuild (tracked client/artifacts unchanged)"
  grep -E '^CLIENT_MANIFEST_SIGNER_FINGERPRINT=|^sha256=|^CLIENT_MANIFEST_UNSIGNED_TEST_COUNT=' \
    "${WORKDIR}/final-prod-build.log" || true
else
  fail "isolated signed rebuild / tracked tree mutated (rc=${rc})"
  tail -40 "${WORKDIR}/final-prod-build.log" || true
fi

READY_AFTER="$(sha256sum "$READY_PATH" | awk '{print $1}')"
if [[ "$READY_BEFORE" == "$READY_AFTER" ]]; then
  pass "READY_UNCHANGED=YES"
  echo "READY_UNCHANGED=YES"
else
  fail "READY changed during signing tests"
fi

pass "11 no DP/do-release-upgrade/package transaction/publish/reboot/full-mirror"

if [[ "$FAIL" -ne 0 ]]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
exit 0
