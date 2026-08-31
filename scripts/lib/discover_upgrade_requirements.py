#!/usr/bin/env python3
"""Helpers for Ubuntu upgrade requirements discovery.

Fixture-friendly parsing and manifest generation. No live apt/do-release-upgrade.
Compatible with Python 3.5+ (Ubuntu 16.04 Xenial).
"""
from __future__ import print_function

import sys

if sys.version_info < (3, 5):
    sys.stderr.write(
        'ERROR: discover_upgrade_requirements.py requires Python 3.5+\n'
        'Found: Python {}.{}.{}\n'.format(
            sys.version_info[0], sys.version_info[1], sys.version_info[2]
        )
    )
    sys.exit(2)

import argparse
import hashlib
import json
import os
import re
import shutil
import urllib.parse
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple
HOP_MAP = {('16.04', '18.04'): 'xenial-to-bionic', ('18.04', '20.04'): 'bionic-to-focal', ('20.04', '22.04'): 'focal-to-jammy', ('22.04', '24.04'): 'jammy-to-noble'}
CODENAME_TO_VERSION = {'xenial': '16.04', 'bionic': '18.04', 'focal': '20.04', 'jammy': '22.04', 'noble': '24.04'}
VERSION_TO_CODENAME = {v: k for k, v in CODENAME_TO_VERSION.items()}
HOP_ORDER = [
    'xenial-to-bionic',
    'bionic-to-focal',
    'focal-to-jammy',
    'jammy-to-noble',
]
HOP_FROM_TO = {
    'xenial-to-bionic': ('16.04', '18.04'),
    'bionic-to-focal': ('18.04', '20.04'),
    'focal-to-jammy': ('20.04', '22.04'),
    'jammy-to-noble': ('22.04', '24.04'),
}
EXPORT_MANIFEST_FILES = [
    'required-packages.tsv',
    'required-files.tsv',
    'required-urls.tsv',
    'unresolved-packages.tsv',
    'unresolved-files.tsv',
    'failed-requests.tsv',
    'evidence.json',
    'validation.txt',
]
EXPORT_CHECKSUM_FILES = EXPORT_MANIFEST_FILES + ['export-summary.json']
EXPORT_INDEX_HEADER = [
    'hop', 'from_os', 'to_os', 'validation',
    'required_packages', 'required_files', 'required_urls',
    'unresolved_packages', 'unresolved_files', 'failed_requests',
    'failed_requests_total', 'failed_requests_blocking', 'failed_requests_non_blocking',
    'recovered_post_hop', 'exported_at_utc', 'relative_path',
]
EXPORT_REPO_METADATA_TYPES = frozenset([
    'inrelease', 'release', 'release_gpg', 'packages_index', 'sources_index',
    'translation', 'contents', 'dep11', 'cnf',
])
EXPORT_CRITICAL_FAILED_TYPES = frozenset(['deb', 'udeb', 'release_upgrader'])
ACCESS_RE = re.compile('^(?P<ts>\\S+\\s+\\S+|\\d{4}-\\d{2}-\\d{2}T\\S+|\\d+)\\s+(?:\\[(?P<brack_ts>[^\\]]+)\\]\\s+)?(?P<client>\\S+)\\s+(?:\\"(?P<method>[A-Z]+)\\s+(?P<url>[^\\"]+)\\s+HTTP/[^\\"]+\\"|(?P<bare_url>https?://\\S+|\\S+))\\s+(?P<status>\\d{3})\\s+(?P<size>\\d+|-)?(?:\\s+(?P<extra>.*))?$')
SIMPLE_RE = re.compile('^(?P<ts>\\S+)\\s+(?P<method>GET|HEAD|POST)\\s+(?P<url>https?://\\S+)\\s+(?P<status>\\d{3})\\s+(?P<size>\\d+|-)(?P<extra>.*)$')
REDIRECT_RE = re.compile('^(?P<ts>\\S+)\\s+REDIRECT\\s+(?P<original>https?://\\S+)\\s+->\\s+(?P<final>https?://\\S+)\\s+(?P<status>\\d{3})$')
DEB_NAME_RE = re.compile('^(?P<package>[^_]+)_(?P<version>.+)_(?P<arch>[^_]+)\\.(?P<ext>deb|udeb)$')
SELFTEST_URL_MARKERS = ('dur-recorder-self-test', 'dur-proxy-self-test-')
MUTABLE_FILE_TYPES = frozenset([
    'inrelease', 'release', 'release_gpg', 'packages_index', 'sources_index',
    'translation', 'contents', 'dep11', 'cnf', 'by_hash', 'meta_release',
    'release_upgrader', 'dist_upgrade',
])
DUR_REPAIR_NONCE_PARAM = 'dur_repair_nonce'


def is_recorder_selftest_url(url):
    if not url:
        return False
    lower = url.lower()
    for marker in SELFTEST_URL_MARKERS:
        if marker in lower:
            return True
    return False


def parse_log_extras(extra):
    """Parse trailing key=value tokens from a proxy access log line."""
    out = {'final': '', 'sha256': '', 'local_path': '', 'redirects': '', 'content_length': ''}
    if not extra:
        return out
    for tok in extra.split():
        if '=' not in tok:
            continue
        key, val = tok.split('=', 1)
        key = key.lower()
        if key == 'final':
            out['final'] = val
        elif key == 'sha256':
            out['sha256'] = val
        elif key == 'local_path':
            out['local_path'] = val
        elif key in ('redirects', 'redirect_chain'):
            out['redirects'] = val
        elif key == 'content_length':
            out['content_length'] = val
    return out


def url_storage_key(url):
    return hashlib.sha256(url.encode('utf-8', 'surrogateescape')).hexdigest()


def object_paths_for_url(cache_dir, url):
    key = url_storage_key(url)
    directory = Path(cache_dir) / key[0:2] / key[2:4]
    final_path = directory / key
    meta_path = Path(str(final_path) + '.meta.json')
    return (final_path, meta_path, key)


def load_capture_meta(path):
    try:
        return json.loads(read_text(path))
    except Exception:
        return {}


def local_body_ok(local_path, expected_sha=''):
    """Return (exists, sha_ok, actual_sha)."""
    if not local_path:
        return (False, False, '')
    p = Path(local_path)
    if not p.is_file():
        return (False, False, '')
    try:
        actual = sha256_file(p)
    except Exception:
        return (True, False, '')
    if expected_sha and actual.lower() != expected_sha.lower():
        return (True, False, actual)
    return (True, True, actual)


def _as_path_str(path):
    return str(path)


def fs_decode(data):
    """Decode path/log bytes without losing non-UTF-8 sequences (PEP 383)."""
    if isinstance(data, str):
        return data
    return data.decode('utf-8', 'surrogateescape')


def open_text(path, mode='r'):
    """Text I/O safe under LC_ALL=C (never use locale default encoding)."""
    return open(_as_path_str(path), mode, encoding='utf-8', errors='surrogateescape')


def read_text(path):
    """Read entire text file with UTF-8 + surrogateescape."""
    with open(_as_path_str(path), 'rb') as fh:
        return fs_decode(fh.read())


def write_text(path, text):
    """Write text with UTF-8 + surrogateescape (round-trip safe for paths)."""
    parent = os.path.dirname(_as_path_str(path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    with open_text(path, 'w') as fh:
        fh.write(text)


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

def hop_name(from_os: str, to_os: str) -> str:
    from_os = normalize_version(from_os)
    to_os = normalize_version(to_os)
    key = (from_os, to_os)
    if key not in HOP_MAP:
        raise ValueError('unsupported hop {} -> {}'.format(from_os, to_os))
    return HOP_MAP[key]

def normalize_version(value: str) -> str:
    v = value.strip().lower()
    if v in CODENAME_TO_VERSION:
        return CODENAME_TO_VERSION[v]
    if v in VERSION_TO_CODENAME:
        return v
    m = re.search('(\\d+\\.\\d+)', v)
    if m and m.group(1) in VERSION_TO_CODENAME:
        return m.group(1)
    raise ValueError('unknown Ubuntu release: {}'.format(value))

def classify_url(url: str) -> str:
    path = urllib.parse.urlparse(url).path
    base = os.path.basename(path)
    lower = base.lower()
    full = path.lower()
    if '/by-hash/' in full:
        return 'by_hash'
    if lower.endswith('.deb'):
        return 'deb'
    if lower.endswith('.udeb'):
        return 'udeb'
    if lower == 'inrelease':
        return 'inrelease'
    if lower == 'release.gpg':
        return 'release_gpg'
    if lower == 'release':
        return 'release'
    if lower.startswith('packages.') or lower == 'packages':
        return 'packages_index'
    if lower.startswith('sources.') or lower == 'sources':
        return 'sources_index'
    if 'translation' in lower:
        return 'translation'
    if lower.startswith('commands-') or '/cnf/' in full or lower.endswith('.cnffile'):
        return 'cnf'
    if lower.startswith('contents-') or lower.startswith('contents.'):
        return 'contents'
    if 'dep11' in full or lower.startswith('components-') or lower.endswith('.yml.gz'):
        return 'dep11'
    if 'meta-release' in lower:
        return 'meta_release'
    if 'dist-upgrader' in full or 'ubuntu-release-upgrader' in full or 'releaseannouncement' in lower:
        return 'release_upgrader'
    if lower.endswith('.tar.gz') and ('upgrader' in full or 'upgrade' in full):
        return 'release_upgrader'
    if lower.endswith('.gpg') and ('upgrader' in full or 'upgrade' in full):
        return 'release_upgrader'
    if 'distupgrade' in full.replace('-', '') or '/dist-upgrade/' in full or full.endswith('/dist-upgrade'):
        return 'dist_upgrade'
    if lower.endswith('.gpg') or lower.endswith('.asc') or 'keyring' in lower:
        return 'gpg_key'
    return 'other'

def parse_suite_component(url: str) -> Tuple[str, str]:
    """Best-effort suite/codename and component from Ubuntu archive URL.

    Keeps the full suite token (e.g. bionic-updates), never strips the pocket.
    Pool URLs have no suite — callers must resolve provenance elsewhere.
    """
    parts = urllib.parse.urlparse(url).path.strip('/').split('/')
    suite = ''
    component = ''
    try:
        if 'dists' in parts:
            i = parts.index('dists')
            if i + 1 < len(parts):
                suite = parts[i + 1]
            if i + 2 < len(parts):
                component = parts[i + 2]
        elif 'pool' in parts:
            i = parts.index('pool')
            if i + 1 < len(parts):
                component = parts[i + 1]
    except ValueError:
        pass
    return (suite, component)

def host_of(url: str) -> str:
    return urllib.parse.urlparse(url).netloc

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def parse_access_log(text: str) -> List[Dict[str, Any]]:
    """Parse proxy/access log lines into request records."""
    records = []
    redirects = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split()
        if len(parts) >= 2 and parts[1] == 'TRACE':
            continue
        if is_recorder_selftest_url(line):
            continue
        m = REDIRECT_RE.match(line)
        if m:
            if is_recorder_selftest_url(m.group('original')):
                continue
            redirects[m.group('original')] = m.group('final')
            records.append({
                'requested_at': m.group('ts'), 'method': 'GET',
                'original_url': m.group('original'), 'final_url': m.group('final'),
                'http_status': int(m.group('status')), 'size_bytes': '',
                'sha256': '', 'local_path': '', 'redirect_chain': '',
                'content_length': '', 'event': 'redirect',
            })
            continue
        m = SIMPLE_RE.match(line)
        if m:
            original = m.group('url')
            if is_recorder_selftest_url(original):
                continue
            extras = parse_log_extras(m.group('extra') or '')
            final = extras['final'] or redirects.get(original, original)
            size = m.group('size')
            records.append({
                'requested_at': m.group('ts'), 'method': m.group('method'),
                'original_url': original, 'final_url': final,
                'http_status': int(m.group('status')),
                'size_bytes': '' if size in (None, '-') else size,
                'sha256': extras['sha256'] or '',
                'local_path': extras['local_path'] or '',
                'redirect_chain': extras['redirects'] or '',
                'content_length': extras['content_length'] or '',
                'event': 'request',
            })
            continue
        urls = re.findall('https?://\\S+', line)
        if urls:
            original = urls[0].rstrip(',;')
            if is_recorder_selftest_url(original):
                continue
            status_m = re.search('\\b([1-5]\\d{2})\\b', line)
            method_m = re.search('\\b(GET|HEAD|POST)\\b', line)
            size_m = re.search('\\b(?:size=)?(\\d+)\\b', line)
            final = urls[1].rstrip(',;') if len(urls) > 1 else redirects.get(original, original)
            records.append({
                'requested_at': line.split()[0],
                'method': method_m.group(1) if method_m else 'GET',
                'original_url': original, 'final_url': final,
                'http_status': int(status_m.group(1)) if status_m else 0,
                'size_bytes': size_m.group(1) if size_m else '',
                'sha256': '', 'local_path': '', 'redirect_chain': '',
                'content_length': '', 'event': 'request',
            })
    return records

def aggregate_urls(records: Iterable[Dict[str, Any]], hop: str) -> List[Dict[str, Any]]:
    agg = OrderedDict()
    for r in records:
        if is_recorder_selftest_url(r.get('original_url') or '') or is_recorder_selftest_url(r.get('final_url') or ''):
            continue
        key = r['original_url']
        cur = agg.get(key)
        if not cur:
            agg[key] = {
                'hop': hop, 'requested_at': r.get('requested_at', ''),
                'method': r.get('method', 'GET'),
                'original_url': r['original_url'],
                'final_url': r.get('final_url') or r['original_url'],
                'http_status': r.get('http_status', 0),
                'size_bytes': r.get('size_bytes', ''),
                'sha256': r.get('sha256', ''),
                'local_path': r.get('local_path', ''),
                'redirect_chain': r.get('redirect_chain', ''),
                'content_length': r.get('content_length', ''),
                'first_requested_at': r.get('requested_at', ''),
                'last_requested_at': r.get('requested_at', ''),
                'request_count': 1 if r.get('event') != 'redirect' else 0,
                'file_type': classify_url(r.get('final_url') or r['original_url']),
                'repository_host': host_of(r.get('final_url') or r['original_url']),
            }
        else:
            if r.get('event') != 'redirect':
                cur['request_count'] += 1
            cur['last_requested_at'] = r.get('requested_at', cur['last_requested_at'])
            if r.get('final_url'):
                cur['final_url'] = r['final_url']
            if r.get('http_status'):
                cur['http_status'] = r['http_status']
            if r.get('size_bytes'):
                cur['size_bytes'] = r['size_bytes']
            if r.get('sha256'):
                cur['sha256'] = r['sha256']
            if r.get('local_path'):
                cur['local_path'] = r['local_path']
            if r.get('redirect_chain'):
                cur['redirect_chain'] = r['redirect_chain']
            if r.get('content_length'):
                cur['content_length'] = r['content_length']
            cur['file_type'] = classify_url(cur.get('final_url') or cur['original_url'])
    # Drop pure-redirect aggregation rows with zero request completions
    return [row for row in agg.values() if int(row.get('request_count') or 0) > 0 or int(row.get('http_status') or 0) in (301, 302, 303, 307, 308, 200, 304)]

def parse_packages_index(text: str) -> List[Dict[str, str]]:
    pkgs = []
    cur = {}
    last_key = ''
    for line in text.splitlines():
        if not line.strip():
            if cur.get('Package'):
                pkgs.append(cur)
            cur = {}
            last_key = ''
            continue
        if line.startswith(' ') and last_key:
            cur[last_key] = cur.get(last_key, '') + '\n' + line[1:]
            continue
        if ':' not in line:
            continue
        key, val = line.split(':', 1)
        key = key.strip()
        val = val.strip()
        cur[key] = val
        last_key = key
    if cur.get('Package'):
        pkgs.append(cur)
    return pkgs

def parse_installed_packages_tsv(path: Path) -> Dict[Tuple[str, str], Dict[str, str]]:
    """Keyed by (package, architecture)."""
    out = {}
    if not path.exists():
        return out
    with open_text(path) as f:
        header = f.readline().rstrip('\n').split('\t')
        for line in f:
            cols = line.rstrip('\n').split('\t')
            if len(cols) < 3:
                continue
            row = {header[i] if i < len(header) else 'c{}'.format(i): cols[i] for i in range(len(cols))}
            pkg = row.get('package') or row.get('Package') or cols[0]
            ver = row.get('version') or row.get('Version') or cols[1]
            arch = row.get('architecture') or row.get('Architecture') or cols[2]
            status = row.get('status') or row.get('Status') or (cols[3] if len(cols) > 3 else '')
            out[pkg, arch] = {'package': pkg, 'version': ver, 'architecture': arch, 'status': status}
    return out

def dpkg_version_cmp(a: str, b: str) -> int:
    """Approximate Debian version comparison using python apt_pkg if available, else string."""
    try:
        import apt_pkg
        apt_pkg.init_system()
        return apt_pkg.version_compare(a, b)
    except Exception:
        if a == b:
            return 0
        return -1 if a < b else 1

def diff_packages(before: Path, after: Path) -> Dict[str, List[Dict[str, str]]]:
    b = parse_installed_packages_tsv(before)
    a = parse_installed_packages_tsv(after)
    added, upgraded, downgraded, removed, unchanged = ([], [], [], [], [])
    keys = set(b) | set(a)
    for key in sorted(keys):
        pkg, arch = key
        if key not in b:
            added.append({'package': pkg, 'architecture': arch, 'version_before': '', 'version_after': a[key]['version'], 'change_type': 'added'})
        elif key not in a:
            removed.append({'package': pkg, 'architecture': arch, 'version_before': b[key]['version'], 'version_after': '', 'change_type': 'removed'})
        else:
            bv, av = (b[key]['version'], a[key]['version'])
            if bv == av:
                unchanged.append({'package': pkg, 'architecture': arch, 'version_before': bv, 'version_after': av, 'change_type': 'unchanged'})
            else:
                cmpv = dpkg_version_cmp(bv, av)
                row = {'package': pkg, 'architecture': arch, 'version_before': bv, 'version_after': av, 'change_type': 'upgraded' if cmpv < 0 else 'downgraded'}
                if cmpv < 0:
                    upgraded.append(row)
                else:
                    downgraded.append(row)
    return {'added': added, 'upgraded': upgraded, 'downgraded': downgraded, 'removed': removed, 'unchanged': unchanged}

def parse_file_manifest(path: Path) -> Dict[str, Dict[str, str]]:
    """Parse file-manifest.tsv / conffiles.tsv keyed by path (col0).

    Uses UTF-8 + surrogateescape so non-ASCII paths survive under LC_ALL=C.
    """
    out = {}
    if not path.exists():
        return out
    with open_text(path) as f:
        header = f.readline().rstrip('\n').split('\t')
        for line in f:
            cols = line.rstrip('\n').split('\t')
            if not cols or not cols[0]:
                continue
            row = {header[i] if i < len(header) else 'c{}'.format(i): cols[i] for i in range(len(cols))}
            out[cols[0]] = row
    return out

def diff_files(before: Path, after: Path) -> Dict[str, List[Dict[str, str]]]:
    b = parse_file_manifest(before)
    a = parse_file_manifest(after)
    added, modified, removed = ([], [], [])
    # sorted() preserves surrogateescape path strings as-is.
    for p in sorted(set(b) | set(a)):
        if p not in b:
            row = dict(a[p])
            row['change_type'] = 'added'
            # Ensure path key present for writers that look up 'path'.
            row.setdefault('path', p)
            added.append(row)
        elif p not in a:
            row = dict(b[p])
            row['change_type'] = 'removed'
            row.setdefault('path', p)
            removed.append(row)
        else:
            fields = ('size', 'size_bytes', 'mtime', 'mtime_epoch', 'sha256', 'mode')
            changed = False
            for fld in fields:
                if b[p].get(fld, '') != a[p].get(fld, '') and (b[p].get(fld) or a[p].get(fld)):
                    if fld in b[p] or fld in a[p]:
                        changed = True
                        break
            if changed or b[p] != a[p]:
                row = dict(a[p])
                row['change_type'] = 'modified'
                row.setdefault('path', p)
                row['sha256_before'] = b[p].get('sha256', '')
                row['sha256_after'] = a[p].get('sha256', '')
                modified.append(row)
    return {'added': added, 'modified': modified, 'removed': removed}

def write_tsv(path: Path, header: List[str], rows: Iterable[Dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open_text(path, 'w') as f:
        f.write('\t'.join(header) + '\n')
        for row in rows:
            f.write('\t'.join((str(row.get(h, '')) for h in header)) + '\n')

def read_tsv(path: Path) -> Tuple[List[str], List[Dict[str, str]]]:
    if not path.exists():
        return ([], [])
    with open_text(path) as f:
        header = f.readline().rstrip('\n').split('\t')
        rows = []
        for line in f:
            cols = line.rstrip('\n').split('\t')
            rows.append({header[i] if i < len(header) else 'c{}'.format(i): cols[i] if i < len(cols) else '' for i in range(len(header))})
        return (header, rows)

def deb_fields_from_filename(name: str) -> Dict[str, str]:
    m = DEB_NAME_RE.match(name)
    if not m:
        return {'package': '', 'version': '', 'architecture': '', 'filename': name}
    return {'package': m.group('package'), 'version': m.group('version'), 'architecture': m.group('arch'), 'filename': name, 'ext': m.group('ext')}

def extract_deb_control(path: Path) -> Dict[str, str]:
    """Extract control fields via dpkg-deb when available."""
    import subprocess
    fields = ['Package', 'Version', 'Architecture', 'Source', 'Depends', 'Pre-Depends', 'Recommends', 'Provides', 'Conflicts', 'Replaces']
    out = {}
    for fld in fields:
        try:
            proc = subprocess.run(['dpkg-deb', '-f', str(path), fld], check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True)
            out[fld.lower().replace('-', '_')] = proc.stdout.strip()
        except Exception:
            out[fld.lower().replace('-', '_')] = ''
    if out.get('package') and (not out.get('source')):
        out['source'] = out['package']
    out['source_package'] = out.get('source', '')
    return out

def _resolve_captured_path(hop_dir, original_url, final_url, local_path, sha):
    """Locate a durable recorder body for a URL (log path, hash object, or legacy basename)."""
    candidates = []
    if local_path:
        candidates.append(local_path)
    deb_cache = hop_dir / 'runtime' / 'deb-cache'
    for url in (original_url, final_url):
        if not url:
            continue
        obj, _meta, _key = object_paths_for_url(deb_cache, url)
        candidates.append(str(obj))
        # legacy basename layout
        base = os.path.basename(urllib.parse.urlparse(url).path)
        if base:
            candidates.append(str(deb_cache / base))
    for cand in candidates:
        exists, sha_ok, actual = local_body_ok(cand, sha)
        if exists and (sha_ok or not sha):
            return (cand, actual or sha, '' if sha_ok or not sha else 'sha256_mismatch')
        if exists and sha and not sha_ok:
            return (cand, actual, 'sha256_mismatch')
    return ('', '', 'missing')


def _index_debs_from_cache(deb_cache, index_map, hop):
    """Index .deb bodies from legacy basenames and URL-hash objects with .meta.json."""
    deb_rows = []
    deb_by_pva = {}
    seen_paths = set()

    def add_deb(path_obj, filename_hint=''):
        path_s = str(path_obj)
        if path_s in seen_paths or not path_obj.is_file():
            return
        seen_paths.add(path_s)
        name = filename_hint or path_obj.name
        meta = extract_deb_control(path_obj)
        fn_meta = deb_fields_from_filename(name)
        package = meta.get('package') or fn_meta.get('package') or ''
        version = meta.get('version') or fn_meta.get('version') or ''
        arch = meta.get('architecture') or fn_meta.get('architecture') or ''
        if not (package and version and arch):
            return
        sha = sha256_file(path_obj)
        size = path_obj.stat().st_size
        idx = index_map.get((package, version, arch), {})
        row = {
            'hop': hop, 'package': package, 'version': version, 'architecture': arch,
            'source_package': meta.get('source_package') or package,
            'filename': name if (name.endswith('.deb') or name.endswith('.udeb')) else (
                '{}_{}_{}.deb'.format(package, version, arch)),
            'local_path': path_s, 'size_bytes': str(size), 'sha256': sha,
            'Depends': idx.get('Depends', meta.get('depends', '')),
            'Pre-Depends': idx.get('Pre-Depends', meta.get('pre_depends', '')),
            'Recommends': idx.get('Recommends', meta.get('recommends', '')),
            'Provides': idx.get('Provides', meta.get('provides', '')),
            'Conflicts': idx.get('Conflicts', meta.get('conflicts', '')),
            'Replaces': idx.get('Replaces', meta.get('replaces', '')),
            'Filename': idx.get('Filename', ''),
        }
        deb_rows.append(row)
        deb_by_pva[package, version, arch] = row

    if not deb_cache.exists():
        return (deb_rows, deb_by_pva)
    for path in sorted(deb_cache.rglob('*')):
        if not path.is_file():
            continue
        if path.name.endswith('.meta.json'):
            meta = load_capture_meta(path)
            body = Path(meta.get('local_path') or str(path)[:-len('.meta.json')])
            url = meta.get('final_url') or meta.get('original_url') or ''
            ftype = classify_url(url) if url else ''
            if ftype in ('deb', 'udeb') or body.name.endswith('.deb') or body.name.endswith('.udeb'):
                hint = os.path.basename(urllib.parse.urlparse(url).path) if url else body.name
                add_deb(body, hint)
            continue
        if path.name.endswith('.deb') or path.name.endswith('.udeb'):
            add_deb(path, path.name)
    return (deb_rows, deb_by_pva)


def build_required_manifests(hop_dir: Path, hop: str) -> Dict[str, Any]:
    runtime = hop_dir / 'runtime'
    packages_dir = hop_dir / 'packages'
    metadata_dir = hop_dir / 'metadata'
    before = hop_dir / 'before'
    after = hop_dir / 'after'
    diff_dir = hop_dir / 'diff'
    deb_cache = hop_dir / 'runtime' / 'deb-cache'
    access_log = runtime / 'proxy-access.log'
    repair_log = runtime / 'repair-access.log'
    # Only treat proxy/access evidence as collected when recording actually started.
    recording_started = runtime / 'recording-started-at.txt'
    records = []
    if recording_started.exists() and access_log.exists():
        records.extend(parse_access_log(read_text(access_log)))
    if repair_log.exists():
        records.extend(parse_access_log(read_text(repair_log)))
    url_rows = aggregate_urls(records, hop)
    req_urls_path = runtime / 'requested-urls.tsv'
    # Rebuild requested-urls from recording-window evidence only (do not merge
    # stale pre-recording rows back into the manifest).
    write_tsv(req_urls_path, ['hop', 'requested_at', 'method', 'original_url', 'final_url', 'http_status', 'size_bytes', 'sha256', 'local_path', 'request_count', 'file_type', 'repository_host', 'first_requested_at', 'last_requested_at'], url_rows)
    index_map = {}
    for idx in metadata_dir.glob('**/Packages*'):
        if idx.is_file() and (not str(idx).endswith('.tsv')):
            try:
                if idx.suffix == '.gz':
                    import gzip
                    text = gzip.open(
                        str(idx), 'rt', encoding='utf-8', errors='surrogateescape'
                    ).read()
                elif idx.suffix == '.xz':
                    import lzma
                    text = lzma.open(
                        str(idx), 'rt', encoding='utf-8', errors='surrogateescape'
                    ).read()
                else:
                    text = read_text(idx)
            except Exception:
                continue
            for p in parse_packages_index(text):
                key = (p.get('Package', ''), p.get('Version', ''), p.get('Architecture', ''))
                index_map[key] = p
    pkg_diff = diff_packages(before / 'installed-packages.tsv', after / 'installed-packages.tsv')
    for name, rows in pkg_diff.items():
        write_tsv(diff_dir / 'packages-{}.tsv'.format(name), ['package', 'architecture', 'version_before', 'version_after', 'change_type'], rows)
    file_diff = diff_files(before / 'file-manifest.tsv', after / 'file-manifest.tsv')
    for name, rows in file_diff.items():
        header = ['path', 'change_type', 'file_origin', 'size', 'sha256', 'sha256_before', 'sha256_after']
        norm = []
        for r in rows:
            norm.append({'path': r.get('path') or r.get('relative_path') or '', 'change_type': r.get('change_type', ''), 'file_origin': r.get('file_origin', 'unknown'), 'size': r.get('size') or r.get('size_bytes') or '', 'sha256': r.get('sha256', ''), 'sha256_before': r.get('sha256_before', ''), 'sha256_after': r.get('sha256_after', '')})
        write_tsv(diff_dir / 'files-{}.tsv'.format(name), header, norm)
    conf_b = parse_file_manifest(before / 'conffiles.tsv')
    conf_a = parse_file_manifest(after / 'conffiles.tsv')
    conf_mod = []
    for p in sorted(set(conf_b) | set(conf_a)):
        if p in conf_b and p in conf_a and (conf_b[p] != conf_a[p]):
            conf_mod.append({'path': p, 'hash_before': conf_b[p].get('hash') or conf_b[p].get('sha256') or '', 'hash_after': conf_a[p].get('hash') or conf_a[p].get('sha256') or ''})
    write_tsv(diff_dir / 'conffiles-modified.tsv', ['path', 'hash_before', 'hash_after'], conf_mod)
    write_tsv(diff_dir / 'apt-sources-before-after.tsv', ['side', 'path', 'sha256'], _list_apt_sources(before / 'apt-sources', 'before') + _list_apt_sources(after / 'apt-sources', 'after'))
    installed_after = parse_installed_packages_tsv(after / 'installed-packages.tsv')
    upgraded_keys = {(r['package'], r['architecture']) for r in pkg_diff['upgraded']}
    removed_keys = {(r['package'], r['architecture']) for r in pkg_diff['removed']}
    deb_rows, deb_by_pva = _index_debs_from_cache(deb_cache, index_map, hop)
    # Prefer URL-log local_path bodies when present (durable recorder capture).
    for u in url_rows:
        ftype = u.get('file_type') or classify_url(u.get('final_url') or u['original_url'])
        if ftype not in ('deb', 'udeb'):
            continue
        lp = u.get('local_path') or ''
        if lp and Path(lp).is_file():
            filename = os.path.basename(urllib.parse.urlparse(u.get('final_url') or u['original_url']).path)
            meta = extract_deb_control(Path(lp))
            fn_meta = deb_fields_from_filename(filename)
            package = meta.get('package') or fn_meta.get('package') or ''
            version = meta.get('version') or fn_meta.get('version') or ''
            arch = meta.get('architecture') or fn_meta.get('architecture') or ''
            if package and version and arch and (package, version, arch) not in deb_by_pva:
                sha = u.get('sha256') or sha256_file(Path(lp))
                size = str(Path(lp).stat().st_size)
                idx = index_map.get((package, version, arch), {})
                row = {
                    'hop': hop, 'package': package, 'version': version, 'architecture': arch,
                    'source_package': meta.get('source_package') or package,
                    'filename': filename, 'local_path': lp, 'size_bytes': size, 'sha256': sha,
                    'Depends': idx.get('Depends', meta.get('depends', '')),
                    'Pre-Depends': idx.get('Pre-Depends', meta.get('pre_depends', '')),
                    'Recommends': idx.get('Recommends', meta.get('recommends', '')),
                    'Provides': idx.get('Provides', meta.get('provides', '')),
                    'Conflicts': idx.get('Conflicts', meta.get('conflicts', '')),
                    'Replaces': idx.get('Replaces', meta.get('replaces', '')),
                    'Filename': idx.get('Filename', ''),
                }
                deb_rows.append(row)
                deb_by_pva[package, version, arch] = row
    write_tsv(packages_dir / 'deb-files.tsv', ['hop', 'package', 'version', 'architecture', 'source_package', 'filename', 'local_path', 'size_bytes', 'sha256', 'Filename', 'Depends', 'Pre-Depends', 'Recommends', 'Provides', 'Conflicts', 'Replaces'], deb_rows)
    required_urls = []
    required_files_map = OrderedDict()  # (ftype, final_url) -> row
    required_packages = []
    unresolved_packages = []
    unresolved_files = []
    failed_requests = []
    seen_pkg = set()
    captured_http_200 = 0
    captured_bytes = 0
    for u in url_rows:
        if is_recorder_selftest_url(u.get('original_url') or '') or is_recorder_selftest_url(u.get('final_url') or ''):
            continue
        ftype = u.get('file_type') or classify_url(u.get('final_url') or u['original_url'])
        final_url = u.get('final_url') or u['original_url']
        original_url = u['original_url']
        filename = os.path.basename(urllib.parse.urlparse(final_url).path)
        status = int(u.get('http_status') or 0)
        local_path = u.get('local_path') or ''
        sha = u.get('sha256') or ''
        resolved_path, resolved_sha, resolve_err = _resolve_captured_path(
            hop_dir, original_url, final_url, local_path, sha)
        if resolved_path:
            local_path = resolved_path
            if resolved_sha:
                sha = resolved_sha
        if status == 200 and local_path and Path(local_path).is_file():
            captured_http_200 += 1
            try:
                captured_bytes += Path(local_path).stat().st_size
            except Exception:
                pass
        required_urls.append({
            'hop': hop,
            'requested_at': u.get('first_requested_at') or u.get('requested_at', ''),
            'method': u.get('method', 'GET'),
            'original_url': original_url,
            'final_url': final_url,
            'http_status': status,
            'size_bytes': u.get('size_bytes', ''),
            'sha256': sha,
            'local_path': local_path,
        })
        if status and status >= 400:
            failed_requests.append({
                'hop': hop, 'original_url': original_url, 'final_url': final_url,
                'http_status': status, 'reason': 'HTTP {}'.format(status), 'file_type': ftype,
            })
        # 304 is success only when a previously preserved body exists.
        needs_body = status in (200, 304) or (status == 0 and ftype in ('deb', 'udeb'))
        body_missing = needs_body and (not local_path or not Path(local_path).is_file())
        body_bad_sha = bool(resolve_err == 'sha256_mismatch')
        if ftype in ('deb', 'udeb'):
            fn_meta = deb_fields_from_filename(filename)
            package = fn_meta.get('package') or ''
            version = fn_meta.get('version') or ''
            arch = fn_meta.get('architecture') or ''
            suite, component = parse_suite_component(final_url)
            deb_row = deb_by_pva.get((package, version, arch))
            if deb_row and (not local_path or not Path(local_path).is_file()):
                local_path = deb_row['local_path']
                sha = deb_row['sha256']
                body_missing = not Path(local_path).is_file()
            if deb_row:
                size_bytes = deb_row['size_bytes']
                source_package = deb_row.get('source_package', package)
                if not sha:
                    sha = deb_row['sha256']
            else:
                size_bytes = u.get('size_bytes', '')
                source_package = package
            downloaded = 'true' if local_path and Path(local_path).is_file() else 'false'
            if status == 304 and body_missing:
                unresolved_packages.append({
                    'hop': hop, 'package': package, 'version': version, 'architecture': arch,
                    'original_url': original_url, 'final_url': final_url,
                    'reason': 'http_304_without_stored_body',
                })
            elif status == 200 and body_missing:
                unresolved_packages.append({
                    'hop': hop, 'package': package, 'version': version, 'architecture': arch,
                    'original_url': original_url, 'final_url': final_url,
                    'reason': 'http200_missing_local_path' if not u.get('local_path') else 'file removed before capture',
                })
            elif body_bad_sha:
                unresolved_packages.append({
                    'hop': hop, 'package': package, 'version': version, 'architecture': arch,
                    'original_url': original_url, 'final_url': final_url,
                    'reason': 'sha256_mismatch',
                })
            elif status == 0 and body_missing and package:
                unresolved_packages.append({
                    'hop': hop, 'package': package, 'version': version, 'architecture': arch,
                    'original_url': original_url, 'final_url': final_url,
                    'reason': 'cache miss',
                })
            key = (package, version, arch)
            installed = 'true' if (package, arch) in installed_after else 'false'
            upgraded = 'true' if (package, arch) in upgraded_keys else 'false'
            removed = 'true' if (package, arch) in removed_keys else 'false'
            transitional = 'true' if 'transitional' in (package or '').lower() else 'false'
            third_party = 'false'
            host = host_of(final_url)
            if host and 'ubuntu.com' not in host and ('canonical.com' not in host) and ('launchpad.net' not in host):
                third_party = 'true'
            if key not in seen_pkg and package:
                seen_pkg.add(key)
                required_packages.append({
                    'hop': hop, 'package': package, 'version': version, 'architecture': arch,
                    'source_package': source_package, 'filename': filename,
                    'repository_host': host, 'suite': suite, 'component': component,
                    'size_bytes': size_bytes, 'sha256': sha,
                    'original_url': original_url, 'final_url': final_url,
                    'requested': 'true', 'downloaded': downloaded, 'installed': installed,
                    'evidence_source': 'proxy_access_log', 'upgraded': upgraded,
                    'removed': removed, 'transitional': transitional, 'third_party': third_party,
                    'first_requested_at': u.get('first_requested_at', ''),
                    'last_requested_at': u.get('last_requested_at', ''),
                    'request_count': u.get('request_count', 1), 'local_path': local_path,
                })
        else:
            fkey = (ftype, final_url)
            row = {
                'hop': hop, 'file_type': ftype, 'filename': filename,
                'original_url': original_url, 'final_url': final_url,
                'local_path': local_path, 'size_bytes': u.get('size_bytes', ''),
                'sha256': sha, 'http_status': status,
                'request_count': u.get('request_count', 1),
                'evidence_source': 'proxy_access_log',
                '_body_missing': body_missing,
                '_body_bad_sha': body_bad_sha,
                '_orig_local': u.get('local_path') or '',
            }
            prev = required_files_map.get(fkey)
            if not prev:
                required_files_map[fkey] = row
            else:
                prev_st = int(prev.get('http_status') or 0)
                prev_has = bool(prev.get('local_path') and Path(prev['local_path']).is_file())
                cur_has = bool(local_path and Path(local_path).is_file())
                # Prefer a captured body / HTTP 200 over redirects or empty rows.
                if (cur_has and not prev_has) or (status == 200 and prev_st != 200) or (
                        status == 200 and cur_has):
                    row['request_count'] = int(prev.get('request_count') or 0) + int(u.get('request_count') or 1)
                    required_files_map[fkey] = row
                else:
                    prev['request_count'] = int(prev.get('request_count') or 0) + int(u.get('request_count') or 1)
    # Materialize non-deb required files + unresolved reasons from best rows
    required_files = []
    for fkey, row in required_files_map.items():
        status = int(row.get('http_status') or 0)
        local_path = row.get('local_path') or ''
        body_missing = bool(row.get('_body_missing'))
        if local_path and Path(local_path).is_file():
            body_missing = False
        body_bad_sha = bool(row.get('_body_bad_sha'))
        reason = ''
        if status == 304 and body_missing:
            reason = 'http_304_without_stored_body'
        elif status == 200 and body_missing:
            reason = 'http200_missing_local_path' if not row.get('_orig_local') else 'file removed before capture'
        elif status == 200 and not local_path:
            reason = 'cache miss'
        elif body_bad_sha:
            reason = 'sha256_mismatch'
        if reason:
            unresolved_files.append({
                'hop': hop, 'file_type': row['file_type'], 'filename': row['filename'],
                'original_url': row['original_url'], 'final_url': row['final_url'], 'reason': reason,
            })
        clean = {k: v for k, v in row.items() if not k.startswith('_')}
        required_files.append(clean)
    for key, deb_row in deb_by_pva.items():
        if key in seen_pkg:
            continue
        package, version, arch = key
        seen_pkg.add(key)
        installed = 'true' if (package, arch) in installed_after else 'false'
        required_packages.append({
            'hop': hop, 'package': package, 'version': version, 'architecture': arch,
            'source_package': deb_row.get('source_package', package),
            'filename': deb_row['filename'], 'repository_host': '', 'suite': '', 'component': '',
            'size_bytes': deb_row['size_bytes'], 'sha256': deb_row['sha256'],
            'original_url': '', 'final_url': '', 'requested': 'false', 'downloaded': 'true',
            'installed': installed, 'evidence_source': 'apt_archives',
            'upgraded': 'true' if (package, arch) in upgraded_keys else 'false',
            'removed': 'false', 'transitional': 'false', 'third_party': 'false',
            'first_requested_at': '', 'last_requested_at': '', 'request_count': 0,
            'local_path': deb_row['local_path'],
        })
        required_files.append({
            'hop': hop, 'file_type': 'deb', 'filename': deb_row['filename'],
            'original_url': '', 'final_url': '', 'local_path': deb_row['local_path'],
            'size_bytes': deb_row['size_bytes'], 'sha256': deb_row['sha256'],
            'http_status': '', 'request_count': 0, 'evidence_source': 'apt_archives',
        })
    seen_file = set(required_files_map.keys())
    for rp in required_packages:
        if rp.get('requested') != 'true':
            continue
        lp = rp.get('local_path') or ''
        has_body = bool(lp) and Path(lp).is_file()
        # Failed/missing downloads stay in required-packages + failed-requests /
        # required-urls; do not create orphan required-files rows (breaks
        # required == resolved + unresolved identity).
        if not has_body and rp.get('downloaded') != 'true':
            continue
        fkey = ('deb', rp.get('final_url') or rp.get('filename'))
        if fkey in seen_file:
            continue
        seen_file.add(fkey)
        required_files.append({
            'hop': hop,
            'file_type': 'deb' if not str(rp.get('filename', '')).endswith('.udeb') else 'udeb',
            'filename': rp.get('filename', ''),
            'original_url': rp.get('original_url', ''),
            'final_url': rp.get('final_url', ''),
            'local_path': lp,
            'size_bytes': rp.get('size_bytes', ''),
            'sha256': rp.get('sha256', ''),
            'http_status': '',
            'request_count': rp.get('request_count', 1),
            'evidence_source': rp.get('evidence_source', ''),
        })
    # Deduplicate unresolved rows
    up_seen = set()
    up_out = []
    for r in unresolved_packages:
        k = (r.get('package'), r.get('version'), r.get('architecture'), r.get('final_url'))
        if k in up_seen:
            continue
        up_seen.add(k)
        up_out.append(r)
    unresolved_packages = up_out
    uf_seen = set()
    uf_out = []
    for r in unresolved_files:
        k = (r.get('file_type'), r.get('final_url') or r.get('original_url'))
        if k in uf_seen:
            continue
        uf_seen.add(k)
        uf_out.append(r)
    unresolved_files = uf_out
    # Drop stale by-hash 404s from final required manifests (keep failed-requests).
    stale_urls, hist_reasons, _hist_rows = identify_historical_non_required_failures(
        failed_requests, unresolved_packages, unresolved_files, required_files)
    if stale_urls:
        required_files = [
            r for r in required_files
            if not (_row_url_set(r) & stale_urls)
        ]
        required_urls = [
            r for r in required_urls
            if not ((_row_url_set(r) & stale_urls) and _http_status_int(r) >= 400)
        ]
    hist_total = sum(int(v) for v in hist_reasons.values()) if hist_reasons else 0
    resolved_packages = sum(
        1 for r in required_packages
        if r.get('local_path') and Path(r['local_path']).is_file()
    )
    resolved_files = sum(
        1 for r in required_files
        if r.get('local_path') and Path(r['local_path']).is_file()
    )
    write_tsv(hop_dir / 'required-urls.tsv', ['hop', 'requested_at', 'method', 'original_url', 'final_url', 'http_status', 'size_bytes', 'sha256', 'local_path'], required_urls)
    write_tsv(hop_dir / 'required-files.tsv', ['hop', 'file_type', 'filename', 'original_url', 'final_url', 'local_path', 'size_bytes', 'sha256', 'http_status', 'request_count', 'evidence_source'], required_files)
    write_tsv(hop_dir / 'required-packages.tsv', ['hop', 'package', 'version', 'architecture', 'source_package', 'filename', 'repository_host', 'suite', 'component', 'size_bytes', 'sha256', 'original_url', 'final_url', 'requested', 'downloaded', 'installed', 'evidence_source'], required_packages)
    write_tsv(packages_dir / 'requested-packages.tsv', ['hop', 'package', 'version', 'architecture', 'filename', 'original_url', 'final_url', 'request_count', 'evidence_source'], [r for r in required_packages if r.get('requested') == 'true'])
    write_tsv(packages_dir / 'downloaded-packages.tsv', ['hop', 'package', 'version', 'architecture', 'filename', 'local_path', 'sha256', 'size_bytes', 'installed', 'evidence_source'], [r for r in required_packages if r.get('downloaded') == 'true'])
    write_tsv(packages_dir / 'package-metadata.tsv', ['hop', 'package', 'version', 'architecture', 'source_package', 'filename', 'local_path', 'original_url', 'final_url', 'repository_host', 'suite', 'component', 'size_bytes', 'sha256', 'first_requested_at', 'last_requested_at', 'request_count', 'downloaded', 'installed', 'upgraded', 'removed', 'transitional', 'third_party', 'evidence_source'], required_packages)
    meta_req = [r for r in required_files if r['file_type'] not in ('deb', 'udeb')]
    write_tsv(metadata_dir / 'requested-metadata.tsv', ['hop', 'file_type', 'filename', 'original_url', 'final_url', 'http_status', 'request_count', 'evidence_source'], meta_req)
    write_tsv(metadata_dir / 'release-upgrader-files.tsv', ['hop', 'file_type', 'filename', 'original_url', 'final_url', 'http_status', 'request_count', 'evidence_source'], [r for r in meta_req if r['file_type'] in ('meta_release', 'release_upgrader', 'dist_upgrade')])
    write_tsv(metadata_dir / 'repository-index-files.tsv', ['hop', 'file_type', 'filename', 'original_url', 'final_url', 'http_status', 'request_count', 'evidence_source'], [r for r in meta_req if r['file_type'] in ('inrelease', 'release', 'release_gpg', 'packages_index', 'sources_index', 'translation', 'contents', 'dep11', 'cnf', 'by_hash')])
    write_tsv(hop_dir / 'unresolved-packages.tsv', ['hop', 'package', 'version', 'architecture', 'original_url', 'final_url', 'reason'], unresolved_packages)
    write_tsv(hop_dir / 'unresolved-files.tsv', ['hop', 'file_type', 'filename', 'original_url', 'final_url', 'reason'], unresolved_files)
    write_tsv(hop_dir / 'failed-requests.tsv', ['hop', 'original_url', 'final_url', 'http_status', 'reason', 'file_type'], failed_requests)
    evidence = {
        'hop': hop,
        'generated_at': utc_now(),
        'required_packages': len(required_packages),
        'resolved_packages': resolved_packages,
        'unresolved_packages': len(unresolved_packages),
        'required_files': len(required_files),
        'resolved_files': resolved_files,
        'unresolved_files': len(unresolved_files),
        'required_urls': len(required_urls),
        'failed_requests': len(failed_requests),
        'historical_non_required_failures': hist_total,
        'historical_non_required_failure_reasons': OrderedDict(hist_reasons),
        'captured_http_200': captured_http_200,
        'captured_bytes': captured_bytes,
        'packages_added': len(pkg_diff['added']),
        'packages_upgraded': len(pkg_diff['upgraded']),
        'packages_removed': len(pkg_diff['removed']),
        'downloaded_not_installed': sum(
            (1 for r in required_packages
             if r.get('downloaded') == 'true' and r.get('installed') != 'true')),
    }
    # Preserve prior recovery markers if present.
    prev_evidence_path = hop_dir / 'evidence.json'
    if prev_evidence_path.exists():
        try:
            prev = json.loads(read_text(prev_evidence_path))
            for k in ('recovered_post_hop', 'checksum_source', 'repair_notes'):
                if k in prev and k not in evidence:
                    evidence[k] = prev[k]
        except Exception:
            pass
    write_text(hop_dir / 'evidence.json', json.dumps(evidence, indent=2) + '\n')
    return evidence

def _list_apt_sources(root: Path, side: str) -> List[Dict[str, str]]:
    rows = []
    if not root.exists():
        return rows
    for p in sorted(root.rglob('*')):
        if p.is_file():
            try:
                sha = sha256_file(p)
            except Exception:
                sha = ''
            rows.append({'side': side, 'path': str(p.relative_to(root)), 'sha256': sha})
    return rows

def _tsv_data_rows(path: Path) -> List[Dict[str, str]]:
    _hdr, rows = read_tsv(path)
    return rows


def validate_hop(hop_dir: Path, hop: str, from_os: str, to_os: str) -> Tuple[bool, List[str]]:
    failures = []

    def need(rel: str) -> Path:
        p = hop_dir / rel
        if not p.exists():
            failures.append('missing:{}'.format(rel))
        return p
    need('before/installed-packages.tsv')
    need('after/installed-packages.tsv')
    need('required-packages.tsv')
    need('required-files.tsv')
    need('required-urls.tsv')
    need('runtime/apt-history.log')
    need('runtime/apt-term.log')
    need('runtime/dpkg.log')
    need('runtime/dist-upgrade')
    need('evidence.json')
    run_json = hop_dir / 'run.json'
    if run_json.exists():
        try:
            meta = json.loads(read_text(run_json))
            if meta.get('hop') and meta['hop'] != hop:
                failures.append('hop_mismatch:run.json hop={} expected={}'.format(meta.get('hop'), hop))
            if meta.get('from_os') and normalize_version(meta['from_os']) != normalize_version(from_os):
                failures.append('from_os_mismatch:{}!={}'.format(meta.get('from_os'), from_os))
            if meta.get('to_os') and normalize_version(meta['to_os']) != normalize_version(to_os):
                failures.append('to_os_mismatch:{}!={}'.format(meta.get('to_os'), to_os))
        except Exception as e:
            failures.append('run.json_parse_failed:{}'.format(e))
    else:
        failures.append('missing:run.json')
    deb_cache = hop_dir / 'runtime' / 'deb-cache'
    if deb_cache.exists():
        for meta_path in deb_cache.rglob('*.meta.json'):
            meta = load_capture_meta(meta_path)
            body = Path(meta.get('local_path') or str(meta_path)[:-len('.meta.json')])
            expected = meta.get('sha256') or ''
            if not body.is_file():
                failures.append('captured_body_missing:{}'.format(meta_path.name))
                continue
            try:
                actual = sha256_file(body)
            except Exception as e:
                failures.append('sha256_failed:{}:{}'.format(body, e))
                continue
            if expected and actual.lower() != expected.lower():
                failures.append('sha256_mismatch:{}'.format(body))
        for deb in deb_cache.rglob('*'):
            if not deb.is_file() or not (deb.name.endswith('.deb') or deb.name.endswith('.udeb')):
                continue
            try:
                sha256_file(deb)
            except Exception as e:
                failures.append('sha256_failed:{}:{}'.format(deb.name, e))
            meta = extract_deb_control(deb)
            if not meta.get('package') or not meta.get('version') or (not meta.get('architecture')):
                fn = deb_fields_from_filename(deb.name)
                if not (fn.get('package') and fn.get('version') and fn.get('architecture')):
                    failures.append('deb_metadata_missing:{}'.format(deb.name))
    _, req_pkgs = read_tsv(hop_dir / 'required-packages.tsv')
    _, req_files = read_tsv(hop_dir / 'required-files.tsv')
    _, req_urls = read_tsv(hop_dir / 'required-urls.tsv')
    unresolved_pkgs = _tsv_data_rows(hop_dir / 'unresolved-packages.tsv')
    unresolved_files = _tsv_data_rows(hop_dir / 'unresolved-files.tsv')
    _, failed_requests = read_tsv(hop_dir / 'failed-requests.tsv')
    seen = set()
    for r in req_pkgs:
        if is_recorder_selftest_url(r.get('original_url') or '') or is_recorder_selftest_url(r.get('final_url') or ''):
            failures.append('selftest_url_in_required_packages:{}'.format(r.get('original_url')))
        key = (r.get('package'), r.get('version'), r.get('architecture'))
        if key in seen:
            failures.append('duplicate_package_key:{}'.format(key))
        seen.add(key)
    _, requested = read_tsv(hop_dir / 'packages' / 'requested-packages.tsv')
    req_set = {(r.get('package'), r.get('version'), r.get('architecture')) for r in req_pkgs}
    for r in requested:
        key = (r.get('package'), r.get('version'), r.get('architecture'))
        if key not in req_set:
            failures.append('requested_package_missing_in_required:{}'.format(key))
    _, meta_req = read_tsv(hop_dir / 'metadata' / 'requested-metadata.tsv')
    file_urls = {(r.get('file_type'), r.get('final_url') or r.get('original_url')) for r in req_files}
    for r in meta_req:
        if is_recorder_selftest_url(r.get('original_url') or '') or is_recorder_selftest_url(r.get('final_url') or ''):
            failures.append('selftest_url_in_required_files:{}'.format(r.get('original_url')))
        key = (r.get('file_type'), r.get('final_url') or r.get('original_url'))
        if key not in file_urls:
            failures.append('requested_metadata_missing_in_required_files:{}'.format(key))
    if unresolved_pkgs:
        failures.append('unresolved_packages:{}'.format(len(unresolved_pkgs)))
    if unresolved_files:
        failures.append('unresolved_files:{}'.format(len(unresolved_files)))
    for r in req_urls:
        if is_recorder_selftest_url(r.get('original_url') or '') or is_recorder_selftest_url(r.get('final_url') or ''):
            failures.append('selftest_url_in_required_urls:{}'.format(r.get('original_url')))
            continue
        try:
            st = int(r.get('http_status') or 0)
        except ValueError:
            st = 0
        lp = r.get('local_path') or ''
        url = r.get('final_url') or r.get('original_url') or ''
        original = r.get('original_url') or url
        ftype = classify_url(url)
        has_local = bool(lp) and Path(lp).is_file()
        if not has_local:
            resolved, _sha, _err = _resolve_captured_path(hop_dir, original, url, lp, r.get('sha256') or '')
            has_local = bool(resolved) and Path(resolved).is_file()
            if has_local:
                lp = resolved
        if st == 200 and ftype in ('deb', 'udeb') and not has_local:
            failures.append('http200_package_missing_local_path:{}'.format(original))
        if st == 200 and not has_local:
            failures.append('http200_missing_stored_file:{}'.format(original))
        if st == 304 and not has_local:
            failures.append('http304_without_stored_body:{}'.format(original))
        if has_local and r.get('sha256'):
            exists, sha_ok, _actual = local_body_ok(lp, r.get('sha256'))
            if exists and not sha_ok:
                failures.append('sha256_mismatch:{}'.format(original))
    # Release upgrader tar.gz / gpg must be present when requested.
    upgrader_needed = [
        r for r in req_files
        if r.get('file_type') == 'release_upgrader'
        and (str(r.get('filename') or '').endswith('.tar.gz')
             or str(r.get('filename') or '').endswith('.tar.gz.gpg')
             or str(r.get('filename') or '').endswith('.gpg'))
    ]
    for r in upgrader_needed:
        lp = r.get('local_path') or ''
        if not lp or not Path(lp).is_file():
            failures.append('release_upgrader_missing:{}'.format(
                r.get('final_url') or r.get('original_url') or r.get('filename')))
    for label, rows in (('required-packages', req_pkgs), ('required-files', req_files), ('required-urls', req_urls)):
        for r in rows:
            if r.get('hop') and r['hop'] != hop:
                failures.append('cross_hop_contamination:{}:{}'.format(label, r.get('hop')))
    # Metrics from evidence.json when available, else recompute.
    metrics = {
        'required_packages': len(req_pkgs),
        'resolved_packages': sum(1 for r in req_pkgs if r.get('local_path') and Path(r['local_path']).is_file()),
        'unresolved_packages': len(unresolved_pkgs),
        'required_files': len(req_files),
        'resolved_files': sum(1 for r in req_files if r.get('local_path') and Path(r['local_path']).is_file()),
        'unresolved_files': len(unresolved_files),
        'failed_requests': len(failed_requests),
        'captured_http_200': 0,
        'captured_bytes': 0,
    }
    evidence_path = hop_dir / 'evidence.json'
    if evidence_path.exists():
        try:
            ev = json.loads(read_text(evidence_path))
            for k in metrics:
                if k in ev:
                    metrics[k] = ev[k]
        except Exception:
            pass
    # Strict identity: every required file is resolved or unresolved (not neither).
    try:
        req_f = int(metrics['required_files'])
        res_f = int(metrics['resolved_files'])
        unres_f = int(metrics['unresolved_files'])
        if req_f != res_f + unres_f:
            failures.append(
                'required_files_count_mismatch:required={} resolved={} unresolved={}'.format(
                    req_f, res_f, unres_f))
    except (TypeError, ValueError):
        failures.append('required_files_count_unparseable')
    # Deduplicate failure strings while preserving order
    dedup = []
    seen_f = set()
    for f in failures:
        if f in seen_f:
            continue
        seen_f.add(f)
        dedup.append(f)
    failures = dedup
    ok = not failures
    lines = [
        'VALIDATION: PASS' if ok else 'VALIDATION: FAIL',
        'hop={}'.format(hop),
        'from_os={}'.format(from_os),
        'to_os={}'.format(to_os),
        'required_packages={}'.format(metrics['required_packages']),
        'resolved_packages={}'.format(metrics['resolved_packages']),
        'unresolved_packages={}'.format(metrics['unresolved_packages']),
        'required_files={}'.format(metrics['required_files']),
        'resolved_files={}'.format(metrics['resolved_files']),
        'unresolved_files={}'.format(metrics['unresolved_files']),
        'failed_requests={}'.format(metrics['failed_requests']),
        'captured_http_200={}'.format(metrics['captured_http_200']),
        'captured_bytes={}'.format(metrics['captured_bytes']),
    ]
    if failures:
        lines.append('failures:')
        lines.extend(('  - {}'.format(f) for f in failures))
    else:
        lines.append('failures: none')
    write_text(hop_dir / 'validation.txt', '\n'.join(lines) + '\n')
    return (ok, failures)

def _new_repair_nonce():
    """Return a cache-busting nonce (UTC timestamp + random hex)."""
    import binascii
    ts = datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')
    rnd = binascii.hexlify(os.urandom(4)).decode('ascii')
    return '{}_{}'.format(ts, rnd)


def _append_query_param(url, name, value):
    """Append or replace a query parameter on url."""
    parts = urllib.parse.urlsplit(url)
    pairs = [
        (k, v) for k, v in urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
        if k != name
    ]
    pairs.append((name, value))
    new_query = urllib.parse.urlencode(pairs)
    return urllib.parse.urlunsplit(
        (parts.scheme, parts.netloc, parts.path, new_query, parts.fragment)
    )


def _ensure_query_param(url, name, value):
    """Ensure url carries name=value (used to keep nonce across redirects)."""
    parts = urllib.parse.urlsplit(url)
    for k, v in urllib.parse.parse_qsl(parts.query, keep_blank_values=True):
        if k == name and v == value:
            return url
    return _append_query_param(url, name, value)


def _repair_download_headers(netloc, unconditional=False):
    """Build repair-hop GET headers.

    Never include If-None-Match / If-Modified-Since / If-Range.
    Unconditional retries also send no-cache / no-store and Accept-Encoding: identity.
    """
    headers = {
        'Host': netloc,
        'Connection': 'close',
    }
    if unconditional:
        headers['Cache-Control'] = 'no-cache, no-store, max-age=0'
        headers['Pragma'] = 'no-cache'
        headers['Accept-Encoding'] = 'identity'
    # Explicitly ensure conditional validators are never sent.
    for key in ('If-None-Match', 'If-Modified-Since', 'If-Range'):
        headers.pop(key, None)
    return headers


def _download_url_atomic(url, cache_dir, max_redirects=8):
    """Download URL following redirects; atomically store under URL-hash path.

    On HTTP 304 with no stored body, retries once with an unconditional GET
    (no conditional validators; Cache-Control/Pragma no-cache; Accept-Encoding:
    identity) and a cache-busting dur_repair_nonce query parameter.
    original_url / object key stay on the pre-nonce URL; final_url records the
    actual request/response URL.

    Returns dict with status, original_url, final_url, redirect_chain, size_bytes,
    sha256, local_path, error.
    """
    from http.client import HTTPConnection, HTTPSConnection
    import tempfile

    original = url
    current = url
    method = 'GET'
    redirects = []
    unconditional = False
    unconditional_retry_done = False
    repair_nonce = None
    result = {
        'original_url': original, 'final_url': original, 'redirect_chain': [original],
        'http_status': 0, 'size_bytes': 0, 'sha256': '', 'local_path': '',
        'content_length': None, 'error': '',
    }
    hops = 0
    while hops < max_redirects:
        parsed = urllib.parse.urlparse(current)
        if parsed.scheme not in ('http', 'https'):
            result['error'] = 'unsupported_scheme'
            return result
        if parsed.scheme == 'https':
            conn = HTTPSConnection(parsed.hostname, parsed.port or 443, timeout=120)
        else:
            conn = HTTPConnection(parsed.hostname, parsed.port or 80, timeout=120)
        path = parsed.path or '/'
        if parsed.query:
            path += '?' + parsed.query
        try:
            req_headers = _repair_download_headers(parsed.netloc, unconditional=unconditional)
            conn.request(method, path, headers=req_headers)
            resp = conn.getresponse()
            status = resp.status
            headers = resp.getheaders()
            sys.stderr.write(
                '[INFO] repair-hop: url={} status={} unconditional={}\n'.format(
                    current, status, 'true' if unconditional else 'false',
                )
            )
            sys.stderr.flush()
            if status in (301, 302, 303, 307, 308):
                loc = dict(headers).get('Location') or dict(
                    ((k.lower(), v) for k, v in headers)).get('location')
                try:
                    resp.read()
                except Exception:
                    pass
                conn.close()
                if not loc:
                    result['http_status'] = status
                    result['error'] = 'redirect_without_location'
                    return result
                if loc.startswith('/'):
                    loc = '{}://{}{}'.format(parsed.scheme, parsed.netloc, loc)
                if unconditional and repair_nonce:
                    loc = _ensure_query_param(loc, DUR_REPAIR_NONCE_PARAM, repair_nonce)
                redirects.append(loc)
                current = loc
                if status == 303:
                    method = 'GET'
                hops += 1
                continue
            clen = None
            for k, v in headers:
                if k.lower() == 'content-length':
                    try:
                        clen = int(v)
                    except ValueError:
                        clen = None
            hasher = hashlib.sha256()
            tmp_dir = os.path.join(str(cache_dir), '.tmp')
            if not os.path.isdir(tmp_dir):
                os.makedirs(tmp_dir)
            fd, tmp_path = tempfile.mkstemp(prefix='dur-repair-', dir=tmp_dir)
            os.close(fd)
            size = 0
            try:
                with open(tmp_path, 'wb') as fh:
                    while True:
                        chunk = resp.read(65536)
                        if not chunk:
                            break
                        fh.write(chunk)
                        hasher.update(chunk)
                        size += len(chunk)
                    fh.flush()
                    try:
                        os.fsync(fh.fileno())
                    except Exception:
                        pass
            finally:
                try:
                    resp.close()
                except Exception:
                    pass
                try:
                    conn.close()
                except Exception:
                    pass
            result['http_status'] = status
            result['final_url'] = current
            chain = [original] + redirects
            if chain[-1] != current:
                chain.append(current)
            result['redirect_chain'] = chain
            result['content_length'] = clen if clen is not None else size
            result['size_bytes'] = size
            if status == 304:
                try:
                    os.unlink(tmp_path)
                except Exception:
                    pass
                stored_path, _meta_path, _key = object_paths_for_url(cache_dir, original)
                if (not stored_path.is_file()) and (not unconditional_retry_done):
                    # No prior body: one unconditional GET retry (repair-hop only)
                    # with cache-busting query (not used on first request / recorder).
                    unconditional_retry_done = True
                    unconditional = True
                    repair_nonce = _new_repair_nonce()
                    current = _append_query_param(
                        original, DUR_REPAIR_NONCE_PARAM, repair_nonce,
                    )
                    redirects = []
                    hops = 0
                    method = 'GET'
                    continue
                result['error'] = 'HTTP 304'
                return result
            if status != 200:
                try:
                    os.unlink(tmp_path)
                except Exception:
                    pass
                result['error'] = 'HTTP {}'.format(status)
                return result
            if clen is not None and size != clen:
                try:
                    os.unlink(tmp_path)
                except Exception:
                    pass
                result['error'] = 'incomplete_body'
                return result
            sha = hasher.hexdigest()
            # Object key always from original_url (no cache-busting query).
            final_path, meta_path, _key = object_paths_for_url(cache_dir, original)
            directory = final_path.parent
            directory.mkdir(parents=True, exist_ok=True)
            meta = {
                'original_url': original,
                'final_url': current,
                'redirect_chain': chain,
                'http_status': status,
                'content_length': result['content_length'],
                'size_bytes': size,
                'sha256': sha,
                'local_path': str(final_path),
                'captured_at': utc_now(),
                'recovered_post_hop': True,
                'checksum_source': 'post_hop_download',
                'exact_original_capture': False,
            }
            ftype = classify_url(original)
            if ftype in MUTABLE_FILE_TYPES:
                meta['mutable_metadata'] = True
                meta['note'] = 'not_exact_original_capture'
            meta_tmp = str(meta_path) + '.tmp.' + str(os.getpid())
            with open_text(meta_tmp, 'w') as mf:
                mf.write(json.dumps(meta, indent=2, sort_keys=True) + '\n')
                mf.flush()
                try:
                    os.fsync(mf.fileno())
                except Exception:
                    pass
            os.replace(tmp_path, str(final_path))
            os.replace(meta_tmp, str(meta_path))
            result['sha256'] = sha
            result['local_path'] = str(final_path)
            return result
        except Exception as exc:
            try:
                conn.close()
            except Exception:
                pass
            result['error'] = str(exc)
            return result
    result['error'] = 'redirect_loop'
    result['http_status'] = 508
    return result


def repair_hop(hop_dir: Path, hop: str) -> Dict[str, Any]:
    """Re-download unresolved URLs into recorder cache; rebuild manifests."""
    hop_dir = Path(hop_dir)
    runtime = hop_dir / 'runtime'
    cache_dir = runtime / 'deb-cache'
    cache_dir.mkdir(parents=True, exist_ok=True)
    repair_log = runtime / 'repair-access.log'
    _, unresolved_pkgs = read_tsv(hop_dir / 'unresolved-packages.tsv')
    _, unresolved_files = read_tsv(hop_dir / 'unresolved-files.tsv')
    targets = []
    seen = set()
    for r in unresolved_pkgs + unresolved_files:
        url = r.get('original_url') or r.get('final_url') or ''
        if not url or is_recorder_selftest_url(url):
            continue
        # Prefer original_url; fall back to final_url
        for candidate in (r.get('original_url'), r.get('final_url')):
            if candidate and candidate not in seen:
                # Keep one download key per original when possible
                pass
        key = r.get('original_url') or r.get('final_url')
        if key in seen:
            continue
        seen.add(key)
        targets.append(key)

    recovered = []
    still_failed = []
    with open_text(repair_log, 'a') as logfh:
        logfh.write('# repair-hop {}\n'.format(utc_now()))
        for url in targets:
            # urllib.parse handles percent-encoding in the URL string as-is
            info = _download_url_atomic(url, cache_dir)
            status = info.get('http_status') or 0
            size = info.get('size_bytes') or 0
            sha = info.get('sha256') or ''
            local_path = info.get('local_path') or ''
            final = info.get('final_url') or url
            chain = info.get('redirect_chain') or []
            parts = [utc_now(), 'GET', url, str(status), str(size)]
            if final != url:
                parts.append('final={}'.format(final))
            if len(chain) > 1:
                parts.append('redirects={}'.format('->'.join(chain)))
            if info.get('content_length') is not None:
                parts.append('content_length={}'.format(info['content_length']))
            if sha:
                parts.append('sha256={}'.format(sha))
            if local_path:
                parts.append('local_path={}'.format(local_path))
            logfh.write(' '.join(parts) + '\n')
            logfh.flush()
            try:
                os.fsync(logfh.fileno())
            except Exception:
                pass
            if status == 200 and local_path and Path(local_path).is_file():
                recovered.append(info)
            else:
                still_failed.append({'url': url, 'error': info.get('error') or 'HTTP {}'.format(status)})

    evidence = build_required_manifests(hop_dir, hop)
    evidence['recovered_post_hop'] = True
    evidence['checksum_source'] = 'post_hop_download'
    evidence['repair_notes'] = {
        'recovered_count': len(recovered),
        'failed_count': len(still_failed),
        'targets': len(targets),
        'exact_original_capture': False,
        'mutable_metadata_warning': True,
    }
    write_text(hop_dir / 'evidence.json', json.dumps(evidence, indent=2) + '\n')
    write_text(
        runtime / 'repair-summary.json',
        json.dumps({
            'recovered': len(recovered),
            'failed': still_failed,
            'generated_at': utc_now(),
        }, indent=2) + '\n',
    )
    return evidence


def cmd_classify_url(args: argparse.Namespace) -> int:
    print(classify_url(args.url))
    return 0

def cmd_parse_access_log(args: argparse.Namespace) -> int:
    text = read_text(Path(args.log))
    records = parse_access_log(text)
    rows = aggregate_urls(records, args.hop)
    write_tsv(Path(args.output), ['hop', 'requested_at', 'method', 'original_url', 'final_url', 'http_status', 'size_bytes', 'sha256', 'local_path', 'request_count', 'file_type', 'repository_host', 'first_requested_at', 'last_requested_at'], rows)
    print('wrote {} url rows'.format(len(rows)))
    return 0

def cmd_parse_packages_index(args: argparse.Namespace) -> int:
    text = read_text(Path(args.index))
    pkgs = parse_packages_index(text)
    write_tsv(Path(args.output), ['Package', 'Version', 'Architecture', 'Filename', 'SHA256', 'Size', 'Depends', 'Provides'], [{'Package': p.get('Package', ''), 'Version': p.get('Version', ''), 'Architecture': p.get('Architecture', ''), 'Filename': p.get('Filename', ''), 'SHA256': p.get('SHA256', ''), 'Size': p.get('Size', ''), 'Depends': p.get('Depends', ''), 'Provides': p.get('Provides', '')} for p in pkgs])
    print('wrote {} packages'.format(len(pkgs)))
    return 0

def cmd_diff_packages(args: argparse.Namespace) -> int:
    result = diff_packages(Path(args.before), Path(args.after))
    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)
    for name, rows in result.items():
        write_tsv(out / 'packages-{}.tsv'.format(name), ['package', 'architecture', 'version_before', 'version_after', 'change_type'], rows)
    print(json.dumps({k: len(v) for k, v in result.items()}))
    return 0

def cmd_build_manifests(args: argparse.Namespace) -> int:
    try:
        evidence = build_required_manifests(Path(args.hop_dir), args.hop)
        print(json.dumps(evidence))
        return 0
    except Exception as exc:
        import traceback
        sys.stderr.write('[ERROR] build-manifests failed: %s\n' % exc)
        traceback.print_exc()
        return 1

def cmd_validate(args: argparse.Namespace) -> int:
    ok, failures = validate_hop(Path(args.hop_dir), args.hop, args.from_os, args.to_os)
    print('PASS' if ok else 'FAIL')
    for f in failures:
        print(f)
    return 0 if ok else 1


def cmd_repair_hop(args: argparse.Namespace) -> int:
    try:
        evidence = repair_hop(Path(args.hop_dir), args.hop)
        print(json.dumps({
            'recovered_post_hop': True,
            'unresolved_packages': evidence.get('unresolved_packages'),
            'unresolved_files': evidence.get('unresolved_files'),
            'resolved_packages': evidence.get('resolved_packages'),
            'resolved_files': evidence.get('resolved_files'),
        }))
        return 0
    except Exception as exc:
        import traceback
        sys.stderr.write('[ERROR] repair-hop failed: %s\n' % exc)
        traceback.print_exc()
        return 1


def tsv_data_row_count(path: Path) -> int:
    """Count TSV data rows (header excluded). Missing file => -1."""
    if not path.is_file():
        return -1
    _hdr, rows = read_tsv(path)
    return len(rows)


def _rmtree_quiet(path: Path) -> None:
    try:
        if path.is_dir():
            shutil.rmtree(str(path))
        elif path.exists():
            os.unlink(str(path))
    except Exception:
        pass


def resolve_export_source(output_dir: Path) -> Tuple[str, str, str, Path]:
    """Resolve (hop, from_os, to_os, hop_dir) from discovery output-dir state/metadata."""
    output_dir = Path(output_dir)
    root = output_dir / 'upgrade-discovery'
    state_path = root / '.discovery-state.json'
    hop = ''
    from_os = ''
    to_os = ''
    if state_path.is_file():
        try:
            state = json.loads(read_text(state_path))
        except Exception as exc:
            raise ValueError('cannot parse {}: {}'.format(state_path, exc))
        hop = (state.get('hop') or '').strip()
        from_os = (state.get('from_os') or '').strip()
        to_os = (state.get('to_os') or '').strip()
    if hop and hop not in HOP_FROM_TO:
        raise ValueError('unsupported hop in state: {}'.format(hop))
    if hop:
        hop_dir = root / hop
        if not hop_dir.is_dir():
            raise ValueError('hop directory missing: {}'.format(hop_dir))
        run_json = hop_dir / 'run.json'
        if run_json.is_file():
            try:
                meta = json.loads(read_text(run_json))
                from_os = from_os or (meta.get('from_os') or '')
                to_os = to_os or (meta.get('to_os') or '')
                if meta.get('hop') and meta.get('hop') != hop:
                    raise ValueError(
                        'hop mismatch: state={} run.json={}'.format(hop, meta.get('hop')))
            except ValueError:
                raise
            except Exception as exc:
                raise ValueError('cannot parse {}: {}'.format(run_json, exc))
        if not from_os or not to_os:
            from_os, to_os = HOP_FROM_TO[hop]
        from_os = normalize_version(from_os)
        to_os = normalize_version(to_os)
        expected = hop_name(from_os, to_os)
        if expected != hop:
            raise ValueError(
                'hop/os mismatch: hop={} from={} to={} expected={}'.format(
                    hop, from_os, to_os, expected))
        return (hop, from_os, to_os, hop_dir)

    # Fallback: exactly one supported hop directory with run.json or validation.txt
    found = []
    for candidate in HOP_ORDER:
        hop_dir = root / candidate
        if not hop_dir.is_dir():
            continue
        if (hop_dir / 'run.json').is_file() or (hop_dir / 'validation.txt').is_file():
            found.append(candidate)
    if not found:
        raise ValueError(
            'cannot determine hop under {}; missing .discovery-state.json'.format(root))
    if len(found) > 1:
        raise ValueError(
            'ambiguous hops under {}: {}; ensure .discovery-state.json exists'.format(
                root, ','.join(found)))
    hop = found[0]
    hop_dir = root / hop
    from_os, to_os = HOP_FROM_TO[hop]
    run_json = hop_dir / 'run.json'
    if run_json.is_file():
        try:
            meta = json.loads(read_text(run_json))
            if meta.get('from_os'):
                from_os = normalize_version(meta['from_os'])
            if meta.get('to_os'):
                to_os = normalize_version(meta['to_os'])
        except Exception as exc:
            raise ValueError('cannot parse {}: {}'.format(run_json, exc))
    return (hop, from_os, to_os, hop_dir)


def _load_export_evidence(hop_dir: Path) -> Dict[str, Any]:
    evidence_path = Path(hop_dir) / 'evidence.json'
    if not evidence_path.is_file():
        return {}
    try:
        return json.loads(read_text(evidence_path))
    except Exception:
        return {}


def _validation_is_pass(hop_dir: Path) -> bool:
    path = Path(hop_dir) / 'validation.txt'
    if not path.is_file():
        return False
    return 'VALIDATION: PASS' in read_text(path)


def _parse_validation_metric(hop_dir: Path, key: str):
    path = Path(hop_dir) / 'validation.txt'
    if not path.is_file():
        return None
    prefix = key + '='
    for line in read_text(path).splitlines():
        if line.startswith(prefix):
            try:
                return int(line.split('=', 1)[1].strip())
            except ValueError:
                return None
    return None


def _row_looks_secured(row: Dict[str, str]) -> bool:
    """True when a required-files row appears successfully captured."""
    lp = row.get('local_path') or ''
    if lp:
        return True
    try:
        status = int(row.get('http_status') or 0)
    except ValueError:
        status = 0
    return status in (200, 304)


def _row_url_set(row: Dict[str, str]) -> set:
    urls = set()
    for key in ('original_url', 'final_url'):
        url = (row.get(key) or '').strip()
        if url:
            urls.add(url)
    return urls


def _http_status_int(row: Dict[str, str]) -> int:
    try:
        return int(row.get('http_status') or 0)
    except (TypeError, ValueError):
        return 0


def _unresolved_url_set(rows: List[Dict[str, str]]) -> set:
    urls = set()
    for row in rows:
        urls |= _row_url_set(row)
    return urls


def _failed_request_urls(row: Dict[str, str]) -> set:
    return _row_url_set(row)


def identify_historical_non_required_failures(
        failed_requests,
        unresolved_packages,
        unresolved_files,
        required_files):
    """Identify stale by-hash 404s to exclude from final required manifests.

    Returns (url_set, reasons_ordered_dict, matched_failed_rows).
    failed-requests.tsv rows themselves are never removed.
    """
    unresolved_urls = (
        _unresolved_url_set(unresolved_packages) | _unresolved_url_set(unresolved_files)
    )
    if not _export_has_secured_repo_metadata(required_files):
        return set(), OrderedDict(), []
    stale_urls = set()
    reasons = OrderedDict()
    matched = []
    for row in failed_requests:
        ftype = (row.get('file_type') or '').strip()
        if not ftype:
            ftype = classify_url(row.get('final_url') or row.get('original_url') or '')
        status = _http_status_int(row)
        urls = _failed_request_urls(row)
        if ftype != 'by_hash' or status != 404 or not urls:
            continue
        if urls & unresolved_urls:
            continue
        matched.append(row)
        stale_urls.update(urls)
        reasons['stale_by_hash_404'] = int(reasons.get('stale_by_hash_404') or 0) + 1
    return stale_urls, reasons, matched


def _export_resolved_counts_match(
        hop_dir: Path,
        req_pkgs: List[Dict[str, str]],
        req_files: List[Dict[str, str]],
        evidence: Dict[str, Any],
        unres_pkgs=None,
        unres_files=None) -> bool:
    """True when required == resolved + unresolved for packages and files."""
    required_packages = len(req_pkgs)
    required_files = len(req_files)
    if unres_pkgs is None:
        unres_pkgs = _tsv_data_rows(hop_dir / 'unresolved-packages.tsv') if (
            hop_dir / 'unresolved-packages.tsv').is_file() else []
    if unres_files is None:
        unres_files = _tsv_data_rows(hop_dir / 'unresolved-files.tsv') if (
            hop_dir / 'unresolved-files.tsv').is_file() else []
    unresolved_packages = len(unres_pkgs)
    unresolved_files = len(unres_files)
    resolved_packages = evidence.get('resolved_packages')
    resolved_files = evidence.get('resolved_files')
    if resolved_packages is None:
        resolved_packages = _parse_validation_metric(hop_dir, 'resolved_packages')
    if resolved_files is None:
        resolved_files = _parse_validation_metric(hop_dir, 'resolved_files')
    if resolved_packages is None or resolved_files is None:
        return False
    try:
        return (
            int(resolved_packages) + unresolved_packages == required_packages
            and int(resolved_files) + unresolved_files == required_files
        )
    except (TypeError, ValueError):
        return False


def _export_has_secured_repo_metadata(req_files: List[Dict[str, str]]) -> bool:
    for row in req_files:
        ftype = row.get('file_type') or ''
        if ftype in EXPORT_REPO_METADATA_TYPES and _row_looks_secured(row):
            return True
    return False


def _export_critical_assets_missing(
        req_pkgs: List[Dict[str, str]],
        req_files: List[Dict[str, str]]) -> List[str]:
    """Hop-level gaps for release-upgrader / essential repository metadata."""
    reasons = []
    if req_files and not _export_has_secured_repo_metadata(req_files):
        reasons.append('required_repository_metadata_missing')
    for row in req_files:
        if row.get('file_type') != 'release_upgrader':
            continue
        filename = str(row.get('filename') or '')
        if not (
            filename.endswith('.tar.gz')
            or filename.endswith('.tar.gz.gpg')
            or filename.endswith('.gpg')
        ):
            continue
        if not _row_looks_secured(row):
            reasons.append('release_upgrader_not_secured:{}'.format(
                row.get('final_url') or row.get('original_url') or filename))
    # Packages are enforced via unresolved + failed-request classification;
    # fixtures may omit on-disk bodies while still recording resolved counts.
    _ = req_pkgs
    return reasons


def _hop_allows_non_blocking_failures(
        hop_dir: Path,
        req_pkgs: List[Dict[str, str]],
        req_files: List[Dict[str, str]],
        unres_pkgs: List[Dict[str, str]],
        unres_files: List[Dict[str, str]],
        evidence: Dict[str, Any]) -> bool:
    if not _validation_is_pass(hop_dir):
        return False
    if unres_pkgs or unres_files:
        return False
    if not _export_resolved_counts_match(
            hop_dir, req_pkgs, req_files, evidence,
            unres_pkgs=unres_pkgs, unres_files=unres_files):
        return False
    if not _export_has_secured_repo_metadata(req_files):
        return False
    return True


def classify_export_failed_requests(hop_dir: Path) -> Dict[str, Any]:
    """Classify failed-requests.tsv rows as blocking vs non-blocking.

    Preserves the TSV as historical evidence. Only stale by-hash 404 rows can be
    non-blocking, and only when hop-level PASS/resolved/metadata conditions hold.
    """
    hop_dir = Path(hop_dir)
    failed_path = hop_dir / 'failed-requests.tsv'
    req_pkgs = _tsv_data_rows(hop_dir / 'required-packages.tsv') if (
        hop_dir / 'required-packages.tsv').is_file() else []
    req_files = _tsv_data_rows(hop_dir / 'required-files.tsv') if (
        hop_dir / 'required-files.tsv').is_file() else []
    unres_pkgs = _tsv_data_rows(hop_dir / 'unresolved-packages.tsv') if (
        hop_dir / 'unresolved-packages.tsv').is_file() else []
    unres_files = _tsv_data_rows(hop_dir / 'unresolved-files.tsv') if (
        hop_dir / 'unresolved-files.tsv').is_file() else []
    failed_rows = _tsv_data_rows(failed_path) if failed_path.is_file() else []
    evidence = _load_export_evidence(hop_dir)
    unresolved_urls = _unresolved_url_set(unres_pkgs) | _unresolved_url_set(unres_files)
    allow_non_blocking = _hop_allows_non_blocking_failures(
        hop_dir, req_pkgs, req_files, unres_pkgs, unres_files, evidence)

    blocking = []
    non_blocking = []
    non_blocking_reasons = OrderedDict()
    for row in failed_rows:
        ftype = (row.get('file_type') or '').strip()
        if not ftype:
            ftype = classify_url(row.get('final_url') or row.get('original_url') or '')
        try:
            status = int(row.get('http_status') or 0)
        except ValueError:
            status = 0
        urls = _failed_request_urls(row)
        linked_unresolved = bool(urls & unresolved_urls)

        if linked_unresolved:
            blocking.append(row)
            continue
        if ftype in EXPORT_CRITICAL_FAILED_TYPES:
            blocking.append(row)
            continue
        if (
            ftype == 'by_hash'
            and status == 404
            and allow_non_blocking
            and not linked_unresolved
        ):
            non_blocking.append(row)
            reason = 'stale_by_hash_404'
            non_blocking_reasons[reason] = int(non_blocking_reasons.get(reason) or 0) + 1
            continue
        # Other historical failures remain blocking unless explicitly classified.
        blocking.append(row)

    total = len(failed_rows)
    return {
        'failed_requests_total': total,
        'failed_requests_blocking': len(blocking),
        'failed_requests_non_blocking': len(non_blocking),
        'non_blocking_failure_reasons': OrderedDict(non_blocking_reasons),
        'blocking_rows': blocking,
        'non_blocking_rows': non_blocking,
        'classification': 'non_blocking_historical_failure' if non_blocking else '',
    }


def check_export_eligible(hop_dir: Path) -> List[str]:
    """Return human-readable rejection reasons (empty => eligible)."""
    reasons = []
    hop_dir = Path(hop_dir)
    required = [
        'validation.txt',
        'required-packages.tsv',
        'required-files.tsv',
        'required-urls.tsv',
        'evidence.json',
        'unresolved-packages.tsv',
        'unresolved-files.tsv',
        'failed-requests.tsv',
    ]
    for name in required:
        if not (hop_dir / name).is_file():
            reasons.append('missing:{}'.format(name))
    if not _validation_is_pass(hop_dir):
        if (hop_dir / 'validation.txt').is_file():
            reasons.append('validation_not_pass')
    for name in ('unresolved-packages.tsv', 'unresolved-files.tsv'):
        path = hop_dir / name
        if not path.is_file():
            continue
        n = tsv_data_row_count(path)
        if n < 0:
            reasons.append('unreadable:{}'.format(name))
        elif n > 0:
            reasons.append('nonempty_data_rows:{}:{}'.format(name, n))
    failed_path = hop_dir / 'failed-requests.tsv'
    if failed_path.is_file():
        n = tsv_data_row_count(failed_path)
        if n < 0:
            reasons.append('unreadable:failed-requests.tsv')

    req_pkgs = _tsv_data_rows(hop_dir / 'required-packages.tsv') if (
        hop_dir / 'required-packages.tsv').is_file() else []
    req_files = _tsv_data_rows(hop_dir / 'required-files.tsv') if (
        hop_dir / 'required-files.tsv').is_file() else []
    unres_pkgs = _tsv_data_rows(hop_dir / 'unresolved-packages.tsv') if (
        hop_dir / 'unresolved-packages.tsv').is_file() else []
    unres_files = _tsv_data_rows(hop_dir / 'unresolved-files.tsv') if (
        hop_dir / 'unresolved-files.tsv').is_file() else []
    evidence = _load_export_evidence(hop_dir)
    if not _export_resolved_counts_match(
            hop_dir, req_pkgs, req_files, evidence,
            unres_pkgs=unres_pkgs, unres_files=unres_files):
        reasons.append('required_resolved_unresolved_count_mismatch')
    reasons.extend(_export_critical_assets_missing(req_pkgs, req_files))

    classification = classify_export_failed_requests(hop_dir)
    blocking_n = int(classification.get('failed_requests_blocking') or 0)
    if blocking_n > 0:
        reasons.append('blocking_failed_requests:{}'.format(blocking_n))
    return reasons


def _build_export_summary(
        hop, from_os, to_os, source_output_dir, hop_dir, exported_at_utc,
        failed_classification=None):
    counts = {
        'required_packages': tsv_data_row_count(hop_dir / 'required-packages.tsv'),
        'required_files': tsv_data_row_count(hop_dir / 'required-files.tsv'),
        'required_urls': tsv_data_row_count(hop_dir / 'required-urls.tsv'),
        'unresolved_packages': tsv_data_row_count(hop_dir / 'unresolved-packages.tsv'),
        'unresolved_files': tsv_data_row_count(hop_dir / 'unresolved-files.tsv'),
        'failed_requests': tsv_data_row_count(hop_dir / 'failed-requests.tsv'),
    }
    if failed_classification is None:
        failed_classification = classify_export_failed_requests(hop_dir)
    total = int(failed_classification.get('failed_requests_total') or counts['failed_requests'] or 0)
    blocking = int(failed_classification.get('failed_requests_blocking') or 0)
    non_blocking = int(failed_classification.get('failed_requests_non_blocking') or 0)
    nb_reasons = failed_classification.get('non_blocking_failure_reasons') or {}
    if not isinstance(nb_reasons, dict):
        nb_reasons = {}
    evidence = _load_export_evidence(hop_dir)
    recovered = evidence.get('recovered_post_hop')
    if recovered is None:
        recovered = False
    checksum_source = evidence.get('checksum_source')
    if checksum_source is None:
        checksum_source = 'original_capture'
    captured_http_200 = evidence.get('captured_http_200')
    if 'captured_http_200' not in evidence:
        captured_http_200 = None
    captured_bytes = evidence.get('captured_bytes')
    if 'captured_bytes' not in evidence:
        captured_bytes = None
    resolved_packages = evidence.get('resolved_packages')
    if resolved_packages is None:
        resolved_packages = _parse_validation_metric(hop_dir, 'resolved_packages')
    resolved_files = evidence.get('resolved_files')
    if resolved_files is None:
        resolved_files = _parse_validation_metric(hop_dir, 'resolved_files')
    hist_total = evidence.get('historical_non_required_failures')
    if hist_total is None:
        hist_total = 0
    hist_reasons = evidence.get('historical_non_required_failure_reasons') or {}
    if not isinstance(hist_reasons, dict):
        hist_reasons = {}
    summary = OrderedDict([
        ('schema_version', 1),
        ('hop', hop),
        ('from_os', from_os),
        ('to_os', to_os),
        ('validation', 'PASS'),
        ('source_output_dir', str(source_output_dir)),
        ('exported_at_utc', exported_at_utc),
        ('required_packages', counts['required_packages']),
        ('resolved_packages', resolved_packages),
        ('required_files', counts['required_files']),
        ('resolved_files', resolved_files),
        ('required_urls', counts['required_urls']),
        ('unresolved_packages', counts['unresolved_packages']),
        ('unresolved_files', counts['unresolved_files']),
        ('failed_requests', total),
        ('failed_requests_total', total),
        ('failed_requests_blocking', blocking),
        ('failed_requests_non_blocking', non_blocking),
        ('non_blocking_failure_reasons', OrderedDict(nb_reasons)),
        ('historical_non_required_failures', hist_total),
        ('historical_non_required_failure_reasons', OrderedDict(hist_reasons)),
        ('recovered_post_hop', bool(recovered)),
        ('checksum_source', checksum_source),
        ('captured_http_200', captured_http_200),
        ('captured_bytes', captured_bytes),
    ])
    return summary


def _write_checksums_sha256(staging: Path, names: List[str]) -> str:
    lines = []
    for name in names:
        digest = sha256_file(staging / name)
        lines.append('{}  {}\n'.format(digest, name))
    text = ''.join(lines)
    write_text(staging / 'checksums.sha256', text)
    return text


def _verify_checksums_file(directory: Path, checksums_text: str) -> None:
    for line in checksums_text.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            raise ValueError('invalid checksums.sha256 line: {}'.format(line))
        expected, name = parts[0], parts[1]
        # sha256sum may use "  " or " *" prefix; strip optional binary marker.
        if name.startswith('*') or name.startswith(' '):
            name = name[1:]
        path = directory / name
        if not path.is_file():
            raise ValueError('checksum target missing: {}'.format(name))
        actual = sha256_file(path)
        if actual.lower() != expected.lower():
            raise ValueError(
                'checksum mismatch for {}: expected={} actual={}'.format(
                    name, expected, actual))


def _update_export_index(artifacts_dir: Path, summary: Dict[str, Any]) -> None:
    index_path = artifacts_dir / 'index.tsv'
    by_hop = OrderedDict()
    if index_path.is_file():
        _hdr, rows = read_tsv(index_path)
        for row in rows:
            h = row.get('hop') or ''
            if h:
                by_hop[h] = row
    recovered = summary.get('recovered_post_hop')
    if isinstance(recovered, bool):
        recovered_s = 'true' if recovered else 'false'
    else:
        recovered_s = str(recovered).lower() if recovered is not None else 'false'
    failed_total = summary.get('failed_requests_total')
    if failed_total is None:
        failed_total = summary.get('failed_requests', 0)
    by_hop[summary['hop']] = {
        'hop': summary['hop'],
        'from_os': summary['from_os'],
        'to_os': summary['to_os'],
        'validation': summary.get('validation') or 'PASS',
        'required_packages': summary.get('required_packages', 0),
        'required_files': summary.get('required_files', 0),
        'required_urls': summary.get('required_urls', 0),
        'unresolved_packages': summary.get('unresolved_packages', 0),
        'unresolved_files': summary.get('unresolved_files', 0),
        'failed_requests': failed_total,
        'failed_requests_total': failed_total,
        'failed_requests_blocking': summary.get('failed_requests_blocking', 0),
        'failed_requests_non_blocking': summary.get('failed_requests_non_blocking', 0),
        'recovered_post_hop': recovered_s,
        'exported_at_utc': summary.get('exported_at_utc') or '',
        'relative_path': summary['hop'],
    }
    ordered = []
    for h in HOP_ORDER:
        if h in by_hop:
            ordered.append(by_hop[h])
    for h, row in by_hop.items():
        if h not in HOP_ORDER:
            ordered.append(row)
    tmp = artifacts_dir / ('.index.tsv.tmp.{}'.format(os.getpid()))
    try:
        write_tsv(tmp, EXPORT_INDEX_HEADER, ordered)
        os.replace(str(tmp), str(index_path))
    finally:
        _rmtree_quiet(tmp)


def _atomic_replace_dir(staging: Path, final: Path) -> None:
    """Replace final directory with staging contents atomically (best-effort)."""
    parent = final.parent
    parent.mkdir(parents=True, exist_ok=True)
    replace_path = parent / ('.replace-{}-{}'.format(final.name, os.getpid()))
    old_path = parent / ('.old-{}-{}'.format(final.name, os.getpid()))
    _rmtree_quiet(replace_path)
    _rmtree_quiet(old_path)
    os.rename(str(staging), str(replace_path))
    try:
        if final.exists() or final.is_symlink():
            os.rename(str(final), str(old_path))
            try:
                os.rename(str(replace_path), str(final))
            except Exception:
                os.rename(str(old_path), str(final))
                raise
            _rmtree_quiet(old_path)
        else:
            os.rename(str(replace_path), str(final))
    finally:
        _rmtree_quiet(replace_path)


def export_hop(output_dir: Path, repo_dir: Path) -> Dict[str, Any]:
    """Export PASS hop manifests into repo_dir/artifacts/upgrade-discovery/<hop>/."""
    output_dir = Path(output_dir).resolve()
    repo_dir = Path(repo_dir).resolve()
    hop, from_os, to_os, hop_dir = resolve_export_source(output_dir)
    reasons = check_export_eligible(hop_dir)
    if reasons:
        for r in reasons:
            sys.stderr.write('[ERROR] export-hop refused: {}\n'.format(r))
        raise ValueError('export-hop eligibility failed ({})'.format('; '.join(reasons)))

    artifacts = repo_dir / 'artifacts' / 'upgrade-discovery'
    artifacts.mkdir(parents=True, exist_ok=True)
    staging = artifacts / ('.staging-{}-{}'.format(hop, os.getpid()))
    final = artifacts / hop
    _rmtree_quiet(staging)
    staging.mkdir(parents=True, exist_ok=True)
    exported_at = utc_now()
    try:
        # Copy only lightweight manifests; never copy runtime/deb-cache/bodies.
        for name in EXPORT_MANIFEST_FILES:
            src = hop_dir / name
            dst = staging / name
            shutil.copy2(str(src), str(dst))
            if not dst.is_file():
                raise IOError('copy failed: {}'.format(name))
            if sha256_file(src) != sha256_file(dst):
                raise IOError('copy checksum mismatch: {}'.format(name))

        # Reject accidental payload leakage into staging.
        for root, dirs, files in os.walk(str(staging)):
            base_dirs = set(dirs)
            for banned in ('runtime', 'deb-cache', 'payload', 'responses', 'before', 'after'):
                if banned in base_dirs:
                    raise IOError('refusing export staging content: {}'.format(banned))
            for fn in files:
                lower = fn.lower()
                if lower.endswith((
                        '.deb', '.udeb', '.tar', '.tar.gz', '.xz', '.gz', '.bz2')):
                    raise IOError('refusing export of payload file: {}'.format(fn))

        failed_classification = classify_export_failed_requests(hop_dir)
        summary = _build_export_summary(
            hop, from_os, to_os, output_dir, hop_dir, exported_at,
            failed_classification=failed_classification)
        # Row counts must reflect copied staging files (same as source).
        summary['required_packages'] = tsv_data_row_count(staging / 'required-packages.tsv')
        summary['required_files'] = tsv_data_row_count(staging / 'required-files.tsv')
        summary['required_urls'] = tsv_data_row_count(staging / 'required-urls.tsv')
        summary['unresolved_packages'] = tsv_data_row_count(staging / 'unresolved-packages.tsv')
        summary['unresolved_files'] = tsv_data_row_count(staging / 'unresolved-files.tsv')
        total = tsv_data_row_count(staging / 'failed-requests.tsv')
        summary['failed_requests'] = total
        summary['failed_requests_total'] = total
        summary['failed_requests_blocking'] = int(
            failed_classification.get('failed_requests_blocking') or 0)
        summary['failed_requests_non_blocking'] = int(
            failed_classification.get('failed_requests_non_blocking') or 0)
        summary['non_blocking_failure_reasons'] = OrderedDict(
            failed_classification.get('non_blocking_failure_reasons') or {})
        write_text(
            staging / 'export-summary.json',
            json.dumps(summary, indent=2, ensure_ascii=False) + '\n',
        )

        checksums_text = _write_checksums_sha256(staging, EXPORT_CHECKSUM_FILES)
        _verify_checksums_file(staging, checksums_text)

        _atomic_replace_dir(staging, final)
        # staging path was renamed away; mark cleaned
        staging = artifacts / ('.staging-{}-{}'.format(hop, os.getpid()))

        # Re-verify final files against checksums.sha256
        final_checksums = read_text(final / 'checksums.sha256')
        _verify_checksums_file(final, final_checksums)

        _update_export_index(artifacts, summary)
        return summary
    except Exception:
        _rmtree_quiet(staging)
        _rmtree_quiet(artifacts / ('.replace-{}-{}'.format(hop, os.getpid())))
        _rmtree_quiet(artifacts / ('.old-{}-{}'.format(hop, os.getpid())))
        # Never leave a partial final from this attempt; old final (if any) remains
        # because replace either fully succeeded or rolled back.
        raise


def cmd_export_hop(args: argparse.Namespace) -> int:
    try:
        summary = export_hop(Path(args.output_dir), Path(args.repo_dir))
        print(json.dumps({
            'exported': True,
            'hop': summary.get('hop'),
            'relative_path': summary.get('hop'),
            'exported_at_utc': summary.get('exported_at_utc'),
            'required_packages': summary.get('required_packages'),
            'required_files': summary.get('required_files'),
            'required_urls': summary.get('required_urls'),
        }, indent=2, ensure_ascii=False))
        return 0
    except Exception as exc:
        sys.stderr.write('[ERROR] export-hop failed: %s\n' % exc)
        return 1


def cmd_sha256(args: argparse.Namespace) -> int:
    print(sha256_file(Path(args.path)))
    return 0

def cmd_extract_deb(args: argparse.Namespace) -> int:
    meta = extract_deb_control(Path(args.deb))
    fn = deb_fields_from_filename(Path(args.deb).name)
    for k in ('package', 'version', 'architecture', 'source_package'):
        print('{}={}'.format(k, meta.get(k) or fn.get(k, '')))
    print('sha256={}'.format(sha256_file(Path(args.deb))))
    print('size_bytes={}'.format(Path(args.deb).stat().st_size))
    return 0

def cmd_hop_name(args: argparse.Namespace) -> int:
    try:
        print(hop_name(args.from_os, args.to_os))
    except ValueError as exc:
        sys.stderr.write('ERROR: {}\n'.format(exc))
        return 2
    return 0


# Directory names skipped while walking product/data trees (basename match).
_SKIP_DIR_NAMES = frozenset([
    'data', 'cache', 'tmp', 'temp', 'logs', 'log', 'journal',
    '.git', 'node_modules', 'lost+found', 'proc', 'sys', 'dev',
    'docker', 'containers', 'volumes', 'snap',
])


# Back-compat aliases for inventory helpers.
_fs_decode = fs_decode
_open_text_surrogateescape = open_text


def _load_dpkg_owned_paths(info_dir, roots, progress_cb=None):
    """Load dpkg *.list paths once (O(packages)), not per-file dpkg-query -S.

    Reads *.list as binary and decodes with surrogateescape so non-ASCII / non-UTF-8
    path bytes never raise UnicodeDecodeError under LC_ALL=C.
    Returns (owned_paths_set, per_file_errors).
    """
    owned = set()
    errors = []
    if not os.path.isdir(info_dir):
        return owned, errors
    try:
        names = [n for n in os.listdir(info_dir) if n.endswith('.list')]
    except (IOError, OSError) as exc:
        raise IOError('cannot list dpkg info dir %s: %s' % (info_dir, exc))
    total = len(names)
    for i, name in enumerate(names, 1):
        path = os.path.join(info_dir, name)
        try:
            with open(path, 'rb') as fh:
                for raw in fh:
                    p = _fs_decode(raw).strip()
                    if not p:
                        continue
                    for root in roots:
                        if p == root or p.startswith(root.rstrip('/') + '/'):
                            owned.add(p)
                            break
        except (IOError, OSError) as exc:
            # One unreadable list must not abort the whole index; record and continue.
            errors.append('%s: %s' % (path, exc))
            if progress_cb:
                progress_cb('WARN skip unreadable dpkg list: %s (%s)' % (name, exc))
            continue
        if progress_cb and i % 200 == 0:
            progress_cb('dpkg-list %s/%s' % (i, total))
    return owned, errors


def collect_file_manifest(output_path, roots, host_root='', hash_max_bytes=262144,
                          max_entries=200000, dpkg_info_dir='/var/lib/dpkg/info'):
    """Fast file inventory for discovery before/after snapshots.

    Avoids per-file ``dpkg-query -S`` (multi-hour on real systems).
    Returns 0 on success, 1 on failure. Never leaves a partial success unmarked:
    callers must treat nonzero as inventory failure.

    ``max_entries`` defaults high enough for /opt/aelladata inventories.
    Pass max_entries=0 for unlimited (no truncation).
    """
    try:
        # dpkg *.list entries are host-absolute (/etc/...). Keep logical roots for
        # matching even when DUR_HOST_ROOT remaps the walk paths.
        dpkg_match_roots = []
        for r in roots:
            if r.startswith('/'):
                dpkg_match_roots.append(r)
            else:
                dpkg_match_roots.append('/' + r)

        if host_root:
            roots = [os.path.join(host_root, r.lstrip('/')) if r.startswith('/') else os.path.join(host_root, r)
                     for r in roots]
            dpkg_info_dir = os.path.join(host_root, dpkg_info_dir.lstrip('/'))

        abs_roots = []
        for r in roots:
            ap = os.path.abspath(r)
            if os.path.exists(ap):
                abs_roots.append(ap)

        def log(msg):
            sys.stderr.write('[INFO] file-manifest: %s\n' % msg)
            sys.stderr.flush()

        log('loading dpkg owned-path index (one-time)...')
        owned, load_errors = _load_dpkg_owned_paths(
            dpkg_info_dir, dpkg_match_roots, progress_cb=log)
        if host_root:
            # Also index hostroot-prefixed forms so walk paths match package_owned.
            hr = host_root.rstrip('/')
            prefixed = set()
            for p in owned:
                if p.startswith('/'):
                    prefixed.add(hr + p)
                else:
                    prefixed.add(hr + '/' + p)
            owned = owned | prefixed
        if load_errors:
            log('dpkg-list unreadable files=%s (continued)' % len(load_errors))
        log('owned-path index size=%s' % len(owned))

        import stat as statmod
        try:
            import pwd
            import grp
        except ImportError:
            pwd = None
            grp = None

        seen = [0]
        hashed = [0]
        skipped_hash = [0]

        out_dir = os.path.dirname(output_path)
        if out_dir and not os.path.isdir(out_dir):
            os.makedirs(out_dir)

        def file_origin(path):
            if path in owned:
                return 'package_owned'
            if '/usr/local/' in path or path.endswith('/usr/local') or '/usr/local' in path:
                return 'custom'
            if '/opt/aelladata' in path:
                return 'custom'
            return 'unknown'

        def emit(out, path):
            if max_entries > 0 and seen[0] >= max_entries:
                return False
            try:
                st = os.lstat(path)
            except (OSError, IOError):
                return True
            if os.path.islink(path):
                typ = 'symlink'
            elif statmod.S_ISDIR(st.st_mode):
                typ = 'dir'
            elif statmod.S_ISREG(st.st_mode):
                typ = 'file'
            else:
                typ = 'other'
            size = int(getattr(st, 'st_size', 0) or 0)
            owner = str(st.st_uid)
            group = str(st.st_gid)
            if pwd is not None:
                try:
                    owner = pwd.getpwuid(st.st_uid).pw_name
                except Exception:
                    pass
            if grp is not None:
                try:
                    group = grp.getgrgid(st.st_gid).gr_name
                except Exception:
                    pass
            mode = format(st.st_mode & 0o777, 'o')
            mtime = int(st.st_mtime)
            sha = ''
            reason = ''
            if typ == 'file':
                # Match directory basenames only (avoid false positives like /tmp/foo host roots).
                path_parts = set([p for p in path.split('/') if p])
                heavy = bool(path_parts & set(['data', 'cache', 'tmp', 'temp', 'logs', 'log']))
                if heavy or size > hash_max_bytes or path.endswith((
                        '.iso', '.img', '.qcow2', '.vmdk', '.raw', '.squashfs',
                        '.db', '.sqlite', '.bin', '.pack')):
                    reason = 'skipped_heavy_or_large'
                    skipped_hash[0] += 1
                else:
                    try:
                        sha = sha256_file(Path(path))
                        hashed[0] += 1
                    except Exception:
                        reason = 'hash_failed'
                        skipped_hash[0] += 1
            origin = file_origin(path)
            out.write('%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' % (
                path, typ, size, owner, group, mode, mtime, sha, reason, origin))
            seen[0] += 1
            if seen[0] % 500 == 0:
                log('entries=%s hashed=%s' % (seen[0], hashed[0]))
            return True if max_entries <= 0 else seen[0] < max_entries

        with _open_text_surrogateescape(output_path, 'w') as out:
            out.write('path\ttype\tsize\towner\tgroup\tmode\tmtime\tsha256\thash_skip_reason\tfile_origin\n')

            for root in abs_roots:
                log('walking %s' % root)
                if os.path.islink(root) or os.path.isfile(root):
                    emit(out, root)
                    continue

                for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
                    keep = []
                    for d in dirnames:
                        if d in _SKIP_DIR_NAMES:
                            continue
                        full = os.path.join(dirpath, d)
                        if '/opt/aelladata/' in (full + '/'):
                            if d in ('backup', 'backups', 'archive', 'archives', 'metrics', 'pcap'):
                                continue
                        keep.append(d)
                    dirnames[:] = keep

                    if not emit(out, dirpath):
                        break
                    for name in filenames:
                        if not emit(out, os.path.join(dirpath, name)):
                            break
                    if max_entries > 0 and seen[0] >= max_entries:
                        break
                if max_entries > 0 and seen[0] >= max_entries:
                    log('reached max_entries=%s; truncating further roots' % max_entries)
                    break

        if not os.path.isfile(output_path):
            sys.stderr.write('[ERROR] file-manifest: output missing after write: %s\n' % output_path)
            return 1

        log('done entries=%s hashed=%s hash_skipped=%s -> %s' % (
            seen[0], hashed[0], skipped_hash[0], output_path))
        return 0
    except Exception as exc:
        sys.stderr.write('[ERROR] file-manifest failed: %s\n' % exc)
        try:
            if output_path and os.path.isfile(output_path):
                os.remove(output_path)
        except Exception:
            pass
        return 1


def cmd_collect_file_manifest(args: argparse.Namespace) -> int:
    roots = list(args.roots) if args.roots else ['/etc', '/usr/local', '/opt/aelladata']
    return collect_file_manifest(
        args.output,
        roots,
        host_root=args.host_root or '',
        hash_max_bytes=int(args.hash_max_bytes),
        max_entries=int(args.max_entries),
        dpkg_info_dir=args.dpkg_info_dir,
    )


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog='discover_upgrade_requirements.py')
    sub = p.add_subparsers(dest='cmd')
    s = sub.add_parser('classify-url')
    s.add_argument('url')
    s.set_defaults(func=cmd_classify_url)
    s = sub.add_parser('parse-access-log')
    s.add_argument('--log', required=True)
    s.add_argument('--hop', required=True)
    s.add_argument('--output', required=True)
    s.set_defaults(func=cmd_parse_access_log)
    s = sub.add_parser('parse-packages-index')
    s.add_argument('--index', required=True)
    s.add_argument('--output', required=True)
    s.set_defaults(func=cmd_parse_packages_index)
    s = sub.add_parser('diff-packages')
    s.add_argument('--before', required=True)
    s.add_argument('--after', required=True)
    s.add_argument('--output-dir', required=True)
    s.set_defaults(func=cmd_diff_packages)
    s = sub.add_parser('build-manifests')
    s.add_argument('--hop-dir', required=True)
    s.add_argument('--hop', required=True)
    s.set_defaults(func=cmd_build_manifests)
    s = sub.add_parser('validate')
    s.add_argument('--hop-dir', required=True)
    s.add_argument('--hop', required=True)
    s.add_argument('--from-os', required=True)
    s.add_argument('--to-os', required=True)
    s.set_defaults(func=cmd_validate)
    s = sub.add_parser('repair-hop')
    s.add_argument('--hop-dir', required=True)
    s.add_argument('--hop', required=True)
    s.set_defaults(func=cmd_repair_hop)
    s = sub.add_parser('export-hop')
    s.add_argument('--output-dir', required=True)
    s.add_argument('--repo-dir', required=True)
    s.set_defaults(func=cmd_export_hop)
    s = sub.add_parser('sha256')
    s.add_argument('path')
    s.set_defaults(func=cmd_sha256)
    s = sub.add_parser('extract-deb')
    s.add_argument('deb')
    s.set_defaults(func=cmd_extract_deb)
    s = sub.add_parser('hop-name')
    s.add_argument('--from-os', required=True)
    s.add_argument('--to-os', required=True)
    s.set_defaults(func=cmd_hop_name)
    s = sub.add_parser('collect-file-manifest')
    s.add_argument('--output', required=True)
    s.add_argument('--host-root', default='')
    s.add_argument('--hash-max-bytes', default='262144')
    s.add_argument('--max-entries', default='200000',
                   help='Max inventory rows (0 = unlimited). Default raised to avoid '
                        'truncating /opt/aelladata on production DPs.')
    s.add_argument('--dpkg-info-dir', default='/var/lib/dpkg/info')
    s.add_argument('roots', nargs='*')
    s.set_defaults(func=cmd_collect_file_manifest)
    return p

def main(argv: Optional[List[str]]=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, 'cmd', None):
        parser.error('command required')
    return int(args.func(args))
if __name__ == '__main__':
    sys.exit(main())
