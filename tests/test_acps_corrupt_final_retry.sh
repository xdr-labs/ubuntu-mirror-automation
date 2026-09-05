#!/usr/bin/env bash
# P2: corrupt existing ACPS finals must not be skipped forever on Menu 2 retry.
# Checksum verification remains authoritative; only invalid payloads are removed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
DP2="${ROOT}/scripts/lib/dp-phase2-common.sh"
ACPS="${ROOT}/scripts/lib/acps_acquire.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

export MM_PROJECT_ROOT="$ROOT"
export MM_MIRROR_ROOT="${TMP}/mirror"
export MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
export MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
export MM_SELECTIVE_ROOT="${MM_MIRROR_ROOT}/selective"
export MM_STATE_DIR="${TMP}/state"
export MM_LOG_DIR="${TMP}/logs"
export MM_CONFIG_DIR="${TMP}/config"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/config"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export MM_SKIP_ROOT_CHECK=1
export MM_LOG_FILE="${TMP}/acps-corrupt.log"
mkdir -p "$MM_CACHE_ROOT" "$MM_STATE_DIR" "$MM_CONFIG_DIR" "$MM_LOG_DIR" \
  "$MM_DP_PHASE2_ROOT" "$MM_SELECTIVE_ROOT"
: >"$MM_STATUS_FILE"
: >"$MM_LOG_FILE"

# shellcheck source=/dev/null
source "$COMMON"
# shellcheck source=/dev/null
source "$DP2"
# shellcheck source=/dev/null
source "$ACPS"

dp2_set_version 6.6.0
CACHE="$(acps_cache_dir 6.6.0)"
ORIGIN="${TMP}/origin"
mkdir -p "$CACHE" "$ORIGIN"
REQUEST_LOG="${TMP}/http-requests.log"
: >"$REQUEST_LOG"

seed_payloads_into() {
  local dir="$1"
  mkdir -p "$dir"
  printf 'common-payload\n' >"${dir}/aelladeb_py3_common.tar.gz"
  sha1sum "${dir}/aelladeb_py3_common.tar.gz" | awk '{print $1}' \
    >"${dir}/aelladeb_py3_common.tar.gz.sha1"
  printf 'uvp-payload\n' >"${dir}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb"
  sha1sum "${dir}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}' \
    >"${dir}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
  printf 'bringup-payload\n' >"${dir}/bringup_py3_dp_after_os_upgrade.sh"
  sha1sum "${dir}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
    >"${dir}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  seq 1 3 >"${dir}/images-6.6.0.list"
  # Distinct large-ish final used to prove unrelated files are not redownloaded.
  python3 - <<'PY' "$dir/images-6.6.0.tar"
import sys
path = sys.argv[1]
with open(path, "wb") as fh:
    fh.write(b"IMAGES-VALID-PAYLOAD\n" + (b"X" * 256000))
PY
  sha256sum "${dir}/images-6.6.0.tar" | awk '{print $1 "  images-6.6.0.tar"}' \
    >"${dir}/images-6.6.0.tar.sha256"
}

seed_payloads_into "$ORIGIN"
cp -a "$ORIGIN"/. "$CACHE"/

# Local ACPS origin (no credentials): DP_PHASE2_SOURCE_BASE skips netrc auth.
PORT_FILE="${TMP}/origin.port"
python3 - "$ORIGIN" "$PORT_FILE" "$REQUEST_LOG" <<'PY' &
import http.server
import pathlib
import socketserver
import sys

root = pathlib.Path(sys.argv[1])
port_file = pathlib.Path(sys.argv[2])
req_log = pathlib.Path(sys.argv[3])

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(root), **kwargs)

    def do_GET(self):
        name = pathlib.Path(self.path.split("?", 1)[0]).name
        with req_log.open("a", encoding="utf-8") as fh:
            fh.write("GET %s\n" % name)
        return super().do_GET()

    def do_HEAD(self):
        name = pathlib.Path(self.path.split("?", 1)[0]).name
        with req_log.open("a", encoding="utf-8") as fh:
            fh.write("HEAD %s\n" % name)
        return super().do_HEAD()

    def log_message(self, *_args):
        pass

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

server = Server(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_address[1]))
server.serve_forever()
PY
SERVER_PID=$!
for _ in $(seq 1 50); do
  [[ -s "$PORT_FILE" ]] && break
  sleep 0.05
done
[[ -s "$PORT_FILE" ]] || fail "origin HTTP server did not start"
PORT="$(cat "$PORT_FILE")"
export DP_PHASE2_SOURCE_BASE="http://127.0.0.1:${PORT}"
ACPS_EFFECTIVE_BASE="$DP_PHASE2_SOURCE_BASE"
ACPS_CURL_AUTH_ARGS=()
ACPS_CURL_TLS_ARGS=()
ACPS_CURL_RETRIES=0

# --- A: verified cache reused; ACPS not contacted ---
mm_acps_verify_payload_checksums "$CACHE" >/dev/null
acps_write_verified_marker "$CACHE" || fail "write verified marker"
: >"$REQUEST_LOG"
if ! acps_acquire_all 6.6.0 >"${TMP}/reuse.log" 2>&1; then
  fail "verified cache acquire failed"
fi
grep -q 'ACPS_DOWNLOAD=REUSED' "${TMP}/reuse.log" || fail "missing ACPS_DOWNLOAD=REUSED"
if grep -qE '^(GET|HEAD) ' "$REQUEST_LOG"; then
  fail "verified reuse contacted ACPS"
fi
pass "A verified cache reused without contacting ACPS"

# --- B: valid existing finals remain reusable (skip download, verify pass) ---
rm -f "${CACHE}/.VERIFIED"
: >"$REQUEST_LOG"
IMG_INO_BEFORE="$(stat -c '%d:%i' "${CACHE}/images-6.6.0.tar")"
BRING_INO_BEFORE="$(stat -c '%d:%i' "${CACHE}/bringup_py3_dp_after_os_upgrade.sh")"
if ! acps_acquire_all 6.6.0 >"${TMP}/valid-exist.log" 2>&1; then
  cat "${TMP}/valid-exist.log" >&2
  fail "valid existing finals acquire failed"
fi
grep -q 'ACPS_DOWNLOAD_SKIP_EXISTING' "${TMP}/valid-exist.log" \
  || fail "expected skip-existing for valid finals"
grep -q 'ACPS_DOWNLOAD=PASS' "${TMP}/valid-exist.log" || fail "missing ACPS_DOWNLOAD=PASS"
[[ "$(stat -c '%d:%i' "${CACHE}/images-6.6.0.tar")" == "$IMG_INO_BEFORE" ]] \
  || fail "valid images final was replaced"
[[ "$(stat -c '%d:%i' "${CACHE}/bringup_py3_dp_after_os_upgrade.sh")" == "$BRING_INO_BEFORE" ]] \
  || fail "valid bringup final was replaced"
# HEAD may probe sizes; GET of payload bodies must not occur for complete finals.
if grep -qE '^GET ' "$REQUEST_LOG"; then
  fail "valid existing finals triggered GET redownload"
fi
pass "B valid existing finals remain reusable"

# --- C/D: corrupt final rejected; only the bad final invalidated ---
rm -f "${CACHE}/.VERIFIED"
printf 'CORRUPT-BRINGUP\n' >"${CACHE}/bringup_py3_dp_after_os_upgrade.sh"
IMG_INO_BEFORE="$(stat -c '%d:%i' "${CACHE}/images-6.6.0.tar")"
COMMON_INO_BEFORE="$(stat -c '%d:%i' "${CACHE}/aelladeb_py3_common.tar.gz")"
UVP_INO_BEFORE="$(stat -c '%d:%i' "${CACHE}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb")"
set +e
( acps_acquire_all 6.6.0 >"${TMP}/corrupt.log" 2>&1 )
CORRUPT_RC=$?
set -e
[[ "$CORRUPT_RC" -ne 0 ]] || fail "corrupt final was accepted"
grep -q 'ACPS_CHECKSUM=FAIL\|SHA1_VERIFY=FAIL' "${TMP}/corrupt.log" \
  || fail "expected checksum failure for corrupt final"
grep -q 'ACPS_CORRUPT_FINAL_INVALIDATE file=bringup_py3_dp_after_os_upgrade.sh' \
  "${TMP}/corrupt.log" || {
  cat "${TMP}/corrupt.log" >&2
  fail "corrupt bringup was not invalidated"
}
[[ ! -f "${CACHE}/bringup_py3_dp_after_os_upgrade.sh" ]] \
  || fail "corrupt bringup final still present after invalidate"
[[ -f "${CACHE}/images-6.6.0.tar" ]] || fail "unrelated images final was removed"
[[ -f "${CACHE}/aelladeb_py3_common.tar.gz" ]] || fail "unrelated common final was removed"
[[ "$(stat -c '%d:%i' "${CACHE}/images-6.6.0.tar")" == "$IMG_INO_BEFORE" ]] \
  || fail "images final inode changed on corrupt bringup failure"
[[ "$(stat -c '%d:%i' "${CACHE}/aelladeb_py3_common.tar.gz")" == "$COMMON_INO_BEFORE" ]] \
  || fail "common final inode changed on corrupt bringup failure"
[[ "$(stat -c '%d:%i' "${CACHE}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb")" == "$UVP_INO_BEFORE" ]] \
  || fail "uvp final inode changed on corrupt bringup failure"
pass "C corrupt existing final is not accepted"
pass "D checksum failure invalidates only the bad final"

# --- E/F: subsequent retry redownloads only the bad final and succeeds ---
: >"$REQUEST_LOG"
IMG_INO_BEFORE="$(stat -c '%d:%i' "${CACHE}/images-6.6.0.tar")"
if ! acps_acquire_all 6.6.0 >"${TMP}/retry.log" 2>&1; then
  cat "${TMP}/retry.log" >&2
  fail "retry after invalidate failed"
fi
grep -q 'ACPS_DOWNLOAD=PASS' "${TMP}/retry.log" || fail "retry missing ACPS_DOWNLOAD=PASS"
[[ -f "${CACHE}/bringup_py3_dp_after_os_upgrade.sh" ]] || fail "bringup not restored"
mm_acps_verify_payload_checksums "$CACHE" >/dev/null \
  || fail "retry left unverifiable cache"
grep -qE '^GET bringup_py3_dp_after_os_upgrade\.sh$' "$REQUEST_LOG" \
  || fail "retry did not GET the invalidated bringup"
if grep -qE '^GET images-6\.6\.0\.tar$' "$REQUEST_LOG"; then
  fail "unrelated valid images final was redownloaded"
fi
if grep -qE '^GET aelladeb_py3_common\.tar\.gz$' "$REQUEST_LOG"; then
  fail "unrelated valid common final was redownloaded"
fi
[[ "$(stat -c '%d:%i' "${CACHE}/images-6.6.0.tar")" == "$IMG_INO_BEFORE" ]] \
  || fail "images final replaced on heal retry"
pass "E subsequent retry downloads/replaces the bad final and succeeds"
pass "F unrelated valid large finals are not redownloaded"

# --- G: no trust fail-open (corrupt body vs authoritative sidecar still fails;
#     pure verify without invalidate must not delete; acquire still fail-closed)
rm -f "${CACHE}/.VERIFIED"
printf 'still-corrupt\n' >"${CACHE}/bringup_py3_dp_after_os_upgrade.sh"
cp -a "${ORIGIN}/bringup_py3_dp_after_os_upgrade.sh.sha1" \
  "${CACHE}/bringup_py3_dp_after_os_upgrade.sh.sha1"
set +e
mm_acps_verify_payload_checksums "$CACHE" >/dev/null 2>&1
G_RC=$?
set -e
[[ "$G_RC" -ne 0 ]] || fail "trust fail-open: corrupt body accepted by verify"
[[ -f "${CACHE}/bringup_py3_dp_after_os_upgrade.sh" ]] \
  || fail "pure verify unexpectedly deleted corrupt final"
set +e
( acps_acquire_all 6.6.0 >"${TMP}/failopen.log" 2>&1 )
FO_RC=$?
set -e
[[ "$FO_RC" -ne 0 ]] || fail "acquire fail-open accepted corrupt bringup"
grep -q 'ACPS_CORRUPT_FINAL_INVALIDATE file=bringup_py3_dp_after_os_upgrade.sh' \
  "${TMP}/failopen.log" || fail "acquire path did not invalidate corrupt final"
[[ ! -f "${CACHE}/.VERIFIED" ]] || fail "fail-open wrote .VERIFIED after checksum FAIL"
pass "G no trust fail-open introduced"

echo "ACPS_CORRUPT_FINAL_RETRY=PASS"
exit 0
