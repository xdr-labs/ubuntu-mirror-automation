#!/usr/bin/env bash
# ACPS remote size discovery must fail closed when TOTAL is unknown.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
DP2="${ROOT}/scripts/lib/dp-phase2-common.sh"
ACPS="${ROOT}/scripts/lib/acps_acquire.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MM_MIRROR_ROOT="${TMP}/mirror"
MM_CACHE_ROOT="${MM_MIRROR_ROOT}/.install-cache"
MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
MM_STATE_DIR="${TMP}/state"
mkdir -p "$MM_CACHE_ROOT" "$MM_STATE_DIR" "${TMP}/bin"

# shellcheck source=/dev/null
source "$COMMON"
# shellcheck source=/dev/null
source "$DP2"
# shellcheck source=/dev/null
source "$ACPS"

DP_PHASE2_VERSION=6.6.0
TARGET_DP_VERSION=6.6.0
DP_PHASE2_REQUIRED_FILES=(a.bin b.bin)
ACPS_CURL_AUTH_ARGS=()
ACPS_CURL_TLS_ARGS=()

MODE=head_ok
cat >"${TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
mode_file="${ACPS_SIZE_TEST_MODE_FILE:?}"
mode="$(cat "$mode_file")"
url="${!#}"
name="${url##*/}"
# Detect Range probe
has_range=0
for a in "$@"; do
  case "$a" in
    Range:*|*bytes=0-0*) has_range=1 ;;
  esac
done
case "$mode" in
  head_ok)
    printf 'HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n'
    ;;
  redirect_final)
    printf 'HTTP/1.1 302 Found\r\nContent-Length: 7\r\n\r\n'
    printf 'HTTP/1.1 200 OK\r\nContent-Length: 250\r\n\r\n'
    ;;
  range_total)
    if [[ "$has_range" -eq 1 ]]; then
      printf 'HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/400\r\n\r\n'
    else
      printf 'HTTP/1.1 200 OK\r\n\r\n'
    fi
    ;;
  bad_range)
    if [[ "$has_range" -eq 1 ]]; then
      printf 'HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/abc\r\n\r\n'
    else
      printf 'HTTP/1.1 200 OK\r\n\r\n'
    fi
    ;;
  unknown)
    printf 'HTTP/1.1 200 OK\r\n\r\n'
    ;;
  one_unknown)
    if [[ "$name" == "b.bin" ]]; then
      printf 'HTTP/1.1 200 OK\r\n\r\n'
    else
      printf 'HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n'
    fi
    ;;
  *) exit 22 ;;
esac
EOF
chmod +x "${TMP}/bin/curl"
export PATH="${TMP}/bin:${PATH}"
export ACPS_SIZE_TEST_MODE_FILE="${TMP}/mode"

echo head_ok >"$ACPS_SIZE_TEST_MODE_FILE"
cl="$(acps_remote_content_length "http://fixture" a.bin)" \
  || fail "head_ok should succeed"
[[ "$cl" == "100" ]] || fail "head_ok expected 100 got ${cl}"
pass "HEAD Content-Length available"

echo redirect_final >"$ACPS_SIZE_TEST_MODE_FILE"
cl="$(acps_remote_content_length "http://fixture" a.bin)" \
  || fail "redirect_final should succeed"
[[ "$cl" == "250" ]] || fail "redirect final CL expected 250 got ${cl}"
pass "redirect then final Content-Length"

echo range_total >"$ACPS_SIZE_TEST_MODE_FILE"
cl="$(acps_remote_content_length "http://fixture" a.bin)" \
  || fail "range_total should succeed"
[[ "$cl" == "400" ]] || fail "range total expected 400 got ${cl}"
pass "HEAD lacks length but Range gives TOTAL"

echo bad_range >"$ACPS_SIZE_TEST_MODE_FILE"
if acps_remote_content_length "http://fixture" a.bin >/dev/null 2>&1; then
  fail "malformed Content-Range must fail"
fi
pass "malformed Content-Range fails closed"

echo unknown >"$ACPS_SIZE_TEST_MODE_FILE"
if acps_remote_content_length "http://fixture" a.bin >/dev/null 2>&1; then
  fail "unknown size must fail"
fi
pass "neither method supplies total → fail"

echo one_unknown >"$ACPS_SIZE_TEST_MODE_FILE"
set +e
out="$(acps_expected_bytes_hint "http://fixture" 2>"${TMP}/err")"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "one unknown required artifact must fail preflight collect"
grep -q 'ACPS_REMOTE_SIZE_UNKNOWN=YES' "${TMP}/err" \
  || fail "missing ACPS_REMOTE_SIZE_UNKNOWN marker"
grep -q 'DISK_PREFLIGHT=FAIL' "${TMP}/err" \
  || fail "missing DISK_PREFLIGHT=FAIL"
pass "one large required artifact unknown → entire preflight FAIL"

echo "ALL ACPS REMOTE SIZE FAIL-CLOSED TESTS PASSED"
