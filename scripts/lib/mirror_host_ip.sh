#!/usr/bin/env bash
# scripts/lib/mirror_host_ip.sh — Mirror Host IPv4 resolution.
#
# Authoritative source for production prepare/enable/client-pin:
#   OPERATOR_CONFIRMED_CONFIG (MIRROR_SERVER_IP / MIRROR_HTTP_URL in GUI config)
#
# Auto-detection from the primary interface is a Configuration suggestion and
# a legacy migration fallback only — never an unattended authoritative decision
# for Download and Prepare / Enable HTTP.
#
# shellcheck shell=bash

if [[ -n "${MIRROR_HOST_IP_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
MIRROR_HOST_IP_LIB_LOADED=1

# Persisted authoritative locations (overridable for tests).
MIRROR_HOST_MM_CONFIG_FILE="${MM_CONFIG_FILE:-/etc/ubuntu-mirror/dp-upgrade-mirror.conf}"
MIRROR_HOST_MIRROR_CONF="${MIRROR_HOST_MIRROR_CONF:-/etc/ubuntu-mirror/mirror.conf}"

RESOLVED_MIRROR_HOST_IPV4="${RESOLVED_MIRROR_HOST_IPV4:-}"
RESOLVED_MIRROR_BASE_URL="${RESOLVED_MIRROR_BASE_URL:-}"
MIRROR_IP_RESOLUTION_SOURCE="${MIRROR_IP_RESOLUTION_SOURCE:-}"
MIRROR_IP_SOURCE="${MIRROR_IP_SOURCE:-}"
MIRROR_PRIMARY_INTERFACE="${MIRROR_PRIMARY_INTERFACE:-}"
MIRROR_IPV4_CANDIDATE_COUNT="${MIRROR_IPV4_CANDIDATE_COUNT:-0}"
MIRROR_IP_RESOLUTION_ERROR=""
SUGGESTED_MIRROR_SERVER_IP="${SUGGESTED_MIRROR_SERVER_IP:-}"

mirror_host_log_err() {
  printf 'MIRROR_IP_RESOLUTION_ERROR=%s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------
mirror_host_is_valid_ipv4() {
  local ip="${1:-}" octet
  [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  local IFS='.'
  # shellcheck disable=SC2206
  local parts=($ip)
  for octet in "${parts[@]}"; do
    [[ "$octet" =~ ^0[0-9]+$ ]] && return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
  return 0
}

# Loopback, link-local, unspecified and broadcast are never client-reachable.
mirror_host_is_usable_ipv4() {
  local ip="${1:-}"
  mirror_host_is_valid_ipv4 "$ip" || return 1
  case "$ip" in
    127.*|169.254.*|0.0.0.0|255.255.255.255) return 1 ;;
  esac
  return 0
}

mirror_host_is_excluded_iface() {
  local iface="${1:-}"
  [[ -n "$iface" ]] || return 0
  case "$iface" in
    lo|lo:*) return 0 ;;
    docker*|br-*|veth*|virbr*|cni*|flannel*|kube*|tun*|tap*) return 0 ;;
  esac
  return 1
}

mirror_host_detect_primary_iface() {
  local line iface
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    iface="$(printf '%s\n' "$line" \
      | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    [[ -n "$iface" ]] || continue
    mirror_host_is_excluded_iface "$iface" && continue
    printf '%s\n' "$iface"
    return 0
  done < <(ip -4 route show default 2>/dev/null || true)
  return 1
}

mirror_host_list_global_ipv4_on_iface() {
  local iface="${1:-}" addr found=0
  [[ -n "$iface" ]] || return 1
  mirror_host_is_excluded_iface "$iface" && return 1
  while IFS= read -r addr; do
    [[ -n "$addr" ]] || continue
    mirror_host_is_usable_ipv4 "$addr" || continue
    printf '%s\n' "$addr"
    found=1
  done < <(ip -4 -o addr show dev "$iface" scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1)
  [[ "$found" -eq 1 ]]
}

# Every global IPv4 on every non-excluded interface (used for validation).
mirror_host_list_global_ipv4_all() {
  local iface addr found=0
  while read -r iface addr; do
    [[ -n "$iface" && -n "$addr" ]] || continue
    mirror_host_is_excluded_iface "$iface" && continue
    mirror_host_is_usable_ipv4 "$addr" || continue
    printf '%s\n' "$addr"
    found=1
  done < <(ip -4 -o addr show scope global 2>/dev/null \
    | awk '{split($4,a,"/"); print $2, a[1]}')
  [[ "$found" -eq 1 ]]
}

mirror_host_validate_ipv4_on_host() {
  local want="${1:-}" have
  mirror_host_is_usable_ipv4 "$want" || return 1
  # Dual-hermetic: MM_HERMETIC_TEST_MODE=1 AND SKIP_MIRROR_HOST_VALIDATE=1.
  if [[ "${MM_HERMETIC_TEST_MODE:-0}" == "1" && "${SKIP_MIRROR_HOST_VALIDATE:-0}" == "1" ]]; then
    return 0
  fi
  while IFS= read -r have; do
    [[ "$have" == "$want" ]] && return 0
  done < <(mirror_host_list_global_ipv4_all || true)
  return 1
}

# http(s)://host[:port][/path] → host (only when host is an IPv4 literal).
mirror_host_extract_ipv4_from_url() {
  local url="${1:-}" host
  [[ -n "$url" ]] || return 1
  host="${url#*://}"
  [[ "$host" == "$url" && "$url" != *://* ]] && host="$url"
  host="${host%%/*}"
  host="${host##*@}"
  host="${host%%\?*}"
  host="${host%%:*}"
  mirror_host_is_valid_ipv4 "$host" || return 1
  printf '%s\n' "$host"
}

mirror_base_url_from_ipv4() {
  local ip="${1:-}"
  mirror_host_is_valid_ipv4 "$ip" || return 1
  printf 'http://%s\n' "$ip"
}

# ---------------------------------------------------------------------------
# Persisted authoritative values
# ---------------------------------------------------------------------------
mirror_host_read_conf_field() {
  local file="${1:-}" field="${2:-}" line value
  [[ -n "$file" && -f "$file" && -r "$file" && -n "$field" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ "$line" == "${field}="* ]] || continue
    value="${line#"${field}="}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    [[ -n "$value" ]] || return 1
    printf '%s\n' "$value"
    return 0
  done <"$file"
  return 1
}

mirror_host_is_placeholder_value() {
  local value="${1:-}"
  case "$value" in
    ""|"_"|auto|AUTO|0.0.0.0|localhost|http://localhost|http://ubuntu-mirror.local|ubuntu-mirror.local)
      return 0 ;;
  esac
  return 1
}

# Suggestion only — never authoritative for prepare/enable.
# Sets SUGGESTED_MIRROR_SERVER_IP when exactly one primary-iface candidate exists.
mirror_host_suggest_primary_ipv4() {
  local iface candidates=() cand
  SUGGESTED_MIRROR_SERVER_IP=""
  iface="$(mirror_host_detect_primary_iface || true)"
  MIRROR_PRIMARY_INTERFACE="$iface"
  if [[ -n "$iface" ]]; then
    while IFS= read -r cand; do
      [[ -n "$cand" ]] && candidates+=("$cand")
    done < <(mirror_host_list_global_ipv4_on_iface "$iface" || true)
  fi
  MIRROR_IPV4_CANDIDATE_COUNT="${#candidates[@]}"
  if [[ "${#candidates[@]}" -eq 1 ]]; then
    SUGGESTED_MIRROR_SERVER_IP="${candidates[0]}"
    printf '%s\n' "$SUGGESTED_MIRROR_SERVER_IP"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Resolver
# ---------------------------------------------------------------------------
_mirror_host_reset_state() {
  RESOLVED_MIRROR_HOST_IPV4=""
  RESOLVED_MIRROR_BASE_URL=""
  MIRROR_IP_RESOLUTION_SOURCE=""
  MIRROR_IP_SOURCE=""
  MIRROR_PRIMARY_INTERFACE=""
  MIRROR_IPV4_CANDIDATE_COUNT=0
  MIRROR_IP_RESOLUTION_ERROR=""
}

_mirror_host_accept() {
  local ip="$1" source="$2"
  RESOLVED_MIRROR_HOST_IPV4="$ip"
  RESOLVED_MIRROR_BASE_URL="$(mirror_base_url_from_ipv4 "$ip")"
  MIRROR_IP_RESOLUTION_SOURCE="$source"
  MIRROR_IP_SOURCE="$source"
  return 0
}

_mirror_host_fail() {
  MIRROR_IP_RESOLUTION_ERROR="$*"
  RESOLVED_MIRROR_HOST_IPV4=""
  RESOLVED_MIRROR_BASE_URL=""
  MIRROR_IP_SOURCE=""
  mirror_host_log_err "$MIRROR_IP_RESOLUTION_ERROR"
  return 1
}

# Accept an operator-confirmed IPv4 after interface validation.
_mirror_host_accept_operator_ip() {
  local ip="$1"
  if ! mirror_host_is_usable_ipv4 "$ip"; then
    _mirror_host_fail "configured Mirror Server IP '${ip}' is not a usable IPv4 address"
    return 1
  fi
  if ! mirror_host_validate_ipv4_on_host "$ip"; then
    _mirror_host_fail \
      "configured Mirror Server IP ${ip} is not present on any active non-excluded interface"
    return 1
  fi
  _mirror_host_accept "$ip" "OPERATOR_CONFIRMED_CONFIG"
  return 0
}

# Sets globals; prints nothing. Returns 0 on success.
_mirror_host_resolve_core() {
  local env_ip="${RESOLVED_MIRROR_HOST_IPV4:-}"
  local iface candidates=() cand persisted host conf server_ip

  # Preserve caller ENV override across reset.
  local saved_env="$env_ip"
  _mirror_host_reset_state

  # Interface facts are informational for ENV/persisted sources and
  # used for suggestion / legacy auto-detect fallback.
  iface="$(mirror_host_detect_primary_iface || true)"
  MIRROR_PRIMARY_INTERFACE="$iface"
  if [[ -n "$iface" ]]; then
    while IFS= read -r cand; do
      [[ -n "$cand" ]] && candidates+=("$cand")
    done < <(mirror_host_list_global_ipv4_on_iface "$iface" || true)
  fi
  MIRROR_IPV4_CANDIDATE_COUNT="${#candidates[@]}"
  if [[ "${#candidates[@]}" -eq 1 ]]; then
    SUGGESTED_MIRROR_SERVER_IP="${candidates[0]}"
  else
    SUGGESTED_MIRROR_SERVER_IP=""
  fi

  # 1. Explicit operator/environment override (tests / advanced ops).
  if [[ -n "$saved_env" ]]; then
    if ! mirror_host_is_usable_ipv4 "$saved_env"; then
      _mirror_host_fail "RESOLVED_MIRROR_HOST_IPV4='${saved_env}' is not a usable IPv4 address"
      return 1
    fi
    if ! mirror_host_validate_ipv4_on_host "$saved_env"; then
      _mirror_host_fail \
        "RESOLVED_MIRROR_HOST_IPV4=${saved_env} is not configured on any active interface"
      return 1
    fi
    _mirror_host_accept "$saved_env" "ENV"
    return 0
  fi

  conf="${MM_CONFIG_FILE:-$MIRROR_HOST_MM_CONFIG_FILE}"

  # 2. Operator-confirmed MIRROR_SERVER_IP (authoritative GUI field).
  server_ip="$(mirror_host_read_conf_field "$conf" MIRROR_SERVER_IP || true)"
  if [[ -n "$server_ip" ]] && ! mirror_host_is_placeholder_value "$server_ip"; then
    _mirror_host_accept_operator_ip "$server_ip" || return 1
    return 0
  fi

  # 3. Operator-confirmed MIRROR_HTTP_URL (same authoritative config file).
  persisted="$(mirror_host_read_conf_field "$conf" MIRROR_HTTP_URL || true)"
  if [[ -n "$persisted" ]] && ! mirror_host_is_placeholder_value "$persisted"; then
    host="$(mirror_host_extract_ipv4_from_url "$persisted" || true)"
    if [[ -n "$host" ]]; then
      _mirror_host_accept_operator_ip "$host" || return 1
      return 0
    fi
  fi

  # 4. Legacy migration fallback — mirror.conf.
  conf="$MIRROR_HOST_MIRROR_CONF"
  persisted="$(mirror_host_read_conf_field "$conf" MIRROR_IP || true)"
  if [[ -n "$persisted" ]] && mirror_host_is_placeholder_value "$persisted"; then
    persisted=""
  fi
  if [[ -z "$persisted" ]]; then
    host="$(mirror_host_read_conf_field "$conf" MIRROR_URL || true)"
    if [[ -n "$host" ]] && ! mirror_host_is_placeholder_value "$host"; then
      persisted="$(mirror_host_extract_ipv4_from_url "$host" || true)"
    fi
  fi
  if [[ -n "$persisted" ]] && mirror_host_is_valid_ipv4 "$persisted"; then
    if mirror_host_validate_ipv4_on_host "$persisted"; then
      _mirror_host_accept "$persisted" "PERSISTED_MIRROR_CONF"
      return 0
    fi
    _mirror_host_fail \
      "persisted mirror.conf address ${persisted} (${conf}) is not configured on any active interface"
    return 1
  fi

  # 5. Legacy auto-detect fallback (suggestion path). Production prepare/enable
  # require operator-confirmed config via mm_require_configured_mirror_server_ip;
  # this path remains for legacy callers and unambiguous single-IP hosts.
  if [[ -z "$iface" ]]; then
    _mirror_host_fail "no default IPv4 route; cannot determine the mirror host interface"
    return 1
  fi
  if [[ "${#candidates[@]}" -eq 0 ]]; then
    _mirror_host_fail \
      "no global IPv4 address on primary interface ${iface}"
    return 1
  fi
  if [[ "${#candidates[@]}" -gt 1 ]]; then
    _mirror_host_fail \
      "ambiguous mirror host IPv4 on ${iface}: ${candidates[*]} — set Mirror Server IP in Configuration (${MM_CONFIG_FILE:-$MIRROR_HOST_MM_CONFIG_FILE})"
    return 1
  fi
  _mirror_host_accept "${candidates[0]}" "PRIMARY_IFACE_AUTO"
  return 0
}

# Prints the resolved IPv4 on stdout.
mirror_host_resolve_ipv4() {
  _mirror_host_resolve_core || return 1
  printf '%s\n' "$RESOLVED_MIRROR_HOST_IPV4"
}

# Prints the machine-readable resolution record on stdout.
mirror_host_resolve_and_log() {
  local rc=0
  _mirror_host_resolve_core || rc=1
  printf 'MIRROR_IP_RESOLUTION_SOURCE=%s\n' "${MIRROR_IP_RESOLUTION_SOURCE:-NONE}"
  printf 'MIRROR_IP_SOURCE=%s\n' "${MIRROR_IP_SOURCE:-${MIRROR_IP_RESOLUTION_SOURCE:-NONE}}"
  printf 'MIRROR_PRIMARY_INTERFACE=%s\n' "${MIRROR_PRIMARY_INTERFACE:-}"
  printf 'MIRROR_IPV4_CANDIDATE_COUNT=%s\n' "${MIRROR_IPV4_CANDIDATE_COUNT:-0}"
  printf 'SUGGESTED_MIRROR_SERVER_IP=%s\n' "${SUGGESTED_MIRROR_SERVER_IP:-}"
  printf 'RESOLVED_MIRROR_HOST_IPV4=%s\n' "${RESOLVED_MIRROR_HOST_IPV4:-}"
  printf 'RESOLVED_MIRROR_BASE_URL=%s\n' "${RESOLVED_MIRROR_BASE_URL:-}"
  if [[ "$rc" -eq 0 ]]; then
    printf 'MIRROR_IP_RESOLUTION_RESULT=PASS\n'
    if [[ "${MIRROR_IP_SOURCE}" == "OPERATOR_CONFIRMED_CONFIG" ]]; then
      printf 'CONFIGURED_MIRROR_SERVER_IP=%s\n' "${RESOLVED_MIRROR_HOST_IPV4}"
      printf 'CONFIGURED_MIRROR_BASE_URL=%s\n' "${RESOLVED_MIRROR_BASE_URL}"
      printf 'MIRROR_IP_INTERFACE_VALIDATION=PASS\n'
    fi
  else
    printf 'MIRROR_IP_RESOLUTION_RESULT=FAIL\n'
  fi
  return "$rc"
}

# Convenience for callers that only need the base URL and want the record in logs.
mirror_host_require_base_url() {
  mirror_host_resolve_and_log || return 1
  [[ -n "$RESOLVED_MIRROR_BASE_URL" ]] || return 1
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-resolve-and-log}" in
    ipv4) mirror_host_resolve_ipv4 ;;
    base-url) mirror_host_resolve_ipv4 >/dev/null && printf '%s\n' "$RESOLVED_MIRROR_BASE_URL" ;;
    suggest) mirror_host_suggest_primary_ipv4 ;;
    resolve-and-log) mirror_host_resolve_and_log ;;
    *) printf 'usage: %s [ipv4|base-url|suggest|resolve-and-log]\n' "${0##*/}" >&2; exit 2 ;;
  esac
fi
