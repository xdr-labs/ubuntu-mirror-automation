#!/usr/bin/env bash
# lib/runtime_manifest.sh — single authoritative Mirror Manager installed-runtime
# file manifest. Bootstrap install, dependency closure, and test fixtures must
# all consume this file. Do not maintain parallel allowlists elsewhere.
# shellcheck shell=bash

if [[ -n "${UM_RUNTIME_MANIFEST_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
UM_RUNTIME_MANIFEST_LOADED=1

# ---------------------------------------------------------------------------
# Core lib/*.sh (sourced shell libraries; also flat-copied for legacy paths)
# ---------------------------------------------------------------------------
UM_RUNTIME_LIB_SHELL_FILES=(
  common.sh
  config.sh
  state.sh
  progress.sh
  offline.sh
  upgrade-profile.sh
  bootstrap.sh
  runtime_manifest.sh
)

# ---------------------------------------------------------------------------
# scripts/ entrypoints (executable shell)
# ---------------------------------------------------------------------------
UM_RUNTIME_SCRIPT_ENTRYPOINTS=(
  ubuntu-offline-mirror.sh
  install-dp-upgrade-mirror.sh
  rebuild-publish-clients.sh
  prepare-phase2-ubuntu-prerequisites.sh
)

# ---------------------------------------------------------------------------
# scripts/lib/*.sh (sourced shell libraries)
# ---------------------------------------------------------------------------
UM_RUNTIME_SCRIPT_LIB_SHELL=(
  mirror_manager_common.sh
  mirror_install_engine.sh
  mirror_workflow_state.sh
  r2_acquire.sh
  acps_auth.sh
  acps_acquire.sh
  dp-phase2-common.sh
  mirror_host_ip.sh
  http_publication_permissions.sh
  client_mirror_gates.sh
  local_client_signing.sh
  phase2_helper_generation.sh
)

# ---------------------------------------------------------------------------
# scripts/lib Python — import-only modules (not typically CLI entrypoints)
# ---------------------------------------------------------------------------
UM_RUNTIME_SCRIPT_LIB_PYTHON_MODULES=(
  client_build_repository.py
  client_build_provenance.py
  assert_client_executable_shebang.py
)

# ---------------------------------------------------------------------------
# scripts/lib Python — invoked via python3 <path>
# ---------------------------------------------------------------------------
UM_RUNTIME_SCRIPT_LIB_PYTHON_EXECUTABLES=(
  os_core_package.py
  atomic_dir_swap.py
  build_client_xenial_to_bionic.py
  build_client_bionic_to_focal.py
  build_client_focal_to_jammy.py
  build_client_jammy_to_noble.py
  build_client_launchers.py
  patch_dp_phase2_bringup.py
  phase2_ubuntu_prerequisites.py
  xenial_bionic_upgrade_analysis.py
  selective_mirror.py
)

# Extra files under scripts/lib/ (subdirectories). Includes Phase 2 bringup
# patch fragments that the patcher hashes into BRINGUP_PATCH_GENERATION.
UM_RUNTIME_SCRIPT_LIB_EXTRA=(
  phase2_bringup_patch/fragment_compat.sh
  phase2_bringup_patch/fragment_credential_ssh.sh
  phase2_bringup_patch/fragment_heartbeat.sh
  phase2_bringup_patch/fragment_resume.sh
  phase2_bringup_patch/README.md
)

# ---------------------------------------------------------------------------
# vendor + nginx template
# ---------------------------------------------------------------------------
UM_RUNTIME_VENDOR_FILES=(
  dp-phase2/bringup_py3_dp_after_os_upgrade.sh
  dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1
  dp-phase2/approved-upstream-bringup.sha256
)

UM_RUNTIME_TEMPLATE_FILES=(
  nginx.conf
)

# ---------------------------------------------------------------------------
# client/ templates and helpers (hop *.sh are rebuilt per host — not installed
# from git checkout as published clients)
# ---------------------------------------------------------------------------
UM_RUNTIME_CLIENT_FILES=(
  dp-offline-upgrade-xenial-to-bionic.sh.in
  dp-offline-upgrade-bionic-to-focal.sh.in
  dp-offline-upgrade-focal-to-jammy.sh.in
  dp-offline-upgrade-jammy-to-noble.sh.in
  dp-client-hop-launcher.sh.in
  dp-postboot-readiness-policy.sh.inc
  stage-dp-phase2.sh
  stage-dp-phase2-6.6.0.sh
  stage-dp-phase2-6.5.0.sh
  bringup_py3_dp_lifecycle.sh
  phase2-helper-generation.manifest
  dp-client-command-runner.sh
)

UM_RUNTIME_CLIENT_LIB_FILES=(
  dp-offline-destructive-confirmation.sh
  dp-offline-release-upgrade-reconciliation.sh
  dp-offline-apt-preflight-sandbox.sh
  dp-offline-source-product-version.sh
  dp-phase2-operation-progress.sh
  dp-phase2-bringup-lifecycle.sh
  dp-phase2-ubuntu-prerequisites.sh
  dp-offline-durable-write.sh
  dp-offline-lxd-inventory.sh
)

# Relative paths under the installed runtime root that must exist after install.
# Derived from the authoritative install arrays so install/verify cannot diverge.
# Build-only hop templates (*.sh.in) remain installed and required — builders need them.
um_runtime_emit_installed_relative_paths() {
  local f
  for f in "${UM_RUNTIME_LIB_SHELL_FILES[@]}"; do
    printf 'lib/%s\n' "$f"
  done
  for f in "${UM_RUNTIME_SCRIPT_ENTRYPOINTS[@]}"; do
    printf 'scripts/%s\n' "$f"
  done
  for f in \
    "${UM_RUNTIME_SCRIPT_LIB_SHELL[@]}" \
    "${UM_RUNTIME_SCRIPT_LIB_PYTHON_MODULES[@]}" \
    "${UM_RUNTIME_SCRIPT_LIB_PYTHON_EXECUTABLES[@]}"
  do
    printf 'scripts/lib/%s\n' "$f"
  done
  for f in "${UM_RUNTIME_SCRIPT_LIB_EXTRA[@]}"; do
    printf 'scripts/lib/%s\n' "$f"
  done
  for f in "${UM_RUNTIME_VENDOR_FILES[@]}"; do
    printf 'vendor/%s\n' "$f"
  done
  for f in "${UM_RUNTIME_TEMPLATE_FILES[@]}"; do
    printf 'templates/%s\n' "$f"
  done
  for f in "${UM_RUNTIME_CLIENT_FILES[@]}"; do
    printf 'client/%s\n' "$f"
  done
  for f in "${UM_RUNTIME_CLIENT_LIB_FILES[@]}"; do
    printf 'client/lib/%s\n' "$f"
  done
}

# shellcheck disable=SC2207
mapfile -t UM_RUNTIME_REQUIRED_RELATIVE_PATHS < <(um_runtime_emit_installed_relative_paths)

# Python modules verified via importlib against the installed scripts/lib only.
# Exported for drift tests / accessors; verifier embeds the same names.
# shellcheck disable=SC2034
UM_RUNTIME_PYTHON_IMPORT_MODULES=(
  client_build_repository
  client_build_provenance
  assert_client_executable_shebang
  atomic_dir_swap
)

# shellcheck disable=SC2034
UM_RUNTIME_BUILDER_HOPS=(
  xenial-to-bionic
  bionic-to-focal
  focal-to-jammy
  jammy-to-noble
)

# ---------------------------------------------------------------------------
# Accessors
# ---------------------------------------------------------------------------
um_runtime_script_lib_files() {
  local f
  for f in \
    "${UM_RUNTIME_SCRIPT_LIB_SHELL[@]}" \
    "${UM_RUNTIME_SCRIPT_LIB_PYTHON_MODULES[@]}" \
    "${UM_RUNTIME_SCRIPT_LIB_PYTHON_EXECUTABLES[@]}" \
    "${UM_RUNTIME_SCRIPT_LIB_EXTRA[@]}"
  do
    printf '%s\n' "$f"
  done
}

um_runtime_required_files() {
  local f
  for f in "${UM_RUNTIME_REQUIRED_RELATIVE_PATHS[@]}"; do
    printf '%s\n' "$f"
  done
}

um_runtime_python_modules() {
  local f
  for f in "${UM_RUNTIME_SCRIPT_LIB_PYTHON_MODULES[@]}"; do
    printf '%s\n' "$f"
  done
}

um_runtime_executable_python_files() {
  local f
  for f in "${UM_RUNTIME_SCRIPT_LIB_PYTHON_EXECUTABLES[@]}"; do
    printf '%s\n' "$f"
  done
}

um_runtime_all_script_lib_basenames() {
  um_runtime_script_lib_files
}

# ---------------------------------------------------------------------------
# Install helpers
# ---------------------------------------------------------------------------
_um_runtime_die() {
  local msg="$1"
  if declare -F um_die >/dev/null 2>&1; then
    um_die "$msg"
  fi
  printf '%s\n' "$msg" >&2
  return 1
}

_um_runtime_ok() {
  local msg="$1"
  if declare -F um_ok >/dev/null 2>&1; then
    um_ok "$msg"
  else
    printf 'OK: %s\n' "$msg"
  fi
}

_um_runtime_info() {
  local msg="$1"
  if declare -F um_info >/dev/null 2>&1; then
    um_info "$msg"
  else
    printf 'INFO: %s\n' "$msg"
  fi
}

# Install one file; fail with RUNTIME_SOURCE_MANIFEST evidence if missing.
um_runtime_install_one() {
  local src="$1" dest="$2" mode="${3:-0644}"
  if [[ ! -f "$src" ]]; then
    printf 'RUNTIME_SOURCE_MANIFEST=FAIL\n'
    printf 'RUNTIME_SOURCE_FILE_MISSING=%s\n' "$src"
    printf 'INSTALL_RESULT=FAIL\n'
    _um_runtime_die "RUNTIME_SOURCE_MANIFEST=FAIL RUNTIME_SOURCE_FILE_MISSING=${src} INSTALL_RESULT=FAIL"
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest" 2>/dev/null; then
    chmod "$mode" "$dest" 2>/dev/null || true
    return 0
  fi
  install -m "$mode" "$src" "$dest"
}

# Copy authoritative runtime tree from src_root into dest runtime root.
# Does NOT create bin links, conf, or deploy HTTP client artifacts.
um_runtime_install_tree() {
  local src_root="$1"
  local runtime="$2"
  local f mode

  mkdir -p \
    "${runtime}/lib" \
    "${runtime}/scripts/lib" \
    "${runtime}/vendor/dp-phase2" \
    "${runtime}/templates" \
    "${runtime}/client/lib" \
    "${runtime}/config/client-signing"

  for f in "${UM_RUNTIME_LIB_SHELL_FILES[@]}"; do
    um_runtime_install_one "${src_root}/lib/${f}" "${runtime}/lib/${f}" 0644
    um_runtime_install_one "${src_root}/lib/${f}" "${runtime}/${f}" 0644
  done

  for f in "${UM_RUNTIME_SCRIPT_ENTRYPOINTS[@]}"; do
    um_runtime_install_one \
      "${src_root}/scripts/${f}" \
      "${runtime}/scripts/${f}" 0755
  done

  for f in "${UM_RUNTIME_SCRIPT_LIB_SHELL[@]}"; do
    um_runtime_install_one \
      "${src_root}/scripts/lib/${f}" \
      "${runtime}/scripts/lib/${f}" 0644
  done

  for f in \
    "${UM_RUNTIME_SCRIPT_LIB_PYTHON_MODULES[@]}" \
    "${UM_RUNTIME_SCRIPT_LIB_PYTHON_EXECUTABLES[@]}"
  do
    mode=0644
    [[ "$f" == "os_core_package.py" ]] && mode=0755
    um_runtime_install_one \
      "${src_root}/scripts/lib/${f}" \
      "${runtime}/scripts/lib/${f}" "$mode"
  done

  for f in "${UM_RUNTIME_SCRIPT_LIB_EXTRA[@]}"; do
    mkdir -p "$(dirname "${runtime}/scripts/lib/${f}")"
    um_runtime_install_one \
      "${src_root}/scripts/lib/${f}" \
      "${runtime}/scripts/lib/${f}" 0644
  done

  for f in "${UM_RUNTIME_VENDOR_FILES[@]}"; do
    mode=0644
    [[ "$f" == *.sh ]] && mode=0755
    um_runtime_install_one \
      "${src_root}/vendor/${f}" \
      "${runtime}/vendor/${f}" "$mode"
  done

  for f in "${UM_RUNTIME_TEMPLATE_FILES[@]}"; do
    um_runtime_install_one \
      "${src_root}/templates/${f}" \
      "${runtime}/templates/${f}" 0644
  done

  for f in "${UM_RUNTIME_CLIENT_FILES[@]}"; do
    mode=0644
    [[ "$f" == *.sh ]] && mode=0755
    um_runtime_install_one \
      "${src_root}/client/${f}" \
      "${runtime}/client/${f}" "$mode"
  done

  for f in "${UM_RUNTIME_CLIENT_LIB_FILES[@]}"; do
    um_runtime_install_one \
      "${src_root}/client/lib/${f}" \
      "${runtime}/client/lib/${f}" 0644
  done

  _um_runtime_ok "RUNTIME_MANIFEST_INSTALL=PASS"
}

# Verify destination runtime has every required relative path.
# Optional second arg: bindir for ubuntu-offline-mirror link check.
um_runtime_verify_dependency_closure() {
  local runtime="$1"
  local bindir="${2:-}"
  local f rel missing=()

  for rel in "${UM_RUNTIME_REQUIRED_RELATIVE_PATHS[@]}"; do
    f="${runtime}/${rel}"
    [[ -e "$f" ]] || missing+=("$rel")
  done
  if [[ -n "$bindir" ]]; then
    [[ -e "${bindir}/ubuntu-offline-mirror" ]] \
      || missing+=("bin/ubuntu-offline-mirror")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'RUNTIME_DEPENDENCY_CLOSURE=FAIL\n'
    printf 'RUNTIME_DEPENDENCY_MISSING=%s\n' "${missing[0]}"
    printf 'INSTALL_RESULT=FAIL\n'
    _um_runtime_die \
      "RUNTIME_DEPENDENCY_CLOSURE=FAIL RUNTIME_DEPENDENCY_MISSING=${missing[*]} INSTALL_RESULT=FAIL"
    return 1
  fi
  _um_runtime_ok "RUNTIME_DEPENDENCY_CLOSURE=PASS"
  return 0
}

# Import-check Python modules from installed scripts/lib only (no git checkout).
um_runtime_verify_python_dependency_closure() {
  local runtime="$1"
  local exclude_repo="${2:-}"
  local lib_dir="${runtime}/scripts/lib"
  local lib_dir="${runtime}/scripts/lib"
  local out rc

  if [[ ! -d "$lib_dir" ]]; then
    printf 'RUNTIME_PYTHON_DEPENDENCY_CLOSURE=FAIL\n'
    printf 'RUNTIME_IMPORT_FAILED_MODULE=scripts/lib\n'
    printf 'RUNTIME_IMPORT_ERROR=missing scripts/lib directory\n'
    printf 'INSTALL_RESULT=FAIL\n'
    _um_runtime_die "RUNTIME_PYTHON_DEPENDENCY_CLOSURE=FAIL missing=${lib_dir}"
    return 1
  fi

  set +e
  out="$(
    UM_EXCLUDE_REPO_ROOT="$exclude_repo" python3 - "$lib_dir" <<'PY'
import importlib.util
import os
import sys

lib_dir = os.path.abspath(sys.argv[1])
exclude = os.environ.get("UM_EXCLUDE_REPO_ROOT", "").strip()
exclude_abs = os.path.abspath(exclude) if exclude else ""

def path_excluded(p):
    if not p:
        return False
    ap = os.path.abspath(p)
    if exclude_abs and (ap == exclude_abs or ap.startswith(exclude_abs + os.sep)):
        return True
    return False

# Keep interpreter/stdlib paths; drop the git checkout; prefer installed lib.
new_path = [lib_dir]
for p in sys.path:
    if not p or p == lib_dir:
        continue
    if path_excluded(p):
        continue
    new_path.append(p)
sys.path[:] = new_path

def import_module(name):
    path = os.path.join(lib_dir, name + ".py")
    if not os.path.isfile(path):
        raise ImportError("file missing: " + path)
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError("spec failed: " + path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod

try:
    for name in (
        "client_build_repository",
        "client_build_provenance",
        "assert_client_executable_shebang",
        "atomic_dir_swap",
    ):
        import_module(name)
        print("RUNTIME_MODULE_IMPORT=PASS module=" + name)
    hop_map = {
        "xenial-to-bionic": "build_client_xenial_to_bionic",
        "bionic-to-focal": "build_client_bionic_to_focal",
        "focal-to-jammy": "build_client_focal_to_jammy",
        "jammy-to-noble": "build_client_jammy_to_noble",
    }
    for hop, name in hop_map.items():
        import_module(name)
        print("RUNTIME_BUILDER_IMPORT=PASS hop=" + hop)
except Exception as exc:  # noqa: BLE001 — surface any import failure
    failed = getattr(exc, "name", None) or type(exc).__name__
    err = str(exc)
    print("RUNTIME_PYTHON_DEPENDENCY_CLOSURE=FAIL")
    print("RUNTIME_IMPORT_FAILED_MODULE=" + str(failed))
    print("RUNTIME_IMPORT_ERROR=" + err.replace("\n", " "))
    sys.exit(1)

print("RUNTIME_PYTHON_DEPENDENCY_CLOSURE=PASS")
sys.exit(0)
PY
  )"
  rc=$?
  set -e
  printf '%s\n' "$out"
  if [[ "$rc" -ne 0 ]]; then
    printf 'INSTALL_RESULT=FAIL\n'
    _um_runtime_die "RUNTIME_PYTHON_DEPENDENCY_CLOSURE=FAIL INSTALL_RESULT=FAIL"
    return 1
  fi

  # atomic_dir_swap CLI smoke (--help)
  if ! python3 "${lib_dir}/atomic_dir_swap.py" --help >/dev/null 2>&1; then
    printf 'RUNTIME_PYTHON_DEPENDENCY_CLOSURE=FAIL\n'
    printf 'RUNTIME_IMPORT_FAILED_MODULE=atomic_dir_swap\n'
    printf 'RUNTIME_IMPORT_ERROR=--help smoke failed\n'
    printf 'INSTALL_RESULT=FAIL\n'
    _um_runtime_die "RUNTIME_PYTHON_DEPENDENCY_CLOSURE=FAIL atomic_dir_swap --help"
    return 1
  fi
  _um_runtime_ok "RUNTIME_ATOMIC_SWAP_HELP=PASS"

  # rebuild-publish-clients.sh direct Python path must exist
  if [[ ! -f "${runtime}/scripts/rebuild-publish-clients.sh" ]]; then
    printf 'RUNTIME_PYTHON_DEPENDENCY_CLOSURE=FAIL\n'
    printf 'RUNTIME_IMPORT_FAILED_MODULE=rebuild-publish-clients.sh\n'
    printf 'INSTALL_RESULT=FAIL\n'
    _um_runtime_die "RUNTIME_DEPENDENCY_MISSING=scripts/rebuild-publish-clients.sh"
    return 1
  fi
  if [[ ! -f "${lib_dir}/atomic_dir_swap.py" ]]; then
    printf 'RUNTIME_DEPENDENCY_CLOSURE=FAIL\n'
    printf 'RUNTIME_DEPENDENCY_MISSING=scripts/lib/atomic_dir_swap.py\n'
    printf 'INSTALL_RESULT=FAIL\n'
    _um_runtime_die "RUNTIME_DEPENDENCY_MISSING=scripts/lib/atomic_dir_swap.py"
    return 1
  fi
  _um_runtime_ok "RUNTIME_DIRECT_SCRIPT_DEPENDENCY=PASS path=scripts/lib/atomic_dir_swap.py"

  return 0
}
