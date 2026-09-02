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
  mkdir -p "$dir"
  printf '%s\n' "$payload" >"$tar"
  sha256sum "$tar" | awk -v n="dp_bundle_${ver}-current.tar" '{print $1"  "n}' >"$sidecar"
  awk 'NF {print $1; exit}' "$sidecar"
}

phase2_trust_fixture_export_dp_phase2_root() {
  local tmp="${1:?temp dir required}"
  export MM_DP_PHASE2_ROOT="${tmp}/dp-phase2"
  mkdir -p "$MM_DP_PHASE2_ROOT"
  printf '%s\n' "$MM_DP_PHASE2_ROOT"
}
