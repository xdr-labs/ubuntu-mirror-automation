#!/usr/bin/env bash
# R2 OS Core trust: HTTPS + mandatory SHA256. Client signing key is not a publisher root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_PROJECT_ROOT="$ROOT"
export MM_SKIP_ROOT_CHECK=1
export MM_MIRROR_ROOT="${TMP}/mirror"
export MM_CACHE_ROOT="${TMP}/cache"
export MM_LOG_DIR="${TMP}/logs"
export MM_CONFIG_DIR="${TMP}/config"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_CLIENT_ROOT="${TMP}/client"
export LOCAL_CLIENT_SIGNING_DIR="${TMP}/client-signing"
mkdir -p "$MM_CACHE_ROOT" "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$MM_CLIENT_ROOT" \
  "$LOCAL_CLIENT_SIGNING_DIR"
: >"$MM_STATUS_FILE"
printf 'CLIENT-PUB\n' >"${LOCAL_CLIENT_SIGNING_DIR}/public.gpg"
printf 'CLIENT-PUB\n' >"${MM_CLIENT_ROOT}/public.gpg"
export CLIENT_SIGNING_PUBLIC_KEY="${LOCAL_CLIENT_SIGNING_DIR}/public.gpg"

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_install_engine.sh"

# 12. local client signing key is not accepted as implicit R2 publisher trust root.
export R2_OS_CORE_PUBLISHER_PUBLIC_KEY="$CLIENT_SIGNING_PUBLIC_KEY"
if pub="$(engine_r2_publisher_public_key)"; then
  fail "client signing key was accepted as R2 publisher key: ${pub}"
fi
unset R2_OS_CORE_PUBLISHER_PUBLIC_KEY
if pub="$(engine_r2_publisher_public_key 2>/dev/null)"; then
  fail "implicit publisher key resolved: ${pub}"
fi
pass "client signing key is not an implicit R2 publisher trust root"

# Build a tiny unsigned package (dirs + regular files only) for verify.
PKG_SRC="${TMP}/pkg-src"
python3 - "$PKG_SRC" <<'PY'
import hashlib, json, os, sys
root = sys.argv[1]
pkg = os.path.join(root, "ubuntu-os-core")
payload = os.path.join(pkg, "payload")
hops = ["xenial-to-bionic", "bionic-to-focal", "focal-to-jammy", "jammy-to-noble"]
file_count = 0
payload_bytes = 0
lines = []
for hop in hops:
    d = os.path.join(payload, "hops", hop)
    os.makedirs(d)
    p = os.path.join(d, "hello.txt")
    data = b"ok\n"
    with open(p, "wb") as fh:
        fh.write(data)
    rel = "hops/%s/hello.txt" % hop
    digest = hashlib.sha256(data).hexdigest()
    lines.append("%s  %s" % (digest, rel))
    file_count += 1
    payload_bytes += len(data)
os.makedirs(os.path.join(payload, "shared"), exist_ok=True)
with open(os.path.join(pkg, "payload.sha256"), "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
manifest = {
    "schema_version": 1,
    "artifact_type": "ubuntu-os-core",
    "release_id": "test-unsigned",
    "payload_file_count": file_count,
    "payload_bytes": payload_bytes,
    "required_free_bytes": payload_bytes,
}
with open(os.path.join(pkg, "manifest.json"), "w", encoding="utf-8") as fh:
    json.dump(manifest, fh)
    fh.write("\n")
PY

# Use os_core_package.py verify against a handmade tar+sha256 (no .asc).
PKG="${TMP}/os-core.tar"
python3 - "$ROOT" "$PKG_SRC" "$PKG" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "scripts", "lib"))
import os_core_package as oc
oc.safe_tar_create(sys.argv[2], sys.argv[3])
PY
sha256sum "$PKG" | awk '{print $1"  os-core.tar"}' >"${PKG}.sha256"

# 13. no-.asc + mandatory SHA256 remains valid.
set +e
out="$(python3 "${ROOT}/scripts/lib/os_core_package.py" verify --package "$PKG" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "unsigned SHA256 package verify rc=${rc} out=${out}"
printf '%s\n' "$out" | grep -q 'OUTER_SHA256=PASS' || fail "missing OUTER_SHA256=PASS"
printf '%s\n' "$out" | grep -q 'SIGNATURE=ABSENT' || fail "missing SIGNATURE=ABSENT"
pass "no-.asc + mandatory SHA256 path remains valid"

# 14. unexpected .asc without configured publisher key fails closed.
printf 'not-a-real-signature\n' >"${PKG}.sha256.asc"
set +e
out="$(python3 "${ROOT}/scripts/lib/os_core_package.py" verify --package "$PKG" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "unexpected .asc without publisher key succeeded"
printf '%s\n' "$out" | grep -q 'publisher_public_key_unconfigured\|SIGNATURE_PRESENT_BUT_NO_PUBLIC_KEY' \
  || fail "missing fail-closed trust error: ${out}"
pass "unexpected .asc without publisher key fails closed"

# Passing the client signing key as --public-key is refused by engine helper.
export R2_OS_CORE_PUBLISHER_PUBLIC_KEY="$CLIENT_SIGNING_PUBLIC_KEY"
if engine_r2_publisher_public_key >/dev/null 2>&1; then
  fail "engine still treats client signing key as publisher"
fi
pass "engine refuses client signing key as R2 publisher"

# Source must not default OS_CORE_PUBLIC_KEY from client signing.
if grep -n 'OS_CORE_PUBLIC_KEY="$CLIENT_SIGNING_PUBLIC_KEY"' \
  "${ROOT}/scripts/install-dp-upgrade-mirror.sh"; then
  fail "install still copies CLIENT_SIGNING_PUBLIC_KEY into OS_CORE_PUBLIC_KEY"
fi
pass "install does not copy client signing key into OS_CORE_PUBLIC_KEY"

echo "ALL test_r2_publisher_trust checks passed"
