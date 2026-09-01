#!/usr/bin/env bash
# HTTP 200 alone is insufficient when publication generation mismatches.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_SKIP_ROOT_CHECK=1
export MM_MIRROR_ROOT="$TMP/mirror"
export MM_CLIENT_ROOT="$TMP/client"
export MM_DP_PHASE2_ROOT="$TMP/dp-phase2"
export MM_SELECTIVE_ROOT="$TMP/selective"
export MM_CONFIG_DIR="$TMP/etc"
export MM_STATUS_FILE="$TMP/etc/status"
export MM_STATE_DIR="$TMP/state"
export PREPARATION_MODE=PHASE2_ONLY
export TARGET_DP_VERSION=6.6.0
mkdir -p "$MM_CLIENT_ROOT" "$MM_CONFIG_DIR" "$MM_STATE_DIR"

printf 'wrap\n' >"$MM_CLIENT_ROOT/upgrade-phase2.sh"
printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  upgrade-phase2.sh\n' \
  >"$MM_CLIENT_ROOT/upgrade-phase2.sh.sha256"

LIVE_ENV="$TMP/live-client-set.env"
cat >"$LIVE_ENV" <<'EOF'
CLIENT_SET_GENERATION_ID=gen-live-1
CLIENT_BUILD_INPUT_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
EOF
LIVE_SHA="$TMP/live-upgrade-phase2.sh.sha256"
printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  upgrade-phase2.sh\n' \
  >"$LIVE_SHA"

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"

# Fixture: HTTP fetch returns live publication bytes (200-equivalent body).
mm_http_fetch_text() {
  local url="$1"
  case "$url" in
    */client/client-set.env) cat "$LIVE_ENV" ;;
    */client/upgrade-phase2.sh.sha256) cat "$LIVE_SHA" ;;
    *) printf '' ;;
  esac
}

mm_status_set HTTP_PUBLICATION_GENERATION_ID "gen-live-1"
mm_status_set CLIENT_SET_GENERATION_ID "gen-live-1"

mm_http_publication_identity_ok || { echo "FAIL matching generation"; exit 1; }
echo "PASS matching publication generation"

# Stale expected generation while HTTP still serves gen-live-1
mm_status_set HTTP_PUBLICATION_GENERATION_ID "gen-stale"
if mm_http_publication_identity_ok; then
  echo "FAIL stale generation accepted"
  exit 1
fi
echo "STALE_HTTP_GENERATION_DETECTED=YES"

# HTTP 200 with wrong wrapper sha is also insufficient
mm_status_set HTTP_PUBLICATION_GENERATION_ID "gen-live-1"
printf 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd  upgrade-phase2.sh\n' \
  >"$LIVE_SHA"
if mm_http_publication_identity_ok; then
  echo "FAIL mismatched wrapper sha accepted"
  exit 1
fi
echo "PASS mismatched wrapper identity rejected"
echo "PASS test_http_publication_identity"
