#!/usr/bin/env bash
# Regression: ACPS private helpers must never chmod host ancestors
# (field defect: /var -> 0700 via disk-preflight state under MM_STATE_DIR).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
DP2="${ROOT}/scripts/lib/dp-phase2-common.sh"
ACPS="${ROOT}/scripts/lib/acps_acquire.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

mode_of() { stat -c '%a' "$1"; }

assert_mode() {
  local path="$1" want="$2"
  local got
  got="$(mode_of "$path")"
  [[ "$got" == "$want" ]] || fail "mode path=${path} got=${got} want=${want}"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Production-shaped hermetic layout under $tmp/var.
export MM_PROJECT_ROOT="$ROOT"
export MM_MIRROR_ROOT="${TMP}/var/spool/apt-mirror"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export MM_STATE_DIR="${TMP}/var/lib/ubuntu-mirror-automation/runs/test-run"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_CLIENT_ROOT="${MM_MIRROR_ROOT}/client"
export MM_SELECTIVE_ROOT="${MM_MIRROR_ROOT}/selective"
export MM_LOG_DIR="${TMP}/logs"
export MM_CONFIG_DIR="${TMP}/config"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/config"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_SKIP_ROOT_CHECK=1

HOST_VAR="${TMP}/var"
HOST_VAR_LIB="${TMP}/var/lib"

mkdir -p "$MM_CACHE_ROOT" "$MM_STATE_DIR" "$MM_CONFIG_DIR" "$MM_LOG_DIR" \
  "$MM_DP_PHASE2_ROOT" "$MM_CLIENT_ROOT" "$MM_SELECTIVE_ROOT"
chmod 0755 "$HOST_VAR" "$HOST_VAR_LIB"
: >"$MM_STATUS_FILE"

# shellcheck source=/dev/null
source "$COMMON"
# shellcheck source=/dev/null
source "$DP2"
# shellcheck source=/dev/null
source "$ACPS"

DP_PHASE2_VERSION=6.6.0
TARGET_DP_VERSION=6.6.0
dp2_set_version 6.6.0

# ---------------------------------------------------------------------------
# A. State-dir regression — verified-cache recorder must not touch /var.
# ---------------------------------------------------------------------------
seed_verified_cache() {
  local dir="$1"
  mkdir -p "$dir"
  local f
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    printf 'payload-%s\n' "$f" >"${dir}/${f}"
  done
  truncate -s 4096 "${dir}/images-6.6.0.tar"
  sha1sum "${dir}/aelladeb_py3_common.tar.gz" | awk '{print $1}' \
    >"${dir}/aelladeb_py3_common.tar.gz.sha1"
  sha1sum "${dir}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}' \
    >"${dir}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
  sha1sum "${dir}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
    >"${dir}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  sha256sum "${dir}/images-6.6.0.tar" | awk '{print $1 "  images-6.6.0.tar"}' \
    >"${dir}/images-6.6.0.tar.sha256"
  seq 1 2 >"${dir}/images-6.6.0.list"
  mm_acps_verify_payload_checksums "$dir" >/dev/null
  acps_write_verified_marker "$dir" || fail "write verified marker"
}

CACHE="$(acps_cache_dir 6.6.0)"
seed_verified_cache "$CACHE"
chmod 0755 "$HOST_VAR" "$HOST_VAR_LIB"
rm -f "$(acps_disk_preflight_state_file 6.6.0)"
acps_record_verified_cache_disk_state 6.6.0 >/dev/null \
  || fail "record verified cache disk state failed"
assert_mode "$HOST_VAR" "755"
assert_mode "$HOST_VAR_LIB" "755"
assert_mode "$MM_STATE_DIR" "700"
STATE_FILE="$(acps_disk_preflight_state_file 6.6.0)"
[[ -f "$STATE_FILE" ]] || fail "state file missing"
assert_mode "$STATE_FILE" "600"
pass "A state-dir verified-cache recorder leaves host ancestors 0755"

# ---------------------------------------------------------------------------
# B. Direct boundary rejection — outside MM_CACHE_ROOT must fail closed.
# ---------------------------------------------------------------------------
chmod 0755 "$HOST_VAR" "$HOST_VAR_LIB"
if acps_ensure_private_cache_dir "$MM_STATE_DIR" 2>/dev/null; then
  fail "outside-cache path must fail closed"
fi
assert_mode "$HOST_VAR" "755"
assert_mode "$HOST_VAR_LIB" "755"
pass "B outside cache path rejected; host ancestors untouched"

# ---------------------------------------------------------------------------
# C. Valid cache path
# ---------------------------------------------------------------------------
chmod 0755 "$HOST_VAR" "$HOST_VAR_LIB"
acps_ensure_private_cache_dir "${MM_CACHE_ROOT}/acps/6.6.0" \
  || fail "valid cache path rejected"
assert_mode "${MM_CACHE_ROOT}/acps" "700"
assert_mode "${MM_CACHE_ROOT}/acps/6.6.0" "700"
assert_mode "$HOST_VAR" "755"
assert_mode "$HOST_VAR_LIB" "755"
# Cache root and mirror root must remain untouched by the walker.
[[ "$(mode_of "$MM_CACHE_ROOT")" != "700" ]] \
  || fail "MM_CACHE_ROOT must not be forced to 0700 by cache helper"
pass "C valid cache path enforces private modes inside boundary"

# ---------------------------------------------------------------------------
# D. Valid work path
# ---------------------------------------------------------------------------
WORK="${MM_CACHE_ROOT}/acps-work/6.6.0/test-run"
chmod 0755 "$HOST_VAR" "$HOST_VAR_LIB"
acps_ensure_private_cache_dir "$WORK" || fail "valid work path rejected"
assert_mode "${MM_CACHE_ROOT}/acps-work" "700"
assert_mode "${MM_CACHE_ROOT}/acps-work/6.6.0" "700"
assert_mode "$WORK" "700"
assert_mode "$HOST_VAR" "755"
assert_mode "$HOST_VAR_LIB" "755"
pass "D valid work path enforces private modes inside boundary"

# ---------------------------------------------------------------------------
# E. Path escape tests — all must fail closed without mutating hosts.
# ---------------------------------------------------------------------------
escape_cases=(
  "${MM_CACHE_ROOT}/acps/../../../../var/lib/ubuntu-mirror-automation/runs/test-run"
  "${MM_CACHE_ROOT}/acps-extra/6.6.0"
  "${MM_CACHE_ROOT}/acps-work-evil/x"
  "${HOST_VAR}/lib"
  "${MM_MIRROR_ROOT}"
  "${MM_CACHE_ROOT}"
  "/"
)
for p in "${escape_cases[@]}"; do
  chmod 0755 "$HOST_VAR" "$HOST_VAR_LIB"
  if acps_ensure_private_cache_dir "$p" 2>/dev/null; then
    fail "escape path must fail closed: ${p}"
  fi
  assert_mode "$HOST_VAR" "755"
  assert_mode "$HOST_VAR_LIB" "755"
done
pass "E lexical/prefix/normalized escapes fail closed"

# Symlink escape: plant a link under acps that points at host state.
LINK_ESCAPE="${MM_CACHE_ROOT}/acps/link-escape"
rm -rf "$LINK_ESCAPE"
ln -s "$MM_STATE_DIR" "$LINK_ESCAPE"
chmod 0755 "$HOST_VAR" "$HOST_VAR_LIB"
chmod 0755 "$MM_STATE_DIR" 2>/dev/null || true
state_mode_before="$(mode_of "$MM_STATE_DIR")"
if acps_ensure_private_cache_dir "${LINK_ESCAPE}/nested" 2>/dev/null; then
  fail "symlink escape must fail closed"
fi
assert_mode "$HOST_VAR" "755"
assert_mode "$HOST_VAR_LIB" "755"
assert_mode "$MM_STATE_DIR" "$state_mode_before"
pass "E symlink escape fails closed without mutating target"

# ---------------------------------------------------------------------------
# F. First-run disk-preflight contract (collect path, not verified reuse).
# ---------------------------------------------------------------------------
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
# Mock remote Content-Length for first-run disk preflight (no real download).
url="${!#}"
case "$url" in
  */aelladeb_py3_common.tar.gz) n=1000 ;;
  */aella-uvp-2404_6.6.0ubuntu1_amd64.deb) n=2000 ;;
  */bringup_py3_dp_after_os_upgrade.sh) n=3000 ;;
  */images-6.6.0.tar) n=4000 ;;
  */images-6.6.0.tar.sha256) n=64 ;;
  */images-6.6.0.list) n=32 ;;
  */*.sha1) n=40 ;;
  *) n=128 ;;
esac
printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "$n"
EOF_CURL
chmod +x "${TMP}/bin/curl"
PATH="${TMP}/bin:${PATH}"
ACPS_CURL_AUTH_ARGS=()
ACPS_CURL_TLS_ARGS=()

# Fresh first-run: no verified credit; exercise collect_disk_preflight_state.
rm -rf "$CACHE"
mkdir -p "$CACHE"
rm -f "$(acps_disk_preflight_state_file 6.6.0)"
chmod 0755 "$HOST_VAR" "$HOST_VAR_LIB"
chmod 0755 "$MM_STATE_DIR" 2>/dev/null || true

expected="$(acps_expected_bytes_hint "http://fixture")"
[[ "$expected" =~ ^[1-9][0-9]*$ ]] || fail "first-run expected bytes missing"
acps_load_disk_preflight_state "$expected" "$DP_PHASE2_VERSION"
[[ -f "$(acps_disk_preflight_state_file 6.6.0)" ]] \
  || fail "first-run state file not written"
assert_mode "$HOST_VAR" "755"
assert_mode "$HOST_VAR_LIB" "755"
assert_mode "$MM_STATE_DIR" "700"
assert_mode "$(acps_disk_preflight_state_file 6.6.0)" "600"
pass "F first-run disk-preflight leaves host ancestors 0755"

# Direct collect path (same first-run helper, no load wrapper).
rm -f "$(acps_disk_preflight_state_file 6.6.0)"
chmod 0755 "$HOST_VAR" "$HOST_VAR_LIB"
chmod 0755 "$MM_STATE_DIR" 2>/dev/null || true
acps_collect_disk_preflight_state "http://fixture" 6.6.0 >/dev/null \
  || fail "collect_disk_preflight_state failed"
assert_mode "$HOST_VAR" "755"
assert_mode "$HOST_VAR_LIB" "755"
assert_mode "$MM_STATE_DIR" "700"
assert_mode "$(acps_disk_preflight_state_file 6.6.0)" "600"
pass "F collect_disk_preflight_state host-ancestor contract"

echo "ALL ACPS PRIVATE PATH BOUNDARY TESTS PASSED"
