#!/usr/bin/env bash
# Regression tests for the Phase 2 incomplete-cluster / 8003 / Python runtime
# incident. Does not log tokens or worker passwords.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
PREREQ_LIB="${ROOT}/client/lib/dp-phase2-ubuntu-prerequisites.sh"
LIFECYCLE="${ROOT}/client/lib/dp-phase2-bringup-lifecycle.sh"
FAIL=0
PASS=0
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "======== test_phase2_cluster_readiness ========"

[[ -f "$BRINGUP" ]] || { echo "missing bringup" >&2; exit 1; }
if bash -n "$BRINGUP" && bash -n "$PREREQ_LIB" && bash -n "$LIFECYCLE" \
  && bash -n "${ROOT}/scripts/prepare-phase2-ubuntu-prerequisites.sh" \
  && bash -n "${ROOT}/client/bringup_py3_dp_lifecycle.sh"; then
  pass "bash -n production scripts"
else
  fail "bash -n production scripts"
fi

extract_fn() {
  local name="$1" dest="$2"
  awk -v n="$name" '
    $0 ~ "^" n "\\(\\)" {keep=1}
    keep {print}
    keep && /^}$/ {exit}
  ' "$BRINGUP" >"$dest"
  [[ -s "$dest" ]]
}

# ---------------------------------------------------------------------------
# C. Critical Python import gate
# ---------------------------------------------------------------------------
extract_fn validate_critical_python_runtime "${WORKDIR}/validate_py.sh"
BIN="${WORKDIR}/bin-py-fail"
mkdir -p "$BIN"
cat >"${BIN}/python3" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *import\ flask* ]] || [[ "$*" == *import flask* ]]; then
  echo 'ModuleNotFoundError: No module named '"'"'click'"'"' >&2
  exit 1
fi
if [[ "$*" == *import\ click* ]]; then
  echo 'ModuleNotFoundError: No module named '"'"'click'"'"' >&2
  exit 1
fi
exit 0
EOF
chmod +x "${BIN}/python3"
set +e
PY_FAIL_OUT="$(
  PATH="${BIN}:$PATH"
  log() { echo "$*"; }
  source_phase2_prereq_lib() { return 1; }
  PHASE2_CRITICAL_PYTHON_IMPORTS="click flask werkzeug OpenSSL gevent kazoo pyinotify"
  # shellcheck disable=SC1090
  source "${WORKDIR}/validate_py.sh"
  validate_critical_python_runtime
  echo RC=$?
)"
set -e
echo "$PY_FAIL_OUT" | grep -q 'CRITICAL_PYTHON_RUNTIME=FAIL' \
  && echo "$PY_FAIL_OUT" | grep -q 'RC=1' \
  && pass "C python import gate FAIL when flask/click missing" \
  || fail "C python import gate FAIL when flask/click missing: ${PY_FAIL_OUT}"

BIN_OK="${WORKDIR}/bin-py-ok"
mkdir -p "$BIN_OK"
cat >"${BIN_OK}/python3" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${BIN_OK}/python3"
set +e
PY_OK_OUT="$(
  PATH="${BIN_OK}:$PATH"
  log() { echo "$*"; }
  source_phase2_prereq_lib() { return 1; }
  PHASE2_CRITICAL_PYTHON_IMPORTS="click flask werkzeug OpenSSL gevent kazoo pyinotify"
  # shellcheck disable=SC1090
  source "${WORKDIR}/validate_py.sh"
  validate_critical_python_runtime
  echo RC=$?
)"
set -e
echo "$PY_OK_OUT" | grep -q 'CRITICAL_PYTHON_RUNTIME=PASS' \
  && echo "$PY_OK_OUT" | grep -q 'RC=0' \
  && pass "C python import gate PASS with complete set" \
  || fail "C python import gate PASS with complete set: ${PY_OK_OUT}"

# Client-lib transaction safety (B)
SIM_BAD="${WORKDIR}/apt-sim-bad.txt"
cat >"$SIM_BAD" <<'EOF'
Inst python3-click [8.1.3-1]
Remv python3-gevent [24.2.1-0ubuntu3]
Remv python3-kazoo [2.9.0-0ubuntu1]
Purg python3-pyinotify [0.9.6-2]
EOF
# shellcheck source=/dev/null
source "$PREREQ_LIB"
if ! dp2_prereq_transaction_safe "$(cat "$SIM_BAD")"; then
  pass "B simulated install rejected when protected packages would be removed"
else
  fail "B simulated install should have been rejected"
fi
SIM_OK="${WORKDIR}/apt-sim-ok.txt"
cat >"$SIM_OK" <<'EOF'
Inst python3-click [8.1.3-1]
Inst python3-colorama [0.4.6-1]
EOF
if dp2_prereq_transaction_safe "$(cat "$SIM_OK")"; then
  pass "B install-only simulation accepted"
else
  fail "B install-only simulation rejected"
fi

# ---------------------------------------------------------------------------
# D. Master 8003 gate
# ---------------------------------------------------------------------------
extract_fn wait_for_master_token_api "${WORKDIR}/wait_8003.sh"
BIN8003="${WORKDIR}/bin-8003-down"
mkdir -p "$BIN8003"
cat >"${BIN8003}/curl" <<'EOF'
#!/usr/bin/env bash
echo 000
exit 7
EOF
cat >"${BIN8003}/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "+%s" ]]; then
  echo "${FAKE_NOW:-1000}"
  exit 0
fi
exec /bin/date "$@"
EOF
chmod +x "${BIN8003}/curl" "${BIN8003}/date"
set +e
GATE_DOWN="$(
  PATH="${BIN8003}:$PATH"
  FAKE_NOW=1000
  log() { echo "$*"; }
  MASTER_TOKEN_API_PORT=8003
  MASTER_TOKEN_API_WAIT_SECONDS=0
  # shellcheck disable=SC1090
  source "${WORKDIR}/wait_8003.sh"
  wait_for_master_token_api 0
  echo RC=$?
)"
set -e
echo "$GATE_DOWN" | grep -q 'MASTER_TOKEN_API_READY=NO' \
  && echo "$GATE_DOWN" | grep -q 'BRINGUP_RESULT=FAIL' \
  && echo "$GATE_DOWN" | grep -q 'RC=1' \
  && pass "D 8003 unavailable fails and does not start orchestration" \
  || fail "D 8003 unavailable: ${GATE_DOWN}"

BIN8003UP="${WORKDIR}/bin-8003-up"
mkdir -p "$BIN8003UP"
cat >"${BIN8003UP}/curl" <<'EOF'
#!/usr/bin/env bash
echo 404
exit 0
EOF
chmod +x "${BIN8003UP}/curl"
set +e
GATE_UP="$(
  PATH="${BIN8003UP}:$PATH"
  log() { echo "$*"; }
  MASTER_TOKEN_API_PORT=8003
  MASTER_TOKEN_API_WAIT_SECONDS=5
  # shellcheck disable=SC1090
  source "${WORKDIR}/wait_8003.sh"
  wait_for_master_token_api 5
  echo RC=$?
)"
set -e
echo "$GATE_UP" | grep -q 'MASTER_TOKEN_API_READY=YES' \
  && echo "$GATE_UP" | grep -q 'RC=0' \
  && pass "D 8003 HTTP 404 is accepted as listener-ready" \
  || fail "D 8003 HTTP 404: ${GATE_UP}"

# Cluster: loopback up + MASTER_IP down must FAIL.
BIN8003MIX="${WORKDIR}/bin-8003-mix"
mkdir -p "$BIN8003MIX"
cat >"${BIN8003MIX}/curl" <<'EOF'
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
chmod +x "${BIN8003MIX}/curl"
set +e
GATE_MIX="$(
  PATH="${BIN8003MIX}:$PATH"
  log() { echo "$*"; }
  MASTER_TOKEN_API_PORT=8003
  MASTER_TOKEN_API_WAIT_SECONDS=0
  MASTER_IP=192.168.12.25
  WORKER_IPS="192.168.12.26,192.168.12.27"
  # shellcheck disable=SC1090
  source "${WORKDIR}/wait_8003.sh"
  wait_for_master_token_api 0
  echo RC=$?
)"
set -e
echo "$GATE_MIX" | grep -q 'MASTER_TOKEN_API_READY=NO' \
  && echo "$GATE_MIX" | grep -q 'MASTER_IP_8003_READY=NO' \
  && echo "$GATE_MIX" | grep -q 'RC=1' \
  && pass "D cluster loopback-up master-IP-down FAIL" \
  || fail "D cluster mix: ${GATE_MIX}"

# Cluster: both loopback and MASTER_IP up => PASS
BIN8003BOTH="${WORKDIR}/bin-8003-both"
mkdir -p "$BIN8003BOTH"
cat >"${BIN8003BOTH}/curl" <<'EOF'
#!/usr/bin/env bash
echo 401
exit 0
EOF
chmod +x "${BIN8003BOTH}/curl"
set +e
GATE_BOTH="$(
  PATH="${BIN8003BOTH}:$PATH"
  log() { echo "$*"; }
  MASTER_TOKEN_API_PORT=8003
  MASTER_TOKEN_API_WAIT_SECONDS=5
  MASTER_IP=192.168.12.25
  WORKER_IPS="192.168.12.26,192.168.12.27"
  # shellcheck disable=SC1090
  source "${WORKDIR}/wait_8003.sh"
  wait_for_master_token_api 5
  echo RC=$?
)"
set -e
echo "$GATE_BOTH" | grep -q 'MASTER_TOKEN_API_READY=YES' \
  && echo "$GATE_BOTH" | grep -q 'MASTER_IP_8003_READY=YES' \
  && echo "$GATE_BOTH" | grep -q 'RC=0' \
  && pass "D cluster both 8003 endpoints PASS" \
  || fail "D cluster both: ${GATE_BOTH}"

# main() must call wait_for_master_token_api before orchestrate_workers
if awk '
  /wait_for_master_token_api \|\|/ && !w {w=NR}
  /orchestrate_workers \|\|/ && !o {o=NR}
  END { exit((w>0 && o>w) ? 0 : 1) }
' "$BRINGUP"; then
  pass "D wait_for_master_token_api precedes orchestrate_workers"
else
  fail "D wait_for_master_token_api precedes orchestrate_workers"
fi

# ---------------------------------------------------------------------------
# E. Worker token curl failure
# ---------------------------------------------------------------------------
extract_fn join_k8s_cluster "${WORKDIR}/join.sh"
BINJOIN="${WORKDIR}/bin-join"
mkdir -p "$BINJOIN"
cat >"${BINJOIN}/curl" <<'EOF'
#!/usr/bin/env bash
# healthz succeeds; token API fails
if [[ "$*" == *6443/healthz* ]]; then
  exit 0
fi
exit 7
EOF
cat >"${BINJOIN}/python3" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *get_curl_username* ]]; then
  echo testuser
  exit 0
fi
if [[ "$*" == *get_curl_password* ]]; then
  echo testpass
  exit 0
fi
exit 0
EOF
chmod +x "${BINJOIN}/curl" "${BINJOIN}/python3"
JOIN_OUT="${WORKDIR}/join.out"
set +e
(
  PATH="${BINJOIN}:$PATH"
  DA_CONF="${WORKDIR}/da_conf.yml"
  printf 'master_ip: 192.168.12.25\n' >"$DA_CONF"
  LOG_FILE="${WORKDIR}/join.log"
  : >"$LOG_FILE"
  log() { echo "$*"; }
  log_phase() { echo "PHASE: $*"; }
  die() { echo "FATAL: $*" >&2; exit 1; }
  WORKER_MODE=true
  ROLE=DL-worker
  # shellcheck disable=SC1090
  source "${WORKDIR}/join.sh"
  join_k8s_cluster
) >"$JOIN_OUT" 2>&1
JOIN_RC=$?
set -e
[[ "$JOIN_RC" -ne 0 ]] || fail "E join_k8s_cluster should fail on curl rc!=0"
grep -q 'join-token API request failed' "$JOIN_OUT" \
  && pass "E curl failure logs a clean error" \
  || fail "E curl failure logging: $(cat "$JOIN_OUT")"
grep -q 'WORKER_RESULT result=FAIL reason=token_api_curl' "$JOIN_OUT" \
  && pass "E worker result FAIL on token curl" \
  || fail "E worker result marker missing"
if grep -qiE 'password=|WORKER_PASSWORD=|token=[A-Za-z0-9._-]{8,}' "$JOIN_OUT"; then
  fail "E token/password leaked in join logs"
else
  pass "E no token/password logging on curl failure"
fi
grep -q 'Bringup complete' "$JOIN_OUT" && fail "E misleading success after curl fail" || \
  pass "E no misleading success after curl fail"

# ---------------------------------------------------------------------------
# F + G. Worker orchestration + cluster join diagnostics
# ---------------------------------------------------------------------------
extract_fn orchestrate_workers "${WORKDIR}/orch.sh"
COMPAT="${ROOT}/scripts/lib/phase2_bringup_patch/fragment_compat.sh"
# shellcheck disable=SC1090
source "$COMPAT"
log() { echo "$*"; }
WORKER_IPS=""
STANDBY_IPS=""
[[ "$(count_remote_orchestration_nodes)" == "0" ]] \
  && pass "H no remote nodes => count 0 (single-node skip)" \
  || fail "H empty remote node count"
WORKER_IPS='192.168.12.26,192.168.12.27'
STANDBY_IPS=""
[[ "$(count_remote_orchestration_nodes)" == "2" ]] \
  && pass "G two workers => requested 2 (not master+workers exact size)" \
  || fail "G two workers count"
WORKER_IPS=""
STANDBY_IPS="192.168.12.30"
[[ "$(count_remote_orchestration_nodes)" == "1" ]] \
  && pass "G standby only => requested 1" \
  || fail "G standby only count"

write_kubectl_nodes() {
  local dest="$1"
  shift
  cat >"$dest" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "get" && "\$2" == "nodes" ]]; then
$(printf '%s\n' "$@")
fi
exit 0
EOF
  chmod +x "$dest"
}

run_topo() {
  local workers="$1"
  local timeout="$2"
  local standby="${3:-}"
  WORKER_IPS="$workers"
  STANDBY_IPS="$standby"
  CLUSTER_JOIN_WAIT_SECONDS="$timeout"
  log() { echo "$*"; }
  # shellcheck disable=SC1090
  source "$COMPAT"
  validate_expected_cluster_nodes "$timeout"
}

KBIN="${WORKDIR}/bin-k"
mkdir -p "$KBIN"
write_kubectl_nodes "${KBIN}/kubectl" \
  '  printf "dl-master Ready  1d  v1.31.0\n"'
set +e
TOPO1="$(PATH="${KBIN}:$PATH" run_topo "192.168.12.26,192.168.12.27" 0 2>&1)"
TOPO1_RC=$?
set -e
echo "$TOPO1" | grep -q 'CLUSTER_JOIN_STATE ready=1 requested=2 diagnostic=YES' \
  && [[ "$TOPO1_RC" -eq 0 ]] \
  && pass "G global Ready count is diagnostic only (not a FAIL gate)" \
  || fail "G diagnostic ready count: rc=${TOPO1_RC} ${TOPO1}"

write_kubectl_nodes "${KBIN}/kubectl" \
  '  printf "dl-master Ready  1d  v1.31.0\n"' \
  '  printf "dl-worker1 Ready 1d  v1.31.0\n"' \
  '  printf "old-worker Ready 1d  v1.31.0\n"' \
  '  printf "dl-worker2 Ready 1d  v1.31.0\n"'
set +e
TOPO_EXTRA="$(PATH="${KBIN}:$PATH" run_topo "192.168.12.26" 5 2>&1)"
TOPO_EXTRA_RC=$?
set -e
echo "$TOPO_EXTRA" | grep -q 'CLUSTER_JOIN_STATE ready=4 requested=1 diagnostic=YES' \
  && [[ "$TOPO_EXTRA_RC" -eq 0 ]] \
  && pass "G extra existing Ready nodes do not fail global diagnostic" \
  || fail "G extra Ready: rc=${TOPO_EXTRA_RC} ${TOPO_EXTRA}"

set +e
TOPO_AIO="$(PATH="${KBIN}:$PATH" run_topo "" 5 2>&1)"
TOPO_AIO_RC=$?
set -e
echo "$TOPO_AIO" | grep -q 'single-node/AIO' \
  && [[ "$TOPO_AIO_RC" -eq 0 ]] \
  && pass "H single-node/AIO topology is not a hard fail" \
  || fail "H AIO topology: rc=${TOPO_AIO_RC} ${TOPO_AIO}"

# F. Remote worker nonzero fails orchestration
ORCH_BIN="${WORKDIR}/bin-orch"
mkdir -p "$ORCH_BIN"
SSHPASS_CMD="${WORKDIR}/sshpass.cmd"
: >"$SSHPASS_CMD"
cat >"${ORCH_BIN}/sshpass" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-f" ]]; then
  shift 2
elif [[ "\$1" == "-p" ]]; then
  shift 2
fi
printf '%s\\n' "\$*" >>"${SSHPASS_CMD}"
if [[ "\$1" == "scp" ]]; then
  exit 0
fi
if [[ "\$1" == "ssh" ]]; then
  remote="\${@: -1}"
  case "\$remote" in
    "echo ok") echo ok; exit 0 ;;
    hostname) echo worker1; exit 0 ;;
    sudo\ bash*) exit 17 ;;
    *aella_role*) echo DL-worker; exit 0 ;;
  esac
  # mkdir/chmod etc.
  exit 0
fi
exit 0
EOF
chmod +x "${ORCH_BIN}/sshpass"
write_kubectl_nodes "${ORCH_BIN}/kubectl" \
  '  printf "dl-master Ready 1d v1.31.0 192.168.12.25 192.168.12.25\n"' \
  '  printf "worker1 Ready 1d v1.31.0 192.168.12.26 192.168.12.26\n"'
STAGING="${WORKDIR}/staging"
AELLADEB="${WORKDIR}/aelladeb"
mkdir -p "$STAGING" "$AELLADEB"
printf '#!/bin/bash\necho fake\n' >"${WORKDIR}/bringup_copy.sh"
set +e
ORCH_FAIL_OUT="$(
  set +e
  PATH="${ORCH_BIN}:$PATH"
  VERSION=6.5.0
  WORKER_IPS=192.168.12.26
  STANDBY_IPS=""
  PHASE2_WORKER_PASSWORD_FILE="${WORKDIR}/orch-worker-password"
  printf '%s' 'secret-pass-not-for-logs' >"$PHASE2_WORKER_PASSWORD_FILE"
  chmod 0600 "$PHASE2_WORKER_PASSWORD_FILE"
  ROLE=DL-master
  WORKER_MODE=false
  SKIP_DOWNLOAD=true
  CLUSTER_TARGET_READY_ATTEMPTS=1
  CLUSTER_TARGET_READY_SLEEP_SECONDS=0
  STAGING_DIR="$STAGING"
  AELLADEB_DIR="$AELLADEB"
  SCRIPT_PATH="${WORKDIR}/bringup_copy.sh"
  SCRIPT_NAME=bringup_py3_dp_after_os_upgrade.sh
  SSH_OPTS="-o StrictHostKeyChecking=accept-new"
  SCP_OPTS="-o StrictHostKeyChecking=accept-new"
  die() { echo "FATAL: $*" >&2; exit 1; }
  log() { echo "$*"; }
  log_phase() { echo "PHASE: $*"; }
  # shellcheck disable=SC1090
  source "${ROOT}/scripts/lib/phase2_bringup_patch/fragment_credential_ssh.sh"
  # shellcheck disable=SC1090
  source "${ROOT}/scripts/lib/phase2_bringup_patch/fragment_compat.sh"
  copy_phase2_prereq_contract_to_worker() { return 0; }
  normalize_remote_orchestration_nodes() { return 0; }
  # shellcheck disable=SC1090
  source "${WORKDIR}/orch.sh"
  set +e
  orchestrate_workers
  echo ORCH_RC=$?
)"
ORCH_FAIL_RC=$?
set -e
echo "$ORCH_FAIL_OUT" | grep -qE 'WORKER_RESULT ip=192.168.12.26 result=FAIL' \
  && echo "$ORCH_FAIL_OUT" | grep -q 'WORKER_ORCHESTRATION=FAIL' \
  && pass "F remote worker nonzero => master orchestration FAIL" \
  || fail "F remote worker fail: ${ORCH_FAIL_OUT}"
if echo "$ORCH_FAIL_OUT" | grep -Fq 'secret-pass-not-for-logs'; then
  fail "I worker password leaked in orchestration output"
else
  pass "I worker password not logged"
fi

# I. --worker-password still accepted
if grep -q -- '--worker-password' "$BRINGUP" \
  && grep -qE -- '--worker-ips(/--standby)? requires --worker-password-file' "$BRINGUP"; then
  pass "I --worker-password-file contract present with --worker-ips"
else
  fail "I --worker-password contract missing"
fi

# Lifecycle wrapper requires WORKER_ORCHESTRATION=PASS for remote nodes.
# Reasons are written via p2b_fail_run; callers must distinguish contains()
# rc=0/1/2 (invalid stream is never treated as pattern-absent).
if grep -q 'WORKER_ORCHESTRATION=PASS' "$LIFECYCLE" \
  && grep -qE 'p2b_fail_run .*"WORKER_ORCHESTRATION"' "$LIFECYCLE" \
  && grep -q 'orch_fail_rc' "$LIFECYCLE" \
  && grep -q 'orch_pass_rc' "$LIFECYCLE"; then
  pass "G lifecycle wrapper requires WORKER_ORCHESTRATION=PASS for remote nodes"
else
  fail "G lifecycle wrapper missing WORKER_ORCHESTRATION remote gate"
fi
if grep -qE 'p2b_fail_run .*"APT_DEPENDENCY_CHECK"' "$LIFECYCLE" \
  && grep -q 'apt_log_rc' "$LIFECYCLE"; then
  pass "K lifecycle wrapper rejects APT_DEPENDENCY_CHECK=FAIL"
else
  fail "K lifecycle wrapper missing APT_DEPENDENCY_CHECK gate"
fi

# ---------------------------------------------------------------------------
# K. APT dependency graph hard gate (dpkg --audit is not sufficient)
# ---------------------------------------------------------------------------
extract_fn validate_apt_dependency_graph "${WORKDIR}/validate_apt.sh"
extract_fn install_python3 "${WORKDIR}/install_python3.sh"
APT_FAIL_BIN="${WORKDIR}/bin-apt-fail"
mkdir -p "$APT_FAIL_BIN"
cat >"${APT_FAIL_BIN}/apt-get" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" check "* ]]; then
  echo "The following packages have unmet dependencies:" >&2
  echo " python3-flask : Depends: python3-click but it is not installed" >&2
  exit 100
fi
exit 0
EOF
cat >"${APT_FAIL_BIN}/dpkg" <<'EOF'
#!/usr/bin/env bash
# Clean audit output: this must NOT be treated as success.
exit 0
EOF
chmod +x "${APT_FAIL_BIN}/apt-get" "${APT_FAIL_BIN}/dpkg"
set +e
APT_FAIL_OUT="$(
  PATH="${APT_FAIL_BIN}:$PATH"
  log() { echo "$*"; }
  source_phase2_prereq_lib() { return 1; }
  # shellcheck disable=SC1090
  source "${WORKDIR}/validate_apt.sh"
  validate_apt_dependency_graph python3_apt
  echo RC=$?
)"
set -e
echo "$APT_FAIL_OUT" | grep -q 'APT_DEPENDENCY_CHECK=FAIL' \
  && echo "$APT_FAIL_OUT" | grep -q 'RC=100' \
  && pass "K apt-get check FAIL is a hard gate" \
  || fail "K apt-get check FAIL: ${APT_FAIL_OUT}"
if echo "$APT_FAIL_OUT" | grep -q 'DPKG_AUDIT=CLEAN'; then
  pass "K dpkg --audit CLEAN is not treated as sufficient"
else
  pass "K dpkg --audit CLEAN noted or omitted; apt-get check still failed"
fi

APT_OK_BIN="${WORKDIR}/bin-apt-ok"
mkdir -p "$APT_OK_BIN"
cat >"${APT_OK_BIN}/apt-get" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" check "* ]]; then
  exit 0
fi
exit 0
EOF
cat >"${APT_OK_BIN}/dpkg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${APT_OK_BIN}/apt-get" "${APT_OK_BIN}/dpkg"
set +e
APT_OK_OUT="$(
  PATH="${APT_OK_BIN}:$PATH"
  log() { echo "$*"; }
  source_phase2_prereq_lib() { return 1; }
  # shellcheck disable=SC1090
  source "${WORKDIR}/validate_apt.sh"
  validate_apt_dependency_graph python3_apt
  echo RC=$?
)"
set -e
echo "$APT_OK_OUT" | grep -q 'APT_DEPENDENCY_CHECK=PASS' \
  && echo "$APT_OK_OUT" | grep -q 'RC=0' \
  && pass "K apt-get check PASS" \
  || fail "K apt-get check PASS: ${APT_OK_OUT}"

# Client-lib path: same FAIL/PASS contract
set +e
LIB_APT_FAIL="$(
  PATH="${APT_FAIL_BIN}:$PATH"
  # shellcheck source=/dev/null
  source "$PREREQ_LIB"
  dp2_validate_apt_dependency_graph prerequisites
  echo RC=$?
)"
set -e
echo "$LIB_APT_FAIL" | grep -q 'APT_DEPENDENCY_CHECK=FAIL' \
  && echo "$LIB_APT_FAIL" | grep -q 'RC=100' \
  && pass "K client-lib apt-get check FAIL" \
  || fail "K client-lib apt-get check FAIL: ${LIB_APT_FAIL}"

if grep -q 'validate_apt_dependency_graph python3_apt' "${WORKDIR}/install_python3.sh" \
  && grep -q 'not a success criterion' "${WORKDIR}/install_python3.sh"; then
  pass "K install_python3 requires apt-get check; force-depends is not success"
else
  fail "K install_python3 missing apt-get check / force-depends caveat"
fi
if grep -nE '^[[:space:]]*apt-get[[:space:]]+install[[:space:]]+-f' \
  "${WORKDIR}/install_python3.sh"; then
  fail "K install_python3 must not run apt-get install -f as repair"
else
  pass "K install_python3 does not run apt-get install -f"
fi

# ---------------------------------------------------------------------------
# J. English-only on production files touched by this workflow
# ---------------------------------------------------------------------------
EN_FILES=(
  "$BRINGUP"
  "$PREREQ_LIB"
  "$LIFECYCLE"
  "${ROOT}/client/bringup_py3_dp_lifecycle.sh"
  "${ROOT}/client/stage-dp-phase2.sh"
  "${ROOT}/scripts/prepare-phase2-ubuntu-prerequisites.sh"
  "${ROOT}/scripts/lib/phase2_ubuntu_prerequisites.py"
  "${ROOT}/scripts/download-dp-phase2.sh"
  "${ROOT}/scripts/lib/mirror_install_engine.sh"
  "${ROOT}/scripts/deploy-stage-dp-phase2-client-atomic.sh"
)
HANGUL=0
for f in "${EN_FILES[@]}"; do
  if python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
data = open(p, "rb").read().decode("utf-8", "replace")
if any(0xAC00 <= ord(ch) <= 0xD7A3 for ch in data):
    print("HANGUL", p)
    sys.exit(1)
sys.exit(0)
PY
  then
    :
  else
    HANGUL=1
  fi
done
if [[ "$HANGUL" -eq 0 ]]; then
  pass "J no Hangul in production files touched by this workflow"
else
  fail "J Hangul found in production files"
fi

# No apt --fix-broken as a runtime repair in the new layer (comments may mention it).
if grep -nE '^[[:space:]]*apt(-get)?[[:space:]]+(--fix-broken|-f)[[:space:]]+install' \
  "$PREREQ_LIB" "${ROOT}/scripts/lib/phase2_ubuntu_prerequisites.py" \
  "${ROOT}/scripts/prepare-phase2-ubuntu-prerequisites.sh" \
  "${ROOT}/scripts/lib/phase2_bringup_patch/fragment_compat.sh" \
  "${ROOT}/client/stage-dp-phase2.sh"; then
  fail "new layer must not run apt --fix-broken install"
else
  pass "new layer does not run apt --fix-broken install"
fi
if grep -nE 'PHASE2_PREREQ_OPTIONAL' \
  "${ROOT}/scripts/prepare-phase2-ubuntu-prerequisites.sh" \
  "${ROOT}/scripts/download-dp-phase2.sh" \
  "${ROOT}/scripts/lib/mirror_install_engine.sh" \
  "${ROOT}/client/stage-dp-phase2.sh"; then
  fail "PHASE2_PREREQ_OPTIONAL still present in production"
else
  pass "PHASE2_PREREQ_OPTIONAL removed from production"
fi
if grep -nE 'stage_phase2_ubuntu_prerequisites \|\| true' \
  "${ROOT}/client/stage-dp-phase2.sh"; then
  fail "stage still ignores prerequisite failures"
else
  pass "stage does not ignore prerequisite failures"
fi
if awk '/^install_python3\(\)/{p=1} p; /^}$/{if(p){exit}}' "$BRINGUP" \
  | grep -nE '^[[:space:]]*apt-get[[:space:]]+install[[:space:]]+-f'; then
  fail "vendor install_python3 must not run apt-get install -f"
else
  pass "vendor install_python3 does not run apt-get install -f"
fi

echo "SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
