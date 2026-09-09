#!/usr/bin/env bash
# Shared AWS kernel source-preflight + post-hop completion gate.
# Inlined into offline upgrade clients / postboot helpers.
#
# Contract (AWS source profile):
#   - next-hop source preflight: installed/running AWS stack must be compatible
#     with the CURRENT SOURCE Ubuntu series before any destructive mutation
#   - baseline persistence: fail closed; atomic write + read-back
#   - postboot COMPLETED_* gate: running kernel must be *-aws; both metapackages
#     must be installed, target-series-compatible, and distinct from source baseline
#
# Do not hard-code a single ABI (e.g. 5.4.0-1103). Series floors are GA major.minor
# for linux-aws on that Ubuntu LTS; HWE kernels (>= floor) are accepted.
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

# GA linux-aws major.minor floor per Ubuntu LTS (not an ABI pin).
# Discovery/installs may use HWE kernels at or above this floor.
aws_series_kernel_floor() {
  case "$1" in
    16.04) printf '4.4' ;;
    18.04) printf '4.15' ;;
    20.04) printf '5.4' ;;
    22.04) printf '5.15' ;;
    24.04) printf '6.8' ;;
    *) return 1 ;;
  esac
}

# Parse major.minor from uname -r (4.4.0-1128-aws) or dpkg version
# (4.4.0.1128.133 / 5.4.0.1103.81 / 5.4.0-1103.111~18.04.1).
aws_parse_major_minor() {
  local raw="$1"
  if [[ "$raw" =~ ^([0-9]+)\.([0-9]+) ]]; then
    printf '%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

aws_mm_ge() {
  # Return 0 if major.minor $1 >= $2.
  local a="$1" b="$2"
  local a1 a2 b1 b2
  IFS=. read -r a1 a2 <<<"$a"
  IFS=. read -r b1 b2 <<<"$b"
  a1=${a1:-0}; a2=${a2:-0}; b1=${b1:-0}; b2=${b2:-0}
  if (( a1 > b1 )); then return 0; fi
  if (( a1 < b1 )); then return 1; fi
  (( a2 >= b2 ))
}

aws_value_meets_series_floor() {
  local series="$1" value="$2" floor mm
  floor="$(aws_series_kernel_floor "$series")" || return 1
  mm="$(aws_parse_major_minor "$value")" || return 1
  aws_mm_ge "$mm" "$floor"
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
  local flavor kr aws_ver img_ver floor
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
  floor="$(aws_series_kernel_floor "$source_ver")" || {
    aws_gate_log ERROR "NEXT_HOP_PREFLIGHT_FAIL reason=unknown_source_series series=${source_ver}"
    return 1
  }

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
  aws_gate_log INFO "AWS_SOURCE_SERIES=${source_ver} floor=${floor}"
  aws_gate_log INFO "AWS_SOURCE_RUNNING_KERNEL=${kr}"
  aws_gate_log INFO "AWS_SOURCE_LINUX_AWS_VERSION=${aws_ver:-none}"
  aws_gate_log INFO "AWS_SOURCE_LINUX_IMAGE_AWS_VERSION=${img_ver:-none}"

  if ! aws_value_meets_series_floor "$source_ver" "$kr"; then
    aws_gate_log ERROR "NEXT_HOP_PREFLIGHT_FAIL reason=running_kernel_incompatible_with_source_series series=${source_ver} floor=${floor} kernel=${kr}"
    return 1
  fi
  if ! aws_value_meets_series_floor "$source_ver" "$aws_ver"; then
    aws_gate_log ERROR "NEXT_HOP_PREFLIGHT_FAIL reason=linux-aws_incompatible_with_source_series series=${source_ver} floor=${floor} version=${aws_ver}"
    return 1
  fi
  if ! aws_value_meets_series_floor "$source_ver" "$img_ver"; then
    aws_gate_log ERROR "NEXT_HOP_PREFLIGHT_FAIL reason=linux-image-aws_incompatible_with_source_series series=${source_ver} floor=${floor} version=${img_ver}"
    return 1
  fi

  aws_gate_log INFO "AWS_SOURCE_PREFLIGHT=PASS"
  return 0
}

validate_aws_post_hop_kernel_gate() {
  # Arguments: expected_target_version_id (e.g. 18.04). Used for series-floor checks.
  # Runs after reboot, immediately before COMPLETED_*. No "pending reboot" PASS.
  local target_ver="${1:-}"
  local profile holds_dir src_aws src_img src_kr src_flavor
  local cur_aws cur_img kr boot_aws floor
  profile="$(detect_aws_upgrade_profile)"
  if [[ "$profile" != "aws" ]]; then
    aws_gate_log INFO "AWS_POST_HOP_KERNEL_GATE=SKIP reason=non_aws_profile"
    return 0
  fi

  if [[ -z "$target_ver" ]]; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=missing_target_version"
    return 1
  fi
  floor="$(aws_series_kernel_floor "$target_ver")" || {
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=unknown_target_series series=${target_ver}"
    return 1
  }

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
  aws_gate_log INFO "AWS_POST_HOP_TARGET_VERSION=${target_ver} floor=${floor}"

  if [[ -z "$cur_aws" || -z "$cur_img" ]]; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=metapackage_version_unavailable"
    return 1
  fi

  # Stale source metapackage: still equal to pre-upgrade baseline.
  if [[ "$src_aws" == "$cur_aws" ]]; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=stale_linux-aws_metapackage source=${src_aws} installed=${cur_aws}"
    return 1
  fi
  if [[ "$src_img" == "$cur_img" ]]; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=stale_linux-image-aws_metapackage source=${src_img} installed=${cur_img}"
    return 1
  fi

  # Target-series compatibility: version-changed alone is insufficient.
  if ! aws_value_meets_series_floor "$target_ver" "$cur_aws"; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=linux-aws_incompatible_with_target_series series=${target_ver} floor=${floor} version=${cur_aws}"
    return 1
  fi
  if ! aws_value_meets_series_floor "$target_ver" "$cur_img"; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=linux-image-aws_incompatible_with_target_series series=${target_ver} floor=${floor} version=${cur_img}"
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
  if ! aws_value_meets_series_floor "$target_ver" "$kr"; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=running_kernel_incompatible_with_target_series series=${target_ver} floor=${floor} kernel=${kr}"
    return 1
  fi
  if ! aws_pkg_installed "linux-image-${kr}"; then
    aws_gate_log ERROR "AWS_POST_HOP_KERNEL_GATE=FAIL reason=running_aws_image_pkg_missing kernel=${kr}"
    return 1
  fi

  aws_gate_log INFO "AWS_POST_HOP_KERNEL_GATE=PASS"
  return 0
}
