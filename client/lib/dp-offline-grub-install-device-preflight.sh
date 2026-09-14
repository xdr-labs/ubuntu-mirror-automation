# shellcheck shell=bash
# Shared BIOS/grub-pc install_devices preflight for offline OS-hop clients.
#
# Injected at build time via @@GRUB_INSTALL_DEVICE_PREFLIGHT_HELPER@@.
# Directly sourceable by fixture tests.
#
# Correctness is based on resolved block-device identity (root → parent disk),
# not hardcoded NVMe paths or AWS volume IDs. EBS volume IDs are diagnostic only.
#
# Contract:
#   BIOS + grub-pc relevant → prove grub-pc/install_devices maps to current
#   root parent disk (reconcile when stale/invalid). Fail closed otherwise.
#   EFI / non-grub-pc → SKIP (PASS).
#
# Evidence globals (exported for callers/tests):
#   BOOT_MODE ROOT_SOURCE ROOT_PARENT_DISK
#   GRUB_INSTALL_DEVICE_CURRENT GRUB_INSTALL_DEVICE_RESOLVED
#   GRUB_INSTALL_DEVICE_EXPECTED GRUB_INSTALL_DEVICE_STATUS
#   GRUB_INSTALL_DEVICE_ACTION GRUB_INSTALL_DEVICE_REBIND_RESULT
#   GRUB_INSTALL_DEVICE_PREFLIGHT AWS_EBS_CURRENT_VOLUME_ID
#   PACKAGE_TRANSITION_STARTED (forced NO on hard fail path logging)

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
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_CURRENT=${GRUB_INSTALL_DEVICE_CURRENT}"
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_RESOLVED=${GRUB_INSTALL_DEVICE_RESOLVED}"
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_EXPECTED=${GRUB_INSTALL_DEVICE_EXPECTED}"
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_STATUS=${GRUB_INSTALL_DEVICE_STATUS}"
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_ACTION=${GRUB_INSTALL_DEVICE_ACTION}"
  if [[ -n "${GRUB_INSTALL_DEVICE_REBIND_RESULT}" ]]; then
    grub_pf_log INFO "GRUB_INSTALL_DEVICE_REBIND_RESULT=${GRUB_INSTALL_DEVICE_REBIND_RESULT}"
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

# Derive parent disk for a block device node (partition or whole disk).
# No NVMe hardcoding: works for nvme*n*p*, sd*, vd*, xvd*, hd*.
grub_pf_parent_disk_of() {
  local src="$1" base pk parent sysdev
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

  # Whole-disk root or unresolved partition naming — treat device as parent
  # only when the block node itself exists.
  if [[ -b "$src" || -e "/sys/class/block/${base}" ]]; then
    printf '/dev/%s' "$base"
    return 0
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

grub_pf_debconf_get_install_devices() {
  local out
  if [[ -n "${GRUB_PF_OVERRIDE_INSTALL_DEVICES:-}" ]]; then
    printf '%s' "$GRUB_PF_OVERRIDE_INSTALL_DEVICES"
    return 0
  fi
  if ! command -v debconf-communicate >/dev/null 2>&1; then
    return 1
  fi
  out="$(echo 'get grub-pc/install_devices' | debconf-communicate 2>/dev/null || true)"
  # Format: "0 value" or "10 ..."
  if [[ "$out" =~ ^0[[:space:]]+(.*)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  # Fallback: debconf-show
  if command -v debconf-show >/dev/null 2>&1; then
    out="$(debconf-show grub-pc 2>/dev/null | awk -F': ' '/install_devices:/{print $2; exit}' || true)"
    printf '%s' "$out"
    return 0
  fi
  return 1
}

grub_pf_debconf_set_install_devices() {
  local device="$1"
  if [[ -n "${GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK:-}" ]]; then
    # Test hook: append "SET <device>" to the hook file path.
    printf 'SET %s\n' "$device" >>"$GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK"
    GRUB_PF_OVERRIDE_INSTALL_DEVICES="$device"
    return 0
  fi
  if [[ "${GRUB_PF_DRY_RUN:-0}" == "1" ]]; then
    GRUB_PF_OVERRIDE_INSTALL_DEVICES="$device"
    return 0
  fi
  if ! command -v debconf-set-selections >/dev/null 2>&1; then
    return 1
  fi
  printf 'grub-pc grub-pc/install_devices multiselect %s\n' "$device" | debconf-set-selections || return 1
  printf 'grub-pc grub-pc/install_devices_disks_changed multiselect %s\n' "$device" | debconf-set-selections || return 1
  printf 'grub-pc grub-pc/install_devices_empty boolean false\n' | debconf-set-selections || return 1
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

# Resolve configured install device(s) to a parent disk identity.
# Sets GRUB_INSTALL_DEVICE_RESOLVED and GRUB_PF_LAST_CLASSIFY_STATUS.
grub_pf_classify_install_devices() {
  local parent="$1" raw="$2"
  local dev resolved any=0 all_current=1 saw_stale=0 saw_invalid=0
  GRUB_INSTALL_DEVICE_RESOLVED=""
  GRUB_PF_LAST_CLASSIFY_STATUS=""

  if [[ -z "$raw" ]]; then
    GRUB_PF_LAST_CLASSIFY_STATUS="INVALID"
    return 0
  fi

  while IFS= read -r dev; do
    [[ -n "$dev" ]] || continue
    any=1
    resolved="$(grub_pf_resolve_path "$dev" 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
      saw_stale=1
      all_current=0
      continue
    fi
    # Prefer recording the parent-disk identity for evidence.
    if [[ -z "$GRUB_INSTALL_DEVICE_RESOLVED" ]]; then
      if [[ "$resolved" == "$parent" ]]; then
        GRUB_INSTALL_DEVICE_RESOLVED="$parent"
      else
        GRUB_INSTALL_DEVICE_RESOLVED="$resolved"
      fi
    fi
    # resolved may be the parent disk or a partition on it
    local resolved_parent=""
    resolved_parent="$(grub_pf_parent_disk_of "$resolved" 2>/dev/null || true)"
    if [[ -z "$resolved_parent" ]]; then
      # Whole disk path equal to parent
      if [[ "$resolved" == "$parent" ]]; then
        GRUB_INSTALL_DEVICE_RESOLVED="$parent"
        continue
      fi
      saw_invalid=1
      all_current=0
      continue
    fi
    if [[ "$resolved" != "$parent" && "$resolved_parent" != "$parent" ]]; then
      # Points at a different disk
      saw_stale=1
      all_current=0
      continue
    fi
    GRUB_INSTALL_DEVICE_RESOLVED="$parent"
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

# Reconcile + verify. Return 0 on PASS, 1 on FAIL (fail-closed).
validate_grub_install_device_preflight() {
  local status expected set_rc verify_raw verify_status

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

  # Fixture harnesses use TEST_ROOT; do not probe the real host disk/debconf
  # unless the test explicitly injects GRUB_PF_OVERRIDE_* knobs.
  if [[ -n "${TEST_ROOT:-}" && -z "${GRUB_PF_OVERRIDE_BOOT_MODE:-}" \
      && -z "${GRUB_PF_OVERRIDE_ROOT_SOURCE:-}" \
      && -z "${GRUB_PF_FORCE_LIVE:-}" ]]; then
    GRUB_INSTALL_DEVICE_STATUS="CURRENT"
    GRUB_INSTALL_DEVICE_ACTION="NONE"
    GRUB_INSTALL_DEVICE_PREFLIGHT="PASS"
    grub_pf_log INFO "GRUB_INSTALL_DEVICE_PREFLIGHT=PASS reason=test_root_skip"
    return 0
  fi

  BOOT_MODE="$(grub_pf_detect_boot_mode)"
  if [[ "$BOOT_MODE" == "EFI" ]]; then
    GRUB_INSTALL_DEVICE_STATUS="CURRENT"
    GRUB_INSTALL_DEVICE_ACTION="NONE"
    GRUB_INSTALL_DEVICE_PREFLIGHT="PASS"
    grub_pf_log INFO "GRUB_INSTALL_DEVICE_PREFLIGHT=PASS reason=efi_boot_mode_skip"
    grub_pf_emit_evidence
    return 0
  fi

  if ! grub_pf_grub_pc_relevant; then
    GRUB_INSTALL_DEVICE_STATUS="CURRENT"
    GRUB_INSTALL_DEVICE_ACTION="NONE"
    GRUB_INSTALL_DEVICE_PREFLIGHT="PASS"
    grub_pf_log INFO "GRUB_INSTALL_DEVICE_PREFLIGHT=PASS reason=grub_pc_not_relevant"
    grub_pf_emit_evidence
    return 0
  fi

  ROOT_SOURCE="$(grub_pf_read_root_source)"
  if [[ -z "$ROOT_SOURCE" ]]; then
    GRUB_INSTALL_DEVICE_STATUS="UNRESOLVED"
    grub_pf_fail_closed root_source_unresolved
    return 1
  fi

  if ! ROOT_PARENT_DISK="$(grub_pf_parent_disk_of "$ROOT_SOURCE")"; then
    GRUB_INSTALL_DEVICE_STATUS="UNRESOLVED"
    ROOT_PARENT_DISK=""
    grub_pf_fail_closed root_parent_disk_unresolved
    return 1
  fi
  if [[ -z "$ROOT_PARENT_DISK" ]]; then
    GRUB_INSTALL_DEVICE_STATUS="UNRESOLVED"
    grub_pf_fail_closed root_parent_disk_empty
    return 1
  fi

  expected="$(grub_pf_select_expected_device "$ROOT_PARENT_DISK")"
  GRUB_INSTALL_DEVICE_EXPECTED="$expected"
  AWS_EBS_CURRENT_VOLUME_ID="$(grub_pf_extract_ebs_vol_id "$expected")"

  GRUB_INSTALL_DEVICE_CURRENT="$(grub_pf_debconf_get_install_devices 2>/dev/null || true)"
  grub_pf_classify_install_devices "$ROOT_PARENT_DISK" "$GRUB_INSTALL_DEVICE_CURRENT"
  status="${GRUB_PF_LAST_CLASSIFY_STATUS}"
  GRUB_INSTALL_DEVICE_STATUS="$status"

  case "$status" in
    CURRENT)
      GRUB_INSTALL_DEVICE_ACTION="NONE"
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
      set_rc=0
      grub_pf_debconf_set_install_devices "$GRUB_INSTALL_DEVICE_EXPECTED" || set_rc=$?
      if [[ "$set_rc" -ne 0 ]]; then
        GRUB_INSTALL_DEVICE_REBIND_RESULT="FAIL"
        grub_pf_fail_closed debconf_set_failed
        return 1
      fi
      # Verify read-back resolves to the same parent disk.
      verify_raw="$(grub_pf_debconf_get_install_devices 2>/dev/null || true)"
      GRUB_INSTALL_DEVICE_CURRENT="$verify_raw"
      grub_pf_classify_install_devices "$ROOT_PARENT_DISK" "$verify_raw"
      verify_status="${GRUB_PF_LAST_CLASSIFY_STATUS}"
      GRUB_INSTALL_DEVICE_STATUS="$verify_status"
      if [[ "$verify_status" != "CURRENT" ]]; then
        GRUB_INSTALL_DEVICE_REBIND_RESULT="FAIL"
        grub_pf_fail_closed rebind_verify_failed
        return 1
      fi
      GRUB_INSTALL_DEVICE_REBIND_RESULT="PASS"
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

# Alias used by hop runners / preflight.
run_grub_install_device_preflight() {
  validate_grub_install_device_preflight "$@"
}
