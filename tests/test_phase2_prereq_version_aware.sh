#!/usr/bin/env bash
# Prerequisite install skip must be version-aware (never package-name-only).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREREQ_LIB="${ROOT}/client/lib/dp-phase2-ubuntu-prerequisites.sh"
FAIL=0
PASS=0
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "======== test_phase2_prereq_version_aware ========"

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

write_yes_contract() {
  local tar="$1" count="$2"
  local sha
  sha="$(sha256sum "$tar" | awk '{print $1}')"
  echo "${sha}  phase2-ubuntu-prerequisites.tar.gz" >"${tar}.sha256"
  cat >"${tar%.tar.gz}.state" <<EOF
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=${count}
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=${sha}
EOF
  printf '{"package_count": %s, "sha256": "%s"}\n' "$count" "$sha" \
    >"$(dirname "$tar")/phase2-ubuntu-prerequisites.manifest.json"
  printf '%s\n' "$sha"
}

make_bin() {
  local bin="$1"
  mkdir -p "$bin"
  cat >"${bin}/dpkg" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--compare-versions" || "$1" == "--print-architecture" ]]; then
  exec /usr/bin/dpkg "$@"
fi
[[ "$1" == --audit ]] && exit 0
[[ "$1" == -i ]] || exit 90
echo "DPKG_CALL $*" >>"${DPKG_LOG}"
exit 0
EOF
  cat >"${bin}/dpkg-query" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/dpkg-query --admindir="$PREREQ_TEST_DB" "$@"
EOF
  cat >"${bin}/apt-get" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/apt-get "$@"
EOF
  chmod +x "${bin}/dpkg" "${bin}/dpkg-query" "${bin}/apt-get"
}

pack_foo() {
  local dest_dir="$1" version="$2" depends="${3:-}"
  mkdir -p "${dest_dir}/debs"
  build_tiny_deb "${dest_dir}/debs/foo_${version}_all.deb" foo "$version" "$depends"
  printf 'foo_%s_all.deb\n' "$version" >"${dest_dir}/install-order.txt"
  tar -C "$dest_dir" -czf "${dest_dir}/phase2-ubuntu-prerequisites.tar.gz" \
    install-order.txt debs
}

pack_scc() {
  local dest_dir="$1"
  local order_line="$2"
  shift 2
  local spec pkg ver
  mkdir -p "${dest_dir}/debs"
  for spec in "$@"; do
    pkg="${spec%%:*}"
    ver="${spec#*:}"
    build_tiny_deb "${dest_dir}/debs/${pkg}_${ver}_all.deb" "$pkg" "$ver"
  done
  printf '%s\n' "$order_line" >"${dest_dir}/install-order.txt"
  tar -C "$dest_dir" -czf "${dest_dir}/phase2-ubuntu-prerequisites.tar.gz" \
    install-order.txt debs
}

BIN="${WORKDIR}/bin"
make_bin "$BIN"

run_case() {
  local art_dir="$1"
  local tar="${art_dir}/phase2-ubuntu-prerequisites.tar.gz"
  # Give both package queries and the whole-plan APT projection the same
  # isolated inventory. No real host package state/sources are consulted.
  PREREQ_TEST_DB="${art_dir}/fixture-dpkg"
  APT_CONFIG="${art_dir}/fixture-apt.conf"
  export PREREQ_TEST_DB APT_CONFIG
  python3 - "$art_dir" <<'PY'
import os
from pathlib import Path
root = Path(__import__('sys').argv[1])
for name in ('fixture-dpkg', 'fixture-empty', 'fixture-lists', 'fixture-cache'):
    (root / name).mkdir()
(root / 'fixture-empty.conf').write_text('')
(root / 'fixture-sources.list').write_text('')
versions = os.environ.get('INSTALLED_VERSIONS', '')
if not versions and os.environ.get('INSTALLED_VERSION'):
    versions = 'foo=' + os.environ['INSTALLED_VERSION']
records = []
for pair in versions.split():
    package, version = pair.split('=', 1)
    records.append('Package: %s\nStatus: install ok installed\nVersion: %s\n'
                   'Architecture: all\nDescription: isolated version fixture\n' % (package, version))
(root / 'fixture-dpkg/status').write_text('\n'.join(records))
paths = {'Dir::Etc::parts': 'fixture-empty', 'Dir::Etc::main': 'fixture-empty.conf',
         'Dir::Etc::sourcelist': 'fixture-sources.list', 'Dir::Etc::sourceparts': 'fixture-empty',
         'Dir::State::status': 'fixture-dpkg/status', 'Dir::State::lists': 'fixture-lists',
         'Dir::Cache': 'fixture-cache'}
(root / 'fixture-apt.conf').write_text(''.join('%s "%s";\n' % (key, root / value)
                                             for key, value in paths.items()) +
    'Dir::Cache::pkgcache "";\nDir::Cache::srcpkgcache "";\nDebug::NoLocking "true";\n')
PY
  PATH="${BIN}:$PATH"
  export DPKG_LOG
  PHASE2_PREREQ_ARTIFACT="$tar"
  PHASE2_PREREQ_STATE="${tar%.tar.gz}.state"
  PHASE2_PREREQ_MANIFEST="${art_dir}/phase2-ubuntu-prerequisites.manifest.json"
  # shellcheck source=/dev/null
  source "$PREREQ_LIB"
  dp2_legacy_product_transition_status_path() { printf '%s\n' "$PREREQ_TEST_DB/status"; }
  dp2_install_phase2_ubuntu_prerequisites
  echo RC=$?
}

# D1. Artifact foo=2.1, installed foo=2.1 => skip
D1="${WORKDIR}/d1"
pack_foo "$D1" 2.1
write_yes_contract "${D1}/phase2-ubuntu-prerequisites.tar.gz" 1 >/dev/null
DPKG_LOG="${WORKDIR}/d1-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  INSTALLED_VERSION=2.1
  export INSTALLED_VERSION
  run_case "$D1"
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_ALREADY_INSTALLED package=foo version=2.1' \
  && echo "$OUT" | grep -q 'RC=0' \
  && [[ ! -s "$DPKG_LOG" ]] \
  && pass "D1 exact same version is skipped" \
  || fail "D1: ${OUT} dpkg=$(cat "$DPKG_LOG")"

# D2. Artifact foo=2.1, installed foo=1.5 => must install
D2="${WORKDIR}/d2"
pack_foo "$D2" 2.1
write_yes_contract "${D2}/phase2-ubuntu-prerequisites.tar.gz" 1 >/dev/null
DPKG_LOG="${WORKDIR}/d2-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  INSTALLED_VERSION=1.5
  export INSTALLED_VERSION
  run_case "$D2"
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_INSTALL_NEEDED package=foo installed=1.5 selected=2.1' \
  && echo "$OUT" | grep -q 'PHASE2_PREREQ_DPKG=PASS' \
  && echo "$OUT" | grep -q 'RC=0' \
  && grep -q 'DPKG_CALL' "$DPKG_LOG" \
  && ! echo "$OUT" | grep -q 'PHASE2_PREREQ_ALREADY_INSTALLED' \
  && pass "D2 older installed version is not skipped" \
  || fail "D2: ${OUT} dpkg=$(cat "$DPKG_LOG")"

# D3. Installed newer than artifact => fail closed, never name-only skip
D3="${WORKDIR}/d3"
pack_foo "$D3" 2.1
write_yes_contract "${D3}/phase2-ubuntu-prerequisites.tar.gz" 1 >/dev/null
DPKG_LOG="${WORKDIR}/d3-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  INSTALLED_VERSION=3.0
  export INSTALLED_VERSION
  run_case "$D3"
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_VERSION_CONFLICT package=foo installed=3.0 selected=2.1' \
  && echo "$OUT" | grep -q 'RC=1' \
  && [[ ! -s "$DPKG_LOG" ]] \
  && ! echo "$OUT" | grep -q 'PHASE2_PREREQ_ALREADY_INSTALLED' \
  && pass "D3 newer installed version fail-closes (no silent skip/downgrade)" \
  || fail "D3: ${OUT} dpkg=$(cat "$DPKG_LOG")"

# D4. Older foo must be installed; its selected version's versioned bar
# dependency is satisfied by the fixture inventory and checked by real APT.
D4="${WORKDIR}/d4"
pack_foo "$D4" 2.1 "bar (>= 2.0)"
write_yes_contract "${D4}/phase2-ubuntu-prerequisites.tar.gz" 1 >/dev/null
DPKG_LOG="${WORKDIR}/d4-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  INSTALLED_VERSIONS='foo=1.5 bar=2.0'
  export INSTALLED_VERSIONS
  run_case "$D4"
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_INSTALL_NEEDED' \
  && echo "$OUT" | grep -q 'PHASE2_PREREQ_DPKG=PASS' \
  && echo "$OUT" | grep -q 'RC=0' \
  && grep -q 'DPKG_CALL' "$DPKG_LOG" \
  && ! echo "$OUT" | grep -q 'PHASE2_PREREQ_ALREADY_INSTALLED' \
  && pass "D4 older installed version is not false ALREADY_INSTALLED" \
  || fail "D4: ${OUT} dpkg=$(cat "$DPKG_LOG")"

# ---------------------------------------------------------------------------
# A1. SCC foo older + bar newer-conflict: FAIL, no dpkg, no downgrade
# ---------------------------------------------------------------------------
A1="${WORKDIR}/a1"
pack_scc "$A1" "foo_2.1_all.deb bar_2.1_all.deb" foo:2.1 bar:2.1
write_yes_contract "${A1}/phase2-ubuntu-prerequisites.tar.gz" 2 >/dev/null
DPKG_LOG="${WORKDIR}/a1-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  INSTALLED_VERSIONS="foo=1.5 bar=3.0"
  export INSTALLED_VERSIONS
  run_case "$A1"
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_VERSION_CONFLICT package=bar installed=3.0 selected=2.1' \
  && echo "$OUT" | grep -q 'RC=1' \
  && [[ ! -s "$DPKG_LOG" ]] \
  && ! echo "$OUT" | grep -q 'PHASE2_PREREQ_DPKG=PASS' \
  && pass "A1 SCC older-then-newer-conflict fail-closes without dpkg" \
  || fail "A1: ${OUT} dpkg=$(cat "$DPKG_LOG")"

# ---------------------------------------------------------------------------
# A2. Reverse filename order must still FAIL with no dpkg
# ---------------------------------------------------------------------------
A2="${WORKDIR}/a2"
pack_scc "$A2" "bar_2.1_all.deb foo_2.1_all.deb" foo:2.1 bar:2.1
write_yes_contract "${A2}/phase2-ubuntu-prerequisites.tar.gz" 2 >/dev/null
DPKG_LOG="${WORKDIR}/a2-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  INSTALLED_VERSIONS="foo=1.5 bar=3.0"
  export INSTALLED_VERSIONS
  run_case "$A2"
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_VERSION_CONFLICT package=bar installed=3.0 selected=2.1' \
  && echo "$OUT" | grep -q 'RC=1' \
  && [[ ! -s "$DPKG_LOG" ]] \
  && pass "A2 reverse SCC order still fail-closes without dpkg" \
  || fail "A2: ${OUT} dpkg=$(cat "$DPKG_LOG")"

# ---------------------------------------------------------------------------
# A3. Exact foo + older bar => one dpkg -i of the entire SCC group
# ---------------------------------------------------------------------------
A3="${WORKDIR}/a3"
pack_scc "$A3" "foo_2.1_all.deb bar_2.1_all.deb" foo:2.1 bar:2.1
write_yes_contract "${A3}/phase2-ubuntu-prerequisites.tar.gz" 2 >/dev/null
DPKG_LOG="${WORKDIR}/a3-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  INSTALLED_VERSIONS="foo=2.1 bar=1.5"
  export INSTALLED_VERSIONS
  run_case "$A3"
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_DPKG=PASS' \
  && echo "$OUT" | grep -q 'RC=0' \
  && [[ "$(grep -c '^DPKG_CALL' "$DPKG_LOG")" -eq 1 ]] \
  && grep -q 'foo_2.1_all.deb' "$DPKG_LOG" \
  && grep -q 'bar_2.1_all.deb' "$DPKG_LOG" \
  && awk '/^DPKG_CALL/ && /foo_2.1_all.deb/ && /bar_2.1_all.deb/ {found=1} END {exit found?0:1}' "$DPKG_LOG" \
  && pass "A3 exact+older installs entire SCC in one dpkg -i" \
  || fail "A3: ${OUT} dpkg=$(cat "$DPKG_LOG")"

# ---------------------------------------------------------------------------
# A4. Older foo + exact bar => entire SCC installed
# ---------------------------------------------------------------------------
A4="${WORKDIR}/a4"
pack_scc "$A4" "foo_2.1_all.deb bar_2.1_all.deb" foo:2.1 bar:2.1
write_yes_contract "${A4}/phase2-ubuntu-prerequisites.tar.gz" 2 >/dev/null
DPKG_LOG="${WORKDIR}/a4-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  INSTALLED_VERSIONS="foo=1.5 bar=2.1"
  export INSTALLED_VERSIONS
  run_case "$A4"
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_DPKG=PASS' \
  && echo "$OUT" | grep -q 'RC=0' \
  && [[ "$(grep -c '^DPKG_CALL' "$DPKG_LOG")" -eq 1 ]] \
  && awk '/^DPKG_CALL/ && /foo_2.1_all.deb/ && /bar_2.1_all.deb/ {found=1} END {exit found?0:1}' "$DPKG_LOG" \
  && pass "A4 older+exact installs entire SCC group" \
  || fail "A4: ${OUT} dpkg=$(cat "$DPKG_LOG")"

# ---------------------------------------------------------------------------
# A5. All exact => skip entire SCC, no dpkg -i
# ---------------------------------------------------------------------------
A5="${WORKDIR}/a5"
pack_scc "$A5" "foo_2.1_all.deb bar_2.1_all.deb" foo:2.1 bar:2.1
write_yes_contract "${A5}/phase2-ubuntu-prerequisites.tar.gz" 2 >/dev/null
DPKG_LOG="${WORKDIR}/a5-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  INSTALLED_VERSIONS="foo=2.1 bar=2.1"
  export INSTALLED_VERSIONS
  run_case "$A5"
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_ALREADY_INSTALLED package=foo version=2.1' \
  && echo "$OUT" | grep -q 'PHASE2_PREREQ_ALREADY_INSTALLED package=bar version=2.1' \
  && echo "$OUT" | grep -q 'RC=0' \
  && [[ ! -s "$DPKG_LOG" ]] \
  && pass "A5 all-exact SCC is skipped with no dpkg -i" \
  || fail "A5: ${OUT} dpkg=$(cat "$DPKG_LOG")"

# ---------------------------------------------------------------------------
# A6. Multiple install-needed members => exactly one SCC dpkg -i
# ---------------------------------------------------------------------------
A6="${WORKDIR}/a6"
pack_scc "$A6" "foo_2.1_all.deb bar_2.1_all.deb" foo:2.1 bar:2.1
write_yes_contract "${A6}/phase2-ubuntu-prerequisites.tar.gz" 2 >/dev/null
DPKG_LOG="${WORKDIR}/a6-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  INSTALLED_VERSIONS="foo=1.0 bar=1.5"
  export INSTALLED_VERSIONS
  run_case "$A6"
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_DPKG=PASS' \
  && echo "$OUT" | grep -q 'RC=0' \
  && [[ "$(grep -c '^DPKG_CALL' "$DPKG_LOG")" -eq 1 ]] \
  && awk '/^DPKG_CALL/ && /foo_2.1_all.deb/ && /bar_2.1_all.deb/ {found=1} END {exit found?0:1}' "$DPKG_LOG" \
  && pass "A6 multiple install-needed members use one SCC dpkg -i" \
  || fail "A6: ${OUT} dpkg=$(cat "$DPKG_LOG")"

# ---------------------------------------------------------------------------
# A7. Conflict after more than one valid member (exact + older + newer)
# ---------------------------------------------------------------------------
A7="${WORKDIR}/a7"
pack_scc "$A7" "foo_2.1_all.deb bar_2.1_all.deb baz_2.1_all.deb" \
  foo:2.1 bar:2.1 baz:2.1
write_yes_contract "${A7}/phase2-ubuntu-prerequisites.tar.gz" 3 >/dev/null
DPKG_LOG="${WORKDIR}/a7-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  INSTALLED_VERSIONS="foo=2.1 bar=1.5 baz=3.0"
  export INSTALLED_VERSIONS
  run_case "$A7"
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_VERSION_CONFLICT package=baz installed=3.0 selected=2.1' \
  && echo "$OUT" | grep -q 'RC=1' \
  && [[ ! -s "$DPKG_LOG" ]] \
  && ! echo "$OUT" | grep -q 'PHASE2_PREREQ_DPKG=PASS' \
  && pass "A7 conflict after exact+older still fail-closes without dpkg" \
  || fail "A7: ${OUT} dpkg=$(cat "$DPKG_LOG")"

echo "SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
