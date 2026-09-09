#!/usr/bin/env bash
# Uninstall INSTALL_LIB_DIR / INSTALL_CONF_DIR destructive-path safety.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

UM_SNIP="${TMP}/um_snip.sh"
awk '/^um_assert_runtime_destructive_path\(\)/,/^um_assert_purge_path\(\)/ {
  if (/^um_assert_purge_path/) exit
  print
}' "${ROOT}/uninstall.sh" >"$UM_SNIP"
cat >"${TMP}/um_helpers.sh" <<'EOF'
um_die() { printf '%s\n' "$*" >&2; exit 2; }
EOF

run_assert() {
  local path="$1" root="$2" label="$3"
  bash -c '
    source "'"${TMP}/um_helpers.sh"'"
    source "'"$UM_SNIP"'"
    um_assert_runtime_destructive_path "'"$path"'" "'"$root"'" "'"$label"'"
  ' 2>"${TMP}/err.txt"
}

set +e
run_assert /usr/local /usr/local/lib INSTALL_LIB_DIR
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "INSTALL_LIB_DIR=/usr/local rejected" \
  || fail "/usr/local accepted"

set +e
run_assert /etc /etc INSTALL_CONF_DIR
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "INSTALL_CONF_DIR=/etc rejected" \
  || fail "/etc accepted"

set +e
run_assert / /etc INSTALL_CONF_DIR
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "INSTALL_CONF_DIR=/ rejected" \
  || fail "/ accepted"

mkdir -p "${TMP}/real/ubuntu-mirror"
ln -sfn "${TMP}/real" "${TMP}/link-escape"
set +e
run_assert "${TMP}/link-escape" /usr/local/lib INSTALL_LIB_DIR
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "symlink escape rejected" \
  || fail "symlink escape accepted"

# Normal defaults under TMP: bind approved root to TMP parents.
mkdir -p "${TMP}/usr/local/lib/ubuntu-mirror" "${TMP}/etc/ubuntu-mirror"
set +e
run_assert "${TMP}/usr/local/lib/ubuntu-mirror" "${TMP}/usr/local/lib" INSTALL_LIB_DIR
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "TMP INSTALL_LIB_DIR accepted" \
  || fail "TMP lib rejected: $(cat "${TMP}/err.txt")"

set +e
run_assert "${TMP}/etc/ubuntu-mirror" "${TMP}/etc" INSTALL_CONF_DIR
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "TMP INSTALL_CONF_DIR accepted" \
  || fail "TMP conf rejected: $(cat "${TMP}/err.txt")"

[[ "$FAIL" -eq 0 ]]
echo "ALL UNINSTALL INSTALL PATH SAFETY TESTS PASSED"
