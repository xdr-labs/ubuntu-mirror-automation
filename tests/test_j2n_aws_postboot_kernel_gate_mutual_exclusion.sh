#!/usr/bin/env bash
# Targeted regression: Jammy→Noble postboot AWS vs generic mutual exclusion.
# Field case: valid Noble AWS kernel 7.0.0-1011-aws must not be rejected by a
# generic-only inline series check, and must not subsequently hit the generic gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

TMP="$(mktemp -d /tmp/j2n-aws-postboot-mx.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

TEMPLATE="${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh.in"
GENERATED="${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh"
AWS_GATE="${ROOT}/client/dp-postboot-aws-kernel-gate.sh.inc"
GENERIC_GATE="${ROOT}/client/dp-postboot-generic-kernel-gate.sh.inc"
CONTRACT="${ROOT}/client/dp-aws-semantic-contract.sh.inc"

[[ -f "$TEMPLATE" && -f "$GENERATED" ]] || { echo "missing template/generated"; exit 1; }
[[ -f "$AWS_GATE" && -f "$GENERIC_GATE" && -f "$CONTRACT" ]] || { echo "missing gates"; exit 1; }

# --- Static contracts ---------------------------------------------------------
if grep -q 'kernel not Noble-series generic' "$TEMPLATE"; then
  fail "template still has generic-only Noble series reject"
else
  pass "template has no 'kernel not Noble-series generic'"
fi
if grep -q 'kernel not Noble-series generic' "$GENERATED"; then
  fail "generated still has generic-only Noble series reject"
else
  pass "generated has no 'kernel not Noble-series generic'"
fi

extract_postboot_main() {
  python3 - "$1" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
m = re.search(r"<<'POSTBOOT_MAIN'\n(.*?)\nPOSTBOOT_MAIN\n", text, re.S)
if not m:
    raise SystemExit("POSTBOOT_MAIN missing in " + sys.argv[1])
sys.stdout.write(m.group(1))
PY
}

MAIN_T="${TMP}/main.template"
MAIN_G="${TMP}/main.generated"
extract_postboot_main "$TEMPLATE" >"$MAIN_T"
extract_postboot_main "$GENERATED" >"$MAIN_G"

for label in template generated; do
  f="$MAIN_T"
  [[ "$label" == generated ]] && f="$MAIN_G"
  if grep -q 'detect_aws_upgrade_profile' "$f" \
    && grep -q 'validate_aws_post_hop_kernel_gate "24.04"' "$f" \
    && grep -q 'GENERIC_POST_HOP_KERNEL_GATE=SKIP reason=aws_profile' "$f" \
    && grep -q 'validate_generic_running_kernel_postboot' "$f"; then
    pass "${label} POSTBOOT_MAIN mutual-exclusion markers"
  else
    fail "${label} POSTBOOT_MAIN mutual-exclusion markers missing"
  fi
  # AWS branch must precede generic else path; SKIP logged on AWS path.
  python3 - "$f" "$label" <<'PY'
import sys
from pathlib import Path
body = Path(sys.argv[1]).read_text(encoding="utf-8")
label = sys.argv[2]
aws = body.find('validate_aws_post_hop_kernel_gate "24.04"')
skip = body.find("GENERIC_POST_HOP_KERNEL_GATE=SKIP reason=aws_profile")
gen = body.find("validate_generic_running_kernel_postboot")
if not (0 <= aws < skip and 0 <= aws < gen):
    raise SystemExit("order fail for " + label)
# Ensure if/else mutual exclusion (generic not unconditionally after AWS).
if "else" not in body[aws:gen]:
    raise SystemExit("missing else mutual exclusion for " + label)
PY
  pass "${label} POSTBOOT_MAIN if-aws/else-generic order"
done

if grep -A5 'generic_target_kernel_series_ere()' "$GENERIC_GATE" | grep -A20 "24.04)" \
  | head -5 | grep -q -- '-aws'; then
  fail "generic Noble series ERE incorrectly accepts -aws"
else
  pass "generic Noble series ERE remains generic-only"
fi

# Already-Noble FAILED re-entry is validation-only (no DRO) and refreshes
# the product-owned postboot from the current wrapper before execution.
if grep -q 'running post-boot verification only' "$TEMPLATE" \
  && grep -q 'POSTBOOT_REFRESH=START reason=validation_only_reentry' "$TEMPLATE" \
  && grep -q 'install_authoritative_postboot_runtime' "$TEMPLATE" \
  && grep -q 'bash "$(hostpath "$POSTBOOT_PATH")"' "$TEMPLATE"; then
  pass "E template already-Noble validation-only re-entry present"
else
  fail "E already-Noble re-entry path missing"
fi
if extract_postboot_main "$TEMPLATE" | grep -q 'do-release-upgrade'; then
  fail "E postboot main invokes do-release-upgrade"
else
  pass "E postboot path has no do-release-upgrade"
fi
if extract_postboot_main "$GENERATED" | grep -q 'do-release-upgrade'; then
  fail "E generated postboot main invokes do-release-upgrade"
else
  pass "E generated postboot path has no do-release-upgrade"
fi

# --- Runtime gate harness (authoritative helpers) -----------------------------
# Mirrors the jammy→noble POSTBOOT_MAIN mutual-exclusion decision and COMPLETED
# write, without requiring absolute /etc MOTD or real durable fsync as root.
run_mx_harness() {
  local root="$1" kernel="$2" out="$3"
  cat >"${TMP}/harness.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export TEST_ROOT="$root"
export DP_POSTBOOT_TEST_ROOT="$root"
export STATE_ROOT="/opt/aelladata/os-upgrade/offline"
export HOLDS_DIR="\${STATE_ROOT}/critical-holds"
export DP_OFFLINE_FAKE_KERNEL="$kernel"
export PATH="$root/bin:\$PATH"

log() { printf '%s [%s] %s\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "\$1" "\$2"; }
write_state() {
  mkdir -p "\${TEST_ROOT}\${STATE_ROOT}"
  printf '%s\n' "\$1" >"\${TEST_ROOT}\${STATE_FILE:-\${STATE_ROOT}/state}"
}
STATE_FILE="\${STATE_ROOT}/state"

# shellcheck disable=SC1091
source "$CONTRACT"
# shellcheck disable=SC1091
source "$AWS_GATE"
# shellcheck disable=SC1091
source "$GENERIC_GATE"

uname() {
  if [[ "\${1:-}" == "-r" || -z "\${1:-}" ]]; then
    printf '%s\n' "$kernel"
    return 0
  fi
  command uname "\$@"
}

# Exact mutual-exclusion block from jammy→noble POSTBOOT_MAIN.
aws_profile="\$(detect_aws_upgrade_profile 2>/dev/null || true)"
if [[ "\$aws_profile" == "aws" ]]; then
  if ! validate_aws_post_hop_kernel_gate "24.04"; then
    log ERROR "AWS kernel post-hop validation failed; refusing COMPLETED_NOBLE"
    write_state FAILED
    exit 1
  fi
  log INFO "GENERIC_POST_HOP_KERNEL_GATE=SKIP reason=aws_profile"
else
  if ! declare -F validate_generic_running_kernel_postboot >/dev/null 2>&1; then
    log ERROR "GENERIC_POST_HOP_KERNEL_GATE=FAIL reason=helper_missing"
    write_state FAILED
    exit 1
  fi
  if ! validate_generic_running_kernel_postboot "24.04"; then
    log ERROR "GENERIC_POST_HOP_KERNEL_GATE=FAIL"
    write_state FAILED
    exit 1
  fi
fi
write_state COMPLETED_NOBLE
log INFO "post-boot verification PASS - COMPLETED_NOBLE"
EOF
  chmod +x "${TMP}/harness.sh"
  set +e
  bash "${TMP}/harness.sh" >"$out" 2>&1
  local rc=$?
  set +e
  printf '%s' "$rc"
}

prep_root() {
  local root="$1"
  mkdir -p \
    "$root/opt/aelladata/os-upgrade/offline/critical-holds" \
    "$root/boot" "$root/etc" "$root/bin"
  cat >"$root/etc/os-release" <<'EOF'
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION_CODENAME=noble
UBUNTU_CODENAME=noble
EOF
  printf 'FAILED\n' >"$root/opt/aelladata/os-upgrade/offline/state"
}

install_aws_dpkg_query() {
  local root="$1" aws_ver="$2" img_ver="$3" kr="$4"
  cat >"$root/bin/dpkg-query" <<EOF
#!/usr/bin/env bash
pkg="\${3:-}"
if [[ "\$1" == "-W" ]]; then
  case "\$pkg" in
    linux-aws|linux-image-aws)
      if [[ "\$2" == *Status* ]]; then echo "install ok installed"; exit 0; fi
      if [[ "\$2" == *Version* ]]; then
        if [[ "\$pkg" == linux-aws ]]; then echo "${aws_ver}"; else echo "${img_ver}"; fi
        exit 0
      fi
      ;;
    linux-image-${kr})
      if [[ "\$2" == *Status* ]]; then echo "install ok installed"; exit 0; fi
      if [[ "\$2" == *Version* ]]; then echo "${img_ver}"; exit 0; fi
      ;;
  esac
fi
exit 1
EOF
  chmod +x "$root/bin/dpkg-query"
}

install_generic_dpkg_query() {
  local root="$1" kr="$2"
  cat >"$root/bin/dpkg-query" <<EOF
#!/usr/bin/env bash
pkg="\${3:-}"
case "\$*" in
  *linux-aws*|*linux-image-aws*|*linux-headers-aws*) exit 1 ;;
esac
if [[ "\$1" == "-W" ]]; then
  case "\$pkg" in
    linux-image-${kr}|linux-image-generic|linux-generic)
      if [[ "\$2" == *Status* ]]; then echo "install ok installed"; exit 0; fi
      if [[ "\$2" == *Version* ]]; then echo "6.8.0-31.31"; exit 0; fi
      ;;
  esac
fi
exit 1
EOF
  chmod +x "$root/bin/dpkg-query"
}

# A) Noble AWS PASS — field kernel 7.0.0-1011-aws
fx_a="${TMP}/A"
prep_root "$fx_a"
install_aws_dpkg_query "$fx_a" '7.0.0-1011.11~24.04.1' '7.0.0-1011.11~24.04.1' '7.0.0-1011-aws'
printf 'aws\n' >"$fx_a/opt/aelladata/os-upgrade/offline/critical-holds/source_kernel_flavor"
printf '5.15.0-1060-aws\n' >"$fx_a/opt/aelladata/os-upgrade/offline/critical-holds/source_kernel_release"
printf '5.15.0.1060.58\n' >"$fx_a/opt/aelladata/os-upgrade/offline/critical-holds/source_linux_aws_version"
printf '5.15.0.1060.58\n' >"$fx_a/opt/aelladata/os-upgrade/offline/critical-holds/source_linux_image_aws_version"
echo x >"$fx_a/boot/vmlinuz-7.0.0-1011-aws"
rc_a="$(run_mx_harness "$fx_a" "7.0.0-1011-aws" "${TMP}/A.out")"
if [[ "$rc_a" -eq 0 ]] \
  && grep -q 'AWS_POST_HOP_KERNEL_GATE=PASS' "${TMP}/A.out" \
  && grep -q 'GENERIC_POST_HOP_KERNEL_GATE=SKIP reason=aws_profile' "${TMP}/A.out" \
  && ! grep -q 'kernel not Noble-series generic' "${TMP}/A.out" \
  && ! grep -q 'GENERIC_POST_HOP_KERNEL_GATE=PASS' "${TMP}/A.out" \
  && ! grep -q 'GENERIC_POST_HOP_KERNEL_GATE=FAIL' "${TMP}/A.out" \
  && [[ "$(tr -d '\r\n' <"$fx_a/opt/aelladata/os-upgrade/offline/state")" == "COMPLETED_NOBLE" ]]; then
  pass "A Noble AWS PASS (7.0.0-1011-aws) → COMPLETED_NOBLE + generic SKIP"
else
  fail "A Noble AWS PASS (rc=${rc_a})"
  cat "${TMP}/A.out" || true
fi

# B) Noble generic PASS
fx_b="${TMP}/B"
prep_root "$fx_b"
install_generic_dpkg_query "$fx_b" "6.8.0-31-generic"
printf 'generic\n' >"$fx_b/opt/aelladata/os-upgrade/offline/critical-holds/source_kernel_flavor"
printf '5.15.0-100-generic\n' >"$fx_b/opt/aelladata/os-upgrade/offline/critical-holds/source_kernel_release"
echo x >"$fx_b/boot/vmlinuz-6.8.0-31-generic"
rc_b="$(run_mx_harness "$fx_b" "6.8.0-31-generic" "${TMP}/B.out")"
if [[ "$rc_b" -eq 0 ]] \
  && grep -q 'GENERIC_POST_HOP_KERNEL_GATE=PASS' "${TMP}/B.out" \
  && ! grep -q 'AWS_POST_HOP_KERNEL_GATE=PASS' "${TMP}/B.out" \
  && ! grep -q 'AWS_POST_HOP_KERNEL_GATE=FAIL' "${TMP}/B.out" \
  && [[ "$(tr -d '\r\n' <"$fx_b/opt/aelladata/os-upgrade/offline/state")" == "COMPLETED_NOBLE" ]]; then
  pass "B Noble generic PASS (AWS path not required)"
else
  fail "B Noble generic PASS (rc=${rc_b})"
  cat "${TMP}/B.out" || true
fi

# C) AWS bad contract FAIL
fx_c="${TMP}/C"
prep_root "$fx_c"
install_aws_dpkg_query "$fx_c" '7.0.0-9999.99~24.04.1' '7.0.0-9999.99~24.04.1' '7.0.0-1011-aws'
printf 'aws\n' >"$fx_c/opt/aelladata/os-upgrade/offline/critical-holds/source_kernel_flavor"
printf '5.15.0-1060-aws\n' >"$fx_c/opt/aelladata/os-upgrade/offline/critical-holds/source_kernel_release"
printf '5.15.0.1060.58\n' >"$fx_c/opt/aelladata/os-upgrade/offline/critical-holds/source_linux_aws_version"
printf '5.15.0.1060.58\n' >"$fx_c/opt/aelladata/os-upgrade/offline/critical-holds/source_linux_image_aws_version"
echo x >"$fx_c/boot/vmlinuz-7.0.0-1011-aws"
rc_c="$(run_mx_harness "$fx_c" "7.0.0-1011-aws" "${TMP}/C.out")"
if [[ "$rc_c" -ne 0 ]] \
  && grep -q 'AWS_POST_HOP_KERNEL_GATE=FAIL' "${TMP}/C.out" \
  && [[ "$(tr -d '\r\n' <"$fx_c/opt/aelladata/os-upgrade/offline/state")" != "COMPLETED_NOBLE" ]]; then
  pass "C AWS bad contract FAIL (no COMPLETED_NOBLE)"
else
  fail "C AWS bad contract (rc=${rc_c} state=$(cat "$fx_c/opt/aelladata/os-upgrade/offline/state"))"
  cat "${TMP}/C.out" || true
fi

# D) Generic wrong series FAIL
fx_d="${TMP}/D"
prep_root "$fx_d"
install_generic_dpkg_query "$fx_d" "5.15.0-100-generic"
printf 'generic\n' >"$fx_d/opt/aelladata/os-upgrade/offline/critical-holds/source_kernel_flavor"
printf '5.4.0-150-generic\n' >"$fx_d/opt/aelladata/os-upgrade/offline/critical-holds/source_kernel_release"
rc_d="$(run_mx_harness "$fx_d" "5.15.0-100-generic" "${TMP}/D.out")"
if [[ "$rc_d" -ne 0 ]] \
  && grep -qE 'GENERIC_POST_HOP_KERNEL_GATE=FAIL|kernel_not_target_series' "${TMP}/D.out" \
  && [[ "$(tr -d '\r\n' <"$fx_d/opt/aelladata/os-upgrade/offline/state")" != "COMPLETED_NOBLE" ]]; then
  pass "D generic wrong series FAIL"
else
  fail "D generic wrong series (rc=${rc_d})"
  cat "${TMP}/D.out" || true
fi

# E) Already-Noble FAILED re-entry: harness starts from FAILED → COMPLETED_NOBLE
# without DRO (covered by A state transition + static DRO absence above).
if [[ "$(tr -d '\r\n' <"$fx_a/opt/aelladata/os-upgrade/offline/state")" == "COMPLETED_NOBLE" ]] \
  && ! grep -q 'do-release-upgrade' "${TMP}/A.out"; then
  pass "E FAILED→COMPLETED_NOBLE validation-only (no DRO)"
else
  fail "E re-entry COMPLETED_NOBLE/DRO guard"
fi

# F) Exact field kernel regression
if grep -q '7.0.0-1011-aws' "${TMP}/A.out" \
  && grep -q 'AWS_POST_HOP_KERNEL_GATE=PASS' "${TMP}/A.out" \
  && ! grep -qi 'kernel not Noble-series generic' "${TMP}/A.out"; then
  pass "F field kernel 7.0.0-1011-aws regression guard"
else
  fail "F field kernel regression"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
exit 0
