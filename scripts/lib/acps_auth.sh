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

# Historical ACPS endpoint — retained for hermetic fixtures and for rejecting
# production env attempts to restore ACPS as the download source.
# Production Phase 2 runtime downloads from PHASE2_R2_BASE_URL_CONSTANT only.
ACPS_PRODUCTION_BASE_URL="https://acps.stellarcyber.ai/provision/aelladeb_py3"

# Immutable production Phase 2 download source (Cloudflare R2 public HTTPS).
# Re-asserted unconditionally so env cannot redirect production downloads.
# Must match scripts/lib/dp-phase2-common.sh.
PHASE2_R2_PUBLIC_BASE_URL_CONSTANT="https://downloads.xdr.ooo"
PHASE2_R2_VALIDATED_RELEASE_ID="validated-20260919"
PHASE2_R2_OBJECT_PREFIX_CONSTANT="dp-os-upgrade/phase2/6.6.0/validated-20260919"
PHASE2_R2_BASE_URL_CONSTANT="https://downloads.xdr.ooo/dp-os-upgrade/phase2/6.6.0/validated-20260919"
# Keep in lockstep with scripts/lib/dp-phase2-common.sh (single production pin).
PHASE2_R2_MANIFEST_SHA256="606e2967652ad4d0f0bfad4a23b562217a062ea17ccb54c47d2a5ea8bdf7c898"
PHASE2_R2_MANIFEST_BYTES=956

# Explicit hermetic-test boundary. Never document in GUI/help.
# Production must not honor ACPS_INSECURE_TLS, DP_PHASE2_SOURCE_BASE,
# ACPS_* URL overrides, or ACPS_AUTH_RUN_DIR.
_acps_hermetic_test_mode() {
  [[ "${MM_HERMETIC_TEST_MODE:-0}" == "1" ]]
}

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

# Reject production env attempts to redirect the fixed ACPS destination.
_acps_reject_production_url_override() {
  local canon="$ACPS_PRODUCTION_BASE_URL"
  if [[ -n "${ACPS_BASE_URL:-}" && "${ACPS_BASE_URL}" != "$canon" ]]; then
    _acps_auth_die "ACPS_BASE_URL=FAIL reason=production_forbidden"
  fi
  if [[ -n "${ACPS_BASE_URL_FIXED:-}" && "${ACPS_BASE_URL_FIXED}" != "$canon" ]]; then
    _acps_auth_die "ACPS_BASE_URL_FIXED=FAIL reason=production_forbidden"
  fi
  if [[ -n "${ACPS_HOST:-}" && "${ACPS_HOST}" != "acps.stellarcyber.ai" ]]; then
    _acps_auth_die "ACPS_HOST=FAIL reason=production_forbidden"
  fi
  if [[ -n "${ACPS_PATH:-}" && "${ACPS_PATH}" != "/provision/aelladeb_py3" ]]; then
    _acps_auth_die "ACPS_PATH=FAIL reason=production_forbidden"
  fi
}

acps_auth_run_dir() {
  local d=""
  # Caller-selected run dirs are hermetic-only; production never chmod/mkdir
  # an arbitrary externally provided path for credential material.
  if [[ -n "${ACPS_AUTH_RUN_DIR:-}" ]]; then
    if ! _acps_hermetic_test_mode; then
      _acps_auth_die "ACPS_AUTH_RUN_DIR=FAIL reason=production_forbidden"
    fi
    d="$ACPS_AUTH_RUN_DIR"
    mkdir -p "$d" || return 1
    chmod 0700 "$d" || return 1
    printf '%s\n' "$d"
    return 0
  fi
  if [[ -d /run && -w /run ]]; then
    d="$(mktemp -d /run/ubuntu-mirror-acps.XXXXXX 2>/dev/null || true)"
  fi
  if [[ -z "$d" ]]; then
    d="$(mktemp -d "${TMPDIR:-/tmp}/ubuntu-mirror-acps.XXXXXX")" || return 1
  fi
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
    case "$d" in
      /run/ubuntu-mirror-acps.*|"${TMPDIR:-/tmp}"/ubuntu-mirror-acps.*)
        rmdir "$d" 2>/dev/null || true
        ;;
      *)
        if [[ -n "${ACPS_AUTH_RUN_DIR:-}" && "$d" == "$ACPS_AUTH_RUN_DIR" ]] \
          && _acps_hermetic_test_mode; then
          : # hermetic caller-owned run dir; leave directory
        else
          rmdir "$d" 2>/dev/null || true
        fi
        ;;
    esac
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
  # .netrc token grammar: whitespace/newlines break curl token parsing.
  # Other special characters are preserved literally (curl reads the password
  # token as-is). Reject only characters that split tokens.
  if [[ "$host" =~ [[:space:]] || "$user" =~ [[:space:]] || "$pass" =~ [[:space:]] ]]; then
    _acps_auth_die "ACPS_NETRC=FAIL reason=whitespace_in_credentials_unsupported"
  fi
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
    if ! _acps_hermetic_test_mode; then
      _acps_auth_die "DP_PHASE2_SOURCE_BASE=FAIL reason=production_forbidden"
    fi
    ACPS_EFFECTIVE_BASE="${DP_PHASE2_SOURCE_BASE}"
    return 0
  fi

  if _acps_hermetic_test_mode; then
    # Hermetic fixtures may redirect via ACPS_BASE_URL / FIXED / HOST+PATH.
    if [[ -n "${ACPS_BASE_URL:-}" ]]; then
      ACPS_EFFECTIVE_BASE="${ACPS_BASE_URL}"
    elif [[ -n "${ACPS_BASE_URL_FIXED:-}" ]]; then
      ACPS_EFFECTIVE_BASE="${ACPS_BASE_URL_FIXED}"
    elif [[ -n "${ACPS_HOST:-}" || -n "${ACPS_PATH:-}" ]]; then
      ACPS_EFFECTIVE_BASE="https://${ACPS_HOST:-acps.stellarcyber.ai}${ACPS_PATH:-/provision/aelladeb_py3}"
    else
      ACPS_EFFECTIVE_BASE="${PHASE2_R2_BASE_URL_CONSTANT}"
    fi
    # Public R2 needs no credentials even in hermetic mode.
    if [[ "${ACPS_EFFECTIVE_BASE}" == "${PHASE2_R2_BASE_URL_CONSTANT}" ]]; then
      if [[ "${ACPS_INSECURE_TLS:-0}" == "1" ]]; then
        ACPS_CURL_TLS_ARGS+=(-k)
        _acps_auth_warn "ACPS_TLS_VERIFY=DISABLED ACPS_INSECURE_TLS_WARNING=YES"
      else
        _acps_auth_info "PHASE2_TLS_VERIFY=ENABLED"
      fi
      ACPS_CURL_AUTH_ARGS=()
      _acps_auth_info "PHASE2_SOURCE=R2 base=${ACPS_EFFECTIVE_BASE}"
      return 0
    fi
  else
    _acps_reject_production_url_override
    if [[ -n "${ACPS_AUTH_RUN_DIR:-}" ]]; then
      _acps_auth_die "ACPS_AUTH_RUN_DIR=FAIL reason=production_forbidden"
    fi
    # Production runtime: immutable R2 prefix only. No ACPS, no credentials,
    # no R2→ACPS fallback.
    ACPS_EFFECTIVE_BASE="${PHASE2_R2_BASE_URL_CONSTANT}"
    PHASE2_EFFECTIVE_BASE="${ACPS_EFFECTIVE_BASE}"
    if [[ "${ACPS_INSECURE_TLS:-0}" == "1" ]]; then
      _acps_auth_die "ACPS_INSECURE_TLS=FAIL reason=production_forbidden"
    fi
    _acps_auth_info "PHASE2_TLS_VERIFY=ENABLED"
    _acps_auth_info "PHASE2_SOURCE=R2 base=${ACPS_EFFECTIVE_BASE}"
    ACPS_CURL_AUTH_ARGS=()
    return 0
  fi
  [[ -n "${ACPS_EFFECTIVE_BASE}" ]] || _acps_auth_die "ACPS_BASE_URL=FAIL missing"

  # Hermetic only below: fixture HTTP may still use netrc against a fake ACPS.
  # Accept either naming convention (GUI: USERNAME/PASSWORD; standalone:
  # USER/PASS). Resolve into ACPS_USERNAME/ACPS_PASSWORD only — do not write
  # back into ACPS_USER/ACPS_PASS, or an earlier successful setup would leave
  # sibling vars that survive an explicit unset of USERNAME/PASSWORD.
  ACPS_USERNAME="${ACPS_USERNAME:-${ACPS_USER:-}}"
  ACPS_PASSWORD="${ACPS_PASSWORD:-${ACPS_PASS:-}}"

  [[ -n "${ACPS_USERNAME:-}" ]] || _acps_auth_die "ACPS_USERNAME=FAIL missing"
  [[ -n "${ACPS_PASSWORD:-}" ]] || _acps_auth_die "ACPS_PASSWORD=FAIL missing"

  # Prefer secure TLS verification. Explicit hermetic test mode required for -k.
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
