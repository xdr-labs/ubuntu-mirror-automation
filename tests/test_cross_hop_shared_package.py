#!/usr/bin/env python3
"""Cross-hop shared-package membership: file + index on every source_hop.

Regression for the production OS Core defect where iucode-tool 2.3.1-1
(identical SHA/URL) was present/indexed only in xenial-to-bionic and omitted
from bionic-to-focal.

Python 3.5+; standard library only.
"""
from __future__ import print_function

import hashlib
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest
from collections import OrderedDict

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'lib'))

import aws_os_core_completeness as aws_c  # noqa: E402
import discovery_profiles as dp  # noqa: E402
import selective_mirror as sm  # noqa: E402
import validate_selective_mirror as vsm  # noqa: E402


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bsp = _load(
    'build_selective_mirror_plan',
    os.path.join(ROOT, 'scripts', 'build-selective-mirror-plan.py'),
)

IUCODE_SHA = '31066ceac0a040b114fc3cd03b012a483d6f5572699c71fda4140f8a6c3bb821'
IUCODE_REL = 'pool/main/i/iucode-tool/iucode-tool_2.3.1-1_amd64.deb'
IUCODE_URL = (
    'http://archive.ubuntu.com/ubuntu/pool/main/i/iucode-tool/'
    'iucode-tool_2.3.1-1_amd64.deb'
)
HOPS = list(dp.HOPS)
X2B = 'xenial-to-bionic'
B2F = 'bionic-to-focal'


def write(path, content):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, 'w') as fh:
        fh.write(content)


def write_bytes(path, data):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, 'wb') as fh:
        fh.write(data)


def write_tsv(path, fieldnames, rows):
    import csv
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, 'w') as fh:
        w = csv.DictWriter(fh, fieldnames=fieldnames, delimiter='\t', lineterminator='\n')
        w.writeheader()
        for row in rows:
            w.writerow(row)


def seed_min_hop(root, hop, packages, files=None, urls=None):
    d = os.path.join(root, hop)
    os.makedirs(d, exist_ok=True)
    pkg_fields = [
        'hop', 'package', 'version', 'architecture', 'source_package', 'filename',
        'repository_host', 'suite', 'component', 'size_bytes', 'sha256',
        'original_url', 'final_url', 'requested', 'downloaded', 'installed',
        'evidence_source',
    ]
    write_tsv(os.path.join(d, 'required-packages.tsv'), pkg_fields, packages)
    file_fields = [
        'hop', 'file_type', 'filename', 'original_url', 'final_url', 'local_path',
        'size_bytes', 'sha256', 'http_status', 'request_count', 'evidence_source',
    ]
    write_tsv(os.path.join(d, 'required-files.tsv'), file_fields, files or [])
    url_fields = [
        'hop', 'requested_at', 'method', 'original_url', 'final_url',
        'http_status', 'size_bytes', 'sha256', 'local_path',
    ]
    write_tsv(os.path.join(d, 'required-urls.tsv'), url_fields, urls or [])
    for name, fields in (
        ('unresolved-packages.tsv', [
            'hop', 'package', 'version', 'architecture', 'original_url',
            'final_url', 'reason',
        ]),
        ('unresolved-files.tsv', [
            'hop', 'file_type', 'filename', 'original_url', 'final_url', 'reason',
        ]),
    ):
        write_tsv(os.path.join(d, name), fields, [])
    write(
        os.path.join(d, 'validation.txt'),
        'VALIDATION: PASS\nhop=%s\nunresolved_packages=0\nunresolved_files=0\n' % hop,
    )
    write(
        os.path.join(d, 'evidence.json'),
        '{"hop":"%s","unresolved_packages":0,"unresolved_files":0}\n' % hop,
    )


def pkg_row(hop, package, version, sha, size, suite, url, filename=None):
    filename = filename or '%s_%s_amd64.deb' % (package, version)
    return {
        'hop': hop,
        'package': package,
        'version': version,
        'architecture': 'amd64',
        'source_package': package,
        'filename': filename,
        'repository_host': 'archive.ubuntu.com',
        'suite': suite,
        'component': 'main',
        'size_bytes': str(size),
        'sha256': sha,
        'original_url': url,
        'final_url': url,
        'requested': 'true',
        'downloaded': 'true',
        'installed': 'true',
        'evidence_source': 'test',
    }


def file_row(hop, filename, url, sha, size):
    return {
        'hop': hop,
        'file_type': 'deb',
        'filename': filename,
        'original_url': url,
        'final_url': url,
        'local_path': '',
        'size_bytes': str(size),
        'sha256': sha,
        'http_status': '200',
        'request_count': '1',
        'evidence_source': 'test',
    }


def write_pocket_packages(root, suite, package, version, sha, size, rel):
    path = os.path.join(
        root, 'dists', suite, 'main', 'binary-amd64', 'Packages',
    )
    body = (
        'Package: %s\nVersion: %s\nArchitecture: amd64\n'
        'Filename: %s\nSize: %s\nSHA256: %s\n\n'
        % (package, version, rel, size, sha)
    )
    write(path, body)


def hop_summaries():
    return OrderedDict([
        (X2B, OrderedDict([
            ('from_series', 'xenial'), ('to_series', 'bionic'),
            ('suites', [
                'xenial', 'xenial-updates', 'xenial-security',
                'bionic', 'bionic-updates', 'bionic-security',
            ]),
        ])),
        (B2F, OrderedDict([
            ('from_series', 'bionic'), ('to_series', 'focal'),
            ('suites', [
                'bionic', 'bionic-updates', 'bionic-security',
                'focal', 'focal-updates', 'focal-security',
            ]),
        ])),
        ('focal-to-jammy', OrderedDict([
            ('from_series', 'focal'), ('to_series', 'jammy'),
            ('suites', ['focal', 'jammy']),
        ])),
        ('jammy-to-noble', OrderedDict([
            ('from_series', 'jammy'), ('to_series', 'noble'),
            ('suites', ['jammy', 'noble']),
        ])),
    ])


def fake_parse_factory(controls):
    def fake_parse(path):
        base = os.path.basename(path)
        if base in controls:
            return dict(controls[base])
        pkg = base.split('_', 1)[0]
        return {
            'Package': pkg, 'Version': '1', 'Architecture': 'amd64',
            'Maintainer': 't', 'Description': 'd',
        }
    return fake_parse


class SharedShaPlannerTests(unittest.TestCase):
    def test_pocket_index_first_wins_no_longer_drops_second_hop(self):
        tmp = tempfile.mkdtemp(prefix='um-shared-plan-')
        try:
            generic = os.path.join(tmp, 'generic')
            body = b'iucode-shared'
            digest = hashlib.sha256(body).hexdigest()
            size = len(body)
            filename = 'iucode-tool_2.3.1-1_amd64.deb'
            url = IUCODE_URL
            for hop in HOPS:
                pkgs = []
                files = []
                if hop == X2B:
                    pkgs.append(pkg_row(
                        hop, 'iucode-tool', '2.3.1-1', digest, size,
                        'bionic', url, filename,
                    ))
                    files.append(file_row(hop, filename, url, digest, size))
                elif hop == B2F:
                    # AWS-like: suite blank, same physical .deb.
                    pkgs.append(pkg_row(
                        hop, 'iucode-tool', '2.3.1-1', digest, size,
                        '', url, filename,
                    ))
                    files.append(file_row(hop, filename, url, digest, size))
                else:
                    other_sha = hashlib.sha256((hop + 'x').encode('utf-8')).hexdigest()
                    other_name = 'hello_%s_1_amd64.deb' % hop
                    other_url = (
                        'http://archive.ubuntu.com/ubuntu/pool/main/h/hello/%s'
                        % other_name
                    )
                    pkgs.append(pkg_row(
                        hop, 'hello', '1', other_sha, 4,
                        hop.split('-to-')[-1], other_url, other_name,
                    ))
                    files.append(file_row(hop, other_name, other_url, other_sha, 4))
                seed_min_hop(generic, hop, pkgs, files=files)

            pocket = os.path.join(tmp, 'pocket')
            write_pocket_packages(
                pocket, 'bionic', 'iucode-tool', '2.3.1-1', digest, size, IUCODE_REL,
            )
            write_pocket_packages(
                pocket, 'focal-updates', 'iucode-tool', '2.3.1-1',
                digest, size, IUCODE_REL,
            )

            old = os.environ.get('UM_ALLOW_GENERIC_ONLY_DISCOVERY')
            old_h = os.environ.get('MM_HERMETIC_TEST_MODE')
            os.environ['UM_ALLOW_GENERIC_ONLY_DISCOVERY'] = '1'
            os.environ['MM_HERMETIC_TEST_MODE'] = '1'
            try:
                plan, rows, _files, _urls = bsp.build_plan(
                    generic, '',
                    resolve_missing_pool_paths=False,
                    pocket_index_root=pocket,
                    discovery_roots=OrderedDict([('generic', generic)]),
                )
            finally:
                if old is None:
                    os.environ.pop('UM_ALLOW_GENERIC_ONLY_DISCOVERY', None)
                else:
                    os.environ['UM_ALLOW_GENERIC_ONLY_DISCOVERY'] = old
                if old_h is None:
                    os.environ.pop('MM_HERMETIC_TEST_MODE', None)
                else:
                    os.environ['MM_HERMETIC_TEST_MODE'] = old_h

            hits = [
                d for d in plan.get('debs') or []
                if d.get('package') == 'iucode-tool'
            ]
            self.assertEqual(len(hits), 1, hits)
            rec = hits[0]
            self.assertEqual(sorted(rec.get('source_hops') or []), sorted([X2B, B2F]))
            prov = rec.get('hop_provenance') or {}
            self.assertEqual((prov.get(X2B) or {}).get('suite'), 'bionic')
            self.assertEqual((prov.get(B2F) or {}).get('suite'), 'focal-updates')
            self.assertEqual(rec.get('original_suite'), 'bionic')
            b2f_rows = [
                r for r in rows
                if r.get('hop') == B2F and r.get('package') == 'iucode-tool'
            ]
            self.assertEqual(len(b2f_rows), 1)
            self.assertEqual(b2f_rows[0].get('suite'), 'focal-updates')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class SharedPackageTreeTests(unittest.TestCase):
    def _shared_deb(self, tmp, extra_b2f=None):
        body = b'iucode-shared-bytes'
        digest = hashlib.sha256(body).hexdigest()
        rel = IUCODE_REL
        write_bytes(os.path.join(tmp, 'seed', rel), body)
        iucode = OrderedDict([
            ('sha256', digest),
            ('size_bytes', len(body)),
            ('relative_pool_path', rel),
            ('filename', 'iucode-tool_2.3.1-1_amd64.deb'),
            ('package', 'iucode-tool'),
            ('version', '2.3.1-1'),
            ('architecture', 'amd64'),
            ('component', 'main'),
            ('original_url', IUCODE_URL),
            ('original_suite', 'bionic'),
            ('original_pocket', 'base'),
            ('source_hops', [X2B, B2F]),
            ('hop_provenance', OrderedDict([
                (X2B, OrderedDict([('suite', 'bionic'), ('pocket', 'base')])),
                (B2F, OrderedDict([
                    ('suite', 'focal-updates'), ('pocket', 'updates'),
                ])),
            ])),
            ('seed_local_path', os.path.join(tmp, 'seed', rel)),
            ('reusable_from_seed', True),
        ])
        debs = [iucode]
        if extra_b2f:
            debs.extend(extra_b2f)
        plan = OrderedDict([
            ('validation_result', 'PASS'),
            ('profile_name', 'offline-upgrade-selective'),
            ('discovery_profiles', ['generic']),
            ('plan_checksum', 'p' * 64),
            ('discovery_artifact_checksum', 'd' * 64),
            ('hops', list(HOPS)),
            ('hop_summaries', hop_summaries()),
            ('debs', debs),
            ('upgraders', []),
            ('sizes', {}),
            ('counts', {}),
        ])
        return plan, digest, rel, body

    def _materialize(self, tmp, plan):
        plan_path = os.path.join(tmp, 'plan.json')
        write(plan_path, json.dumps(plan))
        selective = os.path.join(tmp, 'selective')
        orig = sm.parse_deb_control
        sm.parse_deb_control = fake_parse_factory({
            'iucode-tool_2.3.1-1_amd64.deb': {
                'Package': 'iucode-tool', 'Version': '2.3.1-1',
                'Architecture': 'amd64', 'Maintainer': 't',
                'Description': 'd',
            },
        })
        try:
            result = sm.materialize(
                plan_path, selective, allow_download=False, sign=False,
            )
        finally:
            sm.parse_deb_control = orig
        self.assertEqual(result['validation_result'], 'PASS')
        return selective

    def test_a_file_and_index_in_both_hops(self):
        tmp = tempfile.mkdtemp(prefix='um-shared-a-')
        try:
            plan, digest, rel, _body = self._shared_deb(tmp)
            selective = self._materialize(tmp, plan)
            staging = os.path.join(selective, 'staging')
            for hop, suite in ((X2B, 'bionic'), (B2F, 'focal-updates')):
                path = os.path.join(staging, 'hops', hop, 'ubuntu', rel)
                self.assertTrue(os.path.isfile(path), path)
                self.assertEqual(sm.file_sha256(path), digest)
                pkgs = os.path.join(
                    staging, 'hops', hop, 'ubuntu', 'dists', suite,
                    'main', 'binary-amd64', 'Packages',
                )
                self.assertTrue(os.path.isfile(pkgs), pkgs)
                body = open(pkgs).read()
                self.assertIn('Package: iucode-tool', body)
                self.assertIn(digest, body)
            ok, errors, detail = vsm.validate_per_hop_plan_membership(staging, plan)
            self.assertTrue(ok, errors or detail)
            self.assertEqual(detail.get('result'), 'PASS')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_b_missing_second_hop_file_fails(self):
        tmp = tempfile.mkdtemp(prefix='um-shared-b-')
        try:
            plan, _digest, rel, _body = self._shared_deb(tmp)
            selective = self._materialize(tmp, plan)
            staging = os.path.join(selective, 'staging')
            path = os.path.join(staging, 'hops', B2F, 'ubuntu', rel)
            os.unlink(path)
            ok, errors, detail = vsm.validate_per_hop_plan_membership(staging, plan)
            self.assertFalse(ok)
            self.assertTrue(detail.get('missing_files'), detail)
            self.assertTrue(any(B2F in e for e in errors), errors)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_c_missing_second_hop_index_fails(self):
        tmp = tempfile.mkdtemp(prefix='um-shared-c-')
        try:
            plan, _digest, rel, _body = self._shared_deb(tmp)
            selective = self._materialize(tmp, plan)
            staging = os.path.join(selective, 'staging')
            pkgs = os.path.join(
                staging, 'hops', B2F, 'ubuntu', 'dists', 'focal-updates',
                'main', 'binary-amd64', 'Packages',
            )
            write(pkgs, '')
            gz = pkgs + '.gz'
            if os.path.isfile(gz):
                os.unlink(gz)
            ok, errors, detail = vsm.validate_per_hop_plan_membership(staging, plan)
            self.assertFalse(ok)
            self.assertTrue(detail.get('missing_index'), detail)
            self.assertTrue(os.path.isfile(
                os.path.join(staging, 'hops', B2F, 'ubuntu', rel)
            ))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_f_single_plan_object_still_deduped(self):
        tmp = tempfile.mkdtemp(prefix='um-shared-f-')
        try:
            plan, digest, _rel, _body = self._shared_deb(tmp)
            matches = [
                d for d in plan['debs'] if d.get('sha256') == digest
            ]
            self.assertEqual(len(matches), 1)
            self.assertEqual(len(matches[0]['source_hops']), 2)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class AwsDependencyClosureTests(unittest.TestCase):
    def _plant_chain(self, ubuntu, include_iucode=True):
        chain = [
            ('linux-aws', 'linux-image-aws'),
            ('linux-image-aws', 'microcode-initrd'),
            ('microcode-initrd', 'intel-microcode'),
            ('intel-microcode', 'iucode-tool'),
        ]
        if include_iucode:
            chain.append(('iucode-tool', ''))
        stanzas = []
        for name, dep in chain:
            stanza = (
                'Package: %s\nVersion: 1\nArchitecture: amd64\n'
                'Filename: pool/main/x/%s_1_amd64.deb\nSize: 4\n'
                'SHA256: %s\n'
                % (name, name, hashlib.sha256(name.encode('utf-8')).hexdigest())
            )
            if dep:
                stanza += 'Depends: %s\n' % dep
            stanza += '\n'
            stanzas.append(stanza)
        write(
            os.path.join(
                ubuntu, 'dists', 'focal-updates', 'main', 'binary-amd64',
                'Packages',
            ),
            ''.join(stanzas),
        )

    def test_d_bionic_to_focal_chain_resolves(self):
        tmp = tempfile.mkdtemp(prefix='um-dep-d-')
        try:
            tree = os.path.join(tmp, 'tree')
            for hop in HOPS:
                os.makedirs(os.path.join(tree, 'hops', hop, 'ubuntu', 'pool'))
            ubuntu = os.path.join(tree, 'hops', B2F, 'ubuntu')
            self._plant_chain(ubuntu, include_iucode=True)
            plan = {
                'hops': list(HOPS),
                'debs': [
                    {'package': n, 'source_hops': [B2F]}
                    for n in (
                        'linux-aws', 'linux-image-aws', 'microcode-initrd',
                        'intel-microcode', 'iucode-tool',
                    )
                ],
            }
            ok, errors, detail = vsm.validate_aws_runtime_dependency_closure(
                tree, plan=plan, hop=B2F,
            )
            self.assertTrue(ok, errors or detail)

            self._plant_chain(ubuntu, include_iucode=False)
            ok, errors, detail = vsm.validate_aws_runtime_dependency_closure(
                tree, plan=plan, hop=B2F,
            )
            self.assertFalse(ok)
            self.assertTrue(any('iucode-tool' in e for e in errors), errors)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class ExistingGenericAwsStillCallable(unittest.TestCase):
    def test_e_tree_validator_entrypoint_unchanged(self):
        self.assertTrue(callable(aws_c.validate_tree_aws_completeness))
        self.assertTrue(callable(aws_c.validate_plan_aws_completeness))
        self.assertTrue(callable(vsm.validate_per_hop_plan_membership))
        self.assertIn('iucode-tool', aws_c.AWS_RUNTIME_DEPENDENCY_MUST_RESOLVE)


if __name__ == '__main__':
    unittest.main()
