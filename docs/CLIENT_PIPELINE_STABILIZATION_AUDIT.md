# Client Pipeline Stabilization Audit

Authoritative architecture reference for the DP Mirror Server client pipeline after
the `stabilize/client-pipeline-audit` implementation. This document inventories
call paths, reuse decisions, persistent/temporary paths, and security contracts.

**Real-server test boundary:** Everything in this change is validated with local
fixtures, synthetic Mirror Manager environments, and Docker userspace matrix tests.
It does **not** require or perform real R2 download, ACPS download, 30 GB Phase 2
rehash on production hardware, HTTP publication to a lab Mirror IP, or an actual DP
OS upgrade. Snapshot B retest on a real Mirror Server remains the operator boundary
documented in [CLEAN_SNAPSHOT_RETEST.md](CLEAN_SNAPSHOT_RETEST.md).

---

## Call and dependency graph

```
Configuration (Menu 1)
  └─ mm_wf_mark_configured
       PREPARATION_MODE, MIRROR_SERVER_IP, MIRROR_HTTP_URL, ACPS creds
       └─ CONFIG_SHA256 bound into workflow generation

Download and Prepare (Menu 2)
  └─ engine_download_and_prepare
       ├─ mm_check_client_build_prerequisites_ready   (tooling only; no hop clients)
       ├─ engine_verify_disk_space
       ├─ VERIFY_OR_ACQUIRE_OS_CORE
       │    ├─ r2_download_package (FULL only, when OS Core not reusable)
       │    ├─ engine_verify_os_core_package
       │    └─ engine_materialize_os_mirror → selective/state/READY + hops/*
       ├─ VERIFY_OR_ACQUIRE_PHASE2
       │    ├─ engine_assess_phase2_final
       │    │    ├─ release.env + sidecar metadata checks
       │    │    ├─ PHASE2_BUNDLE_VERIFY_MODE=FULL_HASH | VERIFIED_METADATA_REUSE
       │    │    ├─ mm_verify_sha256_pair_logged (PHASE2_EXISTING_SHA256_VERIFY)
       │    │    └─ mm_run_with_heartbeat (PHASE2_EXISTING_TAR_VERIFY)
       │    ├─ engine_remove_invalid_phase2_final (INVALID → delete before rebuild)
       │    ├─ acps_acquire_all + engine_place_dp_phase2_final (CREATE/REBUILD)
       │    └─ engine_mark_phase2_reused (VALID existing)
       ├─ mm_record_artifacts_prepared (OS + Phase 2 generation IDs)
       ├─ VERIFY_OR_REBUILD_CURRENT_CLIENT_SET
       │    └─ engine_finalize_local_client_set
       │         ├─ engine_verify_selective_ready_provenance
       │         ├─ engine_assess_client_set_for_finalize
       │         │    └─ client_build_provenance.py classify-client-set
       │         ├─ REUSE_CURRENT → engine_bind_reused_client_set_workflow
       │         └─ REBUILD_SIGN_PUBLISH → engine_rebuild_publish_local_client_set
       │              └─ scripts/rebuild-publish-clients.sh
       │                   ├─ client_build_provenance.py compute (bind digest)
       │                   ├─ build_client_*.py × 4 (local-fs selective inputs)
       │                   ├─ local_client_signing.sh (manifest + runner signatures)
       │                   ├─ verify-client-set (pre-swap)
       │                   └─ atomic_dir_swap.py (live client root)
       └─ mm_record_download_validated (does not demote CLIENT_SET_PUBLISHED)

Enable HTTP Distribution (Menu 3)
  └─ engine_enable_http_distribution
       ├─ engine_rebuild_publish_local_client_set (mirror URL pin refresh if needed)
       ├─ engine_render_nginx_site
       └─ mm_record_http_validated

Verify Upgrade Readiness (Menu 4)
  └─ mm_record_readiness_validated (artifact fingerprint match)

Menu 7 — DP Client Upgrade Commands
  └─ install-dp-upgrade-mirror.sh generate path
       ├─ mirror_workflow_state.sh generation gates
       ├─ WRAPPER_V1 one-line hash-pinned upgrade-<hop>.sh commands
       ├─ WRAPPER_V1 one-line upgrade-phase2.sh stage (inner SUBSHELL_V2)
       └─ published upgrade-<hop>.sh / dp-launch-<hop>.sh (+ .sha256 for client-set)

DP execution (off Mirror Server)
  └─ Step 2 one-line wrapper command
       ├─ curl upgrade-<hop>.sh → `.download`
       ├─ literal SHA256 pin (operator trust anchor; not HTTP sidecar)
       ├─ bash ./upgrade-<hop>.sh
       └─ wrapper authenticates existing launcher/runner
            ├─ isolated temp workdir + ephemeral GNUPGHOME
            ├─ gpgv + EXPECTED_FPR pin
            ├─ runner-manifest / hop script SHA bindings
            └─ unchanged dp-offline-upgrade-<hop>.sh
                 ├─ dp-offline-apt-preflight-sandbox.sh (target userspace APT auth)
                 ├─ Phase 1 OS-only dist-upgrade path
                 └─ dp-offline-release-upgrade-reconciliation.sh
                      (safe resume / exit 29 on real partial transition)
```

---

## Inventory

### Authoritative builders

| Path | Hop |
|------|-----|
| `scripts/lib/build_client_xenial_to_bionic.py` | xenial → bionic (16.04 → 18.04) |
| `scripts/lib/build_client_bionic_to_focal.py` | bionic → focal (18.04 → 20.04) |
| `scripts/lib/build_client_focal_to_jammy.py` | focal → jammy (20.04 → 22.04) |
| `scripts/lib/build_client_jammy_to_noble.py` | jammy → noble (22.04 → 24.04) |

Shared builder dependencies: `client_build_repository.py`, `client_build_provenance.py`,
selective tree under `SELECTIVE_ROOT`, local signing keypair.

### Client templates (`.sh.in`)

| Template | Injected helpers |
|----------|------------------|
| `client/dp-offline-upgrade-xenial-to-bionic.sh.in` | APT preflight, reconciliation, destructive confirmation |
| `client/dp-offline-upgrade-bionic-to-focal.sh.in` | same |
| `client/dp-offline-upgrade-focal-to-jammy.sh.in` | same |
| `client/dp-offline-upgrade-jammy-to-noble.sh.in` | same |
| `client/dp-postboot-readiness-policy.sh.inc` | post-boot policy include |

### Injected shared helpers (`client/lib/`)

| Helper | Role |
|--------|------|
| `dp-offline-apt-preflight-sandbox.sh` | Isolated `_apt` sandbox; temporary local `apt-get update` auth |
| `dp-offline-release-upgrade-reconciliation.sh` | Hop-scoped state; safe resume; exit 29 on real transition |
| `dp-offline-destructive-confirmation.sh` | Operator confirmation gate |

### Runner, launchers, and command generation

| Path | Role |
|------|------|
| `client/dp-client-hop-launcher.sh.in` | Authoritative OS-hop launcher template |
| `scripts/lib/build_client_launchers.py` | Deterministic generator for four hop launchers |
| `client/dp-launch-<hop>.sh` (published) | Inner hop launcher (verified by WRAPPER_V1 `upgrade-<hop>.sh`) |
| `client/upgrade-<hop>.sh` (published) | Hash-pinned Menu 7 operator entrypoint (WRAPPER_V1) |
| `client/dp-client-command-runner.sh` | Verified command execution wrapper |
| `scripts/install-dp-upgrade-mirror.sh` | Menu 7 command file generator |
| `scripts/lib/mirror_workflow_state.sh` | Generation-bound workflow KV store |

Launchers are part of the mutable client plane. A change to the launcher template,
generator, Mirror URL, signing fingerprint, hop mapping, or launcher schema version
updates `CLIENT_BUILD_INPUT_SHA256` and forces `CLIENT_SET_ACTION=REBUILD_SIGN_PUBLISH`.
OS Core and Phase 2 remain reusable (`OS_CORE_ACTION=REUSE_VERIFIED`,
`PHASE2_BUNDLE_ACTION=REUSE_VERIFIED`) for launcher-only rebuilds. After Snapshot B
restoration, Menu 2 must be run so launchers are regenerated with the current Mirror
URL and fingerprint.

### Runtime manifest dependencies

Installed via `lib/runtime_manifest.sh` → `um_runtime_install_tree`. Provenance
category `runtime_manifest` binds `lib/runtime_manifest.sh`. Pipeline category binds
`rebuild-publish-clients.sh`, `mirror_manager_common.sh`, `mirror_install_engine.sh`,
signing/permission helpers, Phase 2 staging scripts.

### Signing inputs

| Input | Location | Published? |
|-------|----------|------------|
| Local manifest private key | `/etc/ubuntu-mirror/client-signing/private.gpg` | **Never** |
| Local manifest public key (armored) | `client/public.gpg` | Yes |
| Binary gpgv keyring | `client/public-keyring.gpg` | Yes |
| Fingerprint sidecar | `client/signing-key-fingerprint`, `client/fingerprint` | Yes |
| Per-hop detached manifest signatures | `client/<hop>/client-manifest.json.asc` | Yes |
| Runner manifest signature | `client/runner-manifest.asc` | Yes |

Signing fingerprint is bound into `CLIENT_SIGNING_FINGERPRINT` and hop manifests.

### Generated public client files (after atomic swap)

Under `${MM_CLIENT_ROOT}` (default `/var/spool/apt-mirror/client/`):

- `dp-offline-upgrade-{xenial-to-bionic,bionic-to-focal,focal-to-jammy,jammy-to-noble}.sh` + `.sha256`
- `client/<hop>/client-manifest.json` + `.asc`
- `public.gpg`, `public-keyring.gpg`, fingerprint files
- `runner-manifest`, `runner-manifest.asc`, `dp-client-command-runner.sh` + `.sha256`
- `client-set.env` (provenance + generation metadata)
- `stage-dp-phase2.sh`, `stage-dp-phase2-6.5.0.sh` (+ `.sha256`)
- `lib/` copy of shared helpers (HTTP-served reference; hop scripts embed helpers)

### Generation and workflow state files

| File | Purpose |
|------|---------|
| `/etc/ubuntu-mirror/dp-upgrade-workflow.state` | Monotonic workflow phases + generation IDs |
| `/etc/ubuntu-mirror/dp-upgrade-mirror.conf` | Operator configuration |
| `/etc/ubuntu-mirror/dp-upgrade-mirror.status` | Status KV (HTTP, readiness, checksums) |
| `client/client-set.env` | Public client-set provenance binding |
| `selective/state/READY` | OS Core prepared marker + provenance checksums |

Workflow phases: `UNCONFIGURED → CONFIGURED → PREPARED → CLIENT_SET_PUBLISHED → HTTP_ENABLED → READINESS_VERIFIED → COMMANDS_GENERATED`.

### Client reuse decisions (`engine_assess_client_set_for_finalize`)

| State | Action | Meaning |
|-------|--------|---------|
| `ABSENT` | `REBUILD_SIGN_PUBLISH` | No hop scripts on disk |
| `PARTIAL_OR_MIXED` | `REBUILD_FULL_SET` | Incomplete set |
| `STALE_OR_WRONG_PIN` | `REBUILD_SIGN_PUBLISH` | Mirror URL pin mismatch in scripts |
| `STALE_LEGACY_METADATA` | `REBUILD_SIGN_PUBLISH` | Missing provenance schema fields |
| `STALE_BUILD_INPUT` | `REBUILD_SIGN_PUBLISH` | Digest / schema / command-block / mirror mismatch |
| `STALE_SIGNING_IDENTITY` | `REBUILD_SIGN_PUBLISH` | Fingerprint mismatch |
| `INVALID` | `REBUILD_SIGN_PUBLISH` | Tampered files / signature failure |
| `CURRENT_VERIFIED` | `REUSE_CURRENT` | Exact provenance + integrity match |

Heavy-artifact plane (independent): `OS_CORE_ACTION=REUSE_VERIFIED`, `PHASE2_BUNDLE_ACTION=REUSE` do **not** imply client reuse.

### Long-running operations and heartbeat contract

| Wrapper | Default interval | Log events |
|---------|------------------|------------|
| `mm_run_long_operation` | 30s (`MM_LONG_STEP_HEARTBEAT_SEC`) | `OPERATION_START`, `OPERATION_HEARTBEAT`, `OPERATION_END` |
| `mm_run_with_heartbeat` / `mm_bg_with_heartbeat` | 30s | `{PREFIX}_START`, `{PREFIX}_HEARTBEAT`, `{PREFIX}_COMPLETE` |
| Phase 2 existing verify | via above | `PHASE2_EXISTING_SHA256_VERIFY_*`, `PHASE2_EXISTING_TAR_VERIFY_*` |
| Phase 2 verify cache | status KV | `PHASE2_EXISTING_VERIFY_CACHE=MISS|STORED|HIT` |

Verified metadata reuse (`PHASE2_BUNDLE_VERIFY_MODE=VERIFIED_METADATA_REUSE`) skips full
bundle rehash only when bound fingerprint matches prior verified record.

### Target-OS compatibility assumptions

| Source OS | apt (expected) | Hop | Target |
|-----------|----------------|-----|--------|
| Ubuntu 16.04 | 1.2.x | xenial-to-bionic | 18.04 |
| Ubuntu 18.04 | 1.6.x | bionic-to-focal | 20.04 |
| Ubuntu 20.04 | 2.0.x | focal-to-jammy | 22.04 |
| Ubuntu 22.04 | 2.4.x | jammy-to-noble | 24.04 |
| Ubuntu 24.04 | 2.7.x | (target-side helper syntax) | — |

Clients must remain bash 4.3-compatible (Xenial). No `trusted=yes`, no `apt-key add`,
no Canonical archive fallbacks in templates.

### Persistent paths (production)

| Path | Content |
|------|---------|
| `/var/spool/apt-mirror/selective/` | OS Core hops, release upgraders, READY |
| `/var/spool/apt-mirror/dp-phase2/6.5.0/` | Final Phase 2 bundle + release.env |
| `/var/spool/apt-mirror/client/` | Published signed client set |
| `/var/spool/apt-mirror/.install-cache/` | ACPS/R2 cache, client-build staging |
| `/etc/ubuntu-mirror/client-signing/` | Local signing keypair |
| `/etc/ubuntu-mirror/dp-upgrade-workflow.state` | Workflow generations |
| `/var/log/ubuntu-mirror-automation/` | Evidence and command files |

### Temporary paths (cleaned after success)

| Path pattern | When |
|--------------|------|
| `${CACHE_ROOT}/client-build/<run-id>/` | Client build staging |
| `${CLIENT_HTTP_ROOT}.stage.XXXXXX/` | Pre-swap staging (removed on success) |
| `${MM_CACHE_ROOT}/acps-work/<ver>/<run-id>/` | Phase 2 bundle assembly workdir |
| `${MM_CACHE_ROOT}/r2/*.tar` | R2 package (removed after OS materialize) |
| APT preflight temp root inside hop client | Per-run isolated sandbox |

---

## Duplicate logic across four hops

Each `build_client_*.py` duplicates the same structural pipeline with hop-specific
constants (codenames, VERSION_ID pins, keyring install path, confirm phrase):

1. Load selective hop tree via `LocalHopRepository`
2. Render `.sh.in` template with embedded helper bodies
3. Inject `@@APT_PREFLIGHT_SANDBOX_HELPER@@` and reconciliation helper
4. Pin `MIRROR_BASE` URL and sample deb URLs
5. Build signed `client-manifest.json` with provenance fields
6. Emit SHA256 sidecar

Cross-hop shared logic that **should** remain centralized (and is):

- `client_build_provenance.py` — digest and classify
- `client_build_repository.py` — selective/local-fs IO
- `rebuild-publish-clients.sh` — four-hop orchestration, staging, atomic swap
- `local_client_signing.sh` — signing and gpgv gates
- Shared helpers in `client/lib/` (single source, injected at build time)

Residual duplication in the four builders is intentional hop isolation; provenance
binds all four builder files so any hop builder change forces client rebuild.

---

## Phase 1 policy (preserved)

- **Phase 1 is OS-only** — DP product validation does not block Phase 1 completion.
- **LTS hops cannot be skipped** — xenial→bionic→focal→jammy→noble sequence is fixed.
- **No manual state deletion** — operators must not delete workflow state, READY
  markers, selective/Phase 2 artifacts, or signing keys to force progress.
- **Real partial package transition → exit 29** — reconciliation fails closed; stale
  pre-baseline evidence is safely ignored; `--diagnose-state` performs zero mutation.

---

## Final implemented architecture

### Authoritative build provenance (schema version 1)

Module: `scripts/lib/client_build_provenance.py`

- `CLIENT_BUILD_INPUT_SHA256` — deterministic digest from sorted input file contents
  (mode + SHA256 per file), plus explicit pins: schema version, command-block version,
  mirror URL, signing fingerprint, Phase 1 hop definitions.
- **Excluded from digest:** timestamps, temp paths, generated client outputs, private
  keys, host inode values.
- Bound into `client-set.env` and signed hop manifests before atomic swap.
- `verify-client-set` runs immediately before `atomic_dir_swap.py`.

### Heavy vs client planes

Download and Prepare splits decisions explicitly:

```
VERIFY_OR_ACQUIRE_OS_CORE      → R2 only when not REUSE_VERIFIED
VERIFY_OR_ACQUIRE_PHASE2       → ACPS only when not REUSE
VERIFY_OR_REBUILD_CLIENT_SET → provenance classify → REUSE or rebuild
PUBLISH_CURRENT_CLIENT_SET     → atomic swap when rebuild required
```

Snapshot B restore with newer code: heavy artifacts reused; stale clients rebuilt.

### Heartbeat and Phase 2 verification cache

Long SHA256 and tar-list validation emit heartbeats every 30 seconds. A verified
metadata cache (`PHASE2_REUSE_VERIFIED_FINGERPRINT`, `PHASE2_REUSE_VERIFIED_SHA256`)
allows skipping full bundle re-read when bundle/sidecar/release.env metadata unchanged.

### Snapshot A / Snapshot B (operator)

See [CLEAN_SNAPSHOT_RETEST.md](CLEAN_SNAPSHOT_RETEST.md):

- **Snapshot A** — clean-before-download (tests full R2/ACPS/materialize path).
- **Snapshot B** — heavy-artifacts-verified (OS Core + Phase 2 valid; temp downloads
  cleaned; prefer taken before HTTP enable). After restore: install latest code, run
  Menu 2 (mandatory), then Menu 3 → 4 → 7.

---

## Security contracts (unchanged)

- Menu 7 OS-hop commands are `WRAPPER_V1` one-liners with a literal wrapper SHA256
  embedded in the copied command. The HTTP `.sha256` sidecar is **not** the operator
  trust anchor.
- The wrapper authenticates the existing launcher/runner (`EXPECTED_FPR`, `gpgv`, runner SHA).
- The runner authenticates and executes the unchanged OS-hop client.
- Phase 2 staging uses a `WRAPPER_V1` `upgrade-phase2.sh` one-liner; inner helper
  bootstrap remains `SUBSHELL_V2` inside the published wrapper.
- Private signing key never published under HTTP client root.
- Fail-closed APT authentication (exit 18) for mirror problems; exit 29 for real
  in-flight OS transition evidence.

---

## Related tests

| Test | Coverage |
|------|----------|
| `tests/test_dp_client_launcher_commands.sh` | Launcher generation, operator pin, negatives, provenance |
| `tests/test_client_build_provenance.sh` | Provenance cases 1–12, engine assess, workflow demotion |
| `tests/test_phase2_existing_reuse_progress.sh` | Phase 2 cache, heartbeat, metadata invalidation |
| `tests/test_client_os_userspace_matrix.sh` | Docker userspace matrix per hop |
| `tests/test_client_finalization_local_fs_integration.sh` | End-to-end local-fs four-hop build |
| `tests/test_apt_preflight_sandbox.sh` | Host APT sandbox contract |
| `tests/test_xenial_apt_1_2_authentication.sh` | Real Xenial container APT 1.2.x |
