#!/usr/bin/env bash
# Empty /var/lib/dpkg/updates must not be a package transition.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

extract_block() {
  awk '/# BEGIN_DPKG_UPDATES_LISTING_COMPARE/,/# END_DPKG_UPDATES_LISTING_COMPARE/' "$1"
}

XENIAL="${ROOT}/client/dp-offline-upgrade-xenial-to-bionic.sh.in"
BASE="$(extract_block "$XENIAL")"
[[ -n "$BASE" ]] || fail "listing compare block missing"
for hop in bionic-to-focal focal-to-jammy jammy-to-noble; do
  other="$(extract_block "${ROOT}/client/dp-offline-upgrade-${hop}.sh.in")"
  [[ "$other" == "$BASE" ]] || fail "${hop} listing compare block drifted"
done
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  for ext in sh sh.in; do
    f="${ROOT}/client/dp-offline-upgrade-${hop}.${ext}"
    if grep -F -q 'printf '"'"'%s\n'"'"' "$listing_now"' "$f"; then
      fail "${hop}.${ext} still rebuilds the listing with printf"
    fi
    grep -q '_dpkg_updates_listing_differs' "$f" || fail "${hop}.${ext} missing byte compare"
  done
done
pass "all hops use byte-exact dpkg updates compare"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck disable=SC1090
source /dev/stdin <<<"$BASE"

log() { printf 'LOG %s\n' "$*" >>"${TMP}/log"; }
persist_flags() {
  printf '%s\n' "${RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED}" \
    >"${HOLDS_DIR}/release_upgrade_package_transition_started"
}
_hp() { printf '%s%s\n' "$FIX" "$1"; }
detect_package_transition_evidence() { return "${DETECT_RC:-1}"; }

FIX="${TMP}/root"
HOLDS_DIR="${TMP}/holds"
PIN_SOURCE_VERSION="16.04"
TEST_ROOT="$FIX"
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="true"
mkdir -p "$HOLDS_DIR" "${FIX}/etc" "${FIX}/var/lib/dpkg/updates"
printf 'VERSION_ID=16.04\n' >"${FIX}/etc/os-release"

_write_dpkg_updates_listing "${FIX}/var/lib/dpkg/updates" "${HOLDS_DIR}/dpkg_updates_listing_before"
[[ ! -s "${HOLDS_DIR}/dpkg_updates_listing_before" ]] || fail "empty listing was not zero bytes"
if _dpkg_updates_listing_differs "${FIX}/var/lib/dpkg/updates"; then
  fail "empty→empty reported a transition"
fi
pass "empty baseline → empty current = no transition"

printf '0001\n' >"${FIX}/var/lib/dpkg/updates/0001"
if ! _dpkg_updates_listing_differs "${FIX}/var/lib/dpkg/updates"; then
  fail "added dpkg update entry was not a transition"
fi
pass "added dpkg update entry = transition"

rm -f "${FIX}/var/lib/dpkg/updates/0001"
: >"${HOLDS_DIR}/dpkg_updates_listing_before"
cat >"${HOLDS_DIR}/package_transition_detection.done" <<'EOF'
PACKAGE_TRANSITION_DETECTION_SOURCE=dpkg_status_db
PACKAGE_TRANSITION_DETECTION_EVIDENCE=dpkg_updates_changed
EOF
printf 'true\n' >"${HOLDS_DIR}/release_upgrade_package_transition_started"
DETECT_RC=1
reclassify_false_empty_dpkg_updates_transition || fail "false empty marker was not reclassified"
grep -qx 'false' "${HOLDS_DIR}/release_upgrade_package_transition_started" \
  || fail "marker still true after reclassify"
grep -q 'FALSE_DPKG_UPDATES_TRANSITION_RECLASSIFIED=YES' "${TMP}/log" \
  || fail "reclassify log missing"
pass "empty→empty false marker reclassified"

printf 'true\n' >"${HOLDS_DIR}/release_upgrade_package_transition_started"
cat >"${HOLDS_DIR}/package_transition_detection.done" <<'EOF'
PACKAGE_TRANSITION_DETECTION_SOURCE=dpkg_log
PACKAGE_TRANSITION_DETECTION_EVIDENCE=startup archives unpack
EOF
if reclassify_false_empty_dpkg_updates_transition; then
  fail "real dpkg_log evidence was cleared"
fi
grep -qx 'true' "${HOLDS_DIR}/release_upgrade_package_transition_started" \
  || fail "real evidence marker was weakened"
pass "real mutation evidence stays fail-closed"

cat >"${HOLDS_DIR}/package_transition_detection.done" <<'EOF'
PACKAGE_TRANSITION_DETECTION_SOURCE=dpkg_status_db
PACKAGE_TRANSITION_DETECTION_EVIDENCE=dpkg_updates_changed
EOF
printf '0001\n' >"${HOLDS_DIR}/dpkg_updates_listing_before"
DETECT_RC=1
if reclassify_false_empty_dpkg_updates_transition; then
  fail "non-empty baseline was reclassified"
fi
pass "non-empty baseline is not the empty-listing false positive"

: >"${HOLDS_DIR}/dpkg_updates_listing_before"
DETECT_RC=0
if reclassify_false_empty_dpkg_updates_transition; then
  fail "fresh mutation scan was ignored"
fi
grep -qx 'true' "${HOLDS_DIR}/release_upgrade_package_transition_started" \
  || fail "marker cleared despite fresh mutation evidence"
pass "fresh real-mutation scan stays fail-closed"

printf 'true\n' >"${HOLDS_DIR}/release_upgrade_package_transition_started"
cat >"${HOLDS_DIR}/package_transition_detection.done" <<'EOF'
PACKAGE_TRANSITION_DETECTION_SOURCE=dpkg_status_db
PACKAGE_TRANSITION_DETECTION_EVIDENCE=dpkg_updates_changed
EOF
: >"${HOLDS_DIR}/dpkg_updates_listing_before"
DETECT_RC=1
if reclassify_false_empty_dpkg_updates_transition; then
  :
else
  fail "empty directory with a successful listing read was not reclassified"
fi
printf 'true\n' >"${HOLDS_DIR}/release_upgrade_package_transition_started"
if _dpkg_updates_listing_differs "${FIX}/no-such-dpkg-updates"; then
  :
else
  fail "missing updates directory treated as the same listing"
fi
mv "${FIX}/var/lib/dpkg/updates" "${FIX}/var/lib/dpkg/updates.saved"
if reclassify_false_empty_dpkg_updates_transition; then
  mv "${FIX}/var/lib/dpkg/updates.saved" "${FIX}/var/lib/dpkg/updates"
  fail "missing updates directory cleared the transition marker"
fi
mv "${FIX}/var/lib/dpkg/updates.saved" "${FIX}/var/lib/dpkg/updates"
grep -qx 'true' "${HOLDS_DIR}/release_upgrade_package_transition_started" \
  || fail "marker cleared while updates directory was missing"
pass "missing updates directory stays fail-closed"

printf '0001\n' >"${FIX}/var/lib/dpkg/updates/0001"
find() { return 2; }
FAILED_LISTING="${HOLDS_DIR}/failed-listing"
rm -f "$FAILED_LISTING"
if _write_dpkg_updates_listing "${FIX}/var/lib/dpkg/updates" "$FAILED_LISTING"; then
  unset -f find
  fail "listing write succeeded after find failure"
fi
[[ ! -e "$FAILED_LISTING" ]] || { unset -f find; fail "failed find created a listing file"; }
if _dpkg_updates_listing_differs "${FIX}/var/lib/dpkg/updates"; then
  :
else
  unset -f find
  fail "failed listing read treated as the same listing"
fi
if reclassify_false_empty_dpkg_updates_transition; then
  unset -f find
  fail "failed find cleared the transition marker"
fi
grep -qx 'true' "${HOLDS_DIR}/release_upgrade_package_transition_started" \
  || { unset -f find; fail "marker cleared after listing enumeration failure"; }
unset -f find
pass "listing enumeration failure stays fail-closed"

# Unreadable pre-DRO baseline aborts before do-release-upgrade.
SNAP="$(awk '
  /^snapshot_pre_dro_package_state\(\)/ { p=1 }
  /^_sanitize_transition_evidence\(\)/ { exit }
  p
' "$XENIAL")"
[[ -n "$SNAP" ]] || fail "snapshot function missing"
for hop in bionic-to-focal focal-to-jammy jammy-to-noble; do
  other="$(awk '
    /^snapshot_pre_dro_package_state\(\)/ { p=1 }
    /^_sanitize_transition_evidence\(\)/ { exit }
    p
  ' "${ROOT}/client/dp-offline-upgrade-${hop}.sh.in")"
  [[ "$other" == "$SNAP" ]] || fail "${hop} snapshot abort drifted"
done
run_snapshot_abort() {
  local mode="$1"
  local out="${TMP}/snap-${mode}.out"
  set +e
  (
    # shellcheck disable=SC1090
    source /dev/stdin <<<"$SNAP"
    log() { printf '%s\n' "$*"; }
    fail_stage() { printf 'FAIL_STAGE:%s\n' "$2"; printf 'ROLLBACK_ELIGIBLE=YES\n'; exit 9; }
    do-release-upgrade() { echo SPAWNED >"${TMP}/dro-${mode}"; }
    if [[ "$mode" == "missing" ]]; then
      rm -rf "${FIX}/var/lib/dpkg/updates"
    else
      mkdir -p "${FIX}/var/lib/dpkg/updates"
      find() { return 2; }
    fi
    # Earlier cases leave a true marker. This abort must not create one.
    rm -f "${HOLDS_DIR}/release_upgrade_package_transition_started"
    snapshot_pre_dro_package_state
    do-release-upgrade
  ) >"$out" 2>&1
  local rc=$?
  set -e
  [[ "$rc" -eq 9 ]] || fail "snapshot ${mode} rc=${rc} $(cat "$out")"
  grep -q 'FAIL_STAGE:DPKG_UPDATES_LISTING_BASELINE=UNREADABLE' "$out" || fail "snapshot ${mode} did not fail closed"
  grep -q 'ROLLBACK_ELIGIBLE=YES' "$out" || fail "snapshot ${mode} rollback not eligible"
  grep -q 'PACKAGE_TRANSITION_STARTED=NO' "$out" || fail "snapshot ${mode} missing pre-transition marker"
  [[ ! -e "${TMP}/dro-${mode}" ]] || fail "snapshot ${mode} spawned do-release-upgrade"
  if [[ -f "${HOLDS_DIR}/release_upgrade_package_transition_started" ]]; then
    grep -qx 'true' "${HOLDS_DIR}/release_upgrade_package_transition_started" \
      && fail "snapshot ${mode} set an irreversible transition marker"
  fi
}
run_snapshot_abort missing
unset -f find || true
run_snapshot_abort enum
unset -f find || true
mkdir -p "${FIX}/var/lib/dpkg/updates"
pass "unreadable pre-DRO baseline aborts before do-release-upgrade"

echo "TEST_DPKG_UPDATES_EMPTY_LISTING=PASS"
