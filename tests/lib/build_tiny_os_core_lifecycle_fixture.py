#!/usr/bin/env python3
"""Build a tiny hermetic OS Core production-lifecycle fixture.

Produces real dpkg-deb packages, generic+aws discovery roots, a local seed
pool, release-upgrader stubs, and ephemeral signing material. Does NOT modify
tracked production discovery under artifacts/upgrade-discovery-profiles/.

Usage:
  python3 tests/lib/build_tiny_os_core_lifecycle_fixture.py --output-dir /tmp/fx
"""
from __future__ import print_function

import argparse
import csv
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'lib'))

import discovery_profiles as dp  # noqa: E402
from aws_os_core_completeness import linux_aws_meta_to_kernel_release  # noqa: E402

HOPS = list(dp.HOPS)

# Per-hop AWS meta versions (test-local; not production series authority).
# Derived kernel release via linux_aws_meta_to_kernel_release().
AWS_META_BY_HOP = {
    'xenial-to-bionic': '5.4.0.1103.81',
    'bionic-to-focal': '5.15.0.1084.91~20.04.1',
    'focal-to-jammy': '6.8.0-1063.66~22.04.1',
    'jammy-to-noble': '7.0.0-1011.11~24.04.1',
}
SNAPD_X2B = '2.58+18.04.1'
GENERIC_PKG = 'um-lifecycle-hello'
GENERIC_VER = '1.0.0'


def eprint(*args):
    print(*args, file=sys.stderr)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def write_tsv(path, fields, rows):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, 'w', newline='') as fh:
        w = csv.DictWriter(fh, fieldnames=fields, delimiter='\t', lineterminator='\n')
        w.writeheader()
        for row in rows:
            w.writerow({k: row.get(k, '') for k in fields})


def pool_letter(package):
    if package.startswith('lib') and len(package) > 3:
        return 'lib' + package[3]
    return package[0] if package else 'x'


def relative_pool_path(package, version, arch='amd64', component='main'):
    letter = pool_letter(package)
    filename = '%s_%s_%s.deb' % (package, version, arch)
    return 'pool/%s/%s/%s/%s' % (component, letter, package, filename)


def build_real_deb(package, version, arch='amd64', dest_path=None, body=None):
    """Create a real .deb via dpkg-deb --build. Returns (path, sha256, size)."""
    if not shutil.which('dpkg-deb'):
        raise RuntimeError('dpkg-deb required')
    work = tempfile.mkdtemp(prefix='um-tiny-deb-')
    try:
        root = os.path.join(work, 'root')
        debian = os.path.join(root, 'DEBIAN')
        os.makedirs(debian)
        doc = os.path.join(root, 'usr', 'share', 'doc', package)
        os.makedirs(doc)
        payload = body if body is not None else (
            'um-lifecycle-fixture\npackage=%s\nversion=%s\n' % (package, version)
        )
        if isinstance(payload, bytes):
            with open(os.path.join(doc, 'README'), 'wb') as fh:
                fh.write(payload)
        else:
            with open(os.path.join(doc, 'README'), 'w') as fh:
                fh.write(payload)
        with open(os.path.join(debian, 'control'), 'w') as fh:
            fh.write(
                'Package: %s\n'
                'Version: %s\n'
                'Architecture: %s\n'
                'Maintainer: um-lifecycle-fixture <fixture@local>\n'
                'Description: tiny hermetic OS Core lifecycle fixture package\n'
                % (package, version, arch)
            )
        out = dest_path or os.path.join(work, '%s_%s_%s.deb' % (package, version, arch))
        parent = os.path.dirname(out)
        if parent:
            os.makedirs(parent, exist_ok=True)
        subprocess.check_call(
            ['dpkg-deb', '--build', root, out],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        digest = sha256_file(out)
        size = os.path.getsize(out)
        # Copy out of workdir if dest was inside work
        if dest_path is None:
            final = tempfile.NamedTemporaryFile(prefix='um-deb-', suffix='.deb', delete=False)
            final.close()
            shutil.copy2(out, final.name)
            return final.name, digest, size
        return out, digest, size
    finally:
        shutil.rmtree(work, ignore_errors=True)


def pkg_row(hop, package, version, sha256, size_bytes, suite, arch='amd64',
            component='main', source_package=None):
    rel = relative_pool_path(package, version, arch=arch, component=component)
    filename = os.path.basename(rel)
    url = 'http://archive.ubuntu.com/ubuntu/%s' % rel
    return {
        'hop': hop,
        'package': package,
        'version': version,
        'architecture': arch,
        'source_package': source_package or package,
        'filename': filename,
        'repository_host': 'archive.ubuntu.com',
        'suite': suite,
        'component': component,
        'size_bytes': str(size_bytes),
        'sha256': sha256,
        'original_url': url,
        'final_url': url,
        'requested': 'true',
        'downloaded': 'true',
        'installed': 'true',
        'evidence_source': 'apt_archives',
        '_rel_pool': rel,
    }


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
        ('failed-requests.tsv', [
            'hop', 'requested_at', 'method', 'original_url', 'final_url', 'http_status', 'reason',
        ]),
    ):
        write_tsv(os.path.join(d, name), fields, [])
    with open(os.path.join(d, 'validation.txt'), 'w') as fh:
        fh.write(
            'VALIDATION: PASS\nhop=%s\nunresolved_packages=0\nunresolved_files=0\n' % hop
        )
    with open(os.path.join(d, 'evidence.json'), 'w') as fh:
        json.dump(
            {'hop': hop, 'unresolved_packages': 0, 'unresolved_files': 0, 'validation': 'PASS'},
            fh,
        )
        fh.write('\n')
    with open(os.path.join(d, 'export-summary.json'), 'w') as fh:
        json.dump({'hop': hop, 'validation': 'PASS'}, fh)
        fh.write('\n')


def write_profile_marker(root, profile):
    with open(os.path.join(root, 'PROFILE.txt'), 'w') as fh:
        fh.write('profile=%s\n' % profile)
        fh.write('source=um_lifecycle_hermetic_fixture\n')
        fh.write('description=Tiny hermetic discovery for OS Core lifecycle integration.\n')


def make_upgrader(codename, dest_dir, gpg_homedir=None):
    os.makedirs(dest_dir, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix='um-upg-')
    try:
        with open(os.path.join(tmp, 'ReleaseAnnouncement'), 'w') as fh:
            fh.write('ReleaseAnnouncement %s\n' % codename)
        with open(os.path.join(tmp, 'ReleaseAnnouncement.html'), 'w') as fh:
            fh.write('<html>%s</html>\n' % codename)
        tarball = os.path.join(dest_dir, '%s.tar.gz' % codename)
        subprocess.check_call(
            ['tar', '-czf', tarball, './ReleaseAnnouncement', './ReleaseAnnouncement.html'],
            cwd=tmp,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        sig = tarball + '.gpg'
        if gpg_homedir and shutil.which('gpg'):
            subprocess.check_call(
                [
                    'gpg', '--homedir', gpg_homedir, '--batch', '--yes',
                    '--detach-sign', '-o', sig, tarball,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        else:
            with open(sig, 'wb') as fh:
                fh.write(b'UM-LIFECYCLE-UPGRADER-SIG\n')
        return tarball, sig
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def gen_gpg_keys(work):
    if not shutil.which('gpg'):
        raise RuntimeError('gpg required')
    gpg_sel = os.path.join(work, 'gpg-selective')
    gpg_sign = os.path.join(work, 'gpg-client')
    os.makedirs(gpg_sel, mode=0o700)
    os.makedirs(gpg_sign, mode=0o700)
    for home, name, email in (
        (gpg_sel, 'Fixture Selective Mirror', 'selective-lifecycle@local'),
        (gpg_sign, 'Fixture Client Manifest', 'client-lifecycle@local'),
    ):
        batch = os.path.join(home, 'batch')
        with open(batch, 'w') as fh:
            fh.write(
                'Key-Type: RSA\n'
                'Key-Length: 2048\n'
                'Name-Real: %s\n'
                'Name-Email: %s\n'
                'Expire-Date: 0\n'
                '%%no-protection\n'
                '%%commit\n' % (name, email)
            )
        subprocess.check_call(
            ['gpg', '--homedir', home, '--batch', '--gen-key', batch],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    keys = os.path.join(work, 'keys')
    client = os.path.join(work, 'client-signing')
    os.makedirs(keys)
    os.makedirs(client)
    with open(os.path.join(keys, 'ubuntu-mirror-selective.gpg'), 'wb') as fh:
        fh.write(subprocess.check_output(
            ['gpg', '--homedir', gpg_sel, '--batch', '--export', '--armor']
        ))
    with open(os.path.join(keys, 'ubuntu-mirror-selective.private.gpg'), 'wb') as fh:
        fh.write(subprocess.check_output(
            ['gpg', '--homedir', gpg_sel, '--batch', '--export-secret-keys', '--armor']
        ))
    os.chmod(os.path.join(keys, 'ubuntu-mirror-selective.private.gpg'), 0o600)
    with open(os.path.join(client, 'private.gpg'), 'wb') as fh:
        fh.write(subprocess.check_output(
            ['gpg', '--homedir', gpg_sign, '--batch', '--export-secret-keys', '--armor']
        ))
    with open(os.path.join(client, 'public.gpg'), 'wb') as fh:
        fh.write(subprocess.check_output(
            ['gpg', '--homedir', gpg_sign, '--batch', '--export', '--armor']
        ))
    os.chmod(os.path.join(client, 'private.gpg'), 0o600)
    fpr = subprocess.check_output(
        ['gpg', '--homedir', gpg_sign, '--batch', '--with-colons', '--fingerprint'],
        universal_newlines=True,
    )
    fingerprint = ''
    for line in fpr.splitlines():
        if line.startswith('fpr:'):
            fingerprint = line.split(':')[9].upper()
            break
    with open(os.path.join(client, 'fingerprint'), 'w') as fh:
        fh.write(fingerprint + '\n')
    return gpg_sel, gpg_sign


def build_fixture(output_dir):
    output_dir = os.path.abspath(output_dir)
    if os.path.exists(output_dir):
        shutil.rmtree(output_dir)
    os.makedirs(output_dir)

    generic_root = os.path.join(output_dir, 'discovery', 'generic')
    aws_root = os.path.join(output_dir, 'discovery', 'aws')
    seed_ubuntu = os.path.join(output_dir, 'seed', 'ubuntu')
    upgraders_root = os.path.join(output_dir, 'upgraders')
    os.makedirs(seed_ubuntu)
    os.makedirs(generic_root)
    os.makedirs(aws_root)

    gpg_sel, _gpg_sign = gen_gpg_keys(output_dir)
    write_profile_marker(generic_root, 'generic')
    write_profile_marker(aws_root, 'aws')

    inventory = []
    for hop in HOPS:
        from_series, target = hop.split('-to-')
        # Client builders resolve sample .debs from the base target suite
        # (e.g. dists/bionic/.../Packages.gz), so discovery suite must be the
        # base series — not only {target}-updates.
        suite = target
        meta_ver = AWS_META_BY_HOP[hop]
        rel = linux_aws_meta_to_kernel_release(meta_ver)
        if not rel:
            raise RuntimeError('unmapped kernel release for %s ver=%s' % (hop, meta_ver))
        img_pkg = 'linux-image-%s' % rel
        mods_pkg = 'linux-modules-%s' % rel
        extra_pkg = 'linux-modules-extra-%s' % rel

        aws_specs = [
            ('linux-aws', meta_ver, 'linux-meta-aws'),
            ('linux-image-aws', meta_ver, 'linux-meta-aws'),
            (img_pkg, meta_ver, 'linux-signed-aws'),
            (mods_pkg, meta_ver, 'linux-aws'),
            (extra_pkg, meta_ver, 'linux-aws'),
        ]
        if hop == 'xenial-to-bionic':
            aws_specs.append(('snapd', SNAPD_X2B, 'snapd'))

        aws_rows = []
        for package, version, src in aws_specs:
            dest = os.path.join(seed_ubuntu, relative_pool_path(package, version))
            path, digest, size = build_real_deb(
                package, version, dest_path=dest,
                body='AWS|%s|%s|%s\n' % (hop, package, version),
            )
            row = pkg_row(hop, package, version, digest, size, suite, source_package=src)
            aws_rows.append(row)
            inventory.append({
                'profile': 'aws', 'hop': hop, 'package': package,
                'version': version, 'sha256': digest, 'size_bytes': size,
                'relative_pool_path': row['_rel_pool'], 'path': path,
            })

        # One generic-profile package so the plan truly exercises generic ∪ aws.
        # Hop-specific version suffix keeps identities distinct across hops.
        g_ver = '%s+%s' % (GENERIC_VER, target)
        g_dest = os.path.join(seed_ubuntu, relative_pool_path(GENERIC_PKG, g_ver))
        g_path, g_digest, g_size = build_real_deb(
            GENERIC_PKG, g_ver, dest_path=g_dest,
            body='GENERIC|%s|%s\n' % (hop, g_ver),
        )
        g_row = pkg_row(hop, GENERIC_PKG, g_ver, g_digest, g_size, suite)
        inventory.append({
            'profile': 'generic', 'hop': hop, 'package': GENERIC_PKG,
            'version': g_ver, 'sha256': g_digest, 'size_bytes': g_size,
            'relative_pool_path': g_row['_rel_pool'], 'path': g_path,
        })

        # Dist URLs so planner declares full source+target suite set. Pre-publish
        # DistUpgrade mapping requires dists/<from>/Release and dists/<to>/Release.
        suite_list = [
            from_series,
            '%s-updates' % from_series,
            '%s-security' % from_series,
            target,
            '%s-updates' % target,
            '%s-security' % target,
        ]
        urls = []
        for s in suite_list:
            urls.append({
                'hop': hop,
                'requested_at': '',
                'method': 'GET',
                'original_url': 'http://archive.ubuntu.com/ubuntu/dists/%s/InRelease' % s,
                'final_url': 'http://archive.ubuntu.com/ubuntu/dists/%s/InRelease' % s,
                'http_status': '200',
                'size_bytes': '0',
                'sha256': '',
                'local_path': '',
            })

        # Upgrader stubs produced on disk for fixture completeness. They are
        # intentionally NOT listed in discovery required-files so hermetic
        # materialize (--no-download) does not depend on network fetch; the
        # materializer still creates shared/offline/release-upgraders +
        # meta-release-lts placeholders that pre-publish validate accepts.
        make_upgrader(target, os.path.join(upgraders_root, target), gpg_homedir=gpg_sel)

        seed_min_hop(aws_root, hop, aws_rows, files=[], urls=urls)
        seed_min_hop(generic_root, hop, [g_row], files=[], urls=list(urls))

    # Manifest of built packages for the shell test.
    with open(os.path.join(output_dir, 'fixture-inventory.json'), 'w') as fh:
        json.dump({
            'hops': HOPS,
            'aws_meta_by_hop': AWS_META_BY_HOP,
            'packages': inventory,
            'paths': {
                'generic_discovery': generic_root,
                'aws_discovery': aws_root,
                'seed_ubuntu': seed_ubuntu,
                'upgraders': upgraders_root,
                'keys': os.path.join(output_dir, 'keys'),
                'client_signing': os.path.join(output_dir, 'client-signing'),
            },
        }, fh, indent=2, sort_keys=True)
        fh.write('\n')

    # Env-friendly path file for bash.
    with open(os.path.join(output_dir, 'fixture.env'), 'w') as fh:
        fh.write('FIXTURE_ROOT=%s\n' % output_dir)
        fh.write('GENERIC_DISCOVERY=%s\n' % generic_root)
        fh.write('AWS_DISCOVERY=%s\n' % aws_root)
        fh.write('SEED_UBUNTU=%s\n' % seed_ubuntu)
        fh.write('UPGRADERS_ROOT=%s\n' % upgraders_root)
        fh.write('SELECTIVE_PUBLIC_KEY=%s\n' % os.path.join(output_dir, 'keys', 'ubuntu-mirror-selective.gpg'))
        fh.write('SELECTIVE_PRIVATE_KEY=%s\n' % os.path.join(output_dir, 'keys', 'ubuntu-mirror-selective.private.gpg'))
        fh.write('CLIENT_SIGNING_DIR=%s\n' % os.path.join(output_dir, 'client-signing'))

    print('FIXTURE_ROOT=%s' % output_dir)
    print('GENERIC_DISCOVERY=%s' % generic_root)
    print('AWS_DISCOVERY=%s' % aws_root)
    print('SEED_UBUNTU=%s' % seed_ubuntu)
    print('PACKAGE_COUNT=%d' % len(inventory))
    return output_dir


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', required=True)
    args = parser.parse_args(argv)
    build_fixture(args.output_dir)
    return 0


if __name__ == '__main__':
    sys.exit(main())
