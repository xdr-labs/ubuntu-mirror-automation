#!/usr/bin/env bash
# Phase 2 prerequisite staging is fail-closed when extras are required.
# Identity pin is the root of trust; secondary HTTP consistency remains checked.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="${ROOT}/client/stage-dp-phase2.sh"
export PHASE2_PREREQ_PY="${ROOT}/scripts/lib/phase2_ubuntu_prerequisites.py"
# shellcheck source=lib/phase2_prereq_identity_fixture.sh
source "${ROOT}/tests/lib/phase2_prereq_identity_fixture.sh"

FAIL=0
PASS=0
WORKDIR="$(mktemp -d)"
HTTP_PID=""
PIN=""
trap 'rm -rf "$WORKDIR"; [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true' EXIT

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "======== test_phase2_prereq_stage_failclosed ========"

bash -n "$STAGE" && pass "bash -n stage helper" || fail "bash -n stage helper"
grep -q 'stage_phase2_ubuntu_prerequisites || die' "$STAGE" \
  && pass "stage call is fail-closed (no || true)" \
  || fail "stage still ignores prerequisite failures"
# Controller publish must follow prerequisite staging (atomic publication).
# Use ROOT-absolute paths so this check works under tests/run_all.sh (cwd=tests/).
python3 - "$ROOT" <<'PY' && pass "controller publish after prereq staging" || fail "controller publish before prereq staging"
import sys
from pathlib import Path
body = (Path(sys.argv[1]) / "client/stage-dp-phase2.sh").read_text()
idx = body.rfind("stage_main() {")
body = body[idx:]
assert body.find("stage_phase2_ubuntu_prerequisites") < body.find("install_bringup_lifecycle_wrapper")
PY
grep -q 'EXPECTED_PREREQ_IDENTITY_SHA256' "$STAGE" \
  && pass "stage requires trusted prerequisite identity pin" \
  || fail "stage missing identity pin"

HTTP_ROOT="${WORKDIR}/http"
EXTRAS="${HTTP_ROOT}/dp-phase2/6.6.0/extras"
mkdir -p "$EXTRAS" "${WORKDIR}/artifacts"
PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$HTTP_ROOT" \
  >"${WORKDIR}/http.log" 2>&1 &
HTTP_PID=$!
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && break
  sleep 0.05
done

refresh_pin() {
  phase2_prereq_write_identity_for_extras "$EXTRAS" >/dev/null
  PIN="$(phase2_prereq_identity_sha_of "${EXTRAS}/phase2-ubuntu-prerequisites.identity")"
}

run_stage() {
  local pin
  if [[ $# -ge 1 ]]; then
    pin="$1"
  else
    pin="$PIN"
  fi
  rm -f "${WORKDIR}/artifacts/phase2-ubuntu-prerequisites."*
  set +e
  (
    export DP_PHASE2_STAGE_LIB_ONLY=1
    # shellcheck source=/dev/null
    source "$STAGE"
    ARTIFACT_DIR="${WORKDIR}/artifacts"
    mkdir -p "$ARTIFACT_DIR"
    MIRROR_URL="http://127.0.0.1:${PORT}"
    TARGET_DP_VERSION=6.6.0
    AELLA_UID="$(id -u)"
    AELLA_PRIMARY_GID="$(id -g)"
    EXPECTED_PREREQ_IDENTITY_SHA256="$pin"
    log() { printf '%s\n' "$*"; }
    set +e
    stage_phase2_ubuntu_prerequisites
    echo RC=$?
  )
  set -e
}

# A. REQUIRED=NO + count=0 => NOT_REQUIRED PASS
cat >"${EXTRAS}/phase2-ubuntu-prerequisites.state" <<'EOF'
TARGET_DP_VERSION=6.6.0
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PACKAGE_COUNT=0
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=
EOF
refresh_pin
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=NOT_REQUIRED' \
  && echo "$OUT" | grep -q 'RC=0' \
  && pass "A NOT_REQUIRED metadata => PASS" \
  || fail "A NOT_REQUIRED: ${OUT}"

# B. identity 404 => FAIL CLOSED
rm -f "${EXTRAS}/phase2-ubuntu-prerequisites.identity"
OUT="$(run_stage "$PIN")"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=identity_not_published' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "B missing identity HTTP 404 => FAIL" \
  || fail "B missing identity: ${OUT}"

# C. REQUIRED=YES + artifact 404 => FAIL
printf 'placeholder\n' >"${EXTRAS}/phase2-ubuntu-prerequisites.tar.gz"
(cd "$EXTRAS" && sha256sum phase2-ubuntu-prerequisites.tar.gz >phase2-ubuntu-prerequisites.tar.gz.sha256)
GOOD_SHA="$(awk '{print $1; exit}' "${EXTRAS}/phase2-ubuntu-prerequisites.tar.gz.sha256")"
printf '{"package_count":1,"sha256":"%s"}\n' "$GOOD_SHA" \
  >"${EXTRAS}/phase2-ubuntu-prerequisites.manifest.json"
cat >"${EXTRAS}/phase2-ubuntu-prerequisites.state" <<EOF
TARGET_DP_VERSION=6.6.0
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=1
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=${GOOD_SHA}
EOF
refresh_pin
rm -f "${EXTRAS}/phase2-ubuntu-prerequisites.tar.gz"
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=artifact_http' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "C required artifact HTTP 404 => FAIL" \
  || fail "C artifact 404: ${OUT}"

# D. REQUIRED=YES + artifact digest mismatch vs identity => FAIL
printf 'artifact-bytes\n' >"${EXTRAS}/phase2-ubuntu-prerequisites.tar.gz"
printf '%s  phase2-ubuntu-prerequisites.tar.gz\n' "$GOOD_SHA" \
  >"${EXTRAS}/phase2-ubuntu-prerequisites.tar.gz.sha256"
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL' \
  && echo "$OUT" | grep -qE 'artifact_identity_mismatch|sidecar_identity_mismatch' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "D required artifact identity mismatch => FAIL" \
  || fail "D bad sha: ${OUT}"

# E. REQUIRED=YES + matching identity binding => PASS
printf 'artifact-bytes-ok\n' >"${EXTRAS}/phase2-ubuntu-prerequisites.tar.gz"
(cd "$EXTRAS" && sha256sum phase2-ubuntu-prerequisites.tar.gz >phase2-ubuntu-prerequisites.tar.gz.sha256)
GOOD_SHA="$(awk '{print $1; exit}' "${EXTRAS}/phase2-ubuntu-prerequisites.tar.gz.sha256")"
printf '{"package_count":1,"sha256":"%s"}\n' "$GOOD_SHA" \
  >"${EXTRAS}/phase2-ubuntu-prerequisites.manifest.json"
cat >"${EXTRAS}/phase2-ubuntu-prerequisites.state" <<EOF
TARGET_DP_VERSION=6.6.0
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=1
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=${GOOD_SHA}
EOF
refresh_pin
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=PASS' \
  && echo "$OUT" | grep -q 'RC=0' \
  && pass "E required artifact good identity => PASS" \
  || fail "E good sha: ${OUT}"

# F. REQUIRED=YES + good SHA256 but missing manifest => FAIL
rm -f "${EXTRAS}/phase2-ubuntu-prerequisites.manifest.json"
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=manifest_http' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "F required artifact missing manifest => FAIL" \
  || fail "F missing manifest: ${OUT}"

# G. missing trusted pin => FAIL CLOSED
printf '{"package_count":1,"sha256":"%s"}\n' "$GOOD_SHA" \
  >"${EXTRAS}/phase2-ubuntu-prerequisites.manifest.json"
refresh_pin
OUT="$(run_stage "")"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=trusted_identity_missing' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "G missing trusted pin => FAIL CLOSED" \
  || fail "G missing pin: ${OUT}"

# H. BUILD=FAIL in authenticated identity => FAIL
cat >"${EXTRAS}/phase2-ubuntu-prerequisites.state" <<EOF
TARGET_DP_VERSION=6.6.0
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=1
PHASE2_PREREQ_BUILD=FAIL
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=${GOOD_SHA}
EOF
# Hand-write identity that still binds BUILD=FAIL (helper rejects FAIL build).
STATE_SHA="$(sha256sum "${EXTRAS}/phase2-ubuntu-prerequisites.state" | awk '{print $1}')"
ART_SHA="$GOOD_SHA"
MAN_SHA="$(sha256sum "${EXTRAS}/phase2-ubuntu-prerequisites.manifest.json" | awk '{print $1}')"
cat >"${EXTRAS}/phase2-ubuntu-prerequisites.identity" <<EOF
TARGET_DP_VERSION=6.6.0
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=1
PHASE2_PREREQ_BUILD=FAIL
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_STATE_SHA256=${STATE_SHA}
PHASE2_PREREQ_ARTIFACT_SHA256=${ART_SHA}
PHASE2_PREREQ_MANIFEST_SHA256=${MAN_SHA}
PHASE2_PREREQ_SIDECAR_SHA256=${ART_SHA}
EOF
PIN="$(phase2_prereq_identity_sha_of "${EXTRAS}/phase2-ubuntu-prerequisites.identity")"
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=build_not_pass' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "H BUILD=FAIL identity => FAIL" \
  || fail "H BUILD=FAIL: ${OUT}"

# I. valid REQUIRED=NO retracts stale YES artifacts
cat >"${EXTRAS}/phase2-ubuntu-prerequisites.state" <<'EOF'
TARGET_DP_VERSION=6.6.0
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PACKAGE_COUNT=0
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=
EOF
rm -f "${EXTRAS}/phase2-ubuntu-prerequisites.tar.gz" \
  "${EXTRAS}/phase2-ubuntu-prerequisites.tar.gz.sha256" \
  "${EXTRAS}/phase2-ubuntu-prerequisites.manifest.json"
refresh_pin
# Seed stale local YES artifacts from prior PASS.
printf 'stale\n' >"${WORKDIR}/artifacts/phase2-ubuntu-prerequisites.tar.gz"
printf 'stale\n' >"${WORKDIR}/artifacts/phase2-ubuntu-prerequisites.tar.gz.sha256"
printf '{}\n' >"${WORKDIR}/artifacts/phase2-ubuntu-prerequisites.manifest.json"
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=NOT_REQUIRED' \
  && echo "$OUT" | grep -q 'RC=0' \
  && [[ ! -f "${WORKDIR}/artifacts/phase2-ubuntu-prerequisites.tar.gz" ]] \
  && [[ ! -f "${WORKDIR}/artifacts/phase2-ubuntu-prerequisites.tar.gz.sha256" ]] \
  && [[ ! -f "${WORKDIR}/artifacts/phase2-ubuntu-prerequisites.manifest.json" ]] \
  && [[ -f "${WORKDIR}/artifacts/phase2-ubuntu-prerequisites.state" ]] \
  && [[ -f "${WORKDIR}/artifacts/phase2-ubuntu-prerequisites.identity" ]] \
  && pass "I valid REQUIRED=NO => NOT_REQUIRED; stale artifact retracted" \
  || fail "I valid NO: ${OUT}"

echo "SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
