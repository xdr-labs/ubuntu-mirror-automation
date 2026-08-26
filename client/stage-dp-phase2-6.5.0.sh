#!/usr/bin/env bash
# Retired: production Phase 2 target is 6.6.0. Staging 6.5.0 as the current
# target would mix generations.
set -euo pipefail

printf 'ERROR: production Phase 2 target is 6.6.0; stage-dp-phase2-6.5.0.sh is retired.\n' >&2
printf 'Use: stage-dp-phase2.sh --target-version 6.6.0\n' >&2
printf '  or: stage-dp-phase2-6.6.0.sh\n' >&2
exit 1
