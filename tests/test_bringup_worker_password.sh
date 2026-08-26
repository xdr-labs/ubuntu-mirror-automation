#!/usr/bin/env bash
# --worker-password parsing and worker-orchestration credential use.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== test_bringup_worker_password ==="

[[ -f "$BRINGUP" ]] || { echo "missing bringup: $BRINGUP" >&2; exit 1; }

if bash -n "$BRINGUP"; then
  pass "bash -n bringup"
else
  fail "bash -n bringup"
fi

grep -n 'WORKER_PASS="aelladata"' "$BRINGUP" \
  && fail "hardcoded WORKER_PASS=aelladata still present" \
  || pass "no hardcoded WORKER_PASS=aelladata"

grep -q -- '--worker-password' "$BRINGUP" \
  || fail "--worker-password not in bringup"
grep -q 'WORKER_IPS requires --worker-password\|--worker-ips requires --worker-password\|--worker-ips/--standby requires --worker-password' "$BRINGUP" \
  || fail "missing --worker-ips/--worker-password validation"

# Extract parse_args + orchestrate_workers with local stubs.
PARSE_SRC="${WORKDIR}/parse_args.sh"
awk '
  /^parse_args\(\)/ {keep=1}
  keep {print}
  keep && /^}$/ {exit}
' "$BRINGUP" >"$PARSE_SRC"
[[ -s "$PARSE_SRC" ]] || { echo "failed to extract parse_args" >&2; exit 1; }

ORCH_SRC="${WORKDIR}/orchestrate.sh"
awk '
  /^orchestrate_workers\(\)/ {keep=1}
  keep {print}
  keep && /^}$/ {exit}
' "$BRINGUP" >"$ORCH_SRC"
[[ -s "$ORCH_SRC" ]] || { echo "failed to extract orchestrate_workers" >&2; exit 1; }

run_parse() {
  local out rc err
  err="${WORKDIR}/parse.err"
  : >"$err"
  set +e
  out="$(
    exec 2>"$err"
    VERSION=""
    WORKER_IPS=""
    WORKER_PASSWORD=""
    STANDBY_IPS=""
    ROLE=""
    DRY_RUN=false
    SKIP_DOWNLOAD=false
    WORKER_MODE=false
    PRE_UPGRADE_CLEANUP=false
    AUTO_OS_UPGRADE=false
    RECLAIM_OVERLAY2_ONLY=false
    WORKER_SSH_KEY=""
    die() { echo "FATAL: $*" >&2; exit 1; }
    log() { :; }
    check_version_guard() { return 0; }
    # shellcheck disable=SC1090
    source "$PARSE_SRC"
    parse_args "$@"
    printf 'VERSION=%s\n' "$VERSION"
    printf 'WORKER_IPS=%s\n' "$WORKER_IPS"
    printf 'WORKER_PASSWORD=%s\n' "$WORKER_PASSWORD"
  )"
  rc=$?
  PARSE_RC="$rc"
  PARSE_OUT="$out"
  PARSE_ERR="$(cat "$err")"
  set -e
  return 0
}

# AIO / no workers: password not required
run_parse --version 6.6.0 --skip-download
if [[ "$PARSE_RC" -eq 0 ]]; then
  echo "$PARSE_OUT" | grep -qx 'WORKER_IPS=' || fail "unexpected worker ips on AIO"
  echo "$PARSE_OUT" | grep -qx 'WORKER_PASSWORD=' || fail "unexpected worker password on AIO"
  pass "AIO parse does not require --worker-password"
else
  fail "AIO parse failed: ${PARSE_ERR}"
fi

run_parse --version 6.6.0
if [[ "$PARSE_RC" -eq 0 ]]; then
  pass "bringup --version 6.6.0 still parses"
else
  fail "bringup --version 6.6.0 parse failed: ${PARSE_ERR}"
fi

# worker-ips without password → error
run_parse --version 6.6.0 --skip-download --worker-ips "192.168.124.23,192.168.124.25"
[[ "$PARSE_RC" -ne 0 ]] || fail "worker-ips without password accepted"
echo "$PARSE_ERR" | grep -q -- '--worker-ips/--standby requires --worker-password\|--worker-ips requires --worker-password' \
  || fail "missing validation error: ${PARSE_ERR}"
pass "worker-ips without password is rejected"

# worker-password parsed (including special characters)
for spec_pass in 'something' 'Test123!' 'Abc$123!' 'worker@Pass#2026' 'A&b!c$123'; do
  run_parse --version 6.6.0 --skip-download \
      --worker-ips "192.168.124.23" --worker-password "$spec_pass"
  if [[ "$PARSE_RC" -eq 0 ]]; then
    echo "$PARSE_OUT" | grep -Fxq "WORKER_PASSWORD=${spec_pass}" \
      || fail "parsed password mismatch for special-character case"
  else
    fail "parse failed for special-character password case: ${PARSE_ERR}"
  fi
done
pass "parse_args preserves --worker-password including special characters"

# Worker orchestration uses configured password, not aelladata.
BIN="${WORKDIR}/bin"
mkdir -p "$BIN"
SSHPASS_PASS_FILE="${WORKDIR}/sshpass.pass"
SSHPASS_CMD_FILE="${WORKDIR}/sshpass.cmd"
: >"$SSHPASS_PASS_FILE"
: >"$SSHPASS_CMD_FILE"

cat >"${BIN}/sshpass" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-p" ]]; then
  printf '%s\\n' "\$2" >>"${SSHPASS_PASS_FILE}"
  shift 2
fi
printf '%s\\n' "\$*" >>"${SSHPASS_CMD_FILE}"
if [[ "\$1" == "ssh" ]]; then
  remote="\${@: -1}"
  case "\$remote" in
    "echo ok") echo ok ;;
    hostname) echo worker1 ;;
  esac
fi
exit 0
EOF
chmod +x "${BIN}/sshpass"

cat >"${BIN}/kubectl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "get" && "$2" == "nodes" ]]; then
  printf 'master Ready  <none>  1d  v1.31.0  192.168.124.21  192.168.124.21  Ubuntu 24.04\n'
  printf 'worker1 Ready <none>  1d  v1.31.0  192.168.124.23  192.168.124.23  Ubuntu 24.04\n'
fi
exit 0
EOF
chmod +x "${BIN}/kubectl"

STAGING="${WORKDIR}/staging"
AELLADEB="${WORKDIR}/aelladeb"
mkdir -p "$STAGING" "$AELLADEB"
SCRIPT_COPY="${WORKDIR}/bringup_copy.sh"
printf '#!/bin/bash\necho fake\n' >"$SCRIPT_COPY"

export PATH="${BIN}:${PATH}"
export LOG_FILE="${WORKDIR}/bringup-test.log"
: >"$LOG_FILE"

ORCH_RUNNER="${WORKDIR}/run_orch.sh"
cat >"$ORCH_RUNNER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
VERSION="6.6.0"
WORKER_IPS="192.168.124.23"
WORKER_PASSWORD='Abc\$123!'
ROLE="DL-master"
WORKER_MODE=false
DRY_RUN=false
SKIP_DOWNLOAD=true
STAGING_DIR=$(printf '%q' "$STAGING")
AELLADEB_DIR=$(printf '%q' "$AELLADEB")
SCRIPT_PATH=$(printf '%q' "$SCRIPT_COPY")
SCRIPT_NAME="bringup_py3_dp_after_os_upgrade.sh"
SSH_OPTS="-o StrictHostKeyChecking=no"
SCP_OPTS="-o StrictHostKeyChecking=no"
die() { echo "FATAL: \$*" >&2; exit 1; }
log() { echo "\$*"; }
log_phase() { echo "PHASE: \$*"; }
copy_phase2_prereq_contract_to_worker() { return 0; }
normalize_remote_orchestration_nodes() { return 0; }
# shellcheck disable=SC1090
source $(printf '%q' "$ORCH_SRC")
orchestrate_workers
EOF
set +e
orch_out="$(bash "$ORCH_RUNNER" 2>&1)"
orch_rc=$?
set -e

[[ "$orch_rc" -eq 0 ]] || fail "orchestrate_workers rc=${orch_rc} out=${orch_out}"
if grep -Fxq 'Abc$123!' "$SSHPASS_PASS_FILE"; then
  pass "orchestrate_workers passed configured password to sshpass"
else
  fail "sshpass did not receive configured password"
fi
if grep -Fxq 'aelladata' "$SSHPASS_PASS_FILE"; then
  fail "orchestrate_workers still used hardcoded aelladata"
else
  pass "orchestrate_workers did not use hardcoded aelladata"
fi
grep -q 'sshpass -p' <<<"$orch_out" && fail "password leaked into orchestration stdout" || true

# reclaim_overlay2_on_workers also uses WORKER_PASSWORD
RECLAIM_SRC="${WORKDIR}/reclaim.sh"
awk '
  /^reclaim_overlay2_on_workers\(\)/ {keep=1}
  keep {print}
  keep && /^}$/ {exit}
' "$BRINGUP" >"$RECLAIM_SRC"
: >"$SSHPASS_PASS_FILE"
RECLAIM_RUNNER="${WORKDIR}/run_reclaim.sh"
cat >"$RECLAIM_RUNNER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
WORKER_IPS="192.168.124.23"
WORKER_PASSWORD='worker@Pass#2026'
DRY_RUN=true
SCRIPT_PATH=$(printf '%q' "$SCRIPT_COPY")
SCRIPT_NAME="bringup_py3_dp_after_os_upgrade.sh"
SCP_OPTS="-o StrictHostKeyChecking=no"
SSH_OPTS="-o StrictHostKeyChecking=no"
die() { echo "FATAL: \$*" >&2; exit 1; }
log() { echo "\$*"; }
# shellcheck disable=SC1090
source $(printf '%q' "$RECLAIM_SRC")
reclaim_overlay2_on_workers
EOF
set +e
reclaim_out="$(bash "$RECLAIM_RUNNER" 2>&1)"
reclaim_rc=$?
set -e
[[ "$reclaim_rc" -eq 0 ]] || fail "reclaim_overlay2_on_workers rc=${reclaim_rc} out=${reclaim_out}"
if grep -Fxq 'worker@Pass#2026' "$SSHPASS_PASS_FILE"; then
  pass "overlay2 worker sweep used configured password"
else
  fail "overlay2 sweep password missing"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_bringup_worker_password PASS ==="
else
  echo "=== test_bringup_worker_password FAIL ==="
fi
exit "$FAIL"
