#!/usr/bin/env bash
# tests/test_pr28_runtime_helper_packaging.sh
# Focused regressions: AWS package-closure recovery helper must be in the
# authoritative runtime manifest, installed, closure-verified, and sufficient
# for an installed-runtime-only B2F client build (no repo client/ tree).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/client_finalization_fixture.sh
source "${ROOT}/tests/lib/client_finalization_fixture.sh"

HELPER_REL="client/dp-postboot-aws-package-closure-recovery.sh.inc"
HELPER_BASENAME="dp-postboot-aws-package-closure-recovery.sh.inc"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
REPO_CLIENT_HIDDEN="${WORKDIR}/repo-client-hidden"
_restore_repo_client() {
  if [[ -d "$REPO_CLIENT_HIDDEN" && ! -e "${ROOT}/client" ]]; then
    mv "$REPO_CLIENT_HIDDEN" "${ROOT}/client"
  fi
  rm -rf "$WORKDIR"
}
trap '_restore_repo_client' EXIT

echo "=== test_pr28_runtime_helper_packaging ==="
echo "TARGETED_PR28_RUNTIME_HELPER_PACKAGING=YES"

# shellcheck source=/dev/null
source "${ROOT}/lib/runtime_manifest.sh"

# ---------------------------------------------------------------------------
# A. Runtime manifest contains the recovery helper
# ---------------------------------------------------------------------------
if printf '%s\n' "${UM_RUNTIME_CLIENT_FILES[@]}" | grep -qxF "$HELPER_BASENAME"; then
  pass "A manifest lists ${HELPER_BASENAME}"
else
  fail "A manifest missing ${HELPER_BASENAME}"
fi
if um_runtime_emit_installed_relative_paths | grep -qxF "$HELPER_REL"; then
  pass "A required relative path ${HELPER_REL}"
else
  fail "A required relative path missing ${HELPER_REL}"
fi

# ---------------------------------------------------------------------------
# Builder-required client helpers bound to authoritative manifest (no
# duplicate allowlist — refs are extracted from build_client_*.py).
# ---------------------------------------------------------------------------
python3 - "$ROOT" <<'PY' || fail "builder→manifest helper binding"
import re, sys, pathlib, subprocess
root = pathlib.Path(sys.argv[1])
builders = sorted((root / "scripts" / "lib").glob("build_client_*.py"))
refs = set()
for path in builders:
    text = path.read_text(encoding="utf-8")
    for m in re.finditer(r'["\'](dp-[^"\']+\.sh\.inc)["\']', text):
        refs.add("client/" + m.group(1))
    for m in re.finditer(
        r'os\.path\.join\(\s*[^,]+,\s*["\']lib["\']\s*,\s*["\'](dp-[^"\']+\.sh)["\']',
        text,
    ):
        refs.add("client/lib/" + m.group(1))
if not refs:
    print("FAIL: no client helper refs extracted from builders")
    sys.exit(1)
proc = subprocess.run(
    ["bash", "-c", f'source "{root}/lib/runtime_manifest.sh"; um_runtime_emit_installed_relative_paths'],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=True,
    universal_newlines=True,
)
required = set(line.strip() for line in proc.stdout.splitlines() if line.strip())
missing = sorted(refs - required)
if missing:
    print("FAIL builder helpers not in runtime manifest:")
    for rel in missing:
        print("  " + rel)
    sys.exit(1)
print("BUILDER_CLIENT_HELPER_MANIFEST_BINDING=PASS count=%d" % len(refs))
for rel in sorted(refs):
    print("  bound " + rel)
PY
[[ "$FAIL" -eq 0 ]] && pass "builder client helpers ⊆ runtime manifest" || true

# ---------------------------------------------------------------------------
# B. Fresh runtime install copies helper with include-helper mode (0644)
# ---------------------------------------------------------------------------
RUNTIME_A="${WORKDIR}/runtime-a"
um_runtime_install_tree "$ROOT" "$RUNTIME_A"
INSTALLED_A="${RUNTIME_A}/${HELPER_REL}"
if [[ -f "$INSTALLED_A" ]]; then
  pass "B installed ${HELPER_REL}"
else
  fail "B missing installed ${HELPER_REL}"
fi
mode="$(stat -c '%a' "$INSTALLED_A" 2>/dev/null || stat -f '%OLp' "$INSTALLED_A")"
if [[ "$mode" == "644" ]]; then
  pass "B mode=${mode} (sourced include helper)"
else
  fail "B unexpected mode=${mode} (expected 644)"
fi
# Path contract for field runtime prefix
FIELD_PREFIX="/usr/local/lib/ubuntu-mirror"
echo "RUNTIME_HELPER_INSTALL_PATH=${FIELD_PREFIX}/${HELPER_REL}"
pass "B field install path contract ${FIELD_PREFIX}/${HELPER_REL}"

# ---------------------------------------------------------------------------
# C. Dependency closure fails if installed helper is removed
# ---------------------------------------------------------------------------
um_runtime_verify_dependency_closure "$RUNTIME_A" >/dev/null
pass "C closure PASS with helper present"
mv "$INSTALLED_A" "${INSTALLED_A}.bak"
set +e
closure_out="$(um_runtime_verify_dependency_closure "$RUNTIME_A" 2>&1)"
closure_rc=$?
set -e
mv "${INSTALLED_A}.bak" "$INSTALLED_A"
if [[ "$closure_rc" -ne 0 ]] && grep -q 'RUNTIME_DEPENDENCY_CLOSURE=FAIL' <<<"$closure_out"; then
  if grep -q "$HELPER_REL" <<<"$closure_out" \
    || grep -q 'RUNTIME_DEPENDENCY_MISSING' <<<"$closure_out"; then
    pass "C closure FAIL when helper removed"
  else
    # Still fail-closed; missing list may be space-joined on die path
    pass "C closure FAIL when helper removed (rc=${closure_rc})"
  fi
else
  fail "C closure still PASS after removing helper"
fi

# ---------------------------------------------------------------------------
# F. Deliberately missing recovery helper → B2F build fail-closed diagnostic
#    (before full fixture build; uses installed tree with helper deleted)
# ---------------------------------------------------------------------------
client_fixture_require
client_fixture_build_selective "$WORKDIR"
client_fixture_install_runtime "$ROOT" "$WORKDIR"
RUNTIME_ROOT="$CLIENT_FIXTURE_RUNTIME_ROOT"
SEL="$CLIENT_FIXTURE_SELECTIVE"
SIGNING_DIR="$CLIENT_FIXTURE_SIGNING_DIR"
OUT_MISS="${WORKDIR}/out-missing"
mkdir -p "$OUT_MISS"
rm -f "${RUNTIME_ROOT}/${HELPER_REL}"
# Exclude repository client/ so builder cannot accidentally read source tree.
mv "${ROOT}/client" "$REPO_CLIENT_HIDDEN"
set +e
MISS_LOG="${WORKDIR}/b2f-missing-helper.log"
python3 "${RUNTIME_ROOT}/scripts/lib/build_client_bionic_to_focal.py" \
  --project-root "$RUNTIME_ROOT" \
  --mirror-base "http://192.0.2.99" \
  --selective-root "$SEL" \
  --output-dir "$OUT_MISS" \
  --content-source local-fs \
  --signing-private-key "${SIGNING_DIR}/private.gpg" \
  --signing-public-key "${SIGNING_DIR}/public.gpg" \
  >"$MISS_LOG" 2>&1
MISS_RC=$?
set -e
mv "$REPO_CLIENT_HIDDEN" "${ROOT}/client"
if [[ "$MISS_RC" -ne 0 ]] \
  && grep -Eq 'missing AWS package-closure recovery helper|CLIENT_BUILD_INPUT_MISSING=.*dp-postboot-aws-package-closure-recovery\.sh\.inc' "$MISS_LOG"; then
  pass "F missing-helper fail-closed diagnostic"
else
  fail "F expected fail-closed diagnostic (rc=${MISS_RC})"
  tail -40 "$MISS_LOG" || true
fi
# Restore helper for success path
um_runtime_install_one \
  "${ROOT}/client/${HELPER_BASENAME}" \
  "${RUNTIME_ROOT}/${HELPER_REL}" 0644

# ---------------------------------------------------------------------------
# D. Installed-runtime-only B2F build with repo client/ unavailable
# ---------------------------------------------------------------------------
OUT_OK="${WORKDIR}/out-ok"
mkdir -p "$OUT_OK"
mv "${ROOT}/client" "$REPO_CLIENT_HIDDEN"
set +e
OK_LOG="${WORKDIR}/b2f-installed-only.log"
python3 "${RUNTIME_ROOT}/scripts/lib/build_client_bionic_to_focal.py" \
  --project-root "$RUNTIME_ROOT" \
  --mirror-base "http://192.0.2.99" \
  --selective-root "$SEL" \
  --output-dir "$OUT_OK" \
  --content-source local-fs \
  --signing-private-key "${SIGNING_DIR}/private.gpg" \
  --signing-public-key "${SIGNING_DIR}/public.gpg" \
  >"$OK_LOG" 2>&1
OK_RC=$?
set -e
mv "$REPO_CLIENT_HIDDEN" "${ROOT}/client"
if [[ "$OK_RC" -eq 0 ]] \
  && [[ -f "${OUT_OK}/dp-offline-upgrade-bionic-to-focal.sh" ]]; then
  if grep -q 'try_aws_postboot_package_closure_recovery' \
    "${OUT_OK}/dp-offline-upgrade-bionic-to-focal.sh"; then
    pass "D installed-runtime-only B2F build (repo client excluded)"
  else
    fail "D B2F built but recovery not inlined"
  fi
else
  fail "D installed-runtime-only B2F build failed (rc=${OK_RC})"
  tail -60 "$OK_LOG" || true
fi

# ---------------------------------------------------------------------------
# E. Installed-runtime rebuild-publish path (enable-http equivalent finalizer)
# ---------------------------------------------------------------------------
LOG_RP="${WORKDIR}/rebuild-publish.log"
set +e
# Hide repo client again during rebuild-publish from installed runtime.
mv "${ROOT}/client" "$REPO_CLIENT_HIDDEN"
env \
  MIRROR_HTTP_URL="http://192.0.2.99" \
  RESOLVED_MIRROR_BASE_URL="http://192.0.2.99" \
  RESOLVED_MIRROR_HOST_IPV4="192.0.2.99" \
  LOCAL_CLIENT_SIGNING_DIR="$SIGNING_DIR" \
  CLIENT_HTTP_ROOT="$CLIENT_FIXTURE_CLIENT_ROOT" \
  SELECTIVE_ROOT="$SEL" \
  BASE_PATH="$CLIENT_FIXTURE_MIRROR_ROOT" \
  CACHE_ROOT="${CLIENT_FIXTURE_MIRROR_ROOT}/.install-cache" \
  CONTENT_SOURCE=local-fs \
  MM_HERMETIC_TEST_MODE=1 \
  CLIENT_BUILD_PIN_URL_ONLY=1 \
  SKIP_HTTP_VERIFY=1 \
  REQUIRE_SELECTIVE_READY=1 \
  bash "${RUNTIME_ROOT}/scripts/rebuild-publish-clients.sh" \
  >"$LOG_RP" 2>&1
RP_RC=$?
set -e
mv "$REPO_CLIENT_HIDDEN" "${ROOT}/client"
if [[ "$RP_RC" -eq 0 ]] \
  && grep -q 'CLIENT_BUILD_COMPLETE hop=bionic-to-focal' "$LOG_RP" \
  && grep -q 'REBUILD_PUBLISH_CLIENTS=PASS' "$LOG_RP"; then
  pass "E installed-runtime rebuild-publish (B2F + set)"
else
  fail "E rebuild-publish failed (rc=${RP_RC})"
  tail -80 "$LOG_RP" || true
fi

# ---------------------------------------------------------------------------
# G. Existing PR28 B2F recovery targeted tests
# ---------------------------------------------------------------------------
set +e
G_LOG="${WORKDIR}/pr28-recovery-unit.log"
python3 -m unittest tests.test_b2f_aws_postboot_package_closure_recovery -v \
  >"$G_LOG" 2>&1
G_RC=$?
set -e
if [[ "$G_RC" -eq 0 ]]; then
  pass "G PR28 recovery targeted unittest"
else
  fail "G PR28 recovery targeted unittest"
  tail -40 "$G_LOG" || true
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "PR28_RUNTIME_HELPER_PACKAGING=PASS"
  exit 0
fi
echo "PR28_RUNTIME_HELPER_PACKAGING=FAIL"
exit 1
