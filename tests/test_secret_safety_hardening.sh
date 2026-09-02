#!/usr/bin/env bash
# Secret-safety hardening: no plaintext worker passwords in Menu 7 commands;
# private command-file mode; mm_redact coverage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_PROJECT_ROOT="$ROOT"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_LOG_DIR="$TMP/logs"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$TMP/config/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$TMP/config/status"
export MM_WORKFLOW_FILE="$TMP/config/dp-upgrade-workflow.state"
export MM_CLIENT_ROOT="$TMP/client"
mkdir -p "$MM_CLIENT_ROOT" "$MM_LOG_DIR" "$MM_CONFIG_DIR"
: >"$MM_STATUS_FILE"

python3 "${ROOT}/scripts/lib/build_client_launchers.py" \
  --project-root "$ROOT" \
  --output-dir "$MM_CLIENT_ROOT" \
  --mirror-base-url "http://192.0.2.10" \
  --signing-fingerprint "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" >/dev/null
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/phase2_helper_generation.sh"
mkdir -p "${MM_CLIENT_ROOT}/lib"
install -m 0755 "${ROOT}/client/stage-dp-phase2.sh" "${MM_CLIENT_ROOT}/stage-dp-phase2.sh"
install -m 0755 "${ROOT}/client/bringup_py3_dp_lifecycle.sh" "${MM_CLIENT_ROOT}/bringup_py3_dp_lifecycle.sh"
for hf in dp-offline-source-product-version.sh dp-phase2-operation-progress.sh \
  dp-phase2-bringup-lifecycle.sh dp-phase2-ubuntu-prerequisites.sh
do
  install -m 0755 "${ROOT}/client/lib/${hf}" "${MM_CLIENT_ROOT}/lib/${hf}"
done
phase2_helper_generation_write "$MM_CLIENT_ROOT" >/dev/null
# shellcheck source=lib/phase2_bundle_trust_fixture.sh
source "${ROOT}/tests/lib/phase2_bundle_trust_fixture.sh"
phase2_trust_fixture_export_dp_phase2_root "$TMP" >/dev/null
phase2_trust_fixture_write_bundle_sidecar "$MM_DP_PHASE2_ROOT" "6.6.0" >/dev/null
phase2_upgrade_wrapper_write "$MM_CLIENT_ROOT" "http://192.0.2.10" "6.6.0" >/dev/null
export SCRIPT_DIR="${ROOT}/scripts"
PREPARATION_MODE=FULL
MIRROR_HTTP_URL="http://192.0.2.10"

LIB="$TMP/installer-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$INSTALLER" >"$LIB"
# shellcheck disable=SC1090
source "$LIB"

assert_no_plaintext_password() {
  local file="$1" password="$2"
  if grep -Fqs -- "$password" "$file"; then
    fail "plaintext password leaked into command output"
  fi
}

assert_cluster_prompt_shape() {
  local file="$1" worker_ips="$2"
  local ip
  grep -q -- '--worker-password-file' "$file" \
    || fail "cluster command missing --worker-password-file flag"
  grep -q -- '--worker-ips' "$file" \
    || fail "cluster command missing --worker-ips"
  grep -q -- '--worker-password ' "$file" \
    && fail "cluster command still passes --worker-password on argv" || true
  # IPs may be shell-escaped (e.g. 192.0.2.1\\\,192.0.2.2); require each token.
  IFS=',' read -r -a ips <<<"$worker_ips"
  for ip in "${ips[@]}"; do
    ip="${ip// /}"
    [[ -n "$ip" ]] || continue
    grep -Fq "$ip" "$file" || fail "cluster command missing worker ip ${ip}"
  done
  grep -Eq 'read(\\[[:space:]]|[[:space:]])+-rsp|Worker(\\[[:space:]]|[[:space:]])+SSH' "$file" \
    || fail "cluster command missing runtime password prompt"
  grep -Eq 'mktemp|worker-password\\.XXXXXX|/var/lib/dp-phase2-bringup' "$file" \
    || fail "cluster command missing private password file pattern"
  grep -Eq '(\\\$PWFILE|\$PWFILE|"\$PWFILE")' "$file" \
    || fail "cluster command missing password file placeholder"
}

# --- Cluster: flag present, plaintext absent ---
CLUSTER_OUT="$TMP/cluster.txt"
WORKER_SSH_PASSWORD='customer-password'
gui_build_client_commands "http://192.0.2.10" "cluster" \
  "192.168.124.23,192.168.124.25" "" "customer-password" >"$CLUSTER_OUT"
assert_cluster_prompt_shape "$CLUSTER_OUT" "192.168.124.23,192.168.124.25"
assert_no_plaintext_password "$CLUSTER_OUT" "customer-password"
pass "cluster commands use runtime prompt; password not embedded"

# --- AIO/single: no worker password machinery ---
SINGLE_OUT="$TMP/single.txt"
gui_build_client_commands "http://192.0.2.10" "single" "" "" "" >"$SINGLE_OUT"
grep -q -- '--worker-password' "$SINGLE_OUT" && fail "AIO has --worker-password" || true
grep -q -- '--worker-ips' "$SINGLE_OUT" && fail "AIO has --worker-ips" || true
grep -q 'read -rsp' "$SINGLE_OUT" && fail "AIO has password prompt" || true
pass "AIO/single omits worker password"

# --- Special-character passwords never appear in command output ---
for spec_pass in 'Test123!' 'Abc$123!' 'worker@Pass#2026' 'A&b!c$123' 'p$ss"wo'\''rd`!'; do
  spec_out="$TMP/cluster-spec.txt"
  gui_build_client_commands "http://192.0.2.10" "cluster" "192.168.124.23" "" \
    "$spec_pass" >"$spec_out"
  assert_cluster_prompt_shape "$spec_out" "192.168.124.23"
  assert_no_plaintext_password "$spec_out" "$spec_pass"
done
pass "special-character passwords absent from command output"

# --- Config still requires password for cluster generation ---
set +e
gui_build_client_commands "http://192.0.2.10" "cluster" "192.168.124.23" "" "" \
  >"$TMP/nopass.txt" 2>"$TMP/nopass.err"
nopass_rc=$?
set -e
[[ "$nopass_rc" -ne 0 ]] || fail "cluster without password should fail"
grep -q 'WORKER_SSH_PASSWORD_REQUIRED=YES' "$TMP/nopass.err" \
  || fail "missing WORKER_SSH_PASSWORD_REQUIRED"
pass "config still requires password for cluster generation"

# --- mm_wf_atomic_publish_command_file → mode 0600 ---
mm_wf_ensure_file
PREPARATION_MODE=PHASE2_ONLY
PUB_TMP="$TMP/cmds.publish.tmp"
PUB_DEST="$TMP/cmds.publish"
gui_build_client_commands "http://192.0.2.10" "cluster" "192.168.124.23" "" \
  "customer-password" >"$PUB_TMP"
chmod 0644 "$PUB_TMP"
mm_wf_atomic_publish_command_file "$PUB_TMP" "$PUB_DEST" PHASE2_ONLY "gen-secret-1" >/dev/null \
  || fail "atomic publish failed"
[[ -f "$PUB_DEST" ]] || fail "published command file missing"
mode="$(stat -c '%a' "$PUB_DEST")"
[[ "$mode" == "600" || "$mode" == "0600" ]] \
  || fail "published command file mode=${mode} (want 0600)"
[[ "$mode" != "644" && "$mode" != "0644" ]] || fail "published command file still world-readable"
assert_no_plaintext_password "$PUB_DEST" "customer-password"
pass "atomic publish command file mode is 0600"

# --- mm_redact: --worker-password values and WORKER_SSH_PASSWORD= ---
secret='Sp3c#Pw!x9Q'
redacted="$(printf 'cmd --worker-password %s trailing\nWORKER_SSH_PASSWORD=%s rest\n' \
  "$secret" "$secret" | mm_redact)"
printf '%s\n' "$redacted" | grep -Fq "$secret" && fail "mm_redact leaked secret" || true
[[ "$redacted" == *'--worker-password-file ***'* ]] \
  || [[ "$redacted" == *'--worker-password-file=***'* ]] \
  || [[ "$redacted" == *'--worker-password ***'* ]] \
  || [[ "$redacted" == *'--worker-password=***'* ]] \
  || fail "mm_redact did not mask worker password value"
[[ "$redacted" == *'WORKER_SSH_PASSWORD=***'* ]] \
  || fail "mm_redact did not mask WORKER_SSH_PASSWORD="
pass "mm_redact masks worker password forms"

echo "ALL test_secret_safety_hardening checks passed"
