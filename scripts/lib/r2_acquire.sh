#!/usr/bin/env bash
# scripts/lib/r2_acquire.sh — download Ubuntu OS Core package from fixed R2 URL
# shellcheck shell=bash
set +x

if [[ -n "${R2_ACQUIRE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
R2_ACQUIRE_LOADED=1

R2_CURL_CONNECT_TIMEOUT="${R2_CURL_CONNECT_TIMEOUT:-30}"
R2_CURL_RETRIES="${R2_CURL_RETRIES:-5}"
R2_CURL_RETRY_DELAY="${R2_CURL_RETRY_DELAY:-5}"
R2_PROGRESS_INTERVAL_SEC="${R2_PROGRESS_INTERVAL_SEC:-3}"

r2_cache_dir() {
  printf '%s/r2\n' "${MM_CACHE_ROOT}"
}

r2_require_url() {
  if ! mm_r2_url_configured; then
    mm_error "CONFIGURATION_REQUIRED=YES"
    mm_error "R2_URL_REQUIRED_LOCATION=scripts/lib/mirror_manager_common.sh:OS_CORE_R2_URL_CONSTANT"
    mm_die "OS_CORE_R2_URL=CONFIGURATION_REQUIRED"
  fi
  mm_ok "OS_CORE_R2_URL=CONFIGURED"
}

r2_reject_html_body() {
  local path="$1"
  local label="${2:-$path}"
  [[ -f "$path" ]] || return 1
  local head
  # Binary packages may contain NUL; strip before grep.
  head="$(head -c 256 "$path" 2>/dev/null | tr -d '\0' || true)"
  if printf '%s' "$head" | grep -qiE '<!DOCTYPE[[:space:]]*html|<html[[:space:]]'; then
    mm_error "R2_HTML_BODY=FAIL file=${label}"
    return 1
  fi
  return 0
}

# Parse last HTTP status from a curl -D header dump.
r2_http_last_status() {
  local hdr="$1"
  awk 'BEGIN{s=""} /^HTTP\//{s=$2} END{print s}' "$hdr"
}

# Parse Content-Range start offset: "bytes START-END/TOTAL" → START
r2_content_range_start() {
  local hdr="$1"
  awk -F': ' '
    tolower($1)=="content-range" {
      gsub("\r","",$2)
      if ($2 ~ /^bytes [0-9]+-/) {
        sub(/^bytes /,"",$2)
        sub(/-.*$/,"",$2)
        print $2
        exit
      }
    }
  ' "$hdr"
}

# Safe resumable download into $part (not finalized).
# Guarantees:
# - Cache-Control/Pragma: no-cache on every request
# - HTTP 206 + Content-Range start == local size → append only
# - HTTP 200 with local partial present → discard partial, replace (never append)
# - Wrong Content-Range → fail (no append)
r2_http_download_to_part() {
  local url="$1"
  local part="$2"
  local label="${3:-$(basename "$part")}"

  local hdr err resp have status cr_start
  hdr="$(mktemp)"
  err="$(mktemp)"
  # Observable transfer file so the progress sampler can see growth during curl.
  resp="${part}.download"
  rm -f "$resp"
  have=0
  if [[ -f "$part" ]]; then
    have="$(stat -c%s "$part" 2>/dev/null || echo 0)"
  fi
  if ! [[ "$have" =~ ^[0-9]+$ ]]; then
    have=0
  fi

  local -a curl_args=(
    -sS -L
    --connect-timeout "$R2_CURL_CONNECT_TIMEOUT"
    --retry "$R2_CURL_RETRIES"
    --retry-delay "$R2_CURL_RETRY_DELAY"
    --retry-all-errors
    -H "Cache-Control: no-cache"
    -H "Pragma: no-cache"
    -D "$hdr"
    -o "$resp"
  )

  if [[ "$have" -gt 0 ]]; then
    mm_info "R2_RESUME_ATTEMPT file=${label} local_bytes=${have}"
    curl_args+=(-H "Range: bytes=${have}-")
  fi

  # Preserve real curl rc: `if ! curl; then rc=$?` yields 0 inside the then-branch.
  local rc=0
  if curl "${curl_args[@]}" "$url" 2>"$err"; then
    rc=0
  else
    rc=$?
    mm_redact <"$err" >&2 || true
    rm -f "$hdr" "$err" "$resp"
    return "$rc"
  fi
  rm -f "$err"

  status="$(r2_http_last_status "$hdr")"
  if [[ -z "$status" ]]; then
    mm_error "R2_HTTP_STATUS_MISSING file=${label}"
    rm -f "$hdr" "$resp"
    return 1
  fi

  if [[ "$have" -gt 0 ]]; then
    case "$status" in
      206)
        cr_start="$(r2_content_range_start "$hdr")"
        if [[ -z "$cr_start" || "$cr_start" != "$have" ]]; then
          mm_error "R2_CONTENT_RANGE_MISMATCH file=${label} local=${have} remote_start=${cr_start:-MISSING}"
          rm -f "$hdr" "$resp" "$part"
          return 1
        fi
        # Append remainder only.
        cat "$resp" >>"$part"
        rm -f "$resp"
        mm_ok "R2_RESUME_APPEND=PASS file=${label} status=206"
        ;;
      200)
        # Server ignored Range (e.g. Cloudflare cache HIT). Never append.
        mm_warn "R2_RANGE_IGNORED=YES file=${label} action=clean_restart"
        mv -f "$resp" "$part"
        mm_ok "R2_CLEAN_RESTART=PASS file=${label} status=200"
        ;;
      *)
        mm_error "R2_RESUME_UNEXPECTED_STATUS file=${label} status=${status}"
        rm -f "$hdr" "$resp"
        return 1
        ;;
    esac
  else
    # Fresh download: accept 200 (full) or 206 covering from 0.
    case "$status" in
      200)
        mv -f "$resp" "$part"
        ;;
      206)
        cr_start="$(r2_content_range_start "$hdr")"
        if [[ -n "$cr_start" && "$cr_start" != "0" ]]; then
          mm_error "R2_FRESH_BAD_RANGE file=${label} start=${cr_start}"
          rm -f "$hdr" "$resp" "$part"
          return 1
        fi
        mv -f "$resp" "$part"
        ;;
      *)
        mm_error "R2_FRESH_UNEXPECTED_STATUS file=${label} status=${status}"
        rm -f "$hdr" "$resp"
        return 1
        ;;
    esac
  fi
  rm -f "$hdr"
  return 0
}

# Small sidecar: always clean download (no resume / no append).
r2_http_download_fresh() {
  local url="$1"
  local part="$2"
  local label="${3:-$(basename "$part")}"
  local err
  err="$(mktemp)"
  rm -f "$part"
  if ! curl -f -L \
    --connect-timeout "$R2_CURL_CONNECT_TIMEOUT" \
    --retry "$R2_CURL_RETRIES" \
    --retry-delay "$R2_CURL_RETRY_DELAY" \
    --retry-all-errors \
    -H "Cache-Control: no-cache" \
    -H "Pragma: no-cache" \
    -o "$part" \
    "$url" 2>"$err"; then
    mm_redact <"$err" >&2 || true
    rm -f "$err" "$part"
    return 1
  fi
  rm -f "$err"
  return 0
}

r2_download_package() {
  # Downloads OS Core .tar (+ .sha256 sidecar) into cache; sets OS_CORE_PACKAGE.
  r2_require_url
  local dest_dir part final url start_ts now elapsed downloaded expected pct rate
  local progress_file initial_bytes transfer_bytes
  dest_dir="$(r2_cache_dir)"
  mkdir -p "$dest_dir"
  url="${OS_CORE_R2_URL}"
  local base_name
  base_name="$(basename "${url%%\?*}")"
  [[ -n "$base_name" ]] || base_name="ubuntu-os-core.tar"
  final="${dest_dir}/${base_name}"
  part="${final}.part"
  progress_file="${part}.download"
  initial_bytes=0
  if [[ -f "$part" ]]; then
    initial_bytes="$(stat -c%s "$part" 2>/dev/null || echo 0)"
    [[ "$initial_bytes" =~ ^[0-9]+$ ]] || initial_bytes=0
  fi

  # Sidecar checksum URL: same path + .sha256
  local sha_url="${url}.sha256"
  local sha_final="${final}.sha256"
  local sha_part="${sha_final}.part"

  mm_info "R2_DOWNLOAD_START url_redacted=yes file=${base_name}"
  start_ts="$(date +%s)"
  expected=""
  local cl err_head
  err_head="$(mktemp)"
  cl="$(
    curl -sS -I -L \
      --connect-timeout "$R2_CURL_CONNECT_TIMEOUT" \
      -H "Cache-Control: no-cache" \
      -H "Pragma: no-cache" \
      "$url" 2>"$err_head" \
      | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2; exit}'
  )" || true
  rm -f "$err_head"
  if [[ "$cl" =~ ^[0-9]+$ ]]; then
    expected="$cl"
  fi

  local progress_pid=""
  (
    while true; do
      sleep "$R2_PROGRESS_INTERVAL_SEC" || break
      now="$(date +%s)"
      elapsed=$((now - start_ts))
      transfer_bytes=0
      if [[ -f "$progress_file" ]]; then
        transfer_bytes="$(stat -c%s "$progress_file" 2>/dev/null || echo 0)"
        [[ "$transfer_bytes" =~ ^[0-9]+$ ]] || transfer_bytes=0
      fi
      downloaded=$((initial_bytes + transfer_bytes))
      if [[ -n "$expected" && "$expected" -gt 0 && "$downloaded" -gt "$expected" ]]; then
        downloaded="$expected"
      fi
      pct="UNKNOWN"
      rate="UNKNOWN"
      if [[ -n "$expected" && "$expected" -gt 0 ]]; then
        pct=$((downloaded * 100 / expected))
      fi
      if [[ "$elapsed" -gt 0 ]]; then
        rate=$((downloaded / elapsed))
      fi
      mm_info "R2_DOWNLOAD_PROGRESS file=${base_name} downloaded_bytes=${downloaded} expected_bytes=${expected:-UNKNOWN} percentage=${pct} elapsed=${elapsed}s rate_bps=${rate}"
      mm_progress_line "R2 ${base_name}" "$downloaded" "${expected:-}" "$elapsed" "$rate"
    done
  ) &
  progress_pid=$!

  local rc=0
  if ! r2_http_download_to_part "$url" "$part" "$base_name"; then
    rc=1
  fi
  if [[ -n "$progress_pid" ]]; then
    kill "$progress_pid" 2>/dev/null || true
    wait "$progress_pid" 2>/dev/null || true
  fi
  if [[ "$rc" -ne 0 ]]; then
    mm_state_set R2_OS_CORE_DOWNLOADED FAIL
    mm_die "R2_DOWNLOAD=FAIL file=${base_name}"
  fi

  now="$(date +%s)"
  elapsed=$((now - start_ts))
  downloaded="$(stat -c%s "$part" 2>/dev/null || echo 0)"
  pct="UNKNOWN"
  rate="UNKNOWN"
  if [[ -n "$expected" && "$expected" -gt 0 ]]; then
    pct=$((downloaded * 100 / expected))
  fi
  if [[ "$elapsed" -gt 0 ]]; then
    rate=$((downloaded / elapsed))
  fi
  mm_info "R2_DOWNLOAD_PROGRESS file=${base_name} downloaded_bytes=${downloaded} expected_bytes=${expected:-UNKNOWN} percentage=${pct} elapsed=${elapsed}s rate_bps=${rate} final=yes"
  mm_progress_line "R2 ${base_name}" "$downloaded" "${expected:-}" "$elapsed" "$rate"

  if ! r2_reject_html_body "$part" "$base_name"; then
    rm -f "$part"
    mm_state_set R2_OS_CORE_DOWNLOADED FAIL
    mm_die "R2_DOWNLOAD=FAIL reason=html_body"
  fi
  if [[ -n "$expected" && "$expected" =~ ^[0-9]+$ ]]; then
    local got
    got="$(stat -c%s "$part")"
    if [[ "$got" -ne "$expected" ]]; then
      mm_warn "R2_CONTENT_LENGTH_MISMATCH expected=${expected} got=${got}"
    fi
  fi
  mv -f "$part" "$final" || mm_die "R2_FINALIZE=FAIL file=${base_name}"

  # Download outer checksum (required) — always fresh, never resume-append.
  if ! r2_http_download_fresh "$sha_url" "$sha_part" "${base_name}.sha256"; then
    mm_state_set R2_OS_CORE_CHECKSUM FAIL
    mm_die "R2_SHA256_DOWNLOAD=FAIL"
  fi
  if ! r2_reject_html_body "$sha_part" "${base_name}.sha256"; then
    rm -f "$sha_part"
    mm_die "R2_SHA256_DOWNLOAD=FAIL reason=html_body"
  fi
  mv -f "$sha_part" "$sha_final"

  # Optional signature sidecar download is best-effort and NOT part of the
  # authoritative R2 trust model. Production trust for R2 OS Core packages is:
  #   HTTPS transport + mandatory SHA256 sidecar verification
  # (see engine_verify_os_core_package / os_core_package.py). If an .asc is
  # present later, verification may be attempted only when a pinned trust root
  # exists; absence of .asc does not fail acquisition.
  local asc_url="${sha_url}.asc"
  local asc_final="${sha_final}.asc"
  mm_info "R2_TRUST_MODEL=HTTPS_SHA256 signature_sidecar=optional_unverified_unless_pinned_key"
  if curl -fsSL --connect-timeout 10 \
    -H "Cache-Control: no-cache" -H "Pragma: no-cache" \
    -o "${asc_final}.part" "$asc_url" 2>/dev/null; then
    if r2_reject_html_body "${asc_final}.part" 2>/dev/null; then
      mv -f "${asc_final}.part" "$asc_final"
      mm_info "R2_SIGNATURE_SIDECAR=DOWNLOADED note=not_authoritative_without_pinned_key"
    else
      rm -f "${asc_final}.part"
    fi
  else
    rm -f "${asc_final}.part"
    mm_info "R2_SIGNATURE_SIDECAR=ABSENT"
  fi

  OS_CORE_PACKAGE="$final"
  OS_CORE_PACKAGE_BYTES="$(mm_file_bytes "$final")"
  mm_state_set R2_OS_CORE_DOWNLOADED PASS
  mm_ok "R2_DOWNLOAD=PASS file=${base_name} size=${OS_CORE_PACKAGE_BYTES}"
}

r2_cleanup_package() {
  local pkg="${OS_CORE_PACKAGE:-}"
  [[ -n "$pkg" ]] || return 0
  rm -f "$pkg" "${pkg}.sha256" "${pkg}.sha256.asc" \
    "${pkg}.part" "${pkg}.part.download" "${pkg}.sha256.part" 2>/dev/null || true
  mm_info "R2_PACKAGE_CLEANUP=DONE"
}
