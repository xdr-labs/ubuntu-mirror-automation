#!/usr/bin/env bash
# Host-pin gates: generated clients must embed the local Mirror URL.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/client_mirror_gates.sh"

echo "=== test_client_mirror_pin_gates ==="

HOST_A="http://192.0.2.10"
HOST_B="http://192.0.2.20"

make_client() {
  local out="$1" base="$2"
  local meta="${out}.meta"
  cat >"$meta" <<EOF
Dist: bionic
Release-File: ${base}/hops/xenial-to-bionic/ubuntu/dists/bionic/Release
UpgradeTool: ${base}/offline/release-upgraders/bionic/bionic.tar.gz
UpgradeToolSignature: ${base}/offline/release-upgraders/bionic/bionic.tar.gz.gpg
EOF
  local meta_b64 manifest_b64
  meta_b64="$(base64 -w0 "$meta")"
  printf '{"schema_version":1,"mirror_base":"%s","sample_deb_url":"%s/sample.deb"}\n' \
    "$base" "$base" >"${out}.manifest"
  manifest_b64="$(base64 -w0 "${out}.manifest")"
  cat >"$out" <<EOF
#!/usr/bin/env bash
PIN_MIRROR_BASE='${base}'
PIN_SAMPLE_DEB_URL='${base}/hops/xenial-to-bionic/ubuntu/pool/main/h/hello/hello.deb'
PIN_META_B64='${meta_b64}'
PIN_MANIFEST_B64='${manifest_b64}'
EOF
}

PINNED_A="${WORKDIR}/a.sh"
PINNED_B="${WORKDIR}/b.sh"
EMPTY="${WORKDIR}/empty.sh"
make_client "$PINNED_A" "$HOST_A"
make_client "$PINNED_B" "$HOST_B"
cat >"$EMPTY" <<'EOF'
#!/usr/bin/env bash
PIN_MIRROR_BASE=''
PIN_SAMPLE_DEB_PATH='/hops/x/sample.deb'
PIN_META_B64='QEBNSVJST1JfQkFTRUA='
PIN_MANIFEST_B64='e30K'
EOF

out="$(client_assert_mirror_base_match "$PINNED_A" "$HOST_A" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && pass "Host A pin accepted" || fail "Host A pin rejected: ${out}"

out="$(client_assert_mirror_base_match "$PINNED_A" "$HOST_B" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && pass "Host A vs B mismatch rejected" || fail "cross-host pin unexpectedly accepted"

out="$(client_assert_generic_artifact "$EMPTY" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && pass "empty PIN_MIRROR_BASE rejected" || fail "empty pin accepted"

# Runtime command gate
cmd="curl -fsSLO ${HOST_A}/client/x.sh && sudo bash ./x.sh --mirror-base ${HOST_A}"
out="$(printf '%s\n' "$cmd" | client_assert_command_mirror_base - "$HOST_A" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && pass "runtime command gate PASS" || fail "runtime command gate: ${out}"

out="$(printf '%s\n' "$cmd" | client_assert_command_mirror_base - "$HOST_B" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && pass "runtime command wrong host rejected" || fail "wrong-host command accepted"

# Regression: mirror addresses are LITERAL host pins, never regex patterns.
# A visually similar but different hostname must not match the IPv4 dots.
SPOOF="http://192-0-2-10"
SPOOFED_SAMPLE="${WORKDIR}/sample-spoof.sh"
python3 - "$PINNED_A" "$SPOOFED_SAMPLE" "$HOST_A" "$SPOOF" <<'PY_HOSTPIN_SPOOF'
from pathlib import Path
import sys
source, dest, correct, wrong = sys.argv[1:]
data = Path(source).read_text()
old = "PIN_SAMPLE_DEB_URL='{}{}".format(correct, "/")
new = "PIN_SAMPLE_DEB_URL='{}{}".format(wrong, "/")
assert data.count(old) == 1
Path(dest).write_text(data.replace(old, new))
PY_HOSTPIN_SPOOF
out="$(client_assert_mirror_base_match "$SPOOFED_SAMPLE" "$HOST_A" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && pass "regex-lookalike sample deb host rejected" \
  || fail "regex-lookalike sample deb host accepted: ${out}"

# A wrong literal --mirror-base/-url must fail even if a correct download URL
# or an earlier duplicate option is present.
cmd="curl -fsSL ${HOST_A}/client/x.sh && bash ./x.sh --mirror-base ${SPOOF}"
out="$(client_assert_command_mirror_base "$cmd" "$HOST_A" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && pass "regex-lookalike --mirror-base rejected" \
  || fail "regex-lookalike --mirror-base accepted: ${out}"

cmd="curl -fsSL ${HOST_A}/client/stage-dp-phase2.sh && bash ./stage-dp-phase2.sh --mirror-url ${SPOOF}"
out="$(client_assert_command_mirror_base "$cmd" "$HOST_A" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && pass "regex-lookalike --mirror-url rejected" \
  || fail "regex-lookalike --mirror-url accepted: ${out}"

cmd="curl -fsSL ${HOST_A}/client/x.sh && bash ./x.sh --mirror-base ${HOST_A} --mirror-base ${HOST_B}"
out="$(client_assert_command_mirror_base "$cmd" "$HOST_A" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && pass "duplicate conflicting --mirror-base rejected" \
  || fail "duplicate conflicting --mirror-base accepted: ${out}"

cmd="curl -fsSL ${HOST_A}/client/stage-dp-phase2.sh && bash ./stage-dp-phase2.sh --mirror-url ${HOST_A} --mirror-url ${HOST_B}"
out="$(client_assert_command_mirror_base "$cmd" "$HOST_A" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && pass "duplicate conflicting --mirror-url rejected" \
  || fail "duplicate conflicting --mirror-url accepted: ${out}"

# Valid one-line commands remain supported (positive controls).
cmd="curl -fsSL ${HOST_A}/client/stage-dp-phase2.sh && bash ./stage-dp-phase2.sh --mirror-url ${HOST_A}"
out="$(client_assert_command_mirror_base "$cmd" "$HOST_A" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && pass "literal correct --mirror-url accepted" \
  || fail "literal correct --mirror-url rejected: ${out}"

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_client_mirror_pin_gates PASS ==="
  exit 0
fi
echo "=== test_client_mirror_pin_gates FAIL ==="
exit 1
