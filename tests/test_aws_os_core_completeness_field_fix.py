#!/usr/bin/env python3
"""Regression: AWS OS Core completeness + hop gate review blockers.

Covers independent-review blockers for PR #20:
  - discovery-derived AWS semantic contract (not major.minor floors)
  - next-hop AWS source preflight (Bionic + Xenial 4.4 / wrong series must fail)
  - pre-reboot target AWS kernel readiness gate
  - postboot target-contract COMPLETED_* gate
  - OS Core exact identity validation (version/arch/sha contract)
  - standalone planner CLI fail-closed (generic+aws unless hermetic pair)
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
            self.assertIn('validate_aws_target_kernel_pre_reboot "%s"' % ver, text, rel)
            self.assertIn('validate_aws_post_hop_kernel_gate "%s"' % ver, text, rel)
            self.assertIn(completed, text, rel)
            # Preflight lives inside check_os_baseline, which runs before write_state PREFLIGHT.
            baseline_idx = text.find('check_os_baseline()')
            preflight_idx = text.find('validate_aws_source_kernel_preflight')
            write_state_idx = text.find('write_state "PREFLIGHT"')
            self.assertGreater(preflight_idx, baseline_idx, rel)
            self.assertGreater(write_state_idx, preflight_idx, rel)
            # Pre-reboot gate must run before the reboot_if_success *call*.
            prereboot_idx = text.find('validate_aws_target_kernel_pre_reboot')
            # Function definition appears earlier; locate the invocation after the gate.
            reboot_call_idx = text.find('\n  reboot_if_success\n', prereboot_idx)
            self.assertGreater(prereboot_idx, 0, rel)
            self.assertGreater(reboot_call_idx, prereboot_idx, rel)


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


def _discovery_union_contract():
    """Build the real generic∪aws discovery-derived AWS semantic contract."""
    from discovery_profiles import load_merged_hops, parse_discovery_root_args
    roots = parse_discovery_root_args([
        'generic=%s' % GENERIC,
        'aws=%s' % AWS,
    ])
    hops = load_merged_hops(roots)
    rows = []
    for hop_data in hops:
        hop = hop_data['hop']
        for row in hop_data['packages']:
            rr = dict(row)
            rr['hop'] = hop
            rr.setdefault('source_hops', [hop])
            rows.append(rr)
    contract, errs = aws_c.build_aws_semantic_contract(
        rows, discovery_profiles=list(roots.keys()),
    )
    if errs:
        raise AssertionError(errs)
    return contract, rows


def _plant_contract_tree(root, contract, mutate_hop=None, mutate_fn=None):
    """Plant pool filenames matching contract identities (per-hop, not one ABI)."""
    for hop, hop_c in (contract.get('hops') or {}).items():
        identities = list(aws_c.iter_contract_identities(hop_c))
        if mutate_hop == hop and mutate_fn:
            identities = mutate_fn(list(identities))
        for ident in identities:
            pkg = ident['package']
            ver = ident['version']
            arch = ident.get('architecture') or 'amd64'
            letter = pkg[0] if pkg else 'x'
            pool = os.path.join(
                root, 'hops', hop, 'ubuntu', 'pool', 'main', letter, pkg,
            )
            os.makedirs(pool, exist_ok=True)
            base = '%s_%s_%s.deb' % (pkg, ver, arch)
            with open(os.path.join(pool, base), 'wb') as fh:
                fh.write(b'x')


class AwsSemanticContractAuthorityTests(unittest.TestCase):
    @unittest.skipUnless(
        os.path.isdir(os.path.join(AWS, 'xenial-to-bionic')),
        'aws discovery missing',
    )
    def test_union_plan_embeds_per_hop_discovery_contract(self):
        plan, packages, _f, _u = bsp.build_plan(
            GENERIC, seed_root='', resolve_missing_pool_paths=False,
            discovery_roots={'generic': GENERIC, 'aws': AWS},
        )
        self.assertEqual(plan['validation_result'], 'PASS', plan.get('errors'))
        contract = plan.get('aws_semantic_contract') or {}
        self.assertEqual(contract.get('schema_version'), 1)
        hops = contract.get('hops') or {}
        self.assertEqual(set(hops.keys()), set(dp.HOPS))
        # Must be per-hop discovery identities — not one 5.4 package for all.
        versions = {
            h: (hops[h].get('linux_aws') or {}).get('version') for h in dp.HOPS
        }
        self.assertEqual(versions['xenial-to-bionic'], '5.4.0.1103.81')
        self.assertIn('5.15', versions['bionic-to-focal'])
        self.assertIn('6.8', versions['focal-to-jammy'])
        self.assertIn('7.0', versions['jammy-to-noble'])
        self.assertEqual(len(set(versions.values())), 4)
        x2b = hops['xenial-to-bionic']
        self.assertEqual((x2b.get('snapd') or {}).get('version'), '2.58+18.04.1')
        self.assertEqual(x2b.get('expected_kernel_releases'), ['5.4.0-1103-aws'])
        # Floors are not authoritative in the gate include.
        gate = open(GATE_INC).read()
        self.assertNotIn('aws_series_kernel_floor', gate)
        self.assertIn('aws_contract_load_for_version_id', open(
            os.path.join(ROOT, 'client', 'dp-aws-semantic-contract.sh.inc')
        ).read())


class AwsContractPreflightTests(unittest.TestCase):
    def test_bionic_wrong_newer_release_aws_stack_fails(self):
        script = r'''
set -euo pipefail
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
DP_OFFLINE_FAKE_KERNEL="6.8.0-1063-aws"
dpkg-query() {
  local pkg="${3:-}"
  if [[ "$1" == "-W" ]]; then
    case "$pkg" in
      linux-aws|linux-image-aws|linux-image-6.8.0-1063-aws)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '6.8.0-1063.66~22.04.1\n'; return 0; fi
        ;;
    esac
  fi
  return 1
}
uname() { printf '6.8.0-1063-aws\n'; }
kernel_flavor() { printf 'aws\n'; }
source "%s"
source "%s"
if validate_aws_source_kernel_preflight "18.04"; then
  echo PREFLIGHT_PASS
  exit 0
fi
echo PREFLIGHT_FAIL
''' % (
            os.path.join(ROOT, 'client', 'dp-aws-semantic-contract.sh.inc'),
            GATE_INC,
        )
        out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
        text = out.decode('utf-8', 'replace')
        self.assertIn('PREFLIGHT_FAIL', text)
        self.assertIn('NEXT_HOP_PREFLIGHT_FAIL', text)
        self.assertIn('not_source_contract', text)

    def test_bionic_valid_hwe_discovery_contract_passes(self):
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
source "%s"
validate_aws_source_kernel_preflight "18.04"
echo PREFLIGHT_PASS
''' % (
            os.path.join(ROOT, 'client', 'dp-aws-semantic-contract.sh.inc'),
            GATE_INC,
        )
        out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
        self.assertIn(b'AWS_SOURCE_PREFLIGHT=PASS', out)
        self.assertIn(b'PREFLIGHT_PASS', out)


class AwsPreRebootTargetGateTests(unittest.TestCase):
    def _script(self, tmp, dpkg_case, boot_files, expect_pass=False):
        for rel, content in boot_files:
            path = os.path.join(tmp, rel.lstrip('/'))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'wb') as fh:
                fh.write(content)
        holds = os.path.join(tmp, 'opt/aelladata/os-upgrade/offline/critical-holds')
        os.makedirs(holds, exist_ok=True)
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
        return r'''
set -euo pipefail
TEST_ROOT="%s"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
HOLDS_DIR="${STATE_ROOT}/critical-holds"
dpkg-query() {
  local pkg="${3:-}"
  if [[ "$1" == "-W" ]]; then
    case "$pkg" in
%s
    esac
  fi
  return 1
}
uname() { printf '4.4.0-1128-aws\n'; }
source "%s"
source "%s"
if validate_aws_target_kernel_pre_reboot "18.04"; then
  echo PRE_REBOOT_PASS
  exit 0
fi
echo PRE_REBOOT_FAIL
''' % (
            tmp,
            dpkg_case,
            os.path.join(ROOT, 'client', 'dp-aws-semantic-contract.sh.inc'),
            GATE_INC,
        )

    def test_pre_reboot_missing_target_aws_image_fails(self):
        tmp = tempfile.mkdtemp(prefix='um-aws-prereboot-noimg-')
        try:
            dpkg_case = r'''
      linux-aws|linux-image-aws)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '5.4.0.1103.81\n'; return 0; fi
        ;;
'''
            script = self._script(tmp, dpkg_case, [])
            out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
            text = out.decode('utf-8', 'replace')
            self.assertIn('PRE_REBOOT_FAIL', text)
            self.assertIn('PRE_REBOOT_AWS_TARGET_GATE=FAIL', text)
            self.assertIn('AUTOMATIC_REBOOT_NOT_STARTED', text)
            self.assertIn('target_versioned_aws_image_not_installed', text)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_pre_reboot_missing_target_initrd_fails(self):
        tmp = tempfile.mkdtemp(prefix='um-aws-prereboot-noinitrd-')
        try:
            dpkg_case = r'''
      linux-aws|linux-image-aws|linux-image-5.4.0-1103-aws)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '5.4.0.1103.81\n'; return 0; fi
        ;;
'''
            script = self._script(
                tmp, dpkg_case,
                [('/boot/vmlinuz-5.4.0-1103-aws', b'k')],
            )
            out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
            text = out.decode('utf-8', 'replace')
            self.assertIn('PRE_REBOOT_FAIL', text)
            self.assertIn('missing_target_initrd', text)
            self.assertIn('AUTOMATIC_REBOOT_NOT_STARTED', text)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_pre_reboot_complete_target_aws_state_passes(self):
        tmp = tempfile.mkdtemp(prefix='um-aws-prereboot-ok-')
        try:
            dpkg_case = r'''
      linux-aws|linux-image-aws|linux-image-5.4.0-1103-aws)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '5.4.0.1103.81\n'; return 0; fi
        ;;
'''
            script = self._script(
                tmp, dpkg_case,
                [
                    ('/boot/vmlinuz-5.4.0-1103-aws', b'k'),
                    ('/boot/initrd.img-5.4.0-1103-aws', b'i'),
                ],
            )
            out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
            text = out.decode('utf-8', 'replace')
            self.assertIn('PRE_REBOOT_PASS', text)
            self.assertIn('PRE_REBOOT_AWS_TARGET_GATE=PASS', text)
            self.assertNotIn('AUTOMATIC_REBOOT_NOT_STARTED', text)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class AwsPostbootContractTests(unittest.TestCase):
    def test_postboot_running_kernel_not_in_target_contract_fails(self):
        tmp = tempfile.mkdtemp(prefix='um-aws-postboot-wrongkr-')
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
            open(os.path.join(boot, 'vmlinuz-6.8.0-1063-aws'), 'wb').write(b'k')
            script = r'''
set -euo pipefail
TEST_ROOT="%s"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
HOLDS_DIR="${STATE_ROOT}/critical-holds"
DP_OFFLINE_FAKE_KERNEL="6.8.0-1063-aws"
dpkg-query() {
  local pkg="${3:-}"
  if [[ "$1" == "-W" ]]; then
    case "$pkg" in
      linux-aws|linux-image-aws)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '5.4.0.1103.81\n'; return 0; fi
        ;;
      linux-image-6.8.0-1063-aws)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '6.8.0-1063.66~22.04.1\n'; return 0; fi
        ;;
    esac
  fi
  return 1
}
uname() { printf '6.8.0-1063-aws\n'; }
source "%s"
source "%s"
if validate_aws_post_hop_kernel_gate "18.04"; then
  echo GATE_PASS
  exit 0
fi
echo GATE_FAIL
''' % (
                tmp,
                os.path.join(ROOT, 'client', 'dp-aws-semantic-contract.sh.inc'),
                GATE_INC,
            )
            out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
            text = out.decode('utf-8', 'replace')
            self.assertIn('GATE_FAIL', text)
            self.assertIn('running_kernel_not_target_contract_release', text)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class AwsOsCoreExactIdentityTests(unittest.TestCase):
    @unittest.skipUnless(
        os.path.isdir(os.path.join(AWS, 'xenial-to-bionic')),
        'aws discovery missing',
    )
    def test_correct_names_wrong_release_versions_fail(self):
        contract, _rows = _discovery_union_contract()
        tmp = tempfile.mkdtemp(prefix='um-aws-oscore-wrongver-')
        try:
            def mutate(idents):
                out = []
                for ident in idents:
                    i = dict(ident)
                    if i['package'] in ('linux-aws', 'linux-image-aws'):
                        i['version'] = '4.4.0.1128.133'
                    elif i['package'].startswith('linux-image-') and i['package'].endswith('-aws'):
                        i['package'] = 'linux-image-4.4.0-1128-aws'
                        i['version'] = '4.4.0-1128.133'
                    out.append(i)
                return out

            _plant_contract_tree(tmp, contract, mutate_hop='xenial-to-bionic', mutate_fn=mutate)
            # Other hops get correct identities.
            for hop in dp.HOPS:
                if hop == 'xenial-to-bionic':
                    continue
                _plant_contract_tree(
                    tmp, {'hops': {hop: contract['hops'][hop]}},
                )
            plan = {
                'discovery_profiles': ['generic', 'aws'],
                'aws_semantic_contract': contract,
            }
            ok, errors, detail = aws_c.validate_tree_aws_completeness(
                tmp, plan=plan, require_aws_profile=True,
            )
            self.assertFalse(ok, detail)
            self.assertTrue(
                any('aws_contract_deb_missing_in_tree' in e and 'xenial-to-bionic' in e
                    for e in errors),
                errors,
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    @unittest.skipUnless(
        os.path.isdir(os.path.join(AWS, 'xenial-to-bionic')),
        'aws discovery missing',
    )
    def test_missing_versioned_image_fails(self):
        contract, _rows = _discovery_union_contract()
        tmp = tempfile.mkdtemp(prefix='um-aws-oscore-noimg-')
        try:
            def mutate(idents):
                return [
                    i for i in idents
                    if not (
                        i['package'].startswith('linux-image-')
                        and i['package'].endswith('-aws')
                        and i['package'] not in ('linux-image-aws',)
                    )
                    and not i['package'].startswith('linux-modules')
                ]

            for hop in dp.HOPS:
                if hop == 'xenial-to-bionic':
                    _plant_contract_tree(
                        tmp, contract, mutate_hop=hop, mutate_fn=mutate,
                    )
                else:
                    _plant_contract_tree(
                        tmp, {'hops': {hop: contract['hops'][hop]}},
                    )
            plan = {
                'discovery_profiles': ['generic', 'aws'],
                'aws_semantic_contract': contract,
            }
            ok, errors, detail = aws_c.validate_tree_aws_completeness(
                tmp, plan=plan, require_aws_profile=True,
            )
            self.assertFalse(ok, detail)
            self.assertTrue(
                any('linux-image-5.4.0-1103-aws' in e for e in errors),
                errors,
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    @unittest.skipUnless(
        os.path.isdir(os.path.join(AWS, 'xenial-to-bionic')),
        'aws discovery missing',
    )
    def test_wrong_x2b_snapd_fails(self):
        contract, _rows = _discovery_union_contract()
        tmp = tempfile.mkdtemp(prefix='um-aws-oscore-badsnap-')
        try:
            def mutate(idents):
                out = []
                for ident in idents:
                    i = dict(ident)
                    if i['package'] == 'snapd':
                        i['version'] = '2.48+16.04'  # source-ish, wrong target
                    out.append(i)
                return out

            for hop in dp.HOPS:
                if hop == 'xenial-to-bionic':
                    _plant_contract_tree(
                        tmp, contract, mutate_hop=hop, mutate_fn=mutate,
                    )
                else:
                    _plant_contract_tree(
                        tmp, {'hops': {hop: contract['hops'][hop]}},
                    )
            plan = {
                'discovery_profiles': ['generic', 'aws'],
                'aws_semantic_contract': contract,
            }
            ok, errors, detail = aws_c.validate_tree_aws_completeness(
                tmp, plan=plan, require_aws_profile=True,
            )
            self.assertFalse(ok, detail)
            self.assertTrue(
                any('snapd' in e and 'xenial-to-bionic' in e for e in errors),
                errors,
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    @unittest.skipUnless(
        os.path.isdir(os.path.join(AWS, 'xenial-to-bionic')),
        'aws discovery missing',
    )
    def test_complete_contract_matching_tree_passes(self):
        contract, _rows = _discovery_union_contract()
        tmp = tempfile.mkdtemp(prefix='um-aws-oscore-ok-')
        try:
            _plant_contract_tree(tmp, contract)
            plan = {
                'discovery_profiles': ['generic', 'aws'],
                'aws_semantic_contract': contract,
            }
            ok, errors, detail = aws_c.validate_tree_aws_completeness(
                tmp, plan=plan, require_aws_profile=True,
            )
            self.assertTrue(ok, errors or detail)
            # Same 5.4 for every hop must not be considered valid under contract.
            versions = [
                (contract['hops'][h].get('linux_aws') or {}).get('version')
                for h in dp.HOPS
            ]
            self.assertEqual(len(set(versions)), 4)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class StandalonePlannerCliFailClosedTests(unittest.TestCase):
    PLANNER = os.path.join(ROOT, 'scripts', 'build-selective-mirror-plan.py')

    def _run(self, args, env=None):
        base = os.environ.copy()
        # Production env for fail-closed checks unless caller overrides.
        base.pop('MM_HERMETIC_TEST_MODE', None)
        base.pop('UM_ALLOW_GENERIC_ONLY_DISCOVERY', None)
        if env:
            base.update(env)
        return subprocess.run(
            [sys.executable, self.PLANNER, '--skip-seed-probe'] + args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=base,
            cwd=ROOT,
        )

    @unittest.skipUnless(os.path.isdir(GENERIC), 'generic discovery missing')
    def test_cli_generic_only_production_fails(self):
        out_dir = tempfile.mkdtemp(prefix='um-plan-cli-g-')
        try:
            proc = self._run([
                '--discovery-root', 'generic=%s' % GENERIC,
                '--output-dir', out_dir,
                '--no-resolve-missing-pool-paths',
            ])
            self.assertNotEqual(proc.returncode, 0)
            err = (proc.stderr or b'').decode('utf-8', 'replace')
            self.assertIn('generic=<path> and aws=<path>', err)
        finally:
            shutil.rmtree(out_dir, ignore_errors=True)

    @unittest.skipUnless(os.path.isdir(AWS), 'aws discovery missing')
    def test_cli_aws_only_production_fails(self):
        out_dir = tempfile.mkdtemp(prefix='um-plan-cli-a-')
        try:
            proc = self._run([
                '--discovery-root', 'aws=%s' % AWS,
                '--output-dir', out_dir,
                '--no-resolve-missing-pool-paths',
            ])
            self.assertNotEqual(proc.returncode, 0)
            err = (proc.stderr or b'').decode('utf-8', 'replace')
            self.assertIn('generic=<path> and aws=<path>', err)
        finally:
            shutil.rmtree(out_dir, ignore_errors=True)

    @unittest.skipUnless(os.path.isdir(GENERIC), 'generic discovery missing')
    def test_cli_bare_single_root_production_fails(self):
        out_dir = tempfile.mkdtemp(prefix='um-plan-cli-bare-')
        try:
            proc = self._run([
                '--discovery-root', GENERIC,
                '--output-dir', out_dir,
                '--no-resolve-missing-pool-paths',
            ])
            self.assertNotEqual(proc.returncode, 0)
        finally:
            shutil.rmtree(out_dir, ignore_errors=True)

    @unittest.skipUnless(
        os.path.isdir(GENERIC) and os.path.isdir(AWS),
        'generic+aws discovery missing',
    )
    def test_cli_generic_plus_aws_allowed(self):
        out_dir = tempfile.mkdtemp(prefix='um-plan-cli-union-')
        try:
            proc = self._run([
                '--discovery-root', 'generic=%s' % GENERIC,
                '--discovery-root', 'aws=%s' % AWS,
                '--output-dir', out_dir,
                '--no-resolve-missing-pool-paths',
            ])
            self.assertEqual(proc.returncode, 0, proc.stderr.decode('utf-8', 'replace'))
            stdout = proc.stdout.decode('utf-8', 'replace')
            self.assertIn('validation_result=PASS', stdout)
            self.assertIn('discovery_profiles=generic,aws', stdout)
        finally:
            shutil.rmtree(out_dir, ignore_errors=True)

    @unittest.skipUnless(os.path.isdir(GENERIC), 'generic discovery missing')
    def test_cli_hermetic_dual_escape_allows_generic_only(self):
        out_dir = tempfile.mkdtemp(prefix='um-plan-cli-herm-')
        try:
            proc = self._run(
                [
                    '--discovery-root', 'generic=%s' % GENERIC,
                    '--output-dir', out_dir,
                    '--no-resolve-missing-pool-paths',
                ],
                env={
                    'MM_HERMETIC_TEST_MODE': '1',
                    'UM_ALLOW_GENERIC_ONLY_DISCOVERY': '1',
                },
            )
            self.assertEqual(proc.returncode, 0, proc.stderr.decode('utf-8', 'replace'))
            stdout = proc.stdout.decode('utf-8', 'replace')
            self.assertIn('validation_result=PASS', stdout)
            self.assertIn('discovery_profiles=generic', stdout)
        finally:
            shutil.rmtree(out_dir, ignore_errors=True)


if __name__ == '__main__':
    unittest.main()
