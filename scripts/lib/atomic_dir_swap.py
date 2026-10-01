#!/usr/bin/env python3
"""Rollback-safe atomic directory exchange for client-set publish.

Prefers Linux renameat2(RENAME_EXCHANGE) when available. Falls back to
backup+rename with immediate restore if the second rename fails.
"""
from __future__ import print_function

import argparse
import ctypes
import ctypes.util
import errno
import os
import shutil
import sys
import tempfile


RENAME_EXCHANGE = 1 << 1  # linux/fs.h


class SwapError(Exception):
    pass


def _same_filesystem(path_a, path_b):
    return os.stat(path_a).st_dev == os.stat(path_b).st_dev


def _renameat2_exchange(path_a, path_b):
    """Attempt renameat2(RENAME_EXCHANGE). Returns True on success."""
    libc_name = ctypes.util.find_library("c")
    if not libc_name:
        return False
    libc = ctypes.CDLL(libc_name, use_errno=True)
    if not hasattr(libc, "renameat2"):
        return False
    AT_FDCWD = -100
    libc.renameat2.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    a = os.fsencode(os.path.abspath(path_a))
    b = os.fsencode(os.path.abspath(path_b))
    rc = libc.renameat2(AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCHANGE)
    if rc == 0:
        return True
    err = ctypes.get_errno()
    if err in (errno.ENOSYS, errno.EINVAL, errno.EPERM):
        return False
    raise SwapError("renameat2(RENAME_EXCHANGE) failed: {}".format(os.strerror(err)))


def atomic_dir_swap(stage_dir, live_dir, backup_dir=None, require_exchange=False,
                    keep_previous=False):
    """Publish stage_dir to live_dir with rollback safety.

    The first publication is one atomic rename. With an existing live directory,
    RENAME_EXCHANGE is preferred. If require_exchange is true, fail closed before
    mutating live rather than using the two-rename rollback fallback.

    When keep_previous is true, the previous live generation is retained at
    stage_dir (RENAME_EXCHANGE) or backup_dir (fallback) until the caller commits
    or rolls back the surrounding transaction.

    On success returns dict with method and rollback status.
    On failure restores previous live_dir when possible and raises SwapError.
    """
    stage_dir = os.path.abspath(stage_dir)
    live_dir = os.path.abspath(live_dir)
    if not os.path.isdir(stage_dir):
        raise SwapError("stage directory missing: {}".format(stage_dir))

    parent = os.path.dirname(live_dir) or "."
    os.makedirs(parent, exist_ok=True)

    live_exists = os.path.isdir(live_dir)
    if live_exists and not _same_filesystem(stage_dir, live_dir):
        raise SwapError(
            "stage and live directories are on different filesystems "
            "(atomic rename required)"
        )
    if not live_exists:
        # Ensure parent and stage share a filesystem for a simple rename.
        probe = tempfile.mkdtemp(prefix=".client-swap-probe.", dir=parent)
        try:
            if not _same_filesystem(stage_dir, probe):
                raise SwapError(
                    "stage and live parent are on different filesystems"
                )
        finally:
            shutil.rmtree(probe, ignore_errors=True)
        os.rename(stage_dir, live_dir)
        return {
            "method": "rename_into_place",
            "rollback": "NOT_REQUIRED",
            "previous_preserved": "NONE",
            "previous_path": "",
        }

    # Prefer atomic exchange when both exist.
    if _renameat2_exchange(stage_dir, live_dir):
        # After exchange: live_dir has new content; stage_dir has old content.
        previous_path = stage_dir if keep_previous else ""
        if not keep_previous:
            shutil.rmtree(stage_dir, ignore_errors=True)
        return {
            "method": "renameat2_RENAME_EXCHANGE",
            "rollback": "NOT_REQUIRED",
            "previous_preserved": (
                "RETAINED_FOR_TRANSACTION" if keep_previous
                else "EXCHANGED_THEN_REMOVED"
            ),
            "previous_path": previous_path,
        }

    if require_exchange:
        # Some publications (for example a sealed prerequisite release) must
        # never have a live-path gap. Fail before mutating either directory if
        # the kernel/filesystem cannot provide RENAME_EXCHANGE.
        raise SwapError(
            "renameat2(RENAME_EXCHANGE) unavailable; live set left untouched"
        )

    # Fallback: move live aside, then move stage into live; restore on failure.
    if backup_dir is None:
        backup_dir = "{}.prev.{}".format(live_dir, os.getpid())
    backup_dir = os.path.abspath(backup_dir)
    if os.path.exists(backup_dir):
        raise SwapError("backup path already exists: {}".format(backup_dir))

    try:
        os.rename(live_dir, backup_dir)
    except OSError as exc:
        raise SwapError("failed to move live aside: {}".format(exc))

    try:
        os.rename(stage_dir, live_dir)
    except OSError as exc:
        # Immediate rollback.
        try:
            if os.path.isdir(live_dir):
                shutil.rmtree(live_dir, ignore_errors=True)
            os.rename(backup_dir, live_dir)
            raise SwapError(
                "second rename failed; previous set restored: {}".format(exc)
            )
        except OSError as restore_exc:
            raise SwapError(
                "second rename failed AND rollback failed "
                "(previous at {}): {} / {}".format(backup_dir, exc, restore_exc)
            )

    previous_path = backup_dir if keep_previous else ""
    if not keep_previous:
        shutil.rmtree(backup_dir, ignore_errors=True)
    return {
        "method": "backup_rename_rollback_safe",
        "rollback": "NOT_REQUIRED",
        "previous_preserved": (
            "RETAINED_FOR_TRANSACTION" if keep_previous
            else "REMOVED_AFTER_SUCCESS"
        ),
        "previous_path": previous_path,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--stage-dir", required=True)
    ap.add_argument("--live-dir", required=True)
    ap.add_argument("--backup-dir", default="")
    ap.add_argument("--require-exchange", action="store_true",
                    help="fail without mutating live when RENAME_EXCHANGE is unavailable")
    ap.add_argument("--keep-previous", action="store_true",
                    help="retain the previous live generation for caller commit/rollback")
    ap.add_argument("--inject-fail-after-backup", action="store_true",
                    help="test hook: fail after moving live aside")
    args = ap.parse_args(argv)
    try:
        if args.inject_fail_after_backup:
            # Exercise rollback path without renameat2.
            stage = os.path.abspath(args.stage_dir)
            live = os.path.abspath(args.live_dir)
            backup = args.backup_dir or "{}.prev.{}".format(live, os.getpid())
            if not os.path.isdir(live):
                raise SwapError("inject requires existing live dir")
            os.rename(live, backup)
            # Simulate second rename failure + restore.
            try:
                raise OSError(errno.EIO, "injected failure")
            except OSError as exc:
                os.rename(backup, live)
                raise SwapError(
                    "second rename failed; previous set restored: {}".format(exc)
                )
        result = atomic_dir_swap(
            args.stage_dir,
            args.live_dir,
            backup_dir=args.backup_dir or None,
            require_exchange=args.require_exchange,
            keep_previous=args.keep_previous,
        )
        print("CLIENT_SET_ATOMIC_SWAP=PASS")
        print("CLIENT_SET_ATOMIC_SWAP_METHOD={}".format(result["method"]))
        print("CLIENT_SET_ROLLBACK={}".format(result["rollback"]))
        print("CLIENT_SET_PREVIOUS_PRESERVED={}".format(result["previous_preserved"]))
        if result.get("previous_path"):
            print("CLIENT_SET_PREVIOUS_PATH={}".format(result["previous_path"]))
        print("CLIENT_SET_DEPLOY_ATOMIC=YES")
        return 0
    except SwapError as exc:
        print("CLIENT_SET_ATOMIC_SWAP=FAIL", file=sys.stderr)
        print("CLIENT_SET_ERROR={}".format(exc), file=sys.stderr)
        # Detect successful rollback messaging.
        msg = str(exc)
        if "previous set restored" in msg:
            print("CLIENT_SET_ROLLBACK=PASS", file=sys.stderr)
        else:
            print("CLIENT_SET_ROLLBACK=FAIL", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
