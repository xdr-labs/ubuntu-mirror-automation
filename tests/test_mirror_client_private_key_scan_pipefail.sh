#!/usr/bin/env bash
# Hermetic manager readiness: no real mirrors, signing keys, or DP upgrades.
# A large client tree with private key filenames must never be incorrectly ready.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MM_HERMETIC_TEST_MODE=1
MM_PROJECT_ROOT=''
source "$ROOT/scripts/lib/mirror_manager_common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MM_PROJECT_ROOT="$TMP/project"
MM_CONFIG_DIR="$TMP/config-home"
MM_CLIENT_ROOT="$TMP/public-client"
mkdir -p "$MM_PROJECT_ROOT/client" "$MM_PROJECT_ROOT/config" "$MM_PROJECT_ROOT/scripts/lib" "$MM_CONFIG_DIR"
for f in   client/dp-offline-upgrade-xenial-to-bionic.sh.in   client/dp-offline-upgrade-bionic-to-focal.sh.in   client/dp-offline-upgrade-focal-to-jammy.sh.in   client/dp-offline-upgrade-jammy-to-noble.sh.in   client/dp-client-hop-launcher.sh.in   client/stage-dp-phase2.sh   scripts/lib/build_client_xenial_to_bionic.py   scripts/lib/build_client_bionic_to_focal.py   scripts/lib/build_client_focal_to_jammy.py   scripts/lib/build_client_jammy_to_noble.py   scripts/lib/build_client_launchers.py   scripts/lib/client_build_repository.py   scripts/lib/client_build_provenance.py   scripts/lib/atomic_dir_swap.py   scripts/lib/mirror_host_ip.sh   scripts/lib/client_mirror_gates.sh   scripts/rebuild-publish-clients.sh; do
  : > "$MM_PROJECT_ROOT/$f"
done
chmod +x "$MM_PROJECT_ROOT/scripts/rebuild-publish-clients.sh"
# Source is required inside function; this is a no-op test stub so that no
# credentials or ephemeral keys are created.
cat > "$MM_PROJECT_ROOT/scripts/lib/local_client_signing.sh" <<'STUB'
local_signing_ensure_keypair() { return 0; }
local_signing_assert_private_not_published() { return 0; }
STUB
mm_is_phase2_only() { return 0; }
mm_state_set() { :; }
mm_ok() { :; }
mm_info() { :; }
mm_error() { :; }
mm_check_client_build_prerequisites_ready || { echo 'FAIL: clean hermetic client tree rejected' >&2; exit 1; }
echo 'PASS: clean hermetic client tree ready'
for n in $(seq -w 1 4000); do : > "$MM_PROJECT_ROOT/client/test-private-${n}.gpg"; done
for ((i=0; i<12; i++)); do
  if mm_check_client_build_prerequisites_ready; then
    echo "FAIL: secret-like client tree incorrectly READY (iteration $i)" >&2
    exit 1
  fi
done
echo 'PASS: 12 large private-key tree scans fail closed'
