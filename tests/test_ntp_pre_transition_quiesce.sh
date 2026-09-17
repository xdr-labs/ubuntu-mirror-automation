#!/usr/bin/env bash
# Regression: Jammy→Noble legacy NTP pre-transition quiesce (userdel error 8 prevention).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MM_HERMETIC_TEST_MODE=1
OUT="$(mktemp -d "${TMPDIR:-/tmp}/ntp-quiesce.XXXX")"
trap 'rm -rf "$OUT"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

J2N_IN="${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh.in"
X2B_IN="${ROOT}/client/dp-offline-upgrade-xenial-to-bionic.sh.in"
B2F_IN="${ROOT}/client/dp-offline-upgrade-bionic-to-focal.sh.in"
F2J_IN="${ROOT}/client/dp-offline-upgrade-focal-to-jammy.sh.in"
FIX="${ROOT}/tests/fixtures/jammy-noble-ntp-transition"

[[ -f "$J2N_IN" ]] || { echo "missing template"; exit 1; }
[[ -f "$FIX/ROOT_CAUSE.txt" ]] || { echo "missing root-cause fixture"; exit 1; }
[[ -f "$FIX/jammy-ntp.postrm" ]] || { echo "missing jammy postrm fixture"; exit 1; }

# 0) Root cause fixture must confirm (no speculative fix without evidence).
if grep -q '^ROOT_CAUSE_CONFIRMED=YES$' "$FIX/ROOT_CAUSE.txt" \
  && grep -q 'deluser --system --quiet ntp' "$FIX/jammy-ntp.postrm" \
  && grep -q 'deluser --system --quiet ntp' "$FIX/noble-transitional-ntp.postrm" \
  && grep -q "\[ \"\$1\" = remove \]" "$FIX/jammy-ntp.prerm" \
  && grep -q "userdel: user ntp is currently used by process" "$FIX/dist-upgrade-main.log" \
  && grep -q "error code 8" "$FIX/dist-upgrade-main.log"; then
  pass "0. ROOT_CAUSE confirmed via package scripts + log fixture"
else
  fail "0. ROOT_CAUSE fixture incomplete"
  echo "ROOT_CAUSE_NOT_CONFIRMED"
  exit 1
fi

# Extract quiesce helpers (+ warning classifier) from runner template.
start_line="$(grep -n '^LEGACY_NTP_VERSION_LT=' "$J2N_IN" | head -1 | cut -d: -f1)"
end_line="$(grep -n '^classify_dro_failure()' "$J2N_IN" | head -1 | cut -d: -f1)"
[[ -n "$start_line" && -n "$end_line" && "$end_line" -gt "$start_line" ]] \
  || { echo "failed to locate NTP quiesce block"; exit 1; }
{
  cat <<'HERMETIC_STUB'
# Extracted quiesce block depends on hermetic gate helper defined earlier in the
# full hop client; provide the same production semantics for the unit extract.
dp_offline_hermetic_test_mode() { [[ "${MM_HERMETIC_TEST_MODE:-0}" == "1" ]]; }
dp_offline_hermetic_fixtures_enabled() { dp_offline_hermetic_test_mode; }
HERMETIC_STUB
  sed -n "${start_line},$((end_line - 1))p" "$J2N_IN"
} >"$OUT/ntp_lib.sh"
bash -n "$OUT/ntp_lib.sh" || { echo "extracted ntp_lib.sh syntax error"; exit 1; }

grep -q 'ensure_legacy_ntp_quiesced_before_package_transition()' "$OUT/ntp_lib.sh" \
  && grep -q 'LEGACY_NTP_PACKAGE_DETECTED=' "$OUT/ntp_lib.sh" \
  && grep -q 'legacy_ntp_unit_owned_by_ntp_package()' "$OUT/ntp_lib.sh" \
  && pass "0b. quiesce helpers + package/service markers present (J2N only)" \
  || fail "0b. quiesce helpers missing"

# Other hops must remain unchanged (no pre-transition NTP quiesce).
other_ok=1
for hop_in in "$X2B_IN" "$B2F_IN" "$F2J_IN"; do
  if grep -Eq 'ensure_legacy_ntp_quiesced_before_package_transition|LEGACY_NTP_PACKAGE_DETECTED|NTP_USERDEL_PREVENTION' "$hop_in"; then
    fail "hop-isolation: unexpected NTP quiesce in $(basename "$hop_in")"
    other_ok=0
  fi
done
[[ "$other_ok" -eq 1 ]] && pass "hop-isolation: other 3 hops unchanged"

# Shared test harness
cat >"$OUT/harness.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
STATE_ROOT="${1:?}"
LOG_FILE="${STATE_ROOT}/offline_os_upgrade.log"
mkdir -p "$STATE_ROOT" "$(dirname "$LOG_FILE")"
: >"$LOG_FILE"
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="${RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED:-false}"
NTP_QUIESCE_WAIT_SECS="${NTP_QUIESCE_WAIT_SECS:-2}"
log() { printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" | tee -a "$LOG_FILE"; }
package_transition_evidence_present() { return 1; }
fail_stage() {
  local rc="$1" summary="$2"
  log ERROR "FAIL_STAGE rc=${rc} summary=${summary}"
  printf '%s\n' "$summary" >"${STATE_ROOT}/fail_stage.summary"
  exit "$rc"
}
# shellcheck disable=SC1091
source "$2"
ensure_legacy_ntp_quiesced_before_package_transition
EOS
chmod +x "$OUT/harness.sh"

# a) legacy ntp active + ntp UID process → stop + clear → transition allowed
a_root="$OUT/case-a"
mkdir -p "$a_root"
set +e
STELLAR_OFFLINE_FAKE_LEGACY_NTP_PACKAGE=1 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_UNIT_OWNED=1 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_ACTIVE=1 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_UNIT_FRAGMENT='/lib/systemd/system/ntp.service' \
STELLAR_OFFLINE_FAKE_NTP_UID_PROCS=1 \
STELLAR_OFFLINE_FAKE_SYSTEMCTL_STOP=ok \
STELLAR_OFFLINE_FAKE_NTP_UID_PROCS_AFTER_STOP=0 \
STELLAR_OFFLINE_FAKE_NTPSEC_PACKAGE=0 \
NTP_QUIESCE_WAIT_SECS=3 \
bash "$OUT/harness.sh" "$a_root" "$OUT/ntp_lib.sh" >"$OUT/case-a.out" 2>&1
a_rc=$?
set -e
if [[ "$a_rc" -eq 0 ]] \
  && grep -q 'NTP_PRE_TRANSITION_CHECK=PASS' "$OUT/case-a.out" \
  && grep -q 'LEGACY_NTP_PACKAGE_DETECTED=YES' "$OUT/case-a.out" \
  && grep -q 'LEGACY_NTP_SERVICE_DETECTED=YES' "$OUT/case-a.out" \
  && grep -q 'LEGACY_NTP_SERVICE_QUIESCE=PASS' "$OUT/case-a.out" \
  && grep -q 'NTP_UID_ACTIVE_PROCESS_COUNT=0' "$OUT/case-a.out" \
  && grep -q 'NTP_USERDEL_PREVENTION=PASS' "$OUT/case-a.out" \
  && grep -q 'LEGACY_NTP_SYSTEMCTL_STOP=FAKE_OK' "$OUT/case-a.out"; then
  pass "a. legacy ntp active → stop + clear → PASS"
else
  fail "a. legacy active quiesce"
  cat "$OUT/case-a.out" || true
fi

# b) no legacy ntp package/service → NOT_REQUIRED
b_root="$OUT/case-b"
mkdir -p "$b_root"
set +e
STELLAR_OFFLINE_FAKE_LEGACY_NTP_PACKAGE=0 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_UNIT_OWNED=0 \
STELLAR_OFFLINE_FAKE_NTPSEC_PACKAGE=0 \
STELLAR_OFFLINE_FAKE_NTP_UID_PROCS=0 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_UNIT_FRAGMENT= \
NTP_QUIESCE_WAIT_SECS=1 \
bash "$OUT/harness.sh" "$b_root" "$OUT/ntp_lib.sh" >"$OUT/case-b.out" 2>&1
b_rc=$?
set -e
if [[ "$b_rc" -eq 0 ]] \
  && grep -q 'NTP_PRE_TRANSITION_CHECK=PASS' "$OUT/case-b.out" \
  && grep -q 'LEGACY_NTP_PACKAGE_DETECTED=NO' "$OUT/case-b.out" \
  && grep -q 'LEGACY_NTP_SERVICE_DETECTED=NO' "$OUT/case-b.out" \
  && grep -q 'LEGACY_NTP_SERVICE_QUIESCE=NOT_REQUIRED' "$OUT/case-b.out" \
  && grep -q 'NTP_USERDEL_PREVENTION=PASS' "$OUT/case-b.out" \
  && ! grep -q 'LEGACY_NTP_SYSTEMCTL_STOP=' "$OUT/case-b.out"; then
  pass "b. no legacy ntp → NOT_REQUIRED"
else
  fail "b. no legacy path"
  cat "$OUT/case-b.out" || true
fi

# c) stop ok but ntp UID process remains → STOP before transition
c_root="$OUT/case-c"
mkdir -p "$c_root"
set +e
STELLAR_OFFLINE_FAKE_LEGACY_NTP_PACKAGE=1 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_UNIT_OWNED=1 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_ACTIVE=1 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_UNIT_FRAGMENT='/lib/systemd/system/ntp.service' \
STELLAR_OFFLINE_FAKE_NTP_UID_PROCS=1 \
STELLAR_OFFLINE_FAKE_SYSTEMCTL_STOP=ok \
STELLAR_OFFLINE_FAKE_NTPSEC_PACKAGE=0 \
NTP_QUIESCE_WAIT_SECS=2 \
bash "$OUT/harness.sh" "$c_root" "$OUT/ntp_lib.sh" >"$OUT/case-c.out" 2>&1
c_rc=$?
set -e
if [[ "$c_rc" -ne 0 ]] \
  && grep -q 'NTP_PRE_TRANSITION_CHECK=FAIL' "$OUT/case-c.out" \
  && grep -q 'LEGACY_NTP_PACKAGE_DETECTED=YES' "$OUT/case-c.out" \
  && grep -q 'LEGACY_NTP_SERVICE_DETECTED=YES' "$OUT/case-c.out" \
  && grep -q 'LEGACY_NTP_SERVICE_QUIESCE=FAIL' "$OUT/case-c.out" \
  && grep -q 'NTP_USERDEL_PREVENTION=FAIL' "$OUT/case-c.out" \
  && grep -q 'FAIL_LEGACY_NTP_QUIESCE' "$OUT/case-c.out" \
  && grep -q 'refusing package transition' "$c_root/fail_stage.summary"; then
  pass "c. residual ntp UID process → STOP before transition"
else
  fail "c. residual process must STOP"
  cat "$OUT/case-c.out" || true
fi

# d) ntpsec only → do not stop ntpsec; NOT_REQUIRED
d_root="$OUT/case-d"
mkdir -p "$d_root"
set +e
STELLAR_OFFLINE_FAKE_NTPSEC_PACKAGE=1 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_PACKAGE=0 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_UNIT_OWNED=0 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_UNIT_FRAGMENT='/usr/lib/systemd/system/ntpsec.service' \
STELLAR_OFFLINE_FAKE_NTP_UID_PROCS=0 \
STELLAR_OFFLINE_FAKE_SYSTEMCTL_STOP=fail \
NTP_QUIESCE_WAIT_SECS=1 \
bash "$OUT/harness.sh" "$d_root" "$OUT/ntp_lib.sh" >"$OUT/case-d.out" 2>&1
d_rc=$?
set -e
if [[ "$d_rc" -eq 0 ]] \
  && grep -q 'LEGACY_NTP_PACKAGE_DETECTED=NO' "$OUT/case-d.out" \
  && grep -q 'LEGACY_NTP_SERVICE_DETECTED=NO' "$OUT/case-d.out" \
  && grep -q 'LEGACY_NTP_SERVICE_QUIESCE=NOT_REQUIRED' "$OUT/case-d.out" \
  && grep -q 'REASON=ntpsec_only_no_legacy_ntp' "$OUT/case-d.out" \
  && ! grep -q 'LEGACY_NTP_SYSTEMCTL_STOP=' "$OUT/case-d.out" \
  && ! grep -q 'LEGACY_NTP_STOP_UNIT=ntp.service' "$OUT/case-d.out"; then
  pass "d. ntpsec-only → no ntpsec stop, NOT_REQUIRED"
else
  fail "d. ntpsec-only must not stop services"
  cat "$OUT/case-d.out" || true
fi

# e1) existing real log fixture → warning classification retained
cat >"$OUT/warn_case.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$1"
LIB="$2"
FIXLOG="$3"
hostpath() { printf '%s%s\n' "$ROOT" "$1"; }
LOG_FILE="/var/log/aella/offline_os_upgrade.log"
log() { echo "$1 $2"; }
# shellcheck disable=SC1091
source "$LIB"
mkdir -p "$ROOT/var/log/dist-upgrade"
cp "$FIXLOG" "$ROOT/var/log/dist-upgrade/main.log"
classify_ntp_userdel_warning
emit_ntp_userdel_summary 1
EOS
e_root="$OUT/case-e"
mkdir -p "$e_root"
out="$(bash "$OUT/warn_case.sh" "$e_root" "$OUT/ntp_lib.sh" "$FIX/dist-upgrade-main.log" 2>&1)" \
  && grep -q 'NTP_USERDEL_WARNING_DETECTED=YES' <<<"$out" \
  && grep -q 'NTP_USERDEL_WARNING_BLOCKING=NO' <<<"$out" \
  && pass "e1. existing log fixture still classified as non-blocking warning" \
  || { fail "e1. warning classification regression"; echo "$out"; }

# blocking path with transaction_ok=0
cat >"$OUT/warn_bad.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$1"; LIB="$2"; FIXLOG="$3"
hostpath() { printf '%s%s\n' "$ROOT" "$1"; }
LOG_FILE="/var/log/aella/offline_os_upgrade.log"
log() { echo "$1 $2"; }
# shellcheck disable=SC1091
source "$LIB"
mkdir -p "$ROOT/var/log/dist-upgrade"
cp "$FIXLOG" "$ROOT/var/log/dist-upgrade/main.log"
classify_ntp_userdel_warning
emit_ntp_userdel_summary 0
EOS
out_bad="$(bash "$OUT/warn_bad.sh" "$OUT/case-e-bad" "$OUT/ntp_lib.sh" "$FIX/dist-upgrade-main.log" 2>&1)" \
  && grep -q 'NTP_USERDEL_WARNING_BLOCKING=YES' <<<"$out_bad" \
  && pass "e1b. warning + package failure remains blocking" \
  || { fail "e1b. blocking warning regression"; echo "$out_bad"; }

# e2) prevention path itself must not emit userdel error 8
if ! grep -q "userdel: user ntp is currently used by process" "$OUT/case-a.out" \
  && ! grep -q "error code 8" "$OUT/case-a.out" \
  && grep -q 'NTP_USERDEL_PREVENTION=PASS' "$OUT/case-a.out"; then
  pass "e2. prevention path does not emit userdel error 8"
else
  fail "e2. prevention path unexpectedly logged userdel error 8"
fi

# Forbidden primitives must not appear as executable logic (comments OK).
if grep -nE '^\s*(kill\s+-9|pkill\b|killall\b)' "$J2N_IN" >/dev/null; then
  fail "forbidden kill primitives present in J2N"
else
  pass "no forbidden kill/pkill/killall in J2N"
fi

# Idempotent resume: second run with stamp + zero procs does not re-stop
idem_root="$OUT/case-idem"
mkdir -p "$idem_root"
set +e
STELLAR_OFFLINE_FAKE_LEGACY_NTP_PACKAGE=1 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_UNIT_OWNED=1 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_ACTIVE=0 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_UNIT_FRAGMENT='/lib/systemd/system/ntp.service' \
STELLAR_OFFLINE_FAKE_NTP_UID_PROCS=0 \
STELLAR_OFFLINE_FAKE_NTPSEC_PACKAGE=0 \
NTP_QUIESCE_WAIT_SECS=1 \
bash "$OUT/harness.sh" "$idem_root" "$OUT/ntp_lib.sh" >"$OUT/case-idem1.out" 2>&1
STELLAR_OFFLINE_FAKE_LEGACY_NTP_PACKAGE=1 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_UNIT_OWNED=1 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_ACTIVE=0 \
STELLAR_OFFLINE_FAKE_LEGACY_NTP_UNIT_FRAGMENT='/lib/systemd/system/ntp.service' \
STELLAR_OFFLINE_FAKE_NTP_UID_PROCS=0 \
STELLAR_OFFLINE_FAKE_SYSTEMCTL_STOP=fail \
STELLAR_OFFLINE_FAKE_NTPSEC_PACKAGE=0 \
NTP_QUIESCE_WAIT_SECS=1 \
bash "$OUT/harness.sh" "$idem_root" "$OUT/ntp_lib.sh" >"$OUT/case-idem2.out" 2>&1
idem_rc=$?
set -e
if [[ "$idem_rc" -eq 0 ]] \
  && grep -q 'REASON=idempotent_stamp_reuse' "$OUT/case-idem2.out" \
  && ! grep -q 'LEGACY_NTP_SYSTEMCTL_STOP=FAKE_FAIL' "$OUT/case-idem2.out"; then
  pass "idempotent. resume reuses stamp without re-stop"
else
  fail "idempotent resume"
  cat "$OUT/case-idem1.out" "$OUT/case-idem2.out" || true
fi

# Call site wired before do-release-upgrade
if grep -A6 'snapshot_pre_dro_package_state' "$J2N_IN" \
  | grep -q 'ensure_legacy_ntp_quiesced_before_package_transition'; then
  pass "call-site. quiesce invoked after snapshot, before DRO"
else
  fail "call-site. quiesce not wired before package transition"
fi

echo
echo "RESULT: PASS=${PASS} FAIL=${FAIL}"
[[ "$FAIL" -eq 0 ]]
