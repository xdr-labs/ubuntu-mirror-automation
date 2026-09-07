#!/usr/bin/env python3
"""P2 regression: safe_tar_extract rejects unsafe members before materializing."""
from __future__ import print_function

import os
import shutil
import sys
import tarfile
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "lib"))

import os_core_package as oc  # noqa: E402


def fail(msg):
    print("FAIL: %s" % msg, file=sys.stderr)
    sys.exit(1)


def pass_(msg):
    print("PASS: %s" % msg)


def _write_legit_tree(src_dir):
    pkg = os.path.join(src_dir, oc.PACKAGE_ROOT_NAME)
    payload = os.path.join(pkg, "payload", "hops", "jammy-to-noble")
    os.makedirs(payload)
    with open(os.path.join(pkg, "manifest.json"), "w", encoding="utf-8") as fh:
        fh.write('{"schema_version":1}\n')
    with open(os.path.join(payload, "hello.txt"), "w", encoding="utf-8") as fh:
        fh.write("ok\n")
    return pkg


def _assert_empty_or_missing(path, label):
    if not os.path.exists(path):
        return
    for dirpath, dirnames, filenames in os.walk(path):
        if dirnames or filenames:
            fail("%s: staging not empty after reject: %s" % (label, os.listdir(path)))


def _extract_should_reject(tar_path, dest, label, needle=None):
    before = set()
    if os.path.isdir(dest):
        before = set(os.listdir(dest))
    try:
        oc.safe_tar_extract(tar_path, dest)
        fail("%s: expected OsCoreError" % label)
    except oc.OsCoreError as exc:
        text = str(exc)
        if needle and needle not in text:
            fail("%s: error %r missing %r" % (label, text, needle))
    # Rejected archives must not materialize unsafe payload content.
    if os.path.isdir(dest):
        after = set(os.listdir(dest))
        if after - before:
            # Only empty dirs from makedirs(dest) are acceptable; no package tree.
            for name in sorted(after - before):
                full = os.path.join(dest, name)
                if os.path.islink(full):
                    fail("%s: symlink materialized: %s" % (label, full))
                if os.path.isfile(full):
                    fail("%s: file materialized: %s" % (label, full))
                if os.path.isdir(full) and (os.listdir(full) or name == oc.PACKAGE_ROOT_NAME):
                    fail("%s: package content materialized under %s" % (label, full))
    pass_(label)


def main():
    tmp = tempfile.mkdtemp(prefix="os-core-tar-test-")
    try:
        # --- Successful normal archive (dirs + regular files only) ---
        legit_src = os.path.join(tmp, "legit-src")
        os.makedirs(legit_src)
        _write_legit_tree(legit_src)
        legit_tar = os.path.join(tmp, "legit.tar")
        oc.safe_tar_create(legit_src, legit_tar)
        legit_dest = os.path.join(tmp, "legit-out")
        oc.safe_tar_extract(legit_tar, legit_dest)
        hello = os.path.join(
            legit_dest, oc.PACKAGE_ROOT_NAME, "payload", "hops", "jammy-to-noble", "hello.txt"
        )
        if not os.path.isfile(hello):
            fail("normal archive: expected extracted file missing")
        with tarfile.open(legit_tar, "r:") as tf:
            if any(m.issym() or m.islnk() for m in tf.getmembers()):
                fail("safe_tar_create must omit symlink/hardlink members")
        hello_dir = os.path.dirname(hello)
        hop_dir = os.path.dirname(hello_dir)
        if oct(os.stat(hello).st_mode & 0o777) != "0o644":
            fail("normal archive: file mode %s expected 0644" % oct(os.stat(hello).st_mode & 0o777))
        if oct(os.stat(hop_dir).st_mode & 0o777) != "0o755":
            fail("normal archive: hop dir mode %s expected 0755" % oct(os.stat(hop_dir).st_mode & 0o777))
        pass_("normal directory/regular-file archive accepted")

        # --- Extract under umask 077 must still yield public HTTP modes ---
        umask_src = os.path.join(tmp, "umask-src")
        os.makedirs(umask_src)
        _write_legit_tree(umask_src)
        umask_tar = os.path.join(tmp, "umask.tar")
        oc.safe_tar_create(umask_src, umask_tar)
        umask_dest = os.path.join(tmp, "umask-out")
        old_umask = os.umask(0o077)
        try:
            oc.safe_tar_extract(umask_tar, umask_dest)
        finally:
            os.umask(old_umask)
        umask_hello = os.path.join(
            umask_dest, oc.PACKAGE_ROOT_NAME, "payload", "hops", "jammy-to-noble", "hello.txt"
        )
        umask_hop = os.path.join(
            umask_dest, oc.PACKAGE_ROOT_NAME, "payload", "hops", "jammy-to-noble"
        )
        if not os.path.isfile(umask_hello):
            fail("umask 077 extract: expected file missing")
        hello_mode = os.stat(umask_hello).st_mode & 0o777
        hop_mode = os.stat(umask_hop).st_mode & 0o777
        dest_mode = os.stat(umask_dest).st_mode & 0o777
        if hello_mode != 0o644:
            fail("umask 077 extract: file mode %s expected 0644" % oct(hello_mode))
        if hop_mode != 0o755:
            fail("umask 077 extract: hop dir mode %s expected 0755" % oct(hop_mode))
        if dest_mode != 0o755:
            fail("umask 077 extract: dest dir mode %s expected 0755" % oct(dest_mode))
        pass_("extract under umask 077 yields 0755 dirs / 0644 files")

        # --- Exact package-root namespace (directory-only member) ---
        root_only = os.path.join(tmp, "root-only.tar")
        with tarfile.open(root_only, "w") as tf:
            info = tarfile.TarInfo(name=oc.PACKAGE_ROOT_NAME)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            tf.addfile(info)
        root_dest = os.path.join(tmp, "out-root-only")
        oc.safe_tar_extract(root_only, root_dest)
        if not os.path.isdir(os.path.join(root_dest, oc.PACKAGE_ROOT_NAME)):
            fail("exact ubuntu-os-core directory member not accepted")
        pass_("exact ubuntu-os-core directory accepted")

        # --- Prefix confusion: ubuntu-os-core-evil/... ---
        bad = os.path.join(tmp, "evil-prefix.tar")
        with tarfile.open(bad, "w") as tf:
            info = tarfile.TarInfo(name="ubuntu-os-core-evil/file")
            data = b"evil"
            info.size = len(data)
            tf.addfile(info, fileobj=__import__("io").BytesIO(data))
        dest = os.path.join(tmp, "out-evil")
        os.makedirs(dest)
        _extract_should_reject(
            bad, dest, "ubuntu-os-core-evil prefix rejected", "TAR_UNEXPECTED_MEMBER"
        )
        if os.path.lexists(os.path.join(dest, "ubuntu-os-core-evil")):
            fail("evil prefix: member materialized before reject")

        # --- Prefix confusion: ubuntu-os-core123/... (reject before any write) ---
        bad = os.path.join(tmp, "num-prefix-ordered.tar")
        with tarfile.open(bad, "w") as tf:
            evil = tarfile.TarInfo(name="ubuntu-os-core123/file")
            data = b"nope"
            evil.size = len(data)
            tf.addfile(evil, fileobj=__import__("io").BytesIO(data))
            good = tarfile.TarInfo(name="ubuntu-os-core/payload/ok.txt")
            gdata = b"ok"
            good.size = len(gdata)
            tf.addfile(good, fileobj=__import__("io").BytesIO(gdata))
        dest = os.path.join(tmp, "out-num")
        os.makedirs(dest)
        _extract_should_reject(
            bad, dest, "ubuntu-os-core123 prefix rejected", "TAR_UNEXPECTED_MEMBER"
        )
        if os.path.lexists(os.path.join(dest, oc.PACKAGE_ROOT_NAME)):
            fail("prefix reject: ubuntu-os-core content materialized before reject")
        if os.path.lexists(os.path.join(dest, "ubuntu-os-core123")):
            fail("prefix reject: confused prefix materialized")

        # --- Shared helper unit checks ---
        if not oc.is_package_root_member("ubuntu-os-core"):
            fail("helper: exact root should be accepted")
        if not oc.is_package_root_member("ubuntu-os-core/payload/x"):
            fail("helper: nested path should be accepted")
        if oc.is_package_root_member("ubuntu-os-core-evil/file"):
            fail("helper: evil prefix must be rejected")
        if oc.is_package_root_member("ubuntu-os-core123/file"):
            fail("helper: numeric suffix prefix must be rejected")
        pass_("package-root namespace helper rejects prefix confusion")

        # --- ../escape ---
        bad = os.path.join(tmp, "escape.tar")
        with tarfile.open(bad, "w") as tf:
            info = tarfile.TarInfo(name="ubuntu-os-core/../escape.txt")
            data = b"x"
            info.size = len(data)
            tf.addfile(info, fileobj=__import__("io").BytesIO(data))
        dest = os.path.join(tmp, "out-escape")
        os.makedirs(dest)
        marker = os.path.join(tmp, "escape-sentinel")
        open(marker, "w").close()
        _extract_should_reject(bad, dest, "../escape rejected", "TAR_UNSAFE_MEMBER")
        if not os.path.isfile(marker):
            fail("../escape: sentinel outside staging was disturbed")

        # --- absolute path ---
        bad = os.path.join(tmp, "abs.tar")
        with tarfile.open(bad, "w") as tf:
            info = tarfile.TarInfo(name="/tmp/evil-absolute.txt")
            data = b"x"
            info.size = len(data)
            tf.addfile(info, fileobj=__import__("io").BytesIO(data))
        dest = os.path.join(tmp, "out-abs")
        _extract_should_reject(bad, dest, "absolute path rejected", "TAR_UNSAFE_MEMBER")

        # --- symlink member ---
        bad = os.path.join(tmp, "sym.tar")
        with tarfile.open(bad, "w") as tf:
            info = tarfile.TarInfo(name="ubuntu-os-core/payload/link")
            info.type = tarfile.SYMTYPE
            info.linkname = "/etc/passwd"
            tf.addfile(info)
        dest = os.path.join(tmp, "out-sym")
        os.makedirs(dest)
        _extract_should_reject(bad, dest, "symlink member rejected", "TAR_UNSAFE_MEMBER")
        link_path = os.path.join(dest, oc.PACKAGE_ROOT_NAME, "payload", "link")
        if os.path.lexists(link_path):
            fail("symlink member: link was materialized at %s" % link_path)

        # --- hardlink member ---
        bad = os.path.join(tmp, "hard.tar")
        with tarfile.open(bad, "w") as tf:
            reg = tarfile.TarInfo(name="ubuntu-os-core/payload/a.txt")
            data = b"body"
            reg.size = len(data)
            tf.addfile(reg, fileobj=__import__("io").BytesIO(data))
            hard = tarfile.TarInfo(name="ubuntu-os-core/payload/b.txt")
            hard.type = tarfile.LNKTYPE
            hard.linkname = "ubuntu-os-core/payload/a.txt"
            tf.addfile(hard)
        dest = os.path.join(tmp, "out-hard")
        _extract_should_reject(bad, dest, "hardlink member rejected", "TAR_UNSAFE_MEMBER")
        if os.path.lexists(os.path.join(dest, oc.PACKAGE_ROOT_NAME, "payload", "b.txt")):
            fail("hardlink member: hardlink was materialized")
        # Pre-validation rejects before any member write.
        if os.path.lexists(os.path.join(dest, oc.PACKAGE_ROOT_NAME, "payload", "a.txt")):
            fail("hardlink archive: prior regular member was materialized before reject")

        # --- FIFO ---
        bad = os.path.join(tmp, "fifo.tar")
        with tarfile.open(bad, "w") as tf:
            info = tarfile.TarInfo(name="ubuntu-os-core/payload/pipe")
            info.type = tarfile.FIFOTYPE
            tf.addfile(info)
        dest = os.path.join(tmp, "out-fifo")
        _extract_should_reject(bad, dest, "FIFO member rejected", "TAR_UNSAFE_MEMBER")
        if os.path.exists(os.path.join(dest, oc.PACKAGE_ROOT_NAME, "payload", "pipe")):
            fail("FIFO member: pipe was materialized")

        # --- character special ---
        bad = os.path.join(tmp, "chr.tar")
        with tarfile.open(bad, "w") as tf:
            info = tarfile.TarInfo(name="ubuntu-os-core/payload/nulldev")
            info.type = tarfile.CHRTYPE
            info.devmajor = 1
            info.devminor = 3
            tf.addfile(info)
        dest = os.path.join(tmp, "out-chr")
        _extract_should_reject(bad, dest, "character special rejected", "TAR_UNSAFE_MEMBER")

        # --- block special ---
        bad = os.path.join(tmp, "blk.tar")
        with tarfile.open(bad, "w") as tf:
            info = tarfile.TarInfo(name="ubuntu-os-core/payload/blkdev")
            info.type = tarfile.BLKTYPE
            info.devmajor = 8
            info.devminor = 0
            tf.addfile(info)
        dest = os.path.join(tmp, "out-blk")
        _extract_should_reject(bad, dest, "block special rejected", "TAR_UNSAFE_MEMBER")

        print("ALL test_os_core_safe_tar_extract checks passed")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
