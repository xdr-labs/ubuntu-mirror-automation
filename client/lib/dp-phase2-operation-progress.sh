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
  local stop_file
  sanitized="$(dp2_progress_sanitize_target "$target")"
  stop_file="$(mktemp "${TMPDIR:-/tmp}/dp2-hb-stop.XXXXXX")"
  rm -f "$stop_file"
  start="$(dp2_progress_now)"
  printf 'OPERATION_START name=%s target=%s\n' "$name" "$sanitized"

  "$@" &
  child_pid=$!

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
