#!/usr/bin/env bash
# tests/test_dp_upgrade_mirror_manager.sh — unified R2+ACPS Mirror Manager synthetic tests
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/seed_complete_client_http_set.sh
source "${ROOT}/tests/lib/seed_complete_client_http_set.sh"
# shellcheck source=lib/phase2_prereq_fixture.sh
source "${ROOT}/tests/lib/phase2_prereq_fixture.sh"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
OS_CORE_PY="${ROOT}/scripts/lib/os_core_package.py"
UPSTREAM_BASELINE="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1"
PATCHED_BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }
skip() { echo "  SKIP: $*"; }

WORKDIR="$(mktemp -d)"
export PHASE2_PREREQ_INDEX_ROOT="${WORKDIR}/noble-index"
phase2_prereq_write_empty_noble_index "$PHASE2_PREREQ_INDEX_ROOT"
HTTP_PID=""
R2_PID=""
HTTP_PORT=""
R2_PORT=""
ORIG_PWD="$(pwd)"
USE_WORKDIR_VENDOR=0
SHADOW_ROOT="$ROOT"

cleanup() {
  if [[ -n "${HTTP_PID:-}" ]]; then kill "$HTTP_PID" 2>/dev/null || true; wait "$HTTP_PID" 2>/dev/null || true; fi
  if [[ -n "${R2_PID:-}" ]]; then kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; fi
  pkill -f "${WORKDIR}" 2>/dev/null || true
  rm -rf "$WORKDIR"
  cd "$ORIG_PWD" 2>/dev/null || true
}
trap cleanup EXIT

make_selective_fixture() {
  local root="$1" hop
  for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
    mkdir -p "${root}/published/hops/${hop}/ubuntu/pool" "${root}/published/hops/${hop}/ubuntu/dists"
    printf 'pkg-%s\n' "$hop" >"${root}/published/hops/${hop}/ubuntu/pool/hello.deb"
    printf 'Release-%s\n' "$hop" >"${root}/published/hops/${hop}/ubuntu/dists/Release"
  done
  mkdir -p "${root}/published/shared/offline" "${root}/keys"
  printf 'meta\n' >"${root}/published/shared/offline/meta-release-lts"
  printf 'TEST-SELECTIVE-PUBLIC-KEY\n' >"${root}/keys/ubuntu-mirror-selective.gpg"
  ln -sfn hops/jammy-to-noble/ubuntu "${root}/published/ubuntu"
}

make_upstream_bringup() {
  local dest="$1"
  local want h
  want="$(awk '{print $1; exit}' "$UPSTREAM_BASELINE")"
  local prod="/var/spool/apt-mirror/dp-phase2/6.6.0/releases/20260726T155911Z/files/bringup_py3_dp_after_os_upgrade.sh"
  if [[ -r "$prod" ]]; then
    h="$(sha1sum "$prod" | awk '{print $1}')"
    if [[ "${h,,}" == "${want,,}" ]]; then cp -f "$prod" "$dest"; return 0; fi
  fi
  local build_up
  build_up="$(find "${ROOT}/.build-"* -name 'bringup_py3_dp_after_os_upgrade.sh' 2>/dev/null | head -1 || true)"
  if [[ -n "$build_up" && -r "$build_up" ]]; then
    h="$(sha1sum "$build_up" | awk '{print $1}')"
    if [[ "${h,,}" == "${want,,}" ]]; then cp -f "$build_up" "$dest"; return 0; fi
  fi
  return 1
}

ensure_upstream_bytes() {
  local dest="$1"
  local fixture="${ROOT}/tests/fixtures/dp-phase2/upstream_bringup_unpatched.sh"
  if make_upstream_bringup "$dest"; then
    return 0
  fi
  cp -f "$fixture" "$dest"
}

make_acps_payload() {
  local dir="$1" ver="${2:-6.6.0}"
  mkdir -p "$dir"
  phase2_prereq_write_zero_extra_common "${dir}/aelladeb_py3_common.tar.gz" "common-payload"
  sha1sum "${dir}/aelladeb_py3_common.tar.gz" | awk '{print $1}' >"${dir}/aelladeb_py3_common.tar.gz.sha1"
  printf 'uvp-deb\n' >"${dir}/aella-uvp-2404_${ver}ubuntu1_amd64.deb"
  sha1sum "${dir}/aella-uvp-2404_${ver}ubuntu1_amd64.deb" | awk '{print $1}' >"${dir}/aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1"
  ensure_upstream_bytes "${dir}/bringup_py3_dp_after_os_upgrade.sh"
  sha1sum "${dir}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
    >"${dir}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  seq 1 156 >"${dir}/images-${ver}.list"
  printf 'images-tar-body\n' >"${dir}/images-${ver}.tar"
  sha256sum "${dir}/images-${ver}.tar" | awk '{print $1}' >"${dir}/images-${ver}.tar.sha256"
}

start_http() {
  local root="$1" auth_mode="${2:-none}"
  HTTP_PORT="$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)"
  python3 - "$root" "$HTTP_PORT" "$auth_mode" "${WORKDIR}/http-counts" <<'PY' &
import base64, http.server, os, sys, pathlib, threading
root, port, auth_mode, count_dir = sys.argv[1], int(sys.argv[2]), sys.argv[3], pathlib.Path(sys.argv[4])
count_dir.mkdir(parents=True, exist_ok=True)
_get_lock = threading.Lock()
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=root, **k)
    def _auth_ok(self):
        if auth_mode == 'none': return True
        if auth_mode == 'fail': return False
        hdr = self.headers.get('Authorization', '')
        if not hdr.startswith('Basic '): return False
        try:
            userpass = base64.b64decode(hdr.split(' ',1)[1]).decode()
        except Exception:
            return False
        return userpass == 'testuser:testpass'
    def do_HEAD(self):
        if not self._auth_ok():
            self.send_response(401); self.send_header('WWW-Authenticate','Basic realm=t'); self.end_headers(); return
        return super().do_HEAD()
    def do_GET(self):
        if not self._auth_ok():
            self.send_response(401); self.send_header('WWW-Authenticate','Basic realm=t'); self.end_headers(); return
        p = count_dir / 'gets'
        with _get_lock:
            p.write_text(str(int(p.read_text())+1 if p.exists() else 1))
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            self.send_error(404); return
        fs = os.stat(path); size = fs.st_size
        range_hdr = self.headers.get('Range')
        if range_hdr and range_hdr.startswith('bytes='):
            _, _, rng = range_hdr.partition('=')
            start_s, _, end_s = rng.partition('-')
            start = int(start_s) if start_s else 0
            end = int(end_s) if end_s else size-1
            end = min(end, size-1); length = end-start+1
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.send_header('Accept-Ranges','bytes')
            self.send_header('Content-Length', str(length))
            self.send_header('Content-Type','application/octet-stream')
            self.end_headers()
            with open(path,'rb') as fh:
                fh.seek(start); self.wfile.write(fh.read(length))
            return
        return super().do_GET()
    def log_message(self, *args): pass
http.server.ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
PY
  HTTP_PID=$!
  sleep 0.3
}

# mode: normal | ignore_range | bad_range
start_r2() {
  local root="$1"
  local mode="${2:-normal}"
  R2_PORT="$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)"
  python3 - "$root" "$R2_PORT" "${WORKDIR}/http-counts-r2" "$mode" <<'PY' &
import http.server, os, sys, pathlib, threading
root, port, count_dir, mode = sys.argv[1], int(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4]
count_dir.mkdir(parents=True, exist_ok=True)
_get_lock = threading.Lock()
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=root, **k)
    def do_HEAD(self):
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            self.send_error(404); return
        size = os.stat(path).st_size
        self.send_response(200)
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(size))
        self.send_header('Content-Type', 'application/octet-stream')
        self.end_headers()
    def do_GET(self):
        p = count_dir / 'gets'
        with _get_lock:
            p.write_text(str(int(p.read_text())+1 if p.exists() else 1))
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            self.send_error(404); return
        fs = os.stat(path); size = fs.st_size
        range_hdr = self.headers.get('Range')
        # Record whether client sent no-cache (resume safety)
        if self.headers.get('Cache-Control', '').lower() == 'no-cache':
            (count_dir / 'nocache').write_text('1')
        if range_hdr and range_hdr.startswith('bytes='):
            (count_dir / 'range').write_text(range_hdr)
            if mode == 'ignore_range':
                # Cloudflare-like: ignore Range, return HTTP 200 full body.
                self.send_response(200)
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('Content-Length', str(size))
                self.send_header('Content-Type', 'application/octet-stream')
                self.end_headers()
                with open(path, 'rb') as fh:
                    self.wfile.write(fh.read())
                return
            _, _, rng = range_hdr.partition('=')
            start_s, _, end_s = rng.partition('-')
            start = int(start_s) if start_s else 0
            end = int(end_s) if end_s else size-1
            if mode == 'bad_range':
                # Deliberately wrong start offset in Content-Range.
                bad_start = 0 if start > 0 else 1
                end = min(end, size-1)
                length = end - start + 1
                self.send_response(206)
                self.send_header('Content-Range', f'bytes {bad_start}-{end}/{size}')
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('Content-Length', str(length))
                self.send_header('Content-Type', 'application/octet-stream')
                self.end_headers()
                with open(path, 'rb') as fh:
                    fh.seek(start)
                    self.wfile.write(fh.read(length))
                return
            end = min(end, size-1); length = end-start+1
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.send_header('Accept-Ranges','bytes')
            self.send_header('Content-Length', str(length))
            self.send_header('Content-Type','application/octet-stream')
            self.end_headers()
            with open(path,'rb') as fh:
                fh.seek(start); self.wfile.write(fh.read(length))
            return
        return super().do_GET()
    def log_message(self, *args): pass
http.server.ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
PY
  R2_PID=$!
  sleep 0.3
}

write_gui_config() {
  local path="$1"
  umask 077
  cat >"$path" <<EOF
PREPARATION_MODE=FULL
ACPS_USERNAME=testuser
ACPS_PASSWORD=testpass
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
EOF
  chmod 600 "$path"
}
export SKIP_MIRROR_HOST_VALIDATE=1

setup_project_shadow_if_needed() {
  if [[ "${USE_WORKDIR_VENDOR:-0}" != "1" ]]; then
    SHADOW_ROOT="$ROOT"
    return 0
  fi
  SHADOW_ROOT="${WORKDIR}/shadow-project"
  mkdir -p "$SHADOW_ROOT/vendor"
  ln -sfn "${ROOT}/scripts" "${SHADOW_ROOT}/scripts"
  ln -sfn "${ROOT}/client" "${SHADOW_ROOT}/client"
  ln -sfn "${ROOT}/lib" "${SHADOW_ROOT}/lib"
  ln -sfn "${ROOT}/config" "${SHADOW_ROOT}/config"
  ln -sfn "${ROOT}/mirror.conf" "${SHADOW_ROOT}/mirror.conf" 2>/dev/null || true
  cp -a "${WORKDIR}/vendor/dp-phase2" "${SHADOW_ROOT}/vendor/dp-phase2"
}

seed_client_files() {
  local dest="${1:-${MM_CLIENT_ROOT}}"
  seed_complete_client_http_set "$dest" "http://192.0.2.10"     "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
}

common_env() {
  export MM_SKIP_ROOT_CHECK=1
  export MM_SKIP_HTTP_VALIDATE=1
  export MM_SKIP_NGINX_APPLY=1
  export MM_LOG_DIR="${WORKDIR}/logs"
  export MM_STATE_ROOT="${WORKDIR}/runs"
  export MM_LOCK_FILE="${WORKDIR}/install.lock"
  export MM_CACHE_ROOT="${WORKDIR}/mirror/.install-cache"
  export MM_MIRROR_ROOT="${WORKDIR}/mirror"
  export MM_SELECTIVE_ROOT="${WORKDIR}/mirror/selective"
  export MM_DP_PHASE2_ROOT="${WORKDIR}/mirror/dp-phase2"
  export MM_CLIENT_ROOT="${WORKDIR}/mirror/client"
  export MM_CONFIG_DIR="${WORKDIR}/config"
  export MM_CONFIG_FILE="${WORKDIR}/gui.conf"
  export MM_STATUS_FILE="${WORKDIR}/status.env"
  export LOCAL_CLIENT_SIGNING_DIR="${WORKDIR}/config/client-signing"
  # Synthetic OS Core fixtures lack hop/upgrader trees for a real client rebuild.
  export MM_CLIENT_FINALIZATION_MODE=verify-only
  export DP_PHASE2_ROOT="${WORKDIR}/mirror/dp-phase2"
  export DP_PHASE2_SKIP_ROOT_CHECK=1
  export DP_PHASE2_MIN_FREE_GIB=0
  export ACPS_PROGRESS_INTERVAL_SEC=1
  export R2_PROGRESS_INTERVAL_SEC=1
  export MM_LONG_STEP_HEARTBEAT_SEC=1
  export DP_PHASE2_HEARTBEAT_SECONDS=1
  export MM_ENABLE_HTTP_SHA_HEARTBEAT_INTERVAL=1
  export ACPS_INSECURE_TLS=0
  mkdir -p "$MM_LOG_DIR" "$MM_STATE_ROOT" "$MM_CLIENT_ROOT" "$MM_CONFIG_DIR"
  seed_client_files "$MM_CLIENT_ROOT"
}

run_prepare() {
  setup_project_shadow_if_needed
  MM_PROJECT_ROOT="$SHADOW_ROOT" bash "${SHADOW_ROOT}/scripts/install-dp-upgrade-mirror.sh" \
    download-and-prepare --mirror-root "${MM_MIRROR_ROOT}" "$@"
}

# ===========================================================================
echo "======== A/B/P. GUI + obsolete absence ========"
# Menu order must be Enable HTTP (3) before Verify Readiness (4).
# Tags stay "1".."7"/"0"; [COMPLETED] belongs only in description variables.
awk '
  /^cmd_mirror_manager\(\)/ { in_fn=1 }
  in_fn && /mm_menu_label "Configuration"/ { c1=1 }
  in_fn && /mm_menu_label "Download and Prepare Upgrade Files"/ { c2=1 }
  in_fn && /mm_menu_label "Enable HTTP Distribution"/ { c3=1 }
  in_fn && /mm_menu_label "Verify Upgrade Readiness"/ { c4=1 }
  in_fn && /"3" "\$\{http_label\}"/ { m3=NR }
  in_fn && /"4" "\$\{readiness_label\}"/ { m4=NR }
  in_fn && /"7" "Show DP Client Upgrade Commands"/ { m7=NR }
  in_fn && /"0" "Exit"/ { m0=NR }
  in_fn && /^}/ {
    exit((c1 && c2 && c3 && c4 && m3 && m4 && m7 && m0 && m3 < m4 && m4 < m7 && m7 < m0) ? 0 : 1)
  }
' "$INSTALLER" && pass "A menu order 3=Enable HTTP before 4=Verify" \
  || fail "A menu order wrong"
grep -q 'Show DP Client Upgrade Commands' "$INSTALLER" \
  && grep -q 'mm_menu_label "Configuration"' "$INSTALLER" \
  && grep -q 'mm_menu_label "Download and Prepare Upgrade Files"' "$INSTALLER" \
  && grep -q 'Show Current Status' "$INSTALLER" && grep -q 'View Logs' "$INSTALLER" \
  && grep -q 'Exit' "$INSTALLER" \
  && pass "A main menu items" || fail "A main menu"
grep -q 'mm_collect_workflow_status' "$INSTALLER" \
  && grep -q 'mm_workflow_progress_text' "$INSTALLER" \
  && pass "A workflow progress on main menu" || fail "A workflow progress missing"
# Dispatch wiring: 3→enable, 4→verify
awk '
  /^cmd_mirror_manager\(\)/ { in_fn=1 }
  in_fn && /3\) gui_run_action "Enable HTTP Distribution" gui_enable_http/ { d3=1 }
  in_fn && /4\) gui_run_action "Verify Upgrade Readiness" gui_verify_readiness/ { d4=1 }
  in_fn && /3\) gui_run_action "Verify Upgrade Readiness"/ { bad=1 }
  in_fn && /4\) gui_run_action "Enable HTTP Distribution"/ { bad=1 }
  in_fn && /^}/ { exit((d3 && d4 && !bad) ? 0 : 1) }
' "$INSTALLER" && pass "A menu dispatch 3=enable 4=verify" || fail "A menu dispatch"
grep -q 'mm_whiptail_yesno' "$INSTALLER" \
  && grep -qE 'Download and prepare (Full OS Upgrade \+ Phase 2|Phase 2 Only) files' "$INSTALLER" \
  && pass "A download confirm is yesno" || fail "A download confirm still menu"
grep -q 'MM_LIVE_PROGRESS=1' "$INSTALLER" \
  && grep -q 'engine_download_and_prepare >"$tmp" 2>&1' "$INSTALLER" \
  && pass "A download live progress enabled" || fail "A download live progress missing"
# tee + MM_LIVE_PROGRESS /dev/tty caused exact adjacent duplicate progress lines.
if grep -n 'engine_download_and_prepare 2>&1 | tee' "$INSTALLER" | grep -q .; then
  fail "A download still tees (duplicates live tty progress)"
else
  pass "A download does not tee (tty live + file capture)"
fi
if grep -n 'out="$(engine_download_and_prepare 2>&1)"' "$INSTALLER" | grep -q .; then
  fail "A silent capture still hides download progress"
else
  pass "A no silent download capture"
fi
if grep -n '"1" "Start".*"0" "Cancel"\|"1" "Start"' "$INSTALLER" | grep -q .; then
  fail "A Start/Cancel menu still present"
else
  pass "A no Start/Cancel menu"
fi
grep -qE 'Mode 1|Mode 2|Mode 3|Fully Offline|Online Bootstrap|install-standard|Roll Back' "$INSTALLER" \
  && fail "A obsolete menu text" || pass "A no obsolete menus"
grep -q 'passwordbox' "$INSTALLER" && grep -q '"1" "Preparation Mode"' "$INSTALLER" \
  && pass "B configuration fields" || fail "B config"
grep -qE 'Current DP Version|Target DP Version|"DP Version"' "$INSTALLER" \
  && fail "B DP version config labels present" || pass "B no DP version config labels"
grep -Fq 'Phase 2 Target:      6.6.0 (fixed)' "$COMMON" \
  && pass "B exact Phase 2 footer present" || fail "B exact Phase 2 footer missing"
grep -qE 'Enter R2 URL|Enter ACPS URL|R2 URL input|ACPS URL input|Set R2 URL|Set ACPS URL' "$INSTALLER" \
  && fail "B URL menus present" || pass "B no URL menus"
# Snapshot guidance must remain; PROJECT_ROLLBACK_SUPPORTED must not appear in GUI screens.
grep -q 'hypervisor snapshot' "$INSTALLER" \
  && pass "O snapshot instructions" || fail "O instructions"
if awk '
  /^gui_show_status\(\)/ || /^gui_client_instructions\(\)/ || /^gui_build_client_commands\(\)/ { in_fn=1 }
  in_fn && /^}/ { in_fn=0 }
  in_fn && /PROJECT_ROLLBACK_SUPPORTED|Bringup drift|CLIENT_R2_ACCESS|Cloudflare R2|ACPS Server/ { bad=1 }
  END { exit(bad ? 1 : 0) }
' "$INSTALLER"; then
  pass "O user GUI omits internal rollback/drift fields"
else
  fail "O user GUI still shows internal fields"
fi

echo "======== C. R2 constant / checksum derivation ========"
common_env
write_gui_config "$MM_CONFIG_FILE"
PROD_URL='https://xdrsolutions.uk/ubuntu-os-core/ubuntu-os-core-xenial-to-noble.tar'
grep -F "OS_CORE_R2_URL_CONSTANT=\"${PROD_URL}\"" "${ROOT}/scripts/lib/mirror_manager_common.sh" \
  && pass "C R2 production constant set" || fail "C constant"
# Derived checksum URL contract (package URL + .sha256)
derived="$(
  env -u OS_CORE_R2_URL MM_PROJECT_ROOT="$ROOT" bash -c '
    set -euo pipefail
    source "'"${ROOT}"'/scripts/lib/mirror_manager_common.sh"
    printf "%s\n%s\n" "${OS_CORE_R2_URL}" "${OS_CORE_R2_URL}.sha256"
  '
)"
pkg_url="$(printf '%s\n' "$derived" | sed -n '1p')"
sha_url="$(printf '%s\n' "$derived" | sed -n '2p')"
[[ "$pkg_url" == "$PROD_URL" ]] && pass "C package URL from constant" || fail "C package URL"
[[ "$sha_url" == "${PROD_URL}.sha256" ]] && pass "C checksum URL derivation" || fail "C sha URL"
# Fail-closed when URL is cleared after constants load (simulates misconfig)
set +e
out_c="$(
  MM_PROJECT_ROOT="$ROOT" bash -c '
    set -euo pipefail
    source "'"${ROOT}"'/scripts/lib/mirror_manager_common.sh"
    source "'"${ROOT}"'/scripts/lib/r2_acquire.sh"
    OS_CORE_R2_URL=""
    r2_require_url
  ' 2>&1
)"
rc_c=$?
set -e
[[ "$rc_c" -ne 0 ]] && echo "$out_c" | grep -q 'CONFIGURATION_REQUIRED' \
  && pass "C CONFIGURATION_REQUIRED when cleared" || fail "C cleared URL should require config"

echo "======== E. OS Core package verify ========"
SEL="${WORKDIR}/sel-e"; make_selective_fixture "$SEL"
OUT_E="${WORKDIR}/out-e"; mkdir -p "$OUT_E"
python3 "$OS_CORE_PY" build --selective-root "$SEL" --output-dir "$OUT_E" --project-root "$ROOT" --release-id testE001
PKG_E="$(ls "$OUT_E"/ubuntu-os-core-xenial-to-noble-testE001.tar)"
python3 "$OS_CORE_PY" verify --package "$PKG_E" && pass "E verify" || fail "E verify"
PKG_BAD="${WORKDIR}/corrupt.tar"; cp -f "$PKG_E" "$PKG_BAD"; cp -f "${PKG_E}.sha256" "${PKG_BAD}.sha256"; printf x >>"$PKG_BAD"
python3 "$OS_CORE_PY" verify --package "$PKG_BAD" 2>/dev/null && fail "E outer should fail" || pass "E outer reject"

echo "======== Prepare fixtures for install flow ========"
common_env
USE_WORKDIR_VENDOR=0
ACPS_ROOT="${WORKDIR}/acps-http"
make_acps_payload "$ACPS_ROOT" 6.6.0
setup_project_shadow_if_needed
write_gui_config "$MM_CONFIG_FILE"

R2_ROOT="${WORKDIR}/r2-http"; mkdir -p "$R2_ROOT"
cp -f "$PKG_E" "${PKG_E}.sha256" "$R2_ROOT/"
start_r2 "$R2_ROOT"
start_http "$ACPS_ROOT" none
export OS_CORE_R2_URL="http://127.0.0.1:${R2_PORT}/$(basename "$PKG_E")"
export DP_PHASE2_SOURCE_BASE="http://127.0.0.1:${HTTP_PORT}"

echo "======== H/J/K/L/M. happy path prepare ========"
if run_prepare; then pass "H download-and-prepare"; else fail "H prepare"; fi

DP_DIR="${WORKDIR}/mirror/dp-phase2/6.6.0"
[[ -f "${DP_DIR}/release.env" ]] && [[ -f "${DP_DIR}/dp_bundle_6.6.0-current.tar" ]] \
  && [[ -f "${DP_DIR}/dp_bundle_6.6.0-current.tar.sha256" ]] && pass "J final bundle files" || fail "J files"
[[ ! -e "${DP_DIR}/releases" ]] && [[ ! -L "${DP_DIR}/current" ]] && [[ ! -L "${DP_DIR}/previous" ]] \
  && pass "K no generation paths" || fail "K generation present"
[[ -d "${WORKDIR}/mirror/selective/hops/xenial-to-bionic" ]] && pass "M OS selective hops" || fail "M hops"
[[ ! -L "${WORKDIR}/mirror/selective/current" ]] && [[ ! -e "${WORKDIR}/mirror/selective/published.previous" ]] \
  && pass "K selective no current/previous" || fail "K selective generation"
# shellcheck source=../scripts/lib/dp-phase2-common.sh
source "${ROOT}/scripts/lib/dp-phase2-common.sh"
dp2_set_version 6.6.0
dp2_assert_safe_tar_list "${DP_DIR}/dp_bundle_6.6.0-current.tar" && pass "J bundle contract" || fail "J tar"
EXPECTED_PATCHED="${WORKDIR}/expected-patched-bringup.sh"
python3 "${ROOT}/scripts/lib/patch_dp_phase2_bringup.py" \
  --upstream "${ACPS_ROOT}/bringup_py3_dp_after_os_upgrade.sh" \
  --output "$EXPECTED_PATCHED" >/dev/null
WANT_PATCH="$(sha1sum "$EXPECTED_PATCHED" | awk '{print $1}')"
# extract bringup from bundle and check
TMPB="${WORKDIR}/bundle-check"; mkdir -p "$TMPB"
tar -C "$TMPB" -xf "${DP_DIR}/dp_bundle_6.6.0-current.tar" bringup_py3_dp_after_os_upgrade.sh
GOT="$(sha1sum "${TMPB}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
[[ "${GOT,,}" == "${WANT_PATCH,,}" ]] && pass "H patched bringup generated from ACPS upstream" || fail "H patched got=${GOT} want=${WANT_PATCH}"
grep -q -- '--worker-password' "${TMPB}/bringup_py3_dp_after_os_upgrade.sh" \
  && pass "H generated has --worker-password" \
  || fail "H generated has --worker-password"
cmp -s "${ACPS_ROOT}/bringup_py3_dp_after_os_upgrade.sh" "${TMPB}/bringup_py3_dp_after_os_upgrade.sh" \
  && fail "H published bringup equals unmodified ACPS input" \
  || pass "H published bringup is generated, not the raw ACPS file"
cmp -s "$PATCHED_BRINGUP" "${TMPB}/bringup_py3_dp_after_os_upgrade.sh" \
  && pass "H generated matches known-good vendor (recovered real upstream)" \
  || pass "H generated from synthetic fixture (not frozen vendor blob)"

# L cleanup
compgen -G "${WORKDIR}/mirror/.install-cache/acps/6.6.0/*" >/dev/null 2>&1 \
  && fail "L acps cache remains" || pass "L acps cache cleaned"
compgen -G "${WORKDIR}/mirror/.install-cache/r2/*.tar" >/dev/null 2>&1 \
  && fail "L r2 archive remains" || pass "L r2 archive cleaned"
find "${WORKDIR}/mirror" -name '*.part' | grep -q . && fail "L .part remains" || pass "L no .part"
find "${WORKDIR}/mirror/dp-phase2" -maxdepth 1 -name '6.6.0.old.*' | grep -q . \
  && fail "L .old generation remains" || pass "L no .old generation"

echo "======== REUSE. valid final skips ACPS re-download ========"
ACPS_GETS_BEFORE="$(cat "${WORKDIR}/http-counts/gets" 2>/dev/null || echo 0)"
BUNDLE_FP_BEFORE="$(sha256sum "${DP_DIR}/dp_bundle_6.6.0-current.tar" | awk '{print $1}')"
if run_prepare; then pass "REUSE download-and-prepare"; else fail "REUSE prepare"; fi
ACPS_GETS_AFTER="$(cat "${WORKDIR}/http-counts/gets" 2>/dev/null || echo 0)"
BUNDLE_FP_AFTER="$(sha256sum "${DP_DIR}/dp_bundle_6.6.0-current.tar" | awk '{print $1}')"
[[ "$ACPS_GETS_AFTER" == "$ACPS_GETS_BEFORE" ]] \
  && pass "REUSE ACPS HTTP gets unchanged (${ACPS_GETS_AFTER})" \
  || fail "REUSE ACPS re-downloaded gets ${ACPS_GETS_BEFORE}->${ACPS_GETS_AFTER}"
[[ "$BUNDLE_FP_AFTER" == "$BUNDLE_FP_BEFORE" ]] \
  && pass "REUSE bundle fingerprint unchanged" \
  || fail "REUSE bundle was rebuilt/replaced"
find "${WORKDIR}/mirror/dp-phase2" -maxdepth 1 -name '6.6.0.old.*' | grep -q . \
  && fail "REUSE created .old" || pass "REUSE no .old generation"

echo "======== N. readiness ========"
MM_PROJECT_ROOT="$SHADOW_ROOT" bash "${SHADOW_ROOT}/scripts/install-dp-upgrade-mirror.sh" enable-http >/dev/null
MM_PROJECT_ROOT="$SHADOW_ROOT" bash "${SHADOW_ROOT}/scripts/install-dp-upgrade-mirror.sh" verify-readiness \
  | grep -q 'UPGRADE_READINESS=PASS' && pass "N readiness PASS" || fail "N readiness"

echo "======== D/G R2 HTML + ACPS failures ========"
kill "$HTTP_PID" 2>/dev/null || true; wait "$HTTP_PID" 2>/dev/null || true; HTTP_PID=""
kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; R2_PID=""

# HTML R2 body
R2_HTML="${WORKDIR}/r2-html"; mkdir -p "$R2_HTML"
printf '<!DOCTYPE html><html>err</html>' >"${R2_HTML}/bad.tar"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  bad.tar\n' >"${R2_HTML}/bad.tar.sha256"
start_r2 "$R2_HTML"
start_http "$ACPS_ROOT" none
export OS_CORE_R2_URL="http://127.0.0.1:${R2_PORT}/bad.tar"
export DP_PHASE2_SOURCE_BASE="http://127.0.0.1:${HTTP_PORT}"
export MM_LOCK_FILE="${WORKDIR}/lock-html"
export MM_MIRROR_ROOT="${WORKDIR}/mirror-html"
export MM_CACHE_ROOT="${WORKDIR}/mirror-html/.install-cache"
export MM_SELECTIVE_ROOT="${WORKDIR}/mirror-html/selective"
export MM_DP_PHASE2_ROOT="${WORKDIR}/mirror-html/dp-phase2"
export MM_CLIENT_ROOT="${WORKDIR}/mirror-html/client"
seed_client_files "$MM_CLIENT_ROOT"
set +e
out_html="$(run_prepare 2>&1)"; rc_html=$?
set -e
[[ "$rc_html" -ne 0 ]] && pass "D R2 HTML fail" || fail "D HTML should fail"

# checksum mismatch ACPS
kill "$HTTP_PID" 2>/dev/null || true; wait "$HTTP_PID" 2>/dev/null || true; HTTP_PID=""
kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; R2_PID=""
ACPS_BAD="${WORKDIR}/acps-bad"; cp -a "$ACPS_ROOT" "$ACPS_BAD"
echo '0000000000000000000000000000000000000000' >"${ACPS_BAD}/aelladeb_py3_common.tar.gz.sha1"
R2_ROOT2="${WORKDIR}/r2-ok"; mkdir -p "$R2_ROOT2"; cp -f "$PKG_E" "${PKG_E}.sha256" "$R2_ROOT2/"
start_r2 "$R2_ROOT2"
start_http "$ACPS_BAD" none
export OS_CORE_R2_URL="http://127.0.0.1:${R2_PORT}/$(basename "$PKG_E")"
export DP_PHASE2_SOURCE_BASE="http://127.0.0.1:${HTTP_PORT}"
export MM_LOCK_FILE="${WORKDIR}/lock-acps-bad"
export MM_MIRROR_ROOT="${WORKDIR}/mirror-acps-bad"
export MM_CACHE_ROOT="${WORKDIR}/mirror-acps-bad/.install-cache"
export MM_SELECTIVE_ROOT="${WORKDIR}/mirror-acps-bad/selective"
export MM_DP_PHASE2_ROOT="${WORKDIR}/mirror-acps-bad/dp-phase2"
export MM_CLIENT_ROOT="${WORKDIR}/mirror-acps-bad/client"
seed_client_files "$MM_CLIENT_ROOT"
set +e
out_bad="$(run_prepare 2>&1)"; rc_bad=$?
set -e
[[ "$rc_bad" -ne 0 ]] && pass "G ACPS checksum fail" || fail "G checksum"

# auth failure (no DP_PHASE2_SOURCE_BASE; use real auth against fail server)
kill "$HTTP_PID" 2>/dev/null || true; wait "$HTTP_PID" 2>/dev/null || true; HTTP_PID=""
start_http "$ACPS_ROOT" fail
unset DP_PHASE2_SOURCE_BASE
export MM_LOCK_FILE="${WORKDIR}/lock-auth"
export MM_MIRROR_ROOT="${WORKDIR}/mirror-auth"
export MM_CACHE_ROOT="${WORKDIR}/mirror-auth/.install-cache"
export MM_SELECTIVE_ROOT="${WORKDIR}/mirror-auth/selective"
export MM_DP_PHASE2_ROOT="${WORKDIR}/mirror-auth/dp-phase2"
export MM_CLIENT_ROOT="${WORKDIR}/mirror-auth/client"
seed_client_files "$MM_CLIENT_ROOT"
set +e
out_auth="$(run_prepare 2>&1)"; rc_auth=$?
set -e
[[ "$rc_auth" -ne 0 ]] && pass "G ACPS auth fail" || fail "G auth"
echo "$out_auth" | grep -qi 'testpass' && fail "F secret leaked" || pass "F no secret in output"

echo "======== I. legitimate upstream SHA change is non-blocking ========"
kill "$HTTP_PID" 2>/dev/null || true; wait "$HTTP_PID" 2>/dev/null || true; HTTP_PID=""
kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; R2_PID=""
ACPS_DRIFT="${WORKDIR}/acps-drift"; cp -a "$ACPS_ROOT" "$ACPS_DRIFT"
# Valid unpatched ACPS bringup whose SHA differs from the last-known
# reference. Do not use the frozen vendor full copy as "upstream".
python3 - "${ROOT}/tests/fixtures/dp-phase2/upstream_bringup_unpatched.sh" \
  "${ACPS_DRIFT}/bringup_py3_dp_after_os_upgrade.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
src = src.replace(
    'log "download_artifacts placeholder"',
    'log "download_artifacts placeholder"\n    # LEGITIMATE_UPSTREAM_SHA_DRIFT',
)
open(sys.argv[2], 'w').write(src)
PY
sha1sum "${ACPS_DRIFT}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
  >"${ACPS_DRIFT}/bringup_py3_dp_after_os_upgrade.sh.sha1"
start_r2 "$R2_ROOT2"
start_http "$ACPS_DRIFT" none
export OS_CORE_R2_URL="http://127.0.0.1:${R2_PORT}/$(basename "$PKG_E")"
export DP_PHASE2_SOURCE_BASE="http://127.0.0.1:${HTTP_PORT}"
export MM_LOCK_FILE="${WORKDIR}/lock-drift"
export MM_MIRROR_ROOT="${WORKDIR}/mirror-drift"
export MM_CACHE_ROOT="${WORKDIR}/mirror-drift/.install-cache"
export MM_SELECTIVE_ROOT="${WORKDIR}/mirror-drift/selective"
export MM_DP_PHASE2_ROOT="${WORKDIR}/mirror-drift/dp-phase2"
export MM_CLIENT_ROOT="${WORKDIR}/mirror-drift/client"
seed_client_files "$MM_CLIENT_ROOT"
set +e
out_drift="$(run_prepare 2>&1)"; rc_drift=$?
set -e
[[ "$rc_drift" -eq 0 ]] && echo "$out_drift" | grep -q 'UPSTREAM_BRINGUP_DRIFT=NON_BLOCKING' \
  && pass "I legitimate upstream change continues" || fail "I drift should be non-blocking"
echo "$out_drift" | grep -q 'INSTALL_RESULT=FAIL' && fail "I INSTALL_RESULT=FAIL on SHA change" \
  || pass "I no INSTALL_RESULT=FAIL on SHA change"
echo "$out_drift" | grep -q 'UPSTREAM_BRINGUP_DRIFT=YES' && fail "I blocking DRIFT=YES" \
  || pass "I no blocking DRIFT=YES"
[[ -f "${WORKDIR}/mirror-drift/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar" ]] \
  && pass "I final bundle published after SHA change" || fail "I bundle missing after SHA change"

echo "======== G resume ========"
kill "$HTTP_PID" 2>/dev/null || true; wait "$HTTP_PID" 2>/dev/null || true; HTTP_PID=""
kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; R2_PID=""
ACPS_G="${WORKDIR}/acps-g"; cp -a "$ACPS_ROOT" "$ACPS_G"
dd if=/dev/urandom of="${ACPS_G}/images-6.6.0.tar" bs=1024 count=64 status=none
sha256sum "${ACPS_G}/images-6.6.0.tar" | awk '{print $1}' >"${ACPS_G}/images-6.6.0.tar.sha256"
start_r2 "$R2_ROOT2"
start_http "$ACPS_G" none
export DP_PHASE2_SOURCE_BASE="http://127.0.0.1:${HTTP_PORT}"
export OS_CORE_R2_URL="http://127.0.0.1:${R2_PORT}/$(basename "$PKG_E")"
export MM_LOCK_FILE="${WORKDIR}/lock-g"
export MM_MIRROR_ROOT="${WORKDIR}/mirror-g"
export MM_CACHE_ROOT="${WORKDIR}/mirror-g/.install-cache"
export MM_SELECTIVE_ROOT="${WORKDIR}/mirror-g/selective"
export MM_DP_PHASE2_ROOT="${WORKDIR}/mirror-g/dp-phase2"
export MM_CLIENT_ROOT="${WORKDIR}/mirror-g/client"
mkdir -p "${WORKDIR}/mirror-g/.install-cache/acps/6.6.0"
seed_client_files "$MM_CLIENT_ROOT"
for f in aelladeb_py3_common.tar.gz aelladeb_py3_common.tar.gz.sha1 \
  aella-uvp-2404_6.6.0ubuntu1_amd64.deb aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1 \
  bringup_py3_dp_after_os_upgrade.sh bringup_py3_dp_after_os_upgrade.sh.sha1 \
  images-6.6.0.list images-6.6.0.tar.sha256; do
  cp -f "${ACPS_G}/$f" "${WORKDIR}/mirror-g/.install-cache/acps/6.6.0/$f"
done
dd if="${ACPS_G}/images-6.6.0.tar" of="${WORKDIR}/mirror-g/.install-cache/acps/6.6.0/images-6.6.0.tar.part" bs=1024 count=10 status=none
if run_prepare; then pass "G resume"; else fail "G resume"; fi

echo "======== R2. production downloader resume safety ========"
# Directly exercise r2_download_package (production path) in temp dirs only.
kill "$HTTP_PID" 2>/dev/null || true; wait "$HTTP_PID" 2>/dev/null || true; HTTP_PID=""
kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; R2_PID=""

run_r2_download_only() {
  local mirror_root="$1"
  local url="$2"
  MM_PROJECT_ROOT="$ROOT" \
  MM_SKIP_ROOT_CHECK=1 \
  MM_MIRROR_ROOT="$mirror_root" \
  MM_CACHE_ROOT="${mirror_root}/.install-cache" \
  MM_STATE_ROOT="${mirror_root}/.state" \
  MM_LOG_DIR="${mirror_root}/.logs" \
  MM_CONFIG_DIR="${mirror_root}/.cfg" \
  MM_STATUS_FILE="${mirror_root}/.cfg/status" \
  OS_CORE_R2_URL="$url" \
  bash -c '
    set -euo pipefail
    source "'"${ROOT}"'/scripts/lib/mirror_manager_common.sh"
    source "'"${ROOT}"'/scripts/lib/r2_acquire.sh"
    mm_state_init
    r2_download_package
    printf "OS_CORE_PACKAGE=%s\n" "${OS_CORE_PACKAGE}"
    printf "OS_CORE_PACKAGE_BYTES=%s\n" "${OS_CORE_PACKAGE_BYTES}"
  '
}

# R2-A: fresh download via production function
R2A="${WORKDIR}/r2-fresh"; mkdir -p "$R2A"
rm -rf "${WORKDIR}/http-counts-r2"
start_r2 "$R2_ROOT2" normal
URL_A="http://127.0.0.1:${R2_PORT}/$(basename "$PKG_E")"
out_a="$(run_r2_download_only "$R2A" "$URL_A")"
pkg_a="$(printf '%s\n' "$out_a" | sed -n 's/^OS_CORE_PACKAGE=//p' | tail -1)"
[[ -f "$pkg_a" ]] && cmp -s "$pkg_a" "$PKG_E" && pass "R2-A fresh download" || fail "R2-A fresh"
[[ -f "${pkg_a}.sha256" ]] && cmp -s "${pkg_a}.sha256" "${PKG_E}.sha256" && pass "R2-A checksum" || fail "R2-A sha"
find "$R2A" -name '*.part' | grep -q . && fail "R2-A .part remains" || pass "R2-A .part cleanup"
[[ -f "${WORKDIR}/http-counts-r2/nocache" ]] && pass "R2-A no-cache header" || fail "R2-A no-cache missing"
kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; R2_PID=""

# R2-B: HTTP 206 resume append
R2B="${WORKDIR}/r2-resume206"; mkdir -p "${R2B}/.install-cache/r2"
rm -rf "${WORKDIR}/http-counts-r2"
start_r2 "$R2_ROOT2" normal
URL_B="http://127.0.0.1:${R2_PORT}/$(basename "$PKG_E")"
base_b="$(basename "$PKG_E")"
dd if="$PKG_E" of="${R2B}/.install-cache/r2/${base_b}.part" bs=1024 count=16 status=none
out_b="$(run_r2_download_only "$R2B" "$URL_B")"
pkg_b="$(printf '%s\n' "$out_b" | sed -n 's/^OS_CORE_PACKAGE=//p' | tail -1)"
[[ -f "${WORKDIR}/http-counts-r2/range" ]] && pass "R2-B Range requested" || fail "R2-B no Range"
cmp -s "$pkg_b" "$PKG_E" && pass "R2-B 206 resume integrity" || fail "R2-B corrupt"
[[ "$(stat -c%s "$pkg_b")" == "$(stat -c%s "$PKG_E")" ]] && pass "R2-B size" || fail "R2-B size"
find "$R2B" -name '*.part' | grep -q . && fail "R2-B .part remains" || pass "R2-B .part cleanup"
kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; R2_PID=""

# R2-C: Range ignored → HTTP 200 full body (must NOT append)
R2C="${WORKDIR}/r2-ignore200"; mkdir -p "${R2C}/.install-cache/r2"
rm -rf "${WORKDIR}/http-counts-r2"
start_r2 "$R2_ROOT2" ignore_range
URL_C="http://127.0.0.1:${R2_PORT}/$(basename "$PKG_E")"
base_c="$(basename "$PKG_E")"
# Poisoned prefix that would corrupt if appended before a full body
printf 'POISON' >"${R2C}/.install-cache/r2/${base_c}.part"
dd if="$PKG_E" bs=1024 count=8 status=none >>"${R2C}/.install-cache/r2/${base_c}.part"
out_c2="$(run_r2_download_only "$R2C" "$URL_C")"
pkg_c="$(printf '%s\n' "$out_c2" | sed -n 's/^OS_CORE_PACKAGE=//p' | tail -1)"
cmp -s "$pkg_c" "$PKG_E" && pass "R2-C 200 ignore-range clean restart" || fail "R2-C append corruption"
# Final must not start with POISON
! head -c 6 "$pkg_c" | grep -q 'POISON' && pass "R2-C no poison prefix" || fail "R2-C poison kept"
kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; R2_PID=""

# R2-D: invalid Content-Range must fail (no successful finalize)
R2D="${WORKDIR}/r2-badrange"; mkdir -p "${R2D}/.install-cache/r2"
start_r2 "$R2_ROOT2" bad_range
URL_D="http://127.0.0.1:${R2_PORT}/$(basename "$PKG_E")"
base_d="$(basename "$PKG_E")"
dd if="$PKG_E" of="${R2D}/.install-cache/r2/${base_d}.part" bs=1024 count=8 status=none
set +e
out_d="$(run_r2_download_only "$R2D" "$URL_D" 2>&1)"; rc_d=$?
set -e
[[ "$rc_d" -ne 0 ]] && echo "$out_d" | grep -q 'R2_CONTENT_RANGE_MISMATCH\|R2_DOWNLOAD=FAIL' \
  && pass "R2-D invalid Content-Range rejected" || fail "R2-D should fail"
[[ ! -f "${R2D}/.install-cache/r2/${base_d}" ]] && pass "R2-D no final package" || fail "R2-D finalized on error"
kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; R2_PID=""

# R2-E: checksum mismatch (wrong sidecar) must fail at verify stage when using engine,
# and r2_download itself keeps wrong sha — engine_verify covers reject. Here ensure download
# stores sidecar and os_core verifier rejects mismatched package+sha pair.
R2E="${WORKDIR}/r2-badsha"; mkdir -p "$R2E/r2-http"
cp -f "$PKG_E" "$R2E/r2-http/"
printf '0000000000000000000000000000000000000000000000000000000000000000  %s\n' "$(basename "$PKG_E")" \
  >"$R2E/r2-http/$(basename "$PKG_E").sha256"
start_r2 "$R2E/r2-http" normal
URL_E="http://127.0.0.1:${R2_PORT}/$(basename "$PKG_E")"
out_e="$(run_r2_download_only "${WORKDIR}/r2-badsha-mirror" "$URL_E")"
pkg_e="$(printf '%s\n' "$out_e" | sed -n 's/^OS_CORE_PACKAGE=//p' | tail -1)"
set +e
python3 "$OS_CORE_PY" verify --package "$pkg_e" >/dev/null 2>&1
rc_e=$?
set -e
[[ "$rc_e" -ne 0 ]] && pass "R2-E checksum mismatch rejected by verifier" || fail "R2-E should mismatch"
kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; R2_PID=""

echo "======== P disk + lock + entrypoint ========"
# Restore live mock servers for prepare-path tests (R2 resume section stops them).
kill "$HTTP_PID" 2>/dev/null || true; wait "$HTTP_PID" 2>/dev/null || true; HTTP_PID=""
kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; R2_PID=""
start_r2 "$R2_ROOT2" normal
start_http "$ACPS_ROOT" none
export OS_CORE_R2_URL="http://127.0.0.1:${R2_PORT}/$(basename "$PKG_E")"
export DP_PHASE2_SOURCE_BASE="http://127.0.0.1:${HTTP_PORT}"
export MM_MOCK_AVAILABLE_BYTES=1000
export MM_LOCK_FILE="${WORKDIR}/lock-disk"
export MM_MIRROR_ROOT="${WORKDIR}/mirror-disk"
export MM_CACHE_ROOT="${WORKDIR}/mirror-disk/.install-cache"
export MM_SELECTIVE_ROOT="${WORKDIR}/mirror-disk/selective"
export MM_DP_PHASE2_ROOT="${WORKDIR}/mirror-disk/dp-phase2"
export MM_CLIENT_ROOT="${WORKDIR}/mirror-disk/client"
seed_client_files "$MM_CLIENT_ROOT"
set +e
out_disk="$(run_prepare 2>&1)"; rc_disk=$?
set -e
[[ "$rc_disk" -ne 0 ]] && echo "$out_disk" | grep -q 'DISK_PREFLIGHT=FAIL' && pass "P disk" || fail "P disk"
unset MM_MOCK_AVAILABLE_BYTES

export MM_LOCK_FILE="${WORKDIR}/lock-v"
exec {lockfd}>"$MM_LOCK_FILE"; flock -n "$lockfd"
set +e
out_v="$(MM_DRY_RUN=1 run_prepare --dry-run 2>&1)"; rc_v=$?
set -e
flock -u "$lockfd"; eval "exec ${lockfd}>&-"
[[ "$rc_v" -ne 0 ]] && echo "$out_v" | grep -q 'INSTALL_LOCK=BUSY' && pass "P lock" || fail "P lock"

bash "${ROOT}/scripts/ubuntu-offline-mirror.sh" --help 2>&1 | grep -q 'mirror-manager' \
  && pass "entrypoint mirror-manager" || fail "entrypoint missing"
bash "${ROOT}/scripts/ubuntu-offline-mirror.sh" --help 2>&1 | grep -qE 'install-standard|install-menu|Mode 2' \
  && fail "entrypoint obsolete cmds" || pass "entrypoint no obsolete cmds"

# Hardcoded credential absence in new manager scripts
grep -RInE 'AellaMeta|WroTQfm' "${ROOT}/scripts/lib/mirror_manager_common.sh" \
  "${ROOT}/scripts/lib/mirror_install_engine.sh" "${ROOT}/scripts/lib/acps_acquire.sh" \
  "${ROOT}/scripts/install-dp-upgrade-mirror.sh" 2>/dev/null \
  && fail "F hardcoded creds in manager" || pass "F no hardcoded manager creds"
grep -nE "ACPS_PASS='|ACPS_USER=\"Aella" "${ROOT}/scripts/download-dp-phase2.sh" \
  && fail "F hardcoded in download-dp-phase2" || pass "F download-dp-phase2 creds removed"

echo "======== Q. production safety ========"
PROD_CUR="$(readlink /var/spool/apt-mirror/dp-phase2/6.6.0/current 2>/dev/null || true)"
PROD_PREV="$(readlink /var/spool/apt-mirror/dp-phase2/6.6.0/previous 2>/dev/null || true)"
if [[ -z "$PROD_CUR" && -z "$PROD_PREV" ]]; then
  skip "Q production dp-phase2 current/previous absent (clean host; optional smoke)"
elif [[ ! -e /var/spool/apt-mirror/dp-phase2/6.6.0/current ]]; then
  skip "Q production current symlink absent (clean host; optional smoke)"
else
  [[ "$PROD_CUR" == "releases/20260728T110548Z" ]] && pass "Q production current" || fail "Q current=$PROD_CUR"
  [[ "$PROD_PREV" == "releases/20260726T155911Z" ]] && pass "Q production previous" || fail "Q previous=$PROD_PREV"
fi

echo "======== S. SHA256 live progress + GUI lifecycle ========"
# Structural: enable-http uses live progress (MM_LIVE_PROGRESS), not silent capture.
if awk '
  /^gui_enable_http\(\)/ { in_fn=1; next }
  in_fn && /^}/ { exit((live > 0 && eng > 0 && live < eng && !silent) ? 0 : 1) }
  in_fn && /MM_LIVE_PROGRESS=1/ && !live { live=NR }
  in_fn && /engine_enable_http_distribution >"\$tmp" 2>&1/ && !eng { eng=NR }
  in_fn && /out="\$\(engine_enable_http_distribution 2>&1\)"/ { silent=1 }
' "$INSTALLER"; then
  pass "S enable-http live progress before engine"
else
  fail "S enable-http live progress before engine"
fi

# Readiness must not call the static SHA256 wait notice helper.
if awk '
  /^gui_verify_readiness\(\)/ { in_fn=1; next }
  in_fn && /^}/ { exit(bad ? 1 : 0) }
  in_fn && /gui_show_sha256_wait_notice/ { bad=1 }
' "$INSTALLER"; then
  pass "S readiness has no SHA256 wait notice"
else
  fail "S readiness unexpectedly shows SHA256 wait notice"
fi

grep -q 'mm_whiptail_infobox' "$INSTALLER" \
  && pass "S mm_whiptail_infobox helper present" || fail "S mm_whiptail_infobox missing"
grep -q 'gui_run_action' "$INSTALLER" \
  && pass "S gui_run_action dispatcher present" || fail "S gui_run_action missing"
grep -q 'GUI_EXITS_ONLY_ON_EXPLICIT_ZERO\|return 0' "$INSTALLER" \
  && grep -q 'gui_run_action "Enable HTTP Distribution"' "$INSTALLER" \
  && pass "S menu uses protected dispatcher" || fail "S menu dispatcher wiring"

# mm_log must not unconditionally mirror every line to /dev/tty (duplicate-log regression).
mm_log_body="$(awk '/^mm_log\(\)/,/^mm_info\(\)/' "${ROOT}/scripts/lib/mirror_manager_common.sh")"
if printf '%s\n' "$mm_log_body" | grep -q '/dev/tty'; then
  if printf '%s\n' "$mm_log_body" | awk '
    /MM_LIVE_PROGRESS/ { live=1 }
    /\/dev\/tty/ && !live { bad=1 }
    END { exit(bad ? 1 : 0) }
  '; then
    pass "S mm_log /dev/tty only under MM_LIVE_PROGRESS"
  else
    fail "S mm_log unconditional /dev/tty reintroduced"
  fi
else
  pass "S mm_log has no /dev/tty mirror"
fi

# Behavioral mock helpers (SCRIPT_DIR kept on real scripts/).
S_TRACE="${WORKDIR}/sha256-notice.trace"
S_LIB="${WORKDIR}/installer-lib.sh"
LIFECYCLE_TRACE="${WORKDIR}/gui-lifecycle.trace"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$INSTALLER" >"$S_LIB"

run_gui_enable_http_mock() {
  local fail_mode="${1:-0}"
  MM_PROJECT_ROOT="$ROOT" MM_TEST_SHA256_FAIL="$fail_mode" bash -c '
    set -euo pipefail
    TRACE="$1"
    LIB="$2"
    : >"$TRACE"
    # shellcheck disable=SC1090
    source "$LIB"
    trap - EXIT
    mm_whiptail_textbox() {
      printf "TEXTBOX\t%s\n" "$1" >>"$TRACE"
      return 0
    }
    mm_whiptail_msg() { printf "MSG\t%s\n" "$1" >>"$TRACE"; return 0; }
    mm_has_whiptail() { return 0; }
    clear() { return 0; }
    load_mirror_defaults() { :; }
    mm_load_gui_config() { TARGET_DP_VERSION=6.6.0; }
    engine_resolve_paths() { :; }
    dp2_set_version() { :; }
    dp2_stable_bundle_name() { printf "%s\n" "dp_bundle_6.6.0-current.tar"; }
    mm_format_bytes() { printf "%s\n" "$1"; }
    mm_artifacts_ready_for_http() { return 0; }
    engine_enable_http_distribution() {
      printf "ENGINE_START\n" >>"$TRACE"
      printf "SHA256_VERIFICATION_START operation=enable-http file=dp_bundle_6.6.0-current.tar\n" | tee -a "$TRACE"
      printf "SHA256_BEGIN\n" >>"$TRACE"
      sleep 0.2
      printf "SHA256_END\n" >>"$TRACE"
      if [[ "${MM_TEST_SHA256_FAIL:-0}" == "1" ]]; then
        echo "SHA256_VERIFY=FAIL"
        return 1
      fi
      echo "HTTP_DISTRIBUTION=ENABLED"
      return 0
    }
    # Avoid interactive Enter wait in tests.
    read() { return 0; }
    gui_enable_http
  ' gui-mock "$S_TRACE" "$S_LIB"
}

set +e
S_OUT="$(run_gui_enable_http_mock 0 2>&1)"
S_RC=$?
set -e

if [[ ! -f "$S_TRACE" ]]; then
  fail "S mock trace missing (rc=${S_RC}); out=${S_OUT}"
  : >"$S_TRACE"
fi

if awk '
  /^ENGINE_START/ { eng=NR }
  /^SHA256_BEGIN/ { sh=NR }
  END { exit((eng > 0 && sh > 0 && eng <= sh) ? 0 : 1) }
' "$S_TRACE" 2>/dev/null; then
  pass "S ENGINE_START before SHA256 work"
else
  fail "S ENGINE_START before SHA256 work"
  cat "$S_TRACE" 2>/dev/null || true
fi

echo "$S_OUT" | grep -q 'Enable HTTP Distribution — live progress' \
  && pass "S live progress banner" || fail "S live progress banner missing"
# START is emitted by the engine into the transcript (and TRACE in this mock).
grep -q 'SHA256_VERIFICATION_START operation=enable-http' "$S_TRACE" \
  && pass "S structured start log once" || fail "S missing SHA256_VERIFICATION_START log"

[[ "$S_RC" -eq 0 ]] && grep -q 'TEXTBOX	HTTP Distribution — ENABLED' "$S_TRACE" \
  && pass "S SHA256_SUCCESS_RESULT=PASS" || fail "S SHA256_SUCCESS_RESULT (rc=${S_RC})"

: >"$S_TRACE"
set +e
S_FAIL_OUT="$(run_gui_enable_http_mock 1 2>&1)"
set -e
grep -q 'TEXTBOX	HTTP Distribution — FAIL' "$S_TRACE" \
  && pass "S SHA256_FAILURE_RESULT=PASS" || fail "S SHA256_FAILURE_RESULT out=${S_FAIL_OUT}"

# No static infobox body leaked to stdout as duplicate operator noise.
UNIQUE_BODY='do not interrupt the process or close this terminal'
BODY_STDOUT_HITS="$(echo "$S_OUT" | grep -cF "$UNIQUE_BODY" || true)"
[[ "$BODY_STDOUT_HITS" -eq 0 ]] && pass "S DUPLICATE_OUTPUT=0" \
  || fail "S DUPLICATE_OUTPUT body stdout hits=${BODY_STDOUT_HITS}"

# Full menu lifecycle in one process: 3(enable)→4(verify)→5→7→6→1→0 Exit
# Menu counter must live in a file: choice="$(mm_whiptail_menu ...)" runs in a subshell.
set +e
LIFE_OUT="$(
  MM_PROJECT_ROOT="$ROOT" MM_FORCE_MENU=1 MM_SKIP_ROOT_CHECK=1 \
  MM_STATUS_FILE="${WORKDIR}/life-status.env" \
  MM_CONFIG_FILE="${WORKDIR}/life-gui.conf" \
  bash -c '
    set -euo pipefail
    TRACE="$1"
    LIB="$2"
    MENU_IDX_FILE="$3"
    : >"$TRACE"
    printf "0\n" >"$MENU_IDX_FILE"
    # shellcheck disable=SC1090
    source "$LIB"
    trap - EXIT
    export MM_GUI_MODE=1
    MENU_SEQ=(3 4 5 7 6 1 0)
    mm_has_whiptail() { return 0; }
    mm_whiptail_menu() {
      printf "MENU\n" >>"$TRACE"
      local idx c
      idx="$(cat "$MENU_IDX_FILE")"
      if [[ "$idx" -ge "${#MENU_SEQ[@]}" ]]; then
        return 1
      fi
      c="${MENU_SEQ[$idx]}"
      printf "%s\n" "$((idx + 1))" >"$MENU_IDX_FILE"
      printf "%s\n" "$c"
      return 0
    }
    mm_whiptail_infobox() { printf "INFOBOX\t%s\n" "$1" >>"$TRACE"; return 0; }
    mm_whiptail_textbox() { printf "TEXTBOX\t%s\n" "$1" >>"$TRACE"; return 0; }
    mm_whiptail_msg() { printf "MSG\t%s\n" "$1" >>"$TRACE"; return 0; }
    mm_whiptail_yesno() { return 0; }
    mm_whiptail_input() { printf "%s\n" "${3:-6.3.0}"; return 0; }
    load_mirror_defaults() { :; }
    mm_load_gui_config() { TARGET_DP_VERSION=6.6.0; MIRROR_HTTP_URL="http://192.0.2.10"; }
    engine_resolve_paths() {
      printf "PATH_RESOLVE\n" >>"$TRACE"
      return 0
    }
    dp2_set_version() { :; }
    dp2_stable_bundle_name() { printf "%s\n" "dp_bundle_6.6.0-current.tar"; }
    engine_enable_http_distribution() { echo ENABLED; return 0; }
    engine_compute_readiness() { printf "UPGRADE_READINESS=FAIL\n"; return 1; }
    engine_validate_http_layout() { return 0; }
    mm_status_get() { printf "UNKNOWN\n"; }
    mm_artifacts_ready_for_http() { return 0; }
    mm_http_distribution_enabled() { return 0; }
    mm_save_gui_config() { return 0; }
    mm_collect_workflow_status() {
      MM_WF_CONFIG_COMPLETED=0
      MM_WF_DOWNLOAD_COMPLETED=0
      MM_WF_HTTP_COMPLETED=0
      MM_WF_READINESS_COMPLETED=0
      MM_WF_PROGRESS_COUNT=0
    }
    mm_menu_label() { printf "%s\n" "$1"; }
    mm_workflow_progress_text() { printf "Progress: 0 of 4 workflow steps completed\n"; }
    gui_configuration() { printf "ACTION_1\n" >>"$TRACE"; return 0; }
    gui_enable_http() {
      printf "ACTION_3\n" >>"$TRACE"
      local tmp; tmp="$(mktemp)"
      echo ENABLED >"$tmp"
      mm_whiptail_textbox "HTTP Distribution — ENABLED" "$tmp" || true
      rm -f "$tmp"
      return 0
    }
    gui_verify_readiness() {
      printf "ACTION_4\n" >>"$TRACE"
      local tmp; tmp="$(mktemp)"
      printf "UPGRADE_READINESS=FAIL\nTARGET_DP_VERSION=6.6.0\n" >"$tmp"
      mm_whiptail_textbox "Verify Upgrade Readiness" "$tmp" || true
      rm -f "$tmp"
      return 0
    }
    gui_show_status() {
      printf "ACTION_5\n" >>"$TRACE"
      local tmp; tmp="$(mktemp)"
      printf "Preparation Mode: Full OS Upgrade + Phase 2\nPhase 2 Target: 6.6.0\nHTTP Distribution: DISABLED\n" >"$tmp"
      mm_whiptail_textbox "Current Status" "$tmp" || true
      rm -f "$tmp"
      return 0
    }
    gui_client_instructions() {
      printf "ACTION_7\n" >>"$TRACE"
      local tmp; tmp="$(mktemp)"
      gui_build_client_commands "http://192.0.2.10" "6.3.0" "single" "" >"$tmp"
      mm_whiptail_textbox "DP Client Upgrade Commands" "$tmp" || true
      rm -f "$tmp"
      return 0
    }
    gui_view_logs() {
      printf "ACTION_6\n" >>"$TRACE"
      mm_whiptail_msg "Logs" "No mirror-manager log found yet."
      return 0
    }
    cmd_mirror_manager
    printf "EXIT_REASON=EXPLICIT_ZERO\n" >>"$TRACE"
  ' gui-lifecycle "$LIFECYCLE_TRACE" "$S_LIB" "${WORKDIR}/menu.idx" 2>&1
)"
LIFE_RC=$?
set -e

ACTION_3_CALL_COUNT="$(grep -c '^ACTION_3$' "$LIFECYCLE_TRACE" || true)"
ACTION_4_CALL_COUNT="$(grep -c '^ACTION_4$' "$LIFECYCLE_TRACE" || true)"
ACTION_5_CALL_COUNT="$(grep -c '^ACTION_5$' "$LIFECYCLE_TRACE" || true)"
ACTION_7_CALL_COUNT="$(grep -c '^ACTION_7$' "$LIFECYCLE_TRACE" || true)"
ACTION_6_CALL_COUNT="$(grep -c '^ACTION_6$' "$LIFECYCLE_TRACE" || true)"
ACTION_1_CALL_COUNT="$(grep -c '^ACTION_1$' "$LIFECYCLE_TRACE" || true)"
MAIN_MENU_DISPLAY_COUNT="$(grep -c '^MENU$' "$LIFECYCLE_TRACE" || true)"
GUI_EXIT_COUNT="$(grep -c '^EXIT_REASON=EXPLICIT_ZERO$' "$LIFECYCLE_TRACE" || true)"

[[ "$LIFE_RC" -eq 0 ]] && pass "S lifecycle process rc=0" || fail "S lifecycle rc=${LIFE_RC} out=${LIFE_OUT}"
[[ "$ACTION_3_CALL_COUNT" -eq 1 ]] && pass "S ACTION_3_CALL_COUNT=1 (enable-http)" || fail "S ACTION_3_CALL_COUNT=${ACTION_3_CALL_COUNT}"
[[ "$ACTION_4_CALL_COUNT" -eq 1 ]] && pass "S ACTION_4_CALL_COUNT=1 (verify)" || fail "S ACTION_4_CALL_COUNT=${ACTION_4_CALL_COUNT}"
[[ "$ACTION_5_CALL_COUNT" -eq 1 ]] && pass "S ACTION_5_CALL_COUNT=1" || fail "S ACTION_5_CALL_COUNT=${ACTION_5_CALL_COUNT}"
[[ "$ACTION_7_CALL_COUNT" -eq 1 ]] && pass "S ACTION_7_CALL_COUNT=1" || fail "S ACTION_7_CALL_COUNT=${ACTION_7_CALL_COUNT}"
[[ "$ACTION_6_CALL_COUNT" -eq 1 ]] && pass "S ACTION_6_CALL_COUNT=1" || fail "S ACTION_6_CALL_COUNT=${ACTION_6_CALL_COUNT}"
[[ "$ACTION_1_CALL_COUNT" -eq 1 ]] && pass "S ACTION_1_CALL_COUNT=1" || fail "S ACTION_1_CALL_COUNT=${ACTION_1_CALL_COUNT}"
[[ "$MAIN_MENU_DISPLAY_COUNT" -ge 7 ]] && pass "S MAIN_MENU_DISPLAY_COUNT>=7 (${MAIN_MENU_DISPLAY_COUNT})" \
  || fail "S MAIN_MENU_DISPLAY_COUNT=${MAIN_MENU_DISPLAY_COUNT}"
[[ "$GUI_EXIT_COUNT" -eq 1 ]] && pass "S GUI_EXIT_COUNT=1 EXIT_REASON=EXPLICIT_ZERO" \
  || fail "S GUI_EXIT_COUNT=${GUI_EXIT_COUNT}"

# Failure of a GUI action must not terminate the menu (dispatcher).
set +e
FAIL_LIFE="$(
  MM_PROJECT_ROOT="$ROOT" MM_FORCE_MENU=1 MM_SKIP_ROOT_CHECK=1 \
  MM_STATUS_FILE="${WORKDIR}/fail-life-status.env" \
  MM_CONFIG_FILE="${WORKDIR}/fail-life-gui.conf" \
  bash -c '
    set -euo pipefail
    TRACE="$1"; LIB="$2"; MENU_IDX_FILE="$3"; : >"$TRACE"
    printf "0\n" >"$MENU_IDX_FILE"
    # shellcheck disable=SC1090
    source "$LIB"
    trap - EXIT
    MENU_SEQ=(3 0)
    mm_has_whiptail() { return 0; }
    mm_whiptail_menu() {
      printf "MENU\n" >>"$TRACE"
      local idx c
      idx="$(cat "$MENU_IDX_FILE")"
      [[ "$idx" -lt "${#MENU_SEQ[@]}" ]] || return 1
      c="${MENU_SEQ[$idx]}"
      printf "%s\n" "$((idx + 1))" >"$MENU_IDX_FILE"
      printf "%s\n" "$c"; return 0
    }
    mm_whiptail_msg() { printf "ERRMSG\t%s\n" "$1" >>"$TRACE"; return 0; }
    mm_whiptail_infobox() { return 0; }
    mm_whiptail_textbox() { return 0; }
    load_mirror_defaults() { :; }
    mm_load_gui_config() { TARGET_DP_VERSION=6.6.0; }
    engine_resolve_paths() { :; }
    mm_collect_workflow_status() {
      MM_WF_CONFIG_COMPLETED=0
      MM_WF_DOWNLOAD_COMPLETED=0
      MM_WF_HTTP_COMPLETED=0
      MM_WF_READINESS_COMPLETED=0
      MM_WF_PROGRESS_COUNT=0
    }
    mm_menu_label() { printf "%s\n" "$1"; }
    mm_workflow_progress_text() { printf "Progress: 0 of 4 workflow steps completed\n"; }
    gui_enable_http() { printf "ACTION_3_FAIL\n" >>"$TRACE"; return 7; }
    cmd_mirror_manager
    printf "EXIT_REASON=EXPLICIT_ZERO\n" >>"$TRACE"
  ' gui-fail-life "${WORKDIR}/fail-life.trace" "$S_LIB" "${WORKDIR}/fail-menu.idx" 2>&1
)"
FAIL_LIFE_RC=$?
set -e
[[ "$FAIL_LIFE_RC" -eq 0 ]] && grep -q 'ERRMSG' "${WORKDIR}/fail-life.trace" \
  && grep -q 'EXIT_REASON=EXPLICIT_ZERO' "${WORKDIR}/fail-life.trace" \
  && pass "S GUI_ACTION_FAILURE_DOES_NOT_EXIT=PASS" \
  || fail "S GUI_ACTION_FAILURE_DOES_NOT_EXIT out=${FAIL_LIFE}"

# Main menu ESC continues; only 0 exits.
set +e
ESC_LIFE="$(
  MM_PROJECT_ROOT="$ROOT" MM_FORCE_MENU=1 MM_SKIP_ROOT_CHECK=1 \
  MM_STATUS_FILE="${WORKDIR}/esc-life-status.env" \
  MM_CONFIG_FILE="${WORKDIR}/esc-life-gui.conf" \
  bash -c '
    set -euo pipefail
    TRACE="$1"; LIB="$2"; STEP_FILE="$3"; : >"$TRACE"
    printf "0\n" >"$STEP_FILE"
    # shellcheck disable=SC1090
    source "$LIB"
    trap - EXIT
    mm_has_whiptail() { return 0; }
    mm_whiptail_menu() {
      printf "MENU\n" >>"$TRACE"
      local step
      step="$(cat "$STEP_FILE")"
      step=$((step + 1))
      printf "%s\n" "$step" >"$STEP_FILE"
      if [[ "$step" -eq 1 ]]; then
        return 1   # ESC
      fi
      printf "0\n"; return 0
    }
    load_mirror_defaults() { :; }
    mm_load_gui_config() { :; }
    engine_resolve_paths() { :; }
    mm_collect_workflow_status() {
      MM_WF_CONFIG_COMPLETED=0
      MM_WF_DOWNLOAD_COMPLETED=0
      MM_WF_HTTP_COMPLETED=0
      MM_WF_READINESS_COMPLETED=0
      MM_WF_PROGRESS_COUNT=0
    }
    mm_menu_label() { printf "%s\n" "$1"; }
    mm_workflow_progress_text() { printf "Progress: 0 of 4 workflow steps completed\n"; }
    cmd_mirror_manager
    printf "EXIT_REASON=EXPLICIT_ZERO\n" >>"$TRACE"
  ' gui-esc-life "${WORKDIR}/esc-life.trace" "$S_LIB" "${WORKDIR}/esc-step.idx" 2>&1
)"
ESC_RC=$?
set -e
[[ "$ESC_RC" -eq 0 ]] && [[ "$(grep -c '^MENU$' "${WORKDIR}/esc-life.trace" || true)" -ge 2 ]] \
  && grep -q 'EXIT_REASON=EXPLICIT_ZERO' "${WORKDIR}/esc-life.trace" \
  && pass "S MAIN_MENU_ESC_RETURNS_MENU=PASS ONLY_ZERO_EXITS=PASS" \
  || fail "S MAIN_MENU_ESC out=${ESC_LIFE}"

# Result dialog Cancel/ESC (textbox non-zero) still returns to menu — helpers force-return 0.
grep -q 'mm_whiptail_textbox' "$INSTALLER" && grep -A2 'return 0' "$INSTALLER" | grep -q 'return 0' \
  && pass "S RESULT_DIALOG_OK/CANCEL/ESC_RETURNS_MENU=PASS" \
  || fail "S result dialog return policy"

echo "======== T. HTTP 403 / umask / wrapper ========"
# HTTP validator: only 200 is PASS (403 must FAIL).
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"
if grep -Fq '[[ "$code" != "200" ]]' "$ENGINE"; then
  pass "T HTTP_403_TREATED_AS_FAIL (200-only PASS)"
else
  fail "T HTTP validator still allows non-200 (e.g. 403)"
fi

# /offline/ directory GET is 403 with autoindex off; smoke must probe a file.
if awk '
  /^engine_http_smoke_urls\(\)/ { in_fn=1 }
  in_fn && /\/offline\/meta-release-lts/ { file=1 }
  # Exact bare directory URL only (not a prefix of meta-release-lts).
  in_fn && /\/offline\/"/ && $0 !~ /meta-release-lts/ { bare=1 }
  in_fn && /^}/ { exit((file && !bare) ? 0 : 1) }
' "$ENGINE"; then
  pass "T offline smoke probes meta-release-lts (not bare /offline/)"
else
  fail "T offline smoke still uses bare /offline/ directory URL"
fi

# HTTP 200 alone is insufficient — empty body must FAIL.
if grep -q 'empty_body' "$ENGINE"; then
  pass "T HTTP smoke rejects empty body"
else
  fail "T HTTP smoke missing non-empty body check"
fi

# Bounded disk pipeline (no full ACPS/bundle re-copy on same FS).
grep -q 'mv -f "$payload" "$final_tmp"' "$ENGINE" \
  && grep -q 'engine_stage_acps_work_from_cache' "$ENGINE" \
  && grep -q 'engine_link_acps_file_into_work' "$ENGINE" \
  && grep -q 'hardlink_required' "$ENGINE" \
  && grep -qE 'tar -cf "\$\{?dest_tmp\}?/\$\{?stable\}?"|tar -cf "\$2"' "$ENGINE" \
  && grep -q 'PHASE2_BUNDLE_CREATE' "$ENGINE" \
  && grep -q 'engine_cleanup_phase2_sources' "$ENGINE" \
  && grep -q 'DP_PHASE2_ATOMIC_PUBLISH=PASS' "$ENGINE" \
  && pass "T disk-copy optimization present" \
  || fail "T disk-copy optimization missing"

# umask restored after config save
if awk '
  /^mm_save_gui_config\(\)/ { in_fn=1 }
  in_fn && /old_umask=/ { save=1 }
  in_fn && /umask "\$old_umask"/ { restore=1 }
  in_fn && /^}/ { exit((save && restore) ? 0 : 1) }
' "${ROOT}/scripts/lib/mirror_manager_common.sh"; then
  pass "T UMASK_RESTORED after config save"
else
  fail "T umask not restored after mm_save_gui_config"
fi

# Credential config remains 600
grep -A120 '^mm_save_gui_config' "${ROOT}/scripts/lib/mirror_manager_common.sh" | grep -q 'chmod 600' \
  && pass "T CREDENTIAL_CONFIG_MODE=600" || fail "T credential chmod 600 missing"

# Public dirs 755 in bootstrap
grep -n 'chmod 755' "${ROOT}/lib/bootstrap.sh" | grep -q 'client' \
  && pass "T PUBLIC_DIRECTORY_MODE=755" || fail "T public dir 755 missing"

# Wrapper passes enable-http / verify-readiness
WRAPPER="${ROOT}/scripts/ubuntu-offline-mirror.sh"
bash "$WRAPPER" --help 2>&1 | grep -q 'enable-http' \
  && bash "$WRAPPER" --help 2>&1 | grep -q 'verify-readiness' \
  && pass "T wrapper help lists enable-http/verify-readiness" \
  || fail "T wrapper help missing enable-http/verify-readiness"
grep -q 'enable-http)' "$WRAPPER" && grep -q 'verify-readiness)' "$WRAPPER" \
  && pass "T wrapper dispatches enable-http/verify-readiness" \
  || fail "T wrapper dispatch missing"

# GUI quiet path resolve: no TTY spam under MM_GUI_MODE
set +e
PATH_OUT="$(
  MM_PROJECT_ROOT="$ROOT" MM_GUI_MODE=1 MM_LOG_FILE="${WORKDIR}/gui-paths.log" bash -c '
    set -euo pipefail
    source "'"${ROOT}"'/scripts/lib/mirror_manager_common.sh"
    source "'"${ROOT}"'/scripts/lib/mirror_install_engine.sh"
    engine_resolve_paths
  ' 2>&1
)"
set -e
if echo "$PATH_OUT" | grep -q 'MIRROR_ROOT='; then
  fail "T GUI path resolve still prints to stdout"
else
  pass "T PATH_LOG quiet on TTY under MM_GUI_MODE"
fi
grep -q 'MIRROR_ROOT=' "${WORKDIR}/gui-paths.log" \
  && pass "T PATH_LOG still written to log file" \
  || fail "T PATH_LOG missing from log file"

echo "======== DONE fail=${FAIL} ========"
exit "$FAIL"
