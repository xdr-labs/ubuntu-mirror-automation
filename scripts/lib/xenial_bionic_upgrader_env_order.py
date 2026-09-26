"""Keep the Xenial→Bionic upgrader off the glibc 2.23 getenv/setenv race.

Live RCA (Ubuntu 16.04, glibc 2.23): do-release-upgrade exited 139 before
apt-clone or any package mutation. The kernel reported a GDBus worker
segfault in libc-2.23.so at offset 0x3982d, which disassembles to
getenv()+0xad (an invalid/stale environment entry pointer; the fault address
was 0x1d0, not NULL).

The extracted 18.04.45 UpgradeTool calls inhibit_sleep() and keeps the
logind inhibitor in-process. That starts a GIO/GDBus worker. The same
process then keeps mutating the environment: the early
RELEASE_UPGRADE_IN_PROGRESS / PYCENTRAL_FORCE_OVERWRITE / PATH assignments,
then RELEASE_UPGRADE_MODE in prepare(), TERM and PAGER before every
noninteractive pty fork, and PYTHONPATH before a later exec. glibc 2.23
getenv is not safe against a concurrent setenv. A minimal pthread
reproduction on the failed host (concurrent getenv readers plus one setenv
writer) failed immediately with RC=139 at the same libc offset.

Moving only the first three assignments before inhibit_sleep() leaves the
later writes in a process that still has a GIO worker. Those later writes
cannot all be hoisted: RELEASE_UPGRADE_MODE depends on the cache mode,
and TERM/PAGER must be set on this process immediately before pty.fork so
the maintainer-script child inherits them.

This module therefore does two things, only on an extracted Xenial→Bionic
(18.04) tree:
- move the three early os.environ assignments ahead of inhibit_sleep()
- replace in-process Gio inhibit_sleep() with systemd-inhibit in a child
  process that holds the same shutdown:sleep block lock

The command blocks on a pipe and exits at EOF, so handle close and
upgrader exit both end the command and let systemd-inhibit release the
lock. Xenial systemd 229 does not forward SIGTERM to that command.
If the replacement inhibitor cannot be acquired, the patched controller
aborts before package mutation. This process never imports Gio for the
inhibitor, so later setenv calls have no in-process GDBus worker to race
with. Other hops are rejected. A tree whose controller or inhibit_sleep()
text does not match the 18.04 signature is left untouched and reported
as a hard failure.
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
    "        # inhibit_sleep() used to start a GIO/GDBus worker that calls\n"
    "        # getenv while this process setenv()s. Live fault:\n"
    "        # libc-2.23.so+0x3982d (getenv+0xad), fault address 0x1d0.\n"
    "        # Mutate the early environment before the inhibitor is taken.\n"
    '        os.environ["RELEASE_UPGRADE_IN_PROGRESS"] = "1"\n'
    '        os.environ["PYCENTRAL_FORCE_OVERWRITE"] = "1"\n'
    '        os.environ["PATH"] = "%s:%s" % (os.getcwd()+"/imported",\n'
    '                                        os.environ["PATH"])\n'
    "\n"
    "        # install a logind sleep inhibitor\n"
    "        self.inhibitor_fd = inhibit_sleep()\n"
    "        if not self.inhibitor_fd:\n"
    '            sys.stderr.write("XENIAL_BIONIC_SLEEP_INHIBIT=FAIL\\n")\n'
    "            raise SystemExit(1)\n"
)

# Exact inhibit_sleep() from pinned bionic.tar.gz 18.04.45
# SHA256 976b87d935f8aa2867fac161198812693e6bde6b8fc3fd84f9a7705f638b50a3.
UNPATCHED_INHIBIT = (
    "def inhibit_sleep():\n"
    "    \"\"\"\n"
    "    Send a dbus signal to logind to not suspend the system, it will be\n"
    "    released when the return value drops out of scope\n"
    "    \"\"\"\n"
    "    try:\n"
    "        from gi.repository import Gio, GLib\n"
    "        connection = Gio.bus_get_sync(Gio.BusType.SYSTEM)\n"
    "\n"
    "        var, fdlist = connection.call_with_unix_fd_list_sync(\n"
    "            'org.freedesktop.login1', '/org/freedesktop/login1',\n"
    "            'org.freedesktop.login1.Manager', 'Inhibit',\n"
    "            GLib.Variant('(ssss)',\n"
    "                         ('shutdown:sleep',\n"
    "                          'UpdateManager', 'Updating System',\n"
    "                          'block')),\n"
    "            None, 0, -1, None, None)\n"
    "        inhibitor = Gio.UnixInputStream(fd=fdlist.steal_fds()[var[0]])\n"
    "\n"
    "        return inhibitor\n"
    "    except Exception:\n"
    "        #print(\"could not send the dbus Inhibit signal: %s\" % e)\n"
    "        return False\n"
    "\n"
    "\n"
)

PATCHED_INHIBIT = '''def inhibit_sleep():
    """
    Hold a logind shutdown/sleep inhibitor outside this process.

    Xenial glibc 2.23 segfaults if a GIO/GDBus worker in this process calls
    getenv while this process calls setenv. The pinned 18.04.45 upgrader
    still assigns RELEASE_UPGRADE_MODE, TERM, PAGER, and PYTHONPATH after
    the inhibitor is taken, so an in-process Gio inhibitor is not safe.
    systemd-inhibit takes the same shutdown:sleep block lock (who
    UpdateManager, why Updating System). The command reads stdin and
    exits on EOF. Closing that pipe (handle close, or this process
    exiting) makes the command exit so systemd-inhibit's wait() returns
    and the lock is released. Xenial systemd v229 forks the command and
    does not forward SIGTERM to it, and fork() clears PR_SET_PDEATHSIG,
    so killing systemd-inhibit would leak the command.
    """
    class _SleepInhibitHandle(object):
        def __init__(self, proc):
            self._proc = proc

        def close(self):
            proc = getattr(self, "_proc", None)
            if proc is None:
                return
            self._proc = None
            stdin = getattr(proc, "stdin", None)
            if stdin is not None:
                try:
                    stdin.close()
                except Exception:
                    pass
            try:
                proc.wait(timeout=5)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
                try:
                    proc.wait(timeout=2)
                except Exception:
                    pass

        def __del__(self):
            try:
                self.close()
            except Exception:
                pass

    try:
        import subprocess
        import select
        proc = subprocess.Popen(
            ["systemd-inhibit",
             "--what=shutdown:sleep",
             "--who=UpdateManager",
             "--why=Updating System",
             "--mode=block",
             "sh", "-c", "echo OK; exec cat >/dev/null"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL)
        ready, _, _ = select.select([proc.stdout], [], [], 5)
        if not ready or proc.poll() is not None:
            handle = _SleepInhibitHandle(proc)
            handle.close()
            return False
        line = proc.stdout.readline()
        if line.strip() != b"OK":
            handle = _SleepInhibitHandle(proc)
            handle.close()
            return False
        return _SleepInhibitHandle(proc)
    except Exception:
        return False


'''

_VERSION_RE = re.compile(r"^VERSION\s*=\s*'18\.04\.\d+'\s*$", re.M)
_ENV_NAMES = (
    "RELEASE_UPGRADE_IN_PROGRESS",
    "PYCENTRAL_FORCE_OVERWRITE",
    "PATH",
)
_PINNED_LATER_ENV_MARKERS = (
    'os.environ["RELEASE_UPGRADE_MODE"] = "server"',
    'os.environ["RELEASE_UPGRADE_MODE"] = "desktop"',
    'os.environ["TERM"] = "dumb"',
    'os.environ["PAGER"] = "true"',
    'os.environ["PYTHONPATH"] = "/usr/lib/release-upgrader-python-apt"',
)


class UpgraderPatchError(Exception):
    """Fail closed: expected 18.04 source shape is absent or ambiguous."""


def _read(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def _atomic_write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


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


def _inhibit_function_body(text):
    start = text.find("def inhibit_sleep():")
    if start < 0:
        return ""
    nxt = text.find("\ndef ", start + 1)
    if nxt < 0:
        return text[start:]
    return text[start:nxt]


def inhibit_starts_inprocess_gio(text):
    """True when inhibit_sleep() imports Gio in this process."""
    body = _inhibit_function_body(text)
    if not body:
        return False
    return ("gi.repository" in body) or ("Gio.bus_get_sync" in body)


def inhibit_is_out_of_process(text):
    """True when sleep inhibition is held by a systemd-inhibit child."""
    body = _inhibit_function_body(text)
    if not body or inhibit_starts_inprocess_gio(body):
        return False
    required = (
        "systemd-inhibit",
        "--what=shutdown:sleep",
        "--who=UpdateManager",
        "--why=Updating System",
        "--mode=block",
        "exec cat >/dev/null",
        "stdin.close()",
        "return _SleepInhibitHandle(proc)",
    )
    return all(part in body for part in required)


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


def _rewrite_controller(text):
    has_old = UNPATCHED_BLOCK in text
    has_new = PATCHED_BLOCK in text
    if has_old and has_new:
        raise UpgraderPatchError("ambiguous controller signature")
    if has_new:
        if not _assignments_precede_inhibit(text):
            raise UpgraderPatchError("patched controller failed order check")
        return text, "already"
    if not has_old:
        raise UpgraderPatchError("expected 18.04 inhibit/env signature missing")
    updated = text.replace(UNPATCHED_BLOCK, PATCHED_BLOCK, 1)
    if updated == text or UNPATCHED_BLOCK in updated:
        raise UpgraderPatchError("controller rewrite failed")
    if not _assignments_precede_inhibit(updated):
        raise UpgraderPatchError("rewritten controller failed order check")
    return updated, "patched"


def _rewrite_inhibit(text):
    has_old = UNPATCHED_INHIBIT in text
    has_new = PATCHED_INHIBIT in text
    if has_old and has_new:
        raise UpgraderPatchError("ambiguous inhibit_sleep signature")
    if has_new:
        if not inhibit_is_out_of_process(text):
            raise UpgraderPatchError("patched inhibit_sleep is not out of process")
        return text, "already"
    if not has_old:
        raise UpgraderPatchError("expected 18.04 inhibit_sleep signature missing")
    updated = text.replace(UNPATCHED_INHIBIT, PATCHED_INHIBIT, 1)
    if updated == text or UNPATCHED_INHIBIT in updated:
        raise UpgraderPatchError("inhibit_sleep rewrite failed")
    if not inhibit_is_out_of_process(updated) or inhibit_starts_inprocess_gio(updated):
        raise UpgraderPatchError("rewritten inhibit_sleep still starts Gio")
    return updated, "patched"


def patch_upgrader_tree(root):
    """Patch root in place. Idempotent. Raises UpgraderPatchError on mismatch.

    Returns 'patched' or 'already'. Writes nothing until both rewrites validate.
    """
    root = os.path.abspath(root)
    text = validate_upgrader_tree(root)
    utils_path = os.path.join(root, "utils.py")
    if not os.path.isfile(utils_path):
        raise UpgraderPatchError("utils.py missing")
    utils_text = _read(utils_path)
    new_controller, controller_state = _rewrite_controller(text)
    new_utils, utils_state = _rewrite_inhibit(utils_text)
    controller = os.path.join(root, "DistUpgradeController.py")
    if controller_state == "patched":
        _atomic_write(controller, new_controller)
    if utils_state == "patched":
        _atomic_write(utils_path, new_utils)
    if controller_state == "patched" or utils_state == "patched":
        return "patched"
    return "already"


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
    except Exception as exc:
        # site.py swallows Exception from sitecustomize and would continue
        # into the unpatched bionic entry. Ordinary failures, including
        # UpgraderPatchError and OSError (ENOSPC, EACCES), must exit.
        # SystemExit and other BaseException values are not caught here.
        sys.stderr.write("XENIAL_BIONIC_ENV_ORDER_PATCH=FAIL %s\n" % exc)
        raise SystemExit(1)
    sys.stderr.write("XENIAL_BIONIC_ENV_ORDER_PATCH=%s\n" % result.upper())


maybe_patch_running_upgrader()
