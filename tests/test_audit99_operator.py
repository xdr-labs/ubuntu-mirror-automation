"""Operator/configuration/recovery regressions in isolated temporary roots."""
import fcntl
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class OperatorBoundaries(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="audit99-operator-")
        self.p = Path(self.tmp.name)
        for name in ("config", "metadata", "logs", "data", "lifecycle"):
            (self.p / name).mkdir()
        manager = (ROOT / "scripts/install-dp-upgrade-mirror.sh").read_text()
        manager = re.sub(r"(?m)^SCRIPT_DIR=.*$", 'SCRIPT_DIR="' + str(ROOT / "scripts") + '"', manager)
        manager = manager.replace('\nmain "$@"\n', '\n')
        (self.p / "manager-lib.sh").write_text(manager)
        self.env = dict(os.environ)
        self.env.update(
            CASE_ROOT=str(self.p), AUDIT_ROOT=str(ROOT), MM_PROJECT_ROOT=str(ROOT),
            MM_CONFIG_DIR=str(self.p / "metadata"), MM_CONFIG_FILE=str(self.p / "config/gui.conf"),
            MM_STATUS_FILE=str(self.p / "metadata/status"), MM_WORKFLOW_FILE=str(self.p / "metadata/workflow"),
            MM_LOG_DIR=str(self.p / "logs"), MM_MIRROR_ROOT=str(self.p / "data"),
            MM_STATE_ROOT=str(self.p / "states"), MM_LOCK_FILE=str(self.p / "publication.lock"),
            MM_HERMETIC_TEST_MODE="1", SKIP_MIRROR_HOST_VALIDATE="1",
            PHASE2_BRINGUP_DIR=str(self.p / "lifecycle"), DP_PHASE2_STAGE_LIB_ONLY="1",
            PHASE2_STAGING_CONTRACT_ENV=str(self.p / "lifecycle/staging-result.env"))
        (self.p / "config/gui.conf").write_text(
            "PREPARATION_MODE=PHASE2_ONLY\nMIRROR_SERVER_IP=192.0.2.10\nMIRROR_HTTP_URL=http://192.0.2.10\n"
            "DL_WORKER_IPS=192.0.2.21\nDA_WORKER_IPS=\nWORKER_SSH_PASSWORD=synthetic-legacy-only\n")

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, body, timeout=50):
        q = subprocess.run(["bash", "-c", "set -euo pipefail\n" + body],
                           cwd=ROOT, env=self.env, capture_output=True, text=True, timeout=timeout)
        return q

    def gui_setup(self):
        return r'''
source "$CASE_ROOT/manager-lib.sh"
load_mirror_defaults() { :; }
mirror_host_suggest_primary_ipv4() { printf '192.0.2.10\n'; }
mirror_host_validate_ipv4_on_host() { return 0; }
mm_whiptail_input() { printf '192.0.2.20\n'; }
mm_whiptail_msg() { printf 'DIALOG %s\n%s\n' "$1" "$2"; }
mm_whiptail_menu() {
  local n; n=$(cat "$CASE_ROOT/counter"); n=$((n+1)); echo "$n" >"$CASE_ROOT/counter"
  case "$n" in 1) echo 2;; 2) echo 6;; *) echo 0;; esac
}
echo 0 >"$CASE_ROOT/counter"
'''

    def test_gui_saves_workers_without_password_and_purges_legacy_secret(self):
        q = self.run_script(self.gui_setup() + '\ngui_run_action Configuration gui_configuration\n')
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
        text = (self.p / "config/gui.conf").read_text()
        self.assertIn("MIRROR_SERVER_IP=192.0.2.20", text)
        self.assertIn("DL_WORKER_IPS=192.0.2.21", text)
        self.assertNotIn("WORKER_SSH_PASSWORD", text)
        self.assertNotIn("synthetic-legacy-only", q.stdout + q.stderr + text)
        self.assertIn("CONFIGURATION_SAVED=PASS", q.stdout)
        source = (ROOT / "scripts/install-dp-upgrade-mirror.sh").read_text()
        self.assertNotIn('"Worker SSH Password (aella)"', source)
        self.assertNotIn("mm_whiptail_password()", source)

    def test_gui_failed_config_replace_cannot_report_success(self):
        before = (self.p / "config/gui.conf").read_bytes()
        q = self.run_script(self.gui_setup() + r'''
mv() {
  if [[ "${@: -1}" == "$MM_CONFIG_FILE" ]]; then echo 'fixture replace failure' >&2; return 73; fi
  command mv "$@"
}
gui_run_action Configuration gui_configuration
''')
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)  # menu remains usable
        self.assertNotIn("CONFIGURATION_SAVED=PASS", q.stdout)
        self.assertIn("CONFIGURATION_SAVED=NO", q.stdout)
        self.assertEqual((self.p / "config/gui.conf").read_bytes(), before)
        self.assertEqual(list((self.p / "config").glob(".config.*")), [])

    def test_failed_workflow_write_restores_config_and_existing_guidance(self):
        q = self.run_script(self.gui_setup() + r'''
mm_load_gui_config
mm_save_gui_config_full >/dev/null
cp "$MM_CONFIG_FILE" "$CASE_ROOT/config.before"
cp "$MM_WORKFLOW_FILE" "$CASE_ROOT/workflow.before"
cmd_file="$(mm_client_commands_file)"
printf 'prior guidance\n' >"$cmd_file"
eval "$(declare -f mm_wf_atomic_write_file | sed '1s/mm_wf_atomic_write_file/_audit_real_wf_write/')"
mm_wf_atomic_write_file() {
  if [[ ! -f "$CASE_ROOT/injected" ]]; then : >"$CASE_ROOT/injected"; return 74; fi
  _audit_real_wf_write "$@"
}
gui_run_action Configuration gui_configuration
cmp "$MM_CONFIG_FILE" "$CASE_ROOT/config.before"
cmp "$MM_WORKFLOW_FILE" "$CASE_ROOT/workflow.before"
grep -qx 'prior guidance' "$cmd_file"
''')
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
        self.assertNotIn("CONFIGURATION_SAVED=PASS", q.stdout)
        self.assertIn("CONFIGURATION_SAVED=NO", q.stdout)

    def test_gui_validation_receipt_failure_rolls_back_all_stores(self):
        q = self.run_script(self.gui_setup() + r'''
mm_load_gui_config
mm_save_gui_config_full >/dev/null
cp "$MM_CONFIG_FILE" "$CASE_ROOT/config.before"
cp "$MM_WORKFLOW_FILE" "$CASE_ROOT/workflow.before"
cp "$MM_STATUS_FILE" "$CASE_ROOT/status.before"
eval "$(declare -f mm_status_set | sed '1s/mm_status_set/_audit_real_status_set/')"
mm_status_set() {
  if [[ "$1" == CONFIGURATION_READY ]]; then return 75; fi
  _audit_real_status_set "$@"
}
gui_run_action Configuration gui_configuration
cmp "$MM_CONFIG_FILE" "$CASE_ROOT/config.before"
cmp "$MM_WORKFLOW_FILE" "$CASE_ROOT/workflow.before"
cmp "$MM_STATUS_FILE" "$CASE_ROOT/status.before"
''')
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)
        self.assertNotIn("CONFIGURATION_SAVED=PASS", q.stdout)
        self.assertIn("CONFIGURATION_SAVED=NO", q.stdout)

    def test_retired_password_has_no_identity_or_loaded_value(self):
        q = self.run_script(self.gui_setup() + r'''
mm_load_gui_config
test -z "${WORKER_SSH_PASSWORD:-}"
WORKER_SSH_PASSWORD=ignored-first
first="$(mm_wf_command_identity_sha256)"
WORKER_SSH_PASSWORD=ignored-second
test "$first" = "$(mm_wf_command_identity_sha256)"
mm_save_gui_config_full >/dev/null
! grep -q 'WORKER_SSH_PASSWORD' "$MM_CONFIG_FILE"
test -z "${WORKER_SSH_PASSWORD:-}"
''')
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)

    def test_recovery_is_excluded_while_consumer_holds_lock(self):
        for held in (True, False):
            with self.subTest(held=held):
                live = self.p / "artifacts"
                backup = self.p / "artifacts.bak.prior"
                live.mkdir(exist_ok=True); backup.mkdir(exist_ok=True)
                (live / "marker").write_text("LIVE")
                (backup / "marker").write_text("BACKUP")
                with (self.p / "lifecycle/artifact-consumer.lock").open("a") as lock:
                    if held:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    q = self.run_script(r'''
source "$AUDIT_ROOT/client/stage-dp-phase2.sh"
ARTIFACT_DIR="$CASE_ROOT/artifacts"
require_root() { :; }
require_noble() { :; }
os_release_field() { echo '24.04'; }
eval "$(declare -f acquire_stage_lock | sed '1s/acquire_stage_lock/_audit_acquire_stage_lock/')"
acquire_stage_lock() { CACHE_DIR="$CASE_ROOT/cache"; _audit_acquire_stage_lock; }
# Stop before any downloads, package operations or installation.
require_space() { exit 71; }
stage_main --target-version 6.6.0 --mirror-url http://192.0.2.10
''')
                if held:
                    self.assertNotEqual(q.returncode, 0)
                    self.assertNotEqual(q.returncode, 71, q.stdout + q.stderr)
                    self.assertIn("STAGE_MUTATION_ALLOWED=NO", q.stdout)
                    self.assertEqual((live / "marker").read_text(), "LIVE")
                    self.assertTrue(backup.exists())
                else:
                    self.assertEqual(q.returncode, 71, q.stdout + q.stderr)
                    self.assertEqual((live / "marker").read_text(), "BACKUP")
                    self.assertFalse(backup.exists())

    def test_custom_install_paths_survive_public_entrypoint_reopen(self):
        q = self.run_script(r'''
CASE="$CASE_ROOT/custom install"
mkdir -p "$CASE"
export UM_PROJECT_ROOT="$AUDIT_ROOT"
source "$AUDIT_ROOT/lib/common.sh"
source "$AUDIT_ROOT/lib/config.sh"
source "$AUDIT_ROOT/lib/bootstrap.sh"
cat >"$CASE/custom.conf" <<EOF
BASE_PATH="$CASE/data"
SELECTIVE_MIRROR_ROOT="$CASE/data/selective"
DP_PHASE2_ROOT="$CASE/data/dp-phase2"
INSTALL_LIB_DIR="$CASE/runtime"
INSTALL_BIN_DIR="$CASE/bin"
INSTALL_CONF_DIR="$CASE/etc"
LOG_DIR="$CASE/logs"
BACKUP_DIR="$CASE/backups"
EOF
um_load_config "$CASE/custom.conf"
export UM_UOM_INSTALL_PATH="$CASE/sbin/ubuntu-offline-mirror.sh" UM_DRY_RUN=0
um_bootstrap_deploy_client_http_artifacts() { :; }
um_bootstrap_install_runtime
bash -c 'source "$1"; test "$BASE_PATH" = "$2/data"; test "$INSTALL_LIB_DIR" = "$2/runtime"' _ "$CASE/etc/mirror.conf" "$CASE"
cat >"$CASE/observe.sh" <<'OBS'
#!/bin/bash
printf 'OBS_ROOT=%s\nOBS_CONFIG=%s\n' "$MM_MIRROR_ROOT" "$MM_CONFIG_DIR"
OBS
# Harmless core observer: tests actual installed entrypoint config binding,
# never services, HTTP publication, package installation or a real DP.
env -i PATH=/usr/bin:/bin HOME="$CASE" UOM_CORE_ENTRY="$CASE/observe.sh" \
  "$CASE/bin/ubuntu-offline-mirror" diagnose-mirror-runtime >"$CASE/reopen.out"
grep -Fx "OBS_ROOT=$CASE/data" "$CASE/reopen.out"
grep -Fx "OBS_CONFIG=$CASE/etc" "$CASE/reopen.out"
''', timeout=100)
        self.assertEqual(q.returncode, 0, q.stdout + q.stderr)


if __name__ == "__main__":
    unittest.main()
