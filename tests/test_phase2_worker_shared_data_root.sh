#!/usr/bin/env bash
# SHARED_DATA_ROOT_METADATA_PRESERVED: worker staging must not chown/chmod an
# existing shared data root; project-owned children still harden; symlink roots
# fail closed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAGMENT="${ROOT}/scripts/lib/phase2_bringup_patch/fragment_compat.sh"
FAIL=0
PASS=0
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "======== test_phase2_worker_shared_data_root ========"

bash -n "$FRAGMENT" && pass "bash -n fragment" || fail "bash -n fragment"

# Static: shared data root is asserted, never ensure_safe_dir'd / chown'd.
grep -q 'phase2_assert_existing_data_root' "$FRAGMENT" \
  && ! grep -F 'phase2_ensure_safe_dir \"$data_root\"' "$FRAGMENT" \
  && pass "static: data_root asserted not ensure_safe_dir'd" \
  || fail "static: data_root still passed to phase2_ensure_safe_dir"

DATA_ROOT="${WORKDIR}/opt-aelladata"
STAGING="${DATA_ROOT}/aelladeb_py3"
AELLADEB="${DATA_ROOT}/aelladeb"
UPLOAD="${DATA_ROOT}/.phase2-worker-upload"
mkdir -p "$DATA_ROOT"
# Deliberately non-default shared-root metadata (must survive prepare).
chmod 0750 "$DATA_ROOT"
ROOT_MODE_BEFORE="$(stat -c '%a' "$DATA_ROOT")"
ROOT_OWNER_BEFORE="$(stat -c '%u:%g' "$DATA_ROOT")"

BIN="${WORKDIR}/bin"
mkdir -p "$BIN"
CHOWN_LOG="${WORKDIR}/chown.log"
: >"$CHOWN_LOG"
REAL_CHOWN="$(command -v chown)"
cat >"${BIN}/chown" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${CHOWN_LOG}"
# Hermetic: apply only when target owner matches the invoking user.
owner="\$1"
path="\$2"
case "\$owner" in
  root:root|0:0)
    # Staging dirs want root:root; record but do not require privileges.
    exit 0
    ;;
esac
exec "${REAL_CHOWN}" "\$@"
EOF
chmod +x "${BIN}/chown"

# Prefer real aella identity when present; otherwise stub for hermetic runs.
if ! id -u aella >/dev/null 2>&1; then
  cat >"${BIN}/id" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-u aella") printf '%s\n' "$(command id -u)" ;;
  "-g aella") printf '%s\n' "$(command id -g)" ;;
  *) exec /usr/bin/id "$@" ;;
esac
EOF
  chmod +x "${BIN}/id"
fi

export PATH="${BIN}:${PATH}"

log() { printf '%s\n' "$*"; }
worker_ssh() {
  shift
  local cmd="$*"
  # Mirror OpenSSH remote parsing: eval the same string ssh would hand to the
  # login shell. Drop only the leading sudo for hermetic non-root runs.
  if [[ "$cmd" == sudo\ * ]]; then
    cmd="${cmd#sudo }"
  fi
  eval "$cmd"
}

# shellcheck source=/dev/null
source "$FRAGMENT"
STAGING_DIR="$STAGING"
AELLADEB_DIR="$AELLADEB"
PHASE2_WORKER_UPLOAD_ROOT="$UPLOAD"
export STAGING_DIR AELLADEB_DIR PHASE2_WORKER_UPLOAD_ROOT

set +e
PREPARE_OUT="$(ensure_worker_protected_staging_dirs 192.0.2.50 2>&1; echo RC=$?)"
set -e

ROOT_MODE_AFTER="$(stat -c '%a' "$DATA_ROOT")"
ROOT_OWNER_AFTER="$(stat -c '%u:%g' "$DATA_ROOT")"

echo "$PREPARE_OUT" | grep -q 'RC=0' \
  && [[ "$ROOT_MODE_AFTER" == "$ROOT_MODE_BEFORE" ]] \
  && [[ "$ROOT_OWNER_AFTER" == "$ROOT_OWNER_BEFORE" ]] \
  && ! grep -Eq "(^|[[:space:]])${DATA_ROOT}([[:space:]]|$)" "$CHOWN_LOG" \
  && pass "SHARED_DATA_ROOT_METADATA_PRESERVED mode=${ROOT_MODE_AFTER} owner=${ROOT_OWNER_AFTER}" \
  || fail "data root mutated or prepare failed: out=${PREPARE_OUT} mode=${ROOT_MODE_AFTER} owner=${ROOT_OWNER_AFTER} chown_log=$(cat "$CHOWN_LOG")"

[[ -d "$UPLOAD" && -d "${UPLOAD}/lib" && -d "${UPLOAD}/aelladeb" ]] \
  && [[ -d "$STAGING" && -d "${STAGING}/lib" && -d "$AELLADEB" ]] \
  && [[ "$(stat -c '%a' "$UPLOAD")" == "700" ]] \
  && [[ "$(stat -c '%a' "${UPLOAD}/lib")" == "700" ]] \
  && [[ "$(stat -c '%a' "${UPLOAD}/aelladeb")" == "700" ]] \
  && [[ "$(stat -c '%a' "$STAGING")" == "755" ]] \
  && [[ "$(stat -c '%a' "${STAGING}/lib")" == "755" ]] \
  && [[ "$(stat -c '%a' "$AELLADEB")" == "755" ]] \
  && pass "WORKER_CHILD_DIR_HARDENING modes" \
  || fail "child dir modes unexpected: $(stat -c '%n %a' "$STAGING" "${STAGING}/lib" "$AELLADEB" "$UPLOAD" "${UPLOAD}/lib" "${UPLOAD}/aelladeb" 2>&1)"

# Numeric aella ownership recorded for upload tree (never aella:aella).
AELLA_UID="$(id -u aella 2>/dev/null || command id -u)"
AELLA_GID="$(id -g aella 2>/dev/null || command id -g)"
grep -Eq "${AELLA_UID}:${AELLA_GID}[[:space:]]+${UPLOAD}" "$CHOWN_LOG" \
  && ! grep -Eq 'aella:aella' "$CHOWN_LOG" \
  && pass "WORKER_NUMERIC_UID_GID chown=${AELLA_UID}:${AELLA_GID}" \
  || fail "numeric uid/gid missing in chown log: $(cat "$CHOWN_LOG")"

# Symlink data root must fail closed without mutating the victim.
VICTIM="${WORKDIR}/victim-data-root"
mkdir -p "$VICTIM"
chmod 0700 "$VICTIM"
printf 'keep\n' >"${VICTIM}/marker"
VICTIM_MODE_BEFORE="$(stat -c '%a' "$VICTIM")"
SYMLINK_ROOT="${WORKDIR}/symlink-data-root"
rm -rf "$SYMLINK_ROOT"
ln -s "$VICTIM" "$SYMLINK_ROOT"
STAGING_DIR="${SYMLINK_ROOT}/aelladeb_py3"
AELLADEB_DIR="${SYMLINK_ROOT}/aelladeb"
PHASE2_WORKER_UPLOAD_ROOT="${SYMLINK_ROOT}/.phase2-worker-upload"
export STAGING_DIR AELLADEB_DIR PHASE2_WORKER_UPLOAD_ROOT
set +e
SYM_OUT="$(ensure_worker_protected_staging_dirs 192.0.2.51 2>&1; echo RC=$?)"
set -e
echo "$SYM_OUT" | grep -q 'RC=1' \
  && echo "$SYM_OUT" | grep -Eq 'symlink_path|WORKER_STAGING_PREPARE=FAIL' \
  && [[ "$(stat -c '%a' "$VICTIM")" == "$VICTIM_MODE_BEFORE" ]] \
  && [[ "$(cat "${VICTIM}/marker")" == "keep" ]] \
  && pass "WORKER_DIR_SYMLINK_REJECT data_root" \
  || fail "symlink data root: ${SYM_OUT}"

# Missing data root fails closed (no silent recreate with ownership policy).
MISSING_ROOT="${WORKDIR}/missing-data-root"
STAGING_DIR="${MISSING_ROOT}/aelladeb_py3"
AELLADEB_DIR="${MISSING_ROOT}/aelladeb"
PHASE2_WORKER_UPLOAD_ROOT="${MISSING_ROOT}/.phase2-worker-upload"
export STAGING_DIR AELLADEB_DIR PHASE2_WORKER_UPLOAD_ROOT
set +e
MISS_OUT="$(ensure_worker_protected_staging_dirs 192.0.2.52 2>&1; echo RC=$?)"
set -e
echo "$MISS_OUT" | grep -q 'RC=1' \
  && echo "$MISS_OUT" | grep -q 'data_root_missing' \
  && [[ ! -e "$MISSING_ROOT" ]] \
  && pass "missing data root fail-closed" \
  || fail "missing data root: ${MISS_OUT}"

# Same-filesystem promotion still uses mv (smoke via promote helper path).
PROMOTE_ROOT="${WORKDIR}/promote-tree"
mkdir -p "${PROMOTE_ROOT}/upload" "${PROMOTE_ROOT}/dest"
printf 'payload\n' >"${PROMOTE_ROOT}/upload/sample.deb"
worker_ssh() {
  shift
  local cmd="$*"
  if [[ "$cmd" == sudo\ * ]]; then
    cmd="${cmd#sudo }"
  fi
  eval "$cmd"
}
set +e
PROM_OUT="$(promote_worker_upload_dir 192.0.2.53 "${PROMOTE_ROOT}/upload" "${PROMOTE_ROOT}/dest" 2>&1; echo RC=$?)"
set -e
echo "$PROM_OUT" | grep -q 'RC=0' \
  && [[ -f "${PROMOTE_ROOT}/dest/sample.deb" ]] \
  && [[ ! -e "${PROMOTE_ROOT}/upload/sample.deb" ]] \
  && pass "WORKER_SAME_FS_PROMOTION mv" \
  || fail "promote: ${PROM_OUT}"

echo "SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
