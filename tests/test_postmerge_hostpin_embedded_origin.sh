#!/usr/bin/env bash
# A15: embedded upgrader metadata/manifest cannot hide foreign source URLs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/client_mirror_gates.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
A='http://192.0.2.10'
B='http://192.0.2.20'
make_client() {
  local name="$1" tool_base="$2" sample_base="$3" duplicate_base="$4"
  cat >"$TMP/meta" <<EOF
Dist: bionic
Release-File: $A/hops/xenial-to-bionic/ubuntu/dists/bionic/Release
UpgradeTool: $tool_base/offline/bionic.tar.gz
UpgradeToolSignature: $A/offline/bionic.tar.gz.gpg
EOF
  if [[ -z "$duplicate_base" ]]; then
    printf '{"mirror_base":"%s","sample_deb_url":"%s/client/x.deb"}\n' "$A" "$sample_base" >"$TMP/manifest"
  else
    printf '{"mirror_base":"%s","mirror_base":"%s","sample_deb_url":"%s/client/x.deb"}\n' "$A" "$duplicate_base" "$A" >"$TMP/manifest"
  fi
  local meta_b64 manifest_b64
  meta_b64="$(base64 -w0 "$TMP/meta")"
  manifest_b64="$(base64 -w0 "$TMP/manifest")"
  cat >"$TMP/$name.sh" <<EOF
#!/bin/bash
PIN_MIRROR_BASE='$A'
PIN_SAMPLE_DEB_URL='$A/client/x.deb'
PIN_META_B64='$meta_b64'
PIN_MANIFEST_B64='$manifest_b64'
EOF
}
make_client valid "$A" "$A" ""
client_assert_mirror_base_match "$TMP/valid.sh" "$A" >/dev/null || exit 1
echo 'PASS ACCEPT normal embedded origins'
make_client wrong_meta "$B" "$A" ""
if client_assert_mirror_base_match "$TMP/wrong_meta.sh" "$A" >/dev/null 2>&1; then
  echo 'FAIL foreign UpgradeTool URL accepted' >&2; exit 1
fi
echo 'PASS REJECT foreign upgrader URL'
make_client wrong_manifest "$A" "$B" ""
if client_assert_mirror_base_match "$TMP/wrong_manifest.sh" "$A" >/dev/null 2>&1; then
  echo 'FAIL foreign sample_deb_url manifest accepted' >&2; exit 1
fi
echo 'PASS REJECT foreign manifest URL'
make_client duplicate_manifest "$A" "$A" "$B"
if client_assert_mirror_base_match "$TMP/duplicate_manifest.sh" "$A" >/dev/null 2>&1; then
  echo 'FAIL duplicate conflicting manifest base accepted' >&2; exit 1
fi
echo 'PASS REJECT duplicate manifest base'
echo 'POSTMERGE_EMBEDDED_ORIGIN=PASS'
