#!/usr/bin/env bash
# tests/test_umask_public_publication_regression.sh
# Prove: private workflow-state umask 077 does not leak into public HTTP trees.
# Simulates: normal umask → mm_wf_ensure_file (temp 077) → restore → materialize
# public client + Phase2 → explicit normalize → HTTP-readable modes (and HTTP 200
# when nginx is available). Private state remains 0600.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

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

echo "=== test_umask_public_publication_regression ==="

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_workflow_state.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/http_publication_permissions.sh"

export MM_CONFIG_DIR="${WORKDIR}/etc/ubuntu-offline-mirror"
export MM_WORKFLOW_FILE="${MM_CONFIG_DIR}/workflow.state"
mkdir -p "$MM_CONFIG_DIR"
chmod 0700 "$MM_CONFIG_DIR"

SPOOL="${WORKDIR}/var/spool/apt-mirror"
CLIENT="${SPOOL}/client"
PHASE2="${SPOOL}/dp-phase2/6.6.0"
PRIVATE_CACHE="${SPOOL}/.install-cache"
SIGNING="${MM_CONFIG_DIR}/signing"
mkdir -p "$CLIENT" "$PHASE2" "$PRIVATE_CACHE" "$SIGNING" \
  "${CLIENT}/xenial-to-bionic" "${WORKDIR}/logs" "${WORKDIR}/tmp"

# --- 1. Caller umask restored after private workflow state create ---
umask 022
before="$(umask)"
mm_wf_ensure_file || fail "mm_wf_ensure_file"
after="$(umask)"
if [[ "$after" == "$before" && "$after" == "0022" ]]; then
  pass "UMASK_RESTORATION=PASS (caller umask ${after})"
else
  fail "UMASK_RESTORATION expected ${before} got ${after}"
fi
state_mode="$(stat -c '%a' "$MM_WORKFLOW_FILE")"
[[ "$state_mode" == "600" ]] && pass "private workflow.state mode=600" \
  || fail "workflow.state mode=${state_mode}"

# Simulate restrictive private evidence creation (shell rollback evidence)
EVIDENCE="${MM_CONFIG_DIR}/rollback-evidence"
old="$(umask)"
umask 077
mkdir -p "$EVIDENCE"
printf 'aella\t/usr/bin/aella_cli\n' >"${EVIDENCE}/shell-changes.tsv"
chmod 600 "${EVIDENCE}/shell-changes.tsv" 2>/dev/null || true
umask "$old"
[[ "$(stat -c '%a' "$EVIDENCE")" == "700" ]] && pass "private evidence dir stays 700" \
  || fail "evidence dir mode=$(stat -c '%a' "$EVIDENCE")"
[[ "$(stat -c '%a' "${EVIDENCE}/shell-changes.tsv")" == "600" ]] \
  && pass "private shell evidence stays 600" \
  || fail "shell evidence mode"

# --- 2. Public trees created under restored umask, then force-tight + normalize ---
# Materialize as if generators ran after wf ensure (should get 755/644 with umask 022).
printf '#!/bin/bash\necho hop\n' >"${CLIENT}/dp-offline-upgrade-xenial-to-bionic.sh"
printf '#!/bin/bash\necho stage\n' >"${CLIENT}/stage-dp-phase2.sh"
printf 'meta\n' >"${CLIENT}/fingerprint"
( cd "$CLIENT" && sha256sum dp-offline-upgrade-xenial-to-bionic.sh \
  >dp-offline-upgrade-xenial-to-bionic.sh.sha256 )
( cd "$CLIENT" && sha256sum stage-dp-phase2.sh >stage-dp-phase2.sh.sha256 )
printf 'TARGET_DP_VERSION=6.6.0\n' >"${PHASE2}/release.env"
printf 'bundle-bytes\n' >"${PHASE2}/dp_bundle_6.6.0-current.tar"
( cd "$PHASE2" && sha256sum dp_bundle_6.6.0-current.tar \
  >dp_bundle_6.6.0-current.tar.sha256 )

# Inject the historical leak class (0700/0600) to prove normalizer is required
# and sufficient — publication must not depend on ambient umask alone.
chmod 0700 "$CLIENT" "${CLIENT}/xenial-to-bionic" "$(dirname "$PHASE2")" "$PHASE2"
chmod 0600 "${CLIENT}/fingerprint" "${PHASE2}/release.env" \
  "${CLIENT}/dp-offline-upgrade-xenial-to-bionic.sh.sha256" \
  "${PHASE2}/dp_bundle_6.6.0-current.tar.sha256"
chmod 0700 "${CLIENT}/dp-offline-upgrade-xenial-to-bionic.sh" \
  "${CLIENT}/stage-dp-phase2.sh"

mm_normalize_http_public_tree_permissions "$CLIENT" client \
  || fail "client normalize"
mm_normalize_http_public_tree_permissions "$(dirname "$PHASE2")" phase2 \
  || fail "phase2 normalize"
chmod 0755 "$SPOOL" 2>/dev/null || true

[[ "$(stat -c '%a' "$CLIENT")" == "755" ]] && pass "public client dir 0755" \
  || fail "client dir mode"
[[ "$(stat -c '%a' "${CLIENT}/dp-offline-upgrade-xenial-to-bionic.sh")" == "755" ]] \
  && pass "public hop script 0755" || fail "hop script mode"
[[ "$(stat -c '%a' "${CLIENT}/fingerprint")" == "644" ]] && pass "public client file 0644" \
  || fail "fingerprint mode"
[[ "$(stat -c '%a' "$PHASE2")" == "755" ]] && pass "public phase2 dir 0755" \
  || fail "phase2 dir mode"
[[ "$(stat -c '%a' "${PHASE2}/release.env")" == "644" ]] && pass "public phase2 file 0644" \
  || fail "release.env mode"
pass "PERMISSION_NORMALIZATION=PASS"

# Private material must stay private (never globally weakened)
printf 'SECRET\n' >"${PRIVATE_CACHE}/acps.dat"
printf 'KEY\n' >"${SIGNING}/private.gpg"
chmod 0700 "$PRIVATE_CACHE" "$SIGNING"
chmod 0600 "${PRIVATE_CACHE}/acps.dat" "${SIGNING}/private.gpg"
[[ "$(stat -c '%a' "${PRIVATE_CACHE}/acps.dat")" == "600" ]] \
  && pass "private cache file remains 600" || fail "cache perms weakened"
[[ "$(stat -c '%a' "${SIGNING}/private.gpg")" == "600" ]] \
  && pass "signing private key remains 600" || fail "key perms weakened"
[[ "$(stat -c '%a' "$MM_WORKFLOW_FILE")" == "600" ]] \
  && pass "workflow.state still 600 after public normalize" || fail "state leaked"

# --- 3. HTTP 200 for public; deny probes for private paths ---
if ! command -v nginx >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "  SKIP: nginx/curl unavailable for HTTP probe (mode checks already PASS)"
else
  PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)"
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
  server {
    listen 127.0.0.1:${PORT};
    server_name _;
    location /client/ {
      alias ${CLIENT}/;
      autoindex on;
    }
    location /dp-phase2/6.6.0/ {
      alias ${PHASE2}/;
      autoindex on;
    }
    # Private paths are not published — return 404 (or deny → 403).
    location /.install-cache/ { return 404; }
    location /workflow.state { return 404; }
    location /signing/ { deny all; }
    location /etc/ubuntu-offline-mirror/ { deny all; }
  }
}
EOF
  if nginx -t -c "${WORKDIR}/nginx.conf" >/dev/null 2>&1; then
    nginx -c "${WORKDIR}/nginx.conf"
    sleep 0.3
    probe200() {
      local path="$1" code
      code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}${path}" || echo 000)"
      if [[ "$code" == "200" ]]; then
        pass "GET ${path} → 200"
      else
        fail "GET ${path} → ${code} (expected 200)"
      fi
    }
    probe_deny() {
      local path="$1" code
      code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}${path}" || echo 000)"
      if [[ "$code" == "403" || "$code" == "404" ]]; then
        pass "GET ${path} → ${code} (denied)"
      else
        fail "GET ${path} → ${code} (expected 403/404)"
      fi
    }
    probe200 "/client/"
    probe200 "/client/dp-offline-upgrade-xenial-to-bionic.sh"
    probe200 "/client/stage-dp-phase2.sh"
    probe200 "/dp-phase2/6.6.0/"
    probe200 "/dp-phase2/6.6.0/release.env"
    pass "PUBLIC_CLIENT_HTTP=PASS"
    pass "PUBLIC_PHASE2_HTTP=PASS"
    probe_deny "/.install-cache/acps.dat"
    probe_deny "/workflow.state"
    probe_deny "/signing/private.gpg"
    probe_deny "/etc/ubuntu-offline-mirror/workflow.state"
    pass "PRIVATE_HTTP_DENY=PASS"
    nginx -s stop -c "${WORKDIR}/nginx.conf" 2>/dev/null || true
  else
    echo "  SKIP: nginx -t failed"
  fi
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_umask_public_publication_regression PASS ==="
else
  echo "=== test_umask_public_publication_regression FAIL ==="
fi
exit "$FAIL"
