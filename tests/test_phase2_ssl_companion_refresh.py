#!/usr/bin/env python3
"""Sealed field-release migration recognizes only the known SSL omission."""
import json
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / 'scripts/lib/mirror_install_engine.sh'


class SslCompanionReleaseRefreshTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ssl-companion-release.')
        self.root = Path(self.tmp.name)
        self.manifest = (self.root / '6.6.0/extras/'
                         'phase2-ubuntu-prerequisites.manifest.json')
        self.manifest.parent.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def required(self, rows):
        self.manifest.write_text(json.dumps({'packages': rows}))
        script = ('source "$1"; MM_DP_PHASE2_ROOT="$2"; '
                  'TARGET_DP_VERSION=6.6.0; '
                  'engine_phase2_ssl_companion_refresh_required')
        return subprocess.run(
            ['bash', '-c', script, 'policy-test', str(ENGINE), str(self.root)],
            env=os.environ.copy(), capture_output=True, text=True,
        )

    def test_exact_known_sealed_omission_needs_refresh(self):
        result = self.required([
            {'package': 'libssl3t64', 'version': '3.0.13-0ubuntu3.15'},
            {'package': 'openssl', 'version': '3.0.13-0ubuntu3.15'},
        ])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_companion_already_present_preserves_seal(self):
        self.assertNotEqual(self.required([
            {'package': 'libssl3t64', 'version': '3.0.13-0ubuntu3.15'},
            {'package': 'libssl-dev', 'version': '3.0.13-0ubuntu3.15'},
        ]).returncode, 0)

    def test_unrelated_version_never_autoreseals(self):
        self.assertNotEqual(self.required([
            {'package': 'libssl3t64', 'version': '3.0.13-0ubuntu3.16'},
        ]).returncode, 0)

    def test_invalid_manifest_not_republished(self):
        self.manifest.write_text('invalid-json')
        script = ('source "$1"; MM_DP_PHASE2_ROOT="$2"; '
                  'TARGET_DP_VERSION=6.6.0; '
                  'engine_phase2_ssl_companion_refresh_required')
        result = subprocess.run(['bash', '-c', script, 'policy-test',
                                 str(ENGINE), str(self.root)], capture_output=True,
                                text=True)
        self.assertNotEqual(result.returncode, 0)

    def test_missing_manifest_not_republished(self):
        self.assertNotEqual(self.required([]).returncode, 0)
        self.manifest.unlink()
        script = ('source "$1"; MM_DP_PHASE2_ROOT="$2"; '
                  'TARGET_DP_VERSION=6.6.0; '
                  'engine_phase2_ssl_companion_refresh_required')
        result = subprocess.run(['bash', '-c', script, 'policy-test',
                                 str(ENGINE), str(self.root)], capture_output=True,
                                text=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
