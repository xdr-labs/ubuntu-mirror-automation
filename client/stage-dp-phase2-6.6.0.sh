#!/usr/bin/env bash
# Compatibility wrapper: stage DP Phase 2 artifacts for target version 6.6.0.
# Source DP version is NOT fixed here — pass --source-dp-version when needed.
# Does NOT execute bringup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERIC="${SCRIPT_DIR}/stage-dp-phase2.sh"

if [[ ! -f "$GENERIC" ]]; then
  printf 'ERROR: missing canonical helper %s\n' "$GENERIC" >&2
  exit 1
fi

exec bash "$GENERIC" --target-version 6.6.0 "$@"
