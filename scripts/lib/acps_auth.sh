#!/usr/bin/env bash
# scripts/lib/acps_auth.sh — shared ACPS curl auth/TLS (netrc, no argv secrets)
# Used by Mirror Manager (acps_acquire.sh) and standalone download-dp-phase2.sh.
# shellcheck shell=bash
set +x

if [[ -n "${ACPS_AUTH_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
ACPS_AUTH_LOADED=1

ACPS_CURL_AUTH_ARGS=()
ACPS_CURL_TLS_ARGS=()
ACPS_CURL_NETRC_FILE="${ACPS_CURL_NETRC_FILE:-}"
ACPS_INSECURE_TLS="${ACPS_INSECURE_TLS:-0}"

_acps_auth_die() {
  if declare -F mm_die >/dev/null 2>&1; then
    mm_die "$@"
  elif declare -F dp2_die >/dev/null 2>&1; then
    dp2_die "$@"
  else
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
  fi
}

_acps_auth_warn() {
  if declare -F mm_warn >/dev/null 2>&1; then
    mm_warn "$@"
  elif declare -F dp2_warn >/dev/null 2>&1; then
    dp2_warn "$@"
  else
    printf 'WARN: %s\n' "$*" >&2
  fi
}

_acps_auth_info() {
  if declare -F mm_info >/dev/null 2>&1; then
    mm_info "$@"
  elif declare -F dp2_info >/dev/null 2>&1; then
    dp2_info "$@"
  else
    printf 'INFO: %s\n' "$*" >&2
  fi
}

acps_auth_run_dir() {
  local d
  if [[ -n "${ACPS_AUTH_RUN_DIR:-}" ]]; then
    d="$ACPS_AUTH_RUN_DIR"
  elif [[ -d /run && -w /run ]]; then
    d="/run/ubuntu-mirror-acps.$$"
  else
    d="${TMPDIR:-/tmp}/ubuntu-mirror-acps.$$"
  fi
  mkdir -p "$d" || return 1
  chmod 0700 "$d" || return 1
  printf '%s\n' "$d"
}

acps_cleanup_curl_auth() {
  local f="${ACPS_CURL_NETRC_FILE:-}"
  local d
  ACPS_CURL_AUTH_ARGS=()
  if [[ -n "$f" ]]; then
    d="$(dirname "$f")"
    rm -f "$f" 2>/dev/null || true
    if [[ "$d" == /run/ubuntu-mirror-acps.* || "$d" == "${TMPDIR:-/tmp}/ubuntu-mirror-acps."* ]]; then
      rmdir "$d" 2>/dev/null || true
    elif [[ -n "${ACPS_AUTH_RUN_DIR:-}" && "$d" == "$ACPS_AUTH_RUN_DIR" ]]; then
      : # caller-owned run dir; leave directory
    fi
  fi
  ACPS_CURL_NETRC_FILE=""
}

acps_install_netrc_auth() {
  local run_dir machine host user pass
  acps_cleanup_curl_auth
  run_dir="$(acps_auth_run_dir)" || return 1
  ACPS_CURL_NETRC_FILE="${run_dir}/netrc"
  # Prefer ACPS_USERNAME/ACPS_PASSWORD; fall back to ACPS_USER/ACPS_PASS.
  user="${ACPS_USERNAME:-${ACPS_USER:-}}"
  pass="${ACPS_PASSWORD:-${ACPS_PASS:-}}"
  host="$(printf '%s' "${ACPS_EFFECTIVE_BASE}" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' | cut -d/ -f1 | cut -d@ -f2 | cut -d: -f1)"
  [[ -n "$host" ]] || return 1
  [[ -n "$user" && -n "$pass" ]] || return 1
  machine="$host"
  (
    umask 077
    {
      printf 'machine %s\n' "$machine"
      printf 'login %s\n' "$user"
      printf 'password %s\n' "$pass"
    } >"${ACPS_CURL_NETRC_FILE}"
  ) || return 1
  chmod 0600 "${ACPS_CURL_NETRC_FILE}" || return 1
  ACPS_CURL_AUTH_ARGS=(--netrc-file "${ACPS_CURL_NETRC_FILE}")
  return 0
}

# Configure TLS + netrc auth for ACPS downloads.
# Fixture/local HTTP (DP_PHASE2_SOURCE_BASE set): no auth, no -k.
acps_setup_curl_auth() {
  ACPS_CURL_AUTH_ARGS=()
  ACPS_CURL_TLS_ARGS=()
  ACPS_CURL_NETRC_FILE="${ACPS_CURL_NETRC_FILE:-}"
  if [[ -n "${DP_PHASE2_SOURCE_BASE:-}" ]]; then
    ACPS_EFFECTIVE_BASE="${DP_PHASE2_SOURCE_BASE}"
    return 0
  fi
  ACPS_EFFECTIVE_BASE="${ACPS_BASE_URL:-${ACPS_BASE_URL_FIXED:-}}"
  [[ -n "${ACPS_EFFECTIVE_BASE}" ]] || _acps_auth_die "ACPS_BASE_URL=FAIL missing"

  # Accept either naming convention (GUI: USERNAME/PASSWORD; standalone:
  # USER/PASS). Resolve into ACPS_USERNAME/ACPS_PASSWORD only — do not write
  # back into ACPS_USER/ACPS_PASS, or an earlier successful setup would leave
  # sibling vars that survive an explicit unset of USERNAME/PASSWORD.
  ACPS_USERNAME="${ACPS_USERNAME:-${ACPS_USER:-}}"
  ACPS_PASSWORD="${ACPS_PASSWORD:-${ACPS_PASS:-}}"

  [[ -n "${ACPS_USERNAME:-}" ]] || _acps_auth_die "ACPS_USERNAME=FAIL missing"
  [[ -n "${ACPS_PASSWORD:-}" ]] || _acps_auth_die "ACPS_PASSWORD=FAIL missing"

  # Prefer secure TLS verification. Explicit opt-in required for -k.
  if [[ "${ACPS_INSECURE_TLS:-0}" == "1" ]]; then
    ACPS_CURL_TLS_ARGS+=(-k)
    _acps_auth_warn "ACPS_TLS_VERIFY=DISABLED ACPS_INSECURE_TLS_WARNING=YES"
  else
    _acps_auth_info "ACPS_TLS_VERIFY=ENABLED"
  fi

  # Never put username:password on curl argv (visible via /proc). Use a
  # 0600 netrc under a private run directory and clean it up afterwards.
  acps_install_netrc_auth || _acps_auth_die "ACPS_AUTH_SETUP=FAIL"
}
