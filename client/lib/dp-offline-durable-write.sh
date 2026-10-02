# Shared durable atomic write helpers for offline OS-upgrade clients.
# shellcheck shell=bash
# Injected at build time via the DURABLE_WRITE_HELPER template token.
# Prefer targeted file+directory fsync over unbounded global `sync`.
# Bash 4.3+/4.4 safe; requires python3 (standard on Bionic+ upgrade hosts).

DURABLE_WRITE_LOG_THRESHOLD_MS="${DURABLE_WRITE_LOG_THRESHOLD_MS:-500}"

# Return 0 when dpkg audit is unsafe (issues present OR the audit command itself
# failed); return 1 only for a successful, empty audit. Do not pipe into grep -q:
# with pipefail, an early grep exit can SIGPIPE dpkg and turn dirty state into a
# false negative.
dpkg_audit_has_issues() {
  local tmp rc=0 errexit_was_on=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/dpkg-audit.XXXXXX" 2>/dev/null)" || return 0
  case $- in *e*) errexit_was_on=1 ;; esac
  set +e
  dpkg --audit >"$tmp" 2>&1
  rc=$?
  if [[ "$errexit_was_on" -eq 1 ]]; then
    set -e
  else
    set +e
  fi
  if [[ "$rc" -ne 0 || -s "$tmp" ]]; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

_durable_now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0
}

_durable_write_python() {
  # stdin → durable atomic replace at path. Args: path mode_or_empty preserve_owner(0|1)
  local dest="$1"
  local mode="${2:-}"
  local preserve_owner="${3:-1}"
  local content_file
  content_file="$(mktemp "${TMPDIR:-/tmp}/durable-content.XXXXXX")"
  cat >"$content_file"
  python3 - "$dest" "$mode" "$preserve_owner" "$content_file" <<'PY'
import errno
import os
import stat
import sys
import tempfile

dest = sys.argv[1]
mode_arg = sys.argv[2]
preserve_owner = sys.argv[3] == "1"
with open(sys.argv[4], "rb") as fh:
    data = fh.read()

parent = os.path.dirname(os.path.abspath(dest)) or "."
base = os.path.basename(dest)
os.makedirs(parent, mode=0o755, exist_ok=True)

existed = False
old_mode = None
old_uid = None
old_gid = None
if os.path.lexists(dest):
    if os.path.islink(dest):
        sys.stderr.write("DURABLE_WRITE_ERR=dest_is_symlink\n")
        sys.exit(2)
    st = os.lstat(dest)
    if not stat.S_ISREG(st.st_mode):
        sys.stderr.write("DURABLE_WRITE_ERR=dest_not_regular\n")
        sys.exit(2)
    existed = True
    old_mode = stat.S_IMODE(st.st_mode)
    old_uid = st.st_uid
    old_gid = st.st_gid

if mode_arg:
    mode = int(mode_arg, 8)
elif existed and old_mode is not None:
    mode = old_mode
else:
    mode = 0o644

fd = None
tmp_path = None
try:
    fd, tmp_path = tempfile.mkstemp(
        prefix="." + base + ".",
        suffix=".tmp",
        dir=parent,
    )
    written = 0
    view = memoryview(data)
    while written < len(data):
        n = os.write(fd, view[written:])
        if n <= 0:
            raise OSError(errno.EIO, "short write")
        written += n
    os.fsync(fd)
    os.fchmod(fd, mode)
    if preserve_owner and existed and old_uid is not None:
        try:
            os.fchown(fd, old_uid, old_gid)
        except OSError:
            pass
    os.close(fd)
    fd = None
    os.replace(tmp_path, dest)
    tmp_path = None
    dirfd = os.open(parent, os.O_RDONLY)
    try:
        os.fsync(dirfd)
    finally:
        os.close(dirfd)
except Exception as exc:
    if fd is not None:
        try:
            os.close(fd)
        except OSError:
            pass
    if tmp_path and os.path.lexists(tmp_path):
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
    sys.stderr.write("DURABLE_WRITE_ERR=%s\n" % (exc,))
    sys.exit(1)
sys.exit(0)
PY
  local py_rc=$?
  rm -f "$content_file"
  return "$py_rc"
}

durable_fsync_path() {
  # Targeted fsync of an existing regular file and its parent directory.
  # Never falls back to unbounded global sync.
  local path="$1"
  python3 - "$path" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
if not os.path.lexists(path):
    sys.exit(1)
if os.path.islink(path):
    sys.exit(2)
st = os.lstat(path)
parent = os.path.dirname(os.path.abspath(path)) or "."
if stat.S_ISREG(st.st_mode):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
elif stat.S_ISDIR(st.st_mode):
    parent = path
else:
    sys.exit(2)
dirfd = os.open(parent, os.O_RDONLY)
try:
    os.fsync(dirfd)
finally:
    os.close(dirfd)
sys.exit(0)
PY
}

durable_atomic_write() {
  # durable_atomic_write <logical-name> <path> [mode]
  # Content from stdin. Optional mode octal (0600). Preserves owner when file exists.
  local logical="$1"
  local path="$2"
  local mode="${3:-}"
  local start_ms end_ms dur rc=0
  local errf

  if ! command -v python3 >/dev/null 2>&1; then
    if declare -F log >/dev/null 2>&1; then
      log ERROR "DURABLE_WRITE_BEGIN=${logical}"
      log ERROR "DURABLE_WRITE_PATH=${path}"
      log ERROR "DURABLE_WRITE_RESULT=FAIL"
      log ERROR "DURABLE_WRITE_DURATION_MS=0"
      log ERROR "DURABLE_WRITE_ERR=python3_missing"
    fi
    return 1
  fi

  start_ms="$(_durable_now_ms)"
  errf="$(mktemp "${TMPDIR:-/tmp}/durable-write.XXXXXX")"
  set +e
  _durable_write_python "$path" "$mode" 1 2>"$errf"
  rc=$?
  set -e
  end_ms="$(_durable_now_ms)"
  dur=$((end_ms - start_ms))
  if [[ "$dur" -lt 0 ]]; then
    dur=0
  fi

  if [[ "$rc" -ne 0 ]]; then
    if declare -F log >/dev/null 2>&1; then
      log ERROR "DURABLE_WRITE_BEGIN=${logical}"
      log ERROR "DURABLE_WRITE_PATH=${path}"
      log ERROR "DURABLE_WRITE_RESULT=FAIL"
      log ERROR "DURABLE_WRITE_DURATION_MS=${dur}"
      if [[ -s "$errf" ]]; then
        log ERROR "DURABLE_WRITE_ERR=$(tr '\n' ' ' <"$errf" | head -c 200)"
      fi
    fi
    rm -f "$errf"
    return 1
  fi

  if [[ "$dur" -ge "${DURABLE_WRITE_LOG_THRESHOLD_MS}" ]] && declare -F log >/dev/null 2>&1; then
    log INFO "DURABLE_WRITE_BEGIN=${logical}"
    log INFO "DURABLE_WRITE_PATH=${path}"
    log INFO "DURABLE_WRITE_RESULT=PASS"
    log INFO "DURABLE_WRITE_DURATION_MS=${dur}"
  fi
  rm -f "$errf"
  return 0
}

durable_atomic_write_string() {
  local logical="$1" path="$2" content="$3" mode="${4:-}"
  printf '%s' "$content" | durable_atomic_write "$logical" "$path" "$mode"
}

# Drop-in replacement for prior temp+rename helper (now durable).
atomic_write_file() {
  local dest="$1"
  durable_atomic_write "atomic_write_file" "$dest" || return 1
}
