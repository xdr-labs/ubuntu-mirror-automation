#!/usr/bin/env bash
# Phase 2 time/NTP readiness helpers (staging guidance + bringup hard gate).
# shellcheck shell=bash
# Staging may complete with BRINGUP_READY=NO. Vendor bringup must re-check and hard-block.

if ! declare -F log >/dev/null 2>&1; then
  log() { printf '%s\n' "$*"; }
fi

# --- Time readiness / NTP source classification (Phase 2 staging guidance) ---
# Read-only. Does not configure NTP. Staging always places artifacts; bringup is never executed here.
# INTERNAL NTP absence alone never sets BRINGUP_READY=NO.

dp_phase2_max_clock_skew_seconds() {
  local raw="${DP_MAX_CLOCK_SKEW_SECONDS:-300}"
  if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$raw"
    return 0
  fi
  # Invalid values are rejected by check_ntp_bringup_readiness; keep a safe display default here.
  printf '300'
}

dp_phase2_ipv4_is_loopback_or_linklocal() {
  local ip="$1" a b
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b _ _ <<<"$ip"
  [[ "$a" == "127" ]] && return 0
  [[ "$a" == "169" && "$b" == "254" ]] && return 0
  return 1
}

dp_phase2_ipv4_is_internal_ntp() {
  # RFC1918 only. Loopback/link-local are not valid NTP sources.
  local ip="$1" a b
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  dp_phase2_ipv4_is_loopback_or_linklocal "$ip" && return 1
  IFS=. read -r a b _ _ <<<"$ip"
  [[ "$a" == "10" ]] && return 0
  [[ "$a" == "172" && "$b" -ge 16 && "$b" -le 31 ]] && return 0
  [[ "$a" == "192" && "$b" == "168" ]] && return 0
  return 1
}

dp_phase2_collect_ntp_sources() {
  # Prints candidate server/pool tokens (IP or hostname), one per line.
  local out conf line tok
  out=""
  if [[ -n "${DP_PHASE2_FAKE_NTPQ_PN:-}" ]]; then
    out="${DP_PHASE2_FAKE_NTPQ_PN}"
  elif command -v ntpq >/dev/null 2>&1; then
    out="$(ntpq -pn 2>/dev/null || ntpq -p 2>/dev/null || true)"
  fi
  if [[ -n "$out" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ [[:space:]]*remote[[:space:]]+refid ]] && continue
      [[ "$line" =~ ^=+$ ]] && continue
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      tok="$(printf '%s\n' "${line#"${line%%[![:space:]]*}"}" | awk '{print $1}')"
      tok="${tok#[*+#\-x\. ]}"
      [[ -n "$tok" && "$tok" != "remote" ]] || continue
      printf '%s\n' "$tok"
    done <<<"$out"
  fi
  conf="${DP_PHASE2_FAKE_NTP_CONF:-/etc/ntpsec/ntp.conf}"
  if [[ -r "$conf" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      if [[ "$line" =~ ^[[:space:]]*(server|pool)[[:space:]]+([^[:space:]]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"
      fi
    done <"$conf"
  fi
}

classify_ntp_source_class() {
  # Sets NTP_SOURCE_CLASS=INTERNAL|PUBLIC|UNKNOWN and INTERNAL_NTP_REQUIREMENT informational only.
  local tok has_internal=0 has_public=0 has_any=0
  NTP_SOURCE_CLASS="UNKNOWN"
  INTERNAL_NTP_REQUIREMENT="NOT_EVALUATED"
  while IFS= read -r tok || [[ -n "$tok" ]]; do
    [[ -n "$tok" ]] || continue
    has_any=1
    if [[ "$tok" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      if dp_phase2_ipv4_is_loopback_or_linklocal "$tok"; then
        continue
      fi
      if dp_phase2_ipv4_is_internal_ntp "$tok"; then
        has_internal=1
      else
        has_public=1
      fi
    else
      # Hostname → treat as public NTP source candidate (not RFC1918 IP).
      has_public=1
    fi
  done < <(dp_phase2_collect_ntp_sources | awk 'NF && !seen[$0]++')

  if [[ "$has_internal" -eq 1 ]]; then
    NTP_SOURCE_CLASS="INTERNAL"
    INTERNAL_NTP_REQUIREMENT="SATISFIED"
  elif [[ "$has_public" -eq 1 ]]; then
    NTP_SOURCE_CLASS="PUBLIC"
    INTERNAL_NTP_REQUIREMENT="NOT_SATISFIED"
  elif [[ "$has_any" -eq 0 ]]; then
    NTP_SOURCE_CLASS="UNKNOWN"
    INTERNAL_NTP_REQUIREMENT="NOT_SATISFIED"
  else
    NTP_SOURCE_CLASS="UNKNOWN"
    INTERNAL_NTP_REQUIREMENT="NOT_SATISFIED"
  fi
}

dp_phase2_ntpq_selected_peer() {
  local out line trimmed tally peer
  NTP_SELECTED_PEER=""
  if [[ -n "${DP_PHASE2_FAKE_NTPQ_PN:-}" ]]; then
    out="${DP_PHASE2_FAKE_NTPQ_PN}"
  elif command -v ntpq >/dev/null 2>&1; then
    out="$(ntpq -pn 2>/dev/null || ntpq -p 2>/dev/null || true)"
  else
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ [[:space:]]*remote[[:space:]]+refid ]] && continue
    [[ "$line" =~ ^=+$ ]] && continue
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$trimmed" ]] || continue
    tally="${trimmed:0:1}"
    [[ "$tally" == "*" ]] || continue
    peer="$(printf '%s\n' "$trimmed" | awk '{print $1}')"
    peer="${peer:1}"
    [[ -n "$peer" ]] || continue
    NTP_SELECTED_PEER="$peer"
    return 0
  done <<<"$out"
  return 1
}

dp_phase2_ntpq_leap_ok() {
  local rv
  if [[ -n "${DP_PHASE2_FAKE_NTPQ_RV:-}" ]]; then
    rv="${DP_PHASE2_FAKE_NTPQ_RV}"
  elif command -v ntpq >/dev/null 2>&1; then
    rv="$(ntpq -c rv 2>/dev/null || true)"
  else
    return 1
  fi
  printf '%s\n' "$rv" | grep -qE '(^|[[:space:],])leap=00([[:space:],]|$)'
}

dp_phase2_timedatectl_synchronized() {
  local td
  if [[ -n "${DP_PHASE2_FAKE_TIMEDATECTL:-}" ]]; then
    td="${DP_PHASE2_FAKE_TIMEDATECTL}"
  elif command -v timedatectl >/dev/null 2>&1; then
    td="$(timedatectl status 2>/dev/null || true)"
  else
    return 1
  fi
  # ntpsec often reports "NTP service: n/a" — that alone is not a failure.
  printf '%s\n' "$td" | grep -qiE 'System clock synchronized:[[:space:]]*yes'
}

dp_phase2_ntpwait_ok() {
  if [[ -n "${DP_PHASE2_FAKE_NTPWAIT_RC:-}" ]]; then
    [[ "${DP_PHASE2_FAKE_NTPWAIT_RC}" == "0" ]]
    return $?
  fi
  command -v ntpwait >/dev/null 2>&1 || return 1
  ntpwait >/dev/null 2>&1
}

dp_phase2_clock_skew_from_ntpq_seconds() {
  # Prints integer seconds (abs) from reachable peer offsets (ntpq offset is ms).
  local out line trimmed reach offset abs_ms best_ms=""
  if [[ -n "${DP_PHASE2_FAKE_NTPQ_PN:-}" ]]; then
    out="${DP_PHASE2_FAKE_NTPQ_PN}"
  elif command -v ntpq >/dev/null 2>&1; then
    out="$(ntpq -pn 2>/dev/null || ntpq -p 2>/dev/null || true)"
  else
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ [[:space:]]*remote[[:space:]]+refid ]] && continue
    [[ "$line" =~ ^=+$ ]] && continue
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$trimmed" ]] || continue
    reach="$(printf '%s\n' "$trimmed" | awk '{print $7}')"
    offset="$(printf '%s\n' "$trimmed" | awk '{print $9}')"
    [[ "$reach" =~ ^[0-9]+$ && "$reach" != "0" ]] || continue
    [[ "$offset" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]] || continue
    abs_ms="$(awk -v o="$offset" 'BEGIN { x=o+0; if (x<0) x=-x; printf "%d", x+0.5 }')"
    if [[ -z "$best_ms" ]] || [[ "$abs_ms" -lt "$best_ms" ]]; then
      best_ms="$abs_ms"
    fi
  done <<<"$out"
  [[ -n "$best_ms" ]] || return 1
  # ms → seconds (round)
  awk -v ms="$best_ms" 'BEGIN { printf "%d", (ms/1000)+0.5 }'
}

dp_phase2_clock_skew_from_http_date_seconds() {
  # Compare local UTC epoch to HTTP Date from internal mirror.
  local url headers date_hdr remote_epoch local_epoch skew
  url="${DP_PHASE2_TIME_REF_URL:-${MIRROR_URL}}"
  url="${url%/}"
  if [[ -n "${DP_PHASE2_FAKE_HTTP_DATE_EPOCH:-}" ]]; then
    remote_epoch="${DP_PHASE2_FAKE_HTTP_DATE_EPOCH}"
    [[ "$remote_epoch" =~ ^[0-9]+$ ]] || return 1
  else
    headers="$(curl -fsSI --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || true)"
    [[ -n "$headers" ]] || return 1
    date_hdr="$(printf '%s\n' "$headers" | awk -F': ' 'BEGIN{IGNORECASE=1} /^Date:/ {sub(/\r$/,"",$2); print $2; exit}')"
    [[ -n "$date_hdr" ]] || return 1
    remote_epoch="$(date -u -d "$date_hdr" +%s 2>/dev/null || true)"
    [[ "$remote_epoch" =~ ^[0-9]+$ ]] || return 1
  fi
  if [[ -n "${DP_PHASE2_FAKE_LOCAL_EPOCH:-}" ]]; then
    local_epoch="${DP_PHASE2_FAKE_LOCAL_EPOCH}"
  else
    local_epoch="$(date -u +%s)"
  fi
  [[ "$local_epoch" =~ ^[0-9]+$ ]] || return 1
  skew=$(( local_epoch - remote_epoch ))
  [[ "$skew" -lt 0 ]] && skew=$(( -skew ))
  printf '%s' "$skew"
}

check_ntp_bringup_readiness() {
  # Time readiness is the bringup gate. NTP_SOURCE_CLASS is informational only.
  local skew="" synced=0
  TIME_READINESS="FAIL_TIME_UNVERIFIABLE"
  BRINGUP_READY="NO"
  CLOCK_SKEW_SECONDS=""
  MAX_CLOCK_SKEW_SECONDS="$(dp_phase2_max_clock_skew_seconds)"
  NTP_SELECTED_PEER=""
  classify_ntp_source_class
  log "NTP_SOURCE_CLASS=${NTP_SOURCE_CLASS}"
  log "INTERNAL_NTP_REQUIREMENT=${INTERNAL_NTP_REQUIREMENT}"

  _dp_phase2_warn_if_no_internal_ntp() {
    if [[ "$NTP_SOURCE_CLASS" != "INTERNAL" ]]; then
      log "WARNING: no internal NTP source detected; continuing because local clock readiness passed"
    fi
  }

  if dp_phase2_ntpwait_ok; then
    synced=1
    dp_phase2_ntpq_selected_peer || true
    TIME_READINESS="PASS_SYNCED"
    BRINGUP_READY="YES"
    NTP_BRINGUP_READINESS="PASS"
    log "TIME_READINESS=PASS_SYNCED (ntpwait)"
    _dp_phase2_warn_if_no_internal_ntp
    log "BRINGUP_READY=YES"
    return 0
  fi

  if dp_phase2_ntpq_selected_peer && dp_phase2_ntpq_leap_ok; then
    synced=1
  elif dp_phase2_timedatectl_synchronized; then
    synced=1
    dp_phase2_ntpq_selected_peer || true
  fi

  if [[ "$synced" -eq 1 ]]; then
    TIME_READINESS="PASS_SYNCED"
    BRINGUP_READY="YES"
    NTP_BRINGUP_READINESS="PASS"
    log "TIME_READINESS=PASS_SYNCED"
    log "NTP_SELECTED_PEER=${NTP_SELECTED_PEER:-}"
    _dp_phase2_warn_if_no_internal_ntp
    log "BRINGUP_READY=YES"
    return 0
  fi

  # Unsynchronized: evaluate clock skew against ntpq offsets, then HTTP Date.
  skew="$(dp_phase2_clock_skew_from_ntpq_seconds 2>/dev/null || true)"
  if [[ -z "$skew" ]]; then
    skew="$(dp_phase2_clock_skew_from_http_date_seconds 2>/dev/null || true)"
  fi

  if [[ -n "$skew" && "$skew" =~ ^[0-9]+$ ]]; then
    CLOCK_SKEW_SECONDS="$skew"
    log "CLOCK_SKEW_SECONDS=${CLOCK_SKEW_SECONDS}"
    log "MAX_CLOCK_SKEW_SECONDS=${MAX_CLOCK_SKEW_SECONDS}"
    if [[ "$skew" -le "$MAX_CLOCK_SKEW_SECONDS" ]]; then
      TIME_READINESS="PASS_WITH_WARNING"
      BRINGUP_READY="YES"
      NTP_BRINGUP_READINESS="PASS"
      log "TIME_READINESS=PASS_WITH_WARNING"
      log "WARNING: NTP sync unconfirmed; clock skew within tolerance — bringup guidance allowed"
      _dp_phase2_warn_if_no_internal_ntp
      log "BRINGUP_READY=YES"
      return 0
    fi
    TIME_READINESS="FAIL_CLOCK_SKEW"
    BRINGUP_READY="NO"
    NTP_BRINGUP_READINESS="FAIL"
    log "TIME_READINESS=FAIL_CLOCK_SKEW"
    log "BRINGUP_READY=NO"
    return 0
  fi

  TIME_READINESS="FAIL_TIME_UNVERIFIABLE"
  BRINGUP_READY="NO"
  NTP_BRINGUP_READINESS="FAIL"
  log "TIME_READINESS=FAIL_TIME_UNVERIFIABLE"
  log "BRINGUP_READY=NO"
  return 0
}


# Hard gate for vendor bringup start. Returns 0 only when bringup is allowed.
# Sets ARTIFACT_STAGING_RESULT-compatible TIME_* globals via check_ntp_bringup_readiness.
dp_phase2_bringup_time_gate() {
  check_ntp_bringup_readiness || true
  case "${TIME_READINESS:-}" in
    PASS_SYNCED|PASS_WITH_WARNING)
      if [[ "${BRINGUP_READY:-}" == "YES" ]]; then
        printf '%s\n' "BRINGUP_TIME_GATE=PASS TIME_READINESS=${TIME_READINESS}"
        return 0
      fi
      ;;
  esac
  printf '%s\n' "BRINGUP_TIME_GATE=FAIL TIME_READINESS=${TIME_READINESS:-UNKNOWN} BRINGUP_READY=${BRINGUP_READY:-NO}"
  return 1
}

