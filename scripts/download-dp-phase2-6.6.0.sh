#!/usr/bin/env bash
# Compatibility wrapper for DP Phase 2 target artifact version 6.6.0.
# Prefer: scripts/download-dp-phase2.sh --version 6.6.0 <sync|verify|status>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERIC="${SCRIPT_DIR}/download-dp-phase2.sh"

if [[ ! -f "$GENERIC" ]]; then
  printf 'ERROR: missing canonical script %s\n' "$GENERIC" >&2
  exit 1
fi

exec bash "$GENERIC" --version 6.6.0 "$@"
