#!/usr/bin/env python3
"""Deterministic Phase 2 bringup patcher: fresh upstream + project layer."""
from __future__ import print_function, unicode_literals

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
LIB = os.path.join(ROOT, 'scripts', 'lib')
sys.path.insert(0, LIB)

import patch_dp_phase2_bringup as patcher  # noqa: E402

FIXTURE = os.path.join(
    ROOT, 'tests', 'fixtures', 'dp-phase2', 'upstream_bringup_unpatched.sh',
)
VENDOR = os.path.join(
    ROOT, 'vendor', 'dp-phase2', 'bringup_py3_dp_after_os_upgrade.sh',
)
ENGINE = os.path.join(ROOT, 'scripts', 'lib', 'mirror_install_engine.sh')
PRODUCTION_F1A73 = os.path.join(
    ROOT, 'tests', 'fixtures', 'dp-phase2', 'production-f1a73',
    'bringup_py3_dp_after_os_upgrade.sh',
)
PRODUCTION_F1A73_SHA1 = 'f1a73c1d4502e2efcf55197865d2ade345d9c82f'
F1A73_VENDOR_MARKERS = (
    'STANDBY_IPS=""',
    'AELDEV-73583',
    '--relabel-elastic',
    'token_extra="&standby=1"',
    'Orchestrate workers + standby',
    '${skip_flag}',
    'RELABEL_ELASTIC_ONLY',
)
HELP_PREV = (
    '                echo "  --worker-ips <ip,ip>    Comma-separated worker IPs (master orchestrates)"\n'
    '                echo "  --role <role>           Override auto-detect (AIO|DR-master|DL-master|DR-worker|DL-worker)"\n'
)
HELP_F1A73 = (
    '                echo "  --worker-ips <ip,ip>    Comma-separated worker IPs (master orchestrates)"\n'
    '                echo "  --standby <ip[,ip]>     Standby node IP(s) -- orchestrated like workers but with"\n'
    '                echo "                          role standby, always AFTER the workers. May be used with"\n'
    '                echo "                          or without --worker-ips."\n'
    '                echo "  --role <role>           Override auto-detect (AIO|DR-master|DL-master|DR-worker|DL-worker|standby)"\n'
)


class PatchGenerationTests(unittest.TestCase):
    def test_generation_is_stable_hex(self):
        a = patcher.patch_generation_id()
        b = patcher.patch_generation_id()
        self.assertEqual(a, b)
        self.assertEqual(len(a), 40)
        self.assertRegex(a, r'^[0-9a-f]{40}$')


class FreshUpstreamPatchTests(unittest.TestCase):
    def setUp(self):
        with open(FIXTURE, 'r', encoding='utf-8') as fh:
            self.upstream = fh.read()
        self.assertNotIn('--worker-password', self.upstream)

    def test_a_adds_worker_password(self):
        out, _applied = patcher.patch_bringup_text(self.upstream, emit=False)
        self.assertIn('--worker-password', out)
        self.assertIn('--worker-ips/--standby requires --worker-password-file', out)

    def test_b_preserves_new_upstream_vendor_marker(self):
        src = self.upstream.replace(
            'log "download_artifacts placeholder"',
            'log "download_artifacts placeholder"\n    NEW_UPSTREAM_VENDOR_FIX_MARKER=YES',
        )
        self.assertIn('NEW_UPSTREAM_VENDOR_FIX_MARKER=YES', src)
        out, _applied = patcher.patch_bringup_text(src, emit=False)
        self.assertIn('NEW_UPSTREAM_VENDOR_FIX_MARKER=YES', out)
        self.assertIn('--worker-password', out)
        self.assertIn('MASTER_TOKEN_API_READY', out)
        self.assertIn('APT_DEPENDENCY_CHECK', out)
        self.assertIn('CLUSTER_JOIN_STATE', out)

    def test_c_compatible_unrelated_drift_succeeds(self):
        src = self.upstream.replace(
            'log "download_artifacts placeholder"',
            'log "download_artifacts placeholder"\n    # UNRELATED_UPSTREAM_COMMENT',
        )
        out, _applied = patcher.patch_bringup_text(src, emit=False)
        self.assertIn('# UNRELATED_UPSTREAM_COMMENT', out)
        self.assertIn('wait_for_master_token_api', out)

    def test_d_incompatible_anchor_fails_closed(self):
        src = self.upstream.replace(
            '            --worker-ips)\n'
            '                WORKER_IPS="$2"; shift 2 ;;\n',
            '            --worker-ips)\n'
            '                WORKER_IPS="$2"; shift 2 ;;\n'
            '            --worker-ips-alt)\n'
            '                : ;;\n',
        )
        with self.assertRaises(patcher.PatchCompatError) as ctx:
            patcher.patch_bringup_text(src, emit=False)
        self.assertEqual(ctx.exception.transform, 'parse_args_worker_password_case')
        self.assertIn('anchor_count=0', ctx.exception.reason)

    def test_e_generated_is_not_frozen_vendor_copy(self):
        out, _applied = patcher.patch_bringup_text(self.upstream, emit=False)
        self.assertNotEqual(out, self.upstream)
        self.assertIn('--worker-password-file', out)
        with open(ENGINE, 'r', encoding='utf-8') as fh:
            engine = fh.read()
        self.assertNotIn(
            'cp -f "$patched" "$dest"',
            engine,
        )
        self.assertIn('BRINGUP_PATCH_MODEL=fresh_upstream_plus_project_layer', engine)

    def test_result_markers_and_syntax(self):
        tmp = tempfile.mkdtemp()
        try:
            dest = os.path.join(tmp, 'patched.sh')
            result = patcher.patch_bringup_file(FIXTURE, dest)
            self.assertNotEqual(result['patched_sha1'], result['upstream_sha1'])
            with open(dest, 'r', encoding='utf-8') as fh:
                text = fh.read()
            for marker in patcher.RESULT_MARKERS:
                self.assertIn(marker, text, marker)
            rc = os.system("bash -n %s" % dest)
            self.assertEqual(rc, 0)
        finally:
            shutil.rmtree(tmp)

    def test_does_not_modify_upstream_input(self):
        tmp = tempfile.mkdtemp()
        try:
            src = os.path.join(tmp, 'upstream.sh')
            dest = os.path.join(tmp, 'patched.sh')
            shutil.copy2(FIXTURE, src)
            with open(src, 'rb') as fh:
                before = fh.read()
            patcher.patch_bringup_file(src, dest)
            with open(src, 'rb') as fh2:
                after = fh2.read()
            self.assertEqual(before, after)
            with open(dest, 'rb') as fh3:
                self.assertNotEqual(fh3.read(), before)
        finally:
            shutil.rmtree(tmp)


class MappingHelperTests(unittest.TestCase):
    def test_zero_matches_fails_closed(self):
        with self.assertRaises(patcher.PatchCompatError) as ctx:
            patcher.replace_exactly_one_mapping(
                'aaa', (('bbb', 'ccc'), ('ddd', 'eee')), 't',
            )
        self.assertEqual(ctx.exception.transform, 't')
        self.assertEqual(ctx.exception.reason, 'anchor_count=0 expected=1')

    def test_duplicate_occurrence_fails_closed(self):
        with self.assertRaises(patcher.PatchCompatError) as ctx:
            patcher.replace_exactly_one_mapping(
                'xxx yyy xxx', (('xxx', 'z'),), 't',
            )
        self.assertEqual(ctx.exception.reason, 'anchor_count=2 expected=1')

    def test_ambiguous_alternatives_fail_closed(self):
        with self.assertRaises(patcher.PatchCompatError) as ctx:
            patcher.replace_exactly_one_mapping(
                'aaa bbb', (('aaa', 'A'), ('bbb', 'B')), 't',
            )
        self.assertIn('multiple_alternative_anchors', ctx.exception.reason)


class ProductionF1a73PatchTests(unittest.TestCase):
    def setUp(self):
        with open(PRODUCTION_F1A73, 'r', encoding='utf-8') as fh:
            self.upstream = fh.read()
        with open(PRODUCTION_F1A73, 'rb') as fh:
            self.raw = fh.read()
        self.assertEqual(hashlib.sha1(self.raw).hexdigest(), PRODUCTION_F1A73_SHA1)
        self.assertNotIn('--worker-password', self.upstream)

    def _patch(self, src=None):
        return patcher.patch_bringup_text(
            src if src is not None else self.upstream, emit=False,
        )

    def test_fixture_sha1_is_production_f1a73(self):
        self.assertEqual(
            hashlib.sha1(self.raw).hexdigest(), PRODUCTION_F1A73_SHA1,
        )

    def test_previous_upstream_still_patches(self):
        with open(FIXTURE, 'r', encoding='utf-8') as fh:
            prev = fh.read()
        out, applied = patcher.patch_bringup_text(prev, emit=False)
        self.assertEqual(len(applied), 17)
        for marker in patcher.RESULT_MARKERS:
            self.assertIn(marker, out, marker)

    def test_f1a73_patch_generation_pass(self):
        tmp = tempfile.mkdtemp()
        try:
            dest = os.path.join(tmp, 'patched.sh')
            result = patcher.patch_bringup_file(PRODUCTION_F1A73, dest)
            self.assertEqual(result['upstream_sha1'], PRODUCTION_F1A73_SHA1)
            self.assertNotEqual(result['patched_sha1'], result['upstream_sha1'])
            with open(dest, 'r', encoding='utf-8') as fh:
                text = fh.read()
            for marker in patcher.RESULT_MARKERS:
                self.assertIn(marker, text, marker)
            rc = os.system("bash -n %s" % dest)
            self.assertEqual(rc, 0)
            self.assertNotEqual(text, self.upstream)
            with open(PRODUCTION_F1A73, 'rb') as fh:
                self.assertEqual(
                    hashlib.sha1(fh.read()).hexdigest(), PRODUCTION_F1A73_SHA1,
                )
        finally:
            shutil.rmtree(tmp)

    def test_f1a73_vendor_changes_preserved(self):
        out, _applied = self._patch()
        for marker in F1A73_VENDOR_MARKERS:
            self.assertIn(marker, out, marker)
        self.assertIn('--worker-password', out)
        self.assertIn('wait_for_master_token_api', out)
        self.assertIn('copy_phase2_prereq_contract_to_worker', out)
        self.assertIn('# BEGIN_IMAGE_IMPORT_HEARTBEAT', out)
        self.assertIn('emit_dp_resume_notice_line', out)
        self.assertIn('validate_apt_dependency_graph', out)
        self.assertIn('validate_critical_python_runtime', out)
        self.assertIn('validate_expected_cluster_nodes', out)

    def test_missing_anchor_fails_closed(self):
        src = self.upstream.replace(HELP_F1A73, '', 1)
        self.assertNotEqual(src, self.upstream)
        with self.assertRaises(patcher.PatchCompatError) as ctx:
            self._patch(src)
        self.assertEqual(ctx.exception.transform, 'parse_args_worker_password_help')
        self.assertEqual(ctx.exception.reason, 'anchor_count=0 expected=1')

    def test_duplicate_anchor_fails_closed(self):
        src = self.upstream.replace(HELP_F1A73, HELP_F1A73 + HELP_F1A73, 1)
        with self.assertRaises(patcher.PatchCompatError) as ctx:
            self._patch(src)
        self.assertEqual(ctx.exception.transform, 'parse_args_worker_password_help')
        self.assertEqual(ctx.exception.reason, 'anchor_count=2 expected=1')

    def test_ambiguous_alternative_anchors_fail_closed(self):
        src = self.upstream.replace(HELP_F1A73, HELP_F1A73 + HELP_PREV, 1)
        with self.assertRaises(patcher.PatchCompatError) as ctx:
            self._patch(src)
        self.assertEqual(ctx.exception.transform, 'parse_args_worker_password_help')
        self.assertIn('multiple_alternative_anchors', ctx.exception.reason)

    def test_cli_emits_fail_transform_and_reason(self):
        tmp = tempfile.mkdtemp()
        try:
            src = os.path.join(tmp, 'upstream.sh')
            dest = os.path.join(tmp, 'patched.sh')
            mutated = self.upstream.replace(HELP_F1A73, '', 1)
            with open(src, 'w', encoding='utf-8') as fh:
                fh.write(mutated)
            proc = subprocess.Popen(
                [
                    sys.executable,
                    os.path.join(LIB, 'patch_dp_phase2_bringup.py'),
                    '--upstream', src,
                    '--output', dest,
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
            )
            out, _err = proc.communicate()
            self.assertEqual(proc.returncode, 2)
            self.assertIn(
                'BRINGUP_PATCH_COMPAT_FAIL_TRANSFORM=parse_args_worker_password_help',
                out,
            )
            self.assertIn(
                'BRINGUP_PATCH_COMPAT_FAIL_REASON=anchor_count=0 expected=1',
                out,
            )
            self.assertIn('BRINGUP_PATCH_COMPAT=FAIL', out)
            self.assertIn('PATCHED_BRINGUP_GENERATION=FAIL', out)
        finally:
            shutil.rmtree(tmp)


PRODUCTION_3AF369 = os.path.join(
    ROOT, 'tests', 'fixtures', 'dp-phase2', 'production-3af369',
    'bringup_py3_dp_after_os_upgrade.sh',
)
PRODUCTION_3AF369_SHA1 = '3af369660c3e0dfb0b7421ab455dee1ced365b1d'
N3_VENDOR_MARKERS = (
    'STANDBY_IPS=""',
    'AELDEV-73583',
    'token_extra="&standby=1"',
    'wait_for_da_restful_8003',
    'rebuild_resolv_conf',
    'AELDEV-74638',
)


class Production3af369PatchTests(unittest.TestCase):
    def setUp(self):
        with open(PRODUCTION_3AF369, 'r', encoding='utf-8') as fh:
            self.upstream = fh.read()
        with open(PRODUCTION_3AF369, 'rb') as fh:
            self.raw = fh.read()
        self.assertEqual(hashlib.sha1(self.raw).hexdigest(), PRODUCTION_3AF369_SHA1)

    def test_fixture_sha1_is_production_3af369(self):
        self.assertEqual(
            hashlib.sha1(self.raw).hexdigest(), PRODUCTION_3AF369_SHA1,
        )

    def test_3af369_patch_generation_pass(self):
        tmp = tempfile.mkdtemp()
        try:
            dest = os.path.join(tmp, 'patched.sh')
            result = patcher.patch_bringup_file(PRODUCTION_3AF369, dest)
            self.assertEqual(result['upstream_sha1'], PRODUCTION_3AF369_SHA1)
            self.assertNotEqual(result['patched_sha1'], result['upstream_sha1'])
            with open(dest, 'r', encoding='utf-8') as fh:
                text = fh.read()
            for marker in patcher.RESULT_MARKERS:
                self.assertIn(marker, text, marker)
            for marker in N3_VENDOR_MARKERS:
                self.assertIn(marker, text, marker)
            self.assertIn('ACPS_PY3_APT_DPKG', text)
            self.assertIn('validate_apt_dependency_graph', text)
            self.assertNotIn(
                'WARNING: critical python3 module(s) failed to import', text,
            )
            rc = os.system("bash -n %s" % dest)
            self.assertEqual(rc, 0)
            with open(PRODUCTION_3AF369, 'rb') as fh:
                self.assertEqual(
                    hashlib.sha1(fh.read()).hexdigest(), PRODUCTION_3AF369_SHA1,
                )
        finally:
            shutil.rmtree(tmp)

    def test_3af369_validate_matches_generate(self):
        proc = subprocess.Popen(
            [
                sys.executable,
                os.path.join(LIB, 'patch_dp_phase2_bringup.py'),
                '--validate',
                '--upstream', PRODUCTION_3AF369,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
        )
        out, _err = proc.communicate()
        self.assertEqual(proc.returncode, 0)
        self.assertIn('BRINGUP_PATCH_COMPAT=PASS', out)
        self.assertIn('PATCHED_BRINGUP_GENERATION=PASS', out)

    def test_3af369_mutated_anchor_fails_closed(self):
        src = self.upstream.replace(
            '            dpkg -i --force-depends "${install_list[@]}" 2>&1 | tail -10 || \\\n'
            '                    log "WARNING: some debs in py3-apt-packages.tar.gz failed (continuing)"\n',
            '            dpkg -i --force-depends "${install_list[@]}" || true\n',
            1,
        )
        self.assertNotEqual(src, self.upstream)
        with self.assertRaises(patcher.PatchCompatError) as ctx:
            patcher.patch_bringup_text(src, emit=False)
        self.assertEqual(
            ctx.exception.transform, 'install_python3_dpkg_no_force_depends',
        )
        self.assertEqual(ctx.exception.reason, 'anchor_count=0 expected=1')


if __name__ == '__main__':
    unittest.main()
