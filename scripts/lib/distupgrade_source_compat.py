#!/usr/bin/env python3
"""DistUpgrade SourceEntry compatibility and target-pocket provenance helpers.

Replicates Xenial ubuntu-release-upgrader DistUpgrade sourceslist.SourceEntry
option rules: only arch= and trusted= are accepted. signed-by= → invalid.

Also provides target-suite provenance helpers used by selective plan/materialize
and client pre-DRO gates (no network, no apt mutation).
"""
from __future__ import print_function

import hashlib
import os
import re
from collections import OrderedDict, defaultdict

ALLOWED_TARGET_POCKETS = ('base', 'updates', 'security', 'backports')
UNRESOLVED_TARGET_POCKET = 'UNRESOLVED_TARGET_POCKET'

# Core packages inspected for candidate pocket provenance (client gate + tests).
CORE_PROVENANCE_PACKAGES = (
    'systemd', 'systemd-sysv', 'udev', 'libsystemd0', 'libudev1', 'dbus',
    'initramfs-tools', 'initramfs-tools-core', 'initramfs-tools-bin',
    'linux-image-generic', 'linux-generic', 'linux-firmware',
    'ubuntu-minimal', 'ubuntu-server', 'ubuntu-standard',
    'apt', 'dpkg', 'libc6', 'libc-bin', 'ifupdown', 'netplan.io',
    'networkd-dispatcher', 'openssh-server',
)

INITRAMFS_DEPENDENCY_FAMILY = (
    'initramfs-tools',
    'initramfs-tools-core',
    'initramfs-tools-bin',
    'busybox-initramfs',
    'klibc-utils',
)


def distupgrade_source_entry_valid(line):
    """Replicate DistUpgrade bundled sourceslist.SourceEntry option rules."""
    result = OrderedDict([
        ('line', line.rstrip('\n')),
        ('invalid', False),
        ('disabled', False),
        ('type', ''),
        ('architectures', []),
        ('uri', ''),
        ('dist', ''),
        ('comps', []),
        ('rejected_options', []),
    ])
    raw = line.strip()
    if not raw or raw == '#':
        result['invalid'] = True
        return result
    if raw[0] == '#':
        result['disabled'] = True
        pieces = raw[1:].strip().split()
        if not pieces or pieces[0] not in ('rpm', 'rpm-src', 'deb', 'deb-src'):
            result['invalid'] = True
            return result
        raw = raw[1:]
    comment_i = raw.find('#')
    if comment_i > 0:
        raw = raw[:comment_i]
    pieces = []
    tmp = ''
    p_found = False
    space_found = False
    for ch in raw.strip():
        if ch == '[':
            if space_found:
                space_found = False
                p_found = True
                pieces.append(tmp)
                tmp = ch
            else:
                p_found = True
                tmp += ch
        elif ch == ']':
            p_found = False
            tmp += ch
        elif space_found and not ch.isspace():
            space_found = False
            pieces.append(tmp)
            tmp = ch
        elif ch.isspace() and not p_found:
            space_found = True
        else:
            tmp += ch
    if tmp:
        pieces.append(tmp)
    if len(pieces) < 3:
        result['invalid'] = True
        return result
    result['type'] = pieces[0].strip()
    if result['type'] not in ('deb', 'deb-src', 'rpm', 'rpm-src'):
        result['invalid'] = True
        return result
    idx = 1
    if pieces[1].strip().startswith('['):
        options = pieces[1].strip()[1:-1].split()
        idx = 2
        for option in options:
            if '=' not in option:
                result['invalid'] = True
                result['rejected_options'].append(option)
                continue
            key, value = option.split('=', 1)
            if key == 'arch':
                result['architectures'] = value.split(',')
            elif key == 'trusted':
                # DistUpgrade accepts trusted= but offline policy forbids trusted=yes.
                pass
            else:
                result['invalid'] = True
                result['rejected_options'].append(key)
    if idx >= len(pieces):
        result['invalid'] = True
        return result
    result['uri'] = pieces[idx].strip()
    if idx + 1 >= len(pieces):
        result['invalid'] = True
        return result
    result['dist'] = pieces[idx + 1].strip()
    result['comps'] = [p.strip() for p in pieces[idx + 2:]]
    return result


def rewrite_source_suite(line, from_series, to_series):
    """Rewrite suite token from_series* → to_series* (DistUpgrade rewrite model)."""
    parsed = distupgrade_source_entry_valid(line)
    if parsed['invalid'] or parsed['disabled']:
        return line
    dist = parsed['dist']
    if dist == from_series:
        new_dist = to_series
    elif dist.startswith(from_series + '-'):
        new_dist = to_series + dist[len(from_series):]
    else:
        return line
    # Reconstruct without signed-by; keep arch= only when present.
    opts = []
    if parsed['architectures']:
        opts.append('arch=' + ','.join(parsed['architectures']))
    prefix = 'deb'
    if opts:
        prefix = 'deb [%s]' % ' '.join(opts)
    comps = ' '.join(parsed['comps'])
    return '%s %s %s %s' % (prefix, parsed['uri'], new_dist, comps)


def generate_legacy_target_sources(mirror_repo_uri, target_suites, components,
                                   arch='amd64'):
    """Generate DistUpgrade-compatible target source lines (no signed-by)."""
    comps = components if isinstance(components, str) else ' '.join(components)
    lines = []
    for suite in target_suites:
        if arch:
            lines.append('deb [arch=%s] %s %s %s' % (arch, mirror_repo_uri, suite, comps))
        else:
            lines.append('deb %s %s %s' % (mirror_repo_uri, suite, comps))
    return lines


def _line_has_nonascii(text):
    """True if any codepoint > 127 is present (Py3.5-safe)."""
    for ch in text or '':
        if ord(ch) > 127:
            return True
    return False


def count_nonascii_comments(lines):
    """Count full-line or trailing comments that contain non-ASCII."""
    n = 0
    for line in lines or []:
        s = line.rstrip('\n')
        if not s.strip():
            continue
        if s.lstrip().startswith('#'):
            if _line_has_nonascii(s):
                n += 1
            continue
        comment_i = s.find('#')
        if comment_i > 0 and _line_has_nonascii(s[comment_i:]):
            n += 1
    return n


def read_sources_file_utf8(path):
    """Read an APT sources file as UTF-8 without using locale encoding.

    Always opens in binary mode and decodes with utf-8-sig (BOM-tolerant).
    Decoding failures are classified as FAIL_DISTUPGRADE_SOURCE_TEXT_DECODE,
    never as FAIL_DISTUPGRADE_SOURCE_INVALID.

    Returns (text_or_None, meta OrderedDict).
    """
    meta = OrderedDict([
        ('path', path),
        ('DISTUPGRADE_SOURCE_INPUT_ENCODING', 'UTF-8'),
        ('DISTUPGRADE_SOURCE_DECODE_RESULT', 'PASS'),
        ('DISTUPGRADE_SOURCE_NONASCII_COMMENT_COUNT', 0),
        ('error', ''),
        ('error_detail', ''),
        ('decode_byte_offset', None),
        ('decode_line', None),
    ])
    try:
        with open(path, 'rb') as fh:
            raw = fh.read()
    except (OSError, IOError) as exc:
        meta['DISTUPGRADE_SOURCE_DECODE_RESULT'] = 'FAIL'
        meta['error'] = 'FAIL_DISTUPGRADE_SOURCE_INVALID'
        meta['error_detail'] = 'cannot read %s: %s' % (path, exc)
        return None, meta

    if raw.startswith(b'\xef\xbb\xbf'):
        meta['DISTUPGRADE_SOURCE_INPUT_ENCODING'] = 'UTF-8-SIG'

    try:
        # utf-8-sig strips BOM when present; identical to utf-8 otherwise.
        text = raw.decode('utf-8-sig')
    except UnicodeDecodeError as exc:
        meta['DISTUPGRADE_SOURCE_DECODE_RESULT'] = 'FAIL'
        meta['error'] = 'FAIL_DISTUPGRADE_SOURCE_TEXT_DECODE'
        start = getattr(exc, 'start', None)
        meta['decode_byte_offset'] = start
        line_no = None
        if start is not None:
            line_no = raw[:start].count(b'\n') + 1
        meta['decode_line'] = line_no
        meta['error_detail'] = (
            'UTF-8 decode failed path=%s line=%s byte_offset=%s reason=%s'
            % (path, line_no, start, exc)
        )
        return None, meta

    lines = text.splitlines()
    meta['DISTUPGRADE_SOURCE_NONASCII_COMMENT_COUNT'] = count_nonascii_comments(lines)
    return text, meta


def normalize_deb_source_line(line):
    """Return ASCII-compatible deb/deb-src token line (strip trailing comment).

    Full-line comments and blanks return ''. Non-ASCII in the comment portion is
    discarded with the comment; the structural deb tokens are returned as-is.
    """
    if line is None:
        return ''
    s = line.strip()
    if not s or s.startswith('#'):
        return ''
    comment_i = s.find('#')
    if comment_i > 0:
        s = s[:comment_i].rstrip()
    if not s.startswith('deb'):
        return ''
    return s


def analyze_distupgrade_sources(lines, expected_suites=None, expected_components=None):
    """Validate source lines against DistUpgrade parser + expected target suites."""
    expected_suites = list(expected_suites or [])
    expected_components = list(expected_components or ['main', 'universe'])
    entries = []
    valid = 0
    invalid = 0
    signed_by = 0
    trusted_yes = 0
    found = OrderedDict()
    nonascii_comments = count_nonascii_comments(lines)
    for line in lines:
        s = normalize_deb_source_line(line)
        if not s:
            continue
        if 'trusted=yes' in s.replace(' ', '') or re.search(r'trusted\s*=\s*yes', s, re.I):
            trusted_yes += 1
        parsed = distupgrade_source_entry_valid(s)
        entries.append(parsed)
        if parsed['invalid']:
            invalid += 1
            if 'signed-by' in parsed['rejected_options']:
                signed_by += 1
            continue
        valid += 1
        d = parsed['dist']
        found.setdefault(d, set())
        for c in parsed['comps']:
            found[d].add(c)

    suite_results = OrderedDict()
    for suite in expected_suites:
        key = 'DISTUPGRADE_SOURCE_VALID_%s' % suite.replace('-', '_')
        suite_entries = [e for e in entries if e['dist'] == suite]
        if not suite_entries or any(e['invalid'] for e in suite_entries):
            suite_results[key] = 'FAIL'
        elif not all(c in (suite_entries[0]['comps'] or []) for c in expected_components):
            suite_results[key] = 'FAIL'
        else:
            suite_results[key] = 'PASS'

    error = ''
    if signed_by:
        error = 'FAIL_SIGNED_BY_PRESENT_IN_DISTUPGRADE_SOURCE'
    elif trusted_yes:
        error = 'FAIL_TRUSTED_YES_FORBIDDEN'
    elif expected_suites and valid != len(expected_suites):
        error = 'FAIL_DISTUPGRADE_SOURCE_COUNT_MISMATCH'
    elif any(v == 'FAIL' for v in suite_results.values()):
        error = 'FAIL_DISTUPGRADE_SOURCE_INVALID'
    elif invalid:
        error = 'FAIL_DISTUPGRADE_SOURCE_INVALID'

    return OrderedDict([
        ('valid_count', valid),
        ('invalid_count', invalid),
        ('signed_by_count', signed_by),
        ('trusted_yes_count', trusted_yes),
        ('DISTUPGRADE_VALID_SOURCE_COUNT', valid),
        ('DISTUPGRADE_INVALID_SOURCE_COUNT', invalid),
        ('DISTUPGRADE_SOURCE_NONASCII_COMMENT_COUNT', nonascii_comments),
        ('suite_results', suite_results),
        ('found_components', OrderedDict((k, sorted(v)) for k, v in sorted(found.items()))),
        ('error', error),
        ('ok', error == ''),
        ('entries', entries),
    ])


def analyze_distupgrade_sources_file(path, expected_suites=None, expected_components=None):
    """File-level DistUpgrade source validation with explicit UTF-8 decoding."""
    text, meta = read_sources_file_utf8(path)
    if text is None:
        return OrderedDict([
            ('valid_count', 0),
            ('invalid_count', 0),
            ('signed_by_count', 0),
            ('trusted_yes_count', 0),
            ('DISTUPGRADE_VALID_SOURCE_COUNT', 0),
            ('DISTUPGRADE_INVALID_SOURCE_COUNT', 0),
            ('DISTUPGRADE_SOURCE_INPUT_ENCODING', meta.get('DISTUPGRADE_SOURCE_INPUT_ENCODING')),
            ('DISTUPGRADE_SOURCE_DECODE_RESULT', meta.get('DISTUPGRADE_SOURCE_DECODE_RESULT')),
            ('DISTUPGRADE_SOURCE_NONASCII_COMMENT_COUNT',
             meta.get('DISTUPGRADE_SOURCE_NONASCII_COMMENT_COUNT', 0)),
            ('suite_results', OrderedDict()),
            ('found_components', OrderedDict()),
            ('error', meta.get('error') or 'FAIL_DISTUPGRADE_SOURCE_TEXT_DECODE'),
            ('error_detail', meta.get('error_detail', '')),
            ('decode_byte_offset', meta.get('decode_byte_offset')),
            ('decode_line', meta.get('decode_line')),
            ('path', path),
            ('ok', False),
            ('entries', []),
        ])
    result = analyze_distupgrade_sources(
        text.splitlines(),
        expected_suites=expected_suites,
        expected_components=expected_components,
    )
    result['DISTUPGRADE_SOURCE_INPUT_ENCODING'] = meta['DISTUPGRADE_SOURCE_INPUT_ENCODING']
    result['DISTUPGRADE_SOURCE_DECODE_RESULT'] = meta['DISTUPGRADE_SOURCE_DECODE_RESULT']
    result['DISTUPGRADE_SOURCE_NONASCII_COMMENT_COUNT'] = meta[
        'DISTUPGRADE_SOURCE_NONASCII_COMMENT_COUNT'
    ]
    result['path'] = path
    result['error_detail'] = ''
    result['decode_byte_offset'] = None
    result['decode_line'] = None
    return result


def pocket_from_suite(suite):
    if not suite:
        return ''
    if suite.endswith('-updates'):
        return 'updates'
    if suite.endswith('-security'):
        return 'security'
    if suite.endswith('-backports'):
        return 'backports'
    return 'base'


def series_from_suite(suite):
    if not suite:
        return ''
    for suffix in ('-updates', '-security', '-backports', '-proposed'):
        if suite.endswith(suffix):
            return suite[: -len(suffix)]
    return suite


def suite_from_url(url):
    if not url:
        return ''
    m = re.search(r'/dists/([^/]+)/', url or '')
    return m.group(1) if m else ''


def allowed_target_suites(to_series):
    return [
        to_series,
        '%s-updates' % to_series,
        '%s-security' % to_series,
        '%s-backports' % to_series,
    ]


SERIES_VERSION_HINTS = OrderedDict([
    # Match ubuntu0.XX.04.N / +ubuntuXX.04 / ~XX.04 / :XX.04 / .XX.04. / series name.
    ('xenial', re.compile(
        r'(?:^|[~:.])16\.04(?:\.|$)|ubuntu0?\.?16\.04|\+ubuntu16\.04|xenial', re.I)),
    ('bionic', re.compile(
        r'(?:^|[~:.])18\.04(?:\.|$)|ubuntu0?\.?18\.04|\+ubuntu18\.04|bionic', re.I)),
    ('focal', re.compile(
        r'(?:^|[~:.])20\.04(?:\.|$)|ubuntu0?\.?20\.04|\+ubuntu20\.04|focal', re.I)),
    ('jammy', re.compile(
        r'(?:^|[~:.])22\.04(?:\.|$)|ubuntu0?\.?22\.04|\+ubuntu22\.04|jammy', re.I)),
    ('noble', re.compile(
        r'(?:^|[~:.])24\.04(?:\.|$)|ubuntu0?\.?24\.04|\+ubuntu24\.04|noble', re.I)),
])


def sha_mapped_suites(sha_to_suite, sha):
    """Return every suite a SHA maps to.

    ``sha_to_suite`` may be a first-wins ``sha -> suite`` dict (legacy) or
    ``sha -> [suite, ...]`` when the same physical object appears in multiple
    release indexes (cross-hop shared packages).
    """
    if not sha_to_suite or not sha:
        return []
    key = (sha or '').strip().lower()
    val = sha_to_suite.get(key)
    if val is None and key != sha:
        val = sha_to_suite.get(sha)
    if val is None:
        return []
    if isinstance(val, (list, tuple)):
        out = []
        for item in val:
            if item and item not in out:
                out.append(item)
        return out
    return [val] if val else []


def _suite_candidates(row, preferred_series, sha_to_suite):
    """Collect ordered (suite, reason) candidates for a package row."""
    sha_to_suite = sha_to_suite or {}
    explicit = (row.get('suite') or row.get('source_suite') or '').strip()
    url = (row.get('original_url') or row.get('final_url') or row.get('source_url') or '')
    host = (row.get('repository_host') or '')
    if not host and url:
        m = re.match(r'https?://([^/]+)/', url)
        host = m.group(1) if m else ''

    candidates = []
    if explicit:
        candidates.append((explicit, 'discovery_suite'))
    url_suite = suite_from_url(url)
    if url_suite:
        candidates.append((url_suite, 'url_dists'))
    if host == 'security.ubuntu.com' and preferred_series:
        candidates.append(('%s-security' % preferred_series, 'repository_host_security'))
    sha = (row.get('sha256') or '').strip().lower()
    for mapped in sha_mapped_suites(sha_to_suite, sha):
        candidates.append((mapped, 'packages_index_sha256'))
    return candidates


def resolve_target_suite(row, to_series, sha_to_suite=None):
    """Resolve target suite/pocket for a package row. Never invent base default.

    Returns OrderedDict with source_suite, source_pocket, resolved_from, error.
    """
    sha_to_suite = sha_to_suite or {}
    allowed = set(allowed_target_suites(to_series))

    for suite, reason in _suite_candidates(row, to_series, sha_to_suite):
        if suite == 'release':
            suite = to_series
        series = series_from_suite(suite)
        if series != to_series:
            # Source-series suites are not target provenance.
            continue
        if suite not in allowed:
            continue
        return OrderedDict([
            ('source_suite', suite),
            ('source_pocket', pocket_from_suite(suite)),
            ('resolved_from', reason),
            ('role', 'target'),
            ('error', ''),
        ])

    return OrderedDict([
        ('source_suite', ''),
        ('source_pocket', ''),
        ('resolved_from', ''),
        ('role', ''),
        ('error', UNRESOLVED_TARGET_POCKET),
    ])


def resolve_hop_suite(row, from_series, to_series, sha_to_suite=None):
    """Resolve suite for a hop package: target pocket, else source-series omit.

    Never auto-assigns blank suite to target base. Source-series rows (e.g.
    Xenial 16.04 versions captured beside Bionic upgrades) are returned with
    role=source_series so the plan can omit them from target indexes without
    FAIL_UNRESOLVED for expected pre-upgrade residue.
    """
    target = resolve_target_suite(row, to_series, sha_to_suite=sha_to_suite)
    if not target.get('error'):
        return target

    sha_to_suite = sha_to_suite or {}
    allowed_source = set(allowed_target_suites(from_series)) if from_series else set()

    for suite, reason in _suite_candidates(row, from_series, sha_to_suite):
        if suite == 'release':
            suite = from_series
        series = series_from_suite(suite)
        if from_series and series != from_series:
            continue
        if allowed_source and suite not in allowed_source:
            continue
        # Identical pool content often exists in both the hop's source-series
        # index and the target-series index. A SHA hit on from_series alone is
        # not proof this discovery row is pre-upgrade residue — fall through
        # so a target-series SHA / archive-URL pocket can still win.
        if reason == 'packages_index_sha256' and series == from_series:
            continue
        return OrderedDict([
            ('source_suite', suite),
            ('source_pocket', pocket_from_suite(suite)),
            ('resolved_from', reason),
            ('role', 'source_series'),
            ('error', ''),
        ])

    ver = (row.get('version') or '') + ' ' + (row.get('filename') or '')
    url = (row.get('original_url') or row.get('final_url') or row.get('source_url') or '').strip()
    sha = (row.get('sha256') or '').strip().lower()

    # SHA maps only to a series that is neither this hop's source nor target
    # (e.g. xenial residue captured on a later hop). Shared packages whose SHA
    # is in from_series (and possibly to_series) must not be omitted here.
    mapped_suites = sha_mapped_suites(sha_to_suite, sha)
    target_mapped = [
        s for s in mapped_suites if series_from_suite(s) == to_series
    ]
    if target_mapped:
        suite = target_mapped[0]
        return OrderedDict([
            ('source_suite', suite),
            ('source_pocket', pocket_from_suite(suite)),
            ('resolved_from', 'packages_index_sha256'),
            ('role', 'target'),
            ('error', ''),
        ])
    older_mapped = [
        s for s in mapped_suites
        if series_from_suite(s) not in (from_series, to_series, '')
    ]
    if older_mapped:
        mapped = older_mapped[0]
        return OrderedDict([
            ('source_suite', mapped),
            ('source_pocket', pocket_from_suite(mapped)),
            ('resolved_from', 'non_target_series_sha256'),
            ('role', 'source_series'),
            ('error', ''),
        ])

    # Version hint: any non-target series marker → omit (never invent target base).
    for series, hint in SERIES_VERSION_HINTS.items():
        if series == to_series:
            continue
        if hint.search(ver):
            return OrderedDict([
                ('source_suite', series),
                ('source_pocket', 'base'),
                ('resolved_from', 'source_series_version_hint'),
                ('role', 'source_series'),
                ('error', ''),
            ])

    # Target-series version marker but SHA absent from current Packages (superseded
    # pool object). Keep downloadable archive URL under updates — not blank→base.
    target_hint = SERIES_VERSION_HINTS.get(to_series)
    host = (row.get('repository_host') or '')
    if not host and url:
        m = re.match(r'https?://([^/]+)/', url)
        host = m.group(1) if m else ''
    if (
        target_hint and target_hint.search(ver)
        and host in ('archive.ubuntu.com', 'security.ubuntu.com', 'ports.ubuntu.com')
        and (not sha or sha not in sha_to_suite)
    ):
        suite = (
            '%s-security' % to_series
            if host == 'security.ubuntu.com'
            else '%s-updates' % to_series
        )
        return OrderedDict([
            ('source_suite', suite),
            ('source_pocket', pocket_from_suite(suite)),
            ('resolved_from', 'target_series_version_hint_unindexed'),
            ('role', 'target'),
            ('error', ''),
        ])

    # Discovery residue with no downloadable URL and no index SHA cannot be
    # placed into a target pocket; omit as source_series rather than inventing base.
    if from_series and not url and (not sha or sha not in sha_to_suite):
        return OrderedDict([
            ('source_suite', from_series),
            ('source_pocket', 'base'),
            ('resolved_from', 'source_series_orphan_no_url'),
            ('role', 'source_series'),
            ('error', ''),
        ])

    # Archive/security URL whose SHA left current Packages (superseded pool
    # object), OR whose SHA is indexed only in this hop's source series (the
    # identical .deb is reused by the target release). Keep under
    # updates/security — never invent blank→target base, and never omit a
    # discovery-selected shared package as source-series residue.
    from_only_sha = bool(
        mapped_suites
        and from_series
        and all(series_from_suite(s) == from_series for s in mapped_suites)
    )
    if (
        host in ('archive.ubuntu.com', 'security.ubuntu.com', 'ports.ubuntu.com')
        and sha
        and (sha not in sha_to_suite or from_only_sha)
    ):
        suite = (
            '%s-security' % to_series
            if host == 'security.ubuntu.com'
            else '%s-updates' % to_series
        )
        return OrderedDict([
            ('source_suite', suite),
            ('source_pocket', pocket_from_suite(suite)),
            ('resolved_from', (
                'shared_source_series_sha256_target_pocket' if from_only_sha
                else 'stale_archive_url_target_pocket'
            )),
            ('role', 'target'),
            ('error', ''),
        ])

    return OrderedDict([
        ('source_suite', ''),
        ('source_pocket', ''),
        ('resolved_from', ''),
        ('role', ''),
        ('error', UNRESOLVED_TARGET_POCKET),
    ])


def build_sha_to_suite_from_packages_indexes(ubuntu_root, suites, arch='amd64'):
    """Build sha256 → suite map from existing Packages indexes under ubuntu_root."""
    mapping = {}
    for suite in suites:
        for component in ('main', 'universe', 'restricted', 'multiverse'):
            for name in ('Packages', 'Packages.gz'):
                path = os.path.join(
                    ubuntu_root, 'dists', suite, component, 'binary-%s' % arch, name,
                )
                if not os.path.isfile(path):
                    continue
                text = _read_packages_text(path)
                for sha in re.findall(r'^SHA256:\s*([0-9a-fA-F]{64})\s*$', text, re.M):
                    sha = sha.lower()
                    # Prefer first seen; caller may scan pockets in priority order.
                    mapping.setdefault(sha, suite)
    return mapping


def _read_packages_text(path):
    import gzip
    with open(path, 'rb') as fh:
        data = fh.read()
    if path.endswith('.gz') or data[:2] == b'\x1f\x8b':
        data = gzip.decompress(data)
    return data.decode('utf-8', 'replace')


def validate_target_suite_index_diversity(ubuntu_root, target_suites, arch='amd64',
                                          components=('main', 'universe')):
    """Fail when all target suite Packages indexes share one identical SHA256 set."""
    sha_by_suite = OrderedDict()
    for suite in target_suites:
        digests = []
        for component in components:
            path = os.path.join(
                ubuntu_root, 'dists', suite, component, 'binary-%s' % arch, 'Packages',
            )
            if not os.path.isfile(path):
                digests.append('')
                continue
            h = hashlib.sha256()
            with open(path, 'rb') as fh:
                for chunk in iter(lambda: fh.read(1024 * 1024), b''):
                    h.update(chunk)
            digests.append(h.hexdigest())
        sha_by_suite[suite] = '|'.join(digests)

    values = [v for v in sha_by_suite.values() if v and set(v.split('|')) != {''}]
    identical = len(values) >= 2 and len(set(values)) == 1 and len(values) == len(target_suites)
    detail = OrderedDict()
    for suite, digest in sha_by_suite.items():
        detail['TARGET_SUITE_INDEX_SHA256_%s' % suite.replace('-', '_')] = digest
    detail['TARGET_SUITE_INDEX_DIVERSITY'] = (
        'FAIL_TARGET_SUITE_INDEXES_IDENTICAL' if identical else 'PASS'
    )
    detail['ok'] = not identical
    return detail


def validate_pocket_components(ubuntu_root, target_suites, expected_components,
                               arch='amd64', allow_empty_backports=True):
    """Ensure each target pocket Packages lists expected components (non-empty).

    updates/security/base empty → FAIL. backports may be empty when discovery
    captured no backports payloads (allow_empty_backports=True).
    """
    rows = []
    ok = True
    error = ''
    for suite in target_suites:
        present = []
        is_backports = suite.endswith('-backports')
        for component in expected_components:
            path = os.path.join(
                ubuntu_root, 'dists', suite, component, 'binary-%s' % arch, 'Packages',
            )
            if not os.path.isfile(path):
                if allow_empty_backports and is_backports:
                    rows.append(OrderedDict([
                        ('TARGET_POCKET', suite),
                        ('COMPONENTS', component),
                        ('RESULT', 'PASS'),
                        ('reason', 'empty_backports_allowed_missing_index'),
                    ]))
                    continue
                ok = False
                error = error or 'FAIL_TARGET_POCKET_COMPONENT_MISMATCH'
                rows.append(OrderedDict([
                    ('TARGET_POCKET', suite),
                    ('COMPONENTS', ','.join(expected_components)),
                    ('RESULT', 'FAIL'),
                    ('reason', 'missing_packages_index:%s' % component),
                ]))
                continue
            size = os.path.getsize(path)
            with open(path, 'r', encoding='utf-8', errors='replace') as fh:
                text = fh.read()
            has_pkg = 'Package:' in text
            if size == 0 or not has_pkg:
                if allow_empty_backports and is_backports:
                    rows.append(OrderedDict([
                        ('TARGET_POCKET', suite),
                        ('COMPONENTS', component),
                        ('RESULT', 'PASS'),
                        ('reason', 'empty_backports_allowed'),
                    ]))
                    continue
                ok = False
                error = error or 'FAIL_TARGET_POCKET_COMPONENT_EMPTY'
                rows.append(OrderedDict([
                    ('TARGET_POCKET', suite),
                    ('COMPONENTS', component),
                    ('RESULT', 'FAIL'),
                    ('reason', 'empty_component'),
                ]))
            else:
                present.append(component)
        if set(present) >= set(expected_components):
            rows.append(OrderedDict([
                ('TARGET_POCKET', suite),
                ('COMPONENTS', ','.join(expected_components)),
                ('RESULT', 'PASS'),
                ('reason', ''),
            ]))
        elif is_backports and allow_empty_backports:
            pass
        elif not any(r['TARGET_POCKET'] == suite and r['RESULT'] == 'FAIL' for r in rows):
            ok = False
            error = error or 'FAIL_TARGET_POCKET_COMPONENT_MISMATCH'
            rows.append(OrderedDict([
                ('TARGET_POCKET', suite),
                ('COMPONENTS', ','.join(expected_components)),
                ('RESULT', 'FAIL'),
                ('reason', 'component_mismatch'),
            ]))
    return OrderedDict([
        ('ok', ok),
        ('error', error),
        ('rows', rows),
    ])


def kernel_abi_from_image_name(name):
    """Extract ABI from linux-image-ABI-generic style names."""
    m = re.match(r'^linux-image-(\d+\.\d+\.\d+-\d+)-generic$', name or '')
    return m.group(1) if m else ''


def validate_kernel_package_family(package_names, abi):
    """Require image/modules/modules-extra/headers family for one ABI."""
    required = [
        'linux-image-%s-generic' % abi,
        'linux-modules-%s-generic' % abi,
        'linux-modules-extra-%s-generic' % abi,
        'linux-headers-%s' % abi,
        'linux-headers-%s-generic' % abi,
    ]
    names = set(package_names or [])
    missing = [p for p in required if p not in names]
    return OrderedDict([
        ('TARGET_KERNEL_ABI', abi),
        ('required', required),
        ('missing', missing),
        ('TARGET_KERNEL_PACKAGE_FAMILY', 'PASS' if not missing else 'FAIL'),
        ('ok', not missing),
    ])


def validate_initramfs_dependency_family(package_names):
    names = set(package_names or [])
    missing = [p for p in INITRAMFS_DEPENDENCY_FAMILY if p not in names]
    return OrderedDict([
        ('required', list(INITRAMFS_DEPENDENCY_FAMILY)),
        ('missing', missing),
        ('TARGET_KERNEL_INITRAMFS_DEPENDENCY_FAMILY', 'PASS' if not missing else 'FAIL'),
        ('ok', not missing),
    ])


def count_packages_by_pocket(rows, to_series):
    counts = OrderedDict([
        ('TARGET_PACKAGE_TOTAL', 0),
        ('TARGET_PACKAGE_POCKET_BIONIC', 0),
        ('TARGET_PACKAGE_POCKET_UPDATES', 0),
        ('TARGET_PACKAGE_POCKET_SECURITY', 0),
        ('TARGET_PACKAGE_POCKET_BACKPORTS', 0),
        ('TARGET_PACKAGE_POCKET_UNRESOLVED', 0),
    ])
    # Generic keys as well
    pocket_keys = {
        'base': 'TARGET_PACKAGE_POCKET_BIONIC',
        'updates': 'TARGET_PACKAGE_POCKET_UPDATES',
        'security': 'TARGET_PACKAGE_POCKET_SECURITY',
        'backports': 'TARGET_PACKAGE_POCKET_BACKPORTS',
    }
    for row in rows:
        counts['TARGET_PACKAGE_TOTAL'] += 1
        pocket = (row.get('source_pocket') or row.get('pocket') or '').strip()
        suite = (row.get('source_suite') or row.get('suite') or '').strip()
        if not pocket and suite:
            pocket = pocket_from_suite(suite)
        if not suite and not pocket:
            counts['TARGET_PACKAGE_POCKET_UNRESOLVED'] += 1
            continue
        key = pocket_keys.get(pocket)
        if key:
            counts[key] += 1
        else:
            counts['TARGET_PACKAGE_POCKET_UNRESOLVED'] += 1
    return counts


def line_has_forbidden_auth(line):
    """Return error token if line uses forbidden apt auth shortcuts."""
    if re.search(r'trusted\s*=\s*yes', line or '', re.I):
        return 'FAIL_TRUSTED_YES_FORBIDDEN'
    if re.search(r'AllowUnauthenticated\s*=\s*true', line or '', re.I):
        return 'FAIL_ALLOW_UNAUTHENTICATED_FORBIDDEN'
    if 'signed-by=' in (line or ''):
        return 'FAIL_SIGNED_BY_PRESENT_IN_DISTUPGRADE_SOURCE'
    return ''
