# DP Phase 2 bringup — source roles and provenance

This repository does **not** author the bringup script. The authoritative
upstream is the ACPS release artifact.

## A. Source roles

| Role | Term | Meaning |
|------|------|---------|
| ACPS artifact | `UPSTREAM_AUTHORITATIVE_SOURCE` | Unmodified bringup from the current ACPS release; immutable |
| Project patch layer | `scripts/lib/patch_dp_phase2_bringup.py` | Deterministic, fail-closed transforms applied **to that fresh upstream** |
| Generated bringup | `GENERATED_PATCHED_BRINGUP` | `current ACPS upstream + project patch layer` |
| Vendor bringup | reference / golden output | Last-known generated result for a recorded upstream SHA; **not** a production replacement for a newly downloaded ACPS file |
| Upstream checksum | `*.upstream.sha1` / `BRINGUP_UPSTREAM_SHA1` | SHA1 of the **unmodified** ACPS file |
| Patched checksum | `BRINGUP_PATCHED_SHA1` | SHA1 of the generated script |
| Patch generation | `BRINGUP_PATCH_GENERATION` | Identity of the project patch layer |

Do **not** copy `vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh` over a
freshly downloaded ACPS file. Field operators never edit the ACPS bringup
by hand. If required anchors are missing, Download and Prepare fails closed
(`BRINGUP_PATCH_COMPAT=FAIL`).

## B. Current provenance

- **Target DP version:** 6.6.0
- **ACPS bringup is versionless** (`bringup_py3_dp_after_os_upgrade.sh`).
  Exact generation is recorded via `BRINGUP_UPSTREAM_SHA1` / sidecar checksum.
- **Current validated upstream SHA1 (dark-site 6.6.0):**
  `3af369660c3e0dfb0b7421ab455dee1ced365b1d`
- **Reference / last-known unmodified upstream SHA1:**
  `70de02dd62409110dadb7553991d1ffb0a79f396`
  (recorded in `bringup_py3_dp_after_os_upgrade.sh.upstream.sha1`).
  Observability / change detection only. Download-and-prepare integrity is
  the current ACPS `.sha1` sidecar, not this reference hash.
- **Vendor file role:** developer-readable expected patched result for that
  known upstream generation. Production authority is always
  `fresh upstream + patch layer`.
- **Project-owned modifications currently applied by the patcher:**
  - `--worker-password` and sshpass credential handling
  - Worker orchestration failure propagation (`WORKER_RESULT`)
  - Master TCP/8003 readiness (`MASTER_TOKEN_API_READY`)
  - APT dependency graph hard gate (`APT_DEPENDENCY_CHECK`)
  - Critical Python runtime imports
  - Expected Kubernetes Ready node count (`CLUSTER_JOIN_STATE`)
  - Phase 2 Ubuntu prerequisite install hook
  - Image import heartbeat
  - Post-bringup DP pause/resume operator guidance

## C. Automatic upstream refresh

1. Download the current ACPS bringup and verify its `.sha1` sidecar.
2. Preserve an immutable upstream copy + `BRINGUP_UPSTREAM_SHA1`.
3. If the SHA differs from the last-known reference, log
   `UPSTREAM_BRINGUP_CHANGED=YES` (non-blocking).
4. Run the deterministic patcher against **that** upstream file.
5. Compatible anchors → `BRINGUP_PATCH_COMPAT=PASS` and a generated script.
6. Incompatible anchors → `BRINGUP_PATCH_COMPAT=FAIL` and prepare stops.
   No frozen vendor fallback.
7. Record `BRINGUP_PATCH_GENERATION` and `BRINGUP_PATCHED_SHA1`.
8. Publish the Phase 2 bundle. A change to either upstream content or the
   patch generation identity invalidates reuse.

## D. Explicit naming

- `UPSTREAM_AUTHORITATIVE_SOURCE`
- `GENERATED_PATCHED_BRINGUP`
- `BRINGUP_UPSTREAM_SHA1`
- `BRINGUP_PATCHED_SHA1`
- `BRINGUP_PATCH_GENERATION`
- `GENERATED_BUNDLE_ARTIFACT`
- `PUBLISHED_RELEASE`
