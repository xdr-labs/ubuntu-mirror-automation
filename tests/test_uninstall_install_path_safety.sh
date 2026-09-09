#!/usr/bin/env bash
# Uninstall INSTALL_LIB_DIR / INSTALL_CONF_DIR destructive-path safety.
# Approved roots are independent of the candidate path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

UM_SNIP="${TMP}/um_snip.sh"
awk '/^UM_PROD_INSTALL_LIB_DIR=/,/^um_assert_purge_path\(\)/ {
  if (/^um_assert_purge_path/) exit
  print
}' "${ROOT}/uninstall.sh" >"$UM_SNIP"
cat >"${TMP}/um_helpers.sh" <<'EOF'
um_die() { printf '%s\n' "$*" >&2; exit 2; }
EOF

run_assert() {
  local path="$1" label="$2"
  shift 2
  env "$@" bash -c '
    source "'"${TMP}/um_helpers.sh"'"
    source "'"$UM_SNIP"'"
    um_assert_runtime_destructive_path "'"$path"'" "'"$label"'"
  ' 2>"${TMP}/err.txt"
}

# Production mode: reject dangerous / non-authoritative candidates.
set +e
run_assert /usr/local INSTALL_LIB_DIR MM_HERMETIC_TEST_MODE=0
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "INSTALL_LIB_DIR=/usr/local rejected" \
  || fail "/usr/local accepted"

set +e
run_assert /usr INSTALL_LIB_DIR MM_HERMETIC_TEST_MODE=0
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "INSTALL_LIB_DIR=/usr rejected" \
  || fail "/usr accepted"

set +e
run_assert /etc INSTALL_CONF_DIR MM_HERMETIC_TEST_MODE=0
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "INSTALL_CONF_DIR=/etc rejected" \
  || fail "/etc accepted"

set +e
run_assert / INSTALL_CONF_DIR MM_HERMETIC_TEST_MODE=0
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "INSTALL_CONF_DIR=/ rejected" \
  || fail "/ accepted"

set +e
run_assert /var/lib/ubuntu-mirror INSTALL_LIB_DIR MM_HERMETIC_TEST_MODE=0
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "INSTALL_LIB_DIR=/var/lib/ubuntu-mirror rejected" \
  || fail "/var/lib/ubuntu-mirror accepted"

set +e
run_assert /tmp/arbitrary/ubuntu-mirror INSTALL_LIB_DIR MM_HERMETIC_TEST_MODE=0
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "INSTALL_LIB_DIR=/tmp/arbitrary/ubuntu-mirror rejected" \
  || fail "/tmp/arbitrary/ubuntu-mirror accepted"

mkdir -p "${TMP}/real/ubuntu-mirror"
ln -sfn "${TMP}/real" "${TMP}/link-escape"
set +e
run_assert "${TMP}/link-escape" INSTALL_LIB_DIR MM_HERMETIC_TEST_MODE=0
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "symlink escape rejected" \
  || fail "symlink escape accepted"

# Production defaults must still uninstall successfully.
set +e
run_assert /usr/local/lib/ubuntu-mirror INSTALL_LIB_DIR MM_HERMETIC_TEST_MODE=0
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "default INSTALL_LIB_DIR accepted" \
  || fail "default lib rejected: $(cat "${TMP}/err.txt")"

set +e
run_assert /etc/ubuntu-mirror INSTALL_CONF_DIR MM_HERMETIC_TEST_MODE=0
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "default INSTALL_CONF_DIR accepted" \
  || fail "default conf rejected: $(cat "${TMP}/err.txt")"

# Hermetic: dedicated temp root only behind MM_HERMETIC_TEST_MODE + UM_TEST_APPROVED_ROOT.
mkdir -p "${TMP}/usr/local/lib/ubuntu-mirror" "${TMP}/etc/ubuntu-mirror"
set +e
run_assert "${TMP}/usr/local/lib/ubuntu-mirror" INSTALL_LIB_DIR \
  MM_HERMETIC_TEST_MODE=1 UM_TEST_APPROVED_ROOT="$TMP"
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "hermetic TMP INSTALL_LIB_DIR accepted" \
  || fail "hermetic TMP lib rejected: $(cat "${TMP}/err.txt")"

set +e
run_assert "${TMP}/etc/ubuntu-mirror" INSTALL_CONF_DIR \
  MM_HERMETIC_TEST_MODE=1 UM_TEST_APPROVED_ROOT="$TMP"
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "hermetic TMP INSTALL_CONF_DIR accepted" \
  || fail "hermetic TMP conf rejected: $(cat "${TMP}/err.txt")"

# Hermetic boundary required: TMP path without test root must fail closed.
set +e
run_assert "${TMP}/usr/local/lib/ubuntu-mirror" INSTALL_LIB_DIR MM_HERMETIC_TEST_MODE=0
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "TMP path without hermetic root rejected" \
  || fail "TMP path accepted outside hermetic boundary"

[[ "$FAIL" -eq 0 ]]
echo "ALL UNINSTALL INSTALL PATH SAFETY TESTS PASSED"
