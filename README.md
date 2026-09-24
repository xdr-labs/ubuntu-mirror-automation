<h1 align="center">DP Ubuntu Upgrade Mirror Manager</h1>

<p align="center">
  <strong>Offline upgrade orchestration for Stellar Cyber Data Processors.</strong>
</p>

<p align="center">
  Prepare one Ubuntu 24.04 Mirror Server, upgrade supported DP hosts through Ubuntu 16.04 → 24.04, then stage the validated DP 6.6.0 Phase 2 workflow.
</p>

<p align="center">
  <strong>English</strong> · <a href="README.ko.md">한국어</a> · <a href="https://dpos.xdr.ooo/">User & Operations Guide</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/target-DP%206.6.0-16A34A?style=flat-square" alt="DP 6.6.0">
  <img src="https://img.shields.io/badge/mirror-Ubuntu%2024.04-2563EB?style=flat-square&logo=ubuntu&logoColor=white" alt="Ubuntu 24.04 mirror">
  <img src="https://img.shields.io/badge/source-Cloudflare%20R2-F38020?style=flat-square&logo=cloudflare&logoColor=white" alt="Cloudflare R2">
</p>

---

## What it does

The Mirror Manager prepares and validates an offline upgrade path without requiring direct Internet access from the DP.

```text
Ubuntu 16.04
   ↓
Ubuntu 18.04
   ↓
Ubuntu 20.04
   ↓
Ubuntu 22.04
   ↓
Ubuntu 24.04
   ↓
DP 6.6.0 Phase 2
```

Current production artifact flow:

```text
Cloudflare R2
  ├─ selective Ubuntu OS Core
  └─ immutable DP 6.6.0 Phase 2 release
            ↓
      Mirror Server
            ↓ HTTP/TCP 80
         DP hosts
```

The current production path does **not** require DP hosts to download Phase 2 files directly from ACPS.

## Main workflow

Run the Mirror Manager:

```bash
sudo ubuntu-offline-mirror mirror-manager
```

Use the menu in this order:

```text
1  Configuration
2  Download and Prepare Upgrade Files
3  Enable HTTP Distribution
4  Verify Upgrade Readiness
7  Show DP Client Upgrade Commands
```

Do not start the DP upgrade until **Menu 4 reports PASS**.

Use **Menu 7** as the authoritative source for DP-side commands instead of assembling upgrade commands manually.

## Mirror Server requirements

Use a clean **Ubuntu 24.04 LTS amd64** host.

| Item | Current baseline |
|---|---|
| CPU | 2 vCPU minimum; 4 recommended |
| Memory | 4 GiB minimum; 8 recommended |
| Disk | 100 GB for the current artifact set |
| Network | Stable IPv4 reachable by DP hosts |
| DP → Mirror | TCP 80 |
| Mirror outbound | HTTPS to GitHub, Ubuntu package sources, and `downloads.xdr.ooo` |

The current artifact set requires substantial temporary build/download headroom. The application performs free-space preflight checks before large operations.

## Install

```bash
sudo apt-get update
sudo apt-get install -y git

git clone https://github.com/xdr-labs/ubuntu-mirror-automation.git
cd ubuntu-mirror-automation
sudo ./install.sh
```

If the GUI/TUI is not open later, do **not** reinstall. Reopen it with:

```bash
sudo ubuntu-offline-mirror mirror-manager
```

## Preparation modes

| Starting state | Mode | Result |
|---|---|---|
| DP 6.2.x–6.5.x on Ubuntu 16.04 | Full OS Upgrade + Phase 2 | Ubuntu 24.04 + DP 6.6.0 |
| Supported DP 6.2–6.5 already on Ubuntu 24.04 | Phase 2 Only | DP 6.6.0 Phase 2 |
| Healthy DP 6.6.0 on Ubuntu 24.04 | Normally no upgrade required | No change |

The Phase 2 target is fixed at **6.6.0** for the current workflow.

## Mandatory operator safety gate

Before running the generated upgrade commands on a DP:

1. Run the DP precheck.
2. Pause DP services.
3. Power off each DP VM/node.
4. Create a full hypervisor snapshot/checkpoint.
5. Power the node back on only after the snapshot/checkpoint completes.
6. Keep services paused until the documented upgrade step says otherwise.

The project does not provide an OS/runtime rollback mechanism:

```text
PROJECT_ROLLBACK_SUPPORTED=NO
OS_ROLLBACK_SUPPORTED=NO
DP_RUNTIME_ROLLBACK_SUPPORTED=NO
RECOVERY_METHOD=HYPERVISOR_SNAPSHOT
```

Menu 4 is the software-enforced readiness gate. Snapshot completion remains an operator responsibility.

## Dark-site move

A prepared Mirror Server can be moved from an Internet-connected staging area to a dark site.

After changing its IP address:

1. Open the Mirror Manager.
2. Update and save the Mirror Server IP.
3. Run Menu 2 → 3 → 4 → 7.
4. Use the newly generated Menu 7 commands.

Do not reuse commands generated for the old Mirror Server IP.

## Recovery after SSH disconnect

Reconnect and reopen:

```bash
sudo ubuntu-offline-mirror mirror-manager
```

Continue from the first incomplete step. Do not start a second copy of a still-running preparation job.

## Documentation

The maintained operator/runbook documentation is:

**https://dpos.xdr.ooo/**

Use it for:

- upgrade path selection
- mirror preparation
- snapshot sequencing
- cluster master/worker order
- retry/reuse behavior
- post-upgrade validation
- troubleshooting
- current vs. historical procedures

Repository references:

- [DP Upgrade Mirror Manager](docs/deployment/DP_UPGRADE_MIRROR_MANAGER.md)
- [OS Core Artifact Format](docs/deployment/OS_CORE_ARTIFACT_FORMAT.md)
- [Testing Guide](docs/development/testing.md)

---

<p align="center">
  <strong>Prepare once. Verify before upgrade. Keep the DP isolated.</strong>
</p>
