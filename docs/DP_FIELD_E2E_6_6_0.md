# DP 6.6.0 field E2E — operator acceptance (FULL / PHASE2_ONLY)

This is the **owner-run, real-DP acceptance procedure** for the current
`xdr-labs/ubuntu-mirror-automation` `main` branch. It is not a substitute
for the actual Mirror Manager's readiness checks or the generated Menu 7
commands. The developer regression suite tests code; it cannot certify the
customer's specific mirror image, DP, snapshot, network, or cluster.

**Do not re-upgrade an already healthy, completed DL/DA Master.**
No automated test or script in this runbook changes Ubuntu, Stellar Cyber
packages, DP state, or cluster membership.

## 1. Choose the actual deployment mode and test target

| Actual DP state | Mirror Preparation Mode | DP command path |
| --- | --- | --- |
| Supported DP 6.2.x–6.5.x, **Ubuntu 16.04** | FULL | Menu 7 FULL steps 0–10; four OS hops then Phase 2 |
| Supported DP 6.2.x–6.5.x, **Ubuntu 24.04** | PHASE2_ONLY | Menu 7 Phase 2 steps 0–7; **no OS hops** |
| Healthy DP 6.6.0, Ubuntu 24.04 | Neither | **Stop**; record baseline, do not repeat bringup |
| Uncertain OS/DP version, failed/incomplete previous run | None until diagnosed | Preserve evidence; do not reset, force or skip a gate |

Use a snapshotted, approved **test DP** and maintenance window. Preserve the
last known-good production nodes. For cluster tests, record the actual DL/DA
Master and Worker IPs and confirm each Worker belongs to the intended role.
A configured Worker list is not proof the Worker has been upgraded.

## 2. Update the actual Ubuntu 24.04 Mirror Server

Only when no DP is actively downloading from the mirror, in the **existing
mirror repository** (do not run these commands on a DP):

```bash
cd ~/ubuntu-mirror-automation
git switch main
git pull --ff-only origin main
git rev-parse HEAD
sudo ./install.sh
```

Record the exact SHA and installation output. A first-time Ubuntu 24.04
Mirror Server instead uses the fresh-install commands in the root README.
The developer host `dev-drlink` is **not** the operational mirror and its
`MIRROR_NOT_INSTALLED` status does not validate the field mirror.

Open or reopen the actual operator UI with:

```bash
sudo ubuntu-offline-mirror mirror-manager
```

Select **Menu 1 Configuration**. Confirm the mode, advertised mirror IP and
DL/DA Worker lists. For a moved mirror/IP-only change, update the IP and
save; do not download the large OS/DP release again without a real stale
artifact/generation verdict.

**Existing signed clients may be older than the checked-in `.sh.in` source.**
Do not use an earlier printed command or manually edit a signed client.
For this source update, if the mirror has **not** rebuilt its OS client
generation from the updated templates, run **Menu 2 Download and Prepare**
to regenerate and sign the clients. Menu 2 may reuse already verified heavy
artifacts; do not delete existing validated payloads. In a verified
PHASE2_ONLY preparation, OS-hop files are **NOT REQUIRED**; do not force
a FULL preparation. For an unchanged, already-current generation, use the
Mirror Manager's reuse verdict rather than automatically re-downloading
large artifacts.

Then run, in order:

1. **Menu 3 — Enable HTTP Distribution.** Require successful nginx/HTTP
   smoke checks; if this fails, fix that mirror-side problem before the DP.
2. **Menu 4 — Verify Upgrade Readiness.** Require explicit `PASS`, valid
   signed client/helper generation, published HTTP reachability and required
   prepared artifact checks. `PREPARED` or a prior READY log is not
   today's PASS.
3. **Menu 7 — Show DP Client Upgrade Commands.** Choose the actual AIO/Cluster
   topology. Save the freshly generated output (also written to
   `/var/log/ubuntu-mirror-automation/dp-client-upgrade-commands.txt`).
   Do not copy commands from an older mirror IP or generation.

For a moved dark-site mirror, confirm each test DP can reach this mirror on
**TCP/80**. The DP must retrieve packages and Phase 2 only via the prepared
mirror; the DP itself must not be required to reach R2, ACPS or Ubuntu Internet
repositories.

## 3. Execute only the generated commands on the test DP

**STOP before any change** unless snapshot, role, pause and baseline are
confirmed. Menu 7 is the command authority; do not reconstruct one-line
wrapper URLs, SHA-256 values or worker parameters from this document.

For **FULL** (Ubuntu 16.04), follow Menu 7 steps **0–10** exactly:
precheck, pause inside `aella_cli`, power off, hypervisor snapshot,
power on, four sequential OS hops with reboot/reconnect verification,
then Phase 2 staging, bringup, resume if required and final health.

For **PHASE2_ONLY** (Ubuntu 24.04), follow Menu 7 steps **0–7**:
precheck, pause inside `aella_cli`, power off/snapshot/power on, Noble
prerequisite check (including shell, space and no active package manager),
staging, bringup, resume if required, final health. Never run the OS-hop
commands on an already-Noble DP.

For an **AIO**, run staging/bringup on that DP only.

For a **cluster**:
- Run the common precheck/snapshot/staging on **each intended node**. Complete
  staging on **all** nodes before any Master bringup.
- Run the generated DL Master bringup on **DL Master only**, followed by
  DA Master on **DA Master only** when those roles exist.
- Use the per-role **Menu 7 `--worker-ips`** command. A Master initiates
  its own Workers; **never manually run the Master bringup command on Workers**.
  The credential prompt is displayed at runtime on the Master, not saved
  in the mirror configuration or pasted as a command argument.
- A conditional master-only command applies only when that role genuinely
  exists and has no Workers. It cannot certify unseen Workers.
- **Skip any already healthy/completed Master** rather than forcing bringup
  again.

## 4. Check health and completion (manual, not automatically asserted)

After bringup reports `BRINGUP_RESULT=PASS`, on the relevant Master/AIO:

```bash
sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --validate-cluster
```

If paused, resume **inside `aella_cli` only**, not in Linux Bash. Then
rerun the same `--validate-cluster` command. Confirm expected role signals:
`All cluster nodes are ready`, `All host services are ready`, DL/AIO
license valid or DA/DR System Ready, and no explicit degraded/failed status
or incomplete intended Worker. Pod-count informational text alone is not
an authoritative failure.

**Do not interpret `BRINGUP_RESULT=PASS` as cluster completion.**
When source DP was 6.2/6.3/6.4, the operator must perform the documented
schema migration and verify it before recording its result. Use only the
Menu 7-specified `--record-post-bringup-migration PASS` and
`--record-cluster-validation PASS` commands after the corresponding
real operation/check has succeeded. Never record a fabricated PASS.

For a configured-worker run, require current-run
`WORKER_ORCHESTRATION=PASS` and `DP_WORKER_READINESS=PASS`. The
`DP_CLUSTER_UPGRADE_COMPLETE=YES` field applies only when all
configured-worker completion gates pass. For local/AIO or master-only
execution, `DP_UPGRADE_SCOPE=LOCAL_ONLY` and
`DP_CLUSTER_UPGRADE_COMPLETE=NO` **does not mean the local DP bringup
failed**; it means that run alone did not certify a Worker cluster.

Require final OS release, source/target DP version, services, index/model
health, Worker participation and no paused state to match the test plan.

## 5. Capture the evidence for PASS/FAIL

Record these fields before claiming field E2E PASS:

| Evidence | Actual field result |
| --- | --- |
| Exact mirror repository SHA + selected preparation mode | |
| Actual mirror Menu 2/reuse generation, Menu 3 and Menu 4 PASS | |
| Menu 7 saved commands and advertised mirror IP (no passwords) | |
| DP identity/role, original Ubuntu/DP version, test scope | |
| VM snapshot/checkpoint ID and rollback owner | |
| Pause state and each executed Menu 7 step result | |
| FULL OS hop result and final `/etc/os-release`, or PHASE2_ONLY proof | |
| Stage + bringup run ID, current-run result and target Worker results | |
| `--validate-cluster` outputs before/after resume, migration result | |
| Actual DP runtime version and post-run service/cluster health | |
| Final `DP_UPGRADE_COMPLETE` and applicable scope-specific result | |

Keep full failure output and run IDs; redact SSH credentials, license tokens,
private keys and customer-specific secrets. The user should provide the field
output for follow-up troubleshooting. A failed prerequisite, signed hash, HTTP
endpoint or Worker readiness must **stop that affected node** without
deleting state, rerunning completed Masters, forcing a package transition
or invoking a vendor repair unrelated to the observed defect.

**Acceptance labels:**

- `CODE_REGRESSION=PASS`: exact-main deterministic tests completed.
- `MIRROR_MENU4=PASS`: the actual mirror has passed today's readiness gate.
- `FIELD_DP_E2E=PASS`: the operator has actually executed and verified the
  applicable DP path and final runtime/cluster health.
- `ENGINEERING_FULL_USER_E2E=NOT_RUN` until a real, approved operator-persona
  surface mission on the same candidate has occurred. Code tests do not imply it.

The safe rollback boundary is **hypervisor/cloud snapshot restore**, not a
product-provided OS or DP runtime rollback command.
