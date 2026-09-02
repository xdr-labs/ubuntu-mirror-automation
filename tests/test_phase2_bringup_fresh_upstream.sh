#!/usr/bin/env bash
# Fresh-upstream Phase 2 bringup patching: never replace ACPS with the frozen
# vendor full copy; preserve new upstream text; fail closed on drift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
DP2="${ROOT}/scripts/lib/dp-phase2-common.sh"
ACPS="${ROOT}/scripts/lib/acps_acquire.sh"
R2="${ROOT}/scripts/lib/r2_acquire.sh"
PATCHER="${ROOT}/scripts/lib/patch_dp_phase2_bringup.py"
FIXTURE="${ROOT}/tests/fixtures/dp-phase2/upstream_bringup_unpatched.sh"
PRODUCTION_F1A73="${ROOT}/tests/fixtures/dp-phase2/production-f1a73/bringup_py3_dp_after_os_upgrade.sh"
EXPECTED_F1A73_SHA1="f1a73c1d4502e2efcf55197865d2ade345d9c82f"
PRODUCTION_3AF369="${ROOT}/tests/fixtures/dp-phase2/production-3af369/bringup_py3_dp_after_os_upgrade.sh"
EXPECTED_3AF369_SHA1="3af369660c3e0dfb0b7421ab455dee1ced365b1d"
VENDOR="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
WRAPPER="${ROOT}/client/bringup_py3_dp_lifecycle.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

export MM_SKIP_ROOT_CHECK=1
export MM_PROJECT_ROOT="$ROOT"
export MM_MIRROR_ROOT="${WORKDIR}/mirror"
export MM_CACHE_ROOT="${WORKDIR}/mirror/.install-cache"
export MM_STATE_ROOT="${WORKDIR}/state"
export MM_STATE_DIR="${WORKDIR}/state/run"
export MM_LOG_DIR="${WORKDIR}/logs"
export MM_CONFIG_DIR="${WORKDIR}/config"
export MM_STATUS_FILE="${WORKDIR}/config/status"
export MM_LOCK_FILE="${WORKDIR}/install.lock"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_DRY_RUN=0
mkdir -p "$MM_STATE_DIR" "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$MM_CACHE_ROOT" \
  "$MM_DP_PHASE2_ROOT"

# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "$COMMON"
# shellcheck source=../scripts/lib/dp-phase2-common.sh
source "$DP2"
# shellcheck source=../scripts/lib/acps_acquire.sh
source "$ACPS"
# shellcheck source=../scripts/lib/r2_acquire.sh
source "$R2"
# shellcheck source=../scripts/lib/mirror_install_engine.sh
source "$ENGINE"
mm_state_init 2>/dev/null || true
dp2_set_version 6.6.0

CURRENT_GEN="$(engine_current_bringup_patch_generation)"
[[ -n "$CURRENT_GEN" ]] || { echo "missing patch generation" >&2; exit 1; }

write_sidecar_for() {
  local file="$1"
  sha1sum "$file" | awk '{print $1"  bringup_py3_dp_after_os_upgrade.sh"}' >"${file}.sha1"
}

run_in_subshell() {
  local out="$1"
  shift
  set +e
  ( set -euo pipefail; "$@" ) >"$out" 2>&1
  local rc=$?
  set -e
  printf '%s\n' "$rc"
}

run_verify_then_patch() {
  engine_verify_acps_upstream_bringup "$1"
  engine_apply_local_bringup_patch "$2" "${1}/bringup_py3_dp_after_os_upgrade.sh"
}

echo "======== test_phase2_bringup_fresh_upstream ========"

# Production engine must not copy the frozen vendor script over upstream.
if grep -nE 'cp -f[[:space:]]+"\$patched"[[:space:]]+"\$dest"' "$ENGINE"; then
  fail "E production still copies frozen vendor over dest"
else
  pass "E engine has no cp frozen-vendor dest"
fi
if grep -A2 'engine_apply_local_bringup_patch()' "$ENGINE" | grep -q 'vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh'; then
  fail "E apply still uses vendor full copy as patch input"
else
  pass "E apply does not use vendor full copy as patch input"
fi
grep -q 'BRINGUP_PATCH_MODEL=fresh_upstream_plus_project_layer' "$ENGINE" \
  && pass "E patch model documented in engine" \
  || fail "E patch model documented in engine"

# A. Fresh upstream without --worker-password → generated has it.
grep -q -- '--worker-password' "$FIXTURE" \
  && fail "A fixture unexpectedly contains --worker-password" \
  || pass "A fixture lacks --worker-password"
CACHEA="${WORKDIR}/cacheA"; mkdir -p "$CACHEA"
cp -f "$FIXTURE" "${CACHEA}/bringup_py3_dp_after_os_upgrade.sh"
write_sidecar_for "${CACHEA}/bringup_py3_dp_after_os_upgrade.sh"
WORKA="${WORKDIR}/workA"; mkdir -p "$WORKA"
OUTA="${WORKDIR}/a.log"
rca="$(run_in_subshell "$OUTA" engine_apply_local_bringup_patch "$WORKA" \
  "${CACHEA}/bringup_py3_dp_after_os_upgrade.sh")"
[[ "$rca" -eq 0 ]] && pass "A apply rc=0" || { fail "A apply rc=${rca}"; cat "$OUTA"; }
grep -q 'BRINGUP_PATCH_COMPAT=PASS' "$OUTA" && pass "A BRINGUP_PATCH_COMPAT=PASS" || fail "A BRINGUP_PATCH_COMPAT"
grep -q 'PATCHED_BRINGUP_GENERATION=PASS' "$OUTA" && pass "A PATCHED_BRINGUP_GENERATION=PASS" || fail "A generation log"
grep -q -- '--worker-password' "${WORKA}/bringup_py3_dp_after_os_upgrade.sh" \
  && pass "A generated has --worker-password" \
  || fail "A generated has --worker-password"
grep -q -- '--worker-password' "${WORKA}.upstream/bringup_py3_dp_after_os_upgrade.sh" \
  && fail "A immutable upstream copy gained --worker-password" \
  || pass "A saved upstream remains unpatched"
[[ "$(sha1sum "${WORKA}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')" \
    != "$(sha1sum "${CACHEA}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')" ]] \
  && pass "A generated differs from upstream" \
  || fail "A generated equals upstream (patch not applied)"
cmp -s "${CACHEA}/bringup_py3_dp_after_os_upgrade.sh" "$FIXTURE" \
  && pass "A cache upstream not mutated" \
  || fail "A cache upstream mutated"

# B. New upstream vendor fix survives.
CACHEB="${WORKDIR}/cacheB"; mkdir -p "$CACHEB"
sed 's/log "download_artifacts placeholder"/log "download_artifacts placeholder"\n    NEW_UPSTREAM_VENDOR_FIX_MARKER=YES/' \
  "$FIXTURE" >"${CACHEB}/bringup_py3_dp_after_os_upgrade.sh"
write_sidecar_for "${CACHEB}/bringup_py3_dp_after_os_upgrade.sh"
WORKB="${WORKDIR}/workB"; mkdir -p "$WORKB"
OUTB="${WORKDIR}/b.log"
rcb="$(run_in_subshell "$OUTB" engine_apply_local_bringup_patch "$WORKB" \
  "${CACHEB}/bringup_py3_dp_after_os_upgrade.sh")"
[[ "$rcb" -eq 0 ]] && pass "B apply rc=0" || { fail "B apply rc=${rcb}"; cat "$OUTB"; }
grep -q 'NEW_UPSTREAM_VENDOR_FIX_MARKER=YES' "${WORKB}/bringup_py3_dp_after_os_upgrade.sh" \
  && pass "B marker survived patch generation" \
  || fail "B marker survived patch generation"
grep -q 'MASTER_TOKEN_API_READY' "${WORKB}/bringup_py3_dp_after_os_upgrade.sh" \
  && grep -q 'APT_DEPENDENCY_CHECK' "${WORKB}/bringup_py3_dp_after_os_upgrade.sh" \
  && grep -q 'CLUSTER_JOIN_STATE' "${WORKB}/bringup_py3_dp_after_os_upgrade.sh" \
  && grep -q 'copy_phase2_prereq_contract_to_worker' "${WORKB}/bringup_py3_dp_after_os_upgrade.sh" \
  && pass "B project gates present with new upstream marker" \
  || fail "B project gates present with new upstream marker"

# C. Compatible SHA drift continues.
CACHEC="${WORKDIR}/cacheC"; mkdir -p "$CACHEC"
sed 's/log "download_artifacts placeholder"/log "download_artifacts placeholder"\n    # COMPATIBLE_UPSTREAM_DRIFT/' \
  "$FIXTURE" >"${CACHEC}/bringup_py3_dp_after_os_upgrade.sh"
write_sidecar_for "${CACHEC}/bringup_py3_dp_after_os_upgrade.sh"
OUTC="${WORKDIR}/c.log"
rcc="$(run_in_subshell "$OUTC" engine_verify_acps_upstream_bringup "$CACHEC")"
[[ "$rcc" -eq 0 ]] && pass "C verify rc=0" || { fail "C verify rc=${rcc}"; cat "$OUTC"; }
grep -q 'UPSTREAM_BRINGUP_CHANGED=YES' "$OUTC" && pass "C UPSTREAM_BRINGUP_CHANGED=YES" || fail "C changed warning"
grep -q 'UPSTREAM_LAYOUT_ANCHORS=PASS' "$OUTC" && pass "C layout anchors PASS" || fail "C layout anchors"
grep -q 'BRINGUP_PATCH_COMPAT=PASS' "$OUTC" && pass "C patcher validate PASS" || fail "C patcher validate"
WORKC="${WORKDIR}/workC"; mkdir -p "$WORKC"
OUTC2="${WORKDIR}/c2.log"
rcc2="$(run_in_subshell "$OUTC2" engine_apply_local_bringup_patch "$WORKC" \
  "${CACHEC}/bringup_py3_dp_after_os_upgrade.sh")"
[[ "$rcc2" -eq 0 ]] && pass "C patch generation PASS" || fail "C patch rc=${rcc2}"
grep -q 'COMPATIBLE_UPSTREAM_DRIFT' "${WORKC}/bringup_py3_dp_after_os_upgrade.sh" \
  && pass "C unrelated upstream text preserved" \
  || fail "C unrelated upstream text preserved"

# D. Incompatible exact patch target fails closed; no patched file written.
# Coarse layout still matches so SHA drift is non-blocking; the patcher
# itself rejects the mutated parse_args region (expected_count != 1).
CACHED="${WORKDIR}/cacheD"; mkdir -p "$CACHED"
python3 - "$FIXTURE" "${CACHED}/bringup_py3_dp_after_os_upgrade.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
src = src.replace(
    '            --worker-ips)\n'
    '                WORKER_IPS="$2"; shift 2 ;;\n'
    '            --role)\n',
    '            --worker-ips)\n'
    '                WORKER_IPS="$2"; shift 2 ;;\n'
    '            --worker-ips-alt)\n'
    '                : ;;\n'
    '            --role)\n',
)
open(sys.argv[2], 'w').write(src)
PY
write_sidecar_for "${CACHED}/bringup_py3_dp_after_os_upgrade.sh"
WORKD="${WORKDIR}/workD"; mkdir -p "$WORKD"
OUTD="${WORKDIR}/d.log"
rcd="$(run_in_subshell "$OUTD" run_verify_then_patch "$CACHED" "$WORKD")"
[[ "$rcd" -ne 0 ]] && pass "D incompat fails" || fail "D should fail"
grep -q 'BRINGUP_PATCH_COMPAT=FAIL' "$OUTD" && pass "D BRINGUP_PATCH_COMPAT=FAIL" || fail "D compat fail log"
grep -q 'PATCHED_BRINGUP_GENERATION=FAIL\|INSTALL_RESULT=FAIL' "$OUTD" \
  && pass "D generation/install FAIL" || fail "D generation/install FAIL"
grep -q 'BRINGUP_PATCH_COMPAT_FAIL_TRANSFORM=parse_args_worker_password_case' "$OUTD" \
  && pass "D FAIL_TRANSFORM" || fail "D FAIL_TRANSFORM missing"
grep -q 'BRINGUP_PATCH_COMPAT_FAIL_REASON=anchor_count=0 expected=1' "$OUTD" \
  && pass "D FAIL_REASON" || fail "D FAIL_REASON missing"
grep -E '\[ERROR\].*BRINGUP_PATCH_COMPAT_FAIL_TRANSFORM=parse_args_worker_password_case' "$OUTD" \
  && pass "D FAIL_TRANSFORM via mm_error" || { fail "D FAIL_TRANSFORM not operator-logged"; cat "$OUTD"; }
grep -E '\[ERROR\].*BRINGUP_PATCH_COMPAT_FAIL_REASON=anchor_count=0 expected=1' "$OUTD" \
  && pass "D FAIL_REASON via mm_error" || fail "D FAIL_REASON not operator-logged"
[[ ! -f "${WORKD}/bringup_py3_dp_after_os_upgrade.sh" ]] \
  && pass "D did not publish patched bringup" \
  || fail "D wrote patched bringup after incompat"

# I. Lifecycle wrapper still accepts --worker-password.
grep -q -- '--worker-password' "$WRAPPER" \
  && pass "I lifecycle wrapper has --worker-password" \
  || fail "I lifecycle wrapper has --worker-password"
grep -q -- '--worker-password' "${WORKA}/bringup_py3_dp_after_os_upgrade.sh" \
  && pass "I generated vendor supports --worker-password" \
  || fail "I generated vendor supports --worker-password"

# F. Same upstream, different patch-generation invalidates reuse.
DESTF="${MM_DP_PHASE2_ROOT}/6.6.0"
rm -rf "$DESTF"
mkdir -p "$DESTF"
make_work_tree() {
  local work="$1" bringup="$2"
  mkdir -p "$work"
  printf 'common\n' >"${work}/aelladeb_py3_common.tar.gz"
  sha1sum "${work}/aelladeb_py3_common.tar.gz" | awk '{print $1}' \
    >"${work}/aelladeb_py3_common.tar.gz.sha1"
  printf 'uvp\n' >"${work}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb"
  sha1sum "${work}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}' \
    >"${work}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
  cp -f "$bringup" "${work}/bringup_py3_dp_after_os_upgrade.sh"
  sha1sum "${work}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
    >"${work}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  seq 1 156 >"${work}/images-6.6.0.list"
  printf 'images-body\n' >"${work}/images-6.6.0.tar"
  sha256sum "${work}/images-6.6.0.tar" | awk '{print $1}' \
    >"${work}/images-6.6.0.tar.sha256"
}
WORKF="${WORKDIR}/workF"
make_work_tree "$WORKF" "${WORKA}/bringup_py3_dp_after_os_upgrade.sh"
mkdir -p "${WORKF}.upstream"
cp -f "$FIXTURE" "${WORKF}.upstream/bringup_py3_dp_after_os_upgrade.sh"
sha1sum "${WORKF}.upstream/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
  >"${WORKF}.upstream/bringup_py3_dp_after_os_upgrade.sh.sha1"
export MM_KEEP_PHASE2_SOURCES=1
BRINGUP_UPSTREAM_SHA1="$(sha1sum "$FIXTURE" | awk '{print $1}')"
BRINGUP_PATCH_GENERATION="$CURRENT_GEN"
BRINGUP_PATCHED_SHA1="$(sha1sum "${WORKF}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
engine_place_dp_phase2_final "$WORKF" 6.6.0 >/dev/null
grep -q "^BRINGUP_PATCH_GENERATION=${CURRENT_GEN}$" "${DESTF}/release.env" \
  && pass "F published patch generation" \
  || fail "F published patch generation"
engine_assess_phase2_final 6.6.0
[[ "$PHASE2_EXISTING_BUNDLE" == "VALID" ]] && pass "F current generation VALID" \
  || fail "F current generation VALID got=${PHASE2_EXISTING_BUNDLE}"
sed -i 's/^BRINGUP_PATCH_GENERATION=.*/BRINGUP_PATCH_GENERATION=ffffffffffffffffffffffffffffffffffffffff/' \
  "${DESTF}/release.env"
engine_assess_phase2_final 6.6.0
[[ "$PHASE2_EXISTING_BUNDLE" == "INVALID" ]] \
  && [[ "${PHASE2_EXISTING_INVALID_REASON}" == "patch_generation_changed" ]] \
  && pass "F patch-generation change invalidates reuse" \
  || fail "F want=patch_generation_changed got=${PHASE2_EXISTING_INVALID_REASON:-$PHASE2_EXISTING_BUNDLE}"

# G. Different upstream SHA, same patch generation → rebuild from new upstream.
sed -i "s/^BRINGUP_PATCH_GENERATION=.*/BRINGUP_PATCH_GENERATION=${CURRENT_GEN}/" \
  "${DESTF}/release.env"
# Restore VALID generation, then plant a cache with a new upstream SHA.
CACHEG="$(acps_cache_dir 6.6.0)"
mkdir -p "$CACHEG"
sed 's/log "download_artifacts placeholder"/log "download_artifacts placeholder"\n    NEW_UPSTREAM_VENDOR_FIX_MARKER=YES/' \
  "$FIXTURE" >"${CACHEG}/bringup_py3_dp_after_os_upgrade.sh"
write_sidecar_for "${CACHEG}/bringup_py3_dp_after_os_upgrade.sh"
# Copy remaining dummy payloads so cache looks present; assess only hashes bringup.
engine_assess_phase2_final 6.6.0
[[ "$PHASE2_EXISTING_BUNDLE" == "INVALID" ]] \
  && [[ "${PHASE2_EXISTING_INVALID_REASON}" == "upstream_bringup_changed" ]] \
  && pass "G new upstream SHA invalidates reuse" \
  || fail "G want=upstream_bringup_changed got=${PHASE2_EXISTING_INVALID_REASON:-$PHASE2_EXISTING_BUNDLE}"

# H. Existing valid old bundle + new upstream in cache must not keep old patched.
# (G already marked INVALID for upstream change; confirm apply from new cache
# produces the new marker rather than the previous published bringup.)
WORKH="${WORKDIR}/workH"; mkdir -p "$WORKH"
OUTH="${WORKDIR}/h.log"
rch="$(run_in_subshell "$OUTH" engine_apply_local_bringup_patch "$WORKH" \
  "${CACHEG}/bringup_py3_dp_after_os_upgrade.sh")"
[[ "$rch" -eq 0 ]] || { fail "H apply rc=${rch}"; cat "$OUTH"; }
grep -q 'NEW_UPSTREAM_VENDOR_FIX_MARKER=YES' "${WORKH}/bringup_py3_dp_after_os_upgrade.sh" \
  && pass "H rebuilt from new upstream, not stale bundle" \
  || fail "H rebuilt from new upstream, not stale bundle"
old_published="$(tar -xOf "${DESTF}/dp_bundle_6.6.0-current.tar" bringup_py3_dp_after_os_upgrade.sh)"
printf '%s\n' "$old_published" | grep -q 'NEW_UPSTREAM_VENDOR_FIX_MARKER=YES' \
  && fail "H old bundle already had new marker" \
  || pass "H old published bundle lacked new upstream marker"

# P. Exact production f1a73 upstream patches through the engine path.
F1SHA="$(sha1sum "$PRODUCTION_F1A73" | awk '{print $1}')"
[[ "$F1SHA" == "$EXPECTED_F1A73_SHA1" ]] \
  && pass "P production fixture SHA1=${F1SHA}" \
  || fail "P production fixture SHA1 want=${EXPECTED_F1A73_SHA1} got=${F1SHA}"
CACHEP="${WORKDIR}/cacheP"; mkdir -p "$CACHEP"
cp -f "$PRODUCTION_F1A73" "${CACHEP}/bringup_py3_dp_after_os_upgrade.sh"
write_sidecar_for "${CACHEP}/bringup_py3_dp_after_os_upgrade.sh"
WORKP="${WORKDIR}/workP"; mkdir -p "$WORKP"
OUTP="${WORKDIR}/p.log"
rcp="$(run_in_subshell "$OUTP" engine_apply_local_bringup_patch "$WORKP" \
  "${CACHEP}/bringup_py3_dp_after_os_upgrade.sh")"
[[ "$rcp" -eq 0 ]] && pass "P apply rc=0" || { fail "P apply rc=${rcp}"; cat "$OUTP"; }
grep -q 'BRINGUP_PATCH_COMPAT=PASS' "$OUTP" && pass "P BRINGUP_PATCH_COMPAT=PASS" || fail "P compat"
grep -q 'PATCHED_BRINGUP_GENERATION=PASS' "$OUTP" && pass "P PATCHED_BRINGUP_GENERATION=PASS" || fail "P generation"
grep -q 'STANDBY_IPS=""' "${WORKP}/bringup_py3_dp_after_os_upgrade.sh" \
  && grep -q 'AELDEV-73583' "${WORKP}/bringup_py3_dp_after_os_upgrade.sh" \
  && grep -q 'token_extra="&standby=1"' "${WORKP}/bringup_py3_dp_after_os_upgrade.sh" \
  && pass "P f1a73 vendor changes preserved" \
  || fail "P f1a73 vendor changes preserved"
grep -q -- '--worker-password-file' "${WORKP}/bringup_py3_dp_after_os_upgrade.sh" \
  && pass "P worker-password-file present" || fail "P worker-password-file present"
grep -q 'ACPS_DIRECT_DOWNLOAD=FAIL' "${WORKP}/bringup_py3_dp_after_os_upgrade.sh" \
  && pass "P ACPS direct download fail-closed" \
  || fail "P ACPS direct download fail-closed"
[[ "$(sha1sum "${WORKP}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')" \
    != "$EXPECTED_F1A73_SHA1" ]] \
  && pass "P generated differs from raw f1a73 upstream" \
  || fail "P generated equals raw f1a73 upstream"
bash -n "${WORKP}/bringup_py3_dp_after_os_upgrade.sh" \
  && pass "P patched bash -n" || fail "P patched bash -n"
cmp -s "${CACHEP}/bringup_py3_dp_after_os_upgrade.sh" "$PRODUCTION_F1A73" \
  && pass "P cache upstream not mutated" \
  || fail "P cache upstream mutated"

# Q. Exact production 3af369 upstream patches through verify then apply.
QSHA="$(sha1sum "$PRODUCTION_3AF369" | awk '{print $1}')"
[[ "$QSHA" == "$EXPECTED_3AF369_SHA1" ]] \
  && pass "Q production fixture SHA1=${QSHA}" \
  || fail "Q production fixture SHA1 want=${EXPECTED_3AF369_SHA1} got=${QSHA}"
CACHEQ="${WORKDIR}/cacheQ"; mkdir -p "$CACHEQ"
cp -f "$PRODUCTION_3AF369" "${CACHEQ}/bringup_py3_dp_after_os_upgrade.sh"
write_sidecar_for "${CACHEQ}/bringup_py3_dp_after_os_upgrade.sh"
OUTQ="${WORKDIR}/q.log"
rcq="$(run_in_subshell "$OUTQ" engine_verify_acps_upstream_bringup "$CACHEQ")"
[[ "$rcq" -eq 0 ]] && pass "Q verify rc=0" || { fail "Q verify rc=${rcq}"; cat "$OUTQ"; }
grep -q 'BRINGUP_PATCH_COMPAT=PASS' "$OUTQ" && pass "Q verify BRINGUP_PATCH_COMPAT=PASS" || fail "Q verify compat"
WORKQ="${WORKDIR}/workQ"; mkdir -p "$WORKQ"
OUTQ2="${WORKDIR}/q2.log"
rcq2="$(run_in_subshell "$OUTQ2" engine_apply_local_bringup_patch "$WORKQ" \
  "${CACHEQ}/bringup_py3_dp_after_os_upgrade.sh")"
[[ "$rcq2" -eq 0 ]] && pass "Q apply rc=0" || { fail "Q apply rc=${rcq2}"; cat "$OUTQ2"; }
grep -q 'BRINGUP_PATCH_COMPAT=PASS' "$OUTQ2" && pass "Q apply BRINGUP_PATCH_COMPAT=PASS" || fail "Q apply compat"
grep -q 'PATCHED_BRINGUP_GENERATION=PASS' "$OUTQ2" && pass "Q PATCHED_BRINGUP_GENERATION=PASS" || fail "Q generation"
grep -q 'wait_for_da_restful_8003' "${WORKQ}/bringup_py3_dp_after_os_upgrade.sh" \
  && grep -q 'rebuild_resolv_conf' "${WORKQ}/bringup_py3_dp_after_os_upgrade.sh" \
  && grep -q -- '--worker-password-file' "${WORKQ}/bringup_py3_dp_after_os_upgrade.sh" \
  && pass "Q 3af369 vendor + project markers" \
  || fail "Q 3af369 vendor + project markers"
bash -n "${WORKQ}/bringup_py3_dp_after_os_upgrade.sh" \
  && pass "Q patched bash -n" || fail "Q patched bash -n"
cmp -s "${CACHEQ}/bringup_py3_dp_after_os_upgrade.sh" "$PRODUCTION_3AF369" \
  && pass "Q cache upstream not mutated" \
  || fail "Q cache upstream mutated"

# English-only on production patcher + engine hunks.
if ROOT="$ROOT" python3 - <<'PY'
import glob, os, sys
root = os.environ["ROOT"]
paths = [
    os.path.join(root, "scripts/lib/patch_dp_phase2_bringup.py"),
    os.path.join(root, "scripts/lib/mirror_install_engine.sh"),
    os.path.join(root, "vendor/dp-phase2/README.md"),
]
paths += glob.glob(os.path.join(root, "scripts/lib/phase2_bringup_patch/*"))
found = []
for p in paths:
    if not os.path.isfile(p):
        continue
    data = open(p, "rb").read().decode("utf-8", "replace")
    if any("\uac00" <= ch <= "\ud7a3" for ch in data):
        found.append(p)
sys.exit(1 if found else 0)
PY
then
  pass "L English-only production patch files"
else
  fail "L Hangul in modified production files"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "test_phase2_bringup_fresh_upstream: FAIL"
  exit 1
fi
echo "test_phase2_bringup_fresh_upstream: PASS"
exit 0
