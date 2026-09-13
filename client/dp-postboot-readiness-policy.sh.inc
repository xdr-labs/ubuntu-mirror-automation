#!/usr/bin/env bash
# Shared postboot DNS resolver repair and local-clock readiness policy.
# This file is inlined by build_client_jammy_to_noble.py into the generated
# postboot helper. It is also directly sourceable by fixture tests.
# shellcheck shell=bash

DNS_RESOLVER_STATE="NOT_CHECKED"
DNS_RESOLVER_REPAIR="NOT_ATTEMPTED"
DNS_SERVERS_CONFIGURED="NONE"
DNS_NAME_RESOLUTION="NOT_TESTED"
TIME_READINESS="NOT_CHECKED"
CLOCK_SKEW_SECONDS="UNKNOWN"
MAX_CLOCK_SKEW_SECONDS="${DP_MAX_CLOCK_SKEW_SECONDS:-300}"
NTP_SOURCE_CLASS="UNKNOWN"
NTP_SELECTED_PEER="NONE"
BRINGUP_READY="NO"
NTP_BRINGUP_READINESS="NOT_CHECKED"
BRINGUP_EXECUTED="NO"

DP_POSTBOOT_TEST_ROOT="${DP_POSTBOOT_TEST_ROOT:-}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
RESOLVECTL_BIN="${RESOLVECTL_BIN:-resolvectl}"
GETENT_BIN="${GETENT_BIN:-getent}"
CURL_BIN="${CURL_BIN:-curl}"
NTPQ_BIN="${NTPQ_BIN:-ntpq}"
NTPWAIT_BIN="${NTPWAIT_BIN:-ntpwait}"
TIMEDATECTL_BIN="${TIMEDATECTL_BIN:-timedatectl}"
# Bound every ntpq probe; unbounded ntpq can hang postboot indefinitely (field).
NTPQ_PROBE_TIMEOUT_SECONDS="${NTPQ_PROBE_TIMEOUT_SECONDS:-20}"
NTPQ_PROBE_OUTPUT=""

postboot_policy_log() {
  local level="$1"; shift
  if declare -F log >/dev/null 2>&1; then
    log "$level" "$*"
  else
    printf '%s: %s\n' "$level" "$*"
  fi
}

dns_hp() {
  local p="$1"
  if [[ -n "${DP_POSTBOOT_TEST_ROOT:-}" ]]; then
    printf '%s%s' "${DP_POSTBOOT_TEST_ROOT%/}" "$p"
  else
    printf '%s' "$p"
  fi
}

dns_is_valid_ipv4() {
  local ip="${1:-}" a b c d octet
  IFS=. read -r a b c d <<<"$ip"
  [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" && "$ip" != *.*.*.*.* ]] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
  done
}

dedup_valid_ipv4_words() {
  local word
  for word in "$@"; do
    dns_is_valid_ipv4 "$word" && printf '%s\n' "$word"
  done | awk '!seen[$0]++'
}

interfaces_dns_servers() {
  local f
  f="$(dns_hp /etc/network/interfaces)"
  [[ -r "$f" ]] || return 0
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*dns-nameservers[[:space:]]+/ {
      sub(/^[[:space:]]*dns-nameservers[[:space:]]+/, "")
      print
    }
  ' "$f" | tr ' \t' '\n' | awk 'NF'
}

resolv_conf_dns_servers() {
  local f
  f="$(dns_hp /etc/resolv.conf)"
  [[ -r "$f" ]] || return 0
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*nameserver[[:space:]]+/ {print $2}
  ' "$f"
}

configured_ntp_hostname() {
  local f token
  f="$(dns_hp /etc/ntpsec/ntp.conf)"
  [[ -r "$f" ]] || return 1
  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    if ! dns_is_valid_ipv4 "$token" && [[ "$token" != "localhost" && "$token" != "::1" ]]; then
      printf '%s' "$token"
      return 0
    fi
  done < <(awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*(server|pool)[[:space:]]+/ {print $2}
  ' "$f")
  return 1
}

check_dns_name_resolution() {
  local host="${1:-}"
  [[ -n "$host" ]] || host="$(configured_ntp_hostname 2>/dev/null || true)"
  [[ -n "$host" ]] || host="${DP_DNS_VALIDATION_HOSTNAME:-archive.ubuntu.com}"
  if "$GETENT_BIN" ahosts "$host" >/dev/null 2>&1; then
    DNS_NAME_RESOLUTION="PASS"
    postboot_policy_log INFO "DNS_VALIDATION_HOSTNAME=${host}"
    return 0
  fi
  DNS_NAME_RESOLUTION="FAIL"
  postboot_policy_log INFO "DNS_VALIDATION_HOSTNAME=${host}"
  return 1
}

resolver_service_state() {
  local enabled active
  enabled="$("$SYSTEMCTL_BIN" is-enabled systemd-resolved 2>/dev/null || true)"
  enabled="$(printf '%s\n' "$enabled" | awk 'NF{print; exit}')"
  active="$("$SYSTEMCTL_BIN" is-active systemd-resolved 2>/dev/null || true)"
  active="$(printf '%s\n' "$active" | awk 'NF{print; exit}')"
  printf '%s|%s' "${enabled:-unknown}" "${active:-unknown}"
}

resolved_uses_one_configured_dns() {
  local servers_csv="$1" output ip
  output="$("$RESOLVECTL_BIN" dns 2>/dev/null || true)"
  IFS=, read -ra _dns_array <<<"$servers_csv"
  for ip in "${_dns_array[@]}"; do
    [[ -n "$ip" ]] || continue
    if printf '%s\n' "$output" | grep -Fq -- "$ip"; then
      return 0
    fi
  done
  local upstream
  upstream="$(dns_hp /run/systemd/resolve/resolv.conf)"
  if [[ -r "$upstream" ]]; then
    for ip in "${_dns_array[@]}"; do
      grep -Eq "^[[:space:]]*nameserver[[:space:]]+${ip//./\.}([[:space:]]|$)" "$upstream" && return 0
    done
  fi
  return 1
}

restore_resolved_service_state() {
  local prior_enabled="$1" prior_active="$2"
  "$SYSTEMCTL_BIN" stop systemd-resolved >/dev/null 2>&1 || true
  case "$prior_enabled" in
    masked)
      "$SYSTEMCTL_BIN" disable systemd-resolved >/dev/null 2>&1 || true
      "$SYSTEMCTL_BIN" mask systemd-resolved >/dev/null 2>&1 || true
      ;;
    enabled|enabled-runtime|static|indirect)
      "$SYSTEMCTL_BIN" unmask systemd-resolved >/dev/null 2>&1 || true
      "$SYSTEMCTL_BIN" enable systemd-resolved >/dev/null 2>&1 || true
      ;;
    *)
      "$SYSTEMCTL_BIN" unmask systemd-resolved >/dev/null 2>&1 || true
      "$SYSTEMCTL_BIN" disable systemd-resolved >/dev/null 2>&1 || true
      ;;
  esac
  if [[ "$prior_active" == "active" ]]; then
    "$SYSTEMCTL_BIN" start systemd-resolved >/dev/null 2>&1 || true
  fi
}

emit_dns_result() {
  postboot_policy_log INFO "DNS_RESOLVER_STATE=${DNS_RESOLVER_STATE}"
  postboot_policy_log INFO "DNS_RESOLVER_REPAIR=${DNS_RESOLVER_REPAIR}"
  postboot_policy_log INFO "DNS_SERVERS_CONFIGURED=${DNS_SERVERS_CONFIGURED}"
  postboot_policy_log INFO "DNS_NAME_RESOLUTION=${DNS_NAME_RESOLUTION}"
}

check_and_repair_dns_resolver() {
  local resolv raw_target canonical stub interfaces state_pair enabled active
  local dns_lines dns_csv dropin_dir dropin tmp backup had_dropin=0
  local repair_ok=1 current_active
  DNS_RESOLVER_STATE="NOT_CHECKED"
  DNS_RESOLVER_REPAIR="NOT_ATTEMPTED"
  DNS_SERVERS_CONFIGURED="NONE"
  DNS_NAME_RESOLUTION="NOT_TESTED"

  resolv="$(dns_hp /etc/resolv.conf)"
  stub="$(dns_hp /run/systemd/resolve/stub-resolv.conf)"
  interfaces="$(dns_hp /etc/network/interfaces)"

  if [[ -f "$resolv" && ! -L "$resolv" ]]; then
    dns_lines="$(resolv_conf_dns_servers | while read -r ip; do dns_is_valid_ipv4 "$ip" && echo "$ip"; done | awk '!seen[$0]++')"
    if [[ -n "$dns_lines" ]]; then
      DNS_RESOLVER_STATE="HEALTHY_STATIC"
      DNS_RESOLVER_REPAIR="NOT_REQUIRED"
      DNS_SERVERS_CONFIGURED="$(printf '%s\n' "$dns_lines" | paste -sd, -)"
      check_dns_name_resolution || true
      emit_dns_result
      return 0
    fi
    DNS_RESOLVER_STATE="BROKEN_STATIC"
    DNS_RESOLVER_REPAIR="FAIL"
    check_dns_name_resolution || true
    emit_dns_result
    return 1
  fi

  if [[ -L "$resolv" ]]; then
    raw_target="$(readlink "$resolv" 2>/dev/null || true)"
    canonical="$(readlink -f "$resolv" 2>/dev/null || true)"
    if [[ "$canonical" == "$stub" && -f "$stub" ]]; then
      if check_dns_name_resolution; then
        DNS_RESOLVER_STATE="HEALTHY_SYSTEMD_RESOLVED"
        DNS_RESOLVER_REPAIR="NOT_REQUIRED"
        dns_lines="$(interfaces_dns_servers | while read -r ip; do dns_is_valid_ipv4 "$ip" && echo "$ip"; done | awk '!seen[$0]++')"
        [[ -n "$dns_lines" ]] && DNS_SERVERS_CONFIGURED="$(printf '%s\n' "$dns_lines" | paste -sd, -)"
        emit_dns_result
        return 0
      fi
      DNS_RESOLVER_STATE="BROKEN_SYSTEMD_RESOLVED"
      DNS_RESOLVER_REPAIR="FAIL"
      emit_dns_result
      return 1
    fi

    state_pair="$(resolver_service_state)"
    enabled="${state_pair%%|*}"
    active="${state_pair#*|}"
    if [[ "$raw_target" == "../run/systemd/resolve/stub-resolv.conf" && ! -e "$stub" \
          && ( "$enabled" == "masked" || "$active" != "active" ) ]]; then
      dns_lines="$(interfaces_dns_servers | while read -r ip; do dns_is_valid_ipv4 "$ip" && echo "$ip"; done | awk '!seen[$0]++')"
      if [[ -z "$dns_lines" ]]; then
        DNS_RESOLVER_STATE="BROKEN_SYSTEMD_RESOLVED"
        DNS_RESOLVER_REPAIR="FAIL"
        DNS_SERVERS_CONFIGURED="NONE"
        DNS_NAME_RESOLUTION="NOT_TESTED"
        postboot_policy_log ERROR "ERROR: broken systemd-resolved stub link and no valid dns-nameservers in ${interfaces}"
        emit_dns_result
        return 1
      fi
      dns_csv="$(printf '%s\n' "$dns_lines" | paste -sd, -)"
      DNS_SERVERS_CONFIGURED="$dns_csv"
      dropin_dir="$(dns_hp /etc/systemd/resolved.conf.d)"
      dropin="${dropin_dir}/20-dp-static-dns.conf"
      mkdir -p "$dropin_dir"
      backup="${dropin}.rollback.$$"
      if [[ -e "$dropin" ]]; then
        cp -a "$dropin" "$backup"
        had_dropin=1
      fi
      tmp="${dropin}.tmp.$$"
      {
        printf '[Resolve]\nDNS='
        printf '%s\n' "$dns_lines" | paste -sd' ' -
        printf 'FallbackDNS=\n'
      } >"$tmp"
      chmod 0644 "$tmp"
      mv -f "$tmp" "$dropin"

      "$SYSTEMCTL_BIN" unmask systemd-resolved >/dev/null 2>&1 || repair_ok=0
      "$SYSTEMCTL_BIN" enable --now systemd-resolved >/dev/null 2>&1 || repair_ok=0

      canonical="$(readlink -f "$resolv" 2>/dev/null || true)"
      current_active="$("$SYSTEMCTL_BIN" is-active systemd-resolved 2>/dev/null || true)"
      current_active="$(printf '%s\n' "$current_active" | awk 'NF {print; exit}')"
      [[ "$current_active" == "active" ]] || repair_ok=0
      [[ -f "$stub" ]] || repair_ok=0
      [[ "$canonical" == "$stub" ]] || repair_ok=0
      resolved_uses_one_configured_dns "$dns_csv" || repair_ok=0
      check_dns_name_resolution || repair_ok=0

      if [[ "$repair_ok" -eq 1 ]]; then
        rm -f "$backup"
        DNS_RESOLVER_STATE="RECOVERED_SYSTEMD_RESOLVED"
        DNS_RESOLVER_REPAIR="PASS"
        emit_dns_result
        return 0
      fi

      rm -f "$dropin"
      if [[ "$had_dropin" -eq 1 && -e "$backup" ]]; then
        mv -f "$backup" "$dropin"
      else
        rm -f "$backup"
      fi
      restore_resolved_service_state "$enabled" "$active"
      DNS_RESOLVER_STATE="BROKEN_SYSTEMD_RESOLVED"
      DNS_RESOLVER_REPAIR="FAIL"
      emit_dns_result
      return 1
    fi

    DNS_RESOLVER_STATE="UNKNOWN_LAYOUT"
    DNS_RESOLVER_REPAIR="NOT_ATTEMPTED"
    postboot_policy_log WARN "DNS_RESOLVER_DIAGNOSTIC=symlink target=${raw_target:-unknown} canonical=${canonical:-missing} resolved_enabled=${enabled:-unknown} resolved_active=${active:-unknown}"
    if check_dns_name_resolution; then
      emit_dns_result
      return 0
    fi
    emit_dns_result
    return 1
  fi

  DNS_RESOLVER_STATE="UNKNOWN_LAYOUT"
  DNS_RESOLVER_REPAIR="NOT_ATTEMPTED"
  postboot_policy_log WARN "DNS_RESOLVER_DIAGNOSTIC=/etc/resolv.conf missing or unsupported layout"
  if check_dns_name_resolution; then
    emit_dns_result
    return 0
  fi
  emit_dns_result
  return 1
}

is_positive_integer() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

is_valid_ipv4() {
  local ip="${1:-}" a b c d octet
  IFS=. read -r a b c d <<<"$ip"
  [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || return 1
  [[ "$ip" != *.*.*.*.* ]] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
  done
}

ipv4_source_scope() {
  local ip="$1" a b c d
  is_valid_ipv4 "$ip" || { printf 'UNKNOWN'; return 1; }
  IFS=. read -r a b c d <<<"$ip"
  if ((a == 10)) || ((a == 172 && b >= 16 && b <= 31)) || ((a == 192 && b == 168)); then
    printf 'INTERNAL'
  elif ((a == 127)) || ((a == 169 && b == 254)) || ((a == 0)) || ((a >= 224)); then
    printf 'IGNORED'
  else
    printf 'PUBLIC'
  fi
}

normalize_ntp_source_token() {
  local token="${1:-}"
  token="${token#\*}"
  token="${token#+}"
  token="${token#-}"
  token="${token#o}"
  token="${token#x}"
  token="${token#\#}"
  token="${token#[}"
  token="${token%]}"
  token="${token%.}"
  printf '%s' "$token"
}

classify_ntp_source_token() {
  local token ip scope saw_public=0
  token="$(normalize_ntp_source_token "${1:-}")"
  [[ -n "$token" ]] || { printf 'UNKNOWN'; return 0; }
  case "$token" in
    LOCAL|LOCAL\(*|localhost|localhost.*|0.0.0.0|127.*|169.254.*|::1|fe80:*|FE80:*)
      printf 'IGNORED'; return 0 ;;
  esac
  if is_valid_ipv4 "$token"; then
    ipv4_source_scope "$token"
    return 0
  fi
  if command -v "$GETENT_BIN" >/dev/null 2>&1; then
    while IFS= read -r ip; do
      [[ -n "$ip" ]] || continue
      scope="$(ipv4_source_scope "$ip" 2>/dev/null || printf UNKNOWN)"
      case "$scope" in
        INTERNAL) printf 'INTERNAL'; return 0 ;;
        PUBLIC) saw_public=1 ;;
      esac
    done < <("$GETENT_BIN" ahostsv4 "$token" 2>/dev/null | awk '{print $1}' | awk '!seen[$0]++')
  fi
  if [[ "$saw_public" -eq 1 ]]; then
    printf 'PUBLIC'
  else
    printf 'UNKNOWN'
  fi
}

classify_ntp_sources() {
  local ntpq_text="${1:-}" token class have_internal=0 have_public=0
  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    class="$(classify_ntp_source_token "$token")"
    case "$class" in
      INTERNAL) have_internal=1 ;;
      PUBLIC) have_public=1 ;;
    esac
  done < <(
    {
      printf '%s\n' "$ntpq_text" | awk 'NR>2 && NF>=1 {print $1}'
      if [[ -r "$(dns_hp /etc/ntpsec/ntp.conf)" ]]; then
        awk '
          /^[[:space:]]*#/ {next}
          /^[[:space:]]*(server|pool)[[:space:]]+/ {print $2}
        ' "$(dns_hp /etc/ntpsec/ntp.conf)"
      fi
    } | awk 'NF && !seen[$0]++'
  )
  if [[ "$have_internal" -eq 1 ]]; then
    NTP_SOURCE_CLASS="INTERNAL"
  elif [[ "$have_public" -eq 1 ]]; then
    NTP_SOURCE_CLASS="PUBLIC"
  else
    NTP_SOURCE_CLASS="UNKNOWN"
  fi
}

selected_ntp_peer_from_text() {
  local text="${1:-}"
  printf '%s\n' "$text" | awk 'NR>2 && $1 ~ /^\*/ {gsub(/^\*/, "", $1); print $1; exit}'
}

ntpq_clock_reference_from_text() {
  local text="${1:-}"
  printf '%s\n' "$text" | awk '
    function abs(v) { return v < 0 ? -v : v }
    NR > 2 && NF >= 9 {
      remote=$1; reach=$7; off=$9
      selected=(remote ~ /^\*/)
      gsub(/^[*+#ox-]/, "", remote)
      if (reach !~ /^[0-9]+$/ || reach == 0) next
      if (off !~ /^[-+]?[0-9]+([.][0-9]+)?$/) next
      a=abs(off)
      if (selected && !have_sel) { sel=a; selpeer=remote; have_sel=1 }
      if (!have_any || a < best) { best=a; bestpeer=remote; have_any=1 }
    }
    END {
      if (have_sel) printf "%d|%s\n", int((sel + 999.999999) / 1000), selpeer
      else if (have_any) printf "%d|%s\n", int((best + 999.999999) / 1000), bestpeer
    }
  '
}

http_date_clock_skew_seconds() {
  local base_url="${1:-}" headers date_value ref_epoch local_epoch delta
  [[ -n "$base_url" ]] || return 1
  headers="$("$CURL_BIN" -fsSI --connect-timeout 5 --max-time 10 "$base_url" 2>/dev/null || true)"
  date_value="$(printf '%s\n' "$headers" | awk 'BEGIN{IGNORECASE=1} /^Date:[[:space:]]*/ {sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit}')"
  [[ -n "$date_value" ]] || return 1
  ref_epoch="$(LC_ALL=C date -u -d "$date_value" +%s 2>/dev/null || true)"
  local_epoch="$(date -u +%s 2>/dev/null || true)"
  [[ "$ref_epoch" =~ ^[0-9]+$ && "$local_epoch" =~ ^[0-9]+$ ]] || return 1
  if ((local_epoch >= ref_epoch)); then delta=$((local_epoch-ref_epoch)); else delta=$((ref_epoch-local_epoch)); fi
  printf '%s\n' "$delta"
}

run_ntpwait_probe() {
  command -v "$NTPWAIT_BIN" >/dev/null 2>&1 || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout 20 "$NTPWAIT_BIN" -n 1 -s 1 >/dev/null 2>&1
  else
    "$NTPWAIT_BIN" -n 1 -s 1 >/dev/null 2>&1
  fi
}

# Run one ntpq invocation under a hard wall-clock bound.
# Sets NTPQ_PROBE_OUTPUT on success. On timeout logs NTPQ_PROBE_TIMEOUT=YES and
# leaves NTPQ_PROBE_OUTPUT empty (never treat timed-out output as sync proof).
run_ntpq_probe() {
  local probe="${1:-}"
  shift || true
  local timeout_secs="${NTPQ_PROBE_TIMEOUT_SECONDS:-20}"
  local out="" rc=0 pid waited=0
  NTPQ_PROBE_OUTPUT=""
  [[ -n "$probe" ]] || return 1
  command -v "$NTPQ_BIN" >/dev/null 2>&1 || return 1
  if ! is_positive_integer "$timeout_secs"; then
    timeout_secs=20
  fi

  if command -v timeout >/dev/null 2>&1; then
    out="$(timeout "$timeout_secs" "$NTPQ_BIN" "$@" 2>/dev/null)" || rc=$?
    if [[ "$rc" -eq 124 ]]; then
      postboot_policy_log WARN "NTPQ_PROBE_TIMEOUT=YES probe=${probe}"
      return 1
    fi
    [[ "$rc" -eq 0 ]] || return 1
    NTPQ_PROBE_OUTPUT="$out"
    return 0
  fi

  # Portable fallback when coreutils timeout(1) is unavailable.
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/ntpq-probe.XXXXXX")" || return 1
  "$NTPQ_BIN" "$@" >"$out_file" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ((waited >= timeout_secs)); then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$out_file"
      postboot_policy_log WARN "NTPQ_PROBE_TIMEOUT=YES probe=${probe}"
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$out_file"
    return 1
  fi
  out="$(cat "$out_file" 2>/dev/null || true)"
  rm -f "$out_file"
  NTPQ_PROBE_OUTPUT="$out"
  return 0
}

check_time_readiness() {
  local ntpq_text="" rv_text="" td="" ref="" skew="" ref_peer=""
  TIME_READINESS="FAIL_TIME_UNVERIFIABLE"
  CLOCK_SKEW_SECONDS="UNKNOWN"
  MAX_CLOCK_SKEW_SECONDS="${DP_MAX_CLOCK_SKEW_SECONDS:-300}"
  NTP_SOURCE_CLASS="UNKNOWN"
  NTP_SELECTED_PEER="NONE"
  BRINGUP_READY="NO"
  NTP_BRINGUP_READINESS="FAIL"

  if ! is_positive_integer "$MAX_CLOCK_SKEW_SECONDS"; then
    postboot_policy_log ERROR "ERROR: DP_MAX_CLOCK_SKEW_SECONDS must be a positive integer"
    return 1
  fi

  if command -v "$NTPQ_BIN" >/dev/null 2>&1; then
    # Every ntpq form is bounded. If -pn times out/fails, -p is still bounded.
    if run_ntpq_probe pn -pn; then
      ntpq_text="$NTPQ_PROBE_OUTPUT"
    elif run_ntpq_probe p -p; then
      ntpq_text="$NTPQ_PROBE_OUTPUT"
    else
      ntpq_text=""
    fi
    if run_ntpq_probe rv rv; then
      rv_text="$NTPQ_PROBE_OUTPUT"
    else
      rv_text=""
    fi
  fi
  NTP_SELECTED_PEER="$(selected_ntp_peer_from_text "$ntpq_text")"
  [[ -n "$NTP_SELECTED_PEER" ]] || NTP_SELECTED_PEER="NONE"
  classify_ntp_sources "$ntpq_text"

  if run_ntpwait_probe; then
    TIME_READINESS="PASS_SYNCED"
    CLOCK_SKEW_SECONDS="0"
    BRINGUP_READY="YES"
    NTP_BRINGUP_READINESS="PASS"
  elif [[ "$NTP_SELECTED_PEER" != "NONE" ]] && printf '%s\n' "$rv_text" | grep -Eq '(^|[[:space:],])leap=00([[:space:],]|$)'; then
    TIME_READINESS="PASS_SYNCED"
    CLOCK_SKEW_SECONDS="0"
    BRINGUP_READY="YES"
    NTP_BRINGUP_READINESS="PASS"
  else
    if command -v "$TIMEDATECTL_BIN" >/dev/null 2>&1; then
      td="$("$TIMEDATECTL_BIN" status 2>/dev/null || "$TIMEDATECTL_BIN" 2>/dev/null || true)"
    fi
    if printf '%s\n' "$td" | grep -qiE 'System clock synchronized:[[:space:]]*yes'; then
      TIME_READINESS="PASS_SYNCED"
      CLOCK_SKEW_SECONDS="0"
      BRINGUP_READY="YES"
      NTP_BRINGUP_READINESS="PASS"
    else
      ref="$(ntpq_clock_reference_from_text "$ntpq_text" || true)"
      if [[ -n "$ref" ]]; then
        skew="${ref%%|*}"
        ref_peer="${ref#*|}"
        postboot_policy_log INFO "TIME_REFERENCE=NTP_PEER peer=${ref_peer}"
      else
        # The mirror this client was built for is the only trusted HTTP Date
        # reference; skip the probe rather than guess an address.
        local time_ref_url="${DP_TIME_REFERENCE_URL:-${PIN_MIRROR_BASE:-${MIRROR_BASE:-}}}"
        if [[ -n "$time_ref_url" ]]; then
          skew="$(http_date_clock_skew_seconds "$time_ref_url" || true)"
          [[ -n "$skew" ]] && postboot_policy_log INFO "TIME_REFERENCE=HTTP_DATE url=${time_ref_url}"
        else
          postboot_policy_log WARN "TIME_REFERENCE=UNAVAILABLE no NTP peer and no mirror base for HTTP Date"
        fi
      fi
      if [[ "$skew" =~ ^[0-9]+$ ]]; then
        CLOCK_SKEW_SECONDS="$skew"
        if ((skew <= MAX_CLOCK_SKEW_SECONDS)); then
          TIME_READINESS="PASS_WITH_WARNING"
          BRINGUP_READY="YES"
          NTP_BRINGUP_READINESS="PASS"
          postboot_policy_log WARN "WARNING: time synchronization not confirmed; clock skew ${skew}s is within ${MAX_CLOCK_SKEW_SECONDS}s"
        else
          TIME_READINESS="FAIL_CLOCK_SKEW"
          BRINGUP_READY="NO"
          NTP_BRINGUP_READINESS="FAIL"
          postboot_policy_log ERROR "ERROR: clock skew ${skew}s exceeds ${MAX_CLOCK_SKEW_SECONDS}s"
        fi
      else
        TIME_READINESS="FAIL_TIME_UNVERIFIABLE"
        BRINGUP_READY="NO"
        NTP_BRINGUP_READINESS="FAIL"
        postboot_policy_log ERROR "ERROR: time synchronization is unconfirmed and no usable time reference was obtained"
      fi
    fi
  fi

  if [[ "$BRINGUP_READY" == "YES" && "$NTP_SOURCE_CLASS" != "INTERNAL" ]]; then
    postboot_policy_log WARN "WARNING: no internal NTP source detected; continuing because local clock readiness passed"
  fi
  postboot_policy_log INFO "TIME_READINESS=${TIME_READINESS}"
  postboot_policy_log INFO "CLOCK_SKEW_SECONDS=${CLOCK_SKEW_SECONDS}"
  postboot_policy_log INFO "MAX_CLOCK_SKEW_SECONDS=${MAX_CLOCK_SKEW_SECONDS}"
  postboot_policy_log INFO "NTP_SOURCE_CLASS=${NTP_SOURCE_CLASS}"
  postboot_policy_log INFO "NTP_SELECTED_PEER=${NTP_SELECTED_PEER}"
  postboot_policy_log INFO "BRINGUP_READY=${BRINGUP_READY}"
  [[ "$BRINGUP_READY" == "YES" ]]
}
