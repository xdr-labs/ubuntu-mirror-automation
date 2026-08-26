#!/usr/bin/env bash
# Helper-only Phase 2 publish orchestration (no bundle regenerate, no READY/pointer moves).
# Modes:
#   (default)     deploy helpers + refresh release.env + verify
#   --metadata-only   refresh release.env only (skip helper redeploy)
#   --verify-only     read-only post-publish verification (no mutations)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=lib/dp-phase2-common.sh
source "${ROOT}/scripts/lib/dp-phase2-common.sh"
# shellcheck source=lib/mirror_host_ip.sh
source "${ROOT}/scripts/lib/mirror_host_ip.sh"

TARGET_DP_VERSION="${TARGET_DP_VERSION:-6.6.0}"
MIRROR_BASE="${RESOLVED_MIRROR_BASE_URL:-${MIRROR_BASE:-}}"
MIRROR_BASE="${MIRROR_BASE%/}"
if [[ -z "$MIRROR_BASE" ]]; then
  mirror_host_resolve_and_log || exit 1
  MIRROR_BASE="${RESOLVED_MIRROR_BASE_URL%/}"
fi
MIRROR_LOCAL="${MIRROR_LOCAL:-http://127.0.0.1}"
DP_PHASE2_ROOT="${DP_PHASE2_ROOT:-/var/spool/apt-mirror/dp-phase2}"
READY_PATH="${READY_PATH:-/var/spool/apt-mirror/selective/state/READY}"
NGINX_USER="${NGINX_USER:-www-data}"

MODE="full"
for arg in "$@"; do
  case "$arg" in
    --metadata-only) MODE="metadata-only" ;;
    --verify-only) MODE="verify-only" ;;
    --help|-h)
      cat <<EOF
Usage: $0 [--metadata-only|--verify-only]

  (default)         Deploy helpers, refresh release.env, verify HTTP
  --metadata-only   Only run release.env publisher + verify (no helper redeploy)
  --verify-only     Verify filesystem/HTTP/invariants only (no mutations)
EOF
      exit 0
      ;;
    *)
      echo "unknown argument: ${arg}" >&2
      exit 1
      ;;
  esac
done

if ! [[ "$TARGET_DP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "malformed TARGET_DP_VERSION=${TARGET_DP_VERSION}" >&2
  exit 1
fi

CANONICAL_HELPER="${ROOT}/client/stage-dp-phase2.sh"
COMPAT_HELPER="${ROOT}/client/stage-dp-phase2-${TARGET_DP_VERSION}.sh"
PUBLISHER="${ROOT}/scripts/update-dp-phase2-release-env-atomic.sh"
DEPLOY_HELPERS="${ROOT}/scripts/deploy-stage-dp-phase2-client-atomic.sh"
CURRENT="${DP_PHASE2_ROOT}/${TARGET_DP_VERSION}/current"
ENV_PATH="${CURRENT}/release.env"
BUNDLE_PATH="${CURRENT}/dp_bundle_${TARGET_DP_VERSION}-current.tar"
RELEASE_ENV_URL_LOCAL="${MIRROR_LOCAL}/dp-phase2/${TARGET_DP_VERSION}/release.env"
RELEASE_ENV_URL_MIRROR="${MIRROR_BASE}/dp-phase2/${TARGET_DP_VERSION}/release.env"

CANONICAL_HELPER_DEPLOY="SKIP"
COMPATIBILITY_HELPER_DEPLOY="SKIP"
RELEASE_ENV_DEPLOY="SKIP"
RELEASE_ENV_HTTP_VERIFY="SKIP"
HELPERS_HTTP_VERIFY="SKIP"
READY_UNCHANGED="UNKNOWN"
BUNDLE_UNCHANGED="UNKNOWN"
CURRENT_UNCHANGED="UNKNOWN"
HELPERS_ONLY_DEPLOY="FAIL"
FAILED_STEP=""

fail_step() {
  FAILED_STEP="$1"
  echo "FAILED_STEP=${FAILED_STEP}" >&2
  echo "CANONICAL_HELPER_DEPLOY=${CANONICAL_HELPER_DEPLOY}"
  echo "COMPATIBILITY_HELPER_DEPLOY=${COMPATIBILITY_HELPER_DEPLOY}"
  echo "RELEASE_ENV_DEPLOY=${RELEASE_ENV_DEPLOY}"
  echo "RELEASE_ENV_HTTP_VERIFY=${RELEASE_ENV_HTTP_VERIFY}"
  echo "HELPERS_HTTP_VERIFY=${HELPERS_HTTP_VERIFY}"
  echo "READY_UNCHANGED=${READY_UNCHANGED}"
  echo "BUNDLE_UNCHANGED=${BUNDLE_UNCHANGED}"
  echo "CURRENT_UNCHANGED=${CURRENT_UNCHANGED}"
  echo "HELPERS_ONLY_DEPLOY=FAIL"
  exit 1
}

preflight() {
  bash -n "$CANONICAL_HELPER" || fail_step "preflight_canonical_bash_n"
  bash -n "$COMPAT_HELPER" || fail_step "preflight_compat_bash_n"
  bash -n "$PUBLISHER" || fail_step "preflight_publisher_bash_n"
  bash -n "$DEPLOY_HELPERS" || fail_step "preflight_deploy_helpers_bash_n"

  # Canonical helper safety guards (same intent as deploy-stage script)
  grep -Eq '^[[:space:]]*BRINGUP_EXECUTED[[:space:]]*=[[:space:]]*"?NO"?[[:space:]]*$' "$CANONICAL_HELPER" \
    || fail_step "preflight_canonical_bringup_guard"
  if grep -Eq '^[[:space:]]*BRINGUP_EXECUTED[[:space:]]*=[[:space:]]*"?YES"?[[:space:]]*$' "$CANONICAL_HELPER"; then
    fail_step "preflight_canonical_bringup_yes"
  fi
  if grep -Ev '^[[:space:]]*#' "$CANONICAL_HELPER" | grep -Eiq 'https?://[^[:space:]]*stellarcyber\.ai([/:]|$)'; then
    fail_step "preflight_canonical_stellar_url"
  fi
  if grep -Eq '^VERSION=|^[[:space:]]*VERSION=' "$CANONICAL_HELPER"; then
    fail_step "preflight_canonical_ambiguous_version"
  fi
  grep -q -- "--target-version ${TARGET_DP_VERSION}" "$COMPAT_HELPER" \
    || fail_step "preflight_compat_target_guard"

  [[ -L "$CURRENT" || -d "$CURRENT" ]] || fail_step "preflight_current_missing"
  [[ -f "$BUNDLE_PATH" || -L "$BUNDLE_PATH" ]] || fail_step "preflight_bundle_missing"
  [[ -f "$ENV_PATH" ]] || fail_step "preflight_release_env_missing"
  if dp2_release_has_secret "$ENV_PATH"; then
    fail_step "preflight_release_env_secret"
  fi
  [[ -f "$READY_PATH" ]] || fail_step "preflight_ready_missing"

  # Candidate dry-run in a temp fixture (content/mode only; no production write)
  local fixture candidate_root candidate_current
  fixture="$(mktemp -d)"
  candidate_root="${fixture}/dp-phase2"
  candidate_current="${candidate_root}/${TARGET_DP_VERSION}/current"
  mkdir -p "$candidate_current"
  # Minimal stable bundle stub (publisher only needs a real file for inode/size)
  : >"${candidate_current}/dp_bundle_${TARGET_DP_VERSION}-current.tar"
  cp -a "$ENV_PATH" "${candidate_current}/release.env"
  chmod 0600 "${candidate_current}/release.env" 2>/dev/null || true
  local ready_tmp
  ready_tmp="$(mktemp)"
  cp -a "$READY_PATH" "$ready_tmp"
  if ! DP_PHASE2_SKIP_ROOT_CHECK=1 \
      DP_PHASE2_ROOT="$candidate_root" \
      READY_PATH="$ready_tmp" \
      bash "$PUBLISHER" "$TARGET_DP_VERSION" >/dev/null; then
    rm -rf "$fixture" "$ready_tmp"
    fail_step "preflight_candidate_publisher"
  fi
  local cand_mode
  cand_mode="$(stat -c '%a' "${candidate_current}/release.env")"
  [[ "$cand_mode" == "644" ]] || {
    rm -rf "$fixture" "$ready_tmp"
    fail_step "preflight_candidate_mode"
  }
  if dp2_release_has_secret "${candidate_current}/release.env"; then
    rm -rf "$fixture" "$ready_tmp"
    fail_step "preflight_candidate_secret"
  fi
  rm -rf "$fixture" "$ready_tmp"
  echo "PREFLIGHT=PASS"
}

collect_invariants_before() {
  READY_BEFORE="$(sha256sum "$READY_PATH" | awk '{print $1}')"
  BUNDLE_REAL="$(readlink -f "$BUNDLE_PATH")"
  BUNDLE_BEFORE="$(stat -c '%i %s' "$BUNDLE_REAL")"
  CURRENT_BEFORE="$(readlink -f "$CURRENT")"
  echo "READY_BEFORE=${READY_BEFORE}"
  echo "BUNDLE_BEFORE=${BUNDLE_BEFORE}"
  echo "CURRENT_BEFORE=${CURRENT_BEFORE}"
}

check_invariants_after() {
  local ready_after bundle_after current_after
  ready_after="$(sha256sum "$READY_PATH" | awk '{print $1}')"
  bundle_after="$(stat -c '%i %s' "$(readlink -f "$BUNDLE_PATH")")"
  current_after="$(readlink -f "$CURRENT")"
  if [[ "$ready_after" == "$READY_BEFORE" ]]; then
    READY_UNCHANGED="YES"
  else
    READY_UNCHANGED="NO"
    fail_step "invariant_ready"
  fi
  if [[ "$bundle_after" == "$BUNDLE_BEFORE" ]]; then
    BUNDLE_UNCHANGED="YES"
  else
    BUNDLE_UNCHANGED="NO"
    fail_step "invariant_bundle"
  fi
  if [[ "$current_after" == "$CURRENT_BEFORE" ]]; then
    CURRENT_UNCHANGED="YES"
  else
    CURRENT_UNCHANGED="NO"
    fail_step "invariant_current"
  fi
}

verify_release_env_fs() {
  local mode og
  mode="$(stat -c '%a' "$ENV_PATH")"
  [[ "$mode" == "644" ]] || fail_step "release_env_mode"
  echo "RELEASE_ENV_MODE=${mode}"
  echo "RELEASE_ENV_PERMISSION_CHECK=PASS"
  if [[ "$(id -u)" -eq 0 ]]; then
    og="$(stat -c '%U:%G' "$ENV_PATH")"
    [[ "$og" == "root:root" ]] || fail_step "release_env_owner_group"
    echo "RELEASE_ENV_OWNER_GROUP=${og}"
    if id -u "$NGINX_USER" >/dev/null 2>&1; then
      if sudo -n -u "$NGINX_USER" test -r "$ENV_PATH" 2>/dev/null; then
        echo "RELEASE_ENV_NGINX_READABLE=PASS"
      elif su -s /bin/sh "$NGINX_USER" -c "test -r '$ENV_PATH'" 2>/dev/null; then
        echo "RELEASE_ENV_NGINX_READABLE=PASS"
      else
        fail_step "release_env_nginx_readable"
      fi
    fi
  fi
  grep -qE "^TARGET_DP_VERSION=${TARGET_DP_VERSION}$" "$ENV_PATH" || fail_step "release_env_target_field"
  grep -qE "^PHASE2_ARTIFACT_VERSION=${TARGET_DP_VERSION}$" "$ENV_PATH" || fail_step "release_env_artifact_field"
  grep -qE "^DP_PHASE2_VERSION=${TARGET_DP_VERSION}$" "$ENV_PATH" || fail_step "release_env_compat_field"
  grep -qE "^STABLE_BUNDLE_NAME=dp_bundle_${TARGET_DP_VERSION}-current.tar$" "$ENV_PATH" \
    || fail_step "release_env_stable_bundle"
  grep -qE '^VERIFICATION_RESULT=PASS$' "$ENV_PATH" || fail_step "release_env_verification_result"
  if dp2_release_has_secret "$ENV_PATH"; then
    fail_step "release_env_secret_final"
  fi
}

verify_release_env_http() {
  local code_local code_mirror fs_sha local_sha mirror_sha
  # Canonical URLs only (never .../current/release.env)
  code_local="$(curl -sS -o /tmp/dp2-release.env.local.$$ -w '%{http_code}' --max-time 15 \
    "$RELEASE_ENV_URL_LOCAL" || true)"
  [[ "$code_local" == "200" ]] || {
    echo "HTTP local code=${code_local} url=${RELEASE_ENV_URL_LOCAL}" >&2
    rm -f /tmp/dp2-release.env.local.$$
    fail_step "release_env_http_local"
  }
  code_mirror="$(curl -sS -o /tmp/dp2-release.env.mirror.$$ -w '%{http_code}' --max-time 15 \
    "$RELEASE_ENV_URL_MIRROR" || true)"
  [[ "$code_mirror" == "200" ]] || {
    echo "HTTP mirror code=${code_mirror} url=${RELEASE_ENV_URL_MIRROR}" >&2
    rm -f /tmp/dp2-release.env.local.$$ /tmp/dp2-release.env.mirror.$$
    fail_step "release_env_http_mirror"
  }
  fs_sha="$(sha256sum "$ENV_PATH" | awk '{print $1}')"
  local_sha="$(sha256sum /tmp/dp2-release.env.local.$$ | awk '{print $1}')"
  mirror_sha="$(sha256sum /tmp/dp2-release.env.mirror.$$ | awk '{print $1}')"
  rm -f /tmp/dp2-release.env.local.$$ /tmp/dp2-release.env.mirror.$$
  [[ "$fs_sha" == "$local_sha" && "$fs_sha" == "$mirror_sha" ]] || fail_step "release_env_sha_match"
  echo "RELEASE_ENV_HTTP_LOCAL=PASS"
  echo "RELEASE_ENV_HTTP_MIRROR_IP=PASS"
  echo "RELEASE_ENV_SHA_MATCH=PASS"
  echo "FILESYSTEM_SHA=${fs_sha}"
  echo "LOCAL_HTTP_SHA=${local_sha}"
  echo "MIRROR_HTTP_SHA=${mirror_sha}"
  RELEASE_ENV_HTTP_VERIFY="PASS"
}

verify_helpers_http() {
  local u code name src_sha http_sha side_sha
  # Complete Phase 2 client unit: stage scripts + lifecycle + sourced libs.
  local -a unit_scripts=(
    stage-dp-phase2.sh
    "stage-dp-phase2-${TARGET_DP_VERSION}.sh"
    bringup_py3_dp_lifecycle.sh
  )
  local -a unit_libs=(
    lib/dp-offline-source-product-version.sh
    lib/dp-phase2-operation-progress.sh
    lib/dp-phase2-bringup-lifecycle.sh
    lib/dp-phase2-ubuntu-prerequisites.sh
  )
  for name in "${unit_scripts[@]}"; do
    for u in \
      "${MIRROR_LOCAL}/client/${name}" \
      "${MIRROR_LOCAL}/client/${name}.sha256" \
      "${MIRROR_BASE}/client/${name}" \
      "${MIRROR_BASE}/client/${name}.sha256"
    do
      code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$u" || true)"
      [[ "$code" == "200" ]] || {
        echo "HTTP ${code} ${u}" >&2
        fail_step "helpers_http_${name}"
      }
    done
    src_sha="$(sha256sum "${ROOT}/client/${name}" | awk '{print $1}')"
    http_sha="$(curl -fsS --max-time 15 "${MIRROR_LOCAL}/client/${name}" | sha256sum | awk '{print $1}')"
    side_sha="$(curl -fsS --max-time 15 "${MIRROR_LOCAL}/client/${name}.sha256" | awk '{print $1}')"
    [[ "$src_sha" == "$http_sha" && "$src_sha" == "$side_sha" ]] \
      || fail_step "helpers_sha_${name}"
    echo "HELPER_HTTP_VERIFY=PASS name=${name} sha256=${src_sha}"
  done
  for name in "${unit_libs[@]}"; do
    for u in \
      "${MIRROR_LOCAL}/client/${name}" \
      "${MIRROR_BASE}/client/${name}"
    do
      code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$u" || true)"
      [[ "$code" == "200" ]] || {
        echo "HTTP ${code} ${u}" >&2
        fail_step "helpers_http_${name}"
      }
    done
    src_sha="$(sha256sum "${ROOT}/client/${name}" | awk '{print $1}')"
    http_sha="$(curl -fsS --max-time 15 "${MIRROR_LOCAL}/client/${name}" | sha256sum | awk '{print $1}')"
    [[ "$src_sha" == "$http_sha" ]] || fail_step "helpers_sha_${name}"
    echo "HELPER_HTTP_VERIFY=PASS name=${name} sha256=${src_sha}"
  done
  name="phase2-helper-generation.manifest"
  for u in \
    "${MIRROR_LOCAL}/client/${name}" \
    "${MIRROR_BASE}/client/${name}"
  do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$u" || true)"
    [[ "$code" == "200" ]] || {
      echo "HTTP ${code} ${u}" >&2
      fail_step "helpers_http_${name}"
    }
  done
  src_sha="$(sha256sum "${ROOT}/client/${name}" | awk '{print $1}')"
  http_sha="$(curl -fsS --max-time 15 "${MIRROR_LOCAL}/client/${name}" | sha256sum | awk '{print $1}')"
  [[ "$src_sha" == "$http_sha" ]] || fail_step "helpers_sha_${name}"
  echo "HELPER_HTTP_VERIFY=PASS name=${name} sha256=${src_sha}"
  HELPERS_HTTP_VERIFY="PASS"
}

# ---- main ----
if [[ "$MODE" != "verify-only" ]]; then
  [[ "$(id -u)" -eq 0 || "${DP_PHASE2_SKIP_ROOT_CHECK:-0}" == "1" ]] || {
    echo "must run as root" >&2
    exit 1
  }
fi

collect_invariants_before

if [[ "$MODE" != "verify-only" ]]; then
  preflight
fi

if [[ "$MODE" == "full" ]]; then
  if bash "$DEPLOY_HELPERS"; then
    CANONICAL_HELPER_DEPLOY="PASS"
    COMPATIBILITY_HELPER_DEPLOY="PASS"
  else
    CANONICAL_HELPER_DEPLOY="FAIL"
    COMPATIBILITY_HELPER_DEPLOY="FAIL"
    fail_step "helper_deploy"
  fi
elif [[ "$MODE" == "metadata-only" ]]; then
  CANONICAL_HELPER_DEPLOY="SKIPPED_UNCHANGED"
  COMPATIBILITY_HELPER_DEPLOY="SKIPPED_UNCHANGED"
  echo "HELPER_REDEPLOY=SKIPPED (--metadata-only)"
fi

if [[ "$MODE" != "verify-only" ]]; then
  if bash "$PUBLISHER" "$TARGET_DP_VERSION"; then
    RELEASE_ENV_DEPLOY="PASS"
  else
    RELEASE_ENV_DEPLOY="FAIL"
    fail_step "release_env_deploy"
  fi
else
  RELEASE_ENV_DEPLOY="SKIPPED_VERIFY_ONLY"
fi

verify_release_env_fs
verify_release_env_http
verify_helpers_http
check_invariants_after

HELPERS_ONLY_DEPLOY="PASS"
echo "CANONICAL_HELPER_DEPLOY=${CANONICAL_HELPER_DEPLOY}"
echo "COMPATIBILITY_HELPER_DEPLOY=${COMPATIBILITY_HELPER_DEPLOY}"
echo "RELEASE_ENV_DEPLOY=${RELEASE_ENV_DEPLOY}"
echo "RELEASE_ENV_HTTP_VERIFY=${RELEASE_ENV_HTTP_VERIFY}"
echo "HELPERS_HTTP_VERIFY=${HELPERS_HTTP_VERIFY}"
echo "READY_UNCHANGED=${READY_UNCHANGED}"
echo "BUNDLE_UNCHANGED=${BUNDLE_UNCHANGED}"
echo "CURRENT_UNCHANGED=${CURRENT_UNCHANGED}"
echo "HELPERS_ONLY_DEPLOY=${HELPERS_ONLY_DEPLOY}"
echo "DEPLOY_VERIFY=PASS mode=${MODE}"
