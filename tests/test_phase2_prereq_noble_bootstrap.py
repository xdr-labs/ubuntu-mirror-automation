#!/usr/bin/env python3
"""Fresh PHASE2_ONLY Noble bootstrap; FULL and invalid sources remain fail-closed.

The fixture uses tiny real DEBs and an in-process loopback HTTP archive, never
touching a live mirror, external Ubuntu repository, or DP.
"""
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
PREPARE = ROOT / 'scripts/prepare-phase2-ubuntu-prerequisites.sh'


def make_deb(folder, name, depends=''):
    pkgdir = folder / ('build-' + name)
    control = pkgdir / 'DEBIAN/control'
    control.parent.mkdir(parents=True)
    control.write_text(
        'Package: %s\nVersion: 1\nArchitecture: amd64\n'
        'Maintainer: Test <test@example.invalid>\n'
        '%sDescription: isolated phase2 Noble bootstrap fixture\n' %
        (name, 'Depends: %s\n' % depends if depends else '')
    )
    deb = folder / ('%s_1_amd64.deb' % name)
    subprocess.run(['dpkg-deb', '-Zgzip', '--build', str(pkgdir), str(deb)],
                   check=True, stdout=subprocess.DEVNULL)
    return deb


class QuietHTTP(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


class NobleBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(prefix='phase2-noble-bootstrap-')
        self.base = Path(self.t.name)
        self.selective = self.base / 'absent-selective'
        self.dp_root = self.base / 'dp-phase2'
        self.dp_root.mkdir()
        self.acps = self.base / 'acps'
        self.acps.mkdir()
        self.common = self.acps / 'aelladeb_py3_common.tar.gz'
        root_deb = make_deb(self.acps, 'fixture-root',
                            'fixture-extra (>= 1)')
        inner = self.acps / 'py3-apt-packages.tar.gz'
        with tarfile.open(inner, 'w:gz') as tf:
            tf.add(root_deb, arcname=root_deb.name)
        with tarfile.open(self.common, 'w:gz') as tf:
            tf.add(inner, arcname=inner.name)

        # Authoritative metadata fixture; the selected DEB must still be
        # acquired from the repo URL and verified by its exact SHA256/Size.
        self.source = self.base / 'source'
        rel = Path('pool/main/f/fixture-extra/fixture-extra_1_amd64.deb')
        extra = self.source / 'ubuntu' / rel
        extra.parent.mkdir(parents=True)
        original = make_deb(self.acps, 'fixture-extra')
        extra.write_bytes(original.read_bytes())
        self.auth = self.base / 'authoritative'
        index = self.auth / 'dists/noble/main/binary-amd64/Packages'
        index.parent.mkdir(parents=True)
        index.write_text(
            'Package: fixture-extra\nVersion: 1\nArchitecture: amd64\n'
            'Filename: %s\nSize: %d\nSHA256: %s\n\n' %
            (rel.as_posix(), extra.stat().st_size,
             hashlib.sha256(extra.read_bytes()).hexdigest())
        )
        handler = functools.partial(QuietHTTP, directory=str(self.source))
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       daemon=True)
        self.thread.start()
        self.base_url = 'http://127.0.0.1:%s/ubuntu' % self.server.server_port

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        self.t.cleanup()

    def run_case(self, mode, label, overrides=None):
        dest = self.base / label
        env = os.environ.copy()
        for key in ('PHASE2_PREREQ_INDEX_ROOT',
                    'PHASE2_PREREQ_AUTHORITATIVE_ROOT',
                    'PHASE2_PREREQ_AUTHORITATIVE_CACHE'):
            env.pop(key, None)
        env.update({
            'PREPARATION_MODE': mode,
            'DP_PHASE2_VERSION': '6.6.0',
            'DP_PHASE2_ROOT': str(self.dp_root),
            'MM_SELECTIVE_ROOT': str(self.selective),
            'PHASE2_PREREQ_ACPS_COMMON': str(self.common),
            'PHASE2_PREREQ_OUT_DIR': str(dest),
            'PHASE2_PREREQ_ARCHIVE_BASE': self.base_url,
            'PHASE2_PREREQ_SECURITY_BASE': self.base_url,
            'PHASE2_PREREQ_AUTHORITATIVE_CACHE': str(self.base / 'auth-cache'),
        })
        env.update(overrides or {})
        proc = subprocess.run(
            ['bash', str(PREPARE), '6.6.0'], env=env,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=40,
        )
        return proc, dest

    def test_phase2_only_bootstraps_without_selective_and_verifies_deb(self):
        proc, dest = self.run_case(
            'PHASE2_ONLY', 'good', {
                'PHASE2_PREREQ_AUTHORITATIVE_ROOT': str(self.auth),
            }
        )
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertIn('PHASE2_PREREQ_INDEX_SOURCE=AUTHORITATIVE_BOOTSTRAP', proc.stdout)
        self.assertIn('PHASE2_PREREQ=PASS', proc.stdout)
        state = (dest / 'phase2-ubuntu-prerequisites.state').read_text()
        self.assertIn('PHASE2_PREREQ_BUILD=PASS', state)
        self.assertIn('PHASE2_PREREQ_PACKAGE_COUNT=1', state)
        manifest = json.loads(
            (dest / 'phase2-ubuntu-prerequisites.manifest.json').read_text())
        self.assertEqual([p['package'] for p in manifest['packages']],
                         ['fixture-extra'])
        self.assertTrue((dest / 'phase2-ubuntu-prerequisites.tar.gz').exists())
        self.assertFalse(self.selective.exists())

    def test_full_missing_selective_still_fails_closed(self):
        proc, dest = self.run_case(
            'FULL', 'full-missing', {
                'PHASE2_PREREQ_AUTHORITATIVE_ROOT': str(self.auth),
            }
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('reason=noble_index_missing', proc.stdout)
        self.assertFalse((dest / 'phase2-ubuntu-prerequisites.tar.gz').exists())

    def test_explicit_nonexistent_index_cannot_be_ignored(self):
        proc, dest = self.run_case(
            'PHASE2_ONLY', 'bad-override', {
                'PHASE2_PREREQ_INDEX_ROOT': str(self.base / 'missing-index'),
                'PHASE2_PREREQ_AUTHORITATIVE_ROOT': str(self.auth),
            }
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('reason=noble_index_missing', proc.stdout)
        self.assertFalse((dest / 'phase2-ubuntu-prerequisites.tar.gz').exists())

    def test_authoritative_source_missing_dependency_does_not_publish(self):
        empty = self.base / 'empty-authoritative'
        empty.mkdir()
        proc, dest = self.run_case(
            'PHASE2_ONLY', 'empty-auth', {
                'PHASE2_PREREQ_AUTHORITATIVE_ROOT': str(empty),
            }
        )
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn('PHASE2_PREREQ_BUILD=FAIL', proc.stdout)
        self.assertFalse((dest / 'phase2-ubuntu-prerequisites.tar.gz').exists())

    def test_existing_selective_root_is_preserved_as_source(self):
        sel = self.selective / 'hops/jammy-to-noble/ubuntu'
        index = sel / 'dists/noble/main/binary-amd64/Packages'
        index.parent.mkdir(parents=True)
        index.write_bytes(
            (self.auth / 'dists/noble/main/binary-amd64/Packages').read_bytes())
        proc, dest = self.run_case('FULL', 'full-valid')
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertNotIn('AUTHORITATIVE_BOOTSTRAP', proc.stdout)
        self.assertTrue((dest / 'phase2-ubuntu-prerequisites.tar.gz').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
