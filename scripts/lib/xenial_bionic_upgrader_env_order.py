"""Reorder Xenial→Bionic DistUpgradeController environment mutations.

Live RCA (Ubuntu 16.04, glibc 2.23): do-release-upgrade exited 139 before
apt-clone or any package mutation. The kernel reported a GDBus worker
segfault in libc-2.23.so at offset 0x3982d, which disassembles to
getenv()+0xad (a NULL environment entry pointer).

The extracted 18.04 UpgradeTool calls inhibit_sleep() first. That starts
GIO/GDBus worker threads, then mutates RELEASE_UPGRADE_IN_PROGRESS,
PYCENTRAL_FORCE_OVERWRITE, and PATH. glibc 2.23 getenv is not safe against
a concurrent setenv. A minimal pthread reproduction on the failed host
(concurrent getenv readers plus one setenv writer) failed immediately with
RC=139 at the same libc offset. Single-thread inhibit calls did not.

This module only moves those three os.environ assignments ahead of
inhibit_sleep() on an extracted Xenial→Bionic (18.04) upgrader tree.
Other hops are rejected. A tree whose controller text does not match the
expected 18.04 signature is left untouched and reported as a hard failure.
"""

from __future__ import print_function

import os
import re
import sys

UNPATCHED_BLOCK = (
    "        # install a logind sleep inhibitor\n"
    "        self.inhibitor_fd = inhibit_sleep()\n"
    "\n"
    "        # setup env var \n"
    '        os.environ["RELEASE_UPGRADE_IN_PROGRESS"] = "1"\n'
    '        os.environ["PYCENTRAL_FORCE_OVERWRITE"] = "1"\n'
    '        os.environ["PATH"] = "%s:%s" % (os.getcwd()+"/imported",\n'
    '                                        os.environ["PATH"])\n'
)

PATCHED_BLOCK = (
    "        # Xenial glibc 2.23 getenv/setenv race (exit 139):\n"
    "        # inhibit_sleep() starts a GIO/GDBus worker that calls getenv while\n"
    "        # this process then setenv()s. Live fault: libc-2.23.so+0x3982d\n"
    "        # (getenv+0xad). A pthread getenv/setenv reproducer hit the same\n"
    "        # offset. Mutate the environment before any GDBus thread exists.\n"
    '        os.environ["RELEASE_UPGRADE_IN_PROGRESS"] = "1"\n'
    '        os.environ["PYCENTRAL_FORCE_OVERWRITE"] = "1"\n'
    '        os.environ["PATH"] = "%s:%s" % (os.getcwd()+"/imported",\n'
    '                                        os.environ["PATH"])\n'
    "\n"
    "        # install a logind sleep inhibitor\n"
    "        self.inhibitor_fd = inhibit_sleep()\n"
)

_VERSION_RE = re.compile(r"^VERSION\s*=\s*'18\.04\.\d+'\s*$", re.M)
_ENV_NAMES = (
    "RELEASE_UPGRADE_IN_PROGRESS",
    "PYCENTRAL_FORCE_OVERWRITE",
    "PATH",
)


class UpgraderPatchError(Exception):
    """Fail closed: expected 18.04 source shape is absent or ambiguous."""


def _read(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def validate_upgrader_tree(root):
    """Return controller text after the 18.04 signature checks."""
    root = os.path.abspath(root)
    controller = os.path.join(root, "DistUpgradeController.py")
    version = os.path.join(root, "DistUpgradeVersion.py")
    entry = os.path.join(root, "bionic")
    if not os.path.isfile(controller):
        raise UpgraderPatchError("controller missing")
    if not os.path.isfile(version):
        raise UpgraderPatchError("version signature missing")
    if not os.path.isfile(entry):
        raise UpgraderPatchError("bionic entry missing")
    version_text = _read(version)
    if not _VERSION_RE.search(version_text):
        raise UpgraderPatchError("unexpected upgrader version signature")
    return _read(controller)


def _assignments_precede_inhibit(text):
    call = text.find("self.inhibitor_fd = inhibit_sleep()")
    if call < 0:
        return False
    for name in _ENV_NAMES:
        marker = 'os.environ["%s"]' % name
        pos = text.find(marker)
        if pos < 0 or pos > call:
            return False
    return True


def patch_upgrader_tree(root):
    """Patch root in place. Idempotent. Raises UpgraderPatchError on mismatch.

    Returns 'patched' or 'already'.
    """
    text = validate_upgrader_tree(root)
    has_old = UNPATCHED_BLOCK in text
    has_new = PATCHED_BLOCK in text
    if has_old and has_new:
        raise UpgraderPatchError("ambiguous controller signature")
    if has_new:
        if not _assignments_precede_inhibit(text):
            raise UpgraderPatchError("patched controller failed order check")
        return "already"
    if not has_old:
        raise UpgraderPatchError("expected 18.04 inhibit/env signature missing")
    updated = text.replace(UNPATCHED_BLOCK, PATCHED_BLOCK, 1)
    if updated == text or UNPATCHED_BLOCK in updated:
        raise UpgraderPatchError("controller rewrite failed")
    if not _assignments_precede_inhibit(updated):
        raise UpgraderPatchError("rewritten controller failed order check")
    controller = os.path.join(os.path.abspath(root), "DistUpgradeController.py")
    tmp = controller + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(updated)
    os.replace(tmp, controller)
    return "patched"


def maybe_patch_running_upgrader():
    """sitecustomize entry. No-op unless this process is the bionic upgrader."""
    if os.environ.get("STELLAR_XENIAL_BIONIC_ENV_ORDER_PATCH") != "1":
        return
    argv0 = os.path.basename(sys.argv[0]) if sys.argv else ""
    if argv0 != "bionic":
        return
    root = os.path.dirname(os.path.abspath(sys.argv[0]))
    try:
        result = patch_upgrader_tree(root)
    except UpgraderPatchError as exc:
        sys.stderr.write("XENIAL_BIONIC_ENV_ORDER_PATCH=FAIL %s\n" % exc)
        raise SystemExit(1)
    sys.stderr.write("XENIAL_BIONIC_ENV_ORDER_PATCH=%s\n" % result.upper())


maybe_patch_running_upgrader()
