# shellcheck shell=bash
###############################################################################
# PHASE 2 COMPATIBILITY: Ubuntu prerequisites + cluster readiness gates
###############################################################################
PHASE2_PREREQ_ARTIFACT_NAME="${PHASE2_PREREQ_ARTIFACT_NAME:-phase2-ubuntu-prerequisites.tar.gz}"
PHASE2_CRITICAL_PYTHON_IMPORTS="${PHASE2_CRITICAL_PYTHON_IMPORTS:-click flask werkzeug OpenSSL gevent kazoo pyinotify}"
MASTER_TOKEN_API_PORT="${MASTER_TOKEN_API_PORT:-8003}"
MASTER_TOKEN_API_WAIT_SECONDS="${MASTER_TOKEN_API_WAIT_SECONDS:-180}"
CLUSTER_JOIN_WAIT_SECONDS="${CLUSTER_JOIN_WAIT_SECONDS:-300}"
# Bounded per-target Ready wait used by orchestrate_workers. Tests may lower this.
CLUSTER_TARGET_READY_ATTEMPTS="${CLUSTER_TARGET_READY_ATTEMPTS:-60}"
CLUSTER_TARGET_READY_SLEEP_SECONDS="${CLUSTER_TARGET_READY_SLEEP_SECONDS:-5}"
# Local worker/standby completion evidence. Paths are overrideable for tests only.
PHASE2_KUBELET_CONF_PATH="${PHASE2_KUBELET_CONF_PATH:-/etc/kubernetes/kubelet.conf}"
PHASE2_FLANNEL_INTERFACE="${PHASE2_FLANNEL_INTERFACE:-flannel.1}"

# WORKER_PASSWORD is the SSH password for ALL remote orchestration nodes
# (workers from --worker-ips and standby from --standby). The CLI flag name
# is kept for compatibility; it is not worker-only.

has_remote_orchestration_nodes() {
    [[ -n "${WORKER_IPS:-}" || -n "${STANDBY_IPS:-}" ]]
}

_phase2_trim_ip() {
    local s="${1:-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Split a comma-separated IP list. Empty tokens after trim fail closed.
# Does not attempt a general network parser.
_phase2_split_ip_csv() {
    local csv="${1:-}"
    local -n _phase2_split_out="$2"
    _phase2_split_out=()
    csv="$(_phase2_trim_ip "$csv")"
    [[ -n "$csv" ]] || return 0
    # Bash `read -a` drops a trailing empty field, so reject edge commas
    # before splitting. Internal empty/whitespace-only fields are caught below.
    if [[ "$csv" == ,* || "$csv" == *, ]]; then
        log "ERROR: REMOTE_ORCH_NODES=FAIL reason=empty_ip"
        return 1
    fi
    local IFS=','
    local -a _phase2_parts=()
    read -ra _phase2_parts <<< "$csv"
    local _phase2_p _phase2_t
    for _phase2_p in "${_phase2_parts[@]}"; do
        _phase2_t="$(_phase2_trim_ip "$_phase2_p")"
        if [[ -z "$_phase2_t" ]]; then
            log "ERROR: REMOTE_ORCH_NODES=FAIL reason=empty_ip"
            return 1
        fi
        _phase2_split_out+=("$_phase2_t")
    done
    return 0
}

# Canonical remote-node lists. Fail-closed policy:
#   duplicate worker IP          -> FAIL
#   duplicate standby IP         -> FAIL
#   same IP as worker and standby -> FAIL (conflicting desired roles)
# Harmless exact duplicates are NOT silently deduplicated: this is an
# upgrade orchestration path. Rewrites WORKER_IPS / STANDBY_IPS with
# whitespace normalized. Workers remain first; standby remains second.
normalize_remote_orchestration_nodes() {
    local -a _phase2_workers=() _phase2_standbys=()
    local _phase2_ip
    local -A _phase2_seen_worker=() _phase2_seen_standby=()

    _phase2_split_ip_csv "${WORKER_IPS:-}" _phase2_workers || return 1
    _phase2_split_ip_csv "${STANDBY_IPS:-}" _phase2_standbys || return 1

    for _phase2_ip in "${_phase2_workers[@]}"; do
        if [[ -n "${_phase2_seen_worker[$_phase2_ip]:-}" ]]; then
            log "ERROR: REMOTE_ORCH_NODES=FAIL reason=duplicate_worker_ip"
            return 1
        fi
        _phase2_seen_worker[$_phase2_ip]=1
    done
    for _phase2_ip in "${_phase2_standbys[@]}"; do
        if [[ -n "${_phase2_seen_standby[$_phase2_ip]:-}" ]]; then
            log "ERROR: REMOTE_ORCH_NODES=FAIL reason=duplicate_standby_ip"
            return 1
        fi
        if [[ -n "${_phase2_seen_worker[$_phase2_ip]:-}" ]]; then
            log "ERROR: REMOTE_ORCH_NODES=FAIL reason=role_conflict_ip"
            return 1
        fi
        _phase2_seen_standby[$_phase2_ip]=1
    done

    local IFS=','
    WORKER_IPS="${_phase2_workers[*]}"
    STANDBY_IPS="${_phase2_standbys[*]}"
    log "REMOTE_ORCH_NODES workers=${#_phase2_workers[@]} standby=${#_phase2_standbys[@]}"
    return 0
}

_phase2_canonical_role() {
    case "${1:-}" in
        DA-master) printf '%s' 'DR-master' ;;
        DA-worker) printf '%s' 'DR-worker' ;;
        *) printf '%s' "${1:-}" ;;
    esac
}

phase2_is_local_ipv4_address() {
    local candidate="${1:-}"
    [[ -n "$candidate" ]] || return 1
    command -v ip >/dev/null 2>&1 || return 1
    ip -o -4 addr show 2>/dev/null \
        | awk '{split($4,a,"/"); print a[1]}' \
        | grep -Fxq -- "$candidate"
}

# Read-only pre-mutation identity gate for every remotely orchestrated node.
# The master must never force a role override onto a different DP role (or
# accidentally target one of its own local addresses).
validate_remote_role_identity() {
    local worker_ip="${1:-}"
    local expected_role="${2:-}"
    local actual_role="" expected_canonical actual_canonical
    if [[ -z "$worker_ip" || -z "$expected_role" ]]; then
        log "WORKER_RESULT ip=${worker_ip:-unknown} result=FAIL reason=role_probe"
        return 1
    fi
    if phase2_is_local_ipv4_address "$worker_ip"; then
        log "WORKER_RESULT ip=${worker_ip} role=${expected_role} result=FAIL reason=self_ip"
        return 1
    fi
    if ! declare -F worker_ssh >/dev/null 2>&1; then
        log "WORKER_RESULT ip=${worker_ip} role=${expected_role} result=FAIL reason=role_probe"
        return 1
    fi
    actual_role=$(worker_ssh "$worker_ip" \
        "grep aella_role /opt/aelladata/work/da_conf.yml 2>/dev/null | awk -F': ' '{print \$2}' | tr -d \"' \\\"\"" \
        2>/dev/null || true)
    actual_role="$(_phase2_trim_ip "$actual_role")"
    if [[ -z "$actual_role" ]]; then
        log "WORKER_RESULT ip=${worker_ip} role=${expected_role} result=FAIL reason=role_probe"
        return 1
    fi
    expected_canonical="$(_phase2_canonical_role "$expected_role")"
    actual_canonical="$(_phase2_canonical_role "$actual_role")"
    if [[ "$actual_canonical" != "$expected_canonical" ]]; then
        # Keep the legacy `reason=role_mismatch actual=...` prefix stable for
        # existing diagnostics/tests, then append the stricter expected role.
        log "WORKER_RESULT ip=${worker_ip} role=${expected_role} result=FAIL reason=role_mismatch actual=${actual_role} expected=${expected_role}"
        return 1
    fi
    log "REMOTE_ROLE_IDENTITY ip=${worker_ip} expected=${expected_role} actual=${actual_role} result=PASS"
    return 0
}

# Hard completion gate for a node executing in worker mode, including the
# standalone `--role standby` path. Vendor validate_all remains diagnostic;
# these three local facts must all be true before the run can complete.
validate_local_remote_join_state() {
    local role="${ROLE:-unknown}"
    case "$role" in
        *worker*|standby) ;;
        *) return 0 ;;
    esac
    if ! systemctl is-active --quiet kubelet 2>/dev/null; then
        log "REMOTE_JOIN_LOCAL_STATE=FAIL role=${role} reason=kubelet_inactive"
        return 1
    fi
    if [[ ! -s "$PHASE2_KUBELET_CONF_PATH" ]]; then
        log "REMOTE_JOIN_LOCAL_STATE=FAIL role=${role} reason=kubelet_conf_missing path=${PHASE2_KUBELET_CONF_PATH}"
        return 1
    fi
    if ! ip link show "$PHASE2_FLANNEL_INTERFACE" >/dev/null 2>&1; then
        log "REMOTE_JOIN_LOCAL_STATE=FAIL role=${role} reason=flannel_missing interface=${PHASE2_FLANNEL_INTERFACE}"
        return 1
    fi
    log "REMOTE_JOIN_LOCAL_STATE=PASS role=${role} kubelet_conf=${PHASE2_KUBELET_CONF_PATH} flannel=${PHASE2_FLANNEL_INTERFACE}"
    return 0
}

# Print canonical ip:role specs, workers first (vendor f1a73 order), then standby.
remote_orchestration_node_specs() {
    local default_worker_role="${1:-DR-worker}"
    local -a _phase2_workers=() _phase2_standbys=()
    local _phase2_ip
    _phase2_split_ip_csv "${WORKER_IPS:-}" _phase2_workers || return 1
    _phase2_split_ip_csv "${STANDBY_IPS:-}" _phase2_standbys || return 1
    for _phase2_ip in "${_phase2_workers[@]}"; do
        printf '%s:%s\n' "$_phase2_ip" "$default_worker_role"
    done
    for _phase2_ip in "${_phase2_standbys[@]}"; do
        printf '%s:standby\n' "$_phase2_ip"
    done
}

count_remote_orchestration_nodes() {
    local -a _phase2_workers=() _phase2_standbys=()
    _phase2_split_ip_csv "${WORKER_IPS:-}" _phase2_workers || { printf '0\n'; return 1; }
    _phase2_split_ip_csv "${STANDBY_IPS:-}" _phase2_standbys || { printf '0\n'; return 1; }
    printf '%s\n' $((${#_phase2_workers[@]} + ${#_phase2_standbys[@]}))
}

# Diagnostic helper only. Not a cluster-size correctness criterion.
# Returns the number of requested remote orchestration nodes (workers+standby).
count_expected_cluster_nodes() {
    count_remote_orchestration_nodes
}

phase2_prereq_lib_paths() {
    printf '%s\n' \
        "${STAGING_DIR}/lib/dp-phase2-ubuntu-prerequisites.sh" \
        "/home/aella/lib/dp-phase2-ubuntu-prerequisites.sh" \
        "/opt/aelladata/os-upgrade/offline/phase2-bringup/lib/dp-phase2-ubuntu-prerequisites.sh"
}

source_phase2_prereq_lib() {
    local p
    while IFS= read -r p; do
        if [[ -f "$p" ]]; then
            # shellcheck source=/dev/null
            source "$p"
            return 0
        fi
    done < <(phase2_prereq_lib_paths)
    return 1
}

validate_apt_dependency_graph() {
    local stage="${1:-unspecified}"
    if source_phase2_prereq_lib && declare -F dp2_validate_apt_dependency_graph >/dev/null 2>&1; then
        dp2_validate_apt_dependency_graph "$stage"
        return $?
    fi
    local audit="" rc=0
    audit="$(dpkg --audit 2>&1 || true)"
    if [[ -n "${audit// }" ]]; then
        log "WARNING: DPKG_AUDIT=DIRTY stage=${stage}"
    else
        log "DPKG_AUDIT=CLEAN stage=${stage} (not sufficient)"
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        log "ERROR: APT_DEPENDENCY_CHECK=FAIL stage=${stage} reason=apt-get_missing"
        return 1
    fi
    local prev_e=0
    [[ $- == *e* ]] && prev_e=1
    set +e
    apt-get -o Debug::NoLocking=true check >/dev/null 2>&1
    rc=$?
    [[ "$prev_e" -eq 1 ]] && set -e
    if [[ "$rc" -ne 0 ]]; then
        log "ERROR: APT_DEPENDENCY_CHECK=FAIL stage=${stage} rc=${rc}"
        return "$rc"
    fi
    log "APT_DEPENDENCY_CHECK=PASS stage=${stage}"
    return 0
}

validate_critical_python_runtime() {
    local missing=() mod
    if source_phase2_prereq_lib && declare -F dp2_validate_critical_python_runtime >/dev/null 2>&1; then
        dp2_validate_critical_python_runtime
        return $?
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        log "ERROR: CRITICAL_PYTHON_RUNTIME=FAIL reason=python3_missing"
        return 1
    fi
    for mod in $PHASE2_CRITICAL_PYTHON_IMPORTS; do
        if ! python3 -c "import ${mod}" >/dev/null 2>&1; then
            missing+=("$mod")
            log "ERROR: CRITICAL_PYTHON_IMPORT=FAIL module=${mod}"
        else
            log "CRITICAL_PYTHON_IMPORT=PASS module=${mod}"
        fi
    done
    if ! python3 -c "import asyncore" >/dev/null 2>&1; then
        missing+=("asyncore")
        log "ERROR: CRITICAL_PYTHON_IMPORT=FAIL module=asyncore"
    else
        log "CRITICAL_PYTHON_IMPORT=PASS module=asyncore"
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERROR: CRITICAL_PYTHON_RUNTIME=FAIL missing=${missing[*]}"
        return 1
    fi
    log "CRITICAL_PYTHON_RUNTIME=PASS"
    return 0
}

install_phase2_ubuntu_prerequisites() {
    if source_phase2_prereq_lib && declare -F dp2_install_phase2_ubuntu_prerequisites >/dev/null 2>&1; then
        dp2_install_phase2_ubuntu_prerequisites
        return $?
    fi
    log "ERROR: PHASE2_PREREQ_INSTALL=FAIL reason=prereq_lib_missing"
    return 1
}

# Exact prerequisite contract filenames. Do not use extension globs as the
# protocol: workers must receive these files intentionally.
phase2_prereq_contract_state_name() { printf '%s\n' "phase2-ubuntu-prerequisites.state"; }
phase2_prereq_contract_artifact_name() { printf '%s\n' "phase2-ubuntu-prerequisites.tar.gz"; }
phase2_prereq_contract_sidecar_name() { printf '%s\n' "phase2-ubuntu-prerequisites.tar.gz.sha256"; }
phase2_prereq_contract_manifest_name() { printf '%s\n' "phase2-ubuntu-prerequisites.manifest.json"; }
phase2_prereq_contract_lib_name() { printf '%s\n' "dp-phase2-ubuntu-prerequisites.sh"; }

phase2_prereq_lib_source_path() {
    local p
    for p in \
        "${STAGING_DIR}/lib/dp-phase2-ubuntu-prerequisites.sh" \
        "/home/aella/lib/dp-phase2-ubuntu-prerequisites.sh" \
        "/opt/aelladata/os-upgrade/offline/phase2-bringup/lib/dp-phase2-ubuntu-prerequisites.sh"
    do
        if [[ -f "$p" ]]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

# Remove only the current-generation prerequisite contract files. Never
# glob-delete unrelated staged artifacts.
clean_phase2_prereq_contract_files() {
    local dir="${1:-${STAGING_DIR:-/opt/aelladata/aelladeb_py3}}"
    rm -f \
        "${dir}/phase2-ubuntu-prerequisites.state" \
        "${dir}/phase2-ubuntu-prerequisites.tar.gz" \
        "${dir}/phase2-ubuntu-prerequisites.tar.gz.sha256" \
        "${dir}/phase2-ubuntu-prerequisites.manifest.json" \
        "${dir}/phase2-ubuntu-prerequisites.identity"
}

# Large Phase 2 artifacts (images-*.tar) must land on the data filesystem.
# Default upload root stays under /opt/aelladata — never /home or /tmp.
phase2_worker_upload_root() {
    printf '%s\n' "${PHASE2_WORKER_UPLOAD_ROOT:-/opt/aelladata/.phase2-worker-upload}"
}

# Ensure upload + protected dirs exist with correct ownership. Does not wipe
# already-promoted staging artifacts (prereq contract copy runs after them).
# Rejects directory symlinks at the trust boundary; resolves aella via numeric
# UID/primary GID (never aella:aella). Upload and staging must share a device.
ensure_worker_protected_staging_dirs() {
    local worker_ip="$1"
    local staging="${STAGING_DIR:-/opt/aelladata/aelladeb_py3}"
    local aelladeb="${AELLADEB_DIR:-/opt/aelladata/aelladeb}"
    local upload
    upload="$(phase2_worker_upload_root)"
    if ! declare -F worker_ssh >/dev/null 2>&1; then
        log "ERROR: WORKER_STAGING_PREPARE=FAIL reason=ssh_helpers_missing"
        return 1
    fi
    case "${staging}${aelladeb}${upload}" in
        *\'*)
            log "ERROR: WORKER_STAGING_PREPARE=FAIL reason=unsafe_path"
            return 1
            ;;
    esac
    if ! worker_ssh "$worker_ip" "sudo bash -c '
set -euo pipefail
staging='\''${staging}'\''
aelladeb='\''${aelladeb}'\''
upload='\''${upload}'\''
# Production paths stay under /opt/aelladata. Hermetic tests may override
# STAGING_DIR/PHASE2_WORKER_UPLOAD_ROOT to a shared temp tree.
if [[ \"\$staging\" == /opt/aelladata/* && \"\$upload\" == /opt/aelladata/* && \"\$aelladeb\" == /opt/aelladata/* ]]; then
  data_root=/opt/aelladata
else
  data_root=\$(dirname \"\$staging\")
fi

phase2_reject_symlink_components() {
  local path=\"\$1\"
  local cur=\"\" part
  local IFS=/
  local -a parts
  # Absolute paths only.
  [[ \"\$path\" == /* ]] || {
    echo \"WORKER_STAGING_PREPARE=FAIL reason=path_not_absolute path=\${path}\" >&2
    return 1
  }
  read -r -a parts <<< \"\${path#/}\"
  for part in \"\${parts[@]}\"; do
    [[ -n \"\$part\" ]] || continue
    cur=\"\${cur}/\${part}\"
    if [[ -L \"\$cur\" ]]; then
      echo \"WORKER_STAGING_PREPARE=FAIL reason=symlink_path path=\${cur}\" >&2
      return 1
    fi
  done
  if [[ -e \"\$path\" && ! -d \"\$path\" ]]; then
    echo \"WORKER_STAGING_PREPARE=FAIL reason=not_directory path=\${path}\" >&2
    return 1
  fi
  return 0
}

phase2_ensure_safe_dir() {
  local path=\"\$1\"
  local mode=\"\$2\"
  local owner=\"\$3\"
  local parent=\"\$4\"
  local real pref
  phase2_reject_symlink_components \"\$path\" || return 1
  mkdir -p \"\$path\"
  phase2_reject_symlink_components \"\$path\" || return 1
  [[ -d \"\$path\" && ! -L \"\$path\" ]] || {
    echo \"WORKER_STAGING_PREPARE=FAIL reason=not_directory path=\${path}\" >&2
    return 1
  }
  real=\$(readlink -f \"\$path\")
  pref=\$(readlink -f \"\$parent\")
  case \"\$real\" in
    \"\$pref\"|\"\$pref\"/*) ;;
    *)
      echo \"WORKER_STAGING_PREPARE=FAIL reason=escape_parent path=\${path} real=\${real} parent=\${pref}\" >&2
      return 1
      ;;
  esac
  chown \"\$owner\" \"\$path\"
  chmod \"\$mode\" \"\$path\"
  return 0
}

uid=\$(id -u aella) || {
  echo \"WORKER_STAGING_PREPARE=FAIL reason=aella_uid_unresolved\" >&2
  exit 1
}
gid=\$(id -g aella) || {
  echo \"WORKER_STAGING_PREPARE=FAIL reason=aella_gid_unresolved\" >&2
  exit 1
}
[[ \"\$uid\" =~ ^[0-9]+\$ && \"\$gid\" =~ ^[0-9]+\$ ]] || {
  echo \"WORKER_STAGING_PREPARE=FAIL reason=aella_identity_invalid uid=\${uid} gid=\${gid}\" >&2
  exit 1
}

# Upload must live on the data filesystem (same device as staging), not a
# silent /home or /tmp fallback when production defaults are in use.
if [[ \"\$data_root\" == /opt/aelladata ]]; then
  case \"\$upload\" in
    /home/*|/tmp/*|/var/tmp/*)
      echo \"WORKER_STAGING_PREPARE=FAIL reason=upload_on_root_fs path=\${upload}\" >&2
      exit 1
      ;;
  esac
fi
phase2_ensure_safe_dir \"\$data_root\" 0755 root:root / || exit 1
phase2_ensure_safe_dir \"\$staging\" 0755 root:root \"\$data_root\" || exit 1
phase2_ensure_safe_dir \"\${staging}/lib\" 0755 root:root \"\$staging\" || exit 1
phase2_ensure_safe_dir \"\$aelladeb\" 0755 root:root \"\$data_root\" || exit 1
phase2_ensure_safe_dir \"\$upload\" 0700 \"\${uid}:\${gid}\" \"\$data_root\" || exit 1
phase2_ensure_safe_dir \"\${upload}/lib\" 0700 \"\${uid}:\${gid}\" \"\$upload\" || exit 1
phase2_ensure_safe_dir \"\${upload}/aelladeb\" 0700 \"\${uid}:\${gid}\" \"\$upload\" || exit 1

staging_dev=\$(stat -c \"%d\" \"\$staging\")
upload_dev=\$(stat -c \"%d\" \"\$upload\")
aelladeb_dev=\$(stat -c \"%d\" \"\$aelladeb\")
if [[ \"\$staging_dev\" != \"\$upload_dev\" || \"\$staging_dev\" != \"\$aelladeb_dev\" ]]; then
  echo \"WORKER_STAGING_PREPARE=FAIL reason=cross_filesystem staging_dev=\${staging_dev} upload_dev=\${upload_dev} aelladeb_dev=\${aelladeb_dev}\" >&2
  exit 1
fi
'"; then
        log "ERROR: WORKER_STAGING_PREPARE=FAIL reason=remote_mkdir"
        return 1
    fi
    return 0
}

# Prepare root-owned protected staging and an aella-owned (0700) upload area.
# SCP lands in the upload area; root promotes into protected dirs before use.
# Wipes upload files and stale root-owned deb/tar.gz so OpenSSH 9.x SFTP can
# create fresh aella-owned uploads. Leaves *.tar for skip-by-SHA reuse.
# Does not use find -L across the trust boundary.
prepare_worker_protected_staging() {
    local worker_ip="$1"
    local staging="${STAGING_DIR:-/opt/aelladata/aelladeb_py3}"
    local aelladeb="${AELLADEB_DIR:-/opt/aelladata/aelladeb}"
    local upload
    upload="$(phase2_worker_upload_root)"
    if ! ensure_worker_protected_staging_dirs "$worker_ip"; then
        return 1
    fi
    case "${staging}${aelladeb}${upload}" in
        *\'*)
            log "ERROR: WORKER_STAGING_PREPARE=FAIL reason=unsafe_path"
            return 1
            ;;
    esac
    if ! worker_ssh "$worker_ip" "sudo bash -c '
set -euo pipefail
staging='\''${staging}'\''
aelladeb='\''${aelladeb}'\''
upload='\''${upload}'\''
for d in \"\$upload\" \"\${upload}/lib\" \"\${upload}/aelladeb\" \"\$staging\" \"\$aelladeb\"; do
  if [[ -L \"\$d\" ]]; then
    echo \"WORKER_STAGING_PREPARE=FAIL reason=symlink_path path=\${d}\" >&2
    exit 1
  fi
  if [[ ! -d \"\$d\" ]]; then
    echo \"WORKER_STAGING_PREPARE=FAIL reason=not_directory path=\${d}\" >&2
    exit 1
  fi
done
# Regular files only; never follow directory symlinks (-L omitted by design).
find \"\$upload\" \"\${upload}/lib\" \"\${upload}/aelladeb\" -maxdepth 1 -type f -delete 2>/dev/null || true
find \"\$staging\" \"\$aelladeb\" -maxdepth 1 -type f \
  \\( -name \"*.deb\" -o -name \"*.tar.gz\" -o -name \"*.tgz\" \\) -delete 2>/dev/null || true
true
'"; then
        log "ERROR: WORKER_STAGING_PREPARE=FAIL reason=remote_clean"
        return 1
    fi
    log "WORKER_STAGING_PREPARE=PASS upload=${upload}"
    return 0
}

# Promote regular files from an aella upload dir into a root-owned dest.
# Same-filesystem atomic rename (mv) avoids a second full-size copy of large
# images-*.tar. Rejects symlinks. Root consumes only the promoted object.
promote_worker_upload_dir() {
    local worker_ip="$1"
    local upload_dir="$2"
    local dest_dir="$3"
    local mode="${4:-0644}"
    if ! declare -F worker_ssh >/dev/null 2>&1; then
        log "ERROR: WORKER_STAGING_PROMOTE=FAIL reason=ssh_helpers_missing"
        return 1
    fi
    # Paths are single-quoted into the remote command; they must not contain quotes.
    case "${upload_dir}${dest_dir}${mode}" in
        *\'*) log "ERROR: WORKER_STAGING_PROMOTE=FAIL reason=unsafe_path"; return 1 ;;
    esac
    if ! worker_ssh "$worker_ip" "sudo bash -c '
set -euo pipefail
upload='\''${upload_dir}'\''
dest='\''${dest_dir}'\''
mode='\''${mode}'\''
if [[ -L \"\$upload\" || -L \"\$dest\" ]]; then
  echo \"WORKER_STAGING_PROMOTE=FAIL reason=symlink_path\" >&2
  exit 1
fi
if [[ ! -d \"\$upload\" ]]; then
  echo \"WORKER_STAGING_PROMOTE=FAIL reason=upload_not_directory\" >&2
  exit 1
fi
if [[ -e \"\$dest\" && ! -d \"\$dest\" ]]; then
  echo \"WORKER_STAGING_PROMOTE=FAIL reason=dest_not_directory\" >&2
  exit 1
fi
mkdir -p \"\$dest\"
if [[ -L \"\$dest\" || ! -d \"\$dest\" ]]; then
  echo \"WORKER_STAGING_PROMOTE=FAIL reason=dest_symlink_or_missing\" >&2
  exit 1
fi
upload_dev=\$(stat -c \"%d\" \"\$upload\")
dest_dev=\$(stat -c \"%d\" \"\$dest\")
if [[ \"\$upload_dev\" != \"\$dest_dev\" ]]; then
  echo \"WORKER_STAGING_PROMOTE=FAIL reason=cross_filesystem\" >&2
  exit 1
fi
shopt -s nullglob
for src in \"\$upload\"/*; do
  [[ -e \"\$src\" ]] || continue
  if [[ -L \"\$src\" ]]; then
    echo \"WORKER_STAGING_PROMOTE=FAIL reason=symlink\" >&2
    exit 1
  fi
  [[ -f \"\$src\" ]] || continue
  base=\$(basename \"\$src\")
  case \"\$base\" in
    \"\"|.*|*/*)
      echo \"WORKER_STAGING_PROMOTE=FAIL reason=unsafe_name\" >&2
      exit 1
      ;;
  esac
  # Same-FS atomic promote: chown/chmod in place, then rename into dest.
  # Avoids install(1) full-size copy of multi-GiB images-*.tar.
  chown root:root \"\$src\"
  chmod \"\$mode\" \"\$src\"
  mv -f \"\$src\" \"\${dest}/\${base}\"
done
'"; then
        log "ERROR: WORKER_STAGING_PROMOTE=FAIL upload=${upload_dir} dest=${dest_dir}"
        return 1
    fi
    log "WORKER_STAGING_PROMOTE=PASS upload=${upload_dir} dest=${dest_dir}"
    return 0
}

# Copy the current prerequisite contract to one worker. MUST run after the
# generic staging glob copy so a leftover REQUIRED=YES tarball cannot remain
# as the worker's current artifact when the new state is REQUIRED=NO.
copy_phase2_prereq_contract_to_worker() {
    local worker_ip="$1"
    local staging="${STAGING_DIR:-/opt/aelladata/aelladeb_py3}"
    local state="${staging}/phase2-ubuntu-prerequisites.state"
    local artifact="${staging}/phase2-ubuntu-prerequisites.tar.gz"
    local sidecar="${artifact}.sha256"
    local manifest="${staging}/phase2-ubuntu-prerequisites.manifest.json"
    local lib_src="" required=""
    local upload remote_clean
    upload="$(phase2_worker_upload_root)"

    if ! declare -F worker_ssh >/dev/null 2>&1 || ! declare -F worker_scp >/dev/null 2>&1; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=ssh_helpers_missing"
        return 1
    fi

    if ! ensure_worker_protected_staging_dirs "$worker_ip"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=worker_prepare"
        return 1
    fi

    remote_clean="sudo rm -f \
'${staging}/phase2-ubuntu-prerequisites.state' \
'${staging}/phase2-ubuntu-prerequisites.tar.gz' \
'${staging}/phase2-ubuntu-prerequisites.tar.gz.sha256' \
'${staging}/phase2-ubuntu-prerequisites.manifest.json' \
'${staging}/phase2-ubuntu-prerequisites.identity' \
'${staging}/lib/dp-phase2-ubuntu-prerequisites.sh' \
'${upload}/phase2-ubuntu-prerequisites.state' \
'${upload}/phase2-ubuntu-prerequisites.tar.gz' \
'${upload}/phase2-ubuntu-prerequisites.tar.gz.sha256' \
'${upload}/phase2-ubuntu-prerequisites.manifest.json' \
'${upload}/phase2-ubuntu-prerequisites.identity' \
'${upload}/lib/dp-phase2-ubuntu-prerequisites.sh'"
    if ! worker_ssh "$worker_ip" "$remote_clean"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=worker_clean"
        return 1
    fi

    if [[ ! -f "$state" ]]; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=state_missing"
        return 1
    fi
    if ! worker_scp "$state" "$worker_ip" "${upload}/"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=state_copy"
        return 1
    fi

    if ! lib_src="$(phase2_prereq_lib_source_path)"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=lib_missing"
        return 1
    fi
    if ! worker_scp "$lib_src" "$worker_ip" "${upload}/lib/dp-phase2-ubuntu-prerequisites.sh"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=lib_copy"
        return 1
    fi

    required="$(awk -F= '$1=="PHASE2_PREREQ_REQUIRED"{print $2; exit}' "$state")"
    if [[ "$required" == "NO" ]]; then
        if ! promote_worker_upload_dir "$worker_ip" "$upload" "$staging"; then
            log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=promote_state"
            return 1
        fi
        if ! promote_worker_upload_dir "$worker_ip" "${upload}/lib" "${staging}/lib" 0644; then
            log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=promote_lib"
            return 1
        fi
        log "PHASE2_PREREQ_WORKER_COPY=NOT_REQUIRED"
        return 0
    fi
    if [[ "$required" != "YES" ]]; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=required_invalid"
        return 1
    fi
    if [[ ! -f "$artifact" || ! -f "$sidecar" || ! -f "$manifest" ]]; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=required_file_missing"
        return 1
    fi
    if ! worker_scp "$artifact" "$worker_ip" "${upload}/"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=artifact_copy"
        return 1
    fi
    if ! worker_scp "$sidecar" "$worker_ip" "${upload}/"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=sidecar_copy"
        return 1
    fi
    if ! worker_scp "$manifest" "$worker_ip" "${upload}/"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=manifest_copy"
        return 1
    fi
    if ! promote_worker_upload_dir "$worker_ip" "$upload" "$staging"; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=promote_artifacts"
        return 1
    fi
    if ! promote_worker_upload_dir "$worker_ip" "${upload}/lib" "${staging}/lib" 0644; then
        log "ERROR: PHASE2_PREREQ_WORKER_COPY=FAIL reason=promote_lib"
        return 1
    fi
    log "PHASE2_PREREQ_WORKER_COPY=PASS"
    return 0
}

wait_for_master_token_api() {
    local timeout_s="${1:-$MASTER_TOKEN_API_WAIT_SECONDS}"
    local port="${MASTER_TOKEN_API_PORT}"
    local started now elapsed
    local loopback_code=000 master_ip_code=000
    local loopback_ready=0 master_ip_ready=0
    local cluster_mode=0
    # Remote workers and/or standby are cluster nodes; loopback-only is not enough.
    if [[ -n "${WORKER_IPS:-}" || -n "${STANDBY_IPS:-}" ]]; then
        cluster_mode=1
    fi
    started="$(date +%s)"
    log "Waiting for master token API on TCP/${port} (timeout=${timeout_s}s cluster=${cluster_mode})"
    while true; do
        loopback_code="$(curl -sk --connect-timeout 5 --max-time 10 \
            -o /dev/null -w '%{http_code}' "https://127.0.0.1:${port}/" 2>/dev/null || echo 000)"
        if [[ "$loopback_code" =~ ^(200|401|403|404)$ ]]; then
            loopback_ready=1
        else
            loopback_ready=0
        fi
        master_ip_ready=0
        master_ip_code=000
        if [[ -n "${MASTER_IP:-}" ]]; then
            master_ip_code="$(curl -sk --connect-timeout 5 --max-time 10 \
                -o /dev/null -w '%{http_code}' "https://${MASTER_IP}:${port}/" 2>/dev/null || echo 000)"
            if [[ "$master_ip_code" =~ ^(200|401|403|404)$ ]]; then
                master_ip_ready=1
            fi
        fi
        if [[ "$cluster_mode" -eq 1 ]]; then
            if [[ -z "${MASTER_IP:-}" ]]; then
                log "MASTER_IP_8003_READY=NO reason=master_ip_unset"
                log "MASTER_TOKEN_API_READY=NO"
                log "BRINGUP_RESULT=FAIL"
                return 1
            fi
            if [[ "$master_ip_ready" -eq 1 ]]; then
                if [[ "$loopback_ready" -eq 1 ]]; then
                    log "LOOPBACK_8003_READY=YES"
                else
                    log "LOOPBACK_8003_READY=NO http=${loopback_code}"
                fi
                log "MASTER_IP_8003_READY=YES port=${port} http=${master_ip_code}"
                log "MASTER_TOKEN_API_READY=YES port=${port} http=${master_ip_code}"
                return 0
            fi
        else
            if [[ "$loopback_ready" -eq 1 ]]; then
                log "LOOPBACK_8003_READY=YES port=${port} http=${loopback_code}"
                if [[ -n "${MASTER_IP:-}" ]]; then
                    if [[ "$master_ip_ready" -eq 1 ]]; then
                        log "MASTER_IP_8003_READY=YES"
                    else
                        log "MASTER_IP_8003_READY=NO http=${master_ip_code}"
                    fi
                else
                    log "MASTER_IP_8003_READY=NOT_REQUIRED"
                fi
                log "MASTER_TOKEN_API_READY=YES port=${port} http=${loopback_code}"
                return 0
            fi
        fi
        now="$(date +%s)"
        elapsed=$((now - started))
        if [[ "$elapsed" -ge "$timeout_s" ]]; then
            if [[ "$loopback_ready" -eq 1 ]]; then
                log "LOOPBACK_8003_READY=YES http=${loopback_code}"
            else
                log "LOOPBACK_8003_READY=NO http=${loopback_code}"
            fi
            if [[ "$cluster_mode" -eq 1 || -n "${MASTER_IP:-}" ]]; then
                log "MASTER_IP_8003_READY=NO http=${master_ip_code}"
            else
                log "MASTER_IP_8003_READY=NOT_REQUIRED"
            fi
            log "MASTER_TOKEN_API_READY=NO port=${port} last_http=${master_ip_code:-$loopback_code} waited=${elapsed}s"
            log "BRINGUP_RESULT=FAIL"
            return 1
        fi
        sleep 5
    done
}

kubectl_ready_node_count() {
    kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready($|,)/ {c++} END {print c+0}'
}

validate_expected_cluster_nodes() {
    local requested ready
    # Diagnostic only. Per-target hostname Ready validation in
    # orchestrate_workers is the correctness criterion. Extra existing
    # Ready nodes are expected on retry / incremental worker add and must
    # never cause a false FAIL or hide a missing requested target.
    requested="$(count_remote_orchestration_nodes)"
    ready="$(kubectl_ready_node_count)"
    if [[ "${requested:-0}" -eq 0 ]]; then
        log "CLUSTER_JOIN_STATE skipped (no remote orchestration nodes; single-node/AIO)"
        log "CLUSTER_JOIN_STATE ready=${ready:-0} requested=0 diagnostic=YES"
        return 0
    fi
    log "CLUSTER_JOIN_STATE ready=${ready:-0} requested=${requested} diagnostic=YES"
    return 0
}