#!/usr/bin/env bash
# validate.sh — Ubuntu Mirror Server validation (install | operational)
# Exit: 0=ready/OK, 1=sync pending/warnings, 2=critical failure
set -euo pipefail

UM_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${UM_PROJECT_ROOT}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${UM_PROJECT_ROOT}/lib/config.sh"
# shellcheck source=lib/state.sh
source "${UM_PROJECT_ROOT}/lib/state.sh"
if [[ -f /usr/local/lib/ubuntu-mirror/common.sh ]]; then
  # shellcheck source=/dev/null
  source /usr/local/lib/ubuntu-mirror/common.sh
  # shellcheck source=/dev/null
  source /usr/local/lib/ubuntu-mirror/config.sh
  # shellcheck source=/dev/null
  source /usr/local/lib/ubuntu-mirror/state.sh
fi

UM_CONFIG_ARG=""
UM_QUIET=0
UM_MODE="operational" # install | operational
UM_SYNC_PENDING=0

usage() {
  cat <<'EOF'
Usage: ./validate.sh [--config PATH] [--mode install|operational] [--quiet]

Modes:
  install       Critical install checks only; unsynced versions = PENDING/WARNING
  operational   Full readiness (Release files, HTTP 200, timer, sync complete)

Exit codes:
  0 = ready / install OK
  1 = installed but sync pending or warnings (INSTALLATION_OK_SYNC_PENDING)
  2 = critical failure
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) UM_CONFIG_ARG="${2:-}"; shift 2 ;;
      --mode) UM_MODE="${2:-}"; shift 2 ;;
      --quiet) UM_QUIET=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) um_die "Unknown option: $1" ;;
    esac
  done
  case "$UM_MODE" in
    install|operational) ;;
    *) um_die "--mode must be install or operational" ;;
  esac
}

check_ubuntu_version() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" ]]; then
      if [[ "${VERSION_ID:-}" == "24.04" ]]; then
        um_result PASS "Ubuntu Version" "${PRETTY_NAME}"
      else
        um_result WARNING "Ubuntu Version" "Guide targets 24.04; found ${PRETTY_NAME}"
      fi
    else
      um_result WARNING "Ubuntu Version" "Non-Ubuntu host: ${PRETTY_NAME:-unknown}"
    fi
  else
    um_result FAIL "Ubuntu Version" "/etc/os-release missing"
  fi
}

check_disk_mounted() {
  if [[ ! -d "$BASE_PATH" ]]; then
    um_result FAIL "Disk Mounted" "BASE_PATH missing: $BASE_PATH"
    return
  fi
  if um_path_mounted "$BASE_PATH"; then
    local src
    src="$(findmnt -n -o SOURCE -T "$BASE_PATH" 2>/dev/null || echo unknown)"
    # Warn if same filesystem as root and DATA_DEVICE expected
    local root_src base_src
    root_src="$(findmnt -n -o SOURCE -T / 2>/dev/null || true)"
    base_src="$src"
    if [[ -n "$DATA_DEVICE" ]] && [[ "$root_src" == "$base_src" ]]; then
      um_result WARNING "Disk Mounted" "$BASE_PATH on root FS; DATA_DEVICE=$DATA_DEVICE not separate"
    else
      um_result PASS "Disk Mounted" "$BASE_PATH <- $src"
    fi
  else
    um_result FAIL "Disk Mounted" "$BASE_PATH not a mount point"
  fi
}

check_disk_space() {
  if [[ ! -d "$BASE_PATH" ]]; then
    um_result FAIL "Disk Space" "path missing"
    return
  fi
  local pct avail_kib avail_gib
  pct="$(um_disk_usage_percent "$BASE_PATH" || echo 0)"
  avail_kib="$(df -Pk "$BASE_PATH" | awk 'NR==2 {print $4}')"
  avail_gib=$((avail_kib / 1024 / 1024))
  if [[ "$pct" -ge "${DISK_CRIT_PERCENT}" ]]; then
    um_result FAIL "Disk Space" "${pct}% used, ${avail_gib} GiB free (crit>=${DISK_CRIT_PERCENT}%)"
  elif [[ "$pct" -ge "${DISK_WARN_PERCENT}" ]]; then
    um_result WARNING "Disk Space" "${pct}% used, ${avail_gib} GiB free"
  elif [[ "$avail_gib" -lt "${MIN_FREE_GIB}" ]] && [[ ! -d "$DIST_ROOT/noble" ]]; then
    um_result WARNING "Disk Space" "${avail_gib} GiB free < recommended ${MIN_FREE_GIB} GiB for initial ${MIRROR_MODE} sync"
  else
    um_result PASS "Disk Space" "${pct}% used, ${avail_gib} GiB free"
  fi
}

check_mirror_directory() {
  local ok=1
  for d in "$MIRROR_PATH" "$SKEL_PATH" "$VAR_PATH"; do
    if [[ ! -d "$d" ]]; then
      ok=0
      um_result FAIL "Mirror Directory" "missing $d"
    fi
  done
  if [[ "$ok" -eq 1 ]]; then
    um_result PASS "Mirror Directory" "$BASE_PATH/{mirror,skel,var}"
  fi
}

check_apt_mirror_installed() {
  if um_command_exists apt-mirror; then
    um_result PASS "apt-mirror installed" "$(command -v apt-mirror)"
  else
    um_result FAIL "apt-mirror installed" "not found in PATH"
  fi
  if [[ -f /etc/apt/mirror.list ]]; then
    if grep -qE '^set[[:space:]]+base_path' /etc/apt/mirror.list; then
      um_result PASS "apt-mirror config" "base_path set in /etc/apt/mirror.list"
    else
      um_result FAIL "apt-mirror config" "base_path missing/commented (invalid config)"
    fi
  else
    um_result FAIL "apt-mirror config" "/etc/apt/mirror.list missing"
  fi
}

check_nginx_installed() {
  if um_command_exists nginx; then
    um_result PASS "nginx installed" "$(command -v nginx)"
  else
    um_result FAIL "nginx installed" "not found"
    return
  fi
  if systemctl is-active --quiet nginx 2>/dev/null; then
    um_result PASS "nginx running" "active"
  else
    um_result FAIL "nginx running" "not active"
  fi
}

check_nginx_config() {
  if ! um_command_exists nginx; then
    um_result FAIL "nginx config valid" "nginx missing"
    return
  fi
  if nginx -t >/dev/null 2>&1; then
    um_result PASS "nginx config valid" "nginx -t ok"
  else
    um_result FAIL "nginx config valid" "nginx -t failed"
  fi
  local site="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
  if [[ -e "$site" ]]; then
    um_result PASS "nginx site enabled" "$site"
  else
    um_result FAIL "nginx site enabled" "$site missing"
  fi
}

check_systemd_service() {
  if [[ -f /etc/systemd/system/apt-mirror.service ]]; then
    if systemctl cat apt-mirror.service >/dev/null 2>&1; then
      um_result PASS "systemd service" "apt-mirror.service present"
    else
      um_result FAIL "systemd service" "cannot load apt-mirror.service"
    fi
  else
    um_result FAIL "systemd service" "unit file missing"
  fi
}

check_systemd_timer() {
  if [[ ! -f /etc/systemd/system/apt-mirror.timer ]]; then
    um_result FAIL "systemd timer" "unit file missing"
    return
  fi
  if [[ "$UM_MODE" == "install" ]]; then
    um_result PASS "systemd timer" "unit installed (disabled until initial sync)"
    return
  fi
  if systemctl is-enabled --quiet apt-mirror.timer 2>/dev/null; then
    um_result PASS "systemd timer" "enabled"
  else
    um_result WARNING "systemd timer" "disabled until initial sync / finalize"
    UM_SYNC_PENDING=1
  fi
}

check_mirror_url_reachable() {
  local url="${MIRROR_URL}"
  local code
  code="$(curl -sS -o /dev/null --max-time "${HTTP_TIMEOUT_SEC}" -w '%{http_code}' "$url" 2>/dev/null || true)"
  if [[ -z "$code" ]]; then
    code="000"
  fi
  if [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
    um_result PASS "Mirror URL reachable" "$url (HTTP $code)"
  else
    if [[ "$UM_MODE" == "install" ]]; then
      um_result WARNING "Mirror URL reachable" "PENDING (HTTP $code)"
      UM_SYNC_PENDING=1
    else
      um_result FAIL "Mirror URL reachable" "$url unreachable (HTTP $code)"
    fi
  fi
}

check_ubuntu_versions() {
  local ver present=0
  for ver in ${UBUNTU_VERSIONS}; do
    if [[ -d "${DIST_ROOT}/${ver}" ]]; then
      ((present++)) || true
      um_result PASS "Ubuntu version ${ver}" "dists present"
    else
      if [[ "$UM_MODE" == "install" ]]; then
        um_result WARNING "Ubuntu version ${ver}" "PENDING (not yet synced)"
        UM_SYNC_PENDING=1
      else
        um_result FAIL "Ubuntu version ${ver}" "not available"
      fi
    fi
  done
  if [[ "$present" -eq 0 ]]; then
    if [[ "$UM_MODE" == "install" ]]; then
      um_result WARNING "Ubuntu versions" "INSTALLATION_OK_SYNC_PENDING"
      UM_SYNC_PENDING=1
    else
      um_result FAIL "Ubuntu versions" "none synced"
    fi
  fi
}

check_http_status() {
  local ver code url
  local any_ok=0
  for ver in ${UBUNTU_VERSIONS}; do
    url="${MIRROR_URL}/ubuntu/dists/${ver}/Release"
    code="$(curl -sS -o /dev/null --max-time "${HTTP_TIMEOUT_SEC}" -w '%{http_code}' "$url" 2>/dev/null || true)"
    [[ -z "$code" ]] && code="000"
    if [[ "$code" == "200" ]]; then
      ((any_ok++)) || true
      um_result PASS "HTTP Status ${ver}" "200 OK"
    else
      if [[ "$UM_MODE" == "install" ]]; then
        um_result WARNING "HTTP Status ${ver}" "PENDING (HTTP $code)"
        UM_SYNC_PENDING=1
      else
        um_result FAIL "HTTP Status ${ver}" "HTTP $code"
      fi
    fi
  done
  if [[ "$any_ok" -eq 0 && "$UM_MODE" == "install" ]]; then
    um_result WARNING "HTTP Status" "expected before initial sync completes"
  fi
}

check_permissions() {
  if [[ ! -d "$BASE_PATH" ]]; then
    um_result WARNING "Permissions" "BASE_PATH missing — skip"
    return
  fi
  local issues=0
  if [[ ! -r "$BASE_PATH" ]] || [[ ! -x "$BASE_PATH" ]]; then
    um_result FAIL "Permissions" "$BASE_PATH not readable/executable"
    issues=1
  fi
  if [[ -f /etc/apt/mirror.list ]] && [[ ! -r /etc/apt/mirror.list ]]; then
    um_result FAIL "Permissions" "/etc/apt/mirror.list not readable"
    issues=1
  fi
  if [[ "$issues" -eq 0 ]]; then
    um_result PASS "Permissions" "base paths readable"
  fi
}

check_logs() {
  local ok=0
  for f in "$APT_MIRROR_LOG" "$APT_MIRROR_INITIAL_LOG" "$LOG_DIR"; do
    if [[ -e "$f" ]]; then
      ((ok++)) || true
    fi
  done
  if [[ -d "$LOG_DIR" ]]; then
    um_result PASS "Logs" "log dir $LOG_DIR present"
  else
    um_result WARNING "Logs" "$LOG_DIR missing"
  fi
  if [[ -f "$APT_MIRROR_LOG" ]] || [[ -f "$APT_MIRROR_INITIAL_LOG" ]]; then
    um_result PASS "Logs sync" "apt-mirror log present"
  else
    um_result WARNING "Logs sync" "no apt-mirror log yet (sync not started)"
  fi
}

check_health() {
  if [[ "$UM_MODE" == "install" ]]; then
    return 0
  fi
  local status_bin=""
  if [[ -x "${INSTALL_BIN_DIR}/mirror-status" ]]; then
    status_bin="${INSTALL_BIN_DIR}/mirror-status"
  elif [[ -x "${INSTALL_BIN_DIR}/mirror-status.sh" ]]; then
    status_bin="${INSTALL_BIN_DIR}/mirror-status.sh"
  elif [[ -x "${UM_PROJECT_ROOT}/scripts/mirror-status.sh" ]]; then
    status_bin="${UM_PROJECT_ROOT}/scripts/mirror-status.sh"
  fi
  if [[ -z "$status_bin" ]]; then
    um_result WARNING "Health" "mirror-status not installed"
    return
  fi
  if "$status_bin" --quiet >/dev/null 2>&1; then
    um_result PASS "Health" "ok"
  else
    local rc=$?
    if [[ "$rc" -eq 1 ]]; then
      um_result WARNING "Health" "warnings"
    else
      um_result FAIL "Health" "exit $rc"
    fi
  fi
}

check_upgrade_profile() {
  if [[ "$UM_MODE" == "install" ]]; then
    # Still reject minimal config during install validation
    :
  fi
  local py=""
  if [[ -f "${UM_PROJECT_ROOT}/scripts/lib/validate_upgrade_profile.py" ]]; then
    py="${UM_PROJECT_ROOT}/scripts/lib/validate_upgrade_profile.py"
  elif [[ -f /usr/local/lib/ubuntu-mirror/validate_upgrade_profile.py ]]; then
    py=/usr/local/lib/ubuntu-mirror/validate_upgrade_profile.py
  fi
  if [[ -z "$py" ]]; then
    um_result WARNING "upgrade profile" "validate_upgrade_profile.py not installed"
    return
  fi
  local profile=""
  if [[ -f "${UM_PROJECT_ROOT}/config/offline-upgrade-profile.json" ]]; then
    profile="${UM_PROJECT_ROOT}/config/offline-upgrade-profile.json"
  elif [[ -f /etc/ubuntu-mirror/offline-upgrade-profile.json ]]; then
    profile=/etc/ubuntu-mirror/offline-upgrade-profile.json
  fi
  local out rc
  out="$(mktemp)"
  set +e
  if [[ "$UM_MODE" == "install" ]]; then
    python3 "$py" check-profile \
      --mirror-root "${BASE_PATH}" \
      --profile "${profile}" \
      --mirror-list /etc/apt/mirror.list \
      --mirror-conf "${UM_CONFIG_PATH}" \
      --project-root "${UM_PROJECT_ROOT}" \
      --result-json "${BASE_PATH}/offline/upgrade-profile-check.json" \
      >"$out" 2>&1
  else
    python3 "$py" validate \
      --mirror-root "${BASE_PATH}" \
      --profile "${profile}" \
      --mirror-list /etc/apt/mirror.list \
      --mirror-conf "${UM_CONFIG_PATH}" \
      --project-root "${UM_PROJECT_ROOT}" \
      --skip-external-gates \
      --result-json "${BASE_PATH}/offline/readiness-validation.json" \
      >"$out" 2>&1
  fi
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    um_result PASS "upgrade profile" "offline-upgrade-full"
  else
    if grep -q 'UNSUPPORTED_MINIMAL_PROFILE\|minimal_detected=True' "$out"; then
      um_result FAIL "upgrade profile" "UNSUPPORTED_MINIMAL_PROFILE — minimal not allowed"
    else
      um_result FAIL "upgrade profile" "INCOMPLETE_UPGRADE_PROFILE (see offline/*-validation.json)"
    fi
    if [[ "$UM_QUIET" != "1" ]]; then
      cat "$out" >&2 || true
    fi
  fi
  rm -f "$out"
}

check_by_hash() {
  if [[ "$UM_MODE" == "install" ]]; then
    return 0
  fi
  local py=""
  local offline_bin=""
  if [[ -f "${UM_PROJECT_ROOT}/scripts/lib/sync_by_hash.py" ]]; then
    py="${UM_PROJECT_ROOT}/scripts/lib/sync_by_hash.py"
  elif [[ -f /usr/local/lib/ubuntu-mirror/sync_by_hash.py ]]; then
    py=/usr/local/lib/ubuntu-mirror/sync_by_hash.py
  fi
  if [[ -z "$py" ]]; then
    um_result WARNING "by-hash validation" "sync_by_hash.py not installed"
    return
  fi
  if [[ ! -d "${DIST_ROOT:-}" ]]; then
    um_result FAIL "by-hash validation" "DIST_ROOT missing"
    return
  fi
  local out rc
  out="$(mktemp)"
  set +e
  python3 "$py" validate \
    --mirror-root "${BASE_PATH}" \
    --ubuntu-root "$(dirname "${DIST_ROOT}")" \
    --quiet >"$out" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]] && grep -q 'validation_result=PASS' "$out"; then
    local present missing
    present="$(awk -F= '/^present_by_hash_files=/{print $2}' "$out")"
    missing="$(awk -F= '/^missing_by_hash_files=/{print $2}' "$out")"
    um_result PASS "by-hash validation" "PASS present=${present:-?} missing=${missing:-0}"
  else
    um_result FAIL "by-hash validation" "FAIL (see sync_by_hash validate / offline/by-hash-validation.json)"
    if [[ "$UM_QUIET" != "1" ]]; then
      cat "$out" >&2 || true
    fi
  fi
  rm -f "$out"
}

check_security_compat() {
  if [[ "$UM_MODE" == "install" ]]; then
    return 0
  fi
  local py=""
  if [[ -f "${UM_PROJECT_ROOT}/scripts/lib/validate_security_compat.py" ]]; then
    py="${UM_PROJECT_ROOT}/scripts/lib/validate_security_compat.py"
  elif [[ -f /usr/local/lib/ubuntu-mirror/validate_security_compat.py ]]; then
    py=/usr/local/lib/ubuntu-mirror/validate_security_compat.py
  fi
  if [[ -z "$py" ]]; then
    um_result WARNING "security repository" "validate_security_compat.py not installed"
    return
  fi
  local out rc discovery=()
  out="$(mktemp)"
  if [[ -d "${UM_PROJECT_ROOT}/artifacts/upgrade-discovery" ]]; then
    discovery=(--discovery-root "${UM_PROJECT_ROOT}/artifacts/upgrade-discovery")
  fi
  set +e
  python3 "$py" \
    --mirror-root "${BASE_PATH}" \
    --ubuntu-root "$(dirname "${DIST_ROOT}")" \
    --http-base "${MIRROR_URL}" \
    "${discovery[@]}" \
    --require-by-hash \
    --quiet >"$out" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]] && grep -q 'validation_result=PASS' "$out"; then
    local suites
    suites="$(awk -F= '/^security_suites_found=/{print $2}' "$out")"
    um_result PASS "security repository" "PASS suites=${suites:-?}"
  else
    um_result FAIL "security repository" "FAIL (see offline/security-validation.json)"
    if [[ "$UM_QUIET" != "1" ]]; then
      cat "$out" >&2 || true
    fi
  fi
  rm -f "$out"
}

check_release_upgraders() {
  if [[ "$UM_MODE" == "install" ]]; then
    return 0
  fi
  local py=""
  if [[ -f "${UM_PROJECT_ROOT}/scripts/lib/sync_release_upgraders.py" ]]; then
    py="${UM_PROJECT_ROOT}/scripts/lib/sync_release_upgraders.py"
  elif [[ -f /usr/local/lib/ubuntu-mirror/sync_release_upgraders.py ]]; then
    py=/usr/local/lib/ubuntu-mirror/sync_release_upgraders.py
  fi
  if [[ -z "$py" ]]; then
    um_result WARNING "release upgraders" "sync_release_upgraders.py not installed"
    return
  fi
  local out rc
  out="$(mktemp)"
  set +e
  python3 "$py" validate \
    --mirror-root "${BASE_PATH}" \
    --ubuntu-root "$(dirname "${DIST_ROOT}")" \
    --public-base-url "${MIRROR_URL}" \
    --http-base "${MIRROR_URL}" \
    --quiet >"$out" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]] && grep -q 'validation_result=PASS' "$out"; then
    local present
    present="$(awk -F= '/^upgrader_tarballs_present=/{print $2}' "$out")"
    um_result PASS "release upgraders" "PASS tarballs=${present:-?}"
  else
    um_result FAIL "release upgraders" "FAIL (see offline/release-upgrader-validation.json)"
    if [[ "$UM_QUIET" != "1" ]]; then
      cat "$out" >&2 || true
    fi
  fi
  rm -f "$out"
}

check_legacy_releases() {
  if [[ "$UM_MODE" == "install" ]]; then
    return 0
  fi
  local py=""
  if [[ -f "${UM_PROJECT_ROOT}/scripts/lib/sync_legacy_releases.py" ]]; then
    py="${UM_PROJECT_ROOT}/scripts/lib/sync_legacy_releases.py"
  elif [[ -f /usr/local/lib/ubuntu-mirror/sync_legacy_releases.py ]]; then
    py=/usr/local/lib/ubuntu-mirror/sync_legacy_releases.py
  fi
  if [[ -z "$py" ]]; then
    um_result WARNING "legacy Xenial" "sync_legacy_releases.py not installed"
    return
  fi
  local out rc discovery=()
  out="$(mktemp)"
  if [[ -d "${UM_PROJECT_ROOT}/artifacts/upgrade-discovery" ]]; then
    discovery=(--discovery-root "${UM_PROJECT_ROOT}/artifacts/upgrade-discovery")
  fi
  set +e
  python3 "$py" validate \
    --mirror-root "${BASE_PATH}" \
    --ubuntu-root "$(dirname "${DIST_ROOT}")" \
    --series xenial \
    --target-series bionic \
    "${discovery[@]}" \
    --quiet >"$out" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]] && grep -q 'validation_result=PASS' "$out"; then
    local status
    status="$(awk -F= '/^source_status=/{print $2}' "$out")"
    um_result PASS "legacy Xenial" "PASS source_status=${status:-COMPLETE}"
  else
    um_result FAIL "legacy Xenial" "FAIL (see offline/legacy-release-validation.json / xenial-validation.json)"
    if [[ "$UM_QUIET" != "1" ]]; then
      cat "$out" >&2 || true
    fi
  fi
  rm -f "$out"
}

check_dp_phase2() {
  # Separate from OS mirror READY checks. Missing Phase 2 => WARNING/PENDING only.
  local enabled="${DP_PHASE2_ENABLED:-true}"
  local ver="${DP_PHASE2_VERSION:-6.6.0}"
  local root="${DP_PHASE2_ROOT:-${BASE_PATH}/dp-phase2}"
  local current="${root}/${ver}/current"
  local public_path="${DP_PHASE2_PUBLIC_PATH:-/dp-phase2/${ver}/}"
  local stable="dp_bundle_${ver}-current.tar"

  if [[ "$enabled" != "true" ]]; then
    um_result PASS "DP Phase 2" "disabled in config"
    return 0
  fi

  if [[ ! -L "$current" || ! -d "$current" ]]; then
    um_result WARNING "DP Phase 2 pending" "current release missing at ${current}"
    return 0
  fi

  um_result PASS "DP Phase 2 current" "$(readlink -f "$current" 2>/dev/null || readlink "$current")"

  local required=(
    aelladeb_py3_common.tar.gz
    aelladeb_py3_common.tar.gz.sha1
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb"
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1"
    bringup_py3_dp_after_os_upgrade.sh
    bringup_py3_dp_after_os_upgrade.sh.sha1
    "images-${ver}.list"
    "images-${ver}.tar"
    "images-${ver}.tar.sha256"
  )
  local f missing=0
  for f in "${required[@]}"; do
    if [[ ! -f "${current}/files/${f}" ]]; then
      missing=1
      break
    fi
  done
  if [[ "$missing" -eq 1 ]]; then
    um_result FAIL "DP Phase 2 file count" "required files missing under ${current}/files"
    return 0
  fi
  um_result PASS "DP Phase 2 file count" "9 files present"

  # Checksums (first field only)
  local ok_sum=1
  local expected actual
  expected="$(awk 'NF {print $1; exit}' "${current}/files/aelladeb_py3_common.tar.gz.sha1")"
  actual="$(sha1sum "${current}/files/aelladeb_py3_common.tar.gz" | awk '{print $1}')"
  [[ "${expected,,}" == "${actual,,}" ]] || ok_sum=0
  expected="$(awk 'NF {print $1; exit}' "${current}/files/images-${ver}.tar.sha256")"
  actual="$(sha256sum "${current}/files/images-${ver}.tar" | awk '{print $1}')"
  [[ "${expected,,}" == "${actual,,}" ]] || ok_sum=0
  if [[ "$ok_sum" -ne 1 ]]; then
    um_result FAIL "DP Phase 2 checksums" "ACPS checksum mismatch"
  else
    um_result PASS "DP Phase 2 checksums" "sha1/sha256 OK"
  fi

  if [[ -f "${current}/${stable}" && -f "${current}/${stable}.sha256" ]]; then
    expected="$(awk 'NF {print $1; exit}' "${current}/${stable}.sha256")"
    actual="$(sha256sum "${current}/${stable}" | awk '{print $1}')"
    local tar_lines
    tar_lines="$(tar -tf "${current}/${stable}" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${expected,,}" == "${actual,,}" && "$tar_lines" == "9" ]]; then
      um_result PASS "DP Phase 2 bundle" "${stable} sha256 OK entries=9"
    else
      um_result FAIL "DP Phase 2 bundle" "sha256 or tar list invalid"
    fi
  else
    um_result FAIL "DP Phase 2 bundle" "stable bundle missing"
  fi

  # HTTP checks (operational prefers live; install still probes lightly)
  local base="${MIRROR_URL}${public_path}"
  base="${base%/}"
  local code
  code="$(curl -sS -o /dev/null --max-time "${HTTP_TIMEOUT_SEC:-10}" -w '%{http_code}' "${base}/release.env" 2>/dev/null || true)"
  [[ -z "$code" ]] && code="000"
  if [[ "$code" == "200" ]]; then
    local code2 code3
    code2="$(curl -sS -o /dev/null --max-time "${HTTP_TIMEOUT_SEC:-10}" -w '%{http_code}' "${base}/${stable}.sha256" 2>/dev/null || true)"
    code3="$(curl -sS -o /dev/null --max-time "${HTTP_TIMEOUT_SEC:-10}" -I -w '%{http_code}' "${base}/${stable}" 2>/dev/null || true)"
    if [[ "$code2" == "200" && ( "$code3" == "200" || "$code3" == "206" ) ]]; then
      um_result PASS "DP Phase 2 HTTP" "${base}/ OK"
    else
      um_result FAIL "DP Phase 2 HTTP" "release.env=200 but bundle/sidecar HTTP ${code2}/${code3}"
    fi
  else
    if [[ "$UM_MODE" == "install" ]]; then
      um_result WARNING "DP Phase 2 HTTP" "PENDING (HTTP ${code})"
    else
      um_result FAIL "DP Phase 2 HTTP" "HTTP ${code} for ${base}/release.env"
    fi
  fi
}

main() {
  parse_args "$@"
  um_setup_trap
  um_load_config "$UM_CONFIG_ARG"
  um_set_log_file "${LOG_DIR}/validate.log"
  um_ensure_log_dir
  um_result_reset
  UM_SYNC_PENDING=0

  if [[ "$UM_QUIET" != "1" ]]; then
    printf '%sValidation mode: %s%s\n\n' "$UM_C_BOLD" "$UM_MODE" "$UM_C_RESET"
  fi

  check_ubuntu_version
  check_disk_mounted
  check_disk_space
  check_mirror_directory
  check_apt_mirror_installed
  check_nginx_installed
  check_nginx_config
  check_systemd_service
  check_systemd_timer
  check_permissions
  check_upgrade_profile

  if [[ "$UM_MODE" == "operational" ]]; then
    check_mirror_url_reachable
    check_ubuntu_versions
    check_http_status
    check_by_hash
    check_security_compat
    check_release_upgraders
    check_legacy_releases
    check_logs
    check_health
    check_dp_phase2
  else
    # install mode: report sync as pending, never FAIL solely for missing dists
    check_ubuntu_versions
    check_logs
    check_dp_phase2
  fi

  if [[ "$UM_QUIET" != "1" ]]; then
    if [[ "$UM_SYNC_PENDING" -eq 1 && "$UM_FAIL_COUNT" -eq 0 ]]; then
      printf '\nStatus: INSTALLATION_OK_SYNC_PENDING\n'
    fi
  fi

  set +e
  um_result_summary
  local rc=$?
  set -e

  # install mode: warnings/sync-pending => exit 1 is OK for installer; no fails => treat pending as 1
  if [[ "$UM_MODE" == "install" ]]; then
    if [[ "$UM_FAIL_COUNT" -gt 0 ]]; then
      exit 2
    fi
    if [[ "$UM_SYNC_PENDING" -eq 1 || "$UM_WARN_COUNT" -gt 0 ]]; then
      exit 1
    fi
    exit 0
  fi

  # operational
  if [[ "$UM_FAIL_COUNT" -gt 0 ]]; then
    exit 2
  fi
  if [[ "$UM_SYNC_PENDING" -eq 1 || "$UM_WARN_COUNT" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
