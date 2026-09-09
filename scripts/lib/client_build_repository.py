#!/usr/bin/env python3
"""Local-filesystem repository reader for OS-hop client builds.

Content acquisition MUST use the verified selective tree on disk.
MIRROR_HTTP_URL is a runtime URL pin only — never used to fetch Release,
InRelease, Packages, or pool objects during prepare/build.

Production default: content_source=local-fs (network not required).
Diagnostic only: content_source=http (explicit opt-in; never used by
authoritative finalizer).
"""
from __future__ import print_function

import gzip
import os
import re
import subprocess
import tempfile

try:
    from urllib.request import Request, urlopen
except ImportError:  # pragma: no cover
    from urllib2 import Request, urlopen  # type: ignore


class RepositoryError(Exception):
    """Raised when local (or diagnostic HTTP) repository content is unusable."""


CONTENT_SOURCE_LOCAL = "local-fs"
CONTENT_SOURCE_HTTP = "http"
FORBIDDEN_REL_RE = re.compile(r"(^|/)\.\.(/|$)")


def _safe_join(root, *parts):
    """Join under root and refuse path traversal."""
    root_abs = os.path.realpath(root)
    candidate = os.path.realpath(os.path.join(root_abs, *parts))
    if candidate != root_abs and not candidate.startswith(root_abs + os.sep):
        raise RepositoryError("path traversal refused: {}".format(candidate))
    for part in parts:
        if FORBIDDEN_REL_RE.search(str(part).replace("\\", "/")):
            raise RepositoryError("path traversal refused in component: {}".format(part))
    return candidate


def parse_release_components(release_text):
    for line in release_text.splitlines():
        if line.startswith("Components:"):
            comps = line.split(":", 1)[1].strip().split()
            if not comps:
                raise RepositoryError("empty Components in Release")
            return comps
    raise RepositoryError("Components field missing from Release")


def first_pool_filename_from_packages_gz(packages_gz_bytes):
    text = gzip.decompress(packages_gz_bytes).decode("utf-8", "replace")
    for line in text.splitlines():
        if line.startswith("Filename:"):
            return line.split(":", 1)[1].strip()
    raise RepositoryError("no Filename in Packages.gz")


def shared_components(source_release_text, target_release_text, source_codename, target_codename):
    source_comps = parse_release_components(source_release_text)
    target_comps = parse_release_components(target_release_text)
    if source_comps == target_comps:
        return list(source_comps)
    shared = [c for c in source_comps if c in target_comps]
    if not shared:
        raise RepositoryError(
            "no shared Components between {} and {} Release".format(
                source_codename, target_codename
            )
        )
    return shared


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


def validate_ready_provenance(ready_path):
    fields = read_ready_fields(ready_path)
    plan = (
        fields.get("selective_plan_checksum")
        or fields.get("plan_checksum")
        or ""
    ).strip()
    discovery = (fields.get("discovery_artifact_checksum") or "").strip()
    contract = (fields.get("aws_semantic_contract_sha256") or "").strip()
    if not plan or not discovery:
        raise RepositoryError(
            "READY missing plan/discovery checksums (refusing to invent values)"
        )
    if not contract:
        raise RepositoryError(
            "READY missing aws_semantic_contract_sha256 (refusing to invent values)"
        )
    return fields


def _http_get(url, timeout=30):
    req = Request(url, headers={"User-Agent": "ubuntu-mirror-build-client/1.0"})
    with urlopen(req, timeout=timeout) as resp:
        code = getattr(resp, "status", None) or resp.getcode()
        if int(code) != 200:
            raise RepositoryError("HTTP {} for {}".format(code, url))
        return resp.read()


def gpgv_inrelease(key_bin, inrelease_bytes):
    with tempfile.TemporaryDirectory(prefix="inrel-") as td:
        key_f = os.path.join(td, "key.gpg")
        ir_f = os.path.join(td, "InRelease")
        with open(key_f, "wb") as fh:
            fh.write(key_bin)
        with open(ir_f, "wb") as fh:
            fh.write(inrelease_bytes)
        proc = subprocess.run(
            ["gpgv", "--keyring", key_f, ir_f],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode != 0:
            raise RepositoryError(
                "InRelease signature verification failed: {}".format(
                    proc.stderr.decode("utf-8", "replace")
                )
            )


class LocalHopRepository(object):
    """Read hop ubuntu content from selective local filesystem (or diagnostic HTTP)."""

    def __init__(
        self,
        selective_root,
        hop,
        source_codename,
        target_codename,
        mirror_base="",
        content_source=CONTENT_SOURCE_LOCAL,
    ):
        self.selective_root = os.path.abspath(selective_root)
        self.hop = hop
        self.source_codename = source_codename
        self.target_codename = target_codename
        self.mirror_base = (mirror_base or "").rstrip("/")
        self.content_source = content_source
        if self.content_source not in (CONTENT_SOURCE_LOCAL, CONTENT_SOURCE_HTTP):
            raise RepositoryError(
                "unsupported content-source: {}".format(self.content_source)
            )
        if self.content_source == CONTENT_SOURCE_HTTP and not self.mirror_base:
            raise RepositoryError("HTTP content-source requires --mirror-base")

    @property
    def network_required(self):
        return self.content_source == CONTENT_SOURCE_HTTP

    def hop_ubuntu_root(self):
        return _safe_join(self.selective_root, "hops", self.hop, "ubuntu")

    def _local_path(self, *rel_parts):
        return _safe_join(self.hop_ubuntu_root(), *rel_parts)

    def _read_bytes_local(self, *rel_parts):
        path = self._local_path(*rel_parts)
        if not os.path.isfile(path):
            raise RepositoryError("missing local file: {}".format(path))
        with open(path, "rb") as fh:
            return fh.read()

    def _read_bytes_http(self, *rel_parts):
        url = "{}/hops/{}/ubuntu/{}".format(
            self.mirror_base, self.hop, "/".join(rel_parts)
        )
        return _http_get(url)

    def read_bytes(self, *rel_parts):
        if self.content_source == CONTENT_SOURCE_LOCAL:
            return self._read_bytes_local(*rel_parts)
        return self._read_bytes_http(*rel_parts)

    def read_text(self, *rel_parts):
        return self.read_bytes(*rel_parts).decode("utf-8", "replace")

    def read_release(self, suite):
        return self.read_text("dists", suite, "Release")

    def read_inrelease(self, suite):
        return self.read_bytes("dists", suite, "InRelease")

    def read_packages_gz(self, suite, component="main", arch="amd64"):
        return self.read_bytes(
            "dists", suite, component, "binary-{}".format(arch), "Packages.gz"
        )

    def list_suites(self):
        """Discover suites under hop ubuntu/dists (local) or probe (HTTP diagnostic)."""
        candidates = [
            self.source_codename,
            self.source_codename + "-updates",
            self.source_codename + "-security",
            self.source_codename + "-backports",
            self.target_codename,
            self.target_codename + "-updates",
            self.target_codename + "-security",
            self.target_codename + "-backports",
        ]
        found = []
        if self.content_source == CONTENT_SOURCE_LOCAL:
            dists = self._local_path("dists")
            if not os.path.isdir(dists):
                raise RepositoryError("missing local dists directory: {}".format(dists))
            for name in sorted(os.listdir(dists)):
                if os.path.isfile(os.path.join(dists, name, "Release")):
                    found.append(name)
            # Prefer candidate order for stable source/target suite lists
            ordered = [s for s in candidates if s in found]
            extras = [s for s in found if s not in ordered]
            found = ordered + extras
        else:
            for suite in candidates:
                try:
                    self.read_bytes("dists", suite, "Release")
                    found.append(suite)
                except Exception:
                    continue
        if self.source_codename not in found or self.target_codename not in found:
            raise RepositoryError(
                "required suites missing under hop (have: {})".format(",".join(found))
            )
        return found

    def resolve_sample_deb(self, suite=None):
        """Return (relative_filename, absolute_or_url_for_pin, local_path_or_empty)."""
        sample_suite = suite or self.target_codename
        packages_gz = self.read_packages_gz(sample_suite)
        sample_deb_rel = first_pool_filename_from_packages_gz(packages_gz)
        if not sample_deb_rel:
            raise RepositoryError(
                "no pool Filename in {} Packages.gz (target suite empty?)".format(
                    sample_suite
                )
            )
        # Runtime pin URL always uses mirror_base (may be unreachable during prepare).
        sample_deb_url = "{}/hops/{}/ubuntu/{}".format(
            self.mirror_base, self.hop, sample_deb_rel
        )
        local_path = ""
        if self.content_source == CONTENT_SOURCE_LOCAL:
            local_path = self._local_path(*sample_deb_rel.split("/"))
            if not os.path.isfile(local_path):
                raise RepositoryError(
                    "sample .deb missing on local FS: {}".format(local_path)
                )
        return sample_deb_rel, sample_deb_url, local_path

    def verify_source_inrelease(self, key_bin):
        inrelease = self.read_inrelease(self.source_codename)
        gpgv_inrelease(key_bin, inrelease)
        return inrelease

    def load_build_inputs(self, key_bin):
        """Load all content inputs required for a hop client build.

        Returns dict with Release texts, suites, components, sample deb, etc.
        Does not use HTTP when content_source=local-fs.
        """
        source_release = self.read_release(self.source_codename)
        target_release = self.read_release(self.target_codename)
        components = shared_components(
            source_release,
            target_release,
            self.source_codename,
            self.target_codename,
        )
        suites = self.list_suites()
        source_suites = [
            s
            for s in suites
            if s == self.source_codename or s.startswith(self.source_codename + "-")
        ]
        target_suites = [
            s
            for s in suites
            if s == self.target_codename or s.startswith(self.target_codename + "-")
        ]
        sample_deb_rel, sample_deb_url, sample_deb_path = self.resolve_sample_deb()
        self.verify_source_inrelease(key_bin)
        return {
            "content_source": self.content_source,
            "network_required": self.network_required,
            "source_release": source_release,
            "target_release": target_release,
            "components": components,
            "suites": suites,
            "source_suites": source_suites,
            "target_suites": target_suites,
            "sample_deb_rel": sample_deb_rel,
            "sample_deb_url": sample_deb_url,
            "sample_deb_path": sample_deb_path,
        }


def selective_public_key_path(selective_root):
    return os.path.join(selective_root, "keys", "ubuntu-mirror-selective.gpg")


def selective_ready_path(selective_root):
    return os.path.join(selective_root, "state", "READY")


def assert_no_forbidden_generations(selective_root):
    """Refuse mixed/current/previous generation layouts under selective root."""
    forbidden = (
        "current",
        "previous",
        "published",
        "published.previous",
        "os-core-releases",
        "releases",
    )
    for name in forbidden:
        path = os.path.join(selective_root, name)
        # Legacy current/shared/offline/release-upgraders is still tolerated as
        # a fallback for upgrader tarballs only — but hop trees must not live under current.
        if name == "current":
            hops_under = os.path.join(path, "hops")
            if os.path.isdir(hops_under):
                raise RepositoryError(
                    "forbidden generation layout present: {}".format(hops_under)
                )
            continue
        if os.path.exists(path):
            raise RepositoryError(
                "forbidden generation layout present: {}".format(path)
            )


def verify_os_core_tree_for_reuse(selective_root, hops=None):
    """On-disk validation for OS Core reuse (status files alone are insufficient).

    Returns a dict of findings; raises RepositoryError on hard failure.
    """
    hops = hops or (
        ("xenial-to-bionic", "xenial", "bionic"),
        ("bionic-to-focal", "bionic", "focal"),
        ("focal-to-jammy", "focal", "jammy"),
        ("jammy-to-noble", "jammy", "noble"),
    )
    selective_root = os.path.abspath(selective_root)
    if not os.path.isdir(selective_root):
        raise RepositoryError("selective root missing: {}".format(selective_root))

    assert_no_forbidden_generations(selective_root)
    ready = selective_ready_path(selective_root)
    validate_ready_provenance(ready)

    key_path = selective_public_key_path(selective_root)
    if not os.path.isfile(key_path):
        raise RepositoryError("selective public key missing: {}".format(key_path))
    key_raw = open(key_path, "rb").read()
    if not key_raw:
        raise RepositoryError("selective public key empty")

    # Soft-dearmor for gpgv (builders do the same).
    key_bin = key_raw
    if key_raw.startswith(b"-----BEGIN"):
        proc = subprocess.run(
            ["gpg", "--dearmor"],
            input=key_raw,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode != 0 or not proc.stdout:
            raise RepositoryError("gpg --dearmor failed for selective key")
        key_bin = proc.stdout

    for hop, source, target in hops:
        repo = LocalHopRepository(
            selective_root,
            hop,
            source,
            target,
            mirror_base="http://127.0.0.1",  # unused for local-fs
            content_source=CONTENT_SOURCE_LOCAL,
        )
        repo.load_build_inputs(key_bin)
        upgrader = resolve_upgrader_tar(selective_root, target)
        if not os.path.isfile(upgrader):
            raise RepositoryError("upgrader tar missing: {}".format(upgrader))
        if not os.path.isfile(upgrader + ".gpg"):
            raise RepositoryError("upgrader signature missing: {}".format(upgrader + ".gpg"))

    return {
        "OS_CORE_ON_DISK_VERIFY": "PASS",
        "OS_CORE_HOPS_VERIFIED": str(len(hops)),
        "SELECTIVE_ROOT": selective_root,
    }


def main(argv=None):
    import argparse
    import sys

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--verify-os-core-reuse",
        action="store_true",
        help="validate on-disk selective tree for OS Core reuse",
    )
    ap.add_argument("--selective-root", default="/var/spool/apt-mirror/selective")
    args = ap.parse_args(argv)
    if args.verify_os_core_reuse:
        try:
            result = verify_os_core_tree_for_reuse(args.selective_root)
        except RepositoryError as exc:
            print("OS_CORE_ON_DISK_VERIFY=FAIL", file=sys.stderr)
            print("OS_CORE_ERROR={}".format(exc), file=sys.stderr)
            return 1
        for key, value in result.items():
            print("{}={}".format(key, value))
        return 0
    ap.error("no action specified")
    return 2


if __name__ == "__main__":
    import sys

    sys.exit(main())
