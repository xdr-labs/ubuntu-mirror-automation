#!/usr/bin/env bash
# Current generation-bound Phase 2 staging contract fixture (B/P/H/A).
# shellcheck shell=bash

phase2_staging_write_current_not_required_contract() {
  local target="${1:-6.6.0}"
  local root prereq_dir identity f bundle_sha prereq_sha helper_sha artifact_sha
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  : "${PHASE2_STAGING_CONTRACT_ENV:?}"
  : "${PHASE2_STAGING_ARTIFACT_ROOT:?}"
  : "${PHASE2_STAGING_HELPER_MANIFEST:?}"
  : "${PHASE2_PREREQ_STATE:?}"
  prereq_dir="$(dirname "$PHASE2_PREREQ_STATE")"
  identity="${prereq_dir}/phase2-ubuntu-prerequisites.identity"
  mkdir -p "$prereq_dir" "$PHASE2_STAGING_ARTIFACT_ROOT" \
    "$(dirname "$PHASE2_STAGING_HELPER_MANIFEST")"
  cat >"$PHASE2_PREREQ_STATE" <<EOF
TARGET_DP_VERSION=${target}
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PACKAGE_COUNT=0
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=
EOF
  cat >"$identity" <<EOF
TARGET_DP_VERSION=${target}
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PUBLICATION=PASS
EOF
  printf 'fixture-phase2-helper-generation\n' >"$PHASE2_STAGING_HELPER_MANIFEST"
  for f in \
    aelladeb_py3_common.tar.gz \
    aelladeb_py3_common.tar.gz.sha1 \
    "aella-uvp-2404_${target}ubuntu1_amd64.deb" \
    "aella-uvp-2404_${target}ubuntu1_amd64.deb.sha1" \
    "images-${target}.list" \
    "images-${target}.tar" \
    "images-${target}.tar.sha256"
  do
    printf 'fixture-%s\n' "$f" >"${PHASE2_STAGING_ARTIFACT_ROOT}/$f"
  done

  # shellcheck source=/dev/null
  source "${root}/client/lib/dp-phase2-staging-contract.sh"
  bundle_sha="$(printf 'fixture-bundle-%s' "$target" | sha256sum | awk '{print $1}')"
  prereq_sha="$(sha256sum "$identity" | awk '{print $1}')"
  helper_sha="$(sha256sum "$PHASE2_STAGING_HELPER_MANIFEST" | awk '{print $1}')"
  artifact_sha="$(dp_phase2_artifact_tree_hash "$target")" || return 1
  dp_phase2_persist_staging_contract \
    "$target" "$bundle_sha" "$prereq_sha" "$helper_sha" "$artifact_sha"
}
