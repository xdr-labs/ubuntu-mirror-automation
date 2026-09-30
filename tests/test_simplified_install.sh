#!/usr/bin/env bash
# tests/test_simplified_install.sh — Bootstrap installer surface tests
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${ROOT}/lib/config.sh"
# shellcheck source=../lib/state.sh
source "${ROOT}/lib/state.sh"
# shellcheck source=../lib/bootstrap.sh
source "${ROOT}/lib/bootstrap.sh"

FAIL=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAIL=1; }

echo "[test_default_install_flow] help lists bootstrap options"
HELP="$(bash "${ROOT}/install.sh" --help)"
echo "$HELP" | grep -q -- '--dry-run' || fail "missing --dry-run"
echo "$HELP" | grep -q -- '--non-interactive' || fail "missing --non-interactive"
echo "$HELP" | grep -q -- '--no-gui' || fail "missing --no-gui"
echo "$HELP" | grep -q 'Mirror Manager' || fail "missing Mirror Manager"
echo "$HELP" | grep -q 'Ubuntu 24.04' || fail "missing Ubuntu 24.04"
echo "$HELP" | grep -qE 'plan-selective|materialize-selective|publish-selective' \
  && fail "help still documents old selective sync as default" || true
echo "$HELP" | grep -q 'NOT do' || fail "help should state what installer does not do"
pass "operator help surface"

echo "[test_public_cli_legacy_mutation_block]"
ENTRY="${ROOT}/scripts/ubuntu-offline-mirror-entrypoint.sh"
PUB_HELP="$(bash "$ENTRY" --help)"
echo "$PUB_HELP" | grep -q 'mirror-manager' || fail "public help missing mirror-manager"
echo "$PUB_HELP" | grep -q 'diagnose-mirror-runtime' || fail "public help missing diagnose"
echo "$PUB_HELP" | grep -qE '^[[:space:]]+(materialize-selective|publish-selective|migrate-nginx-selective)' \
  && fail "public help exposes legacy mutator as normal command" || true
set +e
legacy_out="$(MM_HERMETIC_TEST_MODE=0 UOM_ALLOW_LEGACY_MUTATION=0 \
  bash "$ENTRY" materialize-selective 2>&1)"
legacy_rc=$?
set -e
[[ "$legacy_rc" -ne 0 ]] \
  && echo "$legacy_out" | grep -q 'LEGACY_PUBLIC_COMMAND_DISABLED=YES command=materialize-selective' \
  && pass "public legacy mutation blocked" \
  || fail "public legacy mutation not blocked rc=${legacy_rc}"
MOCK_CORE="$(mktemp)"
cat >"$MOCK_CORE" <<'EOF'
#!/usr/bin/env bash
printf 'MOCK_CORE_ARGS=%s\n' "$*"
EOF
chmod 0755 "$MOCK_CORE"
legacy_test_out="$(MM_HERMETIC_TEST_MODE=1 UOM_ALLOW_LEGACY_MUTATION=1 UOM_CORE_ENTRY="$MOCK_CORE" \
  bash "$ENTRY" materialize-selective xenial-to-bionic 2>&1)"
echo "$legacy_test_out" | grep -q 'MOCK_CORE_ARGS=materialize-selective xenial-to-bionic' \
  && pass "dual-hermetic legacy delegation retained for regression tests" \
  || fail "dual-hermetic legacy delegation failed"
rm -f "$MOCK_CORE"

echo "[test_dry_run_bootstrap]"
set +e
bash "${ROOT}/install.sh" --dry-run --no-gui >/tmp/um-dry.out 2>&1
RC=$?
set -e
if [[ "$RC" -eq 0 ]]; then
  pass "dry-run exit 0"
else
  fail "dry-run exit $RC"
  tail -40 /tmp/um-dry.out || true
fi
grep -q 'Would install packages:' /tmp/um-dry.out || fail "missing package dry-run"
grep -q 'whiptail' /tmp/um-dry.out || fail "dry-run missing whiptail"
grep -q 'nginx' /tmp/um-dry.out || fail "dry-run missing nginx"
grep -qiE 'plan-selective|Would start initial synchronization' /tmp/um-dry.out \
  && fail "dry-run still starts old selective sync" || pass "dry-run no old sync"
grep -qiE 'mkfs|wipefs' /tmp/um-dry.out && fail "dry-run mentioned format" || pass "no format in dry-run"

echo "[test_package_list_no_apt_mirror]"
pkgs="$(um_bootstrap_required_packages)"
echo "$pkgs" | grep -qx apt-mirror && fail "apt-mirror still required" || pass "no apt-mirror"
echo "$pkgs" | grep -qx whiptail && pass "whiptail required" || fail "whiptail required"
echo "$pkgs" | grep -qx nginx && pass "nginx required" || fail "nginx required"

echo "[test_nginx_generator_direct_selective]"
um_load_config "${ROOT}/mirror.conf"
SELECTIVE_NGINX_ROOT="${SELECTIVE_MIRROR_ROOT}"
ngx="$(um_generate_nginx_conf)"
echo "$ngx" | grep -q 'location /ubuntu/' || fail "nginx /ubuntu/"
echo "$ngx" | grep -qE 'selective/current|published\.previous' \
  && fail "nginx generation paths" || pass "nginx direct selective root"

echo "[test_client_required_files_list]"
[[ ${#UM_CLIENT_REQUIRED_FILES[@]} -ge 10 ]] && pass "client required list" || fail "client required list"

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL SIMPLIFIED INSTALL TESTS PASSED"
  exit 0
fi
echo "SOME SIMPLIFIED INSTALL TESTS FAILED"
exit 1
