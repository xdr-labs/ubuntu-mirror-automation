#!/usr/bin/env bash
# Targeted regression: AWS/BIOS stale grub-pc install_devices preflight hardening.
# Covers inspect (read-only) vs reconcile (transactional), partition rejection,
# BEFORE/AFTER evidence, xvda parent derivation, wiring, and rollback paths.
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
    GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK GRUB_PF_OVERRIDE_DEBCONF_STORE \
    GRUB_PF_OVERRIDE_DISKS_CHANGED GRUB_PF_OVERRIDE_EMPTY \
    GRUB_PF_RESOLVE_MAP GRUB_PF_DRY_RUN GRUB_PF_MODE \
    GRUB_PF_FORCE_SET_FAIL GRUB_PF_FORCE_SET_FAIL_AT \
    GRUB_PF_FORCE_READBACK_FAIL GRUB_PF_FORCE_ROLLBACK_FAIL || true
  BOOT_MODE=""
  ROOT_SOURCE=""
  ROOT_PARENT_DISK=""
  GRUB_INSTALL_DEVICE_BEFORE=""
  GRUB_INSTALL_DEVICE_STATUS_BEFORE=""
  GRUB_INSTALL_DEVICE_CURRENT=""
  GRUB_INSTALL_DEVICE_RESOLVED=""
  GRUB_INSTALL_DEVICE_EXPECTED=""
  GRUB_INSTALL_DEVICE_AFTER=""
  GRUB_INSTALL_DEVICE_STATUS_AFTER=""
  GRUB_INSTALL_DEVICE_STATUS=""
  GRUB_INSTALL_DEVICE_ACTION="NONE"
  GRUB_INSTALL_DEVICE_REBIND_RESULT=""
  GRUB_INSTALL_DEVICE_ROLLBACK_ATTEMPTED=""
  GRUB_INSTALL_DEVICE_ROLLBACK_RESULT=""
  GRUB_INSTALL_DEVICE_PREFLIGHT=""
  AWS_EBS_CURRENT_VOLUME_ID=""
  GRUB_PF_SET_COUNT=0
}

# shellcheck disable=SC1090
source "$HELPER"

setup_by_id() {
  local dir="$1"; shift
  local pair name target
  mkdir -p "$dir"
  for pair in "$@"; do
    name="${pair%%=>*}"
    target="${pair#*=>}"
    ln -sfn "$target" "$dir/$name"
  done
}

init_debconf_store() {
  # $1=store path, $2=install_devices value
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

# =============================================================================
# A: AWS NVMe stale → read-only inspect reports WOULD_REBIND, no mutation
# =============================================================================
reset_case
CASE_A_DIR="${TMP}/caseA/by-id"
STALE_A="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0c212bb3c68696534"
NEW_A_NAME="nvme-Amazon_Elastic_Block_Store_vol0438c82c0d9c88bd8"
setup_by_id "$CASE_A_DIR" "${NEW_A_NAME}=>/dev/nvme0n1"
STORE_A="${TMP}/caseA.store"
init_debconf_store "$STORE_A" "$STALE_A"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_A_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_A"
export GRUB_PF_RESOLVE_MAP="${CASE_A_DIR}/${NEW_A_NAME}=>/dev/nvme0n1;/dev/nvme0n1p1=>/dev/nvme0n1p1;/dev/nvme0n1=>/dev/nvme0n1"
export GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK="${TMP}/caseA.set"
: >"${TMP}/caseA.set"
BEFORE_A="$(store_get grub-pc/install_devices "$STORE_A")"

if inspect_grub_install_device; then
  if [[ "$GRUB_INSTALL_DEVICE_STATUS_BEFORE" == "STALE" \
     && "$GRUB_INSTALL_DEVICE_ACTION" == "WOULD_REBIND" \
     && "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "PASS" \
     && "$GRUB_INSTALL_DEVICE_EXPECTED" == "${CASE_A_DIR}/${NEW_A_NAME}" \
     && ! -s "${TMP}/caseA.set" \
     && "$(store_get grub-pc/install_devices "$STORE_A")" == "$BEFORE_A" ]]; then
    pass "A: AWS NVMe stale inspect WOULD_REBIND no mutation"
  else
    fail "A: STATUS_BEFORE=${GRUB_INSTALL_DEVICE_STATUS_BEFORE} ACTION=${GRUB_INSTALL_DEVICE_ACTION} PRE=${GRUB_INSTALL_DEVICE_PREFLIGHT} set=$(cat "${TMP}/caseA.set") store=$(store_get grub-pc/install_devices "$STORE_A")"
  fi
else
  fail "A: inspect returned FAIL"
fi

# =============================================================================
# B: AWS NVMe authoritative reconcile → rebind CURRENT + BEFORE/AFTER evidence
# =============================================================================
reset_case
CASE_B_DIR="${TMP}/caseB/by-id"
STALE_B="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0c212bb3c68696534"
NEW_B_NAME="nvme-Amazon_Elastic_Block_Store_vol0438c82c0d9c88bd8"
setup_by_id "$CASE_B_DIR" "${NEW_B_NAME}=>/dev/nvme0n1"
STORE_B="${TMP}/caseB.store"
init_debconf_store "$STORE_B" "$STALE_B"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_B_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_B"
export GRUB_PF_RESOLVE_MAP="${CASE_B_DIR}/${NEW_B_NAME}=>/dev/nvme0n1;/dev/nvme0n1p1=>/dev/nvme0n1p1;/dev/nvme0n1=>/dev/nvme0n1"
export GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK="${TMP}/caseB.set"
: >"${TMP}/caseB.set"

if reconcile_grub_install_device; then
  AFTER_B="$(store_get grub-pc/install_devices "$STORE_B")"
  if [[ "$GRUB_INSTALL_DEVICE_BEFORE" == "$STALE_B" \
     && "$GRUB_INSTALL_DEVICE_STATUS_BEFORE" == "STALE" \
     && "$GRUB_INSTALL_DEVICE_STATUS_AFTER" == "CURRENT" \
     && "$GRUB_INSTALL_DEVICE_ACTION" == "REBOUND" \
     && "$GRUB_INSTALL_DEVICE_REBIND_RESULT" == "PASS" \
     && "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "PASS" \
     && "$AFTER_B" == "${CASE_B_DIR}/${NEW_B_NAME}" \
     && "$GRUB_INSTALL_DEVICE_AFTER" == "$AFTER_B" \
     && "$AWS_EBS_CURRENT_VOLUME_ID" == "vol0438c82c0d9c88bd8" ]]; then
    pass "B: AWS NVMe reconcile rebound + BEFORE/AFTER"
  else
    fail "B: BEFORE=${GRUB_INSTALL_DEVICE_BEFORE} STATUS_B=${GRUB_INSTALL_DEVICE_STATUS_BEFORE} STATUS_A=${GRUB_INSTALL_DEVICE_STATUS_AFTER} AFTER=${GRUB_INSTALL_DEVICE_AFTER} store=${AFTER_B}"
  fi
else
  fail "B: reconcile FAIL"
fi

# =============================================================================
# C: AWS NVMe already current → no mutation
# =============================================================================
reset_case
CASE_C_DIR="${TMP}/caseC/by-id"
setup_by_id "$CASE_C_DIR" \
  "nvme-Amazon_Elastic_Block_Store_vol0438c82c0d9c88bd8=>/dev/nvme0n1"
CUR_C="${CASE_C_DIR}/nvme-Amazon_Elastic_Block_Store_vol0438c82c0d9c88bd8"
STORE_C="${TMP}/caseC.store"
init_debconf_store "$STORE_C" "$CUR_C"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_C_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_C"
export GRUB_PF_RESOLVE_MAP="${CUR_C}=>/dev/nvme0n1;/dev/nvme0n1p1=>/dev/nvme0n1p1;/dev/nvme0n1=>/dev/nvme0n1"
export GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK="${TMP}/caseC.set"
: >"${TMP}/caseC.set"

if reconcile_grub_install_device \
  && [[ "$GRUB_INSTALL_DEVICE_ACTION" == "NONE" \
     && "$GRUB_INSTALL_DEVICE_STATUS" == "CURRENT" \
     && "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "PASS" \
     && ! -s "${TMP}/caseC.set" \
     && "$(store_get grub-pc/install_devices "$STORE_C")" == "$CUR_C" ]]; then
  pass "C: AWS NVMe current no mutation"
else
  fail "C: ACTION=${GRUB_INSTALL_DEVICE_ACTION} PRE=${GRUB_INSTALL_DEVICE_PREFLIGHT} set=$(cat "${TMP}/caseC.set")"
fi

# =============================================================================
# D: AWS /dev/xvda — REAL parent derivation (no PARENT_DISK override)
# =============================================================================
reset_case
CASE_D_DIR="${TMP}/caseD/by-id"
setup_by_id "$CASE_D_DIR" \
  "xen-AWS_Elastic_Block_Store_vol11111111111111111=>/dev/xvda"
STORE_D="${TMP}/caseD.store"
init_debconf_store "$STORE_D" "/dev/disk/by-id/xen-AWS_Elastic_Block_Store_volDEADOLD"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/xvda1
# Intentionally NO GRUB_PF_OVERRIDE_PARENT_DISK — naming derivation must work.
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_D_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_D"
export GRUB_PF_RESOLVE_MAP="/dev/xvda1=>/dev/xvda1;/dev/xvda=>/dev/xvda;${CASE_D_DIR}/xen-AWS_Elastic_Block_Store_vol11111111111111111=>/dev/xvda"
export GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK="${TMP}/caseD.set"
: >"${TMP}/caseD.set"

if reconcile_grub_install_device; then
  if [[ "$ROOT_PARENT_DISK" == "/dev/xvda" \
     && "$GRUB_INSTALL_DEVICE_ACTION" == "REBOUND" \
     && "$GRUB_INSTALL_DEVICE_REBIND_RESULT" == "PASS" \
     && "$GRUB_INSTALL_DEVICE_EXPECTED" == "${CASE_D_DIR}/xen-AWS_Elastic_Block_Store_vol11111111111111111" ]]; then
    pass "D: xvda parent derived + rebind"
  else
    fail "D: PARENT=${ROOT_PARENT_DISK} ACTION=${GRUB_INSTALL_DEVICE_ACTION} EXP=${GRUB_INSTALL_DEVICE_EXPECTED}"
  fi
else
  fail "D: reconcile FAIL"
fi

# No NVMe hardcoding
if grep -nE 'EXPECTED=/dev/nvme0n1|printf .*/dev/nvme0n1[" ]' "$HELPER" \
  | grep -v 'No NVMe hardcoding\|nvme\[0-9\]' >/dev/null; then
  fail "D: helper appears to hardcode /dev/nvme0n1"
else
  pass "D: no /dev/nvme0n1 hardcoding"
fi

# =============================================================================
# E: generic /dev/sda current preserved
# =============================================================================
reset_case
CASE_E_DIR="${TMP}/caseE/by-id"
setup_by_id "$CASE_E_DIR" "ata-VBOX_HARDDISK_VB123=>/dev/sda"
CUR_E="${CASE_E_DIR}/ata-VBOX_HARDDISK_VB123"
STORE_E="${TMP}/caseE.store"
init_debconf_store "$STORE_E" "$CUR_E"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/sda1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_E_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_E"
export GRUB_PF_RESOLVE_MAP="${CUR_E}=>/dev/sda;/dev/sda1=>/dev/sda1;/dev/sda=>/dev/sda"
# No parent override — naming derivation for sda1→sda
export GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK="${TMP}/caseE.set"
: >"${TMP}/caseE.set"

if reconcile_grub_install_device \
  && [[ "$ROOT_PARENT_DISK" == "/dev/sda" \
     && "$GRUB_INSTALL_DEVICE_ACTION" == "NONE" \
     && "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "PASS" \
     && ! -s "${TMP}/caseE.set" ]]; then
  pass "E: generic sda current preserved"
else
  fail "E: PARENT=${ROOT_PARENT_DISK} ACTION=${GRUB_INSTALL_DEVICE_ACTION} PRE=${GRUB_INSTALL_DEVICE_PREFLIGHT}"
fi

# =============================================================================
# F: whole-disk fallback when no useful by-id
# =============================================================================
reset_case
CASE_F_DIR="${TMP}/caseF/by-id"
mkdir -p "$CASE_F_DIR"
# empty by-id dir
STORE_F="${TMP}/caseF.store"
init_debconf_store "$STORE_F" "/dev/disk/by-id/missing-volOLD"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/vda1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_F_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_F"
export GRUB_PF_RESOLVE_MAP="/dev/vda1=>/dev/vda1;/dev/vda=>/dev/vda"
export GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK="${TMP}/caseF.set"
: >"${TMP}/caseF.set"

if reconcile_grub_install_device; then
  if [[ "$GRUB_INSTALL_DEVICE_EXPECTED" == "/dev/vda" \
     && "$GRUB_INSTALL_DEVICE_ACTION" == "REBOUND" \
     && "$GRUB_INSTALL_DEVICE_REBIND_RESULT" == "PASS" \
     && "$(store_get grub-pc/install_devices "$STORE_F")" == "/dev/vda" ]]; then
    pass "F: whole-disk fallback /dev/vda"
  else
    fail "F: EXP=${GRUB_INSTALL_DEVICE_EXPECTED} ACTION=${GRUB_INSTALL_DEVICE_ACTION} store=$(store_get grub-pc/install_devices "$STORE_F")"
  fi
else
  fail "F: reconcile FAIL"
fi

# =============================================================================
# G: unresolved/ambiguous parent → FAIL CLOSED, no package transition
# =============================================================================
reset_case
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/mapper/mystery
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_INSTALL_DEVICES=/dev/sda
export GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK="${TMP}/caseG.set"
: >"${TMP}/caseG.set"

if inspect_grub_install_device; then
  fail "G: expected FAIL CLOSED on mapper root"
else
  if [[ "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "FAIL" \
     && "$GRUB_INSTALL_DEVICE_STATUS" == "UNRESOLVED" \
     && ! -s "${TMP}/caseG.set" ]]; then
    pass "G: ambiguous parent fail-closed no mutation"
  else
    fail "G: PRE=${GRUB_INSTALL_DEVICE_PREFLIGHT} STATUS=${GRUB_INSTALL_DEVICE_STATUS}"
  fi
fi

# =============================================================================
# H: debconf setter failure before first write → originals preserved
# =============================================================================
reset_case
CASE_H_DIR="${TMP}/caseH/by-id"
setup_by_id "$CASE_H_DIR" "nvme-Amazon_Elastic_Block_Store_volNEW=>/dev/nvme0n1"
STORE_H="${TMP}/caseH.store"
STALE_H="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_volOLD"
init_debconf_store "$STORE_H" "$STALE_H"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_H_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_H"
export GRUB_PF_RESOLVE_MAP="${CASE_H_DIR}/nvme-Amazon_Elastic_Block_Store_volNEW=>/dev/nvme0n1;/dev/nvme0n1=>/dev/nvme0n1"
export GRUB_PF_FORCE_SET_FAIL=1
export GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK="${TMP}/caseH.set"
: >"${TMP}/caseH.set"

if reconcile_grub_install_device; then
  fail "H: expected FAIL on set-before-write"
else
  if [[ "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "FAIL" \
     && "$GRUB_INSTALL_DEVICE_REBIND_RESULT" == "FAIL" \
     && "$(store_get grub-pc/install_devices "$STORE_H")" == "$STALE_H" \
     && "${GRUB_INSTALL_DEVICE_ROLLBACK_ATTEMPTED:-NO}" == "NO" ]]; then
    pass "H: set-fail before write preserves original"
  else
    fail "H: PRE=${GRUB_INSTALL_DEVICE_PREFLIGHT} ROLLBACK_ATT=${GRUB_INSTALL_DEVICE_ROLLBACK_ATTEMPTED} store=$(store_get grub-pc/install_devices "$STORE_H")"
  fi
fi

# =============================================================================
# I: partial write failure (2nd SET fails) → rollback restores old state
# =============================================================================
reset_case
CASE_I_DIR="${TMP}/caseI/by-id"
setup_by_id "$CASE_I_DIR" "nvme-Amazon_Elastic_Block_Store_volNEW=>/dev/nvme0n1"
STORE_I="${TMP}/caseI.store"
STALE_I="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_volOLD"
init_debconf_store "$STORE_I" "$STALE_I"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_I_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_I"
export GRUB_PF_RESOLVE_MAP="${CASE_I_DIR}/nvme-Amazon_Elastic_Block_Store_volNEW=>/dev/nvme0n1;/dev/nvme0n1=>/dev/nvme0n1"
export GRUB_PF_FORCE_SET_FAIL_AT=2
export GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK="${TMP}/caseI.set"
: >"${TMP}/caseI.set"

if reconcile_grub_install_device; then
  fail "I: expected FAIL on partial write"
else
  if [[ "$GRUB_INSTALL_DEVICE_REBIND_RESULT" == "FAIL" \
     && "$GRUB_INSTALL_DEVICE_ROLLBACK_ATTEMPTED" == "YES" \
     && "$GRUB_INSTALL_DEVICE_ROLLBACK_RESULT" == "PASS" \
     && "$(store_get grub-pc/install_devices "$STORE_I")" == "$STALE_I" \
     && "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "FAIL" ]]; then
    pass "I: partial write rolled back"
  else
    fail "I: REBIND=${GRUB_INSTALL_DEVICE_REBIND_RESULT} RB_ATT=${GRUB_INSTALL_DEVICE_ROLLBACK_ATTEMPTED} RB=${GRUB_INSTALL_DEVICE_ROLLBACK_RESULT} store=$(store_get grub-pc/install_devices "$STORE_I")"
  fi
fi

# =============================================================================
# J: readback verification failure → rollback
# =============================================================================
reset_case
CASE_J_DIR="${TMP}/caseJ/by-id"
setup_by_id "$CASE_J_DIR" "nvme-Amazon_Elastic_Block_Store_volNEW=>/dev/nvme0n1"
STORE_J="${TMP}/caseJ.store"
STALE_J="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_volOLD"
init_debconf_store "$STORE_J" "$STALE_J"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_J_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_J"
export GRUB_PF_RESOLVE_MAP="${CASE_J_DIR}/nvme-Amazon_Elastic_Block_Store_volNEW=>/dev/nvme0n1;/dev/nvme0n1=>/dev/nvme0n1"
export GRUB_PF_FORCE_READBACK_FAIL=1
export GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK="${TMP}/caseJ.set"
: >"${TMP}/caseJ.set"

if reconcile_grub_install_device; then
  fail "J: expected FAIL on readback"
else
  if [[ "$GRUB_INSTALL_DEVICE_REBIND_RESULT" == "FAIL" \
     && "$GRUB_INSTALL_DEVICE_ROLLBACK_ATTEMPTED" == "YES" \
     && "$GRUB_INSTALL_DEVICE_ROLLBACK_RESULT" == "PASS" \
     && "$(store_get grub-pc/install_devices "$STORE_J")" == "$STALE_J" ]]; then
    pass "J: readback failure rolled back"
  else
    fail "J: REBIND=${GRUB_INSTALL_DEVICE_REBIND_RESULT} RB=${GRUB_INSTALL_DEVICE_ROLLBACK_RESULT} store=$(store_get grub-pc/install_devices "$STORE_J")"
  fi
fi

# =============================================================================
# K: rollback failure → explicit evidence + FAIL CLOSED
# =============================================================================
reset_case
CASE_K_DIR="${TMP}/caseK/by-id"
setup_by_id "$CASE_K_DIR" "nvme-Amazon_Elastic_Block_Store_volNEW=>/dev/nvme0n1"
STORE_K="${TMP}/caseK.store"
STALE_K="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_volOLD"
init_debconf_store "$STORE_K" "$STALE_K"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_K_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_K"
export GRUB_PF_RESOLVE_MAP="${CASE_K_DIR}/nvme-Amazon_Elastic_Block_Store_volNEW=>/dev/nvme0n1;/dev/nvme0n1=>/dev/nvme0n1"
export GRUB_PF_FORCE_SET_FAIL_AT=2
export GRUB_PF_FORCE_ROLLBACK_FAIL=1
export GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK="${TMP}/caseK.set"
: >"${TMP}/caseK.set"

if reconcile_grub_install_device; then
  fail "K: expected FAIL on rollback failure"
else
  if [[ "$GRUB_INSTALL_DEVICE_REBIND_RESULT" == "FAIL" \
     && "$GRUB_INSTALL_DEVICE_ROLLBACK_ATTEMPTED" == "YES" \
     && "$GRUB_INSTALL_DEVICE_ROLLBACK_RESULT" == "FAIL" \
     && "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "FAIL" ]]; then
    pass "K: rollback failure fail-closed"
  else
    fail "K: REBIND=${GRUB_INSTALL_DEVICE_REBIND_RESULT} RB_ATT=${GRUB_INSTALL_DEVICE_ROLLBACK_ATTEMPTED} RB=${GRUB_INSTALL_DEVICE_ROLLBACK_RESULT}"
  fi
fi

# =============================================================================
# L: configured root partition /dev/nvme0n1p1 → MUST NOT be CURRENT
# =============================================================================
reset_case
CASE_L_DIR="${TMP}/caseL/by-id"
setup_by_id "$CASE_L_DIR" "nvme-Amazon_Elastic_Block_Store_volCUR=>/dev/nvme0n1"
STORE_L="${TMP}/caseL.store"
init_debconf_store "$STORE_L" "/dev/nvme0n1p1"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_L_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_L"
export GRUB_PF_RESOLVE_MAP="/dev/nvme0n1p1=>/dev/nvme0n1p1;/dev/nvme0n1=>/dev/nvme0n1;${CASE_L_DIR}/nvme-Amazon_Elastic_Block_Store_volCUR=>/dev/nvme0n1"

if inspect_grub_install_device; then
  if [[ "$GRUB_INSTALL_DEVICE_STATUS_BEFORE" != "CURRENT" \
     && "$GRUB_INSTALL_DEVICE_ACTION" == "WOULD_REBIND" ]]; then
    pass "L: partition install device not CURRENT"
  else
    fail "L: STATUS_BEFORE=${GRUB_INSTALL_DEVICE_STATUS_BEFORE} ACTION=${GRUB_INSTALL_DEVICE_ACTION}"
  fi
else
  fail "L: inspect FAIL"
fi

# =============================================================================
# M: partition by-id *-part1 → MUST NOT be CURRENT
# =============================================================================
reset_case
CASE_M_DIR="${TMP}/caseM/by-id"
setup_by_id "$CASE_M_DIR" \
  "nvme-Amazon_Elastic_Block_Store_volCUR=>/dev/nvme0n1" \
  "nvme-Amazon_Elastic_Block_Store_volCUR-part1=>/dev/nvme0n1p1"
PART_M="${CASE_M_DIR}/nvme-Amazon_Elastic_Block_Store_volCUR-part1"
STORE_M="${TMP}/caseM.store"
init_debconf_store "$STORE_M" "$PART_M"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_M_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_M"
export GRUB_PF_RESOLVE_MAP="${PART_M}=>/dev/nvme0n1p1;/dev/nvme0n1p1=>/dev/nvme0n1p1;/dev/nvme0n1=>/dev/nvme0n1;${CASE_M_DIR}/nvme-Amazon_Elastic_Block_Store_volCUR=>/dev/nvme0n1"

if inspect_grub_install_device; then
  if [[ "$GRUB_INSTALL_DEVICE_STATUS_BEFORE" != "CURRENT" \
     && "$GRUB_INSTALL_DEVICE_ACTION" == "WOULD_REBIND" ]]; then
    pass "M: partition by-id not CURRENT"
  else
    fail "M: STATUS_BEFORE=${GRUB_INSTALL_DEVICE_STATUS_BEFORE} ACTION=${GRUB_INSTALL_DEVICE_ACTION}"
  fi
else
  fail "M: inspect FAIL"
fi

# =============================================================================
# N: --preflight-only contract via inspect alias (zero mutation)
# =============================================================================
reset_case
CASE_N_DIR="${TMP}/caseN/by-id"
setup_by_id "$CASE_N_DIR" "nvme-Amazon_Elastic_Block_Store_volNEW=>/dev/nvme0n1"
STORE_N="${TMP}/caseN.store"
STALE_N="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_volOLD"
init_debconf_store "$STORE_N" "$STALE_N"
HASH_N_BEFORE="$(sha256sum "$STORE_N" | awk '{print $1}')"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_N_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_N"
export GRUB_PF_RESOLVE_MAP="${CASE_N_DIR}/nvme-Amazon_Elastic_Block_Store_volNEW=>/dev/nvme0n1;/dev/nvme0n1=>/dev/nvme0n1"

if run_grub_install_device_preflight \
  && [[ "$GRUB_INSTALL_DEVICE_ACTION" == "WOULD_REBIND" \
     && "$(sha256sum "$STORE_N" | awk '{print $1}')" == "$HASH_N_BEFORE" ]]; then
  pass "N: preflight-only alias zero mutation"
else
  fail "N: ACTION=${GRUB_INSTALL_DEVICE_ACTION} hash changed or FAIL"
fi

# =============================================================================
# O: declined confirmation path ≡ inspect leaves store unchanged
# =============================================================================
reset_case
CASE_O_DIR="${TMP}/caseO/by-id"
setup_by_id "$CASE_O_DIR" "nvme-Amazon_Elastic_Block_Store_volNEW=>/dev/nvme0n1"
STORE_O="${TMP}/caseO.store"
STALE_O="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_volOLD"
init_debconf_store "$STORE_O" "$STALE_O"
HASH_O_BEFORE="$(sha256sum "$STORE_O" | awk '{print $1}')"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_O_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_O"
export GRUB_PF_RESOLVE_MAP="${CASE_O_DIR}/nvme-Amazon_Elastic_Block_Store_volNEW=>/dev/nvme0n1;/dev/nvme0n1=>/dev/nvme0n1"

# Simulate: preflight inspect, then "decline" (never call reconcile).
inspect_grub_install_device >/dev/null
if [[ "$(sha256sum "$STORE_O" | awk '{print $1}')" == "$HASH_O_BEFORE" \
   && "$GRUB_INSTALL_DEVICE_ACTION" == "WOULD_REBIND" ]]; then
  pass "O: declined-confirm path zero mutation"
else
  fail "O: store mutated or unexpected ACTION=${GRUB_INSTALL_DEVICE_ACTION}"
fi

# =============================================================================
# P: post-confirmation runner path uses reconcile (static + behavioral)
# =============================================================================
runner_ok=1
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  tin="${ROOT}/client/dp-offline-upgrade-${hop}.sh.in"
  # Extract approximate runner region: after set_stage GRUB_INSTALL_DEVICE_PREFLIGHT
  if ! awk '
    /set_stage "GRUB_INSTALL_DEVICE_PREFLIGHT"/ {inblock=1}
    inblock && /run_grub_install_device_reconcile/ {found=1}
    inblock && /do-release-upgrade/ {exit}
    END {exit found?0:1}
  ' "$tin"; then
    echo "  missing reconcile before DRO in $tin"
    runner_ok=0
  fi
  # Preflight must still call inspect alias, not reconcile
  if ! awk '
    /^run_os_preflight\(/ {inpf=1}
    inpf && /^}/ {exit}
    inpf && /run_grub_install_device_preflight/ {found=1}
    inpf && /run_grub_install_device_reconcile/ {bad=1}
    END {exit (found && !bad)?0:1}
  ' "$tin"; then
    echo "  preflight wiring wrong in $tin"
    runner_ok=0
  fi
done
if [[ "$runner_ok" -eq 1 ]]; then
  pass "P: runner reconcile before DRO; preflight inspect-only"
else
  fail "P: hop wiring for inspect/reconcile incorrect"
fi

# =============================================================================
# Q: package transition ordering — GRUB fail ⇒ PACKAGE_TRANSITION_STARTED=NO
# =============================================================================
reset_case
CASE_Q_DIR="${TMP}/caseQ/by-id"
setup_by_id "$CASE_Q_DIR" "nvme-Amazon_Elastic_Block_Store_volNEW=>/dev/nvme0n1"
STORE_Q="${TMP}/caseQ.store"
init_debconf_store "$STORE_Q" "/dev/disk/by-id/volOLD"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_Q_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_Q"
export GRUB_PF_RESOLVE_MAP="${CASE_Q_DIR}/nvme-Amazon_Elastic_Block_Store_volNEW=>/dev/nvme0n1;/dev/nvme0n1=>/dev/nvme0n1"
export GRUB_PF_FORCE_SET_FAIL=1
Q_OUT="${TMP}/caseQ.out"
set +e
reconcile_grub_install_device >"$Q_OUT" 2>&1
Q_RC=$?
set -e
if [[ "$Q_RC" -ne 0 ]] \
  && grep -q 'PACKAGE_TRANSITION_STARTED=NO' "$Q_OUT" \
  && grep -q 'GRUB_INSTALL_DEVICE_PREFLIGHT=FAIL' "$Q_OUT"; then
  pass "Q: GRUB fail emits PACKAGE_TRANSITION_STARTED=NO"
else
  fail "Q: rc=$Q_RC out=$(tail -5 "$Q_OUT")"
fi
# Static: reconcile precedes do-release-upgrade / package transition mark in templates
order_ok=1
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  tin="${ROOT}/client/dp-offline-upgrade-${hop}.sh.in"
  if ! python3 - "$tin" <<'PY'
import sys
text=open(sys.argv[1],encoding='utf-8').read()
# Find runner block: set_stage GRUB ... then do-release-upgrade stage
i=text.find('set_stage "GRUB_INSTALL_DEVICE_PREFLIGHT"')
j=text.find('set_stage "DO_RELEASE_UPGRADE"', i)
if i<0 or j<0 or i>j:
    sys.exit(1)
block=text[i:j]
if 'run_grub_install_device_reconcile' not in block:
    sys.exit(1)
if 'mark_package_transition' in block or 'PACKAGE_TRANSITION_STARTED=true' in block:
    sys.exit(1)
sys.exit(0)
PY
  then
    order_ok=0
  fi
done
if [[ "$order_ok" -eq 1 ]]; then
  pass "Q: static order GRUB reconcile before DRO"
else
  fail "Q: static package-transition ordering broken"
fi

# =============================================================================
# R: BEFORE/AFTER evidence retains stale value after successful rebind
# =============================================================================
# Covered by case B assertions; explicit guard:
if [[ "${GRUB_INSTALL_DEVICE_BEFORE:-}" == "$STALE_B" ]] 2>/dev/null; then
  :
fi
reset_case
CASE_R_DIR="${TMP}/caseR/by-id"
setup_by_id "$CASE_R_DIR" "nvme-Amazon_Elastic_Block_Store_volNEW=>/dev/nvme0n1"
STORE_R="${TMP}/caseR.store"
STALE_R="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_volOLDDEAD"
init_debconf_store "$STORE_R" "$STALE_R"
export GRUB_PF_OVERRIDE_BOOT_MODE=BIOS
export GRUB_PF_OVERRIDE_ROOT_SOURCE=/dev/nvme0n1p1
export GRUB_PF_OVERRIDE_PARENT_DISK=/dev/nvme0n1
export GRUB_PF_OVERRIDE_BY_ID_DIR="$CASE_R_DIR"
export GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT=1
export GRUB_PF_OVERRIDE_DEBCONF_STORE="$STORE_R"
export GRUB_PF_RESOLVE_MAP="${CASE_R_DIR}/nvme-Amazon_Elastic_Block_Store_volNEW=>/dev/nvme0n1;/dev/nvme0n1=>/dev/nvme0n1"
R_OUT="${TMP}/caseR.out"
reconcile_grub_install_device >"$R_OUT" 2>&1
if grep -q "GRUB_INSTALL_DEVICE_BEFORE=${STALE_R}" "$R_OUT" \
  && grep -q "GRUB_INSTALL_DEVICE_STATUS_BEFORE=STALE" "$R_OUT" \
  && grep -q "GRUB_INSTALL_DEVICE_STATUS_AFTER=CURRENT" "$R_OUT" \
  && grep -q "GRUB_INSTALL_DEVICE_REBIND_RESULT=PASS" "$R_OUT"; then
  pass "R: BEFORE/AFTER evidence preserved"
else
  fail "R: evidence missing in $(grep GRUB_INSTALL_DEVICE_ "$R_OUT" | tr '\n' ' ')"
fi

# =============================================================================
# S/T/U: wiring, runtime manifest, no template token leak
# =============================================================================
wire_ok=1
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  tin="${ROOT}/client/dp-offline-upgrade-${hop}.sh.in"
  bhop="${hop//-/_}"
  builder="${ROOT}/scripts/lib/build_client_${bhop}.py"
  if [[ ! -f "$tin" ]] || ! grep -q '@@GRUB_INSTALL_DEVICE_PREFLIGHT_HELPER@@' "$tin"; then
    echo "  missing token in $tin"; wire_ok=0
  fi
  if ! grep -q 'run_grub_install_device_preflight' "$tin"; then
    echo "  missing preflight call in $tin"; wire_ok=0
  fi
  if ! grep -q 'run_grub_install_device_reconcile' "$tin"; then
    echo "  missing reconcile call in $tin"; wire_ok=0
  fi
  if [[ ! -f "$builder" ]] || ! grep -q 'dp-offline-grub-install-device-preflight' "$builder"; then
    echo "  missing builder wire in $builder"; wire_ok=0
  fi
done
if grep -q 'dp-offline-grub-install-device-preflight' \
  "${ROOT}/tests/lib/render_offline_upgrade_stub.py" \
  && grep -q 'dp-offline-grub-install-device-preflight' \
  "${ROOT}/scripts/lib/client_build_provenance.py"; then
  :
else
  echo "  missing render stub or provenance listing"; wire_ok=0
fi
if [[ "$wire_ok" -eq 1 ]]; then
  pass "S: all four hops + builders wired"
else
  fail "S: product wiring incomplete"
fi

HELPER_LEAK="$(grep -oE '@@[A-Z0-9_]+@@' "$HELPER" || true)"
if [[ -z "$HELPER_LEAK" ]]; then
  echo "HELPER_TEMPLATE_TOKEN_LEAK=PASS"
  pass "U: helper body has no @@TOKEN@@ literals"
else
  echo "HELPER_TEMPLATE_TOKEN_LEAK=FAIL"
  fail "U: helper body leaks template tokens: ${HELPER_LEAK}"
fi

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
if not re.search(r"(?m)^\s*" + re.escape(wanted) + r"\s*$", block):
    print("missing allowlist entry: " + wanted, file=sys.stderr)
    sys.exit(1)
print("RUNTIME_MANIFEST_GRUB_HELPER=PASS")
sys.exit(0)
PY
if [[ "$manifest_ok" -eq 1 ]]; then
  pass "T: runtime manifest allowlists GRUB helper"
else
  echo "RUNTIME_MANIFEST_GRUB_HELPER=FAIL"
  fail "T: UM_RUNTIME_CLIENT_LIB_FILES missing helper"
fi

# Cheap deferred finding: mapper roots fail closed (case G).
echo "COMPLEX_BLOCK_TOPOLOGY_SUPPORT=DEFERRED_FAIL_CLOSED"

# =============================================================================
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
fi
echo "FAILURES=$FAIL"
exit 1
