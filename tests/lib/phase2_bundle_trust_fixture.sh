#!/usr/bin/env bash
# tests/lib/phase2_bundle_trust_fixture.sh — tiny published bundle sidecar for wrapper tests
# shellcheck shell=bash

phase2_trust_fixture_write_bundle_sidecar() {
  local root="${1:?dp-phase2 root required}"
  local ver="${2:?version required}"
  local payload="${3:-phase2-fixture-bundle}"
  local dir="${root}/${ver}"
  local tar="${dir}/dp_bundle_${ver}-current.tar"
  local sidecar="${tar}.sha256"
  local extras="${dir}/extras"
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  mkdir -p "$dir" "$extras"
  printf '%s\n' "$payload" >"$tar"
  sha256sum "$tar" | awk -v n="dp_bundle_${ver}-current.tar" '{print $1"  "n}' >"$sidecar"
  # Wrapper pin P requires a published prerequisite identity under extras/.
  if [[ ! -f "${extras}/phase2-ubuntu-prerequisites.identity" ]]; then
    cat >"${extras}/phase2-ubuntu-prerequisites.state" <<EOF
TARGET_DP_VERSION=${ver}
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PACKAGE_COUNT=0
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=
EOF
    # shellcheck source=phase2_prereq_identity_fixture.sh
    source "${repo_root}/tests/lib/phase2_prereq_identity_fixture.sh"
    phase2_prereq_write_identity_for_extras "$extras" >/dev/null
  fi
  awk 'NF {print $1; exit}' "$sidecar"
}

phase2_trust_fixture_export_dp_phase2_root() {
  local tmp="${1:?temp dir required}"
  export MM_DP_PHASE2_ROOT="${tmp}/dp-phase2"
  mkdir -p "$MM_DP_PHASE2_ROOT"
  printf '%s\n' "$MM_DP_PHASE2_ROOT"
}
