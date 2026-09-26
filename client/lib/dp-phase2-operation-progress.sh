#!/usr/bin/env bash
# Reusable long-operation progress / heartbeat for Phase 2 staging.
# shellcheck shell=bash
# Default interval 30s; override with DP_PHASE2_HEARTBEAT_SECONDS (tests use 1).
# Preserves exact child exit status; no orphan heartbeats; SIGINT/SIGTERM safe.

DP_PHASE2_HEARTBEAT_SECONDS="${DP_PHASE2_HEARTBEAT_SECONDS:-30}"

# Interruptible heartbeat delay: long `sleep N` cannot be relied on to exit
# promptly after SIGTERM on all Bash builds, which made short operations report
# elapsed_seconds≈N and timed out hermetic tests. Sleep 1s slices and re-check
# stop_file / child liveness between slices.
dp2_progress_interruptible_sleep() {
  local total="${1:-${DP_PHASE2_HEARTBEAT_SECONDS}}"
  local stop_file="${2:-}"
  local child_pid="${3:-}"
  local n=0
  [[ "$total" =~ ^[0-9]+$ ]] || total=1
  [[ "$total" -ge 1 ]] || total=1
  while [[ "$n" -lt "$total" ]]; do
    if [[ -n "$stop_file" && -f "$stop_file" ]]; then
      return 0
    fi
    if [[ -n "$child_pid" ]] && ! kill -0 "$child_pid" 2>/dev/null; then
      return 0
    fi
    sleep 1 || return 0
    n=$((n + 1))
  done
  return 0
}

dp2_hb_reap() {
  local hb_pid="${1:-}"
  local stop_file="${2:-}"
  local i
  [[ -n "$stop_file" ]] && : >"$stop_file" 2>/dev/null || true
  if [[ -n "$hb_pid" ]]; then
    kill "$hb_pid" 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$hb_pid" 2>/dev/null || break
      sleep 0.05 2>/dev/null || sleep 1
    done
    kill -9 "$hb_pid" 2>/dev/null || true
    wait "$hb_pid" 2>/dev/null || true
  fi
  [[ -n "$stop_file" ]] && rm -f "$stop_file"
}

dp2_progress_sanitize_target() {
  local t="${1-}"
  # Strip credentials and query parameters from URLs.
  t="$(printf '%s' "$t" | sed -E 's#://[^/@]+@#://#; s/\?.*$//')"
  # Bound length
  printf '%s' "${t:0:200}"
}

dp2_progress_now() {
  date -u +%s
}

# rchar for a live checksum process. Missing /proc (or a just-exited pid) is
# a fallback signal, not a checksum failure.
dp2_proc_rchar() {
  local pid="$1" root io val
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  root="${DP2_CHECKSUM_PROGRESS_IO_ROOT:-/proc}"
  io="${root}/${pid}/io"
  [[ -r "$io" ]] || return 1
  val="$(awk '/^rchar:/ {print $2; exit}' "$io" 2>/dev/null || true)"
  [[ "$val" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$val"
}

# True when pid has the checksum target open. Does not walk unrelated /proc.
dp2_pid_opens_target() {
  local pid="$1" target="$2" fd link
  [[ "$pid" =~ ^[0-9]+$ && -d "/proc/${pid}/fd" ]] || return 1
  target="$(readlink -f "$target" 2>/dev/null || printf '%s' "$target")"
  for fd in "/proc/${pid}/fd"/*; do
    link="$(readlink "$fd" 2>/dev/null || true)"
    [[ "$link" == "$target" ]] && return 0
  done
  return 1
}

dp2_walk_pids() {
  local pid="$1" child
  printf '%s\n' "$pid"
  while read -r child; do
    [[ "$child" =~ ^[0-9]+$ ]] || continue
    dp2_walk_pids "$child"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
}

# One payload reader. bash -c is not that reader: sha256sum is a descendant.
# Two openers (a pipeline reading the same file twice) stay on heartbeat.
# The chosen pid stays fixed for the rest of the sample loop. Call this in
# the current shell. A command substitution would drop DP2_CHECKSUM_READER_PID.
# Sets DP2_CHECKSUM_RCHAR_OUT on success.
dp2_authoritative_checksum_rchar() {
  local root_pid="$1" target="$2"
  local pid cmd openers=()
  DP2_CHECKSUM_RCHAR_OUT=""
  if [[ "${DP2_CHECKSUM_MULTI_READER:-0}" == "1" ]]; then
    return 1
  fi
  if [[ -n "${DP2_CHECKSUM_READER_PID:-}" ]]; then
    if kill -0 "$DP2_CHECKSUM_READER_PID" 2>/dev/null; then
      DP2_CHECKSUM_RCHAR_OUT="$(dp2_proc_rchar "$DP2_CHECKSUM_READER_PID")" || return 1
      return 0
    fi
    return 1
  fi
  while read -r pid; do
    if dp2_pid_opens_target "$pid" "$target"; then
      openers+=("$pid")
    fi
  done < <(dp2_walk_pids "$root_pid")
  if [[ "${#openers[@]}" -ge 2 ]]; then
    DP2_CHECKSUM_MULTI_READER=1
    return 1
  fi
  if [[ "${#openers[@]}" -eq 1 ]]; then
    DP2_CHECKSUM_READER_PID="${openers[0]}"
    DP2_CHECKSUM_RCHAR_OUT="$(dp2_proc_rchar "$DP2_CHECKSUM_READER_PID")" || return 1
    return 0
  fi
  cmd="$(tr '\0' ' ' < "/proc/${root_pid}/cmdline" 2>/dev/null || true)"
  if [[ "$cmd" == *" -c "* || "$cmd" == *"-c "* ]]; then
    return 1
  fi
  DP2_CHECKSUM_RCHAR_OUT="$(dp2_proc_rchar "$root_pid")" || return 1
  return 0
}

# Cap displayed percent below 100 until the checksum process has exited.
dp2_checksum_running_percent() {
  awk -v read="$1" -v total="$2" 'BEGIN {
    if (total+0 <= 0 || read+0 < 0) { print "UNKNOWN"; exit }
    p = (read * 100.0) / total
    if (p < 0) p = 0
    if (p >= 100) p = 99.9
    printf "%.1f", p
  }'
}

# Run command with periodic OPERATION_PROGRESS heartbeats.
# Usage: dp2_run_with_heartbeat <name> <target> <command...>
# Or:    dp2_run_with_heartbeat <name> <target> -- <command...>
dp2_run_with_heartbeat() {
  local name="$1"
  local target="$2"
  shift 2
  if [[ "${1-}" == "--" ]]; then
    shift
  fi
  local sanitized child_pid hb_pid start now elapsed rc=0
  local stop_file checksum_progress=0 total_bytes=0 read_base=""
  local read_now payload percent rate eta
  sanitized="$(dp2_progress_sanitize_target "$target")"
  case " $* " in
    *sha256sum*|*sha1sum*)
      if [[ -f "$target" ]]; then
        total_bytes="$(stat -c%s "$target" 2>/dev/null || echo 0)"
        if [[ "$total_bytes" =~ ^[0-9]+$ && "$total_bytes" -gt 0 ]]; then
          checksum_progress=1
        fi
      fi
      ;;
  esac
  stop_file="$(mktemp "${TMPDIR:-/tmp}/dp2-hb-stop.XXXXXX")"
  rm -f "$stop_file"
  start="$(dp2_progress_now)"
  printf 'OPERATION_START name=%s target=%s\n' "$name" "$sanitized"

  "$@" &
  child_pid=$!
  DP2_CHECKSUM_READER_PID=""
  DP2_CHECKSUM_MULTI_READER=0
  DP2_CHECKSUM_RCHAR_OUT=""
  read_base=""

  (
    trap 'exit 0' TERM INT
    while true; do
      if [[ -f "$stop_file" ]]; then
        exit 0
      fi
      if ! kill -0 "$child_pid" 2>/dev/null; then
        exit 0
      fi
      dp2_progress_interruptible_sleep "$DP_PHASE2_HEARTBEAT_SECONDS" "$stop_file" "$child_pid"
      if [[ -f "$stop_file" ]]; then
        exit 0
      fi
      if ! kill -0 "$child_pid" 2>/dev/null; then
        exit 0
      fi
      now="$(dp2_progress_now)"
      elapsed=$((now - start))
      if [[ "$checksum_progress" -eq 1 ]]; then
        read_now=""
        if dp2_authoritative_checksum_rchar "$child_pid" "$target"; then
          read_now="$DP2_CHECKSUM_RCHAR_OUT"
        fi
        if [[ "$read_now" =~ ^[0-9]+$ ]]; then
          if [[ -z "${read_base}" ]]; then
            read_base="$read_now"
          fi
          payload="$read_now"
          if [[ "${read_base:-0}" =~ ^[0-9]+$ && "$read_now" -ge "${read_base:-0}" ]]; then
            payload=$((read_now - read_base))
          fi
          percent="$(dp2_checksum_running_percent "$payload" "$total_bytes")"
          rate="UNKNOWN"
          eta="UNKNOWN"
          if [[ "$elapsed" -gt 0 && "$payload" -gt 0 ]]; then
            rate="$(awk -v read="$payload" -v elapsed="$elapsed" 'BEGIN { printf "%.1f", (read / elapsed) / (1024*1024) }')"
            if [[ "$payload" -lt "$total_bytes" ]]; then
              eta="$(awk -v read="$payload" -v total="$total_bytes" -v elapsed="$elapsed" 'BEGIN { printf "%d", (total - read) / (read / elapsed) }')"
            fi
          fi
          case "$percent" in
            100|100.0) percent="99.9" ;;
          esac
          printf 'OPERATION_PROGRESS name=%s elapsed_seconds=%s read_bytes=%s total_bytes=%s percent=%s rate_mib_s=%s eta_seconds=%s status=running\n' \
            "$name" "$elapsed" "$payload" "$total_bytes" "$percent" "$rate" "$eta"
          printf 'Progress : %s / %s bytes\nPercent  : %s%%\nElapsed  : %ss\nRate     : %s MiB/s\nETA      : %ss\nStatus   : Running normally\n' \
            "$payload" "$total_bytes" "$percent" "$elapsed" "$rate" "$eta"
          printf 'ETA is approximate and can vary on newly restored or AMI-backed EBS volumes.\n'
          continue
        fi
      fi
      printf 'OPERATION_PROGRESS name=%s elapsed_seconds=%s\n' "$name" "$elapsed"
    done
  ) &
  hb_pid=$!

  if wait "$child_pid"; then
    rc=0
  else
    rc=$?
  fi
  dp2_hb_reap "$hb_pid" "$stop_file"
  now="$(dp2_progress_now)"
  elapsed=$((now - start))
  printf 'OPERATION_END name=%s rc=%s elapsed_seconds=%s\n' "$name" "$rc" "$elapsed"
  return "$rc"
}

# File-size aware download progress. Does not fabricate Content-Length.
# Usage: dp2_run_download_with_progress <name> <mode> <dest_path> <bytes_total_or_UNKNOWN> <curl-args...>
# mode=FULL|RESUME
dp2_run_download_with_progress() {
  local name="$1"
  local mode="$2"
  local dest="$3"
  local bytes_total="$4"
  shift 4
  local child_pid hb_pid start now elapsed rc=0
  local stop_file last_bytes=0 unchanged=0 bytes_now avg eta percent
  local sanitized="download"
  stop_file="$(mktemp "${TMPDIR:-/tmp}/dp2-dl-stop.XXXXXX")"
  rm -f "$stop_file"
  start="$(dp2_progress_now)"
  if [[ -f "$dest" ]]; then
    last_bytes="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  else
    last_bytes=0
  fi
  printf 'OPERATION_START name=%s target=%s mode=%s bytes_total=%s\n' \
    "$name" "$sanitized" "$mode" "${bytes_total:-UNKNOWN}"

  "$@" &
  child_pid=$!

  (
    trap 'exit 0' TERM INT
    while true; do
      if [[ -f "$stop_file" ]]; then exit 0; fi
      if ! kill -0 "$child_pid" 2>/dev/null; then exit 0; fi
      dp2_progress_interruptible_sleep "$DP_PHASE2_HEARTBEAT_SECONDS" "$stop_file" "$child_pid"
      if [[ -f "$stop_file" ]]; then exit 0; fi
      if ! kill -0 "$child_pid" 2>/dev/null; then exit 0; fi
      now="$(dp2_progress_now)"
      elapsed=$((now - start))
      [[ "$elapsed" -lt 1 ]] && elapsed=1
      bytes_now=0
      if [[ -f "$dest" ]]; then
        bytes_now="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
      fi
      if [[ "$bytes_now" -eq "$last_bytes" ]]; then
        unchanged=$((unchanged + DP_PHASE2_HEARTBEAT_SECONDS))
      else
        unchanged=0
        last_bytes="$bytes_now"
      fi
      avg=$((bytes_now / elapsed))
      if [[ "$bytes_total" =~ ^[0-9]+$ && "$bytes_total" -gt 0 && "$avg" -gt 0 ]]; then
        percent=$((bytes_now * 100 / bytes_total))
        eta=$(( (bytes_total - bytes_now) / avg ))
      else
        percent="UNKNOWN"
        eta="UNKNOWN"
        bytes_total="${bytes_total:-UNKNOWN}"
      fi
      printf 'OPERATION_PROGRESS name=%s elapsed_seconds=%s bytes_downloaded=%s bytes_total=%s percent=%s average_bytes_per_second=%s eta_seconds=%s mode=%s unchanged_seconds=%s\n' \
        "$name" "$elapsed" "$bytes_now" "$bytes_total" "$percent" "$avg" "$eta" "$mode" "$unchanged"
      if [[ "$unchanged" -ge $((DP_PHASE2_HEARTBEAT_SECONDS * 3)) ]]; then
        printf 'DOWNLOAD_NO_PROGRESS_WARNING=YES\n'
      fi
    done
  ) &
  hb_pid=$!

  if wait "$child_pid"; then
    rc=0
  else
    rc=$?
  fi
  dp2_hb_reap "$hb_pid" "$stop_file"

  now="$(dp2_progress_now)"
  elapsed=$((now - start))
  [[ "$elapsed" -lt 1 ]] && elapsed=1
  bytes_now=0
  if [[ -f "$dest" ]]; then
    bytes_now="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  fi
  avg=$((bytes_now / elapsed))
  printf 'OPERATION_END name=%s rc=%s elapsed_seconds=%s\n' "$name" "$rc" "$elapsed"
  if [[ "$rc" -eq 0 ]]; then
    printf 'DOWNLOAD_RESULT=PASS\n'
  else
    printf 'DOWNLOAD_RESULT=FAIL\n'
  fi
  printf 'DOWNLOAD_MODE=%s\n' "$mode"
  printf 'DOWNLOAD_BYTES=%s\n' "$bytes_now"
  printf 'DOWNLOAD_ELAPSED_SECONDS=%s\n' "$elapsed"
  printf 'DOWNLOAD_AVERAGE_BYTES_PER_SECOND=%s\n' "$avg"
  return "$rc"
}

# Ensure the complete Phase 2 client helper unit is present before starting the
# expensive extraction. Current Menu 7 downloads the full unit up front; this
# preflight remains for standalone execution that is missing a subset.
# Trust boundary: every helper must match the generation manifest. bash -n is
# never sufficient integrity validation. A HTTP .sha256 sidecar is not the
# trust anchor — the local generation manifest (pinned by Menu 7) is.
dp2_prepare_bringup_controller_dependencies() {
  local lib_dir="${_STAGE_LIB_DIR:-}"
  local mirror="${MIRROR_URL:-}"
  local stage_dir rel dest tmp url action expected actual man
  local man_name="${PHASE2_HELPER_GENERATION_MANIFEST_NAME:-phase2-helper-generation.manifest}"

  # Outside the Phase 2 stage script these globals are intentionally absent.
  [[ -n "$lib_dir" && -n "$mirror" ]] || return 0
  stage_dir="$(dirname "$lib_dir")"
  man="${stage_dir}/${man_name}"
  if [[ ! -s "$man" ]]; then
    printf 'PHASE2_CONTROLLER_DEPENDENCY=FAIL path=%s reason=manifest_missing\n' \
      "$man_name" >&2
    return 1
  fi

  # Authoritative unit = every path listed in the generation manifest except the
  # stage entrypoint itself (already executing). Do not hardcode a stale subset.
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    [[ "$rel" == "stage-dp-phase2.sh" ]] && continue
    dest="${stage_dir}/${rel}"
    expected="$(awk -v p="$rel" '$2 == p {print $1; exit}' "$man")"
    if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
      printf 'PHASE2_CONTROLLER_DEPENDENCY=FAIL path=%s reason=unlisted\n' "$rel" >&2
      return 1
    fi
    if [[ -s "$dest" ]]; then
      actual="$(sha256sum "$dest" | awk '{print $1}')"
      if [[ "${actual,,}" == "${expected,,}" ]]; then
        printf 'PHASE2_CONTROLLER_DEPENDENCY=REUSED path=%s\n' "$rel"
        continue
      fi
      printf 'PHASE2_CONTROLLER_DEPENDENCY=FAIL path=%s reason=hash_mismatch\n' "$rel" >&2
      return 1
    fi

    mkdir -p "$(dirname "$dest")"
    tmp="$(mktemp "$(dirname "$dest")/.dp2-controller.XXXXXX")"
    url="${mirror%/}/client/${rel}"
    action="DOWNLOAD"
    if ! curl -fsSL --connect-timeout 30 --retry 3 --retry-delay 2 \
        -o "$tmp" "$url"
    then
      rm -f "$tmp"
      printf 'PHASE2_CONTROLLER_DEPENDENCY=FAIL path=%s reason=download_failed url=%s\n' \
        "$rel" "$(dp2_progress_sanitize_target "$url")" >&2
      return 1
    fi
    actual="$(sha256sum "$tmp" | awk '{print $1}')"
    if [[ "${actual,,}" != "${expected,,}" ]]; then
      rm -f "$tmp"
      printf 'PHASE2_CONTROLLER_DEPENDENCY=FAIL path=%s reason=hash_mismatch\n' "$rel" >&2
      return 1
    fi
    chmod 0755 "$tmp"
    mv -f "$tmp" "$dest"
    printf 'PHASE2_CONTROLLER_DEPENDENCY=%s path=%s\n' "$action" "$rel"
  done < <(awk 'NF >= 2 {print $2}' "$man")
  printf 'PHASE2_CONTROLLER_DEPENDENCIES=PASS\n'
  return 0
}

# Extraction progress: report extracted bytes + file count under a directory.
# Usage: dp2_run_extract_with_progress <name> <dest_dir> <command...>
# Or:    dp2_run_extract_with_progress <name> <dest_dir> -- <command...>
dp2_run_extract_with_progress() {
  local name="$1"
  local dest_dir="$2"
  shift 2
  # Keep the same optional command separator contract as
  # dp2_run_with_heartbeat(). Without this, the literal `--` becomes argv[0]
  # and Bash exits immediately with `--: command not found` before extraction.
  if [[ "${1-}" == "--" ]]; then
    shift
  fi
  if [[ "$#" -eq 0 ]]; then
    printf 'OPERATION_START name=%s target=%s\n' "$name" "$(dp2_progress_sanitize_target "$dest_dir")"
    printf 'OPERATION_END name=%s rc=2 elapsed_seconds=0\n' "$name"
    return 2
  fi

  if [[ "$name" == "phase2_tar_extract" ]]; then
    if ! dp2_prepare_bringup_controller_dependencies; then
      printf 'OPERATION_START name=%s target=%s\n' "$name" "$(dp2_progress_sanitize_target "$dest_dir")"
      printf 'OPERATION_END name=%s rc=1 elapsed_seconds=0\n' "$name"
      return 1
    fi
  fi

  local child_pid hb_pid start now elapsed rc=0 stop_file
  local extracted_bytes extracted_files
  stop_file="$(mktemp "${TMPDIR:-/tmp}/dp2-ex-stop.XXXXXX")"
  rm -f "$stop_file"
  start="$(dp2_progress_now)"
  printf 'OPERATION_START name=%s target=%s\n' "$name" "$(dp2_progress_sanitize_target "$dest_dir")"

  "$@" &
  child_pid=$!
  (
    trap 'exit 0' TERM INT
    while true; do
      if [[ -f "$stop_file" ]]; then exit 0; fi
      if ! kill -0 "$child_pid" 2>/dev/null; then exit 0; fi
      dp2_progress_interruptible_sleep "$DP_PHASE2_HEARTBEAT_SECONDS" "$stop_file" "$child_pid"
      if [[ -f "$stop_file" ]]; then exit 0; fi
      if ! kill -0 "$child_pid" 2>/dev/null; then exit 0; fi
      now="$(dp2_progress_now)"
      elapsed=$((now - start))
      extracted_bytes=0
      extracted_files=0
      if [[ -d "$dest_dir" ]]; then
        extracted_bytes="$(du -sb "$dest_dir" 2>/dev/null | awk '{print $1}')"
        extracted_files="$(find "$dest_dir" -type f 2>/dev/null | wc -l | tr -d ' ')"
      fi
      printf 'OPERATION_PROGRESS name=%s elapsed_seconds=%s extracted_bytes=%s extracted_file_count=%s\n' \
        "$name" "$elapsed" "${extracted_bytes:-0}" "${extracted_files:-0}"
    done
  ) &
  hb_pid=$!

  if wait "$child_pid"; then
    rc=0
  else
    rc=$?
  fi
  dp2_hb_reap "$hb_pid" "$stop_file"
  now="$(dp2_progress_now)"
  elapsed=$((now - start))
  printf 'OPERATION_END name=%s rc=%s elapsed_seconds=%s\n' "$name" "$rc" "$elapsed"
  return "$rc"
}
