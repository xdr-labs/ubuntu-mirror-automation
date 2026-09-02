#!/usr/bin/env bash
# Semantic contract for remote orchestration nodes (workers + standby).
# Text-marker survival is not sufficient; these cases exercise behavior.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHER="${ROOT}/scripts/lib/patch_dp_phase2_bringup.py"
COMPAT="${ROOT}/scripts/lib/phase2_bringup_patch/fragment_compat.sh"
CRED_SSH="${ROOT}/scripts/lib/phase2_bringup_patch/fragment_credential_ssh.sh"
PREV_UPSTREAM="${ROOT}/tests/fixtures/dp-phase2/upstream_bringup_unpatched.sh"
F1A73="${ROOT}/tests/fixtures/dp-phase2/production-f1a73/bringup_py3_dp_after_os_upgrade.sh"
EXPECTED_F1A73_SHA1="f1a73c1d4502e2efcf55197865d2ade345d9c82f"
WRAPPER="${ROOT}/client/bringup_py3_dp_lifecycle.sh"
LIFECYCLE="${ROOT}/client/lib/dp-phase2-bringup-lifecycle.sh"

FAIL=0
PASS=0
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "======== test_phase2_remote_orchestration_semantics ========"

F1SHA="$(sha1sum "$F1A73" | awk '{print $1}')"
[[ "$F1SHA" == "$EXPECTED_F1A73_SHA1" ]] \
  && pass "production f1a73 SHA1=${F1SHA}" \
  || fail "production f1a73 SHA1 want=${EXPECTED_F1A73_SHA1} got=${F1SHA}"

PREV_GEN="${WORKDIR}/prev.sh"
F1_GEN="${WORKDIR}/f1a73.sh"
python3 "$PATCHER" --upstream "$PREV_UPSTREAM" --output "$PREV_GEN" \
  >"${WORKDIR}/prev.patch.log"
python3 "$PATCHER" --upstream "$F1A73" --output "$F1_GEN" \
  >"${WORKDIR}/f1.patch.log"
grep -q 'BRINGUP_PATCH_COMPAT=PASS' "${WORKDIR}/prev.patch.log" \
  && pass "previous upstream patch generation" \
  || fail "previous upstream patch generation"
grep -q 'BRINGUP_PATCH_COMPAT=PASS' "${WORKDIR}/f1.patch.log" \
  && pass "f1a73 patch generation" \
  || fail "f1a73 patch generation"
bash -n "$PREV_GEN" && bash -n "$F1_GEN" && bash -n "$COMPAT" \
  && bash -n "$WRAPPER" && bash -n "$LIFECYCLE" \
  && pass "bash -n generated + wrapper" \
  || fail "bash -n generated + wrapper"
grep -q 'STANDBY_IPS=""' "$F1_GEN" && grep -q 'token_extra="&standby=1"' "$F1_GEN" \
  && grep -q 'AELDEV-73583' "$F1_GEN" \
  && pass "f1a73 vendor standby changes preserved" \
  || fail "f1a73 vendor standby changes preserved"
# Workers first, then standby, in the generated node_specs builder.
awk '
  /node_specs=\(\)/ {s=1}
  s && /WORKER_IPS/ {w=NR}
  s && /STANDBY_IPS/ {b=NR}
  s && /^    local node_spec worker_ip node_role/ {exit}
  END { exit((w>0 && b>w) ? 0 : 1) }
' "$F1_GEN" \
  && pass "generated node_specs builds workers before standby" \
  || fail "generated node_specs builds workers before standby"

extract_fn() {
  local src="$1" name="$2" dest="$3"
  awk -v n="$name" '
    $0 ~ "^" n "\\(\\)" {keep=1}
    keep {print}
    keep && /^}$/ {exit}
  ' "$src" >"$dest"
  [[ -s "$dest" ]]
}

# ---------------------------------------------------------------------------
# Argument / password contract (CASES 1-6) + normalization (7-8)
# ---------------------------------------------------------------------------
PARSE_SRC="${WORKDIR}/parse_args.sh"
extract_fn "$F1_GEN" parse_args "$PARSE_SRC"

run_parse() {
  local err="${WORKDIR}/parse.err"
  : >"$err"
  set +e
  PARSE_OUT="$(
    exec 2>"$err"
    VERSION=""
    WORKER_IPS=""
    WORKER_PASSWORD=""
    PHASE2_WORKER_PASSWORD_FILE=""
    STANDBY_IPS=""
    ROLE=""
    DRY_RUN=false
    SKIP_DOWNLOAD=false
    WORKER_MODE=false
    PRE_UPGRADE_CLEANUP=false
    AUTO_OS_UPGRADE=false
    RECLAIM_OVERLAY2_ONLY=false
    RELABEL_ELASTIC_ONLY=false
    WORKER_SSH_KEY=""
    PHASE2_WORKER_PASSWORD_PRIVATE_DIR="$WORKDIR"
    die() { echo "FATAL: $*" >&2; exit 1; }
    log() { echo "$*" >&2; }
    check_version_guard() { return 0; }
    # shellcheck disable=SC1090
    source "$CRED_SSH"
    # shellcheck disable=SC1090
    source "$COMPAT"
    # shellcheck disable=SC1090
    source "$PARSE_SRC"
    parse_args "$@"
    printf 'WORKER_IPS=%s\n' "$WORKER_IPS"
    printf 'STANDBY_IPS=%s\n' "$STANDBY_IPS"
    printf 'WORKER_PASSWORD=%s\n' "${WORKER_PASSWORD:-}"
    printf 'PHASE2_WORKER_PASSWORD_FILE=%s\n' "${PHASE2_WORKER_PASSWORD_FILE:-}"
    if [[ -n "${PHASE2_WORKER_PASSWORD_FILE:-}" && -f "$PHASE2_WORKER_PASSWORD_FILE" ]]; then
      printf 'PHASE2_WORKER_PASSWORD_FILE_CONTENT=%s\n' "$(cat "$PHASE2_WORKER_PASSWORD_FILE")"
    fi
  )"
  PARSE_RC=$?
  PARSE_ERR="$(cat "$err")"
  set -e
}

# CASE 1: AIO, no password
run_parse --version 6.6.0 --skip-download
[[ "$PARSE_RC" -eq 0 ]] && pass "CASE1 aio no password accepted" \
  || fail "CASE1 aio: rc=${PARSE_RC} ${PARSE_ERR}"

# CASE 2: worker only, password missing
run_parse --version 6.6.0 --skip-download --worker-ips 192.0.2.10
[[ "$PARSE_RC" -ne 0 ]] \
  && echo "$PARSE_ERR" | grep -q -- '--worker-ips/--standby requires --worker-password-file' \
  && pass "CASE2 worker-only missing password rejected before orch" \
  || fail "CASE2: rc=${PARSE_RC} ${PARSE_ERR}"

# CASE 3: worker only, password provided
run_parse --version 6.6.0 --skip-download --worker-ips 192.0.2.10 --worker-password 'secret'
[[ "$PARSE_RC" -eq 0 ]] && echo "$PARSE_OUT" | grep -qx 'WORKER_PASSWORD=' \
  && echo "$PARSE_OUT" | grep -Fxq 'PHASE2_WORKER_PASSWORD_FILE_CONTENT=secret' \
  && pass "CASE3 worker-only with password accepted" \
  || fail "CASE3: rc=${PARSE_RC} ${PARSE_ERR}"

# CASE 4: standby only, password missing
run_parse --version 6.6.0 --skip-download --standby 192.0.2.20
[[ "$PARSE_RC" -ne 0 ]] \
  && echo "$PARSE_ERR" | grep -q -- '--worker-ips/--standby requires --worker-password-file' \
  && pass "CASE4 standby-only missing password rejected before orch" \
  || fail "CASE4: rc=${PARSE_RC} ${PARSE_ERR}"

# CASE 5: standby only, password provided
run_parse --version 6.6.0 --skip-download --standby 192.0.2.20 --worker-password 'secret'
[[ "$PARSE_RC" -eq 0 ]] && echo "$PARSE_OUT" | grep -Fxq 'STANDBY_IPS=192.0.2.20' \
  && pass "CASE5 standby-only with password accepted" \
  || fail "CASE5: rc=${PARSE_RC} ${PARSE_ERR}"

# CASE 6: workers + standby, password provided
run_parse --version 6.6.0 --skip-download \
  --worker-ips 192.0.2.10 --standby 192.0.2.20 --worker-password 'secret'
[[ "$PARSE_RC" -eq 0 ]] \
  && echo "$PARSE_OUT" | grep -Fxq 'WORKER_IPS=192.0.2.10' \
  && echo "$PARSE_OUT" | grep -Fxq 'STANDBY_IPS=192.0.2.20' \
  && pass "CASE6 workers+standby with password accepted" \
  || fail "CASE6: rc=${PARSE_RC} ${PARSE_OUT} ${PARSE_ERR}"

# CASE 7: conflicting IP between worker and standby
run_parse --version 6.6.0 --skip-download \
  --worker-ips 192.0.2.10 --standby 192.0.2.10 --worker-password 'secret'
[[ "$PARSE_RC" -ne 0 ]] \
  && echo "$PARSE_ERR" | grep -q 'reason=role_conflict_ip' \
  && pass "CASE7 worker/standby role conflict fail-closed" \
  || fail "CASE7: rc=${PARSE_RC} ${PARSE_ERR}"

run_parse --version 6.6.0 --skip-download \
  --worker-ips '192.0.2.10,192.0.2.10' --worker-password 'secret'
[[ "$PARSE_RC" -ne 0 ]] \
  && echo "$PARSE_ERR" | grep -q 'reason=duplicate_worker_ip' \
  && pass "CASE7b duplicate worker IP fail-closed" \
  || fail "CASE7b: rc=${PARSE_RC} ${PARSE_ERR}"

# CASE 8: whitespace around comma-separated IPs
run_parse --version 6.6.0 --skip-download \
  --worker-ips ' 192.0.2.10 , 192.0.2.11 ' --standby ' 192.0.2.20 ' \
  --worker-password 'secret'
[[ "$PARSE_RC" -eq 0 ]] \
  && echo "$PARSE_OUT" | grep -Fxq 'WORKER_IPS=192.0.2.10,192.0.2.11' \
  && echo "$PARSE_OUT" | grep -Fxq 'STANDBY_IPS=192.0.2.20' \
  && pass "CASE8 whitespace-normalized IP lists" \
  || fail "CASE8: rc=${PARSE_RC} ${PARSE_OUT} ${PARSE_ERR}"

if echo "$PARSE_OUT$PARSE_ERR" | grep -Fq 'secret'; then
  : # password is printed by the test harness printf, not by parse_args logs
fi
if echo "$PARSE_ERR" | grep -Fq 'secret'; then
  fail "password leaked into parse stderr"
else
  pass "parse stderr does not contain password"
fi

# Previous upstream still requires password for workers.
extract_fn "$PREV_GEN" parse_args "${WORKDIR}/parse_prev.sh"
set +e
  PREV_ERR="$(
  VERSION=""
  WORKER_IPS=""
  WORKER_PASSWORD=""
  PHASE2_WORKER_PASSWORD_FILE=""
  STANDBY_IPS=""
  ROLE=""
  DRY_RUN=false
  SKIP_DOWNLOAD=false
  WORKER_MODE=false
  PRE_UPGRADE_CLEANUP=false
  AUTO_OS_UPGRADE=false
  RECLAIM_OVERLAY2_ONLY=false
  WORKER_SSH_KEY=""
  PHASE2_WORKER_PASSWORD_PRIVATE_DIR="$WORKDIR"
  die() { echo "FATAL: $*"; exit 1; }
  log() { :; }
  check_version_guard() { return 0; }
  source "$CRED_SSH"
  source "$COMPAT"
  source "${WORKDIR}/parse_prev.sh"
  parse_args --version 6.6.0 --skip-download --worker-ips 192.0.2.10
  echo SHOULD_NOT_REACH
)"
PREV_RC=$?
set -e
[[ "$PREV_RC" -ne 0 ]] && echo "$PREV_ERR" | grep -q -- '--worker-ips/--standby requires --worker-password-file' \
  && pass "previous upstream worker-password contract" \
  || fail "previous upstream worker-password contract: ${PREV_ERR}"

# ---------------------------------------------------------------------------
# Token API readiness (CASES 9-12)
# ---------------------------------------------------------------------------
extract_fn "$F1_GEN" wait_for_master_token_api "${WORKDIR}/wait_8003.sh"

write_curl() {
  local dest="$1"
  cat >"$dest"
  chmod +x "$dest"
}

run_wait() {
  local bindir="$1"
  shift
  PATH="${bindir}:$PATH"
  log() { echo "$*"; }
  MASTER_TOKEN_API_PORT=8003
  MASTER_TOKEN_API_WAIT_SECONDS=0
  # shellcheck disable=SC1090
  source "${WORKDIR}/wait_8003.sh"
  wait_for_master_token_api 0
}

BIN_LB="${WORKDIR}/bin-lb"
mkdir -p "$BIN_LB"
write_curl "${BIN_LB}/curl" <<'EOF'
#!/usr/bin/env bash
echo 404
exit 0
EOF
set +e
CASE9="$(WORKER_IPS="" STANDBY_IPS="" run_wait "$BIN_LB" 2>&1)"
CASE9_RC=$?
set -e
echo "$CASE9" | grep -q 'MASTER_TOKEN_API_READY=YES' && [[ "$CASE9_RC" -eq 0 ]] \
  && pass "CASE9 AIO loopback ready allowed" \
  || fail "CASE9: rc=${CASE9_RC} ${CASE9}"

BIN_MIX="${WORKDIR}/bin-mix"
mkdir -p "$BIN_MIX"
write_curl "${BIN_MIX}/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "$arg" in
    https://*) url="$arg" ;;
  esac
done
if [[ "$url" == *127.0.0.1* ]]; then
  echo 404
  exit 0
fi
echo 000
exit 7
EOF
set +e
CASE10="$(
  WORKER_IPS="192.0.2.10" STANDBY_IPS="" MASTER_IP=192.0.2.1 \
    run_wait "$BIN_MIX" 2>&1
)"
CASE10_RC=$?
set -e
echo "$CASE10" | grep -q 'MASTER_TOKEN_API_READY=NO' \
  && echo "$CASE10" | grep -q 'MASTER_IP_8003_READY=NO' \
  && [[ "$CASE10_RC" -ne 0 ]] \
  && pass "CASE10 worker + loopback-only FAIL" \
  || fail "CASE10: rc=${CASE10_RC} ${CASE10}"

set +e
CASE11="$(
  WORKER_IPS="" STANDBY_IPS="192.0.2.20" MASTER_IP=192.0.2.1 \
    run_wait "$BIN_MIX" 2>&1
)"
CASE11_RC=$?
set -e
echo "$CASE11" | grep -q 'MASTER_TOKEN_API_READY=NO' \
  && [[ "$CASE11_RC" -ne 0 ]] \
  && pass "CASE11 standby-only + loopback-only FAIL" \
  || fail "CASE11: rc=${CASE11_RC} ${CASE11}"

BIN_BOTH="${WORKDIR}/bin-both"
mkdir -p "$BIN_BOTH"
write_curl "${BIN_BOTH}/curl" <<'EOF'
#!/usr/bin/env bash
echo 401
exit 0
EOF
set +e
CASE12="$(
  WORKER_IPS="" STANDBY_IPS="192.0.2.20" MASTER_IP=192.0.2.1 \
    MASTER_TOKEN_API_WAIT_SECONDS=5 \
    PATH="${BIN_BOTH}:$PATH"
  log() { echo "$*"; }
  MASTER_TOKEN_API_PORT=8003
  source "${WORKDIR}/wait_8003.sh"
  wait_for_master_token_api 5
  echo RC=$?
)"
set -e
echo "$CASE12" | grep -q 'MASTER_TOKEN_API_READY=YES' \
  && echo "$CASE12" | grep -q 'MASTER_IP_8003_READY=YES' \
  && echo "$CASE12" | grep -q 'RC=0' \
  && pass "CASE12 standby-only MASTER_IP:8003 ready PASS" \
  || fail "CASE12: ${CASE12}"

# ---------------------------------------------------------------------------
# Role mismatch + target Ready identity (CASES 13-18)
# ---------------------------------------------------------------------------
extract_fn "$F1_GEN" orchestrate_workers "${WORKDIR}/orch.sh"

ORCH_BIN="${WORKDIR}/bin-orch"
mkdir -p "$ORCH_BIN"
ROLE_FILE="${WORKDIR}/remote.role"
HOST_FILE="${WORKDIR}/remote.host"
BRINGUP_RC_FILE="${WORKDIR}/bringup.rc"
NODES_FILE="${WORKDIR}/kubectl.nodes"
printf 'DL-worker\n' >"$ROLE_FILE"
printf 'new-worker\n' >"$HOST_FILE"
printf '0\n' >"$BRINGUP_RC_FILE"
: >"$NODES_FILE"

cat >"${ORCH_BIN}/sshpass" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-f" ]]; then
  shift 2
elif [[ "\$1" == "-p" ]]; then
  shift 2
fi
if [[ "\$1" != "ssh" && "\$1" != "scp" ]]; then
  exit 0
fi
if [[ "\$1" == "scp" ]]; then
  exit 0
fi
shift
# skip ssh opts and user@ip; last arg is the remote command
remote="\${@: -1}"
ip=""
for a in "\$@"; do
  case "\$a" in
    aella@*) ip="\${a#aella@}" ;;
  esac
done
case "\$remote" in
  "echo ok") echo ok; exit 0 ;;
  hostname)
    if [[ -f "${WORKDIR}/host.\${ip}" ]]; then
      cat "${WORKDIR}/host.\${ip}"
    else
      cat "$HOST_FILE"
    fi
    exit 0
    ;;
  *aella_role*)
    if [[ -f "${WORKDIR}/role.\${ip}" ]]; then
      cat "${WORKDIR}/role.\${ip}"
    else
      cat "$ROLE_FILE"
    fi
    exit 0
    ;;
  sudo\ bash*)
    rc="\$(cat "$BRINGUP_RC_FILE" 2>/dev/null || echo 0)"
    exit "\$rc"
    ;;
esac
exit 0
EOF
chmod +x "${ORCH_BIN}/sshpass"

cat >"${ORCH_BIN}/kubectl" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "get" && "\$2" == "nodes" ]]; then
  cat "$NODES_FILE"
fi
exit 0
EOF
chmod +x "${ORCH_BIN}/kubectl"

run_orch() {
  local worker_ips="${1:-}"
  local standby_ips="${2:-}"
  PATH="${ORCH_BIN}:$PATH"
  VERSION=6.6.0
  WORKER_IPS="$worker_ips"
  STANDBY_IPS="$standby_ips"
  PHASE2_WORKER_PASSWORD_FILE="${WORKDIR}/orch-worker-password"
  printf '%s' 'orch-secret-not-for-logs' >"$PHASE2_WORKER_PASSWORD_FILE"
  chmod 0600 "$PHASE2_WORKER_PASSWORD_FILE"
  ROLE=DL-master
  WORKER_MODE=false
  SKIP_DOWNLOAD=true
  STAGING_DIR="${WORKDIR}/staging"
  AELLADEB_DIR="${WORKDIR}/aelladeb"
  SCRIPT_PATH="${WORKDIR}/bringup_copy.sh"
  SCRIPT_NAME=bringup_py3_dp_after_os_upgrade.sh
  SSH_OPTS="-o StrictHostKeyChecking=accept-new"
  SCP_OPTS="-o StrictHostKeyChecking=accept-new"
  CLUSTER_TARGET_READY_ATTEMPTS=1
  CLUSTER_TARGET_READY_SLEEP_SECONDS=0
  mkdir -p "$STAGING_DIR" "$AELLADEB_DIR"
  printf '#!/bin/bash\necho fake\n' >"$SCRIPT_PATH"
  die() { echo "FATAL: $*" >&2; exit 1; }
  log() { echo "$*"; }
  log_phase() { echo "PHASE: $*"; }
  copy_phase2_prereq_contract_to_worker() { return 0; }
  # shellcheck disable=SC1090
  source "$CRED_SSH"
  # shellcheck disable=SC1090
  source "$COMPAT"
  copy_phase2_prereq_contract_to_worker() { return 0; }
  # shellcheck disable=SC1090
  source "${WORKDIR}/orch.sh"
  orch_rc=0
  orchestrate_workers || orch_rc=$?
  echo ORCH_RC=$orch_rc
}

# CASE 13: requested worker, actual standby
printf 'standby\n' >"$ROLE_FILE"
printf 'bad-standby\n' >"$HOST_FILE"
printf 'master Ready\n' >"$NODES_FILE"
set +e
CASE13="$(run_orch 192.0.2.10 "" 2>&1)"
set -e
echo "$CASE13" | grep -q 'reason=role_mismatch actual=standby' \
  && echo "$CASE13" | grep -q 'WORKER_ORCHESTRATION=FAIL' \
  && echo "$CASE13" | grep -q 'ORCH_RC=1' \
  && pass "CASE13 worker target with actual standby FAIL" \
  || fail "CASE13: ${CASE13}"

# CASE 14: requested standby, actual normal worker
printf 'DL-worker\n' >"$ROLE_FILE"
printf 'bad-worker\n' >"$HOST_FILE"
set +e
CASE14="$(run_orch "" 192.0.2.20 2>&1)"
set -e
echo "$CASE14" | grep -q 'reason=role_mismatch actual=DL-worker' \
  && echo "$CASE14" | grep -q 'WORKER_ORCHESTRATION=FAIL' \
  && echo "$CASE14" | grep -q 'ORCH_RC=1' \
  && pass "CASE14 standby target with actual worker FAIL" \
  || fail "CASE14: ${CASE14}"

# CASE 15: extra existing Ready nodes + requested new-worker Ready => PASS
printf 'DL-worker\n' >"$ROLE_FILE"
printf 'new-worker\n' >"$HOST_FILE"
printf '0\n' >"$BRINGUP_RC_FILE"
cat >"$NODES_FILE" <<'EOF'
master Ready 1d v1.31.0
old-worker Ready 1d v1.31.0
new-worker Ready 1d v1.31.0
EOF
set +e
CASE15="$(run_orch 192.0.2.10 "" 2>&1)"
set -e
echo "$CASE15" | grep -q 'WORKER_ORCHESTRATION=PASS' \
  && echo "$CASE15" | grep -q 'ORCH_RC=0' \
  && echo "$CASE15" | grep -q 'WORKER_RESULT ip=192.0.2.10' \
  && pass "CASE15 extra Ready nodes + requested target Ready PASS" \
  || fail "CASE15: ${CASE15}"

# CASE 16: extra Ready nodes, requested target NOT Ready => FAIL
cat >"$NODES_FILE" <<'EOF'
master Ready 1d v1.31.0
old-worker Ready 1d v1.31.0
unrelated Ready 1d v1.31.0
EOF
set +e
CASE16="$(run_orch 192.0.2.10 "" 2>&1)"
set -e
echo "$CASE16" | grep -q 'reason=not_ready host=new-worker' \
  && echo "$CASE16" | grep -q 'WORKER_ORCHESTRATION=FAIL' \
  && echo "$CASE16" | grep -q 'ORCH_RC=1' \
  && pass "CASE16 extra Ready cannot hide missing requested target" \
  || fail "CASE16: ${CASE16}"

# CASE 17: worker1 Ready, worker2 not, standby1 Ready => FAIL
printf 'DL-worker\n' >"${WORKDIR}/role.192.0.2.11"
printf 'DL-worker\n' >"${WORKDIR}/role.192.0.2.12"
printf 'standby\n' >"${WORKDIR}/role.192.0.2.20"
printf 'worker1\n' >"${WORKDIR}/host.192.0.2.11"
printf 'worker2\n' >"${WORKDIR}/host.192.0.2.12"
printf 'standby1\n' >"${WORKDIR}/host.192.0.2.20"
cat >"$NODES_FILE" <<'EOF'
master Ready 1d v1.31.0
worker1 Ready 1d v1.31.0
worker2 NotReady 1d v1.31.0
standby1 Ready 1d v1.31.0
EOF
set +e
CASE17="$(run_orch '192.0.2.11,192.0.2.12' '192.0.2.20' 2>&1)"
set -e
echo "$CASE17" | grep -q 'reason=not_ready host=worker2' \
  && echo "$CASE17" | grep -q 'WORKER_ORCHESTRATION=FAIL' \
  && echo "$CASE17" | grep -q 'ORCH_RC=1' \
  && pass "CASE17 mixed Ready with one requested not Ready FAIL" \
  || fail "CASE17: ${CASE17}"

# CASE 18: worker1+worker2+standby1 Ready => PASS
cat >"$NODES_FILE" <<'EOF'
master Ready 1d v1.31.0
worker1 Ready 1d v1.31.0
worker2 Ready 1d v1.31.0
standby1 Ready 1d v1.31.0
EOF
set +e
CASE18="$(run_orch '192.0.2.11,192.0.2.12' '192.0.2.20' 2>&1)"
set -e
echo "$CASE18" | grep -q 'WORKER_ORCHESTRATION=PASS' \
  && echo "$CASE18" | grep -q 'ORCH_RC=0' \
  && echo "$CASE18" | grep -Fq -- '--- Deploying node: 192.0.2.11' \
  && echo "$CASE18" | grep -Fq -- '--- Deploying node: 192.0.2.20 (role: standby)' \
  && pass "CASE18 all requested worker+standby Ready PASS" \
  || fail "CASE18: ${CASE18}"

# Confirm standby is orchestrated after workers in CASE18 output.
awk '
  /Deploying node: 192.0.2.12/ {w=NR}
  /Deploying node: 192.0.2.20 \(role: standby\)/ {s=NR}
  END { exit((w>0 && s>w) ? 0 : 1) }
' <<<"$CASE18" \
  && pass "standby orchestration follows workers" \
  || fail "standby orchestration follows workers"

if echo "$CASE13$CASE14$CASE15$CASE16$CASE17$CASE18" | grep -Fq 'orch-secret-not-for-logs'; then
  fail "password leaked in orchestration output"
else
  pass "orchestration output does not contain password"
fi

# Hostname discovery failure is fail-closed.
rm -f "${WORKDIR}/host.192.0.2.10"
printf 'DL-worker\n' >"$ROLE_FILE"
: >"$HOST_FILE"
cat >"$NODES_FILE" <<'EOF'
master Ready 1d v1.31.0
EOF
set +e
CASE_HN="$(run_orch 192.0.2.10 "" 2>&1)"
set -e
echo "$CASE_HN" | grep -q 'reason=hostname' \
  && echo "$CASE_HN" | grep -q 'WORKER_ORCHESTRATION=FAIL' \
  && pass "hostname discovery failure is fail-closed" \
  || fail "hostname discovery: ${CASE_HN}"

# SSH failure is fail-closed.
cat >"${ORCH_BIN}/sshpass" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${ORCH_BIN}/sshpass"
set +e
CASE_SSH="$(run_orch 192.0.2.10 "" 2>&1)"
set -e
echo "$CASE_SSH" | grep -q 'reason=ssh' \
  && echo "$CASE_SSH" | grep -q 'WORKER_ORCHESTRATION=FAIL' \
  && pass "SSH failure is fail-closed" \
  || fail "SSH failure: ${CASE_SSH}"

# ---------------------------------------------------------------------------
# Lifecycle wrapper: --standby passthrough and orch PASS gate
# ---------------------------------------------------------------------------
set +e
WRAP_OUT="$(
  ATTACH_MONITOR=1
  STATUS_ONLY=0
  DIAGNOSE_ONLY=0
  WORKER_MODE=0
  TARGET_VERSION=""
  WORKER_PASSWORD_FILE=""
  PASSTHRU=()
  PHASE2_BRINGUP_DIR="$WORKDIR/lifecycle"
  PHASE2_WORKER_PASSWORD_PRIVATE_DIR="$WORKDIR/lifecycle"
  DP_PHASE2_BRINGUP_LIB_ONLY=1
  # shellcheck disable=SC1090
  source "$WRAPPER"
  parse_args --version 6.6.0 --standby 192.0.2.20 --worker-password 'wrap-secret' --skip-download
  printf 'TARGET=%s\n' "$TARGET_VERSION"
  printf 'PASSTHRU=%s\n' "${PASSTHRU[*]}"
  printf 'WORKER_PASSWORD_FILE=%s\n' "${WORKER_PASSWORD_FILE:-}"
)"
WRAP_RC=$?
set -e
[[ "$WRAP_RC" -eq 0 ]] \
  && echo "$WRAP_OUT" | grep -q -- '--standby 192.0.2.20' \
  && echo "$WRAP_OUT" | grep -q -- '--worker-password-file' \
  && ! echo "$WRAP_OUT" | grep -q -- '--worker-password wrap-secret' \
  && echo "$WRAP_OUT" | grep -q -- '--skip-download' \
  && pass "lifecycle wrapper keeps --standby with its value" \
  || fail "lifecycle wrapper standby passthrough: ${WRAP_OUT}"
if echo "$WRAP_OUT" | grep -Fq 'wrap-secret'; then
  # PASSTHRU dump in the test includes the value; that is the test harness.
  :
fi
set +e
WRAP_BAD="$(
  ATTACH_MONITOR=1
  STATUS_ONLY=0
  DIAGNOSE_ONLY=0
  WORKER_MODE=0
  TARGET_VERSION=""
  PASSTHRU=()
  DP_PHASE2_BRINGUP_LIB_ONLY=1
  source "$WRAPPER"
  parse_args --version 6.6.0 --standby --detach 2>&1
)"
WRAP_BAD_RC=$?
set -e
[[ "$WRAP_BAD_RC" -ne 0 ]] \
  && echo "$WRAP_BAD" | grep -q -- '--standby requires a value' \
  && pass "lifecycle wrapper rejects --standby without a value" \
  || fail "lifecycle wrapper --standby missing value: rc=${WRAP_BAD_RC} ${WRAP_BAD}"

# Lifecycle: extra Ready count must not fail when orch PASS is present.
# shellcheck source=/dev/null
source "$LIFECYCLE"
p2b_dir() { printf '%s\n' "${WORKDIR}/life"; }
export PHASE2_BRINGUP_DIR="${WORKDIR}/life"
export PHASE2_BRINGUP_LOG_DEFAULT="${WORKDIR}/life.log"
p2b_ensure_dir
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file() { printf '%s\n' "$2" >"$1"; }
write_file "$(p2b_dir)/run-id" "run-extra"
write_file "$(p2b_dir)/target-version" "6.6.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VENDOR_EXTRA="${WORKDIR}/vendor-extra.sh"
cat >"$VENDOR_EXTRA" <<'EOF'
#!/usr/bin/env bash
echo "CLUSTER_JOIN_STATE ready=3 requested=1 diagnostic=YES"
echo "WORKER_ORCHESTRATION=PASS"
exit 0
EOF
chmod +x "$VENDOR_EXTRA"
set +e
( p2b_worker_main "$VENDOR_EXTRA" --worker-ips 192.0.2.10 >/dev/null 2>&1 )
LIFE_EXTRA_RC=$?
set -e
[[ "$LIFE_EXTRA_RC" -eq 0 ]] \
  && [[ "$(p2b_read_state)" == "COMPLETED" ]] \
  && pass "lifecycle extra Ready + orch PASS is PASS" \
  || fail "lifecycle extra Ready: rc=${LIFE_EXTRA_RC} state=$(p2b_read_state)"

p2b_ensure_dir
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-standby"
write_file "$(p2b_dir)/target-version" "6.6.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rm -f "$(p2b_dir)/result.env" "$(p2b_dir)/completion.sentinel" "$(p2b_dir)/state"
VENDOR_SB="${WORKDIR}/vendor-standby.sh"
cat >"$VENDOR_SB" <<'EOF'
#!/usr/bin/env bash
echo "Bringup complete: done"
exit 0
EOF
chmod +x "$VENDOR_SB"
set +e
( p2b_worker_main "$VENDOR_SB" --standby 192.0.2.20 >/dev/null 2>&1 )
LIFE_SB_RC=$?
set -e
[[ "$LIFE_SB_RC" -ne 0 ]] \
  && grep -q 'FAILURE_REASON=WORKER_ORCHESTRATION' "$(p2b_dir)/completion.sentinel" \
  && pass "lifecycle standby-only without orch PASS is FAIL" \
  || fail "lifecycle standby-only missing orch PASS: rc=${LIFE_SB_RC}"

echo "SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
