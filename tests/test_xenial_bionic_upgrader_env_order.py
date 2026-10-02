#!/usr/bin/env python3
"""Xenial→Bionic glibc getenv/setenv ordering patch."""

from __future__ import print_function

import hashlib
import importlib.util
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE_PATH = os.path.join(ROOT, "scripts/lib/xenial_bionic_upgrader_env_order.py")
TEMPLATE = os.path.join(ROOT, "client/dp-offline-upgrade-xenial-to-bionic.sh.in")


def load_module():
    spec = importlib.util.spec_from_file_location("xenial_bionic_upgrader_env_order", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_tree(root, version, controller, entry_name="bionic", utils=None):
    os.makedirs(root)
    with open(os.path.join(root, "DistUpgradeVersion.py"), "w", encoding="utf-8") as fh:
        fh.write("VERSION = '%s'\n" % version)
    with open(os.path.join(root, "DistUpgradeController.py"), "w", encoding="utf-8") as fh:
        fh.write(controller)
    with open(os.path.join(root, entry_name), "w", encoding="utf-8") as fh:
        fh.write("#!/usr/bin/python3\nprint('ENTRY_OK')\n")
    if utils is not None:
        with open(os.path.join(root, "utils.py"), "w", encoding="utf-8") as fh:
            fh.write(utils)


class EnvOrderPatchTests(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()
        self.tmp = tempfile.mkdtemp(prefix="env-order-")
        self.addCleanup(shutil.rmtree, self.tmp)

    def _controller(self, block):
        return "class DistUpgradeController(object):\n    def __init__(self):\n" + block + "        check_and_fix_xbit()\n"

    def _utils(self):
        return self.mod.UNPATCHED_INHIBIT + "def str_to_bool(value):\n    return True\n"

    def test_patch_orders_env_before_inhibit_and_is_idempotent(self):
        root = os.path.join(self.tmp, "up")
        write_tree(
            root,
            "18.04.45",
            self._controller(self.mod.UNPATCHED_BLOCK),
            utils=self._utils(),
        )
        before = open(os.path.join(root, "DistUpgradeController.py"), encoding="utf-8").read()
        self.assertEqual(self.mod.patch_upgrader_tree(root), "patched")
        patched = open(os.path.join(root, "DistUpgradeController.py"), encoding="utf-8").read()
        self.assertNotEqual(before, patched)
        self.assertTrue(self.mod._assignments_precede_inhibit(patched))
        call = patched.find("self.inhibitor_fd = inhibit_sleep()")
        for name in ("RELEASE_UPGRADE_IN_PROGRESS", "PYCENTRAL_FORCE_OVERWRITE", "PATH"):
            self.assertLess(patched.find('os.environ["%s"]' % name), call)
        self.assertEqual(self.mod.patch_upgrader_tree(root), "already")
        again = open(os.path.join(root, "DistUpgradeController.py"), encoding="utf-8").read()
        self.assertEqual(patched, again)
        utils = open(os.path.join(root, "utils.py"), encoding="utf-8").read()
        self.assertIn(self.mod.PATCHED_INHIBIT, utils)
        self.assertFalse(self.mod.inhibit_starts_inprocess_gio(utils))
        self.assertTrue(self.mod.inhibit_is_out_of_process(utils))
        self.assertIn("def str_to_bool(value):", utils)

    def test_unexpected_signature_fails_closed_without_write(self):
        root = os.path.join(self.tmp, "bad")
        original = self._controller("        self.inhibitor_fd = inhibit_sleep()\n")
        write_tree(root, "18.04.45", original)
        with self.assertRaises(self.mod.UpgraderPatchError):
            self.mod.patch_upgrader_tree(root)
        got = open(os.path.join(root, "DistUpgradeController.py"), encoding="utf-8").read()
        self.assertEqual(got, original)

    def test_unrelated_version_is_not_modified(self):
        root = os.path.join(self.tmp, "focal")
        original = self._controller(self.mod.UNPATCHED_BLOCK)
        write_tree(root, "20.04.6", original, entry_name="focal")
        with self.assertRaises(self.mod.UpgraderPatchError):
            self.mod.patch_upgrader_tree(root)
        got = open(os.path.join(root, "DistUpgradeController.py"), encoding="utf-8").read()
        self.assertEqual(got, original)

    def test_sitecustomize_patches_only_bionic_entry(self):
        root = os.path.join(self.tmp, "live")
        write_tree(
            root,
            "18.04.45",
            self._controller(self.mod.UNPATCHED_BLOCK),
            utils=self._utils(),
        )
        hook = os.path.join(self.tmp, "hook")
        os.makedirs(hook)
        shutil.copy(MODULE_PATH, os.path.join(hook, "sitecustomize.py"))
        env = os.environ.copy()
        env["PYTHONPATH"] = hook
        env["STELLAR_XENIAL_BIONIC_ENV_ORDER_PATCH"] = "1"
        good = subprocess.run(
            [sys.executable, os.path.join(root, "bionic")],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(good.returncode, 0, good.stderr)
        self.assertIn("ENTRY_OK", good.stdout)
        self.assertIn("XENIAL_BIONIC_ENV_ORDER_PATCH=PATCHED", good.stderr)
        patched = open(os.path.join(root, "DistUpgradeController.py"), encoding="utf-8").read()
        self.assertIn(self.mod.PATCHED_BLOCK, patched)

        focal = os.path.join(self.tmp, "other")
        original = self._controller(self.mod.UNPATCHED_BLOCK)
        write_tree(focal, "18.04.45", original, entry_name="focal")
        skipped = subprocess.run(
            [sys.executable, os.path.join(focal, "focal")],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(skipped.returncode, 0, skipped.stderr)
        self.assertIn("ENTRY_OK", skipped.stdout)
        self.assertNotIn("XENIAL_BIONIC_ENV_ORDER_PATCH=FAIL", skipped.stderr)
        got = open(os.path.join(focal, "DistUpgradeController.py"), encoding="utf-8").read()
        self.assertEqual(got, original)

    def test_sitecustomize_bad_signature_exits_nonzero(self):
        root = os.path.join(self.tmp, "refuse")
        original = self._controller("        pass\n")
        write_tree(root, "18.04.45", original)
        hook = os.path.join(self.tmp, "hook2")
        os.makedirs(hook)
        shutil.copy(MODULE_PATH, os.path.join(hook, "sitecustomize.py"))
        env = os.environ.copy()
        env["PYTHONPATH"] = hook
        env["STELLAR_XENIAL_BIONIC_ENV_ORDER_PATCH"] = "1"
        bad = subprocess.run(
            [sys.executable, os.path.join(root, "bionic")],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(bad.returncode, 0)
        self.assertNotIn("ENTRY_OK", bad.stdout)
        self.assertIn("XENIAL_BIONIC_ENV_ORDER_PATCH=FAIL", bad.stderr)
        got = open(os.path.join(root, "DistUpgradeController.py"), encoding="utf-8").read()
        self.assertEqual(got, original)

    def test_later_env_writes_stay_and_inhibitor_is_out_of_process(self):
        later = (
            '        os.environ["RELEASE_UPGRADE_MODE"] = "server"\n'
            '        os.environ["TERM"] = "dumb"\n'
            '        os.environ["PAGER"] = "true"\n'
            '        os.environ["PYTHONPATH"] = "/usr/lib/release-upgrader-python-apt"\n'
        )
        root = os.path.join(self.tmp, "later")
        write_tree(
            root,
            "18.04.45",
            self._controller(self.mod.UNPATCHED_BLOCK + later),
            utils=self._utils(),
        )
        self.assertEqual(self.mod.patch_upgrader_tree(root), "patched")
        controller = open(os.path.join(root, "DistUpgradeController.py"), encoding="utf-8").read()
        utils = open(os.path.join(root, "utils.py"), encoding="utf-8").read()
        call = controller.find("self.inhibitor_fd = inhibit_sleep()")
        self.assertGreater(call, 0)
        for name in ("RELEASE_UPGRADE_IN_PROGRESS", "PYCENTRAL_FORCE_OVERWRITE", "PATH"):
            self.assertLess(controller.find('os.environ["%s"]' % name), call)
        for marker in self.mod._PINNED_LATER_ENV_MARKERS:
            if "RELEASE_UPGRADE_MODE" in marker and "desktop" in marker:
                continue
            self.assertIn(marker, controller)
            self.assertGreater(controller.find(marker), call)
        self.assertFalse(self.mod.inhibit_starts_inprocess_gio(utils))
        self.assertTrue(self.mod.inhibit_is_out_of_process(utils))
        self.assertNotIn("gi.repository", utils)

    def _v229_inhibit_bin(self, state_dir):
        bindir = os.path.join(self.tmp, "bin-" + os.path.basename(state_dir))
        os.makedirs(bindir)
        os.makedirs(state_dir)
        fake = os.path.join(bindir, "systemd-inhibit")
        with open(fake, "w", encoding="utf-8") as fh:
            fh.write("#!/bin/bash\n")
            fh.write("set -u\n")
            fh.write("state='" + state_dir + "'\n")
            fh.write('printf \'%s\\n\' "$*" > "$state/args"\n')
            fh.write('while [[ $# -gt 0 && "$1" != "sh" ]]; do shift; done\n')
            fh.write('echo $$ > "$state/parent.pid"\n')
            fh.write('"$@" &\n')
            fh.write('echo $! > "$state/child.pid"\n')
            fh.write("trap '' TERM\n")
            fh.write("wait $!\n")
            fh.write("exit $?\n")
        os.chmod(fake, 0o755)
        return bindir

    def _pids_gone(self, parent, child):
        for _ in range(50):
            parent_alive = parent > 0 and os.path.exists("/proc/%s" % parent)
            child_alive = child > 0 and os.path.exists("/proc/%s" % child)
            if not parent_alive and not child_alive:
                return True
            time.sleep(0.05)
        return False

    def test_v229_inhibit_close_reaps_parent_and_command(self):
        state = os.path.join(self.tmp, "v229-close")
        bindir = self._v229_inhibit_bin(state)
        old_path = os.environ.get("PATH", "")
        os.environ["PATH"] = bindir + os.pathsep + old_path
        ns = {"sys": sys}
        exec(self.mod.PATCHED_INHIBIT, ns)
        handle = None
        try:
            handle = ns["inhibit_sleep"]()
            self.assertNotEqual(handle, False)
            os.environ["RELEASE_UPGRADE_MODE"] = "server"
            os.environ["TERM"] = "dumb"
            os.environ["PAGER"] = "true"
            parent = int(open(os.path.join(state, "parent.pid"), encoding="utf-8").read())
            child = int(open(os.path.join(state, "child.pid"), encoding="utf-8").read())
            self.assertNotEqual(parent, child)
            args = open(os.path.join(state, "args"), encoding="utf-8").read()
            self.assertIn("--what=shutdown:sleep", args)
            self.assertIn("--mode=block", args)
        finally:
            if handle not in (None, False):
                handle.close()
            os.environ["PATH"] = old_path
        self.assertTrue(self._pids_gone(parent, child), "v229 command leaked after close")

    def test_v229_parent_loss_reaps_command_without_sigterm(self):
        state = os.path.join(self.tmp, "v229-loss")
        bindir = self._v229_inhibit_bin(state)
        holder = os.path.join(self.tmp, "holder.py")
        with open(holder, "w", encoding="utf-8") as fh:
            fh.write(
                "import os, sys, time\n"
                "import importlib.util\n"
                "spec = importlib.util.spec_from_file_location('m', sys.argv[1])\n"
                "mod = importlib.util.module_from_spec(spec)\n"
                "spec.loader.exec_module(mod)\n"
                "ns = {'sys': sys}\n"
                "exec(mod.PATCHED_INHIBIT, ns)\n"
                "handle = ns['inhibit_sleep']()\n"
                "open(sys.argv[2], 'w').write('HELD' if handle else 'FAIL')\n"
                "time.sleep(30)\n"
            )
        held = os.path.join(state, "held")
        env = os.environ.copy()
        env["PATH"] = bindir + os.pathsep + env.get("PATH", "")
        proc = subprocess.Popen(
            [sys.executable, holder, MODULE_PATH, held],
            env=env,
        )
        deadline = time.time() + 5
        while time.time() < deadline and not os.path.isfile(held):
            time.sleep(0.05)
        self.assertEqual(open(held, encoding="utf-8").read(), "HELD")
        parent = int(open(os.path.join(state, "parent.pid"), encoding="utf-8").read())
        child = int(open(os.path.join(state, "child.pid"), encoding="utf-8").read())
        os.kill(proc.pid, 9)
        proc.wait(timeout=5)
        self.assertTrue(self._pids_gone(parent, child), "v229 command leaked after parent loss")

    def test_inhibit_acquisition_failure_aborts_before_mutation(self):
        self.assertIn("XENIAL_BIONIC_SLEEP_INHIBIT=FAIL", self.mod.PATCHED_BLOCK)
        self.assertLess(
            self.mod.PATCHED_BLOCK.find("self.inhibitor_fd = inhibit_sleep()"),
            self.mod.PATCHED_BLOCK.find("raise SystemExit(1)"),
        )
        old_path = os.environ.get("PATH", "")
        os.environ["PATH"] = "/nonexistent"
        ns = {"sys": sys}
        try:
            exec(self.mod.PATCHED_INHIBIT, ns)
            self.assertIs(ns["inhibit_sleep"](), False)
        finally:
            os.environ["PATH"] = old_path
        src = (
            "inhibitor_fd = False\n"
            "if not inhibitor_fd:\n"
            "    sys.stderr.write('XENIAL_BIONIC_SLEEP_INHIBIT=FAIL\\n')\n"
            "    raise SystemExit(1)\n"
        )
        with self.assertRaises(SystemExit) as caught:
            exec(src, {"sys": sys})
        self.assertEqual(caught.exception.code, 1)

    def test_pinned_1845_tarball_inhibitor_patch(self):
        pin = "976b87d935f8aa2867fac161198812693e6bde6b8fc3fd84f9a7705f638b50a3"
        tar_path = "/var/spool/apt-mirror/selective/shared/offline/release-upgraders/bionic/bionic.tar.gz"
        if not os.path.isfile(tar_path):
            self.skipTest("pinned bionic tarball is not on this host")
        digest = hashlib.sha256()
        with open(tar_path, "rb") as fh:
            while True:
                chunk = fh.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
        self.assertEqual(digest.hexdigest(), pin)
        root = os.path.join(self.tmp, "pinned")
        os.makedirs(root)
        want = {
            "DistUpgradeController.py",
            "DistUpgradeVersion.py",
            "DistUpgradeViewNonInteractive.py",
            "utils.py",
            "bionic",
        }
        with tarfile.open(tar_path) as tar:
            chosen = []
            for member in tar.getmembers():
                base = os.path.basename(member.name)
                if base in want and member.isfile():
                    member.name = base
                    chosen.append(member)
            tar.extractall(root, members=chosen)
        before_view = open(
            os.path.join(root, "DistUpgradeViewNonInteractive.py"), "rb"
        ).read()
        self.assertEqual(self.mod.patch_upgrader_tree(root), "patched")
        controller = open(os.path.join(root, "DistUpgradeController.py"), encoding="utf-8").read()
        utils = open(os.path.join(root, "utils.py"), encoding="utf-8").read()
        view = open(os.path.join(root, "DistUpgradeViewNonInteractive.py"), "rb").read()
        self.assertEqual(view, before_view)
        self.assertTrue(self.mod._assignments_precede_inhibit(controller))
        self.assertIn('os.environ["RELEASE_UPGRADE_MODE"] = "server"', controller)
        self.assertIn('os.environ["TERM"] = "dumb"', view.decode("utf-8"))
        self.assertIn('os.environ["PAGER"] = "true"', view.decode("utf-8"))
        self.assertIn(
            'os.environ["PYTHONPATH"] = "/usr/lib/release-upgrader-python-apt"',
            controller,
        )
        self.assertNotIn("from gi.repository import Gio, GLib", utils)
        self.assertTrue(self.mod.inhibit_is_out_of_process(utils))
        self.assertFalse(self.mod.inhibit_starts_inprocess_gio(utils))
        self.assertEqual(self.mod.patch_upgrader_tree(root), "already")

    def test_oserror_during_replace_does_not_run_bionic_entry(self):
        root = os.path.join(self.tmp, "enospc")
        original = self._controller(self.mod.UNPATCHED_BLOCK)
        utils = self._utils()
        write_tree(root, "18.04.45", original, utils=utils)
        hook = os.path.join(self.tmp, "hook-enospc")
        os.makedirs(hook)
        text = open(MODULE_PATH, encoding="utf-8").read()
        needle = "\nmaybe_patch_running_upgrader()\n"
        inject = (
            "\n_orig_os_replace = os.replace\n"
            "def _fail_os_replace(src, dst):\n"
            "    raise OSError(28, 'No space left on device')\n"
            "os.replace = _fail_os_replace\n"
            "\nmaybe_patch_running_upgrader()\n"
        )
        self.assertIn(needle, text)
        self.assertNotIn("except BaseException", text)
        self.assertNotIn("except SystemExit", text)
        with open(os.path.join(hook, "sitecustomize.py"), "w", encoding="utf-8") as fh:
            fh.write(text.replace(needle, inject, 1))
        env = os.environ.copy()
        env["PYTHONPATH"] = hook
        env["STELLAR_XENIAL_BIONIC_ENV_ORDER_PATCH"] = "1"
        failed = subprocess.run(
            [sys.executable, os.path.join(root, "bionic")],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(failed.returncode, 1, failed.stderr)
        self.assertNotIn("ENTRY_OK", failed.stdout)
        self.assertIn("XENIAL_BIONIC_ENV_ORDER_PATCH=FAIL", failed.stderr)
        self.assertIn("No space left on device", failed.stderr)
        self.assertEqual(
            open(os.path.join(root, "DistUpgradeController.py"), encoding="utf-8").read(),
            original,
        )
        self.assertEqual(open(os.path.join(root, "utils.py"), encoding="utf-8").read(), utils)
        shutil.copy(MODULE_PATH, os.path.join(hook, "sitecustomize.py"))
        retried = subprocess.run(
            [sys.executable, os.path.join(root, "bionic")],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(retried.returncode, 0, retried.stderr)
        self.assertIn("ENTRY_OK", retried.stdout)
        self.assertIn("XENIAL_BIONIC_ENV_ORDER_PATCH=PATCHED", retried.stderr)
        again = subprocess.run(
            [sys.executable, os.path.join(root, "bionic")],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("ENTRY_OK", again.stdout)
        self.assertIn("XENIAL_BIONIC_ENV_ORDER_PATCH=ALREADY", again.stderr)

    def test_systemexit_from_patch_is_not_rewritten(self):
        root = os.path.join(self.tmp, "sysexit")
        write_tree(root, "18.04.45", self._controller(self.mod.UNPATCHED_BLOCK), utils=self._utils())
        old_argv = sys.argv
        old = os.environ.get("STELLAR_XENIAL_BIONIC_ENV_ORDER_PATCH")
        os.environ["STELLAR_XENIAL_BIONIC_ENV_ORDER_PATCH"] = "1"
        sys.argv = [os.path.join(root, "bionic")]

        def boom(_root):
            raise SystemExit(7)

        self.mod.patch_upgrader_tree = boom
        try:
            with self.assertRaises(SystemExit) as caught:
                self.mod.maybe_patch_running_upgrader()
            self.assertEqual(caught.exception.code, 7)
        finally:
            sys.argv = old_argv
            if old is None:
                os.environ.pop("STELLAR_XENIAL_BIONIC_ENV_ORDER_PATCH", None)
            else:
                os.environ["STELLAR_XENIAL_BIONIC_ENV_ORDER_PATCH"] = old

    def _install_function_text(self, body=None):
        text = open(TEMPLATE, encoding="utf-8").read()
        start = text.index("install_xenial_bionic_glibc_env_order_hook() {")
        end = text.index("\nsnapshot_pre_dro_package_state()", start)
        func = text[start:end]
        if body is not None:
            begin = "<<'XENIAL_BIONIC_ENV_ORDER_PY'\n"
            h0 = func.index(begin) + len(begin)
            h1 = func.index("\nXENIAL_BIONIC_ENV_ORDER_PY\n", h0)
            func = func[:h0] + body + func[h1:]
        return func

    def _run_install_then_spawn(self, func_text):
        state = os.path.join(self.tmp, "hook-install")
        os.makedirs(state)
        script = os.path.join(self.tmp, "install-driver.sh")
        with open(script, "w", encoding="utf-8") as fh:
            fh.write("#!/usr/bin/env bash\n")
            fh.write("set -euo pipefail\n")
            fh.write("STATE_ROOT='%s'\n" % state)
            fh.write("mark_release_upgrade_invocation_started() { echo MARK_INV >\"$STATE_ROOT/mark-inv\"; }\n")
            fh.write("mark_release_upgrade_process_spawned() { echo MARK_SPAWN >\"$STATE_ROOT/mark-spawn\"; }\n")
            fh.write("do-release-upgrade() { echo SPAWNED >\"$STATE_ROOT/dro\"; }\n")
            fh.write("fail_stage() { printf 'FAIL_STAGE:%s\\n' \"$2\"; exit 9; }\n")
            fh.write(func_text)
            fh.write("\n")
            fh.write("if ! install_xenial_bionic_glibc_env_order_hook; then\n")
            fh.write("  fail_stage 1 FAIL_XENIAL_BIONIC_ENV_ORDER_HOOK_INSTALL\n")
            fh.write("fi\n")
            fh.write("mark_release_upgrade_invocation_started\n")
            fh.write("mark_release_upgrade_process_spawned\n")
            fh.write("do-release-upgrade\n")
        os.chmod(script, 0o755)
        return subprocess.run(["bash", script], capture_output=True, text=True, check=False), state

    def test_malformed_hook_is_rejected_before_spawn(self):
        text = open(TEMPLATE, encoding="utf-8").read()
        spawn = text.index("\n  do-release-upgrade -f DistUpgradeViewNonInteractive\n")
        install_call = text.rfind("if ! install_xenial_bionic_glibc_env_order_hook; then", 0, spawn)
        mark_inv = text.rfind("\n  mark_release_upgrade_invocation_started\n", 0, spawn)
        mark_spawn = text.rfind("\n  mark_release_upgrade_process_spawned\n", 0, spawn)
        self.assertGreater(install_call, 0)
        self.assertLess(install_call, mark_inv)
        self.assertLess(mark_inv, mark_spawn)
        self.assertLess(mark_spawn, spawn)
        proc, state = self._run_install_then_spawn(self._install_function_text("def broken(:\n"))
        self.assertEqual(proc.returncode, 9, proc.stdout + proc.stderr)
        self.assertIn("FAIL_STAGE:FAIL_XENIAL_BIONIC_ENV_ORDER_HOOK_INSTALL", proc.stdout)
        self.assertFalse(os.path.exists(os.path.join(state, "mark-inv")))
        self.assertFalse(os.path.exists(os.path.join(state, "mark-spawn")))
        self.assertFalse(os.path.exists(os.path.join(state, "dro")))
        live = os.path.join(state, "upgrader-glibc-env-order", "sitecustomize.py")
        self.assertFalse(os.path.exists(live))
        leftovers = [
            name for name in os.listdir(os.path.join(state, "upgrader-glibc-env-order"))
            if name.startswith("sitecustomize.py.tmp.")
        ]
        self.assertEqual(leftovers, [])

    def test_valid_hook_install_syntax_checks_then_reaches_spawn(self):
        proc, state = self._run_install_then_spawn(self._install_function_text())
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertTrue(os.path.exists(os.path.join(state, "mark-inv")))
        self.assertTrue(os.path.exists(os.path.join(state, "mark-spawn")))
        self.assertTrue(os.path.exists(os.path.join(state, "dro")))
        live = os.path.join(state, "upgrader-glibc-env-order", "sitecustomize.py")
        parsed = subprocess.run(
            [sys.executable, "-c", "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())", live],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(parsed.returncode, 0, parsed.stderr)
        names = os.listdir(os.path.join(state, "upgrader-glibc-env-order"))
        self.assertEqual([name for name in names if name.startswith("sitecustomize.py.tmp.")], [])

    def test_client_embed_matches_module_and_other_hops_are_untouched(self):
        text = open(TEMPLATE, encoding="utf-8").read()
        begin = "<<'XENIAL_BIONIC_ENV_ORDER_PY'\n"
        start = text.index(begin) + len(begin)
        end = text.index("\nXENIAL_BIONIC_ENV_ORDER_PY\n", start)
        embedded = text[start:end] + "\n"
        module = open(MODULE_PATH, encoding="utf-8").read()
        self.assertEqual(embedded, module)
        self.assertIn("install_xenial_bionic_glibc_env_order_hook", text)
        self.assertLess(
            text.index("install_xenial_bionic_glibc_env_order_hook"),
            text.index("do-release-upgrade -f DistUpgradeViewNonInteractive"),
        )
        for hop in ("bionic-to-focal", "focal-to-jammy", "jammy-to-noble"):
            other = open(
                os.path.join(ROOT, "client", "dp-offline-upgrade-%s.sh.in" % hop),
                encoding="utf-8",
            ).read()
            self.assertNotIn("STELLAR_XENIAL_BIONIC_ENV_ORDER_PATCH", other)
            self.assertNotIn("install_xenial_bionic_glibc_env_order_hook", other)


if __name__ == "__main__":
    unittest.main()
