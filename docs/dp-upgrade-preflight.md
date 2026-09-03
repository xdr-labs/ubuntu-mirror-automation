# DEPRECATED

See [dp-os-upgrade-preflight.md](dp-os-upgrade-preflight.md).

# DP Upgrade Preflight

## Purpose

`scripts/dp-upgrade-preflight.sh` is a **read-only** judgment tool. It reads a
`collect-dp-upgrade-readiness.sh` result (directory or `.tar.gz`) and decides
whether a Stellar Cyber DP host may proceed toward Ubuntu 24.04 / DP 6.6.0 work.

It does **not** upgrade the OS or DP, change packages, shells, mounts, APT
sources, snapshots, or collector input.

| Tool | Role |
|------|------|
| `collect-dp-upgrade-readiness.sh` | Gather evidence only |
| `dp-upgrade-preflight.sh` | Judge READY / READY_WITH_WARNINGS / BLOCKED |
| `dp-os-upgrade-only.sh` | Phase 1 Ubuntu LTS hops to 24.04 (see `docs/dp-os-upgrade.md`) |

## Read-only guarantee

Allowed writes:

- `--output-dir` results
- a private temporary directory for archive extraction
- the final preflight `.tar.gz`
- cleanup of the script’s own temp files

Forbidden: `apt-get`/`dpkg` mutations, `apt-mark hold/unhold`, `do-release-upgrade`,
`chsh`/`usermod`, `systemctl` start/stop/restart/enable/disable, mount changes,
disk grow/resize, reboot, Docker/K8s lifecycle changes, rewriting collector input
or `/opt/aelladata` / upgrade state.

Optional `--live-check` may only perform DNS lookup, HTTP HEAD/limited GET, TCP
connect, and time queries. No package index refresh or large downloads.

## Supported input

`--collection PATH` may be:

- a collector result directory (`summary.json`, `findings.txt`, …)
- a collector `.tar.gz` (exact one top-level root; path traversal / absolute
  entries / escaping symlinks rejected)

Collector schema: **1.0**, script versions **1.0.1** and **1.0.2** (configurable).

## CLI

```bash
./scripts/dp-upgrade-preflight.sh \
  --collection PATH \
  --package-source-mode direct|cache|mirror \
  --bringup-mode online|offline \
  [--package-source-url URL] \
  [--snapshot-reference TEXT | --backup-reference TEXT] \
  [--output-dir DIR] \
  [--policy FILE] \
  [--live-check] \
  [--network-timeout SECONDS] \
  [--keep-directory] \
  [--help] [--version]
```

- `cache` / `mirror` require `--package-source-url`
- For any upgrade action other than `NONE`, at least one non-placeholder
  `--snapshot-reference` or `--backup-reference` is required for READY

### Package source modes

| Mode | Meaning |
|------|---------|
| `direct` | Use collector evidence for Canonical archives / old-releases / meta-release |
| `cache` | APT cache (e.g. approx on `:3142`); URL required; evidence or `--live-check` |
| `mirror` | Full/local mirror base URL; hop Release endpoints must be evidenced or live-checked |

Connectivity success (DNS/TCP) is **not** the same as repository availability
(HTTP 200 for `Release`). HTTP 404 is availability FAIL, not DNS failure.

### Bringup modes

| Mode | Phase 2 offline bundle (`aelladeb_py3`) |
|------|------------------------------------------|
| `offline` | Required when Phase 2 is part of the planned action |
| `online` | Local bundle optional; online artifact access must be operable (not invented here) |

Default policy: if recommended action is `RUN_PHASE1` only, missing `aelladeb_py3`
is a **warning** (future requirement). Legacy `aelladeb` never substitutes for Py3.

## Verdicts and exit codes

| Overall | Meaning | Exit |
|---------|---------|------|
| `READY` | No blockers or warnings/unknowns | `0` |
| `READY_WITH_WARNINGS` | No blockers; warnings or important unknowns remain | `10` |
| `BLOCKED` | One or more BLOCKER failures | `20` |
| CLI / input error | Bad options, missing paths, bad enums | `2` |
| Integrity / internal | Unreadable/invalid input structure, extract failure | `3` |

No-op (already Ubuntu 24.04 and DP ≥ 6.6.0):

- `overall_status=READY` (if clean)
- `recommended_action=NONE`
- `upgrade_required=false`

## Upgrade path rules

OS and DP are judged **independently**. LTS hops cannot be skipped.

- DP &lt; 6.2.0 → BLOCKED
- Ubuntu 16.04 + DP ≥ 6.2.0 → Phase 1 (four hops to 24.04)
- Ubuntu 24.04 + DP &lt; 6.6.0 → Phase 2 (separate workflow; this OS-only preflight does not execute it)
- Ubuntu 24.04 + DP 6.6.0 → typically Phase 1 no-op / already-target
- Ubuntu 24.04 + DP &gt; 6.6.0 → out of Phase 2 scope; **no downgrade** suggested
- DP 6.5.0 on Ubuntu 16.04 is **not** a no-op (Phase 1 still required)
- DP 6.5.0 on Ubuntu 24.04 is **not** same-version recovery; it is a Phase 2 upgrade to 6.6.0

## Policy

Defaults: `config/dp-upgrade-preflight.conf`

Thresholds (project defaults, **not** vendor-published minima) include root/boot/aelladata
bytes and inode percent. The file is parsed as safe `KEY=VALUE` only (never `source`d).

Effective policy is copied to `policy-effective.conf` in each result.

## Result layout

```text
dp-upgrade-preflight-<hostname>-<UTC>/
├── preflight-summary.json
├── preflight-summary.txt
├── checks.tsv
├── blockers.txt
├── warnings.txt
├── remediation.md
├── input-integrity.txt
├── evidence-map.tsv
├── execution.log
├── policy-effective.conf
└── source/collector-reference.txt
```

Plus `dp-upgrade-preflight-<hostname>-<UTC>.tar.gz`.

## Remediation re-run guidance

| Change | Re-collect? | Preflight-only OK? |
|--------|-------------|--------------------|
| Shell / holds / disk / APT / NTP / repos on host | Yes | No |
| Add snapshot/backup reference | No | Yes |
| Mirror contents / live reachability | Re-collect or `--live-check` | Often `--live-check` |

## Examples

### Full mirror, Phase 1 focus

```bash
sudo ./scripts/dp-upgrade-preflight.sh \
  --collection /var/tmp/dp-upgrade-readiness-dp01-20260716T011742Z.tar.gz \
  --package-source-mode mirror \
  --package-source-url http://192.0.2.10 \
  --bringup-mode offline \
  --snapshot-reference "esxi-dp01-before-ubuntu-upgrade-20260716" \
  --output-dir /var/tmp \
  --keep-directory
```

### Cache server

```bash
sudo ./scripts/dp-upgrade-preflight.sh \
  --collection /var/tmp/dp-upgrade-readiness-dp01-20260716T011742Z.tar.gz \
  --package-source-mode cache \
  --package-source-url http://192.0.2.10:3142 \
  --bringup-mode online \
  --snapshot-reference "change-ticket-CHG-12345" \
  --output-dir /var/tmp
```

### Live source verification

```bash
sudo ./scripts/dp-upgrade-preflight.sh \
  --collection /var/tmp/dp-upgrade-readiness-dp01-20260716T011742Z.tar.gz \
  --package-source-mode mirror \
  --package-source-url http://192.0.2.10 \
  --bringup-mode offline \
  --snapshot-reference "snapshot-id" \
  --live-check \
  --network-timeout 10 \
  --output-dir /var/tmp
```

### Phase 1 no-op host (already 24.04; DP 6.5.0 still needs Phase 2 to 6.6.0)

```bash
./scripts/dp-upgrade-preflight.sh \
  --collection /var/tmp/dp-upgrade-readiness-dp01-....tar.gz \
  --package-source-mode direct \
  --bringup-mode online \
  --output-dir /var/tmp
```

## Typical blockers

- Missing snapshot/backup reference (when upgrade is required)
- `aella` or `root` shell is `/usr/bin/aella_cli` (must be `/bin/bash`)
- Critical APT holds (`systemd`, `udev`, …) without project unhold/restore logic
- Insufficient `/`, `/boot`, or inode headroom
- Active APT/dpkg lock or dirty dpkg state
- NTP not synchronized
- Selected package source cannot prove Release availability for required hops
- Xenial Release 404 with no working old-releases/mirror fallback
- Offline Phase 2 planned without `aelladeb_py3`
- Unsupported OS/DP, conflicting/unknown DP version, corrupt upgrade state

## Limitations

- Snapshot/backup **existence** is not verified—only operator references
- Mirror/cache completeness without `--live-check` or collector HTTP evidence is blocked by default
- This repository currently has **no** OS-hop unhold/restore implementation; critical holds are blockers unless policy sets `PROJECT_MANAGES_CRITICAL_HOLDS=true`
- Online bringup artifact endpoints are not invented; confirm them in your bringup process
- Preflight does not replace a change window or restore drill

## Next step

After `READY` or an accepted `READY_WITH_WARNINGS`, the next component is the
**OS upgrade orchestrator** (not shipped in this change). It should consume
`preflight-summary.json` (upgrade plan, blockers cleared, package source mode,
snapshot reference) and perform LTS hops with explicit state under
`/opt/aelladata/os-upgrade/`.
