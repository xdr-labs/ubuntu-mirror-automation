#!/usr/bin/env bash
# Shared AWS kernel source-preflight, pre-reboot target readiness, and
# post-hop completion gate. Inlined into offline upgrade clients / postboot.
#
# Authority is the discovery-derived AWS semantic contract (exact package
# versions / expected kernel releases per hop target VERSION_ID). Series
# major.minor floors are NOT authoritative.
#
# Contract usage:
#   SOURCE PREFLIGHT (VERSION_ID=current source): installed AWS stack must
#     match the hop contract whose TARGET is this VERSION_ID (prior hop
#     completion state). Xenial 16.04 has no prior-hop contract — require a
#     coherent installed AWS stack only.
#   PRE-REBOOT (VERSION_ID=target): target contract packages + boot artifacts
#     must be installed/prepared; do not start automatic reboot on failure.
#   POSTBOOT (VERSION_ID=target): running kernel must be a contract target
#     release; metapackages must match contract; not stale vs source baseline.
# shellcheck shell=bash

aws_gate_log() {
  local level="$1"; shift
  if declare -F log >/dev/null 2>&1; then
    log "$level" "$*"
  else
    printf '%s: %s\n' "$level" "$*"
  fi
}

aws_gate_hp() {
  local p="$1"
  if [[ -n "${TEST_ROOT:-}" ]]; then
    printf '%s%s' "${TEST_ROOT%/}" "$p"
  elif [[ -n "${DP_POSTBOOT_TEST_ROOT:-}" ]]; then
    printf '%s%s' "${DP_POSTBOOT_TEST_ROOT%/}" "$p"
  else
    printf '%s' "$p"
  fi
}

aws_pkg_installed() {
  local pkg="$1" status
  status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
  [[ "$status" == *"install ok installed"* ]]
}

aws_pkg_version() {
  local pkg="$1"
  dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true
}

aws_running_kernel_release() {
  local kr
  kr="$(uname -r 2>/dev/null || true)"
  if [[ -n "${TEST_ROOT:-}" && -n "${DP_OFFLINE_FAKE_KERNEL:-}" ]]; then
    kr="$DP_OFFLINE_FAKE_KERNEL"
  elif [[ -n "${DP_POSTBOOT_TEST_ROOT:-}" && -n "${DP_OFFLINE_FAKE_KERNEL:-}" ]]; then
    kr="$DP_OFFLINE_FAKE_KERNEL"
  fi
  printf '%s' "$kr"
}

# Decode URL-encoded dpkg/discovery versions for comparison.
aws_decode_version() {
  local v="$1"
  v="${v//%2[bB]/+}"
  v="${v//%7[eE]/~}"
  printf '%s' "$v"
}

aws_versions_equal() {
  local a b
  a="$(aws_decode_version "$1")"
  b="$(aws_decode_version "$2")"
  [[ -n "$a" && "$a" == "$b" ]]
}

# Load discovery-derived contract for a target Ubuntu VERSION_ID when needed.
if [[ "${AWS_SEMANTIC_CONTRACT_LOADED:-0}" != "1" ]]; then
  _aws_contract_inc="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/dp-aws-semantic-contract.sh.inc"
  if [[ -n "${_aws_contract_inc}" && -f "${_aws_contract_inc}" ]]; then
    # shellcheck disable=SC1090
    source "${_aws_contract_inc}"
  fi
  unset _aws_contract_inc
fi

aws_contract_available_for_version() {
  declare -F aws_contract_load_for_version_id >/dev/null 2>&1 || return 1
  aws_contract_load_for_version_id "$1"
}

aws_kernel_release_in_contract() {
  local kr="$1" r
  for r in ${AWS_C_KERNEL_RELEASES}; do
    [[ "$kr" == "$r" ]] && return 0
  done
  return 1
}

aws_detect_current_flavor() {
  local flavor kr
  if declare -F kernel_flavor >/dev/null 2>&1; then
    flavor="$(kernel_flavor)"
  else
    flavor=""
    kr="$(aws_running_kernel_release)"
    case "$kr" in
      *-aws) flavor=aws ;;
      *-generic*) flavor=generic ;;
      *) flavor=other ;;
    esac
  fi
  if [[ -z "$flavor" ]]; then
    kr="$(aws_running_kernel_release)"
    case "$kr" in
      *-aws) flavor=aws ;;
      *) flavor=other ;;
    esac
  fi
  printf '%s' "$flavor"
}

detect_aws_upgrade_profile() {
  # Echo "aws" when this host is/was an AWS kernel DP; else "other".
  local holds_dir flavor kr
  holds_dir="${HOLDS_DIR:-${STATE_ROOT:-/opt/aelladata/os-upgrade/offline}/critical-holds}"
  if [[ -f "$(aws_gate_hp "${holds_dir}/source_kernel_flavor")" ]]; then
    flavor="$(tr -d '\r\n' <"$(aws_gate_hp "${holds_dir}/source_kernel_flavor")" || true)"
    if [[ "$flavor" == "aws" ]]; then
      printf 'aws\n'
      return 0
    fi
  fi
  if [[ -n "${SOURCE_KERNEL_FLAVOR:-}" && "$SOURCE_KERNEL_FLAVOR" == "aws" ]]; then
    printf 'aws\n'
    return 0
  fi
  kr="$(aws_running_kernel_release)"
  case "$kr" in
    *-aws) printf 'aws\n'; return 0 ;;
  esac
  if aws_pkg_installed linux-aws || aws_pkg_installed linux-image-aws || aws_pkg_installed linux-headers-aws; then
    printf 'aws\n'
    return 0
  fi
  printf 'other\n'
}

aws_gate_atomic_write_line() {
  # Write one line atomically and verify read-back. Same rules under TEST_ROOT.
  local rel_path="$1" content="$2"
  local dest parent tmp readback
  dest="$(aws_gate_hp "$rel_path")"
  parent="$(dirname "$dest")"
  mkdir -p "$parent" || {
    aws_gate_log ERROR "AWS_BASELINE_PERSIST=FAIL reason=mkdir path=${parent}"
    return 1
  }
  if declare -F durable_atomic_write_string >/dev/null 2>&1; then
    if ! durable_atomic_write_string "aws_baseline" "$dest" "${content}"$'\n' 0644; then
      aws_gate_log ERROR "AWS_BASELINE_PERSIST=FAIL reason=durable_write path=${dest}"
      return 1
    fi
  else
    tmp="${dest}.tmp.$$.$RANDOM"
    if ! printf '%s\n' "$content" >"$tmp"; then
      rm -f "$tmp" 2>/dev/null || true
      aws_gate_log ERROR "AWS_BASELINE_PERSIST=FAIL reason=write path=${dest}"
      return 1
    fi
    if ! mv -f "$tmp" "$dest"; then
      rm -f "$tmp" 2>/dev/null || true
      aws_gate_log ERROR "AWS_BASELINE_PERSIST=FAIL reason=rename path=${dest}"
      return 1
    fi
  fi
  if [[ ! -f "$dest" ]]; then
    aws_gate_log ERROR "AWS_BASELINE_PERSIST=FAIL reason=missing_after_write path=${dest}"
    return 1
  fi
  readback="$(tr -d '\r\n' <"$dest" || true)"
  if [[ "$readback" != "$content" ]]; then
    aws_gate_log ERROR "AWS_BASELINE_PERSIST=FAIL reason=readback_mismatch path=${dest} expected=${content} got=${readback}"
    return 1
  fi
  return 0
}

persist_source_kernel_aws_baseline() {
  # Called from source preflight/baseline. AWS: fail closed. Non-AWS: record flavor only.
  local holds_dir flavor kr aws_ver img_ver
  holds_dir="${HOLDS_DIR:-${STATE_ROOT:-/opt/aelladata/os-upgrade/offline}/critical-holds}"
  flavor="$(aws_detect_current_flavor)"
  kr="$(aws_running_kernel_release)"
  aws_ver="$(aws_pkg_version linux-aws)"
  img_ver="$(aws_pkg_version linux-image-aws)"

  if [[ "$flavor" != "aws" && -z "$aws_ver" && -z "$img_ver" ]]; then
    aws_gate_atomic_write_line "${holds_dir}/source_kernel_flavor" "${flavor:-other}" || return 1
    aws_gate_atomic_write_line "${holds_dir}/source_kernel_release" "${kr}" || return 1
    aws_gate_log INFO "SOURCE_KERNEL_FLAVOR=${flavor:-other}"
    aws_gate_log INFO "AWS_BASELINE_PERSIST=SKIP reason=non_aws_profile"
    return 0
  fi

  # AWS source profile: all four baseline fields are safety-critical.
  if [[ -z "$aws_ver" ]]; then
    aws_gate_log ERROR "AWS_BASELINE_PERSIST=FAIL reason=linux-aws_version_unavailable"
    return 1
  fi
  if [[ -z "$img_ver" ]]; then
    aws_gate_log ERROR "AWS_BASELINE_PERSIST=FAIL reason=linux-image-aws_version_unavailable"
    return 1
  fi
  if [[ -z "$kr" ]]; then
    aws_gate_log ERROR "AWS_BASELINE_PERSIST=FAIL reason=kernel_release_unavailable"
    return 1
  fi

  aws_gate_atomic_write_line "${holds_dir}/source_kernel_flavor" "aws" || return 1
  aws_gate_atomic_write_line "${holds_dir}/source_kernel_release" "$kr" || return 1
  aws_gate_atomic_write_line "${holds_dir}/source_linux_aws_version" "$aws_ver" || return 1
  aws_gate_atomic_write_line "${holds_dir}/source_linux_image_aws_version" "$img_ver" || return 1

  aws_gate_log INFO "SOURCE_KERNEL_FLAVOR=aws"
  aws_gate_log INFO "SOURCE_KERNEL_RELEASE=${kr}"
  aws_gate_log INFO "SOURCE_LINUX_AWS_VERSION=${aws_ver}"
  aws_gate_log INFO "SOURCE_LINUX_IMAGE_AWS_VERSION=${img_ver}"
  aws_gate_log INFO "AWS_BASELINE_PERSIST=PASS"
  return 0
}

validate_aws_source_kernel_preflight() {
  # Arg: current SOURCE Ubuntu VERSION_ID (e.g. 18.04 for Bionic→Focal).
  # Rejects already-bad AWS state before destructive package/LXD/release mutation.
  local source_ver="${1:-}"
  local flavor kr aws_ver img_ver
  flavor="$(aws_detect_current_flavor)"
  if [[ "$flavor" != "aws" ]]; then
    # Also treat installed AWS metapackages as AWS even if flavor helper differs.
    if ! aws_pkg_installed linux-aws && ! aws_pkg_installed linux-image-aws; then
      aws_gate_log INFO "AWS_SOURCE_PREFLIGHT=SKIP reason=non_aws_profile"
      return 0
    fi
    flavor=aws
  fi

  if [[ -z "$source_ver" ]]; then
    aws_gate_log ERROR "NEXT_HOP_PREFLIGHT_FAIL reason=missing_source_version"
    return 1
  fi

  if ! aws_pkg_installed linux-aws; then
    aws_gate_log ERROR "NEXT_HOP_PREFLIGHT_FAIL reason=linux-aws_not_installed"
    return 1
  fi
  if ! aws_pkg_installed linux-image-aws; then
    aws_gate_log ERROR "NEXT_HOP_PREFLIGHT_FAIL reason=linux-image-aws_not_installed"
    return 1
  fi

  kr="$(aws_running_kernel_release)"
  case "$kr" in
    *-aws) ;;
    *)
      aws_gate_log ERROR "NEXT_HOP_PREFLIGHT_FAIL reason=running_kernel_not_aws kernel=${kr}"
      return 1
      ;;
  esac
  if ! aws_pkg_installed "linux-image-${kr}"; then
    aws_gate_log ERROR "NEXT_HOP_PREFLIGHT_FAIL reason=running_aws_image_pkg_missing kernel=${kr}"
    return 1
  fi

  aws_ver="$(aws_pkg_version linux-aws)"
  img_ver="$(aws_pkg_version linux-image-aws)"
  aws_gate_log INFO "AWS_SOURCE_SERIES=${source_ver}"
  aws_gate_log INFO "AWS_SOURCE_RUNNING_KERNEL=${kr}"
  aws_gate_log INFO "AWS_SOURCE_LINUX_AWS_VERSION=${aws_ver:-none}"
  aws_gate_log INFO "AWS_SOURCE_LINUX_IMAGE_AWS_VERSION=${img_ver:-none}"

  # 16.04 has no prior-hop target contract in the four-hop discovery set.
  # Require a coherent AWS stack only (exact identities enforced from 18.04+).
  if [[ "$source_ver" == "16.04" ]]; then
    aws_gate_log INFO "AWS_SOURCE_PREFLIGHT=PASS reason=xenial_source_no_prior_hop_contract"
    return 0
  fi

  if ! aws_contract_available_for_version "$source_ver"; then
    aws_gate_log ERROR "NEXT_HOP_PREFLIGHT_FAIL reason=missing_source_hop_contract series=${source_ver}"
    return 1
  fi
  aws_gate_log INFO "AWS_SOURCE_CONTRACT_HOP=${AWS_C_HOP}"
  aws_gate_log INFO "AWS_SOURCE_CONTRACT_LINUX_AWS=${AWS_C_LINUX_AWS_VERSION}"
  aws_gate_log INFO "AWS_SOURCE_CONTRACT_KERNEL_RELEASES=${AWS_C_KERNEL_RELEASES}"

  if ! aws_versions_equal "$aws_ver" "$AWS_C_LINUX_AWS_VERSION"; then
    aws_gate_log ERROR "NEXT_HOP_PREFLIGHT_FAIL reason=linux-aws_not_source_contract_identity series=${source_ver} expected=${AWS_C_LINUX_AWS_VERSION} installed=${aws_ver}"
    return 1
  fi
  if ! aws_versions_equal "$img_ver" "$AWS_C_LINUX_IMAGE_AWS_VERSION"; then
    aws_gate_log ERROR "NEXT_HOP_PREFLIGHT_FAIL reason=linux-image-aws_not_source_contract_identity series=${source_ver} expected=${AWS_C_LINUX_IMAGE_AWS_VERSION} installed=${img_ver}"
    return 1
  fi
  if ! aws_kernel_release_in_contract "$kr"; then
    aws_gate_log ERROR "NEXT_HOP_PREFLIGHT_FAIL reason=running_kernel_not_source_contract_release series=${source_ver} expected=${AWS_C_KERNEL_RELEASES} kernel=${kr}"
    return 1
  fi

  aws_gate_log INFO "AWS_SOURCE_PREFLIGHT=PASS"
  return 0
}

validate_aws_target_kernel_pre_reboot() {
  # Arg: TARGET Ubuntu VERSION_ID (e.g. 18.04 after xenial→bionic DRO).
  # Runs AFTER package transition and BEFORE automatic reboot.
  # On failure: do not mark hop successful; do not initiate automatic reboot.
  # No rollback after package transition begins.
  local target_ver="${1:-}"
  local profile holds_dir src_kr
  local cur_aws cur_img img_pkg kr boot_dir vmlinuz initrd matched_kr
  profile="$(detect_aws_upgrade_profile)"
  if [[ "$profile" != "aws" ]]; then
    aws_gate_log INFO "PRE_REBOOT_AWS_TARGET_GATE=SKIP reason=non_aws_profile"
    return 0
  fi

  if [[ -z "$target_ver" ]]; then
    aws_gate_log ERROR "PRE_REBOOT_AWS_TARGET_GATE=FAIL reason=missing_target_version"
    aws_gate_log ERROR "AUTOMATIC_REBOOT_NOT_STARTED"
    return 1
  fi
  if ! aws_contract_available_for_version "$target_ver"; then
    aws_gate_log ERROR "PRE_REBOOT_AWS_TARGET_GATE=FAIL reason=missing_target_hop_contract series=${target_ver}"
    aws_gate_log ERROR "AUTOMATIC_REBOOT_NOT_STARTED"
    return 1
  fi

  holds_dir="${HOLDS_DIR:-${STATE_ROOT:-/opt/aelladata/os-upgrade/offline}/critical-holds}"
  src_kr=""
  if [[ -f "$(aws_gate_hp "${holds_dir}/source_kernel_release")" ]]; then
    src_kr="$(tr -d '\r\n' <"$(aws_gate_hp "${holds_dir}/source_kernel_release")" || true)"
  fi

  aws_gate_log INFO "PRE_REBOOT_AWS_TARGET_CONTRACT_HOP=${AWS_C_HOP}"
  aws_gate_log INFO "PRE_REBOOT_AWS_TARGET_CONTRACT_LINUX_AWS=${AWS_C_LINUX_AWS_VERSION}"
  aws_gate_log INFO "PRE_REBOOT_AWS_TARGET_CONTRACT_KERNEL_RELEASES=${AWS_C_KERNEL_RELEASES}"

  if ! aws_pkg_installed linux-aws; then
    aws_gate_log ERROR "PRE_REBOOT_AWS_TARGET_GATE=FAIL reason=linux-aws_not_installed"
    aws_gate_log ERROR "AUTOMATIC_REBOOT_NOT_STARTED"
    return 1
  fi
  if ! aws_pkg_installed linux-image-aws; then
    aws_gate_log ERROR "PRE_REBOOT_AWS_TARGET_GATE=FAIL reason=linux-image-aws_not_installed"
    aws_gate_log ERROR "AUTOMATIC_REBOOT_NOT_STARTED"
    return 1
  fi

  cur_aws="$(aws_pkg_version linux-aws)"
  cur_img="$(aws_pkg_version linux-image-aws)"
  if [[ -z "$cur_aws" || -z "$cur_img" ]]; then
    aws_gate_log ERROR "PRE_REBOOT_AWS_TARGET_GATE=FAIL reason=metapackage_version_unavailable"
    aws_gate_log ERROR "AUTOMATIC_REBOOT_NOT_STARTED"
    return 1
  fi
  if ! aws_versions_equal "$cur_aws" "$AWS_C_LINUX_AWS_VERSION"; then
    aws_gate_log ERROR "PRE_REBOOT_AWS_TARGET_GATE=FAIL reason=linux-aws_not_target_contract_identity expected=${AWS_C_LINUX_AWS_VERSION} installed=${cur_aws}"
    aws_gate_log ERROR "AUTOMATIC_REBOOT_NOT_STARTED"
    return 1
  fi
  if ! aws_versions_equal "$cur_img" "$AWS_C_LINUX_IMAGE_AWS_VERSION"; then
    aws_gate_log ERROR "PRE_REBOOT_AWS_TARGET_GATE=FAIL reason=linux-image-aws_not_target_contract_identity expected=${AWS_C_LINUX_IMAGE_AWS_VERSION} installed=${cur_img}"
    aws_gate_log ERROR "AUTOMATIC_REBOOT_NOT_STARTED"
    return 1
  fi

  matched_kr=""
  for kr in ${AWS_C_KERNEL_RELEASES}; do
    img_pkg="linux-image-${kr}"
    if aws_pkg_installed "$img_pkg"; then
      # Must not be merely the original source kernel release.
      if [[ -n "$src_kr" && "$kr" == "$src_kr" ]]; then
        aws_gate_log ERROR "PRE_REBOOT_AWS_TARGET_GATE=FAIL reason=target_image_still_source_kernel kernel=${kr}"
        aws_gate_log ERROR "AUTOMATIC_REBOOT_NOT_STARTED"
        return 1
      fi
      boot_dir="$(aws_gate_hp /boot)"
      vmlinuz="${boot_dir}/vmlinuz-${kr}"
      initrd="${boot_dir}/initrd.img-${kr}"
      if [[ ! -f "$vmlinuz" || ! -s "$vmlinuz" ]]; then
        aws_gate_log ERROR "PRE_REBOOT_AWS_TARGET_GATE=FAIL reason=missing_target_vmlinuz kernel=${kr} path=${vmlinuz}"
        aws_gate_log ERROR "AUTOMATIC_REBOOT_NOT_STARTED"
        return 1
      fi
      if [[ ! -f "$initrd" || ! -s "$initrd" ]]; then
        aws_gate_log ERROR "PRE_REBOOT_AWS_TARGET_GATE=FAIL reason=missing_target_initrd kernel=${kr} path=${initrd}"
        aws_gate_log ERROR "AUTOMATIC_REBOOT_NOT_STARTED"
        return 1
      fi
      matched_kr="$kr"
      break
    fi
  done

  if [[ -z "$matched_kr" ]]; then
    aws_gate_log ERROR "PRE_REBOOT_AWS_TARGET_GATE=FAIL reason=target_versioned_aws_image_not_installed expected=${AWS_C_VERSIONED_IMAGE_PACKAGES}"
    aws_gate_log ERROR "AUTOMATIC_REBOOT_NOT_STARTED"
    return 1
  fi

  aws_gate_log INFO "PRE_REBOOT_AWS_TARGET_KERNEL=${matched_kr}"
  aws_gate_log INFO "PRE_REBOOT_AWS_TARGET_GATE=PASS"
  return 0
}

validate_aws_post_hop_kernel_gate() {
  # Arguments: expected_target_version_id (e.g. 18.04). Discovery contract authority.
  # Runs after reboot, immediately before COMPLETED_*. No "pending reboot" PASS.
  local target_ver="${1:-}"
  local profile holds_dir src_aws src_img src_kr src_flavor
  local cur_aws cur_img kr boot_aws
  profile="$(detect_aws_upgrade_profile)"
  if [[ "$profile" != "aws" ]]; then
    aws_gate_log INFO "AWS_POST_HOP_KERNEL_GATE=SKIP reason=non_aws_profile"
    return 0
  fi

  if [[ -z "$target_ver" ]]; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=missing_target_version"
    return 1
  fi
  if ! aws_contract_available_for_version "$target_ver"; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=missing_target_hop_contract series=${target_ver}"
    return 1
  fi

  holds_dir="${HOLDS_DIR:-${STATE_ROOT:-/opt/aelladata/os-upgrade/offline}/critical-holds}"
  src_flavor=""
  src_kr=""
  src_aws=""
  src_img=""
  if [[ -f "$(aws_gate_hp "${holds_dir}/source_kernel_flavor")" ]]; then
    src_flavor="$(tr -d '\r\n' <"$(aws_gate_hp "${holds_dir}/source_kernel_flavor")" || true)"
  fi
  if [[ -f "$(aws_gate_hp "${holds_dir}/source_kernel_release")" ]]; then
    src_kr="$(tr -d '\r\n' <"$(aws_gate_hp "${holds_dir}/source_kernel_release")" || true)"
  fi
  if [[ -f "$(aws_gate_hp "${holds_dir}/source_linux_aws_version")" ]]; then
    src_aws="$(tr -d '\r\n' <"$(aws_gate_hp "${holds_dir}/source_linux_aws_version")" || true)"
  fi
  if [[ -f "$(aws_gate_hp "${holds_dir}/source_linux_image_aws_version")" ]]; then
    src_img="$(tr -d '\r\n' <"$(aws_gate_hp "${holds_dir}/source_linux_image_aws_version")" || true)"
  fi

  # Missing baseline must not allow a stale 4.4 stack to PASS via skipped compares.
  if [[ "$src_flavor" != "aws" || -z "$src_aws" || -z "$src_img" || -z "$src_kr" ]]; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=missing_source_baseline flavor=${src_flavor:-none} aws=${src_aws:-none} img=${src_img:-none} kr=${src_kr:-none}"
    return 1
  fi

  if ! aws_pkg_installed linux-aws; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=linux-aws_not_installed"
    return 1
  fi
  if ! aws_pkg_installed linux-image-aws; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=linux-image-aws_not_installed"
    return 1
  fi

  cur_aws="$(aws_pkg_version linux-aws)"
  cur_img="$(aws_pkg_version linux-image-aws)"
  aws_gate_log INFO "AWS_LINUX_AWS_VERSION=${cur_aws:-none}"
  aws_gate_log INFO "AWS_LINUX_IMAGE_AWS_VERSION=${cur_img:-none}"
  aws_gate_log INFO "AWS_POST_HOP_TARGET_VERSION=${target_ver}"
  aws_gate_log INFO "AWS_POST_HOP_CONTRACT_HOP=${AWS_C_HOP}"
  aws_gate_log INFO "AWS_POST_HOP_CONTRACT_LINUX_AWS=${AWS_C_LINUX_AWS_VERSION}"
  aws_gate_log INFO "AWS_POST_HOP_CONTRACT_KERNEL_RELEASES=${AWS_C_KERNEL_RELEASES}"

  if [[ -z "$cur_aws" || -z "$cur_img" ]]; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=metapackage_version_unavailable"
    return 1
  fi

  # Stale source metapackage: still equal to pre-upgrade baseline.
  if aws_versions_equal "$src_aws" "$cur_aws"; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=stale_linux-aws_metapackage source=${src_aws} installed=${cur_aws}"
    return 1
  fi
  if aws_versions_equal "$src_img" "$cur_img"; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=stale_linux-image-aws_metapackage source=${src_img} installed=${cur_img}"
    return 1
  fi

  # Target contract identity (not major.minor floor, not "version changed").
  if ! aws_versions_equal "$cur_aws" "$AWS_C_LINUX_AWS_VERSION"; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=linux-aws_not_target_contract_identity expected=${AWS_C_LINUX_AWS_VERSION} installed=${cur_aws}"
    return 1
  fi
  if ! aws_versions_equal "$cur_img" "$AWS_C_LINUX_IMAGE_AWS_VERSION"; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=linux-image-aws_not_target_contract_identity expected=${AWS_C_LINUX_IMAGE_AWS_VERSION} installed=${cur_img}"
    return 1
  fi

  boot_aws=0
  if ls "$(aws_gate_hp /boot)"/vmlinu*-aws >/dev/null 2>&1; then
    boot_aws=1
  fi
  if [[ "$boot_aws" -ne 1 ]]; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=no_boot_vmlinuz_aws"
    return 1
  fi

  kr="$(aws_running_kernel_release)"
  case "$kr" in
    *-aws) ;;
    *)
      aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=running_kernel_not_aws kernel=${kr}"
      return 1
      ;;
  esac
  if ! aws_kernel_release_in_contract "$kr"; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=running_kernel_not_target_contract_release expected=${AWS_C_KERNEL_RELEASES} kernel=${kr}"
    return 1
  fi
  if ! aws_pkg_installed "linux-image-${kr}"; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=running_aws_image_pkg_missing kernel=${kr}"
    return 1
  fi

  aws_gate_log INFO "AWS_POST_HOP_KERNEL_GATE=PASS"
  return 0
}
