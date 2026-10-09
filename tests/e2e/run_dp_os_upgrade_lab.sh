#!/usr/bin/env bash
# Destructive lab E2E guard for Phase 1 OS upgrade.
# Refuses to run without disposable-lab allowlist and explicit acknowledgments.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="${ROOT}/scripts/dp-os-upgrade-only.sh"
ALLOWLIST="/etc/dp-os-upgrade-lab-allowed"
DISPOSABLE_MARKER="/etc/dp-os-upgrade-lab-disposable"

PREFLIGHT=""
SNAPSHOT=""
APPROVAL=""
EXECUTE=0
ACK=""

usage() {
  cat <<'EOF'
Usage: sudo tests/e2e/run_dp_os_upgrade_lab.sh \
  --preflight PATH \
  [--snapshot-reference TEXT] \
  --approval-reference TEXT \
  --execute \
  --acknowledge-destructive-upgrade 'I_UNDERSTAND_THIS_OS_UPGRADE_IS_DESTRUCTIVE'

Requires:
  /etc/dp-os-upgrade-lab-allowed   (hostname listed)
  /etc/dp-os-upgrade-lab-disposable (marker file)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preflight) PREFLIGHT="${2:-}"; shift 2 ;;
    --snapshot-reference) SNAPSHOT="${2:-}"; shift 2 ;;
    --approval-reference) APPROVAL="${2:-}"; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
    --acknowledge-destructive-upgrade) ACK="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: lab E2E requires root" >&2
  exit 2
fi
if [[ ! -f "$ALLOWLIST" ]]; then
  echo "ERROR: missing $ALLOWLIST — lab E2E refused" >&2
  exit 20
fi
if [[ ! -f "$DISPOSABLE_MARKER" ]]; then
  echo "ERROR: missing disposable VM marker $DISPOSABLE_MARKER" >&2
  exit 20
fi
host="$(hostname -s 2>/dev/null || hostname)"
if ! grep -qxF "$host" "$ALLOWLIST"; then
  echo "ERROR: hostname $host not in lab allowlist" >&2
  exit 20
fi
[[ -n "$PREFLIGHT" ]] || { echo "ERROR: --preflight required" >&2; exit 2; }
[[ -n "$APPROVAL" ]] || { echo "ERROR: --approval-reference required" >&2; exit 2; }
[[ "$EXECUTE" -eq 1 ]] || { echo "ERROR: --execute required" >&2; exit 2; }
[[ "$ACK" == "I_UNDERSTAND_THIS_OS_UPGRADE_IS_DESTRUCTIVE" ]] || {
  echo "ERROR: destructive acknowledgment mismatch" >&2
  exit 2
}

echo "Lab E2E: running check then install on disposable host $host"
bash "$CLI" check --preflight "$PREFLIGHT"
# Snapshot notes are optional, never inspected or treated as proof by us.
snapshot_args=()
[[ -z "$SNAPSHOT" ]] || snapshot_args=(--snapshot-reference "$SNAPSHOT")
bash "$CLI" install \
  --preflight "$PREFLIGHT" \
  "${snapshot_args[@]}" \
  --approval-reference "$APPROVAL" \
  --execute \
  --acknowledge-destructive-upgrade "$ACK"
echo "Lab E2E install invoked. Monitor: $CLI status / logs --follow"
