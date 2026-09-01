#!/usr/bin/env bash
# Verify Menu 7 DISPLAY wraps WRAPPER_V1 commands to 3 continuation lines
# without changing the canonical command file, and that upgrade-phase2.sh
# still fetches the complete helper unit over HTTP.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="${ROOT}/scripts/ubuntu-offline-mirror-entrypoint.sh"
TMP="$(mktemp -d)"
HTTP_PID=""
cleanup() {
  if [[ -n "$HTTP_PID" ]]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)"
MIRROR="http://127.0.0.1:${PORT}"
SHA="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
HOPS=(xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble)
CANONICAL="${TMP}/canonical.txt"
DISPLAY="${TMP}/display.txt"
FORMAT_LOG="${TMP}/format.log"

HTTP_ROOT="${TMP}/http"
CLIENT_ROOT="${HTTP_ROOT}/client"
mkdir -p "${CLIENT_ROOT}/lib" "${TMP}/fakebin"
cat >"${CLIENT_ROOT}/stage-dp-phase2.sh" <<'STAGE'
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for req in \
  lib/dp-offline-source-product-version.sh \
  lib/dp-phase2-operation-progress.sh \
  lib/dp-phase2-bringup-lifecycle.sh \
  lib/dp-phase2-ubuntu-prerequisites.sh \
  bringup_py3_dp_lifecycle.sh \
  phase2-helper-generation.manifest
do
  [[ -s "${here}/${req}" ]] || { printf 'MISSING=%s\n' "$req"; exit 1; }
done
source "${here}/lib/dp-offline-source-product-version.sh"
source "${here}/lib/dp-phase2-operation-progress.sh"
printf 'PHASE2_HELPER_FETCH_E2E=PASS\n'
printf 'PHASE2_STUB_ARGS=%s\n' "$*"
STAGE
cat >"${CLIENT_ROOT}/lib/dp-offline-source-product-version.sh" <<'HELPER1'
#!/usr/bin/env bash
SOURCE_HELPER_LOADED=YES
HELPER1
cat >"${CLIENT_ROOT}/lib/dp-phase2-operation-progress.sh" <<'HELPER2'
#!/usr/bin/env bash
PROGRESS_HELPER_LOADED=YES
HELPER2
cat >"${CLIENT_ROOT}/lib/dp-phase2-bringup-lifecycle.sh" <<'HELPER3'
#!/usr/bin/env bash
LIFECYCLE_LIB_LOADED=YES
HELPER3
cat >"${CLIENT_ROOT}/lib/dp-phase2-ubuntu-prerequisites.sh" <<'HELPER5'
#!/usr/bin/env bash
PREREQ_HELPER_LOADED=YES
HELPER5
cat >"${CLIENT_ROOT}/bringup_py3_dp_lifecycle.sh" <<'HELPER4'
#!/usr/bin/env bash
LIFECYCLE_WRAPPER_LOADED=YES
HELPER4
chmod +x "${CLIENT_ROOT}/stage-dp-phase2.sh" "${CLIENT_ROOT}/bringup_py3_dp_lifecycle.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/phase2_helper_generation.sh"
phase2_helper_generation_write "$CLIENT_ROOT" >/dev/null
phase2_upgrade_wrapper_write "$CLIENT_ROOT" "$MIRROR" "6.6.0" >/dev/null
P2_SHA="$(sha256sum "${CLIENT_ROOT}/upgrade-phase2.sh" | awk '{print $1}')"
bash -n "${CLIENT_ROOT}/upgrade-phase2.sh"

{
  cat <<'EOF_HEADER'
DP Client Upgrade Commands
==========================

DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2
DP_OS_HOP_COMMAND_VERSION=WRAPPER_V1

OS-hop steps use one hash-pinned wrapper command per hop (DP_OS_HOP_COMMAND_VERSION=WRAPPER_V1).
The Phase 2 staging step uses one hash-pinned wrapper command (upgrade-phase2.sh).
EOF_HEADER
  for hop in "${HOPS[@]}"; do
    wrapper="upgrade-${hop}.sh"
    cat <<EOF_HOP

STEP — ${hop}

Copy and paste the following entire line into the DP terminal:

cd /home/aella && curl -fsSLo ${wrapper}.download ${MIRROR}/client/${wrapper} && printf '%s  %s\\n' '${SHA}' '${wrapper}.download' | sha256sum -c - && mv -f ${wrapper}.download ${wrapper} && bash ./${wrapper}
EOF_HOP
  done
  cat <<EOF_PHASE2

STEP 6 — STAGE DP 6.6.0 FILES

CLUSTER:
Run STEP 6 on the DL master, every DL worker,
the DA master, and every DA worker.

Complete STEP 6 on ALL cluster nodes before starting STEP 7.

Use the SAME staging command on every node.

Copy and paste the following entire line into the DP terminal:

cd /home/aella && curl -fsSLo upgrade-phase2.sh.download ${MIRROR}/client/upgrade-phase2.sh && printf '%s  %s\\n' '${P2_SHA}' 'upgrade-phase2.sh.download' | sha256sum -c - && mv -f upgrade-phase2.sh.download upgrade-phase2.sh && bash ./upgrade-phase2.sh
EOF_PHASE2
} >"$CANONICAL"

canonical_before="$(sha256sum "$CANONICAL" | awk '{print $1}')"
bash "$WRAPPER" --format-menu7 "$CANONICAL" "$DISPLAY" 2>"$FORMAT_LOG"
canonical_after="$(sha256sum "$CANONICAL" | awk '{print $1}')"
[[ "$canonical_before" == "$canonical_after" ]]

grep -q 'MENU7_DISPLAY_FORMAT=PASS wrapped_launchers=4 wrapped_phase2=1' "$FORMAT_LOG"
grep -Fq 'CLUSTER:' "$DISPLAY"
grep -Fq 'Run STEP 6 on the DL master, every DL worker,' "$DISPLAY"
grep -Fq 'Complete STEP 6 on ALL cluster nodes before starting STEP 7.' "$DISPLAY"
grep -Fq 'Use the SAME staging command on every node.' "$DISPLAY"
[[ "$(grep -cF 'Copy and paste all 3 lines together into the DP terminal:' "$DISPLAY")" -eq 5 ]]
! grep -Fq 'Copy and paste the following entire line into the DP terminal:' "$DISPLAY"
grep -Fq 'Copy and paste the following entire line into the DP terminal:' "$CANONICAL"
[[ "$(grep -cE "^cd /home/aella && F='upgrade-" "$DISPLAY")" -eq 5 ]]
[[ "$(grep -cE '^cd /home/aella && curl -fsSLo upgrade-' "$DISPLAY")" -eq 0 ]]
[[ "$(grep -cF "U='${MIRROR}/client'" "$DISPLAY")" -eq 5 ]]
[[ "$(grep -c '^cd /home/aella && L=' "$DISPLAY")" -eq 0 ]]
[[ "$(grep -c '^( C=' "$DISPLAY")" -eq 0 ]]
! grep -q 'for F in' "$DISPLAY"
! grep -q 'BASH_SUBSHELL' "$DISPLAY"
! grep -Eq 'curl[^|;]*\|[[:space:]]*(bash|sh)([[:space:]]|$)' "$DISPLAY"
! grep -q 'dp-launch-' "$DISPLAY"

extract_wrapper_block() {
  local wrapper="$1" dest="$2" src="${3:-$DISPLAY}"
  python3 - "$src" "$wrapper" "$dest" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
wrapper = sys.argv[2]
prefix = "cd /home/aella && F='%s'" % wrapper
found = []
for i, line in enumerate(text):
    if line.startswith(prefix):
        if i + 2 >= len(text):
            raise SystemExit("incomplete display block for %s" % wrapper)
        found.append(text[i:i + 3])
if len(found) != 1:
    raise SystemExit("expected 1 display block for %s, got %s" % (wrapper, len(found)))
Path(sys.argv[3]).write_text("\n".join(found[0]) + "\n", encoding="utf-8")
PY
}

assert_three_line_block() {
  local block="$1" wrapper="$2" sha="$3" mirror="$4"
  local l1 l2 l3
  [[ "$(wc -l <"$block" | tr -d ' ')" -eq 3 ]]
  l1="$(sed -n '1p' "$block")"
  l2="$(sed -n '2p' "$block")"
  l3="$(sed -n '3p' "$block")"
  [[ "${l1: -1}" == '\' ]]
  [[ "${l2: -1}" == '\' ]]
  [[ "$l1" == "${l1%"${l1##*[![:space:]]}"}" ]]
  [[ "$l2" == "${l2%"${l2##*[![:space:]]}"}" ]]
  [[ "${l3: -1}" != '\' ]]
  grep -Fq "F='${wrapper}'" "$block"
  grep -Fq "H='${sha}'" "$block"
  grep -Fq "U='${mirror}/client'" "$block"
  grep -Fq "${mirror}/client" "$block"
  grep -Fq 'curl -fsSLo "$D" "$U/$F"' "$block"
  grep -Fq 'sha256sum -c -' "$block"
  ! grep -Eq 'curl[^|;]*\|[[:space:]]*(bash|sh)([[:space:]]|$)' "$block"
  ! grep -Fq '.sha256' "$block"
  ! grep -q 'dp-launch-' "$block"
  ! grep -q 'for F in' "$block"
  bash -n "$block"
}

MAX_COMMAND_DISPLAY_WIDTH=0
MAX_ALLOWED_COMMAND_WIDTH=125
for hop in "${HOPS[@]}"; do
  block="${TMP}/${hop}.sh"
  extract_wrapper_block "upgrade-${hop}.sh" "$block"
  assert_three_line_block "$block" "upgrade-${hop}.sh" "$SHA" "$MIRROR"
  while IFS= read -r cline; do
    clen="${#cline}"
    [[ "$clen" -gt "$MAX_COMMAND_DISPLAY_WIDTH" ]] && MAX_COMMAND_DISPLAY_WIDTH="$clen"
    [[ "$clen" -le "$MAX_ALLOWED_COMMAND_WIDTH" ]]
  done <"$block"
done

phase2_block="${TMP}/phase2.sh"
extract_wrapper_block "upgrade-phase2.sh" "$phase2_block"
assert_three_line_block "$phase2_block" "upgrade-phase2.sh" "$P2_SHA" "$MIRROR"
! grep -q 'mktemp' "$phase2_block"
! grep -q 'phase2-helper-generation.manifest' "$phase2_block"
while IFS= read -r cline; do
  clen="${#cline}"
  [[ "$clen" -gt "$MAX_COMMAND_DISPLAY_WIDTH" ]] && MAX_COMMAND_DISPLAY_WIDTH="$clen"
  [[ "$clen" -le "$MAX_ALLOWED_COMMAND_WIDTH" ]]
done <"$phase2_block"

# Prove the 125-column bound with the current field mirror URL.
PROD_MIRROR="http://221.139.249.112"
PROD_CANONICAL="${TMP}/prod-canonical.txt"
PROD_DISPLAY="${TMP}/prod-display.txt"
sed "s#${MIRROR}#${PROD_MIRROR}#g" "$CANONICAL" >"$PROD_CANONICAL"
prod_before="$(sha256sum "$PROD_CANONICAL" | awk '{print $1}')"
bash "$WRAPPER" --format-menu7 "$PROD_CANONICAL" "$PROD_DISPLAY" 2>"${TMP}/prod-format.log"
prod_after="$(sha256sum "$PROD_CANONICAL" | awk '{print $1}')"
[[ "$prod_before" == "$prod_after" ]]
grep -q 'MENU7_DISPLAY_FORMAT=PASS wrapped_launchers=4 wrapped_phase2=1' "${TMP}/prod-format.log"
[[ "$(grep -cF "U='${PROD_MIRROR}/client'" "$PROD_DISPLAY")" -eq 5 ]]
for hop in "${HOPS[@]}"; do
  block="${TMP}/prod-${hop}.sh"
  extract_wrapper_block "upgrade-${hop}.sh" "$block" "$PROD_DISPLAY"
  assert_three_line_block "$block" "upgrade-${hop}.sh" "$SHA" "$PROD_MIRROR"
  while IFS= read -r cline; do
    clen="${#cline}"
    [[ "$clen" -gt "$MAX_COMMAND_DISPLAY_WIDTH" ]] && MAX_COMMAND_DISPLAY_WIDTH="$clen"
    [[ "$clen" -le "$MAX_ALLOWED_COMMAND_WIDTH" ]]
  done <"$block"
done
prod_phase2_block="${TMP}/prod-phase2.sh"
extract_wrapper_block "upgrade-phase2.sh" "$prod_phase2_block" "$PROD_DISPLAY"
assert_three_line_block "$prod_phase2_block" "upgrade-phase2.sh" "$P2_SHA" "$PROD_MIRROR"
while IFS= read -r cline; do
  clen="${#cline}"
  [[ "$clen" -gt "$MAX_COMMAND_DISPLAY_WIDTH" ]] && MAX_COMMAND_DISPLAY_WIDTH="$clen"
  [[ "$clen" -le "$MAX_ALLOWED_COMMAND_WIDTH" ]]
done <"$prod_phase2_block"

cat >"${TMP}/fakebin/sudo" <<'SUDO'
#!/usr/bin/env bash
exec "$@"
SUDO
chmod +x "${TMP}/fakebin/sudo"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$HTTP_ROOT" \
  >"${TMP}/http.log" 2>&1 &
HTTP_PID=$!
for _ in $(seq 1 50); do
  curl -fsS "${MIRROR}/client/stage-dp-phase2.sh" >/dev/null 2>&1 && break
  sleep 0.1
done
(
  cd "$TMP"
  PATH="${TMP}/fakebin:${PATH}" bash "$phase2_block" >"${TMP}/phase2.out"
)
grep -q '^PHASE2_HELPER_FETCH_E2E=PASS$' "${TMP}/phase2.out"
grep -q -- '--target-version 6.6.0 --mirror-url' "${TMP}/phase2.out" \
  || fail "phase2 wrapper missing normal stage invocation"
grep -q -- '--same-version-recovery' "${TMP}/phase2.out" \
  && fail "normal wrapper must not force same-version-recovery" || true

# Inner wrapper still pins the generation manifest SHA256.
GEN_SHA="$(phase2_helper_generation_sha256 "${CLIENT_ROOT}/phase2-helper-generation.manifest")"
grep -Fq "H='${GEN_SHA}'" "${CLIENT_ROOT}/upgrade-phase2.sh"
grep -q 'sha256sum -c "$GEN"' "${CLIENT_ROOT}/upgrade-phase2.sh"

# Legacy sidecar-only Menu 7 command must fail closed: no curl+bash -n source path.
OLD_WORK="${TMP}/old-work"
mkdir -p "$OLD_WORK"
curl -fsSLo "${OLD_WORK}/stage-dp-phase2.sh" "${MIRROR}/client/stage-dp-phase2.sh"
python3 - "${ROOT}/client/stage-dp-phase2.sh" "${OLD_WORK}/stage-dp-phase2.sh" <<'PY'
from pathlib import Path
import sys
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
dst.write_text(src.read_text(encoding="utf-8"), encoding="utf-8")
PY
chmod +x "${OLD_WORK}/stage-dp-phase2.sh"
set +e
PATH="${TMP}/fakebin:${PATH}" bash "${OLD_WORK}/stage-dp-phase2.sh" \
  --help --mirror-url "${MIRROR}" >"${TMP}/old.out" 2>&1
OLD_RC=$?
set -e
[[ "$OLD_RC" -ne 0 ]]
grep -q 'PHASE2_HELPER_GENERATION=FAIL' "${TMP}/old.out"
grep -q 'manifest_missing' "${TMP}/old.out"

echo "MENU7_NORMAL_WIDTH_DISPLAY=PASS"
echo "MAX_COMMAND_DISPLAY_WIDTH=${MAX_COMMAND_DISPLAY_WIDTH}"
echo "PHASE2_HELPER_FETCH_E2E=PASS"
echo "PHASE2_OLD_MENU7_HELPER_PREFETCH=FAILCLOSED"
