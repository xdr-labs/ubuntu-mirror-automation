#!/usr/bin/env bash
# tests/run_release_gate.sh — Optional pre-release gate for a candidate OS Core.
#
# Usage:
#   bash tests/run_release_gate.sh --os-core /path/to/candidate.tar
#
# NEVER contacts a real DP.
# NEVER uploads or modifies production R2.
# Does NOT build the multi-GB candidate; caller supplies an already-built artifact.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS_CORE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --os-core) OS_CORE="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --os-core /path/to/candidate.tar"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$OS_CORE" || ! -f "$OS_CORE" ]]; then
  echo "RELEASE_GATE_RESULT=FAIL"
  echo "error: --os-core path required and must exist" >&2
  exit 2
fi

OS_CORE="$(cd "$(dirname "$OS_CORE")" && pwd)/$(basename "$OS_CORE")"
OS_CORE_PY="${ROOT}/scripts/lib/os_core_package.py"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
REBUILD="${ROOT}/scripts/rebuild-publish-clients.sh"

echo "=== run_release_gate ==="
echo "REAL_DP_USED=NO"
echo "R2_NETWORK_USED=NO"
echo "EXTERNAL_NETWORK_USED=NO"

CAND_SHA="$(sha256sum "$OS_CORE" | awk '{print $1}')"
CAND_BYTES="$(stat -c%s "$OS_CORE" 2>/dev/null || wc -c <"$OS_CORE")"
echo "CANDIDATE_OS_CORE=${OS_CORE}"
echo "CANDIDATE_SHA256=${CAND_SHA}"
echo "CANDIDATE_BYTES=${CAND_BYTES}"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "=== 1. verify candidate ==="
set +e
python3 "$OS_CORE_PY" verify --package "$OS_CORE" >"${TMP}/verify.log" 2>&1
VRC=$?
set -e
tail -30 "${TMP}/verify.log" || true
[[ "$VRC" -eq 0 ]] && pass "os_core verify" || fail "os_core verify rc=${VRC}"

# Ephemeral client signing for hermetic finalization
SIGN="${TMP}/client-signing"
mkdir -p "$SIGN"
gpg_home="${TMP}/gpg"
mkdir -p "$gpg_home"
chmod 700 "$gpg_home"
cat >"${gpg_home}/batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Release Gate Client
Name-Email: release-gate@local
Expire-Date: 0
%no-protection
%commit
EOF
gpg --homedir "$gpg_home" --batch --gen-key "${gpg_home}/batch" >/dev/null 2>&1
gpg --homedir "$gpg_home" --batch --export-secret-keys --armor >"${SIGN}/private.gpg"
gpg --homedir "$gpg_home" --batch --export --armor >"${SIGN}/public.gpg"
chmod 600 "${SIGN}/private.gpg"
gpg --homedir "$gpg_home" --batch --with-colons --fingerprint \
  | awk -F: '/^fpr:/ {print toupper($10); exit}' >"${SIGN}/fingerprint"

export MM_PROJECT_ROOT="$ROOT"
export MM_SKIP_ROOT_CHECK=1
export MM_MIRROR_ROOT="${TMP}/mirror"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export MM_STATE_ROOT="${TMP}/state"
export MM_LOG_DIR="${TMP}/logs"
export MM_CONFIG_DIR="${TMP}/config"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_SELECTIVE_ROOT="${MM_MIRROR_ROOT}/selective"
export MM_CLIENT_ROOT="${MM_MIRROR_ROOT}/client"
export MM_LOCK_FILE="${TMP}/install.lock"
export LOCAL_CLIENT_SIGNING_DIR="$SIGN"
export PREPARATION_MODE=FULL

mkdir -p "$MM_CACHE_ROOT" "$MM_LOG_DIR" "$MM_STATE_ROOT" "$MM_CONFIG_DIR" \
  "$MM_CLIENT_ROOT" "$MM_DP_PHASE2_ROOT" "$MM_SELECTIVE_ROOT"

echo "=== 2. materialize into empty temporary Mirror ==="
[[ ! -f "${MM_SELECTIVE_ROOT}/state/plan.json" ]] \
  && pass "fresh mirror empty" || fail "fresh mirror not empty"

# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "$COMMON"
# shellcheck source=../scripts/lib/mirror_install_engine.sh
source "$ENGINE"
mm_state_init
engine_resolve_paths

set +e
engine_materialize_os_mirror "$OS_CORE" >"${TMP}/materialize.log" 2>&1
MRC=$?
set -e
tail -40 "${TMP}/materialize.log" || true
[[ "$MRC" -eq 0 ]] && pass "engine_materialize_os_mirror" || fail "materialize rc=${MRC}"

echo "=== 3. verify generation tuple + AWS contract identities ==="
python3 - <<'PY' "$MM_SELECTIVE_ROOT" "$ROOT" || FAIL=1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[2], "scripts", "lib"))
from aws_os_core_completeness import (
    load_verified_selective_generation,
    iter_contract_identities,
)
gen = load_verified_selective_generation(sys.argv[1], project_root=sys.argv[2])
print("PLAN=%s" % gen["plan_checksum"])
print("DISCOVERY=%s" % gen["discovery_artifact_checksum"])
print("CONTRACT=%s" % gen["aws_semantic_contract_sha256"])
contract = gen.get("contract") or {}
missing = []
for hop, hop_c in (contract.get("hops") or {}).items():
    for ident in iter_contract_identities(hop_c):
        pkg = ident["package"]
        ver = ident["version"]
        arch = ident.get("architecture") or "amd64"
        base = "%s_%s_%s.deb" % (pkg, ver, arch)
        path = os.path.join(
            sys.argv[1], "hops", hop, "ubuntu", "pool", "main", pkg[0], pkg, base
        )
        if not os.path.isfile(path):
            missing.append("%s:%s" % (hop, base))
if missing:
    print("AWS_PHYSICAL_PRESENCE=FAIL missing=%s" % missing[:10])
    sys.exit(1)
print("AWS_PHYSICAL_PRESENCE=PASS")
print("GENERATION_TUPLE=PASS")
PY

echo "=== 4. real client finalization (local-fs, unreachable Mirror URL) ==="
MIRROR_URL="http://192.0.2.99"
set +e
env \
  MIRROR_HTTP_URL="$MIRROR_URL" \
  RESOLVED_MIRROR_BASE_URL="$MIRROR_URL" \
  RESOLVED_MIRROR_HOST_IPV4="192.0.2.99" \
  LOCAL_CLIENT_SIGNING_DIR="$SIGN" \
  CLIENT_HTTP_ROOT="$MM_CLIENT_ROOT" \
  SELECTIVE_ROOT="$MM_SELECTIVE_ROOT" \
  BASE_PATH="$MM_MIRROR_ROOT" \
  CACHE_ROOT="$MM_CACHE_ROOT" \
  CONTENT_SOURCE=local-fs \
  CLIENT_BUILD_PIN_URL_ONLY=1 \
  SKIP_HTTP_VERIFY=1 \
  REQUIRE_SELECTIVE_READY=1 \
  bash "$REBUILD" >"${TMP}/client.log" 2>&1
CRC=$?
set -e
tail -40 "${TMP}/client.log" || true
if [[ "$CRC" -eq 0 ]] && grep -q 'REBUILD_PUBLISH_CLIENTS=PASS' "${TMP}/client.log"; then
  pass "client finalization"
else
  fail "client finalization rc=${CRC}"
fi

echo "CANDIDATE_SHA256=${CAND_SHA}"
echo "CANDIDATE_BYTES=${CAND_BYTES}"
if [[ "$FAIL" -eq 0 ]]; then
  echo "RELEASE_GATE_RESULT=PASS"
  exit 0
fi
echo "RELEASE_GATE_RESULT=FAIL"
exit 1
