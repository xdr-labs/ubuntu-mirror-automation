#!/usr/bin/env bash
# tests/test_os_core_r2_roundtrip_integration.sh
#
# True hermetic production lifecycle round-trip:
#   discovery → planner → materializer → validator → OS Core build/verify
#   → engine_materialize_os_mirror → real four-hop client build
#
# Does NOT use synthetic _write_plan_state / _plant_synth_tree as authority.
# Does NOT contact a real DP, R2, or external network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/client_finalization_fixture.sh
source "${ROOT}/tests/lib/client_finalization_fixture.sh"
FIXTURE_PY="${ROOT}/tests/lib/build_tiny_os_core_lifecycle_fixture.py"
PLANNER="${ROOT}/scripts/build-selective-mirror-plan.py"
MATERIALIZE_PY="${ROOT}/scripts/lib/selective_mirror.py"
VALIDATE_PY="${ROOT}/scripts/lib/validate_selective_mirror.py"
OS_CORE_PY="${ROOT}/scripts/lib/os_core_package.py"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
REBUILD_CLIENTS="${ROOT}/scripts/rebuild-publish-clients.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

echo "=== test_os_core_r2_roundtrip_integration ==="
echo "UNIT_ONLY=NO"
echo "REAL_PRODUCTION_PLANNER=YES"
echo "REAL_SELECTIVE_MATERIALIZER=YES"
echo "REAL_SELECTIVE_VALIDATOR=YES"
echo "REAL_OS_CORE_BUILD=YES"
echo "REAL_OS_CORE_VERIFY=YES"
echo "REAL_ENGINE_MATERIALIZE=YES"
echo "REAL_CLIENT_BUILD=YES"
echo "REAL_DP_USED=NO"
echo "EXTERNAL_NETWORK_USED=NO"
echo "MANUAL_PAYLOAD_COPY_USED=NO"
echo "SYNTHETIC_PLAN_WRITE_USED_IN_POSITIVE_LIFECYCLE=NO"

START_TS="$(date +%s)"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Tiny hermetic fixture (real .debs via dpkg-deb)
# ---------------------------------------------------------------------------
echo "=== 1. build tiny lifecycle fixture ==="
FX="${TMP}/fixture"
python3 "$FIXTURE_PY" --output-dir "$FX"
# shellcheck disable=SC1090
source "${FX}/fixture.env"
[[ -d "$GENERIC_DISCOVERY" && -d "$AWS_DISCOVERY" && -d "$SEED_UBUNTU" ]] \
  && pass "fixture discovery+seed present" \
  || fail "fixture paths missing"

# ---------------------------------------------------------------------------
# 2. Real planner (production profile requirements; no hermetic escapes)
# ---------------------------------------------------------------------------
echo "=== 2. real selective planner ==="
PLAN_OUT="${TMP}/plan-out"
mkdir -p "$PLAN_OUT"
set +e
# Explicitly unset hermetic escapes for the positive production lifecycle.
env -u MM_HERMETIC_TEST_MODE -u UM_ALLOW_GENERIC_ONLY_DISCOVERY \
  -u UM_ALLOW_NAME_ONLY_AWS_VALIDATION \
  python3 "$PLANNER" \
  --discovery-root "generic=${GENERIC_DISCOVERY}" \
  --discovery-root "aws=${AWS_DISCOVERY}" \
  --seed-root "$SEED_UBUNTU" \
  --output-dir "$PLAN_OUT" \
  --no-resolve-missing-pool-paths \
  --verify-seed-checksums \
  >"${TMP}/plan.log" 2>&1
PLAN_RC=$?
set -e
tail -40 "${TMP}/plan.log" || true
PLAN_JSON="${PLAN_OUT}/selective-mirror-plan.json"
[[ -f "$PLAN_JSON" ]] || { fail "plan json missing"; echo "ROUNDTRIP_RESULT=FAIL"; exit 1; }

grep -q 'validation_result=PASS' "${TMP}/plan.log" \
  && pass "planner validation_result=PASS" \
  || fail "planner validation_result not PASS"
grep -q 'discovery_profiles=generic,aws' "${TMP}/plan.log" \
  && pass "discovery_profiles=generic,aws" \
  || fail "discovery_profiles missing/wrong"

PLAN_A="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_checksum"])' "$PLAN_JSON")"
DISCOVERY_A="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["discovery_artifact_checksum"])' "$PLAN_JSON")"
CONTRACT_A="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("aws_semantic_contract_sha256") or "")' "$PLAN_JSON")"
[[ "$PLAN_RC" -eq 0 ]] && pass "planner exit 0" || fail "planner rc=${PLAN_RC}"
[[ "$PLAN_A" =~ ^[0-9a-fA-F]{64}$ ]] && pass "PLAN_A=${PLAN_A:0:16}…" || fail "PLAN_A invalid"
[[ "$DISCOVERY_A" =~ ^[0-9a-fA-F]{64}$ ]] && pass "DISCOVERY_A ok" || fail "DISCOVERY_A invalid"
[[ "$CONTRACT_A" =~ ^[0-9a-fA-F]{64}$ ]] && pass "CONTRACT_A ok" || fail "CONTRACT_A invalid"
echo "PLAN_A=${PLAN_A}"
echo "DISCOVERY_A=${DISCOVERY_A}"
echo "CONTRACT_A=${CONTRACT_A}"

# ---------------------------------------------------------------------------
# 3. Real selective materializer (local seed, no network)
# ---------------------------------------------------------------------------
echo "=== 3. real selective materializer ==="
SEL_SRC="${TMP}/selective-src"
mkdir -p "$SEL_SRC/keys"
# Let materialize ensure_signing_key() generate selective GPG into keys/ so
# InRelease clearsign has a usable gnupg homedir (pre-planted armor alone is
# not imported into keys/gnupg by production materialize).
set +e
python3 "$MATERIALIZE_PY" materialize \
  --plan "$PLAN_JSON" \
  --selective-root "$SEL_SRC" \
  --no-download \
  --reuse-root "$SEED_UBUNTU" \
  >"${TMP}/materialize.log" 2>&1
MAT_RC=$?
set -e
tail -30 "${TMP}/materialize.log" || true
[[ "$MAT_RC" -eq 0 ]] && pass "materialize exit 0" || { fail "materialize rc=${MAT_RC}"; cat "${TMP}/materialize.log"; }

# Physical presence of AWS contract-required .debs under every hop
python3 - <<'PY' "$PLAN_JSON" "$SEL_SRC" || FAIL=1
import json, os, sys
plan = json.load(open(sys.argv[1]))
sel = sys.argv[2]
contract = plan.get("aws_semantic_contract") or {}
staging = os.path.join(sel, "staging")
missing = []
for hop, hop_c in (contract.get("hops") or {}).items():
    idents = []
    for key in ("linux_aws", "linux_image_aws", "snapd"):
        if hop_c.get(key):
            idents.append(hop_c[key])
    idents.extend(hop_c.get("versioned_images") or [])
    idents.extend(hop_c.get("boot_packages") or [])
    for ident in idents:
        pkg = ident["package"]
        ver = ident["version"]
        arch = ident.get("architecture") or "amd64"
        sha = (ident.get("sha256") or "").lower()
        letter = pkg[0]
        base = "%s_%s_%s.deb" % (pkg, ver, arch)
        path = os.path.join(
            staging, "hops", hop, "ubuntu", "pool", "main", letter, pkg, base
        )
        if not os.path.isfile(path):
            # try %2b encoding variant
            base2 = base.replace("+", "%2b")
            path2 = os.path.join(
                staging, "hops", hop, "ubuntu", "pool", "main", letter, pkg, base2
            )
            if os.path.isfile(path2):
                path = path2
            else:
                missing.append("%s:%s" % (hop, base))
                continue
        import hashlib
        h = hashlib.sha256(open(path, "rb").read()).hexdigest()
        if h != sha:
            missing.append("%s:%s sha mismatch" % (hop, base))
if missing:
    print("  FAIL: missing/mismatched AWS debs: %s" % missing[:8])
    sys.exit(1)
print("  PASS: AWS contract debs present under every hop")
PY

# ---------------------------------------------------------------------------
# 4. Real pre-publish validator (+ negative tamper case)
# ---------------------------------------------------------------------------
echo "=== 4. real pre-publish validator ==="
set +e
python3 "$VALIDATE_PY" \
  --plan "$PLAN_JSON" \
  --selective-root "$SEL_SRC" \
  --phase pre_publish \
  >"${TMP}/validate.log" 2>&1
VAL_RC=$?
set -e
tail -40 "${TMP}/validate.log" || true
[[ "$VAL_RC" -eq 0 ]] && pass "validator exit 0" || fail "validator rc=${VAL_RC}"
grep -q 'validation_result=PASS' "${TMP}/validate.log" \
  && pass "validation_result=PASS" || fail "validation_result not PASS"

python3 - <<'PY' "$SEL_SRC" || FAIL=1
import json, os, sys
vr = os.path.join(sys.argv[1], "state", "verify-result.json")
data = json.load(open(vr))
gates = data.get("gates") or {}
need = (
    "aws_plan_semantic_completeness",
    "aws_tree_semantic_completeness",
    "selected_deb_checksum",
)
bad = []
for k in need:
    if gates.get(k) != "PASS":
        bad.append("%s=%s" % (k, gates.get(k)))
# package index coverage
cov = [k for k, v in gates.items() if k.startswith("packages_coverage_") and v != "PASS"]
if cov:
    bad.append("coverage:" + ",".join(cov))
if bad:
    print("  FAIL: gates %s" % bad)
    sys.exit(1)
for k in need:
    print("  PASS: %s=PASS" % k)
print("  PASS: package index coverage PASS")
PY

# Negative: tamper one AWS .deb → validator FAIL → READY must not become valid
echo "=== 4b. negative: tamper contract AWS .deb ==="
TAMPER_DEB="$(python3 - <<'PY' "$PLAN_JSON" "$SEL_SRC"
import json, os, sys
plan = json.load(open(sys.argv[1]))
sel = sys.argv[2]
hop = "xenial-to-bionic"
hop_c = plan["aws_semantic_contract"]["hops"][hop]
ident = hop_c["linux_aws"]
pkg, ver = ident["package"], ident["version"]
arch = ident.get("architecture") or "amd64"
base = "%s_%s_%s.deb" % (pkg, ver, arch)
path = os.path.join(sel, "staging", "hops", hop, "ubuntu", "pool", "main", pkg[0], pkg, base)
print(path)
PY
)"
cp -a "$TAMPER_DEB" "${TAMPER_DEB}.bak"
printf 'TAMPER' >>"$TAMPER_DEB"
rm -f "${SEL_SRC}/state/READY" 2>/dev/null || true
set +e
python3 "$VALIDATE_PY" \
  --plan "$PLAN_JSON" \
  --selective-root "$SEL_SRC" \
  --phase pre_publish \
  >"${TMP}/validate-tamper.log" 2>&1
TAMPER_RC=$?
set -e
[[ "$TAMPER_RC" -ne 0 ]] && pass "tampered validator FAIL (rc=${TAMPER_RC})" \
  || fail "tampered validator unexpectedly PASS"
grep -q 'validation_result=FAIL' "${TMP}/validate-tamper.log" \
  && pass "tampered validation_result=FAIL" || fail "tampered result not FAIL"
[[ ! -f "${SEL_SRC}/state/READY" ]] \
  && pass "READY absent after tamper fail" \
  || fail "READY must not become valid after tamper"
# Restore good bytes and re-validate
mv "${TAMPER_DEB}.bak" "$TAMPER_DEB"
set +e
python3 "$VALIDATE_PY" \
  --plan "$PLAN_JSON" \
  --selective-root "$SEL_SRC" \
  --phase pre_publish \
  >"${TMP}/validate-restored.log" 2>&1
REST_RC=$?
set -e
[[ "$REST_RC" -eq 0 ]] && pass "validator PASS after restore" || fail "restore validate rc=${REST_RC}"

# ---------------------------------------------------------------------------
# 5. Production generation-state helper → publish → READY (no _write_plan_state)
# ---------------------------------------------------------------------------
echo "=== 5. production generation state + publish + READY ==="
python3 - <<'PY' "$SEL_SRC" "$PLAN_JSON" "$ROOT"
import os, sys
sys.path.insert(0, os.path.join(sys.argv[3], "scripts", "lib"))
from aws_os_core_completeness import publish_selective_generation_state
gen = publish_selective_generation_state(sys.argv[1], sys.argv[2])
print("GEN_PLAN=%s" % gen["plan_checksum"])
print("GEN_DISC=%s" % gen["discovery_artifact_checksum"])
print("GEN_CONTRACT=%s" % gen["aws_semantic_contract_sha256"])
open(os.path.join(sys.argv[1], "state", ".gen-tuple.env"), "w").write(
    "GEN_PLAN=%s\nGEN_DISC=%s\nGEN_CONTRACT=%s\n"
    % (gen["plan_checksum"], gen["discovery_artifact_checksum"], gen["aws_semantic_contract_sha256"])
)
PY
# shellcheck disable=SC1090
source "${SEL_SRC}/state/.gen-tuple.env"
[[ "$GEN_PLAN" == "$PLAN_A" ]] && pass "generation plan == PLAN_A" || fail "gen plan mismatch"
[[ "$GEN_DISC" == "$DISCOVERY_A" ]] && pass "generation disc == DISCOVERY_A" || fail "gen disc mismatch"
[[ "$GEN_CONTRACT" == "$CONTRACT_A" ]] && pass "generation contract == CONTRACT_A" || fail "gen contract mismatch"

set +e
python3 "$MATERIALIZE_PY" publish \
  --selective-root "$SEL_SRC" \
  --plan "$PLAN_JSON" \
  --skip-post-publish \
  --skip-nginx-preflight \
  >"${TMP}/publish.log" 2>&1
PUB_RC=$?
set -e
tail -20 "${TMP}/publish.log" || true
[[ "$PUB_RC" -eq 0 ]] && pass "atomic publish (skip post-http) exit 0" || fail "publish rc=${PUB_RC}"
[[ -d "${SEL_SRC}/published/hops/xenial-to-bionic" ]] \
  && pass "published tree present" || fail "published tree missing"

# READY via production generation marker (post-publish HTTP skipped hermetically)
python3 - <<'PY' "$SEL_SRC" "$PLAN_A" "$DISCOVERY_A" "$CONTRACT_A" "$ROOT"
import os, sys
sys.path.insert(0, os.path.join(sys.argv[5], "scripts", "lib"))
from aws_os_core_completeness import (
    write_ready_generation_marker,
    load_verified_selective_generation,
)
ready = os.path.join(sys.argv[1], "state", "READY")
write_ready_generation_marker(ready, sys.argv[2], sys.argv[3], sys.argv[4])
gen = load_verified_selective_generation(sys.argv[1], project_root=sys.argv[5])
assert gen["plan_checksum"] == sys.argv[2]
assert gen["discovery_artifact_checksum"] == sys.argv[3]
assert gen["aws_semantic_contract_sha256"] == sys.argv[4]
print("READY_TUPLE_OK")
print("load_verified_selective_generation=PASS")
PY
pass "READY tuple == real plan tuple; load_verified PASS"

# ---------------------------------------------------------------------------
# 6-7. Real OS Core build + verify
# ---------------------------------------------------------------------------
echo "=== 6-7. real OS Core build + verify ==="
OS_OUT="${TMP}/os-core-out"
mkdir -p "$OS_OUT"
set +e
env -u MM_HERMETIC_TEST_MODE -u UM_ALLOW_NAME_ONLY_AWS_VALIDATION \
  python3 "$OS_CORE_PY" build \
  --selective-root "$SEL_SRC" \
  --output-dir "$OS_OUT" \
  --project-root "$ROOT" \
  --release-id lifecycleRt001 \
  >"${TMP}/os-core-build.log" 2>&1
BUILD_RC=$?
set -e
tail -30 "${TMP}/os-core-build.log" || true
[[ "$BUILD_RC" -eq 0 ]] && pass "os_core build exit 0" || fail "os_core build rc=${BUILD_RC}"
PKG="$(ls "$OS_OUT"/ubuntu-os-core-xenial-to-noble-lifecycleRt001.tar)"
[[ -f "$PKG" ]] || { fail "os core tar missing"; echo "ROUNDTRIP_RESULT=FAIL"; exit 1; }

set +e
python3 "$OS_CORE_PY" verify --package "$PKG" >"${TMP}/os-core-verify.log" 2>&1
VER_RC=$?
set -e
tail -30 "${TMP}/os-core-verify.log" || true
[[ "$VER_RC" -eq 0 ]] && pass "os_core verify exit 0" || fail "os_core verify rc=${VER_RC}"

python3 - <<'PY' "$PKG" "$PLAN_A" "$DISCOVERY_A" "$CONTRACT_A" || FAIL=1
import hashlib, json, os, sys, tarfile, tempfile
pkg, plan_a, disc_a, contract_a = sys.argv[1:5]
td = tempfile.mkdtemp()
with tarfile.open(pkg, "r:") as tf:
    tf.extractall(td)
root = os.path.join(td, "ubuntu-os-core")
manifest = json.load(open(os.path.join(root, "manifest.json")))
payload_sum = os.path.join(root, "payload.sha256")
actual_payload_manifest = hashlib.sha256(open(payload_sum, "rb").read()).hexdigest()
ok = True
def check(name, got, want):
    global ok
    if got != want:
        print("  FAIL: %s got=%s want=%s" % (name, str(got)[:20], str(want)[:20]))
        ok = False
    else:
        print("  PASS: %s" % name)
check("selective_plan_checksum", manifest.get("selective_plan_checksum"), plan_a)
check("discovery_artifact_checksum", manifest.get("discovery_artifact_checksum"), disc_a)
check("aws_semantic_contract_sha256", manifest.get("aws_semantic_contract_sha256"), contract_a)
check("payload_manifest_sha256", manifest.get("payload_manifest_sha256"), actual_payload_manifest)
if manifest.get("discovery_artifact_checksum") == manifest.get("payload_manifest_sha256"):
    print("  FAIL: DISCOVERY_A == payload_manifest_sha256")
    ok = False
else:
    print("  PASS: DISCOVERY_A != payload_manifest_sha256")
if int(manifest.get("schema_version", -1)) != 2:
    print("  FAIL: schema_version=%s want=2" % manifest.get("schema_version"))
    ok = False
else:
    print("  PASS: schema_version=2")
for rel in (
    "payload/state/plan.json",
    "payload/state/aws-semantic-contract.json",
):
    if not os.path.isfile(os.path.join(root, rel)):
        print("  FAIL: missing %s" % rel)
        ok = False
    else:
        print("  PASS: embedded %s" % rel)
sys.exit(0 if ok else 1)
PY

# ---------------------------------------------------------------------------
# 7b. Pool-path independence regression (shared tree validator)
# ---------------------------------------------------------------------------
# Binary package linux-aws may live under source-package pool dir linux-meta-aws.
# Release gate must not reconstruct pool/main/<pkg[0]>/<pkg>/...
echo "=== 7b. AWS tree validator pool-path independence ==="
python3 - <<'PY' "$ROOT" || FAIL=1
import hashlib, os, sys, tempfile
sys.path.insert(0, os.path.join(sys.argv[1], "scripts", "lib"))
import discovery_profiles as dp
import aws_os_core_completeness as aws_c
from collections import OrderedDict

def ident(package, version, blob, arch="amd64"):
    sha = hashlib.sha256(blob).hexdigest()
    return OrderedDict([
        ("package", package),
        ("version", version),
        ("architecture", arch),
        ("sha256", sha),
        ("filename", "%s_%s_%s.deb" % (package, version, arch)),
        ("size_bytes", len(blob)),
    ])

release_by_hop = {
    "xenial-to-bionic": ("5.4.0.1103.81", "5.4.0-1103-aws"),
    "bionic-to-focal": ("5.15.0.1084.91~20.04.1", "5.15.0-1084-aws"),
    "focal-to-jammy": ("6.8.0-1063.66~22.04.1", "6.8.0-1063-aws"),
    "jammy-to-noble": ("7.0.0-1011.11~24.04.1", "7.0.0-1011-aws"),
}

tmp = tempfile.mkdtemp(prefix="um-pool-path-reg-")
try:
    hops = OrderedDict()
    for hop in dp.HOPS:
        ver, rel = release_by_hop[hop]
        img = "linux-image-%s" % rel
        la_blob = ("REG|%s|linux-aws|%s" % (hop, ver)).encode()
        li_blob = ("REG|%s|linux-image-aws|%s" % (hop, ver)).encode()
        vi_blob = ("REG|%s|%s|%s" % (hop, img, ver)).encode()
        la = ident("linux-aws", ver, la_blob)
        li = ident("linux-image-aws", ver, li_blob)
        vi = ident(img, ver, vi_blob)
        snap = None
        if hop == "xenial-to-bionic":
            snap = ident("snapd", "2.58+18.04.1", b"REG|x2b|snapd")
        hops[hop] = OrderedDict([
            ("hop", hop),
            ("source_series", hop.split("-to-")[0]),
            ("target_series", hop.split("-to-")[1]),
            ("source_version_id", aws_c.HOP_SOURCE_VERSION_ID[hop]),
            ("target_version_id", aws_c.HOP_TARGET_VERSION_ID[hop]),
            ("linux_aws", la),
            ("linux_image_aws", li),
            ("expected_kernel_releases", [rel]),
            ("versioned_images", [vi]),
            ("boot_packages", []),
            ("snapd", snap),
        ])
        # CRITICAL: plant under source-package-style pool dir, NOT binary pkg name.
        ubuntu = os.path.join(tmp, "hops", hop, "ubuntu")
        meta_pool = os.path.join(ubuntu, "pool", "main", "l", "linux-meta-aws")
        os.makedirs(meta_pool)
        open(os.path.join(meta_pool, la["filename"]), "wb").write(la_blob)
        open(os.path.join(meta_pool, li["filename"]), "wb").write(li_blob)
        img_pool = os.path.join(ubuntu, "pool", "main", "l", "linux-signed-aws")
        os.makedirs(img_pool)
        open(os.path.join(img_pool, vi["filename"]), "wb").write(vi_blob)
        if snap:
            snap_pool = os.path.join(ubuntu, "pool", "main", "s", "snapd")
            os.makedirs(snap_pool)
            open(os.path.join(snap_pool, snap["filename"]), "wb").write(b"REG|x2b|snapd")

    contract = OrderedDict([
        ("schema_version", aws_c.CONTRACT_SCHEMA_VERSION),
        ("discovery_profiles", ["generic", "aws"]),
        ("required_metapackages", list(aws_c.REQUIRED_AWS_METAPACKAGES)),
        ("hops", hops),
        ("by_target_version_id", OrderedDict(
            (aws_c.HOP_TARGET_VERSION_ID[h], h) for h in dp.HOPS
        )),
    ])
    aws_c.attach_contract_sha256(contract)
    plan = {
        "discovery_profiles": ["generic", "aws"],
        "aws_semantic_contract": contract,
        "aws_semantic_contract_sha256": contract["contract_sha256"],
    }

    ok, errors, detail = aws_c.validate_tree_aws_completeness(
        tmp, plan=plan, require_aws_profile=True, verify_sha256=True,
    )
    if not ok:
        print("  FAIL: source-package pool path should PASS: %s" % (errors[:5],))
        sys.exit(1)
    print("  PASS: linux-aws under linux-meta-aws pool dir validates")

    # Negative: SHA mismatch must FAIL
    bad_hop = "xenial-to-bionic"
    bad_path = os.path.join(
        tmp, "hops", bad_hop, "ubuntu", "pool", "main", "l", "linux-meta-aws",
        hops[bad_hop]["linux_aws"]["filename"],
    )
    open(bad_path, "wb").write(b"TAMPERED-BYTES-NOT-MATCHING-CONTRACT-SHA")
    ok2, errors2, _ = aws_c.validate_tree_aws_completeness(
        tmp, plan=plan, require_aws_profile=True, verify_sha256=True,
    )
    if ok2:
        print("  FAIL: SHA-mismatched identity should FAIL")
        sys.exit(1)
    if not any("sha256_mismatch" in e for e in errors2):
        print("  FAIL: expected sha256_mismatch error, got: %s" % (errors2[:5],))
        sys.exit(1)
    print("  PASS: SHA-mismatched identity FAILS")

    # Negative: absent identity must FAIL
    os.remove(bad_path)
    ok3, errors3, _ = aws_c.validate_tree_aws_completeness(
        tmp, plan=plan, require_aws_profile=True, verify_sha256=True,
    )
    if ok3:
        print("  FAIL: absent identity should FAIL")
        sys.exit(1)
    if not any("missing" in e for e in errors3):
        print("  FAIL: expected missing error, got: %s" % (errors3[:5],))
        sys.exit(1)
    print("  PASS: absent identity FAILS")
    print("POOL_PATH_ASSUMPTION_REGRESSION=PASS")
finally:
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)
PY

# ---------------------------------------------------------------------------
# 7c. Release-gate harness against the tiny schema-v2 candidate
# ---------------------------------------------------------------------------
# Exercises the real run_release_gate.sh (shared AWS tree validator + Phase2
# test fixture). Does NOT contact R2 or a DP. Does NOT build another candidate.
echo "=== 7c. release gate harness (tiny schema-v2 candidate) ==="
set +e
bash "${ROOT}/tests/run_release_gate.sh" --os-core "$PKG" \
  >"${TMP}/release-gate.log" 2>&1
RG_RC=$?
set -e
tail -80 "${TMP}/release-gate.log" || true
if [[ "$RG_RC" -eq 0 ]] \
  && grep -q 'RELEASE_GATE_RESULT=PASS' "${TMP}/release-gate.log" \
  && grep -q 'AWS_PHYSICAL_PRESENCE=PASS' "${TMP}/release-gate.log" \
  && grep -q 'AWS_EXACT_SHA256=PASS' "${TMP}/release-gate.log" \
  && grep -q 'PHASE2_INPUT_MODE=TEST_FIXTURE' "${TMP}/release-gate.log" \
  && grep -q 'PHASE2_RELEASE_READINESS=NOT_TESTED' "${TMP}/release-gate.log" \
  && grep -q 'POOL_PATH_RECONSTRUCTION=NO' "${TMP}/release-gate.log"; then
  pass "release gate harness PASS"
  echo "TINY_RELEASE_GATE_RESULT=PASS"
  echo "RELEASE_GATE_HARNESS_INTEGRATION=PASS"
else
  fail "release gate harness (rc=${RG_RC})"
  echo "TINY_RELEASE_GATE_RESULT=FAIL"
  echo "RELEASE_GATE_HARNESS_INTEGRATION=FAIL"
fi

# ---------------------------------------------------------------------------
# 8. Real engine_materialize_os_mirror onto empty Mirror
# ---------------------------------------------------------------------------
echo "=== 8. real engine_materialize_os_mirror ==="
export MM_PROJECT_ROOT="$ROOT"
export MM_SKIP_ROOT_CHECK=1
export MM_MIRROR_ROOT="${TMP}/fresh-mirror"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export MM_STATE_ROOT="${TMP}/mm-state"
export MM_LOG_DIR="${TMP}/mm-logs"
export MM_CONFIG_DIR="${TMP}/mm-config"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_SELECTIVE_ROOT="${MM_MIRROR_ROOT}/selective"
export MM_CLIENT_ROOT="${MM_MIRROR_ROOT}/client"
export MM_LOCK_FILE="${TMP}/install.lock"
export LOCAL_CLIENT_SIGNING_DIR="${CLIENT_SIGNING_DIR}"
export PREPARATION_MODE=FULL

mkdir -p "$MM_CACHE_ROOT" "$MM_LOG_DIR" "$MM_STATE_ROOT" "$MM_CONFIG_DIR" \
  "$MM_CLIENT_ROOT" "$MM_DP_PHASE2_ROOT" "$MM_SELECTIVE_ROOT"

# Prove destination started empty (no state/plan.json)
[[ ! -f "${MM_SELECTIVE_ROOT}/state/plan.json" ]] \
  && pass "FRESH_MIRROR_STARTED_EMPTY (no state/plan.json)" \
  || fail "fresh mirror already had plan.json"
echo "FRESH_MIRROR_STARTED_EMPTY=YES"

# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "$COMMON"
# shellcheck source=../scripts/lib/mirror_install_engine.sh
source "$ENGINE"
mm_state_init
engine_resolve_paths

set +e
engine_materialize_os_mirror "$PKG" >"${TMP}/engine-materialize.log" 2>&1
ENG_RC=$?
set -e
tail -40 "${TMP}/engine-materialize.log" || true
[[ "$ENG_RC" -eq 0 ]] && pass "engine_materialize_os_mirror exit 0" || fail "engine rc=${ENG_RC}"

[[ -f "${MM_SELECTIVE_ROOT}/state/READY" ]] && pass "READY exists after engine materialize" \
  || fail "READY missing after engine materialize"
[[ -f "${MM_SELECTIVE_ROOT}/state/plan.json" ]] && pass "plan.json restored" \
  || fail "plan.json missing after materialize"
[[ -f "${MM_SELECTIVE_ROOT}/state/aws-semantic-contract.sh.inc" ]] \
  && pass "aws-semantic-contract.sh.inc restored" \
  || fail "contract bash missing"

python3 - <<'PY' "$MM_SELECTIVE_ROOT" "$PLAN_A" "$DISCOVERY_A" "$CONTRACT_A" "$ROOT" || FAIL=1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[5], "scripts", "lib"))
from aws_os_core_completeness import load_verified_selective_generation
gen = load_verified_selective_generation(sys.argv[1], project_root=sys.argv[5])
plan_b = gen["plan_checksum"]
disc_b = gen["discovery_artifact_checksum"]
contract_b = gen["aws_semantic_contract_sha256"]
open(os.path.join(sys.argv[1], "state", ".tuple-b.env"), "w").write(
    "PLAN_B=%s\nDISCOVERY_B=%s\nCONTRACT_B=%s\n" % (plan_b, disc_b, contract_b)
)
assert plan_b == sys.argv[2], (plan_b, sys.argv[2])
assert disc_b == sys.argv[3], (disc_b, sys.argv[3])
assert contract_b == sys.argv[4], (contract_b, sys.argv[4])
print("PLAN_B == PLAN_A")
print("DISCOVERY_B == DISCOVERY_A")
print("CONTRACT_B == CONTRACT_A")
print("load_verified_selective_generation=PASS")
PY
# shellcheck disable=SC1090
source "${MM_SELECTIVE_ROOT}/state/.tuple-b.env"
echo "PLAN_B=${PLAN_B}"
echo "DISCOVERY_B=${DISCOVERY_B}"
echo "CONTRACT_B=${CONTRACT_B}"
[[ "$PLAN_B" == "$PLAN_A" ]] && pass "PLAN_CHECKSUM_ROUNDTRIP" || fail "PLAN_B != PLAN_A"
[[ "$DISCOVERY_B" == "$DISCOVERY_A" ]] && pass "DISCOVERY_CHECKSUM_ROUNDTRIP" || fail "DISCOVERY mismatch"
[[ "$CONTRACT_B" == "$CONTRACT_A" ]] && pass "CONTRACT_SHA_ROUNDTRIP" || fail "CONTRACT mismatch"

# ---------------------------------------------------------------------------
# 9. Real four-hop client build after fresh materialization
# ---------------------------------------------------------------------------
echo "=== 9. real client build (CONTENT_SOURCE=local-fs) ==="
MIRROR_URL="http://192.0.2.99"
CACHE="${MM_MIRROR_ROOT}/.install-cache"
mkdir -p "$MM_CLIENT_ROOT" "$CACHE"

# Ensure shared offline upgraders exist for client builders that probe them.
for codename in bionic focal jammy noble; do
  src="${UPGRADERS_ROOT}/${codename}"
  dst="${MM_SELECTIVE_ROOT}/shared/offline/release-upgraders/${codename}"
  if [[ -d "$src" ]]; then
    mkdir -p "$dst"
    cp -a "${src}/." "$dst/" 2>/dev/null || true
  fi
done
mkdir -p "${MM_SELECTIVE_ROOT}/shared/offline"
[[ -f "${MM_SELECTIVE_ROOT}/shared/offline/meta-release-lts" ]] \
  || printf '# meta\n' >"${MM_SELECTIVE_ROOT}/shared/offline/meta-release-lts"

# Seed minimal published Phase 2 bundle so upgrade-phase2.sh can bind a SHA.
client_fixture_populate_dp_phase2 "$MM_MIRROR_ROOT"

CLIENT_LOG="${TMP}/client-rebuild.log"
set +e
if command -v unshare >/dev/null 2>&1 && unshare -n true 2>/dev/null; then
  unshare -n env \
    MIRROR_HTTP_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_BASE_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_HOST_IPV4="192.0.2.99" \
    LOCAL_CLIENT_SIGNING_DIR="$LOCAL_CLIENT_SIGNING_DIR" \
    CLIENT_HTTP_ROOT="$MM_CLIENT_ROOT" \
    SELECTIVE_ROOT="$MM_SELECTIVE_ROOT" \
    BASE_PATH="$MM_MIRROR_ROOT" \
    CACHE_ROOT="$CACHE" \
    CONTENT_SOURCE=local-fs \
    MM_HERMETIC_TEST_MODE=1 \
    CLIENT_BUILD_PIN_URL_ONLY=1 \
    SKIP_HTTP_VERIFY=1 \
    REQUIRE_SELECTIVE_READY=1 \
    bash "$REBUILD_CLIENTS" \
    >"$CLIENT_LOG" 2>&1
  CLIENT_RC=$?
  echo "NO_NETWORK_METHOD=unshare -n"
else
  env \
    MIRROR_HTTP_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_BASE_URL="$MIRROR_URL" \
    RESOLVED_MIRROR_HOST_IPV4="192.0.2.99" \
    LOCAL_CLIENT_SIGNING_DIR="$LOCAL_CLIENT_SIGNING_DIR" \
    CLIENT_HTTP_ROOT="$MM_CLIENT_ROOT" \
    SELECTIVE_ROOT="$MM_SELECTIVE_ROOT" \
    BASE_PATH="$MM_MIRROR_ROOT" \
    CACHE_ROOT="$CACHE" \
    CONTENT_SOURCE=local-fs \
    MM_HERMETIC_TEST_MODE=1 \
    CLIENT_BUILD_PIN_URL_ONLY=1 \
    SKIP_HTTP_VERIFY=1 \
    REQUIRE_SELECTIVE_READY=1 \
    bash "$REBUILD_CLIENTS" \
    >"$CLIENT_LOG" 2>&1
  CLIENT_RC=$?
  echo "NO_NETWORK_METHOD=rfc5737-unreachable-url"
fi
set -e
tail -60 "$CLIENT_LOG" || true

if [[ "$CLIENT_RC" -eq 0 ]] \
  && grep -q 'CLIENT_BUILD_CONTENT_SOURCE=LOCAL_FILESYSTEM' "$CLIENT_LOG" \
  && grep -q 'CLIENT_BUILD_NETWORK_REQUIRED=NO' "$CLIENT_LOG" \
  && grep -q 'REBUILD_PUBLISH_CLIENTS=PASS' "$CLIENT_LOG"; then
  pass "real client rebuild PASS"
  echo "REAL_CLIENT_BUILD_COVERED=YES"
  echo "REAL_CLIENT_BUILD_AFTER_R2_ROUNDTRIP=PASS"
else
  fail "real client rebuild (rc=${CLIENT_RC})"
  echo "REAL_CLIENT_BUILD_COVERED=NO"
  echo "REAL_CLIENT_BUILD_AFTER_R2_ROUNDTRIP=FAIL"
fi

HOP_OK=1
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  script="${MM_CLIENT_ROOT}/dp-offline-upgrade-${hop}.sh"
  manifest="${MM_CLIENT_ROOT}/${hop}/client-manifest.json"
  [[ -f "$script" ]] || { fail "missing client script ${hop}"; HOP_OK=0; continue; }
  [[ -f "$manifest" ]] || { fail "missing client manifest ${hop}"; HOP_OK=0; continue; }
  python3 - <<'PY' "$manifest" "$PLAN_A" "$DISCOVERY_A" "$CONTRACT_A" "$hop" || HOP_OK=0
import json, sys
m = json.load(open(sys.argv[1]))
plan_a, disc_a, contract_a, hop = sys.argv[2:6]
ok = True
if m.get("plan_checksum") != plan_a:
    print("  FAIL: %s plan_checksum mismatch" % hop); ok = False
if m.get("discovery_checksum") != disc_a:
    print("  FAIL: %s discovery_checksum mismatch" % hop); ok = False
if m.get("aws_semantic_contract_sha256") != contract_a:
    print("  FAIL: %s aws_semantic_contract_sha256 mismatch" % hop); ok = False
if ok:
    print("  PASS: %s client manifest tuple matches PLAN_A/DISCOVERY_A/CONTRACT_A" % hop)
sys.exit(0 if ok else 1)
PY
done
[[ "$HOP_OK" -eq 1 ]] && pass "all four hop client manifests bound to generation A" \
  || fail "client manifest tuple mismatch"

END_TS="$(date +%s)"
DURATION=$((END_TS - START_TS))
echo "ROUNDTRIP_DURATION_SECONDS=${DURATION}"

if [[ "$FAIL" -eq 0 ]]; then
  echo "PRODUCTION_LIFECYCLE_ROUNDTRIP=PASS"
  echo "REAL_PRODUCTION_LIFECYCLE_ROUNDTRIP=PASS"
  echo "RELEASE_GATE_HARNESS_INTEGRATION=PASS"
  echo "ROUNDTRIP_RESULT=PASS"
  exit 0
fi
echo "PRODUCTION_LIFECYCLE_ROUNDTRIP=FAIL"
echo "REAL_PRODUCTION_LIFECYCLE_ROUNDTRIP=FAIL"
echo "RELEASE_GATE_HARNESS_INTEGRATION=FAIL"
echo "ROUNDTRIP_RESULT=FAIL"
exit 1
