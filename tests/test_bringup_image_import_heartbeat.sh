#!/usr/bin/env bash
# Heartbeat / observability around dark-site `ctr images import` in
# LOCAL_PATCHED_SOURCE=vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

die() { echo "FATAL: $*" >&2; exit 1; }

[[ -f "$BRINGUP" ]] || die "missing LOCAL_PATCHED_SOURCE bringup: $BRINGUP"

extract_helpers() {
  local out="$1"
  awk '
    /^# BEGIN_IMAGE_IMPORT_HEARTBEAT$/ {keep=1; next}
    /^# END_IMAGE_IMPORT_HEARTBEAT$/ {keep=0; next}
    keep {print}
  ' "$BRINGUP" >"$out"
  [[ -s "$out" ]] || die "failed to extract IMAGE_IMPORT_HEARTBEAT helpers"
}

# Minimal log() matching bringup shape (timestamp prefix optional for asserts).
log() { echo "[test-log] $*"; }

assert_grep() {
  local pat="$1" file="$2" msg="$3"
  if grep -Eq -- "$pat" "$file"; then
    pass "$msg"
  else
    fail "$msg (pattern=$pat)"
  fi
}

assert_no_grep() {
  local pat="$1" file="$2" msg="$3"
  if grep -Eq -- "$pat" "$file"; then
    fail "$msg (unexpected pattern=$pat)"
  else
    pass "$msg"
  fi
}

echo "======== test_bringup_image_import_heartbeat ========"

# --- D: static ---
if bash -n "$BRINGUP"; then
  pass "bash -n LOCAL_PATCHED_SOURCE bringup"
else
  fail "bash -n LOCAL_PATCHED_SOURCE bringup"
fi

HELPERS="$(mktemp)"
extract_helpers "$HELPERS"
# Prepend shell directive for ShellCheck SC2148 on extracted fragments
{ echo '# shellcheck shell=bash'; cat "$HELPERS"; } >"${HELPERS}.tmp" && mv "${HELPERS}.tmp" "$HELPERS"
if bash -n "$HELPERS"; then
  pass "bash -n extracted helpers"
else
  fail "bash -n extracted helpers"
fi

# Serial order + ctr option contract unchanged in load_local_images call sites.
assert_grep 'run_image_import_with_heartbeat "k8s\.io"' "$BRINGUP" "k8s.io import still first"
assert_grep 'run_image_import_with_heartbeat "moby".*--no-unpack' "$BRINGUP" "moby still uses --no-unpack"
assert_grep 'IMAGE_IMPORT_NEXT namespace=moby' "$BRINGUP" "second namespace clearly announced"
# Serial call sites: k8s helper, then NEXT marker, then moby helper (no parallel &).
if awk '
  /run_image_import_with_heartbeat "k8s.io"/ {k=NR}
  /IMAGE_IMPORT_NEXT namespace=moby/ {n=NR}
  /run_image_import_with_heartbeat "moby"/ {m=NR}
  END { exit((k>0 && n>k && m>n) ? 0 : 1) }
' "$BRINGUP"; then
  pass "k8s then moby remain serial call sites"
else
  fail "k8s then moby remain serial call sites"
fi

# Notices present.
assert_grep 'NOTICE: Local image import may take tens of minutes' "$BRINGUP" "EN duration notice"
assert_no_grep $'\uc548\ub0b4:' "$BRINGUP" "no Korean image-import guidance"
assert_grep 'IMAGE_IMPORT_HEARTBEAT_SECONDS' "$BRINGUP" "heartbeat env honored"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR" "$HELPERS"' EXIT
TAR="${WORKDIR}/images-6.6.0.tar"
# Large-enough sparse-ish file so fd position math has a size; content unused by mock.
dd if=/dev/zero of="$TAR" bs=1M count=4 status=none
LOGF="${WORKDIR}/import.log"

# --- A: long-running success with heartbeats ---
A_OUT="${WORKDIR}/a.out"
A_RC=0
(
  set -euo pipefail
  # shellcheck disable=SC1090
  source "$HELPERS"
  export IMAGE_IMPORT_HEARTBEAT_SECONDS=1
  ctr() {
    # Heartbeat may call `ctr ... images ls`; keep that instant.
    if [[ "$*" == *"images ls"* ]]; then
      return 0
    fi
    # ctr -n=NS images import [args...] FILE
    local f="${!#}"
    # Hold open the tar so progress helper can observe an fd when possible.
    sleep 3.2 <"$f"
    return 0
  }
  run_image_import_with_heartbeat "k8s.io" "$TAR" "$LOGF"
) >"$A_OUT" 2>&1 || A_RC=$?

[[ "$A_RC" -eq 0 ]] && pass "A exit 0" || fail "A exit 0 (rc=$A_RC)"
prog_count="$(grep -c 'IMAGE_IMPORT_PROGRESS namespace=k8s.io' "$A_OUT" || true)"
if [[ "$prog_count" -ge 2 ]]; then
  pass "A heartbeat >=2 (got $prog_count)"
else
  fail "A heartbeat >=2 (got $prog_count)"
  echo "---- A output ----"; cat "$A_OUT"; echo "----"
fi
assert_grep 'IMAGE_IMPORT_START namespace=k8s.io' "$A_OUT" "A START"
assert_grep 'IMAGE_IMPORT_COMPLETE namespace=k8s.io' "$A_OUT" "A COMPLETE"
assert_grep 'process_alive=YES' "$A_OUT" "A process_alive=YES"
assert_grep 'disk_free=' "$A_OUT" "A disk_free present"
assert_grep 'file=images-6.6.0.tar' "$A_OUT" "A tar basename present"

# --- B: failure propagates rc=17 ---
B_OUT="${WORKDIR}/b.out"
B_RC=0
(
  set -euo pipefail
  # shellcheck disable=SC1090
  source "$HELPERS"
  export IMAGE_IMPORT_HEARTBEAT_SECONDS=1
  ctr() {
    if [[ "$*" == *"images ls"* ]]; then
      return 0
    fi
    sleep 2.2
    return 17
  }
  run_image_import_with_heartbeat "moby" "$TAR" "$LOGF" --no-unpack
) >"$B_OUT" 2>&1 || B_RC=$?

[[ "$B_RC" -eq 17 ]] && pass "B propagates rc=17" || fail "B propagates rc=17 (rc=$B_RC)"
assert_grep 'IMAGE_IMPORT_PROGRESS namespace=moby' "$B_OUT" "B emitted heartbeat before fail"
assert_grep 'IMAGE_IMPORT_FAILED namespace=moby.*rc=17' "$B_OUT" "B FAILED line"
if grep -q 'IMAGE_IMPORT_COMPLETE namespace=moby' "$B_OUT"; then
  fail "B must not emit COMPLETE on failure"
else
  pass "B no COMPLETE on failure"
fi

# Caller preserves rc like load_local_images (|| rc=$?) without aborting outer script.
C_OUTER_RC=0
(
  set -euo pipefail
  # shellcheck disable=SC1090
  source "$HELPERS"
  export IMAGE_IMPORT_HEARTBEAT_SECONDS=1
  ctr() {
    if [[ "$*" == *"images ls"* ]]; then
      return 0
    fi
    sleep 1.2
    return 17
  }
  ns_rc=0
  run_image_import_with_heartbeat "k8s.io" "$TAR" "$LOGF" || ns_rc=$?
  echo "CAPTURED_RC=${ns_rc}"
  exit 0
) >"${WORKDIR}/b_outer.out" 2>&1 || C_OUTER_RC=$?
[[ "$C_OUTER_RC" -eq 0 ]] && pass "B outer set -e survives via || rc=\$?" || fail "B outer set -e survives"
assert_grep 'CAPTURED_RC=17' "${WORKDIR}/b_outer.out" "B captured rc=17 for WARNING path"

# --- C: progress UNKNOWN when fd pos unavailable; import still succeeds ---
C_OUT="${WORKDIR}/c.out"
C_RC=0
(
  set -euo pipefail
  # shellcheck disable=SC1090
  source "$HELPERS"
  export IMAGE_IMPORT_HEARTBEAT_SECONDS=1
  # Override progress probe to force UNKNOWN without affecting import.
  image_import_progress_pct() { printf 'UNKNOWN\n'; return 0; }
  ctr() {
    if [[ "$*" == *"images ls"* ]]; then
      return 0
    fi
    sleep 2.2
    return 0
  }
  run_image_import_with_heartbeat "k8s.io" "$TAR" "$LOGF"
) >"$C_OUT" 2>&1 || C_RC=$?

[[ "$C_RC" -eq 0 ]] && pass "C exit 0 with UNKNOWN progress" || fail "C exit 0 (rc=$C_RC)"
assert_grep 'progress=UNKNOWN' "$C_OUT" "C progress=UNKNOWN"
assert_grep 'IMAGE_IMPORT_COMPLETE namespace=k8s.io' "$C_OUT" "C COMPLETE despite UNKNOWN"

# Invalid heartbeat env falls back to 60 (unit check of helper only).
HB_OUT="${WORKDIR}/hb.out"
(
  set -euo pipefail
  # shellcheck disable=SC1090
  source "$HELPERS"
  export IMAGE_IMPORT_HEARTBEAT_SECONDS=bogus
  echo "HB=$(image_import_heartbeat_seconds)"
  export IMAGE_IMPORT_HEARTBEAT_SECONDS=0
  echo "HB0=$(image_import_heartbeat_seconds)"
  export IMAGE_IMPORT_HEARTBEAT_SECONDS=1
  echo "HB1=$(image_import_heartbeat_seconds)"
) >"$HB_OUT"
assert_grep '^HB=60$' "$HB_OUT" "invalid heartbeat -> 60"
assert_grep '^HB0=60$' "$HB_OUT" "zero heartbeat -> 60"
assert_grep '^HB1=1$' "$HB_OUT" "positive heartbeat kept"

# Gzip path recognized (*.gz) — use PATH executables so wait(1) sees a real
# pipeline job (shell-function mocks can hide producer-failure masking).
GZ_TAR="${WORKDIR}/images-6.6.0.tar.gz"
: >"$GZ_TAR"
MOCK_BIN="${WORKDIR}/mockbin"
mkdir -p "$MOCK_BIN"

# --- G1: gzip producer failure must not be masked by ctr exit 0 ---
cat >"$MOCK_BIN/gunzip" <<'EOF'
#!/usr/bin/env bash
# Emit a little data then fail (classic pipefail masking case).
printf 'partial\n'
exit 23
EOF
cat >"$MOCK_BIN/ctr" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"images ls"* ]]; then
  exit 0
fi
# Consume stdin to EOF like a successful import consumer.
cat >/dev/null
exit 0
EOF
chmod +x "$MOCK_BIN/gunzip" "$MOCK_BIN/ctr"

G1_OUT="${WORKDIR}/g1.out"
G1_RC=0
(
  set -euo pipefail
  export PATH="${MOCK_BIN}:$PATH"
  # shellcheck disable=SC1090
  source "$HELPERS"
  export IMAGE_IMPORT_HEARTBEAT_SECONDS=1
  run_image_import_with_heartbeat "k8s.io" "$GZ_TAR" "$LOGF"
) >"$G1_OUT" 2>&1 || G1_RC=$?

echo "GZIP_PRODUCER_FAILURE_EXPECTED_RC=23"
echo "GZIP_PRODUCER_FAILURE_ACTUAL_RC=${G1_RC}"
if [[ "$G1_RC" -eq 23 ]]; then
  echo "GZIP_PRODUCER_RC_PROPAGATION=PASS"
  pass "G1 gzip producer rc=23 propagates"
else
  echo "GZIP_PRODUCER_RC_PROPAGATION=FAIL"
  fail "G1 gzip producer rc=23 propagates (rc=$G1_RC)"
  echo "---- G1 output ----"; cat "$G1_OUT"; echo "----"
fi
if grep -q 'IMAGE_IMPORT_FAILED' "$G1_OUT"; then
  echo "IMAGE_IMPORT_FAILED_PRESENT=YES"
  pass "G1 IMAGE_IMPORT_FAILED present"
else
  echo "IMAGE_IMPORT_FAILED_PRESENT=NO"
  fail "G1 IMAGE_IMPORT_FAILED present"
fi
if grep -q 'IMAGE_IMPORT_COMPLETE' "$G1_OUT"; then
  echo "IMAGE_IMPORT_COMPLETE_PRESENT=YES"
  fail "G1 must not emit IMAGE_IMPORT_COMPLETE"
else
  echo "IMAGE_IMPORT_COMPLETE_PRESENT=NO"
  pass "G1 no IMAGE_IMPORT_COMPLETE"
fi
assert_grep 'IMAGE_IMPORT_FAILED namespace=k8s.io.*rc=23' "$G1_OUT" "G1 FAILED rc=23 line"

# Caller preserves gzip producer failure like load_local_images (|| rc=$?).
G1_OUTER_RC=0
(
  set -euo pipefail
  export PATH="${MOCK_BIN}:$PATH"
  # shellcheck disable=SC1090
  source "$HELPERS"
  export IMAGE_IMPORT_HEARTBEAT_SECONDS=1
  ns_rc=0
  run_image_import_with_heartbeat "k8s.io" "$GZ_TAR" "$LOGF" || ns_rc=$?
  echo "CAPTURED_RC=${ns_rc}"
  exit 0
) >"${WORKDIR}/g1_outer.out" 2>&1 || G1_OUTER_RC=$?
[[ "$G1_OUTER_RC" -eq 0 ]] && pass "G1 outer set -e survives via || rc=\$?" || fail "G1 outer set -e survives"
assert_grep 'CAPTURED_RC=23' "${WORKDIR}/g1_outer.out" "G1 captured rc=23 for WARNING path"

# --- G2: gzip consumer (ctr) failure propagates rc=17 ---
cat >"$MOCK_BIN/gunzip" <<'EOF'
#!/usr/bin/env bash
printf 'ok-payload\n'
exit 0
EOF
cat >"$MOCK_BIN/ctr" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"images ls"* ]]; then
  exit 0
fi
cat >/dev/null
exit 17
EOF
chmod +x "$MOCK_BIN/gunzip" "$MOCK_BIN/ctr"

G2_OUT="${WORKDIR}/g2.out"
G2_RC=0
(
  set -euo pipefail
  export PATH="${MOCK_BIN}:$PATH"
  # shellcheck disable=SC1090
  source "$HELPERS"
  export IMAGE_IMPORT_HEARTBEAT_SECONDS=1
  run_image_import_with_heartbeat "moby" "$GZ_TAR" "$LOGF" --no-unpack
) >"$G2_OUT" 2>&1 || G2_RC=$?

echo "GZIP_CONSUMER_FAILURE_EXPECTED_RC=17"
echo "GZIP_CONSUMER_FAILURE_ACTUAL_RC=${G2_RC}"
if [[ "$G2_RC" -eq 17 ]]; then
  echo "GZIP_CONSUMER_RC_PROPAGATION=PASS"
  pass "G2 gzip consumer rc=17 propagates"
else
  echo "GZIP_CONSUMER_RC_PROPAGATION=FAIL"
  fail "G2 gzip consumer rc=17 propagates (rc=$G2_RC)"
  echo "---- G2 output ----"; cat "$G2_OUT"; echo "----"
fi
assert_grep 'IMAGE_IMPORT_FAILED namespace=moby.*rc=17' "$G2_OUT" "G2 FAILED rc=17"
if grep -q 'IMAGE_IMPORT_COMPLETE namespace=moby' "$G2_OUT"; then
  fail "G2 must not emit COMPLETE on failure"
else
  pass "G2 no COMPLETE on failure"
fi

# --- G3: gzip success ---
cat >"$MOCK_BIN/gunzip" <<'EOF'
#!/usr/bin/env bash
printf 'ok-payload\n'
exit 0
EOF
cat >"$MOCK_BIN/ctr" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"images ls"* ]]; then
  exit 0
fi
cat >/dev/null
# Hold briefly so heartbeat loop can observe the job once when interval=1.
sleep 1.2
exit 0
EOF
chmod +x "$MOCK_BIN/gunzip" "$MOCK_BIN/ctr"

G3_OUT="${WORKDIR}/g3.out"
G3_RC=0
(
  set -euo pipefail
  export PATH="${MOCK_BIN}:$PATH"
  # shellcheck disable=SC1090
  source "$HELPERS"
  export IMAGE_IMPORT_HEARTBEAT_SECONDS=1
  run_image_import_with_heartbeat "k8s.io" "$GZ_TAR" "$LOGF"
) >"$G3_OUT" 2>&1 || G3_RC=$?

if [[ "$G3_RC" -eq 0 ]]; then
  echo "GZIP_SUCCESS_TEST=PASS"
  pass "G3 gzip success rc=0"
else
  echo "GZIP_SUCCESS_TEST=FAIL"
  fail "G3 gzip success rc=0 (rc=$G3_RC)"
  echo "---- G3 output ----"; cat "$G3_OUT"; echo "----"
fi
assert_grep 'IMAGE_IMPORT_COMPLETE namespace=k8s.io' "$G3_OUT" "G3 COMPLETE"
if grep -q 'IMAGE_IMPORT_FAILED' "$G3_OUT"; then
  fail "G3 must not emit FAILED on success"
else
  pass "G3 no FAILED on success"
fi

# Static: gzip path still uses gunzip | ctr import -
assert_grep 'gunzip -c -- "\$tar_file"' "$BRINGUP" "gzip path still gunzip -c"
assert_grep 'ctr -n="\$ns" images import "\$\{extra_args\[@\]\}" -' "$BRINGUP" "gzip path still ctr import -"

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x -e SC1091,SC2015,SC2034,SC2119,SC2120,SC2317 "$HELPERS"; then
    pass "shellcheck helpers"
  else
    fail "shellcheck helpers"
  fi
else
  echo "  SKIP: shellcheck not installed (SKIPPED_NOT_INSTALLED)"
fi

echo "SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
