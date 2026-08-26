#!/usr/bin/env bash
# Retired: production Phase 2 target is 6.6.0. A 6.5.0-named wrapper must not
# download or publish 6.5.0 target artifacts.
set -euo pipefail

printf 'ERROR: production Phase 2 target is 6.6.0; download-dp-phase2-6.5.0.sh is retired.\n' >&2
printf 'Use: scripts/download-dp-phase2.sh --version 6.6.0\n' >&2
printf '  or: scripts/download-dp-phase2-6.6.0.sh\n' >&2
exit 1
