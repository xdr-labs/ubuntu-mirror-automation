#!/usr/bin/env bash
# ACPS bringup integrity: sidecar SHA + repository SHA256 provenance are blocking.
# Reference SHA1 mismatch alone is observability (after provenance PASS).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
DP2="${ROOT}/scripts/lib/dp-phase2-common.sh"
ACPS="${ROOT}/scripts/lib/acps_acquire.sh"
R2="${ROOT}/scripts/lib/r2_acquire.sh"
PATCHED_BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
UPSTREAM_BASELINE="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1"
APPROVED_LIST="${ROOT}/vendor/dp-phase2/approved-upstream-bringup.sha256"
UPSTREAM_FIXTURE="${ROOT}/tests/fixtures/dp-phase2/upstream_bringup_unpatched.sh"
PRODUCTION_F1A73="${ROOT}/tests/fixtures/dp-phase2/production-f1a73/bringup_py3_dp_after_os_upgrade.sh"
PRODUCTION_3AF369="${ROOT}/tests/fixtures/dp-phase2/production-3af369/bringup_py3_dp_after_os_upgrade.sh"
# Pre-scrub reviewed upstream bytes live only in git history (not the worktree).
HIST_BASE="9bfac016d5f66b2abcb3e097284421fc3e62118b"
HIST_F1A73_PATH="tests/fixtures/dp-phase2/production-f1a73/bringup_py3_dp_after_os_upgrade.sh"
HIST_3AF369_PATH="tests/fixtures/dp-phase2/production-3af369/bringup_py3_dp_after_os_upgrade.sh"
# Expected production allowlist digests (SHA256 of exact historical ACPS bytes).
REAL_F1A73_SHA256="1d956d8b1221e2bfd621319951fc7665eed4cdbc046860b36e3f6e2eba885c9c"
REAL_3AF369_SHA256="6a69ff8671a1bd396efb4d103314cd5d347003fbda957e49a20c99fb5957e622"
REAL_F1A73_SHA1="f1a73c1d4502e2efcf55197865d2ade345d9c82f"
REAL_3AF369_SHA1="3af369660c3e0dfb0b7421ab455dee1ced365b1d"

PREVIOUS_KNOWN_SHA1="70de02dd62409110dadb7553991d1ffb0a79f396"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

export MM_SKIP_ROOT_CHECK=1
export MM_PROJECT_ROOT="${WORKDIR}/proj"
export MM_MIRROR_ROOT="${WORKDIR}/mirror"
export MM_CACHE_ROOT="${WORKDIR}/mirror/.install-cache"
export MM_STATE_ROOT="${WORKDIR}/state"
export MM_STATE_DIR="${WORKDIR}/state/run"
export MM_LOG_DIR="${WORKDIR}/logs"
export MM_CONFIG_DIR="${WORKDIR}/config"
export MM_STATUS_FILE="${WORKDIR}/config/status"
export MM_LOCK_FILE="${WORKDIR}/install.lock"
export MM_DRY_RUN=0
mkdir -p "$MM_STATE_DIR" "$MM_LOG_DIR" "$MM_CONFIG_DIR" \
  "${MM_PROJECT_ROOT}/vendor/dp-phase2" "${WORKDIR}/cache" "${WORKDIR}/work"

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

write_compatible_upstream() {
  local dest="$1"
  cp -f "$UPSTREAM_FIXTURE" "$dest"
}

# Test-local allowlist only: synthetic + sanitized fixture digests.
# Never copy these into the production approval file.
write_test_local_allowlist() {
  local dest="${1:-${MM_PROJECT_ROOT}/vendor/dp-phase2/approved-upstream-bringup.sha256}"
  local synth sanitized_f1 sanitized_3
  synth="$(sha256sum "$UPSTREAM_FIXTURE" | awk '{print $1}')"
  sanitized_f1="$(sha256sum "$PRODUCTION_F1A73" | awk '{print $1}')"
  sanitized_3="$(sha256sum "$PRODUCTION_3AF369" | awk '{print $1}')"
  cat >"$dest" <<EOF
# TEST-LOCAL allowlist — not production provenance
${synth}  upstream_bringup_unpatched
${sanitized_f1}  sanitized-f1a73-compat
${sanitized_3}  sanitized-3af369-compat
EOF
}

write_production_allowlist_copy() {
  local dest="${1:-${MM_PROJECT_ROOT}/vendor/dp-phase2/approved-upstream-bringup.sha256}"
  cp -f "$APPROVED_LIST" "$dest"
}

reset_vendor() {
  mkdir -p "${MM_PROJECT_ROOT}/vendor/dp-phase2" \
    "${MM_PROJECT_ROOT}/scripts/lib"
  cp -f "$PATCHED_BRINGUP" "${MM_PROJECT_ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
  printf '%s  bringup_py3_dp_after_os_upgrade.sh\n' "$PREVIOUS_KNOWN_SHA1" \
    >"${MM_PROJECT_ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1"
  write_test_local_allowlist \
    "${MM_PROJECT_ROOT}/vendor/dp-phase2/approved-upstream-bringup.sha256"
  cp -f "${ROOT}/scripts/lib/patch_dp_phase2_bringup.py" \
    "${MM_PROJECT_ROOT}/scripts/lib/patch_dp_phase2_bringup.py"
  rm -rf "${MM_PROJECT_ROOT}/scripts/lib/phase2_bringup_patch"
  cp -a "${ROOT}/scripts/lib/phase2_bringup_patch" \
    "${MM_PROJECT_ROOT}/scripts/lib/phase2_bringup_patch"
}

write_sidecar_for() {
  local file="$1"
  local sidecar="${2:-${file}.sha1}"
  local digest="${3:-}"
  if [[ -n "$digest" ]]; then
    printf '%s  bringup_py3_dp_after_os_upgrade.sh\n' "$digest" >"$sidecar"
  else
    sha1sum "$file" | awk '{print $1"  bringup_py3_dp_after_os_upgrade.sh"}' >"$sidecar"
  fi
}

run_verify_then_patch() {
  engine_verify_acps_upstream_bringup "$1"
  engine_apply_local_bringup_patch "$2" "${1}/bringup_py3_dp_after_os_upgrade.sh"
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

# Extract historical bytes into WORKDIR only (never restore into the repo tree).
extract_historical_upstream() {
  local git_path="$1"
  local dest="$2"
  git -C "$ROOT" show "${HIST_BASE}:${git_path}" >"$dest"
}

echo "======== test_bringup_acps_sha_policy ========"

prod_ref="$(awk '{print $1; exit}' "$UPSTREAM_BASELINE")"
[[ "$prod_ref" == "$PREVIOUS_KNOWN_SHA1" ]] \
  && pass "production reference SHA remains ${PREVIOUS_KNOWN_SHA1}" \
  || fail "production reference SHA changed to ${prod_ref}"
[[ -f "$APPROVED_LIST" ]] \
  && pass "approved SHA256 allowlist present" \
  || fail "approved SHA256 allowlist missing"

# --- Production allowlist must contain only real reviewed digests ---
synth_sha="$(sha256sum "$UPSTREAM_FIXTURE" | awk '{print $1}')"
san_f1_sha="$(sha256sum "$PRODUCTION_F1A73" | awk '{print $1}')"
san_3_sha="$(sha256sum "$PRODUCTION_3AF369" | awk '{print $1}')"
if grep -Eiq "^${synth_sha}([[:space:]]|$)" "$APPROVED_LIST"; then
  fail "production allowlist must not contain synthetic fixture digest"
else
  pass "SYNTHETIC_DIGEST_IN_PRODUCTION_ALLOWLIST=NO"
fi
if grep -Eiq "^${san_f1_sha}([[:space:]]|$)" "$APPROVED_LIST" \
  || grep -Eiq "^${san_3_sha}([[:space:]]|$)" "$APPROVED_LIST"; then
  fail "production allowlist must not contain sanitized fixture digests"
else
  pass "SANITIZED_FIXTURE_DIGEST_IN_PRODUCTION_ALLOWLIST=NO"
fi
real_count="$(awk '/^[0-9a-fA-F]{64}([[:space:]]|$)/ {c++} END{print c+0}' "$APPROVED_LIST")"
[[ "$real_count" -eq 2 ]] \
  && pass "REAL_REVIEWED_UPSTREAM_DIGEST_COUNT=${real_count}" \
  || fail "REAL_REVIEWED_UPSTREAM_DIGEST_COUNT want=2 got=${real_count}"
grep -Eiq "^${REAL_F1A73_SHA256}([[:space:]]|$)" "$APPROVED_LIST" \
  && pass "production allowlist has real f1a73 digest" \
  || fail "production allowlist missing real f1a73 digest"
grep -Eiq "^${REAL_3AF369_SHA256}([[:space:]]|$)" "$APPROVED_LIST" \
  && pass "production allowlist has real 3af369 digest" \
  || fail "production allowlist missing real 3af369 digest"

# Confirm historical bytes match expected digests (no content printed).
HIST_TMP="${WORKDIR}/hist"; mkdir -p "$HIST_TMP"
extract_historical_upstream "$HIST_F1A73_PATH" "${HIST_TMP}/f1a73.sh"
extract_historical_upstream "$HIST_3AF369_PATH" "${HIST_TMP}/3af369.sh"
h_f1_sha1="$(sha1sum "${HIST_TMP}/f1a73.sh" | awk '{print $1}')"
h_3_sha1="$(sha1sum "${HIST_TMP}/3af369.sh" | awk '{print $1}')"
h_f1_sha256="$(sha256sum "${HIST_TMP}/f1a73.sh" | awk '{print $1}')"
h_3_sha256="$(sha256sum "${HIST_TMP}/3af369.sh" | awk '{print $1}')"
[[ "$h_f1_sha1" == "$REAL_F1A73_SHA1" && "$h_f1_sha256" == "$REAL_F1A73_SHA256" ]] \
  && pass "historical f1a73 bytes match reviewed SHA1/SHA256" \
  || fail "historical f1a73 digest mismatch"
[[ "$h_3_sha1" == "$REAL_3AF369_SHA1" && "$h_3_sha256" == "$REAL_3AF369_SHA256" ]] \
  && pass "historical 3af369 bytes match reviewed SHA1/SHA256" \
  || fail "historical 3af369 digest mismatch"

# Real historical bytes PASS against production allowlist (temp project copy).
reset_vendor
write_production_allowlist_copy
CACHE_REAL="${WORKDIR}/cache-real"; mkdir -p "$CACHE_REAL"
cp -f "${HIST_TMP}/f1a73.sh" "${CACHE_REAL}/bringup_py3_dp_after_os_upgrade.sh"
write_sidecar_for "${CACHE_REAL}/bringup_py3_dp_after_os_upgrade.sh"
OUT_REAL="${WORKDIR}/real-f1a73.log"
rc_real="$(run_in_subshell "$OUT_REAL" engine_verify_acps_upstream_bringup "$CACHE_REAL")"
[[ "$rc_real" -eq 0 ]] && pass "real f1a73 provenance PASS" || { fail "real f1a73 provenance"; cat "$OUT_REAL"; }
grep -q 'UPSTREAM_BRINGUP_PROVENANCE=PASS' "$OUT_REAL" && pass "real f1a73 PROVENANCE=PASS" || fail "real f1a73 log"

CACHE_REAL3="${WORKDIR}/cache-real3"; mkdir -p "$CACHE_REAL3"
cp -f "${HIST_TMP}/3af369.sh" "${CACHE_REAL3}/bringup_py3_dp_after_os_upgrade.sh"
write_sidecar_for "${CACHE_REAL3}/bringup_py3_dp_after_os_upgrade.sh"
OUT_REAL3="${WORKDIR}/real-3af369.log"
rc_real3="$(run_in_subshell "$OUT_REAL3" engine_verify_acps_upstream_bringup "$CACHE_REAL3")"
[[ "$rc_real3" -eq 0 ]] && pass "real 3af369 provenance PASS" || { fail "real 3af369 provenance"; cat "$OUT_REAL3"; }

# Sanitized tree fixtures FAIL against production allowlist.
CACHE_SAN="${WORKDIR}/cache-san"; mkdir -p "$CACHE_SAN"
cp -f "$PRODUCTION_F1A73" "${CACHE_SAN}/bringup_py3_dp_after_os_upgrade.sh"
write_sidecar_for "${CACHE_SAN}/bringup_py3_dp_after_os_upgrade.sh"
OUT_SAN="${WORKDIR}/san-fail.log"
rc_san="$(run_in_subshell "$OUT_SAN" engine_verify_acps_upstream_bringup "$CACHE_SAN")"
[[ "$rc_san" -ne 0 ]] && pass "sanitized f1a73 fails production allowlist" || fail "sanitized should fail production"
grep -q 'UPSTREAM_BRINGUP_PROVENANCE=FAIL' "$OUT_SAN" && pass "sanitized PROVENANCE=FAIL" || fail "sanitized FAIL log"
grep -q 'UPSTREAM_BRINGUP_APPROVAL_REQUIRED=YES' "$OUT_SAN" && pass "sanitized APPROVAL_REQUIRED" || fail "sanitized APPROVAL_REQUIRED"

# --- TEST 1: approved known upstream A (synthetic fixture, TEST-LOCAL allowlist) ---
reset_vendor
CACHE1="${WORKDIR}/cache1"; mkdir -p "$CACHE1"
write_compatible_upstream "${CACHE1}/bringup_py3_dp_after_os_upgrade.sh"
same_sha="$(sha1sum "${CACHE1}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
write_sidecar_for "${CACHE1}/bringup_py3_dp_after_os_upgrade.sh"
printf '%s  bringup_py3_dp_after_os_upgrade.sh\n' "$same_sha" \
  >"${MM_PROJECT_ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1"
OUT1="${WORKDIR}/test1.log"
rc1="$(run_in_subshell "$OUT1" engine_verify_acps_upstream_bringup "$CACHE1")"
[[ "$rc1" -eq 0 ]] && pass "TEST 1 verify rc=0" || { fail "TEST 1 verify rc=${rc1}"; cat "$OUT1"; }
grep -q 'ACPS_BRINGUP_CHECKSUM=PASS' "$OUT1" && pass "TEST 1 sidecar PASS" || { fail "TEST 1 sidecar PASS"; cat "$OUT1"; }
grep -q 'UPSTREAM_BRINGUP_PROVENANCE=PASS' "$OUT1" && pass "TEST 1 provenance PASS" || fail "TEST 1 provenance PASS"
grep -q 'UPSTREAM_BRINGUP_CHANGED=YES' "$OUT1" && fail "TEST 1 unexpected change warning" || pass "TEST 1 no change warning"
grep -q 'INSTALL_RESULT=FAIL' "$OUT1" && fail "TEST 1 INSTALL_RESULT=FAIL" || pass "TEST 1 no INSTALL_RESULT=FAIL"
WORK1="${WORKDIR}/work1"; mkdir -p "$WORK1"
OUT1b="${WORKDIR}/test1.patch.log"
rc1b="$(run_in_subshell "$OUT1b" engine_apply_local_bringup_patch "$WORK1" \
  "${CACHE1}/bringup_py3_dp_after_os_upgrade.sh")"
[[ "$rc1b" -eq 0 ]] && pass "TEST 1 patch rc=0" || fail "TEST 1 patch rc=${rc1b}"
grep -q 'PATCHED_BRINGUP_APPLIED=YES' "$OUT1b" && pass "TEST 1 patch applied" || fail "TEST 1 patch applied"

# --- TEST 1b: sanitized f1a73 compat fixture (TEST-LOCAL allowlist) ---
reset_vendor
CACHE1B="${WORKDIR}/cache1b"; mkdir -p "$CACHE1B"
cp -f "$PRODUCTION_F1A73" "${CACHE1B}/bringup_py3_dp_after_os_upgrade.sh"
write_sidecar_for "${CACHE1B}/bringup_py3_dp_after_os_upgrade.sh"
OUT1B="${WORKDIR}/test1b.log"
rc1b_v="$(run_in_subshell "$OUT1B" engine_verify_acps_upstream_bringup "$CACHE1B")"
[[ "$rc1b_v" -eq 0 ]] && pass "TEST 1b sanitized-f1a73 verify rc=0" || { fail "TEST 1b verify rc=${rc1b_v}"; cat "$OUT1B"; }
grep -q 'UPSTREAM_BRINGUP_PROVENANCE=PASS' "$OUT1B" && pass "TEST 1b sanitized-f1a73 provenance PASS" || fail "TEST 1b provenance"

# --- TEST 1c: sanitized 3af369 compat fixture (TEST-LOCAL allowlist) ---
reset_vendor
CACHE1C="${WORKDIR}/cache1c"; mkdir -p "$CACHE1C"
cp -f "$PRODUCTION_3AF369" "${CACHE1C}/bringup_py3_dp_after_os_upgrade.sh"
write_sidecar_for "${CACHE1C}/bringup_py3_dp_after_os_upgrade.sh"
OUT1C="${WORKDIR}/test1c.log"
rc1c="$(run_in_subshell "$OUT1C" engine_verify_acps_upstream_bringup "$CACHE1C")"
[[ "$rc1c" -eq 0 ]] && pass "TEST 1c sanitized-3af369 verify rc=0" || { fail "TEST 1c verify rc=${rc1c}"; cat "$OUT1C"; }
grep -q 'UPSTREAM_BRINGUP_PROVENANCE=PASS' "$OUT1C" && pass "TEST 1c sanitized-3af369 provenance PASS" || fail "TEST 1c provenance"

# --- TEST 2: reference SHA1 mismatch remains non-blocking AFTER provenance PASS ---
reset_vendor
CACHE2="${WORKDIR}/cache2"; mkdir -p "$CACHE2"
write_compatible_upstream "${CACHE2}/bringup_py3_dp_after_os_upgrade.sh"
write_sidecar_for "${CACHE2}/bringup_py3_dp_after_os_upgrade.sh"
# Keep reference at PREVIOUS_KNOWN while upstream fixture SHA1 differs.
OUT2="${WORKDIR}/test2.log"
rc2="$(run_in_subshell "$OUT2" engine_verify_acps_upstream_bringup "$CACHE2")"
[[ "$rc2" -eq 0 ]] && pass "TEST 2 verify rc=0" || { fail "TEST 2 verify rc=${rc2}"; cat "$OUT2"; }
grep -q 'UPSTREAM_BRINGUP_PROVENANCE=PASS' "$OUT2" && pass "TEST 2 provenance PASS" || fail "TEST 2 provenance"
grep -q 'UPSTREAM_BRINGUP_CHANGED=YES' "$OUT2" && pass "TEST 2 changed warning" || fail "TEST 2 changed warning"
grep -q "PREVIOUS_KNOWN_SHA1=${PREVIOUS_KNOWN_SHA1}" "$OUT2" \
  && pass "TEST 2 PREVIOUS_KNOWN_SHA1" || fail "TEST 2 PREVIOUS_KNOWN_SHA1"
grep -q 'UPSTREAM_BRINGUP_REFERENCE_MISMATCH=YES\|UPSTREAM_BRINGUP_DRIFT=NON_BLOCKING' "$OUT2" \
  && pass "TEST 2 reference mismatch non-blocking" || fail "TEST 2 reference mismatch"
grep -q 'INSTALL_RESULT=FAIL' "$OUT2" && fail "TEST 2 INSTALL_RESULT=FAIL" || pass "TEST 2 no INSTALL_RESULT=FAIL"

# --- TEST 3: sidecar hash mismatch fails before provenance publish ---
reset_vendor
CACHE3="${WORKDIR}/cache3"; mkdir -p "$CACHE3"
write_compatible_upstream "${CACHE3}/bringup_py3_dp_after_os_upgrade.sh"
printf '0000000000000000000000000000000000000000  bringup_py3_dp_after_os_upgrade.sh\n' \
  >"${CACHE3}/bringup_py3_dp_after_os_upgrade.sh.sha1"
WORK3="${WORKDIR}/work3"; mkdir -p "$WORK3"
OUT3="${WORKDIR}/test3.log"
rc3="$(run_in_subshell "$OUT3" run_verify_then_patch "$CACHE3" "$WORK3")"
[[ "$rc3" -ne 0 ]] && pass "TEST 3 verify fails" || fail "TEST 3 should fail"
grep -q 'ACPS_BRINGUP_CHECKSUM=FAIL' "$OUT3" && pass "TEST 3 ACPS_BRINGUP_CHECKSUM=FAIL" || fail "TEST 3 checksum log"
grep -q 'INSTALL_RESULT=FAIL' "$OUT3" && pass "TEST 3 INSTALL_RESULT=FAIL" || fail "TEST 3 INSTALL_RESULT=FAIL"
grep -q 'PATCHED_BRINGUP_APPLIED=YES' "$OUT3" && fail "TEST 3 patched corrupted script" || pass "TEST 3 did not patch"
[[ ! -f "${WORK3}/bringup_py3_dp_after_os_upgrade.sh" ]] \
  && pass "TEST 3 work bringup absent" || fail "TEST 3 work bringup was written"

# --- TEST 4: one-byte modified upstream fails provenance even with matching new sidecar ---
reset_vendor
CACHE4="${WORKDIR}/cache4"; mkdir -p "$CACHE4"
write_compatible_upstream "${CACHE4}/bringup_py3_dp_after_os_upgrade.sh"
printf 'x' >>"${CACHE4}/bringup_py3_dp_after_os_upgrade.sh"
write_sidecar_for "${CACHE4}/bringup_py3_dp_after_os_upgrade.sh"
WORK4="${WORKDIR}/work4"; mkdir -p "$WORK4"
OUT4="${WORKDIR}/test4.log"
rc4="$(run_in_subshell "$OUT4" run_verify_then_patch "$CACHE4" "$WORK4")"
[[ "$rc4" -ne 0 ]] && pass "TEST 4 modified upstream fails" || fail "TEST 4 should fail"
grep -q 'UPSTREAM_BRINGUP_PROVENANCE=FAIL' "$OUT4" && pass "TEST 4 provenance FAIL" || fail "TEST 4 provenance FAIL"
grep -q 'UPSTREAM_BRINGUP_APPROVAL_REQUIRED=YES' "$OUT4" && pass "TEST 4 approval required" || fail "TEST 4 approval required"
grep -q 'UPSTREAM_BRINGUP_DRIFT=NON_BLOCKING' "$OUT4" && fail "TEST 4 unknown became NON_BLOCKING" || pass "TEST 4 not NON_BLOCKING"
[[ ! -f "${WORK4}/bringup_py3_dp_after_os_upgrade.sh" ]] \
  && pass "TEST 4 no patched output" || fail "TEST 4 published patched output after provenance fail"

# --- TEST 4b: malicious upstream preserving patch anchors still fails provenance ---
reset_vendor
CACHE4B="${WORKDIR}/cache4b"; mkdir -p "$CACHE4B"
python3 - "$UPSTREAM_FIXTURE" "${CACHE4B}/bringup_py3_dp_after_os_upgrade.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
src = src.replace(
    'log "download_artifacts placeholder"',
    'log "download_artifacts placeholder"\n    # MALICIOUS_BUT_ANCHOR_COMPATIBLE',
)
open(sys.argv[2], 'w').write(src)
PY
write_sidecar_for "${CACHE4B}/bringup_py3_dp_after_os_upgrade.sh"
WORK4B="${WORKDIR}/work4b"; mkdir -p "$WORK4B"
OUT4B="${WORKDIR}/test4b.log"
rc4b="$(run_in_subshell "$OUT4B" run_verify_then_patch "$CACHE4B" "$WORK4B")"
[[ "$rc4b" -ne 0 ]] && pass "TEST 4b malicious fails" || fail "TEST 4b should fail"
grep -q 'UPSTREAM_BRINGUP_PROVENANCE=FAIL' "$OUT4B" && pass "TEST 4b provenance FAIL" || fail "TEST 4b provenance"
[[ ! -f "${WORK4B}/bringup_py3_dp_after_os_upgrade.sh" ]] \
  && pass "TEST 4b no patched output" || fail "TEST 4b published after fail"

# --- TEST 5: generated patched bringup must pass bash -n on approved upstream ---
reset_vendor
CACHE5="${WORKDIR}/cache5"; mkdir -p "$CACHE5"
write_compatible_upstream "${CACHE5}/bringup_py3_dp_after_os_upgrade.sh"
write_sidecar_for "${CACHE5}/bringup_py3_dp_after_os_upgrade.sh"
sha5="$(sha1sum "${CACHE5}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
printf '%s  bringup_py3_dp_after_os_upgrade.sh\n' "$sha5" \
  >"${MM_PROJECT_ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1"
WORK5="${WORKDIR}/work5"; mkdir -p "$WORK5"
OUT5="${WORKDIR}/test5.log"
rc5="$(run_in_subshell "$OUT5" run_verify_then_patch "$CACHE5" "$WORK5")"
[[ "$rc5" -eq 0 ]] && pass "TEST 5 generated patch rc=0" || { fail "TEST 5 generated patch rc=${rc5}"; cat "$OUT5"; }
grep -q 'PATCHED_BRINGUP_SYNTAX=PASS' "$OUT5" && pass "TEST 5 PATCHED_BRINGUP_SYNTAX=PASS" || fail "TEST 5 syntax PASS"
grep -q 'PATCHED_BRINGUP_APPLIED=YES' "$OUT5" && pass "TEST 5 patch applied" || fail "TEST 5 patch applied"

# Source audit
if grep -nE 'cp -f[[:space:]]+"\$patched"[[:space:]]+"\$dest"' "$ENGINE"; then
  fail "engine still copies frozen vendor over dest"
else
  pass "engine does not copy frozen vendor over dest"
fi
if grep -nE 'mm_die[[:space:]]+"UPSTREAM_BRINGUP_DRIFT=YES"' "$ENGINE"; then
  fail "engine still dies on UPSTREAM_BRINGUP_DRIFT=YES"
else
  pass "engine has no blocking mm_die on reference drift"
fi
grep -q 'engine_verify_upstream_bringup_provenance' "$ENGINE" \
  && pass "engine has SHA256 provenance gate" || fail "engine missing provenance gate"
grep -q 'UPSTREAM_BRINGUP_APPROVAL_REQUIRED=YES' "$ENGINE" \
  && pass "engine emits APPROVAL_REQUIRED" || fail "engine missing APPROVAL_REQUIRED"
# Approval path is MM_PROJECT_ROOT-relative only (no env trust-root override).
if grep -nE 'engine_bringup_approved_sha256_list_path|approved-upstream-bringup\.sha256' "$ENGINE" \
  | grep -Eiq 'OVERRIDE|ALLOWLIST_PATH=|APPROVAL_LIST=.*\$\{'; then
  fail "engine appears to allow env override of approval trust root"
else
  pass "engine has no env override of approval trust root"
fi
# Confirm resolver still uses only MM_PROJECT_ROOT vendor path.
grep -q 'MM_PROJECT_ROOT}/vendor/dp-phase2/approved-upstream-bringup.sha256' "$ENGINE" \
  && pass "approval list path is MM_PROJECT_ROOT-scoped" \
  || fail "approval list path not MM_PROJECT_ROOT-scoped"

if [[ "$FAIL" -ne 0 ]]; then
  echo "test_bringup_acps_sha_policy: FAIL"
  exit 1
fi
echo "test_bringup_acps_sha_policy: PASS"
exit 0
