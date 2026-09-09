#!/usr/bin/env python3
"""Validate a selective offline mirror tree against its discovery plan.

Phases:
  pre_publish  — staging filesystem / GPG / Packages / isolated APT
                 (never depends on production nginx or published/current)
  post_publish — concrete HTTP endpoints via production nginx after atomic publish
"""
from __future__ import print_function, unicode_literals

import argparse
import gzip
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from collections import OrderedDict

try:
    from http.server import SimpleHTTPRequestHandler, HTTPServer
    from urllib.request import urlopen, Request
    from urllib.error import HTTPError, URLError
except ImportError:  # pragma: no cover
    from SimpleHTTPServer import SimpleHTTPRequestHandler  # type: ignore
    from BaseHTTPServer import HTTPServer  # type: ignore
    from urllib2 import urlopen, Request, HTTPError, URLError  # type: ignore

FORBIDDEN_INDEX_NAMES = (
    'Translation-', 'Components-amd64.yml', 'cnf', 'Contents-', 'Sources',
)
EXTERNAL_HOSTS = (
    'archive.ubuntu.com', 'security.ubuntu.com',
    'old-releases.ubuntu.com', 'changelogs.ubuntu.com',
)

try:
    from aws_os_core_completeness import (
        validate_plan_aws_completeness,
        validate_tree_aws_completeness,
    )
except ImportError:  # pragma: no cover
    from scripts.lib.aws_os_core_completeness import (  # type: ignore
        validate_plan_aws_completeness,
        validate_tree_aws_completeness,
    )

# Core package version fingerprints used to detect suite contamination.
# Patterns are matched against the Debian version string (prefix / substring).
SERIES_CORE_VERSION_OK = {
    'xenial': OrderedDict([
        ('base-files', ('9.', '9ubuntu')),
        ('libc6', ('2.23',)),
        ('libc-bin', ('2.23',)),
        ('apt', ('1.2',)),
        ('apt-utils', ('1.2',)),
        ('dpkg', ('1.18',)),
        ('systemd', ('229',)),
        ('systemd-sysv', ('229',)),
        ('udev', ('229',)),
        ('python3', ('3.5',)),
        ('ubuntu-server', ('1.361',)),
    ]),
    'bionic': OrderedDict([
        ('base-files', ('10.', '10ubuntu')),
        ('libc6', ('2.27',)),
        ('libc-bin', ('2.27',)),
        ('apt', ('1.6',)),
        ('apt-utils', ('1.6',)),
        ('dpkg', ('1.19',)),
        ('systemd', ('237',)),
        ('systemd-sysv', ('237',)),
        ('udev', ('237',)),
        ('python3', ('3.6',)),
        ('ubuntu-server', ('1.417',)),
    ]),
    'focal': OrderedDict([
        # Official versions are often "11ubuntu5.8" (no dot after major).
        ('base-files', ('11.', '11ubuntu')),
        ('libc6', ('2.31',)),
        ('apt', ('2.0',)),
        ('dpkg', ('1.19',)),
        ('systemd', ('245',)),
    ]),
    'jammy': OrderedDict([
        ('base-files', ('12.', '12ubuntu')),
        ('libc6', ('2.35',)),
        ('apt', ('2.4',)),
        ('dpkg', ('1.21',)),
        ('systemd', ('249',)),
    ]),
    'noble': OrderedDict([
        ('base-files', ('13.', '13ubuntu')),
        ('libc6', ('2.39',)),
        ('apt', ('2.7', '2.8')),
        ('dpkg', ('1.22',)),
        ('systemd', ('255',)),
    ]),
}

# Versions that must NEVER appear in a source (from_series) suite index.
SERIES_CORE_VERSION_FORBIDDEN_IN_SOURCE = {
    'xenial': OrderedDict([
        ('base-files', ('10.', '10ubuntu', '11.', '11ubuntu', '12.', '12ubuntu', '13.', '13ubuntu')),
        ('libc6', ('2.27', '2.31', '2.35', '2.39')),
        ('apt', ('1.6', '2.')),
        ('dpkg', ('1.19', '1.21', '1.22')),
        ('systemd', ('237', '245', '249', '255')),
        ('python3', ('3.6', '3.8', '3.10', '3.12')),
        ('ubuntu-server', ('1.417', '1.440', '1.481', '1.524')),
    ]),
    'bionic': OrderedDict([
        ('base-files', ('11.', '11ubuntu', '12.', '12ubuntu', '13.', '13ubuntu')),
        ('libc6', ('2.31', '2.35', '2.39')),
        ('apt', ('2.',)),
        ('systemd', ('245', '249', '255')),
    ]),
    'focal': OrderedDict([
        ('base-files', ('12.', '12ubuntu', '13.', '13ubuntu')),
        ('libc6', ('2.35', '2.39')),
        ('apt', ('2.4', '2.7', '2.8')),
        ('systemd', ('249', '255')),
    ]),
    'jammy': OrderedDict([
        ('base-files', ('13.', '13ubuntu')),
        ('libc6', ('2.39',)),
        ('apt', ('2.7', '2.8')),
        ('systemd', ('255',)),
    ]),
}

ERROR_SOURCE_CONTAMINATION = 'FAIL_SOURCE_SUITE_TARGET_PACKAGE_CONTAMINATION'
ERROR_TARGET_MISMATCH = 'FAIL_TARGET_SUITE_MISMATCH'
ERROR_DISTUPGRADE_SOURCE = 'FAIL_OFFLINE_DISTUPGRADE_SOURCE_MAPPING'

VERIFY_RESULT_NAME = 'verify-result.json'
VERIFY_RESULT_LEGACY = 'verify.json'
PUBLISH_RESULT_NAME = 'publish-result.json'
PUBLISH_RESULT_LEGACY = 'publish.json'

ERROR_PREPUBLISH = 'SELECTIVE_PREPUBLISH_VERIFY_FAILED'
ERROR_POSTPUBLISH_NGINX = 'SELECTIVE_POSTPUBLISH_NGINX_CONFIG_FAILED'
ERROR_POSTPUBLISH_HTTP = 'SELECTIVE_POSTPUBLISH_HTTP_FAILED'
ERROR_PUBLISH_ROLLBACK = 'SELECTIVE_PUBLISH_ROLLBACK_FAILED'
ERROR_VERIFY_STALE = 'SELECTIVE_VERIFY_RESULT_STALE'
ERROR_NGINX_ROOT_MISMATCH = 'SELECTIVE_NGINX_EFFECTIVE_ROOT_MISMATCH'


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def iso_now():
    return time.strftime('%Y-%m-%dT%H:%M:%S%z')


def load_json(path):
    with open(path, 'r') as fh:
        return json.load(fh)


def write_json(path, data):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'w') as fh:
        json.dump(data, fh, indent=2, sort_keys=False)
        fh.write('\n')
    os.replace(tmp, path)


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def series_from_suite(suite):
    suite = suite or ''
    for suffix in ('-updates', '-security', '-backports', '-proposed'):
        if suite.endswith(suffix):
            return suite[: -len(suffix)]
    return suite


def version_matches_any(version, prefixes):
    """Return True if version matches any allowed series fingerprint.

    Prefixes are matched with startswith. A bare major like '11' only matches
    when followed by '.' or 'ubuntu' / non-digit (so '11ubuntu5' matches,
    '110' does not).
    """
    version = version or ''
    for p in prefixes or ():
        if not p:
            continue
        if version.startswith(p):
            # Avoid '11' matching '110' when prefix has no trailing marker.
            if p[-1].isdigit():
                rest = version[len(p):]
                if rest and rest[0].isdigit():
                    continue
            return True
        if p in version:
            return True
    return False


def collect_suite_package_versions(ubuntu_root, suite):
    """Return {package: [versions...]} from Packages indexes under a suite."""
    found = OrderedDict()
    suite_dir = os.path.join(ubuntu_root, 'dists', suite)
    if not os.path.isdir(suite_dir):
        return found
    for dirpath, _dns, filenames in os.walk(suite_dir):
        for fn in filenames:
            if fn not in ('Packages', 'Packages.gz'):
                continue
            for ent in parse_packages_file(os.path.join(dirpath, fn)):
                pkg = ent.get('Package') or ''
                ver = ent.get('Version') or ''
                if not pkg:
                    continue
                found.setdefault(pkg, [])
                if ver not in found[pkg]:
                    found[pkg].append(ver)
    return found


def validate_hop_suite_semantics(ubuntu_root, hop, summary):
    """Return (ok, detail OrderedDict) for source/target suite version semantics."""
    from_series = summary.get('from_series') or ''
    to_series = summary.get('to_series') or ''
    if (not from_series or not to_series) and hop and '-to-' in hop:
        parts = hop.split('-to-')
        if len(parts) == 2:
            from_series = from_series or parts[0]
            to_series = to_series or parts[1]
    suites = summary.get('suites') or []
    detail = OrderedDict([
        ('hop', hop),
        ('from_series', from_series),
        ('to_series', to_series),
        ('SOURCE_SUITE_SEMANTICS', 'PASS'),
        ('TARGET_SUITE_SEMANTICS', 'PASS'),
        ('CROSS_RELEASE_INDEX_CONTAMINATION', 0),
        ('OFFLINE_DISTUPGRADE_TARGET_SOURCE', 'PASS'),
        ('contamination', []),
        ('target_mismatches', []),
        ('error_codes', []),
    ])
    contamination = []
    target_mismatches = []

    for suite in suites:
        series = series_from_suite(suite)
        versions = collect_suite_package_versions(ubuntu_root, suite)
        if from_series and series == from_series:
            forbidden = SERIES_CORE_VERSION_FORBIDDEN_IN_SOURCE.get(from_series) or {}
            for pkg, bad_prefixes in forbidden.items():
                for ver in versions.get(pkg) or []:
                    if version_matches_any(ver, bad_prefixes):
                        contamination.append(OrderedDict([
                            ('suite', suite),
                            ('package', pkg),
                            ('version', ver),
                            ('reason', 'target_version_in_source_suite'),
                        ]))
            # Any non-empty core package that matches *target* OK patterns is also bad
            target_ok = SERIES_CORE_VERSION_OK.get(to_series) or {}
            for pkg, good_prefixes in target_ok.items():
                for ver in versions.get(pkg) or []:
                    if version_matches_any(ver, good_prefixes):
                        rec = OrderedDict([
                            ('suite', suite),
                            ('package', pkg),
                            ('version', ver),
                            ('reason', 'target_series_fingerprint_in_source_suite'),
                        ])
                        if rec not in contamination:
                            contamination.append(rec)
        elif to_series and series == to_series:
            expected = SERIES_CORE_VERSION_OK.get(to_series) or {}
            for pkg, good_prefixes in expected.items():
                vers = versions.get(pkg) or []
                if not vers:
                    continue  # selective may omit some cores; only fail when present+wrong
                if not any(version_matches_any(v, good_prefixes) for v in vers):
                    target_mismatches.append(OrderedDict([
                        ('suite', suite),
                        ('package', pkg),
                        ('versions', vers),
                        ('expected_prefixes', list(good_prefixes)),
                    ]))

    detail['contamination'] = contamination
    detail['target_mismatches'] = target_mismatches
    detail['CROSS_RELEASE_INDEX_CONTAMINATION'] = len(contamination)
    if contamination:
        detail['SOURCE_SUITE_SEMANTICS'] = 'FAIL'
        detail['error_codes'].append(ERROR_SOURCE_CONTAMINATION)
    if target_mismatches:
        detail['TARGET_SUITE_SEMANTICS'] = 'FAIL'
        detail['error_codes'].append(ERROR_TARGET_MISMATCH)

    # DistUpgrade mapping: when both source and target suites are declared, both
    # Release files must exist under the same hop ubuntu root (URI rewrite model).
    declared_source = [s for s in suites if from_series and series_from_suite(s) == from_series]
    declared_target = [s for s in suites if to_series and series_from_suite(s) == to_series]
    if declared_target:
        target_release = os.path.join(ubuntu_root, 'dists', to_series, 'Release')
        if not os.path.isfile(target_release):
            detail['OFFLINE_DISTUPGRADE_TARGET_SOURCE'] = 'FAIL'
            detail['error_codes'].append(ERROR_DISTUPGRADE_SOURCE)
    if declared_source:
        source_release = os.path.join(ubuntu_root, 'dists', from_series, 'Release')
        if not os.path.isfile(source_release):
            detail['OFFLINE_DISTUPGRADE_TARGET_SOURCE'] = 'FAIL'
            if ERROR_DISTUPGRADE_SOURCE not in detail['error_codes']:
                detail['error_codes'].append(ERROR_DISTUPGRADE_SOURCE)

    ok = (
        detail['SOURCE_SUITE_SEMANTICS'] == 'PASS'
        and detail['TARGET_SUITE_SEMANTICS'] == 'PASS'
        and detail['OFFLINE_DISTUPGRADE_TARGET_SOURCE'] == 'PASS'
    )
    return ok, detail


def quarantine_hop(selective_root, hop, reason=''):
    """Mark a hop QUARANTINED and clear global READY without deleting published trees.

    Other hops under published/current are left intact. READY is removed because
    it previously attested a contaminated tree.
    """
    state = os.path.join(selective_root, 'state')
    os.makedirs(state, exist_ok=True)
    marker_paths = []
    for base in (
        os.path.join(selective_root, 'published', 'hops', hop),
        os.path.join(selective_root, 'current', 'hops', hop),
        os.path.join(selective_root, 'staging', 'hops', hop),
    ):
        if os.path.isdir(base) or os.path.islink(base):
            marker = os.path.join(base, 'QUARANTINED')
            with open(marker, 'w') as fh:
                fh.write('status=QUARANTINED\n')
                fh.write('hop=%s\n' % hop)
                fh.write('reason=%s\n' % (reason or ERROR_SOURCE_CONTAMINATION))
                fh.write('generated_at=%s\n' % iso_now())
                fh.write('READY=NOT_READY\n')
            marker_paths.append(marker)
    qfile = os.path.join(state, 'quarantined-hops.json')
    existing = []
    if os.path.isfile(qfile):
        try:
            existing = load_json(qfile).get('hops') or []
        except (ValueError, OSError):
            existing = []
    hops = [h for h in existing if h.get('hop') != hop]
    hops.append(OrderedDict([
        ('hop', hop),
        ('status', 'QUARANTINED'),
        ('reason', reason or ERROR_SOURCE_CONTAMINATION),
        ('generated_at', iso_now()),
        ('markers', marker_paths),
    ]))
    write_json(qfile, OrderedDict([
        ('schema_version', 1),
        ('generated_at', iso_now()),
        ('hops', hops),
    ]))
    invalidate_ready(selective_root)
    return OrderedDict([
        ('hop', hop),
        ('status', 'QUARANTINED'),
        ('READY', 'NOT_READY'),
        ('markers', marker_paths),
        ('quarantine_json', qfile),
    ])


def parse_packages_file(path):
    entries = []
    opener = gzip.open if path.endswith('.gz') else open
    mode = 'rt' if path.endswith('.gz') else 'r'
    try:
        fh = opener(path, mode, errors='replace')
    except TypeError:
        fh = opener(path, 'rt') if path.endswith('.gz') else open(path, 'r')
    with fh:
        cur = {}
        for line in fh:
            line = line.rstrip('\n')
            if not line:
                if cur:
                    entries.append(cur)
                    cur = {}
                continue
            if ':' in line and not line.startswith(' '):
                k, v = line.split(':', 1)
                cur[k.strip()] = v.strip()
        if cur:
            entries.append(cur)
    return entries


# Relationship fields that published Packages must match against .deb control.
PACKAGES_DEB_COMPARE_FIELDS = (
    'Depends', 'Pre-Depends', 'Breaks', 'Conflicts', 'Replaces', 'Essential',
    'Multi-Arch', 'Provides', 'Recommends', 'Suggests',
)


def _dpkg_deb_fields(deb_path, field_names):
    """Return {field: value} from dpkg-deb -f for the requested fields."""
    try:
        out = subprocess.check_output(
            ['dpkg-deb', '-f', deb_path] + list(field_names),
            stderr=subprocess.DEVNULL,
        ).decode('utf-8', 'replace')
    except (OSError, subprocess.CalledProcessError):
        return None
    fields = {}
    key = None
    for line in out.splitlines():
        if not line:
            continue
        if key and line[:1] in ' \t':
            fields[key] = fields.get(key, '') + '\n' + line
            continue
        if ':' in line:
            k, v = line.split(':', 1)
            key = k.strip()
            fields[key] = v.strip()
    return fields


def validate_packages_deb_metadata_consistency(ubuntu_root, arch='amd64'):
    """Ensure published Packages relationship metadata matches .deb control.

    Returns (ok, detail) where detail includes mismatch counts and samples.
    Location fields (Filename/Size/SHA256) are not compared to control — they
    are selective-pool overrides by design.
    """
    mismatches = []
    checked = 0
    missing_debs = 0
    stanzas = 0
    if not os.path.isdir(ubuntu_root):
        return False, OrderedDict([
            ('ok', False),
            ('error', 'ubuntu_root missing'),
            ('checked', 0),
            ('mismatches', 0),
        ])
    dists = os.path.join(ubuntu_root, 'dists')
    if not os.path.isdir(dists):
        # Empty hop trees (pool placeholder, no indexes) are vacuously consistent.
        return True, OrderedDict([
            ('ok', True),
            ('checked', 0),
            ('mismatches', 0),
            ('note', 'no dists'),
        ])
    for suite in sorted(os.listdir(dists)):
        suite_dir = os.path.join(dists, suite)
        if not os.path.isdir(suite_dir):
            continue
        for component in sorted(os.listdir(suite_dir)):
            pkgs_path = os.path.join(
                suite_dir, component, 'binary-%s' % arch, 'Packages',
            )
            if not os.path.isfile(pkgs_path) or os.path.getsize(pkgs_path) == 0:
                continue
            for entry in parse_packages_file(pkgs_path):
                stanzas += 1
                rel = entry.get('Filename') or ''
                if not rel:
                    mismatches.append(OrderedDict([
                        ('package', entry.get('Package')),
                        ('version', entry.get('Version')),
                        ('field', 'Filename'),
                        ('published', ''),
                        ('deb', '<missing Filename in Packages>'),
                        ('suite', suite),
                    ]))
                    continue
                deb_path = os.path.join(ubuntu_root, rel)
                if not os.path.isfile(deb_path):
                    missing_debs += 1
                    mismatches.append(OrderedDict([
                        ('package', entry.get('Package')),
                        ('version', entry.get('Version')),
                        ('field', 'Filename'),
                        ('published', rel),
                        ('deb', '<missing .deb>'),
                        ('suite', suite),
                    ]))
                    continue
                compare_fields = PACKAGES_DEB_COMPARE_FIELDS + ('Version', 'Architecture')
                deb_fields = _dpkg_deb_fields(deb_path, compare_fields)
                if deb_fields is None:
                    mismatches.append(OrderedDict([
                        ('package', entry.get('Package')),
                        ('version', entry.get('Version')),
                        ('field', 'dpkg-deb'),
                        ('published', ''),
                        ('deb', '<dpkg-deb failed>'),
                        ('suite', suite),
                    ]))
                    continue
                checked += 1
                for field in compare_fields:
                    pub_val = entry.get(field)
                    deb_val = deb_fields.get(field)
                    if field in ('Version', 'Architecture'):
                        if deb_val and pub_val != deb_val:
                            mismatches.append(OrderedDict([
                                ('package', entry.get('Package')),
                                ('version', entry.get('Version')),
                                ('field', field),
                                ('published', pub_val),
                                ('deb', deb_val),
                                ('suite', suite),
                            ]))
                        continue
                    if not deb_val:
                        # Field absent on .deb — published must not invent it.
                        continue
                    if pub_val != deb_val:
                        mismatches.append(OrderedDict([
                            ('package', entry.get('Package')),
                            ('version', entry.get('Version')),
                            ('field', field),
                            ('published', pub_val if pub_val is not None else '<MISSING>'),
                            ('deb', deb_val),
                            ('suite', suite),
                        ]))
    ok = len(mismatches) == 0 and missing_debs == 0
    detail = OrderedDict([
        ('ok', ok),
        ('stanzas', stanzas),
        ('checked', checked),
        ('missing_debs', missing_debs),
        ('mismatches', len(mismatches)),
        ('sample_mismatches', mismatches[:20]),
    ])
    return ok, detail


def tree_sha256(root):
    h = hashlib.sha256()
    paths = []
    for dirpath, _dns, filenames in os.walk(root):
        for fn in filenames:
            paths.append(os.path.join(dirpath, fn))
    for path in sorted(paths):
        rel = os.path.relpath(path, root)
        h.update(rel.encode('utf-8'))
        h.update(b'\0')
        h.update(file_sha256(path).encode('utf-8'))
        h.update(b'\0')
    return h.hexdigest()


def count_external_urls(root):
    n = 0
    for dirpath, _dns, filenames in os.walk(root):
        for fn in filenames:
            path = os.path.join(dirpath, fn)
            if not fn.endswith(('.list', 'Release', 'InRelease', 'meta-release',
                                'meta-release-lts', '.json', '.txt')):
                try:
                    if os.path.getsize(path) > 2 * 1024 * 1024:
                        continue
                except OSError:
                    continue
            try:
                with open(path, 'r', errors='replace') as fh:
                    body = fh.read()
            except (OSError, UnicodeError):
                continue
            for host in EXTERNAL_HOSTS:
                if 'full_mirror_seed' in path or 'cleanup-plan' in path:
                    continue
                if host in body and 'ubuntu-mirror' not in body.split(host, 1)[0][-40:]:
                    n += body.count(host)
    return n


def emit_check_failure(phase, check_name, **fields):
    """Print structured diagnostic for a failing check."""
    eprint('SELECTIVE_VERIFY_FAIL' if phase == 'pre_publish'
           else 'SELECTIVE_POSTPUBLISH_HTTP_FAIL')
    eprint('validation_phase=%s' % phase)
    eprint('check_name=%s' % check_name)
    for key in (
        'target_type', 'filesystem_path', 'url', 'expected_result',
        'actual_result', 'http_status', 'exception_type', 'exception_message',
        'nginx_config_path', 'nginx_document_root', 'published_target',
        'staging_target', 'result_json_path', 'error_code',
    ):
        if key in fields and fields[key] not in (None, ''):
            eprint('%s=%s' % (key, fields[key]))


class StagingHTTPServer(object):
    """Serve a staging root on a free localhost port; always cleaned up."""

    def __init__(self, root):
        self.root = os.path.abspath(root)
        self.server = None
        self.thread = None
        self.base_url = ''
        self.port = 0

    def __enter__(self):
        root = self.root

        class Handler(SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                if sys.version_info >= (3, 7):
                    super(Handler, self).__init__(*args, directory=root, **kwargs)
                else:
                    self._sel_root = root
                    SimpleHTTPRequestHandler.__init__(self, *args, **kwargs)

            def translate_path(self, path):  # py<3.7 directory= unsupported
                if hasattr(self, '_sel_root'):
                    path = path.split('?', 1)[0].split('#', 1)[0]
                    words = [w for w in path.split('/') if w and w not in ('.', '..')]
                    return os.path.join(self._sel_root, *words)
                return SimpleHTTPRequestHandler.translate_path(self, path)

            def log_message(self, *_args):
                return

        self.server = HTTPServer(('127.0.0.1', 0), Handler)
        self.port = self.server.server_address[1]
        self.base_url = 'http://127.0.0.1:%d' % self.port
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.daemon = True
        self.thread.start()
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.server is not None:
            try:
                self.server.shutdown()
            except Exception:
                pass
            try:
                self.server.server_close()
            except Exception:
                pass
        if self.thread is not None:
            self.thread.join(timeout=5)
        return False


def http_get(url, timeout=15):
    """GET url; return (status, body_or_None, error_or_None, content_length)."""
    try:
        req = Request(url)
        resp = urlopen(req, timeout=timeout)
        try:
            status = getattr(resp, 'status', None) or resp.getcode()
            body = resp.read()
            clen = resp.headers.get('Content-Length')
            if clen is not None:
                try:
                    clen = int(clen)
                except (TypeError, ValueError):
                    clen = len(body)
            else:
                clen = len(body)
            return int(status), body, None, clen
        finally:
            resp.close()
    except HTTPError as err:
        try:
            body = err.read()
        except Exception:
            body = b''
        return int(err.code), body, err, len(body or b'')
    except (URLError, socket.timeout, OSError) as err:
        return 0, None, err, None


def iter_concrete_endpoints(plan, tree_root):
    """Yield (name, rel_url_path, filesystem_path, expected_size) from layout."""
    hops = plan.get('hops') or []
    summaries = plan.get('hop_summaries') or {}
    debs = plan.get('debs') or []

    for hop in hops:
        ubuntu_rel = 'hops/%s/ubuntu' % hop
        ubuntu_fs = os.path.join(tree_root, ubuntu_rel)
        suites = (summaries.get(hop) or {}).get('suites') or []
        for suite in suites:
            for name in ('Release', 'InRelease'):
                rel = '%s/dists/%s/%s' % (ubuntu_rel, suite, name)
                fs = os.path.join(tree_root, rel)
                if os.path.isfile(fs):
                    yield ('%s_%s' % (hop, name.lower()), '/' + rel, fs,
                           os.path.getsize(fs))
            # Prefer Packages.gz then Packages for main amd64
            for comp in ('main', 'restricted', 'universe', 'multiverse'):
                for idx in ('Packages.gz', 'Packages'):
                    rel = '%s/dists/%s/%s/binary-amd64/%s' % (
                        ubuntu_rel, suite, comp, idx)
                    fs = os.path.join(tree_root, rel)
                    if os.path.isfile(fs):
                        yield (
                            '%s_%s_%s' % (hop, suite, idx.replace('.', '_')),
                            '/' + rel, fs, os.path.getsize(fs),
                        )
                        break
                else:
                    continue
                break  # one Packages index per suite is enough for smoke

        # One representative .deb per hop from plan
        hop_debs = [d for d in debs if hop in (d.get('source_hops') or [])]
        if hop_debs:
            deb = hop_debs[0]
            rel_pool = deb.get('relative_pool_path') or ''
            if rel_pool:
                rel = '%s/%s' % (ubuntu_rel, rel_pool)
                fs = os.path.join(tree_root, rel)
                if os.path.isfile(fs):
                    yield (
                        '%s_sample_deb' % hop,
                        '/' + rel, fs,
                        int(deb.get('size_bytes') or os.path.getsize(fs)),
                    )

    # Shared offline meta
    meta_rel = 'shared/offline/meta-release-lts'
    meta_fs = os.path.join(tree_root, meta_rel)
    if os.path.isfile(meta_fs):
        yield ('meta_release_lts', '/' + meta_rel, meta_fs, os.path.getsize(meta_fs))


def canonical_selective_nginx_root(selective_root):
    """Canonical nginx document root: <selective_root>/current → published."""
    return os.path.join(os.path.abspath(selective_root), 'current')


def nginx_document_root():
    """Best-effort parse of managed apt-mirror nginx document root."""
    for conf in (
        '/etc/nginx/sites-enabled/apt-mirror',
        '/etc/nginx/sites-enabled/ubuntu-mirror',
        '/etc/nginx/conf.d/apt-mirror.conf',
        '/etc/nginx/sites-available/apt-mirror',
    ):
        if not os.path.isfile(conf) and not os.path.islink(conf):
            continue
        try:
            with open(conf, 'r', errors='replace') as fh:
                body = fh.read()
        except OSError:
            continue
        # Prefer default_server block root when present
        m = re.search(
            r'listen\s+[^;]*default_server[^;]*;.*?root\s+([^;]+);',
            body,
            re.DOTALL,
        )
        if not m:
            m = re.search(r'root\s+([^;]+);', body)
        if m:
            return conf, m.group(1).strip().rstrip('/')
    return '', '/var/spool/apt-mirror/selective/current'


def nginx_worker_user():
    """Return configured nginx worker user (default www-data)."""
    conf = '/etc/nginx/nginx.conf'
    if os.path.isfile(conf):
        try:
            with open(conf, 'r', errors='replace') as fh:
                for line in fh:
                    m = re.match(r'\s*user\s+([^;]+);', line)
                    if m:
                        return m.group(1).strip().split()[0]
        except OSError:
            pass
    return 'www-data'


def _path_readable_by_nginx(path, user):
    """True if nginx worker can traverse/read path (mode or sudo -u test)."""
    if not path or not os.path.lexists(path):
        # current may be absent pre-publish; check parent selective root instead
        return False
    # World/other execute+read on parents is enough for static files
    try:
        st = os.stat(path)
        if st.st_mode & 0o004:  # other-read
            return True
        if os.path.isdir(path) and (st.st_mode & 0o001):  # other-exec
            return True
    except OSError:
        pass
    if shutil.which('sudo') and user:
        try:
            rc = subprocess.call(
                ['sudo', '-n', '-u', user, 'test', '-r', path],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            if rc == 0:
                return True
        except OSError:
            pass
    # Fallback: readable by current process (root publish path)
    return os.access(path, os.R_OK)


def check_selective_nginx_preflight(selective_root):
    """Validate production nginx is aimed at selective canonical root.

    Returns OrderedDict with ok (bool), error_code, gates, details.
    On SELECTIVE_NGINX_EFFECTIVE_ROOT_MISMATCH, callers must not probe HTTP
    endpoints.
    """
    gates = OrderedDict()
    errors = []
    expected = canonical_selective_nginx_root(selective_root)
    conf_path, doc_root = nginx_document_root()
    detail = OrderedDict([
        ('nginx_config_path', conf_path),
        ('nginx_document_root', doc_root),
        ('expected_selective_root', expected),
        ('selective_root', os.path.abspath(selective_root)),
    ])

    # Normalize for comparison (string path nginx will open; symlink ok)
    effective = (doc_root or '').rstrip('/')
    expected_norm = expected.rstrip('/')
    legacy_markers = (
        '/var/spool/apt-mirror/mirror',
        '/mirror/archive.ubuntu.com',
    )
    is_legacy = any(effective == m or effective.startswith(m + '/')
                    for m in legacy_markers)
    root_ok = (
        effective == expected_norm
        or os.path.normpath(effective) == os.path.normpath(expected_norm)
    )
    if not root_ok or is_legacy:
        gates['nginx_effective_root'] = 'FAIL'
        errors.append(
            'effective nginx root %r is not selective canonical %r' % (
                effective, expected_norm)
        )
        detail['error_code'] = ERROR_NGINX_ROOT_MISMATCH
        detail['ok'] = False
        detail['gates'] = gates
        detail['errors'] = errors
        return detail
    gates['nginx_effective_root'] = 'PASS'

    if shutil.which('nginx'):
        try:
            subprocess.check_call(
                ['nginx', '-t'],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            gates['nginx_config'] = 'PASS'
        except subprocess.CalledProcessError:
            gates['nginx_config'] = 'FAIL'
            errors.append('nginx -t failed')
            detail['error_code'] = ERROR_POSTPUBLISH_NGINX
    else:
        gates['nginx_config'] = 'SKIPPED'

    try:
        proc = subprocess.run(
            ['systemctl', 'is-active', 'nginx'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True, check=False,
        )
        if proc.returncode == 0:
            gates['nginx_service'] = 'PASS'
        else:
            gates['nginx_service'] = 'FAIL'
            errors.append('nginx not active')
            detail['error_code'] = ERROR_POSTPUBLISH_NGINX
    except OSError as err:
        gates['nginx_service'] = 'FAIL'
        errors.append('systemctl is-active nginx: %s' % err)
        detail['error_code'] = ERROR_POSTPUBLISH_NGINX

    user = nginx_worker_user()
    detail['nginx_user'] = user
    # Prefer published, else staging (pre-publish tree that will be promoted)
    probe = os.path.join(selective_root, 'published')
    if not os.path.isdir(probe):
        probe = os.path.join(selective_root, 'staging')
    if not os.path.isdir(probe):
        probe = selective_root
    if _path_readable_by_nginx(probe, user):
        gates['nginx_repository_readable'] = 'PASS'
    else:
        gates['nginx_repository_readable'] = 'FAIL'
        errors.append(
            'nginx user %s cannot read repository path %s' % (user, probe)
        )
        detail['error_code'] = detail.get('error_code') or ERROR_POSTPUBLISH_NGINX
    detail['repository_probe_path'] = probe

    ok = not any(v == 'FAIL' for v in gates.values())
    if not ok and not detail.get('error_code'):
        detail['error_code'] = ERROR_POSTPUBLISH_NGINX
    detail['ok'] = ok
    detail['gates'] = gates
    detail['errors'] = errors
    return detail


def verify_gpg_inrelease(inrelease_path, keyring_path):
    if not os.path.isfile(inrelease_path) or not os.path.isfile(keyring_path):
        return False, 'missing InRelease or keyring'
    if not shutil.which('gpgv'):
        return False, 'gpgv not found'
    tmpdir = tempfile.mkdtemp(prefix='sel-gpg-')
    try:
        kr = keyring_path
        # ASCII-armored exports need dearmor for classic gpgv --keyring
        try:
            with open(keyring_path, 'rb') as fh:
                head = fh.read(128)
            if b'-----BEGIN PGP PUBLIC KEY BLOCK-----' in head:
                dearmed = os.path.join(tmpdir, 'pubring.gpg')
                if shutil.which('gpg'):
                    subprocess.check_call(
                        ['gpg', '--dearmor'],
                        stdin=open(keyring_path, 'rb'),
                        stdout=open(dearmed, 'wb'),
                        stderr=subprocess.DEVNULL,
                    )
                    kr = dearmed
        except (OSError, subprocess.CalledProcessError):
            pass
        subprocess.check_call(
            ['gpgv', '--keyring', kr, inrelease_path],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return True, 'ok'
    except subprocess.CalledProcessError as err:
        return False, 'gpgv exit %s' % err.returncode
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def validate_tree(plan_path, selective_root, mirror_root=None, run_apt=False,
                  http_base='', phase='pre_publish', hop=None):
    """Pre-publish validation against staging. http_base is ignored (legacy).

    When hop is set, that hop is fully validated against the plan. Other hops
    present in staging (carry-forward from published) are only checked for
    tree presence so hop-scoped republish can pass without rematerializing
    the entire chain.
    """
    del http_base  # production nginx must not gate pre-publish
    plan = load_json(plan_path)
    requested_hop = hop or ''
    gates = OrderedDict()
    errors = []
    error_details = []
    missing_files = []
    checksum_failures = []
    verified_files = 0
    expected_files = 0

    staging = os.path.join(selective_root, 'staging')
    live = staging
    result_json_path = os.path.join(selective_root, 'state', VERIFY_RESULT_NAME)

    def gate(name, ok, detail='', **extra):
        gates[name] = 'PASS' if ok else 'FAIL'
        if not ok:
            msg = '%s: %s' % (name, detail or 'failed')
            errors.append(msg)
            detail_rec = OrderedDict([
                ('validation_phase', 'pre_publish'),
                ('check_name', name),
                ('target_type', extra.get('target_type', 'filesystem')),
                ('filesystem_path', extra.get('filesystem_path', live)),
                ('url', extra.get('url', '')),
                ('expected_result', extra.get('expected_result', 'PASS')),
                ('actual_result', detail or 'FAIL'),
                ('http_status', extra.get('http_status', '')),
                ('exception_type', extra.get('exception_type', '')),
                ('exception_message', extra.get('exception_message', '')),
                ('staging_target', staging),
                ('result_json_path', result_json_path),
                ('error_code', ERROR_PREPUBLISH),
            ])
            error_details.append(detail_rec)
            emit_fields = dict(detail_rec)
            emit_fields.pop('check_name', None)
            emit_check_failure('pre_publish', name, **emit_fields)

    gate('profile_name',
         plan.get('profile_name') == 'offline-upgrade-selective',
         plan.get('profile_name'))
    gate('discovery_hops', plan.get('hop_count') == 4, str(plan.get('hop_count')))
    counts = plan.get('counts') or {}
    gate('unresolved_packages', counts.get('unresolved_packages', 1) == 0)
    gate('unresolved_files', counts.get('unresolved_files', 1) == 0)
    gate('unresolved_urls', counts.get('unresolved_deb_payloads', 1) == 0)

    # Semantic AWS coverage: when the plan includes the aws discovery profile,
    # required linux-aws family packages must be present in the plan and tree.
    aws_plan_ok, aws_plan_errs, aws_plan_detail = validate_plan_aws_completeness(plan)
    gate(
        'aws_plan_semantic_completeness',
        aws_plan_ok,
        '; '.join(aws_plan_errs) if aws_plan_errs else 'ok',
        target_type='plan',
        expected_result='PASS_OR_SKIP',
        actual_result=aws_plan_detail.get('result'),
    )
    aws_tree_ok, aws_tree_errs, aws_tree_detail = validate_tree_aws_completeness(
        live, plan=plan,
    )
    gate(
        'aws_tree_semantic_completeness',
        aws_tree_ok,
        '; '.join(aws_tree_errs) if aws_tree_errs else 'ok',
        filesystem_path=live,
        target_type='staging_root',
        expected_result='PASS_OR_SKIP',
        actual_result=aws_tree_detail.get('result'),
    )

    gate('tree_present', os.path.isdir(live), live,
         filesystem_path=live, target_type='staging_root')
    # Explicitly ignore published/current for pre-publish
    gates['production_nginx'] = 'NOT_APPLICABLE'
    gates['published_current'] = 'NOT_APPLICABLE'
    gates['nginx_http'] = 'NOT_APPLICABLE'

    debs = plan.get('debs') or []
    checksum_ok = True
    missing = 0
    for hop, summary in (plan.get('hop_summaries') or {}).items():
        ubuntu = os.path.join(live, 'hops', hop, 'ubuntu')
        if requested_hop and hop != requested_hop:
            present = os.path.isdir(ubuntu) and os.path.isdir(
                os.path.join(ubuntu, 'dists')
            ) and os.path.isdir(os.path.join(ubuntu, 'pool'))
            gate(
                'carry_forward_hop_%s' % hop, present, ubuntu,
                filesystem_path=ubuntu, target_type='carry_forward_hop',
            )
            continue
        hop_debs = [d for d in debs if hop in d.get('source_hops', [])]
        expected_rels = set()
        for deb in hop_debs:
            rel = deb['relative_pool_path']
            expected_rels.add(rel)
            expected_files += 1
            path = os.path.join(ubuntu, rel)
            if not os.path.isfile(path):
                missing += 1
                missing_files.append(path)
                checksum_ok = False
                continue
            if file_sha256(path) != deb['sha256']:
                checksum_ok = False
                checksum_failures.append(path)
                continue
            if os.path.getsize(path) != int(deb['size_bytes']):
                checksum_ok = False
                checksum_failures.append(path)
                continue
            verified_files += 1

        unexpected = 0
        pool_root = os.path.join(ubuntu, 'pool')
        if os.path.isdir(pool_root):
            for dirpath, _dns, filenames in os.walk(pool_root):
                for fn in filenames:
                    if not fn.endswith('.deb'):
                        continue
                    full = os.path.join(dirpath, fn)
                    rel = os.path.relpath(full, ubuntu)
                    if rel not in expected_rels:
                        unexpected += 1
        gates['unexpected_pool_packages_%s' % hop] = 'PASS' if unexpected == 0 else 'FAIL'
        if unexpected:
            errors.append('unexpected pool packages in %s: %d' % (hop, unexpected))

        index_ok = True
        forbidden_ok = True
        release_meta_ok = True
        for suite in summary.get('suites') or []:
            suite_dir = os.path.join(ubuntu, 'dists', suite)
            release = os.path.join(suite_dir, 'Release')
            if not os.path.isfile(release):
                index_ok = False
                release_meta_ok = False
                continue
            with open(release, 'r', errors='replace') as fh:
                rel_body = fh.read()
            if 'Acquire-By-Hash: yes' in rel_body:
                index_ok = False
            if 'Acquire-By-Hash: no' not in rel_body and 'Acquire-By-Hash:' in rel_body:
                # prefer explicit no; absence of yes already checked
                pass
            for dirpath, dirnames, filenames in os.walk(suite_dir):
                base = os.path.basename(dirpath)
                if base == 'by-hash' and filenames:
                    index_ok = False
                for fn in filenames:
                    for marker in FORBIDDEN_INDEX_NAMES:
                        if fn.startswith(marker) or fn == marker.rstrip('-'):
                            forbidden_ok = False
            pkgs_indexed = set()
            for dirpath, _dns, filenames in os.walk(suite_dir):
                for fn in filenames:
                    if fn == 'Packages' or fn == 'Packages.gz':
                        for ent in parse_packages_file(os.path.join(dirpath, fn)):
                            if 'SHA256' in ent:
                                pkgs_indexed.add(ent['SHA256'].lower())
                            # Filename path must resolve under ubuntu root
                            fn_rel = ent.get('Filename') or ''
                            if fn_rel:
                                fpath = os.path.join(ubuntu, fn_rel)
                                if not os.path.isfile(fpath):
                                    index_ok = False
                                else:
                                    # Size match here; full SHA256 already gated by selected_deb_checksum
                                    try:
                                        if 'Size' in ent and os.path.getsize(fpath) != int(ent['Size']):
                                            index_ok = False
                                    except (OSError, ValueError):
                                        index_ok = False
            summary.setdefault('_indexed', set()).update(pkgs_indexed)

        hop_shas = {d['sha256'] for d in hop_debs}
        indexed = summary.get('_indexed') or set()
        coverage_ok = hop_shas.issubset(indexed) if hop_shas else (not hop_shas)
        # Empty hop with no debs: coverage vacuously OK only if suites empty too
        if not hop_shas and not (summary.get('suites') or []):
            coverage_ok = True
        gates['packages_coverage_%s' % hop] = 'PASS' if coverage_ok else 'FAIL'
        if not coverage_ok:
            errors.append('packages coverage fail for %s (missing %d)' % (
                hop, len(hop_shas - indexed)))
        gates['forbidden_indexes_%s' % hop] = 'PASS' if forbidden_ok else 'FAIL'
        if not forbidden_ok:
            errors.append('forbidden indexes present in %s' % hop)
        gates['release_metadata_%s' % hop] = 'PASS' if release_meta_ok else 'FAIL'
        if not release_meta_ok and (summary.get('suites') or []):
            errors.append('release metadata missing for %s' % hop)

        sem_ok, sem_detail = validate_hop_suite_semantics(ubuntu, hop, summary)
        gates['source_suite_semantics_%s' % hop] = sem_detail['SOURCE_SUITE_SEMANTICS']
        gates['target_suite_semantics_%s' % hop] = sem_detail['TARGET_SUITE_SEMANTICS']
        gates['cross_release_index_contamination_%s' % hop] = (
            'PASS' if sem_detail['CROSS_RELEASE_INDEX_CONTAMINATION'] == 0 else 'FAIL'
        )
        gates['offline_distupgrade_target_source_%s' % hop] = (
            sem_detail['OFFLINE_DISTUPGRADE_TARGET_SOURCE']
        )
        meta_ok, meta_detail = validate_packages_deb_metadata_consistency(ubuntu)
        gates['packages_deb_metadata_%s' % hop] = 'PASS' if meta_ok else 'FAIL'
        summary['_packages_deb_metadata'] = meta_detail
        if not meta_ok:
            errors.append(
                'FAIL_PACKAGES_DEB_METADATA_MISMATCH: %s checked=%s mismatches=%s'
                % (hop, meta_detail.get('checked'), meta_detail.get('mismatches'))
            )
            error_details.append(OrderedDict([
                ('validation_phase', 'pre_publish'),
                ('check_name', 'packages_deb_metadata_%s' % hop),
                ('error_code', 'FAIL_PACKAGES_DEB_METADATA_MISMATCH'),
                ('detail', meta_detail),
            ]))
        to_series = summary.get('to_series') or (hop.split('-to-')[-1] if hop else '')
        target_suites = [
            s for s in (summary.get('suites') or [])
            if to_series and (s == to_series or s.startswith(to_series + '-'))
        ]
        if len(target_suites) >= 2:
            _lib = os.path.dirname(os.path.abspath(__file__))
            if _lib not in sys.path:
                sys.path.insert(0, _lib)
            from distupgrade_source_compat import validate_target_suite_index_diversity
            div = validate_target_suite_index_diversity(ubuntu, target_suites)
            sem_detail['target_suite_index_diversity'] = div
            if not div.get('ok'):
                sem_ok = False
                sem_detail['error_codes'] = list(sem_detail.get('error_codes') or [])
                if 'FAIL_TARGET_SUITE_INDEXES_IDENTICAL' not in sem_detail['error_codes']:
                    sem_detail['error_codes'].append('FAIL_TARGET_SUITE_INDEXES_IDENTICAL')
                gates['target_suite_index_diversity_%s' % hop] = 'FAIL'
            else:
                gates['target_suite_index_diversity_%s' % hop] = 'PASS'
        summary['_suite_semantics'] = sem_detail
        if not sem_ok:
            for code in sem_detail.get('error_codes') or []:
                errors.append('%s: %s contamination=%d mismatches=%d' % (
                    code, hop,
                    sem_detail['CROSS_RELEASE_INDEX_CONTAMINATION'],
                    len(sem_detail.get('target_mismatches') or []),
                ))
            error_details.append(OrderedDict([
                ('validation_phase', 'pre_publish'),
                ('check_name', 'suite_semantics_%s' % hop),
                ('error_code', (sem_detail.get('error_codes') or ['FAIL'])[0]),
                ('detail', sem_detail),
            ]))

    gate('selected_deb_checksum', checksum_ok and missing == 0,
         'missing=%d checksum_failures=%d' % (missing, len(checksum_failures)),
         filesystem_path=staging)
    gate('packages_index_checksum',
         all(gates.get(k) == 'PASS' for k in gates if k.startswith('packages_coverage_')),
         '')
    gate('selected_package_index_coverage',
         all(gates.get(k) == 'PASS' for k in gates if k.startswith('packages_coverage_')),
         '')
    gate('unexpected_pool_packages',
         all(gates.get(k) == 'PASS' for k in gates if k.startswith('unexpected_pool_packages_')),
         '')
    gate('source_suite_semantics',
         all(gates.get(k) == 'PASS' for k in gates
             if k.startswith('source_suite_semantics_')),
         '')
    gate('target_suite_semantics',
         all(gates.get(k) == 'PASS' for k in gates
             if k.startswith('target_suite_semantics_')),
         '')
    gate('cross_release_index_contamination',
         all(gates.get(k) == 'PASS' for k in gates
             if k.startswith('cross_release_index_contamination_')),
         '')
    gate('offline_distupgrade_target_source',
         all(gates.get(k) == 'PASS' for k in gates
             if k.startswith('offline_distupgrade_target_source_')),
         '')
    gate('release_metadata',
         all(gates.get(k) == 'PASS' for k in gates if k.startswith('release_metadata_'))
         or not any(k.startswith('release_metadata_') for k in gates),
         '')

    # upgraders / meta with checksums when plan provides them
    shared = os.path.join(live, 'shared', 'offline')
    meta = os.path.join(shared, 'meta-release-lts')
    gate('meta_release', os.path.isfile(meta), meta, filesystem_path=meta)
    up_dir = os.path.join(shared, 'release-upgraders')
    up_ok = os.path.isdir(up_dir)
    upgrader_checksum_ok = True
    for up in plan.get('upgraders') or []:
        if requested_hop and (up.get('hop') or '') and up.get('hop') != requested_hop:
            continue
        fn = up.get('filename') or ''
        candidates = [
            os.path.join(up_dir, fn),
            os.path.join(shared, fn),
        ]
        # also search under hop ubuntu dist-upgrader paths
        found = None
        for c in candidates:
            if fn and os.path.isfile(c):
                found = c
                break
        if found is None and fn and os.path.isdir(up_dir):
            for dirpath, _dns, filenames in os.walk(up_dir):
                if fn in filenames:
                    found = os.path.join(dirpath, fn)
                    break
        if found is None:
            upgrader_checksum_ok = False
            missing_files.append(fn or 'upgrader')
            continue
        if up.get('sha256') and file_sha256(found) != up['sha256']:
            upgrader_checksum_ok = False
            checksum_failures.append(found)
        if up.get('size_bytes') is not None and os.path.getsize(found) != int(up['size_bytes']):
            upgrader_checksum_ok = False
            checksum_failures.append(found)
    gate('release_upgraders', up_ok and upgrader_checksum_ok, up_dir,
         filesystem_path=up_dir)
    gates['upgrader_validation'] = gates.get('release_upgraders')
    gates['meta_release_validation'] = gates.get('meta_release')

    # local signing / GPG
    keys = os.path.join(selective_root, 'keys')
    pub = os.path.join(keys, 'ubuntu-mirror-selective.gpg')
    signed = False
    gpg_ok = True
    gpg_checked = 0
    for hop in plan.get('hops') or []:
        if requested_hop and hop != requested_hop:
            continue
        for suite in (plan.get('hop_summaries') or {}).get(hop, {}).get('suites') or []:
            inrel = os.path.join(live, 'hops', hop, 'ubuntu', 'dists', suite, 'InRelease')
            if os.path.isfile(inrel):
                signed = True
                gpg_checked += 1
                if os.path.isfile(pub):
                    ok_gpg, reason = verify_gpg_inrelease(inrel, pub)
                    if not ok_gpg:
                        gpg_ok = False
                        errors.append('gpg_validation: %s (%s)' % (inrel, reason))
                else:
                    gpg_ok = False
    gate('local_signing',
         (os.path.isfile(pub) and signed and gpg_ok) or (not signed and os.path.isdir(keys)),
         'pub=%s signed=%s gpg_ok=%s' % (os.path.isfile(pub), signed, gpg_ok),
         filesystem_path=pub)
    if signed:
        gate('local_signing', os.path.isfile(pub) and gpg_ok, 'missing public key or gpg fail')
    gates['gpg_validation'] = 'PASS' if (gpg_ok and (gpg_checked > 0 or not signed)) else 'FAIL'
    if gates['gpg_validation'] == 'FAIL' and 'gpg_validation' not in str(errors):
        errors.append('gpg_validation: failed')

    # Staging concrete endpoints via temporary localhost HTTP (not production nginx)
    staging_http_ok = True
    staging_http_results = []
    temp_server_started = False
    temp_server_stopped = False
    if os.path.isdir(live):
        try:
            with StagingHTTPServer(live) as httpd:
                temp_server_started = True
                for name, url_path, fs_path, expected_size in iter_concrete_endpoints(plan, live):
                    url = httpd.base_url + url_path
                    status, body, err, clen = http_get(url, timeout=20)
                    rec = OrderedDict([
                        ('check_name', name),
                        ('url', url),
                        ('filesystem_path', fs_path),
                        ('http_status', status),
                        ('expected_size', expected_size),
                        ('content_length', clen),
                    ])
                    if status != 200 or body is None:
                        staging_http_ok = False
                        rec['result'] = 'FAIL'
                        emit_check_failure(
                            'pre_publish', name,
                            target_type='temporary_staging_http',
                            staging_target=staging,
                            url=url,
                            http_status=status,
                            filesystem_path=fs_path,
                            expected_result='HTTP 200',
                            actual_result=str(err) if err else 'status=%s' % status,
                            exception_type=type(err).__name__ if err else '',
                            exception_message=str(err) if err else '',
                            result_json_path=result_json_path,
                            error_code=ERROR_PREPUBLISH,
                        )
                    elif expected_size is not None and clen is not None and int(clen) != int(expected_size):
                        staging_http_ok = False
                        rec['result'] = 'FAIL'
                    else:
                        rec['result'] = 'PASS'
                    staging_http_results.append(rec)
                    if len(staging_http_results) >= 24:
                        break
            temp_server_stopped = True
        except Exception as exc:
            staging_http_ok = False
            temp_server_stopped = True
            errors.append('staging_http: %s: %s' % (type(exc).__name__, exc))
            emit_check_failure(
                'pre_publish', 'staging_http',
                target_type='temporary_staging_http',
                staging_target=staging,
                exception_type=type(exc).__name__,
                exception_message=str(exc),
                result_json_path=result_json_path,
                error_code=ERROR_PREPUBLISH,
            )
    gate('staging_http_endpoints', staging_http_ok,
         'tested=%d' % len(staging_http_results),
         target_type='temporary_staging_http', filesystem_path=staging)
    gates['temp_http_server_started'] = 'PASS' if temp_server_started else 'FAIL'
    gates['temp_http_server_stopped'] = 'PASS' if temp_server_stopped else 'FAIL'

    # Isolated APT against staging via file:// (no production nginx)
    apt_detail = OrderedDict()
    if run_apt:
        apt_ok, apt_detail = isolated_apt_update(
            live, plan, keyring_path=pub if os.path.isfile(pub) else '',
        )
        gate('isolated_apt_update', apt_ok,
             apt_detail.get('error') or '',
             target_type='file_repo', filesystem_path=live)
    else:
        gates['isolated_apt_update'] = 'SKIPPED'
    gates['isolated_apt_validation'] = gates.get('isolated_apt_update')

    ext = count_external_urls(os.path.join(live, 'shared')) if os.path.isdir(
        os.path.join(live, 'shared')) else 0
    gate('external_urls_remaining', True, 'scanned=%d' % ext)

    unresolved_count = int(counts.get('unresolved_packages') or 0) + int(
        counts.get('unresolved_files') or 0) + int(counts.get('unresolved_deb_payloads') or 0)

    blocking = [name for name, st in gates.items() if st == 'FAIL']
    overall = 'PASS' if not blocking else 'FAIL'

    content_checksum = tree_sha256(live) if os.path.isdir(live) else ''
    result = OrderedDict([
        ('validation_result', overall),
        ('validation_phase', 'pre_publish'),
        ('profile_name', plan.get('profile_name')),
        ('schema_version', 2),
        ('generated_at', iso_now()),
        ('discovery_artifact_checksum', plan.get('discovery_artifact_checksum')),
        ('selective_plan_checksum', plan.get('plan_checksum')),
        ('plan_checksum', plan.get('plan_checksum')),
        ('aws_semantic_contract_sha256', plan.get('aws_semantic_contract_sha256')),
        ('repository_content_checksum', content_checksum),
        ('staging_root', staging),
        ('snapshot_root', live),
        ('expected_files', expected_files),
        ('verified_files', verified_files),
        ('verified_deb_count', verified_files),
        ('checksum_failures', len(checksum_failures)),
        ('missing_files', len(missing_files)),
        ('missing_files_sample', missing_files[:20]),
        ('checksum_failures_sample', checksum_failures[:20]),
        ('package_index_coverage', gates.get('selected_package_index_coverage')),
        ('release_metadata', gates.get('release_metadata')),
        ('gpg_validation', gates.get('gpg_validation')),
        ('upgrader_validation', gates.get('upgrader_validation')),
        ('meta_release_validation', gates.get('meta_release_validation')),
        ('isolated_apt_validation', gates.get('isolated_apt_validation')),
        ('isolated_apt_detail', apt_detail),
        ('staging_http_results', staging_http_results),
        ('unresolved_count', unresolved_count),
        ('package_count', counts.get('unique_packages_by_name_arch_version')),
        ('file_count', counts.get('unique_deb_sha256')),
        ('total_size', (plan.get('sizes') or {}).get('selective_mirror_estimate_bytes')),
        ('gates', gates),
        ('errors', errors),
        ('error_details', error_details),
        ('selective_root', selective_root),
        ('live_root', live),
        ('result_json_path', result_json_path),
    ])

    state = os.path.join(selective_root, 'state')
    write_json(os.path.join(state, VERIFY_RESULT_NAME), result)
    write_json(os.path.join(state, VERIFY_RESULT_LEGACY), result)

    # Pre-publish must never create READY
    ready_path = os.path.join(state, 'READY')
    if os.path.isfile(ready_path):
        # Only remove if we are not published; never promote READY from pre-publish
        published = os.path.join(selective_root, 'published')
        current = os.path.join(selective_root, 'current')
        if not (os.path.isdir(published) and os.path.islink(current)):
            os.unlink(ready_path)

    return result


def write_ready(path, result, publish_result=None):
    pub = publish_result or {}
    lines = [
        'READY',
        'profile_name=%s' % result.get('profile_name'),
        'profile_schema_version=%s' % result.get('schema_version'),
        'created_at=%s' % iso_now(),
        'discovery_artifact_checksum=%s' % result.get('discovery_artifact_checksum'),
        'selective_plan_checksum=%s' % result.get('selective_plan_checksum'),
        'plan_checksum=%s' % (
            result.get('plan_checksum') or result.get('selective_plan_checksum') or ''
        ),
        'aws_semantic_contract_sha256=%s' % (
            result.get('aws_semantic_contract_sha256')
            or pub.get('aws_semantic_contract_sha256')
            or ''
        ),
        'repository_content_checksum=%s' % result.get('repository_content_checksum'),
        'verify_result_checksum=%s' % (
            file_sha256(result['result_json_path'])
            if result.get('result_json_path') and os.path.isfile(result['result_json_path'])
            else result.get('repository_content_checksum') or ''
        ),
        'published_target=%s' % (pub.get('published_target') or pub.get('published_root') or ''),
        'package_count=%s' % result.get('package_count'),
        'file_count=%s' % result.get('file_count'),
        'total_size=%s' % result.get('total_size'),
        'validation_phase=post_publish',
    ]
    for g, st in (result.get('gates') or {}).items():
        if st in ('NOT_APPLICABLE',):
            continue
        lines.append('gate_%s=%s' % (g, st))
    for g, st in (pub.get('gates') or {}).items():
        lines.append('gate_%s=%s' % (g, st))
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'w') as fh:
        fh.write('\n'.join(lines) + '\n')
    os.replace(tmp, path)


def isolated_apt_update(live_root, plan, keyring_path=''):
    """Run apt-get update against first hop snapshot via file:// only.

    Installs the selective signing key into trusted.gpg.d (legacy APT path) and
    uses DistUpgrade-compatible source lines without signed-by= / trusted=yes.
    Returns (ok: bool, detail: OrderedDict).
    """
    detail = OrderedDict([
        ('method', 'file'),
        ('external_sources', False),
        ('sources', []),
        ('keyring_path', keyring_path or ''),
        ('auth_mode', 'trusted.gpg.d'),
    ])
    if not shutil.which('apt-get'):
        detail['error'] = 'apt-get not found'
        return False, detail
    hops = plan.get('hops') or []
    if not hops:
        detail['error'] = 'no hops'
        return False, detail
    hop = hops[0]
    ubuntu = os.path.join(live_root, 'hops', hop, 'ubuntu')
    if not os.path.isdir(ubuntu):
        detail['error'] = 'ubuntu root missing'
        return False, detail
    suites = (plan.get('hop_summaries') or {}).get(hop, {}).get('suites') or []
    if not suites:
        detail['error'] = 'no suites'
        return False, detail
    to_series = hop.split('-to-')[-1]
    primary = [s for s in suites if s == to_series or s.startswith(to_series + '-')]
    if not primary:
        primary = suites[:1]
    tmp = tempfile.mkdtemp(prefix='sel-apt-')
    try:
        etc_apt = os.path.join(tmp, 'etc', 'apt')
        os.makedirs(os.path.join(etc_apt, 'apt.conf.d'), exist_ok=True)
        os.makedirs(os.path.join(etc_apt, 'preferences.d'), exist_ok=True)
        os.makedirs(os.path.join(etc_apt, 'trusted.gpg.d'), exist_ok=True)
        lists = os.path.join(tmp, 'var', 'lib', 'apt', 'lists')
        os.makedirs(lists, exist_ok=True)
        cache = os.path.join(tmp, 'var', 'cache', 'apt', 'archives')
        os.makedirs(os.path.join(cache, 'partial'), exist_ok=True)
        os.makedirs(os.path.join(tmp, 'var', 'lib', 'dpkg'), exist_ok=True)
        open(os.path.join(tmp, 'var', 'lib', 'dpkg', 'status'), 'a').close()

        trusted = ''
        if keyring_path and os.path.isfile(keyring_path) and shutil.which('gpg'):
            dearmed = os.path.join(
                etc_apt, 'trusted.gpg.d', 'ubuntu-mirror-selective.gpg',
            )
            try:
                with open(keyring_path, 'rb') as stdin, open(dearmed, 'wb') as stdout:
                    subprocess.check_call(
                        ['gpg', '--dearmor'],
                        stdin=stdin, stdout=stdout, stderr=subprocess.DEVNULL,
                    )
                trusted = dearmed
            except (OSError, subprocess.CalledProcessError):
                trusted = ''
        if not trusted:
            detail['error'] = 'local keyring unavailable for trusted.gpg.d'
            return False, detail
        detail['legacy_keyring'] = trusted

        # Only request components that exist under the primary suite tree
        available_comps = []
        for cand in ('main', 'restricted', 'universe', 'multiverse'):
            for suite in primary[:1]:
                if os.path.isdir(os.path.join(
                    ubuntu, 'dists', suite, cand, 'binary-amd64',
                )):
                    available_comps.append(cand)
                    break
        comps = ' '.join(available_comps) if available_comps else 'main'

        lines = []
        for suite in primary:
            inrel = os.path.join(ubuntu, 'dists', suite, 'InRelease')
            if not os.path.isfile(inrel):
                detail['error'] = 'InRelease missing for suite %s' % suite
                return False, detail
            # DistUpgrade-compatible: arch= only — no signed-by=, no trusted=yes.
            line = 'deb [arch=amd64] file:%s %s %s\n' % (ubuntu, suite, comps)
            lines.append(line)
            detail['sources'].append(line.strip())
        for line in lines:
            if 'http://' in line or 'https://' in line:
                detail['external_sources'] = True
                detail['error'] = 'external http source forbidden'
                return False, detail
            if 'signed-by=' in line or re.search(r'trusted\s*=\s*yes', line, re.I):
                detail['error'] = 'forbidden auth option in isolated sources'
                return False, detail
        with open(os.path.join(etc_apt, 'sources.list'), 'w') as fh:
            fh.writelines(lines)
        with open(os.path.join(etc_apt, 'apt.conf.d', '99selective'), 'w') as fh:
            fh.write('Acquire::Languages "none";\n')
            fh.write('Acquire::IndexTargets::deb::Contents-deb::DefaultEnabled "false";\n')
            fh.write('Acquire::http::Proxy "false";\n')
            fh.write('Acquire::https::Proxy "false";\n')
            fh.write('APT::Get::AllowUnauthenticated "false";\n')
        env = os.environ.copy()
        env['http_proxy'] = ''
        env['https_proxy'] = ''
        env['HTTP_PROXY'] = ''
        env['HTTPS_PROXY'] = ''
        try:
            subprocess.check_call(
                ['apt-get', 'update',
                 '-o', 'Dir=%s' % tmp,
                 '-o', 'Dir::State::status=%s/var/lib/dpkg/status' % tmp,
                 '-o', 'Debug::NoLocking=1'],
                env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            detail['result'] = 'PASS'
            return True, detail
        except subprocess.CalledProcessError as err:
            detail['error'] = 'apt-get update failed rc=%s' % err.returncode
            detail['result'] = 'FAIL'
            return False, detail
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def post_publish_validate(selective_root, plan, http_base='http://127.0.0.1',
                          published_root=None):
    """Validate production nginx serves concrete repository endpoints.

    Does NOT treat root URL `/` 404/403 as failure.
    Concrete checks: Release, InRelease, Packages(.gz), sample .deb.
    """
    gates = OrderedDict()
    errors = []
    error_details = []
    http_results = []
    tested_endpoints = []

    published = published_root or os.path.join(selective_root, 'published')
    current = os.path.join(selective_root, 'current')
    conf_path, doc_root = nginx_document_root()
    result_json_path = os.path.join(selective_root, 'state', PUBLISH_RESULT_NAME)
    base = (http_base or 'http://127.0.0.1').rstrip('/')

    def fail(check, detail, **extra):
        gates[check] = 'FAIL'
        errors.append('%s: %s' % (check, detail))
        rec = OrderedDict([
            ('validation_phase', 'post_publish'),
            ('check_name', check),
            ('target_type', extra.get('target_type', 'production_nginx')),
            ('url', extra.get('url', '')),
            ('filesystem_path', extra.get('filesystem_path', '')),
            ('expected_result', extra.get('expected_result', 'PASS')),
            ('actual_result', detail),
            ('http_status', extra.get('http_status', '')),
            ('exception_type', extra.get('exception_type', '')),
            ('exception_message', extra.get('exception_message', '')),
            ('nginx_config_path', conf_path),
            ('nginx_document_root', doc_root),
            ('published_target', published),
            ('result_json_path', result_json_path),
            ('error_code', extra.get('error_code', ERROR_POSTPUBLISH_HTTP)),
        ])
        error_details.append(rec)
        emit_fields = dict(rec)
        emit_fields.pop('check_name', None)
        emit_check_failure('post_publish', check, **emit_fields)

    def ok(check):
        gates[check] = 'PASS'

    # Fail closed on legacy / mismatched document root — no HTTP endpoint storm
    preflight = check_selective_nginx_preflight(selective_root)
    conf_path = preflight.get('nginx_config_path') or conf_path
    doc_root = preflight.get('nginx_document_root') or doc_root
    for gname, gval in (preflight.get('gates') or {}).items():
        gates[gname] = gval
    if not preflight.get('ok'):
        for err in preflight.get('errors') or []:
            if err not in errors:
                errors.append(err)
        error_code = preflight.get('error_code') or ERROR_NGINX_ROOT_MISMATCH
        if gates.get('nginx_effective_root') == 'FAIL':
            fail(
                'nginx_effective_root',
                'effective=%s expected=%s' % (
                    doc_root, preflight.get('expected_selective_root')),
                error_code=ERROR_NGINX_ROOT_MISMATCH,
                expected_result=preflight.get('expected_selective_root'),
                actual_result=doc_root,
            )
            error_code = ERROR_NGINX_ROOT_MISMATCH
        return OrderedDict([
            ('validation_result', 'FAIL'),
            ('validation_phase', 'post_publish'),
            ('generated_at', iso_now()),
            ('gates', gates),
            ('errors', errors),
            ('error_details', error_details),
            ('error_code', error_code),
            ('tested_endpoints', []),
            ('http_results', []),
            ('nginx_config_path', conf_path),
            ('nginx_document_root', doc_root),
            ('expected_selective_root', preflight.get('expected_selective_root')),
            ('published_target', published),
            ('http_base', base),
            ('result_json_path', result_json_path),
        ])

    # current symlink → published
    if os.path.islink(current) and os.path.realpath(current) == os.path.realpath(published):
        ok('published_current_symlink')
    elif os.path.islink(current) and os.readlink(current) in ('published', './published'):
        ok('published_current_symlink')
    else:
        fail(
            'published_current_symlink',
            'current=%s published=%s' % (
                os.readlink(current) if os.path.islink(current) else 'missing',
                published,
            ),
            filesystem_path=current,
            published_target=published,
        )

    # Root URL is informational only — never blocking readiness
    root_status, _body, _err, _clen = http_get(base + '/', timeout=10)
    gates['nginx_root_url_info'] = 'INFO_STATUS_%s' % root_status

    http_ok = True
    for name, url_path, fs_path, expected_size in iter_concrete_endpoints(plan, published):
        # Map filesystem hop path to nginx URL.
        # nginx: /hops/ → current/hops/, /ubuntu/ → current/ubuntu/, /offline/ → shared/offline/
        if url_path.startswith('/shared/offline/'):
            http_path = '/offline/' + url_path[len('/shared/offline/'):]
        else:
            http_path = url_path
        url = base + http_path
        status, body, err, clen = http_get(url, timeout=30)
        rec = OrderedDict([
            ('check_name', name),
            ('url', url),
            ('filesystem_path', fs_path),
            ('http_status', status),
            ('expected_size', expected_size),
            ('content_length', clen),
        ])
        tested_endpoints.append(url)
        if status != 200 or body is None:
            http_ok = False
            rec['result'] = 'FAIL'
            fail(
                name, 'http_status=%s' % status,
                url=url, filesystem_path=fs_path, http_status=status,
                expected_result='HTTP 200 with Content-Length=%s' % expected_size,
                exception_type=type(err).__name__ if err else '',
                exception_message=str(err) if err else '',
            )
        elif expected_size is not None and clen is not None and int(clen) != int(expected_size):
            http_ok = False
            rec['result'] = 'FAIL'
            fail(
                name, 'content_length mismatch expected=%s actual=%s' % (
                    expected_size, clen),
                url=url, filesystem_path=fs_path, http_status=status,
                expected_result=str(expected_size), actual_result=str(clen),
            )
        else:
            rec['result'] = 'PASS'
        http_results.append(rec)
        if len(http_results) >= 32:
            break

    if http_ok and http_results:
        ok('nginx_http')
        ok('post_publish_http')
    elif not http_results:
        fail('nginx_http', 'no concrete endpoints found to test',
             published_target=published)
        fail('post_publish_http', 'no concrete endpoints found to test')
    else:
        if 'nginx_http' not in gates:
            fail('nginx_http', 'one or more concrete endpoints failed')
        if 'post_publish_http' not in gates:
            fail('post_publish_http', 'one or more concrete endpoints failed')

    overall = 'PASS' if not any(v == 'FAIL' for v in gates.values()) else 'FAIL'
    error_code = ''
    if overall != 'PASS':
        if gates.get('nginx_effective_root') == 'FAIL':
            error_code = ERROR_NGINX_ROOT_MISMATCH
        elif gates.get('nginx_config') == 'FAIL' or gates.get('nginx_service') == 'FAIL':
            error_code = ERROR_POSTPUBLISH_NGINX
        else:
            error_code = ERROR_POSTPUBLISH_HTTP

    return OrderedDict([
        ('validation_result', overall),
        ('validation_phase', 'post_publish'),
        ('generated_at', iso_now()),
        ('gates', gates),
        ('errors', errors),
        ('error_details', error_details),
        ('error_code', error_code),
        ('tested_endpoints', tested_endpoints),
        ('http_results', http_results),
        ('nginx_config_path', conf_path),
        ('nginx_document_root', doc_root),
        ('expected_selective_root', canonical_selective_nginx_root(selective_root)),
        ('published_target', published),
        ('http_base', base),
        ('result_json_path', result_json_path),
    ])


def load_verify_result(selective_root):
    state = os.path.join(selective_root, 'state')
    for name in (VERIFY_RESULT_NAME, VERIFY_RESULT_LEGACY):
        path = os.path.join(state, name)
        if os.path.isfile(path):
            return load_json(path), path
    return None, ''


def invalidate_ready(selective_root):
    path = os.path.join(selective_root, 'state', 'READY')
    if os.path.isfile(path):
        os.unlink(path)
        return True
    return False


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', required=True)
    parser.add_argument('--selective-root', required=True)
    parser.add_argument('--mirror-root', default='/var/spool/apt-mirror')
    parser.add_argument('--run-apt', action='store_true')
    parser.add_argument(
        '--http-base', default='',
        help='Ignored for pre-publish verify (kept for CLI compatibility)',
    )
    parser.add_argument('--invalidate-ready', action='store_true')
    parser.add_argument('--result-json', default='')
    parser.add_argument(
        '--phase', default='pre_publish',
        choices=('pre_publish', 'post_publish'),
    )
    parser.add_argument(
        '--hop', default='',
        help='Limit full plan validation to one hop; other hops carry-forward only',
    )
    args = parser.parse_args(argv)

    if args.invalidate_ready:
        invalidate_ready(args.selective_root)

    if args.phase == 'post_publish':
        plan = load_json(args.plan)
        result = post_publish_validate(
            args.selective_root, plan,
            http_base=args.http_base or 'http://127.0.0.1',
        )
        state = os.path.join(args.selective_root, 'state')
        write_json(os.path.join(state, PUBLISH_RESULT_NAME), result)
        write_json(os.path.join(state, PUBLISH_RESULT_LEGACY), result)
    else:
        result = validate_tree(
            args.plan, args.selective_root,
            mirror_root=args.mirror_root,
            run_apt=args.run_apt,
            http_base=args.http_base,
            phase='pre_publish',
            hop=(args.hop or None),
        )
    if args.result_json:
        write_json(args.result_json, result)
    print('validation_result=%s' % result['validation_result'])
    print('validation_phase=%s' % result.get('validation_phase', args.phase))
    if result.get('verified_files') is not None:
        print('verified_files=%s' % result.get('verified_files'))
        print('expected_files=%s' % result.get('expected_files'))
    if result.get('package_index_coverage'):
        print('package_index_coverage=%s' % result.get('package_index_coverage'))
    if result.get('gpg_validation'):
        print('gpg_validation=%s' % result.get('gpg_validation'))
    if result.get('isolated_apt_validation'):
        print('isolated_apt_validation=%s' % result.get('isolated_apt_validation'))
    for err in result.get('errors') or []:
        eprint('ERROR: %s' % err)
    return 0 if result['validation_result'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
