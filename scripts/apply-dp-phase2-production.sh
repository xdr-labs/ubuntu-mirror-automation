#!/usr/bin/env bash
# RETIRED maintenance utility for the historical Phase 2 current/ layout.
#
# Production use is intentionally disabled. The authoritative field control
# plane is:
#   sudo ubuntu-offline-mirror mirror-manager
# followed by Menu 2 -> 3 -> 4 -> 7.
#
# This file remains only for hermetic regression coverage of old metadata/layout
# behavior. Running it requires BOTH MM_HERMETIC_TEST_MODE=1 and
# ALLOW_LEGACY_PHASE2_MAINTENANCE=1.
set -euo pipefail
set +x

if [[ "${MM_HERMETIC_TEST_MODE:-0}" != "1" \
  || "${ALLOW_LEGACY_PHASE2_MAINTENANCE:-0}" != "1" ]]; then
  echo "LEGACY_PHASE2_MAINTENANCE_DISABLED=YES utility=$(basename "$0")" >&2
  echo "This legacy current/-layout apply path is not a production control plane." >&2
  echo "Use: sudo ubuntu-offline-mirror mirror-manager" >&2
  exit 2
fi

[[ "${EUID}" -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="/var/log/ubuntu-mirror"
LOG="${LOG_DIR}/dp-phase2-sync.log"
NGINX_SITE="/etc/nginx/sites-available/apt-mirror"
READY_PATH="/var/spool/apt-mirror/selective/state/READY"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$LOG_DIR" /var/spool/apt-mirror/dp-phase2 /var/spool/apt-mirror/client

READY_BEFORE=""
[[ -f "$READY_PATH" ]] && READY_BEFORE="$(sha256sum "$READY_PATH" | awk '{print $1}')"
echo "READY_BEFORE=${READY_BEFORE}"

# shellcheck source=/dev/null
source "${ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/config.sh"
um_load_config "${ROOT}/mirror.conf"

# 1) Merge DP_PHASE2_* into installed mirror.conf if present
if [[ -f /etc/ubuntu-mirror/mirror.conf ]]; then
  um_migrate_selective_runtime_config /etc/ubuntu-mirror/mirror.conf || true
fi

# 2) Install scripts into lib dir (lightweight; does not full reinstall)
mkdir -p /usr/local/lib/ubuntu-mirror/lib /usr/local/lib/ubuntu-mirror/templates
install -m 0644 "${ROOT}/scripts/lib/dp-phase2-common.sh" /usr/local/lib/ubuntu-mirror/lib/dp-phase2-common.sh
install -m 0644 "${ROOT}/scripts/lib/acps_auth.sh" /usr/local/lib/ubuntu-mirror/lib/acps_auth.sh
install -m 0755 "${ROOT}/scripts/download-dp-phase2.sh" /usr/local/lib/ubuntu-mirror/download-dp-phase2.sh
install -m 0755 "${ROOT}/scripts/download-dp-phase2-6.6.0.sh" /usr/local/lib/ubuntu-mirror/download-dp-phase2-6.6.0.sh
install -m 0755 "${ROOT}/scripts/deploy-stage-dp-phase2-client-atomic.sh" /usr/local/lib/ubuntu-mirror/deploy-stage-dp-phase2-client-atomic.sh
install -m 0644 "${ROOT}/templates/nginx.conf" /usr/local/lib/ubuntu-mirror/templates/nginx.conf
install -m 0755 "${ROOT}/scripts/ubuntu-offline-mirror.sh" /usr/local/sbin/ubuntu-offline-mirror.sh
install -m 0755 "${ROOT}/validate.sh" /usr/local/bin/validate.sh
install -m 0644 "${ROOT}/lib/config.sh" /usr/local/lib/ubuntu-mirror/config.sh

# 3) nginx: backup + generate + test + reload (existing migrate helper)
um_migrate_nginx_selective_site
echo "NGINX_MIGRATE=PASS"

# 4) Deploy client helper (skip HTTP until bundle sync + nginx ready for /client)
SKIP_HTTP_VERIFY=1 bash "${ROOT}/scripts/deploy-stage-dp-phase2-client-atomic.sh"
# Re-verify HTTP for client helper
MIRROR_BASE="${MIRROR_BASE:-http://127.0.0.1}" SKIP_HTTP_VERIFY=0 \
  bash "${ROOT}/scripts/deploy-stage-dp-phase2-client-atomic.sh" || true

# 5) Actual ACPS sync (long-running; ~30GiB images tar)
echo "DP_PHASE2_SYNC_START log=${LOG}"
export DP_PHASE2_LOG_FILE="$LOG"
export DP_PHASE2_ROOT="/var/spool/apt-mirror/dp-phase2"
export DP_PHASE2_MIN_FREE_GIB="70"
bash "${ROOT}/scripts/download-dp-phase2.sh" --version 6.6.0 sync 2>&1 | tee -a "$LOG"

# 6) Verify + status
bash "${ROOT}/scripts/download-dp-phase2.sh" --version 6.6.0 verify | tee -a "$LOG"
bash "${ROOT}/scripts/download-dp-phase2.sh" --version 6.6.0 status | tee -a "$LOG"

# 7) HTTP checks (no full re-download of 30GiB)
for url in \
  "http://127.0.0.1/dp-phase2/6.6.0/" \
  "http://127.0.0.1/dp-phase2/6.6.0/release.env" \
  "http://127.0.0.1/dp-phase2/6.6.0/manifest.sha256" \
  "http://127.0.0.1/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar.sha256" \
  "http://127.0.0.1/client/stage-dp-phase2.sh" \
  "http://127.0.0.1/client/stage-dp-phase2.sh.sha256" \
  "http://127.0.0.1/client/stage-dp-phase2-6.6.0.sh" \
  "http://127.0.0.1/client/stage-dp-phase2-6.6.0.sh.sha256"
do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "$url" || echo 000)"
  echo "HTTP_CHECK url=${url} code=${code}"
  [[ "$code" == "200" ]] || { echo "HTTP_CHECK=FAIL ${url}" >&2; exit 1; }
done

# HEAD + Content-Length for stable bundle
local_bundle="/var/spool/apt-mirror/dp-phase2/6.6.0/current/dp_bundle_6.6.0-current.tar"
local_size="$(stat -c%s "$local_bundle")"
hdr="$(curl -sS -I --max-time 60 "http://127.0.0.1/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar" | tr -d '\r')"
echo "$hdr" | grep -qi 'HTTP/.*200\|HTTP/.*206' || { echo "BUNDLE_HEAD=FAIL" >&2; exit 1; }
remote_len="$(echo "$hdr" | awk -F': ' 'tolower($1)=="content-length"{print $2; exit}')"
echo "BUNDLE_SIZE_LOCAL=${local_size}"
echo "BUNDLE_SIZE_HTTP=${remote_len}"
[[ "$local_size" == "$remote_len" ]] || { echo "BUNDLE_SIZE_MISMATCH=FAIL" >&2; exit 1; }

# Range request smoke
range_code="$(curl -sS -o /dev/null -w '%{http_code}' -H 'Range: bytes=0-1023' --max-time 30 \
  "http://127.0.0.1/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar" || echo 000)"
echo "RANGE_CHECK code=${range_code}"
[[ "$range_code" == "206" || "$range_code" == "200" ]] || { echo "RANGE_CHECK=FAIL" >&2; exit 1; }

READY_AFTER=""
[[ -f "$READY_PATH" ]] && READY_AFTER="$(sha256sum "$READY_PATH" | awk '{print $1}')"
echo "READY_AFTER=${READY_AFTER}"
[[ "$READY_BEFORE" == "$READY_AFTER" ]] || { echo "READY_CHANGED=FAIL" >&2; exit 1; }
echo "READY_UNCHANGED=YES"
echo "DP_BRINGUP_EXECUTED=NO"
echo "APPLY_DP_PHASE2=PASS"
