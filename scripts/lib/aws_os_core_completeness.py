"""AWS OS Core / selective-plan semantic completeness helpers.

Used by plan generation, selective-mirror validation, and OS Core verify to
fail closed when an artifact claims (or is required to provide) AWS DP upgrade
coverage but lacks the linux-aws package family on one or more hops.

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

# Hermetic/unit-test escape only. Production builders must never set this.
ALLOW_GENERIC_ONLY_ENV = 'UM_ALLOW_GENERIC_ONLY_DISCOVERY'

# Target-series metapackage names that must appear for AWS hops.
AWS_METAPACKAGE_NAMES = frozenset((
    'linux-aws',
    'linux-image-aws',
))

# Filename / relative-pool markers for physical tree scans (not version pins).
AWS_DEB_NAME_RE = re.compile(
    r'(?:^|/)(?:linux-aws_|linux-image-aws_|linux-headers-aws_|'
    r'linux-image-[^/]+-aws_|linux-modules-[^/]+-aws_|'
    r'linux-headers-[^/]+-aws_|linux-aws-[^/]+-headers-)',
    re.I,
)

SNAPD_REQUIRED_HOPS = frozenset(('xenial-to-bionic',))


def allow_generic_only_discovery():
    if os.environ.get(ALLOW_GENERIC_ONLY_ENV, '') in ('1', 'true', 'yes', 'on'):
        return True
    # Existing hermetic test harnesses set MM_HERMETIC_TEST_MODE=1.
    if os.environ.get('MM_HERMETIC_TEST_MODE', '') in ('1', 'true', 'yes', 'on'):
        return True
    return False


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


def hop_has_aws_metapackage(rows_for_hop):
    names = {_package_name(r) for r in rows_for_hop or []}
    return bool(names & AWS_METAPACKAGE_NAMES) or any(
        n.startswith('linux-image-') and n.endswith('-aws') for n in names
    )


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
    # Prefer full package row list when callers pass it; also accept plan debs.
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
        # Also accept sample rows tagged with hop when debs omitted in lean fixtures.
        sample_hop = [r for r in sample if r.get('hop') == hop]
        effective = hop_rows or sample_hop
        ok_meta = hop_has_aws_metapackage(effective)
        details['hops'][hop] = OrderedDict([
            ('aws_package_rows', len(effective)),
            ('has_aws_metapackage_or_image', ok_meta),
        ])
        if not effective:
            errors.append(
                'aws_kernel_missing_hop: %s has no linux-aws family packages' % hop
            )
        elif not ok_meta:
            errors.append(
                'aws_kernel_metapackage_missing_hop: %s lacks linux-aws / '
                'linux-image-aws / linux-image-*-aws' % hop
            )

        if hop in SNAPD_REQUIRED_HOPS and 'aws' in profiles:
            # AWS xenial→bionic discovery installs snapd; omit only if aws absent.
            snap_ok = hop_has_snapd(combined, hop) or hop_has_snapd(
                plan.get('debs') or [], hop
            )
            # package_rows from build_plan use hop field.
            if package_rows is not None:
                snap_ok = snap_ok or any(
                    r.get('hop') == hop and _package_name(r) == 'snapd'
                    for r in package_rows
                )
            details['hops'][hop]['snapd_present'] = snap_ok
            if not snap_ok:
                errors.append(
                    'snapd_missing_hop: %s requires snapd when aws profile is '
                    'included (AWS discovery installs snapd on this hop)' % hop
                )

    details['result'] = 'PASS' if not errors else 'FAIL'
    return not errors, errors, details


def iter_pool_deb_basenames(ubuntu_or_hop_root):
    """Yield .deb basenames under a hop ubuntu root or payload hops tree."""
    if not ubuntu_or_hop_root or not os.path.isdir(ubuntu_or_hop_root):
        return
    for dirpath, _dns, filenames in os.walk(ubuntu_or_hop_root):
        for fn in filenames:
            if fn.endswith('.deb'):
                yield fn


def hop_pool_has_aws_debs(ubuntu_root):
    for fn in iter_pool_deb_basenames(ubuntu_root):
        if AWS_DEB_NAME_RE.search(fn) or aws_kernel_package_name(
            fn.rsplit('_', 2)[0] if '_' in fn else fn
        ):
            return True
        # Filename forms: linux-image-5.4.0-1103-aws_....deb
        base = fn.split('_', 1)[0]
        if aws_kernel_package_name(base):
            return True
    return False


def validate_tree_aws_completeness(selective_or_payload_root, plan=None, require_aws_profile=None):
    """Validate materialized selective/OS Core payload tree for AWS debs.

    ``selective_or_payload_root`` may be:
      - selective published root containing hops/<hop>/ubuntu/pool
      - OS Core payload root containing hops/<hop>/...
    """
    plan = plan or {}
    requires = plan_requires_aws_coverage(plan, require_aws_profile=require_aws_profile)
    # Physical OS Core production path: if no plan profiles, still require AWS
    # unless hermetic escape — callers pass require_aws_profile=True for OS Core.
    errors = []
    details = OrderedDict([
        ('requires_aws_coverage', requires),
        ('root', selective_or_payload_root),
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
        present = hop_pool_has_aws_debs(ubuntu)
        details['hops'][hop] = OrderedDict([
            ('ubuntu_root', ubuntu),
            ('aws_debs_present', present),
        ])
        if not present:
            errors.append(
                'aws_deb_missing_in_tree: %s has no linux-aws family .deb files'
                % hop
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
