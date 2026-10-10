#!/usr/bin/env python3
"""Opt-in, fail-closed garbage collection of disposable /tmp Git clones.

Only explicitly registered standalone Git clones are eligible.  This utility
never discovers and deletes arbitrary directories, linked worktrees, or existing
unregistered checkouts.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

DEFAULT_ROOT = Path("/tmp")
DEFAULT_STATE = Path.home() / ".local/state/ubuntu-mirror-automation/tmp-checkout-gc"
RETENTION_SECONDS = 7 * 86400
QUIET_SECONDS = 86400
MAX_REGISTERED = 250
PATH_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{3,120}\Z")


class NotSafe(Exception):
    pass


def config():
    test_mode = os.environ.get("UM_TMP_GC_TESTING") == "1"
    root = Path(os.environ.get("UM_TMP_GC_TEST_ROOT", "/tmp")) if test_mode else DEFAULT_ROOT
    state = Path(os.environ.get("UM_TMP_GC_TEST_STATE", str(DEFAULT_STATE))) if test_mode else DEFAULT_STATE
    root = Path(os.path.abspath(str(root)))
    state = Path(os.path.abspath(str(state)))
    if not root.is_dir() or root.is_symlink() or (root != DEFAULT_ROOT and not test_mode):
        raise NotSafe("unsafe_tmp_root")
    # A test flag must never allow age/quiet checks to be bypassed against /tmp.
    if test_mode and (
        root == DEFAULT_ROOT
        or root.parent != DEFAULT_ROOT
        or not root.name.startswith("um-gc-test-")
        or state == DEFAULT_STATE
    ):
        raise NotSafe("test_scope_must_be_isolated")
    if root == state or root in state.parents:
        raise NotSafe("registry_inside_disposable_root")
    return root, state, test_mode


def owned_dir(path):
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or path.is_symlink():
        raise NotSafe("directory_owner_or_type")
    return info


@contextlib.contextmanager
def locked_registry(state):
    state.mkdir(parents=True, mode=0o700, exist_ok=True)
    owned_dir(state)
    if os.stat(state).st_mode & 0o077:
        raise NotSafe("state_permissions")
    entries = state / "entries"
    entries.mkdir(mode=0o700, exist_ok=True)
    owned_dir(entries)
    if os.stat(entries).st_mode & 0o077:
        raise NotSafe("registry_permissions")
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(str(state / "lock"), flags, 0o600)
    try:
        if os.fstat(fd).st_uid != os.getuid():
            raise NotSafe("lock_owner")
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield entries
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def candidate_path(value, root):
    path = Path(os.path.abspath(str(value)))
    if path.parent != root or not PATH_PATTERN.fullmatch(path.name):
        raise NotSafe("path_not_direct_tmp_child")
    if os.path.realpath(str(path)) != str(path):
        raise NotSafe("symlink_in_path")
    info = owned_dir(path)
    if info.st_dev != os.stat(root).st_dev:
        raise NotSafe("different_filesystem")
    gitdir = path / ".git"
    if not gitdir.is_dir() or gitdir.is_symlink():
        raise NotSafe("not_standalone_clone")
    gi = owned_dir(gitdir)
    if gi.st_dev != info.st_dev:
        raise NotSafe("gitdir_on_other_filesystem")
    return path, info, gi


def git(path, *args, timeout=25):
    env = os.environ.copy()
    env.update(GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0", GIT_CONFIG_NOSYSTEM="1")
    proc = subprocess.run(["/usr/bin/git", "-C", str(path), *args], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=timeout, env=env)
    if proc.returncode:
        raise NotSafe("git_%s_failed_%s" % (args[0], proc.returncode))
    if len(proc.stdout) > 1024 * 1024:
        raise NotSafe("git_output_too_large")
    return proc.stdout.decode("utf-8", "replace").strip()


def checkout_state(path):
    if git(path, "rev-parse", "--show-toplevel") != str(path):
        raise NotSafe("git_root_mismatch")
    if git(path, "rev-parse", "--is-shallow-repository") != "false":
        raise NotSafe("shallow_repository")
    if git(path, "rev-parse", "--git-common-dir") not in (".git", str(path / ".git")):
        raise NotSafe("linked_common_gitdir")
    worktrees = git(path, "worktree", "list", "--porcelain").splitlines()
    if len([line for line in worktrees if line.startswith("worktree ")]) != 1:
        raise NotSafe("linked_worktrees")
    if git(path, "status", "--porcelain=v1", "--untracked-files=all"):
        raise NotSafe("dirty_or_untracked_files")
    # Ignored files can contain valuable run results. Preserve by default.
    if git(path, "status", "--porcelain=v1", "--ignored=matching", "--untracked-files=normal"):
        raise NotSafe("ignored_files_present")
    if git(path, "stash", "list"):
        raise NotSafe("stash_present")
    for marker in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG",
                   "rebase-apply", "rebase-merge", "index.lock"):
        if (path / ".git" / marker).exists():
            raise NotSafe("pending_git_operation")
    head = git(path, "rev-parse", "HEAD")
    remotes = list(dict.fromkeys(git(path, "for-each-ref", "--format=%(objectname)", "refs/remotes").split()))
    if not remotes or len(remotes) > 100:
        raise NotSafe("no_bounded_remote_tracking")
    local = list(dict.fromkeys(git(path, "for-each-ref", "--format=%(objectname)", "refs/heads").split()))
    if len(local) > 50:
        raise NotSafe("too_many_local_branches")
    for commit in set(local + [head]):
        if not any(subprocess.run(["/usr/bin/git", "-C", str(path), "merge-base",
                                   "--is-ancestor", commit, remote],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  timeout=10).returncode == 0 for remote in remotes):
            raise NotSafe("local_commit_not_in_remote_tracking")
    if git(path, "rev-list", "--all", "--reflog", "--not", "--remotes"):
        raise NotSafe("unpublished_reflog_commit")
    return head


def entry_path(entries, path):
    digest = hashlib.sha256(str(path).encode("utf-8")).hexdigest()
    return entries / (digest + ".json")


def read_entry(file):
    s = os.lstat(file)
    if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid() or s.st_nlink != 1 or s.st_mode & 0o077:
        raise NotSafe("entry_permissions")
    with file.open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    return data


def save_entry(file, data):
    fd, temp = tempfile.mkstemp(prefix=".entry-", dir=str(file.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, file)
    finally:
        if os.path.lexists(temp):
            os.unlink(temp)


def register(path, root, entries):
    target, info, gi = candidate_path(path, root)
    head = checkout_state(target)
    record = entry_path(entries, target)
    if os.path.lexists(record):
        raise NotSafe("already_registered")
    if len(list(entries.glob("*.json"))) >= MAX_REGISTERED:
        raise NotSafe("too_many_registrations")
    save_entry(record, dict(schema=1, path=str(target), dev=info.st_dev, ino=info.st_ino,
                            git_dev=gi.st_dev, git_ino=gi.st_ino, head=head,
                            registered_at=int(time.time())))
    print("REGISTERED path=%s retention_days=7" % target)


def no_mounted_subtrees(path):
    try:
        with open("/proc/self/mountinfo", "r", encoding="utf-8") as stream:
            mounts = [line.split()[4].replace("\\040", " ") for line in stream]
    except OSError:
        raise NotSafe("mountinfo_unavailable")
    prefix = str(path) + "/"
    if any(m == str(path) or m.startswith(prefix) for m in mounts):
        raise NotSafe("mounted_subtree")


def no_nested_git_or_recent_changes(path, cutoff, dev):
    for base, dirs, files in os.walk(path, followlinks=False):
        for name in dirs + files:
            child = os.path.join(base, name)
            try:
                s = os.lstat(child)
            except OSError:
                raise NotSafe("tree_changed_during_scan")
            if s.st_dev != dev:
                raise NotSafe("nested_filesystem")
            if name == ".git" and base != str(path):
                raise NotSafe("nested_git_checkout")
            if s.st_mtime > cutoff:
                raise NotSafe("recent_file_activity")


def process_started_before_registration(proc_path, registered_at):
    """Allow older non-dumpable processes only if their cmdline was inspected."""
    try:
        with open(proc_path + "/stat", "r", encoding="utf-8") as fh:
            # comm in parentheses can include spaces; split only AFTER the
            # final close parenthesis. Element 19 is Linux stat field #22.
            suffix = fh.read().rsplit(")", 1)[1].strip().split()
        start_ticks = int(suffix[19])
        with open("/proc/uptime", "r", encoding="ascii") as fh:
            uptime_seconds = float(fh.read().split()[0])
        boot_epoch = time.time() - uptime_seconds
        started_epoch = boot_epoch + start_ticks / os.sysconf("SC_CLK_TCK")
        return started_epoch < registered_at - 60
    except (OSError, IndexError, ValueError, ZeroDivisionError):
        return False


def active_processes(path, registered_at):
    prefix = (str(path) + "/").encode()
    exact = str(path).encode()
    for proc in os.scandir("/proc"):
        if not proc.name.isdigit():
            continue
        pid = proc.name
        try:
            owner = os.stat(proc.path).st_uid
        except OSError:
            continue
        same_user = owner == os.getuid()
        cmdline_inspected = False
        try:
            with open(proc.path + "/cmdline", "rb") as fd:
                cmdline = fd.read(131072)
            cmdline_inspected = True
            if exact in cmdline:
                raise NotSafe("process_command_reference_pid_%s" % pid)
        except (OSError, PermissionError):
            if same_user:
                raise NotSafe("process_command_unreadable_pid_%s" % pid)
        try:
            cwd = os.readlink(proc.path + "/cwd").encode()
            if cwd == exact or cwd.startswith(prefix):
                raise NotSafe("process_cwd_reference_pid_%s" % pid)
        except (OSError, PermissionError):
            if (same_user and os.path.exists(proc.path)
                    and not (cmdline_inspected and
                             process_started_before_registration(proc.path, registered_at))):
                raise NotSafe("process_cwd_unreadable_pid_%s" % pid)
        if not same_user:
            continue
        try:
            descriptors = os.scandir(proc.path + "/fd")
            with descriptors as handle:
                for desc in handle:
                    try:
                        fd_target = os.readlink(desc.path).encode()
                    except OSError:
                        continue
                    if fd_target == exact or fd_target.startswith(prefix):
                        raise NotSafe("process_fd_reference_pid_%s" % pid)
        except OSError:
            if (os.path.exists(proc.path)
                    and not (cmdline_inspected and
                             process_started_before_registration(proc.path, registered_at))):
                raise NotSafe("process_fd_unreadable_pid_%s" % pid)


def evaluate(file, root, now, testing):
    rec = read_entry(file)
    if rec.get("schema") != 1 or not isinstance(rec.get("path"), str):
        raise NotSafe("invalid_registry_schema")
    target, info, gi = candidate_path(rec["path"], root)
    if file != entry_path(file.parent, target):
        raise NotSafe("entry_path_mismatch")
    if info.st_dev != rec.get("dev") or info.st_ino != rec.get("ino"):
        raise NotSafe("checkout_replaced")
    if gi.st_dev != rec.get("git_dev") or gi.st_ino != rec.get("git_ino"):
        raise NotSafe("gitdir_replaced")
    if int(rec.get("registered_at", now)) > now:
        raise NotSafe("registration_in_future")
    if not testing and now - int(rec["registered_at"]) < RETENTION_SECONDS:
        raise NotSafe("retention_not_elapsed")
    quiet = 0 if testing else QUIET_SECONDS
    if info.st_mtime > now - quiet:
        raise NotSafe("directory_recently_modified")
    head = checkout_state(target)
    if head != rec.get("head"):
        raise NotSafe("head_changed")
    no_mounted_subtrees(target)
    no_nested_git_or_recent_changes(target, now - quiet, info.st_dev)
    active_processes(target, int(rec["registered_at"]))
    return target, rec


def prune(entries, root, apply, testing):
    now = time.time()
    files = sorted(entries.glob("*.json"))
    if len(files) > MAX_REGISTERED:
        raise NotSafe("too_many_entries")
    removed = skipped = ready = 0
    for file in files:
        try:
            target, rec = evaluate(file, root, now, testing)
        except (NotSafe, OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
            skipped += 1
            print("SKIP path=%s reason=%s" % (file.name, str(exc).replace(" ", "_")))
            continue
        if not apply:
            ready += 1
            print("READY path=%s mode=dry_run" % target)
            continue
        # Recheck immediately. The registry and git identity are held by our
        # cooperative lock; other tools are not assumed to honor it.
        try:
            target, _ = evaluate(file, root, time.time(), testing)
            if not shutil.rmtree.avoids_symlink_attacks:
                raise NotSafe("rmtree_symlink_safety_unavailable")
            shutil.rmtree(str(target))
            file.unlink()
            removed += 1
            print("REMOVED path=%s" % target)
        except (NotSafe, OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
            skipped += 1
            print("SKIP path=%s reason=%s" % (file.name, str(exc).replace(" ", "_")))
    print("SUMMARY managed=%d ready=%d removed=%d preserved=%d mode=%s" %
          (len(files), ready, removed, skipped, "apply" if apply else "dry_run"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("status")
    p = sub.add_parser("register")
    p.add_argument("path")
    p = sub.add_parser("unregister")
    p.add_argument("path")
    p = sub.add_parser("prune")
    p.add_argument("--apply", action="store_true")
    p = sub.add_parser("create")
    p.add_argument("--source", required=True, help="local Git repository to clone")
    args = parser.parse_args()
    try:
        root, state, testing = config()
        with locked_registry(state) as entries:
            if args.action == "register":
                register(args.path, root, entries)
            elif args.action == "unregister":
                path = Path(os.path.abspath(args.path))
                file = entry_path(entries, path)
                if file.exists() and read_entry(file).get("path") == str(path):
                    file.unlink()
                    print("UNREGISTERED path=%s checkout_preserved=yes" % path)
                else:
                    raise NotSafe("entry_not_registered")
            elif args.action == "status":
                prune(entries, root, False, testing)
            elif args.action == "prune":
                prune(entries, root, args.apply, testing)
            elif args.action == "create":
                source = Path(os.path.realpath(args.source))
                if not source.is_dir() or not (source / ".git").is_dir():
                    raise NotSafe("source_not_standalone_local_repo")
                target = Path(tempfile.mkdtemp(prefix="um-tmp-checkout-", dir=str(root)))
                # Do not remove the new directory on failure; preserve evidence.
                try:
                    subprocess.run(["/usr/bin/git", "clone", "--local", "--no-hardlinks",
                                    "--quiet", "--", str(source), str(target)], check=True,
                                   timeout=120)
                    register(target, root, entries)
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired, NotSafe) as exc:
                    raise NotSafe("create_incomplete_preserved_path=%s error=%s" % (target, exc))
                print("CHECKOUT=%s" % target)
    except (NotSafe, OSError) as exc:
        print("TMP_CHECKOUT_GC=REFUSED reason=%s" % str(exc).replace(" ", "_"), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
