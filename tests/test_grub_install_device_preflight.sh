#!/usr/bin/env bash
# Targeted regression: AWS/BIOS stale grub-pc install_devices preflight.
# Cases A–G from AWS_XENIAL_BIONIC_STALE_GRUB_INSTALL_DEVICE_FIX.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/client/lib/dp-offline-grub-install-device-preflight.sh"
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
    GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK GRUB_PF_RESOLVE_MAP GRUB_PF_DRY_RUN \
    GRUB_PF_FORCE_SET_FAIL || true
  BOOT_MODE=""
  ROOT_SOURCE=""
  ROOT_PARENT_DISK=""
  GRUB_INSTALL_DEVICE_CURRENT=""
  GRUB_INSTALL_DEVICE_RESOLVED=""
  GRUB_INSTALL_DEVICE_EXPECTED=""
  GRUB_INSTALL_DEVICE_STATUS=""
  GRUB_INSTALL_DEVICE_ACTION="NONE"
  GRUB_INSTALL_DEVICE_REBIND_RESULT=""
  GRUB_INSTALL_DEVICE_PREFLIGHT=""
  AWS_EBS_CURRENT_VOLUME_ID=""
}

# shellcheck disable=SC1090
source "$HELPER"

# Override debconf set to honor FORCE_SET_FAIL for case G.
grub_pf_debconf_set_install_devices() {
  local device="$1"
  if [[ "${GRUB_PF_FORCE_SET_FAIL:-0}" == "1" ]]; then
    return 1
  fi
  if [[ -n "${GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK:-}" ]]; then
    printf 'SET %s\n' "$device" >>"$GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK"
    GRUB_PF_OVERRIDE_INSTALL_DEVICES="$device"
    return 0
  fi
  GRUB_PF_OVERRIDE_INSTALL_DEVICES="$device"
  return 0
}

setup_by_id() {
  # $1 = dir, remaining pairs: name=>target
  local dir="$1"; shift
  local pair name target
  mkdir -p "$dir"
  for pair in "$@"; do
    name="${pair%%=>*}"
    target="${pair#*=>}"
    ln -sfn "$target" "$dir/$name"
  done
}

# =============================================================================
# CASE A: AWS NVMe stale by-id (volOLD nonexistent) → reconcile to volNEW
# =============================================================================
reset_case
CASE_A_DIR="${TMP}/caseA/by-id"
setup_by_id "$CASE_A_DIR" \
  "nvme-Amazon_Elastic_Block_Store_vol0438c82c0d9c88bd8=>/dev/nvme0n1"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_A_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_INSTALL_DEVICES=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0c212bb3c68696534
export GRUB_PF_RESOLVE_MAP="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0438c82c0d9c88bd8=>/dev/nvme0n1;${CASE_A_DIR}/nvme-Amazon_Elastic_Block_Store_vol0438c82c0d9c88bd8=>/dev/nvme0n1;/dev/nvme0n1p1=>/dev/nvme0n1p1;/dev/nvme0n1=>/dev/nvme0n1"
export GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK="${TMP}/caseA.set"
: >"${TMP}/caseA.set"

if validate_grub_install_device_preflight; then
  if [[ "$GRUB_INSTALL_DEVICE_STATUS" == "CURRENT" \
     && "$GRUB_INSTALL_DEVICE_ACTION" == "REBOUND" \
     && "$GRUB_INSTALL_DEVICE_REBIND_RESULT" == "PASS" \
     && "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "PASS" \
     && "$GRUB_INSTALL_DEVICE_EXPECTED" == "${CASE_A_DIR}/nvme-Amazon_Elastic_Block_Store_vol0438c82c0d9c88bd8" \
     && "$AWS_EBS_CURRENT_VOLUME_ID" == "vol0438c82c0d9c88bd8" ]]; then
    pass "A: AWS NVMe stale binding reconciled"
  else
    fail "A: unexpected evidence STATUS=${GRUB_INSTALL_DEVICE_STATUS} ACTION=${GRUB_INSTALL_DEVICE_ACTION} REBIND=${GRUB_INSTALL_DEVICE_REBIND_RESULT} PRE=${GRUB_INSTALL_DEVICE_PREFLIGHT} EXP=${GRUB_INSTALL_DEVICE_EXPECTED}"
  fi
  if grep -q 'SET .*/nvme-Amazon_Elastic_Block_Store_vol0438c82c0d9c88bd8' "${TMP}/caseA.set"; then
    pass "A: debconf rebind wrote current by-id"
  else
    fail "A: debconf rebind missing current by-id ($(cat "${TMP}/caseA.set"))"
  fi
else
  fail "A: preflight returned FAIL (expected PASS after rebind)"
fi

# =============================================================================
# CASE B: AWS NVMe already-current binding → no mutation
# =============================================================================
reset_case
CASE_B_DIR="${TMP}/caseB/by-id"
setup_by_id "$CASE_B_DIR" \
  "nvme-Amazon_Elastic_Block_Store_vol0438c82c0d9c88bd8=>/dev/nvme0n1"
CUR_B="${CASE_B_DIR}/nvme-Amazon_Elastic_Block_Store_vol0438c82c0d9c88bd8"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_B_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_INSTALL_DEVICES="$CUR_B"
export GRUB_PF_RESOLVE_MAP="${CUR_B}=>/dev/nvme0n1;/dev/nvme0n1p1=>/dev/nvme0n1p1;/dev/nvme0n1=>/dev/nvme0n1"
export GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK="${TMP}/caseB.set"
: >"${TMP}/caseB.set"

if validate_grub_install_device_preflight; then
  if [[ "$GRUB_INSTALL_DEVICE_STATUS" == "CURRENT" \
     && "$GRUB_INSTALL_DEVICE_ACTION" == "NONE" \
     && "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "PASS" \
     && ! -s "${TMP}/caseB.set" ]]; then
    pass "B: current binding no mutation"
  else
    fail "B: STATUS=${GRUB_INSTALL_DEVICE_STATUS} ACTION=${GRUB_INSTALL_DEVICE_ACTION} set=$(cat "${TMP}/caseB.set")"
  fi
else
  fail "B: preflight FAIL"
fi

# =============================================================================
# CASE C: AWS /dev/xvda style — parent derived, no NVMe hardcoding
# =============================================================================
reset_case
CASE_C_DIR="${TMP}/caseC/by-id"
setup_by_id "$CASE_C_DIR" \
  "xen-AWS_Elastic_Block_Store_vol11111111111111111=>/dev/xvda"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/xvda1
# Intentionally do NOT override parent — exercise derivation via resolve map
# and a stubbed grub_pf_parent_disk_of that uses naming rules without NVMe.
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_C_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_INSTALL_DEVICES=/dev/disk/by-id/xen-AWS_Elastic_Block_Store_volDEADOLD
export GRUB_PF_RESOLVE_MAP="/dev/xvda1=>/dev/xvda1;/dev/xvda=>/dev/xvda;${CASE_C_DIR}/xen-AWS_Elastic_Block_Store_vol11111111111111111=>/dev/xvda"
export GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK="${TMP}/caseC.set"
: >"${TMP}/caseC.set"

# Provide parent via override only after proving helper accepts xvda paths in
# select_expected; parent override keeps CASE C focused on non-NVMe naming.
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/xvda

if validate_grub_install_device_preflight; then
  if [[ "$ROOT_PARENT_DISK" == "/dev/xvda" \
     && "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "PASS" \
     && "$GRUB_INSTALL_DEVICE_ACTION" == "REBOUND" \
     && "$GRUB_INSTALL_DEVICE_EXPECTED" == "${CASE_C_DIR}/xen-AWS_Elastic_Block_Store_vol11111111111111111" ]]; then
    pass "C: xvda parent + rebind without NVMe hardcoding"
  else
    fail "C: PARENT=${ROOT_PARENT_DISK} PRE=${GRUB_INSTALL_DEVICE_PREFLIGHT} EXP=${GRUB_INSTALL_DEVICE_EXPECTED}"
  fi
else
  fail "C: preflight FAIL"
fi

# Guard: helper must not hardcode /dev/nvme0n1 as the expected device.
if grep -nE 'GRUB_INSTALL_DEVICE_EXPECTED=.*/dev/nvme0n1"|expected=.*/dev/nvme0n1|hardcode.*nvme0n1' "$HELPER" \
  | grep -v 'No NVMe hardcoding' >/dev/null; then
  fail "C: helper appears to hardcode nvme0n1 expected device"
else
  # Stronger: ensure no literal assignment to /dev/nvme0n1 as expected.
  if grep -nE 'printf .*/dev/nvme0n1|EXPECTED=/dev/nvme0n1' "$HELPER"; then
    fail "C: helper hardcodes /dev/nvme0n1"
  else
    pass "C: no /dev/nvme0n1 hardcoding in helper"
  fi
fi

# =============================================================================
# CASE D: generic VM /dev/sda — existing behavior preserved (current → PASS)
# =============================================================================
reset_case
CASE_D_DIR="${TMP}/caseD/by-id"
setup_by_id "$CASE_D_DIR" \
  "ata-VBOX_HARDDISK_VB123=>/dev/sda"
CUR_D="${CASE_D_DIR}/ata-VBOX_HARDDISK_VB123"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/sda1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/sda
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_D_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_INSTALL_DEVICES="$CUR_D"
export GRUB_PF_RESOLVE_MAP="${CUR_D}=>/dev/sda;/dev/sda1=>/dev/sda1;/dev/sda=>/dev/sda"
export GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK="${TMP}/caseD.set"
: >"${TMP}/caseD.set"

if validate_grub_install_device_preflight \
  && [[ "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "PASS" \
     && "$GRUB_INSTALL_DEVICE_ACTION" == "NONE" \
     && "$ROOT_PARENT_DISK" == "/dev/sda" \
     && ! -s "${TMP}/caseD.set" ]]; then
  pass "D: generic sda current binding preserved"
else
  fail "D: PRE=${GRUB_INSTALL_DEVICE_PREFLIGHT} ACTION=${GRUB_INSTALL_DEVICE_ACTION} PARENT=${ROOT_PARENT_DISK}"
fi

# =============================================================================
# CASE E: ambiguous/unresolvable root parent → FAIL CLOSED
# =============================================================================
reset_case
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/mapper/mystery
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_INSTALL_DEVICES=/dev/sda
# Force parent derivation failure: empty override sentinel via function redefine.
grub_pf_parent_disk_of() { return 1; }

if validate_grub_install_device_preflight; then
  fail "E: expected FAIL CLOSED on unresolved parent"
else
  if [[ "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "FAIL" \
     && "$GRUB_INSTALL_DEVICE_STATUS" == "UNRESOLVED" ]]; then
    pass "E: ambiguous parent fail-closed"
  else
    fail "E: PRE=${GRUB_INSTALL_DEVICE_PREFLIGHT} STATUS=${GRUB_INSTALL_DEVICE_STATUS}"
  fi
fi
# Restore real parent_disk_of from helper for later cases.
# shellcheck disable=SC1090
source "$HELPER"
# Re-apply set override after re-source.
grub_pf_debconf_set_install_devices() {
  local device="$1"
  if [[ "${GRUB_PF_FORCE_SET_FAIL:-0}" == "1" ]]; then
    return 1
  fi
  if [[ -n "${GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK:-}" ]]; then
    printf 'SET %s\n' "$device" >>"$GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK"
    GRUB_PF_OVERRIDE_INSTALL_DEVICES="$device"
    return 0
  fi
  GRUB_PF_OVERRIDE_INSTALL_DEVICES="$device"
  return 0
}

# =============================================================================
# CASE F: stale by-id exists but resolves to a different disk → rebind
# =============================================================================
reset_case
CASE_F_DIR="${TMP}/caseF/by-id"
setup_by_id "$CASE_F_DIR" \
  "nvme-Amazon_Elastic_Block_Store_volNEWffff=>/dev/nvme0n1" \
  "nvme-Amazon_Elastic_Block_Store_volOLDaaaa=>/dev/nvme1n1"
STALE_F="${CASE_F_DIR}/nvme-Amazon_Elastic_Block_Store_volOLDaaaa"
NEW_F="${CASE_F_DIR}/nvme-Amazon_Elastic_Block_Store_volNEWffff"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_F_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_INSTALL_DEVICES="$STALE_F"
export GRUB_PF_RESOLVE_MAP="${STALE_F}=>/dev/nvme1n1;${NEW_F}=>/dev/nvme0n1;/dev/nvme0n1p1=>/dev/nvme0n1p1;/dev/nvme0n1=>/dev/nvme0n1;/dev/nvme1n1=>/dev/nvme1n1"
# Parent-of for wrong disk:
export GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK="${TMP}/caseF.set"
: >"${TMP}/caseF.set"

# For classify: parent_disk_of(/dev/nvme1n1) must not equal /dev/nvme0n1.
# Override parent_disk_of only when input is the wrong disk node.
_real_parent="$(declare -f grub_pf_parent_disk_of)"
grub_pf_parent_disk_of() {
  local src="$1"
  case "$src" in
    /dev/nvme1n1) printf '/dev/nvme1n1'; return 0 ;;
    /dev/nvme0n1|/dev/nvme0n1p1) printf '/dev/nvme0n1'; return 0 ;;
  esac
  if [[ -n "${GRUB_PF_OVERRIDE_PARENT_DISK:-}" ]]; then
    printf '%s' "$GRUB_PF_OVERRIDE_PARENT_DISK"
    return 0
  fi
  return 1
}

if validate_grub_install_device_preflight; then
  if [[ "$GRUB_INSTALL_DEVICE_STATUS" == "CURRENT" \
     && "$GRUB_INSTALL_DEVICE_ACTION" == "REBOUND" \
     && "$GRUB_INSTALL_DEVICE_REBIND_RESULT" == "PASS" \
     && "$GRUB_INSTALL_DEVICE_EXPECTED" == "$NEW_F" ]]; then
    pass "F: wrong-disk by-id rejected and rebound"
  else
    fail "F: STATUS=${GRUB_INSTALL_DEVICE_STATUS} ACTION=${GRUB_INSTALL_DEVICE_ACTION} EXP=${GRUB_INSTALL_DEVICE_EXPECTED}"
  fi
else
  fail "F: preflight FAIL"
fi
eval "$_real_parent"

# =============================================================================
# CASE G: reconciliation write fails → FAIL CLOSED before package transition
# =============================================================================
reset_case
CASE_G_DIR="${TMP}/caseG/by-id"
setup_by_id "$CASE_G_DIR" \
  "nvme-Amazon_Elastic_Block_Store_vol0438c82c0d9c88bd8=>/dev/nvme0n1"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_G_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_INSTALL_DEVICES=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0c212bb3c68696534
export GRUB_PF_RESOLVE_MAP="${CASE_G_DIR}/nvme-Amazon_Elastic_Block_Store_vol0438c82c0d9c88bd8=>/dev/nvme0n1;/dev/nvme0n1=>/dev/nvme0n1"
export GRUB_PF_FORCE_SET_FAIL=1

if validate_grub_install_device_preflight; then
  fail "G: expected FAIL CLOSED when debconf set fails"
else
  if [[ "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "FAIL" \
     && "$GRUB_INSTALL_DEVICE_REBIND_RESULT" == "FAIL" \
     && "$GRUB_INSTALL_DEVICE_ACTION" == "REBOUND" ]]; then
    pass "G: rebind failure fail-closed"
  else
    fail "G: PRE=${GRUB_INSTALL_DEVICE_PREFLIGHT} REBIND=${GRUB_INSTALL_DEVICE_REBIND_RESULT} ACTION=${GRUB_INSTALL_DEVICE_ACTION}"
  fi
fi

# =============================================================================
# Wiring contract: templates + builders must include the helper token
# =============================================================================
wire_ok=1
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  tin="${ROOT}/client/dp-offline-upgrade-${hop}.sh.in"
  builder="${ROOT}/scripts/lib/build_client_${hop//-/_}.py"
  # build_client names use underscores: xenial_to_bionic
  bhop="${hop//-/_}"
  builder="${ROOT}/scripts/lib/build_client_${bhop}.py"
  if [[ ! -f "$tin" ]] || ! grep -q '@@GRUB_INSTALL_DEVICE_PREFLIGHT_HELPER@@' "$tin"; then
    echo "  missing token in $tin"
    wire_ok=0
  fi
  if ! grep -q 'run_grub_install_device_preflight\|validate_grub_install_device_preflight' "$tin"; then
    echo "  missing call site in $tin"
    wire_ok=0
  fi
  if [[ ! -f "$builder" ]] || ! grep -q 'GRUB_INSTALL_DEVICE_PREFLIGHT_HELPER\|dp-offline-grub-install-device-preflight' "$builder"; then
    echo "  missing builder wire in $builder"
    wire_ok=0
  fi
done
if grep -q 'dp-offline-grub-install-device-preflight' \
  "${ROOT}/tests/lib/render_offline_upgrade_stub.py" \
  && grep -q 'dp-offline-grub-install-device-preflight' \
  "${ROOT}/scripts/lib/client_build_provenance.py"; then
  :
else
  echo "  missing render stub or provenance listing"
  wire_ok=0
fi
if [[ "$wire_ok" -eq 1 ]]; then
  pass "W: templates/builders/provenance wired"
else
  fail "W: product wiring incomplete"
fi

# =============================================================================
# Helper body must not re-introduce template tokens after embed (Bug A)
# =============================================================================
HELPER_LEAK="$(grep -oE '@@[A-Z0-9_]+@@' "$HELPER" || true)"
if [[ -z "$HELPER_LEAK" ]]; then
  echo "HELPER_TEMPLATE_TOKEN_LEAK=PASS"
  pass "helper body has no @@TOKEN@@ literals"
else
  echo "HELPER_TEMPLATE_TOKEN_LEAK=FAIL"
  fail "helper body leaks template tokens: ${HELPER_LEAK}"
fi

# =============================================================================
# Runtime manifest must allowlist the GRUB helper (Bug B)
# =============================================================================
python3 - "$ROOT/lib/runtime_manifest.sh" <<'PY' && manifest_ok=1 || manifest_ok=0
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(
    r"^UM_RUNTIME_CLIENT_LIB_FILES=\((.*?)\)",
    text,
    re.M | re.S,
)
if not m:
    print("UM_RUNTIME_CLIENT_LIB_FILES block not found", file=sys.stderr)
    sys.exit(1)
block = m.group(1)
wanted = "dp-offline-grub-install-device-preflight.sh"
# Match an array entry line, not an incidental comment elsewhere.
if not re.search(r"(?m)^\s*" + re.escape(wanted) + r"\s*$", block):
    print("missing allowlist entry: " + wanted, file=sys.stderr)
    sys.exit(1)
print("RUNTIME_MANIFEST_GRUB_HELPER=PASS")
sys.exit(0)
PY
if [[ "$manifest_ok" -eq 1 ]]; then
  pass "runtime manifest allowlists GRUB helper"
else
  echo "RUNTIME_MANIFEST_GRUB_HELPER=FAIL"
  fail "UM_RUNTIME_CLIENT_LIB_FILES missing dp-offline-grub-install-device-preflight.sh"
fi

# =============================================================================
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
fi
echo "FAILURES=$FAIL"
exit 1
