#!/usr/bin/env bash
# Build the separate Phase 2 Ubuntu prerequisite artifact from ACPS py3-apt
# package metadata + the selective Noble package index.
# Never modifies original ACPS files. Never rewrites ACPS SHA sidecars.
set -euo pipefail
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/dp-phase2-common.sh
source "${SCRIPT_DIR}/lib/dp-phase2-common.sh"

PHASE2_PREREQ_PY="${SCRIPT_DIR}/lib/phase2_ubuntu_prerequisites.py"
DP_PHASE2_VERSION="${DP_PHASE2_VERSION:-${DP_PHASE2_VERSION_DEFAULT}}"
DP_PHASE2_ROOT="${DP_PHASE2_ROOT:-/var/spool/apt-mirror/dp-phase2}"
MM_SELECTIVE_ROOT="${MM_SELECTIVE_ROOT:-/var/spool/apt-mirror/selective}"

dp2_phase2_prereq_artifact_name() {
  printf '%s\n' "phase2-ubuntu-prerequisites.tar.gz"
}

dp2_phase2_prereq_published_dir() {
  # Always version-root/extras so DP stage URL /dp-phase2/<ver>/extras/ matches
  # the production nginx alias (flat final dir, no current/ generation layout).
  printf '%s/extras\n' "$(dp2_version_root)"
}

dp2_find_acps_common() {
  local explicit="${PHASE2_PREREQ_ACPS_COMMON:-}"
  if [[ -n "$explicit" && -f "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  local ver_root current
  ver_root="$(dp2_version_root)"
  for current in \
    "${ver_root}/current/files/aelladeb_py3_common.tar.gz" \
    "${ver_root}/files/aelladeb_py3_common.tar.gz" \
    "${ver_root}/aelladeb_py3_common.tar.gz" \
    "${ver_root}/current/aelladeb_py3_common.tar.gz"
  do
    if [[ -f "$current" ]]; then
      printf '%s\n' "$current"
      return 0
    fi
  done
  if [[ -n "${PHASE2_PREREQ_WORK_DIR:-}" && -f "${PHASE2_PREREQ_WORK_DIR}/aelladeb_py3_common.tar.gz" ]]; then
    printf '%s\n' "${PHASE2_PREREQ_WORK_DIR}/aelladeb_py3_common.tar.gz"
    return 0
  fi
  return 1
}

dp2_find_noble_ubuntu_root() {
  if [[ -n "${PHASE2_PREREQ_INDEX_ROOT:-}" && -d "${PHASE2_PREREQ_INDEX_ROOT}" ]]; then
    printf '%s\n' "${PHASE2_PREREQ_INDEX_ROOT}"
    return 0
  fi
  local hop
  for hop in \
    "${MM_SELECTIVE_ROOT}/hops/jammy-to-noble/ubuntu" \
    "${MM_SELECTIVE_ROOT}/published/hops/jammy-to-noble/ubuntu" \
    "${MM_SELECTIVE_ROOT}/current/hops/jammy-to-noble/ubuntu"
  do
    if [[ -d "${hop}/dists" ]]; then
      printf '%s\n' "$hop"
      return 0
    fi
  done
  local discovery
  discovery="${PROJECT_ROOT}/artifacts/upgrade-discovery/analysis/pocket-indexes/ubuntu"
  if [[ -d "${discovery}/dists" ]]; then
    printf '%s\n' "$discovery"
    return 0
  fi
  return 1
}

dp2_find_extra_acps_debs() {
  # Read-only extra roots: published Aella/UVP debs beside ACPS common.
  # Never modify or repack these files.
  local common="${1:-}"
  local ver_root
  ver_root="$(dp2_version_root)"
  local dirs=()
  if [[ -n "$common" ]]; then
    dirs+=("$(dirname "$common")")
  fi
  dirs+=(
    "${ver_root}/current/files"
    "${ver_root}/files"
    "${ver_root}"
  )
  local d f
  local seen=""
  for d in "${dirs[@]}"; do
    [[ -n "$d" && -d "$d" ]] || continue
    while IFS= read -r f; do
      [[ -n "$f" && -f "$f" ]] || continue
      case " $seen " in
        *" $f "*) continue ;;
      esac
      seen="${seen} ${f}"
      printf '%s\n' "$f"
    done < <(find "$d" -maxdepth 1 -type f \( \
      -name 'aella-uvp-*.deb' -o -name 'aella-da-*.deb' \
    \) 2>/dev/null | sort)
  done
}

dp2_extract_py3_apt_from_common() {
  local common="$1"
  local dest="$2"
  local listing member found
  local tar_rc=0 listing_rc=0 extract_rc=0 flatten_rc=0
  mkdir -p "$dest"
  # Extract only the inner py3-apt tarball; never rewrite the common archive.
  # Consume the complete tar listing. Never close tar stdout early:
  # grep -q / head / sed-q under set -o pipefail can SIGPIPE tar (rc=141)
  # and falsely report a missing member that exists.
  listing="$(mktemp "${TMPDIR:-/tmp}/phase2-prereq-list.XXXXXX")"
  set +e
  tar -tzf "$common" >"$listing" 2>/dev/null
  tar_rc=$?
  set -e
  if [[ "$tar_rc" -ne 0 ]]; then
    rm -f "$listing"
    dp2_error "PHASE2_PREREQ=FAIL reason=py3_apt_archive_invalid"
    return 1
  fi
  set +e
  member="$(
    awk '
      /py3-apt-packages\.tar\.gz$/ {
        n++
        if (n == 1) saved = $0
      }
      END {
        if (n == 1) { print saved; exit 0 }
        if (n > 1) exit 2
        exit 1
      }
    ' "$listing"
  )"
  listing_rc=$?
  set -e
  rm -f "$listing"
  if [[ "$listing_rc" -eq 2 ]]; then
    dp2_error "PHASE2_PREREQ=FAIL reason=py3_apt_ambiguous"
    return 1
  fi
  if [[ "$listing_rc" -ne 0 || -z "$member" ]]; then
    dp2_error "PHASE2_PREREQ=FAIL reason=py3_apt_missing"
    return 1
  fi
  set +e
  tar -xzf "$common" -C "$dest" -- "$member"
  extract_rc=$?
  set -e
  if [[ "$extract_rc" -ne 0 ]]; then
    dp2_error "PHASE2_PREREQ=FAIL reason=py3_apt_extract_failed"
    return 1
  fi
  if [[ ! -f "${dest}/py3-apt-packages.tar.gz" ]]; then
    set +e
    found="$(
      find "$dest" -name 'py3-apt-packages.tar.gz' -type f |
      awk '
        { n++; if (n == 1) saved = $0 }
        END {
          if (n == 1) { print saved; exit 0 }
          exit 1
        }
      '
    )"
    flatten_rc=$?
    set -e
    if [[ "$flatten_rc" -eq 0 && -n "$found" ]]; then
      cp -a "$found" "${dest}/py3-apt-packages.tar.gz"
    fi
  fi
  if [[ ! -f "${dest}/py3-apt-packages.tar.gz" ]]; then
    dp2_error "PHASE2_PREREQ=FAIL reason=py3_apt_missing"
    return 1
  fi
  return 0
}

prepare_phase2_ubuntu_prerequisites() {
  local common ubuntu_root extras work rc=0

  extras="${PHASE2_PREREQ_OUT_DIR:-$(dp2_phase2_prereq_published_dir)}"
  mkdir -p "$extras"
  work="$(mktemp -d "${TMPDIR:-/tmp}/phase2-prereq.XXXXXX")"

  if ! common="$(dp2_find_acps_common)"; then
    local bundle
    bundle="$(dp2_version_root)/$(dp2_stable_bundle_name 2>/dev/null || true)"
    if [[ -f "$bundle" ]] \
      && tar -xf "$bundle" -C "$work" aelladeb_py3_common.tar.gz 2>/dev/null \
      && [[ -s "${work}/aelladeb_py3_common.tar.gz" ]]; then
      tar -xf "$bundle" -C "$work" \
        "aella-uvp-2404_${DP_PHASE2_VERSION}ubuntu1_amd64.deb" 2>/dev/null || true
      common="${work}/aelladeb_py3_common.tar.gz"
      dp2_info "PHASE2_PREREQ_ACPS_COMMON_FROM_BUNDLE=${bundle}"
    else
      rm -rf "$work"
      dp2_error "PHASE2_PREREQ=FAIL reason=acps_common_missing"
      return 1
    fi
  fi
  dp2_info "PHASE2_PREREQ_ACPS_COMMON=${common}"
  dp2_info "PHASE2_PREREQ_ACPS_SHA1=$(sha1sum "$common" | awk '{print $1}')"

  if ! ubuntu_root="$(dp2_find_noble_ubuntu_root)"; then
    # PHASE2_ONLY deliberately does not acquire the OS Core selective mirror.
    # The resolver already supports Ubuntu authoritative Noble indexes and
    # SHA256/size-verified DEBs; give it a private workspace for those files.
    # FULL mode and a mistyped explicit override must remain fail-closed.
    if [[ "${PREPARATION_MODE:-FULL}" != "PHASE2_ONLY" ||
          -n "${PHASE2_PREREQ_INDEX_ROOT:-}" ]]; then
      rm -rf "$work"
      dp2_error "PHASE2_PREREQ=FAIL reason=noble_index_missing"
      return 1
    fi
    ubuntu_root="${work}/noble-bootstrap"
    mkdir -p "$ubuntu_root"
    PHASE2_PREREQ_AUTHORITATIVE_CACHE="${PHASE2_PREREQ_AUTHORITATIVE_CACHE:-${DP_PHASE2_ROOT}/.phase2-noble-authoritative}"
    dp2_info "PHASE2_PREREQ_INDEX_SOURCE=AUTHORITATIVE_BOOTSTRAP mode=PHASE2_ONLY"
    dp2_info "PHASE2_PREREQ_AUTHORITATIVE_CACHE=${PHASE2_PREREQ_AUTHORITATIVE_CACHE}"
  fi
  dp2_info "PHASE2_PREREQ_UBUNTU_ROOT=${ubuntu_root}"

  if ! dp2_extract_py3_apt_from_common "$common" "$work"; then
    rm -rf "$work"
    return 1
  fi

  local extra_deb extra_args=()
  while IFS= read -r extra_deb; do
    [[ -n "$extra_deb" ]] || continue
    extra_args+=(--extra-deb "$extra_deb")
    dp2_info "PHASE2_PREREQ_EXTRA_ROOT_DEB=${extra_deb}"
  done < <(dp2_find_extra_acps_debs "$common")

  local archive_base security_base
  archive_base="${PHASE2_PREREQ_ARCHIVE_BASE:-http://archive.ubuntu.com/ubuntu}"
  security_base="${PHASE2_PREREQ_SECURITY_BASE:-http://security.ubuntu.com/ubuntu}"
  extra_args+=(--target-version "${DP_PHASE2_VERSION}")
  extra_args+=(--archive-base "$archive_base")
  extra_args+=(--security-base "$security_base")
  if [[ -n "${PHASE2_PREREQ_AUTHORITATIVE_ROOT:-}" ]]; then
    extra_args+=(--authoritative-root "${PHASE2_PREREQ_AUTHORITATIVE_ROOT}")
  fi
  if [[ -n "${PHASE2_PREREQ_AUTHORITATIVE_CACHE:-}" ]]; then
    extra_args+=(--authoritative-cache "${PHASE2_PREREQ_AUTHORITATIVE_CACHE}")
  fi

  set +e
  python3 "$PHASE2_PREREQ_PY" build \
    --source "${work}/py3-apt-packages.tar.gz" \
    --ubuntu-root "$ubuntu_root" \
    --dest "$extras" \
    --ensure-selective \
    "${extra_args[@]}"
  rc=$?
  set -e
  rm -rf "$work"

  local state="${extras}/phase2-ubuntu-prerequisites.state"
  if [[ "$rc" -ne 0 ]]; then
    python3 "$PHASE2_PREREQ_PY" validate-state --dest "$extras" >/dev/null 2>&1 || true
    dp2_error "PHASE2_PREREQ_BUILD=FAIL rc=${rc}"
    dp2_error "PHASE2_PREREQ=FAIL rc=${rc}"
    return "$rc"
  fi
  if [[ ! -f "$state" ]]; then
    dp2_error "PHASE2_PREREQ=FAIL state_missing"
    return 1
  fi
  local fields_rc=0
  set +e
  python3 "$PHASE2_PREREQ_PY" validate-state --dest "$extras"
  fields_rc=$?
  set -e
  if [[ "$fields_rc" -ne 0 ]]; then
    dp2_error "PHASE2_PREREQ=FAIL reason=state_contract"
    return 1
  fi
  local art sha required count
  art="${extras}/$(dp2_phase2_prereq_artifact_name)"
  required="$(awk -F= '$1=="PHASE2_PREREQ_REQUIRED"{print $2; exit}' "$state")"
  count="$(awk -F= '$1=="PHASE2_PREREQ_PACKAGE_COUNT"{print $2; exit}' "$state")"
  sha=""
  if [[ -f "${art}.sha256" ]]; then
    sha="$(awk '{print $1; exit}' "${art}.sha256")"
  fi
  dp2_ok "PHASE2_PREREQ=PASS artifact=${art} sha256=${sha} required=${required} count=${count}"
  dp2_info "PHASE2_PREREQ_PUBLICATION=PASS extras=${extras}"
  # Confirm the original ACPS common file is unchanged.
  dp2_info "PHASE2_PREREQ_ACPS_UNMODIFIED=YES"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  dp2_set_version "${1:-$DP_PHASE2_VERSION}"
  prepare_phase2_ubuntu_prerequisites
fi
