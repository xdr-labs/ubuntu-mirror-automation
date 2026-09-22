#!/usr/bin/env bash
# Current-run log scoping (P0-B) and coherent completion sentinel (P0-C).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/client/lib/dp-phase2-bringup-lifecycle.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
write_file() { printf '%s\n' "$2" >"$1"; }

export PHASE2_BRINGUP_DIR="${TMP}/lifecycle"
export PHASE2_BRINGUP_LOG_DEFAULT="${TMP}/bringup.log"
export PHASE2_BRINGUP_MONITOR_SECONDS=1
# shellcheck source=/dev/null
source "$LIB"

echo "=== test_bringup_lifecycle_run_contract ==="

p2b_ensure_dir
mkdir -p "$(p2b_dir)/lib"
cat >"$(p2b_dir)/lib/dp-phase2-ubuntu-prerequisites.sh" <<'EOF'
dp2_install_phase2_ubuntu_prerequisites() { return 0; }
EOF
cat >"$(p2b_dir)/lib/dp-phase2-time-readiness.sh" <<'EOF'
dp_phase2_load_time_ref_url() { return 0; }
dp_phase2_bringup_time_gate() { return 0; }
EOF
cat >"$(p2b_dir)/lib/dp-phase2-staging-contract.sh" <<'EOF'
dp_phase2_bringup_staging_gate() { return 0; }
EOF
cat >"$(p2b_dir)/lib/dp-phase2-post-bringup-migration.sh" <<'EOF'
dp_phase2_post_bringup_migration() { return 0; }
EOF
cat >"$(p2b_dir)/lib/dp-phase2-cluster-validation.sh" <<'EOF'
dp_phase2_cluster_validation() { return 0; }
EOF

# ---------------------------------------------------------------------------
# B1. Historical APT FAIL must not fail a current-run APT PASS
# ---------------------------------------------------------------------------
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
printf 'HIST APT_DEPENDENCY_CHECK=FAIL\n' >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-b1"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VENDOR_B1="${TMP}/vendor-b1.sh"
cat >"$VENDOR_B1" <<'EOF'
#!/usr/bin/env bash
echo "APT_DEPENDENCY_CHECK=PASS stage=current"
exit 0
EOF
chmod +x "$VENDOR_B1"
set +e
( p2b_worker_main "$VENDOR_B1" >/dev/null 2>&1 )
B1_RC=$?
set -e
[[ "$B1_RC" -eq 0 ]] || fail "B1 worker rc=${B1_RC}"
[[ "$(p2b_read_state)" == "COMPLETED" ]] || fail "B1 state=$(p2b_read_state)"
grep -q '^BRINGUP_RESULT=PASS$' "$(p2b_dir)/result.env" || fail "B1 result.env not PASS"
pass "B1 historical APT_DEPENDENCY_CHECK=FAIL is ignored"

# ---------------------------------------------------------------------------
# B2. Historical 3/3 must not PASS a current incomplete topology
# ---------------------------------------------------------------------------
p2b_ensure_dir
printf 'CLUSTER_JOIN_STATE ready=3 expected=3\n' >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-b2"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rm -f "$(p2b_dir)/result.env" "$(p2b_dir)/completion.sentinel" "$(p2b_dir)/state"
VENDOR_B2="${TMP}/vendor-b2.sh"
cat >"$VENDOR_B2" <<'EOF'
#!/usr/bin/env bash
echo "CLUSTER_JOIN_STATE ready=1 expected=3"
exit 0
EOF
chmod +x "$VENDOR_B2"
set +e
( p2b_worker_main "$VENDOR_B2" --worker-ips 192.0.2.10,192.0.2.11 >/dev/null 2>&1 )
B2_RC=$?
set -e
[[ "$B2_RC" -ne 0 ]] || fail "B2 unexpectedly PASS"
[[ "$(p2b_read_state)" == "FAILED" ]] || fail "B2 state=$(p2b_read_state)"
grep -q 'FAILURE_REASON=WORKER_ORCHESTRATION' "$(p2b_dir)/completion.sentinel" \
  || fail "B2 missing WORKER_ORCHESTRATION failure"
pass "B2 historical CLUSTER_JOIN_STATE 3/3 does not make current run PASS"

# ---------------------------------------------------------------------------
# B3. Historical Bringup complete is not current-run completion evidence
# ---------------------------------------------------------------------------
printf 'Bringup complete: all nodes ready\nPHASE2_BRINGUP=COMPLETE\n' \
  >"$PHASE2_BRINGUP_LOG_DEFAULT"
offset="$(wc -c <"$PHASE2_BRINGUP_LOG_DEFAULT" | tr -d ' ')"
write_file "$(p2b_dir)/log-start-offset" "$offset"
printf 'still running\n' >>"$PHASE2_BRINGUP_LOG_DEFAULT"
if p2b_log_has_anchored_completion "$PHASE2_BRINGUP_LOG_DEFAULT"; then
  fail "B3 historical Bringup complete was accepted as current-run evidence"
fi
pass "B3 historical Bringup complete marker is not current-run completion"

# ---------------------------------------------------------------------------
# B4. Current-run 3/3 evidence => topology gate PASS
# ---------------------------------------------------------------------------
p2b_ensure_dir
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-b4"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rm -f "$(p2b_dir)/result.env" "$(p2b_dir)/completion.sentinel" "$(p2b_dir)/state"
VENDOR_B4="${TMP}/vendor-b4.sh"
cat >"$VENDOR_B4" <<'EOF'
#!/usr/bin/env bash
echo "CLUSTER_JOIN_STATE ready=3 expected=3"
echo "WORKER_ORCHESTRATION=PASS"
exit 0
EOF
chmod +x "$VENDOR_B4"
set +e
( p2b_worker_main "$VENDOR_B4" --worker-ips 192.0.2.10,192.0.2.11 >/dev/null 2>&1 )
B4_RC=$?
set -e
[[ "$B4_RC" -eq 0 ]] || fail "B4 worker rc=${B4_RC}"
[[ "$(p2b_read_state)" == "COMPLETED" ]] || fail "B4 state=$(p2b_read_state)"
grep -q '^BRINGUP_COMPLETION_SENTINEL=PASS$' "$(p2b_dir)/result.env" \
  || fail "B4 sentinel missing"
pass "B4 current-run 3/3 topology gate PASS"

# ---------------------------------------------------------------------------
# B5. Offset past truncated log: no historical reuse, fail-closed
# ---------------------------------------------------------------------------
printf 'CLUSTER_JOIN_STATE ready=3 expected=3\nAPT_DEPENDENCY_CHECK=FAIL\nBringup complete: done\n' \
  >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/log-start-offset" "999999"
set +e
p2b_current_run_log_stream "$PHASE2_BRINGUP_LOG_DEFAULT" >/dev/null
B5_STREAM=$?
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'CLUSTER_JOIN_STATE ready=3 expected=3'
B5_JOIN=$?
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'APT_DEPENDENCY_CHECK=FAIL'
B5_APT=$?
set -e
[[ "$B5_STREAM" -eq 2 ]] || fail "B5 stream rc=${B5_STREAM} expected 2"
[[ "$B5_JOIN" -eq 2 ]] || fail "B5 join contains rc=${B5_JOIN} expected 2"
[[ "$B5_APT" -eq 2 ]] || fail "B5 apt contains rc=${B5_APT} expected 2"
if p2b_log_has_anchored_completion "$PHASE2_BRINGUP_LOG_DEFAULT"; then
  fail "B5 truncated log reused historical completion"
fi
# Cluster evidence cannot be proven current-run => not PASS.
join_ok=0
if p2b_current_run_log_stream "$PHASE2_BRINGUP_LOG_DEFAULT" >/dev/null \
  && p2b_current_run_log_stream "$PHASE2_BRINGUP_LOG_DEFAULT" \
  | grep -E 'CLUSTER_JOIN_STATE ready=([0-9]+) expected=([0-9]+)' \
  | awk '{
      ready=""; expected="";
      for(i=1;i<=NF;i++){
        if($i ~ /^ready=/){ split($i,a,"="); ready=a[2] }
        if($i ~ /^expected=/){ split($i,b,"="); expected=b[2] }
      }
      if(ready!="" && expected!="" && ready==expected && expected+0>1) ok=1
    }
    END { exit ok?0:1 }'
then
  join_ok=1
fi
[[ "$join_ok" -eq 0 ]] || fail "B5 truncated log reused historical 3/3"
pass "B5 truncated offset fail-closes and does not reuse historical evidence"

# ---------------------------------------------------------------------------
# C1. state=COMPLETED, no result.env => NOT PASS
# ---------------------------------------------------------------------------
p2b_ensure_dir
write_file "$(p2b_dir)/state" "COMPLETED"
write_file "$(p2b_dir)/run-id" "run-c1"
rm -f "$(p2b_dir)/result.env"
p2b_discover_aella_cli() { AELLA_CLI_AVAILABLE=YES; AELLA_CLI_PATH=/usr/bin/aella_cli; return 0; }
p2b_print_status >"${TMP}/c1.status"
grep -q '^BRINGUP_RESULT=FAIL_INCONSISTENT_STATE$' "${TMP}/c1.status" \
  || fail "C1 result=$(grep ^BRINGUP_RESULT= "${TMP}/c1.status")"
grep -q '^DO_NOT_RUN_AELLA_CLI_YET=YES$' "${TMP}/c1.status" \
  || fail "C1 DO_NOT_RUN missing"
pass "C1 COMPLETED without result.env is NOT PASS"

# ---------------------------------------------------------------------------
# C2. state=COMPLETED, previous run-id result.env sentinel PASS => NOT PASS
# ---------------------------------------------------------------------------
write_file "$(p2b_dir)/state" "COMPLETED"
write_file "$(p2b_dir)/run-id" "run-c2-current"
cat >"$(p2b_dir)/result.env" <<'EOF'
BRINGUP_TERMINAL_STATE=COMPLETED
BRINGUP_RESULT=PASS
BRINGUP_RUN_ID=run-c2-old
BRINGUP_EXIT_CODE=0
BRINGUP_COMPLETION_SENTINEL=PASS
EOF
p2b_print_status >"${TMP}/c2.status"
grep -q '^BRINGUP_RESULT=FAIL_INCONSISTENT_STATE$' "${TMP}/c2.status" \
  || fail "C2 result=$(grep ^BRINGUP_RESULT= "${TMP}/c2.status")"
grep -q '^DO_NOT_RUN_AELLA_CLI_YET=YES$' "${TMP}/c2.status" \
  || fail "C2 DO_NOT_RUN missing"
pass "C2 previous-run result.env cannot make current run PASS"

# ---------------------------------------------------------------------------
# C3. current run-id, terminal COMPLETED, result PASS, exit 0, sentinel missing
# ---------------------------------------------------------------------------
write_file "$(p2b_dir)/state" "COMPLETED"
write_file "$(p2b_dir)/run-id" "run-c3"
cat >"$(p2b_dir)/result.env" <<'EOF'
BRINGUP_TERMINAL_STATE=COMPLETED
BRINGUP_RESULT=PASS
BRINGUP_RUN_ID=run-c3
BRINGUP_EXIT_CODE=0
EOF
p2b_print_status >"${TMP}/c3.status"
grep -q '^BRINGUP_RESULT=FAIL_INCONSISTENT_STATE$' "${TMP}/c3.status" \
  || fail "C3 result=$(grep ^BRINGUP_RESULT= "${TMP}/c3.status")"
pass "C3 COMPLETED without sentinel PASS is NOT PASS"

# ---------------------------------------------------------------------------
# C4. sentinel PASS but exit code != 0 => NOT PASS
# ---------------------------------------------------------------------------
write_file "$(p2b_dir)/state" "COMPLETED"
write_file "$(p2b_dir)/run-id" "run-c4"
write_file "$(p2b_dir)/exit-code" "7"
cat >"$(p2b_dir)/result.env" <<'EOF'
BRINGUP_TERMINAL_STATE=COMPLETED
BRINGUP_RESULT=PASS
BRINGUP_RUN_ID=run-c4
BRINGUP_EXIT_CODE=7
BRINGUP_COMPLETION_SENTINEL=PASS
EOF
p2b_print_status >"${TMP}/c4.status"
grep -q '^BRINGUP_RESULT=FAIL_INCONSISTENT_STATE$' "${TMP}/c4.status" \
  || fail "C4 result=$(grep ^BRINGUP_RESULT= "${TMP}/c4.status")"
grep -q '^DO_NOT_RUN_AELLA_CLI_YET=YES$' "${TMP}/c4.status" \
  || fail "C4 DO_NOT_RUN missing"
pass "C4 sentinel PASS with nonzero exit is NOT PASS"

# ---------------------------------------------------------------------------
# C5. Fully coherent current-run completion => PASS (CLI present)
# ---------------------------------------------------------------------------
write_file "$(p2b_dir)/state" "COMPLETED"
write_file "$(p2b_dir)/run-id" "run-c5"
write_file "$(p2b_dir)/exit-code" "0"
cat >"$(p2b_dir)/result.env" <<'EOF'
BRINGUP_TERMINAL_STATE=COMPLETED
BRINGUP_RESULT=PASS
BRINGUP_RUN_ID=run-c5
BRINGUP_EXIT_CODE=0
BRINGUP_COMPLETION_SENTINEL=PASS
EOF
p2b_print_status >"${TMP}/c5.status"
grep -q '^BRINGUP_RESULT=PASS$' "${TMP}/c5.status" \
  || fail "C5 result=$(grep ^BRINGUP_RESULT= "${TMP}/c5.status")"
grep -q '^DO_NOT_RUN_AELLA_CLI_YET=NO$' "${TMP}/c5.status" \
  || fail "C5 DO_NOT_RUN unexpected"
pass "C5 coherent current-run completion is PASS"

# Preserve FAIL_POSTCONDITION when CLI is missing after a coherent completion.
p2b_discover_aella_cli() { AELLA_CLI_AVAILABLE=NO; AELLA_CLI_PATH=""; return 1; }
p2b_print_status >"${TMP}/c5.post.status"
grep -q '^BRINGUP_RESULT=FAIL_POSTCONDITION$' "${TMP}/c5.post.status" \
  || fail "C5 postcondition=$(grep ^BRINGUP_RESULT= "${TMP}/c5.post.status")"
pass "C5 CLI postcondition remains FAIL_POSTCONDITION"

fill_bytes() {
  local file="$1" n="$2" ch="${3:-H}"
  python3 -c 'import sys; p,n,ch=sys.argv[1],int(sys.argv[2]),sys.argv[3][:1]; open(p,"wb").write((ch.encode()*n)[:n])' \
    "$file" "$n" "$ch"
}

reset_lifecycle_files() {
  p2b_ensure_dir
  rm -f "$(p2b_dir)/result.env" "$(p2b_dir)/completion.sentinel" "$(p2b_dir)/state" \
    "$(p2b_dir)/log-start-offset" "$(p2b_dir)/exit-code"
}

# ---------------------------------------------------------------------------
# ID-B1. NORMAL APPEND: historical log + current marker after offset
# ---------------------------------------------------------------------------
reset_lifecycle_files
fill_bytes "$PHASE2_BRINGUP_LOG_DEFAULT" 2048 H
printf '\nHIST APT_DEPENDENCY_CHECK=FAIL\n' >>"$PHASE2_BRINGUP_LOG_DEFAULT"
offset="$(wc -c <"$PHASE2_BRINGUP_LOG_DEFAULT" | tr -d ' ')"
write_file "$(p2b_dir)/run-id" "run-idb1"
write_file "$(p2b_dir)/log-start-offset" "$offset"
p2b_write_current_run_log_marker "$PHASE2_BRINGUP_LOG_DEFAULT" "run-idb1"
printf 'APT_DEPENDENCY_CHECK=PASS\n' >>"$PHASE2_BRINGUP_LOG_DEFAULT"
set +e
p2b_current_run_log_identity_valid "$PHASE2_BRINGUP_LOG_DEFAULT" "run-idb1"
IDB1_IDENT=$?
p2b_current_run_log_stream "$PHASE2_BRINGUP_LOG_DEFAULT" >/dev/null
IDB1_STREAM=$?
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'APT_DEPENDENCY_CHECK=PASS'
IDB1_PASS=$?
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'APT_DEPENDENCY_CHECK=FAIL'
IDB1_FAIL=$?
set -e
[[ "$IDB1_IDENT" -eq 0 ]] || fail "ID-B1 identity rc=${IDB1_IDENT}"
[[ "$IDB1_STREAM" -eq 0 ]] || fail "ID-B1 stream rc=${IDB1_STREAM}"
[[ "$IDB1_PASS" -eq 0 ]] || fail "ID-B1 current PASS not found"
[[ "$IDB1_FAIL" -ne 0 ]] || fail "ID-B1 historical FAIL leaked into current stream"
pass "ID-B1 normal append current-run stream is valid"

# ---------------------------------------------------------------------------
# ID-B2. HISTORICAL FAIL ignored when current marker + PASS exist
# ---------------------------------------------------------------------------
reset_lifecycle_files
printf 'HIST APT_DEPENDENCY_CHECK=FAIL\n' >"$PHASE2_BRINGUP_LOG_DEFAULT"
offset="$(wc -c <"$PHASE2_BRINGUP_LOG_DEFAULT" | tr -d ' ')"
write_file "$(p2b_dir)/run-id" "run-idb2"
write_file "$(p2b_dir)/log-start-offset" "$offset"
p2b_write_current_run_log_marker "$PHASE2_BRINGUP_LOG_DEFAULT" "run-idb2"
printf 'APT_DEPENDENCY_CHECK=PASS\n' >>"$PHASE2_BRINGUP_LOG_DEFAULT"
set +e
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'APT_DEPENDENCY_CHECK=FAIL'
IDB2_FAIL=$?
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'APT_DEPENDENCY_CHECK=PASS'
IDB2_PASS=$?
set -e
[[ "$IDB2_FAIL" -ne 0 ]] || fail "ID-B2 historical FAIL treated as current"
[[ "$IDB2_PASS" -eq 0 ]] || fail "ID-B2 current PASS missing"
pass "ID-B2 historical APT FAIL is ignored"

# ---------------------------------------------------------------------------
# ID-B3. HISTORICAL 3/3 ignored; current missing orch PASS is not PASS
# ---------------------------------------------------------------------------
reset_lifecycle_files
printf 'CLUSTER_JOIN_STATE ready=3 expected=3\nWORKER_ORCHESTRATION=PASS\n' \
  >"$PHASE2_BRINGUP_LOG_DEFAULT"
offset="$(wc -c <"$PHASE2_BRINGUP_LOG_DEFAULT" | tr -d ' ')"
write_file "$(p2b_dir)/run-id" "run-idb3"
write_file "$(p2b_dir)/log-start-offset" "$offset"
p2b_write_current_run_log_marker "$PHASE2_BRINGUP_LOG_DEFAULT" "run-idb3"
printf 'CLUSTER_JOIN_STATE ready=1 requested=2 diagnostic=YES\n' \
  >>"$PHASE2_BRINGUP_LOG_DEFAULT"
set +e
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'WORKER_ORCHESTRATION=PASS'
IDB3_ORCH=$?
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'CLUSTER_JOIN_STATE ready=3 expected=3'
IDB3_HIST=$?
set -e
[[ "$IDB3_ORCH" -ne 0 ]] || fail "ID-B3 historical WORKER_ORCHESTRATION=PASS treated as current"
[[ "$IDB3_HIST" -ne 0 ]] || fail "ID-B3 historical CLUSTER_JOIN 3/3 treated as current"
pass "ID-B3 historical CLUSTER_JOIN 3/3 is not current-run PASS"

# ---------------------------------------------------------------------------
# ID-B4. SIMPLE TRUNCATION: recorded offset > current size
# ---------------------------------------------------------------------------
reset_lifecycle_files
printf 'CLUSTER_JOIN_STATE ready=3 expected=3\n' >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-idb4"
write_file "$(p2b_dir)/log-start-offset" "999999"
set +e
p2b_current_run_log_stream "$PHASE2_BRINGUP_LOG_DEFAULT" >/dev/null
IDB4_STREAM=$?
p2b_current_run_log_identity_valid "$PHASE2_BRINGUP_LOG_DEFAULT" "run-idb4"
IDB4_IDENT=$?
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'CLUSTER_JOIN_STATE ready=3 expected=3'
IDB4_JOIN=$?
set -e
[[ "$IDB4_STREAM" -eq 2 ]] || fail "ID-B4 stream rc=${IDB4_STREAM} expected 2"
[[ "$IDB4_IDENT" -eq 2 ]] || fail "ID-B4 identity rc=${IDB4_IDENT} expected 2"
[[ "$IDB4_JOIN" -eq 2 ]] || fail "ID-B4 contains rc=${IDB4_JOIN} expected 2"
pass "ID-B4 truncated offset fail-closes current-run evidence"

# ---------------------------------------------------------------------------
# ID-B5. TRUNCATE THEN REGROW PAST OLD OFFSET without current marker
# ---------------------------------------------------------------------------
reset_lifecycle_files
fill_bytes "$PHASE2_BRINGUP_LOG_DEFAULT" 8192 H
offset="$(wc -c <"$PHASE2_BRINGUP_LOG_DEFAULT" | tr -d ' ')"
write_file "$(p2b_dir)/run-id" "run-idb5"
write_file "$(p2b_dir)/log-start-offset" "$offset"
p2b_write_current_run_log_marker "$PHASE2_BRINGUP_LOG_DEFAULT" "run-idb5"
set +e
p2b_current_run_log_identity_valid "$PHASE2_BRINGUP_LOG_DEFAULT" "run-idb5"
IDB5_BEFORE=$?
set -e
[[ "$IDB5_BEFORE" -eq 0 ]] || fail "ID-B5 precondition identity rc=${IDB5_BEFORE}"
{
  fill_bytes "${TMP}/idb5.pad" 10000 N
  cat "${TMP}/idb5.pad"
  printf 'CLUSTER_JOIN_STATE ready=3 expected=3\n'
  printf 'APT_DEPENDENCY_CHECK=PASS\n'
  printf 'Bringup complete: all nodes ready\n'
} >"$PHASE2_BRINGUP_LOG_DEFAULT"
new_size="$(wc -c <"$PHASE2_BRINGUP_LOG_DEFAULT" | tr -d ' ')"
[[ "$new_size" -gt "$offset" ]] || fail "ID-B5 replacement size ${new_size} not > offset ${offset}"
set +e
p2b_current_run_log_identity_valid "$PHASE2_BRINGUP_LOG_DEFAULT" "run-idb5"
IDB5_IDENT=$?
p2b_current_run_log_stream "$PHASE2_BRINGUP_LOG_DEFAULT" >/dev/null
IDB5_STREAM=$?
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'CLUSTER_JOIN_STATE ready=3 expected=3'
IDB5_JOIN=$?
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'APT_DEPENDENCY_CHECK=PASS'
IDB5_APT=$?
set -e
[[ "$IDB5_IDENT" -eq 3 ]] || fail "ID-B5 identity rc=${IDB5_IDENT} expected 3"
[[ "$IDB5_STREAM" -eq 2 ]] || fail "ID-B5 stream rc=${IDB5_STREAM} expected 2"
[[ "$IDB5_JOIN" -eq 2 ]] || fail "ID-B5 join contains rc=${IDB5_JOIN} expected 2"
[[ "$IDB5_APT" -eq 2 ]] || fail "ID-B5 apt contains rc=${IDB5_APT} expected 2"
pass "ID-B5 truncate-then-regrow rejects current-run evidence"

# ---------------------------------------------------------------------------
# ID-B6. WRONG RUN MARKER cannot satisfy current-run identity
# ---------------------------------------------------------------------------
reset_lifecycle_files
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "new-run"
write_file "$(p2b_dir)/log-start-offset" "0"
printf 'PHASE2_LIFECYCLE_RUN_BEGIN run_id=old-run\n' >>"$PHASE2_BRINGUP_LOG_DEFAULT"
printf 'CLUSTER_JOIN_STATE ready=3 expected=3\n' >>"$PHASE2_BRINGUP_LOG_DEFAULT"
set +e
p2b_current_run_log_identity_valid "$PHASE2_BRINGUP_LOG_DEFAULT" "new-run"
IDB6_IDENT=$?
p2b_current_run_log_stream "$PHASE2_BRINGUP_LOG_DEFAULT" >/dev/null
IDB6_STREAM=$?
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'CLUSTER_JOIN_STATE ready=3 expected=3'
IDB6_JOIN=$?
set -e
[[ "$IDB6_IDENT" -eq 3 ]] || fail "ID-B6 identity rc=${IDB6_IDENT} expected 3"
[[ "$IDB6_STREAM" -eq 2 ]] || fail "ID-B6 stream rc=${IDB6_STREAM} expected 2"
[[ "$IDB6_JOIN" -eq 2 ]] || fail "ID-B6 contains rc=${IDB6_JOIN} expected 2"
pass "ID-B6 wrong-run marker is rejected"

# ---------------------------------------------------------------------------
# ID-B7. CURRENT MARKER + 3/3 => topology evidence accepted
# ---------------------------------------------------------------------------
reset_lifecycle_files
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-idb7"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VENDOR_IDB7="${TMP}/vendor-idb7.sh"
cat >"$VENDOR_IDB7" <<'EOF'
#!/usr/bin/env bash
echo "CLUSTER_JOIN_STATE ready=3 expected=3"
echo "WORKER_ORCHESTRATION=PASS"
exit 0
EOF
chmod +x "$VENDOR_IDB7"
set +e
( p2b_worker_main "$VENDOR_IDB7" --worker-ips 192.0.2.10,192.0.2.11 >/dev/null 2>&1 )
IDB7_RC=$?
set -e
[[ "$IDB7_RC" -eq 0 ]] || fail "ID-B7 worker rc=${IDB7_RC}"
[[ "$(p2b_read_state)" == "COMPLETED" ]] || fail "ID-B7 state=$(p2b_read_state)"
grep -qxF "PHASE2_LIFECYCLE_RUN_BEGIN run_id=run-idb7" "$PHASE2_BRINGUP_LOG_DEFAULT" \
  || fail "ID-B7 current run marker missing"
set +e
p2b_current_run_log_identity_valid "$PHASE2_BRINGUP_LOG_DEFAULT" "run-idb7"
IDB7_IDENT=$?
set -e
[[ "$IDB7_IDENT" -eq 0 ]] || fail "ID-B7 identity rc=${IDB7_IDENT}"
pass "ID-B7 current marker + 3/3 topology evidence is accepted"

# ---------------------------------------------------------------------------
# ID-B8. CURRENT MARKER + APT FAIL => current run FAIL
# ---------------------------------------------------------------------------
reset_lifecycle_files
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-idb8"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VENDOR_IDB8="${TMP}/vendor-idb8.sh"
cat >"$VENDOR_IDB8" <<'EOF'
#!/usr/bin/env bash
echo "APT_DEPENDENCY_CHECK=FAIL"
exit 0
EOF
chmod +x "$VENDOR_IDB8"
set +e
( p2b_worker_main "$VENDOR_IDB8" >/dev/null 2>&1 )
IDB8_RC=$?
set -e
[[ "$IDB8_RC" -ne 0 ]] || fail "ID-B8 unexpectedly PASS"
[[ "$(p2b_read_state)" == "FAILED" ]] || fail "ID-B8 state=$(p2b_read_state)"
grep -q 'FAILURE_REASON=APT_DEPENDENCY_CHECK' "$(p2b_dir)/completion.sentinel" \
  || fail "ID-B8 missing APT_DEPENDENCY_CHECK failure"
pass "ID-B8 current marker + APT FAIL is current-run FAIL"

# ---------------------------------------------------------------------------
# ID-B9. CURRENT MARKER LOST AFTER COPYTRUNCATE: success text is not PASS
# ---------------------------------------------------------------------------
reset_lifecycle_files
fill_bytes "$PHASE2_BRINGUP_LOG_DEFAULT" 8192 H
printf '\nHIST leftover\n' >>"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-idb9"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VENDOR_IDB9="${TMP}/vendor-idb9.sh"
cat >"$VENDOR_IDB9" <<'EOF'
#!/usr/bin/env bash
# copytruncate: wipe the inode contents so the current-run marker is gone,
# then regrow past the recorded offset with apparently successful evidence.
: >"${PHASE2_BRINGUP_LOG_DEFAULT}"
python3 -c 'import sys; sys.stdout.write("N"*10000)'
echo
echo "Bringup complete: all nodes ready"
echo "CLUSTER_JOIN_STATE ready=3 expected=3"
echo "APT_DEPENDENCY_CHECK=PASS"
echo "WORKER_ORCHESTRATION=PASS"
exit 0
EOF
chmod +x "$VENDOR_IDB9"
set +e
( p2b_worker_main "$VENDOR_IDB9" --worker-ips 192.0.2.10,192.0.2.11 >/dev/null 2>&1 )
IDB9_RC=$?
set -e
[[ "$IDB9_RC" -ne 0 ]] || fail "ID-B9 unexpectedly PASS after copytruncate"
[[ "$(p2b_read_state)" == "FAILED" ]] || fail "ID-B9 state=$(p2b_read_state)"
grep -q 'FAILURE_REASON=CURRENT_RUN_LOG_IDENTITY_INVALID' "$(p2b_dir)/completion.sentinel" \
  || fail "ID-B9 missing CURRENT_RUN_LOG_IDENTITY_INVALID after marker loss"
set +e
p2b_current_run_log_identity_valid "$PHASE2_BRINGUP_LOG_DEFAULT" "run-idb9"
IDB9_IDENT=$?
p2b_current_run_log_stream "$PHASE2_BRINGUP_LOG_DEFAULT" >/dev/null
IDB9_STREAM=$?
set -e
[[ "$IDB9_IDENT" -eq 3 ]] || fail "ID-B9 identity rc=${IDB9_IDENT} expected 3"
[[ "$IDB9_STREAM" -eq 2 ]] || fail "ID-B9 stream rc=${IDB9_STREAM} expected 2"
pass "ID-B9 copytruncate without current marker cannot PASS from log text"

# ---------------------------------------------------------------------------
# T1 — AIO COPYTRUNCATE + VENDOR RC=0 MUST FAIL
# ---------------------------------------------------------------------------
reset_lifecycle_files
fill_bytes "$PHASE2_BRINGUP_LOG_DEFAULT" 8192 H
printf '\nHIST leftover\n' >>"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-t1"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VENDOR_T1="${TMP}/vendor-t1.sh"
cat >"$VENDOR_T1" <<'EOF'
#!/usr/bin/env bash
: >"${PHASE2_BRINGUP_LOG_DEFAULT}"
python3 -c 'import sys; sys.stdout.write("N"*10000)'
echo
echo "APT_DEPENDENCY_CHECK=PASS"
echo "Bringup complete: all services ready"
exit 0
EOF
chmod +x "$VENDOR_T1"
set +e
( p2b_worker_main "$VENDOR_T1" >/dev/null 2>&1 )
T1_RC=$?
set -e
[[ "$T1_RC" -ne 0 ]] || fail "T1 unexpectedly PASS after AIO copytruncate"
[[ "$(p2b_read_state)" == "FAILED" ]] || fail "T1 state=$(p2b_read_state)"
grep -q '^BRINGUP_RESULT=FAIL$' "$(p2b_dir)/result.env" || fail "T1 result.env not FAIL"
grep -q '^BRINGUP_COMPLETION_SENTINEL=FAIL$' "$(p2b_dir)/result.env" \
  || fail "T1 sentinel not FAIL"
grep -q 'FAILURE_REASON=CURRENT_RUN_LOG_IDENTITY_INVALID' "$(p2b_dir)/completion.sentinel" \
  || fail "T1 missing CURRENT_RUN_LOG_IDENTITY_INVALID"
if grep -q '^BRINGUP_RESULT=PASS$' "$(p2b_dir)/result.env"; then
  fail "T1 became PASS"
fi
[[ "$(p2b_read_state)" != "COMPLETED" ]] || fail "T1 became COMPLETED"
pass "T1 AIO copytruncate + vendor rc=0 fails closed"

# ---------------------------------------------------------------------------
# T2 — AIO NORMAL VALID CURRENT-RUN STREAM STILL PASSES
# ---------------------------------------------------------------------------
reset_lifecycle_files
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-t2"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VENDOR_T2="${TMP}/vendor-t2.sh"
cat >"$VENDOR_T2" <<'EOF'
#!/usr/bin/env bash
echo "APT_DEPENDENCY_CHECK=PASS"
echo "Bringup complete: all services ready"
exit 0
EOF
chmod +x "$VENDOR_T2"
set +e
( p2b_worker_main "$VENDOR_T2" >/dev/null 2>&1 )
T2_RC=$?
set -e
[[ "$T2_RC" -eq 0 ]] || fail "T2 worker rc=${T2_RC}"
[[ "$(p2b_read_state)" == "COMPLETED" ]] || fail "T2 state=$(p2b_read_state)"
grep -q '^BRINGUP_RESULT=PASS$' "$(p2b_dir)/result.env" || fail "T2 result.env not PASS"
grep -q '^BRINGUP_COMPLETION_SENTINEL=PASS$' "$(p2b_dir)/result.env" \
  || fail "T2 sentinel not PASS"
grep -qxF "PHASE2_LIFECYCLE_RUN_BEGIN run_id=run-t2" "$PHASE2_BRINGUP_LOG_DEFAULT" \
  || fail "T2 current run marker missing"
set +e
p2b_current_run_log_identity_valid "$PHASE2_BRINGUP_LOG_DEFAULT" "run-t2"
T2_IDENT=$?
set -e
[[ "$T2_IDENT" -eq 0 ]] || fail "T2 identity rc=${T2_IDENT}"
pass "T2 AIO valid current-run stream still PASSES"

# ---------------------------------------------------------------------------
# T3 — AIO CURRENT MARKER + APT FAIL STILL FAILS
# ---------------------------------------------------------------------------
reset_lifecycle_files
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-t3"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VENDOR_T3="${TMP}/vendor-t3.sh"
cat >"$VENDOR_T3" <<'EOF'
#!/usr/bin/env bash
echo "APT_DEPENDENCY_CHECK=FAIL"
exit 0
EOF
chmod +x "$VENDOR_T3"
set +e
( p2b_worker_main "$VENDOR_T3" >/dev/null 2>&1 )
T3_RC=$?
set -e
[[ "$T3_RC" -ne 0 ]] || fail "T3 unexpectedly PASS"
[[ "$(p2b_read_state)" == "FAILED" ]] || fail "T3 state=$(p2b_read_state)"
grep -q 'FAILURE_REASON=APT_DEPENDENCY_CHECK' "$(p2b_dir)/completion.sentinel" \
  || fail "T3 missing APT_DEPENDENCY_CHECK failure"
if grep -q 'FAILURE_REASON=CURRENT_RUN_LOG_IDENTITY_INVALID' "$(p2b_dir)/completion.sentinel"; then
  fail "T3 valid identity was reported as log identity failure"
fi
pass "T3 AIO current marker + APT FAIL remains APT_DEPENDENCY_CHECK"

# ---------------------------------------------------------------------------
# T4 — CLUSTER INVALID LOG IDENTITY FAILS EARLY
# ---------------------------------------------------------------------------
reset_lifecycle_files
fill_bytes "$PHASE2_BRINGUP_LOG_DEFAULT" 8192 H
printf '\nHIST leftover\n' >>"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-t4"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VENDOR_T4="${TMP}/vendor-t4.sh"
cat >"$VENDOR_T4" <<'EOF'
#!/usr/bin/env bash
: >"${PHASE2_BRINGUP_LOG_DEFAULT}"
python3 -c 'import sys; sys.stdout.write("N"*10000)'
echo
echo "CLUSTER_JOIN_STATE ready=3 expected=3"
echo "APT_DEPENDENCY_CHECK=PASS"
echo "WORKER_ORCHESTRATION=PASS"
echo "Bringup complete: all nodes ready"
exit 0
EOF
chmod +x "$VENDOR_T4"
set +e
( p2b_worker_main "$VENDOR_T4" --worker-ips 192.0.2.10,192.0.2.11 >/dev/null 2>&1 )
T4_RC=$?
set -e
[[ "$T4_RC" -ne 0 ]] || fail "T4 unexpectedly PASS after cluster copytruncate"
[[ "$(p2b_read_state)" == "FAILED" ]] || fail "T4 state=$(p2b_read_state)"
grep -q 'FAILURE_REASON=CURRENT_RUN_LOG_IDENTITY_INVALID' "$(p2b_dir)/completion.sentinel" \
  || fail "T4 missing CURRENT_RUN_LOG_IDENTITY_INVALID"
if grep -q 'FAILURE_REASON=CLUSTER_JOIN_INCOMPLETE' "$(p2b_dir)/completion.sentinel"; then
  fail "T4 fell through to CLUSTER_JOIN_INCOMPLETE"
fi
if grep -q 'FAILURE_REASON=WORKER_ORCHESTRATION' "$(p2b_dir)/completion.sentinel"; then
  fail "T4 fell through to WORKER_ORCHESTRATION instead of log identity"
fi
pass "T4 cluster invalid log identity fails early"

# ---------------------------------------------------------------------------
# T5 — MARKER WRITE FAILURE PREVENTS VENDOR EXECUTION
# ---------------------------------------------------------------------------
reset_lifecycle_files
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-t5"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VENDOR_T5_RAN="${TMP}/vendor-t5-ran"
rm -f "$VENDOR_T5_RAN"
VENDOR_T5="${TMP}/vendor-t5.sh"
cat >"$VENDOR_T5" <<EOF
#!/usr/bin/env bash
touch '${VENDOR_T5_RAN}'
echo "APT_DEPENDENCY_CHECK=PASS"
echo "Bringup complete: all services ready"
exit 0
EOF
chmod +x "$VENDOR_T5"
__save_write_marker="$(declare -f p2b_write_current_run_log_marker)"
p2b_write_current_run_log_marker() { return 1; }
set +e
( p2b_worker_main "$VENDOR_T5" >/dev/null 2>&1 )
T5_RC=$?
set -e
eval "$__save_write_marker"
[[ "$T5_RC" -ne 0 ]] || fail "T5 unexpectedly PASS on marker write failure"
[[ "$(p2b_read_state)" == "FAILED" ]] || fail "T5 state=$(p2b_read_state)"
grep -q 'FAILURE_REASON=CURRENT_RUN_LOG_MARKER_WRITE' "$(p2b_dir)/completion.sentinel" \
  || fail "T5 missing CURRENT_RUN_LOG_MARKER_WRITE"
[[ ! -e "$VENDOR_T5_RAN" ]] || fail "T5 vendor fixture executed despite marker write failure"
pass "T5 marker write failure prevents vendor execution"

# ---------------------------------------------------------------------------
# T6 — PATTERN ABSENT VS STREAM INVALID ARE DISTINCT
# ---------------------------------------------------------------------------
reset_lifecycle_files
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-t6-valid"
write_file "$(p2b_dir)/log-start-offset" "0"
p2b_write_current_run_log_marker "$PHASE2_BRINGUP_LOG_DEFAULT" "run-t6-valid"
printf 'APT_DEPENDENCY_CHECK=PASS\n' >>"$PHASE2_BRINGUP_LOG_DEFAULT"
set +e
p2b_current_run_log_stream "$PHASE2_BRINGUP_LOG_DEFAULT" >/dev/null
T6_VALID_STREAM=$?
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'APT_DEPENDENCY_CHECK=FAIL'
T6_ABSENT=$?
set -e
[[ "$T6_VALID_STREAM" -eq 0 ]] || fail "T6 valid stream rc=${T6_VALID_STREAM}"
[[ "$T6_ABSENT" -eq 1 ]] || fail "T6 valid+absent rc=${T6_ABSENT} expected 1"

reset_lifecycle_files
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-t6-invalid"
write_file "$(p2b_dir)/log-start-offset" "0"
printf 'APT_DEPENDENCY_CHECK=PASS\nBringup complete: all services ready\n' \
  >>"$PHASE2_BRINGUP_LOG_DEFAULT"
set +e
p2b_current_run_log_stream "$PHASE2_BRINGUP_LOG_DEFAULT" >/dev/null
T6_INVALID_STREAM=$?
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'APT_DEPENDENCY_CHECK=FAIL'
T6_INVALID_CONTAINS=$?
set -e
[[ "$T6_INVALID_STREAM" -eq 2 ]] || fail "T6 invalid stream rc=${T6_INVALID_STREAM} expected 2"
[[ "$T6_INVALID_CONTAINS" -eq 2 ]] || fail "T6 invalid contains rc=${T6_INVALID_CONTAINS} expected 2"
[[ "$T6_ABSENT" -ne "$T6_INVALID_CONTAINS" ]] \
  || fail "T6 pattern-absent and invalid-stream collapsed to ${T6_ABSENT}"
pass "T6 pattern absent vs invalid stream are distinct"

# ---------------------------------------------------------------------------
# T7 — WRONG RUN MARKER REMAINS FAIL CLOSED
# ---------------------------------------------------------------------------
reset_lifecycle_files
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-new"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VENDOR_T7="${TMP}/vendor-t7.sh"
cat >"$VENDOR_T7" <<'EOF'
#!/usr/bin/env bash
: >"${PHASE2_BRINGUP_LOG_DEFAULT}"
echo "PHASE2_LIFECYCLE_RUN_BEGIN run_id=run-old"
echo "APT_DEPENDENCY_CHECK=PASS"
echo "Bringup complete: all services ready"
exit 0
EOF
chmod +x "$VENDOR_T7"
set +e
( p2b_worker_main "$VENDOR_T7" >/dev/null 2>&1 )
T7_RC=$?
set -e
[[ "$T7_RC" -ne 0 ]] || fail "T7 unexpectedly PASS with wrong run marker"
[[ "$(p2b_read_state)" == "FAILED" ]] || fail "T7 state=$(p2b_read_state)"
grep -q 'FAILURE_REASON=CURRENT_RUN_LOG_IDENTITY_INVALID' "$(p2b_dir)/completion.sentinel" \
  || fail "T7 missing CURRENT_RUN_LOG_IDENTITY_INVALID"
pass "T7 wrong-run marker remains fail closed"

# ---------------------------------------------------------------------------
# T8 — HISTORICAL SUCCESS CANNOT RESCUE INVALID CURRENT RUN
# ---------------------------------------------------------------------------
reset_lifecycle_files
{
  echo "APT_DEPENDENCY_CHECK=PASS"
  echo "CLUSTER_JOIN_STATE ready=3 expected=3"
  echo "Bringup complete: all nodes ready"
} >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-t8"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VENDOR_T8="${TMP}/vendor-t8.sh"
cat >"$VENDOR_T8" <<'EOF'
#!/usr/bin/env bash
python3 - "${PHASE2_BRINGUP_LOG_DEFAULT}" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text(errors="replace")
lines = [ln for ln in text.splitlines(True) if "PHASE2_LIFECYCLE_RUN_BEGIN" not in ln]
p.write_text("".join(lines))
PY
echo "APT_DEPENDENCY_CHECK=PASS"
echo "CLUSTER_JOIN_STATE ready=3 expected=3"
echo "Bringup complete: all services ready"
exit 0
EOF
chmod +x "$VENDOR_T8"
set +e
( p2b_worker_main "$VENDOR_T8" --worker-ips 192.0.2.10,192.0.2.11 >/dev/null 2>&1 )
T8_RC=$?
set -e
[[ "$T8_RC" -ne 0 ]] || fail "T8 unexpectedly PASS from historical success"
[[ "$(p2b_read_state)" == "FAILED" ]] || fail "T8 state=$(p2b_read_state)"
grep -q 'FAILURE_REASON=CURRENT_RUN_LOG_IDENTITY_INVALID' "$(p2b_dir)/completion.sentinel" \
  || fail "T8 missing CURRENT_RUN_LOG_IDENTITY_INVALID"
pass "T8 historical success cannot rescue invalid current run"

clone_fn() {
  local src="$1" dest="$2"
  eval "$(declare -f "$src" | sed "1s/${src}/${dest}/")"
}

assert_failed_identity() {
  local label="$1"
  [[ "$(p2b_read_state)" == "FAILED" ]] || fail "${label} state=$(p2b_read_state)"
  grep -q 'FAILURE_REASON=CURRENT_RUN_LOG_IDENTITY_INVALID' "$(p2b_dir)/completion.sentinel" \
    || fail "${label} missing CURRENT_RUN_LOG_IDENTITY_INVALID"
  grep -q 'BRINGUP_TERMINAL_STATE=FAILED' "$(p2b_dir)/completion.sentinel" \
    || fail "${label} sentinel not FAILED"
  grep -q 'BRINGUP_COMPLETION_SENTINEL=FAIL' "$(p2b_dir)/completion.sentinel" \
    || fail "${label} sentinel not FAIL"
  if grep -q 'BRINGUP_TERMINAL_STATE=COMPLETED' "$(p2b_dir)/completion.sentinel"; then
    fail "${label} wrote COMPLETED"
  fi
  if grep -q '^BRINGUP_RESULT=PASS$' "$(p2b_dir)/result.env" 2>/dev/null; then
    fail "${label} wrote result PASS"
  fi
}

setup_rc_run() {
  local run_id="$1"
  reset_lifecycle_files
  : >"$PHASE2_BRINGUP_LOG_DEFAULT"
  write_file "$(p2b_dir)/run-id" "$run_id"
  write_file "$(p2b_dir)/target-version" "6.5.0"
  write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
  write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# ---------------------------------------------------------------------------
# RC-T1. VALID STREAM + PATTERN ABSENT => contains rc=1, lifecycle continues
# ---------------------------------------------------------------------------
setup_rc_run "run-rc-t1"
p2b_write_current_run_log_marker "$PHASE2_BRINGUP_LOG_DEFAULT" "run-rc-t1"
printf 'APT_DEPENDENCY_CHECK=PASS\n' >>"$PHASE2_BRINGUP_LOG_DEFAULT"
set +e
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'APT_DEPENDENCY_CHECK=FAIL'
RC_T1_CONTAINS=$?
set -e
[[ "$RC_T1_CONTAINS" -eq 1 ]] || fail "RC-T1 contains rc=${RC_T1_CONTAINS} expected 1"
VENDOR_RC_T1="${TMP}/vendor-rc-t1.sh"
cat >"$VENDOR_RC_T1" <<'EOF'
#!/usr/bin/env bash
echo "APT_DEPENDENCY_CHECK=PASS"
exit 0
EOF
chmod +x "$VENDOR_RC_T1"
set +e
( p2b_worker_main "$VENDOR_RC_T1" >/dev/null 2>&1 )
RC_T1_RC=$?
set -e
[[ "$RC_T1_RC" -eq 0 ]] || fail "RC-T1 worker rc=${RC_T1_RC}"
[[ "$(p2b_read_state)" == "COMPLETED" ]] || fail "RC-T1 state=$(p2b_read_state)"
pass "RC-T1 valid stream + pattern absent is rc=1 and lifecycle continues"

# ---------------------------------------------------------------------------
# RC-T2. VALID STREAM + APT FAIL
# ---------------------------------------------------------------------------
setup_rc_run "run-rc-t2"
VENDOR_RC_T2="${TMP}/vendor-rc-t2.sh"
cat >"$VENDOR_RC_T2" <<'EOF'
#!/usr/bin/env bash
echo "APT_DEPENDENCY_CHECK=FAIL"
exit 0
EOF
chmod +x "$VENDOR_RC_T2"
set +e
( p2b_worker_main "$VENDOR_RC_T2" >/dev/null 2>&1 )
RC_T2_RC=$?
set -e
[[ "$RC_T2_RC" -ne 0 ]] || fail "RC-T2 unexpectedly PASS"
[[ "$(p2b_read_state)" == "FAILED" ]] || fail "RC-T2 state=$(p2b_read_state)"
grep -q 'FAILURE_REASON=APT_DEPENDENCY_CHECK' "$(p2b_dir)/completion.sentinel" \
  || fail "RC-T2 missing APT_DEPENDENCY_CHECK"
if grep -q 'FAILURE_REASON=CURRENT_RUN_LOG_IDENTITY_INVALID' "$(p2b_dir)/completion.sentinel"; then
  fail "RC-T2 valid APT FAIL was reported as log identity failure"
fi
pass "RC-T2 valid stream + APT FAIL keeps FAILURE_REASON=APT_DEPENDENCY_CHECK"

# ---------------------------------------------------------------------------
# RC-T3. VALID STREAM + WORKER_ORCHESTRATION FAIL
# ---------------------------------------------------------------------------
setup_rc_run "run-rc-t3"
VENDOR_RC_T3="${TMP}/vendor-rc-t3.sh"
cat >"$VENDOR_RC_T3" <<'EOF'
#!/usr/bin/env bash
echo "WORKER_ORCHESTRATION=FAIL"
exit 0
EOF
chmod +x "$VENDOR_RC_T3"
set +e
( p2b_worker_main "$VENDOR_RC_T3" >/dev/null 2>&1 )
RC_T3_RC=$?
set -e
[[ "$RC_T3_RC" -ne 0 ]] || fail "RC-T3 unexpectedly PASS"
[[ "$(p2b_read_state)" == "FAILED" ]] || fail "RC-T3 state=$(p2b_read_state)"
grep -q 'FAILURE_REASON=WORKER_ORCHESTRATION' "$(p2b_dir)/completion.sentinel" \
  || fail "RC-T3 missing WORKER_ORCHESTRATION"
if grep -q 'FAILURE_REASON=CURRENT_RUN_LOG_IDENTITY_INVALID' "$(p2b_dir)/completion.sentinel"; then
  fail "RC-T3 valid orch FAIL was reported as log identity failure"
fi
pass "RC-T3 valid stream + WORKER_ORCHESTRATION=FAIL keeps specific reason"

# ---------------------------------------------------------------------------
# RC-T4. Identity break between initial gate and APT check (AIO TOCTOU)
# ---------------------------------------------------------------------------
setup_rc_run "run-rc-t4"
VENDOR_RC_T4="${TMP}/vendor-rc-t4.sh"
cat >"$VENDOR_RC_T4" <<'EOF'
#!/usr/bin/env bash
echo "APT_DEPENDENCY_CHECK=PASS"
exit 0
EOF
chmod +x "$VENDOR_RC_T4"
clone_fn p2b_current_run_log_contains p2b_current_run_log_contains_orig
p2b_current_run_log_contains() {
  if [[ "$2" == 'APT_DEPENDENCY_CHECK=FAIL' ]]; then
    : >"$1"
    python3 -c 'import sys; sys.stdout.write("N"*10000+"\n")' >>"$1"
    printf 'APT_DEPENDENCY_CHECK=PASS\n' >>"$1"
  fi
  p2b_current_run_log_contains_orig "$@"
}
set +e
( p2b_worker_main "$VENDOR_RC_T4" >/dev/null 2>&1 )
RC_T4_RC=$?
set -e
eval "$(declare -f p2b_current_run_log_contains_orig | sed '1s/p2b_current_run_log_contains_orig/p2b_current_run_log_contains/')"
unset -f p2b_current_run_log_contains_orig
[[ "$RC_T4_RC" -ne 0 ]] || fail "RC-T4 unexpectedly PASS"
assert_failed_identity "RC-T4"
pass "RC-T4 AIO TOCTOU after initial identity cannot PASS"

# ---------------------------------------------------------------------------
# RC-T5. Identity break between APT and WORKER contains checks
# ---------------------------------------------------------------------------
setup_rc_run "run-rc-t5"
VENDOR_RC_T5="${TMP}/vendor-rc-t5.sh"
cat >"$VENDOR_RC_T5" <<'EOF'
#!/usr/bin/env bash
echo "APT_DEPENDENCY_CHECK=PASS"
exit 0
EOF
chmod +x "$VENDOR_RC_T5"
clone_fn p2b_current_run_log_contains p2b_current_run_log_contains_orig
p2b_current_run_log_contains() {
  if [[ "$2" == 'WORKER_ORCHESTRATION=FAIL' ]]; then
    : >"$1"
    python3 -c 'import sys; sys.stdout.write("N"*10000+"\n")' >>"$1"
  fi
  p2b_current_run_log_contains_orig "$@"
}
set +e
( p2b_worker_main "$VENDOR_RC_T5" >/dev/null 2>&1 )
RC_T5_RC=$?
set -e
eval "$(declare -f p2b_current_run_log_contains_orig | sed '1s/p2b_current_run_log_contains_orig/p2b_current_run_log_contains/')"
unset -f p2b_current_run_log_contains_orig
[[ "$RC_T5_RC" -ne 0 ]] || fail "RC-T5 unexpectedly PASS"
assert_failed_identity "RC-T5"
pass "RC-T5 identity break before WORKER contains cannot PASS"

# ---------------------------------------------------------------------------
# RC-T6. Identity break after secondary checks, before PASS sentinel
# ---------------------------------------------------------------------------
setup_rc_run "run-rc-t6"
VENDOR_RC_T6="${TMP}/vendor-rc-t6.sh"
cat >"$VENDOR_RC_T6" <<'EOF'
#!/usr/bin/env bash
echo "APT_DEPENDENCY_CHECK=PASS"
exit 0
EOF
chmod +x "$VENDOR_RC_T6"
clone_fn p2b_require_current_run_log_identity p2b_require_current_run_log_identity_orig
RC_T6_IDENT=0
p2b_require_current_run_log_identity() {
  RC_T6_IDENT=$((RC_T6_IDENT + 1))
  if [[ "$RC_T6_IDENT" -ge 2 ]]; then
    : >"$1"
    python3 -c 'import sys; sys.stdout.write("N"*10000+"\n")' >>"$1"
  fi
  p2b_require_current_run_log_identity_orig "$@"
}
set +e
( p2b_worker_main "$VENDOR_RC_T6" >/dev/null 2>&1 )
RC_T6_RC=$?
set -e
eval "$(declare -f p2b_require_current_run_log_identity_orig | sed '1s/p2b_require_current_run_log_identity_orig/p2b_require_current_run_log_identity/')"
unset -f p2b_require_current_run_log_identity_orig
[[ "$RC_T6_RC" -ne 0 ]] || fail "RC-T6 unexpectedly PASS"
assert_failed_identity "RC-T6"
pass "RC-T6 final pre-PASS identity gate cannot be skipped"

# ---------------------------------------------------------------------------
# RC-T7. NORMAL AIO STILL PASSES
# ---------------------------------------------------------------------------
setup_rc_run "run-rc-t7"
VENDOR_RC_T7="${TMP}/vendor-rc-t7.sh"
cat >"$VENDOR_RC_T7" <<'EOF'
#!/usr/bin/env bash
echo "APT_DEPENDENCY_CHECK=PASS"
exit 0
EOF
chmod +x "$VENDOR_RC_T7"
set +e
( p2b_worker_main "$VENDOR_RC_T7" >/dev/null 2>&1 )
RC_T7_RC=$?
set -e
[[ "$RC_T7_RC" -eq 0 ]] || fail "RC-T7 worker rc=${RC_T7_RC}"
[[ "$(p2b_read_state)" == "COMPLETED" ]] || fail "RC-T7 state=$(p2b_read_state)"
grep -q '^BRINGUP_RESULT=PASS$' "$(p2b_dir)/result.env" || fail "RC-T7 result.env not PASS"
grep -q '^BRINGUP_EXIT_CODE=0$' "$(p2b_dir)/result.env" || fail "RC-T7 exit code not 0"
grep -q '^BRINGUP_COMPLETION_SENTINEL=PASS$' "$(p2b_dir)/result.env" \
  || fail "RC-T7 sentinel not PASS"
pass "RC-T7 normal AIO still PASSES"

# ---------------------------------------------------------------------------
# RC-T8. NORMAL CLUSTER STILL PASSES WITH CURRENT 3/3 + orch PASS
# ---------------------------------------------------------------------------
setup_rc_run "run-rc-t8"
VENDOR_RC_T8="${TMP}/vendor-rc-t8.sh"
cat >"$VENDOR_RC_T8" <<'EOF'
#!/usr/bin/env bash
echo "WORKER_ORCHESTRATION=PASS"
echo "CLUSTER_JOIN_STATE ready=3 expected=3"
exit 0
EOF
chmod +x "$VENDOR_RC_T8"
set +e
( p2b_worker_main "$VENDOR_RC_T8" --worker-ips 192.0.2.10,192.0.2.11 >/dev/null 2>&1 )
RC_T8_RC=$?
set -e
[[ "$RC_T8_RC" -eq 0 ]] || fail "RC-T8 worker rc=${RC_T8_RC}"
[[ "$(p2b_read_state)" == "COMPLETED" ]] || fail "RC-T8 state=$(p2b_read_state)"
grep -q '^BRINGUP_COMPLETION_SENTINEL=PASS$' "$(p2b_dir)/result.env" \
  || fail "RC-T8 sentinel not PASS"
pass "RC-T8 normal cluster current 3/3 still PASSES"

# ---------------------------------------------------------------------------
# RC-T9. WRONG RUN MARKER STILL FAILS
# ---------------------------------------------------------------------------
setup_rc_run "run-new"
VENDOR_RC_T9="${TMP}/vendor-rc-t9.sh"
cat >"$VENDOR_RC_T9" <<'EOF'
#!/usr/bin/env bash
: >"${PHASE2_BRINGUP_LOG_DEFAULT}"
echo "PHASE2_LIFECYCLE_RUN_BEGIN run_id=run-old"
echo "APT_DEPENDENCY_CHECK=PASS"
echo "Bringup complete: all services ready"
exit 0
EOF
chmod +x "$VENDOR_RC_T9"
set +e
( p2b_worker_main "$VENDOR_RC_T9" >/dev/null 2>&1 )
RC_T9_RC=$?
set -e
[[ "$RC_T9_RC" -ne 0 ]] || fail "RC-T9 unexpectedly PASS"
assert_failed_identity "RC-T9"
pass "RC-T9 wrong-run marker remains unusable"

# ---------------------------------------------------------------------------
# RC-T10. HISTORICAL SUCCESS CANNOT RESCUE INVALID CURRENT RUN
# ---------------------------------------------------------------------------
reset_lifecycle_files
{
  echo "APT_DEPENDENCY_CHECK=PASS"
  echo "WORKER_ORCHESTRATION=PASS"
  echo "CLUSTER_JOIN_STATE ready=3 expected=3"
  echo "Bringup complete: all nodes ready"
} >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-rc-t10"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VENDOR_RC_T10="${TMP}/vendor-rc-t10.sh"
cat >"$VENDOR_RC_T10" <<'EOF'
#!/usr/bin/env bash
python3 - "${PHASE2_BRINGUP_LOG_DEFAULT}" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text(errors="replace")
lines = [ln for ln in text.splitlines(True) if "PHASE2_LIFECYCLE_RUN_BEGIN" not in ln]
p.write_text("".join(lines))
PY
echo "APT_DEPENDENCY_CHECK=PASS"
echo "WORKER_ORCHESTRATION=PASS"
echo "CLUSTER_JOIN_STATE ready=3 expected=3"
echo "Bringup complete: all services ready"
exit 0
EOF
chmod +x "$VENDOR_RC_T10"
set +e
( p2b_worker_main "$VENDOR_RC_T10" --worker-ips 192.0.2.10,192.0.2.11 >/dev/null 2>&1 )
RC_T10_RC=$?
set -e
[[ "$RC_T10_RC" -ne 0 ]] || fail "RC-T10 unexpectedly PASS from historical success"
assert_failed_identity "RC-T10"
pass "RC-T10 historical success cannot rescue invalid current run"

append_current_run_lines() {
  local file="$1" n="${2:-30000}"
  python3 -c 'import sys
p, n = sys.argv[1], int(sys.argv[2])
line = b"bringup current-run output " + (b"x" * 80) + b"\n"
with open(p, "ab") as f:
    f.write(line * n)
' "$file" "$n"
}

# ---------------------------------------------------------------------------
# SP-T1. Marker near start + multi-MB trailing current-run log => identity PASS
# ---------------------------------------------------------------------------
reset_lifecycle_files
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-sp-t1"
write_file "$(p2b_dir)/log-start-offset" "0"
p2b_write_current_run_log_marker "$PHASE2_BRINGUP_LOG_DEFAULT" "run-sp-t1"
append_current_run_lines "$PHASE2_BRINGUP_LOG_DEFAULT" 30000
set +e
p2b_current_run_log_identity_valid "$PHASE2_BRINGUP_LOG_DEFAULT" "run-sp-t1" "0"
SP_T1=$?
set -e
[[ "$SP_T1" -eq 0 ]] || fail "SP-T1 identity rc=${SP_T1} on multi-MB current-run log"
pass "SP-T1 marker near start + multi-MB trailing log identity PASS"

# ---------------------------------------------------------------------------
# SP-T2. Failure/success pattern near start + multi-MB trailing log
# ---------------------------------------------------------------------------
reset_lifecycle_files
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-sp-t2"
write_file "$(p2b_dir)/log-start-offset" "0"
p2b_write_current_run_log_marker "$PHASE2_BRINGUP_LOG_DEFAULT" "run-sp-t2"
printf 'APT_DEPENDENCY_CHECK=FAIL\nWORKER_ORCHESTRATION=PASS\n' >>"$PHASE2_BRINGUP_LOG_DEFAULT"
append_current_run_lines "$PHASE2_BRINGUP_LOG_DEFAULT" 30000
set +e
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'APT_DEPENDENCY_CHECK=FAIL'
SP_T2_FAIL=$?
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'WORKER_ORCHESTRATION=PASS'
SP_T2_PASS=$?
set -e
[[ "$SP_T2_FAIL" -eq 0 ]] || fail "SP-T2 FAIL pattern rc=${SP_T2_FAIL} expected 0"
[[ "$SP_T2_PASS" -eq 0 ]] || fail "SP-T2 PASS pattern rc=${SP_T2_PASS} expected 0"
[[ "$SP_T2_FAIL" -ne 141 && "$SP_T2_PASS" -ne 141 ]] \
  || fail "SP-T2 SIGPIPE rc141 false negative"
pass "SP-T2 pattern near start + multi-MB trailing log found without rc141"

# ---------------------------------------------------------------------------
# SP-T3. Pattern genuinely absent in large current-run log
# ---------------------------------------------------------------------------
reset_lifecycle_files
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-sp-t3"
write_file "$(p2b_dir)/log-start-offset" "0"
p2b_write_current_run_log_marker "$PHASE2_BRINGUP_LOG_DEFAULT" "run-sp-t3"
printf 'APT_DEPENDENCY_CHECK=PASS\n' >>"$PHASE2_BRINGUP_LOG_DEFAULT"
append_current_run_lines "$PHASE2_BRINGUP_LOG_DEFAULT" 30000
set +e
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'APT_DEPENDENCY_CHECK=FAIL'
SP_T3=$?
set -e
[[ "$SP_T3" -eq 1 ]] || fail "SP-T3 absent pattern rc=${SP_T3} expected 1"
pass "SP-T3 genuinely absent pattern in large log"

# ---------------------------------------------------------------------------
# SP-T4. Recorded offset past file size remains fail-closed
# ---------------------------------------------------------------------------
reset_lifecycle_files
printf 'PHASE2_LIFECYCLE_RUN_BEGIN run_id=run-sp-t4\n' >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-sp-t4"
write_file "$(p2b_dir)/log-start-offset" "999999"
set +e
p2b_current_run_log_identity_valid "$PHASE2_BRINGUP_LOG_DEFAULT" "run-sp-t4"
SP_T4_IDENT=$?
p2b_current_run_log_stream "$PHASE2_BRINGUP_LOG_DEFAULT" >/dev/null
SP_T4_STREAM=$?
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'PHASE2_LIFECYCLE_RUN_BEGIN'
SP_T4_CONTAINS=$?
set -e
[[ "$SP_T4_IDENT" -eq 2 ]] || fail "SP-T4 identity rc=${SP_T4_IDENT} expected 2"
[[ "$SP_T4_STREAM" -eq 2 ]] || fail "SP-T4 stream rc=${SP_T4_STREAM} expected 2"
[[ "$SP_T4_CONTAINS" -eq 2 ]] || fail "SP-T4 contains rc=${SP_T4_CONTAINS} expected 2"
pass "SP-T4 offset past file size fail-closed"

# ---------------------------------------------------------------------------
# SP-T7. vendor rc=0 + valid large current-run log completes normally
# ---------------------------------------------------------------------------
reset_lifecycle_files
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-sp-t7"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VENDOR_SP_T7="${TMP}/vendor-sp-t7.sh"
cat >"$VENDOR_SP_T7" <<'EOF'
#!/usr/bin/env bash
python3 -c 'import os,sys
p=os.environ["PHASE2_BRINGUP_LOG_DEFAULT"]
line=b"bringup current-run output "+(b"x"*80)+b"\n"
with open(p,"ab") as f:
    f.write(b"APT_DEPENDENCY_CHECK=PASS\n")
    f.write(line*30000)
'
exit 0
EOF
chmod +x "$VENDOR_SP_T7"
set +e
( p2b_worker_main "$VENDOR_SP_T7" >/dev/null 2>&1 )
SP_T7_RC=$?
set -e
[[ "$SP_T7_RC" -eq 0 ]] || fail "SP-T7 worker rc=${SP_T7_RC}"
[[ "$(p2b_read_state)" == "COMPLETED" ]] || fail "SP-T7 state=$(p2b_read_state)"
grep -q '^BRINGUP_COMPLETION_SENTINEL=PASS$' "$(p2b_dir)/result.env" \
  || fail "SP-T7 result not PASS"
pass "SP-T7 vendor rc=0 + valid large current-run log completes"

# ---------------------------------------------------------------------------
# SP-T8. vendor rc=0 + invalid current-run identity still FAIL
# ---------------------------------------------------------------------------
reset_lifecycle_files
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-sp-t8"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VENDOR_SP_T8="${TMP}/vendor-sp-t8.sh"
cat >"$VENDOR_SP_T8" <<'EOF'
#!/usr/bin/env bash
python3 - "${PHASE2_BRINGUP_LOG_DEFAULT}" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text(errors="replace")
lines = [ln for ln in text.splitlines(True) if "PHASE2_LIFECYCLE_RUN_BEGIN" not in ln]
p.write_text("".join(lines))
line = "bringup current-run output " + ("x" * 80) + "\n"
p.write_text(p.read_text(errors="replace") + "APT_DEPENDENCY_CHECK=PASS\n" + line * 2000)
PY
exit 0
EOF
chmod +x "$VENDOR_SP_T8"
set +e
( p2b_worker_main "$VENDOR_SP_T8" >/dev/null 2>&1 )
SP_T8_RC=$?
set -e
[[ "$SP_T8_RC" -ne 0 ]] || fail "SP-T8 unexpectedly PASS with invalid identity"
assert_failed_identity "SP-T8"
pass "SP-T8 vendor rc=0 + invalid current-run identity still FAIL"

echo "TEST_BRINGUP_LIFECYCLE_RUN_CONTRACT=PASS"
