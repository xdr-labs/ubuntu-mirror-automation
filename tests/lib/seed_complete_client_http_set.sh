#!/usr/bin/env bash
# Seed a synthetic HTTP client set that satisfies mm_client_files_ready /
# mm_client_launchers_ready without invoking real hop builders or signing.
# shellcheck shell=bash

seed_complete_client_http_set() {
  local root="${1:?client root required}"
  local mirror="${2:-http://192.0.2.10}"
  local fpr="${3:-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA}"
  local mode="${4:-FULL}"
  local hop launcher f sha launcher_sha wrapper

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

  for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
    launcher="dp-launch-${hop}.sh"
    cat >"${root}/${launcher}" <<EOF
#!/bin/bash
HOP='${hop}'
EXPECTED_FPR='${fpr}'
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
cd /home/aella
L='${launcher}'
D="\${L}.download"
MIRROR='${mirror}'
LAUNCHER_SHA256='${launcher_sha}'
curl -fsSLo "\$D" "\${MIRROR}/client/\${L}"
printf '%s  %s\\n' "\$LAUNCHER_SHA256" "\$D" | sha256sum -c -
mv -f "\$D" "\$L"
exec bash "./\$L"
EOF
    chmod 0755 "${root}/${wrapper}"
    (cd "$root" && sha256sum "$wrapper" >"${wrapper}.sha256")
  done

  cat >"${root}/upgrade-phase2.sh" <<EOF
#!/bin/bash
set -euo pipefail
cd /home/aella
MIRROR='${mirror}'
VER='6.6.0'
SCRIPT='stage-dp-phase2.sh'
GEN='phase2-helper-generation.manifest'
H='0000000000000000000000000000000000000000000000000000000000000000'
W=\$(mktemp -d)
trap 'rm -rf "\$W"' EXIT
cd "\$W"
mkdir -p lib
for F in "\$GEN" "\$SCRIPT"; do
  curl -fsSLo "\$F" "\$MIRROR/client/\$F" || exit 1
done
printf '%s  %s\\n' "\$H" "\$GEN" | sha256sum -c -
sha256sum -c "\$GEN"
exec sudo bash "./\$SCRIPT" --target-version "\$VER" --same-version-recovery --mirror-url "\$MIRROR"
EOF
  chmod 0755 "${root}/upgrade-phase2.sh"
  (cd "$root" && sha256sum upgrade-phase2.sh >upgrade-phase2.sh.sha256)

  cp -f "${root}/dp-client-command-runner.sh.sha256" "${root}/runner-manifest"
  printf 'synthetic-asc\n' >"${root}/runner-manifest.asc"
  printf 'PUB\n' >"${root}/public.gpg"
  printf '\x99\x02\x00' >"${root}/public-keyring.gpg"

  {
    printf 'CLIENT_MIRROR_BASE_URL=%s\n' "$mirror"
    printf 'MIRROR_HTTP_URL=%s\n' "$mirror"
    printf 'CLIENT_SIGNING_FINGERPRINT=%s\n' "$fpr"
    printf 'PREPARATION_MODE=%s\n' "$mode"
    printf 'CLIENT_LAUNCHER_SCHEMA_VERSION=1\n'
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
    printf 'CLIENT_WRAPPER_PHASE2_SHA256=%s\n' \
      "$(sha256sum "${root}/upgrade-phase2.sh" | awk '{print $1}')"
  } >"${root}/client-set.env"
  chmod 0644 "${root}/client-set.env"
}
