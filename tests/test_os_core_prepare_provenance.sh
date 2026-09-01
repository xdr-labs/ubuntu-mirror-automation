#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_SKIP_ROOT_CHECK=1
export PREPARATION_MODE=FULL
export PHASE2_TARGET_VERSION=6.6.0
export OS_CORE_R2_URL="https://example.test/ubuntu-os-core/ubuntu-os-core-xenial-to-noble.tar"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_workflow_state.sh"

id1="$(mm_wf_prepare_identity_sha256)"
export OS_CORE_R2_URL="https://example.test/ubuntu-os-core/ubuntu-os-core-xenial-to-noble-v2.tar"
id2="$(mm_wf_prepare_identity_sha256)"
[[ "$id1" != "$id2" ]] || { echo "FAIL OS Core source change did not alter prepare identity"; exit 1; }

export OS_CORE_R2_URL="https://example.test/ubuntu-os-core/ubuntu-os-core-xenial-to-noble.tar"
export OS_CORE_EXPECTED_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
id3="$(mm_wf_prepare_identity_sha256)"
export OS_CORE_EXPECTED_SHA256="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
id4="$(mm_wf_prepare_identity_sha256)"
[[ "$id3" != "$id4" ]] || { echo "FAIL expected SHA change did not alter prepare identity"; exit 1; }

# Same bytes / same identity independent of local checkout path
export OS_CORE_EXPECTED_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
id5="$(mm_wf_prepare_identity_sha256)"
[[ "$id5" == "$id3" ]] || { echo "FAIL path-independent identity unstable"; exit 1; }

export PREPARATION_MODE=PHASE2_ONLY
id6="$(mm_wf_prepare_identity_sha256)"
[[ "$id6" != "$id5" ]] || { echo "FAIL mode change should alter prepare identity"; exit 1; }

echo "PASS test_os_core_prepare_provenance"
