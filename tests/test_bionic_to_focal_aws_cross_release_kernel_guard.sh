#!/usr/bin/env bash
# Prove Bionic AWS 5.4 kernels are not false-positive Focal cross-release candidates.
# Suite provenance + ~YY.MM markers decide; ABI alone must not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_IN="${ROOT}/client/dp-offline-upgrade-bionic-to-focal.sh.in"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

[[ -f "$SCRIPT_IN" ]] || { echo "FAIL: missing $SCRIPT_IN"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

extract_fn() {
  local name="$1" dest="$2"
  awk -v n="$name" '
    $0 ~ "^" n "\\(\\)" {keep=1}
    keep {print}
    keep && /^}$/ {exit}
  ' "$SCRIPT_IN" >"$dest"
  [[ -s "$dest" ]]
}

extract_fn is_focal_version_for_pkg "${TMP}/is_focal.sh"
extract_fn cross_release_candidate_suite_from_policy "${TMP}/suite_from_policy.sh"
extract_fn is_source_origin_suite "${TMP}/is_source_suite.sh"
extract_fn is_target_origin_suite "${TMP}/is_target_suite.sh"
extract_fn is_cross_release_kernel_candidate "${TMP}/is_cross_kernel.sh"

# shellcheck disable=SC1090
{
  PIN_SOURCE_CODENAME=bionic
  PIN_TARGET_CODENAME=focal
  PIN_SOURCE_VERSION=18.04
  PIN_TARGET_VERSION=20.04
  # shellcheck source=/dev/null
  source "${TMP}/is_focal.sh"
  # shellcheck source=/dev/null
  source "${TMP}/suite_from_policy.sh"
  # shellcheck source=/dev/null
  source "${TMP}/is_source_suite.sh"
  # shellcheck source=/dev/null
  source "${TMP}/is_target_suite.sh"
  # shellcheck source=/dev/null
  source "${TMP}/is_cross_kernel.sh"
}

# A) Bionic AWS kernel with ~18.04 marker must NOT look Focal
if is_focal_version_for_pkg "linux-image-5.4.0-1103-aws" "5.4.0-1103.111~18.04.1"; then
  fail "A: AWS 5.4~18.04 classified as focal"
else
  pass "A: AWS 5.4~18.04 is NOT focal"
fi

# B) Source suite + ~18.04 → not cross-release
if is_cross_release_kernel_candidate "5.4.0-1103.111~18.04.1" "bionic-security"; then
  fail "B: bionic-security + ~18.04 treated as cross"
else
  pass "B: bionic-security + ~18.04 is NOT cross"
fi

# C) Source suite + ABI-only version string → not cross
if is_cross_release_kernel_candidate "5.4.0.1103.81" "bionic-security"; then
  fail "C: bionic-security + 5.4.0.1103.81 treated as cross"
else
  pass "C: bionic-security + ABI-only is NOT cross"
fi

# D) Target suite → IS cross even for 5.4*
if is_cross_release_kernel_candidate "5.4.0-1103.111" "focal-security"; then
  pass "D: focal-security is cross even for 5.4*"
else
  fail "D: focal-security should be cross for 5.4*"
fi

# E) Generic base-files Focal marker still works
if is_focal_version_for_pkg "base-files" "11ubuntu5.7"; then
  pass "E: base-files 11ubuntu* still focal"
else
  fail "E: base-files 11ubuntu* should be focal"
fi

# F) Parse OriginSuite from fixture policy blob
POLICY_FIXTURE="$(cat <<'EOF'
linux-image-5.4.0-1103-aws:
  Installed: 5.4.0-1103.111~18.04.1
  Candidate: 5.4.0-1103.111~18.04.1
  Version table:
 *** 5.4.0-1103.111~18.04.1 500
        500 http://archive.ubuntu.com/ubuntu bionic-security/main amd64 Packages
     5.4.0-1000.100~20.04.1 500
        500 http://archive.ubuntu.com/ubuntu focal-security/main amd64 Packages
EOF
)"
suite="$(cross_release_candidate_suite_from_policy "$POLICY_FIXTURE" "5.4.0-1103.111~18.04.1")"
if [[ "$suite" == "bionic-security" ]]; then
  pass "F: suite_from_policy parses bionic-security"
else
  fail "F: expected bionic-security got '${suite}'"
fi

# G) Template must not use ABI-alone 5.4 matching
if grep -nE '\[\[ "\$ver" == 5\.4\* \|\| "\$ver" == \*5\.4\* \]\]' "$SCRIPT_IN"; then
  fail "G: template still contains ABI-alone 5.4 match"
else
  pass "G: no ABI-alone 5.4 match in bionic-to-focal template"
fi

# H) Other hop templates: kernel branches must not use ABI-alone
h_ok=1
for pair in \
  "focal-to-jammy:5.15" \
  "jammy-to-noble:6.8" \
  "xenial-to-bionic:4.15"; do
  hop="${pair%%:*}"
  abi="${pair##*:}"
  tin="${ROOT}/client/dp-offline-upgrade-${hop}.sh.in"
  if grep -nE "\[\[ \"\\\$ver\" == ${abi}\\\* \|\| \"\\\$ver\" == \\*${abi}\\\* \]\]" "$tin" 2>/dev/null; then
    echo "  still ABI-alone in $tin"
    h_ok=0
  fi
  if [[ "$hop" == "jammy-to-noble" ]] && grep -nE '\[\[ "\$ver" == 6\.8\* \|\| "\$ver" == \*6\.8\* \|\| "\$ver" == 6\.11\* \|\| "\$ver" == \*6\.11\* \]\]' "$tin" 2>/dev/null; then
    echo "  still ABI-alone 6.8/6.11 in $tin"
    h_ok=0
  fi
done
if [[ "$h_ok" -eq 1 ]]; then
  pass "H: focal/jammy/noble/xenial templates reject ABI-alone kernels"
else
  fail "H: some hop templates still match kernel ABI alone"
fi

# Skipped: no small dedicated AWS source-baseline / previous-hop contract test
# (only large hop suites / test_aws_os_core_completeness_field_form.py).
echo "SKIP: no small dedicated AWS baseline/previous-hop contract test"

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
fi
echo "FAILURES=$FAIL"
exit 1
