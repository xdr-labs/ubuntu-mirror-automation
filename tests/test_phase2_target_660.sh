#!/usr/bin/env bash
# tests/test_phase2_target_660.sh — DP 6.6.0 production target + 3af369 patcher
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/dp-phase2-common.sh
source "${ROOT}/scripts/lib/dp-phase2-common.sh"
# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "${ROOT}/scripts/lib/mirror_manager_common.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PATCHER="${ROOT}/scripts/lib/patch_dp_phase2_bringup.py"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
DP2="${ROOT}/scripts/lib/dp-phase2-common.sh"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
FX_3AF369="${ROOT}/tests/fixtures/dp-phase2/production-3af369/bringup_py3_dp_after_os_upgrade.sh"
FX_F1A73="${ROOT}/tests/fixtures/dp-phase2/production-f1a73/bringup_py3_dp_after_os_upgrade.sh"
EXPECTED_3AF369="3af369660c3e0dfb0b7421ab455dee1ced365b1d"
EXPECTED_F1A73="f1a73c1d4502e2efcf55197865d2ade345d9c82f"

echo "======== TEST A — Fixed production target ========"
grep -q 'PHASE2_TARGET_VERSION_FIXED="6.6.0"' "$COMMON" \
  && pass "A PHASE2_TARGET_VERSION_FIXED=6.6.0" \
  || fail "A PHASE2_TARGET_VERSION_FIXED"
grep -q 'DP_PHASE2_VERSION_DEFAULT="6.6.0"' "$DP2" \
  && pass "A DP_PHASE2_VERSION_DEFAULT=6.6.0" \
  || fail "A DP_PHASE2_VERSION_DEFAULT"
mm_force_phase2_target
[[ "$PHASE2_TARGET_VERSION" == "6.6.0" ]] && pass "A PHASE2_TARGET_VERSION=6.6.0" \
  || fail "A PHASE2_TARGET_VERSION=${PHASE2_TARGET_VERSION}"
[[ "$TARGET_DP_VERSION" == "6.6.0" ]] && pass "A TARGET_DP_VERSION=6.6.0" \
  || fail "A TARGET_DP_VERSION=${TARGET_DP_VERSION}"
[[ "$DP_PHASE2_VERSION" == "6.6.0" ]] && pass "A DP_PHASE2_VERSION=6.6.0" \
  || fail "A DP_PHASE2_VERSION=${DP_PHASE2_VERSION}"
TARGET_DP_VERSION=6.5.0
mm_force_phase2_target
[[ "$TARGET_DP_VERSION" == "6.6.0" ]] && pass "A stale 6.5.0 env cannot restore target" \
  || fail "A stale override survived: ${TARGET_DP_VERSION}"

echo "======== TEST B — Required 6.6.0 artifact set ========"
dp2_set_version 6.6.0
printf '%s\n' "${DP_PHASE2_REQUIRED_FILES[@]}" | grep -qx 'aella-uvp-2404_6.6.0ubuntu1_amd64.deb' \
  && pass "B UVP 6.6.0 required" || fail "B UVP 6.6.0 required"
printf '%s\n' "${DP_PHASE2_REQUIRED_FILES[@]}" | grep -qx 'images-6.6.0.tar' \
  && pass "B images-6.6.0.tar required" || fail "B images tar"
printf '%s\n' "${DP_PHASE2_REQUIRED_FILES[@]}" | grep -E '6\.5\.0' \
  && fail "B required set still names 6.5.0" || pass "B required set has no 6.5.0"

MIX="${WORKDIR}/mix65"
mkdir -p "$MIX"
for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
  printf 'x\n' >"${MIX}/${f}"
done
rm -f "${MIX}/images-6.6.0.tar"
printf 'old\n' >"${MIX}/images-6.5.0.tar"
set +e
mix_out="$(dp2_reject_mixed_generation "$MIX" 2>&1)"
mix_rc=$?
set -e
[[ "$mix_rc" -ne 0 ]] && echo "$mix_out" | grep -q 'MIXED_GENERATION=FAIL' \
  && pass "B 6.5 images cannot satisfy 6.6 preparation" \
  || fail "B mixed 6.5 images should fail closed: ${mix_out}"

echo "======== TEST C — Current upstream 3af369 ========"
got_sha="$(sha1sum "$FX_3AF369" | awk '{print $1}')"
[[ "$got_sha" == "$EXPECTED_3AF369" ]] && pass "C fixture SHA1=${got_sha}" \
  || fail "C fixture SHA1 want=${EXPECTED_3AF369} got=${got_sha}"
val_out="$(python3 "$PATCHER" --validate --upstream "$FX_3AF369")"
echo "$val_out" | grep -qx 'BRINGUP_PATCH_COMPAT=PASS' && pass "C validate BRINGUP_PATCH_COMPAT=PASS" \
  || fail "C validate compat: ${val_out}"
echo "$val_out" | grep -qx 'PATCHED_BRINGUP_GENERATION=PASS' && pass "C validate PATCHED_BRINGUP_GENERATION=PASS" \
  || fail "C validate generation"
DESTC="${WORKDIR}/patched-3af369.sh"
gen_out="$(python3 "$PATCHER" --upstream "$FX_3AF369" --output "$DESTC")"
echo "$gen_out" | grep -qx 'BRINGUP_PATCH_COMPAT=PASS' && pass "C generate BRINGUP_PATCH_COMPAT=PASS" \
  || fail "C generate compat"
echo "$gen_out" | grep -qx 'PATCHED_BRINGUP_GENERATION=PASS' && pass "C generate PATCHED_BRINGUP_GENERATION=PASS" \
  || fail "C generate generation"
bash -n "$DESTC" && pass "C patched bash -n" || fail "C patched bash -n"
cmp -s "$FX_3AF369" "$DESTC" && fail "C patched equals upstream" || pass "C patched differs from upstream"

echo "======== TEST D — Previous supported upstream f1a73 ========"
got_f1="$(sha1sum "$FX_F1A73" | awk '{print $1}')"
[[ "$got_f1" == "$EXPECTED_F1A73" ]] && pass "D f1a73 fixture SHA1" || fail "D f1a73 SHA1 got=${got_f1}"
DESTD="${WORKDIR}/patched-f1a73.sh"
gen_d="$(python3 "$PATCHER" --upstream "$FX_F1A73" --output "$DESTD")"
echo "$gen_d" | grep -qx 'BRINGUP_PATCH_COMPAT=PASS' && pass "D f1a73 BRINGUP_PATCH_COMPAT=PASS" \
  || fail "D f1a73 compat"
bash -n "$DESTD" && pass "D f1a73 bash -n" || fail "D f1a73 bash -n"

echo "======== TEST E — Unknown future upstream fail-closed ========"
MUTE="${WORKDIR}/mutated-3af369.sh"
python3 - "$FX_3AF369" "$MUTE" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding='utf-8').read()
# Break a required exact dpkg install_python3 anchor without matching any supported form.
old = 'dpkg -i --force-depends "${install_list[@]}"'
if old not in text:
    raise SystemExit('expected 3af369 dpkg force-depends anchor missing')
open(dst, 'w', encoding='utf-8').write(text.replace(old, 'dpkg -i --unknown-future-flag "${install_list[@]}"', 1))
PY
set +e
e_out="$(python3 "$PATCHER" --validate --upstream "$MUTE" 2>&1)"
e_rc=$?
set -e
[[ "$e_rc" -ne 0 ]] && echo "$e_out" | grep -q 'BRINGUP_PATCH_COMPAT=FAIL' \
  && pass "E mutated anchor FAIL closed" \
  || fail "E mutated upstream must not PASS: rc=${e_rc} ${e_out}"
echo "$e_out" | grep -q 'fuzzy' && fail "E fuzzy path mentioned" || pass "E no fuzzy acceptance"

echo "======== TEST F — Mixed generation rejected ========"
dp2_set_version 6.6.0
MIXF="${WORKDIR}/mix-uvp"
mkdir -p "$MIXF"
for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
  printf 'x\n' >"${MIXF}/${f}"
done
rm -f "${MIXF}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb"
printf 'old-uvp\n' >"${MIXF}/aella-uvp-2404_6.5.0ubuntu1_amd64.deb"
set +e
f_out="$(dp2_assert_exact_files_dir "$MIXF" 2>&1)"
f_rc=$?
set -e
[[ "$f_rc" -ne 0 ]] && echo "$f_out" | grep -Eq 'MIXED_GENERATION=FAIL|REQUIRED_FILE_MISSING=FAIL' \
  && pass "F target 6.6 + UVP 6.5 FAIL CLOSED" \
  || fail "F mixed UVP should fail: ${f_out}"

echo "======== TEST G — Production UI target ========"
grep -nE 'Phase 2 Target:[[:space:]]*6\.5\.0' "$INSTALLER" "$COMMON" \
  && fail "G production UI still shows Phase 2 Target 6.5.0" \
  || pass "G no production Phase 2 Target 6.5.0"
grep -q 'Phase 2 Target:      6.6.0 (fixed)' "$COMMON" \
  && pass "G footer Phase 2 Target 6.6.0 (fixed)" \
  || fail "G footer missing 6.6.0"
grep -q 'Starting DP Version: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0' "$COMMON" \
  && pass "G starting versions still list 6.5.0 as source" \
  || fail "G starting source versions missing"

echo "======== TEST H — generated Phase 2 command ========"
grep -nE -- '--version 6\.5\.0' "$INSTALLER" \
  && fail "H installer still hardcodes --version 6.5.0" \
  || pass "H installer has no --version 6.5.0"
grep -q -- '--version ${ver}' "$INSTALLER" \
  && pass "H bringup command uses \${ver}" \
  || fail "H bringup command missing version substitution"
# ver is PHASE2_TARGET_VERSION in Menu 7 builders
python3 - "$INSTALLER" <<'PY' && pass "H Menu 7 ver comes from PHASE2_TARGET_VERSION" || fail "H Menu 7 version source"
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(encoding='utf-8')
if 'local ver="${PHASE2_TARGET_VERSION}"' not in text and "local ver=\"${PHASE2_TARGET_VERSION}\"" not in text:
    # install-dp-upgrade-mirror.sh uses ver="${PHASE2_TARGET_VERSION}"
    if 'ver="${PHASE2_TARGET_VERSION}"' not in text:
        raise SystemExit(1)
PY
grep -q -- '--target-version 6.6.0' "${ROOT}/client/stage-dp-phase2-6.6.0.sh" \
  && pass "H 6.6.0 stage wrapper" || fail "H 6.6.0 stage wrapper"
grep -q -- '--version 6.6.0' "${ROOT}/scripts/download-dp-phase2-6.6.0.sh" \
  && pass "H 6.6.0 download wrapper" || fail "H 6.6.0 download wrapper"

echo "======== TEST I — same-version semantics ========"
HELPER="${ROOT}/client/stage-dp-phase2.sh"
i_out="$(
  trap - EXIT
  export DP_PHASE2_STAGE_LIB_ONLY=1
  # shellcheck disable=SC1090
  source "$HELPER"
  run_i() {
    local src="$1" tgt="$2"
    SOURCE_DP_VERSION="$src"
    SOURCE_DP_VERSION_RAW="$src"
    SOURCE_DP_VERSION_ORIGIN="test"
    SOURCE_DP_VERSION_CHECK=PASS
    TARGET_DP_VERSION="$tgt"
    PHASE2_ARTIFACT_VERSION="$tgt"
    SAME_VERSION_RECOVERY=0
    read_os_upgrade_state() { printf ''; }
    phase1_product_validation_is_not_run() { return 1; }
    bringup_already_executed() { return 1; }
    set +e
    out="$(evaluate_version_compatibility 2>&1)"
    set -e
    printf '%s\n' "$out"
  }
  printf 'UPGRADE65='
  run_i 6.5.0 6.6.0 || true
  printf '\nALREADY66='
  run_i 6.6.0 6.6.0 || true
  printf '\n'
)"
echo "$i_out" | grep -q 'PASS_UPGRADE' && pass "I 6.5.0 on target 6.6.0 is upgrade" \
  || fail "I 6.5.0 must not be same-version target"
echo "$i_out" | grep -q 'ALREADY_AT_TARGET' && pass "I 6.6.0 is production already-target" \
  || fail "I 6.6.0 already-target missing"

echo "======== TEST J — preflight validate matches generate ========"
j_val="$(python3 "$PATCHER" --validate --upstream "$FX_3AF369")"
DESTJ="${WORKDIR}/patched-j.sh"
j_gen="$(python3 "$PATCHER" --upstream "$FX_3AF369" --output "$DESTJ")"
echo "$j_val" | grep -qx 'BRINGUP_PATCH_COMPAT=PASS' || fail "J validate not PASS"
echo "$j_gen" | grep -qx 'BRINGUP_PATCH_COMPAT=PASS' || fail "J generate not PASS"
val_sha="$(echo "$j_val" | awk -F= '/^BRINGUP_PATCHED_SHA1=/{print $2; exit}')"
gen_sha="$(echo "$j_gen" | awk -F= '/^BRINGUP_PATCHED_SHA1=/{print $2; exit}')"
file_sha="$(sha1sum "$DESTJ" | awk '{print $1}')"
[[ -n "$val_sha" && "$val_sha" == "$gen_sha" && "$gen_sha" == "$file_sha" ]] \
  && pass "J validate SHA matches generate SHA (${file_sha})" \
  || fail "J SHA mismatch val=${val_sha} gen=${gen_sha} file=${file_sha}"

echo "======== TEST K — source/generated Phase 2 version drift ========"
# Committed production generated clients must track the jammy→noble template.
# Do not scan vendor bringup, historical fixtures, or retired 6.5.0 shims.
PHASE2_BRINGUP_CMD_RE='bringup_py3_dp_after_os_upgrade\.sh --version [0-9]+\.[0-9]+\.[0-9]+'
TEMPLATE="${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh.in"
GEN_CLIENT="${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh"
GEN_ART_TOP="${ROOT}/artifacts/client/dp-offline-upgrade-jammy-to-noble.sh"
GEN_ART_HOP="${ROOT}/artifacts/client/jammy-to-noble/dp-offline-upgrade-jammy-to-noble.sh"
tmpl_cmds="$(grep -oE "$PHASE2_BRINGUP_CMD_RE" "$TEMPLATE" | sort -u)"
[[ "$tmpl_cmds" == "bringup_py3_dp_after_os_upgrade.sh --version 6.6.0" ]] \
  && pass "K template Phase 2 command is --version 6.6.0" \
  || fail "K template Phase 2 command drifted: ${tmpl_cmds}"
for gen in "$GEN_CLIENT" "$GEN_ART_TOP" "$GEN_ART_HOP"; do
  [[ -f "$gen" ]] || { fail "K missing generated artifact ${gen}"; continue; }
  gen_cmds="$(grep -oE "$PHASE2_BRINGUP_CMD_RE" "$gen" | sort -u)"
  [[ "$gen_cmds" == "$tmpl_cmds" ]] \
    && pass "K $(realpath --relative-to="$ROOT" "$gen") matches template" \
    || fail "K drift $(realpath --relative-to="$ROOT" "$gen"): ${gen_cmds}"
done
stale="$(
  git -C "$ROOT" grep -n -- 'bringup_py3_dp_after_os_upgrade.sh --version 6.5.0' -- \
    artifacts/client \
    'client/dp-offline-upgrade-*.sh' \
    'client/dp-offline-upgrade-*.sh.in' \
    || true
)"
if [[ -n "$stale" ]]; then
  fail "K production generated/template still instructs --version 6.5.0"
  printf '%s\n' "$stale"
else
  pass "K no production generated --version 6.5.0 guidance"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "test_phase2_target_660: FAIL"
  exit 1
fi
echo "test_phase2_target_660: PASS"
exit 0
