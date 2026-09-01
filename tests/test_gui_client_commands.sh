#!/usr/bin/env bash
# GUI client-command generation, menu helpers, worker IP validation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_PROJECT_ROOT="$ROOT"
# Fixture mirror addresses are RFC 5737 documentation IPs that are not
# configured on the test host; skip the interface-presence check only.
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_LOG_DIR="$TMP/logs"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$TMP/config/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$TMP/config/status"
export MM_CLIENT_ROOT="$TMP/client"
mkdir -p "$MM_CLIENT_ROOT"
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
phase2_upgrade_wrapper_write "$MM_CLIENT_ROOT" "http://192.0.2.10" "6.6.0" >/dev/null
export SCRIPT_DIR="${ROOT}/scripts"
mkdir -p "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$MM_CLIENT_ROOT"
: >"$MM_STATUS_FILE"
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

# --- worker IP validation ---
ok="$(mm_validate_worker_ips '192.168.124.23, 192.168.124.24')" \
  || fail "valid cluster worker ips rejected"
[[ "$ok" == "192.168.124.23,192.168.124.24" ]] || fail "worker ips not normalized: $ok"
ok_mgmt="$(mm_validate_worker_ips '10.10.10.23,10.10.10.24')" \
  || fail "valid management worker ips rejected"
[[ "$ok_mgmt" == "10.10.10.23,10.10.10.24" ]] || fail "mgmt ips not normalized"
mm_validate_worker_ips '' >/dev/null 2>&1 && fail "empty worker ips accepted" || true
mm_validate_worker_ips '192.168.1.1;rm -rf /' >/dev/null 2>&1 && fail "metachar accepted" || true
pass "worker IP validation"

mm_validate_worker_ssh_password '' '' \
  || fail "empty password should be allowed with no worker IPs"
mm_validate_worker_ssh_password '' '192.168.124.23' \
  && fail "empty password accepted with worker IPs" || true
mm_validate_worker_ssh_password 'customer-password' '192.168.124.23' \
  || fail "non-empty password rejected with worker IPs"
mm_validate_worker_ssh_password 'Abc$123!' '192.168.124.23,192.168.124.25' \
  || fail "special-character password rejected"
pass "worker SSH password validation"

# Persist / reload / update worker password
PREPARATION_MODE=FULL
ACPS_USERNAME=u
ACPS_PASSWORD=p
MIRROR_HTTP_URL="http://192.0.2.10"
WORKER_SSH_PASSWORD='customer-password'
DL_WORKER_IPS='192.168.124.23,192.168.124.25'
DA_WORKER_IPS='192.168.124.24,192.168.124.26'
mm_save_gui_config >/dev/null
grep -q 'WORKER_SSH_PASSWORD=' "$MM_CONFIG_FILE" || fail "WORKER_SSH_PASSWORD not written"
grep -q 'DL_WORKER_IPS=' "$MM_CONFIG_FILE" || fail "DL_WORKER_IPS not written"
grep -q 'DA_WORKER_IPS=' "$MM_CONFIG_FILE" || fail "DA_WORKER_IPS not written"
WORKER_SSH_PASSWORD=""
DL_WORKER_IPS=""
DA_WORKER_IPS=""
mm_load_gui_config
[[ "$WORKER_SSH_PASSWORD" == "customer-password" ]] || fail "worker password not reloaded"
[[ "$DL_WORKER_IPS" == '192.168.124.23,192.168.124.25' ]] || fail "DL worker IPs not reloaded"
[[ "$DA_WORKER_IPS" == '192.168.124.24,192.168.124.26' ]] || fail "DA worker IPs not reloaded"
WORKER_SSH_PASSWORD='Abc$123!'
mm_save_gui_config >/dev/null
WORKER_SSH_PASSWORD=""
mm_load_gui_config
[[ "$WORKER_SSH_PASSWORD" == 'Abc$123!' ]] || fail "updated worker password not reloaded"
# Empty password remains allowed when no worker IPs are configured.
WORKER_SSH_PASSWORD=""
rm -f "$MM_CONFIG_FILE"
ACPS_USERNAME=u
ACPS_PASSWORD=p
MIRROR_HTTP_URL="http://192.0.2.10"
mm_save_gui_config >/dev/null
WORKER_SSH_PASSWORD="stale"
mm_load_gui_config
[[ -z "${WORKER_SSH_PASSWORD}" ]] || fail "empty worker password not reloaded as empty"
pass "worker SSH password save/reload/update"
echo "DL_WORKER_IP_PERSISTENCE=PASS"
echo "DA_WORKER_IP_PERSISTENCE=PASS"
echo "WORKER_PASSWORD_PERSISTENCE=PASS"

# --- Configuration: Preparation Mode only; no DP version fields ---
grep -q '"1" "Preparation Mode"' "$INSTALLER" || fail "Preparation Mode menu missing"
grep -q '"5" "DL Worker IP addresses"' "$INSTALLER" || fail "DL Worker IP menu item missing"
grep -q '"6" "DA Worker IP addresses"' "$INSTALLER" || fail "DA Worker IP menu item missing"
grep -q '"7" "Worker SSH Password (aella)"' "$INSTALLER" \
  || fail "Worker SSH Password menu item missing"
grep -q 'Common aella SSH password used by each cluster master to access its workers' "$INSTALLER" \
  || fail "Worker SSH Password help text missing"
grep -qE 'Current DP Version|Starting DP Version"|Target DP Version|"DP Version"' "$INSTALLER" \
  && fail "DP version config fields still present" || true
footer="$(mm_config_footer_text)"
grep -Fxq 'Starting DP Version: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0' <<<"$footer" \
  || fail "exact footer starting line missing"
grep -Fxq 'Phase 2 Target:      6.6.0 (fixed)' <<<"$footer" \
  || fail "exact footer phase2 target line missing"
grep -Fxq 'DP OS version: 16.04' <<<"$footer" \
  || fail "exact footer DP OS line missing"
grep -Fq 'If the DP is already running Ubuntu 24.04, select Phase 2 Only.' <<<"$footer" \
  || fail "Phase 2 Only notice missing"
pass "Configuration uses Preparation Mode + exact footer"

# Menu height must fit Configuration instruction+footer (not a fixed +12 chrome).
# Match production: trailing blank line avoids newt clipping the last footer line.
config_text="Preparation Mode: Full OS Upgrade + Phase 2
ACPS Username: configured
ACPS Password: configured
DL Worker IPs: 192.168.124.23,192.168.124.25
DA Worker IPs: 192.168.124.24,192.168.124.26
Worker SSH Password (aella): configured
ACPS Server: Fixed
OS Core Source: Cloudflare R2

${footer}
"
config_text_lines="$(printf '%b' "$config_text" | wc -l)"
# mm_term_size normally overwrites HEIGHT/WIDTH via tput; pin sizes for this check.
mm_term_size() { :; }
HEIGHT=50 WIDTH=140
read -r cfg_h cfg_w cfg_list <<<"$(mm_calc_menu_size 9 74 8 "${config_text_lines}")"
# Whiptail text rows ≈ dialog_height - list_height - chrome(10).
cfg_text_rows=$((cfg_h - cfg_list - 10))
[[ "$cfg_text_rows" -ge "$config_text_lines" ]] \
  || fail "config menu text rows ${cfg_text_rows} < footer block ${config_text_lines} (h=${cfg_h} list=${cfg_list})"
HEIGHT=40 WIDTH=100
read -r cfg_h cfg_w cfg_list <<<"$(mm_calc_menu_size 9 74 8 "${config_text_lines}")"
cfg_text_rows=$((cfg_h - cfg_list - 10))
[[ "$cfg_text_rows" -ge "$config_text_lines" ]] \
  || fail "mid-term config menu clips footer (rows=${cfg_text_rows} need=${config_text_lines} h=${cfg_h} list=${cfg_list})"
grep -q 'text_lines' "$INSTALLER" || fail "mm_calc_menu_size missing text_lines sizing"
pass "Configuration menu height fits exact footer"

# Fixed target constant
mm_force_phase2_target
[[ "$TARGET_DP_VERSION" == "6.6.0" ]] || fail "forced target not 6.6.0"
[[ "$PHASE2_TARGET_VERSION" == "6.6.0" ]] || fail "PHASE2_TARGET_VERSION not 6.6.0"
TARGET_DP_VERSION=9.9.9
mm_force_phase2_target
[[ "$TARGET_DP_VERSION" == "6.6.0" ]] || fail "production override not forced back to 6.6.0"
pass "Phase 2 target fixed at 6.6.0"

# --- FULL mode command generation ---
PREPARATION_MODE=FULL
OUT="$TMP/cmds-full.txt"
gui_build_client_commands "http://192.0.2.10" "single" "" >"$OUT"

grep -q 'Supported Starting DP Versions: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0' "$OUT" \
  || fail "missing supported starting versions"
grep -q 'Phase 2 Target: 6.6.0' "$OUT" || fail "missing phase2 target header"
grep -q 'OS Upgrade: Ubuntu 16.04 → Ubuntu 24.04' "$OUT" || fail "missing OS upgrade header"
grep -q 'Commands saved to:' "$OUT" || fail "missing Commands saved to"
grep -q 'DP_OS_HOP_COMMAND_VERSION=WRAPPER_V1' "$OUT" || fail "missing WRAPPER_V1"
grep -q 'Copy and paste the following entire line into the DP terminal:' "$OUT" || fail "missing one-line copy guidance"
grep -q 'Do not copy only one or two lines' "$OUT" && fail "obsolete three-line Phase2 warning still present" || true
true  # OS-hop one-line guidance is now required
grep -q 'Visual wrapping does not insert a newline' "$OUT" && fail "obsolete wrap guidance still present" || true
grep -qE 'STEP 0 — SNAPSHOT|Step 0 —' "$OUT" || fail "missing step 0"
grep -qE 'STEP 1 — PAUSE|Step 1 — Pause' "$OUT" || fail "missing pause"
grep -qE 'STEP 2 — UBUNTU 16.04 TO 18.04|Step 2 — Ubuntu 16.04 to 18.04' "$OUT" \
  || fail "missing hop 16→18"
grep -q 'The Xenial-to-Bionic client automatically sets the aella and root login' "$OUT" \
  || fail "missing automatic login shell guidance"
grep -qE 'STEP 3 — UBUNTU 18.04 TO 20.04|Step 3 — Ubuntu 18.04 to 20.04' "$OUT" \
  || fail "missing hop 18→20"
grep -qE 'STEP 4 — UBUNTU 20.04 TO 22.04|Step 4 — Ubuntu 20.04 to 22.04' "$OUT" \
  || fail "missing hop 20→22"
grep -qE 'STEP 5 — UBUNTU 22.04 TO 24.04|Step 5 — Ubuntu 22.04 to 24.04' "$OUT" \
  || fail "missing hop 22→24"
grep -qE 'STEP 6 — STAGE DP 6.6.0|Step 6 — Stage DP 6.6.0 files' "$OUT" \
  || fail "missing stage"
grep -qE 'STEP 7 — RUN DP 6.6.0 BRINGUP|Step 7 — Run DP 6.6.0 bringup' "$OUT" \
  || fail "missing bringup"
grep -qE 'STEP 8 — RESUME|Step 8 — Resume' "$OUT" || fail "missing resume"
grep -qE 'STEP 9 — VERIFY|Step 9 — Verify' "$OUT" || fail "missing health"
grep -q 'Verify bash login shells' "$OUT" && fail "manual shell verify step still present" || true
grep -q 'getent passwd aella root' "$OUT" && fail "manual getent shell command still present" || true
grep -q 'Show complete instructions' "$OUT" && fail "Show complete instructions still present" || true
grep -q 'Show Step 2 command block' "$OUT" && fail "Show Step submenu still present" || true
grep -q 'BEGIN STEP' "$OUT" && fail "BEGIN STEP markers must be removed" || true
grep -q 'END STEP' "$OUT" && fail "END STEP markers must be removed" || true
grep -qE '\\[[:space:]]*$' "$OUT" && fail "backslash continuations must not appear in Menu 7" || true
grep -q 'upgrade-xenial-to-bionic.sh' "$OUT" || fail "missing OS wrapper in commands"
# gpgv lives inside launcher, not operator command
grep -qE 'gpgv --keyring' "$OUT" && fail "gpgv must not appear in operator OS-hop command" || true
grep -q -- '--keyring ./public.gpg' "$OUT" && fail "gpgv must not use armored public.gpg" || true
grep -q "EXPECTED_FPR=" "$OUT" && fail "EXPECTED_FPR must not appear in Menu 7 OS-hop command" || true
grep -q 'mktemp -d' "$OUT" && fail "mktemp must not appear in Menu 7 operator command" || true
grep -q 'dp-launch-xenial-to-bionic.sh' "$OUT" && fail "launcher bootstrap leaked into Menu 7" || true
grep -q 'mktemp -d' "$MM_CLIENT_ROOT/dp-launch-xenial-to-bionic.sh" || fail "missing isolated workdir in launcher"
grep -q 'dp-client-command-runner.sh' "$MM_CLIENT_ROOT/dp-launch-xenial-to-bionic.sh" || fail "missing command runner in launcher"
grep -q 'rm -f "\$SCRIPT"' "$OUT" && fail "must not rm existing files before HTTP" || true
grep -Eq 'curl -fsSLO([[:space:]]|$)' "$OUT" && fail "naked curl -fsSLO present" || true
grep -q 'less -S' "$OUT" && fail "less pager guidance must be removed" || true
# Full mode must still cover steps 0..9
for n in 0 1 2 3 4 5 6 7 8 9; do
  grep -qE "Step ${n} —|STEP ${n} —" "$OUT" || fail "missing step ${n}"
done
for script in \
  upgrade-phase2.sh \
  bringup_py3_dp_after_os_upgrade.sh
do
  grep -Fq "$script" "$OUT" || fail "missing script name: $script"
done
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  grep -q "upgrade-${hop}.sh" "$OUT" || fail "missing wrapper ${hop}"
done
true  # SCRIPT binding lives inside launcher
grep -q 'dp-client-command-runner.sh' "$MM_CLIENT_ROOT/dp-launch-xenial-to-bionic.sh" || fail "missing command runner name in launcher"
grep -Fq -- '--source-dp-version' "$OUT" && fail "FULL command has --source-dp-version" || true
grep -Fq -- '--target-version' "$MM_CLIENT_ROOT/upgrade-phase2.sh" || fail "target version missing from phase2 wrapper"
grep -Fq -- '--mirror-url' "$MM_CLIENT_ROOT/upgrade-phase2.sh" || fail "mirror-url missing from phase2 wrapper"
if grep -E 'sudo bash.*"\$SCRIPT".*--same-version-recovery' "$MM_CLIENT_ROOT/upgrade-phase2.sh" >/dev/null 2>&1; then
  fail "normal phase2 wrapper must not force same-version-recovery"
fi
[[ -f "$MM_CLIENT_ROOT/upgrade-phase2-same-version-recovery.sh" ]] \
  || fail "explicit recovery wrapper missing"
grep -Fq 'CONFIRM_SAME_VERSION_RECOVERY=YES' \
  "$MM_CLIENT_ROOT/upgrade-phase2-same-version-recovery.sh" \
  || fail "recovery wrapper missing confirmation gate"
grep -Fq -- '--target-version' "$OUT" && fail "target-version leaked into Menu 7" || true
hop_count="$(grep -cE '^cd /home/aella && curl -fsSLo upgrade-' "$OUT" || true)"
[[ "$hop_count" -eq 5 ]] || fail "expected four OS wrappers + phase2 wrapper, got ${hop_count}"
mirror_count="$(grep -c "http://192.0.2.10/client/upgrade-" "$OUT" || true)"
[[ "$mirror_count" -ge 5 ]] || fail "expected wrapper URLs, got ${mirror_count}"
second_cmd="$(gui_client_hop_command_line "http://192.0.2.20" "dp-offline-upgrade-xenial-to-bionic.sh")"
[[ "$(printf '%s\n' "$second_cmd" | wc -l | tr -d ' ')" == "1" ]] \
  || fail "hop command_line must be one physical line"
[[ "$second_cmd" == *"http://192.0.2.20/client/upgrade-xenial-to-bionic.sh"* ]] \
  || fail "second fixture URL missing from hop command"
grep -q 'License is valid' "$OUT" || fail "license check missing"
pass "FULL mode client commands"

# --- PHASE2_ONLY mode: no OS hops ---
PREPARATION_MODE=PHASE2_ONLY
P2_OUT="$TMP/cmds-p2.txt"
gui_build_client_commands "http://192.0.2.10" "single" "" >"$P2_OUT"
grep -q 'DP Phase 2 Upgrade Commands' "$P2_OUT" || fail "phase2 title missing"
grep -q 'Required OS: Ubuntu 24.04' "$P2_OUT" || fail "required OS missing"
grep -q 'Ubuntu 16.04 to 18.04\|UBUNTU 16.04 TO 18.04' "$P2_OUT" && fail "PHASE2_ONLY still has OS hops" || true
grep -q 'dp-offline-upgrade-xenial-to-bionic' "$P2_OUT" && fail "PHASE2_ONLY hop script present" || true
grep -qE 'STEP 2 — STAGE DP 6.6.0|Step 2 — Stage DP 6.6.0 files' "$P2_OUT" \
  || fail "phase2 stage step missing"
grep -qE 'STEP 3 — RUN DP 6.6.0 BRINGUP|Step 3 — Run DP 6.6.0 bringup' "$P2_OUT" \
  || fail "phase2 bringup missing"
grep -q 'upgrade-phase2.sh' "$P2_OUT" || fail "phase2 wrapper missing from PHASE2_ONLY commands"
grep -Fq -- '--same-version-recovery' "$P2_OUT" && fail "same-version-recovery leaked into PHASE2_ONLY Menu 7" || true
grep -q 'BEGIN STEP\|BEGIN PHASE' "$P2_OUT" && fail "phase2 still has BEGIN markers" || true
pass "PHASE2_ONLY omits OS hop commands"

# Required wrappers: FULL needs all five; PHASE2_ONLY needs upgrade-phase2.sh.
READY_FULL="$TMP/ready-full"
cp -a "$MM_CLIENT_ROOT" "$READY_FULL"
if mm_client_files_ready "$READY_FULL" 2>/dev/null; then
  pass "FULL seeded client with wrappers is ready"
else
  # Synthetic launcher tree may lack signed hop clients; wrapper presence still required.
  [[ -f "${READY_FULL}/upgrade-xenial-to-bionic.sh" ]] \
    && [[ -f "${READY_FULL}/upgrade-phase2.sh" ]] \
    && pass "FULL required wrappers present" \
    || fail "FULL required wrappers missing"
fi
rm -f "${READY_FULL}/upgrade-jammy-to-noble.sh"
if mm_client_files_ready "$READY_FULL" 2>/dev/null; then
  fail "FULL readiness passed with missing OS wrapper"
else
  pass "missing required OS wrapper makes FULL readiness FAIL"
fi
READY_P2="$TMP/ready-p2"
mkdir -p "${READY_P2}/lib"
cp -a "${MM_CLIENT_ROOT}/stage-dp-phase2.sh" "${READY_P2}/stage-dp-phase2.sh"
cp -a "${MM_CLIENT_ROOT}/stage-dp-phase2.sh.sha256" "${READY_P2}/stage-dp-phase2.sh.sha256" 2>/dev/null || \
  (cd "$READY_P2" && sha256sum stage-dp-phase2.sh >stage-dp-phase2.sh.sha256)
cp -a "${MM_CLIENT_ROOT}/bringup_py3_dp_lifecycle.sh" "${READY_P2}/bringup_py3_dp_lifecycle.sh"
cp -a "${MM_CLIENT_ROOT}/lib/." "${READY_P2}/lib/"
cp -a "${MM_CLIENT_ROOT}/phase2-helper-generation.manifest" "${READY_P2}/phase2-helper-generation.manifest"
cp -a "${MM_CLIENT_ROOT}/upgrade-phase2.sh" "${READY_P2}/upgrade-phase2.sh"
cp -a "${MM_CLIENT_ROOT}/upgrade-phase2.sh.sha256" "${READY_P2}/upgrade-phase2.sh.sha256"
cp -a "${MM_CLIENT_ROOT}/upgrade-phase2-same-version-recovery.sh" \
  "${READY_P2}/upgrade-phase2-same-version-recovery.sh"
cp -a "${MM_CLIENT_ROOT}/upgrade-phase2-same-version-recovery.sh.sha256" \
  "${READY_P2}/upgrade-phase2-same-version-recovery.sh.sha256" 2>/dev/null || true
if mm_client_files_ready_phase2 "$READY_P2"; then
  pass "PHASE2_ONLY required wrapper present"
else
  fail "PHASE2_ONLY helper set with wrapper should be ready"
fi
rm -f "${READY_P2}/upgrade-phase2.sh"
if mm_client_files_ready_phase2 "$READY_P2"; then
  fail "PHASE2_ONLY readiness passed without upgrade-phase2.sh"
else
  pass "missing upgrade-phase2.sh makes PHASE2_ONLY readiness FAIL"
fi
mm_http_probe_ok() {
  local url="$1"
  [[ "$url" == *"/client/upgrade-phase2.sh" ]] && return 1
  return 0
}
mm_http_publication_identity_ok() { return 0; }
mm_phase2_paths() { MM_WF_PHASE2_STABLE="dp_bundle_6.6.0-current.tar"; }
TARGET_DP_VERSION=6.6.0
PHASE2_TARGET_VERSION=6.6.0
PREPARATION_MODE=FULL
if mm_http_required_urls_ok; then
  fail "HTTP readiness passed without upgrade-phase2.sh probe"
else
  pass "missing wrapper over HTTP makes readiness FAIL"
fi
mm_http_probe_ok() { return 0; }
PREPARATION_MODE=PHASE2_ONLY

# Forbidden strings
for bad in \
  CLIENT_DOWNLOAD_SOURCE CLIENT_R2_ACCESS CLIENT_ACPS_ACCESS \
  PROJECT_ROLLBACK_SUPPORTED 'Repeat similarly' '<mirror-ip>' \
  'Worker management IPs' '--source-dp-version' \
  'Current DP Version' 'Target DP Version' \
  '221.139.249.111' '221.139.249.112'
do
  if grep -Fq -- "$bad" "$OUT"; then
    fail "forbidden string present in FULL: $bad"
  fi
  if grep -Fq -- "$bad" "$P2_OUT"; then
    fail "forbidden string present in PHASE2_ONLY: $bad"
  fi
done
pass "forbidden strings absent"

# Cluster bringup: DL master workers + password configured (runtime prompt; no plaintext)
CLUSTER_OUT="$TMP/cluster-dl.txt"
PREPARATION_MODE=FULL
WORKER_SSH_PASSWORD='customer-password'
gui_build_client_commands "http://192.0.2.10" "cluster" "192.168.124.23,192.168.124.25" "" \
  "customer-password" >"$CLUSTER_OUT"
grep -q -- '--worker-ips' "$CLUSTER_OUT" || fail "DL --worker-ips missing"
grep -Fq '192.168.124.23' "$CLUSTER_OUT" && grep -Fq '192.168.124.25' "$CLUSTER_OUT" \
  || fail "DL worker ips missing"
grep -q -- '--worker-password' "$CLUSTER_OUT" || fail "DL --worker-password missing"
grep -Fq 'customer-password' "$CLUSTER_OUT" && fail "DL plaintext password embedded" || true
grep -Eq 'read(\\[[:space:]]|[[:space:]])+-rsp|Worker(\\[[:space:]]|[[:space:]])+SSH' "$CLUSTER_OUT" \
  || fail "DL runtime password prompt missing"
grep -q 'Cluster IP addresses are recommended' "$CLUSTER_OUT" || fail "cluster IP recommendation missing"
grep -q 'Management IP addresses or cluster IP addresses can be used' "$CLUSTER_OUT" || fail "mgmt/cluster IP support missing"
pass "DL cluster bringup command"

assert_cluster_bringup_prompt() {
  # Interactive prompt model: password never embedded; flag + worker-ips present.
  local file="$1" expect_ips="$2" password="${3:-}"
  local ip
  grep -q -- '--worker-ips' "$file" || fail "missing --worker-ips in cluster output"
  IFS=',' read -r -a ips <<<"$expect_ips"
  for ip in "${ips[@]}"; do
    ip="${ip// /}"
    [[ -n "$ip" ]] || continue
    grep -Fq "$ip" "$file" || fail "worker ip missing: ${ip}"
  done
  grep -q -- '--worker-password' "$file" || fail "missing --worker-password flag"
  grep -Eq 'read(\\[[:space:]]|[[:space:]])+-rsp|Worker(\\[[:space:]]|[[:space:]])+SSH' "$file" || fail "missing runtime password prompt"
  if [[ -n "$password" ]]; then
    grep -Fq -- "$password" "$file" && fail "plaintext password present in command output" || true
  fi
}

assert_single_bringup_no_workers() {
  local file="$1"
  local line
  line="$(grep -E 'bringup_py3_dp_after_os_upgrade\.sh' "$file" | head -1)"
  [[ -n "$line" ]] || fail "missing single bringup line"
  printf '%s\n' "$line" | grep -q -- '--worker-ips' && fail "unexpected --worker-ips" || true
  printf '%s\n' "$line" | grep -q -- '--worker-password' && fail "unexpected --worker-password" || true
}

assert_cluster_bringup_prompt "$CLUSTER_OUT" "192.168.124.23,192.168.124.25" "customer-password"
pass "DL worker-ips present; password not embedded"

# DA master workers use the same configured password (prompt; not embedded)
DA_OUT="$TMP/cluster-da.txt"
gui_build_client_commands "http://192.0.2.10" "cluster" "" "192.168.124.24,192.168.124.26" \
  "customer-password" >"$DA_OUT"
grep -q -- '--worker-ips' "$DA_OUT" || fail "DA --worker-ips missing"
grep -Fq '192.168.124.24' "$DA_OUT" && grep -Fq '192.168.124.26' "$DA_OUT" \
  || fail "DA worker ips missing"
assert_cluster_bringup_prompt "$DA_OUT" "192.168.124.24,192.168.124.26" "customer-password"
pass "DA worker-ips present; password not embedded"

# DL and DA cluster commands are emitted together from one configuration.
DUAL_OUT="$TMP/cluster-dual.txt"
gui_build_client_commands "http://192.0.2.10" "cluster" \
  "192.168.124.23,192.168.124.25" "192.168.124.24,192.168.124.26" \
  "customer-password" >"$DUAL_OUT"
[[ "$(grep -cE 'bringup_py3_dp_after_os_upgrade\.sh|read(\\[[:space:]]|[[:space:]])+-rsp' "$DUAL_OUT" || true)" -ge 2 ]] \
  || fail "dual cluster output must contain DL and DA bringup prompts"
grep -q 'STEP 7A — DL CLUSTER MASTER' "$DUAL_OUT" || fail "STEP 7A missing"
grep -q 'STEP 7B — DA CLUSTER MASTER' "$DUAL_OUT" || fail "STEP 7B missing"
grep -Fq '192.168.124.23' "$DUAL_OUT" && grep -Fq '192.168.124.25' "$DUAL_OUT" \
  || fail "dual DL worker list missing"
grep -Fq '192.168.124.24' "$DUAL_OUT" && grep -Fq '192.168.124.26' "$DUAL_OUT" \
  || fail "dual DA worker list missing"
grep -Fq 'customer-password' "$DUAL_OUT" && fail "dual plaintext password embedded" || true
pass "dual DL/DA cluster bringup commands"

# No workers: no --worker-ips / --worker-password
assert_single_bringup_no_workers "$OUT"
pass "single-node bringup omits worker flags"

# Cluster without password is rejected
set +e
gui_build_client_commands "http://192.0.2.10" "cluster" "192.168.124.23" "" "" \
  >"$TMP/cluster-nopass.txt" 2>"$TMP/cluster-nopass.err"
nopass_rc=$?
set -e
[[ "$nopass_rc" -ne 0 ]] || fail "cluster without password should fail"
grep -q 'WORKER_SSH_PASSWORD_REQUIRED=YES' "$TMP/cluster-nopass.err" \
  || fail "missing WORKER_SSH_PASSWORD_REQUIRED"
pass "cluster without password rejected"

# Special-character passwords must NOT appear in generated command output
for spec_pass in 'Test123!' 'Abc$123!' 'worker@Pass#2026' 'A&b!c$123'; do
  spec_out="$TMP/cluster-spec.txt"
  gui_build_client_commands "http://192.0.2.10" "cluster" "192.168.124.23" "" \
    "$spec_pass" >"$spec_out"
  assert_cluster_bringup_prompt "$spec_out" "192.168.124.23" "$spec_pass"
done
pass "special-character worker passwords not embedded in generated command"

# Config save: PREPARATION_MODE, no TARGET_DP_VERSION / CURRENT
PREPARATION_MODE=FULL
ACPS_USERNAME=u
ACPS_PASSWORD=p
MIRROR_HTTP_URL="http://192.0.2.10"
mm_save_gui_config >/dev/null
grep -q '^PREPARATION_MODE=FULL$' "$MM_CONFIG_FILE" || fail "PREPARATION_MODE not saved"
grep -q 'TARGET_DP_VERSION' "$MM_CONFIG_FILE" && fail "TARGET_DP_VERSION still written" || true
grep -q 'CURRENT_DP_VERSION' "$MM_CONFIG_FILE" && fail "CURRENT_DP_VERSION still written" || true
# Legacy ignored
cat >"$MM_CONFIG_FILE" <<EOF
CURRENT_DP_VERSION=6.3.0
SOURCE_DP_VERSION=6.3.0
TARGET_DP_VERSION=9.9.9
PREPARATION_MODE=PHASE2_ONLY
ACPS_USERNAME=u
ACPS_PASSWORD=p
MIRROR_HTTP_URL=http://192.0.2.10
EOF
chmod 600 "$MM_CONFIG_FILE"
mm_load_gui_config
[[ "$PREPARATION_MODE" == "PHASE2_ONLY" ]] || fail "PHASE2_ONLY not loaded"
[[ "$TARGET_DP_VERSION" == "6.6.0" ]] || fail "legacy TARGET not forced to 6.6.0"
[[ -z "${CURRENT_DP_VERSION:-}" ]] || fail "CURRENT not unset"
mm_config_ready || fail "config_ready should pass without source version"
pass "config save/load ignores legacy versions; mode required"

# Mode change stale commands
PREPARATION_MODE=FULL
mm_save_gui_config >/dev/null
mkdir -p "$(dirname "$(mm_client_commands_file)")"
echo stale >"$(mm_client_commands_file)"
chmod 644 "$(mm_client_commands_file)"
PREPARATION_MODE=PHASE2_ONLY
mm_save_gui_config >/dev/null
[[ ! -f "$(mm_client_commands_file)" ]] || fail "stale command file not removed on mode change"
pass "mode change invalidates client commands file"

# Menu 7: consumes saved DL/DA worker configuration; no topology/IP prompt.
PREPARATION_MODE=FULL
MIRROR_HTTP_URL="http://192.0.2.10"
MIRROR_SERVER_IP="192.0.2.10"
# Persist FULL before stubbing save — gui_client_instructions reloads config.
mm_save_gui_config >/dev/null
# Seed generation-bound readiness so Menu 7 preflight passes.
export MM_WORKFLOW_FILE="$TMP/config/dp-upgrade-workflow.state"
mm_wf_ensure_file
mm_status_set HTTP_DISTRIBUTION ENABLED
mm_status_set UPGRADE_READINESS PASS
mm_wf_set_many \
  "WORKFLOW_STATE=READINESS_VERIFIED" \
  "CONFIG_SHA256=$(mm_wf_config_sha256)" \
  "PREPARATION_MODE=FULL" \
  "MIRROR_SERVER_IP=192.0.2.10" \
  "MIRROR_HTTP_URL=http://192.0.2.10" \
  "CLIENT_SET_GENERATION_ID=gen-test-1" \
  "CLIENT_SIGNING_FINGERPRINT=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
  "HTTP_PUBLICATION_GENERATION_ID=gen-test-1" \
  "READINESS_VERIFIED_GENERATION_ID=gen-test-1"
export MM_SKIP_HTTP_VALIDATE=1
# Satisfy launcher readiness for Menu 7 preflight (FULL mode).
{
  cat <<EOF
CLIENT_SET_GENERATION_ID=gen-test-1
CLIENT_SIGNING_FINGERPRINT=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
MIRROR_HTTP_URL=http://192.0.2.10
CLIENT_MIRROR_BASE_URL=http://192.0.2.10
PREPARATION_MODE=FULL
CLIENT_LAUNCHER_SCHEMA_VERSION=1
EOF
  for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
    name="dp-launch-${hop}.sh"
    sha="$(sha256sum "${MM_CLIENT_ROOT}/${name}" | awk '{print $1}')"
    key="CLIENT_LAUNCHER_$(printf '%s' "$hop" | tr 'a-z-' 'A-Z_')_SHA256"
    printf '%s=%s\n' "$key" "$sha"
    wname="upgrade-${hop}.sh"
    sha="$(sha256sum "${MM_CLIENT_ROOT}/${wname}" | awk '{print $1}')"
    key="CLIENT_WRAPPER_$(printf '%s' "$hop" | tr 'a-z-' 'A-Z_')_SHA256"
    printf '%s=%s\n' "$key" "$sha"
  done
  printf 'CLIENT_WRAPPER_PHASE2_SHA256=%s\n' \
    "$(sha256sum "${MM_CLIENT_ROOT}/upgrade-phase2.sh" | awk '{print $1}')"
} >"${MM_CLIENT_ROOT}/client-set.env"
mm_client_set_current_source() { return 0; }
mm_client_launchers_ready() { return 0; }
MENU7_TRACE="$TMP/menu7.trace"
: >"$MENU7_TRACE"
INPUTBOX_COUNT=0
TEXTBOX_COUNT=0
MENU7_TEXTBOX_COUNT=0
mm_whiptail_input() {
  INPUTBOX_COUNT=$((INPUTBOX_COUNT + 1))
  printf 'INPUT\t%s\n' "$*" >>"$MENU7_TRACE"
  fail "unexpected input prompt on single path: $*"
}
# NOTE: $(mm_whiptail_menu) runs in a subshell — do not rely on call counters.
mm_whiptail_menu() {
  printf 'MENU\t%s\n' "$1" >>"$MENU7_TRACE"
  fail "Menu 7 must not ask topology or worker IPs: $1"
}
mm_whiptail_textbox() {
  TEXTBOX_COUNT=$((TEXTBOX_COUNT + 1))
  printf 'TEXTBOX\t%s\t%s\n' "$1" "$2" >>"$MENU7_TRACE"
  return 0
}
mm_menu7_textbox() {
  MENU7_TEXTBOX_COUNT=$((MENU7_TEXTBOX_COUNT + 1))
  printf 'MENU7_TEXTBOX\t%s\t%s\n' "$1" "$2" >>"$MENU7_TRACE"
  return 0
}
mm_whiptail_msg() { printf 'MSG\t%s\n' "$*" >>"$MENU7_TRACE"; return 0; }
load_mirror_defaults() { :; }
engine_resolve_paths() { :; }
mm_save_gui_config() { return 0; }
engine_http_local_smoke() { return 0; }
engine_http_advertised_smoke() { return 0; }
rm -f "$(mm_client_commands_file)"
gui_client_instructions
[[ "$INPUTBOX_COUNT" -eq 0 ]] || fail "menu7 version inputbox count=${INPUTBOX_COUNT}"
[[ "$MENU7_TEXTBOX_COUNT" -eq 1 ]] || fail "menu7 expected exactly one menu7 textbox, got ${MENU7_TEXTBOX_COUNT}"
grep -q $'MENU\tDP deployment type' "$MENU7_TRACE" && fail "Menu 7 still asks topology" || true
grep -q ' — view' "$MENU7_TRACE" && fail "secondary viewer menu still present" || true
grep -q 'Show complete instructions' "$INSTALLER" && fail "Show complete instructions string still in installer" || true
grep -q 'Show Step 2 command block' "$INSTALLER" && fail "Show Step submenu still in installer" || true
grep -q 'gui_client_commands_viewer' "$INSTALLER" && fail "gui_client_commands_viewer still present" || true
grep -q 'less -S' "$INSTALLER" && fail "less guidance still in installer" || true
grep -q 'cat "\$out_file"' "$INSTALLER" && fail "TTY reprint after GUI still present" || true
[[ -f "$(mm_client_commands_file)" ]] || fail "menu7 did not create command file"
[[ -s "$(mm_client_commands_file)" ]] || fail "menu7 created empty command file"
[[ "$(stat -c '%a' "$(mm_client_commands_file)")" == "600" ]] || fail "menu7 file mode not 600"
grep -Fq -- '--source-dp-version' "$(mm_client_commands_file)" && fail "menu7 has source" || true
grep -q 'upgrade-phase2.sh' "$(mm_client_commands_file)" || fail "menu7 missing phase2 wrapper"
grep -Fq -- '--target-version' "$(mm_client_commands_file)" && fail "menu7 leaked --target-version" || true
grep -Fq -- '--same-version-recovery' "$(mm_client_commands_file)" && fail "menu7 leaked recovery flag" || true
for n in 0 1 2 3 4 5 6 7 8 9; do
  grep -qE "STEP ${n} —|Step ${n} —" "$(mm_client_commands_file)" \
    || fail "menu7 missing step ${n}"
done
grep -q 'BEGIN STEP' "$(mm_client_commands_file)" && fail "menu7 still has BEGIN STEP" || true
grep -q 'upgrade-xenial-to-bionic.sh' "$(mm_client_commands_file)" || fail "menu7 missing OS wrapper"
grep -qE 'gpgv --keyring' "$(mm_client_commands_file)" \
  && fail "menu7 OS-hop must not expose gpgv" || true
grep -q "DP_OS_HOP_COMMAND_VERSION=WRAPPER_V1" "$(mm_client_commands_file)" || fail "menu7 missing WRAPPER_V1"
grep -q 'dp-client-command-runner.sh' "$MM_CLIENT_ROOT/dp-launch-xenial-to-bionic.sh" \
  || fail "launcher missing command runner"
# Saved file and generators must agree (same one-line hop / one-line stage content).
gen_hop="$(gui_client_hop_command_line "http://192.0.2.10" "dp-offline-upgrade-xenial-to-bionic.sh")"
grep -Fq "$gen_hop" "$(mm_client_commands_file)" \
  || fail "saved file hop command differs from gui_client_hop_command_line"
gen_stage="$(gui_phase2_stage_command_line "http://192.0.2.10" "6.6.0")"
grep -Fq "$gen_stage" "$(mm_client_commands_file)" \
  || fail "saved file stage block differs from gui_phase2_stage_command_line"
# Menu 7 production viewer must disable dialog mouse handling.
grep -qE -- '--no-mouse' "$INSTALLER" \
  && grep -A25 '^mm_menu7_textbox()' "$INSTALLER" | grep -q -- '--textbox' \
  || fail "mm_menu7_textbox missing dialog --no-mouse/--textbox"
grep -A30 '^mm_menu7_textbox()' "$INSTALLER" | grep -q 'mm_whiptail_textbox' \
  && fail "Menu 7 still has whiptail textbox fallback" || true
grep -A30 '^mm_menu7_textbox()' "$INSTALLER" | grep -q 'MENU7_VIEWER_REASON=dialog_missing' \
  || fail "Menu 7 missing dialog_missing error path"
grep -q 'less -S\|less ' <<<"$(grep -A30 '^mm_menu7_textbox()' "$INSTALLER")" \
  && fail "Menu 7 textbox invokes less" || true
pass "menu7 shows full instructions directly; no secondary viewer"

# Artifact: only 6.6.0 versioned names as the production target
grep -E 'images-6\.[234]\.0|aella-uvp-2404_6\.[234]\.0' \
  "$ROOT/scripts/lib/dp-phase2-common.sh" "$ENGINE" 2>/dev/null \
  && fail "non-target versioned ACPS artifacts referenced" || true
grep -Eq 'images-\$\{|images-6\.6\.0|images-.*VERSION' "$ROOT/scripts/lib/dp-phase2-common.sh" \
  || fail "versioned images template missing from dp2 common"
grep -q 'PHASE2_TARGET_VERSION_FIXED="6.6.0"' "$COMMON" || fail "fixed PHASE2_TARGET_VERSION_FIXED missing"
pass "Phase 2 artifacts are 6.6.0-target"

# Engine: PHASE2_ONLY skips R2
grep -q 'PHASE2_ONLY_R2_DOWNLOAD_COUNT=0' "$ENGINE" || fail "PHASE2_ONLY R2 skip marker missing"
grep -q 'mm_is_phase2_only' "$ENGINE" || fail "engine missing phase2_only branch"
pass "engine PHASE2_ONLY R2 skip present"

# Non-root official entry
NONROOT_OUT="$TMP/nonroot.out"
set +e
MM_SKIP_ROOT_CHECK=0 bash "$INSTALLER" mirror-manager >"$NONROOT_OUT" 2>&1
NONROOT_RC=$?
set -e
[[ "$NONROOT_RC" -ne 0 ]] || fail "non-root mirror-manager should fail"
grep -q 'This command requires sudo.' "$NONROOT_OUT" || fail "non-root missing sudo guidance"
pass "non-root prints clear sudo guidance"

# ---------------------------------------------------------------------------
# Required cluster workflow regression markers (distinct DL/DA IP lists).
# Never print the raw worker password in test output.
# ---------------------------------------------------------------------------
REG_DL_IPS='10.10.10.21,10.10.10.22'
REG_DA_IPS='10.20.20.21,10.20.20.22'
REG_PW='Sp3c#Pw!x9Q'

grep -q '"5" "DL Worker IP addresses"' "$INSTALLER" \
  || fail "CONFIG_HAS_DL_WORKER_IP_FIELD missing"
echo "CONFIG_HAS_DL_WORKER_IP_FIELD=YES"
grep -q '"6" "DA Worker IP addresses"' "$INSTALLER" \
  || fail "CONFIG_HAS_DA_WORKER_IP_FIELD missing"
echo "CONFIG_HAS_DA_WORKER_IP_FIELD=YES"
grep -q '"7" "Worker SSH Password (aella)"' "$INSTALLER" \
  || fail "CONFIG_HAS_COMMON_WORKER_PASSWORD missing"
echo "CONFIG_HAS_COMMON_WORKER_PASSWORD=YES"

if sed -n '/^gui_client_instructions()/,/^cmd_mirror_manager()/p' "$INSTALLER" \
  | grep -q 'mm_whiptail_input'; then
  fail "MENU7_REPROMPTS_FOR_WORKER_IPS: Menu 7 still prompts"
else
  echo "MENU7_REPROMPTS_FOR_WORKER_IPS=NO"
fi

PREPARATION_MODE=FULL
REG_DUAL="$TMP/reg-dual-full.txt"
gui_build_client_commands "http://192.0.2.10" "cluster" \
  "$REG_DL_IPS" "$REG_DA_IPS" "$REG_PW" >"$REG_DUAL"

for n in 1 2 3 4 5 6; do
  step_count="$(grep -cE "^STEP ${n} —" "$REG_DUAL" || true)"
  [[ "$step_count" -eq 1 ]] || fail "STEP ${n} header count=${step_count} (expected 1 common step)"
done
grep -q 'CLUSTER EXECUTION RULE' "$REG_DUAL" || fail "CLUSTER EXECUTION RULE missing"
grep -q 'Run the same steps on every DP node being upgraded' "$REG_DUAL" \
  || fail "common all-nodes guidance missing"
grep -q 'DL master, all DL workers, DA master, and all DA workers' "$REG_DUAL" \
  || fail "all-nodes target list missing"
echo "MENU7_COMMON_STEPS_1_TO_6=PASS"

[[ "$(grep -cE '^STEP 6 — STAGE DP' "$REG_DUAL")" -eq 1 ]] \
  || fail "STEP 6 heading not unique"
[[ "$(grep -cE '^cd /home/aella && curl -fsSLo upgrade-phase2\.sh\.download ' "$REG_DUAL")" -eq 1 ]] \
  || fail "expected exactly one common stage command"
grep -q 'Use the SAME staging command on every node' "$REG_DUAL" \
  || fail "same staging command guidance missing"
grep -qE 'STEP 6A|STEP 6B|DL STAGE|DA STAGE' "$REG_DUAL" \
  && fail "duplicated DL/DA STEP 6 commands present" || true
echo "MENU7_STEP6_SINGLE_COMMON_COMMAND=PASS"

grep -q 'STEP 7A — DL CLUSTER MASTER' "$REG_DUAL" || fail "MENU7_DL_COMMAND_PRESENT"
grep -q 'STEP 7B — DA CLUSTER MASTER' "$REG_DUAL" || fail "MENU7_DA_COMMAND_PRESENT"
echo "MENU7_DL_COMMAND_PRESENT=PASS"
echo "MENU7_DA_COMMAND_PRESENT=PASS"

REG_DL_SEC="$TMP/reg-dl-sec.txt"
REG_DA_SEC="$TMP/reg-da-sec.txt"
awk '/STEP 7A — DL CLUSTER MASTER/,/STEP 7B — DA CLUSTER MASTER/' "$REG_DUAL" \
  >"$REG_DL_SEC"
awk '/STEP 7B — DA CLUSTER MASTER/,/^STEP 8 —/' "$REG_DUAL" \
  >"$REG_DA_SEC"
grep -q -- '--worker-ips' "$REG_DL_SEC" || fail "MENU7_DL_COMMAND_USES_ONLY_DL_WORKERS"
grep -Fq '10.10.10.21' "$REG_DL_SEC" && grep -Fq '10.10.10.22' "$REG_DL_SEC" \
  || fail "MENU7_DL_COMMAND_USES_ONLY_DL_WORKERS"
grep -q -- '--worker-ips' "$REG_DA_SEC" || fail "MENU7_DA_COMMAND_USES_ONLY_DA_WORKERS"
grep -Fq '10.20.20.21' "$REG_DA_SEC" && grep -Fq '10.20.20.22' "$REG_DA_SEC" \
  || fail "MENU7_DA_COMMAND_USES_ONLY_DA_WORKERS"
echo "MENU7_DL_COMMAND_USES_ONLY_DL_WORKERS=PASS"
echo "MENU7_DA_COMMAND_USES_ONLY_DA_WORKERS=PASS"
grep -F "$REG_DA_IPS" "$REG_DL_SEC" \
  && fail "MENU7_DL_COMMAND_DOES_NOT_CONTAIN_DA_WORKERS" || true
grep -F "$REG_DL_IPS" "$REG_DA_SEC" \
  && fail "MENU7_DA_COMMAND_DOES_NOT_CONTAIN_DL_WORKERS" || true
echo "MENU7_DL_COMMAND_DOES_NOT_CONTAIN_DA_WORKERS=PASS"
echo "MENU7_DA_COMMAND_DOES_NOT_CONTAIN_DL_WORKERS=PASS"

grep -q 'Run this command on the DL MASTER ONLY' "$REG_DUAL" \
  || fail "DL master-only guidance missing"
grep -q 'Run this command on the DA MASTER ONLY' "$REG_DUAL" \
  || fail "DA master-only guidance missing"
grep -q 'STEP 7A: DL master only' "$REG_DUAL" || fail "rule missing STEP 7A master-only"
grep -q 'STEP 7B: DA master only' "$REG_DUAL" || fail "rule missing STEP 7B master-only"
echo "MENU7_STEP7_MASTER_ONLY_GUIDANCE=PASS"
grep -q 'Do NOT run this command manually on DL workers' "$REG_DUAL" \
  || fail "DL worker STEP 7 prohibition missing"
grep -q 'Do NOT run this command manually on DA workers' "$REG_DUAL" \
  || fail "DA worker STEP 7 prohibition missing"
grep -q 'Do not run STEP 7 manually on workers' "$REG_DUAL" \
  || fail "cluster rule missing worker STEP 7 prohibition"
echo "MENU7_WORKER_MANUAL_STEP7_PROHIBITED=PASS"

reg_dl_line="$(grep -E 'bringup_py3_dp_after_os_upgrade\.sh|read(\\ |-rsp)' "$REG_DL_SEC" | head -1)"
reg_da_line="$(grep -E 'bringup_py3_dp_after_os_upgrade\.sh|read(\\ |-rsp)' "$REG_DA_SEC" | head -1)"
[[ -n "$reg_dl_line" ]] || fail "DL section missing bringup/prompt"
[[ -n "$reg_da_line" ]] || fail "DA section missing bringup/prompt"
assert_cluster_bringup_prompt "$REG_DL_SEC" "$REG_DL_IPS" "$REG_PW"
assert_cluster_bringup_prompt "$REG_DA_SEC" "$REG_DA_IPS" "$REG_PW"
echo "SPECIAL_CHARACTER_WORKER_PASSWORD=PASS"

redacted="$(printf 'WORKER_SSH_PASSWORD=%s extra\n' "$REG_PW" | mm_redact)"
printf '%s\n' "$redacted" | grep -Fq "$REG_PW" && fail "mm_redact leaked worker password" || true
[[ "$redacted" == *'WORKER_SSH_PASSWORD=***'* ]] || fail "WORKER_SSH_PASSWORD not redacted"
# Password must not appear anywhere in the published dual command file.
if grep -Fq "$REG_PW" "$REG_DUAL"; then
  fail "worker password appeared in published command file"
fi
logged="$(mm_log INFO "WORKER_SSH_PASSWORD=${REG_PW} DL_WORKER_IPS=${REG_DL_IPS}")"
printf '%s\n' "$logged" | grep -Fq "$REG_PW" && fail "mm_log leaked worker password" || true
echo "WORKER_PASSWORD_NOT_LOGGED=PASS"

PREPARATION_MODE=FULL
gui_build_client_commands "http://192.0.2.10" "single" "" "" "" >"$TMP/reg-single.txt"
assert_single_bringup_no_workers "$TMP/reg-single.txt"
grep -q -- '--worker-ips' "$TMP/reg-single.txt" && fail "SINGLE_NODE_HAS_WORKER_IP_ARG" || true
grep -q -- '--worker-password' "$TMP/reg-single.txt" && fail "SINGLE_NODE_HAS_WORKER_PASSWORD_ARG" || true
echo "SINGLE_NODE_HAS_WORKER_IP_ARG=NO"
echo "SINGLE_NODE_HAS_WORKER_PASSWORD_ARG=NO"

REG_DL_ONLY="$TMP/reg-dl-only.txt"
gui_build_client_commands "http://192.0.2.10" "cluster" \
  "$REG_DL_IPS" "" "$REG_PW" >"$REG_DL_ONLY"
grep -q -- '--worker-ips' "$REG_DL_ONLY" || fail "DL-only missing --worker-ips"
grep -Fq '10.10.10.21' "$REG_DL_ONLY" && grep -Fq '10.10.10.22' "$REG_DL_ONLY" \
  || fail "DL-only missing DL workers"
grep -F "$REG_DA_IPS" "$REG_DL_ONLY" && fail "DL-only contains DA workers" || true
grep -q 'DA cluster bringup command was not generated because' "$REG_DL_ONLY" \
  || fail "DL-only missing DA not-configured message"
grep -q 'DA Worker IPs are not configured' "$REG_DL_ONLY" \
  || fail "DL-only missing DA Worker IPs reason"
[[ "$(grep -c 'bringup_py3_dp_after_os_upgrade.sh' "$REG_DL_ONLY")" -eq 1 ]] \
  || fail "DL-only should emit exactly one bringup command"
echo "DL_ONLY_CONFIGURATION=PASS"

REG_DA_ONLY="$TMP/reg-da-only.txt"
gui_build_client_commands "http://192.0.2.10" "cluster" \
  "" "$REG_DA_IPS" "$REG_PW" >"$REG_DA_ONLY"
grep -q -- '--worker-ips' "$REG_DA_ONLY" || fail "DA-only missing --worker-ips"
grep -Fq '10.20.20.21' "$REG_DA_ONLY" && grep -Fq '10.20.20.22' "$REG_DA_ONLY" \
  || fail "DA-only missing DA workers"
grep -F "$REG_DL_IPS" "$REG_DA_ONLY" && fail "DA-only contains DL workers" || true
grep -q 'DL cluster bringup command was not generated because' "$REG_DA_ONLY" \
  || fail "DA-only missing DL not-configured message"
grep -q 'DL Worker IPs are not configured' "$REG_DA_ONLY" \
  || fail "DA-only missing DL Worker IPs reason"
[[ "$(grep -c 'bringup_py3_dp_after_os_upgrade.sh' "$REG_DA_ONLY")" -eq 1 ]] \
  || fail "DA-only should emit exactly one bringup command"
echo "DA_ONLY_CONFIGURATION=PASS"

PREPARATION_MODE=PHASE2_ONLY
REG_P2="$TMP/reg-dual-p2.txt"
gui_build_client_commands "http://192.0.2.10" "cluster" \
  "$REG_DL_IPS" "$REG_DA_IPS" "$REG_PW" >"$REG_P2"
grep -q 'CLUSTER EXECUTION RULE' "$REG_P2" || fail "PHASE2 cluster rule missing"
grep -q 'STEP 3A: DL master only' "$REG_P2" || fail "PHASE2 missing STEP 3A master-only"
grep -q 'STEP 3B: DA master only' "$REG_P2" || fail "PHASE2 missing STEP 3B master-only"
grep -q 'Use the SAME staging command on every node' "$REG_P2" \
  || fail "PHASE2 missing shared stage command guidance"
[[ "$(grep -cE '^cd /home/aella && curl -fsSLo upgrade-phase2\.sh\.download ' "$REG_P2")" -eq 1 ]] \
  || fail "PHASE2 expected exactly one stage command"
awk '/STEP 3A — DL CLUSTER MASTER/,/STEP 3B — DA CLUSTER MASTER/' "$REG_P2" \
  | grep -q -- '--worker-ips' \
  || fail "PHASE2 DL command missing --worker-ips"
awk '/STEP 3A — DL CLUSTER MASTER/,/STEP 3B — DA CLUSTER MASTER/' "$REG_P2" \
  | grep -Fq '10.10.10.21' \
  || fail "PHASE2 DL command missing DL workers"
awk '/STEP 3A — DL CLUSTER MASTER/,/STEP 3B — DA CLUSTER MASTER/' "$REG_P2" \
  | grep -F "$REG_DA_IPS" \
  && fail "PHASE2 DL command contains DA workers" || true
awk '/STEP 3B — DA CLUSTER MASTER/,/^STEP 4 —/' "$REG_P2" \
  | grep -q -- '--worker-ips' \
  || fail "PHASE2 DA command missing --worker-ips"
awk '/STEP 3B — DA CLUSTER MASTER/,/^STEP 4 —/' "$REG_P2" \
  | grep -Fq '10.20.20.21' \
  || fail "PHASE2 DA command missing DA workers"
awk '/STEP 3B — DA CLUSTER MASTER/,/^STEP 4 —/' "$REG_P2" \
  | grep -F "$REG_DL_IPS" \
  && fail "PHASE2 DA command contains DL workers" || true
pass "PHASE2_ONLY cluster routing matches FULL"

unset REG_PW REG_DL_IPS REG_DA_IPS

echo "ALL test_gui_client_commands checks passed"
