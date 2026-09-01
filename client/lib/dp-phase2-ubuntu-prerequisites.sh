#!/usr/bin/env bash
# Offline Phase 2 Ubuntu prerequisite install + critical Python runtime gate.
# Uses the separately published phase2-ubuntu-prerequisites artifact.
# Never runs apt --fix-broken install. Never force-depends as success.
# shellcheck shell=bash

PHASE2_PREREQ_ARTIFACT_NAME="${PHASE2_PREREQ_ARTIFACT_NAME:-phase2-ubuntu-prerequisites.tar.gz}"
PHASE2_PREREQ_PROTECTED_PACKAGES="${PHASE2_PREREQ_PROTECTED_PACKAGES:-python3-gevent python3-kazoo python3-pyinotify aella-da-services aella-da-cli aella-uvp-2404}"
PHASE2_CRITICAL_PYTHON_IMPORTS="${PHASE2_CRITICAL_PYTHON_IMPORTS:-click flask werkzeug OpenSSL gevent kazoo pyinotify}"

dp2_prereq_log() {
  local level="$1"
  shift
  if declare -F log >/dev/null 2>&1; then
    log "[${level}] $*"
    return 0
  fi
  if declare -F dp2_log >/dev/null 2>&1; then
    dp2_log "$level" "$*"
    return 0
  fi
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*"
}

dp2_prereq_find_artifact() {
  local name="$PHASE2_PREREQ_ARTIFACT_NAME"
  local cand
  for cand in \
    "${PHASE2_PREREQ_ARTIFACT:-}" \
    "${STAGING_DIR:-/opt/aelladata/aelladeb_py3}/${name}" \
    "/opt/aelladata/aelladeb_py3/${name}" \
    "/home/aella/${name}" \
    "/opt/aelladata/os-upgrade/offline/phase2-bringup/${name}"
  do
    [[ -n "$cand" && -f "$cand" ]] || continue
    printf '%s\n' "$cand"
    return 0
  done
  return 1
}

dp2_prereq_package_installed() {
  local pkg="$1"
  local status
  status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
  [[ "$status" == "install ok installed" ]]
}

dp2_prereq_installed_version() {
  local pkg="$1"
  dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true
}

dp2_prereq_compare_versions() {
  # Debian version semantics only. Never use string comparison.
  dpkg --compare-versions "$1" "$2" "$3"
}

# Validate prerequisite archive members before root extraction.
# Allowlist: phase2-ubuntu-prerequisites.manifest.json, install-order.txt, debs/*.deb
# Rejects absolute paths, .. traversal, symlinks, hardlinks, devices, FIFOs, sockets,
# unexpected top-level paths, and duplicate member names.
dp2_prereq_assert_safe_archive() {
  local artifact="$1"
  local py_out rc=0
  [[ -f "$artifact" ]] || {
    dp2_prereq_log ERROR "PHASE2_PREREQ_ARCHIVE=FAIL reason=missing"
    return 1
  }
  py_out="$(python3 - "$artifact" <<'PY'
import sys, tarfile

path = sys.argv[1]
allowed_files = {
    "phase2-ubuntu-prerequisites.manifest.json",
    "install-order.txt",
}
seen = set()
try:
    with tarfile.open(path, "r:gz") as tf:
        for m in tf.getmembers():
            name = m.name
            if name in seen:
                print("duplicate_member=%s" % name)
                sys.exit(2)
            seen.add(name)
            cleaned = name.rstrip("/")
            if cleaned.startswith("/") or cleaned.startswith("./") and cleaned[2:].startswith("/"):
                print("absolute_path=%s" % name)
                sys.exit(2)
            parts = [p for p in cleaned.split("/") if p not in ("", ".")]
            if any(p == ".." for p in parts):
                print("path_traversal=%s" % name)
                sys.exit(2)
            if m.issym() or m.islnk():
                print("link_member=%s" % name)
                sys.exit(2)
            special_types = {tarfile.BLKTYPE, tarfile.CHRTYPE, tarfile.FIFOTYPE}
            if hasattr(tarfile, "SOCKTYPE"):
                special_types.add(tarfile.SOCKTYPE)
            if m.type in special_types:
                print("special_member=%s type=%s" % (name, m.type))
                sys.exit(2)
            if m.isdir():
                if cleaned != "debs":
                    print("unexpected_dir=%s" % name)
                    sys.exit(2)
                continue
            if not m.isfile():
                print("unexpected_type=%s" % name)
                sys.exit(2)
            if cleaned in allowed_files:
                continue
            if cleaned.startswith("debs/") and cleaned.count("/") == 1 and cleaned.endswith(".deb"):
                base = cleaned.split("/", 1)[1]
                if not base or "/" in base or base.startswith("."):
                    print("unsafe_deb_name=%s" % name)
                    sys.exit(2)
                continue
            print("unexpected_member=%s" % name)
            sys.exit(2)
except tarfile.TarError as exc:
    print("tar_error=%s" % exc)
    sys.exit(2)
print("ok members=%d" % len(seen))
sys.exit(0)
PY
)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_ARCHIVE=FAIL reason=${py_out:-unsafe}"
    return 1
  fi
  dp2_prereq_log INFO "PHASE2_PREREQ_ARCHIVE=PASS ${py_out}"
  return 0
}

dp2_prereq_safe_extract() {
  local artifact="$1"
  local extract="$2"
  local py_rc=0
  dp2_prereq_assert_safe_archive "$artifact" || return 1
  mkdir -p "$extract" || return 1
  python3 - "$artifact" "$extract" <<'PY' || py_rc=$?
import sys, tarfile, os

artifact, dest = sys.argv[1], sys.argv[2]
# Re-validate and extract file members only via safe join.
with tarfile.open(artifact, "r:gz") as tf:
    for m in tf.getmembers():
        if m.isdir():
            target = os.path.join(dest, m.name)
            os.makedirs(target, exist_ok=True)
            continue
        if not m.isfile():
            raise SystemExit("unsafe_member=%s" % m.name)
        target = os.path.join(dest, m.name)
        parent = os.path.dirname(target)
        os.makedirs(parent, exist_ok=True)
        # Refuse symlink races / escapes after join
        dest_real = os.path.realpath(dest)
        parent_real = os.path.realpath(parent)
        if not (parent_real == dest_real or parent_real.startswith(dest_real + os.sep)):
            raise SystemExit("extract_escape=%s" % m.name)
        src = tf.extractfile(m)
        if src is None:
            raise SystemExit("extract_missing=%s" % m.name)
        with open(target, "wb") as out:
            out.write(src.read())
sys.exit(0)
PY
  if [[ "$py_rc" -ne 0 ]]; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=safe_extract"
    return 1
  fi
  return 0
}

# Skip only when the installed package is exactly the selected artifact
# version. Older installed versions must be replaced. A newer or otherwise
# different installed version is a fail-closed conflict (no silent downgrade).
# Returns: 0 skip, 1 install, 2 conflict.
dp2_prereq_deb_install_decision() {
  local deb="$1"
  local pkg ver arch inst_ver
  pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
  ver="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
  arch="$(dpkg-deb -f "$deb" Architecture 2>/dev/null || true)"
  if [[ -z "$pkg" || -z "$ver" ]]; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=deb_control_missing file=$(basename "$deb")"
    return 2
  fi
  if ! dp2_prereq_package_installed "$pkg"; then
    dp2_prereq_log INFO "PHASE2_PREREQ_INSTALL_NEEDED package=${pkg} version=${ver} arch=${arch} reason=not_installed"
    return 1
  fi
  inst_ver="$(dp2_prereq_installed_version "$pkg")"
  if [[ -z "$inst_ver" ]]; then
    dp2_prereq_log INFO "PHASE2_PREREQ_INSTALL_NEEDED package=${pkg} version=${ver} reason=installed_version_unknown"
    return 1
  fi
  if dp2_prereq_compare_versions "$inst_ver" eq "$ver"; then
    dp2_prereq_log INFO "PHASE2_PREREQ_ALREADY_INSTALLED package=${pkg} version=${ver} arch=${arch}"
    return 0
  fi
  if dp2_prereq_compare_versions "$inst_ver" lt "$ver"; then
    dp2_prereq_log INFO "PHASE2_PREREQ_INSTALL_NEEDED package=${pkg} installed=${inst_ver} selected=${ver} reason=older_installed"
    return 1
  fi
  dp2_prereq_log ERROR "PHASE2_PREREQ_VERSION_CONFLICT package=${pkg} installed=${inst_ver} selected=${ver} arch=${arch}"
  return 2
}

# Evaluate every member of one SCC install group before any dpkg invocation.
# Filename order must not change the decision. A newer installed member is
# always a fail-closed conflict, even if an earlier member needs installation.
# Returns: 0 all exact (skip group), 1 any member needs install, 2 conflict.
dp2_prereq_scc_group_decision() {
  local any_install_needed=0 all_exact=1 decision=0 fpath pkg prev_e=0
  for fpath in "$@"; do
    prev_e=0
    [[ $- == *e* ]] && prev_e=1
    set +e
    dp2_prereq_deb_install_decision "$fpath"
    decision=$?
    [[ "$prev_e" -eq 1 ]] && set -e
    if [[ "$decision" -eq 2 ]]; then
      pkg="$(dpkg-deb -f "$fpath" Package 2>/dev/null || true)"
      dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=version_conflict package=${pkg}"
      return 2
    fi
    if [[ "$decision" -eq 1 ]]; then
      any_install_needed=1
      all_exact=0
    fi
  done
  if [[ "$all_exact" -eq 1 && "$any_install_needed" -eq 0 ]]; then
    return 0
  fi
  return 1
}

dp2_prereq_parse_simulation_removals() {
  local text="$1"
  printf '%s\n' "$text" | awk '
    $1 == "Remv" || $1 == "Purg" { print $2 }
    $1 == "Removing" || $1 == "Purging" { gsub(/\.$/, "", $2); print $2 }
  '
}

dp2_prereq_transaction_safe() {
  local simulation="$1"
  local pkg blocked=()
  local removals
  removals="$(dp2_prereq_parse_simulation_removals "$simulation")"
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    for prot in $PHASE2_PREREQ_PROTECTED_PACKAGES; do
      if [[ "$pkg" == "$prot" ]]; then
        blocked+=("$pkg")
      fi
    done
  done <<<"$removals"
  if [[ ${#blocked[@]} -gt 0 ]]; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_TRANSACTION_SAFE=NO blocked=${blocked[*]}"
    return 1
  fi
  dp2_prereq_log INFO "PHASE2_PREREQ_TRANSACTION_SAFE=YES"
  return 0
}

dp2_prereq_refuse_fix_broken() {
  # Guard: this layer must never invoke apt --fix-broken / apt-get -f.
  return 0
}

dp2_prereq_dep_names() {
  # First alternative of each Depends/Pre-Depends group (name only).
  local field="$1" group first
  while IFS= read -r group; do
    group="${group#"${group%%[![:space:]]*}"}"
    [[ -n "$group" ]] || continue
    first="${group%%|*}"
    first="${first#"${first%%[![:space:]]*}"}"
    first="${first%%[[:space:]]*}"
    first="${first%%(*}"
    first="${first%"${first##*[![:space:]]}"}"
    [[ -n "$first" ]] || continue
    printf '%s\n' "$first"
  done < <(printf '%s\n' "$field" | tr ',' '\n')
}

dp2_prereq_log_unsatisfied_protected_depends() {
  local pkg field dep
  for pkg in $PHASE2_PREREQ_PROTECTED_PACKAGES; do
    dp2_prereq_package_installed "$pkg" || continue
    field="$(dpkg-query -W -f='${Pre-Depends}\n${Depends}\n' "$pkg" 2>/dev/null || true)"
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      case "$dep" in
        python3|python3-minimal|libc6|libgcc-s1|libstdc++6|base-files|dpkg) continue ;;
      esac
      if ! dp2_prereq_package_installed "$dep"; then
        dp2_prereq_log ERROR "PROTECTED_PACKAGE_DEP_MISSING package=${pkg} depends=${dep}"
      fi
    done < <(dp2_prereq_dep_names "$field")
  done
}

dp2_validate_apt_dependency_graph() {
  local stage="${1:-unspecified}"
  local audit=""
  # dpkg --audit is informational only. It can be clean while apt still has
  # unresolved Depends left by dpkg --force-depends. Never treat it as proof.
  if command -v dpkg >/dev/null 2>&1; then
    audit="$(dpkg --audit 2>&1 || true)"
    if [[ -n "${audit// }" ]]; then
      dp2_prereq_log WARN "DPKG_AUDIT=DIRTY stage=${stage}"
    else
      dp2_prereq_log INFO "DPKG_AUDIT=CLEAN stage=${stage} (not sufficient)"
    fi
  fi
  dp2_prereq_log_unsatisfied_protected_depends

  if ! command -v apt-get >/dev/null 2>&1; then
    dp2_prereq_log ERROR "APT_DEPENDENCY_CHECK=FAIL stage=${stage} reason=apt-get_missing"
    return 1
  fi

  local rc=0
  local out=""
  local prev_e=0
  [[ $- == *e* ]] && prev_e=1
  set +e
  # Read-only graph check. NoLocking avoids a false FAIL when the wrapper
  # runs without the dpkg frontend lock (non-root tests) and does not
  # change the dependency verdict.
  out="$(apt-get -o Debug::NoLocking=true check 2>&1)"
  rc=$?
  [[ "$prev_e" -eq 1 ]] && set -e
  if [[ "$rc" -ne 0 ]]; then
    dp2_prereq_log ERROR "APT_DEPENDENCY_CHECK=FAIL stage=${stage} rc=${rc}"
    if [[ -n "${out// }" ]]; then
      dp2_prereq_log ERROR "APT_DEPENDENCY_CHECK_DETAIL=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)"
    fi
    return "$rc"
  fi
  dp2_prereq_log INFO "APT_DEPENDENCY_CHECK=PASS stage=${stage}"
  return 0
}

dp2_validate_critical_python_runtime() {
  local missing=()
  local mod rc
  local python_bin="${PHASE2_PREREQ_PYTHON:-python3}"
  if ! command -v "$python_bin" >/dev/null 2>&1; then
    dp2_prereq_log ERROR "CRITICAL_PYTHON_RUNTIME=FAIL reason=python3_missing"
    return 1
  fi
  for mod in $PHASE2_CRITICAL_PYTHON_IMPORTS; do
    if ! "$python_bin" -c "import ${mod}" >/dev/null 2>&1; then
      missing+=("$mod")
      dp2_prereq_log ERROR "CRITICAL_PYTHON_IMPORT=FAIL module=${mod}"
    else
      dp2_prereq_log INFO "CRITICAL_PYTHON_IMPORT=PASS module=${mod}"
    fi
  done
  # pyinotify needs asyncore on Python 3.12 (provided by python3-pyasyncore).
  if ! "$python_bin" -c "import asyncore" >/dev/null 2>&1; then
    missing+=("asyncore")
    dp2_prereq_log ERROR "CRITICAL_PYTHON_IMPORT=FAIL module=asyncore"
  else
    dp2_prereq_log INFO "CRITICAL_PYTHON_IMPORT=PASS module=asyncore"
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    dp2_prereq_log ERROR "CRITICAL_PYTHON_RUNTIME=FAIL missing=${missing[*]}"
    return 1
  fi

  local entry
  for entry in \
    /opt/aelladata/python/aella_da_restful.py \
    /opt/aelladata/da/aella_da_restful.py \
    /usr/lib/python3/dist-packages/aella_da_restful.py
  do
    if [[ -f "$entry" ]]; then
      if "$python_bin" -c "import py_compile; py_compile.compile('${entry}', doraise=True)" >/dev/null 2>&1; then
        dp2_prereq_log INFO "AELLA_DA_RESTFUL_COMPILE=PASS path=${entry}"
      else
        dp2_prereq_log ERROR "AELLA_DA_RESTFUL_COMPILE=FAIL path=${entry}"
        return 1
      fi
      break
    fi
  done
  dp2_prereq_log INFO "CRITICAL_PYTHON_RUNTIME=PASS"
  return 0
}

dp2_prereq_dpkg_install() {
  # Capture the real dpkg status. `if ! dpkg; then rc=$?` is wrong: inside
  # the then-body $? is the status of `!`, which may be 0.
  local prev_e=0 rc=0
  [[ $- == *e* ]] && prev_e=1
  set +e
  dpkg -i "$@"
  rc=$?
  [[ "$prev_e" -eq 1 ]] && set -e
  return "$rc"
}

dp2_prereq_read_state_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -F= -v k="$key" '$1==k {print $2; exit}' "$file"
}

dp2_prereq_validate_state_contract() {
  # Independent PHASE2_PREREQ_* contract. Missing/blank/non-numeric count is
  # never treated as zero. BUILD/PUBLICATION must be PASS.
  local state="$1"
  local extras_dir="${2:-}"
  local required count build publication artifact sha
  local reason=""
  if [[ ! -f "$state" ]]; then
    printf '%s\n' "state_missing"
    return 1
  fi
  required="$(awk -F= '$1=="PHASE2_PREREQ_REQUIRED"{print $2; exit}' "$state")"
  count="$(awk -F= '$1=="PHASE2_PREREQ_PACKAGE_COUNT"{print $2; exit}' "$state")"
  build="$(awk -F= '$1=="PHASE2_PREREQ_BUILD"{print $2; exit}' "$state")"
  publication="$(awk -F= '$1=="PHASE2_PREREQ_PUBLICATION"{print $2; exit}' "$state")"
  artifact="$(awk -F= '$1=="PHASE2_PREREQ_ARTIFACT"{print $2; exit}' "$state")"
  sha="$(awk -F= '$1=="PHASE2_PREREQ_SHA256"{print $2; exit}' "$state")"
  if [[ "$build" != "PASS" ]]; then
    printf '%s\n' "build_not_pass"
    return 1
  fi
  if [[ "$publication" != "PASS" ]]; then
    printf '%s\n' "publication_not_pass"
    return 1
  fi
  if [[ -z "${count+x}" || -z "$count" ]]; then
    printf '%s\n' "count_missing"
    return 1
  fi
  if [[ ! "$count" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "count_nonnumeric"
    return 1
  fi
  if [[ "$required" == "NO" ]]; then
    if [[ "$count" != "0" ]]; then
      printf '%s\n' "count_nonzero_when_not_required"
      return 1
    fi
    printf '%s\n' "not_required"
    return 0
  fi
  if [[ "$required" != "YES" ]]; then
    printf '%s\n' "required_invalid"
    return 1
  fi
  if [[ "$count" -le 0 ]]; then
    printf '%s\n' "count_not_positive"
    return 1
  fi
  if [[ "$artifact" != "phase2-ubuntu-prerequisites.tar.gz" ]]; then
    printf '%s\n' "artifact_name_invalid"
    return 1
  fi
  if [[ ! "$sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
    printf '%s\n' "sha256_invalid"
    return 1
  fi
  if [[ -n "$extras_dir" ]]; then
    if [[ ! -f "${extras_dir}/phase2-ubuntu-prerequisites.state" ]]; then
      printf '%s\n' "state_file_missing"
      return 1
    fi
    if [[ ! -f "${extras_dir}/phase2-ubuntu-prerequisites.tar.gz" ]]; then
      printf '%s\n' "artifact_missing"
      return 1
    fi
    if [[ ! -f "${extras_dir}/phase2-ubuntu-prerequisites.tar.gz.sha256" ]]; then
      printf '%s\n' "sha_sidecar_missing"
      return 1
    fi
    if [[ ! -f "${extras_dir}/phase2-ubuntu-prerequisites.manifest.json" ]]; then
      printf '%s\n' "manifest_missing"
      return 1
    fi
  fi
  printf '%s\n' "required"
  return 0
}

dp2_prereq_find_state() {
  local cand
  for cand in \
    "${PHASE2_PREREQ_STATE:-}" \
    "${STAGING_DIR:-/opt/aelladata/aelladeb_py3}/phase2-ubuntu-prerequisites.state" \
    "/opt/aelladata/aelladeb_py3/phase2-ubuntu-prerequisites.state" \
    "/home/aella/phase2-ubuntu-prerequisites.state" \
    "/opt/aelladata/os-upgrade/offline/phase2-bringup/phase2-ubuntu-prerequisites.state"
  do
    [[ -n "$cand" && -f "$cand" ]] || continue
    printf '%s\n' "$cand"
    return 0
  done
  return 1
}

dp2_prereq_find_manifest() {
  local artifact="$1"
  local cand dir=""
  [[ -n "$artifact" ]] && dir="$(dirname "$artifact")"
  for cand in \
    "${PHASE2_PREREQ_MANIFEST:-}" \
    "${dir}/phase2-ubuntu-prerequisites.manifest.json" \
    "${STAGING_DIR:-/opt/aelladata/aelladeb_py3}/phase2-ubuntu-prerequisites.manifest.json" \
    "/opt/aelladata/aelladeb_py3/phase2-ubuntu-prerequisites.manifest.json" \
    "/home/aella/phase2-ubuntu-prerequisites.manifest.json"
  do
    [[ -n "$cand" && -f "$cand" ]] || continue
    printf '%s\n' "$cand"
    return 0
  done
  return 1
}

dp2_prereq_json_field() {
  local file="$1" key="$2"
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi
  python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
value = data.get(sys.argv[2], "")
if value is None:
    print("")
else:
    print(value)
' "$file" "$key"
}

dp2_prereq_normalize_sha() {
  printf '%s' "$1" | tr 'A-F' 'a-f'
}

# REQUIRED=YES: state SHA, sidecar SHA, and actual artifact digest must agree.
dp2_prereq_verify_sha_contract() {
  local artifact="$1" state_sha="$2"
  local sidecar="${artifact}.sha256"
  local sidecar_sha actual
  if [[ ! -f "$sidecar" ]]; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_SHA256=FAIL reason=sidecar_missing"
    return 1
  fi
  sidecar_sha="$(awk 'NF {print $1; exit}' "$sidecar")"
  actual="$(sha256sum "$artifact" | awk '{print $1}')"
  state_sha="$(dp2_prereq_normalize_sha "$state_sha")"
  sidecar_sha="$(dp2_prereq_normalize_sha "$sidecar_sha")"
  actual="$(dp2_prereq_normalize_sha "$actual")"
  if [[ -z "$state_sha" || -z "$sidecar_sha" || -z "$actual" ]]; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_SHA256=FAIL reason=sha_blank"
    return 1
  fi
  if [[ "$state_sha" != "$actual" ]]; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_SHA256=FAIL reason=state_artifact_mismatch"
    return 1
  fi
  if [[ "$sidecar_sha" != "$actual" ]]; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_SHA256=FAIL reason=sidecar_artifact_mismatch"
    return 1
  fi
  if [[ "$state_sha" != "$sidecar_sha" ]]; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_SHA256=FAIL reason=state_sidecar_mismatch"
    return 1
  fi
  dp2_prereq_log INFO "PHASE2_PREREQ_SHA256=PASS"
  return 0
}

dp2_prereq_verify_manifest_contract() {
  local manifest="$1" expected_count="$2" expected_sha="$3"
  local got_count got_sha
  if [[ ! -f "$manifest" ]]; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=manifest_missing"
    return 1
  fi
  got_count="$(dp2_prereq_json_field "$manifest" package_count || true)"
  got_sha="$(dp2_prereq_json_field "$manifest" sha256 || true)"
  if [[ -z "$got_count" || ! "$got_count" =~ ^[0-9]+$ ]]; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=manifest_count_invalid"
    return 1
  fi
  if [[ "$got_count" != "$expected_count" ]]; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=manifest_count_mismatch"
    return 1
  fi
  if [[ -n "$got_sha" ]]; then
    got_sha="$(dp2_prereq_normalize_sha "$got_sha")"
    expected_sha="$(dp2_prereq_normalize_sha "$expected_sha")"
    if [[ "$got_sha" != "$expected_sha" ]]; then
      dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=manifest_sha_mismatch"
      return 1
    fi
  fi
  dp2_prereq_log INFO "PHASE2_PREREQ_MANIFEST=PASS"
  return 0
}

dp2_install_phase2_ubuntu_prerequisites() {
  local artifact extract rc=0
  local state="" required="" count="" sha=""
  local verdict="" state_rc=0 prev_e=0
  local manifest=""
  dp2_prereq_log INFO "PHASE2_PREREQ_INSTALL=START"
  dp2_prereq_log INFO "PHASE2_PREREQ_INSTALL_STRATEGY=local_deb_closure"

  # State is mandatory for both REQUIRED=YES and REQUIRED=NO. Artifact
  # presence alone never authorizes install, and a missing state is never
  # treated as NOT_REQUIRED.
  if ! state="$(dp2_prereq_find_state)"; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=state_missing"
    return 1
  fi
  [[ $- == *e* ]] && prev_e=1
  set +e
  verdict="$(dp2_prereq_validate_state_contract "$state")"
  state_rc=$?
  [[ "$prev_e" -eq 1 ]] && set -e
  required="$(dp2_prereq_read_state_value "$state" PHASE2_PREREQ_REQUIRED || true)"
  count="$(dp2_prereq_read_state_value "$state" PHASE2_PREREQ_PACKAGE_COUNT || true)"
  sha="$(dp2_prereq_read_state_value "$state" PHASE2_PREREQ_SHA256 || true)"
  dp2_prereq_log INFO "PHASE2_PREREQ_STATE=${state} required=${required:-unknown} verdict=${verdict:-unknown}"
  if [[ "$state_rc" -ne 0 ]]; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=state_${verdict:-invalid}"
    return 1
  fi
  if [[ "$verdict" == "not_required" ]]; then
    required="NO"
  fi

  if [[ -n "${PHASE2_PREREQ_APT_SIMULATION:-}" ]]; then
    if ! dp2_prereq_transaction_safe "$PHASE2_PREREQ_APT_SIMULATION"; then
      dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=protected_removal"
      return 1
    fi
  fi

  if [[ "${required}" == "NO" ]]; then
    # Current state is authoritative. A leftover tarball from a previous
    # REQUIRED=YES run must not be consumed.
    dp2_prereq_log INFO "PHASE2_PREREQ_INSTALL=SKIP reason=not_required"
    if ! dp2_validate_apt_dependency_graph prerequisites; then
      dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=apt_dependency_check"
      return 1
    fi
    dp2_prereq_log INFO "PHASE2_PREREQ_STAGE=NOT_REQUIRED"
    return 0
  fi

  if ! artifact="$(dp2_prereq_find_artifact)"; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_ARTIFACT=ABSENT"
    dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=artifact_absent_required"
    return 1
  fi
  dp2_prereq_log INFO "PHASE2_PREREQ_ARTIFACT=${artifact}"

  if ! dp2_prereq_verify_sha_contract "$artifact" "$sha"; then
    return 1
  fi
  if ! manifest="$(dp2_prereq_find_manifest "$artifact")"; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=manifest_missing"
    return 1
  fi
  if ! dp2_prereq_verify_manifest_contract "$manifest" "$count" "$sha"; then
    return 1
  fi

  extract="$(mktemp -d "${TMPDIR:-/tmp}/phase2-prereq-inst.XXXXXX")"
  if ! dp2_prereq_safe_extract "$artifact" "$extract"; then
    rm -rf "$extract"
    dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=extract"
    return 1
  fi
  if [[ -f "${extract}/phase2-ubuntu-prerequisites.manifest.json" ]]; then
    if ! dp2_prereq_verify_manifest_contract \
      "${extract}/phase2-ubuntu-prerequisites.manifest.json" "$count" "$sha"; then
      rm -rf "$extract"
      return 1
    fi
  fi

  local order_file="${extract}/install-order.txt"
  local installed_any=0 line fn pkg
  local -a files
  if [[ ! -f "$order_file" ]]; then
    # Zero-extra artifacts may omit debs; still require an order file when debs exist.
    shopt -s nullglob
    files=("${extract}/debs/"*.deb)
    shopt -u nullglob
    if [[ ${#files[@]} -gt 0 ]]; then
      rm -rf "$extract"
      dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=install_order_missing"
      return 1
    fi
    rm -rf "$extract"
    if ! dp2_validate_apt_dependency_graph prerequisites; then
      dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=apt_dependency_check"
      return 1
    fi
    dp2_prereq_log INFO "PHASE2_PREREQ_INSTALL=PASS"
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    files=()
    # shellcheck disable=SC2086
    for fn in $line; do
      files+=("${extract}/debs/${fn}")
    done
    if [[ ${#files[@]} -eq 0 ]]; then
      continue
    fi
    for fn in "${files[@]}"; do
      if [[ ! -f "$fn" ]]; then
        dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=ordered_deb_missing file=$(basename "$fn")"
        rm -rf "$extract"
        return 1
      fi
      pkg="$(dpkg-deb -f "$fn" Package 2>/dev/null || true)"
      if [[ -z "$pkg" ]]; then
        dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=deb_control_missing file=$(basename "$fn")"
        rm -rf "$extract"
        return 1
      fi
    done
    pkg="$(dpkg-deb -f "${files[0]}" Package 2>/dev/null || true)"
    local decision=1
    prev_e=0
    [[ $- == *e* ]] && prev_e=1
    set +e
    dp2_prereq_scc_group_decision "${files[@]}"
    decision=$?
    [[ "$prev_e" -eq 1 ]] && set -e
    if [[ "$decision" -eq 2 ]]; then
      rm -rf "$extract"
      return 1
    fi
    if [[ "$decision" -eq 0 ]]; then
      continue
    fi
    dp2_prereq_dpkg_install "${files[@]}"
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
      dp2_prereq_log ERROR "PHASE2_PREREQ_DPKG=FAIL package=${pkg} rc=${rc}"
      rm -rf "$extract"
      return "$rc"
    fi
    installed_any=1
    dp2_prereq_log INFO "PHASE2_PREREQ_DPKG=PASS package=${pkg} group=${#files[@]}"
  done < "$order_file"
  rm -rf "$extract"

  if [[ "$installed_any" -eq 0 ]]; then
    dp2_prereq_log INFO "PHASE2_PREREQ_INSTALL=IDEMPOTENT"
  fi

  if ! dp2_validate_apt_dependency_graph prerequisites; then
    dp2_prereq_log ERROR "PHASE2_PREREQ_INSTALL=FAIL reason=apt_dependency_check"
    return 1
  fi

  dp2_prereq_log INFO "PHASE2_PREREQ_INSTALL=PASS"
  return 0
}
