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
done < <(um_runtime_emit_installed_relative_paths | grep -E '^(client/stage-dp-phase2\.sh|client/lib/dp-phase2-bringup-lifecycle\.sh|client/lib/dp-offline-source-product-version\.sh|client/lib/dp-phase2-ubuntu-prerequisites\.sh|client/bringup_py3_dp_lifecycle\.sh|scripts/lib/phase2_helper_generation\.sh)$')

[[ "$failures" -eq 0 ]] || exit 1
echo "PASS test_runtime_manifest_closure"
