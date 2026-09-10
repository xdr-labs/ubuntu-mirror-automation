#!/usr/bin/env bash
# tests/lib/client_finalization_fixture.sh — production-shaped OS Core + signing fixtures
# for real four-hop local-fs client finalization tests.
# shellcheck shell=bash

client_fixture_require() {
  command -v gpg >/dev/null 2>&1 || { echo "gpg required" >&2; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; return 1; }
  command -v gzip >/dev/null 2>&1 || { echo "gzip required" >&2; return 1; }
}

# Create ephemeral GPG keys under $1/{selective,signing}
client_fixture_gen_keys() {
  local work="$1"
  local gpg_sel="${work}/gpg-selective"
  local gpg_sign="${work}/gpg-signing"
  mkdir -p "$gpg_sel" "$gpg_sign"
  chmod 700 "$gpg_sel" "$gpg_sign"
  cat >"${gpg_sel}/batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Fixture Selective Mirror
Name-Email: selective-fixture@local
Expire-Date: 0
%no-protection
%commit
EOF
  cat >"${gpg_sign}/batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Fixture Client Manifest
Name-Email: client-manifest-fixture@local
Expire-Date: 0
%no-protection
%commit
EOF
  gpg --homedir "$gpg_sel" --batch --gen-key "${gpg_sel}/batch" >/dev/null 2>&1
  gpg --homedir "$gpg_sign" --batch --gen-key "${gpg_sign}/batch" >/dev/null 2>&1
  mkdir -p "${work}/selective/keys" "${work}/client-signing"
  gpg --homedir "$gpg_sel" --batch --export --armor \
    >"${work}/selective/keys/ubuntu-mirror-selective.gpg"
  gpg --homedir "$gpg_sign" --batch --export-secret-keys --armor \
    >"${work}/client-signing/private.gpg"
  gpg --homedir "$gpg_sign" --batch --export --armor \
    >"${work}/client-signing/public.gpg"
  chmod 600 "${work}/client-signing/private.gpg"
  chmod 644 "${work}/client-signing/public.gpg"
  gpg --homedir "$gpg_sign" --batch --with-colons --fingerprint \
    | awk -F: '/^fpr:/ {print toupper($10); exit}' \
    >"${work}/client-signing/fingerprint"
  CLIENT_FIXTURE_GPG_SEL="$gpg_sel"
  CLIENT_FIXTURE_GPG_SIGN="$gpg_sign"
}

client_fixture_write_release() {
  local suite="$1" dest="$2"
  cat >"$dest" <<EOF
Origin: Ubuntu
Label: Ubuntu
Suite: ${suite}
Codename: ${suite%%-*}
Architectures: amd64
Components: main restricted universe multiverse
Description: Ubuntu ${suite} fixture
EOF
}

# Populate one hop under selective/hops/<hop>/ubuntu with signed InRelease + Packages + deb
client_fixture_populate_hop() {
  local sel_root="$1"
  local hop="$2"
  local source="$3"
  local target="$4"
  local gpg_sel="$5"
  local ubuntu="${sel_root}/hops/${hop}/ubuntu"
  local suite d

  for suite in "$source" "${source}-updates" "${source}-security" \
               "$target" "${target}-updates" "${target}-security"; do
    d="${ubuntu}/dists/${suite}"
    mkdir -p "${d}/main/binary-amd64"
    client_fixture_write_release "$suite" "${d}/Release"
    gpg --homedir "$gpg_sel" --batch --yes --clearsign \
      -o "${d}/InRelease" "${d}/Release" >/dev/null 2>&1
  done

  python3 - "$ubuntu" "$target" <<'PY'
import gzip, pathlib, sys
ubuntu = pathlib.Path(sys.argv[1])
target = sys.argv[2]
body = (
    b"Package: hello\n"
    b"Version: 2.10\n"
    b"Filename: pool/main/a/hello/hello_2.10_amd64.deb\n"
    b"Size: 1\n"
    b"SHA256: " + (b"0" * 64) + b"\n"
)
for suite in (target, target + "-updates", target + "-security"):
    p = ubuntu / "dists" / suite / "main" / "binary-amd64" / "Packages.gz"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(gzip.compress(body))
deb = ubuntu / "pool/main/a/hello/hello_2.10_amd64.deb"
deb.parent.mkdir(parents=True, exist_ok=True)
deb.write_bytes(b"x")
PY
}

client_fixture_populate_upgrader() {
  local sel_root="$1"
  local codename="$2"
  local gpg_sel="$3"
  local upg_dir="${sel_root}/shared/offline/release-upgraders/${codename}"
  local tmp
  mkdir -p "$upg_dir"
  tmp="$(mktemp -d)"
  printf 'ReleaseAnnouncement %s\n' "$codename" >"${tmp}/ReleaseAnnouncement"
  printf '<html>%s</html>\n' "$codename" >"${tmp}/ReleaseAnnouncement.html"
  ( cd "$tmp" && tar -czf "${upg_dir}/${codename}.tar.gz" ./ReleaseAnnouncement ./ReleaseAnnouncement.html )
  gpg --homedir "$gpg_sel" --batch --yes --detach-sign \
    -o "${upg_dir}/${codename}.tar.gz.gpg" "${upg_dir}/${codename}.tar.gz" >/dev/null 2>&1
  rm -rf "$tmp"
}

# Full four-hop production-shaped selective tree + READY provenance.
client_fixture_build_selective() {
  local work="$1"
  local sel="${work}/selective"
  mkdir -p "${sel}/state" "${sel}/keys"
  client_fixture_require
  client_fixture_gen_keys "$work"

  local hops=(
    "xenial-to-bionic:xenial:bionic"
    "bionic-to-focal:bionic:focal"
    "focal-to-jammy:focal:jammy"
    "jammy-to-noble:jammy:noble"
  )
  local entry hop source target
  for entry in "${hops[@]}"; do
    IFS=: read -r hop source target <<<"$entry"
    client_fixture_populate_hop "$sel" "$hop" "$source" "$target" "$CLIENT_FIXTURE_GPG_SEL"
    client_fixture_populate_upgrader "$sel" "$target" "$CLIENT_FIXTURE_GPG_SEL"
  done

  # Verified selective generation: plan.json + AWS contract + READY tuple.
  # Client builders require load_verified_selective_generation() (contract-bound).
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  python3 - "$sel" "$repo_root" <<'PY'
import os, sys, json, hashlib
from collections import OrderedDict
sel, root = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "scripts", "lib"))
import discovery_profiles as dp
import aws_os_core_completeness as aws_c

def ident(package, version, blob):
    sha = hashlib.sha256(blob).hexdigest()
    return OrderedDict([
        ("package", package),
        ("version", version),
        ("architecture", "amd64"),
        ("sha256", sha),
        ("filename", "%s_%s_amd64.deb" % (package, version)),
        ("size_bytes", len(blob)),
    ])

release_by_hop = {
    "xenial-to-bionic": ("5.4.0.1103.81", "5.4.0-1103-aws"),
    "bionic-to-focal": ("5.15.0.1084.91~20.04.1", "5.15.0-1084-aws"),
    "focal-to-jammy": ("6.8.0-1063.66~22.04.1", "6.8.0-1063-aws"),
    "jammy-to-noble": ("7.0.0-1011.11~24.04.1", "7.0.0-1011-aws"),
}
hops = OrderedDict()
for hop in dp.HOPS:
    ver, rel = release_by_hop[hop]
    img = "linux-image-%s" % rel
    la = ident("linux-aws", ver, ("CF|%s|linux-aws|%s" % (hop, ver)).encode())
    li = ident("linux-image-aws", ver, ("CF|%s|linux-image-aws|%s" % (hop, ver)).encode())
    vi = ident(img, ver, ("CF|%s|%s|%s" % (hop, img, ver)).encode())
    snap = None
    if hop == "xenial-to-bionic":
        snap = ident("snapd", "2.58+18.04.1", b"CF|x2b|snapd")
    hops[hop] = OrderedDict([
        ("hop", hop),
        ("source_series", hop.split("-to-")[0]),
        ("target_series", hop.split("-to-")[1]),
        ("source_version_id", aws_c.HOP_SOURCE_VERSION_ID[hop]),
        ("target_version_id", aws_c.HOP_TARGET_VERSION_ID[hop]),
        ("linux_aws", la),
        ("linux_image_aws", li),
        ("expected_kernel_releases", [rel]),
        ("versioned_images", [vi]),
        ("boot_packages", []),
        ("snapd", snap),
    ])
contract = OrderedDict([
    ("schema_version", aws_c.CONTRACT_SCHEMA_VERSION),
    ("discovery_profiles", ["generic", "aws"]),
    ("required_metapackages", list(aws_c.REQUIRED_AWS_METAPACKAGES)),
    ("hops", hops),
    ("by_target_version_id", OrderedDict(
        (aws_c.HOP_TARGET_VERSION_ID[h], h) for h in dp.HOPS
    )),
])
aws_c.attach_contract_sha256(contract)
plan_ck = hashlib.sha256(b"client-fixture-plan").hexdigest()
disc_ck = hashlib.sha256(b"client-fixture-discovery").hexdigest()
state = os.path.join(sel, "state")
os.makedirs(state, exist_ok=True)
plan = {
    "schema_version": 1,
    "profile_name": "offline-upgrade-selective",
    "discovery_profiles": ["generic", "aws"],
    "aws_semantic_contract": contract,
    "aws_semantic_contract_sha256": contract["contract_sha256"],
    "plan_checksum": plan_ck,
    "discovery_artifact_checksum": disc_ck,
    "validation_result": "PASS",
    "debs": [],
}
with open(os.path.join(state, "plan.json"), "w") as fh:
    json.dump(plan, fh, indent=2, sort_keys=True)
    fh.write("\n")
aws_c.write_aws_semantic_contract_bash(
    os.path.join(state, "aws-semantic-contract.sh.inc"), contract,
)
aws_c.write_ready_generation_marker(
    os.path.join(state, "READY"),
    plan_ck, disc_ck, contract["contract_sha256"],
)
# Prove generation loads.
aws_c.load_verified_selective_generation(sel, project_root=root)
print("CLIENT_FIXTURE_GENERATION=PASS")
print("CLIENT_FIXTURE_CONTRACT_SHA=%s" % contract["contract_sha256"])
PY
}

# Install a minimal runtime tree mirroring bootstrap layout under $work/runtime
# using the authoritative runtime manifest (never wildcard-copy scripts/lib).
client_fixture_install_runtime() {
  local repo_root="$1"
  local work="$2"
  local runtime="${work}/runtime"
  local runtime_root="${runtime}/usr/local/lib/ubuntu-mirror"

  mkdir -p \
    "${runtime}/usr/local/lib/ubuntu-mirror" \
    "${runtime}/var/spool/apt-mirror/.install-cache" \
    "${runtime}/var/spool/apt-mirror/client" \
    "${runtime}/var/spool/apt-mirror/selective" \
    "${runtime}/etc/ubuntu-mirror/client-signing"

  # shellcheck source=../../lib/runtime_manifest.sh
  source "${repo_root}/lib/runtime_manifest.sh"
  um_runtime_install_tree "$repo_root" "$runtime_root"

  echo "TEST_RUNTIME_SOURCE=AUTHORITATIVE_MANIFEST"
  echo "TEST_RUNTIME_WILDCARD_COPY=NO"
  echo "TEST_RUNTIME_LAYOUT_MATCHES_BOOTSTRAP=YES"

  # Place selective + signing into runtime paths.
  cp -a "${work}/selective/." "${runtime}/var/spool/apt-mirror/selective/"
  cp -a "${work}/client-signing/." "${runtime}/etc/ubuntu-mirror/client-signing/"
  chmod 600 "${runtime}/etc/ubuntu-mirror/client-signing/private.gpg"

  CLIENT_FIXTURE_RUNTIME="$runtime"
  CLIENT_FIXTURE_RUNTIME_ROOT="$runtime_root"
  CLIENT_FIXTURE_MIRROR_ROOT="${runtime}/var/spool/apt-mirror"
  CLIENT_FIXTURE_SELECTIVE="${runtime}/var/spool/apt-mirror/selective"
  CLIENT_FIXTURE_CLIENT_ROOT="${runtime}/var/spool/apt-mirror/client"
  CLIENT_FIXTURE_SIGNING_DIR="${runtime}/etc/ubuntu-mirror/client-signing"
  client_fixture_populate_dp_phase2 "${CLIENT_FIXTURE_MIRROR_ROOT}"
}

# Minimal published Phase 2 bundle sidecar for wrapper/client finalization tests.
client_fixture_populate_dp_phase2() {
  local mirror_root="${1:?mirror root required}"
  local ver="${2:-6.6.0}"
  local dp_root="${mirror_root}/dp-phase2"
  local dir="${dp_root}/${ver}"
  local tar="${dir}/dp_bundle_${ver}-current.tar"
  mkdir -p "$dir"
  printf 'client-fixture-phase2-bundle\n' >"$tar"
  (
    cd "$dir"
    sha256sum "dp_bundle_${ver}-current.tar" >"dp_bundle_${ver}-current.tar.sha256"
  )
  cat >"${dir}/release.env" <<EOF
TARGET_DP_VERSION=${ver}
PHASE2_ARTIFACT_VERSION=${ver}
DP_PHASE2_VERSION=${ver}
STABLE_BUNDLE_NAME=dp_bundle_${ver}-current.tar
VERIFICATION_RESULT=PASS
EOF
  chmod 0644 "${dir}/release.env"
}
