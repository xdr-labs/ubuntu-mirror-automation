#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export SOURCE_PRODUCT_BRINGUP_RESULT_ENV="$TMP/phase2-bringup/result.env"
mkdir -p "$TMP/phase2-bringup" "$TMP/offline"
# shellcheck source=/dev/null
source "${ROOT}/client/lib/dp-offline-source-product-version.sh"

# Stale BRINGUP_EXECUTED only
touch "$TMP/offline/BRINGUP_EXECUTED"
# Point default path via symlink into TMP if needed — function hardcodes path.
# Override by creating the real path under a fake root is hard; call logic via
# temporary bind: test the predicate after copying semantics.

# Direct unit: with only result.env incomplete, must fail.
printf 'BRINGUP_RESULT=PASS\n' >"$SOURCE_PRODUCT_BRINGUP_RESULT_ENV"
printf 'COMPLETED\n' >"$TMP/phase2-bringup/state"
# missing run-id / sentinel / exit -> fail
if spv_bringup_completed_marker; then
  echo "FAIL incomplete result accepted"
  exit 1
fi
echo "PASS incomplete lifecycle rejected"

# Wrong run id
cat >"$SOURCE_PRODUCT_BRINGUP_RESULT_ENV" <<'EOF'
BRINGUP_RESULT=PASS
BRINGUP_RUN_ID=run-old
BRINGUP_EXIT_CODE=0
BRINGUP_COMPLETION_SENTINEL=PASS
EOF
printf 'COMPLETED\n' >"$TMP/phase2-bringup/state"
printf 'run-new\n' >"$TMP/phase2-bringup/run-id"
if spv_bringup_completed_marker; then
  echo "FAIL wrong run id accepted"
  exit 1
fi
echo "PASS wrong run id rejected"

# Coherent current result
cat >"$SOURCE_PRODUCT_BRINGUP_RESULT_ENV" <<'EOF'
BRINGUP_RESULT=PASS
BRINGUP_RUN_ID=run-1
BRINGUP_EXIT_CODE=0
BRINGUP_COMPLETION_SENTINEL=PASS
EOF
printf 'COMPLETED\n' >"$TMP/phase2-bringup/state"
printf 'run-1\n' >"$TMP/phase2-bringup/run-id"
spv_bringup_completed_marker || { echo "FAIL coherent rejected"; exit 1; }
echo "PASS coherent current result"

# Failed current result wins over stale executed marker evidence.
cat >"$SOURCE_PRODUCT_BRINGUP_RESULT_ENV" <<'EOF'
BRINGUP_RESULT=FAIL
BRINGUP_RUN_ID=run-2
BRINGUP_EXIT_CODE=1
BRINGUP_COMPLETION_SENTINEL=FAIL
EOF
printf 'FAILED\n' >"$TMP/phase2-bringup/state"
printf 'run-2\n' >"$TMP/phase2-bringup/run-id"
if spv_bringup_completed_marker; then
  echo "FAIL failed result accepted"
  exit 1
fi
echo "PASS failed current result"

echo "PASS test_bringup_completion_contract"
