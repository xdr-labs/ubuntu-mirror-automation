#!/usr/bin/env bash
# scripts/rebuild-publish-clients.sh — build/sign/publish host-pinned clients
# for THIS Mirror Server using its local signing keypair.
#
# Content for client builds is read from the local selective filesystem only.
# MIRROR_HTTP_URL is a runtime URL pin embedded into clients — not used to
# fetch Release/Packages during prepare/build.
#
# Invoked by install/bootstrap (and Mirror Manager after OS Core is READY).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/mirror_host_ip.sh
source "${ROOT}/scripts/lib/mirror_host_ip.sh"
# shellcheck source=lib/client_mirror_gates.sh
source "${ROOT}/scripts/lib/client_mirror_gates.sh"
# shellcheck source=lib/local_client_signing.sh
source "${ROOT}/scripts/lib/local_client_signing.sh"
# shellcheck source=lib/http_publication_permissions.sh
source "${ROOT}/scripts/lib/http_publication_permissions.sh"

BASE_PATH="${BASE_PATH:-/var/spool/apt-mirror}"
CLIENT_HTTP_ROOT="${CLIENT_HTTP_ROOT:-${BASE_PATH}/client}"
SELECTIVE_ROOT="${SELECTIVE_ROOT:-${SELECTIVE_MIRROR_ROOT:-${BASE_PATH}/selective}}"
CACHE_ROOT="${CACHE_ROOT:-${BASE_PATH}/.install-cache}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_DEPLOY="${SKIP_DEPLOY:-0}"
SKIP_HTTP_VERIFY="${SKIP_HTTP_VERIFY:-0}"
REQUIRE_SELECTIVE_READY="${REQUIRE_SELECTIVE_READY:-1}"
CONTENT_SOURCE="${CONTENT_SOURCE:-local-fs}"

HOPS=(
  xenial-to-bionic
  bionic-to-focal
  focal-to-jammy
  jammy-to-noble
)

hop_builder_py() {
  printf '%s/scripts/lib/build_client_%s.py\n' "$ROOT" "${1//-/_}"
}

usage() {
  cat <<EOF
Usage: sudo bash ${0##*/} [--hop HOP]... [--skip-build] [--skip-deploy] [--skip-http-verify]

Rebuild and atomically publish host-pinned signed clients for this Mirror.

Hops: ${HOPS[*]}

Environment:
  RESOLVED_MIRROR_HOST_IPV4   override host IPv4
  MIRROR_HTTP_URL             runtime URL pin only (not content acquisition)
  LOCAL_CLIENT_SIGNING_DIR    key directory (default /etc/ubuntu-mirror/client-signing)
  CLIENT_HTTP_ROOT            nginx /client/ destination
  ARTIFACT_DIR                override staging (default: cache/client-build/<run-id>)
  CONTENT_SOURCE              local-fs (default) or http (diagnostic only)
  CLIENT_FINALIZATION_EVIDENCE_LOG  optional persistent evidence path
EOF
}

selected=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hop) selected+=("${2:?--hop requires a value}"); shift 2 ;;
    --hop=*) selected+=("${1#*=}"); shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-deploy) SKIP_DEPLOY=1; shift ;;
    --skip-http-verify) SKIP_HTTP_VERIFY=1; shift ;;
    --content-source)
      CONTENT_SOURCE="${2:?}"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "${#selected[@]}" -gt 0 ]] && HOPS=("${selected[@]}")

if [[ "$CONTENT_SOURCE" != "local-fs" && "$CONTENT_SOURCE" != "http" ]]; then
  echo "CONTENT_SOURCE=INVALID value=${CONTENT_SOURCE}" >&2
  exit 2
fi
# Authoritative production path always forces local-fs unless explicitly overridden
# for diagnostics (CONTENT_SOURCE_FORCE=http).
if [[ "${CONTENT_SOURCE_FORCE:-}" != "http" ]]; then
  CONTENT_SOURCE=local-fs
fi

CLIENT_BUILD_GENERATION_ID="${CLIENT_BUILD_GENERATION_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
CLIENT_PROVENANCE_MODULE="${ROOT}/scripts/lib/client_build_provenance.py"
[[ -f "$CLIENT_PROVENANCE_MODULE" ]] || {
  echo "CLIENT_BUILD_PROVENANCE=FAIL reason=module_missing" >&2
  exit 1
}
# Fingerprint may not exist yet; ensure_keypair runs later. Compute after signing setup.
if [[ -z "${ARTIFACT_DIR:-}" ]]; then
  ARTIFACT_DIR="${CACHE_ROOT}/client-build/${CLIENT_BUILD_GENERATION_ID}"
fi

EVIDENCE_LOG="${CLIENT_FINALIZATION_EVIDENCE_LOG:-}"
if [[ -z "$EVIDENCE_LOG" ]]; then
  if [[ -n "${MM_STATE_DIR:-}" ]]; then
    EVIDENCE_LOG="${MM_STATE_DIR}/client-finalization-${CLIENT_BUILD_GENERATION_ID}.log"
  else
    mkdir -p /var/log/ubuntu-mirror-automation 2>/dev/null || true
    if [[ -d /var/log/ubuntu-mirror-automation ]] && [[ -w /var/log/ubuntu-mirror-automation ]]; then
      EVIDENCE_LOG="/var/log/ubuntu-mirror-automation/client-finalization-${CLIENT_BUILD_GENERATION_ID}.log"
    else
      EVIDENCE_LOG="${CACHE_ROOT}/client-build/evidence-${CLIENT_BUILD_GENERATION_ID}.log"
      mkdir -p "$(dirname "$EVIDENCE_LOG")"
    fi
  fi
fi
mkdir -p "$(dirname "$EVIDENCE_LOG")"
: >"$EVIDENCE_LOG"
chmod 0600 "$EVIDENCE_LOG" 2>/dev/null || true

evidence() {
  # shellcheck disable=SC2034
  local line
  line="$(printf '%s\n' "$*")"
  # Prefer mm_redact when available from caller environment.
  if declare -F mm_redact >/dev/null 2>&1; then
    printf '%s\n' "$line" | mm_redact >>"$EVIDENCE_LOG" 2>/dev/null || printf '%s\n' "$line" >>"$EVIDENCE_LOG"
  else
    printf '%s\n' "$line" >>"$EVIDENCE_LOG"
  fi
}

evidence_echo() {
  evidence "$@"
  printf '%s\n' "$@"
}

FAILED_HOP=""
FAILED_STAGE=""
LIVE_BACKUP=""
STAGE_DIR=""
cleanup() {
  if [[ -n "${STAGE_DIR:-}" && -d "${STAGE_DIR:-}" ]]; then
    rm -rf "$STAGE_DIR"
  fi
  return 0
}
trap cleanup EXIT

fail_build() {
  local hop="${1:-}"
  local stage="${2:-}"
  local msg="${3:-}"
  local rc="${4:-1}"
  FAILED_HOP="$hop"
  FAILED_STAGE="$stage"
  evidence "CLIENT_BUILD_FAILED_HOP=${hop}"
  evidence "CLIENT_BUILD_FAILED_STAGE=${stage}"
  evidence "CLIENT_BUILD_EXIT_CODE=${rc}"
  evidence "CLIENT_BUILD_ERROR=${msg}"
  evidence "CLIENT_FINALIZER_EVIDENCE_PATH=${EVIDENCE_LOG}"
  echo "CLIENT_BUILD_FAILED_HOP=${hop}" >&2
  echo "CLIENT_BUILD_FAILED_STAGE=${stage}" >&2
  echo "CLIENT_BUILD_EXIT_CODE=${rc}" >&2
  echo "CLIENT_BUILD_ERROR=${msg}" >&2
  echo "CLIENT_FINALIZER_EVIDENCE_PATH=${EVIDENCE_LOG}" >&2
  if [[ -s "$EVIDENCE_LOG" ]]; then
    echo "CLIENT_FINALIZER_ERROR_SUMMARY=$(tail -n 5 "$EVIDENCE_LOG" | tr '\n' '|' | sed 's/|$//')" >&2
  fi
  exit "$rc"
}

evidence_echo "CENTRAL_PRODUCTION_PRIVATE_KEY_REQUIRED=NO"
evidence_echo "LOCAL_MIRROR_KEYPAIR_REQUIRED=YES"
evidence_echo "OUT_OF_BAND_FINGERPRINT_REQUIRED=NO"
evidence_echo "TARGET_INSTALL_GENERATES_OR_REUSES_LOCAL_PRIVATE_KEY=YES"
evidence_echo "TARGET_INSTALL_REBUILDS_CLIENTS=YES"
evidence_echo "TARGET_INSTALL_SIGNS_CLIENTS=YES"
evidence_echo "PARTIAL_CLIENT_DEPLOY_ALLOWED=NO"
evidence_echo "CLIENT_BUILD_GENERATION_ID=${CLIENT_BUILD_GENERATION_ID}"
evidence_echo "CLIENT_BUILD_STAGING_PATH=${ARTIFACT_DIR}"
evidence_echo "CLIENT_BUILD_CONTENT_SOURCE=LOCAL_FILESYSTEM"
evidence_echo "CLIENT_BUILD_NETWORK_REQUIRED=NO"
evidence_echo "CLIENT_FINALIZER_EVIDENCE_PATH=${EVIDENCE_LOG}"

# Hermetic/local-fs builds may pin an unreachable documentation IP (RFC 5737)
# without requiring that address on a local interface. Production leaves this unset.
if [[ "${CLIENT_BUILD_PIN_URL_ONLY:-0}" == "1" ]]; then
  pin_url="${RESOLVED_MIRROR_BASE_URL:-${MIRROR_HTTP_URL:-}}"
  pin_url="${pin_url%/}"
  if [[ -z "$pin_url" ]]; then
    fail_build "" "mirror_resolve" "CLIENT_BUILD_PIN_URL_ONLY requires MIRROR_HTTP_URL" 1
  fi
  RESOLVED_MIRROR_BASE_URL="$pin_url"
  MIRROR_BASE="$pin_url"
  evidence_echo "MIRROR_IP_RESOLUTION_SOURCE=PIN_URL_ONLY"
  evidence_echo "RESOLVED_MIRROR_BASE_URL=${MIRROR_BASE}"
else
  mirror_host_resolve_and_log || {
    fail_build "" "mirror_resolve" "mirror host IPv4 could not be resolved" 1
  }
  MIRROR_BASE="${RESOLVED_MIRROR_BASE_URL%/}"
  evidence_echo "RESOLVED_MIRROR_BASE_URL=${MIRROR_BASE}"
fi
evidence_echo "CLIENT_BUILD_MIRROR_URL_PURPOSE=RUNTIME_PIN_ONLY"

local_signing_ensure_keypair || {
  fail_build "" "signing_keypair" "local signing keypair unavailable" 1
}
local_signing_export_build_env
evidence_echo "LOCAL_SIGNING_KEY_PATH=${LOCAL_SIGNING_PRIVATE_KEY}"
evidence_echo "LOCAL_PUBLIC_KEY_PATH=${LOCAL_SIGNING_PUBLIC_KEY}"
evidence_echo "LOCAL_KEY_FINGERPRINT=${LOCAL_KEY_FINGERPRINT}"

CLIENT_PROVENANCE_ENV="$(mktemp)"
python3 "$CLIENT_PROVENANCE_MODULE" compute \
  --project-root "$ROOT" \
  --mirror-base-url "$MIRROR_BASE" \
  --signing-fingerprint "$LOCAL_KEY_FINGERPRINT" \
  --format env >"$CLIENT_PROVENANCE_ENV"
# shellcheck disable=SC1090
source "$CLIENT_PROVENANCE_ENV"
rm -f "$CLIENT_PROVENANCE_ENV"
export CLIENT_PROVENANCE_SCHEMA_VERSION CLIENT_BUILD_INPUT_SHA256
export CLIENT_SOURCE_REVISION CLIENT_SOURCE_TREE_STATE CLIENT_BUILD_SOURCE_REVISION
export CLIENT_RUNTIME_MANIFEST_SHA256 CLIENT_BUILDERS_SHA256 CLIENT_TEMPLATES_SHA256
export CLIENT_SHARED_HELPERS_SHA256 CLIENT_RUNNER_SHA256 CLIENT_COMMAND_BLOCK_VERSION
export CLIENT_LAUNCHER_SCHEMA_VERSION CLIENT_MIRROR_BASE_URL CLIENT_SIGNING_FINGERPRINT
export CLIENT_BUILD_CREATED_UTC
evidence_echo "CLIENT_PROVENANCE_SCHEMA_VERSION=${CLIENT_PROVENANCE_SCHEMA_VERSION}"
evidence_echo "CLIENT_BUILD_INPUT_SHA256=${CLIENT_BUILD_INPUT_SHA256}"
evidence_echo "CLIENT_SOURCE_REVISION=${CLIENT_SOURCE_REVISION}"
evidence_echo "CLIENT_SOURCE_TREE_STATE=${CLIENT_SOURCE_TREE_STATE}"
evidence_echo "CLIENT_COMMAND_BLOCK_VERSION=${CLIENT_COMMAND_BLOCK_VERSION}"
evidence_echo "CLIENT_LAUNCHER_SCHEMA_VERSION=${CLIENT_LAUNCHER_SCHEMA_VERSION}"
evidence_echo "CLIENT_MIRROR_BASE_URL=${CLIENT_MIRROR_BASE_URL}"
evidence_echo "CLIENT_SIGNING_FINGERPRINT=${CLIENT_SIGNING_FINGERPRINT}"

if [[ "$REQUIRE_SELECTIVE_READY" == "1" ]]; then
  if [[ ! -f "${SELECTIVE_ROOT}/state/READY" ]]; then
    fail_build "" "selective_ready" "OS Core/selective mirror not ready path=${SELECTIVE_ROOT}/state/READY" 1
  fi
  if [[ ! -f "${SELECTIVE_ROOT}/keys/ubuntu-mirror-selective.gpg" ]]; then
    fail_build "" "selective_key" "SELECTIVE_KEY=MISSING" 1
  fi
fi

hop_script_name() { printf 'dp-offline-upgrade-%s.sh\n' "$1"; }

# Fresh empty generation directory for this run.
rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"

if [[ "$SKIP_BUILD" == "1" ]]; then
  evidence_echo "CLIENT_REBUILD=SKIPPED"
else
  for hop in "${HOPS[@]}"; do
    builder="$(hop_builder_py "$hop")"
    [[ -f "$builder" ]] || fail_build "$hop" "builder_missing" "missing builder ${builder}" 1
    evidence_echo "CLIENT_BUILD_START hop=${hop}"
    echo "CLIENT_REBUILD_START=${hop} mirror_base=${MIRROR_BASE} content_source=local-fs"
    set +e
    env \
      CLIENT_SIGNING_PRIVATE_KEY="$LOCAL_SIGNING_PRIVATE_KEY" \
      CLIENT_SIGNING_PUBLIC_KEY="$LOCAL_SIGNING_PUBLIC_KEY" \
      CLIENT_SIGNING_KEY_DIR="$LOCAL_CLIENT_SIGNING_DIR" \
      python3 "$builder" \
        --project-root "$ROOT" \
        --mirror-base "$MIRROR_BASE" \
        --selective-root "$SELECTIVE_ROOT" \
        --output-dir "$ARTIFACT_DIR" \
        --content-source local-fs \
        --signing-private-key "$LOCAL_SIGNING_PRIVATE_KEY" \
        --signing-public-key "$LOCAL_SIGNING_PUBLIC_KEY" \
      2>&1 | tee -a "$EVIDENCE_LOG"
    rc=${PIPESTATUS[0]}
    set -e
    if [[ "$rc" -ne 0 ]]; then
      fail_build "$hop" "build" "python builder failed hop=${hop}" "$rc"
    fi
    evidence_echo "CLIENT_BUILD_COMPLETE hop=${hop}"
    echo "CLIENT_REBUILD=PASS hop=${hop}"
  done
  evidence_echo "CLIENT_SET_BUILD_COMPLETE=YES"
  evidence_echo "INSTALL_BUILDS_LOCAL_CLIENT_SET=YES"
  echo "CLIENT_SET_BUILD_COMPLETE=YES"
  echo "INSTALL_BUILDS_LOCAL_CLIENT_SET=YES"
fi

for hop in "${HOPS[@]}"; do
  artifact="${ARTIFACT_DIR}/$(hop_script_name "$hop")"
  [[ -f "$artifact" ]] || fail_build "$hop" "artifact_missing" "missing artifact ${artifact}" 1
  client_assert_mirror_base_match "$artifact" "$MIRROR_BASE" || {
    fail_build "$hop" "host_pin_gate" "HOST_PIN_GATE=FAIL hop=${hop}" 1
  }
done

# Signature verification against the local public key for every hop.
for hop in "${HOPS[@]}"; do
  artifact="${ARTIFACT_DIR}/$(hop_script_name "$hop")"
  if ! python3 - "$ROOT" "$artifact" "$LOCAL_KEY_FINGERPRINT" <<'PY' 2>>"$EVIDENCE_LOG"
import importlib.util, sys
root, artifact, want = sys.argv[1:4]
mod_path = root + "/scripts/lib/build_client_xenial_to_bionic.py"
spec = importlib.util.spec_from_file_location("build_client_x2b", mod_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
info = mod.verify_client_artifact_signature(artifact, allowed_fingerprint=want)
print("LOCAL_SIGNATURE_VERIFY=PASS fingerprint=%s" % info["fingerprint"])
PY
  then
    fail_build "$hop" "signing_verify" "LOCAL_SIGNATURE_VERIFY=FAIL hop=${hop}" 1
  fi
done
evidence_echo "CLIENT_SET_SIGN_COMPLETE=YES"
evidence_echo "INSTALL_SIGNS_LOCAL_CLIENT_SET=YES"
evidence_echo "LOCAL_MANIFEST_SIGNING=PASS"
evidence_echo "LOCAL_PUBLIC_KEY_EXPORT=PASS"
evidence_echo "LOCAL_SIGNATURE_VERIFY=PASS"
evidence_echo "ALL_FOUR_CLIENTS_BUILT=YES"
evidence_echo "ALL_FOUR_CLIENTS_SIGNED=YES"
evidence_echo "ALL_FOUR_CLIENTS_SIGNATURE_VALID=YES"
echo "CLIENT_SET_SIGN_COMPLETE=YES"
echo "INSTALL_SIGNS_LOCAL_CLIENT_SET=YES"
echo "LOCAL_MANIFEST_SIGNING=PASS"
echo "LOCAL_PUBLIC_KEY_EXPORT=PASS"
echo "LOCAL_SIGNATURE_VERIFY=PASS"
echo "ALL_FOUR_CLIENTS_BUILT=YES"
echo "ALL_FOUR_CLIENTS_SIGNED=YES"
echo "ALL_FOUR_CLIENTS_SIGNATURE_VALID=YES"

if [[ "$SKIP_DEPLOY" == "1" ]]; then
  evidence_echo "CLIENT_DEPLOY=SKIPPED"
  evidence_echo "REBUILD_PUBLISH_CLIENTS=PASS"
  echo "CLIENT_DEPLOY=SKIPPED"
  echo "REBUILD_PUBLISH_CLIENTS=PASS"
  exit 0
fi

STAGE_DIR="$(mktemp -d "${CLIENT_HTTP_ROOT}.stage.XXXXXX")"
# mktemp -d creates 0700; nginx (www-data) cannot traverse 0700 roots after swap.
chmod 0755 "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
# Ensure live parent spool allows nginx traversal before publish.
chmod 0755 "$(dirname "$CLIENT_HTTP_ROOT")" 2>/dev/null || true

# Stage full set: clients, sidecars, hop dirs, public key, fingerprint, phase2 helpers.
for hop in "${HOPS[@]}"; do
  name="$(hop_script_name "$hop")"
  install -m 0755 "${ARTIFACT_DIR}/${name}" "${STAGE_DIR}/${name}"
  if [[ -f "${ARTIFACT_DIR}/${name}.sha256" ]]; then
    install -m 0644 "${ARTIFACT_DIR}/${name}.sha256" "${STAGE_DIR}/${name}.sha256"
  else
    ( cd "$STAGE_DIR" && sha256sum "$name" >"${name}.sha256" )
  fi
  if [[ -d "${ARTIFACT_DIR}/${hop}" ]]; then
    mkdir -p "${STAGE_DIR}/${hop}"
    chmod 0755 "${STAGE_DIR}/${hop}"
    cp -a "${ARTIFACT_DIR}/${hop}/." "${STAGE_DIR}/${hop}/"
  fi
done

# Publish armored public key + binary gpgv keyring + fingerprint metadata
# (never the private key). Local on-disk public.gpg format is unchanged.
if ! local_signing_stage_http_public_artifacts "$STAGE_DIR" \
  "$LOCAL_SIGNING_PUBLIC_KEY" "$LOCAL_KEY_FINGERPRINT"
then
  evidence "CLIENT_PUBLIC_BINARY_KEYRING_BUILD=FAIL"
  evidence "CLIENT_SET_ATOMIC_SWAP=NOT_STARTED"
  echo "CLIENT_PUBLIC_BINARY_KEYRING_BUILD=FAIL" >&2
  echo "CLIENT_SET_ATOMIC_SWAP=NOT_STARTED" >&2
  fail_build "" "public_keyring_build" "CLIENT_PUBLIC_BINARY_KEYRING_BUILD=FAIL" 1
fi
evidence_echo "CLIENT_PUBLIC_ARMORED_KEY_PUBLISH=PASS"
evidence_echo "CLIENT_PUBLIC_BINARY_KEYRING_BUILD=PASS"
evidence_echo "CLIENT_PUBLIC_BINARY_KEYRING_FORMAT=OPENPGP_BINARY"
evidence_echo "CLIENT_PUBLIC_BINARY_KEYRING_FINGERPRINT=PASS"
printf '%s\n' "$LOCAL_KEY_FINGERPRINT" >"${STAGE_DIR}/signing-key-fingerprint"
chmod 0644 "${STAGE_DIR}/signing-key-fingerprint"
if [[ -f "$LOCAL_SIGNING_FINGERPRINT_FILE" ]]; then
  install -m 0644 "$LOCAL_SIGNING_FINGERPRINT_FILE" "${STAGE_DIR}/fingerprint"
fi

# Phase 2 helpers from source tree (not host-pinned hop clients).
for f in stage-dp-phase2.sh stage-dp-phase2-6.6.0.sh stage-dp-phase2-6.5.0.sh bringup_py3_dp_lifecycle.sh; do
  if [[ -f "${ROOT}/client/${f}" ]]; then
    install -m 0755 "${ROOT}/client/${f}" "${STAGE_DIR}/${f}"
    ( cd "$STAGE_DIR" && sha256sum "$f" >"${f}.sha256" )
  fi
done
# Menu 7 command-runner: signed checksum manifest + SHA256 sidecar.
if [[ -f "${ROOT}/client/dp-client-command-runner.sh" ]]; then
  if ! local_signing_stage_command_runner \
    "$STAGE_DIR" "${ROOT}/client/dp-client-command-runner.sh"
  then
    fail_build "" "command_runner_stage" "COMMAND_RUNNER_PUBLISH=FAIL" 1
  fi
  evidence_echo "COMMAND_RUNNER_PUBLISH=PASS"
fi
# Menu 7 OS-hop launchers: deterministic hash-pinned operator entrypoints.
LAUNCHER_BUILDER="${ROOT}/scripts/lib/build_client_launchers.py"
if [[ ! -f "$LAUNCHER_BUILDER" ]]; then
  fail_build "" "launcher_builder_missing" "missing ${LAUNCHER_BUILDER}" 1
fi
if ! python3 "$LAUNCHER_BUILDER" \
  --project-root "$ROOT" \
  --output-dir "$STAGE_DIR" \
  --mirror-base-url "$MIRROR_BASE" \
  --signing-fingerprint "$LOCAL_KEY_FINGERPRINT" \
  --print-env >>"$EVIDENCE_LOG"
then
  fail_build "" "launcher_build" "LAUNCHER_BUILD=FAIL" 1
fi
for hop in "${HOPS[@]}"; do
  lname="dp-launch-${hop}.sh"
  [[ -f "${STAGE_DIR}/${lname}" && -f "${STAGE_DIR}/${lname}.sha256" ]] || {
    fail_build "$hop" "launcher_missing" "missing staged launcher ${lname}" 1
  }
  ( cd "$STAGE_DIR" && sha256sum -c "${lname}.sha256" >/dev/null ) || {
    fail_build "$hop" "launcher_checksum" "launcher sidecar mismatch ${lname}" 1
  }
  chmod 0644 "${STAGE_DIR}/${lname}" "${STAGE_DIR}/${lname}.sha256"
  evidence_echo "LAUNCHER_PUBLISH=PASS hop=${hop} file=${lname}"
  wname="upgrade-${hop}.sh"
  [[ -f "${STAGE_DIR}/${wname}" && -f "${STAGE_DIR}/${wname}.sha256" ]] || {
    fail_build "$hop" "os_wrapper_missing" "missing staged OS wrapper ${wname}" 1
  }
  ( cd "$STAGE_DIR" && sha256sum -c "${wname}.sha256" >/dev/null ) || {
    fail_build "$hop" "os_wrapper_checksum" "OS wrapper sidecar mismatch ${wname}" 1
  }
  bash -n "${STAGE_DIR}/${wname}" || {
    fail_build "$hop" "os_wrapper_bash_n" "OS wrapper bash -n failed ${wname}" 1
  }
  chmod 0644 "${STAGE_DIR}/${wname}" "${STAGE_DIR}/${wname}.sha256"
  evidence_echo "OS_UPGRADE_WRAPPER_PUBLISH=PASS hop=${hop} file=${wname}"
done
evidence_echo "LAUNCHER_SET_PUBLISH=PASS"
evidence_echo "OS_UPGRADE_WRAPPER_SET_PUBLISH=PASS"
evidence_echo "CLIENT_LAUNCHER_SCHEMA_VERSION=${CLIENT_LAUNCHER_SCHEMA_VERSION:-1}"
if [[ -d "${ROOT}/client/lib" ]]; then
  mkdir -p "${STAGE_DIR}/lib"
  chmod 0755 "${STAGE_DIR}/lib"
  cp -a "${ROOT}/client/lib/." "${STAGE_DIR}/lib/"
fi
# shellcheck source=lib/phase2_helper_generation.sh
source "${ROOT}/scripts/lib/phase2_helper_generation.sh"
if ! phase2_helper_generation_write "$STAGE_DIR" >/dev/null; then
  fail_build "" "phase2_helper_generation" "PHASE2_HELPER_GENERATION=FAIL" 1
fi
evidence_echo "PHASE2_HELPER_GENERATION=PASS"
if ! phase2_upgrade_wrapper_write "$STAGE_DIR" "$MIRROR_BASE" \
  "${PHASE2_TARGET_VERSION:-6.6.0}" >/dev/null
then
  fail_build "" "phase2_upgrade_wrapper" "PHASE2_UPGRADE_WRAPPER=FAIL" 1
fi
( cd "$STAGE_DIR" && sha256sum -c upgrade-phase2.sh.sha256 >/dev/null ) || {
  fail_build "" "phase2_upgrade_wrapper_checksum" "Phase 2 wrapper sidecar mismatch" 1
}
evidence_echo "PHASE2_UPGRADE_WRAPPER_PUBLISH=PASS"

local_signing_assert_private_not_published "$STAGE_DIR" || {
  evidence "PRIVATE_KEY_HTTP_PUBLISHED=YES"
  evidence "CLIENT_SET_ATOMIC_SWAP=NOT_STARTED"
  echo "CLIENT_SET_ATOMIC_SWAP=NOT_STARTED" >&2
  fail_build "" "private_key_staged" "CLIENT_SET_DEPLOY_ATOMIC=NO private key staged for HTTP" 1
}
evidence_echo "PRIVATE_KEY_HTTP_PUBLISHED=NO"

# Generation metadata for Menu 7 / client trust binding (public, 0644).
cat >"${STAGE_DIR}/client-set.env" <<EOF
CLIENT_SET_GENERATION_ID=${CLIENT_BUILD_GENERATION_ID}
CLIENT_SIGNING_FINGERPRINT=${LOCAL_KEY_FINGERPRINT}
MIRROR_HTTP_URL=${MIRROR_BASE}
PREPARATION_MODE=${PREPARATION_MODE:-FULL}
PHASE2_TARGET_VERSION=${PHASE2_TARGET_VERSION:-6.6.0}
CLIENT_PROVENANCE_SCHEMA_VERSION=${CLIENT_PROVENANCE_SCHEMA_VERSION}
CLIENT_BUILD_INPUT_SHA256=${CLIENT_BUILD_INPUT_SHA256}
CLIENT_SOURCE_REVISION=${CLIENT_SOURCE_REVISION}
CLIENT_SOURCE_TREE_STATE=${CLIENT_SOURCE_TREE_STATE}
CLIENT_BUILD_SOURCE_REVISION=${CLIENT_BUILD_SOURCE_REVISION}
CLIENT_RUNTIME_MANIFEST_SHA256=${CLIENT_RUNTIME_MANIFEST_SHA256}
CLIENT_BUILDERS_SHA256=${CLIENT_BUILDERS_SHA256}
CLIENT_TEMPLATES_SHA256=${CLIENT_TEMPLATES_SHA256}
CLIENT_SHARED_HELPERS_SHA256=${CLIENT_SHARED_HELPERS_SHA256}
CLIENT_RUNNER_SHA256=${CLIENT_RUNNER_SHA256}
CLIENT_COMMAND_BLOCK_VERSION=${CLIENT_COMMAND_BLOCK_VERSION}
CLIENT_LAUNCHER_SCHEMA_VERSION=${CLIENT_LAUNCHER_SCHEMA_VERSION}
CLIENT_MIRROR_BASE_URL=${CLIENT_MIRROR_BASE_URL}
CLIENT_BUILD_CREATED_UTC=${CLIENT_BUILD_CREATED_UTC}
CREATED_UTC=${CLIENT_BUILD_CREATED_UTC}
EOF
# Bind published launcher and operator-wrapper digests into client-set metadata.
for hop in "${HOPS[@]}"; do
  lname="dp-launch-${hop}.sh"
  lsha="$(awk '{print $1; exit}' "${STAGE_DIR}/${lname}.sha256")"
  meta_key="CLIENT_LAUNCHER_$(printf '%s' "$hop" | tr 'a-z-' 'A-Z_')_SHA256"
  printf '%s=%s\n' "$meta_key" "$lsha" >>"${STAGE_DIR}/client-set.env"
  wname="upgrade-${hop}.sh"
  wsha="$(awk '{print $1; exit}' "${STAGE_DIR}/${wname}.sha256")"
  wkey="CLIENT_WRAPPER_$(printf '%s' "$hop" | tr 'a-z-' 'A-Z_')_SHA256"
  printf '%s=%s\n' "$wkey" "$wsha" >>"${STAGE_DIR}/client-set.env"
done
p2sha="$(awk '{print $1; exit}' "${STAGE_DIR}/upgrade-phase2.sh.sha256")"
printf 'CLIENT_WRAPPER_PHASE2_SHA256=%s\n' "$p2sha" >>"${STAGE_DIR}/client-set.env"
chmod 0644 "${STAGE_DIR}/client-set.env"

# Final verify on staged tree before cutover.
for hop in "${HOPS[@]}"; do
  name="$(hop_script_name "$hop")"
  ( cd "$STAGE_DIR" && sha256sum -c "${name}.sha256" >/dev/null ) || {
    fail_build "$hop" "prepublish_checksum" "CLIENT_SET_VERIFY_COMPLETE=NO checksum ${name}" 1
  }
  client_assert_mirror_base_match "${STAGE_DIR}/${name}" "$MIRROR_BASE" || {
    fail_build "$hop" "prepublish_pin" "prepublish pin gate failed" 1
  }
  wname="upgrade-${hop}.sh"
  ( cd "$STAGE_DIR" && sha256sum -c "${wname}.sha256" >/dev/null ) || {
    fail_build "$hop" "prepublish_wrapper_checksum" "CLIENT_SET_VERIFY_COMPLETE=NO checksum ${wname}" 1
  }
done
( cd "$STAGE_DIR" && sha256sum -c upgrade-phase2.sh.sha256 >/dev/null ) || {
  fail_build "" "prepublish_phase2_wrapper_checksum" "CLIENT_SET_VERIFY_COMPLETE=NO checksum upgrade-phase2.sh" 1
}

# Binary keyring + gpgv against every hop manifest — fail closed, no swap.
if ! local_signing_prepublish_keyring_gate "$STAGE_DIR" "$LOCAL_KEY_FINGERPRINT" "${HOPS[@]}"; then
  evidence "CLIENT_SET_ATOMIC_SWAP=NOT_STARTED"
  echo "CLIENT_SET_ATOMIC_SWAP=NOT_STARTED" >&2
  fail_build "" "public_keyring_verify" "CLIENT_PUBLIC_BINARY_KEYRING / gpgv prepublish FAIL" 1
fi
for hop in "${HOPS[@]}"; do
  evidence_echo "CLIENT_MANIFEST_GPGV_VERIFY=PASS hop=${hop}"
done

if ! python3 "$CLIENT_PROVENANCE_MODULE" verify-client-set \
  --project-root "$ROOT" \
  --client-root "$STAGE_DIR" \
  --expected-mirror "$MIRROR_BASE" \
  --expected-fingerprint "$LOCAL_KEY_FINGERPRINT" \
  --expected-mode "${PREPARATION_MODE:-FULL}" >>"$EVIDENCE_LOG" 2>&1
then
  evidence "CLIENT_SET_ATOMIC_SWAP=NOT_STARTED"
  fail_build "" "build_provenance" "CLIENT_BUILD_PROVENANCE=FAIL" 1
fi
evidence_echo "CLIENT_BUILD_PROVENANCE=PASS"
evidence_echo "CLIENT_SET_PREPUBLISH_VERIFY=PASS"
evidence_echo "CLIENT_SET_VERIFY_COMPLETE=YES"
evidence_echo "ALL_FOUR_CLIENTS_PREPUBLISH_VERIFIED=YES"
echo "CLIENT_SET_PREPUBLISH_VERIFY=PASS"
echo "CLIENT_SET_VERIFY_COMPLETE=YES"
echo "ALL_FOUR_CLIENTS_PREPUBLISH_VERIFIED=YES"

# Permission contract before atomic swap — never publish a 0700 tree.
# On failure leave the existing live client set untouched.
if ! mm_client_stage_prepare_public_permissions "$STAGE_DIR" "$(dirname "$CLIENT_HTTP_ROOT")"; then
  evidence "CLIENT_PUBLIC_PERMISSION_VERIFY=FAIL"
  evidence "CLIENT_SET_ATOMIC_SWAP=NOT_STARTED"
  echo "CLIENT_PUBLIC_PERMISSION_VERIFY=FAIL" >&2
  echo "CLIENT_SET_ATOMIC_SWAP=NOT_STARTED" >&2
  fail_build "" "prepublish_permissions" "CLIENT_PUBLIC_PERMISSION_PREPUBLISH_VERIFY=FAIL" 1
fi
evidence_echo "CLIENT_PUBLIC_PERMISSION_NORMALIZE=PASS"
evidence_echo "CLIENT_PUBLIC_PERMISSION_PREPUBLISH_VERIFY=PASS"
evidence_echo "CLIENT_PUBLIC_ROOT_MODE=0755"

# Atomic directory swap with rollback-safe helper.
# atomic_dir_swap.py must not alter permissions; staging is already correct.
set +e
swap_out="$(python3 "${ROOT}/scripts/lib/atomic_dir_swap.py" \
  --stage-dir "$STAGE_DIR" \
  --live-dir "$CLIENT_HTTP_ROOT" 2>&1)"
swap_rc=$?
set -e
printf '%s\n' "$swap_out" | tee -a "$EVIDENCE_LOG"
if [[ "$swap_rc" -ne 0 ]]; then
  STAGE_DIR=""  # may already be moved/cleaned by helper
  fail_build "" "atomic_swap" "CLIENT_SET_ATOMIC_SWAP=FAIL" "$swap_rc"
fi
STAGE_DIR=""

local_signing_assert_private_not_published "$CLIENT_HTTP_ROOT" || {
  fail_build "" "private_key_published" "private key present under client HTTP root" 1
}

if ! mm_client_live_postpublish_permission_verify "$CLIENT_HTTP_ROOT"; then
  evidence "CLIENT_PUBLIC_PERMISSION_POSTPUBLISH_VERIFY=FAIL"
  fail_build "" "postpublish_permissions" "CLIENT_PUBLIC_PERMISSION_POSTPUBLISH_VERIFY=FAIL" 1
fi
evidence_echo "CLIENT_PUBLIC_PERMISSION_POSTPUBLISH_VERIFY=PASS"
evidence_echo "CLIENT_PUBLIC_NGINX_USER_READ=PASS"
evidence_echo "CLIENT_PUBLIC_ROOT_MODE=0755"

evidence_echo "CLIENT_SET_ATOMIC_SWAP=PASS"
evidence_echo "CLIENT_SET_ROLLBACK=NOT_REQUIRED"
evidence_echo "CLIENT_SET_DEPLOY_ATOMIC=YES"
evidence_echo "INSTALL_ATOMICALLY_PUBLISHES_FULL_SET=YES"
evidence_echo "INSTALL_PUBLISHES_LOCAL_PUBLIC_KEY=YES"
evidence_echo "PRIVATE_KEY_HTTP_PUBLISHED=NO"
evidence_echo "ALL_FOUR_CLIENTS_ATOMICALLY_PUBLISHED=YES"
evidence_echo "CLIENT_SET_ON_DISK_READY=PASS"
echo "CLIENT_SET_ATOMIC_SWAP=PASS"
echo "CLIENT_SET_ROLLBACK=NOT_REQUIRED"
echo "CLIENT_SET_DEPLOY_ATOMIC=YES"
echo "INSTALL_ATOMICALLY_PUBLISHES_FULL_SET=YES"
echo "INSTALL_PUBLISHES_LOCAL_PUBLIC_KEY=YES"
echo "PRIVATE_KEY_HTTP_PUBLISHED=NO"
echo "ALL_FOUR_CLIENTS_ATOMICALLY_PUBLISHED=YES"
echo "CLIENT_SET_ON_DISK_READY=PASS"

# Persist generation metadata into the live client set + workflow state.
if [[ -f "${ROOT}/scripts/lib/mirror_workflow_state.sh" ]]; then
  # Prefer the signing confdir parent as the workflow state home when unset.
  if [[ -z "${MM_WORKFLOW_FILE:-}" ]]; then
    if [[ -n "${MM_CONFIG_DIR:-}" ]]; then
      MM_WORKFLOW_FILE="${MM_CONFIG_DIR}/dp-upgrade-workflow.state"
    elif [[ -n "${LOCAL_CLIENT_SIGNING_DIR:-}" ]]; then
      MM_WORKFLOW_FILE="$(dirname "${LOCAL_CLIENT_SIGNING_DIR}")/dp-upgrade-workflow.state"
    fi
    export MM_WORKFLOW_FILE
  fi
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/lib/mirror_workflow_state.sh"
  mm_wf_write_client_set_metadata \
    "$CLIENT_HTTP_ROOT" \
    "$CLIENT_BUILD_GENERATION_ID" \
    "$LOCAL_KEY_FINGERPRINT" \
    "$MIRROR_BASE" \
    "${PREPARATION_MODE:-FULL}" \
    "$CLIENT_BUILD_INPUT_SHA256" \
    "$CLIENT_SOURCE_REVISION" \
    "$CLIENT_RUNTIME_MANIFEST_SHA256" \
    "$CLIENT_BUILDERS_SHA256" \
    "$CLIENT_TEMPLATES_SHA256" \
    "$CLIENT_SHARED_HELPERS_SHA256" \
    "$CLIENT_RUNNER_SHA256" \
    "$CLIENT_COMMAND_BLOCK_VERSION" \
    "$CLIENT_PROVENANCE_SCHEMA_VERSION" \
    "$CLIENT_SOURCE_TREE_STATE" \
    "$CLIENT_MIRROR_BASE_URL" \
    "$CLIENT_BUILD_CREATED_UTC" \
    "${CLIENT_LAUNCHER_SCHEMA_VERSION:-1}"
  mm_wf_mark_client_set_published \
    "$CLIENT_BUILD_GENERATION_ID" \
    "$LOCAL_KEY_FINGERPRINT" \
    "$CLIENT_BUILD_INPUT_SHA256" \
    "$CLIENT_SOURCE_REVISION" \
    "$CLIENT_RUNTIME_MANIFEST_SHA256" \
    "$CLIENT_COMMAND_BLOCK_VERSION" \
    "$CLIENT_PROVENANCE_SCHEMA_VERSION" \
    || evidence_echo "WORKFLOW_STATE_UPDATE=SKIPPED"
  evidence_echo "CLIENT_SET_GENERATION_ID=${CLIENT_BUILD_GENERATION_ID}"
  evidence_echo "CLIENT_SIGNING_FINGERPRINT=${LOCAL_KEY_FINGERPRINT}"
  echo "CLIENT_SET_GENERATION_ID=${CLIENT_BUILD_GENERATION_ID}"
  echo "CLIENT_SIGNING_FINGERPRINT=${LOCAL_KEY_FINGERPRINT}"
fi

if [[ "$SKIP_HTTP_VERIFY" == "1" ]]; then
  evidence_echo "CLIENT_PUBLISH_HTTP_VERIFY=SKIPPED"
  evidence_echo "CLIENT_HTTP_READY=DEFERRED"
  echo "CLIENT_PUBLISH_HTTP_VERIFY=SKIPPED"
  echo "CLIENT_HTTP_READY=DEFERRED"
else
  tmp="$(mktemp -d)"
  for hop in "${HOPS[@]}"; do
    name="$(hop_script_name "$hop")"
    curl -fsS -o "${tmp}/${name}" "${MIRROR_BASE}/client/${name}" || {
      rm -rf "$tmp"
      fail_build "$hop" "http_verify_fetch" "CLIENT_PUBLISH_HTTP_VERIFY=FAIL hop=${hop} fetch" 1
    }
    local_sha="$(sha256sum "${ARTIFACT_DIR}/${name}" | awk '{print $1}')"
    http_sha="$(sha256sum "${tmp}/${name}" | awk '{print $1}')"
    [[ "$local_sha" == "$http_sha" ]] || {
      rm -rf "$tmp"
      fail_build "$hop" "http_verify_sha" "CLIENT_PUBLISH_HTTP_VERIFY=FAIL hop=${hop} sha mismatch" 1
    }
    client_assert_mirror_base_match "${tmp}/${name}" "$MIRROR_BASE" >/dev/null || {
      rm -rf "$tmp"
      fail_build "$hop" "http_verify_pin" "CLIENT_PUBLISH_HTTP_VERIFY=FAIL hop=${hop} pin mismatch" 1
    }
    evidence_echo "CLIENT_PUBLISH_HTTP_VERIFY=PASS hop=${hop} sha256=${http_sha}"
    echo "CLIENT_PUBLISH_HTTP_VERIFY=PASS hop=${hop} sha256=${http_sha}"
  done
  curl -fsS -o "${tmp}/public.gpg" "${MIRROR_BASE}/client/public.gpg" \
    || curl -fsS -o "${tmp}/public.gpg" "${MIRROR_BASE}/client/offline-client-manifest.gpg" \
    || { rm -rf "$tmp"; fail_build "" "http_verify_pubkey" "CLIENT_PUBLISH_HTTP_VERIFY=FAIL public key" 1; }
  curl -fsS -o "${tmp}/public-keyring.gpg" "${MIRROR_BASE}/client/public-keyring.gpg" \
    || { rm -rf "$tmp"; fail_build "" "http_verify_keyring" "CLIENT_PUBLISH_HTTP_VERIFY=FAIL public-keyring.gpg" 1; }
  if ! local_signing_verify_binary_keyring "${tmp}/public-keyring.gpg" "$LOCAL_KEY_FINGERPRINT"; then
    rm -rf "$tmp"
    fail_build "" "http_verify_keyring_format" "CLIENT_PUBLISH_HTTP_VERIFY=FAIL binary keyring" 1
  fi
  rm -rf "$tmp"
  evidence_echo "CLIENT_HTTP_READY=PASS"
  echo "CLIENT_HTTP_READY=PASS"
fi

# Successful generation staging cleanup (keep evidence log).
rm -rf "$ARTIFACT_DIR"
evidence_echo "CLIENT_BUILD_STAGING_CLEANED=YES"
evidence_echo "REBUILD_PUBLISH_CLIENTS=PASS"
echo "REBUILD_PUBLISH_CLIENTS=PASS"
