#!/usr/bin/env bash
# Exercise the sealed-vendor in-memory hook. No product package or service
# operation is executed; every vendor body used at runtime is a local fixture.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${1:-${ROOT}/client/lib/dp-phase2-ubuntu-prerequisites.sh}"
python3 - "$ROOT" "$LIB" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root, lib = map(Path, sys.argv[1:])
environment = {k: v for k, v in os.environ.items()
               if not k.startswith('_DP2_') and k not in ('BASH_ENV', 'ENV')}
stubs = r'''
log() { printf '%s\n' "$*"; }
install_test_validators() {
  dp2_validate_installed_product_replacement() {
    printf 'packages:%s\n' "$1"
    return "${PACKAGE_RC:-0}"
  }
  dp2_validate_apt_dependency_graph() {
    printf 'apt:%s\n' "$1"
    return "${APT_RC:-0}"
  }
}
install_test_validators
VERSION=6.6.0
'''
base = 'set -euo pipefail\nsource "$1"\n' + stubs
count = 0


def run(name, body, rc=0, contains=(), absent=(), args=()):
    global count
    result = subprocess.run(['bash', '-c', base + body, name, str(lib), *args],
                            text=True, capture_output=True, env=environment)
    output = result.stdout + result.stderr
    assert result.returncode == rc, (name, result.returncode, output)
    for text in contains:
        assert text in output, (name, 'missing', text, output)
    for text in absent:
        assert text not in output, (name, 'unexpected', text, output)
    count += 1
    print('PASS', name)
    return output


for role in ('master', 'worker'):
    out = run('success_' + role, r'''
install_uvp() { printf 'vendor:%s\n' "$1"; }
dp2_arm_product_transition_guard
install_uvp ''' + role + r'''
printf 'prepare_system\n'
''', contains=('PRODUCT_TRANSITION_HOOK=ARMED state=new', 'vendor:' + role,
               'packages:6.6.0', 'apt:uvp', 'PRODUCT_REPLACEMENT=PASS',
               'prepare_system'))
    assert out.index('vendor:' + role) < out.index('packages:6.6.0')
    assert out.index('packages:6.6.0') < out.index('apt:uvp') < out.index('prepare_system')

run('rearm_and_resource', r'''
install_uvp() { printf 'vendor_once\n'; return 0; }
dp2_arm_product_transition_guard
source "$1"
install_test_validators
dp2_arm_product_transition_guard
install_uvp
''', contains=('PRODUCT_TRANSITION_HOOK=ARMED state=existing',
               'vendor_once', 'PRODUCT_REPLACEMENT=PASS'))

run('errexit_preserved_inside_original', r'''
install_uvp() { printf 'vendor_enter\n'; false; printf 'invalid_continuation\n'; }
dp2_arm_product_transition_guard
install_uvp
printf 'prepare_system\n'
''', rc=1, contains=('vendor_enter',),
    absent=('invalid_continuation', 'packages:', 'prepare_system'))

run('explicit_vendor_failure_without_errexit', r'''
set +e
install_uvp() { return 17; }
dp2_arm_product_transition_guard
install_uvp
printf 'prepare_system\n'
''', rc=17, contains=('PRODUCT_REPLACEMENT=FAIL reason=vendor_install_uvp rc=17',),
    absent=('packages:', 'prepare_system'))

for fail, marker in (('PACKAGE_RC=1', 'installed_packages'),
                     ('APT_RC=100', 'apt_dependency_graph')):
    run('failed_' + marker, r'''
install_uvp() { printf 'vendor_enter\n'; return 0; }
dp2_arm_product_transition_guard
''' + fail + r'''
install_uvp
printf 'prepare_system\n'
''', rc=1, contains=('PRODUCT_REPLACEMENT=FAIL reason=' + marker,),
        absent=('PRODUCT_REPLACEMENT=PASS', 'prepare_system'))

for name in ('dp2_validate_installed_product_replacement',
             'dp2_validate_apt_dependency_graph'):
    run('missing_at_arm_' + name, r'''
install_uvp() { printf 'vendor_enter\n'; }
unset -f ''' + name + r'''
dp2_arm_product_transition_guard
install_uvp
''', rc=1, contains=('PRODUCT_TRANSITION_HOOK=FAIL reason=validator_missing',),
        absent=('vendor_enter',))
    run('missing_after_arm_' + name, r'''
install_uvp() { printf 'vendor_enter\n'; }
dp2_arm_product_transition_guard
unset -f ''' + name + r'''
install_uvp
''', rc=1, contains=('PRODUCT_REPLACEMENT=FAIL reason=validator_missing',),
        absent=('vendor_enter',))

run('reserved_function_conflict', r'''
install_uvp() { printf 'vendor_enter\n'; }
dp2_vendor_install_uvp() { :; }
dp2_arm_product_transition_guard
''', rc=1, contains=('PRODUCT_TRANSITION_HOOK=FAIL reason=reserved_function_conflict',),
    absent=('vendor_enter',))

run('reserved_state_conflict', r'''
install_uvp() { printf 'vendor_enter\n'; }
_DP2_VENDOR_INSTALL_UVP_DECLARATION=foreign
dp2_arm_product_transition_guard
''', rc=1, contains=('PRODUCT_TRANSITION_HOOK=FAIL reason=reserved_function_conflict',))

for action in ('dp2_arm_product_transition_guard', 'install_uvp'):
    run('original_changed_' + action, r'''
install_uvp() { printf 'vendor_enter\n'; }
dp2_arm_product_transition_guard
dp2_vendor_install_uvp() { printf 'foreign_vendor\n'; }
''' + action + '\n', rc=1, contains=('reason=original_changed',),
        absent=('foreign_vendor', 'vendor_enter'))

run('original_missing_on_rearm', r'''
install_uvp() { :; }
dp2_arm_product_transition_guard
unset -f dp2_vendor_install_uvp
dp2_arm_product_transition_guard
''', rc=1, contains=('PRODUCT_TRANSITION_HOOK=FAIL reason=original_missing',))

run('non_vendor_context', r'''
dp2_arm_product_transition_guard
if declare -F dp2_vendor_install_uvp >/dev/null; then exit 8; fi
printf 'outside_vendor\n'
''', contains=('outside_vendor',), absent=('PRODUCT_TRANSITION_HOOK=ARMED',))

with tempfile.TemporaryDirectory(prefix='phase2-product-hook.') as tmp:
    tmp = Path(tmp)
    # Source the actual vendor function declaration without invoking its body.
    # This proves the exact loaded function survives the rename unchanged.
    for variant in ('production-3af369', 'production-f1a73'):
        fixture = root / 'tests/fixtures/dp-phase2' / variant / 'bringup_py3_dp_after_os_upgrade.sh'
        before = fixture.read_bytes()
        source = before.decode()
        start = source.index('\ninstall_uvp() {') + 1
        end = source.index('\nprepare_system() {', start)
        definition = tmp / (variant + '.sh')
        definition.write_text(source[start:end])
        run('real_declaration_' + variant, r'''
source "$2"
before="$(declare -f install_uvp)"
first="${before%%$'\n'*}"
expected="dp2_vendor_install_uvp () ${before#"$first"}"
dp2_arm_product_transition_guard
[[ "$(declare -f dp2_vendor_install_uvp)" == "$expected" ]]
dp2_arm_product_transition_guard
printf 'original_definition_preserved\n'
''', args=(str(definition),), contains=('original_definition_preserved',))
        assert fixture.read_bytes() == before

    # Exercise the real sealed-vendor helper-loading call chain. Its library
    # is sourced inside a conditional function; the installed wrapper must
    # nevertheless persist into the later bare install_uvp call.
    golden = (root / 'vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh').read_text()
    functions = []
    for name in ('source_phase2_prereq_lib', 'install_phase2_ubuntu_prerequisites'):
        start = golden.index('\n' + name + '() {') + 1
        end = golden.index('\n}\n', start) + 3
        functions.append(golden[start:end])
    loader = tmp / 'vendor-loader.sh'
    loader.write_text('\n'.join(functions))
    state = tmp / 'prerequisites.state'
    state.write_text('PHASE2_PREREQ_REQUIRED=NO\nPHASE2_PREREQ_PACKAGE_COUNT=0\n'
                     'PHASE2_PREREQ_BUILD=PASS\nPHASE2_PREREQ_PUBLICATION=PASS\n')
    reload_lib = tmp / 'reload-library.sh'
    reload_lib.write_text(lib.read_text() + '\n' + stubs + r'''
dp2_prereq_find_state() { printf '%s\n' "$TEST_STATE"; }
''')
    run('sealed_vendor_loading_chain', r'''
source "$2"
TEST_RELOAD_LIB="$3"
TEST_STATE="$4"
phase2_prereq_lib_paths() { printf '%s\n' "$TEST_RELOAD_LIB"; }
install_uvp() { printf 'vendor_enter\n'; return 0; }
install_python3() {
  install_phase2_ubuntu_prerequisites || exit 3
  printf 'python_early_return\n'
  return 0
}
install_python3
install_uvp
printf 'prepare_system\n'
''', args=(str(loader), str(reload_lib), str(state)),
        contains=('PRODUCT_TRANSITION_HOOK=ARMED state=new',
                  'python_early_return', 'vendor_enter', 'apt:uvp',
                  'PRODUCT_REPLACEMENT=PASS', 'prepare_system'))

print('PHASE2_PRODUCT_TRANSITION_HOOK=PASS cases=%d' % count)
PY
