#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=/dev/null
source "${ROOT}/lib/runtime_manifest.sh"

RUNTIME="$TMP/runtime"
um_runtime_install_tree "$ROOT" "$RUNTIME"
um_runtime_verify_dependency_closure "$RUNTIME"

# Delete each required client/runtime class one at a time and expect FAIL.
failures=0
while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  target="${RUNTIME}/${rel}"
  [[ -e "$target" ]] || continue
  # Skip one optional-looking README still required by install — all installed are required.
  bak="${target}.bak"
  mv "$target" "$bak"
  set +e
  um_runtime_verify_dependency_closure "$RUNTIME" >/dev/null 2>&1
  rc=$?
  set -e
  mv "$bak" "$target"
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL closure still PASS after deleting $rel"
    failures=$((failures + 1))
  fi
done < <(um_runtime_emit_installed_relative_paths | grep -E '^(client/stage-dp-phase2\.sh|client/lib/dp-phase2-bringup-lifecycle\.sh|client/lib/dp-offline-source-product-version\.sh|client/lib/dp-phase2-ubuntu-prerequisites\.sh|client/bringup_py3_dp_lifecycle\.sh|scripts/lib/phase2_helper_generation\.sh|scripts/lib/client_curl_source_guard\.py|scripts/lib/client_pin_payload_guard\.py)$')

[[ "$failures" -eq 0 ]] || exit 1
echo "PASS test_runtime_manifest_closure"

# Bootstrap-level runtime install must be transactional on reinstall.
# shellcheck source=/dev/null
source "${ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/bootstrap.sh"

BOOT="${TMP}/bootstrap-atomic"
export UM_PROJECT_ROOT="$ROOT"
export INSTALL_LIB_DIR="${BOOT}/runtime"
export INSTALL_BIN_DIR="${BOOT}/bin"
export INSTALL_CONF_DIR="${BOOT}/etc"
export UM_UOM_INSTALL_PATH="${BOOT}/sbin/ubuntu-offline-mirror.sh"
export BASE_PATH="${BOOT}/mirror"
export LOG_DIR="${BOOT}/logs"
mkdir -p "$INSTALL_BIN_DIR" "$INSTALL_CONF_DIR" "$BASE_PATH" "$LOG_DIR" "$(dirname "$UM_UOM_INSTALL_PATH")"

# Keep this regression focused on runtime transactionality, not client publication.
um_bootstrap_deploy_client_http_artifacts() { return 0; }

install_out="$(um_bootstrap_install_runtime 2>&1)"
printf '%s\n' "$install_out" | grep -q 'RUNTIME_ATOMIC_INSTALL=PASS' \
  || { echo "FAIL bootstrap runtime atomic install marker missing"; echo "$install_out"; exit 1; }
um_runtime_verify_dependency_closure "$INSTALL_LIB_DIR" "$INSTALL_BIN_DIR" >/dev/null
um_runtime_verify_python_dependency_closure "$INSTALL_LIB_DIR" "$ROOT" >/dev/null
[[ -x "${INSTALL_BIN_DIR}/ubuntu-offline-mirror" ]] \
  || { echo "FAIL bootstrap runtime entrypoint missing"; exit 1; }
if compgen -G "${INSTALL_LIB_DIR}.stage.*" >/dev/null || compgen -G "${INSTALL_LIB_DIR}.prev.*" >/dev/null; then
  echo "FAIL bootstrap runtime left transaction staging/previous dirs"
  exit 1
fi
echo "PASS bootstrap runtime atomic install"

# A staged-source failure must not modify an existing known-good runtime.
printf 'KNOWN_GOOD_RUNTIME=YES\n' >"${INSTALL_LIB_DIR}/.known-good-runtime"
before_hash="$(find "$INSTALL_LIB_DIR" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
orig_runtime_libs=("${UM_RUNTIME_LIB_SHELL_FILES[@]}")
UM_RUNTIME_LIB_SHELL_FILES+=(definitely-missing-runtime-source.sh)
set +e
failed_out="$(um_bootstrap_install_runtime 2>&1)"
failed_rc=$?
set -e
UM_RUNTIME_LIB_SHELL_FILES=("${orig_runtime_libs[@]}")
after_hash="$(find "$INSTALL_LIB_DIR" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
if [[ "$failed_rc" -ne 0 ]] \
  && printf '%s\n' "$failed_out" | grep -q 'RUNTIME_ATOMIC_INSTALL=FAIL reason=staged_runtime_validation' \
  && [[ "$before_hash" == "$after_hash" ]] \
  && grep -qx 'KNOWN_GOOD_RUNTIME=YES' "${INSTALL_LIB_DIR}/.known-good-runtime"; then
  echo "PASS failed staged reinstall preserves previous runtime"
else
  echo "FAIL failed staged reinstall changed previous runtime rc=${failed_rc}"
  printf '%s\n' "$failed_out" | tail -40
  exit 1
fi
if compgen -G "${INSTALL_LIB_DIR}.stage.*" >/dev/null || compgen -G "${INSTALL_LIB_DIR}.prev.*" >/dev/null; then
  echo "FAIL failed staged reinstall left transaction dirs"
  exit 1
fi
echo "PASS bootstrap runtime reinstall transaction rollback"
