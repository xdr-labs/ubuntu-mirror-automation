#!/usr/bin/env python3
"""Ubuntu OS Core package builder and verifier (R2 transport artifact).

Package layout (no absolute paths):
  ubuntu-os-core/
    manifest.json
    payload.sha256
    payload/
      hops/...
      shared/...
      (ubuntu alias is recreated after materialize; archives carry dirs/files only)

Used by the DP Upgrade Mirror Manager after R2 download. Does not modify
production mirror data by itself. Safe-path rules are mandatory.
"""
from __future__ import print_function

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone

SCHEMA_VERSION = 1
ARTIFACT_TYPE = "ubuntu-os-core"
SUPPORTED_HOPS = (
    "xenial-to-bionic",
    "bionic-to-focal",
    "focal-to-jammy",
    "jammy-to-noble",
)
PACKAGE_ROOT_NAME = "ubuntu-os-core"
EXCLUDE_NAME_FRAGMENTS = (
    ".part",
    ".tmp",
    ".lock",
    "dp-phase2",
    "dp_bundle_",
    "aella-uvp-",
    "aelladeb_py3",
    "images-",
    "bringup_py3",
    "ACPS_",
    "password",
    "token",
    "otp",
    "license",
    "id_rsa",
    ".private.gpg",
)


class OsCoreError(Exception):
    pass


def eprint(*args):
    print(*args, file=sys.stderr)


def iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_bytes(data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def is_hex64(value):
    return bool(value) and bool(re.match(r"^[0-9a-fA-F]{64}$", str(value).strip()))


def read_ready_fields(ready_path):
    fields = {}
    if not ready_path or not os.path.isfile(ready_path):
        return fields
    with open(ready_path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if "=" in line:
                k, v = line.split("=", 1)
                fields[k.strip()] = v.strip()
    return fields


def derive_os_core_provenance(pkg_root, payload_root=None):
    """Derive selective READY provenance from a verified ubuntu-os-core package root.

    Prefer (in order):
      1. Embedded payload/state/READY with valid hex checksums
      2. Explicit selective_plan_checksum / discovery_artifact_checksum in manifest.json
         (discovery must match sha256(payload.sha256))
      3. Backward-compatible derivation for packages already on R2:
         selective_plan_checksum = sha256(manifest.json)
         discovery_artifact_checksum = sha256(payload.sha256)

    Never invents empty or placeholder checksums.
    """
    pkg_root = os.path.abspath(pkg_root)
    if payload_root is None:
        payload_root = os.path.join(pkg_root, "payload")
    else:
        payload_root = os.path.abspath(payload_root)

    manifest_path = os.path.join(pkg_root, "manifest.json")
    payload_sum = os.path.join(pkg_root, "payload.sha256")
    if not os.path.isfile(manifest_path):
        raise OsCoreError("MANIFEST_MISSING for provenance")
    if not os.path.isfile(payload_sum):
        raise OsCoreError("PAYLOAD_SHA256_MISSING for provenance")

    manifest_sha = sha256_file(manifest_path)
    payload_manifest_sha = sha256_file(payload_sum)

    embedded = os.path.join(payload_root, "state", "READY")
    # After payload has been moved out of pkg_root, callers may pass the moved
    # payload path separately; also accept READY already under that tree.
    if not os.path.isfile(embedded):
        embedded = os.path.join(payload_root, "state", "READY")
    if os.path.isfile(embedded):
        fields = read_ready_fields(embedded)
        plan = fields.get("selective_plan_checksum") or fields.get("plan_checksum") or ""
        disc = fields.get("discovery_artifact_checksum") or ""
        if is_hex64(plan) and is_hex64(disc):
            return {
                "source": "PACKAGE_EMBEDDED_READY",
                "action": "REUSE_VERIFIED",
                "selective_plan_checksum": plan.lower(),
                "discovery_artifact_checksum": disc.lower(),
                "os_core_manifest_sha256": manifest_sha,
                "os_core_payload_manifest_sha256": payload_manifest_sha,
                "release_id": fields.get("os_core_release_id") or "",
            }

    with open(manifest_path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)
    plan = (manifest.get("selective_plan_checksum") or "").strip()
    disc = (manifest.get("discovery_artifact_checksum") or "").strip()
    if is_hex64(plan) and is_hex64(disc):
        if disc.lower() != payload_manifest_sha:
            raise OsCoreError(
                "MANIFEST_DISCOVERY_MISMATCH manifest=%s actual=%s"
                % (disc.lower(), payload_manifest_sha)
            )
        return {
            "source": "PACKAGE_MANIFEST_FIELDS",
            "action": "CREATE_VERIFIED",
            "selective_plan_checksum": plan.lower(),
            "discovery_artifact_checksum": disc.lower(),
            "os_core_manifest_sha256": manifest_sha,
            "os_core_payload_manifest_sha256": payload_manifest_sha,
            "release_id": str(manifest.get("release_id") or ""),
        }

    # Current R2 packages: no READY, no explicit provenance fields.
    return {
        "source": "PACKAGE_MANIFEST_AND_PAYLOAD_SHA256",
        "action": "CREATE_VERIFIED",
        "selective_plan_checksum": manifest_sha,
        "discovery_artifact_checksum": payload_manifest_sha,
        "os_core_manifest_sha256": manifest_sha,
        "os_core_payload_manifest_sha256": payload_manifest_sha,
        "release_id": str(manifest.get("release_id") or ""),
    }


def write_selective_ready_from_provenance(selective_root, provenance):
    """Atomically write selective/state/READY from verified provenance dict."""
    plan = provenance.get("selective_plan_checksum") or ""
    disc = provenance.get("discovery_artifact_checksum") or ""
    if not is_hex64(plan) or not is_hex64(disc):
        raise OsCoreError("PROVENANCE_CHECKSUM_INVALID")
    state_dir = os.path.join(selective_root, "state")
    os.makedirs(state_dir, exist_ok=True)
    ready_path = os.path.join(state_dir, "READY")
    lines = [
        "READY",
        "profile_name=offline-upgrade-selective",
        "created_at=%s" % iso_now(),
        "os_core_provenance_source=%s" % provenance.get("source", ""),
        "os_core_manifest_sha256=%s" % provenance.get("os_core_manifest_sha256", ""),
        "os_core_payload_manifest_sha256=%s"
        % provenance.get("os_core_payload_manifest_sha256", ""),
        "selective_plan_checksum=%s" % plan.lower(),
        "plan_checksum=%s" % plan.lower(),
        "discovery_artifact_checksum=%s" % disc.lower(),
        "validation_phase=os_core_materialize",
    ]
    if provenance.get("release_id"):
        lines.append("os_core_release_id=%s" % provenance["release_id"])
    tmp = ready_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(tmp, ready_path)
    # Post-write verify
    fields = read_ready_fields(ready_path)
    got_plan = fields.get("selective_plan_checksum") or fields.get("plan_checksum") or ""
    got_disc = fields.get("discovery_artifact_checksum") or ""
    if got_plan.lower() != plan.lower() or got_disc.lower() != disc.lower():
        raise OsCoreError("READY_WRITE_VERIFY_FAIL")
    if not is_hex64(got_plan) or not is_hex64(got_disc):
        raise OsCoreError("READY_WRITE_VERIFY_FAIL empty_or_malformed")
    return ready_path


def verify_selective_ready_file(ready_path):
    """Fail closed unless READY carries two non-empty 64-hex provenance checksums."""
    if not ready_path or not os.path.isfile(ready_path):
        raise OsCoreError("SELECTIVE_READY_MISSING path=%s" % ready_path)
    fields = read_ready_fields(ready_path)
    plan = fields.get("selective_plan_checksum") or fields.get("plan_checksum") or ""
    disc = fields.get("discovery_artifact_checksum") or ""
    if not plan or not disc:
        raise OsCoreError("SELECTIVE_READY_EMPTY_CHECKSUM")
    if not is_hex64(plan):
        raise OsCoreError("SELECTIVE_READY_MALFORMED_PLAN")
    if not is_hex64(disc):
        raise OsCoreError("SELECTIVE_READY_MALFORMED_DISCOVERY")
    return {
        "selective_plan_checksum": plan.lower(),
        "discovery_artifact_checksum": disc.lower(),
        "source": fields.get("os_core_provenance_source") or "LEGACY_READY",
    }


def cmd_write_selective_ready(args):
    """Write selective/state/READY from a verified package root + payload tree."""
    pkg_root = os.path.abspath(args.package_root)
    selective_root = os.path.abspath(args.selective_root)
    payload_root = os.path.abspath(args.payload_root) if args.payload_root else None

    if os.path.basename(pkg_root) != PACKAGE_ROOT_NAME:
        raise OsCoreError("PACKAGE_ROOT_NAME_INVALID want=%s" % PACKAGE_ROOT_NAME)
    if not os.path.isfile(os.path.join(pkg_root, "manifest.json")):
        raise OsCoreError("MANIFEST_MISSING")
    if not os.path.isfile(os.path.join(pkg_root, "payload.sha256")):
        raise OsCoreError("PAYLOAD_SHA256_MISSING")
    # When payload is still inside the package root, re-validate the tree.
    if payload_root is None and os.path.isdir(os.path.join(pkg_root, "payload")):
        validate_package_tree(os.path.dirname(pkg_root))

    provenance = derive_os_core_provenance(pkg_root, payload_root=payload_root)
    ready_path = write_selective_ready_from_provenance(selective_root, provenance)
    print("OS_CORE_PROVENANCE_SOURCE=%s" % provenance["source"])
    print("OS_CORE_MANIFEST_SHA256=%s" % provenance["os_core_manifest_sha256"])
    print("OS_CORE_PAYLOAD_MANIFEST_SHA256=%s" % provenance["os_core_payload_manifest_sha256"])
    print("SELECTIVE_PLAN_CHECKSUM=%s" % provenance["selective_plan_checksum"])
    print("DISCOVERY_ARTIFACT_CHECKSUM=%s" % provenance["discovery_artifact_checksum"])
    print("SELECTIVE_READY_ACTION=%s" % provenance["action"])
    print("SELECTIVE_READY_VERIFY=PASS")
    print("SELECTIVE_READY_PATH=%s" % ready_path)


def cmd_verify_selective_ready(args):
    info = verify_selective_ready_file(os.path.abspath(args.ready_path))
    print("SELECTIVE_READY_VERIFY=PASS")
    print("OS_CORE_PROVENANCE_SOURCE=%s" % info.get("source", ""))
    print("SELECTIVE_PLAN_CHECKSUM=%s" % info["selective_plan_checksum"])
    print("DISCOVERY_ARTIFACT_CHECKSUM=%s" % info["discovery_artifact_checksum"])


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()



def is_safe_relpath(rel):
    if not rel or rel.startswith("/") or rel.startswith("\\"):
        return False
    parts = rel.replace("\\", "/").split("/")
    for p in parts:
        if p in ("", ".", ".."):
            return False
        if p.startswith(".."):
            return False
    return True


def reject_special_file(path):
    mode = os.lstat(path).st_mode
    if stat.S_ISCHR(mode) or stat.S_ISBLK(mode) or stat.S_ISFIFO(mode) or stat.S_ISSOCK(mode):
        raise OsCoreError("UNSAFE_FILE_TYPE path=%s" % path)
    if mode & (stat.S_ISUID | stat.S_ISGID):
        raise OsCoreError("SETUID_SETGID_FORBIDDEN path=%s" % path)


def resolve_within(root, rel):
    if not is_safe_relpath(rel):
        raise OsCoreError("UNSAFE_PATH path=%s" % rel)
    full = os.path.realpath(os.path.join(root, rel))
    root_real = os.path.realpath(root)
    if full != root_real and not full.startswith(root_real + os.sep):
        raise OsCoreError("PATH_ESCAPE path=%s" % rel)
    return full


def should_exclude(rel):
    low = rel.lower()
    for frag in EXCLUDE_NAME_FRAGMENTS:
        if frag.lower() in low:
            return True
    base = os.path.basename(rel)
    if base in ("current", "previous", "active", "staging"):
        return True
    if base.endswith(".private.gpg"):
        return True
    return False


def git_commit(project_root):
    try:
        out = subprocess.check_output(
            ["git", "-C", project_root, "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL,
        )
        return out.decode("utf-8", "replace").strip()
    except Exception:
        return "UNKNOWN"


def write_payload_sha256(payload_root, out_path):
    lines = []
    for dirpath, dirnames, filenames in os.walk(payload_root, followlinks=False):
        dirnames[:] = sorted(dirnames)
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            if not os.path.isfile(full):
                reject_special_file(full)
                continue
            reject_special_file(full)
            rel = os.path.relpath(full, payload_root).replace("\\", "/")
            if not is_safe_relpath(rel):
                raise OsCoreError("UNSAFE_PAYLOAD_PATH path=%s" % rel)
            lines.append("%s  %s" % (sha256_file(full), rel))
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
        if lines:
            fh.write("\n")
    return len(lines)


def verify_payload_sha256(payload_root, checksum_path):
    if not os.path.isfile(checksum_path):
        raise OsCoreError("PAYLOAD_SHA256_MISSING")
    expected = {}
    with open(checksum_path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            parts = line.split(None, 1)
            if len(parts) != 2:
                raise OsCoreError("PAYLOAD_SHA256_FORMAT line=%s" % line)
            digest, rel = parts
            if not re.match(r"^[0-9a-fA-F]{64}$", digest):
                raise OsCoreError("PAYLOAD_SHA256_HEX path=%s" % rel)
            if not is_safe_relpath(rel):
                raise OsCoreError("PAYLOAD_SHA256_UNSAFE_PATH path=%s" % rel)
            expected[rel] = digest.lower()

    actual = {}
    for dirpath, dirnames, filenames in os.walk(payload_root, followlinks=False):
        dirnames[:] = sorted(dirnames)
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            if not os.path.isfile(full):
                reject_special_file(full)
                continue
            reject_special_file(full)
            rel = os.path.relpath(full, payload_root).replace("\\", "/")
            actual[rel] = sha256_file(full)

    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    mismatch = sorted(r for r in expected if r in actual and expected[r] != actual[r])
    if missing or extra or mismatch:
        raise OsCoreError(
            "PAYLOAD_SHA256_FAIL missing=%s extra=%s mismatch=%s"
            % (missing[:5], extra[:5], mismatch[:5])
        )
    return len(actual)


def validate_symlinks(package_root, payload_root):
    """Allow only relative symlinks that stay inside payload_root."""
    for dirpath, dirnames, filenames in os.walk(payload_root, followlinks=False):
        for name in list(dirnames) + list(filenames):
            full = os.path.join(dirpath, name)
            if not os.path.islink(full):
                continue
            target = os.readlink(full)
            if target.startswith("/") or target.startswith("\\"):
                raise OsCoreError("ABSOLUTE_SYMLINK path=%s target=%s" % (full, target))
            # Resolve relative to link location; must remain under payload_root.
            link_dir = os.path.dirname(full)
            resolved = os.path.realpath(os.path.join(link_dir, target))
            payload_real = os.path.realpath(payload_root)
            if resolved != payload_real and not resolved.startswith(payload_real + os.sep):
                raise OsCoreError("SYMLINK_ESCAPE path=%s target=%s" % (full, target))


def validate_package_tree(extract_root):
    pkg = os.path.join(extract_root, PACKAGE_ROOT_NAME)
    if not os.path.isdir(pkg):
        raise OsCoreError("PACKAGE_ROOT_MISSING want=%s" % PACKAGE_ROOT_NAME)
    manifest_path = os.path.join(pkg, "manifest.json")
    payload_sum = os.path.join(pkg, "payload.sha256")
    payload_root = os.path.join(pkg, "payload")
    if not os.path.isfile(manifest_path):
        raise OsCoreError("MANIFEST_MISSING")
    if not os.path.isfile(payload_sum):
        raise OsCoreError("PAYLOAD_SHA256_MISSING")
    if not os.path.isdir(payload_root):
        raise OsCoreError("PAYLOAD_DIR_MISSING")

    with open(manifest_path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)
    if int(manifest.get("schema_version", -1)) != SCHEMA_VERSION:
        raise OsCoreError("MANIFEST_SCHEMA=FAIL")
    if manifest.get("artifact_type") != ARTIFACT_TYPE:
        raise OsCoreError("ARTIFACT_TYPE=FAIL")
    for hop in SUPPORTED_HOPS:
        hops_dir = os.path.join(payload_root, "hops", hop)
        if not os.path.isdir(hops_dir):
            raise OsCoreError("HOP_MISSING hop=%s" % hop)

    validate_symlinks(pkg, payload_root)
    count = verify_payload_sha256(payload_root, payload_sum)
    payload_bytes = 0
    for dirpath, _, filenames in os.walk(payload_root, followlinks=False):
        for name in filenames:
            full = os.path.join(dirpath, name)
            if os.path.isfile(full) and not os.path.islink(full):
                payload_bytes += os.path.getsize(full)
    if int(manifest.get("payload_file_count", -1)) != count:
        raise OsCoreError(
            "MANIFEST_COUNT_MISMATCH manifest=%s actual=%s"
            % (manifest.get("payload_file_count"), count)
        )
    if int(manifest.get("payload_bytes", -1)) != payload_bytes:
        raise OsCoreError(
            "MANIFEST_BYTES_MISMATCH manifest=%s actual=%s"
            % (manifest.get("payload_bytes"), payload_bytes)
        )
    return manifest


def copy_tree_safe(src, dst_root, rel_prefix=""):
    """Copy regular files and relative in-tree symlinks under dst_root/rel_prefix."""
    for dirpath, dirnames, filenames in os.walk(src, followlinks=False):
        rel_dir = os.path.relpath(dirpath, src)
        if rel_dir == ".":
            rel_dir = ""
        # Skip excluded directory names early
        keep = []
        for d in dirnames:
            cand = os.path.join(rel_dir, d).replace("\\", "/").lstrip("./")
            full_rel = "/".join(p for p in (rel_prefix, cand) if p)
            if should_exclude(full_rel) or d in ("staging", "current", "previous", "active"):
                continue
            keep.append(d)
        dirnames[:] = keep

        out_dir = os.path.join(dst_root, rel_prefix, rel_dir) if rel_dir else os.path.join(dst_root, rel_prefix)
        os.makedirs(out_dir, exist_ok=True)

        for name in filenames:
            src_path = os.path.join(dirpath, name)
            rel = os.path.join(rel_dir, name).replace("\\", "/") if rel_dir else name
            full_rel = "/".join(p for p in (rel_prefix, rel) if p).replace("\\", "/")
            if should_exclude(full_rel):
                continue
            if not is_safe_relpath(full_rel):
                raise OsCoreError("UNSAFE_SOURCE_PATH path=%s" % full_rel)
            dest = os.path.join(dst_root, full_rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            if os.path.islink(src_path):
                target = os.readlink(src_path)
                if target.startswith("/"):
                    # Skip absolute symlinks (e.g. accidental host links)
                    eprint("SKIP_ABSOLUTE_SYMLINK path=%s" % full_rel)
                    continue
                if os.path.lexists(dest):
                    os.unlink(dest)
                os.symlink(target, dest)
            elif os.path.isfile(src_path):
                reject_special_file(src_path)
                shutil.copy2(src_path, dest)
            else:
                reject_special_file(src_path)


def collect_from_selective_published(selective_root, payload_root):
    published = os.path.join(selective_root, "published")
    if not os.path.isdir(published):
        # Allow packaging directly from a published-like tree (tests).
        published = selective_root
    hops_src = os.path.join(published, "hops")
    if not os.path.isdir(hops_src):
        raise OsCoreError("SELECTIVE_HOPS_MISSING path=%s" % hops_src)
    for hop in SUPPORTED_HOPS:
        hop_src = os.path.join(hops_src, hop)
        if not os.path.isdir(hop_src):
            raise OsCoreError("HOP_SOURCE_MISSING hop=%s path=%s" % (hop, hop_src))
        copy_tree_safe(hop_src, payload_root, rel_prefix=os.path.join("hops", hop))

    shared_src = os.path.join(published, "shared")
    if os.path.isdir(shared_src):
        copy_tree_safe(shared_src, payload_root, rel_prefix="shared")

    # Prefer recreating the ubuntu alias as a relative symlink to jammy-to-noble.
    ubuntu_link = os.path.join(payload_root, "ubuntu")
    target = os.path.join("hops", "jammy-to-noble", "ubuntu")
    if os.path.isdir(os.path.join(payload_root, target)):
        if os.path.lexists(ubuntu_link):
            os.unlink(ubuntu_link)
        os.symlink(target, ubuntu_link)

    # Public selective key only (never private).
    keys_src = os.path.join(selective_root, "keys", "ubuntu-mirror-selective.gpg")
    if os.path.isfile(keys_src) and not os.path.islink(keys_src):
        keys_dst = os.path.join(payload_root, "keys")
        os.makedirs(keys_dst, exist_ok=True)
        shutil.copy2(keys_src, os.path.join(keys_dst, "ubuntu-mirror-selective.gpg"))


def payload_stats(payload_root):
    count = 0
    total = 0
    for dirpath, _, filenames in os.walk(payload_root, followlinks=False):
        for name in filenames:
            full = os.path.join(dirpath, name)
            if os.path.isfile(full) and not os.path.islink(full):
                count += 1
                total += os.path.getsize(full)
    return count, total


def gpg_detach_sign(payload_path, sig_path, private_key_path):
    homedir = tempfile.mkdtemp(prefix="os-core-sign-")
    try:
        subprocess.check_call(
            ["gpg", "--homedir", homedir, "--batch", "--import", private_key_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if os.path.exists(sig_path):
            os.unlink(sig_path)
        subprocess.check_call(
            [
                "gpg",
                "--homedir",
                homedir,
                "--batch",
                "--yes",
                "--armor",
                "--detach-sign",
                "-o",
                sig_path,
                payload_path,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    finally:
        shutil.rmtree(homedir, ignore_errors=True)


def gpgv_verify(public_key_path, sig_path, payload_path):
    with tempfile.TemporaryDirectory(prefix="os-core-gpgv-") as td:
        keyring = os.path.join(td, "key.gpg")
        # Accept either binary or ascii-armored public key.
        with open(public_key_path, "rb") as fh:
            data = fh.read()
        if data.startswith(b"-----BEGIN"):
            proc = subprocess.Popen(
                ["gpg", "--dearmor"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            out, err = proc.communicate(data)
            if proc.returncode != 0:
                raise OsCoreError("GPG_DEARMOR_FAIL")
            with open(keyring, "wb") as fh:
                fh.write(out)
        else:
            with open(keyring, "wb") as fh:
                fh.write(data)
        proc = subprocess.run(
            ["gpgv", "--keyring", keyring, sig_path, payload_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if proc.returncode != 0:
            raise OsCoreError("GPG_VERIFY_FAIL")


# Archive members allowed in the OS Core transport format: directories + regular
# files only. Symlinks/hardlinks/devices/FIFOs/sockets are rejected before any
# member is materialized (materialize recreates the ubuntu alias after extract).
_TAR_ALLOWED_TYPES = frozenset([
    tarfile.DIRTYPE,
    tarfile.REGTYPE,
    tarfile.AREGTYPE,
])
_TAR_SPECIAL_MEMBER_TYPES = frozenset([
    tarfile.BLKTYPE,
    tarfile.CHRTYPE,
    tarfile.FIFOTYPE,
    tarfile.SYMTYPE,
    tarfile.LNKTYPE,
])
if hasattr(tarfile, "SOCKTYPE"):
    _TAR_SPECIAL_MEMBER_TYPES = _TAR_SPECIAL_MEMBER_TYPES | {tarfile.SOCKTYPE}


def _normalized_tar_member_path(name):
    """Return cleaned member path or raise OsCoreError for unsafe names."""
    cleaned = (name or "").replace("\\", "/").rstrip("/")
    if not cleaned or cleaned.startswith("/") or cleaned.startswith("../"):
        raise OsCoreError("TAR_UNSAFE_MEMBER member=%s" % name)
    if cleaned.startswith("./"):
        cleaned = cleaned[2:]
        if not cleaned or cleaned.startswith("/"):
            raise OsCoreError("TAR_UNSAFE_MEMBER member=%s" % name)
    parts = [p for p in cleaned.split("/") if p not in ("", ".")]
    if not parts or any(p == ".." for p in parts):
        raise OsCoreError("TAR_UNSAFE_MEMBER member=%s" % name)
    cleaned = "/".join(parts)
    if not is_safe_relpath(cleaned):
        raise OsCoreError("TAR_UNSAFE_MEMBER member=%s" % name)
    return cleaned


def _reject_unsafe_tar_member(member):
    """Fail closed on links and special file types before extraction."""
    name = member.name
    if member.issym() or member.islnk():
        raise OsCoreError("TAR_UNSAFE_MEMBER member=%s type=link" % name)
    if member.type in _TAR_SPECIAL_MEMBER_TYPES:
        raise OsCoreError(
            "TAR_UNSAFE_MEMBER member=%s type=%s" % (name, member.type)
        )
    if member.type not in _TAR_ALLOWED_TYPES and not (
        member.isdir() or member.isreg() or member.isfile()
    ):
        raise OsCoreError(
            "TAR_UNSAFE_MEMBER member=%s type=%s" % (name, member.type)
        )
    mode = member.mode or 0
    if mode & (stat.S_ISUID | stat.S_ISGID):
        raise OsCoreError("TAR_UNSAFE_MEMBER member=%s setuid_setgid" % name)


def _tar_extract_target(dest_dir, cleaned):
    """Resolve member path under dest_dir; reject normalization escapes."""
    dest_real = os.path.realpath(dest_dir)
    target = os.path.normpath(os.path.join(dest_dir, cleaned))
    if target != dest_real and not target.startswith(dest_real + os.sep):
        raise OsCoreError("TAR_UNSAFE_MEMBER member=%s" % cleaned)
    return target


def safe_tar_create(src_dir, tar_path):
    """Create tar with ubuntu-os-core/ as top-level; dirs and regular files only."""
    parent = os.path.dirname(os.path.abspath(tar_path))
    os.makedirs(parent, exist_ok=True)
    tmp = tar_path + ".part"
    if os.path.exists(tmp):
        os.unlink(tmp)
    pkg = os.path.join(src_dir, PACKAGE_ROOT_NAME)
    if not os.path.isdir(pkg):
        raise OsCoreError("TAR_SOURCE_MISSING")

    try:
        with tarfile.open(tmp, "w") as tf:
            for dirpath, dirnames, filenames in os.walk(pkg, followlinks=False):
                # Do not descend into or archive symlink directories.
                dirnames[:] = sorted(
                    d for d in dirnames
                    if not os.path.islink(os.path.join(dirpath, d))
                )
                rel_dir = os.path.relpath(dirpath, src_dir).replace("\\", "/")
                if rel_dir == ".":
                    continue
                cleaned_dir = _normalized_tar_member_path(rel_dir)
                if not cleaned_dir.startswith(PACKAGE_ROOT_NAME):
                    raise OsCoreError("TAR_UNEXPECTED_MEMBER member=%s" % rel_dir)
                tf.add(dirpath, arcname=cleaned_dir, recursive=False)

                for name in sorted(filenames):
                    full = os.path.join(dirpath, name)
                    if os.path.islink(full):
                        # Omit in-tree aliases (e.g. payload/ubuntu); materialize
                        # recreates the alias after a verified extract.
                        continue
                    if not os.path.isfile(full):
                        reject_special_file(full)
                        continue
                    reject_special_file(full)
                    rel = os.path.relpath(full, src_dir).replace("\\", "/")
                    cleaned = _normalized_tar_member_path(rel)
                    if not cleaned.startswith(PACKAGE_ROOT_NAME):
                        raise OsCoreError("TAR_UNEXPECTED_MEMBER member=%s" % rel)
                    tf.add(full, arcname=cleaned, recursive=False)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

    # Re-scan created archive with the same pre-extract contract.
    with tarfile.open(tmp, "r:") as tf:
        for member in tf.getmembers():
            cleaned = _normalized_tar_member_path(member.name)
            if not cleaned.startswith(PACKAGE_ROOT_NAME):
                os.unlink(tmp)
                raise OsCoreError("TAR_UNEXPECTED_MEMBER member=%s" % member.name)
            try:
                _reject_unsafe_tar_member(member)
            except OsCoreError:
                os.unlink(tmp)
                raise
    os.rename(tmp, tar_path)


def safe_tar_extract(tar_path, dest_dir):
    """Extract OS Core archive after fail-closed path and member-type validation.

    Rejects absolute paths, parent traversal, path-normalization escapes, and all
    non directory/regular-file members (symlinks, hardlinks, devices, FIFOs,
    sockets, etc.) before any member is materialized under dest_dir.
    """
    os.makedirs(dest_dir, exist_ok=True)
    dest_real = os.path.realpath(dest_dir)

    with tarfile.open(tar_path, "r:*") as tf:
        members = tf.getmembers()
        # Pre-validate every member before writing anything.
        for member in members:
            cleaned = _normalized_tar_member_path(member.name)
            if not cleaned.startswith(PACKAGE_ROOT_NAME):
                raise OsCoreError("TAR_UNEXPECTED_MEMBER member=%s" % member.name)
            _reject_unsafe_tar_member(member)
            _tar_extract_target(dest_dir, cleaned)

        for member in members:
            cleaned = _normalized_tar_member_path(member.name)
            target = _tar_extract_target(dest_dir, cleaned)
            if member.isdir():
                os.makedirs(target, exist_ok=True)
                continue
            parent = os.path.dirname(target)
            os.makedirs(parent, exist_ok=True)
            parent_real = os.path.realpath(parent)
            if parent_real != dest_real and not parent_real.startswith(dest_real + os.sep):
                raise OsCoreError("TAR_UNSAFE_MEMBER member=%s" % member.name)
            src = tf.extractfile(member)
            if src is None:
                raise OsCoreError("TAR_EXTRACT_MISSING member=%s" % member.name)
            with open(target, "wb") as out:
                shutil.copyfileobj(src, out)


def cmd_build(args):
    selective_root = os.path.abspath(args.selective_root)
    output_dir = os.path.abspath(args.output_dir)
    release_id = args.release_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", release_id):
        raise OsCoreError("RELEASE_ID_INVALID=%s" % release_id)

    os.makedirs(output_dir, exist_ok=True)
    final_name = "ubuntu-os-core-xenial-to-noble-%s.tar" % release_id
    final_tar = os.path.join(output_dir, final_name)
    final_sha = final_tar + ".sha256"
    final_asc = final_sha + ".asc"
    if os.path.exists(final_tar) or os.path.exists(final_sha):
        raise OsCoreError("OUTPUT_EXISTS path=%s" % final_tar)

    build_tmp = tempfile.mkdtemp(prefix="os-core-build-")
    verify_tmp = tempfile.mkdtemp(prefix="os-core-verify-")
    try:
        pkg_root = os.path.join(build_tmp, PACKAGE_ROOT_NAME)
        payload_root = os.path.join(pkg_root, "payload")
        os.makedirs(payload_root, exist_ok=True)
        collect_from_selective_published(selective_root, payload_root)
        validate_symlinks(pkg_root, payload_root)
        payload_sum = os.path.join(pkg_root, "payload.sha256")
        file_count = write_payload_sha256(payload_root, payload_sum)
        count2, payload_bytes = payload_stats(payload_root)
        if count2 != file_count:
            raise OsCoreError("PAYLOAD_COUNT_INTERNAL")
        # Safety margin: package + extract + stage (~3x payload) + 512MiB
        required_free = payload_bytes * 3 + (512 * 1024 * 1024)
        discovery_ck = sha256_file(payload_sum)
        # Deterministic plan identity (excludes timestamps / mutable paths).
        plan_identity = {
            "artifact_type": ARTIFACT_TYPE,
            "schema_version": SCHEMA_VERSION,
            "supported_hops": list(SUPPORTED_HOPS),
            "supported_source_os": "16.04",
            "target_os": "24.04",
            "payload_file_count": file_count,
            "payload_bytes": payload_bytes,
            "discovery_artifact_checksum": discovery_ck,
        }
        selective_plan_ck = sha256_bytes(
            json.dumps(plan_identity, sort_keys=True, separators=(",", ":"))
        )
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "artifact_type": ARTIFACT_TYPE,
            "release_id": release_id,
            "created_at_utc": iso_now(),
            "source_repository_commit": git_commit(args.project_root),
            "supported_source_os": "16.04",
            "target_os": "24.04",
            "supported_hops": list(SUPPORTED_HOPS),
            "payload_file_count": file_count,
            "payload_bytes": payload_bytes,
            "required_free_bytes": required_free,
            "source_selective_root": "SELECTIVE_PUBLISHED",
            "selective_plan_checksum": selective_plan_ck,
            "discovery_artifact_checksum": discovery_ck,
        }
        with open(os.path.join(pkg_root, "manifest.json"), "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=2, sort_keys=True)
            fh.write("\n")

        verify_payload_sha256(payload_root, payload_sum)
        staging_tar = os.path.join(build_tmp, final_name)
        safe_tar_create(build_tmp, staging_tar)

        # Re-extract and re-verify
        safe_tar_extract(staging_tar, verify_tmp)
        validate_package_tree(verify_tmp)

        digest = sha256_file(staging_tar)
        with open(staging_tar + ".sha256", "w", encoding="utf-8") as fh:
            fh.write("%s  %s\n" % (digest, final_name))

        signed = False
        priv = args.signing_key
        if priv and os.path.isfile(priv):
            try:
                gpg_detach_sign(staging_tar + ".sha256", staging_tar + ".sha256.asc", priv)
                signed = True
            except Exception as exc:
                eprint("GPG_SIGN_SKIP reason=%s" % exc)

        # Atomic move into output_dir
        os.rename(staging_tar, final_tar)
        os.rename(staging_tar + ".sha256", final_sha)
        if signed and os.path.isfile(staging_tar + ".sha256.asc"):
            os.rename(staging_tar + ".sha256.asc", final_asc)

        print("OS_CORE_BUILD=PASS")
        print("PACKAGE=%s" % final_tar)
        print("PACKAGE_SHA256=%s" % digest)
        print("RELEASE_ID=%s" % release_id)
        print("PAYLOAD_FILE_COUNT=%s" % file_count)
        print("PAYLOAD_BYTES=%s" % payload_bytes)
        print("SELECTIVE_PLAN_CHECKSUM=%s" % selective_plan_ck)
        print("DISCOVERY_ARTIFACT_CHECKSUM=%s" % discovery_ck)
        print("SIGNATURE=%s" % ("YES" if signed else "NO"))
    finally:
        shutil.rmtree(build_tmp, ignore_errors=True)
        shutil.rmtree(verify_tmp, ignore_errors=True)


def cmd_verify(args):
    package = os.path.abspath(args.package)
    if not os.path.isfile(package) or os.path.islink(package):
        # Reject symlinks for transport artifacts
        if os.path.islink(package):
            raise OsCoreError("PACKAGE_SYMLINK_FORBIDDEN")
        raise OsCoreError("PACKAGE_MISSING path=%s" % package)

    sha_path = package + ".sha256"
    if not os.path.isfile(sha_path):
        raise OsCoreError("OUTER_SHA256_MISSING path=%s" % sha_path)
    with open(sha_path, "r", encoding="utf-8") as fh:
        line = fh.readline().strip()
    parts = line.split(None, 1)
    if len(parts) < 1 or not re.match(r"^[0-9a-fA-F]{64}$", parts[0]):
        raise OsCoreError("OUTER_SHA256_FORMAT")
    expected = parts[0].lower()
    actual = sha256_file(package)
    if expected != actual:
        raise OsCoreError("OUTER_SHA256_FAIL expected=%s actual=%s" % (expected, actual))
    print("OUTER_SHA256=PASS")

    asc_path = sha_path + ".asc"
    if os.path.isfile(asc_path):
        pub = args.public_key
        if not pub or not os.path.isfile(pub):
            raise OsCoreError("SIGNATURE_PRESENT_BUT_NO_PUBLIC_KEY")
        gpgv_verify(pub, asc_path, sha_path)
        print("SIGNATURE=PASS")
    else:
        print("SIGNATURE=ABSENT")

    extract_tmp = tempfile.mkdtemp(prefix="os-core-vfy-")
    try:
        safe_tar_extract(package, extract_tmp)
        manifest = validate_package_tree(extract_tmp)
        print("OS_CORE_VERIFY=PASS")
        print("RELEASE_ID=%s" % manifest.get("release_id", ""))
        print("PAYLOAD_FILE_COUNT=%s" % manifest.get("payload_file_count", 0))
        print("PAYLOAD_BYTES=%s" % manifest.get("payload_bytes", 0))
        print("REQUIRED_FREE_BYTES=%s" % manifest.get("required_free_bytes", 0))
    finally:
        shutil.rmtree(extract_tmp, ignore_errors=True)


def cmd_extract_staging(args):
    """Extract verified package into staging_dir/ubuntu-os-core (for installer)."""
    package = os.path.abspath(args.package)
    staging_dir = os.path.abspath(args.staging_dir)
    if os.path.islink(package):
        raise OsCoreError("PACKAGE_SYMLINK_FORBIDDEN")
    # Outer verify first
    ns = argparse.Namespace(
        package=package,
        public_key=args.public_key,
    )
    # Inline outer checks without printing full verify twice when called by engine
    sha_path = package + ".sha256"
    with open(sha_path, "r", encoding="utf-8") as fh:
        expected = fh.readline().strip().split(None, 1)[0].lower()
    if sha256_file(package) != expected:
        raise OsCoreError("OUTER_SHA256_FAIL")
    asc_path = sha_path + ".asc"
    if os.path.isfile(asc_path):
        if not args.public_key or not os.path.isfile(args.public_key):
            raise OsCoreError("SIGNATURE_PRESENT_BUT_NO_PUBLIC_KEY")
        gpgv_verify(args.public_key, asc_path, sha_path)

    if os.path.exists(staging_dir):
        raise OsCoreError("STAGING_EXISTS path=%s" % staging_dir)
    os.makedirs(staging_dir, exist_ok=True)
    safe_tar_extract(package, staging_dir)
    manifest = validate_package_tree(staging_dir)
    print("OS_CORE_EXTRACT=PASS")
    print("RELEASE_ID=%s" % manifest.get("release_id", ""))
    print("PAYLOAD_BYTES=%s" % manifest.get("payload_bytes", 0))
    print("REQUIRED_FREE_BYTES=%s" % manifest.get("required_free_bytes", 0))
    print("STAGING_DIR=%s" % staging_dir)


def main(argv=None):
    parser = argparse.ArgumentParser(description="OS Core package tools")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_build = sub.add_parser("build")
    p_build.add_argument("--selective-root", required=True)
    p_build.add_argument("--output-dir", required=True)
    p_build.add_argument("--project-root", default=".")
    p_build.add_argument("--release-id", default="")
    p_build.add_argument("--signing-key", default="")
    p_build.set_defaults(func=cmd_build)

    p_verify = sub.add_parser("verify")
    p_verify.add_argument("--package", required=True)
    p_verify.add_argument("--public-key", default="")
    p_verify.set_defaults(func=cmd_verify)

    p_extract = sub.add_parser("extract-staging")
    p_extract.add_argument("--package", required=True)
    p_extract.add_argument("--staging-dir", required=True)
    p_extract.add_argument("--public-key", default="")
    p_extract.set_defaults(func=cmd_extract_staging)

    p_ready = sub.add_parser("write-selective-ready")
    p_ready.add_argument("--package-root", required=True,
                         help="Path to extracted ubuntu-os-core/ directory")
    p_ready.add_argument("--selective-root", required=True,
                         help="Destination selective tree (payload/final_tmp)")
    p_ready.add_argument("--payload-root", default="",
                         help="Payload path when already moved out of package-root")
    p_ready.set_defaults(func=cmd_write_selective_ready)

    p_vready = sub.add_parser("verify-selective-ready")
    p_vready.add_argument("--ready-path", required=True)
    p_vready.set_defaults(func=cmd_verify_selective_ready)

    args = parser.parse_args(argv)
    # Normalize optional empty payload-root.
    if getattr(args, "payload_root", None) == "":
        args.payload_root = None
    try:
        args.func(args)
    except OsCoreError as exc:
        eprint("OS_CORE_ERROR=%s" % exc)
        return 1
    return 0


if __name__ == "__main__":
    # Python 3.6 compat: argparse required= on subparsers may need fallback
    if sys.version_info < (3, 7):
        # re-parse with manual required check
        pass
    try:
        sys.exit(main())
    except TypeError:
        # older argparse without required= on subparsers
        if len(sys.argv) < 2:
            print("usage: os_core_package.py <build|verify|extract-staging> ...", file=sys.stderr)
            sys.exit(2)
        sys.exit(main())
