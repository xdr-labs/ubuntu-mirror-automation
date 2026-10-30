"""Hermetic regressions for progress and current-run completion display.

Uses real Bash libraries and the public read-only wrapper with disposable state.
Never invokes a vendor upgrade, installs a package or contacts a real DP.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
LIFECYCLE = ROOT / "client/lib/dp-phase2-bringup-lifecycle.sh"
WRAPPER = ROOT / "client/bringup_py3_dp_lifecycle.sh"


class ProgressStatusTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.state = self.base / "state"
        self.state.mkdir()
        self.log = self.base / "bringup.log"
        self.log.write_text("PHASE2_LIFECYCLE_RUN_BEGIN run_id=current\n")
        for name, value in {
            "run-id": "current", "log-start-offset": "0", "state": "COMPLETED",
            "target-version": "6.6.0", "exit-code": "0", "log-path": str(self.log),
        }.items():
            (self.state / name).write_text(value + "\n")
        (self.state / "result.env").write_text(
            "BRINGUP_RUN_ID=current\nBRINGUP_RESULT=PASS\n"
            "BRINGUP_TERMINAL_STATE=COMPLETED\nBRINGUP_EXIT_CODE=0\n"
            "BRINGUP_COMPLETION_SENTINEL=PASS\n"
        )
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.cli = self.bin / "aella_cli"
        self.cli.write_text(
            '#!/usr/bin/env bash\nwhile IFS= read -r cmd; do\n'
            'case "$cmd" in\n"show status") printf "%s\\n" "$TEST_NATIVE_STATUS";;\n'
            'quit) exit 0;;\n*) exit 91;;\nesac\ndone\nexit 92\n'
        )
        self.cli.chmod(0o700)
        self.cluster = self.base / "cluster.env"
        self.migration = self.base / "migration.env"
        self.healthy = (
            "DataProcessor(DL-master)> show status\nAll cluster nodes are ready\n"
            "All host services are ready\nLicense is valid\n"
        )
        self.env = dict(os.environ, PHASE2_BRINGUP_DIR=str(self.state),
                        CLUSTER_VALIDATION_ENV=str(self.cluster),
                        POST_BRINGUP_MIGRATION_ENV=str(self.migration),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        TEST_NATIVE_STATUS=self.healthy, DP_PHASE2_FAKE_K8S="test-only",
                        PHASE2_BRINGUP_ALLOW_NONROOT="1")
        self.write_receipts()

    def write_receipts(self, run="current", migration="PASS", cluster="PASS"):
        self.cluster.write_text(
            f"BRINGUP_RUN_ID={run}\nBRINGUP_TARGET_VERSION=6.6.0\n"
            f"CLUSTER_VALIDATION={cluster}\n"
        )
        self.migration.write_text(
            f"BRINGUP_RUN_ID={run}\nSOURCE_DP_VERSION=6.2.1\nTARGET_DP_VERSION=6.6.0\n"
            f"POST_BRINGUP_MIGRATION={migration}\nREQUIRED_POST_BRINGUP_ACTION=NO\n"
        )

    def bash(self, body, success=True):
        script = f'set -euo pipefail\nsource "{LIFECYCLE}"\n' + body
        result = subprocess.run(["bash", "-c", script], env=self.env,
                                text=True, capture_output=True, timeout=20)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def wrapper(self, *args):
        result = subprocess.run(["bash", str(WRAPPER), *args], env=self.env,
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def append(self, text):
        with self.log.open("a") as out:
            out.write(text + "\n")

    def test_all_vendor_phases_replace_image_complete(self):
        cases = {
            "Install Kubernetes 1.31": ("KUBERNETES", "install_kubernetes"),
            "Install Helm 3.17": ("HELM", "install_helm"),
            "Install UVP Package": ("UVP", "install_uvp"),
            "System Preparation": ("SYSTEM_PREPARATION", "prepare_system"),
            "Start Aella Systemd Services": ("SERVICES", "start_services"),
            "Initialize Kubernetes Master": ("KUBERNETES", "initialize_master"),
            "Deploy K8s Services": ("KUBERNETES", "deploy_services"),
            "Comprehensive Validation": ("VALIDATION", "validate_host"),
            "Orchestrate Worker Nodes": ("WORKER_DEPLOYMENT", "orchestrate_workers"),
            "Join K8s Cluster (Worker)": ("WORKER_JOIN", "join_cluster"),
            "Wait for aella_cli show status -> All pods are running": ("SERVICE_READINESS", "wait_for_services"),
        }
        for phase, expected in cases.items():
            with self.subTest(phase=phase):
                self.append("IMAGE_IMPORT_COMPLETE namespace=moby elapsed=30")
                self.append(f"[2026-10-30 01:00:00] PHASE: {phase}")
                out = self.bash('p2b_current_phase_from_log "$1"; echo "$CURRENT_PHASE/$CURRENT_OPERATION/$CURRENT_TARGET"'.replace('"$1"', f'"{self.log}"')).stdout
                self.assertEqual(out.strip(), "/".join((*expected, "LOCAL")))

    def test_log_references_do_not_replace_real_phase(self):
        self.append("[date] PHASE: Wait for aella_cli show status -> All pods are running")
        self.append("[date] Check load_local_images output earlier in this log.")
        out = self.wrapper("--status")
        self.assertIn("CURRENT_PHASE=SERVICE_READINESS\n", out)

    def test_end_failure_is_never_displayed_as_complete(self):
        self.append("IMAGE_IMPORT_END namespace=moby rc=17")
        out = self.wrapper("--status")
        self.assertIn("CURRENT_PHASE=IMAGE_IMPORT_FAILED\n", out)
        self.assertIn("namespace=moby result=FAIL exit_code=17", out)

    def test_wrong_target_or_failed_run_never_completes(self):
        self.cluster.write_text("BRINGUP_RUN_ID=current\nBRINGUP_TARGET_VERSION=6.5.0\nCLUSTER_VALIDATION=PASS\n")
        self.assertIn("DP_UPGRADE_COMPLETE=NO\n", self.wrapper("--validate-cluster"))
        self.write_receipts()
        (self.state / "state").write_text("FAILED\n")
        self.assertIn("DP_UPGRADE_COMPLETE=NO\n", self.wrapper("--validate-cluster"))

    def test_worker_target_and_master_return(self):
        self.append("--- Deploying worker: 192.168.12.26 ---")
        self.append("[date] [192.168.12.26] [date] PHASE: Install UVP Package")
        out = self.wrapper("--status")
        self.assertIn("CURRENT_TARGET=192.168.12.26\n", out)
        self.assertIn("CURRENT_PHASE=UVP\n", out)
        self.append("[date] PHASE: Wait for aella_cli show status -> All pods are running")
        self.assertIn("CURRENT_TARGET=LOCAL\n", self.wrapper("--status"))

    def test_namespace_outcomes_and_failure_are_explicit(self):
        self.append("IMAGE_IMPORT_PROGRESS namespace=k8s.io progress=99%")
        self.append("IMAGE_IMPORT_COMPLETE namespace=k8s.io elapsed=30")
        self.append("IMAGE_IMPORT_START namespace=moby")
        self.append("IMAGE_IMPORT_FAILED namespace=moby rc=17")
        out = self.wrapper("--status")
        self.assertIn("IMAGE_IMPORT_RESULT target=LOCAL namespace=k8s.io result=PASS exit_code=0\n", out)
        self.assertIn("IMAGE_IMPORT_RESULT target=LOCAL namespace=moby result=FAIL exit_code=17\n", out)
        self.assertIn("IMAGE_IMPORT_STATE=FAILED\n", out)
        self.assertNotIn("progress=100%", out)

    def test_worker_namespace_does_not_replace_master_outcome(self):
        self.append("IMAGE_IMPORT_COMPLETE namespace=moby")
        self.append("[date] [192.168.12.26] IMAGE_IMPORT_FAILED namespace=moby rc=23")
        out = self.wrapper("--status")
        self.assertIn("target=LOCAL namespace=moby result=PASS", out)
        self.assertIn("target=192.168.12.26 namespace=moby result=FAIL", out)

    def test_unknown_cpu_and_end_are_never_success_or_progress(self):
        self.append("IMAGE_IMPORT_PROGRESS namespace=k8s.io progress=81%")
        self.append("IMAGE_IMPORT_START namespace=moby")
        self.append("IMAGE_IMPORT_PROGRESS namespace=moby progress=UNKNOWN cpu=37.5%")
        out = self.wrapper("--status")
        self.assertIn("IMAGE_IMPORT_PROGRESS=\n", out)
        self.append("IMAGE_IMPORT_END namespace=moby")
        self.assertIn("namespace=moby result=UNKNOWN exit_code=UNKNOWN", self.wrapper("--status"))

    def test_stale_or_rotated_log_does_not_leak_old_success(self):
        self.log.write_text("IMAGE_IMPORT_COMPLETE namespace=moby\nPHASE: Install UVP Package\n")
        out = self.wrapper("--status")
        self.assertIn("CURRENT_PHASE=UNKNOWN\n", out)
        self.assertNotIn("IMAGE_IMPORT_RESULT ", out)

    def test_readonly_surface_reflects_valid_current_confirmations(self):
        before = (self.cluster.read_bytes(), self.migration.read_bytes())
        out = self.wrapper("--validate-cluster")
        self.assertIn("CLUSTER_RUNTIME_READINESS=READY\n", out)
        self.assertIn("CLUSTER_VALIDATION=PASS\n", out)
        self.assertIn("DP_UPGRADE_COMPLETE=YES\n", out)
        self.assertNotIn("CLUSTER_VALIDATION=PENDING\n", out)
        self.assertEqual(before, (self.cluster.read_bytes(), self.migration.read_bytes()))

    def test_live_health_never_auto_records_missing_or_stale_confirmation(self):
        for stale in (False, True):
            with self.subTest(stale=stale):
                self.write_receipts(run="old" if stale else "current")
                if not stale:
                    self.cluster.unlink()
                out = self.wrapper("--validate-cluster")
                self.assertIn("CLUSTER_RUNTIME_READINESS=READY\n", out)
                self.assertIn("CLUSTER_VALIDATION=PENDING\n", out)
                self.assertIn("DP_UPGRADE_COMPLETE=NO\n", out)
                if not stale:
                    self.assertFalse(self.cluster.exists())

    def test_required_or_failed_migration_never_completes(self):
        for migration in ("REQUIRED", "FAIL"):
            with self.subTest(migration=migration):
                self.write_receipts(migration=migration)
                self.assertIn("DP_UPGRADE_COMPLETE=NO\n", self.wrapper("--validate-cluster"))

    def test_paused_or_unhealthy_status_cannot_replay_confirmation(self):
        for native in (self.healthy + "System paused. Type resume in cli to start data processor services",
                       self.healthy + "License is invalid", "DataProcessor(DL-master)> System Ready"):
            with self.subTest(native=native):
                self.env["TEST_NATIVE_STATUS"] = native
                before = self.cluster.read_bytes()
                out = self.wrapper("--validate-cluster")
                self.assertIn("DP_UPGRADE_COMPLETE=NO\n", out)
                self.assertNotIn("CLUSTER_VALIDATION=PASS\n", out)
                self.assertEqual(before, self.cluster.read_bytes())

    def test_failed_confirmation_remains_visible_when_runtime_is_unhealthy(self):
        self.write_receipts(cluster="FAIL")
        self.env["TEST_NATIVE_STATUS"] = "DataProcessor(DL-master)> System paused. Type resume"
        out = self.wrapper("--validate-cluster")
        self.assertIn("CLUSTER_VALIDATION=FAIL\n", out)
        self.assertIn("DP_UPGRADE_COMPLETE=NO\n", out)

    def test_terminal_monitor_uses_receipts_without_overwriting_them(self):
        out = self.bash(
            f'source "{ROOT}/client/lib/dp-phase2-post-bringup-migration.sh"\n'
            f'source "{ROOT}/client/lib/dp-phase2-cluster-validation.sh"\n'
            'p2b_monitor_loop current\n'
        ).stdout
        self.assertIn("DP_UPGRADE_COMPLETE=YES\n", out)
        self.assertNotIn("DP_UPGRADE_COMPLETE=NO\n", out)
        self.assertNotIn("CLUSTER_VALIDATION=PENDING\n", out)

    def test_completed_reentry_does_not_restart_or_overwrite_completion(self):
        vendor = self.base / "must-not-run-vendor.sh"
        sentinel = self.base / "vendor-executed"
        vendor.write_text(f'#!/usr/bin/env bash\ntouch "{sentinel}"\nexit 99\n')
        self.env["BRINGUP_VENDOR_SCRIPT"] = str(vendor)
        before = (self.state / "result.env").read_bytes()
        out = self.wrapper("--version", "6.6.0", "--skip-download")
        self.assertIn("BRINGUP_ALREADY_COMPLETED=YES\n", out)
        self.assertIn("DP_UPGRADE_COMPLETE=YES\n", out)
        self.assertNotIn("CLUSTER_VALIDATION=PENDING\n", out)
        self.assertNotIn("DP_UPGRADE_COMPLETE=NO\n", out)
        self.assertFalse(sentinel.exists())
        self.assertEqual(before, (self.state / "result.env").read_bytes())

    def test_compact_heartbeat_shows_quiet_children_and_process_scope(self):
        # Deterministic monitor clock/snapshot, real formatter and loop. No DP
        # worker is launched. A terminal failure ends the third observation.
        os.utime(self.log, (1, 1))
        body = r'''
count=0
p2b_status_snapshot() {
  count=$((count+1))
  BRINGUP_RUN_ID=current; BRINGUP_WORKER_PID=123
  BRINGUP_WORKER_ALIVE=YES; BRINGUP_PROCESS_IDENTITY_MATCH=YES
  BRINGUP_ELAPSED_SECONDS=$((count*30))
  CURRENT_PHASE=UVP; CURRENT_OPERATION=install_uvp; CURRENT_TARGET=192.168.12.26
  BRINGUP_STATE=RUNNING
  if [[ "$count" -eq 3 ]]; then BRINGUP_STATE=FAILED; fi
  BRINGUP_COMPLETION_SENTINEL=FAIL; BRINGUP_EXIT_CODE=17
}
p2b_child_process_names() { echo dpkg; }
sleep() { :; }
p2b_monitor_loop current
'''
        out = self.bash(body, success=False)
        self.assertEqual(out.returncode, 1, out.stderr)
        self.assertEqual(out.stdout.count("BRINGUP_RESULT=IN_PROGRESS\n"), 1)
        self.assertEqual(out.stdout.count("state=RUNNING"), 2)
        self.assertIn("worker_scope=LIFECYCLE_PROCESS", out.stdout)
        self.assertIn("dp_worker_readiness=NOT_CHECKED", out.stdout)
        self.assertIn("target=192.168.12.26", out.stdout)
        self.assertIn("log_activity=QUIET", out.stdout)
        self.assertIn("child_processes=dpkg", out.stdout)
        self.assertIn("BRINGUP_RESULT=FAIL\n", out.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
