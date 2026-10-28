#!/usr/bin/env bash
# Prove dpkg failure return codes are preserved (never inverted to 0) and
# that the installer consumes install-order.txt instead of lexical glob order.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREREQ_LIB="${ROOT}/client/lib/dp-phase2-ubuntu-prerequisites.sh"
FAIL=0
PASS=0
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Real package controls and APT projection use only this empty private package
# database. Fake dpkg below records/returns install outcomes without installing.
PREREQ_TEST_DB="${WORKDIR}/fixture-dpkg"
APT_CONFIG="${WORKDIR}/fixture-apt.conf"
export PREREQ_TEST_DB APT_CONFIG
python3 - "$WORKDIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for name in ('fixture-dpkg', 'fixture-empty', 'fixture-lists', 'fixture-cache'):
    (root / name).mkdir()
for name in ('fixture-dpkg/status', 'fixture-empty.conf', 'fixture-sources.list'):
    (root / name).write_text('')
paths = {'Dir::Etc::parts': 'fixture-empty', 'Dir::Etc::main': 'fixture-empty.conf',
         'Dir::Etc::sourcelist': 'fixture-sources.list', 'Dir::Etc::sourceparts': 'fixture-empty',
         'Dir::State::status': 'fixture-dpkg/status', 'Dir::State::lists': 'fixture-lists',
         'Dir::Cache': 'fixture-cache'}
(root / 'fixture-apt.conf').write_text(''.join('%s "%s";\n' % (key, root / value)
                                             for key, value in paths.items()) +
    'Dir::Cache::pkgcache "";\nDir::Cache::srcpkgcache "";\nDebug::NoLocking "true";\n')
PY

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "======== test_phase2_prereq_dpkg_rc ========"

bash -n "$PREREQ_LIB" && pass "bash -n prereq lib" || fail "bash -n prereq lib"

build_tiny_deb() {
  local dest="$1" package="$2" version="${3:-1}" depends="${4:-}"
  local work debian
  work="$(mktemp -d "${WORKDIR}/deb.XXXXXX")"
  debian="${work}/DEBIAN"
  mkdir -p "$debian" "${work}/usr/share/doc/${package}"
  printf 'fixture\n' >"${work}/usr/share/doc/${package}/README"
  {
    echo "Package: ${package}"
    echo "Version: ${version}"
    echo "Architecture: all"
    echo "Maintainer: fixture@example.com"
    echo "Description: fixture ${package}"
    [[ -n "$depends" ]] && echo "Depends: ${depends}"
  } >"${debian}/control"
  dpkg-deb -Zgzip --build "$work" "$dest" >/dev/null
  rm -rf "$work"
}

# ---------------------------------------------------------------------------
# 1. Fake dpkg returning 1 and 42 must never become rc=0
# ---------------------------------------------------------------------------
for want_rc in 1 42; do
  BIN="${WORKDIR}/bin-dpkg-${want_rc}"
  mkdir -p "$BIN"
  cat >"${BIN}/dpkg" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == --compare-versions || "$1" == --print-architecture ]]; then
  exec /usr/bin/dpkg "$@"
fi
[[ "$1" == --audit ]] && exit 0
[[ "$1" == -i ]] || exit 90
echo "fake-dpkg invoked rc=${PREREQ_TEST_DPKG_RC}" >&2
exit "$PREREQ_TEST_DPKG_RC"
EOF
  cat >"${BIN}/dpkg-deb" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/dpkg-deb "$@"
EOF
  cat >"${BIN}/dpkg-query" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/dpkg-query --admindir="$PREREQ_TEST_DB" "$@"
EOF
  cat >"${BIN}/apt-get" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/apt-get "$@"
EOF
  chmod +x "${BIN}/dpkg" "${BIN}/dpkg-deb" "${BIN}/dpkg-query" "${BIN}/apt-get"

  ART="${WORKDIR}/art-${want_rc}"
  mkdir -p "${ART}/debs"
  build_tiny_deb "${ART}/debs/python3-colorama_1_all.deb" python3-colorama
  cat >"${ART}/install-order.txt" <<'EOF'
# PHASE2_PREREQ_INSTALL_ORDER
python3-colorama_1_all.deb
EOF
  TAR="${WORKDIR}/phase2-ubuntu-prerequisites-${want_rc}.tar.gz"
  tar -C "$ART" -czf "$TAR" install-order.txt debs
  sha256sum "$TAR" | awk '{print $1"  phase2-ubuntu-prerequisites.tar.gz"}' >"${TAR}.sha256"
  TAR_SHA="$(awk '{print $1; exit}' "${TAR}.sha256")"
  cat >"${WORKDIR}/yes-${want_rc}.state" <<EOF
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=1
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=${TAR_SHA}
EOF
  printf '{"package_count": 1, "sha256": "%s"}\n' "$TAR_SHA" \
    >"$(dirname "$TAR")/phase2-ubuntu-prerequisites.manifest.json"

  set +e
  OUT="$(
    PATH="${BIN}:$PATH"
    export PREREQ_TEST_DPKG_RC="$want_rc"
    PHASE2_PREREQ_ARTIFACT="$TAR"
    PHASE2_PREREQ_STATE="${WORKDIR}/yes-${want_rc}.state"
    # shellcheck source=/dev/null
    source "$PREREQ_LIB"
    dp2_legacy_product_transition_status_path() { printf '%s\n' "$PREREQ_TEST_DB/status"; }
    dp2_install_phase2_ubuntu_prerequisites
    echo RC=$?
  )"
  set -e
  echo "$OUT" | grep -q "PHASE2_PREREQ_DPKG=FAIL" \
    && echo "$OUT" | grep -q "rc=${want_rc}" \
    && echo "$OUT" | grep -q "RC=${want_rc}" \
    && ! echo "$OUT" | grep -q "RC=0" \
    && pass "dpkg rc=${want_rc} preserved (never 0)" \
    || fail "dpkg rc=${want_rc} not preserved: ${OUT}"
done

# ---------------------------------------------------------------------------
# 2. Install order is manifest/order-file, not lexical glob
# ---------------------------------------------------------------------------
# Lexical glob would install python3-click before python3-colorama.
ORD_BIN="${WORKDIR}/bin-order"
mkdir -p "$ORD_BIN"
cat >"${ORD_BIN}/dpkg" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == --compare-versions || "$1" == --print-architecture ]]; then
  exec /usr/bin/dpkg "$@"
fi
[[ "$1" == --audit ]] && exit 0
[[ "$1" == -i ]] || exit 90
echo "DPKG_CALL $*" >>"${DPKG_LOG}"
exit 0
EOF
cat >"${ORD_BIN}/dpkg-deb" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/dpkg-deb "$@"
EOF
cat >"${ORD_BIN}/dpkg-query" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/dpkg-query --admindir="$PREREQ_TEST_DB" "$@"
EOF
cat >"${ORD_BIN}/apt-get" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/apt-get "$@"
EOF
chmod +x "${ORD_BIN}/dpkg" "${ORD_BIN}/dpkg-deb" "${ORD_BIN}/dpkg-query" "${ORD_BIN}/apt-get"

ART2="${WORKDIR}/art-order"
mkdir -p "${ART2}/debs"
build_tiny_deb "${ART2}/debs/python3-click_1_all.deb" python3-click 1 "python3-colorama"
build_tiny_deb "${ART2}/debs/python3-colorama_1_all.deb" python3-colorama
# Order file puts colorama first; glob would put click first.
cat >"${ART2}/install-order.txt" <<'EOF'
python3-colorama_1_all.deb
python3-click_1_all.deb
EOF
TAR2="${WORKDIR}/order-art/phase2-ubuntu-prerequisites.tar.gz"
mkdir -p "$(dirname "$TAR2")"
tar -C "$ART2" -czf "$TAR2" install-order.txt debs
sha256sum "$TAR2" | awk '{print $1"  phase2-ubuntu-prerequisites.tar.gz"}' >"${TAR2}.sha256"
TAR2_SHA="$(awk '{print $1; exit}' "${TAR2}.sha256")"
cat >"${WORKDIR}/yes-order.state" <<EOF
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=2
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=${TAR2_SHA}
EOF
printf '{"package_count": 2, "sha256": "%s"}\n' "$TAR2_SHA" \
  >"$(dirname "$TAR2")/phase2-ubuntu-prerequisites.manifest.json"
DPKG_LOG="${WORKDIR}/dpkg-order.log"
: >"$DPKG_LOG"
set +e
OUT2="$(
  PATH="${ORD_BIN}:$PATH"
  export DPKG_LOG="$DPKG_LOG"
  PHASE2_PREREQ_ARTIFACT="$TAR2"
  PHASE2_PREREQ_STATE="${WORKDIR}/yes-order.state"
  # shellcheck source=/dev/null
  source "$PREREQ_LIB"
  dp2_legacy_product_transition_status_path() { printf '%s\n' "$PREREQ_TEST_DB/status"; }
  dp2_install_phase2_ubuntu_prerequisites
  echo RC=$?
)"
set -e
echo "$OUT2" | grep -q 'RC=0' && echo "$OUT2" | grep -q 'PHASE2_PREREQ_INSTALL=PASS' \
  && pass "ordered install rc=0" \
  || fail "ordered install: ${OUT2}"
first="$(grep '^DPKG_CALL' "$DPKG_LOG" | head -1 || true)"
second="$(grep '^DPKG_CALL' "$DPKG_LOG" | sed -n '2p' || true)"
echo "$first" | grep -q 'python3-colorama_1_all.deb' \
  && echo "$second" | grep -q 'python3-click_1_all.deb' \
  && pass "install order colorama before click (not glob)" \
  || fail "install order was lexical/glob: first=${first} second=${second}"

# Missing order file with debs present must FAIL (no glob fallback).
ART3="${WORKDIR}/art-no-order"
mkdir -p "${ART3}/debs"
cp -a "${ART2}/debs/"*.deb "${ART3}/debs/"
TAR3="${WORKDIR}/no-order-art/phase2-ubuntu-prerequisites.tar.gz"
mkdir -p "$(dirname "$TAR3")"
tar -C "$ART3" -czf "$TAR3" debs
sha256sum "$TAR3" | awk '{print $1"  phase2-ubuntu-prerequisites.tar.gz"}' >"${TAR3}.sha256"
TAR3_SHA="$(awk '{print $1; exit}' "${TAR3}.sha256")"
cat >"${WORKDIR}/yes-no-order.state" <<EOF
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=2
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=${TAR3_SHA}
EOF
printf '{"package_count": 2, "sha256": "%s"}\n' "$TAR3_SHA" \
  >"$(dirname "$TAR3")/phase2-ubuntu-prerequisites.manifest.json"
set +e
OUT3="$(
  PATH="${ORD_BIN}:$PATH"
  PHASE2_PREREQ_ARTIFACT="$TAR3"
  PHASE2_PREREQ_STATE="${WORKDIR}/yes-no-order.state"
  # shellcheck source=/dev/null
  source "$PREREQ_LIB"
  dp2_legacy_product_transition_status_path() { printf '%s\n' "$PREREQ_TEST_DB/status"; }
  dp2_install_phase2_ubuntu_prerequisites
  echo RC=$?
)"
set -e
echo "$OUT3" | grep -q 'install_order_missing' \
  && echo "$OUT3" | grep -q 'RC=1' \
  && pass "missing install-order with debs fails closed" \
  || fail "missing install-order: ${OUT3}"

# REQUIRED=NO + absent artifact => PASS skip
set +e
OUT4="$(
  PATH="${ORD_BIN}:$PATH"
  unset PHASE2_PREREQ_ARTIFACT
  PHASE2_PREREQ_STATE="${WORKDIR}/not-required.state"
  cat >"$PHASE2_PREREQ_STATE" <<'EOF'
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PACKAGE_COUNT=0
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
EOF
  # shellcheck source=/dev/null
  source "$PREREQ_LIB"
  dp2_legacy_product_transition_status_path() { printf '%s\n' "$PREREQ_TEST_DB/status"; }
  dp2_install_phase2_ubuntu_prerequisites
  echo RC=$?
)"
set -e
echo "$OUT4" | grep -q 'not_required' \
  && echo "$OUT4" | grep -q 'RC=0' \
  && pass "REQUIRED=NO absent artifact is skip/PASS" \
  || fail "REQUIRED=NO: ${OUT4}"

# Absent artifact without NOT_REQUIRED metadata => FAIL
set +e
OUT5="$(
  PATH="${ORD_BIN}:$PATH"
  unset PHASE2_PREREQ_ARTIFACT PHASE2_PREREQ_STATE PHASE2_PREREQ_MANIFEST
  # shellcheck source=/dev/null
  source "$PREREQ_LIB"
  dp2_prereq_find_artifact() { return 1; }
  dp2_prereq_find_state() { return 1; }
  dp2_install_phase2_ubuntu_prerequisites
  echo RC=$?
)"
set -e
echo "$OUT5" | grep -q 'state_missing' \
  && echo "$OUT5" | grep -q 'RC=1' \
  && pass "absent state without NOT_REQUIRED metadata FAIL" \
  || fail "absent required: ${OUT5}"

echo "SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
