#!/usr/bin/env python3
"""Deterministic generator for hop-specific Menu 7 OS-hop launchers.

Produces four public launcher scripts from one template:

  dp-launch-xenial-to-bionic.sh
  dp-launch-bionic-to-focal.sh
  dp-launch-focal-to-jammy.sh
  dp-launch-jammy-to-noble.sh

and four operator-facing OS-hop wrappers that download/verify those launchers:

  upgrade-xenial-to-bionic.sh
  upgrade-bionic-to-focal.sh
  upgrade-focal-to-jammy.sh
  upgrade-jammy-to-noble.sh

Deterministic for the same template bytes, Mirror URL, signing fingerprint,
exact public-keyring SHA256, hop mapping, launcher schema version, and
resulting launcher SHA256. Never embeds timestamps, random values, temp
paths, hostnames, inodes, or private-key material.
"""
from __future__ import print_function

import argparse
import hashlib
import os
import re
import sys

LAUNCHER_SCHEMA_VERSION = "2"

HOPS = (
    ("xenial-to-bionic", "dp-offline-upgrade-xenial-to-bionic.sh"),
    ("bionic-to-focal", "dp-offline-upgrade-bionic-to-focal.sh"),
    ("focal-to-jammy", "dp-offline-upgrade-focal-to-jammy.sh"),
    ("jammy-to-noble", "dp-offline-upgrade-jammy-to-noble.sh"),
)

TEMPLATE_REL = "client/dp-client-hop-launcher.sh.in"

# Operator-facing bootstrap. Literal LAUNCHER_SHA256 is the inner trust anchor;
# Menu 7 separately pins this wrapper's own SHA256. Never curl|bash.
OS_UPGRADE_WRAPPER_TEMPLATE = """#!/usr/bin/env bash
set -euo pipefail
cd /home/aella
L='@@LAUNCHER@@'
D="${L}.download"
MIRROR='@@MIRROR_BASE@@'
LAUNCHER_SHA256='@@LAUNCHER_SHA256@@'
curl -fsSLo "$D" "${MIRROR}/client/${L}"
printf '%s  %s\\n' "$LAUNCHER_SHA256" "$D" | sha256sum -c -
mv -f "$D" "$L"
exec bash "./$L"
"""


def _sha_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _normalize_mirror(mirror_base_url):
    mirror = (mirror_base_url or "").rstrip("/")
    if not mirror:
        raise RuntimeError("LAUNCHER_MIRROR_BASE_MISSING")
    if "@@" in mirror:
        raise RuntimeError("LAUNCHER_MIRROR_BASE_INVALID")
    return mirror


def _normalize_fpr(signing_fingerprint):
    fpr = (signing_fingerprint or "").upper().replace(" ", "")
    if not re.match(r"^[0-9A-F]{40}$", fpr):
        raise RuntimeError("LAUNCHER_EXPECTED_FPR_INVALID")
    return fpr


def _normalize_keyring_sha256(keyring_sha256):
    digest = (keyring_sha256 or "").lower().replace(" ", "")
    if not re.match(r"^[0-9a-f]{64}$", digest):
        raise RuntimeError("LAUNCHER_EXPECTED_KEYRING_SHA256_INVALID")
    return digest


def render_launcher(
    template_text, mirror_base, expected_fpr, expected_keyring_sha256, hop, script
):
    text = template_text
    replacements = {
        "@@LAUNCHER_SCHEMA_VERSION@@": LAUNCHER_SCHEMA_VERSION,
        "@@MIRROR_BASE@@": mirror_base,
        "@@EXPECTED_FPR@@": expected_fpr,
        "@@EXPECTED_KEYRING_SHA256@@": expected_keyring_sha256,
        "@@HOP@@": hop,
        "@@SCRIPT@@": script,
    }
    for key, value in replacements.items():
        if key not in text:
            raise RuntimeError("LAUNCHER_TEMPLATE_PLACEHOLDER_MISSING=" + key)
        text = text.replace(key, value)
    if re.search(r"@@[A-Z0-9_]+@@", text):
        raise RuntimeError("LAUNCHER_TEMPLATE_UNREPLACED_PLACEHOLDER")
    if not text.startswith("#!/"):
        raise RuntimeError("LAUNCHER_TEMPLATE_SHEBANG_MISSING")
    # Normalize to LF-only for cross-platform determinism.
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if not text.endswith("\n"):
        text += "\n"
    return text


def render_os_upgrade_wrapper(mirror_base, hop, launcher_name, launcher_sha256):
    if not re.match(r"^[0-9a-f]{64}$", launcher_sha256):
        raise RuntimeError("LAUNCHER_SHA256_INVALID hop=" + hop)
    text = OS_UPGRADE_WRAPPER_TEMPLATE
    replacements = {
        "@@LAUNCHER@@": launcher_name,
        "@@MIRROR_BASE@@": mirror_base,
        "@@LAUNCHER_SHA256@@": launcher_sha256,
    }
    for key, value in replacements.items():
        if key not in text:
            raise RuntimeError("WRAPPER_TEMPLATE_PLACEHOLDER_MISSING=" + key)
        text = text.replace(key, value)
    if re.search(r"@@[A-Z0-9_]+@@", text):
        raise RuntimeError("WRAPPER_TEMPLATE_UNREPLACED_PLACEHOLDER")
    if not text.startswith("#!/"):
        raise RuntimeError("WRAPPER_TEMPLATE_SHEBANG_MISSING")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if not text.endswith("\n"):
        text += "\n"
    return text


def _write_sha256_sidecar(path, digest, name):
    sidecar = path + ".sha256"
    with open(sidecar, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("%s  %s\n" % (digest, name))
    os.chmod(sidecar, 0o644)
    return sidecar


def build_launchers(
    project_root,
    output_dir,
    mirror_base_url,
    signing_fingerprint,
    expected_keyring_sha256,
):
    root = os.path.abspath(project_root)
    out = os.path.abspath(output_dir)
    template_path = os.path.join(root, TEMPLATE_REL)
    if not os.path.isfile(template_path):
        raise RuntimeError("LAUNCHER_TEMPLATE_MISSING=" + TEMPLATE_REL)
    with open(template_path, "r", encoding="utf-8", errors="strict") as fh:
        template_text = fh.read()
    mirror = _normalize_mirror(mirror_base_url)
    fpr = _normalize_fpr(signing_fingerprint)
    keyring_sha = _normalize_keyring_sha256(expected_keyring_sha256)
    os.makedirs(out, exist_ok=True)
    results = []
    for hop, script in HOPS:
        body = render_launcher(template_text, mirror, fpr, keyring_sha, hop, script)
        name = "dp-launch-%s.sh" % hop
        path = os.path.join(out, name)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(body)
        os.chmod(path, 0o644)
        digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
        sidecar = _write_sha256_sidecar(path, digest, name)
        wrapper_name = "upgrade-%s.sh" % hop
        wrapper_body = render_os_upgrade_wrapper(mirror, hop, name, digest)
        wrapper_path = os.path.join(out, wrapper_name)
        with open(wrapper_path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(wrapper_body)
        os.chmod(wrapper_path, 0o644)
        wrapper_digest = hashlib.sha256(wrapper_body.encode("utf-8")).hexdigest()
        wrapper_sidecar = _write_sha256_sidecar(
            wrapper_path, wrapper_digest, wrapper_name
        )
        results.append(
            {
                "hop": hop,
                "script": script,
                "name": name,
                "path": path,
                "sha256": digest,
                "sidecar": sidecar,
                "wrapper_name": wrapper_name,
                "wrapper_path": wrapper_path,
                "wrapper_sha256": wrapper_digest,
                "wrapper_sidecar": wrapper_sidecar,
            }
        )
    return results


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--mirror-base-url", required=True)
    parser.add_argument("--signing-fingerprint", required=True)
    parser.add_argument(
        "--expected-keyring-sha256",
        required=True,
        help="SHA256 of the exact public-keyring.gpg bytes to pin into launchers",
    )
    parser.add_argument(
        "--print-env",
        action="store_true",
        help="Emit LAUNCHER_* evidence lines after generation",
    )
    args = parser.parse_args(argv)
    try:
        results = build_launchers(
            args.project_root,
            args.output_dir,
            args.mirror_base_url,
            args.signing_fingerprint,
            args.expected_keyring_sha256,
        )
        if args.print_env:
            print("LAUNCHER_SCHEMA_VERSION=%s" % LAUNCHER_SCHEMA_VERSION)
            print("LAUNCHER_COUNT=%s" % len(results))
            print(
                "LAUNCHER_EXPECTED_KEYRING_SHA256=%s"
                % _normalize_keyring_sha256(args.expected_keyring_sha256)
            )
            for item in results:
                print(
                    "LAUNCHER_BUILT hop=%s name=%s sha256=%s"
                    % (item["hop"], item["name"], item["sha256"])
                )
                print(
                    "WRAPPER_BUILT hop=%s name=%s sha256=%s"
                    % (item["hop"], item["wrapper_name"], item["wrapper_sha256"])
                )
            print("LAUNCHER_BUILD=PASS")
            print("OS_UPGRADE_WRAPPER_BUILD=PASS")
        return 0
    except Exception as exc:
        print("LAUNCHER_BUILD=FAIL", file=sys.stderr)
        print("LAUNCHER_BUILD_REASON=%s" % str(exc).replace("\n", " "), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
