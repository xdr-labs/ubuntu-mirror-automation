"""AWS OS Core / selective-plan semantic completeness helpers.

Used by plan generation, selective-mirror validation, and OS Core verify to
fail closed when an artifact claims (or is required to provide) AWS DP upgrade
coverage but lacks the linux-aws package family on one or more hops.

Authoritative AWS kernel contract (aligned with client postboot gate):
  each AWS hop must include BOTH:
    - linux-aws
    - linux-image-aws
  xenial-to-bionic additionally requires snapd when aws coverage is required.

Python 3.5+; standard library only.
"""
from __future__ import print_function, unicode_literals

import os
import re
from collections import OrderedDict

try:
    from discovery_profiles import HOPS, aws_kernel_package_name
except ImportError:  # pragma: no cover
    from scripts.lib.discovery_profiles import HOPS, aws_kernel_package_name  # type: ignore

# Hermetic/unit-test escape only. Production builders must never set these.
ALLOW_GENERIC_ONLY_ENV = 'UM_ALLOW_GENERIC_ONLY_DISCOVERY'
HERMETIC_TEST_ENV = 'MM_HERMETIC_TEST_MODE'

# Authoritative metapackage contract shared with postboot validation.
REQUIRED_AWS_METAPACKAGES = (
    'linux-aws',
    'linux-image-aws',
)
AWS_METAPACKAGE_NAMES = frozenset(REQUIRED_AWS_METAPACKAGES)

# Filename / relative-pool markers for physical tree scans (not version pins).
AWS_DEB_NAME_RE = re.compile(
    r'(?:^|/)(?:linux-aws_|linux-image-aws_|linux-headers-aws_|'
    r'linux-image-[^/]+-aws_|linux-modules-[^/]+-aws_|'
    r'linux-headers-[^/]+-aws_|linux-aws-[^/]+-headers-)',
    re.I,
)

SNAPD_REQUIRED_HOPS = frozenset(('xenial-to-bionic',))


def _env_truthy(name):
    return os.environ.get(name, '') in ('1', 'true', 'yes', 'on')


def allow_generic_only_discovery():
    """True only when BOTH hermetic test mode and explicit escape are set.

    Production with only UM_ALLOW_GENERIC_ONLY_DISCOVERY=1 must NOT bypass.
    """
    return _env_truthy(HERMETIC_TEST_ENV) and _env_truthy(ALLOW_GENERIC_ONLY_ENV)


def plan_requires_aws_coverage(plan, require_aws_profile=None):
    """Return True when this plan/artifact must include AWS kernel packages.

    Rules:
      - discovery_profiles includes ``aws`` → always require completeness
      - require_aws_profile=True → require (production OS Core / plan-selective)
      - require_aws_profile=False → never require
      - require_aws_profile=None → only require when aws profile is present

    Production plan-selective forces aws into discovery_profiles. Production
    OS Core verify/build passes require_aws_profile=True so generic-only
    payloads cannot PASS structural verification.
    """
    profiles = list(plan.get('discovery_profiles') or [])
    if require_aws_profile is False:
        return False
    if 'aws' in profiles:
        return True
    if require_aws_profile is True:
        return not allow_generic_only_discovery()
    return False


def _package_name(row):
    return (row.get('package') or row.get('Package') or '').strip()


def _row_hops(row):
    hops = row.get('source_hops') or []
    if hops:
        return list(hops)
    hop = row.get('hop') or ''
    return [hop] if hop else []


def collect_aws_packages_by_hop(rows):
    """Map hop → list of AWS-family package rows from plan debs/package rows."""
    by_hop = OrderedDict((h, []) for h in HOPS)
    for row in rows or []:
        name = _package_name(row)
        if not aws_kernel_package_name(name):
            continue
        for hop in _row_hops(row):
            if hop in by_hop:
                by_hop[hop].append(row)
    return by_hop


def hop_required_aws_metapackages_present(rows_for_hop):
    """True iff BOTH linux-aws and linux-image-aws are present (postboot contract)."""
    names = {_package_name(r) for r in rows_for_hop or []}
    return all(m in names for m in REQUIRED_AWS_METAPACKAGES)


# Back-compat alias used by older call sites/tests.
def hop_has_aws_metapackage(rows_for_hop):
    return hop_required_aws_metapackages_present(rows_for_hop)


def hop_has_snapd(rows, hop):
    for row in rows or []:
        if hop not in _row_hops(row) and row.get('hop') != hop:
            continue
        if _package_name(row) == 'snapd':
            return True
    return False


def validate_plan_aws_completeness(plan, package_rows=None, require_aws_profile=None):
    """Validate selective plan semantic AWS coverage.

    Returns (ok, errors, details OrderedDict).
    """
    errors = []
    profiles = list(plan.get('discovery_profiles') or [])
    requires = plan_requires_aws_coverage(plan, require_aws_profile=require_aws_profile)
    details = OrderedDict([
        ('requires_aws_coverage', requires),
        ('discovery_profiles', profiles),
        ('allow_generic_only', allow_generic_only_discovery()),
        ('required_aws_metapackages', list(REQUIRED_AWS_METAPACKAGES)),
        ('hops', OrderedDict()),
    ])

    if not requires:
        details['result'] = 'SKIP'
        return True, errors, details

    if 'aws' not in profiles:
        errors.append(
            'aws_profile_required: offline-upgrade-selective plan missing '
            'discovery profile aws (got: %s)' % (','.join(profiles) or 'none')
        )

    rows = package_rows
    if rows is None:
        rows = list(plan.get('debs') or []) + list(plan.get('aws_kernel_packages_sample') or [])
    deb_rows = list(plan.get('debs') or [])
    combined = list(rows or []) + deb_rows

    by_hop = collect_aws_packages_by_hop(combined)
    counts = plan.get('counts') or {}
    sample = plan.get('aws_kernel_packages_sample') or []
    if int(counts.get('aws_kernel_package_rows') or 0) <= 0 and not sample and not any(by_hop.values()):
        errors.append(
            'aws_kernel_packages_missing: plan claims/requires AWS coverage but '
            'aws_kernel_package_rows=0'
        )

    for hop in HOPS:
        hop_rows = by_hop.get(hop) or []
        sample_hop = [r for r in sample if r.get('hop') == hop]
        effective = hop_rows or sample_hop
        ok_meta = hop_required_aws_metapackages_present(effective)
        missing_meta = [
            m for m in REQUIRED_AWS_METAPACKAGES
            if m not in {_package_name(r) for r in effective}
        ]
        details['hops'][hop] = OrderedDict([
            ('aws_package_rows', len(effective)),
            ('has_required_aws_metapackages', ok_meta),
            ('missing_aws_metapackages', missing_meta),
        ])
        if not effective:
            errors.append(
                'aws_kernel_missing_hop: %s has no linux-aws family packages' % hop
            )
        elif not ok_meta:
            errors.append(
                'aws_kernel_metapackage_missing_hop: %s lacks required '
                'metapackages %s (postboot contract requires both linux-aws and '
                'linux-image-aws)' % (hop, ','.join(missing_meta))
            )

        # snapd: required for AWS xenial→bionic whenever AWS coverage is required
        # (including production OS Core verify with require_aws_profile=True).
        if hop in SNAPD_REQUIRED_HOPS:
            snap_ok = hop_has_snapd(combined, hop) or hop_has_snapd(
                plan.get('debs') or [], hop
            )
            if package_rows is not None:
                snap_ok = snap_ok or any(
                    r.get('hop') == hop and _package_name(r) == 'snapd'
                    for r in package_rows
                )
            details['hops'][hop]['snapd_present'] = snap_ok
            if not snap_ok:
                errors.append(
                    'snapd_missing_hop: %s requires snapd when AWS coverage is '
                    'required (AWS discovery installs snapd on this hop)' % hop
                )

    details['result'] = 'PASS' if not errors else 'FAIL'
    return not errors, errors, details


def deb_basename_to_package(filename):
    """Map ``name_version_arch.deb`` (or URL-encoded) basename → package name."""
    base = os.path.basename(filename)
    if base.endswith('.deb'):
        base = base[:-4]
    # Undo common URL encoding in discovery filenames.
    try:
        from urllib.parse import unquote
    except ImportError:  # pragma: no cover
        from urllib import unquote  # type: ignore
    base = unquote(base)
    # Debian convention: name_version_arch — version/arch may contain underscores
    # only in rare cases; package names for our contract do not contain '_'.
    if '_' not in base:
        return base
    return base.split('_', 1)[0]


def iter_pool_deb_basenames(ubuntu_or_hop_root):
    """Yield .deb basenames under a hop ubuntu root or payload hops tree."""
    if not ubuntu_or_hop_root or not os.path.isdir(ubuntu_or_hop_root):
        return
    for dirpath, _dns, filenames in os.walk(ubuntu_or_hop_root):
        for fn in filenames:
            if fn.endswith('.deb'):
                yield fn


def hop_pool_package_names(ubuntu_root):
    names = set()
    for fn in iter_pool_deb_basenames(ubuntu_root):
        names.add(deb_basename_to_package(fn))
    return names


def hop_pool_has_aws_debs(ubuntu_root):
    for fn in iter_pool_deb_basenames(ubuntu_root):
        pkg = deb_basename_to_package(fn)
        if pkg in AWS_METAPACKAGE_NAMES or aws_kernel_package_name(pkg):
            return True
        if AWS_DEB_NAME_RE.search(fn):
            return True
    return False


def hop_pool_aws_contract(ubuntu_root):
    """Physical hop contract used by OS Core / selective tree validation."""
    names = hop_pool_package_names(ubuntu_root)
    missing_meta = [m for m in REQUIRED_AWS_METAPACKAGES if m not in names]
    return OrderedDict([
        ('package_names_sample', sorted(names)[:40]),
        ('has_required_aws_metapackages', not missing_meta),
        ('missing_aws_metapackages', missing_meta),
        ('has_snapd', 'snapd' in names),
        ('has_any_aws_family', hop_pool_has_aws_debs(ubuntu_root)),
    ])


def validate_tree_aws_completeness(selective_or_payload_root, plan=None, require_aws_profile=None):
    """Validate materialized selective/OS Core payload tree for AWS contract.

    ``selective_or_payload_root`` may be:
      - selective published root containing hops/<hop>/ubuntu/pool
      - OS Core payload root containing hops/<hop>/...

    When AWS coverage is required, each hop must contain BOTH ``linux-aws`` and
    ``linux-image-aws`` .deb metapackages. A lone versioned
    ``linux-image-*-aws`` package is insufficient. xenial-to-bionic also
    requires physical ``snapd``.
    """
    plan = plan or {}
    requires = plan_requires_aws_coverage(plan, require_aws_profile=require_aws_profile)
    errors = []
    details = OrderedDict([
        ('requires_aws_coverage', requires),
        ('root', selective_or_payload_root),
        ('required_aws_metapackages', list(REQUIRED_AWS_METAPACKAGES)),
        ('hops', OrderedDict()),
    ])
    if not requires:
        details['result'] = 'SKIP'
        return True, errors, details

    for hop in HOPS:
        candidates = [
            os.path.join(selective_or_payload_root, 'hops', hop, 'ubuntu'),
            os.path.join(selective_or_payload_root, 'hops', hop),
            os.path.join(selective_or_payload_root, hop, 'ubuntu'),
            os.path.join(selective_or_payload_root, hop),
        ]
        ubuntu = next((c for c in candidates if os.path.isdir(c)), candidates[0])
        contract = hop_pool_aws_contract(ubuntu)
        details['hops'][hop] = OrderedDict([
            ('ubuntu_root', ubuntu),
            ('contract', contract),
        ])
        if not contract['has_required_aws_metapackages']:
            errors.append(
                'aws_metapackage_deb_missing_in_tree: %s missing %s '
                '(versioned linux-image-*-aws alone is insufficient)'
                % (hop, ','.join(contract['missing_aws_metapackages']))
            )
        if hop in SNAPD_REQUIRED_HOPS and not contract['has_snapd']:
            errors.append(
                'snapd_deb_missing_in_tree: %s requires physical snapd .deb '
                'when AWS coverage is required' % hop
            )

    details['result'] = 'PASS' if not errors else 'FAIL'
    return not errors, errors, details


def assert_plan_aws_completeness(plan, package_rows=None, require_aws_profile=None):
    ok, errors, details = validate_plan_aws_completeness(
        plan, package_rows=package_rows, require_aws_profile=require_aws_profile,
    )
    if not ok:
        raise ValueError('; '.join(errors))
    return details
