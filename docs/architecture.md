# Architecture

## Current production model

This repository implements the **DP Ubuntu Upgrade Mirror Manager** for offline upgrade of Stellar Cyber DP hosts from Ubuntu 16.04 through 24.04, followed by DP Phase 2 bringup to the fixed target DP version 6.6.0.

The production control plane is **Mirror Manager only**:

1. **Configuration** — choose `FULL` or `PHASE2_ONLY`, confirm the Mirror Server IP, and enter optional cluster worker settings.
2. **Download and Prepare Upgrade Files** — prepare verified OS Core (FULL mode) and the immutable Phase 2 release.
3. **Enable HTTP Distribution** — publish the current client generation and enable/validate nginx.
4. **Verify Upgrade Readiness** — revalidate live HTTP plus generation/integrity receipts.
7. **Show DP Client Upgrade Commands** — emit SHA-pinned commands bound to the verified generation.

Legacy apt-mirror timer/full-sync and direct Phase 2 apply scripts are **not production control planes**. `mirrorctl` is production read-only; legacy mutations require an explicit dual-hermetic test gate.

## Trust and artifact flow

```text
Cloudflare R2
  ├─ pinned OS Core package (hard-coded SHA256 + byte size)
  └─ pinned Phase 2 release manifest + nine verified payload files
             │
             ▼
Mirror Manager
  ├─ selective/      verified four-hop Ubuntu OS Core
  ├─ dp-phase2/6.6.0 sealed Phase 2 bundle + prerequisite identity
  └─ client/         signed/generated DP clients + B/P/H-bound Phase 2 wrappers
             │
             ▼  HTTP :80 (nginx allowlisted publication only)
DP host
  ├─ Phase 1: 16.04 → 18.04 → 20.04 → 22.04 → 24.04
  └─ Phase 2: verify wrapper SHA → helper H → bundle B → prerequisite P → stage → bringup
```

### OS Core

- Source: validated Cloudflare R2 object.
- Production identity: fixed SHA256 and byte size in code.
- Materialization: staged and provenance-verified before no-gap live cutover.
- Existing verified OS Core is reused; an endpoint-only configuration change does not rebuild it.

### Phase 2

- Target DP version is fixed at **6.6.0**.
- R2 manifest is pinned by SHA256/size; every payload is verified against that manifest.
- The heavy bundle is generated with canonical tar metadata so identical validated inputs produce identical outer bytes.
- A sealed field release binds `PHASE2_BUNDLE_SHA256` and `PHASE2_PREREQ_IDENTITY_SHA256`; local patch/runtime drift must not redefine sealed bytes in place.
- Phase 2 wrappers bind helper generation **H**, bundle **B**, and prerequisite identity **P**.

### Client trust bootstrap

Menu 7 does not trust HTTP metadata as the initial root of trust. Each displayed download command contains the literal SHA256 of the wrapper/client being executed. The verified Phase 2 wrapper then enforces H/B/P.

## Transaction model

All publication paths follow the same rule:

**build candidate → validate candidate → atomic/no-gap cutover → persist authoritative receipt → commit previous generation**.

If a post-cutover step fails, the previous known-good generation is restored. This applies to the client set, selective OS Core, Phase 2 prerequisite publication, Menu 7 command file receipts, and DP Phase 2 staging artifacts.

Runtime reinstall is also staged and closure-verified before atomic cutover; a failed staged reinstall must not leave a mixed old/new `/usr/local/lib/ubuntu-mirror` tree.

## Workflow state and invalidation

Mirror Manager separates configuration identity into prepare, publication-endpoint, command-routing, and auth concerns. Changes invalidate only the layers they affect.

- **Heavy-input change** → Download and Prepare required.
- **IP / HTTP publication endpoint only** → heavy generations preserved; run Menu 3 → 4 → 7.
- **Command-routing only** → regenerate commands after readiness rules are satisfied.
- Menu 7 is blocked whenever readiness generation, live selective tuple, client generation, or command identity is stale.

Status and workflow receipt files are written atomically and in fail-closed order. A failed receipt write must never leave an authoritative PASS that can be consumed by the next step.

## HTTP publication boundary

nginx exposes only allowlisted public trees/files. Private cache/state, raw upstream payloads, private signing keys, dotfiles, symlink escapes, hardlink escapes, and special files are rejected by publication-boundary validation.

HTTP is controlled by Menu 3. `--dry-run` is read-only and cannot mint HTTP/workflow PASS receipts. Test-only skip flags are rejected outside explicit hermetic test mode.

## Runtime and service policy

- No background apt-mirror full-sync timer is part of the production DP Upgrade workflow.
- Unattended package upgrades on the temporary Mirror Server are disabled during bootstrap to prevent surprise service/package churn.
- `mirrorctl`/dashboard remain available for read-only observation and diagnostics; mutation belongs to Mirror Manager.

## Important paths

| Purpose | Path |
|---|---|
| Installed runtime | `/usr/local/lib/ubuntu-mirror` |
| Public CLI | `/usr/local/bin/ubuntu-offline-mirror` |
| Mirror Manager config | `/etc/ubuntu-mirror/dp-upgrade-mirror.conf` |
| Workflow receipt | `/etc/ubuntu-mirror/dp-upgrade-workflow.state` |
| Mirror root | `/var/spool/apt-mirror` |
| Selective OS Core | `/var/spool/apt-mirror/selective` |
| Phase 2 release | `/var/spool/apt-mirror/dp-phase2/6.6.0` |
| Published clients | `/var/spool/apt-mirror/client` |
| Mirror Manager logs | `/var/log/ubuntu-mirror-automation` |

For Phase 2 source-version, staging, bringup lifecycle, migration, and cluster-validation details, see `architecture-phase2-source-bringup.md`.
