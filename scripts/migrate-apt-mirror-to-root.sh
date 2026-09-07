#!/usr/bin/env bash
# migrate-apt-mirror-to-root.sh — Migrate /var/spool/apt-mirror from data disk to root FS
#
# Service paths stay at /var/spool/apt-mirror. Staging uses sibling
# /var/spool/apt-mirror.root-stage on the root filesystem.
#
# IMPORTANT: Default invocation prints usage and mutates nothing.
# Mutation modes require --execute (and cutover confirmation).
# This script never reboots, shuts down, or performs ESXi detach.
#
# shellcheck disable=SC2015,SC2034
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Defaults (overridable for fixtures via MIGRATE_* env)
# ---------------------------------------------------------------------------
EXPECTED_DISK="${MIGRATE_EXPECTED_DISK:-/dev/sdb}"
EXPECTED_PART="${MIGRATE_EXPECTED_PART:-/dev/sdb1}"
EXPECTED_UUID="${MIGRATE_EXPECTED_UUID:-d48ae479-10f5-4ff5-b9be-4baa34dd15ea}"
SOURCE_MOUNT="${MIGRATE_SOURCE_MOUNT:-/var/spool/apt-mirror}"
STAGE_PATH="${MIGRATE_STAGE_PATH:-/var/spool/apt-mirror.root-stage}"
FSTAB_PATH="${MIGRATE_FSTAB_PATH:-/etc/fstab}"
EFFECTIVE_MIRROR_CONF="${MIGRATE_EFFECTIVE_MIRROR_CONF:-/etc/ubuntu-mirror/mirror.conf}"
EFFECTIVE_DEFAULTS="${MIGRATE_EFFECTIVE_DEFAULTS:-/etc/default/ubuntu-offline-mirror}"
NGINX_SITE="${MIGRATE_NGINX_SITE:-/etc/nginx/sites-enabled/apt-mirror}"
EVIDENCE_ROOT="${MIGRATE_EVIDENCE_ROOT:-/var/backups/ubuntu-mirror/migrate-to-root}"
HTTP_BASE="${MIGRATE_HTTP_BASE:-http://127.0.0.1}"
PRIVATE_KEY_REL="selective/keys/ubuntu-mirror-selective.private.gpg"
PUBLIC_KEY_REL="selective/keys/ubuntu-mirror-selective.gpg"

MODE=""
EXECUTE=0
CONFIRM_TEXT="${MIGRATE_CONFIRM_CUTOVER:-}"
TEST_MODE="${MIGRATE_TEST_MODE:-0}"
SKIP_GIT="${MIGRATE_SKIP_GIT:-0}"
SKIP_HTTP="${MIGRATE_SKIP_HTTP:-0}"
SKIP_NGINX_T="${MIGRATE_SKIP_NGINX_T:-0}"
ROOT_AVAIL_OVERRIDE="${MIGRATE_ROOT_AVAIL_BYTES:-}"
LOG_FILE="${MIGRATE_LOG_FILE:-}"
EVIDENCE_DIR="${MIGRATE_EVIDENCE_DIR:-}"
FAKE_MOUNT_TABLE="${MIGRATE_FAKE_MOUNT_TABLE:-}"

# Never enable shell xtrace (private key safety).
set +x

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log() {
  local level="$1"; shift
  local msg
  msg="$(printf '%s' "$*" | sed -E 's/(-----BEGIN[^-]*PRIVATE[^-]*-----).*/\1<REDACTED>/g')"
  printf '%s [%s] %s\n' "$(ts)" "$level" "$msg" >&2
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s [%s] %s\n' "$(ts)" "$level" "$msg" >>"$LOG_FILE"
  fi
}
info() { log INFO "$*"; }
warn() { log WARN "$*"; }
error() { log ERROR "$*"; }
die() { error "$*"; exit 1; }
# Catchable failure for cutover steps (does not exit).
fail_rc() { error "$*"; return 1; }
ok() { log OK "$*"; }

usage() {
  cat <<'EOF'
Usage: migrate-apt-mirror-to-root.sh <mode> [options]

Modes (read-only unless noted):
  --preflight              Validate migration readiness (read-only)
  --initial-copy --execute Online rsync to /var/spool/apt-mirror.root-stage
  --cutover --execute      Maintenance cutover (requires confirmation)
  --verify                 Compare source/stage or live root spool (read-only)
  --post-reboot-verify     After operator reboot (read-only)
  --rollback --execute     Restore disk mount from cutover evidence
  --help                   Show this help

Mutation modes refuse to run without --execute.
Cutover additionally requires typing: CUTOVER_TO_ROOT

This script does NOT reboot, shut down, or detach ESXi disks.

Environment overrides (tests/fixtures):
  MIGRATE_TEST_MODE=1  MIGRATE_SOURCE_MOUNT  MIGRATE_STAGE_PATH
  MIGRATE_EXPECTED_DISK/PART/UUID  MIGRATE_FSTAB_PATH
  MIGRATE_EFFECTIVE_MIRROR_CONF  MIGRATE_EFFECTIVE_DEFAULTS
  MIGRATE_FAKE_MOUNT_TABLE  MIGRATE_SKIP_GIT  MIGRATE_SKIP_HTTP
  MIGRATE_CONFIRM_CUTOVER=CUTOVER_TO_ROOT  MIGRATE_ROOT_AVAIL_BYTES
  MIGRATE_FAKE_SS_FILE  MIGRATE_FAKE_SS_RC (fixture ss established lines)
  MIGRATE_TEST_NGINX_T_FAIL_ON_CALL=N (fail nginx_test on the Nth TEST_MODE call)
EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "COMMAND_UNAVAILABLE=$1"
}

canonical_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$p"
  else
    readlink -f "$p" 2>/dev/null || printf '%s\n' "$p"
  fi
}

is_forbidden_action_request() {
  # Guard against accidental invocation patterns; script never calls these.
  return 1
}

assert_no_destructive_flags() {
  local a
  for a in "$@"; do
    case "$a" in
      --reboot|--shutdown|--poweroff|--esxi*|--detach*)
        die "Forbidden flag refused: $a"
        ;;
    esac
  done
}

# findmnt wrapper (supports fake table for tests)
findmnt_field() {
  # usage: findmnt_field SOURCE|TARGET|FSTYPE path
  local field="$1" path="$2"
  if [[ -n "$FAKE_MOUNT_TABLE" && -f "$FAKE_MOUNT_TABLE" ]]; then
    # table lines: TARGET SOURCE FSTYPE
    local best_target="" best_source="" best_fstype="" t s f
    while read -r t s f; do
      [[ -z "${t:-}" || "$t" =~ ^# ]] && continue
      if [[ "$path" == "$t" || "$path" == "$t"/* ]]; then
        if [[ ${#t} -ge ${#best_target} ]]; then
          best_target="$t"
          best_source="$s"
          best_fstype="$f"
        fi
      fi
    done <"$FAKE_MOUNT_TABLE"
    case "$field" in
      SOURCE) printf '%s\n' "${best_source:-}" ;;
      TARGET) printf '%s\n' "${best_target:-}" ;;
      FSTYPE) printf '%s\n' "${best_fstype:-}" ;;
      *) printf '\n' ;;
    esac
    return 0
  fi
  findmnt -n -o "$field" --target "$path" 2>/dev/null || true
}

path_source() { findmnt_field SOURCE "$1"; }
path_target() { findmnt_field TARGET "$1"; }
path_fstype() { findmnt_field FSTYPE "$1"; }

fs_devno() {
  local p="$1"
  if [[ -n "${MIGRATE_TEST_DEVNO_MAP:-}" && -f "${MIGRATE_TEST_DEVNO_MAP}" ]]; then
    local line
    line="$(awk -v p="$p" '$1==p {print $2; exit}' "$MIGRATE_TEST_DEVNO_MAP" 2>/dev/null || true)"
    if [[ -n "$line" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
    # Longest path-prefix match with a directory boundary so that
    # /var/spool/apt-mirror does NOT match /var/spool/apt-mirror.root-stage.
    line="$(awk -v p="$p" '
      BEGIN { l = -1 }
      {
        pre=$1
        if (p==pre || (index(p, pre)==1 && substr(p, length(pre)+1, 1)=="/")) {
          if (length(pre) > l) { l=length(pre); d=$2 }
        }
      }
      END { if (l >= 0) print d }
    ' "$MIGRATE_TEST_DEVNO_MAP")"
    if [[ -n "$line" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  fi
  # In test mode never fall back to real device ids (fixture trees share one FS).
  if [[ "${MIGRATE_TEST_MODE:-0}" == "1" ]]; then
    printf '0\n'
    return 0
  fi
  stat -c '%d' "$p" 2>/dev/null || echo 0
}

blkid_uuid() {
  local dev="$1"
  if [[ -n "${MIGRATE_TEST_UUID_MAP:-}" && -f "${MIGRATE_TEST_UUID_MAP}" ]]; then
    awk -v d="$dev" '$1==d {print $2; exit}' "$MIGRATE_TEST_UUID_MAP"
    return 0
  fi
  if command -v blkid >/dev/null 2>&1; then
    blkid -s UUID -o value "$dev" 2>/dev/null || true
  elif [[ -e "/dev/disk/by-uuid/${EXPECTED_UUID}" ]]; then
    local link
    link="$(readlink -f "/dev/disk/by-uuid/${EXPECTED_UUID}" 2>/dev/null || true)"
    if [[ "$link" == "$(readlink -f "$dev" 2>/dev/null || echo "$dev")" ]]; then
      printf '%s\n' "$EXPECTED_UUID"
    fi
  fi
}

device_exists() {
  local d="$1"
  if [[ "$TEST_MODE" == "1" ]]; then
    [[ -n "${MIGRATE_TEST_UUID_MAP:-}" && -f "${MIGRATE_TEST_UUID_MAP}" ]] && \
      awk -v d="$d" '$1==d {found=1} END{exit !found}' "$MIGRATE_TEST_UUID_MAP"
    return $?
  fi
  [[ -b "$d" || -e "$d" ]]
}

root_avail_bytes() {
  if [[ -n "$ROOT_AVAIL_OVERRIDE" ]]; then
    printf '%s\n' "$ROOT_AVAIL_OVERRIDE"
    return 0
  fi
  df -B1 --output=avail / | awk 'NR==2 {print $1}'
}

path_used_bytes() {
  local p="$1" out
  # du may return non-zero when unreadable dirs exist (e.g. keys/gnupg); keep best effort.
  out="$(du -x -s -B1 "$p" 2>/dev/null | awk '{print $1}' || true)"
  printf '%s\n' "${out:-0}"
  return 0
}

path_apparent_bytes() {
  local p="$1" out
  out="$(du -x -s -B1 --apparent-size "$p" 2>/dev/null | awk '{print $1}' || true)"
  printf '%s\n' "${out:-0}"
  return 0
}

ensure_evidence_dir() {
  if [[ -z "$EVIDENCE_DIR" ]]; then
    EVIDENCE_DIR="${EVIDENCE_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi
  mkdir -p "$EVIDENCE_DIR"
  if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="${EVIDENCE_DIR}/migrate.log"
  fi
  printf '%s\n' "$EVIDENCE_DIR"
}

save_text() {
  local dest="$1"
  shift
  printf '%s\n' "$@" >"$dest"
}

# ---------------------------------------------------------------------------
# Git guards
# ---------------------------------------------------------------------------
git_repo_ok() {
  [[ -d "${REPO_ROOT}/.git" ]] || die "Not a git repository: $REPO_ROOT"
  [[ -f "${REPO_ROOT}/scripts/migrate-apt-mirror-to-root.sh" ]] || \
    die "Unexpected repository layout at $REPO_ROOT"
}

git_is_clean() {
  git -C "$REPO_ROOT" status --porcelain 2>/dev/null | grep -q . && return 1
  return 0
}

git_head_matches_origin_main() {
  local head origin
  head="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
  origin="$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || true)"
  [[ -n "$head" && -n "$origin" && "$head" == "$origin" ]]
}

# ---------------------------------------------------------------------------
# Structure / key metadata (never print key material)
# ---------------------------------------------------------------------------
private_key_path() {
  printf '%s/%s\n' "$1" "$PRIVATE_KEY_REL"
}

key_metadata_line() {
  # KEYMETA path=... type=... size=... mode=... uid=... gid=...
  local p="$1"
  if [[ ! -e "$p" ]]; then
    printf 'KEYMETA path=%s EXISTS=NO\n' "$p"
    return 1
  fi
  local typ size mode uid gid
  typ="$(stat -c '%F' "$p")"
  size="$(stat -c '%s' "$p")"
  mode="$(stat -c '%a' "$p")"
  uid="$(stat -c '%u' "$p")"
  gid="$(stat -c '%g' "$p")"
  printf 'KEYMETA path=%s EXISTS=YES type=%s size=%s mode=%s uid=%s gid=%s\n' \
    "$p" "$typ" "$size" "$mode" "$uid" "$gid"
}

compare_key_metadata() {
  local src="$1" dst="$2"
  local s_size s_mode s_uid s_gid d_size d_mode d_uid d_gid
  [[ -f "$src" ]] || die "Private key missing at source"
  [[ -f "$dst" ]] || die "Private key missing at destination"
  s_size="$(stat -c '%s' "$src")"; d_size="$(stat -c '%s' "$dst")"
  s_mode="$(stat -c '%a' "$src")"; d_mode="$(stat -c '%a' "$dst")"
  s_uid="$(stat -c '%u' "$src")"; d_uid="$(stat -c '%u' "$dst")"
  s_gid="$(stat -c '%g' "$src")"; d_gid="$(stat -c '%g' "$dst")"
  [[ "$s_size" == "$d_size" ]] || die "Private key size mismatch"
  [[ "$s_mode" == "$d_mode" ]] || die "Private key mode mismatch"
  [[ "$s_uid" == "$d_uid" && "$s_gid" == "$d_gid" ]] || die "Private key ownership mismatch"
  ok "PRIVATE_KEY_METADATA_MATCH=YES size=${s_size} mode=${s_mode}"
}

symlink_target() {
  readlink "$1" 2>/dev/null || true
}

assert_selective_symlinks() {
  local root="$1"
  local cur act
  [[ -L "${root}/selective/current" ]] || die "selective/current missing or not symlink under $root"
  [[ -L "${root}/selective/active" ]] || die "selective/active missing or not symlink under $root"
  cur="$(symlink_target "${root}/selective/current")"
  act="$(symlink_target "${root}/selective/active")"
  [[ "$cur" == "published" || "$cur" == "published/" ]] || die "selective/current invalid target: $cur"
  [[ "$act" == "published" || "$act" == "published/" ]] || die "selective/active invalid target: $act"
  [[ -d "${root}/selective/published" ]] || die "selective/published missing"
  ok "SELECTIVE_SYMLINKS=PASS current=${cur} active=${act}"
}

# ---------------------------------------------------------------------------
# Inventory / verify
# ---------------------------------------------------------------------------
inventory_tree() {
  # Write inventory summary to stdout; paths may contain spaces/unicode.
  local root="$1"
  local tmp
  tmp="$(mktemp)"
  # Exclude gnupg internals from content scans but count the directory.
  find "$root" -xdev \( -type f -o -type d -o -type l \) -print0 2>/dev/null \
    | sort -z \
    | while IFS= read -r -d '' p; do
        local rel typ links size mode uid gid
        rel="${p#"$root"/}"
        [[ "$p" == "$root" ]] && rel="."
        if [[ -L "$p" ]]; then
          typ=l
          links=1
          size=0
        elif [[ -d "$p" ]]; then
          typ=d
          links="$(stat -c '%h' "$p")"
          size=0
        else
          typ=f
          links="$(stat -c '%h' "$p")"
          size="$(stat -c '%s' "$p")"
        fi
        mode="$(stat -c '%a' "$p" 2>/dev/null || echo 0)"
        uid="$(stat -c '%u' "$p" 2>/dev/null || echo 0)"
        gid="$(stat -c '%g' "$p" 2>/dev/null || echo 0)"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$typ" "$links" "$size" "$mode" "$uid" "$gid" "$rel"
      done >"$tmp"

  local files dirs links hardlinked logical
  files="$(awk -F'\t' '$1=="f"' "$tmp" | wc -l)"
  dirs="$(awk -F'\t' '$1=="d"' "$tmp" | wc -l)"
  links="$(awk -F'\t' '$1=="l"' "$tmp" | wc -l)"
  hardlinked="$(awk -F'\t' '$1=="f" && $2+0>1' "$tmp" | wc -l)"
  logical="$(awk -F'\t' '$1=="f" {s+=$3} END{print s+0}' "$tmp")"
  rm -f "$tmp"
  printf 'FILES=%s DIRS=%s SYMLINKS=%s HARDLINKED_FILE_PATH_COUNT=%s LOGICAL_BYTES=%s\n' \
    "$files" "$dirs" "$links" "$hardlinked" "$logical"
}

count_hardlinked_paths() {
  local root="$1"
  find "$root" -xdev -type f -links +1 2>/dev/null | wc -l
}

# ---------------------------------------------------------------------------
# Capacity guard
# ---------------------------------------------------------------------------
capacity_guard() {
  local source="$1"
  local unique apparent needed root_avail projected min_headroom
  unique="$(path_used_bytes "$source")"
  apparent="$(path_apparent_bytes "$source")"
  [[ -n "$unique" && "$unique" -gt 0 ]] || die "Unable to measure source usage"
  needed="$unique"
  # max(unique*2, 10GiB, apparent)
  local t
  t=$((unique * 2))
  [[ "$t" -gt "$needed" ]] && needed="$t"
  t=$((10 * 1024 * 1024 * 1024))
  [[ "$t" -gt "$needed" ]] && needed="$t"
  [[ "$apparent" -gt "$needed" ]] && needed="$apparent"

  root_avail="$(root_avail_bytes)"
  min_headroom=$((20 * 1024 * 1024 * 1024))
  projected=$((root_avail - unique))
  info "CAPACITY unique=${unique} apparent=${apparent} needed_budget=${needed} root_avail=${root_avail} projected_after=${projected}"
  if [[ "$root_avail" -lt "$needed" ]]; then
    die "ROOT_CAPACITY_GUARD=FAIL root_avail=${root_avail} < needed=${needed}"
  fi
  if [[ "$projected" -lt "$min_headroom" ]]; then
    die "ROOT_HEADROOM_GUARD=FAIL projected_after=${projected} < 20GiB"
  fi
  ok "ROOT_CAPACITY_GUARD=PASS"
  printf '%s %s %s\n' "$unique" "$apparent" "$projected"
}

# ---------------------------------------------------------------------------
# Process / service guards
# ---------------------------------------------------------------------------
# Query systemd unit ActiveState via `systemctl is-active`.
# Prints exactly one line to stdout. Never uses `|| echo inactive` —
# is-active already prints "inactive" on stdout with a non-zero exit code,
# so a fallback echo would duplicate the line (inactive\ninactive).
get_unit_active_state() {
  local unit="$1"
  local state

  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  state="${state%%$'\n'*}"

  case "$state" in
    active|inactive|failed|activating|deactivating|reloading)
      printf '%s\n' "$state"
      ;;
    "")
      printf '%s\n' "unknown"
      ;;
    *)
      printf '%s\n' "$state"
      ;;
  esac
}

assert_no_sync_processes() {
  local hits
  # Match real sync/materialize executables — not fixture HTTP servers whose
  # argv merely contains a path segment like /var/spool/apt-mirror.
  hits="$(
    {
      pgrep -af '(^|[[:space:]/])ubuntu-offline-mirror\.sh([[:space:]]|$)' 2>/dev/null || true
      pgrep -af '(^|[[:space:]/])materialize-selective([[:space:]]|$)' 2>/dev/null || true
      pgrep -x apt-mirror 2>/dev/null || true
      pgrep -af '/usr/bin/apt-mirror([[:space:]]|$)' 2>/dev/null || true
    } | grep -v "migrate-apt-mirror-to-root" | grep -v grep || true
  )"
  if [[ -n "$(printf '%s' "$hits" | tr -d '[:space:]')" ]]; then
    printf '%s\n' "$hits"
    die "Active materialize/sync process detected"
  fi
  if pgrep -af '[r]sync.*(apt-mirror|migrate-apt-mirror)' 2>/dev/null \
    | grep -v "migrate-apt-mirror-to-root" \
    | grep -Eq 'rsync'; then
    die "Active rsync/migration process detected"
  fi
  ok "NO_SYNC_OR_MIGRATION_PROCESS=PASS"
}

list_mount_user_pids() {
  local mount="$1"
  local pids="" pid cwd cmd
  # In fixture mode, ignore global lsof/fuser (tmp trees share the real FS with
  # unrelated processes). Only honor cwd/exe under the mount path.
  if [[ "$TEST_MODE" != "1" ]]; then
    if command -v lsof >/dev/null 2>&1; then
      pids="$(lsof +D "$mount" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || true)"
    fi
    if [[ -z "$pids" ]] && command -v fuser >/dev/null 2>&1; then
      pids="$(fuser -m "$mount" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -u || true)"
    fi
  fi
  for pid in /proc/[0-9]*; do
    cwd="$(readlink "$pid/cwd" 2>/dev/null || true)"
    if [[ "$cwd" == "$mount" || "$cwd" == "$mount"/* ]]; then
      pids+=$'\n'"${pid##*/}"
    fi
  done
  # Drop short-lived PIDs and this script's process tree noise.
  while read -r pid; do
    [[ -z "$pid" ]] && continue
    [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
    cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
    [[ -z "$cmd" ]] && continue
    printf '%s\n' "$pid"
  done < <(printf '%s\n' "$pids" | grep -E '^[0-9]+$' | sort -u)
}

gpg_agents_on_mount() {
  local mount="$1" pid cmd
  while read -r pid; do
    [[ -z "$pid" ]] && continue
    cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)" || continue
    if [[ "$cmd" == *gpg-agent* ]]; then
      printf '%s\n' "$pid"
    fi
  done < <(list_mount_user_pids "$mount")
}

stop_gpg_agents_on_mount() {
  local mount="$1" pid
  local agents
  agents="$(gpg_agents_on_mount "$mount" || true)"
  if [[ -z "$agents" ]]; then
    ok "GPG_AGENT_ON_MOUNT=NONE"
    return 0
  fi
  while read -r pid; do
    [[ -z "$pid" ]] && continue
    info "Stopping gpg-agent pid=$pid using mount"
    if [[ "$TEST_MODE" == "1" ]]; then
      kill "$pid" 2>/dev/null || true
    else
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi
  done <<<"$agents"
  ok "GPG_AGENT_STOPPED=PASS"
}

assert_no_user_handles() {
  local mount="$1"
  local pids leftover
  pids="$(list_mount_user_pids "$mount" || true)"
  leftover=""
  while read -r pid; do
    [[ -z "$pid" ]] && continue
    leftover+="$pid "
  done <<<"$pids"
  if [[ -n "${leftover// /}" ]]; then
    error "Open handles remain on ${mount}: ${leftover}"
    fail_rc "OPEN_HANDLE_GUARD=FAIL"
    return 1
  fi
  ok "OPEN_HANDLE_COUNT=0"
}

# ---------------------------------------------------------------------------
# Inbound HTTP connection guard (local sport 80/443 only; read-only)
# ---------------------------------------------------------------------------
# Extract numeric port from ss local/peer endpoint (IPv4 host:port or IPv6 [addr]:port).
ss_endpoint_port() {
  local endpoint="$1" value
  [[ -n "$endpoint" && "$endpoint" == *:* ]] || return 1
  value="${endpoint##*:}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$value"
}

# Emit established TCP lines for parsing. Fixture overrides avoid real network in tests.
# Does not treat query failure as empty/zero.
collect_ss_established_lines() {
  local rc=0
  if [[ -n "${MIGRATE_FAKE_SS_FILE:-}" ]]; then
    rc="${MIGRATE_FAKE_SS_RC:-0}"
    if [[ "$rc" != "0" ]]; then
      echo "ss fixture forced failure rc=${rc}" >&2
      return "$rc"
    fi
    [[ -f "$MIGRATE_FAKE_SS_FILE" ]] || {
      echo "MIGRATE_FAKE_SS_FILE missing: $MIGRATE_FAKE_SS_FILE" >&2
      return 1
    }
    cat "$MIGRATE_FAKE_SS_FILE"
    return 0
  fi
  if [[ "$TEST_MODE" == "1" ]]; then
    # Deterministic fixture default: no real ss dependency.
    return 0
  fi
  # Prefer ss sport filter when available (validated on iproute2); still parse below.
  # Full established dump is required so outbound HTTPS peers can be reported.
  ss -Htn state established || return $?
}

# Parse ss -Htn established rows from stdin.
# Counts only connections whose LOCAL service port is 80 or 443.
# Prints INBOUND_HTTP_* / OUTBOUND_HTTPS_* detail lines, then INBOUND_HTTP_CONNECTIONS=<n>.
# Exit 2 on malformed input (never silently coerce to 0).
parse_ss_http_connections() {
  awk '
    function port_of(endpoint, value) {
      value = endpoint
      if (value == "" || index(value, ":") == 0)
        return ""
      sub(/^.*:/, "", value)
      return value
    }
    function is_port(p) {
      return (p ~ /^[0-9]+$/)
    }
    function fail_parse(msg) {
      printf "PARSE_ERROR: %s\n", msg > "/dev/stderr"
      had_error = 1
      # awk still runs END after exit; END must not emit a fake zero count.
      exit
    }
    {
      line = $0
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "")
        next
      n = split(line, f, /[ \t]+/)
      local_ep = ""
      peer_ep = ""
      if (n >= 5 && f[1] ~ /^(tcp|udp|TCP|UDP)$/) {
        local_ep = f[4]
        peer_ep = f[5]
      } else if (n >= 4) {
        local_ep = f[3]
        peer_ep = f[4]
      } else {
        fail_parse("bad field count: " line)
      }
      lport = port_of(local_ep)
      rport = port_of(peer_ep)
      if (!is_port(lport) || !is_port(rport)) {
        fail_parse("non-numeric port local=" local_ep " peer=" peer_ep " line=" line)
      }
      if (lport == "80" || lport == "443") {
        inbound++
        printf "INBOUND_HTTP_LOCAL=%s REMOTE=%s\n", local_ep, peer_ep
      } else if (rport == "443") {
        # Reference only — outbound HTTPS must not block cutover.
        printf "OUTBOUND_HTTPS_LOCAL=%s REMOTE=%s\n", local_ep, peer_ep
      }
    }
    END {
      if (had_error)
        exit 2
      printf "INBOUND_HTTP_CONNECTIONS=%d\n", inbound + 0
    }
  '
}

# Read-only guard: abort when inbound HTTP(S) is present or ss/parse fails.
assert_no_inbound_http_connections() {
  local raw_file parse_file err_file parse_rc=0 count="" line
  raw_file="$(mktemp)"
  parse_file="$(mktemp)"
  err_file="$(mktemp)"

  cleanup_ss_tmp() {
    rm -f -- "$raw_file" "$parse_file" "$err_file"
  }

  if ! collect_ss_established_lines >"$raw_file" 2>"$err_file"; then
    error "ss established query failed (not treating as INBOUND_HTTP_CONNECTIONS=0)"
    if [[ -s "$err_file" ]]; then
      cat "$err_file" >&2 || true
    fi
    cleanup_ss_tmp
    fail_rc "INBOUND_HTTP_CONNECTION_GUARD=FAIL ss_query"
    return 1
  fi

  parse_rc=0
  parse_ss_http_connections <"$raw_file" >"$parse_file" 2>"$err_file" || parse_rc=$?
  if [[ "$parse_rc" -ne 0 ]]; then
    error "ss established parse failed rc=${parse_rc} (not treating as INBOUND_HTTP_CONNECTIONS=0)"
    if [[ -s "$err_file" ]]; then
      cat "$err_file" >&2 || true
    fi
    cleanup_ss_tmp
    fail_rc "INBOUND_HTTP_CONNECTION_GUARD=FAIL ss_parse"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    case "$line" in
      INBOUND_HTTP_CONNECTIONS=*)
        count="${line#INBOUND_HTTP_CONNECTIONS=}"
        printf '%s\n' "$line"
        info "$line"
        ;;
      INBOUND_HTTP_LOCAL=*|OUTBOUND_HTTPS_LOCAL=*)
        printf '%s\n' "$line"
        info "$line"
        ;;
      *)
        info "$line"
        ;;
    esac
  done <"$parse_file"

  if [[ ! "$count" =~ ^[0-9]+$ ]]; then
    error "INBOUND_HTTP_CONNECTIONS missing or non-integer after parse"
    cleanup_ss_tmp
    fail_rc "INBOUND_HTTP_CONNECTION_GUARD=FAIL missing_count"
    return 1
  fi

  if [[ "$count" -gt 0 ]]; then
    error "Active inbound HTTP(S) connections on local :80/:443: INBOUND_HTTP_CONNECTIONS=${count}"
    cleanup_ss_tmp
    fail_rc "INBOUND_HTTP_CONNECTION_GUARD=FAIL inbound=${count}"
    return 1
  fi

  cleanup_ss_tmp
  ok "INBOUND_HTTP_CONNECTIONS=0"
  return 0
}

# ---------------------------------------------------------------------------
# nginx helpers
# ---------------------------------------------------------------------------
nginx_test() {
  if [[ "$SKIP_NGINX_T" == "1" ]]; then
    ok "NGINX_T=SKIPPED"
    return 0
  fi
  if [[ "$TEST_MODE" == "1" ]]; then
    # Deterministic fixture control: optional 1-based call index that must FAIL.
    # Avoids racy background watchers that poll the fake mount table.
    MIGRATE_TEST_NGINX_T_CALL_COUNT="${MIGRATE_TEST_NGINX_T_CALL_COUNT:-0}"
    MIGRATE_TEST_NGINX_T_CALL_COUNT=$((MIGRATE_TEST_NGINX_T_CALL_COUNT + 1))
    local nt="${MIGRATE_TEST_NGINX_T:-PASS}"
    if [[ -n "${MIGRATE_TEST_NGINX_T_FILE:-}" && -f "${MIGRATE_TEST_NGINX_T_FILE}" ]]; then
      nt="$(tr -d '[:space:]' <"${MIGRATE_TEST_NGINX_T_FILE}")"
    fi
    if [[ -n "${MIGRATE_TEST_NGINX_T_FAIL_ON_CALL:-}" \
      && "${MIGRATE_TEST_NGINX_T_FAIL_ON_CALL}" == "${MIGRATE_TEST_NGINX_T_CALL_COUNT}" ]]; then
      nt="FAIL"
    fi
    if [[ "$nt" != "PASS" ]]; then
      fail_rc "nginx -t failed (fixture)"
      return 1
    fi
    ok "NGINX_T=PASS"
    return 0
  fi
  if nginx -t 2>/tmp/migrate-nginx-t.err; then
    ok "NGINX_T=PASS"
    return 0
  fi
  # retry via sudo if needed for pid path
  if command -v sudo >/dev/null 2>&1 && sudo -n nginx -t 2>/tmp/migrate-nginx-t.err; then
    ok "NGINX_T=PASS"
    return 0
  fi
  # syntax-only acceptance when only pid permission fails
  if grep -q 'syntax is ok' /tmp/migrate-nginx-t.err 2>/dev/null \
    && grep -q 'Permission denied' /tmp/migrate-nginx-t.err 2>/dev/null; then
    if [[ "${MIGRATE_ALLOW_NGINX_T_PERM_SOFT:-1}" == "1" ]]; then
      warn "nginx -t syntax ok but pid permission denied; accepting soft PASS for preflight"
      ok "NGINX_T=PASS soft=permission"
      return 0
    fi
  fi
  cat /tmp/migrate-nginx-t.err >&2 || true
  fail_rc "nginx -t failed"
  return 1
}

nginx_cmd() {
  local action="$1"
  if [[ "$TEST_MODE" == "1" ]]; then
    info "FAKE nginx ${action}"
    printf '%s\n' "$action" >>"${MIGRATE_FAKE_LOG:-/dev/null}"
    if [[ "$action" == "start" || "$action" == "stop" ]]; then
      [[ "${MIGRATE_TEST_NGINX_T:-PASS}" == "PASS" ]] || return 1
    fi
    return 0
  fi
  case "$action" in
    stop) systemctl stop nginx ;;
    start) systemctl start nginx ;;
    *) die "Unknown nginx action $action" ;;
  esac
}

extract_http_paths_from_nginx() {
  local conf="${1:-$NGINX_SITE}"
  [[ -f "$conf" ]] || return 0
  # Heuristic paths for verify
  cat <<'EOF'
/
/client/
/client/dp-offline-upgrade-xenial-to-bionic.sh
/client/dp-offline-upgrade-xenial-to-bionic.sh.sha256
/client/dp-offline-upgrade-bionic-to-focal.sh
/client/dp-offline-upgrade-bionic-to-focal.sh.sha256
/client/dp-offline-upgrade-focal-to-jammy.sh
/client/dp-offline-upgrade-focal-to-jammy.sh.sha256
/client/dp-offline-upgrade-jammy-to-noble.sh
/client/dp-offline-upgrade-jammy-to-noble.sh.sha256
/keys/ubuntu-mirror-selective.gpg
/offline/meta-release-lts
/hops/xenial-to-bionic/ubuntu/dists/bionic/Release
/hops/bionic-to-focal/ubuntu/dists/focal/Release
/hops/focal-to-jammy/ubuntu/dists/jammy/Release
/hops/jammy-to-noble/ubuntu/dists/noble/Release
EOF
  # Also pull ReleaseAnnouncement if present under client hops
  if [[ -d "${SOURCE_MOUNT}/client" ]]; then
    find "${SOURCE_MOUNT}/client" -maxdepth 2 -name 'ReleaseAnnouncement' 2>/dev/null \
      | sed "s|^${SOURCE_MOUNT}/client|/client|" || true
  fi
}

http_verify() {
  if [[ "$SKIP_HTTP" == "1" ]]; then
    ok "HTTP_VERIFY=SKIPPED"
    return 0
  fi
  if [[ "$TEST_MODE" == "1" ]]; then
    if [[ "${MIGRATE_TEST_HTTP:-PASS}" != "PASS" ]]; then
      fail_rc "HTTP verify failed (fixture)"
      return 1
    fi
    ok "HTTP_VERIFY=PASS"
    return 0
  fi
  local path code fail=0
  require_cmd curl
  while read -r path; do
    [[ -z "$path" || "$path" =~ ^# ]] && continue
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 20 \
      "${HTTP_BASE}${path}" 2>/dev/null || echo 000)"
    if [[ "$code" != "200" && "$code" != "301" && "$code" != "302" ]]; then
      error "HTTP ${path} -> ${code}"
      fail=1
    else
      info "HTTP ${path} -> ${code}"
    fi
  done < <(extract_http_paths_from_nginx)
  if [[ "$fail" -ne 0 ]]; then
    fail_rc "HTTP_VERIFY=FAIL"
    return 1
  fi
  ok "HTTP_VERIFY=PASS"
}

# ---------------------------------------------------------------------------
# ALLOW_ROOT_FS_MIRROR — effective configs only
# ---------------------------------------------------------------------------
# Effective runtime sources (do NOT modify tracked repo mirror.conf / templates):
#   1) /etc/default/ubuntu-offline-mirror  (ubuntu-offline-mirror.sh check_mirror_mount)
#   2) /etc/ubuntu-mirror/mirror.conf     (um_load_config consumers)
set_allow_root_fs_mirror() {
  local value="$1"
  local f changed=0
  for f in "$EFFECTIVE_DEFAULTS" "$EFFECTIVE_MIRROR_CONF"; do
    [[ -f "$f" ]] || continue
    if grep -qE '^[[:space:]]*ALLOW_ROOT_FS_MIRROR=' "$f"; then
      sed -i -E "s|^[[:space:]]*ALLOW_ROOT_FS_MIRROR=.*|ALLOW_ROOT_FS_MIRROR=${value}|" "$f"
    else
      printf '\nALLOW_ROOT_FS_MIRROR=%s\n' "$value" >>"$f"
    fi
    # Normalize quoted form in mirror.conf style
    if [[ "$f" == *mirror.conf ]]; then
      sed -i -E "s|^[[:space:]]*ALLOW_ROOT_FS_MIRROR=.*|ALLOW_ROOT_FS_MIRROR=\"${value}\"|" "$f"
    fi
    changed=1
    info "Updated ALLOW_ROOT_FS_MIRROR=${value} in effective config: $f"
  done
  [[ "$changed" -eq 1 ]] || warn "No effective config file found to set ALLOW_ROOT_FS_MIRROR"
  # Report tracked sources that still differ (do not modify).
  if [[ -f "${REPO_ROOT}/mirror.conf" ]] && grep -q 'ALLOW_ROOT_FS_MIRROR="false"' "${REPO_ROOT}/mirror.conf"; then
    warn "TRACKED_SOURCE_STILL_FALSE=${REPO_ROOT}/mirror.conf (not auto-modified)"
  fi
  if [[ -f "${REPO_ROOT}/templates/ubuntu-offline-mirror.default" ]] \
    && grep -q 'ALLOW_ROOT_FS_MIRROR=false' "${REPO_ROOT}/templates/ubuntu-offline-mirror.default"; then
    warn "TRACKED_TEMPLATE_STILL_FALSE=${REPO_ROOT}/templates/ubuntu-offline-mirror.default (not auto-modified)"
  fi
}

# ---------------------------------------------------------------------------
# fstab helpers
# ---------------------------------------------------------------------------
fstab_backup_and_disable_uuid() {
  local uuid="$1"
  local bak="${EVIDENCE_DIR}/fstab.pre-cutover"
  cp -a "$FSTAB_PATH" "$bak"
  local tmp
  tmp="$(mktemp)"
  awk -v u="$uuid" -v ts="$(ts)" '
    BEGIN { re="^[[:space:]]*UUID=" u "[[:space:]]" }
    {
      if ($0 ~ re && $0 !~ /^[[:space:]]*#/) {
        print "# migrate-apt-mirror-to-root.sh disabled " ts
        print "#" $0
      } else {
        print $0
      }
    }
  ' "$FSTAB_PATH" >"$tmp"
  # Ensure unrelated lines intact and exactly one disable for UUID
  if ! grep -qE "^#UUID=${uuid}[[:space:]]" "$tmp"; then
    # also accept "# UUID="
    if ! grep -qE "^#[[:space:]]*UUID=${uuid}[[:space:]]" "$tmp"; then
      rm -f "$tmp"
      die "fstab UUID disable failed for $uuid"
    fi
  fi
  # Must not leave an active (uncommented) UUID line
  if grep -qE "^[[:space:]]*UUID=${uuid}[[:space:]]" "$tmp"; then
    rm -f "$tmp"
    die "fstab still has active UUID entry for $uuid"
  fi
  cp "$tmp" "$FSTAB_PATH"
  rm -f "$tmp"
  ok "FSTAB_UUID_DISABLED=$uuid"
}

fstab_restore_from_evidence() {
  local bak="${EVIDENCE_DIR}/fstab.pre-cutover"
  [[ -f "$bak" ]] || die "fstab backup missing: $bak"
  cp -a "$bak" "$FSTAB_PATH"
  ok "FSTAB_RESTORED=YES"
}

# ---------------------------------------------------------------------------
# rsync
# ---------------------------------------------------------------------------
rsync_flags() {
  # -aHAX --numeric-ids preserves archive, hardlinks, ACL, xattrs, numeric ids
  # --sparse for sparse files; --partial for resume; --delete-delay only with path guards
  local f
  for f in -aHAX --numeric-ids --sparse --human-readable --partial --info=progress2; do
    printf '%s\n' "$f"
  done
}

assert_rsync_supports_hardlinks() {
  local help
  help="$(rsync --help 2>&1 || true)"
  printf '%s' "$help" | grep -qE -- '-H,|--hard-links' || die "rsync lacks hardlink support (-H)"
  # Ensure our invocation includes hardlink flag via -aHAX (H enables --hard-links)
  local flags
  flags="$(rsync_flags | tr '\n' ' ')"
  printf '%s' "$flags" | grep -qE '(^|[[:space:]])-aHAX([[:space:]]|$)|(^|[[:space:]])-H([[:space:]]|$)|--hard-links' \
    || die "rsync flags missing -H"
  ok "RSYNC_HARDLINK_FLAG=PASS"
}

rsync_copy() {
  local src="$1" dst="$2" with_delete="${3:-0}"
  local src_c dst_c
  src_c="$(canonical_path "$src")"
  dst_c="$(canonical_path "$dst")"
  [[ -d "$src_c" ]] || die "rsync source not a directory: $src_c"
  mkdir -p "$dst_c"

  # Path guards: refuse identical paths; refuse destination outside expected stage/source roles
  [[ "$src_c" != "$dst_c" ]] || die "rsync source and destination are identical"
  case "$dst_c" in
    "${STAGE_PATH}"|"$(canonical_path "$STAGE_PATH")") ;;
    *)
      if [[ "$TEST_MODE" == "1" ]]; then
        :
      else
        local stage_c
        stage_c="$(canonical_path "$STAGE_PATH")"
        [[ "$dst_c" == "$stage_c" ]] || die "rsync destination guard failed: $dst_c (expected $stage_c)"
      fi
      ;;
  esac

  local -a args
  mapfile -t args < <(rsync_flags)
  if [[ "$with_delete" == "1" ]]; then
    args+=(--delete-delay)
  fi
  info "RSYNC ${src_c}/ -> ${dst_c}/ flags=${args[*]}"
  rsync "${args[@]}" "${src_c}/" "${dst_c}/"
  ok "RSYNC_COMPLETE ${src_c}/ -> ${dst_c}/"
}

# ---------------------------------------------------------------------------
# Verify trees
# ---------------------------------------------------------------------------
verify_trees() {
  local src="$1" dst="$2"
  assert_selective_symlinks "$dst"
  compare_key_metadata "$(private_key_path "$src")" "$(private_key_path "$dst")"
  [[ -f "${dst}/${PUBLIC_KEY_REL}" ]] || die "Public key missing on destination"

  local inv_s inv_d
  inv_s="$(inventory_tree "$src")"
  inv_d="$(inventory_tree "$dst")"
  info "SOURCE_INVENTORY $inv_s"
  info "DEST_INVENTORY $inv_d"

  local hs hd
  hs="$(count_hardlinked_paths "$src")"
  hd="$(count_hardlinked_paths "$dst")"
  info "HARDLINKED_FILE_PATH_COUNT source=${hs} dest=${hd}"
  [[ "$hs" == "$hd" ]] || die "Hardlinked path count mismatch source=${hs} dest=${hd}"

  # Symlink targets
  [[ "$(symlink_target "${dst}/selective/current")" == "$(symlink_target "${src}/selective/current")" ]] \
    || die "current symlink mismatch"
  [[ "$(symlink_target "${dst}/selective/active")" == "$(symlink_target "${src}/selective/active")" ]] \
    || die "active symlink mismatch"

  # READY / state if present
  if [[ -e "${src}/selective/state/READY" ]]; then
    [[ -e "${dst}/selective/state/READY" ]] || die "READY marker missing on destination"
  fi

  # Four-hop client scripts + sha256 sidecars
  local hop
  for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
    local s="client/dp-offline-upgrade-${hop}.sh"
    if [[ -f "${src}/${s}" ]]; then
      [[ -f "${dst}/${s}" ]] || die "Missing $s on destination"
      [[ -f "${dst}/${s}.sha256" ]] || die "Missing ${s}.sha256 on destination"
      # Compare sha256 sidecar text (not private key)
      cmp -s "${src}/${s}.sha256" "${dst}/${s}.sha256" || die "sha256 sidecar mismatch for $s"
    fi
  done

  # Sample hardlink preservation: if two paths share inode on source, dest must too
  local sample
  sample="$(find "${src}/selective" -xdev -type f -links +1 2>/dev/null | head -1 || true)"
  if [[ -n "$sample" ]]; then
    local rel other ino1 ino2
    rel="${sample#"$src"/}"
    ino1="$(stat -c '%i' "$sample")"
    other="$(find "${src}/selective" -xdev -type f -inum "$ino1" 2>/dev/null | grep -v "^${sample}$" | head -1 || true)"
    if [[ -n "$other" ]]; then
      local rel2 inod1 inod2
      rel2="${other#"$src"/}"
      inod1="$(stat -c '%i' "${dst}/${rel}")"
      inod2="$(stat -c '%i' "${dst}/${rel2}")"
      [[ "$inod1" == "$inod2" ]] || die "Hardlink not preserved for ${rel} <-> ${rel2}"
      ok "HARDLINK_SAMPLE_PRESERVED=YES"
    fi
  fi

  ok "TREE_VERIFY=PASS"
}

verify_live_spool() {
  local root="$1"
  assert_selective_symlinks "$root"
  key_metadata_line "$(private_key_path "$root")" >/dev/null
  [[ -f "$(private_key_path "$root")" ]] || die "Private key missing under live spool"
  [[ -f "${root}/${PUBLIC_KEY_REL}" ]] || die "Public key missing under live spool"
  ok "LIVE_SPOOL_STRUCTURE=PASS"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
cmd_preflight() {
  info "MODE=preflight (read-only)"
  require_cmd rsync
  require_cmd findmnt
  require_cmd awk
  require_cmd sed
  assert_rsync_supports_hardlinks
  git_repo_ok

  local src_src src_tgt src_fstype root_src stage_parent
  [[ -d "$SOURCE_MOUNT" ]] || die "SOURCE_MOUNT missing: $SOURCE_MOUNT"
  src_src="$(path_source "$SOURCE_MOUNT")"
  src_tgt="$(path_target "$SOURCE_MOUNT")"
  src_fstype="$(path_fstype "$SOURCE_MOUNT")"

  info "SOURCE_MOUNT=$SOURCE_MOUNT SOURCE=$src_src TARGET=$src_tgt FSTYPE=$src_fstype"

  device_exists "$EXPECTED_DISK" || die "Candidate disk missing: $EXPECTED_DISK"
  device_exists "$EXPECTED_PART" || die "Candidate partition missing: $EXPECTED_PART"

  local uuid
  uuid="$(blkid_uuid "$EXPECTED_PART")"
  [[ "$uuid" == "$EXPECTED_UUID" ]] || die "UUID mismatch: got '${uuid}' expected '${EXPECTED_UUID}'"

  [[ "$src_tgt" == "$SOURCE_MOUNT" ]] || die "Mountpoint mismatch: ${src_tgt} != ${SOURCE_MOUNT}"
  case "$src_src" in
    "$EXPECTED_PART"|*"${EXPECTED_PART}") ;;
    *)
      # Accept mapper/by-uuid that resolves to expected part in test/prod
      if [[ "$TEST_MODE" == "1" ]]; then
        [[ "$src_src" == "$EXPECTED_PART" || "$src_src" == "UUID=${EXPECTED_UUID}" ]] \
          || die "Source device mismatch: $src_src"
      else
        local resolved
        resolved="$(readlink -f "$src_src" 2>/dev/null || echo "$src_src")"
        local exp_r
        exp_r="$(readlink -f "$EXPECTED_PART" 2>/dev/null || echo "$EXPECTED_PART")"
        [[ "$resolved" == "$exp_r" || "$src_src" == "$EXPECTED_PART" ]] \
          || die "Source device mismatch: $src_src (expected $EXPECTED_PART)"
      fi
      ;;
  esac
  [[ "$src_fstype" == "ext4" ]] || die "Filesystem not ext4: $src_fstype"

  # Not root/boot/swap/LVM/RAID
  root_src="$(path_source /)"
  [[ "$src_src" != "$root_src" ]] || die "Source is root filesystem"
  [[ "$src_tgt" != "/" && "$src_tgt" != "/boot" && "$src_tgt" != "/boot/efi" ]] \
    || die "Source mount is critical system path"
  if [[ "$TEST_MODE" != "1" ]]; then
    if lsblk -no TYPE,FSTYPE "$EXPECTED_PART" 2>/dev/null | grep -Eq 'lvm|LVM|linux_raid'; then
      die "Candidate looks like LVM/RAID member"
    fi
    if [[ -d "/sys/block/$(basename "$EXPECTED_DISK")/holders" ]]; then
      local holders
      holders="$(ls "/sys/block/$(basename "$EXPECTED_DISK")/holders" 2>/dev/null || true)"
      [[ -z "$holders" ]] || die "Candidate disk has holders: $holders"
    fi
  fi

  # Destination staging on root FS, different from source (read-only: do not create)
  stage_parent="$(dirname "$STAGE_PATH")"
  [[ -d "$stage_parent" ]] || die "Stage parent missing: $stage_parent"
  local stage_probe="$stage_parent"
  [[ -e "$STAGE_PATH" ]] && stage_probe="$STAGE_PATH"
  local stage_src root_tgt
  stage_src="$(path_source "$stage_probe")"
  root_tgt="$(path_target /)"
  [[ "$(path_target "$stage_probe")" == "$root_tgt" || "$stage_src" == "$root_src" ]] \
    || die "Stage path is not on root filesystem (source=$stage_src)"
  [[ "$(fs_devno "$SOURCE_MOUNT")" != "$(fs_devno "$stage_probe")" ]] \
    || die "Source and destination staging are on the same filesystem"

  # RW source
  if [[ "$TEST_MODE" == "1" ]]; then
    [[ -w "$SOURCE_MOUNT" ]] || die "Source not writable"
  else
    local opts
    opts="$(findmnt -n -o OPTIONS --target "$SOURCE_MOUNT" 2>/dev/null || true)"
    printf '%s' "$opts" | grep -Eq '(^|,)ro(,|$)' && die "Source filesystem is read-only"
  fi

  capacity_guard "$SOURCE_MOUNT" >/dev/null

  if [[ "$SKIP_GIT" != "1" ]]; then
    git_is_clean || die "Git worktree is dirty"
    git_head_matches_origin_main || die "Git HEAD does not match origin/main"
    ok "GIT_CLEAN=YES HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD)"
  else
    warn "GIT checks skipped (MIGRATE_SKIP_GIT=1)"
  fi

  nginx_test
  assert_selective_symlinks "$SOURCE_MOUNT"
  [[ -f "$(private_key_path "$SOURCE_MOUNT")" ]] || die "Private signing key missing"
  key_metadata_line "$(private_key_path "$SOURCE_MOUNT")" >&2

  local svc timer
  svc="$(get_unit_active_state apt-mirror.service)"
  timer="$(get_unit_active_state apt-mirror.timer)"
  info "apt-mirror.service=${svc}"
  info "apt-mirror.timer=${timer}"
  assert_no_sync_processes

  ok "PREFLIGHT=PASS"
  cat <<EOF
PREFLIGHT=PASS
CANDIDATE_DISK=${EXPECTED_DISK}
CANDIDATE_PARTITION=${EXPECTED_PART}
CANDIDATE_UUID=${EXPECTED_UUID}
SOURCE_MOUNT=${SOURCE_MOUNT}
STAGE_PATH=${STAGE_PATH}
SOURCE_MUTATION=NO
FSTAB_MUTATION=NO
SERVICE_MUTATION=NO
DISK_MUTATION=NO
EOF
}

# ---------------------------------------------------------------------------
# Initial copy
# ---------------------------------------------------------------------------
cmd_initial_copy() {
  [[ "$EXECUTE" -eq 1 ]] || die "--initial-copy requires --execute"
  cmd_preflight >/dev/null
  ensure_evidence_dir >/dev/null
  info "MODE=initial-copy EVIDENCE=${EVIDENCE_DIR}"

  mkdir -p "$STAGE_PATH"
  # Ensure stage still on root / different FS
  [[ "$(fs_devno "$SOURCE_MOUNT")" != "$(fs_devno "$STAGE_PATH")" ]] \
    || die "Stage ended up on same filesystem as source"

  rsync_copy "$SOURCE_MOUNT" "$STAGE_PATH" 0
  verify_trees "$SOURCE_MOUNT" "$STAGE_PATH"
  sync

  ok "INITIAL_COPY=PASS"
  cat <<EOF
INITIAL_COPY=PASS
SOURCE_MUTATION=NO
FSTAB_MUTATION=NO
SERVICE_MUTATION=NO
DISK_MUTATION=NO
STAGE_PATH=${STAGE_PATH}
EVIDENCE_DIR=${EVIDENCE_DIR}
EOF
}

# ---------------------------------------------------------------------------
# Mount/umount wrappers
# ---------------------------------------------------------------------------
do_umount() {
  local target="$1"
  if [[ "$TEST_MODE" == "1" ]]; then
    info "FAKE umount $target"
    # Update fake mount table: remove lines whose TARGET == target
    if [[ -n "$FAKE_MOUNT_TABLE" && -f "$FAKE_MOUNT_TABLE" ]]; then
      local tmp
      tmp="$(mktemp)"
      awk -v t="$target" '$1!=t {print}' "$FAKE_MOUNT_TABLE" >"$tmp"
      mv "$tmp" "$FAKE_MOUNT_TABLE"
    fi
    # Simulate block device leaving an empty mountpoint directory while
    # preserving data for rollback under evidence (never delete source data).
    local store="${EVIDENCE_DIR:-/tmp}/fake-disk-store"
    mkdir -p "$store"
    if [[ -d "$target" ]]; then
      find "$target" -mindepth 1 -maxdepth 1 -exec mv {} "$store/" \;
    fi
    if [[ -n "${MIGRATE_TEST_UMOUNT_LEAVE:-}" ]]; then
      printf 'stray\n' >"${target}/${MIGRATE_TEST_UMOUNT_LEAVE}"
    fi
    printf 'umount %s\n' "$target" >>"${MIGRATE_FAKE_LOG:-/dev/null}"
    return 0
  fi
  umount "$target"
}

do_mount() {
  local what="$1" where="$2"
  if [[ "$TEST_MODE" == "1" ]]; then
    info "FAKE mount $what $where"
    if [[ -n "$FAKE_MOUNT_TABLE" ]]; then
      local fstype="${MIGRATE_TEST_MOUNT_FSTYPE:-ext4}"
      # avoid duplicate rows
      if ! awk -v t="$where" '$1==t {found=1} END{exit !found}' "$FAKE_MOUNT_TABLE"; then
        printf '%s %s %s\n' "$where" "$what" "$fstype" >>"$FAKE_MOUNT_TABLE"
      fi
    fi
    mkdir -p "$where"
    local store="${EVIDENCE_DIR:-/tmp}/fake-disk-store"
    if [[ -d "$store" ]]; then
      find "$store" -mindepth 1 -maxdepth 1 -exec mv {} "$where/" \;
    fi
    printf 'mount %s %s\n' "$what" "$where" >>"${MIGRATE_FAKE_LOG:-/dev/null}"
    return 0
  fi
  mount "$what" "$where"
}

do_daemon_reload() {
  if [[ "$TEST_MODE" == "1" ]]; then
    info "FAKE systemctl daemon-reload"
    printf 'daemon-reload\n' >>"${MIGRATE_FAKE_LOG:-/dev/null}"
    return 0
  fi
  systemctl daemon-reload
}

is_mountpoint() {
  local p="$1"
  if [[ -n "$FAKE_MOUNT_TABLE" && -f "$FAKE_MOUNT_TABLE" ]]; then
    awk -v t="$p" '$1==t {found=1} END{exit !found}' "$FAKE_MOUNT_TABLE"
    return $?
  fi
  mountpoint -q "$p" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Cutover
# ---------------------------------------------------------------------------
require_cutover_confirm() {
  if [[ "$CONFIRM_TEXT" == "CUTOVER_TO_ROOT" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "Cutover confirmation required (set MIGRATE_CONFIRM_CUTOVER=CUTOVER_TO_ROOT or type interactively)"
  fi
  local ans
  printf 'Type CUTOVER_TO_ROOT to continue: ' >&2
  read -r ans
  [[ "$ans" == "CUTOVER_TO_ROOT" ]] || die "Cutover confirmation mismatch"
}

cmd_cutover() {
  [[ "$EXECUTE" -eq 1 ]] || die "--cutover requires --execute"
  require_cutover_confirm
  cmd_preflight >/dev/null
  ensure_evidence_dir >/dev/null
  info "MODE=cutover EVIDENCE=${EVIDENCE_DIR}"

  # Save rollback evidence
  {
    echo "CUTOVER_STARTED=$(ts)"
    echo "SOURCE_MOUNT=$SOURCE_MOUNT"
    echo "STAGE_PATH=$STAGE_PATH"
    echo "EXPECTED_PART=$EXPECTED_PART"
    echo "EXPECTED_UUID=$EXPECTED_UUID"
    echo "REPO_ROOT=$REPO_ROOT"
  } >"${EVIDENCE_DIR}/cutover-meta.txt"
  cp -a "$FSTAB_PATH" "${EVIDENCE_DIR}/fstab.pre-cutover"
  [[ -f "$EFFECTIVE_MIRROR_CONF" ]] && cp -a "$EFFECTIVE_MIRROR_CONF" "${EVIDENCE_DIR}/mirror.conf.pre-cutover" || true
  [[ -f "$EFFECTIVE_DEFAULTS" ]] && cp -a "$EFFECTIVE_DEFAULTS" "${EVIDENCE_DIR}/ubuntu-offline-mirror.default.pre-cutover" || true
  [[ -f "$NGINX_SITE" ]] && cp -a "$NGINX_SITE" "${EVIDENCE_DIR}/nginx-site.pre-cutover" || true
  # Record ALLOW values
  {
    grep -E 'ALLOW_ROOT_FS_MIRROR' "$EFFECTIVE_DEFAULTS" 2>/dev/null || true
    grep -E 'ALLOW_ROOT_FS_MIRROR' "$EFFECTIVE_MIRROR_CONF" 2>/dev/null || true
  } >"${EVIDENCE_DIR}/allow-root.pre-cutover" || true

  # Mark evidence for rollback
  printf '%s\n' "$EVIDENCE_DIR" >"${EVIDENCE_ROOT}/LATEST_EVIDENCE" 2>/dev/null \
    || printf '%s\n' "$EVIDENCE_DIR" >"${EVIDENCE_DIR}/LATEST_EVIDENCE"

  local empty_mp_backup=""
  # shellcheck disable=SC2329
  cutover_fail() {
    local reason="$1"
    error "CUTOVER_FAILED: $reason — attempting automatic rollback"
    if cmd_rollback_internal; then
      die "CUTOVER_FAILED_AFTER_ROLLBACK reason=${reason}"
    else
      error "ROLLBACK_FAILED — manual recovery required"
      print_manual_recovery
      die "CUTOVER_AND_ROLLBACK_FAILED reason=${reason}"
    fi
  }

  # Before any service/mount/fstab mutation: only local :80/:443 count as inbound.
  # Outbound HTTPS (peer :443) must not block. Failures must not be treated as zero.
  assert_no_inbound_http_connections \
    || die "INBOUND_HTTP_CONNECTION_GUARD=FAIL (cutover not started; no nginx/mount/fstab mutation)"

  nginx_cmd stop || cutover_fail "nginx stop"

  local svc timer
  svc="$(get_unit_active_state apt-mirror.service)"
  timer="$(get_unit_active_state apt-mirror.timer)"
  [[ "$svc" == "inactive" ]] \
    || cutover_fail "apt-mirror.service must be inactive; actual=${svc}"
  [[ "$timer" == "inactive" ]] \
    || cutover_fail "apt-mirror.timer must be inactive; actual=${timer}"

  assert_no_sync_processes || cutover_fail "sync process present"
  stop_gpg_agents_on_mount "$SOURCE_MOUNT" || cutover_fail "gpg-agent stop"
  assert_no_user_handles "$SOURCE_MOUNT" || cutover_fail "open handles remain"

  # Final delta
  rsync_copy "$SOURCE_MOUNT" "$STAGE_PATH" 1 || cutover_fail "final rsync"
  verify_trees "$SOURCE_MOUNT" "$STAGE_PATH" || cutover_fail "tree verify"
  sync || true

  # Unmount
  is_mountpoint "$SOURCE_MOUNT" || cutover_fail "source is not a mountpoint before umount"
  do_umount "$SOURCE_MOUNT" || cutover_fail "umount"
  if is_mountpoint "$SOURCE_MOUNT"; then
    cutover_fail "still mounted after umount"
  fi

  # Underlying directory must be empty (allow lost+found only)
  local leftover
  leftover="$(find "$SOURCE_MOUNT" -mindepth 1 -maxdepth 1 ! -name lost+found 2>/dev/null | head -5 || true)"
  if [[ -n "$leftover" ]]; then
    cutover_fail "empty mountpoint directory not empty: $leftover"
  fi

  # fstab disable
  fstab_backup_and_disable_uuid "$EXPECTED_UUID" || cutover_fail "fstab disable"
  do_daemon_reload || cutover_fail "daemon-reload"

  # Same-FS rename guards
  local spool_parent stage_c empty_name
  spool_parent="$(dirname "$SOURCE_MOUNT")"
  stage_c="$(canonical_path "$STAGE_PATH")"
  [[ "$(fs_devno "$stage_c")" == "$(fs_devno "$spool_parent")" ]] \
    || cutover_fail "stage and /var/spool not on same filesystem"
  [[ ! -e "${SOURCE_MOUNT}.root-migrated" ]] || cutover_fail "unexpected leftover migrated path"

  empty_name="${SOURCE_MOUNT}.empty-mountpoint.$(date -u +%Y%m%dT%H%M%SZ)"
  empty_mp_backup="$empty_name"
  printf '%s\n' "$empty_name" >"${EVIDENCE_DIR}/empty-mountpoint-path.txt"

  # Preserve empty mountpoint dir, then rename stage -> service path
  mv "$SOURCE_MOUNT" "$empty_name" || cutover_fail "rename empty mountpoint aside"
  mv "$STAGE_PATH" "$SOURCE_MOUNT" || cutover_fail "atomic rename stage -> source mount path"
  printf '%s\n' "$SOURCE_MOUNT" >"${EVIDENCE_DIR}/live-root-spool.path"
  printf 'renamed\n' >"${EVIDENCE_DIR}/cutover-renamed.flag"

  # After rename, spool lives on root FS — update test devno map probe if present
  if [[ -n "${MIGRATE_TEST_DEVNO_MAP:-}" && -f "${MIGRATE_TEST_DEVNO_MAP}" ]]; then
    local root_devno
    root_devno="$(fs_devno "$spool_parent")"
    printf '%s %s\n' "$SOURCE_MOUNT" "$root_devno" >>"${MIGRATE_TEST_DEVNO_MAP}"
  fi
  if [[ -n "$FAKE_MOUNT_TABLE" && -f "$FAKE_MOUNT_TABLE" ]]; then
    local root_src
    root_src="$(path_source /)"
    printf '%s %s ext4\n' "$SOURCE_MOUNT" "${root_src:-/dev/mapper/rootlv}" >>"$FAKE_MOUNT_TABLE"
  fi

  set_allow_root_fs_mirror true || cutover_fail "ALLOW_ROOT_FS_MIRROR"

  if ! nginx_test; then cutover_fail "nginx -t after cutover"; fi
  nginx_cmd start || cutover_fail "nginx start"
  verify_live_spool "$SOURCE_MOUNT" || cutover_fail "live spool verify"
  if ! http_verify; then cutover_fail "http verify"; fi

  ok "CUTOVER=PASS"
  cat <<EOF
CUTOVER=PASS
SOURCE_MOUNT_NOW_ON_ROOT=YES
EMPTY_MOUNTPOINT_BACKUP=${empty_mp_backup}
EVIDENCE_DIR=${EVIDENCE_DIR}
FSTAB_MUTATION=YES
SERVICE_MUTATION=YES
DISK_MUTATION=YES
ALLOW_ROOT_FS_MIRROR=true
REBOOT_REQUIRED=OPERATOR_APPROVAL
ESXI_DETACH=NOT_PERFORMED
EOF
}

# ---------------------------------------------------------------------------
# Rollback
# ---------------------------------------------------------------------------
print_manual_recovery() {
  cat <<EOF >&2
MANUAL_RECOVERY_HINTS:
  1) Inspect evidence: ${EVIDENCE_DIR:-unknown}
  2) Restore fstab from: ${EVIDENCE_DIR:-/var/backups/...}/fstab.pre-cutover
  3) systemctl daemon-reload
  4) Ensure /var/spool/apt-mirror is the empty mountpoint directory
  5) mount UUID=${EXPECTED_UUID} ${SOURCE_MOUNT}
  6) Restore ALLOW_ROOT_FS_MIRROR from evidence *.pre-cutover
  7) nginx -t && systemctl start nginx
SOURCE_DISK_DATA should still be on ${EXPECTED_PART} if umount succeeded without wipe.
EOF
}

cmd_rollback_internal() {
  info "MODE=rollback-internal"
  [[ -n "$EVIDENCE_DIR" && -d "$EVIDENCE_DIR" ]] || {
    # try latest
    if [[ -f "${EVIDENCE_ROOT}/LATEST_EVIDENCE" ]]; then
      EVIDENCE_DIR="$(cat "${EVIDENCE_ROOT}/LATEST_EVIDENCE")"
    fi
  }
  [[ -n "$EVIDENCE_DIR" && -d "$EVIDENCE_DIR" ]] || {
    error "No evidence directory for rollback"
    return 1
  }

  nginx_cmd stop || true

  local empty_path live_backup
  empty_path="$(cat "${EVIDENCE_DIR}/empty-mountpoint-path.txt" 2>/dev/null || true)"
  live_backup="${SOURCE_MOUNT}.root-stage-failed.$(date -u +%Y%m%dT%H%M%SZ)"

  if [[ -f "${EVIDENCE_DIR}/cutover-renamed.flag" ]]; then
    if [[ -d "$SOURCE_MOUNT" ]] && ! is_mountpoint "$SOURCE_MOUNT"; then
      mv "$SOURCE_MOUNT" "$live_backup" || {
        error "Failed to move root spool aside to $live_backup"
        return 1
      }
      info "Preserved root spool at $live_backup"
    fi
    if [[ -n "$empty_path" && -d "$empty_path" ]]; then
      mv "$empty_path" "$SOURCE_MOUNT" || {
        error "Failed to restore empty mountpoint from $empty_path"
        return 1
      }
    else
      mkdir -p "$SOURCE_MOUNT"
    fi
  fi

  fstab_restore_from_evidence || return 1
  do_daemon_reload || return 1

  if ! is_mountpoint "$SOURCE_MOUNT"; then
    do_mount "UUID=${EXPECTED_UUID}" "$SOURCE_MOUNT" || do_mount "$EXPECTED_PART" "$SOURCE_MOUNT" || {
      error "Failed to remount candidate disk"
      return 1
    }
  fi

  # Restore ALLOW flags from backup files
  if [[ -f "${EVIDENCE_DIR}/ubuntu-offline-mirror.default.pre-cutover" && -f "$EFFECTIVE_DEFAULTS" ]]; then
    cp -a "${EVIDENCE_DIR}/ubuntu-offline-mirror.default.pre-cutover" "$EFFECTIVE_DEFAULTS"
  fi
  if [[ -f "${EVIDENCE_DIR}/mirror.conf.pre-cutover" && -f "$EFFECTIVE_MIRROR_CONF" ]]; then
    cp -a "${EVIDENCE_DIR}/mirror.conf.pre-cutover" "$EFFECTIVE_MIRROR_CONF"
  fi

  nginx_test || return 1
  nginx_cmd start || return 1
  http_verify || warn "HTTP verify after rollback reported issues"

  ok "ROLLBACK=PASS"
  return 0
}

cmd_rollback() {
  [[ "$EXECUTE" -eq 1 ]] || die "--rollback requires --execute"
  ensure_evidence_dir >/dev/null
  if [[ -f "${EVIDENCE_ROOT}/LATEST_EVIDENCE" ]]; then
    EVIDENCE_DIR="$(cat "${EVIDENCE_ROOT}/LATEST_EVIDENCE")"
  fi
  if cmd_rollback_internal; then
    cat <<EOF
ROLLBACK=PASS
SOURCE_DISK_DATA_PRESERVED=YES
EVIDENCE_DIR=${EVIDENCE_DIR}
EOF
  else
    print_manual_recovery
    die "ROLLBACK=FAIL"
  fi
}

# ---------------------------------------------------------------------------
# Verify / post-reboot
# ---------------------------------------------------------------------------
cmd_verify() {
  info "MODE=verify (read-only)"
  if [[ -d "$STAGE_PATH" && -d "$SOURCE_MOUNT" ]] && is_mountpoint "$SOURCE_MOUNT"; then
    verify_trees "$SOURCE_MOUNT" "$STAGE_PATH"
  elif [[ -d "$SOURCE_MOUNT" ]]; then
    verify_live_spool "$SOURCE_MOUNT"
  else
    die "Nothing to verify"
  fi
  ok "VERIFY=PASS"
  echo "VERIFY=PASS"
}

cmd_post_reboot_verify() {
  info "MODE=post-reboot-verify (read-only)"
  local src tgt
  src="$(path_source "$SOURCE_MOUNT")"
  tgt="$(path_target "$SOURCE_MOUNT")"
  local root_src
  root_src="$(path_source /)"

  [[ "$tgt" == "$SOURCE_MOUNT" || "$tgt" == "/" ]] || true
  [[ "$src" == "$root_src" ]] || die "Spool not on root LV (source=$src root=$root_src)"

  if is_mountpoint "$SOURCE_MOUNT" && [[ "$src" != "$root_src" ]]; then
    die "Candidate still mounted at spool path"
  fi

  # sdb1 should not be mounted
  if [[ "$TEST_MODE" == "1" ]]; then
    if [[ -n "$FAKE_MOUNT_TABLE" ]] && awk -v p="$EXPECTED_PART" '$2==p {found=1} END{exit !found}' "$FAKE_MOUNT_TABLE"; then
      die "Candidate partition still mounted per fake table"
    fi
  else
    if findmnt -n "$EXPECTED_PART" >/dev/null 2>&1; then
      die "$EXPECTED_PART is still mounted"
    fi
  fi

  if grep -qE "^[[:space:]]*UUID=${EXPECTED_UUID}[[:space:]]" "$FSTAB_PATH"; then
    die "fstab still has active candidate UUID entry"
  fi

  if [[ "$TEST_MODE" != "1" ]]; then
    systemctl is-active local-fs.target >/dev/null || die "local-fs.target not active"
    if systemctl --failed --no-legend 2>/dev/null | grep -q .; then
      warn "systemctl --failed reports units:"
      systemctl --failed --no-legend 2>/dev/null || true
    fi
    systemctl is-active nginx >/dev/null || die "nginx not active"
  fi

  nginx_test
  verify_live_spool "$SOURCE_MOUNT"
  key_metadata_line "$(private_key_path "$SOURCE_MOUNT")" >&2
  http_verify

  if [[ "$SKIP_GIT" != "1" ]]; then
    git_repo_ok
  fi

  local avail
  avail="$(root_avail_bytes)"
  [[ "$avail" -ge $((20 * 1024 * 1024 * 1024)) ]] || die "Root free space below 20GiB: $avail"

  ok "POST_REBOOT_VERIFY=PASS"
  cat <<EOF
POST_REBOOT_VERIFY=PASS
READY_FOR_POWER_OFF_AND_ESXI_DETACH=YES
SPOOL_SOURCE=${src}
CANDIDATE_MOUNTED=NO
FSTAB_ACTIVE_UUID=NO
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  assert_no_destructive_flags "$@"
  if [[ $# -lt 1 ]]; then
    usage
    exit 0
  fi

  local arg
  for arg in "$@"; do
    case "$arg" in
      --preflight) MODE=preflight ;;
      --initial-copy) MODE=initial-copy ;;
      --cutover) MODE=cutover ;;
      --verify) MODE=verify ;;
      --post-reboot-verify) MODE=post-reboot-verify ;;
      --rollback) MODE=rollback ;;
      --execute) EXECUTE=1 ;;
      --help|-h) usage; exit 0 ;;
      *)
        die "Unknown argument: $arg (see --help)"
        ;;
    esac
  done

  [[ -n "$MODE" ]] || { usage; exit 0; }

  case "$MODE" in
    preflight) cmd_preflight ;;
    initial-copy) cmd_initial_copy ;;
    cutover) cmd_cutover ;;
    verify) cmd_verify ;;
    post-reboot-verify) cmd_post_reboot_verify ;;
    rollback) cmd_rollback ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
