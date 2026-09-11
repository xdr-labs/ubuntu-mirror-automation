#!/usr/bin/env bash
# Bionic→Focal AWS postboot package-closure recovery.
#
# Recoverable class only:
#   Host already on Focal (20.04), AWS profile, running kernel is an acceptable
#   Focal AWS contract release, but linux-aws / linux-image-aws meta closure is
#   incomplete (e.g. linux-aws missing after do-release-upgrade).
#
# This helper NEVER writes COMPLETED_FOCAL. After a successful bounded repair it
# returns control so the installed postboot validator remains authoritative.
# shellcheck shell=bash

aws_pcr_log() {
  local level="$1"; shift
  if declare -F log >/dev/null 2>&1; then
    log "$level" "$*"
  else
    printf '%s: %s\n' "$level" "$*"
  fi
}

aws_pcr_die() {
  local ec="${1:-1}"
  shift
  if declare -F die >/dev/null 2>&1; then
    die "$ec" "$*"
  fi
  aws_pcr_log ERROR "$*"
  exit "$ec"
}

aws_pcr_hp() {
  local p="$1"
  if declare -F hostpath >/dev/null 2>&1; then
    hostpath "$p"
  elif declare -F aws_gate_hp >/dev/null 2>&1; then
    aws_gate_hp "$p"
  elif [[ -n "${TEST_ROOT:-}" ]]; then
    printf '%s%s' "${TEST_ROOT%/}" "$p"
  else
    printf '%s' "$p"
  fi
}

# States that may indicate a completed Focal transition with failed postboot.
aws_pcr_state_is_recovery_candidate() {
  case "${1:-}" in
    FAILED|FAILED_POST_TRANSACTION|FAILED_AFTER_PACKAGE_TRANSITION)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

aws_pcr_os_is_target_focal() {
  local ver code
  if declare -F read_os_field >/dev/null 2>&1; then
    ver="$(read_os_field VERSION_ID 2>/dev/null || true)"
    code="$(read_os_field VERSION_CODENAME 2>/dev/null || true)"
    [[ -z "$code" ]] && code="$(read_os_field UBUNTU_CODENAME 2>/dev/null || true)"
  else
    ver="$(grep -E '^VERSION_ID=' "$(aws_pcr_hp /etc/os-release)" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)"
    code="$(grep -E '^VERSION_CODENAME=' "$(aws_pcr_hp /etc/os-release)" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)"
  fi
  [[ "$ver" == "20.04" && "$code" == "focal" ]]
}

aws_pcr_current_hop_ownership_ok() {
  local hop_file hop src_ver tgt_ver
  hop_file="$(aws_pcr_hp "${CURRENT_HOP_ENV_FILE:-${STATE_ROOT:-/opt/aelladata/os-upgrade/offline}/current-hop.env}")"
  if [[ ! -f "$hop_file" ]]; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=missing_current_hop_env"
    return 1
  fi
  if declare -F read_current_hop_field >/dev/null 2>&1; then
    hop="$(read_current_hop_field CURRENT_HOP 2>/dev/null || true)"
    src_ver="$(read_current_hop_field SOURCE_VERSION_ID 2>/dev/null || true)"
    tgt_ver="$(read_current_hop_field TARGET_VERSION_ID 2>/dev/null || true)"
  else
    hop="$(sed -n 's/^CURRENT_HOP=//p' "$hop_file" 2>/dev/null | head -1)"
    src_ver="$(sed -n 's/^SOURCE_VERSION_ID=//p' "$hop_file" 2>/dev/null | head -1)"
    tgt_ver="$(sed -n 's/^TARGET_VERSION_ID=//p' "$hop_file" 2>/dev/null | head -1)"
  fi
  if [[ "$hop" != "${PIN_HOP:-bionic-to-focal}" ]]; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=current_hop_mismatch hop=${hop:-none} expected=${PIN_HOP:-bionic-to-focal}"
    return 1
  fi
  if [[ -n "$src_ver" && "$src_ver" != "18.04" ]]; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=source_version_mismatch src=${src_ver}"
    return 1
  fi
  if [[ -n "$tgt_ver" && "$tgt_ver" != "20.04" ]]; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=target_version_mismatch tgt=${tgt_ver}"
    return 1
  fi
  return 0
}

aws_pcr_active_upgrade_prohibited() {
  # Return 0 when an active upgrade/reboot/postboot operation blocks recovery mutation.
  local st
  st="${1:-}"
  case "$st" in
    UPGRADING_*|REBOOT_PENDING|REBOOTING|POST_BOOT_VERIFY|CONFIGURING|PREPARING_*|READY_FOR_*)
      return 0
      ;;
  esac
  if declare -F detect_upgrade_already_running >/dev/null 2>&1; then
    if detect_upgrade_already_running; then
      return 0
    fi
  fi
  if pgrep -f 'do-release-upgrade' >/dev/null 2>&1; then
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet stellar-offline-os-upgrade.service 2>/dev/null; then
      return 0
    fi
    if systemctl is-active --quiet stellar-offline-os-upgrade-postboot.service 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

aws_pcr_dpkg_state_ok() {
  local audit
  audit="$(dpkg --audit 2>/dev/null || true)"
  if [[ -n "$(printf '%s' "$audit" | tr -d '[:space:]')" ]]; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=dpkg_audit_dirty"
    return 1
  fi
  if ! apt-get check >/dev/null 2>&1; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=apt_check_failed"
    return 1
  fi
  return 0
}

aws_pcr_sources_are_local_mirror_only() {
  local roots=()
  local f
  roots+=("$(aws_pcr_hp /etc/apt/sources.list)")
  if [[ -d "$(aws_pcr_hp /etc/apt/sources.list.d)" ]]; then
    while IFS= read -r f; do
      roots+=("$f")
    done < <(find "$(aws_pcr_hp /etc/apt/sources.list.d)" -type f \( -name '*.list' -o -name '*.sources' \) 2>/dev/null || true)
  fi
  for f in "${roots[@]}"; do
    [[ -f "$f" ]] || continue
    if grep -qiE '(archive|security|old-releases)\.ubuntu\.com' "$f" 2>/dev/null; then
      aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=external_ubuntu_archive_source file=${f}"
      return 1
    fi
    if grep -qiE 'AllowUnauthenticated|trusted[[:space:]]*=[[:space:]]*yes' "$f" 2>/dev/null; then
      aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=untrusted_source_option file=${f}"
      return 1
    fi
  done
  # Effective sources must reference focal and the pinned hop mirror when MIRROR_BASE is set.
  local blob=""
  for f in "${roots[@]}"; do
    [[ -f "$f" ]] || continue
    blob+="$(cat "$f" 2>/dev/null || true)"$'\n'
  done
  if ! printf '%s' "$blob" | grep -qiE 'focal'; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=focal_suite_absent_from_sources"
    return 1
  fi
  if [[ -n "${MIRROR_BASE:-}" && -n "${PIN_HOP:-}" ]]; then
    if ! printf '%s' "$blob" | grep -Fq "${MIRROR_BASE}/hops/${PIN_HOP}/"; then
      aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=expected_hop_mirror_absent"
      return 1
    fi
  fi
  return 0
}

aws_pcr_package_closure_incomplete() {
  # Return 0 when linux-aws / linux-image-aws closure is incomplete vs Focal contract.
  local target_ver="${1:-20.04}"
  local cur_aws cur_img
  if ! declare -F aws_contract_available_for_version >/dev/null 2>&1; then
    return 1
  fi
  if ! aws_contract_available_for_version "$target_ver"; then
    return 1
  fi
  if ! declare -F aws_pkg_installed >/dev/null 2>&1; then
    return 1
  fi
  if ! aws_pkg_installed linux-aws; then
    return 0
  fi
  if ! aws_pkg_installed linux-image-aws; then
    return 0
  fi
  cur_aws="$(aws_pkg_version linux-aws)"
  cur_img="$(aws_pkg_version linux-image-aws)"
  if ! aws_versions_equal "$cur_aws" "$AWS_C_LINUX_AWS_VERSION"; then
    return 0
  fi
  if ! aws_versions_equal "$cur_img" "$AWS_C_LINUX_IMAGE_AWS_VERSION"; then
    return 0
  fi
  return 1
}

aws_pcr_running_kernel_ok_for_recovery() {
  # Running kernel must already be an acceptable Focal AWS contract release.
  # A non-contract / non-aws kernel indicates partial transition, not meta-closure only.
  local target_ver="${1:-20.04}" kr
  if ! aws_contract_available_for_version "$target_ver"; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=missing_target_hop_contract"
    return 1
  fi
  kr="$(aws_running_kernel_release)"
  case "$kr" in
    *-aws) ;;
    *)
      aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=running_kernel_not_aws kernel=${kr}"
      return 1
      ;;
  esac
  if ! aws_kernel_release_in_contract "$kr"; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=running_kernel_not_target_contract_release expected=${AWS_C_KERNEL_RELEASES} kernel=${kr}"
    return 1
  fi
  return 0
}

aws_pcr_classify_recovery_required() {
  # Echo YES/NO. Return 0 always (classification). Fail-closed gates run later.
  local st="${1:-}"
  local profile

  if [[ "$st" == "COMPLETED_FOCAL" ]]; then
    printf 'NO\n'
    return 0
  fi
  if ! aws_pcr_os_is_target_focal; then
    printf 'NO\n'
    return 0
  fi
  if ! aws_pcr_state_is_recovery_candidate "$st"; then
    printf 'NO\n'
    return 0
  fi
  if ! declare -F detect_aws_upgrade_profile >/dev/null 2>&1; then
    printf 'NO\n'
    return 0
  fi
  profile="$(detect_aws_upgrade_profile 2>/dev/null || true)"
  if [[ "$profile" != "aws" ]]; then
    aws_pcr_log INFO "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=SKIP reason=non_aws_profile"
    printf 'NO\n'
    return 0
  fi
  if ! aws_pcr_package_closure_incomplete "20.04"; then
    aws_pcr_log INFO "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=SKIP reason=package_closure_complete"
    printf 'NO\n'
    return 0
  fi
  printf 'YES\n'
  return 0
}

aws_pcr_refresh_managed_keyring() {
  # Install/replace only the product-owned per-hop keyring using the client pin.
  local work src dest dir tmpf fpr installed_fpr admin_keyring own_work=0
  work="${1:-}"
  if [[ -z "$work" ]]; then
    work="$(mktemp -d /tmp/stellar-aws-pcr-key.XXXXXX)"
    own_work=1
  fi
  src="${work}/stellar-offline-upgrade.gpg"
  if [[ ! -f "$src" ]]; then
  if [[ -z "${PIN_KEY_B64:-}" ]]; then
      aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=embedded_key_missing"
      [[ "$own_work" -eq 1 ]] && rm -rf "$work"
      return 1
    fi
    if declare -F b64_decode_to_file >/dev/null 2>&1; then
      b64_decode_to_file "$PIN_KEY_B64" "$src" || {
        [[ "$own_work" -eq 1 ]] && rm -rf "$work"
        return 1
      }
    else
      printf '%s' "$PIN_KEY_B64" | base64 -d >"$src" || {
        [[ "$own_work" -eq 1 ]] && rm -rf "$work"
        return 1
      }
    fi
  fi

  fpr="$(gpg --no-default-keyring --keyring "$src" --with-colons --fingerprint 2>/dev/null \
    | awk -F: '/^fpr:/ {print $10; exit}' || true)"
  fpr="$(printf '%s' "$fpr" | tr '[:lower:]' '[:upper:]')"
  aws_pcr_log INFO "AWS_PCR_EMBEDDED_KEY_FINGERPRINT=${fpr:-none}"
  aws_pcr_log INFO "AWS_PCR_PINNED_KEY_FINGERPRINT=${PIN_KEY_FINGERPRINT:-none}"
  if [[ -z "$fpr" || -z "${PIN_KEY_FINGERPRINT:-}" || "$fpr" != "$PIN_KEY_FINGERPRINT" ]]; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=embedded_key_fingerprint_mismatch"
    aws_pcr_log INFO "AWS_PCR_KEY_FINGERPRINT_MATCH=FAIL"
    [[ "$own_work" -eq 1 ]] && rm -rf "$work"
    return 1
  fi
  aws_pcr_log INFO "AWS_PCR_KEY_FINGERPRINT_MATCH=PASS"

  dir="$(aws_pcr_hp /etc/apt/trusted.gpg.d)"
  dest="$(aws_pcr_hp "${LEGACY_APT_KEYRING_PATH:-/etc/apt/trusted.gpg.d/stellar-offline-bionic-to-focal.gpg}")"
  mkdir -p "$dir"
  chmod 0755 "$dir"

  # Never touch unrelated administrator trust material.
  admin_keyring="$(aws_pcr_hp /etc/apt/trusted.gpg)"
  if [[ -f "$admin_keyring" ]]; then
    aws_pcr_log INFO "AWS_PCR_ADMIN_TRUSTED_GPG_UNTOUCHED=YES path=${admin_keyring}"
  fi

  tmpf="${dest}.tmp.$$"
  if grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$src" 2>/dev/null; then
    gpg --dearmor <"$src" >"$tmpf" || {
      rm -f "$tmpf"
      aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=keyring_dearmor_failed"
      [[ "$own_work" -eq 1 ]] && rm -rf "$work"
      return 1
    }
  else
    cp -f "$src" "$tmpf" || {
      rm -f "$tmpf"
      [[ "$own_work" -eq 1 ]] && rm -rf "$work"
      return 1
    }
  fi
  chmod 0644 "$tmpf"
  mv -f "$tmpf" "$dest" || {
    [[ "$own_work" -eq 1 ]] && rm -rf "$work"
    return 1
  }
  chown root:root "$dest" 2>/dev/null || true

  installed_fpr="$(gpg --no-default-keyring --keyring "$dest" --with-colons --fingerprint 2>/dev/null \
    | awk -F: '/^fpr:/ {print $10; exit}' || true)"
  installed_fpr="$(printf '%s' "$installed_fpr" | tr '[:lower:]' '[:upper:]')"
  if [[ -z "$installed_fpr" || "$installed_fpr" != "$PIN_KEY_FINGERPRINT" ]]; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=keyring_postinstall_mismatch"
    [[ "$own_work" -eq 1 ]] && rm -rf "$work"
    return 1
  fi
  aws_pcr_log INFO "AWS_PCR_MANAGED_KEYRING_REFRESH=PASS path=${LEGACY_APT_KEYRING_PATH:-$dest}"
  [[ "$own_work" -eq 1 ]] && rm -rf "$work"
  return 0
}

aws_pcr_refresh_apt_indexes() {
  if ! apt-get update >/dev/null 2>&1; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=apt_update_failed"
    return 1
  fi
  aws_pcr_log INFO "AWS_PCR_APT_UPDATE=PASS"
  return 0
}

aws_pcr_candidate_from_expected_mirror() {
  local pkg="$1"
  local policy cand
  policy="$(apt-cache policy "$pkg" 2>/dev/null || true)"
  cand="$(printf '%s\n' "$policy" | awk '/Candidate:/ {print $2; exit}')"
  if [[ -z "$cand" || "$cand" == "(none)" ]]; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=candidate_absent pkg=${pkg}"
    return 1
  fi
  aws_pcr_log INFO "AWS_PCR_CANDIDATE_${pkg}=${cand}"
  if [[ -n "${MIRROR_BASE:-}" && -n "${PIN_HOP:-}" ]]; then
    if ! printf '%s\n' "$policy" | grep -Fq "${MIRROR_BASE}/hops/${PIN_HOP}/"; then
      aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=candidate_not_from_hop_mirror pkg=${pkg}"
      return 1
    fi
  fi
  if printf '%s\n' "$policy" | grep -qiE '(archive|security|old-releases)\.ubuntu\.com'; then
    # Presence of external lines in the Version table is fail-closed for this recovery.
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=candidate_policy_lists_external_archive pkg=${pkg}"
    return 1
  fi
  return 0
}

# Required dependency field chain for Focal AWS meta closure on selective mirrors.
AWS_PCR_REQUIRED_SIM_PACKAGES=(
  linux-aws
  linux-image-aws
  microcode-initrd
  intel-microcode
  iucode-tool
)

aws_pcr_simulate_package_closure() {
  local sim_out sim_err rc pkg
  sim_out="$(mktemp /tmp/stellar-aws-pcr-sim.XXXXXX)"
  sim_err="$(mktemp /tmp/stellar-aws-pcr-sim.XXXXXX)"
  set +e
  DEBIAN_FRONTEND=noninteractive apt-get -s -y install linux-aws linux-image-aws \
    >"$sim_out" 2>"$sim_err"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=dependency_simulation_failed rc=${rc}"
    aws_pcr_log ERROR "AWS_KERNEL_DEPENDENCY_SIMULATION=FAIL"
    cat "$sim_err" >&2 || true
    rm -f "$sim_out" "$sim_err"
    return 1
  fi
  # Simulation must not remove packages or pull from unexpected upgrade paths.
  if grep -Eiq '^Remv ' "$sim_out" 2>/dev/null; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=simulation_would_remove_packages"
    rm -f "$sim_out" "$sim_err"
    return 1
  fi
  for pkg in "${AWS_PCR_REQUIRED_SIM_PACKAGES[@]}"; do
    if ! grep -Eq "^Inst ${pkg} |^Inst ${pkg}$" "$sim_out" \
      && ! grep -Eq " ${pkg} " "$sim_out"; then
      # Already installed packages may be omitted from Inst lines; require either
      # Inst mention or an installed/up-to-date note for the chain roots.
      case "$pkg" in
        linux-aws|linux-image-aws)
          if ! grep -Eq "^Inst ${pkg}" "$sim_out"; then
            # If already at candidate, apt -s may say 0 upgraded; still require
            # the package name appear when closure is incomplete.
            if ! grep -Fq "$pkg" "$sim_out"; then
              aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=simulation_missing_pkg pkg=${pkg}"
              aws_pcr_log ERROR "B2F_DEPENDENCY_CLOSURE=FAIL"
              rm -f "$sim_out" "$sim_err"
              return 1
            fi
          fi
          ;;
        iucode-tool|intel-microcode|microcode-initrd)
          if ! grep -Fq "$pkg" "$sim_out"; then
            aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=simulation_missing_dependency pkg=${pkg}"
            aws_pcr_log ERROR "B2F_DEPENDENCY_CLOSURE=FAIL"
            rm -f "$sim_out" "$sim_err"
            return 1
          fi
          ;;
      esac
    fi
  done
  aws_pcr_log INFO "AWS_KERNEL_DEPENDENCY_SIMULATION=PASS"
  aws_pcr_log INFO "B2F_DEPENDENCY_CLOSURE=PASS"
  aws_pcr_log INFO "AWS_PCR_DEPENDENCY_FIELD_CHAIN=linux-aws->linux-image-aws->microcode-initrd->intel-microcode->iucode-tool"
  rm -f "$sim_out" "$sim_err"
  return 0
}

aws_pcr_install_package_closure() {
  local rc
  aws_pcr_log INFO "AWS_PCR_PACKAGE_REPAIR=START pkgs=linux-aws,linux-image-aws"
  set +e
  DEBIAN_FRONTEND=noninteractive apt-get install -y linux-aws linux-image-aws
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=package_install_failed rc=${rc}"
    return 1
  fi
  aws_pcr_log INFO "AWS_PCR_PACKAGE_REPAIR=PASS"
  return 0
}

# Orchestrator for Focal re-entry.
# Return 0: recovery not applicable, or repair applied (caller must run postboot).
# Non-zero / die: recovery required but a gate failed (fail closed).
try_aws_postboot_package_closure_recovery() {
  local st="${1:-}"
  local required work ec_trust ec_state

  ec_trust="${EC_TRUST:-19}"
  ec_state="${EC_STATE:-23}"

  required="$(aws_pcr_classify_recovery_required "$st" | tr -d '\r\n')"
  if [[ "$required" != "YES" ]]; then
    aws_pcr_log INFO "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY_REQUIRED=NO"
    return 0
  fi
  aws_pcr_log INFO "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY_REQUIRED=YES"

  if ! aws_pcr_current_hop_ownership_ok; then
    aws_pcr_die "$ec_state" "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=ambiguous_or_unowned_current_hop"
  fi
  if aws_pcr_active_upgrade_prohibited "$st"; then
    aws_pcr_log ERROR "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=active_upgrade_or_reboot_or_postboot"
    aws_pcr_die "$ec_state" "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=active_upgrade"
  fi
  if ! aws_pcr_running_kernel_ok_for_recovery "20.04"; then
    aws_pcr_die "$ec_state" "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=kernel_inconsistent_with_package_closure_only"
  fi
  if ! aws_pcr_dpkg_state_ok; then
    aws_pcr_die "$ec_state" "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=dpkg_or_apt_ambiguous"
  fi
  if ! aws_pcr_sources_are_local_mirror_only; then
    aws_pcr_die "$ec_trust" "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=REFUSED reason=unsafe_or_external_sources"
  fi

  work="$(mktemp -d /tmp/stellar-aws-pcr.XXXXXX)"

  if ! aws_pcr_refresh_managed_keyring "$work"; then
    rm -rf "$work"
    aws_pcr_die "$ec_trust" "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=managed_keyring_refresh"
  fi
  if ! aws_pcr_refresh_apt_indexes; then
    rm -rf "$work"
    aws_pcr_die "$ec_trust" "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=apt_index_refresh"
  fi
  if ! aws_pcr_candidate_from_expected_mirror linux-aws; then
    rm -rf "$work"
    aws_pcr_die "$ec_trust" "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=linux-aws_candidate"
  fi
  if ! aws_pcr_candidate_from_expected_mirror linux-image-aws; then
    rm -rf "$work"
    aws_pcr_die "$ec_trust" "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=linux-image-aws_candidate"
  fi
  if ! aws_pcr_simulate_package_closure; then
    rm -rf "$work"
    aws_pcr_die "$ec_state" "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=dependency_simulation"
  fi
  if ! aws_pcr_install_package_closure; then
    rm -rf "$work"
    aws_pcr_die "$ec_state" "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=FAIL reason=package_repair"
  fi
  rm -rf "$work"

  aws_pcr_log INFO "AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=PASS"
  aws_pcr_log INFO "AWS_PCR_NEXT=invoke_authoritative_postboot_validator"
  # Intentionally do NOT write COMPLETED_FOCAL here.
  return 0
}
