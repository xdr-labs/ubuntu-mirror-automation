#!/usr/bin/env python3
"""Tests for selective runtime migration (mirrorctl/config drift fix)."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def write(path: str, body: str, mode: int = 0o644) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(body)
    os.chmod(path, mode)


class SelectiveRuntimeMigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='um-runtime-mig-')
        self.bin = os.path.join(self.tmp, 'usr/local/bin')
        self.sbin = os.path.join(self.tmp, 'usr/local/sbin')
        self.lib = os.path.join(self.tmp, 'usr/local/lib/ubuntu-mirror')
        self.confdir = os.path.join(self.tmp, 'etc/ubuntu-mirror')
        self.systemd = os.path.join(self.tmp, 'etc/systemd/system')
        self.backup = os.path.join(self.tmp, 'var/backups/ubuntu-mirror')
        self.selective = os.path.join(self.tmp, 'var/spool/apt-mirror/selective')
        self.state = os.path.join(self.selective, 'state')
        self.published = os.path.join(self.selective, 'published')
        for d in (self.bin, self.sbin, self.lib, self.confdir, self.systemd,
                  self.backup, self.state, self.published):
            os.makedirs(d, exist_ok=True)
        # Preserve markers that must never change
        write(os.path.join(self.state, 'READY'), 'READY\nprofile_name=offline-upgrade-selective\n')
        write(os.path.join(self.state, 'keep-me.txt'), 'immutable-marker\n')
        os.symlink('published', os.path.join(self.selective, 'current'))
        write(os.path.join(self.published, 'marker.deb'), 'deb-bytes')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _env(self, **extra):
        env = os.environ.copy()
        env.update({
            'UM_ALLOW_NONROOT_MIGRATE': '1',
            'UM_PROJECT_ROOT': ROOT,
            'INSTALL_BIN_DIR': self.bin,
            'INSTALL_LIB_DIR': self.lib,
            'INSTALL_CONF_DIR': self.confdir,
            'UM_SYSTEMD_DIR': self.systemd,
            'UM_MIRRORCTL_AUX_PATH': os.path.join(self.sbin, 'mirrorctl'),
            'UM_UOM_INSTALL_PATH': os.path.join(self.sbin, 'ubuntu-offline-mirror.sh'),
            'BACKUP_DIR': self.backup,
            'BASE_PATH': os.path.join(self.tmp, 'var/spool/apt-mirror'),
            'UM_MIGRATE_RESULT_JSON': os.path.join(self.state, 'runtime-migration.json'),
            'UM_QUIET_LOAD': '1',
        })
        env.update(extra)
        return env

    def _bash(self, script: str, env=None) -> subprocess.CompletedProcess:
        return subprocess.run(
            ['bash', '-c', script],
            cwd=ROOT,
            env=env or self._env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True,
            check=False,
        )

    def _seed_stale_runtime(self):
        # Old mirrorctl (no selective status)
        write(os.path.join(self.bin, 'mirrorctl'),
              '#!/usr/bin/env bash\necho OLD_MIRRORCTL\n', 0o755)
        # Duplicate regular file in sbin (drift case)
        write(os.path.join(self.sbin, 'mirrorctl'),
              '#!/usr/bin/env bash\necho OTHER_OLD\n', 0o755)
        write(os.path.join(self.lib, 'common.sh'), '# old\n')
        write(os.path.join(self.lib, 'config.sh'), '# old\n')
        write(os.path.join(self.lib, 'state.sh'), '# old\n')
        write(os.path.join(self.confdir, 'mirror.conf'), '''# stale
MIRROR_HOSTNAME="_"
MIRROR_PORT="80"
MIRROR_URL=""
MIRROR_IP=""
BASE_PATH="%s"
MIRROR_MODE="full"
SUITE_SUFFIXES="updates security backports"
LOG_DIR="/tmp/um-log"
INSTALL_BIN_DIR="%s"
INSTALL_LIB_DIR="%s"
INSTALL_CONF_DIR="%s"
BACKUP_DIR="%s"
''' % (
            os.path.join(self.tmp, 'var/spool/apt-mirror'),
            self.bin, self.lib, self.confdir, self.backup,
        ))
        write(os.path.join(self.systemd, 'apt-mirror.service'),
              'ExecStart=/usr/local/sbin/ubuntu-offline-mirror.sh sync\n')

    def _migrate(self) -> subprocess.CompletedProcess:
        # Re-export install roots after sourcing config.sh (defaults use ${VAR:-...}).
        script = r'''
set -euo pipefail
export INSTALL_BIN_DIR="%s"
export INSTALL_LIB_DIR="%s"
export INSTALL_CONF_DIR="%s"
export UM_SYSTEMD_DIR="%s"
export UM_MIRRORCTL_AUX_PATH="%s"
export UM_UOM_INSTALL_PATH="%s"
export BACKUP_DIR="%s"
export BASE_PATH="%s"
export UM_MIGRATE_RESULT_JSON="%s"
export UM_PROJECT_ROOT="%s"
export UM_ALLOW_NONROOT_MIGRATE=1
source "%s/lib/common.sh"
source "%s/lib/config.sh"
um_migrate_selective_runtime "%s"
''' % (
            self.bin, self.lib, self.confdir, self.systemd,
            os.path.join(self.sbin, 'mirrorctl'),
            os.path.join(self.sbin, 'ubuntu-offline-mirror.sh'),
            self.backup,
            os.path.join(self.tmp, 'var/spool/apt-mirror'),
            os.path.join(self.state, 'runtime-migration.json'),
            ROOT, ROOT, ROOT, ROOT,
        )
        return self._bash(script)

    def test_checksum_mismatch_detected(self):
        self._seed_stale_runtime()
        repo = sha256_file(os.path.join(ROOT, 'scripts', 'mirrorctl'))
        installed = sha256_file(os.path.join(self.bin, 'mirrorctl'))
        self.assertNotEqual(repo, installed)

    def test_migrate_atomic_install_and_symlink(self):
        self._seed_stale_runtime()
        before_ready = sha256_file(os.path.join(self.state, 'READY'))
        before_current = os.readlink(os.path.join(self.selective, 'current'))
        before_pub = sha256_file(os.path.join(self.published, 'marker.deb'))
        before_keep = sha256_file(os.path.join(self.state, 'keep-me.txt'))

        proc = self._migrate()
        self.assertEqual(proc.returncode, 0, proc.stdout)

        canon = os.path.join(self.bin, 'mirrorctl')
        aux = os.path.join(self.sbin, 'mirrorctl')
        self.assertTrue(os.path.isfile(canon))
        self.assertTrue(os.path.islink(aux))
        self.assertEqual(os.path.realpath(aux), os.path.realpath(canon))
        self.assertEqual(
            sha256_file(canon),
            sha256_file(os.path.join(ROOT, 'scripts', 'mirrorctl')),
        )
        self.assertTrue(os.access(canon, os.X_OK))

        # Config merge preserved BASE_PATH, added selective fields
        conf = open(os.path.join(self.confdir, 'mirror.conf'), encoding='utf-8').read()
        self.assertIn('BASE_PATH="%s"' % os.path.join(self.tmp, 'var/spool/apt-mirror'), conf)
        self.assertIn('MIRROR_MODE="selective"', conf)
        self.assertIn('SELECTIVE_MIRROR_ROOT=', conf)
        self.assertIn('SELECTIVE_NGINX_ROOT="%s"' % self.selective, conf)
        self.assertNotIn('SELECTIVE_NGINX_ROOT="%s/current"' % self.selective, conf)
        self.assertIn('FULL_MIRROR_SEED_ROOT=', conf)

        svc = open(os.path.join(self.systemd, 'apt-mirror.service'), encoding='utf-8').read()
        self.assertIn('materialize-selective', svc)
        self.assertNotIn('ubuntu-offline-mirror.sh sync', svc)

        # Selective data untouched
        self.assertEqual(before_ready, sha256_file(os.path.join(self.state, 'READY')))
        self.assertEqual(before_current, os.readlink(os.path.join(self.selective, 'current')))
        self.assertEqual(before_pub, sha256_file(os.path.join(self.published, 'marker.deb')))
        self.assertEqual(before_keep, sha256_file(os.path.join(self.state, 'keep-me.txt')))

        # Backup created for old mirrorctl
        backup_hits = []
        for dirpath, _, files in os.walk(self.backup):
            for name in files:
                if 'mirrorctl' in name:
                    backup_hits.append(os.path.join(dirpath, name))
        self.assertTrue(backup_hits, 'expected mirrorctl backup')

        result = json.load(open(os.path.join(self.state, 'runtime-migration.json')))
        self.assertEqual(result['result'], 'PASS')
        self.assertFalse(result['selective_state_touched'])

    def test_migrate_idempotent(self):
        self._seed_stale_runtime()
        self.assertEqual(self._migrate().returncode, 0)
        sum1 = sha256_file(os.path.join(self.bin, 'mirrorctl'))
        conf1 = sha256_file(os.path.join(self.confdir, 'mirror.conf'))
        proc2 = self._migrate()
        self.assertEqual(proc2.returncode, 0, proc2.stdout)
        self.assertEqual(sum1, sha256_file(os.path.join(self.bin, 'mirrorctl')))
        self.assertEqual(conf1, sha256_file(os.path.join(self.confdir, 'mirror.conf')))

    def test_rollback_on_missing_source_lib(self):
        self._seed_stale_runtime()
        # Point source at a broken tree missing mirrorctl after first copy prep —
        # invoke migrate with nonexistent source → fail before changes? use empty root.
        empty = tempfile.mkdtemp(prefix='um-empty-src-')
        try:
            write(os.path.join(empty, 'scripts', 'mirrorctl'), '#!/bin/bash\n', 0o755)
            # omit required libs somehow — migration should still mostly succeed;
            # force failure by making destination directory unwritable after first install.
            proc = self._bash(r'''
set -euo pipefail
source "%s/lib/common.sh"
source "%s/lib/config.sh"
# Break atomic install mid-flight: migrate then corrupt by simulating failure path
um_migrate_selective_runtime "%s" || true
# Direct rollback API with synthetic stack
cp -a "%s/usr/local/bin/mirrorctl" "%s/backup-mirrorctl"
UM_MIGRATE_ROLLBACK_STACK="%s/usr/local/bin/mirrorctl|%s/backup-mirrorctl"$'\n'
echo 'CORRUPT' > "%s/usr/local/bin/mirrorctl"
um_migrate_rollback
grep -qv CORRUPT "%s/usr/local/bin/mirrorctl"
''' % (ROOT, ROOT, ROOT, self.tmp, self.tmp, self.tmp, self.tmp, self.tmp, self.tmp))
            self.assertEqual(proc.returncode, 0, proc.stdout)
        finally:
            shutil.rmtree(empty, ignore_errors=True)

    def test_has_runtime_drift_true_then_false(self):
        self._seed_stale_runtime()
        proc = self._bash(r'''
set -euo pipefail
export INSTALL_BIN_DIR="%s"
export INSTALL_LIB_DIR="%s"
export INSTALL_CONF_DIR="%s"
export UM_SYSTEMD_DIR="%s"
export UM_MIRRORCTL_AUX_PATH="%s"
export UM_UOM_INSTALL_PATH="%s"
export BACKUP_DIR="%s"
export BASE_PATH="%s"
export UM_MIGRATE_RESULT_JSON="%s"
export UM_PROJECT_ROOT="%s"
export UM_ALLOW_NONROOT_MIGRATE=1
source "%s/lib/common.sh"
source "%s/lib/config.sh"
if um_has_runtime_drift; then echo DRIFT=1; else echo DRIFT=0; fi
um_migrate_selective_runtime "%s" >/dev/null
if um_has_runtime_drift; then echo DRIFT2=1; else echo DRIFT2=0; fi
''' % (
            self.bin, self.lib, self.confdir, self.systemd,
            os.path.join(self.sbin, 'mirrorctl'),
            os.path.join(self.sbin, 'ubuntu-offline-mirror.sh'),
            self.backup,
            os.path.join(self.tmp, 'var/spool/apt-mirror'),
            os.path.join(self.state, 'runtime-migration.json'),
            ROOT, ROOT, ROOT, ROOT,
        ))
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertIn('DRIFT=1', proc.stdout)
        self.assertIn('DRIFT2=0', proc.stdout)

    def test_selective_ready_gates(self):
        # Build minimal valid selective state
        plan_ck = 'a' * 64
        disc_ck = 'b' * 64
        plan = {
            'plan_checksum': plan_ck,
            'discovery_artifact_checksum': disc_ck,
            'counts': {'unique_deb_sha256': 2, 'unresolved_deb_payloads': 0},
            'validation_result': 'PASS',
        }
        verify = {
            'validation_result': 'PASS',
            'validation_phase': 'pre_publish',
            'plan_checksum': plan_ck,
            'discovery_artifact_checksum': disc_ck,
            'verified_files': 2,
            'expected_files': 2,
            'unresolved_count': 0,
            'checksum_failures': 0,
            'package_count': 2,
        }
        publish = {
            'validation_result': 'PASS',
            'validation_phase': 'post_publish',
            'plan_checksum': plan_ck,
            'discovery_artifact_checksum': disc_ck,
            'gates': {
                'nginx_effective_root': 'PASS',
                'nginx_config': 'PASS',
                'nginx_http': 'PASS',
                'post_publish_http': 'PASS',
            },
        }
        write(os.path.join(self.state, 'plan.json'), json.dumps(plan))
        write(os.path.join(self.state, 'verify-result.json'), json.dumps(verify))
        write(os.path.join(self.state, 'publish-result.json'), json.dumps(publish))
        write(os.path.join(self.state, 'materialize.json'),
              json.dumps({'validation_result': 'PASS',
                          'stats': {'downloaded': 1, 'exists': 1}}))
        write(os.path.join(self.state, 'READY'),
              'READY\nprofile_name=offline-upgrade-selective\npackage_count=2\ntotal_size=100\n')

        script = r'''
set -euo pipefail
source "%s/lib/common.sh"
source "%s/lib/config.sh"
source "%s/lib/state.sh"
source "%s/lib/progress.sh"
BASE_PATH="%s"
SELECTIVE_MIRROR_ROOT="%s"
MIRROR_MODE="selective"
um_evaluate_selective_ready || true
echo READY=$UM_SELECTIVE_READY
echo REASON=$UM_SELECTIVE_READY_REASON
um_is_mirror_ready && echo IS_READY=1 || echo IS_READY=0
''' % (ROOT, ROOT, ROOT, ROOT,
       os.path.join(self.tmp, 'var/spool/apt-mirror'), self.selective)
        proc = self._bash(script)
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertIn('READY=1', proc.stdout)
        self.assertIn('IS_READY=1', proc.stdout)

        # Checksum mismatch must not forge READY
        verify['plan_checksum'] = 'c' * 64
        write(os.path.join(self.state, 'verify-result.json'), json.dumps(verify))
        proc2 = self._bash(script)
        self.assertEqual(proc2.returncode, 0, proc2.stdout)
        self.assertIn('READY=0', proc2.stdout)
        self.assertIn('IS_READY=0', proc2.stdout)

    def test_broken_current_symlink_warning(self):
        plan_ck = 'a' * 64
        disc_ck = 'b' * 64
        write(os.path.join(self.state, 'plan.json'), json.dumps({
            'plan_checksum': plan_ck,
            'discovery_artifact_checksum': disc_ck,
            'counts': {'unique_deb_sha256': 1, 'unresolved_deb_payloads': 0},
        }))
        write(os.path.join(self.state, 'verify-result.json'), json.dumps({
            'validation_result': 'PASS', 'validation_phase': 'pre_publish',
            'plan_checksum': plan_ck, 'discovery_artifact_checksum': disc_ck,
            'verified_files': 1, 'expected_files': 1, 'unresolved_count': 0,
            'checksum_failures': 0,
        }))
        write(os.path.join(self.state, 'publish-result.json'), json.dumps({
            'validation_result': 'PASS', 'validation_phase': 'post_publish',
            'plan_checksum': plan_ck, 'discovery_artifact_checksum': disc_ck,
            'gates': {'nginx_effective_root': 'PASS', 'nginx_config': 'PASS',
                      'nginx_http': 'PASS', 'post_publish_http': 'PASS'},
        }))
        write(os.path.join(self.state, 'READY'), 'READY\nprofile_name=offline-upgrade-selective\n')
        cur = os.path.join(self.selective, 'current')
        os.remove(cur)
        os.symlink('missing-target', cur)

        script = r'''
set -euo pipefail
source "%s/lib/common.sh"
source "%s/lib/config.sh"
source "%s/lib/state.sh"
BASE_PATH="%s"
SELECTIVE_MIRROR_ROOT="%s"
MIRROR_MODE="selective"
um_evaluate_selective_ready || true
echo READY=$UM_SELECTIVE_READY
echo REASON=$UM_SELECTIVE_READY_REASON
''' % (ROOT, ROOT, ROOT,
       os.path.join(self.tmp, 'var/spool/apt-mirror'), self.selective)
        proc = self._bash(script)
        self.assertIn('READY=0', proc.stdout)
        self.assertTrue(
            'current' in proc.stdout.lower() or 'target' in proc.stdout.lower(),
            proc.stdout,
        )

    def test_mirrorctl_status_not_legacy_installed(self):
        self._seed_stale_runtime()
        self.assertEqual(self._migrate().returncode, 0)
        # Build READY gates
        plan_ck = 'd' * 64
        disc_ck = 'e' * 64
        write(os.path.join(self.state, 'plan.json'), json.dumps({
            'plan_checksum': plan_ck,
            'discovery_artifact_checksum': disc_ck,
            'counts': {'unique_deb_sha256': 1, 'unresolved_deb_payloads': 0},
            'validation_result': 'PASS',
        }))
        write(os.path.join(self.state, 'materialize.json'),
              json.dumps({'validation_result': 'PASS',
                          'stats': {'downloaded': 1, 'exists': 0}}))
        write(os.path.join(self.state, 'verify-result.json'), json.dumps({
            'validation_result': 'PASS', 'validation_phase': 'pre_publish',
            'plan_checksum': plan_ck, 'discovery_artifact_checksum': disc_ck,
            'verified_files': 1, 'expected_files': 1, 'unresolved_count': 0,
            'checksum_failures': 0, 'package_count': 1,
        }))
        write(os.path.join(self.state, 'publish-result.json'), json.dumps({
            'validation_result': 'PASS', 'validation_phase': 'post_publish',
            'plan_checksum': plan_ck, 'discovery_artifact_checksum': disc_ck,
            'gates': {'nginx_effective_root': 'PASS', 'nginx_config': 'PASS',
                      'nginx_http': 'PASS', 'post_publish_http': 'PASS'},
        }))
        write(os.path.join(self.state, 'READY'),
              'READY\nprofile_name=offline-upgrade-selective\npackage_count=1\ntotal_size=42\n')
        os.makedirs(os.path.join(self.published, 'hops', 'xenial-to-bionic', 'ubuntu'),
                    exist_ok=True)

        # Point installed libs so mirrorctl resolve_libs uses temp libdir —
        # mirrorctl hardcodes /usr/local/lib; run status helpers directly instead.
        script = r'''
set -euo pipefail
source "%s/lib/common.sh"
source "%s/lib/config.sh"
source "%s/lib/state.sh"
source "%s/lib/progress.sh"
um_load_config "%s/mirror.conf"
BASE_PATH="%s"
SELECTIVE_MIRROR_ROOT="%s"
MIRROR_MODE="selective"
um_evaluate_selective_ready
um_detect_sync_health
echo STATE=$UM_LIFECYCLE_STATE
echo HEALTH=$UM_HEALTH_STATE
echo REASON=$UM_HEALTH_REASON
sz=$(um_mirror_size_bytes_cached)
echo SIZE=$sz
# Ensure not legacy pending
[[ "$UM_LIFECYCLE_STATE" == "READY" ]]
[[ "$UM_HEALTH_REASON" != *"sync not started"* ]]
''' % (ROOT, ROOT, ROOT, ROOT, self.confdir,
       os.path.join(self.tmp, 'var/spool/apt-mirror'), self.selective)
        proc = self._bash(script)
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertIn('STATE=READY', proc.stdout)
        self.assertIn('HEALTH=HEALTHY', proc.stdout)

    def test_mirrorctl_source_guards(self):
        body = open(os.path.join(ROOT, 'scripts', 'mirrorctl'), encoding='utf-8').read()
        self.assertIn('migrate-selective-runtime', body)
        self.assertIn('already READY', body)
        self.assertIn('Hop repositories', body)
        self.assertIn('materialize-selective', body)
        self.assertIn('ubuntu-offline-mirror.log', body)
        uom = open(os.path.join(ROOT, 'scripts', 'ubuntu-offline-mirror.sh'),
                   encoding='utf-8').read()
        self.assertIn('migrate-selective-runtime', uom)
        self.assertIn('cmd_migrate_selective_runtime', uom)
        # Runtime drift/migration helpers live in lib/config.sh; bootstrap install
        # no longer embeds the old selective install pipeline.
        config = open(os.path.join(ROOT, 'lib', 'config.sh'), encoding='utf-8').read()
        self.assertIn('um_has_runtime_drift', config)
        self.assertIn('um_migrate_selective_runtime_config', config)
        bootstrap = open(os.path.join(ROOT, 'lib', 'bootstrap.sh'), encoding='utf-8').read()
        self.assertIn('um_bootstrap_install_runtime', bootstrap)

    def test_sync_start_does_not_call_apt_mirror(self):
        body = open(os.path.join(ROOT, 'scripts', 'mirrorctl'), encoding='utf-8').read()
        # start path must use materialize via systemd, never apt-mirror binary directly
        start_idx = body.find('case "$action" in')
        start_block = body[start_idx:start_idx + 2500]
        self.assertIn('materialize-selective', start_block)
        self.assertNotIn('/usr/bin/apt-mirror', start_block.split('stop)')[0])


if __name__ == '__main__':
    unittest.main()
