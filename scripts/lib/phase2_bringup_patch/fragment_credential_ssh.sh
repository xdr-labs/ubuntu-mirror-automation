# shellcheck shell=bash
###############################################################################
# PHASE 2 CREDENTIAL + SSH HOST-KEY HARDENING (project patch layer)
###############################################################################
PHASE2_SSH_STATE_DIR="${PHASE2_SSH_STATE_DIR:-/var/lib/dp-phase2-bringup}"
PHASE2_SSH_KNOWN_HOSTS_FILE="${PHASE2_SSH_KNOWN_HOSTS_FILE:-${PHASE2_SSH_STATE_DIR}/known_hosts}"
PHASE2_WORKER_PASSWORD_FILE="${PHASE2_WORKER_PASSWORD_FILE:-}"
PHASE2_WORKER_PASSWORD_PRIVATE_DIR="${PHASE2_WORKER_PASSWORD_PRIVATE_DIR:-${PHASE2_SSH_STATE_DIR}}"

init_phase2_ssh_known_hosts() {
    # Persistent project-owned known_hosts only. Do NOT fall back to /tmp —
    # that silently loses changed-key continuity across executions.
    local d="${PHASE2_SSH_STATE_DIR}" f base
    mkdir -p "$d" || die "SSH_KNOWN_HOSTS=FAIL reason=state_dir path=${d}"
    chmod 0700 "$d" || die "SSH_KNOWN_HOSTS=FAIL reason=state_dir_mode path=${d}"
    f="${d}/known_hosts"
    if [[ ! -f "$f" ]]; then
        touch "$f" || die "SSH_KNOWN_HOSTS=FAIL reason=create path=${f}"
    fi
    chmod 0600 "$f" || die "SSH_KNOWN_HOSTS=FAIL reason=known_hosts_mode path=${f}"
    export PHASE2_SSH_KNOWN_HOSTS_FILE="$f"
    export PHASE2_SSH_STATE_DIR="$d"
    base="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${PHASE2_SSH_KNOWN_HOSTS_FILE} -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=240 -o TCPKeepAlive=yes"
    SSH_OPTS="$base"
    SCP_OPTS="$base"
}

phase2_ssh_transport_opts() {
    printf '%s' \
        "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${PHASE2_SSH_KNOWN_HOSTS_FILE} -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=240 -o TCPKeepAlive=yes"
}

# Legacy --worker-password is accepted for manual callers only. Production paths
# must pass --worker-password-file; argv passwords are migrated to a mode-0600
# private file and cleared from shell variables before orchestration.
finalize_worker_password_credential() {
    local d f
    if [[ -n "${WORKER_PASSWORD:-}" ]]; then
        d="${PHASE2_WORKER_PASSWORD_PRIVATE_DIR}"
        if ! mkdir -p "$d" 2>/dev/null; then
            d="${TMPDIR:-/tmp}/dp-phase2-bringup-${$:-$$}"
            mkdir -p "$d" || die "WORKER_PASSWORD_FILE=FAIL reason=private_dir"
        fi
        chmod 0700 "$d" 2>/dev/null || true
        if [[ -z "${PHASE2_WORKER_PASSWORD_FILE:-}" ]]; then
            f="$(mktemp "${d}/worker-password.XXXXXX")" \
                || die "WORKER_PASSWORD_FILE=FAIL reason=temp_file"
            chmod 0600 "$f"
            printf '%s' "$WORKER_PASSWORD" >"$f" \
                || die "WORKER_PASSWORD_FILE=FAIL reason=write"
            PHASE2_WORKER_PASSWORD_FILE="$f"
        fi
        unset WORKER_PASSWORD
    fi
    if [[ -n "${PHASE2_WORKER_PASSWORD_FILE:-}" ]]; then
        [[ -f "$PHASE2_WORKER_PASSWORD_FILE" && -r "$PHASE2_WORKER_PASSWORD_FILE" ]] \
            || die "WORKER_PASSWORD_FILE=UNREADABLE path=${PHASE2_WORKER_PASSWORD_FILE}"
        chmod 0600 "$PHASE2_WORKER_PASSWORD_FILE" 2>/dev/null || true
    fi
}

require_worker_password_file_for_remote_orchestration() {
    if has_remote_orchestration_nodes && [[ -z "${PHASE2_WORKER_PASSWORD_FILE:-}" ]]; then
        die "--worker-ips/--standby requires --worker-password-file"
    fi
}

phase2_acps_direct_download_fail_closed() {
    die "ACPS_DIRECT_DOWNLOAD=FAIL Mirror Manager required; re-run with --skip-download and staged artifacts"
}
