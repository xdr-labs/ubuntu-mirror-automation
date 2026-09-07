#!/usr/bin/env python3
"""Deterministic Phase 2 bringup patch generator.

Production authority:

    FINAL_BRINGUP = current ACPS upstream + this project patch layer

The ACPS bringup file is vendor-owned and immutable. This module never
rewrites the saved upstream copy. It never falls back to
vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh (that file is a
reference / golden output for a known generation, not a production
replacement for a freshly downloaded ACPS script).

Every transformation requires its expected source anchor to occur exactly
once. Zero matches or more than one match is BRINGUP_PATCH_COMPAT=FAIL.
Fuzzy patch application is impossible: there is no patch(1), no git apply,
and no unanchored sed.

Field operators never edit bringup_py3_dp_after_os_upgrade.sh by hand.
If automatic patching is not provably safe, Download and Prepare fails
closed before any DP upgrade.
"""
from __future__ import print_function, unicode_literals

import argparse
import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FRAGMENT_DIR = os.path.join(HERE, 'phase2_bringup_patch')
PATCH_SCHEMA_VERSION = '1'

RESULT_MARKERS = (
    '--worker-password',
    '--worker-password-file',
    'ACPS_DIRECT_DOWNLOAD=FAIL',
    'init_phase2_ssh_known_hosts',
    'StrictHostKeyChecking=accept-new',
    'PHASE2_WORKER_PASSWORD_FILE',
    'require_worker_password_file_for_remote_orchestration',
    'sshpass -f',
    'wait_for_master_token_api',
    'validate_expected_cluster_nodes',
    'validate_apt_dependency_graph',
    'validate_critical_python_runtime',
    'validate_remote_role_identity',
    'REMOTE_ROLE_IDENTITY',
    'validate_local_remote_join_state',
    'REMOTE_JOIN_LOCAL_STATE',
    'MASTER_TOKEN_API_READY',
    'CLUSTER_JOIN_STATE',
    'APT_DEPENDENCY_CHECK',
    'CRITICAL_PYTHON_RUNTIME',
    '# BEGIN_IMAGE_IMPORT_HEARTBEAT',
    'run_image_import_with_heartbeat',
    'emit_dp_resume_notice_line',
    'WORKER_RESULT',
    'WORKER_ORCHESTRATION',
    'copy_phase2_prereq_contract_to_worker',
    'normalize_remote_orchestration_nodes',
    'has_remote_orchestration_nodes',
    '--worker-ips/--standby requires --worker-password-file',
)


class PatchCompatError(Exception):
    def __init__(self, transform, reason):
        Exception.__init__(self, '%s: %s' % (transform, reason))
        self.transform = transform
        self.reason = reason


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def _read(path):
    with open(path, 'rb') as fh:
        return fh.read()


def _read_text(path):
    return _read(path).decode('utf-8')


def _sha1_bytes(data):
    return hashlib.sha1(data).hexdigest()


def _sha1_text(text):
    if not isinstance(text, bytes):
        text = text.encode('utf-8')
    return _sha1_bytes(text)


def _fragment(name):
    path = os.path.join(FRAGMENT_DIR, name)
    if not os.path.isfile(path):
        raise PatchCompatError('fragment_%s' % name, 'missing_fragment path=%s' % path)
    return _read_text(path)


def patch_generation_files():
    """Return sorted (relative_name, bytes) pairs that identify this patcher."""
    files = [('PATCH_SCHEMA_VERSION', PATCH_SCHEMA_VERSION.encode('utf-8'))]
    files.append((os.path.basename(__file__), _read(__file__)))
    names = sorted(
        n for n in os.listdir(FRAGMENT_DIR)
        if n.endswith('.sh') or n == 'README.md'
    )
    for name in names:
        files.append((os.path.join('phase2_bringup_patch', name),
                      _read(os.path.join(FRAGMENT_DIR, name))))
    return files


def patch_generation_id():
    """Stable identity of the project patch layer (not the vendor full copy)."""
    h = hashlib.sha1()
    h.update(('schema=%s\n' % PATCH_SCHEMA_VERSION).encode('utf-8'))
    for name, data in patch_generation_files():
        h.update(('file=%s\n' % name).encode('utf-8'))
        h.update(('len=%d\n' % len(data)).encode('utf-8'))
        h.update(data)
        h.update(b'\n')
    return h.hexdigest()


def _count(text, needle):
    if not needle:
        return 0
    return text.count(needle)


def _require_count(text, needle, expected, transform):
    got = _count(text, needle)
    if got != expected:
        raise PatchCompatError(
            transform,
            'anchor_count=%d expected=%d' % (got, expected),
        )
    return got


def _require_absent(text, needle, transform):
    _require_count(text, needle, 0, transform)


def replace_exactly_once(text, old, new, transform):
    _require_count(text, old, 1, transform)
    return text.replace(old, new, 1)


def replace_exactly_one_of(text, alternatives, new, transform):
    found = []
    for old in alternatives:
        c = _count(text, old)
        if c:
            found.append((old, c))
    if not found:
        raise PatchCompatError(transform, 'anchor_count=0 expected=1')
    if len(found) != 1:
        raise PatchCompatError(
            transform,
            'multiple_alternative_anchors count=%d' % len(found),
        )
    old, c = found[0]
    if c != 1:
        raise PatchCompatError(
            transform,
            'anchor_count=%d expected=1' % c,
        )
    return text.replace(old, new, 1)


def replace_exactly_one_mapping(text, pairs, transform):
    """Replace exactly one known (old, new) pair. Fail closed otherwise.

    Used when the same semantic site exists in more than one supported
    upstream form and the replacement text must preserve that form's
    vendor-side surrounding code. Zero matches, more than one matching
    alternative, or a duplicate occurrence of the chosen alternative is
    BRINGUP_PATCH_COMPAT=FAIL.
    """
    found = []
    for old, new in pairs:
        c = _count(text, old)
        if c:
            found.append((old, new, c))
    if not found:
        raise PatchCompatError(transform, 'anchor_count=0 expected=1')
    if len(found) != 1:
        raise PatchCompatError(
            transform,
            'multiple_alternative_anchors count=%d' % len(found),
        )
    old, new, c = found[0]
    if c != 1:
        raise PatchCompatError(
            transform,
            'anchor_count=%d expected=1' % c,
        )
    return text.replace(old, new, 1)


def insert_before(text, anchor, payload, transform):
    _require_count(text, anchor, 1, transform)
    return text.replace(anchor, payload + anchor, 1)


def insert_after(text, anchor, payload, transform):
    _require_count(text, anchor, 1, transform)
    return text.replace(anchor, anchor + payload, 1)


def _compat_fragment():
    body = _fragment('fragment_compat.sh')
    if not body.endswith('\n'):
        body += '\n'
    return body


def _credential_ssh_fragment():
    body = _fragment('fragment_credential_ssh.sh')
    if not body.endswith('\n'):
        body += '\n'
    return body + '\n'


def _heartbeat_fragment():
    body = _fragment('fragment_heartbeat.sh')
    if not body.endswith('\n'):
        body += '\n'
    return body + '\n'


def _resume_fragment():
    body = _fragment('fragment_resume.sh')
    if not body.endswith('\n'):
        body += '\n'
    return body + '\n'


def apply_worker_password_docs(text):
    text = replace_exactly_once(
        text,
        '#       --worker-ips 10.0.0.2,10.0.0.3 --worker-key /path/to/worker-ssh-key',
        "#       --worker-ips 10.0.0.2,10.0.0.3 --worker-password '<aella-password>'",
        'usage_example_worker_password',
    )
    text = replace_exactly_once(
        text,
        '#            --worker-ips <w1>,<w2> --worker-key /path/to/key',
        "#            --worker-ips <w1>,<w2> --worker-password '<aella-password>'",
        'workflow_example_worker_password',
    )
    text = replace_exactly_once(
        text,
        '#   --worker-key <path>       (deprecated) Workers use sshpass (aella/aelladata)',
        '#   --worker-password <pass>  SSH password for aella on remote nodes (required with --worker-ips/--standby)\n'
        '#   --worker-key <path>       (deprecated) Use --worker-password instead',
        'args_doc_worker_password',
    )
    text = replace_exactly_once(
        text,
        '#   --worker-key <path>       (deprecated) Use --worker-password instead',
        '#   --worker-password-file <path>  Mode-0600 file with SSH password (production path)\n'
        '#   --worker-password <pass>  Legacy manual path; migrated to a private file internally\n'
        '#   --worker-key <path>       (deprecated) Use --worker-password-file instead',
        'args_doc_worker_password_file',
    )
    return text


def apply_worker_password_globals(text):
    text = replace_exactly_once(
        text,
        'WORKER_IPS=""\nROLE=""\n',
        'WORKER_IPS=""\nWORKER_PASSWORD=""\nROLE=""\n',
        'worker_password_global',
    )
    text = replace_exactly_once(
        text,
        'WORKER_SSH_KEY=""  # deprecated: workers use sshpass (aella/aelladata)',
        'WORKER_SSH_KEY=""  # deprecated: use --worker-password',
        'worker_ssh_key_comment',
    )
    return text


def apply_credential_ssh_helpers(text):
    anchors = (
        '# AELDEV-71573: keepalive is REQUIRED on the master->worker SSH.',
        'SCP_OPTS="-o StrictHostKeyChecking=no"\nSSH_OPTS="-o StrictHostKeyChecking=no"',
    )
    for anchor in anchors:
        if _count(text, anchor) == 1:
            return insert_before(
                text, anchor, _credential_ssh_fragment(), 'credential_ssh_helpers_insert',
            )
    raise PatchCompatError('credential_ssh_helpers_insert', 'anchor_count=0 expected=1')


def apply_ssh_host_keys(text):
    opts_full = (
        'SCP_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${PHASE2_SSH_KNOWN_HOSTS_FILE} '
        '-o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=240 -o TCPKeepAlive=yes"\n'
        'SSH_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${PHASE2_SSH_KNOWN_HOSTS_FILE} '
        '-o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=240 -o TCPKeepAlive=yes"'
    )
    opts_minimal = (
        'SCP_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${PHASE2_SSH_KNOWN_HOSTS_FILE} '
        '-o ConnectTimeout=30"\n'
        'SSH_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${PHASE2_SSH_KNOWN_HOSTS_FILE} '
        '-o ConnectTimeout=30"'
    )
    return replace_exactly_one_mapping(
        text,
        (
            (
                'SCP_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 '
                '-o ServerAliveInterval=30 -o ServerAliveCountMax=240 -o TCPKeepAlive=yes"\n'
                'SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 '
                '-o ServerAliveInterval=30 -o ServerAliveCountMax=240 -o TCPKeepAlive=yes"',
                opts_full,
            ),
            (
                'SCP_OPTS="-o StrictHostKeyChecking=no"\nSSH_OPTS="-o StrictHostKeyChecking=no"',
                opts_minimal,
            ),
        ),
        'ssh_host_keys',
    )


def apply_acps_credential_removal(text):
    """Remove embedded ACPS password literals without secret-value anchors.

    Identifies ACPS_PASS assignments with a non-empty quoted literal in the
    bringup configuration area. Exactly one such candidate is required when
    the upstream still embeds a password; zero candidates is allowed only when
    the password is already empty or the upstream has no ACPS_PASS assignment.
    Ambiguous (2+) candidates fail closed.
    """
    # Match whole-line ACPS_PASS='...' / ACPS_PASS="..." assignments only.
    assign_re = re.compile(
        r'(?m)^(?P<prefix>ACPS_PASS=)(?P<q>[\'"])(?P<val>.*?)(?P=q)(?P<suffix>.*)$'
    )
    matches = list(assign_re.finditer(text))
    nonempty = [m for m in matches if m.group('val')]
    empty = [m for m in matches if not m.group('val')]

    if len(nonempty) > 1:
        raise PatchCompatError(
            'acps_credential_removal',
            'anchor_count=%d expected=1' % len(nonempty),
        )

    if len(nonempty) == 1:
        m = nonempty[0]
        replacement = (
            'ACPS_PASS=""  # embedded credentials removed; use Mirror Manager --skip-download'
        )
        return text[:m.start()] + replacement + text[m.end():]

    # Zero nonempty literals: already scrubbed, or no ACPS_PASS line.
    # Fail closed only when upstream still has ACPS auth curl using ${ACPS_PASS}
    # but no replaceable ACPS_PASS assignment exists at all.
    uses_embedded_auth = (
        '-u "${ACPS_USER}:${ACPS_PASS}"' in text
        or "-u \"${ACPS_USER}:${ACPS_PASS}\"" in text
    )
    if uses_embedded_auth and not matches and not empty:
        # ACPS_PASS referenced for auth but no assignment line found.
        raise PatchCompatError(
            'acps_credential_removal',
            'anchor_count=0 expected=1',
        )
    return text


def apply_acps_preflight_fail_closed(text):
    preflight_prev = (
        '    # Check ACPS connectivity\n'
        '    if [[ "$SKIP_DOWNLOAD" != "true" ]]; then\n'
        '        mkdir -p "$STAGING_DIR" "$AELLADEB_DIR" 2>/dev/null || true\n'
        '        if check_local_artifacts; then\n'
        '            log "All artifacts pre-staged locally -- download not required"\n'
        '        else\n'
        '            if ! command -v curl &>/dev/null; then\n'
        '                die "curl not found. Install with: apt-get install -y curl"\n'
        '            fi\n'
        '            log "Testing ACPS connectivity..."\n'
        '            local http_code\n'
        '            http_code=$(curl -s -o /dev/null -w "%{http_code}" -k -u "${ACPS_USER}:${ACPS_PASS}" \\\n'
        '                --connect-timeout 30 --max-time 30 "https://${ACPS_HOST}/" || echo "000")\n'
        '            if [[ "$http_code" != "200" ]] && [[ "$http_code" != "401" ]]; then\n'
        '                log "WARNING: Cannot connect to ACPS (${ACPS_HOST}, HTTP ${http_code}) -- will use local artifacts only"\n'
        '                SKIP_DOWNLOAD=true\n'
        '            elif [[ "$http_code" == "401" ]]; then\n'
        '                die "ACPS authentication failed (HTTP 401). Check ACPS_USER/ACPS_PASS."\n'
        '            else\n'
        '                log "ACPS reachable (HTTP ${http_code})"\n'
        '            fi\n'
        '        fi\n'
        '    fi\n'
    )
    # production-3af369 adds dark-site DNS fallback cleanup inside the warning branch.
    preflight_prev_3af369 = (
        '    # Check ACPS connectivity\n'
        '    if [[ "$SKIP_DOWNLOAD" != "true" ]]; then\n'
        '        mkdir -p "$STAGING_DIR" "$AELLADEB_DIR" 2>/dev/null || true\n'
        '        if check_local_artifacts; then\n'
        '            log "All artifacts pre-staged locally -- download not required"\n'
        '        else\n'
        '            if ! command -v curl &>/dev/null; then\n'
        '                die "curl not found. Install with: apt-get install -y curl"\n'
        '            fi\n'
        '            log "Testing ACPS connectivity..."\n'
        '            local http_code\n'
        '            http_code=$(curl -s -o /dev/null -w "%{http_code}" -k -u "${ACPS_USER}:${ACPS_PASS}" \\\n'
        '                --connect-timeout 30 --max-time 30 "https://${ACPS_HOST}/" || echo "000")\n'
        '            if [[ "$http_code" != "200" ]] && [[ "$http_code" != "401" ]]; then\n'
        '                log "WARNING: Cannot connect to ACPS (${ACPS_HOST}, HTTP ${http_code}) -- will use local artifacts only"\n'
        '                SKIP_DOWNLOAD=true\n'
        '                # AELDEV-74638: auto-detected dark site -- remove any public\n'
        '                # fallback nameservers the DNS preflight appended\n'
        '                if [[ -n "$DNS_FALLBACK_LINES" ]]; then\n'
        '                    log "Dark-site auto-detected -- removing appended public fallback nameservers"\n'
        '                    remove_dns_fallback\n'
        '                fi\n'
        '            elif [[ "$http_code" == "401" ]]; then\n'
        '                die "ACPS authentication failed (HTTP 401). Check ACPS_USER/ACPS_PASS."\n'
        '            else\n'
        '                log "ACPS reachable (HTTP ${http_code})"\n'
        '            fi\n'
        '        fi\n'
        '    fi\n'
    )
    preflight_new = (
        '    # Direct ACPS download is disabled in patched production bringup.\n'
        '    # Mirror Manager stages artifacts; operators must use --skip-download.\n'
        '    if [[ "$SKIP_DOWNLOAD" != "true" ]]; then\n'
        '        if check_local_artifacts; then\n'
        '            log "All artifacts pre-staged locally -- treating as --skip-download"\n'
        '            SKIP_DOWNLOAD=true\n'
        '        else\n'
        '            phase2_acps_direct_download_fail_closed\n'
        '        fi\n'
        '    fi\n'
    )
    present = []
    for prev in (preflight_prev, preflight_prev_3af369):
        if prev in text:
            present.append(prev)
    if not present:
        return text
    if len(present) != 1:
        raise PatchCompatError(
            'acps_preflight_fail_closed',
            'multiple_alternative_anchors count=%d' % len(present),
        )
    return replace_exactly_once(
        text, present[0], preflight_new, 'acps_preflight_fail_closed',
    )


def apply_acps_download_fail_closed(text):
    anchor = (
        '    log "Downloading from ACPS (${ACPS_HOST})"\n'
        '\n'
        '    local curl_opts=(-fsS -k -u "${ACPS_USER}:${ACPS_PASS}" --connect-timeout 30 --max-time 1800)\n'
    )
    if anchor not in text:
        return text
    return replace_exactly_once(
        text,
        anchor,
        '    phase2_acps_direct_download_fail_closed\n',
        'acps_download_fail_closed',
    )


def apply_parse_args_worker_password(text):
    text = replace_exactly_once(
        text,
        '            --worker-ips)\n'
        '                WORKER_IPS="$2"; shift 2 ;;\n'
        '            --role)\n',
        '            --worker-ips)\n'
        '                if [[ $# -lt 2 || -z "${2:-}" || "$2" == --* ]]; then\n'
        '                    die "--worker-ips requires a value"\n'
        '                fi\n'
        '                WORKER_IPS="$2"; shift 2 ;;\n'
        '            --worker-password)\n'
        '                if [[ $# -lt 2 || -z "${2:-}" || "$2" == --* ]]; then\n'
        '                    die "--worker-password requires a value (use --worker-password=VALUE when VALUE begins with --)"\n'
        '                fi\n'
        '                WORKER_PASSWORD="$2"; shift 2 ;;\n'
        '            --worker-password=*)\n'
        '                WORKER_PASSWORD="${1#*=}"\n'
        '                [[ -n "$WORKER_PASSWORD" ]] || die "--worker-password requires a value"\n'
        '                shift ;;\n'
        '            --worker-password-file)\n'
        '                if [[ $# -lt 2 || -z "${2:-}" || "$2" == --* ]]; then\n'
        '                    die "--worker-password-file requires a path"\n'
        '                fi\n'
        '                PHASE2_WORKER_PASSWORD_FILE="$2"; shift 2 ;;\n'
        '            --worker-password-file=*)\n'
        '                PHASE2_WORKER_PASSWORD_FILE="${1#*=}"\n'
        '                [[ -n "$PHASE2_WORKER_PASSWORD_FILE" ]] || die "--worker-password-file requires a value"\n'
        '                shift ;;\n'
        '            --role)\n',
        'parse_args_worker_password_case',
    )
    # f1a73 introduced --standby. Previous supported upstream has no such flag.
    # When the global exists, its parser site must also match exactly once.
    if 'STANDBY_IPS=""' in text:
        text = replace_exactly_once(
            text,
            '            --standby)\n'
            '                STANDBY_IPS="$2"; shift 2 ;;\n',
            '            --standby)\n'
            '                if [[ $# -lt 2 || -z "${2:-}" || "$2" == --* ]]; then\n'
            '                    die "--standby requires a value"\n'
            '                fi\n'
            '                STANDBY_IPS="$2"; shift 2 ;;\n',
            'parse_args_standby_value',
        )
    help_prev = (
        '                echo "  --worker-ips <ip,ip>    Comma-separated worker IPs (master orchestrates)"\n'
        '                echo "  --role <role>           Override auto-detect (AIO|DR-master|DL-master|DR-worker|DL-worker)"\n'
    )
    help_f1a73 = (
        '                echo "  --worker-ips <ip,ip>    Comma-separated worker IPs (master orchestrates)"\n'
        '                echo "  --standby <ip[,ip]>     Standby node IP(s) -- orchestrated like workers but with"\n'
        '                echo "                          role standby, always AFTER the workers. May be used with"\n'
        '                echo "                          or without --worker-ips."\n'
        '                echo "  --role <role>           Override auto-detect (AIO|DR-master|DL-master|DR-worker|DL-worker|standby)"\n'
    )
    text = replace_exactly_one_mapping(
        text,
        (
            (
                help_prev,
                '                echo "  --worker-ips <ip,ip>    Comma-separated worker IPs (master orchestrates)"\n'
                '                echo "  --worker-password-file <path>  Mode-0600 SSH password file (production path)"\n'
                '                echo "  --worker-password <pw>  Legacy manual password (migrated to private file)"\n'
                '                echo "  --role <role>           Override auto-detect (AIO|DR-master|DL-master|DR-worker|DL-worker)"\n',
            ),
            (
                help_f1a73,
                '                echo "  --worker-ips <ip,ip>    Comma-separated worker IPs (master orchestrates)"\n'
                '                echo "  --worker-password-file <path>  Mode-0600 SSH password file (production path)"\n'
                '                echo "  --worker-password <pw>  Legacy manual password (migrated to private file)"\n'
                '                echo "  --standby <ip[,ip]>     Standby node IP(s) -- orchestrated like workers but with"\n'
                '                echo "                          role standby, always AFTER the workers. May be used with"\n'
                '                echo "                          or without --worker-ips."\n'
                '                echo "  --role <role>           Override auto-detect (AIO|DR-master|DL-master|DR-worker|DL-worker|standby)"\n',
            ),
        ),
        'parse_args_worker_password_help',
    )
    text = replace_exactly_once(
        text,
        '        esac\n'
        '    done\n'
        '\n'
        '    # --version not required for pre-upgrade cleanup, auto-os-upgrade, or the\n',
        '        esac\n'
        '    done\n'
        '\n'
        '    # WORKER_PASSWORD applies to all remote orchestration nodes (workers and standby).\n'
        '    finalize_worker_password_credential\n'
        '    require_worker_password_file_for_remote_orchestration\n'
        '    if declare -F normalize_remote_orchestration_nodes >/dev/null 2>&1; then\n'
        '        normalize_remote_orchestration_nodes || die "REMOTE_ORCH_NODES=FAIL"\n'
        '    fi\n'
        '\n'
        '    # --version not required for pre-upgrade cleanup, auto-os-upgrade, or the\n',
        'parse_args_worker_password_required',
    )
    return text


def apply_compat_block(text):
    _require_absent(text, 'validate_apt_dependency_graph()', 'compat_block_already_present')
    _require_absent(text, 'wait_for_master_token_api()', 'compat_block_already_present')
    return insert_before(
        text,
        '###############################################################################\n'
        '# PHASE 2: INSTALL PYTHON 3\n'
        '###############################################################################\n',
        _compat_fragment(),
        'compat_block_insert',
    )


def apply_install_python3_gates(text):
    text = replace_exactly_once(
        text,
        'install_python3() {\n'
        '    log_phase "Install Python 3"\n'
        '\n'
        '    # Ubuntu 24.04 ships python3.12 -- no tarball needed\n',
        'install_python3() {\n'
        '    log_phase "Install Python 3"\n'
        '\n'
        '    # Offline Ubuntu prerequisite closure (separate from ACPS artifacts).\n'
        '    # Must run before dpkg -i of the incomplete ACPS py3-apt-packages set.\n'
        '    install_phase2_ubuntu_prerequisites || \\\n'
        '        die "PHASE2_PREREQ_INSTALL=FAIL critical Ubuntu prerequisites missing"\n'
        '\n'
        '    # Ubuntu 24.04 ships python3.12 -- no tarball needed\n',
        'install_python3_prereq_call',
    )
    dpkg_prev = (
        '        if ls "$apt_tmpdir"/*.deb &>/dev/null; then\n'
        '            dpkg -i --force-depends "$apt_tmpdir"/*.deb 2>&1 | tail -10 || \\\n'
        '                log "WARNING: some debs in py3-apt-packages.tar.gz failed (continuing)"\n'
        '        fi\n'
    )
    dpkg_prev_new = (
        '        if ls "$apt_tmpdir"/*.deb &>/dev/null; then\n'
        '            local py3_apt_rc=0\n'
        '            set +e\n'
        '            dpkg -i "$apt_tmpdir"/*.deb\n'
        '            py3_apt_rc=$?\n'
        '            set -e\n'
        '            if [[ "$py3_apt_rc" -ne 0 ]]; then\n'
        '                log "ACPS_PY3_APT_DPKG=RETRY force_depends=YES (intra-bundle unpack order)"\n'
        '                set +e\n'
        '                dpkg -i --force-depends "$apt_tmpdir"/*.deb\n'
        '                py3_apt_rc=$?\n'
        '                set -e\n'
        '                log "ACPS_PY3_APT_FORCE_DEPENDS=USED rc=${py3_apt_rc} (not a success criterion)"\n'
        '            else\n'
        '                log "ACPS_PY3_APT_DPKG=PASS force_depends=NO"\n'
        '            fi\n'
        '        fi\n'
    )
    # 3af369: AELDEV-74638 filters out debs that would downgrade a newer base
    # package, then still bulk-installs with --force-depends as the success
    # path. Keep the filter; do not treat force-depends as success.
    dpkg_3af369 = (
        '        if ls "$apt_tmpdir"/*.deb &>/dev/null; then\n'
        '            local deb pkg dver iver install_list=()\n'
        '            for deb in "$apt_tmpdir"/*.deb; do\n'
        '                pkg=$(dpkg-deb -f "$deb" Package 2>/dev/null)\n'
        '                dver=$(dpkg-deb -f "$deb" Version 2>/dev/null)\n'
        '                [[ -z "$pkg" || -z "$dver" ]] && continue\n'
        '                iver=$(dpkg-query -W -f \'${Version}\' "$pkg" 2>/dev/null || true)\n'
        '                if [[ -n "$iver" ]] && dpkg --compare-versions "$iver" gt "$dver"; then\n'
        '                    continue    # installed is newer -- never downgrade\n'
        '                fi\n'
        '                install_list+=("$deb")\n'
        '            done\n'
        '            log "py3-apt-packages: installing ${#install_list[@]} of $(ls "$apt_tmpdir"/*.deb | wc -l) debs (rest already current)"\n'
        '            if [[ ${#install_list[@]} -gt 0 ]]; then\n'
        '                dpkg -i --force-depends "${install_list[@]}" 2>&1 | tail -10 || \\\n'
        '                    log "WARNING: some debs in py3-apt-packages.tar.gz failed (continuing)"\n'
        '            fi\n'
        '        fi\n'
    )
    dpkg_3af369_new = (
        '        if ls "$apt_tmpdir"/*.deb &>/dev/null; then\n'
        '            local deb pkg dver iver install_list=()\n'
        '            for deb in "$apt_tmpdir"/*.deb; do\n'
        '                pkg=$(dpkg-deb -f "$deb" Package 2>/dev/null)\n'
        '                dver=$(dpkg-deb -f "$deb" Version 2>/dev/null)\n'
        '                [[ -z "$pkg" || -z "$dver" ]] && continue\n'
        '                iver=$(dpkg-query -W -f \'${Version}\' "$pkg" 2>/dev/null || true)\n'
        '                if [[ -n "$iver" ]] && dpkg --compare-versions "$iver" gt "$dver"; then\n'
        '                    continue    # installed is newer -- never downgrade\n'
        '                fi\n'
        '                install_list+=("$deb")\n'
        '            done\n'
        '            log "py3-apt-packages: installing ${#install_list[@]} of $(ls "$apt_tmpdir"/*.deb | wc -l) debs (rest already current)"\n'
        '            if [[ ${#install_list[@]} -gt 0 ]]; then\n'
        '                local py3_apt_rc=0\n'
        '                set +e\n'
        '                dpkg -i "${install_list[@]}"\n'
        '                py3_apt_rc=$?\n'
        '                set -e\n'
        '                if [[ "$py3_apt_rc" -ne 0 ]]; then\n'
        '                    log "ACPS_PY3_APT_DPKG=RETRY force_depends=YES (intra-bundle unpack order)"\n'
        '                    set +e\n'
        '                    dpkg -i --force-depends "${install_list[@]}"\n'
        '                    py3_apt_rc=$?\n'
        '                    set -e\n'
        '                    log "ACPS_PY3_APT_FORCE_DEPENDS=USED rc=${py3_apt_rc} (not a success criterion)"\n'
        '                else\n'
        '                    log "ACPS_PY3_APT_DPKG=PASS force_depends=NO"\n'
        '                fi\n'
        '            fi\n'
        '        fi\n'
    )
    text = replace_exactly_one_mapping(
        text,
        (
            (dpkg_prev, dpkg_prev_new),
            (dpkg_3af369, dpkg_3af369_new),
        ),
        'install_python3_dpkg_no_force_depends',
    )
    text = replace_exactly_once(
        text,
        '        log "Installing pip3..."\n'
        '        apt-get update -qq 2>&1 | tail -3 || log "WARNING: apt-get update had errors"\n'
        '        apt-get install -f -y -qq 2>&1 | tail -3 || log "WARNING: apt --fix-broken install had errors"\n'
        '        if apt-get install -y -qq python3-pip python3-wheel python3-setuptools 2>&1 | tail -3; then\n',
        '        log "Installing pip3..."\n'
        '        apt-get update -qq 2>&1 | tail -3 || log "WARNING: apt-get update had errors"\n'
        '        if apt-get install -y -qq python3-pip python3-wheel python3-setuptools 2>&1 | tail -3; then\n',
        'install_python3_no_apt_fix_broken',
    )
    hard_gates_body = (
        '    # dpkg --audit and --force-depends are not sufficient. The APT graph\n'
        '    # must be consistent before Python runtime validation or worker orch.\n'
        '    validate_apt_dependency_graph python3_apt || \\\n'
        '        die "APT_DEPENDENCY_CHECK=FAIL after Ubuntu/Python package installation"\n'
        '    # Critical runtime imports are a hard gate (not warnings). dpkg "install ok\n'
        '    # installed" is not sufficient — Flask without click still fails to import.\n'
        '    validate_critical_python_runtime || \\\n'
        '        die "CRITICAL_PYTHON_RUNTIME=FAIL Phase 2 cannot continue"\n'
    )
    hard_prev = (
        '    python3 -c "import psutil" 2>/dev/null || log "WARNING: psutil still missing"\n'
        '    python3 -c "import pymongo" 2>/dev/null || log "WARNING: pymongo still missing"\n'
        '    python3 -c "import flask" 2>/dev/null || log "WARNING: flask still missing"\n'
        '    log "Python 3 system packages installed"\n'
    )
    hard_prev_new = (
        hard_gates_body
        + '    python3 -c "import psutil" 2>/dev/null || log "WARNING: psutil still missing"\n'
        + '    python3 -c "import pymongo" 2>/dev/null || log "WARNING: pymongo still missing"\n'
        + '    log "Python 3 system packages installed"\n'
    )
    # 3af369 names flask/click as critical but still continues on WARNING.
    # Project policy is fail-closed; keep the upstream diagnostic text as
    # comments only after the hard gates.
    hard_3af369 = (
        '    # Verify critical imports.\n'
        '    # AELDEV-74638: aella_da_restful imports flask (which imports click); if\n'
        '    # these cannot import, the master never binds :8003 and worker joins\n'
        '    # stall silently. Do NOT abort here -- the rest of the master bringup is\n'
        '    # independent of flask and completing it leaves the operator ONE small\n'
        '    # manual fix + rerun (exactly how the field recovery worked). Instead:\n'
        '    # name precisely what is missing + how to fix, and let the\n'
        '    # pre-orchestration :8003 gate stop things before any worker can hang.\n'
        '    MISSING_PY3_PKGS=""\n'
        '    local mod\n'
        '    for mod in psutil pymongo flask click; do\n'
        '        python3 -c "import $mod" 2>/dev/null || MISSING_PY3_PKGS="$MISSING_PY3_PKGS python3-$mod"\n'
        '    done\n'
        '    if [[ -n "$MISSING_PY3_PKGS" ]]; then\n'
        '        log "WARNING: critical python3 module(s) failed to import; missing apt packages:$MISSING_PY3_PKGS"\n'
        '        log "  py3-apt-packages.tar.gz in the staged bundle is incomplete (AELDEV-74638;"\n'
        '        log "  bundles published before 2026-08 lack python3-click and others)."\n'
        '        log "  Bringup will continue, but aella_da_restful cannot start without flask,"\n'
        '        log "  so :8003 will not bind and worker joins would hang. FIX (then rerun or"\n'
        '        log "  let the pre-worker gate instructions guide you):"\n'
        '        log "    online:    apt-get install -y$MISSING_PY3_PKGS"\n'
        '        log "    dark-site: on any internet Ubuntu 24.04 host: apt-get download$MISSING_PY3_PKGS"\n'
        '        log "               copy the .debs to this DP and run: dpkg -i <debs>"\n'
        '    else\n'
        '        log "Python 3 system packages installed (psutil pymongo flask click OK)"\n'
        '    fi\n'
    )
    hard_3af369_new = (
        '    # AELDEV-74638 named flask/click as critical, but warning-and-continue\n'
        '    # is not sufficient for dark-site Phase 2. APT graph + runtime imports\n'
        '    # are hard gates; wait_for_da_restful_8003 remains as an additional\n'
        '    # listen check before worker orchestration.\n'
        + hard_gates_body
        + '    log "Python 3 system packages installed (psutil pymongo flask click OK)"\n'
    )
    text = replace_exactly_one_mapping(
        text,
        (
            (hard_prev, hard_prev_new),
            (hard_3af369, hard_3af369_new),
        ),
        'install_python3_hard_gates',
    )
    return text


def apply_overlay2_worker_password(text):
    text = replace_exactly_once(
        text,
        '    local WORKER_USER="aella" WORKER_PASS="aelladata"\n'
        '    local workers worker_ip dry_flag=""\n',
        '    init_phase2_ssh_known_hosts\n'
        '    local WORKER_USER="aella"\n'
        '    require_worker_password_file_for_remote_orchestration\n'
        '    local workers worker_ip dry_flag=""\n',
        'overlay2_worker_password',
    )
    text = replace_exactly_once(
        text,
        '        if ! sshpass -p "$WORKER_PASS" scp -O $SCP_OPTS "$SCRIPT_PATH" \\\n'
        '                "${WORKER_USER}@${worker_ip}:/tmp/${SCRIPT_NAME}" >/dev/null 2>&1; then\n',
        '        if ! sshpass -f "$PHASE2_WORKER_PASSWORD_FILE" scp -O $SCP_OPTS "$SCRIPT_PATH" \\\n'
        '                "${WORKER_USER}@${worker_ip}:/tmp/${SCRIPT_NAME}" >/dev/null 2>&1; then\n',
        'overlay2_sshpass_scp',
    ) if (
        '        if ! sshpass -p "$WORKER_PASS" scp -O $SCP_OPTS "$SCRIPT_PATH" \\\n'
        in text
    ) else text
    if '        sshpass -p "$WORKER_PASS" ssh $SSH_OPTS "${WORKER_USER}@${worker_ip}" \\\n' in text:
        text = replace_exactly_once(
            text,
            '        sshpass -p "$WORKER_PASS" ssh $SSH_OPTS "${WORKER_USER}@${worker_ip}" \\\n',
            '        sshpass -f "$PHASE2_WORKER_PASSWORD_FILE" ssh $SSH_OPTS "${WORKER_USER}@${worker_ip}" \\\n',
            'overlay2_sshpass_ssh',
        )
    return text


def apply_orchestrate_workers(text):
    text = replace_exactly_once(
        text,
        '    # Worker SSH via sshpass (standard on-prem DP auth: aella/aelladata)\n'
        '    local WORKER_PASS="aelladata"\n'
        '    local WORKER_USER="aella"\n'
        '    if ! command -v sshpass &>/dev/null; then\n',
        '    # Worker SSH via sshpass -f (private password file; never argv literal)\n'
        '    local WORKER_USER="aella"\n'
        '    init_phase2_ssh_known_hosts\n'
        '    require_worker_password_file_for_remote_orchestration\n'
        '    if declare -F normalize_remote_orchestration_nodes >/dev/null 2>&1; then\n'
        '        normalize_remote_orchestration_nodes || die "REMOTE_ORCH_NODES=FAIL"\n'
        '    fi\n'
        '    if ! command -v sshpass &>/dev/null; then\n',
        'orchestrate_workers_password',
    )
    text = replace_exactly_once(
        text,
        '    worker_ssh() {\n'
        '        local ip="$1"; shift\n'
        '        sshpass -p "$WORKER_PASS" ssh $SSH_OPTS "${WORKER_USER}@${ip}" "$@"\n'
        '    }\n'
        '    worker_scp() {\n'
        '        local src="$1" dst_ip="$2" dst_path="$3"\n'
        '        sshpass -p "$WORKER_PASS" scp $SCP_OPTS "$src" "${WORKER_USER}@${dst_ip}:${dst_path}"\n'
        '    }\n',
        '    worker_ssh() {\n'
        '        local ip="$1"; shift\n'
        '        sshpass -f "$PHASE2_WORKER_PASSWORD_FILE" ssh $SSH_OPTS "${WORKER_USER}@${ip}" "$@"\n'
        '    }\n'
        '    worker_scp() {\n'
        '        local src="$1" dst_ip="$2" dst_path="$3"\n'
        '        sshpass -f "$PHASE2_WORKER_PASSWORD_FILE" scp $SCP_OPTS "$src" "${WORKER_USER}@${dst_ip}:${dst_path}"\n'
        '    }\n',
        'orchestrate_workers_sshpass_file',
    )
    if '    # due to key exchange. SSH_OPTS uses UserKnownHostsFile=/dev/null so\n' in text:
        text = replace_exactly_once(
            text,
            '    # Warm up SSH connections to workers: first sshpass connect can be slow\n'
            '    # due to key exchange. SSH_OPTS uses UserKnownHostsFile=/dev/null so\n'
            '    # known_hosts isn\'t used; the retry below handles the timing issue.\n',
            '    # Warm up SSH connections to workers: first sshpass connect can be slow\n'
            '    # due to key exchange. SSH_OPTS uses accept-new with a persistent\n'
            '    # project-owned known_hosts file; the retry below handles timing.\n',
            'orchestrate_workers_ssh_comment',
        )
    fail_state_prev = (
        '    IFS=\',\' read -ra workers <<< "$WORKER_IPS"\n'
        '\n'
        '    for worker_ip in "${workers[@]}"; do\n'
        '        worker_ip=$(echo "$worker_ip" | xargs)  # trim whitespace\n'
        '        [[ -z "$worker_ip" ]] && continue\n'
        '        log ""\n'
        '        log "--- Deploying worker: $worker_ip ---"\n'
    )
    fail_state_f1a73 = (
        '    local node_spec worker_ip node_role\n'
        '    for node_spec in "${node_specs[@]}"; do\n'
        '        worker_ip="${node_spec%%:*}"\n'
        '        node_role="${node_spec##*:}"\n'
        '        log ""\n'
        '        log "--- Deploying node: $worker_ip (role: $node_role) ---"\n'
    )
    text = replace_exactly_one_mapping(
        text,
        (
            (
                fail_state_prev,
                '    IFS=\',\' read -ra workers <<< "$WORKER_IPS"\n'
                '    local orch_failed=0\n'
                '\n'
                '    for worker_ip in "${workers[@]}"; do\n'
                '        worker_ip=$(echo "$worker_ip" | xargs)  # trim whitespace\n'
                '        [[ -z "$worker_ip" ]] && continue\n'
                '        log ""\n'
                '        log "--- Deploying worker: $worker_ip ---"\n'
                '        local worker_failed=0\n'
                '        local worker_reason=""\n',
            ),
            (
                fail_state_f1a73,
                '    local node_spec worker_ip node_role\n'
                '    local orch_failed=0\n'
                '    for node_spec in "${node_specs[@]}"; do\n'
                '        worker_ip="${node_spec%%:*}"\n'
                '        node_role="${node_spec##*:}"\n'
                '        log ""\n'
                '        log "--- Deploying node: $worker_ip (role: $node_role) ---"\n'
                '        local worker_failed=0\n'
                '        local worker_reason=""\n',
            ),
        ),
        'orchestrate_workers_fail_state',
    )
    text = replace_exactly_once(
        text,
        '                log "ERROR: Cannot SSH to worker $worker_ip -- skipping"\n'
        '                continue\n',
        '                log "ERROR: Cannot SSH to worker $worker_ip"\n'
        '                log "WORKER_RESULT ip=${worker_ip} result=FAIL reason=ssh"\n'
        '                orch_failed=1\n'
        '                continue\n',
        'orchestrate_workers_ssh_fail',
    )

    # Role identity must be checked BEFORE any remote mkdir/copy/bringup mutation.
    # f1a73 has a standby-only role guard at this location; replace it with the
    # general expected==actual contract. Previous upstream has no role guard, so
    # insert an equivalent worker-role gate immediately before its first mutation.
    if 'STANDBY_IPS=""' in text:
        role_mismatch_f1a73 = (
            '        # AELDEV-73583 guard: intended role must match the node\'s preserved\n'
            '        # aella_role in BOTH directions. A standby listed under --worker-ips\n'
            '        # would be provisioned as a worker (wrong token params, wrong\n'
            '        # expectations); a worker listed under --standby would be provisioned\n'
            '        # as a standby. Skip with instructions instead of mis-provisioning.\n'
            '        local remote_role\n'
            '        remote_role=$(worker_ssh "$worker_ip" \\\n'
            '            "grep aella_role /opt/aelladata/work/da_conf.yml 2>/dev/null | awk -F\': \' \'{print \\$2}\' | tr -d \\"\' \\"" 2>/dev/null || echo "")\n'
            '        if [[ "$remote_role" == "standby" && "$node_role" != "standby" ]]; then\n'
            '            log "ERROR: $worker_ip has aella_role: standby but was listed in --worker-ips -- SKIPPING."\n'
            '            log "  Use --standby $worker_ip (or run on the node itself with --role standby)."\n'
            '            continue\n'
            '        fi\n'
            '        if [[ "$node_role" == "standby" && -n "$remote_role" && "$remote_role" != "standby" ]]; then\n'
            '            log "ERROR: $worker_ip was listed in --standby but has aella_role: ${remote_role} -- SKIPPING."\n'
            '            log "  Use --worker-ips for workers; fix da_conf/role assignment first."\n'
            '            continue\n'
            '        fi\n'
        )
        text = replace_exactly_once(
            text,
            role_mismatch_f1a73,
            '        if ! validate_remote_role_identity "$worker_ip" "$node_role"; then\n'
            '            orch_failed=1\n'
            '            continue\n'
            '        fi\n',
            'orchestrate_workers_role_identity_f1a73',
        )
    else:
        prev_mutation_anchor = (
            '        # Create directories on worker (sudo needed for aella user) and\n'
        )
        prev_role_gate = (
            '        local expected_remote_role\n'
            '        if [[ "$ROLE" == "DR-master" ]]; then\n'
            '            expected_remote_role="DR-worker"\n'
            '        elif [[ "$ROLE" == "DL-master" ]]; then\n'
            '            expected_remote_role="DL-worker"\n'
            '        else\n'
            '            expected_remote_role="DR-worker"\n'
            '        fi\n'
            '        if ! validate_remote_role_identity "$worker_ip" "$expected_remote_role"; then\n'
            '            orch_failed=1\n'
            '            continue\n'
            '        fi\n'
            '\n'
        )
        text = insert_before(
            text,
            prev_mutation_anchor,
            prev_role_gate,
            'orchestrate_workers_role_identity_prev',
        )

    text = replace_exactly_once(
        text,
        '        log "Copying script to $worker_ip..."\n'
        '        worker_scp "$SCRIPT_PATH" "$worker_ip" "/tmp/${SCRIPT_NAME}"\n',
        '        log "Copying script to $worker_ip..."\n'
        '        if ! worker_scp "$SCRIPT_PATH" "$worker_ip" "/tmp/${SCRIPT_NAME}"; then\n'
        '            log "WORKER_RESULT ip=${worker_ip} result=FAIL reason=artifact_copy"\n'
        '            orch_failed=1\n'
        '            continue\n'
        '        fi\n',
        'orchestrate_workers_script_copy',
    )
    text = replace_exactly_once(
        text,
        '            _scp_err=$(worker_scp "$f" "$worker_ip" "${STAGING_DIR}/" 2>&1 >/dev/null) || \\\n'
        '                log "  WARNING: failed to scp $(basename "$f"): ${_scp_err}"\n',
        '            _scp_err=$(worker_scp "$f" "$worker_ip" "${STAGING_DIR}/" 2>&1 >/dev/null) || {\n'
        '                log "ERROR: failed to scp ${_fname}"\n'
        '                worker_failed=1\n'
        '                worker_reason="artifact_copy"\n'
        '            }\n',
        'orchestrate_workers_staging_copy',
    )
    text = replace_exactly_once(
        text,
        '            _scp_err=$(worker_scp "$f" "$worker_ip" "${AELLADEB_DIR}/" 2>&1 >/dev/null) || \\\n'
        '                log "  WARNING: failed to scp $(basename "$f"): ${_scp_err}"\n'
        '        done\n',
        '            _scp_err=$(worker_scp "$f" "$worker_ip" "${AELLADEB_DIR}/" 2>&1 >/dev/null) || {\n'
        '                log "ERROR: failed to scp $(basename "$f")"\n'
        '                worker_failed=1\n'
        '                worker_reason="artifact_copy"\n'
        '            }\n'
        '        done\n'
        '        if [[ "$worker_failed" -ne 0 ]]; then\n'
        '            log "WORKER_RESULT ip=${worker_ip} result=FAIL reason=${worker_reason}"\n'
        '            orch_failed=1\n'
        '            continue\n'
        '        fi\n',
        'orchestrate_workers_uvp_copy',
    )
    remote_rc_prev = (
        '        log "Running bringup on worker $worker_ip (role: $worker_role)..."\n'
        '        worker_ssh "$worker_ip" \\\n'
        '            "sudo bash /tmp/${SCRIPT_NAME} --version $VERSION --role $worker_role --worker-mode --skip-download" 2>&1 | \\\n'
        '            while IFS= read -r line; do log "  [$worker_ip] $line"; done || {\n'
        '            log "WARNING: Worker $worker_ip bringup had errors"\n'
        '        }\n'
    )
    remote_rc_f1a73 = (
        '        log "Running bringup on $worker_ip (role: $node_role)..."\n'
        '        worker_ssh "$worker_ip" \\\n'
        '            "sudo bash /tmp/${SCRIPT_NAME} --version $VERSION --role $node_role --worker-mode ${skip_flag}" 2>&1 | \\\n'
        '            while IFS= read -r line; do log "  [$worker_ip] $line"; done || {\n'
        '            log "WARNING: Node $worker_ip bringup had errors"\n'
        '        }\n'
    )
    text = replace_exactly_one_mapping(
        text,
        (
            (
                remote_rc_prev,
                '        # Run script on worker (sudo for root access). Capture rc without a\n'
                '        # pipe so set -euo pipefail cannot hide a remote nonzero status.\n'
                '        log "Running bringup on worker $worker_ip (role: $worker_role)..."\n'
                '        local worker_out worker_rc=0\n'
                '        worker_out="$(mktemp /tmp/worker-bringup.XXXXXX)"\n'
                '        set +e\n'
                '        worker_ssh "$worker_ip" \\\n'
                '            "sudo bash /tmp/${SCRIPT_NAME} --version $VERSION --role $worker_role --worker-mode --skip-download" \\\n'
                '            >"$worker_out" 2>&1\n'
                '        worker_rc=$?\n'
                '        set -e\n'
                '        while IFS= read -r line || [[ -n "$line" ]]; do\n'
                '            log "  [$worker_ip] $line"\n'
                '        done <"$worker_out"\n'
                '        rm -f "$worker_out"\n'
                '        if [[ "$worker_rc" -ne 0 ]]; then\n'
                '            log "WORKER_RESULT ip=${worker_ip} result=FAIL reason=remote_bringup"\n'
                '            orch_failed=1\n'
                '            continue\n'
                '        fi\n',
            ),
            (
                remote_rc_f1a73,
                '        # Run script on worker (sudo for root access). Capture rc without a\n'
                '        # pipe so set -euo pipefail cannot hide a remote nonzero status.\n'
                '        log "Running bringup on $worker_ip (role: $node_role)..."\n'
                '        local worker_out worker_rc=0\n'
                '        worker_out="$(mktemp /tmp/worker-bringup.XXXXXX)"\n'
                '        set +e\n'
                '        worker_ssh "$worker_ip" \\\n'
                '            "sudo bash /tmp/${SCRIPT_NAME} --version $VERSION --role $node_role --worker-mode ${skip_flag}" \\\n'
                '            >"$worker_out" 2>&1\n'
                '        worker_rc=$?\n'
                '        set -e\n'
                '        while IFS= read -r line || [[ -n "$line" ]]; do\n'
                '            log "  [$worker_ip] $line"\n'
                '        done <"$worker_out"\n'
                '        rm -f "$worker_out"\n'
                '        if [[ "$worker_rc" -ne 0 ]]; then\n'
                '            log "WORKER_RESULT ip=${worker_ip} result=FAIL reason=remote_bringup"\n'
                '            orch_failed=1\n'
                '            continue\n'
                '        fi\n',
            ),
        ),
        'orchestrate_workers_remote_rc',
    )
    text = replace_exactly_once(
        text,
        '        sleep 10\n'
        '        local worker_hostname\n'
        '        worker_hostname=$(worker_ssh "$worker_ip" "hostname" 2>/dev/null || echo "unknown")\n'
        '        if kubectl get nodes 2>/dev/null | grep -qi "$worker_hostname"; then\n'
        '            log "Worker $worker_ip ($worker_hostname) joined cluster successfully"\n'
        '        else\n'
        '            log "WARNING: Worker $worker_ip ($worker_hostname) not yet visible in \'kubectl get nodes\'"\n'
        '            log "  It may still be joining -- check with: kubectl get nodes"\n'
        '        fi\n'
        '\n'
        '        log "Worker $worker_ip deployment complete"\n'
        '    done\n'
        '\n'
        '    # Final cluster state\n'
        '    log "Cluster state after worker deployment:"\n'
        '    kubectl get nodes -o wide 2>/dev/null || true\n'
        '}\n',
        '        # Verify the requested target hostname is Ready (bounded wait).\n'
        '        # Identity of THIS target is authoritative; global Ready count is not.\n'
        '        local worker_hostname ready_wait=0 ready_ok=0\n'
        '        local ready_attempts="${CLUSTER_TARGET_READY_ATTEMPTS:-60}"\n'
        '        local ready_sleep="${CLUSTER_TARGET_READY_SLEEP_SECONDS:-5}"\n'
        '        local result_role="${node_role:-${worker_role:-}}"\n'
        '        worker_hostname=$(worker_ssh "$worker_ip" "hostname" 2>/dev/null || true)\n'
        '        worker_hostname="${worker_hostname//$\'\\r\'/}"\n'
        '        worker_hostname="${worker_hostname#"${worker_hostname%%[![:space:]]*}"}"\n'
        '        worker_hostname="${worker_hostname%"${worker_hostname##*[![:space:]]}"}"\n'
        '        if [[ -z "$worker_hostname" || "$worker_hostname" == "unknown" ]]; then\n'
        '            log "WORKER_RESULT ip=${worker_ip} role=${result_role} result=FAIL reason=hostname"\n'
        '            orch_failed=1\n'
        '            continue\n'
        '        fi\n'
        '        while [[ "$ready_wait" -lt "$ready_attempts" ]]; do\n'
        '            if kubectl get nodes --no-headers 2>/dev/null \\\n'
        '                | awk -v h="$worker_hostname" \'BEGIN{IGNORECASE=1} $1==h && $2 ~ /^Ready($|,)/ {found=1} END{exit found?0:1}\'; then\n'
        '                ready_ok=1\n'
        '                break\n'
        '            fi\n'
        '            sleep "$ready_sleep"\n'
        '            ready_wait=$((ready_wait + 1))\n'
        '        done\n'
        '        if [[ "$ready_ok" -ne 1 ]]; then\n'
        '            log "WORKER_RESULT ip=${worker_ip} role=${result_role} result=FAIL reason=not_ready host=${worker_hostname}"\n'
        '            orch_failed=1\n'
        '            continue\n'
        '        fi\n'
        '\n'
        '        log "WORKER_RESULT ip=${worker_ip} role=${result_role} result=PASS"\n'
        '        log "Worker $worker_ip ($worker_hostname) joined cluster successfully"\n'
        '    done\n'
        '\n'
        '    # Final cluster state\n'
        '    log "Cluster state after worker deployment:"\n'
        '    kubectl get nodes -o wide 2>/dev/null || true\n'
        '    if [[ "$orch_failed" -ne 0 ]]; then\n'
        '        log "WORKER_ORCHESTRATION=FAIL"\n'
        '        return 1\n'
        '    fi\n'
        '    log "WORKER_ORCHESTRATION=PASS"\n'
        '    return 0\n'
        '}\n',
        'orchestrate_workers_ready_gate',
    )
    text = replace_exactly_once(
        text,
        '        log "Copying UVP debs to $worker_ip..."\n',
        '        # Explicit Phase 2 prerequisite contract. Do not rely on\n'
        '        # filename-extension globs as the prerequisite protocol.\n'
        '        if ! copy_phase2_prereq_contract_to_worker "$worker_ip"; then\n'
        '            log "WORKER_RESULT ip=${worker_ip} result=FAIL reason=prereq_contract_copy"\n'
        '            orch_failed=1\n'
        '            continue\n'
        '        fi\n'
        '        log "Copying UVP debs to $worker_ip..."\n',
        'orchestrate_workers_prereq_contract',
    )
    return text


def apply_join_k8s_cluster(text):
    curl_prev = (
        '        local token_response\n'
        '        token_response=$(curl -sk -u "${username}:${password}" \\\n'
        '            "https://${master_ip}:8003/api/1.0/master_token?host=${host_name}" 2>/dev/null)\n'
    )
    curl_f1a73 = (
        '        local token_response\n'
        '        token_response=$(curl -sk -u "${username}:${password}" \\\n'
        '            "https://${master_ip}:8003/api/1.0/master_token?host=${host_name}${token_extra}" 2>/dev/null)\n'
    )
    curl_wrap_prev = (
        '        local token_response curl_rc=0\n'
        '        token_response="$(curl -sk --connect-timeout 10 --max-time 30 \\\n'
        '            -u "${username}:${password}" \\\n'
        '            "https://${master_ip}:8003/api/1.0/master_token?host=${host_name}" \\\n'
        '            2>/dev/null)" || {\n'
        '            curl_rc=$?\n'
        '            log "ERROR: join-token API request failed master=${master_ip} port=8003 curl_rc=${curl_rc}"\n'
        '            log "WORKER_RESULT result=FAIL reason=token_api_curl"\n'
        '            return "$curl_rc"\n'
        '        }\n'
    )
    curl_wrap_f1a73 = (
        '        local token_response curl_rc=0\n'
        '        token_response="$(curl -sk --connect-timeout 10 --max-time 30 \\\n'
        '            -u "${username}:${password}" \\\n'
        '            "https://${master_ip}:8003/api/1.0/master_token?host=${host_name}${token_extra}" \\\n'
        '            2>/dev/null)" || {\n'
        '            curl_rc=$?\n'
        '            log "ERROR: join-token API request failed master=${master_ip} port=8003 curl_rc=${curl_rc}"\n'
        '            log "WORKER_RESULT result=FAIL reason=token_api_curl"\n'
        '            return "$curl_rc"\n'
        '        }\n'
    )
    text = replace_exactly_one_mapping(
        text,
        (
            (curl_prev, curl_wrap_prev),
            (curl_f1a73, curl_wrap_f1a73),
        ),
        'join_k8s_cluster_curl_rc',
    )
    text = replace_exactly_once(
        text,
        '        log "WARNING: Could not get token from REST API"\n'
        '        log "  Response: ${token_response:-empty}"\n'
        '        log "  Ensure master is fully up and aella_cluster_manager is running."\n'
        '        die "Cannot get join token from master"\n',
        '        log "ERROR: join-token API response invalid master=${master_ip} port=8003 length=${#token_response}"\n'
        '        log "WORKER_RESULT result=FAIL reason=token_api_invalid"\n'
        '        die "Cannot get join token from master"\n',
        'join_k8s_cluster_token_invalid',
    )
    return text


def apply_main_orchestration_gates(text):
    main_prev = (
        '    # Phase 13: Orchestrate workers (master only, after self is fully up)\n'
        '    if [[ "$WORKER_MODE" != "true" && -n "$WORKER_IPS" ]]; then\n'
        '        orchestrate_workers\n'
        '    fi\n'
    )
    main_f1a73 = (
        '    # Phase 13: Orchestrate workers + standby (master only, after self is fully up)\n'
        '    if [[ "$WORKER_MODE" != "true" && ( -n "$WORKER_IPS" || -n "$STANDBY_IPS" ) ]]; then\n'
        '        orchestrate_workers\n'
        '    fi\n'
    )
    main_3af369 = (
        '    # Phase 13: Orchestrate workers + standby (master only, after self is fully up)\n'
        '    if [[ "$WORKER_MODE" != "true" && ( -n "$WORKER_IPS" || -n "$STANDBY_IPS" ) ]]; then\n'
        '        # AELDEV-74638: verify the join-token endpoint is actually up before\n'
        '        # spending 60+ min orchestrating workers that would hang on it.\n'
        '        wait_for_da_restful_8003\n'
        '        orchestrate_workers\n'
        '    fi\n'
    )
    gates_body = (
        '        if ! validate_critical_python_runtime; then\n'
        '            die "CRITICAL_PYTHON_RUNTIME=FAIL before worker orchestration"\n'
        '        fi\n'
        '        MASTER_IP="${MASTER_IP:-}"\n'
        '        if [[ -z "$MASTER_IP" ]]; then\n'
        '            MASTER_IP=$(grep \'master_ip\' "$DA_CONF" 2>/dev/null | awk -F\': \' \'{print $2}\' | tr -d "\' \\"" || true)\n'
        '        fi\n'
        '        wait_for_master_token_api || die "MASTER_TOKEN_API_READY=NO; refusing worker orchestration"\n'
        '        orchestrate_workers || die "WORKER_ORCHESTRATION=FAIL"\n'
        '        validate_expected_cluster_nodes || die "CLUSTER_JOIN_STATE incomplete"\n'
    )
    text = replace_exactly_one_mapping(
        text,
        (
            (
                main_prev,
                '    # Phase 13: Orchestrate workers (master only, after self is fully up).\n'
                '    # Token API / TCP 8003 must be functionally ready first. systemctl is-active\n'
                '    # aellad is not sufficient — the failed lab had aellad active with 8003 down.\n'
                '    if [[ "$WORKER_MODE" != "true" && -n "$WORKER_IPS" ]]; then\n'
                + gates_body +
                '    fi\n',
            ),
            (
                main_f1a73,
                '    # Phase 13: Orchestrate workers + standby (master only, after self is fully up).\n'
                '    # Token API / TCP 8003 must be functionally ready first. systemctl is-active\n'
                '    # aellad is not sufficient — the failed lab had aellad active with 8003 down.\n'
                '    if [[ "$WORKER_MODE" != "true" && ( -n "$WORKER_IPS" || -n "$STANDBY_IPS" ) ]]; then\n'
                + gates_body +
                '    fi\n',
            ),
            (
                main_3af369,
                '    # Phase 13: Orchestrate workers + standby (master only, after self is fully up).\n'
                '    # Token API / TCP 8003 must be functionally ready first. systemctl is-active\n'
                '    # aellad is not sufficient — the failed lab had aellad active with 8003 down.\n'
                '    if [[ "$WORKER_MODE" != "true" && ( -n "$WORKER_IPS" || -n "$STANDBY_IPS" ) ]]; then\n'
                '        # AELDEV-74638: listen-gate on :8003 (upstream). Project layer still\n'
                '        # requires a functional token API, not TCP listen alone.\n'
                '        wait_for_da_restful_8003\n'
                + gates_body +
                '    fi\n',
            ),
        ),
        'main_orchestration_gates',
    )

    # Worker-mode completion is authoritative for both normal workers and
    # standalone standby. join_k8s_cluster may log warnings and return after a
    # partial join, so require local kubelet/conf/flannel evidence immediately.
    text = replace_exactly_once(
        text,
        '    # Worker join (worker mode only)\n'
        '    if [[ "$WORKER_MODE" == "true" ]]; then\n'
        '        join_k8s_cluster\n'
        '    fi\n',
        '    # Worker join (worker mode only)\n'
        '    if [[ "$WORKER_MODE" == "true" ]]; then\n'
        '        join_k8s_cluster\n'
        '        validate_local_remote_join_state || die "REMOTE_JOIN_LOCAL_STATE=FAIL"\n'
        '    fi\n',
        'worker_mode_local_join_gate',
    )

    # validate_all is diagnostic, but its role split must not treat standby as
    # a master/AIO. Standby uses the same local K8s checks as a worker.
    text = replace_exactly_once(
        text,
        '    if [[ "$ROLE" == *worker* ]]; then\n',
        '    if [[ "$ROLE" == *worker* || "$ROLE" == "standby" ]]; then\n',
        'validate_all_worker_or_standby',
    )
    master_cond = '    if [[ "$ROLE" != *worker* ]]; then\n'
    _require_count(text, master_cond, 2, 'validate_all_master_conditions')
    text = text.replace(
        master_cond,
        '    if [[ "$ROLE" == "AIO" || "$ROLE" == *master* ]]; then\n',
        2,
    )
    return text


def apply_image_import_heartbeat(text):
    _require_absent(text, '# BEGIN_IMAGE_IMPORT_HEARTBEAT', 'heartbeat_already_present')
    text = insert_before(
        text,
        'load_local_images() {\n',
        _heartbeat_fragment(),
        'heartbeat_helpers_insert',
    )
    gzip_block = (
        '        k8s_rc=0; moby_rc=0\n'
        '        if [[ "$tarball" == *.gz ]]; then\n'
        '            gunzip -c "$tarball" | ctr -n=k8s.io images import - >"$k8s_log" 2>&1 || k8s_rc=$?\n'
        '            gunzip -c "$tarball" | ctr -n=moby images import --no-unpack - >"$moby_log" 2>&1 || moby_rc=$?\n'
        '        else\n'
        '            ctr -n=k8s.io images import "$tarball" >"$k8s_log" 2>&1 || k8s_rc=$?\n'
        '            ctr -n=moby images import --no-unpack "$tarball" >"$moby_log" 2>&1 || moby_rc=$?\n'
        '        fi\n'
    )
    gzip_block_f1a73 = (
        '        k8s_rc=0; moby_rc=0\n'
        '        if [[ "$tarball" == *.gz ]]; then\n'
        '            gunzip -c "$tarball" | ctr -n=k8s.io images import - >"$k8s_log"  2>&1 || k8s_rc=$?\n'
        '            gunzip -c "$tarball" | ctr -n=moby   images import --no-unpack - >"$moby_log" 2>&1 || moby_rc=$?\n'
        '        else\n'
        '            ctr -n=k8s.io images import "$tarball" >"$k8s_log"  2>&1 || k8s_rc=$?\n'
        '            ctr -n=moby   images import --no-unpack "$tarball" >"$moby_log" 2>&1 || moby_rc=$?\n'
        '        fi\n'
    )
    simple_block = (
        '        k8s_rc=0; moby_rc=0\n'
        '        ctr -n=k8s.io images import "$tarball" >"$k8s_log" 2>&1 || k8s_rc=$?\n'
        '        ctr -n=moby images import --no-unpack "$tarball" >"$moby_log" 2>&1 || moby_rc=$?\n'
    )
    wrapped = (
        '        k8s_rc=0; moby_rc=0\n'
        '        run_image_import_with_heartbeat "k8s.io" "$tarball" "$k8s_log" || k8s_rc=$?\n'
        '        log "IMAGE_IMPORT_NEXT namespace=moby file=$(basename "$tarball") note=serial_after_k8s.io"\n'
        '        run_image_import_with_heartbeat "moby" "$tarball" "$moby_log" --no-unpack || moby_rc=$?\n'
    )
    text = replace_exactly_one_of(
        text,
        (gzip_block, gzip_block_f1a73, simple_block),
        wrapped,
        'image_import_ctr_wrap',
    )
    text = replace_exactly_once(
        text,
        '        log "Loading $tarball ($size) into containerd k8s.io + moby namespaces (serial)..."\n'
        '        k8s_log=$(mktemp /tmp/load_local_k8s.XXXXXX.log)\n',
        '        log "Loading $tarball ($size) into containerd k8s.io + moby namespaces (serial)..."\n'
        '        log "NOTICE: Local image import may take tens of minutes or longer."\n'
        '        log "NOTICE: Duration depends on image size, CPU, storage performance, and hypervisor datastore performance."\n'
        '        log "NOTICE: ctr may not print output while it is actively importing images."\n'
        '        log "NOTICE: Do not interrupt bringup, restart containerd, reboot the VM, or run bringup again."\n'
        '        log "NOTICE: Progress heartbeat will be printed every $(image_import_heartbeat_seconds) seconds."\n'
        '        k8s_log=$(mktemp /tmp/load_local_k8s.XXXXXX.log)\n',
        'image_import_notices',
    )
    return text


def apply_dp_resume_notices(text):
    _require_absent(text, '# BEGIN_DP_RESUME_OPERATOR_NOTICE', 'resume_notice_already_present')
    if 'LOG_FILE="${LOG_FILE:-/var/log/aella/aella_py3_bringup.log}"' not in text:
        text = replace_exactly_once(
            text,
            'LOG_FILE="/var/log/aella/aella_py3_bringup.log"\n',
            'LOG_FILE="${LOG_FILE:-/var/log/aella/aella_py3_bringup.log}"\n',
            'resume_log_file_default',
        )
    resume_prev = (
        '    } >> "$LOG_FILE" 2>/dev/null || true\n'
        '}\n'
    )
    resume_f1a73 = (
        '    echo "========================================================================"\n'
        '    echo "  Bringup complete: $(date)"\n'
        '    echo "  Role: $ROLE"\n'
        '    echo "  Version: $VERSION"\n'
        '    echo "  Log: $LOG_FILE"\n'
        '    echo "========================================================================"\n'
        '}\n'
    )
    resume_3af369 = (
        '    log ""\n'
        '    log "========================================================================"\n'
        '    log "  Bringup complete: $(date)"\n'
        '    log "  Role: $ROLE"\n'
        '    log "  Version: $VERSION"\n'
        '    log "  Log: $LOG_FILE"\n'
        '    log "========================================================================"\n'
        '}\n'
    )
    text = replace_exactly_one_mapping(
        text,
        (
            (
                resume_prev,
                '    } >> "$LOG_FILE" 2>/dev/null || true\n'
                '    emit_dp_resume_post_complete_notice\n'
                '}\n',
            ),
            (
                resume_f1a73,
                '    echo "========================================================================"\n'
                '    echo "  Bringup complete: $(date)"\n'
                '    echo "  Role: $ROLE"\n'
                '    echo "  Version: $VERSION"\n'
                '    echo "  Log: $LOG_FILE"\n'
                '    echo "========================================================================"\n'
                '    emit_dp_resume_post_complete_notice\n'
                '}\n',
            ),
            (
                resume_3af369,
                '    log ""\n'
                '    log "========================================================================"\n'
                '    log "  Bringup complete: $(date)"\n'
                '    log "  Role: $ROLE"\n'
                '    log "  Version: $VERSION"\n'
                '    log "  Log: $LOG_FILE"\n'
                '    log "========================================================================"\n'
                '    emit_dp_resume_post_complete_notice\n'
                '}\n',
            ),
        ),
        'resume_post_complete_call',
    )
    text = replace_exactly_once(
        text,
        '    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true\n'
        '    echo "AELDEV-71573: detaching bringup so it survives SSH/console disconnect."\n',
        '    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true\n'
        '    # Operator must see pause/resume guidance on the controlling terminal before\n'
        '    # the launcher hands off to the detached session.\n'
        '    emit_dp_resume_pre_detach_notice\n'
        '    echo "AELDEV-71573: detaching bringup so it survives SSH/console disconnect."\n',
        'resume_pre_detach_call',
    )
    text = insert_before(
        text,
        'detach_guard "$@"\n',
        _resume_fragment()
        + 'if [[ "${BRINGUP_TEST_EMIT_PRE_DETACH_NOTICE_ONLY:-0}" == "1" ]]; then\n'
        '    emit_dp_resume_pre_detach_notice\n'
        '    exit 0\n'
        'fi\n'
        'if [[ "${BRINGUP_TEST_EMIT_POST_COMPLETE_NOTICE_ONLY:-0}" == "1" ]]; then\n'
        '    emit_dp_resume_post_complete_notice\n'
        '    exit 0\n'
        'fi\n'
        '\n',
        'resume_functions_insert',
    )
    return text


def apply_esdata_probe_ssh(text):
    anchor = (
        '        out=$(timeout 25 sshpass -p aelladata ssh \\\n'
        '                -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \\\n'
        '                -o ConnectTimeout=10 -o PreferredAuthentications=password \\\n'
    )
    if anchor not in text:
        return text
    return replace_exactly_once(
        text,
        anchor,
        '        init_phase2_ssh_known_hosts\n'
        '        if [[ -z "${PHASE2_WORKER_PASSWORD_FILE:-}" ]]; then echo "UNKNOWN"; return; fi\n'
        '        out=$(timeout 25 sshpass -f "$PHASE2_WORKER_PASSWORD_FILE" ssh \\\n'
        '                $SSH_OPTS \\\n'
        '                -o ConnectTimeout=10 -o PreferredAuthentications=password \\\n',
        'esdata_probe_ssh',
    )


TRANSFORMS = (
    ('usage_docs', apply_worker_password_docs),
    ('globals', apply_worker_password_globals),
    ('credential_ssh_helpers', apply_credential_ssh_helpers),
    ('ssh_host_keys', apply_ssh_host_keys),
    ('acps_credential_removal', apply_acps_credential_removal),
    ('acps_preflight_fail_closed', apply_acps_preflight_fail_closed),
    ('acps_download_fail_closed', apply_acps_download_fail_closed),
    ('parse_args', apply_parse_args_worker_password),
    ('compat_block', apply_compat_block),
    ('install_python3', apply_install_python3_gates),
    ('overlay2_password', apply_overlay2_worker_password),
    ('orchestrate_workers', apply_orchestrate_workers),
    ('esdata_probe_ssh', apply_esdata_probe_ssh),
    ('join_k8s_cluster', apply_join_k8s_cluster),
    ('main_gates', apply_main_orchestration_gates),
    ('image_import_heartbeat', apply_image_import_heartbeat),
    ('dp_resume_notices', apply_dp_resume_notices),
)


def patch_bringup_text(text, emit=True):
    """Apply every project-owned transform. Fail closed on any mismatch."""
    if not text:
        raise PatchCompatError('upstream', 'empty')
    applied = []
    for name, fn in TRANSFORMS:
        text = fn(text)
        applied.append(name)
        if emit:
            print('PATCH_TRANSFORM=%s result=PASS' % name)
    missing = [m for m in RESULT_MARKERS if m not in text]
    if missing:
        raise PatchCompatError(
            'result_markers',
            'missing=%s' % ','.join(missing),
        )
    if emit:
        print('BRINGUP_PATCH_RESULT=PASS')
    return text, applied


def patch_bringup_file(upstream_path, output_path):
    upstream = _read_text(upstream_path)
    upstream_sha = _sha1_text(upstream)
    generation = patch_generation_id()
    print('BRINGUP_PATCH_GENERATION=%s' % generation)
    print('BRINGUP_UPSTREAM_SHA1=%s' % upstream_sha)
    patched, applied = patch_bringup_text(upstream)
    patched_sha = _sha1_text(patched)
    if patched_sha == upstream_sha:
        raise PatchCompatError('generation', 'patched_sha_equals_upstream_sha')
    out_dir = os.path.dirname(os.path.abspath(output_path))
    if out_dir and not os.path.isdir(out_dir):
        os.makedirs(out_dir)
    tmp = output_path + '.new'
    with open(tmp, 'wb') as fh:
        fh.write(patched.encode('utf-8'))
    os.rename(tmp, output_path)
    print('PATCHED_BRINGUP_GENERATION=PASS')
    print('BRINGUP_PATCHED_SHA1=%s' % patched_sha)
    print('BRINGUP_PATCH_COMPAT=PASS')
    print('PATCH_TRANSFORM_COUNT=%d' % len(applied))
    return {
        'upstream_sha1': upstream_sha,
        'patched_sha1': patched_sha,
        'generation': generation,
        'applied': applied,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description='Apply project-owned Phase 2 bringup patches to a fresh ACPS upstream file.',
    )
    parser.add_argument('--print-generation', action='store_true',
                        help='Print BRINGUP_PATCH_GENERATION and exit')
    parser.add_argument('--validate', action='store_true',
                        help='Apply transforms in memory and report BRINGUP_PATCH_COMPAT')
    parser.add_argument('--upstream', help='Immutable ACPS upstream bringup path')
    parser.add_argument('--output', help='Generated patched bringup path')
    args = parser.parse_args(argv)

    generation = patch_generation_id()
    if args.print_generation:
        print('BRINGUP_PATCH_GENERATION=%s' % generation)
        return 0

    if args.validate:
        if not args.upstream:
            parser.error('--upstream is required with --validate')
        try:
            upstream = _read_text(args.upstream)
            upstream_sha = _sha1_text(upstream)
            print('BRINGUP_PATCH_GENERATION=%s' % generation)
            print('BRINGUP_UPSTREAM_SHA1=%s' % upstream_sha)
            patched, applied = patch_bringup_text(upstream)
            patched_sha = _sha1_text(patched)
            if patched_sha == upstream_sha:
                raise PatchCompatError('generation', 'patched_sha_equals_upstream_sha')
            print('PATCHED_BRINGUP_GENERATION=PASS')
            print('BRINGUP_PATCHED_SHA1=%s' % patched_sha)
            print('BRINGUP_PATCH_COMPAT=PASS')
            print('PATCH_TRANSFORM_COUNT=%d' % len(applied))
            return 0
        except PatchCompatError as exc:
            print('BRINGUP_PATCH_GENERATION=%s' % generation)
            print('BRINGUP_PATCH_COMPAT=FAIL')
            print('PATCHED_BRINGUP_GENERATION=FAIL')
            print('BRINGUP_PATCH_COMPAT_FAIL_TRANSFORM=%s' % exc.transform)
            print('BRINGUP_PATCH_COMPAT_FAIL_REASON=%s' % exc.reason)
            return 2
        except Exception as exc:
            print('BRINGUP_PATCH_GENERATION=%s' % generation)
            print('BRINGUP_PATCH_COMPAT=FAIL')
            print('PATCHED_BRINGUP_GENERATION=FAIL')
            print('BRINGUP_PATCH_COMPAT_FAIL_REASON=%s' % exc)
            return 1

    if not args.upstream or not args.output:
        parser.error('--upstream and --output are required unless --print-generation or --validate')

    upstream_abs = os.path.abspath(args.upstream)
    output_abs = os.path.abspath(args.output)
    if upstream_abs == output_abs:
        eprint('BRINGUP_PATCH_COMPAT=FAIL')
        eprint('PATCHED_BRINGUP_GENERATION=FAIL')
        eprint('BRINGUP_PATCH_COMPAT_FAIL_REASON=output_would_overwrite_upstream')
        return 2

    try:
        patch_bringup_file(args.upstream, args.output)
    except PatchCompatError as exc:
        print('BRINGUP_PATCH_GENERATION=%s' % generation)
        print('BRINGUP_PATCH_COMPAT=FAIL')
        print('PATCHED_BRINGUP_GENERATION=FAIL')
        print('BRINGUP_PATCH_COMPAT_FAIL_TRANSFORM=%s' % exc.transform)
        print('BRINGUP_PATCH_COMPAT_FAIL_REASON=%s' % exc.reason)
        return 2
    except Exception as exc:
        print('BRINGUP_PATCH_GENERATION=%s' % generation)
        print('BRINGUP_PATCH_COMPAT=FAIL')
        print('PATCHED_BRINGUP_GENERATION=FAIL')
        print('BRINGUP_PATCH_COMPAT_FAIL_REASON=%s' % exc)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
