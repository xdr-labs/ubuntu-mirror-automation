#!/usr/bin/env bash
# scripts/lib/local_client_signing.sh — per-mirror-install local signing keypair.
#
# Each Mirror Server install owns its own key pair. There is no central
# production private key and no out-of-band fingerprint trust path.
#
# Layout (overridable via LOCAL_CLIENT_SIGNING_DIR):
#   private.gpg   root:root 0600
#   public.gpg    root:root 0644
#   fingerprint   root:root 0644
#
# shellcheck shell=bash

if [[ -n "${LOCAL_CLIENT_SIGNING_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
LOCAL_CLIENT_SIGNING_LOADED=1

LOCAL_CLIENT_SIGNING_DIR="${LOCAL_CLIENT_SIGNING_DIR:-/etc/ubuntu-mirror/client-signing}"
LOCAL_SIGNING_KEY_ACTION="${LOCAL_SIGNING_KEY_ACTION:-}"
LOCAL_KEY_FINGERPRINT="${LOCAL_KEY_FINGERPRINT:-}"
LOCAL_SIGNING_PRIVATE_KEY="${LOCAL_SIGNING_PRIVATE_KEY:-}"
LOCAL_SIGNING_PUBLIC_KEY="${LOCAL_SIGNING_PUBLIC_KEY:-}"
LOCAL_SIGNING_FINGERPRINT_FILE="${LOCAL_SIGNING_FINGERPRINT_FILE:-}"

local_signing_log() {
  printf '%s\n' "$*"
}

local_signing_err() {
  printf '%s\n' "$*" >&2
}

local_signing_paths() {
  LOCAL_SIGNING_PRIVATE_KEY="${LOCAL_CLIENT_SIGNING_DIR}/private.gpg"
  LOCAL_SIGNING_PUBLIC_KEY="${LOCAL_CLIENT_SIGNING_DIR}/public.gpg"
  LOCAL_SIGNING_FINGERPRINT_FILE="${LOCAL_CLIENT_SIGNING_DIR}/fingerprint"
}

local_signing_fingerprint_of() {
  local key_file="${1:-}" fpr
  [[ -f "$key_file" ]] || return 1
  fpr="$(gpg --batch --with-colons --import-options show-only --import "$key_file" 2>/dev/null \
    | awk -F: '/^fpr:/{print $10; exit}')"
  [[ -n "$fpr" ]] || return 1
  printf '%s\n' "${fpr^^}"
}

# Validate an existing pair: both files present, readable, fingerprints match,
# and the on-disk fingerprint file (when present) matches the public key.
local_signing_validate_pair() {
  local priv="${1:-}" pub="${2:-}" fpr_file="${3:-}"
  local priv_fpr pub_fpr stored
  [[ -f "$priv" && -r "$priv" ]] || return 1
  [[ -f "$pub" && -r "$pub" ]] || return 1
  pub_fpr="$(local_signing_fingerprint_of "$pub" || true)"
  [[ -n "$pub_fpr" && ${#pub_fpr} -eq 40 ]] || return 1
  # Private armor/binary must import and expose the same fingerprint.
  priv_fpr="$(gpg --batch --with-colons --import-options show-only --import "$priv" 2>/dev/null \
    | awk -F: '/^fpr:/{print $10; exit}')"
  priv_fpr="${priv_fpr^^}"
  [[ -n "$priv_fpr" && "$priv_fpr" == "$pub_fpr" ]] || return 1
  if [[ -f "$fpr_file" ]]; then
    stored="$(tr -d '[:space:]' <"$fpr_file" | tr '[:lower:]' '[:upper:]')"
    [[ "$stored" == "$pub_fpr" ]] || return 1
  fi
  LOCAL_KEY_FINGERPRINT="$pub_fpr"
  return 0
}

local_signing_generate_pair() {
  local dir="${1:-$LOCAL_CLIENT_SIGNING_DIR}"
  local homedir batch priv pub fpr_file fpr
  mkdir -p "$dir"
  chmod 0700 "$dir"
  if [[ "${EUID}" -eq 0 ]]; then
    chown root:root "$dir" 2>/dev/null || true
  fi
  priv="${dir}/private.gpg"
  pub="${dir}/public.gpg"
  fpr_file="${dir}/fingerprint"
  homedir="$(mktemp -d "${TMPDIR:-/tmp}/local-client-sign-XXXXXX")"
  chmod 700 "$homedir"
  batch="${homedir}/batch"
  cat >"$batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Ubuntu Mirror Local Client Manifest
Name-Email: local-client-manifest@ubuntu-mirror
Expire-Date: 0
%no-protection
%commit
EOF
  gpg --homedir "$homedir" --batch --gen-key "$batch" >/dev/null 2>&1 \
    || { rm -rf "$homedir"; return 1; }
  gpg --homedir "$homedir" --batch --export-secret-keys --armor >"$priv" 2>/dev/null \
    || { rm -rf "$homedir"; rm -f "$priv"; return 1; }
  gpg --homedir "$homedir" --batch --export --armor >"$pub" 2>/dev/null \
    || { rm -rf "$homedir"; rm -f "$priv" "$pub"; return 1; }
  rm -rf "$homedir"
  chmod 0600 "$priv"
  chmod 0644 "$pub"
  fpr="$(local_signing_fingerprint_of "$pub" || true)"
  [[ -n "$fpr" ]] || { rm -f "$priv" "$pub"; return 1; }
  printf '%s\n' "$fpr" >"$fpr_file"
  chmod 0644 "$fpr_file"
  if [[ "${EUID}" -eq 0 ]]; then
    chown root:root "$priv" "$pub" "$fpr_file" 2>/dev/null || true
  fi
  LOCAL_KEY_FINGERPRINT="$fpr"
  LOCAL_SIGNING_PRIVATE_KEY="$priv"
  LOCAL_SIGNING_PUBLIC_KEY="$pub"
  LOCAL_SIGNING_FINGERPRINT_FILE="$fpr_file"
  return 0
}

# Ensure a usable local keypair. Never rotates automatically.
# Sets LOCAL_SIGNING_KEY_ACTION to GENERATED | REUSED | FAIL.
local_signing_ensure_keypair() {
  local_signing_paths
  LOCAL_SIGNING_KEY_ACTION=""
  LOCAL_KEY_FINGERPRINT=""

  local have_priv=0 have_pub=0
  [[ -e "$LOCAL_SIGNING_PRIVATE_KEY" ]] && have_priv=1
  [[ -e "$LOCAL_SIGNING_PUBLIC_KEY" ]] && have_pub=1

  if [[ "$have_priv" -eq 0 && "$have_pub" -eq 0 ]]; then
    if local_signing_generate_pair "$LOCAL_CLIENT_SIGNING_DIR"; then
      LOCAL_SIGNING_KEY_ACTION=GENERATED
      local_signing_log "LOCAL_SIGNING_KEY_ACTION=GENERATED"
      local_signing_log "LOCAL_KEY_FINGERPRINT=${LOCAL_KEY_FINGERPRINT}"
      return 0
    fi
    LOCAL_SIGNING_KEY_ACTION=FAIL
    local_signing_err "LOCAL_SIGNING_KEY_ACTION=FAIL generation failed"
    return 1
  fi

  if local_signing_validate_pair \
    "$LOCAL_SIGNING_PRIVATE_KEY" \
    "$LOCAL_SIGNING_PUBLIC_KEY" \
    "$LOCAL_SIGNING_FINGERPRINT_FILE"
  then
    # Refresh fingerprint file if missing but pair is valid.
    if [[ ! -f "$LOCAL_SIGNING_FINGERPRINT_FILE" ]]; then
      printf '%s\n' "$LOCAL_KEY_FINGERPRINT" >"$LOCAL_SIGNING_FINGERPRINT_FILE"
      chmod 0644 "$LOCAL_SIGNING_FINGERPRINT_FILE"
    fi
    LOCAL_SIGNING_KEY_ACTION=REUSED
    local_signing_log "LOCAL_SIGNING_KEY_ACTION=REUSED"
    local_signing_log "LOCAL_KEY_FINGERPRINT=${LOCAL_KEY_FINGERPRINT}"
    return 0
  fi

  LOCAL_SIGNING_KEY_ACTION=FAIL
  local_signing_err "LOCAL_SIGNING_KEY_ACTION=FAIL incomplete or mismatched key pair"
  local_signing_err "INSTALL_RESULT=FAIL"
  return 1
}

# Export env vars consumed by the Python builders.
local_signing_export_build_env() {
  local_signing_paths
  export CLIENT_SIGNING_PRIVATE_KEY="$LOCAL_SIGNING_PRIVATE_KEY"
  export CLIENT_SIGNING_PUBLIC_KEY="$LOCAL_SIGNING_PUBLIC_KEY"
  export CLIENT_SIGNING_KEY_DIR="$LOCAL_CLIENT_SIGNING_DIR"
  if [[ -n "${LOCAL_KEY_FINGERPRINT:-}" ]]; then
    export CLIENT_SIGNING_FINGERPRINT="$LOCAL_KEY_FINGERPRINT"
  fi
}

# Refuse publishing private key material into an HTTP document root.
local_signing_assert_private_not_published() {
  local http_root="${1:-}"
  [[ -n "$http_root" && -d "$http_root" ]] || return 0
  local private_match
  if ! private_match="$(find "$http_root" -type f \( -name 'private.gpg' -o -name '*private*.gpg' -o -name '*.private.gpg' \) -print -quit 2>/dev/null)"; then
    local_signing_err "PRIVATE_KEY_HTTP_SCAN_FAILED=YES"
    return 1
  fi
  if [[ -n "$private_match" ]]; then
    local_signing_err "PRIVATE_KEY_HTTP_PUBLISHED=YES"
    return 1
  fi
  local_signing_log "PRIVATE_KEY_HTTP_PUBLISHED=NO"
  return 0
}

# True when path starts with the ASCII-armored public key header.
local_signing_is_ascii_armored_public() {
  local path="${1:-}"
  [[ -f "$path" && -s "$path" ]] || return 1
  head -n 1 "$path" 2>/dev/null | grep -qx -- '-----BEGIN PGP PUBLIC KEY BLOCK-----'
}

# Build a binary OpenPGP keyring suitable for classic gpgv --keyring.
# Source remains ASCII-armored public.gpg on disk; only the HTTP artifact is binary.
local_signing_build_binary_keyring() {
  local armored="${1:-}"
  local dest="${2:-}"
  [[ -n "$armored" && -f "$armored" && -s "$armored" ]] || return 1
  [[ -n "$dest" ]] || return 1
  gpg --batch --dearmor <"$armored" >"$dest" 2>/dev/null || return 1
  [[ -s "$dest" ]] || return 1
  chmod 0644 "$dest"
  return 0
}

# Fingerprint of a binary (or armored) public key file; uppercase 40-hex.
local_signing_fingerprint_of_keyring() {
  local key_file="${1:-}" fpr
  [[ -f "$key_file" && -s "$key_file" ]] || return 1
  if local_signing_is_ascii_armored_public "$key_file"; then
    local_signing_fingerprint_of "$key_file"
    return $?
  fi
  fpr="$(gpg --batch --no-default-keyring --keyring "$key_file" \
    --with-colons --fingerprint 2>/dev/null \
    | awk -F: '/^fpr:/{print $10; exit}')"
  [[ -n "$fpr" ]] || return 1
  printf '%s\n' "${fpr^^}"
}

# Verify binary keyring: non-empty, not ASCII armor, readable, fingerprint match.
local_signing_verify_binary_keyring() {
  local keyring="${1:-}"
  local expected_fpr="${2:-${LOCAL_KEY_FINGERPRINT:-}}"
  local got

  [[ -f "$keyring" && -s "$keyring" ]] || {
    local_signing_err "CLIENT_PUBLIC_BINARY_KEYRING_FORMAT=FAIL reason=empty_or_missing"
    return 1
  }
  if local_signing_is_ascii_armored_public "$keyring"; then
    local_signing_err "CLIENT_PUBLIC_BINARY_KEYRING_FORMAT=FAIL reason=ascii_armor"
    return 1
  fi
  # First bytes must not be the armor header (also catch UTF-8 BOM + header).
  if head -c 64 "$keyring" 2>/dev/null | grep -q 'BEGIN PGP PUBLIC KEY BLOCK'; then
    local_signing_err "CLIENT_PUBLIC_BINARY_KEYRING_FORMAT=FAIL reason=armor_payload"
    return 1
  fi
  got="$(local_signing_fingerprint_of_keyring "$keyring" || true)"
  [[ -n "$got" && ${#got} -eq 40 ]] || {
    local_signing_err "CLIENT_PUBLIC_BINARY_KEYRING_FORMAT=FAIL reason=unreadable"
    return 1
  }
  local_signing_log "CLIENT_PUBLIC_BINARY_KEYRING_FORMAT=OPENPGP_BINARY"
  if [[ -n "$expected_fpr" ]]; then
    expected_fpr="${expected_fpr^^}"
    if [[ "$got" != "$expected_fpr" ]]; then
      local_signing_err "CLIENT_PUBLIC_BINARY_KEYRING_FINGERPRINT=FAIL got=${got} expected=${expected_fpr}"
      return 1
    fi
  fi
  local_signing_log "CLIENT_PUBLIC_BINARY_KEYRING_FINGERPRINT=PASS"
  return 0
}

# Stage HTTP-facing public key artifacts into a client staging directory.
# Keeps local on-disk public.gpg format unchanged; publishes both armor + binary.
local_signing_stage_http_public_artifacts() {
  local stage_dir="${1:-}"
  local armored="${2:-${LOCAL_SIGNING_PUBLIC_KEY}}"
  local expected_fpr="${3:-${LOCAL_KEY_FINGERPRINT:-}}"

  [[ -n "$stage_dir" && -d "$stage_dir" ]] || return 1
  [[ -f "$armored" && -s "$armored" ]] || return 1

  install -m 0644 "$armored" "${stage_dir}/public.gpg"
  install -m 0644 "$armored" "${stage_dir}/public.asc"
  install -m 0644 "$armored" "${stage_dir}/offline-client-manifest.gpg"
  local_signing_log "CLIENT_PUBLIC_ARMORED_KEY_PUBLISH=PASS"

  if ! local_signing_build_binary_keyring "$armored" "${stage_dir}/public-keyring.gpg"; then
    local_signing_err "CLIENT_PUBLIC_BINARY_KEYRING_BUILD=FAIL"
    return 1
  fi
  local_signing_log "CLIENT_PUBLIC_BINARY_KEYRING_BUILD=PASS"

  if ! local_signing_verify_binary_keyring "${stage_dir}/public-keyring.gpg" "$expected_fpr"; then
    return 1
  fi
  return 0
}

# Detach-sign a payload with the local private key (armored .asc).
local_signing_detach_sign() {
  local payload="${1:-}"
  local sig_path="${2:-}"
  local priv="${3:-${LOCAL_SIGNING_PRIVATE_KEY:-}}"
  local homedir

  [[ -f "$payload" && -s "$payload" ]] || return 1
  [[ -n "$sig_path" ]] || return 1
  [[ -f "$priv" && -s "$priv" ]] || return 1

  homedir="$(mktemp -d "${TMPDIR:-/tmp}/local-sign-XXXXXX")"
  chmod 700 "$homedir"
  if ! gpg --homedir "$homedir" --batch --import "$priv" >/dev/null 2>&1; then
    rm -rf "$homedir"
    return 1
  fi
  rm -f "$sig_path"
  if ! gpg --homedir "$homedir" --batch --yes --armor --detach-sign \
    -o "$sig_path" "$payload" >/dev/null 2>&1
  then
    rm -rf "$homedir"
    return 1
  fi
  rm -rf "$homedir"
  [[ -s "$sig_path" ]] || return 1
  chmod 0644 "$sig_path"
  return 0
}

# Stage the Menu 7 command-runner helper + signed checksum manifest + sidecar.
local_signing_stage_command_runner() {
  local stage_dir="${1:-}"
  local src_runner="${2:-}"
  local runner_name="dp-client-command-runner.sh"
  local manifest_name="runner-manifest"

  [[ -n "$stage_dir" && -d "$stage_dir" ]] || return 1
  [[ -f "$src_runner" && -s "$src_runner" ]] || return 1

  install -m 0755 "$src_runner" "${stage_dir}/${runner_name}"
  ( cd "$stage_dir" && sha256sum "$runner_name" >"${runner_name}.sha256" )
  # Signed checksum manifest (sha256sum format) binds the runner bytes.
  install -m 0644 "${stage_dir}/${runner_name}.sha256" "${stage_dir}/${manifest_name}"
  if ! local_signing_detach_sign \
    "${stage_dir}/${manifest_name}" \
    "${stage_dir}/${manifest_name}.asc"
  then
    local_signing_err "RUNNER_MANIFEST_SIGN=FAIL"
    return 1
  fi
  local_signing_log "RUNNER_MANIFEST_SIGN=PASS"
  local_signing_log "COMMAND_RUNNER_PUBLISH=PASS"
  return 0
}

# gpgv-verify each hop's detached client-manifest against the binary keyring.
# hops: remaining args (default four production hops).
local_signing_verify_staged_manifest_gpgv() {
  local stage_dir="${1:-}"
  shift || true
  local hops=("$@")
  local hop json asc keyring

  [[ -n "$stage_dir" && -d "$stage_dir" ]] || return 1
  keyring="${stage_dir}/public-keyring.gpg"
  [[ -f "$keyring" && -s "$keyring" ]] || {
    local_signing_err "CLIENT_MANIFEST_GPGV_VERIFY=FAIL reason=missing_public_keyring"
    return 1
  }
  if [[ "${#hops[@]}" -eq 0 ]]; then
    hops=(xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble)
  fi
  for hop in "${hops[@]}"; do
    json="${stage_dir}/${hop}/client-manifest.json"
    asc="${stage_dir}/${hop}/client-manifest.json.asc"
    if [[ ! -f "$json" || ! -f "$asc" ]]; then
      local_signing_err "CLIENT_MANIFEST_GPGV_VERIFY=FAIL hop=${hop} reason=missing_manifest"
      return 1
    fi
    if ! gpgv --keyring "$keyring" "$asc" "$json" >/dev/null 2>&1; then
      local_signing_err "CLIENT_MANIFEST_GPGV_VERIFY=FAIL hop=${hop}"
      return 1
    fi
    local_signing_log "CLIENT_MANIFEST_GPGV_VERIFY=PASS hop=${hop}"
  done
  return 0
}

# Full pre-publish gate: binary keyring + four-hop gpgv + no private key.
# On failure prints CLIENT_SET_ATOMIC_SWAP=NOT_STARTED via caller responsibility.
local_signing_prepublish_keyring_gate() {
  local stage_dir="${1:-}"
  local expected_fpr="${2:-${LOCAL_KEY_FINGERPRINT:-}}"
  shift 2 2>/dev/null || true
  local hops=("$@")

  [[ -n "$stage_dir" && -d "$stage_dir" ]] || return 1
  if ! local_signing_verify_binary_keyring "${stage_dir}/public-keyring.gpg" "$expected_fpr"; then
    return 1
  fi
  if [[ "${#hops[@]}" -gt 0 ]]; then
    local_signing_verify_staged_manifest_gpgv "$stage_dir" "${hops[@]}" || return 1
  else
    local_signing_verify_staged_manifest_gpgv "$stage_dir" || return 1
  fi
  local_signing_assert_private_not_published "$stage_dir" || return 1
  return 0
}
