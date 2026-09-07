#!/usr/bin/env bash
# Raw ACPS upstream must live in private cache storage, not the public Phase 2 final.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_FIXTURE="${ROOT}/tests/fixtures/dp-phase2/upstream_bringup_unpatched.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SHADOW="${TMP}/proj"
mkdir -p "${SHADOW}/vendor"
cp -a "${ROOT}/vendor/dp-phase2" "${SHADOW}/vendor/dp-phase2"
SYNTH_SHA256="$(sha256sum "$UPSTREAM_FIXTURE" | awk '{print $1}')"
cat >"${SHADOW}/vendor/dp-phase2/approved-upstream-bringup.sha256" <<EOF
${SYNTH_SHA256}  upstream_bringup_unpatched
EOF
ln -sfn "${ROOT}/scripts" "${SHADOW}/scripts"
ln -sfn "${ROOT}/client" "${SHADOW}/client"
ln -sfn "${ROOT}/lib" "${SHADOW}/lib"

export MM_PROJECT_ROOT="$SHADOW"
export MM_SKIP_ROOT_CHECK=1
export MM_MIRROR_ROOT="${TMP}/mirror"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_LOG_DIR="${TMP}/logs"
export MM_CONFIG_DIR="${TMP}/config"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_STATE_ROOT="${TMP}/state"
export TARGET_DP_VERSION=6.6.0
export PHASE2_TARGET_VERSION=6.6.0
mkdir -p "$MM_CACHE_ROOT" "$MM_DP_PHASE2_ROOT/6.6.0" "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$MM_STATE_ROOT"
: >"$MM_STATUS_FILE"

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/dp-phase2-common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_install_engine.sh"

private="$(engine_phase2_saved_upstream_path 6.6.0)"
legacy="$(engine_phase2_legacy_public_upstream_path 6.6.0)"
case "$private" in
  "${MM_CACHE_ROOT}/private/"*) pass "canonical path is under private cache" ;;
  *) fail "canonical path not private: ${private}" ;;
esac
case "$legacy" in
  "${MM_DP_PHASE2_ROOT}/6.6.0/"*) pass "legacy path is public final" ;;
  *) fail "legacy path unexpected: ${legacy}" ;;
esac
[[ "$private" != "$legacy" ]] || fail "private and public paths must differ"

# 1. New preserve writes private 0700/0600 and never the public final.
engine_phase2_install_private_upstream "$UPSTREAM_FIXTURE" 6.6.0 \
  || fail "install private upstream"
[[ -f "$private" ]] || fail "private upstream missing after install"
[[ ! -f "$legacy" ]] || fail "public upstream created by new preserve"
dir="$(engine_phase2_private_upstream_dir 6.6.0)"
[[ "$(stat -c '%a' "$dir")" == "700" ]] || fail "private dir mode=$(stat -c '%a' "$dir") want=0700"
[[ "$(stat -c '%a' "$private")" == "600" ]] || fail "private file mode=$(stat -c '%a' "$private") want=0600"
[[ "$(stat -c '%a' "${private}.sha1")" == "600" ]] || fail "private sidecar mode"
[[ "$(stat -c '%a' "${dir}/provenance.env")" == "600" ]] || fail "provenance mode"
engine_phase2_private_upstream_complete 6.6.0 \
  || fail "complete private set not verified after install"
pass "new preserve is private 0700/0600"

# 2. Legacy public copy migrates without deleting a valid Phase 2 final.
rm -rf "$(engine_phase2_private_upstream_dir 6.6.0)"
mkdir -p "${MM_DP_PHASE2_ROOT}/6.6.0"
printf 'valid-final-bundle\n' >"${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar"
cp -f "$UPSTREAM_FIXTURE" "$legacy"
sha1sum "$legacy" | awk '{print $1}' >"${legacy}.sha1"
engine_phase2_migrate_legacy_public_upstream 6.6.0 \
  || fail "legacy migrate"
[[ -f "$private" ]] || fail "private missing after migrate"
[[ ! -f "$legacy" ]] || fail "public leftover after successful migrate"
[[ -f "${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar" ]] \
  || fail "Phase 2 final destroyed by migrate"
engine_phase2_private_upstream_complete 6.6.0 || fail "migrate left incomplete private set"
pass "legacy public upstream migrates; final preserved"

# 3. Failed migration does not delete the only valid upstream copy.
rm -rf "$(engine_phase2_private_upstream_dir 6.6.0)"
printf 'not-allowlisted-upstream\n' >"$legacy"
sha1sum "$legacy" | awk '{print $1}' >"${legacy}.sha1"
if engine_phase2_migrate_legacy_public_upstream 6.6.0; then
  fail "invalid public upstream must not migrate"
fi
[[ -f "$legacy" ]] || fail "failed migrate deleted the only upstream copy"
[[ ! -f "$private" ]] || fail "invalid public was copied to private"
pass "failed migrate retains the only upstream copy"

# 4. New dest_tmp publication helper must not emit *.upstream names.
if grep -n 'dest_tmp}/bringup_py3_dp_after_os_upgrade.sh.upstream' \
  "${ROOT}/scripts/lib/mirror_install_engine.sh"; then
  fail "new Phase 2 publication still copies raw upstream into public dest_tmp"
fi
pass "new Phase 2 publication does not copy raw upstream into dest_tmp"

plant_valid_public() {
  mkdir -p "$(dirname "$legacy")"
  cp -f "$UPSTREAM_FIXTURE" "$legacy"
  sha1sum "$legacy" | awk '{print $1}' >"${legacy}.sha1"
}

plant_allowlisted_private_raw_only() {
  mkdir -p "$(engine_phase2_private_upstream_dir 6.6.0)"
  chmod 0700 "$(engine_phase2_private_upstream_dir 6.6.0)"
  cp -f "$UPSTREAM_FIXTURE" "$private"
  chmod 0600 "$private"
}

# private_sidecar_missing
rm -rf "$(engine_phase2_private_upstream_dir 6.6.0)"
plant_allowlisted_private_raw_only
if engine_phase2_private_upstream_complete 6.6.0; then
  fail "private_sidecar_missing was treated as complete"
fi
plant_valid_public
if engine_phase2_private_upstream_complete 6.6.0; then
  fail "missing sidecar plus public pair was complete"
fi
pass "private_sidecar_missing"

# private_sidecar_wrong_digest
rm -rf "$(engine_phase2_private_upstream_dir 6.6.0)"
plant_allowlisted_private_raw_only
printf '0000000000000000000000000000000000000000  bringup_py3_dp_after_os_upgrade.sh\n' \
  >"${private}.sha1"
chmod 0600 "${private}.sha1"
{
  printf 'TARGET_DP_VERSION=6.6.0\n'
  printf 'BRINGUP_UPSTREAM_SHA1=%s\n' "$(sha1sum "$private" | awk '{print $1}')"
  printf 'BRINGUP_UPSTREAM_SHA256=%s\n' "$(sha256sum "$private" | awk '{print $1}')"
} >"$(engine_phase2_private_upstream_dir 6.6.0)/provenance.env"
chmod 0600 "$(engine_phase2_private_upstream_dir 6.6.0)/provenance.env"
if engine_phase2_private_upstream_complete 6.6.0; then
  fail "private_sidecar_wrong_digest was treated as complete"
fi
plant_valid_public
# Must not delete public merely because private raw exists.
MM_TEST_FAIL_PRIVATE_SIDECAR_MOVE=1
if engine_phase2_migrate_legacy_public_upstream 6.6.0; then
  fail "wrong-digest private plus injected sidecar move must not migrate"
fi
unset MM_TEST_FAIL_PRIVATE_SIDECAR_MOVE
[[ -f "$legacy" ]] || fail "wrong digest migrate deleted public raw"
[[ -f "${legacy}.sha1" ]] || fail "wrong digest migrate deleted public sidecar"
pass "private_sidecar_wrong_digest"

# private_sidecar_move_failure
rm -rf "$(engine_phase2_private_upstream_dir 6.6.0)"
plant_valid_public
MM_TEST_FAIL_PRIVATE_SIDECAR_MOVE=1
if engine_phase2_install_private_upstream "$UPSTREAM_FIXTURE" 6.6.0; then
  fail "private_sidecar_move_failure succeeded"
fi
unset MM_TEST_FAIL_PRIVATE_SIDECAR_MOVE
if engine_phase2_private_upstream_complete 6.6.0; then
  fail "sidecar move failure left a complete private set"
fi
pass "private_sidecar_move_failure"

# provenance_move_failure
rm -rf "$(engine_phase2_private_upstream_dir 6.6.0)"
plant_valid_public
MM_TEST_FAIL_PRIVATE_PROVENANCE_MOVE=1
if engine_phase2_install_private_upstream "$UPSTREAM_FIXTURE" 6.6.0; then
  fail "provenance_move_failure succeeded"
fi
unset MM_TEST_FAIL_PRIVATE_PROVENANCE_MOVE
if engine_phase2_private_upstream_complete 6.6.0; then
  fail "provenance move failure left a complete private set"
fi
[[ -f "$legacy" && -f "${legacy}.sha1" ]] || fail "provenance move failure deleted public pair"
pass "provenance_move_failure"

# required_private_mode_failure
rm -rf "$(engine_phase2_private_upstream_dir 6.6.0)"
plant_valid_public
MM_TEST_FAIL_PRIVATE_MODE=1
if engine_phase2_install_private_upstream "$UPSTREAM_FIXTURE" 6.6.0; then
  fail "required_private_mode_failure succeeded"
fi
unset MM_TEST_FAIL_PRIVATE_MODE
if engine_phase2_private_upstream_complete 6.6.0; then
  fail "mode failure left a complete private set"
fi
[[ -f "$legacy" && -f "${legacy}.sha1" ]] || fail "mode failure deleted public pair"
pass "required_private_mode_failure"

# existing_private_raw_missing_sidecar_plus_valid_legacy_pair
rm -rf "$(engine_phase2_private_upstream_dir 6.6.0)"
plant_allowlisted_private_raw_only
rm -f "${private}.sha1"
plant_valid_public
printf 'valid-final-bundle\n' >"${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar"
engine_phase2_migrate_legacy_public_upstream 6.6.0 \
  || fail "existing_private_raw_missing_sidecar_plus_valid_legacy_pair migrate"
engine_phase2_private_upstream_complete 6.6.0 \
  || fail "repair did not complete private set"
[[ ! -f "$legacy" ]] || fail "public raw remained after successful repair"
[[ ! -f "${legacy}.sha1" ]] || fail "public sidecar remained after successful repair"
[[ -f "${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar" ]] \
  || fail "repair destroyed Phase 2 final"
pass "existing_private_raw_missing_sidecar_plus_valid_legacy_pair"

# migration_failure_retains_public_raw_and_sidecar
rm -rf "$(engine_phase2_private_upstream_dir 6.6.0)"
plant_valid_public
public_raw_before="$(sha256sum "$legacy" | awk '{print $1}')"
public_sha_before="$(cat "${legacy}.sha1")"
MM_TEST_FAIL_PRIVATE_SIDECAR_MOVE=1
if engine_phase2_migrate_legacy_public_upstream 6.6.0; then
  fail "migration_failure_retains_public_raw_and_sidecar unexpectedly succeeded"
fi
unset MM_TEST_FAIL_PRIVATE_SIDECAR_MOVE
[[ -f "$legacy" ]] || fail "failed migrate deleted public raw"
[[ -f "${legacy}.sha1" ]] || fail "failed migrate deleted public sidecar"
[[ "$(sha256sum "$legacy" | awk '{print $1}')" == "$public_raw_before" ]] \
  || fail "failed migrate mutated public raw"
[[ "$(cat "${legacy}.sha1")" == "$public_sha_before" ]] \
  || fail "failed migrate mutated public sidecar"
pass "migration_failure_retains_public_raw_and_sidecar"

echo "ALL test_phase2_private_upstream_storage checks passed"
