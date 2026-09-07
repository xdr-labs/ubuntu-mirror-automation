#!/usr/bin/env python3
"""Phase 2 Ubuntu prerequisite dependency closure and artifact builder.

Reuses Debian field parsers in xenial_bionic_upgrade_analysis.py
(parse_dep_field / parse_packages_index / load_suite_packages). Phase 2
candidate selection, version constraints, and authoritative Noble lookup
live here so OS-hop last-wins loading is unchanged.

Inspects ACPS py3-apt-packages as root requirements, resolves recursive
Depends/Pre-Depends against Noble metadata, and builds a separate
compatibility artifact. Never modifies ACPS payloads. The DP runtime never
talks to Ubuntu archives; extra packages are materialized during Mirror
Download and Prepare.
"""
from __future__ import print_function, unicode_literals

import argparse
import gzip
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from collections import OrderedDict, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import xenial_bionic_upgrade_analysis as xba  # noqa: E402

try:
    import selective_mirror as sm  # noqa: E402
except ImportError:  # pragma: no cover
    sm = None

PHASE2_PREREQ_FIELDS = ('Pre-Depends', 'Depends')
PHASE2_DEFAULT_SUITES = (
    'noble',
    'noble-updates',
    'noble-security',
    'noble-backports',
)
PHASE2_DEFAULT_COMPONENTS = ('main', 'restricted', 'universe', 'multiverse')
PROTECTED_PACKAGES = (
    'python3-gevent',
    'python3-kazoo',
    'python3-pyinotify',
    'aella-da-services',
    'aella-da-cli',
    'aella-uvp-2404',
)
VIRTUAL_OR_BASE_SKIP = frozenset((
    'libc6', 'libgcc-s1', 'libstdc++6', 'base-files', 'dpkg',
    'python3', 'python3-minimal', 'python3.12', 'python3.12-minimal',
))
ARTIFACT_NAME = 'phase2-ubuntu-prerequisites.tar.gz'
MANIFEST_NAME = 'phase2-ubuntu-prerequisites.manifest.json'
STATE_NAME = 'phase2-ubuntu-prerequisites.state'
INSTALL_ORDER_NAME = 'install-order.txt'
DEFAULT_ARCHIVE_BASE = 'http://archive.ubuntu.com/ubuntu'
DEFAULT_SECURITY_BASE = 'http://security.ubuntu.com/ubuntu'
SHA256_HEX_RE = re.compile(r'^[0-9a-fA-F]{64}$')
REQUIRED_INDEX_FIELDS = (
    'Package', 'Version', 'Architecture', 'Filename', 'SHA256', 'Size',
)
# Ubuntu apt pin: archive/updates/security are 500; backports are 100
# (NotAutomatic). Higher rank wins only among equal Debian versions.
SUITE_PIN = {
    'noble': 500,
    'noble-updates': 500,
    'noble-security': 500,
    'noble-backports': 100,
}
SUITE_TIE_RANK = {
    'noble-security': 3,
    'noble-updates': 2,
    'noble': 1,
    'noble-backports': 0,
}
CONSTRAINT_OPS = {
    '>=': 'ge',
    '<=': 'le',
    '=': 'eq',
    '<<': 'lt',
    '>>': 'gt',
}


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def dump_json(obj, path=None):
    text = json.dumps(obj, indent=2, sort_keys=True, separators=(',', ': ')) + '\n'
    if path:
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(path, 'w') as fh:
            fh.write(text)
    return text


def parse_control_text(text):
    if sm is not None:
        return sm.parse_control_text(text)
    fields = OrderedDict()
    key = None
    for line in text.splitlines():
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


def _control_from_deb_filename(name):
    """Best-effort Package/Version/Arch from a .deb filename."""
    base = os.path.basename(name)
    if base.endswith('.deb'):
        base = base[:-4]
    m = re.match(r'^(.+)_([^_]+)_([^_]+)$', base)
    if not m:
        return OrderedDict([('Package', base)])
    return OrderedDict([
        ('Package', m.group(1)),
        ('Version', m.group(2)),
        ('Architecture', m.group(3)),
    ])


def inspect_one_deb(path, source_label='acps_deb'):
    """Read Package/Depends metadata from one .deb. Never modifies the file."""
    fn = os.path.basename(path)
    fields = _control_from_deb_filename(fn)
    sidecar = path + '.control'
    if os.path.isfile(sidecar):
        with open(sidecar, 'r') as fh:
            fields = parse_control_text(fh.read())
    elif sm is not None:
        try:
            fields = sm.parse_deb_control(path)
        except Exception:
            fields = _control_from_deb_filename(fn)
    name = fields.get('Package') or _control_from_deb_filename(fn).get('Package')
    return OrderedDict([
        ('package', name),
        ('version', fields.get('Version', '')),
        ('architecture', fields.get('Architecture', '')),
        ('depends', fields.get('Depends', '')),
        ('pre_depends', fields.get('Pre-Depends', '')),
        ('provides', fields.get('Provides', '')),
        ('filename', fn),
        ('path', path),
        ('source', source_label),
    ])


def inspect_deb_paths(paths):
    """Inspect extra ACPS/Aella .deb files as additional closure roots.

    Used for published files such as aella-uvp-*.deb / aella-da-*.deb so
    their Ubuntu Depends (for example python3-openssl) enter the recursive
    closure. Original files are never modified or repacked.
    """
    roots = []
    for path in paths or []:
        if not path:
            continue
        if os.path.isdir(path):
            for dirpath, _dns, filenames in os.walk(path):
                for fn in filenames:
                    if fn.endswith('.deb'):
                        roots.append(
                            inspect_one_deb(
                                os.path.join(dirpath, fn),
                                source_label='acps_extra_deb',
                            )
                        )
            continue
        if os.path.isfile(path):
            roots.append(inspect_one_deb(path, source_label='acps_extra_deb'))
    roots.sort(key=lambda r: r.get('package') or '')
    return roots


def collect_phase2_roots(source, extra_debs=None, work_dir=None):
    """ACPS py3-apt roots plus optional extra Aella/UVP .deb metadata."""
    by_name = OrderedDict()
    for rec in inspect_acps_py3_apt_packages(source, work_dir=work_dir):
        name = rec.get('package')
        if name:
            by_name[name] = rec
    for rec in inspect_deb_paths(extra_debs):
        name = rec.get('package')
        if name:
            by_name[name] = rec
    return list(by_name.values())


def extra_debs_from_args(args):
    raw = getattr(args, 'extra_deb', None) or []
    if isinstance(raw, str):
        return [p for p in raw.split(',') if p]
    return [p for p in raw if p]


_TAR_SPECIAL_MEMBER_TYPES = frozenset([
    tarfile.BLKTYPE,
    tarfile.CHRTYPE,
    tarfile.FIFOTYPE,
])
if hasattr(tarfile, 'SOCKTYPE'):
    _TAR_SPECIAL_MEMBER_TYPES = _TAR_SPECIAL_MEMBER_TYPES | {tarfile.SOCKTYPE}


def _normalized_tar_member_path(name):
    """Return cleaned member path or raise ValueError for unsafe names."""
    cleaned = name.rstrip('/')
    if cleaned.startswith('/'):
        raise ValueError('absolute_path=%s' % name)
    if cleaned.startswith('./'):
        cleaned = cleaned[2:]
        if cleaned.startswith('/'):
            raise ValueError('absolute_path=%s' % name)
    parts = [p for p in cleaned.split('/') if p not in ('', '.')]
    if any(p == '..' for p in parts):
        raise ValueError('path_traversal=%s' % name)
    return cleaned


def _reject_unsafe_tar_member(member):
    if member.issym() or member.islnk():
        raise ValueError('link_member=%s' % member.name)
    if member.type in _TAR_SPECIAL_MEMBER_TYPES:
        raise ValueError(
            'special_member=%s type=%s' % (member.name, member.type),
        )
    mode = member.mode or 0
    if mode & (stat.S_ISUID | stat.S_ISGID):
        raise ValueError('setuid_setgid=%s' % member.name)


def _is_allowed_acps_sidecar_member(cleaned):
    """Allow top-level <pkg>.deb.control metadata sidecars in ACPS bundles."""
    return (
        '/' not in cleaned
        and cleaned.endswith('.deb.control')
        and not cleaned.startswith('.')
    )


def _is_allowed_acps_nested_archive_member(cleaned):
    """Allow the nested py3-apt archive inside aelladeb_py3_common.tar.gz."""
    return cleaned == 'py3-apt-packages.tar.gz'


def _is_allowed_py3_apt_deb_member(cleaned):
    """Allow debs/<base>.deb (prereq artifact) or top-level <base>.deb (ACPS)."""
    if cleaned.startswith('debs/') and cleaned.count('/') == 1 and cleaned.endswith('.deb'):
        base = cleaned.split('/', 1)[1]
        return bool(base) and '/' not in base and not base.startswith('.')
    if '/' not in cleaned and cleaned.endswith('.deb'):
        return bool(cleaned) and not cleaned.startswith('.')
    return False


def _safe_tar_extract_target(extract_dir, cleaned):
    dest_real = os.path.realpath(extract_dir)
    target = os.path.join(extract_dir, cleaned)
    parent = os.path.dirname(target)
    os.makedirs(parent, exist_ok=True)
    parent_real = os.path.realpath(parent)
    if not (parent_real == dest_real or parent_real.startswith(dest_real + os.sep)):
        raise ValueError('extract_escape=%s' % cleaned)
    return target


def _safe_tar_extract_file_member(tf, member, extract_dir):
    cleaned = _normalized_tar_member_path(member.name)
    _reject_unsafe_tar_member(member)
    if not member.isreg() and not member.isfile():
        raise ValueError('unexpected_type=%s' % member.name)
    target = _safe_tar_extract_target(extract_dir, cleaned)
    src = tf.extractfile(member)
    if src is None:
        raise ValueError('extract_missing=%s' % member.name)
    with open(target, 'wb') as out:
        shutil.copyfileobj(src, out)
    return cleaned


def safe_extract_py3_apt_archive(tf, extract_dir, ignore_members=None, strict=True):
    """Extract only validated .deb members from a tar archive.

    Allows regular files under debs/*.deb (phase2 artifact layout) and
    top-level *.deb (ACPS py3-apt-packages layout). Rejects ../, absolute
    paths, symlinks, hardlinks, devices, FIFOs, sockets, setuid/setgid,
    duplicate names, and path escapes. Optional ignore_members skips
    non-deb file entries (e.g. manifest sidecars in verify_built_artifact).
    When strict is False, non-deb regular files are skipped instead of
    rejected (ACPS bundles may include harmless sidecar metadata).
    """
    ignore = set(ignore_members or ())
    os.makedirs(extract_dir, exist_ok=True)
    seen = set()
    extracted = []
    for member in tf.getmembers():
        name = member.name
        if name in seen:
            raise ValueError('duplicate_member=%s' % name)
        seen.add(name)
        cleaned = _normalized_tar_member_path(name)
        _reject_unsafe_tar_member(member)
        if member.isdir():
            if cleaned in ('', '.') or not cleaned:
                continue
            if cleaned == 'debs':
                os.makedirs(os.path.join(extract_dir, 'debs'), exist_ok=True)
            else:
                raise ValueError('unexpected_dir=%s' % name)
            continue
        if cleaned in ignore:
            continue
        allowed = _is_allowed_py3_apt_deb_member(cleaned)
        if not strict:
            allowed = (
                allowed
                or _is_allowed_acps_sidecar_member(cleaned)
                or _is_allowed_acps_nested_archive_member(cleaned)
            )
        if not allowed:
            if not strict and (member.isreg() or member.isfile()):
                continue
            raise ValueError('unexpected_member=%s' % name)
        extracted.append(_safe_tar_extract_file_member(tf, member, extract_dir))
    return extracted


def _validate_prereq_artifact_members(members):
    allowed_files = {MANIFEST_NAME, INSTALL_ORDER_NAME}
    seen = set()
    for member in members:
        name = member.name
        if name in seen:
            raise ValueError('duplicate_member=%s' % name)
        seen.add(name)
        cleaned = _normalized_tar_member_path(name)
        _reject_unsafe_tar_member(member)
        if member.isdir():
            if cleaned != 'debs':
                raise ValueError('unexpected_dir=%s' % name)
            continue
        if not member.isreg() and not member.isfile():
            raise ValueError('unexpected_type=%s' % name)
        if cleaned in allowed_files:
            continue
        if not _is_allowed_py3_apt_deb_member(cleaned):
            raise ValueError('unexpected_member=%s' % name)


def _safe_extract_prereq_non_deb_files(tf, extract_dir, names):
    wanted = set(names)
    extracted = []
    for member in tf.getmembers():
        cleaned = _normalized_tar_member_path(member.name)
        if cleaned not in wanted:
            continue
        extracted.append(_safe_tar_extract_file_member(tf, member, extract_dir))
    missing = wanted - set(extracted)
    if missing:
        raise ValueError('missing_members=%s' % ','.join(sorted(missing)))
    return extracted


def inspect_acps_py3_apt_packages(source, work_dir=None):
    """Return root package metadata from an ACPS py3-apt-packages payload.

    ``source`` may be a .tar.gz, a directory of .deb files, or a directory
    containing py3-apt-packages.tar.gz. Original ACPS files are never modified.
    """
    cleanup = None
    roots = []
    try:
        if os.path.isfile(source) and tarfile.is_tarfile(source):
            extract_dir = work_dir or tempfile.mkdtemp(prefix='phase2-py3-apt-')
            if work_dir is None:
                cleanup = extract_dir
            with tarfile.open(source, 'r:*') as tf:
                safe_extract_py3_apt_archive(tf, extract_dir, strict=False)
            source = extract_dir
            inner = os.path.join(source, 'py3-apt-packages.tar.gz')
            if os.path.isfile(inner):
                return inspect_acps_py3_apt_packages(inner, work_dir=work_dir)
        elif os.path.isdir(source):
            inner = os.path.join(source, 'py3-apt-packages.tar.gz')
            if os.path.isfile(inner):
                return inspect_acps_py3_apt_packages(inner, work_dir=work_dir)
        else:
            raise IOError('ACPS py3-apt source not found: %s' % source)

        for dirpath, _dns, filenames in os.walk(source):
            for fn in filenames:
                if not fn.endswith('.deb'):
                    continue
                roots.append(
                    inspect_one_deb(
                        os.path.join(dirpath, fn),
                        source_label='acps_py3_apt_packages',
                    )
                )
        roots.sort(key=lambda r: r.get('package') or '')
        return roots
    finally:
        if cleanup:
            shutil.rmtree(cleanup, ignore_errors=True)


def roots_as_index(roots):
    """Turn inspected ACPS roots into a mini package index for closure."""
    packages = OrderedDict()
    for rec in roots:
        name = rec.get('package')
        if not name:
            continue
        stanza = OrderedDict([
            ('Package', name),
            ('Version', rec.get('version') or ''),
            ('Architecture', rec.get('architecture') or ''),
            ('Depends', rec.get('depends') or ''),
            ('Pre-Depends', rec.get('pre_depends') or ''),
            ('Provides', rec.get('provides') or ''),
            ('_suite', 'acps'),
            ('_component', 'acps'),
            ('_source', rec.get('source') or 'acps'),
        ])
        packages[name] = stanza
    return packages


def load_noble_packages(ubuntu_root, suites=None, components=None, arch='amd64'):
    suites = suites or PHASE2_DEFAULT_SUITES
    components = components or PHASE2_DEFAULT_COMPONENTS
    return xba.load_suite_packages(ubuntu_root, suites, components, arch=arch)


def merge_package_indexes(*indexes):
    """Later indexes override earlier ones (caller puts preferred last)."""
    merged = OrderedDict()
    for idx in indexes:
        if not idx:
            continue
        merged.update(idx)
    return merged


def _dpkg_compare_versions(left, op, right):
    """Debian version compare via dpkg. True when the relation holds."""
    try:
        rc = subprocess.call(
            ['dpkg', '--compare-versions', str(left), op, str(right)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        raise RuntimeError('dpkg --compare-versions is required for Phase 2 candidate policy')
    return rc == 0


def parse_version_constraint(constraint):
    """Return (op_token, version) or None when unconstrained.

    Malformed constraints fail closed (empty tuple marker).
    """
    text = (constraint or '').strip()
    if not text:
        return None
    m = re.match(r'^(<<|<=|>=|>>|=|!=)\s*(\S+)$', text)
    if not m:
        return ('invalid', text)
    return (m.group(1), m.group(2))


def version_satisfies_constraint(version, constraint):
    parsed = parse_version_constraint(constraint)
    if parsed is None:
        return True
    op, other = parsed
    if op == 'invalid' or not version:
        return False
    if op == '!=':
        return not _dpkg_compare_versions(version, 'eq', other)
    dpkg_op = CONSTRAINT_OPS.get(op)
    if not dpkg_op:
        return False
    return _dpkg_compare_versions(version, dpkg_op, other)


def parse_packages_stanzas(text):
    """Yield Packages stanzas, preserving folded field continuations.

    Debian Packages indexes fold long Depends/Provides onto continuation
    lines. Dropping those lines would truncate virtual Provides and break
    provider resolution. OS-hop last-wins loading is unchanged.
    """
    if sm is not None:
        for stanza in sm.iter_packages_stanzas(text):
            yield stanza
        return
    cur = OrderedDict()
    key = None
    for line in text.splitlines():
        if not line.strip():
            if cur:
                yield cur
                cur = OrderedDict()
                key = None
            continue
        if key and line[:1] in ' \t':
            cur[key] = (cur.get(key, '') + ' ' + line.strip()).strip()
            continue
        if ':' in line:
            k, v = line.split(':', 1)
            key = k.strip()
            cur[key] = v.strip()
    if cur:
        yield cur


def parse_provides_entries(field):
    """Parse Provides into (virtual_name, provided_version, versioned).

    Debian Policy 7.5: a versioned Provide uses ``(= version)``. Only that
    form carries a virtual version. Unversioned Provides have an empty
    provided version and cannot satisfy versioned dependencies. The provider
    package's own Version field is never treated as the virtual version.
    """
    entries = []
    for group in xba.parse_dep_field(field):
        for name, constraint, _arch in group:
            versioned = False
            provided = ''
            parsed = parse_version_constraint(constraint)
            if parsed is not None and parsed[0] == '=':
                versioned = True
                provided = parsed[1]
            entries.append((name, provided, versioned))
    return entries


def provider_satisfies_constraint(provided_version, versioned_provides, constraint):
    """Evaluate a virtual dependency against the provided version only."""
    parsed = parse_version_constraint(constraint)
    if parsed is None:
        return True
    if parsed[0] == 'invalid':
        return False
    if not versioned_provides or not provided_version:
        return False
    return version_satisfies_constraint(provided_version, constraint)


def _provider_record(virtual_name, provided_version, versioned, stanza):
    return OrderedDict([
        ('virtual', virtual_name),
        ('provided_version', provided_version or ''),
        ('versioned_provides', bool(versioned)),
        ('package', stanza.get('Package') or ''),
        ('stanza', stanza),
    ])


def build_provider_index(candidates, extra=None):
    """Map virtual names to provider records from real package stanzas.

    Augments the real Package-name index; it does not replace direct-package
    lookup. Duplicate identities (same Package/suite/Version/Filename) are
    skipped so local + authoritative copies of one stanza do not double-count.
    """
    index = OrderedDict()
    seen = set()

    def add_stanza(stanza):
        if not stanza:
            return
        ident = (
            _candidate_identity(stanza),
            stanza.get('Provides') or '',
        )
        if ident in seen:
            return
        seen.add(ident)
        for vname, provided, versioned in parse_provides_entries(
            stanza.get('Provides') or '',
        ):
            if not vname:
                continue
            index.setdefault(vname, [])
            index[vname].append(
                _provider_record(vname, provided, versioned, stanza)
            )

    for _name, stanzas in (candidates or {}).items():
        if isinstance(stanzas, dict):
            stanzas = [stanzas]
        for stanza in stanzas or []:
            add_stanza(stanza)
    extra_names = sorted((extra or {}).keys())
    for name in extra_names:
        add_stanza((extra or {}).get(name))
    return index


def select_best_provider(provider_records, constraint=None):
    """Pick one satisfying provider using existing pin + version policy.

    Constraint is evaluated against the Provides version. Ranking among
    satisfying providers uses the real package Version and suite pin, matching
    select_best_candidate. Preference order matches direct-package lookup:

    1. ACPS/extra providers (suite=acps) when they satisfy
    2. local_selective providers when they satisfy
    3. remaining candidates (authoritative Noble)

    Remaining ties keep the first record in deterministic index order.
    """
    satisfying = []
    for rec in provider_records or []:
        if provider_satisfies_constraint(
            rec.get('provided_version') or '',
            rec.get('versioned_provides'),
            constraint,
        ):
            satisfying.append(rec)
    if not satisfying:
        return None
    acps_hits = [
        rec for rec in satisfying
        if (rec.get('stanza') or {}).get('_suite') == 'acps'
    ]
    local_hits = [
        rec for rec in satisfying
        if (rec.get('stanza') or {}).get('_source') == 'local_selective'
    ]
    if acps_hits:
        pool = acps_hits
    elif local_hits:
        pool = local_hits
    else:
        pool = satisfying
    stanzas = [rec.get('stanza') for rec in pool if rec.get('stanza')]
    chosen_stanza = select_best_candidate(stanzas, constraint=None)
    if chosen_stanza is None:
        return pool[0]
    ident = _candidate_identity(chosen_stanza)
    for rec in pool:
        if _candidate_identity(rec.get('stanza') or {}) == ident:
            return rec
    return pool[0]


def format_provider_summaries(provider_records, constraint=None, limit=8):
    rows = []
    records = list(provider_records or [])
    for rec in records[:limit]:
        st = rec.get('stanza') or {}
        ok = provider_satisfies_constraint(
            rec.get('provided_version') or '',
            rec.get('versioned_provides'),
            constraint,
        )
        rows.append(
            '%s provided_version=%s versioned=%s suite=%s component=%s source=%s satisfies=%s' % (
                rec.get('package') or '',
                rec.get('provided_version') or '-',
                'YES' if rec.get('versioned_provides') else 'NO',
                st.get('_suite') or '',
                st.get('_component') or '',
                st.get('_source') or '',
                'YES' if ok else 'NO',
            )
        )
    extra = len(records) - limit
    if extra > 0:
        rows.append('and %d more' % extra)
    return rows


def emit_virtual_provider_pass(rec, constraint=None):
    st = rec.get('stanza') or {}
    eprint(
        'PHASE2_PREREQ_VIRTUAL_PROVIDER=PASS virtual=%s constraint=%s provider=%s provided_version=%s suite=%s component=%s source=%s' % (
            rec.get('virtual') or '',
            constraint or '-',
            rec.get('package') or '',
            rec.get('provided_version') or '-',
            st.get('_suite') or '',
            st.get('_component') or '',
            st.get('_source') or '',
        )
    )


def emit_virtual_provider_fail(virtual_name, constraint, provider_records):
    summaries = format_provider_summaries(provider_records, constraint)
    eprint(
        'PHASE2_PREREQ_VIRTUAL_PROVIDER=FAIL virtual=%s constraint=%s providers=%s' % (
            virtual_name,
            constraint or '-',
            ';'.join(summaries) if summaries else 'none',
        )
    )


def suite_pin(suite):
    suite = suite or ''
    if suite in SUITE_PIN:
        return SUITE_PIN[suite]
    if suite.endswith('-backports'):
        return 100
    if suite.endswith('-security') or suite.endswith('-updates'):
        return 500
    if suite == 'acps':
        return 0
    return 500


def suite_tie_rank(suite):
    suite = suite or ''
    if suite in SUITE_TIE_RANK:
        return SUITE_TIE_RANK[suite]
    if suite.endswith('-security'):
        return 3
    if suite.endswith('-updates'):
        return 2
    if suite.endswith('-backports'):
        return 0
    return 1


def _candidate_identity(stanza):
    return (
        stanza.get('Package') or '',
        stanza.get('_suite') or '',
        stanza.get('Version') or '',
        stanza.get('Filename') or '',
    )


def load_all_package_candidates(ubuntu_root, suites=None, components=None, arch='amd64'):
    """Load every Packages stanza; do not collapse to last-suite-wins."""
    suites = suites or PHASE2_DEFAULT_SUITES
    components = components or PHASE2_DEFAULT_COMPONENTS
    by_name = OrderedDict()
    provenance = OrderedDict()
    if not ubuntu_root or not os.path.isdir(ubuntu_root):
        return by_name, provenance
    for suite in suites:
        for component in components:
            path = os.path.join(
                ubuntu_root, 'dists', suite, component,
                'binary-%s' % arch, 'Packages',
            )
            if not os.path.isfile(path):
                gz = path + '.gz'
                if not os.path.isfile(gz):
                    continue
                text = xba.open_packages_text(gz)
            else:
                text = xba.read_text(path)
            for stanza in parse_packages_stanzas(text):
                name = stanza.get('Package')
                if not name:
                    continue
                rec = OrderedDict(stanza)
                rec['_suite'] = suite
                rec['_component'] = component
                rec['_source'] = 'local_selective'
                by_name.setdefault(name, [])
                ident = _candidate_identity(rec)
                if any(_candidate_identity(existing) == ident for existing in by_name[name]):
                    continue
                by_name[name].append(rec)
                provenance.setdefault(name, [])
                provenance[name].append('%s/%s' % (suite, component))
    return by_name, provenance


def selected_packages_from_candidates(candidates_by_name):
    """Best unconstrained candidate per name (for install-plan Depends lookup)."""
    selected = OrderedDict()
    for name, stanzas in (candidates_by_name or {}).items():
        chosen = select_best_candidate(stanzas, constraint=None)
        if chosen is not None:
            selected[name] = chosen
    return selected


def select_best_candidate(stanzas, constraint=None):
    """Pick one stanza using Noble pin + Debian version policy.

    Backports (pin 100) never override archive/updates/security (pin 500)
    merely by being loaded last. A backports stanza is used only when no
    pin-500 candidate satisfies the constraint.
    """
    satisfying = []
    for stanza in stanzas or []:
        if version_satisfies_constraint(stanza.get('Version') or '', constraint):
            satisfying.append(stanza)
    if not satisfying:
        return None
    pin500 = [s for s in satisfying if suite_pin(s.get('_suite')) >= 500]
    pool = pin500 if pin500 else satisfying
    best = pool[0]
    for cand in pool[1:]:
        left = cand.get('Version') or ''
        right = best.get('Version') or ''
        if left and right and _dpkg_compare_versions(left, 'gt', right):
            best = cand
            continue
        if left and right and _dpkg_compare_versions(left, 'eq', right):
            if suite_tie_rank(cand.get('_suite')) > suite_tie_rank(best.get('_suite')):
                best = cand
    return best


def candidate_evidence(name, stanzas, constraint=None):
    rows = []
    for stanza in stanzas or []:
        ver = stanza.get('Version') or ''
        rows.append(OrderedDict([
            ('package', name),
            ('version', ver),
            ('suite', stanza.get('_suite') or ''),
            ('component', stanza.get('_component') or ''),
            ('filename', stanza.get('Filename') or ''),
            ('pin', suite_pin(stanza.get('_suite'))),
            ('satisfies_constraint', version_satisfies_constraint(ver, constraint)),
            ('source', stanza.get('_source') or ''),
        ]))
    return rows


def format_dep_expression(group):
    parts = []
    for alt in group or []:
        name, constraint, _arch = alt
        if constraint:
            parts.append('%s (%s)' % (name, constraint))
        else:
            parts.append(name)
    return ' | '.join(parts) if parts else ''


def select_alternative_candidate(
    group, candidates_by_name, ensure_constraint=None,
    provider_index=None,
):
    """Left-to-right alternative that has a candidate satisfying its constraint.

    Direct Package-name lookup is unchanged. When no real package of that
    name satisfies the constraint, virtual Provides are considered. The
    returned stanza is always the real provider package, never a virtual
    name. ``ensure_constraint(name, constraint)``, when provided, is invoked
    for each alternative before selection so authoritative Noble metadata can
    be loaded when a local name exists but no loaded candidate satisfies the
    constraint, including when only a virtual provider can satisfy it.
    """
    evidence = []
    expression = format_dep_expression(group)
    if provider_index is None:
        provider_index = {}
    virtual_failures = []
    for alt in group or []:
        name, constraint, _arch = alt
        if ensure_constraint is not None and name not in VIRTUAL_OR_BASE_SKIP:
            ensure_constraint(name, constraint)
        stanzas = candidates_by_name.get(name) or []
        evidence.extend(candidate_evidence(name, stanzas, constraint))
        if name in VIRTUAL_OR_BASE_SKIP:
            return OrderedDict([
                ('Package', name),
                ('_virtual_or_base', True),
                ('_suite', 'base'),
            ]), None, evidence
        local = [
            s for s in stanzas
            if (s.get('_source') or 'local_selective') == 'local_selective'
        ]
        chosen = select_best_candidate(local, constraint)
        if chosen is None:
            chosen = select_best_candidate(stanzas, constraint)
        if chosen is not None:
            return chosen, None, evidence
        providers = list(provider_index.get(name) or [])
        rec = select_best_provider(providers, constraint)
        if rec is not None:
            emit_virtual_provider_pass(rec, constraint)
            return rec.get('stanza'), None, evidence
        if providers:
            virtual_failures.append((name, constraint, providers))
    for vname, vconstraint, providers in virtual_failures:
        emit_virtual_provider_fail(vname, vconstraint, providers)
    reason = (
        'unsatisfied_dependency expression=%s candidates=%s'
        % (expression, json.dumps(evidence, sort_keys=True))
    )
    return None, reason, evidence


def packages_index_url(suite, component, arch, archive_base, security_base):
    rel = 'dists/%s/%s/binary-%s/Packages.gz' % (suite, component, arch)
    archive_base = (archive_base or DEFAULT_ARCHIVE_BASE).rstrip('/')
    security_base = (security_base or DEFAULT_SECURITY_BASE).rstrip('/')
    if suite.endswith('-security') or suite == 'security':
        return '%s/%s' % (security_base, rel)
    return '%s/%s' % (archive_base, rel)


def _decompress_packages_gz(gz_path, dest_path):
    parent = os.path.dirname(dest_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with gzip.open(gz_path, 'rb') as fh:
        data = fh.read()
    tmp = dest_path + '.part'
    with open(tmp, 'wb') as fh:
        fh.write(data)
    os.rename(tmp, dest_path)
    return dest_path


def fetch_authoritative_packages_index(
    cache_root, suite, component, arch='amd64',
    archive_base=None, security_base=None,
):
    """Download official Ubuntu Packages.gz into cache via acquire_file."""
    dest_dir = os.path.join(
        cache_root, 'dists', suite, component, 'binary-%s' % arch,
    )
    dest = os.path.join(dest_dir, 'Packages')
    dest_gz = dest + '.gz'
    if os.path.isfile(dest):
        return dest
    url = packages_index_url(
        suite, component, arch, archive_base, security_base,
    )
    if sm is None:
        raise RuntimeError('selective_mirror.acquire_file is required to fetch %s' % url)
    os.makedirs(dest_dir, exist_ok=True)
    eprint('PHASE2_PREREQ_AUTH_INDEX=START suite=%s component=%s url=%s' % (
        suite, component, url,
    ))
    sm.acquire_file(
        src='',
        dst=dest_gz,
        allow_download_url=url,
    )
    _decompress_packages_gz(dest_gz, dest)
    eprint('PHASE2_PREREQ_AUTH_INDEX=PASS suite=%s component=%s path=%s' % (
        suite, component, dest,
    ))
    return dest


def load_authoritative_noble_candidates(
    authoritative_root=None, cache_root=None, fetch=False,
    suites=None, components=None, arch='amd64',
    archive_base=None, security_base=None,
):
    """Load official Noble Packages metadata (local cache and/or fetch).

    Trust is the Ubuntu archive/security Packages indexes (Filename/SHA256/Size
    from those stanzas), not the selective mirror plan.
    """
    suites = suites or PHASE2_DEFAULT_SUITES
    components = components or PHASE2_DEFAULT_COMPONENTS
    by_name = OrderedDict()
    roots = []
    if authoritative_root:
        roots.append(authoritative_root)
    if cache_root:
        roots.append(cache_root)
        if fetch:
            for suite in suites:
                for component in components:
                    try:
                        fetch_authoritative_packages_index(
                            cache_root, suite, component, arch=arch,
                            archive_base=archive_base,
                            security_base=security_base,
                        )
                    except Exception as exc:
                        eprint('PHASE2_PREREQ_AUTH_INDEX=FAIL suite=%s component=%s reason=%s' % (
                            suite, component, type(exc).__name__,
                        ))
                        raise
    for root in roots:
        loaded, _prov = load_all_package_candidates(
            root, suites=suites, components=components, arch=arch,
        )
        for name, stanzas in loaded.items():
            by_name.setdefault(name, [])
            for stanza in stanzas:
                rec = OrderedDict(stanza)
                rec['_source'] = rec.get('_source') or 'authoritative_noble'
                if rec.get('_source') == 'local_selective':
                    rec['_source'] = 'authoritative_noble'
                ident = _candidate_identity(rec)
                if any(_candidate_identity(existing) == ident for existing in by_name[name]):
                    continue
                by_name[name].append(rec)
    return by_name


def merge_candidate_indexes(*indexes):
    merged = OrderedDict()
    for idx in indexes:
        if not idx:
            continue
        for name, stanzas in idx.items():
            if isinstance(stanzas, dict):
                stanzas = [stanzas]
            merged.setdefault(name, [])
            for stanza in stanzas:
                ident = _candidate_identity(stanza)
                if any(_candidate_identity(existing) == ident for existing in merged[name]):
                    continue
                merged[name].append(OrderedDict(stanza))
    return merged


def default_authoritative_cache(ubuntu_root, dest=None):
    if dest:
        # Never cache under the HTTP-published extras directory.
        extras_name = os.path.basename(os.path.abspath(dest).rstrip(os.sep))
        if extras_name != 'extras':
            return os.path.join(dest, '.phase2-noble-authoritative')
    if ubuntu_root:
        parent = os.path.dirname(os.path.abspath(ubuntu_root))
        return os.path.join(parent, '.phase2-noble-authoritative')
    return os.path.join(tempfile.gettempdir(), 'phase2-noble-authoritative')


def resolve_phase2_dependency_closure(
    root_names, packages, extra_root_stanzas=None,
    candidate_index=None, on_missing_name=None,
):
    """Resolve recursive Depends/Pre-Depends with version/alternative policy.

    ``packages`` may be name->stanza (legacy last-wins) or name->list of
    stanzas. ``on_missing_name`` loads authoritative Noble metadata when a
    package name is absent from the local selective index, or when every
    currently loaded candidate fails the dependency constraint.
    """
    candidates = OrderedDict()
    if candidate_index:
        candidates = merge_candidate_indexes(candidate_index)
    elif packages:
        for name, info in packages.items():
            if isinstance(info, (list, tuple)):
                candidates[name] = [OrderedDict(s) for s in info]
            elif info:
                candidates[name] = [OrderedDict(info)]
    extra = extra_root_stanzas or OrderedDict()
    seen = set()
    missing = []
    constraint_failures = []
    queue = list(root_names or [])
    edges = []
    selected = OrderedDict()
    authoritative_queries = []
    provider_index = OrderedDict()

    def rebuild_provider_index():
        provider_index.clear()
        provider_index.update(build_provider_index(candidates, extra))

    def providers_satisfy(name, constraint):
        return select_best_provider(provider_index.get(name), constraint) is not None

    def ensure_candidates_for_constraint(name, constraint):
        """Load authoritative candidates when no current stanza satisfies.

        A local name is not enough: the loaded set must contain a candidate
        that ``select_best_candidate`` accepts for ``constraint``, or a
        virtual provider whose Provides version satisfies it.
        """
        if name in VIRTUAL_OR_BASE_SKIP:
            return True
        if name in extra:
            return True
        stanzas = candidates.get(name) or []
        if select_best_candidate(stanzas, constraint) is not None:
            return True
        if providers_satisfy(name, constraint):
            return True
        if on_missing_name is None:
            return False
        authoritative_queries.append(name)
        on_missing_name(name, candidates)
        rebuild_provider_index()
        stanzas = candidates.get(name) or []
        if select_best_candidate(stanzas, constraint) is not None:
            return True
        return providers_satisfy(name, constraint)

    rebuild_provider_index()

    while queue:
        name = queue.pop(0)
        if name in seen:
            continue
        seen.add(name)
        if name in VIRTUAL_OR_BASE_SKIP:
            continue
        extra_info = extra.get(name)
        if extra_info is not None:
            selected[name] = extra_info
            info = extra_info
        else:
            # A dependency alternative may already have stored the constraint-
            # satisfying stanza. Do not re-select unconstrained local versions.
            if name not in selected:
                if not ensure_candidates_for_constraint(name, None):
                    missing.append(name)
                    continue
                stanzas = candidates.get(name) or []
                local = [
                    s for s in stanzas
                    if (s.get('_source') or 'local_selective') == 'local_selective'
                ]
                chosen = select_best_candidate(local, constraint=None)
                if chosen is None:
                    chosen = select_best_candidate(stanzas, constraint=None)
                if chosen is None:
                    missing.append(name)
                    continue
                selected[name] = chosen
            info = selected[name]
        for field in PHASE2_PREREQ_FIELDS:
            for group in xba.parse_dep_field(info.get(field)):
                if not group:
                    continue
                chosen, reason, _ev = select_alternative_candidate(
                    group, candidates,
                    ensure_constraint=ensure_candidates_for_constraint,
                    provider_index=provider_index,
                )
                expression = format_dep_expression(group)
                if reason:
                    # Extra/ACPS roots may depend on another extra root.
                    extra_hit = None
                    for alt in group:
                        if alt[0] in extra and version_satisfies_constraint(
                            extra.get(alt[0], {}).get('Version') or '', alt[1],
                        ):
                            extra_hit = extra[alt[0]]
                            break
                    if extra_hit is None:
                        any_candidates = False
                        for alt in group:
                            if (
                                (candidates.get(alt[0]))
                                or provider_index.get(alt[0])
                                or alt[0] in extra
                                or alt[0] in VIRTUAL_OR_BASE_SKIP
                            ):
                                any_candidates = True
                                break
                        if not any_candidates:
                            for alt in group:
                                missing.append(alt[0])
                            eprint('PHASE2_PREREQ_CANDIDATE=NONE from=%s expression=%s' % (
                                name, expression,
                            ))
                            continue
                        constraint_failures.append(OrderedDict([
                            ('from', name),
                            ('field', field),
                            ('expression', expression),
                            ('reason', reason),
                        ]))
                        eprint('PHASE2_PREREQ_DEP=FAIL from=%s field=%s expression=%s' % (
                            name, field, expression,
                        ))
                        continue
                    chosen = extra_hit
                dep_name = chosen.get('Package')
                edges.append(OrderedDict([
                    ('from', name), ('field', field), ('to', dep_name),
                    ('expression', expression),
                ]))
                if (
                    dep_name not in selected
                    and dep_name not in extra
                    and dep_name not in VIRTUAL_OR_BASE_SKIP
                    and not chosen.get('_virtual_or_base')
                ):
                    selected[dep_name] = chosen
                if dep_name not in seen:
                    queue.append(dep_name)

    return OrderedDict([
        ('roots', list(root_names or [])),
        ('fields', list(PHASE2_PREREQ_FIELDS)),
        ('visited_count', len(seen)),
        ('visited', sorted(seen)),
        ('missing_from_index', sorted(set(missing))),
        ('constraint_failures', constraint_failures),
        ('edge_count', len(edges)),
        ('edges_sample', edges[:50]),
        ('selected', selected),
        ('algorithm', 'phase2_noble_candidate_policy'),
        ('authoritative_queries', authoritative_queries),
        ('prefer_available', True),
    ])


def unsatisfied_from_acps(closure, acps_names):
    """Ubuntu packages in the closure that ACPS did not already ship.

    Vendor/Aella packages (aella-*) may appear as extra roots or as Depends
    of those roots. They are not Ubuntu mirror candidates and must not be
    packed into the prerequisite artifact or fail candidate checks.
    """
    acps = set(acps_names)
    visited = list(closure.get('visited') or [])
    missing = list(closure.get('missing_from_index') or [])
    needed = []
    skipped_vendor = []
    for name in visited:
        if name in acps:
            continue
        if name in VIRTUAL_OR_BASE_SKIP:
            continue
        if name.startswith('aella-'):
            skipped_vendor.append(name)
            continue
        needed.append(name)
    return OrderedDict([
        ('acps_root_count', len(acps)),
        ('closure_visited_count', len(visited)),
        ('unsatisfied', needed),
        ('missing_from_index', missing),
        ('skipped_vendor', skipped_vendor),
    ])


def package_record(name, info):
    return OrderedDict([
        ('package', name),
        ('version', (info or {}).get('Version', '')),
        ('architecture', (info or {}).get('Architecture', '')),
        ('suite', (info or {}).get('_suite', '')),
        ('component', (info or {}).get('_component', '')),
        ('filename', (info or {}).get('Filename', '')),
        ('sha256', (info or {}).get('SHA256', '')),
        ('size', (info or {}).get('Size', '')),
        ('depends', (info or {}).get('Depends', '')),
        ('pre_depends', (info or {}).get('Pre-Depends', '')),
        ('provides', (info or {}).get('Provides', '')),
    ])


def package_upstream_url(suite, filename, archive_base=None, security_base=None):
    """Build the official Ubuntu pool URL from Packages Filename + suite.

    Does not invent pool paths. Filename comes from the Packages index.
    noble-security uses the security pocket base; all other suites use archive.
    """
    filename = (filename or '').lstrip('/')
    if not filename:
        return ''
    archive_base = (archive_base or DEFAULT_ARCHIVE_BASE).rstrip('/')
    security_base = (security_base or DEFAULT_SECURITY_BASE).rstrip('/')
    suite = suite or ''
    if suite.endswith('-security') or suite == 'security':
        base = security_base
    else:
        base = archive_base
    return '%s/%s' % (base, filename)


def _parse_size(value):
    if value in (None, ''):
        return None
    if isinstance(value, int):
        return value if value >= 0 else None
    text = str(value).strip()
    if not re.match(r'^[0-9]+$', text):
        return None
    return int(text)


def is_valid_sha256(value):
    return bool(value) and SHA256_HEX_RE.match(str(value).strip()) is not None


def required_index_metadata_reason(rec):
    """Fail closed when any mandatory Packages field is absent or malformed."""
    rec = rec or {}
    pkg = (rec.get('package') or rec.get('Package') or '').strip()
    ver = (rec.get('version') or rec.get('Version') or '').strip()
    arch = (rec.get('architecture') or rec.get('Architecture') or '').strip()
    filename = (rec.get('filename') or rec.get('Filename') or '').strip()
    sha256 = (rec.get('sha256') or rec.get('SHA256') or '').strip()
    size_raw = rec.get('size')
    if size_raw in (None, '') and rec.get('Size') not in (None, ''):
        size_raw = rec.get('Size')
    if not pkg:
        return 'metadata_missing field=Package'
    if not ver:
        return 'metadata_missing field=Version'
    if not arch:
        return 'metadata_missing field=Architecture'
    if not filename:
        return 'metadata_missing field=Filename'
    if filename.startswith('/') or '..' in filename.split('/'):
        return 'metadata_malformed field=Filename'
    if not is_valid_sha256(sha256):
        return 'metadata_missing field=SHA256'
    size = _parse_size(size_raw)
    if size is None:
        return 'metadata_missing field=Size'
    return ''


def read_deb_control(path):
    """Return control fields from a .deb. Prefer selective_mirror.parse_deb_control.

    Control-read failure returns an empty dict. Callers that require a readable
    control stanza must treat that as FAIL (see verify_local_package_file).
    """
    if not path or not os.path.isfile(path):
        return OrderedDict()
    if sm is not None:
        try:
            fields = sm.parse_deb_control(path)
            if fields:
                return fields
        except Exception:
            pass
    try:
        out = subprocess.check_output(
            ['dpkg-deb', '-I', path, 'control'],
            stderr=subprocess.DEVNULL,
        ).decode('utf-8', 'replace')
        fields = parse_control_text(out)
        if fields:
            return fields
    except (OSError, subprocess.CalledProcessError):
        pass
    return OrderedDict()


def architecture_matches(expected, actual):
    expected = (expected or '').strip()
    actual = (actual or '').strip()
    if not expected or not actual:
        return False
    if actual == expected:
        return True
    # Arch-independent packages may satisfy an architecture-specific Depends.
    if actual == 'all':
        return True
    return False


def verify_local_package_file(path, rec):
    """Verify on-disk .deb against mandatory index metadata. Empty reason means OK."""
    meta_reason = required_index_metadata_reason(rec)
    if meta_reason:
        return meta_reason
    if not path or not os.path.isfile(path):
        return 'deb_absent'
    expected_size = _parse_size(rec.get('size') if rec.get('size') not in (None, '') else rec.get('Size'))
    try:
        actual_size = os.path.getsize(path)
    except OSError:
        return 'size_unreadable'
    if actual_size != expected_size:
        return 'size_mismatch expected=%s actual=%s' % (expected_size, actual_size)
    expected_sha = (rec.get('sha256') or rec.get('SHA256') or '').strip().lower()
    actual_sha = sha256_file(path).lower()
    if actual_sha != expected_sha:
        return 'sha256_mismatch expected=%s actual=%s' % (expected_sha, actual_sha)
    fields = read_deb_control(path)
    if not fields:
        return 'control_unreadable'
    pkg = (fields.get('Package') or '').strip()
    ver = (fields.get('Version') or '').strip()
    arch = (fields.get('Architecture') or '').strip()
    expected_pkg = (rec.get('package') or rec.get('Package') or '').strip()
    expected_ver = (rec.get('version') or rec.get('Version') or '').strip()
    expected_arch = (rec.get('architecture') or rec.get('Architecture') or '').strip()
    if not pkg:
        return 'control_package_unreadable'
    if pkg != expected_pkg:
        return 'control_package_mismatch expected=%s actual=%s' % (expected_pkg, pkg)
    if not ver:
        return 'control_version_unreadable'
    if ver != expected_ver:
        return 'control_version_mismatch expected=%s actual=%s' % (expected_ver, ver)
    if not arch:
        return 'control_architecture_unreadable'
    if not architecture_matches(expected_arch, arch):
        return 'control_architecture_mismatch expected=%s actual=%s' % (
            expected_arch, arch,
        )
    return ''


def _provider_in_install_set(virtual_name, constraint, packages, install_set):
    """Return the real package in install_set that provides virtual_name."""
    matches = []
    for pkg in sorted(install_set):
        info = (packages or {}).get(pkg) or {}
        for vname, provided, versioned in parse_provides_entries(
            info.get('Provides') or '',
        ):
            if vname != virtual_name:
                continue
            if provider_satisfies_constraint(provided, versioned, constraint):
                matches.append(pkg)
                break
    if not matches:
        return None
    if len(matches) == 1:
        return matches[0]
    stanzas = [(packages or {}).get(pkg) for pkg in matches if (packages or {}).get(pkg)]
    chosen = select_best_candidate(stanzas, constraint=None)
    if chosen is not None and chosen.get('Package'):
        return chosen.get('Package')
    return matches[0]


def direct_install_deps(name, packages, install_set):
    """Depends/Pre-Depends of name that are also in the install set.

    Virtual dependencies resolve to the real provider package present in the
    install set. The virtual name itself is never treated as an installable
    artifact package.
    """
    info = (packages or {}).get(name) or {}
    deps = []
    seen = set()
    for field in PHASE2_PREREQ_FIELDS:
        for group in xba.parse_dep_field(info.get(field)):
            chosen = None
            for alt_name, constraint, _arch in group:
                if alt_name in VIRTUAL_OR_BASE_SKIP:
                    continue
                if alt_name in install_set:
                    chosen = alt_name
                    break
                provided_by = _provider_in_install_set(
                    alt_name, constraint, packages, install_set,
                )
                if provided_by:
                    chosen = provided_by
                    break
            if chosen and chosen != name and chosen not in seen:
                seen.add(chosen)
                deps.append(chosen)
    return deps


def _tarjan_scc(nodes, successors):
    """Deterministic Tarjan strongly connected components."""
    nodes = sorted(nodes)
    index_counter = [0]
    stack = []
    onstack = set()
    index = {}
    lowlink = {}
    components = []

    def strongconnect(v):
        index[v] = index_counter[0]
        lowlink[v] = index_counter[0]
        index_counter[0] += 1
        stack.append(v)
        onstack.add(v)
        for w in sorted(successors.get(v, ())):
            if w not in index:
                strongconnect(w)
                lowlink[v] = min(lowlink[v], lowlink[w])
            elif w in onstack:
                lowlink[v] = min(lowlink[v], index[w])
        if lowlink[v] == index[v]:
            comp = []
            while True:
                w = stack.pop()
                onstack.discard(w)
                comp.append(w)
                if w == v:
                    break
            components.append(tuple(sorted(comp)))

    for v in nodes:
        if v not in index:
            strongconnect(v)
    return components


def build_install_plan(package_names, packages):
    """Deterministic dependency-aware install plan (deps before dependents).

    Shared dependencies appear once. Cycles become one SCC group installed
    together (one dpkg -i invocation), not a false claim of strict order.
    """
    names = []
    seen = set()
    for name in package_names or []:
        if name and name not in seen:
            seen.add(name)
            names.append(name)
    install_set = set(names)
    successors = defaultdict(list)  # dep -> packages that require it
    predecessors = defaultdict(list)  # package -> deps in install set
    for name in names:
        for dep in direct_install_deps(name, packages, install_set):
            predecessors[name].append(dep)
            successors[dep].append(name)
    sccs = _tarjan_scc(install_set, predecessors)
    scc_of = {}
    for scc in sccs:
        for name in scc:
            scc_of[name] = scc
    scc_succ = defaultdict(set)
    for name in names:
        src = scc_of[name]
        for dep in predecessors.get(name, ()):
            dst = scc_of[dep]
            if dst != src:
                # dest SCC must be installed before src SCC
                scc_succ[dst].add(src)
    incoming = {scc: 0 for scc in sccs}
    for src, dests in scc_succ.items():
        for dest in dests:
            incoming[dest] = incoming.get(dest, 0) + 1
    ready = sorted(
        [scc for scc in sccs if incoming.get(scc, 0) == 0],
        key=lambda s: s,
    )
    ordered_sccs = []
    remaining = set(sccs)
    while ready:
        scc = ready.pop(0)
        if scc not in remaining:
            continue
        remaining.discard(scc)
        ordered_sccs.append(scc)
        for dest in sorted(scc_succ.get(scc, ())):
            incoming[dest] -= 1
            if incoming[dest] == 0 and dest in remaining:
                ready.append(dest)
                ready.sort()
    if remaining:
        # Should not happen after Tarjan; append leftover SCCs deterministically.
        ordered_sccs.extend(sorted(remaining))
    groups = [list(scc) for scc in ordered_sccs]
    flat = []
    for group in groups:
        flat.extend(group)
    return OrderedDict([
        ('algorithm', 'tarjan_scc_topo'),
        ('package_count', len(names)),
        ('group_count', len(groups)),
        ('cycle_group_count', sum(1 for g in groups if len(g) > 1)),
        ('install_groups', groups),
        ('install_order', flat),
    ])


def write_install_order_text(groups, filename_by_package):
    """One dpkg -i group per line; space-separated artifact filenames."""
    lines = [
        '# PHASE2_PREREQ_INSTALL_ORDER',
        '# One dpkg -i invocation per line. Space-separated files are one SCC group.',
    ]
    for group in groups:
        files = []
        for name in group:
            fn = filename_by_package.get(name)
            if fn:
                files.append(fn)
        if files:
            lines.append(' '.join(files))
    return '\n'.join(lines) + '\n'


def retract_published_prerequisite_files(dest_dir):
    """Remove previously published artifacts so a FAIL state cannot be staged."""
    if not dest_dir:
        return
    for name in (
        ARTIFACT_NAME,
        ARTIFACT_NAME + '.sha256',
        MANIFEST_NAME,
        INSTALL_ORDER_NAME,
    ):
        path = os.path.join(dest_dir, name)
        try:
            if os.path.isfile(path) or os.path.islink(path):
                os.unlink(path)
        except OSError:
            pass


def parse_prereq_state_text(text):
    fields = OrderedDict()
    for raw in (text or '').splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        fields[key.strip()] = value
    return fields


def validate_prereq_state_contract(fields, dest_dir=None, require_files=None):
    """Return a reason string when the PHASE2_PREREQ_* contract is invalid."""
    fields = fields or {}
    required = (fields.get('PHASE2_PREREQ_REQUIRED') or '').strip()
    count_raw = fields.get('PHASE2_PREREQ_PACKAGE_COUNT')
    build = (fields.get('PHASE2_PREREQ_BUILD') or '').strip()
    publication = (fields.get('PHASE2_PREREQ_PUBLICATION') or '').strip()
    artifact = (fields.get('PHASE2_PREREQ_ARTIFACT') or '').strip()
    sha = (fields.get('PHASE2_PREREQ_SHA256') or '').strip()
    if build != 'PASS':
        return 'build_not_pass'
    if publication != 'PASS':
        return 'publication_not_pass'
    if count_raw is None or str(count_raw).strip() == '':
        return 'count_missing'
    count_text = str(count_raw).strip()
    if not re.match(r'^[0-9]+$', count_text):
        return 'count_nonnumeric'
    count = int(count_text)
    if required == 'NO':
        if count != 0:
            return 'count_nonzero_when_not_required'
        return ''
    if required != 'YES':
        return 'required_invalid'
    if count <= 0:
        return 'count_not_positive'
    if artifact != ARTIFACT_NAME:
        return 'artifact_name_invalid'
    if not is_valid_sha256(sha):
        return 'sha256_invalid'
    if require_files is None:
        require_files = bool(dest_dir)
    if require_files:
        if not dest_dir:
            return 'dest_missing'
        art = os.path.join(dest_dir, ARTIFACT_NAME)
        if not os.path.isfile(os.path.join(dest_dir, STATE_NAME)):
            return 'state_file_missing'
        if not os.path.isfile(art):
            return 'artifact_missing'
        if not os.path.isfile(art + '.sha256'):
            return 'sha_sidecar_missing'
        if not os.path.isfile(os.path.join(dest_dir, MANIFEST_NAME)):
            return 'manifest_missing'
        sidecar_sha = ''
        try:
            with open(art + '.sha256', 'r') as fh:
                sidecar_sha = (fh.read().split() or [''])[0]
        except OSError:
            return 'sha_sidecar_unreadable'
        if sidecar_sha.strip().lower() != sha.lower():
            return 'sha256_sidecar_mismatch'
        actual = sha256_file(art)
        if actual.lower() != sha.lower():
            return 'sha256_file_mismatch'
    return ''


def write_prerequisite_state(path, fields):
    """Write machine-readable PHASE2_PREREQ_* key=value state."""
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    lines = []
    for key, value in fields.items():
        if value is None:
            value = ''
        lines.append('%s=%s' % (key, value))
    text = '\n'.join(lines) + '\n'
    tmp = path + '.part'
    with open(tmp, 'w') as fh:
        fh.write(text)
    os.rename(tmp, path)
    return text


def collect_artifact_packages(unsatisfied_names, packages, pool_root=None):
    """Map unsatisfied names to index records and optional on-disk .deb paths."""
    rows = []
    missing_candidate = []
    missing_deb = []
    invalid_metadata = []
    for name in unsatisfied_names:
        info = (packages or {}).get(name)
        rec = package_record(name, info)
        if not info:
            rec['candidate'] = 'none'
            rec['deb_path'] = ''
            missing_candidate.append(name)
            rows.append(rec)
            continue
        meta_reason = required_index_metadata_reason(rec)
        if meta_reason:
            rec['candidate'] = '%s/%s' % (
                info.get('_suite') or '',
                info.get('_component') or '',
            )
            rec['local_verify'] = meta_reason
            rec['deb_path'] = ''
            invalid_metadata.append(name)
            rows.append(rec)
            continue
        rec['candidate'] = '%s/%s' % (
            info.get('_suite') or '',
            info.get('_component') or '',
        )
        rec['url'] = package_upstream_url(
            rec.get('suite'), rec.get('filename'),
        )
        deb_path = ''
        filename = info.get('Filename') or rec.get('filename') or ''
        if pool_root and filename:
            cand = os.path.join(pool_root, filename)
            if os.path.isfile(cand):
                reason = verify_local_package_file(cand, rec)
                if reason:
                    rec['local_verify'] = reason
                else:
                    deb_path = cand
                    rec['local_verify'] = 'ok'
        rec['deb_path'] = deb_path
        if not deb_path:
            missing_deb.append(name)
        rows.append(rec)
    return OrderedDict([
        ('packages', rows),
        ('missing_candidate', missing_candidate),
        ('missing_deb', missing_deb),
        ('invalid_metadata', invalid_metadata),
    ])


def acquire_missing_debs(
    collected, ubuntu_root, archive_base=None, security_base=None,
):
    """Fetch missing .debs via selective_mirror.acquire_file and verify them.

    Reuses the existing trusted downloader. Does not invent URLs: Filename
    comes from the Packages index; the base is the suite's archive/security
    repository root.
    """
    acquired = []
    failed = []
    skipped = []
    if sm is None:
        for name in collected.get('missing_deb') or []:
            failed.append(name)
            eprint('PHASE2_PREREQ_ACQUIRE=FAIL package=%s reason=selective_mirror_unavailable' % name)
        return OrderedDict([
            ('acquired', acquired),
            ('failed', failed),
            ('skipped', skipped),
        ])
    rows_by_name = OrderedDict(
        (rec.get('package'), rec) for rec in (collected.get('packages') or [])
    )
    still_missing = []
    for name in collected.get('missing_deb') or []:
        rec = rows_by_name.get(name) or {}
        filename = rec.get('filename') or ''
        if not filename:
            failed.append(name)
            eprint('PHASE2_PREREQ_ACQUIRE=FAIL package=%s reason=filename_missing' % name)
            continue
        dest = os.path.join(ubuntu_root, filename)
        url = package_upstream_url(
            rec.get('suite'), filename, archive_base, security_base,
        )
        rec['url'] = url
        expected_sha = (rec.get('sha256') or '').strip() or None
        expected_size = _parse_size(rec.get('size'))
        if not is_valid_sha256(expected_sha) or expected_size is None:
            failed.append(name)
            eprint('PHASE2_PREREQ_ACQUIRE=FAIL package=%s reason=metadata_incomplete' % name)
            continue
        eprint('PHASE2_PREREQ_ACQUIRE=START package=%s suite=%s component=%s sha256=%s' % (
            name, rec.get('suite') or '', rec.get('component') or '',
            expected_sha or '',
        ))
        try:
            sm.acquire_file(
                src='',
                dst=dest,
                allow_download_url=url,
                expected_sha256=expected_sha,
                expected_size=expected_size,
            )
        except Exception as exc:
            failed.append(name)
            eprint('PHASE2_PREREQ_ACQUIRE=FAIL package=%s reason=%s' % (
                name, type(exc).__name__,
            ))
            continue
        reason = verify_local_package_file(dest, rec)
        if reason:
            failed.append(name)
            eprint('PHASE2_PREREQ_ACQUIRE=FAIL package=%s reason=%s' % (name, reason))
            continue
        rec['deb_path'] = dest
        rec['acquired'] = True
        rec['local_verify'] = 'ok'
        acquired.append(name)
        eprint('PHASE2_PREREQ_ACQUIRE=PASS package=%s path=%s' % (name, dest))
    collected['missing_deb'] = [
        n for n in (collected.get('missing_deb') or [])
        if n not in acquired
    ]
    for rec in collected.get('packages') or []:
        if rec.get('package') in acquired:
            continue
        if rec.get('deb_path'):
            skipped.append(rec.get('package'))
        elif rec.get('candidate') != 'none' and rec.get('package'):
            still_missing.append(rec.get('package'))
    collected['missing_deb'] = [
        n for n in (collected.get('missing_deb') or [])
        if n not in set(acquired)
    ]
    return OrderedDict([
        ('acquired', acquired),
        ('failed', failed),
        ('skipped', skipped),
        ('still_missing', still_missing),
    ])


def parse_apt_simulation(text):
    """Parse apt-get -s / --just-print output for removals and installs."""
    removals = []
    installs = []
    for raw in (text or '').splitlines():
        line = raw.strip()
        if not line:
            continue
        m = re.match(r'^(Inst|Remv|Purg)\s+(\S+)', line)
        if not m:
            # Also accept "Removing python3-gevent" prose.
            m2 = re.match(r'^(?:Removing|Purging)\s+(\S+)', line)
            if m2:
                removals.append(m2.group(1).rstrip('.'))
            continue
        action, pkg = m.group(1), m.group(2)
        if action in ('Remv', 'Purg'):
            removals.append(pkg)
        elif action == 'Inst':
            installs.append(pkg)
    return OrderedDict([
        ('installs', installs),
        ('removals', removals),
    ])


def transaction_is_safe(simulation, extra_protected=None):
    """Reject a simulated apt transaction that would remove protected packages."""
    protected = set(PROTECTED_PACKAGES)
    if extra_protected:
        protected.update(extra_protected)
    parsed = simulation
    if not isinstance(simulation, dict):
        parsed = parse_apt_simulation(simulation)
    removals = list(parsed.get('removals') or [])
    blocked = [p for p in removals if p in protected]
    return OrderedDict([
        ('safe', len(blocked) == 0),
        ('removals', removals),
        ('blocked_removals', blocked),
        ('protected', sorted(protected)),
    ])


def build_prerequisite_artifact(package_rows, dest_dir, include_missing=False,
                                install_plan=None):
    """Write phase2-ubuntu-prerequisites.tar.gz + manifest + sha256 sidecar.

    Every required row must have an on-disk .deb. Partial artifacts are never
    published. ``include_missing`` is rejected: omitting a required .deb is
    a hard failure.
    """
    if include_missing:
        raise ValueError('include_missing is not allowed for production artifacts')
    os.makedirs(dest_dir, exist_ok=True)
    required = list(package_rows or [])
    missing = [
        rec.get('package') or rec.get('artifact_filename') or '?'
        for rec in required
        if not rec.get('deb_path') or not os.path.isfile(rec.get('deb_path') or '')
    ]
    if missing:
        eprint('PHASE2_PREREQ_MISSING_DEB=%s' % ','.join(missing))
        eprint('PHASE2_PREREQ_BUILD=FAIL reason=missing_deb')
        return None
    work = tempfile.mkdtemp(prefix='phase2-prereq-art-')
    packed = []
    try:
        debs_dir = os.path.join(work, 'debs')
        os.makedirs(debs_dir)
        filename_by_package = OrderedDict()
        for rec in required:
            src = rec.get('deb_path')
            dest_name = os.path.basename(src)
            shutil.copy2(src, os.path.join(debs_dir, dest_name))
            out = OrderedDict(rec)
            out['artifact_filename'] = dest_name
            packed.append(out)
            if out.get('package'):
                filename_by_package[out['package']] = dest_name
        plan = install_plan
        if plan is None:
            # Fall back to package-index Depends using packed rows as a mini index.
            mini = OrderedDict()
            for rec in packed:
                mini[rec.get('package')] = OrderedDict([
                    ('Package', rec.get('package') or ''),
                    ('Depends', rec.get('depends') or ''),
                    ('Pre-Depends', rec.get('pre_depends') or ''),
                    ('Provides', rec.get('provides') or ''),
                ])
            plan = build_install_plan(
                [rec.get('package') for rec in packed if rec.get('package')],
                mini,
            )
        order_text = write_install_order_text(
            plan.get('install_groups') or [], filename_by_package,
        )
        with open(os.path.join(work, INSTALL_ORDER_NAME), 'w') as fh:
            fh.write(order_text)
        manifest = OrderedDict([
            ('artifact', ARTIFACT_NAME),
            ('package_count', len(packed)),
            ('required_package_count', len(required)),
            ('packages', packed),
            ('install_order', list(plan.get('install_order') or [])),
            ('install_groups', list(plan.get('install_groups') or [])),
            ('install_plan_algorithm', plan.get('algorithm') or ''),
            ('protected_packages', list(PROTECTED_PACKAGES)),
            ('fields', list(PHASE2_PREREQ_FIELDS)),
            ('acps_payload_modified', False),
        ])
        dump_json(manifest, os.path.join(work, MANIFEST_NAME))
        artifact_path = os.path.join(dest_dir, ARTIFACT_NAME)
        tmp_art = artifact_path + '.part'
        with tarfile.open(tmp_art, 'w:gz') as tf:
            tf.add(os.path.join(work, MANIFEST_NAME), arcname=MANIFEST_NAME)
            tf.add(os.path.join(work, INSTALL_ORDER_NAME), arcname=INSTALL_ORDER_NAME)
            packed_names = set()
            for rec in packed:
                fn = rec.get('artifact_filename')
                if not fn:
                    continue
                packed_names.add(fn)
                tf.add(os.path.join(debs_dir, fn), arcname='debs/%s' % fn)
        os.rename(tmp_art, artifact_path)
        digest = sha256_file(artifact_path)
        sidecar = artifact_path + '.sha256'
        with open(sidecar, 'w') as fh:
            fh.write('%s  %s\n' % (digest, ARTIFACT_NAME))
        manifest['sha256'] = digest
        manifest['artifact_path'] = artifact_path
        dump_json(manifest, os.path.join(dest_dir, MANIFEST_NAME))
        with open(os.path.join(dest_dir, INSTALL_ORDER_NAME), 'w') as fh:
            fh.write(order_text)
        verify_reason = verify_built_artifact(
            dest_dir, manifest, required_names=[
                rec.get('package') for rec in required if rec.get('package')
            ],
        )
        if verify_reason:
            eprint('PHASE2_PREREQ_BUILD=FAIL reason=%s' % verify_reason)
            for path in (artifact_path, sidecar):
                try:
                    os.unlink(path)
                except OSError:
                    pass
            return None
        return manifest
    finally:
        shutil.rmtree(work, ignore_errors=True)


def verify_built_artifact(dest_dir, manifest, required_names=None):
    """Post-build gate: complete, no extras, control/checksums match."""
    artifact_path = os.path.join(dest_dir, ARTIFACT_NAME)
    if not os.path.isfile(artifact_path):
        return 'artifact_missing'
    required_names = list(required_names or [])
    if manifest.get('package_count') != len(required_names):
        return 'package_count_mismatch manifest=%s required=%s' % (
            manifest.get('package_count'), len(required_names),
        )
    extract = tempfile.mkdtemp(prefix='phase2-prereq-verify-')
    try:
        with tarfile.open(artifact_path, 'r:gz') as tf:
            members = tf.getmembers()
            member_names = [m.name for m in members]
            _validate_prereq_artifact_members(members)
            safe_extract_py3_apt_archive(
                tf, extract,
                ignore_members=(MANIFEST_NAME, INSTALL_ORDER_NAME),
            )
            _safe_extract_prereq_non_deb_files(
                tf, extract, (MANIFEST_NAME, INSTALL_ORDER_NAME),
            )
        deb_members = [n for n in member_names if n.startswith('debs/') and n.endswith('.deb')]
        unexpected = [
            n for n in member_names
            if n not in (MANIFEST_NAME, INSTALL_ORDER_NAME)
            and not n.startswith('debs/')
        ]
        if unexpected:
            return 'unexpected_members=%s' % ','.join(sorted(unexpected))
        packed = list(manifest.get('packages') or [])
        if len(deb_members) != len(packed):
            return 'tar_deb_count_mismatch tar=%s manifest=%s' % (
                len(deb_members), len(packed),
            )
        seen_files = set()
        for rec in packed:
            fn = rec.get('artifact_filename')
            if not fn:
                return 'manifest_filename_missing package=%s' % rec.get('package')
            meta_reason = required_index_metadata_reason(rec)
            if meta_reason:
                return 'verify_fail package=%s %s' % (rec.get('package'), meta_reason)
            tar_path = os.path.join(extract, 'debs', fn)
            if not os.path.isfile(tar_path):
                return 'deb_missing_in_tar file=%s' % fn
            seen_files.add('debs/%s' % fn)
            reason = verify_local_package_file(tar_path, rec)
            if reason:
                return 'verify_fail package=%s %s' % (rec.get('package'), reason)
        extra_debs = [n for n in deb_members if n not in seen_files]
        if extra_debs:
            return 'unexpected_deb=%s' % ','.join(sorted(extra_debs))
        order_path = os.path.join(extract, INSTALL_ORDER_NAME)
        if packed and not os.path.isfile(order_path):
            return 'install_order_missing'
        if packed:
            with open(order_path, 'r') as fh:
                order_text = fh.read()
            ordered_files = []
            for line in order_text.splitlines():
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                ordered_files.extend(line.split())
            manifest_files = [rec.get('artifact_filename') for rec in packed]
            if sorted(ordered_files) != sorted(manifest_files):
                return 'install_order_filename_mismatch'
        return ''
    finally:
        shutil.rmtree(extract, ignore_errors=True)


def ensure_packages_in_selective(ubuntu_root, package_rows, copy_debs=True):
    """Place resolved .debs into the selective pool using index Filename paths.

    Does not rewrite Release signatures here; Packages stanza presence is
    verified by the caller against the already-published indexes. New files
    are copied into pool/<Filename> so a later index regenerate can see them.
    """
    placed = []
    skipped = []
    for rec in package_rows:
        src = rec.get('deb_path') or ''
        filename = rec.get('filename') or ''
        if not src or not os.path.isfile(src):
            skipped.append(rec.get('package'))
            continue
        if not filename:
            skipped.append(rec.get('package'))
            eprint('PHASE2_PREREQ_SELECTIVE=FAIL package=%s reason=filename_missing' % (
                rec.get('package'),
            ))
            continue
        dest = os.path.join(ubuntu_root, filename)
        if copy_debs:
            parent = os.path.dirname(dest)
            os.makedirs(parent, exist_ok=True)
            if os.path.abspath(src) != os.path.abspath(dest):
                shutil.copy2(src, dest)
        placed.append(OrderedDict([
            ('package', rec.get('package')),
            ('filename', filename),
            ('dest', dest),
        ]))
    return OrderedDict([
        ('placed', placed),
        ('skipped', skipped),
    ])


def run_inspect(args):
    roots = collect_phase2_roots(args.source, extra_debs_from_args(args))
    out = OrderedDict([
        ('root_count', len(roots)),
        ('roots', [
            OrderedDict((k, r[k]) for k in (
                'package', 'version', 'architecture', 'depends', 'pre_depends',
                'provides', 'filename', 'source',
            ) if k in r)
            for r in roots
        ]),
    ])
    dump_json(out, args.output)
    print('PHASE2_PREREQ_ROOTS=%d' % len(roots))
    return 0


def _emit_prereq_state(dest_dir, required, count, build, publication,
                       missing_candidate=None, missing_deb=None, sha256='',
                       artifact='', target_version='', invalid_metadata=None):
    if dest_dir and build != 'PASS':
        retract_published_prerequisite_files(dest_dir)
    fields = OrderedDict([
        ('TARGET_DP_VERSION', target_version or ''),
        ('PHASE2_PREREQ_REQUIRED', required),
        ('PHASE2_PREREQ_PACKAGE_COUNT', str(count)),
        ('PHASE2_PREREQ_BUILD', build),
        ('PHASE2_PREREQ_PUBLICATION', publication),
        ('PHASE2_PREREQ_MISSING_CANDIDATE', str(len(missing_candidate or []))),
        ('PHASE2_PREREQ_MISSING_DEB', str(len(missing_deb or []))),
        ('PHASE2_PREREQ_ARTIFACT', artifact or ARTIFACT_NAME),
        ('PHASE2_PREREQ_SHA256', sha256 or ''),
    ])
    if missing_candidate:
        fields['PHASE2_PREREQ_MISSING_CANDIDATE_PACKAGES'] = ','.join(missing_candidate)
    if missing_deb:
        fields['PHASE2_PREREQ_MISSING_DEB_PACKAGES'] = ','.join(missing_deb)
    if invalid_metadata:
        fields['PHASE2_PREREQ_INVALID_METADATA_PACKAGES'] = ','.join(invalid_metadata)
    path = os.path.join(dest_dir, STATE_NAME) if dest_dir else None
    if path:
        write_prerequisite_state(path, fields)
    for key, value in fields.items():
        print('%s=%s' % (key, value))
    return fields


def _suites_from_args(args):
    raw = getattr(args, 'suites', None)
    if raw:
        return [s.strip() for s in raw.split(',') if s.strip()]
    return None


def _components_from_args(args):
    raw = getattr(args, 'components', None)
    if raw:
        return [s.strip() for s in raw.split() if s.strip()]
    return None


def _load_packages_for_args(args):
    return load_noble_packages(
        args.ubuntu_root,
        suites=_suites_from_args(args),
        components=_components_from_args(args),
    )


def _load_candidates_for_args(args):
    return load_all_package_candidates(
        args.ubuntu_root,
        suites=_suites_from_args(args),
        components=_components_from_args(args),
    )


def _target_version_from_args(args):
    return (
        getattr(args, 'target_version', None)
        or os.environ.get('DP_PHASE2_VERSION')
        or os.environ.get('TARGET_DP_VERSION')
        or ''
    )


def _make_authoritative_loader(args, dest=None):
    loaded = {'done': False, 'error': None}
    skip_fetch = bool(getattr(args, 'skip_authoritative_fetch', False))
    auth_root = getattr(args, 'authoritative_root', None) or None
    cache_root = getattr(args, 'authoritative_cache', None) or None
    if not cache_root:
        cache_root = default_authoritative_cache(
            getattr(args, 'ubuntu_root', None), dest,
        )
    archive_base = getattr(args, 'archive_base', None) or DEFAULT_ARCHIVE_BASE
    security_base = getattr(args, 'security_base', None) or DEFAULT_SECURITY_BASE
    suites = _suites_from_args(args)
    components = _components_from_args(args)

    def on_missing(name, candidates):
        if loaded['error'] is not None:
            return False
        if not loaded['done']:
            fetch = (not skip_fetch) and (not auth_root)
            try:
                auth = load_authoritative_noble_candidates(
                    authoritative_root=auth_root,
                    cache_root=cache_root if (fetch or (cache_root and os.path.isdir(cache_root))) else None,
                    fetch=fetch,
                    suites=suites,
                    components=components,
                    archive_base=archive_base,
                    security_base=security_base,
                )
            except Exception as exc:
                loaded['error'] = exc
                eprint('PHASE2_PREREQ_AUTH=FAIL reason=%s' % type(exc).__name__)
                loaded['done'] = True
                return False
            merged = merge_candidate_indexes(candidates, auth)
            candidates.clear()
            candidates.update(merged)
            loaded['done'] = True
            eprint('PHASE2_PREREQ_AUTH=LOADED packages=%d' % len(candidates))
        return bool(candidates.get(name))

    return on_missing, loaded


def _packages_from_selected(selected, names):
    packages = OrderedDict()
    for name in names:
        info = (selected or {}).get(name)
        if info:
            packages[name] = info
    return packages


def _report_unresolved_closure(closure):
    missing = [
        n for n in (closure.get('missing_from_index') or [])
        if n not in VIRTUAL_OR_BASE_SKIP and not str(n).startswith('aella-')
    ]
    failures = list(closure.get('constraint_failures') or [])
    return missing, failures


def run_resolve(args):
    roots = collect_phase2_roots(args.source, extra_debs_from_args(args))
    root_names = [r['package'] for r in roots if r.get('package')]
    extra = roots_as_index(roots)
    candidates, _prov = _load_candidates_for_args(args)
    on_missing, _loaded = _make_authoritative_loader(args)
    closure = resolve_phase2_dependency_closure(
        root_names, None, extra,
        candidate_index=candidates, on_missing_name=on_missing,
    )
    missing, failures = _report_unresolved_closure(closure)
    unsat = unsatisfied_from_acps(closure, root_names)
    selected = closure.get('selected') or OrderedDict()
    packages = _packages_from_selected(selected, unsat['unsatisfied'])
    collected = collect_artifact_packages(
        unsat['unsatisfied'], packages, pool_root=args.ubuntu_root,
    )
    plan = build_install_plan(unsat['unsatisfied'], selected)
    result = OrderedDict([
        ('roots', root_names),
        ('closure', closure),
        ('unsatisfied', unsat),
        ('collected', collected),
        ('install_plan', plan),
    ])
    dump_json(result, args.output)
    print('PHASE2_PREREQ_ROOTS=%d' % len(root_names))
    print('PHASE2_PREREQ_CLOSURE=%d' % closure.get('visited_count', 0))
    print('PHASE2_PREREQ_UNSATISFIED=%d' % len(unsat['unsatisfied']))
    print('PHASE2_PREREQ_MISSING_CANDIDATE=%d' % len(collected['missing_candidate']))
    print('PHASE2_PREREQ_MISSING_DEB=%d' % len(collected['missing_deb']))
    if failures:
        eprint('PHASE2_PREREQ_DEP=FAIL count=%d' % len(failures))
        eprint('PHASE2_PREREQ_BUILD=FAIL')
        return 2
    if (collected['missing_candidate'] or missing) and not args.allow_missing_candidate:
        eprint('PHASE2_PREREQ_CANDIDATE=NONE packages=%s' %
               ','.join(collected['missing_candidate'] or missing))
        eprint('PHASE2_PREREQ_BUILD=FAIL')
        return 2
    if collected.get('invalid_metadata'):
        eprint('PHASE2_PREREQ_METADATA=FAIL packages=%s' %
               ','.join(collected['invalid_metadata']))
        eprint('PHASE2_PREREQ_BUILD=FAIL')
        return 2
    if collected['missing_deb'] and not getattr(args, 'allow_missing_deb', False):
        eprint('PHASE2_PREREQ_MISSING_DEB=%s' % ','.join(collected['missing_deb']))
        eprint('PHASE2_PREREQ_BUILD=FAIL')
        return 4
    return 0


def run_build(args):
    dest = args.dest
    os.makedirs(dest, exist_ok=True)
    target_version = _target_version_from_args(args)
    roots = collect_phase2_roots(args.source, extra_debs_from_args(args))
    root_names = [r['package'] for r in roots if r.get('package')]
    extra = roots_as_index(roots)
    candidates, _prov = _load_candidates_for_args(args)
    on_missing, _loaded = _make_authoritative_loader(args, dest=dest)
    closure = resolve_phase2_dependency_closure(
        root_names, None, extra,
        candidate_index=candidates, on_missing_name=on_missing,
    )
    missing, failures = _report_unresolved_closure(closure)
    unsat = unsatisfied_from_acps(closure, root_names)
    selected = closure.get('selected') or OrderedDict()
    packages = _packages_from_selected(selected, unsat['unsatisfied'])
    collected = collect_artifact_packages(
        unsat['unsatisfied'], packages, pool_root=args.ubuntu_root,
    )
    if failures:
        eprint('PHASE2_PREREQ_DEP=FAIL count=%d' % len(failures))
        _emit_prereq_state(
            dest, 'YES' if unsat['unsatisfied'] else 'NO',
            len(unsat['unsatisfied']), 'FAIL', 'FAIL',
            missing_candidate=collected['missing_candidate'],
            missing_deb=collected['missing_deb'],
            target_version=target_version,
            invalid_metadata=collected.get('invalid_metadata'),
        )
        eprint('PHASE2_PREREQ_BUILD=FAIL reason=dependency_constraint')
        return 2
    if (collected['missing_candidate'] or missing) and not args.allow_missing_candidate:
        names = collected['missing_candidate'] or missing
        eprint('PHASE2_PREREQ_CANDIDATE=NONE packages=%s' % ','.join(names))
        _emit_prereq_state(
            dest, 'YES',
            max(len(unsat['unsatisfied']), len(names)), 'FAIL', 'FAIL',
            missing_candidate=names,
            missing_deb=collected['missing_deb'],
            target_version=target_version,
            invalid_metadata=collected.get('invalid_metadata'),
        )
        eprint('PHASE2_PREREQ_BUILD=FAIL')
        return 2
    if collected.get('invalid_metadata'):
        eprint('PHASE2_PREREQ_METADATA=FAIL packages=%s' %
               ','.join(collected['invalid_metadata']))
        _emit_prereq_state(
            dest, 'YES', len(unsat['unsatisfied']), 'FAIL', 'FAIL',
            missing_candidate=collected['missing_candidate'],
            missing_deb=collected['missing_deb'],
            target_version=target_version,
            invalid_metadata=collected.get('invalid_metadata'),
        )
        eprint('PHASE2_PREREQ_BUILD=FAIL reason=invalid_metadata')
        return 2

    skip_acquire = getattr(args, 'skip_acquire', False)
    if collected['missing_deb'] and not skip_acquire:
        acquire_missing_debs(
            collected,
            args.ubuntu_root,
            archive_base=getattr(args, 'archive_base', None),
            security_base=getattr(args, 'security_base', None),
        )
        collected['missing_deb'] = [
            rec.get('package') for rec in collected.get('packages') or []
            if rec.get('candidate') != 'none' and not rec.get('deb_path')
        ]

    if collected['missing_deb']:
        eprint('PHASE2_PREREQ_MISSING_DEB=%s' % ','.join(collected['missing_deb']))
        _emit_prereq_state(
            dest, 'YES', len(unsat['unsatisfied']), 'FAIL', 'FAIL',
            missing_candidate=collected['missing_candidate'],
            missing_deb=collected['missing_deb'],
            target_version=target_version,
            invalid_metadata=collected.get('invalid_metadata'),
        )
        eprint('PHASE2_PREREQ_BUILD=FAIL reason=missing_deb')
        return 4

    required_rows = [
        rec for rec in collected.get('packages') or []
        if rec.get('candidate') != 'none'
    ]
    plan = build_install_plan(
        [rec.get('package') for rec in required_rows if rec.get('package')],
        selected,
    )
    required = 'YES' if required_rows else 'NO'
    if not required_rows:
        manifest = build_prerequisite_artifact([], dest, install_plan=plan)
        if manifest is None:
            _emit_prereq_state(
                dest, 'NO', 0, 'FAIL', 'FAIL', target_version=target_version,
            )
            return 5
        _emit_prereq_state(
            dest, 'NO', 0, 'PASS', 'PASS',
            sha256=manifest.get('sha256'),
            artifact=ARTIFACT_NAME,
            target_version=target_version,
        )
        print('PHASE2_PREREQ_ARTIFACT=%s' % manifest.get('artifact_path'))
        print('PHASE2_PREREQ_PACKAGE_COUNT=0')
        print('PHASE2_PREREQ_SHA256=%s' % manifest.get('sha256'))
        return 0

    manifest = build_prerequisite_artifact(
        required_rows, dest, install_plan=plan,
    )
    if manifest is None:
        _emit_prereq_state(
            dest, required, len(required_rows), 'FAIL', 'FAIL',
            missing_candidate=collected['missing_candidate'],
            missing_deb=collected['missing_deb'],
            target_version=target_version,
            invalid_metadata=collected.get('invalid_metadata'),
        )
        return 5
    if getattr(args, 'ensure_selective', False):
        placed = ensure_packages_in_selective(args.ubuntu_root, required_rows)
        if placed.get('skipped'):
            eprint('PHASE2_PREREQ_SELECTIVE=FAIL skipped=%s' %
                   ','.join(p for p in placed['skipped'] if p))
            _emit_prereq_state(
                dest, required, len(required_rows), 'FAIL', 'FAIL',
                target_version=target_version,
            )
            return 5
    _emit_prereq_state(
        dest, required, manifest.get('package_count', 0), 'PASS', 'PASS',
        sha256=manifest.get('sha256'),
        artifact=ARTIFACT_NAME,
        target_version=target_version,
    )
    print('PHASE2_PREREQ_ARTIFACT=%s' % manifest.get('artifact_path'))
    print('PHASE2_PREREQ_PACKAGE_COUNT=%d' % manifest.get('package_count', 0))
    print('PHASE2_PREREQ_SHA256=%s' % manifest.get('sha256'))
    return 0


def run_transaction(args):
    text = args.simulation
    if args.simulation_file:
        with open(args.simulation_file, 'r') as fh:
            text = fh.read()
    result = transaction_is_safe(text)
    dump_json(result, args.output)
    print('PHASE2_PREREQ_TRANSACTION_SAFE=%s' % ('YES' if result['safe'] else 'NO'))
    if result['blocked_removals']:
        print('PHASE2_PREREQ_BLOCKED_REMOVALS=%s' % ','.join(result['blocked_removals']))
        return 3
    return 0


def run_validate_state(args):
    dest = args.dest
    state_path = args.state or (os.path.join(dest, STATE_NAME) if dest else '')
    if not state_path or not os.path.isfile(state_path):
        eprint('PHASE2_PREREQ_STATE=FAIL reason=state_missing')
        return 1
    with open(state_path, 'r') as fh:
        fields = parse_prereq_state_text(fh.read())
    require_files = not getattr(args, 'fields_only', False)
    reason = validate_prereq_state_contract(
        fields, dest_dir=dest, require_files=require_files,
    )
    if reason:
        eprint('PHASE2_PREREQ_STATE=FAIL reason=%s' % reason)
        return 1
    print('PHASE2_PREREQ_STATE=PASS required=%s count=%s' % (
        fields.get('PHASE2_PREREQ_REQUIRED'),
        fields.get('PHASE2_PREREQ_PACKAGE_COUNT'),
    ))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description='Phase 2 Ubuntu prerequisite dependency closure',
    )
    sub = parser.add_subparsers(dest='cmd')

    p_ins = sub.add_parser('inspect')
    p_ins.add_argument('--source', required=True)
    p_ins.add_argument('--extra-deb', action='append', default=[])
    p_ins.add_argument('--output')
    p_ins.set_defaults(func=run_inspect)

    p_res = sub.add_parser('resolve')
    p_res.add_argument('--source', required=True)
    p_res.add_argument('--ubuntu-root', required=True)
    p_res.add_argument('--extra-deb', action='append', default=[])
    p_res.add_argument('--suites')
    p_res.add_argument('--components')
    p_res.add_argument('--output')
    p_res.add_argument('--archive-base', default=DEFAULT_ARCHIVE_BASE)
    p_res.add_argument('--security-base', default=DEFAULT_SECURITY_BASE)
    p_res.add_argument('--authoritative-root')
    p_res.add_argument('--authoritative-cache')
    p_res.add_argument('--skip-authoritative-fetch', action='store_true')
    p_res.add_argument('--allow-missing-candidate', action='store_true')
    p_res.add_argument('--allow-missing-deb', action='store_true')
    p_res.set_defaults(func=run_resolve)

    p_bld = sub.add_parser('build')
    p_bld.add_argument('--source', required=True)
    p_bld.add_argument('--ubuntu-root', required=True)
    p_bld.add_argument('--dest', required=True)
    p_bld.add_argument('--extra-deb', action='append', default=[])
    p_bld.add_argument('--suites')
    p_bld.add_argument('--components')
    p_bld.add_argument('--archive-base', default=DEFAULT_ARCHIVE_BASE)
    p_bld.add_argument('--security-base', default=DEFAULT_SECURITY_BASE)
    p_bld.add_argument('--authoritative-root')
    p_bld.add_argument('--authoritative-cache')
    p_bld.add_argument('--skip-authoritative-fetch', action='store_true')
    p_bld.add_argument('--target-version', default='')
    p_bld.add_argument('--allow-missing-candidate', action='store_true')
    p_bld.add_argument('--skip-acquire', action='store_true')
    p_bld.add_argument('--ensure-selective', action='store_true')
    p_bld.set_defaults(func=run_build)

    p_tx = sub.add_parser('transaction-check')
    p_tx.add_argument('--simulation')
    p_tx.add_argument('--simulation-file')
    p_tx.add_argument('--output')
    p_tx.set_defaults(func=run_transaction)

    p_st = sub.add_parser('validate-state')
    p_st.add_argument('--state')
    p_st.add_argument('--dest')
    p_st.add_argument('--fields-only', action='store_true')
    p_st.set_defaults(func=run_validate_state)

    args = parser.parse_args(argv)
    if not getattr(args, 'func', None):
        parser.print_help()
        return 1
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
