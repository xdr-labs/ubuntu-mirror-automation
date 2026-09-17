#!/usr/bin/env bash
# Phase 2 prerequisite identity trust: pin-bound contract rejects MITM of
# mutually consistent HTTP artifacts and REQUIRED=NO→YES flips.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="${ROOT}/client/stage-dp-phase2.sh"
PY="${ROOT}/scripts/lib/phase2_ubuntu_prerequisites.py"
# shellcheck source=lib/phase2_prereq_identity_fixture.sh
source "${ROOT}/tests/lib/phase2_prereq_identity_fixture.sh"
export PHASE2_PREREQ_PY="$PY"

FAIL=0
PASS=0
WORKDIR="$(mktemp -d)"
HTTP_PID=""
trap 'rm -rf "$WORKDIR"; [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true' EXIT

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "======== test_phase2_prereq_identity_trust ========"

EXTRAS="${WORKDIR}/http/dp-phase2/6.6.0/extras"
mkdir -p "$EXTRAS" "${WORKDIR}/artifacts"
PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "${WORKDIR}/http" \
  >"${WORKDIR}/http.log" 2>&1 &
HTTP_PID=$!
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && break
  sleep 0.05
done

write_yes_set() {
  local dest="$1"
  local payload="${2:-authentic-prereq-bytes}"
  mkdir -p "$dest"
  printf '%s\n' "$payload" >"${dest}/phase2-ubuntu-prerequisites.tar.gz"
  local sha
  sha="$(sha256sum "${dest}/phase2-ubuntu-prerequisites.tar.gz" | awk '{print $1}')"
  printf '%s  phase2-ubuntu-prerequisites.tar.gz\n' "$sha" \
    >"${dest}/phase2-ubuntu-prerequisites.tar.gz.sha256"
  printf '{"package_count":1,"sha256":"%s"}\n' "$sha" \
    >"${dest}/phase2-ubuntu-prerequisites.manifest.json"
  cat >"${dest}/phase2-ubuntu-prerequisites.state" <<EOF
TARGET_DP_VERSION=6.6.0
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=1
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=${sha}
EOF
  phase2_prereq_write_identity_for_extras "$dest" >/dev/null
}

write_no_set() {
  local dest="$1"
  mkdir -p "$dest"
  rm -f "${dest}/phase2-ubuntu-prerequisites.tar.gz" \
    "${dest}/phase2-ubuntu-prerequisites.tar.gz.sha256" \
    "${dest}/phase2-ubuntu-prerequisites.manifest.json"
  cat >"${dest}/phase2-ubuntu-prerequisites.state" <<'EOF'
TARGET_DP_VERSION=6.6.0
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PACKAGE_COUNT=0
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=
EOF
  phase2_prereq_write_identity_for_extras "$dest" >/dev/null
}

publish_from() {
  local src="$1"
  rm -rf "$EXTRAS"
  mkdir -p "$EXTRAS"
  cp -a "${src}/." "$EXTRAS/"
}

run_stage() {
  local pin="${1:-}"
  local wipe="${2:-1}"
  set +e
  (
    export DP_PHASE2_STAGE_LIB_ONLY=1
    # shellcheck source=/dev/null
    source "$STAGE"
    ARTIFACT_DIR="${WORKDIR}/artifacts"
    mkdir -p "$ARTIFACT_DIR"
    if [[ "$wipe" == "1" ]]; then
      rm -f "${ARTIFACT_DIR}/phase2-ubuntu-prerequisites."*
    fi
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

# A) authentic REQUIRED=YES
YES="${WORKDIR}/yes"
write_yes_set "$YES" authentic-yes
publish_from "$YES"
PIN_YES="$(phase2_prereq_identity_sha_of "${YES}/phase2-ubuntu-prerequisites.identity")"
OUT="$(run_stage "$PIN_YES" 1)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=PASS' \
  && echo "$OUT" | grep -q 'PHASE2_PREREQ_IDENTITY=PASS' \
  && echo "$OUT" | grep -q 'RC=0' \
  && pass "A authentic REQUIRED=YES" \
  || fail "A YES: ${OUT}"

# J) reuse already verified authentic prerequisite
OUT="$(run_stage "$PIN_YES" 0)"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=PASS' \
  && echo "$OUT" | grep -q 'mode=reused' \
  && echo "$OUT" | grep -q 'RC=0' \
  && pass "J reuse verified authentic prerequisite" \
  || fail "J reuse: ${OUT}"

# B) authentic REQUIRED=NO
NO="${WORKDIR}/no"
write_no_set "$NO"
publish_from "$NO"
PIN_NO="$(phase2_prereq_identity_sha_of "${NO}/phase2-ubuntu-prerequisites.identity")"
OUT="$(run_stage "$PIN_NO")"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=NOT_REQUIRED' \
  && echo "$OUT" | grep -q 'RC=0' \
  && pass "B authentic REQUIRED=NO" \
  || fail "B NO: ${OUT}"

# C) tar-only tamper
publish_from "$YES"
printf 'tampered-tar\n' >"${EXTRAS}/phase2-ubuntu-prerequisites.tar.gz"
OUT="$(run_stage "$PIN_YES")"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL' \
  && echo "$OUT" | grep -qE 'artifact_identity_mismatch|sidecar_identity_mismatch' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "C tar-only tamper FAIL" \
  || fail "C tar-only: ${OUT}"

# D) state-only tamper
publish_from "$YES"
awk '{if($0 ~ /^PHASE2_PREREQ_PACKAGE_COUNT=/) print "PHASE2_PREREQ_PACKAGE_COUNT=2"; else print}' \
  "${YES}/phase2-ubuntu-prerequisites.state" >"${EXTRAS}/phase2-ubuntu-prerequisites.state"
OUT="$(run_stage "$PIN_YES")"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=state_identity_mismatch' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "D state-only tamper FAIL" \
  || fail "D state-only: ${OUT}"

# E) manifest-only tamper
publish_from "$YES"
printf '{"package_count":99,"sha256":"deadbeef"}\n' \
  >"${EXTRAS}/phase2-ubuntu-prerequisites.manifest.json"
OUT="$(run_stage "$PIN_YES")"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=manifest_identity_mismatch' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "E manifest-only tamper FAIL" \
  || fail "E manifest-only: ${OUT}"

# F) sidecar-only tamper
publish_from "$YES"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  phase2-ubuntu-prerequisites.tar.gz\n' \
  >"${EXTRAS}/phase2-ubuntu-prerequisites.tar.gz.sha256"
OUT="$(run_stage "$PIN_YES")"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=sidecar_identity_mismatch' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "F sidecar-only tamper FAIL" \
  || fail "F sidecar-only: ${OUT}"

# G) attacker replaces state+tar+sidecar+manifest consistently
ATTACK="${WORKDIR}/attack-g"
write_yes_set "$ATTACK" attacker-controlled-payload
publish_from "$ATTACK"
# Keep authentic pin from original YES set — attacker identity differs.
OUT="$(run_stage "$PIN_YES")"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=identity_pin_mismatch' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "G consistent four-artifact MITM FAIL" \
  || fail "G all-four MITM: ${OUT}"

# H) flip authenticated REQUIRED=NO to YES with matching attacker artifacts
publish_from "$ATTACK"
OUT="$(run_stage "$PIN_NO")"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=identity_pin_mismatch' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "H REQUIRED=NO→YES flip with attacker set FAIL" \
  || fail "H NO-to-YES: ${OUT}"

# I) missing trusted prerequisite identity pin → fail closed
publish_from "$YES"
OUT="$(run_stage "")"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=trusted_identity_missing' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "I missing trusted identity FAIL CLOSED" \
  || fail "I missing pin: ${OUT}"

# K) trusted identity for 6.5.0 served under 6.6.0 URL → reject (target binding)
CROSS="${WORKDIR}/cross-650"
write_yes_set "$CROSS" cross-target-650
# Rewrite identity+state target to 6.5.0 while publishing under 6.6.0 extras URL.
awk '{if($0 ~ /^TARGET_DP_VERSION=/) print "TARGET_DP_VERSION=6.5.0"; else print}' \
  "${CROSS}/phase2-ubuntu-prerequisites.state" >"${CROSS}/phase2-ubuntu-prerequisites.state.tmp"
mv -f "${CROSS}/phase2-ubuntu-prerequisites.state.tmp" \
  "${CROSS}/phase2-ubuntu-prerequisites.state"
phase2_prereq_write_identity_for_extras "$CROSS" >/dev/null
PIN_CROSS="$(phase2_prereq_identity_sha_of "${CROSS}/phase2-ubuntu-prerequisites.identity")"
publish_from "$CROSS"
OUT="$(run_stage "$PIN_CROSS")"
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=FAIL reason=target_version_mismatch' \
  && echo "$OUT" | grep -q 'RC=1' \
  && ! echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=PASS' \
  && pass "K cross-target trusted identity REJECT" \
  || fail "K cross-target: ${OUT}"

echo "======== summary pass=${PASS} fail=${FAIL} ========"
[[ "$FAIL" -eq 0 ]]
