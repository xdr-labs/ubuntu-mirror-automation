#!/usr/bin/env bash
# ACPS bringup integrity: sidecar SHA is blocking; reference SHA drift is not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
DP2="${ROOT}/scripts/lib/dp-phase2-common.sh"
ACPS="${ROOT}/scripts/lib/acps_acquire.sh"
R2="${ROOT}/scripts/lib/r2_acquire.sh"
PATCHED_BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
UPSTREAM_BASELINE="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1"
UPSTREAM_FIXTURE="${ROOT}/tests/fixtures/dp-phase2/upstream_bringup_unpatched.sh"

PREVIOUS_KNOWN_SHA1="70de02dd62409110dadb7553991d1ffb0a79f396"
CURRENT_UPSTREAM_SHA1="f1a73c1d4502e2efcf55197865d2ade345d9c82f"

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

write_incompatible_upstream() {
  local dest="$1"
  cat >"$dest" <<'EOF'
#!/bin/bash
parse_args() { :; }
orchestrate_workers() { :; }
echo "valid syntax but missing load_local_images / images import"
EOF
}

reset_vendor() {
  mkdir -p "${MM_PROJECT_ROOT}/vendor/dp-phase2" \
    "${MM_PROJECT_ROOT}/scripts/lib"
  cp -f "$PATCHED_BRINGUP" "${MM_PROJECT_ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
  printf '%s  bringup_py3_dp_after_os_upgrade.sh\n' "$PREVIOUS_KNOWN_SHA1" \
    >"${MM_PROJECT_ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1"
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

restore_sha1_of() {
  engine_bringup_sha1_of() {
    sha1sum "$1" | awk '{print $1}'
  }
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

echo "======== test_bringup_acps_sha_policy ========"

prod_ref="$(awk '{print $1; exit}' "$UPSTREAM_BASELINE")"
[[ "$prod_ref" == "$PREVIOUS_KNOWN_SHA1" ]] \
  && pass "production reference SHA remains ${PREVIOUS_KNOWN_SHA1}" \
  || fail "production reference SHA changed to ${prod_ref}"

# --- TEST 1: same reference SHA, sidecar matches ---
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
grep -q 'UPSTREAM_BRINGUP_CHANGED=YES' "$OUT1" && fail "TEST 1 unexpected change warning" || pass "TEST 1 no change warning"
grep -q 'INSTALL_RESULT=FAIL' "$OUT1" && fail "TEST 1 INSTALL_RESULT=FAIL" || pass "TEST 1 no INSTALL_RESULT=FAIL"
grep -q 'UPSTREAM_BRINGUP_DRIFT=YES' "$OUT1" && fail "TEST 1 blocking drift" || pass "TEST 1 no blocking drift"
WORK1="${WORKDIR}/work1"; mkdir -p "$WORK1"
OUT1b="${WORKDIR}/test1.patch.log"
rc1b="$(run_in_subshell "$OUT1b" engine_apply_local_bringup_patch "$WORK1" \
  "${CACHE1}/bringup_py3_dp_after_os_upgrade.sh")"
[[ "$rc1b" -eq 0 ]] && pass "TEST 1 patch rc=0" || fail "TEST 1 patch rc=${rc1b}"
grep -q 'PATCHED_BRINGUP_APPLIED=YES' "$OUT1b" && pass "TEST 1 patch applied" || fail "TEST 1 patch applied"

# --- TEST 2: legitimate upstream update 70de... -> f1a73... ---
reset_vendor
restore_sha1_of
CACHE2="${WORKDIR}/cache2"; mkdir -p "$CACHE2"
write_compatible_upstream "${CACHE2}/bringup_py3_dp_after_os_upgrade.sh"
write_sidecar_for "${CACHE2}/bringup_py3_dp_after_os_upgrade.sh" \
  "${CACHE2}/bringup_py3_dp_after_os_upgrade.sh.sha1" "$CURRENT_UPSTREAM_SHA1"
engine_bringup_sha1_of() {
  printf '%s\n' "$CURRENT_UPSTREAM_SHA1"
}
OUT2="${WORKDIR}/test2.log"
rc2="$(run_in_subshell "$OUT2" engine_verify_acps_upstream_bringup "$CACHE2")"
restore_sha1_of
[[ "$rc2" -eq 0 ]] && pass "TEST 2 verify rc=0 (70de -> f1a73)" || { fail "TEST 2 verify rc=${rc2}"; cat "$OUT2"; }
grep -q 'ACPS_BRINGUP_CHECKSUM=PASS' "$OUT2" && pass "TEST 2 sidecar PASS" || fail "TEST 2 sidecar PASS"
grep -q 'UPSTREAM_BRINGUP_CHANGED=YES' "$OUT2" && pass "TEST 2 changed warning" || fail "TEST 2 changed warning"
grep -q "PREVIOUS_KNOWN_SHA1=${PREVIOUS_KNOWN_SHA1}" "$OUT2" \
  && pass "TEST 2 PREVIOUS_KNOWN_SHA1" || fail "TEST 2 PREVIOUS_KNOWN_SHA1"
grep -q "CURRENT_UPSTREAM_SHA1=${CURRENT_UPSTREAM_SHA1}" "$OUT2" \
  && pass "TEST 2 CURRENT_UPSTREAM_SHA1" || fail "TEST 2 CURRENT_UPSTREAM_SHA1"
grep -q 'UPSTREAM_BRINGUP_DRIFT=NON_BLOCKING' "$OUT2" \
  && pass "TEST 2 drift non-blocking" || fail "TEST 2 drift non-blocking"
grep -q 'UPSTREAM_BRINGUP_DRIFT=YES' "$OUT2" && fail "TEST 2 blocking drift YES" || pass "TEST 2 no DRIFT=YES"
grep -q 'INSTALL_RESULT=FAIL' "$OUT2" && fail "TEST 2 INSTALL_RESULT=FAIL" || pass "TEST 2 no INSTALL_RESULT=FAIL"
grep -q 'HTTP_DISTRIBUTION_READY=NO' "$OUT2" && fail "TEST 2 HTTP_DISTRIBUTION_READY=NO" || pass "TEST 2 no HTTP block"
WORK2="${WORKDIR}/work2"; mkdir -p "$WORK2"
OUT2b="${WORKDIR}/test2.patch.log"
rc2b="$(run_in_subshell "$OUT2b" engine_apply_local_bringup_patch "$WORK2" \
  "${CACHE2}/bringup_py3_dp_after_os_upgrade.sh")"
[[ "$rc2b" -eq 0 ]] && pass "TEST 2 patch continues" || fail "TEST 2 patch rc=${rc2b}"
grep -q 'PATCHED_BRINGUP_APPLIED=YES' "$OUT2b" && pass "TEST 2 patch applied" || fail "TEST 2 patch applied"
[[ "$(mm_status_get UPSTREAM_BRINGUP_DRIFT)" == "NON_BLOCKING" ]] \
  && pass "TEST 2 status DRIFT=NON_BLOCKING" || fail "TEST 2 status DRIFT=$(mm_status_get UPSTREAM_BRINGUP_DRIFT)"

# --- TEST 3: sidecar hash A, file hash B ---
reset_vendor
restore_sha1_of
CACHE3="${WORKDIR}/cache3"; mkdir -p "$CACHE3"
write_compatible_upstream "${CACHE3}/bringup_py3_dp_after_os_upgrade.sh"
printf '0000000000000000000000000000000000000000  bringup_py3_dp_after_os_upgrade.sh\n' \
  >"${CACHE3}/bringup_py3_dp_after_os_upgrade.sh.sha1"
WORK3="${WORKDIR}/work3"; mkdir -p "$WORK3"
OUT3="${WORKDIR}/test3.log"
rc3="$(run_in_subshell "$OUT3" run_verify_then_patch "$CACHE3" "$WORK3")"
[[ "$rc3" -ne 0 ]] && pass "TEST 3 verify fails" || fail "TEST 3 should fail"
grep -q 'ACPS_BRINGUP_CHECKSUM=FAIL' "$OUT3" && pass "TEST 3 ACPS_BRINGUP_CHECKSUM=FAIL" || fail "TEST 3 checksum log"
grep -q 'ACPS_BRINGUP_EXPECTED_SHA1=0000000000000000000000000000000000000000' "$OUT3" \
  && pass "TEST 3 expected sidecar hash" || fail "TEST 3 expected sidecar hash"
grep -q 'INSTALL_RESULT=FAIL' "$OUT3" && pass "TEST 3 INSTALL_RESULT=FAIL" || fail "TEST 3 INSTALL_RESULT=FAIL"
grep -q 'PATCHED_BRINGUP_APPLIED=YES' "$OUT3" && fail "TEST 3 patched corrupted script" || pass "TEST 3 did not patch"
[[ ! -f "${WORK3}/bringup_py3_dp_after_os_upgrade.sh" ]] \
  && pass "TEST 3 work bringup absent" || fail "TEST 3 work bringup was written"

# --- TEST 4: valid checksum, SHA drift, missing patch anchor ---
reset_vendor
restore_sha1_of
CACHE4="${WORKDIR}/cache4"; mkdir -p "$CACHE4"
write_incompatible_upstream "${CACHE4}/bringup_py3_dp_after_os_upgrade.sh"
write_sidecar_for "${CACHE4}/bringup_py3_dp_after_os_upgrade.sh"
WORK4="${WORKDIR}/work4"; mkdir -p "$WORK4"
OUT4="${WORKDIR}/test4.log"
rc4="$(run_in_subshell "$OUT4" run_verify_then_patch "$CACHE4" "$WORK4")"
[[ "$rc4" -ne 0 ]] && pass "TEST 4 incompat fails" || fail "TEST 4 should fail"
grep -q 'ACPS_BRINGUP_CHECKSUM=PASS' "$OUT4" && pass "TEST 4 sidecar PASS" || fail "TEST 4 sidecar PASS"
grep -q 'UPSTREAM_BRINGUP_DRIFT=NON_BLOCKING' "$OUT4" && pass "TEST 4 drift warning" || fail "TEST 4 drift warning"
grep -qE 'BRINGUP_PATCH_COMPAT=FAIL|UPSTREAM_LAYOUT_ANCHORS=FAIL' "$OUT4" \
  && pass "TEST 4 patch compat FAIL" || fail "TEST 4 patch compat FAIL"
grep -q 'UPSTREAM_BRINGUP_DRIFT=YES' "$OUT4" && fail "TEST 4 died on SHA drift" || pass "TEST 4 not SHA-drift fatal"
[[ ! -f "${WORK4}/bringup_py3_dp_after_os_upgrade.sh" ]] \
  && pass "TEST 4 did not apply patch" || fail "TEST 4 applied patch after incompat"

# --- TEST 5: generated patched bringup must pass bash -n; syntax gate remains ---
reset_vendor
restore_sha1_of
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
BROKEN5="${WORKDIR}/broken5.sh"
printf '#!/bin/bash\nif then\n' >"$BROKEN5"
OUT5b="${WORKDIR}/test5b.log"
rc5b="$(run_in_subshell "$OUT5b" engine_bringup_require_bash_n "$BROKEN5" PATCHED_BRINGUP_SYNTAX)"
[[ "$rc5b" -ne 0 ]] && pass "TEST 5 syntax gate still fails closed" || fail "TEST 5 syntax gate should fail"
grep -q 'PATCHED_BRINGUP_SYNTAX=FAIL' "$OUT5b" && pass "TEST 5 PATCHED_BRINGUP_SYNTAX=FAIL" || fail "TEST 5 syntax FAIL log"

# Source audit: production must not copy the frozen vendor full copy over upstream.
if grep -nE 'cp -f[[:space:]]+"\$patched"[[:space:]]+"\$dest"' "$ENGINE"; then
  fail "engine still copies frozen vendor over dest"
else
  pass "engine does not copy frozen vendor over dest"
fi

# Source audit: reference mismatch must not mm_die as UPSTREAM_BRINGUP_DRIFT=YES
if grep -nE 'mm_die[[:space:]]+"UPSTREAM_BRINGUP_DRIFT=YES"' "$ENGINE"; then
  fail "engine still dies on UPSTREAM_BRINGUP_DRIFT=YES"
else
  pass "engine has no blocking mm_die on reference drift"
fi
if grep -nE 'EXPECTED_UPSTREAM_SHA1=' "$ENGINE"; then
  fail "EXPECTED_UPSTREAM_SHA1 still used as a gate label"
else
  pass "EXPECTED_UPSTREAM_SHA1 gate label removed"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "test_bringup_acps_sha_policy: FAIL"
  exit 1
fi
echo "test_bringup_acps_sha_policy: PASS"
exit 0
