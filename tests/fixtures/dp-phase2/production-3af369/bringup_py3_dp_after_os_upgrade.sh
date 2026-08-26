#!/bin/bash
#
# bringup_py3_dp_after_os_upgrade.sh
#
# Restores a Data Processor to full operational state after an in-place OS upgrade
# chain (16.04 -> 18.04 -> 20.04 -> 22.04 -> 24.04) using Python 3 stack.
#
# After do-release-upgrade to 24.04, the DP is left in a broken state:
#   - Docker 18.06 and K8s 1.19 are broken/removed
#   - Python 2.7 is removed (24.04 doesn't ship it)
#   - All aella systemd services are stopped
#   - K8s cluster is destroyed
#   - /opt/aelladata/ data directory survives (da_conf.yml, configs, etc.)
#
# This is the Python 3 counterpart of bringup_py2_dp_after_os_upgrade.sh.
# For DP versions >= 6.5.0, we use this script (Python 3 + K8s 1.31 + containerd).
# For DP versions < 6.5.0, use the py2 script (Python 2.7 + K8s 1.19 + Docker 18.06).
#
# This script downloads all needed artifacts from acps.stellarcyber.ai and
# installs Docker (current noble major) + containerd, K8s 1.31, Helm 3.17, and
# all Stellar Cyber components to bring the DP back to full operational state.
# AELDEV-70673: expected Docker/containerd majors are EXPECTED_DOCKER_MAJOR
# and EXPECTED_CONTAINERD_MAJOR (see configuration section below).
#
# Key differences from py2:
#   - Python 3.12 is system-provided (no tarball needed)
#   - Docker 29.x + containerd 2.x (NOT Docker 18.06)
#   - K8s 1.31 (NOT 1.19), kubeadm v1beta3 API (NOT v1beta2)
#   - Helm 3.17 (new component, not in py2)
#   - containerd with systemd cgroup driver (NOT cgroupfs)
#   - cgroup v2 native (NO cgroup v1 mount)
#   - crictl for image pull (NOT docker pull)
#   - Flannel in kube-flannel namespace (NOT kube-system)
#   - imagePullSecrets on default SA
#   - resolv-kube.conf for musl/Alpine containers
#   - No heapster/influxdb (removed in py3)
#
# Supports: AIO, DR-master, DL-master, DR-worker, DL-worker
# Master can orchestrate workers via --worker-ips.
#
#
# ============================================================================
# USAGE EXAMPLES
# ============================================================================
#
#   # Step 1: Pre-upgrade cleanup (run on 16.04 BEFORE do-release-upgrade)
#   # Removes stale apt repos (kubernetes, nodesource, docker, nexus, etc.)
#   # that cause 404 errors and block the OS upgrade.
#   sudo bash bringup_py3_dp_after_os_upgrade.sh --pre-upgrade-cleanup
#
#   # Step 2: Run do-release-upgrade chain (manual, not part of this script)
#   # sudo do-release-upgrade  (repeat until 24.04)
#
#   # Step 3a: Standard bringup -- AIO DP (auto-detect role, downloads from ACPS)
#   sudo bash bringup_py3_dp_after_os_upgrade.sh --version 6.5.0
#
#   # Step 3b: Bringup with artifacts pre-staged locally (skip download)
#   sudo bash bringup_py3_dp_after_os_upgrade.sh --version 6.5.0 --skip-download
#
#   # Step 3c: Bringup DA/DL master only (no workers)
#   sudo bash bringup_py3_dp_after_os_upgrade.sh --version 6.5.0 --role DR-master
#
#   # Step 3d: Bringup DA/DL master + orchestrate workers automatically
#   sudo bash bringup_py3_dp_after_os_upgrade.sh --version 6.5.0 \
#       --worker-ips 10.0.0.2,10.0.0.3 --worker-key /path/to/worker-ssh-key
#
#   # Step 3e: Bringup with artifacts already staged (no download needed)
#   sudo bash bringup_py3_dp_after_os_upgrade.sh --version 6.5.0 --skip-download
#
#   # Dry run -- pre-flight checks only, no changes
#   sudo bash bringup_py3_dp_after_os_upgrade.sh --version 6.5.0 --dry-run
#
#   # Override role detection (useful if da_conf.yml missing/wrong)
#   sudo bash bringup_py3_dp_after_os_upgrade.sh --version 6.5.0 --role DL-master
#
#   # Worker mode (internal -- called by master during orchestration)
#   sudo bash bringup_py3_dp_after_os_upgrade.sh --version 6.5.0 \
#       --role DR-worker --worker-mode --skip-download
#
# ============================================================================
# WORKFLOW: Single Node / AIO
# ============================================================================
#
#   1. SSH to DP, take VM snapshot
#   2. sudo bash bringup_py3_dp_after_os_upgrade.sh --pre-upgrade-cleanup
#   3. sudo do-release-upgrade  (repeat until 24.04)
#   4. sudo bash bringup_py3_dp_after_os_upgrade.sh --version 6.5.0
#   5. Verify: kubectl get pods --all-namespaces  (all Running/Completed)
#
# ============================================================================
# WORKFLOW: DA/DL Cluster with Workers
# ============================================================================
#
#   1. Take VM snapshots of master + all workers
#   2. On master: sudo bash bringup_py3_dp_after_os_upgrade.sh --pre-upgrade-cleanup
#   3. On each worker: sudo bash bringup_py3_dp_after_os_upgrade.sh --pre-upgrade-cleanup
#   4. On master: sudo do-release-upgrade  (repeat until 24.04)
#   5. On each worker: sudo do-release-upgrade  (repeat until 24.04)
#   6. On master:
#        sudo bash bringup_py3_dp_after_os_upgrade.sh --version 6.5.0 \
#            --worker-ips <w1>,<w2> --worker-key /path/to/key
#      (master brings up itself first, then SSHes to workers and brings them up)
#   7. Verify: kubectl get nodes (all Ready), kubectl get pods -A (all Running)
#
# ============================================================================
# ARGUMENTS
# ============================================================================
#
#   --version <ver>           Required (bringup). DP version, e.g., 6.5.0
#   --skip-download           Use already-staged tarballs (skip download)
#   --worker-ips <ip1,ip2>    Comma-separated worker IPs for master to orchestrate
#   --worker-key <path>       (deprecated) Workers use sshpass (aella/aelladata)
#   --role <role>             Override auto-detect: AIO|DR-master|DL-master|DR-worker|DL-worker
#   --dry-run                 Pre-flight checks only, no changes
#   --skip-download           Use already-staged tarballs (skip download)
#   --pre-upgrade-cleanup     Clean stale apt repos, add correct Ubuntu repos, verify
#                             apt update/upgrade work. Run BEFORE do-release-upgrade.
#   --worker-mode             Internal: set when master SSHes to worker
#
# ============================================================================
# PHASES
# ============================================================================
#
#   Phase 0:  Pre-flight checks (root, 24.04, disk, role detect, version >= 6.5.0)
#   Phase 1:  Download artifacts (UVP, debs, pip3 packages, helm)
#   Phase 2:  Install Python 3 (system python3.12, pip3 packages, symlink)
#   Phase 3:  Install Docker 29.x + containerd (runc, containerd, docker.io debs)
#   Phase 4:  Install Kubernetes 1.31 (debs, CNI, kubelet drop-in, socat/ebtables)
#   Phase 5:  Install Helm 3.17 (extract tarball, copy binary)
#   Phase 6:  Install UVP via two-pass dpkg (never apt-get install -f)
#   Phase 7:  System preparation (sysctl, DNS, resolv-kube.conf, clean K8s state, flannel cleanup)
#   Phase 8:  Start 7 aella services in order with retry
#   Phase 9:  K8s master init -- kubeadm init, flannel, docker-secrets, imagePullSecrets,
#             fluent CRDs, monitoring, CoreDNS, node_configure.py (master/AIO)
#   Phase 10: Deploy K8s services -- kube-deploy.sh -m DR|DL|AIO up (master/AIO)
#   Phase 11: Install elasticdump (local tarball, npm fallback)
#   Phase 12: Comprehensive validation (Python3, Docker 29.x, K8s 1.31, Helm, services)
#   Phase 13: Orchestrate workers -- SCP artifacts, run --worker-mode, join cluster
#
# ============================================================================
# KEY DESIGN DECISIONS
# ============================================================================
#
#   - kubelet 10-kubeadm.conf drop-in: Required when K8s installed from deb offline
#     (deb package normally provides this). Without it, kubelet runs standalone
#     with no --kubeconfig/--config flags and cannot register with API server.
#     ROOT CAUSE of "timed out waiting for control plane" on DA cluster.
#
#   - Port 10250 handling: Phase 8 starts aella services which enables kubelet,
#     holding port 10250. Stop kubelet RIGHT BEFORE kubeadm init (after image
#     pull), with fuser -k fallback. Not earlier -- aella services restart it.
#
#   - systemd cgroup driver: Docker 29.x + containerd on 24.04 uses systemd
#     cgroup driver with cgroup v2 natively. No cgroup v1 mount needed.
#
#   - Two-pass UVP install: aella-uvp postinst extracts sub-debs; second pass
#     installs them. Never apt-get install -f (removes packages).
#
#   - pip3-site-packages.tar.gz: Pre-built from reference DP. Avoids PyPI deps.
#
#   - kubeadm v1beta3: K8s 1.31 uses v1beta3 API (NOT v1beta2 like K8s 1.19).
#
#   - resolv-kube.conf: Needed for musl/Alpine containers in K8s 1.31.
#     Copies nameserver lines from resolv.conf, strips cloud search domains,
#     appends "search .".
#
#   - containerd config.toml: SystemdCgroup = true under runc options.
#
#   - Idempotent: every phase checks if work already done. Safe to re-run.
#
#   - Master-first orchestration: master fully online before workers join.
#
#   - Default download from ACPS via curl with basic auth (HTTPS).
#
#   - bash (not source) for config_worker.sh: prevents exit/redirect from
#     killing parent script.
#
#   - crictl pull (not docker pull) for K8s system images: containerd is the
#     runtime for K8s 1.31, docker pull would put images in wrong store.
#
#   - Flannel in kube-flannel namespace (not kube-system): K8s 1.31 convention.
#
#   - imagePullSecrets on default SA: ensures all pods can pull from Docker Hub.
#
#   - Version guard: Only >= 6.5.0 supported (py3 DP introduced in 6.5.0).
#
# ============================================================================
# JIRA: AELDEV-68149
# ============================================================================

set -euo pipefail

###############################################################################
# GLOBALS
###############################################################################
VERSION=""
WORKER_IPS=""
ROLE=""
DRY_RUN=false
SKIP_DOWNLOAD=false
DNS_FALLBACK_LINES=""  # public nameservers appended by preflight (revertible)
WORKER_MODE=false
PRE_UPGRADE_CLEANUP=false
AUTO_OS_UPGRADE=false
RECLAIM_OVERLAY2_ONLY=false
RELABEL_ELASTIC_ONLY=false

LOG_FILE="/var/log/aella/aella_py3_bringup.log"
DA_CONF="/opt/aelladata/work/da_conf.yml"
STAGING_DIR="/opt/aelladata/aelladeb_py3"
AELLADEB_DIR="/opt/aelladata/aelladeb"
# Also check the provision path (files may be pre-staged there by tarball extraction)
PROVISION_STAGING_DIR="/opt/aelladata/work/metarepo/root/provision/aelladeb_py3"

# Support server (default download source -- no key needed)
ACPS_HOST="acps.stellarcyber.ai"
ACPS_USER="AellaMeta"
ACPS_PASS='WroTQfm/W6x10'
ACPS_PROVISION_URL="https://${ACPS_HOST}/provision/aelladeb_py3"
ACPS_COMMON_TARBALL="aelladeb_py3_common.tar.gz"

# AELDEV-71573: keepalive is REQUIRED on the master->worker SSH. The worker's
# "Install Docker" phase has a long SILENT window (up to 90s graceful drain of
# mongo/etcd/kafka/ES/redis, then dpkg installs). On a live, data-loaded source
# cluster the drain can run the full 90s+, during which the connection is idle.
# Without keepalive the idle master->worker SSH drops, the worker bringup (run
# foreground under that SSH) gets SIGHUP, and the worker dies right after
# "Sent SIGTERM to N stateful service(s)". Earlier wiped/fresh test clusters had
# nothing to drain so the window never got long enough to surface this.
# ServerAliveInterval=30 * ServerAliveCountMax=240 tolerates ~120 min of silence.
SCP_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=240 -o TCPKeepAlive=yes"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=240 -o TCPKeepAlive=yes"
WORKER_SSH_KEY=""  # deprecated: workers use sshpass (aella/aelladata)
STANDBY_IPS=""     # AELDEV-73583: --standby <ip[,ip]> -- orchestrated AFTER workers, role standby

# AELDEV-70673: expected major-version line for the Docker / containerd / runc
# packages bundled in aelladeb_py3_common.tar.gz. Used by the install
# skip-if-installed check and the final validation. Bump in lockstep with the
# regex pattern in build_image_2404_py3.sh + main_upgrade_py2_dp_to_py3_dp.sh
# + the three 24.04 OVA chroots when adopting a new major version.
EXPECTED_DOCKER_MAJOR="29"
EXPECTED_CONTAINERD_MAJOR="2"
EXPECTED_RUNC_MAJOR="1"

SCRIPT_NAME="$(basename "$0")"
SCRIPT_PATH="$(readlink -f "$0")"

###############################################################################
# LOGGING
###############################################################################
setup_logging() {
    mkdir -p /var/log/aella
    touch "$LOG_FILE"
    log ""
    log "========================================================================"
    log "  Py3 DP Bringup After OS Upgrade"
    log "  Started: $(date)"
    log "  Host: $(hostname)"
    log "  Kernel: $(uname -r)"
    log "  OS: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
    log "========================================================================"
}

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_phase() {
    log ""
    log "========================================"
    log "  PHASE: $*"
    log "========================================"
}

die() {
    log "FATAL: $*"
    exit 1
}

# Flush stale kube-proxy iptables rules left over from a prior cluster
# generation (AELDEV-71266, AELDEV-71216). kubeadm reset does NOT clean nat/
# mangle, so KUBE-NODEPORTS / KUBE-SERVICES / KUBE-SEP-* entries can survive
# and DNAT loopback traffic on port 2379 to dead pod IPs, crash-looping
# kube-apiserver after the next kubeadm init.
flush_stale_kube_iptables() {
    log "Flushing stale kube-proxy iptables rules..."
    local tbl chain
    for tbl in nat mangle filter; do
        iptables -t "$tbl" -F 2>/dev/null || true
    done
    for tbl in nat mangle filter; do
        for chain in $(iptables -t "$tbl" -nL 2>/dev/null | awk '/^Chain KUBE-/{print $2}'); do
            iptables -t "$tbl" -F "$chain" 2>/dev/null || true
            iptables -t "$tbl" -X "$chain" 2>/dev/null || true
        done
    done
    conntrack -F 2>/dev/null || true
}

###############################################################################
# VERSION GUARD: Only >= 6.5.0 supported for py3 DP
###############################################################################
version_ge() {
    # Returns 0 if $1 >= $2 (semantic version comparison)
    local v1="$1" v2="$2"
    if [[ "$v1" == "$v2" ]]; then return 0; fi
    local IFS='.'
    local i v1_parts=($v1) v2_parts=($v2)
    for ((i=0; i<3; i++)); do
        local a="${v1_parts[$i]:-0}"
        local b="${v2_parts[$i]:-0}"
        if (( a > b )); then return 0; fi
        if (( a < b )); then return 1; fi
    done
    return 0
}

check_version_guard() {
    # AELDEV-70186: Be explicit that this check is on the TARGET version (from
    # --version), not the currently installed DP version. Also surface what is
    # installed so it's obvious when a py2 DP is being migrated to py3.
    if ! version_ge "$VERSION" "6.5.0"; then
        die "Target version $VERSION is not supported by py3 bringup. Use bringup_py2_dp_after_os_upgrade.sh for < 6.5.0"
    fi
    log "Target version: $VERSION (>= 6.5.0 py3 minimum)"

    local inst_pkg="" inst_ver=""
    if dpkg -s aella-uvp-2404 &>/dev/null; then
        inst_pkg="aella-uvp-2404"
        inst_ver=$(dpkg -s aella-uvp-2404 2>/dev/null | grep '^Version:' | awk '{print $2}' | sed 's/ubuntu.*//' || true)
    elif dpkg -s aella-uvp &>/dev/null; then
        inst_pkg="aella-uvp"
        inst_ver=$(dpkg -s aella-uvp 2>/dev/null | grep '^Version:' | awk '{print $2}' | sed 's/ubuntu.*//' || true)
    fi
    if [[ -n "$inst_pkg" ]]; then
        log "Installed: ${inst_pkg} ${inst_ver}"
        if [[ "$inst_pkg" == "aella-uvp" ]]; then
            log "Detected py2 stack (${inst_ver}) -- will be purged before py3 UVP install"
        fi
    else
        log "Installed: no aella UVP package present (fresh DP)"
    fi
}

###############################################################################
# PRE-UPGRADE CLEANUP (run BEFORE do-release-upgrade)
###############################################################################
# Cleans up stale/dead apt repos and ensures proper Ubuntu repos are in place
# so that apt update, apt upgrade, and do-release-upgrade work cleanly.
#
# Run on the DP BEFORE starting the OS upgrade chain:
#   sudo bash bringup_py3_dp_after_os_upgrade.sh --pre-upgrade-cleanup
#
# Dead repos commonly found on 16.04/18.04 DPs:
#   1. dl.aelladata.com:8080 (10.38.1.46) -- internal build mirror, not reachable
#   2. deb.nodesource.com/node_8.x -- EOL, GPG key 1655A0AB68576280 expired
#   3. 129.146.74.109:32081/repository/dataprocessor -- internal Nexus repo
#   4. dl.stellarcyber.ai -- may be unreachable depending on network
#   5. kubernetes.io/apt repos -- may have expired GPG keys or wrong codename
#   6. docker.com repos -- may reference old release codenames
#   7. Old .list files in /etc/apt/sources.list.d/ with invalid entries
#
pre_upgrade_cleanup() {
    log_phase "Pre-Upgrade Cleanup (apt repos + DNS)"

    if [[ $EUID -ne 0 ]]; then die "Must run as root"; fi

    local removed=0
    local fixed=0

    # Detect current Ubuntu release
    local codename
    codename=$(lsb_release -cs 2>/dev/null || grep UBUNTU_CODENAME /etc/os-release 2>/dev/null | cut -d= -f2 || echo "unknown")
    local version_id
    version_id=$(grep VERSION_ID /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown")
    log "Current OS: Ubuntu $version_id ($codename)"

    # Backup sources.list before making changes
    cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null || true
    log "Backed up /etc/apt/sources.list"

    #---------------------------------------------------------------------------
    # Step 1: Remove dead/stale repo files from /etc/apt/sources.list.d/
    #---------------------------------------------------------------------------
    log ""
    log "--- Step 1: Remove stale repo files ---"

    # Remove nodesource node_8.x/node_10.x/node_12.x repos (EOL, expired GPG keys)
    for f in /etc/apt/sources.list.d/nodesource*.list; do
        if [[ -f "$f" ]]; then
            log "  Removing $f (nodesource EOL)"
            rm -f "$f"
            ((removed++)) || true
        fi
    done

    # Remove dl-stellarcyber.ai.list (may reference old codenames)
    if [[ -f /etc/apt/sources.list.d/dl-stellarcyber.ai.list ]]; then
        log "  Removing /etc/apt/sources.list.d/dl-stellarcyber.ai.list"
        rm -f /etc/apt/sources.list.d/dl-stellarcyber.ai.list
        ((removed++)) || true
    fi

    # Remove any .list / .sources files pointing to known dead repos.
    # AELDEV-70673: noble switched to deb822 .sources format, so cover both
    # patterns. A previously-upgraded DP can carry an inert dl-stellarcyber.ai
    # entry under /etc/apt/sources.list.d/*.sources that the .list-only scan
    # missed; apt ignores it for noble lookups (because its suite is xenial)
    # but the file is still dead config that confuses operators.
    for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        if grep -qE 'aelladata|nodesource|129\.146\.74\.109|dl\.stellarcyber' "$f" 2>/dev/null; then
            log "  Removing dead repo file: $f"
            rm -f "$f"
            ((removed++)) || true
        fi
    done

    # Remove kubernetes apt repo files (may have expired GPG keys or wrong codename)
    for f in /etc/apt/sources.list.d/kubernetes*.list; do
        if [[ -f "$f" ]]; then
            log "  Removing $f (K8s apt repo -- will install from debs)"
            rm -f "$f"
            ((removed++)) || true
        fi
    done

    # Remove docker apt repo files (may reference old codenames)
    for f in /etc/apt/sources.list.d/docker*.list; do
        if [[ -f "$f" ]]; then
            log "  Removing $f (Docker apt repo -- will install from debs)"
            rm -f "$f"
            ((removed++)) || true
        fi
    done

    # Remove any .list.distUpgrade files (leftovers from failed upgrades)
    for f in /etc/apt/sources.list.d/*.list.distUpgrade; do
        if [[ -f "$f" ]]; then
            log "  Removing leftover: $f"
            rm -f "$f"
            ((removed++)) || true
        fi
    done

    #---------------------------------------------------------------------------
    # Step 2: Clean stale entries from /etc/apt/sources.list
    #---------------------------------------------------------------------------
    log ""
    log "--- Step 2: Clean stale entries from sources.list ---"

    # Remove dl.aelladata.com entries
    if grep -q 'dl\.aelladata\.com' /etc/apt/sources.list 2>/dev/null; then
        log "  Removing dl.aelladata.com entries"
        sed -i '/dl\.aelladata\.com/d' /etc/apt/sources.list
        ((removed++)) || true
    fi

    # Remove internal Nexus repo entries (129.146.74.109)
    if grep -q '129\.146\.74\.109' /etc/apt/sources.list 2>/dev/null; then
        log "  Removing 129.146.74.109 (Nexus) entries"
        sed -i '/129\.146\.74\.109/d' /etc/apt/sources.list
        ((removed++)) || true
    fi

    # Remove dl.stellarcyber.ai entries
    if grep -q 'dl\.stellarcyber\.ai' /etc/apt/sources.list 2>/dev/null; then
        log "  Removing dl.stellarcyber.ai entries"
        sed -i '/dl\.stellarcyber\.ai/d' /etc/apt/sources.list
        ((removed++)) || true
    fi

    # Remove any lines with repos that no longer resolve
    if grep -q 'aelladata\.com' /etc/apt/sources.list 2>/dev/null; then
        log "  Removing remaining aelladata.com entries"
        sed -i '/aelladata\.com/d' /etc/apt/sources.list
        ((removed++)) || true
    fi

    # Comment out (don't delete) any lines referencing wrong codenames
    # e.g., xenial repos on a bionic system, or bionic repos on a focal system
    if [[ "$codename" != "unknown" ]]; then
        local old_codenames=""
        case "$codename" in
            bionic)  old_codenames="xenial|trusty|precise" ;;
            focal)   old_codenames="xenial|bionic|trusty" ;;
            jammy)   old_codenames="xenial|bionic|focal|trusty" ;;
            noble)   old_codenames="xenial|bionic|focal|jammy|trusty" ;;
        esac
        if [[ -n "$old_codenames" ]]; then
            local stale_count
            # AELDEV-70680: original `grep -c ... || echo 0` was buggy --
            # grep -c prints "0" AND exits 1 on no match, so `|| echo 0`
            # adds a SECOND "0" -> stale_count="0\n0" -> syntax error in
            # `[[ -gt 0 ]]`. The fix uses `grep -c ... || true` so the
            # 1-line "0" stdout from grep -c stands alone, and the
            # `${stale_count:-0}` is a defensive default for the empty-
            # stdout case (file missing, etc.). Cannot use
            # `var=$(grep | wc -l)` -- under pipefail the pipe inherits
            # grep's rc=1 and set -e exits the script on the assignment.
            stale_count=$(grep -cE "^\s*deb\s.*($old_codenames)" /etc/apt/sources.list 2>/dev/null) || true
            stale_count=${stale_count:-0}
            if [[ "$stale_count" -gt 0 ]]; then
                log "  Commenting out $stale_count lines with old codenames ($old_codenames)"
                sed -i -E "s|^(\s*deb\s.*($old_codenames).*)$|# DISABLED by pre-upgrade-cleanup: \1|" /etc/apt/sources.list
                ((fixed++)) || true
            fi
        fi
    fi

    # Remove empty lines and duplicate blank lines
    sed -i '/^$/N;/^\n$/d' /etc/apt/sources.list

    #---------------------------------------------------------------------------
    # Step 3: Ensure proper Ubuntu repos exist for current release
    #---------------------------------------------------------------------------
    log ""
    log "--- Step 3: Ensure Ubuntu repos for $codename ---"

    if [[ "$codename" != "unknown" ]]; then
        # Check if we have the basic Ubuntu repos (main, restricted, universe)
        local has_main=false has_security=false has_updates=false
        if grep -qE "^\s*deb\s.*archive\.ubuntu\.com.*\s${codename}\s.*main" /etc/apt/sources.list 2>/dev/null || \
           grep -qE "^\s*deb\s.*ubuntu\.com.*\s${codename}\s.*main" /etc/apt/sources.list 2>/dev/null; then
            has_main=true
        fi
        if grep -qE "^\s*deb\s.*security\.ubuntu\.com.*${codename}-security" /etc/apt/sources.list 2>/dev/null; then
            has_security=true
        fi
        if grep -qE "^\s*deb\s.*${codename}-updates" /etc/apt/sources.list 2>/dev/null; then
            has_updates=true
        fi

        if [[ "$has_main" != "true" ]]; then
            log "  Adding Ubuntu main/restricted/universe repos for $codename"
            echo "" >> /etc/apt/sources.list
            echo "# Added by pre-upgrade-cleanup ($(date +%Y-%m-%d))" >> /etc/apt/sources.list
            echo "deb http://archive.ubuntu.com/ubuntu ${codename} main restricted universe multiverse" >> /etc/apt/sources.list
            ((fixed++)) || true
        else
            log "  Ubuntu main repo: present"
        fi

        if [[ "$has_updates" != "true" ]]; then
            log "  Adding ${codename}-updates repo"
            echo "deb http://archive.ubuntu.com/ubuntu ${codename}-updates main restricted universe multiverse" >> /etc/apt/sources.list
            ((fixed++)) || true
        else
            log "  Ubuntu updates repo: present"
        fi

        if [[ "$has_security" != "true" ]]; then
            log "  Adding ${codename}-security repo"
            echo "deb http://security.ubuntu.com/ubuntu ${codename}-security main restricted universe multiverse" >> /etc/apt/sources.list
            ((fixed++)) || true
        else
            log "  Ubuntu security repo: present"
        fi
    fi

    #---------------------------------------------------------------------------
    # Step 4: Clean stale /etc/hosts entries
    #---------------------------------------------------------------------------
    log ""
    log "--- Step 4: Clean stale /etc/hosts entries ---"

    if grep -q 'dl\.aelladata\.com' /etc/hosts 2>/dev/null; then
        log "  Removing dl.aelladata.com from /etc/hosts (stale 10.38.1.46 mapping)"
        sed -i '/dl\.aelladata\.com/d' /etc/hosts
        ((removed++)) || true
    fi

    #---------------------------------------------------------------------------
    # Step 5: Clean up stale GPG keys
    #---------------------------------------------------------------------------
    log ""
    log "--- Step 5: Clean stale GPG keys ---"

    # Nodesource expired key
    if apt-key list 2>/dev/null | grep -q "1655A0AB68576280"; then
        apt-key del 1655A0AB68576280 2>/dev/null && log "  Removed nodesource GPG key" || true
        ((removed++)) || true
    fi

    # Google/Kubernetes expired key
    if apt-key list 2>/dev/null | grep -q "Google Cloud"; then
        local gcloud_keyid
        gcloud_keyid=$(apt-key list 2>/dev/null | grep -B1 "Google Cloud" | head -1 | awk '{print $NF}' || true)
        if [[ -n "$gcloud_keyid" ]]; then
            apt-key del "$gcloud_keyid" 2>/dev/null && log "  Removed Google Cloud GPG key" || true
        fi
    fi

    # Clean /etc/apt/trusted.gpg.d/ of stale keyrings
    for keyring in /etc/apt/trusted.gpg.d/nodesource*.gpg /etc/apt/trusted.gpg.d/kubernetes*.gpg; do
        if [[ -f "$keyring" ]]; then
            log "  Removing stale keyring: $keyring"
            rm -f "$keyring"
            ((removed++)) || true
        fi
    done

    # Also check /usr/share/keyrings/ for stale keyrings
    for keyring in /usr/share/keyrings/nodesource*.gpg /usr/share/keyrings/kubernetes*.gpg; do
        if [[ -f "$keyring" ]]; then
            log "  Removing stale keyring: $keyring"
            rm -f "$keyring"
            ((removed++)) || true
        fi
    done

    #---------------------------------------------------------------------------
    # Step 6: Fix DNS if broken (needed for apt to reach repos)
    #---------------------------------------------------------------------------
    log ""
    log "--- Step 6: Verify DNS ---"

    if ! getent hosts archive.ubuntu.com &>/dev/null; then
        log "  DNS broken -- cannot resolve archive.ubuntu.com"
        # Try restarting systemd-resolved
        if systemctl restart systemd-resolved 2>/dev/null; then
            if [[ -f /run/systemd/resolve/resolv.conf ]]; then
                rm -f /etc/resolv.conf
                ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
                log "  DNS: restarted systemd-resolved"
            fi
        fi
        # Still broken? Add static nameservers
        if ! getent hosts archive.ubuntu.com &>/dev/null; then
            log "  DNS still broken -- adding static nameservers"
            if [[ -L /etc/resolv.conf ]]; then rm -f /etc/resolv.conf; fi
            echo "nameserver 8.8.8.8" > /etc/resolv.conf
            echo "nameserver 8.8.4.4" >> /etc/resolv.conf
            ((fixed++)) || true
        fi
        if getent hosts archive.ubuntu.com &>/dev/null; then
            log "  DNS: working now"
        else
            log "  WARNING: DNS still not working -- apt update may fail"
        fi
    else
        log "  DNS: OK (archive.ubuntu.com resolves)"
    fi

    #---------------------------------------------------------------------------
    # Step 7: Clean apt cache and verify apt update works
    #---------------------------------------------------------------------------
    log ""
    log "--- Step 7: Verify apt update ---"

    # Clean stale apt cache
    apt-get clean 2>/dev/null || true
    rm -rf /var/lib/apt/lists/partial/* 2>/dev/null || true

    log "Running apt-get update..."
    local apt_log="/tmp/apt_update_check_$$.log"
    if apt-get update 2>&1 | tee "$apt_log" | tail -5; then
        local err_count warn_count
        err_count=$(grep -ciE '^E:|^Err|failed to fetch|hash sum mismatch' "$apt_log" 2>/dev/null) || err_count=0
        warn_count=$(grep -ciE '^W:|^WARNING' "$apt_log" 2>/dev/null) || warn_count=0

        if [[ "$err_count" -gt 0 ]]; then
            log ""
            log "WARNING: apt-get update has $err_count error(s):"
            grep -iE '^E:|^Err|failed to fetch|hash sum mismatch' "$apt_log" | head -10
            log ""
            log "Check full output: $apt_log"
            log "You may need to manually fix remaining repo issues before upgrading."
        elif [[ "$warn_count" -gt 0 ]]; then
            log "apt-get update completed with $warn_count warning(s) (usually OK)"
        else
            log "apt-get update succeeded cleanly"
        fi
    else
        log "WARNING: apt-get update failed -- check $apt_log"
    fi

    # Quick test: can we actually install packages?
    log ""
    log "Testing apt-get install (dry-run)..."
    if apt-get install -s --dry-run apt 2>&1 | grep -q "is already the newest"; then
        log "  apt install: OK (package resolution works)"
    else
        log "  WARNING: apt package resolution may have issues"
    fi

    #---------------------------------------------------------------------------
    # Summary
    #---------------------------------------------------------------------------
    log ""
    log "========================================"
    log "  Pre-upgrade cleanup complete"
    log "  Removed: $removed stale items"
    log "  Fixed:   $fixed items"
    log "  OS:      Ubuntu $version_id ($codename)"
    log "========================================"
    log ""
    log "Current /etc/apt/sources.list active entries:"
    grep -v '^#\|^$' /etc/apt/sources.list | head -15
    log ""
    log "Current /etc/apt/sources.list.d/:"
    ls /etc/apt/sources.list.d/*.list 2>/dev/null || log "  (empty)"
    log ""

    if [[ -f "$apt_log" ]] && grep -qiE '^E:|^Err|failed to fetch' "$apt_log" 2>/dev/null; then
        log "ACTION REQUIRED: Fix apt errors before running do-release-upgrade"
        log "  Review: $apt_log"
    else
        rm -f "$apt_log"
        log "Ready for OS upgrade. Next steps:"
        log "  1. sudo apt-get upgrade        # install pending security/bugfix updates"
        log "  2. sudo do-release-upgrade      # upgrade to next Ubuntu release"
    fi
}

###############################################################################
# PHASE 0: ARGUMENT PARSING & PRE-FLIGHT
###############################################################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)
                VERSION="$2"; shift 2 ;;
            --worker-ips)
                WORKER_IPS="$2"; shift 2 ;;
            --role)
                ROLE="$2"; shift 2 ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            --skip-download)
                SKIP_DOWNLOAD=true; shift ;;
            --worker-mode)
                WORKER_MODE=true; shift ;;
            --worker-key)
                WORKER_SSH_KEY="$2"; shift 2 ;;
            --pre-upgrade-cleanup)
                PRE_UPGRADE_CLEANUP=true; shift ;;
            --auto-os-upgrade)
                AUTO_OS_UPGRADE=true; shift ;;
            --reclaim-overlay2)
                RECLAIM_OVERLAY2_ONLY=true; shift ;;
            --relabel-elastic)
                RELABEL_ELASTIC_ONLY=true; shift ;;
            --standby)
                STANDBY_IPS="$2"; shift 2 ;;
            --help|-h)
                echo "Usage: $SCRIPT_NAME --version <dp-version> [options]"
                echo ""
                echo "Required:"
                echo "  --version <ver>         DP version (e.g., 6.5.0) -- must be >= 6.5.0"
                echo ""
                echo "Optional:"
                echo "  --worker-ips <ip,ip>    Comma-separated worker IPs (master orchestrates)"
                echo "  --standby <ip[,ip]>     Standby node IP(s) -- orchestrated like workers but with"
                echo "                          role standby, always AFTER the workers. May be used with"
                echo "                          or without --worker-ips."
                echo "  --role <role>           Override auto-detect (AIO|DR-master|DL-master|DR-worker|DL-worker|standby)"
                echo "  --dry-run               Pre-flight checks only"
                echo "  --skip-download         Use already-staged tarballs"
                echo "  --worker-mode           Internal: worker node mode"
                echo "  --relabel-elastic       Standalone: (re)apply elastic=enabled pre-labels on this"
                echo "                          DL-master/AIO, then print node labels and exit. Run on the"
                echo "                          master AFTER late-joining workers (by-hand section 4c flow)."
                echo "                          Only labels nodes with preserved ES data; skips standby and"
                echo "                          data-less nodes (e.g. ES coordinate candidates)."
                echo "  --pre-upgrade-cleanup   Clean stale apt repos, add correct Ubuntu repos, verify"
                echo "                          apt update/upgrade work. Run BEFORE do-release-upgrade."
                echo "  --auto-os-upgrade       Automated OS upgrade chain (16.04->24.04). Installs a"
                echo "                          systemd service that runs cleanup + do-release-upgrade"
                echo "                          on each boot until 24.04 is reached. Fully unattended."
                echo "                          Safe to re-run any time: auto-detects whether to resume"
                echo "                          (preserving hop_count + start_version) or initialize"
                echo "                          fresh (when state is missing or corrupted)."
                echo ""
                echo "Recovery (stuck mid-chain at 18.04 / 20.04 / 22.04):"
                echo "  1. SSH back in (sshd recovers within 90 min when systemd kills the stuck hop)."
                echo "  2. Check log: tail -50 /var/log/aella/auto_os_upgrade.log"
                echo "  3. Check state: cat /opt/aelladata/os-upgrade/state"
                echo "  4. Re-run: sudo bash $SCRIPT_NAME --auto-os-upgrade   # resumes or auto-resets"
                echo "  5. If state shows BLOCKED, wait for upstream services to recover, then re-run."
                exit 0 ;;
            *)
                die "Unknown option: $1" ;;
        esac
    done

    # --version not required for pre-upgrade cleanup, auto-os-upgrade, or the
    # standalone overlay2 reclaim / elastic relabel (version-independent ops).
    if [[ "$PRE_UPGRADE_CLEANUP" != "true" && "$AUTO_OS_UPGRADE" != "true" && "$RECLAIM_OVERLAY2_ONLY" != "true" && "$RELABEL_ELASTIC_ONLY" != "true" ]]; then
        if [[ -z "$VERSION" ]]; then die "--version is required"; fi
        # Version guard: only >= 6.5.0 for py3
        check_version_guard
    fi
    # If all artifacts are pre-staged locally, download is skipped automatically
}

detect_role() {
    if [[ -n "$ROLE" ]]; then
        log "Role override: $ROLE"
        return 0
    fi

    if [[ ! -f "$DA_CONF" ]]; then
        die "da_conf.yml not found at $DA_CONF. Use --role to specify."
    fi

    ROLE=$(grep 'aella_role' "$DA_CONF" 2>/dev/null | awk -F': ' '{print $2}' | tr -d "' \"" || true)
    if [[ -z "$ROLE" ]]; then
        die "Could not detect aella_role from $DA_CONF. Use --role to specify."
    fi

    log "Detected role: $ROLE"
}

# AELDEV-71573: resource pre-flight against wiki section 1 specs.
# Two-tier RAM check: soft WARN below customer spec (80G DA / 100G DLm),
# loud WARN below 62G hard floor. Never fails on RAM -- the bringup itself
# frees ~30-50G of pod memory via free_pod_memory_before_image_load before
# the 27GB image-load, so even below-spec boxes often complete. Warnings
# make the spec mismatch obvious in the log if anything goes sideways.
# Fails only on absolute floors where the script literally can't function.
preflight_resources() {
    local total_gb free_gb root_gb cores oom_n role_min
    total_gb=$(awk '/^MemTotal:/    {printf "%d", $2/1024/1024}' /proc/meminfo)
    free_gb=$(awk  '/^MemAvailable:/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    root_gb=$(df -BG / | awk 'NR==2 {gsub("G",""); print $4}')
    cores=$(nproc)
    oom_n=$(dmesg 2>/dev/null | grep -cE 'oom-killer|Out of memory|Killed process' || true)

    # Per-role total-RAM recommended (darksite customer + QA appliance specs).
    case "$ROLE" in
        AIO|DL-master)                       role_min=100 ;;
        DR-master|DA-master)                 role_min=80  ;;
        DR-worker|DA-worker|DL-worker)       role_min=80  ;;
        standby)                             role_min=80  ;;  # worker-tier gate; ACTIVATION capacity (>= its master's spec) is a sizing decision, not gated here
        *)                                   role_min=60  ;;
    esac

    log "Resources: cores=${cores} RAM total=${total_gb}G free=${free_gb}G  /=${root_gb}G  prior_OOM=${oom_n}"

    # Tier-2 FAIL: total RAM below 62G hard floor -- the 27GB image-load
    # phase will OOM-hang the VM (silent kernel freeze, requires hypervisor
    # reset). Pod-stop + page-cache drop alone can't recover this much.
    if (( total_gb < 62 )); then
        die "Insufficient RAM: ${total_gb}G total < 62G hard floor (wiki section 1 requires ${role_min}G for $ROLE)"
    fi
    # Tier-1 WARN: below role recommendation (e.g. QA 62G DA on 80G spec).
    # Bringup's pod-stop + cache-drop usually frees enough headroom to fit.
    if (( total_gb < role_min )); then
        log "  WARN: ${total_gb}G RAM is below ${role_min}G recommended for $ROLE (wiki section 1) -- proceeding"
        log "  WARN: bringup will free pod memory + drop page cache before image-load to fit"
    fi

    # WARN: tight free RAM at launch
    if (( free_gb < 25 )); then
        log "  WARN: only ${free_gb}G RAM available; image-load phase peaks ~35-45G"
    fi

    # WARN: cores below recommended (still proceed; bringup will be slow)
    if (( cores < 32 )); then
        log "  WARN: ${cores} cores (32+ recommended); bringup will be slow"
    fi

    # WARN: prior OOMs in dmesg suggest the VM has hit memory pressure before
    if (( oom_n > 0 )); then
        log "  WARN: dmesg shows ${oom_n} prior OOM event(s) -- VM may be undersized"
    fi

    # FAIL only on absolute floors (script can't run):
    if (( root_gb < 20 )); then
        die "Insufficient / disk: ${root_gb}G free < 20G needed for ctr import + dpkg temp"
    fi
    if (( cores < 8 )); then
        die "Insufficient CPU cores: ${cores} < 8 minimum (kubelet/containerd)"
    fi
}

# AELDEV-71573: bundle pre-flight for --skip-download (dark-site) mode.
# Validates wiki section 2 5-file bundle is present in STAGING_DIR (or its symlink
# target). Fail-fast with explicit missing-file list so QA/CS can copy the
# missing pieces from the bundle without waiting for late-phase failures.
# The follow-up auto-extract in download_artifacts() then unpacks the common
# tarball into its individual files; this gate just ensures the 5 inputs
# exist. PROVISION_STAGING_DIR is the alias (typically symlinked to
# /opt/aelladata/aelladeb_py3/) -- accept files in either location.
preflight_bundle() {
    local found_in=""
    if [[ -d "$STAGING_DIR" ]] && [[ -n "$(ls -A "$STAGING_DIR" 2>/dev/null)" ]]; then
        found_in="$STAGING_DIR"
    elif [[ -d "$PROVISION_STAGING_DIR" ]] && [[ -n "$(ls -A "$PROVISION_STAGING_DIR" 2>/dev/null)" ]]; then
        found_in="$PROVISION_STAGING_DIR"
    else
        die "Neither $STAGING_DIR nor $PROVISION_STAGING_DIR is populated. Stage wiki section 2 bundle first."
    fi

    # Wiki section 2 inputs (script itself is already running here so skip it).
    local bundle_files=(
        "aella-uvp-2404_${VERSION}ubuntu1_amd64.deb"
        "${ACPS_COMMON_TARBALL}"
        "images-${VERSION}.tar"
    )
    local missing=()
    for f in "${bundle_files[@]}"; do
        ls "$found_in"/$f &>/dev/null || missing+=("$f")
    done

    # images-<VERSION>.list is optional (only the .tar is strictly required
    # for ctr import, the .list is for operator visibility). Warn if missing.
    if ! ls "$found_in"/images-"${VERSION}".list &>/dev/null; then
        log "  WARN: images-${VERSION}.list missing (operator-visibility only, not fatal)"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERROR: dark-site bundle incomplete in $found_in"
        log "  Missing files:"
        for f in "${missing[@]}"; do log "    - $f"; done
        log "  Copy these from ACPS / customer bundle per wiki section 2 and re-run."
        log "  https://accaella.atlassian.net/wiki/spaces/SCQ/pages/4829478913/"
        die "Bundle incomplete"
    fi
    log "Bundle pre-flight: 3 required files present in $found_in"
}

# AELDEV-74638: is /etc/resolv.conf usable as-is? Usable = exists, has a
# nameserver line, and is not a LOOPBACK-ONLY file (systemd stub 127.0.0.53,
# dnsmasq/resolvconf 127.0.0.1, ::1) while systemd-resolved has no upstream
# servers. 16.04-upgraded boxes often leave resolved enabled but unconfigured
# (stub resolves nothing), and phase-7 masks dnsmasq (a 127.0.0.1 file then
# points at a dead forwarder); copying loopback lines into resolv-kube.conf
# would hand every pod an unreachable resolver.
resolv_conf_usable() {
    [[ -e /etc/resolv.conf ]] || return 1
    grep -q "^nameserver" /etc/resolv.conf 2>/dev/null || return 1
    if ! grep "^nameserver" /etc/resolv.conf 2>/dev/null | \
            grep -qvE "^nameserver[[:space:]]+(127\.|::1)"; then
        # loopback-only: usable only while resolved actually has upstreams
        grep -q "^nameserver" /run/systemd/resolve/resolv.conf 2>/dev/null || return 1
    fi
    return 0
}

# Remove exactly the public fallback nameservers this run appended (tracked
# in DNS_FALLBACK_LINES; pre-existing customer 8.8.8.8 lines are never added
# to the list and therefore never removed).
remove_dns_fallback() {
    local fb
    for fb in $DNS_FALLBACK_LINES; do
        sed -i "/^nameserver ${fb//./\\.}\$/d" /etc/resolv.conf 2>/dev/null || true
    done
    DNS_FALLBACK_LINES=""
}

# AELDEV-74638: rebuild /etc/resolv.conf from the DNS servers the box is
# configured with -- the systemd-resolved runtime file first (netplan boxes
# feed their nameservers into it), then ifupdown dns-nameservers lines
# (16.04-upgraded boxes); 8.8.8.8 only as a last resort. Callers must guard
# with resolv_conf_usable so a working customer DNS config is never clobbered.
rebuild_resolv_conf() {
    rm -f /etc/resolv.conf  # remove dangling symlink to systemd-resolved stub
    local configured_dns
    if grep -q "^nameserver" /run/systemd/resolve/resolv.conf 2>/dev/null; then
        # netplan boxes feed their configured DNS into systemd-resolved
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        log "DNS: linked to systemd-resolved"
    else
        # loopback entries (127.x/::1 -- e.g. a local dnsmasq that phase-7
        # masks) are skipped: they cannot serve as rebuilt upstreams
        configured_dns=$(grep -rhE "^[[:space:]]*dns-nameservers[[:space:]]" \
                /etc/network/interfaces /etc/network/interfaces.d/ 2>/dev/null | \
                sed 's/^[[:space:]]*dns-nameservers[[:space:]]*//' | tr ' ' '\n' | \
                grep -E '^[0-9A-Fa-f.:]+$' | grep -vE '^(127\.|::1$)' | \
                awk '!seen[$0]++' | head -3 || true)
        if [[ -n "$configured_dns" ]]; then
            : > /etc/resolv.conf
            local ns
            for ns in $configured_dns; do echo "nameserver $ns" >> /etc/resolv.conf; done
            log "DNS: restored configured nameservers (ifupdown)"
        elif systemctl restart systemd-resolved 2>/dev/null && \
                grep -q "^nameserver" /run/systemd/resolve/resolv.conf 2>/dev/null; then
            ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
            log "DNS: linked to systemd-resolved (after restart)"
        else
            # Last resort: static public DNS (online bringup still needs to
            # reach ACPS; on dark-site there was no configured DNS to keep)
            echo "nameserver 8.8.8.8" > /etc/resolv.conf
            echo "nameserver 8.8.4.4" >> /etc/resolv.conf
            log "DNS: static resolv.conf (8.8.8.8, 8.8.4.4) -- no configured DNS found"
        fi
    fi
    log "DNS: $(grep nameserver /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
}

preflight_checks() {
    log_phase "Pre-flight Checks"

    # Must be root
    if [[ $EUID -ne 0 ]]; then die "Must run as root"; fi

    # Fix DNS only if truly broken (missing / dangling symlink / no nameserver
    # lines). AELDEV-74638: the old logic treated "cannot resolve ${ACPS_HOST}"
    # as broken DNS and rewrote /etc/resolv.conf with 8.8.8.8/8.8.4.4 -- but on
    # a dark site ACPS is unreachable BY DESIGN, so it wiped the customer's
    # configured DNS (e.g. dns-nameservers 192.168.1.1 in
    # /etc/network/interfaces on a 16.04-upgraded ifupdown box). Never clobber
    # a resolv.conf that has nameservers; when rebuilding, restore the DNS the
    # box is configured with and use 8.8.8.8 only as a last resort.
    if resolv_conf_usable; then
        if ! getent hosts "${ACPS_HOST}" &>/dev/null; then
            if [[ "$SKIP_DOWNLOAD" == "true" ]]; then
                log "DNS: ${ACPS_HOST} does not resolve (expected on dark-site); keeping existing resolv.conf"
            elif [[ ! -L /etc/resolv.conf ]]; then
                # Online mode needs ACPS: keep the configured nameservers but
                # APPEND public fallbacks after them so downloads can proceed
                # (the old code REPLACED the file, wiping customer DNS). The
                # append is REVERTED if it does not help, and again if this
                # later turns out to be an auto-detected dark site -- the
                # customer file must never keep lines that did no good.
                # Symlinked (systemd-resolved-managed) files are left alone.
                log "WARN: ${ACPS_HOST} does not resolve with the configured DNS; trying public fallback nameservers"
                local fb
                for fb in 8.8.8.8 8.8.4.4; do
                    if ! grep -q "^nameserver ${fb//./\\.}\$" /etc/resolv.conf 2>/dev/null; then
                        echo "nameserver ${fb}" >> /etc/resolv.conf
                        DNS_FALLBACK_LINES="${DNS_FALLBACK_LINES} ${fb}"
                    fi
                done
                if getent hosts "${ACPS_HOST}" &>/dev/null; then
                    log "DNS: ${ACPS_HOST} resolves via appended fallback nameservers"
                else
                    remove_dns_fallback
                    log "WARN: fallback did not help -- restored original resolv.conf; downloads may fail (fix DNS or use --skip-download)"
                fi
            else
                log "WARN: ${ACPS_HOST} does not resolve (systemd-resolved-managed resolv.conf); downloads may fail"
            fi
        fi
    else
        log "DNS broken -- rebuilding /etc/resolv.conf"
        rebuild_resolv_conf
    fi

    # Must be Ubuntu 24.04
    local os_version
    os_version=$(grep VERSION_ID /etc/os-release | cut -d= -f2 | tr -d '"' || true)
    if [[ "$os_version" != "24.04" ]]; then die "Expected Ubuntu 24.04, got: $os_version"; fi
    log "OS: Ubuntu $os_version"

    # /opt/aelladata must exist
    if [[ ! -d /opt/aelladata ]]; then die "/opt/aelladata not found"; fi
    log "/opt/aelladata exists"

    # Remove system-installed K8s packages from Ubuntu 24.04 (if wrong version)
    # These conflict with K8s 1.31 from our offline debs
    local sys_kubeadm_ver
    sys_kubeadm_ver=$(dpkg -s kubeadm 2>/dev/null | grep '^Version:' | awk '{print $2}' || true)
    if [[ -n "$sys_kubeadm_ver" ]] && ! echo "$sys_kubeadm_ver" | grep -q "1\.31"; then
        log "Removing system K8s packages (v${sys_kubeadm_ver}) -- conflicts with K8s 1.31"
        # Backup CNI plugins before purge (kubernetes-cni package installs them)
        if [[ -d /opt/cni/bin ]]; then
            cp -a /opt/cni/bin /opt/cni/bin.bak 2>/dev/null || true
        fi
        apt-mark unhold kubeadm kubectl kubelet kubernetes-cni cri-tools 2>/dev/null || true
        dpkg --purge --force-depends kubeadm kubectl kubelet cri-tools 2>/dev/null || true
        # Only purge kubernetes-cni if we have a backup
        dpkg --purge --force-depends kubernetes-cni 2>/dev/null || true
        rm -f /usr/bin/kubeadm /usr/bin/kubectl /usr/bin/kubelet 2>/dev/null || true
        # Restore CNI plugins
        if [[ -d /opt/cni/bin.bak ]]; then
            mkdir -p /opt/cni/bin
            cp -a /opt/cni/bin.bak/* /opt/cni/bin/ 2>/dev/null || true
            rm -rf /opt/cni/bin.bak
            log "CNI plugins preserved in /opt/cni/bin/"
        fi
        log "System K8s packages removed"
    fi

    # Detect role
    detect_role

    # Validate role
    case "$ROLE" in
        AIO|DR-master|DL-master|DR-worker|DL-worker) ;;
        standby)
            # AELDEV-73583: warm-standby for a DL/DR master. Provisions like a
            # worker: same debs + full DL-worker image load (aellautil's
            # get_standby_worker_status reuses DL_WORKER_AELLA_IMAGE_LIST), same
            # kubeadm join to the PRIMARY's cluster (node_configure.join_cluster
            # explicitly allows role standby). Differences handled downstream:
            #   - join token fetched with standby=1 (master records the node via
            #     record_standby_node; node_bootstrap.sh parity),
            #   - config_worker.sh (called post-join) self-skips its cni0 wait
            #     for role standby (a standby runs no workload pods, so the cni0
            #     bridge may never appear -- the wait would hang),
            #   - pre_label_dl_elastic_nodes never labels standby nodes,
            #   - workload pods stay off via the standby label the master's
            #     standby_controller applies (service-yml anti-affinity).
            # Bring up AFTER the primary master is fully up, either orchestrated
            # from the master via --standby <ip> (recommended; NEVER via
            # --worker-ips, which forces DL/DR-worker) or per-node with
            # --role standby (section 4c style).
            if [[ "$WORKER_MODE" != "true" ]]; then
                log "Role standby: enabling worker-mode (join primary's cluster; no master init)"
                WORKER_MODE=true
            fi
            ;;
        *) die "Invalid role: $ROLE" ;;
    esac

    # Check ACPS connectivity
    if [[ "$SKIP_DOWNLOAD" != "true" ]]; then
        mkdir -p "$STAGING_DIR" "$AELLADEB_DIR" 2>/dev/null || true
        if check_local_artifacts; then
            log "All artifacts pre-staged locally -- download not required"
        else
            if ! command -v curl &>/dev/null; then
                die "curl not found. Install with: apt-get install -y curl"
            fi
            log "Testing ACPS connectivity..."
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" -k -u "${ACPS_USER}:${ACPS_PASS}" \
                --connect-timeout 30 --max-time 30 "https://${ACPS_HOST}/" || echo "000")
            if [[ "$http_code" != "200" ]] && [[ "$http_code" != "401" ]]; then
                log "WARNING: Cannot connect to ACPS (${ACPS_HOST}, HTTP ${http_code}) -- will use local artifacts only"
                SKIP_DOWNLOAD=true
                # AELDEV-74638: auto-detected dark site -- remove any public
                # fallback nameservers the DNS preflight appended
                if [[ -n "$DNS_FALLBACK_LINES" ]]; then
                    log "Dark-site auto-detected -- removing appended public fallback nameservers"
                    remove_dns_fallback
                fi
            elif [[ "$http_code" == "401" ]]; then
                die "ACPS authentication failed (HTTP 401). Check ACPS_USER/ACPS_PASS."
            else
                log "ACPS reachable (HTTP ${http_code})"
            fi
        fi
    fi

    # Disk space check. Default 10GB minimum for online bringup; raise to
    # 70GB minimum for --skip-download (dark-site) since the image tarball
    # alone is ~27GB and the containerd content store will hold another
    # ~27GB after import (AELDEV-70735). Need headroom for OS + pods +
    # working set.
    local free_gb min_gb
    free_gb=$(df -BG /opt/aelladata | tail -1 | awk '{print $4}' | tr -d 'G' || true)
    if [[ "$SKIP_DOWNLOAD" == "true" ]]; then
        min_gb=70
    else
        min_gb=10
    fi
    if [[ "$free_gb" -lt "$min_gb" ]]; then
        die "Insufficient disk space: ${free_gb}GB free, need ${min_gb}GB+ (--skip-download=$SKIP_DOWNLOAD)"
    fi
    log "Disk space: ${free_gb}GB free (need ${min_gb}GB+)"

    # AELDEV-71573: resource pre-flight (RAM total + free, /, cores, prior OOM).
    # Surfaces underprovisioned VMs BEFORE the 27GB image-load phase OOMs them
    # (silent VM hang -- requires hypervisor reset). Wiki section 1 minimums.
    preflight_resources

    # AELDEV-71573: bundle pre-flight (--skip-download only). Wiki section 2 staged
    # files must all be present BEFORE any phase runs. Caught a real darksite
    # bug where DAm bundle was missing pip3-site-packages.tar.gz +
    # py3-apt-packages.tar.gz (file gap from incomplete common-tarball extract)
    # -> Flask never installed -> aella_da_restful crashed -> port 8003 never
    # bound -> DA worker join hung indefinitely. Fail fast with the file list.
    if [[ "$SKIP_DOWNLOAD" == "true" ]]; then
        preflight_bundle
    fi

    # Print current state
    log "Current state:"
    log "  Python: $(command -v python3 >/dev/null 2>&1 && python3 --version 2>&1 || echo 'not found')"
    log "  Docker: $(command -v docker >/dev/null 2>&1 && docker --version 2>&1 || echo 'not found')"
    # AELDEV-71573: silence bash's "command not found" stderr noise that
    # leaks through "$(cmd 2>&1 || echo not found)" when cmd is absent --
    # bash's not-found message comes from the OUTER shell, not the missing
    # command's stderr, so 2>&1 doesn't catch it. Use command -v gate.
    log "  containerd: $(command -v containerd >/dev/null 2>&1 && containerd --version 2>&1 || echo 'not found')"
    log "  kubeadm: $(command -v kubeadm >/dev/null 2>&1 && kubeadm version 2>&1 || echo 'not found')"
    log "  Helm: $(command -v helm >/dev/null 2>&1 && helm version --short 2>&1 || echo 'not found')"
    log "  Version to install: $VERSION"
    log "  Worker mode: $WORKER_MODE"
    log "  Worker IPs: ${WORKER_IPS:-none}"
    log "  Standby IPs: ${STANDBY_IPS:-none}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "Dry run complete. All pre-flight checks passed."
        exit 0
    fi
}

###############################################################################
# PHASE 1: DOWNLOAD ARTIFACTS
###############################################################################
check_local_artifacts() {
    # Check if all required artifacts are already present locally
    # If user pre-staged files in /opt/aelladata/aelladeb/ and /opt/aelladata/aelladeb_py3/,
    # we can skip the entire download.
    # Py3 UVP is aella-uvp-2404 (not aella-uvp which is py2)
    local uvp_local="${AELLADEB_DIR}/aella-uvp-2404_${VERSION}ubuntu1_amd64.deb"
    local missing=0

    # UVP deb is required unless the FULL stack (meta + all sub-packages) is
    # already installed at target version. Otherwise install_uvp() will need
    # the deb on disk to repair any missing sub-package.
    # AELDEV-70189 (py2 parity): skipping the UVP check whenever ANY version
    # of aella-uvp-2404 is installed hides the fact that a minor upgrade or
    # partial install needs the deb on disk.
    local uvp_needs_deb=true
    if dpkg -s aella-uvp-2404 &>/dev/null; then
        local inst_ver
        inst_ver=$(dpkg -s aella-uvp-2404 2>/dev/null | grep '^Version:' | awk '{print $2}' | sed 's/ubuntu.*//' || true)
        if [[ "$inst_ver" == "$VERSION" ]]; then
            local full_stack=true
            for pkg in aella-da-services aella-da-cli aellacm kube-tools phonehome pypki; do
                if ! dpkg -s "$pkg" &>/dev/null; then full_stack=false; break; fi
            done
            [[ "$full_stack" == "true" ]] && uvp_needs_deb=false
        fi
    fi
    if [[ "$uvp_needs_deb" == "true" ]] && [[ ! -f "$uvp_local" ]]; then
        local any_uvp
        any_uvp=$(find -L "$AELLADEB_DIR" "$STAGING_DIR" -name "aella-uvp-2404_${VERSION}ubuntu1_amd64.deb" 2>/dev/null | head -1 || true)
        if [[ -z "$any_uvp" ]]; then ((missing++)) || true; fi
    fi

    # Docker/containerd debs required
    if [[ ! -f "${STAGING_DIR}/runc_"*".deb" ]] && ! ls "${STAGING_DIR}"/runc_*.deb &>/dev/null; then
        # Check if runc already installed
        if ! command -v runc &>/dev/null; then ((missing++)) || true; fi
    fi
    if [[ ! -f "${STAGING_DIR}/containerd_"*".deb" ]] && ! ls "${STAGING_DIR}"/containerd_*.deb &>/dev/null; then
        if ! dpkg -s containerd &>/dev/null; then ((missing++)) || true; fi
    fi
    if [[ ! -f "${STAGING_DIR}/docker.io_"*".deb" ]] && ! ls "${STAGING_DIR}"/docker.io_*.deb &>/dev/null; then
        if ! dpkg -s docker.io &>/dev/null; then ((missing++)) || true; fi
    fi

    # K8s debs required
    if ! command -v kubeadm &>/dev/null; then
        if ! ls "${STAGING_DIR}"/kubeadm_*.deb &>/dev/null; then ((missing++)) || true; fi
    fi

    # Helm tarball required if not installed
    if ! command -v helm &>/dev/null; then
        if ! ls "${STAGING_DIR}"/helm-v3.17.0-linux-amd64.tar.gz &>/dev/null; then ((missing++)) || true; fi
    fi

    return $missing
}

download_artifacts() {
    log_phase "Download Artifacts"

    if [[ "$SKIP_DOWNLOAD" == "true" ]]; then
        log "Skipping download (--skip-download)"
        # If STAGING_DIR is empty/missing but PROVISION_STAGING_DIR has files,
        # symlink so all phases can find debs in the expected location.
        if [[ ! -d "$STAGING_DIR" ]] || [[ -z "$(ls -A "$STAGING_DIR" 2>/dev/null)" ]]; then
            if [[ -d "$PROVISION_STAGING_DIR" ]] && [[ -n "$(ls -A "$PROVISION_STAGING_DIR" 2>/dev/null)" ]]; then
                log "Symlinking $STAGING_DIR -> $PROVISION_STAGING_DIR"
                rm -rf "$STAGING_DIR"
                ln -sf "$PROVISION_STAGING_DIR" "$STAGING_DIR"
            fi
        fi

        # AELDEV-70680 #13 + AELDEV-71573: dark-site UX. ACPS serves a single
        # aelladeb_py3_common.tar.gz (217MB consolidated tarball with all
        # K8s/Docker/runc/helm/pip3/py3-apt deps). The download path always
        # extracts it -- but the --skip-download path (used by dark-site
        # customers who copied only the tarball into PROVISION_STAGING_DIR)
        # never did, so subsequent phases failed looking for runc_*.deb /
        # pip3-site-packages.tar.gz / etc. as individual files.
        #
        # AELDEV-71573 fix: the earlier trigger checked ONLY runc_*.deb as
        # canary. If the staging dir was partially populated (e.g. K8s/docker
        # debs from a prior failed extract, but pip3-site-packages.tar.gz
        # missing), runc-only check passed -> extract skipped -> Flask never
        # installed -> aella_da_restful crashed -> 8003 never bound -> DA
        # worker join hung. Now check ALL canonical extracted files and
        # re-extract if any are missing. Idempotent: re-extracting over
        # existing files is a no-op for gzip-tar (same content + mtimes).
        local common_local="${STAGING_DIR}/${ACPS_COMMON_TARBALL}"
        local expected_extracted=(
            "runc_*_amd64.deb"
            "containerd_*_amd64.deb"
            "docker.io_*_amd64.deb"
            "kubernetes-cni_*_amd64.deb"
            "cri-tools_*_amd64.deb"
            "kubelet_*_amd64.deb"
            "kubectl_*_amd64.deb"
            "kubeadm_*_amd64.deb"
            "pip3-site-packages.tar.gz"
            "py3-apt-packages.tar.gz"
            "helm-*-linux-amd64.tar.gz"
        )
        local missing_extracted=()
        for pat in "${expected_extracted[@]}"; do
            ls "${STAGING_DIR}"/$pat &>/dev/null || missing_extracted+=("$pat")
        done
        if [[ -f "$common_local" ]] && [[ ${#missing_extracted[@]} -gt 0 ]]; then
            log "Common tarball present, ${#missing_extracted[@]} extracted file(s) missing -- extracting..."
            log "  Missing: ${missing_extracted[*]}"
            tar xzf "$common_local" -C "$(dirname "$STAGING_DIR")" || \
                die "Failed to extract ${common_local}"
            log "Extracted into ${STAGING_DIR}"
            # Re-verify; FAIL with explicit missing list if extract didn't recover them
            missing_extracted=()
            for pat in "${expected_extracted[@]}"; do
                ls "${STAGING_DIR}"/$pat &>/dev/null || missing_extracted+=("$pat")
            done
            if [[ ${#missing_extracted[@]} -gt 0 ]]; then
                log "ERROR: after extracting ${ACPS_COMMON_TARBALL}, still missing:"
                for f in "${missing_extracted[@]}"; do log "    $f"; done
                log "  Likely a corrupt or incomplete common tarball. Re-stage from ACPS."
                die "Bundle incomplete after extract"
            fi
        elif [[ ! -f "$common_local" ]] && [[ ${#missing_extracted[@]} -gt 0 ]]; then
            # No common tarball AND extracted files missing -> nothing we can
            # auto-recover. Tell operator exactly which files to stage.
            log "ERROR: ${ACPS_COMMON_TARBALL} not found in ${STAGING_DIR} AND extracted files missing:"
            for f in "${missing_extracted[@]}"; do log "    $f"; done
            log "  Stage ${ACPS_COMMON_TARBALL} (or the individual files) per wiki section 2"
            log "  then re-run bringup."
            die "Bundle missing (--skip-download)"
        fi
        return 0
    fi

    mkdir -p "$STAGING_DIR" "$AELLADEB_DIR"

    # Check if all required artifacts already exist locally (user pre-staged)
    if check_local_artifacts; then
        log "All required artifacts found locally -- skipping download"
        return 0
    fi

    log "Downloading from ACPS (${ACPS_HOST})"

    local curl_opts=(-fsS -k -u "${ACPS_USER}:${ACPS_PASS}" --connect-timeout 30 --max-time 1800)

    # Download 1: UVP deb (version-specific, per release)
    # Save to STAGING_DIR (aelladeb_py3/) -- not AELLADEB_DIR (aelladeb/) because
    # UVP postinst overwrites aelladeb/ contents with sub-packages.
    local uvp_deb="aella-uvp-2404_${VERSION}ubuntu1_amd64.deb"
    local uvp_local="${STAGING_DIR}/${uvp_deb}"

    if [[ -f "$uvp_local" ]]; then
        log "UVP deb already exists: $uvp_local"
    elif find -L "$AELLADEB_DIR" "$STAGING_DIR" -name "aella-uvp-2404_*_amd64.deb" 2>/dev/null | head -1 | grep -q .; then
        log "UVP deb found: $(find -L "$AELLADEB_DIR" "$STAGING_DIR" -name "aella-uvp-2404_*_amd64.deb" 2>/dev/null | head -1)"
    else
        log "Downloading UVP deb (${uvp_deb})..."
        curl "${curl_opts[@]}" -o "$uvp_local" \
            "${ACPS_PROVISION_URL}/${uvp_deb}" || \
            die "Failed to download UVP deb from ACPS: ${ACPS_PROVISION_URL}/${uvp_deb}"
        log "UVP deb downloaded: $(ls -lh "$uvp_local" | awk '{print $5}')"
    fi

    # Download 2: common tarball (all dependency files, version-independent)
    local common_local="${STAGING_DIR}/${ACPS_COMMON_TARBALL}"
    if [[ -f "$common_local" ]]; then
        log "Common tarball already exists: $common_local"
    else
        log "Downloading common tarball (${ACPS_COMMON_TARBALL})..."
        curl "${curl_opts[@]}" -o "$common_local" \
            "${ACPS_PROVISION_URL}/${ACPS_COMMON_TARBALL}" || \
            die "Failed to download common tarball from ACPS: ${ACPS_PROVISION_URL}/${ACPS_COMMON_TARBALL}"
        log "Common tarball downloaded: $(ls -lh "$common_local" | awk '{print $5}')"
    fi

    # Extract common tarball into STAGING_DIR
    # Tarball structure: top-level aelladeb_py3/ directory with all files inside
    log "Extracting common tarball into ${STAGING_DIR}..."
    tar xzf "$common_local" -C "$(dirname "$STAGING_DIR")" || \
        die "Failed to extract ${common_local}"

    # AELDEV-70673: validate by glob, not exact version. Tarball contents may
    # roll their backport revisions (e.g. docker.io ~24.04.1 -> ~24.04.2) or
    # patch versions (e.g. helm 3.17.0 -> 3.17.1) without breaking compat.
    # The dpkg -i call sites below already use find -name "<pkg>_*_amd64.deb"
    # so the validation just mirrors that.
    local required=(
        "runc_*_amd64.deb"
        "containerd_*_amd64.deb"
        "docker.io_*_amd64.deb"
        "kubernetes-cni_*_amd64.deb"
        "cri-tools_*_amd64.deb"
        "kubelet_*_amd64.deb"
        "kubectl_*_amd64.deb"
        "kubeadm_*_amd64.deb"
        "pip3-site-packages.tar.gz"
        "py3-apt-packages.tar.gz"
        "helm-*-linux-amd64.tar.gz"
    )
    for pat in "${required[@]}"; do
        local found
        found=$(find "${STAGING_DIR}" -maxdepth 1 -name "${pat}" 2>/dev/null | head -1)
        if [[ -z "$found" ]]; then
            die "Missing required file matching: ${STAGING_DIR}/${pat}"
        fi
    done

    # Verify UVP deb exists
    local any_uvp
    any_uvp=$(find -L "$AELLADEB_DIR" "$STAGING_DIR" -name "aella-uvp-2404_*_amd64.deb" 2>/dev/null | head -1 || true)
    if [[ -z "$any_uvp" ]]; then
        die "Missing aella-uvp-2404 deb in $AELLADEB_DIR or $STAGING_DIR"
    fi

    log "All artifacts downloaded and extracted successfully"
}

###############################################################################
# PHASE 2: INSTALL PYTHON 3
###############################################################################

# AELDEV-70189 / AELDEV-70457: pre-purge broken legacy py2 zombie packages
# left over from do-release-upgrade 16.04 -> 24.04. These are why pip3
# install fails downstream:
#
#   1. iU (installed-but-unconfigured) packages like libpython-stdlib,
#      python-cffi-backend, python-cryptography, python-enum34, python-idna,
#      python-ipaddress, python-ndg-httpsclient, python-openssl,
#      python-pkg-resources, python-pyasn1, python-six, python-urllib3 --
#      half-broken from the OS upgrade. They block `apt-get install -f`
#      because apt re-stages them from /var/cache/apt/archives/ and
#      /tmp/apt-dpkg-install-*/ then dpkg crashes on python_2.7.12-1~16.04.
#
#   2. python-elasticsearch (ii state, Stellar-installed legacy py2 client):
#      Depends: python-urllib3, python:any (>= 2.7.5-5~), python:any (<< 2.8).
#      Even after we purge the iU zombies, this one's healthy `Depends:`
#      forces apt to pull them right back from cache during fix-broken.
#      Removing it breaks the chain. python3-elasticsearch (already on disk
#      via pip3-site-packages.tar.gz) covers all py3 callers.
#
# Idempotent: if no iU zombies, skip. If python-elasticsearch absent, skip
# that part. Verified safe: nfs-common, nodejs, landscape-common, trace-cmd,
# python-minimal, python2.7, libpython2.7-* are NOT touched (stays in
# `ii`). The /usr/bin/python -> python2.7 flip (because python-minimal
# postinst is still there) is handled separately by ensure_python3_symlink
# at later boundaries.
purge_legacy_py2_zombies() {
    local ius
    ius=$(dpkg -l 2>/dev/null | awk '/^iU/ && $2 ~ /^(python-|libpython-)/ {print $2}')
    local trigger=""
    if dpkg -s python-elasticsearch &>/dev/null; then
        trigger="python-elasticsearch"
    fi
    if [[ -z "$ius" ]] && [[ -z "$trigger" ]]; then
        log "  no broken py2 zombies, nothing to purge"
        return 0
    fi
    log "  purging legacy py2 zombies: $(echo $ius $trigger | tr '\n' ' ')"
    apt-get remove --purge -y -qq $ius $trigger 2>&1 | tail -5 || \
        log "  WARNING: purge had errors (continuing)"
    local remaining
    remaining=$(dpkg -l 2>/dev/null | awk '/^iU/' | wc -l)
    log "  iU remaining: $remaining"
}

install_python3() {
    log_phase "Install Python 3"

    # Ubuntu 24.04 ships python3.12 -- no tarball needed
    if python3 --version &>/dev/null; then
        log "Python 3 already installed: $(python3 --version 2>&1)"
    else
        die "Python 3 not found on Ubuntu 24.04 -- system is broken"
    fi

    # AELDEV-70189: clear broken py2 zombie state BEFORE apt operations so
    # `apt-get install -f` and `apt install python3-pip` don't trip on
    # /var/cache/apt/archives/python_2.7.12-1~16.04_amd64.deb.
    purge_legacy_py2_zombies

    # Create python -> python3 symlink
    if [[ ! -L /usr/bin/python ]] || [[ "$(readlink /usr/bin/python)" != *"python3"* ]]; then
        ln -sf /usr/bin/python3 /usr/bin/python
        log "Symlink: /usr/bin/python -> python3"
    else
        log "Symlink /usr/bin/python already points to python3"
    fi

    # Install required Python 3 system apt packages from local tarball FIRST.
    # These are normally installed by the OVA build but missing after OS upgrade.
    # aellautil.py imports psutil, pymongo, kazoo, flask, tornado, etc.
    # All debs pre-staged in py3-apt-packages.tar.gz (no internet needed).
    # Must install these BEFORE pip3: python3-pip depends on python3-wheel which
    # comes from this tarball, and dpkg -i on these debs may leave unmet
    # dependencies that apt --fix-broken needs to resolve.
    local apt_tarball="${STAGING_DIR}/py3-apt-packages.tar.gz"
    if [[ -f "$apt_tarball" ]]; then
        log "Installing Python 3 system apt packages from local tarball..."
        local apt_tmpdir="/tmp/py3-apt-debs-$$"
        mkdir -p "$apt_tmpdir"
        tar -xzf "$apt_tarball" -C "$apt_tmpdir" || log "WARNING: Failed to extract py3-apt-packages.tar.gz"
        # AELDEV-71573: install all debs at once with --force-depends so
        # interdependent packages (python3-flask -> python3-werkzeug,
        # python3-pyinotify -> python3-pyasyncore, etc.) resolve in any
        # order. Previous per-deb loop with "skip if installed" left stale
        # packages and missed re-installs after apt fix-broken rolled them
        # back. Bulk dpkg -i is faster + idempotent (already-installed +
        # same-version is a no-op for dpkg).
        #
        # AELDEV-74638: the tarball now carries the FULL recursive dependency
        # closure (python3-click, colorama, openssl, zope.*, libev4t64,
        # pyasyncore, libjs-jquery, jinja2, blinker, markupsafe, pip, ...),
        # including shared libs the base may already have. dpkg -i would
        # silently DOWNGRADE any base package that is newer than the bundled
        # deb, so filter to debs that are absent or strictly newer than the
        # installed version before the bulk install.
        if ls "$apt_tmpdir"/*.deb &>/dev/null; then
            local deb pkg dver iver install_list=()
            for deb in "$apt_tmpdir"/*.deb; do
                pkg=$(dpkg-deb -f "$deb" Package 2>/dev/null)
                dver=$(dpkg-deb -f "$deb" Version 2>/dev/null)
                [[ -z "$pkg" || -z "$dver" ]] && continue
                iver=$(dpkg-query -W -f '${Version}' "$pkg" 2>/dev/null || true)
                if [[ -n "$iver" ]] && dpkg --compare-versions "$iver" gt "$dver"; then
                    continue    # installed is newer -- never downgrade
                fi
                install_list+=("$deb")
            done
            log "py3-apt-packages: installing ${#install_list[@]} of $(ls "$apt_tmpdir"/*.deb | wc -l) debs (rest already current)"
            if [[ ${#install_list[@]} -gt 0 ]]; then
                dpkg -i --force-depends "${install_list[@]}" 2>&1 | tail -10 || \
                    log "WARNING: some debs in py3-apt-packages.tar.gz failed (continuing)"
            fi
        fi
        rm -rf "$apt_tmpdir"
    else
        log "WARNING: py3-apt-packages.tar.gz not found in $STAGING_DIR"
        log "  Python 3 system packages (psutil, pymongo, flask, etc.) may be missing"
        log "  Place py3-apt-packages.tar.gz in $STAGING_DIR and re-run"
    fi

    # AELDEV-71573: dark-site (--skip-download) skips apt-based pip3 install.
    # `apt --fix-broken install` and `apt install python3-pip` were RE-INSTALLING
    # python3-flask via apt, but the missing deps that fix-broken couldn't
    # resolve (no internet, stale local cache) caused apt to ROLL BACK the
    # python3-flask install we just did via dpkg above. End result: flask gone,
    # aella_da_restful crash-loop, port 8003 never binds, DA worker can't join.
    # py3-apt-packages.tar.gz (debs above) + pip3-site-packages.tar.gz
    # (extracted in install_pip3_packages) together are self-sufficient on
    # dark-site -- no apt/internet ops needed. Online mode keeps the full
    # apt flow as before.
    if [[ "$SKIP_DOWNLOAD" == "true" ]]; then
        log "  --skip-download: skipping apt-based pip3 install (no internet)"
        log "  Python deps come from py3-apt-packages.tar.gz (already dpkg-installed)"
        log "  pip3-site-packages.tar.gz handled in next phase"
        if ! command -v pip3 &>/dev/null; then
            log "  NOTE: pip3 CLI binary not present (expected on dark-site);"
            log "  installed Python packages remain functional via direct imports."
        fi
    elif ! command -v pip3 &>/dev/null; then
        # Online mode: full apt flow (sequence matters):
        # 1. `apt-get update` to refresh cache (post-OS-upgrade cache can be stale,
        #    e.g. pinning to 404'd python3.12-dev versions)
        # 2. `apt --fix-broken install` to resolve unmet deps left by dpkg -i above
        #    (python3-gevent->python3-zope.event, python3-werkzeug->libjs-jquery, etc)
        # 3. Then `apt install python3-pip python3-wheel` can succeed.
        log "Installing pip3..."
        apt-get update -qq 2>&1 | tail -3 || log "WARNING: apt-get update had errors"
        apt-get install -f -y -qq 2>&1 | tail -3 || log "WARNING: apt --fix-broken install had errors"
        if apt-get install -y -qq python3-pip python3-wheel python3-setuptools 2>&1 | tail -3; then
            log "pip3 installed via apt"
        else
            log "WARNING: apt install python3-pip failed, trying get-pip.py fallback..."
            curl -sSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py 2>/dev/null || true
            python3 /tmp/get-pip.py 2>/dev/null || log "WARNING: get-pip.py failed"
            rm -f /tmp/get-pip.py
        fi
        log "pip3: $(pip3 --version 2>&1 || echo 'not found')"
    fi

    # Verify critical imports.
    # AELDEV-74638: aella_da_restful imports flask (which imports click); if
    # these cannot import, the master never binds :8003 and worker joins
    # stall silently. Do NOT abort here -- the rest of the master bringup is
    # independent of flask and completing it leaves the operator ONE small
    # manual fix + rerun (exactly how the field recovery worked). Instead:
    # name precisely what is missing + how to fix, and let the
    # pre-orchestration :8003 gate stop things before any worker can hang.
    MISSING_PY3_PKGS=""
    local mod
    for mod in psutil pymongo flask click; do
        python3 -c "import $mod" 2>/dev/null || MISSING_PY3_PKGS="$MISSING_PY3_PKGS python3-$mod"
    done
    if [[ -n "$MISSING_PY3_PKGS" ]]; then
        log "WARNING: critical python3 module(s) failed to import; missing apt packages:$MISSING_PY3_PKGS"
        log "  py3-apt-packages.tar.gz in the staged bundle is incomplete (AELDEV-74638;"
        log "  bundles published before 2026-08 lack python3-click and others)."
        log "  Bringup will continue, but aella_da_restful cannot start without flask,"
        log "  so :8003 will not bind and worker joins would hang. FIX (then rerun or"
        log "  let the pre-worker gate instructions guide you):"
        log "    online:    apt-get install -y$MISSING_PY3_PKGS"
        log "    dark-site: on any internet Ubuntu 24.04 host: apt-get download$MISSING_PY3_PKGS"
        log "               copy the .debs to this DP and run: dpkg -i <debs>"
    else
        log "Python 3 system packages installed (psutil pymongo flask click OK)"
    fi
}

install_pip3_packages() {
    log_phase "Install pip3 Packages"

    local site_packages_dir="/usr/local/lib/python3.12/dist-packages"

    # Prefer local site-packages tarball (no PyPI dependency)
    if [[ -f "${STAGING_DIR}/pip3-site-packages.tar.gz" ]]; then
        log "Installing pip3 packages from local tarball..."
        mkdir -p "$site_packages_dir"
        tar -xzf "${STAGING_DIR}/pip3-site-packages.tar.gz" -C "$site_packages_dir" || \
            log "WARNING: Failed to extract pip3-site-packages.tar.gz"
        log "pip3 site-packages extracted from local tarball"
    else
        log "pip3-site-packages.tar.gz not found -- packages must be installed separately if needed"
    fi

    # Validate critical imports
    python3 -c "import requests; import elasticsearch; import boto3; print('OK')" 2>/dev/null || \
        log "WARNING: Some critical python3 imports failed (may be installed by UVP later)"

    log "pip3 packages installation complete"
}

###############################################################################
# AELDEV-71573: aggressively free RAM before the 27GB image-load phase.
# Real-world DA boxes (QA + customer) are 64G total; steady-state K8s workload
# holds 40-50G. Image-load peak is ~35-45G (tar mmap + dual-namespace ctr
# import + dpkg). The targeted stateful-pattern drain alone leaves 15-25G of
# non-stateful aella pod memory in flight -- too tight on 64G boxes.
#
# This stops ALL K8s pod containers (not just stateful patterns), drops the
# page cache, and reports the gain. Idempotent: no-op if kubelet is already
# stopped and no containers are running.
###############################################################################
free_pod_memory_before_image_load() {
    local before_gb after_gb pods n

    # AELDEV-71725: defensive re-run gate. The intent of this function is
    # to free pod RAM BEFORE the 27 GB image-load. If K8s is already
    # healthy AND containerd's k8s.io content store is already populated
    # (i.e. load_local_images will also skip the re-import per its own
    # >50-image gate), then killing the running pods here is destructive
    # without benefit -- it would tear down a working cluster on a
    # re-bringup (e.g. master + --worker-ips invocation against an
    # already-bringup'd master to orchestrate a new worker).
    # The caller (install_docker_containerd) ALREADY skips this when
    # Docker is at the expected major, but this in-function gate protects
    # any future caller + matches the skip semantics of load_local_images.
    if systemctl is-active --quiet kubelet 2>/dev/null; then
        local k8s_img_count
        k8s_img_count=$(ctr -n=k8s.io images ls -q 2>/dev/null | wc -l)
        if [[ "$k8s_img_count" -gt 50 ]]; then
            log "Skipping free_pod_memory_before_image_load: kubelet healthy + ctr.k8s.io=$k8s_img_count images present (no re-import expected)"
            return 0
        fi
    fi

    before_gb=$(awk '/^MemAvailable:/ {printf "%d", $2/1024/1024}' /proc/meminfo)

    # Stop kubelet first so it does not restart pods we are about to kill.
    if systemctl is-active --quiet kubelet 2>/dev/null; then
        log "Stopping kubelet to prevent pod respawn..."
        systemctl stop kubelet 2>/dev/null || true
    fi

    # docker ps may not exist yet on fresh installs -- guard.
    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
        # All K8s-managed containers carry the io.kubernetes.pod.namespace label.
        pods=$(docker ps -q --filter "label=io.kubernetes.pod.namespace" 2>/dev/null || true)
        if [[ -n "$pods" ]]; then
            n=$(echo "$pods" | wc -l)
            log "Stopping $n K8s pod container(s) to free RAM before image-load..."
            # docker stop -t 20: SIGTERM then SIGKILL after 20s. Data-safe
            # because WAL/translog/AOF replay on next start.
            echo "$pods" | xargs -r docker stop -t 20 >/dev/null 2>&1 || true
            # Force-kill any still alive (docker stop returned but pid didn't exit)
            echo "$pods" | xargs -r docker kill >/dev/null 2>&1 || true
        fi
    fi

    # Drop page cache so killed-process memory is actually reclaimed (kernel
    # otherwise holds it as cache; usable but counts as "used" in cgroup view
    # and reduces headroom for the 27GB ctr import that follows).
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    after_gb=$(awk '/^MemAvailable:/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    log "RAM available: before=${before_gb}G after=${after_gb}G (freed $((after_gb - before_gb))G)"
}

# Write Docker daemon.json: systemd cgroup driver + containerd-snapshotter.
# Shared by install_docker_containerd and reclaim_legacy_docker_overlay2 so the
# snapshotter flag is always (re)asserted -- the aella-da-services .deb postinst
# ships its own daemon.json (a dpkg conffile) that drops this flag.
write_docker_daemon_json() {
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "features": {
    "containerd-snapshotter": true
  }
}
EOF
    log "Created /etc/docker/daemon.json (systemd cgroup driver + containerd-snapshotter)"
}

# AELDEV-71912: reclaim a stale legacy Docker overlay2 graphdriver store on 24.04.
# On the 16.04 -> 24.04 (--auto-os-upgrade) path an earlier run installs Docker 29
# while the legacy /var/lib/docker (image index) still exists, so Docker 29 comes
# up in the legacy "overlay2" graphdriver mode and re-populates ~230G that merely
# duplicates containerd's k8s.io store. The follow-up "--version" run hits
# install_docker_containerd's "already installed" early-return, so the in-install
# wipe never runs -- this reclaims it there. Idempotent: only fires while Docker
# reports the legacy overlay2 driver; once flipped to the containerd-snapshotter
# (reported as "overlayfs") it is a no-op, so re-runs never re-delete anything.
reclaim_legacy_docker_overlay2() {
    grep -q 'VERSION_ID="24.04"' /etc/os-release 2>/dev/null || return 0
    local sd
    sd=$(docker info 2>/dev/null | awk -F': ' '/Storage Driver/{print $2}' | tr -d ' ')
    [[ "$sd" == "overlay2" ]] || return 0
    # Never strand the DP: containerd's k8s.io namespace (what kubelet runs pods
    # from, and what is left untouched here) must already hold the image set
    # before we drop the parallel docker store.
    local k8s_imgs
    k8s_imgs=$(ctr -n k8s.io images ls -q 2>/dev/null | wc -l)
    if [[ "$k8s_imgs" -lt 50 ]]; then
        log "AELDEV-71912: docker in legacy overlay2 mode but containerd k8s.io has only $k8s_imgs images -- skipping reclaim to avoid stranding the DP"
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log "AELDEV-71912 DRY-RUN: WOULD reclaim /var/lib/docker (~$(du -sh /var/lib/docker 2>/dev/null|cut -f1)) and flip Docker overlay2 -> containerd-snapshotter (k8s.io has $k8s_imgs images; nothing changed)"
        return 0
    fi
    log "AELDEV-71912: Docker stuck in legacy overlay2 graphdriver mode; reclaiming /var/lib/docker (~$(du -sh /var/lib/docker 2>/dev/null|cut -f1); k8s.io has $k8s_imgs images, pods keep running off containerd)..."
    # Re-assert the snapshotter flag so the restart flips even if Docker 29's
    # default would not (daemon.json may have been clobbered by the .deb postinst).
    write_docker_daemon_json
    systemctl stop docker docker.socket 2>/dev/null || true
    # Only the docker graphdriver store -- never /var/lib/containerd (k8s.io).
    rm -rf /var/lib/docker/image /var/lib/docker/overlay2
    systemctl start docker.socket docker || die "Docker failed to start after overlay2 reclaim"
    local attempts=0
    while ! docker info &>/dev/null; do
        ((attempts++)) || true
        [[ $attempts -ge 30 ]] && die "Docker not ready 60s after overlay2 reclaim"
        sleep 2
    done
    local sd2
    sd2=$(docker info 2>/dev/null | awk -F': ' '/Storage Driver/{print $2}' | tr -d ' ')
    if [[ "$sd2" == "overlay2" ]]; then
        log "  WARNING: Docker still in overlay2 after reclaim (snapshotter flip failed) -- check daemon.json features.containerd-snapshotter"
    else
        log "  Docker flipped overlay2 -> ${sd2}; /var/lib/docker now $(du -sh /var/lib/docker 2>/dev/null|cut -f1). load_local_images (dark-site) / pull_image (online) repopulates the moby namespace."
    fi
}

# AELDEV-71912: overlay2 reclaim sweep across worker nodes. Two callers:
#   1. full bringup, AFTER wait_for_system_ready -- the whole cluster is up, so
#      every worker's containerd k8s.io is populated and pods run off it, exactly
#      when each worker's strand-guard can safely pass. (Workers do NOT
#      self-reclaim during their own bringup -- k8s.io may still be filling and
#      restarting docker mid-convergence is undesirable -- so cleanup is decoupled
#      into this separate post-convergence loop.)
#   2. standalone `--reclaim-overlay2 --worker-ips ...` -- a one-shot cluster
#      cleanup on an already-deployed cluster.
# Self-staging: scp this script to /tmp/<SCRIPT_NAME> on each worker first
# (idempotent -- full bringup also staged it via orchestrate_workers; standalone
# needs it placed), then SSH-invoke it there with --reclaim-overlay2. Workers run
# WITHOUT --worker-ips, so they only reclaim themselves (no recursion).
# Best-effort + non-fatal: an unreachable worker is logged and skipped.
reclaim_overlay2_on_workers() {
    [[ -z "$WORKER_IPS" ]] && return 0
    if ! command -v sshpass &>/dev/null; then
        log "AELDEV-71912: sshpass unavailable -- skipping worker overlay2 sweep"
        return 0
    fi
    local WORKER_USER="aella" WORKER_PASS="aelladata"
    local workers worker_ip dry_flag=""
    [[ "$DRY_RUN" == "true" ]] && dry_flag=" --dry-run"
    IFS=',' read -ra workers <<< "$WORKER_IPS"
    log "AELDEV-71912: overlay2 reclaim sweep across ${#workers[@]} worker(s)${dry_flag:+ (dry-run)}..."
    for worker_ip in "${workers[@]}"; do
        worker_ip=$(echo "$worker_ip" | xargs)
        [[ -z "$worker_ip" ]] && continue
        # Stage the script (-O = legacy scp protocol; 24.04 OpenSSH routes scp via SFTP).
        if ! sshpass -p "$WORKER_PASS" scp -O $SCP_OPTS "$SCRIPT_PATH" \
                "${WORKER_USER}@${worker_ip}:/tmp/${SCRIPT_NAME}" >/dev/null 2>&1; then
            log "  WARNING: could not stage script on $worker_ip -- skipping (non-fatal)"
            continue
        fi
        log "  [$worker_ip] reclaiming legacy docker overlay2 (if any)..."
        sshpass -p "$WORKER_PASS" ssh $SSH_OPTS "${WORKER_USER}@${worker_ip}" \
            "sudo bash /tmp/${SCRIPT_NAME} --reclaim-overlay2${dry_flag}" 2>&1 \
            | while IFS= read -r line; do log "    [$worker_ip] $line"; done \
            || log "  WARNING: overlay2 reclaim on $worker_ip failed (non-fatal; rerun: sudo bash /tmp/${SCRIPT_NAME} --reclaim-overlay2${dry_flag})"
    done
}

###############################################################################
# PHASE 3: INSTALL DOCKER + CONTAINERD
###############################################################################
install_docker_containerd() {
    log_phase "Install Docker ${EXPECTED_DOCKER_MAJOR}.x + containerd ${EXPECTED_CONTAINERD_MAJOR}.x"

    # AELDEV-70673: check against the EXPECTED_DOCKER_MAJOR constant so this
    # skip-if-installed gate stays in lockstep with whatever major the tarball
    # currently bundles. Previously hard-coded to "28\." which made the gate
    # fall through (forcing an unnecessary reinstall) after the bump to 29.x.
    if docker --version 2>/dev/null | grep -qE "version ${EXPECTED_DOCKER_MAJOR}[.]" && \
       containerd --version &>/dev/null && \
       systemctl is-active --quiet docker 2>/dev/null; then
        log "Docker ${EXPECTED_DOCKER_MAJOR}.x + containerd already installed and running"
        # AELDEV-71912: early/fast-path reclaim. Frees the ~100G legacy overlay2
        # store BEFORE the image-load phase when k8s.io is ALREADY populated --
        # i.e. the 24.04 py2->py3 path, where a running cluster already holds the
        # image set in containerd at this point. On the 16.04->24.04 path k8s.io
        # is still empty here (kube-deploy has not run), so the strand-guard skips
        # this call and the SECOND pass after wait_for_system_ready does the work.
        # No-op once Docker is already on the containerd-snapshotter driver.
        reclaim_legacy_docker_overlay2
    else
        # AELDEV-71573: stop ALL K8s pod containers + drop page cache. Frees
        # 30-50G on a populated DA box -- gives the 27GB image-load phase
        # enough headroom on 64G DA appliances. Runs BEFORE the targeted
        # stateful-pattern drain below (which now mostly catches orphans).
        free_pod_memory_before_image_load

        # AELDEV-70735: graceful shutdown of stateful processes BEFORE
        # replacing docker/containerd. Without this, `systemctl stop docker`
        # below kills all containers abruptly -- WiredTiger mid-write ->
        # mongo data corruption ("read checksum error for 4096B block ...
        # doesn't match expected checksum") -> aella-mongodb CrashLoopBackOff
        # on the new py3 stack -> stellar-css can't connect -> cm-master /
        # cm-bg / ui / metarepo blocked on Init. Subtle gotcha worth noting:
        # `systemctl stop kubelet` alone does NOT signal pod containers --
        # kubelet just exits, the containerd-managed containers keep running
        # until docker daemon shutdown. Docker's default --shutdown-timeout
        # is 10-15s which is often too short for a real customer's mongo
        # (multi-GB database -> checkpoint can take 30+ seconds). So we
        # send SIGTERM directly to the in-container processes (visible from
        # the host PID namespace) and wait for them to exit cleanly.
        # Stateful processes that NEED graceful shutdown to avoid WAL/
        # checkpoint corruption. Pattern matching is `pgrep -f` (full
        # command line) so we catch e.g. java-running-kafka.
        local stateful_patterns=(
            'mongod'                       # mongo: WiredTiger journal flush
            'etcd '                        # etcd: WAL fsync
            'kafka\.Kafka'                 # kafka: log segment close + checkpoint
            'java.*kafka'                  # alt kafka command line
            'java.*zookeeper'              # zookeeper: snapshot
            'java.*QuorumPeerMain'         # zookeeper alt
            '/usr/bin/java.*elasticsearch' # ES: translog flush + segment commit
            'redis-server'                 # redis: AOF/RDB flush
            'rabbitmq.*beam.smp'           # rabbitmq erlang VM
        )
        local any_alive=0
        for pat in "${stateful_patterns[@]}"; do
            pgrep -f "$pat" >/dev/null 2>&1 && any_alive=$((any_alive + 1))
        done

        if [[ $any_alive -gt 0 ]]; then
            # Stop kubelet first if running, so it doesn't restart pods
            # we're killing. Do this BEFORE SIGTERM-ing the workloads.
            # (Even if kubelet is already stopped -- e.g. from a previous
            # failed bringup with orphan mongo still running -- we still
            # need to graceful-stop those orphans.)
            if systemctl is-active --quiet kubelet 2>/dev/null; then
                log "Stopping kubelet to prevent pod restart during graceful drain..."
                systemctl stop kubelet 2>/dev/null || true
            fi

            local sent=0
            for pat in "${stateful_patterns[@]}"; do
                if pgrep -f "$pat" >/dev/null 2>&1; then
                    pkill -SIGTERM -f "$pat" 2>/dev/null && sent=$((sent + 1))
                fi
            done

            # AELDEV-71573: 30s SIGTERM grace then SIGKILL (was 90s).
            # WAL/translog/log-segment designs (mongo WiredTiger journal, etcd
            # WAL, ES translog, kafka log, redis AOF) replay on next start --
            # SIGKILL after 30s grace is data-safe (same as systemd's default
            # TimeoutStopSec). 90s left too long a silent window where the
            # bringup looked hung and operators Ctrl-C'd it.
            log "Sent SIGTERM to $sent stateful service(s); waiting up to 30s for graceful exit..."
            local wait_s=0
            while [[ $wait_s -lt 30 ]]; do
                local alive=0
                for pat in "${stateful_patterns[@]}"; do
                    pgrep -f "$pat" >/dev/null 2>&1 && alive=$((alive + 1))
                done
                [[ $alive -eq 0 ]] && break
                sleep 2
                wait_s=$((wait_s + 2))
            done
            # AELDEV-71573: count still-alive without tripping `set -euo pipefail`.
            # The old `still_alive=$(for...do pgrep...done | wc -l)` aborted the
            # script silently here -- last pattern (rabbitmq) rarely matches, so
            # the for-loop returned 1, pipefail propagated, the assignment's
            # non-zero status triggered set -e exit RIGHT AFTER "Sent SIGTERM".
            # No log line, looked like a disconnect. Latent since AELDEV-70735.
            local still_alive=0
            for pat in "${stateful_patterns[@]}"; do
                local n
                n=$(pgrep -cf "$pat" 2>/dev/null || true)
                still_alive=$((still_alive + n))
            done
            if [[ $still_alive -gt 0 ]]; then
                # SIGKILL fallback: holdouts (typically kafka JVM, ZK) ignored
                # SIGTERM or have slow shutdown hooks. Their WAL/log-segment
                # design tolerates abrupt termination -- mongo WiredTiger journal,
                # etcd WAL fsync, ES translog, kafka log replay, redis AOF -- so
                # SIGKILL after a 90s SIGTERM grace is data-safe (same semantics
                # systemd uses with TimeoutStopSec then KillMode=control-group).
                log "  $still_alive process(es) still alive after ${wait_s}s -- sending SIGKILL"
                for pat in "${stateful_patterns[@]}"; do
                    pkill -SIGKILL -f "$pat" 2>/dev/null || true
                done
                sleep 3
                still_alive=0
                for pat in "${stateful_patterns[@]}"; do
                    local n
                    n=$(pgrep -cf "$pat" 2>/dev/null || true)
                    still_alive=$((still_alive + n))
                done
                if [[ $still_alive -gt 0 ]]; then
                    log "  WARNING: $still_alive process(es) survived SIGKILL -- proceeding anyway"
                else
                    log "  all stateful services killed after ${wait_s}s SIGTERM grace + SIGKILL"
                fi
            else
                log "  all stateful services exited cleanly after ${wait_s}s"
            fi
        fi

        # Stop existing Docker/containerd (if present, may be wrong version)
        systemctl stop docker 2>/dev/null || true
        systemctl stop docker.socket 2>/dev/null || true
        systemctl stop containerd 2>/dev/null || true

        # AELDEV-71573: clear stale dpkg pending state from 16.04 docker.io/runc
        # left over after do-release-upgrade. Without this, when we dpkg -i the
        # new 29.x debs, dpkg also tries to "configure" the leftover 18.06.1
        # 16.04-arch debs in /var/cache/apt/archives -> emits noisy
        # "dpkg: error processing package docker.io (--install): dependency
        # problems - leaving unconfigured" + "containerd 2.2.1 breaks docker.io
        # (<< 19.03.13)". The new install succeeds but the log churns errors
        # that confuse operators. Force-purge the in-place package first;
        # --force-depends keeps the kernel modules + cgroups intact.
        for pkg in docker.io containerd runc; do
            if dpkg -l "$pkg" 2>/dev/null | grep -qE "^[ihrp][nUMRT]"; then
                dpkg --purge --force-depends "$pkg" 2>&1 | tail -3 || true
            fi
        done

        # AELDEV-71912: wipe legacy Docker 18.06 graphdriver content. On 6.2.0
        # OVA boxes /var/lib/docker/{overlay2,image} holds ~65 GB of 16.04-era
        # image layers + index. Docker 29 detects this dir on first start and
        # KEEPS using legacy overlay2 graphdriver for compat (instead of the
        # 29.x default = containerd-snapshotter). That keeps two image stores
        # in parallel (legacy /var/lib/docker AND containerd /var/lib/containerd)
        # and the daemon.json `features.containerd-snapshotter:true` flag we
        # write below gets clobbered by aella-da-services .deb postinst anyway.
        # Wiping the legacy dir NOW means Docker 29 starts fresh, picks the
        # snapshotter default, shares containerd's content store with kubelet
        # via the moby namespace -> single image store -> reclaims ~65 GB per
        # upgraded DP. No-op on fresh 6.5.0 OVA installs (dir doesn't exist).
        # Validated 2026-06-05 on QA dark-site 4-node cluster: 0 pod state
        # change, ~65 GB reclaimed per node, Docker auto-flips to overlayfs
        # + systemd cgroup driver.
        if [[ -d /var/lib/docker/overlay2 || -d /var/lib/docker/image ]]; then
            local legacy_gb
            legacy_gb=$(du -s /var/lib/docker 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}')
            log "Wiping legacy /var/lib/docker (~${legacy_gb}G stranded from 6.2.0 OVA Docker 18.06)..."
            rm -rf /var/lib/docker/image /var/lib/docker/overlay2
        fi

        # Install in dependency order: runc first, then containerd, then docker.io
        # This is critical -- dpkg -i in wrong order fails on unmet deps

        # Step 1: Install runc
        local runc_deb
        runc_deb=$(find -L "$STAGING_DIR" -name "runc_*_amd64.deb" 2>/dev/null | head -1 || true)
        if [[ -n "$runc_deb" ]]; then
            log "Installing runc..."
            dpkg -i --force-depends "$runc_deb" 2>&1 || true
            log "runc installed: $(runc --version 2>&1 | head -1 || echo 'unknown')"
        else
            log "WARNING: runc deb not found in $STAGING_DIR"
        fi

        # Step 2: Install containerd
        # --auto-deconfigure handles docker.io 28.x dependency conflict when upgrading
        # from a system where docker.io 28.x was installed before containerd (e.g.,
        # accidental py2 UVP install on py3 DP installs docker 28.x which Depends: containerd)
        local containerd_deb
        containerd_deb=$(find -L "$STAGING_DIR" -name "containerd_*_amd64.deb" 2>/dev/null | head -1 || true)
        if [[ -n "$containerd_deb" ]]; then
            log "Installing containerd..."
            dpkg -i --auto-deconfigure --force-depends --force-overwrite "$containerd_deb" 2>&1 || true
            log "containerd installed: $(containerd --version 2>&1 || echo 'unknown')"
        else
            log "WARNING: containerd deb not found in $STAGING_DIR"
        fi

        # Step 3: Install docker.io
        local docker_deb
        docker_deb=$(find -L "$STAGING_DIR" -name "docker.io_*_amd64.deb" 2>/dev/null | head -1 || true)
        if [[ -n "$docker_deb" ]]; then
            log "Installing docker.io..."
            dpkg -i --force-depends "$docker_deb" 2>&1 || true
            log "Docker installed: $(docker --version 2>&1 || echo 'unknown')"
        else
            log "WARNING: docker.io deb not found in $STAGING_DIR"
        fi

        # Verify binaries exist
        command -v docker &>/dev/null || die "docker binary not found after installation"
        command -v containerd &>/dev/null || die "containerd binary not found after installation"
        command -v runc &>/dev/null || die "runc binary not found after installation"
    fi

    # Configure containerd with SystemdCgroup = true
    log "Configuring containerd..."
    mkdir -p /etc/containerd
    # AELDEV-70673: regen gate. The expected containerd major is
    # EXPECTED_CONTAINERD_MAJOR (currently 2). containerd 2.x reads config
    # version 3; containerd 1.7.x only reads version 2. If the runtime is 1.x
    # but config.toml is v3 (which happens when an OS-upgrade-time apt install
    # pulled docker.io 29.x + containerd 2.x, then this script downgrades the
    # runtime), the service refuses to start ("config version `3` is not
    # supported, the max version is `2`"). Gate forces regen in that mismatch
    # case only. For 2.x runtime with v3 config the regen is unnecessary, so
    # we skip the version-3 trigger when the major is >= 2.
    local need_regen=0
    [[ ! -f /etc/containerd/config.toml ]] && need_regen=1
    if [[ "$EXPECTED_CONTAINERD_MAJOR" -lt 2 ]]; then
        grep -q '^version = 3' /etc/containerd/config.toml 2>/dev/null && need_regen=1
    fi
    grep -q 'SystemdCgroup = true' /etc/containerd/config.toml 2>/dev/null || need_regen=1
    if [[ "$need_regen" -eq 1 ]]; then
        # Backup any prior config (helps debug if regen produces an empty file).
        [[ -f /etc/containerd/config.toml ]] && \
            cp -p /etc/containerd/config.toml /etc/containerd/config.toml.bak.aellabringup
        containerd config default > /etc/containerd/config.toml 2>/dev/null || true
        # Set SystemdCgroup = true under runc options
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml 2>/dev/null || true
        # Verify the setting was applied; if not, append it.
        # AELDEV-70673: containerd 2.x renamed the runc-options plugin path
        # from `io.containerd.grpc.v1.cri` (v2 config) to
        # `io.containerd.cri.v1.runtime` (v3 config), and the v3 default uses
        # single quotes instead of double. Match either form so the manual
        # insertion still works whether the runtime is 1.7.x or 2.x. (Primary
        # sed above already covers both default configs in practice; this is
        # a defensive fallback for a non-default config layout.)
        if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml 2>/dev/null; then
            if grep -qE '^\s*\[plugins\.[^]]*containerd\.runtimes\.runc\.options\]' /etc/containerd/config.toml 2>/dev/null; then
                sed -i -E '/^\s*\[plugins\.[^]]*containerd\.runtimes\.runc\.options\]/a\            SystemdCgroup = true' /etc/containerd/config.toml
            fi
        fi
        log "containerd config: SystemdCgroup = true (regenerated from running binary)"
    else
        log "containerd config already has SystemdCgroup = true (version v2)"
    fi

    # AELDEV-70735: align containerd's sandbox/pause image with what kubeadm
    # pre-pulls. `containerd config default` hardcodes pause:3.8 in both v2
    # (sandbox_image) and v3 (pinned_images.sandbox) schemas, but kubeadm
    # v1.31 pre-pulls pause:3.10 and our tarball ships pause:3.10. On a
    # dark-site DP the mismatch makes containerd try to pull pause:3.8 from
    # registry.k8s.io for every pod-sandbox create -- the firewall blocks
    # it, no sandbox starts, kubeadm init waits for control plane and bails.
    # Sed handles both schemas; restart picks up the new value.
    if grep -q 'registry\.k8s\.io/pause:3\.8' /etc/containerd/config.toml 2>/dev/null; then
        sed -i -E 's|registry\.k8s\.io/pause:3\.8|registry.k8s.io/pause:3.10|g' /etc/containerd/config.toml
        log "containerd config: pause image 3.8 -> 3.10 (matches kubeadm 1.31 + local tarball)"
    fi

    # Ensure LimitNOFILE=infinity for containerd (containerd 2.x dropped it from service file)
    mkdir -p /etc/systemd/system/containerd.service.d
    cat > /etc/systemd/system/containerd.service.d/override.conf << 'EOFCRD'
[Service]
LimitNOFILE=infinity
EOFCRD
    systemctl daemon-reload 2>/dev/null || true
    log "containerd LimitNOFILE=infinity drop-in installed"

    # Write Docker daemon.json (systemd cgroup driver for Docker 29.x)
    # AELDEV-70735: enable containerd-snapshotter so Docker shares
    # containerd's unified content store instead of using the legacy
    # /var/lib/docker graphdriver. That means `ctr -n=moby import` and
    # `docker pull` see the SAME images -- which is what load_local_images
    # depends on for aellad's `docker pull` to find 6.5.0 images under
    # dark-site (no registry egress).
    #
    # Docker 29.x prints a misleading warning that "containerd-snapshotter
    # is now the default" if you set it explicitly, but in practice (verified
    # on docker.io 29.1.3-0ubuntu3~24.04.2) the default is STILL the legacy
    # graphdriver -- the setting is required to actually flip the mode.
    #
    # IMPORTANT: do NOT also set `storage-driver: overlay2` -- in snapshotter
    # mode Docker re-interprets that as a containerd-snapshotter NAME, and
    # "overlay2" is not a valid containerd snapshotter (containerd uses
    # "overlayfs"). With both keys set, dockerd refuses to start with
    # "configured driver overlay2 not available: unavailable".
    write_docker_daemon_json

    # Docker Hub credentials
    mkdir -p /root/.docker /home/aella/.docker 2>/dev/null || true
    cat > /root/.docker/config.json <<'DOCKERAUTH'
{
    "auths": {
        "https://index.docker.io/v1/": {
            "auth": "YWVsbGFkYXRhZG9ja2Vyczo0dHB5ZndrcTNk"
        }
    }
}
DOCKERAUTH
    chmod 600 /root/.docker/config.json
    if id aella &>/dev/null; then
        cp /root/.docker/config.json /home/aella/.docker/config.json
        chown -R aella: /home/aella/.docker
        chmod 600 /home/aella/.docker/config.json
    fi

    # NO cgroup v1 mount needed -- containerd uses cgroup v2 natively on 24.04
    # NO apparmor disable -- Docker 29.x works with apparmor

    # Ensure docker group exists (needed by docker.socket)
    groupadd docker 2>/dev/null || true

    # Enable and start containerd first, then Docker
    systemctl daemon-reload
    systemctl enable containerd 2>/dev/null || true
    systemctl restart containerd || die "Failed to start containerd"

    systemctl reset-failed docker 2>/dev/null || true
    systemctl enable docker docker.socket 2>/dev/null || true
    systemctl start docker || {
        # Retry once after resetting failure counter
        sleep 3
        systemctl reset-failed docker 2>/dev/null || true
        systemctl start docker || die "Failed to start Docker"
    }

    # Wait for Docker to be ready
    local attempts=0
    while ! docker info &>/dev/null; do
        ((attempts++)) || true
        if [[ $attempts -ge 30 ]]; then die "Docker not ready after 60 seconds"; fi
        sleep 2
    done

    log "Docker running: $(docker info 2>/dev/null | grep 'Server Version' | xargs)"

    # Verify crictl works with containerd
    if command -v crictl &>/dev/null; then
        # Configure crictl to use containerd
        cat > /etc/crictl.yaml <<'CRICTL'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
CRICTL
        crictl info &>/dev/null && log "crictl: OK (containerd backend)" || \
            log "WARNING: crictl info failed"
    else
        log "crictl not yet installed (will be installed with K8s)"
    fi
}

###############################################################################
# PHASE 3.5: LOAD LOCAL IMAGE TARBALLS (--skip-download / dark-site only)
###############################################################################
# AELDEV-70735: dark-site customers stage a single images-<VER>.tar tarball
# (produced via `ctr -n=k8s.io images export` from a healthy AIO) in
# $STAGING_DIR. We import it into BOTH containerd namespaces so:
#   - k8s.io: kubelet/CRI sees images; the K8s + flannel pulls in
#     init_k8s_master short-circuit via crictl-images cache check.
#   - moby:   docker daemon sees images via the shared content store, so
#     aellad's `docker pull` in start_aella_services becomes a cache hit.
# Single tarball, two imports -- safe on containerd 2.x. Gated on
# --skip-download so online bringup keeps using registries.
# AELDEV-70735: scan release-image.yml against local containerd/docker
# image cache and report missing refs. release-image.yml uses a YAML map of
# `<name>: <version>`; the actual image ref is conventionally
# `aelladata/<name>:<version>` OR (for entries like `aella-etcd: v3.2`)
# `aelladata/<short-name>:<version>` where short-name = name without the
# `aella-` prefix. Fuzzy substring match handles both forms.
#
# Strictly informational: this is called only in --skip-download mode to
# surface what's cached vs missing so customer/CS know if the bundle is
# complete. Does NOT block bringup -- a missing image just becomes an
# ImagePullBackOff later, which the operator can resolve via tag-alias
# (see wiki section 11.1 UVP-vs-image-bundle drift).
darksite_check_local_images() {
    local rel="$1"
    [[ -f "$rel" ]] || return 0

    local cached
    cached=$(
        ctr -n=k8s.io images ls 2>/dev/null | awk 'NR>1 {print $1}'
        ctr -n=moby   images ls 2>/dev/null | awk 'NR>1 {print $1}'
        docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null
    )
    local total=0 missing=0
    local -a missing_list=()
    local name ver short
    while IFS=':' read -r name ver; do
        name="${name//[[:space:]]/}"
        ver="${ver//[[:space:]]/}"
        [[ -z "$name" || -z "$ver" || "$name" == "images" || "$name" == "#"* ]] && continue
        short="${name#aella-}"
        total=$((total + 1))
        # Version-anywhere match: cached ref ends with `:<version>` on the
        # same line. Drops the name-substring requirement entirely to
        # avoid name-drift false positives like `aella-mongo-backup`
        # (yaml) vs `mongodb-backup` (cache). Build-hash versions like
        # `6.5.0.7878-5ae4f4876` are unique enough that version-only
        # matching is reliable; bare semver versions like `4.4.11` may
        # rarely collide across different images but that's acceptable
        # since this check is informational (see "fuzzy" note below).
        if ! grep -qE ":${ver}([[:space:]]|$)" <<<"$cached"; then
            missing_list+=("aelladata/${name}:${ver} (or aelladata/${short}:${ver})")
            missing=$((missing + 1))
        fi
    done < <(awk '/^[[:space:]]+[a-zA-Z0-9_-]+:[[:space:]]*[^[:space:]]+[[:space:]]*$/ {gsub(/^[[:space:]]+/, ""); print}' "$rel")

    log "  release-image.yml: ${total} refs total, ${missing} not detected in cache"
    if [[ "$missing" -gt 0 && "$missing" -lt 20 ]]; then
        log "  Missing (or differently-named) refs:"
        for img in "${missing_list[@]}"; do
            log "    - $img"
        done
        log "  Note: fuzzy substring match -- some 'missing' refs may exist under different paths."
        log "  Verify via:  sudo ctr -n=k8s.io images ls | grep <name>"
    elif [[ "$missing" -ge 20 ]]; then
        log "  Large number missing (${missing}) -- likely image bundle isn't fully loaded yet."
        log "  Check load_local_images output earlier in this log."
    fi
}

load_local_images() {
    [[ "$SKIP_DOWNLOAD" != "true" ]] && return 0
    log_phase "Load Local Image Tarballs (dark-site)"

    # AELDEV-70735: tag-alias bare-name refs (no domain prefix) to docker.io/*
    # equivalents in both namespaces. kubelet/containerd normalize unprefixed
    # image refs to docker.io/<ref> when resolving image-pull lookups; without
    # this alias pass, a pod referencing `docker.io/aelladata/foo` won't see
    # the bare `aelladata/foo` already in containerd and will hit the
    # registry network (= darksite blocked). The fixup is idempotent and
    # cheap (a few hundred metadata records, no blob movement), so it's safe
    # to run on every load_local_images call.
    alias_docker_io_refs() {
        local ns="$1" ref first_seg new_ref count=0
        while IFS= read -r ref; do
            [[ -z "$ref" ]] && continue
            first_seg="${ref%%/*}"
            # Skip refs that already have a domain prefix or are sha-digest refs
            if [[ "$first_seg" != *.* && "$first_seg" != "localhost" && "$first_seg" != *:* && "$ref" != sha256:* ]]; then
                new_ref="docker.io/$ref"
                ctr -n="$ns" images tag --force "$ref" "$new_ref" >/dev/null 2>&1 && count=$((count + 1))
            fi
        done < <(ctr -n="$ns" images ls -q 2>/dev/null)
        log "  aliased $count bare-name refs in $ns -> docker.io/* equivalents"
    }

    # Idempotency gate: if both namespaces are already populated, skip
    # re-import. Each ctr import takes ~25 min for a 27 GB tarball, and a
    # script re-run (after recoverable failure) shouldn't pay that cost again.
    local k8s_pre moby_pre
    k8s_pre=$(ctr -n=k8s.io images ls -q 2>/dev/null | wc -l)
    moby_pre=$(ctr -n=moby   images ls -q 2>/dev/null | wc -l)
    if [[ "$k8s_pre" -gt 50 ]] && [[ "$moby_pre" -gt 50 ]]; then
        log "containerd already populated (k8s.io=$k8s_pre moby=$moby_pre), skipping re-import"
        # Still run the alias pass -- it's idempotent and ensures kubelet
        # can resolve `docker.io/<ref>` after a manual ctr-import or a
        # bringup-py3 from an earlier version that didn't have this step.
        alias_docker_io_refs "k8s.io"
        alias_docker_io_refs "moby"
        return 0
    fi

    local loaded=0 tarball size k8s_log moby_log k8s_rc moby_rc
    shopt -s nullglob
    for tarball in "$STAGING_DIR"/images-*.tar "$STAGING_DIR"/images-*.tar.gz; do
        size=$(du -h "$tarball" | awk '{print $1}')
        log "Loading $tarball ($size) into containerd k8s.io + moby namespaces (serial)..."
        k8s_log=$(mktemp /tmp/load_local_k8s.XXXXXX.log)
        moby_log=$(mktemp /tmp/load_local_moby.XXXXXX.log)
        # Serial imports. Earlier parallel impl raced on the shared content store
        # (`/var/lib/containerd/io.containerd.content.v1.content/`): both ctr
        # processes try to write the same blob digest simultaneously, one writer
        # gets aborted ("content writer already exists"), and because that
        # writer's tarball stream has already consumed past the blob entry it
        # can't re-stream -- BOTH imports then fail at manifest-verify time
        # with the same "content digest <sha>: not found" error.
        # Serial is safe: second pass re-streams the same blobs but the content
        # store dedupes them (near-instant after first commit), so the second
        # import is dominated by namespace metadata registration, not blob I/O.
        # AELDEV-72882: moby uses --no-unpack. Docker (containerd-snapshotter mode)
        # reads moby for `docker pull` cache-hits via refs + SHARED blobs; unpacking
        # every layer into moby snapshots duplicates the k8s.io set (~1681 snapshots
        # for 155 images though Docker runs only ~5) = ~65G dead weight. --no-unpack
        # keeps moby metadata-only; Docker lazy-unpacks on demand what it runs.
        k8s_rc=0; moby_rc=0
        if [[ "$tarball" == *.gz ]]; then
            gunzip -c "$tarball" | ctr -n=k8s.io images import - >"$k8s_log"  2>&1 || k8s_rc=$?
            gunzip -c "$tarball" | ctr -n=moby   images import --no-unpack - >"$moby_log" 2>&1 || moby_rc=$?
        else
            ctr -n=k8s.io images import "$tarball" >"$k8s_log"  2>&1 || k8s_rc=$?
            ctr -n=moby   images import --no-unpack "$tarball" >"$moby_log" 2>&1 || moby_rc=$?
        fi
        tail -3 "$k8s_log"  | while read -r line; do log "    k8s.io: $line"; done
        tail -3 "$moby_log" | while read -r line; do log "    moby:   $line"; done
        [[ "$k8s_rc"  -ne 0 ]] && log "  WARNING: k8s.io import rc=$k8s_rc"
        [[ "$moby_rc" -ne 0 ]] && log "  WARNING: moby   import rc=$moby_rc"
        rm -f "$k8s_log" "$moby_log" 2>/dev/null || true
        loaded=$((loaded + 1))
    done
    shopt -u nullglob

    if [[ "$loaded" -eq 0 ]]; then
        log "No images-*.tar/tar.gz in $STAGING_DIR -- skipping local image load"
        log "  (registry path will be used during crictl / docker pull)"
        return 0
    fi

    # Tag-alias bare-name refs to docker.io/* equivalents so kubelet's
    # normalized image-pull lookups hit the local cache.
    alias_docker_io_refs "k8s.io"
    alias_docker_io_refs "moby"

    local k8s_count moby_count
    k8s_count=$(ctr -n=k8s.io images ls --quiet 2>/dev/null | wc -l)
    moby_count=$(ctr -n=moby   images ls --quiet 2>/dev/null | wc -l)
    log "post-load: ctr.k8s.io=$k8s_count ctr.moby=$moby_count tarballs=$loaded"

    # AELDEV-71725 Issue #4: per-image cross-namespace verification.
    # Some imports silently land in ONE namespace but not the other
    # (intermittent containerd content-store contention -- QA saw
    # stellar-dms make it into k8s.io but not moby on .11 after a 27 GB
    # import). Without this check, the bringup logs "post-load: ..." OK
    # totals, kubelet pulls succeed, but `docker pull` fails later when
    # aellad / cluster-controller try to pre-pull the upgrade image.
    # Strategy: read images-*.list sidecar (the authoritative manifest
    # written alongside the tar by the publish runbook); for each ref,
    # check presence in BOTH namespaces; if missing in either, re-import
    # the tar into that namespace only, then re-verify.
    local list_file k8s_missing=0 moby_missing=0
    shopt -s nullglob
    for list_file in "$STAGING_DIR"/images-*.list; do
        log "  cross-namespace verify against $list_file"
        # snapshot both namespaces once (avoid 147 separate ctr invocations)
        ctr -n=k8s.io images ls --quiet 2>/dev/null | sort > /tmp/_load_k8s_refs.$$
        ctr -n=moby   images ls --quiet 2>/dev/null | sort > /tmp/_load_moby_refs.$$
        while IFS= read -r ref; do
            [[ -z "$ref" || "$ref" =~ ^# ]] && continue
            if ! grep -Fxq "$ref" /tmp/_load_k8s_refs.$$; then
                log "    MISSING from k8s.io: $ref"
                k8s_missing=$((k8s_missing + 1))
            fi
            if ! grep -Fxq "$ref" /tmp/_load_moby_refs.$$; then
                log "    MISSING from moby:   $ref"
                moby_missing=$((moby_missing + 1))
            fi
        done < "$list_file"
        rm -f /tmp/_load_k8s_refs.$$ /tmp/_load_moby_refs.$$
    done
    shopt -u nullglob

    if [[ "$k8s_missing" -gt 0 || "$moby_missing" -gt 0 ]]; then
        log "  cross-ns verify: k8s.io missing=$k8s_missing moby missing=$moby_missing -- re-importing partial namespace(s)"
        shopt -s nullglob
        for tarball in "$STAGING_DIR"/images-*.tar "$STAGING_DIR"/images-*.tar.gz; do
            if [[ "$k8s_missing" -gt 0 ]]; then
                log "    re-importing $tarball into k8s.io"
                if [[ "$tarball" == *.gz ]]; then
                    gunzip -c "$tarball" | ctr -n=k8s.io images import - >/dev/null 2>&1 || true
                else
                    ctr -n=k8s.io images import "$tarball" >/dev/null 2>&1 || true
                fi
            fi
            if [[ "$moby_missing" -gt 0 ]]; then
                log "    re-importing $tarball into moby (--no-unpack)"
                if [[ "$tarball" == *.gz ]]; then
                    gunzip -c "$tarball" | ctr -n=moby images import --no-unpack - >/dev/null 2>&1 || true
                else
                    ctr -n=moby   images import --no-unpack "$tarball" >/dev/null 2>&1 || true
                fi
            fi
        done
        shopt -u nullglob
        alias_docker_io_refs "k8s.io"
        alias_docker_io_refs "moby"
        # re-verify after retry
        k8s_missing=0; moby_missing=0
        shopt -s nullglob
        for list_file in "$STAGING_DIR"/images-*.list; do
            ctr -n=k8s.io images ls --quiet 2>/dev/null | sort > /tmp/_load_k8s_refs.$$
            ctr -n=moby   images ls --quiet 2>/dev/null | sort > /tmp/_load_moby_refs.$$
            while IFS= read -r ref; do
                [[ -z "$ref" || "$ref" =~ ^# ]] && continue
                grep -Fxq "$ref" /tmp/_load_k8s_refs.$$ || k8s_missing=$((k8s_missing + 1))
                grep -Fxq "$ref" /tmp/_load_moby_refs.$$ || moby_missing=$((moby_missing + 1))
            done < "$list_file"
            rm -f /tmp/_load_k8s_refs.$$ /tmp/_load_moby_refs.$$
        done
        shopt -u nullglob
        if [[ "$k8s_missing" -gt 0 || "$moby_missing" -gt 0 ]]; then
            log "  WARNING: after re-import still missing -- k8s.io=$k8s_missing moby=$moby_missing"
            log "  WARNING: pods referencing those tags will hit ImagePullBackOff on darksite"
        else
            log "  cross-ns verify (post-retry): all images present in both namespaces"
        fi
    else
        log "  cross-ns verify: all images present in both namespaces"
    fi
}

###############################################################################
# PHASE 4: INSTALL KUBERNETES 1.31
###############################################################################
install_kubernetes() {
    log_phase "Install Kubernetes 1.31"

    # Check if already installed
    if kubeadm version 2>/dev/null | grep -q "1.31"; then
        log "Kubernetes 1.31 already installed"
    else
        # Remove system-installed K8s packages if wrong version
        local sys_kubeadm_ver
        sys_kubeadm_ver=$(dpkg -s kubeadm 2>/dev/null | grep '^Version:' | awk '{print $2}' || true)
        if [[ -n "$sys_kubeadm_ver" ]] && ! echo "$sys_kubeadm_ver" | grep -q "1\.31"; then
            log "Removing system K8s packages (v${sys_kubeadm_ver}) -- will install 1.31 from debs"
            # Backup CNI plugins before purge
            if [[ -d /opt/cni/bin ]]; then
                cp -a /opt/cni/bin /opt/cni/bin.bak 2>/dev/null || true
            fi
            apt-mark unhold kubeadm kubectl kubelet kubernetes-cni cri-tools 2>/dev/null || true
            dpkg --purge --force-depends kubeadm kubectl kubelet kubernetes-cni cri-tools 2>/dev/null || true
            rm -f /usr/bin/kubeadm /usr/bin/kubectl /usr/bin/kubelet 2>/dev/null || true
            # Restore CNI plugins
            if [[ -d /opt/cni/bin.bak ]]; then
                mkdir -p /opt/cni/bin
                cp -a /opt/cni/bin.bak/* /opt/cni/bin/ 2>/dev/null || true
                rm -rf /opt/cni/bin.bak
                log "CNI plugins preserved in /opt/cni/bin/"
            fi
        fi

        # Install dependency debs: socat, ebtables, conntrack
        for dep_name in "socat" "ebtables" "conntrack"; do
            local dep_deb
            dep_deb=$(find -L "$STAGING_DIR" -name "${dep_name}*_amd64.deb" -o -name "${dep_name}*amd64.deb" 2>/dev/null | head -1 || true)
            if [[ -z "$dep_deb" ]]; then
                # conntrack filename has %3a encoding
                dep_deb=$(find -L "$STAGING_DIR" -name "${dep_name}*" -name "*.deb" 2>/dev/null | head -1 || true)
            fi
            if [[ -n "$dep_deb" ]]; then
                dpkg -i --force-depends "$dep_deb" 2>/dev/null || true
                log "Installed $dep_name from deb"
            else
                apt-get install -qqy "$dep_name" 2>/dev/null || log "WARNING: $dep_name not available"
            fi
        done

        # Install K8s debs in dependency order:
        # 1. kubernetes-cni (CNI plugins)
        # 2. cri-tools (crictl)
        # 3. kubelet
        # 4. kubectl
        # 5. kubeadm
        local k8s_install_order=("kubernetes-cni" "cri-tools" "kubelet" "kubectl" "kubeadm")
        for pkg_name in "${k8s_install_order[@]}"; do
            local pkg_deb
            pkg_deb=$(find -L "$STAGING_DIR" -name "${pkg_name}_*_amd64.deb" -o -name "${pkg_name}_*amd64.deb" 2>/dev/null | head -1 || true)
            if [[ -n "$pkg_deb" ]]; then
                log "Installing $pkg_name..."
                dpkg -i --force-depends "$pkg_deb" 2>&1 || true
            else
                log "WARNING: $pkg_name deb not found in $STAGING_DIR"
            fi
        done

        # Verify
        command -v kubeadm &>/dev/null || die "kubeadm binary not found after installation"
        log "kubeadm installed: $(kubeadm version 2>&1 | head -1)"
    fi

    # Configure crictl to use containerd
    cat > /etc/crictl.yaml <<'CRICTL'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
CRICTL
    log "crictl configured for containerd"

    # Create kubelet service file (base unit -- args come from drop-in below)
    cat > /usr/lib/systemd/system/kubelet.service <<'KUBESVC'
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/home/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
KUBESVC

    # Create kubeadm drop-in for kubelet (normally installed by kubeadm deb package).
    # Without this, kubelet runs in standalone mode with no --kubeconfig or --config flags,
    # and cannot register with the API server or start control plane static pods.
    mkdir -p /etc/systemd/system/kubelet.service.d
    cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<'KUBEDROPIN'
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
KUBEDROPIN

    # Hold K8s packages to prevent apt from upgrading them
    apt-mark hold kubeadm kubectl kubelet kubernetes-cni cri-tools 2>/dev/null || true

    # Disable swap (required by K8s)
    swapoff -a
    sed -i '/swap/d' /etc/fstab

    # Enable kubelet. AELDEV-73583: UNMASK first -- purging the old 1.19
    # kubelet (preflight) while its unit was enabled can leave the unit
    # masked (dangling enablement -> systemd "masked" state), especially
    # when a prior bringup run was interrupted between purge and install.
    # A masked unit silently defeats both `systemctl enable` and kubeadm's
    # own kubelet-start -> kubeadm init times out at wait-control-plane
    # with kubelet dead (observed live 2026-07-23). unmask is a no-op when
    # not masked.
    systemctl unmask kubelet 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable kubelet 2>/dev/null || true

    log "Kubernetes 1.31 installation complete"
}

###############################################################################
# PHASE 5: INSTALL HELM 3.17
###############################################################################
install_helm() {
    log_phase "Install Helm 3.17"

    # Check if already installed
    if helm version --short 2>/dev/null | grep -q "v3.17"; then
        log "Helm 3.17 already installed: $(helm version --short 2>&1)"
        return 0
    fi

    local helm_tarball="${STAGING_DIR}/helm-v3.17.0-linux-amd64.tar.gz"
    if [[ ! -f "$helm_tarball" ]]; then
        log "WARNING: Helm tarball not found at $helm_tarball"
        log "  Attempting download from get.helm.sh..."
        curl -sSL https://get.helm.sh/helm-v3.17.0-linux-amd64.tar.gz -o "$helm_tarball" || \
            die "Failed to download Helm tarball"
    fi

    log "Extracting Helm..."
    # The tarball contains linux-amd64/helm
    local tmpdir="/tmp/helm_extract_$$"
    mkdir -p "$tmpdir"
    tar -xzf "$helm_tarball" -C "$tmpdir" || die "Failed to extract Helm tarball"

    # Copy helm binary to /usr/bin
    if [[ -f "$tmpdir/linux-amd64/helm" ]]; then
        cp "$tmpdir/linux-amd64/helm" /usr/bin/helm
    elif [[ -f "$tmpdir/helm" ]]; then
        cp "$tmpdir/helm" /usr/bin/helm
    else
        die "helm binary not found in tarball"
    fi
    chmod +x /usr/bin/helm
    rm -rf "$tmpdir"

    # Verify
    helm version --short 2>&1 || die "helm not working after installation"
    log "Helm installed: $(helm version --short 2>&1)"
}

###############################################################################
# PHASE 6: INSTALL UVP
###############################################################################
install_uvp() {
    log_phase "Install UVP Package"

    # Check if all UVP packages are already installed with correct version
    # Py3 UVP package name is aella-uvp-2404 (py2 is aella-uvp)
    local all_installed=true
    for pkg in aella-da-services aella-da-cli aellacm kube-tools phonehome pypki; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            all_installed=false
            break
        fi
    done
    # Check py3 UVP meta-package
    if ! dpkg -s aella-uvp-2404 &>/dev/null; then
        all_installed=false
    fi
    if [[ "$all_installed" == "true" ]]; then
        local installed_ver
        installed_ver=$(dpkg -s aella-uvp-2404 2>/dev/null | grep '^Version:' | awk '{print $2}' | sed 's/ubuntu.*//' || true)
        if [[ "$installed_ver" == "$VERSION" ]]; then
            log "UVP $VERSION and all sub-packages already installed -- skipping"
            mkdir -p /opt/aelladata/work
            if [[ ! -f /opt/aelladata/work/logical_tenants ]]; then
                echo '{"enable": true}' > /opt/aelladata/work/logical_tenants
            fi
            # Still ensure PyPKI module is extracted (deb only installs egg-info)
            local pypki_tarball="/opt/aelladata/3rd/PyPKI-py3.tar.gz"
            local py3_dist="/usr/lib/python3/dist-packages"
            if [[ -f "$pypki_tarball" ]] && [[ ! -d "${py3_dist}/PyPKI" ]]; then
                log "Extracting PyPKI module (UVP already installed but module missing)..."
                tar -xzf "$pypki_tarball" -C "$py3_dist" 2>/dev/null || log "WARNING: Failed to extract PyPKI tarball"
            fi
            return 0
        fi
    fi

    # AELDEV-70186/70189: Purge ANY pre-existing aella package state before
    # installing target py3 UVP. Covers:
    #   - py2-to-py3 migration (aella-uvp + py2 sub-pkgs own files under
    #     /opt/aelladata/aelladeb/ that collide with aella-uvp-2404)
    #   - partial py3 install (meta present, sub-pkgs missing or vice versa)
    #   - stale sub-pkgs without meta (leftover from OS-upgrade snapshot or
    #     prior failed install) -- dpkg Pass 2 can't downgrade across versions
    # Also drop py2 /opt/aelladata/python/aellautil (has `from sets import Set`
    # which breaks python3 when render_kubeadm_config.py imports it later).
    local to_purge=()
    for pkg in aella-da-services aella-da-cli aellacm kube-tools phonehome pypki; do
        dpkg -s "$pkg" &>/dev/null && to_purge+=("$pkg")
    done
    for meta in aella-uvp aella-uvp-2404; do
        dpkg -s "$meta" &>/dev/null && to_purge+=("$meta")
    done
    if [[ ${#to_purge[@]} -gt 0 ]]; then
        log "Purging existing aella packages before install: ${to_purge[*]}"
        for pkg in "${to_purge[@]}"; do
            log "  purge $pkg"
            dpkg --purge --force-all "$pkg" >/dev/null 2>&1 || \
                log "  WARNING: failed to purge $pkg (may block UVP install)"
        done
        if [[ -d /opt/aelladata/python/aellautil ]]; then
            rm -rf /opt/aelladata/python/aellautil 2>/dev/null || true
            log "  removed /opt/aelladata/python/aellautil (py2-compat cleanup)"
        fi

        # AELDEV-70735: clear stale runtime locks left by py2 containers.
        # During destructive py2->py3 transition, Docker 18.06 -> 29.1.3
        # replacement kills py2 pods ungracefully, leaving lock files in
        # hostPath-mounted data dirs. New py3 pods then CrashLoopBackOff:
        #   aella-mongodb-0  -> "DBPathInUse: Unable to lock mongod.lock"
        #   stellar-css      -> can't reach mongo -> dependent pods cascade
        #   aella-cm-master  -> blocked waiting for mongo
        # SAFETY: only run if no mongod/beam.smp host process is alive.
        # Container processes are visible in the host PID namespace, so
        # `pgrep -x mongod` reliably detects a live mongo inside any
        # K8s pod backed by /opt/aelladata/mongodb hostPath. Deleting a
        # held lockfile inode is technically safe (flock survives unlink
        # via the open FD) but would let a second mongo start on the same
        # data dir = corruption -- so gate strictly.
        if ! pgrep -x mongod >/dev/null 2>&1 && ! pgrep -x beam.smp >/dev/null 2>&1; then
            local stale_locks=(
                /opt/aelladata/mongodb/mongod.lock
                /opt/aelladata/mongodb/WiredTiger.lock
                /opt/aelladata/custom-response-mongodb/mongod.lock
                /opt/aelladata/custom-response-mongodb/WiredTiger.lock
                /opt/aelladata/work/aella-rabbit/rabbit@aella-rabbit-0.pid
            )
            local cleared=0
            for lock in "${stale_locks[@]}"; do
                if [[ -e "$lock" ]]; then
                    rm -f "$lock" 2>/dev/null && cleared=$((cleared + 1))
                fi
            done
            # Defensive sweep for any other .pid files under work/ (rabbit pid
            # naming varies by hostname/install).
            find /opt/aelladata/work -maxdepth 3 -name "*.pid" -type f -delete 2>/dev/null || true
            [[ $cleared -gt 0 ]] && log "  cleared $cleared stale runtime lock(s) (mongo/rabbit)"
        else
            log "  skipping stale-lock sweep: mongod or beam.smp still running"
        fi
    fi

    # AELDEV-70735: dpkg --purge aella-uvp/aella-uvp-2404 postrm removes
    # /opt/aelladata/aelladeb. Re-create here and harden find with `|| true`
    # so `set -euo pipefail` doesn't kill the script on find rc=1 when dir
    # is briefly absent (same pattern as bringup_py2).
    mkdir -p "$AELLADEB_DIR" "$STAGING_DIR" 2>/dev/null || true

    # Find py3 UVP deb (aella-uvp-2404)
    local uvp_deb
    uvp_deb=$(find -L "$AELLADEB_DIR" "$STAGING_DIR" -name "aella-uvp-2404_${VERSION}ubuntu1_amd64.deb" 2>/dev/null | head -1 || true)
    if [[ -z "$uvp_deb" ]]; then
        # Try any version of aella-uvp-2404
        uvp_deb=$(find -L "$AELLADEB_DIR" "$STAGING_DIR" -name "aella-uvp-2404_*_amd64.deb" 2>/dev/null | head -1 || true)
    fi
    if [[ -z "$uvp_deb" ]]; then die "aella-uvp-2404 deb not found in $AELLADEB_DIR or $STAGING_DIR"; fi

    log "Installing UVP: $(basename "$uvp_deb")"

    # Pass 1: Install UVP (postinst extracts sub-packages to aelladeb/)
    log "Pass 1: Installing UVP deb..."
    DEBIAN_FRONTEND=noninteractive dpkg -i --force-depends --force-conflicts --force-confnew "$uvp_deb" 2>&1 | grep -v "dependency problems" || true

    # Pass 2: Install sub-packages extracted by UVP postinst.
    # Use explicit name matching (not `-newer "$uvp_deb"`): the outer deb
    # preserves sub-deb mtimes from build time, so on workers that receive
    # the outer deb via scp mid-bringup, sub-debs end up with OLDER mtimes
    # than the freshly-SCPed UVP deb. `-newer` filter would silently skip
    # them all and leave only the meta package installed (1/7). Name-match
    # always picks up the right debs regardless of mtime.
    local sub_debs
    sub_debs=$(find "$AELLADEB_DIR" \( -name "aella-da-services_*.deb" -o \
                                         -name "aellacm_*.deb" -o \
                                         -name "aella-da-cli_*.deb" -o \
                                         -name "kube-tools_*.deb" -o \
                                         -name "phonehome_*.deb" -o \
                                         -name "pypki_*.deb" \) 2>/dev/null)
    for deb in $sub_debs; do
        log "  Installing: $(basename "$deb")"
        DEBIAN_FRONTEND=noninteractive dpkg -i --force-depends --force-conflicts --force-confnew "$deb" 2>&1 | grep -v "dependency problems" || true
    done

    # NEVER run apt-get install -f (would remove aella packages due to unmet deps)

    # Create logical_tenants if missing
    mkdir -p /opt/aelladata/work
    if [[ ! -f /opt/aelladata/work/logical_tenants ]]; then
        echo '{"enable": true}' > /opt/aelladata/work/logical_tenants
    fi

    # Verify sub-packages (meta-package is aella-uvp-2404)
    local pkg_count=0
    if dpkg -s aella-uvp-2404 &>/dev/null; then
        ((pkg_count++)) || true
    else
        log "WARNING: aella-uvp-2404 meta-package not installed"
    fi
    for pkg in aella-da-services aella-da-cli aellacm kube-tools phonehome pypki; do
        if dpkg -s "$pkg" &>/dev/null; then
            ((pkg_count++)) || true
        else
            log "WARNING: Package not installed: $pkg"
        fi
    done
    log "UVP packages installed: $pkg_count/7"

    # The pypki deb only installs egg-info metadata, not the actual PyPKI module.
    # Extract from /opt/aelladata/3rd/PyPKI-py3.tar.gz into dist-packages.
    local pypki_tarball="/opt/aelladata/3rd/PyPKI-py3.tar.gz"
    local py3_dist="/usr/lib/python3/dist-packages"
    if [[ -f "$pypki_tarball" ]] && [[ ! -d "${py3_dist}/PyPKI" ]]; then
        log "Extracting PyPKI module from $pypki_tarball..."
        tar -xzf "$pypki_tarball" -C "$py3_dist" 2>/dev/null || log "WARNING: Failed to extract PyPKI tarball"
        python3 -c "from PyPKI import PyPKI" 2>/dev/null && log "PyPKI module OK" || \
            log "WARNING: PyPKI import still fails after extraction"
    elif [[ -d "${py3_dist}/PyPKI" ]]; then
        log "PyPKI module already present"
    else
        log "WARNING: PyPKI tarball not found at $pypki_tarball -- aellad will fail"
    fi
}

###############################################################################
# PHASE 7: SYSTEM PREPARATION
###############################################################################
prepare_system() {
    log_phase "System Preparation"

    # Load br_netfilter kernel module (required by flannel/K8s networking).
    # Docker 18.06 loaded this automatically; containerd does not.
    # Without it, flannel crashes: "Failed to check br_netfilter: no such file"
    log "Loading br_netfilter kernel module..."
    modprobe br_netfilter 2>/dev/null || log "WARNING: Failed to load br_netfilter"
    grep -qxF "br_netfilter" /etc/modules-load.d/k8s.conf 2>/dev/null || {
        mkdir -p /etc/modules-load.d
        echo "br_netfilter" >> /etc/modules-load.d/k8s.conf
    }
    sysctl -w net.bridge.bridge-nf-call-iptables=1 2>/dev/null || true
    grep -qxF "net.bridge.bridge-nf-call-iptables=1" /etc/sysctl.conf || echo "net.bridge.bridge-nf-call-iptables=1" >> /etc/sysctl.conf

    # sysctl tuning (ES, K8s requirements)
    log "Configuring sysctl..."
    sysctl -w vm.max_map_count=2621440 2>/dev/null || true
    sysctl -w vm.swappiness=0 2>/dev/null || true
    grep -qxF "vm.max_map_count=2621440" /etc/sysctl.conf || echo "vm.max_map_count=2621440" >> /etc/sysctl.conf
    grep -qxF "vm.swappiness=0" /etc/sysctl.conf || echo "vm.swappiness=0" >> /etc/sysctl.conf
    grep -qxF "fs.inotify.max_user_watches=1048576" /etc/sysctl.conf || echo "fs.inotify.max_user_watches=1048576" >> /etc/sysctl.conf
    grep -qxF "fs.inotify.max_user_instances=1024" /etc/sysctl.conf || echo "fs.inotify.max_user_instances=1024" >> /etc/sysctl.conf
    grep -qxF "vm.overcommit_memory=1" /etc/sysctl.conf || echo "vm.overcommit_memory=1" >> /etc/sysctl.conf
    # TCP keepalive for ES
    grep -qxF "net.ipv4.tcp_keepalive_time=600" /etc/sysctl.conf || echo "net.ipv4.tcp_keepalive_time=600" >> /etc/sysctl.conf
    grep -qxF "net.ipv4.tcp_keepalive_intvl=15" /etc/sysctl.conf || echo "net.ipv4.tcp_keepalive_intvl=15" >> /etc/sysctl.conf
    sysctl -p 2>/dev/null || true
    ulimit -n 65536

    # Fix DNS resolution for Ubuntu 24.04
    log "Configuring DNS resolution..."
    systemctl stop dnsmasq 2>/dev/null || true
    systemctl disable dnsmasq 2>/dev/null || true
    systemctl mask dnsmasq 2>/dev/null || true
    systemctl enable systemd-resolved 2>/dev/null || true
    systemctl start systemd-resolved 2>/dev/null || true
    # Ensure resolv.conf is usable. AELDEV-74638: never repoint a resolv.conf
    # that already has real nameservers -- on a 16.04-upgraded ifupdown box
    # systemd-resolved has no DNS config, so unconditionally linking to its
    # runtime file (or writing 8.8.8.8) discards the customer's configured DNS.
    # EXCEPTION: the 127.0.0.53 stub (netplan boxes) is fine for host lookups
    # but must not leak into resolv-kube.conf (kubelet resolvConf, generated
    # below) -- the stub is unreachable from inside containers. The resolved
    # runtime file carries the same configured DNS, so swapping to it
    # preserves the customer's servers.
    if resolv_conf_usable; then
        # Swap ONLY a loopback-ONLY file (the resolv_conf_usable pass above
        # then guarantees the runtime file has the upstreams) -- a mixed file
        # with real nameservers is kept, and the resolv-kube.conf generation
        # below filters the loopback lines out for pods.
        if ! grep "^nameserver" /etc/resolv.conf 2>/dev/null | \
                grep -qvE "^nameserver[[:space:]]+(127\.|::1)"; then
            rm -f /etc/resolv.conf
            ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
            log "DNS: swapped loopback-only resolv.conf for systemd-resolved runtime file"
        else
            log "DNS: existing resolv.conf has real nameservers -- keeping"
        fi
    else
        rebuild_resolv_conf
    fi

    # Create resolv-kube.conf (needed for musl/Alpine containers in K8s 1.31)
    # Copy nameserver lines from resolv.conf, strip cloud search domains, append "search ."
    # AELDEV-74638: loopback resolvers (127.x/::1) are unreachable from inside
    # a pod netns -- filter them so pods only ever get real upstreams.
    log "Creating /etc/resolv-kube.conf..."
    {
        grep '^nameserver' /etc/resolv.conf 2>/dev/null | \
            grep -vE '^nameserver[[:space:]]+(127\.|::1)' || echo "nameserver 8.8.8.8"
        echo "search ."
    } > /etc/resolv-kube.conf
    log "resolv-kube.conf created with nameservers + 'search .'"

    # Clean stale K8s state
    log "Cleaning stale K8s state..."
    systemctl stop kubelet 2>/dev/null || true
    kubeadm reset -f 2>/dev/null || true
    flush_stale_kube_iptables
    rm -rf /etc/kubernetes/ /var/lib/kubelet/pki/ /var/lib/etcd/ /run/flannel/
    # Keep /var/lib/kubelet/ itself (may have config)
    ip link set cni0 down 2>/dev/null || true
    ip link set flannel.1 down 2>/dev/null || true
    bridge fdb flush dev flannel.1 2>/dev/null || true
    ip link delete cni0 2>/dev/null || true
    ip link delete flannel.1 2>/dev/null || true
    rm -rf /var/lib/cni/networks/* 2>/dev/null || true

    # AELDEV-71573: wipe stale kafka broker state. Kafka writes
    # meta.properties with the broker's cluster.id (from ZK) under
    # /opt/aelladata/run/{kafka,stellar-buffer}/logs/. bringup_py3 is
    # destructive at the K8s layer -- new ZK init generates a fresh
    # cluster.id -- but /opt/aelladata/run is preserved (mongo, etcd,
    # other live state). When kafka comes back up post-bringup, it
    # reads the OLD meta.properties cluster.id, finds it doesn't match
    # the new ZK, and dies with:
    #   kafka.common.InconsistentClusterIdException: The Cluster ID X
    #   doesn't match stored clusterId Y in meta.properties.
    # -> kafka-pod-0 + stellar-buffer-0 CrashLoopBackOff, receivers
    # never deploy (depend on kafka), "Missing pods: kafka" /
    # "Data Lake cluster not ready" / "Missing pods: processor" in
    # aella_cli show status. Wipe is data-safe: kafka topics are
    # rebuilt automatically by producers (aella services) on first
    # message; this is exactly what fresh-cluster init expects.
    for kafka_dir in /opt/aelladata/run/kafka/logs \
                     /opt/aelladata/run/stellar-buffer/logs; do
        if [[ -e "$kafka_dir/meta.properties" ]]; then
            log "Wiping stale kafka state: $kafka_dir/meta.properties (stale cluster.id)"
            rm -rf "$kafka_dir"
        fi
    done

    # AELDEV-71573: seed self-signed mlgs cert/key on dark-site so
    # autosoc-local + stellar-summary-customer + stellar-indicator-verify
    # don't CrashLoopBackOff on missing /run/scgs/client.crt mount.
    seed_mlgs_cert_for_darksite

    # Fix /etc/hosts
    log "Fixing /etc/hosts..."
    local hostname_val
    hostname_val=$(hostname)
    local cluster_if
    cluster_if=$(grep 'cluster_interface' "$DA_CONF" 2>/dev/null | awk -F': ' '{print $2}' | tr -d "' \"" || true)
    local host_ip=""
    if [[ -n "$cluster_if" ]]; then
        host_ip=$(ip -4 addr show "$cluster_if" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1 || true)
    fi
    # Fallback: use master_ip from da_conf or first non-loopback IP
    if [[ -z "$host_ip" ]]; then
        host_ip=$(grep 'master_ip' "$DA_CONF" 2>/dev/null | awk -F': ' '{print $2}' | tr -d "' \"" || true)
    fi
    if [[ -z "$host_ip" ]]; then
        host_ip=$(ip -4 addr show | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -1 || true)
    fi
    if [[ -n "$host_ip" ]]; then
        sed -i "/$hostname_val/d" /etc/hosts
        echo "$host_ip $hostname_val" >> /etc/hosts
        log "Added to /etc/hosts: $host_ip $hostname_val"
    fi

    # Install flannel cleanup service
    install_flannel_cleanup_service

    # AELDEV-71725: durable fix for the 24.04 MACAddressPolicy vs flannel
    # VtepMAC drift. systemd-udevd defaults MACAddressPolicy=persistent
    # which assigns flannel.1 a deterministic MAC every boot. Flannel
    # pods expect the random per-restart VtepMAC they generated to remain
    # stable -- when udev overrides it, the VtepMAC<>actual-MAC mismatch
    # causes cross-node VXLAN packets to be dropped as 'otherhost' on the
    # receiving side, breaking pod-to-pod DNS (e.g. `stellar-css` lookups
    # from DL-worker -> DL-master). Symptom: ES init container raises
    # `DNS resolution failed for stellar-css` after wait_for_service
    # retries 15x. The non-durable workaround `kubectl delete pod -l
    # app=flannel` re-pulls the right MAC but re-diverges on every reboot.
    # Durable fix: tell udev NOT to touch flannel.1's MAC. This file is
    # idempotent and harmless on systems where flannel never gets deployed.
    install_flannel_mac_policy_override

    # Enable ipv4 forwarding
    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
    grep -qxF "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    log "System preparation complete"
}

install_flannel_cleanup_service() {
    log "Installing flannel cleanup service..."

    mkdir -p /opt/aelladata/kubernetes/scripts

    cat > /opt/aelladata/kubernetes/scripts/flannel-cleanup.sh << 'CLEANUP_SCRIPT_EOF'
#!/bin/bash
LOG_FILE=/var/log/aella/flannel-cleanup.log
mkdir -p /var/log/aella
{
  echo "Flannel cleanup started: $(date)"
  if [ ! -f /etc/kubernetes/kubelet.conf ]; then
    echo "Kubelet not configured - skipping"
    exit 0
  fi
  if ip link show flannel.1 &>/dev/null; then
    ip link set flannel.1 down 2>/dev/null || true
    bridge fdb flush dev flannel.1 2>/dev/null || true
    ip link delete flannel.1 2>/dev/null || true
  fi
  if ip link show cni0 &>/dev/null; then
    ip link set cni0 down 2>/dev/null || true
    ip link delete cni0 2>/dev/null || true
  fi
  rm -f /run/flannel/subnet.env 2>/dev/null || true
  rm -rf /var/lib/cni/networks/* 2>/dev/null || true
  echo "Flannel cleanup done"
} >> "$LOG_FILE" 2>&1
exit 0
CLEANUP_SCRIPT_EOF
    chmod +x /opt/aelladata/kubernetes/scripts/flannel-cleanup.sh

    cat > /etc/systemd/system/flannel-cleanup.service << 'SERVICE_EOF'
[Unit]
Description=Clean up stale Flannel CNI state before kubelet starts
Before=kubelet.service
After=network.target
ConditionPathExists=/opt/aelladata/kubernetes/scripts/flannel-cleanup.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/aelladata/kubernetes/scripts/flannel-cleanup.sh

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable flannel-cleanup.service 2>/dev/null || true
}

install_flannel_mac_policy_override() {
    local link_file=/etc/systemd/network/10-flannel.link
    mkdir -p /etc/systemd/network
    cat > "$link_file" << 'LINK_EOF'
# AELDEV-71725: prevent systemd-udev from overriding flannel.1's MAC.
# Flannel CNI generates a per-restart random VtepMAC and tags VXLAN
# packets with it. If udev later reassigns flannel.1 a persistent MAC,
# the MAC<>VtepMAC drift causes peer nodes to drop incoming traffic
# as 'otherhost' -- cross-node pod DNS (stellar-css) and pod traffic
# silently breaks. MACAddressPolicy=none tells udev to leave the MAC
# flannel set alone.
[Match]
OriginalName=flannel.1

[Link]
MACAddressPolicy=none
LINK_EOF
    log "Installed flannel MAC-policy override: $link_file"
    # Reload udev rules. If flannel.1 already exists with the wrong MAC,
    # the flannel-cleanup.service deletes it next boot and the new one
    # gets the policy. We don't force-delete here since flannel may not
    # yet exist on a fresh install.
    udevadm control --reload-rules 2>/dev/null || true
}

###############################################################################
# AELDEV-71573: seed self-signed mlgs cert+key on dark-site DPs.
# /opt/aelladata/work/metarepo/root/{mlgs_cert,mlgs_key}/client.{cert,key}
# are normally synced from ACPS by metarepo's release-sync (see
# metarepo/image/root/release-sync.yml). ACPS is unreachable on dark-site
# -> sync fails -> the FILES never get written. Pods that hostPath+subPath
# mount these (autosoc-local, stellar-summary-customer,
# stellar-indicator-verify) then see `/run/scgs/client.crt` as a directory
# (k8s subPath behavior when target missing) and CrashLoopBackOff with
# `IsADirectoryError`.
# SCGS itself is a cloud-only ML service so the pods can't actually reach
# it from dark-site anyway -- this is just so they don't crash-loop. The
# generated cert is local, self-signed, never trusted by any real SCGS
# server. Only runs on --skip-download (dark-site) AND on DL-master/AIO
# (where the pods are scheduled). Idempotent -- skip if files exist.
###############################################################################
seed_mlgs_cert_for_darksite() {
    [[ "$SKIP_DOWNLOAD" != "true" ]] && return 0
    case "$ROLE" in
        DL-master|AIO) ;;
        *) return 0 ;;
    esac

    local cert_dir="/opt/aelladata/work/metarepo/root/mlgs_cert"
    local key_dir="/opt/aelladata/work/metarepo/root/mlgs_key"
    local cert_file="$cert_dir/client.cert"
    local key_file="$key_dir/client.key"

    # Skip if both are already valid files (set up by a prior bringup or
    # a customer's offline manual seed).
    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        log "mlgs cert/key already present as files; skipping self-signed seed"
        return 0
    fi

    log "Seeding self-signed mlgs cert/key for dark-site (SCGS cloud-only; pods won't actually reach SCGS, but the mount needs to be a file so pods don't CrashLoopBackOff with IsADirectoryError)"
    # rm -rf to clear any partial directory state (k8s subPath mounts may
    # have created client.cert/ or client.key/ as DIRECTORIES on prior
    # restart attempts; openssl can't write a file where a dir exists).
    rm -rf "$cert_dir" "$key_dir"
    mkdir -p "$cert_dir" "$key_dir"
    if ! openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
        -keyout "$key_file" -out "$cert_file" \
        -subj "/CN=mlgs-client-$(hostname)" 2>/dev/null; then
        log "  WARNING: openssl req failed; skipping (SCGS pods will CrashLoop until cert is manually seeded)"
        return 0
    fi
    chmod 644 "$cert_file" "$key_file"
    log "  mlgs cert/key seeded: $(ls -la "$cert_file" "$key_file" 2>/dev/null | awk '{print $NF}' | tr '\n' ' ')"
}

###############################################################################
# PHASE 8: START AELLA SERVICES
###############################################################################
ensure_python3_symlink() {
    # AELDEV-70457: aella-cms (and other py3 binaries) use shebang
    # `#!/usr/bin/env python`, so /usr/bin/python MUST point to python3.
    # On 24.04 DPs upgraded from 16.04 py2, residual `python-minimal`
    # (from 16.04, depended on by nodejs+trace-cmd) gets re-pulled by
    # `apt --fix-broken install` during bringup; its postinst recreates
    # /usr/bin/python -> python2.7. Defensive reset -- call at every
    # boundary where aellad may start/restart, and once at the end of
    # main(). Harmless if already correct.
    if [[ -L /usr/bin/python ]] && [[ "$(readlink /usr/bin/python)" == *"python3"* ]]; then
        return 0
    fi
    ln -sf /usr/bin/python3 /usr/bin/python
    log "  Reset /usr/bin/python -> python3 (was: $(readlink /usr/bin/python 2>/dev/null || echo 'absent'))"
}

start_aella_services() {
    log_phase "Start Aella Systemd Services"

    # AELDEV-70457: ensure python -> python3 RIGHT before aellad starts.
    # Earlier symlink set in install_python3 may have been clobbered by
    # apt --fix-broken pulling python-minimal back in.
    ensure_python3_symlink

    systemctl daemon-reload

    local services=(aella_cluster_manager aella_ctrl_rh aella_conf_rh aella_conf_sys aella_cluster_controller aella_cluster_scheduler aellad)

    for svc in "${services[@]}"; do
        log "Starting $svc..."
        systemctl enable "$svc" 2>/dev/null || true
        systemctl start "$svc" 2>/dev/null || true
        sleep 3

        if ! systemctl is-active --quiet "$svc"; then
            log "WARNING: $svc not active, retrying..."
            systemctl restart "$svc" 2>/dev/null || true
            sleep 5
            if ! systemctl is-active --quiet "$svc"; then
                log "WARNING: $svc still not active after retry"
            fi
        fi

        local status
        status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
        log "  $svc: $status"
    done
}

###############################################################################
# PHASE 9: K8S MASTER INIT (master/AIO only)
###############################################################################
init_k8s_master() {
    log_phase "Initialize Kubernetes Master"

    export PYTHONPATH=/opt/aelladata/python:/opt/aelladata/cms
    export KUBECONFIG=/etc/kubernetes/admin.conf

    # Skip if already initialized
    if [[ -f /etc/kubernetes/kubelet.conf ]]; then
        log "K8s already initialized (kubelet.conf exists)"
        return 0
    fi

    # Detect master IP
    local master_ip=""
    local cluster_if
    cluster_if=$(grep 'cluster_interface' "$DA_CONF" 2>/dev/null | awk -F': ' '{print $2}' | tr -d "' \"" || true)

    if [[ -n "$cluster_if" ]]; then
        master_ip=$(ip -4 addr show "$cluster_if" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1 || true)
    fi
    if [[ -z "$master_ip" ]]; then
        local master_if
        master_if=$(ip link show | grep ': en.[0-9]\|: eth[0-9]' | head -1 | awk '{print $2}' | sed 's/://g' | cut -f1 -d'@' || true)
        master_ip=$(ip -4 addr show "$master_if" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1 || true)
    fi
    if [[ -z "$master_ip" ]]; then die "Could not detect master IP"; fi
    log "Master IP: $master_ip"

    # AELDEV-70735: ensure /opt/aelladata/work/da_conf.yml has the 4 fields
    # downstream scripts (config_master.sh, MON/install.sh, node_configure.py,
    # aellad) require: aella_role / cluster_name / cluster_size / master_ip.
    # On a customer upgrade da_conf.yml is preserved from the prior install
    # and already has them. On a FRESH bringup (or a destructive py2->py3
    # transition where /opt/aelladata/work was clobbered) it's empty, so
    # MON/install.sh reads aella_role=empty and skips the entire monitoring
    # stack install: `monitoring` namespace stays empty, prometheus / grafana
    # / alertmanager / *-exporter pods never deploy. Seed any missing field
    # so the chain works. Preserves any existing value (cluster-controller
    # may have already written them); only fills gaps.
    mkdir -p /opt/aelladata/work
    touch "$DA_CONF"
    seed_da_conf_field() {
        local key="$1" val="$2"
        if ! grep -q "^${key}:" "$DA_CONF" 2>/dev/null; then
            echo "${key}: ${val}" >> "$DA_CONF"
            log "  da_conf.yml: ${key}: ${val} (seeded)"
        fi
    }
    local cluster_size="1"
    [[ "$ROLE" == *master* || "$ROLE" == *worker* ]] && cluster_size="3"
    seed_da_conf_field aella_role   "$ROLE"
    seed_da_conf_field cluster_name "$ROLE"
    seed_da_conf_field cluster_size "$cluster_size"

    # AELDEV-70735 Fix #17: for AIO/master roles, master_ip MUST be the LOCAL ip,
    # not whatever was preserved from a prior usage. Stale master_ip pointing to
    # a different DP (seen on .11 with master_ip=10.39.200.7 left over from a
    # prior cluster role) causes hostPath-mounted containers like spark-slave's
    # meta-sync to download from the wrong host and CrashLoop indefinitely.
    # TWO files hold this IP and BOTH must be updated:
    #   - /opt/aelladata/work/da_conf.yml         key: master_ip
    #   - /opt/aelladata/work/host_info/host_info.yml  key: cm_address
    # da_conf.yml is read by aellad / bringup / kubeadm-init; host_info.yml is
    # read by per-pod sidecars (spark-slave's meta-sync uses CM_IP_FILE) and is
    # NOT regenerated by aellad on a re-bringup. The other 3 da_conf.yml fields
    # above are additive (preserve customer values), but master_ip / cm_address
    # are unambiguous on AIO/masters -- they ARE the master. For worker roles,
    # master_ip must point to the master and is supplied externally, so keep
    # seed-only behavior there.
    if [[ "$ROLE" == "AIO" || "$ROLE" == *master* ]]; then
        # da_conf.yml master_ip
        if grep -q "^master_ip:" "$DA_CONF" 2>/dev/null; then
            local existing_ip
            existing_ip=$(grep '^master_ip:' "$DA_CONF" | awk -F': ' '{print $2}' | tr -d "' \"")
            if [[ "$existing_ip" != "$master_ip" ]]; then
                sed -i "s|^master_ip:.*|master_ip: $master_ip|" "$DA_CONF"
                log "  da_conf.yml: master_ip: $master_ip (overwrote stale '$existing_ip')"
            fi
        else
            echo "master_ip: $master_ip" >> "$DA_CONF"
            log "  da_conf.yml: master_ip: $master_ip (seeded)"
        fi

        # host_info.yml cm_address (read by spark-slave meta-sync sidecar via
        # CM_IP_FILE=/work/host_info/host_info.yml -> get_metarepo_url(), AND by
        # dl_liveness_checker via aella_util.get_cm_ip()).
        #
        # AELDEV-71573 fix #17b: cm_address is the Cluster Manager IP, which is
        # always the DL-master's IP -- NOT the local node's IP. Previously this
        # block overwrote cm_address with $master_ip on ALL master roles, which
        # is CORRECT for DL-master/AIO (cm_address == self) but WRONG for
        # DR-master (cm_address should point to the DL-master across the wire).
        # Setting cm_address to DR-master's own IP causes dl_liveness_checker to
        # probe DA's own aellad endpoint (which has no ES) -> "Elasticsearch not
        # responding" -> Lockdown DA -> receiver/web/log-collector all disabled
        # -> entire data ingest pipeline goes down silently.
        local host_info=/opt/aelladata/work/host_info/host_info.yml
        mkdir -p /opt/aelladata/work/host_info
        if [[ "$ROLE" == "AIO" || "$ROLE" == "DL-master" ]]; then
            # DL-master / AIO: cm_address IS the local IP (DLm runs the CM).
            if [[ -f "$host_info" ]] && grep -q "^cm_address:" "$host_info" 2>/dev/null; then
                local existing_cm
                existing_cm=$(grep '^cm_address:' "$host_info" | awk -F': ' '{print $2}' | tr -d "' \"")
                if [[ "$existing_cm" != "$master_ip" ]]; then
                    sed -i "s|^cm_address:.*|cm_address: $master_ip|" "$host_info"
                    log "  host_info.yml: cm_address: $master_ip (overwrote stale '$existing_cm')"
                fi
            else
                echo "cm_address: $master_ip" >> "$host_info"
                log "  host_info.yml: cm_address: $master_ip (seeded)"
            fi
        else
            # DR-master: cm_address should be the DL-master's IP, NOT the local
            # DA-master's IP. Preserve existing value if set (operator/CM-UI
            # provides it during DA-side registration with DL). If it ACCIDENTALLY
            # equals $master_ip (this DR-master's own IP), warn loudly because
            # that breaks dl_liveness_checker.
            if [[ -f "$host_info" ]] && grep -q "^cm_address:" "$host_info" 2>/dev/null; then
                local existing_cm
                existing_cm=$(grep '^cm_address:' "$host_info" | awk -F': ' '{print $2}' | tr -d "' \"")
                if [[ "$existing_cm" == "$master_ip" ]]; then
                    log "  WARNING: host_info.yml cm_address ($existing_cm) equals THIS DR-master's IP."
                    log "  WARNING: cm_address must point to the DL-master IP, not the DA-master itself."
                    log "  WARNING: dl_liveness_checker will probe local aellad (no ES) -> Lockdown DA"
                    log "  WARNING: -> receiver disabled, entire data ingest pipeline broken."
                    log "  WARNING: After bringup completes, operator must set cm_address to the DL-master IP:"
                    log "  WARNING:   sudo sed -i 's|^cm_address:.*|cm_address: <DLm-cluster-iface-IP>|' $host_info"
                    log "  WARNING:   sudo systemctl restart aellad"
                else
                    log "  host_info.yml: cm_address: $existing_cm (preserved -- DR-master keeps DLm IP)"
                fi
            else
                log "  WARNING: host_info.yml has no cm_address on DR-master. Operator must seed it"
                log "  WARNING: with the DL-master IP after bringup, then 'systemctl restart aellad'."
            fi
        fi
    else
        seed_da_conf_field master_ip "$master_ip"
    fi

    # Load kubeadm custom env if exists
    local pod_network_cidr="${POD_NETWORK_CIDR:-}"
    if [[ -f /opt/aelladata/work/cluster-manager/kubeadm-custom.env ]]; then
        source /opt/aelladata/work/cluster-manager/kubeadm-custom.env
        pod_network_cidr="${POD_NETWORK_CIDR:-}"
    fi

    # Py3 UVP (>= 6.5.0) uses v1beta3 kubeadm config (kubeadm-init.u2404.yml.j2)
    local flannel_template="kube-flannel.u2404.yml.j2"
    local kubeadm_template="kubeadm-init.u2404.yml.j2"

    # Render flannel config (kube-flannel namespace)
    local flannel_config="/opt/aelladata/kubernetes/kube-flannel.yml"
    log "Rendering flannel config (kube-flannel namespace)..."
    python3 /opt/aelladata/kubernetes/scripts/render_kubeadm_config.py \
        "$flannel_template" "$flannel_config" \
        --pod-network-cidr "${pod_network_cidr}" --iface "${cluster_if}" || \
        die "Failed to render flannel config"

    # Render kubeadm config (v1beta3 with maxPods: 250, resolvConf: /etc/resolv-kube.conf)
    local kube_version
    kube_version=$(dpkg -s kubelet 2>/dev/null | grep Version | grep -oP "\d+\.\d+\.\d+" || true)
    if [[ -z "$kube_version" ]]; then
        kube_version=$(kubelet --version 2>/dev/null | grep -oP "\d+\.\d+\.\d+" || true)
    fi
    if [[ -z "$kube_version" ]]; then
        kube_version="1.31.10"
        log "WARNING: Could not detect K8s version, defaulting to $kube_version"
    fi
    local kubeadm_config="/opt/aelladata/kubernetes/kubeadm-init.yml"
    log "Rendering kubeadm config (K8s v${kube_version}, v1beta3)..."
    python3 /opt/aelladata/kubernetes/scripts/render_kubeadm_config.py \
        "$kubeadm_template" "$kubeadm_config" \
        --apiserver-advertise-address "$master_ip" \
        --kubernetes-version "v${kube_version}" \
        --pod-network-cidr "${pod_network_cidr}" || \
        die "Failed to render kubeadm config"

    # Skip kubeadm init if K8s API is reachable and this node exists in the cluster
    # (idempotent re-run). This avoids re-creating the control plane on every
    # --worker-ips re-run (which wipes all pods and requires workers to rejoin).
    # Check API reachable + node exists (regardless of Ready/NotReady -- a NotReady
    # node just needs flannel or containerd restart, not a full kubeadm re-init).
    if KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes &>/dev/null; then
        local node_count
        node_count=$(KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes --no-headers 2>/dev/null | wc -l)
        if [[ "$node_count" -gt 0 ]]; then
            log "K8s cluster already exists ($node_count node(s)), skipping kubeadm init"
            export KUBECONFIG=/etc/kubernetes/admin.conf
            return 0
        fi
    fi

    # Pre-pull K8s system images via crictl (NOT docker pull -- containerd is the runtime)
    # Done before stopping kubelet since image pull can take minutes
    # and doesn't need port 10250.
    # AELDEV-70680 #12: dark-site protection. crictl pull always contacts
    # the registry. On an air-gapped DP whose OVA pre-loaded these images
    # into containerd, every pull would WARN for ~30s = ~3.5 min of noise.
    # Check the local cache first; only crictl pull if missing. Same
    # pattern as #11 for flannel.
    systemctl daemon-reload
    log "Pulling K8s system images via crictl (with local-cache short-circuit)..."
    # AELDEV-70735: pull the actual list from kubeadm so etcd/coredns versions
    # track K8s minor versions automatically (kubeadm 1.31.10 wants
    # etcd:3.5.15-0, NOT 3.5.16-0 -- hardcoding drifts and triggers spurious
    # network pulls under --skip-download).
    local k8s_images=()
    if command -v kubeadm >/dev/null 2>&1; then
        mapfile -t k8s_images < <(kubeadm config images list --kubernetes-version "v${kube_version}" 2>/dev/null)
    fi
    if [[ ${#k8s_images[@]} -eq 0 ]]; then
        log "WARNING: kubeadm config images list returned empty; using static fallback"
        k8s_images=(
            "registry.k8s.io/kube-apiserver:v${kube_version}"
            "registry.k8s.io/kube-controller-manager:v${kube_version}"
            "registry.k8s.io/kube-scheduler:v${kube_version}"
            "registry.k8s.io/kube-proxy:v${kube_version}"
            "registry.k8s.io/coredns/coredns:v1.11.3"
            "registry.k8s.io/pause:3.10"
        )
    fi
    # AELDEV-70735: cache check uses `ctr` not `crictl`. The CRI plugin's
    # ImageStore lazily refreshes after ctr-import (especially for OCI multi-
    # arch indexes like flannel), so a cache check via crictl right after
    # Phase 3.5 can race-miss and trigger spurious crictl-pull attempts. ctr
    # reads metadata directly = always current.
    local cached_imgs
    cached_imgs=$(ctr -n=k8s.io images ls 2>/dev/null | awk 'NR>1 {print $1}')
    for img in "${k8s_images[@]}"; do
        if grep -qFx "$img" <<<"$cached_imgs"; then
            log "  $img (local cache, no pull)"
        else
            crictl pull "$img" 2>&1 || log "WARNING: Failed to pull $img"
        fi
    done
    log "K8s images ready"

    # AELDEV-70261: pull flannel + flannel-cni-plugin with mirror-first
    # fallback. AELDEV-58259 (Jun 2025) made the kube-flannel.u2404.yml.j2
    # template reference ghcr.io/flannel-io/* which is unreachable from
    # restricted-network and dark-site customers.
    #
    # AELDEV-70680 #10: original mirror was docker.io/aelladata/flannel which
    # got pushed to a private repo nobody can read (build-pipeline creds
    # only). Online customer DPs hit "pull access denied" -> 5x15s retries
    # per image of pure noise before fallback to ghcr.io kicked in. Switch
    # to docker.io/stellardev/* which is public-by-default (matches the
    # existing stellardev/kube-proxy, stellardev/coredns, etc. mirror
    # repos). Re-pushed manually 2026-05-07.
    #
    # AELDEV-70680 #11: dark-site protection. crictl pull ALWAYS contacts
    # the registry -- it does not consult the local containerd image cache
    # first. So an air-gapped DP that has the image loaded from the OVA
    # bundle would still hit "pull failed -> manual pre-load needed" from
    # the network. Check the local cache FIRST and skip the network call
    # entirely if the image is already present under either tag.
    pull_flannel_with_fallback() {
        local short="$1"   # e.g. flannel:v0.27.0
        local mirror="docker.io/stellardev/${short}"
        local upstream="ghcr.io/flannel-io/${short}"
        local registry attempt other ref alt

        # Dark-site safety: use whatever's already in the local cache.
        # AELDEV-70735: read from ctr (source of truth) not crictl -- crictl's
        # ImageStore lazily refreshes after ctr-import and can race-miss for
        # OCI multi-arch index types (flannel uses oci.image.index.v1+json).
        local cached_refs
        cached_refs=$(ctr -n=k8s.io images ls 2>/dev/null | awk 'NR>1 {print $1}')
        for ref in "$mirror" "$upstream"; do
            if grep -qFx "${ref}" <<<"$cached_refs"; then
                log "  using local cache: ${ref} (no network pull)"
                # Tag under both names so kubelet finds it regardless of
                # which name the kube-flannel manifest references.
                for alt in "$mirror" "$upstream"; do
                    [[ "$alt" == "$ref" ]] && continue
                    ctr -n k8s.io images tag --force "$ref" "$alt" 2>/dev/null || true
                done
                return 0
            fi
        done

        # Online path: mirror first, ghcr.io fallback.
        for registry in "$mirror" "$upstream"; do
            for ((attempt=1; attempt<=5; attempt++)); do
                if timeout 600 crictl pull "$registry"; then
                    [[ "$registry" == "$mirror" ]] && other="$upstream" || other="$mirror"
                    ctr -n k8s.io images tag --force "$registry" "$other" 2>/dev/null || true
                    log "  flannel pulled from $registry (attempt $attempt)"
                    return 0
                fi
                log "  pull from $registry failed (attempt $attempt/5), retrying in 15s..."
                sleep 15
            done
        done

        # AELDEV-70735: last-chance cache verification. All registry pulls
        # failed; if the image actually does exist in the local cache under
        # an unexpected ref (e.g. aelladata/flannel, or any private mirror
        # the customer used), alias it to both expected refs and succeed.
        # Only bail (return 1) if the cache truly has no flannel image,
        # since kubelet would then fail to pull during daemonset deploy.
        local final_ref
        final_ref=$(ctr -n=k8s.io images ls 2>/dev/null | awk 'NR>1 {print $1}' | grep -F "/${short}" | head -1)
        if [[ -n "$final_ref" ]]; then
            log "  pulls failed but found in cache: ${final_ref} -- aliasing to expected refs"
            for alt in "$mirror" "$upstream"; do
                [[ "$alt" == "$final_ref" ]] && continue
                ctr -n k8s.io images tag --force "$final_ref" "$alt" 2>/dev/null || true
            done
            return 0
        fi
        log "  ERROR: ${short} not in containerd k8s.io and all registry pulls failed -- kubelet daemonset deploy will fail; bailing"
        return 1
    }
    log "Pulling flannel images (local-cache check, then mirror-first, ghcr.io fallback)..."
    # AELDEV-70735: don't bail the script if a flannel pull fails. kubelet
    # retries during daemonset deploy and can find the image in containerd's
    # k8s.io namespace if it's there. set -euo means the function's `return 1`
    # otherwise terminates the whole bringup before kubeadm init runs.
    pull_flannel_with_fallback "flannel:v0.27.0"             || true
    pull_flannel_with_fallback "flannel-cni-plugin:v1.7.1-flannel1" || true

    # Stop kubelet RIGHT BEFORE kubeadm init -- not earlier, because:
    # 1. Image pull above can take minutes
    # 2. Aella services (Phase 8) may restart kubelet if it's stopped too early
    # 3. kubeadm init manages kubelet startup itself
    # 4. kubelet holds port 10250 which fails kubeadm preflight
    # Helper: ensure port 10250 is free before kubeadm init/retry
    ensure_port_10250_free() {
        systemctl stop kubelet 2>/dev/null || true
        sleep 2
        if ss -tlnp | grep -q ':10250 '; then
            log "WARNING: Port 10250 still in use, killing process..."
            fuser -k 10250/tcp 2>/dev/null || true
            sleep 1
        fi
    }

    # Helper: kill orphan static-pod containers + processes from a prior
    # failed bringup so kubeadm init preflight passes. A previous run may
    # have started kubelet -> containerd -> static pods (apiserver/etcd/
    # scheduler/controller-manager) before failing later. Stopping kubelet
    # alone doesn't reap them: the containers stay running under containerd
    # and keep their listening sockets (6443/2379/2380/10257/10259), which
    # makes the next kubeadm init preflight bail with "Port X in use".
    # kubeadm reset doesn't always clean them either (relies on kubelet to
    # send shutdown signals). So nuke them directly.
    cleanup_orphan_static_pods() {
        # Remove all containers from k8s.io namespace (where kubelet/CRI
        # parks static pods + their pause containers). -f forces stop+rm.
        crictl rm -fa 2>/dev/null || true
        # Belt-and-suspenders: kill any bare control-plane processes that
        # somehow survived (e.g. a stale binary started outside containerd).
        pkill -9 -f kube-apiserver         2>/dev/null || true
        pkill -9 -f kube-controller-manager 2>/dev/null || true
        pkill -9 -f kube-scheduler         2>/dev/null || true
        pkill -9 -f 'etcd '                2>/dev/null || true
        # Give kernel a beat to release the listening sockets.
        sleep 2
    }

    # AELDEV-70735: drop stale KUBE-* iptables chains left by the prior
    # K8s install (py2 K8s 1.19 kube-proxy, or any earlier kubeadm cycle).
    # After multiple kubeadm init/reset rounds, iptables-nft chains end up
    # in a "Device or resource busy" state -- the new kube-proxy 1.31 can't
    # CHAIN_DEL them, Sync-loops fail every 30s, Service ClusterIPs never
    # get rules, and pod-to-pod-via-Service traffic times out (e.g.
    # stellar-css -> aella-mongodb:27017 i/o timeout even though the
    # mongo pod IP is reachable directly). Surgically drop only KUBE-*
    # chains -- preserves dark-site firewall OUTPUT rules and other
    # user-managed chains in the same tables.
    cleanup_stale_kube_iptables() {
        # NOTE: each `... | grep ... | awk ... | while read ...; done` pipeline
        # below MUST be followed by `|| true`. Under `set -euo pipefail`, when
        # iptables has no KUBE-* chains (fresh DP, or iptables was just flushed),
        # `grep -oE ...` returns rc=1 -> pipefail propagates -> set -e kills the
        # whole bringup BEFORE kubeadm init runs, with no error logged. Bug seen
        # on .9 after manual iptables flush in pre-bringup wipe. Customer DPs
        # upgrading from py2 are unaffected (KUBE-* chains exist from K8s 1.19),
        # but fresh customer DPs (no prior K8s) would hit this.
        local tbl
        for tbl in filter nat mangle; do
            iptables -t "$tbl" -S 2>/dev/null | grep -oE '\-N KUBE-[A-Z0-9-]+' | awk '{print $2}' | while read -r chain; do
                iptables -t "$tbl" -F "$chain" 2>/dev/null || true
            done || true
            iptables -t "$tbl" -S 2>/dev/null | grep -oE '\-N KUBE-[A-Z0-9-]+' | awk '{print $2}' | while read -r chain; do
                iptables -t "$tbl" -X "$chain" 2>/dev/null || true
            done || true
        done
        # ip6tables KUBE-* chains too (kube-proxy creates parallel IPv6 chains)
        for tbl in filter nat mangle; do
            ip6tables -t "$tbl" -S 2>/dev/null | grep -oE '\-N KUBE-[A-Z0-9-]+' | awk '{print $2}' | while read -r chain; do
                ip6tables -t "$tbl" -F "$chain" 2>/dev/null || true
                ip6tables -t "$tbl" -X "$chain" 2>/dev/null || true
            done || true
        done
    }

    log "Stopping kubelet before kubeadm init..."
    ensure_port_10250_free
    cleanup_orphan_static_pods
    cleanup_stale_kube_iptables

    # kubeadm init with retry -- first attempt may fail due to timing/state issues
    log "Running kubeadm init..."
    if ! kubeadm init --config "$kubeadm_config" 2>&1; then
        log "WARNING: kubeadm init failed on first attempt, retrying after reset..."
        kubeadm reset -f 2>/dev/null || true
        flush_stale_kube_iptables
        rm -rf /etc/kubernetes/manifests/*.yaml 2>/dev/null || true
        rm -rf /var/lib/etcd/ 2>/dev/null || true
        ensure_port_10250_free
        cleanup_orphan_static_pods
        cleanup_stale_kube_iptables
        sleep 5
        log "Retrying kubeadm init..."
        kubeadm init --config "$kubeadm_config" || die "kubeadm init failed after retry"
    fi

    # Deploy CoreDNS
    log "Deploying CoreDNS..."
    kubeadm init phase addon coredns 2>/dev/null || true

    # Setup kubeconfig
    ln -fs /etc/kubernetes/admin.conf "$HOME/admin.conf"
    mkdir -p "$HOME/.kube"
    ln -fs /etc/kubernetes/admin.conf "$HOME/.kube/config"
    export KUBECONFIG="$HOME/admin.conf"
    grep -q "KUBECONFIG=/etc/kubernetes/admin.conf" ~/.bashrc 2>/dev/null || \
        echo "export KUBECONFIG=/etc/kubernetes/admin.conf" >> ~/.bashrc

    # Also setup for aella user
    if id aella &>/dev/null; then
        mkdir -p /home/aella/.kube
        cp /etc/kubernetes/admin.conf /home/aella/.kube/config
        chown -R aella: /home/aella/.kube
    fi

    # Wait for API server
    log "Waiting for API server..."
    sleep 15
    local wait_attempts=0
    while [[ "$(kubectl get nodes 2>/dev/null)" == "" ]]; do
        ((wait_attempts++)) || true
        if [[ $wait_attempts -ge 24 ]]; then die "API server not available after 120 seconds"; fi
        sleep 5
    done
    log "API server ready"

    # Deploy flannel (kube-flannel namespace)
    log "Deploying flannel (kube-flannel namespace)..."
    kubectl apply -f "$flannel_config"

    # Deploy RBAC
    kubectl apply -f /opt/aelladata/kubernetes/stellar-k8s-admin.yml 2>/dev/null || true

    # NO heapster/influxdb (py3 doesn't use these)

    # Wait for flannel
    log "Waiting for flannel..."
    local flannel_attempts=0
    while [[ ! -f /run/flannel/subnet.env ]] || ! ip link show flannel.1 &>/dev/null; do
        ((flannel_attempts++)) || true
        if [[ $flannel_attempts -ge 80 ]]; then log "WARNING: Flannel not ready after 400s"; break; fi
        sleep 5
    done
    log "Flannel ready"

    # Remove master taints (allow pods on master)
    kubectl taint nodes --all node-role.kubernetes.io/master- 2>/dev/null || true
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

    # AELDEV-70735: apply aella role labels so pod nodeAffinity matches.
    # Aella pods use `nodeAffinity: master=enabled` (and `dl=enabled` / `da=enabled`
    # for role-specific pods). On a stable cluster cluster-controller writes
    # /opt/aelladata/work/cluster-controller/service_scheduling.yml which the
    # update_service_scheduling.py script consumes to label nodes -- but on a
    # FRESH bringup that file doesn't exist yet (cluster-controller hasn't
    # produced it), so the labels never get applied and dozens of pods sit
    # Pending with "didn't match node selector". Apply them explicitly here.
    local node_name
    node_name=$(hostname)
    case "$ROLE" in
        AIO)
            kubectl label node "$node_name" master=enabled dl=enabled da=enabled --overwrite 2>/dev/null || \
                log "WARNING: failed to apply AIO node labels"
            log "Node labels: master=enabled dl=enabled da=enabled (AIO)"
            ;;
        DL-master)
            kubectl label node "$node_name" master=enabled dl=enabled --overwrite 2>/dev/null || \
                log "WARNING: failed to apply DL-master node labels"
            log "Node labels: master=enabled dl=enabled (DL-master)"
            ;;
        DR-master)
            kubectl label node "$node_name" master=enabled da=enabled --overwrite 2>/dev/null || \
                log "WARNING: failed to apply DR-master node labels"
            log "Node labels: master=enabled da=enabled (DR-master)"
            ;;
    esac

    # Apply stellar-docker-secrets.yml
    if [[ -f /opt/aelladata/kubernetes/stellar-docker-secrets.yml ]]; then
        log "Applying stellar-docker-secrets.yml..."
        kubectl apply -f /opt/aelladata/kubernetes/stellar-docker-secrets.yml 2>/dev/null || true
    fi

    # Patch default SA with imagePullSecrets
    log "Patching default service account with imagePullSecrets..."
    kubectl patch serviceaccount default -p '{"imagePullSecrets":[{"name":"stellar-docker"}]}' 2>/dev/null || \
        log "WARNING: Failed to patch default SA with imagePullSecrets"

    # Apply fluent-operator CRDs
    if [[ -f /opt/aelladata/kubernetes/fluent-crds.yml ]]; then
        log "Applying fluent-operator CRDs..."
        kubectl apply -f /opt/aelladata/kubernetes/fluent-crds.yml 2>/dev/null || true
    fi

    # Install monitoring stack
    if [[ -f /opt/aelladata/kubernetes/services/templates/MON/scripts/install.sh ]]; then
        log "Installing monitoring stack..."
        bash /opt/aelladata/kubernetes/services/templates/MON/scripts/install.sh 2>/dev/null || true
    fi

    # Azure/cloud vendor config
    python3 /opt/aelladata/kubernetes/scripts/update_azure.py 2>/dev/null || true

    # Update CoreDNS config
    log "Updating CoreDNS config..."
    python3 /opt/aelladata/kubernetes/scripts/update_dns.py 2>/dev/null || true

    # Update common config
    log "Updating common config..."
    python3 /opt/aelladata/kubernetes/scripts/update_common_config.py 2>/dev/null || true

    # AELDEV-74638: verify the rendered fflag secret is usable. An empty
    # FFLAG_PROJECT_KEY (stale pre-6.5.0 /opt/aelladata/work/fflag_settings.yml
    # preserved across the OS upgrade) crashes stellar-cluster-controller,
    # which blocks aella-cm-master init and stellar-report pods.
    local ff_project_key
    ff_project_key=$(kubectl get secret common-config-ff \
        -o jsonpath='{.data.FFLAG_PROJECT_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [[ -z "$ff_project_key" ]]; then
        log "  WARN: common-config-ff secret has an empty FFLAG_PROJECT_KEY"
        log "        (likely a stale ff: section in /opt/aelladata/work/fflag_settings.yml)."
        log "        stellar-cluster-controller / aella-cm-master / stellar-report pods will crash."
        log "        Fix the ff: values in that file (FFLAG_PROJECT_KEY: openxdr; and if"
        log "        FFLAG_SDK_KEY is empty set FFLAG_OFFLINE: \"true\"), then re-run:"
        log "        python3 /opt/aelladata/kubernetes/scripts/update_common_config.py"
    else
        log "  common-config-ff secret OK (FFLAG_PROJECT_KEY=${ff_project_key})"
    fi

    # Apply service-scheduling labels
    if [[ -f /opt/aelladata/work/cluster-controller/service_scheduling.yml ]]; then
        python3 /opt/aelladata/kubernetes/scripts/update_service_scheduling.py 2>/dev/null || true
    fi

    # AELDEV-69987: install helm charts explicitly. Previously this was delegated
    # to node_configure.py which silently failed on some clusters (stderr was
    # dropped to /dev/null; error reported as a non-fatal WARNING). Result:
    # fluent-operator + webhook-ingest-fluentd never got installed -> web-pod's
    # nginx couldn't resolve webhook-ingest-fluentd:8080 -> CrashLoopBackOff.
    # Install directly (mirrors main_upgrade_py2_dp_to_py3_dp.sh:2309,2319) so a
    # node_configure.py failure doesn't leave the cluster half-configured.
    local role_dir=""
    case "$ROLE" in
        DR-master) role_dir="DR" ;;
        DL-master) role_dir="DL" ;;
        AIO)       role_dir="AIO" ;;
    esac
    local HELM_CHARTS_DIR="/opt/aelladata/kubernetes/helm-charts/${role_dir}"

    # AELDEV-70735: UVP currently ships only helm-charts/DR -- AIO and DL
    # dirs are not packaged. Without a fallback, AIO bringup skips ALL helm
    # installs (fluent-operator, webhook-ingest, monitoring stack), leaving
    # the monitoring namespace empty and ServiceMonitor apply failing with
    # "no matches for kind". Fall back to DR which has the common charts.
    # Verified on .9: helm-charts/ contains only DR/ subdir.
    if [[ -n "$role_dir" && ! -d "$HELM_CHARTS_DIR" ]] && [[ -d "/opt/aelladata/kubernetes/helm-charts/DR" ]]; then
        # AELDEV-71573: this is INTENTIONAL -- UVP packages only helm-charts/DR
        # since the common charts (fluent-operator + webhook-ingest-fluentd)
        # are role-agnostic. Demoted to info to stop scaring operators in
        # log reviews; the fallback is the expected path on AIO + DL roles.
        log "helm-charts/${role_dir} not packaged in UVP, using helm-charts/DR (common charts apply to all roles)"
        HELM_CHARTS_DIR="/opt/aelladata/kubernetes/helm-charts/DR"
    fi

    if [[ -n "$role_dir" && -d "$HELM_CHARTS_DIR" ]]; then
        for chart in fluent-operator webhook-ingest-fluentd; do
            if [[ -d "$HELM_CHARTS_DIR/$chart" ]]; then
                log "Installing helm chart: $chart"
                helm upgrade --install "$chart" "$HELM_CHARTS_DIR/$chart" \
                    --namespace default --create-namespace \
                    --wait --timeout 5m 2>&1 | tee -a "$LOG_FILE" || \
                    log "WARNING: helm install $chart had errors (non-fatal)"
            else
                log "Helm chart $chart not found under $HELM_CHARTS_DIR, skipping"
            fi
        done
    else
        log "WARNING: helm-charts dir for role $ROLE not found (expected $HELM_CHARTS_DIR)"
    fi

    # Run node_configure.py for remaining setup (labels, taints, etc.)
    # Timeout after 300s: node_configure.py can block indefinitely waiting for services
    # that aren't up yet during initial bringup. The helm-driven pieces are now
    # installed above so a node_configure.py failure no longer leaves the cluster
    # in a half-configured state. stderr now goes to the bringup log (tee -a)
    # instead of /dev/null so post-hoc debugging is possible.
    log "Running node_configure.py (max 300s)..."
    timeout 300 env PYTHONPATH=/opt/aelladata/python:/opt/aelladata/cms KUBECONFIG=/etc/kubernetes/admin.conf \
        python3 /opt/aelladata/python/cluster_manager/node_configure.py 2>&1 | tee -a "$LOG_FILE" || \
        log "WARNING: node_configure.py timed out or had errors (non-fatal, helm charts already installed)"

    # AELDEV-69987: write /work/VERSION YAML (authoritative for feature-flag
    # library). The dpkg postinst writes /work/version (lowercase, plain) but
    # the feature flag code in processor / web / etc. reads /work/VERSION
    # (uppercase, YAML) via KindEnvironment.getDpVersion(). If we don't write
    # this, pods think they're still running the pre-bringup version and take
    # the wrong code paths (e.g. processor uses old kafka consumer, expects a
    # kafka topic that no longer exists -> crash). Mirrors the behavior of
    # reset_factory_util.py which writes this during UI-driven factory reset.
    log "Writing /work/VERSION YAML for feature-flag library..."
    mkdir -p /opt/aelladata/work
    python3 -c "
import yaml, datetime
with open('/opt/aelladata/work/VERSION', 'w') as f:
    yaml.safe_dump({
        'DP': {
            'VERSION': '${VERSION}',
            'most_recent_upgrade': 'Bringup on ' + datetime.datetime.now(datetime.timezone.utc).strftime('%a %b %d %H:%M:%S UTC %Y'),
        }
    }, f, default_flow_style=False)
" && log "Wrote /work/VERSION = ${VERSION}" || log "WARNING: Failed to write /work/VERSION"

    log "K8s master initialization complete"
    kubectl get nodes
}

###############################################################################
# PHASE 10: DEPLOY K8S SERVICES (master/AIO only)
###############################################################################
deploy_k8s_services() {
    log_phase "Deploy K8s Services"

    export KUBECONFIG=/etc/kubernetes/admin.conf

    local cluster_mode=""
    case "$ROLE" in
        DR-master) cluster_mode="DR" ;;
        DL-master) cluster_mode="DL" ;;
        AIO)       cluster_mode="AIO" ;;
        *)         log "Skipping service deployment for role: $ROLE"; return 0 ;;
    esac

    log "Deploying services in $cluster_mode mode..."

    # Use kube-deploy.sh if available
    if [[ -x /usr/bin/kube-deploy ]] || [[ -x /opt/aelladata/kubernetes/scripts/kube-deploy.sh ]]; then
        local kube_deploy
        kube_deploy=$(command -v kube-deploy 2>/dev/null || echo "/opt/aelladata/kubernetes/scripts/kube-deploy.sh")
        bash "$kube_deploy" -m "$cluster_mode" up 2>&1 || \
            log "WARNING: kube-deploy had errors (pods may still be starting)"
    else
        log "WARNING: kube-deploy.sh not found. Pods not deployed."
        log "  You may need to run: kube-deploy -m $cluster_mode up"
    fi

    # Pull Docker images using release-image.yml (aellad normally handles this).
    # AELDEV-70735: in --skip-download (dark-site) mode, scan the local cache
    # against release-image.yml so the customer/CS sees a concrete list of
    # which images are present/missing. Then skip pull_image because Docker
    # 29.x with default overlay2 snapshotter doesn't share content with
    # containerd's moby ns, AND the network is blocked anyway -- pull_image
    # would emit hundreds of network-blocked errors. Kubernetes pods are
    # unaffected since kubelet+CRI reads containerd k8s.io directly.
    local release_image="/opt/aelladata/release-image.yml"
    if [[ "$SKIP_DOWNLOAD" == "true" ]]; then
        if [[ -f "$release_image" ]]; then
            log "Verifying release-image.yml refs against local cache (dark-site)..."
            darksite_check_local_images "$release_image"
        fi
        log "Skipping pull_image (--skip-download): network blocked; cached images already served via kubelet+CRI."
    elif [[ -f "$release_image" ]] && command -v pull_image &>/dev/null; then
        log "Pulling Docker images from release-image.yml (background)..."
        nohup pull_image -f "$release_image" >> /var/log/aella/pull_image.log 2>&1 &
        log "  pull_image started (PID $!), check /var/log/aella/pull_image.log for progress"
    elif [[ -f "$release_image" ]]; then
        log "WARNING: pull_image not found -- Docker images may not load"
        log "  Run manually: pull_image -f $release_image"
    fi

    # Wait a moment then show pod status
    sleep 10
    log "Pod status:"
    kubectl get pods --all-namespaces 2>/dev/null | head -50 || true
    local running_count
    # AELDEV-70680: see line ~445 -- avoid `grep -c ... || echo 0` (double-print bug).
    running_count=$(kubectl get pods --all-namespaces 2>/dev/null | grep -c "Running" || true)
    running_count=${running_count:-0}
    log "Pods running: $running_count"

    # AELDEV-71573 fix #16: stabilize kafka bootstrap BEFORE bringup proceeds to
    # long phases (elasticdump install ~5-10 min, orchestrate_workers 60+ min).
    # Without this AT THIS POINT, the kafka ZK ephemeral race plays out during
    # those long phases and the DA pipeline (kafka/buffer/processor/receiver)
    # stays broken for the duration -- processor CrashLoopBackOff'd 30+ min
    # observed on QA darksite cluster. DR-master/AIO only; DL has no kafka.
    clean_stale_kafka_zk_ephemerals

    # Fix #16b: verify kafka actually reached Ready. Adds 10-min polling
    # budget on top of fix #16's 5-min loop. Logs a loud diagnostic block
    # if the DA pipeline base is still broken, but bringup continues so
    # workers can join and operator gets the full picture.
    wait_for_kafka_ready || true
}

###############################################################################
# AELDEV-71573 fix #21: Pre-label DL nodes with `elastic=enabled`
###############################################################################
# Breaks the cluster-controller scheduling deadlock that occurs on darksite
# py2->py3 destructive bringup with preserved /opt/aelladata/esdata.
#
# Deadlock chain (without this fix):
#   1. ES manifests deploy elasticsearch2-master (DaemonSet, needs elastic +
#      master labels) and elasticsearch2 (data DaemonSet, needs elastic, NotIn
#      master). Both stay DESIRED=0 because no node carries `elastic=enabled`.
#   2. stellar-cluster-controller's es.py:init_cluster is supposed to apply
#      `elastic=enabled` to eligible nodes -- but it gates on ES status=green
#      via eps_check.py before doing so.
#   3. ES status stays RED forever because the preserved /opt/aelladata/esdata
#      carries N unassigned primary shards from the prior py2 cluster, and the
#      master-only ES has zero data nodes to allocate them to.
#   4. Controller never labels -> data nodes never schedule -> ES never reaches
#      green -> red-state deadlock.
#
# Fix: pre-emptively apply `elastic=enabled` to eligible nodes on DL-master /
# AIO, mirroring node_configure.py:init_dl_labels() -- master is labeled only
# when this is a single-node cluster (AIO / workerless DL-master), so the
# multi-node ES topology stays identical to the prior cluster (ES2 data on
# workers only). The manifest's NodeAffinity rules then place the DaemonSets:
#   - AIO (1 node):   elasticsearch2-master lands on the AIO node
#                     (elastic+master both true; data DS skipped by NotIn).
#   - Multi-node DL:  elasticsearch2 (data) lands on each DL worker
#                     (elastic required, master forbidden). elasticsearch2-master
#                     stays DESIRED=0 -- DLm has master but not elastic.
#
# Safety: idempotent (--overwrite); DR-master/DR-worker skipped (no ES
# manifests). Fresh installs unaffected: controller labels eligible nodes
# anyway once healthy; this just breaks the preserved-data deadlock sooner.
#
# AELDEV-73583 refinement -- label ONLY nodes that hold preserved ES data:
# the deadlock this fix breaks is caused by PRESERVED shards, so preserved
# data is the correct eligibility signal (not RAM/labels). Per non-master
# node, probe /opt/aelladata/esdata|es-data-lvm over ssh (standard aella
# creds):
#   - preserved data found  -> label elastic=enabled (deadlock breaker)
#   - probe OK, no data     -> SKIP: node never held ES data. Covers ES
#     coordinate candidates (small nodes; es.py node_can_run_es requires
#     >=80% of max data-node storage) and any fresh/empty node. The
#     controller applies its own disk-rule labeling once ES is green.
#   - probe FAILS           -> label anyway (old behavior; a missed label
#     risks the red-state deadlock, a spurious one only mis-places a pod
#     the controller can correct).
# Standby nodes are NEVER labeled here (skipped via the master's preserved
# /opt/aelladata/work/standby/standby_config node list + the standby node
# label): standby ES participation is owned by standby_controller/es.py
# (data_sync-gated), not by provisioning.
# NO label REMOVALS here: removal stays controller/operator-owned.
pre_label_dl_elastic_nodes() {
    [[ "$ROLE" == "DL-master" || "$ROLE" == "AIO" ]] || return 0

    local k="kubectl --kubeconfig=/etc/kubernetes/admin.conf"
    local standby_conf="/opt/aelladata/work/standby/standby_config"
    local n labeled=0 skipped=0 node_count
    node_count=$($k get nodes --no-headers 2>/dev/null | wc -l)
    node_count=${node_count:-0}

    # Probe a node for preserved ES data over ssh (aella/aelladata, the
    # standard on-prem DP credentials -- same auth orchestrate_workers uses).
    # Prints HASDATA / NODATA / UNKNOWN.
    _esdata_probe() {
        local ip="$1" out=""
        if ! command -v sshpass &>/dev/null; then echo "UNKNOWN"; return; fi
        out=$(timeout 25 sshpass -p aelladata ssh \
                -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=10 -o PreferredAuthentications=password \
                "aella@${ip}" \
                "test -d /opt/aelladata/esdata/nodes -o -d /opt/aelladata/es-data-lvm/nodes && echo HASDATA || echo NODATA" \
                2>/dev/null | tail -1)
        case "$out" in HASDATA|NODATA) echo "$out" ;; *) echo "UNKNOWN" ;; esac
    }

    # Mirror node_configure.py:init_dl_labels() topology rule -- master only
    # gets `elastic=enabled` when this is a single-node cluster (AIO or
    # workerless DL-master). For multi-node, label workers only; otherwise we
    # would force elasticsearch2-master DaemonSet onto DLm and grow the ES
    # data-node count by one, which is a topology change vs the prior cluster.
    for n in $($k get nodes -o name 2>/dev/null | sed 's|node/||'); do
        local is_master is_standby node_ip verdict
        is_master=$($k get node "$n" -o jsonpath='{.metadata.labels.master}' 2>/dev/null)
        if [[ "$is_master" == "enabled" && "$node_count" -gt 1 ]]; then
            continue   # multi-node DL: leave master unlabeled, ES2 data lives on workers
        fi

        if [[ "$node_count" -gt 1 ]]; then
            # Skip standby nodes: preserved standby record on this master
            # (WARM_STANDBY_CONF_FILE "nodes" list) or an already-applied
            # standby label. Case-insensitive: record stores lowercase.
            is_standby=$($k get node "$n" -o jsonpath='{.metadata.labels.standby}' 2>/dev/null)
            if [[ "$is_standby" == "enabled" ]] || \
               { [[ -f "$standby_conf" ]] && grep -qiw "$n" "$standby_conf" 2>/dev/null; }; then
                log "  pre-label: $n is a standby node -- skipping (standby ES is controller-owned)"
                skipped=$((skipped + 1))
                continue
            fi

            node_ip=$($k get node "$n" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
            verdict=$([[ -n "$node_ip" ]] && _esdata_probe "$node_ip" || echo "UNKNOWN")
            if [[ "$verdict" == "NODATA" ]]; then
                log "  pre-label: $n has no preserved ES data -- skipping (controller labels eligible nodes once green; expected for ES coordinate candidates)"
                skipped=$((skipped + 1))
                continue
            fi
            [[ "$verdict" == "UNKNOWN" ]] && \
                log "  pre-label: $n esdata probe inconclusive -- labeling anyway (deadlock-safe default)"
        fi

        if $k label node "$n" elastic=enabled --overwrite >/dev/null 2>&1; then
            labeled=$((labeled + 1))
        fi
    done

    if (( labeled > 0 || skipped > 0 )); then
        log "Pre-labeled $labeled DL node(s) with elastic=enabled, skipped $skipped (standby/no-preserved-data)"
    fi
}

###############################################################################
# AELDEV-71573 fix #22: Clean stale kafka broker ephemerals in ZooKeeper
###############################################################################
# Prevents the kafka bootstrap restart loop on a fresh-bringup cluster.
#
# Symptom (no fix):
#   kafka-pod-0     Running   2 restarts (frozen)
#   stellar-buffer  Running   2 restarts (frozen)
#   processor-0     Running   10+ restarts (cascade from kafka instability,
#                                          DirectKafkaInputDStream channel-closed)
#
# Root cause: K8s container restart backoff (5s -> 10s -> 20s ...) starts shorter
# than ZooKeeper's client session timeout (18s for kafka 2.6.3). When a kafka
# pod crashes early -- e.g. a transient ZK connect blip during bootstrap -- the
# ephemeral znode /brokers/ids/<broker.id> stays in ZK owned by the dead session.
# The next kafka attempt opens a new session, tries to create the same path:
#
#   ERROR Error while creating ephemeral at /brokers/ids/1001, node already
#         exists and owner '72059382728294627' does not match current session
#         '72059382728294629' (kafka.zk.KafkaZkClient$CheckedEphemeral)
#   ERROR [KafkaServer id=1001] Fatal error during KafkaServer startup
#   ERROR Exiting Kafka.
#
# Loop continues until K8s backoff exceeds 18s -> ZK expires the old session
# -> kafka claims the path. Typical resolution: 60-120s window, 2-3 restarts.
# processor-0 cascades because Spark's DirectKafkaInputDStream loses its
# channel mid-stream and SparkException-exits the JVM.
#
# Fix: at the END of deploy_k8s_services (right after kube-deploy applies all
# manifests), wait for zookeeper-pod-0 to be Ready, then run a stabilization
# loop. Each iteration: check kafka Ready -> if Ready return, else clean stale
# /brokers/ids ephemerals via `rmr` (or `deleteall` on ZK 3.5.4+) and wait. Up
# to 5 minutes total so the entire DA pipeline (kafka/buffer/processor/receiver)
# converges before bringup proceeds to long phases (elasticdump install,
# orchestrate_workers). Without this AT THE RIGHT TIME, the race plays out for
# the full duration of the multi-worker bringup (60+ min) and processor stays
# in CrashLoopBackOff -- breaking the data pipeline.
#
# Gated: skip if kafka-pod-0 already Ready (idempotent re-run safety -- don't
# disturb a healthy broker). Each iteration locates zkCli.sh dynamically
# (path is version-tagged in the aella zookeeper image).
clean_stale_kafka_zk_ephemerals() {
    [[ "$ROLE" == "DR-master" || "$ROLE" == "AIO" ]] || return 0

    local k="kubectl --kubeconfig=/etc/kubernetes/admin.conf"

    # Wait up to 90s for zookeeper-pod-0 to be Running + Ready.
    local zk_pod="" i
    for i in $(seq 1 18); do
        zk_pod=$($k get pods -n default 2>/dev/null \
                 | awk '/^zookeeper-pod-0/ && $2=="1/1" && $3=="Running"{print $1; exit}')
        [[ -n "$zk_pod" ]] && break
        sleep 5
    done
    if [[ -z "$zk_pod" ]]; then
        log "zookeeper-pod-0 not Ready after 90s -- skipping kafka ZK ephemeral cleanup"
        return 0
    fi

    # Locate zkCli.sh once (absolute path; not on PATH in the aella zookeeper
    # image, baked-in dir is version-tagged like /app/zookeeper-3.4.12/bin/).
    # AELDEV-72012: timeout 10 bounds the kubectl exec hang window post-kubeadm-init.
    local zkbin
    zkbin=$(timeout 10 $k exec "$zk_pod" -- bash -c \
              'ls /app/zookeeper-*/bin/zkCli.sh 2>/dev/null | head -1' \
              2>/dev/null || echo "")
    if [[ -z "$zkbin" ]]; then
        # Fallback search; the `find /` part can take many seconds on a fresh
        # pod, so allow up to 30s here.
        zkbin=$(timeout 30 $k exec "$zk_pod" -- bash -c \
                  'command -v zkCli.sh 2>/dev/null || \
                   command -v zookeeper-shell 2>/dev/null || \
                   find / -maxdepth 6 -name zkCli.sh 2>/dev/null | head -1' \
                  2>/dev/null || echo "")
    fi
    if [[ -z "$zkbin" ]]; then
        log "zkCli.sh not found in zookeeper-pod-0; skipping ZK ephemeral cleanup"
        return 0
    fi
    log "kafka stabilization: zkbin=$zkbin in $zk_pod"

    # Stabilization loop: up to 5 minutes (10 iterations x 30s) to let kafka
    # claim broker.id cleanly. Each iteration: if kafka Ready -> done; else
    # rmr /brokers/ids so the next kafka restart claims a fresh ephemeral
    # (ZK 3.4.x uses `rmr`, 3.5.4+ uses `deleteall`; try both).
    local iter kafka_ready before after cleaned=0
    for iter in $(seq 1 10); do
        # AELDEV-72012: log iter entry BEFORE any kubectl call so a silent
        # exit inside the loop body still surfaces the failing iter in the
        # bringup log. Without this, the prior "kafka stabilization: zkbin=..."
        # was the last log line on the 2026-06-08 .32 DAm failure and the
        # operator had no signal of which kubectl call hung.
        log "kafka stabilization iter=$iter: checking kafka-pod-0 Ready"
        # AELDEV-72012: timeout 10 bounds apiserver-hang window in the first
        # ~30-90s post-kubeadm-init when apiserver/CRI can stall arbitrarily.
        # Existing 2>/dev/null still suppresses stderr; new `|| echo ""` is a
        # defensive fallback so `set -e` can never fire on transient rc=1.
        kafka_ready=$(timeout 10 $k get pod kafka-pod-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "")
        if [[ "$kafka_ready" == "true" ]]; then
            log "kafka stabilization: kafka-pod-0 Ready after $((iter - 1)) cleanup pass(es), $cleaned rmr issued"
            return 0
        fi

        # Snapshot /brokers/ids before cleanup so the log shows what was stuck.
        # AELDEV-72012: timeout 15 bounds zkCli.sh cold-start (~5-10s normally)
        # + ZK response. Applied to all three exec calls in the loop body.
        before=$(timeout 15 $k exec "$zk_pod" -- bash -c \
                  "$zkbin -server localhost:2181 ls /brokers/ids 2>&1 | tail -1" \
                  2>/dev/null || echo "")
        timeout 15 $k exec "$zk_pod" -- bash -c \
            "$zkbin -server localhost:2181 rmr /brokers/ids 2>/dev/null \
             || $zkbin -server localhost:2181 deleteall /brokers/ids 2>/dev/null" \
            >/dev/null 2>&1 || true
        after=$(timeout 15 $k exec "$zk_pod" -- bash -c \
                  "$zkbin -server localhost:2181 ls /brokers/ids 2>&1 | tail -1" \
                  2>/dev/null || echo "")
        cleaned=$((cleaned + 1))
        log "kafka stabilization iter=$iter: kafka not Ready, rmr /brokers/ids (before=$before -> after=$after)"
        sleep 30
    done

    log "kafka stabilization: 5 min elapsed, kafka-pod-0 not yet Ready (cleaned=$cleaned). Continuing -- wait_for_kafka_ready will verify"
}

###############################################################################
# AELDEV-71573 fix #16b: wait_for_kafka_ready
###############################################################################
# Runs after clean_stale_kafka_zk_ephemerals' 5-minute stabilization loop.
# Adds another 10-minute polling budget for kafka-pod-0 to reach Ready before
# bringup proceeds past deploy_k8s_services. Total kafka-stabilization budget
# = 15 min (5 from fix #16 + 10 here).
#
# The DA pipeline -- receiver -> kafka -> stellar-buffer -> processor -> ES --
# is the customer's primary data path. If kafka is not Ready, every downstream
# pod (processor, receivers, etc.) will either CrashLoopBackOff or fail to
# accept ingest. Better to surface this LOUDLY during bringup than to claim
# "Bringup complete" with a silently-broken pipeline.
#
# Returns 0 when kafka-pod-0 Ready; returns 1 (with a loud diagnostic block
# logged) if the 10-min budget elapses without recovery. The caller logs a
# warning and continues (operator review required) rather than die() -- the
# rest of bringup (elasticdump, validate, orchestrate_workers, wait_for_system
# _ready) still runs so the operator gets a complete picture, and so workers
# still join the cluster even if the DA-side data plane needs attention.
# To convert to hard-fail, replace the `log ... || true` at the call site
# with `|| die`.
wait_for_kafka_ready() {
    [[ "$ROLE" == "DR-master" || "$ROLE" == "AIO" ]] || return 0

    local k="kubectl --kubeconfig=/etc/kubernetes/admin.conf"
    local budget_iter=20   # 20 * 30s = 10 min
    local iter kafka_ready restart_count phase pod_status

    log "Waiting for kafka-pod-0 to be Ready (budget: 10 min, polling every 30s)..."
    for iter in $(seq 1 $budget_iter); do
        # AELDEV-72012: timeout 10 on all 4 kubectl gets to bound apiserver hangs.
        kafka_ready=$(timeout 10 $k get pod kafka-pod-0 \
                          -o jsonpath='{.status.containerStatuses[0].ready}' \
                          2>/dev/null || echo "")
        if [[ "$kafka_ready" == "true" ]]; then
            restart_count=$(timeout 10 $k get pod kafka-pod-0 \
                                -o jsonpath='{.status.containerStatuses[0].restartCount}' \
                                2>/dev/null || echo "")
            log "kafka-pod-0 Ready after $iter polls (~$((iter * 30))s, RestartCount=${restart_count:-0}). DA pipeline base is healthy."
            return 0
        fi
        restart_count=$(timeout 10 $k get pod kafka-pod-0 \
                            -o jsonpath='{.status.containerStatuses[0].restartCount}' \
                            2>/dev/null || echo "")
        pod_status=$(timeout 10 $k get pod kafka-pod-0 -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        log "  poll $iter/$budget_iter: kafka-pod-0 not Ready yet (phase=${pod_status:-Unknown}, RestartCount=${restart_count:-0})"
        sleep 30
    done

    # 10 min elapsed, kafka still not Ready. Emit a loud, actionable block.
    log ""
    log "=========================================================================="
    log "  CRITICAL: kafka-pod-0 NOT Ready after 15 minutes total"
    log "             (5 min in fix #16 stabilization + 10 min here)."
    log ""
    log "  DA data pipeline IS DOWN:"
    log "     receiver -> KAFKA(broken) -> stellar-buffer -> processor -> ES"
    log "  No sensor data can be ingested or processed until kafka is healthy."
    log ""
    log "  Diagnostic commands (run on this DAm):"
    log "    kubectl get pod kafka-pod-0 -o wide"
    log "    kubectl describe pod kafka-pod-0 | tail -40"
    log "    kubectl logs kafka-pod-0 --previous --tail=100 | tail -50"
    log "    kubectl exec zookeeper-pod-0 -- /app/zookeeper-*/bin/zkCli.sh \\"
    log "        -server localhost:2181 ls /brokers/ids"
    log ""
    log "  If /brokers/ids still has a stale ephemeral that fix #16's 5-min"
    log "  loop did not clear (e.g. ZK pod itself was restarting during the"
    log "  window), one-shot recovery:"
    log "    kubectl exec zookeeper-pod-0 -- /app/zookeeper-*/bin/zkCli.sh \\"
    log "        -server localhost:2181 rmr /brokers/ids"
    log "  followed by:"
    log "    kubectl delete pod kafka-pod-0"
    log ""
    log "  Bringup will CONTINUE so workers can still join and the DL side"
    log "  can stabilize, but the DA-side data plane needs operator review"
    log "  before this DP is production-ready."
    log "=========================================================================="
    log ""

    return 1
}

###############################################################################
# PHASE 11: INSTALL ELASTICDUMP
###############################################################################
install_elasticdump() {
    log_phase "Install elasticdump"

    if command -v elasticdump &>/dev/null; then
        log "elasticdump already installed"
        return 0
    fi

    # Install nodejs/npm if not available
    if ! command -v npm &>/dev/null; then
        log "Installing nodejs and npm..."
        apt-get update -qq 2>/dev/null || true
        apt-get install -qqy nodejs npm 2>/dev/null || {
            log "WARNING: Failed to install nodejs/npm from apt"
            return 0
        }
    fi

    # Try local tarball first (no internet required)
    if [[ -f "${STAGING_DIR}/elasticdump-6.76.0.tgz" ]]; then
        log "Installing elasticdump from local tarball..."
        if npm install -g "${STAGING_DIR}/elasticdump-6.76.0.tgz" 2>&1; then
            log "elasticdump installed from local tarball"
            return 0
        fi
        log "WARNING: Failed to install from local tarball, falling back to npm registry..."
    fi

    # Fallback: install from npm registry
    log "Installing elasticdump@6.76.0 from npm registry..."
    local attempt
    for attempt in 1 2 3; do
        if npm install elasticdump@6.76.0 -g --timeout=120000 2>&1; then
            log "elasticdump installed from npm registry"
            return 0
        fi
        if [[ $attempt -lt 3 ]]; then sleep 5; fi
    done
    log "WARNING: elasticdump installation failed after 3 attempts"
}

###############################################################################
# PHASE 11.5: INFORMATIONAL WAIT FOR aella_cli show status -> All pods running
###############################################################################
# AELDEV-70735: report DP ready-state from aellad's perspective so the
# bringup log captures the composite customer-facing signal (pods + images
# + CM certs + license + DGA models + indices + provision service + OTP).
#
# **Strictly informational**: never returns non-zero, never fails the
# bringup. Dark-site DPs typically converge in ~10-15 min (cache hits).
# Online DPs may take 45-60 min because aellad / kubelet pull images
# over the network. Customer or CS can keep checking after bringup_py3
# exits; this function just gives an early-success signal when possible.
wait_for_system_ready() {
    [[ "$WORKER_MODE" == "true" ]] && return 0
    case "${ROLE:-}" in
        DR-master|DL-master|AIO) ;;
        *) return 0 ;;
    esac

    local aella_cli
    aella_cli=$(command -v aella_cli 2>/dev/null || ls /usr/bin/aella_cli /usr/local/bin/aella_cli 2>/dev/null | head -1)
    if [[ -z "$aella_cli" ]]; then
        log "INFO: aella_cli not found; skip-poll, check manually after bringup exits"
        return 0
    fi

    # Budget scales with mode: dark-site converges fast (~10-15 min) since
    # all images are already cached; online bringup can take 45-60 min as
    # kubelet/aellad pull from registries.
    local budget_sec
    if [[ "$SKIP_DOWNLOAD" == "true" ]]; then
        budget_sec=1200   # 20 min
    else
        budget_sec=3600   # 60 min
    fi
    local poll_interval=60

    log_phase "Wait for aella_cli show status -> All pods are running (informational, ${budget_sec}s budget)"
    log "  Mode: $([[ "$SKIP_DOWNLOAD" == "true" ]] && echo "dark-site (--skip-download)" || echo "online")"
    log "  This is informational only -- bringup will return 0 regardless."
    log "  Customer / CS can continue checking with: sudo $aella_cli  -> show status"

    local deadline=$(( $(date +%s) + budget_sec ))
    local out remaining pod_line
    while [[ $(date +%s) -lt $deadline ]]; do
        out=$(echo 'show status' | timeout 20 "$aella_cli" 2>/dev/null \
              | sed -E 's/\x1b\[[0-9;]*m//g' || true)
        if grep -q 'All pods are running' <<<"$out"; then
            log "  All pods are running (per aella_cli show status)"
            grep -E '^(All |[0-9]+ |License |CM |DNS |Using |No |The |Provision )' <<<"$out" \
                | while IFS= read -r line; do log "    $line"; done
            return 0
        fi
        remaining=$(( deadline - $(date +%s) ))
        # Pull progress line from status (e.g. "52 pods running, at least 53 expected")
        pod_line=$(grep -E '^[0-9]+ pods? running' <<<"$out" | head -1)
        if [[ -n "$pod_line" ]]; then
            log "  $pod_line; waiting (${remaining}s remaining)..."
        else
            log "  status not yet ready; waiting (${remaining}s remaining)..."
        fi
        sleep "$poll_interval"
    done
    log "INFO: 'All pods are running' not yet observed after ${budget_sec}s. This is normal for fresh online bringups (kubelet/aellad still pulling images)."
    log "  Continue checking with: sudo $aella_cli  -> show status"
    log "  Or: sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A | grep -vE 'Running|Completed'"
    return 0   # informational, never fail
}

###############################################################################
# PHASE 12: COMPREHENSIVE VALIDATION
###############################################################################
validate_all() {
    log_phase "Comprehensive Validation"

    local errors=0
    local warnings=0

    # Python 3
    if python3 --version &>/dev/null; then
        log "  PASS: Python 3 - $(python3 --version 2>&1)"
    else
        log "  FAIL: Python 3 not found"
        ((errors++)) || true
    fi

    # AELDEV-71573: pip3 CLI is intentionally NOT installed on --skip-download
    # (no apt cache + apt --fix-broken rolled back python3-flask install).
    # python deps come from pip3-site-packages.tar.gz extracted into
    # /usr/lib/python3/dist-packages -- no pip3 binary needed at runtime.
    # Demote pip3 to a WARN on --skip-download, full FAIL on online mode.
    if pip3 --version &>/dev/null; then
        log "  PASS: pip3 available"
    elif [[ "$SKIP_DOWNLOAD" == "true" ]]; then
        log "  WARN: pip3 not present (expected on --skip-download; deps come from pip3-site-packages.tar.gz)"
        ((warnings++)) || true
    else
        log "  FAIL: pip3 not found"
        ((errors++)) || true
    fi

    # AELDEV-70457: /usr/bin/python MUST resolve to python3 (aella-cms shebang
    # is `#!/usr/bin/env python`). python-minimal postinst can flip it back to
    # python2.7; ensure_python3_symlink is the safety net but verify here too.
    if [[ -L /usr/bin/python ]] && [[ "$(readlink /usr/bin/python)" == *"python3"* ]]; then
        log "  PASS: /usr/bin/python -> python3"
    else
        log "  FAIL: /usr/bin/python not pointing to python3 (was: $(readlink /usr/bin/python 2>/dev/null || echo absent))"
        ((errors++)) || true
    fi

    # AELDEV-70189: no broken py2 zombie packages remaining. iU state means
    # do-release-upgrade left half-installed packages that block apt operations
    # (dpkg crashes on cached 16.04 debs). purge_legacy_py2_zombies should have
    # cleared these in install_python3.
    local iu_zombies
    iu_zombies=$(dpkg -l 2>/dev/null | awk '/^iU/ && $2 ~ /^(python-|libpython-)/ {print $2}' | tr '\n' ' ')
    if [[ -z "$iu_zombies" ]]; then
        log "  PASS: no iU py2 zombie packages"
    else
        log "  WARN: iU py2 zombies remain (purge had errors): $iu_zombies"
        ((warnings++)) || true
    fi

    # AELDEV-70189: legacy py2 elasticsearch client should be gone. It chains
    # the iU zombies back via Depends on python-urllib3 etc; py3 elasticsearch
    # 7.7.0 (already installed via pip3-site-packages.tar.gz) covers all callers.
    if dpkg -s python-elasticsearch &>/dev/null; then
        log "  WARN: legacy py2 python-elasticsearch still installed (chain-trigger for iU re-install)"
        ((warnings++)) || true
    else
        log "  PASS: legacy py2 python-elasticsearch not installed"
    fi

    if python3 -c "import requests; import elasticsearch; import boto3" &>/dev/null; then
        log "  PASS: Critical Python3 imports OK"
    else
        log "  WARN: Some Python3 imports failed"
        ((warnings++)) || true
    fi

    # AELDEV-70673: validate against EXPECTED_DOCKER_MAJOR. Was hard-coded to
    # "28\." which produced a false WARN after the bump to 29.x.
    if docker info &>/dev/null; then
        local docker_ver
        docker_ver=$(docker --version 2>&1)
        if echo "$docker_ver" | grep -qE "version ${EXPECTED_DOCKER_MAJOR}[.]"; then
            log "  PASS: Docker ${EXPECTED_DOCKER_MAJOR}.x running - $docker_ver"
        else
            log "  WARN: Docker running but not ${EXPECTED_DOCKER_MAJOR}.x - $docker_ver"
            ((warnings++)) || true
        fi
    else
        log "  FAIL: Docker not running"
        ((errors++)) || true
    fi

    # containerd
    if containerd --version &>/dev/null; then
        log "  PASS: containerd available - $(containerd --version 2>&1 | head -1)"
    else
        log "  FAIL: containerd not found"
        ((errors++)) || true
    fi

    # crictl
    if crictl info &>/dev/null; then
        log "  PASS: crictl OK (containerd backend)"
    else
        log "  WARN: crictl info failed"
        ((warnings++)) || true
    fi

    if [[ -f /etc/docker/daemon.json ]]; then
        log "  PASS: daemon.json exists"
    else
        log "  FAIL: daemon.json missing"
        ((errors++)) || true
    fi

    # Kubernetes 1.31
    if command -v kubeadm &>/dev/null; then
        if kubeadm version 2>/dev/null | grep -q "1.31"; then
            log "  PASS: kubeadm 1.31 available"
        else
            log "  WARN: kubeadm available but not 1.31"
            ((warnings++)) || true
        fi
    else
        log "  FAIL: kubeadm not found"
        ((errors++)) || true
    fi

    # kubelet drop-in (critical for kubeadm-managed kubelet)
    if [[ -f /etc/systemd/system/kubelet.service.d/10-kubeadm.conf ]]; then
        log "  PASS: kubelet kubeadm drop-in exists"
    else
        log "  FAIL: kubelet kubeadm drop-in missing (/etc/systemd/system/kubelet.service.d/10-kubeadm.conf)"
        ((errors++)) || true
    fi

    # CNI plugins
    if [[ -d /opt/cni/bin ]] && ls /opt/cni/bin/* &>/dev/null; then
        log "  PASS: CNI plugins present ($(ls /opt/cni/bin/ 2>/dev/null | wc -l) binaries)"
    else
        log "  FAIL: CNI plugins missing in /opt/cni/bin/"
        ((errors++)) || true
    fi

    # Helm
    if command -v helm &>/dev/null; then
        if helm version --short 2>/dev/null | grep -q "v3.17"; then
            log "  PASS: Helm 3.17 available"
        else
            log "  WARN: Helm available but not 3.17: $(helm version --short 2>&1)"
            ((warnings++)) || true
        fi
    else
        log "  FAIL: Helm not found"
        ((errors++)) || true
    fi

    # K8s worker validation
    if [[ "$ROLE" == *worker* ]]; then
        if systemctl is-active --quiet kubelet 2>/dev/null; then
            log "  PASS: kubelet active (worker)"
        else
            log "  FAIL: kubelet not active (worker)"
            ((errors++)) || true
        fi
        if [[ -f /etc/kubernetes/kubelet.conf ]]; then
            log "  PASS: kubelet.conf exists (joined cluster)"
        else
            log "  FAIL: kubelet.conf missing (not joined)"
            ((errors++)) || true
        fi
        if ip link show flannel.1 &>/dev/null; then
            log "  PASS: flannel.1 interface exists (worker)"
        else
            log "  WARN: flannel.1 not found (worker)"
            ((warnings++)) || true
        fi
    fi

    # K8s cluster (master/AIO only)
    if [[ "$ROLE" != *worker* ]]; then
        export KUBECONFIG=/etc/kubernetes/admin.conf
        if kubectl get nodes &>/dev/null; then
            local node_status
            node_status=$(kubectl get nodes --no-headers 2>/dev/null | head -5)
            log "  PASS: K8s cluster accessible"
            echo "$node_status" | while read -r line; do log "    $line"; done

            # Check flannel (kube-flannel namespace)
            if kubectl get pods -n kube-flannel 2>/dev/null | grep -q "flannel.*Running"; then
                log "  PASS: Flannel running (kube-flannel namespace)"
            else
                log "  WARN: Flannel not running in kube-flannel namespace"
                ((warnings++)) || true
            fi

            # Check imagePullSecrets on default SA
            if kubectl get serviceaccount default -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null | grep -q "stellar-docker"; then
                log "  PASS: imagePullSecrets on default SA"
            else
                log "  WARN: imagePullSecrets not set on default SA"
                ((warnings++)) || true
            fi

            # Pod summary
            local total_pods running_pods
            total_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)
            # AELDEV-70680: see line ~445 -- avoid `grep -c ... || echo 0` (double-print bug).
            running_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -c "Running" || true)
            running_pods=${running_pods:-0}
            log "  INFO: Pods $running_pods/$total_pods running"
        else
            log "  FAIL: K8s cluster not accessible"
            ((errors++)) || true
        fi
    fi

    # Systemd services (all 7 aella services)
    for svc in aella_cluster_manager aella_ctrl_rh aella_conf_rh aella_conf_sys aella_cluster_controller aella_cluster_scheduler aellad; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log "  PASS: $svc active"
        else
            log "  WARN: $svc not active"
            ((warnings++)) || true
        fi
    done

    # Flannel networking (master/AIO)
    if [[ "$ROLE" != *worker* ]]; then
        if ip link show flannel.1 &>/dev/null; then
            log "  PASS: flannel.1 interface exists"
        else
            log "  WARN: flannel.1 interface not found"
            ((warnings++)) || true
        fi
    fi

    # elasticdump
    if command -v elasticdump &>/dev/null; then
        log "  PASS: elasticdump available"
    else
        log "  WARN: elasticdump not found"
        ((warnings++)) || true
    fi

    # UVP packages (py3 meta-package is aella-uvp-2404)
    local installed_pkgs=0
    if dpkg -s aella-uvp-2404 &>/dev/null; then
        ((installed_pkgs++)) || true
    fi
    for pkg in aella-da-services aella-da-cli aellacm kube-tools phonehome pypki; do
        if dpkg -s "$pkg" &>/dev/null; then
            ((installed_pkgs++)) || true
        fi
    done
    if [[ $installed_pkgs -ge 6 ]]; then
        log "  PASS: UVP packages ($installed_pkgs/7)"
    else
        log "  WARN: Only $installed_pkgs/7 UVP packages installed"
        ((warnings++)) || true
    fi

    # PyPKI module (deb only installs egg-info, tarball extraction required)
    if python3 -c "from PyPKI import PyPKI" 2>/dev/null; then
        log "  PASS: PyPKI module importable"
    else
        log "  WARN: PyPKI module NOT importable (aellad will crash-loop)"
        ((warnings++)) || true
    fi

    # AELDEV-74638: log(), not bare echo -- detached runs discard stdout
    log ""
    log "========================================"
    if [[ $errors -eq 0 ]]; then
        log "VALIDATION RESULT: PASSED ($warnings warnings)"
    else
        log "VALIDATION RESULT: FAILED ($errors errors, $warnings warnings)"
    fi
    log "========================================"

    return $errors
}

###############################################################################
# PHASE 13: ORCHESTRATE WORKERS
###############################################################################

# AELDEV-74638: gate worker orchestration on the master's aella_da_restful
# actually listening on :8003. Workers fetch their kubeadm join token from
# https://<master>:8003/api/1.0/master_token; if aella_da_restful is dead
# (e.g. flask import failure from an incomplete py3-apt-packages.tar.gz) the
# workers stall forever at "Getting join token from master..." with no error
# on the master side. Stop HERE, on the master, with a self-service
# remediation recipe -- the operator installs the named packages and reruns;
# no dev/ACPS bundle rebuild needed to get unblocked.
wait_for_da_restful_8003() {
    local timeout_s=300 waited=0
    log "Waiting for aella_da_restful on :8003 (worker join token endpoint, ${timeout_s}s budget)..."
    while [[ $waited -lt $timeout_s ]]; do
        # ( ... || true ) guards pipefail: grep -q's early exit can SIGPIPE ss.
        if (ss -ltn 2>/dev/null || true) | grep -q ':8003 '; then
            log "aella_da_restful is listening on :8003 (after ${waited}s)"
            return 0
        fi
        sleep 10; waited=$((waited + 10))
    done
    log "ERROR: :8003 not listening after ${timeout_s}s -- workers cannot fetch join"
    log "tokens, so worker orchestration is stopped BEFORE it can hang."
    local missing="" mod
    for mod in flask click psutil pymongo; do
        python3 -c "import $mod" 2>/dev/null || missing="$missing python3-$mod"
    done
    if [[ -n "$missing" ]]; then
        log "Cause: python3 module(s) missing (incomplete py3-apt-packages.tar.gz,"
        log "AELDEV-74638). ACTION REQUIRED (self-service, no new bundle needed):"
        log "  1. Install the missing packages ON THIS MASTER:"
        log "       online:    apt-get install -y$missing"
        log "       dark-site: on any internet Ubuntu 24.04 host run:"
        log "                    apt-get download$missing"
        log "                  copy the .debs here and run: dpkg -i <debs>"
        log "  2. Verify: python3 -c 'import flask' && ss -ltn | grep 8003"
        log "     (aella_da_restful restarts on its own; give it ~1 min)"
        log "  3. Rerun this bringup with the SAME arguments (safe to rerun) --"
        log "     it will skip completed phases and proceed to the worker join."
        log "  A fixed py3-apt-packages bundle (2026-08+) on ACPS prevents this"
        log "  on future bringups; no need to wait for it to recover this DP."
    else
        log "Cause: python3 imports are OK -- aella_da_restful itself is not up."
        log "  Check: pgrep -af aella_da_restful; aellad logs under /var/log/aella/;"
        log "  then rerun this bringup with the SAME arguments."
        # pgrep rc=1 on no match would kill the script under set -e before die.
        (pgrep -af aella_da_restful 2>/dev/null || true) | head -3 | \
            while read -r line; do log "  proc: $line"; done
    fi
    die "aella_da_restful not on :8003 -- fix per instructions above, then rerun bringup (AELDEV-74638)"
}

orchestrate_workers() {
    log_phase "Orchestrate Worker Nodes"

    if [[ -z "$WORKER_IPS" && -z "$STANDBY_IPS" ]]; then
        log "No worker/standby IPs specified, skipping"
        return 0
    fi

    # Worker SSH via sshpass (standard on-prem DP auth: aella/aelladata)
    local WORKER_PASS="aelladata"
    local WORKER_USER="aella"
    if ! command -v sshpass &>/dev/null; then
        log "Installing sshpass (needed for worker SSH)..."
        apt-get install -y sshpass &>/dev/null || die "Failed to install sshpass"
    fi
    mkdir -p ~/.ssh 2>/dev/null || true

    # Helper functions for SSH/SCP to workers
    worker_ssh() {
        local ip="$1"; shift
        sshpass -p "$WORKER_PASS" ssh $SSH_OPTS "${WORKER_USER}@${ip}" "$@"
    }
    worker_scp() {
        local src="$1" dst_ip="$2" dst_path="$3"
        sshpass -p "$WORKER_PASS" scp $SCP_OPTS "$src" "${WORKER_USER}@${dst_ip}:${dst_path}"
    }

    local master_ip
    master_ip=$(kubectl get nodes -o wide --no-headers 2>/dev/null | awk '{print $6}' | head -1 || true)
    log "Master IP: $master_ip"
    log "Worker auth: sshpass (${WORKER_USER})"

    # Detect worker role from master's perspective (standby entries get role
    # standby regardless -- AELDEV-73583 --standby orchestration).
    local default_worker_role
    if [[ "$ROLE" == "DR-master" ]]; then
        default_worker_role="DR-worker"
    elif [[ "$ROLE" == "DL-master" ]]; then
        default_worker_role="DL-worker"
    else
        default_worker_role="DR-worker"  # default
    fi

    # Build the deployment list: workers first (data path up ASAP), then
    # standby node(s) -- a standby joins the already-forming cluster and its
    # heartbeat/sync machinery expects the primary side to exist.
    local node_specs=()
    local _ip
    IFS=',' read -ra workers <<< "$WORKER_IPS"
    for _ip in "${workers[@]}"; do
        _ip=$(echo "$_ip" | xargs)
        [[ -n "$_ip" ]] && node_specs+=("${_ip}:${default_worker_role}")
    done
    IFS=',' read -ra standbys <<< "$STANDBY_IPS"
    for _ip in "${standbys[@]}"; do
        _ip=$(echo "$_ip" | xargs)
        [[ -n "$_ip" ]] && node_specs+=("${_ip}:standby")
    done

    # Warm up SSH connections to workers: first sshpass connect can be slow
    # due to key exchange. SSH_OPTS uses UserKnownHostsFile=/dev/null so
    # known_hosts isn't used; the retry below handles the timing issue.
    local node_spec worker_ip node_role
    for node_spec in "${node_specs[@]}"; do
        worker_ip="${node_spec%%:*}"
        node_role="${node_spec##*:}"
        log ""
        log "--- Deploying node: $worker_ip (role: $node_role) ---"

        # Test SSH connectivity to worker (retry once after 5s if first attempt fails)
        log "Testing SSH to $worker_ip..."
        if ! worker_ssh "$worker_ip" "echo ok" &>/dev/null; then
            log "WARNING: First SSH to $worker_ip failed, retrying in 5s..."
            sleep 5
            if ! worker_ssh "$worker_ip" "echo ok" &>/dev/null; then
                log "ERROR: Cannot SSH to worker $worker_ip -- skipping"
                continue
            fi
        fi

        # AELDEV-73583 guard: intended role must match the node's preserved
        # aella_role in BOTH directions. A standby listed under --worker-ips
        # would be provisioned as a worker (wrong token params, wrong
        # expectations); a worker listed under --standby would be provisioned
        # as a standby. Skip with instructions instead of mis-provisioning.
        local remote_role
        remote_role=$(worker_ssh "$worker_ip" \
            "grep aella_role /opt/aelladata/work/da_conf.yml 2>/dev/null | awk -F': ' '{print \$2}' | tr -d \"' \"" 2>/dev/null || echo "")
        if [[ "$remote_role" == "standby" && "$node_role" != "standby" ]]; then
            log "ERROR: $worker_ip has aella_role: standby but was listed in --worker-ips -- SKIPPING."
            log "  Use --standby $worker_ip (or run on the node itself with --role standby)."
            continue
        fi
        if [[ "$node_role" == "standby" && -n "$remote_role" && "$remote_role" != "standby" ]]; then
            log "ERROR: $worker_ip was listed in --standby but has aella_role: ${remote_role} -- SKIPPING."
            log "  Use --worker-ips for workers; fix da_conf/role assignment first."
            continue
        fi

        # Create directories on worker (sudo needed for aella user) and
        # wipe stale root-owned debs/tarballs left by a prior UVP postinst.
        # AELDEV-70663: OpenSSH 9.x on 24.04 routes scp through the SFTP
        # backend, which enforces POSIX file ownership on overwrite even
        # when the parent dir is 777 -- aella cannot open(O_WRONLY|O_TRUNC)
        # a root:root 644 file. DL workers happen to start with empty
        # $AELLADEB_DIR (scp creates fresh aella-owned files); DA workers
        # carry leftover root-owned debs from the original install and the
        # second scp pass silently fails for all 6 sub-debs. Removing the
        # stale files before chmod 777 makes scp create fresh files in
        # both cases.
        worker_ssh "$worker_ip" "sudo mkdir -p $STAGING_DIR $AELLADEB_DIR && \
            sudo find -L $STAGING_DIR $AELLADEB_DIR -maxdepth 1 -type f \
                 \\( -name '*.deb' -o -name '*.tar.gz' -o -name '*.tgz' \\) \
                 -delete 2>/dev/null; \
            sudo chmod 777 $STAGING_DIR $AELLADEB_DIR"

        # Copy script to worker
        log "Copying script to $worker_ip..."
        worker_scp "$SCRIPT_PATH" "$worker_ip" "/tmp/${SCRIPT_NAME}"

        # Copy all debs and tarballs. Use a shell loop because worker_scp
        # wraps the source arg in double quotes, which suppresses bash's
        # glob expansion -- a bare `worker_scp "${STAGING_DIR}/*.deb" ...`
        # passes the literal pattern to scp and silently fails. Expanding
        # the glob here and scp'ing each file individually ensures the
        # patched master debs actually reach the worker (without this the
        # worker installs from whatever was left in /opt/aelladata/... by
        # a previous install, so master-side deb patches are invisible to
        # workers and templates / aellautil fixes don't propagate).
        # AELDEV-70663: capture scp stderr in the WARNING so future
        # failures self-explain instead of presenting as a bare "failed
        # to scp X" with the underlying "Permission denied" hidden.
        log "Copying staged artifacts to $worker_ip..."
        # AELDEV-70735: include *.tar so dark-site image tarballs (e.g.
        # images-6.5.0.tar, 27 GB) reach workers; otherwise worker's
        # load_local_images finds nothing and worker bringup tries to pull
        # all images over the network -> blocked -> bringup fails. Also
        # copy .sha256/.sha1/.list so workers can verify the bundle.
        for f in "${STAGING_DIR}"/*.deb \
                 "${STAGING_DIR}"/*.tar.gz "${STAGING_DIR}"/*.tgz \
                 "${STAGING_DIR}"/*.tar \
                 "${STAGING_DIR}"/*.sha1 "${STAGING_DIR}"/*.sha256 \
                 "${STAGING_DIR}"/*.list; do
            [[ -f "$f" ]] || continue
            local _scp_err _sz
            _sz=$(du -h "$f" 2>/dev/null | awk '{print $1}')
            # Skip-if-already-present on worker (by sha + size) to make
            # re-runs idempotent and avoid re-transferring 27 GB tarballs.
            local _local_sha _remote_sha _fname
            _fname=$(basename "$f")
            if [[ "$f" == *.tar ]] && [[ -f "${f}.sha256" ]]; then
                _local_sha=$(awk '{print $1}' "${f}.sha256" 2>/dev/null)
                _remote_sha=$(worker_ssh "$worker_ip" "sha256sum '${STAGING_DIR}/${_fname}' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || echo "")
                if [[ -n "$_local_sha" ]] && [[ "$_local_sha" == "$_remote_sha" ]]; then
                    log "  ${_fname} (${_sz}) already on $worker_ip with matching sha256, skipping"
                    continue
                fi
            fi
            log "  scp ${_fname} (${_sz}) -> $worker_ip:${STAGING_DIR}/"
            _scp_err=$(worker_scp "$f" "$worker_ip" "${STAGING_DIR}/" 2>&1 >/dev/null) || \
                log "  WARNING: failed to scp $(basename "$f"): ${_scp_err}"
        done

        # Copy UVP and sub-debs from aelladeb dir
        log "Copying UVP debs to $worker_ip..."
        for f in "${AELLADEB_DIR}"/*.deb; do
            [[ -f "$f" ]] || continue
            local _scp_err
            _scp_err=$(worker_scp "$f" "$worker_ip" "${AELLADEB_DIR}/" 2>&1 >/dev/null) || \
                log "  WARNING: failed to scp $(basename "$f"): ${_scp_err}"
        done

        # Run script on the node (sudo for root access) with its intended role.
        # AELDEV-73583: propagate the MASTER's download mode instead of
        # hard-coding --skip-download. Hard-coding broke ONLINE --worker-ips
        # bringups: remote preflight_bundle demands images-<ver>.tar, which
        # does not exist online (images are registry-pulled) -> every remote
        # node died "FATAL: Bundle incomplete" (observed live 2026-07-23).
        # Online mode: the scp'd UVP+common satisfy check_local_artifacts, so
        # remote nodes skip ACPS download and pull images from the registry.
        local skip_flag=""
        [[ "$SKIP_DOWNLOAD" == "true" ]] && skip_flag="--skip-download"
        log "Running bringup on $worker_ip (role: $node_role)..."
        worker_ssh "$worker_ip" \
            "sudo bash /tmp/${SCRIPT_NAME} --version $VERSION --role $node_role --worker-mode ${skip_flag}" 2>&1 | \
            while IFS= read -r line; do log "  [$worker_ip] $line"; done || {
            log "WARNING: Node $worker_ip bringup had errors"
        }

        # Verify worker appeared in cluster (check from master)
        sleep 10
        local worker_hostname
        worker_hostname=$(worker_ssh "$worker_ip" "hostname" 2>/dev/null || echo "unknown")
        if kubectl get nodes 2>/dev/null | grep -qi "$worker_hostname"; then
            log "Worker $worker_ip ($worker_hostname) joined cluster successfully"
        else
            log "WARNING: Worker $worker_ip ($worker_hostname) not yet visible in 'kubectl get nodes'"
            log "  It may still be joining -- check with: kubectl get nodes"
        fi

        log "Worker $worker_ip deployment complete"
    done

    # Final cluster state
    log "Cluster state after worker deployment:"
    kubectl get nodes -o wide 2>/dev/null || true
}

###############################################################################
# WORKER K8S JOIN (worker mode only)
###############################################################################
join_k8s_cluster() {
    log_phase "Join K8s Cluster (Worker)"

    export PYTHONPATH=/opt/aelladata/python:/opt/aelladata/cms

    # Skip if already joined
    if [[ -f /etc/kubernetes/kubelet.conf ]]; then
        log "Already joined K8s cluster"
        return 0
    fi

    # Get master IP from da_conf.yml
    local master_ip
    master_ip=$(grep 'master_ip' "$DA_CONF" 2>/dev/null | awk -F': ' '{print $2}' | tr -d "' \"" || true)
    if [[ -z "$master_ip" ]]; then
        master_ip=$(grep 'master' "$DA_CONF" 2>/dev/null | head -1 | awk -F': ' '{print $2}' | tr -d "' \"" || true)
    fi
    if [[ -z "$master_ip" ]]; then die "Cannot determine master IP from $DA_CONF"; fi
    log "Master IP: $master_ip"

    # Wait for master API to be available
    log "Waiting for master API..."
    local wait_attempts=0
    while ! curl -sk "https://${master_ip}:6443/healthz" &>/dev/null; do
        ((wait_attempts++)) || true
        if [[ $wait_attempts -ge 60 ]]; then die "Master API not available after 300 seconds"; fi
        sleep 5
    done
    log "Master API ready"

    # Get join token from master REST API
    log "Getting join token from master..."
    local username password token=""
    username=$(python3 -c 'import sys; sys.path.insert(0,"/opt/aelladata/python"); sys.path.insert(0,"/opt/aelladata/cms"); import aellautil.aellautil as au; print(au.AellaUtil().get_curl_username())' 2>/dev/null || echo "")
    password=$(python3 -c 'import sys; sys.path.insert(0,"/opt/aelladata/python"); sys.path.insert(0,"/opt/aelladata/cms"); import aellautil.aellautil as au; print(au.AellaUtil().get_curl_password())' 2>/dev/null || echo "")
    local host_name
    host_name=$(hostname)

    # AELDEV-73583: node_bootstrap.sh parity -- a standby announces itself on
    # the token fetch (standby=1) so the master records it via
    # record_standby_node. Harmless no-op on re-bringup (record preserved in
    # /opt/aelladata/work/standby on the master); required for a fresh standby.
    local token_extra=""
    [[ "$ROLE" == "standby" ]] && token_extra="&standby=1"

    if [[ -n "$username" && -n "$password" ]]; then
        local token_response
        token_response=$(curl -sk -u "${username}:${password}" \
            "https://${master_ip}:8003/api/1.0/master_token?host=${host_name}${token_extra}" 2>/dev/null)
        log "Token API response length: ${#token_response}"

        # Response may be raw token or JSON -- extract token if JSON
        if echo "$token_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" &>/dev/null; then
            token=$(echo "$token_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token','') or d.get('data',{}).get('token',''))" 2>/dev/null)
        fi
        # If python parsing failed or returned empty, use raw response
        if [[ -z "$token" ]]; then
            token="$token_response"
        fi
    fi

    if [[ -z "$token" || "$token" == *"error"* || "$token" == *"Error"* ]]; then
        log "WARNING: Could not get token from REST API"
        log "  Response: ${token_response:-empty}"
        log "  Ensure master is fully up and aella_cluster_manager is running."
        die "Cannot get join token from master"
    fi

    log "Got join token (${#token} chars)"

    # Render join config (v1beta3 for K8s 1.31)
    python3 /opt/aelladata/kubernetes/scripts/render_kubeadm_config.py \
        kubeadm-join.u2404.yml.j2 /opt/aelladata/kubernetes/kubeadm-join.yml \
        --token "$token" --apiserver-advertise-address "$master_ip" || \
        die "Failed to render kubeadm join config"

    # Pre-join cleanup (Ubuntu 24.04)
    ip link set cni0 down 2>/dev/null || true
    ip link set flannel.1 down 2>/dev/null || true
    ip link delete cni0 2>/dev/null || true
    ip link delete flannel.1 2>/dev/null || true

    # Stop kubelet before join -- Phase 8 starts aella services which enables kubelet,
    # holding port 10250. kubeadm join preflight checks require this port free.
    stop_kubelet_free_port() {
        systemctl stop kubelet 2>/dev/null || true
        sleep 2
        if ss -tlnp | grep -q ':10250 '; then
            log "WARNING: Port 10250 still in use, killing process..."
            fuser -k 10250/tcp 2>/dev/null || true
            sleep 1
        fi
    }
    stop_kubelet_free_port

    # Join cluster with retry
    log "Joining K8s cluster..."
    if ! kubeadm join "${master_ip}:6443" \
        --config /opt/aelladata/kubernetes/kubeadm-join.yml \
        --ignore-preflight-errors=FileAvailable--etc-kubernetes-pki-ca.crt 2>&1; then
        log "WARNING: kubeadm join failed on first attempt, retrying after reset..."
        kubeadm reset -f 2>/dev/null || true
        stop_kubelet_free_port
        sleep 5
        kubeadm join "${master_ip}:6443" \
            --config /opt/aelladata/kubernetes/kubeadm-join.yml \
            --ignore-preflight-errors=FileAvailable--etc-kubernetes-pki-ca.crt || \
            die "kubeadm join failed after retry"
    fi

    # Post-join config
    log "Running post-join config..."
    sysctl -w vm.max_map_count=2621440 2>/dev/null || true
    systemctl daemon-reload
    systemctl restart kubelet

    # Run config_worker.sh for flannel consistency fix (don't source -- it may exit/redirect)
    if [[ -f /opt/aelladata/kubernetes/scripts/config_worker.sh ]]; then
        log "Running config_worker.sh..."
        bash /opt/aelladata/kubernetes/scripts/config_worker.sh 2>&1 || \
            log "WARNING: config_worker.sh had errors"
    fi

    # Wait for kubelet to be healthy
    log "Waiting for kubelet to become healthy..."
    local kubelet_attempts=0
    while ! systemctl is-active --quiet kubelet; do
        ((kubelet_attempts++)) || true
        if [[ $kubelet_attempts -ge 30 ]]; then log "WARNING: kubelet not active after 60s"; break; fi
        sleep 2
    done

    # Verify join succeeded -- kubelet.conf should exist
    if [[ -f /etc/kubernetes/kubelet.conf ]]; then
        log "Worker joined K8s cluster successfully (kubelet.conf present)"
    else
        log "WARNING: kubelet.conf not found -- join may not have completed"
    fi

    # Wait for flannel on worker
    log "Waiting for flannel..."
    local flannel_wait=0
    while ! ip link show flannel.1 &>/dev/null; do
        ((flannel_wait++)) || true
        if [[ $flannel_wait -ge 60 ]]; then log "WARNING: flannel.1 not ready after 120s"; break; fi
        sleep 2
    done
    if ip link show flannel.1 &>/dev/null; then
        log "flannel.1 interface ready"
        # Restart containerd + kubelet to initialize CNI plugin.
        # containerd may have started before flannel deployed the CNI config,
        # leaving kubelet reporting "NetworkPluginNotReady: cni plugin not initialized".
        log "Restarting containerd and kubelet to initialize CNI..."
        systemctl restart containerd
        sleep 3
        systemctl restart kubelet
    fi
}

###############################################################################
# AUTO OS UPGRADE: systemd service + helper script for unattended upgrade chain
# Upgrades Ubuntu 16.04 -> 18.04 -> 20.04 -> 22.04 -> 24.04 with reboots
###############################################################################
AUTO_UPGRADE_DIR="/opt/aelladata/os-upgrade"
AUTO_UPGRADE_SCRIPT="${AUTO_UPGRADE_DIR}/auto_os_upgrade.sh"
AUTO_UPGRADE_LOG="/var/log/aella/auto_os_upgrade.log"
AUTO_UPGRADE_SERVICE="aella-os-upgrade.service"

setup_auto_os_upgrade() {
    log_phase "Auto OS Upgrade Setup"

    if [[ $EUID -ne 0 ]]; then die "Must run as root"; fi

    # AELDEV-70680 #7: refuse if a chain run is already in flight. The helper
    # itself uses flock to prevent concurrent helper instances, but a human
    # running `sudo bash bringup_py3_dp_after_os_upgrade.sh --auto-os-upgrade`
    # while the systemd service is already running would re-run pre_upgrade_
    # cleanup mid-flight (sed sources.list under the running apt) and would
    # re-write the helper script while the live one is reading it. Refuse
    # cleanly with a monitoring hint.
    local svc_state
    svc_state=$(systemctl is-active aella-os-upgrade.service 2>/dev/null || true)
    if [[ "$svc_state" == "active" ]] || [[ "$svc_state" == "activating" ]]; then
        log ""
        log "ABORT: aella-os-upgrade.service is already $svc_state -- a chain run is in flight."
        log "Monitor it with:   sudo tail -f /var/log/aella/auto_os_upgrade.log"
        log "Inspect state:     sudo cat /opt/aelladata/os-upgrade/state"
        log "If genuinely stuck (>2h on same line), stop with:   sudo systemctl stop aella-os-upgrade.service"
        log "Then re-run this script to resume."
        exit 1
    fi

    # Step 1: Run pre_upgrade_cleanup for the CURRENT OS version
    log "Running pre_upgrade_cleanup for current OS before first hop..."
    pre_upgrade_cleanup

    # Step 2: Change aella user shell from aella_cli to bash
    # This ensures SSH login with aella/aelladata drops to bash during upgrade chain
    # User restores /usr/bin/aella_cli after bringup is complete
    if grep -q '/usr/bin/aella_cli' /etc/passwd 2>/dev/null; then
        log "Changing aella user shell: /usr/bin/aella_cli -> /bin/bash"
        sed -i 's|/usr/bin/aella_cli|/bin/bash|' /etc/passwd
    else
        log "aella user shell already set to bash (or aella_cli not found)"
    fi

    # Step 3: Fix GRUB for visibility during upgrade reboots
    if [[ -f /etc/default/grub ]]; then
        log "Fixing GRUB: commenting out GRUB_HIDDEN_*, setting GRUB_TIMEOUT=10"
        cp /etc/default/grub /etc/default/grub.bak.auto_os_upgrade
        # Comment out any GRUB_HIDDEN_* lines
        sed -i 's/^\(GRUB_HIDDEN_.*\)/#\1/' /etc/default/grub
        # Set or replace GRUB_TIMEOUT
        if grep -q '^GRUB_TIMEOUT=' /etc/default/grub; then
            sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=10/' /etc/default/grub
        else
            echo 'GRUB_TIMEOUT=10' >> /etc/default/grub
        fi
        update-grub 2>/dev/null || log "WARNING: update-grub failed (non-fatal)"
    fi

    # Step 4: Create directory structure
    mkdir -p "$AUTO_UPGRADE_DIR"
    mkdir -p /var/log/aella

    # Step 5: Write the 99force-confold apt config (persists across all hops)
    log "Writing /etc/apt/apt.conf.d/99force-confold"
    cat > /etc/apt/apt.conf.d/99force-confold << 'CONFOLD_EOF'
// Keep existing config files during OS upgrades (unattended)
Dpkg::Options {
   "--force-confdef";
   "--force-confold";
};
CONFOLD_EOF

    # Step 6: Write the helper script
    log "Writing $AUTO_UPGRADE_SCRIPT"
    cat > "$AUTO_UPGRADE_SCRIPT" << 'HELPER_EOF'
#!/bin/bash
###############################################################################
# auto_os_upgrade.sh - Unattended Ubuntu upgrade chain for Stellar Cyber DPs
#
# Runs on every boot via aella-os-upgrade.service.
# Performs: pre_upgrade_cleanup -> do-release-upgrade -> reboot
# Repeats until Ubuntu 24.04 (noble) is reached, then disables itself.
###############################################################################
set -uo pipefail

AUTO_UPGRADE_DIR="/opt/aelladata/os-upgrade"
STATE_FILE="${AUTO_UPGRADE_DIR}/state"
LOG_FILE="/var/log/aella/auto_os_upgrade.log"
LOCK_FILE="/var/run/aella-os-upgrade.lock"
TARGET_VERSION="24.04"
TARGET_CODENAME="noble"
MAX_HOPS=6  # safety: 16.04->24.04 = 4 hops, allow 6 for margin

export DEBIAN_FRONTEND=noninteractive
# AELDEV-70680: $DPKG_OPTS is NOT read by dpkg -- the previous export was a
# no-op. Real conffile auto-resolution is configured via apt.conf.d below.
export DPKG_FORCE="confold,confdef"

alog() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [auto-os-upgrade] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

die_upgrade() {
    alog "FATAL: $*"
    echo "FAILED: $*" > "$STATE_FILE"
    exit 1
}

# Prevent concurrent runs
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    alog "Another instance is already running. Exiting."
    exit 0
fi

# ---- Detect current OS ----
CURRENT_VERSION=$(grep VERSION_ID /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown")
CURRENT_CODENAME=$(grep UBUNTU_CODENAME /etc/os-release 2>/dev/null | cut -d= -f2 || \
                   lsb_release -cs 2>/dev/null || echo "unknown")

alog "========================================================================"
alog "  Auto OS Upgrade - Boot Cycle"
alog "  Current OS: Ubuntu $CURRENT_VERSION ($CURRENT_CODENAME)"
alog "  Target:     Ubuntu $TARGET_VERSION ($TARGET_CODENAME)"
alog "  Host:       $(hostname)"
alog "  Kernel:     $(uname -r)"
alog "========================================================================"

# ---- Read hop counter ----
HOP_COUNT=0
if [[ -f "${AUTO_UPGRADE_DIR}/hop_count" ]]; then
    HOP_COUNT=$(cat "${AUTO_UPGRADE_DIR}/hop_count" 2>/dev/null || echo 0)
fi

# ---- Check if we've reached the target ----
if [[ "$CURRENT_VERSION" == "$TARGET_VERSION" ]] || [[ "$CURRENT_CODENAME" == "$TARGET_CODENAME" ]]; then
    alog "SUCCESS: Ubuntu $TARGET_VERSION reached after $HOP_COUNT hop(s)!"
    alog "Disabling aella-os-upgrade.service..."
    systemctl disable aella-os-upgrade.service 2>/dev/null || true

    # AELDEV-70680: chain-only patches we should clean up so the host is in
    # a "normal" ops state after the upgrade chain completes. Leaving them
    # in place would silently change behavior of every future apt op /
    # crash report. Idempotent: each rm is conditional on the file existing.
    alog "Cleaning up auto-upgrade-chain transient patches..."
    # apt.conf.d snippet that forced --force-confdef --force-confold globally.
    [[ -f /etc/apt/apt.conf.d/99auto-os-upgrade-noninteractive ]] && \
        sudo rm -f /etc/apt/apt.conf.d/99auto-os-upgrade-noninteractive && \
        alog "  removed /etc/apt/apt.conf.d/99auto-os-upgrade-noninteractive"
    # apport-cli no-op shim (AELDEV-70504) -- restore the real binary so
    # crash reporting works again.
    if [[ -f /usr/bin/apport-cli.bak.aellaosupgrade ]]; then
        sudo mv -f /usr/bin/apport-cli.bak.aellaosupgrade /usr/bin/apport-cli && \
            alog "  restored /usr/bin/apport-cli from .bak.aellaosupgrade"
    fi
    # Note: we deliberately KEEP /etc/apt/preferences.d/no-snapd (DPs do
    # not run snap workloads -- pin stays for life of the install) and the
    # AELDEV-70504-UA sitecustomize.py block (idempotent, helps any future
    # urllib HEAD against archive.ubuntu.com).

    echo "COMPLETED" > "$STATE_FILE"
    echo "$CURRENT_VERSION" > "${AUTO_UPGRADE_DIR}/final_version"
    alog "========================================================================"
    alog "  AUTO OS UPGRADE COMPLETE"
    alog "  Final OS:   Ubuntu $CURRENT_VERSION ($CURRENT_CODENAME)"
    alog "  Total hops: $HOP_COUNT"
    alog "  Log:        $LOG_FILE"
    alog "========================================================================"
    alog ""
    alog "Next step: run the bringup script to restore the DP."
    wall "Aella auto-OS-upgrade complete: Ubuntu $CURRENT_VERSION reached. Run bringup script to restore DP." 2>/dev/null || true
    exit 0
fi

# ---- Safety: too many hops ----
if [[ "$HOP_COUNT" -ge "$MAX_HOPS" ]]; then
    die_upgrade "Exceeded maximum hop count ($MAX_HOPS). Current OS: $CURRENT_VERSION. Manual intervention required."
fi

# ---- Record state ----
echo "UPGRADING from $CURRENT_VERSION (hop $((HOP_COUNT+1)))" > "$STATE_FILE"
echo "$CURRENT_VERSION" > "${AUTO_UPGRADE_DIR}/pre_hop_${HOP_COUNT}_version"

alog "Starting hop $((HOP_COUNT+1)): upgrading from Ubuntu $CURRENT_VERSION ($CURRENT_CODENAME)..."

# ---- Sync clock via NTP (clock can drift after upgrade) ----
alog "Syncing system clock..."
if command -v timedatectl &>/dev/null; then
    sudo timedatectl set-ntp true 2>/dev/null || true
fi
if command -v ntpdate &>/dev/null; then
    sudo ntpdate -u pool.ntp.org >> "$LOG_FILE" 2>&1 || true
elif command -v chronyd &>/dev/null; then
    sudo chronyd -q 'server pool.ntp.org iburst' >> "$LOG_FILE" 2>&1 || true
fi
alog "System time: $(date)"

# ---- Stop aella services (DP is being rebuilt anyway) ----
alog "Stopping aella services before OS upgrade..."
for svc in aella-engine aella-dm aella-da aella-updater aella-ade aella-cdc aella-connector kubelet docker containerd; do
    sudo systemctl stop "$svc" 2>/dev/null || true
done
alog "Aella services stopped."

# ---- Pre-upgrade cleanup (runs before EACH hop) ----
alog "Running pre-upgrade cleanup for $CURRENT_CODENAME..."

# Backup sources.list
sudo cp /etc/apt/sources.list "/etc/apt/sources.list.bak.hop${HOP_COUNT}.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

# Remove ALL .list files in sources.list.d -- clean slate for each hop
# do-release-upgrade will add what it needs
for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.list.distUpgrade; do
    if [[ -f "$f" ]]; then
        alog "  Removing $f"
        sudo rm -f "$f"
    fi
done

# Clean stale entries from sources.list
for pattern in 'dl\.aelladata\.com' '129\.146\.74\.109' 'dl\.stellarcyber\.ai' 'aelladata\.com' 'nodesource'; do
    if grep -q "$pattern" /etc/apt/sources.list 2>/dev/null; then
        alog "  Removing $pattern from sources.list"
        sudo sed -i "/${pattern}/d" /etc/apt/sources.list
    fi
done

# Comment out repos from previous codenames (stale after each hop)
case "$CURRENT_CODENAME" in
    xenial)  old_cn="trusty|precise" ;;
    bionic)  old_cn="xenial|trusty|precise" ;;
    focal)   old_cn="xenial|bionic|trusty" ;;
    jammy)   old_cn="xenial|bionic|focal|trusty" ;;
    noble)   old_cn="xenial|bionic|focal|jammy|trusty" ;;
    *)       old_cn="" ;;
esac
if [[ -n "${old_cn:-}" ]]; then
    sudo sed -i -E "s|^(\s*deb\s.*($old_cn).*)$|# DISABLED by auto-os-upgrade: \1|" /etc/apt/sources.list 2>/dev/null || true
fi

# Ensure Ubuntu repos exist for current codename
for suffix in "" "-updates" "-security"; do
    local_repo="${CURRENT_CODENAME}${suffix}"
    if [[ "$suffix" == "-security" ]]; then
        mirror="http://security.ubuntu.com/ubuntu"
    else
        mirror="http://archive.ubuntu.com/ubuntu"
    fi
    if ! grep -qE "^\s*deb\s.*${local_repo}\s" /etc/apt/sources.list 2>/dev/null; then
        alog "  Adding $local_repo repo"
        echo "deb $mirror $local_repo main restricted universe multiverse" | sudo tee -a /etc/apt/sources.list >/dev/null
    fi
done

# Clean stale GPG keys
for keyring in /etc/apt/trusted.gpg.d/nodesource*.gpg \
               /etc/apt/trusted.gpg.d/kubernetes*.gpg \
               /usr/share/keyrings/nodesource*.gpg \
               /usr/share/keyrings/kubernetes*.gpg; do
    [[ -f "$keyring" ]] && sudo rm -f "$keyring"
done

# Fix DNS if broken
if ! getent hosts archive.ubuntu.com &>/dev/null; then
    alog "  DNS broken, attempting fix..."
    sudo systemctl restart systemd-resolved 2>/dev/null || true
    sleep 2
    if ! getent hosts archive.ubuntu.com &>/dev/null; then
        if [[ -f /run/systemd/resolve/resolv.conf ]]; then
            sudo rm -f /etc/resolv.conf
            sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        fi
    fi
    if ! getent hosts archive.ubuntu.com &>/dev/null; then
        [[ -L /etc/resolv.conf ]] && sudo rm -f /etc/resolv.conf
        echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" | sudo tee /etc/resolv.conf >/dev/null
        alog "  Set static DNS nameservers (8.8.8.8, 8.8.4.4)"
    fi
fi

# Clean apt cache
sudo apt-get clean 2>/dev/null || true
sudo rm -rf /var/lib/apt/lists/* 2>/dev/null || true

alog "Pre-upgrade cleanup complete."

# ---- AELDEV-70504: xenial-EOL fallback to old-releases.ubuntu.com ----
# Canonical retires xenial from archive.ubuntu.com after ESM ends
# (target: weeks following 2026-04-30) and moves it to old-releases.
# When that happens, archive 404s for xenial Release while old-releases
# starts serving it. Auto-rewrite sources.list when both conditions
# are true; otherwise no-op. Codename-scoped (xenial only) -- bionic
# and later are on archive.ubuntu.com indefinitely.
if [[ "$CURRENT_CODENAME" == "xenial" ]]; then
    if ! curl -fsS --max-time 30 -o /dev/null \
         "http://archive.ubuntu.com/ubuntu/dists/xenial/Release" 2>/dev/null \
       && curl -fsS --max-time 30 -o /dev/null \
            "http://old-releases.ubuntu.com/ubuntu/dists/xenial/Release" 2>/dev/null; then
        alog "xenial retired from archive.ubuntu.com -- rewriting sources.list to old-releases.ubuntu.com"
        sudo sed -i 's|archive\.ubuntu\.com|old-releases.ubuntu.com|g; s|security\.ubuntu\.com|old-releases.ubuntu.com|g' \
            /etc/apt/sources.list
        sudo apt-get clean 2>/dev/null || true
    fi
fi

# ---- apt-get update with timeout and retry ----
APT_TIMEOUT="-o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=2"
alog "Running apt-get update (30s timeout per repo)..."
if ! sudo apt-get update -y $APT_TIMEOUT >> "$LOG_FILE" 2>&1; then
    alog "WARNING: apt-get update failed, retrying after DNS fix..."
    # Retry: force DNS to Google and try again
    echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" | sudo tee /etc/resolv.conf >/dev/null
    sleep 2
    if ! sudo apt-get update -y $APT_TIMEOUT >> "$LOG_FILE" 2>&1; then
        alog "WARNING: apt-get update failed on retry"
    fi
fi

# ---- Install update-manager-core ----
alog "Installing update-manager-core..."
if ! sudo apt-get install -y $APT_TIMEOUT update-manager-core >> "$LOG_FILE" 2>&1; then
    alog "ERROR: failed to install update-manager-core"
    # Check if do-release-upgrade exists anyway (might already be installed)
    if ! command -v do-release-upgrade &>/dev/null; then
        alog "FATAL: do-release-upgrade not available and cannot be installed"
        echo "FAILED: do-release-upgrade not available (hop $((HOP_COUNT+1)))" > "$STATE_FILE"
        sudo systemctl disable aella-os-upgrade.service 2>/dev/null || true
        exit 1
    fi
    alog "do-release-upgrade already available, continuing..."
fi

# ---- AELDEV-70680 #8: snapd Pin -1 written EARLY (before legacy_purge) ----
# AELDEV-70504 had this Pin written late (just before do-release-upgrade) and
# also held + masked snapd. That breaks jammy -> noble: do-release-upgrade
# tries to MarkGarbage snapd to transition it, but `apt-mark hold` blocks
# the removal -> "Hold prevents MarkGarbage of snapd" -> upgrader exits
# without advancing. Writing the Pin first means we can purge snapd in the
# legacy_purge loop below, and the Pin guarantees neither dist-upgrade nor
# do-release-upgrade reinstalls it. The late mask/hold block is kept as
# defense-in-depth (no-op once snapd is purged).
sudo tee /etc/apt/preferences.d/no-snapd >/dev/null <<'PIN_EOF'
Package: snapd
Pin: release *
Pin-Priority: -1
PIN_EOF

# ---- Unhold any held packages (e.g., systemd, udev, snapd) ----
# do-release-upgrade fails if critical packages are held back. Specifically,
# `apt-mark hold snapd` (added by an earlier hop's late snapd block) blocks
# the jammy -> noble transition with "Hold prevents MarkGarbage" error.
HELD_PKGS=$(sudo apt-mark showhold 2>/dev/null)
if [[ -n "$HELD_PKGS" ]]; then
    alog "Unholding held packages: $HELD_PKGS"
    echo "$HELD_PKGS" | xargs sudo apt-mark unhold >> "$LOG_FILE" 2>&1
fi

# ---- AELDEV-70680: force --force-confdef --force-confold via apt.conf.d ----
# Written FIRST (before legacy_purge / dist-upgrade) so EVERY apt invocation
# in this hop -- including the legacy_purge below, which may invoke postrm
# scripts that prompt -- inherits non-interactive conffile resolution.
# dpkg honors $DPKG_FORCE only when invoked directly; apt-get -> dpkg
# honors Dpkg::Options from apt.conf.d. Pre-seeding ucf-related debconf
# templates also covers the ucf --three-way prompts (e.g.,
# update-grub-legacy-ec2's grub/update_grub_changeprompt_threeway) that
# bypass dpkg's --force-conf* flags entirely.
sudo tee /etc/apt/apt.conf.d/99auto-os-upgrade-noninteractive >/dev/null <<'APTCONF_EOF'
// AELDEV-70680: keep current conffiles non-interactively for ALL apt operations
Dpkg::Options {
   "--force-confdef";
   "--force-confold";
}
APT::Get::Assume-Yes "true";
APTCONF_EOF
export DPKG_FORCE="confold,confdef"
export UCF_FORCE_CONFFOLD=YES
# AELDEV-70680 #14: also write /etc/ucf.conf so the ucf binary picks up
# the policy from disk, in addition to the env var (which sudo may strip
# from arbitrary apt invocations downstream). conf_force_install=NO means
# "do not install package maintainer's version, keep my local mods" --
# the same outcome as --force-confold for native dpkg conffiles, applied
# to ucf-managed conffiles too (e.g. /etc/apt/apt.conf.d/50unattended-
# upgrades, which broke 10.36.11.20's recovery test 2026-05-07).
sudo tee /etc/ucf.conf >/dev/null <<'UCF_EOF'
# AELDEV-70680 #14: keep local conffile mods during automated OS upgrade
conf_force_install=NO
conf_force_remove=NO
UCF_EOF
# Pre-seed ucf and grub-* templates so any --three-way prompt resolves to
# "keep current" without rendering a curses dialog.
sudo debconf-set-selections >/dev/null 2>&1 <<'DEBCONF_PRE_EOF'
ucf ucf/changeprompt_threeway select keep_current
ucf ucf/changeprompt select keep_current
ucf ucf/show_diff boolean false
grub grub/update_grub_changeprompt_threeway select keep
grub-pc grub-pc/install_devices_empty boolean true
grub-pc grub-pc/install_devices string
grub-efi-amd64 grub2/update_nvram boolean true
libc6 libraries/restart-without-asking boolean true
DEBCONF_PRE_EOF

# ---- AELDEV-70504 + AELDEV-70680: Purge legacy packages that don't transition cleanly ----
# Observed on QA DP 10.36.11.20 (2026-05-01): xenial-era packages survive
# multi-hop upgrades and trigger unmet-dependency errors that wedge
# do-release-upgrade with rc=1 ("Please install all available updates").
# Concrete cases:
#   lxd 2.0.11 (xenial deb)  -> bionic moves lxd to snap; deb-shim
#                               "lxd 1:0.10" leaves lxd-client (deb) without
#                               its lxd binary -> circular Depends fault
#   nodejs 8.x (nodesource)  -> bionic strips python-minimal -> Depends
#                               unsatisfiable; nodesource node_8.x is EOL
#   grub-legacy-ec2 (AELDEV-70680, 2026-05-06): postinst calls
#                               update-grub-legacy-ec2 -> ucf --three-way
#                               on /boot/grub/menu.lst, which prompts
#                               interactively regardless of dpkg
#                               --force-conf* flags or DEBIAN_FRONTEND.
#                               apt-get dist-upgrade then wedges the
#                               whole chain at the curses dialog.
# DPs do not use lxd, nodejs, npm, or grub-legacy-ec2 for any functional
# component (DPs run on KVM/VMware/baremetal, not legacy EC2 PV-GRUB), so
# a blanket purge is safe and idempotent. Run before dist-upgrade so apt
# starts each hop with a clean slate.
LEGACY_PURGE_PKGS="lxd lxd-client nodejs npm libnode64 libnode-dev grub-legacy-ec2 snapd"
purge_list=""
for p in $LEGACY_PURGE_PKGS; do
    if dpkg -l "$p" 2>/dev/null | awk 'NR>5 && $1 ~ /^(ii|hi|iU)/' | grep -q .; then
        purge_list="$purge_list $p"
    fi
done
if [[ -n "${purge_list// /}" ]]; then
    alog "Purging legacy packages that block transitions:$purge_list"
    sudo apt-get purge -y --auto-remove $APT_TIMEOUT $purge_list >> "$LOG_FILE" 2>&1 || \
        alog "WARNING: legacy purge had errors (self-heal will retry)"
else
    alog "No legacy packages to purge"
fi

# ---- apt dist-upgrade (apply ALL pending updates, including held-back packages) ----
# Must use dist-upgrade, not upgrade -- do-release-upgrade refuses if any packages are held back.
# Note: apt.conf.d/99auto-os-upgrade-noninteractive + ucf/grub debconf
# pre-seeds were already written above (before legacy_purge), so this
# dist-upgrade and do-release-upgrade both inherit them. AELDEV-70680.
alog "Running apt dist-upgrade (30s timeout per repo)..."
sudo UCF_FORCE_CONFFOLD=YES DEBIAN_FRONTEND=noninteractive DPKG_FORCE="confold,confdef" \
    apt-get dist-upgrade -y $APT_TIMEOUT >> "$LOG_FILE" 2>&1 || alog "WARNING: apt-get dist-upgrade had errors"

# ---- Ensure Prompt=lts for do-release-upgrade ----
if [[ -f /etc/update-manager/release-upgrades ]]; then
    sudo sed -i 's/^Prompt=.*/Prompt=lts/' /etc/update-manager/release-upgrades
else
    sudo mkdir -p /etc/update-manager
    echo -e "[DEFAULT]\nPrompt=lts" | sudo tee /etc/update-manager/release-upgrades >/dev/null
fi

# ---- Pre-seed debconf to suppress ALL interactive prompts ----
alog "Pre-seeding debconf for non-interactive upgrade..."
sudo debconf-set-selections <<DEBCONF_EOF
grub-efi-amd64 grub2/update_nvram boolean true
grub-pc grub-pc/install_devices_empty boolean true
grub-pc grub-pc/install_devices string
ucf ucf/changeprompt select keep_current
DEBCONF_EOF

# Force ucf to keep old configs without prompting
export UCF_FORCE_CONFFOLD=1

# ---- AELDEV-70504: Gate on external-service availability ----
# do-release-upgrade reaches archive.ubuntu.com (apt), changelogs.ubuntu.com
# (release detection), and -- once snapd is installed (xenial->bionic hop adds
# it) -- api.snapcraft.io. When any service stalls (e.g., snap-store outage
# 2026-04-30), the upgrader wedges with sshd up but PAM blocked behind snapd
# locks. Probe before kicking the hop; abort cleanly so the next boot retries
# instead of leaving the DP unreachable.
check_url() {
    # 60s -- ubuntu archive can return first-byte in 14-20s under DDoS load
    # (validated 2026-05-02 mid-incident). 15s tipped real successful runs
    # into spurious BLOCKED. 60s gives ~3-4x normal headroom; worst-case
    # probe of 3 services is 3*60=180s before BLOCKED lands.
    curl -fsS --max-time 60 -o /dev/null "$1" 2>/dev/null
}
alog "Probing external services required for do-release-upgrade..."
EXT_SERVICES=(
    "http://archive.ubuntu.com/ubuntu/dists/${CURRENT_CODENAME}/Release"
    "http://changelogs.ubuntu.com/meta-release-lts"
)
# api.snapcraft.io is only contacted by do-release-upgrade if snapd is
# installed (its postinst seeds core/core18 from there). With our Pin: -1
# in /etc/apt/preferences.d/no-snapd, snapd never gets installed during
# the bionic transition, so snapcraft is never on the critical path.
# Probe only when snapd is actually present (i.e., pin failed for some
# reason). Avoids false BLOCKED when snapcraft has DDoS-degraded routing
# (validated 2026-05-02: api.snapcraft.io was IPv6-only-resolved and
# unreachable from a bionic DP, even though the upgrade chain didn't
# actually need it).
if dpkg -l snapd 2>/dev/null | grep -q '^ii'; then
    EXT_SERVICES+=("https://api.snapcraft.io/")
fi
EXT_FAILED=()
for url in "${EXT_SERVICES[@]}"; do
    check_url "$url" || EXT_FAILED+=("$url")
done
if [[ ${#EXT_FAILED[@]} -gt 0 ]]; then
    alog "External services unreachable:"
    for u in "${EXT_FAILED[@]}"; do alog "  - $u"; done
    # Conditional status hint -- only show pages relevant to what actually failed
    has_canonical=false
    has_snap=false
    for u in "${EXT_FAILED[@]}"; do
        case "$u" in
            *snapcraft.io*) has_snap=true ;;
            *ubuntu.com*)   has_canonical=true ;;
        esac
    done
    status_msg=""
    [[ "$has_canonical" == "true" ]] && status_msg="$status_msg https://status.canonical.com"
    [[ "$has_snap" == "true" ]]      && status_msg="$status_msg https://status.snapcraft.io"
    alog "Aborting hop -- next boot will retry when upstream recovers."
    alog "To retry now: sudo bash bringup_py3_dp_after_os_upgrade.sh --auto-os-upgrade"
    [[ -n "$status_msg" ]] && alog "Upstream status:$status_msg"
    echo "BLOCKED: external service(s) unreachable: ${EXT_FAILED[*]}" > "$STATE_FILE"
    # exit 0 -- service stays enabled, next boot retries
    exit 0
fi
alog "All external services reachable, continuing..."

# ---- AELDEV-70504/70680: Neutralize snapd (DPs do not use snaps) ----
# DPs run no functional component on snap. xenial base has no snapd, but the
# bionic transition installs it as a Recommends and triggers a seed against
# api.snapcraft.io -- that is the call that hung mid-upgrade in 70504. The
# Pin -1 was already written at the top of this hop (before legacy_purge),
# and snapd was added to LEGACY_PURGE_PKGS so any installed copy was purged.
# Defense-in-depth: if snapd somehow got reinstalled (apt-listbugs hook,
# Recommends override, etc.), stop and mask it here. AELDEV-70680: do NOT
# `apt-mark hold` snapd -- the hold blocks do-release-upgrade's MarkGarbage
# during jammy -> noble (Hold prevents MarkGarbage of snapd:amd64). Pin -1
# already prevents reinstall; hold adds nothing and breaks the upgrader.
if dpkg -l snapd 2>/dev/null | grep -q '^ii'; then
    alog "snapd reappeared despite Pin -1 -- masking (defense-in-depth)"
    sudo systemctl stop  snapd.service snapd.socket            2>/dev/null || true
    sudo systemctl mask  snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true
fi

# ---- Self-heal partial dpkg state from a prior killed hop ----
# If a previous hop was killed mid-dpkg (TimeoutStartSec, power-cycle), apt
# refuses any operation until dpkg is reconfigured. Idempotent on a clean box.
alog "Reconfiguring any half-installed packages from a prior run..."
sudo dpkg --configure -a >> "$LOG_FILE" 2>&1 || alog "WARNING: dpkg --configure -a had errors"
sudo apt-get install -f -y $APT_TIMEOUT >> "$LOG_FILE" 2>&1 || alog "WARNING: apt-get install -f had errors"

# ---- AELDEV-70504: apt health gate before do-release-upgrade ----
# do-release-upgrade refuses with "Please install all available updates" when
# apt has unresolved dependencies, exits rc=1 in 3s, and our FATAL handler
# disables the service. That UX leaves the customer with no clear next step.
# Instead: gate on apt-get check; if still broken after legacy-purge +
# self-heal, abort cleanly with a BLOCKED state file containing the precise
# unmet-deps line so manual recovery is one-line obvious. Service stays
# enabled; next boot retries (after manual fix or external repo recovery).
if ! sudo apt-get check >> "$LOG_FILE" 2>&1; then
    apt_check_out=$(sudo apt-get check 2>&1 | tail -10 | tr '\n' ' ')
    alog "apt-get check FAILED -- broken deps remain after self-heal:"
    alog "  $apt_check_out"
    echo "BLOCKED: apt broken at hop $((HOP_COUNT+1)) -- $apt_check_out" > "$STATE_FILE"
    alog "Manual recovery options:"
    alog "  1. sudo apt --fix-broken install"
    alog "  2. sudo apt purge <conflicting-pkg>"
    alog "Then re-run: sudo bash bringup_py{2,3}_dp_after_os_upgrade.sh --auto-os-upgrade"
    # exit 0 -- service stays enabled, next boot retries
    exit 0
fi
alog "apt-get check passed -- proceeding to do-release-upgrade"

# ---- AELDEV-70504: neutralize apport-cli for non-interactive upgrade ----
# do-release-upgrade invokes /usr/bin/apport-cli to ask whether to send a
# bug report when a related package (snapd "No candidate ver") trips its
# crash hook. Under systemd there is no TTY -> apport-cli aborts with
# termios.error -> do-release-upgrade exits rc=1 -> chain wedged.
# Replace apport-cli with a no-op shim for the duration of the chain.
sudo rm -f /var/crash/*.crash 2>/dev/null || true
sudo systemctl stop apport.service 2>/dev/null || true
echo "enabled=0" | sudo tee /etc/default/apport >/dev/null 2>&1 || true
if [[ -x /usr/bin/apport-cli ]] && ! grep -q 'AELDEV-70504-shim' /usr/bin/apport-cli 2>/dev/null; then
    sudo cp -p /usr/bin/apport-cli /usr/bin/apport-cli.bak.aellaosupgrade 2>/dev/null || true
    sudo tee /usr/bin/apport-cli >/dev/null <<'APORT_SHIM_EOF'
#!/bin/sh
# AELDEV-70504-shim -- non-interactive no-op during auto-os-upgrade chain
exit 0
APORT_SHIM_EOF
    sudo chmod +x /usr/bin/apport-cli
    alog "Replaced /usr/bin/apport-cli with no-op shim (backup: apport-cli.bak.aellaosupgrade)"
fi

# ---- AELDEV-70504: inject UA via sitecustomize.py for ALL python3 procs ----
# Ubuntu's archive.ubuntu.com began returning HTTP 403 to Python-urllib's
# default User-Agent (~2026-05). do-release-upgrade's url_downloadable()
# probes the next-release Release file via urllib.request.urlopen with
# default UA -> 403 -> upgrader concludes "no mirror has bionic/focal/jammy"
# and aborts with "ubuntu-minimal could not be located".
# do-release-upgrade downloads its own DistUpgrade tarball at runtime, so
# patching the system /usr/lib/python3/dist-packages/DistUpgrade/utils.py
# is bypassed. Instead, append a Request.__init__ monkey-patch to the
# system sitecustomize.py for whichever python3.X is current. site.py
# auto-imports sitecustomize on every Python start, so all subprocesses
# (including the downloaded upgrader) inherit the UA fix.
sc_target=""
for sc in /usr/lib/python3.5/sitecustomize.py \
          /usr/lib/python3.6/sitecustomize.py \
          /usr/lib/python3.8/sitecustomize.py \
          /usr/lib/python3.10/sitecustomize.py \
          /usr/lib/python3.12/sitecustomize.py; do
    [[ -f "$sc" ]] && sc_target="$sc"
done
if [[ -n "$sc_target" ]] && ! sudo grep -q 'AELDEV-70504-UA' "$sc_target" 2>/dev/null; then
    sudo tee -a "$sc_target" >/dev/null <<'SC_UA_EOF'

# AELDEV-70504-UA: archive.ubuntu.com 403s default Python-urllib UA.
# Inject a real-looking UA on every urllib.request.Request so
# do-release-upgrade's mirror-Release HEAD probes succeed.
try:
    import urllib.request as _ur_aelda
    _orig_init_aelda = _ur_aelda.Request.__init__
    def _patched_init_aelda(self, *args, **kwargs):
        _orig_init_aelda(self, *args, **kwargs)
        if not self.has_header("User-agent"):
            self.add_header("User-Agent", "Mozilla/5.0 (compatible; ubuntu-release-upgrader)")
    _ur_aelda.Request.__init__ = _patched_init_aelda
except Exception:
    pass
SC_UA_EOF
    alog "Appended urllib UA fix to $sc_target (AELDEV-70504-UA)"
fi

# ---- AELDEV-70680 #6: gate on /boot space ----
# do-release-upgrade unpacks a new kernel (~80MB) plus initramfs (~200MB
# expanded). Older customer installs commonly have a 200-500MB /boot
# partition that's already 70%+ full from accumulated kernel images.
# Mid-hop ENOSPC on /boot leaves a half-installed initramfs and an
# unbootable host. Rather than silently failing, gate cleanly: if /boot
# is a separate mount AND has < 300MB free, abort BLOCKED with a one-line
# remediation hint. Auto-purge of old kernels is too risky (could remove
# the running kernel). Service stays enabled; admin clears space + retries.
if mountpoint -q /boot 2>/dev/null; then
    boot_avail_kb=$(df -kP /boot 2>/dev/null | awk 'NR==2 {print $4}')
    boot_avail_kb=${boot_avail_kb:-0}
    if [[ "$boot_avail_kb" -lt 300000 ]]; then
        boot_avail_mb=$((boot_avail_kb / 1024))
        alog "/boot partition has only ${boot_avail_mb}MB free (need >=300MB for kernel install)"
        alog "Manual fix: sudo apt-get autoremove --purge   OR   sudo dpkg -l 'linux-image-*' | grep ^ii | awk '{print \$2}' | sort -V"
        echo "BLOCKED: /boot has only ${boot_avail_mb}MB free; need >=300MB before do-release-upgrade hop $((HOP_COUNT+1))" > "$STATE_FILE"
        # exit 0 -- service stays enabled, admin clears space + reboots / re-runs
        exit 0
    fi
    alog "/boot has ${boot_avail_kb}KB free -- OK"
fi

# ---- AELDEV-70680 #3: gate on /var/run/reboot-required ----
# do-release-upgrade refuses to run with rc=1 ("You have not rebooted after
# updating a package which requires a reboot. Please reboot before
# upgrading.") whenever apt has installed a kernel/glibc/libc6/etc. without
# a subsequent boot. The kernel install can be from a pre-existing host
# state (QA's 10.36.11.20: linux-image-5.4.0-216-generic mtime predates the
# auto-upgrade chain) OR from the dist-upgrade we just ran. Either way,
# without rebooting first, do-release-upgrade exits 1 in 3s and the script
# previously declared FATAL and disabled the service. Instead: detect the
# marker, reboot cleanly so the next boot retries with a fresh kernel.
# Service stays enabled (we exit 0, not FATAL).
if [[ -f /var/run/reboot-required ]]; then
    pending_pkgs=$(cat /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')
    pending_pkgs=${pending_pkgs:-unknown}
    alog "/var/run/reboot-required present (pkgs: $pending_pkgs)"
    alog "do-release-upgrade refuses to run until rebooted -- rebooting; service will retry on next boot"
    echo "REBOOT_PENDING: rebooting before do-release-upgrade hop $((HOP_COUNT+1)) (pkgs: $pending_pkgs)" > "$STATE_FILE"
    sync
    sleep 5
    sudo reboot
    # systemd kills us; exit 0 in case sudo returns first.
    exit 0
fi

# ---- do-release-upgrade ----
# Note: apt.conf.d/99auto-os-upgrade-noninteractive + debconf pre-seeds were
# already written above (before dist-upgrade), so do-release-upgrade inherits
# them. AELDEV-70680.
# AELDEV-70680 #9: do NOT pre-increment hop_count. Old code wrote
# `echo $((HOP_COUNT+1)) > hop_count` BEFORE do-release-upgrade, so any
# helper invocation (including a re-run after a transient probe BLOCKED,
# a #3 reboot-required gate, an apt-check FAIL, or an admin manually
# restarting the service) burned a hop. With MAX_HOPS=6 and a real chain
# only needing 4 hops (xenial -> bionic -> focal -> jammy -> noble), 2-3
# debug cycles inflate hop_count past the ceiling and trigger
# "Exceeded maximum hop count" FATAL. Fix: increment ONLY after we've
# confirmed the OS version actually changed, so failed/aborted attempts
# are free.
attempted_hop=$((HOP_COUNT+1))
alog "Starting do-release-upgrade (non-interactive) for attempt #${attempted_hop}..."
alog "Logging do-release-upgrade output to: ${AUTO_UPGRADE_DIR}/hop_${HOP_COUNT}_upgrade.log"

sudo UCF_FORCE_CONFFOLD=1 DEBIAN_FRONTEND=noninteractive DPKG_FORCE="confold,confdef" \
    do-release-upgrade -f DistUpgradeViewNonInteractive 2>&1 | tee -a "${AUTO_UPGRADE_DIR}/hop_${HOP_COUNT}_upgrade.log" >> "$LOG_FILE"
upgrade_rc=${PIPESTATUS[0]}

# Check if the OS version actually changed
POST_VERSION=$(grep VERSION_ID /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown")
POST_CODENAME=$(grep UBUNTU_CODENAME /etc/os-release 2>/dev/null | cut -d= -f2 || echo "unknown")

alog "do-release-upgrade exited with code $upgrade_rc"
alog "Pre-upgrade OS:  $CURRENT_VERSION ($CURRENT_CODENAME)"
alog "Post-upgrade OS: $POST_VERSION ($POST_CODENAME)"

if [[ "$POST_VERSION" == "$CURRENT_VERSION" ]]; then
    # Version did NOT change -- do-release-upgrade failed
    alog "FATAL: do-release-upgrade did not upgrade OS (still $CURRENT_VERSION)"
    alog "NOT rebooting -- manual intervention required."
    alog "Check hop log: ${AUTO_UPGRADE_DIR}/hop_${HOP_COUNT}_upgrade.log"
    echo "FAILED: do-release-upgrade did not upgrade OS (still $CURRENT_VERSION, exit code $upgrade_rc)" > "$STATE_FILE"
    echo "DO_RELEASE_UPGRADE_EXIT=$upgrade_rc" > "${AUTO_UPGRADE_DIR}/last_hop_status"
    sudo systemctl disable aella-os-upgrade.service 2>/dev/null || true
    exit 1
fi

# OS version changed -- upgrade succeeded; commit hop counter + history, reboot.
HOP_COUNT=$attempted_hop
echo "$HOP_COUNT" > "${AUTO_UPGRADE_DIR}/hop_count"
alog "do-release-upgrade succeeded: $CURRENT_VERSION -> $POST_VERSION ($POST_CODENAME)"
echo "HOP_${HOP_COUNT}: $CURRENT_VERSION -> $POST_VERSION (rc=$upgrade_rc)" >> "${AUTO_UPGRADE_DIR}/hop_history"
alog "Rebooting in 5 seconds..."
sleep 5
sync
sudo reboot
HELPER_EOF

    chmod +x "$AUTO_UPGRADE_SCRIPT"
    log "Helper script written: $AUTO_UPGRADE_SCRIPT"

    # Step 7: Write the systemd service unit
    log "Writing /etc/systemd/system/$AUTO_UPGRADE_SERVICE"
    cat > "/etc/systemd/system/$AUTO_UPGRADE_SERVICE" << 'SERVICE_EOF'
[Unit]
Description=Aella Automated OS Upgrade Chain (16.04 -> 24.04)
After=network-online.target systemd-resolved.service
Wants=network-online.target
ConditionPathExists=/opt/aelladata/os-upgrade/auto_os_upgrade.sh

[Service]
Type=oneshot
RemainAfterExit=no
Environment=DEBIAN_FRONTEND=noninteractive
ExecStart=/opt/aelladata/os-upgrade/auto_os_upgrade.sh
StandardOutput=journal+console
StandardError=journal+console
# AELDEV-70504: per-hop ceiling. Normal hop is 20-40 min; 90 min is 2x worst
# case. Without this, a stuck do-release-upgrade locks the box forever. When
# systemd kills it, dpkg state is auto-reconfigured at the start of the next
# boot's hop (see HEREDOC dpkg --configure -a above).
TimeoutStartSec=5400
# Service is oneshot but boot-triggered: do not auto-restart -- the next boot
# (after reboot OR after systemd kill) is the retry, with fresh DNS state.
Restart=no

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable "$AUTO_UPGRADE_SERVICE" 2>/dev/null || true
    log "Systemd service enabled: $AUTO_UPGRADE_SERVICE"

    # Step 8: Initialize OR resume state with auto-corruption detection.
    # AELDEV-70504: re-running --auto-os-upgrade is the customer's recovery
    # path. We auto-detect whether to resume (preserve hop_count + start_version
    # so MAX_HOPS counts correctly and telemetry stays intact) or fresh-init
    # (state files missing OR corrupted). No separate --reset flag -- the
    # script always Does The Right Thing on re-invocation.
    local current_version
    current_version=$(grep VERSION_ID /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown")

    # Validate existing state: hop_count must be 0..10, start_version NN.NN.
    # Anything else (missing file, garbage, manual edit gone wrong) = corrupt.
    local state_valid=false
    if [[ -f "${AUTO_UPGRADE_DIR}/hop_count" ]] && [[ -f "${AUTO_UPGRADE_DIR}/start_version" ]]; then
        local prev_hop_raw prev_ver_raw
        prev_hop_raw=$(cat "${AUTO_UPGRADE_DIR}/hop_count" 2>/dev/null | tr -d '[:space:]')
        prev_ver_raw=$(cat "${AUTO_UPGRADE_DIR}/start_version" 2>/dev/null | tr -d '[:space:]')
        if [[ "$prev_hop_raw" =~ ^[0-9]+$ ]] && [[ "$prev_hop_raw" -le 10 ]] \
           && [[ "$prev_ver_raw" =~ ^[0-9]+\.[0-9]+$ ]]; then
            state_valid=true
        fi
    fi

    local resume_mode=false
    if [[ "$state_valid" == "true" ]]; then
        local prev_hop_count prev_start_version prev_state
        prev_hop_count=$(cat "${AUTO_UPGRADE_DIR}/hop_count")
        prev_start_version=$(cat "${AUTO_UPGRADE_DIR}/start_version")
        prev_state=$(cat "${AUTO_UPGRADE_DIR}/state" 2>/dev/null || echo "unknown")
        log "Resuming existing auto-os-upgrade run:"
        log "  Previous hop_count:     $prev_hop_count"
        log "  Original start version: $prev_start_version"
        log "  Last state:             $prev_state"
        log "  Current OS:             $current_version"
        echo "RESUMED at $current_version (prev state: $prev_state)" > "${AUTO_UPGRADE_DIR}/state"
        resume_mode=true
    else
        if [[ -f "${AUTO_UPGRADE_DIR}/hop_count" ]] || [[ -f "${AUTO_UPGRADE_DIR}/start_version" ]]; then
            log "WARNING: existing state files are corrupted -- auto-resetting"
            log "  hop_count='$(head -c 50 "${AUTO_UPGRADE_DIR}/hop_count" 2>/dev/null || echo missing)'"
            log "  start_version='$(head -c 50 "${AUTO_UPGRADE_DIR}/start_version" 2>/dev/null || echo missing)'"
        fi
        log "Initializing fresh auto-os-upgrade state..."
        echo "0" > "${AUTO_UPGRADE_DIR}/hop_count"
        echo "INITIALIZED" > "${AUTO_UPGRADE_DIR}/state"
        echo "$current_version" > "${AUTO_UPGRADE_DIR}/start_version"
    fi

    log ""
    log "========================================================================"
    if [[ "$resume_mode" == "true" ]]; then
        log "  Auto OS Upgrade RESUMED"
    else
        log "  Auto OS Upgrade Configured"
    fi
    log "  Current:  Ubuntu $current_version"
    log "  Target:   Ubuntu 24.04 (noble)"
    log "  Helper:   $AUTO_UPGRADE_SCRIPT"
    log "  Service:  $AUTO_UPGRADE_SERVICE"
    log "  Log:      $AUTO_UPGRADE_LOG"
    log "  State:    ${AUTO_UPGRADE_DIR}/state"
    log "========================================================================"
    log ""
    if [[ "$resume_mode" == "true" ]]; then
        log "Resuming chain from current OS. Monitor: tail -f $AUTO_UPGRADE_LOG"
    else
        log "Starting first upgrade cycle now..."
        log "The machine will reboot shortly. Monitor: tail -f $AUTO_UPGRADE_LOG"
    fi

    # Step 9: Start the cycle (will reboot when do-release-upgrade succeeds)
    systemctl start "$AUTO_UPGRADE_SERVICE"
}

###############################################################################
# MAIN
###############################################################################
main() {
    parse_args "$@"
    setup_logging

    # Pre-upgrade cleanup mode: remove dead repos and exit
    if [[ "$PRE_UPGRADE_CLEANUP" == "true" ]]; then
        pre_upgrade_cleanup
        exit 0
    fi

    # Auto OS upgrade mode: install systemd service for unattended upgrade chain
    if [[ "$AUTO_OS_UPGRADE" == "true" ]]; then
        setup_auto_os_upgrade
        exit 0
    fi

    # AELDEV-71912: reclaim-only mode -- drop the legacy Docker overlay2 store and
    # exit. No download/install: just the guarded, idempotent reclaim. Reclaims
    # THIS node; with --worker-ips on a master/AIO it also sweeps the workers, so
    #   bringup_py3_dp_after_os_upgrade.sh --reclaim-overlay2 --worker-ips a,b,c
    # is a one-shot cluster-wide cleanup (add --dry-run to preview). Workers are
    # invoked WITHOUT --worker-ips, so they only reclaim themselves (no recursion).
    if [[ "$RECLAIM_OVERLAY2_ONLY" == "true" ]]; then
        reclaim_legacy_docker_overlay2
        if [[ "$WORKER_MODE" != "true" && -n "$WORKER_IPS" ]]; then
            reclaim_overlay2_on_workers
        fi
        exit 0
    fi

    # AELDEV-73583: relabel-only mode -- (re)run the elastic pre-labeling on a
    # DL-master/AIO and show the resulting labels, then exit. For the by-hand
    # (section 4c) flow where workers join AFTER the master's bringup already
    # ran its labeling pass: run this on the master once all workers are Ready.
    # Idempotent; labels only nodes with preserved ES data; skips standby and
    # data-less nodes (ES coordinate candidates). No removals.
    if [[ "$RELABEL_ELASTIC_ONLY" == "true" ]]; then
        if [[ $EUID -ne 0 ]]; then die "Must run as root"; fi
        detect_role
        [[ "$ROLE" == "DL-master" || "$ROLE" == "AIO" ]] || \
            die "--relabel-elastic runs on a DL-master or AIO node (this node: ${ROLE})"
        pre_label_dl_elastic_nodes
        log "Current node labels:"
        kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -L elastic,coordinate,standby,master 2>&1 | \
            while IFS= read -r line; do log "  $line"; done
        exit 0
    fi

    # Download from ACPS (or use local artifacts if pre-staged)

    log "Version: $VERSION | Role: ${ROLE:-auto-detect} | Worker mode: $WORKER_MODE"

    preflight_checks

    # Phase 1: Download
    download_artifacts

    # Phase 2: Python 3
    install_python3
    install_pip3_packages

    # Phase 3: Docker + containerd
    install_docker_containerd

    # Phase 3.5: load local image tarballs into containerd (dark-site, --skip-download only)
    load_local_images

    # Phase 4: Kubernetes 1.31
    install_kubernetes

    # Phase 5: Helm 3.17
    install_helm

    # Phase 6: UVP
    install_uvp

    # Phase 7: System prep
    prepare_system

    # Phase 8: Aella services
    start_aella_services

    # Phase 9-10: K8s master init + deploy (master/AIO only, not in worker mode)
    if [[ "$WORKER_MODE" != "true" ]]; then
        case "$ROLE" in
            DR-master|DL-master|AIO)
                init_k8s_master
                deploy_k8s_services
                ;;
        esac
    fi

    # Worker join (worker mode only)
    if [[ "$WORKER_MODE" == "true" ]]; then
        join_k8s_cluster
    fi

    # Phase 11: elasticdump
    install_elasticdump

    # AELDEV-70457: final python3 symlink safety net. install_elasticdump
    # pulls nodejs which has rdep on python-minimal -- its postinst can
    # recreate /usr/bin/python -> python2.7. Reset to python3 here so
    # any subsequent aellad restart picks the right interpreter.
    ensure_python3_symlink

    # Phase 12: Validate
    validate_all || true

    # Phase 13: Orchestrate workers + standby (master only, after self is fully up)
    if [[ "$WORKER_MODE" != "true" && ( -n "$WORKER_IPS" || -n "$STANDBY_IPS" ) ]]; then
        # AELDEV-74638: verify the join-token endpoint is actually up before
        # spending 60+ min orchestrating workers that would hang on it.
        wait_for_da_restful_8003
        orchestrate_workers
    fi

    # AELDEV-71573 fix #15: pre-label DL master + workers with elastic=enabled
    # to break the cluster-controller red-state deadlock that arises on
    # darksite py2->py3 (preserved esdata with unassigned shards keeps ES RED,
    # which gates the controller's own labeling step). No-op on DR-* and on
    # fresh installs where controller would label anyway. See function header.
    # NOTE: fix #16 (kafka stabilization) now runs INSIDE deploy_k8s_services
    # to fire while the race is still happening, NOT after the 60+ min worker
    # orchestration window.
    if [[ "$WORKER_MODE" != "true" ]]; then
        pre_label_dl_elastic_nodes
    fi

    # Phase 14: Wait for aella_cli to report "All pods are running"
    # (master/AIO only; workers skip).
    wait_for_system_ready || true

    # AELDEV-71912: post-convergence overlay2 reclaim (master/AIO only). The early
    # call in install_docker_containerd (Phase 3) runs BEFORE kube-deploy populates
    # containerd's k8s.io, so on the 16.04->24.04 path (no prior dockershim k8s.io)
    # its strand-guard skips and the ~100G legacy overlay2 store is left behind.
    # Running it HERE -- after the whole cluster is up -- guarantees k8s.io is
    # populated and pods are confirmed on containerd, so the guard passes and the
    # store is reclaimed + Docker flips to the snapshotter driver. Workers are
    # swept in a separate loop FIRST (reclaim_overlay2_on_workers), since they too
    # are only safe to reclaim once converged; then the master reclaims itself.
    # Idempotent: no-op where the early pass already flipped it (24.04 py2->py3).
    # Also runs AFTER the aella-da-services .deb postinst, so its
    # write_docker_daemon_json is the final writer -- the snapshotter flag sticks.
    # AELDEV-71912: post-convergence overlay2 reclaim (master/AIO only). Gated on
    # THIS node still being stuck in legacy overlay2, so every already-flipped
    # path (24.04 py2->py3, fresh, re-run) stays a TRUE no-op here -- zero worker
    # I/O, zero log noise, no behavior change vs the tested baseline. Only the
    # cold 16.04->24.04 case (master still overlay2) sweeps the workers + reclaims
    # the master; a cluster upgrades uniformly, so a clean master implies clean
    # workers. Best-effort: the cluster is already converged, so a cleanup hiccup
    # must NOT fail the bringup -- the subshell isolates the reclaim's
    # die-on-docker-restart-failure (the early Phase-3 call keeps its hard-fail
    # since docker is needed for the rest of bringup; the worker sweep is already
    # non-fatal per worker).
    if [[ "$WORKER_MODE" != "true" ]] \
       && grep -q 'VERSION_ID="24.04"' /etc/os-release 2>/dev/null \
       && [[ "$(docker info 2>/dev/null | awk -F': ' '/Storage Driver/{print $2}' | tr -d ' ')" == "overlay2" ]]; then
        reclaim_overlay2_on_workers
        ( reclaim_legacy_docker_overlay2 ) || log "AELDEV-71912: post-convergence overlay2 reclaim on master hit an error (non-fatal; cluster already converged)"
    fi

    # AELDEV-74638 (QA Issue #3): this banner MUST go through log(), not bare
    # echo. Detached (master/AIO) runs redirect stdout to /dev/null (the
    # AELDEV-71725 duplicate-line fix), so an echo'd banner never reaches
    # LOG_FILE -- while detach_guard explicitly tells the operator to wait for
    # "Bringup complete:" in that log. A fully successful bringup then looks
    # stuck forever. (Worker-mode runs were unaffected: they run inline and the
    # orchestrator logs their stdout.)
    log ""
    log "========================================================================"
    log "  Bringup complete: $(date)"
    log "  Role: $ROLE"
    log "  Version: $VERSION"
    log "  Log: $LOG_FILE"
    log "========================================================================"
}

# AELDEV-71573: self-detach the master/AIO bringup so it survives losing its
# controlling terminal (SSH disconnect, console drop, or an operator Ctrl-C'ing
# what looks like a hang). A plain foreground `sudo bash ...` is killed by SIGHUP
# during the "Install Docker" phase's ~90s silent stateful-drain window, leaving
# a half-upgraded DP. Re-exec under setsid (new session, no controlling tty) with
# all output to LOG_FILE, then hand the operator's shell back. Skipped for:
#   --worker-mode    : master orchestration runs this synchronously over SSH and
#                      reads its output live; detaching would break that path.
#   --pre-upgrade-cleanup / --auto-os-upgrade : quick setup modes, stay inline.
#   --dry-run / --help / -h : inspection modes -- keep output on the terminal.
# Falls back to running inline (no detach) if setsid is unavailable.
detach_guard() {
    case " $* " in
        *" --worker-mode "*|*" --pre-upgrade-cleanup "*|*" --auto-os-upgrade "*) return 0 ;;
        *" --reclaim-overlay2 "*|*" --relabel-elastic "*) return 0 ;;
        *" --dry-run "*|*" --help "*|*" -h "*) return 0 ;;
    esac
    [[ -n "${BRINGUP_DETACHED:-}" ]] && return 0
    command -v setsid >/dev/null 2>&1 || return 0
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "AELDEV-71573: detaching bringup so it survives SSH/console disconnect."
    echo "  Monitor:    tail -f $LOG_FILE"
    echo "  Completes when the log shows:  Bringup complete:"
    # AELDEV-71725: redirect stdout to /dev/null, ONLY stderr to LOG_FILE.
    # Previously stdout was redirected to LOG_FILE, which collided with
    # log()'s explicit `>> "$LOG_FILE"` write (and `... | tee -a "$LOG_FILE"`
    # patterns) -- every log line and every tee'd command appeared TWICE
    # in the log. log()'s direct file write + tee's -a write are sufficient;
    # any stray stdout from sub-commands not intended for the log is now
    # discarded cleanly. stderr (apt warnings, kubectl errors, etc.) still
    # captured for postmortem.
    BRINGUP_DETACHED=1 setsid bash "$0" "$@" </dev/null >/dev/null 2>>"$LOG_FILE" &
    exit 0
}

detach_guard "$@"

main "$@"
