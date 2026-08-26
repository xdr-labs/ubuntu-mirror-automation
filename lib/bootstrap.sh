#!/usr/bin/env bash
# lib/bootstrap.sh — Fresh Ubuntu 24.04 Mirror Manager bootstrap helpers
# shellcheck shell=bash

if [[ -n "${UM_BOOTSTRAP_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
UM_BOOTSTRAP_LOADED=1

# Authoritative installed-runtime file manifest (single source of truth).
# shellcheck source=runtime_manifest.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime_manifest.sh"

# Test-only override (never documented in README / --help).
# UM_BOOTSTRAP_ALLOW_UNSUPPORTED_OS=1 skips the Ubuntu 24.04 gate.

UM_BOOTSTRAP_REQUIRED_PKGS=(
  nginx
  curl
  ca-certificates
  whiptail
  dialog
  python3
  tar
  coreutils
  util-linux
  gnupg
  gpgv
  openssl
  findutils
  grep
  sed
  gawk
)

UM_BOOTSTRAP_REQUIRED_CMDS=(
  nginx
  curl
  whiptail
  dialog
  python3
  tar
  sha256sum
  sha1sum
  flock
  stat
  df
  awk
  sed
  grep
  find
  mkdir
  chmod
  mktemp
  openssl
  gpgv
)

# OS-hop clients (built and signed per Mirror install against local MIRROR_HTTP_URL)
UM_CLIENT_HOP_SCRIPTS=(
  dp-offline-upgrade-xenial-to-bionic.sh
  dp-offline-upgrade-bionic-to-focal.sh
  dp-offline-upgrade-focal-to-jammy.sh
  dp-offline-upgrade-jammy-to-noble.sh
)

# Client HTTP artifacts required for CLIENT_FILES_READY=PASS
UM_CLIENT_REQUIRED_FILES=(
  dp-offline-upgrade-xenial-to-bionic.sh
  dp-offline-upgrade-xenial-to-bionic.sh.sha256
  dp-offline-upgrade-bionic-to-focal.sh
  dp-offline-upgrade-bionic-to-focal.sh.sha256
  dp-offline-upgrade-focal-to-jammy.sh
  dp-offline-upgrade-focal-to-jammy.sh.sha256
  dp-offline-upgrade-jammy-to-noble.sh
  dp-offline-upgrade-jammy-to-noble.sh.sha256
  stage-dp-phase2.sh
  stage-dp-phase2.sh.sha256
)

um_bootstrap_required_packages() {
  printf '%s\n' "${UM_BOOTSTRAP_REQUIRED_PKGS[@]}"
}

um_bootstrap_os_gate() {
  local id="" version_id="" arch
  arch="$(uname -m 2>/dev/null || true)"
  if [[ ! -f /etc/os-release ]]; then
    um_die "OS_GATE=FAIL /etc/os-release missing"
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  id="${ID:-}"
  version_id="${VERSION_ID:-}"
  if [[ "${UM_BOOTSTRAP_ALLOW_UNSUPPORTED_OS:-0}" == "1" ]]; then
    um_warn "OS_GATE=SKIPPED_TEST_ONLY id=${id} version=${version_id} arch=${arch}"
    return 0
  fi
  if [[ "$id" != "ubuntu" || "$version_id" != "24.04" ]]; then
    um_die "OS_GATE=FAIL supported=Ubuntu_24.04_LTS_amd64 got=${id:-unknown} ${version_id:-unknown}"
  fi
  if [[ "$arch" != "x86_64" && "$arch" != "amd64" ]]; then
    um_die "OS_GATE=FAIL supported_arch=amd64 got=${arch}"
  fi
  um_ok "OS_GATE=PASS Ubuntu 24.04 LTS amd64"
}

um_bootstrap_host_preflight() {
  um_bootstrap_os_gate

  if [[ "${UM_DRY_RUN:-0}" != "1" ]]; then
    um_require_root
  else
    um_dry "Would require root privileges"
  fi

  um_command_exists apt-get || um_die "PREFLIGHT=FAIL apt-get missing"
  um_command_exists systemctl || um_die "PREFLIGHT=FAIL systemd/systemctl missing"
  um_ok "PREFLIGHT=PASS apt-get systemd"

  # DNS / HTTPS (best-effort; do not fail dry-run)
  if curl -sS --max-time 8 -I https://xdrsolutions.uk/ >/dev/null 2>&1; then
    um_ok "OUTBOUND_HTTPS=PASS xdrsolutions.uk"
  else
    if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
      um_dry "SKIPPED: outbound HTTPS check (runtime)"
    else
      um_warn "OUTBOUND_HTTPS=WARN cannot reach https://xdrsolutions.uk (R2 download will need this)"
    fi
  fi

  # System clock sanity (year >= 2024)
  local year
  year="$(date -u +%Y 2>/dev/null || echo 0)"
  if [[ "$year" =~ ^[0-9]+$ ]] && [[ "$year" -ge 2024 ]]; then
    um_ok "SYSTEM_CLOCK=PASS year=${year}"
  else
    um_warn "SYSTEM_CLOCK=WARN year=${year}"
  fi

  # Port 80 conflict (informational)
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn '( sport = :80 )' 2>/dev/null | grep -q LISTEN; then
      if systemctl is-active --quiet nginx 2>/dev/null; then
        um_ok "PORT_80=PASS (nginx already listening)"
      else
        um_warn "PORT_80=WARN port 80 in use by non-nginx process"
      fi
    else
      um_ok "PORT_80=PASS available"
    fi
  fi
}

um_bootstrap_storage_preflight() {
  local base="${BASE_PATH:-/var/spool/apt-mirror}"
  if [[ ! -d "$base" ]]; then
    if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
      um_dry "Would create BASE_PATH ${base}"
    else
      mkdir -p "$base"
    fi
  fi

  if [[ -d "$base" ]] && um_path_mounted "$base" 2>/dev/null; then
    local src
    src="$(findmnt -n -o SOURCE -T "$base" 2>/dev/null || echo unknown)"
    um_ok "STORAGE_MOUNT=PASS ${base} <- ${src}"
  else
    um_warn "STORAGE_MOUNT=WARN ${base} is not a separate mount — ensure enough free space"
  fi

  if [[ -d "$base" ]]; then
    local avail_kib avail_gib
    avail_kib="$(um_df_avail_kib "$base" 2>/dev/null || echo 0)"
    avail_gib=$(( ${avail_kib:-0} / 1024 / 1024 ))
    um_ok "STORAGE_FREE=${avail_gib} GiB at ${base}"
    um_info "Disk requirements for R2/ACPS downloads are calculated at Download and Prepare time"
    um_info "(package size + extract + Phase 2 + safety margin). Bootstrap does not download OS Core."
  fi

  if [[ -d "$base" ]] && [[ "${UM_DRY_RUN:-0}" != "1" ]] && [[ ! -w "$base" ]]; then
    um_die "STORAGE=FAIL no write permission on ${base}"
  fi
}

um_bootstrap_install_packages() {
  local pkgs=("${UM_BOOTSTRAP_REQUIRED_PKGS[@]}")
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would install packages: ${pkgs[*]}"
    return 0
  fi

  local need=0 c
  for c in "${UM_BOOTSTRAP_REQUIRED_CMDS[@]}"; do
    um_command_exists "$c" || need=1
  done

  if [[ "$need" -eq 0 ]]; then
    um_ok "PACKAGE_INSTALL=PASS already present"
  else
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
  fi

  for c in "${UM_BOOTSTRAP_REQUIRED_CMDS[@]}"; do
    um_command_exists "$c" || um_die "PACKAGE_INSTALL=FAIL missing command after install: ${c}"
  done
  um_ok "PACKAGE_INSTALL=PASS commands verified (whiptail nginx python3 present)"
}

um_bootstrap_prepare_dirs() {
  local base="${BASE_PATH:-/var/spool/apt-mirror}"
  local mm_log_dir="${UM_MM_LOG_DIR:-/var/log/ubuntu-mirror-automation}"
  local mm_state_dir="${UM_MM_STATE_ROOT:-/var/lib/ubuntu-mirror-automation/runs}"
  local dirs=(
    "$base"
    "${base}/selective"
    "${base}/dp-phase2"
    "${base}/client"
    "${base}/.install-cache"
    "${base}/offline"
    "${LOG_DIR:-/var/log/ubuntu-mirror}"
    "$mm_log_dir"
    "$mm_state_dir"
    "${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}"
    "${INSTALL_LIB_DIR:-/usr/local/lib/ubuntu-mirror}"
    "${BACKUP_DIR:-/var/backups/ubuntu-mirror}"
  )
  local d
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would create directories under ${base} and runtime paths"
    return 0
  fi
  for d in "${dirs[@]}"; do
    mkdir -p "$d"
  done
  chmod 755 "$base" "${base}/selective" "${base}/dp-phase2" "${base}/client" 2>/dev/null || true
  # Do not create selective/current, published.previous, or releases/
  rm -f "${base}/selective/current" 2>/dev/null || true
  um_ok "DIRECTORIES=PASS"
}

um_bootstrap_install_file() {
  local src="$1" dest="$2" mode="${3:-0644}"
  [[ -f "$src" ]] || um_die "RUNTIME_INSTALL=FAIL missing source ${src}"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest" 2>/dev/null; then
    chmod "$mode" "$dest" 2>/dev/null || true
    return 0
  fi
  install -m "$mode" "$src" "$dest"
}

um_bootstrap_install_runtime() {
  local src_root="${UM_PROJECT_ROOT}"
  local runtime="${INSTALL_LIB_DIR:-/usr/local/lib/ubuntu-mirror}"
  local bindir="${INSTALL_BIN_DIR:-/usr/local/bin}"
  local confdir="${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}"

  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would install Mirror Manager runtime under ${runtime}"
    um_dry "Would link ${bindir}/ubuntu-offline-mirror"
    return 0
  fi

  mkdir -p \
    "${runtime}" \
    "${confdir}" \
    "${bindir}" \
    /usr/local/sbin

  # Install every runtime file from the authoritative manifest (no hardcoded
  # parallel allowlist; no wildcard copies).
  um_runtime_install_tree "$src_root" "$runtime"

  # Resolve IP, local keypair, rebuild/sign/atomic-publish host-pinned clients
  um_bootstrap_deploy_client_http_artifacts

  # Entry points (sbin path overridable for temp-root tests)
  local sbin_link="${UM_UOM_INSTALL_PATH:-/usr/local/sbin/ubuntu-offline-mirror.sh}"
  mkdir -p "$(dirname "$sbin_link")" "${bindir}"
  ln -sfn "${runtime}/scripts/ubuntu-offline-mirror.sh" "$sbin_link"
  ln -sfn "${runtime}/scripts/ubuntu-offline-mirror.sh" "${bindir}/ubuntu-offline-mirror"

  # Minimal mirror.conf for path defaults (no secrets)
  if [[ ! -f "${confdir}/mirror.conf" ]] || [[ "${UM_FORCE:-0}" == "1" ]]; then
    if [[ -f "${src_root}/mirror.conf" ]]; then
      um_bootstrap_install_file "${src_root}/mirror.conf" "${confdir}/mirror.conf" 0644
    fi
  fi

  # Record source repo for operators (path only)
  printf '%s\n' "${src_root}" >"${confdir}/source-repo"

  # File + Python import dependency closure against the installed tree only.
  um_runtime_verify_dependency_closure "$runtime" "$bindir"
  um_runtime_verify_python_dependency_closure "$runtime" "$src_root"
  um_ok "RUNTIME_INSTALL=PASS"
}

um_bootstrap_write_sha256_sidecar() {
  local file="$1"
  local dir base
  dir="$(dirname "$file")"
  base="$(basename "$file")"
  (
    cd "$dir" || exit 1
    sha256sum "$base" >"${base}.sha256"
  )
}

um_bootstrap_source_mirror_host_libs() {
  local root="${UM_PROJECT_ROOT}"
  [[ -f "${root}/scripts/lib/mirror_host_ip.sh" ]] || return 1
  [[ -f "${root}/scripts/lib/client_mirror_gates.sh" ]] || return 1
  [[ -f "${root}/scripts/lib/local_client_signing.sh" ]] || return 1
  # shellcheck source=/dev/null
  source "${root}/scripts/lib/mirror_host_ip.sh"
  # shellcheck source=/dev/null
  source "${root}/scripts/lib/client_mirror_gates.sh"
  # shellcheck source=/dev/null
  source "${root}/scripts/lib/local_client_signing.sh"
}

# Persist operator-confirmed Mirror URL for Mirror Manager command generation.
# When mirror_base is empty, leave MIRROR_SERVER_IP/MIRROR_HTTP_URL unset so the
# operator must confirm them in Configuration before prepare/enable.
um_bootstrap_persist_local_mirror_url() {
  local confdir="${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}"
  local conf="${confdir}/dp-upgrade-mirror.conf"
  local mirror_base="${1:-}"
  local tmp prep user pass worker_pass dl_worker_ips da_worker_ips server_ip
  mkdir -p "$confdir"
  prep="FULL"
  user=""
  pass=""
  worker_pass=""
  dl_worker_ips=""
  da_worker_ips=""
  server_ip=""
  if [[ -f "$conf" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "$conf"
    set +a
    prep="${PREPARATION_MODE:-FULL}"
    user="${ACPS_USERNAME:-}"
    pass="${ACPS_PASSWORD:-}"
    worker_pass="${WORKER_SSH_PASSWORD:-}"
    dl_worker_ips="${DL_WORKER_IPS:-}"
    da_worker_ips="${DA_WORKER_IPS:-}"
    server_ip="${MIRROR_SERVER_IP:-}"
  fi
  if [[ -n "$mirror_base" ]]; then
    server_ip="$(mirror_host_extract_ipv4_from_url "$mirror_base" || true)"
  fi
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# DP Upgrade Mirror Manager configuration (managed by install/bootstrap)
# Phase 2 target is fixed at 6.6.0 (not user-editable).
PREPARATION_MODE=$(printf '%q' "${prep}")
ACPS_USERNAME=$(printf '%q' "${user}")
ACPS_PASSWORD=$(printf '%q' "${pass}")
WORKER_SSH_PASSWORD=$(printf '%q' "${worker_pass}")
DL_WORKER_IPS=$(printf '%q' "${dl_worker_ips}")
DA_WORKER_IPS=$(printf '%q' "${da_worker_ips}")
MIRROR_SERVER_IP=$(printf '%q' "${server_ip}")
MIRROR_HTTP_URL=$(printf '%q' "${mirror_base}")
EOF
  chmod 600 "$tmp"
  mv -f "$tmp" "$conf"
  chmod 600 "$conf"
  if [[ "${EUID}" -eq 0 ]]; then
    chown root:root "$conf" 2>/dev/null || true
  fi
  if [[ -n "$mirror_base" ]]; then
    um_ok "INSTALL_PERSISTS_LOCAL_MIRROR_URL=YES path=${conf} url=${mirror_base}"
  else
    um_info "INSTALL_PERSISTS_LOCAL_MIRROR_URL=DEFERRED path=${conf}"
  fi
}

um_bootstrap_selective_ready() {
  local selective="${SELECTIVE_MIRROR_ROOT:-${BASE_PATH:-/var/spool/apt-mirror}/selective}"
  [[ -f "${selective}/state/READY" ]] || return 1
  [[ -f "${selective}/keys/ubuntu-mirror-selective.gpg" ]] || return 1
  return 0
}

# Publish Phase 2 helpers + local public key without hop clients (pre-OS-Core).
um_bootstrap_publish_phase2_helpers_only() {
  local dest="${1:-${BASE_PATH:-/var/spool/apt-mirror}/client}"
  local src_root="${UM_PROJECT_ROOT}"
  local stage f
  mkdir -p "$dest"
  stage="$(mktemp -d "${dest}.helpers.XXXXXX")"
  chmod 0755 "$stage"
  for f in stage-dp-phase2.sh stage-dp-phase2-6.6.0.sh stage-dp-phase2-6.5.0.sh bringup_py3_dp_lifecycle.sh; do
    if [[ -f "${src_root}/client/${f}" ]]; then
      install -m 0755 "${src_root}/client/${f}" "${stage}/${f}"
      um_bootstrap_write_sha256_sidecar "${stage}/${f}"
    fi
  done
  if [[ -d "${src_root}/client/lib" ]]; then
    mkdir -p "${stage}/lib"
    chmod 0755 "${stage}/lib"
    # Publish the Phase 2 helper libraries required by Menu 7 / stage preflight.
    for f in \
      dp-offline-source-product-version.sh \
      dp-phase2-operation-progress.sh \
      dp-phase2-bringup-lifecycle.sh \
      dp-phase2-ubuntu-prerequisites.sh
    do
      if [[ -f "${src_root}/client/lib/${f}" ]]; then
        install -m 0755 "${src_root}/client/lib/${f}" "${stage}/lib/${f}"
      fi
    done
  fi
  if [[ -f "${src_root}/scripts/lib/phase2_helper_generation.sh" ]]; then
    # shellcheck source=/dev/null
    source "${src_root}/scripts/lib/phase2_helper_generation.sh"
    phase2_helper_generation_write "$stage" >/dev/null || {
      um_error "PHASE2_HELPER_GENERATION=FAIL"
      rm -rf "$stage"
      return 1
    }
  fi
  if [[ -n "${LOCAL_SIGNING_PUBLIC_KEY:-}" && -f "${LOCAL_SIGNING_PUBLIC_KEY}" ]]; then
    if ! local_signing_stage_http_public_artifacts "$stage" \
      "$LOCAL_SIGNING_PUBLIC_KEY" "${LOCAL_KEY_FINGERPRINT:-}"
    then
      um_error "CLIENT_PUBLIC_BINARY_KEYRING_BUILD=FAIL"
      rm -rf "$stage"
      return 1
    fi
    if [[ -n "${LOCAL_KEY_FINGERPRINT:-}" ]]; then
      printf '%s\n' "$LOCAL_KEY_FINGERPRINT" >"${stage}/fingerprint"
      chmod 0644 "${stage}/fingerprint"
    fi
  fi
  chmod 0755 "$dest" 2>/dev/null || true
  # Merge helpers into dest without removing an existing hop set.
  cp -a "${stage}/." "$dest/"
  rm -rf "$stage"
  chmod 0755 "$dest" 2>/dev/null || true
  # Apply public permission contract when the helper is available.
  if [[ -f "${src_root}/scripts/lib/http_publication_permissions.sh" ]]; then
    # shellcheck source=/dev/null
    source "${src_root}/scripts/lib/http_publication_permissions.sh"
    mm_normalize_http_public_tree_permissions "$dest" client || true
  fi
  local_signing_assert_private_not_published "$dest" || return 1
  return 0
}

# Resolve host IP, ensure local signing keypair, rebuild/sign/atomic-publish the
# four host-pinned clients. Never copies stale prebuilt client/*.sh from git.
um_bootstrap_deploy_client_http_artifacts() {
  local src_root="${UM_PROJECT_ROOT}"
  local dest="${BASE_PATH:-/var/spool/apt-mirror}/client"
  local mirror_base rebuild="${src_root}/scripts/rebuild-publish-clients.sh"
  local confdir="${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}"
  mkdir -p "$dest"

  um_bootstrap_source_mirror_host_libs \
    || um_die "CLIENT_ARTIFACT=FAIL mirror host resolution / signing libraries missing"

  # Fresh bootstrap: operator-confirmed Mirror Server IP may not exist yet.
  # Auto-detection is a suggestion only — do not treat it as authoritative and
  # do not fail install when Configuration has not been saved.
  mirror_base=""
  if [[ -f "${confdir}/dp-upgrade-mirror.conf" ]]; then
    local existing_ip existing_url
    existing_ip="$(mirror_host_read_conf_field "${confdir}/dp-upgrade-mirror.conf" MIRROR_SERVER_IP || true)"
    existing_url="$(mirror_host_read_conf_field "${confdir}/dp-upgrade-mirror.conf" MIRROR_HTTP_URL || true)"
    if [[ -n "$existing_ip" ]] && ! mirror_host_is_placeholder_value "$existing_ip"; then
      if mirror_host_validate_ipv4_on_host "$existing_ip" 2>/dev/null \
        || [[ "${SKIP_MIRROR_HOST_VALIDATE:-0}" == "1" ]]; then
        mirror_base="$(mirror_base_url_from_ipv4 "$existing_ip")"
        RESOLVED_MIRROR_HOST_IPV4="$existing_ip"
        RESOLVED_MIRROR_BASE_URL="$mirror_base"
        MIRROR_IP_SOURCE=OPERATOR_CONFIRMED_CONFIG
      fi
    elif [[ -n "$existing_url" ]] && ! mirror_host_is_placeholder_value "$existing_url"; then
      existing_ip="$(mirror_host_extract_ipv4_from_url "$existing_url" || true)"
      if [[ -n "$existing_ip" ]] && mirror_host_validate_ipv4_on_host "$existing_ip" 2>/dev/null; then
        mirror_base="$(mirror_base_url_from_ipv4 "$existing_ip")"
        RESOLVED_MIRROR_HOST_IPV4="$existing_ip"
        RESOLVED_MIRROR_BASE_URL="$mirror_base"
        MIRROR_IP_SOURCE=OPERATOR_CONFIRMED_CONFIG
      fi
    fi
  fi

  if [[ -z "$mirror_base" ]]; then
    local suggested=""
    suggested="$(mirror_host_suggest_primary_ipv4 2>/dev/null || true)"
    um_info "MIRROR_IP_CONFIGURATION=REQUIRED_BEFORE_PREPARE"
    if [[ -n "$suggested" ]]; then
      um_info "Detected Mirror Server IP suggestion: ${suggested}"
      um_info "AUTO_DETECTION_ROLE=CONFIGURATION_SUGGESTION"
    fi
    um_bootstrap_persist_local_mirror_url ""
    um_info "INSTALL_RESOLVES_LOCAL_HOST_IP=DEFERRED"
  else
    um_bootstrap_persist_local_mirror_url "$mirror_base"
    um_info "INSTALL_RESOLVES_LOCAL_HOST_IP=YES url=${mirror_base}"
    um_info "MIRROR_IP_SOURCE=OPERATOR_CONFIRMED_CONFIG"
  fi
  um_info "CENTRAL_PRODUCTION_PRIVATE_KEY_REQUIRED=NO"
  um_info "OUT_OF_BAND_FINGERPRINT_REQUIRED=NO"
  um_info "EXPECTED_FINGERPRINT_COMMAND_ARGUMENT_REQUIRED=NO"

  # Install-time key directory is always under INSTALL_CONF_DIR. Ambient
  # LOCAL_CLIENT_SIGNING_DIR from a developer shell must not leak into bootstrap.
  if [[ "${UM_BOOTSTRAP_ALLOW_SIGNING_DIR_OVERRIDE:-0}" == "1" && -n "${LOCAL_CLIENT_SIGNING_DIR:-}" ]]; then
    :
  else
    LOCAL_CLIENT_SIGNING_DIR="${confdir}/client-signing"
  fi
  export LOCAL_CLIENT_SIGNING_DIR
  local_signing_ensure_keypair \
    || um_die "LOCAL_SIGNING_KEY_ACTION=FAIL INSTALL_RESULT=FAIL"
  um_ok "INSTALL_GENERATES_OR_REUSES_LOCAL_KEYPAIR=YES action=${LOCAL_SIGNING_KEY_ACTION}"
  um_info "LOCAL_SIGNING_KEY_PATH=${LOCAL_SIGNING_PRIVATE_KEY}"
  um_info "LOCAL_PUBLIC_KEY_PATH=${LOCAL_SIGNING_PUBLIC_KEY}"
  um_info "LOCAL_KEY_FINGERPRINT=${LOCAL_KEY_FINGERPRINT}"

  um_info "TARGET_INSTALL_GENERATES_OR_REUSES_LOCAL_PRIVATE_KEY=YES"
  um_info "TARGET_INSTALL_REBUILDS_CLIENTS=YES"
  um_info "TARGET_INSTALL_SIGNS_CLIENTS=YES"
  um_info "TARGET_INSTALL_REQUIRES_PREEXISTING_PRIVATE_KEY=NO"

  if ! um_bootstrap_selective_ready; then
    # Fresh bootstrap before Download and Prepare: deferred state is expected, not a warning.
    um_info "SELECTIVE_READY=NOT_PREPARED_YET"
    um_info "CLIENT_SET_BUILD=DEFERRED_UNTIL_OS_CORE"
    um_info "STALE_PREBUILT_CLIENT_PUBLISH=PROHIBITED"
    um_info "STALE_CLIENT_COPY_ALLOWED=NO"
    um_info "PARTIAL_CLIENT_DEPLOY_ALLOWED=NO"
    # Still publish Phase 2 helpers + local public key metadata (no hop clients).
    um_bootstrap_publish_phase2_helpers_only "$dest" || true
    local_signing_assert_private_not_published "$dest" \
      || um_die "PRIVATE_KEY_HTTP_PUBLISHED=YES"
    um_info "PRIVATE_KEY_HTTP_PUBLISHED=NO"
    um_info "CLIENT_FILES_READY=NOT_REQUIRED_DURING_BOOTSTRAP"
    um_info "CLIENT_HTTP_READY=DEFERRED_UNTIL_ENABLE_HTTP"
    return 0
  fi

  if [[ -z "$mirror_base" ]]; then
    um_info "CLIENT_SET_BUILD=DEFERRED_UNTIL_MIRROR_IP_CONFIGURED"
    um_bootstrap_publish_phase2_helpers_only "$dest" || true
    um_info "CLIENT_FILES_READY=NOT_REQUIRED_DURING_BOOTSTRAP"
    um_info "MIRROR_IP_CONFIGURATION=REQUIRED_BEFORE_PREPARE"
    return 0
  fi

  [[ -x "$rebuild" || -f "$rebuild" ]] \
    || um_die "CLIENT_ARTIFACT=FAIL missing ${rebuild}"

  local artifact_dir
  artifact_dir="${BASE_PATH:-/var/spool/apt-mirror}/.install-cache/client-build/bootstrap-$$"
  mkdir -p "$(dirname "$artifact_dir")"
  # Bootstrap builds from local FS; HTTP verification is Enable HTTP's job.
  if ! env \
    MIRROR_HTTP_URL="$mirror_base" \
    RESOLVED_MIRROR_HOST_IPV4="${RESOLVED_MIRROR_HOST_IPV4}" \
    RESOLVED_MIRROR_BASE_URL="$mirror_base" \
    LOCAL_CLIENT_SIGNING_DIR="$LOCAL_CLIENT_SIGNING_DIR" \
    CLIENT_HTTP_ROOT="$dest" \
    ARTIFACT_DIR="$artifact_dir" \
    SELECTIVE_ROOT="${SELECTIVE_MIRROR_ROOT:-${BASE_PATH:-/var/spool/apt-mirror}/selective}" \
    BASE_PATH="${BASE_PATH:-/var/spool/apt-mirror}" \
    CACHE_ROOT="${BASE_PATH:-/var/spool/apt-mirror}/.install-cache" \
    CONTENT_SOURCE=local-fs \
    SKIP_HTTP_VERIFY="${UM_BOOTSTRAP_SKIP_HTTP_VERIFY:-1}" \
    bash "$rebuild"
  then
    um_die "CLIENT_SET_BUILD_OR_PUBLISH=FAIL existing HTTP set left unchanged"
  fi

  um_bootstrap_verify_client_files "$dest" || um_die "CLIENT_FILES_READY=FAIL after deploy"
  local_signing_assert_private_not_published "$dest" \
    || um_die "PRIVATE_KEY_HTTP_PUBLISHED=YES"
  um_ok "CLIENT_HTTP_ARTIFACTS=PASS path=${dest}"
  um_ok "INSTALL_BUILDS_LOCAL_CLIENT_SET=YES"
  um_ok "INSTALL_SIGNS_LOCAL_CLIENT_SET=YES"
  um_ok "INSTALL_PUBLISHES_LOCAL_PUBLIC_KEY=YES"
  um_ok "INSTALL_ATOMICALLY_PUBLISHES_FULL_SET=YES"
  um_ok "CLIENT_SET_DEPLOY_ATOMIC=YES"
  um_ok "PARTIAL_CLIENT_DEPLOY_ALLOWED=NO"
  um_ok "PRIVATE_KEY_HTTP_PUBLISHED=NO"
}

um_bootstrap_verify_client_files() {
  local root="${1:-${BASE_PATH:-/var/spool/apt-mirror}/client}"
  local f
  local missing_flag=0
  [[ -d "$root" ]] || return 1
  for f in "${UM_CLIENT_REQUIRED_FILES[@]}"; do
    if [[ ! -f "${root}/${f}" ]]; then
      um_error "CLIENT_FILE_MISSING=${f}"
      missing_flag=1
    fi
  done
  [[ "$missing_flag" -eq 0 ]] || return 1

  for f in \
    dp-offline-upgrade-xenial-to-bionic.sh \
    dp-offline-upgrade-bionic-to-focal.sh \
    dp-offline-upgrade-focal-to-jammy.sh \
    dp-offline-upgrade-jammy-to-noble.sh \
    stage-dp-phase2.sh
  do
    if ! (cd "$root" && sha256sum -c "${f}.sha256" >/dev/null 2>&1); then
      um_error "CLIENT_CHECKSUM=FAIL file=${f}"
      return 1
    fi
  done
  # Public key (armor) + binary gpgv keyring must be published; private key must not.
  if [[ ! -f "${root}/public.gpg" && ! -f "${root}/offline-client-manifest.gpg" ]]; then
    um_error "CLIENT_PUBLIC_KEY=MISSING"
    return 1
  fi
  if [[ ! -f "${root}/public-keyring.gpg" ]]; then
    um_error "CLIENT_PUBLIC_KEYRING=MISSING"
    return 1
  fi
  if [[ -f "${root}/private.gpg" ]]; then
    um_error "PRIVATE_KEY_HTTP_PUBLISHED=YES"
    return 1
  fi
  return 0
}

um_bootstrap_install_nginx_base() {
  local base="${BASE_PATH:-/var/spool/apt-mirror}"
  local site_name="${NGINX_SITE_NAME:-apt-mirror}"
  local site_avail="/etc/nginx/sites-available/${site_name}"
  local site_en="/etc/nginx/sites-enabled/${site_name}"
  local tpl="${UM_PROJECT_ROOT}/templates/nginx.conf"
  local ngx_tmp backup=""

  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would install nginx site ${site_avail} (direct selective root, no current/previous)"
    return 0
  fi

  [[ -f "$tpl" ]] || um_die "NGINX_TEMPLATE=FAIL missing ${tpl}"
  um_command_exists nginx || um_die "NGINX_INSTALL=FAIL nginx binary missing"

  ngx_tmp="$(mktemp)"
  sed \
    -e "s|/var/spool/apt-mirror/selective|${base}/selective|g" \
    -e "s|/var/spool/apt-mirror/client|${base}/client|g" \
    -e "s|/var/spool/apt-mirror/dp-phase2|${base}/dp-phase2|g" \
    "$tpl" >"$ngx_tmp"

  # Refuse generation paths in generated config
  if grep -qE 'selective/current|published\.previous|/releases/' "$ngx_tmp"; then
    rm -f "$ngx_tmp"
    um_die "NGINX_CONFIG=FAIL generation path reference present"
  fi

  if [[ -f "$site_avail" ]] && cmp -s "$ngx_tmp" "$site_avail"; then
    um_ok "NGINX_CONFIG=PASS unchanged"
  else
    if [[ -f "$site_avail" ]]; then
      backup="${site_avail}.bak.$(date -u +%Y%m%d%H%M%S)"
      cp -a "$site_avail" "$backup"
    fi
    install -m 0644 "$ngx_tmp" "$site_avail"
    um_ok "NGINX_CONFIG=PASS installed ${site_avail}"
  fi
  rm -f "$ngx_tmp"

  ln -sfn "$site_avail" "$site_en"
  if [[ "${NGINX_DISABLE_DEFAULT:-true}" == "true" ]] && [[ -e /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
    um_ok "NGINX_DEFAULT_SITE=DISABLED"
  fi

  if ! nginx -t; then
    if [[ -n "$backup" && -f "$backup" ]]; then
      cp -a "$backup" "$site_avail"
      um_warn "Restored previous nginx site from ${backup}"
    fi
    um_die "NGINX_TEST=FAIL nginx -t failed"
  fi
  um_ok "NGINX_TEST=PASS"

  # Install/bootstrap: package + site config only. Do not start nginx, do not
  # enable on boot, and do not expose incomplete artifacts. If apt post-install
  # auto-started/enabled nginx, stop and disable it. Enable HTTP Distribution
  # owns enable/start/reload + HTTP verify.
  um_bootstrap_enforce_http_disabled
  um_ok "NGINX_CONFIG_READY=YES"
}

# Resolve systemctl binary (test override: UM_BOOTSTRAP_SYSTEMCTL_BIN).
um_bootstrap_systemctl() {
  if [[ -n "${UM_BOOTSTRAP_SYSTEMCTL_BIN:-}" ]]; then
    "${UM_BOOTSTRAP_SYSTEMCTL_BIN}" "$@"
  else
    systemctl "$@"
  fi
}

# Authoritative bootstrap HTTP isolation: nginx must be stopped and not
# boot-enabled so incomplete mirror artifacts are never served.
um_bootstrap_enforce_http_disabled() {
  local was_active=0
  local was_enabled=0
  local stop_needed=0
  local disable_needed=0

  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would enforce nginx stopped and boot-disabled (HTTP_DISTRIBUTION=DISABLED)"
    return 0
  fi

  if um_bootstrap_systemctl is-active --quiet nginx 2>/dev/null; then
    was_active=1
    stop_needed=1
  fi
  if um_bootstrap_systemctl is-enabled nginx >/dev/null 2>&1; then
    was_enabled=1
    disable_needed=1
  fi

  if [[ "$was_active" -eq 1 || "$was_enabled" -eq 1 ]]; then
    um_info "NGINX_PACKAGE_AUTO_START_DETECTED=YES"
  else
    um_info "NGINX_PACKAGE_AUTO_START_DETECTED=NO"
  fi

  if [[ "$stop_needed" -eq 1 ]]; then
    if ! um_bootstrap_systemctl stop nginx >/dev/null 2>&1; then
      um_error "BOOTSTRAP_NGINX_STOP=FAIL"
      um_die "BOOTSTRAP_HTTP_ISOLATION=FAIL nginx stop failed"
    fi
    if um_bootstrap_systemctl is-active --quiet nginx 2>/dev/null; then
      um_error "BOOTSTRAP_NGINX_STOP=FAIL still_active"
      um_die "BOOTSTRAP_HTTP_ISOLATION=FAIL nginx still active after stop"
    fi
    um_ok "BOOTSTRAP_NGINX_STOP=PASS"
  fi

  if [[ "$disable_needed" -eq 1 ]]; then
    if ! um_bootstrap_systemctl disable nginx >/dev/null 2>&1; then
      um_error "BOOTSTRAP_NGINX_DISABLE=FAIL"
      um_die "BOOTSTRAP_HTTP_ISOLATION=FAIL nginx disable failed"
    fi
    if um_bootstrap_systemctl is-enabled nginx >/dev/null 2>&1; then
      um_error "BOOTSTRAP_NGINX_DISABLE=FAIL still_enabled"
      um_die "BOOTSTRAP_HTTP_ISOLATION=FAIL nginx still enabled after disable"
    fi
    um_ok "BOOTSTRAP_NGINX_DISABLE=PASS"
  fi

  # Final fail-closed verification regardless of prior detection.
  if um_bootstrap_systemctl is-active --quiet nginx 2>/dev/null; then
    um_die "BOOTSTRAP_HTTP_ISOLATION=FAIL nginx active"
  fi
  if um_bootstrap_systemctl is-enabled nginx >/dev/null 2>&1; then
    um_die "BOOTSTRAP_HTTP_ISOLATION=FAIL nginx enabled"
  fi

  um_ok "BOOTSTRAP_HTTP_ISOLATION=PASS"
  um_info "HTTP_DISTRIBUTION=DISABLED"
  um_info "NGINX_SERVICE_STATE=STOPPED"
  um_info "NGINX_BOOT_ENABLE=DISABLED"
}

um_bootstrap_summary() {
  local bindir="${INSTALL_BIN_DIR:-/usr/local/bin}"
  cat <<EOF

DP Ubuntu Upgrade Mirror bootstrap completed.

Runtime:
  ${bindir}/ubuntu-offline-mirror mirror-manager

Mirror root:
  ${BASE_PATH:-/var/spool/apt-mirror}

Config (GUI credentials, mode 600 after save):
  ${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}/dp-upgrade-mirror.conf

Logs:
  /var/log/ubuntu-mirror-automation/

Next steps (Mirror Manager GUI):
  1. Configuration — Preparation Mode, ACPS username/password
  2. Download and Prepare Upgrade Files — R2 OS Core (FULL) + ACPS Phase 2
  3. Enable HTTP Distribution
  4. Verify Upgrade Readiness
  7. Show DP Client Upgrade Commands

Phase 2 Target is fixed at 6.6.0.
Supported Starting DP Versions: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0
If the DP is already on Ubuntu 24.04, choose Phase 2 Only.

Large downloads are NOT started by bootstrap. Start them from the GUI.

Recovery: take a full hypervisor snapshot of the DP VM before upgrade.
This project does not provide rollback commands.

EOF
}

um_bootstrap_maybe_start_gui() {
  local bindir="${INSTALL_BIN_DIR:-/usr/local/bin}"
  local cmd="${bindir}/ubuntu-offline-mirror"
  if [[ "${UM_NO_GUI:-0}" == "1" ]]; then
    if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
      um_dry "GUI auto-start skipped (--no-gui / --non-interactive)"
    else
      um_info "GUI auto-start skipped (--no-gui)"
    fi
    printf 'Re-open GUI: sudo %s mirror-manager\n' "$cmd"
    return 0
  fi
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would start Mirror Manager GUI on interactive TTY"
    return 0
  fi
  if [[ -t 0 && -t 1 ]]; then
    um_ok "Starting Mirror Manager GUI"
    exec "$cmd" mirror-manager
  fi
  cat <<EOF
NONINTERACTIVE_TTY=YES
Mirror Manager GUI was not started (no interactive TTY).

Re-open GUI:
  sudo ${cmd} mirror-manager
EOF
}

um_bootstrap_detect_install_mode() {
  local confdir="${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}"
  local runtime="${INSTALL_LIB_DIR:-/usr/local/lib/ubuntu-mirror}"
  if [[ -f "${confdir}/dp-upgrade-mirror.conf" ]] \
    || [[ -d "${confdir}/client-signing" ]] \
    || [[ -e "${runtime}/scripts/install-dp-upgrade-mirror.sh" ]]; then
    printf 'REINSTALL\n'
  else
    printf 'FRESH\n'
  fi
}

um_bootstrap_report_install_outcome() {
  local mode="${1:-FRESH}"
  local confdir="${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}"
  local base="${BASE_PATH:-/var/spool/apt-mirror}"
  local http_before="${2:-UNKNOWN}"
  local http_after="${3:-DISABLED}"
  local reenable="${4:-}"
  local next_action config_p selective_p phase2_p signing_p client_p

  config_p=NO
  selective_p=NO
  phase2_p=NO
  signing_p=NO
  client_p=NO
  [[ -f "${confdir}/dp-upgrade-mirror.conf" ]] && config_p=YES
  [[ -d "${base}/selective/ubuntu" || -f "${base}/selective/state/READY" ]] && selective_p=YES
  [[ -d "${base}/dp-phase2/6.6.0" ]] && phase2_p=YES
  [[ -f "${confdir}/client-signing/private.gpg" ]] && signing_p=YES
  [[ -f "${base}/client/stage-dp-phase2.sh" \
    || -f "${base}/client/dp-offline-upgrade-xenial-to-bionic.sh" ]] && client_p=YES

  if [[ "$mode" == "FRESH" ]]; then
    next_action="CONFIGURATION_REQUIRED"
  elif [[ "$http_after" != "ENABLED" ]]; then
    reenable="${reenable:-YES}"
    next_action="Enable HTTP Distribution"
  else
    next_action="Verify Upgrade Readiness"
  fi

  cat <<EOF
INSTALL_MODE=${mode}
CONFIG_PRESERVED=${config_p}
SELECTIVE_PRESERVED=${selective_p}
PHASE2_PRESERVED=${phase2_p}
SIGNING_KEY_PRESERVED=${signing_p}
CLIENT_SET_PRESERVED=${client_p}
HTTP_STATE_BEFORE=${http_before}
HTTP_STATE_AFTER=${http_after}
HTTP_REENABLE_REQUIRED=${reenable:-NO}
NEXT_REQUIRED_ACTION=${next_action}
EOF
}

um_bootstrap_http_state_label() {
  if um_bootstrap_systemctl is-active --quiet nginx 2>/dev/null; then
    printf 'ENABLED\n'
  else
    printf 'DISABLED\n'
  fi
}

um_bootstrap_run() {
  phase() { printf '\n==> %s\n' "$*"; }
  local install_mode http_before http_after reenable=NO
  local config_p=NO selective_p=NO phase2_p=NO signing_p=NO client_p=NO
  local confdir="${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}"
  local base="${BASE_PATH:-/var/spool/apt-mirror}"

  install_mode="$(um_bootstrap_detect_install_mode)"
  http_before="$(um_bootstrap_http_state_label 2>/dev/null || printf 'UNKNOWN')"
  [[ -f "${confdir}/dp-upgrade-mirror.conf" ]] && config_p=YES
  [[ -d "${base}/selective/ubuntu" || -f "${base}/selective/state/READY" ]] && selective_p=YES
  [[ -d "${base}/dp-phase2/6.6.0" ]] && phase2_p=YES
  [[ -f "${confdir}/client-signing/private.gpg" ]] && signing_p=YES
  [[ -f "${base}/client/stage-dp-phase2.sh" \
    || -f "${base}/client/dp-offline-upgrade-xenial-to-bionic.sh" ]] && client_p=YES

  um_info "INSTALL_MODE=${install_mode}"
  um_info "HTTP_STATE_BEFORE=${http_before}"

  phase "Host preflight (Ubuntu 24.04)"
  um_bootstrap_host_preflight

  phase "Storage preflight"
  um_bootstrap_storage_preflight

  phase "Install required packages"
  um_bootstrap_install_packages

  phase "Prepare directories"
  um_bootstrap_prepare_dirs

  phase "Install Mirror Manager runtime"
  um_bootstrap_install_runtime

  phase "Install nginx base configuration"
  um_bootstrap_install_nginx_base

  http_after="$(um_bootstrap_http_state_label 2>/dev/null || printf 'DISABLED')"
  if [[ "$install_mode" == "FRESH" ]]; then
    config_p=NO
    selective_p=NO
    phase2_p=NO
    signing_p=NO
    client_p=NO
    reenable=NO
  else
    # Reinstall: report whether prior artifacts remain after runtime update.
    config_p=NO; selective_p=NO; phase2_p=NO; signing_p=NO; client_p=NO
    [[ -f "${confdir}/dp-upgrade-mirror.conf" ]] && config_p=YES
    [[ -d "${base}/selective/ubuntu" || -f "${base}/selective/state/READY" ]] && selective_p=YES
    [[ -d "${base}/dp-phase2/6.6.0" ]] && phase2_p=YES
    [[ -f "${confdir}/client-signing/private.gpg" ]] && signing_p=YES
    [[ -f "${base}/client/stage-dp-phase2.sh" \
      || -f "${base}/client/dp-offline-upgrade-xenial-to-bionic.sh" ]] && client_p=YES
    if [[ "$http_before" == "ENABLED" && "$http_after" != "ENABLED" ]]; then
      reenable=YES
    elif [[ "$http_after" != "ENABLED" ]]; then
      reenable=YES
    fi
  fi

  phase "Bootstrap summary"
  local next_action
  if [[ "$install_mode" == "FRESH" ]]; then
    next_action="CONFIGURATION_REQUIRED"
  elif [[ "$reenable" == "YES" || "$http_after" != "ENABLED" ]]; then
    next_action="Enable HTTP Distribution"
  else
    next_action="Verify Upgrade Readiness"
  fi
  cat <<EOF
INSTALL_MODE=${install_mode}
CONFIG_PRESERVED=${config_p}
SELECTIVE_PRESERVED=${selective_p}
PHASE2_PRESERVED=${phase2_p}
SIGNING_KEY_PRESERVED=${signing_p}
CLIENT_SET_PRESERVED=${client_p}
HTTP_STATE_BEFORE=${http_before}
HTTP_STATE_AFTER=${http_after}
HTTP_REENABLE_REQUIRED=${reenable}
NEXT_REQUIRED_ACTION=${next_action}
EOF
  um_bootstrap_summary

  um_bootstrap_maybe_start_gui
}
