#!/usr/bin/env bash
# tests/test_http_enable_local_smoke.sh — isolated nginx smoke for /client and /dp-phase2.
# Uses a high port + temp nginx config. Does not modify production nginx.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

if ! command -v nginx >/dev/null 2>&1; then
  echo "SKIP: nginx not installed"
  exit 0
fi

WORKDIR="$(mktemp -d)"
chmod 0755 "$WORKDIR"
NGINX_PID=""
cleanup() {
  if [[ -n "${NGINX_PID:-}" ]]; then
    kill "$NGINX_PID" 2>/dev/null || true
    wait "$NGINX_PID" 2>/dev/null || true
  fi
  # Prefer nginx -s stop when pid file exists
  if [[ -f "${WORKDIR}/nginx.pid" ]]; then
    nginx -s stop -c "${WORKDIR}/nginx.conf" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# shellcheck source=../scripts/lib/http_publication_permissions.sh
source "${ROOT}/scripts/lib/http_publication_permissions.sh"

SPOOL="${WORKDIR}/spool"
CLIENT="${SPOOL}/client"
DP="${SPOOL}/dp-phase2/6.6.0"
PORT=18765
mkdir -p "$CLIENT" "$DP" "${WORKDIR}/logs" "${WORKDIR}/tmp" "${WORKDIR}/body"

# Fixture content
printf '#!/bin/bash\necho stage\n' >"${CLIENT}/stage-dp-phase2.sh"
chmod 0755 "${CLIENT}/stage-dp-phase2.sh"
( cd "$CLIENT" && sha256sum stage-dp-phase2.sh >stage-dp-phase2.sh.sha256 )
printf 'TARGET_DP_VERSION=6.6.0\n' >"${DP}/release.env"
printf 'bundle-bytes\n' >"${DP}/dp_bundle_6.6.0-current.tar"
( cd "$DP" && sha256sum dp_bundle_6.6.0-current.tar >dp_bundle_6.6.0-current.tar.sha256 )
chmod 0755 "$SPOOL" "$CLIENT" "$(dirname "$DP")" "$DP"
chmod 0644 "${CLIENT}/stage-dp-phase2.sh.sha256" "${DP}/release.env" \
  "${DP}/dp_bundle_6.6.0-current.tar" "${DP}/dp_bundle_6.6.0-current.tar.sha256"

write_nginx_conf() {
  local use_www_data="${1:-0}"
  local user_line=""
  if [[ "$use_www_data" == "1" ]]; then
    user_line="user www-data;"
  fi
  cat >"${WORKDIR}/nginx.conf" <<EOF
${user_line}
worker_processes 1;
error_log ${WORKDIR}/logs/error.log;
pid ${WORKDIR}/nginx.pid;
events { worker_connections 64; }
http {
  access_log ${WORKDIR}/logs/access.log;
  client_body_temp_path ${WORKDIR}/tmp;
  proxy_temp_path ${WORKDIR}/tmp;
  fastcgi_temp_path ${WORKDIR}/tmp;
  uwsgi_temp_path ${WORKDIR}/tmp;
  scgi_temp_path ${WORKDIR}/tmp;
  server {
    listen 127.0.0.1:${PORT};
    server_name _;
    location /client/ {
      alias ${CLIENT}/;
      autoindex off;
    }
    location /dp-phase2/6.6.0/ {
      alias ${DP}/;
      autoindex off;
    }
  }
}
EOF
}

start_nginx() {
  local as_root="${1:-0}"
  NGINX_PID=""
  if [[ "$as_root" == "1" ]]; then
    sudo -n nginx -c "${WORKDIR}/nginx.conf"
  else
    nginx -c "${WORKDIR}/nginx.conf"
  fi
  sleep 0.4
}

stop_nginx() {
  if [[ -f "${WORKDIR}/nginx.pid" ]]; then
    if [[ -f "${WORKDIR}/.nginx_root" ]]; then
      sudo -n nginx -s stop -c "${WORKDIR}/nginx.conf" 2>/dev/null || true
    else
      nginx -s stop -c "${WORKDIR}/nginx.conf" 2>/dev/null || true
    fi
  fi
  sleep 0.2
  rm -f "${WORKDIR}/.nginx_root"
}

# --- Bad case: 0700 client root ---
chmod 0700 "$CLIENT"
# Filesystem-level denial for www-data (authoritative for the 403 root cause)
set +e
runuser -u www-data -- test -r "${CLIENT}/stage-dp-phase2.sh" 2>/dev/null
ru_rc=$?
set -e
if [[ "$ru_rc" -ne 0 ]]; then
  pass "0700 fixture: www-data cannot read (permission denial reproduced)"
else
  fail "0700 fixture: www-data unexpectedly can read"
fi

# HTTP 403 when nginx runs as www-data (requires sudo for user directive)
if sudo -n true 2>/dev/null; then
  write_nginx_conf 1
  if sudo -n nginx -t -c "${WORKDIR}/nginx.conf" >/dev/null 2>&1; then
    touch "${WORKDIR}/.nginx_root"
    start_nginx 1
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
      "http://127.0.0.1:${PORT}/client/stage-dp-phase2.sh" || echo 000)"
    if [[ "$code" == "403" ]]; then
      pass "0700 fixture yields HTTP 403"
    else
      fail "0700 fixture expected 403, got ${code}"
    fi
    stop_nginx
  else
    echo "  SKIP: nginx -t with user www-data failed"
  fi
else
  echo "  SKIP: no passwordless sudo for www-data nginx 403 HTTP probe"
fi

# --- Good case: normalize → 200 ---
mm_normalize_http_public_tree_permissions "$CLIENT" client
mm_normalize_http_public_tree_permissions "$(dirname "$DP")" phase2
chmod 0755 "$SPOOL"
[[ "$(stat -c '%a' "$CLIENT")" == "755" ]] && pass "normalized client root 0755" || fail "client mode"

if sudo -n true 2>/dev/null; then
  write_nginx_conf 1
  touch "${WORKDIR}/.nginx_root"
  start_nginx 1
else
  write_nginx_conf 0
  if ! nginx -t -c "${WORKDIR}/nginx.conf" >/dev/null 2>&1; then
    echo "SKIP: nginx -t failed in this environment"
    exit 0
  fi
  start_nginx 0
fi

probe() {
  local path="$1"
  local c
  c="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}${path}" || echo 000)"
  if [[ "$c" == "200" ]]; then
    pass "GET ${path} → 200"
  else
    fail "GET ${path} → ${c}"
  fi
}

probe "/client/stage-dp-phase2.sh"
probe "/client/stage-dp-phase2.sh.sha256"
probe "/dp-phase2/6.6.0/release.env"
probe "/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar.sha256"

if mm_verify_http_access_as_nginx_user "${CLIENT}/stage-dp-phase2.sh"; then
  pass "HTTP_LOCAL_SMOKE nginx-user read PASS"
else
  fail "nginx-user read after normalize"
fi

stop_nginx

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_http_enable_local_smoke PASS ==="
else
  echo "=== test_http_enable_local_smoke FAIL ==="
  tail -20 "${WORKDIR}/logs/error.log" 2>/dev/null || true
fi
exit "$FAIL"
