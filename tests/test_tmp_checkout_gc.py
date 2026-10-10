#!/usr/bin/env python3
"""Temporary-checkout GC integration tests: only synthetic /tmp fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/tmp-checkout-gc.py"


def git(*args, cwd=None):
    proc = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True)
    return proc.stdout.strip()


class SafeTempCheckoutGCTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="um-gc-test-", dir="/tmp")
        self.state = tempfile.TemporaryDirectory(prefix="um-gc-state-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.state.cleanup)
        self.root = Path(self.tmp.name)
        self.registry = Path(self.state.name) / "registry"
        self.env = os.environ.copy()
        self.env.update(UM_TMP_GC_TESTING="1", UM_TMP_GC_TEST_ROOT=str(self.root),
                        UM_TMP_GC_TEST_STATE=str(self.registry))
        self.remote = Path(self.state.name) / "origin.git"
        git("init", "-q", "--bare", str(self.remote))
        self.seed = Path(self.state.name) / "seed"
        git("init", "-q", "-b", "main", str(self.seed))
        git("config", "user.name", "Temp Checkout GC Test", cwd=self.seed)
        git("config", "user.email", "test@example.invalid", cwd=self.seed)
        (self.seed / "README.md").write_text("source\n")
        git("add", "README.md", cwd=self.seed)
        git("commit", "-q", "-m", "seed", cwd=self.seed)
        git("remote", "add", "origin", str(self.remote), cwd=self.seed)
        git("push", "-q", "-u", "origin", "main", cwd=self.seed)
        git("--git-dir", str(self.remote), "symbolic-ref", "HEAD", "refs/heads/main")

    def run_gc(self, *args, env=None):
        return subprocess.run([sys.executable, str(SCRIPT), *args],
                              env=self.env if env is None else env,
                              text=True, capture_output=True, timeout=30)

    def clone(self, name="um-test-clone"):
        dest = self.root / name
        git("clone", "-q", str(self.remote), str(dest))
        self.assertEqual(git("status", "--porcelain", cwd=dest), "")
        return dest

    def register(self, path):
        result = self.run_gc("register", str(path))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("REGISTERED", result.stdout)

    def test_default_mode_never_deletes_unregistered_git_checkouts(self):
        existing = self.clone("old-unmanaged")
        self.assertEqual(self.run_gc("prune", "--apply").returncode, 0)
        self.assertTrue(existing.exists())
        self.assertIn("managed=0", self.run_gc("status").stdout)

    def test_registered_clean_checkout_only_dry_runs_until_apply(self):
        target = self.clone()
        self.register(target)
        dry = self.run_gc("prune")
        self.assertIn("READY", dry.stdout)
        self.assertTrue(target.exists())
        prune = self.run_gc("prune", "--apply")
        self.assertEqual(prune.returncode, 0, prune.stderr)
        self.assertIn("removed=1", prune.stdout)
        self.assertFalse(target.exists())
        self.assertIn("managed=0", self.run_gc("status").stdout)

    def test_dirty_untracked_and_ignored_content_blocks_deletion(self):
        target = self.clone()
        self.register(target)
        (target / "untracked.txt").write_text("save me")
        result = self.run_gc("prune", "--apply")
        self.assertIn("dirty_or_untracked_files", result.stdout)
        self.assertTrue(target.exists())
        (target / "untracked.txt").unlink()
        (target / ".gitignore").write_text("private.txt\n")
        git("add", ".gitignore", cwd=target)
        # An uncommitted staged .gitignore must never be deleted.
        self.assertIn("preserved=1", self.run_gc("prune", "--apply").stdout)

    def test_ignored_generated_file_blocks_deletion(self):
        target = self.clone()
        # The ignored pattern is committed to the source before cloning.
        self.assertEqual(self.run_gc("register", str(target)).returncode, 0)
        (target / ".cache").mkdir()
        (target / ".cache" / "data").write_text("protected temporary data")
        # .cache isn't yet ignored, so validate with the committed .git/info/exclude.
        with (target / ".git/info/exclude").open("a") as fh:
            fh.write("\n.cache/\n")
        result = self.run_gc("prune", "--apply")
        self.assertIn("ignored_files_present", result.stdout)
        self.assertTrue(target.exists())

    def test_changed_head_and_unpushed_commit_block_deletion(self):
        target = self.clone()
        self.register(target)
        git("config", "user.name", "Temp Checkout GC Test", cwd=target)
        git("config", "user.email", "test@example.invalid", cwd=target)
        (target / "README.md").write_text("new work\n")
        git("add", "README.md", cwd=target)
        git("commit", "-q", "-m", "unpublished", cwd=target)
        result = self.run_gc("prune", "--apply")
        self.assertIn("local_commit_not_in_remote_tracking", result.stdout)
        self.assertTrue(target.exists())

    def test_active_process_cwd_and_open_fd_block_deletion(self):
        target = self.clone()
        self.register(target)
        active = subprocess.Popen(["sleep", "30"], cwd=target)
        try:
            outcome = self.run_gc("prune", "--apply")
            self.assertIn("process_cwd_reference", outcome.stdout)
            self.assertTrue(target.exists())
        finally:
            active.terminate()
            active.wait(timeout=3)
        with (target / "README.md").open("rb") as fh:
            self.assertEqual(fh.read(), b"source\n")
            outcome = self.run_gc("prune", "--apply")
            self.assertIn("process_fd_reference", outcome.stdout)
            self.assertTrue(target.exists())
        self.assertIn("removed=1", self.run_gc("prune", "--apply").stdout)

    def test_linked_git_worktree_and_symlink_are_not_registerable(self):
        other = self.seed / "linked"
        git("worktree", "add", "-q", "-b", "testworktree", str(other), cwd=self.seed)
        self.addCleanup(lambda: subprocess.run(
            ["git", "-C", str(self.seed), "worktree", "remove", "--force", str(other)],
            capture_output=True))
        linked = self.root / "linked"
        linked.symlink_to(other, target_is_directory=True)
        self.assertNotEqual(self.run_gc("register", str(linked)).returncode, 0)
        self.assertTrue(other.exists())
        self.assertTrue(linked.is_symlink())

    def test_checkout_directory_replacement_cannot_be_deleted(self):
        target = self.clone()
        self.register(target)
        old = self.root / "old-checkout"
        target.rename(old)
        replacement = self.clone()
        self.assertEqual(replacement, target)
        result = self.run_gc("prune", "--apply")
        self.assertIn("checkout_replaced", result.stdout)
        self.assertTrue(target.exists())
        self.assertTrue(old.exists())

    def test_test_mode_cannot_bypass_real_tmp_cleanup_scope(self):
        e = self.env.copy()
        e["UM_TMP_GC_TEST_ROOT"] = "/tmp"
        self.assertNotEqual(self.run_gc("status", env=e).returncode, 0)
        self.assertIn("test_scope_must_be_isolated", self.run_gc("status", env=e).stderr)

    def test_register_and_unregister_preserves_checkout(self):
        target = self.clone()
        self.register(target)
        r = self.run_gc("unregister", str(target))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("checkout_preserved=yes", r.stdout)
        self.assertTrue(target.exists())

    def test_cron_installer_preserves_other_jobs_and_is_idempotent(self):
        # The installer uses a real per-user HOME, not the GC fixture root.
        # Keep it outside /tmp so its durable registry is out of prune scope.
        isolated_home = tempfile.TemporaryDirectory(
            prefix="um-gc-installer-home-", dir=str(Path.home())
        )
        self.addCleanup(isolated_home.cleanup)
        fake_home = Path(isolated_home.name)
        fake_bin = fake_home / "bin"
        fake_bin.mkdir()
        fake_crontab = fake_home / ".crontab-fixture"
        old_job = "10 7 * * * /usr/bin/true"
        fake_crontab.write_text(old_job + "\n")
        fake = fake_bin / "crontab"
        fake.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "if [[ \"$1\" == \"-l\" ]]; then\n"
            "  cat \"$HOME/.crontab-fixture\"\n"
            "else\n"
            "  cp \"$1\" \"$HOME/.crontab-fixture\"\n"
            "fi\n"
        )
        fake.chmod(0o755)
        env = os.environ.copy()
        env["HOME"] = str(fake_home)
        env["PATH"] = str(fake_bin) + ":" + env.get("PATH", "")
        installer = str(ROOT / "scripts/install-tmp-checkout-gc.sh")
        for _ in range(2):
            proc = subprocess.run(["bash", installer, "--install"], env=env,
                                  text=True, capture_output=True, timeout=30)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        content = fake_crontab.read_text()
        self.assertEqual(content.count("BEGIN ubuntu-mirror-automation tmp-checkout-gc"), 1)
        self.assertEqual(content.count("prune --apply"), 1)
        self.assertIn(old_job, content)
        installed = fake_home / ".local/lib/ubuntu-mirror-automation/tmp-checkout-gc.py"
        self.assertTrue(installed.is_file())
        shortcut = fake_home / ".local/bin/um-tmp-checkout"
        self.assertTrue(shortcut.is_symlink())
        self.assertEqual(shortcut.resolve(), installed)
        stop = subprocess.run(["bash", installer, "--disable"], env=env,
                              text=True, capture_output=True, timeout=30)
        self.assertEqual(stop.returncode, 0, stop.stdout + stop.stderr)
        self.assertIn(old_job, fake_crontab.read_text())
        self.assertNotIn("prune --apply", fake_crontab.read_text())

    def test_create_local_git_clone_registers_for_auto_cleanup(self):
        r = self.run_gc("create", "--source", str(self.seed))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        path = Path([l for l in r.stdout.splitlines() if l.startswith("CHECKOUT=")][0].split("=", 1)[1])
        self.assertTrue(path.is_dir())
        self.assertIn("REGISTERED", r.stdout)
        self.assertIn("removed=1", self.run_gc("prune", "--apply").stdout)
        self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
