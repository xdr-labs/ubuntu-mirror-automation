# DP OS Upgrade Preflight (Phase 1 OS-only)

Canonical entrypoint: `scripts/dp-os-upgrade-preflight.sh`

Deprecated wrapper: `scripts/dp-upgrade-preflight.sh` (prints a warning and forwards).

## Purpose

Judge **Ubuntu LTS hop readiness only** from
`collect-dp-upgrade-readiness.sh` evidence.

Phase 2 (DP Python/Py3 bringup) is **not evaluated** as a readiness gate.
Collector may still record `aelladeb_py3` evidence; this preflight keeps it
informational only.

## Flow

```
Collector
→ OS-only Preflight
→ Discovery OS Hop (or production hop chain)
→ Package/File Analysis
→ Mirror/Offline Set completion
→ Repeat for the next OS hop
→ Reach Ubuntu 24.04
────────────────────────────────
→ Separate Phase 2 Readiness
→ DP Python/Py3 Bringup
```

## Execution profiles

| Profile | Snapshot/backup | Default hop scope |
|---------|-----------------|-------------------|
| `production` (default) | Required when OS upgrade needed | Full remaining LTS chain |
| `discovery` | Optional (INFO/WARNING if absent) | One hop (`max-hops=1`) |

Disposable VM acknowledgment is enforced by the **orchestrator** at `install`
time for discovery, not by this preflight.

## Canonical recommended_action

- `RUN_OS_UPGRADE`
- `NO_OS_UPGRADE_REQUIRED`
- `UNSUPPORTED`
- `BLOCKED` (overall status / unsupported plan)

Legacy inputs such as `RUN_PHASE1`, `RUN_PHASE1_AND_PHASE2`, and `RUN_PHASE2`
are normalized or ignored for Phase 1 gates.

## Examples

Discovery (no snapshot):

```bash
sudo ./scripts/dp-os-upgrade-preflight.sh \
  --collection /var/tmp/dp-upgrade-readiness-dp01-....tar.gz \
  --execution-profile discovery \
  --package-source-mode mirror \
  --package-source-url http://192.0.2.10 \
  --output-dir /var/tmp \
  --keep-directory
```

Production:

```bash
sudo ./scripts/dp-os-upgrade-preflight.sh \
  --collection /var/tmp/dp-upgrade-readiness-dp01-....tar.gz \
  --execution-profile production \
  --package-source-mode mirror \
  --package-source-url http://192.0.2.10 \
  --snapshot-reference "esxi-snapshot-id" \
  --output-dir /var/tmp
```

`--bringup-mode` is deprecated and ignored for READY/BLOCKED.

## Notes

- Read-only: does not mutate the host or collector input.
- Snapshot existence is not verified by this tool.
- Intermediate DP application health is not a Phase 1 criterion.
