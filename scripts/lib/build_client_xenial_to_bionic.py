#!/usr/bin/env python3
"""Build the single-file Xenial→Bionic offline DP upgrade client artifact.

Does not materialize/publish the selective repository or mutate READY.
Writes client artifacts under a separate directory (default: artifacts/client/).
"""
from __future__ import print_function

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from collections import OrderedDict
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
import client_build_repository as cbr
import client_build_provenance as cbp
import assert_client_executable_shebang as aces


HOP = "xenial-to-bionic"
SOURCE_CODENAME = "xenial"
TARGET_CODENAME = "bionic"
SOURCE_VERSION = "16.04"
TARGET_VERSION = "18.04"
PROFILE_NAME = "offline-upgrade-selective"
KEYRING_INSTALL_PATH = "/etc/apt/trusted.gpg.d/stellar-offline-xenial-to-bionic.gpg"
CONFIRM_PHRASE = "UPGRADE-XENIAL-TO-BIONIC"
EXTERNAL_HOST_RE = re.compile(
    r"(archive|security|old-releases|changelogs)\.ubuntu\.com|api\.snapcraft\.io",
    re.I,
)
UNSIGNED_TEST_MARKER = "UNSIGNED" + "_TEST"
PRODUCTION_CLIENT_REL = os.path.join("artifacts", "client")
UNSIGNED_TEST_CLIENT_REL = os.path.join("artifacts", "client-unsigned-test")
CLIENT_SIGNING_PRIV_REL = os.path.join(
    "config", "client-signing", "offline-client-manifest.private.gpg"
)
CLIENT_SIGNING_PUB_REL = os.path.join(
    "config", "client-signing", "offline-client-manifest.gpg"
)


class BuildError(Exception):
    pass


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_release_components(release_text):
    for line in release_text.splitlines():
        if line.startswith("Components:"):
            comps = line.split(":", 1)[1].strip().split()
            if not comps:
                raise BuildError("empty Components in Release")
            return comps
    raise BuildError("Components field missing from Release")


def dearmor_key(key_bytes):
    """Return binary OpenPGP key material suitable for apt signed-by / gpgv."""
    if key_bytes.startswith(b"-----BEGIN"):
        proc = subprocess.run(
            ["gpg", "--dearmor"],
            input=key_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode != 0 or not proc.stdout:
            raise BuildError("gpg --dearmor failed: {}".format(proc.stderr.decode()))
        return proc.stdout
    return key_bytes


def key_fingerprint(key_bytes):
    """Return 40-char uppercase fingerprint from public key bytes."""
    dearmed = dearmor_key(key_bytes)
    with tempfile.NamedTemporaryFile(prefix="selkey-", suffix=".gpg") as tmp:
        tmp.write(dearmed)
        tmp.flush()
        proc = subprocess.run(
            [
                "gpg",
                "--no-default-keyring",
                "--keyring",
                tmp.name,
                "--with-colons",
                "--fingerprint",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    if proc.returncode != 0:
        raise BuildError("fingerprint failed: {}".format(proc.stderr.decode()))
    for line in proc.stdout.decode().splitlines():
        if line.startswith("fpr:"):
            fpr = line.split(":")[9]
            if len(fpr) >= 40:
                return fpr[-40:].upper()
    raise BuildError("no fingerprint in key")


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


def build_meta_release_lts(mirror_base, hop, announcement_name="ReleaseAnnouncement"):
    """Build local-only meta-release-lts for Xenial to Bionic (no Canonical hosts).

    Client-generated /etc/update-manager/meta-release INI must stay ASCII-only for
    Xenial Python 3.5 configparser under POSIX locale. Dist-format bodies here may
    still carry upstream UTF-8 Description text.
    """
    mb = mirror_base.rstrip("/")
    hop_ubuntu = "{}/hops/{}/ubuntu".format(mb, hop)
    # Include current + target so update-manager can resolve LTS prompt.
    xenial = OrderedDict(
        [
            ("Dist", "xenial"),
            ("Name", "Xenial Xerus"),
            ("Version", "16.04.7 LTS"),
            ("Date", "Thu, 21 April 2016 16:04:00 UTC"),
            ("Supported", "1"),
            ("Description", "This is the 16.04.7 LTS release"),
            ("Release-File", "{}/dists/xenial/Release".format(hop_ubuntu)),
            (
                "ReleaseNotes",
                "{}/client/{}/{}".format(mb, hop, announcement_name),
            ),
            (
                "UpgradeTool",
                "{}/offline/release-upgraders/bionic/bionic.tar.gz".format(mb),
            ),
            (
                "UpgradeToolSignature",
                "{}/offline/release-upgraders/bionic/bionic.tar.gz.gpg".format(mb),
            ),
        ]
    )
    bionic = OrderedDict(
        [
            ("Dist", "bionic"),
            ("Name", "Bionic Beaver"),
            ("Version", "18.04.6 LTS"),
            ("Date", "Thu, 26 April 2018 18:04:00 UTC"),
            ("Supported", "1"),
            ("Description", "This is the 18.04.6 LTS release"),
            ("Release-File", "{}/dists/bionic/Release".format(hop_ubuntu)),
            (
                "ReleaseNotes",
                "{}/client/{}/{}".format(mb, hop, announcement_name),
            ),
            (
                "ReleaseNotesHtml",
                "{}/client/{}/ReleaseAnnouncement.html".format(mb, hop),
            ),
            (
                "UpgradeTool",
                "{}/offline/release-upgraders/bionic/bionic.tar.gz".format(mb),
            ),
            (
                "UpgradeToolSignature",
                "{}/offline/release-upgraders/bionic/bionic.tar.gz.gpg".format(mb),
            ),
        ]
    )
    blocks = []
    for entry in (xenial, bionic):
        lines = ["{}: {}".format(k, v) for k, v in entry.items()]
        blocks.append("\n".join(lines))
    text = "\n\n".join(blocks) + "\n"
    if EXTERNAL_HOST_RE.search(text):
        raise BuildError("generated meta-release still contains external hosts")
    return text



def resolve_upgrader_tar(selective_root, codename):
    """Prefer direct selective/shared layout; fall back to legacy current/shared."""
    rel = os.path.join(
        "shared", "offline", "release-upgraders", codename, codename + ".tar.gz"
    )
    direct = os.path.join(selective_root, rel)
    legacy = os.path.join(selective_root, "current", rel)
    if os.path.isfile(direct):
        return direct
    if os.path.isfile(legacy):
        return legacy
    return direct


def extract_announcements(upgrader_tar_path, dest_dir):
    os.makedirs(dest_dir, exist_ok=True)
    names = ("ReleaseAnnouncement", "ReleaseAnnouncement.html")
    extracted = {}
    with tarfile.open(upgrader_tar_path, "r:gz") as tf:
        for name in names:
            try:
                member = tf.getmember("./" + name)
            except KeyError:
                try:
                    member = tf.getmember(name)
                except KeyError:
                    continue
            fh = tf.extractfile(member)
            if fh is None:
                continue
            data = fh.read()
            out = os.path.join(dest_dir, name)
            with open(out, "wb") as out_fh:
                out_fh.write(data)
            extracted[name] = sha256_bytes(data)
    if "ReleaseAnnouncement" not in extracted:
        raise BuildError("ReleaseAnnouncement missing from upgrader tar")
    return extracted


def gpg_detach_sign(private_key_path, payload_path, sig_path):
    homedir = tempfile.mkdtemp(prefix="client-sign-")
    try:
        proc = subprocess.run(
            ["gpg", "--homedir", homedir, "--batch", "--import", private_key_path],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if proc.returncode != 0:
            raise BuildError(
                "gpg import failed: {}".format(proc.stderr.decode("utf-8", "replace"))
            )
        if os.path.exists(sig_path):
            os.remove(sig_path)
        proc = subprocess.run(
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
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if proc.returncode != 0:
            raise BuildError(
                "gpg detach-sign failed: {}".format(proc.stderr.decode("utf-8", "replace"))
            )
    finally:
        shutil.rmtree(homedir, ignore_errors=True)


def production_client_dir(project_root):
    return os.path.abspath(os.path.join(project_root, PRODUCTION_CLIENT_REL))


def unsigned_test_client_dir(project_root):
    return os.path.abspath(os.path.join(project_root, UNSIGNED_TEST_CLIENT_REL))


def is_production_output_dir(project_root, output_dir):
    """True when output_dir is the production artifacts/client tree."""
    prod = production_client_dir(project_root)
    out = os.path.abspath(output_dir)
    return out == prod or out.startswith(prod + os.sep)


def client_signing_paths(project_root, private_key=None, public_key=None):
    """Resolve signing key paths for this build.

    Precedence:
      1. Explicit private_key/public_key arguments
      2. CLIENT_SIGNING_PRIVATE_KEY / CLIENT_SIGNING_PUBLIC_KEY env
      3. CLIENT_SIGNING_KEY_DIR/{private.gpg,public.gpg} (per-mirror install)
      4. CLIENT_SIGNING_KEY_DIR/offline-client-manifest.{private.,}gpg
      5. <project-root>/config/client-signing/offline-client-manifest.*
    """
    env_priv = os.environ.get("CLIENT_SIGNING_PRIVATE_KEY", "").strip()
    env_pub = os.environ.get("CLIENT_SIGNING_PUBLIC_KEY", "").strip()
    key_dir = os.environ.get("CLIENT_SIGNING_KEY_DIR", "").strip()
    priv = private_key or env_priv
    pub = public_key or env_pub
    if not priv or not pub:
        if key_dir:
            cand_priv = os.path.join(key_dir, "private.gpg")
            cand_pub = os.path.join(key_dir, "public.gpg")
            legacy_priv = os.path.join(key_dir, "offline-client-manifest.private.gpg")
            legacy_pub = os.path.join(key_dir, "offline-client-manifest.gpg")
            if os.path.isfile(cand_priv) and os.path.isfile(cand_pub):
                priv = priv or cand_priv
                pub = pub or cand_pub
            elif os.path.isfile(legacy_priv) and os.path.isfile(legacy_pub):
                priv = priv or legacy_priv
                pub = pub or legacy_pub
    if not priv or not pub:
        priv = os.path.join(project_root, CLIENT_SIGNING_PRIV_REL)
        pub = os.path.join(project_root, CLIENT_SIGNING_PUB_REL)
    return priv, pub


def resolve_production_manifest_signing_key(project_root, private_key=None, public_key=None):
    """Return (private_path, public_bytes, fingerprint) for manifest signing.

    Uses the local Mirror install keypair (or test override). Never auto-generates
    and never falls back to the selective repository private key.
    """
    priv, pub = client_signing_paths(project_root, private_key, public_key)
    if not os.path.isfile(priv) or not os.access(priv, os.R_OK):
        raise BuildError(
            "client manifest signing key missing or unreadable: {}".format(priv)
        )
    if not os.path.isfile(pub) or not os.access(pub, os.R_OK):
        raise BuildError(
            "client manifest public key missing or unreadable: {}".format(pub)
        )
    pub_raw = open(pub, "rb").read()
    return priv, pub_raw, key_fingerprint(pub_raw)

def ensure_manifest_signing_key(project_root, allow_generate=False):
    """Return (private_path, public_bytes) for client-manifest signing.

    Production builds must call resolve_production_manifest_signing_key() instead.
    When allow_generate is True (test helpers only), missing keys may be created
    under config/client-signing/ — never used for production artifacts/client.
    """
    signing_dir = os.path.join(project_root, "config", "client-signing")
    os.makedirs(signing_dir, exist_ok=True)
    priv, pub = client_signing_paths(project_root)
    if os.path.isfile(priv) and os.path.isfile(pub):
        return priv, open(pub, "rb").read()
    if not allow_generate:
        raise BuildError(
            "client manifest signing key missing (generation disabled): {}".format(priv)
        )

    homedir = tempfile.mkdtemp(prefix="client-keygen-")
    try:
        batch = os.path.join(homedir, "batch")
        with open(batch, "w", encoding="utf-8") as fh:
            fh.write(
                "Key-Type: RSA\nKey-Length: 2048\nName-Real: Stellar Offline Client Manifest\n"
                "Name-Email: offline-client-manifest@local\nExpire-Date: 0\n%no-protection\n%commit\n"
            )
        subprocess.run(
            ["gpg", "--homedir", homedir, "--batch", "--gen-key", batch],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        subprocess.run(
            [
                "gpg",
                "--homedir",
                homedir,
                "--batch",
                "--export-secret-keys",
                "--armor",
                "-o",
                priv,
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        subprocess.run(
            ["gpg", "--homedir", homedir, "--batch", "--export", "-o", pub],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        os.chmod(priv, 0o600)
        os.chmod(pub, 0o644)
    finally:
        shutil.rmtree(homedir, ignore_errors=True)
    return priv, open(pub, "rb").read()


def extract_pinned_b64(script_text, pin_name):
    """Extract a PIN_<name>='...' single-quoted value (may be multiline)."""
    token = "PIN_{}='".format(pin_name)
    start = script_text.find(token)
    if start < 0:
        raise BuildError("pin {} missing from client artifact".format(pin_name))
    start += len(token)
    end = script_text.find("'", start)
    if end < 0:
        raise BuildError("pin {} is not terminated".format(pin_name))
    return script_text[start:end]


def decode_pinned_b64(script_text, pin_name):
    raw = extract_pinned_b64(script_text, pin_name)
    compact = re.sub(r"\s+", "", raw)
    try:
        return base64.b64decode(compact)
    except Exception as exc:
        raise BuildError("pin {} base64 decode failed: {}".format(pin_name, exc))


def count_unsigned_test(data):
    if isinstance(data, bytes):
        return data.count(UNSIGNED_TEST_MARKER.encode("ascii"))
    return data.count(UNSIGNED_TEST_MARKER)


def gpgv_verify(key_bin, sig_bytes, payload_bytes):
    """Verify detached armored/binary signature; raise BuildError on failure."""
    with tempfile.TemporaryDirectory(prefix="client-gpgv-") as td:
        key_path = os.path.join(td, "key.gpg")
        sig_path = os.path.join(td, "payload.asc")
        payload_path = os.path.join(td, "payload")
        with open(key_path, "wb") as fh:
            if key_bin.startswith(b"-----BEGIN"):
                fh.write(dearmor_key(key_bin))
            else:
                fh.write(key_bin)
        with open(sig_path, "wb") as fh:
            fh.write(sig_bytes)
        with open(payload_path, "wb") as fh:
            fh.write(payload_bytes)
        proc = subprocess.run(
            ["gpgv", "--keyring", key_path, sig_path, payload_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode != 0:
            raise BuildError(
                "gpgv verification failed: {}".format(
                    proc.stderr.decode("utf-8", "replace")
                )
            )


def verify_client_artifact_signature(script_path, allowed_fingerprint=None):
    """Extract embedded manifest/sig/key and verify production signature.

    Returns dict with fingerprint and unsigned_test_count.
    """
    script_text = open(script_path, "r", encoding="utf-8", errors="replace").read()
    unsigned_count = count_unsigned_test(script_text)
    manifest = decode_pinned_b64(script_text, "MANIFEST_B64")
    sig = decode_pinned_b64(script_text, "MANIFEST_SIG_B64")
    key = decode_pinned_b64(script_text, "MANIFEST_KEY_B64")
    pin_fpr = extract_pinned_b64(script_text, "MANIFEST_KEY_FINGERPRINT").strip().upper()
    unsigned_count += count_unsigned_test(sig)
    if unsigned_count:
        raise BuildError(
            "UNSIGNED_TEST present in client artifact (count={})".format(unsigned_count)
        )
    if not sig or not manifest or not key:
        raise BuildError("embedded manifest signature material missing")
    if UNSIGNED_TEST_MARKER.encode("ascii") in sig:
        raise BuildError("embedded manifest signature is UNSIGNED_TEST")
    key_fpr = key_fingerprint(key)
    if pin_fpr != key_fpr:
        raise BuildError(
            "embedded manifest key fingerprint mismatch pin={} key={}".format(
                pin_fpr, key_fpr
            )
        )
    if allowed_fingerprint and key_fpr != allowed_fingerprint.upper():
        raise BuildError(
            "manifest signer fingerprint not allowed: got {} want {}".format(
                key_fpr, allowed_fingerprint.upper()
            )
        )
    gpgv_verify(key, sig, manifest)
    return {
        "fingerprint": key_fpr,
        "unsigned_test_count": 0,
        "manifest_sha256": sha256_bytes(manifest),
    }


def first_pool_filename_from_packages_gz(packages_gz_bytes):
    import gzip

    text = gzip.decompress(packages_gz_bytes).decode("utf-8", "replace")
    for line in text.splitlines():
        if line.startswith("Filename:"):
            return line.split(":", 1)[1].strip()
    raise BuildError("no Filename in Packages.gz")


def render_script(template_path, replacements):
    with open(template_path, "r", encoding="utf-8") as fh:
        body = fh.read()
    helper_token = "@@DESTRUCTIVE_CONFIRMATION_HELPER@@"
    helper_path = os.path.join(
        os.path.dirname(os.path.abspath(template_path)),
        "lib",
        "dp-offline-destructive-confirmation.sh",
    )
    if helper_token not in body:
        raise BuildError("template missing token {}".format(helper_token))
    if not os.path.isfile(helper_path):
        raise BuildError("missing confirmation helper: {}".format(helper_path))
    with open(helper_path, "r", encoding="utf-8") as fh:
        helper_body = fh.read().rstrip("\n") + "\n"
    body = body.replace(helper_token, helper_body)
    recon_token = "@@RELEASE_UPGRADE_RECONCILIATION_HELPER@@"
    recon_path = os.path.join(
        os.path.dirname(os.path.abspath(template_path)),
        "lib",
        "dp-offline-release-upgrade-reconciliation.sh",
    )
    if recon_token not in body:
        raise BuildError("template missing token {}".format(recon_token))
    if not os.path.isfile(recon_path):
        raise BuildError("missing reconciliation helper: {}".format(recon_path))
    with open(recon_path, "r", encoding="utf-8") as fh:
        recon_body = fh.read().rstrip("\n") + "\n"
    body = body.replace(recon_token, recon_body)
    apt_token = "@@APT_PREFLIGHT_SANDBOX_HELPER@@"
    apt_path = os.path.join(
        os.path.dirname(os.path.abspath(template_path)),
        "lib",
        "dp-offline-apt-preflight-sandbox.sh",
    )
    if apt_token not in body:
        raise BuildError("template missing token {}".format(apt_token))
    if not os.path.isfile(apt_path):
        raise BuildError("missing APT preflight sandbox helper: {}".format(apt_path))
    with open(apt_path, "r", encoding="utf-8") as fh:
        apt_body = fh.read().rstrip("\n") + "\n"
    body = body.replace(apt_token, apt_body)
    durable_token = "@@DURABLE_WRITE_HELPER@@"
    durable_path = os.path.join(
        os.path.dirname(os.path.abspath(template_path)),
        "lib",
        "dp-offline-durable-write.sh",
    )
    if durable_token not in body:
        raise BuildError("template missing token {}".format(durable_token))
    if not os.path.isfile(durable_path):
        raise BuildError("missing durable-write helper: {}".format(durable_path))
    with open(durable_path, "r", encoding="utf-8") as fh:
        durable_body = fh.read().rstrip("\n") + "\n"
    body = body.replace(durable_token, durable_body)

    aws_token = "@@AWS_KERNEL_GATE_LIB@@"
    aws_path = os.path.join(
        os.path.dirname(os.path.abspath(template_path)),
        "dp-postboot-aws-kernel-gate.sh.inc",
    )
    if aws_token not in body:
        raise BuildError("template missing token {}".format(aws_token))
    if not os.path.isfile(aws_path):
        raise BuildError("missing AWS kernel gate helper: {}".format(aws_path))
    with open(aws_path, "r", encoding="utf-8") as fh:
        aws_body = fh.read().rstrip("\n") + "\n"
    body = body.replace(aws_token, aws_body)

    source_token = "@@SOURCE_PRODUCT_HELPER@@"
    if source_token in body:
        source_path = os.path.join(
            os.path.dirname(os.path.abspath(template_path)),
            "lib",
            "dp-offline-source-product-version.sh",
        )
        if not os.path.isfile(source_path):
            raise BuildError("missing source-product helper: {}".format(source_path))
        with open(source_path, "r", encoding="utf-8") as fh:
            source_body = fh.read().rstrip("\n") + "\n"
        body = body.replace(source_token, source_body)

    lxd_token = "@@LXD_INVENTORY_HELPER@@"
    if lxd_token in body:
        lxd_path = os.path.join(
            os.path.dirname(os.path.abspath(template_path)),
            "lib",
            "dp-offline-lxd-inventory.sh",
        )
        if not os.path.isfile(lxd_path):
            raise BuildError("missing LXD inventory helper: {}".format(lxd_path))
        with open(lxd_path, "r", encoding="utf-8") as fh:
            lxd_body = fh.read().rstrip("\n") + "\n"
        body = body.replace(lxd_token, lxd_body)
    for key, value in replacements.items():
        token = "@@{}@@".format(key)
        if token not in body:
            raise BuildError("template missing token {}".format(token))
        body = body.replace(token, value)
    leftover = re.findall(r"@@[A-Z0-9_]+@@", body)
    if leftover:
        raise BuildError("unreplaced template tokens: {}".format(", ".join(leftover)))
    return body


def bash_single_quote(s):
    return "'" + s.replace("'", "'\"'\"'") + "'"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--project-root", required=True)
    ap.add_argument("--mirror-base", required=True, help="local Mirror HTTP base, e.g. http://192.0.2.10")

    ap.add_argument("--signing-private-key", default="",
                    help="local Mirror private signing key (or CLIENT_SIGNING_PRIVATE_KEY)")
    ap.add_argument("--signing-public-key", default="",
                    help="local Mirror public signing key (or CLIENT_SIGNING_PUBLIC_KEY)")
    ap.add_argument(
        "--selective-root",
        default="/var/spool/apt-mirror/selective",
        help="local selective root for keys/READY/upgraders",
    )
    ap.add_argument(
        "--output-dir",
        default="",
        help="default: <project-root>/artifacts/client",
    )
    ap.add_argument(
        "--template",
        default="",
        help="default: client/dp-offline-upgrade-xenial-to-bionic.sh.in",
    )
    ap.add_argument(
        "--deploy-nginx-root",
        default="",
        help="optional directory nginx /client/ will alias (copy artifacts here)",
    )
    ap.add_argument(
        "--skip-sign",
        action="store_true",
        help="emit UNSIGNED_TEST placeholder (test paths only; never artifacts/client)",
    )
    ap.add_argument(
        "--content-source",
        choices=("local-fs", "http"),
        default="local-fs",
        help="local-fs (production default) or http (diagnostic only)",
    )
    args = ap.parse_args(argv)

    project_root = os.path.abspath(args.project_root)
    mirror_base = args.mirror_base.rstrip("/")
    selective_root = args.selective_root
    if args.skip_sign:
        default_out = unsigned_test_client_dir(project_root)
    else:
        default_out = production_client_dir(project_root)
    out_dir = os.path.abspath(args.output_dir or default_out)
    if args.skip_sign:
        if is_production_output_dir(project_root, out_dir):
            raise BuildError(
                "--skip-sign refuses production output dir {}".format(out_dir)
            )
        if args.deploy_nginx_root:
            raise BuildError("--skip-sign refuses --deploy-nginx-root")
        nginx_probe = os.path.abspath(args.deploy_nginx_root) if args.deploy_nginx_root else ""
        if nginx_probe and (
            nginx_probe == "/var/spool/apt-mirror/client"
            or nginx_probe.startswith("/var/spool/apt-mirror/client" + os.sep)
        ):
            raise BuildError("--skip-sign refuses nginx client path")
    elif args.output_dir and not is_production_output_dir(project_root, out_dir):
        # Signed builds may still target temp dirs (unit tests); production path
        # is the default. Non-production signed builds are allowed.
        pass
    hop_out = os.path.join(out_dir, HOP)
    template = args.template or os.path.join(
        project_root, "client", "dp-offline-upgrade-xenial-to-bionic.sh.in"
    )
    if not os.path.isfile(template):
        raise BuildError("template not found: {}".format(template))

    key_path = os.path.join(selective_root, "keys", "ubuntu-mirror-selective.gpg")
    ready_path = os.path.join(selective_root, "state", "READY")
    upgrader_tar = resolve_upgrader_tar(selective_root, "bionic")
    upgrader_gpg = upgrader_tar + ".gpg"

    for path in (key_path, upgrader_tar, upgrader_gpg):
        if not os.path.isfile(path):
            raise BuildError("required file missing: {}".format(path))

    os.makedirs(hop_out, exist_ok=True)

    key_raw = open(key_path, "rb").read()
    key_bin = dearmor_key(key_raw)
    key_sha = sha256_bytes(key_bin)
    fingerprint = key_fingerprint(key_raw)

    print("CLIENT_BUILD_CONTENT_SOURCE={}".format(args.content_source.upper().replace("-", "_") if args.content_source != "local-fs" else "LOCAL_FILESYSTEM"))
    print("CLIENT_BUILD_NETWORK_REQUIRED={}".format("YES" if args.content_source == "http" else "NO"))
    print("CLIENT_BUILD_MIRROR_URL_PURPOSE=RUNTIME_PIN_ONLY")
    try:
        hop_repo = cbr.LocalHopRepository(
            selective_root,
            HOP,
            SOURCE_CODENAME,
            TARGET_CODENAME,
            mirror_base=mirror_base,
            content_source=args.content_source,
        )
        build_inputs = hop_repo.load_build_inputs(key_bin)
    except cbr.RepositoryError as exc:
        raise BuildError(str(exc))
    components = build_inputs["components"]
    suites = build_inputs["suites"]
    source_suites = build_inputs["source_suites"]
    target_suites = build_inputs["target_suites"]
    sample_deb_rel = build_inputs["sample_deb_rel"]
    sample_deb_url = build_inputs["sample_deb_url"]

    announcements = extract_announcements(upgrader_tar, hop_out)
    meta_text = build_meta_release_lts(mirror_base, HOP)
    meta_path = os.path.join(hop_out, "meta-release-lts")
    with open(meta_path, "w", encoding="utf-8") as fh:
        fh.write(meta_text)
    meta_sha = sha256_file(meta_path)

    up_tar_sha = sha256_file(upgrader_tar)
    up_gpg_sha = sha256_file(upgrader_gpg)

    ready = cbr.validate_ready_provenance(ready_path)
    plan_checksum = (
        ready.get("selective_plan_checksum")
        or ready.get("plan_checksum")
        or ""
    )
    discovery_checksum = ready.get("discovery_artifact_checksum") or ""

    generated_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    repo_base = "{}/hops/{}/ubuntu".format(mirror_base, HOP)

    # Resolve manifest signing key before writing manifest JSON.
    # Production always uses config/client-signing (never selective private,
    # never auto-generated keys).
    manifest_key_bin = key_bin
    manifest_key_fpr = fingerprint
    manifest_key_sha = key_sha
    sign_priv = None
    allowed_production_fpr = None
    if not args.skip_sign:
        sign_priv, manifest_pub_raw, manifest_key_fpr = (
            resolve_production_manifest_signing_key(
            project_root,
            private_key=getattr(args, "signing_private_key", "") or None,
            public_key=getattr(args, "signing_public_key", "") or None,
        )
        )
        manifest_key_bin = dearmor_key(manifest_pub_raw)
        manifest_key_sha = sha256_bytes(manifest_key_bin)
        allowed_production_fpr = manifest_key_fpr
        print(
            "manifest_signing_key=local-mirror-client-signing path={}".format(sign_priv)
        )

    build_provenance = cbp.compute_provenance(
        project_root,
        mirror_base_url=mirror_base,
        signing_fingerprint=manifest_key_fpr or "",
    )

    manifest = OrderedDict(
        [
            ("schema_version", 1),
            ("profile", PROFILE_NAME),
            ("hop", HOP),
            ("source_codename", SOURCE_CODENAME),
            ("target_codename", TARGET_CODENAME),
            ("source_version", SOURCE_VERSION),
            ("target_version", TARGET_VERSION),
            ("mirror_base", mirror_base),
            ("repository_base", repo_base),
            ("suites", suites),
            ("source_suites", source_suites),
            ("target_suites", target_suites),
            ("components", components),
            ("repository_key_fingerprint", fingerprint),
            ("key_sha256", key_sha),
            ("manifest_key_fingerprint", manifest_key_fpr),
            ("manifest_key_sha256", manifest_key_sha),
            ("keyring_install_path", KEYRING_INSTALL_PATH),
            (
                "meta_release_url",
                "{}/client/{}/meta-release-lts".format(mirror_base, HOP),
            ),
            ("meta_release_sha256", meta_sha),
            (
                "upgrader_tar_url",
                "{}/offline/release-upgraders/bionic/bionic.tar.gz".format(mirror_base),
            ),
            ("upgrader_tar_sha256", up_tar_sha),
            (
                "upgrader_gpg_url",
                "{}/offline/release-upgraders/bionic/bionic.tar.gz.gpg".format(
                    mirror_base
                ),
            ),
            ("upgrader_gpg_sha256", up_gpg_sha),
            ("sample_deb_url", sample_deb_url),
            ("plan_checksum", plan_checksum),
            ("discovery_checksum", discovery_checksum),
            ("confirm_phrase", CONFIRM_PHRASE),
            ("client_provenance_schema_version", build_provenance["CLIENT_PROVENANCE_SCHEMA_VERSION"]),
            ("client_build_input_sha256", build_provenance["CLIENT_BUILD_INPUT_SHA256"]),
            ("client_source_revision", build_provenance["CLIENT_SOURCE_REVISION"]),
            ("client_source_tree_state", build_provenance["CLIENT_SOURCE_TREE_STATE"]),
            ("client_command_block_version", build_provenance["CLIENT_COMMAND_BLOCK_VERSION"]),
            ("client_mirror_base_url", build_provenance["CLIENT_MIRROR_BASE_URL"]),
            ("client_signing_fingerprint", build_provenance["CLIENT_SIGNING_FINGERPRINT"]),
            ("client_runtime_manifest_sha256", build_provenance["CLIENT_RUNTIME_MANIFEST_SHA256"]),
            ("client_builders_sha256", build_provenance["CLIENT_BUILDERS_SHA256"]),
            ("client_templates_sha256", build_provenance["CLIENT_TEMPLATES_SHA256"]),
            ("client_shared_helpers_sha256", build_provenance["CLIENT_SHARED_HELPERS_SHA256"]),
            ("client_runner_sha256", build_provenance["CLIENT_RUNNER_SHA256"]),
            ("generated_at", generated_at),
            ("announcements", announcements),
        ]
    )
    manifest_path = os.path.join(hop_out, "client-manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=False)
        fh.write("\n")
    manifest_sha = sha256_file(manifest_path)

    sig_path = os.path.join(hop_out, "client-manifest.json.asc")
    signed = False
    if args.skip_sign:
        with open(sig_path, "w", encoding="utf-8") as fh:
            fh.write(
                "-----BEGIN PGP SIGNATURE-----\n{}\n-----END PGP SIGNATURE-----\n".format(
                    UNSIGNED_TEST_MARKER
                )
            )
        manifest_sig_b64 = base64.b64encode(open(sig_path, "rb").read()).decode("ascii")
        print("CLIENT_MANIFEST_SIGNATURE_MODE=UNSIGNED_TEST")
    else:
        gpg_detach_sign(sign_priv, manifest_path, sig_path)
        manifest_sig_b64 = base64.b64encode(open(sig_path, "rb").read()).decode("ascii")
        signed = True
        # Fail-closed: refuse any UNSIGNED_TEST placeholder in the detached sig.
        sig_raw = open(sig_path, "rb").read()
        if count_unsigned_test(sig_raw):
            raise BuildError("production signature unexpectedly contains UNSIGNED_TEST")
        gpgv_verify(manifest_key_bin, sig_raw, open(manifest_path, "rb").read())

    # Persist repository + manifest public keys (dearmored) beside artifacts
    key_out = os.path.join(hop_out, "stellar-offline-upgrade.gpg")
    with open(key_out, "wb") as fh:
        fh.write(key_bin)
    manifest_key_out = os.path.join(hop_out, "stellar-offline-manifest.gpg")
    with open(manifest_key_out, "wb") as fh:
        fh.write(manifest_key_bin)

    key_b64 = base64.b64encode(key_bin).decode("ascii")
    # wrap base64 for readability
    key_b64_wrapped = "\n".join(
        key_b64[i : i + 76] for i in range(0, len(key_b64), 76)
    )
    manifest_key_b64 = base64.b64encode(manifest_key_bin).decode("ascii")
    manifest_key_b64_wrapped = "\n".join(
        manifest_key_b64[i : i + 76] for i in range(0, len(manifest_key_b64), 76)
    )
    meta_b64 = base64.b64encode(meta_text.encode("utf-8")).decode("ascii")
    meta_b64_wrapped = "\n".join(meta_b64[i : i + 76] for i in range(0, len(meta_b64), 76))
    # Embed exact file bytes so PIN_MANIFEST_SHA256 matches decoded content
    manifest_raw = open(manifest_path, "rb").read()
    if sha256_bytes(manifest_raw) != manifest_sha:
        raise BuildError("internal error: manifest sha mismatch before embed")
    manifest_b64 = base64.b64encode(manifest_raw).decode("ascii")
    manifest_b64_wrapped = "\n".join(
        manifest_b64[i : i + 76] for i in range(0, len(manifest_b64), 76)
    )
    sig_b64_wrapped = "\n".join(
        manifest_sig_b64[i : i + 76] for i in range(0, len(manifest_sig_b64), 76)
    )

    ann_text = open(
        os.path.join(hop_out, "ReleaseAnnouncement"), "r", encoding="utf-8", errors="replace"
    ).read()
    ann_b64 = base64.b64encode(ann_text.encode("utf-8")).decode("ascii")
    ann_b64_wrapped = "\n".join(ann_b64[i : i + 76] for i in range(0, len(ann_b64), 76))

    replacements = {
        "MIRROR_BASE": mirror_base,
        "HOP": HOP,
        "SOURCE_CODENAME": SOURCE_CODENAME,
        "TARGET_CODENAME": TARGET_CODENAME,
        "SOURCE_VERSION": SOURCE_VERSION,
        "TARGET_VERSION": TARGET_VERSION,
        "COMPONENTS": " ".join(components),
        "SOURCE_SUITES": " ".join(source_suites),
        "TARGET_SUITES": " ".join(target_suites),
        "KEY_FINGERPRINT": fingerprint,
        "KEY_SHA256": key_sha,
        "KEY_B64": key_b64_wrapped,
        "MANIFEST_KEY_FINGERPRINT": manifest_key_fpr,
        "MANIFEST_KEY_SHA256": manifest_key_sha,
        "MANIFEST_KEY_B64": manifest_key_b64_wrapped,
        "META_SHA256": meta_sha,
        "META_B64": meta_b64_wrapped,
        "UPGRADER_TAR_SHA256": up_tar_sha,
        "UPGRADER_GPG_SHA256": up_gpg_sha,
        "PLAN_CHECKSUM": plan_checksum,
        "DISCOVERY_CHECKSUM": discovery_checksum,
        "MANIFEST_SHA256": manifest_sha,
        "MANIFEST_B64": manifest_b64_wrapped,
        "MANIFEST_SIG_B64": sig_b64_wrapped,
        "SAMPLE_DEB_URL": sample_deb_url,
        "CONFIRM_PHRASE": CONFIRM_PHRASE,
        "ANNOUNCEMENT_B64": ann_b64_wrapped,
        "GENERATED_AT": generated_at,
        "PROFILE_NAME": PROFILE_NAME,
    }

    script_body = render_script(template, replacements)
    aces.assert_client_executable_shebangs(script_body, 'xenial-to-bionic')
    script_name = "dp-offline-upgrade-xenial-to-bionic.sh"
    script_path = os.path.join(out_dir, script_name)
    # also place under hop dir; production signed builds also refresh client/
    with open(script_path, "w", encoding="utf-8") as fh:
        fh.write(script_body)
        if not script_body.endswith("\n"):
            fh.write("\n")
    os.chmod(script_path, 0o755)
    hop_script = os.path.join(hop_out, script_name)
    shutil.copy2(script_path, hop_script)
    # Host-pinned clients are install-time artifacts. Never refresh tracked
    # client/*.sh in the git checkout (templates *.in are the source of truth).
    client_script = ""

    script_sha = sha256_file(script_path)
    sha_path = os.path.join(out_dir, script_name + ".sha256")
    with open(sha_path, "w", encoding="utf-8") as fh:
        fh.write("{}  {}\n".format(script_sha, script_name))

    # Bind published hop manifest to the exact script filename + SHA256.
    # The embedded MANIFEST_B64 (already rendered into the script) remains the
    # pre-binding snapshot used for in-script pin checks; the HTTP-published
    # hop/client-manifest.json is authoritative for download-time verification.
    manifest["script"] = script_name
    manifest["script_sha256"] = script_sha
    with open(manifest_path, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=False)
        fh.write("\n")
    if not args.skip_sign and sign_priv is not None:
        gpg_detach_sign(sign_priv, manifest_path, sig_path)
        gpgv_verify(manifest_key_bin, open(sig_path, "rb").read(), open(manifest_path, "rb").read())
        print("CLIENT_MANIFEST_SCRIPT_BINDING=PASS script={} sha256={}".format(script_name, script_sha))
    elif args.skip_sign:
        print("CLIENT_MANIFEST_SCRIPT_BINDING=UNSIGNED_TEST script={}".format(script_name))

    if not args.skip_sign:
        # Fail-closed production gates on the final artifact.
        verify_info = verify_client_artifact_signature(
            script_path, allowed_fingerprint=allowed_production_fpr
        )
        print("CLIENT_MANIFEST_SIGNATURE_MODE=PRODUCTION_SIGNED")
        print("CLIENT_MANIFEST_SIGNATURE_STATUS=PASS")
        print(
            "CLIENT_MANIFEST_SIGNER_FINGERPRINT={}".format(verify_info["fingerprint"])
        )
        print(
            "CLIENT_MANIFEST_UNSIGNED_TEST_COUNT={}".format(
                verify_info["unsigned_test_count"]
            )
        )
        print("ARTIFACT_SIGNATURE_VERIFY=PASS")

    # Optional nginx client root deploy:
    # Only top-level client script + .sha256 (never selective READY / DP publish).
    # Backup existing files, then atomic temp+fsync+rename replace.
    # Unsigned test builds already refused --deploy-nginx-root above.
    if args.deploy_nginx_root:
        deploy_root = args.deploy_nginx_root
        os.makedirs(deploy_root, exist_ok=True)
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        for src, name in ((script_path, script_name), (sha_path, script_name + ".sha256")):
            dest = os.path.join(deploy_root, name)
            if os.path.isfile(dest):
                bak = "{}.bak-{}".format(dest, stamp)
                shutil.copy2(dest, bak)
                print("client_deploy_backup={}".format(bak))
            tmp = "{}.tmp.{}".format(dest, os.getpid())
            shutil.copy2(src, tmp)
            os.chmod(tmp, 0o755 if name.endswith(".sh") else 0o644)
            # fsync file + directory for durable atomic replace
            with open(tmp, "rb") as fh:
                os.fsync(fh.fileno())
            os.replace(tmp, dest)
            dirfd = os.open(deploy_root, os.O_RDONLY)
            try:
                os.fsync(dirfd)
            finally:
                os.close(dirfd)
            print("client_deploy_atomic={}".format(dest))
        # Intentionally do NOT modify hop bundle / selective / READY here.

    summary = OrderedDict(
        [
            ("status", "PASS"),
            ("script_path", script_path),
            ("client_script_path", client_script),
            ("script_sha256", script_sha),
            ("manifest_path", manifest_path),
            ("manifest_sha256", manifest_sha),
            ("manifest_signed", signed),
            ("mirror_base", mirror_base),
            ("components", components),
            ("source_suites", source_suites),
            ("key_fingerprint", fingerprint),
            ("key_sha256", key_sha),
            ("meta_release_sha256", meta_sha),
            ("upgrader_tar_sha256", up_tar_sha),
            ("plan_checksum", plan_checksum),
            ("discovery_checksum", discovery_checksum),
            ("generated_at", generated_at),
        ]
    )
    summary_path = os.path.join(out_dir, "build-summary.json")
    with open(summary_path, "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2)
        fh.write("\n")

    print("BUILD_CLIENT_XENIAL_TO_BIONIC PASS")
    print("script={}".format(script_path))
    print("sha256={}".format(script_sha))
    print("fingerprint={}".format(fingerprint))
    print("components={}".format(" ".join(components)))
    print("manifest_signed={}".format(signed))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BuildError as exc:
        print("BUILD_CLIENT_XENIAL_TO_BIONIC FAIL: {}".format(exc), file=sys.stderr)
        sys.exit(1)
