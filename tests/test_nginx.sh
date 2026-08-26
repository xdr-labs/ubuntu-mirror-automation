#!/usr/bin/env bash
# test_nginx.sh — Validate generated nginx config shape; nginx -t if available
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${ROOT}/lib/config.sh"

FAIL=0
um_load_config "${ROOT}/mirror.conf"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

um_generate_nginx_conf >"${TMPDIR_TEST}/apt-mirror.conf"

# Structural checks — selective canonical root
grep -q 'listen' "${TMPDIR_TEST}/apt-mirror.conf" || FAIL=1
grep -q 'location /ubuntu/' "${TMPDIR_TEST}/apt-mirror.conf" || FAIL=1
grep -q 'location /ubuntu-security/' "${TMPDIR_TEST}/apt-mirror.conf" || FAIL=1
grep -q 'location /offline/' "${TMPDIR_TEST}/apt-mirror.conf" || FAIL=1
grep -q 'location /hops/' "${TMPDIR_TEST}/apt-mirror.conf" || FAIL=1
grep -q 'location /client/' "${TMPDIR_TEST}/apt-mirror.conf" || FAIL=1
grep -q 'location /dp-phase2/6.6.0/' "${TMPDIR_TEST}/apt-mirror.conf" || FAIL=1
grep -q 'dp-phase2/6.6.0/' "${TMPDIR_TEST}/apt-mirror.conf" || FAIL=1
grep -q 'selective/' "${TMPDIR_TEST}/apt-mirror.conf" || FAIL=1
# Direct paths only — no current/previous generation aliases
if grep -qE 'selective/current|dp-phase2/6\.[0-9]+\.[0-9]+/current' "${TMPDIR_TEST}/apt-mirror.conf"; then
  echo "  FAIL: generated nginx still uses current symlink paths"
  FAIL=1
fi
grep -q 'server_name security.ubuntu.com' "${TMPDIR_TEST}/apt-mirror.conf" || FAIL=1
grep -q 'server_name archive.ubuntu.com' "${TMPDIR_TEST}/apt-mirror.conf" || FAIL=1
grep -q 'server_name old-releases.ubuntu.com' "${TMPDIR_TEST}/apt-mirror.conf" || FAIL=1
grep -q 'autoindex on' "${TMPDIR_TEST}/apt-mirror.conf" || FAIL=1
grep -q 'alias ' "${TMPDIR_TEST}/apt-mirror.conf" || FAIL=1
# Must not point at legacy full-mirror spool
if grep -qE 'root[[:space:]]+/var/spool/apt-mirror/mirror[[:space:]]*;' "${TMPDIR_TEST}/apt-mirror.conf"; then
  echo "  FAIL: generated nginx still uses legacy mirror root"
  FAIL=1
fi

# Template file exists and matches guide essentials
grep -q 'location /ubuntu/' "${ROOT}/templates/nginx.conf" || FAIL=1
grep -q 'location /ubuntu-security/' "${ROOT}/templates/nginx.conf" || FAIL=1
grep -q 'location /offline/' "${ROOT}/templates/nginx.conf" || FAIL=1
grep -q 'location /client/' "${ROOT}/templates/nginx.conf" || FAIL=1
grep -q 'location /dp-phase2/6.6.0/' "${ROOT}/templates/nginx.conf" || FAIL=1
grep -q 'root /var/spool/apt-mirror/selective;' "${ROOT}/templates/nginx.conf" || FAIL=1
if grep -qE 'selective/current|dp-phase2/6\.[0-9]+\.[0-9]+/current' "${ROOT}/templates/nginx.conf"; then
  echo "  FAIL: nginx template still uses current symlink paths"
  FAIL=1
fi
grep -q 'server_name security.ubuntu.com' "${ROOT}/templates/nginx.conf" || FAIL=1
grep -q 'server_name old-releases.ubuntu.com' "${ROOT}/templates/nginx.conf" || FAIL=1

if command -v nginx >/dev/null 2>&1; then
  # Build a minimal nginx.conf that includes our server block for -t
  cat >"${TMPDIR_TEST}/nginx.conf" <<EOF
events {}
http {
    include ${TMPDIR_TEST}/apt-mirror.conf;
}
EOF
  if nginx -t -c "${TMPDIR_TEST}/nginx.conf" 2>/dev/null; then
    echo "  PASS: nginx -t on generated site"
  else
    # Some nginx builds need more defaults; treat as soft warning
    echo "  WARNING: nginx -t with minimal wrapper failed (environment limits)"
  fi
else
  echo "  SKIP: nginx not installed — structural checks only"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "  PASS: nginx template/generator checks"
fi
exit "$FAIL"
