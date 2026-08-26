#!/usr/bin/env bash
# Atomically refresh dp-phase2 release.env metadata fields without touching bundles.
# Does NOT download from ACPS, regenerate bundles, or move current/previous pointers.
# Publishes release.env as world-readable public metadata (mode 0644) for nginx.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dp-phase2-common.sh
source "${ROOT_DIR}/scripts/lib/dp-phase2-common.sh"

TARGET_DP_VERSION="${1:-6.6.0}"
if ! [[ "$TARGET_DP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "malformed TARGET_DP_VERSION=${TARGET_DP_VERSION}" >&2
  exit 1
fi
dp2_set_version "$TARGET_DP_VERSION"

ROOT="${DP_PHASE2_ROOT:-/var/spool/apt-mirror/dp-phase2}"
CURRENT="${ROOT}/${TARGET_DP_VERSION}/current"
ENV_PATH="${CURRENT}/release.env"
READY_PATH="${READY_PATH:-/var/spool/apt-mirror/selective/state/READY}"

if [[ "${DP_PHASE2_SKIP_ROOT_CHECK:-0}" != "1" ]]; then
  [[ "$(id -u)" -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
fi

[[ -L "$CURRENT" || -d "$CURRENT" ]] || { echo "missing current release: ${CURRENT}" >&2; exit 1; }
[[ -f "$ENV_PATH" ]] || { echo "missing release.env" >&2; exit 1; }

if dp2_release_has_secret "$ENV_PATH"; then
  echo "RELEASE_ENV_SECRET=FAIL existing release.env contains secret-like content" >&2
  exit 1
fi

READY_BEFORE=""
[[ -f "$READY_PATH" ]] && READY_BEFORE="$(sha256sum "$READY_PATH" | awk '{print $1}')"
BUNDLE="$(readlink -f "${CURRENT}/dp_bundle_${TARGET_DP_VERSION}-current.tar" 2>/dev/null || true)"
[[ -f "$BUNDLE" ]] || { echo "missing stable bundle" >&2; exit 1; }
BUNDLE_INODE_BEFORE="$(stat -c '%i %s' "$BUNDLE")"
CURRENT_BEFORE="$(readlink -f "$CURRENT" 2>/dev/null || true)"

tmp=""
cleanup() {
  # Use if/fi so a negative [[ ]] under set -e cannot flip a successful exit status.
  if [[ -n "${tmp:-}" && -e "$tmp" ]]; then
    rm -f -- "$tmp"
  fi
}
trap cleanup EXIT

tmp="$(mktemp "${CURRENT}/.release.env.XXXXXX")"

# Preserve existing keys; ensure explicit target fields are present/first-class.
awk -v ver="$TARGET_DP_VERSION" '
  BEGIN {
    print "TARGET_DP_VERSION=" ver
    print "PHASE2_ARTIFACT_VERSION=" ver
  }
  /^TARGET_DP_VERSION=/ { next }
  /^PHASE2_ARTIFACT_VERSION=/ { next }
  { print }
' "$ENV_PATH" >"$tmp"

# Ensure deprecated alias remains if it was present or always keep it
if ! grep -qE '^DP_PHASE2_VERSION=' "$tmp"; then
  printf 'DP_PHASE2_VERSION=%s\n' "$TARGET_DP_VERSION" >>"$tmp"
fi

if dp2_release_has_secret "$tmp"; then
  echo "RELEASE_ENV_SECRET=FAIL candidate release.env contains secret-like content" >&2
  exit 1
fi

# Reject ambiguous VERSION= keys in published metadata
if grep -Eq '^VERSION=' "$tmp"; then
  echo "RELEASE_ENV_AMBIGUOUS_VERSION=FAIL ambiguous VERSION= present" >&2
  exit 1
fi

# Required first-class fields
grep -qE "^TARGET_DP_VERSION=${TARGET_DP_VERSION}$" "$tmp" \
  || { echo "missing TARGET_DP_VERSION" >&2; exit 1; }
grep -qE "^PHASE2_ARTIFACT_VERSION=${TARGET_DP_VERSION}$" "$tmp" \
  || { echo "missing PHASE2_ARTIFACT_VERSION" >&2; exit 1; }
grep -qE "^DP_PHASE2_VERSION=${TARGET_DP_VERSION}$" "$tmp" \
  || { echo "missing DP_PHASE2_VERSION" >&2; exit 1; }
# No duplicate target keys
[[ "$(grep -cE '^TARGET_DP_VERSION=' "$tmp")" -eq 1 ]] \
  || { echo "duplicate TARGET_DP_VERSION" >&2; exit 1; }
[[ "$(grep -cE '^PHASE2_ARTIFACT_VERSION=' "$tmp")" -eq 1 ]] \
  || { echo "duplicate PHASE2_ARTIFACT_VERSION" >&2; exit 1; }

python3 - "$tmp" "$ENV_PATH" <<'PY'
import os, sys
tmp, dest = sys.argv[1:3]
if os.environ.get("DP_PHASE2_RELEASE_ENV_ATOMIC_FAIL_REPLACE") == "1":
    raise SystemExit("forced replace failure for tests")
with open(tmp, "rb") as fh:
    os.fchmod(fh.fileno(), 0o644)
    os.fsync(fh.fileno())
os.replace(tmp, dest)
dirfd = os.open(os.path.dirname(dest) or ".", os.O_RDONLY)
try:
    os.fsync(dirfd)
finally:
    os.close(dirfd)
print("RELEASE_ENV_ATOMIC=PASS")
PY

# Successful replace moved tmp onto dest; clear so EXIT trap will not remove dest.
tmp=""

mode="$(stat -c '%a' "$ENV_PATH")"
[[ "$mode" == "644" ]] || {
  echo "RELEASE_ENV_PERMISSION_CHECK=FAIL mode=${mode} expected=644" >&2
  exit 1
}
echo "RELEASE_ENV_MODE=${mode}"
echo "RELEASE_ENV_PERMISSION_CHECK=PASS"

if [[ "$(id -u)" -eq 0 ]]; then
  og="$(stat -c '%U:%G' "$ENV_PATH")"
  if [[ "$og" != "root:root" ]]; then
    echo "RELEASE_ENV_OWNER_GROUP_CHECK=FAIL owner:group=${og} expected=root:root" >&2
    echo "REFUSING automatic chown; investigate operational policy before changing ownership." >&2
    exit 1
  fi
  echo "RELEASE_ENV_OWNER_GROUP=root:root"
fi

if dp2_release_has_secret "$ENV_PATH"; then
  echo "RELEASE_ENV_SECRET=FAIL final release.env contains secret-like content" >&2
  exit 1
fi

READY_AFTER=""
[[ -f "$READY_PATH" ]] && READY_AFTER="$(sha256sum "$READY_PATH" | awk '{print $1}')"
[[ "$READY_BEFORE" == "$READY_AFTER" ]] || { echo "READY changed" >&2; exit 1; }
BUNDLE_INODE_AFTER="$(stat -c '%i %s' "$BUNDLE")"
[[ "$BUNDLE_INODE_BEFORE" == "$BUNDLE_INODE_AFTER" ]] || { echo "bundle inode/size changed" >&2; exit 1; }
CURRENT_AFTER="$(readlink -f "$CURRENT" 2>/dev/null || true)"
[[ "$CURRENT_BEFORE" == "$CURRENT_AFTER" ]] || { echo "current pointer changed" >&2; exit 1; }

# No leftover temp files in CURRENT
if compgen -G "${CURRENT}/.release.env.*" >/dev/null 2>&1; then
  echo "RELEASE_ENV_TEMP_CLEANUP=FAIL leftover .release.env.*" >&2
  ls -la "${CURRENT}/.release.env."* >&2 || true
  exit 1
fi

echo "READY_UNCHANGED=YES"
echo "BUNDLE_UNCHANGED=YES inode_size=${BUNDLE_INODE_AFTER}"
echo "CURRENT_UNCHANGED=YES path=${CURRENT_AFTER}"
echo "RELEASE_ENV=${ENV_PATH}"
grep -E '^(TARGET_DP_VERSION|PHASE2_ARTIFACT_VERSION|DP_PHASE2_VERSION|STABLE_BUNDLE_NAME|VERIFICATION_RESULT)=' "$ENV_PATH"
