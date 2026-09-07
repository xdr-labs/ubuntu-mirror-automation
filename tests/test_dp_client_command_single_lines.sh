#!/usr/bin/env bash
# tests/test_dp_client_command_single_lines.sh
# Validate DP hop commands are LAUNCHER_V1 one-liners; Phase 2 stage remains 2–3 lines.
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
mkdir -p "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$MM_CLIENT_ROOT"
: >"$MM_STATUS_FILE"
PREPARATION_MODE=FULL
MIRROR_HTTP_URL="http://192.0.2.55"
MIRROR="http://192.0.2.55"
FPR="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

python3 "$LAUNCHER_BUILDER" \
  --project-root "$ROOT" \
  --output-dir "$MM_CLIENT_ROOT" \
  --mirror-base-url "$MIRROR" \
  --signing-fingerprint "$FPR" >/dev/null

LIB="$TMP/installer-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$INSTALLER" >"$LIB"
# shellcheck disable=SC1090
source "$LIB"

echo "=== test_dp_client_command_launcher_v1 ==="

HOPS=(
  "dp-offline-upgrade-xenial-to-bionic.sh"
  "dp-offline-upgrade-bionic-to-focal.sh"
  "dp-offline-upgrade-focal-to-jammy.sh"
  "dp-offline-upgrade-jammy-to-noble.sh"
)

for script in "${HOPS[@]}"; do
  hop="${script#dp-offline-upgrade-}"
  hop="${hop%.sh}"
  launcher="dp-launch-${hop}.sh"
  local_sha="$(sha256sum "${MM_CLIENT_ROOT}/${launcher}" | awk '{print $1}')"
  block="$(gui_client_hop_command_line "$MIRROR" "$script")"
  printf '%s\n' "$block" >"${TMP}/block-${hop}.sh"
  lines="$(wc -l <"${TMP}/block-${hop}.sh" | tr -d ' ')"
  [[ "$lines" == "1" ]] && pass "${hop}: exactly one physical line" || fail "${hop}: lines=${lines}"
  grep -qE "^cd /home/aella && curl -fsSLo ${launcher}\.download ${MIRROR}/client/${launcher}" "${TMP}/block-${hop}.sh" \
    && pass "${hop}: download form" || fail "${hop}: download form"
  grep -q "'${local_sha}'" "${TMP}/block-${hop}.sh" \
    && pass "${hop}: literal SHA matches published launcher" || fail "${hop}: SHA mismatch"
  grep -q "sha256sum -c - && mv -f ${launcher}.download ${launcher} && bash ./${launcher}" "${TMP}/block-${hop}.sh" \
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

stage="$(gui_phase2_stage_command_line "$MIRROR" "6.5.0")"
mapfile -t stage_lines < <(printf '%s\n' "$stage")
[[ "${#stage_lines[@]}" -ge 2 && "${#stage_lines[@]}" -le 3 ]] \
  && pass "phase2-stage: ${#stage_lines[@]} physical lines" \
  || fail "phase2-stage: unexpected line count ${#stage_lines[@]}"
printf '%s\n' "$stage" >"${TMP}/stage.sh"
grep -q 'stage-dp-phase2.sh' "${TMP}/stage.sh" \
  && pass "stage: script name" || fail "stage: script name"
grep -q "MIRROR='${MIRROR}'" "${TMP}/stage.sh" \
  && pass "stage: configured mirror" || fail "stage: mirror"
grep -q "GEN='phase2-helper-generation.manifest'" "${TMP}/stage.sh" \
  && pass "stage: generation manifest" || fail "stage: generation manifest"
grep -q 'sha256sum -c -' "${TMP}/stage.sh" \
  && pass "stage: pinned manifest hash" || fail "stage: pinned manifest hash"
grep -q 'sha256sum -c "$GEN"' "${TMP}/stage.sh" \
  && pass "stage: verify helpers against manifest" || fail "stage: helper verify"
grep -qE 'SCRIPT\.sha256' "${TMP}/stage.sh" \
  && fail "stage: HTTP sidecar still used as trust anchor" \
  || pass "stage: no sidecar trust anchor"
bash -n "${TMP}/stage.sh" && pass "stage: bash -n" || fail "stage: bash -n"
grep -qE 'BASH_SUBSHELL' "${TMP}/stage.sh" \
  && pass "stage: BASH_SUBSHELL guard" || fail "stage: missing BASH_SUBSHELL"
grep -qE '^\( ' "${TMP}/stage.sh" \
  && pass "stage: opens with (" || fail "stage: missing ("
[[ "${stage_lines[0]}" =~ \\[[:space:]]*$ ]] \
  && pass "stage: non-final line has backslash" || fail "stage: missing continuation"

OUT="$TMP/full.txt"
gui_build_client_commands "$MIRROR" "single" "" >"$OUT"
bringup="$(grep -E 'bringup_py3_dp_after_os_upgrade\.sh' "$OUT" | head -1)"
[[ "$(printf '%s\n' "$bringup" | wc -l | tr -d ' ')" == "1" ]] \
  && pass "bringup: one physical line" || fail "bringup: not one line"
grep -q 'BEGIN STEP\|END STEP' "$OUT" && fail "BEGIN/END in full doc" || true
grep -q 'DP_OS_HOP_COMMAND_VERSION=LAUNCHER_V1' "$OUT" \
  && pass "LAUNCHER_V1 in doc" || fail "missing LAUNCHER_V1"
grep -q 'DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2' "$OUT" \
  && pass "DP_COMMAND_BLOCK_VERSION in doc" || fail "missing block version"
grep -q 'Copy and paste the following entire line into the DP terminal:' "$OUT" \
  && pass "OS-hop one-line guidance" || fail "missing OS-hop guidance"
grep -qE 'Copy the complete three-line block|first two lines must end with backslash' "$OUT" \
  && pass "Phase2 three-line guidance retained" || fail "missing Phase2 guidance"
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

if declare -F gui_client_hop_command_line >/dev/null; then
  pass "gui_client_hop_command_line defined"
else
  fail "gui_client_hop_command_line missing"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_dp_client_command_launcher_v1 PASS ==="
  exit 0
fi
echo "=== test_dp_client_command_launcher_v1 FAIL ==="
exit 1
