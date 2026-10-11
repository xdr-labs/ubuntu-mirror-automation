#!/usr/bin/env bash
# scripts/lib/dp-os-upgrade-artifacts.sh — Phase 1 discovery artifact capture/export
# Sourced by dp-os-upgrade-common.sh. Bash 4.3+ / Ubuntu 16.04 compatible.
# shellcheck disable=SC2034,SC2155

osu_should_capture_artifacts() {
  return 0
}

osu_write_apt_preserve_config() {
  # Xenial-safe keep-downloads hints; never automatic APT cache purge from orchestrator.
  local dest confd
  confd="$(osu_hostpath /etc/apt/apt.conf.d)"
  mkdir -p "$confd"
  dest="${confd}/99dp-os-upgrade-keep-downloads"
  {
    printf '// Managed by dp-os-upgrade — preserve downloaded packages for discovery evidence\n'
    printf 'Binary::apt::APT::Keep-Downloaded-Packages "true";\n'
    printf 'APT::Keep-Downloaded-Packages "true";\n'
  } >"$dest" 2>/dev/null || true
}

osu_capture_package_inventory() {
  local out="$1"
  mkdir -p "$(dirname "$out")"
  if command -v dpkg-query >/dev/null 2>&1; then
    {
      printf 'package\tversion\tarchitecture\tstatus\n'
      dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\t${Status}\n' 2>/dev/null || true
    } >"$out"
  elif [[ -f "$(osu_hostpath /tmp/package-list.tsv)" ]]; then
    cp -a "$(osu_hostpath /tmp/package-list.tsv)" "$out"
  else
    printf 'package\tversion\tarchitecture\tstatus\n' >"$out"
  fi
}

osu_capture_python_inventory() {
  local outdir="$1"
  mkdir -p "$outdir"
  {
    printf 'INFORMATIONAL:\n'
    printf 'Python/DP application compatibility is not part of Phase 1 validation.\n'
    printf 'A separate Phase 2 bringup is required after Ubuntu 24.04.\n\n'
    local cmd
    for cmd in python python2 python3; do
      if command -v "$cmd" >/dev/null 2>&1; then
        printf '%s: ' "$cmd"
        "$cmd" --version 2>&1 || true
        printf 'path: %s\n' "$(command -v "$cmd")"
      else
        printf '%s: not_found\n' "$cmd"
      fi
    done
    for cmd in pip pip2 pip3; do
      if command -v "$cmd" >/dev/null 2>&1; then
        printf '%s: present (%s)\n' "$cmd" "$(command -v "$cmd")"
      else
        printf '%s: not_found\n' "$cmd"
      fi
    done
    if command -v dpkg-query >/dev/null 2>&1; then
      printf '\n# python-related debian packages\n'
      dpkg-query -W -f='${Package}\t${Version}\n' 'python*' 2>/dev/null || true
    fi
  } >"${outdir}/inventory.txt"
  if command -v pip3 >/dev/null 2>&1; then
    pip3 freeze >"${outdir}/pip3-freeze.txt" 2>/dev/null || printf 'pip3 freeze unavailable\n' >"${outdir}/pip3-freeze.txt"
  fi
}

osu_capture_file_manifest() {
  local out="$1"
  local roots=(/etc /boot /lib/systemd/system /etc/systemd/system /usr/lib/systemd/system /etc/apt)
  mkdir -p "$(dirname "$out")"
  {
    printf 'relative_path\tfile_type\tsize_bytes\tmtime_epoch\tmode\tuid\tgid\tsha256_if_small_or_critical\tsymlink_target\n'
    local r hp p rel typ size mtime mode uid gid sha target
    for r in "${roots[@]}"; do
      hp="$(osu_hostpath "$r")"
      [[ -e "$hp" ]] || continue
      while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        rel="${p#"$(osu_hostpath /)"}"
        rel="${rel#/}"
        target=""
        if [[ -L "$p" ]]; then
          typ="symlink"
          target="$(readlink "$p" 2>/dev/null || true)"
          size=0
        elif [[ -d "$p" ]]; then
          typ="dir"
          size=0
        else
          typ="file"
          size="$(stat -c '%s' "$p" 2>/dev/null || echo 0)"
        fi
        mtime="$(stat -c '%Y' "$p" 2>/dev/null || echo 0)"
        mode="$(stat -c '%a' "$p" 2>/dev/null || echo '')"
        uid="$(stat -c '%u' "$p" 2>/dev/null || echo '')"
        gid="$(stat -c '%g' "$p" 2>/dev/null || echo '')"
        sha=""
        if [[ "$typ" == "file" ]]; then
          case "$rel" in
            etc/passwd|etc/group|etc/hostname|etc/hosts|etc/ssh/sshd_config|boot/grub/*|etc/default/grub|etc/apt/*|opt/aelladata/cluster-name|opt/aelladata/release-*.yml)
              [[ "${size:-0}" -le 1048576 ]] && sha="$(osu_sha256_file "$p" 2>/dev/null || true)"
              ;;
            *)
              [[ "${size:-0}" -le 262144 ]] && sha="$(osu_sha256_file "$p" 2>/dev/null || true)"
              ;;
          esac
        fi
        case "$rel" in
          *id_rsa*|*id_ed25519*|*.pem|*shadow*|*password*) sha="REDACTED" ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$typ" "$size" "$mtime" "$mode" "$uid" "$gid" "$sha" "$target"
      done < <(find "$hp" -xdev \( -type f -o -type l -o -type d \) 2>/dev/null | head -n 5000)
    done
  } >"$out"
}

osu_diff_package_inventories() {
  local before="$1" after="$2" out="$3"
  {
    printf 'package\tchange_type\tversion_before\tversion_after\n'
    if command -v python3 >/dev/null 2>&1 && [[ -f "$before" && -f "$after" ]]; then
      python3 - "$before" "$after" <<'PY'
import sys
def load(path):
    d={}
    with open(path) as f:
        next(f, None)
        for line in f:
            p=line.rstrip('\n').split('\t')
            if len(p) >= 2:
                d[p[0]] = p[1]
    return d
b, a = load(sys.argv[1]), load(sys.argv[2])
for pkg in sorted(set(b) | set(a)):
    if pkg not in b:
        print(f"{pkg}\tADDED\t\t{a[pkg]}")
    elif pkg not in a:
        print(f"{pkg}\tREMOVED\t{b[pkg]}\t")
    elif b[pkg] != a[pkg]:
        print(f"{pkg}\tUPGRADED\t{b[pkg]}\t{a[pkg]}")
PY
    fi
  } >"$out"
}

osu_diff_file_manifests() {
  local before="$1" after="$2" out="$3"
  {
    printf 'relative_path\tchange_type\n'
    if command -v python3 >/dev/null 2>&1 && [[ -f "$before" && -f "$after" ]]; then
      python3 - "$before" "$after" <<'PY'
import sys
def load(path):
    d={}
    with open(path) as f:
        next(f, None)
        for line in f:
            p=line.rstrip('\n').split('\t')
            if p and p[0]:
                d[p[0]] = p
    return d
b, a = load(sys.argv[1]), load(sys.argv[2])
for rel in sorted(set(b) | set(a)):
    if rel not in b:
        print(f"{rel}\tADDED")
    elif rel not in a:
        print(f"{rel}\tREMOVED")
    elif b[rel] != a[rel]:
        if len(b[rel]) > 7 and len(a[rel]) > 7 and b[rel][7] != a[rel][7] and (b[rel][7] or a[rel][7]):
            print(f"{rel}\tMODIFIED")
        else:
            print(f"{rel}\tMETADATA_CHANGED")
PY
    fi
  } >"$out"
}

osu_copy_apt_archives() {
  local dest="$1"
  mkdir -p "$dest"
  local src copied=0 failed=0 f base
  src="$(osu_hostpath /var/cache/apt/archives)"
  if [[ ! -d "$src" ]]; then
    printf 'no_apt_archives_dir\n' >"${dest}/copy-status.txt"
    return 0
  fi
  shopt -s nullglob
  for f in "$src"/*.deb; do
    base="$(basename "$f")"
    if cp -a "$f" "${dest}/${base}" 2>/dev/null; then
      osu_sha256_file "${dest}/${base}" >"${dest}/${base}.sha256" 2>/dev/null || true
      copied=$((copied + 1))
    else
      failed=$((failed + 1))
    fi
  done
  shopt -u nullglob
  printf 'copied=%s failed=%s\n' "$copied" "$failed" >"${dest}/copy-status.txt"
  if [[ "$failed" -gt 0 ]]; then
    osu_log WARN "apt archive copy had ${failed} failures"
    return 1
  fi
  return 0
}

osu_build_package_manifest_tsv() {
  local packages_dir="$1" out="$2"
  {
    printf 'package\tversion\tarchitecture\tfilename\tsize_bytes\tsha256\tsource_uri\tsource_pocket\tdownload_evidence\tinstalled_before\tinstalled_after\tchange_type\tevidence_source\tconfidence\n'
    local f base pkg ver arch size sha
    shopt -s nullglob
    for f in "$packages_dir"/*.deb; do
      base="$(basename "$f")"
      size="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
      sha="$(osu_sha256_file "$f" 2>/dev/null || echo unknown)"
      pkg=""; ver=""; arch=""
      if command -v dpkg-deb >/dev/null 2>&1; then
        pkg="$(dpkg-deb -f "$f" Package 2>/dev/null || true)"
        ver="$(dpkg-deb -f "$f" Version 2>/dev/null || true)"
        arch="$(dpkg-deb -f "$f" Architecture 2>/dev/null || true)"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${pkg:-unknown}" "${ver:-unknown}" "${arch:-unknown}" "$base" "$size" "$sha" \
        "unknown" "unknown" "apt-archives-copy" "unknown" "unknown" "unknown" "apt_cache_copy" "medium"
    done
    shopt -u nullglob
  } >"$out"
}

osu_capture_hop_artifacts() {
  local hop_dir="$1" phase="$2"
  osu_should_capture_artifacts || return 0
  local art="${hop_dir}/discovery-artifacts"
  mkdir -p "$art"/{packages,files-before,files-after,python-before,python-after,apt,dist-upgrade,repositories,services,systemd,aelladata,checksums}
  local profile="${ST_EXECUTION_PROFILE:-${OSU_EXECUTION_PROFILE:-production}}"

  if [[ "$phase" == "before" ]]; then
    osu_write_apt_preserve_config
    osu_capture_package_inventory "${art}/packages/installed-before.tsv"
    if [[ "$profile" == "discovery" || "${POLICY_DISCOVERY_CAPTURE_FILE_CHANGES}" == "true" ]]; then
      osu_capture_file_manifest "${art}/files-before/manifest.tsv"
    fi
    if [[ "$profile" == "discovery" || "${POLICY_DISCOVERY_CAPTURE_PYTHON_INVENTORY}" == "true" ]]; then
      osu_capture_python_inventory "${art}/python-before"
    fi
    if [[ -f "$(osu_hostpath /etc/apt/sources.list)" ]]; then
      cp -a "$(osu_hostpath /etc/apt/sources.list)" "${art}/repositories/sources.list.before" 2>/dev/null || true
    fi
    if command -v apt-mark >/dev/null 2>&1; then
      apt-mark showhold >"${art}/packages/holds-before.txt" 2>/dev/null || true
    fi
    ST_ARTIFACT_CAPTURE_STATUS="before_captured"
    return 0
  fi

  osu_capture_package_inventory "${art}/packages/installed-after.tsv"
  osu_diff_package_inventories "${art}/packages/installed-before.tsv" "${art}/packages/installed-after.tsv" "${art}/package-changes.tsv"
  if [[ -f "${art}/files-before/manifest.tsv" ]]; then
    osu_capture_file_manifest "${art}/files-after/manifest.tsv"
    osu_diff_file_manifests "${art}/files-before/manifest.tsv" "${art}/files-after/manifest.tsv" "${art}/file-changes.tsv"
  fi
  if [[ -d "${art}/python-before" ]]; then
    osu_capture_python_inventory "${art}/python-after"
    printf 'INFORMATIONAL: Python differences are not Phase 1 success criteria.\n' >"${art}/python-changes.tsv"
  fi
  if [[ "$profile" == "discovery" || "${POLICY_DISCOVERY_PRESERVE_APT_CACHE}" == "true" ]]; then
    if ! osu_copy_apt_archives "${art}/packages"; then
      ST_ARTIFACT_CAPTURE_STATUS="WARNING_partial_package_copy"
    fi
  fi
  osu_build_package_manifest_tsv "${art}/packages" "${art}/package-manifest.tsv"
  if [[ -d "$(osu_hostpath /var/log/dist-upgrade)" ]]; then
    cp -a "$(osu_hostpath /var/log/dist-upgrade)/." "${art}/dist-upgrade/" 2>/dev/null || true
  fi
  if [[ -d "$(osu_hostpath /var/log/apt)" ]]; then
    cp -a "$(osu_hostpath /var/log/apt)/." "${art}/apt/" 2>/dev/null || true
  fi
  local meta
  meta="$(osu_hostpath /var/lib/ubuntu-release-upgrader)"
  [[ -d "$meta" ]] && mkdir -p "${art}/repositories/upgrader" && cp -a "$meta/." "${art}/repositories/upgrader/" 2>/dev/null || true
  if [[ -f "${OSU_STATE_DIR}/original-system-state/critical-checksums.tsv" ]]; then
    cp -a "${OSU_STATE_DIR}/original-system-state/critical-checksums.tsv" "${art}/aelladata/critical-before.tsv"
    if osu_verify_critical_checksums; then
      printf 'critical_checksums=PASS\n' >"${art}/aelladata/compare.txt"
    else
      printf 'critical_checksums=FAIL\n' >"${art}/aelladata/compare.txt"
    fi
  fi
  {
    printf '{\n'
    printf '  "hop_dir": "%s",\n' "$(osu_json_escape "$hop_dir")"
    printf '  "captured_at_utc": "%s",\n' "$(osu_utc_now)"
    printf '  "execution_profile": "%s",\n' "$(osu_json_escape "$profile")"
    printf '  "phase2_evaluated": false,\n'
    printf '  "phase2_executed": false\n'
    printf '}\n'
  } >"${art}/manifest.json"
  {
    printf 'Discovery hop artifacts\n'
    printf 'execution_profile=%s\n' "$profile"
    printf 'phase2_evaluated=false\n'
    find "$art" -type f -printf '%P\n' 2>/dev/null | sort
  } >"${art}/manifest.txt"
  (
    cd "$art" && find . -type f ! -name 'export-manifest.sha256' -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null
  ) >"${art}/checksums/export-manifest.sha256" || true
  cp -a "${art}/checksums/export-manifest.sha256" "${art}/export-manifest.sha256" 2>/dev/null || true
  if [[ "${ST_ARTIFACT_CAPTURE_STATUS:-}" != WARNING* ]]; then
    ST_ARTIFACT_CAPTURE_STATUS="captured"
  fi
  return 0
}

osu_sanitize_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | sed 's/__*/_/g'
}

osu_export_artifacts() {
  local hop_filter="${1:-}" out_dir="${2:-.}" keep_dir="${3:-0}"
  local host stamp name parent archive hop_dirs=() hop_dir base_code stage
  host="$(osu_sanitize_name "${ST_HOSTNAME:-$(osu_current_hostname)}")"
  stamp="$(osu_utc_stamp)"
  mkdir -p "$out_dir"
  parent="$(cd "$out_dir" && pwd)"

  if [[ -n "$hop_filter" ]]; then
    mapfile -t hop_dirs < <(find "${OSU_STATE_DIR}/hops" -maxdepth 1 -type d -name "hop-$(printf '%02d' "$hop_filter")-*" 2>/dev/null | sort)
  else
    mapfile -t hop_dirs < <(find "${OSU_STATE_DIR}/hops" -maxdepth 1 -type d -name 'hop-*' 2>/dev/null | sort)
  fi
  if [[ ${#hop_dirs[@]} -eq 0 ]]; then
    osu_log ERROR "no hop directories to export"
    return 1
  fi

  for hop_dir in "${hop_dirs[@]}"; do
    base_code="$(basename "$hop_dir" | sed -E 's/^hop-[0-9]+-//')"
    name="dp-os-upgrade-artifacts-${host}-${base_code}-${stamp}"
    stage="${parent}/${name}"
    mkdir -p "$stage"
    cp -a "$hop_dir/." "$stage/" 2>/dev/null || true
    [[ -f "$(osu_state_path)" ]] && cp -a "$(osu_state_path)" "$stage/state.json"
    [[ -d "${OSU_STATE_DIR}/reports" ]] && cp -a "${OSU_STATE_DIR}/reports" "$stage/reports" 2>/dev/null || true
    local secret_match
    if ! secret_match="$(find "$stage" \( -iname '*id_rsa*' -o -iname '*.pem' -o -iname '*password*' \) -print -quit 2>/dev/null)"; then
      osu_log ERROR "secret scan failed; refusing export"
      rm -rf "$stage"
      return 1
    fi
    if [[ -n "$secret_match" ]]; then
      osu_log ERROR "secret-like paths detected; refusing export"
      rm -rf "$stage"
      return 1
    fi
    archive="${parent}/${name}.tar.gz"
    tar -C "$parent" -czf "$archive" "$name"
    ST_ARTIFACT_EXPORT_STATUS="exported"
    osu_log INFO "exported artifacts: $archive"
    if [[ "$keep_dir" != "1" ]]; then
      rm -rf "$stage"
    fi
    printf '%s\n' "$archive"
  done
  return 0
}

osu_should_checkpoint_after_hop() {
  local cur_os="$1"
  local profile="${ST_EXECUTION_PROFILE:-production}"
  local max_hops="${ST_MAX_HOPS:-}"
  local stop="${ST_STOP_AFTER_OS:-}"
  local hops_this="${ST_HOPS_THIS_RUN:-0}"

  if [[ "$cur_os" == "${ST_FINAL_TARGET_OS:-$POLICY_TARGET_OS_VERSION}" ]]; then
    return 1
  fi
  if [[ -n "$stop" && "$cur_os" == "$stop" ]]; then
    ST_CHECKPOINT_REASON="stop_after_os_${stop}"
    return 0
  fi
  if [[ -n "$max_hops" && "$hops_this" -ge "$max_hops" ]]; then
    ST_CHECKPOINT_REASON="max_hops_${max_hops}"
    return 0
  fi
  if [[ "$profile" == "discovery" ]]; then
    local def="${POLICY_DISCOVERY_DEFAULT_MAX_HOPS:-1}"
    if [[ -z "$max_hops" && -z "$stop" && "$hops_this" -ge "$def" ]]; then
      ST_CHECKPOINT_REASON="discovery_default_max_hops_${def}"
      return 0
    fi
  fi
  return 1
}
