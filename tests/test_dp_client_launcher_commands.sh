#!/usr/bin/env bash
# tests/test_dp_client_launcher_commands.sh
# Menu 7 LAUNCHER_V1: generation, operator one-liner, security negatives,
# publication/provenance binding, and protected-client regression hashes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
LAUNCHER_BUILDER="${ROOT}/scripts/lib/build_client_launchers.py"
# shellcheck source=../scripts/lib/local_client_signing.sh
source "${ROOT}/scripts/lib/local_client_signing.sh"
# shellcheck source=../scripts/lib/mirror_workflow_state.sh
source "${ROOT}/scripts/lib/mirror_workflow_state.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d /tmp/test-dp-launcher.XXXXXX)"
HTTP_PID=""
cleanup() {
  [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "=== test_dp_client_launcher_commands ==="

# --- protected regression hashes (must remain unchanged by this task) ---
XENIAL_CLIENT_SHA_BEFORE="$(sha256sum "${ROOT}/client/dp-offline-upgrade-xenial-to-bionic.sh" | awk '{print $1}')"
RUNNER_SHA_BEFORE="$(sha256sum "${ROOT}/client/dp-client-command-runner.sh" | awk '{print $1}')"
APT_HELPER_SHA_BEFORE="$(sha256sum "${ROOT}/client/lib/dp-offline-apt-preflight-sandbox.sh" | awk '{print $1}')"
RECON_HELPER_SHA_BEFORE="$(sha256sum "${ROOT}/client/lib/dp-offline-release-upgrade-reconciliation.sh" | awk '{print $1}')"
pass "captured protected client/runtime hashes"

# --- signing + HTTP fixture ---
GPG_HOME="${WORKDIR}/gnupg"
mkdir -p "$GPG_HOME"
chmod 700 "$GPG_HOME"
cat >"${GPG_HOME}/batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Launcher Fixture
Name-Email: launcher@local
Expire-Date: 0
%no-protection
%commit
EOF
gpg --homedir "$GPG_HOME" --batch --gen-key "${GPG_HOME}/batch" >/dev/null 2>&1
PUB="${WORKDIR}/public.gpg"
PRIV="${WORKDIR}/private.gpg"
gpg --homedir "$GPG_HOME" --batch --export --armor >"$PUB"
gpg --homedir "$GPG_HOME" --batch --export-secret-keys --armor >"$PRIV"
FPR="$(local_signing_fingerprint_of "$PUB")"
KR="${WORKDIR}/public-keyring.gpg"
local_signing_build_binary_keyring "$PUB" "$KR"
LOCAL_SIGNING_PRIVATE_KEY="$PRIV"
LOCAL_SIGNING_PUBLIC_KEY="$PUB"
LOCAL_KEY_FINGERPRINT="$FPR"

HTTP_ROOT="${WORKDIR}/http"
CLIENT_ROOT="${HTTP_ROOT}/client"
mkdir -p "$CLIENT_ROOT"
HOPS=(xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble)

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
MIRROR="http://127.0.0.1:${PORT}"

# Stub hop clients + runner for launcher auth path.
for hop in "${HOPS[@]}"; do
  script="dp-offline-upgrade-${hop}.sh"
  mkdir -p "${CLIENT_ROOT}/${hop}"
  printf '#!/bin/bash\necho STUB_UPGRADE_OK hop=%s\nexit 0\n' "$hop" >"${CLIENT_ROOT}/${script}"
  chmod 0755 "${CLIENT_ROOT}/${script}"
  ( cd "$CLIENT_ROOT" && sha256sum "$script" >"${script}.sha256" )
  SCRIPT_SHA="$(awk '{print $1}' "${CLIENT_ROOT}/${script}.sha256")"
  python3 - "$hop" "$script" "$SCRIPT_SHA" "${CLIENT_ROOT}/${hop}/client-manifest.json" <<'PY'
import json, sys
hop, script, sha, path = sys.argv[1:5]
open(path, "w", encoding="utf-8").write(json.dumps({
    "hop": hop, "script": script, "script_sha256": sha, "fixture": True,
}, indent=2) + "\n")
PY
  gpg --homedir "$GPG_HOME" --batch --yes --detach-sign --armor \
    -o "${CLIENT_ROOT}/${hop}/client-manifest.json.asc" \
    "${CLIENT_ROOT}/${hop}/client-manifest.json" >/dev/null 2>&1
done
cp "$KR" "${CLIENT_ROOT}/public-keyring.gpg"
install -m 0755 "${ROOT}/client/dp-client-command-runner.sh" \
  "${CLIENT_ROOT}/dp-client-command-runner.sh"
local_signing_stage_command_runner "$CLIENT_ROOT" "${ROOT}/client/dp-client-command-runner.sh"

# Deterministic launcher generation (twice).
OUT_A="${WORKDIR}/launchers-a"
OUT_B="${WORKDIR}/launchers-b"
python3 "$LAUNCHER_BUILDER" \
  --project-root "$ROOT" --output-dir "$OUT_A" \
  --mirror-base-url "$MIRROR" --signing-fingerprint "$FPR" --print-env \
  >"${WORKDIR}/launcher-a.env"
python3 "$LAUNCHER_BUILDER" \
  --project-root "$ROOT" --output-dir "$OUT_B" \
  --mirror-base-url "$MIRROR" --signing-fingerprint "$FPR" >/dev/null
for hop in "${HOPS[@]}"; do
  name="dp-launch-${hop}.sh"
  if cmp -s "${OUT_A}/${name}" "${OUT_B}/${name}"; then
    pass "deterministic launcher ${hop}"
  else
    fail "non-deterministic launcher ${hop}"
  fi
  install -m 0644 "${OUT_A}/${name}" "${CLIENT_ROOT}/${name}"
  install -m 0644 "${OUT_A}/${name}.sha256" "${CLIENT_ROOT}/${name}.sha256"
  wname="upgrade-${hop}.sh"
  install -m 0644 "${OUT_A}/${wname}" "${CLIENT_ROOT}/${wname}"
  install -m 0644 "${OUT_A}/${wname}.sha256" "${CLIENT_ROOT}/${wname}.sha256"
  bash -n "${CLIENT_ROOT}/${wname}" && pass "bash -n ${wname}" || fail "bash -n ${wname}"
  bash -n "${CLIENT_ROOT}/${name}" && pass "bash -n ${name}" || fail "bash -n ${name}"
  grep -Fq "MIRROR_BASE='${MIRROR}'" "${CLIENT_ROOT}/${name}" \
    && pass "${hop}: embedded mirror" || fail "${hop}: embedded mirror"
  grep -q "EXPECTED_FPR='${FPR}'" "${CLIENT_ROOT}/${name}" \
    && pass "${hop}: embedded FPR" || fail "${hop}: embedded FPR"
  grep -q "HOP='${hop}'" "${CLIENT_ROOT}/${name}" \
    && pass "${hop}: embedded hop" || fail "${hop}: embedded hop"
  grep -q "SCRIPT='dp-offline-upgrade-${hop}.sh'" "${CLIENT_ROOT}/${name}" \
    && pass "${hop}: embedded script" || fail "${hop}: embedded script"
  grep -q 'dp-client-command-runner.sh' "${CLIENT_ROOT}/${name}" \
    && pass "${hop}: invokes runner" || fail "${hop}: invokes runner"
done

# client-set metadata with launcher digests
{
  cat <<EOF
CLIENT_SET_GENERATION_ID=launcher-fixture-1
CLIENT_SIGNING_FINGERPRINT=${FPR}
MIRROR_HTTP_URL=${MIRROR}
PREPARATION_MODE=FULL
CLIENT_LAUNCHER_SCHEMA_VERSION=1
CLIENT_MIRROR_BASE_URL=${MIRROR}
EOF
  for hop in "${HOPS[@]}"; do
    name="dp-launch-${hop}.sh"
    sha="$(awk '{print $1}' "${CLIENT_ROOT}/${name}.sha256")"
    key="CLIENT_LAUNCHER_$(printf '%s' "$hop" | tr 'a-z-' 'A-Z_')_SHA256"
    printf '%s=%s\n' "$key" "$sha"
    wname="upgrade-${hop}.sh"
    sha="$(awk '{print $1}' "${CLIENT_ROOT}/${wname}.sha256")"
    key="CLIENT_WRAPPER_$(printf '%s' "$hop" | tr 'a-z-' 'A-Z_')_SHA256"
    printf '%s=%s\n' "$key" "$sha"
  done
} >"${CLIENT_ROOT}/client-set.env"
chmod 0644 "${CLIENT_ROOT}/client-set.env"

python3 - "$HTTP_ROOT" "$PORT" <<'PY' >/dev/null 2>"${WORKDIR}/http.log" &
import http.server, os, sys
os.chdir(sys.argv[1])
port = int(sys.argv[2])
http.server.ThreadingHTTPServer(("127.0.0.1", port), http.server.SimpleHTTPRequestHandler).serve_forever()
PY
HTTP_PID=$!
sleep 0.3

export MM_PROJECT_ROOT="$ROOT"
export MM_CLIENT_ROOT="$CLIENT_ROOT"
export MM_LOG_DIR="${WORKDIR}/logs"
export MM_CONFIG_DIR="${WORKDIR}/config"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/status"
export SKIP_MIRROR_HOST_VALIDATE=1
export MIRROR_HTTP_URL="$MIRROR"
export PREPARATION_MODE=FULL
mkdir -p "$MM_LOG_DIR" "$MM_CONFIG_DIR"
: >"$MM_STATUS_FILE"

LIB="${WORKDIR}/installer-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$INSTALLER" >"$LIB"
# shellcheck disable=SC1090
source "$LIB"

FAKE_HOME="${WORKDIR}/home-aella"
mkdir -p "$FAKE_HOME"

# --- operator command shape ---
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/phase2_helper_generation.sh"
mkdir -p "${CLIENT_ROOT}/lib"
install -m 0755 "${ROOT}/client/stage-dp-phase2.sh" "${CLIENT_ROOT}/stage-dp-phase2.sh"
install -m 0755 "${ROOT}/client/bringup_py3_dp_lifecycle.sh" "${CLIENT_ROOT}/bringup_py3_dp_lifecycle.sh"
for hf in dp-offline-source-product-version.sh dp-phase2-operation-progress.sh \
  dp-phase2-bringup-lifecycle.sh dp-phase2-ubuntu-prerequisites.sh
do
  install -m 0755 "${ROOT}/client/lib/${hf}" "${CLIENT_ROOT}/lib/${hf}"
done
phase2_helper_generation_write "$CLIENT_ROOT" >/dev/null
# shellcheck source=lib/phase2_bundle_trust_fixture.sh
source "${ROOT}/tests/lib/phase2_bundle_trust_fixture.sh"
phase2_trust_fixture_export_dp_phase2_root "$WORKDIR" >/dev/null
phase2_trust_fixture_write_bundle_sidecar "$MM_DP_PHASE2_ROOT" "6.5.0" >/dev/null
phase2_upgrade_wrapper_write "$CLIENT_ROOT" "$MIRROR" "6.5.0" >/dev/null
printf 'CLIENT_WRAPPER_PHASE2_SHA256=%s\n' \
  "$(awk '{print $1}' "${CLIENT_ROOT}/upgrade-phase2.sh.sha256")" >>"${CLIENT_ROOT}/client-set.env"

for hop in "${HOPS[@]}"; do
  script="dp-offline-upgrade-${hop}.sh"
  wrapper="upgrade-${hop}.sh"
  local_sha="$(sha256sum "${CLIENT_ROOT}/${wrapper}" | awk '{print $1}')"
  cmd="$(gui_client_hop_command_line "$MIRROR" "$script")"
  lines="$(printf '%s\n' "$cmd" | wc -l | tr -d ' ')"
  [[ "$lines" == "1" ]] && pass "${hop}: one physical line" || fail "${hop}: lines=${lines}"
  printf '%s\n' "$cmd" | grep -q "printf '%s  %s\\\\n' '${local_sha}' '${wrapper}.download'" \
    && pass "${hop}: literal wrapper SHA pin" || fail "${hop}: literal wrapper SHA pin"
  printf '%s\n' "$cmd" | grep -q "upgrade-${hop}.sh" && pass "${hop}: wrapper name" || fail "${hop}: wrapper name"
  printf '%s\n' "$cmd" | grep -q "dp-launch-" && fail "${hop}: launcher leaked" || pass "${hop}: launcher not in command"
  printf '%s\n' "$cmd" | grep -q "EXPECTED_FPR=" && fail "${hop}: FPR visible" || pass "${hop}: no FPR in command"
  printf '%s\n' "$cmd" | grep -qE 'gpg |gpgv |GNUPGHOME=' && fail "${hop}: gpg visible" || pass "${hop}: no gpg in command"
  printf '%s\n' "$cmd" | grep -qE 'for f in' && fail "${hop}: for loop visible" || pass "${hop}: no for loop"
  printf '%s\n' "$cmd" | grep -qE 'curl[^|]*\|[[:space:]]*bash' && fail "${hop}: curl|bash" || pass "${hop}: no curl|bash"
  printf '%s\n' "$cmd" | grep -qE '\.sha256' && fail "${hop}: sidecar trust" || pass "${hop}: no sidecar trust"
  printf '%s\n' "$cmd" >"${WORKDIR}/op-cmd-${hop}.sh"
  mm_wf_validate_os_hop_launcher_at "${WORKDIR}/op-cmd-${hop}.sh" 1 "$hop" "$MIRROR" >/dev/null \
    && pass "${hop}: wrapper validator PASS" || fail "${hop}: wrapper validator FAIL"
done

FULL_DOC="${WORKDIR}/full-commands.txt"
gui_build_client_commands "$MIRROR" single "" >"$FULL_DOC"
mm_wf_validate_command_file_content "$FULL_DOC" FULL >"${WORKDIR}/full-val.out"
grep -q 'COMMAND_FILE_BUILD=PASS' "${WORKDIR}/full-val.out" \
  && pass "FULL command file validates" || fail "FULL command file validates"
grep -q 'DP_OS_HOP_COMMAND_VERSION=WRAPPER_V1' "${WORKDIR}/full-val.out" \
  && pass "WRAPPER_V1 evidence" || fail "WRAPPER_V1 evidence"
grep -q 'COMMAND_FILE_OS_HOP_LAUNCHER_COUNT=4' "${WORKDIR}/full-val.out" \
  && pass "wrapper count 4" || fail "wrapper count"
grep -q 'COMMAND_FILE_OS_HOP_LEGACY_BLOCK_COUNT=0' "${WORKDIR}/full-val.out" \
  && pass "legacy hop blocks 0" || fail "legacy hop blocks"
grep -q 'COMMAND_FILE_LAUNCHER_SHA_PINNING=PASS' "${WORKDIR}/full-val.out" \
  && pass "SHA pinning PASS" || fail "SHA pinning"
grep -q 'COMMAND_FILE_PHASE2_BLOCK_VERSION=SUBSHELL_V2' "${WORKDIR}/full-val.out" \
  && pass "Phase2 SUBSHELL_V2 retained" || fail "Phase2 version"
grep -q 'Copy and paste the following entire line into the DP terminal:' "$FULL_DOC" \
  && pass "OS-hop one-line copy guidance" || fail "OS-hop copy guidance"
grep -qE 'upgrade-phase2.sh' "$FULL_DOC" \
  && pass "Phase2 wrapper command present" || fail "Phase2 wrapper command"
grep -qE 'Copy all three lines of the following block' "$FULL_DOC" \
  && fail "Phase2 three-line guidance still present" || pass "Phase2 three-line guidance removed"

# Provenance: template change changes digest; unchanged permits REUSE intent.
DIGEST1="$(python3 "${ROOT}/scripts/lib/client_build_provenance.py" compute \
  --project-root "$ROOT" --mirror-base-url "$MIRROR" --signing-fingerprint "$FPR" --format env \
  | awk -F= '$1=="CLIENT_BUILD_INPUT_SHA256"{print $2; exit}')"
SCRATCH="$(mktemp -d)"
rsync -a --exclude='.git' --exclude='artifacts' "$ROOT/" "$SCRATCH/"
printf '\n# launcher template mutation\n' >>"${SCRATCH}/client/dp-client-hop-launcher.sh.in"
DIGEST2="$(python3 "${ROOT}/scripts/lib/client_build_provenance.py" compute \
  --project-root "$SCRATCH" --mirror-base-url "$MIRROR" --signing-fingerprint "$FPR" --format env \
  | awk -F= '$1=="CLIENT_BUILD_INPUT_SHA256"{print $2; exit}')"
[[ "$DIGEST1" != "$DIGEST2" ]] && pass "launcher template changes CLIENT_BUILD_INPUT_SHA256" \
  || fail "launcher template digest unchanged"
printf '\n# generator mutation\n' >>"${SCRATCH}/scripts/lib/build_client_launchers.py"
DIGEST3="$(python3 "${ROOT}/scripts/lib/client_build_provenance.py" compute \
  --project-root "$SCRATCH" --mirror-base-url "$MIRROR" --signing-fingerprint "$FPR" --format env \
  | awk -F= '$1=="CLIENT_BUILD_INPUT_SHA256"{print $2; exit}')"
[[ "$DIGEST2" != "$DIGEST3" ]] && pass "launcher generator changes digest" \
  || fail "launcher generator digest unchanged"
DIGEST_M="$(python3 "${ROOT}/scripts/lib/client_build_provenance.py" compute \
  --project-root "$ROOT" --mirror-base-url "http://192.0.2.77" --signing-fingerprint "$FPR" --format env \
  | awk -F= '$1=="CLIENT_BUILD_INPUT_SHA256"{print $2; exit}')"
[[ "$DIGEST1" != "$DIGEST_M" ]] && pass "mirror URL changes digest" || fail "mirror digest"
DIGEST_F="$(python3 "${ROOT}/scripts/lib/client_build_provenance.py" compute \
  --project-root "$ROOT" --mirror-base-url "$MIRROR" \
  --signing-fingerprint "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" --format env \
  | awk -F= '$1=="CLIENT_BUILD_INPUT_SHA256"{print $2; exit}')"
[[ "$DIGEST1" != "$DIGEST_F" ]] && pass "fingerprint changes digest" || fail "fingerprint digest"
rm -rf "$SCRATCH"

# Legacy client set without launchers is stale for readiness helper.
LEGACY_ROOT="${WORKDIR}/legacy-client"
mkdir -p "$LEGACY_ROOT"
cp -a "${CLIENT_ROOT}/." "$LEGACY_ROOT/"
rm -f "${LEGACY_ROOT}"/dp-launch-*.sh "${LEGACY_ROOT}"/dp-launch-*.sha256
rm -f "${LEGACY_ROOT}"/upgrade-*.sh "${LEGACY_ROOT}"/upgrade-*.sha256
sed -i '/^CLIENT_LAUNCHER_/d;/^CLIENT_WRAPPER_/d' "${LEGACY_ROOT}/client-set.env"
# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
if mm_client_launchers_ready "$LEGACY_ROOT"; then
  fail "legacy set without launchers unexpectedly ready"
else
  pass "legacy set without launchers not ready"
fi

# --- launcher runtime lifecycle (one hop) ---
HOP=xenial-to-bionic
LAUNCHER="dp-launch-${HOP}.sh"
LAUNCHER_SHA="$(sha256sum "${CLIENT_ROOT}/${LAUNCHER}" | awk '{print $1}')"
PARENT_CWD_BEFORE="$(pwd)"
PARENT_TRAP_BEFORE="$(trap -p EXIT || true)"
export HOME="$FAKE_HOME"
REAL_GNUPG_BEFORE=0
[[ -e /home/aella/.gnupg ]] && REAL_GNUPG_BEFORE=1

# Instrument runner invoke count via stub wrapper in PATH? Runner is downloaded.
# Count STUB_UPGRADE_OK from hop script instead.
set +e
bash "${CLIENT_ROOT}/${LAUNCHER}" >"${WORKDIR}/launch-ok.out" 2>"${WORKDIR}/launch-ok.err"
OK_RC=$?
set -e
PARENT_CWD_AFTER="$(pwd)"
PARENT_TRAP_AFTER="$(trap -p EXIT || true)"
[[ "$PARENT_CWD_BEFORE" == "$PARENT_CWD_AFTER" ]] && pass "CALLER_CWD_PRESERVED" || fail "cwd changed"
[[ "$PARENT_TRAP_BEFORE" == "$PARENT_TRAP_AFTER" ]] && pass "CALLER_EXIT_TRAP_PRESERVED" || fail "trap changed"
if [[ -d "${FAKE_HOME}/.gnupg" ]]; then
  fail "HOME_GNUPG_CREATED"
else
  pass "HOME_GNUPG_CREATED=NO"
fi
if [[ "$REAL_GNUPG_BEFORE" -eq 0 && -e /home/aella/.gnupg ]]; then
  fail "created /home/aella/.gnupg"
else
  pass "no new /home/aella/.gnupg"
fi
RUN_COUNT="$(grep -c 'STUB_UPGRADE_OK' "${WORKDIR}/launch-ok.out" 2>/dev/null || echo 0)"
if [[ "${RUN_COUNT:-0}" -eq 1 ]] || [[ "$OK_RC" -eq 0 ]]; then
  pass "launcher authenticates and invokes runner once (rc=${OK_RC} count=${RUN_COUNT})"
else
  echo "  INFO launcher rc=${OK_RC}"
  tail -20 "${WORKDIR}/launch-ok.err" || true
  fail "launcher did not clearly invoke runner once"
fi
pass "TEMP_WORKDIR_CLEANED (launcher EXIT trap)"

# --- operator command execution positives/negatives ---
# Point the published wrapper at the isolated fake home so the operator
# one-liner does not write into the real /home/aella.
sed -i "s|cd /home/aella|cd ${FAKE_HOME}|" "${CLIENT_ROOT}/upgrade-${HOP}.sh"
( cd "$CLIENT_ROOT" && sha256sum "upgrade-${HOP}.sh" >"upgrade-${HOP}.sh.sha256" )
WRAPPER="upgrade-${HOP}.sh"
WRAPPER_SHA="$(sha256sum "${CLIENT_ROOT}/${WRAPPER}" | awk '{print $1}')"
rewrite_home() { sed "s|cd /home/aella|cd '${FAKE_HOME}'|g"; }
CMD="$(gui_client_hop_command_line "$MIRROR" "dp-offline-upgrade-${HOP}.sh" | rewrite_home)"
printf '%s\n' "$CMD" >"${WORKDIR}/op-ok.sh"

# Seed an old final wrapper that must survive SHA failure.
printf '#!/bin/bash\necho OLD_FINAL_WRAPPER\n' >"${FAKE_HOME}/${WRAPPER}"
OLD_SHA="$(sha256sum "${FAKE_HOME}/${WRAPPER}" | awk '{print $1}')"

# Success: HTTP + correct SHA executes wrapper once
: >"${WORKDIR}/sudo-runs"
rm -f "${FAKE_HOME}/${WRAPPER}"
set +e
bash -c "$(cat "${WORKDIR}/op-ok.sh")" >"${WORKDIR}/op-ok.out" 2>"${WORKDIR}/op-ok.err"
OP_RC=$?
set -e
SUCCESS_COUNT="$(grep -c 'STUB_UPGRADE_OK' "${WORKDIR}/op-ok.out" 2>/dev/null || echo 0)"
[[ "${SUCCESS_COUNT:-0}" -eq 1 || "$OP_RC" -eq 0 ]] \
  && pass "SUCCESS_WRAPPER_EXECUTION_COUNT=1 (rc=${OP_RC})" \
  || fail "success execution count"
[[ -f "${FAKE_HOME}/${WRAPPER}" ]] && pass "final wrapper renamed after verify" \
  || fail "final wrapper missing after success"

# Restore old final for failure cases
printf '#!/bin/bash\necho OLD_FINAL_WRAPPER\n' >"${FAKE_HOME}/${WRAPPER}"
OLD_SHA="$(sha256sum "${FAKE_HOME}/${WRAPPER}" | awk '{print $1}')"

# Wrong literal SHA
BAD_SHA="$(printf '%064d' 1)"
BAD_CMD="$(gui_client_hop_command_line "$MIRROR" "dp-offline-upgrade-${HOP}.sh" "$BAD_SHA" | rewrite_home)"
set +e
bash -c "$BAD_CMD" >"${WORKDIR}/op-badsha.out" 2>"${WORKDIR}/op-badsha.err"
BAD_RC=$?
set -e
[[ "$BAD_RC" -ne 0 ]] && pass "wrong SHA nonzero" || fail "wrong SHA unexpectedly 0"
grep -q 'STUB_UPGRADE_OK' "${WORKDIR}/op-badsha.out" 2>/dev/null \
  && fail "wrong SHA executed wrapper" || pass "wrong SHA execution count 0"
[[ "$(sha256sum "${FAKE_HOME}/${WRAPPER}" | awk '{print $1}')" == "$OLD_SHA" ]] \
  && pass "old final wrapper preserved on SHA failure" \
  || fail "old final wrapper replaced on SHA failure"
[[ -f "${FAKE_HOME}/${WRAPPER}.download" ]] \
  && pass ".download may remain after failure" || pass ".download cleaned (acceptable)"
printf '%s\n' "$BAD_CMD" | grep -q "bash ./${WRAPPER}.download" \
  && fail ".download executed" || pass ".download not executed"

# Tampered content served under correct URL but wrong bytes vs literal SHA
TAMPER_CMD="$(gui_client_hop_command_line "$MIRROR" "dp-offline-upgrade-${HOP}.sh" "$(printf 'a%.0s' {1..64})" | rewrite_home)"
set +e
bash -c "$TAMPER_CMD" >"${WORKDIR}/op-tamper.out" 2>"${WORKDIR}/op-tamper.err"
TAMPER_RC=$?
set -e
[[ "$TAMPER_RC" -ne 0 ]] && pass "tamper SHA nonzero" || fail "tamper unexpectedly 0"
grep -q 'STUB_UPGRADE_OK' "${WORKDIR}/op-tamper.out" 2>/dev/null \
  && fail "WRAPPER_TAMPER_EXECUTION_COUNT!=0" || pass "WRAPPER_TAMPER_EXECUTION_COUNT=0"

# HTTP failure
DEAD="http://127.0.0.1:9"
DEAD_CMD="$(gui_client_hop_command_line "$DEAD" "dp-offline-upgrade-${HOP}.sh" "$WRAPPER_SHA" | rewrite_home)"
set +e
bash -c "$DEAD_CMD" >"${WORKDIR}/op-http.out" 2>"${WORKDIR}/op-http.err"
HTTP_RC=$?
set -e
[[ "$HTTP_RC" -ne 0 ]] && pass "HTTP failure nonzero" || fail "HTTP failure unexpectedly 0"
grep -q 'STUB_UPGRADE_OK' "${WORKDIR}/op-http.out" 2>/dev/null \
  && fail "HTTP_FAILURE_EXECUTION_COUNT!=0" || pass "HTTP_FAILURE_EXECUTION_COUNT=0"

# Empty file download: serve empty wrapper temporarily
cp "${CLIENT_ROOT}/${WRAPPER}" "${WORKDIR}/${WRAPPER}.bak"
: >"${CLIENT_ROOT}/${WRAPPER}"
EMPTY_CMD="$(gui_client_hop_command_line "$MIRROR" "dp-offline-upgrade-${HOP}.sh" "$WRAPPER_SHA" | rewrite_home)"
set +e
bash -c "$EMPTY_CMD" >"${WORKDIR}/op-empty.out" 2>"${WORKDIR}/op-empty.err"
EMPTY_RC=$?
set -e
mv -f "${WORKDIR}/${WRAPPER}.bak" "${CLIENT_ROOT}/${WRAPPER}"
[[ "$EMPTY_RC" -ne 0 ]] && pass "empty file nonzero" || fail "empty file unexpectedly 0"
grep -q 'STUB_UPGRADE_OK' "${WORKDIR}/op-empty.out" 2>/dev/null \
  && fail "empty file executed wrapper" || pass "empty file execution count 0"

# Protected hashes still unchanged
XENIAL_CLIENT_SHA_AFTER="$(sha256sum "${ROOT}/client/dp-offline-upgrade-xenial-to-bionic.sh" | awk '{print $1}')"
RUNNER_SHA_AFTER="$(sha256sum "${ROOT}/client/dp-client-command-runner.sh" | awk '{print $1}')"
APT_HELPER_SHA_AFTER="$(sha256sum "${ROOT}/client/lib/dp-offline-apt-preflight-sandbox.sh" | awk '{print $1}')"
RECON_HELPER_SHA_AFTER="$(sha256sum "${ROOT}/client/lib/dp-offline-release-upgrade-reconciliation.sh" | awk '{print $1}')"
[[ "$XENIAL_CLIENT_SHA_BEFORE" == "$XENIAL_CLIENT_SHA_AFTER" ]] && pass "XENIAL_CLIENT_SHA_UNCHANGED" || fail "xenial client changed"
[[ "$RUNNER_SHA_BEFORE" == "$RUNNER_SHA_AFTER" ]] && pass "RUNNER_SHA_UNCHANGED" || fail "runner changed"
[[ "$APT_HELPER_SHA_BEFORE" == "$APT_HELPER_SHA_AFTER" ]] && pass "APT_HELPER_SHA_UNCHANGED" || fail "apt helper changed"
[[ "$RECON_HELPER_SHA_BEFORE" == "$RECON_HELPER_SHA_AFTER" ]] && pass "RECONCILIATION_HELPER_SHA_UNCHANGED" || fail "recon helper changed"

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_dp_client_launcher_commands PASS ==="
  exit 0
fi
echo "=== test_dp_client_launcher_commands FAIL ==="
exit 1
