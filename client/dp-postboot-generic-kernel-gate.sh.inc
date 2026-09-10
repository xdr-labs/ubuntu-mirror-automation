#!/usr/bin/env bash
# Generic/virtual kernel continuity gate for OS hops (non-AWS).
# shellcheck shell=bash
#
# Complements (does not replace) the AWS exact-contract gate.
# Goals: reject target userspace + stale source running kernel as success.
# Does NOT hardcode laboratory-specific generic ABI package versions.

generic_gate_log() {
  local level="$1"; shift
  if declare -F log >/dev/null 2>&1; then
    log "$level" "$*"
  else
    printf '%s: %s\n' "$level" "$*"
  fi
}

generic_gate_hp() {
  local p="$1"
  if [[ -n "${TEST_ROOT:-}" ]]; then
    printf '%s%s' "${TEST_ROOT%/}" "$p"
  elif [[ -n "${DP_POSTBOOT_TEST_ROOT:-}" ]]; then
    printf '%s%s' "${DP_POSTBOOT_TEST_ROOT%/}" "$p"
  else
    printf '%s' "$p"
  fi
}

generic_running_kernel_release() {
  local kr
  kr="$(uname -r 2>/dev/null || true)"
  if [[ -n "${TEST_ROOT:-}${DP_POSTBOOT_TEST_ROOT:-}" && -n "${DP_OFFLINE_FAKE_KERNEL:-}" ]]; then
    kr="$DP_OFFLINE_FAKE_KERNEL"
  fi
  printf '%s' "$kr"
}

generic_kernel_flavor() {
  local kr="${1:-}"
  [[ -n "$kr" ]] || kr="$(generic_running_kernel_release)"
  case "$kr" in
    *-aws) printf 'aws' ;;
    *-generic-lpae) printf 'generic-lpae' ;;
    *-generic) printf 'generic' ;;
    *-virtual) printf 'virtual' ;;
    *) printf 'other' ;;
  esac
}

generic_pkg_installed() {
  local pkg="$1" status
  status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
  [[ "$status" == *"install ok installed"* ]]
}

# Map Ubuntu VERSION_ID → acceptable running-kernel series patterns (ERE).
# Intentionally series-based, not exact ABI pins.
generic_target_kernel_series_ere() {
  case "${1:-}" in
    18.04) printf '%s' '^(4\.15[.-].*-generic(-lpae)?|4\.1[6-9][.-].*-generic(-lpae)?|5\.[0-9]+[.-].*-generic(-lpae)?)$' ;;
    20.04) printf '%s' '^(5\.4[.-].*-generic(-lpae)?|5\.[5-9][.-].*-generic(-lpae)?|5\.[1-9][0-9][.-].*-generic(-lpae)?)$' ;;
    22.04) printf '%s' '^(5\.15[.-].*-generic(-lpae)?|5\.1[6-9][.-].*-generic(-lpae)?|5\.[2-9][0-9][.-].*-generic(-lpae)?|6\.[0-9]+[.-].*-generic(-lpae)?)$' ;;
    24.04) printf '%s' '^(6\.[8-9][.-].*-generic(-lpae)?|6\.[1-9][0-9][.-].*-generic(-lpae)?|7\.[0-9]+[.-].*-generic(-lpae)?)$' ;;
    *) return 1 ;;
  esac
}

generic_is_aws_profile() {
  local flavor
  if declare -F detect_aws_upgrade_profile >/dev/null 2>&1; then
    detect_aws_upgrade_profile >/dev/null 2>&1 && return 0
  fi
  flavor="$(generic_kernel_flavor)"
  [[ "$flavor" == "aws" ]]
}

persist_source_kernel_generic_baseline() {
  local holds_dir flavor kr
  holds_dir="${HOLDS_DIR:-${STATE_ROOT:-/opt/aelladata/os-upgrade/offline}/critical-holds}"
  flavor="$(generic_kernel_flavor)"
  kr="$(generic_running_kernel_release)"
  mkdir -p "$(generic_gate_hp "$holds_dir")" 2>/dev/null || true
  if declare -F durable_atomic_write_string >/dev/null 2>&1; then
    durable_atomic_write_string "generic_src_flavor" "$(generic_gate_hp "${holds_dir}/source_kernel_flavor")" "${flavor}"$'\n' 0644 || true
    durable_atomic_write_string "generic_src_kr" "$(generic_gate_hp "${holds_dir}/source_kernel_release")" "${kr}"$'\n' 0644 || true
  else
    printf '%s\n' "$flavor" >"$(generic_gate_hp "${holds_dir}/source_kernel_flavor")"
    printf '%s\n' "$kr" >"$(generic_gate_hp "${holds_dir}/source_kernel_release")"
  fi
  generic_gate_log INFO "SOURCE_KERNEL_FLAVOR=${flavor}"
  generic_gate_log INFO "SOURCE_KERNEL_RELEASE=${kr}"
  generic_gate_log INFO "GENERIC_SOURCE_KERNEL_BASELINE=PASS"
  return 0
}

# PRE-REBOOT: target kernel image + matching initrd exist; not merely source kernel.
# Arg: target Ubuntu VERSION_ID
validate_generic_target_kernel_pre_reboot() {
  local target_ver="${1:-}"
  local holds_dir src_kr flavor boot_dir found=0 kr img initrd
  if generic_is_aws_profile; then
    generic_gate_log INFO "PRE_REBOOT_GENERIC_TARGET_GATE=SKIP reason=aws_profile"
    return 0
  fi
  holds_dir="${HOLDS_DIR:-${STATE_ROOT:-/opt/aelladata/os-upgrade/offline}/critical-holds}"
  src_kr=""
  if [[ -f "$(generic_gate_hp "${holds_dir}/source_kernel_release")" ]]; then
    src_kr="$(tr -d '\r\n' <"$(generic_gate_hp "${holds_dir}/source_kernel_release")" || true)"
  fi
  flavor="$(generic_kernel_flavor "${src_kr}")"
  case "$flavor" in
    generic|generic-lpae|virtual|other)
      ;;
    aws)
      generic_gate_log INFO "PRE_REBOOT_GENERIC_TARGET_GATE=SKIP reason=aws_flavor"
      return 0
      ;;
  esac

  # Prefer metapackage presence without pinning exact ABI.
  if ! generic_pkg_installed linux-image-generic \
    && ! generic_pkg_installed linux-image-virtual \
    && ! generic_pkg_installed linux-generic; then
    generic_gate_log ERROR "PRE_REBOOT_GENERIC_TARGET_GATE=FAIL reason=target_generic_metapackage_missing"
    generic_gate_log ERROR "AUTOMATIC_REBOOT_NOT_STARTED=YES"
    generic_gate_log ERROR "POSTBOOT_HANDOFF_READY=NO"
    return 1
  fi

  boot_dir="$(generic_gate_hp /boot)"
  # Look for installed versioned generic/virtual images that are not the source release.
  while IFS= read -r img; do
    [[ -n "$img" ]] || continue
    kr="${img#linux-image-}"
    case "$kr" in
      *-generic|*-generic-lpae|*-virtual) ;;
      *) continue ;;
    esac
    if [[ -n "$src_kr" && "$kr" == "$src_kr" ]]; then
      continue
    fi
    # Series coherence when target VERSION_ID known
    if [[ -n "$target_ver" ]]; then
      local ere
      ere="$(generic_target_kernel_series_ere "$target_ver" || true)"
      if [[ -n "$ere" ]] && ! printf '%s' "$kr" | grep -Eq "$ere"; then
        continue
      fi
    fi
    initrd="${boot_dir}/initrd.img-${kr}"
    if [[ -f "${boot_dir}/vmlinuz-${kr}" && -s "${boot_dir}/vmlinuz-${kr}" \
      && -f "$initrd" && -s "$initrd" ]]; then
      found=1
      generic_gate_log INFO "PRE_REBOOT_GENERIC_TARGET_KERNEL=${kr}"
      break
    fi
  done < <(dpkg-query -W -f='${Package}\n' 'linux-image-*' 2>/dev/null | grep -E '^linux-image-[0-9]' || true)

  if [[ "$found" -ne 1 ]]; then
    generic_gate_log ERROR "PRE_REBOOT_GENERIC_TARGET_GATE=FAIL reason=no_target_series_vmlinuz_initrd source_kernel=${src_kr:-unknown}"
    generic_gate_log ERROR "AUTOMATIC_REBOOT_NOT_STARTED=YES"
    generic_gate_log ERROR "POSTBOOT_HANDOFF_READY=NO"
    return 1
  fi
  generic_gate_log INFO "PRE_REBOOT_GENERIC_TARGET_GATE=PASS"
  return 0
}

# POSTBOOT: running kernel must not equal source; must match target series/flavor.
# Arg: target Ubuntu VERSION_ID
validate_generic_running_kernel_postboot() {
  local target_ver="${1:-}"
  local holds_dir src_kr kr flavor ere img_pkg
  if generic_is_aws_profile; then
    generic_gate_log INFO "GENERIC_POST_HOP_KERNEL_GATE=SKIP reason=aws_profile"
    return 0
  fi
  holds_dir="${HOLDS_DIR:-${STATE_ROOT:-/opt/aelladata/os-upgrade/offline}/critical-holds}"
  src_kr=""
  if [[ -f "$(generic_gate_hp "${holds_dir}/source_kernel_release")" ]]; then
    src_kr="$(tr -d '\r\n' <"$(generic_gate_hp "${holds_dir}/source_kernel_release")" || true)"
  fi
  kr="$(generic_running_kernel_release)"
  flavor="$(generic_kernel_flavor "$kr")"
  if [[ -z "$kr" ]]; then
    generic_gate_log ERROR "GENERIC_POST_HOP_KERNEL_GATE=FAIL reason=running_kernel_unavailable"
    return 1
  fi
  if [[ -n "$src_kr" && "$kr" == "$src_kr" ]]; then
    generic_gate_log ERROR "GENERIC_POST_HOP_KERNEL_GATE=FAIL reason=running_kernel_still_source kernel=${kr}"
    return 1
  fi
  case "$flavor" in
    generic|generic-lpae|virtual) ;;
    aws)
      generic_gate_log INFO "GENERIC_POST_HOP_KERNEL_GATE=SKIP reason=aws_flavor"
      return 0
      ;;
    *)
      generic_gate_log ERROR "GENERIC_POST_HOP_KERNEL_GATE=FAIL reason=unexpected_flavor flavor=${flavor} kernel=${kr}"
      return 1
      ;;
  esac
  ere="$(generic_target_kernel_series_ere "$target_ver" || true)"
  if [[ -z "$ere" ]]; then
    generic_gate_log ERROR "GENERIC_POST_HOP_KERNEL_GATE=FAIL reason=unknown_target_version ${target_ver}"
    return 1
  fi
  if ! printf '%s' "$kr" | grep -Eq "$ere"; then
    generic_gate_log ERROR "GENERIC_POST_HOP_KERNEL_GATE=FAIL reason=kernel_not_target_series kernel=${kr} target=${target_ver}"
    return 1
  fi
  img_pkg="linux-image-${kr}"
  if ! generic_pkg_installed "$img_pkg"; then
    generic_gate_log ERROR "GENERIC_POST_HOP_KERNEL_GATE=FAIL reason=running_image_package_missing package=${img_pkg}"
    return 1
  fi
  # OS VERSION_ID must match hop target when readable.
  local vid
  vid="$(grep -E '^VERSION_ID=' "$(generic_gate_hp /etc/os-release)" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)"
  if [[ -n "$target_ver" && -n "$vid" && "$vid" != "$target_ver" ]]; then
    generic_gate_log ERROR "GENERIC_POST_HOP_KERNEL_GATE=FAIL reason=os_version_mismatch expected=${target_ver} got=${vid}"
    return 1
  fi
  generic_gate_log INFO "GENERIC_POST_HOP_KERNEL_GATE=PASS kernel=${kr} flavor=${flavor}"
  return 0
}
