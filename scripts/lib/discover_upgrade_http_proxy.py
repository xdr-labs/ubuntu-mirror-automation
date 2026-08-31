#!/usr/bin/env python3
"""Minimal HTTP forward proxy that logs APT/do-release-upgrade requests.

Streams upstream HTTP 200 bodies to the client while atomically capturing a
durable recorder copy (URL-hash keyed). Compatible with Python 3.5+.
"""
from __future__ import print_function

import sys

if sys.version_info < (3, 5):
    sys.stderr.write(
        'ERROR: discover_upgrade_http_proxy.py requires Python 3.5+\n'
        'Found: Python {}.{}.{}\n'.format(
            sys.version_info[0], sys.version_info[1], sys.version_info[2]
        )
    )
    sys.exit(2)

import argparse
import hashlib
import json
import os
import select
import socket
import tempfile
import threading
import time
from http.client import HTTPConnection, HTTPSConnection
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import urlparse

SELFTEST_PREFIX = '/dur-recorder-self-test/'
REDIRECT_STATUSES = (301, 302, 303, 307, 308)


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def utc_ts():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def url_storage_key(url):
    """Collision-free storage key derived from the request URL."""
    return hashlib.sha256(url.encode('utf-8', 'surrogateescape')).hexdigest()


def object_paths(cache_dir, url):
    """Return (final_path, meta_path) under URL-hash directories."""
    key = url_storage_key(url)
    d1, d2 = key[0:2], key[2:4]
    directory = os.path.join(cache_dir, d1, d2)
    final_path = os.path.join(directory, key)
    meta_path = final_path + '.meta.json'
    return (final_path, meta_path, key)


def header_map(headers):
    out = {}
    for k, v in headers:
        out[k.lower()] = v
    return out


def content_length_of(headers):
    if isinstance(headers, dict):
        hm = {k.lower(): v for k, v in headers.items()}
    else:
        hm = header_map(headers or [])
    raw = hm.get('content-length')
    if raw is None or raw == '':
        return None
    try:
        return int(raw)
    except ValueError:
        return None


class Recorder(object):

    def __init__(self, log_path, cache_dir):
        self.log_path = log_path
        self.cache_dir = cache_dir
        self.lock = threading.Lock()
        if not os.path.isdir(self.cache_dir):
            os.makedirs(self.cache_dir)
        parent = os.path.dirname(self.log_path)
        if parent and not os.path.isdir(parent):
            os.makedirs(parent)

    def write(self, line):
        with self.lock:
            with open(self.log_path, 'a', encoding='utf-8', errors='surrogateescape') as f:
                f.write(line.rstrip() + '\n')
                f.flush()
                try:
                    os.fsync(f.fileno())
                except Exception:
                    pass

    def log_request(
            self, method, original, final, status, size,
            sha256='', local_path='', redirect_chain=None, content_length=None):
        parts = [utc_ts(), method, original, str(status), str(size if size >= 0 else '-')]
        if final and final != original:
            parts.append('final={}'.format(final))
        if redirect_chain:
            parts.append('redirects={}'.format('->'.join(redirect_chain)))
        if content_length is not None:
            parts.append('content_length={}'.format(content_length))
        if sha256:
            parts.append('sha256={}'.format(sha256))
        if local_path:
            parts.append('local_path={}'.format(local_path))
        self.write(' '.join(parts))

    def log_redirect(self, original, final, status):
        self.write('{} REDIRECT {} -> {} {}'.format(utc_ts(), original, final, status))

    def atomic_capture(self, storage_url, body_path_tmp, size, sha256, meta):
        """fsync temp body, write sidecar, atomic rename into URL-hash path."""
        final_path, meta_path, _key = object_paths(self.cache_dir, storage_url)
        directory = os.path.dirname(final_path)
        if not os.path.isdir(directory):
            os.makedirs(directory)
        # fsync body
        with open(body_path_tmp, 'rb') as fh:
            try:
                os.fsync(fh.fileno())
            except Exception:
                pass
        meta = dict(meta)
        meta['local_path'] = final_path
        meta['size_bytes'] = size
        meta['sha256'] = sha256
        meta['captured_at'] = utc_ts()
        meta_tmp = meta_path + '.tmp.' + str(os.getpid())
        with open(meta_tmp, 'w', encoding='utf-8') as mf:
            json.dump(meta, mf, indent=2, sort_keys=True)
            mf.write('\n')
            mf.flush()
            try:
                os.fsync(mf.fileno())
            except Exception:
                pass
        os.replace(body_path_tmp, final_path)
        os.replace(meta_tmp, meta_path)
        # Best-effort directory fsync
        try:
            dirfd = os.open(directory, os.O_DIRECTORY)
            try:
                os.fsync(dirfd)
            finally:
                os.close(dirfd)
        except Exception:
            pass
        return final_path


RECORDER = None


def _selftest_marker_from_path(path):
    """Return marker if path is a recorder self-test URI (relative or absolute)."""
    if path.startswith(SELFTEST_PREFIX):
        return path[len(SELFTEST_PREFIX):].split('?', 1)[0]
    if path.startswith('http://') or path.startswith('https://'):
        parsed = urlparse(path)
        if parsed.path.startswith(SELFTEST_PREFIX):
            return parsed.path[len(SELFTEST_PREFIX):].split('?', 1)[0]
    return None


class ProxyHandler(BaseHTTPRequestHandler):
    # HTTP/1.0 avoids keep-alive quirks on Python 3.5 ThreadingMixIn.
    protocol_version = 'HTTP/1.0'

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        self._dispatch()

    def do_HEAD(self):
        self._dispatch()

    def do_POST(self):
        self._dispatch()

    def do_CONNECT(self):
        # CONNECT is accepted for compatibility, but full HTTPS URLs / .deb bodies
        # cannot be recorded through an opaque tunnel. APT discovery installs
        # Acquire::https::Proxy "DIRECT" and must not claim HTTPS capture support.
        host_port = self.path
        if RECORDER:
            RECORDER.write(
                '{} CONNECT https://{}/ 200 - note=https_path_not_recorded'.format(
                    utc_ts(), host_port))
        try:
            host, port_s = host_port.split(':')
            port = int(port_s)
        except ValueError:
            self.send_error(400, 'bad CONNECT target')
            return
        try:
            upstream = socket.create_connection((host, port), timeout=60)
        except OSError:
            self.send_error(502, 'upstream connect failed')
            return
        self.send_response(200, 'Connection Established')
        self.end_headers()
        self._tunnel(self.connection, upstream)

    def _tunnel(self, client, upstream):
        sockets = [client, upstream]
        try:
            while True:
                r, _, _ = select.select(sockets, [], [], 60)
                if not r:
                    break
                for s in r:
                    other = upstream if s is client else client
                    data = s.recv(65536)
                    if not data:
                        return
                    other.sendall(data)
        finally:
            try:
                upstream.close()
            except Exception:
                pass

    def _dispatch(self):
        assert RECORDER is not None
        # Trace every request immediately so self-test can detect contact.
        RECORDER.write('{} TRACE {} {}'.format(utc_ts(), self.command, self.path))
        marker = _selftest_marker_from_path(self.path)
        if marker is not None:
            self._handle_selftest(marker)
            return
        self._proxy()

    def _handle_selftest(self, marker):
        """Answer locally - no upstream. Guarantees an access-log line on Xenial."""
        body = b'ok'
        original = self.path
        if not original.startswith('http://') and not original.startswith('https://'):
            original = 'http://127.0.0.1{0}{1}'.format(SELFTEST_PREFIX, marker)
        RECORDER.log_request(self.command, original, original, 200, len(body))
        try:
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Connection', 'close')
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(body)
        except Exception:
            pass

    def _proxy(self):
        method = self.command
        url = self.path
        if not url.startswith('http://') and (not url.startswith('https://')):
            self.send_error(400, 'absolute URL required')
            return
        original = url
        body = b''
        length = int(self.headers.get('Content-Length', '0') or '0')
        if length > 0:
            body = self.rfile.read(length)

        result = self._open_final(method, url, body)
        final_url, status, resp_headers, resp, conn, redirects = result
        chain_urls = [original]
        for _src, dst, st in redirects:
            RECORDER.log_redirect(_src, dst, st)
            chain_urls.append(dst)
        # Unique ordered chain including final
        redirect_chain = []
        for u in chain_urls:
            if not redirect_chain or redirect_chain[-1] != u:
                redirect_chain.append(u)
        if final_url and (not redirect_chain or redirect_chain[-1] != final_url):
            redirect_chain.append(final_url)

        clen = content_length_of(resp_headers)
        try:
            # HTTP 304 / HEAD: discovery needs a stored body for mutable metadata
            # (esp. InRelease). On 304 with no prior capture, re-fetch once with
            # an unconditional GET and capture that body, while still answering
            # the client.
            if status == 304 and method == 'GET':
                stored_path, _meta, _key = object_paths(RECORDER.cache_dir, original)
                if not os.path.isfile(stored_path):
                    # Close the 304 response and retry upstream unconditionally.
                    try:
                        resp.read()
                    except Exception:
                        pass
                    try:
                        resp.close()
                    except Exception:
                        pass
                    try:
                        conn.close()
                    except Exception:
                        pass
                    # Rebuild request without conditional validators (already
                    # stripped in _open_final) — force a fresh GET.
                    result = self._open_final('GET', url, b'')
                    final_url, status, resp_headers, resp, conn, redirects2 = result
                    for _src, dst, st in redirects2:
                        RECORDER.log_redirect(_src, dst, st)
                    clen = content_length_of(resp_headers)
                    if status == 200:
                        sha, local_path, size = self._stream_and_capture(
                            resp, status, resp_headers, clen, method,
                            storage_url=original,
                            meta={
                                'original_url': original,
                                'final_url': final_url,
                                'redirect_chain': redirect_chain,
                                'http_status': status,
                                'content_length': clen,
                                'recovered_from_http_304': True,
                            })
                        RECORDER.log_request(
                            method, original, final_url, status, size,
                            sha256=sha, local_path=local_path,
                            redirect_chain=redirect_chain if len(redirect_chain) > 1 else None,
                            content_length=clen if clen is not None else size)
                        return
                    # Fall through: relay non-200 / still-304 without capture.
                else:
                    # Prior body exists — treat as success using stored object.
                    try:
                        size = os.path.getsize(stored_path)
                    except OSError:
                        size = 0
                    self._send_headers_only(200, resp_headers, size)
                    try:
                        with open(stored_path, 'rb') as fh:
                            while True:
                                chunk = fh.read(65536)
                                if not chunk:
                                    break
                                self.wfile.write(chunk)
                    except Exception:
                        pass
                    RECORDER.log_request(
                        method, original, final_url, 200, size,
                        local_path=stored_path,
                        redirect_chain=redirect_chain if len(redirect_chain) > 1 else None,
                        content_length=size)
                    return

            if method == 'HEAD' or status == 304:
                self._send_headers_only(status, resp_headers, clen)
                RECORDER.log_request(
                    method, original, final_url, status, 0,
                    redirect_chain=redirect_chain if len(redirect_chain) > 1 else None,
                    content_length=clen)
                return

            if status != 200:
                # Non-200: stream/discard without durable capture.
                size = self._relay_no_capture(resp, status, resp_headers, clen, method)
                RECORDER.log_request(
                    method, original, final_url, status, size,
                    redirect_chain=redirect_chain if len(redirect_chain) > 1 else None,
                    content_length=clen)
                return

            sha, local_path, size = self._stream_and_capture(
                resp, status, resp_headers, clen, method,
                storage_url=original,
                meta={
                    'original_url': original,
                    'final_url': final_url,
                    'redirect_chain': redirect_chain,
                    'http_status': status,
                    'content_length': clen,
                })
            RECORDER.log_request(
                method, original, final_url, status, size,
                sha256=sha, local_path=local_path,
                redirect_chain=redirect_chain if len(redirect_chain) > 1 else None,
                content_length=clen if clen is not None else size)
        finally:
            try:
                resp.close()
            except Exception:
                pass
            try:
                conn.close()
            except Exception:
                pass

    def _send_headers_only(self, status, resp_headers, clen):
        try:
            self.send_response(status)
            for k, v in resp_headers:
                lk = k.lower()
                if lk in ('transfer-encoding', 'connection', 'content-length'):
                    continue
                self.send_header(k, v)
            if clen is not None:
                self.send_header('Content-Length', str(clen))
            else:
                self.send_header('Content-Length', '0')
            self.send_header('Connection', 'close')
            self.end_headers()
        except Exception:
            pass

    def _relay_no_capture(self, resp, status, resp_headers, clen, method):
        size = 0
        try:
            self.send_response(status)
            for k, v in resp_headers:
                lk = k.lower()
                if lk in ('transfer-encoding', 'connection', 'content-length'):
                    continue
                self.send_header(k, v)
            # Buffer small error bodies so Content-Length is exact.
            data = resp.read() if method != 'HEAD' else b''
            size = len(data or b'')
            self.send_header('Content-Length', str(size))
            self.send_header('Connection', 'close')
            self.end_headers()
            if method != 'HEAD' and data:
                self.wfile.write(data)
        except Exception:
            pass
        return size

    def _stream_and_capture(self, resp, status, resp_headers, clen, method,
                            storage_url, meta):
        """Stream body to client while writing a temp recorder file; atomic commit."""
        tmp_dir = os.path.join(RECORDER.cache_dir, '.tmp')
        if not os.path.isdir(tmp_dir):
            os.makedirs(tmp_dir)
        fd, tmp_path = tempfile.mkstemp(prefix='dur-cap-', dir=tmp_dir)
        os.close(fd)
        hasher = hashlib.sha256()
        size = 0
        complete = True
        sha = ''
        local_path = ''
        headers_sent = False
        try:
            self.send_response(status)
            for k, v in resp_headers:
                lk = k.lower()
                if lk in ('transfer-encoding', 'connection', 'content-length'):
                    continue
                self.send_header(k, v)
            # Prefer upstream Content-Length when present; otherwise omit until done
            # is awkward for HTTP/1.0 — buffer if unknown would break streaming.
            # We stream and set Content-Length only when known.
            if clen is not None:
                self.send_header('Content-Length', str(clen))
            self.send_header('Connection', 'close')
            self.end_headers()
            headers_sent = True

            with open(tmp_path, 'wb') as tmp_fh:
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    tmp_fh.write(chunk)
                    hasher.update(chunk)
                    size += len(chunk)
                    try:
                        self.wfile.write(chunk)
                    except Exception:
                        # Client gone — keep reading upstream to finish capture.
                        pass
                tmp_fh.flush()
                try:
                    os.fsync(tmp_fh.fileno())
                except Exception:
                    pass

            if clen is not None and size != clen:
                complete = False

            if complete:
                sha = hasher.hexdigest()
                meta = dict(meta)
                meta['content_length'] = clen if clen is not None else size
                local_path = RECORDER.atomic_capture(
                    storage_url, tmp_path, size, sha, meta)
                tmp_path = ''  # ownership transferred
            else:
                sha = ''
                local_path = ''
        except Exception:
            complete = False
            if not headers_sent:
                try:
                    self.send_error(502, 'upstream stream failed')
                except Exception:
                    pass
        finally:
            if tmp_path and os.path.exists(tmp_path):
                try:
                    os.unlink(tmp_path)
                except Exception:
                    pass
        return (sha, local_path, size)

    def _open_final(self, method, url, body):
        redirects = []
        current = url
        for _ in range(8):
            parsed = urlparse(current)
            if parsed.scheme == 'https':
                conn = HTTPSConnection(parsed.hostname, parsed.port or 443, timeout=120)
            else:
                conn = HTTPConnection(parsed.hostname, parsed.port or 80, timeout=120)
            path = parsed.path or '/'
            if parsed.query:
                path += '?' + parsed.query
            headers = {k: v for k, v in self.headers.items()
                       if k.lower() not in (
                           'proxy-connection', 'host',
                           # Discovery must capture durable bodies. Conditional
                           # validators cause upstream HTTP 304 with no body and
                           # force a later repair-hop; strip them on the normal path.
                           'if-none-match', 'if-modified-since', 'if-range',
                       )}
            headers['Host'] = parsed.netloc
            # Prefer a cache-busting identity encoding so mutable metadata
            # (InRelease) is always returned with a body.
            headers.setdefault('Cache-Control', 'no-cache')
            headers.setdefault('Pragma', 'no-cache')
            try:
                conn.request(
                    method, path,
                    body=body if method in ('POST', 'PUT') else None,
                    headers=headers)
                resp = conn.getresponse()
            except Exception:
                try:
                    conn.close()
                except Exception:
                    pass
                if RECORDER:
                    RECORDER.write('{} ERROR upstream_connect {}'.format(utc_ts(), current))
                return (current, 502, [], _EmptyResp(), _NullConn(), redirects)

            status = resp.status
            resp_headers = resp.getheaders()
            if status in REDIRECT_STATUSES:
                loc = dict(resp_headers).get('Location') or dict(
                    ((k.lower(), v) for k, v in resp_headers)).get('location')
                # Drain redirect body
                try:
                    resp.read()
                except Exception:
                    pass
                try:
                    conn.close()
                except Exception:
                    pass
                if not loc:
                    return (current, status, resp_headers, _EmptyResp(), _NullConn(), redirects)
                if loc.startswith('/'):
                    loc = '{}://{}{}'.format(parsed.scheme, parsed.netloc, loc)
                redirects.append((current, loc, status))
                current = loc
                if status == 303:
                    method = 'GET'
                    body = b''
                continue
            return (current, status, resp_headers, resp, conn, redirects)

        if RECORDER:
            RECORDER.write('{} ERROR redirect_loop {}'.format(utc_ts(), url))
        return (current, 508, [], _EmptyResp(), _NullConn(), redirects)


class _EmptyResp(object):
    status = 502

    def read(self, n=-1):
        return b''

    def close(self):
        return

    def getheaders(self):
        return []


class _NullConn(object):
    def close(self):
        return


def main():
    global RECORDER
    ap = argparse.ArgumentParser()
    ap.add_argument('--listen', default='127.0.0.1')
    ap.add_argument('--port', type=int, default=18080)
    ap.add_argument('--log', required=True)
    ap.add_argument('--cache-dir', required=True)
    args = ap.parse_args()
    RECORDER = Recorder(args.log, args.cache_dir)
    # Bind first; only then announce readiness in the access log.
    httpd = ThreadingHTTPServer((args.listen, args.port), ProxyHandler)
    RECORDER.write(
        '# discover-upgrade-http-proxy started %s on %s:%s' % (
            utc_ts(), args.listen, args.port))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
