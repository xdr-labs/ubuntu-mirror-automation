# Clean Snapshot Retest

Operator procedure for Mirror Server lab retests using two snapshot classes.
Follow every step in order. Stop on the first failure.

See also [CLIENT_PIPELINE_STABILIZATION_AUDIT.md](CLIENT_PIPELINE_STABILIZATION_AUDIT.md)
for architecture, provenance, and heavy-vs-client plane behavior.

---

## Mirror snapshots

### Snapshot A — clean-before-download

**Purpose:** exercise the full acquisition path from a clean disk.

- R2 OS Core download and verification
- OS mirror materialization and `selective/state/READY`
- ACPS Phase 2 download, bundle creation, and verification
- First-time client build/sign/publish

**When to use:** validating download/network/disk behavior, first install on a
fresh lab host, or after intentionally wiping `/var/spool/apt-mirror` and
`/etc/ubuntu-mirror` selective/Phase 2 content.

**Procedure:** follow sections 1–15 below from repository checkout through acceptance.
This is the original clean-room retest flow.

### Snapshot B — heavy-artifacts-verified

**Purpose:** reuse verified heavy artifacts while recalculating the mutable client set.

**Create Snapshot B after:**

1. Menu 2 completed successfully once (OS Core verified, Phase 2 bundle verified)
2. Temporary download artifacts cleaned (R2 package removed post-materialize;
   ACPS cache/work temps cleaned per engine policy)
3. **Prefer creating the snapshot before Menu 3 (HTTP enable)** so HTTP/nginx state
   is not part of the baseline

**What Snapshot B preserves:**

- `/var/spool/apt-mirror/selective/` including `state/READY`
- `/var/spool/apt-mirror/dp-phase2/6.6.0/` final bundle + sidecar + `release.env`
- `/etc/ubuntu-mirror/client-signing/` local signing keypair
- `/etc/ubuntu-mirror/dp-upgrade-workflow.state` and related upgrade state

**What Snapshot B does not replace:** latest product code — always `git pull` and
`sudo ./install.sh` after restore before running Menu 2.

### After restoring Snapshot B

1. Confirm the lab snapshot restored and the host rebooted (section 1).
2. Repository clean check + pull latest `origin/main` (sections 2–4).
3. `sudo ./install.sh` (section 5) — refreshes `/usr/local/lib/ubuntu-mirror` runtime.
4. Menu 1 Configuration — confirm mode, Mirror IP, ACPS credentials (section 6).
5. **Menu 2 Download and Prepare — DO NOT SKIP** (section 7).

   Expected heavy-artifact behavior when inputs unchanged:

   ```text
   OS_CORE_ACTION=REUSE_VERIFIED
   R2_DOWNLOAD_REQUIRED=NO
   PHASE2_BUNDLE_ACTION=REUSE
   ACPS_DOWNLOAD_REQUIRED=NO
   PHASE2_BUNDLE_REBUILD_REQUIRED=NO
   ```

   Client set behavior is recalculated from build provenance:

   ```text
   CLIENT_SET_ACTION=REUSE_CURRENT          # when CLIENT_BUILD_INPUT_SHA256 matches
   CLIENT_SET_ACTION=REBUILD_SIGN_PUBLISH   # when code/runtime inputs changed
   ```

6. Menu 3 → Menu 4 → Menu 7 (sections 8–11) only after Menu 2 PASS.

**Explicit Snapshot B rules — do not:**

- skip Menu 2 (it validates heavy artifacts and rebuilds stale clients)
- delete selective / OS Core artifacts
- delete Phase 2 bundle artifacts
- delete or rotate the local signing key by hand
- delete workflow state, READY markers, or command files
- create `selective/state/READY` manually

---

## Forbidden actions

Do **not**:

- manually delete workflow state, READY markers, or command files
- manually copy selective / Phase 2 / client artifacts
- delete or rotate the local signing key by hand
- set `PYTHONPATH` or copy runtime Python modules by hand
- run `tests/run_all.sh` as a substitute for this procedure
- enable nginx manually to bypass Menu 3
- edit `/etc/ubuntu-mirror/dp-upgrade-workflow.state` by hand

---

## 1. Snapshot restore complete

**Command:** confirm the lab snapshot is restored and the host has rebooted to Ubuntu 24.04.

**Expected:** clean host, Mirror Manager not yet reconfigured for this retest.

**Failure:** wrong snapshot or dirty disk state → restore again.

**Stop if:** previous retest leftovers remain under `/var/spool/apt-mirror` or `/etc/ubuntu-mirror` and the snapshot was supposed to be clean.

---

## 2. Repository clean check

```bash
cd /path/to/ubuntu-mirror-automation
git status --short
```

**Expected:** empty output (clean tree).

**Failure:** local modifications → `git reset --hard` / clean only if this is an intentional discard of uncommitted work.

**Stop if:** unrelated dirty files must be preserved.

---

## 3. Pull origin/main

```bash
git fetch origin
git checkout main
git pull --ff-only
```

**Expected:** fast-forward to current `origin/main`.

**Failure:** diverged local main → stop and resolve with the release owner.

---

## 4. Exact HEAD confirmation

```bash
git rev-parse HEAD
git log -1 --oneline
```

**Expected:** record the exact commit hash in the retest log.

**Failure:** unexpected branch tip → stop.

---

## 5. Install

```bash
sudo ./install.sh
```

**Expected output includes:**

```text
INSTALL_MODE=FRESH|REINSTALL
CONFIG_PRESERVED=...
SELECTIVE_PRESERVED=...
PHASE2_PRESERVED=...
SIGNING_KEY_PRESERVED=...
CLIENT_SET_PRESERVED=...
HTTP_STATE_BEFORE=...
HTTP_STATE_AFTER=...
HTTP_REENABLE_REQUIRED=...
NEXT_REQUIRED_ACTION=...
```

On a clean snapshot: `INSTALL_MODE=FRESH`, `HTTP_STATE_AFTER=DISABLED`, `NEXT_REQUIRED_ACTION=CONFIGURATION_REQUIRED`.

**Failure interpretation:**

- `RUNTIME_DEPENDENCY_CLOSURE=FAIL` → install aborted; do not continue
- `HTTP_REENABLE_REQUIRED=YES` on reinstall → follow Menu 3 after config/prepare, do not start nginx by hand

**Stop if:** install does not complete or reports missing runtime files.

---

## 6. Configuration

```bash
sudo ubuntu-offline-mirror mirror-manager
```

Menu **1 Configuration**:

1. Preparation Mode = **Full OS Upgrade + Phase 2**
2. Confirm **Mirror Server IP** (operator-confirmed; do not rely on auto-detect alone)
3. Enter ACPS username / password
4. Save

**Expected:** Configuration `[COMPLETED]`.

**Failure:** Mirror IP interface validation FAIL → fix networking or choose the correct host IP.

**Stop if:** ACPS credentials are wrong and connection test fails (download will fail later).

---

## 7. Download and Prepare

Menu **2 Download and Prepare Upgrade Files**.

**Expected:**

- OS Core (FULL) prepared
- Phase 2 6.6.0 bundle verified
- four hop clients built, signed, atomically published
- `PRIVATE_KEY_HTTP_PUBLISHED=NO`

**Failure:** network / checksum / client finalization errors → do not skip to Menu 7.

**Stop if:** `CLIENT_SET_ATOMIC_SWAP=NOT_STARTED` or client files incomplete.

---

## 8. Enable HTTP Distribution

Menu **3 Enable HTTP Distribution**.

**Expected:**

- `nginx -t` PASS
- local + advertised HTTP smoke PASS
- public tree modes `0755` / `0644` (directories / ordinary files; executable
  public scripts `0755`). Workflow state / credentials / signing material remain
  private (`0700`/`0600`) and are never published. Publication normalizes public
  trees explicitly so a prior private-state `umask 077` cannot leave HTTP 403.
- `HTTP_DISTRIBUTION=ENABLED`

**Failure:** smoke FAIL → nginx rolled back; artifacts preserved. Fix and retry Menu 3.

**Stop if:** HTTP remains disabled.

---

## 9. Verify Upgrade Readiness

Menu **4 Verify Upgrade Readiness**.

**Expected:**

```text
UPGRADE_READINESS=PASS
READINESS_VERIFIED_GENERATION_ID=<current publication generation>
```

**Failure:** generation mismatch or HTTP probe FAIL → return to Menu 3/2 as indicated.

**Stop if:** readiness is not PASS.

---

## 10. Menu 7 — DP Client Upgrade Commands

Menu **7 Show DP Client Upgrade Commands**.

**Expected:**

- one scrollable TUI viewer (`whiptail --textbox` with mouse tracking disabled), not `less`, not a terminal reprint
- mouse click/drag selects text via the SSH terminal (dialog mouse handling is disabled)
- keyboard navigation (Up/Down, PageUp/PageDown, Home/End) moves through the viewer
- ESC, `q`, or Exit closes only the viewer and returns to the Mirror Manager main menu
- only main-menu option **0** exits Mirror Manager
- FULL mode Steps 0–9 in one view
- each OS-hop command is exactly one physical line (`DP_OS_HOP_COMMAND_VERSION=LAUNCHER_V1`)
- each hop line downloads `dp-launch-<hop>.sh` into a `.download` name, verifies a
  literal SHA256 embedded in the command (not an HTTP `.sha256` sidecar), renames,
  then runs `bash ./dp-launch-<hop>.sh`
- Phase 2 staging remains a three-line `DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2` block
- file written atomically to `/var/log/ubuntu-mirror-automation/dp-client-upgrade-commands.txt`

If blocked:

```text
DP_CLIENT_COMMANDS_AVAILABLE=NO
BLOCK_REASON=...
REQUIRED_ACTION=...
```

**Failure:** follow `REQUIRED_ACTION` (Enable HTTP / Verify Readiness / regenerate).

**Stop if:** Menu 7 shows commands while HTTP is down.

After Snapshot B restoration, Menu 2 must be run so launchers are regenerated when
Mirror URL, signing fingerprint, or launcher source changes. OS Core and Phase 2
are not redownloaded for launcher-only client-set rebuilds.

---

## 11. Full command file generation verification

```bash
sudo grep -cE '^cd /home/aella && curl -fsSLo dp-launch-' \
  /var/log/ubuntu-mirror-automation/dp-client-upgrade-commands.txt
sudo grep -cE '^DP_OS_HOP_COMMAND_VERSION=LAUNCHER_V1$' \
  /var/log/ubuntu-mirror-automation/dp-client-upgrade-commands.txt
sudo test -s /var/log/ubuntu-mirror-automation/dp-client-upgrade-commands.txt \
  && stat -c '%a' /var/log/ubuntu-mirror-automation/dp-client-upgrade-commands.txt
```

**Expected:** launcher command count `4`, `LAUNCHER_V1` present, non-empty file mode `644`.

**Failure:** empty file or hop count 0 in FULL mode → do not use the file; regenerate via Menu 7 after readiness.

**Stop if:** command file is empty or PHASE2-only content while mode is FULL.

---

## 12. DP Step 2 execution

On the DP (after hypervisor snapshot), copy the **entire one-line Step 2 launcher
command** from the viewer into the DP terminal once. Do not edit the embedded SHA256.
Do not trust an HTTP `.sha256` sidecar as the operator trust anchor.

Mouse selection is terminal-controlled because Menu 7 disables dialog mouse handling.
Use keyboard navigation to move through the viewer.

**Expected:**

1. HTTP download of the hop launcher into `.download`
2. literal SHA256 verification PASS, then rename to the final launcher name
3. launcher authenticates the existing `dp-client-command-runner.sh` (keyring FPR,
   `gpgv`, runner SHA bindings)
4. runner authenticates and executes the unchanged OS-hop client

**Failure interpretation:**

- connection refused / HTTP 403/404 → Mirror HTTP not ready; return to Menu 3/4
- launcher SHA mismatch → stop; previous final launcher (if any) is not replaced
- runner/keyring/signature / hop SHA mismatch → stop; do not proceed

**Stop if:** any verification fails before `sudo bash` (execution count must remain 0).

---

## 13. Safe resume result check

If a previous FAILED legacy flag exists without post-baseline package transition:

**Expected:** safe resume (no manual state deletion).

If a real post-baseline package transition is detected:

**Expected:** exit `29` / manual review — do not delete state to force continue.

**Stop if:** exit 29 with real transition evidence — escalate per runbook.

---

## 14. Next hop progress condition

Proceed to the next OS hop only when:

1. current hop completed successfully
2. Mirror HTTP + readiness generations are still current
3. the next hop one-line launcher command is copied complete from Menu 7

Do not reuse a command file generated under a different Mirror IP, mode, or client generation.

---

## 15. Acceptance

Retest PASS only when:

- install reported HTTP state clearly
- FULL prepare → HTTP enable → readiness PASS for one generation
- Menu 7 emitted four one-line hash-pinned launcher commands (`LAUNCHER_V1`)
- DP Step 2 verified downloads without deleting prior `/home/aella` evidence on HTTP failure
- safe resume / exit 29 behavior matches policy
- no forbidden manual repairs were used

After evidence collection, restore the lab snapshot again for the next run.
