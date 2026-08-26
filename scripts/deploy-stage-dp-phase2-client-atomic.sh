#!/usr/bin/env bash
# Atomic publish of the complete Phase 2 client helper unit to
# /var/spool/apt-mirror/client/ (or DEST_ROOT).
#
# Publishes:
#   stage-dp-phase2.sh (+ .sha256)
#   stage-dp-phase2-6.6.0.sh (+ .sha256)
#   stage-dp-phase2-6.5.0.sh (+ .sha256, retired fail-closed shim)
#   bringup_py3_dp_lifecycle.sh (+ .sha256)
#   lib/dp-offline-source-product-version.sh
#   lib/dp-phase2-operation-progress.sh
#   lib/dp-phase2-bringup-lifecycle.sh
#   lib/dp-phase2-ubuntu-prerequisites.sh
#   phase2-helper-generation.manifest
#
# Does NOT touch selective READY, OS upgrade client manifests, Phase 2 bundles,
# or nginx reload unless HTTP verify requires an already-published /client/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/mirror_host_ip.sh
source "${ROOT}/scripts/lib/mirror_host_ip.sh"
# shellcheck source=lib/phase2_helper_generation.sh
source "${ROOT}/scripts/lib/phase2_helper_generation.sh"
DEST_ROOT="${DEST_ROOT:-/var/spool/apt-mirror/client}"
READY_PATH="${READY_PATH:-/var/spool/apt-mirror/selective/state/READY}"
SKIP_HTTP_VERIFY="${SKIP_HTTP_VERIFY:-0}"
MIRROR_BASE="${RESOLVED_MIRROR_BASE_URL:-${MIRROR_BASE:-}}"
MIRROR_BASE="${MIRROR_BASE%/}"
if [[ -z "$MIRROR_BASE" && "$SKIP_HTTP_VERIFY" != "1" ]]; then
  mirror_host_resolve_and_log || exit 1
  MIRROR_BASE="${RESOLVED_MIRROR_BASE_URL%/}"
fi

# Relative paths under client/. Scripts with sidecars first; lib helpers follow.
PHASE2_CLIENT_UNIT_SCRIPTS=(
  stage-dp-phase2.sh
  stage-dp-phase2-6.6.0.sh
  stage-dp-phase2-6.5.0.sh
  bringup_py3_dp_lifecycle.sh
)
PHASE2_CLIENT_UNIT_LIBS=(
  lib/dp-offline-source-product-version.sh
  lib/dp-phase2-operation-progress.sh
  lib/dp-phase2-bringup-lifecycle.sh
  lib/dp-phase2-ubuntu-prerequisites.sh
)

[[ "$(id -u)" -eq 0 || "${DP_PHASE2_SKIP_ROOT_CHECK:-0}" == "1" ]] || {
  echo "must run as root" >&2
  exit 1
}

deploy_script_with_sidecar() {
  local name="$1"
  local src="${ROOT}/client/${name}"
  [[ -f "$src" ]] || { echo "missing ${src}" >&2; exit 1; }
  bash -n "$src" || { echo "bash -n failed: ${name}" >&2; exit 1; }

  # Reject an actual external Stellar Cyber URL, but allow guard code that
  # contains the hostname only to refuse such URLs at runtime.
  if grep -Ev '^[[:space:]]*#' "$src" | grep -Eiq 'https?://[^[:space:]]*stellarcyber\.ai([/:]|$)'; then
    echo "REFUSE: helper contains an external Stellar Cyber URL: ${name}" >&2
    exit 1
  fi
  # Wrapper may only exec; canonical must declare BRINGUP_EXECUTED=NO
  if [[ "$name" == "stage-dp-phase2.sh" ]]; then
    grep -Eq '^[[:space:]]*BRINGUP_EXECUTED[[:space:]]*=[[:space:]]*"?NO"?[[:space:]]*$' "$src" || {
      echo "missing valid BRINGUP_EXECUTED=NO assignment" >&2
      exit 1
    }
    if grep -Eq '^[[:space:]]*BRINGUP_EXECUTED[[:space:]]*=[[:space:]]*"?YES"?[[:space:]]*$' "$src"; then
      echo "REFUSE: BRINGUP_EXECUTED=YES assignment present" >&2
      exit 1
    fi
    grep -Eq '^DEFAULT_MIRROR_URL=""$' "$src" || {
      echo "REFUSE: stage helper must not carry a built-in mirror address" >&2
      exit 1
    }
    if grep -Eq -- 'chown[[:space:]]+aella:aella|install[[:space:]]+-o[[:space:]]+aella|[[:space:]]-g[[:space:]]+aella[[:space:]]+-m' "$src"; then
      echo "REFUSE: literal aella group ownership present" >&2
      exit 1
    fi
    if grep -Eq '^VERSION=|^[[:space:]]*VERSION=' "$src"; then
      echo "REFUSE: ambiguous VERSION= assignment present" >&2
      exit 1
    fi
  fi

  mkdir -p "$DEST_ROOT"
  local sha stamp dest side tmp sidetmp
  sha="$(sha256sum "$src" | awk '{print $1}')"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="${DEST_ROOT}/${name}"
  side="${dest}.sha256"
  tmp="${dest}.tmp.$$"
  sidetmp="${side}.tmp.$$"

  if [[ -f "$dest" ]]; then
    cp -a "$dest" "${dest}.bak-${stamp}"
  fi
  if [[ -f "$side" ]]; then
    cp -a "$side" "${side}.bak-${stamp}"
  fi

  cp -a "$src" "$tmp"
  chmod 0755 "$tmp"
  printf '%s  %s\n' "$sha" "$name" >"$sidetmp"
  chmod 0644 "$sidetmp"

  python3 - "$tmp" "$dest" "$sidetmp" "$side" <<'PY'
import os, sys
tmp, dest, sidetmp, side = sys.argv[1:5]
for path in (tmp, sidetmp):
    with open(path, "rb") as fh:
        os.fsync(fh.fileno())
os.replace(tmp, dest)
os.replace(sidetmp, side)
parent = os.path.dirname(dest) or "."
dirfd = os.open(parent, os.O_RDONLY)
try:
    os.fsync(dirfd)
finally:
    os.close(dirfd)
print("ATOMIC_DEPLOY=PASS")
print("DEST=" + dest)
print("SIDECAR=" + side)
PY
  echo "ARTIFACT_SHA256=${sha} name=${name}"
}

deploy_lib_helper() {
  local rel="$1"
  local src="${ROOT}/client/${rel}"
  local dest="${DEST_ROOT}/${rel}"
  local tmp stamp
  [[ -f "$src" ]] || { echo "missing ${src}" >&2; exit 1; }
  if [[ ! -s "$src" ]]; then
    echo "REFUSE: empty payload: ${rel}" >&2
    exit 1
  fi
  # Reject HTTP error pages; inspect only the file head so shell source that
  # mentions HTML detectors is not false-positive rejected.
  if head -c 256 "$src" | tr -d '\0' | grep -qiE '<!DOCTYPE[[:space:]]*html|<html[[:space:]]|<html>'; then
    echo "REFUSE: invalid shell payload: ${rel}" >&2
    exit 1
  fi
  bash -n "$src" || { echo "bash -n failed: ${rel}" >&2; exit 1; }
  mkdir -p "$(dirname "$dest")"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ -f "$dest" ]]; then
    cp -a "$dest" "${dest}.bak-${stamp}"
  fi
  tmp="${dest}.tmp.$$"
  cp -a "$src" "$tmp"
  chmod 0755 "$tmp"
  python3 - "$tmp" "$dest" <<'PY'
import os, sys
tmp, dest = sys.argv[1:3]
with open(tmp, "rb") as fh:
    os.fsync(fh.fileno())
os.replace(tmp, dest)
parent = os.path.dirname(dest) or "."
dirfd = os.open(parent, os.O_RDONLY)
try:
    os.fsync(dirfd)
finally:
    os.close(dirfd)
print("ATOMIC_DEPLOY=PASS")
print("DEST=" + dest)
PY
  echo "ARTIFACT_SHA256=$(sha256sum "$dest" | awk '{print $1}') name=${rel}"
}

READY_BEFORE=""
[[ -f "$READY_PATH" ]] && READY_BEFORE="$(sha256sum "$READY_PATH" | awk '{print $1}')"

for h in "${PHASE2_CLIENT_UNIT_SCRIPTS[@]}"; do
  deploy_script_with_sidecar "$h"
done
for h in "${PHASE2_CLIENT_UNIT_LIBS[@]}"; do
  deploy_lib_helper "$h"
done

phase2_helper_generation_write "$DEST_ROOT" >/dev/null
echo "ARTIFACT_SHA256=$(sha256sum "${DEST_ROOT}/${PHASE2_HELPER_GENERATION_MANIFEST_NAME}" | awk '{print $1}') name=${PHASE2_HELPER_GENERATION_MANIFEST_NAME}"
if [[ -z "$MIRROR_BASE" ]]; then
  echo "PHASE2_UPGRADE_WRAPPER=FAIL reason=mirror_missing" >&2
  exit 1
fi
phase2_upgrade_wrapper_write "$DEST_ROOT" "$MIRROR_BASE" \
  "${TARGET_DP_VERSION:-6.6.0}" >/dev/null
echo "ARTIFACT_SHA256=$(sha256sum "${DEST_ROOT}/upgrade-phase2.sh" | awk '{print $1}') name=upgrade-phase2.sh"

# Leave no partial temp files behind.
find "$DEST_ROOT" -maxdepth 3 -type f \( -name '*.tmp.*' -o -name '.dp2-*.XXXXXX' \) -delete 2>/dev/null || true

READY_AFTER=""
[[ -f "$READY_PATH" ]] && READY_AFTER="$(sha256sum "$READY_PATH" | awk '{print $1}')"
if [[ -n "$READY_BEFORE" && "$READY_BEFORE" != "$READY_AFTER" ]]; then
  echo "READY changed unexpectedly" >&2
  exit 1
fi
echo "READY_UNCHANGED=YES"
echo "PHASE2_CLIENT_UNIT_DEPLOY=PASS"

if [[ "$SKIP_HTTP_VERIFY" == "1" ]]; then
  echo "HTTP_VERIFY=SKIPPED"
  exit 0
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
for h in "${PHASE2_CLIENT_UNIT_SCRIPTS[@]}"; do
  local_sha="$(sha256sum "${DEST_ROOT}/${h}" | awk '{print $1}')"
  curl -fsS -o "${TMPD}/${h}" "${MIRROR_BASE}/client/${h}"
  http_sha="$(sha256sum "${TMPD}/${h}" | awk '{print $1}')"
  [[ "$http_sha" == "$local_sha" ]] || { echo "HTTP SHA mismatch for ${h}" >&2; exit 1; }
  curl -fsS -o "${TMPD}/${h}.sha256" "${MIRROR_BASE}/client/${h}.sha256"
  http_side="$(awk '{print $1}' "${TMPD}/${h}.sha256")"
  [[ "$http_side" == "$local_sha" ]] || { echo "HTTP sidecar mismatch for ${h}" >&2; exit 1; }
  echo "HTTP_VERIFY=PASS name=${h} sha256=${http_sha}"
done
for h in "${PHASE2_CLIENT_UNIT_LIBS[@]}"; do
  local_sha="$(sha256sum "${DEST_ROOT}/${h}" | awk '{print $1}')"
  curl -fsS -o "${TMPD}/$(basename "$h")" "${MIRROR_BASE}/client/${h}"
  http_sha="$(sha256sum "${TMPD}/$(basename "$h")" | awk '{print $1}')"
  [[ "$http_sha" == "$local_sha" ]] || { echo "HTTP SHA mismatch for ${h}" >&2; exit 1; }
  echo "HTTP_VERIFY=PASS name=${h} sha256=${http_sha}"
done
man="${PHASE2_HELPER_GENERATION_MANIFEST_NAME}"
local_sha="$(sha256sum "${DEST_ROOT}/${man}" | awk '{print $1}')"
curl -fsS -o "${TMPD}/${man}" "${MIRROR_BASE}/client/${man}"
http_sha="$(sha256sum "${TMPD}/${man}" | awk '{print $1}')"
[[ "$http_sha" == "$local_sha" ]] || { echo "HTTP SHA mismatch for ${man}" >&2; exit 1; }
echo "HTTP_VERIFY=PASS name=${man} sha256=${http_sha}"
local_sha="$(sha256sum "${DEST_ROOT}/upgrade-phase2.sh" | awk '{print $1}')"
curl -fsS -o "${TMPD}/upgrade-phase2.sh" "${MIRROR_BASE}/client/upgrade-phase2.sh"
http_sha="$(sha256sum "${TMPD}/upgrade-phase2.sh" | awk '{print $1}')"
[[ "$http_sha" == "$local_sha" ]] || { echo "HTTP SHA mismatch for upgrade-phase2.sh" >&2; exit 1; }
echo "HTTP_VERIFY=PASS name=upgrade-phase2.sh sha256=${http_sha}"
