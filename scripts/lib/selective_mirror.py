#!/usr/bin/env python3
"""Materialize, verify helpers, publish, and status for selective offline mirrors.

Uses discovery plan from build-selective-mirror-plan.py.
Layout: hop-separated snapshots + shared offline meta/upgraders.
Metadata via apt-ftparchive; signing via local GPG (not trusted=yes).

Python 3.5+; standard library only (invokes apt-ftparchive/gpg as subprocess).
"""
from __future__ import print_function, unicode_literals

import argparse
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from collections import OrderedDict, defaultdict

try:
    from urllib.parse import urlparse, unquote, urlunparse
    from urllib.request import Request, build_opener, HTTPRedirectHandler
    from urllib.error import HTTPError, URLError
except ImportError:  # pragma: no cover
    from urlparse import urlparse, urlunparse  # type: ignore
    from urllib import unquote  # type: ignore
    from urllib2 import (  # type: ignore
        Request, build_opener, HTTPRedirectHandler, HTTPError, URLError,
    )

ERROR_HTTP_404 = 'SELECTIVE_DOWNLOAD_HTTP_404'
ERROR_HTTP = 'SELECTIVE_DOWNLOAD_HTTP_ERROR'
ERROR_DOWNLOAD = 'SELECTIVE_DOWNLOAD_FAILED'
ERROR_EXACT_NOT_FOUND = 'SELECTIVE_DOWNLOAD_EXACT_FILE_NOT_FOUND'
ERROR_PREPUBLISH = 'SELECTIVE_PREPUBLISH_VERIFY_FAILED'
ERROR_POSTPUBLISH_NGINX = 'SELECTIVE_POSTPUBLISH_NGINX_CONFIG_FAILED'
ERROR_POSTPUBLISH_HTTP = 'SELECTIVE_POSTPUBLISH_HTTP_FAILED'
ERROR_PUBLISH_ROLLBACK = 'SELECTIVE_PUBLISH_ROLLBACK_FAILED'
ERROR_VERIFY_STALE = 'SELECTIVE_VERIFY_RESULT_STALE'
ERROR_STAGING_CHANGED = 'FAIL_STAGING_CHANGED_AFTER_VERIFY'
ERROR_STAGING_PROVENANCE = 'FAIL_SELECTIVE_STAGING_PROVENANCE_MISMATCH'
ERROR_STAGING_SCHEMA = 'FAIL_STAGING_SCHEMA_MISMATCH'
ERROR_NGINX_ROOT_MISMATCH = 'SELECTIVE_NGINX_EFFECTIVE_ROOT_MISMATCH'
ERROR_QUARANTINE = 'FAIL_STAGING_QUARANTINE_UNSAFE'
FAILED_DOWNLOADS_NAME = 'failed-downloads.json'
RESOLVED_DOWNLOADS_NAME = 'resolved-downloads.json'
VERIFY_RESULT_NAME = 'verify-result.json'
VERIFY_RESULT_LEGACY = 'verify.json'
PUBLISH_RESULT_NAME = 'publish-result.json'
PUBLISH_RESULT_LEGACY = 'publish.json'
# Layout contract shared by materializer / validator / publisher.
STAGING_SCHEMA_VERSION = 1
MATERIALIZER_SCHEMA = STAGING_SCHEMA_VERSION
VALIDATOR_SCHEMA = STAGING_SCHEMA_VERSION
PUBLISHER_SCHEMA = STAGING_SCHEMA_VERSION
KNOWN_COMPONENTS = ('main', 'restricted', 'universe', 'multiverse')
OFFICIAL_POOL_BASES = (
    'http://archive.ubuntu.com/ubuntu',
    'http://security.ubuntu.com/ubuntu',
    'http://old-releases.ubuntu.com/ubuntu',
)
# Bounded retry for transient network failures during materialize downloads.
DOWNLOAD_MAX_ATTEMPTS = 5
DOWNLOAD_RETRY_BASE_DELAY_SEC = 1.0
TRANSIENT_DOWNLOAD_EXCEPTION_NAMES = frozenset((
    'RemoteDisconnected',
    'TimeoutError',
    'BrokenPipeError',
    'ConnectionResetError',
    'IncompleteRead',
    'ConnectionAbortedError',
))
FORBIDDEN_QUARANTINE_PATHS = frozenset((
    '/', '/var', '/home', '/usr', '/etc', '/root', '/tmp', '/boot',
))


class SelectiveDownloadError(Exception):
    """Structured download failure for selective materialize."""

    def __init__(self, error_code, message, context=None):
        super(SelectiveDownloadError, self).__init__(message)
        self.error_code = error_code
        self.message = message
        self.context = OrderedDict(context or {})

    def to_dict(self):
        data = OrderedDict([
            ('generated_at', iso_now()),
            ('validation_result', 'FAIL'),
            ('error_code', self.error_code),
            ('exception_type', type(self).__name__),
            ('exception_message', self.message),
        ])
        data.update(self.context)
        return data


class SelectivePublishError(Exception):
    """Structured publish / post-publish failure."""

    def __init__(self, error_code, message, context=None):
        super(SelectivePublishError, self).__init__(message)
        self.error_code = error_code
        self.message = message
        self.context = OrderedDict(context or {})


class SelectiveProvenanceError(Exception):
    """Staging provenance mismatch — fail closed; do not auto-delete staging."""

    def __init__(self, error_code, message, mismatches=None, context=None):
        super(SelectiveProvenanceError, self).__init__(message)
        self.error_code = error_code
        self.message = message
        self.mismatches = list(mismatches or [])
        self.context = OrderedDict(context or {})


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def iso_now():
    return time.strftime('%Y-%m-%dT%H:%M:%S%z')


def normalize_url(url):
    if not url:
        return ''
    parsed = urlparse(url.strip())
    scheme = (parsed.scheme or 'http').lower()
    host = (parsed.hostname or '').lower()
    if host.startswith('www.'):
        host = host[4:]
    netloc = host
    if parsed.port:
        netloc = '%s:%d' % (host, parsed.port)
    path = unquote(parsed.path or '')
    while '//' in path:
        path = path.replace('//', '/')
    return urlunparse((scheme, netloc, path, '', '', ''))


def load_json(path):
    with open(path, 'r') as fh:
        return json.load(fh)


def write_json(path, data):
    """Atomic JSON write with fsync (receipts / state must survive crash)."""
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = path + '.tmp.%d' % os.getpid()
    with open(tmp, 'w') as fh:
        json.dump(data, fh, indent=2, sort_keys=False)
        fh.write('\n')
        fh.flush()
        try:
            os.fsync(fh.fileno())
        except OSError:
            pass
    os.replace(tmp, path)
    if parent:
        try:
            dirfd = os.open(parent, os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
            try:
                os.fsync(dirfd)
            finally:
                os.close(dirfd)
        except OSError:
            pass


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)


def safe_unlink(path):
    try:
        if path and os.path.lexists(path):
            os.unlink(path)
    except OSError:
        pass


def destination_matches(dst, expected_sha256=None, expected_size=None):
    """True when dst exists and matches expected size/SHA256 (when provided)."""
    if not os.path.isfile(dst):
        return False
    if expected_size is not None and int(expected_size) >= 0:
        try:
            if os.path.getsize(dst) != int(expected_size):
                return False
        except OSError:
            return False
    if expected_sha256:
        try:
            if file_sha256(dst) != expected_sha256.lower():
                return False
        except OSError:
            return False
    return True


def pool_component_from_path(rel_or_url):
    text = rel_or_url or ''
    marker = '/pool/'
    idx = text.find(marker)
    if idx < 0 and text.startswith('pool/'):
        parts = text.split('/')
        return parts[1] if len(parts) > 1 else ''
    if idx < 0:
        return ''
    rest = text[idx + len(marker):]
    return rest.split('/', 1)[0] if rest else ''


def rewrite_pool_component(rel_pool_path, new_component):
    """Rewrite pool/<component>/... keeping the remainder unchanged."""
    rel = (rel_pool_path or '').lstrip('/')
    if not rel.startswith('pool/') or not new_component:
        return ''
    parts = rel.split('/')
    if len(parts) < 3:
        return ''
    parts[1] = new_component
    return '/'.join(parts)


def candidate_correction_urls(original_url, relative_pool_path):
    """Yield alternate official URLs swapping only the pool component."""
    original_url = normalize_url(original_url or '')
    rel = (relative_pool_path or '').lstrip('/')
    if original_url and '/pool/' in original_url:
        parsed = urlparse(original_url)
        path = unquote(parsed.path or '')
        idx = path.find('/pool/')
        if idx >= 0:
            rel = path[idx + 1:].lstrip('/')
    if not rel.startswith('pool/'):
        return
    current = pool_component_from_path(rel)
    bases = []
    if original_url:
        parsed = urlparse(original_url)
        host = (parsed.hostname or '').lower()
        if host in (
            'archive.ubuntu.com', 'security.ubuntu.com', 'old-releases.ubuntu.com',
        ):
            netloc = host
            if parsed.port:
                netloc = '%s:%d' % (host, parsed.port)
            # Keep the /ubuntu prefix when present in the original path.
            prefix = '/ubuntu' if '/ubuntu/' in (parsed.path or '') else ''
            bases.append('%s://%s%s' % ((parsed.scheme or 'http'), netloc, prefix))
    for base in OFFICIAL_POOL_BASES:
        if base not in bases:
            bases.append(base)
    for component in KNOWN_COMPONENTS:
        if component == current:
            continue
        new_rel = rewrite_pool_component(rel, component)
        if not new_rel:
            continue
        for base in bases:
            yield component, new_rel, normalize_url('%s/%s' % (base.rstrip('/'), new_rel))


def append_resolved_download(selective_root, record):
    """Atomically append one resolution record to state/resolved-downloads.json."""
    state = os.path.join(selective_root, 'state')
    ensure_dir(state)
    path = os.path.join(state, RESOLVED_DOWNLOADS_NAME)
    existing = []
    if os.path.isfile(path):
        try:
            data = load_json(path)
            if isinstance(data, dict) and isinstance(data.get('resolutions'), list):
                existing = list(data['resolutions'])
            elif isinstance(data, list):
                existing = list(data)
        except (ValueError, OSError, TypeError):
            existing = []
    existing.append(OrderedDict(record))
    payload = OrderedDict([
        ('schema_version', 1),
        ('generated_at', iso_now()),
        ('resolution_count', len(existing)),
        ('resolutions', existing),
    ])
    write_json(path, payload)


def acquire_with_component_correction(
    src, dst, allow_download_url, expected_sha256, expected_size,
    entry_context, selective_root, relative_pool_path, deb,
):
    """Acquire file; on original URL HTTP 404 try exact component-path correction."""
    try:
        return acquire_file(
            src, dst,
            allow_download_url=allow_download_url,
            expected_sha256=expected_sha256,
            expected_size=expected_size,
            entry_context=entry_context,
        ), None
    except SelectiveDownloadError as err:
        if err.error_code != ERROR_HTTP_404 or not allow_download_url:
            raise
        host = (urlparse(normalize_url(allow_download_url)).hostname or '').lower()
        if host not in (
            'archive.ubuntu.com', 'security.ubuntu.com', 'old-releases.ubuntu.com',
        ):
            # Non-official hosts (unit-test servers): keep original 404 semantics.
            raise
        original_component = (
            deb.get('component')
            or pool_component_from_path(relative_pool_path)
            or pool_component_from_path(allow_download_url)
        )
        last_err = err
        for component, new_rel, candidate_url in candidate_correction_urls(
            allow_download_url, relative_pool_path,
        ):
            # Stage into the plan destination; path inside pool changes only after
            # exact verify. Keep dst as plan path for index consistency — the
            # downloaded bytes must match expected sha/size regardless of URL.
            corr_ctx = OrderedDict(entry_context or {})
            corr_ctx['original_url'] = allow_download_url
            corr_ctx['normalized_url'] = normalize_url(allow_download_url)
            corr_ctx['candidate_url'] = candidate_url
            corr_ctx['resolved_component'] = component
            try:
                method = acquire_file(
                    '', dst,
                    allow_download_url=candidate_url,
                    expected_sha256=expected_sha256,
                    expected_size=expected_size,
                    entry_context=corr_ctx,
                )
            except SelectiveDownloadError as cand_err:
                last_err = cand_err
                continue
            if not destination_matches(dst, expected_sha256, expected_size):
                safe_unlink(dst)
                continue
            # Reject identity mismatches — plan identity fields are immutable.
            if (deb.get('package') and corr_ctx.get('package')
                    and deb.get('package') != corr_ctx.get('package')):
                safe_unlink(dst)
                continue
            verified_sha = file_sha256(dst)
            verified_size = os.path.getsize(dst)
            resolution = OrderedDict([
                ('package', deb.get('package') or ''),
                ('version', deb.get('version') or ''),
                ('architecture', deb.get('architecture') or ''),
                ('filename', deb.get('filename') or os.path.basename(relative_pool_path or '')),
                ('expected_sha256', (expected_sha256 or '').lower()),
                ('verified_sha256', verified_sha),
                ('expected_size_bytes', int(expected_size or 0)),
                ('verified_size_bytes', int(verified_size)),
                ('original_url', allow_download_url),
                ('resolved_url', candidate_url),
                ('original_component', original_component),
                ('resolved_component', component),
                ('resolution_reason', 'ORIGINAL_URL_HTTP_404_COMPONENT_PATH_CORRECTION'),
                ('acquisition_source', 'official-exact-checksum-path-correction'),
                ('source_hops', list(deb.get('source_hops') or [])),
                ('resolved_at', iso_now()),
                ('plan_relative_pool_path', relative_pool_path),
                ('candidate_relative_pool_path', new_rel),
            ])
            append_resolved_download(selective_root, resolution)
            return method, resolution

        ctx = OrderedDict(entry_context or {})
        if last_err is not None:
            ctx.update(last_err.context or {})
        ctx['original_url'] = allow_download_url
        ctx['resolution_reason'] = 'ORIGINAL_URL_HTTP_404_NO_EXACT_COMPONENT_MATCH'
        raise SelectiveDownloadError(
            ERROR_EXACT_NOT_FOUND,
            'exact file not found after component path correction: %s'
            % (deb.get('package') or relative_pool_path),
            ctx,
        )


class _CaptureRedirects(HTTPRedirectHandler):
    def __init__(self):
        HTTPRedirectHandler.__init__(self)
        self.chain = []

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self.chain.append(OrderedDict([
            ('status', int(code)),
            ('url', newurl),
        ]))
        return HTTPRedirectHandler.redirect_request(
            self, req, fp, code, msg, headers, newurl,
        )


def _http_error_code(status):
    if status == 404:
        return ERROR_HTTP_404
    return ERROR_HTTP


def _is_transient_download_exc(exc):
    """True for network faults safe to retry (RemoteDisconnected, resets, …)."""
    cur = exc
    seen = 0
    while cur is not None and seen < 6:
        name = type(cur).__name__
        if name in TRANSIENT_DOWNLOAD_EXCEPTION_NAMES:
            return True
        msg = str(cur).lower()
        if (
            'remote end closed' in msg
            or 'connection reset' in msg
            or 'temporarily unavailable' in msg
            or 'timed out' in msg
            or 'timeout' in msg
        ):
            return True
        if isinstance(cur, URLError):
            reason = getattr(cur, 'reason', None)
            if reason is not None and reason is not cur:
                cur = reason
                seen += 1
                continue
        cur = getattr(cur, '__cause__', None) or getattr(cur, 'reason', None)
        seen += 1
    return False


def download_url_to_path(url, tmp_path, entry_context=None,
                         max_attempts=DOWNLOAD_MAX_ATTEMPTS):
    """Download url to tmp_path. Raises SelectiveDownloadError on failure.

    Transient network errors are retried with exponential backoff.
    Cleans tmp_path on failure. Never touches the final destination.
    Partial HTTP range resume is not used (not universally safe).
    """
    ctx = OrderedDict(entry_context or {})
    original_url = ctx.get('original_url') or url
    # The url argument is authoritative for this attempt (correction retries).
    normalized = normalize_url(url)
    ctx.setdefault('original_url', original_url)
    ctx['normalized_url'] = normalized
    ctx['resolved_url'] = normalized
    ctx['redirect_chain'] = []
    ctx['http_status'] = None
    attempts = max(1, int(max_attempts or 1))
    transient_retries = 0
    last_exc = None

    for attempt in range(1, attempts + 1):
        safe_unlink(tmp_path)
        ensure_dir(os.path.dirname(tmp_path))
        tracker = _CaptureRedirects()
        opener = build_opener(tracker)
        request = Request(normalized or url, headers={
            'User-Agent': 'ubuntu-mirror-automation-selective/1.0',
        })
        try:
            response = opener.open(request, timeout=120)
            try:
                final_url = (
                    response.geturl() if hasattr(response, 'geturl') else normalized
                )
                status = getattr(response, 'status', None)
                if status is None and hasattr(response, 'code'):
                    status = response.code
                ctx['http_status'] = int(status) if status is not None else 200
                ctx['resolved_url'] = final_url or normalized
                ctx['redirect_chain'] = list(tracker.chain)
                with open(tmp_path, 'wb') as fh:
                    shutil.copyfileobj(response, fh)
            finally:
                try:
                    response.close()
                except Exception:
                    pass
            ctx['download_attempts'] = attempt
            ctx['transient_retry_count'] = transient_retries
            return ctx
        except HTTPError as exc:
            safe_unlink(tmp_path)
            status = int(getattr(exc, 'code', 0) or 0)
            final_url = ''
            try:
                final_url = exc.geturl() if hasattr(exc, 'geturl') else ''
            except Exception:
                final_url = ''
            ctx['http_status'] = status
            ctx['resolved_url'] = final_url or normalized or url
            ctx['redirect_chain'] = list(tracker.chain)
            ctx['exception_type'] = type(exc).__name__
            ctx['exception_message'] = str(exc)
            # 5xx is transient; 4xx is not.
            if status >= 500 and attempt < attempts:
                transient_retries += 1
                last_exc = exc
                time.sleep(DOWNLOAD_RETRY_BASE_DELAY_SEC * (2 ** (attempt - 1)))
                continue
            ctx['download_attempts'] = attempt
            ctx['transient_retry_count'] = transient_retries
            raise SelectiveDownloadError(
                _http_error_code(status),
                'HTTP %s downloading %s' % (status, ctx['resolved_url']),
                ctx,
            )
        except URLError as exc:
            safe_unlink(tmp_path)
            reason = getattr(exc, 'reason', exc)
            ctx['http_status'] = None
            ctx['resolved_url'] = normalized or url
            ctx['redirect_chain'] = list(tracker.chain)
            ctx['exception_type'] = type(exc).__name__
            ctx['exception_message'] = str(reason)
            if _is_transient_download_exc(exc) and attempt < attempts:
                transient_retries += 1
                last_exc = exc
                time.sleep(DOWNLOAD_RETRY_BASE_DELAY_SEC * (2 ** (attempt - 1)))
                continue
            ctx['download_attempts'] = attempt
            ctx['transient_retry_count'] = transient_retries
            raise SelectiveDownloadError(
                ERROR_DOWNLOAD,
                'URL error downloading %s: %s' % (ctx['resolved_url'], reason),
                ctx,
            )
        except SelectiveDownloadError:
            raise
        except Exception as exc:
            safe_unlink(tmp_path)
            ctx['http_status'] = ctx.get('http_status')
            ctx['resolved_url'] = ctx.get('resolved_url') or normalized or url
            ctx['redirect_chain'] = list(tracker.chain)
            ctx['exception_type'] = type(exc).__name__
            ctx['exception_message'] = str(exc)
            if _is_transient_download_exc(exc) and attempt < attempts:
                transient_retries += 1
                last_exc = exc
                time.sleep(DOWNLOAD_RETRY_BASE_DELAY_SEC * (2 ** (attempt - 1)))
                continue
            ctx['download_attempts'] = attempt
            ctx['transient_retry_count'] = transient_retries
            raise SelectiveDownloadError(
                ERROR_DOWNLOAD,
                'download failed for %s: %s' % (ctx['resolved_url'], exc),
                ctx,
            )

    ctx['download_attempts'] = attempts
    ctx['transient_retry_count'] = transient_retries
    raise SelectiveDownloadError(
        ERROR_DOWNLOAD,
        'download failed after %s attempts for %s: %s'
        % (attempts, ctx.get('resolved_url') or url, last_exc),
        ctx,
    )


def acquire_file(
    src, dst, allow_download_url=None,
    expected_sha256=None, expected_size=None, entry_context=None,
):
    """Place dst using hardlink → reflink → copy → download.

    If dst already exists with matching size+SHA256, skip download ('exists').
    Partial *.download temps are removed on failure; matching destinations
    are never deleted.
    """
    ensure_dir(os.path.dirname(dst))
    tmp = dst + '.download'

    if os.path.isfile(dst):
        if expected_sha256 or expected_size is not None:
            if destination_matches(dst, expected_sha256, expected_size):
                return 'exists'
            # Mismatch: leave dst in place until a verified replacement is ready.
        else:
            return 'exists'

    if src and os.path.isfile(src):
        # Prefer direct link/copy when destination is absent.
        if not os.path.isfile(dst):
            try:
                os.link(src, dst)
                return 'hardlink'
            except OSError:
                pass
            try:
                subprocess.check_call(
                    ['cp', '--reflink=auto', src, dst],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                return 'reflink'
            except (OSError, subprocess.CalledProcessError):
                pass
            shutil.copy2(src, dst)
            return 'copy'
        # Destination exists but failed checksum match: stage via temp.
        safe_unlink(tmp)
        try:
            try:
                os.link(src, tmp)
                method = 'hardlink'
            except OSError:
                try:
                    subprocess.check_call(
                        ['cp', '--reflink=auto', src, tmp],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    )
                    method = 'reflink'
                except (OSError, subprocess.CalledProcessError):
                    shutil.copy2(src, tmp)
                    method = 'copy'
            if expected_sha256 or expected_size is not None:
                if not destination_matches(tmp, expected_sha256, expected_size):
                    safe_unlink(tmp)
                    raise IOError('seed content mismatch for %s' % dst)
            os.replace(tmp, dst)
            return method
        except Exception:
            safe_unlink(tmp)
            raise

    if allow_download_url:
        ctx = OrderedDict(entry_context or {})
        ctx.setdefault('destination_path', dst)
        ctx.setdefault('original_url', allow_download_url)
        # Always fetch allow_download_url (component-path correction retries).
        ctx['attempt_url'] = allow_download_url
        ctx['normalized_url'] = normalize_url(allow_download_url)
        try:
            dl_ctx = download_url_to_path(
                allow_download_url, tmp, entry_context=ctx,
            )
            if isinstance(dl_ctx, dict):
                ctx.update(dl_ctx)
                if entry_context is not None:
                    entry_context['transient_retry_count'] = dl_ctx.get(
                        'transient_retry_count', 0,
                    )
                    entry_context['download_attempts'] = dl_ctx.get(
                        'download_attempts', 1,
                    )
            if expected_sha256 or expected_size is not None:
                if not destination_matches(tmp, expected_sha256, expected_size):
                    safe_unlink(tmp)
                    ctx['exception_type'] = 'ChecksumError'
                    ctx['exception_message'] = 'downloaded content checksum/size mismatch'
                    raise SelectiveDownloadError(
                        ERROR_DOWNLOAD,
                        'checksum/size mismatch after download: %s' % dst,
                        ctx,
                    )
            os.replace(tmp, dst)
            return 'downloaded'
        except SelectiveDownloadError as err:
            if entry_context is not None and err.context:
                entry_context['transient_retry_count'] = err.context.get(
                    'transient_retry_count', 0,
                )
            safe_unlink(tmp)
            raise
        except Exception as exc:
            safe_unlink(tmp)
            ctx['exception_type'] = type(exc).__name__
            ctx['exception_message'] = str(exc)
            raise SelectiveDownloadError(
                ERROR_DOWNLOAD,
                'download failed for %s: %s' % (dst, exc),
                ctx,
            )

    raise IOError('cannot acquire %s (no seed, no url)' % dst)


def print_download_error(err):
    """Print a concise structured failure summary to stderr (no traceback)."""
    ctx = err.context or {}
    lines = [
        'error_code=%s' % err.error_code,
        'plan_entry_index=%s' % ctx.get('plan_entry_index', ''),
        'hop=%s' % ctx.get('hop', ''),
        'package=%s' % ctx.get('package', ''),
        'version=%s' % ctx.get('version', ''),
        'architecture=%s' % ctx.get('architecture', ''),
        'expected_sha256=%s' % ctx.get('expected_sha256', ''),
        'expected_size_bytes=%s' % ctx.get('expected_size_bytes', ''),
        'original_url=%s' % ctx.get('original_url', ''),
        'normalized_url=%s' % ctx.get('normalized_url', ''),
        'destination_path=%s' % ctx.get('destination_path', ''),
        'http_status=%s' % (
            '' if ctx.get('http_status') is None else ctx.get('http_status')
        ),
        'exception_type=%s' % (
            ctx.get('exception_type') or type(err).__name__
        ),
        'exception_message=%s' % (
            ctx.get('exception_message') or err.message
        ),
        'resolved_url=%s' % ctx.get('resolved_url', ''),
    ]
    chain = ctx.get('redirect_chain') or []
    if chain:
        lines.append('redirect_chain=%s' % json.dumps(chain))
    else:
        lines.append('redirect_chain=[]')
    eprint('SELECTIVE_MATERIALIZE_FAIL')
    for line in lines:
        eprint(line)


def write_failed_downloads(selective_root, err, succeeded_count, remaining_count):
    state_dir = os.path.join(selective_root, 'state')
    ensure_dir(state_dir)
    payload = err.to_dict()
    payload['succeeded_file_count'] = int(succeeded_count)
    payload['remaining_file_count'] = int(remaining_count)
    path = os.path.join(state_dir, FAILED_DOWNLOADS_NAME)
    write_json(path, payload)
    return path


def clear_failed_downloads(selective_root):
    safe_unlink(os.path.join(selective_root, 'state', FAILED_DOWNLOADS_NAME))


def cleanup_partial_downloads(root):
    """Remove only *.download temps under root; never touch completed files."""
    if not root or not os.path.isdir(root):
        return 0
    removed = 0
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if name.endswith('.download'):
                safe_unlink(os.path.join(dirpath, name))
                removed += 1
    return removed


# Location/identity fields that may be rewritten for the selective pool layout.
PACKAGES_LOCATION_FIELDS = frozenset((
    'Filename', 'Size', 'SHA256', 'MD5sum', 'SHA1', 'SHA512',
))
# Relationship / policy fields that must never be dropped or normalized.
PACKAGES_RELATIONSHIP_FIELDS = frozenset((
    'Depends', 'Pre-Depends', 'Recommends', 'Suggests', 'Enhances',
    'Breaks', 'Conflicts', 'Replaces', 'Provides', 'Essential',
    'Multi-Arch', 'Built-Using', 'Protected', 'Important',
))


def parse_control_text(text):
    """Parse an RFC822 control/Packages stanza into an OrderedDict.

    Multi-line values keep their leading continuation whitespace so that
    Description and similar fields round-trip byte-identically when rewritten.
    """
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


def parse_deb_control(deb_path):
    """Return *all* binary control fields from a .deb (verbatim order).

    Prefer `dpkg-deb -I <deb> control` so Depends/Pre-Depends/Essential/Multi-Arch
    and every other control field are preserved. Falling back to a field-limited
    `dpkg-deb -f` extract is forbidden — that path previously dropped dependency
    metadata and broke APT Immediate-Configure ordering (libc-bin before libc6).
    """
    try:
        out = subprocess.check_output(
            ['dpkg-deb', '-I', deb_path, 'control'],
            stderr=subprocess.DEVNULL,
        ).decode('utf-8', 'replace')
    except subprocess.CalledProcessError:
        # Extremely old dpkg without -I control; still request *no* field filter.
        out = subprocess.check_output(
            ['dpkg-deb', '-f', deb_path],
            stderr=subprocess.DEVNULL,
        ).decode('utf-8', 'replace')
    return parse_control_text(out)


def iter_packages_stanzas(text):
    """Yield OrderedDict stanzas from a Packages index body."""
    chunks = text.split('\n\n')
    for chunk in chunks:
        chunk = chunk.strip('\n')
        if not chunk.strip():
            continue
        fields = parse_control_text(chunk)
        if fields.get('Package'):
            yield fields


def load_original_packages_indexes(index_roots):
    """Load original repository Packages stanzas keyed by (pkg, ver, arch).

    Later roots do not override an earlier hit so the first matching original
    index wins (discovery pocket-indexes before any optional overrides).
    """
    index = {}
    for root in index_roots or []:
        if not root or not os.path.isdir(root):
            continue
        for dirpath, _dns, filenames in os.walk(root):
            for fn in filenames:
                if fn != 'Packages' and fn != 'Packages.gz':
                    continue
                path = os.path.join(dirpath, fn)
                try:
                    if fn.endswith('.gz'):
                        with gzip.open(path, 'rt', errors='replace') as fh:
                            body = fh.read()
                    else:
                        with open(path, 'r', errors='replace') as fh:
                            body = fh.read()
                except (OSError, IOError, UnicodeError):
                    continue
                for stanza in iter_packages_stanzas(body):
                    key = (
                        stanza.get('Package', ''),
                        stanza.get('Version', ''),
                        stanza.get('Architecture', ''),
                    )
                    if key[0] and key not in index:
                        index[key] = stanza
    return index


def default_original_packages_index_roots():
    """Discovery pocket-indexes + optional env override roots."""
    roots = []
    env = os.environ.get('SELECTIVE_ORIGINAL_PACKAGES_ROOTS') or ''
    for part in env.split(':'):
        part = part.strip()
        if part:
            roots.append(part)
    # Repo-relative discovery snapshot (Canonical Packages stanzas).
    here = os.path.dirname(os.path.abspath(__file__))
    project = os.path.abspath(os.path.join(here, '..', '..'))
    pocket = os.path.join(
        project, 'artifacts', 'upgrade-discovery', 'analysis',
        'pocket-indexes', 'ubuntu',
    )
    if os.path.isdir(pocket):
        roots.append(pocket)
    return roots


def stanza_for_deb(deb, local_path, original_index=None, deb_control=None):
    """Return full binary metadata for a deb, preferring original Packages.

    Original repository stanzas are preserved verbatim except location fields.
    When no original stanza exists, fall back to the complete .deb control.
    """
    pkg = deb.get('package') or ''
    ver = deb.get('version') or ''
    arch = deb.get('architecture') or 'amd64'
    orig = None
    if original_index:
        orig = original_index.get((pkg, ver, arch))
        if orig is None and arch:
            # Some indexes omit Architecture on arch:all — try empty arch key.
            orig = original_index.get((pkg, ver, 'all'))
    if orig:
        return OrderedDict(orig), 'original_packages'
    if deb_control is not None:
        return OrderedDict(deb_control), 'deb_control'
    return parse_deb_control(local_path), 'deb_control'


def write_packages_stanza(fh, fields, filename, size, sha256):
    """Write a Packages stanza preserving all non-location metadata.

    Only Filename / Size / SHA256 (and hash siblings when already present) are
    safely rewritten for the selective pool. Dependency relationship fields are
    never dropped or renormalized.
    """
    out = OrderedDict(fields)
    # Strip location fields first, then append the selective-pool values in
    # canonical trailing order so APT sees a consistent layout.
    for key in list(out.keys()):
        if key in PACKAGES_LOCATION_FIELDS:
            del out[key]
    out['Filename'] = filename
    out['Size'] = str(int(size))
    out['SHA256'] = sha256
    for key, value in out.items():
        if value is None:
            continue
        text = value if isinstance(value, str) else str(value)
        # Multi-line values already contain "\\n "-continuations from parse.
        if '\n' in text:
            first, rest = text.split('\n', 1)
            fh.write('%s: %s\n' % (key, first))
            fh.write(rest + '\n')
        else:
            fh.write('%s: %s\n' % (key, text))
    fh.write('\n')


def series_from_suite(suite):
    """Return Ubuntu series codename for a suite/pocket name."""
    suite = suite or ''
    for suffix in ('-updates', '-security', '-backports', '-proposed'):
        if suite.endswith(suffix):
            return suite[: -len(suffix)]
    return suite


def pocket_from_suite(suite):
    """Return pocket name for a suite (base/updates/security/backports)."""
    suite = suite or ''
    if suite.endswith('-updates'):
        return 'updates'
    if suite.endswith('-security'):
        return 'security'
    if suite.endswith('-backports'):
        return 'backports'
    return 'base'


def hop_series_pair(hop):
    parts = (hop or '').split('-to-')
    if len(parts) != 2:
        return '', ''
    return parts[0], parts[1]


def suite_for_hop_deb(deb, hop=''):
    """Return the suite this deb should be indexed under for ``hop``.

    Per-hop provenance wins so a SHA-deduplicated plan object can still carry
    distinct pockets (bionic vs focal-updates) for each source_hop. Legacy
    plans without hop_provenance fall back to original_suite.
    """
    prov = deb.get('hop_provenance') or {}
    if hop and isinstance(prov, dict) and hop in prov:
        entry = prov.get(hop) or {}
        if isinstance(entry, dict):
            suite = (entry.get('suite') or '').strip()
            if suite:
                return suite
        elif entry:
            return str(entry).strip()
    return (deb.get('original_suite') or '').strip()


def debs_for_suite_index(debs_for_hop, suite, from_series='', to_series='',
                         hop=''):
    """Select debs that may appear in a suite Packages index.

    Discovery payloads for a hop are *target-release* packages. They must be
    indexed under the exact target pocket suite recorded as original_suite
    (bionic / bionic-updates / bionic-security / bionic-backports). Source-series
    suites (xenial*, …) are source-stabilization indexes and must never list
    target package versions — empty Packages is correct when discovery has no
    genuine source-series payloads.

    Blank original_suite is never auto-assigned to the base target suite; such
    debs are omitted here and must be rejected at plan time (UNRESOLVED_TARGET_POCKET).
    """
    suite_series = series_from_suite(suite)
    if from_series and suite_series == from_series:
        # Source stabilization: never publish target discovery payloads here.
        return []
    out = []
    for deb in debs_for_hop:
        orig = suite_for_hop_deb(deb, hop)
        if not orig:
            # Fail-closed at plan/publish; do not clone into every target suite.
            continue
        if orig == suite:
            out.append(deb)
            continue
        # Legacy single-suite unit fixtures without series hints: allow match by
        # series only when from/to are unset and original_suite has no pocket.
        if not from_series and not to_series and series_from_suite(orig) == suite_series:
            if orig == suite or (pocket_from_suite(orig) == 'base' and suite == suite_series):
                out.append(deb)
    return out


def generate_packages_for_hop(ubuntu_root, debs_for_hop, suites, arch='amd64',
                              from_series='', to_series='', hop='',
                              original_index_roots=None):
    """Generate Packages(+gz) preserving full original binary metadata.

    Suite indexes are series-scoped: source suites never list target packages.
    Stanza policy (fail-closed for dependency fidelity):
      1. Prefer the original repository Packages stanza (discovery pocket-indexes
         / SELECTIVE_ORIGINAL_PACKAGES_ROOTS) keyed by Package+Version+Arch.
      2. Otherwise use the complete .deb control (`dpkg-deb -I control`).
      3. Rewrite only Filename / Size / SHA256 (location fields). Never drop or
         renormalize Depends / Pre-Depends / Breaks / Conflicts / Essential /
         Multi-Arch or other relationship fields.
    apt-ftparchive is used for Release metadata when available.
    """
    if not from_series or not to_series:
        inferred_from, inferred_to = hop_series_pair(hop)
        from_series = from_series or inferred_from
        to_series = to_series or inferred_to

    use_ftparchive = shutil.which('apt-ftparchive') is not None
    generated = []
    # Default components when a suite has no packages (empty source indexes).
    default_components = sorted({
        (d.get('component') or 'main') for d in debs_for_hop
    }) or ['main']

    if original_index_roots is None:
        original_index_roots = default_original_packages_index_roots()
    original_index = load_original_packages_indexes(original_index_roots)
    stanza_sources = {'original_packages': 0, 'deb_control': 0}

    for suite in suites:
        suite_debs = debs_for_suite_index(
            debs_for_hop, suite, from_series=from_series, to_series=to_series,
            hop=hop,
        )
        by_component = defaultdict(list)
        for deb in suite_debs:
            by_component[deb.get('component') or 'main'].append(deb)
        components_present = sorted(by_component.keys()) or list(default_components)

        for component in components_present:
            items = by_component.get(component) or []
            binary = os.path.join(
                ubuntu_root, 'dists', suite, component, 'binary-%s' % arch,
            )
            ensure_dir(binary)
            packages_path = os.path.join(binary, 'Packages')
            with open(packages_path, 'w') as fh:
                for deb in sorted(items, key=lambda d: (d['package'], d['version'])):
                    local = os.path.join(ubuntu_root, deb['relative_pool_path'])
                    if not os.path.isfile(local):
                        raise IOError('missing deb for Packages: %s' % local)
                    deb_ctrl = parse_deb_control(local)
                    fields, source = stanza_for_deb(
                        deb, local, original_index, deb_control=deb_ctrl,
                    )
                    stanza_sources[source] = stanza_sources.get(source, 0) + 1
                    # Guard: relationship fields present on the .deb must survive
                    # even when an original stanza is incomplete.
                    for rel_key in PACKAGES_RELATIONSHIP_FIELDS:
                        if rel_key in deb_ctrl and rel_key not in fields:
                            fields[rel_key] = deb_ctrl[rel_key]
                    write_packages_stanza(
                        fh, fields, deb['relative_pool_path'],
                        int(deb['size_bytes']), deb['sha256'],
                    )
            # gzip
            with open(packages_path, 'rb') as raw, gzip.open(packages_path + '.gz', 'wb') as gz:
                shutil.copyfileobj(raw, gz)
            generated.append(packages_path)

        # Release via apt-ftparchive or minimal hand-written
        release_path = os.path.join(ubuntu_root, 'dists', suite, 'Release')
        ensure_dir(os.path.dirname(release_path))
        suite_series = series_from_suite(suite)
        role = 'source-stabilization' if suite_series == from_series else (
            'target-upgrade' if suite_series == to_series else 'hop-snapshot'
        )
        description = 'Selective offline %s suite (%s)' % (role, suite)
        if use_ftparchive:
            conf = tempfile.NamedTemporaryFile('w', delete=False, prefix='aft-')
            try:
                conf.write('APT::FTPArchive::Release::Origin "Ubuntu-Selective";\n')
                conf.write('APT::FTPArchive::Release::Label "Ubuntu-Selective";\n')
                conf.write('APT::FTPArchive::Release::Suite "%s";\n' % suite)
                conf.write('APT::FTPArchive::Release::Codename "%s";\n' % suite_series)
                conf.write('APT::FTPArchive::Release::Architectures "%s";\n' % arch)
                conf.write('APT::FTPArchive::Release::Components "%s";\n' % ' '.join(components_present))
                conf.write('APT::FTPArchive::Release::Description "%s";\n' % description)
                conf.write('APT::FTPArchive::Release::Acquire-By-Hash "no";\n')
                conf.flush()
                conf.close()
                body = subprocess.check_output(
                    ['apt-ftparchive', '-c', conf.name, 'release',
                     os.path.join(ubuntu_root, 'dists', suite)],
                ).decode('utf-8', 'replace')
                lines = []
                saw_by_hash = False
                for line in body.splitlines():
                    if line.startswith('Acquire-By-Hash:'):
                        lines.append('Acquire-By-Hash: no')
                        saw_by_hash = True
                    else:
                        lines.append(line)
                if not saw_by_hash:
                    # Insert after Suite/Codename block header fields
                    insert_at = 0
                    for i, line in enumerate(lines):
                        if line.startswith('Description:'):
                            insert_at = i + 1
                            break
                    lines.insert(insert_at or len(lines), 'Acquire-By-Hash: no')
                with open(release_path, 'w') as fh:
                    fh.write('\n'.join(lines) + '\n')
            finally:
                try:
                    os.unlink(conf.name)
                except OSError:
                    pass
        else:
            # minimal Release + checksums
            files = []
            for component in components_present:
                for name in ('Packages', 'Packages.gz'):
                    rel = '%s/binary-%s/%s' % (component, arch, name)
                    path = os.path.join(ubuntu_root, 'dists', suite, rel)
                    if os.path.isfile(path):
                        files.append((rel, path))
            with open(release_path, 'w') as fh:
                fh.write('Origin: Ubuntu-Selective\n')
                fh.write('Label: Ubuntu-Selective\n')
                fh.write('Suite: %s\n' % suite)
                fh.write('Codename: %s\n' % suite_series)
                fh.write('Architectures: %s\n' % arch)
                fh.write('Components: %s\n' % ' '.join(components_present))
                fh.write('Description: %s\n' % description)
                fh.write('Acquire-By-Hash: no\n')
                fh.write('SHA256:\n')
                for rel, path in files:
                    digest = file_sha256(path)
                    size = os.path.getsize(path)
                    fh.write(' %s %16d %s\n' % (digest, size, rel))
        generated.append(release_path)
    eprint(
        'PACKAGES_STANZA_SOURCES original_packages=%s deb_control=%s'
        % (
            stanza_sources.get('original_packages', 0),
            stanza_sources.get('deb_control', 0),
        )
    )
    return generated


def ensure_signing_key(keys_dir, key_name='ubuntu-mirror-selective'):
    ensure_dir(keys_dir)
    priv = os.path.join(keys_dir, '%s.private.gpg' % key_name)
    pub = os.path.join(keys_dir, '%s.gpg' % key_name)
    if os.path.isfile(priv) and os.path.isfile(pub):
        return priv, pub
    if not shutil.which('gpg'):
        raise RuntimeError('gpg required for local signing')
    homedir = os.path.join(keys_dir, 'gnupg')
    ensure_dir(homedir)
    os.chmod(homedir, 0o700)
    batch = os.path.join(keys_dir, 'keybatch')
    with open(batch, 'w') as fh:
        fh.write('%no-protection\n')
        fh.write('Key-Type: RSA\n')
        fh.write('Key-Length: 2048\n')
        fh.write('Name-Real: Ubuntu Selective Mirror\n')
        fh.write('Name-Email: selective-mirror@local\n')
        fh.write('Expire-Date: 0\n')
        fh.write('%%commit\n')
    subprocess.check_call([
        'gpg', '--homedir', homedir, '--batch', '--gen-key', batch,
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.check_call([
        'gpg', '--homedir', homedir, '--export', '-a',
        'selective-mirror@local',
    ], stdout=open(pub, 'w'))
    subprocess.check_call([
        'gpg', '--homedir', homedir, '--export-secret-keys', '-a',
        'selective-mirror@local',
    ], stdout=open(priv, 'w'))
    os.chmod(priv, 0o600)
    return priv, pub


def sign_release(release_path, keys_dir, key_name='ubuntu-mirror-selective'):
    priv, pub = ensure_signing_key(keys_dir, key_name)
    homedir = os.path.join(keys_dir, 'gnupg')
    inrelease = os.path.join(os.path.dirname(release_path), 'InRelease')
    release_gpg = release_path + '.gpg'
    subprocess.check_call([
        'gpg', '--homedir', homedir, '--batch', '--yes',
        '--clearsign', '-o', inrelease, release_path,
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.check_call([
        'gpg', '--homedir', homedir, '--batch', '--yes',
        '-b', '-o', release_gpg, release_path,
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return inrelease, release_gpg, pub


def _acquisition_entries(plan, hop=None):
    """Build ordered list of deb acquisition entries with plan entry index.

    When hop is set, only that hop is included (official hop selector).
    """
    hop_summaries = plan.get('hop_summaries') or {}
    debs = plan.get('debs') or []
    hops = plan.get('hops') or list(hop_summaries.keys())
    entries = []
    idx = 0
    for hop_name in hops:
        if hop and hop_name != hop:
            continue
        if hop_name not in hop_summaries:
            continue
        hop_debs = [d for d in debs if hop_name in (d.get('source_hops') or [])]
        for deb in hop_debs:
            entries.append((idx, hop_name, deb))
            idx += 1
    return entries


def resolve_verified_reuse_source(
    selective_root, hop_name, relative_pool_path,
    expected_sha256=None, expected_size=None, extra_reuse_roots=None,
):
    """Return a local path with matching SHA256/size, or ''.

    Never moves published files; caller may hardlink/copy after re-verify.
    Partial *.download / *.part files are never considered.
    """
    rel = (relative_pool_path or '').lstrip('/')
    if not rel or not selective_root:
        return ''
    candidates = []
    if hop_name:
        candidates.append(os.path.join(
            selective_root, 'published', 'hops', hop_name, 'ubuntu', rel,
        ))
    for root in extra_reuse_roots or []:
        if not root:
            continue
        if hop_name:
            candidates.append(os.path.join(root, 'hops', hop_name, 'ubuntu', rel))
            candidates.append(os.path.join(root, 'ubuntu', rel))
        candidates.append(os.path.join(root, rel))
    for path in candidates:
        base = os.path.basename(path)
        if base.endswith('.download') or base.endswith('.part'):
            continue
        if destination_matches(path, expected_sha256, expected_size):
            return path
    return ''


def evaluate_staging_reuse(plan_path, selective_root, hop=None, sample_limit=32):
    """Decide whether a completed staging tree can be reused without re-download.

    Returns:
      (True, detail)  — safe to reuse (MATERIALIZE_REUSED)
      (False, detail) — incomplete / no receipt → caller should materialize

    Raises:
      SelectiveProvenanceError — hard mismatch (fail closed; never auto-delete)
    """
    plan = load_json(plan_path)
    state_dir = os.path.join(selective_root, 'state')
    staging = os.path.join(selective_root, 'staging')
    mat_path = os.path.join(state_dir, 'materialize.json')
    detail = OrderedDict([
        ('staging_root', staging),
        ('materialize_receipt', mat_path),
        ('hop', hop or ''),
        ('mismatches', []),
    ])

    if not os.path.isfile(mat_path):
        detail['reason'] = 'NO_MATERIALIZE_RECEIPT'
        return False, detail
    if not os.path.isdir(staging):
        detail['reason'] = 'STAGING_MISSING'
        return False, detail

    mat = load_json(mat_path)
    mismatches = []

    plan_ck = plan.get('plan_checksum') or ''
    mat_ck = mat.get('plan_checksum') or ''
    if plan_ck and mat_ck and plan_ck != mat_ck:
        mismatches.append(OrderedDict([
            ('field', 'plan_checksum'),
            ('expected', plan_ck),
            ('actual', mat_ck),
        ]))

    disc = plan.get('discovery_artifact_checksum') or ''
    mat_disc = mat.get('discovery_artifact_checksum') or ''
    if disc and mat_disc and disc != mat_disc:
        mismatches.append(OrderedDict([
            ('field', 'discovery_artifact_checksum'),
            ('expected', disc),
            ('actual', mat_disc),
        ]))

    prof = plan.get('profile_name') or ''
    mat_prof = mat.get('profile_name') or ''
    if prof and mat_prof and prof != mat_prof:
        mismatches.append(OrderedDict([
            ('field', 'profile_name'),
            ('expected', prof),
            ('actual', mat_prof),
        ]))

    mat_schema = mat.get('staging_schema_version')
    if mat_schema is None:
        # Legacy receipts predate explicit schema; treat as version 1 only when
        # layout fields otherwise match. Missing schema on PASS reuse is OK if
        # equal to current; mismatch against a future version fails closed.
        mat_schema = 1
    if int(mat_schema) != int(STAGING_SCHEMA_VERSION):
        mismatches.append(OrderedDict([
            ('field', 'staging_schema_version'),
            ('expected', STAGING_SCHEMA_VERSION),
            ('actual', mat_schema),
        ]))
        detail['mismatches'] = mismatches
        detail['reason'] = 'STAGING_SCHEMA_MISMATCH'
        raise SelectiveProvenanceError(
            ERROR_STAGING_SCHEMA,
            'staging schema mismatch — refuse reuse and refuse auto-delete',
            mismatches=mismatches,
            context=detail,
        )

    mat_staging = mat.get('staging_root') or ''
    if mat_staging and os.path.realpath(mat_staging) != os.path.realpath(staging):
        mismatches.append(OrderedDict([
            ('field', 'staging_root'),
            ('expected', staging),
            ('actual', mat_staging),
        ]))

    # Hard provenance mismatches: never auto-delete; never resume as-is.
    if mismatches:
        detail['mismatches'] = mismatches
        detail['reason'] = 'PROVENANCE_MISMATCH'
        raise SelectiveProvenanceError(
            ERROR_STAGING_PROVENANCE,
            'staging provenance mismatch — refuse reuse and refuse auto-delete',
            mismatches=mismatches,
            context=detail,
        )

    # Same plan but incomplete / in-progress: continue materialize (reuse files).
    if mat.get('validation_result') != 'PASS':
        detail['reason'] = 'VALIDATION_NOT_PASS'
        detail['actual_validation_result'] = mat.get('validation_result')
        return False, detail

    # Target hop must exist under staging when requested.
    check_hop = hop or ''
    layout_mismatches = []
    if check_hop:
        hop_ubuntu = os.path.join(staging, 'hops', check_hop, 'ubuntu')
        if not os.path.isdir(hop_ubuntu):
            layout_mismatches.append(OrderedDict([
                ('field', 'hop_ubuntu'),
                ('expected', hop_ubuntu),
                ('actual', 'missing'),
            ]))
        else:
            dists = os.path.join(hop_ubuntu, 'dists')
            pool = os.path.join(hop_ubuntu, 'pool')
            if not os.path.isdir(dists):
                layout_mismatches.append(OrderedDict([
                    ('field', 'hop_dists'),
                    ('expected', dists),
                    ('actual', 'missing'),
                ]))
            if not os.path.isdir(pool):
                layout_mismatches.append(OrderedDict([
                    ('field', 'hop_pool'),
                    ('expected', pool),
                    ('actual', 'missing'),
                ]))

    shared = os.path.join(staging, 'shared', 'offline')
    if not os.path.isdir(shared):
        layout_mismatches.append(OrderedDict([
            ('field', 'shared_offline'),
            ('expected', shared),
            ('actual', 'missing'),
        ]))

    # Staging must not already have been published away (empty hops after rename).
    hops_root = os.path.join(staging, 'hops')
    if not os.path.isdir(hops_root) or not os.listdir(hops_root):
        detail['reason'] = 'STAGING_EMPTY_OR_PUBLISHED'
        detail['mismatches'] = layout_mismatches
        return False, detail

    # Spot-check selected deb checksums for the hop (or all hops).
    debs = plan.get('debs') or []
    checked = 0
    for deb in debs:
        if checked >= sample_limit:
            break
        src_hops = deb.get('source_hops') or []
        if check_hop and check_hop not in src_hops:
            continue
        for h in src_hops:
            if check_hop and h != check_hop:
                continue
            rel = deb.get('relative_pool_path') or ''
            if not rel:
                continue
            dst = os.path.join(staging, 'hops', h, 'ubuntu', rel)
            expected_sha = (deb.get('sha256') or '').lower()
            expected_size = int(deb.get('size_bytes') or 0)
            if not os.path.isfile(dst):
                layout_mismatches.append(OrderedDict([
                    ('field', 'selected_deb'),
                    ('expected', dst),
                    ('actual', 'missing'),
                ]))
            elif not destination_matches(dst, expected_sha, expected_size):
                layout_mismatches.append(OrderedDict([
                    ('field', 'selected_deb_checksum'),
                    ('expected', expected_sha),
                    ('actual', 'mismatch_or_size'),
                    ('path', dst),
                ]))
            checked += 1
            break

    if layout_mismatches:
        detail['mismatches'] = layout_mismatches
        detail['reason'] = 'PROVENANCE_MISMATCH'
        raise SelectiveProvenanceError(
            ERROR_STAGING_PROVENANCE,
            'staging provenance mismatch — refuse reuse and refuse auto-delete',
            mismatches=layout_mismatches,
            context=detail,
        )

    detail['reason'] = 'REUSE_OK'
    detail['checked_debs'] = checked
    detail['refresh_resume_from'] = 'MATERIALIZED'
    detail['materialize_reused'] = 'YES'
    detail['staging_schema_version'] = STAGING_SCHEMA_VERSION
    return True, detail


def _link_or_copy_tree(src, dst):
    """Populate dst from src using hardlinks when possible (never moves src)."""
    if not os.path.isdir(src):
        raise IOError('source tree missing: %s' % src)
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    parent = os.path.dirname(dst)
    ensure_dir(parent)
    # cp -al creates dst as a hardlinked clone of src (GNU cp).
    try:
        subprocess.check_call(
            ['cp', '-al', src, dst],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if os.path.isdir(dst):
            return 'hardlink-tree'
    except (OSError, subprocess.CalledProcessError):
        if os.path.isdir(dst):
            shutil.rmtree(dst)

    def _on_copy(src_path, dst_path):
        ensure_dir(os.path.dirname(dst_path))
        try:
            os.link(src_path, dst_path)
        except OSError:
            shutil.copy2(src_path, dst_path)

    for dirpath, dirnames, filenames in os.walk(src):
        rel = os.path.relpath(dirpath, src)
        target_dir = dst if rel == '.' else os.path.join(dst, rel)
        ensure_dir(target_dir)
        for name in dirnames:
            ensure_dir(os.path.join(target_dir, name))
        for name in filenames:
            _on_copy(os.path.join(dirpath, name), os.path.join(target_dir, name))
    return 'copy-tree'


def merge_other_published_hops_into_staging(selective_root, hop):
    """After hop-scoped materialize, bring other published hops into staging.

    Required so atomic_publish (full tree rename) does not drop sibling hops.
    Never modifies published; only hardlink/copy into staging.
    """
    if not hop:
        return OrderedDict([('merged_hops', []), ('skipped', 'no hop filter')])
    staging = os.path.join(selective_root, 'staging')
    published = os.path.join(selective_root, 'published')
    pub_hops = os.path.join(published, 'hops')
    st_hops = os.path.join(staging, 'hops')
    ensure_dir(st_hops)
    merged = []
    if os.path.isdir(pub_hops):
        for name in sorted(os.listdir(pub_hops)):
            if name == hop:
                continue
            src = os.path.join(pub_hops, name)
            dst = os.path.join(st_hops, name)
            if not os.path.isdir(src):
                continue
            if os.path.isdir(dst):
                # Already present (e.g. prior partial) — keep staging copy.
                continue
            method = _link_or_copy_tree(src, dst)
            merged.append(OrderedDict([('hop', name), ('method', method)]))
    # Merge sibling release-upgraders from published shared/offline.
    pub_shared = os.path.join(published, 'shared', 'offline')
    st_shared = os.path.join(staging, 'shared', 'offline')
    ensure_dir(st_shared)
    if os.path.isdir(pub_shared):
        for root, _dns, files in os.walk(pub_shared):
            rel_root = os.path.relpath(root, pub_shared)
            for name in files:
                rel = name if rel_root == '.' else os.path.join(rel_root, name)
                src = os.path.join(pub_shared, rel)
                dst = os.path.join(st_shared, rel)
                if os.path.isfile(dst):
                    continue
                ensure_dir(os.path.dirname(dst))
                try:
                    os.link(src, dst)
                except OSError:
                    shutil.copy2(src, dst)
    eprint('STAGING_MERGE_OTHER_HOPS=%s' % ','.join(m['hop'] for m in merged))
    return OrderedDict([
        ('replaced_hop', hop),
        ('merged_hops', merged),
        ('staging_root', staging),
    ])


def _tool_version_label():
    """Best-effort tool/commit label for staging receipts."""
    env = (os.environ.get('UM_TOOL_VERSION') or '').strip()
    if env:
        return env
    try:
        root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
        out = subprocess.check_output(
            ['git', '-C', root, 'rev-parse', '--short', 'HEAD'],
            stderr=subprocess.DEVNULL,
        ).decode('utf-8', 'replace').strip()
        if out:
            return out
    except (OSError, subprocess.CalledProcessError):
        pass
    return 'selective_mirror'


def quarantine_mismatch_staging(
    selective_root,
    expected_receipt_path=None,
    evidence_dir=None,
    known_selective_roots=None,
):
    """Atomically rename provenance-mismatch staging; never delete.

    Safety gates (any failure aborts):
    - staging is a known selective staging path (not symlink)
    - not a forbidden path / published root
    - expected receipt exists when provided
    - same-filesystem rename possible
    - after rename, original staging path is absent
    """
    selective_root = os.path.abspath(selective_root)
    staging = os.path.join(selective_root, 'staging')
    published = os.path.join(selective_root, 'published')
    state_dir = os.path.join(selective_root, 'state')
    receipt = expected_receipt_path or os.path.join(state_dir, 'materialize.json')

    known = set(known_selective_roots or [])
    known.add(selective_root)
    # Always accept the canonical spool path when present on this host.
    known.add('/var/spool/apt-mirror/selective')

    def _fail(msg, **extra):
        ctx = OrderedDict([
            ('selective_root', selective_root),
            ('staging_root', staging),
            ('message', msg),
        ])
        ctx.update(extra)
        raise SelectiveProvenanceError(ERROR_QUARANTINE, msg, context=ctx)

    if selective_root not in known and os.path.realpath(selective_root) not in {
        os.path.realpath(k) for k in known
    }:
        _fail('selective_root is not a known managed path')
    if not os.path.isdir(staging):
        _fail('staging root missing', staging_root=staging)
    if os.path.islink(staging):
        _fail('staging root is a symlink — refuse quarantine')
    real_staging = os.path.realpath(staging)
    if real_staging in FORBIDDEN_QUARANTINE_PATHS or real_staging in (
        '/', '/var', '/home', '/var/spool', '/var/spool/apt-mirror',
    ):
        _fail('staging resolves to a forbidden path', real_staging=real_staging)
    if os.path.isdir(published):
        if os.path.samefile(staging, published):
            _fail('staging and published are the same path/device inode')
        if real_staging == os.path.realpath(published):
            _fail('staging realpath equals published root')
    if expected_receipt_path or os.path.isfile(receipt):
        if not os.path.isfile(receipt):
            _fail('expected receipt missing', receipt=receipt)
        # Receipt must reference this staging root when present.
        try:
            rec = load_json(receipt)
            rec_staging = rec.get('staging_root') or ''
            if rec_staging and os.path.realpath(rec_staging) != real_staging:
                _fail(
                    'receipt staging_root does not match staging',
                    receipt_staging=rec_staging,
                    real_staging=real_staging,
                )
        except (ValueError, OSError) as exc:
            _fail('receipt unreadable: %s' % exc, receipt=receipt)

    plan_sha = ''
    if os.path.isfile(receipt):
        try:
            plan_sha = (load_json(receipt).get('plan_checksum') or '')[:8]
        except (ValueError, OSError):
            plan_sha = ''
    ts = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    dest = '%s.quarantine-plan-%s-%s' % (
        staging, plan_sha or 'unknown', ts,
    )
    if os.path.lexists(dest):
        _fail('quarantine destination already exists', destination=dest)

    # Same-filesystem rename check.
    try:
        st_src = os.stat(staging)
        st_parent = os.stat(os.path.dirname(staging))
        if st_src.st_dev != st_parent.st_dev:
            _fail('staging and parent are on different devices; refuse rename')
    except OSError as exc:
        _fail('stat failed: %s' % exc)

    # Evidence capture (best effort before rename).
    if evidence_dir:
        ensure_dir(evidence_dir)
        if os.path.isfile(receipt):
            shutil.copy2(receipt, os.path.join(evidence_dir, 'materialize.json'))
        meta = OrderedDict([
            ('collected_at', iso_now()),
            ('staging_root', staging),
            ('receipt_path', receipt),
            ('receipt_sha256', file_sha256(receipt) if os.path.isfile(receipt) else ''),
            ('selective_root', selective_root),
            ('published_root', published),
        ])
        try:
            file_count = 0
            total_bytes = 0
            part_count = 0
            for dirpath, _dns, fnames in os.walk(staging):
                for name in fnames:
                    fp = os.path.join(dirpath, name)
                    file_count += 1
                    try:
                        total_bytes += os.path.getsize(fp)
                    except OSError:
                        pass
                    if name.endswith('.download') or name.endswith('.part'):
                        part_count += 1
            meta['staging_file_count'] = file_count
            meta['staging_total_bytes'] = total_bytes
            meta['partial_temp_file_count'] = part_count
            meta['top_level'] = sorted(os.listdir(staging))
        except OSError as exc:
            meta['walk_error'] = str(exc)
        write_json(os.path.join(evidence_dir, 'quarantine-meta.json'), meta)

    os.rename(staging, dest)
    if os.path.lexists(staging):
        # Roll back if somehow still present.
        try:
            os.rename(dest, staging)
        except OSError:
            pass
        _fail('staging path still present after rename', destination=dest)

    # Move receipt alongside quarantine (do not rewrite plan SHA).
    receipt_dest = ''
    if os.path.isfile(receipt):
        receipt_dest = os.path.join(dest, 'state-materialize.json')
        ensure_dir(os.path.dirname(receipt_dest))
        shutil.move(receipt, receipt_dest)

    result = OrderedDict([
        ('PROVENANCE_MISMATCH_CONFIRMED', 'YES'),
        ('QUARANTINE_SOURCE', staging),
        ('QUARANTINE_DESTINATION', dest),
        ('QUARANTINE_RESULT', 'PASS'),
        ('QUARANTINE_DELETE_PERFORMED', 'NO'),
        ('receipt_moved_to', receipt_dest),
        ('evidence_dir', evidence_dir or ''),
        ('staging_schema_version', STAGING_SCHEMA_VERSION),
    ])
    eprint('PROVENANCE_MISMATCH_CONFIRMED=YES')
    eprint('QUARANTINE_SOURCE=%s' % staging)
    eprint('QUARANTINE_DESTINATION=%s' % dest)
    eprint('QUARANTINE_RESULT=PASS')
    eprint('QUARANTINE_DELETE_PERFORMED=NO')
    return result


def materialize(plan_path, selective_root, allow_download=True, sign=True,
                allow_resume=False, hop=None, extra_reuse_roots=None):
    plan = load_json(plan_path)
    if plan.get('validation_result') != 'PASS':
        raise RuntimeError('refusing to materialize FAIL plan')

    requested_hop = hop or ''
    staging = os.path.join(selective_root, 'staging')
    state_dir = os.path.join(selective_root, 'state')
    ensure_dir(state_dir)
    receipt_path = os.path.join(state_dir, 'materialize.json')

    if allow_resume:
        reusable, detail = evaluate_staging_reuse(
            plan_path, selective_root, hop=hop,
        )
        if reusable:
            mat, _ = _load_state_json(state_dir, 'materialize.json')
            result = OrderedDict(mat) if mat else OrderedDict()
            result['validation_result'] = 'PASS'
            result['staging_root'] = staging
            result['materialize_reused'] = 'YES'
            result['refresh_resume_from'] = 'MATERIALIZED'
            result['resume_detail'] = detail
            result['staging_schema_version'] = STAGING_SCHEMA_VERSION
            result['generated_at'] = result.get('generated_at') or iso_now()
            eprint('MATERIALIZE_REUSED=YES')
            eprint('REFRESH_RESUME_FROM=MATERIALIZED')
            eprint('STAGING_PROVENANCE=PASS')
            eprint('STAGING_SCHEMA_VERSION=%s' % STAGING_SCHEMA_VERSION)
            write_json(receipt_path, result)
            return result

    # Preserve previously completed files across re-runs / mid-run failures.
    # Only remove leftover partial *.download temps.
    ensure_dir(staging)
    cleanup_partial_downloads(staging)
    keys_dir = os.path.join(selective_root, 'keys')
    # Fail closed: never leave READY from a prior verify while rematerializing.
    safe_unlink(os.path.join(state_dir, 'READY'))

    generation_id = 'mat-%s-%s' % (
        time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()),
        os.getpid(),
    )
    components = []
    for deb in plan.get('debs') or []:
        if requested_hop and requested_hop not in (deb.get('source_hops') or []):
            continue
        comp = deb.get('component') or ''
        if comp and comp not in components:
            components.append(comp)

    # Atomic in-progress receipt bound to current plan provenance.
    in_progress = OrderedDict([
        ('validation_result', 'IN_PROGRESS'),
        ('staging_root', staging),
        ('staging_schema_version', STAGING_SCHEMA_VERSION),
        ('materialize_generation_id', generation_id),
        ('plan_path', os.path.abspath(plan_path)),
        ('plan_checksum', plan.get('plan_checksum')),
        ('discovery_path', plan.get('discovery_root') or ''),
        ('discovery_artifact_checksum', plan.get('discovery_artifact_checksum')),
        ('hop', requested_hop),
        ('architecture', 'amd64'),
        ('components', components),
        ('profile_name', plan.get('profile_name')),
        ('tool_version', _tool_version_label()),
        ('created_at', iso_now()),
        ('generated_at', iso_now()),
        ('materialize_reused', 'NO'),
    ])
    write_json(receipt_path, in_progress)
    eprint('NEW_STAGING_ROOT=%s' % staging)
    eprint('NEW_STAGING_GENERATION=%s' % generation_id)
    eprint('NEW_STAGING_PLAN_SHA256=%s' % (plan.get('plan_checksum') or ''))
    eprint('NEW_STAGING_HOP=%s' % (requested_hop or 'ALL'))
    eprint('STAGING_SCHEMA_VERSION=%s' % STAGING_SCHEMA_VERSION)
    eprint('REQUESTED_HOP=%s' % (requested_hop or 'ALL'))
    eprint('EFFECTIVE_HOP=%s' % (requested_hop or 'ALL'))

    stats = OrderedDict([
        ('hardlink', 0), ('reflink', 0), ('copy', 0),
        ('downloaded', 0), ('exists', 0),
        ('bytes_reused', 0), ('bytes_downloaded', 0),
        ('transient_retry_count', 0),
        ('checksum_mismatch', 0),
    ])

    hop_summaries = plan.get('hop_summaries') or {}
    debs = plan.get('debs') or []
    entries = _acquisition_entries(plan, hop=hop)
    total_entries = len(entries)
    succeeded = 0
    unexpected_hops = set()
    eprint('MATERIALIZE_HOP=%s' % (requested_hop or 'ALL'))
    eprint('MATERIALIZE_EXPECTED=%s' % total_entries)

    for idx, hop_name, deb in entries:
        if requested_hop and hop_name != requested_hop:
            unexpected_hops.add(hop_name)
        ubuntu = os.path.join(staging, 'hops', hop_name, 'ubuntu')
        ensure_dir(os.path.join(ubuntu, 'pool'))
        rel = deb['relative_pool_path']
        dst = os.path.join(ubuntu, rel)
        expected_sha = (deb.get('sha256') or '').lower()
        expected_size = int(deb.get('size_bytes') or 0)
        src = deb.get('seed_local_path') or ''
        if not src or not os.path.isfile(src):
            src = resolve_verified_reuse_source(
                selective_root, hop_name, rel,
                expected_sha256=expected_sha,
                expected_size=expected_size,
                extra_reuse_roots=extra_reuse_roots,
            )
        original_url = deb.get('original_url') or ''
        normalized = normalize_url(original_url)
        url = original_url if allow_download else None
        entry_ctx = OrderedDict([
            ('plan_entry_index', idx),
            ('hop', hop_name),
            ('package', deb.get('package') or ''),
            ('version', deb.get('version') or ''),
            ('architecture', deb.get('architecture') or ''),
            ('expected_sha256', expected_sha),
            ('expected_size_bytes', expected_size),
            ('original_url', original_url),
            ('normalized_url', normalized),
            ('destination_path', dst),
        ])
        try:
            method, _resolution = acquire_with_component_correction(
                src, dst,
                allow_download_url=url,
                expected_sha256=expected_sha,
                expected_size=expected_size,
                entry_context=entry_ctx,
                selective_root=selective_root,
                relative_pool_path=rel,
                deb=deb,
            )
        except SelectiveDownloadError as err:
            # Merge any download-time fields (http_status, redirects, …).
            merged = OrderedDict(entry_ctx)
            merged.update(err.context or {})
            err.context = merged
            retries = int(merged.get('transient_retry_count') or 0)
            stats['transient_retry_count'] = (
                int(stats.get('transient_retry_count') or 0) + retries
            )
            remaining = max(total_entries - succeeded - 1, 0)
            # Preserve in-progress receipt + progress; do not touch published.
            in_progress['stats'] = stats
            in_progress['succeeded'] = succeeded
            in_progress['remaining'] = remaining
            in_progress['generated_at'] = iso_now()
            write_json(receipt_path, in_progress)
            write_failed_downloads(selective_root, err, succeeded, remaining)
            eprint('MATERIALIZE_COMPLETED=%s' % succeeded)
            eprint('MATERIALIZE_REMAINING=%s' % remaining)
            eprint('MATERIALIZE_TRANSIENT_RETRY_COUNT=%s' % (
                stats.get('transient_retry_count') or 0
            ))
            raise
        stats['transient_retry_count'] = (
            int(stats.get('transient_retry_count') or 0)
            + int(entry_ctx.get('transient_retry_count') or 0)
        )
        stats[method] = stats.get(method, 0) + 1
        if method in ('hardlink', 'reflink', 'copy', 'exists'):
            stats['bytes_reused'] += expected_size
        elif method == 'downloaded':
            stats['bytes_downloaded'] += expected_size
        if not destination_matches(dst, expected_sha, expected_size):
            safe_unlink(dst + '.download')
            stats['checksum_mismatch'] = int(stats.get('checksum_mismatch') or 0) + 1
            err = SelectiveDownloadError(
                ERROR_DOWNLOAD,
                'checksum mismatch after acquire: %s' % rel,
                entry_ctx,
            )
            err.context['exception_type'] = 'ChecksumError'
            err.context['exception_message'] = 'checksum mismatch after acquire'
            remaining = max(total_entries - succeeded - 1, 0)
            in_progress['stats'] = stats
            write_json(receipt_path, in_progress)
            write_failed_downloads(selective_root, err, succeeded, remaining)
            raise err
        # Re-verify source when we reused a local immutable candidate.
        if src and os.path.isfile(src) and method in ('hardlink', 'reflink', 'copy'):
            if not destination_matches(src, expected_sha, expected_size):
                stats['checksum_mismatch'] = int(stats.get('checksum_mismatch') or 0) + 1
                raise SelectiveDownloadError(
                    ERROR_DOWNLOAD,
                    'reuse source checksum mismatch: %s' % src,
                    entry_ctx,
                )
        succeeded += 1

    if unexpected_hops:
        raise RuntimeError(
            'UNEXPECTED_HOP materialize entries: %s' % sorted(unexpected_hops)
        )
    eprint('UNEXPECTED_HOP_COUNT=0')

    # Generate indexes after all debs for each selected hop are present.
    for hop_name, summary in hop_summaries.items():
        if requested_hop and hop_name != requested_hop:
            continue
        ubuntu = os.path.join(staging, 'hops', hop_name, 'ubuntu')
        ensure_dir(os.path.join(ubuntu, 'pool'))
        hop_debs = [d for d in debs if hop_name in (d.get('source_hops') or [])]
        suites = summary.get('suites') or []
        from_series = summary.get('from_series') or hop_series_pair(hop_name)[0]
        to_series = summary.get('to_series') or hop_series_pair(hop_name)[1]
        generate_packages_for_hop(
            ubuntu, hop_debs, suites,
            from_series=from_series, to_series=to_series, hop=hop_name,
        )
        if sign:
            for suite in suites:
                release = os.path.join(ubuntu, 'dists', suite, 'Release')
                if os.path.isfile(release):
                    sign_release(release, keys_dir)

    # shared offline placeholders — upgraders copied from plan URLs if download allowed
    shared = os.path.join(staging, 'shared', 'offline')
    ensure_dir(shared)
    ensure_dir(os.path.join(shared, 'release-upgraders'))
    # meta-release stub pointing at local paths (full rewrite done by sync_release_upgraders reuse)
    meta = os.path.join(shared, 'meta-release-lts')
    with open(meta, 'w') as fh:
        fh.write('# Selective offline meta-release-lts placeholder\n')
        fh.write('# Replaced/rewritten by release-upgrader sync against PUBLIC_BASE_URL\n')

    for up in plan.get('upgraders') or []:
        up_hop = up.get('hop') or ''
        if requested_hop and up_hop and up_hop != requested_hop:
            continue
        url = up.get('url') or ''
        name = up.get('filename') or os.path.basename(urlparse_path(url))
        if not name:
            continue
        # derive dist from filename prefix
        dist = name.split('.', 1)[0].replace('.tar', '')
        if name.endswith('.gpg'):
            dist = name.split('.tar.gz', 1)[0]
        dest_dir = os.path.join(shared, 'release-upgraders', dist)
        ensure_dir(dest_dir)
        dst = os.path.join(dest_dir, name)
        if allow_download and url:
            up_sha = (up.get('sha256') or '').lower() or None
            up_size = up.get('size_bytes')
            try:
                up_size = int(up_size) if up_size not in (None, '') else None
            except (TypeError, ValueError):
                up_size = None
            if up_sha or up_size is not None:
                if destination_matches(dst, up_sha, up_size):
                    stats['exists'] = stats.get('exists', 0) + 1
                    continue
            elif os.path.isfile(dst):
                stats['exists'] = stats.get('exists', 0) + 1
                continue
            entry_ctx = OrderedDict([
                ('plan_entry_index', None),
                ('hop', up_hop),
                ('package', name),
                ('version', ''),
                ('architecture', ''),
                ('expected_sha256', up_sha or ''),
                ('expected_size_bytes', up_size if up_size is not None else ''),
                ('original_url', url),
                ('normalized_url', normalize_url(url)),
                ('destination_path', dst),
            ])
            try:
                method = acquire_file(
                    '', dst, allow_download_url=url,
                    expected_sha256=up_sha, expected_size=up_size,
                    entry_context=entry_ctx,
                )
            except SelectiveDownloadError as err:
                merged = OrderedDict(entry_ctx)
                merged.update(err.context or {})
                err.context = merged
                retries = int(merged.get('transient_retry_count') or 0)
                stats['transient_retry_count'] = (
                    int(stats.get('transient_retry_count') or 0) + retries
                )
                in_progress['stats'] = stats
                write_json(receipt_path, in_progress)
                write_failed_downloads(
                    selective_root, err, succeeded,
                    max(total_entries - succeeded, 0),
                )
                raise
            stats[method] = stats.get(method, 0) + 1

    merge_info = OrderedDict()
    if requested_hop:
        # Keep sibling hops from published so atomic full-tree publish is safe.
        merge_info = merge_other_published_hops_into_staging(
            selective_root, requested_hop,
        )

    reused = (
        int(stats.get('hardlink') or 0)
        + int(stats.get('reflink') or 0)
        + int(stats.get('copy') or 0)
        + int(stats.get('exists') or 0)
    )
    downloaded = int(stats.get('downloaded') or 0)
    eprint('MATERIALIZE_COMPLETED=%s' % succeeded)
    eprint('MATERIALIZE_REUSED=%s' % reused)
    eprint('MATERIALIZE_DOWNLOADED=%s' % downloaded)
    eprint('MATERIALIZE_REMAINING=0')
    eprint('MATERIALIZE_CHECKSUM_MISMATCH=%s' % (
        stats.get('checksum_mismatch') or 0
    ))
    eprint('MATERIALIZE_TRANSIENT_RETRY_COUNT=%s' % (
        stats.get('transient_retry_count') or 0
    ))
    eprint('STAGING_SCHEMA_CONSISTENCY=PASS')
    eprint('MATERIALIZER_SCHEMA=%s' % MATERIALIZER_SCHEMA)
    eprint('VALIDATOR_SCHEMA=%s' % VALIDATOR_SCHEMA)
    eprint('PUBLISHER_SCHEMA=%s' % PUBLISHER_SCHEMA)
    eprint('NEW_STAGING_RECEIPT_VALIDATION=PASS')

    result = OrderedDict([
        ('validation_result', 'PASS'),
        ('staging_root', staging),
        ('staging_schema_version', STAGING_SCHEMA_VERSION),
        ('materialize_generation_id', generation_id),
        ('plan_path', os.path.abspath(plan_path)),
        ('plan_checksum', plan.get('plan_checksum')),
        ('discovery_path', plan.get('discovery_root') or ''),
        ('discovery_artifact_checksum', plan.get('discovery_artifact_checksum')),
        ('hop', requested_hop),
        ('architecture', 'amd64'),
        ('components', components),
        ('stats', stats),
        ('profile_name', plan.get('profile_name')),
        ('tool_version', _tool_version_label()),
        ('materialize_reused', 'NO'),
        ('published_hop_merge', merge_info),
        ('created_at', in_progress.get('created_at')),
        ('generated_at', iso_now()),
    ])
    clear_failed_downloads(selective_root)
    write_json(receipt_path, result)
    write_cleanup_plan(selective_root, plan, stats)
    return result


def urlparse_path(url):
    return urlparse(url).path if url else ''


def write_cleanup_plan(selective_root, plan, stats):
    seed = plan.get('full_mirror_seed_root') or ''
    sizes = plan.get('sizes') or {}
    cleanup = OrderedDict([
        ('schema_version', 1),
        ('generated_at', iso_now()),
        ('action', 'DO_NOT_AUTO_DELETE'),
        ('full_mirror_seed_root', seed),
        ('selective_mirror_root', selective_root),
        ('notes', [
            'Existing full mirror was used only as a seed.',
            'Delete the full mirror only after selective verify+publish PASS',
            'and after confirming selective tree is independently complete',
            '(no hardlink dependency on seed), or after a full copy/rsync.',
        ]),
        ('estimated_selective_bytes', sizes.get('selective_mirror_estimate_bytes')),
        ('reusable_from_seed_bytes', sizes.get('reusable_from_seed_bytes')),
        ('download_bytes', sizes.get('download_bytes')),
        ('materialize_stats', stats),
        ('suggested_manual_commands', [
            '# AFTER verify-selective + publish-selective PASS and independence check:',
            '# du -sh %s' % selective_root,
            '# # if hardlinks remain against seed, rsync -aH --copy-links staging to a new tree first',
            '# # rm -rf %s   # NOT auto-run' % seed,
        ]),
    ])
    write_json(os.path.join(selective_root, 'state', 'cleanup-plan.json'), cleanup)


def _load_state_json(state, *names):
    for name in names:
        path = os.path.join(state, name)
        if os.path.isfile(path):
            return load_json(path), path
    return {}, ''


def _load_plan_for_publish(selective_root, verify_result):
    candidates = [
        os.path.join(selective_root, 'state', 'plan.json'),
    ]
    # Prefer plan path from environment / common discovery location via verify root
    for cand in candidates:
        if os.path.isfile(cand):
            return load_json(cand)
    return {}


def _verify_result_is_current(verify_result, plan, staging):
    """Ensure pre-publish verify matches current plan + staging snapshot."""
    if not verify_result:
        return False, ERROR_PREPUBLISH, 'verify-result missing'
    if verify_result.get('validation_result') != 'PASS':
        return False, ERROR_PREPUBLISH, 'verify-selective not PASS'
    phase = verify_result.get('validation_phase') or 'pre_publish'
    if phase not in ('pre_publish',):
        # Accept legacy verify.json without phase if other checks match
        if verify_result.get('validation_phase') not in (None, '', 'pre_publish'):
            return False, ERROR_VERIFY_STALE, 'unexpected validation_phase=%s' % phase
    plan_ck = plan.get('plan_checksum') or ''
    ver_plan = (
        verify_result.get('plan_checksum')
        or verify_result.get('selective_plan_checksum')
        or ''
    )
    if plan_ck and ver_plan and plan_ck != ver_plan:
        return False, ERROR_VERIFY_STALE, 'plan_checksum mismatch'
    disc = plan.get('discovery_artifact_checksum') or ''
    ver_disc = verify_result.get('discovery_artifact_checksum') or ''
    if disc and ver_disc and disc != ver_disc:
        return False, ERROR_VERIFY_STALE, 'discovery_artifact_checksum mismatch'
    snap = verify_result.get('repository_content_checksum') or ''
    if snap and os.path.isdir(staging):
        # Import locally to avoid circular import at module load
        import validate_selective_mirror as vsm
        current = vsm.tree_sha256(staging)
        if current != snap:
            return False, ERROR_STAGING_CHANGED, 'staging snapshot changed since verify'
    return True, '', ''


def _switch_current_symlink(selective_root, target_name='published'):
    current_link = os.path.join(selective_root, 'current')
    tmp_current = current_link + '.tmp'
    if os.path.lexists(tmp_current):
        safe_unlink(tmp_current)
    os.symlink(target_name, tmp_current)
    os.replace(tmp_current, current_link)
    active = os.path.join(selective_root, 'active')
    tmp_link = active + '.tmp'
    if os.path.lexists(tmp_link):
        safe_unlink(tmp_link)
    os.symlink(target_name, tmp_link)
    os.replace(tmp_link, active)
    return current_link, active


def _ensure_ubuntu_alias(published):
    ubuntu_link = os.path.join(published, 'ubuntu')
    default_hop = 'jammy-to-noble'
    hop_ubuntu = os.path.join(published, 'hops', default_hop, 'ubuntu')
    if not os.path.isdir(hop_ubuntu):
        return
    if os.path.islink(ubuntu_link) or os.path.isfile(ubuntu_link):
        os.unlink(ubuntu_link)
    if not os.path.exists(ubuntu_link):
        os.symlink(os.path.join('hops', default_hop, 'ubuntu'), ubuntu_link)


def _write_publish_result(state, result):
    write_json(os.path.join(state, PUBLISH_RESULT_NAME), result)
    write_json(os.path.join(state, PUBLISH_RESULT_LEGACY), result)


def atomic_publish(selective_root, require_verify_pass=True, http_base='http://127.0.0.1',
                   run_post_publish=True, plan_path=None, run_nginx_preflight=True):
    """Atomic publish of staging → published with post-publish HTTP smoke + READY.

    On post-publish failure: rollback symlink/tree, never write READY.
    Before promoting staging, production nginx must already point at the
    selective canonical root (SELECTIVE_NGINX_EFFECTIVE_ROOT_MISMATCH otherwise).
    """
    import validate_selective_mirror as vsm

    state = os.path.join(selective_root, 'state')
    ensure_dir(state)
    verify_result, verify_path = _load_state_json(
        state, VERIFY_RESULT_NAME, VERIFY_RESULT_LEGACY,
    )
    plan = {}
    if plan_path and os.path.isfile(plan_path):
        plan = load_json(plan_path)
    if not plan:
        plan = _load_plan_for_publish(selective_root, verify_result)

    staging = os.path.join(selective_root, 'staging')
    if not os.path.isdir(staging):
        raise SelectivePublishError(
            ERROR_PREPUBLISH, 'staging missing',
            {'staging_root': staging},
        )

    if require_verify_pass:
        ok, code, reason = _verify_result_is_current(verify_result, plan, staging)
        if not ok:
            raise SelectivePublishError(code, reason, {
                'verify_result_path': verify_path,
                'plan_checksum': plan.get('plan_checksum'),
                'verify_plan_checksum': verify_result.get('plan_checksum')
                or verify_result.get('selective_plan_checksum'),
                'discovery_artifact_checksum': plan.get('discovery_artifact_checksum'),
            })

    # Fail before touching staging when nginx still serves the legacy mirror root
    if run_nginx_preflight:
        preflight = vsm.check_selective_nginx_preflight(selective_root)
        if not preflight.get('ok'):
            err_code = preflight.get('error_code') or ERROR_NGINX_ROOT_MISMATCH
            result = OrderedDict([
                ('validation_result', 'FAIL'),
                ('validation_phase', 'pre_publish_nginx'),
                ('generated_at', iso_now()),
                ('error_code', err_code),
                ('nginx_config_path', preflight.get('nginx_config_path')),
                ('nginx_document_root', preflight.get('nginx_document_root')),
                ('expected_selective_root', preflight.get('expected_selective_root')),
                ('gates', preflight.get('gates') or {}),
                ('errors', preflight.get('errors') or []),
                ('tested_endpoints', []),
                ('http_results', []),
                ('rollback_performed', False),
                ('plan_checksum', plan.get('plan_checksum')),
                ('discovery_artifact_checksum',
                 plan.get('discovery_artifact_checksum')),
            ])
            _write_publish_result(state, result)
            ready = os.path.join(state, 'READY')
            if os.path.isfile(ready):
                os.unlink(ready)
            raise SelectivePublishError(
                err_code,
                'nginx effective root is not selective canonical path',
                result,
            )

    published = os.path.join(selective_root, 'published')
    previous = os.path.join(selective_root, 'published.previous')
    new_pub = os.path.join(selective_root, 'published.new')
    previous_target = ''
    if os.path.isdir(published) or os.path.islink(published):
        previous_target = os.path.realpath(published)

    if os.path.isdir(new_pub) or os.path.islink(new_pub):
        if os.path.islink(new_pub):
            os.unlink(new_pub)
        else:
            shutil.rmtree(new_pub)

    # Promote staging → published.new, then rename over published
    os.rename(staging, new_pub)
    ensure_dir(os.path.join(selective_root, 'staging'))

    if os.path.isdir(published) or os.path.islink(published):
        if os.path.isdir(previous) or os.path.islink(previous):
            if os.path.islink(previous):
                os.unlink(previous)
            else:
                shutil.rmtree(previous)
        os.rename(published, previous)
    os.rename(new_pub, published)

    current_link, active = _switch_current_symlink(selective_root, 'published')
    _ensure_ubuntu_alias(published)

    # Best-effort nginx reload after symlink switch (post_publish_validate is authoritative)
    if shutil.which('nginx'):
        try:
            if subprocess.call(
                ['nginx', '-t'],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            ) == 0:
                try:
                    subprocess.call(
                        ['systemctl', 'reload', 'nginx'],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    )
                except OSError:
                    pass
        except OSError:
            pass

    post = OrderedDict()
    rollback_performed = False
    rollback_result = ''
    if run_post_publish:
        if not plan:
            # Minimal plan from verify result fields
            plan = {
                'hops': [],
                'hop_summaries': {},
                'debs': [],
                'plan_checksum': verify_result.get('plan_checksum')
                or verify_result.get('selective_plan_checksum'),
                'discovery_artifact_checksum': verify_result.get(
                    'discovery_artifact_checksum'),
            }
        post = vsm.post_publish_validate(
            selective_root, plan, http_base=http_base, published_root=published,
        )

        if post.get('validation_result') != 'PASS':
            # Rollback: restore previous published if any; else remove failed current
            try:
                if os.path.isdir(previous) or os.path.islink(previous):
                    rb = rollback_publish(selective_root)
                    rollback_performed = True
                    rollback_result = rb.get('validation_result')
                else:
                    # No previous — remove published + current symlink; restore staging
                    failed = os.path.join(selective_root, 'published.failed')
                    if os.path.isdir(failed) or os.path.islink(failed):
                        if os.path.islink(failed):
                            os.unlink(failed)
                        else:
                            shutil.rmtree(failed)
                    if os.path.isdir(published) or os.path.islink(published):
                        os.rename(published, failed)
                    # Move failed tree back to staging so materialize data is preserved
                    if os.path.isdir(failed) and not os.path.isdir(staging):
                        os.rename(failed, staging)
                    elif os.path.isdir(failed):
                        # staging empty dir exists — replace
                        if os.path.isdir(staging) and not os.listdir(staging):
                            os.rmdir(staging)
                            os.rename(failed, staging)
                    for link in (
                        os.path.join(selective_root, 'current'),
                        os.path.join(selective_root, 'active'),
                    ):
                        if os.path.islink(link) or os.path.isfile(link):
                            safe_unlink(link)
                    rollback_performed = True
                    rollback_result = 'REMOVED_FAILED_CURRENT'
            except Exception as exc:
                result = OrderedDict([
                    ('validation_result', 'FAIL'),
                    ('validation_phase', 'post_publish'),
                    ('generated_at', iso_now()),
                    ('error_code', ERROR_PUBLISH_ROLLBACK),
                    ('previous_target', previous_target),
                    ('published_target', published),
                    ('atomic_switch', True),
                    ('nginx_config', post.get('gates', {}).get('nginx_config')),
                    ('nginx_service', post.get('gates', {}).get('nginx_service')),
                    ('tested_endpoints', post.get('tested_endpoints') or []),
                    ('http_results', post.get('http_results') or []),
                    ('rollback_performed', rollback_performed),
                    ('rollback_result', 'FAIL: %s' % exc),
                    ('plan_checksum', plan.get('plan_checksum')),
                    ('discovery_artifact_checksum',
                     plan.get('discovery_artifact_checksum')),
                    ('errors', (post.get('errors') or []) + [str(exc)]),
                    ('post_publish', post),
                ])
                _write_publish_result(state, result)
                ready = os.path.join(state, 'READY')
                if os.path.isfile(ready):
                    os.unlink(ready)
                raise SelectivePublishError(
                    ERROR_PUBLISH_ROLLBACK,
                    'post-publish failed and rollback failed: %s' % exc,
                    result,
                )

            result = OrderedDict([
                ('validation_result', 'FAIL'),
                ('validation_phase', 'post_publish'),
                ('generated_at', iso_now()),
                ('error_code', post.get('error_code') or ERROR_POSTPUBLISH_HTTP),
                ('previous_target', previous_target),
                ('published_target', published),
                ('atomic_switch', True),
                ('nginx_config', post.get('gates', {}).get('nginx_config')),
                ('nginx_service', post.get('gates', {}).get('nginx_service')),
                ('tested_endpoints', post.get('tested_endpoints') or []),
                ('http_results', post.get('http_results') or []),
                ('rollback_performed', rollback_performed),
                ('rollback_result', rollback_result),
                ('plan_checksum', plan.get('plan_checksum')),
                ('discovery_artifact_checksum',
                 plan.get('discovery_artifact_checksum')),
                ('errors', post.get('errors') or []),
                ('post_publish', post),
            ])
            _write_publish_result(state, result)
            ready = os.path.join(state, 'READY')
            if os.path.isfile(ready):
                os.unlink(ready)
            raise SelectivePublishError(
                result['error_code'],
                'post-publish validation failed',
                result,
            )

    result = OrderedDict([
        ('validation_result', 'PASS'),
        ('validation_phase', 'post_publish' if run_post_publish else 'publish_only'),
        ('generated_at', iso_now()),
        ('previous_target', previous_target),
        ('published_target', published),
        ('published_root', published),
        ('active', active),
        ('current', current_link),
        ('atomic_switch', True),
        ('nginx_config', (post.get('gates') or {}).get('nginx_config', 'SKIPPED')),
        ('nginx_service', (post.get('gates') or {}).get('nginx_service', 'SKIPPED')),
        ('tested_endpoints', post.get('tested_endpoints') or []),
        ('http_results', post.get('http_results') or []),
        ('rollback_performed', False),
        ('rollback_result', ''),
        ('plan_checksum', plan.get('plan_checksum')
         or verify_result.get('plan_checksum')
         or verify_result.get('selective_plan_checksum')),
        ('discovery_artifact_checksum',
         plan.get('discovery_artifact_checksum')
         or verify_result.get('discovery_artifact_checksum')),
        ('aws_semantic_contract_sha256',
         plan.get('aws_semantic_contract_sha256')
         or verify_result.get('aws_semantic_contract_sha256')
         or ((plan.get('aws_semantic_contract') or {}).get('contract_sha256'))),
        ('errors', []),
        ('gates', post.get('gates') or (
            {'post_publish_http': 'SKIPPED'} if not run_post_publish
            else {'post_publish_http': 'PASS'}
        )),
        ('post_publish', post),
    ])
    _write_publish_result(state, result)

    # READY only after post-publish HTTP smoke PASS
    ready_path = os.path.join(state, 'READY')
    if run_post_publish:
        vsm.write_ready(ready_path, verify_result or result, publish_result=result)
    elif os.path.isfile(ready_path):
        os.unlink(ready_path)
    return result


def rollback_publish(selective_root):
    published = os.path.join(selective_root, 'published')
    previous = os.path.join(selective_root, 'published.previous')
    if not (os.path.isdir(previous) or os.path.islink(previous)):
        raise RuntimeError('no previous publish to roll back to')
    failed = os.path.join(selective_root, 'published.failed')
    if os.path.isdir(published) or os.path.islink(published):
        if os.path.isdir(failed) or os.path.islink(failed):
            if os.path.islink(failed):
                os.unlink(failed)
            else:
                shutil.rmtree(failed)
        os.rename(published, failed)
    os.rename(previous, published)
    _switch_current_symlink(selective_root, 'published')
    # Invalidate READY after rollback
    ready = os.path.join(selective_root, 'state', 'READY')
    if os.path.isfile(ready):
        os.unlink(ready)
    return OrderedDict([
        ('validation_result', 'ROLLED_BACK'),
        ('published_root', published),
        ('generated_at', iso_now()),
        ('READY', False),
    ])


def status_report(selective_root, plan_path=None):
    state = os.path.join(selective_root, 'state')
    plan = load_json(plan_path) if plan_path and os.path.isfile(plan_path) else {}
    if not plan:
        plan, _ = _load_state_json(state, 'plan.json')
    mat, _ = _load_state_json(state, 'materialize.json')
    ver, _ = _load_state_json(state, VERIFY_RESULT_NAME, VERIFY_RESULT_LEGACY)
    pub, _ = _load_state_json(state, PUBLISH_RESULT_NAME, PUBLISH_RESULT_LEGACY)
    ready_path = os.path.join(state, 'READY')
    ready = os.path.isfile(ready_path)

    def tree_size(path):
        total = 0
        if not os.path.isdir(path):
            return 0
        for root, _dns, fns in os.walk(path):
            for fn in fns:
                try:
                    total += os.path.getsize(os.path.join(root, fn))
                except OSError:
                    pass
        return total

    published = os.path.join(selective_root, 'published')
    staging = os.path.join(selective_root, 'staging')
    current = os.path.join(selective_root, 'current')
    live = published if os.path.isdir(published) else staging
    sizes = plan.get('sizes') or {}
    counts = plan.get('counts') or {}

    pre = ver.get('validation_result') if ver else None
    if not ver:
        pre = 'NOT_RUN'
    post_http = 'NOT_RUN'
    if pub:
        if pub.get('validation_phase') == 'post_publish':
            post_http = pub.get('gates', {}).get('post_publish_http') or pub.get(
                'validation_result')
        elif pub.get('validation_result'):
            post_http = pub.get('validation_result')
    publish_st = pub.get('validation_result') if pub else 'NOT_RUN'

    current_target = ''
    if os.path.islink(current):
        current_target = os.readlink(current)
    elif os.path.isdir(published):
        current_target = published

    last_error = ''
    if pub.get('errors'):
        last_error = pub['errors'][0]
    elif ver.get('errors'):
        last_error = ver['errors'][0]

    return OrderedDict([
        ('profile_name', plan.get('profile_name') or 'offline-upgrade-selective'),
        ('selected_package_count', counts.get('unique_packages_by_name_arch_version')),
        ('selected_file_count', counts.get('unique_deb_sha256')),
        ('unique_package_size', sizes.get('unique_deb_bytes')),
        ('metadata_size', sizes.get('metadata_estimate_bytes')),
        ('total_mirror_size', tree_size(live) or sizes.get('selective_mirror_estimate_bytes')),
        ('reused_bytes', (mat.get('stats') or {}).get('bytes_reused', sizes.get('reusable_from_seed_bytes'))),
        ('downloaded_bytes', (mat.get('stats') or {}).get('bytes_downloaded', sizes.get('download_bytes'))),
        ('unresolved_count', counts.get('unresolved_deb_payloads', 0)),
        ('validation_result', ver.get('validation_result') or plan.get('validation_result')),
        ('materialize', mat.get('validation_result') or 'NOT_RUN'),
        ('pre_publish_verify', pre),
        ('verify', pre),
        ('publish', publish_st),
        ('post_publish_http', post_http),
        ('READY', 'YES' if ready else 'NO'),
        ('ready', ready),
        ('current_published_target', current_target),
        ('last_error', last_error or '-'),
        ('rollback_status', pub.get('rollback_result') or (
            'performed' if pub.get('rollback_performed') else 'none')),
        ('plan_checksum', plan.get('plan_checksum')
         or ver.get('plan_checksum') or ver.get('selective_plan_checksum')),
        ('discovery_artifact_checksum',
         plan.get('discovery_artifact_checksum')
         or ver.get('discovery_artifact_checksum')),
        ('selective_root', selective_root),
    ])


def _debug_enabled(args_debug=False):
    if args_debug:
        return True
    env = os.environ.get('SELECTIVE_MIRROR_DEBUG') or os.environ.get('UM_DEBUG') or ''
    return env.strip().lower() in ('1', 'true', 'yes', 'on')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='cmd')

    sp = sub.add_parser('materialize')
    sp.add_argument('--plan', required=True)
    sp.add_argument('--selective-root', required=True)
    sp.add_argument('--no-download', action='store_true')
    sp.add_argument('--no-sign', action='store_true')
    sp.add_argument(
        '--allow-resume', action='store_true',
        help='Reuse PASS staging when plan/discovery provenance matches',
    )
    sp.add_argument(
        '--hop', default='',
        help='Limit materialize + provenance to one hop (e.g. xenial-to-bionic)',
    )
    sp.add_argument(
        '--reuse-root', action='append', default=[],
        help='Extra immutable roots for SHA256-verified reuse (repeatable)',
    )
    sp.add_argument(
        '--debug', action='store_true',
        help='print full traceback on failure (or set SELECTIVE_MIRROR_DEBUG=1)',
    )

    sp = sub.add_parser('quarantine-staging')
    sp.add_argument('--selective-root', required=True)
    sp.add_argument('--evidence-dir', default='')
    sp.add_argument(
        '--receipt', default='',
        help='Expected materialize receipt path (default: state/materialize.json)',
    )

    sp = sub.add_parser('publish')
    sp.add_argument('--selective-root', required=True)
    sp.add_argument('--allow-unverified', action='store_true')
    sp.add_argument('--plan', default='')
    sp.add_argument('--http-base', default='http://127.0.0.1')
    sp.add_argument(
        '--skip-post-publish', action='store_true',
        help='Skip post-publish HTTP smoke (tests only; not for production)',
    )
    sp.add_argument(
        '--skip-nginx-preflight', action='store_true',
        help='Skip selective nginx root preflight (tests only; not for production)',
    )

    sp = sub.add_parser('rollback-publish')
    sp.add_argument('--selective-root', required=True)

    sp = sub.add_parser('status')
    sp.add_argument('--selective-root', required=True)
    sp.add_argument('--plan', default='')

    args = parser.parse_args(argv)
    debug = _debug_enabled(getattr(args, 'debug', False))
    try:
        if args.cmd == 'materialize':
            result = materialize(
                args.plan, args.selective_root,
                allow_download=not args.no_download,
                sign=not args.no_sign,
                allow_resume=bool(getattr(args, 'allow_resume', False)),
                hop=(getattr(args, 'hop', '') or None),
                extra_reuse_roots=list(getattr(args, 'reuse_root', None) or []),
            )
            print(json.dumps(result, indent=2))
            return 0
        if args.cmd == 'quarantine-staging':
            result = quarantine_mismatch_staging(
                args.selective_root,
                expected_receipt_path=(getattr(args, 'receipt', '') or None),
                evidence_dir=(getattr(args, 'evidence_dir', '') or None),
            )
            print(json.dumps(result, indent=2))
            return 0
        if args.cmd == 'publish':
            result = atomic_publish(
                args.selective_root,
                require_verify_pass=not args.allow_unverified,
                http_base=args.http_base,
                run_post_publish=not args.skip_post_publish,
                plan_path=args.plan or None,
                run_nginx_preflight=not args.skip_nginx_preflight,
            )
            print(json.dumps(result, indent=2))
            return 0
        if args.cmd == 'rollback-publish':
            result = rollback_publish(args.selective_root)
            print(json.dumps(result, indent=2))
            return 0
        if args.cmd == 'status':
            result = status_report(args.selective_root, args.plan or None)
            print(json.dumps(result, indent=2))
            return 0
    except SelectiveProvenanceError as err:
        eprint('%s: %s' % (err.error_code, err.message))
        for item in err.mismatches:
            if isinstance(item, dict):
                eprint(
                    'mismatch field=%s expected=%s actual=%s'
                    % (item.get('field'), item.get('expected'), item.get('actual'))
                )
            else:
                eprint('mismatch=%s' % item)
        for key, val in (err.context or {}).items():
            if key in ('mismatches',) or isinstance(val, (list, dict)):
                continue
            eprint('%s=%s' % (key, val))
        if debug:
            raise
        return 4
    except SelectiveDownloadError as err:
        print_download_error(err)
        failed_path = os.path.join(
            getattr(args, 'selective_root', '') or '',
            'state', FAILED_DOWNLOADS_NAME,
        )
        if failed_path and os.path.isfile(failed_path):
            eprint('failed_downloads_json=%s' % failed_path)
        if debug:
            raise
        return 2
    except SelectivePublishError as err:
        eprint('%s: %s' % (err.error_code, err.message))
        for key, val in (err.context or {}).items():
            if key in ('http_results', 'tested_endpoints', 'post_publish', 'gates'):
                continue
            if isinstance(val, (list, dict)) and key == 'errors':
                for item in val:
                    eprint('ERROR: %s' % item)
            elif not isinstance(val, (list, dict)):
                eprint('%s=%s' % (key, val))
        if debug:
            raise
        return 3
    except Exception as exc:
        eprint('SELECTIVE_MIRROR_ERROR: %s: %s' % (type(exc).__name__, exc))
        if debug:
            raise
        return 1
    parser.print_help()
    return 1


if __name__ == '__main__':
    sys.exit(main())
