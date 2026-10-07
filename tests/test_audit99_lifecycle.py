"""Run-isolation regressions using the real lifecycle and harmless local workers.

No real DP, credentials, package manager, system service or external network.
Run: python3 -m unittest tests.test_audit99_lifecycle
"""
import fcntl
import pty
import select
import termios
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LifecycleIsolation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="audit99-lifecycle-")
        self.p = Path(self.tmp.name)
        self.d = self.p / "lifecycle"
        self.runtime = self.p / "runtime"
        for d in (self.d, self.runtime / "lib", self.p / "bin"):
            d.mkdir(parents=True)
        shutil.copy2(ROOT / "client/bringup_py3_dp_lifecycle.sh", self.runtime)
        for name in ("bringup-lifecycle", "cluster-validation", "post-bringup-migration"):
            shutil.copy2(ROOT / ("client/lib/dp-phase2-" + name + ".sh"), self.runtime / "lib")
        (self.runtime / "lib/dp-phase2-time-readiness.sh").write_text(
            "dp_phase2_load_time_ref_url() { return 0; }\n"
            "dp_phase2_bringup_time_gate() { TIME_READINESS=PASS_SYNCED; BRINGUP_READY=YES; return 0; }\n")
        (self.runtime / "lib/dp-phase2-staging-contract.sh").write_text(
            "dp_phase2_bringup_staging_gate() { return 0; }\n")
        (self.runtime / "bringup_py3_dp_after_os_upgrade.vendor.sh").write_text('''#!/usr/bin/env bash
set -eu
: > "$AUDIT_CASE/entered"
for ((i=0;i<200;i++)); do
  [[ -e "$AUDIT_CASE/release" ]] && break
  sleep 0.05
done
[[ -e "$AUDIT_CASE/release" ]] || exit 44
if [[ "${AUDIT_CHECK_PASSWORD:-0}" == 1 && ! -s "$PHASE2_BRINGUP_DIR/worker-password" ]]; then
  exit 43
fi
echo APT_DEPENDENCY_CHECK=PASS
echo WORKER_ORCHESTRATION=PASS
''')
        cli = self.p / "bin/aella_cli"
        cli.write_text("#!/bin/sh\nexit 0\n")
        cli.chmod(0o700)
        self.env = dict(os.environ)
        self.env.pop("DP_PHASE2_BRINGUP_LIB_ONLY", None)
        self.env.update(
            AUDIT_CASE=str(self.p), PHASE2_BRINGUP_DIR=str(self.d),
            PHASE2_BRINGUP_LOG_DEFAULT=str(self.p / "bringup.log"),
            PHASE2_BRINGUP_ALLOW_NONROOT="1", PHASE2_BRINGUP_MONITOR_SECONDS="0.05",
            CLUSTER_VALIDATION_ENV=str(self.d / "cluster-validation.env"),
            POST_BRINGUP_MIGRATION_ENV=str(self.d / "post-bringup-migration.env"),
            DP_PHASE2_FAKE_IP_MTU="2: audit0: mtu 1500", PATH=str(self.p / "bin") + ":/usr/bin:/bin")

    def tearDown(self):
        (self.p / "release").touch()
        pidfile = self.d / "worker.pid"
        if pidfile.exists():
            try:
                pid = int(pidfile.read_text())
                cmd = Path("/proc/{}/cmdline".format(pid))
                # Only a still-live worker belonging to this exact fixture.
                deadline = time.monotonic() + 2
                while cmd.exists() and str(self.p).encode() in cmd.read_bytes() and time.monotonic() < deadline:
                    time.sleep(0.02)
                if cmd.exists() and str(self.p).encode() in cmd.read_bytes():
                    os.kill(pid, signal.SIGTERM)
            except (ValueError, FileNotFoundError, ProcessLookupError):
                pass
        self.tmp.cleanup()

    def call(self, *args):
        return subprocess.run(["bash", str(self.runtime / "bringup_py3_dp_lifecycle.sh"), *args],
                              env=self.env, capture_output=True, text=True, timeout=18)

    def lib(self, body):
        return subprocess.run(["bash", "-c", 'source "$AUDIT_CASE/runtime/lib/dp-phase2-bringup-lifecycle.sh"\n' + body],
                              env=self.env, capture_output=True, text=True, timeout=15)

    def wait_for(self, predicate):
        end = time.monotonic() + 12
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(0.03)
        self.fail("fixture timeout")

    def seed(self, run="run-A", version="6.6.0"):
        for name, value in {"state": "COMPLETED", "run-id": run, "target-version": version,
                            "exit-code": "0", "started-at": "2026-10-06T12:00:00Z",
                            "log-path": str(self.p / "bringup.log")}.items():
            (self.d / name).write_text(value + "\n")
        result = ("BRINGUP_TERMINAL_STATE=COMPLETED\nBRINGUP_RESULT=PASS\nBRINGUP_RUN_ID={}\n"
                  "BRINGUP_TARGET_VERSION={}\nBRINGUP_EXIT_CODE=0\nBRINGUP_COMPLETION_SENTINEL=PASS\n").format(run, version)
        (self.d / "result.env").write_text(result)
        (self.d / "completion.sentinel").write_text(result)
        (self.p / "bringup.log").write_text("")

    def start_password_worker(self):
        self.env["AUDIT_CHECK_PASSWORD"] = "1"
        q = self.call("--version", "6.6.0", "--detach", "--worker-password", "synthetic-test-only")
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
        self.wait_for(lambda: (self.p / "entered").exists())
        self.assertTrue((self.d / "worker-password").exists())

    def test_losing_lock_preserves_active_worker_credential(self):
        self.start_password_worker()
        before = (self.d / "worker-password").read_bytes()
        run = (self.d / "run-id").read_bytes()
        with (self.d / "lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            q = self.call("--version", "6.6.0", "--detach")
            self.assertNotEqual(q.returncode, 0)
            self.assertEqual((self.d / "worker-password").read_bytes(), before)
            self.assertEqual((self.d / "run-id").read_bytes(), run)
        (self.p / "release").touch()
        self.wait_for(lambda: (self.d / "state").read_text().strip() == "COMPLETED")
        self.wait_for(lambda: not (self.d / "worker-password").exists())

    def test_preownership_vendor_error_preserves_active_credential(self):
        self.start_password_worker()
        self.env["BRINGUP_VENDOR_SCRIPT"] = str(self.p / "missing-vendor")
        q = self.call("--version", "6.6.0", "--detach")
        self.assertNotEqual(q.returncode, 0)
        self.assertTrue((self.d / "worker-password").exists())

    def test_ordinary_reattach_does_not_prompt_or_replace_credential(self):
        self.start_password_worker()
        before = (self.d / "worker-password").read_bytes()
        q = self.call("--version", "6.6.0", "--detach", "--prompt-worker-password")
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
        self.assertIn("MONITOR_EXISTING", q.stdout)
        self.assertEqual((self.d / "worker-password").read_bytes(), before)

    def test_monitor_missing_cli_preserves_all_terminal_files(self):
        self.seed()
        before = {f.name: f.read_bytes() for f in self.d.iterdir()}
        q = self.lib('p2b_discover_aella_cli() { AELLA_CLI_AVAILABLE=NO; return 1; }; p2b_monitor_loop run-A')
        self.assertNotEqual(q.returncode, 0)
        self.assertIn("FAIL_POSTCONDITION", q.stdout)
        self.assertEqual(before, {f.name: f.read_bytes() for f in self.d.iterdir()})

    def test_old_monitor_cannot_adopt_or_corrupt_new_run(self):
        self.seed("new-run-B")
        before = {f.name: f.read_bytes() for f in self.d.iterdir()}
        for cli_failure in (False, True):
            q = self.lib(('p2b_discover_aella_cli() { return 1; }; ' if cli_failure else '') + 'p2b_monitor_loop old-run-A')
            self.assertNotEqual(q.returncode, 0)
            self.assertIn("MONITORED_RUN_REPLACED", q.stdout)
            self.assertNotIn("BRINGUP_RESULT=PASS", q.stdout)
            self.assertEqual(before, {f.name: f.read_bytes() for f in self.d.iterdir()})

    def test_same_run_monitor_can_report_pass(self):
        self.seed()
        q = self.lib('p2b_monitor_loop run-A')
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
        self.assertIn("BRINGUP_RESULT=PASS", q.stdout)

    def test_new_retry_requires_fresh_cluster_confirmation(self):
        self.seed()
        (self.d / "post-bringup-migration.env").write_text(
            "SOURCE_DP_VERSION=6.5.0\nTARGET_DP_VERSION=6.6.0\nPOST_BRINGUP_MIGRATION=NOT_REQUIRED\n")
        q = self.call("--record-cluster-validation", "PASS")
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
        self.assertIn("BRINGUP_RUN_ID=run-A", (self.d / "cluster-validation.env").read_text())
        (self.d / "state").write_text("FAILED\n")
        q = self.call("--version", "6.6.0", "--detach")
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
        (self.p / "release").touch()
        self.wait_for(lambda: (self.d / "state").read_text().strip() == "COMPLETED")
        q = self.call("--status")
        self.assertIn("CLUSTER_VALIDATION=PENDING", q.stdout)
        self.assertIn("DP_UPGRADE_COMPLETE=NO", q.stdout)
        q = self.call("--record-cluster-validation", "PASS")
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
        q = self.call("--status")
        self.assertIn("DP_UPGRADE_COMPLETE=YES", q.stdout)

    def test_unbound_legacy_cluster_pass_is_not_reused(self):
        self.seed()
        (self.d / "cluster-validation.env").write_text("CLUSTER_VALIDATION=PASS\n")
        q = self.call("--status")
        self.assertIn("CLUSTER_VALIDATION=PENDING", q.stdout)
        self.assertNotIn("DP_UPGRADE_COMPLETE=YES", q.stdout)

    def test_migration_pass_is_run_bound(self):
        self.seed()
        (self.d / "post-bringup-migration.env").write_text(
            "SOURCE_DP_VERSION=6.3.0\nTARGET_DP_VERSION=6.6.0\nPOST_BRINGUP_MIGRATION=REQUIRED\n")
        q = self.call("--record-post-bringup-migration", "PASS")
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
        self.seed("new-run-B")
        q = self.call("--status")
        self.assertIn("POST_BRINGUP_MIGRATION=REQUIRED", q.stdout)
        self.assertNotIn("DP_UPGRADE_COMPLETE=YES", q.stdout)

    def test_failed_run_cannot_be_confirmed_pass(self):
        self.seed()
        (self.d / "state").write_text("FAILED\n")
        q = self.call("--record-cluster-validation", "PASS")
        self.assertNotEqual(q.returncode, 0)
        self.assertFalse((self.d / "cluster-validation.env").exists())

    def test_target_mismatch_is_explicit_and_does_not_launch(self):
        self.seed(version="6.5.0")
        before = (self.d / "result.env").read_bytes()
        q = self.call("--version", "6.6.0", "--detach")
        self.assertNotEqual(q.returncode, 0)
        self.assertIn("LIFECYCLE_TARGET_MISMATCH", q.stdout)
        self.assertFalse((self.p / "entered").exists())
        self.assertEqual(before, (self.d / "result.env").read_bytes())

    def test_same_target_completion_replay_remains_idempotent(self):
        self.seed()
        q = self.call("--version", "6.6.0", "--detach")
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
        self.assertIn("BRINGUP_ALREADY_COMPLETED=YES", q.stdout)
        self.assertFalse((self.p / "entered").exists())

    def test_runtime_prompt_is_masked_not_on_worker_argv_and_cleans_up(self):
        master, slave = pty.openpty()
        proc = None
        output = b""
        secret = b"synthetic-runtime-only!"
        try:
            proc = subprocess.Popen(
                ["bash", str(self.runtime / "bringup_py3_dp_lifecycle.sh"), "--version", "6.6.0",
                 "--detach", "--worker-ips", "192.0.2.21", "--prompt-worker-password"],
                env=self.env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
            deadline = time.monotonic() + 12
            while b"Worker SSH password" not in output and time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    output += os.read(master, 65536)
                if proc.poll() is not None:
                    break
            self.assertIn(b"Worker SSH password", output)
            self.assertFalse(termios.tcgetattr(slave)[3] & termios.ECHO, "prompt must disable terminal echo")
            os.write(master, secret + b"\n")
            while proc.poll() is None and time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    output += os.read(master, 65536)
            self.assertEqual(proc.wait(timeout=3), 0, output.decode(errors="replace"))
            while select.select([master], [], [], 0)[0]:
                output += os.read(master, 65536)
            self.assertNotIn(secret, output)
            password = self.d / "worker-password"
            self.assertEqual(password.read_bytes(), secret)
            self.assertEqual(password.stat().st_mode & 0o777, 0o600)
            pid = int((self.d / "worker.pid").read_text())
            self.assertNotIn(secret, Path("/proc/{}/cmdline".format(pid)).read_bytes())
            self.assertNotIn(secret, (self.p / "bringup.log").read_bytes())
            (self.p / "release").touch()
            self.wait_for(lambda: (self.d / "state").read_text().strip() == "COMPLETED")
            self.wait_for(lambda: not password.exists())
        finally:
            if proc is not None and proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=3)
            os.close(slave)
            os.close(master)

    def test_old_credential_cleanup_cannot_remove_replacement_inode(self):
        q = self.lib(r'''DP_PHASE2_BRINGUP_LIB_ONLY=1
source "$AUDIT_CASE/runtime/bringup_py3_dp_lifecycle.sh"
p2b_store_worker_password synthetic-old
printf synthetic-new >"$AUDIT_CASE/replacement"
mv "$AUDIT_CASE/replacement" "$PHASE2_BRINGUP_DIR/worker-password"
p2b_cleanup_lifecycle_owned_worker_password
test "$(cat "$PHASE2_BRINGUP_DIR/worker-password")" = synthetic-new
''')
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)


if __name__ == "__main__":
    unittest.main()
