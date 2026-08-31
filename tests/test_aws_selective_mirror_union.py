#!/usr/bin/env python3
"""Tests for multi-profile discovery union and AWS kernel flavor support."""
from __future__ import print_function

import csv
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'lib'))

import discovery_profiles as dp  # noqa: E402


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bsp = _load(
    'build_selective_mirror_plan',
    os.path.join(ROOT, 'scripts', 'build-selective-mirror-plan.py'),
)

GENERIC = os.path.join(ROOT, 'artifacts', 'upgrade-discovery-profiles', 'generic')
AWS = os.path.join(ROOT, 'artifacts', 'upgrade-discovery-profiles', 'aws')
TEMPLATES = [
    'client/dp-offline-upgrade-xenial-to-bionic.sh.in',
    'client/dp-offline-upgrade-bionic-to-focal.sh.in',
    'client/dp-offline-upgrade-focal-to-jammy.sh.in',
    'client/dp-offline-upgrade-jammy-to-noble.sh.in',
]


def write_tsv(path, fieldnames, rows):
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
            'hop', 'package', 'version', 'architecture', 'original_url', 'final_url', 'reason',
        ]),
        ('unresolved-files.tsv', [
            'hop', 'file_type', 'filename', 'original_url', 'final_url', 'reason',
        ]),
    ):
        write_tsv(os.path.join(d, name), fields, [])
    with open(os.path.join(d, 'validation.txt'), 'w') as fh:
        fh.write('VALIDATION: PASS\nhop=%s\nunresolved_packages=0\nunresolved_files=0\n' % hop)
    with open(os.path.join(d, 'evidence.json'), 'w') as fh:
        fh.write('{"hop":"%s","unresolved_packages":0,"unresolved_files":0}\n' % hop)


class DiscoveryProfileUnitTests(unittest.TestCase):
    def test_parse_profile_equals_path(self):
        self.assertEqual(
            dp.parse_discovery_root_arg('aws=/tmp/aws'),
            ('aws', '/tmp/aws'),
        )
        self.assertEqual(
            dp.parse_discovery_root_arg('/tmp/generic'),
            ('generic', '/tmp/generic'),
        )

    def test_ec2_host_normalize(self):
        self.assertEqual(
            dp.normalize_mirror_host('ap-northeast-2.ec2.archive.ubuntu.com'),
            'archive.ubuntu.com',
        )
        url = dp.normalize_discovery_url(
            'http://ap-northeast-2.ec2.archive.ubuntu.com/ubuntu/pool/main/l/linux-aws/x.deb'
        )
        self.assertTrue(url.startswith('http://archive.ubuntu.com/ubuntu/pool/'))

    def test_aws_kernel_package_name(self):
        self.assertTrue(dp.aws_kernel_package_name('linux-aws'))
        self.assertTrue(dp.aws_kernel_package_name('linux-image-5.4.0-1103-aws'))
        self.assertTrue(dp.aws_kernel_package_name('linux-modules-5.4.0-1103-aws'))
        self.assertTrue(dp.aws_kernel_package_name('linux-aws-5.4-headers-5.4.0-1103'))
        self.assertFalse(dp.aws_kernel_package_name('linux-image-generic'))
        self.assertFalse(dp.aws_kernel_package_name('linux-generic'))

    def test_union_dedup_by_sha_preserves_distinct_hashes(self):
        tmp = tempfile.mkdtemp(prefix='um-prof-')
        try:
            g = os.path.join(tmp, 'generic')
            a = os.path.join(tmp, 'aws')
            shared_sha = 'a' * 64
            aws_only_sha = 'b' * 64
            for hop in dp.HOPS:
                seed_min_hop(g, hop, [{
                    'hop': hop, 'package': 'shared-pkg', 'version': '1',
                    'architecture': 'amd64', 'source_package': 'shared-pkg',
                    'filename': 'shared-pkg_1_amd64.deb',
                    'repository_host': 'archive.ubuntu.com', 'suite': '',
                    'component': 'main', 'size_bytes': '10', 'sha256': shared_sha,
                    'original_url': 'http://archive.ubuntu.com/ubuntu/pool/main/s/shared-pkg/shared-pkg_1_amd64.deb',
                    'final_url': 'http://archive.ubuntu.com/ubuntu/pool/main/s/shared-pkg/shared-pkg_1_amd64.deb',
                    'requested': 'true', 'downloaded': 'true', 'installed': 'true',
                    'evidence_source': 'test',
                }])
                seed_min_hop(a, hop, [
                    {
                        'hop': hop, 'package': 'shared-pkg', 'version': '1',
                        'architecture': 'amd64', 'source_package': 'shared-pkg',
                        'filename': 'shared-pkg_1_amd64.deb',
                        'repository_host': 'archive.ubuntu.com', 'suite': '',
                        'component': 'main', 'size_bytes': '10', 'sha256': shared_sha,
                        'original_url': 'http://archive.ubuntu.com/ubuntu/pool/main/s/shared-pkg/shared-pkg_1_amd64.deb',
                        'final_url': 'http://archive.ubuntu.com/ubuntu/pool/main/s/shared-pkg/shared-pkg_1_amd64.deb',
                        'requested': 'true', 'downloaded': 'true', 'installed': 'true',
                        'evidence_source': 'test',
                    },
                    {
                        'hop': hop, 'package': 'linux-aws', 'version': '5.4.0',
                        'architecture': 'amd64', 'source_package': 'linux-meta-aws',
                        'filename': 'linux-aws_5.4.0_amd64.deb',
                        'repository_host': 'ap-northeast-2.ec2.archive.ubuntu.com',
                        'suite': '', 'component': 'main', 'size_bytes': '20',
                        'sha256': aws_only_sha,
                        'original_url': (
                            'http://ap-northeast-2.ec2.archive.ubuntu.com/ubuntu/'
                            'pool/main/l/linux-meta-aws/linux-aws_5.4.0_amd64.deb'
                        ),
                        'final_url': (
                            'http://ap-northeast-2.ec2.archive.ubuntu.com/ubuntu/'
                            'pool/main/l/linux-meta-aws/linux-aws_5.4.0_amd64.deb'
                        ),
                        'requested': 'true', 'downloaded': 'true', 'installed': 'true',
                        'evidence_source': 'test',
                    },
                ])
            merged = dp.load_merged_hops(
                dp.parse_discovery_root_args([
                    'generic=%s' % g,
                    'aws=%s' % a,
                ])
            )
            pkgs = merged[0]['packages']
            self.assertEqual(len(pkgs), 2)
            by_sha = {p['sha256']: p for p in pkgs}
            self.assertIn(shared_sha, by_sha)
            self.assertIn(aws_only_sha, by_sha)
            self.assertEqual(by_sha[shared_sha]['profile'], 'aws,generic')
            self.assertEqual(by_sha[aws_only_sha]['profile'], 'aws')
            self.assertIn(
                'archive.ubuntu.com',
                by_sha[aws_only_sha]['original_url'],
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


@unittest.skipUnless(
    os.path.isdir(os.path.join(AWS, 'xenial-to-bionic')),
    'AWS discovery profile manifests missing',
)
class AwsDiscoveryArtifactTests(unittest.TestCase):
    def test_aws_validation_txt_closure(self):
        for hop in dp.HOPS:
            path = os.path.join(AWS, hop, 'validation.txt')
            text = open(path).read()
            self.assertIn('VALIDATION: PASS', text)
            self.assertIn('unresolved_packages=0', text)
            self.assertIn('unresolved_files=0', text)

    def test_aws_kernel_family_present_each_hop(self):
        for hop in dp.HOPS:
            path = os.path.join(AWS, hop, 'required-packages.tsv')
            rows = list(csv.DictReader(open(path), delimiter='\t'))
            aws_rows = [r for r in rows if dp.aws_kernel_package_name(r.get('package'))]
            self.assertGreater(len(aws_rows), 0, hop)
            names = {r['package'] for r in aws_rows}
            self.assertTrue(
                any(n == 'linux-aws' or n.startswith('linux-image-') and n.endswith('-aws')
                    for n in names),
                names,
            )

    def test_build_plan_aws_alone_pass(self):
        plan, packages, _files, _urls = bsp.build_plan(
            AWS, seed_root='', profile_name='offline-upgrade-selective',
            resolve_missing_pool_paths=False,
            discovery_roots={'aws': AWS},
        )
        self.assertEqual(plan['validation_result'], 'PASS', plan.get('errors'))
        self.assertEqual(plan['counts']['unresolved_packages'], 0)
        self.assertEqual(plan['counts']['unresolved_files'], 0)
        self.assertGreater(plan['counts']['aws_kernel_package_rows'], 0)
        self.assertIn('aws', plan['discovery_profiles'])


@unittest.skipUnless(
    os.path.isdir(os.path.join(GENERIC, 'xenial-to-bionic'))
    and os.path.isdir(os.path.join(AWS, 'xenial-to-bionic')),
    'generic+aws discovery profiles missing',
)
class GenericAwsUnionPlanTests(unittest.TestCase):
    def test_union_plan_pass_and_larger_than_either(self):
        plan_g, _, _, _ = bsp.build_plan(
            GENERIC, seed_root='', resolve_missing_pool_paths=False,
            discovery_roots={'generic': GENERIC},
        )
        plan_a, _, _, _ = bsp.build_plan(
            AWS, seed_root='', resolve_missing_pool_paths=False,
            discovery_roots={'aws': AWS},
        )
        plan_u, packages, _, _ = bsp.build_plan(
            GENERIC, seed_root='', resolve_missing_pool_paths=False,
            discovery_roots={'generic': GENERIC, 'aws': AWS},
        )
        self.assertEqual(plan_u['validation_result'], 'PASS', plan_u.get('errors'))
        self.assertEqual(plan_u['counts']['unresolved_packages'], 0)
        self.assertEqual(plan_u['counts']['unresolved_files'], 0)
        self.assertGreaterEqual(
            plan_u['counts']['unique_deb_sha256'],
            max(plan_g['counts']['unique_deb_sha256'], plan_a['counts']['unique_deb_sha256']),
        )
        self.assertEqual(plan_u['discovery_profiles'], ['generic', 'aws'])
        # Provenance present on union rows
        self.assertTrue(any(r.get('profile') for r in packages))
        aws_only = [
            r for r in packages
            if r.get('profile') == 'aws' and dp.aws_kernel_package_name(r.get('package'))
        ]
        self.assertGreater(len(aws_only), 0)


class ClientTemplateAwsKernelTests(unittest.TestCase):
    def test_templates_support_aws_flavor_and_bash_hard_gate(self):
        series = [
            ('xenial', '4.4.0-1128-aws'),
            ('bionic', '5.4.0-1103-aws'),
            ('focal', '5.15.0-1084-aws'),
            ('jammy', '6.8.0-1063-aws'),
        ]
        for rel, _kr in zip(TEMPLATES, series):
            path = os.path.join(ROOT, rel)
            text = open(path).read()
            self.assertIn('*-aws)', text, rel)
            self.assertIn('KERNEL_FLAVOR_AWS=SUPPORTED', text, rel)
            self.assertIn('linux-image-aws', text, rel)
            self.assertIn('linux-aws', text, rel)
            self.assertIn('assert_aella_login_shell_bash_hard_gate', text, rel)
            self.assertIn('AELLA_BASH_HARD_GATE=FAIL', text, rel)
            self.assertIn('FAIL_AELLA_SHELL_NOT_BASH', text, rel)
            self.assertIn('chsh -s /bin/bash aella', text, rel)
            # generic path must remain
            self.assertIn('linux-image-generic', text, rel)

    def test_kernel_flavor_detection_via_bash(self):
        snippet = r'''
kernel_flavor() {
  local k
  k="$1"
  case "$k" in
    *-generic) printf 'generic' ;;
    *-generic-lpae) printf 'generic-lpae' ;;
    *-lowlatency) printf 'lowlatency' ;;
    *-aws) printf 'aws' ;;
    *) printf '%s' "${k##*-}" ;;
  esac
}
[[ "$(kernel_flavor 4.4.0-210-generic)" == "generic" ]]
[[ "$(kernel_flavor 5.15.0-1084-aws)" == "aws" ]]
[[ "$(kernel_flavor 7.0.0-1011-aws)" == "aws" ]]
echo OK
'''
        out = subprocess.check_output(['bash', '-c', snippet])
        self.assertIn(b'OK', out)


class FileManifestMaxEntriesTests(unittest.TestCase):
    def test_default_max_entries_raised(self):
        path = os.path.join(ROOT, 'scripts/lib/discover_upgrade_requirements.py')
        text = open(path).read()
        self.assertIn('max_entries=200000', text)
        self.assertIn("default='200000'", text)
        self.assertIn('max_entries > 0 and seen[0] >= max_entries', text)


class Http304ProxyGuardTests(unittest.TestCase):
    def test_proxy_strips_conditional_validators(self):
        path = os.path.join(ROOT, 'scripts/lib/discover_upgrade_http_proxy.py')
        text = open(path).read()
        self.assertIn("'if-none-match'", text)
        self.assertIn("'if-modified-since'", text)
        self.assertIn('recovered_from_http_304', text)


if __name__ == '__main__':
    unittest.main()
