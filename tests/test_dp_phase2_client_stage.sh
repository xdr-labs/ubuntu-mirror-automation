#!/usr/bin/env bash
# tests/test_dp_phase2_client_stage.sh — client staging helper safety + logic
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/client/stage-dp-phase2.sh"
WRAP="${ROOT}/client/stage-dp-phase2-6.6.0.sh"
RETIRED_WRAP="${ROOT}/client/stage-dp-phase2-6.5.0.sh"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
HTTP_PID=""
trap 'rm -rf "$WORKDIR"; [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true' EXIT

echo "[test] bash -n helpers"
bash -n "$HELPER" && pass "bash -n canonical" || fail "bash -n canonical"
bash -n "$WRAP" && pass "bash -n wrapper" || fail "bash -n wrapper"

echo "[test] wrapper forwards target 6.6.0 only"
grep -q -- '--target-version 6.6.0' "$WRAP" && pass "wrapper target" || fail "wrapper target"
grep -q 'source-dp-version 6\.' "$WRAP" && fail "wrapper must not fix source version" || pass "wrapper source not fixed"
bash -n "$RETIRED_WRAP" && pass "bash -n retired 6.5.0 wrapper" || fail "bash -n retired wrapper"
set +e
retired_out="$(bash "$RETIRED_WRAP" 2>&1)"
retired_rc=$?
set -e
[[ "$retired_rc" -ne 0 ]] && echo "$retired_out" | grep -q 'retired' \
  && pass "retired 6.5.0 wrapper fail-closed" || fail "retired 6.5.0 wrapper should fail closed"

echo "[test] helper does not use ACPS as download source"
if grep -Eiq 'ACPS_PROVISION_URL|ACPS_BASE_URL|curl .*acps\.stellarcyber' "$HELPER"; then
  fail "ACPS download source present"
elif grep -Eiq 'DEFAULT_MIRROR_URL=.*acps\.stellarcyber' "$HELPER"; then
  fail "default mirror is ACPS"
else
  pass "no ACPS download source"
fi

echo "[test] no built-in mirror address; --mirror-url required"
grep -q '^DEFAULT_MIRROR_URL=""$' "$HELPER" && pass "no default mirror URL" || fail "no default mirror URL"
if grep -qE '^DEFAULT_MIRROR_URL="https?://[0-9]' "$HELPER"; then
  fail "hardcoded default mirror address present"
else
  pass "no hardcoded default mirror address"
fi
set +e
out="$(bash "$HELPER" --target-version 6.6.0 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q -- '--mirror-url is required'; then
  pass "missing --mirror-url fails closed"
else
  fail "missing --mirror-url should fail: rc=${rc} ${out}"
fi

echo "[test] bringup never auto-executed"
grep -Eq 'BRINGUP_EXECUTED=("NO"|NO)|BRINGUP_EXECUTED=\$\{BRINGUP_EXECUTED\}' "$HELPER" \
  && pass "BRINGUP_EXECUTED=NO contract" || fail "missing NO"
grep -q 'BRINGUP_EXECUTED="NO"' "$HELPER" && pass "default BRINGUP_EXECUTED=NO" || fail "default NO"
if grep -nE '[[:space:]](bash|sh)[[:space:]]+/home/aella/bringup_py3' "$HELPER" | grep -vE 'NEXT_COMMAND|usage|EOF'; then
  fail "bringup executed in script body"
else
  pass "bringup not executed in body"
fi

echo "[test] no literal aella group / no ambiguous VERSION="
if grep -En -- 'chown[[:space:]]+aella:aella|install[[:space:]]+-o[[:space:]]+aella|[[:space:]]-g[[:space:]]+aella[[:space:]]+-m' "$HELPER"; then
  fail "literal aella group"
else
  pass "no literal aella group"
fi
grep -Eq '^VERSION=|"VERSION=6\.5\.0"|Current DP version' "$HELPER" && fail "ambiguous VERSION" || pass "no ambiguous VERSION"

echo "[test] refuses stellarcyber URL via --mirror-url"
set +e
out="$(bash "$HELPER" --target-version 6.6.0 --mirror-url 'https://acps.stellarcyber.ai/x' 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -Eiq 'Refusing ACPS|ACPS|stellarcyber'; then
  pass "refuses ACPS mirror-url"
else
  fail "should refuse ACPS mirror-url: $out"
fi

echo "[test] package health failures preserve diagnostics and stop staging"
PACKAGE_RUNNER="$WORKDIR/package-check.sh"
cat >"$PACKAGE_RUNNER" <<'PACKAGE_TEST'
#!/usr/bin/env bash
set -euo pipefail
DP_PHASE2_STAGE_LIB_ONLY=1 source "$1" >/dev/null
PACKAGE_SCENARIO="$2"
PACKAGE_TRACE="$3"
dpkg() {
  printf 'dpkg %s\n' "$*" >>"$PACKAGE_TRACE"
  [[ "$*" == "--audit" ]] || exit 96
  case "$PACKAGE_SCENARIO" in
    audit_issues) printf 'package-a is unpacked but not configured\n'; return 0 ;;
    audit_error) printf 'dpkg: unable to read package status\n' >&2; return 2 ;;
    audit_silent_error) return 2 ;;
  esac
  return 0
}
apt-get() {
  printf 'apt-get %s\n' "$*" >>"$PACKAGE_TRACE"
  [[ "$*" == "check" ]] || exit 97
  case "$PACKAGE_SCENARIO" in
    apt_dependencies)
      printf 'The following packages have unmet dependencies:\n package-a : Depends: package-b (>= 2) but 1 is installed\n'
      printf 'E: Unmet dependencies.\n' >&2
      return 100
      ;;
    healthy_warning) printf 'W: package cache warning\n' >&2 ;;
    apt_silent_error) return 100 ;;
  esac
  printf 'Reading package lists... Done\n'
}
require_dpkg_apt_clean
printf 'PACKAGE_CHECK_COMPLETED\n'
PACKAGE_TEST
for package_case in healthy healthy_warning apt_dependencies audit_issues audit_error audit_silent_error apt_silent_error; do
  package_out="$WORKDIR/$package_case.out"
  package_err="$WORKDIR/$package_case.err"
  package_trace="$WORKDIR/$package_case.trace"
  if bash "$PACKAGE_RUNNER" "$HELPER" "$package_case" "$package_trace" >"$package_out" 2>"$package_err"; then
    package_rc=0
  else
    package_rc=$?
  fi
  if [[ "$package_case" == healthy* ]]; then
    if [[ "$package_rc" -eq 0 ]] \
      && [[ "$(cat "$package_out")" == PACKAGE_CHECK_COMPLETED ]] \
      && grep -Fxq 'apt-get check' "$package_trace"; then
      pass "$package_case continues without routine APT progress output"
    else
      fail "$package_case: rc=$package_rc"
    fi
    if [[ "$package_case" == healthy_warning ]]; then
      grep -Fq 'W: package cache warning' "$package_err" \
        && pass "successful APT warnings remain visible" || fail "successful APT warning was lost"
    else
      [[ ! -s "$package_err" ]] && pass "healthy package checks are quiet" \
        || fail "healthy package checks wrote unexpected stderr"
    fi
    continue
  fi
  if [[ "$package_rc" -ne 0 ]] && ! grep -Fq PACKAGE_CHECK_COMPLETED "$package_out"; then
    pass "$package_case stops before subsequent staging"
  else
    fail "$package_case must stop staging: rc=$package_rc"
  fi
  case "$package_case" in
    apt_dependencies)
      if grep -Fq 'package-a : Depends: package-b (>= 2) but 1 is installed' "$package_err" \
        && grep -Fq 'E: Unmet dependencies.' "$package_err" \
        && grep -Fq 'apt-get check failed (exit=100)' "$package_err"; then
        pass "APT dependency details, stderr and exit code are preserved"
      else
        fail "APT dependency details, stderr or exit code were lost"
      fi
      ;;
    audit_issues)
      grep -Fq 'package-a is unpacked but not configured' "$package_err" \
        && pass "dpkg audit issues are printed even with exit 0" \
        || fail "dpkg audit issue details were lost"
      ;;
    audit_error)
      if grep -Fq 'dpkg: unable to read package status' "$package_err" \
        && grep -Fq 'dpkg --audit failed (exit=2)' "$package_err"; then
        pass "dpkg command error and exit code are preserved"
      else
        fail "dpkg command error or exit code were lost"
      fi
      ;;
    audit_silent_error)
      grep -Fq 'dpkg --audit failed (exit=2)' "$package_err" \
        && pass "silent dpkg failure is reported" || fail "silent dpkg failure was ignored"
      ;;
    apt_silent_error)
      grep -Fq 'apt-get check failed (exit=100)' "$package_err" \
        && pass "silent APT failure is reported" || fail "silent APT failure lost its exit code"
      ;;
  esac
  case "$package_case" in
    audit_*)
      if ! grep -Fq 'apt-get' "$package_trace"; then
        pass "$package_case does not run APT after a failed audit"
      else
        fail "$package_case continued to APT"
      fi
      ;;
  esac
done

echo "[test] failed staging cleanup removes STAGE_ROOT"
grep -q 'STAGE_ROOT' "$HELPER" && grep -A20 '^cleanup()' "$HELPER" | grep -q 'STAGE_ROOT' \
  && pass "cleanup removes STAGE_ROOT" || fail "STAGE_ROOT cleanup"

echo "[test] checksum failure leaves destination untouched (inline harness)"
HTTP_ROOT="${WORKDIR}/http"
REL="${HTTP_ROOT}/dp-phase2/6.6.0"
mkdir -p "$REL" "${WORKDIR}/dest"
printf 'old-marker\n' >"${WORKDIR}/dest/marker"
FILES=(
  aelladeb_py3_common.tar.gz
  aelladeb_py3_common.tar.gz.sha1
  aella-uvp-2404_6.6.0ubuntu1_amd64.deb
  aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1
  bringup_py3_dp_after_os_upgrade.sh
  bringup_py3_dp_after_os_upgrade.sh.sha1
  images-6.6.0.list
  images-6.6.0.tar
  images-6.6.0.tar.sha256
)
TMPF="${WORKDIR}/files"
mkdir -p "$TMPF"
printf 'common\n' >"${TMPF}/aelladeb_py3_common.tar.gz"
sha1sum "${TMPF}/aelladeb_py3_common.tar.gz" | awk '{print $1}' >"${TMPF}/aelladeb_py3_common.tar.gz.sha1"
printf 'deb\n' >"${TMPF}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb"
sha1sum "${TMPF}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb" | awk '{print $1}' >"${TMPF}/aella-uvp-2404_6.6.0ubuntu1_amd64.deb.sha1"
printf '#!/bin/bash\necho hi\n' >"${TMPF}/bringup_py3_dp_after_os_upgrade.sh"
sha1sum "${TMPF}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' >"${TMPF}/bringup_py3_dp_after_os_upgrade.sh.sha1"
seq 1 3 >"${TMPF}/images-6.6.0.list"
printf 'img\n' >"${TMPF}/images-6.6.0.tar"
sha256sum "${TMPF}/images-6.6.0.tar" | awk '{print $1}' >"${TMPF}/images-6.6.0.tar.sha256"
(
  cd "$TMPF"
  tar -cf "${REL}/dp_bundle_6.6.0-current.tar" "${FILES[@]}"
)
echo '0000000000000000000000000000000000000000000000000000000000000000  dp_bundle_6.6.0-current.tar' \
  >"${REL}/dp_bundle_6.6.0-current.tar.sha256"

python3 - "${HTTP_ROOT}" 8766 <<'PY' &
import http.server, os, sys
os.chdir(sys.argv[1])
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), http.server.SimpleHTTPRequestHandler).serve_forever()
PY
HTTP_PID=$!
sleep 0.3

DEST="${WORKDIR}/dest"
STAGE="${WORKDIR}/stage"
mkdir -p "$STAGE"
set +e
(
  set -euo pipefail
  curl -fsS -o "${STAGE}/bundle.tar" "http://127.0.0.1:8766/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar"
  curl -fsS -o "${STAGE}/bundle.tar.sha256" "http://127.0.0.1:8766/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar.sha256"
  expected="$(awk 'NF {print $1; exit}' "${STAGE}/bundle.tar.sha256")"
  actual="$(sha256sum "${STAGE}/bundle.tar" | awk '{print $1}')"
  [[ "${expected,,}" == "${actual,,}" ]]
  rm -rf "$DEST"
) 2>/dev/null
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "checksum failure aborts before replace" || fail "checksum should fail"
[[ -f "${DEST}/marker" ]] && pass "destination preserved on checksum fail" || fail "destination altered"

sha256sum "${REL}/dp_bundle_6.6.0-current.tar" | awk '{print $1"  dp_bundle_6.6.0-current.tar"}' \
  >"${REL}/dp_bundle_6.6.0-current.tar.sha256"
NEW="${WORKDIR}/new_art"
mkdir -p "$NEW"
curl -fsS -o "${STAGE}/bundle.tar" "http://127.0.0.1:8766/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar"
curl -fsS -o "${STAGE}/bundle.tar.sha256" "http://127.0.0.1:8766/dp-phase2/6.6.0/dp_bundle_6.6.0-current.tar.sha256"
expected="$(awk 'NF {print $1; exit}' "${STAGE}/bundle.tar.sha256")"
actual="$(sha256sum "${STAGE}/bundle.tar" | awk '{print $1}')"
[[ "${expected,,}" == "${actual,,}" ]] && pass "good checksum verifies" || fail "good checksum"
tar -xf "${STAGE}/bundle.tar" -C "$NEW"
[[ -f "${NEW}/images-6.6.0.tar" ]] && pass "extract places artifacts" || fail "extract"

echo "[test] deploy script safety checks"
bash -n "${ROOT}/scripts/deploy-stage-dp-phase2-client-atomic.sh" && pass "deploy bash -n" || fail "deploy bash -n"
grep -q 'READY_UNCHANGED' "${ROOT}/scripts/deploy-stage-dp-phase2-client-atomic.sh" && pass "READY guard" || fail "READY guard"
grep -q 'stage-dp-phase2.sh' "${ROOT}/scripts/deploy-stage-dp-phase2-client-atomic.sh" && pass "deploys generic" || fail "deploys generic"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -e SC1091,SC2015,SC2034,SC2119,SC2120,SC2317 "$HELPER" \
    && pass "shellcheck helper" || fail "shellcheck helper"
else
  echo "  SKIP: shellcheck not installed"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL DP PHASE2 CLIENT STAGE TESTS PASSED"
  exit 0
fi
echo "SOME DP PHASE2 CLIENT STAGE TESTS FAILED"
exit 1
