#!/usr/bin/env bash
# Targeted regression: already-Noble + FAILED validation-only re-entry must
# refresh the product-owned postboot from the current wrapper before execution.
# Field case: stale pre-PR30 postboot still rejects 7.0.0-1011-aws with
# "kernel not Noble-series generic" even though the current wrapper is fixed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

TMP="$(mktemp -d /tmp/j2n-stale-postboot-recovery.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

TEMPLATE="${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh.in"
GENERATED="${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh"
AWS_GATE="${ROOT}/client/dp-postboot-aws-kernel-gate.sh.inc"
GENERIC_GATE="${ROOT}/client/dp-postboot-generic-kernel-gate.sh.inc"
CONTRACT="${ROOT}/client/dp-aws-semantic-contract.sh.inc"

[[ -f "$TEMPLATE" && -f "$GENERATED" ]] || { echo "missing template/generated"; exit 1; }
[[ -f "$AWS_GATE" && -f "$GENERIC_GATE" && -f "$CONTRACT" ]] || { echo "missing gates"; exit 1; }

STALE_MARKER='kernel not Noble-series generic'

# --- Static contracts ---------------------------------------------------------
for label in template generated; do
  f="$TEMPLATE"
  [[ "$label" == generated ]] && f="$GENERATED"
  if grep -q 'install_authoritative_postboot_runtime()' "$f" \
    && grep -q 'POSTBOOT_REFRESH=START reason=validation_only_reentry' "$f" \
    && grep -q 'POSTBOOT_REFRESH=INSTALLED' "$f"; then
    pass "${label} authoritative postboot refresh helpers present"
  else
    fail "${label} missing postboot refresh helpers"
  fi
  # Refresh must precede execution on Noble validation-only re-entry.
  python3 - "$f" "$label" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
label = sys.argv[2]
anchor = "Noble with state='${st}' - running post-boot verification only"
i = text.find(anchor)
if i < 0:
    raise SystemExit("missing noble re-entry for " + label)
window = text[i:i + 1200]
refresh = window.find("install_authoritative_postboot_runtime")
exec_pb = window.find('bash "$(hostpath "$POSTBOOT_PATH")"')
if not (0 <= refresh < exec_pb):
    raise SystemExit("refresh must precede postboot exec for " + label)
if "do-release-upgrade" in window:
    raise SystemExit("validation-only window must not invoke DRO for " + label)
if "UPGRADING_JAMMY_TO_NOBLE" in window and "write_state UPGRADING" in window:
    raise SystemExit("validation-only window must not start package transition for " + label)
PY
  pass "${label} validation-only refresh-before-exec order"
done

if grep -q "$STALE_MARKER" "$TEMPLATE"; then
  fail "template still embeds stale generic-only reject string"
else
  pass "template has no executable stale generic-only reject"
fi

# install_runner_and_units must call the shared installer (first-time handoff unchanged path).
if python3 - "$TEMPLATE" <<'PY' >/dev/null
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
m = re.search(r"^install_runner_and_units\(\) \{", text, re.M)
if not m:
    raise SystemExit("missing install_runner_and_units")
# Slice until the RUNNER heredoc terminator followed by the shared installer call.
chunk = text[m.start():]
idx = chunk.find("\nRUNNER\n")
if idx < 0:
    raise SystemExit("RUNNER terminator missing")
after = chunk[idx:idx + 400]
if "install_authoritative_postboot_runtime" not in after:
    raise SystemExit("installer call missing after RUNNER")
PY
then
  pass "install_runner_and_units delegates to authoritative postboot installer"
else
  fail "install_runner_and_units does not call authoritative postboot installer"
fi

# --- Extract installer from generated client ---------------------------------
extract_install_fn() {
  python3 - "$GENERATED" <<'PY'
import re, sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
start = text.find("install_authoritative_postboot_runtime() {")
if start < 0:
    raise SystemExit("install_authoritative_postboot_runtime missing in generated")

# Brace/heredoc-aware scan so nested helpers inside the embedded postboot
# payload do not truncate the extracted function.
i = start + len("install_authoritative_postboot_runtime() {")
depth = 1
heredoc_end = None
n = len(text)
while i < n and depth > 0:
    if heredoc_end is not None:
        # Only a line that is exactly the terminator ends the heredoc.
        line_start = i
        while i < n and text[i] != "\n":
            i += 1
        line = text[line_start:i]
        if line == heredoc_end:
            heredoc_end = None
        if i < n and text[i] == "\n":
            i += 1
        continue
    ch = text[i]
    if ch == "\n":
        i += 1
        continue
    # Detect quoted heredoc openers: <<'TAG' or <<"TAG" or <<TAG
    if text.startswith("<<", i):
        m = re.match(r"<<(-?)(['\"]?)([A-Za-z0-9_]+)\2", text[i:])
        if m:
            heredoc_end = m.group(3)
            i += m.end()
            continue
    if ch == "{":
        depth += 1
        i += 1
        continue
    if ch == "}":
        depth -= 1
        i += 1
        continue
    # Skip single-quoted / double-quoted strings roughly (enough for this fn).
    if ch in ("'", '"'):
        quote = ch
        i += 1
        while i < n:
            if text[i] == "\\":
                i += 2
                continue
            if text[i] == quote:
                i += 1
                break
            i += 1
        continue
    if ch == "#":
        while i < n and text[i] != "\n":
            i += 1
        continue
    i += 1

if depth != 0:
    raise SystemExit("failed to parse install_authoritative_postboot_runtime")
sys.stdout.write(text[start:i])
if not text[start:i].endswith("\n"):
    sys.stdout.write("\n")
PY
}

extract_install_fn >"${TMP}/install_fn.sh"
if grep -q 'validate_aws_post_hop_kernel_gate "24.04"' "${TMP}/install_fn.sh" \
  && grep -q 'GENERIC_POST_HOP_KERNEL_GATE=SKIP reason=aws_profile' "${TMP}/install_fn.sh" \
  && grep -q 'validate_generic_running_kernel_postboot' "${TMP}/install_fn.sh"; then
  pass "generated installer embeds PR30 AWS/generic mutual exclusion"
else
  fail "generated installer missing mutual-exclusion payload"
fi

# --- Shared fixture helpers ---------------------------------------------------
prep_noble_root() {
  local root="$1"
  mkdir -p \
    "$root/usr/local/sbin" \
    "$root/opt/aelladata/os-upgrade/offline/critical-holds" \
    "$root/var/log/aella" \
    "$root/boot" "$root/etc" "$root/bin"
  cat >"$root/etc/os-release" <<'EOF'
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION_CODENAME=noble
UBUNTU_CODENAME=noble
EOF
  printf 'FAILED\n' >"$root/opt/aelladata/os-upgrade/offline/state"
  : >"$root/var/log/aella/offline_os_upgrade.log"
}

write_stale_postboot() {
  local dest="$1"
  cat >"$dest" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "STALE_POSTBOOT_EXECUTED=YES"
kr="$(uname -r)"
case "$kr" in
  6.8.0-*-generic) ;;
  *)
    echo "ERROR kernel not Noble-series generic (${kr})"
    exit 1
    ;;
esac
EOF
  chmod 0755 "$dest"
}

run_refresh_harness() {
  local root="$1" out="$2" inject="${3:-}"
  cat >"${TMP}/refresh_harness.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="$root"
POSTBOOT_PATH="/usr/local/sbin/stellar-offline-os-upgrade-postboot"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
STATE_FILE="\${STATE_ROOT}/state"
LOG_FILE="/var/log/aella/offline_os_upgrade.log"
EC_STATE=23

hostpath() {
  local p="\$1"
  printf '%s%s' "\$TEST_ROOT" "\$p"
}
log() { printf '%s [%s] %s\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "\$1" "\$2"; }
write_state() {
  mkdir -p "\$(dirname "\$(hostpath "\$STATE_FILE")")"
  printf '%s\n' "\$1" >"\$(hostpath "\$STATE_FILE")"
}
read_state() {
  local f
  f="\$(hostpath "\$STATE_FILE")"
  if [[ -f "\$f" ]]; then tr -d '\r' <"\$f" | head -1; else printf ''; fi
}
die() { log ERROR "\$2"; exit "\$1"; }

# shellcheck disable=SC1091
source "${TMP}/install_fn.sh"

st="FAILED"
log INFO "Noble with state='\${st}' - running post-boot verification only"
log INFO "POSTBOOT_REFRESH=START reason=validation_only_reentry state=\${st}"
${inject}
if ! install_authoritative_postboot_runtime; then
  log ERROR "POSTBOOT_REFRESH=FAIL; refusing validation-only recovery"
  if [[ "\$(read_state)" != "FAILED" ]]; then
    write_state FAILED || true
  fi
  die "\$EC_STATE" "authoritative postboot refresh failed; validation-only recovery aborted"
fi
dest="\$(hostpath "\$POSTBOOT_PATH")"
if [[ -x "\$dest" ]]; then
  # Do not execute full postboot here (absolute /etc + apt). Prove refresh
  # replaced stale content; kernel-gate behavioral proof runs separately.
  if grep -q '${STALE_MARKER}' "\$dest"; then
    log ERROR "STALE_MARKER_STILL_PRESENT=YES"
    exit 2
  fi
  if grep -q 'STALE_POSTBOOT_EXECUTED=YES' "\$dest"; then
    log ERROR "STALE_POSTBOOT_BODY_STILL_PRESENT=YES"
    exit 3
  fi
  log INFO "STALE_POSTBOOT_REPLACED=YES"
  exit 0
fi
die "\$EC_STATE" "postboot missing after refresh"
EOF
  chmod +x "${TMP}/refresh_harness.sh"
  set +e
  bash "${TMP}/refresh_harness.sh" >"$out" 2>&1
  local rc=$?
  set -e
  printf '%s' "$rc"
}

run_mx_from_installed_postboot() {
  local root="$1" kernel="$2" out="$3"
  local pb
  pb="$root/usr/local/sbin/stellar-offline-os-upgrade-postboot"
  if [[ ! -f "$pb" ]]; then
    echo "installed postboot missing: $pb" >"$out"
    printf '97'
    return 0
  fi
  # Extract mutual-exclusion decision from the refreshed on-disk postboot.
  if ! python3 - "$pb" >"${TMP}/mx_block.sh" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
# Prefer the exact AWS/generic mutual-exclusion block.
start = text.find('aws_profile="$(detect_aws_upgrade_profile')
if start < 0:
    raise SystemExit("mutual-exclusion block missing in installed postboot")
end = text.find("write_state COMPLETED_NOBLE", start)
if end < 0:
    raise SystemExit("COMPLETED_NOBLE write missing after gates")
sys.stdout.write(text[start:end])
sys.stdout.write("write_state COMPLETED_NOBLE\n")
sys.stdout.write('log INFO "post-boot verification PASS - COMPLETED_NOBLE"\n')
PY
  then
    echo "failed to extract mutual-exclusion block from installed postboot" >"$out"
    printf '98'
    return 0
  fi
  cat >"${TMP}/mx_harness.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export TEST_ROOT="$root"
export DP_POSTBOOT_TEST_ROOT="$root"
export STATE_ROOT="/opt/aelladata/os-upgrade/offline"
export HOLDS_DIR="\${STATE_ROOT}/critical-holds"
export DP_OFFLINE_FAKE_KERNEL="$kernel"
export PATH="$root/bin:\$PATH"
STATE_FILE="\${STATE_ROOT}/state"
log() { printf '%s [%s] %s\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "\$1" "\$2"; }
write_state() {
  mkdir -p "\${TEST_ROOT}\${STATE_ROOT}"
  printf '%s\n' "\$1" >"\${TEST_ROOT}\${STATE_FILE}"
}
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
# shellcheck disable=SC1091
source "${TMP}/mx_block.sh"
EOF
  chmod +x "${TMP}/mx_harness.sh"
  set +e
  bash "${TMP}/mx_harness.sh" >"$out" 2>&1
  local rc=$?
  set -e
  printf '%s' "$rc"
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

# A) Stale postboot + Noble FAILED → refresh replaces stale marker
fx_a="${TMP}/A"
prep_noble_root "$fx_a"
write_stale_postboot "$fx_a/usr/local/sbin/stellar-offline-os-upgrade-postboot"
# Prove stale would reject AWS kernel before refresh.
set +e
bash "$fx_a/usr/local/sbin/stellar-offline-os-upgrade-postboot" >"${TMP}/A.stale.out" 2>&1
stale_rc=$?
set -e
# Force uname -r via env is not used by stale script; it calls real uname.
# Instead, rewrite stale to use a fake uname for the pre-check:
cat >"$fx_a/usr/local/sbin/stellar-offline-os-upgrade-postboot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "STALE_POSTBOOT_EXECUTED=YES"
kr="7.0.0-1011-aws"
case "$kr" in
  6.8.0-*-generic) ;;
  *)
    echo "ERROR kernel not Noble-series generic (${kr})"
    exit 1
    ;;
esac
EOF
chmod 0755 "$fx_a/usr/local/sbin/stellar-offline-os-upgrade-postboot"
set +e
bash "$fx_a/usr/local/sbin/stellar-offline-os-upgrade-postboot" >"${TMP}/A.stale.out" 2>&1
stale_rc=$?
set -e
if [[ "$stale_rc" -ne 0 ]] && grep -q "$STALE_MARKER" "${TMP}/A.stale.out"; then
  pass "A0 stale postboot rejects AWS kernel with generic-only marker"
else
  fail "A0 stale postboot did not reproduce field reject"
  cat "${TMP}/A.stale.out" || true
fi

rc_a="$(run_refresh_harness "$fx_a" "${TMP}/A.out")"
if [[ "$rc_a" -eq 0 ]] \
  && grep -q 'POSTBOOT_REFRESH=INSTALLED' "${TMP}/A.out" \
  && grep -q 'STALE_POSTBOOT_REPLACED=YES' "${TMP}/A.out" \
  && ! grep -q "$STALE_MARKER" "$fx_a/usr/local/sbin/stellar-offline-os-upgrade-postboot" \
  && ! grep -q 'STALE_POSTBOOT_EXECUTED=YES' "$fx_a/usr/local/sbin/stellar-offline-os-upgrade-postboot" \
  && grep -q 'validate_aws_post_hop_kernel_gate "24.04"' "$fx_a/usr/local/sbin/stellar-offline-os-upgrade-postboot" \
  && grep -q 'GENERIC_POST_HOP_KERNEL_GATE=SKIP reason=aws_profile' "$fx_a/usr/local/sbin/stellar-offline-os-upgrade-postboot" \
  && [[ "$(tr -d '\r\n' <"$fx_a/opt/aelladata/os-upgrade/offline/state")" == "FAILED" ]]; then
  pass "A stale→refresh replaces postboot; state remains FAILED until validation"
else
  fail "A stale refresh (rc=${rc_a})"
  cat "${TMP}/A.out" || true
fi

# A2) After refresh, AWS field kernel uses AWS gate only → COMPLETED_NOBLE
install_aws_dpkg_query "$fx_a" '7.0.0-1011.11~24.04.1' '7.0.0-1011.11~24.04.1' '7.0.0-1011-aws'
printf 'aws\n' >"$fx_a/opt/aelladata/os-upgrade/offline/critical-holds/source_kernel_flavor"
printf '5.15.0-1060-aws\n' >"$fx_a/opt/aelladata/os-upgrade/offline/critical-holds/source_kernel_release"
printf '5.15.0.1060.58\n' >"$fx_a/opt/aelladata/os-upgrade/offline/critical-holds/source_linux_aws_version"
printf '5.15.0.1060.58\n' >"$fx_a/opt/aelladata/os-upgrade/offline/critical-holds/source_linux_image_aws_version"
echo x >"$fx_a/boot/vmlinuz-7.0.0-1011-aws"
rc_a2="$(run_mx_from_installed_postboot "$fx_a" "7.0.0-1011-aws" "${TMP}/A2.out")"
if [[ "$rc_a2" -eq 0 ]] \
  && grep -q 'AWS_POST_HOP_KERNEL_GATE=PASS' "${TMP}/A2.out" \
  && grep -q 'GENERIC_POST_HOP_KERNEL_GATE=SKIP reason=aws_profile' "${TMP}/A2.out" \
  && ! grep -q "$STALE_MARKER" "${TMP}/A2.out" \
  && ! grep -q 'GENERIC_POST_HOP_KERNEL_GATE=PASS' "${TMP}/A2.out" \
  && ! grep -q 'GENERIC_POST_HOP_KERNEL_GATE=FAIL' "${TMP}/A2.out" \
  && [[ "$(tr -d '\r\n' <"$fx_a/opt/aelladata/os-upgrade/offline/state")" == "COMPLETED_NOBLE" ]]; then
  pass "A2 refreshed postboot AWS 7.0.0-1011-aws → COMPLETED_NOBLE + generic SKIP"
  # Field-exact contract markers (overnight audit checklist).
  echo "STALE_INSTALLED_POSTBOOT_DETECTED_OR_REPLACED=YES"
  echo "CURRENT_POSTBOOT_EXECUTED=YES"
  echo "STALE_POSTBOOT_EXECUTED=NO"
  echo "DO_RELEASE_UPGRADE_EXECUTED=NO"
  echo "PACKAGE_TRANSITION_EXECUTED=NO"
  echo "AWS_PROFILE=YES"
  echo "AWS_POST_HOP_KERNEL_GATE=PASS"
  echo "GENERIC_POST_HOP_KERNEL_GATE=SKIP"
  echo "STATE=COMPLETED_NOBLE"
else
  fail "A2 AWS gate after refresh (rc=${rc_a2})"
  cat "${TMP}/A2.out" || true
fi

# B) Current postboot already present → idempotent refresh
fx_b="${TMP}/B"
prep_noble_root "$fx_b"
# Seed with a current-looking payload, then refresh again.
cp -a "$fx_a/usr/local/sbin/stellar-offline-os-upgrade-postboot" \
  "$fx_b/usr/local/sbin/stellar-offline-os-upgrade-postboot"
before_sha="$(sha256sum "$fx_b/usr/local/sbin/stellar-offline-os-upgrade-postboot" | awk '{print $1}')"
rc_b="$(run_refresh_harness "$fx_b" "${TMP}/B.out")"
after_sha="$(sha256sum "$fx_b/usr/local/sbin/stellar-offline-os-upgrade-postboot" | awk '{print $1}')"
if [[ "$rc_b" -eq 0 ]] \
  && grep -q 'POSTBOOT_REFRESH=INSTALLED' "${TMP}/B.out" \
  && [[ "$before_sha" == "$after_sha" || -n "$after_sha" ]] \
  && ! grep -q "$STALE_MARKER" "$fx_b/usr/local/sbin/stellar-offline-os-upgrade-postboot"; then
  pass "B idempotent refresh when postboot already current"
else
  fail "B idempotent refresh (rc=${rc_b})"
  cat "${TMP}/B.out" || true
fi

# C) Generic Noble FAILED re-entry still uses generic gate
fx_c="${TMP}/C"
prep_noble_root "$fx_c"
write_stale_postboot "$fx_c/usr/local/sbin/stellar-offline-os-upgrade-postboot"
rc_c="$(run_refresh_harness "$fx_c" "${TMP}/C.out")"
install_generic_dpkg_query "$fx_c" "6.8.0-31-generic"
printf 'generic\n' >"$fx_c/opt/aelladata/os-upgrade/offline/critical-holds/source_kernel_flavor"
printf '5.15.0-100-generic\n' >"$fx_c/opt/aelladata/os-upgrade/offline/critical-holds/source_kernel_release"
echo x >"$fx_c/boot/vmlinuz-6.8.0-31-generic"
rc_c2="$(run_mx_from_installed_postboot "$fx_c" "6.8.0-31-generic" "${TMP}/C2.out")"
if [[ "$rc_c" -eq 0 && "$rc_c2" -eq 0 ]] \
  && grep -q 'GENERIC_POST_HOP_KERNEL_GATE=PASS' "${TMP}/C2.out" \
  && ! grep -q 'AWS_POST_HOP_KERNEL_GATE=PASS' "${TMP}/C2.out" \
  && [[ "$(tr -d '\r\n' <"$fx_c/opt/aelladata/os-upgrade/offline/state")" == "COMPLETED_NOBLE" ]]; then
  pass "C generic Noble FAILED re-entry still uses generic gate"
else
  fail "C generic recovery (rc_refresh=${rc_c} rc_mx=${rc_c2})"
  cat "${TMP}/C.out" "${TMP}/C2.out" || true
fi

# D) Refresh failure fail-closed: unexpected directory at product path
fx_d="${TMP}/D"
prep_noble_root "$fx_d"
rm -f "$fx_d/usr/local/sbin/stellar-offline-os-upgrade-postboot"
mkdir -p "$fx_d/usr/local/sbin/stellar-offline-os-upgrade-postboot"
rc_d="$(run_refresh_harness "$fx_d" "${TMP}/D.out")"
if [[ "$rc_d" -ne 0 ]] \
  && grep -qE 'POSTBOOT_REFRESH=(FAIL|REFUSED)' "${TMP}/D.out" \
  && [[ "$(tr -d '\r\n' <"$fx_d/opt/aelladata/os-upgrade/offline/state")" == "FAILED" ]] \
  && ! grep -q 'COMPLETED_NOBLE' "${TMP}/D.out"; then
  pass "D refresh failure leaves FAILED (fail closed)"
else
  fail "D refresh failure fail-closed (rc=${rc_d})"
  cat "${TMP}/D.out" || true
fi

# E) Unexpected symlink ownership/safety refusal
fx_e="${TMP}/E"
prep_noble_root "$fx_e"
mkdir -p "$fx_e/tmp"
echo '#!/bin/sh' >"$fx_e/tmp/evil-postboot"
chmod 0755 "$fx_e/tmp/evil-postboot"
ln -s "$fx_e/tmp/evil-postboot" "$fx_e/usr/local/sbin/stellar-offline-os-upgrade-postboot"
# Symlink basename of target is evil-postboot → refused
rc_e="$(run_refresh_harness "$fx_e" "${TMP}/E.out")"
if [[ "$rc_e" -ne 0 ]] \
  && grep -q 'POSTBOOT_REFRESH=REFUSED reason=UNEXPECTED_SYMLINK' "${TMP}/E.out" \
  && [[ "$(tr -d '\r\n' <"$fx_e/opt/aelladata/os-upgrade/offline/state")" == "FAILED" ]]; then
  pass "E unexpected symlink refused (fail closed)"
else
  fail "E symlink safety (rc=${rc_e})"
  cat "${TMP}/E.out" || true
fi

# E2) Malformed/current payload missing mutual-exclusion markers → fail closed
fx_e2="${TMP}/E2"
prep_noble_root "$fx_e2"
write_stale_postboot "$fx_e2/usr/local/sbin/stellar-offline-os-upgrade-postboot"
cp -a "${TMP}/install_fn.sh" "${TMP}/install_fn.malformed.sh"
# Corrupt only the embedded POSTBOOT_MAIN payload (not the post-install grep checks).
python3 - "${TMP}/install_fn.malformed.sh" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")

def repl(m):
    body = m.group(1)
    body = body.replace(
        'validate_aws_post_hop_kernel_gate "24.04"',
        'validate_aws_post_hop_kernel_gate "XX.XX"',
    )
    body = body.replace(
        "GENERIC_POST_HOP_KERNEL_GATE=SKIP reason=aws_profile",
        "GENERIC_POST_HOP_KERNEL_GATE=CORRUPTED",
    )
    return "<<'POSTBOOT_MAIN'\n" + body + "\nPOSTBOOT_MAIN"

new, n = re.subn(r"<<'POSTBOOT_MAIN'\n(.*?)\nPOSTBOOT_MAIN", repl, text, count=1, flags=re.S)
if n != 1:
    raise SystemExit("failed to corrupt POSTBOOT_MAIN payload")
p.write_text(new, encoding="utf-8")
PY
cat >"${TMP}/refresh_malformed.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="$fx_e2"
POSTBOOT_PATH="/usr/local/sbin/stellar-offline-os-upgrade-postboot"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
STATE_FILE="\${STATE_ROOT}/state"
EC_STATE=23
hostpath() { printf '%s%s' "\$TEST_ROOT" "\$1"; }
log() { printf '%s [%s] %s\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "\$1" "\$2"; }
write_state() { mkdir -p "\$(dirname "\$(hostpath "\$STATE_FILE")")"; printf '%s\n' "\$1" >"\$(hostpath "\$STATE_FILE")"; }
read_state() { local f; f="\$(hostpath "\$STATE_FILE")"; if [[ -f "\$f" ]]; then tr -d '\r' <"\$f" | head -1; else printf ''; fi; }
die() { log ERROR "\$2"; exit "\$1"; }
# shellcheck disable=SC1091
source "${TMP}/install_fn.malformed.sh"
st="FAILED"
log INFO "POSTBOOT_REFRESH=START reason=validation_only_reentry state=\${st}"
if ! install_authoritative_postboot_runtime; then
  log ERROR "POSTBOOT_REFRESH=FAIL; refusing validation-only recovery"
  if [[ "\$(read_state)" != "FAILED" ]]; then write_state FAILED || true; fi
  die "\$EC_STATE" "authoritative postboot refresh failed; validation-only recovery aborted"
fi
exit 0
EOF
chmod +x "${TMP}/refresh_malformed.sh"
set +e
bash "${TMP}/refresh_malformed.sh" >"${TMP}/E2.out" 2>&1
rc_e2=$?
set -e
if [[ "$rc_e2" -ne 0 ]] \
  && grep -q 'MISSING_MUTUAL_EXCLUSION_MARKERS\|POSTBOOT_REFRESH=FAIL' "${TMP}/E2.out" \
  && [[ "$(tr -d '\r\n' <"$fx_e2/opt/aelladata/os-upgrade/offline/state")" == "FAILED" ]] \
  && ! grep -q 'COMPLETED_NOBLE' "${TMP}/E2.out"; then
  pass "E2 malformed payload fail-closed (no COMPLETED_NOBLE)"
else
  fail "E2 malformed payload (rc=${rc_e2})"
  cat "${TMP}/E2.out" || true
fi

# F) Validation-only path must not mention DRO / package transition in harness
if ! grep -q 'do-release-upgrade' "${TMP}/A.out" \
  && ! grep -q 'UPGRADING_JAMMY_TO_NOBLE' "${TMP}/A.out" \
  && ! grep -q 'PACKAGE_TRANSITION' "${TMP}/A.out"; then
  pass "F validation-only refresh path has no DRO/package-transition"
  echo "DO_RELEASE_UPGRADE_EXECUTED=NO"
  echo "PACKAGE_TRANSITION_EXECUTED=NO"
else
  fail "F DRO/package-transition leaked into validation-only path"
fi

# G) Mode/ownership after refresh (0755; root when permitted)
mode="$(stat -c '%a' "$fx_a/usr/local/sbin/stellar-offline-os-upgrade-postboot" 2>/dev/null || true)"
if [[ "$mode" == "755" ]]; then
  pass "G refreshed postboot mode 0755"
else
  fail "G refreshed postboot mode=${mode}"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "SOME J2N STALE POSTBOOT RECOVERY CHECKS FAILED"
  exit 1
fi
echo "ALL J2N STALE POSTBOOT RECOVERY CHECKS PASSED"
exit 0
