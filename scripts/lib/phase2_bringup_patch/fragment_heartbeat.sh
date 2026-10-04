# BEGIN_IMAGE_IMPORT_HEARTBEAT
# Observability helpers for long-running `ctr images import` (dark-site).
# Heartbeat never kills, times out, retries, or restarts containerd.
image_import_heartbeat_seconds() {
    local hb="${IMAGE_IMPORT_HEARTBEAT_SECONDS:-60}"
    if [[ "$hb" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' "$hb"
    else
        printf '60\n'
    fi
}

image_import_format_elapsed() {
    local total="${1:-0}"
    (( total < 0 )) && total=0
    printf '%02d:%02d:%02d' $((total / 3600)) $(((total % 3600) / 60)) $((total % 60))
}

# Best-effort read position percent for the import tar. Never fails the import.
image_import_progress_pct() {
    local pid="$1"
    local tar_file="$2"
    local tar_abs size pos fd_path link fd_num max_pos=""
    tar_abs="$(readlink -f "$tar_file" 2>/dev/null || true)"
    [[ -n "$tar_abs" && -f "$tar_abs" ]] || { printf 'UNKNOWN\n'; return 0; }
    size="$(stat -c '%s' "$tar_abs" 2>/dev/null || true)"
    [[ -n "$size" && "$size" -gt 0 ]] || { printf 'UNKNOWN\n'; return 0; }
    shopt -s nullglob
    for fd_path in /proc/"$pid"/fd/*; do
        link="$(readlink "$fd_path" 2>/dev/null || true)"
        [[ -n "$link" ]] || continue
        if [[ "$link" == "$tar_abs" || "$link" == "$tar_file" ]]; then
            fd_num="${fd_path##*/}"
            pos="$(awk '/^pos:/ {print $2; exit}' "/proc/${pid}/fdinfo/${fd_num}" 2>/dev/null || true)"
            if [[ -n "$pos" && "$pos" =~ ^[0-9]+$ ]]; then
                if [[ -z "$max_pos" || "$pos" -gt "$max_pos" ]]; then
                    max_pos="$pos"
                fi
            fi
        fi
    done
    shopt -u nullglob
    if [[ -n "$max_pos" ]]; then
        if (( max_pos >= size )); then
            printf '100\n'
        else
            printf '%s\n' "$(( (max_pos * 100) / size ))"
        fi
        return 0
    fi
    printf 'UNKNOWN\n'
    return 0
}

image_import_disk_free() {
    local path="$1"
    df -h "$path" 2>/dev/null | awk 'NR==2 {print $4; exit}'
}

image_import_emit_progress() {
    local ns="$1"
    local tar_file="$2"
    local import_pid="$3"
    local start_ts="$4"
    local base elapsed alive progress raw_progress disk_free cpu_pct img_count extras
    base="$(basename "$tar_file")"
    elapsed="$(image_import_format_elapsed $(( $(date +%s) - start_ts )))"
    alive=NO
    kill -0 "$import_pid" 2>/dev/null && alive=YES

    raw_progress="$(image_import_progress_pct "$import_pid" "$tar_file")"
    progress="$raw_progress"
    if [[ "$raw_progress" =~ ^[0-9]+$ ]]; then
        # The import process can momentarily expose multiple/reopened FDs for the
        # same tar. Report the highest observed read position for this import so
        # operator progress never moves backwards. Do not display 100% while the
        # process is still alive; completion is authoritative only after wait(1).
        if [[ -n "${last_progress_pct:-}" \
          && "${last_progress_pct}" =~ ^[0-9]+$ \
          && "$raw_progress" -lt "${last_progress_pct}" ]]; then
            raw_progress="${last_progress_pct}"
        fi
        if [[ "$alive" == "YES" && "$raw_progress" -ge 100 ]]; then
            raw_progress=99
        fi
        last_progress_pct="$raw_progress"
        progress="${raw_progress}%"
    fi

    disk_free="$(image_import_disk_free "$tar_file")"
    [[ -n "$disk_free" ]] || disk_free=UNKNOWN
    extras=""
    cpu_pct="$(ps -p "$import_pid" -o pcpu= 2>/dev/null | tr -d ' ' || true)"
    [[ -n "$cpu_pct" ]] && extras+=" cpu=${cpu_pct}%"
    # Best-effort only; never let a stuck/failing listing affect import.
    img_count="$(ctr -n="$ns" images ls -q 2>/dev/null | wc -l 2>/dev/null || true)"
    if [[ -n "$img_count" && "$img_count" =~ ^[0-9]+$ ]]; then
        extras+=" image_count=${img_count}"
    fi
    log "IMAGE_IMPORT_PROGRESS namespace=${ns} elapsed=${elapsed} pid=${import_pid} process_alive=${alive} file=${base} progress=${progress} disk_free=${disk_free}${extras}"
}

# Run one namespace import with 60s (configurable) heartbeats.
# Preserves ctr argv/options/stdout/stderr routing. Returns ctr exit code.
# usage: run_image_import_with_heartbeat <namespace> <tar_file> <log_file> [extra ctr args...]
run_image_import_with_heartbeat() {
    local ns="$1"
    local tar_file="$2"
    local log_file="$3"
    shift 3
    local -a extra_args=("$@")
    local hb_secs base size import_pid start_ts now next_hb import_rc elapsed poll_secs last_progress_pct=""
    hb_secs="$(image_import_heartbeat_seconds)"
    poll_secs=5
    # Keep poll short enough to honor small heartbeat intervals in tests.
    if (( hb_secs < poll_secs )); then
        poll_secs="$hb_secs"
    fi
    base="$(basename "$tar_file")"
    size="$(du -h "$tar_file" 2>/dev/null | awk '{print $1}')"
    [[ -n "$size" ]] || size=UNKNOWN
    start_ts="$(date +%s)"

    if [[ "$tar_file" == *.gz ]]; then
        # gunzip | ctr import - with stdout/stderr -> log_file.
        # Wrap in an explicit subshell + pipefail so wait(1) observes the
        # whole pipeline: a failing gunzip must not be masked when ctr
        # reads EOF and exits 0. Heartbeat watches this job pid.
        (
            set -o pipefail
            gunzip -c -- "$tar_file" |
                ctr -n="$ns" images import "${extra_args[@]}" -
        ) >"$log_file" 2>&1 &
        import_pid=$!
    else
        ctr -n="$ns" images import "${extra_args[@]}" "$tar_file" >"$log_file" 2>&1 &
        import_pid=$!
    fi

    log "IMAGE_IMPORT_START namespace=${ns} file=${base} size=${size} pid=${import_pid}"
    next_hb=$((start_ts + hb_secs))

    while kill -0 "$import_pid" 2>/dev/null; do
        now="$(date +%s)"
        if (( now >= next_hb )); then
            image_import_emit_progress "$ns" "$tar_file" "$import_pid" "$start_ts" || true
            next_hb=$((next_hb + hb_secs))
        fi
        sleep "$poll_secs" || true
    done

    import_rc=0
    if wait "$import_pid"; then
        import_rc=0
    else
        import_rc=$?
    fi

    elapsed="$(image_import_format_elapsed $(( $(date +%s) - start_ts )))"
    if [[ "$import_rc" -ne 0 ]]; then
        log "IMAGE_IMPORT_FAILED namespace=${ns} pid=${import_pid} rc=${import_rc} elapsed=${elapsed} file=${base}"
        return "$import_rc"
    fi
    log "IMAGE_IMPORT_COMPLETE namespace=${ns} elapsed=${elapsed}"
    return 0
}
# END_IMAGE_IMPORT_HEARTBEAT

