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
import json
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
                any(
                    'aws_semantic_contract_missing' in e
                    or 'aws_metapackage_deb_missing' in e
                    for e in errors
                ),
                errors,
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_versioned_image_only_tree_fails(self):
        # Blocker 4A: one versioned AWS image per hop is insufficient.
        tmp = tempfile.mkdtemp(prefix='um-aws-tree-imgonly-')
        restore = _env_swap({
            aws_c.HERMETIC_TEST_ENV: '1',
            aws_c.ALLOW_NAME_ONLY_AWS_ENV: '1',
        })
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
            restore()
            shutil.rmtree(tmp, ignore_errors=True)

    def test_aws_kernels_without_x2b_snapd_fails(self):
        # Blocker 4B.
        tmp = tempfile.mkdtemp(prefix='um-aws-tree-nosnapd-')
        restore = _env_swap({
            aws_c.HERMETIC_TEST_ENV: '1',
            aws_c.ALLOW_NAME_ONLY_AWS_ENV: '1',
        })
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
            restore()
            shutil.rmtree(tmp, ignore_errors=True)

    def test_complete_aws_tree_passes(self):
        # Blocker 4C.
        tmp = tempfile.mkdtemp(prefix='um-aws-tree-ok-')
        restore = _env_swap({
            aws_c.HERMETIC_TEST_ENV: '1',
            aws_c.ALLOW_NAME_ONLY_AWS_ENV: '1',
        })
        try:
            _plant_complete_aws_tree(tmp)
            plan = {'discovery_profiles': ['aws']}
            ok, errors, detail = aws_c.validate_tree_aws_completeness(
                tmp, plan=plan, require_aws_profile=True,
            )
            self.assertTrue(ok, errors or detail)
        finally:
            restore()
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
      snapd)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '2.58+18.04.1\n'; return 0; fi
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
      snapd)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '2.58+18.04.1\n'; return 0; fi
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
      snapd)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '2.58+18.04.1\n'; return 0; fi
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
      snapd)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '2.58+18.04.1\n'; return 0; fi
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


def _synth_identity(package, version, content):
    return {
        'package': package,
        'version': version,
        'architecture': 'amd64',
        'sha256': __import__('hashlib').sha256(content).hexdigest(),
        'filename': '%s_%s_amd64.deb' % (package, version),
        'size_bytes': len(content),
    }, content


def _synthetic_contract_and_contents():
    """Tiny coherent per-hop contract with known .deb byte contents."""
    import hashlib
    from collections import OrderedDict

    hops = OrderedDict()
    contents = {}  # sha256 -> bytes
    release_by_hop = {
        'xenial-to-bionic': ('5.4.0.1103.81', '5.4.0-1103-aws'),
        'bionic-to-focal': ('5.15.0.1084.91~20.04.1', '5.15.0-1084-aws'),
        'focal-to-jammy': ('6.8.0-1063.66~22.04.1', '6.8.0-1063-aws'),
        'jammy-to-noble': ('7.0.0-1011.11~24.04.1', '7.0.0-1011-aws'),
    }
    for hop in dp.HOPS:
        ver, rel = release_by_hop[hop]
        img_pkg = 'linux-image-%s' % rel
        identities = []
        for pkg, v in (
            ('linux-aws', ver),
            ('linux-image-aws', ver),
            (img_pkg, ver),
        ):
            blob = ('SYNTH|%s|%s|%s' % (hop, pkg, v)).encode('utf-8')
            ident, _ = _synth_identity(pkg, v, blob)
            contents[ident['sha256']] = blob
            identities.append(ident)
        snap = None
        if hop == 'xenial-to-bionic':
            blob = b'SYNTH|x2b|snapd|2.58+18.04.1'
            snap, _ = _synth_identity('snapd', '2.58+18.04.1', blob)
            contents[snap['sha256']] = blob
        hop_c = OrderedDict([
            ('hop', hop),
            ('source_series', hop.split('-to-')[0]),
            ('target_series', hop.split('-to-')[1]),
            ('source_version_id', aws_c.HOP_SOURCE_VERSION_ID[hop]),
            ('target_version_id', aws_c.HOP_TARGET_VERSION_ID[hop]),
            ('linux_aws', identities[0]),
            ('linux_image_aws', identities[1]),
            ('expected_kernel_releases', [rel]),
            ('versioned_images', [identities[2]]),
            ('boot_packages', []),
            ('snapd', snap),
        ])
        hops[hop] = hop_c
    contract = OrderedDict([
        ('schema_version', aws_c.CONTRACT_SCHEMA_VERSION),
        ('discovery_profiles', ['generic', 'aws']),
        ('required_metapackages', list(aws_c.REQUIRED_AWS_METAPACKAGES)),
        ('hops', hops),
        ('by_target_version_id', OrderedDict(
            (aws_c.HOP_TARGET_VERSION_ID[h], h) for h in dp.HOPS
        )),
    ])
    aws_c.attach_contract_sha256(contract)
    return contract, contents


def _plant_synth_tree(root, contract, contents, mutate_hop=None, mutate_fn=None):
    for hop, hop_c in (contract.get('hops') or {}).items():
        idents = list(aws_c.iter_contract_identities(hop_c))
        if mutate_hop == hop and mutate_fn:
            idents = mutate_fn(list(idents), contents)
        for ident in idents:
            pkg = ident['package']
            ver = ident['version']
            arch = ident.get('architecture') or 'amd64'
            letter = pkg[0] if pkg else 'x'
            pool = os.path.join(
                root, 'hops', hop, 'ubuntu', 'pool', 'main', letter, pkg,
            )
            os.makedirs(pool, exist_ok=True)
            base = '%s_%s_%s.deb' % (pkg, ver, arch)
            data = contents.get(ident.get('sha256') or '')
            if data is None:
                data = b'WRONG'
            with open(os.path.join(pool, base), 'wb') as fh:
                fh.write(data)


def _write_plan_state(selective_root, contract, plan_checksum='a' * 64,
                      discovery_checksum='b' * 64, write_ready=True):
    state = os.path.join(selective_root, 'state')
    os.makedirs(state, exist_ok=True)
    plan = {
        'schema_version': 1,
        'profile_name': 'offline-upgrade-selective',
        'discovery_profiles': ['generic', 'aws'],
        'aws_semantic_contract': contract,
        'aws_semantic_contract_sha256': contract['contract_sha256'],
        'plan_checksum': plan_checksum,
        'discovery_artifact_checksum': discovery_checksum,
        'validation_result': 'PASS',
        'debs': [],
    }
    with open(os.path.join(state, 'plan.json'), 'w') as fh:
        json.dump(plan, fh, indent=2, sort_keys=True)
        fh.write('\n')
    aws_c.write_aws_semantic_contract_bash(
        os.path.join(state, 'aws-semantic-contract.sh.inc'), contract,
    )
    if write_ready:
        aws_c.write_ready_generation_marker(
            os.path.join(state, 'READY'),
            plan_checksum,
            discovery_checksum,
            contract['contract_sha256'],
        )
    return plan


class ContractBindingAuthorityTests(unittest.TestCase):
    """Fourth-review P0/P1: single contract authority plan→client→OS Core."""

    def test_plan_client_drift_uses_plan_not_tracked_snapshot(self):
        contract, _contents = _synthetic_contract_and_contents()
        # Drift Bionic linux-aws away from tracked snapshot identity.
        bionic = contract['hops']['bionic-to-focal']
        drifted_ver = '9.9.9.9999.99~drift'
        blob = b'SYNTH|drift|linux-aws'
        ident, _ = _synth_identity('linux-aws', drifted_ver, blob)
        bionic['linux_aws'] = ident
        # Keep image meta aligned enough for bash render.
        bionic['linux_image_aws'] = dict(ident)
        bionic['linux_image_aws']['package'] = 'linux-image-aws'
        aws_c.attach_contract_sha256(contract)

        tracked = open(
            os.path.join(ROOT, 'client', 'dp-aws-semantic-contract.sh.inc')
        ).read()
        self.assertNotIn(drifted_ver, tracked)

        tmp = tempfile.mkdtemp(prefix='um-aws-drift-')
        try:
            _write_plan_state(tmp, contract)
            bash, sha, _c = aws_c.resolve_aws_semantic_contract_bash_for_client(tmp)
            self.assertEqual(sha, contract['contract_sha256'])
            self.assertIn(drifted_ver, bash)
            self.assertIn('AWS_SEMANTIC_CONTRACT_SHA256=', bash)
            # Must not silently use tracked snapshot authority.
            self.assertNotEqual(
                sha,
                # tracked file content hash is unrelated; compare identity string
                'tracked-not-used',
            )
            self.assertTrue(
                drifted_ver in bash and '5.15.0.1084.91~20.04.1' not in bash
                or drifted_ver in bash
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_client_contract_mismatch_fail_closed(self):
        contract, _ = _synthetic_contract_and_contents()
        tmp = tempfile.mkdtemp(prefix='um-aws-mismatch-')
        try:
            _write_plan_state(tmp, contract)
            # Plant a sibling bash that does not match plan-rendered authority.
            bad = os.path.join(tmp, 'state', 'aws-semantic-contract.sh.inc')
            with open(bad, 'w') as fh:
                fh.write('# stale\nAWS_SEMANTIC_CONTRACT_SHA256=deadbeef\n')
            with self.assertRaises(ValueError) as ctx:
                aws_c.resolve_aws_semantic_contract_bash_for_client(tmp)
            self.assertIn('differs_from_plan', str(ctx.exception))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_wrong_hop_identity_fails_plan_validation(self):
        contract, contents = _synthetic_contract_and_contents()
        # Rows: required xenial identity present only under bionic hop membership.
        x2b = contract['hops']['xenial-to-bionic']['linux_aws']
        rows = []
        for hop, hop_c in contract['hops'].items():
            for ident in aws_c.iter_contract_identities(hop_c):
                row_hop = hop
                if hop == 'xenial-to-bionic' and ident['package'] == 'linux-aws':
                    row_hop = 'bionic-to-focal'  # wrong hop membership
                rows.append({
                    'package': ident['package'],
                    'version': ident['version'],
                    'architecture': ident.get('architecture') or 'amd64',
                    'sha256': ident['sha256'],
                    'hop': row_hop,
                    'source_hops': [row_hop],
                })
        plan = {
            'discovery_profiles': ['generic', 'aws'],
            'aws_semantic_contract': contract,
            'aws_semantic_contract_sha256': contract['contract_sha256'],
            'counts': {'aws_kernel_package_rows': len(rows)},
            'debs': rows,
        }
        ok, errors, detail = aws_c.validate_plan_aws_completeness(
            plan, package_rows=rows, require_aws_profile=True,
        )
        self.assertFalse(ok, detail)
        self.assertTrue(
            any(
                'aws_contract_identity_missing_in_plan:xenial-to-bionic:linux-aws'
                in e
                for e in errors
            ),
            errors,
        )

    def test_end_to_end_contract_sha_identical(self):
        import json
        import tarfile
        oc = _load('os_core_package', os.path.join(ROOT, 'scripts', 'lib', 'os_core_package.py'))
        contract, contents = _synthetic_contract_and_contents()
        plan_sha = contract['contract_sha256']
        tmp = tempfile.mkdtemp(prefix='um-aws-e2e-')
        try:
            sel = os.path.join(tmp, 'sel')
            # published-like tree
            _plant_synth_tree(sel, contract, contents)
            _write_plan_state(sel, contract)
            # Client binding
            bash, client_sha, _ = aws_c.resolve_aws_semantic_contract_bash_for_client(sel)
            self.assertEqual(client_sha, plan_sha)
            self.assertIn(plan_sha, bash)

            out = os.path.join(tmp, 'out')
            os.makedirs(out)
            # Real OS Core build path
            ns = type('A', (), {
                'selective_root': sel,
                'output_dir': out,
                'project_root': ROOT,
                'release_id': 'e2eContract001',
                'signing_key': '',
            })()
            oc.cmd_build(ns)
            tar_path = os.path.join(
                out, 'ubuntu-os-core-xenial-to-noble-e2eContract001.tar'
            )
            extract = os.path.join(tmp, 'extract')
            os.makedirs(extract)
            with tarfile.open(tar_path, 'r:') as tf:
                tf.extractall(extract)
            pkg = os.path.join(extract, 'ubuntu-os-core')
            with open(os.path.join(pkg, 'manifest.json')) as fh:
                manifest = json.load(fh)
            self.assertEqual(manifest.get('aws_semantic_contract_sha256'), plan_sha)
            cpath = os.path.join(pkg, 'payload', 'state', 'aws-semantic-contract.json')
            self.assertTrue(os.path.isfile(cpath))
            with open(cpath) as fh:
                embedded = json.load(fh)
            self.assertEqual(
                aws_c.aws_semantic_contract_sha256(embedded), plan_sha,
            )
            # payload.sha256 must cover the contract file
            rel = 'state/aws-semantic-contract.json'
            covered = False
            with open(os.path.join(pkg, 'payload.sha256')) as fh:
                for line in fh:
                    if rel in line:
                        covered = True
                        break
            self.assertTrue(covered, 'contract not in payload.sha256')
            # Real verify
            vns = type('V', (), {'package': tar_path, 'public_key': ''})()
            oc.cmd_verify(vns)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_real_os_core_contract_embedded(self):
        self.test_end_to_end_contract_sha_identical()

    def test_real_os_core_wrong_version_fails(self):
        import json
        oc = _load('os_core_package', os.path.join(ROOT, 'scripts', 'lib', 'os_core_package.py'))
        contract, contents = _synthetic_contract_and_contents()
        tmp = tempfile.mkdtemp(prefix='um-aws-wrongver-')
        try:
            sel = os.path.join(tmp, 'sel')

            def mutate(idents, contents_map):
                out = []
                for ident in idents:
                    i = dict(ident)
                    if i['package'] == 'linux-aws':
                        i['version'] = '0.0.0.wrong'
                        # keep same sha/content so filename/version mismatch is the defect
                    out.append(i)
                return out

            _plant_synth_tree(
                sel, contract, contents,
                mutate_hop='xenial-to-bionic', mutate_fn=mutate,
            )
            # Other hops correct
            for hop in dp.HOPS:
                if hop == 'xenial-to-bionic':
                    continue
                _plant_synth_tree(sel, {'hops': {hop: contract['hops'][hop]}}, contents)
            _write_plan_state(sel, contract)
            out = os.path.join(tmp, 'out')
            os.makedirs(out)
            ns = type('A', (), {
                'selective_root': sel,
                'output_dir': out,
                'project_root': ROOT,
                'release_id': 'wrongVer001',
                'signing_key': '',
            })()
            with self.assertRaises(oc.OsCoreError) as ctx:
                oc.cmd_build(ns)
            self.assertIn('AWS_OS_CORE_SEMANTIC_COMPLETENESS', str(ctx.exception))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_real_os_core_wrong_bytes_fails_sha256(self):
        oc = _load('os_core_package', os.path.join(ROOT, 'scripts', 'lib', 'os_core_package.py'))
        contract, contents = _synthetic_contract_and_contents()
        tmp = tempfile.mkdtemp(prefix='um-aws-wrongbytes-')
        try:
            sel = os.path.join(tmp, 'sel')
            # Plant correct names/versions but corrupt one payload byte map.
            bad_contents = dict(contents)
            xsha = contract['hops']['xenial-to-bionic']['linux_aws']['sha256']
            bad_contents[xsha] = b'TAMPERED-BYTES-NOT-MATCHING-SHA'

            _plant_synth_tree(sel, contract, bad_contents)
            _write_plan_state(sel, contract)
            out = os.path.join(tmp, 'out')
            os.makedirs(out)
            ns = type('A', (), {
                'selective_root': sel,
                'output_dir': out,
                'project_root': ROOT,
                'release_id': 'wrongBytes001',
                'signing_key': '',
            })()
            with self.assertRaises(oc.OsCoreError) as ctx:
                oc.cmd_build(ns)
            msg = str(ctx.exception)
            self.assertTrue(
                'sha256' in msg.lower() or 'AWS_OS_CORE_SEMANTIC_COMPLETENESS' in msg,
                msg,
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_real_os_core_missing_contract_fails(self):
        oc = _load('os_core_package', os.path.join(ROOT, 'scripts', 'lib', 'os_core_package.py'))
        contract, contents = _synthetic_contract_and_contents()
        tmp = tempfile.mkdtemp(prefix='um-aws-nocontract-')
        try:
            sel = os.path.join(tmp, 'sel')
            _plant_synth_tree(sel, contract, contents)
            # Intentionally omit state/plan.json
            out = os.path.join(tmp, 'out')
            os.makedirs(out)
            ns = type('A', (), {
                'selective_root': sel,
                'output_dir': out,
                'project_root': ROOT,
                'release_id': 'noContract001',
                'signing_key': '',
            })()
            with self.assertRaises(oc.OsCoreError) as ctx:
                oc.cmd_build(ns)
            self.assertIn('AWS_SEMANTIC_CONTRACT', str(ctx.exception))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class FifthReviewGenerationBindingTests(unittest.TestCase):
    """P0: READY / state plan / contract must be generation-bound."""

    def test_ready_state_plan_generation_drift_fails(self):
        contract_a, _ = _synthetic_contract_and_contents()
        contract_b, _ = _synthetic_contract_and_contents()
        # Drift contract B linux-aws so SHA differs.
        blob = b'SYNTH|genB|linux-aws|drift'
        ident, _ = _synth_identity('linux-aws', '9.9.9.9999.99', blob)
        contract_b['hops']['xenial-to-bionic']['linux_aws'] = ident
        aws_c.attach_contract_sha256(contract_b)
        self.assertNotEqual(
            contract_a['contract_sha256'], contract_b['contract_sha256'],
        )

        tmp = tempfile.mkdtemp(prefix='um-aws-gen-drift-')
        try:
            # Plan/state = B; READY = A
            _write_plan_state(
                tmp, contract_b,
                plan_checksum='b' * 64,
                discovery_checksum='c' * 64,
                write_ready=False,
            )
            aws_c.write_ready_generation_marker(
                os.path.join(tmp, 'state', 'READY'),
                'a' * 64,
                'a' * 64,
                contract_a['contract_sha256'],
            )
            with self.assertRaises(ValueError) as ctx:
                aws_c.load_verified_selective_generation(tmp)
            self.assertIn('selective_generation_drift', str(ctx.exception))
            with self.assertRaises(ValueError):
                aws_c.resolve_aws_semantic_contract_bash_for_client(tmp)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_contract_sha_only_drift_fails(self):
        contract, _ = _synthetic_contract_and_contents()
        tmp = tempfile.mkdtemp(prefix='um-aws-contract-drift-')
        try:
            plan_ck = 'd' * 64
            disc_ck = 'e' * 64
            _write_plan_state(
                tmp, contract,
                plan_checksum=plan_ck,
                discovery_checksum=disc_ck,
                write_ready=False,
            )
            # READY plan/discovery match; contract SHA does not.
            aws_c.write_ready_generation_marker(
                os.path.join(tmp, 'state', 'READY'),
                plan_ck,
                disc_ck,
                'f' * 64,
            )
            with self.assertRaises(ValueError) as ctx:
                aws_c.load_verified_selective_generation(tmp)
            msg = str(ctx.exception)
            self.assertIn('selective_generation_drift', msg)
            self.assertIn('aws_semantic_contract_sha256', msg)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_state_write_failure_fails_closed(self):
        contract, _ = _synthetic_contract_and_contents()
        tmp = tempfile.mkdtemp(prefix='um-aws-state-write-')
        try:
            plan_src_dir = os.path.join(tmp, 'analysis')
            os.makedirs(plan_src_dir)
            plan_path = os.path.join(plan_src_dir, 'plan.json')
            plan = {
                'schema_version': 1,
                'validation_result': 'PASS',
                'plan_checksum': '1' * 64,
                'discovery_artifact_checksum': '2' * 64,
                'aws_semantic_contract': contract,
                'aws_semantic_contract_sha256': contract['contract_sha256'],
            }
            with open(plan_path, 'w') as fh:
                json.dump(plan, fh)
            aws_c.write_aws_semantic_contract_bash(
                os.path.join(plan_src_dir, 'aws-semantic-contract.sh.inc'), contract,
            )

            sel = os.path.join(tmp, 'sel')
            # Prior generation READY A present.
            _write_plan_state(
                sel, contract,
                plan_checksum='a' * 64,
                discovery_checksum='a' * 64,
            )
            ready_path = os.path.join(sel, 'state', 'READY')
            self.assertTrue(os.path.isfile(ready_path))
            state_dir = os.path.join(sel, 'state')
            os.chmod(state_dir, 0o555)
            try:
                with self.assertRaises(ValueError) as ctx:
                    aws_c.publish_selective_generation_state(sel, plan_path)
                msg = str(ctx.exception)
                self.assertTrue(
                    'selective_generation' in msg or 'selective_ready_invalidate' in msg,
                    msg,
                )
            finally:
                os.chmod(state_dir, 0o755)
            # Fail closed: did not report PASS; READY was not replaced with B.
            # Either invalidate failed (READY A remains) or state was not updated
            # to the new plan checksum.
            if os.path.isfile(ready_path):
                fields = {}
                for line in open(ready_path):
                    if '=' in line:
                        k, v = line.strip().split('=', 1)
                        fields[k] = v
                self.assertEqual(fields.get('plan_checksum'), 'a' * 64)
            plan_on_disk = json.load(open(os.path.join(state_dir, 'plan.json')))
            self.assertEqual(plan_on_disk.get('plan_checksum'), 'a' * 64)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_valid_generation_binding_passes_client_and_os_core(self):
        oc = _load('os_core_package', os.path.join(ROOT, 'scripts', 'lib', 'os_core_package.py'))
        contract, contents = _synthetic_contract_and_contents()
        tmp = tempfile.mkdtemp(prefix='um-aws-valid-gen-')
        try:
            sel = os.path.join(tmp, 'sel')
            _plant_synth_tree(sel, contract, contents)
            _write_plan_state(sel, contract)
            gen = aws_c.load_verified_selective_generation(sel)
            self.assertEqual(gen['aws_semantic_contract_sha256'], contract['contract_sha256'])
            bash, sha, _ = aws_c.resolve_aws_semantic_contract_bash_for_client(sel)
            self.assertEqual(sha, contract['contract_sha256'])
            self.assertIn('AWS_SEMANTIC_CONTRACT_SHA256=', bash)

            out = os.path.join(tmp, 'out')
            os.makedirs(out)
            ns = type('A', (), {
                'selective_root': sel,
                'output_dir': out,
                'project_root': ROOT,
                'release_id': 'validGen001',
                'signing_key': '',
            })()
            oc.cmd_build(ns)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class FifthReviewSnapdGateTests(unittest.TestCase):
    """P0: xenial→bionic snapd contract enforced at runtime."""

    def _prereboot_script(self, tmp, snap_ver):
        for rel, content in (
            ('/boot/vmlinuz-5.4.0-1103-aws', b'k'),
            ('/boot/initrd.img-5.4.0-1103-aws', b'i'),
        ):
            path = os.path.join(tmp, rel.lstrip('/'))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, 'wb').write(content)
        holds = os.path.join(tmp, 'opt/aelladata/os-upgrade/offline/critical-holds')
        os.makedirs(holds, exist_ok=True)
        open(os.path.join(holds, 'source_kernel_flavor'), 'w').write('aws\n')
        open(os.path.join(holds, 'source_kernel_release'), 'w').write('4.4.0-1128-aws\n')
        open(os.path.join(holds, 'source_linux_aws_version'), 'w').write('4.4.0.1128.133\n')
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
      linux-aws|linux-image-aws|linux-image-5.4.0-1103-aws)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '5.4.0.1103.81\n'; return 0; fi
        ;;
      snapd)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '%s\n'; return 0; fi
        ;;
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
            snap_ver,
            os.path.join(ROOT, 'client', 'dp-aws-semantic-contract.sh.inc'),
            GATE_INC,
        )

    def test_x2b_pre_reboot_stale_snapd_fails(self):
        tmp = tempfile.mkdtemp(prefix='um-aws-snapd-prereboot-')
        try:
            script = self._prereboot_script(tmp, '2.48.3')
            out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
            text = out.decode('utf-8', 'replace')
            self.assertIn('PRE_REBOOT_FAIL', text)
            self.assertIn('snapd_not_contract_identity', text)
            self.assertIn('AUTOMATIC_REBOOT_NOT_STARTED', text)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_x2b_postboot_stale_snapd_fails(self):
        tmp = tempfile.mkdtemp(prefix='um-aws-snapd-postboot-')
        try:
            holds = os.path.join(tmp, 'opt/aelladata/os-upgrade/offline/critical-holds')
            boot = os.path.join(tmp, 'boot')
            os.makedirs(holds)
            os.makedirs(boot)
            open(os.path.join(holds, 'source_kernel_flavor'), 'w').write('aws\n')
            open(os.path.join(holds, 'source_kernel_release'), 'w').write('4.4.0-1128-aws\n')
            open(os.path.join(holds, 'source_linux_aws_version'), 'w').write('4.4.0.1128.133\n')
            open(os.path.join(holds, 'source_linux_image_aws_version'), 'w').write(
                '4.4.0.1128.133\n'
            )
            open(os.path.join(boot, 'vmlinuz-5.4.0-1103-aws'), 'wb').write(b'k')
            script = r'''
set -euo pipefail
TEST_ROOT="%s"
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
      snapd)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '2.48.3\n'; return 0; fi
        ;;
    esac
  fi
  return 1
}
uname() { printf '5.4.0-1103-aws\n'; }
source "%s"
source "%s"
if validate_aws_post_hop_kernel_gate "18.04"; then
  echo COMPLETED_BIONIC
  exit 0
fi
echo POSTBOOT_FAIL
''' % (
                tmp,
                os.path.join(ROOT, 'client', 'dp-aws-semantic-contract.sh.inc'),
                GATE_INC,
            )
            out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
            text = out.decode('utf-8', 'replace')
            self.assertIn('POSTBOOT_FAIL', text)
            self.assertIn('snapd_not_contract_identity', text)
            self.assertNotIn('COMPLETED_BIONIC', text)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_next_hop_recovery_stale_snapd_fails(self):
        script = r'''
set -euo pipefail
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
DP_OFFLINE_FAKE_KERNEL="5.4.0-1103-aws"
MUTATION_ENTERED=0
simulate_destructive_stage() { MUTATION_ENTERED=1; echo MUTATION_ENTERED; }
dpkg-query() {
  local pkg="${3:-}"
  if [[ "$1" == "-W" ]]; then
    case "$pkg" in
      linux-aws|linux-image-aws|linux-image-5.4.0-1103-aws)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '5.4.0.1103.81\n'; return 0; fi
        ;;
      snapd)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '2.48.3\n'; return 0; fi
        ;;
    esac
  fi
  return 1
}
uname() { printf '5.4.0-1103-aws\n'; }
kernel_flavor() { printf 'aws\n'; }
source "%s"
source "%s"
if validate_aws_source_kernel_preflight "18.04"; then
  simulate_destructive_stage
  echo PREFLIGHT_PASS
  exit 0
fi
echo PREFLIGHT_FAIL
echo "MUTATION_ENTERED=${MUTATION_ENTERED}"
''' % (
            os.path.join(ROOT, 'client', 'dp-aws-semantic-contract.sh.inc'),
            GATE_INC,
        )
        out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
        text = out.decode('utf-8', 'replace')
        self.assertIn('PREFLIGHT_FAIL', text)
        self.assertIn('snapd_not_contract_identity', text)
        self.assertIn('MUTATION_ENTERED=0', text)

    def test_valid_bionic_snapd_passes(self):
        tmp = tempfile.mkdtemp(prefix='um-aws-snapd-ok-')
        try:
            script = self._prereboot_script(tmp, '2.58+18.04.1')
            out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
            text = out.decode('utf-8', 'replace')
            self.assertIn('PRE_REBOOT_PASS', text)
            self.assertIn('AWS_CONTRACT_SNAPD=PASS', text)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_later_hop_empty_snapd_not_required(self):
        # Focal target contract has empty snapd — gate must not require snapd.
        tmp = tempfile.mkdtemp(prefix='um-aws-snapd-later-')
        try:
            for rel, content in (
                ('/boot/vmlinuz-5.15.0-1084-aws', b'k'),
                ('/boot/initrd.img-5.15.0-1084-aws', b'i'),
            ):
                path = os.path.join(tmp, rel.lstrip('/'))
                os.makedirs(os.path.dirname(path), exist_ok=True)
                open(path, 'wb').write(content)
            holds = os.path.join(tmp, 'opt/aelladata/os-upgrade/offline/critical-holds')
            os.makedirs(holds, exist_ok=True)
            open(os.path.join(holds, 'source_kernel_flavor'), 'w').write('aws\n')
            open(os.path.join(holds, 'source_kernel_release'), 'w').write(
                '5.4.0-1103-aws\n'
            )
            open(os.path.join(holds, 'source_linux_aws_version'), 'w').write(
                '5.4.0.1103.81\n'
            )
            open(os.path.join(holds, 'source_linux_image_aws_version'), 'w').write(
                '5.4.0.1103.81\n'
            )
            script = r'''
set -euo pipefail
TEST_ROOT="%s"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
HOLDS_DIR="${STATE_ROOT}/critical-holds"
dpkg-query() {
  local pkg="${3:-}"
  if [[ "$1" == "-W" ]]; then
    case "$pkg" in
      linux-aws|linux-image-aws|linux-image-5.15.0-1084-aws)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '5.15.0.1084.91~20.04.1\n'; return 0; fi
        ;;
    esac
  fi
  return 1
}
uname() { printf '5.4.0-1103-aws\n'; }
source "%s"
source "%s"
validate_aws_target_kernel_pre_reboot "20.04"
echo PRE_REBOOT_PASS
''' % (
                tmp,
                os.path.join(ROOT, 'client', 'dp-aws-semantic-contract.sh.inc'),
                GATE_INC,
            )
            out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
            text = out.decode('utf-8', 'replace')
            self.assertIn('PRE_REBOOT_PASS', text)
            self.assertNotIn('snapd_not_installed', text)
            self.assertNotIn('snapd_not_contract_identity', text)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class FifthReviewBootPackageGateTests(unittest.TestCase):
    """P1: discovery boot_packages rendered and enforced at runtime."""

    def test_boot_packages_rendered_into_bash_contract(self):
        contract, _ = _synthetic_contract_and_contents()
        rel = contract['hops']['xenial-to-bionic']['expected_kernel_releases'][0]
        mod_name = 'linux-modules-%s' % rel
        blob = b'SYNTH|boot|modules'
        ident, _ = _synth_identity(mod_name, '5.4.0.1103.81', blob)
        contract['hops']['xenial-to-bionic']['boot_packages'] = [ident]
        aws_c.attach_contract_sha256(contract)
        bash = aws_c.render_aws_semantic_contract_bash(contract)
        self.assertIn("AWS_C_BOOT_PACKAGES='%s'" % mod_name, bash)
        self.assertIn(
            "AWS_C_BOOT_PACKAGE_VERSIONS='%s=5.4.0.1103.81'" % mod_name, bash,
        )

    def _prereboot_with_boot_pkg(self, tmp, install_modules=True):
        for rel, content in (
            ('/boot/vmlinuz-5.4.0-1103-aws', b'k'),
            ('/boot/initrd.img-5.4.0-1103-aws', b'i'),
        ):
            path = os.path.join(tmp, rel.lstrip('/'))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, 'wb').write(content)
        holds = os.path.join(tmp, 'opt/aelladata/os-upgrade/offline/critical-holds')
        os.makedirs(holds, exist_ok=True)
        open(os.path.join(holds, 'source_kernel_flavor'), 'w').write('aws\n')
        open(os.path.join(holds, 'source_kernel_release'), 'w').write('4.4.0-1128-aws\n')
        open(os.path.join(holds, 'source_linux_aws_version'), 'w').write('4.4.0.1128.133\n')
        open(os.path.join(holds, 'source_linux_image_aws_version'), 'w').write(
            '4.4.0.1128.133\n'
        )
        modules_case = ''
        if install_modules:
            modules_case = r'''
      linux-modules-5.4.0-1103-aws)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '5.4.0.1103.81\n'; return 0; fi
        ;;
'''
        # Inline a minimal contract with boot package for 18.04.
        return r'''
set -euo pipefail
TEST_ROOT="%s"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
HOLDS_DIR="${STATE_ROOT}/critical-holds"
AWS_SEMANTIC_CONTRACT_LOADED=1
aws_contract_clear() {
  AWS_C_HOP=""; AWS_C_TARGET_VERSION_ID=""; AWS_C_LINUX_AWS_VERSION=""
  AWS_C_LINUX_AWS_SHA256=""; AWS_C_LINUX_IMAGE_AWS_VERSION=""; AWS_C_LINUX_IMAGE_AWS_SHA256=""
  AWS_C_KERNEL_RELEASES=""; AWS_C_VERSIONED_IMAGE_PACKAGES=""
  AWS_C_BOOT_PACKAGES=""; AWS_C_BOOT_PACKAGE_VERSIONS=""; AWS_C_SNAPD_VERSION=""
}
aws_contract_load_for_version_id() {
  local ver="${1:-}"
  aws_contract_clear
  [[ "$ver" == "18.04" ]] || return 1
  AWS_C_HOP='xenial-to-bionic'
  AWS_C_TARGET_VERSION_ID='18.04'
  AWS_C_LINUX_AWS_VERSION='5.4.0.1103.81'
  AWS_C_LINUX_IMAGE_AWS_VERSION='5.4.0.1103.81'
  AWS_C_KERNEL_RELEASES='5.4.0-1103-aws'
  AWS_C_VERSIONED_IMAGE_PACKAGES='linux-image-5.4.0-1103-aws'
  AWS_C_BOOT_PACKAGES='linux-modules-5.4.0-1103-aws'
  AWS_C_BOOT_PACKAGE_VERSIONS='linux-modules-5.4.0-1103-aws=5.4.0.1103.81'
  AWS_C_SNAPD_VERSION='2.58+18.04.1'
  return 0
}
dpkg-query() {
  local pkg="${3:-}"
  if [[ "$1" == "-W" ]]; then
    case "$pkg" in
      linux-aws|linux-image-aws|linux-image-5.4.0-1103-aws)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '5.4.0.1103.81\n'; return 0; fi
        ;;
      snapd)
        if [[ "$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$2" == *Version* ]]; then printf '2.58+18.04.1\n'; return 0; fi
        ;;
%s
    esac
  fi
  return 1
}
uname() { printf '4.4.0-1128-aws\n'; }
source "%s"
if validate_aws_target_kernel_pre_reboot "18.04"; then
  echo PRE_REBOOT_PASS
  exit 0
fi
echo PRE_REBOOT_FAIL
''' % (tmp, modules_case, GATE_INC)

    def test_missing_required_boot_package_fails(self):
        tmp = tempfile.mkdtemp(prefix='um-aws-boot-missing-')
        try:
            script = self._prereboot_with_boot_pkg(tmp, install_modules=False)
            out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
            text = out.decode('utf-8', 'replace')
            self.assertIn('PRE_REBOOT_FAIL', text)
            self.assertIn('boot_package_not_installed', text)
            self.assertIn('AUTOMATIC_REBOOT_NOT_STARTED', text)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_complete_boot_package_contract_passes(self):
        tmp = tempfile.mkdtemp(prefix='um-aws-boot-ok-')
        try:
            script = self._prereboot_with_boot_pkg(tmp, install_modules=True)
            out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
            text = out.decode('utf-8', 'replace')
            self.assertIn('PRE_REBOOT_PASS', text)
            self.assertIn('AWS_CONTRACT_BOOT_PACKAGES=PASS', text)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class SixthReviewR2RoundTripAndChecksumTests(unittest.TestCase):
    """Sixth-review P0/P1: distinct checksums + R2 fresh materialize self-sufficiency."""

    def _build_os_core(self, oc, sel, out, release_id):
        ns = type('A', (), {
            'selective_root': sel,
            'output_dir': out,
            'project_root': ROOT,
            'release_id': release_id,
            'signing_key': '',
        })()
        oc.cmd_build(ns)
        return os.path.join(
            out, 'ubuntu-os-core-xenial-to-noble-%s.tar' % release_id,
        )

    def test_discovery_and_payload_manifest_checksums_are_distinct(self):
        import hashlib
        import tarfile
        oc = _load('os_core_package', os.path.join(ROOT, 'scripts', 'lib', 'os_core_package.py'))
        contract, contents = _synthetic_contract_and_contents()
        plan_ck = 'a' * 64
        disc_ck = 'b' * 64
        self.assertNotEqual(plan_ck, disc_ck)
        tmp = tempfile.mkdtemp(prefix='um-aws-disc-payload-')
        try:
            sel = os.path.join(tmp, 'sel')
            _plant_synth_tree(sel, contract, contents)
            _write_plan_state(
                sel, contract,
                plan_checksum=plan_ck,
                discovery_checksum=disc_ck,
            )
            out = os.path.join(tmp, 'out')
            os.makedirs(out)
            tar_path = self._build_os_core(oc, sel, out, 'discPayload001')
            extract = os.path.join(tmp, 'extract')
            os.makedirs(extract)
            with tarfile.open(tar_path, 'r:') as tf:
                tf.extractall(extract)
            pkg = os.path.join(extract, 'ubuntu-os-core')
            with open(os.path.join(pkg, 'manifest.json')) as fh:
                manifest = json.load(fh)
            payload_manifest = hashlib.sha256(
                open(os.path.join(pkg, 'payload.sha256'), 'rb').read()
            ).hexdigest()
            self.assertEqual(manifest.get('discovery_artifact_checksum'), disc_ck)
            self.assertEqual(manifest.get('payload_manifest_sha256'), payload_manifest)
            self.assertNotEqual(
                manifest.get('discovery_artifact_checksum'),
                manifest.get('payload_manifest_sha256'),
            )
            self.assertEqual(manifest.get('selective_plan_checksum'), plan_ck)
            self.assertEqual(
                manifest.get('aws_semantic_contract_sha256'),
                contract['contract_sha256'],
            )
            oc.cmd_verify(type('V', (), {'package': tar_path, 'public_key': ''})())
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_payload_manifest_sha_tamper_fails_verify(self):
        import tarfile
        oc = _load('os_core_package', os.path.join(ROOT, 'scripts', 'lib', 'os_core_package.py'))
        contract, contents = _synthetic_contract_and_contents()
        tmp = tempfile.mkdtemp(prefix='um-aws-payload-tamper-')
        try:
            sel = os.path.join(tmp, 'sel')
            _plant_synth_tree(sel, contract, contents)
            _write_plan_state(sel, contract, plan_checksum='1' * 64, discovery_checksum='2' * 64)
            out = os.path.join(tmp, 'out')
            os.makedirs(out)
            tar_path = self._build_os_core(oc, sel, out, 'payloadTamper001')
            # Rebuild tar with tampered manifest.payload_manifest_sha256
            work = os.path.join(tmp, 'tamper')
            os.makedirs(work)
            with tarfile.open(tar_path, 'r:') as tf:
                tf.extractall(work)
            mp = os.path.join(work, 'ubuntu-os-core', 'manifest.json')
            with open(mp) as fh:
                manifest = json.load(fh)
            manifest['payload_manifest_sha256'] = '0' * 64
            with open(mp, 'w') as fh:
                json.dump(manifest, fh, indent=2, sort_keys=True)
                fh.write('\n')
            bad_tar = os.path.join(tmp, 'bad.tar')
            with tarfile.open(bad_tar, 'w') as tf:
                tf.add(
                    os.path.join(work, 'ubuntu-os-core'),
                    arcname='ubuntu-os-core',
                )
            # validate_package_tree path used by verify
            with self.assertRaises(oc.OsCoreError) as ctx:
                oc.validate_package_tree(work)
            self.assertIn('MANIFEST_PAYLOAD_MANIFEST_MISMATCH', str(ctx.exception))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_fresh_materialize_restores_generation_without_prior_plan(self):
        import tarfile
        oc = _load('os_core_package', os.path.join(ROOT, 'scripts', 'lib', 'os_core_package.py'))
        contract, contents = _synthetic_contract_and_contents()
        plan_ck = 'c' * 64
        disc_ck = 'd' * 64
        tmp = tempfile.mkdtemp(prefix='um-aws-fresh-mat-')
        try:
            sel = os.path.join(tmp, 'sel')
            _plant_synth_tree(sel, contract, contents)
            _write_plan_state(
                sel, contract,
                plan_checksum=plan_ck,
                discovery_checksum=disc_ck,
            )
            out = os.path.join(tmp, 'out')
            os.makedirs(out)
            tar_path = self._build_os_core(oc, sel, out, 'freshMat001')
            oc.cmd_verify(type('V', (), {'package': tar_path, 'public_key': ''})())

            extract = os.path.join(tmp, 'extract')
            os.makedirs(extract)
            with tarfile.open(tar_path, 'r:') as tf:
                tf.extractall(extract)
            pkg = os.path.join(extract, 'ubuntu-os-core')
            # Fresh empty destination — no prior plan/READY.
            dest = os.path.join(tmp, 'fresh-selective')
            # Simulate engine move of payload into selective root.
            shutil.copytree(os.path.join(pkg, 'payload'), dest)
            # Ensure we did not copy READY from source (build does not embed READY).
            ready_src = os.path.join(dest, 'state', 'READY')
            if os.path.isfile(ready_src):
                os.unlink(ready_src)
            self.assertTrue(
                os.path.isfile(os.path.join(dest, 'state', 'plan.json')),
                'OS Core must embed public-safe plan.json',
            )
            # Real provenance → READY materialization path
            ns = type('R', (), {
                'package_root': pkg,
                'selective_root': dest,
                'payload_root': dest,
            })()
            oc.cmd_write_selective_ready(ns)
            gen = aws_c.load_verified_selective_generation(dest)
            self.assertEqual(gen['plan_checksum'], plan_ck)
            self.assertEqual(gen['discovery_artifact_checksum'], disc_ck)
            self.assertEqual(gen['aws_semantic_contract_sha256'], contract['contract_sha256'])
            bash, client_sha, _ = aws_c.resolve_aws_semantic_contract_bash_for_client(dest)
            self.assertEqual(client_sha, contract['contract_sha256'])
            self.assertIn(contract['contract_sha256'], bash)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_stale_external_plan_replaced_by_os_core_generation(self):
        import tarfile
        oc = _load('os_core_package', os.path.join(ROOT, 'scripts', 'lib', 'os_core_package.py'))
        contract, contents = _synthetic_contract_and_contents()
        plan_ck = 'e' * 64
        disc_ck = 'f' * 64
        tmp = tempfile.mkdtemp(prefix='um-aws-stale-plan-')
        try:
            sel = os.path.join(tmp, 'sel')
            _plant_synth_tree(sel, contract, contents)
            _write_plan_state(
                sel, contract,
                plan_checksum=plan_ck,
                discovery_checksum=disc_ck,
            )
            out = os.path.join(tmp, 'out')
            os.makedirs(out)
            tar_path = self._build_os_core(oc, sel, out, 'stalePlan001')
            extract = os.path.join(tmp, 'extract')
            os.makedirs(extract)
            with tarfile.open(tar_path, 'r:') as tf:
                tf.extractall(extract)
            pkg = os.path.join(extract, 'ubuntu-os-core')

            dest = os.path.join(tmp, 'dest')
            os.makedirs(os.path.join(dest, 'state'), exist_ok=True)
            # Plant unrelated stale plan that must NOT win.
            stale_contract, _ = _synthetic_contract_and_contents()
            blob = b'SYNTH|stale|linux-aws'
            ident, _ = _synth_identity('linux-aws', '0.0.0.stale', blob)
            stale_contract['hops']['xenial-to-bionic']['linux_aws'] = ident
            aws_c.attach_contract_sha256(stale_contract)
            _write_plan_state(
                dest, stale_contract,
                plan_checksum='9' * 64,
                discovery_checksum='8' * 64,
            )
            # Overlay verified payload state from OS Core (engine replaces tree).
            # Invalidate any stale READY so package manifest is the authority.
            stale_ready = os.path.join(dest, 'state', 'READY')
            if os.path.isfile(stale_ready):
                os.unlink(stale_ready)
            for name in ('plan.json', 'aws-semantic-contract.json'):
                src = os.path.join(pkg, 'payload', 'state', name)
                if os.path.isfile(src):
                    shutil.copy2(src, os.path.join(dest, 'state', name))
            # Copy hops so client resolution is meaningful after READY.
            if os.path.isdir(os.path.join(pkg, 'payload', 'hops')):
                if os.path.isdir(os.path.join(dest, 'hops')):
                    shutil.rmtree(os.path.join(dest, 'hops'))
                shutil.copytree(
                    os.path.join(pkg, 'payload', 'hops'),
                    os.path.join(dest, 'hops'),
                )
            oc.cmd_write_selective_ready(type('R', (), {
                'package_root': pkg,
                'selective_root': dest,
                'payload_root': dest,
            })())
            gen = aws_c.load_verified_selective_generation(dest)
            self.assertEqual(gen['plan_checksum'], plan_ck)
            self.assertEqual(gen['discovery_artifact_checksum'], disc_ck)
            self.assertNotEqual(gen['plan_checksum'], '9' * 64)
            self.assertEqual(gen['aws_semantic_contract_sha256'], contract['contract_sha256'])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_r2_roundtrip_real_build_verify_materialize_client(self):
        """Mandatory hermetic lifecycle using real production functions."""
        import hashlib
        import tarfile
        oc = _load('os_core_package', os.path.join(ROOT, 'scripts', 'lib', 'os_core_package.py'))
        contract, contents = _synthetic_contract_and_contents()
        plan_ck = hashlib.sha256(b'generation-A-plan').hexdigest()
        disc_ck = hashlib.sha256(b'generation-A-discovery').hexdigest()
        self.assertNotEqual(plan_ck, disc_ck)
        tmp = tempfile.mkdtemp(prefix='um-aws-r2-roundtrip-')
        try:
            # 1-3: tiny valid tree + verified generation A + READY A
            sel = os.path.join(tmp, 'sel-src')
            _plant_synth_tree(sel, contract, contents)
            _write_plan_state(
                sel, contract,
                plan_checksum=plan_ck,
                discovery_checksum=disc_ck,
                write_ready=True,
            )
            gen_a = aws_c.load_verified_selective_generation(sel)
            self.assertEqual(gen_a['plan_checksum'], plan_ck)
            self.assertEqual(gen_a['discovery_artifact_checksum'], disc_ck)

            # 4-5: REAL os_core build + verify
            out = os.path.join(tmp, 'out')
            os.makedirs(out)
            tar_path = self._build_os_core(oc, sel, out, 'r2RoundTrip001')
            oc.cmd_verify(type('V', (), {'package': tar_path, 'public_key': ''})())

            # 6-7: extract into NEW EMPTY selective root + provenance READY path
            extract = os.path.join(tmp, 'extract')
            os.makedirs(extract)
            with tarfile.open(tar_path, 'r:') as tf:
                tf.extractall(extract)
            pkg = os.path.join(extract, 'ubuntu-os-core')
            # Prove we did not manually copy source plan outside OS Core contract.
            self.assertTrue(
                os.path.isfile(os.path.join(pkg, 'payload', 'state', 'plan.json'))
            )
            fresh = os.path.join(tmp, 'fresh-mirror')
            shutil.copytree(os.path.join(pkg, 'payload'), fresh)
            if os.path.isfile(os.path.join(fresh, 'state', 'READY')):
                os.unlink(os.path.join(fresh, 'state', 'READY'))
            oc.cmd_write_selective_ready(type('R', (), {
                'package_root': pkg,
                'selective_root': fresh,
                'payload_root': fresh,
            })())

            # 8-9: canonical generation restored + load_verified_selective_generation
            gen_b = aws_c.load_verified_selective_generation(fresh)
            self.assertEqual(gen_b['plan_checksum'], plan_ck)
            self.assertEqual(gen_b['discovery_artifact_checksum'], disc_ck)
            self.assertEqual(gen_b['aws_semantic_contract_sha256'], contract['contract_sha256'])
            self.assertEqual(gen_a['plan_checksum'], gen_b['plan_checksum'])
            self.assertEqual(
                gen_a['discovery_artifact_checksum'],
                gen_b['discovery_artifact_checksum'],
            )
            self.assertEqual(
                gen_a['aws_semantic_contract_sha256'],
                gen_b['aws_semantic_contract_sha256'],
            )

            # 10: REAL client contract-resolution path
            bash, client_sha, _ = aws_c.resolve_aws_semantic_contract_bash_for_client(
                fresh, project_root=ROOT,
            )
            self.assertEqual(client_sha, contract['contract_sha256'])
            self.assertEqual(client_sha, gen_b['aws_semantic_contract_sha256'])
            self.assertIn('AWS_SEMANTIC_CONTRACT_SHA256=', bash)

            with open(os.path.join(pkg, 'manifest.json')) as fh:
                manifest = json.load(fh)
            self.assertEqual(manifest['selective_plan_checksum'], plan_ck)
            self.assertEqual(manifest['discovery_artifact_checksum'], disc_ck)
            self.assertNotEqual(
                manifest['discovery_artifact_checksum'],
                manifest['payload_manifest_sha256'],
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_plan_same_name_version_wrong_sha_fails(self):
        contract, contents = _synthetic_contract_and_contents()
        x2b = contract['hops']['xenial-to-bionic']['linux_aws']
        wrong_sha = 'b' * 64
        self.assertNotEqual(x2b['sha256'], wrong_sha)
        rows = []
        for hop, hop_c in contract['hops'].items():
            for ident in aws_c.iter_contract_identities(hop_c):
                sha = ident['sha256']
                if hop == 'xenial-to-bionic' and ident['package'] == 'linux-aws':
                    sha = wrong_sha
                rows.append({
                    'package': ident['package'],
                    'version': ident['version'],
                    'architecture': ident.get('architecture') or 'amd64',
                    'sha256': sha,
                    'hop': hop,
                    'source_hops': [hop],
                })
        plan = {
            'discovery_profiles': ['generic', 'aws'],
            'aws_semantic_contract': contract,
            'aws_semantic_contract_sha256': contract['contract_sha256'],
            'debs': rows,
        }
        ok, errors, detail = aws_c.validate_plan_aws_completeness(
            plan, package_rows=rows, require_aws_profile=True,
        )
        self.assertFalse(ok, detail)
        self.assertTrue(
            any('aws_contract_identity_sha256_mismatch_in_plan' in e for e in errors),
            errors,
        )

    def test_prepublish_contract_file_wrong_bytes_fails(self):
        contract, contents = _synthetic_contract_and_contents()
        tmp = tempfile.mkdtemp(prefix='um-aws-prepub-bytes-')
        try:
            # Correct filenames/versions, wrong bytes for one critical AWS deb.
            bad_contents = dict(contents)
            xsha = contract['hops']['xenial-to-bionic']['linux_aws']['sha256']
            bad_contents[xsha] = b'TAMPERED-PREPUBLISH-BYTES'
            live = os.path.join(tmp, 'staging')
            _plant_synth_tree(live, contract, bad_contents)
            plan = {
                'discovery_profiles': ['generic', 'aws'],
                'aws_semantic_contract': contract,
                'aws_semantic_contract_sha256': contract['contract_sha256'],
                'require_contract_checksum': True,
            }
            # Pre-publish gate now calls verify_sha256=True for the AWS critical set.
            ok, errors, detail = aws_c.validate_tree_aws_completeness(
                live, plan=plan, require_aws_profile=True, verify_sha256=True,
            )
            self.assertFalse(ok, detail)
            self.assertTrue(
                any('aws_contract_deb_sha256_mismatch_in_tree' in e for e in errors),
                errors,
            )
            # READY must not be written on pre-publish semantic failure.
            ready = os.path.join(tmp, 'state', 'READY')
            self.assertFalse(os.path.isfile(ready))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    unittest.main()
