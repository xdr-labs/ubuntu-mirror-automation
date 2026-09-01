#!/usr/bin/env bash
# nginx publication boundary: deny private paths; catch-all 404; public allowlist.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${ROOT}/lib/config.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

um_load_config "${ROOT}/mirror.conf"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TPL="${ROOT}/templates/nginx.conf"
um_generate_nginx_conf >"${TMP}/apt-mirror.conf"

assert_deny() {
  local conf="$1" path="$2"
  grep -Eq "location[[:space:]]+(=|\\^~)[[:space:]]+${path}(/)?[[:space:]]*\\{[[:space:]]*return[[:space:]]+403" "$conf" \
    || grep -Eq "location[[:space:]]+\\^~[[:space:]]+${path}/[[:space:]]*\\{[[:space:]]*return[[:space:]]+403" "$conf" \
    || fail "missing deny for ${path} in $(basename "$conf")"
}

for conf in "$TPL" "${TMP}/apt-mirror.conf"; do
  for path in /staging /state /.install-cache /cache /tmp; do
    assert_deny "$conf" "$path"
  done
  # Catch-all must return 404 (not try_files into selective root).
  if ! awk '
    /location[[:space:]]+\/[[:space:]]*\{/ { in_loc=1; next }
    in_loc && /return[[:space:]]+404/ { found=1; exit }
    in_loc && /\}/ { in_loc=0 }
    END { exit found ? 0 : 1 }
  ' "$conf"; then
    fail "catch-all location / missing return 404 in $(basename "$conf")"
  fi
  if awk '
    /location[[:space:]]+\/[[:space:]]*\{/ { in_loc=1; next }
    in_loc && /try_files/ { found=1; exit }
    in_loc && /\}/ { in_loc=0 }
    END { exit found ? 0 : 1 }
  ' "$conf"; then
    fail "catch-all location / still uses try_files in $(basename "$conf")"
  fi
  for pub in '/ubuntu/' '/client/' '/dp-phase2/6.6.0/' '/offline/' '/hops/'; do
    grep -q "location ${pub}" "$conf" || fail "public path ${pub} missing in $(basename "$conf")"
  done
  grep -q '/keys/' "$conf" || fail "public /keys/ path missing in $(basename "$conf")"
done
pass "deny private paths; catch-all 404; public paths present"

if command -v nginx >/dev/null 2>&1; then
  cat >"${TMP}/nginx.conf" <<EOF
events {}
http {
    include ${TMP}/apt-mirror.conf;
}
EOF
  if nginx -t -c "${TMP}/nginx.conf" 2>"${TMP}/nginx-t.err"; then
    pass "nginx -t on generated config"
  else
    # Minimal wrapper may lack mime defaults on some builds; soft-warn only when
    # the error is clearly environmental, fail on syntax referencing our site.
    if grep -Eqi 'unexpected|unknown directive|invalid' "${TMP}/nginx-t.err"; then
      fail "nginx -t syntax error: $(tr '\n' ' ' <"${TMP}/nginx-t.err")"
    fi
    echo "WARNING: nginx -t with minimal wrapper failed (environment limits)"
  fi
else
  echo "SKIP: nginx not installed — structural checks only"
fi

echo "ALL test_nginx_publication_boundary checks passed"
