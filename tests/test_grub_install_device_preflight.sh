#!/usr/bin/env bash
# Targeted regression: CURRENT_STATE_ONLY grub-pc normalization.
# Proves old grub-pc state does not control the target, and that the ACTUAL
# generated detached runner embeds and mandatorily invokes the normalizer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/client/lib/dp-offline-grub-install-device-preflight.sh"
RENDER="${ROOT}/tests/lib/render_offline_upgrade_stub.py"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

[[ -f "$HELPER" ]] || { echo "FAIL: missing helper $HELPER"; exit 1; }
bash -n "$HELPER" && pass "helper bash -n" || fail "helper bash -n"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- fixture helpers -------------------------------------------------------

reset_case() {
  unset GRUB_PF_OVERRIDE_BOOT_MODE GRUB_PF_OVERRIDE_ROOT_SOURCE \
    GRUB_PF_OVERRIDE_PARENT_DISK GRUB_PF_OVERRIDE_BY_ID_DIR \
    GRUB_PF_OVERRIDE_INSTALL_DEVICES GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT \
    GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK GRUB_PF_OVERRIDE_DEBCONF_STORE \
    GRUB_PF_OVERRIDE_DISKS_CHANGED GRUB_PF_OVERRIDE_EMPTY \
    GRUB_PF_RESOLVE_MAP GRUB_PF_DRY_RUN GRUB_PF_MODE \
    GRUB_PF_FORCE_SET_FAIL GRUB_PF_FORCE_SET_FAIL_AT \
    GRUB_PF_FORCE_READBACK_FAIL GRUB_PF_FORCE_LIVE || true
  BOOT_MODE=""
  ROOT_SOURCE=""
  ROOT_PARENT_DISK=""
  GRUB_INSTALL_TARGET=""
  GRUB_INSTALL_TARGET_DERIVATION=""
  GRUB_INSTALL_DEVICE_BEFORE=""
  GRUB_INSTALL_DEVICE_AFTER=""
  GRUB_INSTALL_DEVICE_PREFLIGHT=""
  OLD_STATE_USED_FOR_CONTROL_FLOW=""
  GRUB_PF_SET_COUNT=0
}

# shellcheck disable=SC1090
source "$HELPER"

init_debconf_store() {
  local store="$1" devices="$2"
  cat >"$store" <<EOF
grub-pc/install_devices=${devices}
grub-pc/install_devices_disks_changed=${devices}
grub-pc/install_devices_empty=false
EOF
}

store_get() {
  awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1); exit}' "$2"
}

bios_nvme_env() {
  local store="$1"
  export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
  export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
  export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
  export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
  export GRUB_PF_OVERRIDE_DEBCONF_STORE="$store"
  export GRUB_PF_RESOLVE_MAP="/dev/nvme0n1p1=>/dev/nvme0n1p1;/dev/nvme0n1=>/dev/nvme0n1"
}

assert_normalize_to() {
  local expected="$1" label="$2"
  if [[ "$GRUB_INSTALL_TARGET" == "$expected" \
     && "$GRUB_INSTALL_TARGET_DERIVATION" == "PASS" \
     && "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "PASS" \
     && "$OLD_STATE_USED_FOR_CONTROL_FLOW" == "NO" \
     && "$(store_get grub-pc/install_devices "$GRUB_PF_OVERRIDE_DEBCONF_STORE")" == "$expected" \
     && "$GRUB_INSTALL_DEVICE_AFTER" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label target=${GRUB_INSTALL_TARGET} der=${GRUB_INSTALL_TARGET_DERIVATION} pre=${GRUB_INSTALL_DEVICE_PREFLIGHT} after=${GRUB_INSTALL_DEVICE_AFTER} oldctl=${OLD_STATE_USED_FOR_CONTROL_FLOW} store=$(store_get grub-pc/install_devices "$GRUB_PF_OVERRIDE_DEBCONF_STORE")"
  fi
}

# =============================================================================
# CASE A — AWS NVMe + old nonexistent EBS value
# =============================================================================
reset_case
STORE_A="${TMP}/caseA.store"
OLD_A="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0c212bb3c68696534"
init_debconf_store "$STORE_A" "$OLD_A"
bios_nvme_env "$STORE_A"
if run_grub_install_device_normalize; then
  assert_normalize_to "/dev/nvme0n1" "A: NVMe + nonexistent EBS old value → /dev/nvme0n1"
  [[ "$GRUB_INSTALL_DEVICE_BEFORE" == "$OLD_A" ]] \
    && pass "A: BEFORE observational log retained" \
    || fail "A: BEFORE missing (got=${GRUB_INSTALL_DEVICE_BEFORE})"
else
  fail "A: normalize returned nonzero"
fi

# =============================================================================
# CASE B — AWS NVMe + already-current old value (same final behavior as A)
# =============================================================================
reset_case
STORE_B="${TMP}/caseB.store"
init_debconf_store "$STORE_B" "/dev/nvme0n1"
bios_nvme_env "$STORE_B"
if run_grub_install_device_normalize; then
  assert_normalize_to "/dev/nvme0n1" "B: NVMe + already-current old value → /dev/nvme0n1"
else
  fail "B: normalize returned nonzero"
fi

# =============================================================================
# CASE C — AWS NVMe + partition stored as old target
# =============================================================================
reset_case
STORE_C="${TMP}/caseC.store"
init_debconf_store "$STORE_C" "/dev/nvme0n1p1"
bios_nvme_env "$STORE_C"
if run_grub_install_device_normalize; then
  assert_normalize_to "/dev/nvme0n1" "C: NVMe + partition old value → whole disk"
else
  fail "C: normalize returned nonzero"
fi

# =============================================================================
# CASE D — /dev/xvda1
# =============================================================================
reset_case
STORE_D="${TMP}/caseD.store"
init_debconf_store "$STORE_D" "/dev/disk/by-id/xen-AWS_Elastic_Block_Store_volDEAD"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/xvda1
# No PARENT override: exercise naming derivation.
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_D"
export GRUB_PF_RESOLVE_MAP="/dev/xvda1=>/dev/xvda1;/dev/xvda=>/dev/xvda"
if run_grub_install_device_normalize; then
  assert_normalize_to "/dev/xvda" "D: xvda1 → /dev/xvda"
else
  fail "D: normalize returned nonzero"
fi

# =============================================================================
# CASE E — /dev/sda1
# =============================================================================
reset_case
STORE_E="${TMP}/caseE.store"
init_debconf_store "$STORE_E" ""
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/sda1
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_E"
export GRUB_PF_RESOLVE_MAP="/dev/sda1=>/dev/sda1;/dev/sda=>/dev/sda"
if run_grub_install_device_normalize; then
  assert_normalize_to "/dev/sda" "E: sda1 → /dev/sda"
else
  fail "E: normalize returned nonzero"
fi

# =============================================================================
# CASE F — idempotency (normalize twice)
# =============================================================================
reset_case
STORE_F="${TMP}/caseF.store"
init_debconf_store "$STORE_F" "$OLD_A"
bios_nvme_env "$STORE_F"
run_grub_install_device_normalize >/dev/null
T1="$GRUB_INSTALL_TARGET"
A1="$GRUB_INSTALL_DEVICE_AFTER"
run_grub_install_device_normalize >/dev/null
T2="$GRUB_INSTALL_TARGET"
A2="$GRUB_INSTALL_DEVICE_AFTER"
if [[ "$T1" == "/dev/nvme0n1" && "$T2" == "/dev/nvme0n1" \
   && "$A1" == "/dev/nvme0n1" && "$A2" == "/dev/nvme0n1" \
   && "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "PASS" ]]; then
  pass "F: idempotent normalize twice"
else
  fail "F: t1=$T1 t2=$T2 a1=$A1 a2=$A2"
fi

# =============================================================================
# CASE G — unable to derive a single whole root disk
# =============================================================================
reset_case
STORE_G="${TMP}/caseG.store"
init_debconf_store "$STORE_G" "/dev/sda"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/mapper/rootvg-root
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_G"
# Explicitly no PARENT override; mapper must fail closed.
set +e
run_grub_install_device_normalize >/dev/null 2>"${TMP}/caseG.err"
G_RC=$?
set -e
if [[ "$G_RC" -ne 0 \
   && "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "FAIL" \
   && "$(store_get grub-pc/install_devices "$STORE_G")" == "/dev/sda" ]]; then
  pass "G: mapper root fails before mutation"
else
  fail "G: rc=$G_RC pre=${GRUB_INSTALL_DEVICE_PREFLIGHT} store=$(store_get grub-pc/install_devices "$STORE_G")"
fi

# =============================================================================
# CASE H — debconf write failure
# =============================================================================
reset_case
STORE_H="${TMP}/caseH.store"
init_debconf_store "$STORE_H" "$OLD_A"
bios_nvme_env "$STORE_H"
export GRUB_PF_FORCE_SET_FAIL=1
H_OUT="${TMP}/caseH.out"
set +e
run_grub_install_device_normalize >"$H_OUT" 2>&1
H_RC=$?
set -e
if [[ "$H_RC" -ne 0 \
   && "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "FAIL" \
   && "$(store_get grub-pc/install_devices "$STORE_H")" == "$OLD_A" ]] \
  && grep -q 'PACKAGE_TRANSITION_STARTED=NO' "$H_OUT"; then
  pass "H: write failure → FAIL + PACKAGE_TRANSITION_STARTED=NO"
else
  fail "H: rc=$H_RC pre=${GRUB_INSTALL_DEVICE_PREFLIGHT} out=$(tail -3 "$H_OUT")"
fi

# =============================================================================
# CASE I — readback/verification failure
# =============================================================================
reset_case
STORE_I="${TMP}/caseI.store"
init_debconf_store "$STORE_I" "$OLD_A"
bios_nvme_env "$STORE_I"
export GRUB_PF_FORCE_READBACK_FAIL=1
I_OUT="${TMP}/caseI.out"
set +e
run_grub_install_device_normalize >"$I_OUT" 2>&1
I_RC=$?
set -e
if [[ "$I_RC" -ne 0 && "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "FAIL" ]] \
  && grep -q 'PACKAGE_TRANSITION_STARTED=NO' "$I_OUT"; then
  pass "I: readback failure → FAIL + PACKAGE_TRANSITION_STARTED=NO"
else
  fail "I: rc=$I_RC pre=${GRUB_INSTALL_DEVICE_PREFLIGHT}"
fi

# =============================================================================
# CASE J — EFI skip without grub-pc mutation
# =============================================================================
reset_case
STORE_J="${TMP}/caseJ.store"
init_debconf_store "$STORE_J" "$OLD_A"
export GRUB_PF_OVERRIDE_BOOT_MODE=EFI
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_J"
if run_grub_install_device_normalize \
  && [[ "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "PASS" \
     && "$(store_get grub-pc/install_devices "$STORE_J")" == "$OLD_A" ]]; then
  pass "J: EFI skip without mutation"
else
  fail "J: pre=${GRUB_INSTALL_DEVICE_PREFLIGHT} store=$(store_get grub-pc/install_devices "$STORE_J")"
fi

# Preflight read-only must not mutate even on BIOS
reset_case
STORE_PF="${TMP}/casePF.store"
init_debconf_store "$STORE_PF" "$OLD_A"
bios_nvme_env "$STORE_PF"
HASH_BEFORE="$(sha256sum "$STORE_PF" | awk '{print $1}')"
if run_grub_install_device_preflight \
  && [[ "$GRUB_INSTALL_TARGET" == "/dev/nvme0n1" \
     && "$GRUB_INSTALL_TARGET_DERIVATION" == "PASS" \
     && "$OLD_STATE_USED_FOR_CONTROL_FLOW" == "NO" \
     && "$(sha256sum "$STORE_PF" | awk '{print $1}')" == "$HASH_BEFORE" ]]; then
  pass "preflight: derivation PASS without mutation"
else
  fail "preflight mutated or failed"
fi

# =============================================================================
# Wiring: templates + builders + manifest
# =============================================================================
wire_ok=1
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  tin="${ROOT}/client/dp-offline-upgrade-${hop}.sh.in"
  bhop="${hop//-/_}"
  builder="${ROOT}/scripts/lib/build_client_${bhop}.py"
  token_count="$(grep -c '@@GRUB_INSTALL_DEVICE_PREFLIGHT_HELPER@@' "$tin" || true)"
  if [[ "$token_count" -lt 2 ]]; then
    echo "  need helper token in outer+runner: $tin (count=${token_count})"; wire_ok=0
  fi
  if ! grep -q 'run_grub_install_device_preflight' "$tin"; then
    echo "  missing preflight call in $tin"; wire_ok=0
  fi
  if ! grep -q 'run_grub_install_device_normalize' "$tin"; then
    echo "  missing normalize call in $tin"; wire_ok=0
  fi
  if grep -q 'run_grub_install_device_reconcile' "$tin"; then
    echo "  obsolete reconcile still present in $tin"; wire_ok=0
  fi
  if ! awk '
    /set_stage "GRUB_INSTALL_DEVICE_PREFLIGHT"/ {inblock=1}
    inblock && /run_grub_install_device_normalize/ {found=1}
    inblock && /GRUB_INSTALL_DEVICE_NORMALIZER_MISSING/ {miss=1}
    inblock && /do-release-upgrade/ {exit}
    END {exit (found && miss)?0:1}
  ' "$tin"; then
    echo "  mandatory normalize/fail-closed missing before DRO in $tin"; wire_ok=0
  fi
  if [[ ! -f "$builder" ]] || ! grep -q 'dp-offline-grub-install-device-preflight' "$builder"; then
    echo "  missing builder wire in $builder"; wire_ok=0
  fi
done
if grep -q 'dp-offline-grub-install-device-preflight' "$RENDER" \
  && grep -q 'dp-offline-grub-install-device-preflight' \
  "${ROOT}/scripts/lib/client_build_provenance.py"; then
  :
else
  echo "  missing render stub or provenance listing"; wire_ok=0
fi
if [[ "$wire_ok" -eq 1 ]]; then
  pass "wiring: all four hops embed helper + mandatory normalize"
else
  fail "wiring incomplete"
fi

HELPER_LEAK="$(grep -oE '@@[A-Z0-9_]+@@' "$HELPER" || true)"
if [[ -z "$HELPER_LEAK" ]]; then
  pass "helper body has no @@TOKEN@@ literals"
else
  fail "helper body leaks template tokens: ${HELPER_LEAK}"
fi

python3 - "$ROOT/lib/runtime_manifest.sh" <<'PY' && manifest_ok=1 || manifest_ok=0
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^UM_RUNTIME_CLIENT_LIB_FILES=\((.*?)\)", text, re.M | re.S)
if not m:
    sys.exit(1)
wanted = "dp-offline-grub-install-device-preflight.sh"
if not re.search(r"(?m)^\s*" + re.escape(wanted) + r"\s*$", m.group(1)):
    sys.exit(1)
sys.exit(0)
PY
if [[ "$manifest_ok" -eq 1 ]]; then
  pass "runtime manifest allowlists GRUB helper"
else
  fail "runtime manifest missing helper"
fi

# Obsolete state-machine symbols must not remain in the helper.
if grep -qE 'GRUB_PF_SNAP_|GRUB_INSTALL_DEVICE_ROLLBACK|WOULD_REBIND|run_grub_install_device_reconcile|grub_pf_classify_install_devices|grub_pf_select_expected_device' "$HELPER"; then
  fail "obsolete GRUB state-machine symbols still present in helper"
else
  pass "obsolete STALE/CURRENT/rollback state machine removed"
fi

# =============================================================================
# CRITICAL: generate real runners via install_runner_and_units and execute them
# =============================================================================
RENDERED_DIR="${TMP}/rendered"
mkdir -p "$RENDERED_DIR"
ALL_RUNNERS_OK=1
UNRESOLVED=0

extract_and_install_runner() {
  local hop="$1" rendered="$2" fixture="$3"
  local harness="${fixture}/install-harness.sh"
  local tin="${ROOT}/client/dp-offline-upgrade-${hop}.sh.in"

  {
    cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="${DP_OFFLINE_TEST_ROOT:-}"
dp_offline_hermetic_test_mode() { [[ "${MM_HERMETIC_TEST_MODE:-0}" == "1" ]]; }
dp_offline_hermetic_fixtures_enabled() { [[ "${MM_HERMETIC_TEST_MODE:-0}" == "1" ]]; }
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
ENV_DEFAULT_FILE="/etc/default/stellar-offline-os-upgrade"
PIN_ENV_FILE="${STATE_ROOT}/pins.env"
RUNNER_PATH="/usr/local/sbin/stellar-offline-os-upgrade-runner"
POSTBOOT_PATH="/usr/local/sbin/stellar-offline-os-upgrade-postboot"
UNIT_NAME="stellar-offline-os-upgrade.service"
POSTBOOT_UNIT_NAME="stellar-offline-os-upgrade-postboot.service"
STATE_FILE="${STATE_ROOT}/state"
hostpath() { local p="$1"; if [[ -n "$TEST_ROOT" ]]; then printf '%s%s' "$TEST_ROOT" "$p"; else printf '%s' "$p"; fi; }
log() { :; }
# Jammy→Noble install_runner_and_units may call this after writing the runner.
install_authoritative_postboot_runtime() { return 0; }
EOS
    # Expand helper tokens already done in rendered file; extract install_runner_and_units.
    # Boundary: function start → next top-level write_pins_env (or postboot install).
    awk '
      /^install_runner_and_units\(\)/ {keep=1}
      keep {print}
      keep && /^write_pins_env\(\)/ {exit}
      keep && /^install_postboot/ {exit}
    ' "$rendered" \
      | awk 'NR==1{print; next} /^write_pins_env\(\)/{exit} /^install_postboot/{exit} {print}'
  } >"$harness"

  # If awk included write_pins_env line, strip it.
  if grep -q '^write_pins_env()' "$harness"; then
    awk '/^write_pins_env\(\)/{exit} {print}' "$harness" >"${harness}.tmp"
    mv "${harness}.tmp" "$harness"
  fi

  bash -n "$harness" || return 1
  # shellcheck disable=SC1090
  export DP_OFFLINE_TEST_ROOT="$fixture" TEST_ROOT="$fixture" MM_HERMETIC_TEST_MODE=1
  # shellcheck disable=SC1090
  source "$harness"
  mkdir -p "${fixture}/tmpwork"
  install_runner_and_units "${fixture}/tmpwork"
  [[ -x "$(hostpath "$RUNNER_PATH")" ]] || return 1
}

for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  tin="${ROOT}/client/dp-offline-upgrade-${hop}.sh.in"
  rendered="${RENDERED_DIR}/dp-offline-upgrade-${hop}.sh"
  python3 "$RENDER" --helpers-only "$tin" "$rendered"
  if grep -qE '@@GRUB_INSTALL_DEVICE_PREFLIGHT_HELPER@@' "$rendered"; then
    echo "  unresolved GRUB token in $rendered"
    UNRESOLVED=1
    ALL_RUNNERS_OK=0
    continue
  fi
  bash -n "$rendered" && pass "rendered client bash -n: $hop" || {
    fail "rendered client bash -n: $hop"
    ALL_RUNNERS_OK=0
    continue
  }

  fix="${TMP}/runner-${hop}"
  mkdir -p "$fix"
  if ! extract_and_install_runner "$hop" "$rendered" "$fix"; then
    fail "install_runner_and_units failed: $hop"
    ALL_RUNNERS_OK=0
    continue
  fi
  runner="${fix}/usr/local/sbin/stellar-offline-os-upgrade-runner"
  if ! bash -n "$runner"; then
    fail "generated runner bash -n: $hop"
    ALL_RUNNERS_OK=0
    continue
  fi
  if ! grep -q 'run_grub_install_device_normalize()' "$runner"; then
    fail "generated runner missing normalize fn: $hop"
    ALL_RUNNERS_OK=0
    continue
  fi
  if ! grep -q 'GRUB_INSTALL_DEVICE_NORMALIZER_MISSING' "$runner"; then
    fail "generated runner missing fail-closed missing-helper: $hop"
    ALL_RUNNERS_OK=0
    continue
  fi
  if ! awk '
    /set_stage "GRUB_INSTALL_DEVICE_PREFLIGHT"/ {inblock=1}
    inblock && /run_grub_install_device_normalize/ {found=1}
    inblock && /do-release-upgrade/ {exit}
    END {exit found?0:1}
  ' "$runner"; then
    fail "generated runner normalize not before DRO: $hop"
    ALL_RUNNERS_OK=0
    continue
  fi
  if grep -qE '@@[A-Z0-9_]+@@' "$runner"; then
    echo "  unresolved tokens in runner $hop: $(grep -oE '@@[A-Z0-9_]+@@' "$runner" | sort -u | tr '\n' ' ')"
    # Only fail hard on GRUB token; other leftover pins may remain in helpers-only render of outer,
    # but runner heredoc should only have helper tokens which were expanded.
    if grep -q '@@GRUB' "$runner"; then
      UNRESOLVED=1
      ALL_RUNNERS_OK=0
      continue
    fi
  fi
  pass "generated runner embeds mandatory normalizer: $hop"
done

if [[ "$UNRESOLVED" -eq 0 ]]; then
  pass "no unresolved @@GRUB...@@ tokens after render"
else
  fail "unresolved @@GRUB...@@ tokens remain"
fi

# --- Execute generated xenial runner GRUB→DRO path under mocks -------------
XB_FIX="${TMP}/runner-xenial-to-bionic"
XB_RUNNER="${XB_FIX}/usr/local/sbin/stellar-offline-os-upgrade-runner"
EVENTS="${TMP}/events.log"
: >"$EVENTS"

if [[ -f "$XB_RUNNER" ]]; then
  EXEC_DIR="${TMP}/exec-pos"
  mkdir -p "$EXEC_DIR/bin" "$EXEC_DIR/store"
  STORE_EXEC="${EXEC_DIR}/store/debconf"
  init_debconf_store "$STORE_EXEC" "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_volOLDDEAD"

  # Mock do-release-upgrade and common tools used after GRUB stage.
  cat >"$EXEC_DIR/bin/do-release-upgrade" <<'EOS'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: do-release-upgrade [options]"
  echo "  -f FRONTEND, DistUpgradeViewNonInteractive"
  exit 0
fi
echo "DRO_MOCK_START" >>"${STELLAR_GRUB_EVENT_LOG}"
exit 0
EOS
  chmod +x "$EXEC_DIR/bin/do-release-upgrade"
  for cmd in systemctl apt-get dpkg dpkg-query findmnt lsblk; do
    printf '#!/bin/sh\nexit 0\n' >"$EXEC_DIR/bin/$cmd"
    chmod +x "$EXEC_DIR/bin/$cmd"
  done

  # Build a minimal harness that sources the generated runner's GRUB helper
  # functions and executes the exact mandatory normalize+DRO ordering block
  # taken from the generated runner itself.
  python3 - "$XB_RUNNER" "$EXEC_DIR/run-grub-dro.sh" <<'PY'
import re, sys
runner = open(sys.argv[1], encoding="utf-8").read()
out = sys.argv[2]
# Capture from first run_grub helper definition through end of helper aliases.
# The helper is inlined near the top; take until STATE_ROOT= assignment after helpers.
m = re.search(
    r"(?ms)^(BOOT_MODE=\"\"|grub_pf_log\(\)|# Shared BIOS).*?(?=^STATE_ROOT=)",
    runner,
)
if not m:
    # Fallback: extract by function name markers
    m = re.search(
        r"(?ms)^BOOT_MODE=\"\".*?^run_grub_install_device_normalize\(\) \{.*?\n\}\n",
        runner,
    )
if not m:
    raise SystemExit("could not extract GRUB helper from generated runner")
helper = m.group(0)
# Capture the exact GRUB stage block from the generated runner.
m2 = re.search(
    r'(?ms)^  set_stage "GRUB_INSTALL_DEVICE_PREFLIGHT".*?(?=^  LAST_COMMAND="do-release-upgrade --help")',
    runner,
)
if not m2:
    raise SystemExit("could not extract GRUB stage block from generated runner")
block = m2.group(0)
open(out, "w", encoding="utf-8").write(
    """#!/usr/bin/env bash
set -euo pipefail
log() { printf '%s: %s\\n' \"$1\" \"$2\"; printf '%s\\n' \"$2\" >>\"${STELLAR_GRUB_EVENT_LOG}\"; }
set_stage() { log INFO \"STAGE=$1\"; }
fail_stage() {
  local rc=\"$1\"; shift
  log ERROR \"fail_stage rc=${rc} $*\"
  log ERROR \"PACKAGE_TRANSITION_STARTED=NO\"
  exit \"$rc\"
}
"""
    + helper
    + "\n"
    + block
    + """
LAST_COMMAND=\"do-release-upgrade --help\"
if ! do-release-upgrade --help 2>&1 | grep -q DistUpgradeViewNonInteractive; then
  if ! do-release-upgrade --help 2>&1 | grep -q -- '-f'; then
    fail_stage 1 \"do-release-upgrade frontend unsupported\"
  fi
fi
LAST_COMMAND=\"do-release-upgrade -f DistUpgradeViewNonInteractive\"
do-release-upgrade -f DistUpgradeViewNonInteractive
"""
)
PY
  chmod +x "$EXEC_DIR/run-grub-dro.sh"
  bash -n "$EXEC_DIR/run-grub-dro.sh"

  set +e
  env -i \
    PATH="$EXEC_DIR/bin:/usr/bin:/bin" \
    HOME=/tmp \
    STELLAR_GRUB_EVENT_LOG="$EVENTS" \
    GRUB_PF_OVERRIDE_BOOT_MODE=BIOS \
    GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1 \
    GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1 \
    GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1 \
    GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_EXEC" \
    GRUB_PF_RESOLVE_MAP="/dev/nvme0n1p1=>/dev/nvme0n1p1;/dev/nvme0n1=>/dev/nvme0n1" \
    bash "$EXEC_DIR/run-grub-dro.sh" >"${TMP}/exec-pos.out" 2>&1
  POS_RC=$?
  set -e

  if [[ "$POS_RC" -eq 0 ]] \
    && grep -q 'DETECT_CURRENT_ROOT' "$EVENTS" \
    && grep -q 'DERIVE_CURRENT_WHOLE_DISK' "$EVENTS" \
    && grep -q 'SET_GRUB_TARGET' "$EVENTS" \
    && grep -q 'VERIFY_GRUB_TARGET' "$EVENTS" \
    && grep -q 'GRUB_NORMALIZATION_PASS' "$EVENTS" \
    && grep -q 'DRO_MOCK_START' "$EVENTS" \
    && [[ "$(store_get grub-pc/install_devices "$STORE_EXEC")" == "/dev/nvme0n1" ]]; then
    # Ordering: GRUB_NORMALIZATION_PASS before DRO_MOCK_START
    python3 - "$EVENTS" <<'PY' && pass "GENERATED_RUNNER_INTEGRATION: normalize before DRO" || fail "PACKAGE_TRANSITION_ORDERING broken"
import sys
lines=[ln.strip() for ln in open(sys.argv[1], encoding='utf-8')]
def idx(s):
    for i,ln in enumerate(lines):
        if s in ln: return i
    return -1
order=['DETECT_CURRENT_ROOT','DERIVE_CURRENT_WHOLE_DISK','SET_GRUB_TARGET','VERIFY_GRUB_TARGET','GRUB_NORMALIZATION_PASS','DRO_MOCK_START']
pos=[idx(s) for s in order]
if any(p<0 for p in pos) or pos != sorted(pos):
    sys.exit(1)
sys.exit(0)
PY
  else
    fail "GENERATED_RUNNER_INTEGRATION positive path rc=$POS_RC events=$(tr '\n' '|' <"$EVENTS") out=$(tail -20 "${TMP}/exec-pos.out")"
  fi

  # Negative: strip normalizer from a copy of the generated runner block
  NEG_DIR="${TMP}/exec-neg"
  mkdir -p "$NEG_DIR"
  NEG_EVENTS="${TMP}/neg-events.log"
  : >"$NEG_EVENTS"
  python3 - "$XB_RUNNER" "$NEG_DIR/run-missing.sh" <<'PY'
import re, sys
runner = open(sys.argv[1], encoding="utf-8").read()
out = sys.argv[2]
m2 = re.search(
    r'(?ms)^  set_stage "GRUB_INSTALL_DEVICE_PREFLIGHT".*?(?=^  LAST_COMMAND="do-release-upgrade --help")',
    runner,
)
if not m2:
    raise SystemExit("missing GRUB stage")
block = m2.group(0)
open(out, "w", encoding="utf-8").write(
    """#!/usr/bin/env bash
set -euo pipefail
log() { printf '%s: %s\\n' \"$1\" \"$2\"; printf '%s\\n' \"$2\" >>\"${STELLAR_GRUB_EVENT_LOG}\"; }
set_stage() { log INFO \"STAGE=$1\"; }
fail_stage() {
  local rc=\"$1\"; shift
  log ERROR \"fail_stage rc=${rc} $*\"
  log ERROR \"PACKAGE_TRANSITION_STARTED=NO\"
  exit \"$rc\"
}
# Intentionally omit run_grub_install_device_normalize definition.
"""
    + block
    + """
echo DRO_MOCK_START >>\"${STELLAR_GRUB_EVENT_LOG}\"
"""
)
PY
  chmod +x "$NEG_DIR/run-missing.sh"
  set +e
  env -i PATH="/usr/bin:/bin" HOME=/tmp STELLAR_GRUB_EVENT_LOG="$NEG_EVENTS" \
    bash "$NEG_DIR/run-missing.sh" >"${TMP}/exec-neg.out" 2>&1
  NEG_RC=$?
  set -e
  if [[ "$NEG_RC" -ne 0 ]] \
    && ! grep -q 'DRO_MOCK_START' "$NEG_EVENTS" \
    && grep -q 'PACKAGE_TRANSITION_STARTED=NO' "${TMP}/exec-neg.out"; then
    pass "MISSING_NORMALIZER_FAIL_CLOSED"
  else
    fail "missing normalizer did not fail closed (rc=$NEG_RC events=$(cat "$NEG_EVENTS"))"
  fi
else
  fail "xenial generated runner missing; skip integration execution"
  ALL_RUNNERS_OK=0
fi

if [[ "$ALL_RUNNERS_OK" -eq 1 ]]; then
  pass "ALL_FOUR_RENDERED_RUNNERS"
else
  fail "ALL_FOUR_RENDERED_RUNNERS"
fi

# =============================================================================
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
fi
echo "FAILURES=${FAIL}"
exit 1
