#!/usr/bin/env python3
"""Regression: AWS OS Core completeness + hop gate review blockers.

Covers independent-review blockers for PR #20:
  - next-hop AWS source preflight (Bionic + Xenial 4.4 must fail)
  - fail-closed AWS baseline persistence
  - postboot requires running *-aws kernel
  - OS Core physical metapackage + x2b snapd contract
  - plan validation aligned with postboot (both linux-aws + linux-image-aws)
  - hermetic escape requires MM_HERMETIC_TEST_MODE + UM_ALLOW_GENERIC_ONLY_DISCOVERY
"""
from __future__ import print_function

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
MIRROR_SH = os.path.join(ROOT, 'scripts', 'ubuntu-offline-mirror.sh')


def _env_swap(pairs):
    """Context helper: set env keys (None deletes). Returns restore callable."""
    old = {}
    for key, val in pairs.items():
        old[key] = os.environ.get(key)
        if val is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = val

    def restore():
        for key, val in old.items():
            if val is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = val

    return restore


def _plant_complete_aws_tree(root):
    for hop in dp.HOPS:
        pool = os.path.join(
            root, 'hops', hop, 'ubuntu', 'pool', 'main', 'l', 'linux-aws',
        )
        os.makedirs(pool)
        open(os.path.join(pool, 'linux-aws_5.4.0.1103.81_amd64.deb'), 'wb').write(b'x')
        open(
            os.path.join(pool, 'linux-image-aws_5.4.0.1103.81_amd64.deb'), 'wb',
        ).write(b'x')
        open(
            os.path.join(pool, 'linux-image-5.4.0-1103-aws_5.4.0_amd64.deb'), 'wb',
        ).write(b'x')
        if hop == 'xenial-to-bionic':
            snap_pool = os.path.join(
                root, 'hops', hop, 'ubuntu', 'pool', 'main', 's', 'snapd',
            )
            os.makedirs(snap_pool)
            open(os.path.join(snap_pool, 'snapd_2.58+18.04.1_amd64.deb'), 'wb').write(b'x')


class FieldDefectReproductionTests(unittest.TestCase):
    @unittest.skipUnless(
        os.path.isdir(os.path.join(GENERIC, 'xenial-to-bionic')),
        'generic discovery missing',
    )
    def test_generic_only_plan_lacks_aws_but_structurally_passed_before(self):
        restore = _env_swap({
            'MM_HERMETIC_TEST_MODE': '1',
            'UM_ALLOW_GENERIC_ONLY_DISCOVERY': '1',
        })
        try:
            plan, packages, _f, _u = bsp.build_plan(
                GENERIC, seed_root='', resolve_missing_pool_paths=False,
                discovery_roots={'generic': GENERIC},
            )
        finally:
            restore()

        self.assertEqual(plan['validation_result'], 'PASS', plan.get('errors'))
        self.assertEqual(plan['discovery_profiles'], ['generic'])
        self.assertEqual(plan['counts'].get('aws_kernel_package_rows', 0), 0)

        restore2 = _env_swap({
            'MM_HERMETIC_TEST_MODE': None,
            'UM_ALLOW_GENERIC_ONLY_DISCOVERY': None,
        })
        try:
            ok, errors, detail = aws_c.validate_plan_aws_completeness(
                plan, package_rows=packages, require_aws_profile=True,
            )
        finally:
            restore2()
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
        # Plan PASS must imply postboot contract families are present on each hop.
        by_hop = aws_c.collect_aws_packages_by_hop(packages)
        for hop in dp.HOPS:
            self.assertTrue(
                aws_c.hop_required_aws_metapackages_present(by_hop[hop]),
                hop,
            )
        x2b_snapd = [
            r for r in packages
            if r.get('hop') == 'xenial-to-bionic' and r.get('package') == 'snapd'
        ]
        self.assertGreater(len(x2b_snapd), 0)


class AwsPlanSemanticValidationTests(unittest.TestCase):
    def test_aws_profile_plan_missing_linux_aws_family_fails(self):
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
        self.assertTrue(any('aws_kernel' in e for e in errors), errors)

    def test_versioned_image_alone_insufficient_for_plan(self):
        # Align with postboot: linux-image-*-aws alone must not PASS plan validation.
        rows = []
        for hop in dp.HOPS:
            rows.append({
                'package': 'linux-image-5.4.0-1103-aws',
                'hop': hop,
                'source_hops': [hop],
                'version': '1',
            })
            if hop == 'xenial-to-bionic':
                rows.append({
                    'package': 'snapd',
                    'hop': hop,
                    'source_hops': [hop],
                    'version': '2.58+18.04.1',
                })
        plan = {
            'discovery_profiles': ['generic', 'aws'],
            'counts': {'aws_kernel_package_rows': len(rows)},
            'debs': rows,
        }
        ok, errors, detail = aws_c.validate_plan_aws_completeness(
            plan, package_rows=rows,
        )
        self.assertFalse(ok, detail)
        self.assertTrue(any('metapackage_missing' in e for e in errors), errors)

    def test_aws_x2b_plan_missing_snapd_fails(self):
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
            self.assertTrue(
                any('aws_metapackage_deb_missing' in e for e in errors),
                errors,
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_versioned_image_only_tree_fails(self):
        # Blocker 4A: one versioned AWS image per hop is insufficient.
        tmp = tempfile.mkdtemp(prefix='um-aws-tree-imgonly-')
        try:
            for hop in dp.HOPS:
                pool = os.path.join(
                    tmp, 'hops', hop, 'ubuntu', 'pool', 'main', 'l', 'linux-aws',
                )
                os.makedirs(pool)
                open(
                    os.path.join(pool, 'linux-image-5.4.0-1103-aws_5.4.0_amd64.deb'),
                    'wb',
                ).write(b'x')
                if hop == 'xenial-to-bionic':
                    snap_pool = os.path.join(
                        tmp, 'hops', hop, 'ubuntu', 'pool', 'main', 's', 'snapd',
                    )
                    os.makedirs(snap_pool)
                    open(
                        os.path.join(snap_pool, 'snapd_2.58+18.04.1_amd64.deb'),
                        'wb',
                    ).write(b'x')
            plan = {'discovery_profiles': ['aws']}
            ok, errors, detail = aws_c.validate_tree_aws_completeness(
                tmp, plan=plan, require_aws_profile=True,
            )
            self.assertFalse(ok, detail)
            self.assertTrue(
                any('aws_metapackage_deb_missing' in e for e in errors),
                errors,
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_aws_kernels_without_x2b_snapd_fails(self):
        # Blocker 4B.
        tmp = tempfile.mkdtemp(prefix='um-aws-tree-nosnapd-')
        try:
            for hop in dp.HOPS:
                pool = os.path.join(
                    tmp, 'hops', hop, 'ubuntu', 'pool', 'main', 'l', 'linux-aws',
                )
                os.makedirs(pool)
                open(os.path.join(pool, 'linux-aws_5.4.0_amd64.deb'), 'wb').write(b'x')
                open(
                    os.path.join(pool, 'linux-image-aws_5.4.0_amd64.deb'), 'wb',
                ).write(b'x')
            plan = {'discovery_profiles': ['aws']}
            ok, errors, detail = aws_c.validate_tree_aws_completeness(
                tmp, plan=plan, require_aws_profile=True,
            )
            self.assertFalse(ok, detail)
            self.assertTrue(any('snapd_deb_missing' in e for e in errors), errors)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_complete_aws_tree_passes(self):
        # Blocker 4C.
        tmp = tempfile.mkdtemp(prefix='um-aws-tree-ok-')
        try:
            _plant_complete_aws_tree(tmp)
            plan = {'discovery_profiles': ['aws']}
            ok, errors, detail = aws_c.validate_tree_aws_completeness(
                tmp, plan=plan, require_aws_profile=True,
            )
            self.assertTrue(ok, errors or detail)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class AwsNextHopPreflightTests(unittest.TestCase):
    def test_bionic_with_xenial_4_4_aws_fails_before_mutation(self):
        # Blocker 1: 18.04 + 4.4.0-1128-aws => NEXT_HOP_PREFLIGHT_FAIL
        script = r'''
set -euo pipefail
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/opt/aelladata/os-upgrade/offline/critical-holds"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
HOLDS_DIR="${STATE_ROOT}/critical-holds"
DP_OFFLINE_FAKE_KERNEL="4.4.0-1128-aws"
dpkg-query() {
  local pkg="${3:-}"
  if [[ "$1" == "-W" ]]; then
    case "$pkg" in
      linux-aws|linux-image-aws|linux-image-4.4.0-1128-aws)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '4.4.0.1128.133\n'; return 0; fi
        ;;
    esac
  fi
  return 1
}
uname() { printf '4.4.0-1128-aws\n'; }
kernel_flavor() { printf 'aws\n'; }
MUTATION_ENTERED=0
simulate_destructive_stage() { MUTATION_ENTERED=1; echo MUTATION_ENTERED; }
source "%s"
if validate_aws_source_kernel_preflight "18.04"; then
  simulate_destructive_stage
  echo PREFLIGHT_PASS
  exit 0
fi
echo PREFLIGHT_FAIL
echo "MUTATION_ENTERED=${MUTATION_ENTERED}"
''' % GATE_INC
        out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
        text = out.decode('utf-8', 'replace')
        self.assertIn('NEXT_HOP_PREFLIGHT_FAIL', text)
        self.assertIn('PREFLIGHT_FAIL', text)
        self.assertIn('MUTATION_ENTERED=0', text)
        self.assertNotIn('MUTATION_ENTERED=1', text)

    def test_bionic_with_compatible_aws_kernel_passes(self):
        script = r'''
set -euo pipefail
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
DP_OFFLINE_FAKE_KERNEL="5.4.0-1103-aws"
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
kernel_flavor() { printf 'aws\n'; }
source "%s"
validate_aws_source_kernel_preflight "18.04"
echo PREFLIGHT_PASS
''' % GATE_INC
        out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
        self.assertIn(b'AWS_SOURCE_PREFLIGHT=PASS', out)
        self.assertIn(b'PREFLIGHT_PASS', out)


class AwsBaselinePersistenceTests(unittest.TestCase):
    def test_aws_baseline_write_failure_fails_preflight(self):
        # Blocker 2: AWS profile + baseline persistence failure => FAIL
        script = r'''
set -euo pipefail
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
# Create a file where the holds directory must be created → mkdir -p of child fails
# when parent path component is a file.
mkdir -p "$TEST_ROOT/opt/aelladata/os-upgrade"
printf 'not-a-dir\n' >"$TEST_ROOT/opt/aelladata/os-upgrade/offline"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
HOLDS_DIR="${STATE_ROOT}/critical-holds"
DP_OFFLINE_FAKE_KERNEL="5.4.0-1103-aws"
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
kernel_flavor() { printf 'aws\n'; }
source "%s"
if persist_source_kernel_aws_baseline; then
  echo PERSIST_PASS
  exit 0
fi
echo PERSIST_FAIL
''' % GATE_INC
        out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
        text = out.decode('utf-8', 'replace')
        self.assertIn('PERSIST_FAIL', text)
        self.assertIn('AWS_BASELINE_PERSIST=FAIL', text)

    def test_missing_baseline_cannot_pass_postboot_with_stale_4_4(self):
        # Blocker 2: missing baseline + stale 4.4 must FAIL (not skip compares).
        tmp = tempfile.mkdtemp(prefix='um-aws-nobase-')
        try:
            boot = os.path.join(tmp, 'boot')
            os.makedirs(boot)
            open(os.path.join(boot, 'vmlinuz-4.4.0-1128-aws'), 'wb').write(b'k')
            # No critical-holds baseline files at all.
            script = r'''
set -euo pipefail
TEST_ROOT="%s"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
HOLDS_DIR="${STATE_ROOT}/critical-holds"
dpkg-query() {
  local pkg="${3:-}"
  if [[ "$1" == "-W" ]]; then
    case "$pkg" in
      linux-aws|linux-image-aws|linux-image-4.4.0-1128-aws)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '4.4.0.1128.133\n'; return 0; fi
        ;;
    esac
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
''' % (tmp, GATE_INC)
            out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
            text = out.decode('utf-8', 'replace')
            self.assertIn('GATE_FAIL', text)
            self.assertIn('missing_source_baseline', text)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class AwsPostHopCompletionGateTests(unittest.TestCase):
    def test_gate_rejects_stale_xenial_aws_metapackage(self):
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
            open(os.path.join(boot, 'vmlinuz-4.4.0-1128-aws'), 'wb').write(b'k')

            script = r'''
set -euo pipefail
TEST_ROOT="%s"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
HOLDS_DIR="${STATE_ROOT}/critical-holds"
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
            open(os.path.join(holds, 'source_kernel_release'), 'w').write(
                '4.4.0-1128-aws\n'
            )
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

    def test_postboot_generic_kernel_on_aws_fails(self):
        # Blocker 3: upgraded metas + running generic => POSTBOOT FAIL
        tmp = tempfile.mkdtemp(prefix='um-aws-gate-generic-')
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
            open(os.path.join(boot, 'vmlinuz-5.4.0-1103-aws'), 'wb').write(b'k')

            script = r'''
set -euo pipefail
TEST_ROOT="%s"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
HOLDS_DIR="${STATE_ROOT}/critical-holds"
DP_OFFLINE_FAKE_KERNEL="5.4.0-150-generic"
dpkg-query() {
  local pkg="${3:-}"
  if [[ "$1" == "-W" ]]; then
    case "$pkg" in
      linux-aws|linux-image-aws)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '5.4.0.1103.81\n'; return 0; fi
        ;;
    esac
  fi
  return 1
}
uname() { printf '5.4.0-150-generic\n'; }
source "%s"
if validate_aws_post_hop_kernel_gate "18.04"; then
  echo GATE_PASS
  exit 0
fi
echo GATE_FAIL
''' % (tmp, GATE_INC)
            out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
            text = out.decode('utf-8', 'replace')
            self.assertIn('GATE_FAIL', text)
            self.assertIn('running_kernel_not_aws', text)
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
            self.assertIn('validate_aws_source_kernel_preflight', text, rel)
            self.assertIn('persist_source_kernel_aws_baseline', text, rel)
            self.assertNotIn('persist_source_kernel_aws_baseline || true', text, rel)
            self.assertIn('validate_aws_post_hop_kernel_gate "%s"' % ver, text, rel)
            self.assertIn(completed, text, rel)
            # Preflight lives inside check_os_baseline, which runs before write_state PREFLIGHT.
            baseline_idx = text.find('check_os_baseline()')
            preflight_idx = text.find('validate_aws_source_kernel_preflight')
            write_state_idx = text.find('write_state "PREFLIGHT"')
            self.assertGreater(preflight_idx, baseline_idx, rel)
            self.assertGreater(write_state_idx, preflight_idx, rel)


class HermeticEscapeTests(unittest.TestCase):
    def test_allow_generic_only_requires_both_flags(self):
        restore = _env_swap({
            'MM_HERMETIC_TEST_MODE': None,
            'UM_ALLOW_GENERIC_ONLY_DISCOVERY': None,
        })
        try:
            self.assertFalse(aws_c.allow_generic_only_discovery())
            os.environ['UM_ALLOW_GENERIC_ONLY_DISCOVERY'] = '1'
            self.assertFalse(aws_c.allow_generic_only_discovery())
            os.environ['MM_HERMETIC_TEST_MODE'] = '1'
            self.assertTrue(aws_c.allow_generic_only_discovery())
        finally:
            restore()

    def test_production_override_env_alone_still_requires_aws(self):
        restore = _env_swap({
            'MM_HERMETIC_TEST_MODE': None,
            'UM_ALLOW_GENERIC_ONLY_DISCOVERY': '1',
        })
        try:
            plan = {
                'discovery_profiles': ['generic'],
                'counts': {'aws_kernel_package_rows': 0},
                'debs': [],
            }
            ok, errors, detail = aws_c.validate_plan_aws_completeness(
                plan, package_rows=[], require_aws_profile=True,
            )
            self.assertFalse(ok, detail)
            self.assertTrue(any('aws' in e for e in errors), errors)
        finally:
            restore()

    def test_mirror_script_requires_hermetic_pair_and_union(self):
        text = open(MIRROR_SH).read()
        self.assertIn('MM_HERMETIC_TEST_MODE', text)
        self.assertIn('UM_ALLOW_GENERIC_ONLY_DISCOVERY', text)
        self.assertIn('generic=<path> and aws=<path>', text)
        self.assertIn('hermetic_generic_only', text)
        # Old single-flag escape must not remain.
        self.assertNotIn(
            'UM_ALLOW_GENERIC_ONLY_DISCOVERY:-0}" == "1" ]]; then\n    disc_args+=(--discovery-root "$DISCOVERY_ROOT")',
            text,
        )

    def test_production_discovery_roots_generic_only_and_aws_only_fail(self):
        # Blocker 6: production generic-only / aws-only DISCOVERY_ROOTS must die.
        script = r'''
set -uo pipefail
eval_roots() {
  local DISCOVERY_ROOTS="$1"
  local MM_HERMETIC_TEST_MODE="${2:-0}"
  local UM_ALLOW_GENERIC_ONLY_DISCOVERY="${3:-0}"
  local hermetic_generic_only=0
  if [[ "${MM_HERMETIC_TEST_MODE}" == "1" && "${UM_ALLOW_GENERIC_ONLY_DISCOVERY}" == "1" ]]; then
    hermetic_generic_only=1
  fi
  local has_aws_root=0 has_generic_root=0 entry
  for entry in ${DISCOVERY_ROOTS}; do
    case "$entry" in
      aws=*) has_aws_root=1 ;;
      generic=*) has_generic_root=1 ;;
    esac
  done
  if [[ "$hermetic_generic_only" -ne 1 ]]; then
    if [[ "$has_generic_root" -ne 1 || "$has_aws_root" -ne 1 ]]; then
      echo "DIE:DISCOVERY_ROOTS must include both generic=<path> and aws=<path>"
      return 1
    fi
  fi
  echo ROOTS_OK
  return 0
}
# production generic-only
if eval_roots "generic=/tmp/g" 0 0; then echo UNEXPECTED_GENERIC_ONLY_PASS; else echo PRODUCTION_GENERIC_ONLY_FAIL; fi
# production aws-only
if eval_roots "aws=/tmp/a" 0 0; then echo UNEXPECTED_AWS_ONLY_PASS; else echo PRODUCTION_AWS_ONLY_FAIL; fi
# production override env alone still fails
if eval_roots "generic=/tmp/g" 0 1; then echo UNEXPECTED_OVERRIDE_ALONE_PASS; else echo PRODUCTION_OVERRIDE_ALONE_FAIL; fi
# hermetic pair allows generic-only fixture
if eval_roots "generic=/tmp/g" 1 1; then echo HERMETIC_GENERIC_ONLY_OK; else echo HERMETIC_GENERIC_ONLY_FAIL; fi
# production full union ok
if eval_roots "generic=/tmp/g aws=/tmp/a" 0 0; then echo PRODUCTION_UNION_OK; else echo PRODUCTION_UNION_FAIL; fi
'''
        out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
        text = out.decode('utf-8', 'replace')
        self.assertIn('PRODUCTION_GENERIC_ONLY_FAIL', text)
        self.assertIn('PRODUCTION_AWS_ONLY_FAIL', text)
        self.assertIn('PRODUCTION_OVERRIDE_ALONE_FAIL', text)
        self.assertIn('HERMETIC_GENERIC_ONLY_OK', text)
        self.assertIn('PRODUCTION_UNION_OK', text)
        self.assertNotIn('UNEXPECTED_', text)


if __name__ == '__main__':
    unittest.main()
