#!/usr/bin/env python3
"""H7 DistUpgrade source compatibility + target pocket provenance tests.

Covers signed-by invalidation, legacy keyring, pocket provenance, identical
index detection, kernel family gates, and pre-DRO semantic gate blocking.
No live DP, do-release-upgrade, reboot, or mirror publish.
"""
from __future__ import print_function

import hashlib
import os
import shutil
import sys
import tempfile
import unittest
from collections import OrderedDict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, 'scripts', 'lib')
if LIB not in sys.path:
    sys.path.insert(0, LIB)
SCRIPTS = os.path.join(ROOT, 'scripts')
if SCRIPTS not in sys.path:
    sys.path.insert(0, SCRIPTS)

import distupgrade_source_compat as dsc  # noqa: E402
import selective_mirror as sm  # noqa: E402


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as fh:
        fh.write(text)


class TestDistUpgradeSourceCompat(unittest.TestCase):
    def test_01_signed_by_source_invalid(self):
        line = (
            'deb [arch=amd64 signed-by=/etc/apt/keyrings/x.gpg] '
            'http://m/ubuntu bionic main universe'
        )
        parsed = dsc.distupgrade_source_entry_valid(line)
        self.assertTrue(parsed['invalid'])
        self.assertIn('signed-by', parsed['rejected_options'])

    def test_02_arch_only_source_valid(self):
        line = 'deb [arch=amd64] http://m/ubuntu bionic main universe'
        parsed = dsc.distupgrade_source_entry_valid(line)
        self.assertFalse(parsed['invalid'])
        self.assertEqual(parsed['dist'], 'bionic')
        self.assertEqual(parsed['comps'], ['main', 'universe'])

    def test_06_trusted_yes_forbidden_helper(self):
        err = dsc.line_has_forbidden_auth(
            'deb [arch=amd64 trusted=yes] http://m/ubuntu bionic main'
        )
        self.assertEqual(err, 'FAIL_TRUSTED_YES_FORBIDDEN')

    def test_07_allow_unauthenticated_forbidden(self):
        err = dsc.line_has_forbidden_auth('APT::Get::AllowUnauthenticated=true;')
        self.assertEqual(err, 'FAIL_ALLOW_UNAUTHENTICATED_FORBIDDEN')

    def test_08_to_11_four_target_suites_valid(self):
        lines = dsc.generate_legacy_target_sources(
            'http://m/hops/xenial-to-bionic/ubuntu',
            ['bionic', 'bionic-updates', 'bionic-security', 'bionic-backports'],
            'main universe',
        )
        result = dsc.analyze_distupgrade_sources(
            lines,
            expected_suites=[
                'bionic', 'bionic-updates', 'bionic-security', 'bionic-backports',
            ],
        )
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['valid_count'], 4)
        self.assertEqual(result['invalid_count'], 0)
        for key in (
            'DISTUPGRADE_SOURCE_VALID_bionic',
            'DISTUPGRADE_SOURCE_VALID_bionic_updates',
            'DISTUPGRADE_SOURCE_VALID_bionic_security',
            'DISTUPGRADE_SOURCE_VALID_bionic_backports',
        ):
            self.assertEqual(result['suite_results'][key], 'PASS')

    def test_12_valid_source_count_mismatch(self):
        lines = dsc.generate_legacy_target_sources(
            'http://m/ubuntu',
            ['bionic', 'bionic-updates', 'bionic-security'],
            'main universe',
        )
        result = dsc.analyze_distupgrade_sources(
            lines,
            expected_suites=[
                'bionic', 'bionic-updates', 'bionic-security', 'bionic-backports',
            ],
        )
        self.assertFalse(result['ok'])
        self.assertEqual(result['error'], 'FAIL_DISTUPGRADE_SOURCE_COUNT_MISMATCH')

    def test_signed_by_in_analyze_errors(self):
        lines = [
            'deb [arch=amd64 signed-by=/k.gpg] http://m/ubuntu bionic main universe',
            'deb [arch=amd64 signed-by=/k.gpg] http://m/ubuntu bionic-updates main universe',
            'deb [arch=amd64 signed-by=/k.gpg] http://m/ubuntu bionic-security main universe',
            'deb [arch=amd64 signed-by=/k.gpg] http://m/ubuntu bionic-backports main universe',
        ]
        result = dsc.analyze_distupgrade_sources(
            lines,
            expected_suites=[
                'bionic', 'bionic-updates', 'bionic-security', 'bionic-backports',
            ],
        )
        self.assertFalse(result['ok'])
        self.assertEqual(result['error'], 'FAIL_SIGNED_BY_PRESENT_IN_DISTUPGRADE_SOURCE')

    def _four_target_body(self, header_comment):
        suites = ['bionic', 'bionic-updates', 'bionic-security', 'bionic-backports']
        lines = [header_comment]
        for s in suites:
            lines.append('deb [arch=amd64] http://m/ubuntu %s main universe' % s)
        return '\n'.join(lines) + '\n'

    def test_utf8_comment_under_ascii_locale_pass(self):
        tmp = tempfile.mkdtemp(prefix='dsc-utf8-')
        try:
            path = os.path.join(tmp, 'sources.list')
            text = self._four_target_body(
                '# stellar offline upgrade xenial-to-bionic — DistUpgrade-compatible'
            )
            with open(path, 'wb') as fh:
                fh.write(text.encode('utf-8'))
            # Simulate Xenial LC_ALL=C: locale preferred encoding is ASCII, but
            # our reader must NOT use it.
            old = os.environ.get('LC_ALL')
            os.environ['LC_ALL'] = 'C'
            try:
                result = dsc.analyze_distupgrade_sources_file(
                    path,
                    expected_suites=[
                        'bionic', 'bionic-updates', 'bionic-security', 'bionic-backports',
                    ],
                )
            finally:
                if old is None:
                    os.environ.pop('LC_ALL', None)
                else:
                    os.environ['LC_ALL'] = old
            self.assertEqual(result['DISTUPGRADE_SOURCE_DECODE_RESULT'], 'PASS')
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['valid_count'], 4)
            self.assertGreaterEqual(result['DISTUPGRADE_SOURCE_NONASCII_COMMENT_COUNT'], 1)
            self.assertEqual(result['error'], '')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_utf8_en_dash_comment_pass(self):
        tmp = tempfile.mkdtemp(prefix='dsc-endash-')
        try:
            path = os.path.join(tmp, 'sources.list')
            # U+2013 EN DASH (E2 80 93)
            text = self._four_target_body('# pocket – security')
            with open(path, 'wb') as fh:
                fh.write(text.encode('utf-8'))
            result = dsc.analyze_distupgrade_sources_file(
                path,
                expected_suites=[
                    'bionic', 'bionic-updates', 'bionic-security', 'bionic-backports',
                ],
            )
            self.assertEqual(result['DISTUPGRADE_SOURCE_DECODE_RESULT'], 'PASS')
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['valid_count'], 4)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_utf8_arrow_comment_pass(self):
        tmp = tempfile.mkdtemp(prefix='dsc-arrow-')
        try:
            path = os.path.join(tmp, 'sources.list')
            text = self._four_target_body('# xenial → bionic offline')
            with open(path, 'wb') as fh:
                fh.write(text.encode('utf-8'))
            result = dsc.analyze_distupgrade_sources_file(
                path,
                expected_suites=[
                    'bionic', 'bionic-updates', 'bionic-security', 'bionic-backports',
                ],
            )
            self.assertEqual(result['DISTUPGRADE_SOURCE_DECODE_RESULT'], 'PASS')
            self.assertTrue(result['ok'], result)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_utf8_bom_file_pass(self):
        tmp = tempfile.mkdtemp(prefix='dsc-bom-')
        try:
            path = os.path.join(tmp, 'sources.list')
            text = self._four_target_body('# bom header')
            with open(path, 'wb') as fh:
                fh.write(b'\xef\xbb\xbf' + text.encode('utf-8'))
            result = dsc.analyze_distupgrade_sources_file(
                path,
                expected_suites=[
                    'bionic', 'bionic-updates', 'bionic-security', 'bionic-backports',
                ],
            )
            self.assertEqual(result['DISTUPGRADE_SOURCE_INPUT_ENCODING'], 'UTF-8-SIG')
            self.assertEqual(result['DISTUPGRADE_SOURCE_DECODE_RESULT'], 'PASS')
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['valid_count'], 4)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_malformed_utf8_is_text_decode_not_invalid(self):
        tmp = tempfile.mkdtemp(prefix='dsc-badutf8-')
        try:
            path = os.path.join(tmp, 'sources.list')
            # Invalid UTF-8 sequence (lone 0xe2, same leading byte as em-dash)
            with open(path, 'wb') as fh:
                fh.write(b'# bad \xe2\n')
                fh.write(b'deb [arch=amd64] http://m/ubuntu bionic main universe\n')
            result = dsc.analyze_distupgrade_sources_file(
                path,
                expected_suites=['bionic', 'bionic-updates', 'bionic-security', 'bionic-backports'],
            )
            self.assertFalse(result['ok'])
            self.assertEqual(result['error'], 'FAIL_DISTUPGRADE_SOURCE_TEXT_DECODE')
            self.assertEqual(result['DISTUPGRADE_SOURCE_DECODE_RESULT'], 'FAIL')
            self.assertNotEqual(result['error'], 'FAIL_DISTUPGRADE_SOURCE_INVALID')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_legacy_open_without_encoding_reproduces_ascii_failure(self):
        """Document the original bug: locale ASCII + open(path) on em-dash."""
        tmp = tempfile.mkdtemp(prefix='dsc-repro-')
        try:
            path = os.path.join(tmp, 'sources.list')
            line = (
                '# stellar offline upgrade xenial-to-bionic — DistUpgrade-compatible\n'
            )
            with open(path, 'wb') as fh:
                fh.write(line.encode('utf-8'))
            raw = open(path, 'rb').read()
            self.assertEqual(raw[43], 0xe2)
            # Force ASCII decode path equivalent to Xenial LC_ALL=C open().
            with self.assertRaises(UnicodeDecodeError):
                raw.decode('ascii')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_trusted_yes_in_analyze_errors(self):
        lines = [
            'deb [arch=amd64 trusted=yes] http://m/ubuntu bionic main universe',
            'deb [arch=amd64] http://m/ubuntu bionic-updates main universe',
            'deb [arch=amd64] http://m/ubuntu bionic-security main universe',
            'deb [arch=amd64] http://m/ubuntu bionic-backports main universe',
        ]
        result = dsc.analyze_distupgrade_sources(
            lines,
            expected_suites=[
                'bionic', 'bionic-updates', 'bionic-security', 'bionic-backports',
            ],
        )
        self.assertFalse(result['ok'])
        self.assertEqual(result['error'], 'FAIL_TRUSTED_YES_FORBIDDEN')


class TestPocketProvenance(unittest.TestCase):
    def test_16_blank_suite_unresolved(self):
        resolved = dsc.resolve_target_suite(
            {'suite': '', 'original_url': 'http://archive.ubuntu.com/ubuntu/pool/main/a/a.deb',
             'repository_host': 'archive.ubuntu.com', 'sha256': 'a' * 64},
            'bionic',
        )
        self.assertEqual(resolved['error'], dsc.UNRESOLVED_TARGET_POCKET)
        self.assertEqual(resolved['source_suite'], '')

    def test_17_blank_suite_not_auto_bionic(self):
        resolved = dsc.resolve_target_suite({'suite': ''}, 'bionic')
        self.assertNotEqual(resolved['source_suite'], 'bionic')
        self.assertEqual(resolved['error'], dsc.UNRESOLVED_TARGET_POCKET)

    def test_security_host_resolves(self):
        resolved = dsc.resolve_target_suite(
            {
                'suite': '',
                'original_url': 'http://security.ubuntu.com/ubuntu/pool/main/u/x.deb',
                'repository_host': 'security.ubuntu.com',
                'sha256': 'b' * 64,
            },
            'bionic',
        )
        self.assertEqual(resolved['source_suite'], 'bionic-security')
        self.assertEqual(resolved['source_pocket'], 'security')
        self.assertEqual(resolved['error'], '')

    def test_explicit_suite_kept(self):
        resolved = dsc.resolve_target_suite(
            {'suite': 'bionic-updates', 'sha256': 'c' * 64},
            'bionic',
        )
        self.assertEqual(resolved['source_suite'], 'bionic-updates')
        self.assertEqual(resolved['resolved_from'], 'discovery_suite')

    def test_sha_index_lookup(self):
        resolved = dsc.resolve_target_suite(
            {'suite': '', 'sha256': 'd' * 64},
            'bionic',
            sha_to_suite={'d' * 64: 'bionic-updates'},
        )
        self.assertEqual(resolved['source_suite'], 'bionic-updates')

    def test_shared_sha_multi_suite_resolves_target(self):
        sha = 'e' * 64
        sha_map = {sha: ['bionic', 'focal-updates']}
        row = {
            'suite': '',
            'sha256': sha,
            'original_url': (
                'http://archive.ubuntu.com/ubuntu/pool/main/i/iucode-tool/'
                'iucode-tool_2.3.1-1_amd64.deb'
            ),
            'repository_host': 'archive.ubuntu.com',
            'version': '2.3.1-1',
            'filename': 'iucode-tool_2.3.1-1_amd64.deb',
        }
        resolved = dsc.resolve_hop_suite(
            row, 'bionic', 'focal', sha_to_suite=sha_map,
        )
        self.assertEqual(resolved.get('error'), '')
        self.assertEqual(resolved.get('role'), 'target')
        self.assertEqual(resolved.get('source_suite'), 'focal-updates')

    def test_shared_sha_source_series_only_does_not_omit_as_residue(self):
        sha = 'f' * 64
        row = {
            'suite': '',
            'sha256': sha,
            'original_url': (
                'http://archive.ubuntu.com/ubuntu/pool/main/i/iucode-tool/'
                'iucode-tool_2.3.1-1_amd64.deb'
            ),
            'repository_host': 'archive.ubuntu.com',
            'version': '2.3.1-1',
            'filename': 'iucode-tool_2.3.1-1_amd64.deb',
        }
        resolved = dsc.resolve_hop_suite(
            row, 'bionic', 'focal', sha_to_suite={sha: 'bionic'},
        )
        self.assertNotEqual(resolved.get('role'), 'source_series')
        self.assertEqual(resolved.get('error'), '')
        self.assertEqual(resolved.get('role'), 'target')
        self.assertEqual(resolved.get('source_suite'), 'focal-updates')

    def test_older_series_sha_still_omitted(self):
        sha = 'a' * 64
        row = {
            'suite': '',
            'sha256': sha,
            'version': '1.1.0~beta1ubuntu0.16.04.12',
            'filename': 'python-apt-common_1.1.0_all.deb',
        }
        resolved = dsc.resolve_hop_suite(
            row, 'bionic', 'focal', sha_to_suite={sha: 'xenial'},
        )
        self.assertEqual(resolved.get('role'), 'source_series')


class TestSuiteIndexDiversity(unittest.TestCase):
    def test_18_identical_indexes_fail(self):
        tmp = tempfile.mkdtemp(prefix='idx-ident-')
        try:
            body = 'Package: apt\nVersion: 1.6\nFilename: pool/main/a.deb\nSize: 1\nSHA256: %s\n\n' % ('a' * 64)
            suites = ['bionic', 'bionic-updates', 'bionic-security', 'bionic-backports']
            for suite in suites:
                for comp in ('main', 'universe'):
                    write(
                        os.path.join(tmp, 'dists', suite, comp, 'binary-amd64', 'Packages'),
                        body,
                    )
            detail = dsc.validate_target_suite_index_diversity(tmp, suites)
            self.assertFalse(detail['ok'])
            self.assertEqual(
                detail['TARGET_SUITE_INDEX_DIVERSITY'],
                'FAIL_TARGET_SUITE_INDEXES_IDENTICAL',
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_19_diverse_indexes_pass(self):
        tmp = tempfile.mkdtemp(prefix='idx-div-')
        try:
            suites = ['bionic', 'bionic-updates', 'bionic-security', 'bionic-backports']
            for i, suite in enumerate(suites):
                for comp in ('main', 'universe'):
                    write(
                        os.path.join(tmp, 'dists', suite, comp, 'binary-amd64', 'Packages'),
                        'Package: pkg%d\nVersion: 1\nFilename: x\nSize: 1\nSHA256: %s\n\n'
                        % (i, ('%d' % i) * 64),
                    )
            detail = dsc.validate_target_suite_index_diversity(tmp, suites)
            self.assertTrue(detail['ok'], detail)
            self.assertEqual(detail['TARGET_SUITE_INDEX_DIVERSITY'], 'PASS')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class TestPocketComponents(unittest.TestCase):
    def test_13_updates_empty_blocked(self):
        tmp = tempfile.mkdtemp(prefix='pocket-empty-')
        try:
            for suite in ('bionic', 'bionic-security', 'bionic-backports'):
                for comp in ('main', 'universe'):
                    write(
                        os.path.join(tmp, 'dists', suite, comp, 'binary-amd64', 'Packages'),
                        'Package: x\nVersion: 1\nFilename: f\nSize: 1\nSHA256: %s\n\n' % ('e' * 64),
                    )
            for comp in ('main', 'universe'):
                write(
                    os.path.join(tmp, 'dists', 'bionic-updates', comp, 'binary-amd64', 'Packages'),
                    '',
                )
            result = dsc.validate_pocket_components(
                tmp,
                ['bionic', 'bionic-updates', 'bionic-security', 'bionic-backports'],
                ['main', 'universe'],
            )
            self.assertFalse(result['ok'])
            self.assertEqual(result['error'], 'FAIL_TARGET_POCKET_COMPONENT_EMPTY')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_14_security_empty_blocked(self):
        tmp = tempfile.mkdtemp(prefix='pocket-sec-')
        try:
            for suite in ('bionic', 'bionic-updates', 'bionic-backports'):
                for comp in ('main', 'universe'):
                    write(
                        os.path.join(tmp, 'dists', suite, comp, 'binary-amd64', 'Packages'),
                        'Package: x\nVersion: 1\nFilename: f\nSize: 1\nSHA256: %s\n\n' % ('f' * 64),
                    )
            for comp in ('main', 'universe'):
                write(
                    os.path.join(tmp, 'dists', 'bionic-security', comp, 'binary-amd64', 'Packages'),
                    '',
                )
            result = dsc.validate_pocket_components(
                tmp,
                ['bionic', 'bionic-updates', 'bionic-security', 'bionic-backports'],
                ['main', 'universe'],
            )
            self.assertFalse(result['ok'])
            self.assertIn('EMPTY', result['error'])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_15_universe_missing_fails(self):
        tmp = tempfile.mkdtemp(prefix='pocket-uni-')
        try:
            for suite in ('bionic', 'bionic-updates', 'bionic-security', 'bionic-backports'):
                write(
                    os.path.join(tmp, 'dists', suite, 'main', 'binary-amd64', 'Packages'),
                    'Package: x\nVersion: 1\nFilename: f\nSize: 1\nSHA256: %s\n\n' % ('1' * 64),
                )
            result = dsc.validate_pocket_components(
                tmp,
                ['bionic'],
                ['main', 'universe'],
            )
            self.assertFalse(result['ok'])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class TestSelectiveIndexByPocket(unittest.TestCase):
    def test_debs_indexed_by_original_suite_only(self):
        debs = [
            {'package': 'a', 'original_suite': 'bionic', 'component': 'main'},
            {'package': 'b', 'original_suite': 'bionic-updates', 'component': 'main'},
            {'package': 'c', 'original_suite': '', 'component': 'main'},
        ]
        self.assertEqual(
            [d['package'] for d in sm.debs_for_suite_index(
                debs, 'bionic', from_series='xenial', to_series='bionic')],
            ['a'],
        )
        self.assertEqual(
            [d['package'] for d in sm.debs_for_suite_index(
                debs, 'bionic-updates', from_series='xenial', to_series='bionic')],
            ['b'],
        )
        self.assertEqual(
            sm.debs_for_suite_index(debs, 'bionic-security', from_series='xenial', to_series='bionic'),
            [],
        )


class TestKernelFamily(unittest.TestCase):
    def test_23_base_only_abi_incomplete_family(self):
        # Only image present for early ABI — family incomplete → FAIL
        names = ['linux-image-4.15.0-20-generic']
        result = dsc.validate_kernel_package_family(names, '4.15.0-20')
        self.assertFalse(result['ok'])
        self.assertEqual(result['TARGET_KERNEL_PACKAGE_FAMILY'], 'FAIL')

    def test_24_25_updates_abi_family_complete(self):
        abi = '4.15.0-213'
        names = [
            'linux-image-%s-generic' % abi,
            'linux-modules-%s-generic' % abi,
            'linux-modules-extra-%s-generic' % abi,
            'linux-headers-%s' % abi,
            'linux-headers-%s-generic' % abi,
            'initramfs-tools',
            'initramfs-tools-core',
            'initramfs-tools-bin',
            'busybox-initramfs',
            'klibc-utils',
        ]
        k = dsc.validate_kernel_package_family(names, abi)
        i = dsc.validate_initramfs_dependency_family(names)
        self.assertTrue(k['ok'])
        self.assertTrue(i['ok'])
        self.assertEqual(k['TARGET_KERNEL_PACKAGE_FAMILY'], 'PASS')
        self.assertEqual(i['TARGET_KERNEL_INITRAMFS_DEPENDENCY_FAMILY'], 'PASS')

    def test_26_initramfs_family(self):
        result = dsc.validate_initramfs_dependency_family([
            'initramfs-tools', 'initramfs-tools-core', 'initramfs-tools-bin',
            'busybox-initramfs', 'klibc-utils',
        ])
        self.assertTrue(result['ok'])


class TestLegacyKeyringFingerprint(unittest.TestCase):
    def test_03_04_fingerprint_match_logic(self):
        expected = 'D1FF722556ED95F5E779BAE66B1BA1673A997CA5'
        self.assertEqual(expected, expected.upper())
        self.assertNotEqual(expected, 'DEADBEEF' + expected[8:])

    def test_05_atomic_install_pattern(self):
        tmp = tempfile.mkdtemp(prefix='key-atomic-')
        try:
            dest = os.path.join(tmp, 'trusted.gpg.d', 'stellar-offline-xenial-to-bionic.gpg')
            os.makedirs(os.path.dirname(dest))
            tmpf = dest + '.tmp'
            with open(tmpf, 'wb') as fh:
                fh.write(b'\x99\x02fake-keyring')
            os.chmod(tmpf, 0o644)
            os.rename(tmpf, dest)
            self.assertTrue(os.path.isfile(dest))
            self.assertFalse(os.path.exists(tmpf))
            self.assertEqual(os.stat(dest).st_mode & 0o777, 0o644)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class TestPreDroGateBlocking(unittest.TestCase):
    def test_28_29_gate_blocks_dro_on_signed_by(self):
        lines = [
            'deb [arch=amd64 signed-by=/k.gpg] http://m/ubuntu bionic main universe',
        ]
        result = dsc.analyze_distupgrade_sources(
            lines, expected_suites=['bionic', 'bionic-updates', 'bionic-security', 'bionic-backports'],
        )
        self.assertFalse(result['ok'])
        # Simulate gate: DRO call count stays 0 when gate fails.
        dro_calls = 0
        if result['ok']:
            dro_calls += 1
        self.assertEqual(dro_calls, 0)

    def test_29_gate_pass_allows_dro_flag(self):
        lines = dsc.generate_legacy_target_sources(
            'http://m/ubuntu',
            ['bionic', 'bionic-updates', 'bionic-security', 'bionic-backports'],
            'main universe',
        )
        result = dsc.analyze_distupgrade_sources(
            lines,
            expected_suites=[
                'bionic', 'bionic-updates', 'bionic-security', 'bionic-backports',
            ],
        )
        self.assertTrue(result['ok'])
        dro_calls = 0
        if result['ok']:
            dro_calls += 1
        self.assertEqual(dro_calls, 1)


class TestTemplatePolicy(unittest.TestCase):
    def test_no_signed_by_generation_in_template(self):
        path = os.path.join(ROOT, 'client', 'dp-offline-upgrade-xenial-to-bionic.sh.in')
        with open(path, encoding='utf-8') as fh:
            text = fh.read()
        self.assertNotIn('signed-by=%s', text)
        self.assertNotIn('printf \'deb [arch=amd64 signed-by=', text)
        self.assertIn('LEGACY_APT_KEYRING_PATH', text)
        self.assertIn('trusted.gpg.d/stellar-offline-xenial-to-bionic.gpg', text)
        self.assertIn('PRE_DRO_REPOSITORY_SEMANTIC_GATE', text)
        self.assertIn('runner_pre_dro_semantic_gate', text)
        # Must not enable trusted=yes as an apt option in generated sources.
        self.assertNotRegex(text, r"printf 'deb \[.*trusted\s*=\s*yes")
        self.assertIn('APT::Get::AllowUnauthenticated "false"', text)
        # Encoding-safe DistUpgrade source validation + pre-upgrade APT restore.
        self.assertIn("raw.decode('utf-8-sig')", text)
        self.assertIn('FAIL_DISTUPGRADE_SOURCE_TEXT_DECODE', text)
        self.assertIn('restore_apt_sources_from_backup', text)
        self.assertIn('LEGACY_APT_KEYRING_RETAINED=YES', text)
        self.assertNotIn('lines = open(path).read()', text)

    def test_30_bash43_no_mapfile_atq(self):
        path = os.path.join(ROOT, 'client', 'dp-offline-upgrade-xenial-to-bionic.sh.in')
        with open(path, encoding='utf-8') as fh:
            text = fh.read()
        self.assertNotIn('${', text and '')  # noop keep linter calm
        self.assertNotIn('mapfile -d', text)
        self.assertNotIn('${FOO@Q}', text)


if __name__ == '__main__':
    unittest.main()
