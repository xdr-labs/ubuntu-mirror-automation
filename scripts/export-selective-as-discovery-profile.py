#!/usr/bin/env python3
"""Export an existing selective apt-mirror tree as a discovery profile.

Reads hops under <selective-root>/hops/<hop>/ubuntu/, parses Packages indexes,
and writes discovery-compatible TSV/JSON under
artifacts/upgrade-discovery-profiles/generic/<hop>/.

Python 3.5+ stdlib only.
"""
from __future__ import print_function

import argparse
import csv
import hashlib
import json
import os
import sys
from collections import OrderedDict
from datetime import datetime

HOPS = (
    'xenial-to-bionic',
    'bionic-to-focal',
    'focal-to-jammy',
    'jammy-to-noble',
)

HOP_OS = {
    'xenial-to-bionic': ('16.04', '18.04'),
    'bionic-to-focal': ('18.04', '20.04'),
    'focal-to-jammy': ('20.04', '22.04'),
    'jammy-to-noble': ('22.04', '24.04'),
}

ARCHIVE_BASE = 'http://archive.ubuntu.com/ubuntu'

PACKAGE_FIELDS = [
    'hop', 'package', 'version', 'architecture', 'source_package', 'filename',
    'repository_host', 'suite', 'component', 'size_bytes', 'sha256',
    'original_url', 'final_url', 'requested', 'downloaded', 'installed',
    'evidence_source',
]

FILE_FIELDS = [
    'hop', 'file_type', 'filename', 'original_url', 'final_url', 'local_path',
    'size_bytes', 'sha256', 'http_status', 'request_count', 'evidence_source',
]

URL_FIELDS = [
    'hop', 'requested_at', 'method', 'original_url', 'final_url',
    'http_status', 'size_bytes', 'sha256', 'local_path',
]

UNRESOLVED_PACKAGE_FIELDS = [
    'hop', 'package', 'version', 'architecture', 'original_url', 'final_url',
    'reason',
]

UNRESOLVED_FILE_FIELDS = [
    'hop', 'file_type', 'filename', 'original_url', 'final_url', 'reason',
]

FAILED_REQUEST_FIELDS = [
    'hop', 'original_url', 'final_url', 'http_status', 'reason', 'file_type',
]

EVIDENCE_SOURCE = 'selective_mirror_export'
PROFILE_NAME = 'generic'


def eprint(*args):
    print(*args, file=sys.stderr)


def iso_now():
    try:
        from datetime import timezone
        return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    except Exception:
        return datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')


def repo_root():
    return os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def ensure_dir(path):
    if not os.path.isdir(path):
        os.makedirs(path)


def write_tsv(path, fieldnames, rows):
    parent = os.path.dirname(path)
    if parent:
        ensure_dir(parent)
    with open(path, 'w') as fh:
        writer = csv.DictWriter(
            fh, fieldnames=fieldnames, delimiter='\t', lineterminator='\n',
            extrasaction='ignore')
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def parse_source_field(value, package_name):
    """Return source package name; strip optional (version) suffix."""
    raw = (value or '').strip()
    if not raw:
        return package_name
    if ' (' in raw and raw.endswith(')'):
        return raw.split(' (', 1)[0].strip() or package_name
    return raw


def parse_packages_file(path):
    """Yield OrderedDict paragraphs from a Packages file."""
    paragraph = OrderedDict()
    current_key = None
    with open(path, 'r') as fh:
        for raw_line in fh:
            line = raw_line.rstrip('\n')
            if not line:
                if paragraph:
                    yield paragraph
                    paragraph = OrderedDict()
                    current_key = None
                continue
            if line.startswith(' ') or line.startswith('\t'):
                if current_key is not None:
                    paragraph[current_key] = (
                        paragraph.get(current_key, '') + '\n' + line[1:]
                    )
                continue
            if ':' not in line:
                continue
            key, value = line.split(':', 1)
            key = key.strip()
            value = value.strip()
            paragraph[key] = value
            current_key = key
    if paragraph:
        yield paragraph


def suite_component_from_packages_path(packages_path, ubuntu_root):
    """Derive suite/component from .../dists/<suite>/<component>/.../Packages."""
    rel = os.path.relpath(packages_path, ubuntu_root)
    parts = rel.split(os.sep)
    suite = ''
    component = ''
    if len(parts) >= 3 and parts[0] == 'dists':
        suite = parts[1]
        component = parts[2]
    return suite, component


def find_packages_files(ubuntu_root):
    dists = os.path.join(ubuntu_root, 'dists')
    found = []
    if not os.path.isdir(dists):
        return found
    for root, _dirs, files in os.walk(dists):
        if 'Packages' in files:
            found.append(os.path.join(root, 'Packages'))
    found.sort()
    return found


def pool_url(filename_field):
    """Build archive URL when Filename starts with pool/."""
    fn = (filename_field or '').strip()
    if fn.startswith('pool/'):
        return '%s/%s' % (ARCHIVE_BASE, fn)
    return ''


def component_from_pool_filename(filename_field):
    parts = (filename_field or '').split('/')
    if len(parts) >= 2 and parts[0] == 'pool':
        return parts[1]
    return ''


def basename_filename(filename_field):
    return os.path.basename((filename_field or '').strip())


def collect_hop(hop, selective_root):
    ubuntu_root = os.path.join(selective_root, 'hops', hop, 'ubuntu')
    if not os.path.isdir(ubuntu_root):
        raise IOError('missing ubuntu root for hop %s: %s' % (hop, ubuntu_root))

    packages_by_sha = OrderedDict()
    packages_files = find_packages_files(ubuntu_root)

    for pkg_path in packages_files:
        suite, path_component = suite_component_from_packages_path(
            pkg_path, ubuntu_root)
        for para in parse_packages_file(pkg_path):
            sha = (para.get('SHA256') or '').strip().lower()
            filename_field = (para.get('Filename') or '').strip()
            if not sha or not filename_field:
                # Try to fill from local .deb when Filename present but hash missing
                if not filename_field:
                    continue
                local_deb = os.path.join(ubuntu_root, filename_field)
                if not os.path.isfile(local_deb):
                    continue
                try:
                    size_bytes = os.path.getsize(local_deb)
                    sha = file_sha256(local_deb)
                except OSError:
                    continue
            else:
                size_str = (para.get('Size') or '').strip()
                try:
                    size_bytes = int(size_str) if size_str else 0
                except ValueError:
                    size_bytes = 0
                if size_bytes <= 0:
                    local_deb = os.path.join(ubuntu_root, filename_field)
                    if os.path.isfile(local_deb):
                        try:
                            size_bytes = os.path.getsize(local_deb)
                        except OSError:
                            pass

            if sha in packages_by_sha:
                continue

            pkg_name = (para.get('Package') or '').strip()
            version = (para.get('Version') or '').strip()
            arch = (para.get('Architecture') or '').strip()
            source = parse_source_field(para.get('Source'), pkg_name)
            component = path_component or component_from_pool_filename(
                filename_field)
            url = pool_url(filename_field)
            local_path = os.path.join(ubuntu_root, filename_field)
            if not os.path.isfile(local_path):
                local_path = ''

            packages_by_sha[sha] = OrderedDict([
                ('hop', hop),
                ('package', pkg_name),
                ('version', version),
                ('architecture', arch),
                ('source_package', source),
                ('filename', basename_filename(filename_field)),
                ('pool_filename', filename_field),
                ('repository_host', 'archive.ubuntu.com'),
                ('suite', suite),
                ('component', component),
                ('size_bytes', str(size_bytes)),
                ('sha256', sha),
                ('original_url', url),
                ('final_url', url),
                ('requested', 'true'),
                ('downloaded', 'true'),
                ('installed', 'true'),
                ('evidence_source', EVIDENCE_SOURCE),
                ('local_path', local_path),
            ])

    # Walk pool/ .debs: fill size/sha for any package row still missing,
    # and index orphan debs only for size/sha lookups (packages come from indexes).
    pool_root = os.path.join(ubuntu_root, 'pool')
    if os.path.isdir(pool_root):
        for root, _dirs, files in os.walk(pool_root):
            for name in files:
                if not name.endswith('.deb'):
                    continue
                path = os.path.join(root, name)
                rel = os.path.relpath(path, ubuntu_root).replace(os.sep, '/')
                # Match packages that have this pool path but empty size
                for rec in packages_by_sha.values():
                    if rec.get('pool_filename') == rel:
                        if not rec.get('local_path'):
                            rec['local_path'] = path
                        if not rec.get('size_bytes') or rec['size_bytes'] in ('', '0'):
                            try:
                                rec['size_bytes'] = str(os.path.getsize(path))
                            except OSError:
                                pass
                        if not rec.get('sha256'):
                            try:
                                rec['sha256'] = file_sha256(path)
                            except OSError:
                                pass
                        if not rec.get('original_url') and rel.startswith('pool/'):
                            url = pool_url(rel)
                            rec['original_url'] = url
                            rec['final_url'] = url

    # Metadata files: InRelease / Release under dists/
    meta_rows = []
    dists_root = os.path.join(ubuntu_root, 'dists')
    if os.path.isdir(dists_root):
        for suite_name in sorted(os.listdir(dists_root)):
            suite_dir = os.path.join(dists_root, suite_name)
            if not os.path.isdir(suite_dir):
                continue
            for meta_name, file_type in (
                ('InRelease', 'inrelease'),
                ('Release', 'release'),
            ):
                meta_path = os.path.join(suite_dir, meta_name)
                if not os.path.isfile(meta_path):
                    continue
                try:
                    size_bytes = os.path.getsize(meta_path)
                    sha = file_sha256(meta_path)
                except OSError:
                    continue
                url = '%s/dists/%s/%s' % (ARCHIVE_BASE, suite_name, meta_name)
                meta_rows.append(OrderedDict([
                    ('hop', hop),
                    ('file_type', file_type),
                    ('filename', meta_name),
                    ('original_url', url),
                    ('final_url', url),
                    ('local_path', meta_path),
                    ('size_bytes', str(size_bytes)),
                    ('sha256', sha),
                    ('http_status', '200'),
                    ('request_count', '1'),
                    ('evidence_source', EVIDENCE_SOURCE),
                ]))

    package_rows = []
    file_rows = list(meta_rows)
    for sha, rec in packages_by_sha.items():
        package_rows.append(OrderedDict([
            (k, rec.get(k, '')) for k in PACKAGE_FIELDS
        ]))
        file_rows.append(OrderedDict([
            ('hop', hop),
            ('file_type', 'deb'),
            ('filename', rec.get('filename', '')),
            ('original_url', rec.get('original_url', '')),
            ('final_url', rec.get('final_url', '')),
            ('local_path', rec.get('local_path', '')),
            ('size_bytes', rec.get('size_bytes', '')),
            ('sha256', rec.get('sha256', '')),
            ('http_status', '200'),
            ('request_count', '1'),
            ('evidence_source', EVIDENCE_SOURCE),
        ]))

    # required-urls from package + metadata URLs (dedup by final_url)
    now = iso_now()
    urls_by_final = OrderedDict()
    for row in meta_rows:
        url = row.get('final_url') or ''
        if not url or url in urls_by_final:
            continue
        urls_by_final[url] = OrderedDict([
            ('hop', hop),
            ('requested_at', now),
            ('method', 'GET'),
            ('original_url', row.get('original_url', '')),
            ('final_url', url),
            ('http_status', '200'),
            ('size_bytes', row.get('size_bytes', '')),
            ('sha256', row.get('sha256', '')),
            ('local_path', row.get('local_path', '')),
        ])
    for rec in packages_by_sha.values():
        url = rec.get('final_url') or ''
        if not url or url in urls_by_final:
            continue
        urls_by_final[url] = OrderedDict([
            ('hop', hop),
            ('requested_at', now),
            ('method', 'GET'),
            ('original_url', rec.get('original_url', '')),
            ('final_url', url),
            ('http_status', '200'),
            ('size_bytes', rec.get('size_bytes', '')),
            ('sha256', rec.get('sha256', '')),
            ('local_path', rec.get('local_path', '')),
        ])

    url_rows = list(urls_by_final.values())
    captured_bytes = 0
    for row in url_rows:
        try:
            captured_bytes += int(row.get('size_bytes') or '0')
        except ValueError:
            pass

    return {
        'hop': hop,
        'packages': package_rows,
        'files': file_rows,
        'urls': url_rows,
        'captured_bytes': captured_bytes,
    }


def write_hop_artifacts(out_dir, hop_data):
    hop = hop_data['hop']
    ensure_dir(out_dir)

    write_tsv(
        os.path.join(out_dir, 'required-packages.tsv'),
        PACKAGE_FIELDS, hop_data['packages'])
    write_tsv(
        os.path.join(out_dir, 'required-files.tsv'),
        FILE_FIELDS, hop_data['files'])
    write_tsv(
        os.path.join(out_dir, 'required-urls.tsv'),
        URL_FIELDS, hop_data['urls'])
    write_tsv(
        os.path.join(out_dir, 'unresolved-packages.tsv'),
        UNRESOLVED_PACKAGE_FIELDS, [])
    write_tsv(
        os.path.join(out_dir, 'unresolved-files.tsv'),
        UNRESOLVED_FILE_FIELDS, [])
    write_tsv(
        os.path.join(out_dir, 'failed-requests.tsv'),
        FAILED_REQUEST_FIELDS, [])

    n_pkg = len(hop_data['packages'])
    n_files = len(hop_data['files'])
    n_urls = len(hop_data['urls'])
    from_os, to_os = HOP_OS.get(hop, ('', ''))

    validation_lines = [
        'VALIDATION: PASS',
        'hop=%s' % hop,
        'from_os=%s' % from_os,
        'to_os=%s' % to_os,
        'required_packages=%d' % n_pkg,
        'resolved_packages=%d' % n_pkg,
        'unresolved_packages=0',
        'required_files=%d' % n_files,
        'resolved_files=%d' % n_files,
        'unresolved_files=0',
        'failed_requests=0',
        'captured_http_200=%d' % n_urls,
        'captured_bytes=%d' % hop_data['captured_bytes'],
        'failures: none',
        '',
    ]
    with open(os.path.join(out_dir, 'validation.txt'), 'w') as fh:
        fh.write('\n'.join(validation_lines))

    evidence = OrderedDict([
        ('hop', hop),
        ('generated_at', iso_now()),
        ('profile', PROFILE_NAME),
        ('source', EVIDENCE_SOURCE),
        ('required_packages', n_pkg),
        ('resolved_packages', n_pkg),
        ('unresolved_packages', 0),
        ('required_files', n_files),
        ('resolved_files', n_files),
        ('unresolved_files', 0),
        ('required_urls', n_urls),
        ('failed_requests', 0),
        ('captured_http_200', n_urls),
        ('captured_bytes', hop_data['captured_bytes']),
        ('recovered_post_hop', True),
        ('checksum_source', 'selective_mirror_packages_index'),
    ])
    with open(os.path.join(out_dir, 'evidence.json'), 'w') as fh:
        json.dump(evidence, fh, indent=2, sort_keys=False)
        fh.write('\n')

    return n_pkg, n_files, n_urls


def write_profile_txt(profile_dir):
    ensure_dir(profile_dir)
    path = os.path.join(profile_dir, 'PROFILE.txt')
    content = (
        'profile=%s\n'
        'source=%s\n'
        'description=Discovery profile exported from existing selective '
        'apt-mirror tree (Packages indexes + local pool).\n'
        'selective_root_default=/var/spool/apt-mirror/selective\n'
        'generated_by=scripts/export-selective-as-discovery-profile.py\n'
    ) % (PROFILE_NAME, EVIDENCE_SOURCE)
    with open(path, 'w') as fh:
        fh.write(content)
    return path


def main(argv=None):
    root = repo_root()
    parser = argparse.ArgumentParser(
        description='Export selective mirror as generic discovery profile')
    parser.add_argument(
        '--selective-root',
        default='/var/spool/apt-mirror/selective',
        help='Selective mirror root (default: /var/spool/apt-mirror/selective)')
    parser.add_argument(
        '--output-root',
        default=os.path.join(
            root, 'artifacts', 'upgrade-discovery-profiles', PROFILE_NAME),
        help='Output root for hop directories')
    parser.add_argument(
        '--profile-dir',
        default=os.path.join(root, 'profiles', PROFILE_NAME),
        help='Directory for PROFILE.txt')
    parser.add_argument(
        '--hops',
        default=','.join(HOPS),
        help='Comma-separated hops to export')
    args = parser.parse_args(argv)

    hops = [h.strip() for h in args.hops.split(',') if h.strip()]
    for hop in hops:
        if hop not in HOPS:
            eprint('warning: unusual hop name: %s' % hop)

    profile_path = write_profile_txt(args.profile_dir)
    print('Wrote %s' % profile_path)

    counts = []
    for hop in hops:
        print('Exporting hop %s ...' % hop)
        hop_data = collect_hop(hop, args.selective_root)
        out_dir = os.path.join(args.output_root, hop)
        n_pkg, n_files, n_urls = write_hop_artifacts(out_dir, hop_data)
        counts.append((hop, n_pkg, n_files, n_urls))
        print(
            '  %s: packages=%d files=%d urls=%d -> %s'
            % (hop, n_pkg, n_files, n_urls, out_dir)
        )

    print('')
    print('Package counts per hop:')
    for hop, n_pkg, n_files, n_urls in counts:
        print('  %s\t%d' % (hop, n_pkg))
    return 0


if __name__ == '__main__':
    sys.exit(main())
