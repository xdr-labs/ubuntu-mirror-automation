#!/usr/bin/env bash
# Targeted regressions for post-Menu7 five-pass hardening fixes.
# Does NOT run full suite, R2/ACPS redownload, or real DP upgrade.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

echo "=== test_post_menu7_hardening_regressions ==="

# --- G1: runtime manifest includes selective planners/sync helpers ---
# shellcheck source=/dev/null
source "${ROOT}/lib/runtime_manifest.sh"
RUNTIME="$TMP/runtime"
um_runtime_install_tree "$ROOT" "$RUNTIME"
for rel in \
  scripts/build-selective-mirror-plan.py \
  scripts/lib/sync_by_hash.py \
  scripts/lib/sync_release_upgraders.py \
  scripts/lib/sync_legacy_releases.py \
  scripts/lib/validate_upgrade_profile.py
do
  if [[ -f "${RUNTIME}/${rel}" ]]; then
    pass "runtime has ${rel}"
  else
    fail "runtime missing ${rel}"
  fi
done
um_runtime_verify_dependency_closure "$RUNTIME" \
  && pass "runtime dependency closure" \
  || fail "runtime dependency closure"

# --- A1: missing verify/publish identity fails readiness ---
# shellcheck source=/dev/null
source "${ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/state.sh"
SEL="$TMP/selective"
mkdir -p "${SEL}/state" "${SEL}/published/hops"
ln -sfn "${SEL}/published" "${SEL}/current"
printf 'READY\nprofile_name=offline-upgrade-selective\n' >"${SEL}/state/READY"
python3 - <<'PY' "$SEL"
import json, os, sys
root = sys.argv[1]
state = os.path.join(root, 'state')
plan = {
  'plan_checksum': 'a' * 64,
  'discovery_artifact_checksum': 'b' * 64,
  'counts': {'unique_deb_sha256': 1, 'unresolved_deb_payloads': 0},
}
ver = {
  'validation_result': 'PASS',
  'validation_phase': 'pre_publish',
  'verified_files': 1,
  'expected_files': 1,
  'unresolved_count': 0,
  'checksum_failures': 0,
  # Intentionally omit plan/discovery identity
}
pub = {
  'validation_result': 'PASS',
  'validation_phase': 'post_publish',
  'gates': {
    'nginx_effective_root': 'PASS',
    'nginx_config': 'PASS',
    'nginx_http': 'PASS',
    'post_publish_http': 'PASS',
  },
}
for name, doc in (
  ('plan.json', plan),
  ('verify-result.json', ver),
  ('publish-result.json', pub),
):
  with open(os.path.join(state, name), 'w') as fh:
    json.dump(doc, fh)
PY
export SELECTIVE_MIRROR_ROOT="$SEL"
if um_evaluate_selective_ready 2>/dev/null; then
  fail "A1 missing identity should not be READY"
else
  printf '%s' "${UM_SELECTIVE_READY_REASON}" | grep -q 'plan checksum missing from verify' \
    && pass "A1 missing verify plan identity fails closed" \
    || fail "A1 reason missing plan checksum text: ${UM_SELECTIVE_READY_REASON}"
fi

# --- F1: typo MIRROR_MODE must not silently become selective ---
# shellcheck source=/dev/null
source "${ROOT}/lib/config.sh"
set +e
out="$(MIRROR_MODE=selctive um_resolve_mirror_mode 0 0 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -qi 'Unsupported MIRROR_MODE' \
  && pass "F1 typo MIRROR_MODE rejected" \
  || fail "F1 typo MIRROR_MODE not rejected (rc=${rc} out=${out})"

# --- F3: obsolete installer flags hard-error ---
set +e
out="$(bash "${ROOT}/install.sh" --no-sync 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -qi 'Obsolete option' \
  && pass "F3 obsolete --no-sync rejected" \
  || fail "F3 obsolete flag not rejected (rc=${rc})"

# --- B2: backup session stable across multiple backups ---
export BACKUP_DIR="$TMP/backups"
unset UM_BACKUP_SESSION || true
um_backup_session_dir >/dev/null
s1="$UM_BACKUP_SESSION"
printf 'one\n' >"$TMP/a.conf"
printf 'two\n' >"$TMP/b.conf"
um_backup_file "$TMP/a.conf" >/dev/null
# Force a second wall-clock second if possible without sleeping long: reuse session var.
um_backup_file "$TMP/b.conf" >/dev/null
s2="$UM_BACKUP_SESSION"
[[ "$s1" == "$s2" ]] && [[ -d "$s1" ]] \
  && pass "B2 backup session stable" \
  || fail "B2 backup session drifted s1=${s1} s2=${s2}"

# --- I1: um_write_file preserves trailing newline ---
printf 'line\n' | um_write_file "$TMP/written.conf" 0644
if [[ "$(wc -c <"$TMP/written.conf")" -eq 5 ]] && [[ "$(tail -c1 "$TMP/written.conf" | od -An -tx1)" == *"0a"* ]]; then
  pass "I1 um_write_file preserves trailing newline"
else
  fail "I1 trailing newline not preserved"
fi

# --- I2: um_die does not include exit code in message ---
set +e
out="$(bash -c 'source "'"${ROOT}"'/lib/common.sh"; um_die "boom" 7' 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 7 ]] && printf '%s' "$out" | grep -Fq 'boom' \
  && ! printf '%s' "$out" | grep -Eq 'boom 7|ERROR.* 7$' \
  && pass "I2 um_die message/code split" \
  || fail "I2 um_die API (rc=${rc} out=${out})"

# --- H1: resume timer has RandomizedDelaySec ---
grep -q 'RandomizedDelaySec=' "${ROOT}/systemd/dp-os-upgrade-resume.timer" \
  && pass "H1 resume timer RandomizedDelaySec" \
  || fail "H1 RandomizedDelaySec missing"

# --- D2: production publish bypass without dual hermetic fails ---
set +e
out="$(
  env -u MM_ALLOW_SELECTIVE_PUBLISH_TEST_BYPASS MM_HERMETIC_TEST_MODE=0 \
    python3 "${ROOT}/scripts/lib/selective_mirror.py" publish \
      --selective-root "$SEL" --skip-post-publish 2>&1
)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'SELECTIVE_PUBLISH_TEST_BYPASS=FAIL' \
  && pass "D2 publish bypass gated" \
  || fail "D2 publish bypass not gated (rc=${rc} out=${out})"

# --- C1: R2/ACPS curl args include speed watchdog ---
grep -q 'speed-limit' "${ROOT}/scripts/lib/r2_acquire.sh" \
  && grep -q 'speed-time' "${ROOT}/scripts/lib/r2_acquire.sh" \
  && grep -q 'speed-limit' "${ROOT}/scripts/lib/acps_acquire.sh" \
  && pass "C1 stall watchdog present" \
  || fail "C1 stall watchdog missing"

# --- F2: conf set escapes special characters ---
printf 'FOO="bar"\n' >"$TMP/escape.conf"
um_conf_set_key "$TMP/escape.conf" "PATH_VAL" 'a&b|$c`"d'
# shellcheck disable=SC1090
source "$TMP/escape.conf"
[[ "${PATH_VAL}" == 'a&b|$c`"d' ]] \
  && pass "F2 conf serialization escapes specials" \
  || fail "F2 conf serialization broke value (${PATH_VAL:-})"

# --- E2: HTTP normalizer refuses paths outside approved mirror root ---
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/http_publication_permissions.sh"
outside="$TMP/outside-client"
mkdir -p "$outside"
chmod 0700 "$outside"
export MM_MIRROR_ROOT="$TMP/approved-spool"
mkdir -p "$MM_MIRROR_ROOT"
set +e
out="$(mm_normalize_http_public_tree_permissions "$outside" client 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'HTTP_PUBLIC_ROOT_CONTAINMENT=FAIL' \
  && pass "E2 outside-root normalize rejected" \
  || fail "E2 containment not enforced (rc=${rc} out=${out})"

# --- ACPS resume uses Content-Range (not blind continue-at) ---
grep -q 'ACPS_CONTENT_RANGE_MISMATCH' "${ROOT}/scripts/lib/acps_acquire.sh" \
  && ! grep -qE '^[[:space:]]*--continue-at[[:space:]]+-' "${ROOT}/scripts/lib/acps_acquire.sh" \
  && pass "ACPS Content-Range resume contract" \
  || fail "ACPS still uses blind continue-at or missing range check"

# --- Release-upgrader SHA256 required before fetch ---
grep -q 'release upgrader missing sha256' "${ROOT}/scripts/lib/selective_mirror.py" \
  && pass "upgrader SHA256 required before fetch" \
  || fail "upgrader empty-SHA guard missing"

# --- Durable DP state persistence fail-closed (runner + safety helpers) ---
! grep -nE 'osu_write_state_json "\$\(osu_build_state_json\)" \|\| true' \
    "${ROOT}/scripts/dp-os-upgrade-runner.sh" \
  && grep -q 'state_persistence_failed' "${ROOT}/scripts/dp-os-upgrade-runner.sh" \
  && grep -q 'refusing to continue with uncertain durable state' \
    "${ROOT}/scripts/lib/dp-os-upgrade-common.sh" \
  && pass "durable state fail-closed contracts" \
  || fail "durable state fail-closed contracts missing"

# --- G2: migrate preserves entrypoint wrapper ---
grep -q 'ubuntu-offline-mirror-entrypoint.sh' "${ROOT}/lib/config.sh" \
  && pass "G2 migrate installs entrypoint wrapper" \
  || fail "G2 migrate still only symlinks core"

[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS test_post_menu7_hardening_regressions"
