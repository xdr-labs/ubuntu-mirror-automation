#!/usr/bin/env python3
"""Malicious-archive regression tests for phase2 safe tar extraction."""
from __future__ import print_function, unicode_literals

import io
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
LIB = os.path.join(ROOT, 'scripts', 'lib')
sys.path.insert(0, LIB)

import phase2_ubuntu_prerequisites as p2p  # noqa: E402


def make_deb(path):
    work = tempfile.mkdtemp(prefix='tar-safety-deb-')
    try:
        os.makedirs(os.path.join(work, 'DEBIAN'))
        with open(os.path.join(work, 'DEBIAN', 'control'), 'w') as fh:
            fh.write(
                'Package: phase2-prereq-fixture\n'
                'Version: 1.0\n'
                'Architecture: all\n'
                'Maintainer: test\n'
                'Description: fixture\n',
            )
        os.makedirs(os.path.dirname(path), exist_ok=True)
        subprocess.check_call(
            ['dpkg-deb', '-b', work, path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    finally:
        shutil.rmtree(work, ignore_errors=True)


def build_valid_prereq_archive(path):
    staging = tempfile.mkdtemp(prefix='tar-safety-valid-')
    try:
        os.makedirs(os.path.join(staging, 'debs'))
        deb = os.path.join(staging, 'debs', 'phase2-prereq-fixture_1.0_all.deb')
        make_deb(deb)
        with open(os.path.join(staging, p2p.INSTALL_ORDER_NAME), 'w') as fh:
            fh.write('phase2-prereq-fixture_1.0_all.deb\n')
        with open(os.path.join(staging, p2p.MANIFEST_NAME), 'w') as fh:
            fh.write('{"package_count":1}\n')
        with tarfile.open(path, 'w:gz') as tf:
            for name in (
                p2p.MANIFEST_NAME,
                p2p.INSTALL_ORDER_NAME,
                'debs/phase2-prereq-fixture_1.0_all.deb',
            ):
                tf.add(os.path.join(staging, name), arcname=name)
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def build_valid_acps_archive(path):
    staging = tempfile.mkdtemp(prefix='tar-safety-acps-')
    try:
        deb = os.path.join(staging, 'fixture_1_all.deb')
        with open(deb, 'wb') as fh:
            fh.write(b'acps\n')
        with tarfile.open(path, 'w:gz') as tf:
            tf.add(deb, arcname='fixture_1_all.deb')
    finally:
        shutil.rmtree(staging, ignore_errors=True)


class Phase2PrereqTarSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='tar-safety-')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _extract_dir(self):
        path = os.path.join(self.tmp, 'extract')
        os.makedirs(path, exist_ok=True)
        return path

    def _assert_rejects(self, archive_path, fn):
        with tarfile.open(archive_path, 'r:*') as tf:
            with self.assertRaises(ValueError, msg=fn.__name__):
                fn(tf, self._extract_dir())

    def test_valid_prereq_and_acps_archives_extract(self):
        prereq = os.path.join(self.tmp, 'valid-prereq.tar.gz')
        build_valid_prereq_archive(prereq)
        extract = self._extract_dir()
        with tarfile.open(prereq, 'r:gz') as tf:
            p2p._validate_prereq_artifact_members(tf.getmembers())
            p2p.safe_extract_py3_apt_archive(
                tf, extract,
                ignore_members=(p2p.MANIFEST_NAME, p2p.INSTALL_ORDER_NAME),
            )
            p2p._safe_extract_prereq_non_deb_files(
                tf, extract, (p2p.MANIFEST_NAME, p2p.INSTALL_ORDER_NAME),
            )
        self.assertTrue(os.path.isfile(
            os.path.join(extract, 'debs', 'phase2-prereq-fixture_1.0_all.deb'),
        ))
        self.assertTrue(os.path.isfile(os.path.join(extract, p2p.INSTALL_ORDER_NAME)))

        acps = os.path.join(self.tmp, 'valid-acps.tar.gz')
        build_valid_acps_archive(acps)
        acps_extract = os.path.join(self.tmp, 'acps-extract')
        with tarfile.open(acps, 'r:gz') as tf:
            names = p2p.safe_extract_py3_apt_archive(tf, acps_extract)
        self.assertEqual(names, ['fixture_1_all.deb'])
        self.assertTrue(os.path.isfile(os.path.join(acps_extract, 'fixture_1_all.deb')))

    def test_rejects_path_traversal(self):
        path = os.path.join(self.tmp, 'trav.tar.gz')
        with tarfile.open(path, 'w:gz') as tf:
            info = tarfile.TarInfo(name='../evil.deb')
            data = b'evil'
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
        self._assert_rejects(path, p2p.safe_extract_py3_apt_archive)

    def test_rejects_absolute_path(self):
        path = os.path.join(self.tmp, 'abs.tar.gz')
        with tarfile.open(path, 'w:gz') as tf:
            info = tarfile.TarInfo(name='/etc/evil.deb')
            data = b'x'
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
        self._assert_rejects(path, p2p.safe_extract_py3_apt_archive)

    def test_rejects_symlink(self):
        path = os.path.join(self.tmp, 'sym.tar.gz')
        with tarfile.open(path, 'w:gz') as tf:
            info = tarfile.TarInfo(name='debs/link.deb')
            info.type = tarfile.SYMTYPE
            info.linkname = '/etc/passwd'
            tf.addfile(info)
        self._assert_rejects(path, p2p.safe_extract_py3_apt_archive)

    def test_rejects_hardlink(self):
        path = os.path.join(self.tmp, 'hard.tar.gz')
        with tarfile.open(path, 'w:gz') as tf:
            info = tarfile.TarInfo(name='debs/a.deb')
            data = b'abc'
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
            hard = tarfile.TarInfo(name='debs/b.deb')
            hard.type = tarfile.LNKTYPE
            hard.linkname = 'debs/a.deb'
            tf.addfile(hard)
        self._assert_rejects(path, p2p.safe_extract_py3_apt_archive)

    def test_rejects_unexpected_member(self):
        path = os.path.join(self.tmp, 'extra.tar.gz')
        with tarfile.open(path, 'w:gz') as tf:
            info = tarfile.TarInfo(name='evil.sh')
            data = b'#!/bin/sh\n'
            info.size = len(data)
            info.mode = 0o755
            tf.addfile(info, io.BytesIO(data))
        self._assert_rejects(path, p2p.safe_extract_py3_apt_archive)

    def test_rejects_fifo(self):
        path = os.path.join(self.tmp, 'fifo.tar.gz')
        with tarfile.open(path, 'w:gz') as tf:
            info = tarfile.TarInfo(name='debs/x.deb')
            info.type = tarfile.FIFOTYPE
            tf.addfile(info)
        self._assert_rejects(path, p2p.safe_extract_py3_apt_archive)

    def test_rejects_duplicate_member(self):
        path = os.path.join(self.tmp, 'dup.tar.gz')
        with tarfile.open(path, 'w:gz') as tf:
            for _ in range(2):
                info = tarfile.TarInfo(name='debs/a.deb')
                data = b'abc'
                info.size = len(data)
                tf.addfile(info, io.BytesIO(data))
        self._assert_rejects(path, p2p.safe_extract_py3_apt_archive)

    def test_rejects_setuid_bit(self):
        path = os.path.join(self.tmp, 'setuid.tar.gz')
        with tarfile.open(path, 'w:gz') as tf:
            info = tarfile.TarInfo(name='debs/setuid.deb')
            data = b'abc'
            info.size = len(data)
            info.mode = stat.S_ISUID | 0o644
            tf.addfile(info, io.BytesIO(data))
        self._assert_rejects(path, p2p.safe_extract_py3_apt_archive)

    def test_prereq_validate_rejects_nested_deb_path(self):
        path = os.path.join(self.tmp, 'nested.tar.gz')
        with tarfile.open(path, 'w:gz') as tf:
            info = tarfile.TarInfo(name='debs/nested/pkg.deb')
            data = b'abc'
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
        with tarfile.open(path, 'r:gz') as tf:
            with self.assertRaises(ValueError):
                p2p._validate_prereq_artifact_members(tf.getmembers())


if __name__ == '__main__':
    unittest.main()
