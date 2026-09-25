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

echo "TEST_DPKG_UPDATES_EMPTY_LISTING=PASS"
