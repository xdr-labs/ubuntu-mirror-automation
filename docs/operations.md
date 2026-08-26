# Operations — Selective Offline Ubuntu Upgrade Mirror

This server builds a **discovery-exact selective offline upgrade mirror** for the DP LTS chain:

`Ubuntu 16.04 Xenial → 18.04 Bionic → 20.04 Focal → 22.04 Jammy → 24.04 Noble`

It is **not** a general full Ubuntu archive mirror.

## Scope

### Included

- Exact `.deb` payloads from `artifacts/upgrade-discovery` (4 hops)
- Hop-separated generated APT repositories (`Packages` / `Release` / `InRelease`)
- Local GPG signing (no unconditional `trusted=yes`)
- Release upgraders + local `meta-release-lts`
- `/ubuntu-security` nginx alias to the same selective tree
- Existing full mirror as **read-only seed** (hardlink/reflink/copy)

### Excluded

- Full `apt-mirror` Cartesian sync (`UNSUPPORTED_FULL_MIRROR_SYNC`)
- Official full by-hash materialization / Translation / DEP-11 / CNF / Contents
- Automatic deletion of the existing ~2.2TB seed mirror

## Install

```bash
cd ubuntu-mirror-automation
sudo ./install.sh --selective --no-menu --no-sync
```

Profile SSOT: `config/offline-upgrade-profile.json` (`offline-upgrade-selective`).

| Path | Purpose |
|------|---------|
| `/var/spool/apt-mirror/selective` | staging / published selective tree |
| `/var/spool/apt-mirror/mirror/...` | existing full seed (preserved) |
| `ubuntu-offline-mirror.sh` | plan / materialize / verify / publish / status |

## Selective workflow

Existing operator surface (`install.sh`, `mirrorctl`, systemd `apt-mirror.service`, nginx) runs the selective engine:

```bash
sudo ./install.sh                          # plan-selective + tooling
sudo mirrorctl sync start                  # materialize-selective (systemd)
sudo mirrorctl watch / status / logs
sudo ubuntu-offline-mirror.sh verify-selective   # staging / pre-publish only
sudo ubuntu-offline-mirror.sh publish-selective  # atomic publish + HTTP smoke + READY
sudo mirrorctl status
```

### Xenial→Bionic hop refresh (official single command)

After a suite-semantics fix (or when `xenial-to-bionic` was quarantined for
cross-release contamination), rebuild **only** the selective tree — never a full
apt-mirror sync:

```bash
sudo ./scripts/ubuntu-offline-mirror.sh refresh-hop-selective xenial-to-bionic
```

This runs, in order, under **one** global flock (`/run/ubuntu-offline-mirror.lock`):

1. `quarantine-hop-selective` (marks hop `QUARANTINED`, clears READY; other hops kept)
2. `plan-selective`
3. `materialize-selective` (reuses PASS staging when plan/discovery provenance matches;
   otherwise downloads missing files — never blindly wipes staging)
4. `verify-selective` (includes `SOURCE_SUITE_SEMANTICS` / `TARGET_SUITE_SEMANTICS`)
5. `publish-selective` (atomic publish; READY only on PASS)

Internal steps call `*_impl` functions in-process — they do **not** re-exec
`$0 verify-selective` / `$0 publish-selective` (that previously caused a
self-deadlock via a second `flock -n` on a new FD while the parent still held
the first). Concurrent standalone `verify-selective` / `publish-selective` from
another process still fail with `FAIL_SELECTIVE_MIRROR_LOCK_BUSY`.

If a prior run completed materialize (`validation_result=PASS` + matching
`plan_checksum` / `discovery_artifact_checksum`), refresh resumes with
`MATERIALIZE_REUSED=YES` / `REFRESH_RESUME_FROM=MATERIALIZED` and continues at
verify→publish without re-downloading. Provenance mismatch fails closed with
`FAIL_SELECTIVE_STAGING_PROVENANCE_MISMATCH` (staging is not auto-deleted).

Orchestration phase is recorded in
`selective/state/refresh-orchestration.json`
(`QUARANTINED` → `PLAN_READY` → `MATERIALIZED` → `VERIFIED` → `PUBLISHED` / `FAILED`).

Then rebuild the DP client against the new READY tree:

```bash
sudo ./scripts/ubuntu-offline-mirror.sh build-client-xenial-to-bionic \
  --mirror-base http://SERVER
```

### Repository suite semantics

Each hop keeps one URI (`/hops/<hop>/ubuntu`) so `do-release-upgrade` can rewrite
suite names in place. Indexes are **not** replicated across series:

| Path | Role |
|------|------|
| `dists/xenial*` | Source stabilization — Xenial packages only (may be empty Packages) |
| `dists/bionic*` | Target upgrade — discovery Bionic payloads |
| `pool/` | Shared `.deb` storage |

`verify-selective` fails closed on target versions appearing under source suites
(`FAIL_SOURCE_SUITE_TARGET_PACKAGE_CONTAMINATION`).

### Verification phases

| Step | Command | Target | Depends on nginx / `published/current`? | Writes READY? |
|------|---------|--------|----------------------------------------|---------------|
| 1 | `materialize-selective` | `selective/staging` | No | No |
| 2 | `verify-selective` | staging (pre-publish) | **No** | **No** |
| 3 | `publish-selective` | atomic switch + post-publish HTTP | Yes (concrete endpoints) | Yes, only if smoke PASS |

- `verify-selective` PASS means the staging tree is consistent; it is **not** yet published.
- Production nginx document root must be the canonical path
  `/var/spool/apt-mirror/selective/current` (symlink → `published` after publish).
- Legacy installs may still have `root /var/spool/apt-mirror/mirror;` — migrate with:
  `sudo ./scripts/ubuntu-offline-mirror.sh migrate-nginx-selective`
  (or `sudo mirrorctl nginx migrate`). Idempotent: timestamp backup → atomic replace →
  `nginx -t` → reload; restores backup on `-t` failure. Other nginx sites are untouched.
- `publish-selective` preflight checks effective nginx root, `nginx -t`, nginx active, and
  repository readability. Legacy/mismatched root fails immediately with
  `SELECTIVE_NGINX_EFFECTIVE_ROOT_MISMATCH` (no multi-endpoint HTTP probe).
- Post-publish smoke tests concrete `Release` / `InRelease` / `Packages(.gz)` / sample `.deb`
  URLs (and `/offline/meta-release-lts`). A 403/404 on `/` alone is **not** a failure.
- If post-publish HTTP fails, publish rolls back the previous `current` (or removes the failed publish) and does **not** write READY.
- `verify-selective` failure blocks `publish-selective`.

`sync` (full apt-mirror) is blocked under selective profile (`UNSUPPORTED_FULL_MIRROR_SYNC`).
nginx serves only `selective/current` → published tree (staging never exposed).

Cleanup of the seed full mirror is **never** automatic; see
`selective/state/cleanup-plan.json` after materialize.

## Legacy reference (pre-selective)

The following sections are retained for P0-2/P0-3/P0-4 operational detail
but READY/sync steps that require full apt-mirror/by-hash-3219 are obsolete.
Use plan-selective → materialize-selective → verify-selective → publish-selective.

## HTTP endpoints

```text
http://SERVER/ubuntu/
http://SERVER/ubuntu/dists/<suite>/InRelease
http://SERVER/ubuntu/dists/<suite>/Release
http://SERVER/hops/<hop>/ubuntu/dists/<suite>/Release
http://SERVER/offline/release-upgraders/<dist>/<dist>.tar.gz
http://SERVER/offline/meta-release-lts
http://SERVER/keys/ubuntu-mirror-selective.gpg
http://SERVER/client/                          # build-client artifacts (not part of READY tree)
http://SERVER/client/xenial-to-bionic/meta-release-lts
```

## Phase 1 — Ubuntu OS-Only Offline Upgrade

Phase 1 enables and validates **Ubuntu OS hops only** using the offline selective mirror:

`16.04 → 18.04 → 20.04 → 22.04 → 24.04`

**In scope:** root/OS identity, mirror GPG/suite semantics, disk/dpkg/APT health, critical OS package holds, `do-release-upgrade`, reboot, and post-boot OS validation.

**Out of scope (Phase 2):** DP product install/activation/registration, topology (AIO/DL-master/Worker), product containers/services, UI/data/topology compatibility.

- DP product install is **not** required. An uninstalled DP image (no `aella.role`, `installed=false`, no product containers) is a valid Phase 1 input.
- Product version/topology may be logged as diagnostics (`DP_*_GATE=SKIPPED_PHASE1_OS_ONLY`) but never hard-fail Phase 1.
- Phase 1 success = Ubuntu 24.04 boots with OS health PASS — not DP UI/service health.
- On **Jammy (22.04)** intermediate hops, DP runtime / `aella_cli` unavailability and the known kubelet Docker API 1.40 vs daemon 1.44 mismatch are **expected** and must **not** abort Phase 1. Do not repair kubelet/Docker/containerd/Kubernetes in Phase 1.
- After **Noble (24.04)** OS validation, create a **powered-off** VM snapshot before Phase 2. Phase 2 does **not** auto-start.

## Mirror environments (do not confuse)

Two active mirror environments exist. Neither is deprecated.

| Role | URL | Purpose |
|------|-----|---------|
| Development mirror | `http://221.139.249.111` | Cursor / development publication and retest |
| Stellar test mirror | `http://221.139.249.112` | Current field OS-upgrade / Phase 2 retest |

Reusable product code must not hardcode either address. Runtime mirror
configuration drives generated clients, launchers, manifests, Menu 7 commands,
and readiness checks. Client generations, launcher SHA256 values, signed
manifests, and public fingerprints must never be mixed between `.111` and `.112`.

- Commands signed or generated on `.111` are for development retest only.
- Stellar retest commands must be regenerated on `.112` via Menu 2 → 3 → 4 → 7.

See [architecture-phase2-source-bringup.md](architecture-phase2-source-bringup.md)
for Phase 2 source-version capture, staging progress, and bringup lifecycle.

### Phase 2 artifact staging (product bringup is separate)

**Support contract**

- Supported starting DP version: **6.2.0 or above** (auto-detected on the DP)
- DP Version / Phase 2 artifact version: **6.6.0** (bundle filenames remain versioned)
- Ubuntu OS is upgraded from 16.04 to 24.04; Phase 2 then installs DP 6.6.0
- Phase 2 bringup restores/upgrades the DP runtime to 6.6.0 after the OS upgrade
- Versions above 6.6.0 must not be downgraded
- A healthy host already on 6.6.0 on Ubuntu 24.04 normally needs no staging
- After Phase 1 OS-only upgrade (`COMPLETED_NOBLE`, product validation `NOT_RUN_PHASE1`), same-version staging (source already 6.6.0) is allowed only with explicit `--same-version-recovery` after a powered-off snapshot

**Client helpers (internal mirror `/client/`)**

```bash
# Canonical (Menu 7 default): same-version recovery after COMPLETED_NOBLE
sudo bash stage-dp-phase2.sh \
  --target-version 6.6.0 \
  --same-version-recovery \
  --mirror-url http://<internal-mirror>

# Read-only source version diagnosis (no download / mutation)
sudo bash stage-dp-phase2.sh --diagnose-source-version

# Compatibility wrapper (target fixed to 6.6.0; source auto-detected)
sudo bash stage-dp-phase2-6.6.0.sh \
  --same-version-recovery \
  --mirror-url http://<internal-mirror>
```

Staging never executes bringup. The original source DP version is captured during
the first OS hop when detection succeeds; later hops may lack `aella_cli` (expected
during OS-only Phase 1). Phase 2 recovers historical Phase 1 log evidence when
`source-product.env` is missing. Later `UNDETERMINED` log records do not erase
earlier complete PASS evidence. Failures emit source-specific diagnostics (not
generic `FAIL_UNKNOWN`). Staging prints progress about every 30 seconds.

`--source-dp-version` remains an optional operator fallback inside the stage
helper when auto-detection fails; Mirror Manager generated commands do not
include it. Prefer `--diagnose-source-version` before supplying an override.

**Bringup (after staging PASS)**

```bash
# Default: detached worker + foreground read-only monitor (survives SSH disconnect)
sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh \
  --version 6.6.0 --skip-download

# Return after handoff only
sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh \
  --version 6.6.0 --skip-download --detach

# Read-only
sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --status
sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --diagnose
```

Ctrl+C stops the monitor only; the worker continues. Instructional log text
containing `Bringup complete:` is not completion evidence. Do not check
`aella_cli` until `BRINGUP_RESULT=PASS`. Absence of `aella_cli` after verified
completion is a postcondition failure. `resume` is manual and conditional after
`show status`. Duplicate bringup while a worker is running attaches to the
existing run.

See [architecture-phase2-source-bringup.md](architecture-phase2-source-bringup.md).

Staging never executes `bringup_py3_dp_after_os_upgrade.sh`. Do not run bringup until `NTP_BRINGUP_READINESS=PASS` (internal NTP only).

`--source-dp-version` remains an optional operator fallback inside the stage
helper when auto-detection fails; Mirror Manager generated commands do not
include it.

**Mirror apply (SSH-safe interactive wrapper)**

`scripts/apply-dp-phase2-production.sh` never kills SSH. A trailing `exit "$rc"` in an interactive login shell **will** close the SSH session — that is wrapper misuse, not script behavior.

```bash
cd /home/aella/ubuntu-mirror-automation && {
  sudo bash scripts/apply-dp-phase2-production.sh
  rc=$?
  printf '\nAPPLY_DP_PHASE2_EXIT_CODE=%s\n' "$rc"
}
```

Generic sync entrypoint: `sudo bash scripts/download-dp-phase2.sh --version 6.6.0 sync`

Compatibility: `sudo bash scripts/download-dp-phase2-6.6.0.sh sync`

### Xenial → Bionic hop client (`UPGRADE_MODE=OS_ONLY_PHASE1`)

```bash
# On mirror host (after READY): render pinned single-file client script
sudo ./scripts/ubuntu-offline-mirror.sh build-client-xenial-to-bionic \
  --mirror-base http://221.139.249.111

# Deploy path for nginx /client/ (does not alter selective READY fingerprint)
# /var/spool/apt-mirror/client/
# Reload nginx after template migrate if /client/ is new:
sudo ./scripts/ubuntu-offline-mirror.sh migrate-nginx-selective
```

Deliverable: `artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh`

- Default mode: `OS_ONLY_PHASE1` (`--mode os-only`)
- Execution path: `run_os_preflight` → confirm → `run_os_upgrade` → post-boot `os_validation_result`
  (`run_product_preflight` / `run_product_post_upgrade` are not called)
- Confirmation phrase: `UPGRADE-XENIAL-TO-BIONIC`
- State root: `/opt/aelladata/os-upgrade/offline/`
- Log: `/var/log/aella/offline_os_upgrade.log`
- Units: `stellar-offline-os-upgrade.service`, `stellar-offline-os-upgrade-postboot.service`
- Stops after `COMPLETED_BIONIC` — does **not** auto-start 18.04→20.04
- Product diagnostics (optional INFO only; never invent AIO / never create `aella.role`):
  1. Shared `aella_cli` probe when present
  2. Authoritative keys in `/opt/aelladata/release-image.yml` for version logging
  3. Explicit vendor role files for topology logging
  4. Topology undetermined / Worker / DL-master / missing version → continue Phase 1
  5. Critical **OS** package holds are planned for automatic unhold after confirmation (not hard-fail); product-only holds remain ignored in Phase 1. Successful release upgrades do **not** auto-restore critical OS holds (deferred to Phase 2).

### Bionic → Focal hop client (`UPGRADE_MODE=OS_ONLY_PHASE1`)

See [operations-bionic-to-focal.md](operations-bionic-to-focal.md) for the full procedure.

```bash
sudo ./scripts/ubuntu-offline-mirror.sh build-client-bionic-to-focal \
  --mirror-base http://221.139.249.111
sudo ./scripts/deploy-client-bionic-to-focal-atomic.sh
```

- Deliverable: `artifacts/client/dp-offline-upgrade-bionic-to-focal.sh`
- Confirmation: `UPGRADE-BIONIC-TO-FOCAL`
- Terminal state: `COMPLETED_FOCAL` — does **not** auto-start 20.04→22.04
- Repository: `http://221.139.249.111/hops/bionic-to-focal/ubuntu`
- Integration tests must use a **clean** Bionic VM (never the Xenial→Bionic success evidence VM)

## Failure recovery

| Symptom | Action |
|---------|--------|
| Sync fails: root filesystem | Mount data disk at `/var/spool/apt-mirror` or set `ALLOW_ROOT_FS_MIRROR` only as last resort |
| Sync fails: free space | Expand data volume; do **not** delete mirror blindly |
| GPG upgrader failure | Re-run sync; check keyring `/usr/share/keyrings/ubuntu-archive-keyring.gpg` |
| `READY` missing after sync | Read `/var/log/ubuntu-offline-mirror.log`; fix failing check; re-run `verify`/`sync` |
| nginx 404 on `/ubuntu/` or `/hops/` after publish | Confirm `root` is `selective/current` (not `mirror`); run `migrate-nginx-selective`; `nginx -t`; reload |
| `SELECTIVE_NGINX_EFFECTIVE_ROOT_MISMATCH` | Runtime site still legacy; run `migrate-nginx-selective` then retry `publish-selective` |
| Concurrent sync | Wait; lock file `/run/ubuntu-offline-mirror.lock` |
| Need full-tree hashes | `sudo ubuntu-offline-mirror sha256-all` (expensive; optional) |

Do **not** automatically format disks, wipe the mirror, or run host `apt upgrade` as part of recovery.

## Git backup staging

Use this only to **stage and audit** a Git backup candidate. It does **not** commit or push.

### Warnings

- Do **not** paste multi-line `set -e` / `exit N` audit blocks into an interactive SSH shell.
  A failing `exit` in the current shell terminates the SSH session.
- Do **not** `source` (or `.`) the helper script into your login shell.
- Always run it as a **child** bash process:

```bash
bash scripts/prepare-backup-staging.sh --audit-only
bash scripts/prepare-backup-staging.sh --stage
```

### Modes

| Mode | Effect |
|------|--------|
| `--audit-only` | Read-only inspection. Does not change git index, `.gitignore`, or the worktree. |
| `--stage` | Stages approved paths, ensures exclude rules in `.gitignore`, then audits. On audit failure, restores the pre-run index (and any `.gitignore` edits from this run). Never commits or pushes. |

Private signing material such as `config/client-signing/offline-client-manifest.private.gpg` is never staged. Nested `ubuntu-mirror-automation/` and discovery/recovery/log artifacts are excluded.

Staged blobs are scanned for **complete** PEM/PGP private-key blocks (exact
`BEGIN`/`END` lines plus base64 payload). Bare marker substrings in docs, tests,
or detector source are not treated as secrets. There is no path allowlist.

Production client scripts are cross-checked per hop: top-level script, `.sha256`
sidecar, hop-directory copy, signed `client-manifest.json` (script hash field
when present in the schema), detached signature, and helper pins. Mismatches
print `ARTIFACT_HOP` / `EXPECTED_SHA256` / `ACTUAL_SHA256` and related fields.
Helper pins are updated only when artifacts are consistent and the pin is stale.

## Related commands

```bash
sudo mirrorctl status
sudo mirrorctl validate
sudo ./validate.sh
```
