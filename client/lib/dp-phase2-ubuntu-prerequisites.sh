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

dp2_legacy_product_transition_environment() {
  # There is no operator/environment bypass or alternate live dpkg database.
  [[ -z "${DPKG_ROOT:-}" && -z "${DPKG_ADMINDIR:-}" ]] || return 1
  [[ "$(. /etc/os-release; printf '%s:%s:%s' "${ID:-}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}")" == "ubuntu:24.04:noble" ]] || return 1
  [[ "$(dpkg --print-architecture)" == "amd64" ]]
}

dp2_legacy_product_transition_status_path() {
  local configured
  configured="$(apt-config shell DP2_STATUS Dir::State::status/f)" || return 1
  [[ "$configured" == "DP2_STATUS='/var/lib/dpkg/status'" ]] || return 1
  printf '%s\n' /var/lib/dpkg/status
}

# Pure snapshot transformation, also exercised against isolated real APT in tests.
# No installed metadata is changed. Only exact legacy Python 2 dependency atoms
# in a coherent seven-package product generation are omitted from this copy.
dp2_write_legacy_product_shadow() {
  python3 - "$1" "$2" <<'PY'
import hashlib
import pathlib
import re
import sys

expected = {
    'aella-da-cli': {'python2.7', 'python-openssl', 'python-yaml'},
    'aella-da-services': {'python2.7', 'openssl', 'python-openssl', 'python-yaml', 'python-concurrent.futures'},
    'aella-uvp': {'python', 'openssl', 'python-openssl', 'python-yaml', 'python-flask',
                  'python-concurrent.futures', 'python-configparser', 'python-tabulate',
                  'python-tornado', 'python-httplib2', 'python-requests', 'python-psutil'},
    'aellacm': {'python2.7', 'python-yaml', 'python-tornado', 'python-httplib2',
                'python-requests', 'python-crypto', 'pypki'},
    'kube-tools': {'python2.7'},
    'phonehome': set(),
    'pypki': {'python2.7', 'openssl', 'python-configparser', 'python-tabulate'},
}
legacy = set().union(*expected.values()) - {'openssl', 'pypki'}
legacy_atom = re.compile(r'(?<![a-z0-9+.-])(?:' + '|'.join(re.escape(p) for p in sorted(legacy)) + r')(?![a-z0-9+.-])')

def fail(reason):
    raise ValueError(reason)

try:
    raw = pathlib.Path(sys.argv[1]).read_bytes()
    if len(raw) > 64 * 1024 * 1024 or b'\x00' in raw or b'\r' in raw:
        fail('status_format')
    records = re.split(r'\n\n', raw.decode('utf-8'))
    seen, selected, versions = set(), set(), set()
    for number, record in enumerate(records):
        if not record.strip():
            continue
        lines = record.splitlines(keepends=True)
        fields, spans, key = {}, {}, None
        for index, line in enumerate(lines):
            if line.startswith((' ', '\t')):
                if key is None:
                    fail('orphan_continuation')
                fields[key] += ' ' + line.strip()
                spans[key][1] = index + 1
                continue
            match = re.fullmatch(r'([A-Za-z0-9][A-Za-z0-9-]*):[ \t]*(.*?)\n?', line)
            if not match:
                fail('invalid_field')
            key, value = match.group(1).lower(), match.group(2).strip()
            if key in fields:
                fail('duplicate_field')
            fields[key], spans[key] = value, [index, index + 1]
        package = fields.get('package', '')
        identity = (package, fields.get('architecture', ''))
        if not package or identity in seen:
            fail('duplicate_or_missing_package')
        seen.add(identity)
        if package == 'aella-uvp-2404' and fields.get('status') not in ('deinstall ok config-files', 'purge ok not-installed'):
            fail('new_product_present')
        if package not in expected:
            continue
        if package in selected:
            fail('legacy_multiarch')
        selected.add(package)
        if fields.get('status') != 'install ok installed' or fields.get('architecture') != 'amd64':
            fail('legacy_package_state')
        version = fields.get('version', '')
        if not re.fullmatch(r'6\.[234]\.[0-9]+ubuntu[0-9]+', version):
            fail('legacy_package_version')
        versions.add(version)
        if fields.get('pre-depends', ''):
            fail('legacy_pre_depends')
        groups = [part.strip() for part in fields.get('depends', '').split(',') if part.strip()]
        if len(groups) != len(set(groups)) or not expected[package].issubset(set(groups)):
            fail('legacy_dependency_schema')
        # Keep unknown/non-Python dependencies for APT to evaluate. Expressions
        # involving a known Python 2 atom must match its observed plain form.
        for group in groups:
            if legacy_atom.search(group) and group not in expected[package]:
                fail('legacy_dependency_expression')
        retained = [group for group in groups if group not in legacy]
        if 'depends' in spans:
            start, end = spans['depends']
            replacement = ['Depends: ' + ', '.join(retained) + '\n'] if retained else []
            lines[start:end] = replacement
            records[number] = ''.join(lines)
    if selected != set(expected) or len(versions) != 1:
        fail('legacy_generation_incomplete_or_mixed')
    with open(sys.argv[2], 'xb') as output:
        output.write('\n\n'.join(records).encode('utf-8'))
    print(hashlib.sha256(raw).hexdigest(), next(iter(versions)))
except (OSError, UnicodeError, ValueError) as error:
    print('LEGACY_PRODUCT_TRANSITION=UNSUPPORTED reason=' + str(error), file=sys.stderr)
    sys.exit(1)
PY
}

dp2_try_legacy_product_transition() (
  local stage="${1:-unspecified}" status dir audit details original_hash version current_hash out rc
  case "$stage" in staging|prerequisites|python3_apt) ;; *) return 1 ;; esac
  if ! dp2_legacy_product_transition_environment; then
    dp2_prereq_log WARN "LEGACY_PRODUCT_TRANSITION=UNSUPPORTED reason=environment stage=${stage}"
    return 1
  fi
  if ! status="$(dp2_legacy_product_transition_status_path)"; then
    dp2_prereq_log WARN "LEGACY_PRODUCT_TRANSITION=UNSUPPORTED reason=status_path stage=${stage}"
    return 1
  fi
  if ! audit="$(dpkg --audit 2>&1)" || [[ -n "${audit//[[:space:]]/}" ]]; then
    dp2_prereq_log WARN "LEGACY_PRODUCT_TRANSITION=UNSUPPORTED reason=dpkg_audit stage=${stage}"
    [[ -z "$audit" ]] || printf '%s\n' "$audit" >&2
    return 1
  fi
  dir="$(mktemp -d "${TMPDIR:-/tmp}/phase2-legacy-graph.XXXXXX")" || return 1
  trap 'rm -rf -- "$dir"' EXIT
  if ! details="$(dp2_write_legacy_product_shadow "$status" "${dir}/status")"; then
    return 1
  fi
  read -r original_hash version <<<"$details"
  [[ "$original_hash" =~ ^[0-9a-f]{64}$ && -n "$version" ]] || return 1
  if out="$(LC_ALL=C apt-get -o Debug::NoLocking=true \
      -o "Dir::State::status=${dir}/status" \
      -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= check 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    dp2_prereq_log WARN "LEGACY_PRODUCT_TRANSITION=UNSUPPORTED reason=other_dependency_failure stage=${stage} rc=${rc}"
    printf '%s\n' "$out" >&2
    return 1
  fi
  current_hash="$(sha256sum "$status")" || return 1
  if [[ "${current_hash%% *}" != "$original_hash" ]]; then
    dp2_prereq_log WARN "LEGACY_PRODUCT_TRANSITION=UNSUPPORTED reason=status_changed stage=${stage}"
    return 1
  fi
  dp2_prereq_log WARN "APT_DEPENDENCY_CHECK=DEFERRED_LEGACY_PY2 stage=${stage} legacy_version=${version} shadow_graph=PASS"
  dp2_prereq_log WARN "LEGACY_PRODUCT_REPLACEMENT=PENDING stage=${stage}"
  return 0
)

dp2_validate_apt_dependency_graph() {
  local stage="${1:-unspecified}"
  local audit="" rc=0 out=""
  # Both checks are required. A clean audit alone says nothing about Depends;
  # partial or failing dpkg state must never qualify for the legacy transition.
  if audit="$(dpkg --audit 2>&1)"; then
    if [[ -n "${audit//[[:space:]]/}" ]]; then
      dp2_prereq_log ERROR "APT_DEPENDENCY_CHECK=FAIL stage=${stage} reason=dpkg_audit_dirty"
      printf '%s\n' "$audit" >&2
      return 1
    fi
  else
    rc=$?
    dp2_prereq_log ERROR "APT_DEPENDENCY_CHECK=FAIL stage=${stage} reason=dpkg_audit_failed rc=${rc}"
    [[ -z "$audit" ]] || printf '%s\n' "$audit" >&2
    return "$rc"
  fi
  dp2_prereq_log INFO "DPKG_AUDIT=CLEAN stage=${stage} (not sufficient)"

  if ! command -v apt-get >/dev/null 2>&1; then
    dp2_prereq_log ERROR "APT_DEPENDENCY_CHECK=FAIL stage=${stage} reason=apt-get_missing"
    return 1
  fi

  # Read-only graph check. NoLocking avoids a false FAIL when the wrapper
  # runs without the dpkg frontend lock (non-root tests) and does not
  # change the dependency verdict.
  if out="$(apt-get -o Debug::NoLocking=true check 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$rc" -eq 100 ]] && dp2_try_legacy_product_transition "$stage"; then
      return 0
    fi
    dp2_prereq_log_unsatisfied_protected_depends
    dp2_prereq_log ERROR "APT_DEPENDENCY_CHECK=FAIL stage=${stage} rc=${rc}"
    if [[ -n "${out// }" ]]; then
      dp2_prereq_log ERROR "APT_DEPENDENCY_CHECK_DETAIL=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)"
    fi
    return "$rc"
  fi
  dp2_prereq_log INFO "APT_DEPENDENCY_CHECK=PASS stage=${stage}"
  return 0
}

# Product-replacement metadata gates. The caller supplies an already trusted UVP
# artifact and must run the strict real dependency graph check after replacement.
# This layer never installs a package or executes a Debian maintainer script.
dp2_product_replacement_metadata() {
  local mode="$1" target="$2" artifact="${3:-}" status="${4:-}" out rc
  if out="$(python3 - "$mode" "$target" "$artifact" "$status" <<'PY_PRODUCT_REPLACEMENT'
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

mode, target, artifact, status_path = sys.argv[1:]
meta = 'aella-uvp-2404'
children = ('aella-da-cli', 'aella-da-services', 'aellacm',
            'kube-tools', 'phonehome', 'pypki')
packages = (meta,) + children
prefix = ('PRODUCT_REPLACEMENT_ARTIFACT' if mode == 'artifact'
          else 'PRODUCT_REPLACEMENT_PACKAGES')
env = dict(os.environ, LC_ALL='C')

class Invalid(Exception):
    pass

def require(condition, reason):
    if not condition:
        raise Invalid(reason)

def command(args):
    proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env=env, timeout=60)
    require(proc.returncode == 0, 'command_failed_' + args[0])
    require(len(proc.stdout) <= 8 * 1024 * 1024, 'metadata_too_large')
    return proc.stdout.decode('utf-8')

def control_fields(text):
    fields = {}
    previous = None
    for line in text.splitlines():
        if not line:
            continue
        if line[0].isspace():
            require(previous is not None, 'control_continuation')
            fields[previous] += ' ' + line.strip()
            continue
        match = re.fullmatch(r'([A-Za-z0-9][A-Za-z0-9-]*):[ \t]*(.*)', line)
        require(match is not None, 'invalid_control_line')
        key, value = match.groups()
        key = key.lower()
        require(key not in fields, 'duplicate_control_field_' + key)
        fields[key] = value
        previous = key
    return fields

def validate_control(path, expected):
    fields = control_fields(command(['dpkg-deb', '--field', path]))
    require(fields.get('package') == expected, 'package_identity_' + expected)
    require(fields.get('version') == target + 'ubuntu1', 'package_version_' + expected)
    require(fields.get('architecture') == 'amd64', 'package_architecture_' + expected)
    # Binary dependency fields contain comma-separated groups and alternatives.
    # The package-name token is enough to reject Python 2 edges; APT remains the
    # authority for dependency satisfaction, alternatives and Debian versions.
    for field in ('depends', 'pre-depends'):
        value = fields.get(field, '').strip()
        if not value:
            continue
        for alternative in re.split(r'\s*[,|]\s*', value):
            atom = re.fullmatch(
                r'([a-z0-9][a-z0-9+.-]*)(?::[a-z0-9-]+)?'
                r'(?:\s*\(\s*(?:<<|<=|=|>=|>>)\s*[^()\s]+\s*\))?',
                alternative)
            require(atom is not None, 'dependency_syntax_' + expected)
            name = atom.group(1)
            require(not (name == 'python' or name.startswith('python2')
                         or name.startswith('python-')
                         or name.startswith('libpython2')),
                    'legacy_python_dependency_' + expected + '_' + name)
    return fields

def validate_consumers(target_controls, tmp):
    # This proves compatibility of packages that remain installed with the
    # replacement identities. It is NOT the final target dependency check:
    # target Python 3 Depends/Pre-Depends are deliberately absent in this copy,
    # because their installation happens later. All other package records and
    # target Provides/Conflicts/Breaks/Replaces retain their normal APT meaning.
    with open(status_path, 'rb') as source:
        original = source.read(64 * 1024 * 1024 + 1)
    require(len(original) <= 64 * 1024 * 1024, 'status_too_large')
    require(b'\x00' not in original and b'\r' not in original, 'status_format')
    original_hash = hashlib.sha256(original).digest()
    legacy_packages = set(children) | {'aella-uvp'}
    retained = []
    seen_legacy = set()
    legacy_versions = set()
    seen = set()
    for record in original.split(b'\n\n'):
        if not record.strip():
            retained.append(record)
            continue
        fields = control_fields(record.decode('utf-8'))
        package = fields.get('package', '')
        identity = (package, fields.get('architecture', ''))
        require(package and identity not in seen, 'duplicate_or_missing_status_package')
        seen.add(identity)
        if package == meta:
            require(fields.get('status') in ('deinstall ok config-files',
                    'purge ok not-installed', 'deinstall ok not-installed'),
                    'projection_new_product_present')
            continue
        if package not in legacy_packages:
            retained.append(record)
            continue
        require(package not in seen_legacy, 'projection_legacy_multiarch')
        require(fields.get('architecture') == 'amd64'
                and fields.get('status') == 'install ok installed',
                'projection_legacy_package_state')
        require(re.fullmatch(r'6\.[234]\.[0-9]+ubuntu[0-9]+',
                             fields.get('version', '')) is not None,
                'projection_legacy_package_version')
        legacy_versions.add(fields['version'])
        seen_legacy.add(package)
    require(seen_legacy == legacy_packages and len(legacy_versions) == 1,
            'projection_legacy_generation_incomplete_or_mixed')
    for package in packages:
        fields = dict(target_controls[package])
        fields.pop('depends', None)
        fields.pop('pre-depends', None)
        fields['status'] = 'install ok installed'
        retained.append('\n'.join('%s: %s' % item for item in fields.items()).encode('utf-8'))
    shadow = os.path.join(tmp, 'consumer-status')
    with open(shadow, 'xb') as output:
        output.write(b'\n\n'.join(retained) + b'\n')
    result = subprocess.run([
        'apt-get', '-o', 'Debug::NoLocking=true',
        '-o', 'Dir::State::status=' + shadow,
        '-o', 'Dir::Cache::pkgcache=', '-o', 'Dir::Cache::srcpkgcache=',
        'check'], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=env, timeout=60)
    if result.returncode != 0:
        # Keep APT's precise external dependency/conflict explanation visible.
        for detail in (result.stdout, result.stderr):
            if detail:
                sys.stderr.write(detail[:65536].decode('utf-8', 'replace'))
        raise Invalid('replacement_consumer_graph_rc_' + str(result.returncode))
    with open(status_path, 'rb') as source:
        current = source.read(64 * 1024 * 1024 + 1)
    require(hashlib.sha256(current).digest() == original_hash, 'status_changed')
    print('PRODUCT_REPLACEMENT_CONSUMERS=PASS target=%s target_depends=deferred_to_uvp' % target)

def artifact_metadata():
    require(os.path.isfile(artifact), 'artifact_missing')
    target_controls = {meta: validate_control(artifact, meta)}
    wanted = {'opt/aelladata/aelladeb/' + p + '_' + target + 'ubuntu1_amd64.deb': p
              for p in children}
    # Stream the payload, copy only six regular .deb members to private filenames.
    # Never extract paths from the archive, follow links, or run postinst scripts.
    with tempfile.TemporaryDirectory(prefix='phase2-product-metadata.') as tmp:
        found = {}
        total = 0
        count = 0
        with tempfile.TemporaryFile() as errors:
            proc = subprocess.Popen(['dpkg-deb', '--fsys-tarfile', artifact],
                                    stdout=subprocess.PIPE, stderr=errors, env=env)
            try:
                with tarfile.open(fileobj=proc.stdout, mode='r|') as archive:
                    for member in archive:
                        count += 1
                        require(count <= 100000, 'too_many_archive_members')
                        require(member.size >= 0, 'negative_member_size')
                        total += member.size
                        require(total <= 1024 * 1024 * 1024, 'payload_too_large')
                        name = member.name
                        while name.startswith('./'):
                            name = name[2:]
                        require(not name.startswith('/') and '..' not in name.split('/'),
                                'unsafe_member_path')
                        if name not in wanted:
                            # The vendor installs these six basename patterns. A
                            # second version or path must not create ambiguity.
                            base = name.rsplit('/', 1)[-1]
                            require(not any(base.startswith(p + '_') and base.endswith('.deb')
                                            for p in children), 'unexpected_product_deb')
                            continue
                        package = wanted[name]
                        require(package not in found, 'duplicate_product_deb_' + package)
                        require(member.isfile(), 'nonregular_product_deb_' + package)
                        require(0 < member.size <= 512 * 1024 * 1024,
                                'product_deb_size_' + package)
                        path = os.path.join(tmp, package + '.deb')
                        source = archive.extractfile(member)
                        require(source is not None, 'unreadable_product_deb_' + package)
                        with source, open(path, 'xb') as output:
                            shutil.copyfileobj(source, output, 1024 * 1024)
                        require(os.path.getsize(path) == member.size,
                                'truncated_product_deb_' + package)
                        found[package] = path
                proc.stdout.close()
                require(proc.wait(timeout=60) == 0, 'payload_read_failed')
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait()
                if proc.stdout:
                    proc.stdout.close()
        require(set(found) == set(children), 'replacement_package_set')
        for package in children:
            target_controls[package] = validate_control(found[package], package)
        if status_path:
            validate_consumers(target_controls, tmp)

def installed_metadata():
    # A successful complete inventory distinguishes an absent old meta from a
    # failed name-specific dpkg query. It also catches duplicate architectures.
    inventory = command(['dpkg-query', '-W',
        '-f=${Package}\t${Version}\t${Architecture}\t${Status}\n'])
    found = {}
    for line in inventory.splitlines():
        parts = line.split('\t')
        require(len(parts) == 4, 'invalid_inventory_row')
        package, version, architecture, status = parts
        if package not in packages and package != 'aella-uvp':
            continue
        require(package not in found, 'duplicate_installed_package_' + package)
        found[package] = (version, architecture, status)
    old = found.get('aella-uvp')
    if old is not None:
        require(old[2] in ('deinstall ok config-files', 'purge ok not-installed',
                           'deinstall ok not-installed'), 'legacy_meta_still_present')
    for package in packages:
        require(package in found, 'installed_package_missing_' + package)
        version, architecture, status = found[package]
        require(version == target + 'ubuntu1', 'installed_version_' + package)
        require(architecture == 'amd64', 'installed_architecture_' + package)
        require(status == 'install ok installed', 'installed_status_' + package)

try:
    require(mode in ('artifact', 'installed'), 'invalid_mode')
    require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', target) is not None, 'invalid_target')
    if mode == 'artifact':
        artifact_metadata()
    else:
        installed_metadata()
    print('%s=PASS target=%s packages=7' % (prefix, target))
except (Invalid, OSError, ValueError, UnicodeError, subprocess.SubprocessError,
        tarfile.TarError) as exc:
    detail = re.sub(r'[^A-Za-z0-9_.:-]+', '_', str(exc))[:240]
    print('%s=FAIL reason=%s' % (prefix, detail or type(exc).__name__))
    sys.exit(1)
PY_PRODUCT_REPLACEMENT
  )"; then
    dp2_prereq_log INFO "$out"
    return 0
  else
    rc=$?
    dp2_prereq_log ERROR "$out"
    return "$rc"
  fi
}

dp2_validate_product_replacement_artifact() {
  # Third argument is an internal, explicit status path for the staging-only
  # reverse-consumer projection. Production callers resolve the canonical live
  # status path; no environment variable selects an alternate database.
  dp2_product_replacement_metadata artifact "$2" "$1" "${3:-}"
}

dp2_validate_installed_product_replacement() {
  # Metadata only: the caller MUST follow this with the strict unfiltered
  # dp2_validate_apt_dependency_graph uvp (or lifecycle_completion) check.
  dp2_product_replacement_metadata installed "$1"
}

# A sealed release retains its vendor script bytes. The vendor already loads
# this shared library at the start of install_python3. Arm a post-install_uvp
# guard in that running Bash process, before the vendor can reach system prep
# or start services. This is also the existing worker helper-loading path.
dp2_guarded_install_uvp() {
  local vendor_rc=0
  if [[ -z "${_DP2_VENDOR_INSTALL_UVP_DECLARATION:-}" ]] ||
     [[ "$(declare -f dp2_vendor_install_uvp)" != "$_DP2_VENDOR_INSTALL_UVP_DECLARATION" ]]; then
    dp2_prereq_log ERROR "PRODUCT_REPLACEMENT=FAIL reason=original_changed"
    exit 1
  fi
  if ! declare -F dp2_validate_installed_product_replacement >/dev/null 2>&1 ||
     ! declare -F dp2_validate_apt_dependency_graph >/dev/null 2>&1; then
    dp2_prereq_log ERROR "PRODUCT_REPLACEMENT=FAIL reason=validator_missing"
    exit 1
  fi
  # Keep this as a bare call. Putting it in `if`, `!`, or an AND/OR list would
  # disable the vendor function's errexit behavior, including nested commands.
  dp2_vendor_install_uvp "$@"
  vendor_rc=$?
  if [[ "$vendor_rc" -ne 0 ]]; then
    dp2_prereq_log ERROR "PRODUCT_REPLACEMENT=FAIL reason=vendor_install_uvp rc=${vendor_rc}"
    exit "$vendor_rc"
  fi
  if ! dp2_validate_installed_product_replacement "${VERSION:-}"; then
    dp2_prereq_log ERROR "PRODUCT_REPLACEMENT=FAIL reason=installed_packages"
    exit 1
  fi
  if ! dp2_validate_apt_dependency_graph uvp; then
    dp2_prereq_log ERROR "PRODUCT_REPLACEMENT=FAIL reason=apt_dependency_graph"
    exit 1
  fi
  dp2_prereq_log INFO "PRODUCT_REPLACEMENT=PASS"
}

dp2_arm_product_transition_guard() {
  local original wrapped renamed first_line
  # Stage/lifecycle prerequisite checks run outside the vendor Bash process.
  # There is no vendor call to wrap there; the later vendor load arms it.
  declare -F install_uvp >/dev/null 2>&1 || return 0
  if ! declare -F dp2_validate_installed_product_replacement >/dev/null 2>&1 ||
     ! declare -F dp2_validate_apt_dependency_graph >/dev/null 2>&1; then
    dp2_prereq_log ERROR "PRODUCT_TRANSITION_HOOK=FAIL reason=validator_missing"
    return 1
  fi
  original="$(declare -f install_uvp)" || return 1
  wrapped="$(declare -f dp2_guarded_install_uvp)" || return 1
  first_line="${wrapped%%$'\n'*}"
  if [[ "$first_line" != 'dp2_guarded_install_uvp () ' ]]; then
    dp2_prereq_log ERROR "PRODUCT_TRANSITION_HOOK=FAIL reason=guard_signature"
    return 1
  fi
  wrapped="install_uvp () ${wrapped#"$first_line"}"
  if [[ "$original" == "$wrapped" ]]; then
    if ! declare -F dp2_vendor_install_uvp >/dev/null 2>&1; then
      dp2_prereq_log ERROR "PRODUCT_TRANSITION_HOOK=FAIL reason=original_missing"
      return 1
    fi
    if [[ -z "${_DP2_VENDOR_INSTALL_UVP_DECLARATION:-}" ]] ||
       [[ "$(declare -f dp2_vendor_install_uvp)" != "$_DP2_VENDOR_INSTALL_UVP_DECLARATION" ]]; then
      dp2_prereq_log ERROR "PRODUCT_TRANSITION_HOOK=FAIL reason=original_changed"
      return 1
    fi
    dp2_prereq_log INFO "PRODUCT_TRANSITION_HOOK=ARMED state=existing"
    return 0
  fi
  if declare -F dp2_vendor_install_uvp >/dev/null 2>&1 ||
     [[ -n "${_DP2_VENDOR_INSTALL_UVP_DECLARATION+x}" ]]; then
    dp2_prereq_log ERROR "PRODUCT_TRANSITION_HOOK=FAIL reason=reserved_function_conflict"
    return 1
  fi
  first_line="${original%%$'\n'*}"
  if [[ "$first_line" != 'install_uvp () ' ]]; then
    dp2_prereq_log ERROR "PRODUCT_TRANSITION_HOOK=FAIL reason=vendor_signature"
    return 1
  fi
  renamed="dp2_vendor_install_uvp () ${original#"$first_line"}"
  # Only the exact declaration name of the already loaded, verified vendor
  # function changes. No shell text comes from package metadata or user input.
  if ! eval "$renamed" || ! eval "$wrapped"; then
    dp2_prereq_log ERROR "PRODUCT_TRANSITION_HOOK=FAIL reason=definition_failed"
    return 1
  fi
  if [[ "$(declare -f install_uvp)" != "$wrapped" ]] ||
     [[ "$(declare -f dp2_vendor_install_uvp)" != "$renamed" ]]; then
    dp2_prereq_log ERROR "PRODUCT_TRANSITION_HOOK=FAIL reason=definition_mismatch"
    return 1
  fi
  if ! declare -gr _DP2_VENDOR_INSTALL_UVP_DECLARATION="$renamed"; then
    dp2_prereq_log ERROR "PRODUCT_TRANSITION_HOOK=FAIL reason=original_identity"
    return 1
  fi
  dp2_prereq_log INFO "PRODUCT_TRANSITION_HOOK=ARMED state=new"
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
  dp2_arm_product_transition_guard || return 1
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
