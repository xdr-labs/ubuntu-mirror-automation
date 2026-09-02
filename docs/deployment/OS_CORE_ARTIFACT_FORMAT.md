# Ubuntu OS Core artifact format

## Package layout

```
ubuntu-os-core/
├── manifest.json
├── payload.sha256
└── payload/
    ├── hops/
    │   ├── xenial-to-bionic/
    │   ├── bionic-to-focal/
    │   ├── focal-to-jammy/
    │   └── jammy-to-noble/
    ├── shared/
    ├── keys/                    # public key only, optional
    └── ubuntu -> hops/jammy-to-noble/ubuntu   # relative symlink
```

Transport name:

`ubuntu-os-core-xenial-to-noble-<release-id>.tar`

Sidecars:

- `*.tar.sha256` — mandatory outer integrity
- `*.tar.sha256.asc` — optional detached signature using the existing
  `config/client-signing` key (no new signing keys)

## Manifest schema

`schema_version: 1`, `artifact_type: ubuntu-os-core`.

Required fields include `release_id`, `created_at_utc`,
`source_repository_commit`, `supported_source_os`, `target_os`,
`supported_hops`, `payload_file_count`, `payload_bytes`,
`required_free_bytes`.

## Payload checksum

`payload.sha256` lists `SHA256  relative/path` for every regular file under
`payload/` (symlinks excluded from the digest list but validated for safety).

## Outer checksum / signature

Outer `.sha256` covers the tar blob. If `.asc` exists, verification is mandatory
with the configured public key (`OS_CORE_PUBLIC_KEY` / `--public-key`).

**R2 GPG hardening status (deferred):** production acquisition trust today is
HTTPS transport + mandatory outer SHA256 sidecar verification
(`scripts/lib/r2_acquire.sh`, `engine_verify_os_core_package`). Optional
`*.tar.sha256.asc` download is best-effort and is **not** authoritative unless a
pinned publisher trust root exists in-tree. Per-mirror
`config/client-signing` / `/etc/ubuntu-mirror/client-signing` keys are **not** an
R2 publisher trust anchor (they sign local client manifests). Enabling mandatory
R2 signature verification requires an external prerequisite: a published R2
`.asc` plus a repository-pinned publisher fingerprint/public key (do not invent
or import keys from public keyservers).

## Path safety

Rejected:

- absolute paths
- `..` components
- device/FIFO/socket files
- setuid/setgid
- absolute symlinks
- symlinks escaping the package/payload root

Relative in-tree symlinks (for example `ubuntu` → hop tree) are allowed because
the selective mirror layout uses them.

## Materialize on the mirror host

The Mirror Manager downloads this package from the fixed Cloudflare R2 URL,
verifies it, extracts into a temporary staging directory, then materializes a
**single** selective tree used by nginx (`/ubuntu/`, `/ubuntu-security/`,
`/offline/`, `/hops/`).

After success the downloaded archive is removed. The installer does not keep
`os-core-releases/`, `current`/`previous` symlinks, or `published.previous`
copies.

## R2

OS Core is always acquired from the code-fixed R2 URL
(`OS_CORE_R2_URL_CONSTANT` / `OS_CORE_R2_URL`). Operators do not enter a local
package path or R2 URL in the GUI. See
[DP_UPGRADE_MIRROR_MANAGER.md](DP_UPGRADE_MIRROR_MANAGER.md).

Production constant (custom domain):

```
https://xdrsolutions.uk/ubuntu-os-core/ubuntu-os-core-xenial-to-noble.tar
```

Checksum sidecar:

```
https://xdrsolutions.uk/ubuntu-os-core/ubuntu-os-core-xenial-to-noble.tar.sha256
```

Optional signature sidecar (currently not published / not a trust root):

```
https://xdrsolutions.uk/ubuntu-os-core/ubuntu-os-core-xenial-to-noble.tar.sha256.asc
```
