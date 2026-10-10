# DP OS Upgrade Lab E2E (destructive)

This runbook is **not** part of `tests/run_all.sh`.

## Requirements

- Disposable VM (marker file required)
- Hypervisor snapshot/backup decisions remain an operator responsibility; this
  lab runner does not check snapshot existence or require a reference string
- Root
- Fresh READY preflight (collector 1.0.2 → preflight)
- Exact destructive acknowledgment
- Lab hostname allowlist file: `/etc/dp-os-upgrade-lab-allowed`
- Operator approval reference

If `/etc/dp-os-upgrade-lab-allowed` is missing, the lab script refuses to run.

## Matrix

1. Xenial → Bionic  
2. Bionic → Focal  
3. Focal → Jammy  
4. Jammy → Noble  
5. Full Xenial → Noble  
6. SSH disconnect persistence  
7. Reboot auto-resume  
8. Mirror outage → retryable BLOCKED  
9. Mirror recovery → resume  
10. State corruption → fail closed  
11. Disk low → pre-start block  
12. NTP fail → pre-start block  
13. APT lock → pre-start block  
14. pause / unpause  
15. `/opt/aelladata` critical checksum validation  

## Command

The operator may optionally add `--snapshot-reference "lab-snap-id"` as a note;
the lab runner does not inspect or verify external snapshots.

```bash
sudo tests/e2e/run_dp_os_upgrade_lab.sh \
  --preflight /var/tmp/dp-upgrade-preflight-....tar.gz \
  --approval-reference "CHG-LAB-001" \
  --execute \
  --acknowledge-destructive-upgrade \
  "I_UNDERSTAND_THIS_OS_UPGRADE_IS_DESTRUCTIVE"
```

## Reporting discipline

Never claim lab E2E success from unit/simulated tests alone:

- Unit tests: PASS/FAIL from `tests/test_dp_os_upgrade.sh`
- Simulated integration: fake-root stubs
- Destructive lab E2E: only when this runbook is executed on an allowlisted disposable host


## Discovery one-hop example

```bash
sudo ./scripts/dp-os-upgrade-only.sh install \
  --execution-profile discovery \
  --preflight /var/tmp/dp-os-upgrade-preflight-....tar.gz \
  --stop-after-os 18.04 \
  --execute \
  --acknowledge-disposable-discovery-vm \
  "I_UNDERSTAND_THIS_DISCOVERY_VM_MAY_BE_LOST" \
  --acknowledge-destructive-upgrade \
  "I_UNDERSTAND_THIS_OS_UPGRADE_IS_DESTRUCTIVE"
```
