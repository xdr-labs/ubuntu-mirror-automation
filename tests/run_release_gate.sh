#!/usr/bin/env bash
# tests/run_release_gate.sh — Optional pre-release gate for a candidate OS Core.
#
# Usage:
#   bash tests/run_release_gate.sh --os-core /path/to/candidate.tar
#
# NEVER contacts a real DP.
# NEVER uploads or modifies production R2.
# Does NOT build the multi-GB candidate; caller supplies an already-built artifact.
#
# Phase2 input is a TEST FIXTURE only (satisfies rebuild-publish-clients.sh's
# unrelated wrapper dependency). This gate does NOT claim ACPS / Phase2 6.6.0
# release readiness.
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
# shellcheck source=lib/client_finalization_fixture.sh
source "${ROOT}/tests/lib/client_finalization_fixture.sh"

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

echo "=== 3. verify generation tuple + AWS contract identities (shared tree validator) ==="
# Do NOT reconstruct Debian pool paths from binary package names. Ubuntu pool
# directories may be source-package based (e.g. linux-meta-aws). Reuse the same
# production semantic validator used by OS Core / selective verification.
python3 - <<'PY' "$MM_SELECTIVE_ROOT" "$ROOT" || FAIL=1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[2], "scripts", "lib"))
from aws_os_core_completeness import (
    load_verified_selective_generation,
    iter_contract_identities,
    validate_tree_aws_completeness,
)

gen = load_verified_selective_generation(sys.argv[1], project_root=sys.argv[2])
print("PLAN=%s" % gen["plan_checksum"])
print("DISCOVERY=%s" % gen["discovery_artifact_checksum"])
print("CONTRACT=%s" % gen["aws_semantic_contract_sha256"])
plan = gen.get("plan")
if not plan:
    print("AWS_PHYSICAL_PRESENCE=FAIL reason=verified_plan_missing")
    print("AWS_EXACT_SHA256=FAIL")
    print("GENERATION_TUPLE=FAIL")
    sys.exit(1)

contract = gen.get("contract") or plan.get("aws_semantic_contract") or {}
# Evidence only: hop/package/version/arch/sha — never reconstruct pool paths.
for hop, hop_c in (contract.get("hops") or {}).items():
    for ident in iter_contract_identities(hop_c):
        print(
            "CONTRACT_IDENTITY hop=%s package=%s version=%s architecture=%s sha256=%s"
            % (
                hop,
                ident.get("package"),
                ident.get("version"),
                ident.get("architecture") or "amd64",
                (ident.get("sha256") or "")[:16],
            )
        )

ok, errors, detail = validate_tree_aws_completeness(
    sys.argv[1],
    plan=plan,
    require_aws_profile=True,
    verify_sha256=True,
)
if not ok:
    print("AWS_PHYSICAL_PRESENCE=FAIL")
    print("AWS_EXACT_SHA256=FAIL")
    print("GENERATION_TUPLE=FAIL")
    for err in (errors or [])[:20]:
        print("  aws_tree_error: %s" % err)
    sys.exit(1)

# Presence + exact SHA both enforced by verify_sha256=True above.
print("AWS_PHYSICAL_PRESENCE=PASS")
print("AWS_EXACT_SHA256=PASS")
print("GENERATION_TUPLE=PASS")
print("SHARED_AWS_TREE_VALIDATOR=validate_tree_aws_completeness")
print("POOL_PATH_RECONSTRUCTION=NO")
PY

echo "=== 4. real client finalization (local-fs, unreachable Mirror URL) ==="
# Phase2 fixture satisfies rebuild-publish-clients.sh wrapper dependency only.
# Populates the temporary release-gate Mirror — never production Phase2 data.
client_fixture_populate_dp_phase2 "$MM_MIRROR_ROOT"
echo "PHASE2_INPUT_MODE=TEST_FIXTURE"
echo "PHASE2_RELEASE_READINESS=NOT_TESTED"

# Tiny schema-v2 lifecycle candidates may omit signed release-upgrader tarballs;
# real multi-GB candidates carry them in the OS Core payload. Plant fixtures only
# when absent — never overwrite candidate-provided upgraders.
UPGRADER_FIXTURE=0
for codename in bionic focal jammy noble; do
  utar="${MM_SELECTIVE_ROOT}/shared/offline/release-upgraders/${codename}/${codename}.tar.gz"
  [[ -f "$utar" ]] || UPGRADER_FIXTURE=1
done
if [[ "$UPGRADER_FIXTURE" -eq 1 ]]; then
  client_fixture_require
  client_fixture_gen_keys "${TMP}/upgrader-fixture"
  for codename in bionic focal jammy noble; do
    utar="${MM_SELECTIVE_ROOT}/shared/offline/release-upgraders/${codename}/${codename}.tar.gz"
    if [[ ! -f "$utar" ]]; then
      client_fixture_populate_upgrader "$MM_SELECTIVE_ROOT" "$codename" \
        "$CLIENT_FIXTURE_GPG_SEL"
    fi
  done
  mkdir -p "${MM_SELECTIVE_ROOT}/shared/offline"
  [[ -f "${MM_SELECTIVE_ROOT}/shared/offline/meta-release-lts" ]] \
    || printf '# meta-release-lts fixture\n' \
      >"${MM_SELECTIVE_ROOT}/shared/offline/meta-release-lts"
  echo "RELEASE_UPGRADER_INPUT_MODE=TEST_FIXTURE"
else
  echo "RELEASE_UPGRADER_INPUT_MODE=FROM_CANDIDATE"
fi

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
  MM_HERMETIC_TEST_MODE=1 \
  CLIENT_BUILD_PIN_URL_ONLY=1 \
  SKIP_HTTP_VERIFY=1 \
  REQUIRE_SELECTIVE_READY=1 \
  bash "$REBUILD" >"${TMP}/client.log" 2>&1
CRC=$?
set -e
tail -40 "${TMP}/client.log" || true
if [[ "$CRC" -eq 0 ]] && grep -q 'REBUILD_PUBLISH_CLIENTS=PASS' "${TMP}/client.log"; then
  pass "client finalization"
  echo "CLIENT_4_HOP_BUILD=PASS"
else
  fail "client finalization rc=${CRC}"
  echo "CLIENT_4_HOP_BUILD=FAIL"
fi

# Generation tuple on all four hop client manifests
if [[ "$CRC" -eq 0 ]]; then
  python3 - <<'PY' "$MM_CLIENT_ROOT" "$MM_SELECTIVE_ROOT" "$ROOT" || FAIL=1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[3], "scripts", "lib"))
from aws_os_core_completeness import load_verified_selective_generation
gen = load_verified_selective_generation(sys.argv[2], project_root=sys.argv[3])
plan_ck = gen["plan_checksum"]
disc_ck = gen["discovery_artifact_checksum"]
contract_ck = gen["aws_semantic_contract_sha256"]
client_root = sys.argv[1]
ok = True
for hop in (
    "xenial-to-bionic", "bionic-to-focal", "focal-to-jammy", "jammy-to-noble",
):
    manifest = os.path.join(client_root, hop, "client-manifest.json")
    if not os.path.isfile(manifest):
        print("CLIENT_GENERATION_TUPLE_MATCH=FAIL missing=%s" % hop)
        ok = False
        continue
    m = json.load(open(manifest))
    if (
        m.get("plan_checksum") != plan_ck
        or m.get("discovery_checksum") != disc_ck
        or m.get("aws_semantic_contract_sha256") != contract_ck
    ):
        print("CLIENT_GENERATION_TUPLE_MATCH=FAIL hop=%s" % hop)
        ok = False
if ok:
    print("CLIENT_GENERATION_TUPLE_MATCH=PASS")
sys.exit(0 if ok else 1)
PY
else
  echo "CLIENT_GENERATION_TUPLE_MATCH=FAIL"
fi

echo "CANDIDATE_SHA256=${CAND_SHA}"
echo "CANDIDATE_BYTES=${CAND_BYTES}"
echo "PHASE2_INPUT_MODE=TEST_FIXTURE"
echo "PHASE2_RELEASE_READINESS=NOT_TESTED"
if [[ "$FAIL" -eq 0 ]]; then
  echo "RELEASE_GATE_RESULT=PASS"
  exit 0
fi
echo "RELEASE_GATE_RESULT=FAIL"
exit 1
