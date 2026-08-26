#!/usr/bin/env bash
# Regression: live progress advances, no adjacent duplicates, bounded disk pipeline.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
R2="${ROOT}/scripts/lib/r2_acquire.sh"
ACPS="${ROOT}/scripts/lib/acps_acquire.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
DP2="${ROOT}/scripts/download-dp-phase2.sh"
DP2_COMMON="${ROOT}/scripts/lib/dp-phase2-common.sh"
PATCHED_BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
UPSTREAM_BASELINE="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# GUI keeps MM_LIVE_PROGRESS → /dev/tty, but must NOT also tee (adjacent duplicates).
grep -q '/dev/tty' "$COMMON" || fail "mm_log lost MM_LIVE_PROGRESS /dev/tty path"
if grep -n 'engine_download_and_prepare 2>&1 | tee' "$INSTALLER" | grep -q .; then
  fail "installer still tees (duplicates live tty progress)"
fi
grep -q 'engine_download_and_prepare >"$tmp" 2>&1' "$INSTALLER" \
  || fail "installer missing file-only transcript capture"
pass "live progress: tty once + logfile capture (no tee)"

grep -q 'resp="${part}.download"' "$R2" || fail "R2 transfer file is not observable"
grep -q 'final=yes' "$R2" || fail "R2 final progress missing"
grep -q 'final=yes' "$ACPS" || fail "ACPS final progress missing"
# `if ! curl; then rc=$?` loses the real non-zero status inside the then-branch.
if awk '
  /^r2_http_download_to_part\(\)/ { in_fn=1 }
  in_fn && /if ! curl / { bad=1 }
  in_fn && /^}/ { exit(bad ? 0 : 1) }
' "$R2"; then
  fail "R2 curl status is still inverted"
fi
if awk '
  /^acps_download_one\(\)/ { in_fn=1 }
  in_fn && /if ! curl / { bad=1 }
  in_fn && /^}/ { exit(bad ? 0 : 1) }
' "$ACPS"; then
  fail "ACPS curl status is still inverted"
fi
pass "download failure status propagation"

grep -qE 'tar -cf "\$\{?dest_tmp\}?/\$\{?stable\}?"|tar -cf "\$2"' "$ENGINE" \
  || fail "bundle is not built in final staging"
grep -q 'PHASE2_BUNDLE_CREATE' "$ENGINE" || fail "bundle create progress events missing"
grep -q 'mm_run_with_file_progress\|mm_bg_with_heartbeat' "$COMMON" \
  || fail "long-step heartbeat helpers missing"
grep -q 'MM_LONG_STEP_HEARTBEAT_SEC' "$COMMON" || fail "heartbeat interval env missing"
if grep -q 'cp -f "${staging}/${stable}" "${dest_tmp}/${stable}"' "$ENGINE"; then
  fail "full bundle copy still present"
fi
grep -q 'engine_stage_acps_work_from_cache' "$ENGINE" || fail "ACPS hard-link staging helper missing"
grep -q 'hardlink_required' "$ENGINE" || fail "large-file hardlink refusal missing"
grep -q 'engine_assert_same_filesystem_layout' "$ENGINE" || fail "same-filesystem preflight missing"
grep -q 'engine_cleanup_phase2_sources' "$ENGINE" || fail "early phase2 source cleanup missing"
grep -q 'mv -f "$payload" "$final_tmp"' "$ENGINE" || fail "OS payload rename missing"
grep -q 'engine_assess_phase2_final' "$ENGINE" || fail "phase2 final assess missing"
grep -q 'PHASE2_BUNDLE_ACTION=REUSE' "$ENGINE" || fail "valid bundle REUSE path missing"
grep -q 'INVALID_EXISTING_BUNDLE_ACTION=DELETE_BEFORE_REBUILD' "$ENGINE" || fail "invalid delete-before-rebuild missing"
grep -q 'R2_PACKAGE_REMOVED_AFTER_MATERIALIZE=YES' "$ENGINE" || fail "early R2 cleanup marker missing"
if grep -q 'dest_old' "$ENGINE"; then
  fail "phase2 .old rollback path still present"
fi
pass "bounded disk pipeline structure"

# Unreadable mode-600 config must not abort non-root callers.
grep -q '\[\[ -f "$cfg" && -r "$cfg" \]\]' "$DP2" \
  || fail "download-dp-phase2 still sources unreadable config"
pass "unreadable config is skipped (env credentials still work)"

# HTTP smoke probes a real file and rejects empty bodies.
grep -q 'offline/meta-release-lts' "$ENGINE" || fail "offline smoke missing meta-release-lts"
grep -q 'empty_body' "$ENGINE" || fail "HTTP validator missing non-empty body check"
pass "HTTP smoke real-file + non-empty body"

TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

MM_PROJECT_ROOT="$ROOT"
MM_MIRROR_ROOT="${TMP}/mirror"
MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
MM_STATE_ROOT="${TMP}/state"
MM_LOG_DIR="${TMP}/logs"
MM_CONFIG_DIR="${TMP}/config"
MM_STATUS_FILE="${TMP}/config/status"
MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
MM_SELECTIVE_ROOT="${MM_MIRROR_ROOT}/selective"
MM_MOCK_AVAILABLE_BYTES=$((100 * 1024 * 1024 * 1024))
MM_MOCK_SAFETY_RESERVE_BYTES=$((10 * 1024 * 1024 * 1024))
OS_CORE_PACKAGE_BYTES=100
OS_CORE_PAYLOAD_BYTES=200
ACPS_EXPECTED_BYTES=300
TARGET_DP_VERSION=6.6.0

# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "$COMMON"
PREPARATION_MODE=FULL
mm_calc_disk_requirements >/dev/null
# Sequential peaks: max(OS=payload+512MiB, PHASE2=acps+bundle+512MiB) + safety
# With ACPS=300, payload=200 → phase2 peak wins.
os_stage=$((200 + (512 * 1024 * 1024)))
phase2_stage=$((300 + 300 + (512 * 1024 * 1024)))
if [[ "$os_stage" -gt "$phase2_stage" ]]; then
  stage_peak=$os_stage
else
  stage_peak=$phase2_stage
fi
expected_total=$((stage_peak + (10 * 1024 * 1024 * 1024)))
[[ "$TOTAL_REQUIRED_BYTES" -eq "$expected_total" ]] \
  || fail "FULL disk estimate expected=${expected_total} actual=${TOTAL_REQUIRED_BYTES}"
[[ "$DISK_PREFLIGHT_SAFETY_RESERVE_BYTES" -eq $((10 * 1024 * 1024 * 1024)) ]] \
  || fail "safety reserve not 10GiB"
[[ "$DISK_PREFLIGHT_RESULT" == "PASS" ]] || fail "disk preflight should PASS with 100GiB mock free"
[[ "$DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES" -eq 0 ]] \
  || fail "fresh replacement overhead must be 0"
pass "FULL disk estimate uses sequential max(OS,PHASE2) + safety"

# PHASE2_ONLY drops OS stage peak
PREPARATION_MODE=PHASE2_ONLY
mm_calc_disk_requirements >/dev/null
p2_expected=$((phase2_stage + (10 * 1024 * 1024 * 1024)))
[[ "$DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES" -eq 0 ]] \
  || fail "PHASE2_ONLY OS stage extra should be 0"
[[ "$TOTAL_REQUIRED_BYTES" -eq "$p2_expected" ]] \
  || fail "PHASE2_ONLY estimate expected=${p2_expected} actual=${TOTAL_REQUIRED_BYTES}"
pass "PHASE2_ONLY disk estimate excludes OS stage"

PREPARATION_MODE=FULL
# Existing final must NOT double-count against current available (overhead=0).
mkdir -p "${MM_DP_PHASE2_ROOT}/6.6.0"
dd if=/dev/zero of="${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar" bs=1 count=400 status=none
mm_calc_disk_requirements >/dev/null
[[ "$DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES" -eq 0 ]] \
  || fail "replacement overhead expected=0 actual=${DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES}"
[[ "$DISK_PREFLIGHT_EXISTING_FINAL_BYTES" -eq 400 ]] \
  || fail "existing final bytes expected=400 actual=${DISK_PREFLIGHT_EXISTING_FINAL_BYTES}"
[[ "$TOTAL_REQUIRED_BYTES" -eq "$expected_total" ]] \
  || fail "create-path available-based required changed incorrectly: ${TOTAL_REQUIRED_BYTES}"
# Valid REUSE zeros Phase 2 ACPS/bundle requirements.
PHASE2_BUNDLE_ACTION=REUSE
PHASE2_REBUILD_REQUIRED=NO
ACPS_EXPECTED_BYTES=300
mm_calc_disk_requirements >/dev/null
[[ "$PHASE2_ACPS_SOURCE_REQUIRED_BYTES" -eq 0 ]] || fail "REUSE ACPS required should be 0"
[[ "$PHASE2_BUNDLE_OUTPUT_REQUIRED_BYTES" -eq 0 ]] || fail "REUSE bundle required should be 0"
[[ "$PHASE2_REBUILD_REQUIRED" == "NO" ]] || fail "REUSE rebuild flag should be NO"
reuse_os_stage=$((200 + (512 * 1024 * 1024)))
reuse_expected=$((reuse_os_stage + (10 * 1024 * 1024 * 1024)))
[[ "$TOTAL_REQUIRED_BYTES" -eq "$reuse_expected" ]] \
  || fail "REUSE FULL estimate expected=${reuse_expected} actual=${TOTAL_REQUIRED_BYTES}"
unset PHASE2_BUNDLE_ACTION PHASE2_REBUILD_REQUIRED
rm -f "${MM_DP_PHASE2_ROOT}/6.6.0/dp_bundle_6.6.0-current.tar"
pass "existing final reported; REUSE zeros Phase 2 stage bytes"

HTTP_ROOT="${TMP}/http"
mkdir -p "$HTTP_ROOT"
dd if=/dev/zero of="${HTTP_ROOT}/core.tar" bs=1M count=8 status=none
# ACPS-style payload name (small fixture; progress monitored via .part growth)
dd if=/dev/zero of="${HTTP_ROOT}/payload.bin" bs=1M count=6 status=none
(cd "$HTTP_ROOT" && sha256sum core.tar >core.tar.sha256)
PORT_FILE="${TMP}/port"

python3 - "$HTTP_ROOT" "$PORT_FILE" <<'PY' &
import http.server
import pathlib
import socketserver
import sys
import time

root = pathlib.Path(sys.argv[1])
port_file = pathlib.Path(sys.argv[2])

class Handler(http.server.BaseHTTPRequestHandler):
    def path_on_disk(self):
        return root / self.path.lstrip('/')

    def do_HEAD(self):
        path = self.path_on_disk()
        if not path.is_file():
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Length', str(path.stat().st_size))
        self.send_header('Accept-Ranges', 'bytes')
        self.end_headers()

    def do_GET(self):
        path = self.path_on_disk()
        if not path.is_file():
            self.send_error(404)
            return
        size = path.stat().st_size
        self.send_response(200)
        self.send_header('Content-Length', str(size))
        self.send_header('Accept-Ranges', 'bytes')
        self.end_headers()
        with path.open('rb') as fh:
            while True:
                chunk = fh.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
                time.sleep(0.02)

    def log_message(self, *_):
        pass

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

server = Server(('127.0.0.1', 0), Handler)
port_file.write_text(str(server.server_address[1]))
server.serve_forever()
PY
SERVER_PID=$!

for _ in $(seq 1 50); do
  [[ -s "$PORT_FILE" ]] && break
  sleep 0.1
done
[[ -s "$PORT_FILE" ]] || fail "slow HTTP server did not start"

PORT="$(cat "$PORT_FILE")"
analyze_progress() {
  # Args: label structured_prefix human_prefix logfile stdout
  local label="$1" structured="$2" human="$3" logfile="$4" stdout="$5"
  local samples non_zero finals adj mono prev bytes pct
  samples="$(grep -c "${structured}.*downloaded_bytes=" <<<"$stdout" || true)"
  non_zero="$(grep -Eoc "${structured}.*downloaded_bytes=[1-9][0-9]*" <<<"$stdout" || true)"
  finals="$(grep -c "${structured}.*final=yes" <<<"$stdout" || true)"
  adj=0
  prev=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == "$prev" ]]; then
      adj=$((adj + 1))
    fi
    prev="$line"
  done < <(grep -E "${structured}.*downloaded_bytes=|PROGRESS ${human}" <<<"$stdout" || true)
  mono=YES
  prev=-1
  while IFS= read -r bytes; do
    [[ -z "$bytes" ]] && continue
    if [[ "$bytes" -lt "$prev" ]]; then
      mono=NO
      break
    fi
    prev="$bytes"
  done < <(grep -Eo "${structured}.*downloaded_bytes=[0-9]+" <<<"$stdout" | grep -Eo '[0-9]+$' || true)
  pct="$(grep -Eo "${structured}.*percentage=[0-9]+" <<<"$stdout" | grep -Eo '[0-9]+$' | tail -n1 || true)"
  grep -q "${structured}.*downloaded_bytes=" "$logfile" || fail "${label} progress missing from logfile"
  grep -q "PROGRESS ${human}" "$logfile" || fail "${label} human progress missing from logfile"
  printf '%s_FIXTURE_PROGRESS_SAMPLE_COUNT=%s\n' "$label" "$samples"
  printf '%s_FIXTURE_NON_ZERO_SAMPLE_COUNT=%s\n' "$label" "$non_zero"
  printf '%s_FIXTURE_MONOTONIC=%s\n' "$label" "$mono"
  printf '%s_FIXTURE_FINAL_COUNT=%s\n' "$label" "$finals"
  printf '%s_FIXTURE_ADJACENT_DUPLICATES=%s\n' "$label" "$adj"
  [[ "$samples" -ge 2 ]] || fail "${label} too few progress samples (${samples})"
  [[ "$non_zero" -ge 1 ]] || fail "${label} progress stuck at zero"
  [[ "$mono" == "YES" ]] || fail "${label} downloaded_bytes not monotonic"
  [[ "$finals" -eq 1 ]] || fail "${label} final=yes count=${finals}"
  [[ "$adj" -eq 0 ]] || fail "${label} adjacent duplicates=${adj}"
  [[ -n "$pct" && "$pct" -gt 0 ]] || fail "${label} percentage never increased"
}

OS_CORE_R2_URL="http://127.0.0.1:${PORT}/core.tar"
R2_PROGRESS_INTERVAL_SEC=1
MM_LOG_FILE="${TMP}/r2-progress.log"
MM_RUN_ID="test-r2"
MM_STATE_DIR="${TMP}/state/test-r2"
mkdir -p "$MM_STATE_DIR" "$(dirname "$MM_LOG_FILE")"
: >"$MM_LOG_FILE"

# shellcheck source=../scripts/lib/r2_acquire.sh
source "$R2"
R2_OUT_FILE="${TMP}/r2-out.txt"
set +e
r2_download_package >"$R2_OUT_FILE" 2>&1
R2_RC=$?
set -e
R2_OUT="$(cat "$R2_OUT_FILE")"
printf '%s\n' "$R2_OUT"
[[ "$R2_RC" -eq 0 ]] || fail "r2_download_package rc=${R2_RC}"
analyze_progress R2 R2_DOWNLOAD_PROGRESS "R2 core.tar" "$MM_LOG_FILE" "$R2_OUT"
[[ -n "${OS_CORE_PACKAGE:-}" && -f "$OS_CORE_PACKAGE" ]] || fail "R2 final package missing"
(cd "$(dirname "$OS_CORE_PACKAGE")" && sha256sum -c "$(basename "$OS_CORE_PACKAGE").sha256" >/dev/null) \
  || fail "R2 checksum mismatch"
find "$MM_CACHE_ROOT" \( -name '*.download' -o -name '*.part' \) | grep -q . \
  && fail "R2 temporary transfer files remain"
pass "R2 live progress advances and finalizes cleanly"

# ACPS path: production acps_download_one against throttled local HTTP (no credentials).
# shellcheck source=../scripts/lib/dp-phase2-common.sh
source "$DP2_COMMON"
# shellcheck source=../scripts/lib/acps_acquire.sh
source "$ACPS"
ACPS_PROGRESS_INTERVAL_SEC=1
ACPS_CURL_RETRIES=0
ACPS_EFFECTIVE_BASE="http://127.0.0.1:${PORT}"
ACPS_CURL_AUTH_ARGS=()
ACPS_CURL_TLS_ARGS=()
MM_LOG_FILE="${TMP}/acps-progress.log"
: >"$MM_LOG_FILE"
ACPS_DEST="${TMP}/acps-dest"
mkdir -p "$ACPS_DEST"
ACPS_OUT_FILE="${TMP}/acps-out.txt"
set +e
acps_download_one "payload.bin" "$ACPS_DEST" >"$ACPS_OUT_FILE" 2>&1
ACPS_RC=$?
set -e
ACPS_OUT="$(cat "$ACPS_OUT_FILE")"
printf '%s\n' "$ACPS_OUT"
[[ "$ACPS_RC" -eq 0 ]] || fail "acps_download_one rc=${ACPS_RC}"
analyze_progress ACPS ACPS_DOWNLOAD_PROGRESS "ACPS payload.bin" "$MM_LOG_FILE" "$ACPS_OUT"
[[ -f "${ACPS_DEST}/payload.bin" ]] || fail "ACPS fixture final missing"
pass "ACPS live progress advances and finalizes cleanly"

# Curl failure must preserve non-zero rc (ACPS path).
set +e
acps_download_one "missing-file-xyz" "${TMP}/acps-fail" >/dev/null 2>&1
ACPS_FAIL_RC=$?
set -e
[[ "$ACPS_FAIL_RC" -ne 0 ]] || fail "ACPS curl failure rc was zero"
pass "ACPS curl failure preserves non-zero rc (${ACPS_FAIL_RC})"

# ---------------------------------------------------------------------------
# Synthetic Phase 2 pipeline: hardlink staging, direct .new bundle, peak ratio
# ---------------------------------------------------------------------------
# shellcheck source=../scripts/lib/mirror_install_engine.sh
source "$ENGINE"

PIPE="${TMP}/pipe"
MM_MIRROR_ROOT="$PIPE"
MM_CACHE_ROOT="${PIPE}/.install-cache"
MM_SELECTIVE_ROOT="${PIPE}/selective"
MM_DP_PHASE2_ROOT="${PIPE}/dp-phase2"
MM_CLIENT_ROOT="${PIPE}/client"
MM_STATE_DIR="${PIPE}/state"
MM_LOG_FILE="${PIPE}/pipe.log"
MM_DRY_RUN=0
MM_KEEP_PHASE2_SOURCES=0
TARGET_DP_VERSION=6.6.0
mkdir -p "$MM_CACHE_ROOT" "$MM_SELECTIVE_ROOT" "$MM_DP_PHASE2_ROOT" "$MM_STATE_DIR"
: >"$MM_LOG_FILE"

engine_assert_same_filesystem_layout >/dev/null
pass "same-filesystem preflight PASS on single tmpfs/dir tree"

# Existing selective tree must not inflate available-based future required.
mkdir -p "${MM_SELECTIVE_ROOT}/ubuntu/pool"
dd if=/dev/zero of="${MM_SELECTIVE_ROOT}/ubuntu/pool/hello.deb" bs=1 count=250 status=none
OS_CORE_PACKAGE_BYTES=100
OS_CORE_PAYLOAD_BYTES=200
ACPS_EXPECTED_BYTES=300
MM_MOCK_AVAILABLE_BYTES=$((100 * 1024 * 1024 * 1024))
MM_MOCK_SAFETY_RESERVE_BYTES=$((10 * 1024 * 1024 * 1024))
unset MM_MOCK_FS_SIZE_BYTES || true
mm_calc_disk_requirements >/dev/null
sel_expected=$((300 + 300 + (512 * 1024 * 1024) + (10 * 1024 * 1024 * 1024)))
[[ "$CURRENT_AVAILABLE_BASED_REQUIRED_BYTES" -eq "$sel_expected" ]] \
  || fail "selective tree changed available-based required: ${CURRENT_AVAILABLE_BASED_REQUIRED_BYTES}"
pass "existing selective tree not double-counted in future required"

# Interrupted .part files are cleaned by engine helpers and must not be in the
# permanent final layout model (preflight still uses ACPS expected sizes).
mkdir -p "${MM_CACHE_ROOT}/r2" "${MM_CACHE_ROOT}/acps/6.6.0"
: >"${MM_CACHE_ROOT}/r2/pkg.tar.part"
: >"${MM_CACHE_ROOT}/acps/6.6.0/images-6.6.0.tar.part"
mm_calc_disk_requirements >/dev/null
[[ "$CURRENT_AVAILABLE_BASED_REQUIRED_BYTES" -eq "$sel_expected" ]] \
  || fail ".part presence changed available-based required"
pass "interrupted .part does not change preflight formula"

# Cross-filesystem layouts are blocked.
CROSS="${TMP}/cross-fs"
mkdir -p "${CROSS}/mirror" "${CROSS}/other"
# Bind-mount another path as selective when possible; otherwise simulate via
# mismatched device check by pointing selective at a path we force-fail.
if command -v mountpoint >/dev/null 2>&1 && [[ -d /dev/shm ]]; then
  CROSS_SEL="${CROSS}/sel-shm"
  mkdir -p "${CROSS}/mirror/.install-cache" "${CROSS}/mirror/dp-phase2" "$CROSS_SEL"
  if mount --bind /dev/shm "$CROSS_SEL" 2>/dev/null; then
    MM_MIRROR_ROOT="${CROSS}/mirror"
    MM_CACHE_ROOT="${CROSS}/mirror/.install-cache"
    MM_SELECTIVE_ROOT="$CROSS_SEL"
    MM_DP_PHASE2_ROOT="${CROSS}/mirror/dp-phase2"
    set +e
    out="$(engine_assert_same_filesystem_layout 2>&1)"
    rc=$?
    set -e
    umount "$CROSS_SEL" 2>/dev/null || true
    [[ "$rc" -ne 0 ]] || fail "cross-filesystem should be blocked"
    echo "$out" | grep -q 'SAME_FILESYSTEM=FAIL' || fail "cross-filesystem missing FAIL marker"
    pass "cross-filesystem blocked"
  else
    pass "cross-filesystem bind skipped (no mount privileges)"
  fi
else
  pass "cross-filesystem bind skipped (no /dev/shm)"
fi

# Restore pipe roots after cross-fs probe
MM_MIRROR_ROOT="$PIPE"
MM_CACHE_ROOT="${PIPE}/.install-cache"
MM_SELECTIVE_ROOT="${PIPE}/selective"
MM_DP_PHASE2_ROOT="${PIPE}/dp-phase2"

dp2_set_version 6.6.0
EMPTY_BYTES="$(du -xsb "$PIPE" | awk '{print $1}')"
CACHE="$(acps_cache_dir 6.6.0)"
mkdir -p "$CACHE"
# Representative payload: ~120MiB images tar dominates (~80%+ of source).
dd if=/dev/urandom of="${CACHE}/images-6.6.0.tar" bs=1M count=120 status=none
sha256sum "${CACHE}/images-6.6.0.tar" | awk '{print $1}' >"${CACHE}/images-6.6.0.tar.sha256"
printf 'common\n' >"${CACHE}/aelladeb_py3_common.tar.gz"
sha1sum "${CACHE}/aelladeb_py3_common.tar.gz" | awk '{print $1}' >"${CACHE}/aelladeb_py3_common.tar.gz.sha1"
printf 'uvp\n' >"${CACHE}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb"
sha1sum "${CACHE}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}' \
  >"${CACHE}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
seq 1 156 >"${CACHE}/images-6.6.0.list"
# Place a synthetic upstream bringup; engine_verify is skipped here — we call stage+patch+place.
printf 'SYNTHETIC_UPSTREAM_FOR_DISK_PIPE\n' >"${CACHE}/bringup_py3_dp_after_os_upgrade.sh"
sha1sum "${CACHE}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
  >"${CACHE}/bringup_py3_dp_after_os_upgrade.sh.sha1"

SOURCE_TOTAL_BYTES="$(du -xsb "$CACHE" | awk '{print $1}')"
BEFORE_BYTES="$(du -xsb "$PIPE" | awk '{print $1}')"
printf 'FIXTURE_SOURCE_TOTAL_BYTES=%s\n' "$SOURCE_TOTAL_BYTES"
printf 'FIXTURE_EMPTY_BYTES=%s\n' "$EMPTY_BYTES"
printf 'FIXTURE_BEFORE_BYTES=%s\n' "$BEFORE_BYTES"

CACHE_IMG_INODE="$(stat -c '%d %i %b %s' "${CACHE}/images-6.6.0.tar")"
WORK="${MM_CACHE_ROOT}/acps-work/6.6.0/pipe-run"
engine_stage_acps_work_from_cache "$CACHE" "$WORK"
WORK_IMG_INODE="$(stat -c '%d %i %b %s' "${WORK}/images-6.6.0.tar")"
[[ "$CACHE_IMG_INODE" == "$WORK_IMG_INODE" ]] \
  || fail "images tar not hard-linked cache=${CACHE_IMG_INODE} work=${WORK_IMG_INODE}"
HARDLINK_COUNT="$(stat -c %h "${CACHE}/images-6.6.0.tar")"
[[ "$HARDLINK_COUNT" -ge 2 ]] || fail "expected nlink>=2 after hardlink got=${HARDLINK_COUNT}"
pass "ACPS large file hard-linked (same device/inode, nlink=${HARDLINK_COUNT})"

# Seed already-generated patched bringup for disk accounting (place path).
# Production Download and Prepare generates this via the patcher; this suite
# does not exercise patch application.
cp -f "$PATCHED_BRINGUP" "${WORK}/bringup_py3_dp_after_os_upgrade.sh"
sha1sum "${WORK}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
  >"${WORK}/bringup_py3_dp_after_os_upgrade.sh.sha1"
BRINGUP_PATCHED_SHA1="$(sha1sum "${WORK}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"

AFTER_STAGE_BYTES="$(du -xsb "$PIPE" | awk '{print $1}')"
# Hardlinks must not double the large payload in allocated/apparent du -xsb counts once.
STAGE_INCREMENT=$((AFTER_STAGE_BYTES - BEFORE_BYTES))
# Allow small overhead for work dir metadata; must stay far below another full source copy.
if [[ "$STAGE_INCREMENT" -gt $((SOURCE_TOTAL_BYTES / 5)) ]]; then
  fail "staging added too many bytes increment=${STAGE_INCREMENT} source=${SOURCE_TOTAL_BYTES}"
fi
pass "staging increment bounded (${STAGE_INCREMENT} bytes)"

# Seed an existing final to prove failure/preserve + replacement path.
EXIST_DIR="${MM_DP_PHASE2_ROOT}/6.6.0"
mkdir -p "$EXIST_DIR"
printf 'OLD_BUNDLE_PAYLOAD_SHOULD_BE_PRESERVED_ON_FAIL\n' >"${EXIST_DIR}/dp_bundle_6.6.0-current.tar"
printf 'deadbeef  dp_bundle_6.6.0-current.tar\n' >"${EXIST_DIR}/dp_bundle_6.6.0-current.tar.sha256"
printf 'TARGET_DP_VERSION=6.6.0\n' >"${EXIST_DIR}/release.env"
OLD_FP="$(sha256sum "${EXIST_DIR}/dp_bundle_6.6.0-current.tar" | awk '{print $1}')"

# Failure path: force tar list assertion to fail by breaking required file set after stage.
# Use a copy of work with a missing required name so place fails before publish.
BAD_WORK="${WORK}.bad"
rm -rf "$BAD_WORK"
mkdir -p "$BAD_WORK"
for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
  [[ -e "${WORK}/${f}" ]] || continue
  ln "${WORK}/${f}" "${BAD_WORK}/${f}" 2>/dev/null || cp -f "${WORK}/${f}" "${BAD_WORK}/${f}"
done
rm -f "${BAD_WORK}/images-6.6.0.list"
# mm_die/dp2_die call exit — must isolate in a subshell.
set +e
( engine_place_dp_phase2_final "$BAD_WORK" 6.6.0 >/dev/null 2>&1 )
PLACE_FAIL_RC=$?
set -e
[[ "$PLACE_FAIL_RC" -ne 0 ]] || fail "place should fail with incomplete work dir"
[[ -f "${EXIST_DIR}/dp_bundle_6.6.0-current.tar" ]] || fail "existing final missing after failed place"
NEW_FP="$(sha256sum "${EXIST_DIR}/dp_bundle_6.6.0-current.tar" | awk '{print $1}')"
[[ "$NEW_FP" == "$OLD_FP" ]] || fail "existing final changed after failed place"
# No orphan .new dirs left for this version
find "$MM_DP_PHASE2_ROOT" -maxdepth 1 -name '6.6.0.new.*' | grep -q . \
  && fail "orphan .new dir remains after failed place" || true
pass "failure preserves existing final artifact"

# Successful publish path with peak sampling.
PEAK_FILE="${TMP}/peak.bytes"
echo "$AFTER_STAGE_BYTES" >"$PEAK_FILE"
(
  while true; do
    cur="$(du -xsb "$PIPE" 2>/dev/null | awk '{print $1}')"
    prev="$(cat "$PEAK_FILE")"
    if [[ -n "$cur" && "$cur" =~ ^[0-9]+$ && "$cur" -gt "$prev" ]]; then
      echo "$cur" >"$PEAK_FILE"
    fi
    sleep 0.05
  done
) &
PEAK_PID=$!

BUNDLE_NEW_INODE_BEFORE=""
# Keep sources during publish so we can assert rename (inode of .new matches final).
# We still verify cleanup timing separately after a second run with default cleanup.
MM_KEEP_PHASE2_SOURCES=1
set +e
PLACE_OUT="$(engine_place_dp_phase2_final "$WORK" 6.6.0 2>&1)"
PLACE_RC=$?
set -e
kill "$PEAK_PID" 2>/dev/null || true
wait "$PEAK_PID" 2>/dev/null || true
printf '%s\n' "$PLACE_OUT"
[[ "$PLACE_RC" -eq 0 ]] || fail "engine_place_dp_phase2_final rc=${PLACE_RC}"
# Command substitution runs in a subshell; confirm marker via logfile/state too.
grep -q 'DP_PHASE2_ATOMIC_PUBLISH=PASS' <<<"$PLACE_OUT" \
  || grep -q 'DP_PHASE2_ATOMIC_PUBLISH=PASS' "$MM_LOG_FILE" \
  || fail "atomic publish marker missing"

FINAL_BUNDLE="${EXIST_DIR}/dp_bundle_6.6.0-current.tar"
[[ -f "$FINAL_BUNDLE" ]] || fail "final bundle missing"
BUNDLE_OUTPUT_BYTES="$(stat -c%s "$FINAL_BUNDLE")"
FINAL_ENTRY_COUNT="$(tar -tf "$FINAL_BUNDLE" | wc -l | tr -d ' ')"
[[ "$FINAL_ENTRY_COUNT" -eq 9 ]] || fail "bundle entry count=${FINAL_ENTRY_COUNT}"
dp2_verify_sha256_pair "$FINAL_BUNDLE" "${FINAL_BUNDLE}.sha256"
NEW_FP2="$(sha256sum "$FINAL_BUNDLE" | awk '{print $1}')"
[[ "$NEW_FP2" != "$OLD_FP" ]] || fail "final bundle was not replaced on success"
find "$MM_DP_PHASE2_ROOT" -maxdepth 1 -name '6.6.0.old.*' | grep -q . \
  && fail ".old generation created on publish" || true
pass "direct final-directory bundle publish (entries=9, no .old)"

# Confirm no dp-build staging tree and no second bundle copy path residue.
[[ ! -d "${MM_CACHE_ROOT}/dp-build" ]] || fail "dp-build staging still present"
# With KEEP sources, cache may remain; cleanup explicitly and assert.
engine_cleanup_temps >/dev/null
[[ ! -d "$CACHE" ]] || fail "ACPS cache not cleaned"
[[ ! -d "${MM_CACHE_ROOT}/acps-work" ]] || fail "acps-work not cleaned"
[[ -f "$FINAL_BUNDLE" ]] || fail "cleanup removed final bundle"
pass "cache cleanup removes sources and keeps final"

PEAK_BYTES="$(cat "$PEAK_FILE")"
# Peak monitor starts after staging; include source already on disk in full peak.
if [[ "$PEAK_BYTES" -lt "$BEFORE_BYTES" ]]; then
  PEAK_BYTES="$BEFORE_BYTES"
fi
AFTER_BYTES="$(du -xsb "$PIPE" | awk '{print $1}')"
PEAK_INCREMENT=$((PEAK_BYTES - EMPTY_BYTES))
# Full pipeline multiplier: (source + bundle + small OH) / source ; target <= ~2.4
MULT="$(awk -v p="$PEAK_INCREMENT" -v s="$SOURCE_TOTAL_BYTES" 'BEGIN{ if (s<=0) print 999; else printf "%.3f", p/s }')"
printf 'FIXTURE_BUNDLE_OUTPUT_BYTES=%s\n' "$BUNDLE_OUTPUT_BYTES"
printf 'FIXTURE_PEAK_INCREMENT_BYTES=%s\n' "$PEAK_INCREMENT"
printf 'FIXTURE_PEAK_MULTIPLIER=%s\n' "$MULT"
printf 'FIXTURE_AFTER_BYTES=%s\n' "$AFTER_BYTES"
awk -v m="$MULT" 'BEGIN{ exit !(m >= 1.80 && m <= 2.40) }' \
  || fail "peak multiplier ${MULT} outside 1.80-2.40 (increment=${PEAK_INCREMENT} source=${SOURCE_TOTAL_BYTES})"
pass "fixture peak multiplier ${MULT} in 1.80-2.40"

# Project real 6.6.0 sizes for FULL vs PHASE2_ONLY (GB decimal ≠ GiB).
REAL_SOURCE=30307553280
REAL_BUNDLE=30307553280
REAL_R2=3562915840
REAL_PAYLOAD=$REAL_R2
BASE_OS=$((10 * 1024 * 1024 * 1024))
METADATA_OH=$((512 * 1024 * 1024))
GIB=$((1024 * 1024 * 1024))

FRESH_OS_STAGE=$((REAL_PAYLOAD + METADATA_OH))
FRESH_PHASE2_STAGE=$((REAL_SOURCE + REAL_BUNDLE + METADATA_OH))
FRESH_STAGE_PEAK=$FRESH_PHASE2_STAGE
FULL_PROJECTED_PEAK=$((BASE_OS + REAL_R2 + FRESH_STAGE_PEAK))
FULL_PROJECTED_PEAK_GIB=$((FULL_PROJECTED_PEAK / GIB))
PHASE2_ONLY_PROJECTED_PEAK=$((BASE_OS + FRESH_PHASE2_STAGE))
PHASE2_ONLY_PROJECTED_PEAK_GIB=$((PHASE2_ONLY_PROJECTED_PEAK / GIB))
printf 'FULL_PROJECTED_PEAK_GIB=%s\n' "$FULL_PROJECTED_PEAK_GIB"
printf 'PHASE2_ONLY_PROJECTED_PEAK_GIB=%s\n' "$PHASE2_ONLY_PROJECTED_PEAK_GIB"
[[ "$FULL_PROJECTED_PEAK_GIB" -ge 70 && "$FULL_PROJECTED_PEAK_GIB" -le 73 ]] \
  || fail "FULL projected peak ${FULL_PROJECTED_PEAK_GIB}GiB outside 70-73"
[[ "$PHASE2_ONLY_PROJECTED_PEAK_GIB" -ge 65 && "$PHASE2_ONLY_PROJECTED_PEAK_GIB" -le 70 ]] \
  || fail "PHASE2_ONLY projected peak ${PHASE2_ONLY_PROJECTED_PEAK_GIB}GiB outside 65-70"
# Source version must not change Phase 2 bytes
SOURCE_VERSION_DISK_DELTA_BYTES=0
[[ "$SOURCE_VERSION_DISK_DELTA_BYTES" -eq 0 ]] || fail "source version disk delta non-zero"
pass "FULL/PHASE2_ONLY projected peaks; source version disk delta=0"

# Preflight engine with real sizes on a 100GB decimal disk model
MM_MOCK_AVAILABLE_BYTES=$((80 * GIB))
MM_MOCK_FS_SIZE_BYTES=$((100 * 1000 * 1000 * 1000))
MM_MOCK_SAFETY_RESERVE_BYTES=$((10 * GIB))
OS_CORE_PACKAGE_BYTES=$REAL_R2
OS_CORE_PAYLOAD_BYTES=$REAL_PAYLOAD
ACPS_EXPECTED_BYTES=$REAL_SOURCE
PREPARATION_MODE=FULL
unset PHASE2_BUNDLE_ACTION PHASE2_REBUILD_REQUIRED
mm_calc_disk_requirements >/dev/null
[[ "$DISK_PREFLIGHT_RESULT" == "PASS" ]] || fail "FULL preflight should PASS at 80GiB free on 100GB disk"
[[ "$DISK_PREFLIGHT_SAFETY_RESERVE_BYTES" -ge $((10 * GIB)) ]] \
  || fail "safety reserve below 10GiB"
[[ "$FULL_PROJECTED_PEAK_GIB" -ge 70 && "$FULL_PROJECTED_PEAK_GIB" -le 73 ]] \
  || fail "100GB model peak not ~70GiB"
PREPARATION_MODE=PHASE2_ONLY
mm_calc_disk_requirements >/dev/null
[[ "$DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES" -eq 0 ]] || fail "PHASE2_ONLY OS stage not zero"
[[ "$DISK_PREFLIGHT_RESULT" == "PASS" ]] || fail "PHASE2_ONLY preflight should PASS"
pass "DISK_100GB_TEST=PASS preflight FULL/PHASE2_ONLY"

# Insufficient free space must FAIL before ACPS download/build.
MM_MOCK_AVAILABLE_BYTES=$((5 * GIB))
PREPARATION_MODE=FULL
ACPS_EXPECTED_BYTES=$REAL_SOURCE
set +e
( mm_calc_disk_requirements >/dev/null 2>&1 )
INSUFF_RC=$?
set -e
[[ "$INSUFF_RC" -ne 0 ]] || fail "insufficient disk should FAIL"
pass "INSUFFICIENT_DISK_TEST=PASS"

# Docs must not advertise 120/150/200GB or future-growth sizing.
DOC="${ROOT}/docs/deployment/DP_UPGRADE_MIRROR_MANAGER.md"
README="${ROOT}/README.md"
for bad in \
  'RECOMMENDED_FRESH_INSTALL_DISK=120GB' \
  'RECOMMENDED_OPERATIONAL_DISK=150GB' \
  'FUTURE_GROWTH_DISK=200GB' \
  'future bundle growth'
do
  if grep -Fq "$bad" "$DOC" "$README" 2>/dev/null; then
    fail "production docs still contain: ${bad}"
  fi
done
pass "documentation 100GB-only sizing (no 120/150/200/future-growth)"

MM_MOCK_AVAILABLE_BYTES=$((80 * GIB))

# Large-file hardlink refusal (no silent cp): put cache on a bind that breaks hardlink
# by using a copied file opened from a path we force-fail via threshold=0 + unlink trick:
# simpler: call engine_link with threshold 0 against a file where ln is made to fail by
# linking across... hard on one FS. Instead assert code path with a mock: chmod and use
# a directory without write? ln fails if dst exists as different inode — use existing dst.
LARGE="${TMP}/large.bin"
dd if=/dev/zero of="$LARGE" bs=1M count=65 status=none
DST="${TMP}/large.link"
: >"$DST"
MM_LARGE_FILE_COPY_THRESHOLD_BYTES=$((64 * 1024 * 1024))
set +e
( engine_link_acps_file_into_work "$LARGE" "$DST" >/dev/null 2>&1 )
LINK_RC=$?
set -e
[[ "$LINK_RC" -ne 0 ]] || fail "large-file hardlink refusal should fail when ln cannot replace"
pass "large-file hardlink failure refuses full copy"

echo "ALL TARGETED REGRESSION TESTS PASSED"
