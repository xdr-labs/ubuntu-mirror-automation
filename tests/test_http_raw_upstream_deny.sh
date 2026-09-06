#!/usr/bin/env bash
# HTTP negative probes: raw upstream and private config/key/state must not be 200.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

if ! command -v nginx >/dev/null 2>&1; then
  echo "SKIP: nginx not installed"
  exit 0
fi

WORKDIR="$(mktemp -d)"
chmod 0755 "$WORKDIR"
NGINX_PID=""
cleanup() {
  if [[ -f "${WORKDIR}/nginx.pid" ]]; then
    nginx -s stop -c "${WORKDIR}/nginx.conf" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# shellcheck source=/dev/null
source "${ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/config.sh"

SPOOL="${WORKDIR}/spool"
um_load_config "${ROOT}/mirror.conf"
export BASE_PATH="$SPOOL"
export SELECTIVE_MIRROR_ROOT="${SPOOL}/selective"
export DP_PHASE2_ROOT="${SPOOL}/dp-phase2"
export DP_PHASE2_VERSION=6.6.0
PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)"

mkdir -p "${SPOOL}/selective/ubuntu" "${SPOOL}/selective/shared/offline" \
  "${SPOOL}/selective/keys" "${SPOOL}/client" "${SPOOL}/dp-phase2/6.6.0" \
  "${WORKDIR}/logs" "${WORKDIR}/tmp"
printf 'TARGET_DP_VERSION=6.6.0\n' >"${SPOOL}/dp-phase2/6.6.0/release.env"
printf 'bundle\n' >"${SPOOL}/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar"
( cd "${SPOOL}/dp-phase2/6.6.0" && sha256sum dp_bundle_6.6.0-current.tar \
  >dp_bundle_6.6.0-current.tar.sha256 )
# Legacy public leak fixture — nginx must still deny it.
printf 'RAW-UPSTREAM-SECRET\n' \
  >"${SPOOL}/dp-phase2/6.6.0/bringup_py3_dp_after_os_upgrade.sh.upstream"
printf 'deadbeef\n' \
  >"${SPOOL}/dp-phase2/6.6.0/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1"
printf 'PRIVATE-KEY\n' >"${SPOOL}/client/private.gpg"
chmod 0755 "$SPOOL" "${SPOOL}/selective" "${SPOOL}/client" \
  "${SPOOL}/dp-phase2" "${SPOOL}/dp-phase2/6.6.0"
chmod 0644 "${SPOOL}/dp-phase2/6.6.0/"*

um_generate_nginx_conf >"${WORKDIR}/site.conf"
# Bind the isolated smoke server to a high port; drop IPv6 listen lines so
# they cannot become a duplicate 127.0.0.1:PORT in the same server block.
sed -i \
  -e '/listen \[::\]/d' \
  -e "s/listen[[:space:]]*[0-9]*[^;]*;/listen 127.0.0.1:${PORT};/g" \
  -e "s|/var/log/nginx/apt-mirror-access.log|${WORKDIR}/logs/access.log|g" \
  -e "s|/var/log/nginx/apt-mirror-error.log|${WORKDIR}/logs/error.log|g" \
  "${WORKDIR}/site.conf"

cat >"${WORKDIR}/nginx.conf" <<EOF
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
  include ${WORKDIR}/site.conf;
}
EOF

nginx -c "${WORKDIR}/nginx.conf" || fail "nginx start"
sleep 0.3
base="http://127.0.0.1:${PORT}"

probe_code() {
  curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 "$1" || echo 000
}

code="$(probe_code "${base}/dp-phase2/6.6.0/release.env")"
[[ "$code" == "200" ]] || fail "positive release.env want=200 got=${code}"
pass "HTTP positive publication path still 200"

code="$(probe_code "${base}/dp-phase2/6.6.0/bringup_py3_dp_after_os_upgrade.sh.upstream")"
[[ "$code" == "403" || "$code" == "404" ]] \
  || fail "raw upstream want=403/404 got=${code}"
pass "HTTP raw upstream negative probe ${code}"

code="$(probe_code "${base}/dp-phase2/6.6.0/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1")"
[[ "$code" == "403" || "$code" == "404" ]] \
  || fail "raw upstream sha1 want=403/404 got=${code}"
pass "HTTP raw upstream sidecar negative probe ${code}"

code="$(probe_code "${base}/client/private.gpg")"
[[ "$code" == "403" || "$code" == "404" ]] \
  || fail "private key want=403/404 got=${code}"
pass "HTTP private key negative probe ${code}"

code="$(probe_code "${base}/config/dp-upgrade-mirror.conf")"
[[ "$code" == "403" || "$code" == "404" ]] \
  || fail "private config want=403/404 got=${code}"
pass "HTTP private config negative probe ${code}"

code="$(probe_code "${base}/workflow.state")"
[[ "$code" == "403" || "$code" == "404" ]] \
  || fail "workflow.state want=403/404 got=${code}"
pass "HTTP workflow state negative probe ${code}"

code="$(probe_code "${base}/acps-credentials")"
[[ "$code" == "403" || "$code" == "404" ]] \
  || fail "acps-credentials want=403/404 got=${code}"
pass "HTTP credential negative probe ${code}"

code="$(probe_code "${base}/r2-credentials")"
[[ "$code" == "403" || "$code" == "404" ]] \
  || fail "r2-credentials want=403/404 got=${code}"
code="$(probe_code "${base}/rclone.conf")"
[[ "$code" == "403" || "$code" == "404" ]] \
  || fail "rclone.conf want=403/404 got=${code}"
pass "HTTP R2 credential/config negative probe"

code="$(probe_code "${base}/.install-cache/")"
[[ "$code" == "403" || "$code" == "404" ]] \
  || fail "cache want=403/404 got=${code}"
pass "HTTP cache negative probe ${code}"

# Readiness helper must FAIL closed on HTTP 200 for a sensitive name.
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
export MM_VERIFY_HTTP_BASE="$base"
export TARGET_DP_VERSION=6.6.0
if mm_http_probe_denied "${base}/dp-phase2/6.6.0/bringup_py3_dp_after_os_upgrade.sh.upstream"; then
  pass "mm_http_probe_denied rejects exposed raw upstream"
else
  fail "mm_http_probe_denied unexpectedly passed for denied upstream"
fi
if mm_http_probe_ok "${base}/dp-phase2/6.6.0/bringup_py3_dp_after_os_upgrade.sh.upstream"; then
  fail "mm_http_probe_ok must not treat raw upstream as public 200"
fi
pass "readiness negative probe contract"

echo "ALL test_http_raw_upstream_deny checks passed"
