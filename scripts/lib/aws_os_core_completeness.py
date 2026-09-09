"""AWS OS Core / selective-plan semantic completeness helpers.

Used by plan generation, selective-mirror validation, OS Core verify, and
client gate generation to fail closed when an artifact claims (or is required
to provide) AWS DP upgrade coverage.

Authoritative contract is discovery-derived (generic∪aws union rows), not
Ubuntu series major.minor floors:

  each AWS hop must include exact target identities for:
    - linux-aws
    - linux-image-aws
    - versioned linux-image-<abi>-aws (and boot-related modules when present)
  xenial-to-bionic additionally requires snapd with exact target identity.

Python 3.5+; standard library only.
"""
from __future__ import print_function, unicode_literals

import hashlib
import json
import os
import re
from collections import OrderedDict

try:
    from urllib.parse import unquote
except ImportError:  # pragma: no cover
    from urllib import unquote  # type: ignore

try:
    from discovery_profiles import HOPS, aws_kernel_package_name
except ImportError:  # pragma: no cover
    from scripts.lib.discovery_profiles import HOPS, aws_kernel_package_name  # type: ignore

# Hermetic/unit-test escape only. Production builders must never set these.
ALLOW_GENERIC_ONLY_ENV = 'UM_ALLOW_GENERIC_ONLY_DISCOVERY'
HERMETIC_TEST_ENV = 'MM_HERMETIC_TEST_MODE'
# Name-only AWS tree validation is hermetic-only (same dual escape).
ALLOW_NAME_ONLY_AWS_ENV = 'UM_ALLOW_NAME_ONLY_AWS_VALIDATION'

# Authoritative metapackage names shared with client gates.
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

# Hop ↔ Ubuntu VERSION_ID (target of the hop = completed userland series).
HOP_TARGET_VERSION_ID = OrderedDict([
    ('xenial-to-bionic', '18.04'),
    ('bionic-to-focal', '20.04'),
    ('focal-to-jammy', '22.04'),
    ('jammy-to-noble', '24.04'),
])
HOP_SOURCE_VERSION_ID = OrderedDict([
    ('xenial-to-bionic', '16.04'),
    ('bionic-to-focal', '18.04'),
    ('focal-to-jammy', '20.04'),
    ('jammy-to-noble', '22.04'),
])
VERSION_ID_TO_TARGET_HOP = OrderedDict(
    (v, h) for h, v in HOP_TARGET_VERSION_ID.items()
)

CONTRACT_SCHEMA_VERSION = 1

# Embedded OS Core / selective state relative path for the public contract artifact.
AWS_SEMANTIC_CONTRACT_JSON_REL = os.path.join('state', 'aws-semantic-contract.json')


def _env_truthy(name):
    return os.environ.get(name, '') in ('1', 'true', 'yes', 'on')


def _canonical_contract_for_hash(contract):
    """Return a plain dict suitable for stable hashing (no contract_sha256)."""
    if not contract:
        return {}
    # Round-trip through JSON so nested OrderedDicts become plain dicts.
    body = json.loads(json.dumps(contract, sort_keys=True, default=str))
    body.pop('contract_sha256', None)
    return body


def aws_semantic_contract_sha256(contract):
    """Stable SHA256 over the authoritative semantic contract body."""
    body = _canonical_contract_for_hash(contract)
    blob = json.dumps(body, sort_keys=True, separators=(',', ':'), ensure_ascii=True)
    return hashlib.sha256(blob.encode('utf-8')).hexdigest()


def attach_contract_sha256(contract):
    """Attach/refresh contract_sha256 on a contract OrderedDict/dict."""
    if not contract:
        return contract
    sha = aws_semantic_contract_sha256(contract)
    if isinstance(contract, OrderedDict):
        contract['contract_sha256'] = sha
    else:
        contract['contract_sha256'] = sha
    return contract


def verify_contract_checksum(contract, expected_sha=None):
    """Return (ok, actual_sha, error_message)."""
    if not contract or not (contract.get('hops') or {}):
        return False, '', 'aws_semantic_contract_missing'
    schema = contract.get('schema_version')
    try:
        schema_i = int(schema)
    except (TypeError, ValueError):
        schema_i = -1
    if schema_i != CONTRACT_SCHEMA_VERSION:
        return False, '', 'aws_semantic_contract_schema_unsupported:%s' % schema
    actual = aws_semantic_contract_sha256(contract)
    embedded = (contract.get('contract_sha256') or '').strip()
    if embedded and embedded != actual:
        return False, actual, (
            'aws_semantic_contract_checksum_mismatch embedded=%s actual=%s'
            % (embedded[:16], actual[:16])
        )
    if expected_sha:
        expected_sha = expected_sha.strip()
        if expected_sha != actual:
            return False, actual, (
                'aws_semantic_contract_checksum_mismatch expected=%s actual=%s'
                % (expected_sha[:16], actual[:16])
            )
    return True, actual, ''


def minimal_public_aws_semantic_contract(contract):
    """Public-safe contract for OS Core embedding (no host paths / secrets).

    The plan ``aws_semantic_contract`` is already identity-only. Embed a deep copy
    with a verified ``contract_sha256`` so plan/client/OS Core share one authority.
    """
    if not contract:
        return OrderedDict()
    raw = json.loads(json.dumps(contract, sort_keys=True, default=str))
    attach_contract_sha256(raw)
    return raw


def load_aws_semantic_contract_from_plan_file(plan_path):
    """Load and verify aws_semantic_contract from a selective plan JSON file.

    Returns (contract, contract_sha256).
    Raises ValueError on fail-closed conditions.
    """
    if not plan_path or not os.path.isfile(plan_path):
        raise ValueError('aws_semantic_contract_absent: plan missing path=%s' % plan_path)
    try:
        with open(plan_path, 'r') as fh:
            plan = json.load(fh)
    except (OSError, ValueError, TypeError) as exc:
        raise ValueError('aws_semantic_contract_absent: plan unreadable (%s)' % exc)
    return load_aws_semantic_contract_from_plan(plan)


def load_aws_semantic_contract_from_plan(plan):
    """Extract and verify contract from a plan dict. Returns (contract, sha256)."""
    plan = plan or {}
    contract = plan.get('aws_semantic_contract')
    if not contract or not (contract.get('hops') or {}):
        raise ValueError('aws_semantic_contract_absent')
    expected = (
        (plan.get('aws_semantic_contract_sha256') or '').strip()
        or (contract.get('contract_sha256') or '').strip()
    )
    if not expected:
        raise ValueError('aws_semantic_contract_checksum_absent')
    ok, actual, err = verify_contract_checksum(contract, expected_sha=expected)
    if not ok:
        raise ValueError(err or 'aws_semantic_contract_checksum_mismatch')
    # Ensure embedded field is present for downstream consumers.
    contract = dict(contract)
    contract['contract_sha256'] = actual
    return contract, actual


def _is_hex64(value):
    s = (value or '').strip().lower()
    if len(s) != 64:
        return False
    try:
        int(s, 16)
    except ValueError:
        return False
    return True


def _read_ready_kv_fields(ready_path):
    fields = {}
    with open(ready_path, 'r') as fh:
        for line in fh:
            line = line.strip()
            if '=' in line:
                k, v = line.split('=', 1)
                fields[k.strip()] = v.strip()
    return fields


def generation_tuple_from_plan(plan):
    """Extract the selective generation identity tuple from a plan dict."""
    plan = plan or {}
    contract = plan.get('aws_semantic_contract') or {}
    return OrderedDict([
        ('plan_checksum', (plan.get('plan_checksum') or '').strip().lower()),
        (
            'discovery_artifact_checksum',
            (plan.get('discovery_artifact_checksum') or '').strip().lower(),
        ),
        (
            'aws_semantic_contract_sha256',
            (
                (plan.get('aws_semantic_contract_sha256') or '').strip()
                or (contract.get('contract_sha256') or '').strip()
            ).lower(),
        ),
    ])


def generation_tuple_from_ready(fields):
    """Extract the selective generation identity tuple from READY fields."""
    fields = fields or {}
    return OrderedDict([
        (
            'plan_checksum',
            (
                fields.get('selective_plan_checksum')
                or fields.get('plan_checksum')
                or ''
            ).strip().lower(),
        ),
        (
            'discovery_artifact_checksum',
            (fields.get('discovery_artifact_checksum') or '').strip().lower(),
        ),
        (
            'aws_semantic_contract_sha256',
            (fields.get('aws_semantic_contract_sha256') or '').strip().lower(),
        ),
    ])


def _require_generation_tuple(tuple_doc, source):
    for key in (
        'plan_checksum',
        'discovery_artifact_checksum',
        'aws_semantic_contract_sha256',
    ):
        val = (tuple_doc.get(key) or '').strip().lower()
        if not _is_hex64(val):
            raise ValueError(
                'selective_generation_%s_incomplete:%s' % (source, key)
            )
        tuple_doc[key] = val
    return tuple_doc


def compare_generation_tuples(ready_tuple, plan_tuple):
    """Compare READY vs plan generation tuples. Raises ValueError on drift."""
    ready_tuple = _require_generation_tuple(dict(ready_tuple), 'ready')
    plan_tuple = _require_generation_tuple(dict(plan_tuple), 'plan')
    for key in (
        'plan_checksum',
        'discovery_artifact_checksum',
        'aws_semantic_contract_sha256',
    ):
        if ready_tuple[key] != plan_tuple[key]:
            raise ValueError(
                'selective_generation_drift:%s ready=%s plan=%s'
                % (key, ready_tuple[key][:16], plan_tuple[key][:16])
            )
    return plan_tuple


def write_ready_generation_marker(
    ready_path,
    plan_checksum,
    discovery_artifact_checksum,
    aws_semantic_contract_sha256,
    extra_lines=None,
):
    """Atomically write a minimal READY receipt with the generation tuple."""
    plan_checksum = (plan_checksum or '').strip().lower()
    discovery_artifact_checksum = (discovery_artifact_checksum or '').strip().lower()
    aws_semantic_contract_sha256 = (aws_semantic_contract_sha256 or '').strip().lower()
    _require_generation_tuple(
        {
            'plan_checksum': plan_checksum,
            'discovery_artifact_checksum': discovery_artifact_checksum,
            'aws_semantic_contract_sha256': aws_semantic_contract_sha256,
        },
        'ready_write',
    )
    parent = os.path.dirname(ready_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    lines = [
        'READY',
        'selective_plan_checksum=%s' % plan_checksum,
        'plan_checksum=%s' % plan_checksum,
        'discovery_artifact_checksum=%s' % discovery_artifact_checksum,
        'aws_semantic_contract_sha256=%s' % aws_semantic_contract_sha256,
        'validation_phase=generation_bound',
    ]
    if extra_lines:
        lines.extend(list(extra_lines))
    tmp = ready_path + '.tmp.%d' % os.getpid()
    with open(tmp, 'w') as fh:
        fh.write('\n'.join(lines) + '\n')
    os.replace(tmp, ready_path)
    # Read-back verify
    got = generation_tuple_from_ready(_read_ready_kv_fields(ready_path))
    compare_generation_tuples(
        got,
        {
            'plan_checksum': plan_checksum,
            'discovery_artifact_checksum': discovery_artifact_checksum,
            'aws_semantic_contract_sha256': aws_semantic_contract_sha256,
        },
    )
    return ready_path


def _atomic_copy_file(src, dest):
    """Copy src→dest atomically with SHA256 read-back. Fail closed."""
    if not src or not os.path.isfile(src):
        raise ValueError('atomic_copy_missing_src:%s' % src)
    parent = os.path.dirname(dest)
    if parent:
        try:
            os.makedirs(parent, exist_ok=True)
        except OSError as exc:
            raise ValueError('atomic_copy_mkdir_fail:%s (%s)' % (parent, exc))
    h = hashlib.sha256()
    with open(src, 'rb') as fh:
        data = fh.read()
    h.update(data)
    src_sha = h.hexdigest()
    tmp = dest + '.tmp.%d' % os.getpid()
    try:
        with open(tmp, 'wb') as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, dest)
    except OSError as exc:
        try:
            if os.path.isfile(tmp):
                os.unlink(tmp)
        except OSError:
            pass
        raise ValueError('atomic_copy_write_fail:%s (%s)' % (dest, exc))
    # Read-back
    rh = hashlib.sha256()
    with open(dest, 'rb') as fh:
        rh.update(fh.read())
    if rh.hexdigest() != src_sha:
        raise ValueError(
            'atomic_copy_readback_mismatch:%s expected=%s got=%s'
            % (dest, src_sha[:16], rh.hexdigest()[:16])
        )
    return src_sha


def invalidate_selective_ready(selective_root):
    """Remove READY so consumers cannot bind an older generation. Fail closed."""
    ready = os.path.join(os.path.abspath(selective_root), 'state', 'READY')
    if not os.path.lexists(ready):
        return False
    try:
        os.unlink(ready)
    except OSError as exc:
        raise ValueError('selective_ready_invalidate_fail:%s (%s)' % (ready, exc))
    if os.path.lexists(ready):
        raise ValueError('selective_ready_invalidate_incomplete:%s' % ready)
    return True


def publish_selective_generation_state(
    selective_root,
    plan_src,
    contract_bash_src=None,
    invalidate_ready=True,
):
    """Atomically publish plan.json + AWS contract bash into selective state.

    Lifecycle (fail closed):
      1. invalidate READY (optional, default on)
      2. mkdir state
      3. atomic plan.json publish + read-back
      4. atomic contract bash publish + read-back (required when plan has contract)
      5. verify plan generation tuple + contract body SHA

    Does NOT write READY — that happens only after successful post-publish verify.
    Raises ValueError on any failure; never reports success with stale state.
    Returns verified generation tuple OrderedDict.
    """
    selective_root = os.path.abspath(selective_root or '')
    plan_src = os.path.abspath(plan_src or '')
    if not os.path.isfile(plan_src):
        raise ValueError('selective_generation_plan_src_missing:%s' % plan_src)
    state = os.path.join(selective_root, 'state')
    try:
        os.makedirs(state, exist_ok=True)
    except OSError as exc:
        raise ValueError('selective_generation_state_mkdir_fail:%s (%s)' % (state, exc))

    if invalidate_ready:
        invalidate_selective_ready(selective_root)

    plan_dest = os.path.join(state, 'plan.json')
    try:
        _atomic_copy_file(plan_src, plan_dest)
    except ValueError as exc:
        raise ValueError('selective_generation_plan_state_fail:%s' % exc)

    try:
        with open(plan_dest, 'r') as fh:
            plan = json.load(fh)
    except (OSError, ValueError, TypeError) as exc:
        raise ValueError('selective_generation_plan_unreadable:%s' % exc)

    if (plan.get('validation_result') or '') != 'PASS':
        raise ValueError(
            'selective_generation_plan_not_pass:%s'
            % (plan.get('validation_result') or 'missing')
        )

    plan_tuple = _require_generation_tuple(generation_tuple_from_plan(plan), 'plan')
    contract, contract_sha = load_aws_semantic_contract_from_plan(plan)
    if contract_sha != plan_tuple['aws_semantic_contract_sha256']:
        raise ValueError(
            'selective_generation_contract_sha_mismatch plan=%s body=%s'
            % (plan_tuple['aws_semantic_contract_sha256'][:16], contract_sha[:16])
        )

    if not contract_bash_src:
        sibling_src = os.path.join(os.path.dirname(plan_src), 'aws-semantic-contract.sh.inc')
        if os.path.isfile(sibling_src):
            contract_bash_src = sibling_src
    rendered = render_aws_semantic_contract_bash(contract)
    if not rendered.endswith('\n'):
        rendered += '\n'
    bash_dest = os.path.join(state, 'aws-semantic-contract.sh.inc')
    if contract_bash_src and os.path.isfile(contract_bash_src):
        try:
            _atomic_copy_file(contract_bash_src, bash_dest)
        except ValueError as exc:
            raise ValueError('selective_generation_contract_state_fail:%s' % exc)
        with open(bash_dest, 'r') as fh:
            existing = fh.read()
        if not existing.endswith('\n'):
            existing += '\n'
        if existing != rendered:
            raise ValueError(
                'selective_generation_contract_bash_mismatch: copied bash != plan render'
            )
    else:
        # Plan carries a contract: materialize rendered bash atomically.
        tmp = bash_dest + '.tmp.%d' % os.getpid()
        try:
            with open(tmp, 'w') as fh:
                fh.write(rendered)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, bash_dest)
        except OSError as exc:
            try:
                if os.path.isfile(tmp):
                    os.unlink(tmp)
            except OSError:
                pass
            raise ValueError(
                'selective_generation_contract_state_fail:%s' % exc
            )
        with open(bash_dest, 'r') as fh:
            existing = fh.read()
        if not existing.endswith('\n'):
            existing += '\n'
        if existing != rendered:
            raise ValueError(
                'selective_generation_contract_bash_readback_mismatch'
            )

    return OrderedDict([
        ('plan_checksum', plan_tuple['plan_checksum']),
        ('discovery_artifact_checksum', plan_tuple['discovery_artifact_checksum']),
        ('aws_semantic_contract_sha256', contract_sha),
        ('plan', plan),
        ('contract', contract),
        ('bash', rendered),
        ('plan_path', plan_dest),
        ('contract_bash_path', bash_dest),
    ])


def load_verified_selective_generation(selective_root, project_root=None):
    """Load READY + state/plan.json and verify they form one selective generation.

    Checks (all required; fail closed):
      - READY exists with plan/discovery/contract SHA256 fields
      - state/plan.json exists with validation_result == PASS
      - READY tuple == plan tuple (all three fields)
      - plan contract body verifies and matches plan/READY contract SHA
      - optional state bash matches plan-rendered contract

    Returns OrderedDict with plan, contract, bash, and generation checksums.
    Hermetic dual-escape only when BOTH READY and plan are absent.
    """
    selective_root = os.path.abspath(selective_root or '')
    state = os.path.join(selective_root, 'state')
    ready_path = os.path.join(state, 'READY')
    plan_path = os.path.join(state, 'plan.json')

    ready_exists = os.path.isfile(ready_path)
    plan_exists = os.path.isfile(plan_path)

    if not ready_exists and not plan_exists:
        if allow_generic_only_discovery() and project_root:
            fixture = os.path.join(
                os.path.abspath(project_root),
                'client',
                'dp-aws-semantic-contract.sh.inc',
            )
            if not os.path.isfile(fixture):
                raise ValueError(
                    'aws_semantic_contract_absent: no plan/READY and no hermetic fixture'
                )
            with open(fixture, 'r') as fh:
                text = fh.read()
            if not text.endswith('\n'):
                text += '\n'
            contract_sha = hashlib.sha256(text.encode('utf-8')).hexdigest()
            return OrderedDict([
                ('plan_checksum', ''),
                ('discovery_artifact_checksum', ''),
                ('aws_semantic_contract_sha256', contract_sha),
                ('plan', None),
                ('contract', None),
                ('bash', text),
                ('ready_fields', {}),
                ('hermetic_fixture', True),
            ])
        raise ValueError(
            'selective_generation_absent: missing READY and plan under %s' % state
        )

    if not ready_exists:
        raise ValueError('selective_generation_ready_absent: %s' % ready_path)
    if not plan_exists:
        raise ValueError('selective_generation_plan_absent: %s' % plan_path)

    ready_fields = _read_ready_kv_fields(ready_path)
    ready_tuple = generation_tuple_from_ready(ready_fields)

    try:
        with open(plan_path, 'r') as fh:
            plan = json.load(fh)
    except (OSError, ValueError, TypeError) as exc:
        raise ValueError('selective_generation_plan_unreadable:%s' % exc)

    if (plan.get('validation_result') or '') != 'PASS':
        raise ValueError(
            'selective_generation_plan_not_pass:%s'
            % (plan.get('validation_result') or 'missing')
        )

    plan_tuple = generation_tuple_from_plan(plan)
    compare_generation_tuples(ready_tuple, plan_tuple)

    contract, contract_sha = load_aws_semantic_contract_from_plan(plan)
    if contract_sha != plan_tuple['aws_semantic_contract_sha256']:
        raise ValueError(
            'selective_generation_contract_body_mismatch plan=%s body=%s'
            % (plan_tuple['aws_semantic_contract_sha256'][:16], contract_sha[:16])
        )
    if contract_sha != ready_tuple['aws_semantic_contract_sha256']:
        raise ValueError(
            'selective_generation_contract_ready_mismatch ready=%s body=%s'
            % (ready_tuple['aws_semantic_contract_sha256'][:16], contract_sha[:16])
        )

    bash = render_aws_semantic_contract_bash(contract)
    if not bash.endswith('\n'):
        bash += '\n'
    sibling = os.path.join(state, 'aws-semantic-contract.sh.inc')
    if os.path.isfile(sibling):
        with open(sibling, 'r') as fh:
            existing = fh.read()
        if not existing.endswith('\n'):
            existing += '\n'
        if existing != bash:
            raise ValueError(
                'aws_semantic_contract_differs_from_plan: state bash != plan contract'
            )

    return OrderedDict([
        ('plan_checksum', plan_tuple['plan_checksum']),
        ('discovery_artifact_checksum', plan_tuple['discovery_artifact_checksum']),
        ('aws_semantic_contract_sha256', contract_sha),
        ('plan', plan),
        ('contract', contract),
        ('bash', bash),
        ('ready_fields', ready_fields),
        ('hermetic_fixture', False),
        ('ready_path', ready_path),
        ('plan_path', plan_path),
    ])


def resolve_aws_semantic_contract_bash_for_client(selective_root, project_root=None):
    """Resolve authoritative AWS contract bash for client generation.

    Production authority is the verified READY↔state/plan.json generation tuple.
    The tracked ``client/dp-aws-semantic-contract.sh.inc`` is never an independent
    production authority; it may be used only under the hermetic dual escape when
    no verified plan/READY generation is available.

    Returns (bash_text, contract_sha256, contract_dict).
    """
    gen = load_verified_selective_generation(
        selective_root, project_root=project_root,
    )
    return gen['bash'], gen['aws_semantic_contract_sha256'], gen.get('contract')


def write_aws_semantic_contract_json(path, contract):
    """Write public contract JSON atomically; returns path."""
    public = minimal_public_aws_semantic_contract(contract)
    parent = os.path.dirname(path)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    tmp = path + '.tmp.%d' % os.getpid()
    with open(tmp, 'w') as fh:
        json.dump(public, fh, indent=2, sort_keys=True)
        fh.write('\n')
    os.replace(tmp, path)
    return path


def allow_generic_only_discovery():
    """True only when BOTH hermetic test mode and explicit escape are set.

    Production with only UM_ALLOW_GENERIC_ONLY_DISCOVERY=1 must NOT bypass.
    """
    return _env_truthy(HERMETIC_TEST_ENV) and _env_truthy(ALLOW_GENERIC_ONLY_ENV)


def allow_name_only_aws_validation():
    """True only for hermetic fixtures that explicitly opt into name-only AWS checks.

    Production OS Core build/verify must never take this path.
    Requires MM_HERMETIC_TEST_MODE=1 and UM_ALLOW_NAME_ONLY_AWS_VALIDATION=1.
    """
    return _env_truthy(HERMETIC_TEST_ENV) and _env_truthy(ALLOW_NAME_ONLY_AWS_ENV)


def require_production_discovery_profiles(profiles):
    """Return (ok, error_message) for standalone production planner CLI.

    Requires both generic and aws unless the hermetic dual escape is set.
    """
    profiles = list(profiles or [])
    if allow_generic_only_discovery():
        return True, ''
    has_generic = 'generic' in profiles
    has_aws = 'aws' in profiles
    if has_generic and has_aws:
        return True, ''
    return False, (
        'production selective plan requires discovery profiles '
        'generic=<path> and aws=<path> (got: %s); hermetic escape needs '
        'BOTH %s=1 and %s=1'
        % (','.join(profiles) or 'none', HERMETIC_TEST_ENV, ALLOW_GENERIC_ONLY_ENV)
    )


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


def decode_pkg_version(version):
    """Decode URL-encoded discovery versions (%2b, %7e, …)."""
    return unquote(version or '').strip()


def decode_filename(filename):
    return unquote(filename or '').strip()


def linux_aws_meta_to_kernel_release(version):
    """Map linux-aws / linux-image-aws version → uname -r style release.

    Examples:
      5.4.0.1103.81 → 5.4.0-1103-aws
      5.15.0.1084.91~20.04.1 → 5.15.0-1084-aws
      6.8.0-1063.66~22.04.1 → 6.8.0-1063-aws
      7.0.0-1011.11~24.04.1 → 7.0.0-1011-aws
    """
    v = decode_pkg_version(version)
    if ':' in v:
        v = v.split(':', 1)[1]
    m = re.match(r'^(\d+\.\d+\.\d+)-(\d+)\.', v)
    if m:
        return '%s-%s-aws' % (m.group(1), m.group(2))
    m = re.match(r'^(\d+\.\d+\.\d+)\.(\d+)\.', v)
    if m:
        return '%s-%s-aws' % (m.group(1), m.group(2))
    return ''


def versions_equal(a, b):
    return decode_pkg_version(a) == decode_pkg_version(b)


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
    """True iff BOTH linux-aws and linux-image-aws are present (name-level)."""
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


def _row_profile_blob(row):
    return '%s %s' % (row.get('profile') or '', row.get('provenance') or '')


def _row_prefers_aws_profile(row):
    blob = _row_profile_blob(row).lower()
    return 'aws' in blob.split() or 'profile=aws' in blob or ',aws' in blob or blob.startswith('aws')


def _row_sort_key(row):
    """Lower is better when selecting the authoritative discovery identity."""
    evidence = (row.get('evidence_source') or '').strip()
    installed = str(row.get('installed') or '').strip().lower()
    ver = row.get('version') or ''
    decoded = decode_pkg_version(ver)
    # Prefer apt_archives (installed target), then proxy, then others.
    ev_rank = 0 if evidence == 'apt_archives' else (1 if evidence == 'proxy_access_log' else 2)
    inst_rank = 0 if installed in ('true', '1', 'yes') else 1
    # Prefer already-decoded versions (contain +/~ rather than %2b/%7e).
    enc_rank = 0 if ver == decoded else 1
    sha = (row.get('sha256') or '').strip()
    return (ev_rank, inst_rank, enc_rank, 0 if sha else 1, decoded, sha)


def _pick_best_row(rows):
    if not rows:
        return None
    return sorted(rows, key=_row_sort_key)[0]


def _identity_from_row(row):
    if not row:
        return None
    ver = decode_pkg_version(row.get('version') or '')
    arch = (row.get('architecture') or row.get('arch') or '').strip()
    sha = (row.get('sha256') or '').strip()
    fn = decode_filename(row.get('filename') or row.get('relative_pool_path') or '')
    size_raw = row.get('size_bytes')
    try:
        size_bytes = int(size_raw) if size_raw not in (None, '') else None
    except (TypeError, ValueError):
        size_bytes = None
    return OrderedDict([
        ('package', _package_name(row)),
        ('version', ver),
        ('architecture', arch or 'amd64'),
        ('sha256', sha),
        ('filename', os.path.basename(fn) if fn else ''),
        ('size_bytes', size_bytes),
    ])


def _rows_for_hop_package(rows, hop, package):
    out = []
    for row in rows or []:
        if hop not in _row_hops(row) and row.get('hop') != hop:
            continue
        if _package_name(row) != package:
            continue
        out.append(row)
    return out


def _filter_aws_profile_rows(rows):
    aws_rows = [r for r in rows or [] if _row_prefers_aws_profile(r)]
    return aws_rows if aws_rows else list(rows or [])


def expected_deb_basenames(identity):
    """Possible pool basenames for a contract identity (encoding variants)."""
    if not identity:
        return []
    pkg = identity.get('package') or ''
    ver = identity.get('version') or ''
    arch = identity.get('architecture') or 'amd64'
    if not pkg or not ver:
        return []
    variants = [ver]
    # Common URL encodings seen in discovery filenames.
    enc = ver.replace('+', '%2b').replace('~', '%7e')
    if enc not in variants:
        variants.append(enc)
    enc2 = ver.replace('+', '%2B').replace('~', '%7E')
    if enc2 not in variants:
        variants.append(enc2)
    return ['%s_%s_%s.deb' % (pkg, v, arch) for v in variants]


def deb_basename_matches_identity(filename, identity):
    base = os.path.basename(filename or '')
    if not base:
        return False
    decoded = decode_filename(base)
    for cand in expected_deb_basenames(identity):
        if base == cand or decoded == cand or decoded == decode_filename(cand):
            return True
    # Fallback: parse name_version_arch.deb
    pkg = identity.get('package') or ''
    ver = identity.get('version') or ''
    arch = identity.get('architecture') or 'amd64'
    if not (pkg and ver and decoded.startswith(pkg + '_') and decoded.endswith('_' + arch + '.deb')):
        return False
    mid = decoded[len(pkg) + 1:-(len(arch) + 5)]
    return versions_equal(mid, ver)


def build_hop_aws_semantic_contract(hop, package_rows):
    """Build discovery-derived target AWS contract for one hop.

    Returns (contract OrderedDict or None, errors list).
    """
    errors = []
    hop_rows = []
    for row in package_rows or []:
        if hop in _row_hops(row) or row.get('hop') == hop:
            hop_rows.append(row)
    hop_rows = _filter_aws_profile_rows(hop_rows)

    contract = OrderedDict([
        ('hop', hop),
        ('source_series', hop.split('-to-')[0] if '-to-' in hop else ''),
        ('target_series', hop.split('-to-')[1] if '-to-' in hop else ''),
        ('source_version_id', HOP_SOURCE_VERSION_ID.get(hop, '')),
        ('target_version_id', HOP_TARGET_VERSION_ID.get(hop, '')),
    ])

    metas = OrderedDict()
    for name in REQUIRED_AWS_METAPACKAGES:
        candidates = _rows_for_hop_package(hop_rows, hop, name)
        # Dedup by sha256 keeping preferred row.
        by_sha = OrderedDict()
        for row in sorted(candidates, key=_row_sort_key):
            sha = (row.get('sha256') or '').strip() or 'nover:%s' % decode_pkg_version(
                row.get('version') or ''
            )
            by_sha.setdefault(sha, row)
        if not by_sha:
            errors.append('aws_contract_missing:%s:%s' % (hop, name))
            continue
        if len(by_sha) > 1:
            # Prefer the row whose version maps to a present versioned image.
            chosen = None
            for row in by_sha.values():
                rel = linux_aws_meta_to_kernel_release(row.get('version') or '')
                img = 'linux-image-%s' % rel if rel else ''
                if img and _rows_for_hop_package(hop_rows, hop, img):
                    chosen = row
                    break
            pick = chosen or _pick_best_row(list(by_sha.values()))
        else:
            pick = next(iter(by_sha.values()))
        ident = _identity_from_row(pick)
        if not ident.get('sha256'):
            errors.append('aws_contract_missing_sha256:%s:%s' % (hop, name))
        metas[name] = ident
        key = 'linux_aws' if name == 'linux-aws' else 'linux_image_aws'
        contract[key] = ident

    kernel_releases = []
    versioned_images = []
    boot_packages = []
    if 'linux-aws' in metas:
        rel = linux_aws_meta_to_kernel_release(metas['linux-aws'].get('version'))
        if not rel:
            errors.append(
                'aws_contract_unmapped_kernel_release:%s:version=%s'
                % (hop, metas['linux-aws'].get('version'))
            )
        else:
            kernel_releases.append(rel)
            img_name = 'linux-image-%s' % rel
            img_rows = _rows_for_hop_package(hop_rows, hop, img_name)
            img_pick = _pick_best_row(img_rows)
            if not img_pick:
                errors.append('aws_contract_missing:%s:%s' % (hop, img_name))
            else:
                img_ident = _identity_from_row(img_pick)
                versioned_images.append(img_ident)
                if not img_ident.get('sha256'):
                    errors.append('aws_contract_missing_sha256:%s:%s' % (hop, img_name))

            for boot_name in (
                'linux-modules-%s' % rel,
                'linux-modules-extra-%s' % rel,
            ):
                boot_rows = _rows_for_hop_package(hop_rows, hop, boot_name)
                boot_pick = _pick_best_row(boot_rows)
                if boot_pick:
                    boot_packages.append(_identity_from_row(boot_pick))

    contract['expected_kernel_releases'] = kernel_releases
    contract['versioned_images'] = versioned_images
    contract['boot_packages'] = boot_packages

    if hop in SNAPD_REQUIRED_HOPS:
        snap_rows = _rows_for_hop_package(hop_rows, hop, 'snapd')
        snap_pick = _pick_best_row(snap_rows)
        if not snap_pick:
            errors.append('aws_contract_missing:%s:snapd' % hop)
            contract['snapd'] = None
        else:
            snap_ident = _identity_from_row(snap_pick)
            contract['snapd'] = snap_ident
            if not snap_ident.get('sha256'):
                errors.append('aws_contract_missing_sha256:%s:snapd' % hop)
    else:
        contract['snapd'] = None

    if errors:
        return None, errors
    return contract, []


def build_aws_semantic_contract(package_rows, discovery_profiles=None):
    """Build full multi-hop AWS semantic contract from discovery/plan rows."""
    errors = []
    hops = OrderedDict()
    for hop in HOPS:
        hop_contract, hop_errs = build_hop_aws_semantic_contract(hop, package_rows)
        if hop_errs:
            errors.extend(hop_errs)
        if hop_contract:
            hops[hop] = hop_contract
    contract = OrderedDict([
        ('schema_version', CONTRACT_SCHEMA_VERSION),
        ('discovery_profiles', list(discovery_profiles or [])),
        ('required_metapackages', list(REQUIRED_AWS_METAPACKAGES)),
        ('hops', hops),
        ('by_target_version_id', OrderedDict(
            (HOP_TARGET_VERSION_ID[h], h) for h in HOPS if h in hops
        )),
    ])
    if hops and not errors:
        attach_contract_sha256(contract)
    return contract, errors


def iter_contract_identities(hop_contract):
    """Yield all required identities for a hop contract."""
    if not hop_contract:
        return
    for key in ('linux_aws', 'linux_image_aws', 'snapd'):
        ident = hop_contract.get(key)
        if ident:
            yield ident
    for ident in hop_contract.get('versioned_images') or []:
        if ident:
            yield ident
    for ident in hop_contract.get('boot_packages') or []:
        if ident:
            yield ident


def _index_rows_by_sha_and_name(rows, hop=None):
    """Index rows by sha256 and name/version/arch.

    When ``hop`` is set, only rows that list that hop in source_hops/hop are
    indexed — preventing a package present only in hop B from satisfying hop A.
    """
    by_sha = {}
    by_nv = {}
    for row in rows or []:
        if hop is not None:
            if hop not in _row_hops(row) and row.get('hop') != hop:
                continue
        sha = (row.get('sha256') or '').strip()
        name = _package_name(row)
        ver = decode_pkg_version(row.get('version') or '')
        arch = (row.get('architecture') or '').strip()
        if sha:
            by_sha.setdefault(sha, []).append(row)
        if name and ver:
            by_nv.setdefault((name, ver, arch or 'amd64'), []).append(row)
            by_nv.setdefault((name, ver, ''), []).append(row)
    return by_sha, by_nv


def validate_rows_match_aws_contract(contract, package_rows, hops=None):
    """Ensure package rows include every contract identity (sha/version/arch).

    Matching is hop-scoped: an identity required for hop A must appear in rows
    that belong to hop A (source_hops/hop), not merely elsewhere in the plan.
    """
    errors = []
    details = OrderedDict([('hops', OrderedDict())])
    if not contract or not contract.get('hops'):
        return False, ['aws_semantic_contract_missing'], details
    for hop in (hops or list(contract.get('hops') or {})):
        hop_c = (contract.get('hops') or {}).get(hop)
        hop_detail = OrderedDict([('identities', [])])
        if not hop_c:
            errors.append('aws_contract_hop_missing:%s' % hop)
            details['hops'][hop] = hop_detail
            continue
        by_sha, by_nv = _index_rows_by_sha_and_name(package_rows, hop=hop)
        for ident in iter_contract_identities(hop_c):
            pkg = ident.get('package')
            ver = ident.get('version')
            arch = ident.get('architecture') or 'amd64'
            sha = ident.get('sha256') or ''
            matched = False
            match_how = ''
            if sha and sha in by_sha:
                matched = True
                match_how = 'sha256'
            elif (pkg, ver, arch) in by_nv or (pkg, ver, '') in by_nv:
                matched = True
                match_how = 'name_version_arch'
            hop_detail['identities'].append(OrderedDict([
                ('package', pkg),
                ('version', ver),
                ('architecture', arch),
                ('sha256', sha),
                ('matched', matched),
                ('match_how', match_how),
            ]))
            if not matched:
                errors.append(
                    'aws_contract_identity_missing_in_plan:%s:%s:%s:%s'
                    % (hop, pkg, ver, sha[:12] if sha else 'nosha')
                )
        details['hops'][hop] = hop_detail
    details['result'] = 'PASS' if not errors else 'FAIL'
    return not errors, errors, details


def validate_plan_aws_completeness(plan, package_rows=None, require_aws_profile=None):
    """Validate selective plan semantic AWS coverage (exact identities).

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

    contract = plan.get('aws_semantic_contract')
    contract_errors = []
    if not contract or not (contract.get('hops') or {}):
        contract, contract_errors = build_aws_semantic_contract(
            combined, discovery_profiles=profiles,
        )
        details['contract_built'] = True
    else:
        details['contract_built'] = False
        ok_ck, actual_ck, ck_err = verify_contract_checksum(
            contract,
            expected_sha=(plan.get('aws_semantic_contract_sha256') or None),
        )
        details['contract_sha256'] = actual_ck
        if not ok_ck:
            errors.append(ck_err or 'aws_semantic_contract_checksum_mismatch')

    if contract_errors:
        errors.extend(contract_errors)

    details['aws_semantic_contract'] = OrderedDict([
        ('schema_version', (contract or {}).get('schema_version')),
        ('hop_count', len((contract or {}).get('hops') or {})),
        ('contract_sha256', (contract or {}).get('contract_sha256') or details.get('contract_sha256')),
    ])

    by_hop = collect_aws_packages_by_hop(combined)
    counts = plan.get('counts') or {}
    sample = plan.get('aws_kernel_packages_sample') or []
    if int(counts.get('aws_kernel_package_rows') or 0) <= 0 and not sample and not any(by_hop.values()):
        errors.append(
            'aws_kernel_packages_missing: plan claims/requires AWS coverage but '
            'aws_kernel_package_rows=0'
        )

    if contract and contract.get('hops'):
        ok_ids, id_errs, id_details = validate_rows_match_aws_contract(
            contract, combined,
        )
        details['identity_validation'] = id_details
        if not ok_ids:
            errors.extend(id_errs)
        for hop in HOPS:
            hop_c = (contract.get('hops') or {}).get(hop) or {}
            details['hops'][hop] = OrderedDict([
                ('has_contract', bool(hop_c)),
                ('linux_aws', (hop_c.get('linux_aws') or {}).get('version')),
                ('linux_image_aws', (hop_c.get('linux_image_aws') or {}).get('version')),
                ('expected_kernel_releases', list(hop_c.get('expected_kernel_releases') or [])),
                ('snapd', ((hop_c.get('snapd') or {}) or {}).get('version')),
            ])
    else:
        # Fallback name-level checks if contract could not be built.
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
                    'metapackages %s' % (hop, ','.join(missing_meta))
                )
            if hop in SNAPD_REQUIRED_HOPS:
                snap_ok = hop_has_snapd(combined, hop)
                details['hops'][hop]['snapd_present'] = snap_ok
                if not snap_ok:
                    errors.append(
                        'snapd_missing_hop: %s requires snapd when AWS coverage is '
                        'required' % hop
                    )

    details['result'] = 'PASS' if not errors else 'FAIL'
    return not errors, errors, details


def deb_basename_to_package(filename):
    """Map ``name_version_arch.deb`` (or URL-encoded) basename → package name."""
    base = os.path.basename(filename)
    if base.endswith('.deb'):
        base = base[:-4]
    base = unquote(base)
    if '_' not in base:
        return base
    return base.split('_', 1)[0]


def deb_basename_to_identity(filename):
    """Parse basename into package/version/arch when possible."""
    base = os.path.basename(filename or '')
    if base.endswith('.deb'):
        base = base[:-4]
    base = unquote(base)
    parts = base.split('_')
    if len(parts) < 3:
        return None
    arch = parts[-1]
    pkg = parts[0]
    ver = '_'.join(parts[1:-1])
    return OrderedDict([
        ('package', pkg),
        ('version', ver),
        ('architecture', arch),
        ('filename', os.path.basename(filename)),
    ])


def iter_pool_deb_basenames(ubuntu_or_hop_root):
    """Yield .deb basenames under a hop ubuntu root or payload hops tree."""
    if not ubuntu_or_hop_root or not os.path.isdir(ubuntu_or_hop_root):
        return
    for dirpath, _dns, filenames in os.walk(ubuntu_or_hop_root):
        for fn in filenames:
            if fn.endswith('.deb'):
                yield fn


def iter_pool_deb_paths(ubuntu_or_hop_root):
    if not ubuntu_or_hop_root or not os.path.isdir(ubuntu_or_hop_root):
        return
    for dirpath, _dns, filenames in os.walk(ubuntu_or_hop_root):
        for fn in filenames:
            if fn.endswith('.deb'):
                yield os.path.join(dirpath, fn)


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


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def hop_pool_aws_contract(ubuntu_root):
    """Physical hop presence summary (name-level; legacy helper)."""
    names = hop_pool_package_names(ubuntu_root)
    missing_meta = [m for m in REQUIRED_AWS_METAPACKAGES if m not in names]
    return OrderedDict([
        ('package_names_sample', sorted(names)[:40]),
        ('has_required_aws_metapackages', not missing_meta),
        ('missing_aws_metapackages', missing_meta),
        ('has_snapd', 'snapd' in names),
        ('has_any_aws_family', hop_pool_has_aws_debs(ubuntu_root)),
    ])


def _find_identity_in_pool(ubuntu_root, identity, verify_sha256=False):
    """Return (found, detail) for one identity under a hop pool."""
    detail = OrderedDict([
        ('package', (identity or {}).get('package')),
        ('version', (identity or {}).get('version')),
        ('architecture', (identity or {}).get('architecture')),
        ('sha256', (identity or {}).get('sha256')),
        ('found', False),
        ('path', ''),
        ('sha_ok', None),
    ])
    if not identity:
        return False, detail
    expected_sha = (identity.get('sha256') or '').strip()
    for path in iter_pool_deb_paths(ubuntu_root) or []:
        base = os.path.basename(path)
        if not deb_basename_matches_identity(base, identity):
            continue
        detail['found'] = True
        detail['path'] = path
        if verify_sha256:
            if not expected_sha:
                detail['sha_ok'] = False
                return False, detail
            try:
                actual = file_sha256(path)
            except OSError:
                detail['sha_ok'] = False
                return False, detail
            detail['sha_ok'] = (actual == expected_sha)
            detail['actual_sha256'] = actual
            if actual != expected_sha:
                return False, detail
        return True, detail
    return False, detail


def validate_tree_aws_completeness(
    selective_or_payload_root,
    plan=None,
    require_aws_profile=None,
    verify_sha256=False,
):
    """Validate materialized selective/OS Core payload tree for AWS contract.

    When AWS coverage is required, each hop must contain exact discovery-derived
    identities (package/version/architecture, and sha256 when verify_sha256).
    Name-only presence is insufficient.
    """
    plan = plan or {}
    requires = plan_requires_aws_coverage(plan, require_aws_profile=require_aws_profile)
    errors = []
    details = OrderedDict([
        ('requires_aws_coverage', requires),
        ('root', selective_or_payload_root),
        ('required_aws_metapackages', list(REQUIRED_AWS_METAPACKAGES)),
        ('verify_sha256', verify_sha256),
        ('hops', OrderedDict()),
    ])
    if not requires:
        details['result'] = 'SKIP'
        return True, errors, details

    contract = plan.get('aws_semantic_contract')
    if not contract or not contract.get('hops'):
        # Attempt rebuild from plan debs (tests may plant contract directly).
        rows = list(plan.get('debs') or []) + list(plan.get('aws_kernel_packages_sample') or [])
        if rows:
            contract, build_errs = build_aws_semantic_contract(
                rows, discovery_profiles=plan.get('discovery_profiles') or [],
            )
            if build_errs and not (contract and contract.get('hops')):
                errors.extend(build_errs)

    if not contract or not contract.get('hops'):
        # Name-only path is hermetic-only. Production must fail closed.
        if not allow_name_only_aws_validation():
            errors.append(
                'aws_semantic_contract_missing: exact identity contract required '
                '(name-only fallback needs %s=1 and %s=1)'
                % (HERMETIC_TEST_ENV, ALLOW_NAME_ONLY_AWS_ENV)
            )
            details['mode'] = 'fail_closed_no_contract'
            details['result'] = 'FAIL'
            return False, errors, details
        for hop in HOPS:
            candidates = [
                os.path.join(selective_or_payload_root, 'hops', hop, 'ubuntu'),
                os.path.join(selective_or_payload_root, 'hops', hop),
                os.path.join(selective_or_payload_root, hop, 'ubuntu'),
                os.path.join(selective_or_payload_root, hop),
            ]
            ubuntu = next((c for c in candidates if os.path.isdir(c)), candidates[0])
            presence = hop_pool_aws_contract(ubuntu)
            details['hops'][hop] = OrderedDict([
                ('ubuntu_root', ubuntu),
                ('contract', presence),
                ('mode', 'name_only_fallback'),
            ])
            if not presence['has_required_aws_metapackages']:
                errors.append(
                    'aws_metapackage_deb_missing_in_tree: %s missing %s'
                    % (hop, ','.join(presence['missing_aws_metapackages']))
                )
            if hop in SNAPD_REQUIRED_HOPS and not presence['has_snapd']:
                errors.append(
                    'snapd_deb_missing_in_tree: %s requires physical snapd .deb'
                    % hop
                )
        details['result'] = 'PASS' if not errors else 'FAIL'
        return not errors, errors, details

    # When a contract is present, optionally enforce its checksum binding.
    expected_ck = (
        (plan.get('aws_semantic_contract_sha256') or '').strip()
        or (contract.get('contract_sha256') or '').strip()
    )
    if expected_ck or plan.get('require_contract_checksum'):
        ok_ck, actual_ck, ck_err = verify_contract_checksum(
            contract, expected_sha=expected_ck or None,
        )
        details['contract_sha256'] = actual_ck
        if not ok_ck:
            errors.append(ck_err or 'aws_semantic_contract_checksum_mismatch')
            details['result'] = 'FAIL'
            return False, errors, details

    for hop in HOPS:
        hop_c = (contract.get('hops') or {}).get(hop)
        candidates = [
            os.path.join(selective_or_payload_root, 'hops', hop, 'ubuntu'),
            os.path.join(selective_or_payload_root, 'hops', hop),
            os.path.join(selective_or_payload_root, hop, 'ubuntu'),
            os.path.join(selective_or_payload_root, hop),
        ]
        ubuntu = next((c for c in candidates if os.path.isdir(c)), candidates[0])
        hop_detail = OrderedDict([
            ('ubuntu_root', ubuntu),
            ('mode', 'exact_identity'),
            ('identities', []),
        ])
        if not hop_c:
            errors.append('aws_contract_hop_missing_in_tree_validation:%s' % hop)
            details['hops'][hop] = hop_detail
            continue

        # Required: metas + versioned images + snapd(x2b). Boot modules are
        # best-effort from discovery — require when present in contract.
        required = []
        for key in ('linux_aws', 'linux_image_aws'):
            if hop_c.get(key):
                required.append(hop_c[key])
        required.extend(hop_c.get('versioned_images') or [])
        if hop in SNAPD_REQUIRED_HOPS and hop_c.get('snapd'):
            required.append(hop_c['snapd'])
        required.extend(hop_c.get('boot_packages') or [])

        for ident in required:
            found, idet = _find_identity_in_pool(
                ubuntu, ident, verify_sha256=verify_sha256,
            )
            hop_detail['identities'].append(idet)
            pkg = ident.get('package')
            ver = ident.get('version')
            if not found:
                errors.append(
                    'aws_contract_deb_missing_in_tree: %s missing %s version=%s'
                    % (hop, pkg, ver)
                )
            elif verify_sha256 and idet.get('sha_ok') is False:
                errors.append(
                    'aws_contract_deb_sha256_mismatch_in_tree: %s %s expected=%s'
                    % (hop, pkg, (ident.get('sha256') or '')[:16])
                )
        details['hops'][hop] = hop_detail

    details['result'] = 'PASS' if not errors else 'FAIL'
    return not errors, errors, details


def assert_plan_aws_completeness(plan, package_rows=None, require_aws_profile=None):
    ok, errors, details = validate_plan_aws_completeness(
        plan, package_rows=package_rows, require_aws_profile=require_aws_profile,
    )
    if not ok:
        raise ValueError('; '.join(errors))
    return details


def render_aws_semantic_contract_bash(contract):
    """Render bash include defining aws_contract_load_for_version_id()."""
    contract_sha = ''
    if contract:
        contract_sha = (contract.get('contract_sha256') or '').strip()
        if not contract_sha and contract.get('hops'):
            contract_sha = aws_semantic_contract_sha256(contract)
    lines = [
        '# Generated AWS semantic contract (discovery-derived). Do not hand-edit.',
        '# shellcheck shell=bash',
        'AWS_SEMANTIC_CONTRACT_LOADED=1',
        'AWS_SEMANTIC_CONTRACT_SCHEMA=%s' % (
            (contract or {}).get('schema_version') or CONTRACT_SCHEMA_VERSION
        ),
        'AWS_SEMANTIC_CONTRACT_SHA256=%s' % _bash_quote(contract_sha),
        '',
        'aws_contract_clear() {',
        '  AWS_C_HOP=""',
        '  AWS_C_TARGET_VERSION_ID=""',
        '  AWS_C_LINUX_AWS_VERSION=""',
        '  AWS_C_LINUX_AWS_SHA256=""',
        '  AWS_C_LINUX_IMAGE_AWS_VERSION=""',
        '  AWS_C_LINUX_IMAGE_AWS_SHA256=""',
        '  AWS_C_KERNEL_RELEASES=""',
        '  AWS_C_VERSIONED_IMAGE_PACKAGES=""',
        '  AWS_C_BOOT_PACKAGES=""',
        '  AWS_C_BOOT_PACKAGE_VERSIONS=""',
        '  AWS_C_SNAPD_VERSION=""',
        '}',
        '',
        'aws_contract_load_for_version_id() {',
        '  local ver="${1:-}"',
        '  aws_contract_clear',
        '  case "$ver" in',
    ]
    hops = (contract or {}).get('hops') or {}
    for hop in HOPS:
        hop_c = hops.get(hop) or {}
        if not hop_c:
            continue
        tver = hop_c.get('target_version_id') or HOP_TARGET_VERSION_ID.get(hop, '')
        linux_aws = hop_c.get('linux_aws') or {}
        linux_img = hop_c.get('linux_image_aws') or {}
        releases = list(hop_c.get('expected_kernel_releases') or [])
        images = [
            (i.get('package') or '')
            for i in (hop_c.get('versioned_images') or [])
            if i and i.get('package')
        ]
        boot_names = []
        boot_pairs = []
        for bp in (hop_c.get('boot_packages') or []):
            if not bp:
                continue
            bname = (bp.get('package') or '').strip()
            bver = (bp.get('version') or '').strip()
            if not bname:
                continue
            boot_names.append(bname)
            if bver:
                boot_pairs.append('%s=%s' % (bname, bver))
        snap = hop_c.get('snapd') or {}
        lines.extend([
            '    %s)' % tver,
            '      AWS_C_HOP=%s' % _bash_quote(hop),
            '      AWS_C_TARGET_VERSION_ID=%s' % _bash_quote(tver),
            '      AWS_C_LINUX_AWS_VERSION=%s' % _bash_quote(linux_aws.get('version') or ''),
            '      AWS_C_LINUX_AWS_SHA256=%s' % _bash_quote(linux_aws.get('sha256') or ''),
            '      AWS_C_LINUX_IMAGE_AWS_VERSION=%s' % _bash_quote(
                linux_img.get('version') or ''
            ),
            '      AWS_C_LINUX_IMAGE_AWS_SHA256=%s' % _bash_quote(
                linux_img.get('sha256') or ''
            ),
            '      AWS_C_KERNEL_RELEASES=%s' % _bash_quote(' '.join(releases)),
            '      AWS_C_VERSIONED_IMAGE_PACKAGES=%s' % _bash_quote(' '.join(images)),
            '      AWS_C_BOOT_PACKAGES=%s' % _bash_quote(' '.join(boot_names)),
            '      AWS_C_BOOT_PACKAGE_VERSIONS=%s' % _bash_quote(' '.join(boot_pairs)),
            '      AWS_C_SNAPD_VERSION=%s' % _bash_quote(snap.get('version') or ''),
            '      ;;',
        ])
    lines.extend([
        '    *)',
        '      return 1',
        '      ;;',
        '  esac',
        '  if [[ -z "${AWS_C_LINUX_AWS_VERSION}" || -z "${AWS_C_LINUX_IMAGE_AWS_VERSION}" ]]; then',
        '    return 1',
        '  fi',
        '  if [[ -z "${AWS_C_KERNEL_RELEASES}" || -z "${AWS_C_VERSIONED_IMAGE_PACKAGES}" ]]; then',
        '    return 1',
        '  fi',
        '  return 0',
        '}',
        '',
    ])
    return '\n'.join(lines)


def _bash_quote(value):
    s = '' if value is None else str(value)
    return "'" + s.replace("'", "'\"'\"'") + "'"


def write_aws_semantic_contract_bash(path, contract):
    text = render_aws_semantic_contract_bash(contract)
    parent = os.path.dirname(path)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    tmp = path + '.tmp.%d' % os.getpid()
    with open(tmp, 'w') as fh:
        fh.write(text)
        if not text.endswith('\n'):
            fh.write('\n')
    os.replace(tmp, path)
    return path
