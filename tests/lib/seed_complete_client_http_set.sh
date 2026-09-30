#!/usr/bin/env bash
# Seed a synthetic HTTP client set that satisfies mm_client_files_ready /
# mm_client_launchers_ready without invoking real hop builders or signing.
# shellcheck shell=bash

seed_complete_client_http_set() {
  local root="${1:?client root required}"
  local mirror="${2:-http://192.0.2.10}"
  local fpr="${3:-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA}"
  local mode="${4:-FULL}"
  local hop launcher f sha launcher_sha wrapper keyring_sha
  local repo_root phase2_root bundle_sha prereq_sha p2h p2b p2p p2rsha
  local identity_path bundle_path bundle_sidecar actual_bundle_sha sidecar_bundle_sha

  mirror="${mirror%/}"
  fpr="$(printf '%s' "$fpr" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  mkdir -p "$root"

  for f in \
    dp-offline-upgrade-xenial-to-bionic.sh \
    dp-offline-upgrade-bionic-to-focal.sh \
    dp-offline-upgrade-focal-to-jammy.sh \
    dp-offline-upgrade-jammy-to-noble.sh \
    stage-dp-phase2.sh \
    dp-client-command-runner.sh
  do
    cat >"${root}/${f}" <<EOF
#!/bin/bash
# synthetic unit for mm_client_files_ready
echo ${f}
EOF
    chmod 0755 "${root}/${f}"
    (cd "$root" && sha256sum "$f" >"${f}.sha256")
  done

  cp -f "${root}/dp-client-command-runner.sh.sha256" "${root}/runner-manifest"
  printf 'synthetic-asc\n' >"${root}/runner-manifest.asc"
  printf 'PUB\n' >"${root}/public.gpg"
  printf '\x99\x02\x00' >"${root}/public-keyring.gpg"
  keyring_sha="$(sha256sum "${root}/public-keyring.gpg" | awk '{print $1}')"

  for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
    launcher="dp-launch-${hop}.sh"
    cat >"${root}/${launcher}" <<EOF
#!/bin/bash
HOP='${hop}'
EXPECTED_FPR='${fpr}'
EXPECTED_KEYRING_SHA256='${keyring_sha}'
EXPECTED_CLIENT_BUILD_INPUT_SHA256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
MIRROR_BASE='${mirror}'
# ${mirror}
exec "\$(dirname "\$0")/dp-client-command-runner.sh" "\$@"
EOF
    chmod 0755 "${root}/${launcher}"
    (cd "$root" && sha256sum "$launcher" >"${launcher}.sha256")
    launcher_sha="$(sha256sum "${root}/${launcher}" | awk '{print $1}')"
    wrapper="upgrade-${hop}.sh"
    cat >"${root}/${wrapper}" <<EOF
#!/bin/bash
set -euo pipefail
L='${launcher}'
MIRROR='${mirror}'
LAUNCHER_SHA256='${launcher_sha}'
W=\$(mktemp -d)
trap 'rm -rf "\$W"' EXIT
D="\${W}/\${L}.download"
curl -fsSLo "\$D" "\${MIRROR}/client/\${L}"
printf '%s  %s\\n' "\$LAUNCHER_SHA256" "\$D" | sha256sum -c -
bash "\$D"
EOF
    chmod 0755 "${root}/${wrapper}"
    (cd "$root" && sha256sum "$wrapper" >"${wrapper}.sha256")
  done

  # Production-shaped Phase 2 helper generation and trust anchors. The common
  # fixture is used by readiness/publication tests, so keep it aligned with the
  # same B/P/H contract enforced in production instead of a stale synthetic
  # wrapper that can silently bypass new required helpers.
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  phase2_root="${5:-$(dirname "$root")/dp-phase2}"
  mkdir -p "${root}/lib" "${phase2_root}/6.6.0/extras"
  cp -f "${repo_root}/client/stage-dp-phase2.sh" "${root}/stage-dp-phase2.sh"
  cp -f "${repo_root}/client/bringup_py3_dp_lifecycle.sh" "${root}/bringup_py3_dp_lifecycle.sh"
  for f in \
    dp-offline-source-product-version.sh \
    dp-phase2-operation-progress.sh \
    dp-phase2-bringup-lifecycle.sh \
    dp-phase2-ubuntu-prerequisites.sh \
    dp-phase2-time-readiness.sh \
    dp-phase2-staging-contract.sh \
    dp-phase2-post-bringup-migration.sh \
    dp-phase2-cluster-validation.sh
  do
    cp -f "${repo_root}/client/lib/${f}" "${root}/lib/${f}"
  done
  chmod 0755 "${root}/stage-dp-phase2.sh" "${root}/bringup_py3_dp_lifecycle.sh" "${root}/lib/"*.sh
  (cd "$root" && sha256sum stage-dp-phase2.sh >stage-dp-phase2.sh.sha256)

  identity_path="${phase2_root}/6.6.0/extras/phase2-ubuntu-prerequisites.identity"
  bundle_path="${phase2_root}/6.6.0/dp_bundle_6.6.0-current.tar"
  bundle_sidecar="${bundle_path}.sha256"
  if [[ ! -f "$identity_path" ]]; then
    printf 'fixture-prerequisite-identity-v1\n' >"$identity_path"
  fi
  prereq_sha="$(sha256sum "$identity_path" | awk '{print $1}')"

  if [[ -f "$bundle_path" ]]; then
    actual_bundle_sha="$(sha256sum "$bundle_path" | awk '{print $1}')"
    if [[ -f "$bundle_sidecar" ]]; then
      sidecar_bundle_sha="$(awk 'NF {print tolower($1); exit}' "$bundle_sidecar")"
      [[ "$sidecar_bundle_sha" =~ ^[0-9a-f]{64}$ && "$sidecar_bundle_sha" == "$actual_bundle_sha" ]] || return 1
    else
      printf '%s  dp_bundle_6.6.0-current.tar\n' "$actual_bundle_sha" >"$bundle_sidecar"
    fi
    bundle_sha="$actual_bundle_sha"
  elif [[ -f "$bundle_sidecar" ]]; then
    bundle_sha="$(awk 'NF {print tolower($1); exit}' "$bundle_sidecar")"
    [[ "$bundle_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  else
    bundle_sha="$(printf 'fixture-phase2-bundle-v1\n' | sha256sum | awk '{print $1}')"
    printf '%s  dp_bundle_6.6.0-current.tar\n' "$bundle_sha" >"$bundle_sidecar"
  fi

  # shellcheck source=../../scripts/lib/phase2_helper_generation.sh
  source "${repo_root}/scripts/lib/phase2_helper_generation.sh"
  phase2_helper_generation_write "$root" >/dev/null
  phase2_upgrade_wrapper_write "$root" "$mirror" 6.6.0 "$bundle_sha" "$prereq_sha" >/dev/null

  {
    printf 'CLIENT_MIRROR_BASE_URL=%s\n' "$mirror"
    printf 'MIRROR_HTTP_URL=%s\n' "$mirror"
    printf 'CLIENT_SIGNING_FINGERPRINT=%s\n' "$fpr"
    printf 'PREPARATION_MODE=%s\n' "$mode"
    printf 'CLIENT_LAUNCHER_SCHEMA_VERSION=3\n'
    printf 'CLIENT_BUILD_INPUT_SHA256=%s\n' \
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
      launcher="dp-launch-${hop}.sh"
      sha="$(sha256sum "${root}/${launcher}" | awk '{print $1}')"
      meta_key="CLIENT_LAUNCHER_$(printf '%s' "$hop" | tr 'a-z-' 'A-Z_')_SHA256"
      printf '%s=%s\n' "$meta_key" "$sha"
      wrapper="upgrade-${hop}.sh"
      sha="$(sha256sum "${root}/${wrapper}" | awk '{print $1}')"
      meta_key="CLIENT_WRAPPER_$(printf '%s' "$hop" | tr 'a-z-' 'A-Z_')_SHA256"
      printf '%s=%s\n' "$meta_key" "$sha"
    done
    printf 'CLIENT_PROVENANCE_SCHEMA_VERSION=3\n'
    printf 'CLIENT_WRAPPER_PHASE2_SHA256=%s\n' \
      "$(sha256sum "${root}/upgrade-phase2.sh" | awk '{print $1}')"
    p2rsha="$(sha256sum "${root}/upgrade-phase2-same-version-recovery.sh" | awk '{print $1}')"
    p2h="$(awk -F"'" '$1=="H="{print $2; exit}' "${root}/upgrade-phase2.sh")"
    p2b="$(awk -F"'" '$1=="B="{print $2; exit}' "${root}/upgrade-phase2.sh")"
    p2p="$(awk -F"'" '$1=="P="{print $2; exit}' "${root}/upgrade-phase2.sh")"
    printf 'CLIENT_WRAPPER_PHASE2_RECOVERY_SHA256=%s\n' "$p2rsha"
    printf 'CLIENT_PHASE2_HELPER_GENERATION_SHA256=%s\n' "$p2h"
    printf 'CLIENT_PHASE2_BUNDLE_SHA256=%s\n' "$p2b"
    printf 'CLIENT_PHASE2_PREREQ_IDENTITY_SHA256=%s\n' "$p2p"
  } >"${root}/client-set.env"
  chmod 0644 "${root}/client-set.env"
}
