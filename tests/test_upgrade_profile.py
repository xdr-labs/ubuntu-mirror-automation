#!/usr/bin/env python3
"""Fixture tests for offline-upgrade-selective profile validation."""
from __future__ import print_function

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'lib'))

import validate_upgrade_profile as vup  # noqa: E402

PROFILE = os.path.join(ROOT, 'config', 'offline-upgrade-profile.json')
EXCEPTIONS = os.path.join(ROOT, 'config', 'offline-upgrade-exceptions.json')


def write(path, content):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, 'w') as fh:
        fh.write(content)


class SelectiveUpgradeProfileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='um-sel-prof-')
        self.profile = json.load(open(PROFILE))
        self.conf = os.path.join(self.tmp, 'mirror.conf')
        write(self.conf, 'MIRROR_MODE="selective"\n')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_selective_profile_ssot(self):
        self.assertEqual(self.profile['profile_name'], 'offline-upgrade-selective')
        self.assertEqual(self.profile['selection_mode'], 'discovery_exact')
        self.assertFalse(self.profile['requirements']['by_hash'])
        self.assertEqual(len(self.profile['supported_hops']), 4)

    def test_selective_config_pass(self):
        cfg = vup.validate_config(self.profile, '', self.conf, EXCEPTIONS)
        self.assertEqual(cfg['validation_result'], 'PASS', cfg)

    def test_minimal_mode_fail(self):
        write(self.conf, 'MIRROR_MODE="minimal"\n')
        cfg = vup.validate_config(self.profile, '', self.conf, EXCEPTIONS)
        self.assertEqual(cfg['validation_result'], 'FAIL')
        self.assertIn('UNSUPPORTED_MINIMAL_PROFILE', cfg['error_codes'])

    def test_full_mode_fail(self):
        write(self.conf, 'MIRROR_MODE="full"\n')
        cfg = vup.validate_config(self.profile, '', self.conf, EXCEPTIONS)
        self.assertEqual(cfg['validation_result'], 'FAIL')
        self.assertIn('UNSUPPORTED_FULL_MIRROR_SYNC', cfg['error_codes'])

    def test_is_selective_helper(self):
        self.assertTrue(vup.is_selective_profile(self.profile))

    def test_payload_without_plan_fails(self):
        mirror_root = os.path.join(self.tmp, 'mirror')
        os.makedirs(mirror_root)
        # Point plan path to missing file via temp profile copy
        profile = dict(self.profile)
        profile['discovery_plan_path'] = os.path.join(self.tmp, 'missing-plan.json')
        payload = vup.validate_payload_selective(profile, mirror_root, project_root=ROOT)
        self.assertEqual(payload['validation_result'], 'FAIL')

    def test_shell_rejects_full_and_minimal(self):
        script = '''
set -e
UM_PROJECT_ROOT="%s"
source "%s/lib/upgrade-profile.sh"
um_assert_supported_mirror_mode selective
um_assert_supported_mirror_mode minimal && exit 10 || true
um_assert_supported_mirror_mode full && exit 11 || true
echo OK
''' % (ROOT, ROOT)
        out = subprocess.check_output(['bash', '-c', script], stderr=subprocess.STDOUT)
        self.assertIn(b'OK', out)

    def test_install_help_mentions_selective_or_rejects_minimal(self):
        # ensure upgrade-profile.sh default name
        text = open(os.path.join(ROOT, 'lib', 'upgrade-profile.sh')).read()
        self.assertIn('offline-upgrade-selective', text)
        self.assertIn('um_reject_full_sync_request', text)
        self.assertNotIn('eval "$(python3', text)

    def test_shell_profile_parser_does_not_execute_json_as_code(self):
        project = os.path.join(self.tmp, 'project')
        config_dir = os.path.join(project, 'config')
        os.makedirs(config_dir)
        sentinel = os.path.join(self.tmp, 'PROFILE_EVAL_PWNED')
        malicious = dict(self.profile)
        # Python repr historically selected double quotes for this value; shell
        # eval could then execute command substitution as root.
        malicious['selective_mirror_root'] = "/tmp/profile';$(touch %s);#" % sentinel
        with open(os.path.join(config_dir, 'offline-upgrade-profile.json'), 'w') as fh:
            json.dump(malicious, fh)
        script = r'''
set -u
um_warn() { :; }
UM_PROJECT_ROOT="$1"
source "$2/lib/upgrade-profile.sh"
um_load_upgrade_profile
'''
        proc = subprocess.run(
            ['bash', '-c', script, '_', project, ROOT],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        self.assertNotEqual(proc.returncode, 0, proc.stdout.decode('utf-8', 'replace'))
        self.assertFalse(os.path.exists(sentinel), proc.stdout.decode('utf-8', 'replace'))


if __name__ == '__main__':
    unittest.main()
