# shellcheck shell=bash
# Shared BIOS/grub-pc install_devices preflight for offline OS-hop clients.
#
# Injected at build time through the GRUB install-device preflight helper token.
# Directly sourceable by fixture tests.
#
# Correctness is based on resolved block-device identity (root → parent disk),
# not hardcoded NVMe paths or AWS volume IDs. EBS volume IDs are diagnostic only.
#
# Contract:
#   BIOS + grub-pc relevant → prove grub-pc/install_devices maps to current
#   root parent WHOLE disk (reconcile when stale/invalid). Fail closed otherwise.
#   EFI / non-grub-pc → SKIP (PASS).
#
# Modes:
#   inspect   — read-only classify/evidence (client --preflight-only / pre-confirm)
#   reconcile — authoritative transactional debconf mutation (runner pre-DRO)
#
# Evidence globals (exported for callers/tests):
#   BOOT_MODE ROOT_SOURCE ROOT_PARENT_DISK
#   GRUB_INSTALL_DEVICE_BEFORE GRUB_INSTALL_DEVICE_STATUS_BEFORE
#   GRUB_INSTALL_DEVICE_CURRENT GRUB_INSTALL_DEVICE_RESOLVED
#   GRUB_INSTALL_DEVICE_EXPECTED
#   GRUB_INSTALL_DEVICE_AFTER GRUB_INSTALL_DEVICE_STATUS_AFTER
#   GRUB_INSTALL_DEVICE_STATUS
#   GRUB_INSTALL_DEVICE_ACTION GRUB_INSTALL_DEVICE_REBIND_RESULT
#   GRUB_INSTALL_DEVICE_ROLLBACK_ATTEMPTED GRUB_INSTALL_DEVICE_ROLLBACK_RESULT
#   GRUB_INSTALL_DEVICE_PREFLIGHT AWS_EBS_CURRENT_VOLUME_ID
#   PACKAGE_TRANSITION_STARTED (forced NO on hard fail path logging)

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

# Snapshot of debconf keys touched by reconciliation (for rollback).
GRUB_PF_SNAP_INSTALL_DEVICES=""
GRUB_PF_SNAP_DISKS_CHANGED=""
GRUB_PF_SNAP_EMPTY=""
GRUB_PF_SNAP_TAKEN=0

grub_pf_log() {
  local level="$1"; shift
  if declare -F log >/dev/null 2>&1; then
    log "$level" "$*"
  else
    printf '%s: %s\n' "$level" "$*"
  fi
}

grub_pf_hp() {
  local p="$1"
  if declare -F hostpath >/dev/null 2>&1; then
    hostpath "$p"
  elif declare -F _hp >/dev/null 2>&1; then
    _hp "$p"
  elif [[ -n "${TEST_ROOT:-}" ]]; then
    printf '%s%s' "${TEST_ROOT%/}" "$p"
  else
    printf '%s' "$p"
  fi
}

grub_pf_emit_evidence() {
  grub_pf_log INFO "BOOT_MODE=${BOOT_MODE}"
  grub_pf_log INFO "ROOT_SOURCE=${ROOT_SOURCE}"
  grub_pf_log INFO "ROOT_PARENT_DISK=${ROOT_PARENT_DISK}"
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_BEFORE=${GRUB_INSTALL_DEVICE_BEFORE}"
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_STATUS_BEFORE=${GRUB_INSTALL_DEVICE_STATUS_BEFORE}"
  # Compatibility: CURRENT mirrors BEFORE when present, else AFTER.
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_CURRENT=${GRUB_INSTALL_DEVICE_CURRENT}"
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_RESOLVED=${GRUB_INSTALL_DEVICE_RESOLVED}"
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_EXPECTED=${GRUB_INSTALL_DEVICE_EXPECTED}"
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_AFTER=${GRUB_INSTALL_DEVICE_AFTER}"
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_STATUS_AFTER=${GRUB_INSTALL_DEVICE_STATUS_AFTER}"
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_STATUS=${GRUB_INSTALL_DEVICE_STATUS}"
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_ACTION=${GRUB_INSTALL_DEVICE_ACTION}"
  if [[ -n "${GRUB_INSTALL_DEVICE_REBIND_RESULT}" ]]; then
    grub_pf_log INFO "GRUB_INSTALL_DEVICE_REBIND_RESULT=${GRUB_INSTALL_DEVICE_REBIND_RESULT}"
  fi
  if [[ -n "${GRUB_INSTALL_DEVICE_ROLLBACK_ATTEMPTED}" ]]; then
    grub_pf_log INFO "GRUB_INSTALL_DEVICE_ROLLBACK_ATTEMPTED=${GRUB_INSTALL_DEVICE_ROLLBACK_ATTEMPTED}"
    grub_pf_log INFO "GRUB_INSTALL_DEVICE_ROLLBACK_RESULT=${GRUB_INSTALL_DEVICE_ROLLBACK_RESULT}"
  fi
  if [[ -n "${AWS_EBS_CURRENT_VOLUME_ID}" ]]; then
    grub_pf_log INFO "AWS_EBS_CURRENT_VOLUME_ID=${AWS_EBS_CURRENT_VOLUME_ID}"
  fi
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_PREFLIGHT=${GRUB_INSTALL_DEVICE_PREFLIGHT}"
}

grub_pf_fail_closed() {
  local reason="$1"
  GRUB_INSTALL_DEVICE_PREFLIGHT="FAIL"
  grub_pf_emit_evidence
  grub_pf_log ERROR "PACKAGE_TRANSITION_STARTED=NO"
  grub_pf_log ERROR "GRUB_INSTALL_DEVICE_PREFLIGHT=FAIL reason=${reason}"
  return 1
}

# --- boot mode -------------------------------------------------------------

grub_pf_detect_boot_mode() {
  if [[ -n "${GRUB_PF_OVERRIDE_BOOT_MODE:-}" ]]; then
    printf '%s' "$GRUB_PF_OVERRIDE_BOOT_MODE"
    return 0
  fi
  if [[ -d "$(grub_pf_hp /sys/firmware/efi)" || -d /sys/firmware/efi ]]; then
    printf 'EFI'
  else
    printf 'BIOS'
  fi
}

# --- root / parent disk resolution -----------------------------------------

grub_pf_read_root_source() {
  local src=""
  if [[ -n "${GRUB_PF_OVERRIDE_ROOT_SOURCE:-}" ]]; then
    printf '%s' "$GRUB_PF_OVERRIDE_ROOT_SOURCE"
    return 0
  fi
  if command -v findmnt >/dev/null 2>&1; then
    src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  fi
  if [[ -z "$src" && -r /proc/mounts ]]; then
    src="$(awk '$2=="/"{print $1; exit}' /proc/mounts 2>/dev/null || true)"
  fi
  printf '%s' "$src"
}

# Resolve a path that may be a symlink; empty if the path does not exist.
# Overridable for fixture tests.
grub_pf_resolve_path() {
  local p="$1"
  if [[ -n "${GRUB_PF_RESOLVE_MAP:-}" ]]; then
    # Format: path=>resolved;path2=>resolved2
    local entry key val
    IFS=';' read -r -a _grub_pf_map_entries <<<"${GRUB_PF_RESOLVE_MAP}"
    for entry in "${_grub_pf_map_entries[@]}"; do
      key="${entry%%=>*}"
      val="${entry#*=>}"
      if [[ "$key" == "$p" ]]; then
        printf '%s' "$val"
        return 0
      fi
    done
  fi
  if [[ ! -e "$p" && ! -L "$p" ]]; then
    return 1
  fi
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$p" 2>/dev/null || realpath "$p" 2>/dev/null || printf '%s' "$p"
  elif command -v realpath >/dev/null 2>&1; then
    realpath "$p" 2>/dev/null || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

# Strip /dev/ and return basename.
grub_pf_dev_basename() {
  local d="$1"
  d="${d#/dev/}"
  d="${d#/dev/}"
  printf '%s' "$d"
}

# True if basename looks like a partition node (not whole disk).
# Covers nvme*n*pN, mmcblk*pN, sd/vd/xvd/hd + digits. No NVMe path hardcoding.
grub_pf_is_partition_name() {
  local base="$1"
  [[ -n "$base" ]] || return 1
  if [[ "$base" =~ ^(nvme[0-9]+n[0-9]+|mmcblk[0-9]+)p[0-9]+$ ]]; then
    return 0
  fi
  if [[ "$base" =~ ^(sd|vd|xvd|hd)[a-z]+[0-9]+$ ]]; then
    return 0
  fi
  return 1
}

# Naming-only parent derivation (no lsblk/sysfs). Used as last resort and by
# fixtures that exercise real derivation without host block devices.
grub_pf_parent_disk_from_name() {
  local base="$1" parent=""
  [[ -n "$base" ]] || return 1
  if [[ "$base" =~ ^(nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
    parent="${BASH_REMATCH[1]}"
  elif [[ "$base" =~ ^(mmcblk[0-9]+)p[0-9]+$ ]]; then
    parent="${BASH_REMATCH[1]}"
  elif [[ "$base" =~ ^((sd|vd|xvd|hd)[a-z]+)[0-9]+$ ]]; then
    parent="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  printf '/dev/%s' "$parent"
}

# Derive parent disk for a block device node (partition or whole disk).
# No NVMe hardcoding: works for nvme*n*p*, sd*, vd*, xvd*, hd*.
# Mapper/LVM/RAID/dm roots are intentionally unresolved (fail closed).
grub_pf_parent_disk_of() {
  local src="$1" base pk parent sysdev resolved=""
  if [[ -n "${GRUB_PF_OVERRIDE_PARENT_DISK:-}" ]]; then
    printf '%s' "$GRUB_PF_OVERRIDE_PARENT_DISK"
    return 0
  fi
  [[ -n "$src" ]] || return 1

  # If already a by-id (or other) path that resolves, canonicalize first.
  if resolved="$(grub_pf_resolve_path "$src" 2>/dev/null)"; then
    src="$resolved"
  fi

  base="$(grub_pf_dev_basename "$src")"
  [[ -n "$base" ]] || return 1

  # Complex topologies: do not guess a boot disk from mapper/dm/md names.
  case "$base" in
    mapper/*|dm-*|md*|loop*)
      return 1
      ;;
  esac
  if [[ "$src" == /dev/mapper/* || "$src" == /dev/dm-* ]]; then
    return 1
  fi

  if command -v lsblk >/dev/null 2>&1; then
    pk="$(lsblk -ndo PKNAME "$src" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
    if [[ -n "$pk" ]]; then
      printf '/dev/%s' "$pk"
      return 0
    fi
  fi

  # sysfs: partition nodes live under .../block/<parent>/<partition>
  if [[ -e "/sys/class/block/${base}/partition" ]]; then
    sysdev="$(readlink -f "/sys/class/block/${base}" 2>/dev/null || true)"
    if [[ -n "$sysdev" ]]; then
      parent="$(basename "$(dirname "$sysdev")")"
      if [[ -n "$parent" && "$parent" != "block" ]]; then
        printf '/dev/%s' "$parent"
        return 0
      fi
    fi
  fi

  # Deterministic naming fallback (partition → whole disk).
  if parent="$(grub_pf_parent_disk_from_name "$base" 2>/dev/null)"; then
    printf '%s' "$parent"
    return 0
  fi

  # Whole-disk root — treat device as parent only when the block node exists
  # or naming clearly indicates a whole disk (not a partition).
  if ! grub_pf_is_partition_name "$base"; then
    if [[ -b "$src" || -e "/sys/class/block/${base}" || -n "${GRUB_PF_RESOLVE_MAP:-}" ]]; then
      printf '/dev/%s' "$base"
      return 0
    fi
  fi
  return 1
}

# --- by-id candidates ------------------------------------------------------

grub_pf_by_id_dir() {
  if [[ -n "${GRUB_PF_OVERRIDE_BY_ID_DIR:-}" ]]; then
    printf '%s' "$GRUB_PF_OVERRIDE_BY_ID_DIR"
    return 0
  fi
  printf '%s' "$(grub_pf_hp /dev/disk/by-id)"
}

# List by-id paths whose resolved target equals the parent disk.
# Prints one path per line. Skips *-partN partition links.
grub_pf_list_by_id_for_parent() {
  local parent="$1" dir link target base
  dir="$(grub_pf_by_id_dir)"
  [[ -d "$dir" ]] || return 0
  # shellcheck disable=SC2045
  for link in "$dir"/*; do
    [[ -e "$link" || -L "$link" ]] || continue
    base="$(basename "$link")"
    # Skip partition-specific links; grub-pc wants the disk.
    if [[ "$base" =~ -part[0-9]+$ ]]; then
      continue
    fi
    target="$(grub_pf_resolve_path "$link" 2>/dev/null || true)"
    [[ -n "$target" ]] || continue
    if [[ "$target" == "$parent" ]]; then
      printf '%s\n' "$link"
    fi
  done
}

# Prefer stable AWS EBS by-id, then other by-id, then raw parent path.
grub_pf_select_expected_device() {
  local parent="$1" cand ebs_pref="" other_pref=""
  while IFS= read -r cand; do
    [[ -n "$cand" ]] || continue
    case "$(basename "$cand")" in
      *Amazon_Elastic_Block_Store_vol*|nvme-Amazon_Elastic_Block_Store_vol*|xen-AWS_*-vol*)
        if [[ -z "$ebs_pref" ]]; then
          ebs_pref="$cand"
        fi
        ;;
      *)
        if [[ -z "$other_pref" ]]; then
          other_pref="$cand"
        fi
        ;;
    esac
  done < <(grub_pf_list_by_id_for_parent "$parent")

  if [[ -n "$ebs_pref" ]]; then
    printf '%s' "$ebs_pref"
    return 0
  fi
  if [[ -n "$other_pref" ]]; then
    printf '%s' "$other_pref"
    return 0
  fi
  # Fall back to the parent disk node itself (xvda/sda/vda/nvme).
  printf '%s' "$parent"
}

grub_pf_extract_ebs_vol_id() {
  local path="$1" base
  base="$(basename "$path")"
  if [[ "$base" =~ (vol[0-9a-f]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# --- debconf ---------------------------------------------------------------

grub_pf_grub_pc_relevant() {
  if [[ -n "${GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT:-}" ]]; then
    [[ "${GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT}" == "1" || "${GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT}" == "yes" ]]
    return $?
  fi
  local status
  status="$(dpkg-query -W -f='${Status}' grub-pc 2>/dev/null || true)"
  # Installed, unpacked, half-configured, etc. — any dpkg presence of grub-pc.
  [[ "$status" == *"installed"* || "$status" == *"unpacked"* || "$status" == *"half-configured"* || "$status" == *"config-files"* ]]
}

# Get a single grub-pc debconf key via debconf-communicate (Xenial-safe).
# Prints value on success; empty + return 0 if key unset; return 1 on tool failure.
grub_pf_debconf_get_key() {
  local key="$1" out
  if [[ -n "${GRUB_PF_OVERRIDE_DEBCONF_STORE:-}" ]]; then
    # Test store: KEY=value lines
    out="$(awk -F= -v k="$key" '$1==k{print substr($0,index($0,"=")+1); exit}' \
      "$GRUB_PF_OVERRIDE_DEBCONF_STORE" 2>/dev/null || true)"
    printf '%s' "$out"
    return 0
  fi
  if [[ -n "${GRUB_PF_OVERRIDE_INSTALL_DEVICES+x}" && "$key" == "grub-pc/install_devices" ]]; then
    printf '%s' "${GRUB_PF_OVERRIDE_INSTALL_DEVICES}"
    return 0
  fi
  if [[ -n "${GRUB_PF_OVERRIDE_DISKS_CHANGED+x}" && "$key" == "grub-pc/install_devices_disks_changed" ]]; then
    printf '%s' "${GRUB_PF_OVERRIDE_DISKS_CHANGED}"
    return 0
  fi
  if [[ -n "${GRUB_PF_OVERRIDE_EMPTY+x}" && "$key" == "grub-pc/install_devices_empty" ]]; then
    printf '%s' "${GRUB_PF_OVERRIDE_EMPTY}"
    return 0
  fi
  if ! command -v debconf-communicate >/dev/null 2>&1; then
    return 1
  fi
  out="$(echo "get ${key}" | debconf-communicate 2>/dev/null || true)"
  # Format: "0 value" or "10 ..."
  if [[ "$out" =~ ^0[[:space:]]+(.*)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$out" =~ ^0[[:space:]]*$ ]]; then
    printf ''
    return 0
  fi
  # Fallback: debconf-show for install_devices only
  if [[ "$key" == "grub-pc/install_devices" ]] && command -v debconf-show >/dev/null 2>&1; then
    out="$(debconf-show grub-pc 2>/dev/null | awk -F': ' '/install_devices:/{print $2; exit}' || true)"
    printf '%s' "$out"
    return 0
  fi
  return 1
}

grub_pf_debconf_get_install_devices() {
  grub_pf_debconf_get_key "grub-pc/install_devices"
}

# Write one debconf key. Supports test fail-injection:
#   GRUB_PF_FORCE_SET_FAIL=1           — fail before any write
#   GRUB_PF_FORCE_SET_FAIL_AT=N        — fail on Nth write (1-based)
#   GRUB_PF_SET_COUNT                  — internal counter
grub_pf_debconf_set_key() {
  local key="$1" type="$2" value="$3"
  local next_count=$((${GRUB_PF_SET_COUNT:-0} + 1))

  if [[ "${GRUB_PF_FORCE_SET_FAIL:-0}" == "1" ]]; then
    return 1
  fi
  if [[ -n "${GRUB_PF_FORCE_SET_FAIL_AT:-}" \
      && "${next_count}" -eq "${GRUB_PF_FORCE_SET_FAIL_AT}" ]]; then
    return 1
  fi
  GRUB_PF_SET_COUNT="$next_count"

  if [[ -n "${GRUB_PF_OVERRIDE_DEBCONF_STORE:-}" ]]; then
    local store="$GRUB_PF_OVERRIDE_DEBCONF_STORE" tmp
    tmp="${store}.tmp.$$"
    if [[ -f "$store" ]]; then
      grep -v "^${key}=" "$store" >"$tmp" 2>/dev/null || : >"$tmp"
    else
      : >"$tmp"
    fi
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    mv -f "$tmp" "$store"
    if [[ -n "${GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK:-}" ]]; then
      printf 'SET %s %s\n' "$key" "$value" >>"$GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK"
    fi
    # Keep legacy override in sync for install_devices.
    if [[ "$key" == "grub-pc/install_devices" ]]; then
      GRUB_PF_OVERRIDE_INSTALL_DEVICES="$value"
    fi
    return 0
  fi

  if [[ -n "${GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK:-}" ]]; then
    printf 'SET %s %s\n' "$key" "$value" >>"$GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK"
    if [[ "$key" == "grub-pc/install_devices" ]]; then
      GRUB_PF_OVERRIDE_INSTALL_DEVICES="$value"
    elif [[ "$key" == "grub-pc/install_devices_disks_changed" ]]; then
      GRUB_PF_OVERRIDE_DISKS_CHANGED="$value"
    elif [[ "$key" == "grub-pc/install_devices_empty" ]]; then
      GRUB_PF_OVERRIDE_EMPTY="$value"
    fi
    return 0
  fi

  if [[ "${GRUB_PF_DRY_RUN:-0}" == "1" ]]; then
    if [[ "$key" == "grub-pc/install_devices" ]]; then
      GRUB_PF_OVERRIDE_INSTALL_DEVICES="$value"
    fi
    return 0
  fi

  if ! command -v debconf-set-selections >/dev/null 2>&1; then
    return 1
  fi
  printf 'grub-pc %s %s %s\n' "$key" "$type" "$value" | debconf-set-selections || return 1
  return 0
}

# Legacy single-device setter (writes all three keys). Prefer transactional path.
grub_pf_debconf_set_install_devices() {
  local device="$1"
  GRUB_PF_SET_COUNT=0
  grub_pf_debconf_set_key "grub-pc/install_devices" multiselect "$device" || return 1
  grub_pf_debconf_set_key "grub-pc/install_devices_disks_changed" multiselect "$device" || return 1
  grub_pf_debconf_set_key "grub-pc/install_devices_empty" boolean false || return 1
  return 0
}

grub_pf_snapshot_debconf() {
  GRUB_PF_SNAP_INSTALL_DEVICES="$(grub_pf_debconf_get_key "grub-pc/install_devices" 2>/dev/null || true)"
  GRUB_PF_SNAP_DISKS_CHANGED="$(grub_pf_debconf_get_key "grub-pc/install_devices_disks_changed" 2>/dev/null || true)"
  GRUB_PF_SNAP_EMPTY="$(grub_pf_debconf_get_key "grub-pc/install_devices_empty" 2>/dev/null || true)"
  GRUB_PF_SNAP_TAKEN=1
}

grub_pf_restore_debconf_snapshot() {
  local rc=0
  GRUB_INSTALL_DEVICE_ROLLBACK_ATTEMPTED="YES"
  if [[ "${GRUB_PF_FORCE_ROLLBACK_FAIL:-0}" == "1" ]]; then
    GRUB_INSTALL_DEVICE_ROLLBACK_RESULT="FAIL"
    return 1
  fi
  if [[ "$GRUB_PF_SNAP_TAKEN" -ne 1 ]]; then
    GRUB_INSTALL_DEVICE_ROLLBACK_RESULT="FAIL"
    return 1
  fi
  # Reset set-fail inject so rollback can proceed unless FORCE_ROLLBACK_FAIL.
  local saved_fail="${GRUB_PF_FORCE_SET_FAIL:-0}"
  local saved_at="${GRUB_PF_FORCE_SET_FAIL_AT:-}"
  GRUB_PF_FORCE_SET_FAIL=0
  unset GRUB_PF_FORCE_SET_FAIL_AT || true
  GRUB_PF_SET_COUNT=0

  grub_pf_debconf_set_key "grub-pc/install_devices" multiselect \
    "${GRUB_PF_SNAP_INSTALL_DEVICES}" || rc=1
  grub_pf_debconf_set_key "grub-pc/install_devices_disks_changed" multiselect \
    "${GRUB_PF_SNAP_DISKS_CHANGED}" || rc=1
  grub_pf_debconf_set_key "grub-pc/install_devices_empty" boolean \
    "${GRUB_PF_SNAP_EMPTY:-false}" || rc=1

  GRUB_PF_FORCE_SET_FAIL="$saved_fail"
  if [[ -n "$saved_at" ]]; then
    GRUB_PF_FORCE_SET_FAIL_AT="$saved_at"
  fi

  if [[ "$rc" -ne 0 ]]; then
    GRUB_INSTALL_DEVICE_ROLLBACK_RESULT="FAIL"
    return 1
  fi

  # Verify restoration of install_devices (authoritative).
  local got
  got="$(grub_pf_debconf_get_key "grub-pc/install_devices" 2>/dev/null || true)"
  if [[ "$got" != "${GRUB_PF_SNAP_INSTALL_DEVICES}" ]]; then
    GRUB_INSTALL_DEVICE_ROLLBACK_RESULT="FAIL"
    return 1
  fi
  GRUB_INSTALL_DEVICE_ROLLBACK_RESULT="PASS"
  return 0
}

# Transactional write of intended install device + companion keys.
# On any write/readback/validation failure: restore snapshot and fail closed.
grub_pf_rebind_transactional() {
  local device="$1" parent="$2"
  local verify_raw verify_status

  GRUB_INSTALL_DEVICE_REBIND_RESULT=""
  GRUB_INSTALL_DEVICE_ROLLBACK_ATTEMPTED=""
  GRUB_INSTALL_DEVICE_ROLLBACK_RESULT=""

  grub_pf_snapshot_debconf
  GRUB_PF_SET_COUNT=0

  if ! grub_pf_debconf_set_key "grub-pc/install_devices" multiselect "$device"; then
    GRUB_INSTALL_DEVICE_REBIND_RESULT="FAIL"
    # No successful mutation yet if first key failed; still attempt restore for safety.
    if [[ "${GRUB_PF_SET_COUNT:-0}" -gt 0 ]]; then
      grub_pf_restore_debconf_snapshot || true
    else
      # First-write failure: originals unchanged; record no rollback needed.
      GRUB_INSTALL_DEVICE_ROLLBACK_ATTEMPTED="NO"
      GRUB_INSTALL_DEVICE_ROLLBACK_RESULT="N/A"
    fi
    return 1
  fi
  if ! grub_pf_debconf_set_key "grub-pc/install_devices_disks_changed" multiselect "$device"; then
    GRUB_INSTALL_DEVICE_REBIND_RESULT="FAIL"
    grub_pf_restore_debconf_snapshot || true
    return 1
  fi
  if ! grub_pf_debconf_set_key "grub-pc/install_devices_empty" boolean false; then
    GRUB_INSTALL_DEVICE_REBIND_RESULT="FAIL"
    grub_pf_restore_debconf_snapshot || true
    return 1
  fi

  if [[ "${GRUB_PF_FORCE_READBACK_FAIL:-0}" == "1" ]]; then
    GRUB_INSTALL_DEVICE_REBIND_RESULT="FAIL"
    grub_pf_restore_debconf_snapshot || true
    return 1
  fi

  verify_raw="$(grub_pf_debconf_get_install_devices 2>/dev/null || true)"
  GRUB_INSTALL_DEVICE_AFTER="$verify_raw"
  grub_pf_classify_install_devices "$parent" "$verify_raw"
  verify_status="${GRUB_PF_LAST_CLASSIFY_STATUS}"
  GRUB_INSTALL_DEVICE_STATUS_AFTER="$verify_status"
  # Compatibility: CURRENT reflects post-mutation view after rebind attempt.
  GRUB_INSTALL_DEVICE_CURRENT="$verify_raw"
  GRUB_INSTALL_DEVICE_STATUS="$verify_status"

  if [[ "$verify_status" != "CURRENT" ]]; then
    GRUB_INSTALL_DEVICE_REBIND_RESULT="FAIL"
    grub_pf_restore_debconf_snapshot || true
    return 1
  fi

  GRUB_INSTALL_DEVICE_REBIND_RESULT="PASS"
  return 0
}

# Split debconf multiselect value into paths (comma and/or whitespace).
grub_pf_split_devices() {
  local raw="$1" tok
  raw="${raw//,/ }"
  for tok in $raw; do
    [[ -n "$tok" ]] || continue
    printf '%s\n' "$tok"
  done
}

# Resolve configured install device(s) to a WHOLE-DISK identity.
# CURRENT only when every configured target resolves exactly to parent disk.
# A partition (e.g. /dev/nvme0n1p1 or *-part1) is NEVER CURRENT.
# Sets GRUB_INSTALL_DEVICE_RESOLVED and GRUB_PF_LAST_CLASSIFY_STATUS.
grub_pf_classify_install_devices() {
  local parent="$1" raw="$2"
  local dev resolved any=0 all_current=1 saw_stale=0 saw_invalid=0
  local base resolved_parent=""
  GRUB_INSTALL_DEVICE_RESOLVED=""
  GRUB_PF_LAST_CLASSIFY_STATUS=""

  if [[ -z "$raw" ]]; then
    GRUB_PF_LAST_CLASSIFY_STATUS="INVALID"
    return 0
  fi

  while IFS= read -r dev; do
    [[ -n "$dev" ]] || continue
    any=1
    base="$(basename "$dev")"
    # Partition by-id links are never valid grub-pc install disks.
    if [[ "$base" =~ -part[0-9]+$ ]]; then
      saw_invalid=1
      all_current=0
      resolved="$(grub_pf_resolve_path "$dev" 2>/dev/null || true)"
      [[ -n "$GRUB_INSTALL_DEVICE_RESOLVED" ]] || GRUB_INSTALL_DEVICE_RESOLVED="${resolved:-$dev}"
      continue
    fi

    resolved="$(grub_pf_resolve_path "$dev" 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
      saw_stale=1
      all_current=0
      continue
    fi

    if [[ -z "$GRUB_INSTALL_DEVICE_RESOLVED" ]]; then
      GRUB_INSTALL_DEVICE_RESOLVED="$resolved"
    fi

    # Reject partition device nodes even if parent matches.
    if grub_pf_is_partition_name "$(grub_pf_dev_basename "$resolved")"; then
      saw_invalid=1
      all_current=0
      continue
    fi

    # Whole-disk CURRENT requires exact identity match to parent.
    if [[ "$resolved" == "$parent" ]]; then
      GRUB_INSTALL_DEVICE_RESOLVED="$parent"
      continue
    fi

    # Resolves to some other whole disk → STALE.
    resolved_parent="$(grub_pf_parent_disk_of "$resolved" 2>/dev/null || true)"
    if [[ -n "$resolved_parent" && "$resolved_parent" != "$parent" ]]; then
      saw_stale=1
      all_current=0
      continue
    fi
    if [[ "$resolved" != "$parent" ]]; then
      # Different path that is not the parent whole disk.
      saw_stale=1
      all_current=0
      continue
    fi
  done < <(grub_pf_split_devices "$raw")

  if [[ "$any" -eq 0 ]]; then
    GRUB_PF_LAST_CLASSIFY_STATUS="INVALID"
    return 0
  fi
  if [[ "$all_current" -eq 1 ]]; then
    [[ -n "$GRUB_INSTALL_DEVICE_RESOLVED" ]] || GRUB_INSTALL_DEVICE_RESOLVED="$parent"
    GRUB_PF_LAST_CLASSIFY_STATUS="CURRENT"
    return 0
  fi
  if [[ "$saw_invalid" -eq 1 && "$saw_stale" -eq 0 ]]; then
    GRUB_PF_LAST_CLASSIFY_STATUS="INVALID"
    return 0
  fi
  if [[ "$saw_stale" -eq 1 ]]; then
    GRUB_PF_LAST_CLASSIFY_STATUS="STALE"
    return 0
  fi
  if [[ "$saw_invalid" -eq 1 ]]; then
    GRUB_PF_LAST_CLASSIFY_STATUS="INVALID"
    return 0
  fi
  GRUB_PF_LAST_CLASSIFY_STATUS="UNRESOLVED"
}

# --- main entrypoints ------------------------------------------------------

grub_pf_reset_evidence() {
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
  GRUB_PF_SNAP_INSTALL_DEVICES=""
  GRUB_PF_SNAP_DISKS_CHANGED=""
  GRUB_PF_SNAP_EMPTY=""
  GRUB_PF_SNAP_TAKEN=0
  GRUB_PF_SET_COUNT=0
}

# Shared detect/classify. Sets BEFORE evidence. Returns 0 if inspectable,
# 1 on hard fail (unresolved parent, etc.). Does not mutate debconf.
grub_pf_inspect_core() {
  local status expected

  # Fixture harnesses use TEST_ROOT; do not probe the real host disk/debconf
  # unless the test explicitly injects GRUB_PF_OVERRIDE_* knobs.
  if [[ -n "${TEST_ROOT:-}" && -z "${GRUB_PF_OVERRIDE_BOOT_MODE:-}" \
      && -z "${GRUB_PF_OVERRIDE_ROOT_SOURCE:-}" \
      && -z "${GRUB_PF_FORCE_LIVE:-}" ]]; then
    GRUB_INSTALL_DEVICE_STATUS="CURRENT"
    GRUB_INSTALL_DEVICE_STATUS_BEFORE="CURRENT"
    GRUB_INSTALL_DEVICE_ACTION="NONE"
    GRUB_INSTALL_DEVICE_PREFLIGHT="PASS"
    grub_pf_log INFO "GRUB_INSTALL_DEVICE_PREFLIGHT=PASS reason=test_root_skip"
    return 0
  fi

  BOOT_MODE="$(grub_pf_detect_boot_mode)"
  if [[ "$BOOT_MODE" == "EFI" ]]; then
    GRUB_INSTALL_DEVICE_STATUS="CURRENT"
    GRUB_INSTALL_DEVICE_STATUS_BEFORE="CURRENT"
    GRUB_INSTALL_DEVICE_ACTION="NONE"
    GRUB_INSTALL_DEVICE_PREFLIGHT="PASS"
    grub_pf_log INFO "GRUB_INSTALL_DEVICE_PREFLIGHT=PASS reason=efi_boot_mode_skip"
    grub_pf_emit_evidence
    return 0
  fi

  if ! grub_pf_grub_pc_relevant; then
    GRUB_INSTALL_DEVICE_STATUS="CURRENT"
    GRUB_INSTALL_DEVICE_STATUS_BEFORE="CURRENT"
    GRUB_INSTALL_DEVICE_ACTION="NONE"
    GRUB_INSTALL_DEVICE_PREFLIGHT="PASS"
    grub_pf_log INFO "GRUB_INSTALL_DEVICE_PREFLIGHT=PASS reason=grub_pc_not_relevant"
    grub_pf_emit_evidence
    return 0
  fi

  ROOT_SOURCE="$(grub_pf_read_root_source)"
  if [[ -z "$ROOT_SOURCE" ]]; then
    GRUB_INSTALL_DEVICE_STATUS="UNRESOLVED"
    GRUB_INSTALL_DEVICE_STATUS_BEFORE="UNRESOLVED"
    grub_pf_fail_closed root_source_unresolved
    return 1
  fi

  if ! ROOT_PARENT_DISK="$(grub_pf_parent_disk_of "$ROOT_SOURCE")"; then
    GRUB_INSTALL_DEVICE_STATUS="UNRESOLVED"
    GRUB_INSTALL_DEVICE_STATUS_BEFORE="UNRESOLVED"
    ROOT_PARENT_DISK=""
    grub_pf_fail_closed root_parent_disk_unresolved
    return 1
  fi
  if [[ -z "$ROOT_PARENT_DISK" ]]; then
    GRUB_INSTALL_DEVICE_STATUS="UNRESOLVED"
    GRUB_INSTALL_DEVICE_STATUS_BEFORE="UNRESOLVED"
    grub_pf_fail_closed root_parent_disk_empty
    return 1
  fi

  expected="$(grub_pf_select_expected_device "$ROOT_PARENT_DISK")"
  GRUB_INSTALL_DEVICE_EXPECTED="$expected"
  AWS_EBS_CURRENT_VOLUME_ID="$(grub_pf_extract_ebs_vol_id "$expected")"

  GRUB_INSTALL_DEVICE_BEFORE="$(grub_pf_debconf_get_install_devices 2>/dev/null || true)"
  GRUB_INSTALL_DEVICE_CURRENT="$GRUB_INSTALL_DEVICE_BEFORE"
  grub_pf_classify_install_devices "$ROOT_PARENT_DISK" "$GRUB_INSTALL_DEVICE_BEFORE"
  status="${GRUB_PF_LAST_CLASSIFY_STATUS}"
  GRUB_INSTALL_DEVICE_STATUS_BEFORE="$status"
  GRUB_INSTALL_DEVICE_STATUS="$status"
  return 0
}

# Read-only inspect: classify and emit WOULD_REBIND / NONE. Never mutates.
inspect_grub_install_device() {
  local status
  grub_pf_reset_evidence
  if ! grub_pf_inspect_core; then
    return 1
  fi
  # Early skip paths already set PASS.
  if [[ "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "PASS" ]]; then
    return 0
  fi

  status="$GRUB_INSTALL_DEVICE_STATUS_BEFORE"
  case "$status" in
    CURRENT)
      GRUB_INSTALL_DEVICE_ACTION="NONE"
      GRUB_INSTALL_DEVICE_AFTER="$GRUB_INSTALL_DEVICE_BEFORE"
      GRUB_INSTALL_DEVICE_STATUS_AFTER="CURRENT"
      GRUB_INSTALL_DEVICE_PREFLIGHT="PASS"
      grub_pf_emit_evidence
      return 0
      ;;
    STALE|INVALID)
      GRUB_INSTALL_DEVICE_ACTION="WOULD_REBIND"
      if [[ -z "$GRUB_INSTALL_DEVICE_EXPECTED" ]]; then
        grub_pf_fail_closed expected_device_empty
        return 1
      fi
      GRUB_INSTALL_DEVICE_PREFLIGHT="PASS"
      grub_pf_emit_evidence
      return 0
      ;;
    *)
      GRUB_INSTALL_DEVICE_ACTION="NONE"
      grub_pf_fail_closed "status_${status:-unresolved}"
      return 1
      ;;
  esac
}

# Authoritative reconcile: mutate only after caller crossed destructive confirm.
reconcile_grub_install_device() {
  local status
  grub_pf_reset_evidence
  if ! grub_pf_inspect_core; then
    return 1
  fi
  if [[ "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "PASS" ]]; then
    return 0
  fi

  status="$GRUB_INSTALL_DEVICE_STATUS_BEFORE"
  case "$status" in
    CURRENT)
      GRUB_INSTALL_DEVICE_ACTION="NONE"
      GRUB_INSTALL_DEVICE_AFTER="$GRUB_INSTALL_DEVICE_BEFORE"
      GRUB_INSTALL_DEVICE_STATUS_AFTER="CURRENT"
      GRUB_INSTALL_DEVICE_PREFLIGHT="PASS"
      grub_pf_emit_evidence
      return 0
      ;;
    STALE|INVALID)
      GRUB_INSTALL_DEVICE_ACTION="REBOUND"
      if [[ -z "$GRUB_INSTALL_DEVICE_EXPECTED" ]]; then
        GRUB_INSTALL_DEVICE_REBIND_RESULT="FAIL"
        grub_pf_fail_closed expected_device_empty
        return 1
      fi
      if ! grub_pf_rebind_transactional "$GRUB_INSTALL_DEVICE_EXPECTED" "$ROOT_PARENT_DISK"; then
        # Preserve BEFORE evidence; AFTER may reflect failed/partial then rollback.
        if [[ -z "$GRUB_INSTALL_DEVICE_AFTER" ]]; then
          GRUB_INSTALL_DEVICE_AFTER="$(grub_pf_debconf_get_install_devices 2>/dev/null || true)"
          grub_pf_classify_install_devices "$ROOT_PARENT_DISK" "$GRUB_INSTALL_DEVICE_AFTER"
          GRUB_INSTALL_DEVICE_STATUS_AFTER="${GRUB_PF_LAST_CLASSIFY_STATUS}"
        fi
        GRUB_INSTALL_DEVICE_STATUS="$GRUB_INSTALL_DEVICE_STATUS_BEFORE"
        GRUB_INSTALL_DEVICE_CURRENT="$GRUB_INSTALL_DEVICE_BEFORE"
        if [[ "${GRUB_INSTALL_DEVICE_ROLLBACK_RESULT}" == "FAIL" ]]; then
          grub_pf_fail_closed rebind_rollback_failed
          return 1
        fi
        grub_pf_fail_closed rebind_failed
        return 1
      fi
      # Successful rebind: BEFORE retained; AFTER/CURRENT are post-state.
      GRUB_INSTALL_DEVICE_STATUS="CURRENT"
      GRUB_INSTALL_DEVICE_PREFLIGHT="PASS"
      grub_pf_emit_evidence
      return 0
      ;;
    *)
      GRUB_INSTALL_DEVICE_ACTION="NONE"
      grub_pf_fail_closed "status_${status:-unresolved}"
      return 1
      ;;
  esac
}

# Back-compat entry: mode inspect|reconcile (default inspect = non-mutating).
# Env GRUB_PF_MODE overrides when no arg given.
validate_grub_install_device_preflight() {
  local mode="${1:-}"
  if [[ -z "$mode" ]]; then
    mode="${GRUB_PF_MODE:-inspect}"
  fi
  case "$mode" in
    inspect|read-only|readonly|preflight)
      inspect_grub_install_device
      ;;
    reconcile|mutate|apply)
      reconcile_grub_install_device
      ;;
    *)
      grub_pf_log ERROR "unknown GRUB preflight mode: ${mode}"
      return 1
      ;;
  esac
}

# Alias used by hop client preflight (read-only).
run_grub_install_device_preflight() {
  validate_grub_install_device_preflight inspect "$@"
}

# Alias used by hop runners (authoritative mutation).
run_grub_install_device_reconcile() {
  validate_grub_install_device_preflight reconcile "$@"
}
