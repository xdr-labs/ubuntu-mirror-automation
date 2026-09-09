#!/usr/bin/env bash
# Shared AWS post-hop kernel completion gate.
# Inlined into offline upgrade clients / postboot helpers.
# Fail closed when an AWS-source DP reaches the target Ubuntu release but still
# retains a stale source-release linux-aws metapackage stack.
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

persist_source_kernel_aws_baseline() {
  # Called from preflight/baseline on the source release.
  local holds_dir flavor kr aws_ver img_ver
  holds_dir="${HOLDS_DIR:-${STATE_ROOT:-/opt/aelladata/os-upgrade/offline}/critical-holds}"
  mkdir -p "$(aws_gate_hp "$holds_dir")" 2>/dev/null || true
  if declare -F kernel_flavor >/dev/null 2>&1; then
    flavor="$(kernel_flavor)"
  else
    flavor=""
    kr="$(uname -r 2>/dev/null || true)"
    case "$kr" in
      *-aws) flavor=aws ;;
    esac
  fi
  kr="$(uname -r 2>/dev/null || true)"
  if [[ -n "${TEST_ROOT:-}" && -n "${DP_OFFLINE_FAKE_KERNEL:-}" ]]; then
    kr="$DP_OFFLINE_FAKE_KERNEL"
  fi
  aws_ver="$(aws_pkg_version linux-aws)"
  img_ver="$(aws_pkg_version linux-image-aws)"
  printf '%s\n' "$flavor" >"$(aws_gate_hp "${holds_dir}/source_kernel_flavor")"
  printf '%s\n' "$kr" >"$(aws_gate_hp "${holds_dir}/source_kernel_release")"
  printf '%s\n' "${aws_ver:-}" >"$(aws_gate_hp "${holds_dir}/source_linux_aws_version")"
  printf '%s\n' "${img_ver:-}" >"$(aws_gate_hp "${holds_dir}/source_linux_image_aws_version")"
  aws_gate_log INFO "SOURCE_KERNEL_FLAVOR=${flavor}"
  aws_gate_log INFO "SOURCE_KERNEL_RELEASE=${kr}"
  if [[ "$flavor" == "aws" || -n "$aws_ver" || -n "$img_ver" ]]; then
    aws_gate_log INFO "SOURCE_LINUX_AWS_VERSION=${aws_ver:-none}"
    aws_gate_log INFO "SOURCE_LINUX_IMAGE_AWS_VERSION=${img_ver:-none}"
  fi
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
  kr="$(uname -r 2>/dev/null || true)"
  if [[ -n "${TEST_ROOT:-}" && -n "${DP_OFFLINE_FAKE_KERNEL:-}" ]]; then
    kr="$DP_OFFLINE_FAKE_KERNEL"
  fi
  case "$kr" in
    *-aws) printf 'aws\n'; return 0 ;;
  esac
  if aws_pkg_installed linux-aws || aws_pkg_installed linux-image-aws || aws_pkg_installed linux-headers-aws; then
    printf 'aws\n'
    return 0
  fi
  printf 'other\n'
}

validate_aws_post_hop_kernel_gate() {
  # Arguments: expected_target_version_id (e.g. 18.04) — informational only.
  local target_ver="${1:-}"
  local profile holds_dir src_aws src_img cur_aws cur_img kr boot_aws
  profile="$(detect_aws_upgrade_profile)"
  if [[ "$profile" != "aws" ]]; then
    aws_gate_log INFO "AWS_POST_HOP_KERNEL_GATE=SKIP reason=non_aws_profile"
    return 0
  fi

  holds_dir="${HOLDS_DIR:-${STATE_ROOT:-/opt/aelladata/os-upgrade/offline}/critical-holds}"
  src_aws=""
  src_img=""
  if [[ -f "$(aws_gate_hp "${holds_dir}/source_linux_aws_version")" ]]; then
    src_aws="$(tr -d '\r\n' <"$(aws_gate_hp "${holds_dir}/source_linux_aws_version")" || true)"
  fi
  if [[ -f "$(aws_gate_hp "${holds_dir}/source_linux_image_aws_version")" ]]; then
    src_img="$(tr -d '\r\n' <"$(aws_gate_hp "${holds_dir}/source_linux_image_aws_version")" || true)"
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
  if [[ -n "$target_ver" ]]; then
    aws_gate_log INFO "AWS_POST_HOP_TARGET_VERSION=${target_ver}"
  fi

  # Stale source metapackage: installed linux-aws still equals pre-upgrade version.
  if [[ -n "$src_aws" && -n "$cur_aws" && "$src_aws" == "$cur_aws" ]]; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=stale_linux-aws_metapackage source=${src_aws} installed=${cur_aws}"
    return 1
  fi
  if [[ -n "$src_img" && -n "$cur_img" && "$src_img" == "$cur_img" ]]; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=stale_linux-image-aws_metapackage source=${src_img} installed=${cur_img}"
    return 1
  fi

  # Bootable AWS kernel artifact must exist (do not hard-code ABI numbers).
  boot_aws=0
  if ls "$(aws_gate_hp /boot)"/vmlinu*-aws >/dev/null 2>&1; then
    boot_aws=1
  fi
  if [[ "$boot_aws" -ne 1 ]]; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=no_boot_vmlinuz_aws"
    return 1
  fi

  kr="$(uname -r 2>/dev/null || true)"
  if [[ -n "${TEST_ROOT:-}" && -n "${DP_OFFLINE_FAKE_KERNEL:-}" ]]; then
    kr="$DP_OFFLINE_FAKE_KERNEL"
  fi
  case "$kr" in
    *-aws)
      if ! aws_pkg_installed "linux-image-${kr}"; then
        aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=running_aws_image_pkg_missing kernel=${kr}"
        return 1
      fi
      ;;
    *)
      # Allow deferred reboot onto the new AWS ABI, but never accept a completed
      # hop while the metapackage is still the source-release version (checked above).
      aws_gate_log INFO "AWS_RUNNING_KERNEL_FLAVOR=non_aws_pending_reboot kernel=${kr}"
      ;;
  esac

  aws_gate_log INFO "AWS_POST_HOP_KERNEL_GATE=PASS"
  return 0
}
