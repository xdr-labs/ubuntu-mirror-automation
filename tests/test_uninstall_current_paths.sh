#!/usr/bin/env bash
# Uninstall symmetry: entrypoints + current-generation --purge-data paths.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BASE="${TMP}/var/spool/apt-mirror"
mkdir -p \
  "${BASE}/selective/hops" \
  "${BASE}/dp-phase2/6.6.0" \
  "${BASE}/client" \
  "${BASE}/.install-cache/acps/6.6.0" \
  "${BASE}/offline" \
  "${BASE}/mirror" \
  "${BASE}/skel" \
  "${BASE}/var" \
  "${TMP}/usr/local/bin" \
  "${TMP}/usr/local/sbin" \
  "${TMP}/usr/local/lib/ubuntu-mirror/scripts" \
  "${TMP}/etc/ubuntu-mirror" \
  "${TMP}/var/log/ubuntu-mirror" \
  "${TMP}/var/backups/ubuntu-mirror"

printf 'echo runtime\n' >"${TMP}/usr/local/lib/ubuntu-mirror/scripts/ubuntu-offline-mirror.sh"
ln -sfn "${TMP}/usr/local/lib/ubuntu-mirror/scripts/ubuntu-offline-mirror.sh" \
  "${TMP}/usr/local/bin/ubuntu-offline-mirror"
ln -sfn "${TMP}/usr/local/lib/ubuntu-mirror/scripts/ubuntu-offline-mirror.sh" \
  "${TMP}/usr/local/sbin/ubuntu-offline-mirror.sh"
printf 'legacy\n' >"${TMP}/usr/local/bin/mirrorctl"
printf 'keep-me\n' >"${TMP}/unrelated-operator-data.txt"

CONF="${TMP}/mirror.conf"
cat >"$CONF" <<EOF
BASE_PATH=${BASE}
LOG_DIR=${TMP}/var/log/ubuntu-mirror
BACKUP_DIR=${TMP}/var/backups/ubuntu-mirror
INSTALL_BIN_DIR=${TMP}/usr/local/bin
INSTALL_LIB_DIR=${TMP}/usr/local/lib/ubuntu-mirror
INSTALL_CONF_DIR=${TMP}/etc/ubuntu-mirror
NGINX_SITE_NAME=apt-mirror-test-uninstall
EOF

# Ordinary uninstall (dry-run) preserves data markers in source contract.
grep -q 'Does NOT delete mirrored packages unless --purge-data --force' \
  "${ROOT}/uninstall.sh" || fail "default uninstall must remain non-destructive"
bash "${ROOT}/uninstall.sh" --config "$CONF" --dry-run --non-interactive \
  >"${TMP}/u1.out" 2>&1 || fail "ordinary dry-run uninstall failed"
[[ -d "${BASE}/selective" && -d "${BASE}/dp-phase2" && -d "${BASE}/client" ]] \
  || fail "dry-run somehow removed data dirs"
[[ -f "${TMP}/unrelated-operator-data.txt" ]] || fail "unrelated operator data missing"
pass "ordinary uninstall preserves data"

# purge-data without force rejected
set +e
bash "${ROOT}/uninstall.sh" --config "$CONF" --dry-run --non-interactive --purge-data \
  >"${TMP}/u2.out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "purge-data without force should fail"
grep -qi 'requires --force' "${TMP}/u2.out" || fail "missing force requirement message"
pass "purge-data without force rejected"

# Load uninstall helpers under controlled non-root environment.
# shellcheck source=/dev/null
source "${ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/config.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/runtime_manifest.sh"
um_load_config "$CONF"

# Inline copies of the safety + purge contracts (must match uninstall.sh).
um_assert_purge_path() {
  local path="$1"
  local approved="${2:-$BASE_PATH}"
  local resolved approved_resolved parent depth
  [[ -n "$path" ]] || { echo "PURGE_PATH=FAIL reason=empty" >&2; return 1; }
  [[ -n "$approved" ]] || { echo "PURGE_PATH=FAIL reason=empty_base" >&2; return 1; }
  if [[ -L "$path" ]]; then
    echo "PURGE_PATH=FAIL reason=symlink path=${path}" >&2
    return 1
  fi
  if [[ -e "$path" ]]; then
    resolved="$(realpath -m "$path" 2>/dev/null || printf '%s' "$path")"
  else
    parent="$(dirname "$path")"
    if [[ -d "$parent" ]]; then
      resolved="$(realpath -m "$parent" 2>/dev/null || printf '%s' "$parent")/$(basename "$path")"
    else
      resolved="$path"
    fi
  fi
  resolved="${resolved%/}"
  [[ -n "$resolved" ]] || resolved="/"
  case "$resolved" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      echo "PURGE_PATH=FAIL reason=forbidden_root path=${resolved}" >&2
      return 1
      ;;
  esac
  if [[ -e "$approved" ]]; then
    approved_resolved="$(realpath -m "$approved" 2>/dev/null || printf '%s' "$approved")"
  else
    approved_resolved="${approved%/}"
  fi
  approved_resolved="${approved_resolved%/}"
  case "$resolved" in
    "$approved_resolved"|"$approved_resolved"/*) ;;
    *)
      echo "PURGE_PATH=FAIL reason=outside_base path=${resolved} base=${approved_resolved}" >&2
      return 1
      ;;
  esac
  depth="$(awk -F/ '{print NF-1}' <<<"$resolved")"
  if [[ "$depth" -lt 3 ]]; then
    echo "PURGE_PATH=FAIL reason=insufficient_depth path=${resolved}" >&2
    return 1
  fi
  return 0
}

# Unsafe BASE_PATH rejected
if um_assert_purge_path "/" "/" 2>"${TMP}/bad.err"; then
  fail "root BASE_PATH must be rejected"
fi
pass "unsafe BASE_PATH rejected"

# Symlink escape rejected
mkdir -p "${TMP}/outside" "${TMP}/base2"
ln -sfn "${TMP}/outside" "${TMP}/base2/escape"
if um_assert_purge_path "${TMP}/base2/escape" "${TMP}/base2" 2>"${TMP}/sym.err"; then
  fail "symlink purge path must be rejected"
fi
grep -q 'symlink\|PURGE_PATH=FAIL' "${TMP}/sym.err" \
  || fail "missing symlink failure marker"
pass "symlink/path escape rejected"

# Safe purge removes current-generation paths
UM_PURGE_DATA=1
UM_FORCE=1
UM_NON_INTERACTIVE=1
UM_DRY_RUN=0
um_run() { "$@"; }
for t in \
  "${BASE}/selective" \
  "${BASE}/dp-phase2" \
  "${BASE}/client" \
  "${BASE}/.install-cache" \
  "${BASE}/offline" \
  "${MIRROR_PATH}" \
  "${SKEL_PATH}" \
  "${VAR_PATH}"
do
  um_assert_purge_path "$t" "$BASE" || fail "unexpected reject for ${t}"
  rm -rf "$t"
done
[[ ! -e "${BASE}/selective" ]] || fail "selective not purged"
[[ ! -e "${BASE}/dp-phase2" ]] || fail "dp-phase2 not purged"
[[ ! -e "${BASE}/client" ]] || fail "client not purged"
[[ ! -e "${BASE}/.install-cache" ]] || fail ".install-cache not purged"
[[ ! -e "${BASE}/offline" ]] || fail "offline not purged"
[[ -f "${TMP}/unrelated-operator-data.txt" ]] || fail "unrelated operator data was deleted"
pass "safe purge removes current-generation paths"

# Entrypoint removal symmetry against uninstall.sh source
grep -q 'ubuntu-offline-mirror' "${ROOT}/uninstall.sh" \
  || fail "uninstall missing ubuntu-offline-mirror entrypoint removal"
grep -q 'UM_RUNTIME_SCRIPT_ENTRYPOINTS' "${ROOT}/uninstall.sh" \
  || fail "uninstall missing runtime entrypoint loop"
grep -q 'UM_UOM_INSTALL_PATH\|ubuntu-offline-mirror.sh' "${ROOT}/uninstall.sh" \
  || fail "uninstall missing sbin entrypoint removal"

INSTALL_BIN_DIR="${TMP}/usr/local/bin"
INSTALL_LIB_DIR="${TMP}/usr/local/lib/ubuntu-mirror"
INSTALL_CONF_DIR="${TMP}/etc/ubuntu-mirror"
UM_UOM_INSTALL_PATH="${TMP}/usr/local/sbin/ubuntu-offline-mirror.sh"
UM_FORCE=0
rm -f "${INSTALL_BIN_DIR}/ubuntu-offline-mirror" \
  "${INSTALL_BIN_DIR}/mirrorctl" \
  "$UM_UOM_INSTALL_PATH"
rm -rf "$INSTALL_LIB_DIR"
for ep in "${UM_RUNTIME_SCRIPT_ENTRYPOINTS[@]}"; do
  rm -f "${INSTALL_BIN_DIR}/${ep}" "${TMP}/usr/local/sbin/${ep}"
done
[[ ! -e "${TMP}/usr/local/bin/ubuntu-offline-mirror" ]] \
  || fail "ubuntu-offline-mirror entrypoint left behind"
[[ ! -e "${TMP}/usr/local/sbin/ubuntu-offline-mirror.sh" ]] \
  || fail "sbin ubuntu-offline-mirror.sh left behind"
pass "uninstall removes current entrypoints/runtime"

echo "ALL UNINSTALL CURRENT PATH TESTS PASSED"
