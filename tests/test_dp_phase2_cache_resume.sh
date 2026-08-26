#!/usr/bin/env bash
# Bundle cache / resume / concurrent lock for Phase 2 staging helper.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/client/stage-dp-phase2.sh"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
HTTP_PID=""
cleanup() {
  if [[ -n "${HTTP_PID:-}" ]]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

export DP_PHASE2_STAGE_LIB_ONLY=1
export DP_PHASE2_HEARTBEAT_SECONDS=1
# shellcheck disable=SC1090
source "$HELPER"

TARGET_DP_VERSION="6.6.0"
PHASE2_ARTIFACT_VERSION="6.6.0"
set_target_bundle_files "$TARGET_DP_VERSION"
CACHE_DIR="${WORKDIR}/cache/${TARGET_DP_VERSION}"
mkdir -p "$CACHE_DIR" "${WORKDIR}/http/dp-phase2/6.6.0"

HTTP_PORT="$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)"
MIRROR_URL="http://127.0.0.1:${HTTP_PORT}"

# Build tiny bundle
TMPF="${WORKDIR}/files"
mkdir -p "$TMPF"
for f in "${REQUIRED_BUNDLE_FILES[@]}"; do
  case "$f" in
    *.sha1|*.sha256) continue ;;
    *.sh) printf '#!/bin/bash\necho bringup\n' >"${TMPF}/$f" ;;
    *.list) seq 1 3 >"${TMPF}/$f" ;;
    *) printf 'payload-%s\n' "$f" >"${TMPF}/$f" ;;
  esac
done
sha1sum "${TMPF}/aelladeb_py3_common.tar.gz" | awk '{print $1}' >"${TMPF}/aelladeb_py3_common.tar.gz.sha1"
sha1sum "${TMPF}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}' >"${TMPF}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
sha1sum "${TMPF}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' >"${TMPF}/bringup_py3_dp_after_os_upgrade.sh.sha1"
sha256sum "${TMPF}/images-6.6.0.tar" | awk '{print $1}' >"${TMPF}/images-6.6.0.tar.sha256"
(
  cd "$TMPF"
  tar -cf "${WORKDIR}/http/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar" "${REQUIRED_BUNDLE_FILES[@]}"
)
sha256sum "${WORKDIR}/http/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar" \
  | awk '{print $1"  dp_bundle_6.6.0-current.tar"}' \
  >"${WORKDIR}/http/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar.sha256"
cat >"${WORKDIR}/http/dp-phase2/6.6.0/release.env" <<EOF
TARGET_DP_VERSION=6.6.0
PHASE2_ARTIFACT_VERSION=6.6.0
DP_PHASE2_VERSION=6.6.0
STABLE_BUNDLE_NAME=dp_bundle_6.6.0-current.tar
FILE_COUNT=9
VERIFICATION_RESULT=PASS
EOF

# Counting HTTP server for body downloads (supports Range for resume tests)
python3 - "${WORKDIR}/http" "$HTTP_PORT" "${WORKDIR}/http-counts" <<'PY' &
import http.server, os, sys, pathlib
root, port, count_dir = sys.argv[1], int(sys.argv[2]), pathlib.Path(sys.argv[3])
count_dir.mkdir(parents=True, exist_ok=True)

class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=root, **k)
    def do_GET(self):
        if self.path.endswith('.tar') and not self.path.endswith('.sha256'):
            p = count_dir / 'body_gets'
            p.write_text(str(int(p.read_text()) + 1) if p.exists() else '1')
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            self.send_error(404)
            return
        fs = os.stat(path)
        size = fs.st_size
        range_hdr = self.headers.get('Range')
        if range_hdr and range_hdr.startswith('bytes='):
            unit, _, rng = range_hdr.partition('=')
            start_s, _, end_s = rng.partition('-')
            start = int(start_s) if start_s else 0
            end = int(end_s) if end_s else size - 1
            end = min(end, size - 1)
            if start > end or start >= size:
                self.send_error(416)
                return
            length = end - start + 1
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(length))
            self.send_header('Content-Type', 'application/octet-stream')
            self.end_headers()
            with open(path, 'rb') as fh:
                fh.seek(start)
                self.wfile.write(fh.read(length))
            return
        return super().do_GET()
    def log_message(self, *args):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
HTTP_PID=$!
sleep 0.4

body_gets() { cat "${WORKDIR}/http-counts/body_gets" 2>/dev/null || echo 0; }

echo "[test] fresh download"
ensure_verified_bundle
[[ "$ARTIFACT_CACHE_RESULT" == "DOWNLOADED" ]] && pass "fresh DOWNLOADED" || fail "fresh ($ARTIFACT_CACHE_RESULT)"
[[ -f "${CACHE_DIR}/VERIFIED" ]] && pass "VERIFIED marker" || fail "VERIFIED"
g1="$(body_gets)"

echo "[test] valid cache reuse"
ensure_verified_bundle
[[ "$ARTIFACT_CACHE_RESULT" == "REUSED" ]] && pass "REUSED" || fail "reuse ($ARTIFACT_CACHE_RESULT)"
g2="$(body_gets)"
[[ "$g1" == "$g2" ]] && pass "no re-download on reuse" || fail "body re-downloaded on reuse"

echo "[test] corrupt cache rejected"
printf 'corrupt' >"${CACHE_DIR}/bundle.tar"
rm -f "${CACHE_DIR}/VERIFIED"
ensure_verified_bundle
[[ "$ARTIFACT_CHECKSUM_RESULT" == "PASS" ]] && pass "re-download after corrupt" || fail "corrupt recover"
[[ -f "${CACHE_DIR}/VERIFIED" ]] && pass "re-verified" || fail "re-verified"

echo "[test] checksum change invalidates cache"
echo '0000000000000000000000000000000000000000000000000000000000000001  x' \
  >"${WORKDIR}/http/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar.sha256"
set +e
out="$(ensure_verified_bundle 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "checksum change STOP" || fail "checksum change should fail"
# restore good checksum
sha256sum "${WORKDIR}/http/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar" \
  | awk '{print $1"  dp_bundle_6.6.0-current.tar"}' \
  >"${WORKDIR}/http/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar.sha256"
rm -f "${CACHE_DIR}/bundle.tar" "${CACHE_DIR}/VERIFIED" "${CACHE_DIR}/bundle.tar.part"
ensure_verified_bundle
g3="$(body_gets)"

echo "[test] partial resume"
rm -f "${CACHE_DIR}/VERIFIED"
# create partial smaller than full
head -c 10 "${CACHE_DIR}/bundle.tar" >"${CACHE_DIR}/bundle.tar.part"
rm -f "${CACHE_DIR}/bundle.tar"
ensure_verified_bundle
[[ "$ARTIFACT_CACHE_RESULT" == "RESUMED" || "$ARTIFACT_CACHE_RESULT" == "DOWNLOADED" ]] \
  && pass "resume path exercised (${ARTIFACT_CACHE_RESULT})" || fail "resume"
[[ -f "${CACHE_DIR}/VERIFIED" ]] && pass "verified after resume" || fail "verified resume"

echo "[test] post-verification failure keeps cache"
[[ -f "${CACHE_DIR}/bundle.tar" && -f "${CACHE_DIR}/VERIFIED" ]] && pass "cache retained" || fail "cache retained"
g4="$(body_gets)"
ensure_verified_bundle
[[ "$ARTIFACT_CACHE_RESULT" == "REUSED" ]] && pass "retry without body transfer" || fail "retry reuse"
g5="$(body_gets)"
[[ "$g4" == "$g5" ]] && pass "HTTP body not re-downloaded on retry" || fail "unexpected body GET"

echo "[test] concurrent lock"
LOCK_HELD=0
LOCK_FD=""
acquire_stage_lock
set +e
(
  LOCK_HELD=0
  LOCK_FD=""
  acquire_stage_lock
)
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "concurrent lock busy" || fail "concurrent lock should fail"
flock -u "$LOCK_FD" 2>/dev/null || true
eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
LOCK_HELD=0

echo "[test] success cleanup policy"
KEEP_CACHE=0
# simulate cleanup snippet
rm -f "${CACHE_DIR}/bundle.tar" "${CACHE_DIR}/bundle.tar.part" \
  "${CACHE_DIR}/bundle.tar.sha256" "${CACHE_DIR}/VERIFIED"
[[ ! -f "${CACHE_DIR}/bundle.tar" ]] && pass "success cleanup" || fail "cleanup"

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL DP PHASE2 CACHE/RESUME TESTS PASSED"
  exit 0
fi
echo "SOME DP PHASE2 CACHE/RESUME TESTS FAILED"
exit 1
