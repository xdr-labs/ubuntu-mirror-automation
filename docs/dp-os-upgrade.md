# DP OS Upgrade (Phase 1 OS-only)

Phase 1 upgrades Ubuntu LTS hops only (16.04→24.04) in **OS-only** mode.
DP product install, topology, containers, and service health are **not** Phase 1 requirements
(an uninstalled DP image is a valid input). Phase 2 DP product validation/bringup is a
**separate** workflow and is never executed by these tools.

Execution profiles:
- `production` (default): snapshot/backup required; may run the full remaining hop chain
- `discovery`: disposable investigation VM; snapshot optional; default one hop (`max-hops=1`); ends in `CHECKPOINT_REACHED` until a new collector/preflight is supplied


## Purpose and scope

`scripts/dp-os-upgrade-only.sh` performs **Phase 1 only**: sequential Ubuntu LTS
hops on a Stellar Cyber DP host up to **Ubuntu 24.04 (noble)**.

| In scope | Out of scope |
|----------|--------------|
| Ubuntu 16.04→18.04→20.04→22.04→24.04 | DP 6.6.0 Py3 bringup |
| Resume after reboot | DP ≥ 6.6.0 upgrade |
| direct / cache / mirror package sources | UI upgrade |
| Data preservation under `/opt/aelladata` | Phase 2 execution |

**Phase 1 success is not full DP upgrade success.**

> Phase 1 OS upgrade completed.  
> Ubuntu 24.04 validation passed.  
> DP bringup has not been executed.

## Flow

```text
Collector (1.0.2)
  → Preflight (READY / READY_WITH_WARNINGS)
    → Phase 1 OS Upgrade (this tool)
      → Re-collect
        → Re-preflight
          → Phase 2 DP Bringup (separate workstream)
```

## Destructive work warning

This tool can rewrite APT sources, run `do-release-upgrade`, and reboot.

- Default CLI paths (`check`, `plan`, `status`, `validate`, `logs`) are read-only.
- `install` requires **root**, a valid fresh preflight, snapshot/backup reference,
  live safety checks, `--execute`, and the exact phrase:

  `I_UNDERSTAND_THIS_OS_UPGRADE_IS_DESTRUCTIVE`

Do **not** start `install` on a production DP while preflight is `BLOCKED`
(for example held `systemd`/`udev`, non-bash `aella` shell, or incomplete mirrors).

## Supported OS and hops

Supported LTS only (no skip):

| Start | Hops |
|-------|------|
| 16.04 xenial | 4 |
| 18.04 bionic | 3 |
| 20.04 focal | 2 |
| 22.04 jammy | 1 |
| 24.04 noble | no-op → `COMPLETED` |

Unsupported (blocked): ≤14.04, non-LTS intermediates, non-Ubuntu, unknown >24.04.

## Preflight input

`--preflight PATH` accepts a preflight **directory** or **`.tar.gz`**.

Required files: `preflight-summary.json`, `checks.tsv`, `blockers.txt`,
`warnings.txt`, `remediation.md`, `policy-effective.conf`,
`source/collector-reference.txt`.

Archives with absolute paths, `..`, multiple roots, escaping symlinks, device
nodes, FIFOs, abnormal hardlinks, or bomb-like size/entry counts are rejected.
Original inputs are never modified.

### Allowed recommended actions

- `RUN_OS_UPGRADE` — run Phase 1
- `RUN_OS_UPGRADE_AND_PHASE2` — run **Phase 1 only** (Phase 2 not started)
- `NONE` — Phase 1 no-op validation on 24.04

`RUN_PHASE2` alone is refused. `BLOCKED` preflight cannot be overridden.

### READY_WITH_WARNINGS

Automatic install is refused until every warning ID is accepted:

```bash
--accept-warning AELLADATA_SEPARATE_MOUNT
--accept-warning POST_OS_DP_REVALIDATION
```

Or all-at-once (all three required):

```bash
--accept-all-warnings \
--approval-reference "CHG-12345" \
--acknowledge-all-warnings "I_ACCEPT_ALL_PREFLIGHT_WARNINGS"
```

Acceptances and durable execute authorization are stored under
`/opt/aelladata/os-upgrade/operator-approval.json` (checksummed). Install also
records `execute_authorized` in `state.json`. Runners/reboot ignore a one-shot
shell `OSU_EXECUTE` flag and require that durable approval.

### Freshness

Default `PREFLIGHT_MAX_AGE_SECONDS=3600` from `completed_at_utc`.
Missing/invalid/future/stale timestamps block execution.
There is **no** `--allow-stale-preflight`. Re-collect and re-run preflight.

Also blocked on hostname, OS, package-source mode/URL, or snapshot mismatch.

## Live safety check

Even when preflight is READY, install re-checks hostname, OS, shells, disk/inodes,
`/opt/aelladata`, dpkg/apt locks and processes, NTP, repository Release/meta-release,
critical holds, and reboot/process conflicts.

Results: `/opt/aelladata/os-upgrade/live-precheck-<timestamp>.{json,txt}`.

## Package source modes

| Mode | Behavior |
|------|----------|
| `direct` | Canonical archives; Xenial may use `old-releases.ubuntu.com` **after** Release verification |
| `cache` | Keep Canonical URLs; set `Acquire::http::Proxy` to cache (e.g. `:3142`); no quiet HTTPS bypass |
| `mirror` | Internal base URL + `/ubuntu` (nginx SSOT) and `/offline/meta-release-lts`; **no** Canonical fallback |

Mirror layout is defined by `templates/nginx.conf` and `ubuntu-offline-mirror`:

- Packages: `http://MIRROR/ubuntu/dists/<codename>/Release`
- Metadata: `http://MIRROR/offline/meta-release-lts`

APT package mirror alone is not enough for offline `do-release-upgrade`.

## Held packages

Default `MANAGE_CRITICAL_HOLDS=false`. Critical holds (including `systemd`, `udev`)
**block** the upgrade. There is no unsupported automatic unhold path in this repo.
If project-approved allowlist logic is added later, it must be tested and
`CRITICAL_HOLD_ALLOWLIST` must be explicit.

## Third-party repositories

Identified files under `sources.list.d` are **moved** out of apt's scan path into
`/opt/aelladata/os-upgrade/repository-backup/disabled/` with a durable manifest
(original path, backup path, sha256, owner/mode, disabled_at, restore target).
They are **not** left as `*.disabled-by-dp-os-upgrade` under `sources.list.d`
(invalid apt filename extensions). They are **not** auto-reenabled after 24.04.

## State machine

States include: `NEW`, `PREFLIGHT_ACCEPTED`, `INITIALIZED`, hop states
(`HOP_PRECHECK` … `HOP_COMPLETED`), `REBOOT_REQUIRED`, `REBOOT_REQUESTED`,
`RESUME_REQUIRED`, `RESUMED`, `PAUSED`, `BLOCKED`, `FAILED`, `COMPLETED`.

- Transitions only via a central allow-list.
- `state.json` written atomically with SHA-256 sidecar.
- Checksum mismatch / orphaned evidence → fail closed (no silent re-init).
- Lock: `/run/lock/dp-os-upgrade.lock` (flock, mkdir fallback).

Runtime copies are pinned under `/opt/aelladata/os-upgrade/runtime/` and verified
on resume. Mid-flight runtime changes → `BLOCKED`.

## systemd / reboot / resume

Units: `systemd/dp-os-upgrade.service`, `dp-os-upgrade-resume.service`,
`dp-os-upgrade-resume.timer` (≈15 minutes, `Persistent=true`).

Reboot order: flush state → `REBOOT_REQUIRED` → sync → verify runtime/units →
`REBOOT_REQUESTED` → reboot. Timer retries **retryable BLOCKED** only.

## Pause / retry / failure

- `pause` sets a marker; does **not** kill apt/dpkg/`do-release-upgrade`.
- Honored at safe boundaries.
- Retryable BLOCKED: transient DNS/HTTP/NTP/apt-lock/network.
- Non-retryable BLOCKED / FAILED: no automatic retry.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success (query commands may return 0 even if state is BLOCKED) |
| 2 | CLI/input error |
| 3 | State/integrity/internal |
| 10 | Warning acceptance required |
| 20 | BLOCKED |
| 21 | PAUSED |
| 22 | RESUME_REQUIRED |
| 30 | FAILED |
| 40 | COMPLETED / Phase 1 no-op |

## Logs and reports

- `/var/log/aella/auto_os_upgrade.log`
- `/opt/aelladata/os-upgrade/events.jsonl`
- `/opt/aelladata/os-upgrade/hops/*/commands.tsv`
- Reports under `/opt/aelladata/os-upgrade/reports/`

## Example commands

```bash
sudo ./scripts/dp-os-upgrade-only.sh check \
  --preflight /var/tmp/dp-upgrade-preflight-dp01-....tar.gz

sudo ./scripts/dp-os-upgrade-only.sh plan \
  --preflight /var/tmp/dp-upgrade-preflight-dp01-....tar.gz

sudo ./scripts/dp-os-upgrade-only.sh install \
  --preflight /var/tmp/dp-upgrade-preflight-dp01-....tar.gz \
  --execute \
  --acknowledge-destructive-upgrade \
  "I_UNDERSTAND_THIS_OS_UPGRADE_IS_DESTRUCTIVE"

sudo ./scripts/dp-os-upgrade-only.sh status
sudo ./scripts/dp-os-upgrade-only.sh status --json
sudo ./scripts/dp-os-upgrade-only.sh logs --follow
sudo ./scripts/dp-os-upgrade-only.sh pause --reason "Maintenance window ended"
sudo ./scripts/dp-os-upgrade-only.sh unpause
sudo ./scripts/dp-os-upgrade-only.sh resume
sudo ./scripts/dp-os-upgrade-only.sh validate
```

## Recovery

Prefer hypervisor/snapshot rollback using the recorded snapshot reference.
Do not invent a fresh `install` over orphaned `/opt/aelladata/os-upgrade` evidence.
To preserve evidence without deleting it:

```bash
sudo ./scripts/dp-os-upgrade-only.sh archive-orphaned-state \
  --acknowledge-orphan-archive \
  "I_UNDERSTAND_THE_ORPHANED_STATE_WILL_BE_ARCHIVED"
```

This moves the directory to `/opt/aelladata/os-upgrade.orphaned-<UTC timestamp>` (never deletes).

Safe recovery helpers (run `diagnose` first; it prints `recommended_action`):

| Action | When |
|--------|------|
| `recover-lock` | `lock_class=STALE` (never clears a live flock/pid holder or active apt/dro) |
| `recover-not-started` | Sticky `REBOOT_*` / false `result.json=REBOOT_REQUIRED` while `do-release-upgrade` is `SKIPPED` / never started (`release_upgrade_evidence=NOT_STARTED`). Backs up state/result, records `FALSE_REBOOT_REQUIRED_DEMOTED`, sets `RESUME_REQUIRED` + `new_preflight_required=true`. Does **not** run apt, `do-release-upgrade`, or reboot. |
| `recover-current-release-update` | Current-release `dist-upgrade` finished (dpkg audit clean, `apt-get check`/`-s dist-upgrade` OK, stdout unpack/setup evidence) but wrapper timed out / state `FAILED`. Sets `RESUME_REQUIRED`, `last_successful_step=current_release_updated`, `current_hop=1`. Does **not** re-run apt install / dro / reboot. |
| `recover-resume-dispatch` | Stuck at `HOP_PRECHECK` after an illegal resume dispatch while `last_successful_step=current_release_updated`, hop=1, dro `NOT_STARTED`, lock `FREE`, and no destructive commands after the illegal transition. Backs up state, emits `RESUME_DISPATCH_RECOVERED`, restores `RESUME_REQUIRED` + `next_action=RUN_RELEASE_UPGRADE` + `new_preflight_required=true`. Does **not** run apt, `do-release-upgrade`, or reboot. |
| `resume` | After recovery, or mid-hop continue; when `new_preflight_required=true` use `resume --preflight <new.tar.gz> --execute ...` |

Resume stage resolver (`osu_resolve_resume_stage`, shared by runner + transitions) uses
`current_state`, `last_successful_step`, `next_action`, hop/OS, `release_upgrade_evidence`,
recovery evidence, and the latest hop command journal. `NOT_STARTED` means only that
`do-release-upgrade` has not started — never that the whole hop is incomplete.

| Stage | Meaning |
|-------|---------|
| `CONTINUE_SOURCE_PREPARATION` | Fresh / early hop — repository prep still required (`HOP_PRECHECK` → `HOP_SOURCE_PREPARING`) |
| `CONTINUE_CURRENT_RELEASE_UPDATE` | Source prep done; current-release apt update not complete |
| `CONTINUE_RELEASE_UPGRADE` | `last_successful_step=current_release_updated` + dro `NOT_STARTED` → `HOP_PRECHECK` → `HOP_RELEASE_UPGRADE_STARTING` (upgrader-core + dro only; no apt update/dist-upgrade/repo disable) |
| `CONTINUE_POST_UPGRADE_REBOOT` | Release upgrade success evidence present |
| `BLOCKED_INCONSISTENT_EVIDENCE` | State fields conflict with command evidence — fail closed, do not rewind |
| `request-reboot` | Only when `release_upgrade_evidence=SUCCESS` (OS at target, or `COMPLETED`/`SUCCESS` dro with `return_code=0` plus real dist-upgrade execution logs). `SKIPPED` + `rc=0` is never success. `result.json` alone never authorizes reboot. |
| operator intervention | `BLOCKED` / `FAILED` / live foreign lock |

`resume` validates under a short-lived lock then releases before invoking the runner (avoids CLI/runner self-deadlock on `/run/lock/dp-os-upgrade.lock`). Sticky `REBOOT_REQUESTED` while still on the hop source OS without success evidence does **not** authorize reboot. Command status `SKIPPED` means not executed (simulation/no-execute), even when `return_code=0`. Empty or stale `/var/log/dist-upgrade` directories (missing/outdated `main.log`/`apt.log`/`term.log`) are not execution evidence.

## Lab E2E

Destructive multi-hop E2E is **not** part of `tests/run_all.sh`.
See `docs/dp-os-upgrade-lab-e2e.md` and `tests/e2e/run_dp_os_upgrade_lab.sh`.

## Known limitations

- Ubuntu version-specific `do-release-upgrade` flags differ; noninteractive mode uses
  the conservative `DistUpgradeViewNonInteractive` frontend.
- Cache mode HTTPS/changelogs behavior depends on the cache product; misconfigured
  caches that leak to the internet are treated as policy failures, not success.
- Critical hold auto-management is intentionally disabled by default.
- Intermediate OS hops are not assumed to run full DP product services—only OS,
  package manager, login/SSH prerequisites, and `/opt/aelladata` preservation.
- Simulated unit/integration tests use stubs; they do not prove lab hardware success.