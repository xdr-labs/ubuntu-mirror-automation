"""Multi-profile upgrade-discovery ingestion helpers.

Supports:
  --discovery-root /path/to/single          (implicit profile=generic)
  --discovery-root generic=/path
  --discovery-root aws=/path

Merge rule (deterministic):
  FINAL = UNION of all profiles
  Dedup key preference: sha256 → final/original URL → pool path
  Same package name with different arch/version/hash is preserved.
  Provenance: profile=…,hop=… (comma-joined sorted unique profiles)

Python 3.5+; standard library only.
"""
from __future__ import print_function, unicode_literals

import csv
import os
import re
from collections import OrderedDict

try:
    from urllib.parse import urlparse, urlunparse, unquote
except ImportError:  # pragma: no cover
    from urlparse import urlparse, urlunparse  # type: ignore
    from urllib import unquote  # type: ignore

HOPS = (
    'xenial-to-bionic',
    'bionic-to-focal',
    'focal-to-jammy',
    'jammy-to-noble',
)

HOP_MANIFESTS = (
    'required-packages.tsv',
    'required-files.tsv',
    'required-urls.tsv',
    'unresolved-packages.tsv',
    'unresolved-files.tsv',
    'failed-requests.tsv',
    'evidence.json',
    'validation.txt',
)

EC2_ARCHIVE_HOST_RE = re.compile(
    r'^(?:[a-z0-9-]+\.)?ec2\.archive\.ubuntu\.com$', re.I
)
ALLOWED_UPSTREAM_HOSTS = (
    'archive.ubuntu.com',
    'security.ubuntu.com',
    'old-releases.ubuntu.com',
)


def parse_discovery_root_arg(value):
    """Parse ``profile=path`` or bare ``path`` (profile defaults to generic)."""
    if value is None:
        raise ValueError('empty --discovery-root')
    value = value.strip()
    if not value:
        raise ValueError('empty --discovery-root')
    if '=' in value:
        profile, path = value.split('=', 1)
        profile = profile.strip()
        path = path.strip()
        if not profile:
            raise ValueError('empty profile in --discovery-root %r' % value)
        if not path:
            raise ValueError('empty path in --discovery-root %r' % value)
        if '/' in profile or profile in ('.', '..'):
            raise ValueError('invalid profile name %r' % profile)
        return profile, path
    return 'generic', value


def parse_discovery_root_args(values):
    """Return OrderedDict profile → absolute path (first wins on duplicate)."""
    out = OrderedDict()
    for raw in values or []:
        profile, path = parse_discovery_root_arg(raw)
        if profile in out:
            raise ValueError('duplicate discovery profile %r' % profile)
        out[profile] = os.path.abspath(path)
    return out


def normalize_mirror_host(host):
    host = (host or '').lower()
    if host.startswith('www.'):
        host = host[4:]
    if EC2_ARCHIVE_HOST_RE.match(host):
        return 'archive.ubuntu.com'
    return host


def is_allowed_host(host):
    host = normalize_mirror_host(host)
    if host in ALLOWED_UPSTREAM_HOSTS:
        return True
    if EC2_ARCHIVE_HOST_RE.match(host or ''):
        return True
    return False


def normalize_discovery_url(url):
    """Normalize URL and rewrite EC2 regional archives to archive.ubuntu.com."""
    if not url:
        return ''
    parsed = urlparse(url.strip())
    scheme = (parsed.scheme or 'http').lower()
    host = normalize_mirror_host(parsed.hostname or '')
    netloc = host
    if parsed.port:
        netloc = '%s:%d' % (host, parsed.port)
    path = unquote(parsed.path or '')
    while '//' in path:
        path = path.replace('//', '/')
    return urlunparse((scheme, netloc, path, '', '', ''))


def read_tsv(path):
    if not os.path.isfile(path):
        raise IOError('missing TSV: %s' % path)
    with open(path, 'r') as fh:
        return list(csv.DictReader(fh, delimiter='\t'))


def load_hop_from_root(discovery_root, hop, profile='generic'):
    hop_dir = os.path.join(discovery_root, hop)
    if not os.path.isdir(hop_dir):
        raise IOError('missing hop directory: %s' % hop_dir)
    packages = read_tsv(os.path.join(hop_dir, 'required-packages.tsv'))
    files = read_tsv(os.path.join(hop_dir, 'required-files.tsv'))
    urls = read_tsv(os.path.join(hop_dir, 'required-urls.tsv'))
    unresolved_packages = read_tsv(os.path.join(hop_dir, 'unresolved-packages.tsv'))
    unresolved_files = read_tsv(os.path.join(hop_dir, 'unresolved-files.tsv'))
    unresolved_packages = [r for r in unresolved_packages if any(r.values())]
    unresolved_files = [r for r in unresolved_files if any(r.values())]

    def stamp(rows, kind):
        out = []
        for row in rows:
            r = dict(row)
            r['_profile'] = profile
            r['_kind'] = kind
            # Normalize EC2 hosts early so merge keys are stable.
            for key in ('original_url', 'final_url'):
                if r.get(key):
                    r[key] = normalize_discovery_url(r[key])
            if r.get('repository_host'):
                r['repository_host'] = normalize_mirror_host(r['repository_host'])
            out.append(r)
        return out

    return {
        'hop': hop,
        'profile': profile,
        'dir': hop_dir,
        'packages': stamp(packages, 'package'),
        'files': stamp(files, 'file'),
        'urls': stamp(urls, 'url'),
        'unresolved_packages': stamp(unresolved_packages, 'unresolved_package'),
        'unresolved_files': stamp(unresolved_files, 'unresolved_file'),
    }


def _provenance_join(existing, profile):
    parts = []
    if existing:
        parts.extend([p for p in existing.split(',') if p])
    if profile and profile not in parts:
        parts.append(profile)
    return ','.join(sorted(set(parts)))


def _package_merge_key(row):
    sha = (row.get('sha256') or '').strip().lower()
    if sha:
        return ('sha256', sha)
    url = normalize_discovery_url(
        row.get('final_url') or row.get('original_url') or ''
    )
    if url and '/pool/' in url:
        return ('url', url)
    # pool path from filename + component if present
    fn = unquote(row.get('filename') or '')
    rel = ''
    if url:
        path = urlparse(url).path or ''
        idx = path.find('/pool/')
        if idx >= 0:
            rel = path[idx + 1:]
    if not rel and fn and row.get('component'):
        rel = 'pool/%s/%s' % (row.get('component'), fn)
    if rel:
        return ('pool', rel)
    # last resort: name/version/arch (still preserves distinct versions)
    return (
        'pva',
        '%s|%s|%s' % (
            row.get('package') or '',
            unquote(row.get('version') or ''),
            row.get('architecture') or '',
        ),
    )


def _file_merge_key(row):
    sha = (row.get('sha256') or '').strip().lower()
    if sha:
        return ('sha256', sha)
    url = normalize_discovery_url(
        row.get('final_url') or row.get('original_url') or ''
    )
    if url:
        return ('url', url)
    return ('name', row.get('filename') or row.get('file_type') or '')


def _url_merge_key(row):
    sha = (row.get('sha256') or '').strip().lower()
    url = normalize_discovery_url(
        row.get('final_url') or row.get('original_url') or ''
    )
    if sha:
        return ('sha256', sha)
    if url:
        return ('url', url)
    return ('empty', '')


def merge_hop_profiles(hop_loads):
    """Merge multiple profile loads for the same hop into one hop_data.

    hop_loads: list of load_hop_from_root results for one hop.
    """
    if not hop_loads:
        raise ValueError('no hop loads to merge')
    hop = hop_loads[0]['hop']
    profiles = []
    packages = OrderedDict()
    files = OrderedDict()
    urls = OrderedDict()
    unresolved_packages = []
    unresolved_files = []

    for load in hop_loads:
        profile = load['profile']
        if profile not in profiles:
            profiles.append(profile)
        for row in load['packages']:
            key = _package_merge_key(row)
            if key not in packages:
                r = dict(row)
                r['profile'] = profile
                r['provenance'] = 'profile=%s' % profile
                packages[key] = r
            else:
                existing = packages[key]
                existing['profile'] = _provenance_join(
                    existing.get('profile') or '', profile
                )
                existing['provenance'] = 'profile=%s' % existing['profile']
        for row in load['files']:
            key = _file_merge_key(row)
            if key not in files:
                r = dict(row)
                r['profile'] = profile
                r['provenance'] = 'profile=%s' % profile
                files[key] = r
            else:
                existing = files[key]
                existing['profile'] = _provenance_join(
                    existing.get('profile') or '', profile
                )
                existing['provenance'] = 'profile=%s' % existing['profile']
        for row in load['urls']:
            key = _url_merge_key(row)
            if key == ('empty', ''):
                continue
            if key not in urls:
                r = dict(row)
                r['profile'] = profile
                r['provenance'] = 'profile=%s' % profile
                urls[key] = r
            else:
                existing = urls[key]
                existing['profile'] = _provenance_join(
                    existing.get('profile') or '', profile
                )
                existing['provenance'] = 'profile=%s' % existing['profile']
        unresolved_packages.extend(load['unresolved_packages'])
        unresolved_files.extend(load['unresolved_files'])

    return {
        'hop': hop,
        'profiles': profiles,
        'dir': hop_loads[0]['dir'],
        'packages': list(packages.values()),
        'files': list(files.values()),
        'urls': list(urls.values()),
        'unresolved_packages': unresolved_packages,
        'unresolved_files': unresolved_files,
    }


def load_merged_hops(discovery_roots):
    """Load and union all hops across discovery_roots (OrderedDict profile→path).

    Returns list of merged hop_data in HOPS order.
    """
    if not discovery_roots:
        raise ValueError('at least one --discovery-root is required')
    merged = []
    errors = []
    for hop in HOPS:
        loads = []
        for profile, root in discovery_roots.items():
            hop_dir = os.path.join(root, hop)
            if not os.path.isdir(hop_dir):
                # Allow a profile to cover a subset of hops only when other
                # profiles supply the hop — but require at least one.
                continue
            try:
                loads.append(load_hop_from_root(root, hop, profile=profile))
            except IOError as exc:
                errors.append(str(exc))
        if not loads:
            errors.append('no discovery profile provides hop %s' % hop)
            continue
        merged.append(merge_hop_profiles(loads))
    if errors and len(merged) != len(HOPS):
        raise IOError('; '.join(errors))
    if len(merged) != len(HOPS):
        raise IOError('expected 4 hops after merge, found %d' % len(merged))
    return merged


def aws_kernel_package_name(name):
    """Return True if package belongs to the linux-aws family."""
    n = (name or '').strip()
    if not n:
        return False
    patterns = (
        r'^linux-aws$',
        r'^linux-image-aws$',
        r'^linux-headers-aws$',
        r'^linux-image-.+-aws$',
        r'^linux-modules-.+-aws$',
        r'^linux-headers-.+-aws$',
        r'^linux-aws-.+-headers-.+$',
        r'^linux-aws-.+-tools-.+$',
        r'^linux-tools-.+-aws$',
        r'^linux-modules-extra-.+-aws$',
        r'^linux-aws-edge$',
        r'^linux-image-aws-edge$',
        r'^linux-headers-aws-edge$',
        r'^linux-meta-aws',
        r'^linux-signed-aws',
        r'^linux-aws-\d',
    )
    for pat in patterns:
        if re.match(pat, n):
            return True
    return False
