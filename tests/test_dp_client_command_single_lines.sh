#!/usr/bin/env bash
# tests/test_dp_client_command_single_lines.sh
# Validate DP hop / Phase2 stage commands are WRAPPER_V1 one-liners.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
LAUNCHER_BUILDER="${ROOT}/scripts/lib/build_client_launchers.py"

# shellcheck source=lib/portable_ip_policy.sh
source "${ROOT}/tests/lib/portable_ip_policy.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_PROJECT_ROOT="$ROOT"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_LOG_DIR="$TMP/logs"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$TMP/config/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$TMP/config/status"
export MM_CLIENT_ROOT="$TMP/client"
export SCRIPT_DIR="${ROOT}/scripts"
mkdir -p "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$MM_CLIENT_ROOT/lib"
: >"$MM_STATUS_FILE"
PREPARATION_MODE=FULL
PHASE2_TARGET_VERSION=6.6.0
TARGET_DP_VERSION=6.6.0
MIRROR_HTTP_URL="http://192.0.2.55"
MIRROR="http://192.0.2.55"
FPR="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

python3 "$LAUNCHER_BUILDER" \
  --project-root "$ROOT" \
  --output-dir "$MM_CLIENT_ROOT" \
  --mirror-base-url "$MIRROR" \
  --signing-fingerprint "$FPR" \
  --expected-keyring-sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" \
    --expected-client-build-input-sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >/dev/null

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/phase2_helper_generation.sh"
install -m 0755 "${ROOT}/client/stage-dp-phase2.sh" "${MM_CLIENT_ROOT}/stage-dp-phase2.sh"
install -m 0755 "${ROOT}/client/bringup_py3_dp_lifecycle.sh" "${MM_CLIENT_ROOT}/bringup_py3_dp_lifecycle.sh"
while IFS= read -r f; do
  [[ "$f" == lib/* ]] || continue
  install -m 0755 "${ROOT}/client/$f" "${MM_CLIENT_ROOT}/$f"
done < <(phase2_helper_generation_files)
phase2_helper_generation_write "$MM_CLIENT_ROOT" >/dev/null
# shellcheck source=lib/phase2_bundle_trust_fixture.sh
source "${ROOT}/tests/lib/phase2_bundle_trust_fixture.sh"
phase2_trust_fixture_export_dp_phase2_root "$TMP" >/dev/null
phase2_trust_fixture_write_bundle_sidecar "$MM_DP_PHASE2_ROOT" "6.6.0" >/dev/null
phase2_upgrade_wrapper_write "$MM_CLIENT_ROOT" "$MIRROR" "6.6.0" >/dev/null

LIB="$TMP/installer-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$INSTALLER" >"$LIB"
# shellcheck disable=SC1090
source "$LIB"

echo "=== test_dp_client_command_wrapper_v1 ==="

HOPS=(
  "dp-offline-upgrade-xenial-to-bionic.sh"
  "dp-offline-upgrade-bionic-to-focal.sh"
  "dp-offline-upgrade-focal-to-jammy.sh"
  "dp-offline-upgrade-jammy-to-noble.sh"
)

for script in "${HOPS[@]}"; do
  hop="${script#dp-offline-upgrade-}"
  hop="${hop%.sh}"
  wrapper="upgrade-${hop}.sh"
  local_sha="$(sha256sum "${MM_CLIENT_ROOT}/${wrapper}" | awk '{print $1}')"
  block="$(gui_client_hop_command_line "$MIRROR" "$script")"
  printf '%s\n' "$block" >"${TMP}/block-${hop}.sh"
  lines="$(wc -l <"${TMP}/block-${hop}.sh" | tr -d ' ')"
  [[ "$lines" == "1" ]] && pass "${hop}: exactly one physical line" || fail "${hop}: lines=${lines}"
  grep -qE "^cd /home/aella && curl -fsSLo ${wrapper}\.download ${MIRROR}/client/${wrapper}" "${TMP}/block-${hop}.sh" \
    && pass "${hop}: download form" || fail "${hop}: download form"
  grep -q "'${local_sha}'" "${TMP}/block-${hop}.sh" \
    && pass "${hop}: literal SHA matches published wrapper" || fail "${hop}: SHA mismatch"
  grep -q "sha256sum -c - && mv -f ${wrapper}.download ${wrapper} && bash ./${wrapper}" "${TMP}/block-${hop}.sh" \
    && pass "${hop}: verify→mv→bash order" || fail "${hop}: order"
  grep -qE 'EXPECTED_FPR=|gpgv |GNUPGHOME=|for f in|BASH_SUBSHELL' "${TMP}/block-${hop}.sh" \
    && fail "${hop}: legacy bootstrap leaked" || pass "${hop}: no legacy bootstrap"
  grep -qE 'curl[^|]*\|[[:space:]]*bash' "${TMP}/block-${hop}.sh" \
    && fail "${hop}: curl|bash" || pass "${hop}: no curl|bash"
  grep -qE '\.sha256' "${TMP}/block-${hop}.sh" \
    && fail "${hop}: sidecar trust" || pass "${hop}: no sidecar trust"
  if portable_ip_policy_assert_file "hop-${hop}" "${TMP}/block-${hop}.sh"; then
    pass "${hop}: portable IP policy"
  else
    fail "${hop}: non-portable IP literal in generated hop command"
  fi
  bash -n "${TMP}/block-${hop}.sh" && pass "${hop}: bash -n PASS" || fail "${hop}: bash -n FAIL"
done

stage="$(gui_phase2_stage_command_line "$MIRROR" "6.6.0")"
mapfile -t stage_lines < <(printf '%s\n' "$stage")
[[ "${#stage_lines[@]}" -eq 1 ]] \
  && pass "phase2-stage: exactly one physical WRAPPER_V1 line" \
  || fail "phase2-stage: unexpected line count ${#stage_lines[@]}"
printf '%s\n' "$stage" >"${TMP}/stage.sh"
grep -q 'upgrade-phase2.sh' "${TMP}/stage.sh" \
  && pass "stage: wrapper name" || fail "stage: wrapper name"
grep -q "sha256sum -c -" "${TMP}/stage.sh" \
  && pass "stage: pinned wrapper hash" || fail "stage: pinned wrapper hash"
grep -qE 'SCRIPT\.sha256|phase2-helper-generation\.manifest' "${TMP}/stage.sh" \
  && fail "stage: HTTP sidecar / manifest still used as operator trust anchor" \
  || pass "stage: no sidecar trust anchor in operator command"
bash -n "${TMP}/stage.sh" && pass "stage: bash -n" || fail "stage: bash -n"
grep -qE 'BASH_SUBSHELL|^\( ' "${TMP}/stage.sh" \
  && fail "stage: legacy subshell leaked into operator command" \
  || pass "stage: no legacy subshell in operator command"

OUT="$TMP/full.txt"
gui_build_client_commands "$MIRROR" "single" "" >"$OUT"
bringup="$(grep -E '^sudo bash /home/aella/bringup_py3_dp_after_os_upgrade\.sh --version ' "$OUT" | head -1)"
[[ -n "$bringup" ]] && pass "bringup: executable line present" || fail "bringup: missing executable"
[[ "$(printf '%s\n' "$bringup" | wc -l | tr -d ' ')" == "1" ]] \
  && pass "bringup: one physical line" || fail "bringup: not one line"
grep -q 'BEGIN STEP\|END STEP' "$OUT" && fail "BEGIN/END in full doc" || true
grep -q 'DP_OS_HOP_COMMAND_VERSION=WRAPPER_V1' "$OUT" \
  && pass "WRAPPER_V1 in doc" || fail "missing WRAPPER_V1"
grep -q 'DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2' "$OUT" \
  && pass "DP_COMMAND_BLOCK_VERSION in doc" || fail "missing block version"
grep -q 'Copy and paste the following entire line into the DP terminal:' "$OUT" \
  && pass "OS-hop one-line guidance" || fail "missing OS-hop guidance"
grep -qE 'Copy all three lines of the following block|first two lines must end with backslash' "$OUT" \
  && fail "Phase2 three-line guidance still present" || pass "Phase2 three-line guidance removed"
# OS-hop sections must not tell operators to copy three lines / parentheses / SUBSHELL_V2 for hops.
python3 - "$OUT" <<'PY' || fail "OS-hop section still has three-line paste instructions"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
# Between STEP 2 and STEP 6 should not say "Copy all three lines"
m = re.search(r"STEP 2 —.*?(?=STEP 6 —)", text, re.S)
if not m:
    raise SystemExit(1)
chunk = m.group(0)
for bad in (
    "Copy all three lines of the following block",
    "opening parenthesis",
    "first two lines must end with backslash",
    "SUBSHELL_V2 is required for the OS-hop",
):
    if bad in chunk:
        raise SystemExit(2)
raise SystemExit(0)
PY
pass "OS-hop sections use one-line paste guidance only"

# shellcheck source=../scripts/lib/mirror_workflow_state.sh
source "${ROOT}/scripts/lib/mirror_workflow_state.sh"
mm_wf_validate_command_file_content "$OUT" FULL >"$TMP/val.out"
grep -q 'COMMAND_FILE_BUILD=PASS' "$TMP/val.out" && pass "FULL validation PASS" || fail "FULL validation"
grep -q 'COMMAND_FILE_OS_HOP_LAUNCHER_COUNT=4' "$TMP/val.out" && pass "launcher count 4" || fail "launcher count"
grep -q 'COMMAND_FILE_BRINGUP_EXECUTABLE_COUNT=1' "$TMP/val.out" \
  && pass "bringup executable count 1" || fail "bringup executable count"

if declare -F gui_client_hop_command_line >/dev/null; then
  pass "gui_client_hop_command_line defined"
else
  fail "gui_client_hop_command_line missing"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_dp_client_command_wrapper_v1 PASS ==="
  exit 0
fi
echo "=== test_dp_client_command_wrapper_v1 FAIL ==="
exit 1
