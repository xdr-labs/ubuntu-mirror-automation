#!/usr/bin/env bash
# Worker prerequisite contract: state always, artifacts only when REQUIRED=YES.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREREQ_LIB="${ROOT}/client/lib/dp-phase2-ubuntu-prerequisites.sh"
FRAGMENT="${ROOT}/scripts/lib/phase2_bringup_patch/fragment_compat.sh"
PATCHER="${ROOT}/scripts/lib/patch_dp_phase2_bringup.py"
FIXTURE="${ROOT}/tests/fixtures/dp-phase2/upstream_bringup_unpatched.sh"
FAIL=0
PASS=0
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "======== test_phase2_prereq_worker_contract ========"

bash -n "$PREREQ_LIB" && pass "bash -n prereq lib" || fail "bash -n prereq lib"
bash -n "$FRAGMENT" && pass "bash -n compat fragment" || fail "bash -n compat fragment"

BIN="${WORKDIR}/bin"
mkdir -p "$BIN"
cat >"${BIN}/apt-get" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${BIN}/dpkg" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--compare-versions" ]]; then
  exec /usr/bin/dpkg "$@"
fi
echo "DPKG_CALL $*" >>"${DPKG_LOG:-/dev/null}"
exit 0
EOF
cat >"${BIN}/dpkg-query" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${BIN}/apt-get" "${BIN}/dpkg" "${BIN}/dpkg-query"

write_no_state() {
  local dest="$1"
  cat >"$dest" <<'EOF'
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PACKAGE_COUNT=0
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
EOF
}

run_install() {
  PATH="${BIN}:$PATH"
  # shellcheck source=/dev/null
  source "$PREREQ_LIB"
  dp2_validate_apt_dependency_graph() { return 0; }
  dp2_install_phase2_ubuntu_prerequisites
  echo RC=$?
}

# A1. REQUIRED=NO COUNT=0 BUILD/PUBLICATION=PASS, no tarball => NOT_REQUIRED
set +e
OUT="$(
  unset PHASE2_PREREQ_ARTIFACT
  PHASE2_PREREQ_STATE="${WORKDIR}/a1.state"
  write_no_state "$PHASE2_PREREQ_STATE"
  run_install
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=NOT_REQUIRED' \
  && echo "$OUT" | grep -q 'RC=0' \
  && pass "A1 REQUIRED=NO COUNT=0 => NOT_REQUIRED/PASS" \
  || fail "A1: ${OUT}"

# A2. Same but COUNT missing => FAIL
set +e
OUT="$(
  unset PHASE2_PREREQ_ARTIFACT
  PHASE2_PREREQ_STATE="${WORKDIR}/a2.state"
  cat >"$PHASE2_PREREQ_STATE" <<'EOF'
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
EOF
  run_install
)"
set -e
echo "$OUT" | grep -q 'state_count_missing' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "A2 REQUIRED=NO missing COUNT => FAIL" \
  || fail "A2: ${OUT}"

# A3. Stale REQUIRED=YES artifact + new REQUIRED=NO state => stale not consumed
STALE_DIR="${WORKDIR}/a3"
mkdir -p "$STALE_DIR/debs"
printf 'stale\n' >"${STALE_DIR}/debs/stale.deb"
printf 'stale.deb\n' >"${STALE_DIR}/install-order.txt"
STALE_TAR="${STALE_DIR}/phase2-ubuntu-prerequisites.tar.gz"
tar -C "$STALE_DIR" -czf "$STALE_TAR" install-order.txt debs
sha256sum "$STALE_TAR" | awk '{print $1"  phase2-ubuntu-prerequisites.tar.gz"}' >"${STALE_TAR}.sha256"
DPKG_LOG="${WORKDIR}/a3-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  export DPKG_LOG
  PHASE2_PREREQ_ARTIFACT="$STALE_TAR"
  PHASE2_PREREQ_STATE="${WORKDIR}/a3.state"
  write_no_state "$PHASE2_PREREQ_STATE"
  run_install
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_STAGE=NOT_REQUIRED' \
  && echo "$OUT" | grep -q 'RC=0' \
  && [[ ! -s "$DPKG_LOG" ]] \
  && pass "A3 stale artifact ignored for REQUIRED=NO" \
  || fail "A3: ${OUT} dpkg=$(cat "$DPKG_LOG" 2>/dev/null || true)"

# Worker copy A3: stale tar on master is not copied when state is REQUIRED=NO
MASTER="${WORKDIR}/master-staging"
WORKER="${WORKDIR}/worker-staging"
UPLOAD="${WORKDIR}/worker-upload"
mkdir -p "${MASTER}/lib" "$WORKER" "$UPLOAD"
printf 'stale-tar\n' >"${MASTER}/phase2-ubuntu-prerequisites.tar.gz"
printf 'deadbeef  phase2-ubuntu-prerequisites.tar.gz\n' \
  >"${MASTER}/phase2-ubuntu-prerequisites.tar.gz.sha256"
printf '{"package_count": 9}\n' >"${MASTER}/phase2-ubuntu-prerequisites.manifest.json"
write_no_state "${MASTER}/phase2-ubuntu-prerequisites.state"
printf '# prereq lib fixture\n' >"${MASTER}/lib/dp-phase2-ubuntu-prerequisites.sh"
# leftover worker files from a previous YES run
printf 'old-worker-tar\n' >"${WORKER}/phase2-ubuntu-prerequisites.tar.gz"
printf 'old-worker-state\n' >"${WORKER}/phase2-ubuntu-prerequisites.state"

SCP_LOG="${WORKDIR}/scp.log"
: >"$SCP_LOG"
log() { printf '%s\n' "$*"; }
worker_ssh() {
  shift
  local cmd="$*"
  if [[ "$cmd" == *"install -o root"* ]] \
    || [[ "$cmd" == *"bash -c"* && "$cmd" == *"upload="* ]]; then
    # Simulate promote: move upload files into protected worker staging.
    local src dest
    mkdir -p "$WORKER" "${WORKER}/lib"
    shopt -s nullglob
    for src in "${UPLOAD}"/*; do
      [[ -f "$src" ]] || continue
      [[ ! -L "$src" ]] || return 1
      dest="${WORKER}/$(basename "$src")"
      cp -a "$src" "$dest"
      chmod 0644 "$dest"
      rm -f "$src"
    done
    for src in "${UPLOAD}/lib"/*; do
      [[ -f "$src" ]] || continue
      [[ ! -L "$src" ]] || return 1
      dest="${WORKER}/lib/$(basename "$src")"
      cp -a "$src" "$dest"
      chmod 0644 "$dest"
      rm -f "$src"
    done
    shopt -u nullglob
    return 0
  fi
  if [[ "$cmd" == *"mkdir -p"* && "$cmd" != *"bash -c"* ]]; then
    mkdir -p "$WORKER" "${WORKER}/lib" "$UPLOAD" "${UPLOAD}/lib" "${UPLOAD}/aelladeb"
    chmod 0755 "$WORKER" "${WORKER}/lib"
    chmod 0700 "$UPLOAD" "${UPLOAD}/lib" "${UPLOAD}/aelladeb"
    return 0
  fi
  if [[ "$cmd" == *"rm -f"* ]]; then
    rm -f \
      "${WORKER}/phase2-ubuntu-prerequisites.state" \
      "${WORKER}/phase2-ubuntu-prerequisites.tar.gz" \
      "${WORKER}/phase2-ubuntu-prerequisites.tar.gz.sha256" \
      "${WORKER}/phase2-ubuntu-prerequisites.manifest.json" \
      "${WORKER}/phase2-ubuntu-prerequisites.identity" \
      "${WORKER}/lib/dp-phase2-ubuntu-prerequisites.sh" \
      "${UPLOAD}/phase2-ubuntu-prerequisites.state" \
      "${UPLOAD}/phase2-ubuntu-prerequisites.tar.gz" \
      "${UPLOAD}/phase2-ubuntu-prerequisites.tar.gz.sha256" \
      "${UPLOAD}/phase2-ubuntu-prerequisites.manifest.json" \
      "${UPLOAD}/phase2-ubuntu-prerequisites.identity" \
      "${UPLOAD}/lib/dp-phase2-ubuntu-prerequisites.sh"
    return 0
  fi
  return 0
}
worker_scp() {
  local src="$1" dest="$3"
  printf '%s\n' "$(basename "$src")" >>"$SCP_LOG"
  if [[ "$dest" == */lib/dp-phase2-ubuntu-prerequisites.sh ]] \
    || [[ "$dest" == */lib/* ]]; then
    mkdir -p "${UPLOAD}/lib"
    cp -a "$src" "${UPLOAD}/lib/$(basename "$src")"
    return 0
  fi
  mkdir -p "$UPLOAD"
  cp -a "$src" "${UPLOAD}/$(basename "$src")"
}
# shellcheck source=/dev/null
source "$FRAGMENT"
STAGING_DIR="$MASTER"
PHASE2_WORKER_UPLOAD_ROOT="$UPLOAD"
export PHASE2_WORKER_UPLOAD_ROOT
set +e
COPY_OUT="$(copy_phase2_prereq_contract_to_worker 192.0.2.10; echo RC=$?)"
set -e
echo "$COPY_OUT" | grep -q 'PHASE2_PREREQ_WORKER_COPY=NOT_REQUIRED' \
  && echo "$COPY_OUT" | grep -q 'RC=0' \
  && [[ -f "${WORKER}/phase2-ubuntu-prerequisites.state" ]] \
  && [[ ! -f "${WORKER}/phase2-ubuntu-prerequisites.tar.gz" ]] \
  && [[ ! -f "${WORKER}/phase2-ubuntu-prerequisites.manifest.json" ]] \
  && ! grep -qx 'phase2-ubuntu-prerequisites.tar.gz' "$SCP_LOG" \
  && grep -qx 'phase2-ubuntu-prerequisites.state' "$SCP_LOG" \
  && [[ "$(stat -c '%a' "$WORKER")" != "777" ]] \
  && [[ "$(stat -c '%a' "$UPLOAD")" == "700" ]] \
  && pass "A3 worker copy does not propagate stale tar" \
  || fail "A3 copy: ${COPY_OUT} scp=$(cat "$SCP_LOG") worker=$(ls -1 "$WORKER")"

# A4. REQUIRED=YES valid current contract => worker validates and proceeds
A4="${WORKDIR}/a4"
mkdir -p "${A4}/debs"
printf 'fixture\n' >"${A4}/debs/foo_2.1_all.deb"
printf 'foo_2.1_all.deb\n' >"${A4}/install-order.txt"
# Real tiny .deb so dpkg-deb reads Package/Version.
build_tiny() {
  local dest="$1" package="$2" version="$3"
  local work debian
  work="$(mktemp -d "${WORKDIR}/deb.XXXXXX")"
  debian="${work}/DEBIAN"
  mkdir -p "$debian" "${work}/usr/share/doc/${package}"
  printf 'fixture\n' >"${work}/usr/share/doc/${package}/README"
  cat >"${debian}/control" <<EOF
Package: ${package}
Version: ${version}
Architecture: all
Maintainer: fixture@example.com
Description: fixture ${package}
EOF
  dpkg-deb -Zgzip --build "$work" "$dest" >/dev/null
  rm -rf "$work"
}
rm -rf "${A4}/debs"
mkdir -p "${A4}/debs"
build_tiny "${A4}/debs/foo_2.1_all.deb" foo 2.1
printf 'foo_2.1_all.deb\n' >"${A4}/install-order.txt"
A4_TAR="${A4}/phase2-ubuntu-prerequisites.tar.gz"
tar -C "$A4" -czf "$A4_TAR" install-order.txt debs
sha256sum "$A4_TAR" | awk '{print $1"  phase2-ubuntu-prerequisites.tar.gz"}' >"${A4_TAR}.sha256"
A4_SHA="$(awk '{print $1; exit}' "${A4_TAR}.sha256")"
cat >"${A4}/phase2-ubuntu-prerequisites.state" <<EOF
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=1
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=${A4_SHA}
EOF
printf '{"package_count": 1, "sha256": "%s"}\n' "$A4_SHA" \
  >"${A4}/phase2-ubuntu-prerequisites.manifest.json"
set +e
OUT="$(
  PHASE2_PREREQ_ARTIFACT="$A4_TAR"
  PHASE2_PREREQ_STATE="${A4}/phase2-ubuntu-prerequisites.state"
  PHASE2_PREREQ_MANIFEST="${A4}/phase2-ubuntu-prerequisites.manifest.json"
  run_install
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_INSTALL=PASS' \
  && echo "$OUT" | grep -q 'PHASE2_PREREQ_SHA256=PASS' \
  && echo "$OUT" | grep -q 'PHASE2_PREREQ_MANIFEST=PASS' \
  && echo "$OUT" | grep -q 'RC=0' \
  && pass "A4 REQUIRED=YES valid contract proceeds" \
  || fail "A4: ${OUT}"

# A4 worker copy of YES contract
MASTER_YES="${WORKDIR}/master-yes"
WORKER_YES="${WORKDIR}/worker-yes"
UPLOAD_YES="${WORKDIR}/upload-yes"
mkdir -p "${MASTER_YES}/lib" "$WORKER_YES" "$UPLOAD_YES"
cp -a "${A4}/phase2-ubuntu-prerequisites."* "$MASTER_YES/"
cp -a "${A4_TAR}.sha256" "$MASTER_YES/"
printf '# prereq lib fixture\n' >"${MASTER_YES}/lib/dp-phase2-ubuntu-prerequisites.sh"
: >"$SCP_LOG"
STAGING_DIR="$MASTER_YES"
WORKER="$WORKER_YES"
UPLOAD="$UPLOAD_YES"
PHASE2_WORKER_UPLOAD_ROOT="$UPLOAD_YES"
export PHASE2_WORKER_UPLOAD_ROOT
set +e
COPY_OUT="$(copy_phase2_prereq_contract_to_worker 192.0.2.11; echo RC=$?)"
set -e
echo "$COPY_OUT" | grep -q 'PHASE2_PREREQ_WORKER_COPY=PASS' \
  && echo "$COPY_OUT" | grep -q 'RC=0' \
  && [[ -f "${WORKER_YES}/phase2-ubuntu-prerequisites.state" ]] \
  && [[ -f "${WORKER_YES}/phase2-ubuntu-prerequisites.tar.gz" ]] \
  && [[ -f "${WORKER_YES}/phase2-ubuntu-prerequisites.tar.gz.sha256" ]] \
  && [[ -f "${WORKER_YES}/phase2-ubuntu-prerequisites.manifest.json" ]] \
  && [[ -f "${WORKER_YES}/lib/dp-phase2-ubuntu-prerequisites.sh" ]] \
  && [[ "$(stat -c '%a' "$WORKER_YES")" != "777" ]] \
  && pass "A4 worker receives state+artifact+sidecar+manifest+lib" \
  || fail "A4 copy: ${COPY_OUT} files=$(ls -1 "$WORKER_YES" 2>/dev/null || true)"

# A4b. Symlink in upload area fails closed at promote
ln -sf /etc/passwd "${UPLOAD_YES}/evil-link"
set +e
PROMOTE_OUT="$(promote_worker_upload_dir 192.0.2.11 "$UPLOAD_YES" "$WORKER_YES"; echo RC=$?)"
set -e
echo "$PROMOTE_OUT" | grep -q 'RC=1' \
  && pass "A4b symlink upload promote FAIL CLOSED" \
  || fail "A4b symlink: ${PROMOTE_OUT}"

# A5. REQUIRED=YES artifact exists but state missing => FAIL
set +e
OUT="$(
  unset PHASE2_PREREQ_STATE STAGING_DIR
  PHASE2_PREREQ_ARTIFACT="$A4_TAR"
  PHASE2_PREREQ_MANIFEST="${A4}/phase2-ubuntu-prerequisites.manifest.json"
  run_install
)"
set -e
echo "$OUT" | grep -q 'state_missing' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "A5 artifact without state => FAIL" \
  || fail "A5: ${OUT}"

# A6. BUILD=FAIL while old valid artifact remains => FAIL, artifact not consumed
DPKG_LOG="${WORKDIR}/a6-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  export DPKG_LOG
  PHASE2_PREREQ_ARTIFACT="$A4_TAR"
  PHASE2_PREREQ_STATE="${WORKDIR}/a6.state"
  PHASE2_PREREQ_MANIFEST="${A4}/phase2-ubuntu-prerequisites.manifest.json"
  cat >"$PHASE2_PREREQ_STATE" <<EOF
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=1
PHASE2_PREREQ_BUILD=FAIL
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=${A4_SHA}
EOF
  run_install
)"
set -e
echo "$OUT" | grep -q 'state_build_not_pass' \
  && echo "$OUT" | grep -q 'RC=1' \
  && [[ ! -s "$DPKG_LOG" ]] \
  && pass "A6 BUILD=FAIL does not consume stale valid artifact" \
  || fail "A6: ${OUT}"

# A7. State SHA != sidecar/artifact SHA => FAIL
set +e
OUT="$(
  PHASE2_PREREQ_ARTIFACT="$A4_TAR"
  PHASE2_PREREQ_STATE="${WORKDIR}/a7.state"
  PHASE2_PREREQ_MANIFEST="${A4}/phase2-ubuntu-prerequisites.manifest.json"
  cat >"$PHASE2_PREREQ_STATE" <<'EOF'
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=1
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
  run_install
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_SHA256=FAIL' \
  && echo "$OUT" | grep -q 'RC=1' \
  && pass "A7 state SHA mismatch => FAIL" \
  || fail "A7: ${OUT}"

# Generated bringup must call the explicit contract copy (not globs as protocol).
GEN="${WORKDIR}/generated.sh"
if python3 "$PATCHER" --upstream "$FIXTURE" --output "$GEN" >/dev/null; then
  grep -q 'copy_phase2_prereq_contract_to_worker' "$GEN" \
    && grep -q 'phase2-ubuntu-prerequisites.state' "$GEN" \
    && grep -q 'prepare_worker_protected_staging' "$GEN" \
    && grep -q 'promote_worker_upload_dir' "$GEN" \
    && ! grep -qE 'chmod 777|chmod 0777' "$GEN" \
    && pass "generated bringup copies explicit prereq contract" \
    || fail "generated bringup missing explicit prereq contract copy"
  bash -n "$GEN" && pass "bash -n generated bringup" || fail "bash -n generated bringup"
else
  fail "patcher failed to generate bringup"
fi

echo "SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
