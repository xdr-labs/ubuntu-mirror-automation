#!/usr/bin/env bash
# --worker-password-file parsing and worker-orchestration credential use.
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

grep -q -- '--worker-password-file' "$BRINGUP" \
  || fail "--worker-password-file not in bringup"
grep -q -- '--worker-password' "$BRINGUP" \
  || fail "legacy --worker-password not in bringup"
grep -q 'WORKER_IPS requires --worker-password\|--worker-ips requires --worker-password\|--worker-ips/--standby requires --worker-password-file' "$BRINGUP" \
  || fail "missing --worker-ips/--worker-password-file validation"

grep -q 'sshpass -f' "$BRINGUP" \
  || fail "sshpass -f not used in patched bringup"
grep 'sshpass -p' "$BRINGUP" \
  && fail "sshpass -p still present in patched bringup" \
  || pass "no sshpass -p in patched bringup"

CRED_SRC="${ROOT}/scripts/lib/phase2_bringup_patch/fragment_credential_ssh.sh"
COMPAT_SRC="${ROOT}/scripts/lib/phase2_bringup_patch/fragment_compat.sh"

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
    PHASE2_WORKER_PASSWORD_PRIVATE_DIR="$WORKDIR"
    die() { echo "FATAL: $*" >&2; exit 1; }
    log() { :; }
    check_version_guard() { return 0; }
    # shellcheck disable=SC1090
    source "$COMPAT_SRC"
    # shellcheck disable=SC1090
    source "$CRED_SRC"
    # shellcheck disable=SC1090
    source "$PARSE_SRC"
    parse_args "$@"
    printf 'VERSION=%s\n' "$VERSION"
    printf 'WORKER_IPS=%s\n' "$WORKER_IPS"
    printf 'WORKER_PASSWORD=%s\n' "${WORKER_PASSWORD:-}"
    printf 'PHASE2_WORKER_PASSWORD_FILE=%s\n' "${PHASE2_WORKER_PASSWORD_FILE:-}"
    if [[ -n "${PHASE2_WORKER_PASSWORD_FILE:-}" && -f "$PHASE2_WORKER_PASSWORD_FILE" ]]; then
      printf 'PHASE2_WORKER_PASSWORD_FILE_CONTENT=%s\n' "$(cat "$PHASE2_WORKER_PASSWORD_FILE")"
    else
      printf 'PHASE2_WORKER_PASSWORD_FILE_CONTENT=\n'
    fi
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
  echo "$PARSE_OUT" | grep -qx 'WORKER_PASSWORD=' || fail "unexpected worker password var on AIO"
  echo "$PARSE_OUT" | grep -qx 'PHASE2_WORKER_PASSWORD_FILE=' || fail "unexpected password file on AIO"
  pass "AIO parse does not require worker password file"
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
run_parse --version 6.6.0 --skip-download --worker-ips "192.0.2.23,192.0.2.25"
[[ "$PARSE_RC" -ne 0 ]] || fail "worker-ips without password file accepted"
echo "$PARSE_ERR" | grep -q -- '--worker-ips/--standby requires --worker-password-file\|--worker-ips requires --worker-password' \
  || fail "missing validation error: ${PARSE_ERR}"
pass "worker-ips without password file is rejected"

# legacy --worker-password migrates to private file (including special characters)
for spec_pass in 'something' 'Test123!' 'Abc$123!' 'worker@Pass#2026' 'A&b!c$123'; do
  run_parse --version 6.6.0 --skip-download \
      --worker-ips "192.0.2.23" --worker-password "$spec_pass"
  if [[ "$PARSE_RC" -eq 0 ]]; then
    echo "$PARSE_OUT" | grep -qx 'WORKER_PASSWORD=' \
      || fail "WORKER_PASSWORD not cleared after migration"
    echo "$PARSE_OUT" | grep -Fxq "PHASE2_WORKER_PASSWORD_FILE_CONTENT=${spec_pass}" \
      || fail "password file content mismatch for special-character case"
  else
    fail "parse failed for special-character password case: ${PARSE_ERR}"
  fi
done
pass "legacy --worker-password migrates to private file"

PWFILE="${WORKDIR}/worker-password.file"
printf '%s' 'file-mode-pass' >"$PWFILE"
chmod 0600 "$PWFILE"
run_parse --version 6.6.0 --skip-download \
  --worker-ips "192.0.2.23" --worker-password-file "$PWFILE"
[[ "$PARSE_RC" -eq 0 ]] || fail "--worker-password-file parse failed: ${PARSE_ERR}"
echo "$PARSE_OUT" | grep -Fxq "PHASE2_WORKER_PASSWORD_FILE=${PWFILE}" \
  || fail "--worker-password-file path not preserved"
pass "--worker-password-file accepted"

# Worker orchestration uses password file, not argv literal or aelladata.
BIN="${WORKDIR}/bin"
mkdir -p "$BIN"
SSHPASS_PASS_FILE="${WORKDIR}/sshpass.pass"
SSHPASS_CMD_FILE="${WORKDIR}/sshpass.cmd"
: >"$SSHPASS_PASS_FILE"
: >"$SSHPASS_CMD_FILE"

cat >"${BIN}/sshpass" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-f" ]]; then
  cat "\$2" >>"${SSHPASS_PASS_FILE}"
  shift 2
elif [[ "\$1" == "-p" ]]; then
  printf '%s\\n' "\$2" >>"${SSHPASS_PASS_FILE}"
  shift 2
fi
printf '%s\\n' "\$*" >>"${SSHPASS_CMD_FILE}"
if [[ "\$1" == "scp" ]]; then
  exit 0
fi
if [[ "\$1" == "ssh" ]]; then
  remote="\${@: -1}"
  case "\$remote" in
    "echo ok") echo ok ;;
    hostname) echo worker1 ;;
    *aella_role*) echo DL-worker ;;
    *) echo ok ;;
  esac
fi
exit 0
EOF
chmod +x "${BIN}/sshpass"

cat >"${BIN}/kubectl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "get" && "$2" == "nodes" ]]; then
  printf 'master Ready  <none>  1d  v1.31.0  192.0.2.21  192.0.2.21  Ubuntu 24.04\n'
  printf 'worker1 Ready <none>  1d  v1.31.0  192.0.2.23  192.0.2.23  Ubuntu 24.04\n'
fi
exit 0
EOF
chmod +x "${BIN}/kubectl"

STAGING="${WORKDIR}/staging"
AELLADEB="${WORKDIR}/aelladeb"
mkdir -p "$STAGING" "$AELLADEB"
SCRIPT_COPY="${WORKDIR}/bringup_copy.sh"
printf '#!/bin/bash\necho fake\n' >"$SCRIPT_COPY"
ORCH_PWFILE="${WORKDIR}/orch-worker-password"
printf '%s' 'Abc$123!' >"$ORCH_PWFILE"
chmod 0600 "$ORCH_PWFILE"

export PATH="${BIN}:${PATH}"
export LOG_FILE="${WORKDIR}/bringup-test.log"
: >"$LOG_FILE"

ORCH_RUNNER="${WORKDIR}/run_orch.sh"
cat >"$ORCH_RUNNER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
VERSION="6.6.0"
WORKER_IPS="192.0.2.23"
STANDBY_IPS=""
PHASE2_WORKER_PASSWORD_FILE=$(printf '%q' "$ORCH_PWFILE")
PHASE2_SSH_STATE_DIR=$(printf '%q' "$WORKDIR/ssh-state")
PHASE2_WORKER_PASSWORD_PRIVATE_DIR=$(printf '%q' "$WORKDIR")
export PHASE2_SSH_STATE_DIR
mkdir -p "\$PHASE2_SSH_STATE_DIR"
export PATH=$(printf '%q' "$BIN"):"\$PATH"
ROLE="DL-master"
WORKER_MODE=false
DRY_RUN=false
SKIP_DOWNLOAD=true
STAGING_DIR=$(printf '%q' "$STAGING")
AELLADEB_DIR=$(printf '%q' "$AELLADEB")
SCRIPT_PATH=$(printf '%q' "$SCRIPT_COPY")
SCRIPT_NAME="bringup_py3_dp_after_os_upgrade.sh"
SCP_OPTS="-o StrictHostKeyChecking=accept-new"
SSH_OPTS="-o StrictHostKeyChecking=accept-new"
die() { echo "FATAL: \$*" >&2; exit 1; }
log() { echo "\$*"; }
log_phase() { echo "PHASE: \$*"; }
# shellcheck disable=SC1090
source $(printf '%q' "$COMPAT_SRC")
# shellcheck disable=SC1090
source $(printf '%q' "$CRED_SRC")
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
if grep -Fq 'Abc$123!' "$SSHPASS_PASS_FILE"; then
  pass "orchestrate_workers passed configured password via sshpass -f"
else
  fail "sshpass -f did not receive configured password"
fi
if grep -Fxq 'aelladata' "$SSHPASS_PASS_FILE"; then
  fail "orchestrate_workers still used hardcoded aelladata"
else
  pass "orchestrate_workers did not use hardcoded aelladata"
fi
grep -q 'sshpass -p' <<<"$orch_out" && fail "password leaked into orchestration stdout" || true

# reclaim_overlay2_on_workers also uses password file
RECLAIM_SRC="${WORKDIR}/reclaim.sh"
awk '
  /^reclaim_overlay2_on_workers\(\)/ {keep=1}
  keep {print}
  keep && /^}$/ {exit}
' "$BRINGUP" >"$RECLAIM_SRC"
: >"$SSHPASS_PASS_FILE"
RECLAIM_PWFILE="${WORKDIR}/reclaim-worker-password"
printf '%s' 'worker@Pass#2026' >"$RECLAIM_PWFILE"
chmod 0600 "$RECLAIM_PWFILE"
RECLAIM_RUNNER="${WORKDIR}/run_reclaim.sh"
cat >"$RECLAIM_RUNNER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
WORKER_IPS="192.0.2.23"
PHASE2_WORKER_PASSWORD_FILE=$(printf '%q' "$RECLAIM_PWFILE")
PHASE2_SSH_STATE_DIR=$(printf '%q' "$WORKDIR/ssh-state")
export PHASE2_SSH_STATE_DIR
mkdir -p "\$PHASE2_SSH_STATE_DIR"
DRY_RUN=true
export PATH=$(printf '%q' "$BIN"):"\$PATH"
SCRIPT_PATH=$(printf '%q' "$SCRIPT_COPY")
SCRIPT_NAME="bringup_py3_dp_after_os_upgrade.sh"
SCP_OPTS="-o StrictHostKeyChecking=accept-new"
SSH_OPTS="-o StrictHostKeyChecking=accept-new"
die() { echo "FATAL: \$*" >&2; exit 1; }
log() { echo "\$*"; }
# shellcheck disable=SC1090
source $(printf '%q' "$COMPAT_SRC")
# shellcheck disable=SC1090
source $(printf '%q' "$CRED_SRC")
# shellcheck disable=SC1090
source $(printf '%q' "$RECLAIM_SRC")
reclaim_overlay2_on_workers
EOF
set +e
reclaim_out="$(bash "$RECLAIM_RUNNER" 2>&1)"
reclaim_rc=$?
set -e
[[ "$reclaim_rc" -eq 0 ]] || fail "reclaim_overlay2_on_workers rc=${reclaim_rc} out=${reclaim_out}"
if grep -Fq 'worker@Pass#2026' "$SSHPASS_PASS_FILE"; then
  pass "overlay2 worker sweep used password file"
else
  fail "overlay2 sweep password missing"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_bringup_worker_password PASS ==="
else
  echo "=== test_bringup_worker_password FAIL ==="
fi
exit "$FAIL"
