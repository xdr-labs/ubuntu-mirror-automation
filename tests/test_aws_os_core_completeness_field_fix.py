#!/usr/bin/env python3
"""Regression: AWS OS Core completeness field defects (Xenial→Bionic).

Reproduces the confirmed failure mode:
  - generic-only selective plan claims offline-upgrade-selective profile
  - old structural validation would PASS with aws_kernel_package_rows=0
  - physical tree can lack linux-aws family .deb files
  - post-hop gate previously accepted VERSION_ID alone

After the fix:
  - aws-inclusive plans must contain AWS kernels (+ xenial→bionic snapd)
  - semantic validators fail closed on AWS-incomplete artifacts
  - AWS post-hop gate rejects stale source linux-aws metapackages
"""
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

import aws_os_core_completeness as aws_c  # noqa: E402
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
GATE_INC = os.path.join(ROOT, 'client', 'dp-postboot-aws-kernel-gate.sh.inc')


class FieldDefectReproductionTests(unittest.TestCase):
    """Demonstrate old failure mode against current fixtures."""

    @unittest.skipUnless(
        os.path.isdir(os.path.join(GENERIC, 'xenial-to-bionic')),
        'generic discovery missing',
    )
    def test_generic_only_plan_lacks_aws_but_structurally_passed_before(self):
        # Hermetic escape: allow building the historical generic-only plan shape.
        old = os.environ.get('UM_ALLOW_GENERIC_ONLY_DISCOVERY')
        os.environ['UM_ALLOW_GENERIC_ONLY_DISCOVERY'] = '1'
        try:
            plan, packages, _f, _u = bsp.build_plan(
                GENERIC, seed_root='', resolve_missing_pool_paths=False,
                discovery_roots={'generic': GENERIC},
            )
        finally:
            if old is None:
                os.environ.pop('UM_ALLOW_GENERIC_ONLY_DISCOVERY', None)
            else:
                os.environ['UM_ALLOW_GENERIC_ONLY_DISCOVERY'] = old

        self.assertEqual(plan['validation_result'], 'PASS', plan.get('errors'))
        self.assertEqual(plan['discovery_profiles'], ['generic'])
        self.assertEqual(plan['counts'].get('aws_kernel_package_rows', 0), 0)
        aws_pkgs = [
            r for r in packages
            if dp.aws_kernel_package_name(r.get('package'))
        ]
        self.assertEqual(aws_pkgs, [])
        x2b_snapd = [
            r for r in packages
            if r.get('hop') == 'xenial-to-bionic' and r.get('package') == 'snapd'
        ]
        self.assertEqual(x2b_snapd, [])

        # Old logic: structural plan PASS with zero AWS rows.
        # New semantic validator must FAIL when AWS coverage is required.
        ok, errors, detail = aws_c.validate_plan_aws_completeness(
            plan, package_rows=packages, require_aws_profile=True,
        )
        self.assertFalse(ok, detail)
        self.assertTrue(any('aws' in e for e in errors), errors)

    @unittest.skipUnless(
        os.path.isdir(os.path.join(GENERIC, 'xenial-to-bionic'))
        and os.path.isdir(os.path.join(AWS, 'xenial-to-bionic')),
        'generic+aws discovery missing',
    )
    def test_union_plan_includes_aws_kernels_and_x2b_snapd(self):
        plan, packages, _f, _u = bsp.build_plan(
            GENERIC, seed_root='', resolve_missing_pool_paths=False,
            discovery_roots={'generic': GENERIC, 'aws': AWS},
        )
        self.assertEqual(plan['validation_result'], 'PASS', plan.get('errors'))
        self.assertEqual(plan['discovery_profiles'], ['generic', 'aws'])
        self.assertGreater(plan['counts']['aws_kernel_package_rows'], 0)
        ok, errors, detail = aws_c.validate_plan_aws_completeness(
            plan, package_rows=packages,
        )
        self.assertTrue(ok, errors or detail)
        x2b_aws = [
            r for r in packages
            if r.get('hop') == 'xenial-to-bionic'
            and dp.aws_kernel_package_name(r.get('package'))
        ]
        self.assertTrue(
            any(r.get('package') in ('linux-aws', 'linux-image-aws')
                or (r.get('package', '').startswith('linux-image-')
                    and r.get('package', '').endswith('-aws'))
                for r in x2b_aws),
            [r.get('package') for r in x2b_aws],
        )
        x2b_snapd = [
            r for r in packages
            if r.get('hop') == 'xenial-to-bionic' and r.get('package') == 'snapd'
        ]
        self.assertGreater(len(x2b_snapd), 0)


class AwsPlanSemanticValidationTests(unittest.TestCase):
    def test_aws_profile_plan_missing_linux_aws_family_fails(self):
        # Case 3: discovery_profiles includes aws but plan rows omit linux-aws.
        rows = [
            {
                'package': 'bash',
                'hop': hop,
                'source_hops': [hop],
                'version': '1',
            }
            for hop in dp.HOPS
        ]
        plan = {
            'profile_name': 'offline-upgrade-selective',
            'discovery_profiles': ['generic', 'aws'],
            'counts': {'aws_kernel_package_rows': 0},
            'debs': rows,
        }
        ok, errors, detail = aws_c.validate_plan_aws_completeness(
            plan, package_rows=rows,
        )
        self.assertFalse(ok, detail)
        self.assertTrue(
            any('aws_kernel' in e for e in errors),
            errors,
        )

    def test_aws_x2b_plan_missing_snapd_fails(self):
        # Case 4: AWS xenial→bionic discovery requires snapd; kernels alone insufficient.
        rows = []
        for hop in dp.HOPS:
            rows.append({
                'package': 'linux-aws',
                'hop': hop,
                'source_hops': [hop],
                'version': '1',
            })
            rows.append({
                'package': 'linux-image-aws',
                'hop': hop,
                'source_hops': [hop],
                'version': '1',
            })
        plan = {
            'profile_name': 'offline-upgrade-selective',
            'discovery_profiles': ['generic', 'aws'],
            'counts': {'aws_kernel_package_rows': len(rows)},
            'debs': rows,
        }
        ok, errors, detail = aws_c.validate_plan_aws_completeness(
            plan, package_rows=rows,
        )
        self.assertFalse(ok, detail)
        self.assertTrue(any('snapd_missing_hop' in e for e in errors), errors)
        self.assertTrue(
            any('xenial-to-bionic' in e for e in errors if 'snapd' in e),
            errors,
        )


class AwsTreeSemanticValidationTests(unittest.TestCase):
    def test_empty_tree_fails_when_aws_required(self):
        tmp = tempfile.mkdtemp(prefix='um-aws-tree-')
        try:
            for hop in dp.HOPS:
                os.makedirs(os.path.join(tmp, 'hops', hop, 'ubuntu', 'pool', 'main'))
            plan = {
                'profile_name': 'offline-upgrade-selective',
                'discovery_profiles': ['generic', 'aws'],
                'counts': {'aws_kernel_package_rows': 0},
            }
            ok, errors, detail = aws_c.validate_tree_aws_completeness(
                tmp, plan=plan,
            )
            self.assertFalse(ok, detail)
            self.assertTrue(any('aws_deb_missing' in e for e in errors), errors)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_tree_with_aws_debs_passes(self):
        tmp = tempfile.mkdtemp(prefix='um-aws-tree-ok-')
        try:
            for hop in dp.HOPS:
                pool = os.path.join(
                    tmp, 'hops', hop, 'ubuntu', 'pool', 'main', 'l', 'linux-aws',
                )
                os.makedirs(pool)
                open(os.path.join(pool, 'linux-aws_5.4.0_amd64.deb'), 'wb').write(b'x')
                open(
                    os.path.join(pool, 'linux-image-5.4.0-1103-aws_5.4.0_amd64.deb'),
                    'wb',
                ).write(b'x')
            plan = {
                'discovery_profiles': ['aws'],
                'counts': {'aws_kernel_package_rows': 8},
            }
            ok, errors, detail = aws_c.validate_tree_aws_completeness(
                tmp, plan=plan,
            )
            self.assertTrue(ok, errors or detail)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class AwsPostHopCompletionGateTests(unittest.TestCase):
    def test_gate_rejects_stale_xenial_aws_metapackage(self):
        self.assertTrue(os.path.isfile(GATE_INC))
        tmp = tempfile.mkdtemp(prefix='um-aws-gate-')
        try:
            holds = os.path.join(tmp, 'opt/aelladata/os-upgrade/offline/critical-holds')
            boot = os.path.join(tmp, 'boot')
            os.makedirs(holds)
            os.makedirs(boot)
            open(os.path.join(holds, 'source_kernel_flavor'), 'w').write('aws\n')
            open(os.path.join(holds, 'source_kernel_release'), 'w').write(
                '4.4.0-1128-aws\n'
            )
            open(os.path.join(holds, 'source_linux_aws_version'), 'w').write(
                '4.4.0.1128.133\n'
            )
            open(os.path.join(holds, 'source_linux_image_aws_version'), 'w').write(
                '4.4.0.1128.133\n'
            )
            # Stale metapackage still present; a boot aws vmlinuz exists (insufficient).
            open(os.path.join(boot, 'vmlinuz-4.4.0-1128-aws'), 'wb').write(b'k')

            script = r'''
set -euo pipefail
TEST_ROOT="%s"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
HOLDS_DIR="${STATE_ROOT}/critical-holds"
# Fake dpkg-query: still on Xenial AWS metapackage versions.
dpkg-query() {
  if [[ "$1" == "-W" && "$3" == "linux-aws" ]]; then
    if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
    if [[ "$2" == *Version* ]]; then printf '4.4.0.1128.133\n'; return 0; fi
  fi
  if [[ "$1" == "-W" && "$3" == "linux-image-aws" ]]; then
    if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
    if [[ "$2" == *Version* ]]; then printf '4.4.0.1128.133\n'; return 0; fi
  fi
  return 1
}
uname() { printf '4.4.0-1128-aws\n'; }
source "%s"
if validate_aws_post_hop_kernel_gate "18.04"; then
  echo GATE_PASS
  exit 0
fi
echo GATE_FAIL
exit 0
''' % (tmp, GATE_INC)
            out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
            text = out.decode('utf-8', 'replace')
            self.assertIn('GATE_FAIL', text)
            self.assertIn('stale_linux-aws_metapackage', text)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_gate_passes_when_aws_metapackage_upgraded(self):
        tmp = tempfile.mkdtemp(prefix='um-aws-gate-ok-')
        try:
            holds = os.path.join(tmp, 'opt/aelladata/os-upgrade/offline/critical-holds')
            boot = os.path.join(tmp, 'boot')
            os.makedirs(holds)
            os.makedirs(boot)
            open(os.path.join(holds, 'source_kernel_flavor'), 'w').write('aws\n')
            open(os.path.join(holds, 'source_linux_aws_version'), 'w').write(
                '4.4.0.1128.133\n'
            )
            open(os.path.join(holds, 'source_linux_image_aws_version'), 'w').write(
                '4.4.0.1128.133\n'
            )
            open(os.path.join(boot, 'vmlinuz-5.4.0-1103-aws'), 'wb').write(b'k')

            script = r'''
set -euo pipefail
TEST_ROOT="%s"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
HOLDS_DIR="${STATE_ROOT}/critical-holds"
dpkg-query() {
  local pkg="${3:-}"
  if [[ "$1" == "-W" ]]; then
    case "$pkg" in
      linux-aws|linux-image-aws|linux-image-5.4.0-1103-aws)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '5.4.0.1103.81\n'; return 0; fi
        ;;
    esac
  fi
  return 1
}
uname() { printf '5.4.0-1103-aws\n'; }
source "%s"
validate_aws_post_hop_kernel_gate "18.04"
echo GATE_PASS
''' % (tmp, GATE_INC)
            out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
            self.assertIn(b'GATE_PASS', out)
            self.assertIn(b'AWS_POST_HOP_KERNEL_GATE=PASS', out)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_gate_skips_non_aws(self):
        script = r'''
set -euo pipefail
TEST_ROOT=$(mktemp -d)
mkdir -p "$TEST_ROOT/opt/aelladata/os-upgrade/offline/critical-holds"
printf 'generic\n' >"$TEST_ROOT/opt/aelladata/os-upgrade/offline/critical-holds/source_kernel_flavor"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
HOLDS_DIR="${STATE_ROOT}/critical-holds"
dpkg-query() { return 1; }
uname() { printf '4.4.0-210-generic\n'; }
source "%s"
validate_aws_post_hop_kernel_gate "18.04"
echo SKIP_OK
rm -rf "$TEST_ROOT"
''' % GATE_INC
        out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
        self.assertIn(b'SKIP_OK', out)
        self.assertIn(b'AWS_POST_HOP_KERNEL_GATE=SKIP', out)


class ClientTemplateAwsGateWiringTests(unittest.TestCase):
    def test_templates_include_gate_and_completed_hook(self):
        pairs = [
            ('client/dp-offline-upgrade-xenial-to-bionic.sh.in', '18.04', 'COMPLETED_BIONIC'),
            ('client/dp-offline-upgrade-bionic-to-focal.sh.in', '20.04', 'COMPLETED_FOCAL'),
            ('client/dp-offline-upgrade-focal-to-jammy.sh.in', '22.04', 'COMPLETED_JAMMY'),
            ('client/dp-offline-upgrade-jammy-to-noble.sh.in', '24.04', 'COMPLETED_NOBLE'),
        ]
        for rel, ver, completed in pairs:
            text = open(os.path.join(ROOT, rel)).read()
            self.assertIn('@@AWS_KERNEL_GATE_LIB@@', text, rel)
            self.assertIn('persist_source_kernel_aws_baseline', text, rel)
            self.assertIn('validate_aws_post_hop_kernel_gate "%s"' % ver, text, rel)
            self.assertIn(completed, text, rel)


class PlanSelectiveShellFailClosedTests(unittest.TestCase):
    def test_mirror_script_refuses_silent_generic_only_fallback(self):
        path = os.path.join(ROOT, 'scripts', 'ubuntu-offline-mirror.sh')
        text = open(path).read()
        self.assertIn('refusing generic-only selective plan', text)
        self.assertIn('DISCOVERY_ROOTS must include aws=', text)
        self.assertIn('UM_ALLOW_GENERIC_ONLY_DISCOVERY', text)


if __name__ == '__main__':
    unittest.main()
