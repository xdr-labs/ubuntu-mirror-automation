# DP Ubuntu Upgrade Mirror Manager

## Purpose

Build a DP Ubuntu upgrade HTTP mirror server in one fixed workflow:

1. Bootstrap a clean Ubuntu 24.04 host with `sudo ./install.sh`
2. Configure Preparation Mode + ACPS credentials in the GUI
3. Download Ubuntu OS Core from Cloudflare R2 (FULL mode) or skip R2 (PHASE2_ONLY)
4. Verify OS Core checksums (FULL mode)
5. Download DP Phase 2 artifacts from ACPS (always 6.6.0)
6. Verify ACPS checksums (bringup SHA1 vs the current ACPS `.sha1` sidecar)
7. Apply the local patched bringup
8. Materialize one Phase 1 OS mirror set (FULL) and one Phase 2 6.6.0 bundle
9. Enable HTTP distribution (real nginx enable + smoke tests)
10. Serve clients over HTTP only

Contracts:

```
INSTALLATION_MODE_COUNT=1
OS_CORE_SOURCE=R2
DP_PHASE2_SOURCE=ACPS
CLIENT_R2_ACCESS=NO
CLIENT_ACPS_ACCESS=NO
CLIENT_DOWNLOAD_SOURCE=MIRROR_SERVER_ONLY
```

## Entrypoint

Fresh host bootstrap (authoritative):

```bash
git clone https://github.com/RickLee-kr/ubuntu-mirror-automation.git
cd ubuntu-mirror-automation
sudo ./install.sh
```

Re-open GUI after install (system command; no checkout required):

```bash
sudo ubuntu-offline-mirror mirror-manager
```

Repository-relative equivalents (development):

```bash
sudo ./scripts/ubuntu-offline-mirror.sh mirror-manager
sudo ./scripts/install-dp-upgrade-mirror.sh mirror-manager
```

## GUI menu

```
Workflow: Configuration → Download → Enable HTTP → Verify Readiness
Progress: 3 of 4 workflow steps completed

1 Configuration [COMPLETED]
2 Download and Prepare Upgrade Files [COMPLETED]
3 Enable HTTP Distribution [COMPLETED]
4 Verify Upgrade Readiness
5 Show Current Status
6 View Logs
7 Show DP Client Upgrade Commands
0 Exit
```

`[COMPLETED]` means the step is currently valid.
The label is removed automatically if its configuration, artifacts, HTTP service, or readiness state is no longer valid.
SHA256 verification displays a heartbeat every 30 seconds.

Order is intentional: enable HTTP before verifying readiness (readiness checks live HTTP URLs).

Menu 3 refuses to run until Download and Prepare has produced OS + Phase 2 artifacts.
Menu 4 refuses to PASS until HTTP distribution is ENABLED.

Menu 7 shows copy-paste one-line DP commands (download + checksum + execute) and
writes the same text to
`/var/log/ubuntu-mirror-automation/dp-client-upgrade-commands.txt`.

There is no install-mode menu, no local OS Core path picker, no R2/ACPS URL editor, and no rollback menu.

## Configuration

GUI fields:

- Preparation Mode (`FULL` or `PHASE2_ONLY`)
- Mirror Server IP
- ACPS Username / Password
- DL Worker IP addresses / DA Worker IP addresses
- Worker SSH Password (aella) — required when any worker IP is set
- Test ACPS Connection
- Save Configuration

Save is an **authoritative full save**: clearing a field and saving persists
empty (workers/`WORKER_SSH_PASSWORD` do not resurrect from disk). Internal
URL-only persistence uses a separate merge save so unrelated credentials are
not wiped.

Exact Configuration footer:

```
Starting DP Version: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0
Phase 2 Target:      6.6.0 (fixed)
DP OS version: 16.04

If the DP is already running Ubuntu 24.04, select Phase 2 Only.
```

Phase 2 Target is the fixed constant `PHASE2_TARGET_VERSION=6.6.0`.
It is not user-editable. Starting DP Version is auto-detected on the DP.
Mirror Server stores one Phase 2 bundle under `/dp-phase2/6.6.0/` only.

### Configuration change impact

Invalidation is dependency-scoped (not “any save resets everything”):

| Change | Earliest demotion | Preserved | Next action |
| --- | --- | --- | --- |
| No semantic change | none | everything | none |
| Worker IPs / worker password only | commands | artifacts, client set, HTTP, readiness | Menu 7 regenerate |
| ACPS username/password only | ACPS auth status | verified artifacts + readiness | re-test ACPS if acquisition needed |
| Mirror Server IP / HTTP URL | PREPARED (client/HTTP/readiness) | downloaded OS/Phase2 content | rebuild/republish clients |
| Preparation Mode FULL ↔ PHASE2_ONLY | CONFIGURED | on-disk cache files | Download and Prepare |

Semantic readiness identity uses content hashes, not config file inode/mtime.
A no-op Save after an identical rewrite does not force Download and Prepare.

Single/AIO (no worker IPs) bringup commands omit `--worker-ips` and
`--worker-password`. Cluster commands attach only the relevant DL or DA worker
list with a safely shell-quoted password (never logged).

Read-only:

- ACPS Server: fixed (`https://acps.stellarcyber.ai/provision/aelladeb_py3`)
- OS Core Source: Cloudflare R2 — configured by installer (FULL mode)

Credentials are stored root-owned mode `600` at
`/etc/ubuntu-mirror/dp-upgrade-mirror.conf` and redacted from logs.

Decision matrix:

| Starting DP | Starting OS | Action | Final State |
| --- | --- | --- | --- |
| 6.2 / 6.3 / 6.4 | 16.04 | Phase 1 + Phase 2 | DP 6.6.0 / Ubuntu 24.04 |
| 6.2 / 6.3 / 6.4 / 6.5 | 24.04 | Phase 2 Only | DP 6.6.0 / Ubuntu 24.04 |
| 6.5.0 | 16.04 | Phase 1 + Phase 2 | DP 6.6.0 / Ubuntu 24.04 |
| 6.6.0 | 24.04 healthy | No action | DP 6.6.0 / Ubuntu 24.04 |
| 6.6.0 | 24.04 recovery state | Gated same-version recovery | DP 6.6.0 / Ubuntu 24.04 |

Native Ubuntu 24.04 DPs (Phase 2 Only) resolve source product version from live
`aella_cli` when Phase 1 evidence is absent. Post-Phase1 hosts keep the
immutable evidence / fail-closed recovery model and do not trust live CLI over
persisted Phase 1 records.

## Download and Prepare

Automatic sequence: config check → client artifact check → R2 download
(`.part`, safe resume, retry) → OS Core verify/extract → ACPS download →
checksum → ACPS bringup sidecar check → non-blocking reference-SHA notice → patched bringup → Phase 2 bundle
(9 entries) → place final HTTP files → delete download cache/staging.

### Expected duration (disk-dependent)

These times vary by host disk throughput. A long silent gap is **not** normal:
the manager emits a heartbeat at least every 30 seconds during long steps.

| Step | Algorithm / action | Typical duration |
| --- | --- | --- |
| ACPS `images-*.tar` verification | **SHA256** (not SHA1) | approximately 5–10 minutes |
| Small ACPS sidecars / bringup | **SHA1** | seconds |
| Phase 2 bundle creation (`tar -cf`) | archive write | several minutes |
| Bundle SHA256 sidecar generation | **SHA256** full read | approximately 5–10 minutes |
| Final published bundle verification | **SHA256** after atomic publish | approximately 5–10 minutes |

Do not close the terminal or interrupt while heartbeats / progress lines are
printing. Logs show the current `DP_PHASE=` name and `elapsed=` seconds.

Integrity policy (same-filesystem hardlink pipeline):

- Source `images-*.tar` is SHA256-verified once after ACPS download.
- Hard-linked work-tree copies of that inode are not re-hashed.
- Bundle SHA256 is computed when the `.new` archive is created, then verified
  once more on the published final path (at most two full bundle reads).

Resume rules for the R2 package download:

- Requests send `Cache-Control: no-cache` and `Pragma: no-cache`.
- HTTP 206 with matching `Content-Range` start → append to `.part` only.
- HTTP 200 while a `.part` exists (Range ignored) → discard `.part` and replace
  (never append a full body onto a partial).
- Invalid `Content-Range` → fail; do not finalize.

## Enable HTTP Distribution

Not a status-only flag. On success the manager:

1. Validates prepared layout and client files (HTTP probes deferred until nginx is enabled)
2. Renders/installs the nginx site
3. Enables the site symlink and disables the default site when needed
4. Runs `nginx -t`
5. `systemctl enable` + reload/start nginx
6. Runs live HTTP validation (200-only smoke tests)
7. Sets `HTTP_DISTRIBUTION=ENABLED` only after smoke PASS

On failure the previous nginx site is restored and ENABLED is not recorded.

Pre-nginx layout checks may log `HTTP_VALIDATION=DEFERRED`; they must not warn
`SKIPPED_NETWORK`. Final Menu 3 success requires `HTTP_VALIDATION=PASS`.

## Client upgrade command order (Menu 7)

Menu 7 asks topology only (Single / Cluster). It never asks for Starting or Target DP Version.

**Full OS Upgrade + Phase 2**

1. Hypervisor snapshot
2. `aella_cli` → `pause` on Ubuntu 16.04
3. OS hops 16.04 → 18.04 → 20.04 → 22.04 → 24.04
   (Xenial→Bionic client sets aella/root login shells to `/bin/bash` after
   confirmation and re-verifies with `getent`; no manual `chsh`/`usermod`)
4. Stage DP 6.6.0 (`--target-version 6.6.0 --same-version-recovery`; source auto-detected)
5. Bringup (`--worker-ips` optional)
6. `aella_cli` → `resume`
7. `aella_cli` → `show status`

**Phase 2 Only** (DP already on Ubuntu 24.04)

1. Hypervisor snapshot
2. Verify Ubuntu 24.04 prerequisites
3. Stage DP 6.6.0 (source auto-detected)
4. Bringup
5. Resume when required
6. `show status`

Upgrade Readiness status values are exactly: `PASS`, `NOT VERIFIED`, `NOT READY`, or `FAIL`.
OS Upgrade Files may show `NOT REQUIRED` in Phase 2 Only mode.

## Storage

One final OS data set and one final DP bundle. No `releases/<timestamp>/`, no
`current`/`previous` symlinks, no `published.previous`. Keep only one DP Version
artifact set on the mirror host.

Final DP files:

```
/var/spool/apt-mirror/dp-phase2/<version>/release.env
/var/spool/apt-mirror/dp-phase2/<version>/dp_bundle_<version>-current.tar
/var/spool/apt-mirror/dp-phase2/<version>/dp_bundle_<version>-current.tar.sha256
```

The `current` token in the bundle **filename** is the existing client contract
name only; it is not a symlink generation.

OS selective tree is materialized directly under `selective/` for nginx paths
`/ubuntu/`, `/ubuntu-security/`, `/offline/`, `/hops/`. Client scripts remain
under `/client/` and must include hop scripts plus `stage-dp-phase2.sh` and
checksum sidecars (`CLIENT_FILES_READY` rejects an empty directory).

### Disk sizing

The mirror server stores:

- one Ubuntu selective OS data set
- one DP 6.6.0 Phase 2 bundle
- no source-version-specific bundles
- no historical releases
- no current/previous generations

A valid existing DP 6.6.0 bundle is reused.

It is not downloaded, rebuilt, replaced, or retained as an old generation
during normal operation.

If the final bundle is invalid, HTTP distribution is disabled and the invalid
bundle is removed before rebuilding.

The maximum large Phase 2 data present during a build is:

- one ACPS source set
- one new bundle

The projected peak including Ubuntu OS data is approximately 70 GiB.

Required mirror server disk:

100GB

The disk preflight must use actual free space and actual ACPS Content-Length,
and it must preserve at least 10 GiB of safety space.

120GB, 150GB, and 200GB are not required by this workflow.

Approximate artifact sizes (DP 6.6.0):

| Artifact | Size (approx.) |
| --- | --- |
| R2 OS Core / selective tree | ~3.4 GiB |
| Phase 2 final bundle | ~28.2 GiB (30307553280 bytes) |
| Host after successful prepare | ~40 GiB used on a clean Ubuntu Server |

Preflight free-space model (`CURRENT_AVAILABLE_BASED_REQUIRED_BYTES`):

```
OS_STAGE_EXTRA = OS payload temp + metadata
PHASE2_STAGE_EXTRA = ACPS source + new bundle + metadata   # 0 when REUSE
REQUIRED = max(OS_STAGE_EXTRA, PHASE2_STAGE_EXTRA) + SAFETY_RESERVE
```

Valid finals set `PHASE2_BUNDLE_ACTION=REUSE` so Phase 2 ACPS/bundle required
bytes are 0. Invalid finals are deleted before rebuild and are not counted as
future required. Selective OS data already on disk reduces `df` available and
is not double-counted.

Hard requirements:

- `MM_MIRROR_ROOT`, `.install-cache`, `selective`, and `dp-phase2` must share one
  filesystem (hard links + atomic rename). Split mounts are blocked in preflight.
- Large ACPS payloads are hard-linked into the work staging dir; automatic full
  copy of large files is refused.
- R2 OS Core package is removed immediately after selective OS materialize
  (before Phase 2 build).
- ACPS cache/work is deleted as soon as the verified `.new` bundle exists, before
  the atomic publish rename.
- Checksums and entry-count checks are never skipped.

Preflight logs structured fields (`DISK_PREFLIGHT_*`,
`CURRENT_AVAILABLE_BASED_REQUIRED_BYTES`,
`TOTAL_CAPACITY_BASED_PROJECTED_PEAK_BYTES`). Insufficient free space fails closed
with `DISK_PREFLIGHT=FAIL`.

## Bringup integrity and provenance

Authoritative integrity for `bringup_py3_dp_after_os_upgrade.sh` has two
blocking gates:

1. Current ACPS `.sha1` sidecar must match downloaded bytes
   (`ACPS_BRINGUP_CHECKSUM`).
2. `SHA256(upstream bytes)` must match a digest in the repository-controlled
   allowlist `vendor/dp-phase2/approved-upstream-bringup.sha256`
   (`UPSTREAM_BRINGUP_PROVENANCE`). Unknown digests fail closed with
   `UPSTREAM_BRINGUP_APPROVAL_REQUIRED=YES` — they are **not**
   `UPSTREAM_BRINGUP_DRIFT=NON_BLOCKING`.

HTTPS alone, same-channel sidecars, and patch-anchor compatibility are not an
approval root. New vendor bringup bytes require engineer review, patch
compatibility/tests, and an intentional allowlist update.

`vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1` is a
previously known reference SHA for change detection only. A mismatch after
provenance PASS is logged as `UPSTREAM_BRINGUP_CHANGED=YES` /
`UPSTREAM_BRINGUP_REFERENCE_MISMATCH=YES` and does not by itself fail the
install.

A changed-but-approved upstream must still pass syntax (`bash -n`) and
required patch anchors. Project modifications are then applied **to that
fresh upstream** by `scripts/lib/patch_dp_phase2_bringup.py`. Missing anchors
or a failed generation is fatal (`BRINGUP_PATCH_COMPAT` /
`PATCHED_BRINGUP_GENERATION` / `BRINGUP_PATCH_RESULT` /
`PATCHED_BRINGUP_SYNTAX`). The repository vendor full copy is a reference
artifact only and is never copied over a newly downloaded ACPS bringup.

Worker SSH uses `StrictHostKeyChecking=accept-new` with a persistent
project-owned `known_hosts` under `/var/lib/dp-phase2-bringup` (mode
`0700`/`0600`). TOFU does **not** cryptographically authenticate the first
connection; this provides persistent first-seen-key continuity and
changed-key rejection. Production paths do not silently fall back to a
process-local `/tmp` known_hosts file.

## Client HTTP only

## Test vs development Mirror addresses

Documentation examples only (RFC 5737; replace with the operator Mirror URL):

- Development Mirror Server example: `http://192.0.2.10`
- Test Mirror Server example: `http://198.51.100.10`

Clients published from a given Mirror must embed that same base URL for
`PIN_MIRROR_BASE`, APT sources, meta-release UpgradeTool URIs, and sample DEB
URLs. Do not point one environment's client runtime at another environment's
Mirror.

Optional HTTP `/client/<hop>/meta-release-lts` may be absent (HTTP 404). In that
case the signed embedded meta-release copy is authoritative
(`META_RELEASE_SOURCE=EMBEDDED_SIGNED_COPY`) and does not increment preflight
warnings.

Critical OS holds (for example systemd/udev) are unheld for the release upgrade.
They are restored only on pre-transition failure. Successful OS upgrades do not
automatically re-hold them, and Phase 2 does not re-hold them.

DP clients must use the mirror HTTP address only. They must not reach R2 or ACPS.

## Recovery boundary

```
PROJECT_ROLLBACK_SUPPORTED=NO
OS_ROLLBACK_SUPPORTED=NO
DP_RUNTIME_ROLLBACK_SUPPORTED=NO
RECOVERY_METHOD=HYPERVISOR_SNAPSHOT
RECOVERY_TARGET=PRE_UPGRADE_UBUNTU_16_04_STATE
INTERMEDIATE_OS_RECOVERY_SUPPORTED=NO
```

Create a full DP VM hypervisor snapshot before upgrade. Intermediate Ubuntu
versions are not recovery points. This project does not create or validate
snapshots and does not provide rollback commands.

The ACPS bringup file `bringup_py3_dp_after_os_upgrade.sh` is versionless.
Download and Prepare records its exact generation as `BRINGUP_UPSTREAM_SHA1`
together with `BRINGUP_PATCH_GENERATION` and `BRINGUP_PATCHED_SHA1` in
`release.env`. UVP and images must match the same `TARGET_DP_VERSION`.

## Production note

Repository tests use synthetic fixtures and mock HTTP only. Real R2/ACPS
downloads on a disposable fresh mirror VM require separate operator approval.
Bootstrap tests use temporary roots and must not modify production mirror data.
