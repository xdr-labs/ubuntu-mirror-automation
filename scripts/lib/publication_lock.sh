#!/usr/bin/env bash
# Shared publication mutation lock.
# Production path: /run/ubuntu-mirror-publication.lock
# Non-root hermetic tests fall back to a writable temp file so unit tests
# do not require root to create /run.
# shellcheck shell=bash

if [[ -n "${PUBLICATION_LOCK_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
PUBLICATION_LOCK_LOADED=1

publication_lock_path() {
  local lock="${MM_LOCK_FILE:-${PUBLICATION_LOCK_FILE:-/run/ubuntu-mirror-publication.lock}}"
  local dir
  dir="$(dirname "$lock")"
  if mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
    printf '%s\n' "$lock"
    return 0
  fi
  # /run is root-owned. Hermetic tests must not share one machine-global
  # fallback: a child that inherits the lock FD (gpg-agent and similar) would
  # block every later test. Explicit MM_LOCK_FILE values that are writable are
  # returned above and still provide cross-process exclusion.
  if [[ "${MM_HERMETIC_TEST_MODE:-0}" == "1" ]]; then
    printf '%s\n' "${TMPDIR:-/tmp}/ubuntu-mirror-publication.$$.lock"
    return 0
  fi
  if [[ "${EUID}" -ne 0 ]]; then
    printf '%s\n' "${TMPDIR:-/tmp}/ubuntu-mirror-publication.lock"
    return 0
  fi
  printf '%s\n' "$lock"
}

# True when fd is an open handle on the publication lock file and this
# process already holds its exclusive flock. A bare environment boolean is
# not ownership.
_publication_lock_fd_holds_ours() {
  local fd="$1"
  local expected path
  [[ "$fd" =~ ^[0-9]+$ ]] || return 1
  [[ -e "/proc/self/fd/${fd}" ]] || return 1
  expected="$(publication_lock_path)"
  expected="$(readlink -f "$expected" 2>/dev/null || printf '%s' "$expected")"
  path="$(readlink -f "/proc/self/fd/${fd}" 2>/dev/null || true)"
  [[ -n "$path" && "$path" == "$expected" ]] || return 1
  flock -n "$fd"
}

publication_lock_acquire() {
  local lock new_fd inherited=""
  if [[ -n "${PUBLICATION_LOCK_FD:-}" ]] && _publication_lock_fd_holds_ours "$PUBLICATION_LOCK_FD"; then
    PUBLICATION_LOCK_HELD=1
    PUBLICATION_LOCK_PATH="$(readlink -f "/proc/self/fd/${PUBLICATION_LOCK_FD}" 2>/dev/null || true)"
    return 0
  fi
  inherited="${MM_PUBLICATION_LOCK_INHERITED_FD:-}"
  if [[ -n "$inherited" ]] && _publication_lock_fd_holds_ours "$inherited"; then
    PUBLICATION_LOCK_FD="$inherited"
    PUBLICATION_LOCK_HELD=1
    PUBLICATION_LOCK_PATH="$(readlink -f "/proc/self/fd/${PUBLICATION_LOCK_FD}" 2>/dev/null || true)"
    return 0
  fi
  lock="$(publication_lock_path)"
  mkdir -p "$(dirname "$lock")" || return 1
  exec {new_fd}>"$lock" || return 1
  if ! flock -n "$new_fd"; then
    eval "exec ${new_fd}>&-" 2>/dev/null || true
    printf 'PUBLICATION_LOCK=BUSY path=%s\n' "$lock" >&2
    return 1
  fi
  PUBLICATION_LOCK_FD="$new_fd"
  PUBLICATION_LOCK_HELD=1
  PUBLICATION_LOCK_PATH="$lock"
  return 0
}

publication_lock_release() {
  if [[ "${PUBLICATION_LOCK_HELD:-0}" == "1" && -n "${PUBLICATION_LOCK_FD:-}" ]]; then
    flock -u "$PUBLICATION_LOCK_FD" 2>/dev/null || true
    eval "exec ${PUBLICATION_LOCK_FD}>&-" 2>/dev/null || true
    PUBLICATION_LOCK_FD=""
    PUBLICATION_LOCK_HELD=0
  fi
}
