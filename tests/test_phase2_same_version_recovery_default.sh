#!/usr/bin/env bash
# Prove normal upgrade-phase2.sh does not force --same-version-recovery,
# while an explicit recovery wrapper remains gated.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/phase2_helper_generation.sh"

CLIENT="${TMP}/client"
mkdir -p "$CLIENT/lib"
cp -a "${ROOT}/client/stage-dp-phase2.sh" "$CLIENT/"
cp -a "${ROOT}/client/bringup_py3_dp_lifecycle.sh" "$CLIENT/"
cp -a "${ROOT}/client/phase2-helper-generation.manifest" "$CLIENT/"
cp -a "${ROOT}/client/lib/"*.sh "$CLIENT/lib/"
# Refresh manifest hashes for the copied tree
(
  cd "$CLIENT"
  {
    sha256sum stage-dp-phase2.sh
    sha256sum bringup_py3_dp_lifecycle.sh
    sha256sum lib/dp-offline-source-product-version.sh
    sha256sum lib/dp-phase2-operation-progress.sh
    sha256sum lib/dp-phase2-bringup-lifecycle.sh
    sha256sum lib/dp-phase2-ubuntu-prerequisites.sh
  } >phase2-helper-generation.manifest
)

phase2_upgrade_wrapper_write "$CLIENT" "http://192.0.2.50" "6.6.0" \
  >/dev/null

wrap="${CLIENT}/upgrade-phase2.sh"
rec="${CLIENT}/upgrade-phase2-same-version-recovery.sh"
[[ -f "$wrap" && -f "$rec" ]] || { echo "FAIL wrappers missing"; exit 1; }

grep -Fq 'sudo bash "./$SCRIPT" --target-version "$VER" --mirror-url "$MIRROR"' "$wrap" \
  || { echo "FAIL normal invocation missing"; exit 1; }
if grep -E 'sudo bash.*"\$SCRIPT".*--same-version-recovery' "$wrap" >/dev/null 2>&1; then
  echo "FAIL normal wrapper forces recovery"
  exit 1
fi
grep -Fq 'CONFIRM_SAME_VERSION_RECOVERY=YES' "$rec" \
  || { echo "FAIL recovery gate missing"; exit 1; }
grep -Fq -- '--same-version-recovery' "$rec" \
  || { echo "FAIL recovery flag missing from explicit wrapper"; exit 1; }

set +e
out="$(bash "$wrap" --target-version 6.5.0 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL target override accepted"; exit 1; }
echo "$out" | grep -qi 'protected option' || { echo "FAIL target override message"; exit 1; }

set +e
out="$(bash "$wrap" --mirror-url http://evil 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL mirror override accepted"; exit 1; }

set +e
out="$(CONFIRM_SAME_VERSION_RECOVERY= bash "$rec" 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL recovery without confirm"; exit 1; }

echo "PASS test_phase2_same_version_recovery_default"
