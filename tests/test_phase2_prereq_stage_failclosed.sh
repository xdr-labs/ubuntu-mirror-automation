#!/usr/bin/env bash
# Phase 2 prerequisite staging is fail-closed when extras are required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="${ROOT}/client/stage-dp-phase2.sh"
FAIL=0
PASS=0
WORKDIR="$(mktemp -d)"
HTTP_PID=""
trap 'rm -rf "$WORKDIR"; [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true' EXIT

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "======== test_phase2_prereq_stage_failclosed ========"

bash -n "$STAGE" && pass "bash -n stage helper" || fail "bash -n stage helper"
grep -q 'stage_phase2_ubuntu_prerequisites || die' "$STAGE" \
  && pass "stage call is fail-closed (no || true)" \
  || fail "stage still ignores prerequisite failures"

HTTP_ROOT="${WORKDIR}/http"
mkdir -p "${HTTP_ROOT}/dp-phase2/6.6.0/extras" "${WORKDIR}/artifacts"
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

run_stage() {
  local out
  set +e
  out="$(
    export DP_PHASE2_STAGE_LIB_ONLY=1
    # shellcheck source=/dev/null
    source "$STAGE"
    ARTIFACT_DIR="${WORKDIR}/artifacts"
    mkdir -p "$ARTIFACT_DIR"
    MIRROR_URL="http://127.0.0.1:${PORT}"
    TARGET_DP_VERSION=6.6.0
    AELLA_UID="$(id -u)"
    AELLA_PRIMARY_GID="$(id -g)"
    log() { printf '%s\n' "$*"; }
    set +e
    stage_phase2_ubuntu_prerequisites
    echo RC=$?
  )"
  set -e
  printf '%s\n' "$out"
}

# A. REQUIRED=NO + count=0 => NOT_REQUIRED PASS
cat >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.state" <<'EOF'
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PACKAGE_COUNT=0
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
EOF
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=NOT_REQUIRED' \
  && echo "$OUT" | grep -q 'RC=0' \
  && pass "A NOT_REQUIRED metadata => PASS" \
  || fail "A NOT_REQUIRED: ${OUT}"

# B. state 404 => FAIL
rm -f "${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.state"
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=state_not_published' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "B missing state HTTP 404 => FAIL" \
  || fail "B missing state: ${OUT}"

# C. REQUIRED=YES + artifact 404 => FAIL
YES_SHA="$(printf 'a%.0s' {1..64})"
cat >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.state" <<EOF
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=2
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=${YES_SHA}
EOF
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=artifact_http' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "C required artifact HTTP 404 => FAIL" \
  || fail "C artifact 404: ${OUT}"

# D. REQUIRED=YES + bad SHA256 => FAIL
printf 'artifact-bytes\n' >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.tar.gz"
echo 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  phase2-ubuntu-prerequisites.tar.gz' \
  >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.tar.gz.sha256"
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=sha256' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "D required artifact bad SHA256 => FAIL" \
  || fail "D bad sha: ${OUT}"

# E. REQUIRED=YES + matching SHA256 + manifest => PASS
ART="${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.tar.gz"
printf 'artifact-bytes-ok\n' >"$ART"
(cd "$(dirname "$ART")" && sha256sum "$(basename "$ART")" >"$(basename "$ART").sha256")
GOOD_SHA="$(awk '{print $1; exit}' "${ART}.sha256")"
cat >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.state" <<EOF
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=1
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=${GOOD_SHA}
EOF
printf '{"package_count": 1}\n' \
  >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.manifest.json"
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=PASS' \
  && echo "$OUT" | grep -q 'RC=0' \
  && pass "E required artifact good SHA256 => PASS" \
  || fail "E good sha: ${OUT}"

# F. REQUIRED=YES + good SHA256 but missing manifest => FAIL
rm -f "${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.manifest.json"
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=manifest_http' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "F required artifact missing manifest => FAIL" \
  || fail "F missing manifest: ${OUT}"

write_yes_state() {
  local sha="${1:-$GOOD_SHA}"
  cat >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.state" <<EOF
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=1
PHASE2_PREREQ_BUILD=${2:-PASS}
PHASE2_PREREQ_PUBLICATION=${3:-PASS}
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=${sha}
EOF
}

# Restore a complete published YES set for later mutations.
printf 'artifact-bytes-ok\n' >"$ART"
(cd "$(dirname "$ART")" && sha256sum "$(basename "$ART")" >"$(basename "$ART").sha256")
GOOD_SHA="$(awk '{print $1; exit}' "${ART}.sha256")"
printf '{"package_count": 1}\n' \
  >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.manifest.json"

# G. REQUIRED=YES + BUILD=FAIL => FAIL even with leftover artifact
write_yes_state "$GOOD_SHA" FAIL PASS
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=build_not_pass' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "G REQUIRED=YES BUILD=FAIL => FAIL" \
  || fail "G BUILD=FAIL: ${OUT}"

# H. REQUIRED=YES + PUBLICATION=FAIL => FAIL
write_yes_state "$GOOD_SHA" PASS FAIL
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=publication_not_pass' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "H REQUIRED=YES PUBLICATION=FAIL => FAIL" \
  || fail "H PUBLICATION=FAIL: ${OUT}"

# I. REQUIRED=NO + missing count => FAIL
cat >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.state" <<'EOF'
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
EOF
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=count_missing' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "I REQUIRED=NO missing count => FAIL" \
  || fail "I missing count: ${OUT}"

# J. REQUIRED=NO + blank count => FAIL
cat >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.state" <<'EOF'
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PACKAGE_COUNT=
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
EOF
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=count_missing' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "J REQUIRED=NO blank count => FAIL" \
  || fail "J blank count: ${OUT}"

# K. REQUIRED=NO + nonnumeric count => FAIL
cat >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.state" <<'EOF'
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PACKAGE_COUNT=abc
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
EOF
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=count_nonnumeric' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "K REQUIRED=NO nonnumeric count => FAIL" \
  || fail "K nonnumeric: ${OUT}"

# L. REQUIRED=NO + count > 0 => FAIL
cat >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.state" <<'EOF'
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PACKAGE_COUNT=2
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
EOF
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=count_nonzero_when_not_required' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "L REQUIRED=NO count>0 => FAIL" \
  || fail "L NO+count: ${OUT}"

# M. REQUIRED=YES + count=0 => FAIL
cat >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.state" <<EOF
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=0
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=${GOOD_SHA}
EOF
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=count_not_positive' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "M REQUIRED=YES count=0 => FAIL" \
  || fail "M YES+count0: ${OUT}"

# N. REQUIRED=YES + missing SHA => FAIL
cat >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.state" <<'EOF'
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=1
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
EOF
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=sha256_missing' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "N REQUIRED=YES missing SHA => FAIL" \
  || fail "N missing SHA: ${OUT}"

# O. stale old artifact + new FAIL state => FAIL
write_yes_state "$GOOD_SHA" FAIL FAIL
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=build_not_pass' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "O stale artifact + FAIL state => FAIL" \
  || fail "O stale+FAIL: ${OUT}"

# P. valid REQUIRED=YES => PASS
write_yes_state "$GOOD_SHA" PASS PASS
printf '{"package_count": 1}\n' \
  >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.manifest.json"
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=PASS' \
  && echo "$OUT" | grep -q 'RC=0' \
  && pass "P valid REQUIRED=YES => PASS" \
  || fail "P valid YES: ${OUT}"

# Q. valid REQUIRED=NO => NOT_REQUIRED PASS and stale YES artifacts retracted
cat >"${HTTP_ROOT}/dp-phase2/6.6.0/extras/phase2-ubuntu-prerequisites.state" <<'EOF'
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PACKAGE_COUNT=0
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
EOF
OUT="$(run_stage)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=NOT_REQUIRED' \
  && echo "$OUT" | grep -q 'RC=0' \
  && [[ ! -f "${WORKDIR}/artifacts/phase2-ubuntu-prerequisites.tar.gz" ]] \
  && [[ ! -f "${WORKDIR}/artifacts/phase2-ubuntu-prerequisites.tar.gz.sha256" ]] \
  && [[ ! -f "${WORKDIR}/artifacts/phase2-ubuntu-prerequisites.manifest.json" ]] \
  && [[ -f "${WORKDIR}/artifacts/phase2-ubuntu-prerequisites.state" ]] \
  && pass "Q valid REQUIRED=NO => NOT_REQUIRED/PASS; stale artifact retracted" \
  || fail "Q valid NO: ${OUT}"

echo "SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
