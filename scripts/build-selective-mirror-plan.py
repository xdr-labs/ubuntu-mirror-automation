#!/usr/bin/env python3
"""Build a discovery-exact selective offline mirror plan.

Reads artifacts/upgrade-discovery hop manifests (read-only) and writes:
  analysis/selective-mirror-plan.json
  analysis/selective-mirror-files.tsv
  analysis/selective-mirror-packages.tsv
  analysis/selective-mirror-urls.tsv

Python 3.5+; standard library only.
"""
from __future__ import print_function, unicode_literals

import argparse
import csv
import hashlib
import json
import os
import re
import sys
import time
from collections import OrderedDict, defaultdict

try:
    from urllib.parse import urlparse, unquote, urlunparse
except ImportError:  # pragma: no cover
    from urlparse import urlparse, urlunparse  # type: ignore
    from urllib import unquote  # type: ignore

HOPS = (
    'xenial-to-bionic',
    'bionic-to-focal',
    'focal-to-jammy',
    'jammy-to-noble',
)

ALLOWED_HOSTS = (
    'archive.ubuntu.com',
    'security.ubuntu.com',
    'old-releases.ubuntu.com',
)

POOL_RE = re.compile(r'/pool/([^/]+)/(.+\.deb)$')
DISTS_SUITE_RE = re.compile(r'/dists/([^/]+)/')
UPGRADER_RE = re.compile(
    r'/dists/([^/]+)/main/dist-upgrader-all/current/([^/]+\.tar\.gz(?:\.gpg)?)$'
)
KNOWN_COMPONENTS = ('main', 'restricted', 'universe', 'multiverse')
OFFICIAL_POOL_BASES = (
    'http://archive.ubuntu.com/ubuntu',
    'http://security.ubuntu.com/ubuntu',
    'http://old-releases.ubuntu.com/ubuntu',
)
EPOCH_IN_FILENAME_RE = re.compile(r'^(.+_)(\d+):(.+)$')

_LIB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib')
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
try:
    from distupgrade_source_compat import (  # noqa: E402
        UNRESOLVED_TARGET_POCKET,
        build_sha_to_suite_from_packages_indexes,
        count_packages_by_pocket,
        resolve_hop_suite,
        resolve_target_suite,
        allowed_target_suites,
    )
except ImportError:  # pragma: no cover
    from scripts.lib.distupgrade_source_compat import (  # type: ignore
        UNRESOLVED_TARGET_POCKET,
        build_sha_to_suite_from_packages_indexes,
        count_packages_by_pocket,
        resolve_hop_suite,
        resolve_target_suite,
        allowed_target_suites,
    )
try:
    from discovery_profiles import (  # noqa: E402
        aws_kernel_package_name,
        is_allowed_host,
        load_merged_hops,
        normalize_discovery_url,
        normalize_mirror_host,
        parse_discovery_root_args,
    )
except ImportError:  # pragma: no cover
    from scripts.lib.discovery_profiles import (  # type: ignore
        aws_kernel_package_name,
        is_allowed_host,
        load_merged_hops,
        normalize_discovery_url,
        normalize_mirror_host,
        parse_discovery_root_args,
    )


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def iso_now():
    return time.strftime('%Y-%m-%dT%H:%M:%S%z')


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def sha256_text(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def read_tsv(path):
    if not os.path.isfile(path):
        raise IOError('missing TSV: %s' % path)
    with open(path, 'r') as fh:
        return list(csv.DictReader(fh, delimiter='\t'))


def write_tsv(path, fieldnames, rows):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'w') as fh:
        writer = csv.DictWriter(
            fh, fieldnames=fieldnames, delimiter='\t', lineterminator='\n',
            extrasaction='ignore',
        )
        writer.writeheader()
        for row in rows:
            writer.writerow(row)
    os.replace(tmp, path)


def write_json(path, data):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'w') as fh:
        json.dump(data, fh, indent=2, sort_keys=False)
        fh.write('\n')
    os.replace(tmp, path)


def normalize_url(url):
    # Prefer discovery_profiles normalizer (EC2 regional → archive.ubuntu.com).
    return normalize_discovery_url(url)


def hop_series(hop):
    parts = hop.split('-to-')
    if len(parts) != 2:
        raise ValueError('bad hop name: %s' % hop)
    return parts[0], parts[1]


def pocket_from_suite(suite):
    if suite.endswith('-updates'):
        return 'updates'
    if suite.endswith('-security'):
        return 'security'
    if suite.endswith('-backports'):
        return 'backports'
    return 'base'


def series_from_suite(suite):
    for suffix in ('-updates', '-security', '-backports'):
        if suite.endswith(suffix):
            return suite[: -len(suffix)]
    return suite


def pool_path_from_url(url):
    if not url:
        return '', ''
    parsed = urlparse(url)
    path = unquote(parsed.path or '')
    idx = path.find('/pool/')
    if idx < 0:
        return '', ''
    rel = path[idx + 1:]  # pool/...
    m = POOL_RE.search(path)
    component = m.group(1) if m else ''
    return rel, component


def pool_prefix_for_source(source):
    source = unquote(source or '')
    if source.startswith('lib') and len(source) >= 4:
        return source[:4]
    return source[:1] if source else ''


def synthesize_pool_path(component, source, filename):
    source = unquote(source or '')
    filename = unquote(filename or '')
    if not component or not source or not filename:
        return ''
    first = pool_prefix_for_source(source)
    return 'pool/%s/%s/%s/%s' % (component, first, source, filename)


def filename_pool_variants(filename):
    """Return candidate pool basenames (epoch-stripped variants included)."""
    raw = filename or ''
    decoded = unquote(raw)
    variants = []
    for candidate in (decoded, raw):
        if candidate and candidate not in variants:
            variants.append(candidate)
    for candidate in list(variants):
        m = EPOCH_IN_FILENAME_RE.match(candidate)
        if m:
            stripped = '%s%s' % (m.group(1), m.group(3))
            if stripped not in variants:
                variants.append(stripped)
    return variants


def build_discovery_url_indexes(hops_data):
    """Index real discovery URLs by sha256 and by filename (read-only join)."""
    by_sha = {}
    by_filename = {}

    def consider(url, sha, filename):
        url = normalize_url(url or '')
        if not url or '/pool/' not in url:
            return
        host = urlparse(url).hostname or ''
        if host and host not in ALLOWED_HOSTS:
            return
        sha = (sha or '').strip().lower()
        if sha and sha not in by_sha:
            by_sha[sha] = url
        fn = unquote(filename or '')
        if not fn and url:
            fn = unquote(url.rsplit('/', 1)[-1])
        if fn and fn not in by_filename:
            by_filename[fn] = url
        # also index encoded basename when present
        if filename and filename not in by_filename:
            by_filename[filename] = url

    for hop_data in hops_data:
        for row in hop_data.get('packages') or []:
            consider(
                row.get('final_url') or row.get('original_url') or '',
                row.get('sha256'),
                row.get('filename'),
            )
        for row in hop_data.get('files') or []:
            consider(
                row.get('final_url') or row.get('original_url') or '',
                row.get('sha256'),
                row.get('filename'),
            )
        for row in hop_data.get('urls') or []:
            consider(
                row.get('final_url') or row.get('original_url') or '',
                row.get('sha256'),
                '',
            )
    return by_sha, by_filename


def head_content_length(url, timeout=20):
    """Return (ok, status, content_length) for a HEAD (GET fallback) probe."""
    try:
        from urllib.request import Request, urlopen
        from urllib.error import HTTPError, URLError
    except ImportError:  # pragma: no cover
        from urllib2 import Request, urlopen, HTTPError, URLError  # type: ignore

    class HeadRequest(Request):
        def get_method(self):
            return 'HEAD'

    headers = {'User-Agent': 'ubuntu-mirror-automation-plan/1.0'}
    for req_cls in (HeadRequest, Request):
        try:
            req = req_cls(url, headers=headers)
            resp = urlopen(req, timeout=timeout)
            try:
                status = getattr(resp, 'status', None)
                if status is None and hasattr(resp, 'code'):
                    status = resp.code
                status = int(status) if status is not None else 200
                cl = resp.headers.get('Content-Length')
                try:
                    cl_int = int(cl) if cl is not None else None
                except (TypeError, ValueError):
                    cl_int = None
                return status == 200, status, cl_int
            finally:
                try:
                    resp.close()
                except Exception:
                    pass
        except HTTPError as exc:
            status = int(getattr(exc, 'code', 0) or 0)
            if status == 405 and req_cls is HeadRequest:
                continue
            return False, status, None
        except (URLError, OSError, ValueError):
            return False, 0, None
    return False, 0, None


def probe_official_pool_path(source_package, filename, size_bytes, package_name=''):
    """Resolve pool path via official hosts when discovery has no URL.

    Tries known components and filename variants. Accepts only HTTP 200 with
    Content-Length == expected size. Never defaults to main.
    """
    sources = []
    for src in (source_package, package_name):
        src = unquote(src or '')
        if src and src not in sources:
            sources.append(src)
    if not sources:
        return '', '', ''

    try:
        expected_size = int(size_bytes)
    except (TypeError, ValueError):
        return '', '', ''
    if expected_size <= 0:
        return '', '', ''

    for source in sources:
        for component in KNOWN_COMPONENTS:
            for fn in filename_pool_variants(filename):
                rel = synthesize_pool_path(component, source, fn)
                if not rel:
                    continue
                for base in OFFICIAL_POOL_BASES:
                    url = normalize_url('%s/%s' % (base, rel))
                    ok, _status, cl = head_content_length(url)
                    if ok and cl == expected_size:
                        return rel, component, url
    return '', '', ''


def prefer_url_component(existing_rec, url, rel_pool, component):
    """Upgrade merged deb record when a real pool URL is newly available."""
    if not url or not rel_pool or not component:
        return
    old_url = existing_rec.get('original_url') or ''
    old_rel, old_comp = pool_path_from_url(old_url)
    new_from_url = bool(pool_path_from_url(url)[0])
    old_from_url = bool(old_rel)
    if new_from_url and not old_from_url:
        existing_rec['original_url'] = url
        existing_rec['relative_pool_path'] = rel_pool
        existing_rec['component'] = component
        existing_rec['original_component'] = component
        return
    if new_from_url and old_from_url and old_comp and component and old_comp != component:
        # Conflict: keep first URL-derived path; caller records error separately.
        return
    if not existing_rec.get('relative_pool_path') and rel_pool:
        existing_rec['relative_pool_path'] = rel_pool
    if not existing_rec.get('component') and component:
        existing_rec['component'] = component
        existing_rec['original_component'] = component
    if not old_url and url:
        existing_rec['original_url'] = url


def classify_url(url):
    if not url:
        return 'empty'
    path = urlparse(url).path or ''
    if path.endswith('.deb') or '/pool/' in path:
        return 'pool_deb'
    if '/by-hash/' in path:
        return 'by_hash'
    if UPGRADER_RE.search(path):
        if path.endswith('.gpg'):
            return 'release_upgrader_gpg'
        return 'release_upgrader_tarball'
    if path.endswith('/InRelease') or path.endswith('/Release') or path.endswith('/Release.gpg'):
        return 'repository_metadata'
    if 'meta-release' in path:
        return 'meta_release'
    return 'unsupported'


def seed_path_for_rel(seed_root, rel_pool_path):
    if not seed_root or not rel_pool_path:
        return ''
    return os.path.join(seed_root, rel_pool_path)


def verify_seed_file(path, expected_sha256, expected_size, verify_checksum=False):
    """Return True if seed file looks reusable.

    Default is size+existence (fast on multi-TB seeds). Pass verify_checksum=True
    to also compare SHA256 (slow).
    """
    if not path or not os.path.isfile(path):
        return False
    try:
        if expected_size is not None and os.path.getsize(path) != int(expected_size):
            return False
    except (OSError, ValueError, TypeError):
        return False
    if not verify_checksum:
        return True
    try:
        return file_sha256(path) == expected_sha256
    except OSError:
        return False


def load_hop(discovery_root, hop, profile='generic'):
    """Backward-compatible single-root hop loader (adds profile provenance)."""
    from discovery_profiles import load_hop_from_root
    return load_hop_from_root(discovery_root, hop, profile=profile)


def _coerce_discovery_roots(discovery_root, discovery_roots=None):
    """Accept legacy single path or multi-profile OrderedDict/list."""
    if discovery_roots:
        if isinstance(discovery_roots, dict):
            return OrderedDict(
                (k, os.path.abspath(v)) for k, v in discovery_roots.items()
            )
        return parse_discovery_root_args(list(discovery_roots))
    if isinstance(discovery_root, dict):
        return OrderedDict(
            (k, os.path.abspath(v)) for k, v in discovery_root.items()
        )
    if not discovery_root:
        raise ValueError('discovery_root required')
    return OrderedDict([('generic', os.path.abspath(discovery_root))])


def index_files_by_filename(files):
    by_name = {}
    for row in files:
        name = row.get('filename') or ''
        if name and name not in by_name:
            by_name[name] = row
        # also index decoded name
        decoded = unquote(name)
        if decoded and decoded not in by_name:
            by_name[decoded] = row
    return by_name


def suites_from_urls(url_rows):
    suites = set()
    for row in url_rows:
        for key in ('original_url', 'final_url'):
            url = normalize_url(row.get(key) or '')
            m = DISTS_SUITE_RE.search(urlparse(url).path or '')
            if m:
                suites.add(m.group(1))
    return sorted(suites)


def build_plan(discovery_root, seed_root, profile_name='offline-upgrade-selective',
               verify_seed_checksums=False, resolve_missing_pool_paths=True,
               pocket_index_root='', discovery_roots=None):
    errors = []
    warnings = []
    roots = _coerce_discovery_roots(discovery_root, discovery_roots=discovery_roots)
    try:
        hops_data = load_merged_hops(roots)
    except (IOError, ValueError) as exc:
        errors.append(str(exc))
        hops_data = []

    if len(hops_data) != 4:
        errors.append('expected 4 hops, found %d' % len(hops_data))

    package_rows_out = []
    file_rows_out = []
    url_rows_out = []

    # unique .deb by sha256
    debs = OrderedDict()  # sha256 -> record
    hop_package_keys = defaultdict(set)  # hop -> set((pkg, arch, version))
    version_conflicts = []  # same hop, same pkg+arch, different versions
    unsupported_urls = []
    unresolved_urls = []
    unresolved_target_pockets = []
    component_conflicts = []
    pool_probe_cache = {}  # (source, filename, size) -> (rel, component, url)
    aws_kernel_packages = []

    # Cross-hop join: prefer real discovery pool URLs over synthesized paths.
    url_by_sha, url_by_filename = build_discovery_url_indexes(hops_data)

    # Optional official/seed Packages indexes for sha256 → suite provenance.
    sha_to_suite_global = {}
    if pocket_index_root and os.path.isdir(pocket_index_root):
        # Prefer security/updates/backports before base (setdefault keeps first).
        for series in ('xenial', 'bionic', 'focal', 'jammy', 'noble'):
            scan = [
                '%s-security' % series,
                '%s-updates' % series,
                '%s-backports' % series,
                series,
            ]
            for sha, suite in build_sha_to_suite_from_packages_indexes(
                pocket_index_root, scan,
            ).items():
                sha_to_suite_global.setdefault(sha, suite)

    upgrader_files = []
    meta_release_required = True  # always required by profile; not in discovery capture

    total_unresolved_packages = 0
    total_unresolved_files = 0

    for hop_data in hops_data:
        hop = hop_data['hop']
        from_series, to_series = hop_series(hop)
        files_by_name = index_files_by_filename(hop_data['files'])
        hop_suites = suites_from_urls(hop_data['urls'])
        if not hop_suites:
            # fallback structural suites
            hop_suites = []
            for series in (from_series, to_series):
                hop_suites.extend([
                    series,
                    '%s-updates' % series,
                    '%s-security' % series,
                    '%s-backports' % series,
                ])

        total_unresolved_packages += len(hop_data['unresolved_packages'])
        total_unresolved_files += len(hop_data['unresolved_files'])

        # Conflict = same (package, version, arch) with different sha256.
        # Multiple versions of one package in a hop are expected during upgrades.
        seen_sha = {}
        multi_version = defaultdict(set)
        for prow in hop_data['packages']:
            pkg = prow.get('package') or ''
            arch = prow.get('architecture') or ''
            ver = unquote(prow.get('version') or '')
            sha_early = (prow.get('sha256') or '').strip().lower()
            pva = (pkg, ver, arch)
            if pva in seen_sha and seen_sha[pva] != sha_early and sha_early:
                version_conflicts.append(OrderedDict([
                    ('hop', hop),
                    ('package', pkg),
                    ('architecture', arch),
                    ('version', ver),
                    ('sha256s', sorted({seen_sha[pva], sha_early})),
                    ('reason', 'same_version_different_sha256'),
                ]))
            elif sha_early:
                seen_sha[pva] = sha_early
            multi_version[(pkg, arch)].add(ver)

            filename = prow.get('filename') or ''
            source = unquote(prow.get('source_package') or pkg)
            url = normalize_url(prow.get('final_url') or prow.get('original_url') or '')
            file_row = files_by_name.get(filename) or files_by_name.get(unquote(filename))
            if not url and file_row:
                url = normalize_url(file_row.get('final_url') or file_row.get('original_url') or '')

            # Priority 1-2: discovery URL / Filename pool path (row, file row, sha/filename join)
            if not url and sha_early and sha_early in url_by_sha:
                url = url_by_sha[sha_early]
            if not url:
                for fn_key in filename_pool_variants(filename):
                    if fn_key in url_by_filename:
                        url = url_by_filename[fn_key]
                        break

            rel_pool, component = pool_path_from_url(url)
            metadata_component = (prow.get('component') or '').strip()
            if metadata_component and component and metadata_component != component:
                component_conflicts.append(OrderedDict([
                    ('hop', hop),
                    ('package', pkg),
                    ('filename', unquote(filename)),
                    ('url_component', component),
                    ('metadata_component', metadata_component),
                    ('url', url),
                    ('reason', 'url_vs_metadata_component_conflict'),
                ]))
            if not component:
                component = metadata_component
            if not component and file_row:
                _, component = pool_path_from_url(
                    normalize_url(file_row.get('final_url') or file_row.get('original_url') or '')
                )

            try:
                size_bytes = int(prow.get('size_bytes') or '0')
            except ValueError:
                size_bytes = 0
            sha = (prow.get('sha256') or '').strip().lower()
            if not sha or size_bytes <= 0:
                errors.append('package missing size/sha256: %s/%s' % (hop, pkg))
                continue

            # Priority 3/4: official pool path probe — never default component=main.
            if (not component or not rel_pool) and resolve_missing_pool_paths:
                cache_key = (source, unquote(filename), size_bytes)
                if cache_key not in pool_probe_cache:
                    pool_probe_cache[cache_key] = probe_official_pool_path(
                        source, filename, size_bytes, package_name=pkg,
                    )
                probed_rel, probed_comp, probed_url = pool_probe_cache[cache_key]
                if probed_rel and probed_comp:
                    if not rel_pool:
                        rel_pool = probed_rel
                    if not component:
                        component = probed_comp
                    if not url:
                        url = probed_url
                    warnings.append(
                        'resolved pool path via official HEAD probe for %s/%s → %s'
                        % (hop, unquote(filename), probed_comp)
                    )

            if not component or not rel_pool:
                unresolved_urls.append(OrderedDict([
                    ('hop', hop),
                    ('package', pkg),
                    ('filename', unquote(filename)),
                    ('sha256', sha),
                    ('reason', 'component_or_pool_path_unresolved'),
                ]))
                errors.append(
                    'component/pool path unresolved for %s/%s (no discovery URL; '
                    'refusing default component=main)' % (hop, unquote(filename) or pkg)
                )
                continue

            if not url and rel_pool:
                url = normalize_url(
                    'http://archive.ubuntu.com/ubuntu/%s' % rel_pool
                )

            if arch not in ('amd64', 'all'):
                errors.append('unsupported architecture %s for %s/%s' % (arch, hop, pkg))
                continue

            host = normalize_mirror_host(urlparse(url).hostname or '')
            if url and host and not is_allowed_host(host):
                unsupported_urls.append(url)
                continue

            if aws_kernel_package_name(pkg):
                aws_kernel_packages.append(OrderedDict([
                    ('hop', hop),
                    ('package', pkg),
                    ('version', ver),
                    ('architecture', arch),
                    ('sha256', sha),
                    ('profile', prow.get('profile') or ''),
                    ('provenance', prow.get('provenance') or ''),
                ]))

            suite = ''
            pocket = ''
            resolved = resolve_hop_suite(
                {
                    'suite': prow.get('suite') or '',
                    'original_url': url,
                    'final_url': prow.get('final_url') or url,
                    'repository_host': host,
                    'sha256': sha,
                    'version': ver,
                    'filename': filename,
                },
                from_series,
                to_series,
                sha_to_suite=sha_to_suite_global,
            )
            if resolved.get('error') == UNRESOLVED_TARGET_POCKET:
                unresolved_target_pockets.append(OrderedDict([
                    ('hop', hop),
                    ('package', pkg),
                    ('version', ver),
                    ('architecture', arch),
                    ('sha256', sha),
                    ('filename', unquote(filename)),
                    ('reason', UNRESOLVED_TARGET_POCKET),
                ]))
                errors.append(
                    '%s for %s/%s (refusing auto-assign to %s)'
                    % (UNRESOLVED_TARGET_POCKET, hop, pkg, to_series)
                )
                continue
            # Pre-upgrade source-series residue: never clone into target indexes.
            if resolved.get('role') == 'source_series':
                warnings.append(
                    'omit source-series package %s/%s %s (suite=%s via %s)'
                    % (hop, pkg, ver, resolved.get('source_suite'),
                       resolved.get('resolved_from'))
                )
                continue
            suite = resolved['source_suite']
            pocket = resolved['source_pocket']

            seed_path = seed_path_for_rel(seed_root, rel_pool)
            reusable = verify_seed_file(
                seed_path, sha, size_bytes, verify_checksum=verify_seed_checksums,
            )
            if reusable:
                acquisition = 'existing_full_mirror'
            elif url and rel_pool:
                acquisition = 'downloaded'
            else:
                acquisition = 'unresolved'
            if acquisition == 'unresolved':
                unresolved_urls.append(OrderedDict([
                    ('hop', hop),
                    ('package', pkg),
                    ('filename', filename),
                    ('reason', 'no_url_and_not_in_seed'),
                ]))

            rec = debs.get(sha)
            if rec is None:
                rec = OrderedDict([
                    ('sha256', sha),
                    ('size_bytes', size_bytes),
                    ('relative_pool_path', rel_pool),
                    ('filename', unquote(filename)),
                    ('package', pkg),
                    ('version', ver),
                    ('architecture', arch),
                    ('component', component),
                    ('original_url', url),
                    ('original_suite', suite),
                    ('original_pocket', pocket),
                    ('original_component', component),
                    ('source_hops', []),
                    ('acquisition_source', acquisition),
                    ('seed_local_path', seed_path if reusable else ''),
                    ('reusable_from_seed', reusable),
                ])
                debs[sha] = rec
            else:
                if rec['size_bytes'] != size_bytes:
                    errors.append('size conflict for sha256 %s' % sha)
                # prefer reusable if any hop can reuse
                if reusable and not rec['reusable_from_seed']:
                    rec['reusable_from_seed'] = True
                    rec['acquisition_source'] = 'existing_full_mirror'
                    rec['seed_local_path'] = seed_path
                # Prefer real pool-URL component/path over earlier synthesized guesses.
                old_rel, old_comp = pool_path_from_url(rec.get('original_url') or '')
                new_rel, new_comp = pool_path_from_url(url)
                if new_comp and old_comp and new_comp != old_comp:
                    component_conflicts.append(OrderedDict([
                        ('hop', hop),
                        ('package', pkg),
                        ('sha256', sha),
                        ('existing_component', old_comp),
                        ('new_component', new_comp),
                        ('existing_url', rec.get('original_url') or ''),
                        ('new_url', url),
                        ('reason', 'sha256_merge_component_conflict'),
                    ]))
                prefer_url_component(rec, url, rel_pool, component)
                if url and rec.get('acquisition_source') == 'unresolved':
                    rec['acquisition_source'] = (
                        'existing_full_mirror' if rec.get('reusable_from_seed')
                        else 'downloaded'
                    )
                if rel_pool and not rec['relative_pool_path']:
                    rec['relative_pool_path'] = rel_pool

            if hop not in rec['source_hops']:
                rec['source_hops'].append(hop)

            hop_package_keys[hop].add((pkg, arch, ver))
            package_rows_out.append(OrderedDict([
                ('hop', hop),
                ('package', pkg),
                ('version', ver),
                ('architecture', arch),
                ('component', rec.get('component') or component),
                ('suite', suite),
                ('pocket', pocket),
                ('source_suite', suite),
                ('source_pocket', pocket),
                ('source_url', rec.get('original_url') or url),
                ('filename', unquote(filename)),
                ('relative_pool_path', rec.get('relative_pool_path') or rel_pool),
                ('size_bytes', size_bytes),
                ('sha256', sha),
                ('original_url', rec.get('original_url') or url),
                ('acquisition_source', rec['acquisition_source']),
                ('seed_local_path', rec.get('seed_local_path', '')),
                ('profile', prow.get('profile') or ''),
                ('provenance', prow.get('provenance') or ('profile=%s' % (
                    prow.get('_profile') or 'generic'))),
            ]))

        # files / urls manifests (normalized)
        for frow in hop_data['files']:
            url = normalize_url(frow.get('final_url') or frow.get('original_url') or '')
            utype = classify_url(url) if url else (frow.get('file_type') or 'unknown')
            if utype == 'unsupported':
                unsupported_urls.append(url)
            try:
                size_bytes = int(frow.get('size_bytes') or '0')
            except ValueError:
                size_bytes = 0
            file_rows_out.append(OrderedDict([
                ('hop', hop),
                ('file_type', frow.get('file_type') or utype),
                ('filename', frow.get('filename') or ''),
                ('original_url', url),
                ('size_bytes', size_bytes),
                ('sha256', (frow.get('sha256') or '').lower()),
                ('url_class', utype),
                ('profile', frow.get('profile') or ''),
                ('provenance', frow.get('provenance') or ''),
            ]))
            if utype in ('release_upgrader_tarball', 'release_upgrader_gpg') or (
                frow.get('file_type') == 'release_upgrader'
            ):
                upgrader_files.append(OrderedDict([
                    ('hop', hop),
                    ('filename', frow.get('filename') or ''),
                    ('url', url),
                    ('sha256', (frow.get('sha256') or '').lower()),
                    ('size_bytes', size_bytes),
                ]))

        for urow in hop_data['urls']:
            url = normalize_url(urow.get('final_url') or urow.get('original_url') or '')
            utype = classify_url(url)
            if utype == 'unsupported':
                unsupported_urls.append(url)
            if utype == 'empty':
                unresolved_urls.append(OrderedDict([
                    ('hop', hop), ('url', ''), ('reason', 'empty_url')
                ]))
            host = normalize_mirror_host(urlparse(url).hostname or '')
            if url and host and not is_allowed_host(host) and utype != 'by_hash':
                # by-hash ignored for selective; other hosts unsupported
                if utype not in ('by_hash', 'repository_metadata'):
                    unsupported_urls.append(url)
            try:
                size_bytes = int(urow.get('size_bytes') or '0')
            except ValueError:
                size_bytes = 0
            url_rows_out.append(OrderedDict([
                ('hop', hop),
                ('original_url', url),
                ('http_status', urow.get('http_status') or ''),
                ('size_bytes', size_bytes),
                ('sha256', (urow.get('sha256') or '').lower()),
                ('url_class', utype),
                ('include_in_selective', utype in (
                    'pool_deb', 'release_upgrader_tarball', 'release_upgrader_gpg',
                    'meta_release',
                )),
                ('profile', urow.get('profile') or ''),
                ('provenance', urow.get('provenance') or ''),
            ]))

        hop_data['suites'] = hop_suites
        hop_data['from_series'] = from_series
        hop_data['to_series'] = to_series
        hop_data['multi_version_packages'] = sum(
            1 for _k, vers in multi_version.items() if len(vers) > 1
        )

    # Deduplicate unsupported
    unsupported_urls = sorted(set(u for u in unsupported_urls if u))

    # For selective plan, by-hash and official InRelease are intentionally excluded
    # (regenerated locally). Treat them as ignored, not unsupported.
    ignored_classes = {'by_hash', 'repository_metadata'}

    reusable_bytes = sum(
        r['size_bytes'] for r in debs.values() if r['reusable_from_seed']
    )
    download_bytes = sum(
        r['size_bytes'] for r in debs.values()
        if not r['reusable_from_seed'] and r['original_url']
    )
    unresolved_deb_bytes = sum(
        r['size_bytes'] for r in debs.values()
        if r['acquisition_source'] == 'unresolved'
    )
    unique_deb_bytes = sum(r['size_bytes'] for r in debs.values())

    # metadata estimate: Packages/Release/upgraders ~ small; use upgrader sizes + 32MiB headroom
    upgrader_bytes = 0
    seen_up_sha = set()
    for u in upgrader_files:
        if u['sha256'] and u['sha256'] not in seen_up_sha:
            seen_up_sha.add(u['sha256'])
            upgrader_bytes += int(u['size_bytes'] or 0)
    metadata_estimate = upgrader_bytes + (32 * 1024 * 1024)

    unresolved_deb_count = sum(
        1 for r in debs.values() if r['acquisition_source'] == 'unresolved'
    )

    # Validation gates
    if unresolved_target_pockets:
        errors.append(
            '%s: %d packages (blank suite/pocket never auto-assigned to target base)'
            % (UNRESOLVED_TARGET_POCKET, len(unresolved_target_pockets))
        )
    if total_unresolved_packages != 0:
        errors.append('unresolved packages != 0 (%d)' % total_unresolved_packages)
    if total_unresolved_files != 0:
        errors.append('unresolved files != 0 (%d)' % total_unresolved_files)
    if version_conflicts:
        errors.append('package version conflicts within hop: %d' % len(version_conflicts))
    if component_conflicts:
        errors.append('component/path conflicts: %d' % len(component_conflicts))
    if unresolved_deb_count:
        errors.append('unresolved .deb payloads: %d' % unresolved_deb_count)
    # unsupported after filtering ignored
    real_unsupported = []
    for u in unsupported_urls:
        utype = classify_url(u)
        if utype in ignored_classes or utype == 'pool_deb':
            continue
        host = normalize_mirror_host(urlparse(u).hostname or '')
        if not is_allowed_host(host):
            real_unsupported.append(u)
    if real_unsupported:
        errors.append('unsupported URLs: %d' % len(real_unsupported))
    if len(seen_up_sha) < 8:
        # 4 tarball + 4 gpg expected
        warnings.append('expected 8 upgrader artifacts (4 tar + 4 gpg), found %d unique' % len(seen_up_sha))
    if not meta_release_required:
        errors.append('meta-release required')

    validation = 'PASS' if not errors else 'FAIL'

    hop_summaries = OrderedDict()
    for hop_data in hops_data:
        hop = hop_data['hop']
        hop_debs = [r for r in debs.values() if hop in r['source_hops']]
        hop_summaries[hop] = OrderedDict([
            ('from_series', hop_data['from_series']),
            ('to_series', hop_data['to_series']),
            ('suites', hop_data['suites']),
            ('profiles', hop_data.get('profiles') or []),
            ('package_rows', len(hop_data['packages'])),
            ('file_rows', len(hop_data['files'])),
            ('url_rows', len(hop_data['urls'])),
            ('unique_debs', len(hop_debs)),
            ('unique_deb_bytes', sum(r['size_bytes'] for r in hop_debs)),
            ('unresolved_packages', len(hop_data['unresolved_packages'])),
            ('unresolved_files', len(hop_data['unresolved_files'])),
        ])

    # discovery artifact checksum (manifest files only) across all profiles
    checksum_paths = []
    for profile, root in roots.items():
        for hop in HOPS:
            for name in (
                'required-packages.tsv', 'required-files.tsv', 'required-urls.tsv',
                'export-summary.json', 'checksums.sha256', 'validation.txt',
                'evidence.json',
            ):
                p = os.path.join(root, hop, name)
                if os.path.isfile(p):
                    checksum_paths.append('%s:%s' % (profile, p))
    checksum_paths.sort()
    h = hashlib.sha256()
    for labeled in checksum_paths:
        profile, p = labeled.split(':', 1)
        h.update(profile.encode('utf-8'))
        h.update(b'\0')
        h.update(p.encode('utf-8'))
        h.update(b'\0')
        h.update(file_sha256(p).encode('utf-8'))
        h.update(b'\0')
    discovery_checksum = h.hexdigest()

    primary_root = next(iter(roots.values()))
    plan = OrderedDict([
        ('schema_version', 1),
        ('profile_name', profile_name),
        ('selection_mode', 'discovery_exact'),
        ('repository_layout', 'hop_separated_source_target_suites'),
        ('metadata_generator', 'apt-ftparchive'),
        ('generated_at', iso_now()),
        ('discovery_root', os.path.abspath(primary_root)),
        ('discovery_roots', OrderedDict(
            (k, os.path.abspath(v)) for k, v in roots.items()
        )),
        ('discovery_profiles', list(roots.keys())),
        ('full_mirror_seed_root', os.path.abspath(seed_root) if seed_root else ''),
        ('discovery_artifact_checksum', discovery_checksum),
        ('validation_result', validation),
        ('errors', errors),
        ('warnings', warnings[:50]),
        ('warning_count', len(warnings)),
        ('hops', list(HOPS)),
        ('hop_count', len(hops_data)),
        ('counts', OrderedDict([
            ('unique_packages_by_name_arch_version', len({
                (r['package'], r['architecture'], r['version']) for r in debs.values()
            })),
            ('unique_deb_sha256', len(debs)),
            ('unique_package_rows', len(package_rows_out)),
            ('unique_urls_normalized', len({r['original_url'] for r in url_rows_out if r['original_url']})),
            ('package_version_conflicts', len(version_conflicts)),
            ('multi_version_package_keys', sum(
                int(h.get('multi_version_packages') or 0) for h in hops_data
            )),
            ('unresolved_packages', total_unresolved_packages),
            ('unresolved_files', total_unresolved_files),
            ('unresolved_deb_payloads', unresolved_deb_count),
            ('unresolved_target_pockets', len(unresolved_target_pockets)),
            ('unsupported_urls', len(real_unsupported)),
            ('upgrader_artifacts', len(seen_up_sha)),
            ('meta_release_required', True),
            ('aws_kernel_package_rows', len(aws_kernel_packages)),
        ])),
        ('aws_kernel_packages_sample', aws_kernel_packages[:40]),
        ('target_pocket_provenance', count_packages_by_pocket(package_rows_out, 'bionic')),
        ('unresolved_target_pocket_rows', unresolved_target_pockets[:50]),
        ('sizes', OrderedDict([
            ('unique_deb_bytes', unique_deb_bytes),
            ('reusable_from_seed_bytes', reusable_bytes),
            ('download_bytes', download_bytes),
            ('unresolved_deb_bytes', unresolved_deb_bytes),
            ('upgrader_bytes', upgrader_bytes),
            ('metadata_estimate_bytes', metadata_estimate),
            ('selective_mirror_estimate_bytes', unique_deb_bytes + metadata_estimate),
        ])),
        ('hop_summaries', hop_summaries),
        ('version_conflicts', version_conflicts),
        ('component_conflicts', component_conflicts),
        ('unsupported_urls_sample', real_unsupported[:20]),
        ('upgraders', upgrader_files),
        ('debs', list(debs.values())),
        ('omit_by_default', [
            'Translation', 'DEP-11', 'CNF', 'Contents', 'Sources',
            'i386', 'deb-src', 'Acquire-By-Hash', 'full_official_by_hash',
        ]),
    ])

    # Semantic plan identity excludes volatile/local-path diagnostics:
    # generated_at, discovery_root(s), seed_root checkout locations.
    stable = dict(plan)
    for volatile in (
        'generated_at',
        'discovery_root',
        'discovery_roots',
        'full_mirror_seed_root',
    ):
        stable.pop(volatile, None)
    plan['plan_checksum'] = sha256_text(json.dumps(stable, sort_keys=True, default=str))

    return plan, package_rows_out, file_rows_out, url_rows_out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--discovery-root',
        action='append',
        default=None,
        help=(
            'Discovery root. Repeatable. Forms: PATH (profile=generic) or '
            'profile=/path (e.g. aws=/path/to/aws-discovery). '
            'Multiple roots are unioned with SHA256/URL/pool-path dedup.'
        ),
    )
    parser.add_argument(
        '--output-dir',
        default='',
        help='defaults to <first-discovery-root>/analysis',
    )
    parser.add_argument(
        '--seed-root',
        default='/var/spool/apt-mirror/mirror/archive.ubuntu.com/ubuntu',
    )
    parser.add_argument('--profile-name', default='offline-upgrade-selective')
    parser.add_argument('--skip-seed-probe', action='store_true',
                        help='Do not probe seed mirror (reuse=0)')
    parser.add_argument('--verify-seed-checksums', action='store_true',
                        help='SHA256-verify seed hits (slow on large mirrors)')
    parser.add_argument(
        '--no-resolve-missing-pool-paths',
        action='store_true',
        help='Do not HEAD-probe official archives for URL-less apt_archives rows',
    )
    parser.add_argument(
        '--pocket-index-root',
        default='',
        help='Ubuntu archive root with dists/*/…/Packages for sha256→suite provenance',
    )
    args = parser.parse_args(argv)

    default_root = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'artifacts', 'upgrade-discovery',
    )
    root_args = args.discovery_root or [default_root]
    roots = parse_discovery_root_args(root_args)
    primary_root = next(iter(roots.values()))
    out_dir = args.output_dir or os.path.join(primary_root, 'analysis')
    seed_root = '' if args.skip_seed_probe else args.seed_root

    plan, packages, files, urls = build_plan(
        primary_root, seed_root, profile_name=args.profile_name,
        verify_seed_checksums=args.verify_seed_checksums,
        resolve_missing_pool_paths=not args.no_resolve_missing_pool_paths,
        pocket_index_root=args.pocket_index_root,
        discovery_roots=roots,
    )

    plan_path = os.path.join(out_dir, 'selective-mirror-plan.json')
    # Write a lean plan for operators (full deb list kept) plus TSV sidecars
    write_json(plan_path, plan)
    write_tsv(
        os.path.join(out_dir, 'selective-mirror-packages.tsv'),
        [
            'hop', 'package', 'version', 'architecture', 'component', 'suite',
            'pocket', 'filename', 'relative_pool_path', 'size_bytes', 'sha256',
            'original_url', 'acquisition_source', 'seed_local_path',
            'profile', 'provenance',
        ],
        packages,
    )
    write_tsv(
        os.path.join(out_dir, 'selective-mirror-files.tsv'),
        [
            'hop', 'file_type', 'filename', 'original_url', 'size_bytes',
            'sha256', 'url_class', 'profile', 'provenance',
        ],
        files,
    )
    write_tsv(
        os.path.join(out_dir, 'selective-mirror-urls.tsv'),
        [
            'hop', 'original_url', 'http_status', 'size_bytes', 'sha256',
            'url_class', 'include_in_selective', 'profile', 'provenance',
        ],
        urls,
    )

    print('validation_result=%s' % plan['validation_result'])
    print('discovery_profiles=%s' % ','.join(plan.get('discovery_profiles') or []))
    print('unique_deb_sha256=%d' % plan['counts']['unique_deb_sha256'])
    print('unique_urls=%d' % plan['counts']['unique_urls_normalized'])
    print('package_version_conflicts=%d' % plan['counts']['package_version_conflicts'])
    print('aws_kernel_package_rows=%d' % plan['counts'].get('aws_kernel_package_rows', 0))
    print('reusable_from_seed_bytes=%d' % plan['sizes']['reusable_from_seed_bytes'])
    print('download_bytes=%d' % plan['sizes']['download_bytes'])
    print('selective_mirror_estimate_bytes=%d' % plan['sizes']['selective_mirror_estimate_bytes'])
    print('plan=%s' % plan_path)

    for err in plan['errors']:
        eprint('ERROR: %s' % err)
    return 0 if plan['validation_result'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
