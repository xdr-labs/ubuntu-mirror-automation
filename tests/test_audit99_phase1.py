"""Phase 1 dispatch and evidence regressions; no OS/package mutations."""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOPS = [("xenial-to-bionic", "16.04", "18.04"), ("bionic-to-focal", "18.04", "20.04"),
        ("focal-to-jammy", "20.04", "22.04"), ("jammy-to-noble", "22.04", "24.04")]


def function(text, name):
    return name + "() {" + text.split(name + "() {", 1)[1].split("\n}\n", 1)[0] + "\n}\n"


class Phase1Safety(unittest.TestCase):
    def run_script(self, body, **env_extra):
        env = dict(os.environ, **env_extra)
        return subprocess.run(["bash", "-c", "set -euo pipefail\n" + body],
                              cwd=ROOT, env=env, text=True, capture_output=True, timeout=30)

    def test_live_owner_precedes_target_os_recovery_in_all_hops(self):
        for hop, source, target in HOPS:
            fn = function((ROOT / ("client/dp-offline-upgrade-" + hop + ".sh.in")).read_text(), "handle_existing_state")
            generated = function((ROOT / ("client/dp-offline-upgrade-" + hop + ".sh")).read_text(), "handle_existing_state")
            self.assertEqual(fn, generated, hop)
            cases = [(source, "1", "inactive", "FAILED"),
                     (target, "1", "inactive", "UPGRADING"),
                     (target, "0", "inactive", "FAILED"),
                     (target, "0", "inactive", "POST_BOOT_VERIFY"),
                     (target, "0", "inactive", "UPGRADING"),
                     (target, "0", "active", "POST_BOOT_VERIFY"),
                     (target, "0", "activating", "POST_BOOT_VERIFY"),
                     (target, "0", "failed", "POST_BOOT_VERIFY")]
            for version, live, postboot, state in cases:
                with self.subTest(hop=hop, version=version, live=live, postboot=postboot, state=state), tempfile.TemporaryDirectory() as tmp:
                    body = r'''
EC_OS=24; EC_STATE=23; EC_BUSY=22
PREVIOUS_HOP_TERMINAL_STATE=PREVIOUS
POSTBOOT_UNIT_NAME=fixture-postboot.service
POSTBOOT_PATH="$CASE_ROOT/postboot.sh"
TEST_ROOT="$CASE_ROOT"
read_state() { echo "$OBS_STATE"; }
read_os_field() { echo "$OBSERVED_OS"; }
hostpath() { printf '%s' "$1"; }
log() { echo "$*"; }
die() { exit "$1"; }
detect_upgrade_already_running() { echo LIVE_CHECK >>"$CASE_ROOT/calls"; [[ "$LIVE" == 1 ]]; }
live_upgrade_evidence_present() { echo LIVE_CHECK >>"$CASE_ROOT/calls"; [[ "$LIVE" == 1 ]]; }
allow_live_systemctl() { return 0; }
systemctl_show_prop() { printf '%s\n' "$POSTBOOT_STATE"; }
refuse_duplicate_upgrade() { echo BUSY >>"$CASE_ROOT/calls"; exit 22; }
install_authoritative_postboot_runtime() { echo REFRESH >>"$CASE_ROOT/calls"; return 0; }
printf '#!/bin/bash\necho POSTBOOT >>"$CASE_ROOT/calls"\n' >"$POSTBOOT_PATH"
chmod +x "$POSTBOOT_PATH"
''' + fn + "\nhandle_existing_state\n"
                    q = self.run_script(body, CASE_ROOT=tmp, OBSERVED_OS=version, LIVE=live,
                                        OBS_STATE=state, POSTBOOT_STATE=postboot)
                    calls = (Path(tmp) / "calls").read_text()
                    self.assertIn("LIVE_CHECK", calls)
                    if live == "1" or postboot in ("active", "activating"):
                        self.assertEqual(q.returncode, 22, q.stdout + q.stderr)
                        self.assertNotIn("POSTBOOT", calls)
                        self.assertNotIn("REFRESH", calls)
                    else:
                        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
                        self.assertIn("POSTBOOT", calls)

    def test_zero_and_nonzero_log_baseline_preserve_transition_evidence(self):
        for initial in ("", "old harmless record\n"):
            with self.subTest(empty=not initial), tempfile.TemporaryDirectory() as tmp:
                body = '''source client/lib/dp-offline-durable-write.sh
source client/lib/dp-offline-release-upgrade-reconciliation.sh
''' + r'''
TEST_ROOT="$CASE_ROOT/root"
STATE_ROOT=/opt/aelladata/os-upgrade/offline
STATE_FILE="$STATE_ROOT/state"
LOG_FILE="$CASE_ROOT/recon.log"
PIN_HOP=xenial-to-bionic
PIN_SOURCE_VERSION=16.04; PIN_TARGET_VERSION=18.04
PIN_SOURCE_CODENAME=xenial; PIN_TARGET_CODENAME=bionic
EC_RESUME=29
hostpath() { printf '%s%s' "$TEST_ROOT" "$1"; }
critical_holds_dir() { hostpath "$STATE_ROOT/critical-holds"; }
log() { :; }
read_os_field() { echo 16.04; }
read_state() { echo FAILED_BEFORE_PACKAGE_TRANSITION; }
load_release_upgrade_started_flag() { :; }
mkdir -p "$TEST_ROOT/var/log/apt" "$(critical_holds_dir)" "$TEST_ROOT/var/lib/dpkg"
printf '%s' "$INITIAL" >"$TEST_ROOT/var/log/dpkg.log"
: >"$TEST_ROOT/var/log/apt/history.log"
: >"$TEST_ROOT/var/log/apt/term.log"
: >"$TEST_ROOT/var/lib/dpkg/status"
record_release_upgrade_run_baseline
printf '%s startup archives unpack\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$TEST_ROOT/var/log/dpkg.log"
diagnose_release_upgrade_state
'''
                q = self.run_script(body, CASE_ROOT=tmp, INITIAL=initial)
                self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
                self.assertIn("PACKAGE_TRANSITION_CLASS=AUTHORITATIVE_PACKAGE_TRANSITION", q.stdout)
                self.assertIn("SAFE_TO_RERUN=NO", q.stdout)

    def test_rotated_dpkg_and_apt_records_use_local_time_and_exclude_history(self):
        for tz, local_hour in [("UTC", "01"), ("Asia/Seoul", "10")]:
            for kind in ("dpkg", "apt"):
                with self.subTest(tz=tz, kind=kind), tempfile.TemporaryDirectory() as tmp:
                    f = Path(tmp) / "log"
                    if kind == "dpkg":
                        data = ("2026-10-06 {}:00:00 startup archives unpack OLD\n"
                                "2026-10-07 {}:00:00 startup archives unpack NEW\n").format(local_hour, local_hour)
                    else:
                        data = ("Start-Date: 2026-10-06  {}:00:00\nUpgrade: OLD\nEnd-Date: 2026-10-06  {}:01:00\n"
                                "Start-Date: 2026-10-07  {}:00:00\nUpgrade: NEW\nEnd-Date: 2026-10-07  {}:01:00\n").format(*([local_hour] * 4))
                    f.write_text(data)
                    body = ('source client/lib/dp-offline-release-upgrade-reconciliation.sh\n'
                            'RECON_BASE_STARTED_UTC=2026-10-07T00:59:59Z\n'
                            'recon_slice_log_after_baseline ' + shlex.quote(str(f)) + ' -1 15\n')
                    q = self.run_script(body, TZ=tz)
                    self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
                    self.assertIn("NEW", q.stdout)
                    self.assertNotIn("OLD", q.stdout)

    def test_unavailable_log_evidence_blocks_conditional_resume(self):
        with tempfile.TemporaryDirectory() as tmp:
            body = r'''
source client/lib/dp-offline-release-upgrade-reconciliation.sh
TEST_ROOT="$CASE_ROOT"
STATE_ROOT=/state; STATE_FILE=/state/state; LOG_FILE="$CASE_ROOT/log"
PIN_SOURCE_VERSION=16.04; PIN_TARGET_VERSION=18.04
PIN_SOURCE_CODENAME=xenial; PIN_TARGET_CODENAME=bionic; PIN_HOP=xenial-to-bionic
hostpath() { printf '%s%s' "$CASE_ROOT" "$1"; }
read_state() { echo FAILED_BEFORE_PACKAGE_TRANSITION; }
read_os_field() { echo 16.04; }
log() { :; }
load_release_upgrade_started_flag() { :; }
recon_load_baseline() {
  RECON_BASELINE_LOADED=YES; RECON_BASE_STARTED_UTC=invalid
  RECON_BASE_DPKG_INODE=-1; RECON_BASE_DPKG_OFFSET=0; RECON_BASE_DPKG_PREFIX_SHA=
  RECON_BASE_APT_HIST_INODE=-1; RECON_BASE_APT_HIST_OFFSET=0; RECON_BASE_APT_HIST_PREFIX_SHA=
}
mkdir -p "$CASE_ROOT/var/log/apt"
printf '2026-10-07 01:00:00 startup archives unpack\n' >"$CASE_ROOT/var/log/dpkg.log"
: >"$CASE_ROOT/var/log/apt/history.log"
if package_transition_evidence_present; then :; else exit 91; fi
diagnose_release_upgrade_state
'''
            q = self.run_script(body, CASE_ROOT=tmp)
            self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
            self.assertIn("SAFE_TO_RERUN=NO", q.stdout)
            self.assertIn("MANUAL_REVIEW_REQUIRED=YES", q.stdout)

    def test_invalid_slicer_error_propagates_under_conditional_call(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / "log"
            f.write_text("2026-10-07 01:00:00 startup archives unpack\n")
            body = ('source client/lib/dp-offline-release-upgrade-reconciliation.sh\n'
                    'RECON_BASE_STARTED_UTC=invalid\nif recon_slice_log_after_baseline '
                    + shlex.quote(str(f)) + ' -1 1; then exit 90; else exit 0; fi\n')
            q = self.run_script(body)
            self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
            self.assertEqual(q.stdout, "")

    def test_invalid_rotation_baseline_is_not_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / "log"
            f.write_text("2026-10-07 01:00:00 startup archives unpack\n")
            body = ('source client/lib/dp-offline-release-upgrade-reconciliation.sh\n'
                    'RECON_BASE_STARTED_UTC=invalid\nrecon_slice_log_after_baseline ' + shlex.quote(str(f)) + ' -1 1\n')
            q = self.run_script(body)
            self.assertNotEqual(q.returncode, 0)
            self.assertEqual(q.stdout, "")


if __name__ == "__main__":
    unittest.main()
