#!/usr/bin/env python3
"""Xenial→Bionic glibc getenv/setenv ordering patch."""

from __future__ import print_function

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE_PATH = os.path.join(ROOT, "scripts/lib/xenial_bionic_upgrader_env_order.py")
TEMPLATE = os.path.join(ROOT, "client/dp-offline-upgrade-xenial-to-bionic.sh.in")


def load_module():
    spec = importlib.util.spec_from_file_location("xenial_bionic_upgrader_env_order", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_tree(root, version, controller, entry_name="bionic"):
    os.makedirs(root)
    with open(os.path.join(root, "DistUpgradeVersion.py"), "w", encoding="utf-8") as fh:
        fh.write("VERSION = '%s'\n" % version)
    with open(os.path.join(root, "DistUpgradeController.py"), "w", encoding="utf-8") as fh:
        fh.write(controller)
    with open(os.path.join(root, entry_name), "w", encoding="utf-8") as fh:
        fh.write("#!/usr/bin/python3\nprint('ENTRY_OK')\n")


class EnvOrderPatchTests(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()
        self.tmp = tempfile.mkdtemp(prefix="env-order-")
        self.addCleanup(shutil.rmtree, self.tmp)

    def _controller(self, block):
        return "class DistUpgradeController(object):\n    def __init__(self):\n" + block + "        check_and_fix_xbit()\n"

    def test_patch_orders_env_before_inhibit_and_is_idempotent(self):
        root = os.path.join(self.tmp, "up")
        write_tree(root, "18.04.45", self._controller(self.mod.UNPATCHED_BLOCK))
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
        write_tree(root, "18.04.45", self._controller(self.mod.UNPATCHED_BLOCK))
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
