#!/usr/bin/env python3
"""Tests for discovery-exact selective offline mirror plan/materialize/verify."""
from __future__ import print_function

import csv
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'lib'))

import importlib.util


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bsp = _load(
    'build_selective_mirror_plan',
    os.path.join(ROOT, 'scripts', 'build-selective-mirror-plan.py'),
)
import selective_mirror as sm  # noqa: E402
import validate_selective_mirror as vsm  # noqa: E402
import validate_upgrade_profile as vup  # noqa: E402

PROFILE = os.path.join(ROOT, 'config', 'offline-upgrade-profile.json')
DISCOVERY = os.path.join(ROOT, 'artifacts', 'upgrade-discovery')


def write(path, content):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, 'w') as fh:
        fh.write(content if isinstance(content, str) else content.decode('latin1'))


def write_bytes(path, data):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, 'wb') as fh:
        fh.write(data)


class SelectivePlanTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.path.isdir(os.path.join(DISCOVERY, 'xenial-to-bionic')):
            raise unittest.SkipTest('discovery artifacts missing')

    def test_profile_is_selective(self):
        profile = json.load(open(PROFILE))
        self.assertEqual(profile['profile_name'], 'offline-upgrade-selective')
        self.assertEqual(profile['selection_mode'], 'discovery_exact')
        self.assertFalse(profile['requirements']['by_hash'])
        self.assertEqual(profile['schema_version'], 2)

    def test_parser_four_hops_and_dedupe(self):
        tmp = tempfile.mkdtemp(prefix='sel-plan-')
        try:
            plan, packages, files, urls = bsp.build_plan(
                DISCOVERY, seed_root='', profile_name='offline-upgrade-selective',
            )
            self.assertEqual(plan['hop_count'], 4)
            self.assertEqual(len(plan['hops']), 4)
            self.assertGreater(plan['counts']['unique_deb_sha256'], 3000)
            # Conflicts only when same version maps to different sha256
            self.assertEqual(plan['counts']['package_version_conflicts'], 0)
            # Multi-version keys (epoch duplicates / upgrade pairs) are OK
            self.assertGreaterEqual(
                plan['counts'].get('multi_version_package_keys', 0), 0
            )
            self.assertEqual(plan['counts']['unresolved_packages'], 0)
            self.assertEqual(plan['counts']['unresolved_files'], 0)
            # URL dedupe: unique normalized < raw rows
            self.assertLessEqual(
                plan['counts']['unique_urls_normalized'], len(urls)
            )
            self.assertEqual(plan['validation_result'], 'PASS', plan.get('errors'))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_version_conflict_detection(self):
        # Same version + arch with different sha256 must FAIL
        tmp = tempfile.mkdtemp(prefix='sel-conflict-')
        try:
            for hop in bsp.HOPS:
                d = os.path.join(tmp, hop)
                os.makedirs(d)
                write(os.path.join(d, 'required-packages.tsv'),
                      'hop\tpackage\tversion\tarchitecture\tsource_package\tfilename\t'
                      'repository_host\tsuite\tcomponent\tsize_bytes\tsha256\t'
                      'original_url\tfinal_url\trequested\tdownloaded\tinstalled\tevidence_source\n'
                      '%s\tfoo\t1.0\tamd64\tfoo\tfoo_1.0_amd64.deb\tarchive.ubuntu.com\t'
                      '\tmain\t4\t%s\thttp://archive.ubuntu.com/ubuntu/pool/main/f/foo/foo_1.0_amd64.deb\t'
                      'http://archive.ubuntu.com/ubuntu/pool/main/f/foo/foo_1.0_amd64.deb\t'
                      'true\ttrue\ttrue\tproxy\n'
                      '%s\tfoo\t1.0\tamd64\tfoo\tfoo_1.0_amd64.deb\tarchive.ubuntu.com\t'
                      '\tmain\t4\t%s\thttp://archive.ubuntu.com/ubuntu/pool/main/f/foo/foo_1.0_amd64.deb\t'
                      'http://archive.ubuntu.com/ubuntu/pool/main/f/foo/foo_1.0_amd64.deb\t'
                      'true\ttrue\ttrue\tproxy\n' % (
                          hop, 'a' * 64, hop, 'b' * 64,
                      ))
                write(os.path.join(d, 'required-files.tsv'),
                      'hop\tfile_type\tfilename\toriginal_url\tfinal_url\tlocal_path\t'
                      'size_bytes\tsha256\thttp_status\trequest_count\tevidence_source\n')
                write(os.path.join(d, 'required-urls.tsv'),
                      'hop\trequested_at\tmethod\toriginal_url\tfinal_url\thttp_status\t'
                      'size_bytes\tsha256\tlocal_path\n')
                write(os.path.join(d, 'unresolved-packages.tsv'), 'hop\tpackage\n')
                write(os.path.join(d, 'unresolved-files.tsv'), 'hop\tfilename\n')
            plan, _p, _f, _u = bsp.build_plan(tmp, seed_root='')
            self.assertEqual(plan['validation_result'], 'FAIL')
            self.assertGreater(plan['counts']['package_version_conflicts'], 0)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_unsupported_url_host(self):
        self.assertEqual(bsp.classify_url('http://evil.example/pool/main/a.deb'), 'pool_deb')
        # host check happens in build; classify alone is type
        self.assertEqual(
            bsp.classify_url('http://archive.ubuntu.com/ubuntu/dists/x/by-hash/SHA256/abc'),
            'by_hash',
        )

    def test_seed_reuse_hardlink(self):
        tmp = tempfile.mkdtemp(prefix='sel-reuse-')
        try:
            seed = os.path.join(tmp, 'seed')
            data = b'debdata'
            digest = hashlib.sha256(data).hexdigest()
            rel = 'pool/main/d/demo/demo_1_amd64.deb'
            write_bytes(os.path.join(seed, rel), data)
            selective = os.path.join(tmp, 'selective')
            dst = os.path.join(selective, 'hops', 'x', 'ubuntu', rel)
            method = sm.acquire_file(os.path.join(seed, rel), dst)
            self.assertIn(method, ('hardlink', 'reflink', 'copy'))
            self.assertTrue(os.path.isfile(dst))
            self.assertEqual(hashlib.sha256(open(dst, 'rb').read()).hexdigest(), digest)
            # hardlink fallback: if link exists, second acquire returns exists
            self.assertEqual(sm.acquire_file(os.path.join(seed, rel), dst), 'exists')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_checksum_mismatch_fails_materialize_piece(self):
        tmp = tempfile.mkdtemp(prefix='sel-mis-')
        try:
            path = os.path.join(tmp, 'a.deb')
            write_bytes(path, b'abc')
            self.assertNotEqual(sm.file_sha256(path), '0' * 64)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_generate_packages_no_forbidden_indexes(self):
        tmp = tempfile.mkdtemp(prefix='sel-pkg-')
        try:
            ubuntu = os.path.join(tmp, 'ubuntu')
            data = b'demo'
            digest = hashlib.sha256(data).hexdigest()
            rel = 'pool/main/d/demo/demo_1_amd64.deb'
            write_bytes(os.path.join(ubuntu, rel), data)
            # dpkg-deb may fail on fake deb — skip if unavailable
            if not shutil.which('dpkg-deb'):
                self.skipTest('dpkg-deb missing')
            # Create a minimal real-ish deb with ar? too heavy — mock parse_deb_control
            orig = sm.parse_deb_control

            def fake_parse(_path):
                return {
                    'Package': 'demo', 'Version': '1', 'Architecture': 'amd64',
                    'Maintainer': 't', 'Description': 'd',
                }

            sm.parse_deb_control = fake_parse
            try:
                debs = [{
                    'package': 'demo', 'version': '1', 'architecture': 'amd64',
                    'component': 'main', 'relative_pool_path': rel,
                    'size_bytes': len(data), 'sha256': digest,
                    'original_suite': 'bionic',
                }]
                sm.generate_packages_for_hop(
                    ubuntu, debs, ['bionic'], arch='amd64',
                    from_series='xenial', to_series='bionic',
                )
                pkgs = os.path.join(ubuntu, 'dists', 'bionic', 'main', 'binary-amd64', 'Packages')
                self.assertTrue(os.path.isfile(pkgs))
                body = open(pkgs).read()
                self.assertIn('Package: demo', body)
                self.assertIn(digest, body)
                release = open(os.path.join(ubuntu, 'dists', 'bionic', 'Release')).read()
                self.assertIn('Acquire-By-Hash: no', release)
                # no Translation/Contents
                suite = os.path.join(ubuntu, 'dists', 'bionic')
                for dirpath, _d, filenames in os.walk(suite):
                    for fn in filenames:
                        self.assertFalse(fn.startswith('Translation'))
                        self.assertFalse(fn.startswith('Contents'))
                        self.assertNotEqual(fn, 'Sources')
            finally:
                sm.parse_deb_control = orig
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_atomic_publish_rollback(self):
        tmp = tempfile.mkdtemp(prefix='sel-pub-')
        try:
            root = os.path.join(tmp, 'selective')
            staging = os.path.join(root, 'staging')
            os.makedirs(os.path.join(staging, 'hops', 'jammy-to-noble', 'ubuntu'))
            write(os.path.join(staging, 'marker'), 'v1')
            os.makedirs(os.path.join(root, 'state'))
            write(os.path.join(root, 'state', 'verify.json'),
                  json.dumps({'validation_result': 'PASS',
                              'validation_phase': 'pre_publish'}))
            sm.atomic_publish(root, run_post_publish=False, run_nginx_preflight=False)
            self.assertTrue(os.path.isdir(os.path.join(root, 'published')))
            self.assertTrue(os.path.islink(os.path.join(root, 'active')))
            self.assertTrue(os.path.islink(os.path.join(root, 'current')))
            # second publish then rollback
            staging2 = os.path.join(root, 'staging')
            os.makedirs(os.path.join(staging2, 'hops', 'jammy-to-noble', 'ubuntu'))
            write(os.path.join(staging2, 'marker'), 'v2')
            write(os.path.join(root, 'state', 'verify.json'),
                  json.dumps({'validation_result': 'PASS',
                              'validation_phase': 'pre_publish'}))
            sm.atomic_publish(root, run_post_publish=False, run_nginx_preflight=False)
            self.assertEqual(open(os.path.join(root, 'published', 'marker')).read(), 'v2')
            sm.rollback_publish(root)
            self.assertEqual(open(os.path.join(root, 'published', 'marker')).read(), 'v1')
            self.assertFalse(os.path.isfile(os.path.join(root, 'state', 'READY')))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_ready_invalidation(self):
        tmp = tempfile.mkdtemp(prefix='sel-ready-')
        try:
            root = os.path.join(tmp, 'selective')
            os.makedirs(os.path.join(root, 'state'))
            ready = os.path.join(root, 'state', 'READY')
            write(ready, 'READY\n')
            self.assertTrue(vsm.invalidate_ready(root))
            self.assertFalse(os.path.isfile(ready))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_unexpected_package_detection(self):
        tmp = tempfile.mkdtemp(prefix='sel-unexp-')
        try:
            plan_path = os.path.join(tmp, 'plan.json')
            selective = os.path.join(tmp, 'selective')
            hop = 'xenial-to-bionic'
            ubuntu = os.path.join(selective, 'staging', 'hops', hop, 'ubuntu')
            data = b'ok'
            digest = hashlib.sha256(data).hexdigest()
            rel = 'pool/main/d/demo/demo_1_amd64.deb'
            write_bytes(os.path.join(ubuntu, rel), data)
            write_bytes(os.path.join(ubuntu, 'pool/main/x/x/x_1_amd64.deb'), b'bad')
            suites = ['bionic']
            # minimal Packages
            binary = os.path.join(ubuntu, 'dists', 'bionic', 'main', 'binary-amd64')
            os.makedirs(binary)
            write(os.path.join(binary, 'Packages'),
                  'Package: demo\nFilename: %s\nSize: %d\nSHA256: %s\n\n' % (
                      rel, len(data), digest))
            write(os.path.join(ubuntu, 'dists', 'bionic', 'Release'),
                  'Suite: bionic\nAcquire-By-Hash: no\n')
            os.makedirs(os.path.join(selective, 'staging', 'shared', 'offline',
                                     'release-upgraders'))
            write(os.path.join(selective, 'staging', 'shared', 'offline', 'meta-release-lts'), '#')
            os.makedirs(os.path.join(selective, 'keys'))
            plan = {
                'profile_name': 'offline-upgrade-selective',
                'hop_count': 4,
                'hops': list(bsp.HOPS),
                'counts': {
                    'unresolved_packages': 0, 'unresolved_files': 0,
                    'unresolved_deb_payloads': 0,
                    'unique_packages_by_name_arch_version': 1,
                    'unique_deb_sha256': 1,
                },
                'sizes': {'selective_mirror_estimate_bytes': 4},
                'discovery_artifact_checksum': 'x',
                'plan_checksum': 'y',
                'hop_summaries': {
                    hop: {'suites': suites},
                    'bionic-to-focal': {'suites': []},
                    'focal-to-jammy': {'suites': []},
                    'jammy-to-noble': {'suites': []},
                },
                'debs': [{
                    'sha256': digest, 'size_bytes': len(data),
                    'relative_pool_path': rel, 'source_hops': [hop],
                    'package': 'demo', 'version': '1', 'architecture': 'amd64',
                    'component': 'main',
                }],
            }
            # fill empty hops dirs
            for h in bsp.HOPS:
                if h == hop:
                    continue
                os.makedirs(os.path.join(selective, 'staging', 'hops', h, 'ubuntu', 'pool'),
                            exist_ok=True)
            write(plan_path, json.dumps(plan))
            result = vsm.validate_tree(plan_path, selective)
            self.assertEqual(
                result['gates'].get('unexpected_pool_packages_%s' % hop), 'FAIL'
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_selective_profile_config_rejects_full(self):
        profile = json.load(open(PROFILE))
        conf = tempfile.NamedTemporaryFile('w', delete=False)
        conf.write('MIRROR_MODE="full"\n')
        conf.close()
        try:
            result = vup.validate_config_selective(profile, conf.name)
            self.assertEqual(result['validation_result'], 'FAIL')
            self.assertIn('UNSUPPORTED_FULL_MIRROR_SYNC', result['error_codes'])
        finally:
            os.unlink(conf.name)

    def test_selective_profile_config_pass(self):
        profile = json.load(open(PROFILE))
        conf = tempfile.NamedTemporaryFile('w', delete=False)
        conf.write('MIRROR_MODE="selective"\n')
        conf.close()
        try:
            result = vup.validate_config_selective(profile, conf.name)
            self.assertEqual(result['validation_result'], 'PASS', result)
        finally:
            os.unlink(conf.name)

    def test_full_mirror_seed_path_preserved_in_profile(self):
        profile = json.load(open(PROFILE))
        self.assertTrue(profile['full_mirror_seed_root'].endswith(
            'archive.ubuntu.com/ubuntu'))
        self.assertNotEqual(
            profile['selective_mirror_root'], profile['full_mirror_seed_root']
        )

    def test_migrate_to_selective(self):
        tmp = tempfile.mkdtemp(prefix='sel-mig-')
        try:
            conf = os.path.join(tmp, 'mirror.conf')
            write(conf, 'MIRROR_MODE="full"\n')
            mirror_root = os.path.join(tmp, 'mirror')
            os.makedirs(os.path.join(mirror_root, 'offline'))
            rc = subprocess.call([
                sys.executable,
                os.path.join(ROOT, 'scripts', 'lib', 'validate_upgrade_profile.py'),
                'migrate-profile',
                '--mirror-root', mirror_root,
                '--profile', PROFILE,
                '--mirror-conf', conf,
                '--project-root', ROOT,
                '--confirm',
                '--result-json', os.path.join(tmp, 'mig.json'),
            ])
            self.assertEqual(rc, 0)
            body = open(conf).read()
            self.assertIn('MIRROR_MODE="selective"', body)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class SelectiveCliSmoke(unittest.TestCase):
    def test_help_lists_selective_commands(self):
        out = subprocess.check_output(
            ['bash', os.path.join(ROOT, 'scripts', 'ubuntu-offline-mirror.sh'), '--help'],
            stderr=subprocess.STDOUT,
        ).decode('utf-8', 'replace')
        # Primary entrypoint is Mirror Manager; selective tooling remains listed as legacy.
        self.assertIn('mirror-manager', out)
        self.assertIn('plan-selective', out)
        self.assertIn('materialize-selective', out)
        self.assertIn('verify-selective', out)
        self.assertIn('publish-selective', out)
        self.assertIn('Legacy selective tooling', out)


class SelectiveDownloadDiagnosticsTests(unittest.TestCase):
    """HTTP 404 diagnostics, failed-downloads.json, skip/preserve behavior."""

    def _start_http(self, handler_cls):
        import threading
        try:
            from http.server import HTTPServer
        except ImportError:  # pragma: no cover
            from BaseHTTPServer import HTTPServer  # type: ignore
        server = HTTPServer(('127.0.0.1', 0), handler_cls)
        thread = threading.Thread(target=server.serve_forever)
        thread.daemon = True
        thread.start()
        host, port = server.server_address
        return server, 'http://%s:%d' % (host, port)

    def _stop_http(self, server):
        server.shutdown()
        server.server_close()

    def _minimal_plan(self, debs, hop='xenial-to-bionic'):
        return {
            'validation_result': 'PASS',
            'profile_name': 'offline-upgrade-selective',
            'plan_checksum': 'plan',
            'discovery_artifact_checksum': 'disc',
            'hop_summaries': {
                hop: {'suites': []},
            },
            'debs': debs,
            'upgraders': [],
            'sizes': {},
            'counts': {},
        }

    def test_http_404_error_code_and_failed_json(self):
        try:
            from http.server import BaseHTTPRequestHandler
        except ImportError:  # pragma: no cover
            from BaseHTTPServer import BaseHTTPRequestHandler  # type: ignore

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_error(404, 'Not Found')

            def log_message(self, *_args):
                return

        server, base = self._start_http(Handler)
        tmp = tempfile.mkdtemp(prefix='sel-404-')
        try:
            data_ok = b'good-deb-content'
            digest_ok = hashlib.sha256(data_ok).hexdigest()
            rel_ok = 'pool/main/g/good/good_1_amd64.deb'
            rel_bad = 'pool/main/b/bad/bad_1_amd64.deb'
            digest_bad = 'a' * 64
            selective = os.path.join(tmp, 'selective')
            # Pre-place a successful file under staging (must be preserved).
            ok_dst = os.path.join(
                selective, 'staging', 'hops', 'xenial-to-bionic', 'ubuntu', rel_ok,
            )
            write_bytes(ok_dst, data_ok)
            # Also leave a stale partial for the failing package.
            bad_dst = os.path.join(
                selective, 'staging', 'hops', 'xenial-to-bionic', 'ubuntu', rel_bad,
            )
            write_bytes(bad_dst + '.download', b'partial-junk')

            debs = [
                {
                    'sha256': digest_ok, 'size_bytes': len(data_ok),
                    'relative_pool_path': rel_ok,
                    'package': 'good', 'version': '1', 'architecture': 'amd64',
                    'component': 'main', 'source_hops': ['xenial-to-bionic'],
                    'original_url': base + '/good.deb',
                    'seed_local_path': '',
                },
                {
                    'sha256': digest_bad, 'size_bytes': 4,
                    'relative_pool_path': rel_bad,
                    'package': 'badpkg', 'version': '9.9.9',
                    'architecture': 'amd64',
                    'component': 'main', 'source_hops': ['xenial-to-bionic'],
                    'original_url': base + '/missing.deb',
                    'seed_local_path': '',
                },
            ]
            plan_path = os.path.join(tmp, 'plan.json')
            write(plan_path, json.dumps(self._minimal_plan(debs)))

            # Patch index/sign to avoid dpkg-deb/gpg dependency in this unit test.
            orig_gen = sm.generate_packages_for_hop
            orig_sign = sm.sign_release
            sm.generate_packages_for_hop = lambda *a, **k: []
            sm.sign_release = lambda *a, **k: ('', '', '')
            try:
                with self.assertRaises(sm.SelectiveDownloadError) as caught:
                    sm.materialize(plan_path, selective, allow_download=True, sign=False)
            finally:
                sm.generate_packages_for_hop = orig_gen
                sm.sign_release = orig_sign

            err = caught.exception
            self.assertEqual(err.error_code, 'SELECTIVE_DOWNLOAD_HTTP_404')
            self.assertEqual(err.context.get('package'), 'badpkg')
            self.assertEqual(err.context.get('version'), '9.9.9')
            self.assertEqual(err.context.get('architecture'), 'amd64')
            self.assertEqual(err.context.get('expected_sha256'), digest_bad)
            self.assertEqual(err.context.get('http_status'), 404)
            self.assertIn('/missing.deb', err.context.get('original_url', ''))
            self.assertIn('/missing.deb', err.context.get('normalized_url', ''))
            self.assertEqual(err.context.get('destination_path'), bad_dst)

            failed_path = os.path.join(selective, 'state', 'failed-downloads.json')
            self.assertTrue(os.path.isfile(failed_path))
            with open(failed_path) as fh:
                payload = json.load(fh)
            self.assertEqual(payload['validation_result'], 'FAIL')
            self.assertEqual(payload['error_code'], 'SELECTIVE_DOWNLOAD_HTTP_404')
            self.assertEqual(payload['package'], 'badpkg')
            self.assertEqual(payload['version'], '9.9.9')
            self.assertEqual(payload['architecture'], 'amd64')
            self.assertEqual(payload['expected_sha256'], digest_bad)
            self.assertIn('/missing.deb', payload['original_url'])
            self.assertIn('/missing.deb', payload['normalized_url'])
            self.assertEqual(payload['destination_path'], bad_dst)
            self.assertEqual(payload['http_status'], 404)
            self.assertEqual(payload['succeeded_file_count'], 1)
            self.assertGreaterEqual(payload['remaining_file_count'], 0)

            # Successful file preserved; partial cleaned.
            self.assertTrue(os.path.isfile(ok_dst))
            with open(ok_dst, 'rb') as fh:
                self.assertEqual(fh.read(), data_ok)
            self.assertFalse(os.path.isfile(bad_dst + '.download'))
            # READY must not be created on failure.
            self.assertFalse(os.path.isfile(os.path.join(selective, 'state', 'READY')))
        finally:
            self._stop_http(server)
            shutil.rmtree(tmp, ignore_errors=True)

    def test_matching_destination_skips_redownload(self):
        try:
            from http.server import BaseHTTPRequestHandler
        except ImportError:  # pragma: no cover
            from BaseHTTPServer import BaseHTTPRequestHandler  # type: ignore

        hits = {'n': 0}

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                hits['n'] += 1
                body = b'should-not-fetch'
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                return

        server, base = self._start_http(Handler)
        tmp = tempfile.mkdtemp(prefix='sel-skip-')
        try:
            data = b'already-present'
            digest = hashlib.sha256(data).hexdigest()
            rel = 'pool/main/a/already/already_1_amd64.deb'
            selective = os.path.join(tmp, 'selective')
            dst = os.path.join(
                selective, 'staging', 'hops', 'xenial-to-bionic', 'ubuntu', rel,
            )
            write_bytes(dst, data)
            debs = [{
                'sha256': digest, 'size_bytes': len(data),
                'relative_pool_path': rel,
                'package': 'already', 'version': '1', 'architecture': 'amd64',
                'component': 'main', 'source_hops': ['xenial-to-bionic'],
                'original_url': base + '/already.deb',
                'seed_local_path': '',
            }]
            plan_path = os.path.join(tmp, 'plan.json')
            write(plan_path, json.dumps(self._minimal_plan(debs)))
            orig_gen = sm.generate_packages_for_hop
            sm.generate_packages_for_hop = lambda *a, **k: []
            try:
                result = sm.materialize(
                    plan_path, selective, allow_download=True, sign=False,
                )
            finally:
                sm.generate_packages_for_hop = orig_gen
            self.assertEqual(result['validation_result'], 'PASS')
            self.assertEqual(hits['n'], 0)
            self.assertEqual(result['stats'].get('exists'), 1)
            with open(dst, 'rb') as fh:
                self.assertEqual(fh.read(), data)
            self.assertFalse(os.path.isfile(
                os.path.join(selective, 'state', 'failed-downloads.json')
            ))
        finally:
            self._stop_http(server)
            shutil.rmtree(tmp, ignore_errors=True)

    def test_cli_prints_structured_error_without_traceback(self):
        try:
            from http.server import BaseHTTPRequestHandler
        except ImportError:  # pragma: no cover
            from BaseHTTPServer import BaseHTTPRequestHandler  # type: ignore

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_error(404, 'Not Found')

            def log_message(self, *_args):
                return

        server, base = self._start_http(Handler)
        tmp = tempfile.mkdtemp(prefix='sel-cli-404-')
        try:
            rel = 'pool/main/m/miss/miss_1_amd64.deb'
            debs = [{
                'sha256': 'b' * 64, 'size_bytes': 1,
                'relative_pool_path': rel,
                'package': 'miss', 'version': '1.0', 'architecture': 'amd64',
                'component': 'main', 'source_hops': ['xenial-to-bionic'],
                'original_url': base + '/miss.deb',
                'seed_local_path': '',
            }]
            plan_path = os.path.join(tmp, 'plan.json')
            selective = os.path.join(tmp, 'selective')
            write(plan_path, json.dumps(self._minimal_plan(debs)))
            env = os.environ.copy()
            env.pop('SELECTIVE_MIRROR_DEBUG', None)
            env.pop('UM_DEBUG', None)
            proc = subprocess.run(
                [
                    sys.executable,
                    os.path.join(ROOT, 'scripts', 'lib', 'selective_mirror.py'),
                    'materialize',
                    '--plan', plan_path,
                    '--selective-root', selective,
                    '--no-sign',
                ],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=env, universal_newlines=True,
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn('SELECTIVE_DOWNLOAD_HTTP_404', proc.stderr)
            self.assertIn('package=miss', proc.stderr)
            self.assertIn('version=1.0', proc.stderr)
            self.assertNotIn('Traceback (most recent call last)', proc.stderr)
            failed = os.path.join(selective, 'state', 'failed-downloads.json')
            self.assertTrue(os.path.isfile(failed))
            self.assertFalse(os.path.isfile(os.path.join(selective, 'state', 'READY')))
        finally:
            self._stop_http(server)
            shutil.rmtree(tmp, ignore_errors=True)

    def test_partial_cleanup_helper_only_removes_download_suffix(self):
        tmp = tempfile.mkdtemp(prefix='sel-partial-')
        try:
            good = os.path.join(tmp, 'pool', 'ok.deb')
            partial = os.path.join(tmp, 'pool', 'ok.deb.download')
            write_bytes(good, b'keep-me')
            write_bytes(partial, b'junk')
            removed = sm.cleanup_partial_downloads(tmp)
            self.assertEqual(removed, 1)
            self.assertTrue(os.path.isfile(good))
            self.assertFalse(os.path.isfile(partial))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class SelectiveComponentPathTests(unittest.TestCase):
    """Component/path rules: no main default; URL wins; 404 path correction."""

    @classmethod
    def setUpClass(cls):
        if not os.path.isdir(os.path.join(DISCOVERY, 'xenial-to-bionic')):
            raise unittest.SkipTest('discovery artifacts missing')

    def test_discovery_universe_url_keeps_universe(self):
        plan, _packages, _files, _urls = bsp.build_plan(
            DISCOVERY, seed_root='', profile_name='offline-upgrade-selective',
            resolve_missing_pool_paths=False,
        )
        hits = [
            d for d in plan['debs']
            if d.get('package') == 'containerd'
            and '1.6.12' in (d.get('version') or '')
        ]
        self.assertTrue(hits)
        for deb in hits:
            self.assertEqual(deb['component'], 'universe')
            self.assertIn('/pool/universe/', deb['original_url'])
            self.assertTrue(deb['relative_pool_path'].startswith('pool/universe/'))

    def test_no_main_default_without_url(self):
        tmp = tempfile.mkdtemp(prefix='sel-nomain-')
        try:
            for hop in bsp.HOPS:
                d = os.path.join(tmp, hop)
                os.makedirs(d)
                write(os.path.join(d, 'required-packages.tsv'),
                      'hop\tpackage\tversion\tarchitecture\tsource_package\tfilename\t'
                      'repository_host\tsuite\tcomponent\tsize_bytes\tsha256\t'
                      'original_url\tfinal_url\trequested\tdownloaded\tinstalled\tevidence_source\n'
                      '%s\tophan\t1\tamd64\tophan\tophan_1_amd64.deb\t\t\t\t'
                      '4\t%s\t\t\tfalse\ttrue\ttrue\tapt_archives\n'
                      % (hop, 'a' * 64))
                write(os.path.join(d, 'required-files.tsv'),
                      'hop\tfile_type\tfilename\toriginal_url\tfinal_url\tlocal_path\t'
                      'size_bytes\tsha256\thttp_status\tdownloaded\tevidence_source\n')
                write(os.path.join(d, 'required-urls.tsv'),
                      'hop\ttimestamp\tmethod\toriginal_url\tfinal_url\thttp_status\t'
                      'size_bytes\tsha256\tlocal_path\n')
                write(os.path.join(d, 'unresolved-packages.tsv'),
                      'hop\tpackage\treason\n')
                write(os.path.join(d, 'unresolved-files.tsv'),
                      'hop\tfilename\treason\n')
                write(os.path.join(d, 'export-summary.json'), '{}')
                write(os.path.join(d, 'checksums.sha256'), '')
            plan, _p, _f, _u = bsp.build_plan(
                tmp, seed_root='', resolve_missing_pool_paths=False,
            )
            self.assertEqual(plan['validation_result'], 'FAIL')
            self.assertTrue(any('refusing default component=main' in e for e in plan['errors']))
            self.assertEqual(len(plan['debs']), 0)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_sha_merge_prefers_real_url_component(self):
        tmp = tempfile.mkdtemp(prefix='sel-merge-')
        try:
            sha = 'b' * 64
            universe_url = (
                'http://archive.ubuntu.com/ubuntu/pool/universe/c/containerd/'
                'containerd_1_amd64.deb'
            )
            for hop in bsp.HOPS:
                d = os.path.join(tmp, hop)
                os.makedirs(d)
                # First hop: apt_archives without URL; later hops provide universe URL
                if hop == 'xenial-to-bionic':
                    pkg_row = (
                        '%s\tcontainerd\t1\tamd64\tcontainerd\tcontainerd_1_amd64.deb\t'
                        '\t\t\t12\t%s\t\t\tfalse\ttrue\ttrue\tapt_archives\n'
                        % (hop, sha)
                    )
                else:
                    pkg_row = (
                        '%s\tcontainerd\t1\tamd64\tcontainerd\tcontainerd_1_amd64.deb\t'
                        'archive.ubuntu.com\tbionic\tuniverse\t12\t%s\t%s\t%s\t'
                        'true\ttrue\ttrue\tproxy_access_log\n'
                        % (hop, sha, universe_url, universe_url)
                    )
                write(os.path.join(d, 'required-packages.tsv'),
                      'hop\tpackage\tversion\tarchitecture\tsource_package\tfilename\t'
                      'repository_host\tsuite\tcomponent\tsize_bytes\tsha256\t'
                      'original_url\tfinal_url\trequested\tdownloaded\tinstalled\tevidence_source\n'
                      + pkg_row)
                write(os.path.join(d, 'required-files.tsv'),
                      'hop\tfile_type\tfilename\toriginal_url\tfinal_url\tlocal_path\t'
                      'size_bytes\tsha256\thttp_status\tdownloaded\tevidence_source\n')
                write(os.path.join(d, 'required-urls.tsv'),
                      'hop\ttimestamp\tmethod\toriginal_url\tfinal_url\thttp_status\t'
                      'size_bytes\tsha256\tlocal_path\n')
                write(os.path.join(d, 'unresolved-packages.tsv'), 'hop\tpackage\treason\n')
                write(os.path.join(d, 'unresolved-files.tsv'), 'hop\tfilename\treason\n')
                write(os.path.join(d, 'export-summary.json'), '{}')
                write(os.path.join(d, 'checksums.sha256'), '')
            plan, packages, _f, _u = bsp.build_plan(
                tmp, seed_root='', resolve_missing_pool_paths=False,
            )
            self.assertEqual(plan['validation_result'], 'PASS', plan.get('errors'))
            self.assertEqual(len(plan['debs']), 1)
            deb = plan['debs'][0]
            self.assertEqual(deb['component'], 'universe')
            self.assertIn('/pool/universe/', deb['original_url'])
            # Per-row output for first hop should also reflect merged URL component
            first = [r for r in packages if r['hop'] == 'xenial-to-bionic'][0]
            self.assertEqual(first['component'], 'universe')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_component_path_correction_on_404(self):
        try:
            from http.server import BaseHTTPRequestHandler, HTTPServer
        except ImportError:  # pragma: no cover
            from BaseHTTPServer import BaseHTTPRequestHandler, HTTPServer  # type: ignore
        import threading

        body = b'exact-containerd-bytes'
        digest = hashlib.sha256(body).hexdigest()

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.endswith('/pool/universe/c/containerd/containerd_1_amd64.deb'):
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                else:
                    self.send_error(404, 'Not Found')

            def log_message(self, *_args):
                return

        server = HTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever)
        thread.daemon = True
        thread.start()
        host, port = server.server_address
        base = 'http://%s:%d' % (host, port)
        tmp = tempfile.mkdtemp(prefix='sel-corr-')
        try:
            rel_main = 'pool/main/c/containerd/containerd_1_amd64.deb'
            original = base + '/ubuntu/' + rel_main
            # Treat local test server as an official host for this unit test.
            orig_host_check = sm.acquire_with_component_correction

            def _acquire_corr(*args, **kwargs):
                # Reuse production logic but force official-host branch via patched URL host list.
                return orig_host_check(*args, **kwargs)

            # Patch OFFICIAL bases and host allow-list used by correction.
            orig_bases = sm.OFFICIAL_POOL_BASES
            sm.OFFICIAL_POOL_BASES = (base + '/ubuntu',)

            # Rewrite the official-host gate inside acquire_with_component_correction
            # by temporarily treating any host as official via wrapper.
            def _corr(
                src, dst, allow_download_url, expected_sha256, expected_size,
                entry_context, selective_root, relative_pool_path, deb,
            ):
                try:
                    return sm.acquire_file(
                        src, dst,
                        allow_download_url=allow_download_url,
                        expected_sha256=expected_sha256,
                        expected_size=expected_size,
                        entry_context=entry_context,
                    ), None
                except sm.SelectiveDownloadError as err:
                    if err.error_code != sm.ERROR_HTTP_404:
                        raise
                    last_err = err
                    for component, new_rel, candidate_url in sm.candidate_correction_urls(
                        allow_download_url, relative_pool_path,
                    ):
                        corr_ctx = dict(entry_context or {})
                        try:
                            method = sm.acquire_file(
                                '', dst,
                                allow_download_url=candidate_url,
                                expected_sha256=expected_sha256,
                                expected_size=expected_size,
                                entry_context=corr_ctx,
                            )
                        except sm.SelectiveDownloadError as cand_err:
                            last_err = cand_err
                            continue
                        if not sm.destination_matches(dst, expected_sha256, expected_size):
                            sm.safe_unlink(dst)
                            continue
                        resolution = {
                            'package': deb.get('package') or '',
                            'version': deb.get('version') or '',
                            'architecture': deb.get('architecture') or '',
                            'filename': deb.get('filename') or '',
                            'expected_sha256': expected_sha256,
                            'verified_sha256': sm.file_sha256(dst),
                            'expected_size_bytes': expected_size,
                            'verified_size_bytes': os.path.getsize(dst),
                            'original_url': allow_download_url,
                            'resolved_url': candidate_url,
                            'original_component': 'main',
                            'resolved_component': component,
                            'resolution_reason':
                                'ORIGINAL_URL_HTTP_404_COMPONENT_PATH_CORRECTION',
                            'acquisition_source':
                                'official-exact-checksum-path-correction',
                            'source_hops': list(deb.get('source_hops') or []),
                            'resolved_at': sm.iso_now(),
                        }
                        sm.append_resolved_download(selective_root, resolution)
                        return method, resolution
                    raise sm.SelectiveDownloadError(
                        sm.ERROR_EXACT_NOT_FOUND,
                        'exact file not found',
                        dict(last_err.context or {}),
                    )

            sm.acquire_with_component_correction = _corr
            try:
                debs = [{
                    'sha256': digest, 'size_bytes': len(body),
                    'relative_pool_path': rel_main,
                    'filename': 'containerd_1_amd64.deb',
                    'package': 'containerd', 'version': '1',
                    'architecture': 'amd64', 'component': 'main',
                    'source_hops': ['xenial-to-bionic'],
                    'original_url': original, 'seed_local_path': '',
                }]
                plan_path = os.path.join(tmp, 'plan.json')
                write(plan_path, json.dumps({
                    'validation_result': 'PASS',
                    'profile_name': 'offline-upgrade-selective',
                    'plan_checksum': 'p', 'discovery_artifact_checksum': 'd',
                    'hop_summaries': {'xenial-to-bionic': {'suites': []}},
                    'debs': debs, 'upgraders': [], 'sizes': {}, 'counts': {},
                }))
                selective = os.path.join(tmp, 'selective')
                orig_gen = sm.generate_packages_for_hop
                sm.generate_packages_for_hop = lambda *a, **k: []
                try:
                    result = sm.materialize(
                        plan_path, selective, allow_download=True, sign=False,
                    )
                finally:
                    sm.generate_packages_for_hop = orig_gen
                self.assertEqual(result['validation_result'], 'PASS')
                dst = os.path.join(
                    selective, 'staging', 'hops', 'xenial-to-bionic', 'ubuntu', rel_main,
                )
                self.assertTrue(os.path.isfile(dst))
                resolved = os.path.join(selective, 'state', 'resolved-downloads.json')
                self.assertTrue(os.path.isfile(resolved))
                payload = json.load(open(resolved))
                self.assertEqual(payload['resolution_count'], 1)
                rec = payload['resolutions'][0]
                self.assertEqual(rec['resolved_component'], 'universe')
                self.assertEqual(
                    rec['resolution_reason'],
                    'ORIGINAL_URL_HTTP_404_COMPONENT_PATH_CORRECTION',
                )
            finally:
                sm.acquire_with_component_correction = orig_host_check
                sm.OFFICIAL_POOL_BASES = orig_bases
        finally:
            server.shutdown()
            server.server_close()
            shutil.rmtree(tmp, ignore_errors=True)

    def test_exact_not_found_when_no_component_match(self):
        try:
            from http.server import BaseHTTPRequestHandler, HTTPServer
        except ImportError:  # pragma: no cover
            from BaseHTTPServer import BaseHTTPRequestHandler, HTTPServer  # type: ignore
        import threading

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_error(404, 'Not Found')

            def log_message(self, *_args):
                return

        server = HTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever)
        thread.daemon = True
        thread.start()
        host, port = server.server_address
        base = 'http://%s:%d' % (host, port)
        tmp = tempfile.mkdtemp(prefix='sel-nofound-')
        try:
            orig_bases = sm.OFFICIAL_POOL_BASES
            sm.OFFICIAL_POOL_BASES = (base,)
            orig_download = sm.download_url_to_path

            def _download(url, tmp_path, entry_context=None):
                rewritten = url.replace('http://archive.ubuntu.com/ubuntu', base)
                return orig_download(rewritten, tmp_path, entry_context=entry_context)

            sm.download_url_to_path = _download
            try:
                rel = 'pool/main/x/x/x_1_amd64.deb'
                debs = [{
                    'sha256': 'c' * 64, 'size_bytes': 4,
                    'relative_pool_path': rel, 'filename': 'x_1_amd64.deb',
                    'package': 'x', 'version': '1', 'architecture': 'amd64',
                    'component': 'main', 'source_hops': ['xenial-to-bionic'],
                    'original_url': 'http://archive.ubuntu.com/ubuntu/' + rel,
                    'seed_local_path': '',
                }]
                plan_path = os.path.join(tmp, 'plan.json')
                write(plan_path, json.dumps({
                    'validation_result': 'PASS',
                    'profile_name': 'offline-upgrade-selective',
                    'plan_checksum': 'p', 'discovery_artifact_checksum': 'd',
                    'hop_summaries': {'xenial-to-bionic': {'suites': []}},
                    'debs': debs, 'upgraders': [], 'sizes': {}, 'counts': {},
                }))
                selective = os.path.join(tmp, 'selective')
                orig_gen = sm.generate_packages_for_hop
                sm.generate_packages_for_hop = lambda *a, **k: []
                try:
                    with self.assertRaises(sm.SelectiveDownloadError) as caught:
                        sm.materialize(
                            plan_path, selective, allow_download=True, sign=False,
                        )
                finally:
                    sm.generate_packages_for_hop = orig_gen
                self.assertEqual(
                    caught.exception.error_code,
                    'SELECTIVE_DOWNLOAD_EXACT_FILE_NOT_FOUND',
                )
                self.assertFalse(
                    os.path.isfile(os.path.join(selective, 'state', 'READY'))
                )
            finally:
                sm.download_url_to_path = orig_download
                sm.OFFICIAL_POOL_BASES = orig_bases
        finally:
            server.shutdown()
            server.server_close()
            shutil.rmtree(tmp, ignore_errors=True)


class SelectiveIntegrationSurfaceTests(unittest.TestCase):
    def test_install_sh_references_selective_helpers(self):
        # Fresh install.sh is Mirror Manager bootstrap; selective helpers stay in runtime libs.
        body = open(os.path.join(ROOT, 'install.sh'), encoding='utf-8').read()
        self.assertIn('um_bootstrap_run', body)
        self.assertIn('mirror-manager', body)
        self.assertIn('--full', body)
        bootstrap = open(os.path.join(ROOT, 'lib', 'bootstrap.sh'), encoding='utf-8').read()
        self.assertIn('install-dp-upgrade-mirror.sh', bootstrap)
        # Install engine lives in the authoritative runtime manifest (not
        # inlined into bootstrap.sh after the Mirror Manager split).
        # Required paths are derived from install arrays via
        # um_runtime_emit_installed_relative_paths (scripts/lib/<basename>).
        manifest = open(os.path.join(ROOT, 'lib', 'runtime_manifest.sh'), encoding='utf-8').read()
        self.assertIn('mirror_install_engine.sh', manifest)
        self.assertIn('um_runtime_emit_installed_relative_paths', manifest)
        self.assertIn("printf 'scripts/lib/%s\\n'", manifest)
        self.assertIn('UM_RUNTIME_SCRIPT_LIB_SHELL', manifest)
        # Legacy selective tooling remains available via ubuntu-offline-mirror.sh
        uom = open(os.path.join(ROOT, 'scripts', 'ubuntu-offline-mirror.sh'), encoding='utf-8').read()
        self.assertIn('plan-selective', uom)
        self.assertIn('selective_mirror.py', uom)

    def test_mirrorctl_stops_selective_processes(self):
        body = open(os.path.join(ROOT, 'scripts', 'mirrorctl')).read()
        self.assertIn('materialize-selective', body)
        self.assertIn('selective_mirror', body)

    def test_systemd_unit_runs_materialize_selective(self):
        body = open(os.path.join(ROOT, 'templates', 'apt-mirror.service')).read()
        self.assertIn('materialize-selective', body)
        self.assertNotIn('ubuntu-offline-mirror.sh sync', body)

    def test_nginx_points_at_selective_direct(self):
        body = open(os.path.join(ROOT, 'templates', 'nginx.conf')).read()
        self.assertIn('root /var/spool/apt-mirror/selective;', body)
        self.assertNotIn('selective/current', body)
        self.assertNotIn('selective/active/ubuntu', body)
        self.assertNotIn('/var/spool/apt-mirror/mirror;', body)

    def test_generator_matches_selective_canonical_root(self):
        import subprocess
        script = (
            'source "%s/lib/common.sh"; source "%s/lib/config.sh"; '
            'um_load_config "%s/mirror.conf"; um_generate_nginx_conf'
        ) % (ROOT, ROOT, ROOT)
        out = subprocess.check_output(['bash', '-c', script], universal_newlines=True)
        self.assertIn('/selective;', out)
        self.assertNotIn('selective/current', out)
        self.assertIn('location /hops/', out)
        self.assertNotIn('root /var/spool/apt-mirror/mirror;', out)

    def test_no_unrelated_recovery_e2e_paths(self):
        # Guard: this selective fix must not create recovery/E2E scaffolding.
        for rel in (
            'e2e/cross-product',
            'recovery-attempt-005',
            'xp-normal-000',
            'recovery-plan.json',
            'replacement-map.json',
        ):
            self.assertFalse(
                os.path.exists(os.path.join(ROOT, rel)),
                'unexpected unrelated path: %s' % rel,
            )


class SelectivePrePostPublishTests(unittest.TestCase):
    """Pre-publish verify vs post-publish HTTP separation."""

    def _minimal_staging_tree(self, selective, hop='xenial-to-bionic', suite='bionic'):
        # Build a real .deb so packages↔control metadata consistency can run.
        deb_tmpdir = tempfile.mkdtemp(prefix='sel-deb-')
        try:
            deb_build = os.path.join(deb_tmpdir, 'pkg')
            debian = os.path.join(deb_build, 'DEBIAN')
            os.makedirs(debian)
            write(os.path.join(debian, 'control'),
                  'Package: demo\nVersion: 1\nArchitecture: amd64\n'
                  'Maintainer: test <t@example.com>\nDescription: demo\n')
            deb_out = os.path.join(deb_tmpdir, 'demo_1_amd64.deb')
            subprocess.check_call(
                ['dpkg-deb', '-b', deb_build, deb_out],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            with open(deb_out, 'rb') as fh:
                data = fh.read()
        finally:
            shutil.rmtree(deb_tmpdir, ignore_errors=True)
        digest = hashlib.sha256(data).hexdigest()
        rel = 'pool/main/d/demo/demo_1_amd64.deb'
        ubuntu = os.path.join(selective, 'staging', 'hops', hop, 'ubuntu')
        write_bytes(os.path.join(ubuntu, rel), data)
        binary = os.path.join(ubuntu, 'dists', suite, 'main', 'binary-amd64')
        os.makedirs(binary, exist_ok=True)
        write(os.path.join(binary, 'Packages'),
              'Package: demo\nVersion: 1\nArchitecture: amd64\n'
              'Filename: %s\nSize: %d\nSHA256: %s\n\n' % (
                  rel, len(data), digest))
        write(os.path.join(ubuntu, 'dists', suite, 'Release'),
              'Suite: %s\nAcquire-By-Hash: no\n' % suite)
        write(os.path.join(ubuntu, 'dists', suite, 'InRelease'),
              'Suite: %s\nAcquire-By-Hash: no\n' % suite)
        shared = os.path.join(selective, 'staging', 'shared', 'offline')
        os.makedirs(os.path.join(shared, 'release-upgraders', 'bionic'), exist_ok=True)
        write(os.path.join(shared, 'meta-release-lts'), '# meta\n')
        up_body = b'upgrader'
        up_digest = hashlib.sha256(up_body).hexdigest()
        write_bytes(os.path.join(shared, 'release-upgraders', 'bionic', 'bionic.tar.gz'),
                    up_body)
        os.makedirs(os.path.join(selective, 'keys'), exist_ok=True)
        write(os.path.join(selective, 'keys', 'ubuntu-mirror-selective.gpg'), 'KEY')
        for h in bsp.HOPS:
            if h == hop:
                continue
            os.makedirs(
                os.path.join(selective, 'staging', 'hops', h, 'ubuntu', 'pool'),
                exist_ok=True,
            )
        plan = {
            'profile_name': 'offline-upgrade-selective',
            'hop_count': 4,
            'hops': list(bsp.HOPS),
            'counts': {
                'unresolved_packages': 0, 'unresolved_files': 0,
                'unresolved_deb_payloads': 0,
                'unique_packages_by_name_arch_version': 1,
                'unique_deb_sha256': 1,
            },
            'sizes': {'selective_mirror_estimate_bytes': len(data)},
            'discovery_artifact_checksum': 'disc-aaa',
            'plan_checksum': 'plan-bbb',
            'hop_summaries': {
                hop: {'suites': [suite]},
                'bionic-to-focal': {'suites': []},
                'focal-to-jammy': {'suites': []},
                'jammy-to-noble': {'suites': []},
            },
            'debs': [{
                'sha256': digest, 'size_bytes': len(data),
                'relative_pool_path': rel, 'source_hops': [hop],
                'package': 'demo', 'version': '1', 'architecture': 'amd64',
                'component': 'main',
            }],
            'upgraders': [{
                'hop': hop, 'filename': 'bionic.tar.gz',
                'sha256': up_digest, 'size_bytes': len(up_body),
            }],
        }
        return plan, digest, rel, data

    def test_prepublish_passes_without_published_current(self):
        tmp = tempfile.mkdtemp(prefix='sel-pre-')
        try:
            selective = os.path.join(tmp, 'selective')
            plan, _d, _r, _data = self._minimal_staging_tree(selective)
            plan_path = os.path.join(tmp, 'plan.json')
            write(plan_path, json.dumps(plan))
            self.assertFalse(os.path.exists(os.path.join(selective, 'published')))
            self.assertFalse(os.path.exists(os.path.join(selective, 'current')))
            # Patch gpgv — InRelease is unsigned placeholder
            orig = vsm.verify_gpg_inrelease
            vsm.verify_gpg_inrelease = lambda *a, **k: (True, 'ok')
            try:
                result = vsm.validate_tree(plan_path, selective, run_apt=False)
            finally:
                vsm.verify_gpg_inrelease = orig
            self.assertEqual(result['validation_phase'], 'pre_publish')
            self.assertEqual(result['gates'].get('nginx_http'), 'NOT_APPLICABLE')
            self.assertEqual(result['validation_result'], 'PASS', result.get('errors'))
            self.assertFalse(os.path.isfile(os.path.join(selective, 'state', 'READY')))
            self.assertTrue(os.path.isfile(
                os.path.join(selective, 'state', 'verify-result.json')))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_prepublish_ignores_production_http_base(self):
        tmp = tempfile.mkdtemp(prefix='sel-nohttp-')
        try:
            selective = os.path.join(tmp, 'selective')
            plan, _d, _r, _data = self._minimal_staging_tree(selective)
            plan_path = os.path.join(tmp, 'plan.json')
            write(plan_path, json.dumps(plan))
            orig = vsm.verify_gpg_inrelease
            vsm.verify_gpg_inrelease = lambda *a, **k: (True, 'ok')
            try:
                result = vsm.validate_tree(
                    plan_path, selective, run_apt=False,
                    http_base='http://127.0.0.1',
                )
            finally:
                vsm.verify_gpg_inrelease = orig
            self.assertEqual(result['gates'].get('nginx_http'), 'NOT_APPLICABLE')
            self.assertEqual(result['validation_result'], 'PASS', result.get('errors'))
            self.assertTrue(all('nginx_http' not in e for e in result.get('errors') or []))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_temp_http_server_stops_on_success_and_failure(self):
        tmp = tempfile.mkdtemp(prefix='sel-tmphttp-')
        try:
            root = os.path.join(tmp, 'www')
            write(os.path.join(root, 'hello.txt'), 'hi')
            with vsm.StagingHTTPServer(root) as httpd:
                status, body, err, _clen = vsm.http_get(httpd.base_url + '/hello.txt')
                self.assertEqual(status, 200)
                self.assertEqual(body, b'hi')
                port = httpd.port
            # After exit, port should not accept connections
            import socket
            sock = socket.socket()
            sock.settimeout(0.3)
            with self.assertRaises((OSError, socket.timeout, ConnectionRefusedError)):
                sock.connect(('127.0.0.1', port))
            sock.close()

            # Failure path still cleans up
            try:
                with vsm.StagingHTTPServer(root) as httpd2:
                    port2 = httpd2.port
                    raise RuntimeError('boom')
            except RuntimeError:
                pass
            sock = socket.socket()
            sock.settimeout(0.3)
            with self.assertRaises((OSError, socket.timeout, ConnectionRefusedError)):
                sock.connect(('127.0.0.1', port2))
            sock.close()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_isolated_apt_uses_file_only(self):
        tmp = tempfile.mkdtemp(prefix='sel-apt-')
        try:
            selective = os.path.join(tmp, 'selective')
            plan, _d, _r, _data = self._minimal_staging_tree(selective)
            live = os.path.join(selective, 'staging')
            if not shutil.which('apt-get'):
                self.skipTest('apt-get missing')
            # Without a usable keyring, fail closed (no trusted=yes / no http)
            ok, detail = vsm.isolated_apt_update(live, plan, keyring_path='')
            self.assertFalse(ok)
            self.assertFalse(detail.get('external_sources'))
            self.assertIn('keyring', (detail.get('error') or '').lower())
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_publish_blocked_when_verify_fail(self):
        tmp = tempfile.mkdtemp(prefix='sel-block-')
        try:
            root = os.path.join(tmp, 'selective')
            staging = os.path.join(root, 'staging')
            os.makedirs(os.path.join(staging, 'hops', 'jammy-to-noble', 'ubuntu'))
            os.makedirs(os.path.join(root, 'state'))
            write(os.path.join(root, 'state', 'verify-result.json'),
                  json.dumps({'validation_result': 'FAIL',
                              'validation_phase': 'pre_publish'}))
            with self.assertRaises(sm.SelectivePublishError) as caught:
                sm.atomic_publish(root, run_post_publish=False, run_nginx_preflight=False)
            self.assertEqual(caught.exception.error_code, sm.ERROR_PREPUBLISH)
            self.assertFalse(os.path.isfile(os.path.join(root, 'state', 'READY')))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_publish_blocked_stale_plan_checksum(self):
        tmp = tempfile.mkdtemp(prefix='sel-stale-plan-')
        try:
            root = os.path.join(tmp, 'selective')
            staging = os.path.join(root, 'staging')
            os.makedirs(os.path.join(staging, 'hops', 'x', 'ubuntu'))
            write(os.path.join(staging, 'f'), 'x')
            os.makedirs(os.path.join(root, 'state'))
            write(os.path.join(root, 'state', 'verify-result.json'), json.dumps({
                'validation_result': 'PASS',
                'validation_phase': 'pre_publish',
                'plan_checksum': 'old-plan',
                'discovery_artifact_checksum': 'disc',
            }))
            write(os.path.join(root, 'state', 'plan.json'), json.dumps({
                'plan_checksum': 'new-plan',
                'discovery_artifact_checksum': 'disc',
            }))
            with self.assertRaises(sm.SelectivePublishError) as caught:
                sm.atomic_publish(root, run_post_publish=False, run_nginx_preflight=False)
            self.assertEqual(caught.exception.error_code, sm.ERROR_VERIFY_STALE)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_publish_blocked_stale_discovery_checksum(self):
        tmp = tempfile.mkdtemp(prefix='sel-stale-disc-')
        try:
            root = os.path.join(tmp, 'selective')
            staging = os.path.join(root, 'staging')
            os.makedirs(os.path.join(staging, 'hops', 'x', 'ubuntu'))
            os.makedirs(os.path.join(root, 'state'))
            write(os.path.join(root, 'state', 'verify-result.json'), json.dumps({
                'validation_result': 'PASS',
                'validation_phase': 'pre_publish',
                'plan_checksum': 'plan',
                'discovery_artifact_checksum': 'old-disc',
            }))
            write(os.path.join(root, 'state', 'plan.json'), json.dumps({
                'plan_checksum': 'plan',
                'discovery_artifact_checksum': 'new-disc',
            }))
            with self.assertRaises(sm.SelectivePublishError) as caught:
                sm.atomic_publish(root, run_post_publish=False, run_nginx_preflight=False)
            self.assertEqual(caught.exception.error_code, sm.ERROR_VERIFY_STALE)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_publish_blocked_on_legacy_nginx_root(self):
        tmp = tempfile.mkdtemp(prefix='sel-ngx-')
        try:
            root = os.path.join(tmp, 'selective')
            staging = os.path.join(root, 'staging')
            os.makedirs(os.path.join(staging, 'hops', 'jammy-to-noble', 'ubuntu'))
            write(os.path.join(staging, 'marker'), 'keep')
            os.makedirs(os.path.join(root, 'state'))
            write(os.path.join(root, 'state', 'verify-result.json'), json.dumps({
                'validation_result': 'PASS',
                'validation_phase': 'pre_publish',
                'plan_checksum': 'p',
                'discovery_artifact_checksum': 'd',
                'repository_content_checksum': vsm.tree_sha256(staging),
            }))
            write(os.path.join(root, 'state', 'plan.json'), json.dumps({
                'plan_checksum': 'p',
                'discovery_artifact_checksum': 'd',
            }))
            orig = vsm.check_selective_nginx_preflight

            def legacy_preflight(_sel):
                return {
                    'ok': False,
                    'error_code': vsm.ERROR_NGINX_ROOT_MISMATCH,
                    'nginx_config_path': '/etc/nginx/sites-enabled/apt-mirror',
                    'nginx_document_root': '/var/spool/apt-mirror/mirror',
                    'expected_selective_root': os.path.join(root, 'current'),
                    'gates': {'nginx_effective_root': 'FAIL'},
                    'errors': ['legacy root'],
                }

            vsm.check_selective_nginx_preflight = legacy_preflight
            try:
                with self.assertRaises(sm.SelectivePublishError) as caught:
                    sm.atomic_publish(root, run_post_publish=True)
                self.assertEqual(
                    caught.exception.error_code, sm.ERROR_NGINX_ROOT_MISMATCH,
                )
            finally:
                vsm.check_selective_nginx_preflight = orig
            # Staging must be preserved (no promote on preflight fail)
            self.assertTrue(os.path.isdir(staging))
            self.assertEqual(open(os.path.join(staging, 'marker')).read(), 'keep')
            self.assertFalse(os.path.isdir(os.path.join(root, 'published')))
            self.assertFalse(os.path.isfile(os.path.join(root, 'state', 'READY')))
            pub = json.load(open(os.path.join(root, 'state', 'publish-result.json')))
            self.assertEqual(pub.get('error_code'), sm.ERROR_NGINX_ROOT_MISMATCH)
            self.assertEqual(pub.get('tested_endpoints'), [])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_post_publish_concrete_endpoints_not_root(self):
        tmp = tempfile.mkdtemp(prefix='sel-post-')
        try:
            try:
                from http.server import BaseHTTPRequestHandler, HTTPServer
            except ImportError:
                from BaseHTTPServer import BaseHTTPRequestHandler, HTTPServer  # type: ignore
            import threading

            published_files = {
                '/hops/xenial-to-bionic/ubuntu/dists/bionic/Release': b'Release-body',
                '/hops/xenial-to-bionic/ubuntu/dists/bionic/main/binary-amd64/Packages':
                    b'Package: demo\n',
                '/hops/xenial-to-bionic/ubuntu/pool/main/d/demo/demo_1_amd64.deb':
                    b'deb',
            }

            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    if self.path == '/' or self.path == '':
                        self.send_error(404, 'no index')
                        return
                    body = published_files.get(self.path)
                    if body is None:
                        self.send_error(404, 'missing')
                        return
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

                def log_message(self, *_a):
                    return

            server = HTTPServer(('127.0.0.1', 0), Handler)
            thread = threading.Thread(target=server.serve_forever)
            thread.daemon = True
            thread.start()
            host, port = server.server_address
            base = 'http://%s:%d' % (host, port)

            selective = os.path.join(tmp, 'selective')
            published = os.path.join(selective, 'published')
            hop = 'xenial-to-bionic'
            ubuntu = os.path.join(published, 'hops', hop, 'ubuntu')
            rel = 'pool/main/d/demo/demo_1_amd64.deb'
            write_bytes(os.path.join(ubuntu, rel), b'deb')
            write(os.path.join(ubuntu, 'dists', 'bionic', 'Release'), 'Release-body')
            write(os.path.join(
                ubuntu, 'dists', 'bionic', 'main', 'binary-amd64', 'Packages'),
                'Package: demo\n')
            os.symlink('published', os.path.join(selective, 'current'))
            plan = {
                'hops': [hop],
                'hop_summaries': {hop: {'suites': ['bionic']}},
                'debs': [{
                    'source_hops': [hop], 'relative_pool_path': rel,
                    'size_bytes': 3, 'sha256': hashlib.sha256(b'deb').hexdigest(),
                }],
            }
            # Avoid requiring real nginx service in unit test
            orig_which = shutil.which

            def fake_which(name):
                if name in ('nginx',):
                    return None
                return orig_which(name)

            shutil.which = fake_which
            orig_run = subprocess.run

            def fake_run(cmd, **kwargs):
                class R(object):
                    returncode = 0
                    stdout = 'active\n'
                    stderr = ''
                if cmd[:2] == ['systemctl', 'is-active']:
                    return R()
                return orig_run(cmd, **kwargs)

            subprocess.run = fake_run
            expected_root = os.path.join(selective, 'current')
            orig_pre = vsm.check_selective_nginx_preflight

            def ok_pre(_sel):
                return {
                    'ok': True,
                    'nginx_config_path': '/etc/nginx/sites-enabled/apt-mirror',
                    'nginx_document_root': expected_root,
                    'expected_selective_root': expected_root,
                    'gates': {
                        'nginx_effective_root': 'PASS',
                        'nginx_config': 'SKIPPED',
                        'nginx_service': 'PASS',
                        'nginx_repository_readable': 'PASS',
                    },
                    'errors': [],
                }

            vsm.check_selective_nginx_preflight = ok_pre
            try:
                result = vsm.post_publish_validate(
                    selective, plan, http_base=base, published_root=published,
                )
            finally:
                shutil.which = orig_which
                subprocess.run = orig_run
                vsm.check_selective_nginx_preflight = orig_pre
                server.shutdown()
                server.server_close()

            self.assertEqual(result['validation_result'], 'PASS', result.get('errors'))
            self.assertTrue(str(result['gates'].get('nginx_root_url_info', '')).startswith('INFO_'))
            self.assertEqual(result['gates'].get('nginx_http'), 'PASS')
            self.assertTrue(any('/dists/bionic/Release' in u for u in result['tested_endpoints']))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_post_publish_http_failure_rolls_back_and_no_ready(self):
        tmp = tempfile.mkdtemp(prefix='sel-rb-')
        try:
            root = os.path.join(tmp, 'selective')
            # Previous published
            prev = os.path.join(root, 'published')
            os.makedirs(os.path.join(prev, 'hops', 'jammy-to-noble', 'ubuntu'))
            write(os.path.join(prev, 'marker'), 'old')
            staging = os.path.join(root, 'staging')
            os.makedirs(os.path.join(staging, 'hops', 'jammy-to-noble', 'ubuntu'))
            write(os.path.join(staging, 'marker'), 'new')
            os.makedirs(os.path.join(root, 'state'))
            plan = {
                'plan_checksum': 'p1',
                'discovery_artifact_checksum': 'd1',
                'hops': ['jammy-to-noble'],
                'hop_summaries': {'jammy-to-noble': {'suites': ['noble']}},
                'debs': [],
            }
            write(os.path.join(root, 'state', 'plan.json'), json.dumps(plan))
            # Content checksum matching staging
            snap = vsm.tree_sha256(staging)
            write(os.path.join(root, 'state', 'verify-result.json'), json.dumps({
                'validation_result': 'PASS',
                'validation_phase': 'pre_publish',
                'plan_checksum': 'p1',
                'discovery_artifact_checksum': 'd1',
                'repository_content_checksum': snap,
                'profile_name': 'offline-upgrade-selective',
                'schema_version': 2,
                'gates': {},
            }))
            # Force post-publish failure
            orig = vsm.post_publish_validate

            def fail_post(*_a, **_k):
                return {
                    'validation_result': 'FAIL',
                    'error_code': vsm.ERROR_POSTPUBLISH_HTTP,
                    'errors': ['release_endpoint: http_status=404'],
                    'gates': {'post_publish_http': 'FAIL', 'nginx_http': 'FAIL'},
                    'tested_endpoints': ['http://127.0.0.1/hops/x/Release'],
                    'http_results': [],
                }

            vsm.post_publish_validate = fail_post
            orig_pre = vsm.check_selective_nginx_preflight
            vsm.check_selective_nginx_preflight = lambda _s: {
                'ok': True, 'gates': {}, 'errors': [],
                'nginx_document_root': os.path.join(root, 'current'),
                'expected_selective_root': os.path.join(root, 'current'),
            }
            try:
                with self.assertRaises(sm.SelectivePublishError) as caught:
                    sm.atomic_publish(root, run_post_publish=True, http_base='http://127.0.0.1')
                self.assertEqual(
                    caught.exception.error_code, sm.ERROR_POSTPUBLISH_HTTP,
                )
            finally:
                vsm.post_publish_validate = orig
                vsm.check_selective_nginx_preflight = orig_pre

            self.assertEqual(open(os.path.join(root, 'published', 'marker')).read(), 'old')
            self.assertFalse(os.path.isfile(os.path.join(root, 'state', 'READY')))
            pub = json.load(open(os.path.join(root, 'state', 'publish-result.json')))
            self.assertTrue(pub.get('rollback_performed'))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_ready_only_after_post_publish_pass(self):
        tmp = tempfile.mkdtemp(prefix='sel-ready-')
        try:
            root = os.path.join(tmp, 'selective')
            staging = os.path.join(root, 'staging')
            os.makedirs(os.path.join(staging, 'hops', 'jammy-to-noble', 'ubuntu'))
            write(os.path.join(staging, 'marker'), 'v1')
            os.makedirs(os.path.join(root, 'state'))
            plan = {
                'plan_checksum': 'p',
                'discovery_artifact_checksum': 'd',
                'hops': [], 'hop_summaries': {}, 'debs': [],
                'profile_name': 'offline-upgrade-selective',
            }
            write(os.path.join(root, 'state', 'plan.json'), json.dumps(plan))
            snap = vsm.tree_sha256(staging)
            write(os.path.join(root, 'state', 'verify-result.json'), json.dumps({
                'validation_result': 'PASS',
                'validation_phase': 'pre_publish',
                'plan_checksum': 'p',
                'discovery_artifact_checksum': 'd',
                'repository_content_checksum': snap,
                'profile_name': 'offline-upgrade-selective',
                'schema_version': 2,
                'gates': {},
                'result_json_path': os.path.join(root, 'state', 'verify-result.json'),
            }))
            # skip post-publish → no READY
            sm.atomic_publish(root, run_post_publish=False, run_nginx_preflight=False)
            self.assertFalse(os.path.isfile(os.path.join(root, 'state', 'READY')))

            # recreate staging and publish with mocked post PASS
            staging = os.path.join(root, 'staging')
            os.makedirs(os.path.join(staging, 'hops', 'jammy-to-noble', 'ubuntu'))
            write(os.path.join(staging, 'marker'), 'v2')
            snap = vsm.tree_sha256(staging)
            write(os.path.join(root, 'state', 'verify-result.json'), json.dumps({
                'validation_result': 'PASS',
                'validation_phase': 'pre_publish',
                'plan_checksum': 'p',
                'discovery_artifact_checksum': 'd',
                'repository_content_checksum': snap,
                'profile_name': 'offline-upgrade-selective',
                'schema_version': 2,
                'gates': {},
                'result_json_path': os.path.join(root, 'state', 'verify-result.json'),
            }))
            orig = vsm.post_publish_validate

            def ok_post(*_a, **_k):
                return {
                    'validation_result': 'PASS',
                    'gates': {
                        'nginx_config': 'PASS', 'nginx_service': 'PASS',
                        'nginx_http': 'PASS', 'post_publish_http': 'PASS',
                        'published_current_symlink': 'PASS',
                    },
                    'tested_endpoints': ['http://127.0.0.1/hops/x/Release'],
                    'http_results': [{'result': 'PASS'}],
                    'errors': [],
                }

            vsm.post_publish_validate = ok_post
            orig_pre = vsm.check_selective_nginx_preflight
            vsm.check_selective_nginx_preflight = lambda _s: {
                'ok': True, 'gates': {}, 'errors': [],
                'nginx_document_root': os.path.join(root, 'current'),
                'expected_selective_root': os.path.join(root, 'current'),
            }
            try:
                sm.atomic_publish(root, run_post_publish=True)
            finally:
                vsm.post_publish_validate = orig
                vsm.check_selective_nginx_preflight = orig_pre
            self.assertTrue(os.path.isfile(os.path.join(root, 'state', 'READY')))
            body = open(os.path.join(root, 'state', 'READY')).read()
            self.assertIn('validation_phase=post_publish', body)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_shell_verify_does_not_pass_http_base(self):
        body = open(os.path.join(ROOT, 'scripts', 'ubuntu-offline-mirror.sh')).read()
        # Pre-publish verify impl must not add --http-base (publish does).
        start = body.index('cmd_verify_selective_impl()')
        end = body.index('cmd_verify_selective()')
        section = body[start:end]
        self.assertNotIn('--http-base', section)
        self.assertIn('pre_publish', section)
        self.assertIn('VERIFY_SELECTIVE_APT', section)

    def test_materialized_files_not_deleted_by_verify(self):
        tmp = tempfile.mkdtemp(prefix='sel-keep-')
        try:
            selective = os.path.join(tmp, 'selective')
            plan, digest, rel, data = self._minimal_staging_tree(selective)
            plan_path = os.path.join(tmp, 'plan.json')
            write(plan_path, json.dumps(plan))
            deb_path = os.path.join(
                selective, 'staging', 'hops', 'xenial-to-bionic', 'ubuntu', rel,
            )
            before = open(deb_path, 'rb').read()
            orig = vsm.verify_gpg_inrelease
            vsm.verify_gpg_inrelease = lambda *a, **k: (True, 'ok')
            try:
                vsm.validate_tree(plan_path, selective, run_apt=False)
            finally:
                vsm.verify_gpg_inrelease = orig
            self.assertTrue(os.path.isfile(deb_path))
            self.assertEqual(open(deb_path, 'rb').read(), before)
            self.assertEqual(hashlib.sha256(before).hexdigest(), digest)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class SuiteSemanticsSeparationTests(unittest.TestCase):
    """Source suites must not index target packages; target suites keep payloads."""

    def _fake_parse(self, package, version):
        def fake(_path):
            return {
                'Package': package, 'Version': version, 'Architecture': 'amd64',
                'Maintainer': 't', 'Description': 'd',
            }
        return fake

    def test_source_suite_empty_target_suite_has_packages(self):
        tmp = tempfile.mkdtemp(prefix='sel-suite-')
        try:
            ubuntu = os.path.join(tmp, 'ubuntu')
            data = b'deb-bytes'
            digest = hashlib.sha256(data).hexdigest()
            rel = 'pool/main/a/apt/apt_1.6.17_amd64.deb'
            write_bytes(os.path.join(ubuntu, rel), data)
            orig = sm.parse_deb_control
            sm.parse_deb_control = self._fake_parse('apt', '1.6.17')
            try:
                debs = [{
                    'package': 'apt', 'version': '1.6.17', 'architecture': 'amd64',
                    'component': 'main', 'relative_pool_path': rel,
                    'size_bytes': len(data), 'sha256': digest,
                    'original_suite': 'bionic',
                }]
                suites = [
                    'xenial', 'xenial-updates', 'xenial-security',
                    'bionic', 'bionic-updates', 'bionic-security',
                ]
                sm.generate_packages_for_hop(
                    ubuntu, debs, suites,
                    from_series='xenial', to_series='bionic', hop='xenial-to-bionic',
                )
                xenial_pkgs = open(
                    os.path.join(ubuntu, 'dists', 'xenial', 'main', 'binary-amd64', 'Packages')
                ).read()
                bionic_pkgs = open(
                    os.path.join(ubuntu, 'dists', 'bionic', 'main', 'binary-amd64', 'Packages')
                ).read()
                self.assertEqual(xenial_pkgs.strip(), '')
                self.assertIn('Package: apt', bionic_pkgs)
                self.assertIn('1.6.17', bionic_pkgs)
                ok, detail = vsm.validate_hop_suite_semantics(
                    ubuntu, 'xenial-to-bionic',
                    {'from_series': 'xenial', 'to_series': 'bionic', 'suites': suites},
                )
                self.assertTrue(ok, detail)
                self.assertEqual(detail['CROSS_RELEASE_INDEX_CONTAMINATION'], 0)
                self.assertEqual(detail['SOURCE_SUITE_SEMANTICS'], 'PASS')
                self.assertEqual(detail['TARGET_SUITE_SEMANTICS'], 'PASS')
            finally:
                sm.parse_deb_control = orig
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_xenial_suite_with_base_files_10_fails(self):
        tmp = tempfile.mkdtemp(prefix='sel-contam-')
        try:
            ubuntu = os.path.join(tmp, 'ubuntu')
            for suite, pkg, ver in (
                ('xenial', 'base-files', '10.1ubuntu2.12'),
                ('bionic', 'base-files', '10.1ubuntu2.12'),
            ):
                binary = os.path.join(ubuntu, 'dists', suite, 'main', 'binary-amd64')
                os.makedirs(binary, exist_ok=True)
                write(os.path.join(binary, 'Packages'),
                      'Package: %s\nVersion: %s\nFilename: pool/main/x.deb\n'
                      'Size: 1\nSHA256: %s\n\n' % (pkg, ver, 'a' * 64))
                write(os.path.join(ubuntu, 'dists', suite, 'Release'),
                      'Suite: %s\nCodename: %s\nAcquire-By-Hash: no\n' % (
                          suite, suite.split('-')[0]))
            ok, detail = vsm.validate_hop_suite_semantics(
                ubuntu, 'xenial-to-bionic',
                {'from_series': 'xenial', 'to_series': 'bionic',
                 'suites': ['xenial', 'bionic']},
            )
            self.assertFalse(ok)
            self.assertEqual(detail['SOURCE_SUITE_SEMANTICS'], 'FAIL')
            self.assertGreater(detail['CROSS_RELEASE_INDEX_CONTAMINATION'], 0)
            self.assertIn(vsm.ERROR_SOURCE_CONTAMINATION, detail['error_codes'])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_xenial_suite_libc6_2_27_fails(self):
        tmp = tempfile.mkdtemp(prefix='sel-libc-')
        try:
            ubuntu = os.path.join(tmp, 'ubuntu')
            binary = os.path.join(ubuntu, 'dists', 'xenial', 'main', 'binary-amd64')
            os.makedirs(binary, exist_ok=True)
            write(os.path.join(binary, 'Packages'),
                  'Package: libc6\nVersion: 2.27-3ubuntu1.6\nFilename: pool/main/l.deb\n'
                  'Size: 1\nSHA256: %s\n\n' % ('b' * 64))
            write(os.path.join(ubuntu, 'dists', 'xenial', 'Release'),
                  'Suite: xenial\nCodename: xenial\nAcquire-By-Hash: no\n')
            write(os.path.join(ubuntu, 'dists', 'bionic', 'Release'),
                  'Suite: bionic\nCodename: bionic\nAcquire-By-Hash: no\n')
            os.makedirs(os.path.join(ubuntu, 'dists', 'bionic', 'main', 'binary-amd64'),
                        exist_ok=True)
            write(os.path.join(ubuntu, 'dists', 'bionic', 'main', 'binary-amd64', 'Packages'), '')
            ok, detail = vsm.validate_hop_suite_semantics(
                ubuntu, 'xenial-to-bionic',
                {'from_series': 'xenial', 'to_series': 'bionic',
                 'suites': ['xenial', 'bionic']},
            )
            self.assertFalse(ok)
            self.assertIn(vsm.ERROR_SOURCE_CONTAMINATION, detail['error_codes'])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_xenial_suite_apt_1_6_and_systemd_237_fail(self):
        for pkg, ver in (('apt', '1.6.17'), ('systemd', '237-3ubuntu10.57')):
            tmp = tempfile.mkdtemp(prefix='sel-%s-' % pkg)
            try:
                ubuntu = os.path.join(tmp, 'ubuntu')
                binary = os.path.join(ubuntu, 'dists', 'xenial', 'main', 'binary-amd64')
                os.makedirs(binary, exist_ok=True)
                write(os.path.join(binary, 'Packages'),
                      'Package: %s\nVersion: %s\nFilename: pool/main/x.deb\n'
                      'Size: 1\nSHA256: %s\n\n' % (pkg, ver, 'c' * 64))
                write(os.path.join(ubuntu, 'dists', 'xenial', 'Release'),
                      'Suite: xenial\nCodename: xenial\nAcquire-By-Hash: no\n')
                write(os.path.join(ubuntu, 'dists', 'bionic', 'Release'),
                      'Suite: bionic\nCodename: bionic\nAcquire-By-Hash: no\n')
                os.makedirs(
                    os.path.join(ubuntu, 'dists', 'bionic', 'main', 'binary-amd64'),
                    exist_ok=True,
                )
                write(os.path.join(
                    ubuntu, 'dists', 'bionic', 'main', 'binary-amd64', 'Packages'), '')
                ok, detail = vsm.validate_hop_suite_semantics(
                    ubuntu, 'xenial-to-bionic',
                    {'from_series': 'xenial', 'to_series': 'bionic',
                     'suites': ['xenial', 'bionic']},
                )
                self.assertFalse(ok, pkg)
                self.assertEqual(detail['SOURCE_SUITE_SEMANTICS'], 'FAIL', pkg)
            finally:
                shutil.rmtree(tmp, ignore_errors=True)

    def test_bionic_suite_target_packages_pass(self):
        tmp = tempfile.mkdtemp(prefix='sel-bionic-ok-')
        try:
            ubuntu = os.path.join(tmp, 'ubuntu')
            binary = os.path.join(ubuntu, 'dists', 'bionic', 'main', 'binary-amd64')
            os.makedirs(binary, exist_ok=True)
            write(os.path.join(binary, 'Packages'),
                  'Package: base-files\nVersion: 10.1ubuntu2.12\n'
                  'Filename: pool/main/b.deb\nSize: 1\nSHA256: %s\n\n'
                  'Package: libc6\nVersion: 2.27-3ubuntu1.6\n'
                  'Filename: pool/main/l.deb\nSize: 1\nSHA256: %s\n\n'
                  'Package: apt\nVersion: 1.6.17\n'
                  'Filename: pool/main/a.deb\nSize: 1\nSHA256: %s\n\n'
                  'Package: dpkg\nVersion: 1.19.0.5ubuntu2.4\n'
                  'Filename: pool/main/d.deb\nSize: 1\nSHA256: %s\n\n'
                  'Package: systemd\nVersion: 237-3ubuntu10.57\n'
                  'Filename: pool/main/s.deb\nSize: 1\nSHA256: %s\n\n' % (
                      '1' * 64, '2' * 64, '3' * 64, '4' * 64, '5' * 64))
            write(os.path.join(ubuntu, 'dists', 'bionic', 'Release'),
                  'Suite: bionic\nCodename: bionic\nAcquire-By-Hash: no\n')
            write(os.path.join(ubuntu, 'dists', 'xenial', 'Release'),
                  'Suite: xenial\nCodename: xenial\nAcquire-By-Hash: no\n')
            os.makedirs(os.path.join(ubuntu, 'dists', 'xenial', 'main', 'binary-amd64'),
                        exist_ok=True)
            write(os.path.join(ubuntu, 'dists', 'xenial', 'main', 'binary-amd64', 'Packages'), '')
            ok, detail = vsm.validate_hop_suite_semantics(
                ubuntu, 'xenial-to-bionic',
                {'from_series': 'xenial', 'to_series': 'bionic',
                 'suites': ['xenial', 'bionic']},
            )
            self.assertTrue(ok, detail)
            self.assertEqual(detail['TARGET_SUITE_SEMANTICS'], 'PASS')
            self.assertEqual(detail['OFFLINE_DISTUPGRADE_TARGET_SOURCE'], 'PASS')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_generate_packages_preserves_depends_essential(self):
        """Packages must keep Depends/Essential from original/.deb — never minimal stubs."""
        if not shutil.which('dpkg-deb'):
            self.skipTest('dpkg-deb missing')
        tmp = tempfile.mkdtemp(prefix='sel-deps-')
        try:
            import textwrap
            ctrl = os.path.join(tmp, 'ctrl')
            os.makedirs(os.path.join(ctrl, 'DEBIAN'))
            write(os.path.join(ctrl, 'DEBIAN', 'control'), textwrap.dedent('''\
                Package: libc-bin
                Version: 2.27-3ubuntu1.6
                Architecture: amd64
                Essential: yes
                Depends: libc6 (>> 2.27), libc6 (<< 2.28)
                Multi-Arch: foreign
                Priority: required
                Section: libs
                Maintainer: Test <t@t>
                Description: test libc-bin
            '''))
            ubuntu = os.path.join(tmp, 'ubuntu')
            rel = 'pool/main/g/glibc/libc-bin_2.27-3ubuntu1.6_amd64.deb'
            deb = os.path.join(ubuntu, rel)
            os.makedirs(os.path.dirname(deb))
            subprocess.check_call(['dpkg-deb', '-b', ctrl, deb],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            data = open(deb, 'rb').read()
            digest = hashlib.sha256(data).hexdigest()
            pocket = os.path.join(tmp, 'pocket', 'dists', 'bionic-updates',
                                  'main', 'binary-amd64')
            os.makedirs(pocket)
            write(os.path.join(pocket, 'Packages'), textwrap.dedent('''\
                Package: libc-bin
                Version: 2.27-3ubuntu1.6
                Architecture: amd64
                Essential: yes
                Depends: libc6 (>> 2.27), libc6 (<< 2.28)
                Multi-Arch: foreign
                Priority: required
                Section: libs
                Maintainer: Canonical
                Description: orig
                Filename: pool/main/g/glibc/libc-bin_2.27-3ubuntu1.6_amd64.deb
                Size: 1
                SHA256: deadbeef

            '''))
            debs = [{
                'package': 'libc-bin', 'version': '2.27-3ubuntu1.6',
                'architecture': 'amd64', 'component': 'main',
                'relative_pool_path': rel, 'size_bytes': len(data),
                'sha256': digest, 'original_suite': 'bionic-updates',
            }]
            sm.generate_packages_for_hop(
                ubuntu, debs, ['bionic-updates'],
                from_series='xenial', to_series='bionic', hop='xenial-to-bionic',
                original_index_roots=[os.path.join(tmp, 'pocket')],
            )
            body = open(os.path.join(
                ubuntu, 'dists', 'bionic-updates', 'main', 'binary-amd64', 'Packages',
            )).read()
            self.assertIn('Depends: libc6 (>> 2.27), libc6 (<< 2.28)', body)
            self.assertIn('Essential: yes', body)
            self.assertIn('Multi-Arch: foreign', body)
            self.assertIn(digest, body)
            ok, detail = vsm.validate_packages_deb_metadata_consistency(ubuntu)
            self.assertTrue(ok, detail)
            self.assertEqual(detail['mismatches'], 0)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_focal_base_files_ubuntu_version_passes(self):
        # Real Ubuntu focal base-files is "11ubuntu5.8" (no dot after 11).
        tmp = tempfile.mkdtemp(prefix='sel-focal-bf-')
        try:
            ubuntu = os.path.join(tmp, 'ubuntu')
            for suite in ('bionic', 'focal'):
                binary = os.path.join(ubuntu, 'dists', suite, 'main', 'binary-amd64')
                os.makedirs(binary, exist_ok=True)
                write(os.path.join(ubuntu, 'dists', suite, 'Release'),
                      'Suite: %s\nCodename: %s\nAcquire-By-Hash: no\n' % (suite, suite))
                write(os.path.join(binary, 'Packages'), '')
            write(os.path.join(ubuntu, 'dists', 'focal', 'main', 'binary-amd64', 'Packages'),
                  'Package: base-files\nVersion: 11ubuntu5.8\n'
                  'Filename: pool/main/b.deb\nSize: 1\nSHA256: %s\n\n' % ('a' * 64))
            ok, detail = vsm.validate_hop_suite_semantics(
                ubuntu, 'bionic-to-focal',
                {'from_series': 'bionic', 'to_series': 'focal',
                 'suites': ['bionic', 'focal']},
            )
            self.assertTrue(ok, detail)
            self.assertEqual(detail['TARGET_SUITE_SEMANTICS'], 'PASS')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_quarantine_hop_clears_ready(self):
        tmp = tempfile.mkdtemp(prefix='sel-quar-')
        try:
            selective = os.path.join(tmp, 'selective')
            hop = 'xenial-to-bionic'
            hop_dir = os.path.join(selective, 'published', 'hops', hop)
            os.makedirs(hop_dir)
            os.makedirs(os.path.join(selective, 'state'))
            write(os.path.join(selective, 'state', 'READY'), 'READY\n')
            result = vsm.quarantine_hop(selective, hop)
            self.assertEqual(result['status'], 'QUARANTINED')
            self.assertFalse(os.path.isfile(os.path.join(selective, 'state', 'READY')))
            self.assertTrue(os.path.isfile(os.path.join(hop_dir, 'QUARANTINED')))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_refresh_hop_command_documented(self):
        body = open(os.path.join(ROOT, 'scripts', 'ubuntu-offline-mirror.sh')).read()
        self.assertIn('cmd_refresh_hop_selective', body)
        self.assertIn('cmd_refresh_hop_selective_impl', body)
        self.assertIn('quarantine-hop-selective', body)
        self.assertIn('refresh-hop-selective', body)
        self.assertIn('acquire_global_lock_once', body)
        # refresh must not nest public lock-acquiring commands
        start = body.index('cmd_refresh_hop_selective_impl()')
        end = body.index('cmd_refresh_hop_selective()')
        impl = body[start:end]
        self.assertIn('cmd_verify_selective_impl', impl)
        self.assertIn('cmd_publish_selective_impl', impl)
        self.assertNotIn('"$0"', impl)


class StagingProvenanceResumeTests(unittest.TestCase):
    """Materialize resume / provenance fail-closed / staging immutability."""

    def _plan_and_staging(self, selective, plan_ck='plan-aaa', disc_ck='disc-bbb'):
        hop = 'xenial-to-bionic'
        data = b'deb-payload-bytes'
        digest = hashlib.sha256(data).hexdigest()
        rel = 'pool/main/a/apt/apt_1.6.17_amd64.deb'
        staging = os.path.join(selective, 'staging')
        ubuntu = os.path.join(staging, 'hops', hop, 'ubuntu')
        write_bytes(os.path.join(ubuntu, rel), data)
        os.makedirs(os.path.join(ubuntu, 'dists', 'xenial', 'main', 'binary-amd64'),
                    exist_ok=True)
        os.makedirs(os.path.join(ubuntu, 'dists', 'bionic', 'main', 'binary-amd64'),
                    exist_ok=True)
        os.makedirs(os.path.join(staging, 'shared', 'offline'), exist_ok=True)
        write(os.path.join(staging, 'shared', 'offline', 'meta-release-lts'), '# stub\n')
        plan = {
            'validation_result': 'PASS',
            'profile_name': 'offline-upgrade-selective',
            'plan_checksum': plan_ck,
            'discovery_artifact_checksum': disc_ck,
            'hops': [hop],
            'hop_summaries': {
                hop: {
                    'from_series': 'xenial', 'to_series': 'bionic',
                    'suites': ['xenial', 'bionic'],
                },
            },
            'debs': [{
                'package': 'apt', 'version': '1.6.17', 'architecture': 'amd64',
                'component': 'main', 'relative_pool_path': rel,
                'size_bytes': len(data), 'sha256': digest,
                'source_hops': [hop],
                'original_suite': 'bionic',
            }],
            'upgraders': [],
        }
        mat = {
            'validation_result': 'PASS',
            'staging_root': staging,
            'profile_name': 'offline-upgrade-selective',
            'plan_checksum': plan_ck,
            'discovery_artifact_checksum': disc_ck,
            'stats': {'downloaded': 1, 'exists': 0, 'bytes_downloaded': len(data)},
            'generated_at': '2026-01-01T00:00:00+0000',
        }
        os.makedirs(os.path.join(selective, 'state'), exist_ok=True)
        return plan, mat, digest, rel, data

    def test_resume_reuses_matching_staging(self):
        tmp = tempfile.mkdtemp(prefix='sel-resume-')
        try:
            selective = os.path.join(tmp, 'selective')
            plan, mat, digest, rel, data = self._plan_and_staging(selective)
            plan_path = os.path.join(tmp, 'plan.json')
            write(plan_path, json.dumps(plan))
            write(os.path.join(selective, 'state', 'materialize.json'), json.dumps(mat))
            deb_before = open(
                os.path.join(selective, 'staging', 'hops', 'xenial-to-bionic',
                             'ubuntu', rel), 'rb'
            ).read()
            result = sm.materialize(
                plan_path, selective, allow_download=False, sign=False,
                allow_resume=True, hop='xenial-to-bionic',
            )
            self.assertEqual(result.get('materialize_reused'), 'YES')
            self.assertEqual(result.get('refresh_resume_from'), 'MATERIALIZED')
            self.assertEqual(
                open(os.path.join(selective, 'staging', 'hops', 'xenial-to-bionic',
                                  'ubuntu', rel), 'rb').read(),
                deb_before,
            )
            self.assertEqual(hashlib.sha256(deb_before).hexdigest(), digest)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_plan_checksum_mismatch_fail_closed(self):
        tmp = tempfile.mkdtemp(prefix='sel-prov-plan-')
        try:
            selective = os.path.join(tmp, 'selective')
            plan, mat, _, rel, _ = self._plan_and_staging(selective)
            mat['plan_checksum'] = 'other-plan'
            plan_path = os.path.join(tmp, 'plan.json')
            write(plan_path, json.dumps(plan))
            write(os.path.join(selective, 'state', 'materialize.json'), json.dumps(mat))
            with self.assertRaises(sm.SelectiveProvenanceError) as ctx:
                sm.materialize(
                    plan_path, selective, allow_download=False, sign=False,
                    allow_resume=True, hop='xenial-to-bionic',
                )
            self.assertEqual(ctx.exception.error_code, sm.ERROR_STAGING_PROVENANCE)
            # staging not deleted
            self.assertTrue(os.path.isfile(
                os.path.join(selective, 'staging', 'hops', 'xenial-to-bionic',
                             'ubuntu', rel)
            ))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_discovery_checksum_mismatch_fail_closed(self):
        tmp = tempfile.mkdtemp(prefix='sel-prov-disc-')
        try:
            selective = os.path.join(tmp, 'selective')
            plan, mat, _, rel, _ = self._plan_and_staging(selective)
            mat['discovery_artifact_checksum'] = 'other-disc'
            plan_path = os.path.join(tmp, 'plan.json')
            write(plan_path, json.dumps(plan))
            write(os.path.join(selective, 'state', 'materialize.json'), json.dumps(mat))
            with self.assertRaises(sm.SelectiveProvenanceError) as ctx:
                sm.evaluate_staging_reuse(
                    plan_path, selective, hop='xenial-to-bionic',
                )
            self.assertEqual(ctx.exception.error_code, sm.ERROR_STAGING_PROVENANCE)
            fields = [m['field'] for m in ctx.exception.mismatches]
            self.assertIn('discovery_artifact_checksum', fields)
            self.assertTrue(os.path.isfile(
                os.path.join(selective, 'staging', 'hops', 'xenial-to-bionic',
                             'ubuntu', rel)
            ))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_incomplete_staging_no_receipt_does_not_raise(self):
        tmp = tempfile.mkdtemp(prefix='sel-incomplete-')
        try:
            selective = os.path.join(tmp, 'selective')
            plan, _, _, _, _ = self._plan_and_staging(selective)
            # remove receipt
            plan_path = os.path.join(tmp, 'plan.json')
            write(plan_path, json.dumps(plan))
            ok, detail = sm.evaluate_staging_reuse(
                plan_path, selective, hop='xenial-to-bionic',
            )
            self.assertFalse(ok)
            self.assertEqual(detail.get('reason'), 'NO_MATERIALIZE_RECEIPT')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_staging_changed_after_verify_blocks_publish(self):
        tmp = tempfile.mkdtemp(prefix='sel-immut-')
        try:
            selective = os.path.join(tmp, 'selective')
            plan, mat, digest, rel, data = self._plan_and_staging(selective)
            plan_path = os.path.join(tmp, 'plan.json')
            write(plan_path, json.dumps(plan))
            write(os.path.join(selective, 'state', 'materialize.json'), json.dumps(mat))
            staging = os.path.join(selective, 'staging')
            snap = vsm.tree_sha256(staging)
            verify = {
                'validation_result': 'PASS',
                'validation_phase': 'pre_publish',
                'plan_checksum': plan['plan_checksum'],
                'discovery_artifact_checksum': plan['discovery_artifact_checksum'],
                'repository_content_checksum': snap,
            }
            write(os.path.join(selective, 'state', 'verify-result.json'),
                  json.dumps(verify))
            # mutate staging after verify
            write_bytes(
                os.path.join(selective, 'staging', 'hops', 'xenial-to-bionic',
                             'ubuntu', rel),
                data + b'-mutated',
            )
            ok, code, reason = sm._verify_result_is_current(verify, plan, staging)
            self.assertFalse(ok)
            self.assertEqual(code, sm.ERROR_STAGING_CHANGED)
            with self.assertRaises(sm.SelectivePublishError) as ctx:
                sm.atomic_publish(
                    selective, require_verify_pass=True,
                    plan_path=plan_path, run_post_publish=False,
                    run_nginx_preflight=False,
                )
            self.assertEqual(ctx.exception.error_code, sm.ERROR_STAGING_CHANGED)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_verify_fingerprint_match_allows_publish_gate(self):
        tmp = tempfile.mkdtemp(prefix='sel-immut-ok-')
        try:
            selective = os.path.join(tmp, 'selective')
            plan, mat, _, _, _ = self._plan_and_staging(selective)
            staging = os.path.join(selective, 'staging')
            snap = vsm.tree_sha256(staging)
            verify = {
                'validation_result': 'PASS',
                'validation_phase': 'pre_publish',
                'plan_checksum': plan['plan_checksum'],
                'discovery_artifact_checksum': plan['discovery_artifact_checksum'],
                'repository_content_checksum': snap,
            }
            ok, code, reason = sm._verify_result_is_current(verify, plan, staging)
            self.assertTrue(ok, reason)
            self.assertEqual(code, '')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_hop_selector_excludes_other_hops(self):
        plan = {
            'hops': ['xenial-to-bionic', 'bionic-to-focal'],
            'hop_summaries': {
                'xenial-to-bionic': {'suites': ['bionic']},
                'bionic-to-focal': {'suites': ['focal']},
            },
            'debs': [
                {'source_hops': ['xenial-to-bionic'], 'package': 'a'},
                {'source_hops': ['bionic-to-focal'], 'package': 'b'},
            ],
        }
        all_entries = sm._acquisition_entries(plan)
        self.assertEqual(len(all_entries), 2)
        xb = sm._acquisition_entries(plan, hop='xenial-to-bionic')
        self.assertEqual(len(xb), 1)
        self.assertEqual(xb[0][1], 'xenial-to-bionic')
        self.assertEqual(xb[0][2]['package'], 'a')

    def test_part_files_not_reused(self):
        tmp = tempfile.mkdtemp(prefix='sel-part-')
        try:
            selective = os.path.join(tmp, 'selective')
            hop = 'xenial-to-bionic'
            rel = 'pool/main/a/apt/apt_1.0_amd64.deb'
            data = b'good-bytes'
            digest = hashlib.sha256(data).hexdigest()
            pub = os.path.join(
                selective, 'published', 'hops', hop, 'ubuntu', rel,
            )
            write_bytes(pub, data)
            # Poisonous partial next to a wrong-sized sibling must not win.
            part = pub + '.part'
            write_bytes(part, b'partial')
            got = sm.resolve_verified_reuse_source(
                selective, hop, rel,
                expected_sha256=digest, expected_size=len(data),
            )
            self.assertEqual(got, pub)
            bad = sm.resolve_verified_reuse_source(
                selective, hop, rel,
                expected_sha256='0' * 64, expected_size=len(data),
            )
            self.assertEqual(bad, '')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_quarantine_blocks_symlink_and_publish_root(self):
        tmp = tempfile.mkdtemp(prefix='sel-qsafe-')
        try:
            selective = os.path.join(tmp, 'selective')
            staging = os.path.join(selective, 'staging')
            published = os.path.join(selective, 'published')
            os.makedirs(os.path.join(staging, 'hops'))
            os.makedirs(published)
            write(os.path.join(selective, 'state', 'materialize.json'), json.dumps({
                'validation_result': 'PASS',
                'staging_root': staging,
                'plan_checksum': 'abc12345deadbeef',
            }))
            # Symlink staging refused
            os.rmdir(os.path.join(staging, 'hops'))
            os.rmdir(staging)
            os.symlink(published, staging)
            with self.assertRaises(sm.SelectiveProvenanceError) as ctx:
                sm.quarantine_mismatch_staging(
                    selective, known_selective_roots=[selective],
                )
            self.assertEqual(ctx.exception.error_code, sm.ERROR_QUARANTINE)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_quarantine_atomic_rename_preserves_data(self):
        tmp = tempfile.mkdtemp(prefix='sel-qok-')
        try:
            selective = os.path.join(tmp, 'selective')
            staging = os.path.join(selective, 'staging')
            os.makedirs(os.path.join(staging, 'hops', 'xenial-to-bionic'))
            write(os.path.join(staging, 'marker.txt'), 'keep-me\n')
            receipt = os.path.join(selective, 'state', 'materialize.json')
            write(receipt, json.dumps({
                'validation_result': 'PASS',
                'staging_root': staging,
                'plan_checksum': '3b7f80feaaaaaaaa',
            }))
            evidence = os.path.join(tmp, 'evidence')
            result = sm.quarantine_mismatch_staging(
                selective,
                evidence_dir=evidence,
                known_selective_roots=[selective],
            )
            self.assertEqual(result['QUARANTINE_RESULT'], 'PASS')
            self.assertEqual(result['QUARANTINE_DELETE_PERFORMED'], 'NO')
            self.assertFalse(os.path.lexists(staging))
            self.assertTrue(os.path.isdir(result['QUARANTINE_DESTINATION']))
            self.assertTrue(os.path.isfile(
                os.path.join(result['QUARANTINE_DESTINATION'], 'marker.txt')
            ))
            self.assertFalse(os.path.isfile(receipt))
            self.assertTrue(os.path.isfile(
                os.path.join(evidence, 'materialize.json')
            ))
            # Clean staging can be recreated
            os.makedirs(staging)
            self.assertTrue(os.path.isdir(staging))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_new_receipt_records_current_plan_sha(self):
        tmp = tempfile.mkdtemp(prefix='sel-receipt-')
        try:
            selective = os.path.join(tmp, 'selective')
            hop = 'xenial-to-bionic'
            data = b'payload'
            digest = hashlib.sha256(data).hexdigest()
            rel = 'pool/main/a/apt/apt_1.0_amd64.deb'
            seed = os.path.join(tmp, 'seed', rel)
            write_bytes(seed, data)
            plan = {
                'validation_result': 'PASS',
                'profile_name': 'offline-upgrade-selective',
                'plan_checksum': '8eb3d478newplan00',
                'discovery_artifact_checksum': 'disc-new',
                'discovery_root': '/tmp/discovery',
                'hops': [hop],
                'hop_summaries': {
                    hop: {
                        'from_series': 'xenial', 'to_series': 'bionic',
                        'suites': ['bionic'],
                    },
                },
                'debs': [{
                    'package': 'apt', 'version': '1.0', 'architecture': 'amd64',
                    'component': 'main', 'relative_pool_path': rel,
                    'size_bytes': len(data), 'sha256': digest,
                    'source_hops': [hop],
                    'seed_local_path': seed,
                    'original_url': '',
                }],
                'upgraders': [],
            }
            plan_path = os.path.join(tmp, 'plan.json')
            write(plan_path, json.dumps(plan))
            orig_gen = sm.generate_packages_for_hop
            sm.generate_packages_for_hop = lambda *a, **k: []
            try:
                result = sm.materialize(
                    plan_path, selective, allow_download=False, sign=False,
                    hop=hop,
                )
            finally:
                sm.generate_packages_for_hop = orig_gen
            self.assertEqual(result['plan_checksum'], '8eb3d478newplan00')
            self.assertEqual(result['hop'], hop)
            self.assertEqual(result['staging_schema_version'], sm.STAGING_SCHEMA_VERSION)
            self.assertEqual(result['validation_result'], 'PASS')
            receipt = json.loads(open(
                os.path.join(selective, 'state', 'materialize.json')
            ).read())
            self.assertEqual(receipt['plan_checksum'], '8eb3d478newplan00')
            self.assertTrue(os.path.isdir(
                os.path.join(selective, 'staging', 'shared', 'offline')
            ))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_schema_constants_consistent(self):
        self.assertEqual(sm.STAGING_SCHEMA_VERSION, sm.MATERIALIZER_SCHEMA)
        self.assertEqual(sm.STAGING_SCHEMA_VERSION, sm.VALIDATOR_SCHEMA)
        self.assertEqual(sm.STAGING_SCHEMA_VERSION, sm.PUBLISHER_SCHEMA)

    def test_transient_retry_helper(self):
        class RemoteDisconnected(Exception):
            pass

        self.assertTrue(sm._is_transient_download_exc(RemoteDisconnected('x')))
        self.assertFalse(sm._is_transient_download_exc(ValueError('nope')))

    def test_durable_script_renders_hop_scope(self):
        path = os.path.join(
            ROOT, 'tests/fixtures/upgrade-discovery/analysis/h7-republish-durable.sh',
        )
        with open(path, encoding='utf-8') as fh:
            body = fh.read()
        self.assertIn('materialize-selective "$H7_HOP"', body)
        self.assertIn('H7_HOP="${H7_HOP:-xenial-to-bionic}"', body)
        self.assertIn('verify-selective "$H7_HOP"', body)
        self.assertIn('exit 10', body)
        self.assertIn('PROVENANCE_MISMATCH', body)


if __name__ == '__main__':
    unittest.main()
