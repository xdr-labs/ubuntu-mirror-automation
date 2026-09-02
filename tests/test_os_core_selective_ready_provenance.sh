#!/usr/bin/env bash
# P0 regression: OS Core packages without state/READY must still materialize a
# verified selective READY provenance so client finalization can proceed.
# Proves the 35d4cc2 contract contradiction (OS_MIRROR_READY=PASS but READY missing).
# UNIT_ONLY=YES — mocks engine_rebuild_publish_local_client_set; REAL_CLIENT_BUILD_COVERED=NO
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/seed_complete_client_http_set.sh
source "${ROOT}/tests/lib/seed_complete_client_http_set.sh"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
OS_CORE_PY="${ROOT}/scripts/lib/os_core_package.py"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

echo "=== test_os_core_selective_ready_provenance ==="
echo "UNIT_ONLY=YES"
echo "REAL_CLIENT_BUILD_COVERED=NO"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

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
export LOCAL_CLIENT_SIGNING_DIR="${MM_CONFIG_DIR}/client-signing"
export PREPARATION_MODE=FULL

mkdir -p "$MM_CACHE_ROOT" "$MM_LOG_DIR" "$MM_STATE_ROOT" "$MM_CONFIG_DIR" \
  "$MM_CLIENT_ROOT" "$MM_DP_PHASE2_ROOT"

# --- Build a production-shaped OS Core package WITHOUT state/READY ---
SEL="${TMP}/sel-src"
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  mkdir -p "${SEL}/published/hops/${hop}/ubuntu/pool" \
    "${SEL}/published/hops/${hop}/ubuntu/dists"
  printf 'pkg-%s\n' "$hop" >"${SEL}/published/hops/${hop}/ubuntu/pool/hello.deb"
  printf 'Release-%s\n' "$hop" >"${SEL}/published/hops/${hop}/ubuntu/dists/Release"
done
mkdir -p "${SEL}/published/shared/offline/release-upgraders/bionic"
printf 'meta\n' >"${SEL}/published/shared/offline/meta-release-lts"
printf 'upgrader\n' >"${SEL}/published/shared/offline/release-upgraders/bionic/bionic.tar.gz"
printf 'upgrader-sig\n' >"${SEL}/published/shared/offline/release-upgraders/bionic/bionic.tar.gz.gpg"
ln -sfn hops/jammy-to-noble/ubuntu "${SEL}/published/ubuntu"
mkdir -p "${SEL}/keys"
printf 'SELECTIVE-PUBLIC-KEY\n' >"${SEL}/keys/ubuntu-mirror-selective.gpg"

OUT="${TMP}/pkg-out"
mkdir -p "$OUT"
python3 "$OS_CORE_PY" build \
  --selective-root "$SEL" \
  --output-dir "$OUT" \
  --project-root "$ROOT" \
  --release-id reproReady001

PKG="$(ls "$OUT"/ubuntu-os-core-xenial-to-noble-reproReady001.tar)"
[[ -f "$PKG" ]] || { echo "package missing"; exit 1; }

# Prove package payload has no state/READY (current R2 contract).
EXTRACT="${TMP}/pkg-list"
mkdir -p "$EXTRACT"
tar -tf "$PKG" >"${TMP}/tar.list"
if grep -E 'payload/state/READY|/state/READY$' "${TMP}/tar.list" >/dev/null; then
  fail "fixture package unexpectedly contains state/READY"
else
  pass "fixture package has no state/READY (production-like)"
fi

# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "$COMMON"
# shellcheck source=../scripts/lib/mirror_install_engine.sh
source "$ENGINE"

mm_state_init
engine_resolve_paths

echo "=== 1. materialize OS Core package without READY ==="
set +e
engine_materialize_os_mirror "$PKG" >"${TMP}/materialize.log" 2>&1
mrc=$?
set -e
cat "${TMP}/materialize.log" | tail -40

[[ "$mrc" -eq 0 ]] \
  && pass "engine_materialize_os_mirror exit 0" \
  || fail "engine_materialize_os_mirror rc=${mrc}"

os_ready="$(mm_status_get OS_MIRROR_READY 2>/dev/null || true)"
[[ "$os_ready" == "PASS" ]] || os_ready="$(grep -E 'OS_MIRROR_READY|OS_MIRROR_MATERIALIZE=PASS' "${TMP}/materialize.log" | tail -1 || true)"
grep -q 'OS_MIRROR_MATERIALIZE=PASS\|OS_MIRROR_READY' "${TMP}/materialize.log" \
  && pass "OS_MIRROR materialize logged PASS" \
  || fail "OS_MIRROR materialize PASS missing"

READY_PATH="${MM_SELECTIVE_ROOT}/state/READY"
if [[ -f "$READY_PATH" ]]; then
  pass "SELECTIVE READY exists after materialize"
else
  fail "SELECTIVE READY missing after materialize (35d4cc2 regression)"
fi

echo "=== 2. provenance checksums must be real hex digests ==="
if [[ -f "$READY_PATH" ]]; then
  plan="$(awk -F= '/^selective_plan_checksum=/{print $2; exit}' "$READY_PATH")"
  disc="$(awk -F= '/^discovery_artifact_checksum=/{print $2; exit}' "$READY_PATH")"
  if [[ "$plan" =~ ^[0-9a-fA-F]{64}$ ]]; then
    pass "selective_plan_checksum is 64-hex"
  else
    fail "selective_plan_checksum invalid='${plan}'"
  fi
  if [[ "$disc" =~ ^[0-9a-fA-F]{64}$ ]]; then
    pass "discovery_artifact_checksum is 64-hex"
  else
    fail "discovery_artifact_checksum invalid='${disc}'"
  fi
  if [[ -z "$plan" || -z "$disc" || "$plan" == "PASS" || "$disc" == "PASS" ]]; then
    fail "empty or fake checksum values"
  else
    pass "checksums are non-empty and not fake PASS tokens"
  fi
  grep -qE 'OS_CORE_PROVENANCE_SOURCE=|os_core_provenance_source=' "${TMP}/materialize.log" "$READY_PATH" \
    && pass "provenance source logged" \
    || fail "OS_CORE_PROVENANCE_SOURCE missing"
fi

echo "=== 3. finalize must not die with SELECTIVE_READY=MISSING ==="
# Mock rebuild: only prove finalization gate passes when READY is present.
engine_rebuild_publish_local_client_set() {
  seed_complete_client_http_set "$MM_CLIENT_ROOT" "http://192.0.2.10"     "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  return 0
}
mm_status_set OS_MIRROR_READY PASS
set +e
engine_finalize_local_client_set >"${TMP}/finalize.log" 2>&1
frc=$?
set -e
if grep -q 'SELECTIVE_READY=MISSING' "${TMP}/finalize.log"; then
  fail "finalize still reports SELECTIVE_READY=MISSING"
else
  pass "finalize does not report SELECTIVE_READY=MISSING"
fi
[[ "$frc" -eq 0 ]] \
  && pass "CLIENT_SET_FINALIZATION path exit 0" \
  || { fail "finalize rc=${frc}"; tail -30 "${TMP}/finalize.log"; }
grep -q 'CLIENT_SET_FINALIZATION=PASS\|CLIENT_FILES_READY=PASS' "${TMP}/finalize.log" \
  && pass "CLIENT_SET_FINALIZATION/CLIENT_FILES_READY PASS" \
  || fail "finalization PASS markers missing"

echo "=== 4. tamper / malformed READY rejected ==="
if declare -F engine_verify_selective_ready_provenance >/dev/null 2>&1; then
  printf 'READY\nselective_plan_checksum=\ndiscovery_artifact_checksum=\n' \
    >"${MM_SELECTIVE_ROOT}/state/READY"
  if engine_verify_selective_ready_provenance >"${TMP}/bad-empty.log" 2>&1; then
    fail "empty checksum READY should FAIL verify"
  else
    pass "empty checksum READY rejected"
  fi
  printf 'READY\nselective_plan_checksum=not-hex\ndiscovery_artifact_checksum=%s\n' \
    "$(printf 'a%.0s' {1..64})" >"${MM_SELECTIVE_ROOT}/state/READY"
  if engine_verify_selective_ready_provenance >"${TMP}/bad-malformed.log" 2>&1; then
    fail "malformed checksum READY should FAIL verify"
  else
    pass "malformed checksum READY rejected"
  fi
else
  fail "engine_verify_selective_ready_provenance missing"
fi

echo "=== 5. legacy READY with valid checksums is reusable ==="
printf 'READY\nselective_plan_checksum=%s\ndiscovery_artifact_checksum=%s\nplan_checksum=%s\n' \
  "$(printf 'b%.0s' {1..64})" \
  "$(printf 'c%.0s' {1..64})" \
  "$(printf 'b%.0s' {1..64})" \
  >"${MM_SELECTIVE_ROOT}/state/READY"
if engine_verify_selective_ready_provenance >"${TMP}/legacy.log" 2>&1; then
  pass "legacy READY with valid checksums accepted"
else
  fail "legacy READY verify failed"
fi

echo "=== 6. backward-compat: package WITHOUT manifest provenance fields ==="
# Simulate currently deployed R2 packages: strip checksum fields from manifest,
# rebuild tar, materialize — must still derive READY from sha256(manifest)+sha256(payload.sha256).
OLD_DIR="${TMP}/old-pkg"
mkdir -p "$OLD_DIR"
tar -C "$OLD_DIR" -xf "$PKG"
python3 - <<'PY' "$OLD_DIR"
import json, sys, os
root = os.path.join(sys.argv[1], "ubuntu-os-core")
mp = os.path.join(root, "manifest.json")
with open(mp) as fh:
    m = json.load(fh)
for k in ("selective_plan_checksum", "discovery_artifact_checksum"):
    m.pop(k, None)
with open(mp, "w") as fh:
    json.dump(m, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
OLD_TAR="${TMP}/ubuntu-os-core-xenial-to-noble-oldR2.tar"
tar -C "$OLD_DIR" -cf "$OLD_TAR" ubuntu-os-core
sha256sum "$OLD_TAR" | awk '{print $1"  ubuntu-os-core-xenial-to-noble-oldR2.tar"}' \
  >"${OLD_TAR}.sha256"
# Reset selective root
rm -rf "$MM_SELECTIVE_ROOT"
set +e
engine_materialize_os_mirror "$OLD_TAR" >"${TMP}/old-materialize.log" 2>&1
orc=$?
set -e
[[ "$orc" -eq 0 ]] && pass "old R2-shaped package materialize PASS" \
  || { fail "old package materialize rc=${orc}"; tail -20 "${TMP}/old-materialize.log"; }
grep -q 'OS_CORE_PROVENANCE_SOURCE=PACKAGE_MANIFEST_AND_PAYLOAD_SHA256' "${TMP}/old-materialize.log" \
  && pass "old package uses PACKAGE_MANIFEST_AND_PAYLOAD_SHA256 provenance" \
  || fail "old package provenance source wrong"
[[ -f "${MM_SELECTIVE_ROOT}/state/READY" ]] \
  && pass "old package produced READY" \
  || fail "old package READY missing"
old_plan="$(awk -F= '/^selective_plan_checksum=/{print $2; exit}' "${MM_SELECTIVE_ROOT}/state/READY")"
old_disc="$(awk -F= '/^discovery_artifact_checksum=/{print $2; exit}' "${MM_SELECTIVE_ROOT}/state/READY")"
want_plan="$(sha256sum "${OLD_DIR}/ubuntu-os-core/manifest.json" | awk '{print $1}')"
want_disc="$(sha256sum "${OLD_DIR}/ubuntu-os-core/payload.sha256" | awk '{print $1}')"
[[ "$old_plan" == "$want_plan" ]] \
  && pass "old package plan checksum == sha256(manifest.json)" \
  || fail "old plan mismatch got=$old_plan want=$want_plan"
[[ "$old_disc" == "$want_disc" ]] \
  && pass "old package discovery checksum == sha256(payload.sha256)" \
  || fail "old discovery mismatch"

echo "=== 7. package manifest discovery tamper rejected ==="
TAMPER_DIR="${TMP}/tamper"
mkdir -p "$TAMPER_DIR"
tar -C "$TAMPER_DIR" -xf "$PKG"
python3 - <<'PY' "$TAMPER_DIR"
import json, sys, os
mp = os.path.join(sys.argv[1], "ubuntu-os-core", "manifest.json")
with open(mp) as fh:
    m = json.load(fh)
m["discovery_artifact_checksum"] = "0" * 64
with open(mp, "w") as fh:
    json.dump(m, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
# write-selective-ready should fail closed on discovery mismatch (payload still in tree)
set +e
python3 "$OS_CORE_PY" write-selective-ready \
  --package-root "${TAMPER_DIR}/ubuntu-os-core" \
  --selective-root "${TMP}/tamper-sel" >"${TMP}/tamper.out" 2>&1
trc=$?
set -e
[[ "$trc" -ne 0 ]] \
  && grep -q 'MANIFEST_DISCOVERY_MISMATCH\|OS_CORE_ERROR' "${TMP}/tamper.out" \
  && pass "manifest discovery tamper rejected" \
  || fail "manifest discovery tamper not rejected"

echo "=== 8. Phase2-only does not require OS-hop READY ==="
PREPARATION_MODE=PHASE2_ONLY
export PREPARATION_MODE
rm -rf "$MM_SELECTIVE_ROOT"
mkdir -p "$MM_CLIENT_ROOT" "${MM_MIRROR_ROOT}/dp-phase2/6.6.0"
printf '#!/bin/bash\necho stage\n' >"${MM_CLIENT_ROOT}/stage-dp-phase2.sh"
chmod +x "${MM_CLIENT_ROOT}/stage-dp-phase2.sh"
(cd "$MM_CLIENT_ROOT" && sha256sum stage-dp-phase2.sh >stage-dp-phase2.sh.sha256)
printf 'p2only-fixture\n' >"${MM_MIRROR_ROOT}/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar"
(
  cd "${MM_MIRROR_ROOT}/dp-phase2/6.6.0"
  sha256sum dp_bundle_6.6.0-current.tar >dp_bundle_6.6.0-current.tar.sha256
)
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
set +e
engine_finalize_local_client_set >"${TMP}/p2only.log" 2>&1
p2rc=$?
set -e
[[ "$p2rc" -eq 0 ]] \
  && pass "Phase2-only finalize without OS-hop READY" \
  || { fail "Phase2-only blocked by READY"; cat "${TMP}/p2only.log"; }
grep -q 'OS_HOP_CLIENT_FILES_REQUIRED=NO' "${TMP}/p2only.log" \
  && pass "OS_HOP_CLIENT_FILES_REQUIRED=NO logged" \
  || fail "Phase2-only hop-required flag missing"

echo "=== summary ==="
if [[ "$FAIL" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASS"
exit 0
