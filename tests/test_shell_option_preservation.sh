#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check_preserve() {
  local lib="$1"
  local label="$2"
  # With errexit enabled
  bash -c '
    set -euo pipefail
    before="$-"
    source "'"$lib"'"
    after="$-"
    [[ "$before" == *e* ]] || exit 10
    [[ "$after" == *e* ]] || exit 11
    # Call a function that historically toggled errexit, if present
    if declare -F spv_detect_from_aella_cli >/dev/null 2>&1; then
      spv_detect_from_aella_cli >/dev/null 2>&1 || true
    fi
    if declare -F dp2_prereq_assert_safe_archive >/dev/null 2>&1; then
      true
    fi
    if declare -F p2b_current_run_completion_coherent >/dev/null 2>&1; then
      p2b_current_run_completion_coherent >/dev/null 2>&1 || true
    fi
    [[ "$-" == *e* ]] || exit 12
  ' || { echo "FAIL $label with set -e"; exit 1; }

  # With errexit disabled
  bash -c '
    set +e
    set -u
    before="$-"
    source "'"$lib"'"
    [[ "$before" != *e* ]] || exit 20
    [[ "$-" != *e* ]] || exit 21
    if declare -F spv_detect_from_aella_cli >/dev/null 2>&1; then
      spv_detect_from_aella_cli >/dev/null 2>&1 || true
    fi
    [[ "$-" != *e* ]] || exit 22
  ' || { echo "FAIL $label with set +e"; exit 1; }
  echo "PASS $label"
}

check_preserve "${ROOT}/client/lib/dp-offline-source-product-version.sh" source-product
check_preserve "${ROOT}/client/lib/dp-phase2-ubuntu-prerequisites.sh" prereq
check_preserve "${ROOT}/client/lib/dp-phase2-bringup-lifecycle.sh" bringup

echo "PASS test_shell_option_preservation"
