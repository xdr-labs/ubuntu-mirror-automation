#!/usr/bin/env bash
# Real APT dependency solving against temporary status databases. No live dpkg
# state, apt sources/cache, packages, or product files are changed by this test.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/client/lib/dp-phase2-ubuntu-prerequisites.sh"
[[ -x /usr/bin/apt-get ]] || { echo 'FAIL: real /usr/bin/apt-get is required' >&2; exit 1; }
# The production accessor must reject a different live status database even
# though the isolated APT fixtures below deliberately replace that accessor.
(
  apt-config() { printf "DP2_STATUS='/tmp/not-the-installed-database'\n"; }
  if dp2_legacy_product_transition_status_path; then
    echo 'FAIL noncanonical production status configuration accepted' >&2
    exit 1
  fi
  apt-config() { printf "DP2_STATUS='/var/lib/dpkg/status'\n"; }
  [[ "$(dp2_legacy_product_transition_status_path)" == /var/lib/dpkg/status ]]
  if DPKG_ROOT=/tmp/other-root dp2_legacy_product_transition_environment; then
    echo 'FAIL alternate production dpkg root accepted' >&2
    exit 1
  fi
)
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/phase2-legacy-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/lists" "$TEST_ROOT/cache" "$TEST_ROOT/empty"
: >"$TEST_ROOT/sources.list"
printf 'Dir::Etc::parts "%s/empty";\nDir::Etc::main "%s/empty.conf";\n' "$TEST_ROOT" "$TEST_ROOT" >"$TEST_ROOT/apt.conf"
: >"$TEST_ROOT/empty.conf"
export TEST_ROOT

python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ['TEST_ROOT'])
dependencies = {
    'aella-da-cli': 'python2.7, python-openssl, python-yaml',
    'aella-da-services': 'python2.7, openssl, python-openssl, python-yaml, python-concurrent.futures',
    'aella-uvp': 'python, openssl, python-openssl, python-yaml, python-flask, python-concurrent.futures, python-configparser, python-tabulate, python-tornado, python-httplib2, python-requests, python-psutil',
    'aellacm': 'python2.7, python-yaml, python-tornado, python-httplib2, python-requests, python-crypto, pypki',
    'kube-tools': 'python2.7',
    'phonehome': '',
    'pypki': 'python2.7, openssl, python-configparser, python-tabulate',
}

def package(name, version='6.2.1ubuntu1', depends='', extra=''):
    return 'Package: %s\nStatus: install ok installed\nArchitecture: amd64\nVersion: %s\n%s%sDescription: isolated test fixture\n' % (
        name, version, 'Depends: ' + depends + '\n' if depends else '', extra)

product = [package(name, depends=depends) for name, depends in dependencies.items()]
base = '\n'.join(product + [package('openssl', '3.0'), package('python2.7', '2.7')])
variants = {
    'owner': base,
    'next_legacy': base.replace('6.2.1ubuntu1', '6.3.0ubuntu1'),
    'unrelated': base + '\n' + package('other-product', depends='missing-system-library'),
    'missing_openssl': '\n'.join(product + [package('python2.7', '2.7')]),
    'unknown_dep': base.replace('python-concurrent.futures\n', 'python-concurrent.futures, missing-system-library (>= 1)\n', 1),
    'complex_legacy': base.replace('python-openssl, python-yaml', 'python-openssl, python-yaml | python3-yaml', 1),
    'partial': base.replace('install ok installed', 'install ok unpacked', 1),
    'mixed': base.replace('Version: 6.2.1ubuntu1', 'Version: 6.3.0ubuntu1', 1),
    'missing_product': base.replace(product[-1] + '\n', ''),
    'new_meta': base + '\n' + package('aella-uvp-2404', '6.6.0ubuntu1'),
    'wrong_arch': base.replace('Architecture: amd64', 'Architecture: arm64', 1),
    'py3_version': base.replace('6.2.1ubuntu1', '6.5.0ubuntu1'),
    'pre_depends': base.replace('Description:', 'Pre-Depends: missing-library\nDescription:', 1),
    'reverse_good': base + '\n' + package('external-consumer', depends='aellacm (= 6.2.1ubuntu1)'),
    'reverse_bad': base + '\n' + package('external-consumer', depends='aellacm (= 6.4.0ubuntu1)'),
    'conflict': base + '\n' + package('conflicting-product', extra='Conflicts: aellacm\n'),
    'healthy': package('openssl', '3.0'),
}
for name, content in variants.items():
    (root / (name + '.status')).write_text(content)
PY

# Runtime boundary seams are substituted only inside this test. Production has
# a fixed Noble/amd64 check and refuses noncanonical apt status configuration.
dp2_legacy_product_transition_environment() { return 0; }
dp2_legacy_product_transition_status_path() { printf '%s\n' "$TEST_ROOT/current.status"; }
dp2_prereq_log() { printf '%s %s\n' "$1" "${*:2}"; }
dpkg() {
  case "${1:-}" in
    --audit)
      [[ "${AUDIT_DIRTY:-0}" == 0 ]] || printf 'unconfigured fixture package\n'
      return "${AUDIT_RC:-0}"
      ;;
    --print-architecture) printf 'amd64\n' ;;
    *) echo "unexpected dpkg invocation: $*" >&2; return 2 ;;
  esac
}
dpkg-query() { return 1; }
apt-get() {
  printf 'call\n' >>"$TEST_ROOT/apt.calls"
  if [[ "${APT_ERROR:-0}" != 0 ]]; then
    printf 'fixture APT invocation failure\n' >&2
    return "$APT_ERROR"
  fi
  local rc=0
  if APT_CONFIG="$TEST_ROOT/apt.conf" LC_ALL=C /usr/bin/apt-get \
      -o "Dir::State::status=$TEST_ROOT/current.status" \
      -o "Dir::State::lists=$TEST_ROOT/lists" \
      -o "Dir::Cache=$TEST_ROOT/cache" \
      -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= \
      -o "Dir::Etc::sourcelist=$TEST_ROOT/sources.list" \
      -o "Dir::Etc::sourceparts=$TEST_ROOT/empty" "$@"; then
    rc=0
  else
    rc=$?
  fi
  if [[ "${MUTATE_STATUS:-0}" == 1 && "$*" == *phase2-legacy-graph.* ]]; then
    printf '\n' >>"$TEST_ROOT/current.status"
  fi
  return "$rc"
}

count=0
run_case() {
  local name="$1" fixture="$2" stage="$3" verdict="$4" marker="$5" rc=0 out before after
  cp "$TEST_ROOT/${fixture}.status" "$TEST_ROOT/current.status"
  : >"$TEST_ROOT/apt.calls"
  before="$(sha256sum "$TEST_ROOT/current.status")"
  if out="$(dp2_validate_apt_dependency_graph "$stage" 2>&1)"; then rc=0; else rc=$?; fi
  if [[ ( "$verdict" == pass && "$rc" != 0 ) || ( "$verdict" == fail && "$rc" == 0 ) ]]; then
    printf 'FAIL %s expected=%s rc=%s\n%s\n' "$name" "$verdict" "$rc" "$out" >&2
    exit 1
  fi
  if [[ "$out" != *"$marker"* ]]; then
    printf 'FAIL %s missing marker=%s\n%s\n' "$name" "$marker" "$out" >&2
    exit 1
  fi
  if [[ "$marker" == *DEFERRED* && "$out" == *'APT_DEPENDENCY_CHECK=PASS'* ]]; then
    printf 'FAIL %s incorrectly claims actual graph PASS\n%s\n' "$name" "$out" >&2
    exit 1
  fi
  if [[ "$verdict" == fail && "$out" == *'APT_DEPENDENCY_CHECK=DEFERRED_LEGACY_PY2'* ]]; then
    printf 'FAIL %s incorrectly defers failure\n%s\n' "$name" "$out" >&2
    exit 1
  fi
  after="$(sha256sum "$TEST_ROOT/current.status")"
  if [[ "${MUTATE_STATUS:-0}" == 0 && "$before" != "$after" ]]; then
    echo "FAIL $name modified input status" >&2
    exit 1
  fi
  count=$((count + 1))
  printf 'PASS %s\n' "$name"
}

for stage in staging prerequisites python3_apt; do
  run_case "owner_${stage}" owner "$stage" pass 'APT_DEPENDENCY_CHECK=DEFERRED_LEGACY_PY2'
done
run_case next_legacy next_legacy prerequisites pass 'APT_DEPENDENCY_CHECK=DEFERRED_LEGACY_PY2'
run_case reverse_preserved reverse_good prerequisites pass 'APT_DEPENDENCY_CHECK=DEFERRED_LEGACY_PY2'
for fixture in unrelated missing_openssl unknown_dep reverse_bad conflict; do
  run_case "$fixture" "$fixture" prerequisites fail 'reason=other_dependency_failure'
done
for fixture in complex_legacy partial mixed missing_product new_meta wrong_arch py3_version pre_depends; do
  run_case "$fixture" "$fixture" prerequisites fail 'LEGACY_PRODUCT_TRANSITION=UNSUPPORTED'
done
for stage in uvp final unspecified; do
  run_case "strict_${stage}" owner "$stage" fail 'APT_DEPENDENCY_CHECK=FAIL'
  [[ "$(wc -l <"$TEST_ROOT/apt.calls")" -eq 1 ]] || { echo 'FAIL strict stage ran shadow APT' >&2; exit 1; }
done
AUDIT_DIRTY=1 run_case dirty_audit owner prerequisites fail 'reason=dpkg_audit_dirty'
[[ ! -s "$TEST_ROOT/apt.calls" ]] || { echo 'FAIL dirty audit invoked APT' >&2; exit 1; }
AUDIT_RC=2 run_case failed_audit owner prerequisites fail 'reason=dpkg_audit_failed rc=2'
[[ ! -s "$TEST_ROOT/apt.calls" ]] || { echo 'FAIL failing audit invoked APT' >&2; exit 1; }
APT_ERROR=2 run_case apt_invocation_error owner prerequisites fail 'rc=2'
[[ "$(wc -l <"$TEST_ROOT/apt.calls")" -eq 1 ]] || { echo 'FAIL non-100 APT error attempted deferral' >&2; exit 1; }
MUTATE_STATUS=1 run_case concurrent_status_change owner prerequisites fail 'reason=status_changed'
run_case actual_clean_graph healthy final pass 'APT_DEPENDENCY_CHECK=PASS stage=final'
printf 'PASS phase2 legacy product transition (%s cases, isolated real APT)\n' "$count"
