#!/usr/bin/env python3
"""Exercise a bounded, non-destructive restore of a regular file from an OS-state archive.

This is a supplemental archive check, NOT a substitute for hypervisor snapshot restore.
Compatible with the Python 3 versions available throughout the Ubuntu LTS hop chain.
"""
from __future__ import print_function

import hashlib
import os
import sys
import tarfile
import tempfile

MAX_PROBE_BYTES = 4 * 1024 * 1024


def check(archive, state_rel):
    prefix = state_rel.strip("/")
    if not prefix or ".." in prefix.split("/"):
        raise ValueError("unsafe durable state root")

    seen_root = False
    restored_probe = None
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle:
            name = member.name.rstrip("/")
            if (member.name.startswith("/") or
                    ".." in member.name.split("/") or
                    (name != prefix and not name.startswith(prefix + "/"))):
                raise ValueError("unsafe or unexpected archive member")
            seen_root = True
            if restored_probe is not None:
                continue
            if not member.isfile() or member.size > MAX_PROBE_BYTES:
                continue

            source = bundle.extractfile(member)
            if source is None:
                raise ValueError("cannot read representative archive member")
            extracted_hash = hashlib.sha256()
            with tempfile.TemporaryFile() as scratch:
                remaining = member.size
                while remaining:
                    block = source.read(min(65536, remaining))
                    if not block:
                        raise ValueError("truncated representative archive member")
                    extracted_hash.update(block)
                    scratch.write(block)
                    remaining -= len(block)
                scratch.flush()
                scratch.seek(0)
                restored_hash = hashlib.sha256()
                while True:
                    block = scratch.read(65536)
                    if not block:
                        break
                    restored_hash.update(block)
                if extracted_hash.digest() != restored_hash.digest():
                    raise ValueError("representative restore content mismatch")
            restored_probe = (name, member.size)

    if not seen_root:
        raise ValueError("archive missing expected durable state root")
    if restored_probe is None:
        raise ValueError("no bounded regular file available for restore probe")
    print("ENGINEERING_STATE_RESTORE_PROBE=PASS path={} bytes={}".format(
        restored_probe[0], restored_probe[1]))


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("expected archive and state-relative path")
        check(sys.argv[1], sys.argv[2])
    except (ValueError, OSError, tarfile.TarError) as exc:
        print("ERROR: representative restore probe failed: {}".format(exc),
              file=sys.stderr)
        sys.exit(3)
