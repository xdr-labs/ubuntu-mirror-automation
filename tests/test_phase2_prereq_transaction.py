#!/usr/bin/env python3
"""Whole-prerequisite transaction gates against isolated, real APT graphs.

Real dpkg-deb reads tiny fixtures. A recording dpkg replacement modifies only
each test's temporary status file; it never executes dpkg -i or maintainer code.
APT reads private status/config/cache paths with no package sources.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / 'client/lib/dp-phase2-ubuntu-prerequisites.sh'
OLD = '3.0.13-0ubuntu3.6'
NEW = '3.0.13-0ubuntu3.15'
LEGACY_DEPENDS = {
    'aella-da-cli': 'python2.7, python-openssl, python-yaml',
    'aella-da-services': 'python2.7, openssl, python-openssl, python-yaml, python-concurrent.futures',
    'aella-uvp': 'python, openssl, python-openssl, python-yaml, python-flask, python-concurrent.futures, python-configparser, python-tabulate, python-tornado, python-httplib2, python-requests, python-psutil',
    'aellacm': 'python2.7, python-yaml, python-tornado, python-httplib2, python-requests, python-crypto, pypki',
    'kube-tools': 'python2.7', 'phonehome': '',
    'pypki': 'python2.7, openssl, python-configparser, python-tabulate',
}


def package(name, version='1', depends='', architecture='amd64', extra=''):
    return ('Package: %s\nStatus: install ok installed\nVersion: %s\n'
            'Architecture: %s\nMaintainer: Test <test@example.invalid>\n'
            '%s%sDescription: isolated prerequisite transaction fixture\n' % (
                name, version, architecture,
                'Depends: ' + depends + '\n' if depends else '', extra))


def ssl_status(runtime=OLD, development=OLD, cli=OLD):
    return '\n'.join((package('libssl3t64', runtime),
                      package('libssl-dev', development,
                              'libssl3t64 (= ' + development + ')'),
                      package('openssl', cli, 'libssl3t64 (>= 3.0.9)'),
                      package('libkrb5support0', '1.20.1-6ubuntu2.6')))


def legacy_status():
    return '\n'.join(package(p, '6.2.1ubuntu1', deps)
                     for p, deps in LEGACY_DEPENDS.items())


DPKG_STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
if args == ['--audit']:
    if os.environ.get('TX_AUDIT_DIRTY') == '1':
        print('fixture package is unconfigured')
    raise SystemExit(int(os.environ.get('TX_AUDIT_RC', '0')))
if args[:1] in (['--compare-versions'], ['--print-architecture']):
    os.execv('/usr/bin/dpkg', ['dpkg'] + args)
if args[:1] != ['-i']:
    raise SystemExit('unexpected dpkg operation: ' + repr(args))
status = pathlib.Path(os.environ['TX_STATUS'])
records = status.read_text().strip().split('\n\n') if status.read_text().strip() else []
changes = []
labels = []
def value(record, key):
    return next((line.split(':', 1)[1].strip() for line in record.splitlines()
                 if line.startswith(key + ':')), '')
for name in args[1:]:
    control = subprocess.check_output(['/usr/bin/dpkg-deb', '-f', name], text=True)
    changes.append(control)
    labels.append(value(control, 'Package') + '=' + value(control, 'Version'))
with open(os.environ['TX_INSTALL_CALLS'], 'a') as out:
    out.write(json.dumps(labels) + '\n')
rc = int(os.environ.get('TX_DPKG_RC', '0'))
if rc:
    raise SystemExit(rc)
for control in changes:
    identity = (value(control, 'Package'), value(control, 'Architecture'))
    records = [record for record in records if
               (value(record, 'Package'), value(record, 'Architecture')) != identity]
    records.append(control.strip() + '\nStatus: install ok installed')
status.write_text('\n\n'.join(records) + '\n')
'''


APT_STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
if args[-1:] != ['check']:
    raise SystemExit('unexpected APT operation: ' + repr(args))
status = os.environ['TX_STATUS']
for item in args:
    if item.startswith('Dir::State::status='):
        status = item.split('=', 1)[1]
with open(os.environ['TX_APT_CALLS'], 'a') as out:
    out.write(json.dumps({'status': status, 'args': args}) + '\n')
rc = subprocess.call(['/usr/bin/apt-get'] + args)
if rc == 0 and status.endswith('.status-projected'):
    if os.environ.get('TX_MUTATE_PLAN') == '1':
        plan = pathlib.Path(status.removesuffix('.status-projected'))
        data = json.loads(plan.read_text())
        data['install_groups'] = []
        plan.write_text(json.dumps(data) + '\n')
        pathlib.Path(os.environ['TX_MUTATION_MARKER']).write_text('changed selected plan\n')
    if os.environ.get('TX_MUTATE_PROJECTION') == '1':
        with open(status, 'a') as out:
            out.write('\nPackage: injected-fixture\nVersion: 1\nArchitecture: amd64\n'
                      'Status: install ok installed\nDescription: injected fixture\n')
        pathlib.Path(os.environ['TX_MUTATION_MARKER']).write_text('changed projected status\n')
if os.environ.get('TX_MUTATE_STATUS') == '1' and status != os.environ['TX_STATUS']:
    marker = pathlib.Path(os.environ['TX_MUTATION_MARKER'])
    if not marker.exists():
        with open(os.environ['TX_STATUS'], 'a') as out:
            out.write('\n')
        marker.write_text('external fixture writer changed status after projection\n')
raise SystemExit(rc)
'''


class PrerequisiteTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='phase2-prereq-transaction.')
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.db = self.root / 'dpkg'
        self.db.mkdir()
        self.status = self.db / 'status'
        self.status.write_text(ssl_status())
        self.calls = self.root / 'install.calls'
        self.calls.write_text('')
        self.apt_calls = self.root / 'apt.calls'
        self.apt_calls.write_text('')
        self.maintainer = self.root / 'maintainer-ran'
        self.mutation = self.root / 'status-mutated'
        self.serial = 0
        for name, source in [('dpkg', DPKG_STUB), ('apt-get', APT_STUB),
                             ('dpkg-query', '#!/bin/sh\nexec /usr/bin/dpkg-query '
                              '--admindir="$TX_DATABASE" "$@"\n')]:
            path = self.bin / name
            path.write_text(source)
            path.chmod(0o755)
        for name in ('empty', 'lists', 'cache', 'logs'):
            (self.root / name).mkdir()
        for name in ('empty.conf', 'sources.list', 'preferences'):
            (self.root / name).write_text('')
        self.config = self.root / 'apt.conf'
        dirs = {
            'Dir::Etc::parts': 'empty', 'Dir::Etc::main': 'empty.conf',
            'Dir::Etc::sourcelist': 'sources.list', 'Dir::Etc::sourceparts': 'empty',
            'Dir::Etc::preferences': 'preferences', 'Dir::Etc::preferencesparts': 'empty',
            'Dir::State::status': 'dpkg/status', 'Dir::State::lists': 'lists',
            'Dir::Cache': 'cache', 'Dir::Log': 'logs',
        }
        self.config.write_text(''.join('%s "%s";\n' % (key, self.root / path)
                                       for key, path in dirs.items())
                               + 'Dir::Cache::pkgcache "";\nDir::Cache::srcpkgcache "";\n'
                                 'Debug::NoLocking "true";\n')

    def tearDown(self):
        self.assertFalse(self.maintainer.exists(), 'fixture maintainer code was executed')
        self.temp.cleanup()

    def deb(self, destination, name, version='1', depends='', architecture='amd64', extra=''):
        self.serial += 1
        build = self.root / ('build-%d' % self.serial)
        control = build / 'DEBIAN'
        control.mkdir(parents=True)
        (control / 'control').write_text(package(name, version, depends, architecture, extra)
                                        .replace('Status: install ok installed\n', ''))
        (control / 'postinst').write_text('#!/bin/sh\ntouch "%s"\n' % self.maintainer)
        (control / 'postinst').chmod(0o755)
        filename = '%s_%s_%s.deb' % (name, version, architecture)
        target = destination / filename
        subprocess.run(['/usr/bin/dpkg-deb', '--root-owner-group', '-Zgzip', '--build',
                        str(build), str(target)], check=True, capture_output=True)
        return filename

    def bundle(self, specs, groups=None, missing=None):
        tree = self.root / 'artifact-tree'
        debs = tree / 'debs'
        debs.mkdir(parents=True)
        names = [self.deb(debs, **spec) for spec in specs]
        order = '\n'.join(names) if groups is None else '\n'.join(groups(names))
        if missing:
            order += '\n' + missing
        (tree / 'install-order.txt').write_text(order + '\n')
        archive = self.root / 'phase2-ubuntu-prerequisites.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(tree / 'install-order.txt', arcname='install-order.txt')
            tar.add(debs, arcname='debs')
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        Path(str(archive) + '.sha256').write_text(digest + '  ' + archive.name + '\n')
        self.state = self.root / 'phase2-ubuntu-prerequisites.state'
        self.state.write_text(
            'PHASE2_PREREQ_REQUIRED=YES\nPHASE2_PREREQ_PACKAGE_COUNT=%d\n'
            'PHASE2_PREREQ_BUILD=PASS\nPHASE2_PREREQ_PUBLICATION=PASS\n'
            'PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz\n'
            'PHASE2_PREREQ_SHA256=%s\n' % (len(names), digest))
        self.manifest = self.root / 'phase2-ubuntu-prerequisites.manifest.json'
        self.manifest.write_text(json.dumps({'package_count': len(names), 'sha256': digest}))
        self.archive = archive

    def invoke(self, **changes):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                   APT_CONFIG=str(self.config), LC_ALL='C', TX_STATUS=str(self.status),
                   TX_DATABASE=str(self.db), TX_INSTALL_CALLS=str(self.calls),
                   TX_APT_CALLS=str(self.apt_calls), TX_MUTATION_MARKER=str(self.mutation),
                   PHASE2_PREREQ_ARTIFACT=str(self.archive),
                   PHASE2_PREREQ_STATE=str(self.state), PHASE2_PREREQ_MANIFEST=str(self.manifest))
        env.update(changes)
        script = '''set -uo pipefail
source "$1"
dp2_legacy_product_transition_status_path() { printf '%s\\n' "$TX_STATUS"; }
dp2_legacy_product_transition_environment() { return 0; }
dp2_prereq_log() { printf '%s\\n' "$*"; }
dp2_install_phase2_ubuntu_prerequisites
'''
        return subprocess.run(['bash', '-c', script, 'transaction-test', str(LIBRARY)],
                              env=env, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=30)

    def blocked(self, result, before, text=None, allow_external_change=False):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.calls.read_text(), '', 'dpkg ran before rejection:\n' +
                         self.calls.read_text() + '\n' + result.stdout)
        if not allow_external_change:
            self.assertEqual(self.status.read_bytes(), before, result.stdout)
        if text:
            self.assertIn(text, result.stdout)
        self.assertNotIn('PHASE2_PREREQ_INSTALL=PASS', result.stdout)

    @staticmethod
    def early():
        return {'name': 'libkrb5support0', 'version': '1.20.1-6ubuntu2.8'}

    def test_field_reverse_dependency_blocks_even_earlier_group(self):
        self.bundle([self.early(), {'name': 'libssl3t64', 'version': NEW}])
        before = self.status.read_bytes()
        self.blocked(self.invoke(), before, 'libssl-dev')

    def test_later_newer_installed_version_blocks_earlier_group(self):
        self.status.write_text(ssl_status() + '\n' + package('later-fixture', '3'))
        self.bundle([self.early(), {'name': 'later-fixture', 'version': '2'}])
        before = self.status.read_bytes()
        self.blocked(self.invoke(), before)

    def test_later_missing_ordered_file_blocks_earlier_group(self):
        self.bundle([self.early()], missing='missing_1_amd64.deb')
        before = self.status.read_bytes()
        self.blocked(self.invoke(), before)

    def test_complete_companion_projection_installs_in_verified_order(self):
        self.bundle([self.early(), {'name': 'libssl3t64', 'version': NEW},
                     {'name': 'libssl-dev', 'version': NEW,
                      'depends': 'libssl3t64 (= ' + NEW + ')'}])
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual([json.loads(line) for line in self.calls.read_text().splitlines()], [
            ['libkrb5support0=1.20.1-6ubuntu2.8'], ['libssl3t64=' + NEW],
            ['libssl-dev=' + NEW]])
        self.assertIn('PHASE2_PREREQ_INSTALL=PASS', result.stdout)

    def test_known_legacy_python_edges_allow_valid_transaction(self):
        self.status.write_text(ssl_status() + '\n' + legacy_status())
        self.bundle([self.early()])
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('APT_DEPENDENCY_CHECK=DEFERRED_LEGACY_PY2', result.stdout)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_legacy_exception_does_not_hide_projected_ssl_failure(self):
        self.status.write_text(ssl_status() + '\n' + legacy_status())
        self.bundle([self.early(), {'name': 'libssl3t64', 'version': NEW}])
        before = self.status.read_bytes()
        self.blocked(self.invoke(), before, 'libssl-dev')

    def test_already_broken_graph_blocks_before_any_install(self):
        self.status.write_text(ssl_status(runtime=NEW, cli=NEW))
        self.bundle([self.early()])
        before = self.status.read_bytes()
        self.blocked(self.invoke(), before, 'libssl-dev')

    def test_unrelated_failure_is_not_legacy_exception(self):
        self.status.write_text(ssl_status() + '\n' + legacy_status() + '\n' +
                               package('unrelated-consumer', depends='missing-library'))
        self.bundle([self.early()])
        before = self.status.read_bytes()
        self.blocked(self.invoke(), before)

    def test_real_install_failure_code_preserved(self):
        self.bundle([self.early()])
        before = self.status.read_bytes()
        result = self.invoke(TX_DPKG_RC='42')
        self.assertEqual(result.returncode, 42, result.stdout)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)
        self.assertEqual(self.status.read_bytes(), before)
        self.assertIn('PHASE2_PREREQ_DPKG=FAIL', result.stdout)

    def test_status_change_during_projection_blocks_before_install(self):
        self.bundle([self.early()])
        before = self.status.read_bytes()
        result = self.invoke(TX_MUTATE_STATUS='1')
        self.assertTrue(self.mutation.exists(), 'fixture never observed a private projection')
        self.blocked(result, before, allow_external_change=True)

    def test_malformed_status_does_not_pass(self):
        self.status.write_text(ssl_status().replace('Version: ' + OLD,
                               'Version: ' + OLD + '\nVersion: ' + OLD, 1))
        self.bundle([self.early()])
        before = self.status.read_bytes()
        self.blocked(self.invoke(), before)

    def test_plan_changed_during_projection_blocks_before_install(self):
        self.bundle([self.early()])
        before = self.status.read_bytes()
        result = self.invoke(TX_MUTATE_PLAN='1')
        self.assertTrue(self.mutation.exists(), 'fixture did not modify the selected plan')
        self.blocked(result, before, 'reason=plan_changed')

    def test_projected_status_changed_after_apt_blocks_before_install(self):
        self.bundle([self.early()])
        before = self.status.read_bytes()
        result = self.invoke(TX_MUTATE_PROJECTION='1')
        self.assertTrue(self.mutation.exists(), 'fixture did not modify projected status')
        self.blocked(result, before, 'reason=projection_changed')

    def test_ambiguous_selected_multiarch_does_not_pass(self):
        self.status.write_text(ssl_status() + '\n' + package(
            'libkrb5support0', '1.20.1-6ubuntu2.6', architecture='i386',
            extra='Multi-Arch: same\n'))
        self.bundle([self.early()])
        before = self.status.read_bytes()
        self.blocked(self.invoke(), before)

    def test_dirty_audit_blocks_before_install(self):
        self.bundle([self.early()])
        before = self.status.read_bytes()
        self.blocked(self.invoke(TX_AUDIT_DIRTY='1'), before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
