#!/usr/bin/env bash
# Hermetic regression for Mirror Manager source-tree private key guard.
# Only an artificial project root with empty dummy .gpg files is inspected.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export MM_HERMETIC_TEST_MODE=1
export MM_SKIP_ROOT_CHECK=1
export MM_PROJECT_ROOT="$tmp/project"
export MM_MIRROR_ROOT="$tmp/mirror"
export MM_CLIENT_ROOT="$tmp/mirror/client"
export MM_CONFIG_DIR="$tmp/config"
export MM_CONFIG_FILE="$tmp/config/fixture.conf"
mkdir -p "$MM_PROJECT_ROOT/client" "$MM_PROJECT_ROOT/config"   "$MM_PROJECT_ROOT/scripts/lib" "$MM_CLIENT_ROOT" "$MM_CONFIG_DIR"
for f in   client/dp-offline-upgrade-xenial-to-bionic.sh.in   client/dp-offline-upgrade-bionic-to-focal.sh.in   client/dp-offline-upgrade-focal-to-jammy.sh.in   client/dp-offline-upgrade-jammy-to-noble.sh.in   client/dp-client-hop-launcher.sh.in   scripts/lib/build_client_xenial_to_bionic.py   scripts/lib/build_client_bionic_to_focal.py   scripts/lib/build_client_focal_to_jammy.py   scripts/lib/build_client_jammy_to_noble.py   scripts/lib/build_client_launchers.py   scripts/lib/client_build_repository.py   scripts/lib/client_build_provenance.py   scripts/lib/atomic_dir_swap.py   scripts/lib/mirror_host_ip.sh   scripts/lib/local_client_signing.sh   scripts/lib/client_mirror_gates.sh   scripts/rebuild-publish-clients.sh
do
  mkdir -p "$MM_PROJECT_ROOT/$(dirname "$f")"
  : >"$MM_PROJECT_ROOT/$f"
done
chmod +x "$MM_PROJECT_ROOT/scripts/rebuild-publish-clients.sh"
# The real source-tree guard is tested; no crypto generation or network is needed.
cat >"$MM_PROJECT_ROOT/scripts/lib/local_client_signing.sh" <<'STUB'
local_signing_ensure_keypair() { return 0; }
local_signing_assert_private_not_published() { return 0; }
STUB
# shellcheck source=../scripts/lib/mirror_manager_common.sh
source "$ROOT/scripts/lib/mirror_manager_common.sh"
mm_client_mirror_url() { printf 'http://192.0.2.10\n'; }
mm_state_set() { :; }
mm_error() { :; }
mm_info() { :; }
mm_ok() { :; }
mm_is_phase2_only() { return 1; }
mm_check_client_build_prerequisites_ready ||
  { echo 'FAIL: clean fixture rejected' >&2; exit 1; }
echo 'PASS: clean fixture prerequisite succeeds'
for n in $(seq -w 1 650); do : >"$MM_PROJECT_ROOT/client/test-private-$n.gpg"; done
for ((i=0; i<12; i++)); do
  if mm_check_client_build_prerequisites_ready >/dev/null 2>&1; then
    echo "FAIL: private key filename scan allowed fixture on iteration $i" >&2
    exit 1
  fi
done
echo 'PASS: 12 rounds reject all secret-like tree filenames'
