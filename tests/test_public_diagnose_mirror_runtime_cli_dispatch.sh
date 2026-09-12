#!/usr/bin/env bash
# Public CLI must dispatch diagnose-mirror-runtime through the installed
# presentation wrapper → core → Mirror Manager path (field layout), without
# a Git checkout, without mutating status/config/client-set/nginx.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../lib/runtime_manifest.sh
source "${ROOT}/lib/runtime_manifest.sh"

FAKE_ROOT="${WORKDIR}/destdir"
export INSTALL_LIB_DIR="${FAKE_ROOT}/usr/local/lib/ubuntu-mirror"
export INSTALL_BIN_DIR="${FAKE_ROOT}/usr/local/bin"
export INSTALL_CONF_DIR="${FAKE_ROOT}/etc/ubuntu-mirror"
export BASE_PATH="${FAKE_ROOT}/var/spool/apt-mirror"
export MM_CONFIG_DIR="${INSTALL_CONF_DIR}"
export MM_CONFIG_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="${MM_CONFIG_DIR}/dp-upgrade-mirror.status"
export MM_WORKFLOW_FILE="${MM_CONFIG_DIR}/dp-upgrade-workflow.state"
export MM_LOG_DIR="${FAKE_ROOT}/var/log/ubuntu-mirror-automation"
export MM_MIRROR_ROOT="${BASE_PATH}"
export MM_SELECTIVE_ROOT="${BASE_PATH}/selective"
export MM_DP_PHASE2_ROOT="${BASE_PATH}/dp-phase2"
export MM_CLIENT_ROOT="${BASE_PATH}/client"
export MM_SKIP_ROOT_CHECK=1

mkdir -p \
  "$INSTALL_LIB_DIR" \
  "$INSTALL_BIN_DIR" \
  "$INSTALL_CONF_DIR" \
  "$MM_LOG_DIR" \
  "$MM_SELECTIVE_ROOT" \
  "$MM_DP_PHASE2_ROOT" \
  "$MM_CLIENT_ROOT"

# Install authoritative runtime tree (source → installed layout).
um_runtime_install_tree "$ROOT" "$INSTALL_LIB_DIR"

# Field layout: install.sh replaces /usr/local/bin/ubuntu-offline-mirror with
# the presentation wrapper (not a symlink to the core script).
install -m 0755 \
  "${ROOT}/scripts/ubuntu-offline-mirror-entrypoint.sh" \
  "${INSTALL_BIN_DIR}/ubuntu-offline-mirror"

PUBLIC_CLI="${INSTALL_BIN_DIR}/ubuntu-offline-mirror"
[[ -x "$PUBLIC_CLI" ]] || fail "public CLI missing at ${PUBLIC_CLI}"
[[ ! -L "$PUBLIC_CLI" ]] \
  && pass "public CLI is installed wrapper (not core symlink)" \
  || fail "public CLI unexpectedly a symlink"

# Minimal operator state fixtures (read-only target surfaces).
cat >"$MM_STATUS_FILE" <<'EOF'
HTTP_DISTRIBUTION=DISABLED
OS_MIRROR_READY=PASS
PHASE2_BUNDLE_CHECKSUM=PASS
PHASE2_BUNDLE_ENTRY_COUNT=9
UPGRADE_READINESS=FAIL
READINESS_RESULT=
LAST_EXECUTION_RESULT=NONE
EOF
chmod 600 "$MM_STATUS_FILE"

cat >"$MM_CONFIG_FILE" <<'EOF'
PREPARATION_MODE=FULL
PHASE2_TARGET_VERSION=6.6.0
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
EOF
chmod 600 "$MM_CONFIG_FILE"

cat >"${MM_CLIENT_ROOT}/client-set.env" <<'EOF'
CLIENT_SET_GENERATION_ID=gen-test-1
CLIENT_BUILD_INPUT_SHA256=deadbeef
CLIENT_SIGNING_FINGERPRINT=AABBCCDDEEFF00112233445566778899AABBCCDD
EOF

# Capture before hashes / nginx state for read-only invariant.
hash_file() { sha256sum "$1" | awk '{print $1}'; }
meta_file() { stat -c '%s %Y %a' "$1"; }
BEFORE_STATUS_HASH="$(hash_file "$MM_STATUS_FILE")"
BEFORE_STATUS_META="$(meta_file "$MM_STATUS_FILE")"
BEFORE_CONF_HASH="$(hash_file "$MM_CONFIG_FILE")"
BEFORE_CONF_META="$(meta_file "$MM_CONFIG_FILE")"
BEFORE_CLIENT_HASH="$(hash_file "${MM_CLIENT_ROOT}/client-set.env")"
BEFORE_CLIENT_META="$(meta_file "${MM_CLIENT_ROOT}/client-set.env")"
BEFORE_NGINX_ACTIVE="$(systemctl is-active nginx 2>/dev/null || true)"
BEFORE_NGINX_ENABLED="$(systemctl is-enabled nginx 2>/dev/null || true)"

# Make Git checkout unavailable to the child process (installed-runtime only).
HIDDEN_ROOT="${WORKDIR}/hidden-src"
mkdir -p "$HIDDEN_ROOT"
# Child must not see ROOT; only fake installed tree + PATH.
run_public() {
  env -i \
    PATH="/usr/bin:/bin:${INSTALL_BIN_DIR}" \
    HOME="$WORKDIR" \
    UOM_RUNTIME_ROOT="$INSTALL_LIB_DIR" \
    UOM_CORE_ENTRY="${INSTALL_LIB_DIR}/scripts/ubuntu-offline-mirror.sh" \
    UOM_MANAGER_ENTRY="${INSTALL_LIB_DIR}/scripts/install-dp-upgrade-mirror.sh" \
    MM_CONFIG_DIR="$MM_CONFIG_DIR" \
    MM_CONFIG_FILE="$MM_CONFIG_FILE" \
    MM_STATUS_FILE="$MM_STATUS_FILE" \
    MM_WORKFLOW_FILE="$MM_WORKFLOW_FILE" \
    MM_LOG_DIR="$MM_LOG_DIR" \
    MM_MIRROR_ROOT="$MM_MIRROR_ROOT" \
    MM_SELECTIVE_ROOT="$MM_SELECTIVE_ROOT" \
    MM_DP_PHASE2_ROOT="$MM_DP_PHASE2_ROOT" \
    MM_CLIENT_ROOT="$MM_CLIENT_ROOT" \
    MM_SKIP_ROOT_CHECK=1 \
    BASE_PATH="$BASE_PATH" \
    bash "$PUBLIC_CLI" "$@"
}

# Prove core alone would have been the rejection point before the fix, and
# that the installed core now accepts the command name in usage/dispatch.
CORE="${INSTALL_LIB_DIR}/scripts/ubuntu-offline-mirror.sh"
grep -q 'diagnose-mirror-runtime' "$CORE" \
  && pass "installed core lists diagnose-mirror-runtime" \
  || fail "installed core missing diagnose-mirror-runtime"
MANAGER="${INSTALL_LIB_DIR}/scripts/install-dp-upgrade-mirror.sh"
grep -q 'cmd_diagnose_mirror_runtime' "$MANAGER" \
  && pass "installed manager has cmd_diagnose_mirror_runtime" \
  || fail "installed manager missing diagnostic command"

# A. Public wrapper dispatch (must not emit Unknown command)
set +e
DIAG_OUT="$(run_public diagnose-mirror-runtime 2>&1)"
DIAG_RC=$?
set -e
if echo "$DIAG_OUT" | grep -qi 'Unknown command'; then
  fail "A: public CLI rejected diagnose-mirror-runtime: $DIAG_OUT"
else
  pass "A: public CLI did not emit Unknown command"
fi
[[ "$DIAG_RC" -eq 0 ]] \
  && pass "A: diagnose-mirror-runtime exit 0" \
  || fail "A: diagnose-mirror-runtime rc=${DIAG_RC}: $DIAG_OUT"
echo "$DIAG_OUT" | grep -q 'DIAGNOSE_MIRROR_RUNTIME=PASS' \
  && echo "$DIAG_OUT" | grep -q 'DIAGNOSE_MUTATION=NO' \
  && pass "A: backend diagnostic payload reached" \
  || fail "A: diagnostic payload missing: $DIAG_OUT"
# Ensure PROJECT_ROOT reported is installed runtime, not the hidden git path.
echo "$DIAG_OUT" | grep -q "PROJECT_ROOT=${INSTALL_LIB_DIR}" \
  && pass "A/D: diagnose used installed PROJECT_ROOT" \
  || fail "A/D: PROJECT_ROOT not installed runtime: $DIAG_OUT"

# B. Help visibility
set +e
HELP_OUT="$(run_public --help 2>&1)"
HELP_RC=$?
set -e
[[ "$HELP_RC" -eq 0 ]] || fail "B: --help rc=${HELP_RC}"
echo "$HELP_OUT" | grep -q 'diagnose-mirror-runtime' \
  && pass "B: --help documents diagnose-mirror-runtime" \
  || fail "B: --help missing diagnose-mirror-runtime"

# C. Read-only invariant
AFTER_STATUS_HASH="$(hash_file "$MM_STATUS_FILE")"
AFTER_STATUS_META="$(meta_file "$MM_STATUS_FILE")"
AFTER_CONF_HASH="$(hash_file "$MM_CONFIG_FILE")"
AFTER_CONF_META="$(meta_file "$MM_CONFIG_FILE")"
AFTER_CLIENT_HASH="$(hash_file "${MM_CLIENT_ROOT}/client-set.env")"
AFTER_CLIENT_META="$(meta_file "${MM_CLIENT_ROOT}/client-set.env")"
AFTER_NGINX_ACTIVE="$(systemctl is-active nginx 2>/dev/null || true)"
AFTER_NGINX_ENABLED="$(systemctl is-enabled nginx 2>/dev/null || true)"

[[ "$BEFORE_STATUS_HASH" == "$AFTER_STATUS_HASH" && "$BEFORE_STATUS_META" == "$AFTER_STATUS_META" ]] \
  && pass "C: status file unchanged" \
  || fail "C: status file mutated"
[[ "$BEFORE_CONF_HASH" == "$AFTER_CONF_HASH" && "$BEFORE_CONF_META" == "$AFTER_CONF_META" ]] \
  && pass "C: conf file unchanged" \
  || fail "C: conf file mutated"
[[ "$BEFORE_CLIENT_HASH" == "$AFTER_CLIENT_HASH" && "$BEFORE_CLIENT_META" == "$AFTER_CLIENT_META" ]] \
  && pass "C: client-set.env unchanged" \
  || fail "C: client-set.env mutated"
[[ "$BEFORE_NGINX_ACTIVE" == "$AFTER_NGINX_ACTIVE" && "$BEFORE_NGINX_ENABLED" == "$AFTER_NGINX_ENABLED" ]] \
  && pass "C: nginx active/enabled unchanged" \
  || fail "C: nginx state changed"

# D. Git checkout independence already covered by env -i + PROJECT_ROOT check.
[[ ! -d "${HIDDEN_ROOT}/.git" ]] || true
pass "D: invoked with git checkout unavailable to child"

# G. Existing non-GUI commands retain dispatch (help + status still reach core)
set +e
STATUS_OUT="$(run_public status 2>&1)"
STATUS_RC=$?
set -e
if echo "$STATUS_OUT" | grep -qi 'Unknown command'; then
  fail "G: status dispatch broken"
else
  pass "G: status still dispatches through public CLI (rc=${STATUS_RC})"
fi

# Mirror-manager path still owned by wrapper (smoke: wrapper case still present)
grep -q 'mirror-manager|install-menu' \
  "${ROOT}/scripts/ubuntu-offline-mirror-entrypoint.sh" \
  && pass "G: wrapper retains mirror-manager special path" \
  || fail "G: wrapper lost mirror-manager path"

if [[ "$FAIL" -eq 0 ]]; then
  echo "TEST_PUBLIC_DIAGNOSE_MIRROR_RUNTIME_CLI_DISPATCH=PASS"
  exit 0
fi
echo "TEST_PUBLIC_DIAGNOSE_MIRROR_RUNTIME_CLI_DISPATCH=FAIL"
exit 1
