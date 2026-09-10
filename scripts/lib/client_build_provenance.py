#!/usr/bin/env python3
"""Authoritative build-provenance identity for published DP client sets.

Digest is computed from actual file contents and explicit runtime pins
(Mirror URL, signing fingerprint, schema/command-block versions). Never from
.git metadata alone, timestamps, temporary paths, generated outputs, private
keys, or host-specific inode values inside CLIENT_BUILD_INPUT_SHA256.
"""
from __future__ import print_function

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from datetime import datetime, timezone

CLIENT_PROVENANCE_SCHEMA_VERSION = "1"
COMMAND_BLOCK_VERSION = "SUBSHELL_V2"
LAUNCHER_SCHEMA_VERSION = "2"
HOPS = (
    "xenial-to-bionic",
    "bionic-to-focal",
    "focal-to-jammy",
    "jammy-to-noble",
)
PHASE1_HOP_DEFINITIONS = (
    "xenial-to-bionic|16.04|18.04|xenial|bionic",
    "bionic-to-focal|18.04|20.04|bionic|focal",
    "focal-to-jammy|20.04|22.04|focal|jammy",
    "jammy-to-noble|22.04|24.04|jammy|noble",
)

CATEGORY_PATTERNS = {
    "runtime_manifest": ("lib/runtime_manifest.sh",),
    "builders": (
        "scripts/lib/client_build_repository.py",
        "scripts/lib/client_build_provenance.py",
        "scripts/lib/assert_client_executable_shebang.py",
        "scripts/lib/build_client_xenial_to_bionic.py",
        "scripts/lib/build_client_bionic_to_focal.py",
        "scripts/lib/build_client_focal_to_jammy.py",
        "scripts/lib/build_client_jammy_to_noble.py",
        "scripts/lib/build_client_launchers.py",
    ),
    "templates": (
        "client/dp-offline-upgrade-xenial-to-bionic.sh.in",
        "client/dp-offline-upgrade-bionic-to-focal.sh.in",
        "client/dp-offline-upgrade-focal-to-jammy.sh.in",
        "client/dp-offline-upgrade-jammy-to-noble.sh.in",
        "client/dp-postboot-readiness-policy.sh.inc",
        "client/dp-postboot-aws-kernel-gate.sh.inc",
        "client/dp-aws-semantic-contract.sh.inc",
        "client/dp-client-hop-launcher.sh.in",
    ),
    "helpers": (
        "client/lib/dp-offline-destructive-confirmation.sh",
        "client/lib/dp-offline-release-upgrade-reconciliation.sh",
        "client/lib/dp-offline-apt-preflight-sandbox.sh",
        "client/lib/dp-offline-durable-write.sh",
        "client/lib/dp-offline-source-product-version.sh",
        "client/lib/dp-offline-lxd-inventory.sh",
        "client/bringup_py3_dp_lifecycle.sh",
        "client/lib/dp-phase2-operation-progress.sh",
        "client/lib/dp-phase2-bringup-lifecycle.sh",
        "client/lib/dp-phase2-ubuntu-prerequisites.sh",
    ),
    "runner": ("client/dp-client-command-runner.sh",),
    "command_generators": (
        "scripts/install-dp-upgrade-mirror.sh",
        "scripts/lib/mirror_workflow_state.sh",
    ),
    "pipeline": (
        "scripts/rebuild-publish-clients.sh",
        "scripts/lib/mirror_manager_common.sh",
        "scripts/lib/mirror_install_engine.sh",
        "scripts/lib/local_client_signing.sh",
        "scripts/lib/client_mirror_gates.sh",
        "scripts/lib/http_publication_permissions.sh",
        "scripts/lib/atomic_dir_swap.py",
        "scripts/lib/phase2_helper_generation.sh",
        "client/stage-dp-phase2.sh",
        "client/stage-dp-phase2-6.6.0.sh",
        "client/stage-dp-phase2-6.5.0.sh",
    ),
}

ENV_FIELDS = (
    "CLIENT_PROVENANCE_SCHEMA_VERSION",
    "CLIENT_BUILD_INPUT_SHA256",
    "CLIENT_SOURCE_REVISION",
    "CLIENT_SOURCE_TREE_STATE",
    "CLIENT_COMMAND_BLOCK_VERSION",
    "CLIENT_LAUNCHER_SCHEMA_VERSION",
    "CLIENT_MIRROR_BASE_URL",
    "CLIENT_SIGNING_FINGERPRINT",
    "CLIENT_RUNTIME_MANIFEST_SHA256",
    "CLIENT_BUILDERS_SHA256",
    "CLIENT_TEMPLATES_SHA256",
    "CLIENT_SHARED_HELPERS_SHA256",
    "CLIENT_RUNNER_SHA256",
    "CLIENT_PLAN_CHECKSUM",
    "CLIENT_DISCOVERY_ARTIFACT_CHECKSUM",
    "CLIENT_AWS_SEMANTIC_CONTRACT_SHA256",
)

# Legacy alias kept for older metadata readers.
LEGACY_ENV_ALIASES = {
    "CLIENT_BUILD_SOURCE_REVISION": "CLIENT_SOURCE_REVISION",
}


def _sha_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _canonical_digest(root, relpaths):
    h = hashlib.sha256()
    for rel in sorted(set(relpaths)):
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            raise RuntimeError("CLIENT_BUILD_INPUT_MISSING=" + rel)
        mode = stat.S_IMODE(os.stat(path).st_mode)
        line = "%s\0%04o\0%s\n" % (rel, mode, _sha_file(path))
        h.update(line.encode("utf-8"))
    return h.hexdigest()


def all_input_files():
    files = []
    for values in CATEGORY_PATTERNS.values():
        files.extend(values)
    return tuple(sorted(set(files)))


def _git_revision(root):
    try:
        proc = subprocess.run(
            ["git", "-C", root, "rev-parse", "HEAD"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            text=True,
        )
        if proc.returncode == 0:
            return proc.stdout.strip()
    except Exception:
        pass
    return "unknown"


def _git_tree_state(root):
    try:
        proc = subprocess.run(
            ["git", "-C", root, "status", "--porcelain"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            text=True,
        )
        if proc.returncode == 0:
            return "dirty" if proc.stdout.strip() else "clean"
    except Exception:
        pass
    return "unknown"


def compute_provenance(
    project_root,
    mirror_base_url="",
    signing_fingerprint="",
    aws_semantic_contract_sha256="",
    plan_checksum="",
    discovery_artifact_checksum="",
):
    root = os.path.abspath(project_root)
    cat = {}
    for name, values in CATEGORY_PATTERNS.items():
        cat[name] = _canonical_digest(root, values)
    file_digest = _canonical_digest(root, all_input_files())
    mirror = (mirror_base_url or "").rstrip("/")
    fpr = (signing_fingerprint or "").upper().replace(" ", "")
    contract_sha = (aws_semantic_contract_sha256 or "").strip().lower()
    plan_ck = (plan_checksum or "").strip().lower()
    disc_ck = (discovery_artifact_checksum or "").strip().lower()
    # Build-input digest: file contents + explicit field separators for pins.
    # No timestamps, temp paths, generated outputs, private keys, or inodes.
    binder = hashlib.sha256()
    binder.update(b"CLIENT_PROVENANCE_SCHEMA_VERSION\0")
    binder.update(CLIENT_PROVENANCE_SCHEMA_VERSION.encode("utf-8") + b"\n")
    binder.update(b"CLIENT_COMMAND_BLOCK_VERSION\0")
    binder.update(COMMAND_BLOCK_VERSION.encode("utf-8") + b"\n")
    binder.update(b"CLIENT_LAUNCHER_SCHEMA_VERSION\0")
    binder.update(LAUNCHER_SCHEMA_VERSION.encode("utf-8") + b"\n")
    binder.update(b"CLIENT_MIRROR_BASE_URL\0")
    binder.update(mirror.encode("utf-8") + b"\n")
    binder.update(b"CLIENT_SIGNING_FINGERPRINT\0")
    binder.update(fpr.encode("utf-8") + b"\n")
    binder.update(b"CLIENT_PLAN_CHECKSUM\0")
    binder.update(plan_ck.encode("utf-8") + b"\n")
    binder.update(b"CLIENT_DISCOVERY_ARTIFACT_CHECKSUM\0")
    binder.update(disc_ck.encode("utf-8") + b"\n")
    binder.update(b"CLIENT_AWS_SEMANTIC_CONTRACT_SHA256\0")
    binder.update(contract_sha.encode("utf-8") + b"\n")
    binder.update(b"PHASE1_HOP_DEFINITIONS\0")
    for hopdef in PHASE1_HOP_DEFINITIONS:
        binder.update(hopdef.encode("utf-8") + b"\n")
    binder.update(b"FILE_DIGEST\0")
    binder.update(file_digest.encode("utf-8") + b"\n")
    whole = binder.hexdigest()
    created = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {
        "CLIENT_PROVENANCE_SCHEMA_VERSION": CLIENT_PROVENANCE_SCHEMA_VERSION,
        "CLIENT_BUILD_INPUT_SHA256": whole,
        "CLIENT_SOURCE_REVISION": _git_revision(root),
        "CLIENT_SOURCE_TREE_STATE": _git_tree_state(root),
        "CLIENT_BUILD_SOURCE_REVISION": "tree:" + file_digest,
        "CLIENT_COMMAND_BLOCK_VERSION": COMMAND_BLOCK_VERSION,
        "CLIENT_LAUNCHER_SCHEMA_VERSION": LAUNCHER_SCHEMA_VERSION,
        "CLIENT_MIRROR_BASE_URL": mirror,
        "CLIENT_SIGNING_FINGERPRINT": fpr,
        "CLIENT_PLAN_CHECKSUM": plan_ck,
        "CLIENT_DISCOVERY_ARTIFACT_CHECKSUM": disc_ck,
        "CLIENT_AWS_SEMANTIC_CONTRACT_SHA256": contract_sha,
        "CLIENT_BUILD_CREATED_UTC": created,
        "CLIENT_RUNTIME_MANIFEST_SHA256": _sha_file(
            os.path.join(root, "lib/runtime_manifest.sh")
        ),
        "CLIENT_BUILDERS_SHA256": cat["builders"],
        "CLIENT_TEMPLATES_SHA256": cat["templates"],
        "CLIENT_SHARED_HELPERS_SHA256": cat["helpers"],
        "CLIENT_RUNNER_SHA256": _sha_file(
            os.path.join(root, "client/dp-client-command-runner.sh")
        ),
        "CLIENT_FILE_CONTENT_SHA256": file_digest,
    }


def resolve_selective_root(selective_root=""):
    """Resolve selective root from explicit arg or production env defaults."""
    candidates = (
        selective_root,
        os.environ.get("SELECTIVE_ROOT", ""),
        os.environ.get("SELECTIVE_MIRROR_ROOT", ""),
        os.environ.get("MM_SELECTIVE_ROOT", ""),
        "/var/spool/apt-mirror/selective",
    )
    for cand in candidates:
        cand = (cand or "").strip()
        if cand:
            return os.path.abspath(cand)
    return ""


def _hermetic_test_boundary():
    return (
        os.environ.get("MM_HERMETIC_TEST_MODE", "") == "1"
        and os.environ.get("UM_ALLOW_GENERIC_ONLY_DISCOVERY", "") == "1"
    )


def load_current_selective_generation(project_root, selective_root=""):
    """Load CURRENT verified selective generation independently of client metadata.

    Production FULL authority is selective READY + plan.json + embedded contract.
    Never trust CLIENT_* metadata as the sole expected-generation source.
    """
    root = os.path.abspath(project_root)
    sel = resolve_selective_root(selective_root)
    if not sel:
        raise RuntimeError("SELECTIVE_GENERATION_ROOT_MISSING")
    lib = os.path.join(root, "scripts", "lib")
    if lib not in sys.path:
        sys.path.insert(0, lib)
    from aws_os_core_completeness import load_verified_selective_generation

    return load_verified_selective_generation(sel, project_root=root)


def requires_selective_generation_binding(expected_mode=""):
    """OS-hop selective binding applies to FULL (and empty/default), not PHASE2_ONLY."""
    mode = (expected_mode or os.environ.get("PREPARATION_MODE", "") or "FULL").strip()
    return mode != "PHASE2_ONLY"


def parse_env_file(path):
    """Parse KEY=VALUE metadata. Duplicate keys are always rejected."""
    result = {}
    with open(path, "r", encoding="utf-8", errors="strict") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            if not re.match(r"^[A-Z0-9_]+=[^\r\n]*$", line):
                raise RuntimeError("CLIENT_SET_METADATA_PARSE=FAIL")
            key, value = line.split("=", 1)
            if key in result:
                raise RuntimeError(
                    "CLIENT_SET_METADATA_DUPLICATE_KEY=%s" % key
                )
            result[key] = value
    return result


def _fingerprint(keyring):
    proc = subprocess.run(
        [
            "gpg",
            "--batch",
            "--no-default-keyring",
            "--keyring",
            keyring,
            "--with-colons",
            "--fingerprint",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError("CLIENT_SET_KEYRING_FINGERPRINT=FAIL")
    for line in proc.stdout.splitlines():
        if line.startswith("fpr:"):
            value = line.split(":")[9].upper()
            if len(value) == 40:
                return value
    raise RuntimeError("CLIENT_SET_KEYRING_FINGERPRINT=FAIL")


def _gpgv(keyring, signature, payload):
    proc = subprocess.run(
        ["gpgv", "--keyring", keyring, signature, payload],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError("CLIENT_SET_SIGNATURE_VERIFY=FAIL payload=" + payload)


def _verify_sidecar(root, name):
    sidecar = os.path.join(root, name + ".sha256")
    target = os.path.join(root, name)
    if not os.path.isfile(sidecar) or not os.path.isfile(target):
        raise RuntimeError("CLIENT_SET_FILE_MISSING=" + name)
    with open(sidecar, "r", encoding="utf-8", errors="replace") as fh:
        expected = fh.readline().split()[0].lower()
    if not re.match(r"^[0-9a-f]{64}$", expected):
        raise RuntimeError("CLIENT_SET_SIDECAR_FORMAT=FAIL file=" + name)
    if _sha_file(target) != expected:
        raise RuntimeError("CLIENT_SET_SIDECAR_VERIFY=FAIL file=" + name)


class ClientSetDecision(Exception):
    def __init__(self, state, action, reason):
        self.state = state
        self.action = action
        self.reason = reason
        super(ClientSetDecision, self).__init__(
            "CLIENT_SET_STATE=%s CLIENT_SET_ACTION=%s reason=%s"
            % (state, action, reason)
        )


def classify_client_set(
    project_root,
    client_root,
    expected_mirror="",
    expected_fingerprint="",
    expected_mode="",
    selective_root="",
):
    """Return (state, action, provenance_or_None, reason).

    CURRENT_VERIFIED authority for FULL mode comes from the live selective
    generation (READY + plan.json + contract), never solely from client-set
    metadata being validated.
    """
    root = os.path.abspath(client_root)
    meta_path = os.path.join(root, "client-set.env")
    if not os.path.isfile(meta_path):
        return ("STALE_LEGACY_METADATA", "REBUILD_SIGN_PUBLISH", None, "CLIENT_SET_METADATA=MISSING")
    try:
        metadata = parse_env_file(meta_path)
    except Exception as exc:
        return ("INVALID", "REBUILD_SIGN_PUBLISH", None, str(exc))

    if "CLIENT_BUILD_INPUT_SHA256" not in metadata or "CLIENT_PROVENANCE_SCHEMA_VERSION" not in metadata:
        return ("STALE_LEGACY_METADATA", "REBUILD_SIGN_PUBLISH", None, "legacy_metadata")

    meta_mirror = (metadata.get("CLIENT_MIRROR_BASE_URL") or metadata.get("MIRROR_HTTP_URL", "")).rstrip("/")
    meta_fpr = metadata.get("CLIENT_SIGNING_FINGERPRINT", "").upper().replace(" ", "")
    mirror = (expected_mirror or meta_mirror).rstrip("/")
    fpr = (expected_fingerprint or meta_fpr).upper().replace(" ", "")

    plan_ck = ""
    disc_ck = ""
    contract_sha = ""
    selective_gen = None
    bind_selective = requires_selective_generation_binding(expected_mode)
    if bind_selective:
        try:
            selective_gen = load_current_selective_generation(
                project_root, selective_root=selective_root
            )
        except Exception as exc:
            # Fail closed: never classify CURRENT_VERIFIED from client metadata alone.
            return (
                "STALE_BUILD_INPUT",
                "REBUILD_SIGN_PUBLISH",
                None,
                "selective_generation_unavailable:%s" % str(exc).replace("\n", " "),
            )
        plan_ck = (selective_gen.get("plan_checksum") or "").strip().lower()
        disc_ck = (selective_gen.get("discovery_artifact_checksum") or "").strip().lower()
        contract_sha = (
            selective_gen.get("aws_semantic_contract_sha256") or ""
        ).strip().lower()
        if selective_gen.get("hermetic_fixture"):
            # Hermetic dual-escape: empty plan/discovery, fixture contract only.
            if not _hermetic_test_boundary():
                return (
                    "STALE_BUILD_INPUT",
                    "REBUILD_SIGN_PUBLISH",
                    None,
                    "hermetic_selective_escape_without_test_boundary",
                )
        elif not contract_sha:
            return (
                "STALE_BUILD_INPUT",
                "REBUILD_SIGN_PUBLISH",
                None,
                "selective_generation_contract_empty",
            )

    if expected_fingerprint and meta_fpr and meta_fpr != fpr:
        current = compute_provenance(
            project_root,
            mirror_base_url=mirror,
            signing_fingerprint=fpr,
            aws_semantic_contract_sha256=contract_sha,
            plan_checksum=plan_ck,
            discovery_artifact_checksum=disc_ck,
        )
        return ("STALE_SIGNING_IDENTITY", "REBUILD_SIGN_PUBLISH", current, "signing_fingerprint_mismatch")
    if expected_mirror and meta_mirror and meta_mirror != mirror:
        current = compute_provenance(
            project_root,
            mirror_base_url=mirror,
            signing_fingerprint=fpr,
            aws_semantic_contract_sha256=contract_sha,
            plan_checksum=plan_ck,
            discovery_artifact_checksum=disc_ck,
        )
        return ("STALE_BUILD_INPUT", "REBUILD_SIGN_PUBLISH", current, "mirror_mismatch")

    current = compute_provenance(
        project_root,
        mirror_base_url=mirror,
        signing_fingerprint=fpr,
        aws_semantic_contract_sha256=contract_sha,
        plan_checksum=plan_ck,
        discovery_artifact_checksum=disc_ck,
    )

    if bind_selective and selective_gen is not None:
        meta_contract = (
            metadata.get("CLIENT_AWS_SEMANTIC_CONTRACT_SHA256", "") or ""
        ).strip().lower()
        meta_plan = (metadata.get("CLIENT_PLAN_CHECKSUM", "") or "").strip().lower()
        meta_disc = (
            metadata.get("CLIENT_DISCOVERY_ARTIFACT_CHECKSUM", "") or ""
        ).strip().lower()
        if meta_contract != contract_sha:
            return (
                "STALE_BUILD_INPUT",
                "REBUILD_SIGN_PUBLISH",
                current,
                "aws_semantic_contract_mismatch",
            )
        # Prefer explicit plan/discovery fields when present; empty legacy metadata
        # is still caught via CLIENT_BUILD_INPUT_SHA256 after plan/discovery entered
        # the binder, and via signed hop manifests below.
        if meta_plan and meta_plan != plan_ck:
            return (
                "STALE_BUILD_INPUT",
                "REBUILD_SIGN_PUBLISH",
                current,
                "plan_checksum_mismatch",
            )
        if meta_disc and meta_disc != disc_ck:
            return (
                "STALE_BUILD_INPUT",
                "REBUILD_SIGN_PUBLISH",
                current,
                "discovery_artifact_checksum_mismatch",
            )
        if not selective_gen.get("hermetic_fixture"):
            if not meta_plan or not meta_disc:
                return (
                    "STALE_BUILD_INPUT",
                    "REBUILD_SIGN_PUBLISH",
                    current,
                    "client_set_selective_tuple_metadata_missing",
                )

    if metadata.get("CLIENT_PROVENANCE_SCHEMA_VERSION", "") != current["CLIENT_PROVENANCE_SCHEMA_VERSION"]:
        return ("STALE_BUILD_INPUT", "REBUILD_SIGN_PUBLISH", current, "schema_mismatch")
    if metadata.get("CLIENT_COMMAND_BLOCK_VERSION", "") != current["CLIENT_COMMAND_BLOCK_VERSION"]:
        return ("STALE_BUILD_INPUT", "REBUILD_SIGN_PUBLISH", current, "command_block_mismatch")
    meta_launcher_schema = metadata.get("CLIENT_LAUNCHER_SCHEMA_VERSION", "")
    if meta_launcher_schema != current["CLIENT_LAUNCHER_SCHEMA_VERSION"]:
        # Legacy client sets without launchers are stale and must rebuild.
        return ("STALE_BUILD_INPUT", "REBUILD_SIGN_PUBLISH", current, "launcher_schema_mismatch")
    if meta_mirror != current["CLIENT_MIRROR_BASE_URL"].rstrip("/"):
        return ("STALE_BUILD_INPUT", "REBUILD_SIGN_PUBLISH", current, "mirror_mismatch")
    if meta_fpr != current["CLIENT_SIGNING_FINGERPRINT"].upper():
        return ("STALE_SIGNING_IDENTITY", "REBUILD_SIGN_PUBLISH", current, "signing_fingerprint_mismatch")
    if metadata.get("CLIENT_BUILD_INPUT_SHA256", "") != current["CLIENT_BUILD_INPUT_SHA256"]:
        return ("STALE_BUILD_INPUT", "REBUILD_SIGN_PUBLISH", current, "build_input_mismatch")

    if expected_mode and metadata.get("PREPARATION_MODE", "") != expected_mode:
        return ("STALE_BUILD_INPUT", "REBUILD_SIGN_PUBLISH", current, "mode_mismatch")

    try:
        verify_client_set_integrity(
            root,
            current,
            expected_mirror=mirror,
            expected_fingerprint=fpr,
            selective_generation=selective_gen if bind_selective else None,
            require_selective_binding=bind_selective,
        )
    except Exception as exc:
        return ("INVALID", "REBUILD_SIGN_PUBLISH", current, str(exc))

    return ("CURRENT_VERIFIED", "REUSE_CURRENT", current, "exact_match")


def verify_client_set_integrity(
    root,
    current,
    expected_mirror="",
    expected_fingerprint="",
    selective_generation=None,
    require_selective_binding=False,
):
    keyring = os.path.join(root, "public-keyring.gpg")
    fpr = _fingerprint(keyring)
    if expected_fingerprint and fpr != expected_fingerprint.upper():
        raise RuntimeError("CLIENT_SET_LOCAL_SIGNING_FINGERPRINT_MISMATCH")
    if current.get("CLIENT_SIGNING_FINGERPRINT") and fpr != current["CLIENT_SIGNING_FINGERPRINT"].upper():
        raise RuntimeError("CLIENT_SET_SIGNING_FINGERPRINT_MISMATCH")

    meta_path = os.path.join(root, "client-set.env")
    disk_meta = parse_env_file(meta_path) if os.path.isfile(meta_path) else {}

    expected_plan = ""
    expected_disc = ""
    expected_contract = ""
    if require_selective_binding:
        if selective_generation is None:
            raise RuntimeError("CLIENT_SET_SELECTIVE_GENERATION_REQUIRED")
        expected_plan = (selective_generation.get("plan_checksum") or "").strip().lower()
        expected_disc = (
            selective_generation.get("discovery_artifact_checksum") or ""
        ).strip().lower()
        expected_contract = (
            selective_generation.get("aws_semantic_contract_sha256") or ""
        ).strip().lower()
        meta_contract = (
            disk_meta.get("CLIENT_AWS_SEMANTIC_CONTRACT_SHA256", "") or ""
        ).strip().lower()
        if meta_contract != expected_contract:
            raise RuntimeError("CLIENT_SET_CONTRACT_SHA_MISMATCH")
        meta_plan = (disk_meta.get("CLIENT_PLAN_CHECKSUM", "") or "").strip().lower()
        meta_disc = (
            disk_meta.get("CLIENT_DISCOVERY_ARTIFACT_CHECKSUM", "") or ""
        ).strip().lower()
        if not selective_generation.get("hermetic_fixture"):
            if meta_plan != expected_plan:
                raise RuntimeError("CLIENT_SET_PLAN_CHECKSUM_MISMATCH")
            if meta_disc != expected_disc:
                raise RuntimeError("CLIENT_SET_DISCOVERY_CHECKSUM_MISMATCH")

    _verify_sidecar(root, "dp-client-command-runner.sh")
    runner_manifest = os.path.join(root, "runner-manifest")
    runner_sig = runner_manifest + ".asc"
    _gpgv(keyring, runner_sig, runner_manifest)
    if open(runner_manifest, "rb").read() != open(
        os.path.join(root, "dp-client-command-runner.sh.sha256"), "rb"
    ).read():
        raise RuntimeError("CLIENT_SET_RUNNER_MANIFEST_MISMATCH")

    for hop in HOPS:
        script = "dp-offline-upgrade-%s.sh" % hop
        _verify_sidecar(root, script)
        launcher = "dp-launch-%s.sh" % hop
        _verify_sidecar(root, launcher)
        launcher_path = os.path.join(root, launcher)
        with open(launcher_path, "r", encoding="utf-8", errors="replace") as fh:
            launcher_text = fh.read()
        if "BEGIN PGP PRIVATE KEY" in launcher_text:
            raise RuntimeError("CLIENT_LAUNCHER_PRIVATE_KEY_PRESENT hop=" + hop)
        if ("HOP='%s'" % hop) not in launcher_text and ('HOP="%s"' % hop) not in launcher_text:
            raise RuntimeError("CLIENT_LAUNCHER_HOP_MISMATCH hop=" + hop)
        if expected_mirror and expected_mirror.rstrip("/") not in launcher_text:
            raise RuntimeError("CLIENT_LAUNCHER_MIRROR_MISMATCH hop=" + hop)
        if fpr not in launcher_text.upper():
            raise RuntimeError("CLIENT_LAUNCHER_FINGERPRINT_MISMATCH hop=" + hop)
        keyring_sha = _sha_file(keyring)
        if ("EXPECTED_KEYRING_SHA256='%s'" % keyring_sha) not in launcher_text \
                and ('EXPECTED_KEYRING_SHA256="%s"' % keyring_sha) not in launcher_text:
            raise RuntimeError("CLIENT_LAUNCHER_KEYRING_SHA_MISMATCH hop=" + hop)
        if "dp-client-command-runner.sh" not in launcher_text:
            raise RuntimeError("CLIENT_LAUNCHER_RUNNER_INVOKE_MISSING hop=" + hop)
        meta_key = "CLIENT_LAUNCHER_%s_SHA256" % hop.upper().replace("-", "_")
        launcher_sha = _sha_file(launcher_path)
        if meta_key not in disk_meta:
            raise RuntimeError("CLIENT_LAUNCHER_METADATA_MISSING hop=" + hop)
        if disk_meta[meta_key].lower() != launcher_sha:
            raise RuntimeError("CLIENT_LAUNCHER_METADATA_SHA_MISMATCH hop=" + hop)
        wrapper = "upgrade-%s.sh" % hop
        _verify_sidecar(root, wrapper)
        wrapper_path = os.path.join(root, wrapper)
        with open(wrapper_path, "r", encoding="utf-8", errors="replace") as fh:
            wrapper_text = fh.read()
        if "BEGIN PGP PRIVATE KEY" in wrapper_text:
            raise RuntimeError("CLIENT_WRAPPER_PRIVATE_KEY_PRESENT hop=" + hop)
        if launcher not in wrapper_text:
            raise RuntimeError("CLIENT_WRAPPER_LAUNCHER_MISSING hop=" + hop)
        if ("LAUNCHER_SHA256='%s'" % launcher_sha) not in wrapper_text:
            raise RuntimeError("CLIENT_WRAPPER_LAUNCHER_SHA_MISMATCH hop=" + hop)
        if expected_mirror and expected_mirror.rstrip("/") not in wrapper_text:
            raise RuntimeError("CLIENT_WRAPPER_MIRROR_MISMATCH hop=" + hop)
        if re.search(r"curl[^\n]*\|\s*(?:bash|sh)\b", wrapper_text):
            raise RuntimeError("CLIENT_WRAPPER_CURL_PIPE_BASH hop=" + hop)
        wrapper_key = "CLIENT_WRAPPER_%s_SHA256" % hop.upper().replace("-", "_")
        wrapper_sha = _sha_file(wrapper_path)
        if wrapper_key not in disk_meta:
            raise RuntimeError("CLIENT_WRAPPER_METADATA_MISSING hop=" + hop)
        if disk_meta[wrapper_key].lower() != wrapper_sha:
            raise RuntimeError("CLIENT_WRAPPER_METADATA_SHA_MISMATCH hop=" + hop)
        manifest = os.path.join(root, hop, "client-manifest.json")
        signature = manifest + ".asc"
        if not os.path.isfile(manifest) or not os.path.isfile(signature):
            raise RuntimeError("CLIENT_MANIFEST_MISSING hop=" + hop)
        _gpgv(keyring, signature, manifest)
        with open(manifest, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if data.get("hop") != hop:
            raise RuntimeError("CLIENT_MANIFEST_HOP_MISMATCH hop=" + hop)
        if expected_mirror and str(data.get("mirror_base", "")).rstrip("/") != expected_mirror.rstrip("/"):
            raise RuntimeError("CLIENT_MANIFEST_MIRROR_MISMATCH hop=" + hop)
        if str(data.get("manifest_key_fingerprint", "")).upper() != fpr:
            raise RuntimeError("CLIENT_MANIFEST_SIGNING_FINGERPRINT_MISMATCH hop=" + hop)
        # Bound provenance fields inside signed hop manifests.
        for key in (
            "CLIENT_BUILD_INPUT_SHA256",
            "CLIENT_PROVENANCE_SCHEMA_VERSION",
            "CLIENT_COMMAND_BLOCK_VERSION",
        ):
            json_key = key.lower()
            if str(data.get(json_key, "")) != current[key]:
                raise RuntimeError(
                    "CLIENT_MANIFEST_PROVENANCE_MISMATCH hop=%s field=%s" % (hop, json_key)
                )
        if require_selective_binding and selective_generation is not None:
            if not selective_generation.get("hermetic_fixture"):
                man_plan = str(data.get("plan_checksum", "") or "").strip().lower()
                man_disc = str(data.get("discovery_checksum", "") or "").strip().lower()
                man_contract = str(
                    data.get("aws_semantic_contract_sha256", "") or ""
                ).strip().lower()
                if man_plan != expected_plan:
                    raise RuntimeError(
                        "CLIENT_MANIFEST_PLAN_CHECKSUM_MISMATCH hop=%s" % hop
                    )
                if man_disc != expected_disc:
                    raise RuntimeError(
                        "CLIENT_MANIFEST_DISCOVERY_CHECKSUM_MISMATCH hop=%s" % hop
                    )
                if man_contract != expected_contract:
                    raise RuntimeError(
                        "CLIENT_MANIFEST_CONTRACT_SHA_MISMATCH hop=%s" % hop
                    )
    _verify_sidecar(root, "upgrade-phase2.sh")
    phase2_wrapper = os.path.join(root, "upgrade-phase2.sh")
    with open(phase2_wrapper, "r", encoding="utf-8", errors="replace") as fh:
        phase2_text = fh.read()
    gen_path = os.path.join(root, "phase2-helper-generation.manifest")
    if not os.path.isfile(gen_path):
        raise RuntimeError("CLIENT_SET_FILE_MISSING=phase2-helper-generation.manifest")
    gen_sha = _sha_file(gen_path)
    if ("H='%s'" % gen_sha) not in phase2_text:
        raise RuntimeError("CLIENT_WRAPPER_PHASE2_GENERATION_SHA_MISMATCH")
    if "phase2-helper-generation.manifest" not in phase2_text:
        raise RuntimeError("CLIENT_WRAPPER_PHASE2_GENERATION_MANIFEST_MISSING")
    if "sha256sum -c \"$GEN\"" not in phase2_text and "sha256sum -c '$GEN'" not in phase2_text:
        raise RuntimeError("CLIENT_WRAPPER_PHASE2_HELPER_VERIFY_MISSING")
    if "stage-dp-phase2.sh" not in phase2_text:
        raise RuntimeError("CLIENT_WRAPPER_PHASE2_STAGE_MISSING")
    if "--target-version" not in phase2_text or "6.6.0" not in phase2_text:
        raise RuntimeError("CLIENT_WRAPPER_PHASE2_TARGET_VERSION_MISSING")
    # Normal wrapper must not force same-version recovery on every run.
    if re.search(
        r'sudo bash\s+"\./\$SCRIPT".*--same-version-recovery',
        phase2_text,
    ):
        raise RuntimeError("CLIENT_WRAPPER_PHASE2_FORCES_SAME_VERSION_RECOVERY")
    recovery_wrapper = os.path.join(root, "upgrade-phase2-same-version-recovery.sh")
    if not os.path.isfile(recovery_wrapper):
        raise RuntimeError("CLIENT_WRAPPER_PHASE2_RECOVERY_MISSING")
    with open(recovery_wrapper, "r", encoding="utf-8", errors="replace") as fh:
        recovery_text = fh.read()
    if "CONFIRM_SAME_VERSION_RECOVERY=YES" not in recovery_text:
        raise RuntimeError("CLIENT_WRAPPER_PHASE2_RECOVERY_GATE_MISSING")
    if "--same-version-recovery" not in recovery_text:
        raise RuntimeError("CLIENT_WRAPPER_PHASE2_RECOVERY_FLAG_MISSING")
    if "--mirror-url" not in phase2_text:
        raise RuntimeError("CLIENT_WRAPPER_PHASE2_MIRROR_URL_FLAG_MISSING")
    if expected_mirror and expected_mirror.rstrip("/") not in phase2_text:
        raise RuntimeError("CLIENT_WRAPPER_PHASE2_MIRROR_MISMATCH")
    if re.search(r"curl[^\n]*\|\s*(?:bash|sh)\b", phase2_text):
        raise RuntimeError("CLIENT_WRAPPER_PHASE2_CURL_PIPE_BASH")
    if "CLIENT_WRAPPER_PHASE2_SHA256" not in disk_meta:
        raise RuntimeError("CLIENT_WRAPPER_PHASE2_METADATA_MISSING")
    if disk_meta["CLIENT_WRAPPER_PHASE2_SHA256"].lower() != _sha_file(phase2_wrapper):
        raise RuntimeError("CLIENT_WRAPPER_PHASE2_METADATA_SHA_MISMATCH")
    return current


def verify_client_set(
    project_root,
    client_root,
    expected_mirror="",
    expected_fingerprint="",
    expected_mode="",
    selective_root="",
):
    state, action, current, reason = classify_client_set(
        project_root,
        client_root,
        expected_mirror,
        expected_fingerprint,
        expected_mode,
        selective_root=selective_root,
    )
    if state != "CURRENT_VERIFIED":
        raise RuntimeError(
            "CLIENT_SET_STATE=%s CLIENT_SET_ACTION=%s reason=%s" % (state, action, reason)
        )
    return current


def emit_env(values):
    for key in ENV_FIELDS:
        print("%s=%s" % (key, values[key]))
    # Compat aliases for workflow/metadata writers.
    print("CLIENT_BUILD_SOURCE_REVISION=%s" % values.get("CLIENT_BUILD_SOURCE_REVISION", ""))
    print("CLIENT_BUILD_CREATED_UTC=%s" % values.get("CLIENT_BUILD_CREATED_UTC", ""))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p_compute = sub.add_parser("compute")
    p_compute.add_argument("--project-root", required=True)
    p_compute.add_argument("--mirror-base-url", default="")
    p_compute.add_argument("--signing-fingerprint", default="")
    p_compute.add_argument("--aws-semantic-contract-sha256", default="")
    p_compute.add_argument("--plan-checksum", default="")
    p_compute.add_argument("--discovery-artifact-checksum", default="")
    p_compute.add_argument("--format", choices=("env", "json"), default="env")
    p_list = sub.add_parser("list-files")
    p_classify = sub.add_parser("classify-client-set")
    p_classify.add_argument("--project-root", required=True)
    p_classify.add_argument("--client-root", required=True)
    p_classify.add_argument("--expected-mirror", default="")
    p_classify.add_argument("--expected-fingerprint", default="")
    p_classify.add_argument("--expected-mode", default="")
    p_classify.add_argument("--selective-root", default="")
    p_verify = sub.add_parser("verify-client-set")
    p_verify.add_argument("--project-root", required=True)
    p_verify.add_argument("--client-root", required=True)
    p_verify.add_argument("--expected-mirror", default="")
    p_verify.add_argument("--expected-fingerprint", default="")
    p_verify.add_argument("--expected-mode", default="")
    p_verify.add_argument("--selective-root", default="")
    args = parser.parse_args(argv)
    try:
        if args.command == "list-files":
            for rel in all_input_files():
                print(rel)
            return 0
        if args.command == "compute":
            values = compute_provenance(
                args.project_root,
                mirror_base_url=args.mirror_base_url,
                signing_fingerprint=args.signing_fingerprint,
                aws_semantic_contract_sha256=getattr(
                    args, "aws_semantic_contract_sha256", ""
                )
                or "",
                plan_checksum=getattr(args, "plan_checksum", "") or "",
                discovery_artifact_checksum=getattr(
                    args, "discovery_artifact_checksum", ""
                )
                or "",
            )
            if args.format == "json":
                print(json.dumps(values, sort_keys=True, indent=2))
            else:
                emit_env(values)
            return 0
        if args.command == "classify-client-set":
            state, action, current, reason = classify_client_set(
                args.project_root,
                args.client_root,
                args.expected_mirror,
                args.expected_fingerprint,
                args.expected_mode,
                selective_root=getattr(args, "selective_root", "") or "",
            )
            print("CLIENT_SET_STATE=%s" % state)
            print("CLIENT_SET_ACTION=%s" % action)
            print("CLIENT_SET_REASON=%s" % reason)
            if current:
                emit_env(current)
            if state == "CURRENT_VERIFIED":
                print("CLIENT_BUILD_PROVENANCE=PASS")
                print("CLIENT_SET_CURRENT_SOURCE=YES")
                return 0
            print("CLIENT_BUILD_PROVENANCE=FAIL", file=sys.stderr)
            print("CLIENT_SET_CURRENT_SOURCE=NO", file=sys.stderr)
            return 1
        values = verify_client_set(
            args.project_root,
            args.client_root,
            args.expected_mirror,
            args.expected_fingerprint,
            args.expected_mode,
            selective_root=getattr(args, "selective_root", "") or "",
        )
        emit_env(values)
        print("CLIENT_BUILD_PROVENANCE=PASS")
        print("CLIENT_SET_CURRENT_SOURCE=YES")
        return 0
    except Exception as exc:
        print("CLIENT_BUILD_PROVENANCE=FAIL", file=sys.stderr)
        print("CLIENT_SET_CURRENT_SOURCE=NO", file=sys.stderr)
        print("CLIENT_BUILD_PROVENANCE_REASON=" + str(exc).replace("\n", " "), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
