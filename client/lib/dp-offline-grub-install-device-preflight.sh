# shellcheck shell=bash
# Shared BIOS/grub-pc install_devices normalization for offline OS-hop clients.
#
# Injected at build time through the GRUB install-device preflight helper token.
# Directly sourceable by fixture tests.
#
# Decision model: CURRENT_STATE_ONLY
#   The running system's current whole root disk is authoritative.
#   Old grub-pc/install_devices values are observational (debug) only and MUST
#   NOT control whether normalization runs or which target is selected.
#   AWS EBS by-id paths are never chosen as the grub-pc install target.
#
# Contract:
#   BIOS + grub-pc relevant → derive current whole root disk, prove it, and
#   (normalize) set grub-pc debconf to that whole disk then verify.
#   EFI / non-grub-pc → SKIP (PASS). Ambiguous root topology → FAIL closed.
#
# Caller-facing entrypoints:
#   run_grub_install_device_preflight  — read-only derivation proof (pre-confirm)
#   run_grub_install_device_normalize  — set + verify before do-release-upgrade

BOOT_MODE=""
ROOT_SOURCE=""
ROOT_PARENT_DISK=""
GRUB_INSTALL_TARGET=""
GRUB_INSTALL_TARGET_DERIVATION=""
GRUB_INSTALL_DEVICE_BEFORE=""
GRUB_INSTALL_DEVICE_AFTER=""
GRUB_INSTALL_DEVICE_PREFLIGHT=""
OLD_STATE_USED_FOR_CONTROL_FLOW="NO"

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
  local root
  if declare -F hostpath >/dev/null 2>&1; then
    hostpath "$p"
  elif declare -F _hp >/dev/null 2>&1; then
    _hp "$p"
  else
    root="$(grub_pf_fixture_root)"
    if [[ -n "$root" ]]; then
      printf '%s%s' "${root%/}" "$p"
    else
      printf '%s' "$p"
    fi
  fi
}

# Hermetic fixture root for skip/hostpath. Detached runners historically set
# STELLAR_OFFLINE_TEST_ROOT / _TEST_PREFIX without also exporting TEST_ROOT.
grub_pf_fixture_root() {
  if declare -F dp_offline_hermetic_fixtures_enabled >/dev/null 2>&1 \
    && dp_offline_hermetic_fixtures_enabled; then
    printf '%s' "${TEST_ROOT:-${STELLAR_OFFLINE_TEST_ROOT:-${DP_OFFLINE_TEST_ROOT:-}}}"
  else
    printf '%s' "${TEST_ROOT:-}"
  fi
}

grub_pf_emit_evidence() {
  grub_pf_log INFO "BOOT_MODE=${BOOT_MODE}"
  grub_pf_log INFO "ROOT_SOURCE=${ROOT_SOURCE}"
  grub_pf_log INFO "ROOT_PARENT_DISK=${ROOT_PARENT_DISK}"
  grub_pf_log INFO "GRUB_INSTALL_TARGET=${GRUB_INSTALL_TARGET}"
  grub_pf_log INFO "GRUB_INSTALL_TARGET_DERIVATION=${GRUB_INSTALL_TARGET_DERIVATION}"
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_BEFORE=${GRUB_INSTALL_DEVICE_BEFORE}"
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_AFTER=${GRUB_INSTALL_DEVICE_AFTER}"
  grub_pf_log INFO "OLD_STATE_USED_FOR_CONTROL_FLOW=${OLD_STATE_USED_FOR_CONTROL_FLOW}"
  grub_pf_log INFO "GRUB_INSTALL_DEVICE_PREFLIGHT=${GRUB_INSTALL_DEVICE_PREFLIGHT}"
}

grub_pf_fail_closed() {
  local reason="$1"
  GRUB_INSTALL_DEVICE_PREFLIGHT="FAIL"
  if [[ -z "${GRUB_INSTALL_TARGET_DERIVATION}" ]]; then
    GRUB_INSTALL_TARGET_DERIVATION="FAIL"
  fi
  OLD_STATE_USED_FOR_CONTROL_FLOW="NO"
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
# Mapper/LVM/RAID/dm roots are intentionally unresolved (fail closed).
grub_pf_parent_disk_of() {
  local src="$1" base pk parent sysdev resolved=""
  if [[ -n "${GRUB_PF_OVERRIDE_PARENT_DISK:-}" ]]; then
    printf '%s' "$GRUB_PF_OVERRIDE_PARENT_DISK"
    return 0
  fi
  [[ -n "$src" ]] || return 1

  if resolved="$(grub_pf_resolve_path "$src" 2>/dev/null)"; then
    src="$resolved"
  fi

  base="$(grub_pf_dev_basename "$src")"
  [[ -n "$base" ]] || return 1

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

  if parent="$(grub_pf_parent_disk_from_name "$base" 2>/dev/null)"; then
    printf '%s' "$parent"
    return 0
  fi

  if ! grub_pf_is_partition_name "$base"; then
    if [[ -b "$src" || -e "/sys/class/block/${base}" || -n "${GRUB_PF_RESOLVE_MAP:-}" ]]; then
      printf '/dev/%s' "$base"
      return 0
    fi
  fi
  return 1
}

# --- debconf ---------------------------------------------------------------

grub_pf_grub_pc_relevant() {
  if [[ -n "${GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT:-}" ]]; then
    [[ "${GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT}" == "1" || "${GRUB_PF_OVERRIDE_GRUB_PC_RELEVANT}" == "yes" ]]
    return $?
  fi
  local status
  status="$(dpkg-query -W -f='${Status}' grub-pc 2>/dev/null || true)"
  [[ "$status" == *"installed"* || "$status" == *"unpacked"* || "$status" == *"half-configured"* || "$status" == *"config-files"* ]]
}

# Get a single grub-pc debconf key via debconf-communicate (Xenial-safe).
grub_pf_debconf_get_key() {
  local key="$1" out
  if [[ -n "${GRUB_PF_OVERRIDE_DEBCONF_STORE:-}" ]]; then
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
  if [[ "$out" =~ ^0[[:space:]]+(.*)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$out" =~ ^0[[:space:]]*$ ]]; then
    printf ''
    return 0
  fi
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

# Set the complete desired grub-pc install target state in one logical write.
# Prefer a single debconf-set-selections input on live systems (Xenial-safe).
grub_pf_debconf_set_install_target() {
  local device="$1"
  GRUB_PF_SET_COUNT=0

  if [[ "${GRUB_PF_FORCE_SET_FAIL:-0}" == "1" ]]; then
    return 1
  fi

  # Fixture / dry-run paths keep per-key writes so fail-at-N injection works.
  if [[ -n "${GRUB_PF_OVERRIDE_DEBCONF_STORE:-}" \
      || -n "${GRUB_PF_OVERRIDE_DEBCONF_SET_HOOK:-}" \
      || "${GRUB_PF_DRY_RUN:-0}" == "1" \
      || -n "${GRUB_PF_FORCE_SET_FAIL_AT:-}" ]]; then
    grub_pf_debconf_set_key "grub-pc/install_devices" multiselect "$device" || return 1
    grub_pf_debconf_set_key "grub-pc/install_devices_disks_changed" multiselect "$device" || return 1
    grub_pf_debconf_set_key "grub-pc/install_devices_empty" boolean false || return 1
    return 0
  fi

  if ! command -v debconf-set-selections >/dev/null 2>&1; then
    return 1
  fi
  printf '%s\n' \
    "grub-pc grub-pc/install_devices multiselect ${device}" \
    "grub-pc grub-pc/install_devices_disks_changed multiselect ${device}" \
    "grub-pc grub-pc/install_devices_empty boolean false" \
    | debconf-set-selections || return 1
  GRUB_PF_SET_COUNT=3
  return 0
}

# True when configured install_devices resolves exactly to the current whole disk.
grub_pf_verify_install_target() {
  local parent="$1" raw="$2" expected="$3"
  local first="" tok resolved

  [[ -n "$raw" ]] || return 1
  # Reject multi-select lists; we always normalize to exactly one whole disk.
  raw="${raw//,/ }"
  for tok in $raw; do
    [[ -n "$tok" ]] || continue
    if [[ -n "$first" ]]; then
      return 1
    fi
    first="$tok"
  done
  [[ -n "$first" ]] || return 1

  if [[ "$first" == "$expected" || "$first" == "$parent" ]]; then
    return 0
  fi
  resolved="$(grub_pf_resolve_path "$first" 2>/dev/null || true)"
  [[ -n "$resolved" ]] || return 1
  if grub_pf_is_partition_name "$(grub_pf_dev_basename "$resolved")"; then
    return 1
  fi
  [[ "$resolved" == "$parent" || "$resolved" == "$expected" ]]
}

grub_pf_reset_evidence() {
  BOOT_MODE=""
  ROOT_SOURCE=""
  ROOT_PARENT_DISK=""
  GRUB_INSTALL_TARGET=""
  GRUB_INSTALL_TARGET_DERIVATION=""
  GRUB_INSTALL_DEVICE_BEFORE=""
  GRUB_INSTALL_DEVICE_AFTER=""
  GRUB_INSTALL_DEVICE_PREFLIGHT=""
  OLD_STATE_USED_FOR_CONTROL_FLOW="NO"
  GRUB_PF_SET_COUNT=0
}

# Derive current whole-root-disk GRUB target. Never consults old grub-pc state
# for control flow. Sets evidence globals. Returns 0 when ready to continue
# (including EFI/non-grub-pc skip), 1 on hard fail.
grub_pf_detect_current_target() {
  # Fixture harnesses use TEST_ROOT / STELLAR_OFFLINE_TEST_ROOT; do not probe the
  # real host disk/debconf unless the test explicitly injects GRUB_PF_OVERRIDE_*
  # knobs or GRUB_PF_FORCE_LIVE.
  local fixture_root
  fixture_root="$(grub_pf_fixture_root)"
  if [[ -n "$fixture_root" && -z "${GRUB_PF_OVERRIDE_BOOT_MODE:-}" \
      && -z "${GRUB_PF_OVERRIDE_ROOT_SOURCE:-}" \
      && -z "${GRUB_PF_FORCE_LIVE:-}" ]]; then
    GRUB_INSTALL_TARGET_DERIVATION="PASS"
    GRUB_INSTALL_DEVICE_PREFLIGHT="PASS"
    OLD_STATE_USED_FOR_CONTROL_FLOW="NO"
    grub_pf_log INFO "GRUB_INSTALL_DEVICE_PREFLIGHT=PASS reason=test_root_skip"
    return 0
  fi

  BOOT_MODE="$(grub_pf_detect_boot_mode)"
  if [[ "$BOOT_MODE" == "EFI" ]]; then
    GRUB_INSTALL_TARGET_DERIVATION="SKIP"
    GRUB_INSTALL_DEVICE_PREFLIGHT="PASS"
    OLD_STATE_USED_FOR_CONTROL_FLOW="NO"
    grub_pf_log INFO "GRUB_INSTALL_DEVICE_PREFLIGHT=PASS reason=efi_boot_mode_skip"
    grub_pf_emit_evidence
    return 0
  fi

  if ! grub_pf_grub_pc_relevant; then
    GRUB_INSTALL_TARGET_DERIVATION="SKIP"
    GRUB_INSTALL_DEVICE_PREFLIGHT="PASS"
    OLD_STATE_USED_FOR_CONTROL_FLOW="NO"
    grub_pf_log INFO "GRUB_INSTALL_DEVICE_PREFLIGHT=PASS reason=grub_pc_not_relevant"
    grub_pf_emit_evidence
    return 0
  fi

  grub_pf_log INFO "DETECT_CURRENT_ROOT"
  ROOT_SOURCE="$(grub_pf_read_root_source)"
  if [[ -z "$ROOT_SOURCE" ]]; then
    GRUB_INSTALL_TARGET_DERIVATION="FAIL"
    grub_pf_fail_closed root_source_unresolved
    return 1
  fi

  grub_pf_log INFO "DERIVE_CURRENT_WHOLE_DISK"
  if ! ROOT_PARENT_DISK="$(grub_pf_parent_disk_of "$ROOT_SOURCE")"; then
    ROOT_PARENT_DISK=""
    GRUB_INSTALL_TARGET_DERIVATION="FAIL"
    grub_pf_fail_closed root_parent_disk_unresolved
    return 1
  fi
  if [[ -z "$ROOT_PARENT_DISK" ]]; then
    GRUB_INSTALL_TARGET_DERIVATION="FAIL"
    grub_pf_fail_closed root_parent_disk_empty
    return 1
  fi

  # Authoritative target is the current whole root disk — never EBS by-id.
  GRUB_INSTALL_TARGET="$ROOT_PARENT_DISK"
  GRUB_INSTALL_TARGET_DERIVATION="PASS"

  # Observational only: record whatever was previously stored.
  GRUB_INSTALL_DEVICE_BEFORE="$(grub_pf_debconf_get_install_devices 2>/dev/null || true)"
  OLD_STATE_USED_FOR_CONTROL_FLOW="NO"
  return 0
}

# Read-only pre-confirm check: prove a valid current GRUB target can be derived.
# Does not mutate debconf. Does not classify old grub-pc state for decisions.
run_grub_install_device_preflight() {
  grub_pf_reset_evidence
  if ! grub_pf_detect_current_target; then
    return 1
  fi
  if [[ "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "PASS" ]]; then
    return 0
  fi
  GRUB_INSTALL_DEVICE_PREFLIGHT="PASS"
  grub_pf_emit_evidence
  return 0
}

# Post-confirm runner normalization: set grub-pc to the current whole root disk
# and verify readback. Old stored values never control the target.
run_grub_install_device_normalize() {
  local verify_raw

  grub_pf_reset_evidence
  if ! grub_pf_detect_current_target; then
    return 1
  fi
  # EFI / non-grub-pc / TEST_ROOT skip paths already PASS.
  if [[ "$GRUB_INSTALL_DEVICE_PREFLIGHT" == "PASS" ]]; then
    return 0
  fi

  if [[ -z "$GRUB_INSTALL_TARGET" ]]; then
    grub_pf_fail_closed grub_install_target_empty
    return 1
  fi

  grub_pf_log INFO "SET_GRUB_TARGET target=${GRUB_INSTALL_TARGET}"
  if ! grub_pf_debconf_set_install_target "$GRUB_INSTALL_TARGET"; then
    grub_pf_fail_closed grub_install_device_write_failed
    return 1
  fi

  if [[ "${GRUB_PF_FORCE_READBACK_FAIL:-0}" == "1" ]]; then
    grub_pf_fail_closed grub_install_device_readback_failed
    return 1
  fi

  grub_pf_log INFO "VERIFY_GRUB_TARGET"
  verify_raw="$(grub_pf_debconf_get_install_devices 2>/dev/null || true)"
  GRUB_INSTALL_DEVICE_AFTER="$verify_raw"
  if ! grub_pf_verify_install_target "$ROOT_PARENT_DISK" "$verify_raw" "$GRUB_INSTALL_TARGET"; then
    grub_pf_fail_closed grub_install_device_verify_failed
    return 1
  fi

  GRUB_INSTALL_DEVICE_PREFLIGHT="PASS"
  OLD_STATE_USED_FOR_CONTROL_FLOW="NO"
  grub_pf_emit_evidence
  grub_pf_log INFO "GRUB_NORMALIZATION_PASS"
  return 0
}
