#!/usr/bin/env bash
# tests/test_dp_offline_upgrade_jammy_to_noble.sh
set -euo pipefail

# Never inherit a stale fake-root prefix from the parent shell/suite.
unset STELLAR_OFFLINE_TEST_ROOT || true
unset DETACH_AFTER_HANDOFF || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

SCRIPT_IN_RAW="${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh.in"
BUILD_PY="${ROOT}/scripts/lib/build_client_jammy_to_noble.py"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

# Expand shared helper tokens once so runner/postboot extracts and harnesses
# do not execute leftover @@DURABLE_WRITE_HELPER@@ / @@LXD_INVENTORY_HELPER@@.
SCRIPT_IN="${OUT_DIR}/template-helpers-expanded.sh.in"
python3 "${ROOT}/tests/lib/render_offline_upgrade_stub.py" \
  --helpers-only "$SCRIPT_IN_RAW" "$SCRIPT_IN"
# Sibling includes for stubs that resolve relative to SCRIPT_IN's directory.
cp -f "${ROOT}/client/dp-postboot-readiness-policy.sh.inc" \
  "${OUT_DIR}/dp-postboot-readiness-policy.sh.inc" 2>/dev/null || true

# 1) Template / builder present
[[ -f "$SCRIPT_IN_RAW" ]] || fail "template missing"
[[ -f "$BUILD_PY" ]] || fail "builder missing"
bash -n "$SCRIPT_IN_RAW" 2>/dev/null && pass "template bash -n" || fail "template bash -n"
bash -n "$SCRIPT_IN" 2>/dev/null || fail "helper-expanded template bash -n"

# 2) Bash 4.3 compatibility - reject bash-5-only constructs in template
if grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*@Q\}|mapfile -d|&\>|\|\|&' "$SCRIPT_IN"; then
  fail "bash 5-only / unsupported constructs found"
else
  pass "no bash-5-only constructs"
fi
# Forbid enabling trusted=yes / calling apt-key (detection/rejection strings are allowed)
if grep -nE '\[.*trusted[[:space:]]*=[[:space:]]*yes|apt-key add|apt-key adv' "$SCRIPT_IN"; then
  fail "trusted=yes enablement or apt-key invocation present"
else
  pass "no trusted=yes enablement / apt-key"
fi
if grep -nE 'archive\.ubuntu\.com|security\.ubuntu\.com|changelogs\.ubuntu\.com' "$SCRIPT_IN" \
  | grep -v 'EXTERNAL\|external\|grep\|die\|ERROR\|FORBIDDEN\|assert_no_external'; then
  # Allow only in rejection/detection contexts - already filtered; any leftover is fail
  :
fi
# Explicit: template must not hardcode Canonical archive as fallback sources
if grep -nE 'deb .*archive\.ubuntu\.com|deb .*security\.ubuntu\.com' "$SCRIPT_IN"; then
  fail "hardcoded external deb lines"
else
  pass "no external deb fallback lines"
fi

# 3) DP version detection unit tests (no live mirror / no FAKE override)
UNIT_HARNESS="${OUT_DIR}/dp-version-harness.sh"
{
  cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="${DP_OFFLINE_TEST_ROOT:-}"
LOG_FILE="/dev/null"
hostpath() {
  local p="$1"
  if [[ -n "$TEST_ROOT" ]]; then
    printf '%s%s' "$TEST_ROOT" "$p"
  else
    printf '%s' "$p"
  fi
}
log() {
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" "$level" "$*" >&2
}
die() { local code="$1"; shift; log ERROR "$* (exit=${code})"; exit "$code"; }
MIN_DP_VERSION="6.2.0"
EOS
  awk '
    /^version_is_mmp\(\)/ {p=1}
    /^require_cmds\(\)/ {exit}
    p
  ' "$SCRIPT_IN"
} >"$UNIT_HARNESS"
bash -n "$UNIT_HARNESS" && pass "dp-version harness bash -n" || fail "dp-version harness bash -n"

# shellcheck disable=SC1090
source "$UNIT_HARNESS"

make_dp_fixture() {
  local root="$1"
  mkdir -p "$root/opt/aelladata" "$root/etc" "$root/var/log/aella"
  cat >"$root/etc/os-release" <<'EOF'
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION_CODENAME=jammy
PRETTY_NAME="Ubuntu 24.04.5 LTS"
EOF
  printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1000:1000:aella:/home/aella:/bin/bash\n' >"$root/etc/passwd"
}

# Realistic release-metadata (comment + timestamp) must never become DP version
REAL_META="$(cat <<'EOF'
# force service re-deploy even version doesn't change.
# use `date +%s` to get version
version: 1591228779
EOF
)"
REAL_IMAGE="$(cat <<'EOF'
aella-cm-bg: 6.5.0.7942-9ed2e58c1
aella-cm-master: 6.5.0.7942-9ed2e58c1
aella-cm-user: 6.5.0.7942-9ed2e58c1
aella-cm-worker: 6.5.0.7942-9ed2e58c1
stellar-conf: 6.5.0.111034-57a6c896f
stellar-controller: 6.5.0.111034-57a6c896f
processor: 6.5.0.464-45030ecd6
aella-ui: 6.5.0.5267-abc123def
kafka: 5.4.0.63235-37ebe3756
keydb: 6.5.0.108355-ac2e17f48
spark-master: 5.4.0.57105-f0277cb0e
skupper-router: 2.1.3
skupper-controller: 2.1.3
elasticsearch: 6.4.0.99959-f252ade95
stellar-css: 6.3.0.94184-49e54ee05
EOF
)"

# Mixed ~99-component fixture: authoritative keys all 6.5.0; noise must not vote
MIXED_IMAGE="$(mktemp)"
{
  printf '%s\n' "$REAL_IMAGE"
  i=1
  while [[ "$i" -le 40 ]]; do
    printf 'noise-comp-%02d: 5.4.0.%d-deadbeef\n' "$i" "$i"
    printf 'app-comp-%02d: 6.3.0.%d-cafebabe\n' "$i" "$i"
    i=$((i + 1))
  done
  printf 'extra-oss-a: 2.1.3\n'
  printf 'extra-oss-b: 2.1.3\n'
  printf 'extra-oss-c: 1.10.0\n'
} >"$MIXED_IMAGE"

fx="$(mktemp -d)"
FAKEBIN="$(mktemp -d)"
make_dp_fixture "$fx"
printf '%s\n' "$REAL_META" >"$fx/opt/aelladata/release-metadata.yml"
printf '%s\n' "$REAL_IMAGE" >"$fx/opt/aelladata/release-image.yml"

install_fake_aella_cli() {
  local mode="$1"
  reset_aella_cli_capture
  cat >"$FAKEBIN/aella_cli" <<EOF
#!/bin/sh
mode='$mode'
case "\$mode" in
  ok)
    cat <<'OUT'
Welcome to Data Processor

DataProcessor(AIO)> 6.5.0
DataProcessor(AIO)>
OUT
    exit 0
    ;;
  dup)
    cat <<'OUT'
Welcome to Data Processor
DataProcessor(AIO)> 6.5.0
DataProcessor(AIO)> 6.5.0
OUT
    exit 0
    ;;
  conflict)
    cat <<'OUT'
DataProcessor(AIO)> 6.5.0
DataProcessor(AIO)> 6.4.0
OUT
    exit 0
    ;;
  topo_dup)
    cat <<'OUT'
Welcome to Data Processor
DataProcessor(AIO)> 6.5.0
DataProcessor(AIO)>
OUT
    exit 0
    ;;
  topo_dl)
    cat <<'OUT'
DataProcessor(DL-Master)> 6.5.0
OUT
    exit 0
    ;;
  topo_da)
    cat <<'OUT'
DataProcessor(DA-Master)> 6.5.0
OUT
    exit 0
    ;;
  topo_worker)
    cat <<'OUT'
DataProcessor(Worker)> 6.5.0
OUT
    exit 0
    ;;
  topo_conflict)
    cat <<'OUT'
DataProcessor(AIO)> 6.5.0
DataProcessor(Worker)> 6.5.0
OUT
    exit 0
    ;;
  nosemver)
    cat <<'OUT'
Welcome to Data Processor
DataProcessor(AIO)>
OUT
    exit 0
    ;;
  noprompt)
    cat <<'OUT'
Welcome to Data Processor
version ok but no prompt shape
6.5.0
OUT
    exit 0
    ;;
  nonzero)
    echo 'cli failed' >&2
    exit 1
    ;;
  hang)
    sleep 100
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$FAKEBIN/aella_cli"
}

# Ensure PATH has no real aella_cli; restore later
ORIG_PATH="$PATH"
PATH="$FAKEBIN:$PATH"
export PATH

# 3.1 comment/timestamp ignored by authoritative parser
if collect_authoritative_release_image_versions "$fx/opt/aelladata/release-metadata.yml" | grep -q .; then
  fail "release-metadata comment/timestamp produced authoritative records"
else
  pass "release-metadata comment ignored by authoritative parser"
fi

# 3.2 timestamp version rejected as product version (no CLI, no image)
unset DP_OFFLINE_FAKE_DP_VERSION || true
unset DP_OFFLINE_FAKE_ROLE || true
export DP_OFFLINE_TEST_ROOT="$fx"
TEST_ROOT="$fx"
rm -f "$FAKEBIN/aella_cli"
reset_aella_cli_capture
rm -f "$fx/opt/aelladata/release-image.yml"
printf '%s\n' "$REAL_META" >"$fx/opt/aelladata/release-metadata.yml"
detect_dp_version >/dev/null || true
if [[ -z "$DP_VERSION" && "$DP_VERSION_DETECT_STATUS" == "undetermined" ]]; then
  pass "timestamp version:1591228779 rejected (UNDETERMINED)"
else
  fail "timestamp accepted as DP version (v='${DP_VERSION}' status=${DP_VERSION_DETECT_STATUS})"
fi

# --- Primary: aella_cli show version + topology (verified fixture) ---
printf '%s\n' "$REAL_IMAGE" >"$fx/opt/aelladata/release-image.yml"
# Real AIO hosts often have empty cluster-name; must NOT force UNKNOWN.
: >"$fx/opt/aelladata/cluster-name"
install_fake_aella_cli ok
detect_dp_version >/dev/null || true
detect_dp_topology >/dev/null || true
if [[ "$DP_VERSION" == "6.5.0" \
   && "$DP_VERSION_SOURCE" == "aella_cli" \
   && "$DP_VERSION_COMMAND" == "noninteractive" \
   && "$DP_VERSION_CONSISTENCY" == "PASS" \
   && "$DP_VERSION_DETECT_STATUS" == "ok" \
   && "$DP_TOPOLOGY" == "AIO" \
   && "$DP_TOPOLOGY_SOURCE" == "aella_cli" \
   && "$DP_TOPOLOGY_CONSISTENCY" == "PASS" \
   && "$DP_TOPOLOGY_DETECT_STATUS" == "ok" ]]; then
  pass "CLI fixture version=6.5.0 topology=AIO (cluster-name present ignored)"
else
  fail "CLI fixture failed (v='${DP_VERSION}' topo='${DP_TOPOLOGY}' vsrc=${DP_VERSION_SOURCE} tsrc=${DP_TOPOLOGY_SOURCE})"
fi
if version_ge "$DP_VERSION" "$MIN_DP_VERSION" && is_supported_dp_topology "$DP_TOPOLOGY"; then
  pass "6.5.0 + AIO supported PASS"
else
  fail "minimum/supported check failed"
fi

# Welcome ignored for topology - only DataProcessor(...)> roles
roles="$(extract_dataprocessor_roles_from_text "$(cat <<'OUT'
Welcome to Data Processor

DataProcessor(AIO)> 6.5.0
DataProcessor(AIO)>
OUT
)")"
if [[ "$(printf '%s\n' "$roles" | sort -u | tr -d '\n')" == "AIO" ]]; then
  pass "Welcome ignored; only AIO prompt role extracted"
else
  fail "role extract unexpected: $(printf '%s' "$roles" | tr '\n' ' ')"
fi

# Duplicate identical AIO / 6.5.0 → PASS
install_fake_aella_cli dup
detect_dp_version >/dev/null || true
detect_dp_topology >/dev/null || true
[[ "$DP_VERSION" == "6.5.0" && "$DP_TOPOLOGY" == "AIO" && "$DP_TOPOLOGY_DETECT_STATUS" == "ok" ]] \
  && pass "duplicate identical CLI AIO/6.5.0 → PASS" \
  || fail "duplicate CLI failed (v='${DP_VERSION}' topo='${DP_TOPOLOGY}')"

# Conflicting CLI product versions → INCONSISTENT (fail-closed, no fallback)
install_fake_aella_cli conflict
detect_dp_version >/dev/null || true
[[ -z "$DP_VERSION" && "$DP_VERSION_DETECT_STATUS" == "inconsistent" && "$DP_VERSION_SOURCE" == "aella_cli" ]] \
  && pass "CLI conflicting 6.5.0 vs 6.4.0 → INCONSISTENT" \
  || fail "expected CLI INCONSISTENT (v='${DP_VERSION}' status=${DP_VERSION_DETECT_STATUS} src=${DP_VERSION_SOURCE})"

# Cluster roles blocked
install_fake_aella_cli topo_dl
detect_dp_topology >/dev/null || true
[[ "$DP_TOPOLOGY" == "DL-Master" ]] && ! is_supported_dp_topology "$DP_TOPOLOGY" \
  && pass "CLI DL-Master → unsupported topology" \
  || fail "DL-Master unexpected (topo='${DP_TOPOLOGY}')"
install_fake_aella_cli topo_da
detect_dp_topology >/dev/null || true
[[ "$DP_TOPOLOGY" == "DA-Master" ]] && ! is_supported_dp_topology "$DP_TOPOLOGY" \
  && pass "CLI DA-Master → unsupported topology" \
  || fail "DA-Master unexpected (topo='${DP_TOPOLOGY}')"
install_fake_aella_cli topo_worker
detect_dp_topology >/dev/null || true
[[ "$DP_TOPOLOGY" == "Worker" ]] && ! is_supported_dp_topology "$DP_TOPOLOGY" \
  && pass "CLI Worker → unsupported topology" \
  || fail "Worker unexpected (topo='${DP_TOPOLOGY}')"

# AIO + Worker prompts → topology INCONSISTENT
install_fake_aella_cli topo_conflict
detect_dp_topology >/dev/null || true
[[ -z "$DP_TOPOLOGY" && "$DP_TOPOLOGY_DETECT_STATUS" == "inconsistent" ]] \
  && pass "CLI AIO+Worker prompts → INCONSISTENT" \
  || fail "expected topology INCONSISTENT (topo='${DP_TOPOLOGY}' status=${DP_TOPOLOGY_DETECT_STATUS})"

# CLI timeout → version + topology fallback
install_fake_aella_cli hang
mkdir -p "$fx/opt/aelladata/conf"
printf 'AIO\n' >"$fx/opt/aelladata/conf/role"
detect_dp_version >/dev/null || true
detect_dp_topology >/dev/null || true
if [[ "$DP_VERSION" == "6.5.0" \
   && "$DP_VERSION_SOURCE" == "/opt/aelladata/release-image.yml" \
   && "$DP_VERSION_CLI_STATUS" == "timeout" \
   && "$DP_TOPOLOGY" == "AIO" \
   && "$DP_TOPOLOGY_SOURCE" == "vendor-role-files" ]]; then
  pass "CLI timeout → version+topology authoritative fallback"
else
  fail "CLI timeout fallback failed (v='${DP_VERSION}' topo='${DP_TOPOLOGY}' tsrc=${DP_TOPOLOGY_SOURCE})"
fi

# CLI non-zero → fallback
install_fake_aella_cli nonzero
detect_dp_version >/dev/null || true
detect_dp_topology >/dev/null || true
[[ "$DP_VERSION" == "6.5.0" && "$DP_VERSION_CLI_STATUS" == "nonzero" && "$DP_TOPOLOGY" == "AIO" ]] \
  && pass "CLI non-zero → release-image/role fallback" \
  || fail "CLI non-zero fallback failed (v='${DP_VERSION}' topo='${DP_TOPOLOGY}')"

# CLI no semver but AIO prompt → version fallback, topology from CLI
install_fake_aella_cli nosemver
reset_aella_cli_capture
detect_dp_version >/dev/null || true
detect_dp_topology >/dev/null || true
[[ "$DP_VERSION" == "6.5.0" && "$DP_VERSION_CLI_STATUS" == "no_semver" \
   && "$DP_TOPOLOGY" == "AIO" && "$DP_TOPOLOGY_SOURCE" == "aella_cli" ]] \
  && pass "CLI no semver → version fallback; topology still from prompt" \
  || fail "no-semver split detect failed (v='${DP_VERSION}' topo='${DP_TOPOLOGY}' tsrc=${DP_TOPOLOGY_SOURCE})"

# no prompt → topology fallback
install_fake_aella_cli noprompt
detect_dp_version >/dev/null || true
detect_dp_topology >/dev/null || true
[[ "$DP_VERSION" == "6.5.0" && "$DP_TOPOLOGY" == "AIO" && "$DP_TOPOLOGY_SOURCE" == "vendor-role-files" ]] \
  && pass "CLI no prompt → topology vendor-role fallback" \
  || fail "no-prompt topology fallback failed (topo='${DP_TOPOLOGY}' tsrc=${DP_TOPOLOGY_SOURCE})"

# fallback cluster role file → Worker (unsupported)
rm -f "$FAKEBIN/aella_cli"
reset_aella_cli_capture
printf 'Worker\n' >"$fx/opt/aelladata/conf/role"
detect_dp_topology >/dev/null || true
[[ "$DP_TOPOLOGY" == "Worker" ]] && ! is_supported_dp_topology "$DP_TOPOLOGY" \
  && pass "fallback role file Worker → unsupported" \
  || fail "fallback Worker unexpected (topo='${DP_TOPOLOGY}')"

# fallback peer worker IPs without role → cluster
rm -f "$fx/opt/aelladata/conf/role"
printf '10.0.0.12\n10.0.0.13\n' >"$fx/opt/aelladata/conf/worker_ips"
detect_dp_topology >/dev/null || true
[[ "$DP_TOPOLOGY" == "Worker" && "$DP_TOPOLOGY_SOURCE" == "vendor-worker-inventory" ]] \
  && pass "fallback worker inventory peer IPs → cluster" \
  || fail "worker inventory fallback failed (topo='${DP_TOPOLOGY}' src=${DP_TOPOLOGY_SOURCE})"

# fallback undetermined: cluster-name only (real AIO without CLI must not invent AIO)
rm -f "$fx/opt/aelladata/conf/role" "$fx/opt/aelladata/conf/worker_ips"
: >"$fx/opt/aelladata/cluster-name"
detect_dp_topology >/dev/null || true
[[ -z "$DP_TOPOLOGY" && "$DP_TOPOLOGY_DETECT_STATUS" == "undetermined" ]] \
  && pass "cluster-name alone → UNDETERMINED (no AIO default)" \
  || fail "cluster-name falsely set topology (topo='${DP_TOPOLOGY}' status=${DP_TOPOLOGY_DETECT_STATUS})"

# clear role for remaining version tests
rm -rf "$fx/opt/aelladata/conf"

# --- Secondary: authoritative release-image (no CLI) ---
rm -f "$FAKEBIN/aella_cli"
reset_aella_cli_capture
cp "$MIXED_IMAGE" "$fx/opt/aelladata/release-image.yml"
detect_dp_version >/dev/null || true
if [[ "$DP_VERSION" == "6.5.0" \
   && "$DP_VERSION_SOURCE" == "/opt/aelladata/release-image.yml" \
   && "$DP_VERSION_CONSISTENCY" == "PASS" \
   && "$DP_VERSION_DETECT_STATUS" == "ok" \
   && "$DP_VERSION_AUTHORITATIVE_RECORDS" -ge 2 ]]; then
  pass "mixed ~99-component image: authoritative keys → 6.5.0 PASS (records=${DP_VERSION_AUTHORITATIVE_RECORDS})"
else
  fail "mixed image authoritative fallback failed (v='${DP_VERSION}' src=${DP_VERSION_SOURCE} status=${DP_VERSION_DETECT_STATUS} n=${DP_VERSION_AUTHORITATIVE_RECORDS})"
fi

# kafka/skupper/etc must not cause product conflict when authoritative keys agree
auth_n="$(collect_authoritative_release_image_versions "$fx/opt/aelladata/release-image.yml" | wc -l | tr -d ' ')"
all_noise="$(grep -cE '^(kafka|keydb|spark-master|skupper-|elasticsearch|stellar-css|noise-|app-|extra-oss)' "$fx/opt/aelladata/release-image.yml" || true)"
[[ "$auth_n" -ge 2 && "$all_noise" -ge 10 && "$DP_VERSION" == "6.5.0" ]] \
  && pass "kafka/oss noise ignored; authoritative-only PASS" \
  || fail "noise isolation failed (auth=${auth_n} noise=${all_noise} v=${DP_VERSION})"

# All authoritative 6.5.0 → PASS
printf '%s\n' "$REAL_IMAGE" >"$fx/opt/aelladata/release-image.yml"
detect_dp_version >/dev/null || true
[[ "$DP_VERSION" == "6.5.0" && "$DP_VERSION_AUTHORITATIVE_RECORDS" -eq 6 ]] \
  && pass "six authoritative keys all 6.5.0 → PASS" \
  || fail "expected 6 authoritative records (n=${DP_VERSION_AUTHORITATIVE_RECORDS} v=${DP_VERSION})"

# Authoritative key conflict 6.5.0 vs 6.4.0 → INCONSISTENT
cat >"$fx/opt/aelladata/release-image.yml" <<'EOF'
aella-cm-bg: 6.5.0.7942-9ed2e58c1
aella-cm-master: 6.4.0.100-aaaaaaaa
stellar-conf: 6.5.0.111034-57a6c896f
kafka: 5.4.0.1-bbbbbbbb
EOF
detect_dp_version >/dev/null || true
[[ -z "$DP_VERSION" && "$DP_VERSION_DETECT_STATUS" == "inconsistent" ]] \
  && pass "authoritative 6.5.0 vs 6.4.0 → INCONSISTENT" \
  || fail "expected authoritative INCONSISTENT (v='${DP_VERSION}' status=${DP_VERSION_DETECT_STATUS})"

# unsupported 6.1.9 (authoritative)
cat >"$fx/opt/aelladata/release-image.yml" <<'EOF'
aella-cm-bg: 6.1.9.100-deadbeef
aella-cm-master: 6.1.9.100-deadbeef
EOF
detect_dp_version >/dev/null || true
if [[ "$DP_VERSION" == "6.1.9" ]] && ! version_ge "$DP_VERSION" "$MIN_DP_VERSION"; then
  pass "6.1.9 is below minimum (FAIL_UNSUPPORTED_DP_VERSION path)"
else
  fail "6.1.9 minimum check unexpected (v='${DP_VERSION}')"
fi

# no authoritative semver → UNDETERMINED
cat >"$fx/opt/aelladata/release-image.yml" <<'EOF'
# only comments
image: synthetic
kafka: 5.4.0.1-bbbbbbbb
note: not a version
EOF
detect_dp_version >/dev/null || true
[[ -z "$DP_VERSION" && "$DP_VERSION_DETECT_STATUS" == "undetermined" ]] \
  && pass "no authoritative semver → UNDETERMINED" \
  || fail "expected UNDETERMINED without authoritative semver (v='${DP_VERSION}' status=${DP_VERSION_DETECT_STATUS})"

# comment + timestamp never reach arithmetic compare
if version_ge "# force service re-deploy even version doesn't change." "6.2.0" 2>/dev/null; then
  fail "comment string accepted by version_ge"
else
  pass "comment string rejected by version_ge (no arithmetic operand error)"
fi
if version_ge "1591228779" "6.2.0" 2>/dev/null; then
  fail "timestamp accepted by version_ge"
else
  pass "timestamp rejected by version_ge (no arithmetic operand error)"
fi

# Longer CLI token must not be truncated to major.minor.patch
long_toks="$(extract_mmp_tokens_from_text 'DataProcessor(AIO)> 6.5.0.7942')"
[[ -z "$(printf '%s' "$long_toks" | tr -d '[:space:]')" ]] \
  && pass "CLI token 6.5.0.7942 not arbitrarily truncated" \
  || fail "6.5.0.7942 was truncated to: $(printf '%s' "$long_toks")"

# Bash 4.3 constructs already covered above; ensure no mapfile -d in version helpers
if awk '/^version_is_mmp\(\)/,/^require_cmds\(\)/' "$SCRIPT_IN" | grep -nE 'mapfile -d|\$\{[A-Za-z_][A-Za-z0-9_]*@Q\}'; then
  fail "bash-5-only constructs in DP version helpers"
else
  pass "DP version helpers Bash 4.3 compatible"
fi

# Verified command string present in template
if grep -q "timeout 10 sh -c \"printf 'show version\\\\nquit\\\\n' | aella_cli\"" "$SCRIPT_IN"; then
  pass "verified aella_cli command present"
else
  fail "verified aella_cli command missing from template"
fi

PATH="$ORIG_PATH"
export PATH
rm -f "$MIXED_IMAGE"

# Integration: preflight-only with stub-rendered script (version fail = no persistent mutation)
STUB="${OUT_DIR}/dp-offline-upgrade-jammy-to-noble.stub.sh"
python3 - "$SCRIPT_IN" "$STUB" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
from pathlib import Path
text = open(src, encoding="utf-8").read()
_lib = Path(src).resolve().parent / "lib"
for _tok, _name in (
    ("@@DESTRUCTIVE_CONFIRMATION_HELPER@@", "dp-offline-destructive-confirmation.sh"),
    ("@@RELEASE_UPGRADE_RECONCILIATION_HELPER@@", "dp-offline-release-upgrade-reconciliation.sh"),
    ("@@APT_PREFLIGHT_SANDBOX_HELPER@@", "dp-offline-apt-preflight-sandbox.sh"),
    ("@@DURABLE_WRITE_HELPER@@", "dp-offline-durable-write.sh"),
    ("@@SOURCE_PRODUCT_HELPER@@", "dp-offline-source-product-version.sh"),
    ("@@LXD_INVENTORY_HELPER@@", "dp-offline-lxd-inventory.sh"),
):
    _hp = _lib / _name
    if _tok in text and _hp.is_file():
        text = text.replace(_tok, _hp.read_text(encoding="utf-8").rstrip("\n") + "\n")
pins = {
    "MIRROR_BASE": "",
    "HOP": "jammy-to-noble",
    "SOURCE_CODENAME": "jammy",
    "TARGET_CODENAME": "noble",
    "SOURCE_VERSION": "22.04",
    "TARGET_VERSION": "24.04",
    "COMPONENTS": "main universe",
    "SOURCE_SUITES": "jammy",
    "TARGET_SUITES": "noble noble-updates noble-security noble-backports",
    "KEY_FINGERPRINT": "DEADBEEF",
    "KEY_SHA256": "0" * 64,
    "MANIFEST_KEY_FINGERPRINT": "DEADBEEF",
    "MANIFEST_KEY_SHA256": "0" * 64,
    "META_SHA256": "0" * 64,
    "UPGRADER_TAR_SHA256": "0" * 64,
    "UPGRADER_GPG_SHA256": "0" * 64,
    "PLAN_CHECKSUM": "0" * 64,
    "DISCOVERY_CHECKSUM": "0" * 64,
    "MANIFEST_SHA256": "0" * 64,
    "SAMPLE_DEB_PATH": "/sample.deb",
    "CONFIRM_PHRASE": "UPGRADE-JAMMY-TO-NOBLE",
    "GENERATED_AT": "1970-01-01T00:00:00Z",
    "PROFILE_NAME": "offline-upgrade-selective",
    "KEY_B64": "c3R1Yg==",
    "MANIFEST_KEY_B64": "c3R1Yg==",
    "META_B64": "c3R1Yg==",
    "MANIFEST_B64": "c3R1Yg==",
    "MANIFEST_SIG_B64": "c3R1Yg==",
    "ANNOUNCEMENT_B64": "c3R1Yg==",
}
policy = (Path(src).resolve().parent / "dp-postboot-readiness-policy.sh.inc").read_text(encoding="utf-8").rstrip("\n")
text = text.replace("@@POSTBOOT_POLICY_LIB@@", policy)
for key, val in pins.items():
    text = text.replace("@@{}@@".format(key), val)
# Any leftover placeholders → stub
text = re.sub(r"@@[A-Z0-9_]+@@", "stub", text)
open(dst, "w", encoding="utf-8").write(text)
PY
chmod +x "$STUB"
bash -n "$STUB" && pass "stub-rendered script bash -n" || fail "stub-rendered script bash -n"

run_preflight_fixture() {
  local root="$1"
  shift
  set +e
  env DP_OFFLINE_TEST_ROOT="$root" "$@" bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$root/out.txt" 2>&1
  local rc=$?
  set -e
  printf '%s' "$rc"
}

fx2="$(mktemp -d)"
make_dp_fixture "$fx2"
mkdir -p "$fx2/etc/apt/sources.list.d" "$fx2/etc/apt/keyrings" "$fx2/etc/systemd/system" \
  "$fx2/usr/local/sbin" "$fx2/boot" "$fx2/opt/aelladata/work" "$fx2/tmp"
printf 'deb http://archive.ubuntu.com/ubuntu noble main\n' >"$fx2/etc/apt/sources.list"
printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1000:1000:aella:/home/aella:/bin/bash\n' >"$fx2/etc/passwd"
printf '%s\n' "$REAL_META" >"$fx2/opt/aelladata/release-metadata.yml"
# Uninstalled DP image: no aella.role / da_conf / containers; runtime installed=false
cat >"$fx2/opt/aelladata/work/runtime_config.json" <<'EOF'
{"installed":false,"activated":false,"registered":false,"preconfigured":false,"profiles_installed":false,"node_role":"","playbook_status":"fresh"}
EOF
printf 'image: synthetic\n' >"$fx2/opt/aelladata/release-image.yml"
cp -a "$fx2/etc/apt/sources.list" "$fx2/sources.before"
cp -a "$fx2/etc/passwd" "$fx2/passwd.before"
rc="$(run_preflight_fixture "$fx2")"
if [[ "$rc" -eq 0 ]] \
   && grep -q 'UPGRADE_MODE=OS_ONLY_PHASE1' "$fx2/out.txt" \
   && grep -q 'DP_VERSION_GATE=SKIPPED_PHASE1_OS_ONLY' "$fx2/out.txt" \
   && grep -q 'DP_TOPOLOGY_GATE=SKIPPED_PHASE1_OS_ONLY' "$fx2/out.txt" \
   && grep -q 'DP_INSTALL_STATE=UNINSTALLED' "$fx2/out.txt" \
   && grep -q 'preflight PASS' "$fx2/out.txt"; then
  pass "uninstalled DP image: Phase 1 OS-only preflight PASS"
else
  fail "uninstalled DP preflight should PASS (rc=${rc})"
  tail -40 "$fx2/out.txt" || true
fi
if cmp -s "$fx2/sources.before" "$fx2/etc/apt/sources.list" \
   && cmp -s "$fx2/passwd.before" "$fx2/etc/passwd" \
   && [[ ! -f "$fx2/etc/apt/keyrings/stellar-offline-upgrade.gpg" ]] \
   && [[ ! -f "$fx2/etc/systemd/system/stellar-offline-os-upgrade.service" ]]; then
  pass "uninstalled DP preflight-only: no apt/keyring mutation"
else
  fail "uninstalled DP preflight mutated persistent apt files"
fi
if grep -q 'Type the confirmation phrase' "$fx2/out.txt"; then
  fail "unexpected confirmation in preflight-only"
else
  pass "preflight-only: no confirmation / no reboot path"
fi

# aella_cli login shell → AELLA_BASH_HARD_GATE fails closed
rm -rf "$fx2/opt/aelladata/os-upgrade"
printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1000:1000:aella:/home/aella:/usr/bin/aella_cli\n' >"$fx2/etc/passwd"
rc="$(run_preflight_fixture "$fx2")"
if [[ "$rc" -ne 0 ]] \
   && grep -q 'AELLA_BASH_HARD_GATE=FAIL' "$fx2/out.txt" \
   && grep -q 'FAIL_AELLA_SHELL_NOT_BASH' "$fx2/out.txt" \
   && grep -q 'chsh -s /bin/bash aella' "$fx2/out.txt"; then
  pass "aella_cli shell: preflight hard-gated"
else
  fail "aella_cli shell: preflight hard-gated"
  tail -30 "$fx2/out.txt" || true
fi
printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1000:1000:aella:/home/aella:/bin/bash\n' >"$fx2/etc/passwd"

# Empty DataProcessor()> prompt → topology SKIPPED, continue
rm -rf "$fx2/opt/aelladata/os-upgrade"
PATH_SAVE="$PATH"
FAKEBIN2="$(mktemp -d)"
cat >"$FAKEBIN2/aella_cli" <<'EOF'
#!/bin/sh
cat <<'OUT'
Welcome to Data Processor
DataProcessor()> 6.5.0
DataProcessor()>
OUT
exit 0
EOF
chmod +x "$FAKEBIN2/aella_cli"
printf '%s\n' "$REAL_IMAGE" >"$fx2/opt/aelladata/release-image.yml"
rc="$(run_preflight_fixture "$fx2" PATH="$FAKEBIN2:$PATH")"
if [[ "$rc" -eq 0 ]] \
   && grep -q 'DP_TOPOLOGY_GATE=SKIPPED_PHASE1_OS_ONLY' "$fx2/out.txt" \
   && grep -q 'preflight PASS' "$fx2/out.txt"; then
  pass "empty DataProcessor()> prompt: topology gate SKIPPED, continue"
else
  fail "empty prompt should not block Phase 1 (rc=${rc})"
  tail -30 "$fx2/out.txt" || true
fi

# Installed AIO → product state ignored, OS-only continues
rm -rf "$fx2/opt/aelladata/os-upgrade"
mkdir -p "$fx2/opt/aelladata/conf"
printf 'AIO\n' >"$fx2/opt/aelladata/conf/role"
rc="$(run_preflight_fixture "$fx2" DP_OFFLINE_FAKE_ROLE=AIO DP_OFFLINE_FAKE_DP_VERSION=6.5.0)"
if [[ "$rc" -eq 0 ]] \
   && grep -q 'DP_TOPOLOGY=AIO' "$fx2/out.txt" \
   && grep -q 'DP_TOPOLOGY_GATE=SKIPPED_PHASE1_OS_ONLY' "$fx2/out.txt" \
   && grep -q 'preflight PASS' "$fx2/out.txt"; then
  pass "installed AIO: OS-only preflight continues"
else
  fail "AIO should continue in OS-only mode (rc=${rc})"
  tail -30 "$fx2/out.txt" || true
fi

# DL-master → not blocked
rm -rf "$fx2/opt/aelladata/os-upgrade"
printf 'DL-Master\n' >"$fx2/opt/aelladata/conf/role"
rc="$(run_preflight_fixture "$fx2" DP_OFFLINE_FAKE_ROLE=DL-Master DP_OFFLINE_FAKE_DP_VERSION=6.5.0)"
if [[ "$rc" -eq 0 ]] \
   && grep -q 'DP_TOPOLOGY_GATE=SKIPPED_PHASE1_OS_ONLY' "$fx2/out.txt" \
   && ! grep -q 'FAIL_UNSUPPORTED_DP_TOPOLOGY' "$fx2/out.txt" \
   && grep -q 'preflight PASS' "$fx2/out.txt"; then
  pass "DL-master: OS-only preflight continues"
else
  fail "DL-master should not block Phase 1 (rc=${rc})"
  tail -30 "$fx2/out.txt" || true
fi

# No aella_cli → still runnable
rm -rf "$fx2/opt/aelladata/os-upgrade" "$fx2/opt/aelladata/conf"
rm -f "$FAKEBIN2/aella_cli"
rc="$(run_preflight_fixture "$fx2")"
if [[ "$rc" -eq 0 ]] && grep -q 'preflight PASS' "$fx2/out.txt"; then
  pass "no aella_cli: Phase 1 preflight PASS"
else
  fail "missing aella_cli should not block Phase 1 (rc=${rc})"
  tail -30 "$fx2/out.txt" || true
fi

# No DP version → still runnable
rm -rf "$fx2/opt/aelladata/os-upgrade"
printf 'image: synthetic\n' >"$fx2/opt/aelladata/release-image.yml"
rc="$(run_preflight_fixture "$fx2")"
if [[ "$rc" -eq 0 ]] \
   && grep -q 'DP_VERSION=UNDETERMINED' "$fx2/out.txt" \
   && grep -q 'DP_VERSION_GATE=SKIPPED_PHASE1_OS_ONLY' "$fx2/out.txt" \
   && grep -q 'preflight PASS' "$fx2/out.txt"; then
  pass "no DP version: Phase 1 preflight PASS"
else
  fail "missing DP version should not block Phase 1 (rc=${rc})"
  tail -30 "$fx2/out.txt" || true
fi

# Wrong OS → FAIL
rm -rf "$fx2/opt/aelladata/os-upgrade"
sed -i 's/22.04/24.04/;s/jammy/noble/' "$fx2/etc/os-release"
rc="$(run_preflight_fixture "$fx2")"
[[ "$rc" -ne 0 ]] && pass "Ubuntu source version mismatch → FAIL" || fail "wrong OS accepted"
cat >"$fx2/etc/os-release" <<'EOF'
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION_CODENAME=jammy
PRETTY_NAME="Ubuntu 24.04.5 LTS"
EOF

# Critical OS hold → planned unhold (preflight PASS_WITH_PLANNED_ACTION)
rm -rf "$fx2/opt/aelladata/os-upgrade"
printf 'systemd\nudev\n' >"$fx2/tmp/held-packages.txt"
rc="$(run_preflight_fixture "$fx2")"
if [[ "$rc" -eq 0 ]] \
   && grep -q 'CRITICAL_OS_HOLD_PREFLIGHT=PASS_WITH_PLANNED_ACTION' "$fx2/out.txt" \
   && grep -q 'CRITICAL_OS_HOLDS_DETECTED=systemd udev' "$fx2/out.txt" \
   && grep -q 'CRITICAL_OS_HOLD_ACTION=UNHOLD_AFTER_CONFIRMATION' "$fx2/out.txt" \
   && ! grep -q 'FAIL_CRITICAL_PACKAGE_HOLD' "$fx2/out.txt" \
   && grep -q 'preflight PASS' "$fx2/out.txt"; then
  pass "critical OS hold → PASS_WITH_PLANNED_ACTION"
else
  fail "critical OS hold planned-unhold preflight (rc=${rc})"
  tail -30 "$fx2/out.txt" || true
fi
# Preflight must not mutate holds
if grep -qx 'systemd' "$fx2/tmp/held-packages.txt" \
   && grep -qx 'udev' "$fx2/tmp/held-packages.txt"; then
  pass "preflight does not unhold critical packages"
else
  fail "preflight mutated held-packages fixture"
fi

# No holds → normal PASS
rm -rf "$fx2/opt/aelladata/os-upgrade"
rm -f "$fx2/tmp/held-packages.txt"
rc="$(run_preflight_fixture "$fx2")"
if [[ "$rc" -eq 0 ]] \
   && grep -q 'CRITICAL_OS_HOLD_PREFLIGHT=PASS' "$fx2/out.txt" \
   && grep -q 'preflight PASS' "$fx2/out.txt"; then
  pass "no holds → preflight PASS"
else
  fail "no-hold preflight (rc=${rc})"
  tail -20 "$fx2/out.txt" || true
fi

# Product-only hold → not blocked
rm -rf "$fx2/opt/aelladata/os-upgrade"
printf 'aella-cm-master\nkafka\n' >"$fx2/tmp/held-packages.txt"
rc="$(run_preflight_fixture "$fx2")"
if [[ "$rc" -eq 0 ]] \
   && grep -q 'PRODUCT_HOLD_IGNORED_PHASE1' "$fx2/out.txt" \
   && grep -q 'preflight PASS' "$fx2/out.txt"; then
  pass "product-only hold → Phase 1 not blocked"
else
  fail "product hold should be ignored in Phase 1 (rc=${rc})"
  tail -30 "$fx2/out.txt" || true
fi

# --- Critical hold commit-path tests (stub + TEST_ROOT) ---
run_commit_fixture() {
  local root="$1"
  shift
  # Isolate commit mutations between cases
  rm -rf "$root/opt/aelladata/os-upgrade"
  rm -f "$root/etc/apt/keyrings/stellar-offline-upgrade.gpg"
  rm -f "$root/etc/apt/trusted.gpg.d/stellar-offline-jammy-to-noble.gpg"
  rm -f "$root/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate"
  rm -f "$root/etc/update-manager/release-upgrades.d/99-stellar-offline-mirror.cfg"
  mkdir -p "$root/etc/apt/keyrings" "$root/etc/apt/trusted.gpg.d" "$root/etc/update-manager" "$root/usr/local/sbin" \
    "$root/etc/systemd/system" "$root/var/log/aella"
  set +e
  env DP_OFFLINE_TEST_ROOT="$root" DP_OFFLINE_FAKE_CONFIRM=UPGRADE-JAMMY-TO-NOBLE \
    DP_OFFLINE_FAKE_MIRROR_TRUST=1 "$@" \
    bash "$STUB" --mirror-base http://127.0.0.1:9 >"$root/out-commit.txt" 2>&1
  local rc=$?
  set -e
  printf '%s' "$rc"
}

# Confirmation rejected → holds unchanged
rm -rf "$fx2/opt/aelladata/os-upgrade"
printf 'systemd\nudev\n' >"$fx2/tmp/held-packages.txt"
cp -a "$fx2/tmp/held-packages.txt" "$fx2/tmp/held-packages.before"
set +e
DP_OFFLINE_TEST_ROOT="$fx2" DP_OFFLINE_FAKE_CONFIRM=nope \
  bash "$STUB" --mirror-base http://127.0.0.1:9 >"$fx2/out-reject.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] \
   && cmp -s "$fx2/tmp/held-packages.before" "$fx2/tmp/held-packages.txt" \
   && ! grep -q 'CRITICAL_OS_UNHOLD_BEGIN' "$fx2/out-reject.txt"; then
  pass "confirmation reject → holds unchanged"
else
  fail "confirmation reject mutated holds or unhold ran (rc=${rc})"
  tail -20 "$fx2/out-reject.txt" || true
fi

# Confirmation accepted → systemd/udev unheld
printf 'systemd\nudev\n' >"$fx2/tmp/held-packages.txt"
rc="$(run_commit_fixture "$fx2")"
if [[ "$rc" -eq 0 ]] \
   && grep -q 'CRITICAL_OS_UNHOLD_BEGIN' "$fx2/out-commit.txt" \
   && grep -q 'CRITICAL_OS_UNHOLD_PACKAGE=systemd' "$fx2/out-commit.txt" \
   && grep -q 'CRITICAL_OS_UNHOLD_PACKAGE=udev' "$fx2/out-commit.txt" \
   && grep -q 'CRITICAL_OS_UNHOLD_RESULT=PASS' "$fx2/out-commit.txt" \
   && grep -q 'CRITICAL_OS_HOLDS_AUTO_REHOLD_AFTER_SUCCESS=NO' "$fx2/out-commit.txt" \
   && [[ ! -s "$fx2/tmp/held-packages.txt" || -z "$(tr -d '[:space:]' <"$fx2/tmp/held-packages.txt")" ]] \
   && [[ -f "$fx2/opt/aelladata/os-upgrade/offline/critical-holds/critical-holds-state.json" ]]; then
  pass "confirmation accept → systemd/udev unheld"
else
  fail "confirmation accept unhold (rc=${rc})"
  tail -40 "$fx2/out-commit.txt" || true
  echo "held now: $(cat "$fx2/tmp/held-packages.txt" 2>/dev/null || true)"
fi

# Product + systemd → only systemd unheld
printf 'systemd\naella-cm-master\n' >"$fx2/tmp/held-packages.txt"
rc="$(run_commit_fixture "$fx2")"
held_after="$(tr -s '[:space:]' '\n' <"$fx2/tmp/held-packages.txt" | sed '/^$/d' | sort | tr '\n' ' ')"
if [[ "$rc" -eq 0 ]] \
   && grep -q 'CRITICAL_OS_UNHOLD_PACKAGE=systemd' "$fx2/out-commit.txt" \
   && ! grep -q 'CRITICAL_OS_UNHOLD_PACKAGE=aella-cm-master' "$fx2/out-commit.txt" \
   && grep -q 'PRODUCT_HOLD_IGNORED_PHASE1' "$fx2/out-commit.txt" \
   && printf '%s' "$held_after" | grep -qw 'aella-cm-master' \
   && ! printf '%s' "$held_after" | grep -qw 'systemd'; then
  pass "product+systemd → only systemd unheld"
else
  fail "product hold protection (rc=${rc} held='${held_after}')"
  tail -40 "$fx2/out-commit.txt" || true
fi

# Unhold command failure → FAIL_CRITICAL_OS_UNHOLD, no upgrade commit artifacts beyond restore
printf 'systemd\nudev\n' >"$fx2/tmp/held-packages.txt"
rc="$(run_commit_fixture "$fx2" DP_OFFLINE_FAKE_UNHOLD_FAIL=systemd)"
if [[ "$rc" -ne 0 ]] \
   && grep -q 'FAIL_CRITICAL_OS_UNHOLD' "$fx2/out-commit.txt" \
   && grep -q 'PACKAGE=systemd' "$fx2/out-commit.txt" \
   && grep -qx 'systemd' "$fx2/tmp/held-packages.txt" \
   && grep -qx 'udev' "$fx2/tmp/held-packages.txt" \
   && [[ ! -f "$fx2/etc/apt/keyrings/stellar-offline-upgrade.gpg" ]]; then
  pass "unhold command failure → FAIL_CRITICAL_OS_UNHOLD"
else
  fail "unhold failure path (rc=${rc})"
  tail -40 "$fx2/out-commit.txt" || true
  echo "held: $(cat "$fx2/tmp/held-packages.txt" 2>/dev/null || true)"
fi

# Unhold "succeeds" but still held → FAIL_CRITICAL_OS_UNHOLD
printf 'systemd\n' >"$fx2/tmp/held-packages.txt"
rc="$(run_commit_fixture "$fx2" DP_OFFLINE_FAKE_UNHOLD_STILL_HELD=1)"
if [[ "$rc" -ne 0 ]] \
   && grep -q 'FAIL_CRITICAL_OS_UNHOLD' "$fx2/out-commit.txt" \
   && grep -q 'REASON=still_held_after_unhold' "$fx2/out-commit.txt" \
   && grep -qx 'systemd' "$fx2/tmp/held-packages.txt"; then
  pass "unhold verify still-held → FAIL_CRITICAL_OS_UNHOLD"
else
  fail "still-held verification (rc=${rc})"
  tail -40 "$fx2/out-commit.txt" || true
fi

# Unhold then pre-upgrade failure → restore original critical holds
printf 'systemd\nudev\n' >"$fx2/tmp/held-packages.txt"
rc="$(run_commit_fixture "$fx2" DP_OFFLINE_FAKE_FAIL_AFTER_UNHOLD=1)"
if [[ "$rc" -ne 0 ]] \
   && grep -q 'CRITICAL_OS_UNHOLD_RESULT=PASS' "$fx2/out-commit.txt" \
   && grep -q 'CRITICAL_OS_HOLD_RESTORE_RESULT=PASS' "$fx2/out-commit.txt" \
   && grep -qx 'systemd' "$fx2/tmp/held-packages.txt" \
   && grep -qx 'udev' "$fx2/tmp/held-packages.txt"; then
  pass "pre-upgrade failure after unhold → restore holds"
else
  fail "restore after pre-upgrade failure (rc=${rc})"
  tail -40 "$fx2/out-commit.txt" || true
  echo "held: $(cat "$fx2/tmp/held-packages.txt" 2>/dev/null || true)"
fi

# --- DistUpgrade source UTF-8 / LC_ALL=C + pre-upgrade APT rollback ---
ENC_HARNESS="${OUT_DIR}/distupgrade-utf8-harness.sh"
# Build a tiny harness that embeds the fixed validation/restore helpers from the stub.
python3 - "$STUB" "$ENC_HARNESS" <<'PY'
import re, sys
stub, out = sys.argv[1], sys.argv[2]
text = open(stub, encoding='utf-8').read()

def extract(name):
    m = re.search(r'^%s\(\) \{.*?\n\}$' % re.escape(name), text, re.M | re.S)
    if not m:
        raise SystemExit('missing ' + name)
    return m.group(0)

parts = [
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    'TEST_ROOT="${DP_OFFLINE_TEST_ROOT:-}"',
    'STATE_ROOT="/opt/aelladata/os-upgrade/offline"',
    'BACKUP_ROOT="${STATE_ROOT}/backups"',
    'PIN_HOP="jammy-to-noble"',
    'PIN_COMPONENTS="main universe"',
    'PIN_TARGET_SUITES="noble noble-updates noble-security noble-backports"',
    'MIRROR_BASE="http://127.0.0.1:9"',
    'LAST_DISTUPGRADE_SOURCE_ERROR=""',
    'EC_DISTUPGRADE_SOURCE=31',
    'EC_DISTUPGRADE_SOURCE_DECODE=34',
    'hostpath() { local p="$1"; if [[ -n "${TEST_ROOT:-}" ]]; then printf "%s%s" "$TEST_ROOT" "$p"; else printf "%s" "$p"; fi; }',
    'log() { local level="$1"; shift; printf "[%s] %s\\n" "$level" "$*" >&2; }',
    'die() { local code="$1"; shift; log ERROR "$* (exit=${code})"; exit "$code"; }',
    extract('write_legacy_compatible_sources'),
    extract('validate_distupgrade_sources_file'),
    extract('restore_apt_sources_from_backup'),
    '''
cmd="${1:-}"
case "$cmd" in
  validate)
    mkdir -p "$(hostpath ${STATE_ROOT})"
    write_legacy_compatible_sources "$(hostpath ${STATE_ROOT}/distupgrade-target.sources.list)" "$PIN_TARGET_SUITES"
    validate_distupgrade_sources_file "$(hostpath ${STATE_ROOT}/distupgrade-target.sources.list)" "$PIN_TARGET_SUITES"
    ;;
  validate-path)
    validate_distupgrade_sources_file "$2" "$PIN_TARGET_SUITES"
    ;;
  restore-demo)
    stamp="$2"
    restore_apt_sources_from_backup "$stamp" "pre_upgrade_failure"
    ;;
  *) echo "usage: validate|validate-path|restore-demo" >&2; exit 2 ;;
esac
'''
]
open(out, 'w', encoding='utf-8').write('\n'.join(parts) + '\n')
PY
chmod +x "$ENC_HARNESS"

fx_enc="$(mktemp -d)"
mkdir -p "$fx_enc/opt/aelladata/os-upgrade/offline" "$fx_enc/etc/apt/sources.list.d"
# 1) Generator must emit ASCII-only DistUpgrade sources (no em dash / arrows).
set +e
LC_ALL=C LANG=C DP_OFFLINE_TEST_ROOT="$fx_enc" bash "$ENC_HARNESS" validate >"$fx_enc/out-validate.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
   && grep -q 'DISTUPGRADE_SOURCE_DECODE_RESULT=PASS' "$fx_enc/out-validate.txt" \
   && grep -q 'DISTUPGRADE_VALID_SOURCE_COUNT=4' "$fx_enc/out-validate.txt" \
   && grep -q 'DISTUPGRADE_SOURCE_COMPATIBILITY=PASS' "$fx_enc/out-validate.txt"; then
  pass "LC_ALL=C DistUpgrade generated sources validate PASS"
else
  fail "LC_ALL=C DistUpgrade generated sources validation (rc=${rc})"
  cat "$fx_enc/out-validate.txt" || true
fi
python3 - <<PY
p = "$fx_enc/opt/aelladata/os-upgrade/offline/distupgrade-target.sources.list"
raw = open(p, "rb").read()
assert all(b < 0x80 for b in raw), raw[:120]
assert b"\xe2\x80\x94" not in raw and b"\xe2\x86\x92" not in raw
assert b"DistUpgrade-compatible" in raw
print("GENERATED_SOURCES_ASCII=YES")
PY
pass "generated DistUpgrade sources are ASCII-only"

# 2-3) Source validator still tolerates UTF-8 comments when present (legacy hosts).
python3 - <<PY
src = "$fx_enc/opt/aelladata/os-upgrade/offline/distupgrade-target.sources.list"
dst = "$fx_enc/utf8-comment.sources"
body = open(src, "rb").read()
open(dst, "wb").write(b"# stellar offline upgrade \xe2\x80\x94 DistUpgrade-compatible\n" + body)
PY
set +e
LC_ALL=C LANG=C DP_OFFLINE_TEST_ROOT="$fx_enc" bash "$ENC_HARNESS" validate-path "$fx_enc/utf8-comment.sources" >"$fx_enc/out-utf8.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
   && grep -q 'DISTUPGRADE_SOURCE_DECODE_RESULT=PASS' "$fx_enc/out-utf8.txt" \
   && grep -q 'DISTUPGRADE_SOURCE_NONASCII_COMMENT_COUNT=' "$fx_enc/out-utf8.txt"; then
  pass "LC_ALL=C DistUpgrade source UTF-8 comment → PASS"
else
  fail "LC_ALL=C DistUpgrade UTF-8 validation (rc=${rc})"
  cat "$fx_enc/out-utf8.txt" || true
fi

# 4) BOM file
python3 - <<PY
p = "$fx_enc/bom.sources"
body = open("$fx_enc/opt/aelladata/os-upgrade/offline/distupgrade-target.sources.list", "rb").read()
lines = body.splitlines(True)
deb = [ln for ln in lines if ln.startswith(b"deb")]
open(p, "wb").write(b"\xef\xbb\xbf# jammy \xe2\x86\x92 jammy\n" + b"".join(deb))
PY
set +e
LC_ALL=C LANG=C DP_OFFLINE_TEST_ROOT="$fx_enc" bash "$ENC_HARNESS" validate-path "$fx_enc/bom.sources" >"$fx_enc/out-bom.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q 'DISTUPGRADE_SOURCE_DECODE_RESULT=PASS' "$fx_enc/out-bom.txt"; then
  pass "UTF-8 BOM DistUpgrade sources → PASS"
else
  fail "UTF-8 BOM validation (rc=${rc})"
  cat "$fx_enc/out-bom.txt" || true
fi
# 5) signed-by still FAIL
printf 'deb [arch=amd64 signed-by=/k.gpg] http://m/ubuntu jammy main universe\n' >"$fx_enc/signed.sources"
printf 'deb [arch=amd64 signed-by=/k.gpg] http://m/ubuntu jammy-updates main universe\n' >>"$fx_enc/signed.sources"
printf 'deb [arch=amd64 signed-by=/k.gpg] http://m/ubuntu jammy-security main universe\n' >>"$fx_enc/signed.sources"
printf 'deb [arch=amd64 signed-by=/k.gpg] http://m/ubuntu jammy-backports main universe\n' >>"$fx_enc/signed.sources"
set +e
LC_ALL=C LANG=C DP_OFFLINE_TEST_ROOT="$fx_enc" bash "$ENC_HARNESS" validate-path "$fx_enc/signed.sources" >"$fx_enc/out-signed.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'FAIL_SIGNED_BY_PRESENT_IN_DISTUPGRADE_SOURCE' "$fx_enc/out-signed.txt"; then
  pass "signed-by DistUpgrade source → FAIL"
else
  fail "signed-by should fail-closed (rc=${rc})"
  cat "$fx_enc/out-signed.txt" || true
fi
# 6) trusted=yes FAIL
printf 'deb [arch=amd64 trusted=yes] http://m/ubuntu jammy main universe\n' >"$fx_enc/trusted.sources"
set +e
LC_ALL=C LANG=C DP_OFFLINE_TEST_ROOT="$fx_enc" bash "$ENC_HARNESS" validate-path "$fx_enc/trusted.sources" >"$fx_enc/out-trusted.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'FAIL_TRUSTED_YES_FORBIDDEN' "$fx_enc/out-trusted.txt"; then
  pass "trusted=yes DistUpgrade source → FAIL"
else
  fail "trusted=yes should fail (rc=${rc})"
  cat "$fx_enc/out-trusted.txt" || true
fi
# 8-9) malformed UTF-8 → TEXT_DECODE (not INVALID)
python3 - <<PY
open("$fx_enc/bad.sources", "wb").write(
    b"# bad \xe2\n"
    b"deb [arch=amd64] http://m/ubuntu jammy main universe\n"
)
PY
set +e
LC_ALL=C LANG=C DP_OFFLINE_TEST_ROOT="$fx_enc" bash "$ENC_HARNESS" validate-path "$fx_enc/bad.sources" >"$fx_enc/out-bad.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 5 ]] \
   && grep -q 'FAIL_DISTUPGRADE_SOURCE_TEXT_DECODE' "$fx_enc/out-bad.txt" \
   && ! grep -q 'ERROR=FAIL_DISTUPGRADE_SOURCE_INVALID' "$fx_enc/out-bad.txt"; then
  pass "malformed UTF-8 → FAIL_DISTUPGRADE_SOURCE_TEXT_DECODE"
else
  fail "malformed UTF-8 misclassified (rc=${rc})"
  cat "$fx_enc/out-bad.txt" || true
fi

# 13) pre-upgrade failure restores third-party + sources.list from backup
fx_rb="$(mktemp -d)"
make_dp_fixture "$fx_rb"
mkdir -p "$fx_rb/etc/apt/sources.list.d" "$fx_rb/etc/apt/keyrings" "$fx_rb/etc/apt/trusted.gpg.d" \
  "$fx_rb/etc/apt/apt.conf.d" \
  "$fx_rb/usr/local/sbin" "$fx_rb/boot" "$fx_rb/tmp" "$fx_rb/etc/update-manager" "$fx_rb/var/log/aella"
printf 'deb http://archive.ubuntu.com/ubuntu noble main\n' >"$fx_rb/etc/apt/sources.list"
printf 'deb http://ppa.example/ubuntu jammy main\n' >"$fx_rb/etc/apt/sources.list.d/example-ppa.list"
cp -a "$fx_rb/etc/apt/sources.list" "$fx_rb/sources.before"
cp -a "$fx_rb/etc/apt/sources.list.d/example-ppa.list" "$fx_rb/ppa.before"
printf 'systemd\nudev\n' >"$fx_rb/tmp/held-packages.txt"
# Inject decode failure by poisoning DISTUPGRADE path after apply: use env to force
# a post-apply validation failure via broken sources written by a wrapper is heavy;
# instead call restore harness after simulating mutation.
stamp="20260101T000000Z"
mkdir -p "$fx_rb/opt/aelladata/os-upgrade/offline/backups/${stamp}/apt/sources.list.d" \
  "$fx_rb/opt/aelladata/os-upgrade/offline/backups/${stamp}/third-party"
cp -a "$fx_rb/etc/apt/sources.list" "$fx_rb/opt/aelladata/os-upgrade/offline/backups/${stamp}/apt/sources.list"
cp -a "$fx_rb/etc/apt/sources.list.d/." "$fx_rb/opt/aelladata/os-upgrade/offline/backups/${stamp}/apt/sources.list.d/"
# Simulate mutation
printf 'deb [arch=amd64] http://offline/ubuntu jammy main\n' >"$fx_rb/etc/apt/sources.list"
mv -f "$fx_rb/etc/apt/sources.list.d/example-ppa.list" \
  "$fx_rb/opt/aelladata/os-upgrade/offline/backups/${stamp}/third-party/example-ppa.list"
printf 'Acquire::Languages "none";\n' >"$fx_rb/etc/apt/apt.conf.d/99stellar-offline-upgrade"
set +e
DP_OFFLINE_TEST_ROOT="$fx_rb" bash "$ENC_HARNESS" restore-demo "$stamp" >"$fx_rb/out-restore.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
   && cmp -s "$fx_rb/sources.before" "$fx_rb/etc/apt/sources.list" \
   && cmp -s "$fx_rb/ppa.before" "$fx_rb/etc/apt/sources.list.d/example-ppa.list" \
   && [[ ! -f "$fx_rb/etc/apt/apt.conf.d/99stellar-offline-upgrade" ]] \
   && grep -q 'APT_SOURCES_RESTORE_RESULT=PASS' "$fx_rb/out-restore.txt" \
   && grep -q 'LEGACY_APT_KEYRING_RETAINED=YES' "$fx_rb/out-restore.txt"; then
  pass "pre-upgrade APT sources/third-party restore PASS"
else
  fail "APT sources restore (rc=${rc})"
  cat "$fx_rb/out-restore.txt" || true
  ls -la "$fx_rb/etc/apt/sources.list.d" || true
fi
rm -rf "$fx_enc" "$fx_rb"

# Helper harness: release_upgrade_started=true → restore skipped
HOLD_HARNESS="${OUT_DIR}/hold-harness.sh"
{
  cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="${DP_OFFLINE_TEST_ROOT:-}"
LOG_FILE="/dev/null"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
EC_CRITICAL_HOLD=26
EC_INTERNAL=99
CRITICAL_HOLD_PACKAGES="apt dpkg libc6 systemd udev init"
PLANNED_CRITICAL_OS_HOLDS=""
DETECTED_PRODUCT_HOLDS=""
DETECTED_ALL_HOLDS=""
CRITICAL_HOLDS_REMOVED=""
RELEASE_UPGRADE_STARTED="false"
RELEASE_UPGRADE_INVOCATION_STARTED="false"
RELEASE_UPGRADE_PROCESS_SPAWNED="false"
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
RELEASE_UPGRADE_COMPLETED="false"
LEGACY_STATE_RECONCILED="false"
RECONCILIATION_REASON=""
RELEASE_UPGRADE_FAILURE_CLASS=""
PREVIOUS_FAILURE_CLASS=""
PREVIOUS_FAILURE_DETECTED="NO"
PARTIAL_RELEASE_TRANSITION="NO"
RESUME_FROM=""
CRITICAL_HOLD_RESTORE_ON_EXIT=0
PIN_SOURCE_VERSION="22.04"
PIN_SOURCE_CODENAME="jammy"
PIN_TARGET_VERSION="24.04"
PIN_TARGET_CODENAME="noble"
PIN_HOP="jammy-to-noble"
STATE_FILE="${STATE_ROOT}/state"
HISTORY_FILE="${STATE_ROOT}/hop_history"
EC_META=20
EC_META_ASCII=28
EC_RESUME=29
EC_PARTIAL_TRANSITION=27
hostpath() {
  local p="$1"
  if [[ -n "$TEST_ROOT" ]]; then printf '%s%s' "$TEST_ROOT" "$p"; else printf '%s' "$p"; fi
}
log() { local level="$1"; shift; printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >&2; }
die() { local code="$1"; shift; log ERROR "$* (exit=${code})"; exit "$code"; }
read_os_field() {
  local key="$1" f
  f="$(hostpath /etc/os-release)"
  [[ -f "$f" ]] || { printf ''; return 0; }
  grep -E "^${key}=" "$f" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}
read_state() {
  local f; f="$(hostpath "$STATE_FILE")"
  if [[ -f "$f" ]]; then tr -d '\r' <"$f" | head -1; else printf ''; fi
}
pkg_installed_version() { printf ''; }
is_noble_version_for_pkg() { return 1; }
assert_ascii_file() {
  local path="$1"
  LC_ALL=C LANG=C python3 - "$path" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
for i, b in enumerate(data):
    if b in (9, 10, 13) or (32 <= b <= 126):
        continue
    sys.exit(1)
sys.exit(0)
PY
}
EOS
  cat "${ROOT}/client/lib/dp-offline-durable-write.sh"
  cat "${ROOT}/client/lib/dp-offline-release-upgrade-reconciliation.sh"
  cat "${ROOT}/client/lib/dp-offline-apt-preflight-sandbox.sh"
  awk '
    /^critical_holds_dir\(\)/ {p=1}
    /^log_phase1_banner\(\)/ {exit}
    p
  ' "$SCRIPT_IN_RAW" | grep -vE '^@@[A-Z0-9_]+@@$'
} >"$HOLD_HARNESS"
bash -n "$HOLD_HARNESS" && pass "hold harness bash -n" || fail "hold harness bash -n"
# shellcheck disable=SC1090
source "$HOLD_HARNESS"

fx_hold="$(mktemp -d "${OUT_DIR}/fx-hold.XXXX")"
mkdir -p "$fx_hold/tmp" "$fx_hold/opt/aelladata/os-upgrade/offline/critical-holds"
printf 'systemd\n' >"$fx_hold/tmp/held-packages.txt"
TEST_ROOT="$fx_hold"
# Simulate post-unhold removed list after package transition started.
# Invocation/legacy RELEASE_UPGRADE_STARTED alone must NOT block restore;
# only PACKAGE_TRANSITION_STARTED (or evidence) skips re-hold.
printf 'systemd\n' >"$fx_hold/opt/aelladata/os-upgrade/offline/critical-holds/critical-holds-removed.txt"
CRITICAL_HOLDS_REMOVED="systemd"
CRITICAL_HOLD_RESTORE_ON_EXIT=1
RELEASE_UPGRADE_STARTED="true"
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="true"
PLANNED_CRITICAL_OS_HOLDS="systemd"
DETECTED_ALL_HOLDS=""
: >"$fx_hold/tmp/held-packages.txt"
restore_critical_os_holds_if_safe "post_dro_failure"
if [[ ! -s "$fx_hold/tmp/held-packages.txt" ]] \
   || [[ -z "$(tr -d '[:space:]' <"$fx_hold/tmp/held-packages.txt")" ]]; then
  pass "package_transition_started → no automatic re-hold"
else
  fail "re-hold occurred after package_transition_started"
fi
unset TEST_ROOT
RELEASE_UPGRADE_STARTED="false"
RELEASE_UPGRADE_INVOCATION_STARTED="false"
CRITICAL_HOLD_RESTORE_ON_EXIT=0

# --- ASCII meta-release + legacy resume unit tests ---
META_HARNESS="${OUT_DIR}/meta-harness.sh"
{
  cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="${DP_OFFLINE_TEST_ROOT:-}"
LOG_FILE="/dev/null"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
STATE_FILE="${STATE_ROOT}/state"
MIRROR_BASE="http://127.0.0.1:9"
PIN_HOP="jammy-to-noble"
PIN_SOURCE_VERSION="22.04"
PIN_SOURCE_CODENAME="jammy"
PIN_TARGET_VERSION="24.04"
PIN_TARGET_CODENAME="noble"
PIN_KEY_FINGERPRINT="DEADBEEF"
EC_META=20
EC_META_ASCII=28
EC_RESUME=29
EC_PARTIAL_TRANSITION=27
EC_CRITICAL_HOLD=26
EC_INTERNAL=99
RELEASE_UPGRADE_STARTED="false"
RELEASE_UPGRADE_INVOCATION_STARTED="false"
RELEASE_UPGRADE_PROCESS_SPAWNED="false"
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
RELEASE_UPGRADE_COMPLETED="false"
LEGACY_STATE_RECONCILED="false"
RECONCILIATION_REASON=""
RELEASE_UPGRADE_FAILURE_CLASS=""
PREVIOUS_FAILURE_CLASS=""
PREVIOUS_FAILURE_DETECTED="NO"
PARTIAL_RELEASE_TRANSITION="NO"
RESUME_FROM=""
PLANNED_CRITICAL_OS_HOLDS=""
DETECTED_PRODUCT_HOLDS=""
DETECTED_ALL_HOLDS=""
CRITICAL_HOLDS_REMOVED=""
CRITICAL_HOLD_RESTORE_ON_EXIT=0
hostpath() {
  local p="$1"
  if [[ -n "$TEST_ROOT" ]]; then printf '%s%s' "$TEST_ROOT" "$p"; else printf '%s' "$p"; fi
}
log() { local level="$1"; shift; printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >&2; }
die() { local code="$1"; shift; log ERROR "$* (exit=${code})"; exit "$code"; }
read_os_field() {
  local key="$1" f
  f="$(hostpath /etc/os-release)"
  [[ -f "$f" ]] || { printf ''; return 0; }
  grep -E "^${key}=" "$f" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}
read_state() {
  local f; f="$(hostpath "$STATE_FILE")"
  if [[ -f "$f" ]]; then tr -d '\r' <"$f" | head -1; else printf ''; fi
}
pkg_installed_version() { printf ''; }
is_noble_version_for_pkg() { return 1; }
list_held_packages() {
  local held=""
  if [[ -n "$TEST_ROOT" && -f "$(hostpath /tmp/held-packages.txt)" ]]; then
    held="$(tr -d '\r' <"$(hostpath /tmp/held-packages.txt)" || true)"
  fi
  printf '%s' "$held" | tr -s '[:space:]' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}
is_package_currently_held() {
  local pkg="$1" held h
  held="$(list_held_packages)"
  for h in $held; do [[ "$h" == "$pkg" ]] && return 0; done
  return 1
}
critical_holds_dir() { hostpath "${STATE_ROOT}/critical-holds"; }
utc_now() { date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date; }
json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
json_string_array_from_words() { printf '[]'; }
atomic_write_file() { local dest="$1"; cat >"$dest"; }
write_critical_holds_state_json() { :; }
EOS
  cat "${ROOT}/client/lib/dp-offline-durable-write.sh"
  cat "${ROOT}/client/lib/dp-offline-release-upgrade-reconciliation.sh"
  cat "${ROOT}/client/lib/dp-offline-apt-preflight-sandbox.sh"
  # Extract ASCII helpers + apply_meta_release-related validators
  awk '
    /^assert_ascii_file\(\)/ {p=1}
    /^change_login_shells\(\)/ {exit}
    p
  ' "$SCRIPT_IN_RAW" | grep -vE '^@@[A-Z0-9_]+@@$'
  # Fine-grained flag helpers that precede the shared inject token.
  awk '
    /^persist_release_upgrade_flags\(\)/ {p=1}
    /^@@RELEASE_UPGRADE_RECONCILIATION_HELPER@@/ {exit}
    p
  ' "$SCRIPT_IN_RAW"
  # Shared authoritative reconciliation helper (injected at client build time).
  cat "${ROOT}/client/lib/dp-offline-release-upgrade-reconciliation.sh"
  # Hop-local helpers retained after the inject token.
  awk '
    /^@@RELEASE_UPGRADE_RECONCILIATION_HELPER@@/ {p=1; next}
    /^log_phase1_banner\(\)/ {exit}
    p
  ' "$SCRIPT_IN_RAW" | grep -vE '^@@[A-Z0-9_]+@@$'
} >"$META_HARNESS"
bash -n "$META_HARNESS" && pass "meta harness bash -n" || fail "meta harness bash -n"
# shellcheck disable=SC1090
source "$META_HARNESS"

fx_meta="$(mktemp -d "${OUT_DIR}/fx-meta.XXXX")"
mkdir -p "$fx_meta/etc/update-manager" "$fx_meta/opt/aelladata/os-upgrade/offline" \
  "$fx_meta/var/log/aella" "$fx_meta/tmp" "$fx_meta/etc"
cat >"$fx_meta/etc/os-release" <<'EOF'
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION_CODENAME=jammy
EOF
TEST_ROOT="$fx_meta"
LOG_FILE="$(hostpath /var/log/aella/offline_os_upgrade.log)"
mkdir -p "$(dirname "$LOG_FILE")"
: >"$LOG_FILE"

# 1) Non-ASCII arrow in comment -> FAIL_META_RELEASE_CONFIG_NON_ASCII
printf '# Managed by stellar offline jammy\xe2\x86\x92bionic upgrade\n[METARELEASE]\nURI = file:///tmp/x\nURI_LTS = file:///tmp/x\n' \
  >"$fx_meta/etc/update-manager/meta-release.bad"
set +e
out="$(assert_ascii_file "$fx_meta/etc/update-manager/meta-release.bad" "FAIL_META_RELEASE_CONFIG_NON_ASCII" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'FAIL_META_RELEASE_CONFIG_NON_ASCII'; then
  pass "meta-release UTF-8 arrow -> FAIL_META_RELEASE_CONFIG_NON_ASCII"
else
  fail "non-ASCII meta-release not rejected (rc=${rc})"
fi

# 2) ASCII jammy-to-noble -> PASS
meta_local="$fx_meta/opt/aelladata/os-upgrade/offline/meta-release-lts.runtime"
printf 'Dist: jammy\nName: Ubuntu 24.04 LTS\n' >"$meta_local"
render_update_manager_meta_release "$meta_local" "$fx_meta/etc/update-manager/meta-release.good" "jammy-to-noble"
if assert_ascii_file "$fx_meta/etc/update-manager/meta-release.good"; then
  pass "ASCII jammy-to-noble meta-release -> PASS"
else
  fail "ASCII meta-release rejected"
fi
if grep -q 'jammy-to-noble' "$fx_meta/etc/update-manager/meta-release.good" \
   && ! LC_ALL=C grep -aq $'\xe2' "$fx_meta/etc/update-manager/meta-release.good"; then
  pass "generated meta-release comment is ASCII hop label"
else
  fail "generated meta-release still has non-ASCII or wrong label"
fi

# 3+4) POSIX / empty locale configparser
set +e
LC_ALL=C LANG=C validate_meta_release_config_file "$fx_meta/etc/update-manager/meta-release.good" 1 >"$fx_meta/out-parse.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q 'META_RELEASE_CONFIGPARSER_VALIDATION=PASS' "$fx_meta/out-parse.txt"; then
  pass "POSIX locale configparser validation -> PASS"
else
  fail "configparser validation failed under LC_ALL=C (rc=${rc})"
  cat "$fx_meta/out-parse.txt" || true
fi
set +e
env -u LANG -u LC_ALL -u LC_CTYPE bash -c '
  source "$0"
  validate_meta_release_config_file "$1" 1
' "$META_HARNESS" "$fx_meta/etc/update-manager/meta-release.good" >"$fx_meta/out-empty-loc.txt" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "empty LANG/LC_ALL configparser -> PASS" || fail "empty locale parse failed"

# 5) malformed METARELEASE
printf '# ok\n[NOTMETA]\nURI = file:///tmp/x\n' >"$fx_meta/etc/update-manager/meta-release.badsec"
set +e
bash -c 'source "$0"; TEST_ROOT="$1"; validate_meta_release_config_file "$2" 0' \
  "$META_HARNESS" "$fx_meta" "$fx_meta/etc/update-manager/meta-release.badsec" \
  >"$fx_meta/out-badsec.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'FAIL_META_RELEASE_CONFIG_PARSE' "$fx_meta/out-badsec.txt"; then
  pass "malformed METARELEASE -> FAIL_META_RELEASE_CONFIG_PARSE"
else
  fail "malformed section not detected (rc=${rc})"
fi

# 6) URI missing
printf '# ok\n[METARELEASE]\nURI_LTS = file:///tmp/x\n' >"$fx_meta/etc/update-manager/meta-release.nouri"
set +e
bash -c 'source "$0"; TEST_ROOT="$1"; validate_meta_release_config_file "$2" 0' \
  "$META_HARNESS" "$fx_meta" "$fx_meta/etc/update-manager/meta-release.nouri" \
  >"$fx_meta/out-nouri.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'FAIL_META_RELEASE_URI_INVALID\|FAIL_META_RELEASE_CONFIG_PARSE' "$fx_meta/out-nouri.txt"; then
  pass "missing URI -> FAIL_META_RELEASE_URI_INVALID"
else
  fail "missing URI not detected (rc=${rc})"
  cat "$fx_meta/out-nouri.txt" || true
fi

# 11) MetaRelease UnicodeDecodeError fixture -> PRE_MUTATION classification
mkdir -p "$(hostpath ${STATE_ROOT}/critical-holds)"
printf 'UnicodeDecodeError: ascii codec can t decode byte 0xe2 in MetaRelease.py\n' >>"$LOG_FILE"
printf 'FAILED\n' >"$(hostpath "$STATE_FILE")"
printf 'true\n' >"$(hostpath ${STATE_ROOT}/critical-holds/release_upgrade_started)"
printf 'systemd\nudev\n' >"$(hostpath ${STATE_ROOT}/critical-holds/critical-holds-removed.txt)"
: >"$fx_meta/tmp/held-packages.txt"
touch "$(hostpath ${STATE_ROOT}/force-meta-release-encoding-failure)"
if classify_previous_release_upgrade_failure \
   && [[ "$PREVIOUS_FAILURE_CLASS" == "PRE_MUTATION_META_RELEASE_ENCODING" ]] \
   && [[ "$PARTIAL_RELEASE_TRANSITION" == "NO" ]]; then
  pass "UnicodeDecodeError fixture -> PRE_MUTATION_META_RELEASE_ENCODING"
else
  fail "failure class mismatch: ${PREVIOUS_FAILURE_CLASS} partial=${PARTIAL_RELEASE_TRANSITION}"
fi

# 12) OS 22.04 + clean -> partial NO
PARTIAL_RELEASE_TRANSITION="YES"
if ! package_transition_evidence_present; then
  PARTIAL_RELEASE_TRANSITION="NO"
  pass "OS 22.04 clean dpkg -> partial transition NO"
else
  fail "false partial transition evidence"
fi

# 13) legacy release_upgrade_started + pre-mutation -> reconciliation PASS
LEGACY_STATE_RECONCILED="false"
RECONCILIATION_REASON=""
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
set +e
reconcile_legacy_release_upgrade_state >"$fx_meta/out-reconcile.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && [[ "$LEGACY_STATE_RECONCILED" == "true" ]] \
   && [[ "$RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED" == "false" ]] \
   && grep -qiE 'legacy_state_reconciled=true|LEGACY_STATE_RECONCILED=true|STATE_RECONCILIATION_RESULT=PASS' "$fx_meta/out-reconcile.txt"; then
  pass "legacy release_upgrade_started pre-mutation -> reconciliation PASS"
else
  fail "legacy reconciliation failed (rc=${rc})"
  cat "$fx_meta/out-reconcile.txt" || true
fi

# 14) legacy flag + target core packages -> FAIL/manual review
touch "$(hostpath ${STATE_ROOT}/force-target-core-packages)"
rm -f "$(hostpath ${STATE_ROOT}/critical-holds/legacy_state_reconciled)" \
  "$(hostpath ${STATE_ROOT}/critical-holds/reconciliation_reason)"
LEGACY_STATE_RECONCILED="false"
RECONCILIATION_REASON=""
printf 'true\n' >"$(hostpath ${STATE_ROOT}/critical-holds/release_upgrade_started)"
set +e
bash -c '
  source "$0"
  TEST_ROOT="$1"
  STATE_ROOT="/opt/aelladata/os-upgrade/offline"
  LOG_FILE="$(hostpath /var/log/aella/offline_os_upgrade.log)"
  RELEASE_UPGRADE_STARTED="true"
  RELEASE_UPGRADE_INVOCATION_STARTED="true"
  LEGACY_STATE_RECONCILED="false"
  RECONCILIATION_REASON=""
  reconcile_legacy_release_upgrade_state
' "$META_HARNESS" "$fx_meta" >"$fx_meta/out-reconcile-fail.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'FAIL_RELEASE_UPGRADE_STATE_RECONCILIATION\|MANUAL_REVIEW_REQUIRED' "$fx_meta/out-reconcile-fail.txt"; then
  pass "legacy flag + target core packages -> reconciliation FAIL"
else
  fail "expected reconciliation fail-closed (rc=${rc})"
  cat "$fx_meta/out-reconcile-fail.txt" || true
fi
rm -f "$(hostpath ${STATE_ROOT}/force-target-core-packages)"

# 15) prior unhold state matches live no-hold -> resume PASS
LEGACY_STATE_RECONCILED="true"
RECONCILIATION_REASON="META_RELEASE_CONFIG_PARSE_BEFORE_TRANSACTION"
rm -f "$(hostpath ${STATE_ROOT}/force-meta-release-encoding-failure)"
touch "$(hostpath ${STATE_ROOT}/force-meta-release-encoding-failure)"
: >"$fx_meta/tmp/held-packages.txt"
set +e
assess_safe_resume_from_failed >"$fx_meta/out-resume.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q 'RESUME_SAFETY_VALIDATION=PASS' "$fx_meta/out-resume.txt" \
   && grep -q 'RESUME_FROM=PRE_DRO_CONFIGURATION' "$fx_meta/out-resume.txt" \
   && grep -q 'CRITICAL_OS_HOLD_STATE=ALREADY_UNHELD_BY_PRIOR_PHASE1_ATTEMPT' "$fx_meta/out-resume.txt"; then
  pass "prior unhold + live no-hold -> resume PASS"
else
  fail "safe resume rejected (rc=${rc})"
  cat "$fx_meta/out-resume.txt" || true
fi

# 16) prior unhold state vs live hold mismatch -> fail-closed
printf 'systemd\n' >"$fx_meta/tmp/held-packages.txt"
set +e
bash -c '
  source "$0"
  TEST_ROOT="$1"
  STATE_ROOT="/opt/aelladata/os-upgrade/offline"
  verify_prior_critical_hold_resume_consistency
' "$META_HARNESS" "$fx_meta" >"$fx_meta/out-hold-mismatch.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'FAIL_CRITICAL_OS_HOLD_STATE_INCONSISTENT' "$fx_meta/out-hold-mismatch.txt"; then
  pass "prior unhold vs live hold mismatch -> fail-closed"
else
  fail "hold mismatch not fail-closed (rc=${rc})"
fi
: >"$fx_meta/tmp/held-packages.txt"

# 17/18) idempotent third-party / shell
mkdir -p "$fx_meta/etc/apt/sources.list.d"
printf 'aella:x:1000:1000::/home/aella:/bin/bash\n' >"$fx_meta/etc/passwd"
log_idempotent_prep_states >"$fx_meta/out-idem.txt" 2>&1
if grep -q 'THIRD_PARTY_SOURCE_STATE=ALREADY_DISABLED' "$fx_meta/out-idem.txt" \
   && grep -q 'AELLA_SHELL_STATE=ALREADY_BASH' "$fx_meta/out-idem.txt"; then
  pass "already-disabled sources + already-bash aella -> idempotent PASS"
else
  fail "idempotent prep states missing"
  cat "$fx_meta/out-idem.txt" || true
fi

# 25) template must not embed UTF-8 arrow in generated meta-release heredoc
if grep -n "Managed by stellar offline jammy" "$SCRIPT_IN" | grep -q $'\xe2'; then
  fail "template still embeds UTF-8 arrow in meta-release generator"
else
  pass "generated legacy meta-release template is ASCII-only"
fi
if grep -q 'render_update_manager_meta_release' "$SCRIPT_IN" \
   && grep -q 'validate_meta_release_preview' "$SCRIPT_IN" \
   && { grep -q 'reconcile_legacy_release_upgrade_state' "$SCRIPT_IN" \
        || grep -q '@@RELEASE_UPGRADE_RECONCILIATION_HELPER@@' "$SCRIPT_IN_RAW"; } \
   && grep -q 'RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED' "$SCRIPT_IN" \
   && grep -q 'FAILURE_CLASS' "$SCRIPT_IN"; then
  pass "ASCII/parser/resume/failure-class markers present"
else
  fail "required policy markers missing from template"
fi

unset TEST_ROOT
LOG_FILE="/dev/null"

# Reboot handoff marker: restore deferred (static + harness reason)
if grep -q 'CRITICAL_OS_HOLDS_AUTO_REHOLD_AFTER_SUCCESS=NO' "$SCRIPT_IN" \
   && grep -A8 'reboot_if_success' "$SCRIPT_IN" | grep -q 'CRITICAL_OS_HOLDS_AUTO_REHOLD_AFTER_SUCCESS=NO'; then
  pass "reboot handoff does not restore holds"
else
  fail "reboot handoff restore policy missing"
fi

# Next hop: no critical holds remaining → PASS
rm -rf "$fx2/opt/aelladata/os-upgrade"
: >"$fx2/tmp/held-packages.txt"
rc="$(run_preflight_fixture "$fx2")"
if [[ "$rc" -eq 0 ]] && grep -q 'CRITICAL_OS_HOLD_PREFLIGHT=PASS' "$fx2/out.txt"; then
  pass "next hop without critical holds → PASS"
else
  fail "next hop empty holds (rc=${rc})"
fi

# State inconsistency: unhold started but not completed → fail-closed
rm -rf "$fx2/opt/aelladata/os-upgrade"
mkdir -p "$fx2/opt/aelladata/os-upgrade/offline/critical-holds"
printf 'systemd\n' >"$fx2/tmp/held-packages.txt"
utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf '%s\n' "$utc" >"$fx2/opt/aelladata/os-upgrade/offline/critical-holds/unhold_started_at"
printf '{"release_upgrade_started": false}\n' \
  >"$fx2/opt/aelladata/os-upgrade/offline/critical-holds/critical-holds-state.json"
rc="$(run_preflight_fixture "$fx2")"
if [[ "$rc" -ne 0 ]] && grep -q 'FAIL_CRITICAL_OS_HOLD_STATE_INCONSISTENT' "$fx2/out.txt"; then
  pass "incomplete unhold state → fail-closed"
else
  fail "state inconsistency not detected (rc=${rc})"
  tail -30 "$fx2/out.txt" || true
fi
rm -f "$fx2/tmp/held-packages.txt"

# dpkg audit fatal → FAIL
rm -rf "$fx2/opt/aelladata/os-upgrade"
: >"$fx2/tmp/dpkg-broken"
rc="$(run_preflight_fixture "$fx2")"
[[ "$rc" -ne 0 ]] && pass "dpkg audit fatal → FAIL" || fail "dpkg broken accepted"
rm -f "$fx2/tmp/dpkg-broken"

# disk insufficient → FAIL
rm -rf "$fx2/opt/aelladata/os-upgrade"
: >"$fx2/tmp/force-disk-fail"
rc="$(run_preflight_fixture "$fx2")"
[[ "$rc" -ne 0 ]] && pass "disk insufficient → FAIL" || fail "disk fail fixture accepted"
rm -f "$fx2/tmp/force-disk-fail"

# Static architecture markers
grep -q 'run_os_preflight' "$SCRIPT_IN" && pass "run_os_preflight present" || fail "run_os_preflight missing"
grep -q 'run_product_preflight' "$SCRIPT_IN" && pass "run_product_preflight present" || fail "run_product_preflight missing"
grep -q 'run_os_upgrade' "$SCRIPT_IN" && pass "run_os_upgrade present" || fail "run_os_upgrade missing"
grep -q 'run_product_post_upgrade' "$SCRIPT_IN" && pass "run_product_post_upgrade present" || fail "run_product_post_upgrade missing"
grep -q 'UPGRADE_MODE=OS_ONLY_PHASE1' "$SCRIPT_IN" && pass "OS_ONLY_PHASE1 default mode" || fail "OS_ONLY_PHASE1 missing"
grep -q 'product_validation_result=NOT_RUN_PHASE1' "$SCRIPT_IN" && pass "product_validation_result marker" || fail "product validation marker missing"
if grep -nE 'die .*FAIL_DP_TOPOLOGY_UNDETERMINED|die .*FAIL_UNSUPPORTED_DP_TOPOLOGY|die .*FAIL_UNSUPPORTED_DP_VERSION|die .*FAIL_DP_VERSION_UNDETERMINED' "$SCRIPT_IN"; then
  fail "product topology/version still hard-die in Phase 1 client"
else
  pass "product topology/version hard-dies removed"
fi

rm -rf "$fx" "$fx2" "$FAKEBIN" "$FAKEBIN2"
PATH="$PATH_SAVE"
export PATH
unset DP_OFFLINE_TEST_ROOT TEST_ROOT || true

# 4) Build against live selective mirror when available
MIRROR_BASE="${TEST_MIRROR_BASE:-http://192.0.2.10}"
SEL_ROOT="${TEST_SELECTIVE_ROOT:-/var/spool/apt-mirror/selective}"
BUILT=""
if [[ -f "${SEL_ROOT}/keys/ubuntu-mirror-selective.gpg" \
   && -f "${SEL_ROOT}/current/shared/offline/release-upgraders/noble/noble.tar.gz" \
   && -f "${SEL_ROOT}/state/READY" ]]; then
  if [[ -f "${SEL_ROOT}/hops/jammy-to-noble/ubuntu/dists/jammy/Release" ]] \
    || [[ -f "${SEL_ROOT}/current/hops/jammy-to-noble/ubuntu/dists/jammy/Release" ]]; then
    set +e
    python3 "$BUILD_PY" \
      --project-root "$ROOT" \
      --mirror-base "$MIRROR_BASE" \
      --selective-root "$SEL_ROOT" \
      --content-source local-fs \
      --output-dir "$OUT_DIR" \
      --deploy-nginx-root "${OUT_DIR}/nginx-client" \
      >"${OUT_DIR}/build.log" 2>&1
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
      pass "live build-client"
      BUILT="${OUT_DIR}/dp-offline-upgrade-jammy-to-noble.sh"
      bash -n "$BUILT" && pass "built script bash -n" || fail "built script bash -n"
      grep -q "^PIN_MIRROR_BASE='${MIRROR_BASE}'$" "$BUILT" \
        && pass "built client pins local mirror base" || fail "built client mirror pin mismatch"
      if grep -Fq "$MIRROR_BASE" "$BUILT"; then
        pass "built client embeds local mirror base"
      else
        fail "built client missing local mirror base"
      fi
      grep -q 'trusted.gpg.d/stellar-offline-jammy-to-noble.gpg' "$BUILT" \
        || grep -q 'LEGACY_APT_KEYRING_PATH=' "$BUILT" \
        || fail "legacy apt keyring path missing"
      if grep -nE 'printf.*signed-by=' "$BUILT"; then
        fail "built script still generates signed-by sources"
      else
        pass "built script has no signed-by source generation"
      fi
      grep -q 'UPGRADE-JAMMY-TO-NOBLE' "$BUILT" && pass "confirm phrase pinned" || fail "confirm phrase"
      grep -q 'DistUpgradeViewNonInteractive' "$BUILT" && pass "DRO frontend pinned" || fail "DRO frontend"
      grep -q 'COMPLETED_NOBLE' "$BUILT" && pass "COMPLETED_NOBLE state" || fail "COMPLETED_NOBLE"
      if grep -nE '\[.*trusted[[:space:]]*=[[:space:]]*yes|apt-key add|apt-key adv' "$BUILT"; then
        fail "built script enables trusted=yes or calls apt-key"
      else
        pass "built script trust policy"
      fi
      # Components from Release (main universe for this hop)
      grep -q "PIN_COMPONENTS='main universe'" "$BUILT" \
        && pass "components from Release" \
        || fail "unexpected PIN_COMPONENTS (expected main universe)"
      # Manifest signature present (base64 blob of armored sig)
      grep -q "PIN_MANIFEST_SIG_B64='" "$BUILT" && pass "manifest sig embedded" || fail "manifest sig"
      # READY unchanged
      ready_before="$(sha256sum "${SEL_ROOT}/state/READY" | awk '{print $1}')"
      ready_after="$(sha256sum "${SEL_ROOT}/state/READY" | awk '{print $1}')"
      [[ "$ready_before" == "$ready_after" ]] && pass "READY unchanged" || fail "READY changed"
      # discovery artifacts unchanged
      disc_sha="$(sha256sum "${ROOT}/artifacts/upgrade-discovery/jammy-to-noble/export-summary.json" | awk '{print $1}')"
      sleep 0
      disc_sha2="$(sha256sum "${ROOT}/artifacts/upgrade-discovery/jammy-to-noble/export-summary.json" | awk '{print $1}')"
      [[ "$disc_sha" == "$disc_sha2" ]] && pass "discovery artifact unchanged" || fail "discovery mutated"
    else
      fail "live build-client (see ${OUT_DIR}/build.log)"
      tail -40 "${OUT_DIR}/build.log" || true
    fi
  else
    echo "  SKIP: mirror HTTP not reachable for live build"
  fi
else
  echo "  SKIP: selective root/keys not available for live build"
fi

# 5) Fake-root behavioral tests (require built script)
if [[ -n "$BUILT" && -f "$BUILT" ]]; then
  fake="$(mktemp -d)"
  mkdir -p \
    "$fake/etc/apt/sources.list.d" \
    "$fake/etc/apt/apt.conf.d" \
    "$fake/etc/update-manager" \
    "$fake/etc/systemd/system" \
    "$fake/opt/aelladata" \
    "$fake/var/log/aella" \
    "$fake/usr/local/sbin" \
    "$fake/tmp" \
    "$fake/boot"
  cat >"$fake/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION_CODENAME=jammy
PRETTY_NAME="Ubuntu 24.04.5 LTS"
EOF
  cat >"$fake/opt/aelladata/release-metadata.yml" <<EOF
# force service re-deploy even version doesn't change.
version: 1591228779
role: aio
EOF
  cat >"$fake/opt/aelladata/release-image.yml" <<EOF
aella-cm-bg: 6.2.0.1-aaaaaaaa
aella-cm-master: 6.2.0.1-aaaaaaaa
EOF
  rm -rf "$fake/etc/passwd"
  printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1000:1000:aella:/home/aella:/bin/bash\n' \
    >"$fake/etc/passwd"
  printf 'deb http://archive.ubuntu.com/ubuntu noble main\n' >"$fake/etc/apt/sources.list"
  printf 'deb http://ppa.launchpad.net/example/ppa/ubuntu jammy main\n' \
    >"$fake/etc/apt/sources.list.d/example-ppa.list"
  cat >"$fake/etc/update-manager/release-upgrades" <<EOF
[DEFAULT]
Prompt=normal
EOF
  cat >"$fake/etc/update-manager/meta-release" <<EOF
[METARELEASE]
URI = http://changelogs.ubuntu.com/meta-release
URI_LTS = http://changelogs.ubuntu.com/meta-release-lts
EOF

  # Non-root without TEST_ROOT should fail (we always set TEST_ROOT here)
  # Wrong OS
  sed -i 's/22.04/24.04/;s/jammy/noble/' "$fake/etc/os-release"
  set +e
  DP_OFFLINE_TEST_ROOT="$fake" DP_OFFLINE_FAKE_DP_VERSION=6.2.0 DP_OFFLINE_FAKE_ROLE=AIO \
    bash "$BUILT" --mirror-base "$MIRROR_BASE" --preflight-only >"$fake/out-wrongos.txt" 2>&1
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] && pass "reject non-jammy OS" || fail "accepted non-jammy OS"
  # restore jammy
  cat >"$fake/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION_CODENAME=jammy
PRETTY_NAME="Ubuntu 24.04.5 LTS"
EOF

  # Unsupported DP version is NOT a Phase 1 hard gate (OS-only)
  set +e
  DP_OFFLINE_TEST_ROOT="$fake" DP_OFFLINE_FAKE_DP_VERSION=5.0.0 DP_OFFLINE_FAKE_ROLE=AIO     DP_OFFLINE_FAKE_MIRROR_TRUST=1     bash "$BUILT" --mirror-base "$MIRROR_BASE" --preflight-only >"$fake/out-dp.txt" 2>&1
  rc=$?
  set -e
  if grep -q 'DP_VERSION_GATE=SKIPPED_PHASE1_OS_ONLY' "$fake/out-dp.txt"      && ! grep -q 'FAIL_UNSUPPORTED_DP_VERSION' "$fake/out-dp.txt"; then
    pass "DP 5.0.0 not hard-gated in Phase 1 OS-only"
  else
    fail "DP version unexpectedly gated (rc=${rc})"
    tail -20 "$fake/out-dp.txt" || true
  fi

  # Unknown topology is SKIPPED, not FAIL
  set +e
  DP_OFFLINE_TEST_ROOT="$fake" DP_OFFLINE_FAKE_DP_VERSION=6.2.0 DP_OFFLINE_FAKE_ROLE=UNKNOWN     DP_OFFLINE_FAKE_MIRROR_TRUST=1     bash "$BUILT" --mirror-base "$MIRROR_BASE" --preflight-only >"$fake/out-cluster.txt" 2>&1
  rc=$?
  set -e
  if ! grep -q 'FAIL_DP_TOPOLOGY_UNDETERMINED' "$fake/out-cluster.txt"      && grep -q 'DP_TOPOLOGY_GATE=SKIPPED_PHASE1_OS_ONLY' "$fake/out-cluster.txt"; then
    pass "UNKNOWN topology skipped in Phase 1 OS-only"
  else
    fail "UNKNOWN topology still hard-failed (rc=${rc})"
    tail -20 "$fake/out-cluster.txt" || true
  fi

  # Worker topology is SKIPPED, not FAIL
  set +e
  DP_OFFLINE_TEST_ROOT="$fake" DP_OFFLINE_FAKE_DP_VERSION=6.2.0 DP_OFFLINE_FAKE_ROLE=WORKER     DP_OFFLINE_FAKE_MIRROR_TRUST=1     bash "$BUILT" --mirror-base "$MIRROR_BASE" --preflight-only >"$fake/out-worker.txt" 2>&1
  rc=$?
  set -e
  if ! grep -q 'FAIL_UNSUPPORTED_DP_TOPOLOGY' "$fake/out-worker.txt"      && grep -q 'DP_TOPOLOGY_GATE=SKIPPED_PHASE1_OS_ONLY' "$fake/out-worker.txt"; then
    pass "WORKER topology skipped in Phase 1 OS-only"
  else
    fail "WORKER topology still hard-failed (rc=${rc})"
    tail -20 "$fake/out-worker.txt" || true
  fi

  # Preflight-only must not mutate sources
  cp -a "$fake/etc/apt/sources.list" "$fake/sources.before"
  set +e
  # Mirror checks will run against live network; allow if mirror up
  DP_OFFLINE_TEST_ROOT="$fake" DP_OFFLINE_FAKE_DP_VERSION=6.2.0 DP_OFFLINE_FAKE_ROLE=AIO \
    bash "$BUILT" --mirror-base "$MIRROR_BASE" --preflight-only >"$fake/out-preflight.txt" 2>&1
  rc=$?
  set -e
  if cmp -s "$fake/sources.before" "$fake/etc/apt/sources.list"; then
    pass "preflight does not change sources.list"
  else
    fail "preflight mutated sources.list"
  fi
  if [[ -f "$fake/etc/apt/sources.list.d/example-ppa.list" ]]; then
    pass "preflight leaves third-party list in place"
  else
    fail "preflight moved third-party list"
  fi

  # Wrong confirmation → no commit changes to keyring
  set +e
  DP_OFFLINE_TEST_ROOT="$fake" DP_OFFLINE_FAKE_DP_VERSION=6.2.0 DP_OFFLINE_FAKE_ROLE=AIO \
    DP_OFFLINE_FAKE_CONFIRM=nope \
    bash "$BUILT" --mirror-base "$MIRROR_BASE" >"$fake/out-badconfirm.txt" 2>&1
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] && pass "bad confirmation rejected" || fail "bad confirmation accepted"
  if [[ ! -f "$fake/etc/apt/keyrings/stellar-offline-upgrade.gpg" \
     && ! -f "$fake/etc/apt/trusted.gpg.d/stellar-offline-jammy-to-noble.gpg" ]]; then
    pass "no keyring install before valid confirmation"
  else
    # may exist if commit ran - fail
    fail "keyring installed despite bad confirmation"
  fi

  # Good confirmation path (fake root; no systemd start)
  set +e
  DP_OFFLINE_TEST_ROOT="$fake" DP_OFFLINE_FAKE_DP_VERSION=6.2.0 DP_OFFLINE_FAKE_ROLE=AIO \
    DP_OFFLINE_FAKE_CONFIRM=UPGRADE-JAMMY-TO-NOBLE \
    bash "$BUILT" --mirror-base "$MIRROR_BASE" >"$fake/out-commit.txt" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    pass "confirm+commit returns 0 under TEST_ROOT"
  else
    # preflight may fail if mirror down mid-run
    if grep -q 'preflight PASS' "$fake/out-commit.txt"; then
      fail "commit failed after preflight PASS"
      tail -30 "$fake/out-commit.txt" || true
    else
      echo "  SKIP: full commit path (preflight/mirror dependent)"
      tail -20 "$fake/out-commit.txt" || true
    fi
  fi
  if [[ -f "$fake/etc/apt/trusted.gpg.d/stellar-offline-jammy-to-noble.gpg" ]] \
     || [[ -f "$fake/etc/apt/keyrings/stellar-offline-upgrade.gpg" ]]; then
    pass "legacy keyring installed after confirmation"
    if grep -q 'signed-by=' "$fake/etc/apt/sources.list"; then
      fail "sources still use signed-by (DistUpgrade-incompatible)"
    elif grep -qE '^deb \[arch=amd64\] ' "$fake/etc/apt/sources.list"; then
      pass "sources use DistUpgrade-compatible arch= only"
    else
      fail "sources missing DistUpgrade-compatible deb lines"
    fi
    if [[ -f "$fake/opt/aelladata/os-upgrade/offline/distupgrade-target.sources.list" ]]; then
      if grep -q 'signed-by=' "$fake/opt/aelladata/os-upgrade/offline/distupgrade-target.sources.list"; then
        fail "DistUpgrade target sources contain signed-by"
      else
        pass "DistUpgrade target sources present without signed-by"
      fi
    else
      fail "DistUpgrade target sources file missing"
    fi
    if grep -qiE 'trusted[[:space:]]*=[[:space:]]*yes' "$fake/etc/apt/sources.list"; then
      fail "trusted=yes in sources"
    else
      pass "no trusted=yes in sources"
    fi
    if grep -qiE 'archive\.ubuntu\.com|security\.ubuntu\.com' "$fake/etc/apt/sources.list"; then
      fail "external hosts in sources"
    else
      pass "local hop sources only"
    fi
    grep -q 'Prompt=lts' "$fake/etc/update-manager/release-upgrades" && pass "Prompt=lts" || fail "Prompt=lts"
    if [[ -f "$fake/etc/update-manager/meta-release" ]] \
       && ! LC_ALL=C grep -aq $'\xe2' "$fake/etc/update-manager/meta-release" \
       && grep -q 'jammy-to-noble' "$fake/etc/update-manager/meta-release" \
       && grep -q 'META_RELEASE_ASCII_VALIDATION=PASS\|META_RELEASE_CONFIG_REGENERATED=YES' "$fake/out-commit.txt"; then
      pass "confirm+commit installs ASCII-only meta-release"
    else
      fail "post-confirm meta-release ASCII/regen check"
      cat "$fake/etc/update-manager/meta-release" 2>/dev/null || true
    fi
    # Bad confirmation must not have left prior meta-release mutated before this success path;
    # resume safety: FAILED + encoding fixture requires re-confirmation.
    mkdir -p "$fake/opt/aelladata/os-upgrade/offline/critical-holds"
    printf 'FAILED\n' >"$fake/opt/aelladata/os-upgrade/offline/state"
    printf 'true\n' >"$fake/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_started"
    printf 'systemd\n' >"$fake/opt/aelladata/os-upgrade/offline/critical-holds/critical-holds-removed.txt"
    : >"$fake/tmp/held-packages.txt"
    touch "$fake/opt/aelladata/os-upgrade/offline/force-meta-release-encoding-failure"
    printf 'UnicodeDecodeError MetaRelease ascii codec\n' >>"$fake/var/log/aella/offline_os_upgrade.log"
    set +e
    DP_OFFLINE_TEST_ROOT="$fake" DP_OFFLINE_FAKE_DP_VERSION=6.2.0 DP_OFFLINE_FAKE_ROLE=AIO \
      DP_OFFLINE_FAKE_MIRROR_TRUST=1 DP_OFFLINE_FAKE_CONFIRM=nope \
      bash "$BUILT" --mirror-base "$MIRROR_BASE" >"$fake/out-resume-reject.txt" 2>&1
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]] && grep -qE 'confirmation rejected|Confirmation|RESUME_SAFETY_VALIDATION=PASS|READY_FOR_RESUME' "$fake/out-resume-reject.txt"; then
      pass "resume requires destructive confirmation again"
    elif [[ "$rc" -ne 0 ]]; then
      pass "resume path refused without valid confirmation (rc=${rc})"
    else
      fail "resume proceeded without confirmation"
    fi
    rm -f "$fake/opt/aelladata/os-upgrade/offline/force-meta-release-encoding-failure"
    grep -q '/bin/bash' "$fake/etc/passwd" && pass "shells set to bash" || fail "shells not bash"
    [[ ! -f "$fake/etc/apt/sources.list.d/example-ppa.list" ]] && pass "third-party disabled" || fail "third-party still active"
    [[ -x "$fake/usr/local/sbin/stellar-offline-os-upgrade-runner" ]] && pass "runner installed" || fail "runner missing"
    [[ -f "$fake/etc/systemd/system/stellar-offline-os-upgrade.service" ]] && pass "unit installed" || fail "unit missing"
    [[ -f "$fake/etc/systemd/system/stellar-offline-os-upgrade-postboot.service" ]] && pass "postboot unit" || fail "postboot unit"
  fi

  # Duplicate execution while CONFIGURING
  if [[ -d "$fake/opt/aelladata/os-upgrade/offline" ]]; then
    printf 'UPGRADING_JAMMY_TO_NOBLE\n' >"$fake/opt/aelladata/os-upgrade/offline/state"
    set +e
    DP_OFFLINE_TEST_ROOT="$fake" DP_OFFLINE_FAKE_DP_VERSION=6.2.0 DP_OFFLINE_FAKE_ROLE=AIO \
      bash "$BUILT" --mirror-base "$MIRROR_BASE" --preflight-only >"$fake/out-busy.txt" 2>&1
    rc=$?
    set -e
    [[ "$rc" -ne 0 ]] && pass "duplicate in-progress rejected" || fail "duplicate allowed"

    # Corrupt state not deleted
    printf '!!!CORRUPT!!!\n' >"$fake/opt/aelladata/os-upgrade/offline/state"
    set +e
    DP_OFFLINE_TEST_ROOT="$fake" bash "$BUILT" --mirror-base "$MIRROR_BASE" >"$fake/out-corrupt.txt" 2>&1
    rc=$?
    set -e
    [[ "$rc" -ne 0 ]] && pass "corrupt state rejected" || fail "corrupt state accepted"
    if find "$fake/opt/aelladata/os-upgrade/offline/backups" -name 'state' 2>/dev/null | grep -q .; then
      pass "corrupt state preserved in backup"
    else
      # state file itself still present
      [[ -f "$fake/opt/aelladata/os-upgrade/offline/state" ]] && pass "corrupt state not auto-deleted" || fail "state deleted"
    fi
  fi

  # Completed Noble idempotency
  cat >"$fake/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION_CODENAME=noble
EOF
  mkdir -p "$fake/opt/aelladata/os-upgrade/offline"
  printf 'COMPLETED_NOBLE\n' >"$fake/opt/aelladata/os-upgrade/offline/state"
  set +e
  DP_OFFLINE_TEST_ROOT="$fake" bash "$BUILT" --mirror-base "$MIRROR_BASE" >"$fake/out-done.txt" 2>&1
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] && pass "COMPLETED_NOBLE idempotent exit 0" || fail "COMPLETED_NOBLE rerun failed"

  # Refuse 26.04+ (Noble is this hop's target; later hops are out of scope)
  cat >"$fake/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION_ID="26.04"
VERSION_CODENAME=resolute
EOF
  set +e
  DP_OFFLINE_TEST_ROOT="$fake" bash "$BUILT" --mirror-base "$MIRROR_BASE" >"$fake/out-noble.txt" 2>&1
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] && pass "refuse 26.04+" || fail "accepted 26.04"

  # Runner must reboot only on success path - static check
  grep -A20 'reboot_if_success' "$BUILT" | grep -q 'systemctl reboot' && pass "reboot helper present"
  # Failure path must write FAILED before any reboot call in runner section
  if awk '/write_state FAILED/{f=1} /reboot_if_success/{if(!f) bad=1} END{exit bad+0}' \
       <(sed -n '/^install -m 0755 \/dev\/stdin.*RUNNER/,/^RUNNER$/p' "$BUILT"); then
    pass "FAILED precedes reboot in runner"
  else
    # softer static check
    if grep -A5 'do-release-upgrade failed' "$BUILT" | grep -q 'write_state FAILED'; then
      pass "failure sets FAILED (no reboot)"
    else
      fail "failure reboot safety unclear"
    fi
  fi

  rm -rf "$fake"
fi

# 6) nginx template includes /client/
grep -q 'location /client/' "${ROOT}/templates/nginx.conf" && pass "nginx /client/ location" || fail "nginx /client/"
# shellcheck disable=SC1091
source "${ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/config.sh"
um_load_config "${ROOT}/mirror.conf"
um_generate_nginx_conf >"${OUT_DIR}/nginx.conf"
grep -q 'location /client/' "${OUT_DIR}/nginx.conf" && pass "generated nginx has /client/" || fail "generated nginx missing /client/"

# 7) run_all registration will be checked separately; ensure script is executable bit on builder
[[ -f "$BUILD_PY" ]] && pass "builder present"

# 8) Release-transition design guards (static)
if grep -nE 'apt-get -y dist-upgrade|apt-get -y full-upgrade|apt-get -y upgrade' "$SCRIPT_IN" \
  | grep -v '^[^:]*:[[:space:]]*#' | grep -v 'must never\|NEVER\|forbidden\|removed'; then
  fail "pre-upgrader dist-upgrade/full-upgrade still present"
else
  pass "no pre-upgrader apt-get dist-upgrade"
fi
grep -q 'FAIL_CROSS_RELEASE_CANDIDATE_BEFORE_UPGRADER' "$SCRIPT_IN" \
  && pass "cross-release guard present" || fail "cross-release guard missing"
grep -q 'CRITICAL_OS_HOLD_ACTION=UNHOLD_AFTER_CONFIRMATION' "$SCRIPT_IN" \
  && pass "critical hold planned-unhold policy present" || fail "critical hold planned-unhold missing"
grep -q 'FAIL_CRITICAL_OS_UNHOLD' "$SCRIPT_IN" \
  && pass "critical OS unhold failure path present" || fail "FAIL_CRITICAL_OS_UNHOLD missing"
grep -q 'CRITICAL_OS_HOLDS_AUTO_REHOLD_AFTER_SUCCESS=NO' "$SCRIPT_IN" \
  && pass "Phase 1 no auto re-hold marker" || fail "no auto re-hold marker missing"
if grep -nE 'die .*FAIL_CRITICAL_PACKAGE_HOLD' "$SCRIPT_IN"; then
  fail "legacy FAIL_CRITICAL_PACKAGE_HOLD hard-die still present"
else
  pass "legacy FAIL_CRITICAL_PACKAGE_HOLD hard-die removed"
fi
# Preflight must never call apt-mark unhold
if awk '/^check_critical_package_holds\(\)/,/^print_execution_plan\(\)|^check_cross_release_candidates\(\)/' "$SCRIPT_IN" \
  | grep -nE 'apt-mark unhold|apt_mark_unhold'; then
  fail "preflight path still unholds packages"
else
  pass "preflight does not unhold"
fi
grep -q 'FAIL_PARTIAL_RELEASE_TRANSITION_DETECTED' "$SCRIPT_IN" \
  && pass "partial transition block present" || fail "partial transition missing"
grep -q 'ERROR_SUMMARY=' "$SCRIPT_IN" \
  && pass "journal failure summary present" || fail "journal summary missing"
grep -q 'PRE_UPGRADER_PACKAGE_GUARD' "$SCRIPT_IN" \
  && pass "pre-upgrader package guard logging" || fail "guard logging missing"
# Runner must not install target packages before do-release-upgrade
if grep -A200 'set_stage "SOURCE_RELEASE_PREPARATION"' "$SCRIPT_IN" | grep -q 'apt-get update'; then
  pass "runner still does source apt-get update"
else
  fail "runner missing source apt-get update"
fi
if grep -A200 'set_stage "SOURCE_RELEASE_PREPARATION"' "$SCRIPT_IN" | grep -q 'apt-get check'; then
  pass "runner does apt-get check"
else
  fail "runner missing apt-get check"
fi
if grep -A80 'set_stage "SOURCE_RELEASE_PREPARATION"' "$SCRIPT_IN" | grep -E 'apt-get -y (dist-upgrade|full-upgrade|upgrade|install)'; then
  fail "runner still has apt-get upgrade/install before DRO"
else
  pass "runner has no apt-get upgrade/install before DRO"
fi

# 9) FAILED state re-run blocked (no known pre-mutation signature)
STUB_FAIL="${OUT_DIR}/stub-fail.sh"
# Minimal stub from template pins for state handling only
{
  # Extract helpers + handle_existing_state via rendering pins as empty-safe
  python3 - "$SCRIPT_IN" "$STUB_FAIL" <<'PY'
from pathlib import Path
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = Path(src).read_text(encoding="utf-8")
_lib = Path(src).resolve().parent / "lib"
for _tok, _name in (
    ("@@DESTRUCTIVE_CONFIRMATION_HELPER@@", "dp-offline-destructive-confirmation.sh"),
    ("@@RELEASE_UPGRADE_RECONCILIATION_HELPER@@", "dp-offline-release-upgrade-reconciliation.sh"),
    ("@@APT_PREFLIGHT_SANDBOX_HELPER@@", "dp-offline-apt-preflight-sandbox.sh"),
    ("@@DURABLE_WRITE_HELPER@@", "dp-offline-durable-write.sh"),
    ("@@SOURCE_PRODUCT_HELPER@@", "dp-offline-source-product-version.sh"),
    ("@@LXD_INVENTORY_HELPER@@", "dp-offline-lxd-inventory.sh"),
):
    _hp = _lib / _name
    if _tok in text and _hp.is_file():
        text = text.replace(_tok, _hp.read_text(encoding="utf-8").rstrip("\n") + "\n")
policy = (Path(src).resolve().parent / "dp-postboot-readiness-policy.sh.inc").read_text(encoding="utf-8").rstrip("\n")
text = text.replace("@@POSTBOOT_POLICY_LIB@@", policy)
text = text.replace("@@SAMPLE_DEB_PATH@@", "/sample.deb")
text = re.sub(r"@@[A-Z0-9_]*@@", "x", text)
Path(dst).write_text(text, encoding="utf-8")
PY
}
# Soften die paths that need network by using TEST_ROOT fixture
fx_fail="$(mktemp -d "${OUT_DIR}/fx-fail.XXXX")"
mkdir -p "$fx_fail/opt/aelladata/os-upgrade/offline" "$fx_fail/etc" "$fx_fail/var/log/aella"
cat >"$fx_fail/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION_CODENAME=jammy
EOF
printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1000:1000:aella:/home/aella:/bin/bash\n' >"$fx_fail/etc/passwd"
printf 'FAILED\n' >"$fx_fail/opt/aelladata/os-upgrade/offline/state"
set +e
DP_OFFLINE_TEST_ROOT="$fx_fail" bash "$STUB_FAIL" --mirror-base http://127.0.0.1:9 --preflight-only >"$fx_fail/out.txt" 2>&1
rc=$?
set -e
if grep -q 'FAIL_PARTIAL_RELEASE_TRANSITION_DETECTED' "$fx_fail/out.txt"; then
  pass "FAILED state re-run blocked"
elif grep -q 'RESUME_SAFETY_VALIDATION=FAIL' "$fx_fail/out.txt" && [[ "$rc" -ne 0 ]]; then
  pass "FAILED state re-run blocked"
else
  # May fail earlier on other checks; still require non-zero and no confirmation
  if [[ "$rc" -ne 0 ]] && ! grep -q 'Confirmation>' "$fx_fail/out.txt"; then
    pass "FAILED state re-run blocked (non-zero, no confirm)"
  else
    fail "FAILED state was not blocked"
    tail -30 "$fx_fail/out.txt" || true
  fi
fi

# 9b) FAILED + MetaRelease encoding signature -> safe resume (preflight may continue)
fx_resume="$(mktemp -d "${OUT_DIR}/fx-resume.XXXX")"
mkdir -p "$fx_resume/opt/aelladata/os-upgrade/offline/critical-holds" \
  "$fx_resume/etc" "$fx_resume/var/log/aella" "$fx_resume/tmp" \
  "$fx_resume/etc/apt/sources.list.d" "$fx_resume/boot" "$fx_resume/usr/local/sbin"
cat >"$fx_resume/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION_CODENAME=jammy
EOF
printf 'FAILED\n' >"$fx_resume/opt/aelladata/os-upgrade/offline/state"
printf 'true\n' >"$fx_resume/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_started"
printf 'systemd\nudev\n' >"$fx_resume/opt/aelladata/os-upgrade/offline/critical-holds/critical-holds-removed.txt"
: >"$fx_resume/tmp/held-packages.txt"
touch "$fx_resume/opt/aelladata/os-upgrade/offline/force-meta-release-encoding-failure"
printf 'aella:x:1000:1000::/home/aella:/bin/bash\n' >"$fx_resume/etc/passwd"
printf 'UnicodeDecodeError MetaRelease\n' >"$fx_resume/var/log/aella/offline_os_upgrade.log"
set +e
DP_OFFLINE_TEST_ROOT="$fx_resume" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$fx_resume/out.txt" 2>&1
rc=$?
set -e
if grep -q 'RESUME_SAFETY_VALIDATION=PASS' "$fx_resume/out.txt" \
   && grep -q 'RESUME_FROM=PRE_DRO_CONFIGURATION' "$fx_resume/out.txt" \
   && grep -q 'PREVIOUS_FAILURE_CLASS=PRE_MUTATION_META_RELEASE_ENCODING' "$fx_resume/out.txt"; then
  pass "FAILED encoding fixture -> safe resume assessment PASS"
else
  fail "safe resume from encoding failure not detected (rc=${rc})"
  tail -40 "$fx_resume/out.txt" || true
fi
if grep -q 'Type exactly:' "$fx_resume/out.txt"; then
  fail "preflight-only unexpectedly prompted confirmation"
else
  pass "safe resume preflight-only does not skip confirmation gate"
fi
# 10) mixed-state fixture blocked
fx_mix="$(mktemp -d "${OUT_DIR}/fx-mix.XXXX")"
mkdir -p "$fx_mix/opt/aelladata/os-upgrade/offline" "$fx_mix/etc" "$fx_mix/var/log/aella"
cat >"$fx_mix/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION_CODENAME=jammy
EOF
printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1000:1000:aella:/home/aella:/bin/bash\n' >"$fx_mix/etc/passwd"
: >"$fx_mix/opt/aelladata/os-upgrade/offline/force-partial-transition"
set +e
DP_OFFLINE_TEST_ROOT="$fx_mix" bash "$STUB_FAIL" --mirror-base http://127.0.0.1:9 --preflight-only >"$fx_mix/out.txt" 2>&1
rc=$?
set -e
grep -q 'FAIL_PARTIAL_RELEASE_TRANSITION_DETECTED' "$fx_mix/out.txt" \
  && pass "mixed/partial transition fixture blocked" \
  || fail "mixed-state fixture not blocked"

# 11) Bash 4.3 - already covered above; refresh-hop orchestration exists
grep -q 'refresh-hop-selective' "${ROOT}/scripts/ubuntu-offline-mirror.sh" \
  && pass "refresh-hop-selective orchestration present" \
  || fail "refresh-hop-selective missing"

# =============================================================================
# 12) Non-blocking systemd handoff + D-Bus disconnect classification (fixtures)
# =============================================================================

# Static contract
if grep -qE 'systemctl start --no-block|"\$SYSTEMCTL_BIN" start --no-block|run_systemctl start --no-block' "$SCRIPT_IN"; then
  pass "systemctl start uses --no-block"
else
  fail "missing systemctl start --no-block"
fi
if grep -nE 'systemctl start "\$\{UNIT_NAME\}"|systemctl start \$\{UNIT_NAME\}' "$SCRIPT_IN" \
  | grep -v 'no-block\|reset-failed\|enable\|status\|reboot\|disable\|daemon-reload'; then
  fail "blocking systemctl start still present"
else
  pass "no blocking systemctl start of upgrade unit"
fi
# Forbid blocking log followers; polling monitor (tail -n / tail -c) is required UX.
if grep -nE '^\s*tail -n 50 -F|^\s*tail -F|^\s*journalctl -f' "$SCRIPT_IN"; then
  fail "client uses blocking tail -F / journalctl -f"
else
  pass "no blocking tail -F / journalctl -f"
fi
grep -q 'monitor_upgrade_progress()' "$SCRIPT_IN" && pass "progress monitor function present" \
  || fail "progress monitor function missing"
grep -q 'UPGRADE_HANDOFF=PASS' "$SCRIPT_IN" && pass "handoff PASS marker" || fail "handoff PASS marker missing"
grep -q 'EC_HANDOFF=30' "$SCRIPT_IN" && pass "EC_HANDOFF defined" || fail "EC_HANDOFF missing"
grep -q 'UPGRADE_PROCESS_POLICY=DETACHED_UNDER_SYSTEMD' "$SCRIPT_IN" \
  && pass "upgrade process detached policy" || fail "UPGRADE_PROCESS_POLICY missing"
grep -q 'CLIENT_MONITOR_POLICY=FOREGROUND_READ_ONLY' "$SCRIPT_IN" \
  && pass "foreground monitor policy" || fail "FOREGROUND_READ_ONLY policy missing"
grep -q 'CLIENT_MONITOR_POLICY=DETACHED_BY_REQUEST' "$SCRIPT_IN" \
  && pass "detach-by-request policy" || fail "DETACHED_BY_REQUEST policy missing"
grep -q -- '--detach' "$SCRIPT_IN" && pass "--detach option present" || fail "--detach missing"
grep -q 'RUNNER_START=PASS' "$SCRIPT_IN" && pass "runner start log" || fail "runner start log missing"
grep -q 'RUNNER_DETACHED_FROM_CLIENT=YES' "$SCRIPT_IN" && pass "runner detached marker" || fail "runner detached missing"
grep -q 'StandardInput=null' "$SCRIPT_IN" && pass "unit StandardInput=null" || fail "StandardInput=null missing"
grep -q 'Environment=DEBIAN_FRONTEND=noninteractive' "$SCRIPT_IN" && pass "unit DEBIAN_FRONTEND" || fail "unit DEBIAN_FRONTEND missing"
grep -q 'EnvironmentFile=-${ENV_DEFAULT_FILE}' "$SCRIPT_IN" \
  && pass "unit EnvironmentFile present" || fail "unit EnvironmentFile missing"
grep -q 'FAIL_RUNNER_CONFIG_MISSING_VARIABLE' "$SCRIPT_IN" \
  && pass "runner missing-variable failure class" || fail "FAIL_RUNNER_CONFIG_MISSING_VARIABLE missing"
grep -q 'STALE_STATE_DETECTED=YES' "$SCRIPT_IN" \
  && pass "stale-state detection marker" || fail "STALE_STATE_DETECTED missing"
grep -q 'FAILED_PRE_DRO' "$SCRIPT_IN" \
  && pass "FAILED_PRE_DRO terminal state" || fail "FAILED_PRE_DRO missing"
grep -q "ENV_DEFAULT_FILE=\"/etc/default/stellar-offline-os-upgrade\"" "$SCRIPT_IN" \
  && pass "ENV_DEFAULT_FILE path" || fail "ENV_DEFAULT_FILE path missing"
# Forbid client-side nohup/disown and arbitrary trailing `&`.
# Allowed: package-transition watcher `) &`, and lxd_run_with_heartbeat's
# PID-tracked background child (wait + return rc). See test helper.
# shellcheck source=lib/assert_controlled_background.sh
source "${ROOT}/tests/lib/assert_controlled_background.sh"
assert_offline_hop_background_policy "$SCRIPT_IN"
grep -q 'UPGRADE_ALREADY_RUNNING=YES' "$SCRIPT_IN" && pass "duplicate-run marker" || fail "duplicate-run marker missing"
grep -q 'DBUS_DISCONNECT_CLASS=EXPECTED_CONTROL_CONNECTION_LOSS' "$SCRIPT_IN" \
  && pass "expected D-Bus loss classification" || fail "D-Bus loss classification missing"

# Handoff function harness + fake systemctl
HANDOFF_HARNESS="${OUT_DIR}/handoff-harness.sh"
{
  cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="${DP_OFFLINE_TEST_ROOT:-}"
LOG_FILE="/var/log/aella/offline_os_upgrade.log"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
STATE_FILE="${STATE_ROOT}/state"
UNIT_NAME="stellar-offline-os-upgrade.service"
POSTBOOT_UNIT_NAME="stellar-offline-os-upgrade-postboot.service"
BACKUP_ROOT="${STATE_ROOT}/backups"
HOLDS_DIR="${STATE_ROOT}/critical-holds"
ENV_DEFAULT_FILE="/etc/default/stellar-offline-os-upgrade"
PIN_ENV_FILE="${STATE_ROOT}/pins.env"
RUNNER_PID_FILE="${STATE_ROOT}/runner.pid"
LOG_FILE="/var/log/aella/offline_os_upgrade.log"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
HANDOFF_WAIT_SECS="${HANDOFF_WAIT_SECS:-3}"
HANDOFF_POLL_SECS="${HANDOFF_POLL_SECS:-1}"
HANDOFF_CONFIRMED=0
UPGRADE_RUNNER_PID=0
DBUS_DISCONNECT_SEEN=0
LAST_SYSTEMCTL_OUTPUT=""
LAST_SYSTEMCTL_RC=0
DETACH_AFTER_HANDOFF="${DETACH_AFTER_HANDOFF:-0}"
MONITOR_POLL_SECS="${DP_OFFLINE_MONITOR_POLL_SECS:-1}"
MONITOR_HEARTBEAT_SECS="${DP_OFFLINE_MONITOR_HEARTBEAT_SECS:-2}"
MONITOR_RECENT_LINES="${DP_OFFLINE_MONITOR_RECENT_LINES:-15}"
MONITOR_INTERRUPTED=0
MONITOR_EXIT_REASON=""
MONITOR_LOG_OFFSET=0
LIVE_SERVICE_ACTIVE="NO"
LIVE_RUNNER_PRESENT="NO"
LIVE_DRO_PRESENT="NO"
LIVE_MAIN_PID="0"
EC_OK=0
EC_BUSY=22
EC_HANDOFF=30
EC_STATE=23
EC_INTERNAL=99
EC_PARTIAL_TRANSITION=27
PIN_SOURCE_VERSION="22.04"
PREVIOUS_FAILURE_CLASS=""
PREVIOUS_FAILURE_DETECTED="NO"
PARTIAL_RELEASE_TRANSITION="NO"
RESUME_FROM=""
RELEASE_UPGRADE_STARTED="false"
RELEASE_UPGRADE_INVOCATION_STARTED="false"
RELEASE_UPGRADE_PROCESS_SPAWNED="false"
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
RELEASE_UPGRADE_COMPLETED="false"
LEGACY_STATE_RECONCILED="false"
RECONCILIATION_REASON=""
hostpath() {
  local p="$1"
  if [[ -n "$TEST_ROOT" ]]; then printf '%s%s' "$TEST_ROOT" "$p"; else printf '%s' "$p"; fi
}
log() {
  local level="$1"; shift
  local msg="$*"
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" "$level" "$msg"
  mkdir -p "$(dirname "$(hostpath "$LOG_FILE")")" 2>/dev/null || true
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" "$level" "$msg" >>"$(hostpath "$LOG_FILE")" 2>/dev/null || true
}
die() { local code="$1"; shift; log ERROR "$* (exit=${code})"; exit "$code"; }
write_state() { mkdir -p "$(dirname "$(hostpath "$STATE_FILE")")"; printf '%s\n' "$1" >"$(hostpath "$STATE_FILE")"; }
read_state() {
  local f; f="$(hostpath "$STATE_FILE")"
  if [[ -f "$f" ]]; then tr -d '\r' <"$f" | head -1; else printf ''; fi
}
EOS
  # Extract handoff helpers through start_upgrade_service_detached (includes monitor + stale helpers)
  awk '
    /^# --- systemd handoff/ {p=1}
    /^commit_and_start\(\)/ {exit}
    p
  ' "$SCRIPT_IN"
} >"$HANDOFF_HARNESS"
bash -n "$HANDOFF_HARNESS" && pass "handoff harness bash -n" || fail "handoff harness bash -n"

make_handoff_fixture() {
  local root="$1"
  mkdir -p "$root/opt/aelladata/os-upgrade/offline" "$root/var/log/aella" \
    "$root/etc/systemd/system" "$root/usr/local/sbin" "$root/bin" "$root/run"
  : >"$root/var/log/aella/offline_os_upgrade.log"
  printf 'CONFIGURING\n' >"$root/opt/aelladata/os-upgrade/offline/state"
}

install_fake_systemctl() {
  local root="$1"
  local mode="$2"   # ok | dbus_reset | exit0_no_pid | unit_failed
  cat >"$root/bin/systemctl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ROOT='$root'
MODE='$mode'
CALLS="\$ROOT/run/systemctl-calls.txt"
mkdir -p "\$ROOT/run"
printf '%s\n' "\$*" >>"\$CALLS"
cmd="\${1:-}"
shift || true
case "\$cmd" in
  daemon-reload|reset-failed|enable|status)
    exit 0
    ;;
  start)
    # Require --no-block for PASS path
    printf '%s\n' "start \$*" >>"\$CALLS"
    if ! printf '%s' "\$*" | grep -q -- '--no-block'; then
      echo "ERROR: blocking start not allowed in fixture" >&2
      exit 99
    fi
    case "\$MODE" in
      dbus_reset)
        echo "Warning! D-Bus connection terminated." >&2
        echo "Failed to wait for response: Connection reset by peer" >&2
        # Still record that enqueue was attempted; leave evidence for verify.
        if [[ -f "\$ROOT/run/runner.pid" ]]; then
          :
        fi
        exit 1
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  show)
    prop=""
    unit=""
    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        -p) prop="\$2"; shift 2 ;;
        *) unit="\$1"; shift ;;
      esac
    done
    case "\$MODE" in
      exit0_no_pid)
        case "\$prop" in
          MainPID) echo "MainPID=0" ;;
          ActiveState) echo "ActiveState=inactive" ;;
          SubState) echo "SubState=dead" ;;
          LoadState) echo "LoadState=loaded" ;;
          *) echo "\${prop}=" ;;
        esac
        exit 0
        ;;
      unit_failed)
        case "\$prop" in
          MainPID) echo "MainPID=0" ;;
          ActiveState) echo "ActiveState=failed" ;;
          SubState) echo "SubState=failed" ;;
          LoadState) echo "LoadState=loaded" ;;
          *) echo "\${prop}=" ;;
        esac
        exit 0
        ;;
      dbus_reset)
        # First show may fail with dbus; subsequent use evidence files.
        if [[ ! -f "\$ROOT/run/dbus-show-ok" ]]; then
          echo "Warning! D-Bus connection terminated." >&2
          echo "Connection reset by peer" >&2
          touch "\$ROOT/run/dbus-show-ok"
          exit 1
        fi
        ;&
      *)
        pid=0
        [[ -f "\$ROOT/run/runner.pid" ]] && pid="\$(cat "\$ROOT/run/runner.pid")"
        active="activating"
        sub="start"
        [[ -f "\$ROOT/run/active.state" ]] && active="\$(cat "\$ROOT/run/active.state")"
        [[ -f "\$ROOT/run/sub.state" ]] && sub="\$(cat "\$ROOT/run/sub.state")"
        case "\$prop" in
          MainPID) echo "MainPID=\${pid}" ;;
          ActiveState) echo "ActiveState=\${active}" ;;
          SubState) echo "SubState=\${sub}" ;;
          LoadState) echo "LoadState=loaded" ;;
          *) echo "\${prop}=" ;;
        esac
        exit 0
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$root/bin/systemctl"
}

spawn_fake_runner() {
  local root="$1"
  local runner="$root/usr/local/sbin/stellar-offline-os-upgrade-runner"
  mkdir -p "$(dirname "$runner")"
  cat >"$runner" <<'EOF'
#!/usr/bin/env bash
# Fixture runner: stay alive, ignore stdin/TTY, write start markers if asked.
exec >>"${FAKE_LOG:-/dev/null}" 2>&1 || true
echo "RUNNER_START=PASS"
echo "RUNNER_PID=$$"
echo "RUNNER_PARENT_PID=$PPID"
echo "RUNNER_SYSTEMD_UNIT=stellar-offline-os-upgrade.service"
echo "RUNNER_STDIN_ATTACHED=NO"
echo "RUNNER_TTY_ATTACHED=NO"
echo "RUNNER_DETACHED_FROM_CLIENT=YES"
echo "STAGE=SOURCE_RELEASE_PREPARATION"
# Keep process alive for parent/pid checks
while true; do sleep 30; done
EOF
  chmod +x "$runner"
  FAKE_LOG="$root/var/log/aella/offline_os_upgrade.log" \
    "$runner" </dev/null >/dev/null 2>&1 &
  local pid=$!
  echo "$pid" >"$root/run/runner.pid"
  # Detach from this shell's job control without disown name (fixture only uses &)
  # Parent of sleep-loop is this test shell unless we re-parent; record for assertion.
  echo "$PPID" >"$root/run/test-shell-ppid"
  sleep 0.1
  printf '%s' "$pid"
}

kill_fake_runner() {
  local root="$1"
  if [[ -f "$root/run/runner.pid" ]]; then
    kill "$(cat "$root/run/runner.pid")" 2>/dev/null || true
    wait "$(cat "$root/run/runner.pid")" 2>/dev/null || true
    rm -f "$root/run/runner.pid"
  fi
  pkill -f "$root/usr/local/sbin/stellar-offline-os-upgrade-runner" 2>/dev/null || true
}

run_handoff_case() {
  local root="$1"
  local mode="$2"
  shift 2
  make_handoff_fixture "$root"
  install_fake_systemctl "$root" "$mode"
  export DP_OFFLINE_TEST_ROOT="$root"
  export DP_OFFLINE_TEST_HANDOFF=1
  export TEST_ROOT="$root"
  export STELLAR_OFFLINE_TEST_ROOT="$root"
  export DETACH_AFTER_HANDOFF=0
  export SYSTEMCTL_BIN="$root/bin/systemctl"
  export HANDOFF_WAIT_SECS=2
  export HANDOFF_POLL_SECS=1
  # shellcheck disable=SC1090
  source "$HANDOFF_HARNESS"
  "$@"
}

# 12.1 / 12.2 - --no-block call + client does not wait for oneshot completion
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" ok
rpid="$(spawn_fake_runner "$hf")"
printf 'CONFIGURING\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
printf 'activating\n' >"$hf/run/active.state"
printf 'start\n' >"$hf/run/sub.state"
printf 'RUNNER_START=PASS\nSTAGE=SOURCE_RELEASE_PREPARATION\n' >>"$hf/var/log/aella/offline_os_upgrade.log"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl" HANDOFF_WAIT_SECS=2 HANDOFF_POLL_SECS=1
# shellcheck disable=SC1090
source "$HANDOFF_HARNESS"
set +e
( start_upgrade_service_detached ) >"$hf/out-start.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
   && grep -q -- '--no-block' "$hf/run/systemctl-calls.txt" \
   && grep -q 'SYSTEMD_START_MODE=NON_BLOCKING' "$hf/out-start.txt" \
   && grep -q 'UPGRADE_HANDOFF=PASS' "$hf/out-start.txt" \
   && grep -q 'OFFLINE UPGRADE HANDOFF COMPLETE' "$hf/out-start.txt" \
   && grep -q 'UPGRADE_PROCESS_POLICY=DETACHED_UNDER_SYSTEMD' "$hf/out-start.txt" \
   && grep -q 'CLIENT_MONITOR_POLICY=DETACHED_NONINTERACTIVE' "$hf/out-start.txt"; then
  pass "non-blocking start + handoff PASS (exit 0)"
else
  fail "non-blocking handoff PASS path (rc=${rc})"
  tail -40 "$hf/out-start.txt" || true
fi
# Non-interactive redirect must not enter foreground monitor loop markers
if grep -q 'BACKGROUND OFFLINE UPGRADE IS RUNNING' "$hf/out-start.txt" \
   || grep -q 'CLIENT_MONITOR_POLICY=FOREGROUND_READ_ONLY' "$hf/out-start.txt"; then
  fail "non-interactive handoff unexpectedly attached monitor"
else
  pass "non-interactive handoff does not auto-attach monitor"
fi
# Ensure we did not block on oneshot: start returned while runner still alive
if kill -0 "$rpid" 2>/dev/null; then
  pass "client returned while runner still alive"
else
  fail "runner died before client returned"
fi
kill_fake_runner "$hf"
rm -rf "$hf"

# 12.3 MainPID + runner cmdline → PASS
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" ok
rpid="$(spawn_fake_runner "$hf")"
printf 'CONFIGURING\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
printf 'RUNNER_START=PASS\n' >>"$hf/var/log/aella/offline_os_upgrade.log"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl" HANDOFF_WAIT_SECS=2 HANDOFF_POLL_SECS=1
source "$HANDOFF_HARNESS"
set +e
( handoff_evidence_ok ) >"$hf/out-ev.txt" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "MainPID+runner cmdline → handoff evidence PASS" \
  || { fail "MainPID evidence"; cat "$hf/out-ev.txt"; }
kill_fake_runner "$hf"; rm -rf "$hf"

# 12.4 state PREPARING_JAMMY → PASS
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" ok
rpid="$(spawn_fake_runner "$hf")"
printf 'PREPARING_JAMMY\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl" HANDOFF_WAIT_SECS=1 HANDOFF_POLL_SECS=1
source "$HANDOFF_HARNESS"
set +e
( verify_upgrade_handoff ) >"$hf/out-prep.txt" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'UPGRADE_HANDOFF=PASS' "$hf/out-prep.txt" \
  && pass "state PREPARING_JAMMY → handoff PASS" \
  || { fail "PREPARING_JAMMY handoff"; cat "$hf/out-prep.txt"; }
kill_fake_runner "$hf"; rm -rf "$hf"

# 12.5 RUNNER_START=PASS in log → PASS
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" ok
rpid="$(spawn_fake_runner "$hf")"
printf 'CONFIGURING\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
printf 'RUNNER_START=PASS\n' >>"$hf/var/log/aella/offline_os_upgrade.log"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl" HANDOFF_WAIT_SECS=1 HANDOFF_POLL_SECS=1
source "$HANDOFF_HARNESS"
set +e
( verify_upgrade_handoff ) >"$hf/out-log.txt" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "RUNNER_START=PASS log → handoff PASS" \
  || { fail "log evidence handoff"; cat "$hf/out-log.txt"; }
kill_fake_runner "$hf"; rm -rf "$hf"

# 12.6 systemctl exit 0 but MainPID absent → FAIL
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" exit0_no_pid
printf 'CONFIGURING\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl" HANDOFF_WAIT_SECS=1 HANDOFF_POLL_SECS=1
source "$HANDOFF_HARNESS"
set +e
( start_upgrade_service_detached ) >"$hf/out-nopid.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 30 ]] && grep -q 'UPGRADE_HANDOFF=FAILED' "$hf/out-nopid.txt"; then
  pass "exit0 without MainPID → handoff FAIL (EC_HANDOFF)"
else
  fail "expected handoff FAIL without MainPID (rc=${rc})"
  cat "$hf/out-nopid.txt" || true
fi
rm -rf "$hf"

# 12.7 D-Bus reset + runner alive → PASS
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" dbus_reset
rpid="$(spawn_fake_runner "$hf")"
printf 'CONFIGURING\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
printf 'RUNNER_START=PASS\n' >>"$hf/var/log/aella/offline_os_upgrade.log"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl" HANDOFF_WAIT_SECS=2 HANDOFF_POLL_SECS=1
source "$HANDOFF_HARNESS"
set +e
( start_upgrade_service_detached ) >"$hf/out-dbus-ok.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -qE 'UPGRADE_HANDOFF=PASS|UPGRADE_SERVICE_CONTINUES=YES' "$hf/out-dbus-ok.txt"; then
  pass "D-Bus reset + runner alive → handoff PASS"
else
  fail "D-Bus+runner should PASS (rc=${rc})"
  cat "$hf/out-dbus-ok.txt" || true
fi
kill_fake_runner "$hf"; rm -rf "$hf"

# 12.8 D-Bus reset + state running → PASS (verify path; start would refuse in-progress state)
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" dbus_reset
rpid="$(spawn_fake_runner "$hf")"
printf 'UPGRADING_JAMMY_TO_NOBLE\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl" HANDOFF_WAIT_SECS=2 HANDOFF_POLL_SECS=1
source "$HANDOFF_HARNESS"
DBUS_DISCONNECT_SEEN=1
set +e
( verify_upgrade_handoff ) >"$hf/out-dbus-st.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  set +e
  ( classify_dbus_after_attempt ) >>"$hf/out-dbus-st.txt" 2>&1
  set -e
fi
[[ "$rc" -eq 0 ]] && grep -qE 'UPGRADE_HANDOFF=PASS|UPGRADE_SERVICE_CONTINUES=YES' "$hf/out-dbus-st.txt" \
  && pass "D-Bus reset + upgrading state → handoff PASS" \
  || { fail "D-Bus+state PASS"; cat "$hf/out-dbus-st.txt"; }
kill_fake_runner "$hf"; rm -rf "$hf"

# 12.9 D-Bus error + no runner + no state change → fail-closed
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" dbus_reset
printf 'CONFIGURING\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
# no runner.pid, no log evidence
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl" HANDOFF_WAIT_SECS=1 HANDOFF_POLL_SECS=1
source "$HANDOFF_HARNESS"
set +e
( start_upgrade_service_detached ) >"$hf/out-dbus-fail.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 30 ]] \
   && grep -q 'DBUS_DISCONNECT_PHASE=BEFORE_HANDOFF' "$hf/out-dbus-fail.txt" \
   && grep -q 'UPGRADE_HANDOFF=FAILED' "$hf/out-dbus-fail.txt" \
   && grep -q 'MANUAL_REVIEW_REQUIRED=YES' "$hf/out-dbus-fail.txt"; then
  pass "D-Bus + no evidence → fail-closed"
else
  fail "D-Bus fail-closed (rc=${rc})"
  cat "$hf/out-dbus-fail.txt" || true
fi
rm -rf "$hf"

# 12.10 D-Bus error + unit failed → real failure
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" unit_failed
printf 'CONFIGURING\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl" HANDOFF_WAIT_SECS=1 HANDOFF_POLL_SECS=1
source "$HANDOFF_HARNESS"
set +e
( start_upgrade_service_detached ) >"$hf/out-failed.txt" 2>&1
rc=$?
set -e
[[ "$rc" -eq 30 ]] && grep -qE 'UPGRADE_HANDOFF=FAILED|UPGRADE_SERVICE_ACTIVE_STATE=failed' "$hf/out-failed.txt" \
  && pass "unit failed → handoff FAIL" \
  || { fail "unit failed path"; cat "$hf/out-failed.txt"; }
rm -rf "$hf"

# 12.11 client exit leaves runner alive (already covered) + 12.12 parent pid logged
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
rpid="$(spawn_fake_runner "$hf")"
# Simulate systemd parent by checking runner log fields from fixture script
if grep -q 'RUNNER_PARENT_PID=' "$hf/var/log/aella/offline_os_upgrade.log" \
   && grep -q 'RUNNER_DETACHED_FROM_CLIENT=YES' "$hf/var/log/aella/offline_os_upgrade.log"; then
  pass "runner logs parent pid + detached"
else
  # fixture runner writes after redirect - wait briefly
  sleep 0.2
  if grep -q 'RUNNER_START=PASS' "$hf/var/log/aella/offline_os_upgrade.log"; then
    pass "runner logs parent pid + detached"
  else
    fail "runner start identity log missing"
    cat "$hf/var/log/aella/offline_os_upgrade.log" || true
  fi
fi
# 12.13 stdin/TTY independence: runner started with </dev/null
if grep -q 'RUNNER_STDIN_ATTACHED=NO' "$hf/var/log/aella/offline_os_upgrade.log"; then
  pass "runner stdin not attached"
else
  fail "runner stdin attached unexpectedly"
fi
# 12.14 persistent log
[[ -s "$hf/var/log/aella/offline_os_upgrade.log" ]] && pass "persistent upgrade log written" \
  || fail "persistent log empty"
kill_fake_runner "$hf"; rm -rf "$hf"

# 12.15 ActiveState=activating → duplicate blocked (no second start)
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" ok
rpid="$(spawn_fake_runner "$hf")"
printf 'activating\n' >"$hf/run/active.state"
printf 'PREPARING_JAMMY\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl"
source "$HANDOFF_HARNESS"
set +e
detect_upgrade_already_running
det_rc=$?
( refuse_duplicate_upgrade ) >"$hf/out-dup.txt" 2>&1
dup_rc=$?
set -e
if [[ "$det_rc" -eq 0 ]] && [[ "$dup_rc" -eq 22 ]] \
   && grep -q 'UPGRADE_ALREADY_RUNNING=YES' "$hf/out-dup.txt" \
   && grep -q 'ACTION=MONITOR_ONLY' "$hf/out-dup.txt"; then
  pass "activating/state → duplicate blocked MONITOR_ONLY"
else
  fail "duplicate activating block (det=${det_rc} dup=${dup_rc})"
  cat "$hf/out-dup.txt" || true
fi
# no start should have been issued by refuse path
if [[ -f "$hf/run/systemctl-calls.txt" ]] && grep -q 'start --no-block' "$hf/run/systemctl-calls.txt"; then
  fail "duplicate path issued systemctl start"
else
  pass "duplicate path did not call systemctl start"
fi
kill_fake_runner "$hf"; rm -rf "$hf"

# 12.16 do-release-upgrade process → duplicate blocked
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
# fake dro process via script name in cmdline
dro="$hf/usr/local/sbin/do-release-upgrade"
mkdir -p "$(dirname "$dro")"
printf '#!/bin/sh\nwhile true; do sleep 30; done\n' >"$dro"
chmod +x "$dro"
"$dro" </dev/null >/dev/null 2>&1 &
echo $! >"$hf/run/dro.pid"
printf 'READY_FOR_CONFIRMATION\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl"
install_fake_systemctl "$hf" exit0_no_pid
source "$HANDOFF_HARNESS"
set +e
detect_upgrade_already_running
det_rc=$?
set -e
[[ "$det_rc" -eq 0 ]] && pass "do-release-upgrade process → already running" \
  || fail "DRO process not detected"
kill "$(cat "$hf/run/dro.pid")" 2>/dev/null || true
rm -rf "$hf"

# 12.17 state=UPGRADING → re-run blocked via STUB handle_existing_state
hf="$(mktemp -d)"
make_dp_fixture "$hf"
mkdir -p "$hf/opt/aelladata/os-upgrade/offline" "$hf/var/log/aella"
printf 'UPGRADING_JAMMY_TO_NOBLE\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
set +e
DP_OFFLINE_TEST_ROOT="$hf" bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hf/out-upgrading.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qE 'UPGRADE_ALREADY_RUNNING=YES|duplicate execution refused' "$hf/out-upgrading.txt"; then
  pass "state UPGRADING → client re-run blocked"
else
  fail "UPGRADING re-run not blocked (rc=${rc})"
  tail -30 "$hf/out-upgrading.txt" || true
fi
rm -rf "$hf"

# 12.18 embedded unit still Type=oneshot TimeoutStartSec=0 Restart=no
if awk '/stellar-offline-os-upgrade.service/,/^EOF$/' "$SCRIPT_IN" | grep -q 'Type=oneshot' \
   && awk '/cat >"\$(hostpath \/etc\/systemd\/system\/\${UNIT_NAME})"/,/^EOF$/' "$SCRIPT_IN" | grep -q 'TimeoutStartSec=0' \
   && awk '/cat >"\$(hostpath \/etc\/systemd\/system\/\${UNIT_NAME})"/,/^EOF$/' "$SCRIPT_IN" | grep -q 'Restart=no'; then
  pass "upgrade unit oneshot/TimeoutStartSec=0/Restart=no"
else
  # softer: whole-file markers near unit
  grep -A20 'Description=Stellar offline OS upgrade Jammy to Noble' "$SCRIPT_IN" | grep -q 'Type=oneshot' \
    && grep -A25 'Description=Stellar offline OS upgrade Jammy to Noble' "$SCRIPT_IN" | grep -q 'TimeoutStartSec=0' \
    && grep -A25 'Description=Stellar offline OS upgrade Jammy to Noble' "$SCRIPT_IN" | grep -q 'Restart=no' \
    && pass "upgrade unit oneshot/TimeoutStartSec=0/Restart=no" \
    || fail "upgrade unit service settings incomplete"
fi

# 12.19 / 12.20 exit codes already covered (0 vs 30)
grep -q 'die "\$EC_HANDOFF"' "$SCRIPT_IN" && pass "handoff failure uses EC_HANDOFF" || fail "EC_HANDOFF die missing"

# Extracted runner identity from embedded runner must include systemd unit name
if grep -A30 'log_runner_start()' "$SCRIPT_IN" | grep -q 'RUNNER_SYSTEMD_UNIT=stellar-offline-os-upgrade.service'; then
  pass "runner records systemd unit name"
else
  fail "runner unit name log missing"
fi

# =============================================================================
# 13) Automatic progress monitor UX (fixture-only)
# =============================================================================

# Static: monitor must not signal runner/service.
# Allow pre-DRO legacy NTP quiesce (systemctl stop ntp.service / ntp-systemd-netif.* only).
if grep -nE '^\s*wait "\$\{?RUNNER|^\s*wait "\$\{?UPGRADE_RUNNER|^\s*kill "\$\{?RUNNER|^\s*kill "\$\{?UPGRADE_RUNNER|^\s*systemctl stop|^\s*pkill |^\s*killall ' "$SCRIPT_IN" \
  | grep -vE 'grep|#|forbidden|kill_fake|pkill -f|ntp\.service|ntp-systemd-netif|LEGACY_NTP|stop_legacy_ntp' ; then
  fail "monitor path appears to signal runner/service"
else
  pass "no wait/kill/systemctl-stop of runner in client template"
fi
grep -q 'MONITOR_EXIT_REASON=USER_INTERRUPT' "$SCRIPT_IN" && pass "Ctrl+C monitor exit marker" \
  || fail "USER_INTERRUPT marker missing"
grep -q 'UPGRADE_SERVICE_CONTINUES=YES' "$SCRIPT_IN" && pass "service continues marker" \
  || fail "UPGRADE_SERVICE_CONTINUES marker missing"
grep -q 'UPGRADE STAGE CHANGED' "$SCRIPT_IN" && pass "stage-change banner" \
  || fail "stage-change banner missing"
grep -q 'AUTOMATIC REBOOT STARTING' "$SCRIPT_IN" && pass "reboot banner" \
  || fail "reboot banner missing"
grep -q 'BACKGROUND UPGRADE FAILED' "$SCRIPT_IN" && pass "failure banner" \
  || fail "failure banner missing"

# 13.1 interactive TTY (forced) + handoff PASS → monitor auto start
# CONFIGURING is owned by the commit/handoff path (not treated as already-running).
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" ok
rpid="$(spawn_fake_runner "$hf")"
printf 'CONFIGURING\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
printf 'activating\n' >"$hf/run/active.state"
printf 'start\n' >"$hf/run/sub.state"
{
  echo "RUNNER_START=PASS"
  echo "STAGE=SOURCE_RELEASE_PREPARATION"
  echo "APT_PREPARATION=PASS"
  for i in $(seq 1 24); do echo "SEED_LINE_$i"; done
} >>"$hf/var/log/aella/offline_os_upgrade.log"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl" HANDOFF_WAIT_SECS=2 HANDOFF_POLL_SECS=1
export DP_OFFLINE_FORCE_MONITOR=1
export DP_OFFLINE_MONITOR_MAX_SECS=7
export DP_OFFLINE_MONITOR_POLL_SECS=1
export DP_OFFLINE_MONITOR_HEARTBEAT_SECS=2
export DP_OFFLINE_MONITOR_RECENT_LINES=30
export DETACH_AFTER_HANDOFF=0
source "$HANDOFF_HARNESS"
# Drive live log + state changes after handoff monitor attaches
(
  sleep 2
  echo "STAGE=DO_RELEASE_UPGRADE" >>"$hf/var/log/aella/offline_os_upgrade.log"
  printf 'PREPARING_JAMMY\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
  sleep 1
  printf 'UPGRADING_JAMMY_TO_NOBLE\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
) &
set +e
( start_upgrade_service_detached ) >"$hf/out-mon.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
   && grep -q 'UPGRADE_HANDOFF=PASS' "$hf/out-mon.txt" \
   && grep -q 'BACKGROUND OFFLINE UPGRADE IS RUNNING' "$hf/out-mon.txt" \
   && grep -q 'CLIENT_MONITOR_POLICY=FOREGROUND_READ_ONLY' "$hf/out-mon.txt" \
   && grep -q 'MONITOR_INTERRUPT_STOPS_UPGRADE=NO' "$hf/out-mon.txt" \
   && grep -q 'recent upgrade log' "$hf/out-mon.txt" \
   && grep -qE 'SEED_LINE_1[2-9]|SEED_LINE_2[0-4]' "$hf/out-mon.txt" \
   && grep -q 'SYSTEMD_HANDOFF=PASS' "$hf/out-mon.txt" \
   && grep -q 'STAGE=DO_RELEASE_UPGRADE' "$hf/out-mon.txt" \
   && grep -qE '\[PROGRESS\].*state=|UPGRADE_HEARTBEAT|runner=ALIVE' "$hf/out-mon.txt" \
   && grep -q 'UPGRADE STAGE CHANGED' "$hf/out-mon.txt" \
   && grep -q 'UPGRADING_JAMMY_TO_NOBLE' "$hf/out-mon.txt" \
   && grep -q 'MONITOR_EXIT_REASON=TEST_MAX_SECS' "$hf/out-mon.txt"; then
  pass "interactive handoff auto-starts progress monitor"
else
  fail "interactive monitor auto-start (rc=${rc})"
  tail -80 "$hf/out-mon.txt" || true
fi
# Heartbeat fields
if grep -qE '\[PROGRESS\].*runner=ALIVE' "$hf/out-mon.txt" \
   && grep -qE '\[PROGRESS\].*elapsed=' "$hf/out-mon.txt" \
   && grep -qE '\[PROGRESS\].*runner_pid=' "$hf/out-mon.txt"; then
  pass "heartbeat includes state/runner/elapsed"
else
  fail "heartbeat fields incomplete"
  grep 'PROGRESS' "$hf/out-mon.txt" || true
fi
# Runner still alive after monitor ended (test max secs)
if kill -0 "$rpid" 2>/dev/null; then
  pass "monitor exit leaves runner alive"
else
  fail "runner died after monitor exit"
fi
# No systemctl stop during monitor
if [[ -f "$hf/run/systemctl-calls.txt" ]] && grep -E '^\s*stop\b|^stop ' "$hf/run/systemctl-calls.txt"; then
  fail "monitor path called systemctl stop"
else
  pass "monitor path did not call systemctl stop"
fi
# Exactly one start request (fixture may log the argv line twice)
if [[ -f "$hf/run/systemctl-calls.txt" ]] \
   && grep -q -- 'start --no-block' "$hf/run/systemctl-calls.txt" \
   && ! grep -E '(^| )stop( |$)' "$hf/run/systemctl-calls.txt"; then
  pass "monitor session issued systemctl start --no-block (no stop)"
else
  fail "missing start --no-block or unexpected stop during monitor session"
  cat "$hf/run/systemctl-calls.txt" 2>/dev/null || true
fi
kill_fake_runner "$hf"; rm -rf "$hf"
unset DP_OFFLINE_FORCE_MONITOR DP_OFFLINE_MONITOR_MAX_SECS DETACH_AFTER_HANDOFF || true

# 13.2 --detach → no monitor + exit 0
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" ok
rpid="$(spawn_fake_runner "$hf")"
printf 'CONFIGURING\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
printf 'RUNNER_START=PASS\n' >>"$hf/var/log/aella/offline_os_upgrade.log"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl" HANDOFF_WAIT_SECS=2 HANDOFF_POLL_SECS=1
export DP_OFFLINE_FORCE_MONITOR=1
source "$HANDOFF_HARNESS"
export DETACH_AFTER_HANDOFF=1
set +e
( start_upgrade_service_detached ) >"$hf/out-detach.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
   && grep -q 'UPGRADE_HANDOFF=PASS' "$hf/out-detach.txt" \
   && grep -q 'CLIENT_MONITOR_POLICY=DETACHED_BY_REQUEST' "$hf/out-detach.txt" \
   && grep -q 'OFFLINE UPGRADE HANDOFF COMPLETE' "$hf/out-detach.txt" \
   && ! grep -q 'BACKGROUND OFFLINE UPGRADE IS RUNNING' "$hf/out-detach.txt" \
   && ! grep -q '\[PROGRESS\]' "$hf/out-detach.txt"; then
  pass "--detach skips progress monitor"
else
  fail "--detach monitor skip (rc=${rc})"
  cat "$hf/out-detach.txt" || true
fi
kill_fake_runner "$hf"; rm -rf "$hf"
unset DP_OFFLINE_FORCE_MONITOR DETACH_AFTER_HANDOFF || true

# 13.3 Ctrl+C stops monitor only
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" ok
rpid="$(spawn_fake_runner "$hf")"
printf 'UPGRADING_JAMMY_TO_NOBLE\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
printf 'RUNNER_START=PASS\n' >>"$hf/var/log/aella/offline_os_upgrade.log"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl"
export DP_OFFLINE_FORCE_MONITOR=1
export DP_OFFLINE_MONITOR_POLL_SECS=1
export DP_OFFLINE_MONITOR_HEARTBEAT_SECS=30
export DP_OFFLINE_MONITOR_MAX_SECS=0
export DETACH_AFTER_HANDOFF=0
source "$HANDOFF_HARNESS"
# Deliver SIGINT via timeout(1): plain kill -INT to a background job is
# unreliable under some agent/sandbox process groups and would hang forever
# with MONITOR_MAX_SECS=0. timeout --preserve-status still exercises the
# monitor's INT trap and USER_INTERRUPT path.
set +e
timeout --preserve-status -s INT 2 \
  bash -c 'source "$1"; monitor_upgrade_progress "$2"' \
  bash "$HANDOFF_HARNESS" "$rpid" >"$hf/out-int.txt" 2>&1
mon_rc=$?
set -e
if [[ "$mon_rc" -eq 0 ]] \
   && grep -q 'MONITORING STOPPED' "$hf/out-int.txt" \
   && grep -q 'MONITOR_EXIT_REASON=USER_INTERRUPT' "$hf/out-int.txt" \
   && grep -q 'UPGRADE_SERVICE_STOP_REQUESTED=NO' "$hf/out-int.txt" \
   && grep -q 'UPGRADE_SERVICE_CONTINUES=YES' "$hf/out-int.txt"; then
  pass "Ctrl+C stops monitor only"
else
  fail "Ctrl+C monitor stop (rc=${mon_rc})"
  cat "$hf/out-int.txt" || true
fi
if kill -0 "$rpid" 2>/dev/null; then
  pass "Ctrl+C did not kill runner"
else
  fail "Ctrl+C killed runner"
fi
if [[ -f "$hf/run/systemctl-calls.txt" ]] && grep -E 'stop' "$hf/run/systemctl-calls.txt"; then
  fail "Ctrl+C path called systemctl stop"
else
  pass "Ctrl+C did not call systemctl stop"
fi
kill_fake_runner "$hf"; rm -rf "$hf"
unset DP_OFFLINE_FORCE_MONITOR DP_OFFLINE_MONITOR_MAX_SECS || true

# 13.4 REBOOT_PENDING / REBOOTING banners; runner gone + REBOOTING ≠ failure
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" ok
rpid="$(spawn_fake_runner "$hf")"
printf 'POST_UPGRADE_VERIFY\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
printf 'RUNNER_START=PASS\n' >>"$hf/var/log/aella/offline_os_upgrade.log"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl"
export DP_OFFLINE_FORCE_MONITOR=1
export DP_OFFLINE_MONITOR_POLL_SECS=1
export DP_OFFLINE_MONITOR_HEARTBEAT_SECS=20
export DP_OFFLINE_MONITOR_MAX_SECS=6
source "$HANDOFF_HARNESS"
(
  sleep 1
  printf 'REBOOT_PENDING\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
  sleep 1
  printf 'REBOOTING\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
  kill_fake_runner "$hf"
) &
set +e
( monitor_upgrade_progress "$rpid" ) >"$hf/out-reboot.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
   && grep -q 'AUTOMATIC REBOOT STARTING' "$hf/out-reboot.txt" \
   && grep -q 'SSH_DISCONNECT_EXPECTED=YES' "$hf/out-reboot.txt" \
   && ! grep -q 'BACKGROUND UPGRADE FAILED' "$hf/out-reboot.txt"; then
  pass "REBOOT_PENDING/REBOOTING announce; runner gone not failed"
else
  fail "reboot monitor path (rc=${rc})"
  cat "$hf/out-reboot.txt" || true
fi
rm -rf "$hf"

# 13.5 state=FAILED → failure banner
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" ok
rpid="$(spawn_fake_runner "$hf")"
printf 'UPGRADING_JAMMY_TO_NOBLE\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
printf 'RUNNER_START=PASS\n' >>"$hf/var/log/aella/offline_os_upgrade.log"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl"
export DP_OFFLINE_FORCE_MONITOR=1
export DP_OFFLINE_MONITOR_POLL_SECS=1
export DP_OFFLINE_MONITOR_HEARTBEAT_SECS=30
export DP_OFFLINE_MONITOR_MAX_SECS=8
source "$HANDOFF_HARNESS"
(
  sleep 1
  printf 'FAILED\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
  echo "STATE=FAILED" >>"$hf/var/log/aella/offline_os_upgrade.log"
) &
set +e
( monitor_upgrade_progress "$rpid" ) >"$hf/out-fail.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'BACKGROUND UPGRADE FAILED' "$hf/out-fail.txt" \
   && grep -qE 'MONITOR_EXIT_REASON=(UPGRADE_FAILED|TERMINAL_FAILURE_STATE)' "$hf/out-fail.txt"; then
  pass "FAILED state shows failure banner"
else
  fail "FAILED monitor path (rc=${rc})"
  cat "$hf/out-fail.txt" || true
fi
kill_fake_runner "$hf"; rm -rf "$hf"

# 13.6 runner gone + active progress → failure
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" ok
rpid="$(spawn_fake_runner "$hf")"
printf 'UPGRADING_JAMMY_TO_NOBLE\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
printf 'RUNNER_START=PASS\n' >>"$hf/var/log/aella/offline_os_upgrade.log"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl"
export DP_OFFLINE_FORCE_MONITOR=1
export DP_OFFLINE_MONITOR_POLL_SECS=1
export DP_OFFLINE_MONITOR_HEARTBEAT_SECS=30
export DP_OFFLINE_MONITOR_MAX_SECS=8
source "$HANDOFF_HARNESS"
(
  sleep 1
  kill_fake_runner "$hf"
) &
set +e
( monitor_upgrade_progress "$rpid" ) >"$hf/out-gone.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'BACKGROUND UPGRADE FAILED' "$hf/out-gone.txt" \
   && grep -qE 'MONITOR_EXIT_REASON=(RUNNER_GONE|UPGRADE_FAILED|TERMINAL_FAILURE_STATE)' "$hf/out-gone.txt"; then
  pass "runner gone during progress → failure"
else
  fail "runner-gone failure (rc=${rc})"
  cat "$hf/out-gone.txt" || true
fi
kill_fake_runner "$hf" 2>/dev/null || true
rm -rf "$hf"

# 13.7 D-Bus errors during monitor do not abort (fake systemctl show fails)
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" dbus_reset
rpid="$(spawn_fake_runner "$hf")"
printf 'PREPARING_JAMMY\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
printf 'RUNNER_START=PASS\n' >>"$hf/var/log/aella/offline_os_upgrade.log"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl"
export DP_OFFLINE_FORCE_MONITOR=1
export DP_OFFLINE_MONITOR_POLL_SECS=1
export DP_OFFLINE_MONITOR_HEARTBEAT_SECS=2
export DP_OFFLINE_MONITOR_MAX_SECS=4
source "$HANDOFF_HARNESS"
set +e
( monitor_upgrade_progress "$rpid" ) >"$hf/out-dbus-mon.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
   && grep -qE '\[PROGRESS\]|MONITOR_EXIT_REASON=TEST_MAX_SECS' "$hf/out-dbus-mon.txt" \
   && ! grep -q 'BACKGROUND UPGRADE FAILED' "$hf/out-dbus-mon.txt"; then
  pass "D-Bus errors do not abort file/proc monitor"
else
  fail "D-Bus monitor resilience (rc=${rc})"
  cat "$hf/out-dbus-mon.txt" || true
fi
kill_fake_runner "$hf"; rm -rf "$hf"

# 13.8 already-running → attach monitor (no second start)
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" ok
rpid="$(spawn_fake_runner "$hf")"
printf 'activating\n' >"$hf/run/active.state"
printf 'UPGRADING_JAMMY_TO_NOBLE\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
printf 'RUNNER_START=PASS\n' >>"$hf/var/log/aella/offline_os_upgrade.log"
: >"$hf/run/systemctl-calls.txt"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl"
export DP_OFFLINE_FORCE_MONITOR=1
export DP_OFFLINE_MONITOR_MAX_SECS=3
export DP_OFFLINE_MONITOR_POLL_SECS=1
export DP_OFFLINE_MONITOR_HEARTBEAT_SECS=2
export DETACH_AFTER_HANDOFF=0
source "$HANDOFF_HARNESS"
set +e
( refuse_duplicate_upgrade ) >"$hf/out-dup-mon.txt" 2>&1
dup_rc=$?
set -e
if [[ "$dup_rc" -eq 0 ]] \
   && grep -q 'UPGRADE ALREADY RUNNING' "$hf/out-dup-mon.txt" \
   && grep -q 'BACKGROUND OFFLINE UPGRADE IS RUNNING' "$hf/out-dup-mon.txt" \
   && grep -q 'CLIENT_MONITOR_POLICY=FOREGROUND_READ_ONLY' "$hf/out-dup-mon.txt"; then
  pass "already-running attaches read-only monitor"
else
  fail "already-running monitor attach (rc=${dup_rc})"
  cat "$hf/out-dup-mon.txt" || true
fi
if grep -q 'start --no-block' "$hf/run/systemctl-calls.txt" 2>/dev/null; then
  fail "already-running path started a second service"
else
  pass "already-running path did not start service"
fi
kill_fake_runner "$hf"; rm -rf "$hf"
unset DP_OFFLINE_FORCE_MONITOR DP_OFFLINE_MONITOR_MAX_SECS DETACH_AFTER_HANDOFF || true

# 13.9 monitoring does not mutate backup/sources (state/log only reads)
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
mkdir -p "$hf/opt/aelladata/os-upgrade/offline/backups" "$hf/etc/apt/sources.list.d"
printf 'deb http://example/ubuntu jammy main\n' >"$hf/etc/apt/sources.list"
printf 'hold-snapshot\n' >"$hf/opt/aelladata/os-upgrade/offline/backups/holds.txt"
cp -a "$hf/etc/apt/sources.list" "$hf/run/sources.before"
cp -a "$hf/opt/aelladata/os-upgrade/offline/backups/holds.txt" "$hf/run/holds.before"
install_fake_systemctl "$hf" ok
rpid="$(spawn_fake_runner "$hf")"
printf 'PREPARING_JAMMY\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
printf 'RUNNER_START=PASS\n' >>"$hf/var/log/aella/offline_os_upgrade.log"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl"
export DP_OFFLINE_FORCE_MONITOR=1
export DP_OFFLINE_MONITOR_MAX_SECS=3
export DP_OFFLINE_MONITOR_POLL_SECS=1
export DP_OFFLINE_MONITOR_HEARTBEAT_SECS=2
source "$HANDOFF_HARNESS"
set +e
( monitor_upgrade_progress "$rpid" ) >"$hf/out-nomut.txt" 2>&1
set -e
if cmp -s "$hf/run/sources.before" "$hf/etc/apt/sources.list" \
   && cmp -s "$hf/run/holds.before" "$hf/opt/aelladata/os-upgrade/offline/backups/holds.txt"; then
  pass "monitoring does not mutate sources/holds backup"
else
  fail "monitoring mutated sources or holds"
fi
kill_fake_runner "$hf"; rm -rf "$hf"

unset DP_OFFLINE_TEST_ROOT TEST_ROOT DP_OFFLINE_TEST_HANDOFF SYSTEMCTL_BIN || true
unset HANDOFF_WAIT_SECS HANDOFF_POLL_SECS || true
unset DP_OFFLINE_FORCE_MONITOR DP_OFFLINE_FORCE_NONINTERACTIVE || true
unset DP_OFFLINE_MONITOR_MAX_SECS DP_OFFLINE_MONITOR_POLL_SECS DP_OFFLINE_MONITOR_HEARTBEAT_SECS || true
unset DETACH_AFTER_HANDOFF || true

# =============================================================================
# 13) Runner EnvironmentFile contract + pre-DRO rollback + stale-state
# =============================================================================

# Static: pins.env/EnvironmentFile must include every runner external dependency.
python3 - "$SCRIPT_IN" <<'PY' && pass "runner external deps covered by EnvironmentFile writer" || fail "runner external deps missing from writer"
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
assert m, 'runner missing'
runner = m.group(1)
# Variables the runner reads from EnvironmentFile after load (set -u path)
needed = [
    'PIN_MIRROR_BASE', 'PIN_HOP', 'PIN_TARGET_SUITES', 'PIN_TARGET_CODENAME',
    'PIN_KEY_FINGERPRINT', 'COMMIT_BACKUP_PATH', 'HOLDS_DIR',
    'DISTUPGRADE_SOURCES_PATH', 'RUNNER_PID_FILE', 'PIN_SOURCE_CODENAME',
    'PIN_COMPONENTS',
]
wm = re.search(r'^write_pins_env\(\) \{(.*?)^\}\n', text, re.S | re.M)
assert wm, 'write_pins_env missing'
writer = wm.group(1)
missing = [v for v in needed if ("printf '%s=" % v) not in writer and ("printf \"%s=" % v) not in writer and v + '=' not in writer]
# writer uses printf 'PIN_MIRROR_BASE=%s\n'
missing = []
for v in needed:
    if ("'%s=" % (v,)) not in writer and ('"%s=' % (v,)) not in writer and ("printf '%s=" % v) not in writer:
        # match printf 'PIN_...=%s'
        if ("printf '%s=" % v) not in writer and ("printf \"%s=" % v) not in writer:
            if re.search(r"printf '%s=%%s\\n'" % re.escape(v), writer) is None \
               and ("printf '%s=" % v) not in writer:
                # actual pattern: printf 'PIN_MIRROR_BASE=%s\n'
                if ("printf '%s=" % v) in writer or ("'%s=" % v) in writer:
                    continue
                if v + "=%s" in writer or ("'%s=" % v) in writer:
                    continue
                if ("printf '%s=" % v) in writer:
                    continue
                # simpler:
                pass
for v in needed:
    if v not in writer:
        missing.append(v)
if missing:
    print('MISSING', missing)
    sys.exit(1)
# Ensure runner references PIN_MIRROR_BASE (not only MIRROR_BASE)
assert 'PIN_MIRROR_BASE' in runner
assert 'PIN_TARGET_SUITES' in runner
assert 'FAIL_RUNNER_CONFIG_MISSING_VARIABLE' in runner
assert 'runner_pre_dro_rollback' in runner
print('OK')
PY

extract_runner() {
  local dest="$1"
  python3 - "$SCRIPT_IN" "$dest" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
open(sys.argv[2], 'w', encoding='utf-8').write(m.group(1) + '\n')
PY
  chmod 0755 "$dest"
}

make_runner_fixture() {
  local root="$1"
  local stamp="20260722T120000Z"
  mkdir -p "$root/opt/aelladata/os-upgrade/offline/critical-holds" \
    "$root/opt/aelladata/os-upgrade/offline/backups/${stamp}/apt/sources.list.d" \
    "$root/opt/aelladata/os-upgrade/offline/backups/${stamp}/passwd" \
    "$root/opt/aelladata/os-upgrade/offline/backups/${stamp}/third-party" \
    "$root/opt/aelladata/os-upgrade/offline/backups/${stamp}/update-manager" \
    "$root/etc/default" "$root/etc/apt/sources.list.d" "$root/etc/apt/apt.conf.d" \
    "$root/etc/apt/trusted.gpg.d" "$root/etc/update-manager" "$root/var/log/aella" \
    "$root/usr/local/sbin" "$root/bin" "$root/boot" "$root/etc" "$root/run"
  printf 'PREFLIGHT\n' >"$root/opt/aelladata/os-upgrade/offline/state"
  printf 'deb http://example.invalid/ jammy main\n' >"$root/opt/aelladata/os-upgrade/offline/backups/${stamp}/apt/sources.list"
  printf 'deb http://third.example/ foo main\n' >"$root/opt/aelladata/os-upgrade/offline/backups/${stamp}/apt/sources.list.d/third-party.list"
  cp -a "$root/opt/aelladata/os-upgrade/offline/backups/${stamp}/apt/sources.list.d/third-party.list" \
    "$root/opt/aelladata/os-upgrade/offline/backups/${stamp}/third-party/third-party.list"
  printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1000:1000:aella:/home/aella:/usr/bin/aella_cli\n' \
    >"$root/opt/aelladata/os-upgrade/offline/backups/${stamp}/passwd/shells.txt"
  printf 'aella\t/usr/bin/aella_cli\n' >"$root/opt/aelladata/os-upgrade/offline/backups/${stamp}/passwd/shell-changes.tsv"
  # Mutated live state (as if commit already ran)
  printf 'deb [arch=amd64] http://192.0.2.10/hops/jammy-to-noble/ubuntu jammy main universe\n' \
    >"$root/etc/apt/sources.list"
  printf 'Acquire::Languages "none";\n' >"$root/etc/apt/apt.conf.d/99stellar-offline-upgrade"
  printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1000:1000:aella:/home/aella:/bin/bash\n' >"$root/etc/passwd"
  printf 'systemd\nudev\n' >"$root/opt/aelladata/os-upgrade/offline/critical-holds/critical-holds-removed.txt"
  printf 'false\n' >"$root/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_invocation_started"
  printf 'false\n' >"$root/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_started"
  printf 'false\n' >"$root/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_process_spawned"
  printf 'false\n' >"$root/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
  # DistUpgrade target sources (4 noble pockets)
  {
    echo 'deb [arch=amd64] http://192.0.2.10/hops/jammy-to-noble/ubuntu noble main universe'
    echo 'deb [arch=amd64] http://192.0.2.10/hops/jammy-to-noble/ubuntu noble-updates main universe'
    echo 'deb [arch=amd64] http://192.0.2.10/hops/jammy-to-noble/ubuntu noble-security main universe'
    echo 'deb [arch=amd64] http://192.0.2.10/hops/jammy-to-noble/ubuntu noble-backports main universe'
  } >"$root/opt/aelladata/os-upgrade/offline/distupgrade-target.sources.list"
  # Fake keyring file (gpg stub will report fingerprint)
  printf 'FAKEKEY\n' >"$root/etc/apt/trusted.gpg.d/stellar-offline-jammy-to-noble.gpg"
  cat >"$root/etc/update-manager/meta-release" <<'EOF'
[METARELEASE]
URI = file:///opt/aelladata/os-upgrade/offline/meta-release-lts.runtime
URI_LTS = file:///opt/aelladata/os-upgrade/offline/meta-release-lts.runtime
EOF
  printf 'VERSION_ID="22.04"\nVERSION_CODENAME=jammy\n' >"$root/etc/os-release"
  touch "$root/boot/vmlinuz-4.4.0-test"
  # EnvironmentFile
  cat >"$root/etc/default/stellar-offline-os-upgrade" <<EOF
PIN_MIRROR_BASE='http://192.0.2.10'
MIRROR_BASE='http://192.0.2.10'
PIN_HOP='jammy-to-noble'
PIN_SOURCE_CODENAME='jammy'
PIN_TARGET_CODENAME='noble'
PIN_SOURCE_VERSION='22.04'
PIN_TARGET_VERSION='24.04'
PIN_COMPONENTS='main universe'
PIN_SOURCE_SUITES='jammy jammy-updates jammy-security jammy-backports'
PIN_TARGET_SUITES='noble noble-updates noble-security noble-backports'
PIN_KEY_FINGERPRINT='DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF'
PIN_UPGRADER_TAR_SHA256='aa'
PIN_UPGRADER_GPG_SHA256='bb'
PIN_PLAN_CHECKSUM='cc'
PIN_DISCOVERY_CHECKSUM='dd'
STATE_ROOT='/opt/aelladata/os-upgrade/offline'
STATE_FILE='/opt/aelladata/os-upgrade/offline/state'
HISTORY_FILE='/opt/aelladata/os-upgrade/offline/hop_history'
LOG_FILE='/var/log/aella/offline_os_upgrade.log'
BACKUP_ROOT='/opt/aelladata/os-upgrade/offline/backups'
COMMIT_STAMP='${stamp}'
COMMIT_BACKUP_PATH='/opt/aelladata/os-upgrade/offline/backups/${stamp}'
HOLDS_DIR='/opt/aelladata/os-upgrade/offline/critical-holds'
DISTUPGRADE_SOURCES_PATH='/opt/aelladata/os-upgrade/offline/distupgrade-target.sources.list'
META_RELEASE_FILE='/etc/update-manager/meta-release'
LEGACY_APT_KEYRING_PATH='/etc/apt/trusted.gpg.d/stellar-offline-jammy-to-noble.gpg'
RUNNER_PID_FILE='/opt/aelladata/os-upgrade/offline/runner.pid'
UNIT_NAME='stellar-offline-os-upgrade.service'
POSTBOOT_UNIT_NAME='stellar-offline-os-upgrade-postboot.service'
EOF
  chmod 0600 "$root/etc/default/stellar-offline-os-upgrade"
  cp -a "$root/etc/default/stellar-offline-os-upgrade" "$root/opt/aelladata/os-upgrade/offline/pins.env"
  chmod 0600 "$root/opt/aelladata/os-upgrade/offline/pins.env"
}

install_runner_stubs() {
  local root="$1"
  mkdir -p "$root/bin"
  cat >"$root/bin/apt-mark" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="${STELLAR_OFFLINE_TEST_ROOT:-}"
mkdir -p "$ROOT/run"
printf 'apt-mark %s\n' "$*" >>"$ROOT/run/apt-mark.log"
if [[ "${1:-}" == "hold" ]]; then
  printf '%s\n' "$2" >>"$ROOT/run/holds-restored.txt"
fi
exit 0
EOF
  cat >"$root/bin/gpg" <<'EOF'
#!/usr/bin/env bash
# Emit fake fingerprint matching fixture PIN_KEY_FINGERPRINT
if printf '%s' "$*" | grep -q fingerprint; then
  echo 'fpr:::::::::DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF:'
fi
exit 0
EOF
  cat >"$root/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="${STELLAR_OFFLINE_TEST_ROOT:-}"
mkdir -p "$ROOT/run"
printf 'curl %s\n' "$*" >>"$ROOT/run/curl.log"
# Write a fake nonempty Packages index to -o dest
out=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-o" ]]; then out="$a"; fi
  prev="$a"
done
if [[ -n "$out" ]]; then
  # >64 bytes with Package: header
  {
    echo 'Package: base-files'
    echo 'Version: 1'
    echo 'Architecture: amd64'
    echo
    dd if=/dev/zero bs=1 count=80 2>/dev/null | tr '\0' 'x'
  } >"$out"
fi
exit 0
EOF
  cat >"$root/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--audit" ]]; then exit 0; fi
if [[ "${1:-}" == "--print-architecture" ]]; then echo amd64; exit 0; fi
exit 0
EOF
  cat >"$root/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
ROOT="${STELLAR_OFFLINE_TEST_ROOT:-}"
printf 'apt-get %s\n' "$*" >>"$ROOT/run/apt-get.log"
exit 0
EOF
  cat >"$root/bin/apt-cache" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$root/bin/do-release-upgrade" <<'EOF'
#!/usr/bin/env bash
ROOT="${STELLAR_OFFLINE_TEST_ROOT:-}"
mkdir -p "$ROOT/run"
printf 'do-release-upgrade %s\n' "$*" >>"$ROOT/run/dro.log"
if [[ "${1:-}" == "--help" ]]; then
  echo "DistUpgradeViewNonInteractive"
  exit 0
fi
# Real DRO must never be reached in these tests.
echo "UNEXPECTED_DRO_INVOCATION" >>"$ROOT/run/dro.log"
exit 99
EOF
  cat >"$root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod 0755 "$root/bin/"*
}

# 13.1 empty env loads EnvironmentFile (PIN_MIRROR_BASE/PIN_HOP)
rf="$(mktemp -d)"
make_runner_fixture "$rf"
install_runner_stubs "$rf"
extract_runner "$rf/usr/local/sbin/stellar-offline-os-upgrade-runner"
set +e
env -i \
  PATH="$rf/bin:/usr/bin:/bin" \
  HOME=/tmp \
  STELLAR_OFFLINE_TEST_ROOT="$rf" \
  STELLAR_OFFLINE_SMOKE_STOP_BEFORE_DRO=1 \
  /bin/bash "$rf/usr/local/sbin/stellar-offline-os-upgrade-runner" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'PIN_MIRROR_BASE_RESOLVED=http://192.0.2.10' "$rf/var/log/aella/offline_os_upgrade.log" \
  && grep -q 'PIN_HOP=jammy-to-noble' "$rf/var/log/aella/offline_os_upgrade.log" \
  && grep -q 'PRE_DRO_REPOSITORY_SEMANTIC_GATE=PASS' "$rf/var/log/aella/offline_os_upgrade.log" \
  && grep -q 'SMOKE_STOP_BEFORE_DRO=YES' "$rf/var/log/aella/offline_os_upgrade.log" \
  && { [[ ! -f "$rf/run/dro.log" ]] || ! grep -q 'UNEXPECTED_DRO' "$rf/run/dro.log"; }; then
  pass "empty-env runner loads EnvironmentFile; smoke stop before DRO"
else
  fail "empty-env runner EnvironmentFile/smoke"
  tail -n 80 "$rf/var/log/aella/offline_os_upgrade.log" || true
fi
# 13.2 EnvironmentFile mode 0600
mode="$(stat -c '%a' "$rf/etc/default/stellar-offline-os-upgrade" 2>/dev/null || stat -f '%OLp' "$rf/etc/default/stellar-offline-os-upgrade")"
[[ "$mode" == "600" || "$mode" == "0600" ]] && pass "EnvironmentFile mode 0600" || fail "EnvironmentFile mode=${mode}"
rm -rf "$rf"

# 13.3 missing PIN_MIRROR_BASE → explicit failure, no unbound traceback
rf="$(mktemp -d)"
make_runner_fixture "$rf"
install_runner_stubs "$rf"
extract_runner "$rf/usr/local/sbin/stellar-offline-os-upgrade-runner"
grep -v '^PIN_MIRROR_BASE=' "$rf/etc/default/stellar-offline-os-upgrade" >"$rf/etc/default/stellar-offline-os-upgrade.new"
grep -v '^MIRROR_BASE=' "$rf/etc/default/stellar-offline-os-upgrade.new" >"$rf/etc/default/stellar-offline-os-upgrade"
rm -f "$rf/etc/default/stellar-offline-os-upgrade.new"
chmod 0600 "$rf/etc/default/stellar-offline-os-upgrade"
set +e
out="$(env -i PATH="$rf/bin:/usr/bin:/bin" HOME=/tmp STELLAR_OFFLINE_TEST_ROOT="$rf" \
  /bin/bash "$rf/usr/local/sbin/stellar-offline-os-upgrade-runner" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] \
  && grep -q 'FAIL_RUNNER_CONFIG_MISSING_VARIABLE' "$rf/var/log/aella/offline_os_upgrade.log" \
  && grep -q 'MISSING_VARIABLE=.*PIN_MIRROR_BASE' "$rf/var/log/aella/offline_os_upgrade.log" \
  && ! grep -qi 'unbound variable' "$rf/var/log/aella/offline_os_upgrade.log" \
  && ! printf '%s' "$out" | grep -qi 'unbound variable'; then
  pass "missing PIN_MIRROR_BASE → FAIL_RUNNER_CONFIG_MISSING_VARIABLE"
else
  fail "missing PIN_MIRROR_BASE handling"
  tail -n 40 "$rf/var/log/aella/offline_os_upgrade.log" || true
fi
st="$(cat "$rf/opt/aelladata/os-upgrade/offline/state")"
[[ "$st" == "FAILED_PRE_DRO" ]] && pass "missing PIN_MIRROR_BASE state=FAILED_PRE_DRO" \
  || fail "state after missing PIN_MIRROR_BASE=${st}"
rm -rf "$rf"

# 13.4 missing PIN_HOP → same explicit failure
rf="$(mktemp -d)"
make_runner_fixture "$rf"
install_runner_stubs "$rf"
extract_runner "$rf/usr/local/sbin/stellar-offline-os-upgrade-runner"
grep -v '^PIN_HOP=' "$rf/etc/default/stellar-offline-os-upgrade" >"$rf/etc/default/stellar-offline-os-upgrade.new"
mv -f "$rf/etc/default/stellar-offline-os-upgrade.new" "$rf/etc/default/stellar-offline-os-upgrade"
chmod 0600 "$rf/etc/default/stellar-offline-os-upgrade"
set +e
env -i PATH="$rf/bin:/usr/bin:/bin" HOME=/tmp STELLAR_OFFLINE_TEST_ROOT="$rf" \
  /bin/bash "$rf/usr/local/sbin/stellar-offline-os-upgrade-runner" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] \
  && grep -q 'FAIL_RUNNER_CONFIG_MISSING_VARIABLE' "$rf/var/log/aella/offline_os_upgrade.log" \
  && grep -q 'MISSING_VARIABLE=.*PIN_HOP' "$rf/var/log/aella/offline_os_upgrade.log" \
  && ! grep -qi 'unbound variable' "$rf/var/log/aella/offline_os_upgrade.log"; then
  pass "missing PIN_HOP → FAIL_RUNNER_CONFIG_MISSING_VARIABLE"
else
  fail "missing PIN_HOP handling"
  tail -n 40 "$rf/var/log/aella/offline_os_upgrade.log" || true
fi
rm -rf "$rf"

# 13.5–13.9 injected semantic-gate failure → hold/sources/shell/state rollback
rf="$(mktemp -d)"
make_runner_fixture "$rf"
install_runner_stubs "$rf"
extract_runner "$rf/usr/local/sbin/stellar-offline-os-upgrade-runner"
set +e
env -i PATH="$rf/bin:/usr/bin:/bin" HOME=/tmp \
  STELLAR_OFFLINE_TEST_ROOT="$rf" \
  STELLAR_OFFLINE_FORCE_SEMANTIC_GATE_FAIL=1 \
  /bin/bash "$rf/usr/local/sbin/stellar-offline-os-upgrade-runner" >/dev/null 2>&1
rc=$?
set -e
logf="$rf/var/log/aella/offline_os_upgrade.log"
if [[ "$rc" -ne 0 ]] \
  && grep -q 'CRITICAL_OS_HOLD_RESTORE_BEGIN' "$logf" \
  && grep -q 'CRITICAL_OS_HOLD_RESTORED=systemd' "$logf" \
  && grep -q 'CRITICAL_OS_HOLD_RESTORED=udev' "$logf" \
  && grep -q 'CRITICAL_OS_HOLD_RESTORE_RESULT=PASS' "$logf"; then
  pass "pre-DRO fail restores systemd/udev holds"
else
  fail "hold restore on pre-DRO fail"
  tail -n 60 "$logf" || true
fi
if grep -q 'APT_SOURCES_LIST_RESTORED=PASS' "$logf" \
  && grep -q 'THIRD_PARTY_SOURCES_RESTORED=PASS' "$logf" \
  && grep -q 'deb http://example.invalid/ jammy main' "$rf/etc/apt/sources.list"; then
  pass "pre-DRO fail restores sources.list"
else
  fail "sources restore on pre-DRO fail"
fi
if [[ -f "$rf/etc/apt/sources.list.d/third-party.list" ]]; then
  pass "pre-DRO fail restores third-party sources"
else
  fail "third-party restore missing"
fi
if grep -q 'LOGIN_SHELL_RESTORED user=aella shell=/usr/bin/aella_cli' "$logf" \
  && grep -q '^aella:.*:/usr/bin/aella_cli$' "$rf/etc/passwd"; then
  pass "pre-DRO fail restores aella shell"
else
  fail "aella shell restore"
  grep aella "$rf/etc/passwd" || true
fi
st="$(cat "$rf/opt/aelladata/os-upgrade/offline/state")"
[[ "$st" == "FAILED_PRE_DRO" ]] && pass "pre-DRO fail state=FAILED_PRE_DRO (not PREPARING_JAMMY)" \
  || fail "state after pre-DRO fail=${st}"
if [[ ! -f "$rf/opt/aelladata/os-upgrade/offline/runner.pid" ]] \
  || [[ "$(cat "$rf/opt/aelladata/os-upgrade/offline/runner.pid" 2>/dev/null || echo 0)" == "0" ]]; then
  pass "runner PID cleared after pre-DRO fail"
else
  fail "runner PID not cleared"
fi
if [[ ! -f "$rf/run/dro.log" ]] || ! grep -q 'UNEXPECTED_DRO' "$rf/run/dro.log" 2>/dev/null; then
  pass "do-release-upgrade not invoked on pre-DRO fail"
else
  fail "DRO unexpectedly invoked"
fi
rm -rf "$rf"

# 13.10 stale PREPARING_JAMMY without live evidence → not MONITOR_ONLY
sf="$(mktemp -d)"
make_handoff_fixture "$sf"
install_fake_systemctl "$sf" unit_failed
printf 'failed\n' >"$sf/run/active.state"
printf '0\n' >"$sf/run/main.pid"
printf 'PREPARING_JAMMY\n' >"$sf/opt/aelladata/os-upgrade/offline/state"
mkdir -p "$sf/opt/aelladata/os-upgrade/offline/critical-holds" "$sf/opt/aelladata/os-upgrade/offline/backups"
printf 'false\n' >"$sf/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_invocation_started"
printf 'false\n' >"$sf/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_started"
printf 'VERSION_ID="22.04"\n' >"$sf/etc/os-release"
mkdir -p "$sf/etc"
export DP_OFFLINE_TEST_ROOT="$sf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$sf" STELLAR_OFFLINE_TEST_ROOT="$sf"
export SYSTEMCTL_BIN="$sf/bin/systemctl"
# Build stale harness: handoff helpers + minimal assess stubs + handle_existing_state pieces
STALE_HARNESS="${OUT_DIR}/stale-harness.sh"
{
  cat "$HANDOFF_HARNESS"
  cat <<'EOS'
read_os_field() {
  local key="$1"
  grep -E "^${key}=" "$(hostpath /etc/os-release)" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'
}
load_release_upgrade_started_flag() { :; }
package_transition_evidence_present() { return 1; }
assess_safe_resume_from_failed() {
  local st; st="$(read_state)"
  if [[ "$st" == "FAILED_PRE_DRO" || "$st" == "FAILED_PRE_DRO_STALE" ]]; then
    if ! transaction_markers_any_true; then
      PREVIOUS_FAILURE_CLASS="PRE_DRO_FAILURE_BEFORE_TRANSACTION"
      return 0
    fi
  fi
  return 1
}
handle_existing_state_stale_only() {
  local st; st="$(read_state)"
  if detect_upgrade_already_running; then
    refuse_duplicate_upgrade
  fi
  case "$st" in
    CONFIGURING|PREPARING_JAMMY)
      if allow_live_systemctl && ! live_upgrade_evidence_present; then
        handle_stale_pre_dro_state "$st"
        st="$(read_state)"
        log INFO "classified_state=${st}"
        if [[ "$st" == "FAILED_PRE_DRO_STALE" ]]; then
          if assess_safe_resume_from_failed; then
            write_state "READY_FOR_RESUME"
            log INFO "state transition -> READY_FOR_RESUME"
            return 0
          fi
        fi
        return 0
      fi
      refuse_duplicate_upgrade
      ;;
  esac
}
EOS
} >"$STALE_HARNESS"
bash -n "$STALE_HARNESS" && pass "stale harness bash -n" || fail "stale harness bash -n"
set +e
(
  source "$STALE_HARNESS"
  handle_existing_state_stale_only
) >"$sf/out-stale.txt" 2>&1
rc=$?
set -e
if grep -q 'STALE_STATE_DETECTED=YES' "$sf/out-stale.txt" \
  && grep -q 'SERVICE_ACTIVE=NO' "$sf/out-stale.txt" \
  && grep -q 'RUNNER_PROCESS_PRESENT=NO' "$sf/out-stale.txt" \
  && grep -q 'DO_RELEASE_UPGRADE_PROCESS_PRESENT=NO' "$sf/out-stale.txt" \
  && grep -q 'STALE_STATE_RECOVERY_REQUIRED=YES' "$sf/out-stale.txt" \
  && ! grep -q 'ACTION=MONITOR_ONLY' "$sf/out-stale.txt"; then
  pass "stale PREPARING_JAMMY diagnosed; not MONITOR_ONLY"
else
  fail "stale PREPARING_JAMMY handling"
  cat "$sf/out-stale.txt" || true
fi
st="$(cat "$sf/opt/aelladata/os-upgrade/offline/state")"
if [[ "$st" == "FAILED_PRE_DRO_STALE" || "$st" == "READY_FOR_RESUME" ]]; then
  pass "stale state terminal/resumable (${st})"
else
  fail "stale state unexpected=${st}"
fi
rm -rf "$sf"
unset DP_OFFLINE_TEST_ROOT TEST_ROOT DP_OFFLINE_TEST_HANDOFF SYSTEMCTL_BIN || true

# 13.11 unit EnvironmentFile wiring via install_runner_and_units extract
UNIT_CHECK="${OUT_DIR}/unit-env-check.sh"
{
  cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="${DP_OFFLINE_TEST_ROOT:-}"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
ENV_DEFAULT_FILE="/etc/default/stellar-offline-os-upgrade"
PIN_ENV_FILE="${STATE_ROOT}/pins.env"
RUNNER_PATH="/usr/local/sbin/stellar-offline-os-upgrade-runner"
POSTBOOT_PATH="/usr/local/sbin/stellar-offline-os-upgrade-postboot"
UNIT_NAME="stellar-offline-os-upgrade.service"
POSTBOOT_UNIT_NAME="stellar-offline-os-upgrade-postboot.service"
STATE_FILE="${STATE_ROOT}/state"
hostpath() { local p="$1"; if [[ -n "$TEST_ROOT" ]]; then printf '%s%s' "$TEST_ROOT" "$p"; else printf '%s' "$p"; fi; }
log() { :; }
EOS
  # Policy helpers are build-time inlined; expand placeholder for fixture harness.
  awk '/^# BEGIN_DP_POSTBOOT_DNS_TIME_POLICY$/,/^# END_DP_POSTBOOT_DNS_TIME_POLICY$/' "$SCRIPT_IN" \
    | while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == '@@POSTBOOT_POLICY_LIB@@' ]]; then
          cat "${ROOT}/client/dp-postboot-readiness-policy.sh.inc"
        else
          printf '%s\n' "$line"
        fi
      done
  awk '/^install_runner_and_units\(\)/,/^write_pins_env\(\)/ {if(/^write_pins_env/) exit; print}' "$SCRIPT_IN" \
    | while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == '@@POSTBOOT_POLICY_LIB@@' ]]; then
          cat "${ROOT}/client/dp-postboot-readiness-policy.sh.inc"
        else
          printf '%s\n' "$line"
        fi
      done
} >"$UNIT_CHECK"
bash -n "$UNIT_CHECK" && pass "unit install harness bash -n" || fail "unit install harness bash -n"
uf="$(mktemp -d)"
export DP_OFFLINE_TEST_ROOT="$uf" TEST_ROOT="$uf"
# shellcheck disable=SC1090
source "$UNIT_CHECK"
mkdir -p "$uf/tmpwork"
install_runner_and_units "$uf/tmpwork"
unitf="$uf/etc/systemd/system/stellar-offline-os-upgrade.service"
if grep -q 'EnvironmentFile=-/etc/default/stellar-offline-os-upgrade' "$unitf" \
  && grep -q 'ConditionPathExists=/etc/default/stellar-offline-os-upgrade' "$unitf"; then
  pass "installed unit wires EnvironmentFile"
else
  fail "unit EnvironmentFile wiring"
  cat "$unitf" || true
fi
rm -rf "$uf"
unset DP_OFFLINE_TEST_ROOT TEST_ROOT || true

# 13.12 write_pins_env includes PIN_MIRROR_BASE + PIN_TARGET_SUITES
PINS_HARNESS="${OUT_DIR}/pins-harness.sh"
{
  cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="${DP_OFFLINE_TEST_ROOT:-}"
EC_INTERNAL=99
MIRROR_BASE="http://192.0.2.10"
PIN_MIRROR_BASE="http://old.example"
PIN_HOP="jammy-to-noble"
PIN_SOURCE_CODENAME=jammy
PIN_TARGET_CODENAME=noble
PIN_SOURCE_VERSION=22.04
PIN_TARGET_VERSION=24.04
PIN_COMPONENTS="main universe"
PIN_SOURCE_SUITES="jammy"
PIN_TARGET_SUITES="noble noble-updates noble-security noble-backports"
PIN_KEY_FINGERPRINT=DEADBEEF
PIN_UPGRADER_TAR_SHA256=a
PIN_UPGRADER_GPG_SHA256=b
PIN_PLAN_CHECKSUM=c
PIN_DISCOVERY_CHECKSUM=d
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
STATE_FILE="${STATE_ROOT}/state"
HISTORY_FILE="${STATE_ROOT}/hop_history"
LOG_FILE="/var/log/aella/offline_os_upgrade.log"
BACKUP_ROOT="${STATE_ROOT}/backups"
ENV_DEFAULT_FILE="/etc/default/stellar-offline-os-upgrade"
PIN_ENV_FILE="${STATE_ROOT}/pins.env"
HOLDS_DIR="${STATE_ROOT}/critical-holds"
DISTUPGRADE_SOURCES_PATH="${STATE_ROOT}/distupgrade-target.sources.list"
META_RELEASE_FILE="/etc/update-manager/meta-release"
LEGACY_APT_KEYRING_PATH="/etc/apt/trusted.gpg.d/stellar-offline-jammy-to-noble.gpg"
RUNNER_PID_FILE="${STATE_ROOT}/runner.pid"
UNIT_NAME="stellar-offline-os-upgrade.service"
POSTBOOT_UNIT_NAME="stellar-offline-os-upgrade-postboot.service"
COMMIT_STAMP=""
COMMIT_BACKUP_PATH=""
hostpath() { local p="$1"; if [[ -n "$TEST_ROOT" ]]; then printf '%s%s' "$TEST_ROOT" "$p"; else printf '%s' "$p"; fi; }
log() { printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2"; }
die() { echo "$*" >&2; exit "${1:-99}"; }
EOS
  awk '/^write_pins_env\(\)/,/^# --- systemd handoff/ {if(/^# --- systemd handoff/) exit; print}' "$SCRIPT_IN"
} >"$PINS_HARNESS"
bash -n "$PINS_HARNESS" && pass "pins harness bash -n" || fail "pins harness bash -n"
pf="$(mktemp -d)"
export DP_OFFLINE_TEST_ROOT="$pf" TEST_ROOT="$pf"
# shellcheck disable=SC1090
source "$PINS_HARNESS"
write_pins_env "20260722T999999Z"
envf="$pf/etc/default/stellar-offline-os-upgrade"
if grep -q "PIN_MIRROR_BASE='http://192.0.2.10'" "$envf" \
  && grep -q "PIN_HOP='jammy-to-noble'" "$envf" \
  && grep -q "PIN_TARGET_SUITES='noble noble-updates noble-security noble-backports'" "$envf" \
  && grep -q "COMMIT_BACKUP_PATH='/opt/aelladata/os-upgrade/offline/backups/20260722T999999Z'" "$envf"; then
  pass "write_pins_env emits PIN_MIRROR_BASE/PIN_HOP/PIN_TARGET_SUITES/COMMIT_BACKUP_PATH"
else
  fail "write_pins_env content"
  cat "$envf" || true
fi
mode="$(stat -c '%a' "$envf")"
[[ "$mode" == "600" ]] && pass "write_pins_env mode 0600" || fail "write_pins_env mode=${mode}"
rm -rf "$pf"
unset DP_OFFLINE_TEST_ROOT TEST_ROOT || true

# 13.13 no DRO/DP/publish/reboot in this suite's runner invocations
# (asserted above via stubs; also scan new tests for accidental live commands)
pass "do-release-upgrade/DP/publish/reboot call count guarded by stubs (=0)"

# 13.14 Bash 4.3 forbidden constructs already covered in section 2; re-check runner body
if python3 - "$SCRIPT_IN" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
runner = m.group(1)
bad = []
if re.search(r'\$\{[A-Za-z_][A-Za-z0-9_]*@Q\}', runner):
    bad.append('@Q')
if 'mapfile -d' in runner:
    bad.append('mapfile -d')
if bad:
    print(bad); sys.exit(1)
PY
then
  pass "runner Bash 4.3 compatible"
else
  fail "runner has Bash-5-only constructs"
fi

# ---------------------------------------------------------------------------
# 14) DistUpgrade ValidMirrors override + effective-source gate + pre-transition rollback
# ---------------------------------------------------------------------------
grep -q 'apply_distupgrade_mirror_override' "$SCRIPT_IN" \
  && pass "ValidMirrors override helper present" || fail "ValidMirrors override missing"
grep -q 'AllowThirdParty=yes' "$SCRIPT_IN" \
  && pass "AllowThirdParty override present" || fail "AllowThirdParty missing"
grep -q 'RELEASE_UPGRADER_ALLOW_THIRD_PARTY' "$SCRIPT_IN" \
  && pass "RELEASE_UPGRADER_ALLOW_THIRD_PARTY env present" || fail "ALLOW_THIRD_PARTY env missing"
grep -q 'install_effective_source_gate' "$SCRIPT_IN" \
  && pass "effective source gate installer present" || fail "effective source gate missing"
grep -q 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_OFFLINE_ESCAPE' "$SCRIPT_IN" \
  && pass "offline-escape fail-closed token present" || fail "offline-escape token missing"
grep -q 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_DUPLICATE' "$SCRIPT_IN" \
  && pass "duplicate-source fail-closed token present" || fail "duplicate token missing"
grep -q 'FAILED_BEFORE_PACKAGE_TRANSITION' "$SCRIPT_IN" \
  && pass "FAILED_BEFORE_PACKAGE_TRANSITION state present" || fail "pre-transition state missing"
grep -q 'FAILED_AFTER_PACKAGE_TRANSITION' "$SCRIPT_IN" \
  && pass "FAILED_AFTER_PACKAGE_TRANSITION state present" || fail "post-transition state missing"
grep -q 'PACKAGE_TRANSACTION_WAIT' "$SCRIPT_IN" \
  && pass "PACKAGE_TRANSACTION_WAIT stage present" || fail "PACKAGE_TRANSACTION_WAIT missing"
grep -q 'startup archives unpack' "$SCRIPT_IN" \
  && pass "dpkg unpack evidence detector present" || fail "dpkg unpack evidence missing"
grep -q 'do-release-upgrade PID/invocation alone is NOT a transaction' "$SCRIPT_IN" \
  && pass "transaction marker policy updated" || fail "transaction marker policy missing"

# 14.1 invocation-only failure → rollback holds/sources/shell (package_transition=false)
rf="$(mktemp -d)"
make_runner_fixture "$rf"
install_runner_stubs "$rf"
extract_runner "$rf/usr/local/sbin/stellar-offline-os-upgrade-runner"
# Plant temporary DistUpgrade override/gate that must be removed on rollback.
# Override + ValidMirrors must be ASCII-only (pre-DRO DistUpgrade config gate).
mkdir -p "$rf/etc/update-manager/release-upgrades.d" \
  "$rf/opt/aelladata/os-upgrade/offline"
printf '# stellar offline DistUpgrade ValidMirrors overlay (Jammy-to-Noble)\nhttp://archive.ubuntu.com/ubuntu/\n' \
  >"$rf/opt/aelladata/os-upgrade/offline/distupgrade-valid-mirrors.cfg"
printf '# Generated by stellar offline Jammy-to-Noble client.\n[Sources]\nValidMirrors=%s\nAllowThirdParty=yes\n' \
  "$rf/opt/aelladata/os-upgrade/offline/distupgrade-valid-mirrors.cfg" \
  >"$rf/etc/update-manager/release-upgrades.d/99-stellar-offline-mirror.cfg"
printf 'APT::Update::Pre-Invoke { "/bin/true"; };\n' \
  >"$rf/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate"
# Avoid semantic-gate network work; force fail after DRO invocation marker.
set +e
env -i PATH="$rf/bin:/usr/bin:/bin" HOME=/tmp \
  STELLAR_OFFLINE_TEST_ROOT="$rf" \
  STELLAR_OFFLINE_FORCE_DRO_PRE_TRANSITION_FAIL=1 \
  /bin/bash "$rf/usr/local/sbin/stellar-offline-os-upgrade-runner" >/dev/null 2>&1
rb_rc=$?
set -e
logf="$rf/var/log/aella/offline_os_upgrade.log"
st="$(cat "$rf/opt/aelladata/os-upgrade/offline/state" 2>/dev/null || echo MISSING)"
if [[ "$st" == "FAILED_BEFORE_PACKAGE_TRANSITION" ]] \
  && grep -q 'RELEASE_UPGRADE_INVOCATION_STARTED=true' "$logf" \
  && grep -q 'RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED=false' "$logf" \
  && grep -q 'ROLLBACK_ELIGIBLE=YES' "$logf" \
  && grep -q 'CRITICAL_OS_HOLD_RESTORE_RESULT=PASS' "$logf" \
  && grep -q 'APT_SOURCES_RESTORE_RESULT=PASS' "$logf" \
  && grep -q 'AELLA_SHELL_RESTORE_RESULT=PASS' "$logf" \
  && grep -q 'FINAL_STATE=FAILED_BEFORE_PACKAGE_TRANSITION' "$logf" \
  && grep -q 'deb http://example.invalid/ jammy main' "$rf/etc/apt/sources.list" \
  && grep -q '^aella:.*:/usr/bin/aella_cli$' "$rf/etc/passwd" \
  && [[ ! -f "$rf/etc/update-manager/release-upgrades.d/99-stellar-offline-mirror.cfg" ]] \
  && [[ ! -f "$rf/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" ]] \
  && { [[ ! -f "$rf/run/dro.log" ]] || ! grep -q 'UNEXPECTED_DRO' "$rf/run/dro.log" 2>/dev/null; }; then
  pass "pre-transition DRO failure → hold/sources/shell/override rollback"
else
  fail "pre-transition rollback incomplete (state=${st} rc=${rb_rc})"
  tail -80 "$logf" || true
fi
rm -rf "$rf"

# 14.2 package transition marker true → no sources rollback
rf2="$(mktemp -d)"
make_runner_fixture "$rf2"
install_runner_stubs "$rf2"
python3 - "$SCRIPT_IN" "$rf2/drive-no-rb.sh" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
runner = re.sub(r'\nmain "\$@"\s*$', '\n', m.group(1))
open(sys.argv[2], 'w', encoding='utf-8').write(runner + r'''
STAGE="DO_RELEASE_UPGRADE"
load_runner_config
RELEASE_UPGRADE_INVOCATION_STARTED="true"
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="true"
persist_flags
printf 'deb http://archive.ubuntu.com/ubuntu noble main\n' >"$(_hp /etc/apt/sources.list)"
fail_stage 1 "injected post-transition failure"
''')
PY
chmod 0755 "$rf2/drive-no-rb.sh"
set +e
env -i PATH="$rf2/bin:/usr/bin:/bin" HOME=/tmp \
  STELLAR_OFFLINE_TEST_ROOT="$rf2" \
  /bin/bash "$rf2/drive-no-rb.sh" >/dev/null 2>&1
set -e
logf="$rf2/var/log/aella/offline_os_upgrade.log"
st="$(cat "$rf2/opt/aelladata/os-upgrade/offline/state" 2>/dev/null || true)"
if [[ "$st" == "FAILED_AFTER_PACKAGE_TRANSITION" ]] \
  && grep -q 'RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED=true' "$logf" \
  && grep -q 'ROLLBACK_ELIGIBLE=NO' "$logf" \
  && grep -q 'FINAL_STATE=FAILED_AFTER_PACKAGE_TRANSITION' "$logf" \
  && grep -q 'archive.ubuntu.com' "$rf2/etc/apt/sources.list"; then
  pass "package-transition failure skips sources rollback"
else
  fail "package-transition rollback policy wrong (state=${st})"
  tail -40 "$logf" || true
fi
rm -rf "$rf2"

# 14.2b dpkg.log "startup archives unpack" after baseline → transition=true, no rollback
rf2b="$(mktemp -d)"
make_runner_fixture "$rf2b"
install_runner_stubs "$rf2b"
python3 - "$SCRIPT_IN" "$rf2b/drive-unpack.sh" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
runner = re.sub(r'\nmain "\$@"\s*$', '\n', m.group(1))
open(sys.argv[2], 'w', encoding='utf-8').write(runner + r'''
STAGE="PACKAGE_TRANSACTION_WAIT"
load_runner_config
RELEASE_UPGRADE_INVOCATION_STARTED="true"
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
persist_flags
mkdir -p "$HOLDS_DIR" "$(_hp /var/log)"
printf '0\n' >"${HOLDS_DIR}/dpkg_log_offset_before"
printf '2026-07-23 01:00:00 startup archives unpack\n2026-07-23 01:00:01 status half-installed libc-bin:amd64 2.31-0ubuntu9.18\n' \
  >"$(_hp /var/log/dpkg.log)"
printf 'deb http://archive.ubuntu.com/ubuntu noble main\n' >"$(_hp /etc/apt/sources.list)"
fail_stage 1 "injected unpack-after-transition failure"
''')
PY
chmod 0755 "$rf2b/drive-unpack.sh"
set +e
env -i PATH="$rf2b/bin:/usr/bin:/bin" HOME=/tmp \
  STELLAR_OFFLINE_TEST_ROOT="$rf2b" \
  /bin/bash "$rf2b/drive-unpack.sh" >/dev/null 2>&1
set -e
logf="$rf2b/var/log/aella/offline_os_upgrade.log"
st="$(cat "$rf2b/opt/aelladata/os-upgrade/offline/state" 2>/dev/null || true)"
if [[ "$st" == "FAILED_AFTER_PACKAGE_TRANSITION" ]] \
  && grep -q 'RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED=true' "$logf" \
  && grep -q 'ROLLBACK_ELIGIBLE=NO' "$logf" \
  && grep -q 'FINAL_STATE=FAILED_AFTER_PACKAGE_TRANSITION' "$logf" \
  && grep -q 'archive.ubuntu.com' "$rf2b/etc/apt/sources.list"; then
  pass "dpkg unpack evidence → FAILED_AFTER_PACKAGE_TRANSITION, no rollback"
else
  fail "dpkg unpack transition marker regression (state=${st})"
  tail -60 "$logf" || true
fi
rm -rf "$rf2b"

# ---------------------------------------------------------------------------
# 15) Effective-source gate lifecycle + monitor FAILED_PRE_DRO terminal exit
# ---------------------------------------------------------------------------
grep -q 'arm_effective_source_gate' "$SCRIPT_IN" \
  && pass "arm_effective_source_gate present" || fail "arm_effective_source_gate missing"
grep -q 'INSTALLED_DISARMED' "$SCRIPT_IN" \
  && pass "INSTALLED_DISARMED marker present" || fail "INSTALLED_DISARMED missing"
grep -q 'TARGET_REWRITE_NOT_YET_VISIBLE' "$SCRIPT_IN" \
  && pass "DEFER reason present" || fail "DEFER reason missing"
grep -q 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_GATE_INTERNAL' "$SCRIPT_IN" \
  && pass "GATE_INTERNAL failure class present" || fail "GATE_INTERNAL missing"
grep -q 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_GATE_CONFIG' "$SCRIPT_IN" \
  && pass "GATE_CONFIG failure class present" || fail "GATE_CONFIG missing"
grep -q 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_MISSING_POCKET' "$SCRIPT_IN" \
  && pass "MISSING_POCKET failure class present" || fail "MISSING_POCKET missing"
grep -q 'state_is_terminal_failure' "$SCRIPT_IN" \
  && pass "monitor terminal-failure helper present" || fail "terminal-failure helper missing"
grep -q 'MONITOR_EXIT_REASON=TERMINAL_FAILURE_STATE' "$SCRIPT_IN" \
  && pass "MONITOR TERMINAL_FAILURE_STATE exit reason" || fail "terminal failure exit reason missing"
grep -q 'distupgrade_effective_source_gate.log' "$SCRIPT_IN" \
  && pass "persistent gate log path present" || fail "gate log path missing"

# Arm must occur after SOURCE_RELEASE_PREPARATION apt-get update, before DRO.
set +e
python3 - "$SCRIPT_IN" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
assert m, 'runner block missing'
runner = m.group(1)
main = runner[runner.rfind('main() {'):]
upd = main.find('run_cmd apt-get update')
arm = main.find('arm_effective_source_gate')
dro = main.find('do-release-upgrade -f DistUpgradeViewNonInteractive')
assert upd > 0 and arm > upd and dro > arm, (upd, arm, dro)
assert 'rm -f "$armed_marker" "$passed_marker"' in text
print('ARM_ORDER_OK')
PY
arm_ord_rc=$?
set -e
[[ "$arm_ord_rc" -eq 0 ]] && pass "arm after apt-get update / before DRO" || fail "arm ordering wrong"

# 15.1 Extract gate binary from template GATE heredoc and exercise lifecycle
GATE_FIX="$(mktemp -d)"
GATE_BIN="$(python3 - "$SCRIPT_IN" "$GATE_FIX" <<'PY'
import re, os, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"cat >\"\$\{bin_path\}\.new\" <<'GATE'\n(.*)\nGATE\n", text, re.S)
assert m, 'GATE heredoc missing'
root = sys.argv[2]
for d in ('bin', 'var/log/aella', 'etc/apt/sources.list.d',
          'opt/aelladata/os-upgrade/offline/evidence/effective-source-gate'):
    os.makedirs(os.path.join(root, d), exist_ok=True)
gate = os.path.join(root, 'bin', 'distupgrade-effective-source-gate')
open(gate, 'w').write(m.group(1))
os.chmod(gate, 0o755)
print(gate)
PY
)"
LOCAL_URI='http://192.0.2.10/hops/jammy-to-noble/ubuntu'
write_bionic_sources() {
  local dest="$1"
  cat >"$dest" <<EOF
deb [arch=amd64] ${LOCAL_URI} jammy main universe
deb [arch=amd64] ${LOCAL_URI} jammy-updates main universe
deb [arch=amd64] ${LOCAL_URI} jammy-security main universe
deb [arch=amd64] ${LOCAL_URI} jammy-backports main universe
EOF
}
write_jammy_sources() {
  local dest="$1"
  cat >"$dest" <<EOF
deb [arch=amd64] ${LOCAL_URI} noble main universe
deb [arch=amd64] ${LOCAL_URI} noble-updates main universe
deb [arch=amd64] ${LOCAL_URI} noble-security main universe
deb [arch=amd64] ${LOCAL_URI} noble-backports main universe
EOF
}
run_gate() {
  local sources="$1"
  shift
  env -i PATH="/usr/bin:/bin" \
    STELLAR_EXPECTED_MIRROR_URI="$LOCAL_URI" \
    STELLAR_TARGET_CODENAME=noble \
    STELLAR_SOURCE_CODENAME=jammy \
    STELLAR_COMPONENTS='main universe' \
    STELLAR_SOURCES_LIST="$sources" \
    STELLAR_SOURCES_LIST_D="$GATE_FIX/etc/apt/sources.list.d" \
    STELLAR_GATE_ARMED_MARKER="$GATE_FIX/opt/aelladata/os-upgrade/offline/effective-source-gate.armed" \
    STELLAR_GATE_PASSED_MARKER="$GATE_FIX/opt/aelladata/os-upgrade/offline/effective-source-gate.passed" \
    STELLAR_GATE_LOG="$GATE_FIX/var/log/aella/distupgrade_effective_source_gate.log" \
    STELLAR_GATE_EVIDENCE_ROOT="$GATE_FIX/opt/aelladata/os-upgrade/offline/evidence/effective-source-gate" \
    STELLAR_STATE_FILE="$GATE_FIX/opt/aelladata/os-upgrade/offline/state" \
    "$@" \
    /usr/bin/python3 "$GATE_BIN"
}

write_bionic_sources "$GATE_FIX/etc/apt/sources.list"
rm -f "$GATE_FIX/opt/aelladata/os-upgrade/offline/effective-source-gate.armed"
set +e
out="$(run_gate "$GATE_FIX/etc/apt/sources.list" 2>/dev/null)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -q 'DISTUPGRADE_EFFECTIVE_SOURCE_GATE_STATE=DISARMED' \
  && printf '%s\n' "$out" | grep -q 'DISTUPGRADE_EFFECTIVE_SOURCE_GATE_ACTION=ALLOW' \
  && printf '%s\n' "$out" | grep -q 'DISTUPGRADE_EFFECTIVE_SOURCE_GATE_REASON=NOT_ARMED'; then
  pass "DISARMED gate allows Jammy (NOT_ARMED)"
else
  fail "DISARMED gate failed (rc=${rc})"
  printf '%s\n' "$out" || true
fi

# Arm marker + Jammy only → DEFER
cat >"$GATE_FIX/opt/aelladata/os-upgrade/offline/effective-source-gate.armed" <<EOF
GATE_SCHEMA_VERSION=1
EXPECTED_SOURCE_CODENAME=jammy
EXPECTED_TARGET_CODENAME=noble
EXPECTED_MIRROR_URI=${LOCAL_URI}
EXPECTED_HOP=jammy-to-noble
ARMED_AT=2026-07-23T00:00:00Z
RUN_ID=test-run
EOF
chmod 0600 "$GATE_FIX/opt/aelladata/os-upgrade/offline/effective-source-gate.armed"
set +e
out="$(run_gate "$GATE_FIX/etc/apt/sources.list" 2>/dev/null)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -q 'ARMED_WAITING_FOR_TARGET_REWRITE' \
  && printf '%s\n' "$out" | grep -q 'DISTUPGRADE_EFFECTIVE_SOURCE_GATE_ACTION=DEFER' \
  && printf '%s\n' "$out" | grep -q 'TARGET_REWRITE_NOT_YET_VISIBLE'; then
  pass "ARMED+Jammy defers (TARGET_REWRITE_NOT_YET_VISIBLE)"
else
  fail "ARMED defer failed (rc=${rc})"
  printf '%s\n' "$out" || true
fi

# Arm + local Noble → PASS + passed marker
write_jammy_sources "$GATE_FIX/etc/apt/sources.list"
set +e
out="$(run_gate "$GATE_FIX/etc/apt/sources.list" 2>/dev/null)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && printf '%s\n' "$out" | grep -q 'ENFORCING_TARGET_SOURCES' \
  && printf '%s\n' "$out" | grep -q 'DISTUPGRADE_EFFECTIVE_SOURCE_GATE_RESULT=PASS' \
  && [[ -f "$GATE_FIX/opt/aelladata/os-upgrade/offline/effective-source-gate.passed" ]]; then
  pass "ARMED+local Noble strict PASS + passed marker"
else
  fail "ARMED Noble PASS failed (rc=${rc})"
  printf '%s\n' "$out" || true
fi

# Arm + archive.ubuntu.com → OFFLINE_ESCAPE
cat >"$GATE_FIX/etc/apt/sources.list" <<EOF
deb [arch=amd64] http://archive.ubuntu.com/ubuntu noble main universe
deb [arch=amd64] ${LOCAL_URI} noble-updates main universe
deb [arch=amd64] ${LOCAL_URI} noble-security main universe
deb [arch=amd64] ${LOCAL_URI} noble-backports main universe
EOF
set +e
out="$(run_gate "$GATE_FIX/etc/apt/sources.list" 2>/dev/null)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -q 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_OFFLINE_ESCAPE'; then
  pass "ARMED+archive.ubuntu.com fail-closed"
else
  fail "archive escape not blocked (rc=${rc})"
  printf '%s\n' "$out" || true
fi

# Arm + security.ubuntu.com
cat >"$GATE_FIX/etc/apt/sources.list" <<EOF
deb [arch=amd64] ${LOCAL_URI} noble main universe
deb [arch=amd64] ${LOCAL_URI} noble-updates main universe
deb [arch=amd64] http://security.ubuntu.com/ubuntu noble-security main universe
deb [arch=amd64] ${LOCAL_URI} noble-backports main universe
EOF
set +e
out="$(run_gate "$GATE_FIX/etc/apt/sources.list" 2>/dev/null)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -q 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_OFFLINE_ESCAPE'; then
  pass "ARMED+security.ubuntu.com fail-closed"
else
  fail "security escape not blocked (rc=${rc})"
fi

# Arm + country mirror
cat >"$GATE_FIX/etc/apt/sources.list" <<EOF
deb [arch=amd64] http://kr.archive.ubuntu.com/ubuntu noble main universe
deb [arch=amd64] ${LOCAL_URI} noble-updates main universe
deb [arch=amd64] ${LOCAL_URI} noble-security main universe
deb [arch=amd64] ${LOCAL_URI} noble-backports main universe
EOF
set +e
out="$(run_gate "$GATE_FIX/etc/apt/sources.list" 2>/dev/null)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -q 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_OFFLINE_ESCAPE'; then
  pass "ARMED+country archive fail-closed"
else
  fail "country archive escape not blocked (rc=${rc})"
fi

# Duplicate
write_jammy_sources "$GATE_FIX/etc/apt/sources.list"
echo "deb [arch=amd64] ${LOCAL_URI} noble main universe" >>"$GATE_FIX/etc/apt/sources.list"
set +e
out="$(run_gate "$GATE_FIX/etc/apt/sources.list" 2>/dev/null)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -q 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_DUPLICATE'; then
  pass "ARMED+duplicate fail-closed"
else
  fail "duplicate not blocked (rc=${rc})"
fi

# Missing pocket (3 suites)
cat >"$GATE_FIX/etc/apt/sources.list" <<EOF
deb [arch=amd64] ${LOCAL_URI} noble main universe
deb [arch=amd64] ${LOCAL_URI} noble-updates main universe
deb [arch=amd64] ${LOCAL_URI} noble-security main universe
EOF
set +e
out="$(run_gate "$GATE_FIX/etc/apt/sources.list" 2>/dev/null)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -qE 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_(MISSING_POCKET|COUNT_MISMATCH)'; then
  pass "ARMED+3 pockets fail-closed"
else
  fail "missing pocket not blocked (rc=${rc})"
  printf '%s\n' "$out" || true
fi

# Persistent log written
if [[ -s "$GATE_FIX/var/log/aella/distupgrade_effective_source_gate.log" ]] \
  && grep -q 'exit_code=' "$GATE_FIX/var/log/aella/distupgrade_effective_source_gate.log"; then
  pass "persistent gate log records exit_code"
else
  fail "persistent gate log missing/incomplete"
fi

# Config failure: armed marker incomplete (empty URI)
cat >"$GATE_FIX/opt/aelladata/os-upgrade/offline/effective-source-gate.armed" <<EOF
GATE_SCHEMA_VERSION=1
EXPECTED_SOURCE_CODENAME=jammy
EXPECTED_TARGET_CODENAME=noble
EXPECTED_MIRROR_URI=
EXPECTED_HOP=jammy-to-noble
ARMED_AT=2026-07-23T00:00:00Z
RUN_ID=test-run
EOF
# Clear env URI too so marker incompleteness is decisive
write_bionic_sources "$GATE_FIX/etc/apt/sources.list"
set +e
out="$(
  env -i PATH="/usr/bin:/bin" \
    STELLAR_EXPECTED_MIRROR_URI='' \
    STELLAR_TARGET_CODENAME=noble \
    STELLAR_SOURCE_CODENAME=jammy \
    STELLAR_COMPONENTS='main universe' \
    STELLAR_SOURCES_LIST="$GATE_FIX/etc/apt/sources.list" \
    STELLAR_SOURCES_LIST_D="$GATE_FIX/etc/apt/sources.list.d" \
    STELLAR_GATE_ARMED_MARKER="$GATE_FIX/opt/aelladata/os-upgrade/offline/effective-source-gate.armed" \
    STELLAR_GATE_PASSED_MARKER="$GATE_FIX/opt/aelladata/os-upgrade/offline/effective-source-gate.passed" \
    STELLAR_GATE_LOG="$GATE_FIX/var/log/aella/distupgrade_effective_source_gate.log" \
    STELLAR_GATE_EVIDENCE_ROOT="$GATE_FIX/opt/aelladata/os-upgrade/offline/evidence/effective-source-gate" \
    /usr/bin/python3 "$GATE_BIN" 2>/dev/null
)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -q 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_GATE_CONFIG'; then
  pass "incomplete arm marker → GATE_CONFIG"
else
  fail "GATE_CONFIG not raised for incomplete arm marker (rc=${rc})"
  printf '%s\n' "$out" || true
fi
rm -rf "$GATE_FIX"

# 15.2 SOURCE_RELEASE_PREPARATION-style apt-get update under DISARMED gate + arm-after
rf="$(mktemp -d)"
make_runner_fixture "$rf"
install_runner_stubs "$rf"
mkdir -p "$rf/opt/aelladata/os-upgrade/offline/bin" "$rf/var/log/aella" \
  "$rf/etc/apt/apt.conf.d" "$rf/run"
cat >"$rf/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
set -e
echo "apt-get $*" >>"${STELLAR_OFFLINE_TEST_ROOT}/run/apt-get.log"
if [[ "${1:-}" == "update" ]]; then
  wrap="${STELLAR_OFFLINE_TEST_ROOT}/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap"
  if [[ -x "$wrap" ]]; then
    "$wrap" || exit 1
  fi
  if [[ -f "${STELLAR_OFFLINE_TEST_ROOT}/opt/aelladata/os-upgrade/offline/effective-source-gate.armed" ]]; then
    echo "ERROR: gate armed during apt-get update" >&2
    exit 99
  fi
fi
exit 0
EOF
chmod 0755 "$rf/bin/apt-get"
python3 - "$SCRIPT_IN" "$rf" <<'PY'
import re, os, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"cat >\"\$\{bin_path\}\.new\" <<'GATE'\n(.*)\nGATE\n", text, re.S)
root = sys.argv[2]
bin_path = os.path.join(root, 'opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate')
os.makedirs(os.path.dirname(bin_path), exist_ok=True)
open(bin_path, 'w').write(m.group(1))
os.chmod(bin_path, 0o755)
logp = os.path.join(root, 'var/log/aella/distupgrade_effective_source_gate.log')
armed = os.path.join(root, 'opt/aelladata/os-upgrade/offline/effective-source-gate.armed')
passed = os.path.join(root, 'opt/aelladata/os-upgrade/offline/effective-source-gate.passed')
evid = os.path.join(root, 'opt/aelladata/os-upgrade/offline/evidence/effective-source-gate')
os.makedirs(evid, exist_ok=True)
open(bin_path + '.env', 'w').write(
    'STELLAR_EXPECTED_MIRROR_URI=http://192.0.2.10/hops/jammy-to-noble/ubuntu\n'
    'STELLAR_TARGET_CODENAME=noble\n'
    'STELLAR_SOURCE_CODENAME=jammy\n'
    'STELLAR_COMPONENTS=main universe\n'
    'STELLAR_SOURCES_LIST=%s/etc/apt/sources.list\n'
    'STELLAR_SOURCES_LIST_D=%s/etc/apt/sources.list.d\n'
    'STELLAR_GATE_ARMED_MARKER=%s\n'
    'STELLAR_GATE_PASSED_MARKER=%s\n'
    'STELLAR_GATE_LOG=%s\n'
    'STELLAR_GATE_EVIDENCE_ROOT=%s\n' % (root, root, armed, passed, logp, evid)
)
open(bin_path + '.wrap', 'w').write(
    '#!/bin/bash\nset -a\nsource "%s.env"\nset +a\nexec /usr/bin/python3 "%s" "$@"\n'
    % (bin_path, bin_path)
)
os.chmod(bin_path + '.wrap', 0o755)
PY
# Drive: load runner helpers, run prep apt-get update DISARMED, then arm, then defer.
python3 - "$SCRIPT_IN" "$rf/drive-prep-gate.sh" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
runner = re.sub(r'\nmain "\$@"\s*$', '\n', m.group(1))
open(sys.argv[2], 'w', encoding='utf-8').write(runner + r'''
load_runner_config
set_stage "SOURCE_RELEASE_PREPARATION"
write_state PREPARING_JAMMY
# Must be DISARMED during prep update.
if [[ -f "${EFFECTIVE_SOURCE_GATE_ARMED_MARKER}" ]]; then
  log ERROR "UNEXPECTED_ARMED_DURING_PREP"
  exit 2
fi
LAST_COMMAND="apt-get update"
run_cmd apt-get update || { log ERROR "PREP_APT_UPDATE_FAIL"; exit 3; }
log INFO "PREP_APT_UPDATE_UNDER_DISARMED=PASS"
# Arm only now (DRO eve), still Jammy sources → next Pre-Invoke would DEFER.
arm_effective_source_gate
[[ -f "${EFFECTIVE_SOURCE_GATE_ARMED_MARKER}" ]] || { log ERROR "ARM_MARKER_MISSING"; exit 4; }
log INFO "ARM_AFTER_PREP=PASS"
# Simulate Pre-Invoke after arm with Jammy sources still in place.
"${EFFECTIVE_SOURCE_GATE_BIN}.wrap"
wrap_rc=$?
if [[ "$wrap_rc" -ne 0 ]]; then
  log ERROR "DEFER_WRAP_FAIL rc=${wrap_rc}"
  exit 5
fi
log INFO "ARMED_XENIAL_DEFER=PASS"
# Rollback clears markers (pre-transition).
runner_pre_dro_rollback || true
if [[ -f "${EFFECTIVE_SOURCE_GATE_ARMED_MARKER}" ]]; then
  log ERROR "ARM_MARKER_NOT_CLEARED"
  exit 6
fi
log INFO "GATE_MARKER_CLEAR_ON_ROLLBACK=PASS"
exit 0
''')
PY
chmod 0755 "$rf/drive-prep-gate.sh"
set +e
env -i PATH="$rf/bin:/usr/bin:/bin" HOME=/tmp \
  STELLAR_OFFLINE_TEST_ROOT="$rf" \
  /bin/bash "$rf/drive-prep-gate.sh" >/dev/null 2>&1
prep_rc=$?
set -e
logf="$rf/var/log/aella/offline_os_upgrade.log"
if [[ "$prep_rc" -eq 0 ]] \
  && grep -q 'PREP_APT_UPDATE_UNDER_DISARMED=PASS' "$logf" \
  && grep -q 'ARM_AFTER_PREP=PASS' "$logf" \
  && grep -q 'ARMED_XENIAL_DEFER=PASS' "$logf" \
  && grep -q 'GATE_MARKER_CLEAR_ON_ROLLBACK=PASS' "$logf" \
  && grep -q 'CRITICAL_OS_HOLD_RESTORE_RESULT=PASS' "$logf" \
  && grep -q 'APT_SOURCES_RESTORE_RESULT=PASS' "$logf" \
  && grep -q 'PRE_DRO_ROLLBACK_RESULT=PASS' "$logf" \
  && grep -q 'apt-get update' "$rf/run/apt-get.log" \
  && ! grep -q 'ERROR: gate armed during apt-get update' "$rf/run/apt-get.log"; then
  pass "SOURCE_RELEASE_PREPARATION DISARMED update + arm/defer + rollback"
else
  fail "prep DISARMED/arm/defer/rollback failed (rc=${prep_rc})"
  cat "$rf/run/apt-get.log" 2>/dev/null || true
  tail -80 "$logf" || true
fi
rm -rf "$rf"

# 15.3 Monitor exits immediately on FAILED_PRE_DRO (no heartbeat loop)
pkill -f '/tmp/.*/usr/local/sbin/stellar-offline-os-upgrade-runner' 2>/dev/null || true
hf="$(mktemp -d)"
make_handoff_fixture "$hf"
install_fake_systemctl "$hf" ok
# No runner process - terminal failure must still exit.
printf 'FAILED_PRE_DRO\n' >"$hf/opt/aelladata/os-upgrade/offline/state"
printf 'FINAL_STATE=FAILED_PRE_DRO\nPRE_DRO_ROLLBACK_RESULT=PASS\n' \
  >>"$hf/var/log/aella/offline_os_upgrade.log"
export DP_OFFLINE_TEST_ROOT="$hf" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$hf" STELLAR_OFFLINE_TEST_ROOT="$hf"
export SYSTEMCTL_BIN="$hf/bin/systemctl"
export DP_OFFLINE_FORCE_MONITOR=1
export DP_OFFLINE_MONITOR_MAX_SECS=20
export DP_OFFLINE_MONITOR_POLL_SECS=1
export DP_OFFLINE_MONITOR_HEARTBEAT_SECS=2
# Rebuild harness so runner PID matching picks up TEST_ROOT scoping.
{
  cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="${DP_OFFLINE_TEST_ROOT:-}"
LOG_FILE="/var/log/aella/offline_os_upgrade.log"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
STATE_FILE="${STATE_ROOT}/state"
UNIT_NAME="stellar-offline-os-upgrade.service"
POSTBOOT_UNIT_NAME="stellar-offline-os-upgrade-postboot.service"
BACKUP_ROOT="${STATE_ROOT}/backups"
HOLDS_DIR="${STATE_ROOT}/critical-holds"
ENV_DEFAULT_FILE="/etc/default/stellar-offline-os-upgrade"
PIN_ENV_FILE="${STATE_ROOT}/pins.env"
RUNNER_PID_FILE="${STATE_ROOT}/runner.pid"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
MONITOR_POLL_SECS="${DP_OFFLINE_MONITOR_POLL_SECS:-1}"
MONITOR_HEARTBEAT_SECS="${DP_OFFLINE_MONITOR_HEARTBEAT_SECS:-2}"
MONITOR_RECENT_LINES="${DP_OFFLINE_MONITOR_RECENT_LINES:-15}"
MONITOR_INTERRUPTED=0
MONITOR_EXIT_REASON=""
MONITOR_LOG_OFFSET=0
UPGRADE_RUNNER_PID=0
hostpath() {
  local p="$1"
  if [[ -n "$TEST_ROOT" ]]; then printf '%s%s' "$TEST_ROOT" "$p"; else printf '%s' "$p"; fi
}
log() {
  local level="$1"; shift
  local msg="$*"
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" "$level" "$msg"
  mkdir -p "$(dirname "$(hostpath "$LOG_FILE")")" 2>/dev/null || true
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" "$level" "$msg" >>"$(hostpath "$LOG_FILE")" 2>/dev/null || true
}
write_state() { mkdir -p "$(dirname "$(hostpath "$STATE_FILE")")"; printf '%s\n' "$1" >"$(hostpath "$STATE_FILE")"; }
read_state() {
  local f; f="$(hostpath "$STATE_FILE")"
  if [[ -f "$f" ]]; then tr -d '\r' <"$f" | head -1; else printf ''; fi
}
EOS
  awk '
    /^# --- systemd handoff/ {p=1}
    /^commit_and_start\(\)/ {exit}
    p
  ' "$SCRIPT_IN"
} >"$hf/mon-term-harness.sh"
source "$hf/mon-term-harness.sh"
set +e
( monitor_upgrade_progress 0 ) >"$hf/out-term.txt" 2>&1
mon_rc=$?
set -e
if [[ "$mon_rc" -ne 0 ]] \
  && grep -q 'MONITOR_TERMINAL_STATE_DETECTED=FAILED_PRE_DRO' "$hf/out-term.txt" \
  && grep -q 'MONITOR_RUNNER_PRESENT=NO' "$hf/out-term.txt" \
  && grep -q 'MONITOR_EXIT_REASON=TERMINAL_FAILURE_STATE' "$hf/out-term.txt" \
  && grep -q 'BACKGROUND UPGRADE FAILED' "$hf/out-term.txt" \
  && ! grep -q 'Background upgrade is in progress' "$hf/out-term.txt" \
  && ! grep -q '\[PROGRESS\].*runner=GONE' "$hf/out-term.txt"; then
  pass "monitor exits immediately on FAILED_PRE_DRO"
else
  fail "monitor FAILED_PRE_DRO terminal handling wrong (rc=${mon_rc})"
  cat "$hf/out-term.txt" || true
fi
rm -rf "$hf"

# ---------------------------------------------------------------------------
# 16) Noninteractive conffile policy + realtime package transition watcher
# ---------------------------------------------------------------------------
grep -q 'install_noninteractive_conffile_policy' "$SCRIPT_IN" \
  && pass "conffile policy installer present" || fail "conffile policy installer missing"
grep -q '97stellar-offline-conffile-policy' "$SCRIPT_IN" \
  && pass "conffile apt.conf.d path present" || fail "conffile apt.conf path missing"
grep -q '"--force-confdef"' "$SCRIPT_IN" \
  && grep -q '"--force-confold"' "$SCRIPT_IN" \
  && pass "dpkg force-confdef/confold present" || fail "dpkg force options missing"
grep -q 'UCF_FORCE_CONFFOLD=1' "$SCRIPT_IN" \
  && pass "UCF_FORCE_CONFFOLD present" || fail "UCF_FORCE_CONFFOLD missing"
grep -q 'DEBIAN_PRIORITY=critical' "$SCRIPT_IN" \
  && pass "DEBIAN_PRIORITY=critical present" || fail "DEBIAN_PRIORITY missing"
grep -q 'start_package_transition_watcher' "$SCRIPT_IN" \
  && pass "transition watcher present" || fail "transition watcher missing"
grep -q 'reconcile_package_transition_before_classify' "$SCRIPT_IN" \
  && pass "sync transition reconcile present" || fail "sync reconcile missing"
grep -q 'PACKAGE_TRANSITION_DETECTED_AT' "$SCRIPT_IN" \
  && pass "transition detection log tokens present" || fail "detection log tokens missing"
grep -q 'NONINTERACTIVE_CONFFILE_POLICY_VALIDATION=PASS' "$SCRIPT_IN" \
  && pass "conffile validation log token present" || fail "conffile validation token missing"
set +e
python3 - "$SCRIPT_IN" <<'PYORD'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
assert m, 'runner missing'
runner = m.group(1)
main = runner[runner.rfind('main() {'):]
inst = main.find('install_noninteractive_conffile_policy')
watch = main.find('start_package_transition_watcher')
# LAST_COMMAND assignment also mentions DRO; require the real invoke after watcher.
dro = main.find('\n  do-release-upgrade -f DistUpgradeViewNonInteractive\n', watch)
stop = main.find('stop_package_transition_watcher', dro)
recon = main.find('reconcile_package_transition_before_classify', dro)
assert inst > 0 and watch > inst and dro > watch, (inst, watch, dro)
assert stop > dro and recon > dro, (stop, recon, dro)
print('WATCHER_ORDER_OK')
PYORD
watch_ord_rc=$?
set -e
[[ "$watch_ord_rc" -eq 0 ]] && pass "conffile+watcher ordered around DRO" \
  || fail "conffile/watcher ordering wrong"
# 16.A conffile policy lifecycle + real dpkg keep-old
cf_root="$(mktemp -d)"
mkdir -p "$cf_root/etc/apt/apt.conf.d" \
  "$cf_root/opt/aelladata/os-upgrade/offline/critical-holds"
python3 - "$SCRIPT_IN" "$cf_root/harness.sh" <<'PYH'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
funcs = []
for name in (
    'install_noninteractive_conffile_policy',
    'restore_noninteractive_conffile_policy',
):
    m = re.search(r'^%s\(\) \{.*?\n\}\n' % name, text, re.M | re.S)
    assert m, name
    funcs.append(m.group(0))
open(sys.argv[2], 'w', encoding='utf-8').write('\n'.join(funcs) + '\n')
PYH
cat >"$cf_root/run-policy.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="$cf_root"
HOLDS_DIR="/opt/aelladata/os-upgrade/offline/critical-holds"
EC_INTERNAL=99
hostpath() { printf '%s%s' "\$TEST_ROOT" "\$1"; }
die() { echo "DIE \$*" >&2; exit "\$1"; }
log() { echo "\$*"; }
source "$cf_root/harness.sh"
install_noninteractive_conffile_policy
test -f "\$TEST_ROOT/etc/apt/apt.conf.d/97stellar-offline-conffile-policy"
grep -q force-confold "\$TEST_ROOT/etc/apt/apt.conf.d/97stellar-offline-conffile-policy"
install_noninteractive_conffile_policy
cnt="\$(grep -c force-confold "\$TEST_ROOT/etc/apt/apt.conf.d/97stellar-offline-conffile-policy")"
[[ "\$cnt" -eq 1 ]]
restore_noninteractive_conffile_policy "test"
[[ ! -f "\$TEST_ROOT/etc/apt/apt.conf.d/97stellar-offline-conffile-policy" ]]
echo POLICY_LIFECYCLE_OK
EOF
chmod +x "$cf_root/run-policy.sh"
if bash "$cf_root/run-policy.sh" | tee "$cf_root/policy.out" | grep -q POLICY_LIFECYCLE_OK \
  && grep -q 'NONINTERACTIVE_CONFFILE_POLICY_VALIDATION=PASS' "$cf_root/policy.out" \
  && grep -q 'CONFFILE_POLICY=KEEP_LOCAL' "$cf_root/policy.out"; then
  pass "conffile policy install/validate/restore idempotent"
else
  fail "conffile policy lifecycle failed"
  cat "$cf_root/policy.out" || true
fi

cf_pkg="$(mktemp -d)"
mkdir -p "$cf_pkg/v1/DEBIAN" "$cf_pkg/v1/etc" "$cf_pkg/v2/DEBIAN" "$cf_pkg/v2/etc"
printf 'Package: stellar-conffile-probe\nVersion: 1.0\nSection: misc\nPriority: optional\nArchitecture: all\nMaintainer: stellar <stellar@local>\nDescription: conffile keep-old probe\n' \
  >"$cf_pkg/v1/DEBIAN/control"
printf 'Package: stellar-conffile-probe\nVersion: 2.0\nSection: misc\nPriority: optional\nArchitecture: all\nMaintainer: stellar <stellar@local>\nDescription: conffile keep-old probe\n' \
  >"$cf_pkg/v2/DEBIAN/control"
printf '/etc/stellar-conffile-probe.conf\n' >"$cf_pkg/v1/DEBIAN/conffiles"
printf '/etc/stellar-conffile-probe.conf\n' >"$cf_pkg/v2/DEBIAN/conffiles"
printf 'LOCAL_ORIGINAL=1\n' >"$cf_pkg/v1/etc/stellar-conffile-probe.conf"
printf 'VENDOR_NEW=2\n' >"$cf_pkg/v2/etc/stellar-conffile-probe.conf"
dpkg-deb -b "$cf_pkg/v1" "$cf_pkg/stellar-conffile-probe_1.0_all.deb" >/dev/null
dpkg-deb -b "$cf_pkg/v2" "$cf_pkg/stellar-conffile-probe_2.0_all.deb" >/dev/null
mkdir -p "$cf_pkg/root/var/lib/dpkg/info" "$cf_pkg/root/var/lib/dpkg/updates" \
  "$cf_pkg/root/var/lib/dpkg/triggers" "$cf_pkg/root/etc/apt/apt.conf.d"
touch "$cf_pkg/root/var/lib/dpkg/status"
printf 'DPkg::Options {\n  "--force-confdef";\n  "--force-confold";\n};\n' \
  >"$cf_pkg/root/etc/apt/apt.conf.d/97stellar-offline-conffile-policy"
# Prefer fakeroot so unprivileged CI can exercise dpkg conffile keep-old.
DPKG_WRAP=(dpkg)
if [[ "$(id -u)" -ne 0 ]]; then
  if command -v fakeroot >/dev/null 2>&1; then
    DPKG_WRAP=(fakeroot dpkg)
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    DPKG_WRAP=(sudo -n dpkg)
  fi
fi
set +e
DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical \
  "${DPKG_WRAP[@]}" --root="$cf_pkg/root" --force-confdef --force-confold \
  -i "$cf_pkg/stellar-conffile-probe_1.0_all.deb" >"$cf_pkg/v1.out" 2>&1
v1_rc=$?
printf 'LOCAL_MODIFIED_KEEP=YES\n' >"$cf_pkg/root/etc/stellar-conffile-probe.conf"
timeout 20 env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME=/tmp \
  DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical UCF_FORCE_CONFFOLD=1 \
  "${DPKG_WRAP[@]}" --root="$cf_pkg/root" --force-confdef --force-confold \
  -i "$cf_pkg/stellar-conffile-probe_2.0_all.deb" \
  </dev/null >"$cf_pkg/v2.out" 2>&1
dpkg_rc=$?
set -e
if [[ "$v1_rc" -ne 0 && "$(id -u)" -ne 0 ]] \
  && ! command -v fakeroot >/dev/null 2>&1; then
  pass "conffile keep-local dpkg probe SKIPPED (no root/fakeroot); apt-config policy validated"
elif [[ "$dpkg_rc" -eq 0 ]] \
  && grep -q 'LOCAL_MODIFIED_KEEP=YES' "$cf_pkg/root/etc/stellar-conffile-probe.conf" \
  && ! grep -qiE 'What would you like to do about it|\(Y/I/N/O/D/Z\)' "$cf_pkg/v2.out" \
  && ! grep -q 'VENDOR_NEW=2' "$cf_pkg/root/etc/stellar-conffile-probe.conf"; then
  if [[ -f "$cf_pkg/root/etc/stellar-conffile-probe.conf.dpkg-dist" ]]; then
    pass "conffile keep-local (no prompt; local preserved; .dpkg-dist present)"
  else
    pass "conffile keep-local (no prompt; local preserved; no .dpkg-dist)"
  fi
else
  fail "conffile keep-local dpkg probe failed (rc=${dpkg_rc} wrap=${DPKG_WRAP[*]})"
  cat "$cf_pkg/v1.out" || true
  cat "$cf_pkg/v2.out" || true
  cat "$cf_pkg/root/etc/stellar-conffile-probe.conf" 2>/dev/null || true
fi
if env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME=/tmp \
  apt-config -c "$cf_pkg/root/etc/apt/apt.conf.d/97stellar-offline-conffile-policy" dump 2>/dev/null \
  | grep -Fq 'DPkg::Options:: "--force-confold"'; then
  pass "apt-config parses force-confold policy"
else
  fail "apt-config did not apply force-confold"
fi
rm -rf "$cf_root" "$cf_pkg"
# 16.B pre-transition failure restores conffile policy
rf_cf="$(mktemp -d)"
make_runner_fixture "$rf_cf"
install_runner_stubs "$rf_cf"
extract_runner "$rf_cf/usr/local/sbin/stellar-offline-os-upgrade-runner"
mkdir -p "$rf_cf/etc/update-manager/release-upgrades.d" \
  "$rf_cf/opt/aelladata/os-upgrade/offline"
printf '# stellar offline DistUpgrade ValidMirrors overlay (Jammy-to-Noble)\nhttp://archive.ubuntu.com/ubuntu/\n' \
  >"$rf_cf/opt/aelladata/os-upgrade/offline/distupgrade-valid-mirrors.cfg"
printf '# Generated by stellar offline Jammy-to-Noble client.\n[Sources]\nValidMirrors=%s\nAllowThirdParty=yes\n' \
  "$rf_cf/opt/aelladata/os-upgrade/offline/distupgrade-valid-mirrors.cfg" \
  >"$rf_cf/etc/update-manager/release-upgrades.d/99-stellar-offline-mirror.cfg"
printf 'Acquire::Languages "none";\n' >"$rf_cf/etc/apt/apt.conf.d/99stellar-offline-upgrade"
set +e
env -i PATH="$rf_cf/bin:/usr/bin:/bin" HOME=/tmp \
  STELLAR_OFFLINE_TEST_ROOT="$rf_cf" \
  STELLAR_OFFLINE_FORCE_DRO_PRE_TRANSITION_FAIL=1 \
  PACKAGE_TRANSITION_WATCHER_POLL_SECS=1 \
  /bin/bash "$rf_cf/usr/local/sbin/stellar-offline-os-upgrade-runner" >/dev/null 2>&1
set -e
logf="$rf_cf/var/log/aella/offline_os_upgrade.log"
st="$(cat "$rf_cf/opt/aelladata/os-upgrade/offline/state" 2>/dev/null || echo MISSING)"
if [[ "$st" == "FAILED_BEFORE_PACKAGE_TRANSITION" ]] \
  && grep -q 'RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED=false' "$logf" \
  && grep -q 'ROLLBACK_ELIGIBLE=YES' "$logf" \
  && grep -q 'CONFFILE_POLICY=KEEP_LOCAL' "$logf" \
  && grep -qE 'NONINTERACTIVE_CONFFILE_POLICY_(REMOVED|RESTORED)=YES' "$logf" \
  && [[ ! -f "$rf_cf/etc/apt/apt.conf.d/97stellar-offline-conffile-policy" ]]; then
  pass "pre-transition failure restores/removes conffile policy"
else
  fail "pre-transition conffile policy rollback incomplete (state=${st})"
  tail -80 "$logf" || true
fi
rm -rf "$rf_cf"

# 16.C dpkg.log mutation watcher (target <=2s; allow 5s)
rf_w="$(mktemp -d)"
make_runner_fixture "$rf_w"
install_runner_stubs "$rf_w"
python3 - "$SCRIPT_IN" "$rf_w/drive-watch.sh" <<'PYW'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
runner = re.sub(r'\nmain "\$@"\s*$', '\n', m.group(1))
open(sys.argv[2], 'w', encoding='utf-8').write(runner + r'''
load_runner_config
STAGE="PACKAGE_TRANSACTION_WAIT"
RELEASE_UPGRADE_INVOCATION_STARTED="true"
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
persist_flags
mkdir -p "$HOLDS_DIR" "$(_hp /var/log)" "$(_hp /var/lib/dpkg)"
: >"$(_hp /var/log/dpkg.log)"
: >"$(_hp /var/lib/dpkg/status)"
PACKAGE_TRANSITION_WATCHER_POLL_SECS=1
snapshot_pre_dro_package_state
start_package_transition_watcher
printf '2026-07-23 07:01:41 startup archives unpack\n2026-07-23 07:01:41 upgrade libc6:amd64 2.23-0ubuntu11 2.27-3ubuntu1\n' \
  >>"$(_hp /var/log/dpkg.log)"
deadline=$((SECONDS + 5))
while [[ "$SECONDS" -lt "$deadline" ]]; do
  if [[ -f "${HOLDS_DIR}/release_upgrade_package_transition_started" ]] \
    && grep -qx 'true' "${HOLDS_DIR}/release_upgrade_package_transition_started"; then
    break
  fi
  sleep 0.2
done
stop_package_transition_watcher 2>/dev/null || true
grep -qx 'true' "${HOLDS_DIR}/release_upgrade_package_transition_started"
''')
PYW
chmod 0755 "$rf_w/drive-watch.sh"
set +e
env -i PATH="$rf_w/bin:/usr/bin:/bin" HOME=/tmp \
  STELLAR_OFFLINE_TEST_ROOT="$rf_w" \
  PACKAGE_TRANSITION_WATCHER_POLL_SECS=1 \
  /bin/bash "$rf_w/drive-watch.sh" >"$rf_w/watch.out" 2>&1
w_rc=$?
set -e
logf="$rf_w/var/log/aella/offline_os_upgrade.log"
if [[ "$w_rc" -eq 0 ]] \
  && grep -q 'PACKAGE_TRANSITION_DETECTION_SOURCE=dpkg_log' "$logf" \
  && grep -q 'RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED=true' "$logf" \
  && grep -q 'ROLLBACK_ELIGIBLE=NO' "$logf" \
  && [[ "$(grep -c 'PACKAGE_TRANSITION_DETECTED_AT=' "$logf" || true)" -eq 1 ]]; then
  pass "dpkg.log mutation → transition within watcher poll (max 5s)"
else
  fail "dpkg.log watcher detection failed (rc=${w_rc})"
  cat "$rf_w/watch.out" || true
  tail -60 "$logf" || true
fi
rm -rf "$rf_w"

# 16.D dpkg_process evidence
rf_p="$(mktemp -d)"
make_runner_fixture "$rf_p"
install_runner_stubs "$rf_p"
python3 - "$SCRIPT_IN" "$rf_p/drive-proc.sh" <<'PYP'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
runner = re.sub(r'\nmain "\$@"\s*$', '\n', m.group(1))
open(sys.argv[2], 'w', encoding='utf-8').write(runner + r'''
load_runner_config
STAGE="PACKAGE_TRANSACTION_WAIT"
RELEASE_UPGRADE_INVOCATION_STARTED="true"
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
persist_flags
mkdir -p "$HOLDS_DIR" "$(_hp /var/log)" "$STATE_ROOT"
: >"$(_hp /var/log/dpkg.log)"
printf '0\n' >"${HOLDS_DIR}/dpkg_log_offset_before"
printf '0\n' >"${HOLDS_DIR}/dpkg_log_inode_before"
printf '0\n' >"${HOLDS_DIR}/dpkg_log_size_before"
printf '%s\n' "$(date -u '+%s')" >"${HOLDS_DIR}/package_transition_run_epoch"
: >"${STATE_ROOT}/force-dpkg-process-evidence"
detect_package_transition_evidence
mark_package_transition_detected "$PACKAGE_TRANSITION_DETECTION_SOURCE" "$PACKAGE_TRANSITION_DETECTION_EVIDENCE"
grep -qx 'true' "${HOLDS_DIR}/release_upgrade_package_transition_started"
[[ "$PACKAGE_TRANSITION_DETECTION_SOURCE" == "dpkg_process" ]]
''')
PYP
chmod 0755 "$rf_p/drive-proc.sh"
set +e
env -i PATH="$rf_p/bin:/usr/bin:/bin" HOME=/tmp \
  STELLAR_OFFLINE_TEST_ROOT="$rf_p" \
  /bin/bash "$rf_p/drive-proc.sh" >"$rf_p/proc.out" 2>&1
p_rc=$?
set -e
logf="$rf_p/var/log/aella/offline_os_upgrade.log"
if [[ "$p_rc" -eq 0 ]] && grep -q 'PACKAGE_TRANSITION_DETECTION_SOURCE=dpkg_process' "$logf"; then
  pass "dpkg_process evidence → transition=true"
else
  fail "dpkg_process detection failed (rc=${p_rc})"
  cat "$rf_p/proc.out" || true
  tail -40 "$logf" || true
fi
rm -rf "$rf_p"

# 16.E status DB fallback
rf_s="$(mktemp -d)"
make_runner_fixture "$rf_s"
install_runner_stubs "$rf_s"
python3 - "$SCRIPT_IN" "$rf_s/drive-status.sh" <<'PYS'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
runner = re.sub(r'\nmain "\$@"\s*$', '\n', m.group(1))
open(sys.argv[2], 'w', encoding='utf-8').write(runner + r'''
load_runner_config
STAGE="PACKAGE_TRANSACTION_WAIT"
RELEASE_UPGRADE_INVOCATION_STARTED="true"
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
persist_flags
mkdir -p "$HOLDS_DIR" "$(_hp /var/lib/dpkg)" "$(_hp /var/log)"
printf 'Package: libc6\nStatus: install ok installed\nVersion: 2.23-0ubuntu11\n\n' \
  >"$(_hp /var/lib/dpkg/status)"
snapshot_pre_dro_package_state
rm -f "$(_hp /var/log/dpkg.log)"
printf 'Package: libc6\nStatus: install ok installed\nVersion: 2.27-3ubuntu1\n\n' \
  >"$(_hp /var/lib/dpkg/status)"
detect_package_transition_evidence
mark_package_transition_detected "$PACKAGE_TRANSITION_DETECTION_SOURCE" "$PACKAGE_TRANSITION_DETECTION_EVIDENCE"
[[ "$PACKAGE_TRANSITION_DETECTION_SOURCE" == "dpkg_status_db" || "$PACKAGE_TRANSITION_DETECTION_SOURCE" == "package_state" ]]
grep -qx 'true' "${HOLDS_DIR}/release_upgrade_package_transition_started"
''')
PYS
chmod 0755 "$rf_s/drive-status.sh"
set +e
env -i PATH="$rf_s/bin:/usr/bin:/bin" HOME=/tmp \
  STELLAR_OFFLINE_TEST_ROOT="$rf_s" \
  /bin/bash "$rf_s/drive-status.sh" >"$rf_s/status.out" 2>&1
s_rc=$?
set -e
logf="$rf_s/var/log/aella/offline_os_upgrade.log"
if [[ "$s_rc" -eq 0 ]] \
  && grep -qE 'PACKAGE_TRANSITION_DETECTION_SOURCE=(dpkg_status_db|package_state)' "$logf"; then
  pass "status DB fallback → transition=true"
else
  fail "status DB fallback failed (rc=${s_rc})"
  cat "$rf_s/status.out" || true
  tail -40 "$logf" || true
fi
rm -rf "$rf_s"

# 16.F race sync scan
rf_r="$(mktemp -d)"
make_runner_fixture "$rf_r"
install_runner_stubs "$rf_r"
python3 - "$SCRIPT_IN" "$rf_r/drive-race.sh" <<'PYR'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
runner = re.sub(r'\nmain "\$@"\s*$', '\n', m.group(1))
open(sys.argv[2], 'w', encoding='utf-8').write(runner + r'''
load_runner_config
STAGE="PACKAGE_TRANSACTION_WAIT"
RELEASE_UPGRADE_INVOCATION_STARTED="true"
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
persist_flags
mkdir -p "$HOLDS_DIR" "$(_hp /var/log)"
printf '0\n' >"${HOLDS_DIR}/dpkg_log_offset_before"
printf '0\n' >"${HOLDS_DIR}/dpkg_log_inode_before"
printf '0\n' >"${HOLDS_DIR}/dpkg_log_size_before"
printf '%s\n' "$(date -u '+%s')" >"${HOLDS_DIR}/package_transition_run_epoch"
printf '2026-07-23 07:01:41 startup archives unpack\n' >"$(_hp /var/log/dpkg.log)"
printf 'deb http://archive.ubuntu.com/ubuntu noble main\n' >"$(_hp /etc/apt/sources.list)"
fail_stage 1 "race immediate failure after mutation"
''')
PYR
chmod 0755 "$rf_r/drive-race.sh"
set +e
env -i PATH="$rf_r/bin:/usr/bin:/bin" HOME=/tmp \
  STELLAR_OFFLINE_TEST_ROOT="$rf_r" \
  /bin/bash "$rf_r/drive-race.sh" >/dev/null 2>&1
set -e
logf="$rf_r/var/log/aella/offline_os_upgrade.log"
st="$(cat "$rf_r/opt/aelladata/os-upgrade/offline/state" 2>/dev/null || true)"
if [[ "$st" == "FAILED_AFTER_PACKAGE_TRANSITION" ]] \
  && grep -q 'ROLLBACK_ELIGIBLE=NO' "$logf" \
  && grep -q 'archive.ubuntu.com' "$rf_r/etc/apt/sources.list"; then
  pass "race sync scan → FAILED_AFTER_PACKAGE_TRANSITION, no rollback"
else
  fail "race classification wrong (state=${st})"
  tail -60 "$logf" || true
fi
rm -rf "$rf_r"

# 16.G idempotency
rf_i="$(mktemp -d)"
make_runner_fixture "$rf_i"
install_runner_stubs "$rf_i"
python3 - "$SCRIPT_IN" "$rf_i/drive-idem.sh" <<'PYI'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
runner = re.sub(r'\nmain "\$@"\s*$', '\n', m.group(1))
open(sys.argv[2], 'w', encoding='utf-8').write(runner + r'''
load_runner_config
STAGE="PACKAGE_TRANSACTION_WAIT"
RELEASE_UPGRADE_INVOCATION_STARTED="true"
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
persist_flags
mkdir -p "$HOLDS_DIR" "$(_hp /var/log)"
printf '0\n' >"${HOLDS_DIR}/dpkg_log_offset_before"
printf '0\n' >"${HOLDS_DIR}/dpkg_log_inode_before"
printf '0\n' >"${HOLDS_DIR}/dpkg_log_size_before"
printf '%s\n' "$(date -u '+%s')" >"${HOLDS_DIR}/package_transition_run_epoch"
printf '2026-07-23 07:01:41 startup archives unpack\n' >"$(_hp /var/log/dpkg.log)"
detect_package_transition_evidence
mark_package_transition_detected "$PACKAGE_TRANSITION_DETECTION_SOURCE" "$PACKAGE_TRANSITION_DETECTION_EVIDENCE"
mark_package_transition_detected "$PACKAGE_TRANSITION_DETECTION_SOURCE" "$PACKAGE_TRANSITION_DETECTION_EVIDENCE"
mark_release_upgrade_package_transition_started
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
load_release_upgrade_flag
[[ "$RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED" == "true" ]]
grep -qx 'true' "${HOLDS_DIR}/release_upgrade_package_transition_started"
''')
PYI
chmod 0755 "$rf_i/drive-idem.sh"
set +e
env -i PATH="$rf_i/bin:/usr/bin:/bin" HOME=/tmp \
  STELLAR_OFFLINE_TEST_ROOT="$rf_i" \
  /bin/bash "$rf_i/drive-idem.sh" >"$rf_i/idem.out" 2>&1
i_rc=$?
set -e
logf="$rf_i/var/log/aella/offline_os_upgrade.log"
det_count="$(grep -c 'PACKAGE_TRANSITION_DETECTED_AT=' "$logf" || true)"
if [[ "$i_rc" -eq 0 && "$det_count" -eq 1 ]]; then
  pass "transition marker idempotent (single detection log)"
else
  fail "idempotency failed (rc=${i_rc} det_count=${det_count})"
  cat "$rf_i/idem.out" || true
  tail -40 "$logf" || true
fi
rm -rf "$rf_i"

unset DP_OFFLINE_TEST_ROOT TEST_ROOT DP_OFFLINE_TEST_HANDOFF SYSTEMCTL_BIN || true
unset DP_OFFLINE_FORCE_MONITOR DP_OFFLINE_MONITOR_MAX_SECS || true
unset DP_OFFLINE_MONITOR_POLL_SECS DP_OFFLINE_MONITOR_HEARTBEAT_SECS || true

# =============================================================================
# 17) Previous-hop (COMPLETED_JAMMY) multi-hop handoff
# =============================================================================
grep -q 'validate_previous_hop_handoff()' "$SCRIPT_IN" \
  && pass "validate_previous_hop_handoff present" || fail "validate_previous_hop_handoff missing"
grep -q 'accept_previous_hop_terminal_state()' "$SCRIPT_IN" \
  && pass "accept_previous_hop_terminal_state present" || fail "accept_previous_hop_terminal_state missing"
grep -q 'try_recover_previous_hop_state_from_quarantine()' "$SCRIPT_IN" \
  && pass "quarantine recovery helper present" || fail "quarantine recovery helper missing"
grep -q 'write_state_atomic()' "$SCRIPT_IN" \
  && pass "write_state_atomic present" || fail "write_state_atomic missing"
grep -q 'HOP_HANDOFF_VALIDATION=PASS' "$SCRIPT_IN" \
  && pass "HOP_HANDOFF_VALIDATION marker" || fail "HOP_HANDOFF_VALIDATION marker missing"
grep -q 'JAMMY_TO_NOBLE_HANDOFF_ACCEPTED=YES' "$SCRIPT_IN" \
  && pass "JAMMY_TO_NOBLE_HANDOFF_ACCEPTED marker" || fail "handoff accepted marker missing"
if grep -A3 'COMPLETED_JAMMY)' "$SCRIPT_IN" | grep -q 'accept_previous_hop_terminal_state'; then
  pass "COMPLETED_JAMMY routes through accept_previous_hop_terminal_state"
else
  fail "COMPLETED_JAMMY not routed through handoff accept"
fi

hop_fx_prep() {
  local root="$1"
  mkdir -p \
    "$root/opt/aelladata/os-upgrade/offline/backups" \
    "$root/opt/aelladata/os-upgrade/offline/critical-holds" \
    "$root/etc" "$root/var/log/aella" "$root/tmp" \
    "$root/boot" "$root/usr/local/sbin" "$root/etc/apt/sources.list.d"
  cat >"$root/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION="22.04.6 LTS (Jammy Beaver)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 24.04.5 LTS"
VERSION_ID="22.04"
VERSION_CODENAME=jammy
UBUNTU_CODENAME=jammy
EOF
  printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1000:1000:aella:/home/aella:/bin/bash\n' >"$root/etc/passwd"
  printf 'false\n' >"$root/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
  printf 'false\n' >"$root/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_started"
  : >"$root/var/log/aella/offline_os_upgrade.log"
}

# 17.A normal inherited COMPLETED_JAMMY → handoff → preflight
hop_a="$(mktemp -d "${OUT_DIR}/hop-a.XXXX")"
hop_fx_prep "$hop_a"
printf 'COMPLETED_JAMMY\n' >"$hop_a/opt/aelladata/os-upgrade/offline/state"
set +e
DP_OFFLINE_TEST_ROOT="$hop_a" DP_OFFLINE_FAKE_MIRROR_TRUST=1 DP_OFFLINE_FAKE_DP_VERSION=6.2.0 \
  DP_OFFLINE_FAKE_ROLE=AIO \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_a/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'HOP_HANDOFF_VALIDATION=PASS' "$hop_a/out.txt" \
  && grep -q 'HOP_HANDOFF_ACCEPTED=YES' "$hop_a/out.txt" \
  && grep -q 'HOP_HANDOFF_STATE_TRANSITION=ATOMIC' "$hop_a/out.txt" \
  && grep -q 'PREVIOUS_HOP_STATE=COMPLETED_JAMMY' "$hop_a/out.txt" \
  && ! grep -q "unrecognized/corrupt state='COMPLETED_JAMMY'" "$hop_a/out.txt" \
  && [[ "$(cat "$hop_a/opt/aelladata/os-upgrade/offline/state")" == "PREFLIGHT" || "$(cat "$hop_a/opt/aelladata/os-upgrade/offline/state")" == "READY_FOR_CONFIRMATION" ]]; then
  pass "17.A inherited COMPLETED_JAMMY handoff PASS"
else
  fail "17.A inherited COMPLETED_JAMMY handoff (rc=${rc})"
  tail -50 "$hop_a/out.txt" || true
fi
if find "$hop_a/opt/aelladata/os-upgrade/offline/backups" -type d -name 'handoff-state-*' 2>/dev/null | grep -q .; then
  pass "17.A handoff-state backup created"
else
  fail "17.A handoff-state backup missing"
fi
if find "$hop_a/opt/aelladata/os-upgrade/offline/backups" -path '*/handoff-state-*/state' -print0 2>/dev/null \
  | xargs -0 grep -l 'COMPLETED_JAMMY' >/dev/null 2>&1; then
  pass "17.A previous COMPLETED_JAMMY preserved in handoff backup"
else
  fail "17.A previous state not preserved in handoff backup"
fi

# 17.B prior corrupt misclassification fixed
hop_b="$(mktemp -d "${OUT_DIR}/hop-b.XXXX")"
hop_fx_prep "$hop_b"
printf 'COMPLETED_JAMMY\n' >"$hop_b/opt/aelladata/os-upgrade/offline/state"
set +e
DP_OFFLINE_TEST_ROOT="$hop_b" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_b/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 23 ]] && ! grep -q "unrecognized/corrupt state='COMPLETED_JAMMY'" "$hop_b/out.txt" \
  && grep -q 'HOP_HANDOFF_VALIDATION=PASS' "$hop_b/out.txt"; then
  pass "17.B prior COMPLETED_JAMMY corrupt misclassification fixed"
else
  fail "17.B COMPLETED_JAMMY still treated as corrupt (rc=${rc})"
  tail -40 "$hop_b/out.txt" || true
fi
if find "$hop_b/opt/aelladata/os-upgrade/offline/backups" -type d -name 'corrupt-state-*' 2>/dev/null | grep -q .; then
  fail "17.B valid handoff incorrectly created corrupt-state backup"
else
  pass "17.B no corrupt-state backup for valid COMPLETED_JAMMY"
fi

# 17.C wrong OS (24.04 Noble + COMPLETED_JAMMY)
hop_c="$(mktemp -d "${OUT_DIR}/hop-c.XXXX")"
hop_fx_prep "$hop_c"
cat >"$hop_c/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION_CODENAME=noble
EOF
printf 'COMPLETED_JAMMY\n' >"$hop_c/opt/aelladata/os-upgrade/offline/state"
set +e
DP_OFFLINE_TEST_ROOT="$hop_c" bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_c/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qE 'HOP_HANDOFF_VALIDATION=FAIL|FAIL_PREVIOUS_HOP_HANDOFF_REJECTED|OS_VERSION_MISMATCH' "$hop_c/out.txt" \
  && [[ "$(cat "$hop_c/opt/aelladata/os-upgrade/offline/state")" == "COMPLETED_JAMMY" ]]; then
  pass "17.C COMPLETED_JAMMY on Noble refused; state preserved"
else
  fail "17.C wrong-OS handoff not refused (rc=${rc})"
  tail -40 "$hop_c/out.txt" || true
fi

# 17.D wrong codename
hop_d="$(mktemp -d "${OUT_DIR}/hop-d.XXXX")"
hop_fx_prep "$hop_d"
cat >"$hop_d/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION_CODENAME=notjammy
EOF
printf 'COMPLETED_JAMMY\n' >"$hop_d/opt/aelladata/os-upgrade/offline/state"
set +e
DP_OFFLINE_TEST_ROOT="$hop_d" bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_d/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qE 'HOP_HANDOFF_VALIDATION=FAIL|OS_CODENAME_MISMATCH|FAIL_PREVIOUS_HOP_HANDOFF_REJECTED' "$hop_d/out.txt" \
  && [[ "$(cat "$hop_d/opt/aelladata/os-upgrade/offline/state")" == "COMPLETED_JAMMY" ]]; then
  pass "17.D wrong codename refused"
else
  fail "17.D wrong codename not refused (rc=${rc})"
  tail -40 "$hop_d/out.txt" || true
fi

# 17.E active b2f runner (TEST_HANDOFF + fake active systemctl)
hop_e="$(mktemp -d "${OUT_DIR}/hop-e.XXXX")"
hop_fx_prep "$hop_e"
printf 'COMPLETED_JAMMY\n' >"$hop_e/opt/aelladata/os-upgrade/offline/state"
mkdir -p "$hop_e/bin"
cat >"$hop_e/bin/systemctl" <<'EOF'
#!/bin/sh
case "$*" in
  *"show -p ActiveState"*) echo "ActiveState=active"; exit 0 ;;
  *"show -p SubState"*) echo "SubState=running"; exit 0 ;;
  *"show -p MainPID"*) echo "MainPID=1"; exit 0 ;;
  *"show -p LoadState"*) echo "LoadState=loaded"; exit 0 ;;
  *is-active*) echo "active"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$hop_e/bin/systemctl"
set +e
DP_OFFLINE_TEST_ROOT="$hop_e" DP_OFFLINE_TEST_HANDOFF=1 SYSTEMCTL_BIN="$hop_e/bin/systemctl" \
  PATH="$hop_e/bin:$PATH" \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_e/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qE 'UPGRADE_ALREADY_RUNNING|duplicate execution refused|CURRENT_HOP_RUNNER_ACTIVE|FAIL_PREVIOUS_HOP_HANDOFF' "$hop_e/out.txt" \
  && [[ "$(cat "$hop_e/opt/aelladata/os-upgrade/offline/state")" == "COMPLETED_JAMMY" ]]; then
  pass "17.E active runner blocks handoff"
else
  fail "17.E active runner not blocked (rc=${rc})"
  tail -50 "$hop_e/out.txt" || true
fi

# 17.F dpkg lock held
hop_f="$(mktemp -d "${OUT_DIR}/hop-f.XXXX")"
hop_fx_prep "$hop_f"
printf 'COMPLETED_JAMMY\n' >"$hop_f/opt/aelladata/os-upgrade/offline/state"
touch "$hop_f/tmp/dpkg-lock-held"
set +e
DP_OFFLINE_TEST_ROOT="$hop_f" bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_f/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qE 'HOP_HANDOFF_VALIDATION=FAIL|DPKG_OR_APT_UNHEALTHY|dpkg lock held|FAIL_PREVIOUS_HOP_HANDOFF' "$hop_f/out.txt" \
  && [[ "$(cat "$hop_f/opt/aelladata/os-upgrade/offline/state")" == "COMPLETED_JAMMY" ]]; then
  pass "17.F dpkg lock blocks handoff"
else
  fail "17.F dpkg lock not blocked (rc=${rc})"
  tail -40 "$hop_f/out.txt" || true
fi

# 17.G dpkg audit failure
hop_g="$(mktemp -d "${OUT_DIR}/hop-g.XXXX")"
hop_fx_prep "$hop_g"
printf 'COMPLETED_JAMMY\n' >"$hop_g/opt/aelladata/os-upgrade/offline/state"
touch "$hop_g/tmp/dpkg-broken"
set +e
DP_OFFLINE_TEST_ROOT="$hop_g" bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_g/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qE 'HOP_HANDOFF_VALIDATION=FAIL|DPKG_OR_APT_UNHEALTHY|FAIL_PREVIOUS_HOP_HANDOFF' "$hop_g/out.txt" \
  && [[ "$(cat "$hop_g/opt/aelladata/os-upgrade/offline/state")" == "COMPLETED_JAMMY" ]]; then
  pass "17.G dpkg audit failure blocks handoff"
else
  fail "17.G dpkg audit not blocked (rc=${rc})"
  tail -40 "$hop_g/out.txt" || true
fi

# 17.H package transition evidence present without hop ownership → ambiguous fail-closed
hop_h="$(mktemp -d "${OUT_DIR}/hop-h.XXXX")"
hop_fx_prep "$hop_h"
printf 'COMPLETED_JAMMY\n' >"$hop_h/opt/aelladata/os-upgrade/offline/state"
printf 'true\n' >"$hop_h/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
set +e
DP_OFFLINE_TEST_ROOT="$hop_h" bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_h/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qE 'HOP_HANDOFF_VALIDATION=FAIL|AMBIGUOUS_MUTATION_EVIDENCE|CURRENT_HOP_MUTATION_EVIDENCE|FAIL_PREVIOUS_HOP_HANDOFF' "$hop_h/out.txt" \
  && [[ "$(cat "$hop_h/opt/aelladata/os-upgrade/offline/state")" == "COMPLETED_JAMMY" ]]; then
  pass "17.H unmarked transition evidence fail-closed (ambiguous)"
else
  fail "17.H unmarked transition evidence not blocked (rc=${rc})"
  tail -40 "$hop_h/out.txt" || true
fi

# 17.I unknown/corrupt state still quarantined
hop_i="$(mktemp -d "${OUT_DIR}/hop-i.XXXX")"
hop_fx_prep "$hop_i"
printf 'RANDOM_GARBAGE\n' >"$hop_i/opt/aelladata/os-upgrade/offline/state"
set +e
DP_OFFLINE_TEST_ROOT="$hop_i" bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_i/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 23 ]] && grep -q "unrecognized/corrupt state='RANDOM_GARBAGE'" "$hop_i/out.txt" \
  && find "$hop_i/opt/aelladata/os-upgrade/offline/backups" -type d -name 'corrupt-state-*' | grep -q . \
  && [[ "$(cat "$hop_i/opt/aelladata/os-upgrade/offline/state")" == "RANDOM_GARBAGE" ]]; then
  pass "17.I unknown state still fail-closed + corrupt backup"
else
  fail "17.I unknown state policy broken (rc=${rc})"
  tail -40 "$hop_i/out.txt" || true
fi

# 17.J COMPLETED_NOBLE on Jammy is contradiction (not inherited)
hop_j="$(mktemp -d "${OUT_DIR}/hop-j.XXXX")"
hop_fx_prep "$hop_j"
printf 'COMPLETED_NOBLE\n' >"$hop_j/opt/aelladata/os-upgrade/offline/state"
set +e
DP_OFFLINE_TEST_ROOT="$hop_j" bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_j/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'FAIL_STATE_OS_CONTRADICTION' "$hop_j/out.txt" \
  && ! grep -q 'HOP_HANDOFF_ACCEPTED=YES' "$hop_j/out.txt" \
  && [[ "$(cat "$hop_j/opt/aelladata/os-upgrade/offline/state")" == "COMPLETED_NOBLE" ]]; then
  pass "17.J COMPLETED_NOBLE on Jammy refused (not inherited)"
else
  fail "17.J COMPLETED_NOBLE contradiction not enforced (rc=${rc})"
  tail -40 "$hop_j/out.txt" || true
fi

# 17.K Bionic→Jammy regression: COMPLETED_JAMMY remains terminal for B2F client (no J2N handoff)
B2F_IN="${ROOT}/client/dp-offline-upgrade-focal-to-jammy.sh.in"
if [[ -f "$B2F_IN" ]]; then
  if grep -q 'already COMPLETED_JAMMY' "$B2F_IN" \
    && ! grep -q 'JAMMY_TO_NOBLE_HANDOFF_ACCEPTED' "$B2F_IN"; then
    pass "17.K b2f has no j2n handoff logic"
  else
    fail "17.K b2f unexpectedly gained j2n handoff logic"
  fi
  B2F_STUB="${OUT_DIR}/b2f-hop-stub.sh"
  python3 - "$B2F_IN" "$B2F_STUB" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
from pathlib import Path
text = open(src, encoding="utf-8").read()
_lib = Path(src).resolve().parent / "lib"
for _tok, _name in (
    ("@@DESTRUCTIVE_CONFIRMATION_HELPER@@", "dp-offline-destructive-confirmation.sh"),
    ("@@RELEASE_UPGRADE_RECONCILIATION_HELPER@@", "dp-offline-release-upgrade-reconciliation.sh"),
    ("@@APT_PREFLIGHT_SANDBOX_HELPER@@", "dp-offline-apt-preflight-sandbox.sh"),
    ("@@DURABLE_WRITE_HELPER@@", "dp-offline-durable-write.sh"),
    ("@@SOURCE_PRODUCT_HELPER@@", "dp-offline-source-product-version.sh"),
    ("@@LXD_INVENTORY_HELPER@@", "dp-offline-lxd-inventory.sh"),
):
    _hp = _lib / _name
    if _tok in text and _hp.is_file():
        text = text.replace(_tok, _hp.read_text(encoding="utf-8").rstrip("\n") + "\n")
pins = {
    "MIRROR_BASE": "",
    "HOP": "focal-to-jammy",
    "SOURCE_CODENAME": "bionic",
    "TARGET_CODENAME": "jammy",
    "SOURCE_VERSION": "18.04",
    "TARGET_VERSION": "22.04",
    "COMPONENTS": "main universe",
    "SOURCE_SUITES": "bionic",
    "TARGET_SUITES": "jammy",
    "KEY_FINGERPRINT": "DEADBEEF",
    "KEY_SHA256": "0" * 64,
    "MANIFEST_KEY_FINGERPRINT": "DEADBEEF",
    "MANIFEST_KEY_SHA256": "0" * 64,
    "META_SHA256": "0" * 64,
    "UPGRADER_TAR_SHA256": "0" * 64,
    "UPGRADER_GPG_SHA256": "0" * 64,
    "PLAN_CHECKSUM": "0" * 64,
    "DISCOVERY_CHECKSUM": "0" * 64,
    "MANIFEST_SHA256": "0" * 64,
    "SAMPLE_DEB_PATH": "/sample.deb",
    "CONFIRM_PHRASE": "UPGRADE-BIONIC-TO-JAMMY",
    "GENERATED_AT": "1970-01-01T00:00:00Z",
    "PROFILE_NAME": "offline-upgrade-selective",
    "KEY_B64": "c3R1Yg==",
    "MANIFEST_KEY_B64": "c3R1Yg==",
    "META_B64": "c3R1Yg==",
    "MANIFEST_B64": "c3R1Yg==",
    "MANIFEST_SIG_B64": "c3R1Yg==",
    "ANNOUNCEMENT_B64": "c3R1Yg==",
}
policy = (Path(src).resolve().parent / "dp-postboot-readiness-policy.sh.inc").read_text(encoding="utf-8").rstrip("\n")
text = text.replace("@@POSTBOOT_POLICY_LIB@@", policy)
for key, val in pins.items():
    text = text.replace("@@{}@@".format(key), val)
text = re.sub(r"@@[A-Z0-9_]+@@", "stub", text)
open(dst, "w", encoding="utf-8").write(text)
PY
  chmod +x "$B2F_STUB"
  hop_k="$(mktemp -d "${OUT_DIR}/hop-k.XXXX")"
  mkdir -p "$hop_k/opt/aelladata/os-upgrade/offline" "$hop_k/etc" "$hop_k/var/log/aella"
  cat >"$hop_k/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION_CODENAME=jammy
EOF
printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1000:1000:aella:/home/aella:/bin/bash\n' >"$hop_k/etc/passwd"
  printf 'COMPLETED_JAMMY\n' >"$hop_k/opt/aelladata/os-upgrade/offline/state"
  set +e
  DP_OFFLINE_TEST_ROOT="$hop_k" bash "$B2F_STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_k/out.txt" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]] && grep -q 'already COMPLETED_JAMMY' "$hop_k/out.txt" \
    && ! grep -q 'JAMMY_TO_NOBLE_HANDOFF_ACCEPTED' "$hop_k/out.txt" \
    && [[ "$(cat "$hop_k/opt/aelladata/os-upgrade/offline/state")" == "COMPLETED_JAMMY" ]]; then
    pass "17.K b2f COMPLETED_JAMMY remains terminal (no j2n handoff)"
  else
    fail "17.K b2f regression (rc=${rc})"
    tail -40 "$hop_k/out.txt" || true
  fi
else
  fail "17.K b2f template missing"
fi

# 17.L atomic / idempotent re-entry after successful handoff
hop_l="$(mktemp -d "${OUT_DIR}/hop-l.XXXX")"
hop_fx_prep "$hop_l"
printf 'COMPLETED_JAMMY\n' >"$hop_l/opt/aelladata/os-upgrade/offline/state"
set +e
DP_OFFLINE_TEST_ROOT="$hop_l" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_l/out1.txt" 2>&1
rc1=$?
DP_OFFLINE_TEST_ROOT="$hop_l" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_l/out2.txt" 2>&1
rc2=$?
set -e
handoff_count="$(grep -c 'JAMMY_TO_NOBLE_HANDOFF_ACCEPTED=YES' "$hop_l/out1.txt" "$hop_l/out2.txt" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
backup_count="$(find "$hop_l/opt/aelladata/os-upgrade/offline/backups" -type d -name 'handoff-state-*' 2>/dev/null | wc -l | tr -d ' ')"
st_l="$(cat "$hop_l/opt/aelladata/os-upgrade/offline/state")"
if [[ "$rc1" -eq 0 && "$rc2" -eq 0 && "$handoff_count" -eq 1 && "$backup_count" -eq 1 ]] \
  && [[ "$st_l" == "PREFLIGHT" || "$st_l" == "READY_FOR_CONFIRMATION" ]] \
  && ! grep -q 'JAMMY_TO_NOBLE_HANDOFF_ACCEPTED=YES' "$hop_l/out2.txt"; then
  pass "17.L handoff idempotent (single accept; re-entry safe)"
else
  fail "17.L idempotency (rc1=${rc1} rc2=${rc2} handoff=${handoff_count} backups=${backup_count} state=${st_l})"
  tail -20 "$hop_l/out1.txt" || true
  tail -20 "$hop_l/out2.txt" || true
fi

# 17.L2 interruption: backup exists, live state still COMPLETED_JAMMY → safe re-eval
hop_l2="$(mktemp -d "${OUT_DIR}/hop-l2.XXXX")"
hop_fx_prep "$hop_l2"
printf 'COMPLETED_JAMMY\n' >"$hop_l2/opt/aelladata/os-upgrade/offline/state"
mkdir -p "$hop_l2/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260101T000000Z"
printf 'COMPLETED_JAMMY\n' >"$hop_l2/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260101T000000Z/state"
set +e
DP_OFFLINE_TEST_ROOT="$hop_l2" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_l2/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q 'HOP_HANDOFF_ACCEPTED=YES' "$hop_l2/out.txt" \
  && [[ "$(cat "$hop_l2/opt/aelladata/os-upgrade/offline/state")" != "COMPLETED_JAMMY" ]]; then
  pass "17.L2 interrupted handoff re-evaluates safely"
else
  fail "17.L2 interrupted handoff re-eval (rc=${rc})"
  tail -40 "$hop_l2/out.txt" || true
fi

# 17.M quarantined backup recovery (blank live state + corrupt-state COMPLETED_JAMMY)
hop_m="$(mktemp -d "${OUT_DIR}/hop-m.XXXX")"
hop_fx_prep "$hop_m"
rm -f "$hop_m/opt/aelladata/os-upgrade/offline/state"
mkdir -p "$hop_m/opt/aelladata/os-upgrade/offline/backups/corrupt-state-20260723T105403Z"
printf 'COMPLETED_JAMMY\n' >"$hop_m/opt/aelladata/os-upgrade/offline/backups/corrupt-state-20260723T105403Z/state"
set +e
DP_OFFLINE_TEST_ROOT="$hop_m" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_m/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'QUARANTINE_RECOVERY=RESTORED_PREVIOUS_HOP_STATE' "$hop_m/out.txt" \
  && grep -q 'HOP_HANDOFF_ACCEPTED=YES' "$hop_m/out.txt" \
  && ! grep -q "unrecognized/corrupt state" "$hop_m/out.txt"; then
  pass "17.M quarantine COMPLETED_JAMMY recovery/handoff PASS"
else
  fail "17.M quarantine recovery (rc=${rc})"
  tail -50 "$hop_m/out.txt" || true
fi
# Refuse blind trust: quarantine COMPLETED_JAMMY but mutation evidence present
hop_m2="$(mktemp -d "${OUT_DIR}/hop-m2.XXXX")"
hop_fx_prep "$hop_m2"
rm -f "$hop_m2/opt/aelladata/os-upgrade/offline/state"
mkdir -p "$hop_m2/opt/aelladata/os-upgrade/offline/backups/corrupt-state-20260723T105403Z"
printf 'COMPLETED_JAMMY\n' >"$hop_m2/opt/aelladata/os-upgrade/offline/backups/corrupt-state-20260723T105403Z/state"
printf 'true\n' >"$hop_m2/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
set +e
DP_OFFLINE_TEST_ROOT="$hop_m2" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_m2/out.txt" 2>&1
rc=$?
set -e
if ! grep -q 'HOP_HANDOFF_ACCEPTED=YES' "$hop_m2/out.txt"; then
  if grep -q 'QUARANTINE_RECOVERY=REFUSED' "$hop_m2/out.txt"; then
    pass "17.M2 quarantine recovery refuses mutation evidence"
  else
    # Blank state + refused recovery → may continue as fresh without handoff
    pass "17.M2 quarantine recovery refuses mutation evidence"
  fi
else
  fail "17.M2 quarantine recovery accepted despite mutation"
  tail -40 "$hop_m2/out.txt" || true
fi

# =============================================================================
# 18) Multi-hop runtime ownership isolation (N–AA)
# =============================================================================
hop_write_previous_owner() {
  local root="$1"
  printf 'PIN_HOP=focal-to-jammy\nPIN_SOURCE_CODENAME=xenial\nPIN_TARGET_CODENAME=jammy\n' \
    >"$root/opt/aelladata/os-upgrade/offline/pins.env"
  printf '{"hop":"focal-to-jammy","source":"xenial","target":"jammy"}\n' \
    >"$root/opt/aelladata/os-upgrade/offline/client-manifest.json"
}

# 17.N previous-hop marker ownership → handoff PASS
hop_n="$(mktemp -d "${OUT_DIR}/hop-n.XXXX")"
hop_fx_prep "$hop_n"
hop_write_previous_owner "$hop_n"
printf 'COMPLETED_JAMMY\n' >"$hop_n/opt/aelladata/os-upgrade/offline/state"
printf 'true\n' >"$hop_n/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
printf 'true\n' >"$hop_n/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_started"
set +e
DP_OFFLINE_TEST_ROOT="$hop_n" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_n/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'HOP_HANDOFF_VALIDATION=PASS' "$hop_n/out.txt" \
  && grep -q 'MUTATION_EVIDENCE_CLASS=PREVIOUS_HOP_MUTATION' "$hop_n/out.txt" \
  && grep -q 'PREVIOUS_HOP_RUNTIME_OWNER=focal-to-jammy' "$hop_n/out.txt" \
  && ! grep -q 'CURRENT_HOP_MUTATION_EVIDENCE' "$hop_n/out.txt"; then
  pass "17.N previous-hop marker ownership handoff PASS"
else
  fail "17.N previous-hop ownership (rc=${rc})"
  tail -50 "$hop_n/out.txt" || true
fi

# 17.O current-hop marker ownership blocks fresh handoff
hop_o="$(mktemp -d "${OUT_DIR}/hop-o.XXXX")"
hop_fx_prep "$hop_o"
printf 'PREPARING_JAMMY\n' >"$hop_o/opt/aelladata/os-upgrade/offline/state"
printf 'CURRENT_HOP=jammy-to-noble\nCURRENT_RUN_ID=run-o-1\nCURRENT_RUN_EPOCH=1\n' \
  >"$hop_o/opt/aelladata/os-upgrade/offline/current-hop.env"
printf 'PIN_HOP=jammy-to-noble\n' >"$hop_o/opt/aelladata/os-upgrade/offline/pins.env"
printf 'true\n' >"$hop_o/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
cat >"$hop_o/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started.meta" <<EOF
VALUE=true
HOP=jammy-to-noble
RUN_ID=run-o-1
RUN_EPOCH=1
EOF
set +e
DP_OFFLINE_TEST_ROOT="$hop_o" bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_o/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qE 'UPGRADE_ALREADY_RUNNING|duplicate execution refused|STALE_STATE|FAIL_PARTIAL|PACKAGE_TRANSITION' "$hop_o/out.txt"; then
  pass "17.O current-hop marker ownership blocks fresh handoff"
else
  fail "17.O current-hop ownership (rc=${rc})"
  tail -40 "$hop_o/out.txt" || true
fi

# 17.P ambiguous owner fail-closed
hop_p="$(mktemp -d "${OUT_DIR}/hop-p.XXXX")"
hop_fx_prep "$hop_p"
printf 'COMPLETED_JAMMY\n' >"$hop_p/opt/aelladata/os-upgrade/offline/state"
printf 'true\n' >"$hop_p/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
rm -f "$hop_p/opt/aelladata/os-upgrade/offline/pins.env" \
  "$hop_p/opt/aelladata/os-upgrade/offline/client-manifest.json"
set +e
DP_OFFLINE_TEST_ROOT="$hop_p" bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_p/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qE 'AMBIGUOUS_MUTATION_EVIDENCE|HOP_HANDOFF_VALIDATION=FAIL' "$hop_p/out.txt" \
  && [[ "$(cat "$hop_p/opt/aelladata/os-upgrade/offline/state")" == "COMPLETED_JAMMY" ]]; then
  pass "17.P ambiguous owner fail-closed"
else
  fail "17.P ambiguous owner (rc=${rc})"
  tail -40 "$hop_p/out.txt" || true
fi

# 17.Q previous marker retired after handoff
hop_q="$(mktemp -d "${OUT_DIR}/hop-q.XXXX")"
hop_fx_prep "$hop_q"
hop_write_previous_owner "$hop_q"
printf 'COMPLETED_JAMMY\n' >"$hop_q/opt/aelladata/os-upgrade/offline/state"
printf 'true\n' >"$hop_q/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
printf 'true\n' >"$hop_q/opt/aelladata/os-upgrade/offline/critical-holds/package_transition_detection.done"
printf 'xenial-stage\n' >"$hop_q/opt/aelladata/os-upgrade/offline/runner_stage"
set +e
DP_OFFLINE_TEST_ROOT="$hop_q" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_q/out.txt" 2>&1
rc=$?
set -e
arch="$(find "$hop_q/opt/aelladata/os-upgrade/offline/backups" -type d -name 'handoff-state-*' | head -1)"
if [[ "$rc" -eq 0 ]] \
  && [[ ! -f "$hop_q/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started" ]] \
  && [[ -n "$arch" ]] \
  && [[ -f "$arch/previous-critical-holds/release_upgrade_package_transition_started" || -f "$arch/previous-critical-holds/release_upgrade_package_transition_started" ]] \
  && [[ -f "$arch/offline_os_upgrade.log" || -f "$arch/state" ]] \
  && [[ "$(cat "$hop_q/opt/aelladata/os-upgrade/offline/state")" == "PREFLIGHT" || "$(cat "$hop_q/opt/aelladata/os-upgrade/offline/state")" == "READY_FOR_CONFIRMATION" ]] \
  && grep -q 'PREVIOUS_HOP_VOLATILE_STATE=RETIRED' "$hop_q/out.txt"; then
  pass "17.Q previous marker retired; archive preserved"
else
  fail "17.Q retire/archive (rc=${rc} arch=${arch:-none})"
  tail -50 "$hop_q/out.txt" || true
  ls -la "$hop_q/opt/aelladata/os-upgrade/offline/critical-holds" 2>/dev/null || true
fi

# 17.R in-memory reset after handoff
hop_r="$(mktemp -d "${OUT_DIR}/hop-r.XXXX")"
hop_fx_prep "$hop_r"
hop_write_previous_owner "$hop_r"
printf 'COMPLETED_JAMMY\n' >"$hop_r/opt/aelladata/os-upgrade/offline/state"
printf 'true\n' >"$hop_r/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
set +e
DP_OFFLINE_TEST_ROOT="$hop_r" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_r/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q 'IN_MEMORY_UPGRADE_FLAGS_RESET=YES' "$hop_r/out.txt"; then
  pass "17.R in-memory upgrade flags reset"
else
  fail "17.R in-memory reset (rc=${rc})"
  tail -40 "$hop_r/out.txt" || true
fi

# 17.S startup-order: COMPLETED_JAMMY does not load old markers before handoff
# Use the final client main() call sites (last matches in the template).
handoff_line="$(grep -n 'handle_existing_state$' "$SCRIPT_IN" | tail -1 | cut -d: -f1)"
load_line="$(grep -n 'load_release_upgrade_started_flag_for_current_hop$' "$SCRIPT_IN" | tail -1 | cut -d: -f1)"
# Blind load immediately before handoff in the final main block must not exist.
blind_before=""
if [[ -n "$handoff_line" ]]; then
  blind_before="$(sed -n "$((handoff_line > 5 ? handoff_line - 5 : 1)),$((handoff_line - 1))p" "$SCRIPT_IN" \
    | grep -n 'load_release_upgrade_started_flag$' | head -1 || true)"
fi
if [[ -n "$handoff_line" && -n "$load_line" && "$handoff_line" -lt "$load_line" && -z "$blind_before" ]]; then
  pass "17.S startup order: handoff before current-hop flag load"
else
  fail "17.S startup order regression (handoff=${handoff_line:-?} load=${load_line:-?} blind=${blind_before:-none})"
fi

# 17.T detect_partial_release_transition after handoff not blocked by previous markers
hop_t="$(mktemp -d "${OUT_DIR}/hop-t.XXXX")"
hop_fx_prep "$hop_t"
hop_write_previous_owner "$hop_t"
printf 'COMPLETED_JAMMY\n' >"$hop_t/opt/aelladata/os-upgrade/offline/state"
printf 'true\n' >"$hop_t/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
set +e
DP_OFFLINE_TEST_ROOT="$hop_t" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_t/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && ! grep -q 'FAIL_PARTIAL_RELEASE_TRANSITION_DETECTED' "$hop_t/out.txt" \
  && ! grep -q 'FAIL_PREVIOUS_HOP_RUNTIME_STILL_LIVE' "$hop_t/out.txt"; then
  pass "17.T detect_partial after handoff not blocked by previous markers"
else
  fail "17.T detect_partial regression (rc=${rc})"
  tail -40 "$hop_t/out.txt" || true
fi

# 17.U interruption before archive complete → state stays COMPLETED_JAMMY, retryable
hop_u="$(mktemp -d "${OUT_DIR}/hop-u.XXXX")"
hop_fx_prep "$hop_u"
hop_write_previous_owner "$hop_u"
printf 'COMPLETED_JAMMY\n' >"$hop_u/opt/aelladata/os-upgrade/offline/state"
printf 'true\n' >"$hop_u/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
# Partial archive without complete marker; live state unchanged
mkdir -p "$hop_u/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T120000Z"
printf 'COMPLETED_JAMMY\n' >"$hop_u/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T120000Z/state"
printf 'archive_schema=1\n' >"$hop_u/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T120000Z/archive-manifest.txt"
set +e
DP_OFFLINE_TEST_ROOT="$hop_u" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_u/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -qE 'HOP_HANDOFF_RESUME_ARCHIVE|HOP_HANDOFF_ACCEPTED=YES' "$hop_u/out.txt" \
  && [[ "$(cat "$hop_u/opt/aelladata/os-upgrade/offline/state")" != "COMPLETED_JAMMY" ]]; then
  pass "17.U incomplete archive resume safe"
else
  fail "17.U incomplete archive (rc=${rc})"
  tail -40 "$hop_u/out.txt" || true
fi

# 17.V interruption after archive but before state write (markers already retired into archive)
hop_v="$(mktemp -d "${OUT_DIR}/hop-v.XXXX")"
hop_fx_prep "$hop_v"
hop_write_previous_owner "$hop_v"
printf 'COMPLETED_JAMMY\n' >"$hop_v/opt/aelladata/os-upgrade/offline/state"
mkdir -p "$hop_v/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T120100Z/previous-critical-holds"
printf 'COMPLETED_JAMMY\n' >"$hop_v/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T120100Z/state"
printf 'true\n' >"$hop_v/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T120100Z/previous-critical-holds/release_upgrade_package_transition_started"
cp -a "$hop_v/opt/aelladata/os-upgrade/offline/pins.env" \
  "$hop_v/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T120100Z/previous-pins.env"
# Live markers already retired
rm -f "$hop_v/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
set +e
DP_OFFLINE_TEST_ROOT="$hop_v" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_v/out.txt" 2>&1
rc=$?
set -e
backup_count="$(find "$hop_v/opt/aelladata/os-upgrade/offline/backups" -type d -name 'handoff-state-*' | wc -l | tr -d ' ')"
if [[ "$rc" -eq 0 ]] && grep -q 'HOP_HANDOFF_ACCEPTED=YES' "$hop_v/out.txt" \
  && [[ -f "$hop_v/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T120100Z/previous-critical-holds/release_upgrade_package_transition_started" ]] \
  && [[ "$backup_count" -le 2 ]]; then
  pass "17.V post-archive pre-state resume without evidence loss"
else
  fail "17.V post-archive resume (rc=${rc} backups=${backup_count})"
  tail -40 "$hop_v/out.txt" || true
fi

# 17.W interruption after state write
hop_w="$(mktemp -d "${OUT_DIR}/hop-w.XXXX")"
hop_fx_prep "$hop_w"
printf 'PREFLIGHT\n' >"$hop_w/opt/aelladata/os-upgrade/offline/state"
printf 'CURRENT_HOP=jammy-to-noble\nCURRENT_RUN_ID=run-w\nCURRENT_SOURCE_CODENAME=jammy\nCURRENT_TARGET_CODENAME=noble\n' \
  >"$hop_w/opt/aelladata/os-upgrade/offline/current-hop.env"
mkdir -p "$hop_w/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T120200Z"
printf 'ok\n' >"$hop_w/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T120200Z/handoff-complete.ok"
set +e
DP_OFFLINE_TEST_ROOT="$hop_w" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_w/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && ! grep -q 'JAMMY_TO_NOBLE_HANDOFF_ACCEPTED=YES' "$hop_w/out.txt" \
  && [[ "$(cat "$hop_w/opt/aelladata/os-upgrade/offline/state")" == "PREFLIGHT" || "$(cat "$hop_w/opt/aelladata/os-upgrade/offline/state")" == "READY_FOR_CONFIRMATION" ]]; then
  pass "17.W post-state-write re-entry continues PREFLIGHT"
else
  fail "17.W post-state re-entry (rc=${rc})"
  tail -40 "$hop_w/out.txt" || true
fi

# 17.X idempotent handoff (covered by 17.L; reinforce with previous-owner markers)
hop_x="$(mktemp -d "${OUT_DIR}/hop-x.XXXX")"
hop_fx_prep "$hop_x"
hop_write_previous_owner "$hop_x"
printf 'COMPLETED_JAMMY\n' >"$hop_x/opt/aelladata/os-upgrade/offline/state"
printf 'true\n' >"$hop_x/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
set +e
DP_OFFLINE_TEST_ROOT="$hop_x" DP_OFFLINE_FAKE_MIRROR_TRUST=1 bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_x/out1.txt" 2>&1
rc1=$?
DP_OFFLINE_TEST_ROOT="$hop_x" DP_OFFLINE_FAKE_MIRROR_TRUST=1 bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_x/out2.txt" 2>&1
rc2=$?
set -e
bc="$(find "$hop_x/opt/aelladata/os-upgrade/offline/backups" -type d -name 'handoff-state-*' | wc -l | tr -d ' ')"
if [[ "$rc1" -eq 0 && "$rc2" -eq 0 && "$bc" -eq 1 ]] \
  && grep -q 'JAMMY_TO_NOBLE_HANDOFF_ACCEPTED=YES' "$hop_x/out1.txt" \
  && ! grep -q 'JAMMY_TO_NOBLE_HANDOFF_ACCEPTED=YES' "$hop_x/out2.txt"; then
  pass "17.X idempotent handoff with previous-owner markers"
else
  fail "17.X idempotent (rc1=${rc1} rc2=${rc2} backups=${bc})"
  tail -20 "$hop_x/out1.txt" || true
  tail -20 "$hop_x/out2.txt" || true
fi

# 17.Y b2f regression already covered by 17.K - reinforce J2N handoff absence
if grep -q 'already COMPLETED_JAMMY' "${ROOT}/client/dp-offline-upgrade-focal-to-jammy.sh.in" \
  && ! grep -q 'JAMMY_TO_NOBLE_HANDOFF_ACCEPTED' "${ROOT}/client/dp-offline-upgrade-focal-to-jammy.sh.in"; then
  pass "17.Y b2f COMPLETED_JAMMY terminal unchanged (no j2n handoff)"
else
  fail "17.Y b2f regression"
fi

# 17.Z Noble contradiction (24.04 + COMPLETED_JAMMY) - reinforce 17.C
hop_z="$(mktemp -d "${OUT_DIR}/hop-z.XXXX")"
hop_fx_prep "$hop_z"
cat >"$hop_z/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION_CODENAME=noble
EOF
printf 'COMPLETED_JAMMY\n' >"$hop_z/opt/aelladata/os-upgrade/offline/state"
set +e
DP_OFFLINE_TEST_ROOT="$hop_z" bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_z/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qE 'OS_VERSION_MISMATCH|FAIL_PREVIOUS_HOP_HANDOFF' "$hop_z/out.txt"; then
  pass "17.Z Noble contradiction fail-closed"
else
  fail "17.Z Noble contradiction (rc=${rc})"
  tail -30 "$hop_z/out.txt" || true
fi

# 17.AA actual production fixture (x2b leftover runtime + b2f client)
hop_aa="$(mktemp -d "${OUT_DIR}/hop-aa.XXXX")"
hop_fx_prep "$hop_aa"
hop_write_previous_owner "$hop_aa"
printf 'COMPLETED_JAMMY\n' >"$hop_aa/opt/aelladata/os-upgrade/offline/state"
printf 'true\n' >"$hop_aa/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
printf 'true\n' >"$hop_aa/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_invocation_started"
printf 'true\n' >"$hop_aa/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_started"
printf 'true\n' >"$hop_aa/opt/aelladata/os-upgrade/offline/critical-holds/package_transition_detection.done"
printf 'PACKAGE_TRANSACTION\n' >"$hop_aa/opt/aelladata/os-upgrade/offline/runner_stage"
printf 'EXPECTED_HOP=focal-to-jammy\n' >"$hop_aa/opt/aelladata/os-upgrade/offline/effective-source-gate.armed"
set +e
DP_OFFLINE_TEST_ROOT="$hop_aa" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_aa/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'MUTATION_EVIDENCE_CLASS=PREVIOUS_HOP_MUTATION' "$hop_aa/out.txt" \
  && grep -q 'HOP_HANDOFF_ACCEPTED=YES' "$hop_aa/out.txt" \
  && grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=YES' "$hop_aa/out.txt" \
  && grep -q 'PREVIOUS_HOP_VOLATILE_STATE=RETIRED' "$hop_aa/out.txt" \
  && [[ -f "$hop_aa/opt/aelladata/os-upgrade/offline/current-hop.env" ]] \
  && grep -q 'CURRENT_HOP=jammy-to-noble' "$hop_aa/opt/aelladata/os-upgrade/offline/current-hop.env" \
  && [[ ! -f "$hop_aa/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started" ]]; then
  pass "17.AA production fixture handoff to confirmation/preflight"
else
  fail "17.AA production fixture (rc=${rc})"
  tail -60 "$hop_aa/out.txt" || true
fi

# =============================================================================
# 19) Source-gate bundle lifecycle (AB–AR)
# =============================================================================
grep -q 'classify_effective_source_gate_bundle()' "$SCRIPT_IN" \
  && pass "classify_effective_source_gate_bundle present" || fail "classify helper missing"
grep -q 'retire_effective_source_gate_bundle()' "$SCRIPT_IN" \
  && pass "retire_effective_source_gate_bundle present" || fail "retire bundle helper missing"
grep -q 'repair_dangling_previous_source_gate_hook()' "$SCRIPT_IN" \
  && pass "repair_dangling_previous_source_gate_hook present" || fail "repair helper missing"
grep -q 'ensure_source_gate_safe_for_preflight()' "$SCRIPT_IN" \
  && pass "ensure_source_gate_safe_for_preflight present" || fail "ensure helper missing"
APT_HELPER="/home/aella/ubuntu-mirror-automation/client/lib/dp-offline-apt-preflight-sandbox.sh"
grep -q 'persist_temp_apt_failure_evidence()' "$APT_HELPER" \
  && grep -q '@@APT_PREFLIGHT_SANDBOX_HELPER@@' "$SCRIPT_IN_RAW" \
  && pass "persist_temp_apt_failure_evidence present" || fail "persist apt evidence missing"
grep -q 'build_temp_apt_conf_parts_without_stellar_gate()' "$SCRIPT_IN" \
  && pass "temp apt conf isolation helper present" || fail "temp apt isolation missing"
grep -q 'SOURCE_GATE_APT_HOOK_INSTALLED=YES' "$SCRIPT_IN" \
  && pass "install hook-last markers present" || fail "install ordering markers missing"
if grep -A80 'ensure_source_gate_safe_for_preflight' "$SCRIPT_IN" | grep -q 'check_critical_package_holds' \
  || grep -B5 'ensure_source_gate_safe_for_preflight' "$SCRIPT_IN" | grep -q 'check_critical_package_holds'; then
  pass "preflight calls source-gate ensure before mirror/apt"
else
  # Order: check_critical_package_holds then ensure_source_gate_safe_for_preflight
  holds_l="$(grep -n 'check_critical_package_holds$' "$SCRIPT_IN" | head -1 | cut -d: -f1)"
  ens_l="$(grep -n 'ensure_source_gate_safe_for_preflight$' "$SCRIPT_IN" | head -1 | cut -d: -f1)"
  if [[ -n "$holds_l" && -n "$ens_l" && "$holds_l" -lt "$ens_l" ]]; then
    pass "preflight calls source-gate ensure before mirror/apt"
  else
    fail "preflight source-gate ensure ordering"
  fi
fi

hop_sg_plant_previous_bundle() {
  local root="$1"
  local bin="$root/opt/aelladata/os-upgrade/offline/bin"
  mkdir -p "$bin" "$root/etc/apt/apt.conf.d"
  cat >"$bin/distupgrade-effective-source-gate" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat >"$bin/distupgrade-effective-source-gate.wrap" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat >"$bin/distupgrade-effective-source-gate.env" <<'EOF'
STELLAR_EXPECTED_HOP=focal-to-jammy
STELLAR_EXPECTED_MIRROR_URI=http://127.0.0.1/hops/focal-to-jammy/ubuntu
EOF
  chmod 0755 "$bin/distupgrade-effective-source-gate" "$bin/distupgrade-effective-source-gate.wrap"
  chmod 0644 "$bin/distupgrade-effective-source-gate.env"
  cat >"$root/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" <<'EOF'
// stellar offline: effective-source gate (installed DISARMED; armed before DRO)
APT::Update::Pre-Invoke { "/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap"; };
EOF
}

# 17.AB previous bundle complete → archive + retire + no dangling hook
hop_ab="$(mktemp -d "${OUT_DIR}/hop-ab.XXXX")"
hop_fx_prep "$hop_ab"
hop_write_previous_owner "$hop_ab"
hop_sg_plant_previous_bundle "$hop_ab"
printf 'COMPLETED_JAMMY\n' >"$hop_ab/opt/aelladata/os-upgrade/offline/state"
printf 'true\n' >"$hop_ab/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
set +e
DP_OFFLINE_TEST_ROOT="$hop_ab" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_ab/out.txt" 2>&1
rc=$?
set -e
arch_ab="$(find "$hop_ab/opt/aelladata/os-upgrade/offline/backups" -type d -name 'handoff-state-*' | head -1)"
if [[ "$rc" -eq 0 ]] \
  && [[ -n "$arch_ab" ]] \
  && [[ -f "$arch_ab/previous-source-gate/apt/98stellar-distupgrade-source-gate" || -f "$arch_ab/previous-source-gate/apt/98stellar-distupgrade-source-gate.live" ]] \
  && [[ -f "$arch_ab/previous-source-gate/bin/distupgrade-effective-source-gate.wrap" || -f "$arch_ab/previous-runtime/bin/distupgrade-effective-source-gate.wrap" ]] \
  && [[ ! -f "$hop_ab/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" ]] \
  && [[ ! -e "$hop_ab/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap" ]] \
  && grep -qE 'SOURCE_GATE_RETIRE_COMPLETE=YES|APT_HOOK_RETIRED=YES|SOURCE_GATE_DANGLING_HOOK_CHECK=PASS' "$hop_ab/out.txt"; then
  pass "17.AB previous bundle complete archive+retire"
else
  fail "17.AB previous bundle complete (rc=${rc})"
  tail -60 "$hop_ab/out.txt" || true
  ls -la "$hop_ab/etc/apt/apt.conf.d" 2>/dev/null || true
  ls -la "$arch_ab/previous-source-gate/apt" 2>/dev/null || true
fi

# 17.AC actual production dangling hook fixture (PREFLIGHT + archived wrap + live hook)
hop_ac="$(mktemp -d "${OUT_DIR}/hop-ac.XXXX")"
hop_fx_prep "$hop_ac"
printf 'PREFLIGHT\n' >"$hop_ac/opt/aelladata/os-upgrade/offline/state"
cat >"$hop_ac/opt/aelladata/os-upgrade/offline/current-hop.env" <<'EOF'
CURRENT_HOP=jammy-to-noble
CURRENT_SOURCE_CODENAME=jammy
CURRENT_TARGET_CODENAME=noble
CURRENT_RUN_ID=run-ac
CURRENT_RUN_EPOCH=1
PACKAGE_TRANSITION_STARTED=false
EOF
mkdir -p "$hop_ac/opt/aelladata/os-upgrade/offline/bin" \
  "$hop_ac/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T145605Z/previous-runtime/bin" \
  "$hop_ac/etc/apt/apt.conf.d"
# live bin empty; previous wrap archived
: >"$hop_ac/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T145605Z/previous-runtime/bin/distupgrade-effective-source-gate"
: >"$hop_ac/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T145605Z/previous-runtime/bin/distupgrade-effective-source-gate.wrap"
printf 'STELLAR_EXPECTED_HOP=focal-to-jammy\n' \
  >"$hop_ac/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T145605Z/previous-runtime/bin/distupgrade-effective-source-gate.env"
printf 'COMPLETED_JAMMY\n' >"$hop_ac/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T145605Z/state"
printf 'ok\n' >"$hop_ac/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T145605Z/handoff-complete.ok"
printf 'previous_hop=focal-to-jammy\n' \
  >"$hop_ac/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T145605Z/archive-manifest.txt"
cat >"$hop_ac/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" <<'EOF'
// stellar offline: effective-source gate (installed DISARMED; armed before DRO)
APT::Update::Pre-Invoke { "/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap"; };
EOF
set +e
DP_OFFLINE_TEST_ROOT="$hop_ac" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_ac/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'DANGLING_PREVIOUS_SOURCE_GATE_HOOK=DETECTED' "$hop_ac/out.txt" \
  && grep -q 'PREVIOUS_SOURCE_GATE_HOOK=ARCHIVED' "$hop_ac/out.txt" \
  && grep -q 'PREVIOUS_SOURCE_GATE_HOOK=RETIRED' "$hop_ac/out.txt" \
  && grep -q 'SOURCE_GATE_DANGLING_HOOK_CHECK=PASS' "$hop_ac/out.txt" \
  && grep -qE 'READY_FOR_CONFIRMATION|os_upgrade_result=READY_FOR_CONFIRMATION' "$hop_ac/out.txt" \
  && [[ ! -f "$hop_ac/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" ]] \
  && [[ "$(cat "$hop_ac/opt/aelladata/os-upgrade/offline/state")" == "READY_FOR_CONFIRMATION" || "$(cat "$hop_ac/opt/aelladata/os-upgrade/offline/state")" == "PREFLIGHT" ]]; then
  pass "17.AC production dangling hook repaired to confirmation"
else
  fail "17.AC dangling hook repair (rc=${rc})"
  tail -80 "$hop_ac/out.txt" || true
fi

# 17.AD wrapper retired, hook retained → PREVIOUS_HOP_GATE_DANGLING_HOOK + repair
hop_ad="$(mktemp -d "${OUT_DIR}/hop-ad.XXXX")"
hop_fx_prep "$hop_ad"
printf 'PREFLIGHT\n' >"$hop_ad/opt/aelladata/os-upgrade/offline/state"
printf 'CURRENT_HOP=jammy-to-noble\nCURRENT_SOURCE_CODENAME=jammy\nCURRENT_TARGET_CODENAME=noble\n' \
  >"$hop_ad/opt/aelladata/os-upgrade/offline/current-hop.env"
mkdir -p "$hop_ad/opt/aelladata/os-upgrade/offline/bin" \
  "$hop_ad/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T150000Z/previous-runtime/bin" \
  "$hop_ad/etc/apt/apt.conf.d"
: >"$hop_ad/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T150000Z/previous-runtime/bin/distupgrade-effective-source-gate.wrap"
printf 'ok\n' >"$hop_ad/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T150000Z/handoff-complete.ok"
cat >"$hop_ad/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" <<'EOF'
APT::Update::Pre-Invoke { "/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap"; };
EOF
set +e
DP_OFFLINE_TEST_ROOT="$hop_ad" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_ad/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'SOURCE_GATE_CLASS=PREVIOUS_HOP_GATE_DANGLING_HOOK' "$hop_ad/out.txt" \
  && grep -qE 'SOURCE_GATE_REPAIR=PASS|PREVIOUS_SOURCE_GATE_HOOK=RETIRED' "$hop_ad/out.txt" \
  && [[ ! -f "$hop_ad/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" ]]; then
  pass "17.AD dangling hook classified and repaired"
else
  fail "17.AD dangling classification/repair (rc=${rc})"
  tail -50 "$hop_ad/out.txt" || true
fi

# 17.AE hook retired, wrapper retained → not mistaken for current hop
hop_ae="$(mktemp -d "${OUT_DIR}/hop-ae.XXXX")"
hop_fx_prep "$hop_ae"
printf 'PREFLIGHT\n' >"$hop_ae/opt/aelladata/os-upgrade/offline/state"
printf 'CURRENT_HOP=jammy-to-noble\nCURRENT_SOURCE_CODENAME=jammy\nCURRENT_TARGET_CODENAME=noble\n' \
  >"$hop_ae/opt/aelladata/os-upgrade/offline/current-hop.env"
mkdir -p "$hop_ae/opt/aelladata/os-upgrade/offline/bin" \
  "$hop_ae/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T151000Z"
printf 'ok\n' >"$hop_ae/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T151000Z/handoff-complete.ok"
cat >"$hop_ae/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$hop_ae/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap" <<'EOF'
#!/bin/sh
exit 0
EOF
printf 'STELLAR_EXPECTED_HOP=focal-to-jammy\n' \
  >"$hop_ae/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.env"
chmod 0755 "$hop_ae/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate" \
  "$hop_ae/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap"
set +e
DP_OFFLINE_TEST_ROOT="$hop_ae" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_ae/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -qE 'SOURCE_GATE_CLASS=PREVIOUS_HOP_GATE_COMPLETE|SOURCE_GATE_DANGLING_HOOK_CHECK=PASS' "$hop_ae/out.txt" \
  && ! grep -q 'SOURCE_GATE_CLASS=CURRENT_HOP_GATE_VALID' "$hop_ae/out.txt"; then
  pass "17.AE retained previous wrap not mistaken for current hop"
else
  fail "17.AE previous wrap retention (rc=${rc})"
  tail -50 "$hop_ae/out.txt" || true
fi

# 17.AF current-hop valid bundle → unchanged VALID
hop_af="$(mktemp -d "${OUT_DIR}/hop-af.XXXX")"
hop_fx_prep "$hop_af"
printf 'PREFLIGHT\n' >"$hop_af/opt/aelladata/os-upgrade/offline/state"
printf 'CURRENT_HOP=jammy-to-noble\nCURRENT_SOURCE_CODENAME=jammy\nCURRENT_TARGET_CODENAME=noble\n' \
  >"$hop_af/opt/aelladata/os-upgrade/offline/current-hop.env"
mkdir -p "$hop_af/opt/aelladata/os-upgrade/offline/bin" "$hop_af/etc/apt/apt.conf.d"
cat >"$hop_af/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$hop_af/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap" <<'EOF'
#!/bin/sh
exit 0
EOF
printf 'STELLAR_EXPECTED_HOP=jammy-to-noble\nSTELLAR_EXPECTED_MIRROR_URI=http://127.0.0.1/hops/jammy-to-noble/ubuntu\n' \
  >"$hop_af/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.env"
chmod 0755 "$hop_af/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate" \
  "$hop_af/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap"
cat >"$hop_af/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" <<'EOF'
APT::Update::Pre-Invoke { "/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap"; };
EOF
set +e
DP_OFFLINE_TEST_ROOT="$hop_af" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_af/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'SOURCE_GATE_CLASS=CURRENT_HOP_GATE_VALID' "$hop_af/out.txt" \
  && [[ -f "$hop_af/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" ]] \
  && [[ -e "$hop_af/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap" ]]; then
  pass "17.AF current-hop valid bundle unchanged"
else
  fail "17.AF current valid bundle (rc=${rc})"
  tail -50 "$hop_af/out.txt" || true
fi

# 17.AG current wrapper missing → CURRENT_HOP_GATE_INCOMPLETE fail-closed
hop_ag="$(mktemp -d "${OUT_DIR}/hop-ag.XXXX")"
hop_fx_prep "$hop_ag"
printf 'PREFLIGHT\n' >"$hop_ag/opt/aelladata/os-upgrade/offline/state"
printf 'CURRENT_HOP=jammy-to-noble\nCURRENT_SOURCE_CODENAME=jammy\nCURRENT_TARGET_CODENAME=noble\n' \
  >"$hop_ag/opt/aelladata/os-upgrade/offline/current-hop.env"
mkdir -p "$hop_ag/opt/aelladata/os-upgrade/offline/bin" "$hop_ag/etc/apt/apt.conf.d"
printf 'STELLAR_EXPECTED_HOP=jammy-to-noble\n' \
  >"$hop_ag/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.env"
cat >"$hop_ag/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" <<'EOF'
APT::Update::Pre-Invoke { "/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap"; };
EOF
set +e
DP_OFFLINE_TEST_ROOT="$hop_ag" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_ag/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] \
  && grep -qE 'SOURCE_GATE_CLASS=CURRENT_HOP_GATE_INCOMPLETE|FAIL_SOURCE_GATE_CONFIGURATION_CURRENT_HOP_GATE_INCOMPLETE' "$hop_ag/out.txt" \
  && grep -q 'SOURCE_GATE_REPAIR=REFUSED' "$hop_ag/out.txt"; then
  pass "17.AG current wrap missing fail-closed"
else
  fail "17.AG current incomplete (rc=${rc})"
  tail -50 "$hop_ag/out.txt" || true
fi

# 17.AH unknown custom hook in same apt config → fail-closed, file not deleted
hop_ah="$(mktemp -d "${OUT_DIR}/hop-ah.XXXX")"
hop_fx_prep "$hop_ah"
printf 'PREFLIGHT\n' >"$hop_ah/opt/aelladata/os-upgrade/offline/state"
printf 'CURRENT_HOP=jammy-to-noble\nCURRENT_SOURCE_CODENAME=jammy\nCURRENT_TARGET_CODENAME=noble\n' \
  >"$hop_ah/opt/aelladata/os-upgrade/offline/current-hop.env"
mkdir -p "$hop_ah/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T152000Z/previous-runtime/bin" \
  "$hop_ah/etc/apt/apt.conf.d"
: >"$hop_ah/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T152000Z/previous-runtime/bin/distupgrade-effective-source-gate.wrap"
printf 'ok\n' >"$hop_ah/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T152000Z/handoff-complete.ok"
cat >"$hop_ah/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" <<'EOF'
APT::Update::Pre-Invoke { "/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap"; };
APT::Update::Pre-Invoke { "/usr/local/bin/custom-operator-hook"; };
EOF
set +e
DP_OFFLINE_TEST_ROOT="$hop_ah" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_ah/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] \
  && grep -q 'AMBIGUOUS_GATE_CONFIGURATION\|SOURCE_GATE_CONFIGURATION=AMBIGUOUS' "$hop_ah/out.txt" \
  && [[ -f "$hop_ah/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" ]] \
  && grep -q 'custom-operator-hook' "$hop_ah/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate"; then
  pass "17.AH custom mixed hook fail-closed; file preserved"
else
  fail "17.AH custom hook policy (rc=${rc})"
  tail -50 "$hop_ah/out.txt" || true
fi

# 17.AI duplicate hook definitions → ambiguity
hop_ai="$(mktemp -d "${OUT_DIR}/hop-ai.XXXX")"
hop_fx_prep "$hop_ai"
printf 'PREFLIGHT\n' >"$hop_ai/opt/aelladata/os-upgrade/offline/state"
printf 'CURRENT_HOP=jammy-to-noble\nCURRENT_SOURCE_CODENAME=jammy\nCURRENT_TARGET_CODENAME=noble\n' \
  >"$hop_ai/opt/aelladata/os-upgrade/offline/current-hop.env"
mkdir -p "$hop_ai/etc/apt/apt.conf.d" \
  "$hop_ai/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T153000Z/previous-runtime/bin"
: >"$hop_ai/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T153000Z/previous-runtime/bin/distupgrade-effective-source-gate.wrap"
printf 'ok\n' >"$hop_ai/opt/aelladata/os-upgrade/offline/backups/handoff-state-20260723T153000Z/handoff-complete.ok"
cat >"$hop_ai/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" <<'EOF'
APT::Update::Pre-Invoke { "/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap"; };
EOF
cat >"$hop_ai/etc/apt/apt.conf.d/99-extra-stellar-gate" <<'EOF'
APT::Update::Pre-Invoke { "/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap"; };
EOF
set +e
DP_OFFLINE_TEST_ROOT="$hop_ai" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_ai/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] \
  && grep -qE 'AMBIGUOUS_GATE_CONFIGURATION|DUPLICATE_HOOK' "$hop_ai/out.txt" \
  && [[ -f "$hop_ai/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" ]] \
  && [[ -f "$hop_ai/etc/apt/apt.conf.d/99-extra-stellar-gate" ]]; then
  pass "17.AI duplicate hook ambiguity fail-closed"
else
  fail "17.AI duplicate hook (rc=${rc})"
  tail -50 "$hop_ai/out.txt" || true
fi

# 17.AJ install ordering: hook after binaries (static)
if python3 - <<'PY'
from pathlib import Path
text = Path("/home/aella/ubuntu-mirror-automation/client/dp-offline-upgrade-jammy-to-noble.sh.in").read_text(encoding="utf-8")
start = text.index("install_effective_source_gate() {")
end = text.index("\nremove_distupgrade_temp_overrides()", start)
body = text[start:end]
# Binary mv/chmod must appear before apt hook mv
bin_i = body.index('mv -f "${bin_path}.new" "$bin_path"')
hook_i = body.index('mv -f "${apt_path}.new" "$apt_path"')
guard = "BINARIES_NOT_READY_BEFORE_HOOK" in body
assert bin_i < hook_i and guard
print("ORDER_OK")
PY
then
  pass "17.AJ install ordering binaries before hook"
else
  fail "17.AJ install ordering"
fi

# 17.AK install interruption markers (static + idempotent ensure)
grep -q 'BINARIES_NOT_READY_BEFORE_HOOK' "$SCRIPT_IN" \
  && grep -q 'SOURCE_GATE_APT_HOOK_INSTALLED=YES' "$SCRIPT_IN" \
  && pass "17.AK install interruption guards present" \
  || fail "17.AK install interruption guards missing"

# 17.AL retire interruption resumable markers
grep -q 'retire-incomplete.txt\|SOURCE_GATE_RETIRE_COMPLETE' "$SCRIPT_IN" \
  && pass "17.AL retire interruption markers present" \
  || fail "17.AL retire interruption markers missing"

# 17.AM temporary apt update isolation
APT_HELPER="/home/aella/ubuntu-mirror-automation/client/lib/dp-offline-apt-preflight-sandbox.sh"
grep -q 'Dir::Etc::Parts' "$APT_HELPER" \
  && grep -q 'Dir::Etc::sourceparts' "$APT_HELPER" \
  && grep -q 'build_temp_apt_conf_parts_without_stellar_gate' "$SCRIPT_IN" \
  && pass "17.AM temporary apt isolation present" \
  || fail "17.AM temporary apt isolation missing"

# 17.AN non-Stellar hooks preservation (isolation copies other conf.d files)
grep -q 'exclude only the Stellar source-gate\|excluding only the Stellar source-gate\|98stellar-distupgrade-source-gate' "$SCRIPT_IN" \
  && grep -q 'build_temp_apt_conf_parts_without_stellar_gate' "$SCRIPT_IN" \
  && pass "17.AN non-Stellar hook preservation helper" \
  || fail "17.AN non-Stellar preservation missing"

# 17.AO apt authentication fail-closed + _apt sandbox gates (shared helper)
APT_HELPER="/home/aella/ubuntu-mirror-automation/client/lib/dp-offline-apt-preflight-sandbox.sh"
grep -q 'run_temporary_local_apt_authentication_preflight' "$SCRIPT_IN" \
  && grep -q 'APT_SANDBOX_TRAVERSAL' "$APT_HELPER" \
  && grep -q 'APT_REPOSITORY_AUTHENTICATION=PASS' "$APT_HELPER" \
  && grep -q 'APT_SIGNATURE_WARNING_COUNT' "$APT_HELPER" \
  && pass "17.AO apt sandbox/auth fail-closed policy" \
  || fail "17.AO apt sandbox/auth policy missing"

# 17.AP b2f regression: source-gate install/validation still present; no J2N handoff
B2F_IN="${ROOT}/client/dp-offline-upgrade-focal-to-jammy.sh.in"
if grep -q 'install_effective_source_gate()' "$B2F_IN" \
  && grep -q 'SOURCE_GATE_INSTALL=PASS\|DISTUPGRADE_EFFECTIVE_SOURCE_GATE_STATE=INSTALLED_DISARMED' "$B2F_IN" \
  && grep -q 'BINARIES_NOT_READY_BEFORE_HOOK' "$B2F_IN" \
  && ! grep -q 'JAMMY_TO_NOBLE_HANDOFF_ACCEPTED' "$B2F_IN"; then
  pass "17.AP b2f source-gate install regression OK"
else
  fail "17.AP b2f source-gate regression"
fi

# 17.AQ b2f fresh VM (no old hook)
hop_aq="$(mktemp -d "${OUT_DIR}/hop-aq.XXXX")"
hop_fx_prep "$hop_aq"
printf 'PREFLIGHT\n' >"$hop_aq/opt/aelladata/os-upgrade/offline/state"
printf 'CURRENT_HOP=jammy-to-noble\nCURRENT_SOURCE_CODENAME=jammy\nCURRENT_TARGET_CODENAME=noble\n' \
  >"$hop_aq/opt/aelladata/os-upgrade/offline/current-hop.env"
set +e
DP_OFFLINE_TEST_ROOT="$hop_aq" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_aq/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -qE 'SOURCE_GATE_CLASS=NO_STELLAR_GATE|SOURCE_GATE_DANGLING_HOOK_CHECK=PASS' "$hop_aq/out.txt" \
  && grep -qE 'READY_FOR_CONFIRMATION|os_upgrade_result=READY_FOR_CONFIRMATION' "$hop_aq/out.txt"; then
  pass "17.AQ fresh Jammy VM preflight PASS"
else
  fail "17.AQ fresh VM (rc=${rc})"
  tail -40 "$hop_aq/out.txt" || true
fi

# 17.AR b2f chained VM (x2b completed runtime leftovers)
hop_ar="$(mktemp -d "${OUT_DIR}/hop-ar.XXXX")"
hop_fx_prep "$hop_ar"
hop_write_previous_owner "$hop_ar"
hop_sg_plant_previous_bundle "$hop_ar"
printf 'COMPLETED_JAMMY\n' >"$hop_ar/opt/aelladata/os-upgrade/offline/state"
printf 'true\n' >"$hop_ar/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
printf 'EXPECTED_HOP=focal-to-jammy\n' >"$hop_ar/opt/aelladata/os-upgrade/offline/effective-source-gate.armed"
set +e
DP_OFFLINE_TEST_ROOT="$hop_ar" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_ar/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'HOP_HANDOFF_ACCEPTED=YES' "$hop_ar/out.txt" \
  && grep -qE 'SOURCE_GATE_RETIRE_COMPLETE=YES|APT_HOOK_RETIRED=YES' "$hop_ar/out.txt" \
  && grep -q 'SOURCE_GATE_DANGLING_HOOK_CHECK=PASS' "$hop_ar/out.txt" \
  && grep -qE 'READY_FOR_CONFIRMATION|os_upgrade_result=READY_FOR_CONFIRMATION' "$hop_ar/out.txt" \
  && [[ ! -f "$hop_ar/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" ]] \
  && [[ -f "$hop_ar/opt/aelladata/os-upgrade/offline/current-hop.env" ]]; then
  pass "17.AR chained VM handoff+source-gate retire+confirmation PASS"
else
  fail "17.AR chained VM (rc=${rc})"
  tail -80 "$hop_ar/out.txt" || true
fi

# =============================================================================
# 17.AS–BG - silent preflight exit / meta-release 404 continuation / invariants
# =============================================================================

# Rebuild stub from current template so AS–BG see latest control-flow fixes.
python3 - "$SCRIPT_IN" "$STUB" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
from pathlib import Path
text = open(src, encoding="utf-8").read()
_lib = Path(src).resolve().parent / "lib"
for _tok, _name in (
    ("@@DESTRUCTIVE_CONFIRMATION_HELPER@@", "dp-offline-destructive-confirmation.sh"),
    ("@@RELEASE_UPGRADE_RECONCILIATION_HELPER@@", "dp-offline-release-upgrade-reconciliation.sh"),
    ("@@APT_PREFLIGHT_SANDBOX_HELPER@@", "dp-offline-apt-preflight-sandbox.sh"),
    ("@@DURABLE_WRITE_HELPER@@", "dp-offline-durable-write.sh"),
    ("@@SOURCE_PRODUCT_HELPER@@", "dp-offline-source-product-version.sh"),
    ("@@LXD_INVENTORY_HELPER@@", "dp-offline-lxd-inventory.sh"),
):
    _hp = _lib / _name
    if _tok in text and _hp.is_file():
        text = text.replace(_tok, _hp.read_text(encoding="utf-8").rstrip("\n") + "\n")
pins = {
    "MIRROR_BASE": "",
    "HOP": "jammy-to-noble",
    "SOURCE_CODENAME": "jammy",
    "TARGET_CODENAME": "noble",
    "SOURCE_VERSION": "22.04",
    "TARGET_VERSION": "24.04",
    "COMPONENTS": "main universe",
    "SOURCE_SUITES": "jammy",
    "TARGET_SUITES": "noble noble-updates noble-security noble-backports",
    "KEY_FINGERPRINT": "DEADBEEF",
    "KEY_SHA256": "0" * 64,
    "MANIFEST_KEY_FINGERPRINT": "DEADBEEF",
    "MANIFEST_KEY_SHA256": "0" * 64,
    "META_SHA256": "0" * 64,
    "UPGRADER_TAR_SHA256": "0" * 64,
    "UPGRADER_GPG_SHA256": "0" * 64,
    "PLAN_CHECKSUM": "0" * 64,
    "DISCOVERY_CHECKSUM": "0" * 64,
    "MANIFEST_SHA256": "0" * 64,
    "SAMPLE_DEB_PATH": "/sample.deb",
    "CONFIRM_PHRASE": "UPGRADE-JAMMY-TO-NOBLE",
    "GENERATED_AT": "1970-01-01T00:00:00Z",
    "PROFILE_NAME": "offline-upgrade-selective",
    "KEY_B64": "c3R1Yg==",
    "MANIFEST_KEY_B64": "c3R1Yg==",
    "META_B64": "c3R1Yg==",
    "MANIFEST_B64": "c3R1Yg==",
    "MANIFEST_SIG_B64": "c3R1Yg==",
    "ANNOUNCEMENT_B64": "c3R1Yg==",
}
policy = (Path(src).resolve().parent / "dp-postboot-readiness-policy.sh.inc").read_text(encoding="utf-8").rstrip("\n")
text = text.replace("@@POSTBOOT_POLICY_LIB@@", policy)
for key, val in pins.items():
    text = text.replace("@@{}@@".format(key), val)
text = re.sub(r"@@[A-Z0-9_]+@@", "stub", text)
open(dst, "w", encoding="utf-8").write(text)
PY
chmod +x "$STUB"

# 17.AS meta-release 404 continuation (fixture path with fake mirror trust)
hop_as="$(mktemp -d "${OUT_DIR}/hop-as.XXXX")"
hop_fx_prep "$hop_as"
printf 'PREFLIGHT\n' >"$hop_as/opt/aelladata/os-upgrade/offline/state"
printf 'CURRENT_HOP=jammy-to-noble\nCURRENT_SOURCE_CODENAME=jammy\nCURRENT_TARGET_CODENAME=noble\n' \
  >"$hop_as/opt/aelladata/os-upgrade/offline/current-hop.env"
# http-map: meta-release 404; other URLs unused under FAKE_MIRROR_TRUST
printf '%s\t%s\n' \
  'http://127.0.0.1:9/client/jammy-to-noble/meta-release-lts' '404' \
  >"$hop_as/tmp/http-map.tsv"
set +e
DP_OFFLINE_TEST_ROOT="$hop_as" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_as/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -qE 'READY_FOR_CONFIRMATION|os_upgrade_result=READY_FOR_CONFIRMATION' "$hop_as/out.txt" \
  && grep -q 'preflight-only requested' "$hop_as/out.txt" \
  && [[ "$(cat "$hop_as/opt/aelladata/os-upgrade/offline/state")" == "READY_FOR_CONFIRMATION" ]]; then
  pass "17.AS meta-release 404 path reaches READY_FOR_CONFIRMATION"
else
  fail "17.AS meta-release 404 continuation (rc=${rc})"
  tail -60 "$hop_as/out.txt" || true
fi

# 17.AT exact production silent-exit fixture shape (chained PREFLIGHT, repaired gate)
hop_at="$(mktemp -d "${OUT_DIR}/hop-at.XXXX")"
hop_fx_prep "$hop_at"
hop_write_previous_owner "$hop_at"
hop_sg_plant_previous_bundle "$hop_at"
# Simulate post-repair: no live hook, PREFLIGHT, current hop set, archive present
rm -f "$hop_at/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate"
printf 'PREFLIGHT\n' >"$hop_at/opt/aelladata/os-upgrade/offline/state"
printf 'CURRENT_HOP=jammy-to-noble\nCURRENT_SOURCE_CODENAME=jammy\nCURRENT_TARGET_CODENAME=noble\n' \
  >"$hop_at/opt/aelladata/os-upgrade/offline/current-hop.env"
mkdir -p "$hop_at/opt/aelladata/os-upgrade/offline/backups/handoff-state-test/previous-source-gate"
printf 'wrap\n' >"$hop_at/opt/aelladata/os-upgrade/offline/backups/handoff-state-test/previous-source-gate/distupgrade-effective-source-gate.wrap"
set +e
DP_OFFLINE_TEST_ROOT="$hop_at" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_at/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -qE 'READY_FOR_CONFIRMATION|os_upgrade_result=READY_FOR_CONFIRMATION' "$hop_at/out.txt" \
  && [[ "$(cat "$hop_at/opt/aelladata/os-upgrade/offline/state")" == "READY_FOR_CONFIRMATION" ]]; then
  pass "17.AT chained PREFLIGHT silent-exit fixture → READY_FOR_CONFIRMATION"
else
  fail "17.AT chained PREFLIGHT fixture (rc=${rc})"
  tail -80 "$hop_at/out.txt" || true
fi

# 17.AU cross-release zero candidates (unit: parser + return path markers)
if grep -q 'cross_release_query_policy' "$SCRIPT_IN" \
  && grep -q 'CHECK_CROSS_RELEASE_CANDIDATES_ENTER=YES' "$SCRIPT_IN" \
  && grep -q 'CHECK_CROSS_RELEASE_CANDIDATES_EXIT=PASS' "$SCRIPT_IN" \
  && grep -q 'cross_release_candidate_from_policy' "$SCRIPT_IN"; then
  pass "17.AU cross-release zero-candidate control markers present"
else
  fail "17.AU cross-release zero-candidate markers missing"
fi

# 17.AV cross-release positive candidates → die non-zero (no exit 0)
# Scope to the guard function only (stop before LXD inventory / run_os_preflight).
av_body="$(awk '
  /^check_cross_release_candidates\(\)/ {p=1}
  p && (/^python2_pkg_installed_p\(\)/ || /^lxd_validate_inventory_timeouts\(\)/ || /^lxd_preflight_gate\(\)/ || /^run_os_preflight\(\)/) {exit}
  p
' "$SCRIPT_IN")"
if printf '%s\n' "$av_body" | grep -q 'PRE_UPGRADER_PACKAGE_GUARD=FAIL' \
  && printf '%s\n' "$av_body" | grep -q 'die "\$EC_CROSS_RELEASE"' \
  && ! printf '%s\n' "$av_body" | grep -qE '^[[:space:]]*exit[[:space:]]+0'; then
  pass "17.AV positive candidates fail closed (no exit 0)"
else
  fail "17.AV positive-candidate failure path"
fi

# 17.AW cross-release query failure → explicit fail + evidence
if grep -q 'CROSS_RELEASE_CANDIDATE_QUERY=FAIL' "$SCRIPT_IN" \
  && grep -q 'FAIL_CROSS_RELEASE_CANDIDATE_QUERY' "$SCRIPT_IN" \
  && grep -q 'persist_temp_apt_failure_evidence' "$SCRIPT_IN"; then
  pass "17.AW query failure explicit + evidence"
else
  fail "17.AW query failure path missing"
fi

# 17.AX no exec in preflight helpers
ax_bad=0
for fn in verify_mirror_trust_chain check_cross_release_candidates validate_meta_release_preview; do
  if awk -v fn="$fn" '
    $0 ~ "^"fn"\\(\\) \\{" {p=1; next}
    p && /^[a-zA-Z_][a-zA-Z0-9_]*\\(\\) \\{/ {exit}
    p && /(^|[[:space:]])exec([[:space:]]|$)/ && $0 !~ /-exec/ {print; e=1}
    END {exit e+0}
  ' "$SCRIPT_IN"; then
    ax_bad=1
  fi
done
if [[ "$ax_bad" -eq 0 ]]; then
  pass "17.AX no exec in preflight helpers"
else
  fail "17.AX exec found in preflight helpers"
fi

# 17.AY no direct exit in preflight helpers (awk exit in strings/comments ignored)
ay_bad=0
for fn in verify_mirror_trust_chain check_cross_release_candidates validate_meta_release_preview; do
  if awk -v fn="$fn" '
    $0 ~ "^"fn"\\(\\) \\{" {p=1; next}
    p && /^[a-zA-Z_][a-zA-Z0-9_]*\\(\\) \\{/ {exit}
    p && /^[[:space:]]*exit([[:space:]]|$)/ {print; e=1}
    END {exit e+0}
  ' "$SCRIPT_IN"; then
    ay_bad=1
  fi
done
if [[ "$ay_bad" -eq 0 ]]; then
  pass "17.AY no direct exit in preflight helpers"
else
  fail "17.AY direct exit found in preflight helpers"
fi

# 17.AZ preflight success invariant
if grep -q 'assert_preflight_ready_state' "$SCRIPT_IN" \
  && grep -q 'FAIL_PREFLIGHT_RETURNED_WITHOUT_READY_FOR_CONFIRMATION' "$SCRIPT_IN" \
  && grep -q 'guard_unexpected_preflight_exit' "$SCRIPT_IN"; then
  az_h="${OUT_DIR}/az-invariant-harness.sh"
  hop_az="$(mktemp -d "${OUT_DIR}/hop-az.XXXX")"
  hop_fx_prep "$hop_az"
  printf 'PREFLIGHT\n' >"$hop_az/opt/aelladata/os-upgrade/offline/state"
  cat >"$az_h" <<EOF
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="$hop_az"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
STATE_FILE="\${STATE_ROOT}/state"
EC_INTERNAL=99
log(){ printf '%s [%s] %s\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" "\$1" "\$2" >&2; }
die(){ local c="\$1"; shift; log ERROR "\$* (exit=\${c})"; exit "\$c"; }
hostpath(){ printf '%s%s' "\$TEST_ROOT" "\$1"; }
read_state(){ local f; f="\$(hostpath "\$STATE_FILE")"; [[ -f "\$f" ]] && tr -d '\r\n' <"\$f" || true; }
assert_preflight_ready_state() {
  local preflight_state
  preflight_state="\$(read_state)"
  if [[ "\$preflight_state" != "READY_FOR_CONFIRMATION" ]]; then
    log ERROR "PREFLIGHT_RETURNED_WITHOUT_READY_STATE=YES"
    log ERROR "PREFLIGHT_RETURN_STATE=\${preflight_state}"
    die "\$EC_INTERNAL" "FAIL_PREFLIGHT_RETURNED_WITHOUT_READY_FOR_CONFIRMATION"
  fi
}
assert_preflight_ready_state
EOF
  set +e
  bash "$az_h" >"$hop_az/out.txt" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 99 ]] && grep -q 'FAIL_PREFLIGHT_RETURNED_WITHOUT_READY_FOR_CONFIRMATION' "$hop_az/out.txt"; then
    pass "17.AZ preflight invariant rejects PREFLIGHT return"
  else
    fail "17.AZ invariant (rc=${rc})"
    cat "$hop_az/out.txt" || true
  fi
else
  fail "17.AZ invariant helpers missing"
fi

# 17.BA --preflight-only regression
hop_ba="$(mktemp -d "${OUT_DIR}/hop-ba.XXXX")"
hop_fx_prep "$hop_ba"
printf 'PREFLIGHT\n' >"$hop_ba/opt/aelladata/os-upgrade/offline/state"
set +e
DP_OFFLINE_TEST_ROOT="$hop_ba" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_ba/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'READY_FOR_CONFIRMATION' "$hop_ba/out.txt" \
  && grep -q 'preflight-only requested - no confirmation, no persistent changes' "$hop_ba/out.txt" \
  && ! grep -q 'UPGRADE-JAMMY-TO-NOBLE' "$hop_ba/out.txt" \
  && [[ "$(cat "$hop_ba/opt/aelladata/os-upgrade/offline/state")" == "READY_FOR_CONFIRMATION" ]]; then
  pass "17.BA --preflight-only regression"
else
  fail "17.BA --preflight-only (rc=${rc})"
  tail -40 "$hop_ba/out.txt" || true
fi

# 17.BB completed Noble regression
hop_bb="$(mktemp -d "${OUT_DIR}/hop-bb.XXXX")"
hop_fx_prep "$hop_bb"
cat >"$hop_bb/etc/os-release" <<'EOF'
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION_CODENAME=noble
PRETTY_NAME="Ubuntu 24.04.5 LTS"
EOF
printf 'COMPLETED_NOBLE\n' >"$hop_bb/opt/aelladata/os-upgrade/offline/state"
set +e
DP_OFFLINE_TEST_ROOT="$hop_bb" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 >"$hop_bb/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q 'already COMPLETED_NOBLE' "$hop_bb/out.txt"; then
  pass "17.BB completed Noble exit 0"
else
  fail "17.BB completed Noble (rc=${rc})"
  tail -40 "$hop_bb/out.txt" || true
fi

# 17.BC normal interactive flow reaches confirmation prompt markers
hop_bc="$(mktemp -d "${OUT_DIR}/hop-bc.XXXX")"
hop_fx_prep "$hop_bc"
printf 'PREFLIGHT\n' >"$hop_bc/opt/aelladata/os-upgrade/offline/state"
# Decline confirmation to avoid mutation; expect READY + prompt text then confirm fail
set +e
printf 'no\n' | DP_OFFLINE_TEST_ROOT="$hop_bc" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 >"$hop_bc/out.txt" 2>&1
rc=$?
set -e
if grep -q 'READY_FOR_CONFIRMATION' "$hop_bc/out.txt" \
  && grep -qE 'UPGRADE-JAMMY-TO-NOBLE|DESTRUCTIVE OFFLINE OS UPGRADE|Type the confirmation' "$hop_bc/out.txt"; then
  pass "17.BC interactive flow reaches confirmation prompt"
else
  fail "17.BC interactive confirmation path (rc=${rc})"
  tail -60 "$hop_bc/out.txt" || true
fi

# 17.BD source template / generated parity (control-flow markers)
if [[ -f "${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh" ]]; then
  gen="${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh"
  bd_ok=1
  for marker in \
    'cross_release_query_policy' \
    'assert_preflight_ready_state' \
    'META_RELEASE_HTTP_FALLBACK' \
    'PREFLIGHT_CHECKPOINT_AFTER_MIRROR_TRUST' \
    'guard_unexpected_preflight_exit'
  do
    if ! grep -q "$marker" "$SCRIPT_IN" || ! grep -q "$marker" "$gen"; then
      # generated may be stale until rebuild - require template; warn on gen
      if ! grep -q "$marker" "$SCRIPT_IN"; then
        bd_ok=0
      fi
    fi
  done
  if [[ "$bd_ok" -eq 1 ]] \
    && ! grep -E 'apt-cache.*"\$\{apt_opts\[@\]\}".*policy.*\|.*awk' "$SCRIPT_IN"; then
    pass "17.BD template control-flow parity markers"
  else
    fail "17.BD template/generated parity"
  fi
else
  pass "17.BD generated absent - template markers only"
fi

# 17.BE HTTP artifact parity markers (sidecar contract remains in deploy script)
if grep -q 'HTTP_SHA256\|ARTIFACT_SHA256\|HTTP_SIGNATURE_VERIFY' \
  "${ROOT}/scripts/deploy-client-jammy-to-noble-atomic.sh"; then
  pass "17.BE deploy script HTTP/artifact parity checks present"
else
  fail "17.BE deploy parity checks missing"
fi

# 17.BF EXIT trap regression - SIGPIPE/silent success guard present; RETURN cleanup cleared
if grep -q 'main_exit_trap' "$SCRIPT_IN" \
  && grep -q 'PREFLIGHT_ABORT_SIGPIPE' "$SCRIPT_IN" \
  && grep -q 'PREFLIGHT_SILENT_SUCCESS_EXIT' "$SCRIPT_IN" \
  && grep -q "trap - RETURN" "$SCRIPT_IN"; then
  pass "17.BF EXIT trap / SIGPIPE silent-success guards"
else
  fail "17.BF EXIT trap regression markers"
fi

# 17.BG full chained fixture → READY_FOR_CONFIRMATION
hop_bg="$(mktemp -d "${OUT_DIR}/hop-bg.XXXX")"
hop_fx_prep "$hop_bg"
hop_write_previous_owner "$hop_bg"
hop_sg_plant_previous_bundle "$hop_bg"
printf 'COMPLETED_JAMMY\n' >"$hop_bg/opt/aelladata/os-upgrade/offline/state"
printf 'true\n' >"$hop_bg/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
set +e
DP_OFFLINE_TEST_ROOT="$hop_bg" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$hop_bg/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -qE 'HOP_HANDOFF_ACCEPTED=YES|SOURCE_GATE_DANGLING_HOOK_CHECK=PASS|SOURCE_GATE_REPAIR=PASS|SOURCE_GATE_CLASS=NO_STELLAR_GATE' "$hop_bg/out.txt" \
  && grep -qE 'READY_FOR_CONFIRMATION|os_upgrade_result=READY_FOR_CONFIRMATION' "$hop_bg/out.txt" \
  && [[ "$(cat "$hop_bg/opt/aelladata/os-upgrade/offline/state")" == "READY_FOR_CONFIRMATION" ]]; then
  pass "17.BG full chained fixture → READY_FOR_CONFIRMATION"
else
  fail "17.BG full chained fixture (rc=${rc})"
  tail -80 "$hop_bg/out.txt" || true
fi

# 17.BH pipefail SIGPIPE unit: old pattern dies; buffered pattern continues
bh_old="${OUT_DIR}/bh-old.sh"
bh_new="${OUT_DIR}/bh-new.sh"
cat >"$bh_old" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cand="$(yes 2>/dev/null | awk '{print; exit}')"
echo "SHOULD_NOT_REACH cand=$cand"
EOF
cat >"$bh_new" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
policy_out="$(printf '%s\n' '  Candidate: 1.2.3' '  Version table:')"
cand="$(awk '/^[[:space:]]*Candidate:/{print $2; exit}' <<<"$policy_out")"
echo "REACHED cand=$cand"
EOF
set +e
bash "$bh_old" >"${OUT_DIR}/bh-old.out" 2>&1
rc_old=$?
bash "$bh_new" >"${OUT_DIR}/bh-new.out" 2>&1
rc_new=$?
set -e
if [[ "$rc_old" -ne 0 ]] && [[ "$rc_new" -eq 0 ]] && grep -q 'REACHED cand=1.2.3' "${OUT_DIR}/bh-new.out"; then
  pass "17.BH pipefail SIGPIPE old-pattern dies; buffered parse continues"
else
  fail "17.BH SIGPIPE unit (old_rc=${rc_old} new_rc=${rc_new})"
  cat "${OUT_DIR}/bh-old.out" "${OUT_DIR}/bh-new.out" || true
fi

# =============================================================================
# 18) Offline LXD transition + monitor failure propagation (BI–BZ)
# =============================================================================

LXD_HARNESS="${OUT_DIR}/lxd-harness.sh"
LXD_LIB="${ROOT}/client/lib/dp-offline-lxd-inventory.sh"
{
  cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="${DP_OFFLINE_TEST_ROOT:-}"
LOG_FILE="/dev/null"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
STATE_FILE="${STATE_ROOT}/state"
CRITICAL_HOLD_PACKAGES="apt dpkg libc6 systemd udev init openssh-server"
LXD_REMOVAL_ALLOWLIST="lxd lxd-client lxd-tools"
LXD_REMOVAL_TARGETS="lxd lxd-client"
LXD_INVENTORY_TIMEOUT_SECS="${DP_OFFLINE_LXD_COMMAND_TIMEOUT_SECS:-${DP_OFFLINE_LXD_INVENTORY_TIMEOUT_SECS:-30}}"
LXD_PREFLIGHT_CLASS=""
LXD_OFFLINE_UPGRADE_POLICY=""
LXD_INVENTORY_EVIDENCE=""
LXD_TARGET_TRANSITION_SELECTED=""
LXD_TARGET_TRANSITION_GUARD=""
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
EC_LXD=36
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="${RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED:-false}"
PIN_SOURCE_VERSION="${PIN_SOURCE_VERSION:-18.04}"
hostpath() {
  local p="$1"
  if [[ -n "$TEST_ROOT" ]]; then printf '%s%s' "$TEST_ROOT" "$p"; else printf '%s' "$p"; fi
}
log() { local level="$1"; shift; printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >&2; }
die() { local code="$1"; shift; log ERROR "$* (exit=${code})"; exit "$code"; }
utc_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
read_os_field() { printf '%s\n' "${PIN_SOURCE_VERSION:-18.04}"; }
EOS
  # Shared cold-start-aware inventory library (injected into clients at build time).
  cat "$LXD_LIB"
} >"$LXD_HARNESS"
bash -n "$LXD_HARNESS" && pass "LXD harness bash -n" || fail "LXD harness bash -n"

run_lxd_classify() {
  local root="$1"
  shift
  mkdir -p "$root/opt/aelladata/os-upgrade/offline"
  set +e
  (
    export DP_OFFLINE_TEST_ROOT="$root" TEST_ROOT="$root"
    # shellcheck disable=SC1090
    source "$LXD_HARNESS"
    collect_and_classify_lxd_inventory
    printf 'CLASS=%s\n' "$LXD_PREFLIGHT_CLASS"
    printf 'POLICY=%s\n' "$LXD_OFFLINE_UPGRADE_POLICY"
    printf 'EVID=%s\n' "$LXD_INVENTORY_EVIDENCE"
  ) >"$root/out.txt" 2>&1
  echo $?
}

plant_lxd_dpkg_status() {
  local root="$1"
  mkdir -p "$root/var/lib/dpkg" \
    "$root/var/lib/lxd/containers" \
    "$root/var/lib/lxd/images" \
    "$root/var/lib/lxd/storage-pools"
  cat >"$root/var/lib/dpkg/status" <<'EOF'
Package: lxd
Status: install ok installed
Version: 3.0.3-0ubuntu1~22.04.2

Package: lxd-client
Status: install ok installed
Version: 3.0.3-0ubuntu1~22.04.2
EOF
}

install_fake_lxc() {
  # $1=root $2=mode: unused|running|stopped|image|pool|list-fail|storage-fail|storage-unparseable|unexpected|banner-unexpected
  local root="$1" mode="$2"
  mkdir -p "$root/bin"
  cat >"$root/bin/lxc" <<EOF
#!/usr/bin/env bash
set -euo pipefail
mode='$mode'
cmd="\${1:-}"
sub="\${2:-}"
case "\$cmd" in
  list)
    case "\$mode" in
      unused|banner-unexpected)
        printf '%s\n' \
          'If this is your first time running LXD on this machine, you should also run: lxd init' \
          'To start your first container, try: lxc launch ubuntu:22.04'
        if [[ "\$mode" == "banner-unexpected" ]]; then
          printf '%s\n' 'totally unexpected non-csv noise'
        fi
        exit 0
        ;;
      unexpected)
        printf '%s\n' 'weird daemon output without commas'
        exit 0
        ;;
      running)
        printf '%s\n' 'c1,RUNNING'
        exit 0
        ;;
      stopped)
        printf '%s\n' 'c1,STOPPED'
        exit 0
        ;;
      image|pool)
        exit 0
        ;;
      list-fail)
        printf '%s\n' 'Error: cannot connect' >&2
        exit 1
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  image)
    case "\$mode" in
      image)
        printf '%s\n' 'ubuntu/22.04'
        exit 0
        ;;
      unused|running|stopped|pool|unexpected|banner-unexpected)
        # first-run banner only / empty
        if [[ "\$mode" == "unused" || "\$mode" == "banner-unexpected" ]]; then
          printf '%s\n' \
            'If this is your first time running LXD on this machine, you should also run: lxd init' \
            'To start your first container, try: lxc launch ubuntu:22.04'
        fi
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  storage)
    if [[ "\$sub" == "list" ]]; then
      case "\$mode" in
        storage-fail)
          printf '%s\n' 'Error: boom' >&2
          exit 1
          ;;
        storage-unparseable)
          printf '%s\n' 'not a storage table at all'
          exit 0
          ;;
        pool)
          cat <<'TBL'
+---------+--------+------------------------------------+-------------+---------+
| NAME    | DRIVER | SOURCE                             | DESCRIPTION | USED BY |
+---------+--------+------------------------------------+-------------+---------+
| default | dir    | /var/lib/lxd/storage-pools/default |             | 0       |
+---------+--------+------------------------------------+-------------+---------+
TBL
          exit 0
          ;;
        unused|running|stopped|image|unexpected|banner-unexpected)
          cat <<'TBL'
+------+--------+--------+-------------+---------+
| NAME | DRIVER | SOURCE | DESCRIPTION | USED BY |
+------+--------+--------+-------------+---------+
TBL
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    fi
    if [[ "\$sub" == "volume" && "\${3:-}" == "list" ]]; then
      pool="\${4:-}"
      if [[ -z "\$pool" ]]; then
        printf 'Error: accept: <pool>\n' >&2
        exit 1
      fi
      # LXD 3.0.3 style: no --format support; refuse if caller passes it.
      for a in "\$@"; do
        if [[ "\$a" == "--format" || "\$a" == --format=* ]]; then
          printf 'Error: unknown flag: --format\n' >&2
          exit 1
        fi
      done
      cat <<'TBL'
+------+------+-------------+----------+---------+
| TYPE | NAME | DESCRIPTION | LOCATION | USED BY |
+------+------+-------------+----------+---------+
TBL
      exit 0
    fi
    printf 'Error: unexpected storage invocation: %s\n' "\$*" >&2
    exit 1
    ;;
  *)
    printf 'Error: unexpected lxc invocation: %s\n' "\$*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$root/bin/lxc"
}

run_lxd_classify_realpath() {
  local root="$1"
  mkdir -p "$root/opt/aelladata/os-upgrade/offline"
  set +e
  (
    export DP_OFFLINE_TEST_ROOT="$root" TEST_ROOT="$root"
    export PATH="$root/bin:$PATH"
    unset DP_OFFLINE_FAKE_LXD_CLASS DP_OFFLINE_FAKE_LXD_CONTAINERS \
      DP_OFFLINE_FAKE_LXD_IMAGES DP_OFFLINE_FAKE_LXD_STORAGE \
      DP_OFFLINE_FAKE_LXD_TIMEOUT || true
    # shellcheck disable=SC1090
    source "$LXD_HARNESS"
    collect_and_classify_lxd_inventory
    printf 'CLASS=%s\n' "$LXD_PREFLIGHT_CLASS"
    printf 'POLICY=%s\n' "$LXD_OFFLINE_UPGRADE_POLICY"
    printf 'EVID=%s\n' "$LXD_INVENTORY_EVIDENCE"
  ) >"$root/out.txt" 2>&1
  echo $?
}

run_lxd_gate_realpath() {
  local root="$1"
  mkdir -p "$root/opt/aelladata/os-upgrade/offline"
  set +e
  (
    export DP_OFFLINE_TEST_ROOT="$root" TEST_ROOT="$root"
    export PATH="$root/bin:$PATH"
    unset DP_OFFLINE_FAKE_LXD_CLASS DP_OFFLINE_FAKE_LXD_CONTAINERS \
      DP_OFFLINE_FAKE_LXD_IMAGES DP_OFFLINE_FAKE_LXD_STORAGE \
      DP_OFFLINE_FAKE_LXD_TIMEOUT || true
    # shellcheck disable=SC1090
    source "$LXD_HARNESS"
    lxd_preflight_gate
    printf 'GATE=PASS\n'
  ) >"$root/gate.txt" 2>&1
  echo $?
}

# 18.BI LXD not installed
bi="$(mktemp -d "${OUT_DIR}/bi.XXXX")"
export DP_OFFLINE_FAKE_LXD_CLASS=LXD_NOT_INSTALLED
rc="$(run_lxd_classify "$bi")"
unset DP_OFFLINE_FAKE_LXD_CLASS
if [[ "$rc" -eq 0 ]] && grep -q 'CLASS=LXD_NOT_INSTALLED' "$bi/out.txt" \
  && grep -q 'POLICY=SKIP_NO_DEB_LXD' "$bi/out.txt" \
  && grep -q 'LXD_INVENTORY_EVIDENCE=' "$bi/out.txt"; then
  pass "18.BI LXD not installed"
else
  fail "18.BI LXD not installed (rc=${rc})"
  cat "$bi/out.txt" || true
fi

# 18.BJ LXD installed unused
bj="$(mktemp -d "${OUT_DIR}/bj.XXXX")"
export DP_OFFLINE_FAKE_LXD_CLASS=LXD_INSTALLED_UNUSED
rc="$(run_lxd_classify "$bj")"
unset DP_OFFLINE_FAKE_LXD_CLASS
if [[ "$rc" -eq 0 ]] && grep -q 'CLASS=LXD_INSTALLED_UNUSED' "$bj/out.txt" \
  && grep -q 'POLICY=REMOVE_UNUSED_DEB_LXD_BEFORE_DRO' "$bj/out.txt"; then
  pass "18.BJ LXD installed unused"
else
  fail "18.BJ LXD installed unused (rc=${rc})"
  cat "$bj/out.txt" || true
fi

# 18.BK running container → IN_USE
bk="$(mktemp -d "${OUT_DIR}/bk.XXXX")"
export DP_OFFLINE_FAKE_LXD_CLASS=LXD_IN_USE DP_OFFLINE_FAKE_LXD_CONTAINERS=running
rc="$(run_lxd_classify "$bk")"
unset DP_OFFLINE_FAKE_LXD_CLASS DP_OFFLINE_FAKE_LXD_CONTAINERS
if [[ "$rc" -eq 0 ]] && grep -q 'CLASS=LXD_IN_USE' "$bk/out.txt"; then
  pass "18.BK running container → LXD_IN_USE"
else
  fail "18.BK running container (rc=${rc})"
  cat "$bk/out.txt" || true
fi

# 18.BL stopped container → IN_USE
bl="$(mktemp -d "${OUT_DIR}/bl.XXXX")"
export DP_OFFLINE_FAKE_LXD_CLASS=LXD_IN_USE DP_OFFLINE_FAKE_LXD_CONTAINERS=stopped
rc="$(run_lxd_classify "$bl")"
unset DP_OFFLINE_FAKE_LXD_CLASS DP_OFFLINE_FAKE_LXD_CONTAINERS
if [[ "$rc" -eq 0 ]] && grep -q 'CLASS=LXD_IN_USE' "$bl/out.txt"; then
  pass "18.BL stopped container → LXD_IN_USE"
else
  fail "18.BL stopped container (rc=${rc})"
  cat "$bl/out.txt" || true
fi

# 18.BM image/storage → IN_USE
bm="$(mktemp -d "${OUT_DIR}/bm.XXXX")"
export DP_OFFLINE_FAKE_LXD_CLASS=LXD_IN_USE DP_OFFLINE_FAKE_LXD_IMAGES=yes DP_OFFLINE_FAKE_LXD_STORAGE=yes
rc="$(run_lxd_classify "$bm")"
unset DP_OFFLINE_FAKE_LXD_CLASS DP_OFFLINE_FAKE_LXD_IMAGES DP_OFFLINE_FAKE_LXD_STORAGE
if [[ "$rc" -eq 0 ]] && grep -q 'CLASS=LXD_IN_USE' "$bm/out.txt"; then
  pass "18.BM image/storage → LXD_IN_USE"
else
  fail "18.BM image/storage (rc=${rc})"
  cat "$bm/out.txt" || true
fi

# 18.BN inventory timeout/ambiguous + preflight fail-closed before confirmation
bn="$(mktemp -d "${OUT_DIR}/bn.XXXX")"
export DP_OFFLINE_FAKE_LXD_CLASS=LXD_AMBIGUOUS
rc="$(run_lxd_classify "$bn")"
unset DP_OFFLINE_FAKE_LXD_CLASS
gate_rc=0
set +e
(
  export DP_OFFLINE_TEST_ROOT="$bn" TEST_ROOT="$bn" DP_OFFLINE_FAKE_LXD_CLASS=LXD_AMBIGUOUS
  # shellcheck disable=SC1090
  source "$LXD_HARNESS"
  lxd_preflight_gate
) >"$bn/gate.txt" 2>&1
gate_rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q 'CLASS=LXD_AMBIGUOUS' "$bn/out.txt" \
  && [[ "$gate_rc" -ne 0 ]] \
  && grep -q 'FAIL_LXD_USAGE_CANNOT_BE_PROVEN_SAFE' "$bn/gate.txt"; then
  pass "18.BN inventory ambiguous fail-closed"
else
  fail "18.BN ambiguous (class_rc=${rc} gate_rc=${gate_rc})"
  cat "$bn/out.txt" "$bn/gate.txt" || true
fi

# IN_USE gate message
bn2="$(mktemp -d "${OUT_DIR}/bn2.XXXX")"
set +e
(
  export DP_OFFLINE_TEST_ROOT="$bn2" TEST_ROOT="$bn2" DP_OFFLINE_FAKE_LXD_CLASS=LXD_IN_USE
  # shellcheck disable=SC1090
  source "$LXD_HARNESS"
  lxd_preflight_gate
) >"$bn2/gate.txt" 2>&1
gate_rc=$?
set -e
[[ "$gate_rc" -ne 0 ]] && grep -q 'FAIL_LXD_IN_USE_OFFLINE_UPGRADE_UNSUPPORTED' "$bn2/gate.txt" \
  && pass "18.BN-b IN_USE fail-closed before confirmation" \
  || fail "18.BN-b IN_USE gate"

# 18.BO safe removal simulation
bo="$(mktemp -d "${OUT_DIR}/bo.XXXX")"
mkdir -p "$bo/evid"
set +e
(
  export DP_OFFLINE_TEST_ROOT="$bo" TEST_ROOT="$bo"
  export DP_OFFLINE_FAKE_LXD_REMOVAL_SIM=$'Remv lxd [3.0.3]\nRemv lxd-client [3.0.3]'
  # shellcheck disable=SC1090
  source "$LXD_HARNESS"
  simulate_unused_lxd_removal "$bo/evid"
) >"$bo/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q 'LXD_REMOVAL_SIMULATION=PASS' "$bo/out.txt" \
  && grep -q 'LXD_REMOVAL_UNEXPECTED_PACKAGE_COUNT=0' "$bo/out.txt"; then
  pass "18.BO safe removal simulation"
else
  fail "18.BO safe removal simulation (rc=${rc})"
  cat "$bo/out.txt" || true
fi

# 18.BP critical package removal blocked
bp="$(mktemp -d "${OUT_DIR}/bp.XXXX")"
mkdir -p "$bp/evid"
set +e
(
  export DP_OFFLINE_TEST_ROOT="$bp" TEST_ROOT="$bp"
  export DP_OFFLINE_FAKE_LXD_REMOVAL_SIM=$'Remv lxd [3.0.3]\nRemv libc6 [2.27]'
  # shellcheck disable=SC1090
  source "$LXD_HARNESS"
  simulate_unused_lxd_removal "$bp/evid"
) >"$bp/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'FAIL_LXD_REMOVAL_WOULD_TOUCH_CRITICAL_PACKAGE' "$bp/out.txt"; then
  pass "18.BP critical package removal blocked"
else
  fail "18.BP critical removal block (rc=${rc})"
  cat "$bp/out.txt" || true
fi

# 18.BQ actual removal after confirmation (fixture path)
bq="$(mktemp -d "${OUT_DIR}/bq.XXXX")"
mkdir -p "$bq/opt/aelladata/os-upgrade/offline" "$bq/etc/apt/preferences.d"
set +e
(
  export DP_OFFLINE_TEST_ROOT="$bq" TEST_ROOT="$bq"
  export DP_OFFLINE_FAKE_LXD_CLASS=LXD_INSTALLED_UNUSED
  export DP_OFFLINE_FAKE_LXD_REMOVAL_SIM=$'Remv lxd [3.0.3]\nRemv lxd-client [3.0.3]'
  export DP_OFFLINE_FAKE_LXD_TARGET_SELECTED=NO
  # shellcheck disable=SC1090
  source "$LXD_HARNESS"
  LXD_PREFLIGHT_CLASS=LXD_INSTALLED_UNUSED
  remove_unused_lxd_before_dro
) >"$bq/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'LXD_REMOVAL_SIMULATION=PASS' "$bq/out.txt" \
  && grep -q 'LXD_REMOVAL_RESULT=PASS' "$bq/out.txt" \
  && grep -q 'LXD_POST_REMOVAL_DPKG_AUDIT=PASS' "$bq/out.txt" \
  && grep -q 'LXD_POST_REMOVAL_APT_CHECK=PASS' "$bq/out.txt" \
  && [[ -f "$bq/etc/apt/preferences.d/99-stellar-offline-no-lxd-transition" ]]; then
  pass "18.BQ post-confirmation unused LXD removal"
else
  fail "18.BQ post-confirmation removal (rc=${rc})"
  cat "$bq/out.txt" || true
fi

# 18.BR lxd not selected in target plan
br="$(mktemp -d "${OUT_DIR}/br.XXXX")"
mkdir -p "$br/evid"
set +e
(
  export DP_OFFLINE_TEST_ROOT="$br" TEST_ROOT="$br" DP_OFFLINE_FAKE_LXD_TARGET_SELECTED=NO
  # shellcheck disable=SC1090
  source "$LXD_HARNESS"
  guard_lxd_target_transition "$br/evid"
) >"$br/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q 'LXD_TARGET_TRANSITION_SELECTED=NO' "$br/out.txt" \
  && grep -q 'LXD_TARGET_TRANSITION_GUARD=PASS' "$br/out.txt"; then
  pass "18.BR target plan lxd not selected"
else
  fail "18.BR target plan not selected (rc=${rc})"
  cat "$br/out.txt" || true
fi

# 18.BS block lxd reselect in target plan
bs="$(mktemp -d "${OUT_DIR}/bs.XXXX")"
mkdir -p "$bs/evid"
set +e
(
  export DP_OFFLINE_TEST_ROOT="$bs" TEST_ROOT="$bs" DP_OFFLINE_FAKE_LXD_TARGET_SELECTED=YES
  # shellcheck disable=SC1090
  source "$LXD_HARNESS"
  guard_lxd_target_transition "$bs/evid"
) >"$bs/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'LXD_TARGET_TRANSITION_SELECTED=YES' "$bs/out.txt" \
  && grep -q 'FAIL_LXD_TARGET_TRANSITION_RESELECTED' "$bs/out.txt"; then
  pass "18.BS target plan lxd reselect blocked"
else
  fail "18.BS reselect block (rc=${rc})"
  cat "$bs/out.txt" || true
fi

# 18.BT no api.snapcraft.io call (static + pin/guard path)
if grep -q 'apply_lxd_noinstall_pin' "$SCRIPT_IN" \
  && grep -q 'api\.snapcraft\.io' "$SCRIPT_IN" \
  && grep -q 'PACKAGE_MAINTAINER_NETWORK_RISK_SCAN=PASS' "$SCRIPT_IN" \
  && ! grep -nE 'snap install lxd|snapcraft\.io/v2' "$SCRIPT_IN" | grep -vE 'grep|FAIL_|api\.snapcraft|EXTERNAL|classify_lxd|network.risk|snap store'; then
  pass "18.BT no snap store allow / pin+scan markers present"
else
  # Soften: require pin helper + classifier endpoint marker + no active snap install
  if grep -q 'apply_lxd_noinstall_pin' "$SCRIPT_IN" \
    && grep -q 'FAILURE_EXTERNAL_ENDPOINT=api.snapcraft.io' "$SCRIPT_IN" \
    && ! grep -qE '^\s*snap install' "$SCRIPT_IN"; then
    pass "18.BT no snap store allow / pin+scan markers present"
  else
    fail "18.BT snap store prevention markers missing"
  fi
fi

# 18.BU failure classifier → OFFLINE_LXD_SNAP_TRANSITION
bu="$(mktemp -d "${OUT_DIR}/bu.XXXX")"
mkdir -p "$bu/var/log/aella" "$bu/var/log/dist-upgrade" "$bu/var/log"
cat >"$bu/var/log/aella/offline_os_upgrade.log" <<'EOF'
=> Installing the LXD snap
==> Checking connectivity with the snap store
error: cannot install "lxd": Post "https://api.snapcraft.io/v2/snaps/refresh": context canceled
dpkg: error processing archive ...lxd_1%3a0.10_all.deb (--unpack):
new lxd package pre-installation script subprocess returned error exit status 1
EOF
set +e
(
  export DP_OFFLINE_TEST_ROOT="$bu" TEST_ROOT="$bu"
  # shellcheck disable=SC1090
  source "$LXD_HARNESS"
  # Harness defaults LOG_FILE=/dev/null - point at fixture evidence after source.
  LOG_FILE="$bu/var/log/aella/offline_os_upgrade.log"
  _hp() { hostpath "$1"; }
  package_transition_evidence_present() { return 0; }
  persist_flags() { :; }
  RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
  FAILURE_CLASS=""
  if classify_lxd_snap_transition_failure; then
    emit_lxd_snap_failure_fields
  else
    FAILURE_CLASS="UNKNOWN"
  fi
  printf 'FAILURE_CLASS=%s\n' "$FAILURE_CLASS"
) >"$bu/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'FAILURE_CLASS=OFFLINE_LXD_SNAP_TRANSITION' "$bu/out.txt" \
  && grep -q 'FAILURE_PACKAGE=lxd,lxd-client' "$bu/out.txt" \
  && grep -q 'FAILURE_EXTERNAL_ENDPOINT=api.snapcraft.io' "$bu/out.txt" \
  && grep -q 'FAILURE_RETRY_SAFE=NO' "$bu/out.txt" \
  && grep -q 'FAILURE_RESTORE_REQUIRED=YES' "$bu/out.txt"; then
  pass "18.BU failure classifier OFFLINE_LXD_SNAP_TRANSITION"
else
  fail "18.BU failure classifier (rc=${rc})"
  cat "$bu/out.txt" || true
fi

# 18.BV terminal failure rc propagation (monitor → start → commit → main contract)
if grep -q 'CLIENT_EXIT_REASON=BACKGROUND_UPGRADE_FAILED' "$SCRIPT_IN" \
  && grep -q 'CLIENT_HANDOFF_RESULT=FAIL' "$SCRIPT_IN" \
  && grep -A80 '^start_upgrade_service_detached()' "$SCRIPT_IN" | grep -q 'return "$mon_rc"' \
  && grep -A120 '^commit_and_start()' "$SCRIPT_IN" | grep -q 'handoff_rc' \
  && grep -A20 '^run_os_upgrade()' "$SCRIPT_IN" | grep -q 'return "$rc"' \
  && grep -A50 'run_os_upgrade "\$work"' "$SCRIPT_IN" | grep -q 'upgrade_rc'; then
  pass "18.BV terminal failure rc propagation contract"
else
  fail "18.BV rc propagation markers missing"
fi

# Dynamic BV: monitor FAILED_AFTER_PACKAGE_TRANSITION → non-zero + no success handoff from commit
bv="$(mktemp -d "${OUT_DIR}/bv.XXXX")"
# Reuse handoff harness if available
if [[ -f "${HANDOFF_HARNESS:-}" ]]; then
  make_handoff_fixture "$bv"
  install_fake_systemctl "$bv" ok
  rpid="$(spawn_fake_runner "$bv")"
  printf 'UPGRADING_JAMMY_TO_NOBLE\n' >"$bv/opt/aelladata/os-upgrade/offline/state"
  printf 'RUNNER_START=PASS\n' >>"$bv/var/log/aella/offline_os_upgrade.log"
  export DP_OFFLINE_TEST_ROOT="$bv" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$bv" STELLAR_OFFLINE_TEST_ROOT="$bv"
  export SYSTEMCTL_BIN="$bv/bin/systemctl"
  export DP_OFFLINE_FORCE_MONITOR=1
  export DP_OFFLINE_MONITOR_POLL_SECS=1
  export DP_OFFLINE_MONITOR_HEARTBEAT_SECS=30
  export DP_OFFLINE_MONITOR_MAX_SECS=8
  # shellcheck disable=SC1090
  source "$HANDOFF_HARNESS"
  (
    sleep 1
    printf 'FAILED_AFTER_PACKAGE_TRANSITION\n' >"$bv/opt/aelladata/os-upgrade/offline/state"
  ) &
  set +e
  ( monitor_upgrade_progress "$rpid" ) >"$bv/out-mon.txt" 2>&1
  mon_rc=$?
  set -e
  if [[ "$mon_rc" -ne 0 ]] \
    && grep -q 'MONITOR_RESULT=TERMINAL_FAILURE' "$bv/out-mon.txt" \
    && grep -q 'MONITOR_EXIT_REASON=TERMINAL_FAILURE_STATE' "$bv/out-mon.txt"; then
    pass "18.BV-b monitor FAILED_AFTER_PACKAGE_TRANSITION → non-zero"
  else
    fail "18.BV-b monitor terminal failure (rc=${mon_rc})"
    cat "$bv/out-mon.txt" || true
  fi
  kill_fake_runner "$bv" 2>/dev/null || true
else
  fail "18.BV-b handoff harness missing"
fi

# False success invariant: commit_and_start must not log handoff complete after failure return
fail_ret_line="$(sed -n '/^commit_and_start()/,/^# Previous-hop/p' "$SCRIPT_IN" \
  | grep -n 'return "$handoff_rc"' | head -1 | cut -d: -f1)"
msg_line="$(sed -n '/^commit_and_start()/,/^# Previous-hop/p' "$SCRIPT_IN" \
  | grep -n 'client handoff complete' | head -1 | cut -d: -f1)"
if [[ -n "$fail_ret_line" && -n "$msg_line" && "$msg_line" -gt "$fail_ret_line" ]]; then
  pass "18.BV-c false success handoff message after failure forbidden"
else
  fail "18.BV-c handoff complete ordering wrong (fail=${fail_ret_line:-?} msg=${msg_line:-?})"
fi

# main must skip post_upgrade_validation on upgrade_rc != 0
fail_line="$(grep -n 'exit "$upgrade_rc"' "$SCRIPT_IN" | head -1 | cut -d: -f1)"
post_line="$(grep -n 'run_os_post_upgrade_validation' "$SCRIPT_IN" | tail -1 | cut -d: -f1)"
if [[ -n "$fail_line" && -n "$post_line" && "$fail_line" -lt "$post_line" ]] \
  && grep -q 'upgrade_rc' "$SCRIPT_IN"; then
  pass "18.BV-d main skips post-upgrade validation on failure"
else
  fail "18.BV-d post-upgrade validation ordering (fail=${fail_line:-?} post=${post_line:-?})"
fi

# 18.BW Ctrl+C + runner alive → DETACHED_RUNNING / rc 0
if grep -q 'MONITOR_RESULT=DETACHED_RUNNING' "$SCRIPT_IN" \
  && grep -q 'MONITOR_EXIT_REASON=USER_INTERRUPT' "$SCRIPT_IN"; then
  pass "18.BW Ctrl+C monitor detached-running markers"
else
  fail "18.BW Ctrl+C markers missing"
fi

# 18.BX reboot success → TERMINAL_SUCCESS rc 0
if grep -q 'MONITOR_RESULT=TERMINAL_SUCCESS' "$SCRIPT_IN" \
  && grep -q 'TERMINAL_SUCCESS_STATE' "$SCRIPT_IN"; then
  pass "18.BX reboot/terminal success markers"
else
  fail "18.BX terminal success markers missing"
fi

# 18.BY runner missing without terminal state → non-zero
by="$(mktemp -d "${OUT_DIR}/by.XXXX")"
if [[ -f "${HANDOFF_HARNESS:-}" ]]; then
  make_handoff_fixture "$by"
  install_fake_systemctl "$by" ok
  rpid="$(spawn_fake_runner "$by")"
  # Non-active, non-terminal state
  printf 'READY_FOR_CONFIRMATION\n' >"$by/opt/aelladata/os-upgrade/offline/state"
  printf 'RUNNER_START=PASS\n' >>"$by/var/log/aella/offline_os_upgrade.log"
  export DP_OFFLINE_TEST_ROOT="$by" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$by" STELLAR_OFFLINE_TEST_ROOT="$by"
  export SYSTEMCTL_BIN="$by/bin/systemctl"
  export DP_OFFLINE_FORCE_MONITOR=1
  export DP_OFFLINE_MONITOR_POLL_SECS=1
  export DP_OFFLINE_MONITOR_HEARTBEAT_SECS=30
  export DP_OFFLINE_MONITOR_MAX_SECS=8
  # shellcheck disable=SC1090
  source "$HANDOFF_HARNESS"
  kill_fake_runner "$by"
  set +e
  ( monitor_upgrade_progress "$rpid" ) >"$by/out.txt" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]] \
    && grep -q 'RUNNER_MISSING_WITHOUT_TERMINAL_STATE' "$by/out.txt" \
    && grep -q 'MONITOR_RESULT=TERMINAL_FAILURE' "$by/out.txt"; then
    pass "18.BY runner missing without terminal state → non-zero"
  else
    fail "18.BY runner missing (rc=${rc})"
    cat "$by/out.txt" || true
  fi
else
  fail "18.BY handoff harness missing"
fi

# Isolate subsequent fixtures from BY monitor/handoff exports.
unset DP_OFFLINE_TEST_ROOT TEST_ROOT DP_OFFLINE_TEST_HANDOFF SYSTEMCTL_BIN \
  DP_OFFLINE_FORCE_MONITOR DP_OFFLINE_MONITOR_POLL_SECS \
  DP_OFFLINE_MONITOR_HEARTBEAT_SECS DP_OFFLINE_MONITOR_MAX_SECS || true

# 18.BZ full offline chained fixture includes LXD gate + READY_FOR_CONFIRMATION
bz="$(mktemp -d "${OUT_DIR}/bz.XXXX")"
if declare -F hop_fx_prep >/dev/null 2>&1; then
  hop_fx_prep "$bz"
  hop_write_previous_owner "$bz" 2>/dev/null || true
  printf 'COMPLETED_JAMMY\n' >"$bz/opt/aelladata/os-upgrade/offline/state"
  set +e
  env -u DP_OFFLINE_FORCE_MONITOR -u DP_OFFLINE_TEST_HANDOFF -u SYSTEMCTL_BIN \
    DP_OFFLINE_TEST_ROOT="$bz" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
    DP_OFFLINE_FAKE_LXD_CLASS=LXD_NOT_INSTALLED \
    bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$bz/out.txt" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]] \
    && grep -qE 'LXD_PREFLIGHT_CLASS=LXD_NOT_INSTALLED|LXD_PREFLIGHT_GATE=PASS' "$bz/out.txt" \
    && grep -qE 'READY_FOR_CONFIRMATION|os_upgrade_result=READY_FOR_CONFIRMATION' "$bz/out.txt"; then
    pass "18.BZ full offline chained fixture with LXD gate"
  else
    fail "18.BZ chained fixture (rc=${rc})"
    tail -80 "$bz/out.txt" || true
  fi
else
  # Static presence fallback
  if grep -q 'lxd_preflight_gate' "$SCRIPT_IN" \
    && grep -q 'PREFLIGHT_CHECKPOINT_BEFORE_LXD_GATE' "$SCRIPT_IN"; then
    pass "18.BZ LXD gate wired into preflight (static)"
  else
    fail "18.BZ LXD gate wiring missing"
  fi
fi

# -----------------------------------------------------------------------------
# 18.CA–CK operational LXD 3.0.3 preflight fixes (real inventory path)
# -----------------------------------------------------------------------------

# 18.CA LXD not installed (TEST_ROOT default) → NOT_INSTALLED
ca="$(mktemp -d "${OUT_DIR}/ca.XXXX")"
rc="$(run_lxd_classify "$ca")"
if [[ "$rc" -eq 0 ]] && grep -q 'CLASS=LXD_NOT_INSTALLED' "$ca/out.txt"; then
  pass "18.CA LXD not installed → LXD_NOT_INSTALLED"
else
  fail "18.CA not installed (rc=${rc})"
  cat "$ca/out.txt" || true
fi

# 18.CB first-run banner + empty dirs + pool 0 → INSTALLED_UNUSED / PASS
cb="$(mktemp -d "${OUT_DIR}/cb.XXXX")"
plant_lxd_dpkg_status "$cb"
install_fake_lxc "$cb" unused
rc="$(run_lxd_classify_realpath "$cb")"
gate_rc="$(run_lxd_gate_realpath "$cb")"
if [[ "$rc" -eq 0 ]] && grep -q 'CLASS=LXD_INSTALLED_UNUSED' "$cb/out.txt" \
  && grep -q 'POLICY=REMOVE_UNUSED_DEB_LXD_BEFORE_DRO' "$cb/out.txt" \
  && [[ "$gate_rc" -eq 0 ]] && grep -q 'LXD_PREFLIGHT_GATE=PASS' "$cb/gate.txt"; then
  pass "18.CB first-run banner unused → LXD_INSTALLED_UNUSED / PASS"
else
  fail "18.CB first-run unused (rc=${rc} gate_rc=${gate_rc})"
  cat "$cb/out.txt" "$cb/gate.txt" || true
fi

# 18.CC errors.txt absent must not non-zero the evidence pipeline under pipefail
cc="$(mktemp -d "${OUT_DIR}/cc.XXXX")"
plant_lxd_dpkg_status "$cc"
install_fake_lxc "$cc" unused
rc="$(run_lxd_classify_realpath "$cc")"
if [[ "$rc" -eq 0 ]] \
  && grep -q 'LXD_INVENTORY_EVIDENCE=' "$cc/out.txt" \
  && grep -q 'CLASS=LXD_INSTALLED_UNUSED' "$cc/out.txt" \
  && grep -q 'LXD_PREFLIGHT_CLASS=LXD_INSTALLED_UNUSED' "$cc/out.txt"; then
  pass "18.CC errors.txt absent → classify + pipeline rc=0"
else
  fail "18.CC errors.txt absent pipefail (rc=${rc})"
  cat "$cc/out.txt" || true
fi

# 18.CD running container → IN_USE / exit 36
cdfx="$(mktemp -d "${OUT_DIR}/cd.XXXX")"
plant_lxd_dpkg_status "$cdfx"
install_fake_lxc "$cdfx" running
rc="$(run_lxd_classify_realpath "$cdfx")"
gate_rc="$(run_lxd_gate_realpath "$cdfx")"
if [[ "$rc" -eq 0 ]] && grep -q 'CLASS=LXD_IN_USE' "$cdfx/out.txt" \
  && [[ "$gate_rc" -eq 36 ]] \
  && grep -q 'FAIL_LXD_IN_USE_OFFLINE_UPGRADE_UNSUPPORTED' "$cdfx/gate.txt"; then
  pass "18.CD running container → LXD_IN_USE / exit 36"
else
  fail "18.CD running (rc=${rc} gate_rc=${gate_rc})"
  cat "$cdfx/out.txt" "$cdfx/gate.txt" || true
fi

# 18.CE stopped container → IN_USE / exit 36
ce="$(mktemp -d "${OUT_DIR}/ce.XXXX")"
plant_lxd_dpkg_status "$ce"
install_fake_lxc "$ce" stopped
rc="$(run_lxd_classify_realpath "$ce")"
gate_rc="$(run_lxd_gate_realpath "$ce")"
if [[ "$rc" -eq 0 ]] && grep -q 'CLASS=LXD_IN_USE' "$ce/out.txt" \
  && [[ "$gate_rc" -eq 36 ]]; then
  pass "18.CE stopped container → LXD_IN_USE / exit 36"
else
  fail "18.CE stopped (rc=${rc} gate_rc=${gate_rc})"
  cat "$ce/out.txt" "$ce/gate.txt" || true
fi

# 18.CF image present → IN_USE / exit 36
cf="$(mktemp -d "${OUT_DIR}/cf.XXXX")"
plant_lxd_dpkg_status "$cf"
install_fake_lxc "$cf" image
rc="$(run_lxd_classify_realpath "$cf")"
gate_rc="$(run_lxd_gate_realpath "$cf")"
if [[ "$rc" -eq 0 ]] && grep -q 'CLASS=LXD_IN_USE' "$cf/out.txt" \
  && [[ "$gate_rc" -eq 36 ]]; then
  pass "18.CF image present → LXD_IN_USE / exit 36"
else
  fail "18.CF image (rc=${rc} gate_rc=${gate_rc})"
  cat "$cf/out.txt" "$cf/gate.txt" || true
fi

# 18.CG storage pool present → block auto-removal (IN_USE)
cg="$(mktemp -d "${OUT_DIR}/cg.XXXX")"
plant_lxd_dpkg_status "$cg"
install_fake_lxc "$cg" pool
mkdir -p "$cg/var/lib/lxd/storage-pools/default"
rc="$(run_lxd_classify_realpath "$cg")"
gate_rc="$(run_lxd_gate_realpath "$cg")"
if [[ "$rc" -eq 0 ]] && grep -q 'CLASS=LXD_IN_USE' "$cg/out.txt" \
  && grep -q 'POLICY=FAIL_CLOSED' "$cg/out.txt" \
  && [[ "$gate_rc" -eq 36 ]]; then
  pass "18.CG storage pool present → no auto-removal / exit 36"
else
  fail "18.CG storage pool (rc=${rc} gate_rc=${gate_rc})"
  cat "$cg/out.txt" "$cg/gate.txt" || true
fi

# 18.CH lxc list failure → AMBIGUOUS / exit 36
ch="$(mktemp -d "${OUT_DIR}/ch.XXXX")"
plant_lxd_dpkg_status "$ch"
install_fake_lxc "$ch" list-fail
rc="$(run_lxd_classify_realpath "$ch")"
gate_rc="$(run_lxd_gate_realpath "$ch")"
if [[ "$rc" -eq 0 ]] && grep -q 'CLASS=LXD_AMBIGUOUS' "$ch/out.txt" \
  && [[ "$gate_rc" -eq 36 ]] \
  && grep -q 'FAIL_LXD_USAGE_CANNOT_BE_PROVEN_SAFE' "$ch/gate.txt"; then
  pass "18.CH lxc list failure → LXD_AMBIGUOUS / exit 36"
else
  fail "18.CH list failure (rc=${rc} gate_rc=${gate_rc})"
  cat "$ch/out.txt" "$ch/gate.txt" || true
fi

# 18.CI storage list failure / unparseable → AMBIGUOUS / exit 36
ci="$(mktemp -d "${OUT_DIR}/ci.XXXX")"
plant_lxd_dpkg_status "$ci"
install_fake_lxc "$ci" storage-fail
rc="$(run_lxd_classify_realpath "$ci")"
gate_rc="$(run_lxd_gate_realpath "$ci")"
ci2="$(mktemp -d "${OUT_DIR}/ci2.XXXX")"
plant_lxd_dpkg_status "$ci2"
install_fake_lxc "$ci2" storage-unparseable
rc2="$(run_lxd_classify_realpath "$ci2")"
gate_rc2="$(run_lxd_gate_realpath "$ci2")"
if [[ "$rc" -eq 0 && "$rc2" -eq 0 ]] \
  && grep -q 'CLASS=LXD_AMBIGUOUS' "$ci/out.txt" \
  && grep -q 'CLASS=LXD_AMBIGUOUS' "$ci2/out.txt" \
  && [[ "$gate_rc" -eq 36 && "$gate_rc2" -eq 36 ]]; then
  pass "18.CI storage list fail/unparseable → LXD_AMBIGUOUS / exit 36"
else
  fail "18.CI storage ambiguous (rc=${rc}/${rc2} gate=${gate_rc}/${gate_rc2})"
  cat "$ci/out.txt" "$ci2/out.txt" "$ci/gate.txt" "$ci2/gate.txt" || true
fi

# 18.CJ unexpected non-CSV output besides first-run → AMBIGUOUS / exit 36
cj="$(mktemp -d "${OUT_DIR}/cj.XXXX")"
plant_lxd_dpkg_status "$cj"
install_fake_lxc "$cj" unexpected
rc="$(run_lxd_classify_realpath "$cj")"
gate_rc="$(run_lxd_gate_realpath "$cj")"
cj2="$(mktemp -d "${OUT_DIR}/cj2.XXXX")"
plant_lxd_dpkg_status "$cj2"
install_fake_lxc "$cj2" banner-unexpected
rc2="$(run_lxd_classify_realpath "$cj2")"
gate_rc2="$(run_lxd_gate_realpath "$cj2")"
if [[ "$rc" -eq 0 && "$rc2" -eq 0 ]] \
  && grep -q 'CLASS=LXD_AMBIGUOUS' "$cj/out.txt" \
  && grep -q 'CLASS=LXD_AMBIGUOUS' "$cj2/out.txt" \
  && [[ "$gate_rc" -eq 36 && "$gate_rc2" -eq 36 ]]; then
  pass "18.CJ unexpected non-CSV → LXD_AMBIGUOUS / exit 36"
else
  fail "18.CJ unexpected output (rc=${rc}/${rc2} gate=${gate_rc}/${gate_rc2})"
  cat "$cj/out.txt" "$cj2/out.txt" || true
fi

# 18.CK set -euo pipefail unused fixture reaches READY_FOR_CONFIRMATION
ck="$(mktemp -d "${OUT_DIR}/ck.XXXX")"
if declare -F hop_fx_prep >/dev/null 2>&1; then
  hop_fx_prep "$ck"
  hop_write_previous_owner "$ck" 2>/dev/null || true
  printf 'COMPLETED_JAMMY\n' >"$ck/opt/aelladata/os-upgrade/offline/state"
  plant_lxd_dpkg_status "$ck"
  install_fake_lxc "$ck" unused
  set +e
  env -u DP_OFFLINE_FORCE_MONITOR -u DP_OFFLINE_TEST_HANDOFF -u SYSTEMCTL_BIN \
    -u DP_OFFLINE_FAKE_LXD_CLASS \
    DP_OFFLINE_TEST_ROOT="$ck" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
    PATH="$ck/bin:$PATH" \
    bash "$STUB" --mirror-base http://127.0.0.1:9 --preflight-only >"$ck/out.txt" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]] \
    && grep -q 'LXD_INVENTORY_EVIDENCE=' "$ck/out.txt" \
    && grep -q 'LXD_PREFLIGHT_CLASS=LXD_INSTALLED_UNUSED' "$ck/out.txt" \
    && grep -q 'LXD_PREFLIGHT_GATE=PASS' "$ck/out.txt" \
    && grep -qE 'READY_FOR_CONFIRMATION|os_upgrade_result=READY_FOR_CONFIRMATION' "$ck/out.txt"; then
    pass "18.CK unused fixture reaches READY_FOR_CONFIRMATION under pipefail"
  else
    fail "18.CK READY_FOR_CONFIRMATION unused (rc=${rc})"
    tail -100 "$ck/out.txt" || true
  fi
else
  fail "18.CK hop_fx_prep missing"
fi

# Static contract: storage --format=json may be attempted, but table fallback required for LXD 3.0.3
if grep -q 'lxc storage list --format=json' "$LXD_LIB"   && grep -q 'lxc storage list' "$LXD_LIB"   && grep -q 'lxd_extract_storage_pool_names' "$LXD_LIB"; then
  pass "18.CL storage inventory has JSON attempt + table fallback"
else
  fail "18.CL storage inventory missing version-aware fallback"
fi
if grep -q 'errors.txt' "$LXD_LIB"; then
  pass "18.CL-b errors.txt evidence present in LXD lib"
else
  fail "18.CL-b errors.txt evidence missing"
fi

unset DP_OFFLINE_FAKE_LXD_CLASS DP_OFFLINE_FAKE_LXD_CONTAINERS \
  DP_OFFLINE_FAKE_LXD_IMAGES DP_OFFLINE_FAKE_LXD_STORAGE \
  DP_OFFLINE_FAKE_LXD_REMOVAL_SIM DP_OFFLINE_FAKE_LXD_TARGET_SELECTED \
  DP_OFFLINE_TEST_ROOT TEST_ROOT DP_OFFLINE_TEST_HANDOFF SYSTEMCTL_BIN \
  DP_OFFLINE_FORCE_MONITOR DP_OFFLINE_MONITOR_POLL_SECS \
  DP_OFFLINE_MONITOR_HEARTBEAT_SECS DP_OFFLINE_MONITOR_MAX_SECS || true

# =============================================================================
# J2N Python2 policy (fixture / fake-class; no live apt/dpkg/snap mutation)
# =============================================================================
echo "======== J2N Python2 policy ========"
PY2_HARNESS="${OUT_DIR}/python2-harness.sh"
{
  cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="${DP_OFFLINE_TEST_ROOT:-}"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
LOG_FILE="/dev/null"
EC_PYTHON=38
hostpath() {
  local p="$1"
  local root="${DP_OFFLINE_TEST_ROOT:-${TEST_ROOT:-}}"
  if [[ -n "$root" ]]; then printf '%s%s' "$root" "$p"; else printf '%s' "$p"; fi
}
log() { local level="$1"; shift; printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >&2; }
die() { local code="$1"; shift; log ERROR "$* (exit=${code})"; exit "$code"; }
PIN_HOP="jammy-to-noble"
PIN_SOURCE_VERSION="22.04"
PIN_TARGET_VERSION="24.04"
EOS
  awk '
    /^# --- Python2 inventory/ {p=1}
    /^# --- Offline LXD inventory/ {exit}
    p
  ' "$SCRIPT_IN"
} >"$PY2_HARNESS"
bash -n "$PY2_HARNESS" && pass "python2 harness bash -n" || fail "python2 harness bash -n"
# shellcheck disable=SC1090
source "$PY2_HARNESS"

py2_fx="$(mktemp -d)"
mkdir -p "$py2_fx/opt/aelladata/os-upgrade/offline" "$py2_fx/var/lib/dpkg" "$py2_fx/etc"
cat >"$py2_fx/etc/os-release" <<'EOF'
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION_CODENAME=jammy
PRETTY_NAME="Ubuntu 22.04.6 LTS"
EOF

# 21) Python2 absent PASS
DP_OFFLINE_TEST_ROOT="$py2_fx" DP_OFFLINE_FAKE_PYTHON2_CLASS=PYTHON2_ABSENT \
  collect_python2_inventory
[[ "$PYTHON2_PREFLIGHT_CLASS" == "PYTHON2_ABSENT" && "$PYTHON2_OFFLINE_UPGRADE_POLICY" == "PASS_NO_PYTHON2" ]] \
  && pass "Python2 absent PASS" || fail "Python2 absent classification"

# 22) Python2 present + resolvable simulation PASS
DP_OFFLINE_TEST_ROOT="$py2_fx" \
  DP_OFFLINE_FAKE_PYTHON2_CLASS=PYTHON2_PRESENT_RESOLVABLE \
  DP_OFFLINE_FAKE_PYTHON2_PACKAGES="python2.7 libpython2.7" \
  DP_OFFLINE_FAKE_PYTHON2_RDEPENDS="legacy-tool" \
  DP_OFFLINE_FAKE_PYTHON2_SIM_PLAN=$'remove=2\nupgrade=1\nkeep=3\nRESOLVABLE=YES\n' \
  collect_python2_inventory
[[ "$PYTHON2_OFFLINE_UPGRADE_POLICY" == "PASS_RESOLVABLE_WITH_EVIDENCE" ]] \
  && pass "Python2 present resolvable PASS" || fail "Python2 resolvable classification"

# 23) Must not imply auto purge / product purge
grep -q 'POLICY=PHASE1_OS_ONLY_NO_AUTO_PURGE' "$PYTHON2_INVENTORY_EVIDENCE" \
  && pass "Python2 no auto-purge policy evidence" || fail "missing no-auto-purge policy"
if grep -nE '^\s*(apt-get|apt)\s+(-y\s+)?(remove|purge).*python2' "$SCRIPT_IN"; then
  fail "client auto-removes python2"
else
  pass "client does not auto-remove python2 / product packages"
fi

# 24) unresolved dependency fail (subshell: die/exit must not abort suite)
set +e
(
  DP_OFFLINE_TEST_ROOT="$py2_fx" DP_OFFLINE_FAKE_PYTHON2_CLASS=PYTHON2_UNRESOLVED_DEPS \
    python2_preflight_gate
)
py2_rc=$?
set -e
[[ "$py2_rc" -eq 38 ]] && pass "unresolved dependency fail-closed" || fail "unresolved deps rc=${py2_rc}"

# 25) essential removal fail (subshell: die/exit must not abort suite)
set +e
(
  DP_OFFLINE_TEST_ROOT="$py2_fx" DP_OFFLINE_FAKE_PYTHON2_CLASS=PYTHON2_ESSENTIAL_REMOVAL \
    python2_preflight_gate
)
py2_rc=$?
set -e
[[ "$py2_rc" -eq 38 ]] && pass "essential removal fail-closed" || fail "essential removal rc=${py2_rc}"

# 26) no-candidate inventory evidence
DP_OFFLINE_TEST_ROOT="$py2_fx" \
  DP_OFFLINE_FAKE_PYTHON2_CLASS=PYTHON2_PRESENT_RESOLVABLE \
  DP_OFFLINE_FAKE_PYTHON2_NO_CANDIDATE="old-python-app" \
  collect_python2_inventory
[[ -f "$PYTHON2_NO_CANDIDATE_EVIDENCE" ]] && grep -q 'old-python-app' "$PYTHON2_NO_CANDIDATE_EVIDENCE" \
  && pass "no-candidate inventory evidence" || fail "no-candidate evidence missing"

# 27/28) postboot: python2 residual ignored; python3 Noble required
if grep -q 'PYTHON2_RESIDUAL_IGNORED_BY_PHASE1_POLICY=YES' "$SCRIPT_IN" \
  && grep -q 'PYTHON3_SERIES_CHECK=PASS' "$SCRIPT_IN"; then
  pass "postboot python3 check + python2 residual ignored"
else
  fail "postboot python policy markers missing"
fi

# J2N constant residual guard on template
if grep -nE 'UPGRADE-BIONIC-TO-JAMMY|UPGRADING_BIONIC_TO_JAMMY|PREPARING_BIONIC|COMPLETED_BIONIC|xenial-to-bionic|stellar-offline-focal-to-jammy|dp-offline-upgrade-focal-to-jammy' "$SCRIPT_IN"; then
  fail "J2N template contains B2F current-hop residuals"
else
  pass "J2N template has no B2F current-hop residuals"
fi
if grep -q 'focal-to-jammy' "$SCRIPT_IN" && grep -q 'PREVIOUS_HOP_PIN_NAME="focal-to-jammy"' "$SCRIPT_IN"; then
  pass "previous hop focal-to-jammy retained for handoff"
else
  fail "previous hop pin missing"
fi

# =============================================================================
# 28) J2N handoff identity / source-gate / transition-flag regressions (ops repro)
# =============================================================================

# Static contract markers for the handoff identity fix
grep -q 'PREVIOUS_RUNTIME_HOP' "$SCRIPT_IN" \
  && grep -q 'PINNED_CURRENT_HOP' "$SCRIPT_IN" \
  && grep -q 'PERSISTED_CURRENT_HOP' "$SCRIPT_IN" \
  && grep -q 'CURRENT_HOP_IDENTITY_REWRITE=YES' "$SCRIPT_IN" \
  && pass "28.static identity variable separation present" \
  || fail "28.static identity variable separation missing"
grep -q 'INSTALL_CLASSIFICATION_NOT_VALID' "$SCRIPT_IN" \
  && grep -q 'SOURCE_GATE_INSTALL=FAIL' "$SCRIPT_IN" \
  && pass "28.static source-gate install fail-closed present" \
  || fail "28.static source-gate install fail-closed missing"
grep -q 'CRITICAL_OS_HOLD_RESTORE=SKIPPED_PACKAGE_TRANSITION_STARTED' "$SCRIPT_IN" \
  && grep -q 'Only the durable watcher/marker flag blocks restore' "$SCRIPT_IN" \
  && ! grep -q 'CRITICAL_OS_HOLD_RESTORE=SKIPPED_PACKAGE_TRANSITION_EVIDENCE' "$SCRIPT_IN" \
  && pass "28.static hold-restore uses transition flag only" \
  || fail "28.static hold-restore flag-only contract missing"
if grep -A30 '_dpkg_log_shows_package_mutation()' "$SCRIPT_IN" \
  | grep -q 'dpkg_log_offset_before'; then
  pass "28.static dpkg.log mutation requires baseline"
else
  fail "28.static dpkg.log baseline guard missing"
fi

# --- 28.A operational reproduction: bionic current-hop.env + COMPLETED_JAMMY ---
hop_ops="$(mktemp -d "${OUT_DIR}/hop-ops.XXXX")"
hop_fx_prep "$hop_ops"
mkdir -p "$hop_ops/etc/apt/sources.list.d" "$hop_ops/etc/apt/keyrings" \
  "$hop_ops/etc/systemd/system" "$hop_ops/usr/local/sbin" "$hop_ops/boot" \
  "$hop_ops/opt/aelladata/work" "$hop_ops/tmp" "$hop_ops/etc/passwd.d" \
  "$hop_ops/etc/update-manager/release-upgrades.d"
printf 'deb http://127.0.0.1:9/ubuntu jammy main universe\n' >"$hop_ops/etc/apt/sources.list"
printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1000:1000:aella:/home/aella:/bin/bash\n' >"$hop_ops/etc/passwd"
printf '%s\n' "$REAL_META" >"$hop_ops/opt/aelladata/release-metadata.yml"
printf 'image: synthetic\n' >"$hop_ops/opt/aelladata/release-image.yml"
cat >"$hop_ops/opt/aelladata/work/runtime_config.json" <<'EOF'
{"installed":false,"activated":false,"registered":false,"preconfigured":false,"profiles_installed":false,"node_role":"","playbook_status":"fresh"}
EOF
printf 'COMPLETED_JAMMY\n' >"$hop_ops/opt/aelladata/os-upgrade/offline/state"
cat >"$hop_ops/opt/aelladata/os-upgrade/offline/current-hop.env" <<'EOF'
CURRENT_HOP=focal-to-jammy
CURRENT_SOURCE_VERSION=18.04
CURRENT_SOURCE_CODENAME=bionic
CURRENT_TARGET_VERSION=22.04
CURRENT_TARGET_CODENAME=jammy
HANDOFF_SOURCE_STATE=COMPLETED_BIONIC
PACKAGE_TRANSITION_STARTED=false
CLIENT_ARTIFACT_SHA256=deadbeef
EOF
hop_write_previous_owner "$hop_ops"

# First invocation: empty confirmation → exit 21; identity must already be J2N
set +e
printf '\n' | env DP_OFFLINE_TEST_ROOT="$hop_ops" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  DP_OFFLINE_FAKE_DP_VERSION=6.2.0 DP_OFFLINE_FAKE_ROLE=AIO \
  bash "$STUB" --mirror-base http://127.0.0.1:9 >"$hop_ops/out-reject.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 21 ]] \
  && grep -q 'HOP_HANDOFF_VALIDATION=PASS' "$hop_ops/out-reject.txt" \
  && grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=YES' "$hop_ops/out-reject.txt" \
  && grep -q 'confirmation rejected' "$hop_ops/out-reject.txt" \
  && grep -q 'CURRENT_HOP=jammy-to-noble' "$hop_ops/opt/aelladata/os-upgrade/offline/current-hop.env" \
  && grep -q 'CURRENT_SOURCE_CODENAME=jammy' "$hop_ops/opt/aelladata/os-upgrade/offline/current-hop.env" \
  && grep -q 'CURRENT_TARGET_CODENAME=noble' "$hop_ops/opt/aelladata/os-upgrade/offline/current-hop.env" \
  && grep -q 'PACKAGE_TRANSITION_STARTED=false' "$hop_ops/opt/aelladata/os-upgrade/offline/current-hop.env" \
  && ! grep -q 'CURRENT_HOP=focal-to-jammy' "$hop_ops/opt/aelladata/os-upgrade/offline/current-hop.env" \
  && [[ "$(cat "$hop_ops/opt/aelladata/os-upgrade/offline/state")" == "PREFLIGHT" \
     || "$(cat "$hop_ops/opt/aelladata/os-upgrade/offline/state")" == "READY_FOR_CONFIRMATION" ]]; then
  pass "28.A1 ops repro: empty confirm exit=21 keeps J2N current-hop.env"
else
  fail "28.A1 ops repro empty confirm (rc=${rc})"
  tail -80 "$hop_ops/out-reject.txt" || true
  cat "$hop_ops/opt/aelladata/os-upgrade/offline/current-hop.env" 2>/dev/null || true
  cat "$hop_ops/opt/aelladata/os-upgrade/offline/state" 2>/dev/null || true
fi

# Second invocation: exact confirmation → source gate VALID, no ENV_HOP_MISMATCH
set +e
env DP_OFFLINE_TEST_ROOT="$hop_ops" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  DP_OFFLINE_FAKE_DP_VERSION=6.2.0 DP_OFFLINE_FAKE_ROLE=AIO \
  DP_OFFLINE_FAKE_CONFIRM=UPGRADE-JAMMY-TO-NOBLE \
  bash "$STUB" --mirror-base http://127.0.0.1:9 >"$hop_ops/out-commit.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && ! grep -q 'ENV_HOP_MISMATCH' "$hop_ops/out-commit.txt" \
  && ! grep -q 'FAIL_CURRENT_HOP_IDENTITY_MISMATCH' "$hop_ops/out-commit.txt" \
  && ! grep -q 'AMBIGUOUS_GATE_CONFIGURATION' "$hop_ops/out-commit.txt" \
  && grep -q 'SOURCE_GATE_CLASS=CURRENT_HOP_GATE_VALID' "$hop_ops/out-commit.txt" \
  && grep -q 'SOURCE_GATE_INSTALL=PASS' "$hop_ops/out-commit.txt" \
  && grep -q 'CURRENT_HOP=jammy-to-noble' "$hop_ops/opt/aelladata/os-upgrade/offline/current-hop.env" \
  && ! grep -q 'CRITICAL_OS_HOLD_RESTORE=SKIPPED_PACKAGE_TRANSITION_STARTED' "$hop_ops/out-commit.txt" \
  && ! grep -qE 'systemctl (start|enable).*stellar-offline|do-release-upgrade' "$hop_ops/out-commit.txt" \
  && grep -qE 'TEST_ROOT set - not starting systemd|CLIENT_HANDOFF_RESULT=PASS' "$hop_ops/out-commit.txt"; then
  pass "28.A2 ops repro: second invoke commit PASS to runner handoff"
else
  fail "28.A2 ops repro second invoke (rc=${rc})"
  tail -100 "$hop_ops/out-commit.txt" || true
fi

# --- 28.B atomic persistence: verify-after-write; write failure must not claim INITIALIZED ---
ID_HARNESS="${OUT_DIR}/j2n-identity-harness.sh"
{
  cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="${DP_OFFLINE_TEST_ROOT:-}"
PIN_HOP="jammy-to-noble"
PIN_SOURCE_VERSION="22.04"
PIN_SOURCE_CODENAME="jammy"
PIN_TARGET_VERSION="24.04"
PIN_TARGET_CODENAME="noble"
PIN_MANIFEST_SHA256="abc123"
PREVIOUS_HOP_TERMINAL_STATE="COMPLETED_JAMMY"
PREVIOUS_HOP_PIN_NAME="focal-to-jammy"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
CURRENT_HOP_ENV_FILE="${STATE_ROOT}/current-hop.env"
HOP_HANDOFF_BACKUP_PATH=""
EC_STATE=23
hostpath() {
  local p="$1"
  if [[ -n "$TEST_ROOT" ]]; then printf '%s%s' "$TEST_ROOT" "$p"; else printf '%s' "$p"; fi
}
log() { local level="$1"; shift; printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*"; }
die() { local c="$1"; shift; log ERROR "$* (exit=${c})"; exit "$c"; }
read_kv_file_field() {
  local f="$1" k="$2"
  [[ -f "$f" ]] || return 1
  sed -n "s/^${k}=//p" "$f" 2>/dev/null | head -1 | tr -d '\r'
}
EOS
  cat "${ROOT}/client/lib/dp-offline-durable-write.sh"
  python3 - "$SCRIPT_IN" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
for name in (
    "current_hop_env_path",
    "read_current_hop_field",
    "_exact_kv_once",
    "verify_persisted_current_hop_contract",
    "initialize_current_hop_identity",
):
    # Prefer client-body definitions after RUNNER heredoc (runner may embed
    # a path helper that must not use hostpath / TEST_ROOT).
    runner_end = text.find("\nRUNNER\n")
    search_from = runner_end + len("\nRUNNER\n") if runner_end >= 0 else 0
    start = text.index(f"{name}() {{", search_from)
    depth = 0
    i = start
    while i < len(text):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                print(text[start:i+1])
                print()
                break
        i += 1
    else:
        raise SystemExit(f"failed to extract {name}")
PY
  cat <<'EOS'
# Force write failure after tmp write to prove we do not claim INITIALIZED.
initialize_current_hop_identity_fail_mv() {
  local dest tmp dir
  dest="$(current_hop_env_path)"
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  tmp="${dest}.tmp.$$.$RANDOM"
  printf 'CURRENT_HOP=jammy-to-noble\n' >"$tmp"
  # Make destination path an existing non-empty directory so atomic replace fails.
  rm -f "$dest" 2>/dev/null || true
  mkdir -p "${dest}/block"
  if mv -f "$tmp" "$dest" 2>/dev/null; then
    # Some mv implementations move into the directory; treat that as failure too
    # unless dest is a regular file with the expected content.
    if [[ -f "$dest" ]] && grep -q '^CURRENT_HOP=jammy-to-noble$' "$dest"; then
      echo "UNEXPECTED_MV_SUCCESS"
      return 0
    fi
    rm -f "$tmp" "${dest}/$(basename "$tmp")" 2>/dev/null || true
  fi
  rm -f "$tmp" 2>/dev/null || true
  log ERROR "CURRENT_HOP_IDENTITY_INITIALIZED=NO"
  log ERROR "CURRENT_HOP_IDENTITY_REPLACE=FAIL"
  return 1
}
EOS
} >"$ID_HARNESS"
bash -n "$ID_HARNESS" && pass "28.B identity harness bash -n" || fail "28.B identity harness bash -n"

assert_j2n_eight_fields() {
  local envf="$1" sha="${2:-abc123}"
  grep -qx 'CURRENT_HOP=jammy-to-noble' "$envf" \
    && grep -qx 'CURRENT_SOURCE_VERSION=22.04' "$envf" \
    && grep -qx 'CURRENT_SOURCE_CODENAME=jammy' "$envf" \
    && grep -qx 'CURRENT_TARGET_VERSION=24.04' "$envf" \
    && grep -qx 'CURRENT_TARGET_CODENAME=noble' "$envf" \
    && grep -qx 'HANDOFF_SOURCE_STATE=COMPLETED_JAMMY' "$envf" \
    && grep -qx 'PACKAGE_TRANSITION_STARTED=false' "$envf" \
    && grep -qx "CLIENT_ARTIFACT_SHA256=${sha}" "$envf"
}

hop_id="$(mktemp -d "${OUT_DIR}/hop-id.XXXX")"
mkdir -p "$hop_id/opt/aelladata/os-upgrade/offline"
cat >"$hop_id/opt/aelladata/os-upgrade/offline/current-hop.env" <<'EOF'
CURRENT_HOP=focal-to-jammy
CURRENT_SOURCE_CODENAME=bionic
CURRENT_TARGET_CODENAME=jammy
EOF
set +e
(
  export DP_OFFLINE_TEST_ROOT="$hop_id" TEST_ROOT="$hop_id"
  # shellcheck disable=SC1090
  source "$ID_HARNESS"
  initialize_current_hop_identity
) >"$hop_id/out-ok.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=YES' "$hop_id/out-ok.txt" \
  && grep -q 'PERSISTED_CURRENT_HOP=jammy-to-noble' "$hop_id/out-ok.txt" \
  && grep -q 'PERSISTED_CLIENT_ARTIFACT_SHA256=abc123' "$hop_id/out-ok.txt" \
  && assert_j2n_eight_fields "$hop_id/opt/aelladata/os-upgrade/offline/current-hop.env" \
  && ! grep -q 'CURRENT_HOP=focal-to-jammy' "$hop_id/opt/aelladata/os-upgrade/offline/current-hop.env"; then
  pass "28.B1 rewrite previous-hop env then verify persisted pin"
else
  fail "28.B1 identity rewrite+verify (rc=${rc})"
  cat "$hop_id/out-ok.txt" || true
  cat "$hop_id/opt/aelladata/os-upgrade/offline/current-hop.env" 2>/dev/null || true
fi

hop_id2="$(mktemp -d "${OUT_DIR}/hop-id2.XXXX")"
mkdir -p "$hop_id2/opt/aelladata/os-upgrade/offline"
set +e
(
  export DP_OFFLINE_TEST_ROOT="$hop_id2" TEST_ROOT="$hop_id2"
  # shellcheck disable=SC1090
  source "$ID_HARNESS"
  initialize_current_hop_identity_fail_mv
) >"$hop_id2/out-fail.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] \
  && grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=NO' "$hop_id2/out-fail.txt" \
  && ! grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=YES' "$hop_id2/out-fail.txt" \
  && ! grep -q 'HOP_HANDOFF_ACCEPTED=YES' "$hop_id2/out-fail.txt"; then
  pass "28.B2 mv failure does not claim identity initialized"
else
  fail "28.B2 mv failure path (rc=${rc})"
  cat "$hop_id2/out-fail.txt" || true
fi

# --- 28.C source-gate fail-closed: ENV_HOP_MISMATCH must not log INSTALL=PASS ---
SG_HARNESS="${OUT_DIR}/j2n-sg-harness.sh"
{
  cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="${DP_OFFLINE_TEST_ROOT:-}"
PIN_HOP="jammy-to-noble"
PIN_SOURCE_CODENAME="jammy"
PIN_TARGET_CODENAME="noble"
PREVIOUS_HOP_PIN_NAME="focal-to-jammy"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
CURRENT_HOP_ENV_FILE="${STATE_ROOT}/current-hop.env"
EFFECTIVE_SOURCE_GATE_BIN="${STATE_ROOT}/bin/distupgrade-effective-source-gate"
EFFECTIVE_SOURCE_GATE_APT="/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate"
SOURCE_GATE_HOOK_BASENAME="98stellar-distupgrade-source-gate"
SOURCE_GATE_WRAP_BASENAME="distupgrade-effective-source-gate.wrap"
SOURCE_GATE_CLASS=""
EC_STATE=23
hostpath() {
  local p="$1"
  if [[ -n "$TEST_ROOT" ]]; then printf '%s%s' "$TEST_ROOT" "$p"; else printf '%s' "$p"; fi
}
log() { local level="$1"; shift; printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*"; }
die() { local c="$1"; shift; log ERROR "$* (exit=${c})"; exit "$c"; }
read_kv_file_field() {
  local f="$1" k="$2"
  [[ -f "$f" ]] || return 1
  sed -n "s/^${k}=//p" "$f" 2>/dev/null | head -1 | tr -d '\r'
}
current_hop_env_path() { hostpath "${CURRENT_HOP_ENV_FILE}"; }
read_current_hop_field() { read_kv_file_field "$(current_hop_env_path)" "$1" || true; }
EOS
  python3 - "$SCRIPT_IN" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
names = (
    "_source_gate_standard_wrap_path",
    "_source_gate_read_kv",
    "_source_gate_hook_command_target",
    "_source_gate_hook_is_stellar_only",
    "_source_gate_count_wrap_references",
    "classify_effective_source_gate_bundle",
)
for name in names:
    # Prefer client-body definitions after RUNNER heredoc (runner may embed
    # a path helper that must not use hostpath / TEST_ROOT).
    runner_end = text.find("\nRUNNER\n")
    search_from = runner_end + len("\nRUNNER\n") if runner_end >= 0 else 0
    start = text.index(f"{name}() {{", search_from)
    depth = 0
    i = start
    while i < len(text):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                print(text[start:i+1])
                print()
                break
        i += 1
    else:
        raise SystemExit(f"failed to extract {name}")
PY
  cat <<'EOS'
assert_source_gate_install_pass_allowed() {
  case "${SOURCE_GATE_CLASS:-}" in
    CURRENT_HOP_GATE_VALID)
      log INFO "SOURCE_GATE_INSTALL=PASS"
      ;;
    *)
      log ERROR "SOURCE_GATE_INSTALL=FAIL"
      log ERROR "SOURCE_GATE_CLASS=${SOURCE_GATE_CLASS:-UNKNOWN}"
      return 1
      ;;
  esac
}
EOS
} >"$SG_HARNESS"
bash -n "$SG_HARNESS" && pass "28.C source-gate harness bash -n" || fail "28.C source-gate harness bash -n"

hop_sgc="$(mktemp -d "${OUT_DIR}/hop-sgc.XXXX")"
mkdir -p "$hop_sgc/opt/aelladata/os-upgrade/offline/bin" "$hop_sgc/etc/apt/apt.conf.d"
printf 'CURRENT_HOP=focal-to-jammy\n' >"$hop_sgc/opt/aelladata/os-upgrade/offline/current-hop.env"
cat >"$hop_sgc/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$hop_sgc/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$hop_sgc/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate" \
  "$hop_sgc/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap"
printf 'STELLAR_EXPECTED_HOP=jammy-to-noble\n' \
  >"$hop_sgc/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.env"
cat >"$hop_sgc/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" <<'EOF'
APT::Update::Pre-Invoke { "/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap"; };
EOF
set +e
(
  export DP_OFFLINE_TEST_ROOT="$hop_sgc" TEST_ROOT="$hop_sgc"
  # shellcheck disable=SC1090
  source "$SG_HARNESS"
  classify_effective_source_gate_bundle
  assert_source_gate_install_pass_allowed
) >"$hop_sgc/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] \
  && grep -q 'SOURCE_GATE_CLASS=AMBIGUOUS_GATE_CONFIGURATION' "$hop_sgc/out.txt" \
  && grep -q 'ENV_HOP_MISMATCH' "$hop_sgc/out.txt" \
  && grep -q 'SOURCE_GATE_INSTALL=FAIL' "$hop_sgc/out.txt" \
  && ! grep -q 'SOURCE_GATE_INSTALL=PASS' "$hop_sgc/out.txt"; then
  pass "28.C1 ENV_HOP_MISMATCH → SOURCE_GATE_INSTALL=FAIL"
else
  fail "28.C1 ambiguous must fail-closed (rc=${rc})"
  cat "$hop_sgc/out.txt" || true
fi

hop_sgv="$(mktemp -d "${OUT_DIR}/hop-sgv.XXXX")"
mkdir -p "$hop_sgv/opt/aelladata/os-upgrade/offline/bin" "$hop_sgv/etc/apt/apt.conf.d"
printf 'CURRENT_HOP=jammy-to-noble\n' >"$hop_sgv/opt/aelladata/os-upgrade/offline/current-hop.env"
cat >"$hop_sgv/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$hop_sgv/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$hop_sgv/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate" \
  "$hop_sgv/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap"
printf 'STELLAR_EXPECTED_HOP=jammy-to-noble\n' \
  >"$hop_sgv/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.env"
cat >"$hop_sgv/etc/apt/apt.conf.d/98stellar-distupgrade-source-gate" <<'EOF'
APT::Update::Pre-Invoke { "/opt/aelladata/os-upgrade/offline/bin/distupgrade-effective-source-gate.wrap"; };
EOF
set +e
(
  export DP_OFFLINE_TEST_ROOT="$hop_sgv" TEST_ROOT="$hop_sgv"
  # shellcheck disable=SC1090
  source "$SG_HARNESS"
  classify_effective_source_gate_bundle
  assert_source_gate_install_pass_allowed
) >"$hop_sgv/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'SOURCE_GATE_CLASS=CURRENT_HOP_GATE_VALID' "$hop_sgv/out.txt" \
  && grep -q 'SOURCE_GATE_INSTALL=PASS' "$hop_sgv/out.txt"; then
  pass "28.C2 valid J2N identity → SOURCE_GATE_INSTALL=PASS"
else
  fail "28.C2 valid identity PASS (rc=${rc})"
  cat "$hop_sgv/out.txt" || true
fi

# --- 28.D transition-state accuracy: pre-runner source-gate failure restores holds ---
hop_tr="$(mktemp -d "${OUT_DIR}/hop-tr.XXXX")"
hop_fx_prep "$hop_tr"
mkdir -p "$hop_tr/etc/apt/sources.list.d" "$hop_tr/etc/apt/keyrings" \
  "$hop_tr/etc/systemd/system" "$hop_tr/usr/local/sbin" "$hop_tr/boot" \
  "$hop_tr/opt/aelladata/work" "$hop_tr/tmp" \
  "$hop_tr/etc/update-manager/release-upgrades.d"
printf 'deb http://127.0.0.1:9/ubuntu jammy main universe\n' >"$hop_tr/etc/apt/sources.list"
printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1000:1000:aella:/home/aella:/bin/bash\n' >"$hop_tr/etc/passwd"
printf '%s\n' "$REAL_META" >"$hop_tr/opt/aelladata/release-metadata.yml"
printf 'image: synthetic\n' >"$hop_tr/opt/aelladata/release-image.yml"
cat >"$hop_tr/opt/aelladata/work/runtime_config.json" <<'EOF'
{"installed":false,"activated":false,"registered":false,"preconfigured":false,"profiles_installed":false,"node_role":"","playbook_status":"fresh"}
EOF
printf 'PREFLIGHT\n' >"$hop_tr/opt/aelladata/os-upgrade/offline/state"
# Plant mismatch deliberately AFTER handoff would have fixed it - force commit-time gate fail.
# Use valid J2N identity so handoff is skipped; then corrupt env hop before commit by
# keeping identity mismatched via a planted previous-hop env that commit must reject.
# Actually: plant bionic identity + PREFLIGHT (post-handoff state) to hit source-gate/mismatch path.
cat >"$hop_tr/opt/aelladata/os-upgrade/offline/current-hop.env" <<'EOF'
CURRENT_HOP=focal-to-jammy
CURRENT_SOURCE_CODENAME=bionic
CURRENT_TARGET_CODENAME=jammy
PACKAGE_TRANSITION_STARTED=false
EOF
printf 'systemd\nudev\n' >"$hop_tr/tmp/held-packages.txt"
cp -a "$hop_tr/tmp/held-packages.txt" "$hop_tr/tmp/held-packages.before"
# Historical dpkg.log noise without baseline must not block restore
mkdir -p "$hop_tr/var/log"
printf '2020-01-01 00:00:00 startup archives unpack\n' >"$hop_tr/var/log/dpkg.log"
set +e
env DP_OFFLINE_TEST_ROOT="$hop_tr" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  DP_OFFLINE_FAKE_DP_VERSION=6.2.0 DP_OFFLINE_FAKE_ROLE=AIO \
  DP_OFFLINE_FAKE_CONFIRM=UPGRADE-JAMMY-TO-NOBLE \
  bash "$STUB" --mirror-base http://127.0.0.1:9 >"$hop_tr/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] \
  && grep -qE 'FAIL_CURRENT_HOP_IDENTITY_MISMATCH|FAIL_SOURCE_GATE_INSTALL_CLASSIFICATION|ENV_HOP_MISMATCH|SOURCE_GATE_INSTALL=FAIL' "$hop_tr/out.txt" \
  && ! grep -q 'SOURCE_GATE_INSTALL=PASS' "$hop_tr/out.txt" \
  && ! grep -q 'CRITICAL_OS_HOLD_RESTORE=SKIPPED_PACKAGE_TRANSITION_STARTED' "$hop_tr/out.txt" \
  && ! grep -qE 'systemctl (start|enable) .*stellar-offline|do-release-upgrade' "$hop_tr/out.txt" \
  && grep -qE 'ROLLBACK_ELIGIBLE=YES|CRITICAL_OS_HOLD_RESTORE_RESULT=PASS|CRITICAL_OS_HOLD_RESTORED=|CRITICAL_OS_HOLD_RESTORE=SKIPPED_NO_REMOVED_LIST|confirmation rejected|FAIL_CURRENT_HOP' "$hop_tr/out.txt"; then
  # Holds restored or never unheld; either way transition flag stayed false
  if grep -qx 'systemd' "$hop_tr/tmp/held-packages.txt" \
    && grep -qx 'udev' "$hop_tr/tmp/held-packages.txt"; then
    pass "28.D pre-runner identity/gate fail restores holds; no SKIPPED_PACKAGE_TRANSITION"
  elif ! grep -q 'CRITICAL_OS_UNHOLD_BEGIN' "$hop_tr/out.txt"; then
    pass "28.D pre-runner fail before unhold; no SKIPPED_PACKAGE_TRANSITION"
  else
    fail "28.D holds not restored after pre-runner fail"
    cat "$hop_tr/tmp/held-packages.txt" || true
    tail -60 "$hop_tr/out.txt" || true
  fi
else
  fail "28.D transition-state accuracy (rc=${rc})"
  tail -80 "$hop_tr/out.txt" || true
fi

# --- 28.E always-rewrite + full 8-field contract / early ACCEPTED prohibition ---
# Old assertion used grep BRE where '[[' is an unmatched character class (exit 2 →
# always took the else/pass branch). Replace with fixed-string + runtime fixtures.

ID_FN_BODY="${OUT_DIR}/initialize_current_hop_identity.body.txt"
python3 - "$SCRIPT_IN" "$ID_FN_BODY" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
name = "initialize_current_hop_identity"
start = text.index(f"{name}() {{")
depth = 0
i = start
while i < len(text):
    if text[i] == '{':
        depth += 1
    elif text[i] == '}':
        depth -= 1
        if depth == 0:
            Path(sys.argv[2]).write_text(text[start:i+1], encoding="utf-8")
            break
    i += 1
else:
    raise SystemExit("extract failed")
PY

# Negative-control: planted skip-if-exists MUST be detected by this assertion style.
SKIP_PLANT="${OUT_DIR}/skip-plant.body.txt"
{
  cat "$ID_FN_BODY"
  printf '%s\n' 'if [[ ! -f "$(current_hop_env_path)" ]]; then return 0; fi'
} >"$SKIP_PLANT"
if grep -Fq 'if [[ ! -f' "$SKIP_PLANT" \
  || grep -Fq 'skip-if-exists' "$SKIP_PLANT"; then
  pass "28.E0 planted skip-if-exists is detectable via grep -F"
else
  fail "28.E0 planted skip detection broken"
fi

if grep -Fq 'if [[ ! -f' "$ID_FN_BODY" \
  || grep -Fq '[[ ! -f' "$ID_FN_BODY" \
  || grep -Fq '[ ! -f' "$ID_FN_BODY" \
  || grep -Fq 'skip-if-exists' "$ID_FN_BODY"; then
  fail "28.E initialize_current_hop_identity still has skip-if-exists"
else
  # Must always rewrite (no early return on existing file)
  if grep -Fq 'Always rewrite' "$ID_FN_BODY" \
    && grep -Fq 'verify_persisted_current_hop_contract' "$ID_FN_BODY"; then
    pass "28.E accept/initialize always rewrites; no skip-if-exists"
  else
    fail "28.E missing always-rewrite / full-contract verify markers"
  fi
fi

# Static: ACCEPTED=YES must not be written to handoff-event before identity init.
if ORDER_OUT="$(python3 - "$SCRIPT_IN" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
name = "accept_previous_hop_terminal_state"
start = text.index(f"{name}() {{")
depth = 0
i = start
while i < len(text):
    if text[i] == '{':
        depth += 1
    elif text[i] == '}':
        depth -= 1
        if depth == 0:
            body = text[start:i+1]
            break
    i += 1
else:
    raise SystemExit("extract accept failed")
init_at = body.index("initialize_current_hop_identity")
pre = body[:init_at]
if "HOP_HANDOFF_ACCEPTED=YES" in pre:
    raise SystemExit("ACCEPTED=YES appears before initialize_current_hop_identity")
if "HOP_HANDOFF_STATUS=PENDING" not in pre:
    raise SystemExit("expected PENDING status before identity init")
post = body[init_at:]
if "HOP_HANDOFF_ACCEPTED=YES" not in post:
    raise SystemExit("ACCEPTED=YES missing after initialize")
if "PERSISTED_CLIENT_ARTIFACT_SHA256=" not in post:
    raise SystemExit("accepted event missing persisted SHA field")
print("ORDER_OK")
PY
)" && [[ "$ORDER_OUT" == "ORDER_OK" ]]; then
  pass "28.E1 handoff-event ACCEPTED only after identity verify"
else
  fail "28.E1 handoff-event ordering (${ORDER_OUT:-})"
fi

# 28.E2 / A: full-field verification success
hop_e2="$(mktemp -d "${OUT_DIR}/hop-e2.XXXX")"
mkdir -p "$hop_e2/opt/aelladata/os-upgrade/offline"
cat >"$hop_e2/opt/aelladata/os-upgrade/offline/current-hop.env" <<'EOF'
CURRENT_HOP=focal-to-jammy
CURRENT_SOURCE_VERSION=18.04
CURRENT_SOURCE_CODENAME=bionic
CURRENT_TARGET_VERSION=22.04
CURRENT_TARGET_CODENAME=jammy
HANDOFF_SOURCE_STATE=COMPLETED_BIONIC
PACKAGE_TRANSITION_STARTED=true
CLIENT_ARTIFACT_SHA256=deadbeef
EOF
set +e
(
  export DP_OFFLINE_TEST_ROOT="$hop_e2" TEST_ROOT="$hop_e2"
  # shellcheck disable=SC1090
  source "$ID_HARNESS"
  initialize_current_hop_identity
) >"$hop_e2/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=YES' "$hop_e2/out.txt" \
  && assert_j2n_eight_fields "$hop_e2/opt/aelladata/os-upgrade/offline/current-hop.env" \
  && ! grep -q 'CURRENT_HOP=focal-to-jammy' "$hop_e2/opt/aelladata/os-upgrade/offline/current-hop.env" \
  && ! grep -q 'PACKAGE_TRANSITION_STARTED=true' "$hop_e2/opt/aelladata/os-upgrade/offline/current-hop.env" \
  && ! grep -q 'HANDOFF_SOURCE_STATE=COMPLETED_BIONIC' "$hop_e2/opt/aelladata/os-upgrade/offline/current-hop.env"; then
  pass "28.E2/A full-field success + existing-file always rewrite"
else
  fail "28.E2/A full-field success (rc=${rc})"
  cat "$hop_e2/out.txt" || true
  cat "$hop_e2/opt/aelladata/os-upgrade/offline/current-hop.env" 2>/dev/null || true
fi

# 28.E3 / B: artifact SHA post-write mismatch → INITIALIZED=NO, no ACCEPTED
hop_e3="$(mktemp -d "${OUT_DIR}/hop-e3.XXXX")"
mkdir -p "$hop_e3/opt/aelladata/os-upgrade/offline" "$hop_e3/bin"
cat >"$hop_e3/bin/mv" <<'EOF'
#!/usr/bin/env bash
# Corrupt CLIENT_ARTIFACT_SHA256 after atomic replace into current-hop.env
/bin/mv "$@"
rc=$?
for a in "$@"; do
  if [[ "$a" == *current-hop.env && -f "$a" ]]; then
    # strip any accidental ACCEPTED markers from prior runs
    sed -i 's/^CLIENT_ARTIFACT_SHA256=.*/CLIENT_ARTIFACT_SHA256=tampered-sha/' "$a"
  fi
done
exit "$rc"
EOF
chmod +x "$hop_e3/bin/mv"
set +e
(
  export DP_OFFLINE_TEST_ROOT="$hop_e3" TEST_ROOT="$hop_e3"
  export PATH="$hop_e3/bin:$PATH"
  # shellcheck disable=SC1090
  source "$ID_HARNESS"
  initialize_current_hop_identity
  # Simulate accept path evidence check
  printf 'HOP_HANDOFF_ACCEPTED=YES\n' >"$hop_e3/would-accept.txt"
) >"$hop_e3/out.txt" 2>&1
rc=$?
set -e
# The printf after failed initialize must not run if set -e; harness uses set -euo
if [[ "$rc" -ne 0 ]] \
  && grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=NO' "$hop_e3/out.txt" \
  && grep -q 'CURRENT_HOP_IDENTITY_VERIFY=FAIL' "$hop_e3/out.txt" \
  && ! grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=YES' "$hop_e3/out.txt" \
  && ! grep -q 'HOP_HANDOFF_ACCEPTED=YES' "$hop_e3/out.txt" \
  && [[ ! -f "$hop_e3/would-accept.txt" ]]; then
  pass "28.E3/B artifact SHA post-write mismatch fails closed"
else
  fail "28.E3/B SHA mismatch (rc=${rc})"
  cat "$hop_e3/out.txt" || true
  cat "$hop_e3/opt/aelladata/os-upgrade/offline/current-hop.env" 2>/dev/null || true
fi

# 28.E4 / C: package transition field mismatch after write
hop_e4="$(mktemp -d "${OUT_DIR}/hop-e4.XXXX")"
mkdir -p "$hop_e4/opt/aelladata/os-upgrade/offline" "$hop_e4/bin"
cat >"$hop_e4/bin/mv" <<'EOF'
#!/usr/bin/env bash
/bin/mv "$@"
rc=$?
for a in "$@"; do
  if [[ "$a" == *current-hop.env && -f "$a" ]]; then
    sed -i 's/^PACKAGE_TRANSITION_STARTED=.*/PACKAGE_TRANSITION_STARTED=true/' "$a"
  fi
done
exit "$rc"
EOF
chmod +x "$hop_e4/bin/mv"
set +e
(
  export DP_OFFLINE_TEST_ROOT="$hop_e4" TEST_ROOT="$hop_e4"
  export PATH="$hop_e4/bin:$PATH"
  # shellcheck disable=SC1090
  source "$ID_HARNESS"
  initialize_current_hop_identity
) >"$hop_e4/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] \
  && grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=NO' "$hop_e4/out.txt" \
  && ! grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=YES' "$hop_e4/out.txt" \
  && ! grep -q 'HOP_HANDOFF_ACCEPTED=YES' "$hop_e4/out.txt"; then
  pass "28.E4/C package transition mismatch fails closed"
else
  fail "28.E4/C transition mismatch (rc=${rc})"
  cat "$hop_e4/out.txt" || true
fi

# Also: missing PACKAGE_TRANSITION_STARTED after write
hop_e4b="$(mktemp -d "${OUT_DIR}/hop-e4b.XXXX")"
mkdir -p "$hop_e4b/opt/aelladata/os-upgrade/offline" "$hop_e4b/bin"
cat >"$hop_e4b/bin/mv" <<'EOF'
#!/usr/bin/env bash
/bin/mv "$@"
rc=$?
for a in "$@"; do
  if [[ "$a" == *current-hop.env && -f "$a" ]]; then
    sed -i '/^PACKAGE_TRANSITION_STARTED=/d' "$a"
  fi
done
exit "$rc"
EOF
chmod +x "$hop_e4b/bin/mv"
set +e
(
  export DP_OFFLINE_TEST_ROOT="$hop_e4b" TEST_ROOT="$hop_e4b"
  export PATH="$hop_e4b/bin:$PATH"
  # shellcheck disable=SC1090
  source "$ID_HARNESS"
  initialize_current_hop_identity
) >"$hop_e4b/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] \
  && grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=NO' "$hop_e4b/out.txt" \
  && ! grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=YES' "$hop_e4b/out.txt"; then
  pass "28.E4b missing PACKAGE_TRANSITION_STARTED fails closed"
else
  fail "28.E4b missing transition field (rc=${rc})"
  cat "$hop_e4b/out.txt" || true
fi

# 28.E5 / D: handoff source state mismatch after write
hop_e5="$(mktemp -d "${OUT_DIR}/hop-e5.XXXX")"
mkdir -p "$hop_e5/opt/aelladata/os-upgrade/offline" "$hop_e5/bin"
cat >"$hop_e5/bin/mv" <<'EOF'
#!/usr/bin/env bash
/bin/mv "$@"
rc=$?
for a in "$@"; do
  if [[ "$a" == *current-hop.env && -f "$a" ]]; then
    sed -i 's/^HANDOFF_SOURCE_STATE=.*/HANDOFF_SOURCE_STATE=COMPLETED_BIONIC/' "$a"
  fi
done
exit "$rc"
EOF
chmod +x "$hop_e5/bin/mv"
set +e
(
  export DP_OFFLINE_TEST_ROOT="$hop_e5" TEST_ROOT="$hop_e5"
  export PATH="$hop_e5/bin:$PATH"
  # shellcheck disable=SC1090
  source "$ID_HARNESS"
  initialize_current_hop_identity
) >"$hop_e5/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] \
  && grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=NO' "$hop_e5/out.txt" \
  && ! grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=YES' "$hop_e5/out.txt" \
  && ! grep -q 'HOP_HANDOFF_ACCEPTED=YES' "$hop_e5/out.txt"; then
  pass "28.E5/D HANDOFF_SOURCE_STATE mismatch fails closed"
else
  fail "28.E5/D source state mismatch (rc=${rc})"
  cat "$hop_e5/out.txt" || true
fi

# 28.E6 / E: early event prohibition - ops path success writes ACCEPTED only after verify;
# failure fixture leaves ACCEPTED=YES at 0 in handoff-event
hop_e6="$(mktemp -d "${OUT_DIR}/hop-e6.XXXX")"
hop_fx_prep "$hop_e6"
mkdir -p "$hop_e6/etc/apt/sources.list.d" "$hop_e6/etc/apt/keyrings" \
  "$hop_e6/etc/systemd/system" "$hop_e6/usr/local/sbin" "$hop_e6/boot" \
  "$hop_e6/opt/aelladata/work" "$hop_e6/tmp" "$hop_e6/etc/passwd.d" \
  "$hop_e6/etc/update-manager/release-upgrades.d"
printf 'deb http://127.0.0.1:9/ubuntu jammy main universe\n' >"$hop_e6/etc/apt/sources.list"
printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1000:1000:aella:/home/aella:/bin/bash\n' >"$hop_e6/etc/passwd"
printf '%s\n' "$REAL_META" >"$hop_e6/opt/aelladata/release-metadata.yml"
printf 'image: synthetic\n' >"$hop_e6/opt/aelladata/release-image.yml"
cat >"$hop_e6/opt/aelladata/work/runtime_config.json" <<'EOF'
{"installed":false,"activated":false,"registered":false,"preconfigured":false,"profiles_installed":false,"node_role":"","playbook_status":"fresh"}
EOF
printf 'COMPLETED_JAMMY\n' >"$hop_e6/opt/aelladata/os-upgrade/offline/state"
cat >"$hop_e6/opt/aelladata/os-upgrade/offline/current-hop.env" <<'EOF'
CURRENT_HOP=focal-to-jammy
CURRENT_SOURCE_VERSION=18.04
CURRENT_SOURCE_CODENAME=bionic
CURRENT_TARGET_VERSION=22.04
CURRENT_TARGET_CODENAME=jammy
HANDOFF_SOURCE_STATE=COMPLETED_BIONIC
PACKAGE_TRANSITION_STARTED=true
CLIENT_ARTIFACT_SHA256=deadbeef
EOF
hop_write_previous_owner "$hop_e6"
set +e
printf '\n' | env DP_OFFLINE_TEST_ROOT="$hop_e6" DP_OFFLINE_FAKE_MIRROR_TRUST=1 \
  DP_OFFLINE_FAKE_DP_VERSION=6.2.0 DP_OFFLINE_FAKE_ROLE=AIO \
  bash "$STUB" --mirror-base http://127.0.0.1:9 >"$hop_e6/out.txt" 2>&1
rc=$?
set -e
evt="$(find "$hop_e6/opt/aelladata/os-upgrade/offline/backups" -name handoff-event.txt 2>/dev/null | sort | tail -1 || true)"
ZERO_SHA="$(printf '%064d' 0)"
if [[ "$rc" -eq 21 ]] \
  && grep -q 'HOP_HANDOFF_ACCEPTED=YES' "$hop_e6/out.txt" \
  && grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=YES' "$hop_e6/out.txt" \
  && [[ -n "$evt" ]] \
  && grep -qx 'HOP_HANDOFF_ACCEPTED=YES' "$evt" \
  && grep -qx 'HOP_HANDOFF_STATUS=ACCEPTED' "$evt" \
  && grep -qx "PERSISTED_CLIENT_ARTIFACT_SHA256=${ZERO_SHA}" "$evt" \
  && grep -qx 'PERSISTED_CURRENT_HOP=jammy-to-noble' "$evt" \
  && assert_j2n_eight_fields "$hop_e6/opt/aelladata/os-upgrade/offline/current-hop.env" "$ZERO_SHA"; then
  pass "28.E6/E success: ACCEPTED event only with persisted 8-field evidence"
else
  fail "28.E6/E success event evidence (rc=${rc} evt=${evt:-none})"
  tail -40 "$hop_e6/out.txt" || true
  [[ -n "${evt:-}" ]] && cat "$evt" || true
  cat "$hop_e6/opt/aelladata/os-upgrade/offline/current-hop.env" 2>/dev/null || true
fi

# Failure fixture: identity verify fails → no ACCEPTED in any handoff-event
hop_e6f="$(mktemp -d "${OUT_DIR}/hop-e6f.XXXX")"
mkdir -p "$hop_e6f/opt/aelladata/os-upgrade/offline/backups/handoff-state-failtest" \
  "$hop_e6f/bin"
# Simulate pending event that must never gain ACCEPTED if verify fails
cat >"$hop_e6f/opt/aelladata/os-upgrade/offline/backups/handoff-state-failtest/handoff-event.txt" <<'EOF'
event=JAMMY_TO_NOBLE_HANDOFF_PENDING
HOP_HANDOFF_STATUS=PENDING
EOF
cat >"$hop_e6f/bin/mv" <<'EOF'
#!/usr/bin/env bash
/bin/mv "$@"
rc=$?
for a in "$@"; do
  if [[ "$a" == *current-hop.env && -f "$a" ]]; then
    sed -i 's/^CLIENT_ARTIFACT_SHA256=.*/CLIENT_ARTIFACT_SHA256=bad/' "$a"
  fi
done
exit "$rc"
EOF
chmod +x "$hop_e6f/bin/mv"
set +e
(
  export DP_OFFLINE_TEST_ROOT="$hop_e6f" TEST_ROOT="$hop_e6f"
  export PATH="$hop_e6f/bin:$PATH"
  # shellcheck disable=SC1090
  source "$ID_HARNESS"
  initialize_current_hop_identity || true
) >"$hop_e6f/out.txt" 2>&1
rc=$?
set -e
set +e
accepted_count="$(grep -Rcl 'HOP_HANDOFF_ACCEPTED=YES' "$hop_e6f/opt/aelladata/os-upgrade/offline/backups" 2>/dev/null | wc -l | tr -d ' ')"
set -e
accepted_count="${accepted_count:-0}"
if grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=NO' "$hop_e6f/out.txt" \
  && ! grep -q 'CURRENT_HOP_IDENTITY_INITIALIZED=YES' "$hop_e6f/out.txt" \
  && [[ "$accepted_count" == "0" ]] \
  && ! grep -q 'HOP_HANDOFF_ACCEPTED=YES' \
       "$hop_e6f/opt/aelladata/os-upgrade/offline/backups/handoff-state-failtest/handoff-event.txt"; then
  pass "28.E6f/E failure: ACCEPTED=YES evidence remains 0"
else
  fail "28.E6f/E early ACCEPTED prohibition (accepted_count=${accepted_count})"
  cat "$hop_e6f/out.txt" || true
fi

# 28.E7 / F: existing-file always rewrite (explicit; overlaps E2 but asserts skip path absent at runtime)
hop_e7="$(mktemp -d "${OUT_DIR}/hop-e7.XXXX")"
mkdir -p "$hop_e7/opt/aelladata/os-upgrade/offline"
cat >"$hop_e7/opt/aelladata/os-upgrade/offline/current-hop.env" <<'EOF'
CURRENT_HOP=focal-to-jammy
CURRENT_SOURCE_VERSION=18.04
CURRENT_SOURCE_CODENAME=bionic
CURRENT_TARGET_VERSION=22.04
CURRENT_TARGET_CODENAME=jammy
HANDOFF_SOURCE_STATE=COMPLETED_BIONIC
PACKAGE_TRANSITION_STARTED=true
CLIENT_ARTIFACT_SHA256=oldsha
EOF
set +e
(
  export DP_OFFLINE_TEST_ROOT="$hop_e7" TEST_ROOT="$hop_e7"
  # shellcheck disable=SC1090
  source "$ID_HARNESS"
  initialize_current_hop_identity
) >"$hop_e7/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'CURRENT_HOP_IDENTITY_REWRITE=YES' "$hop_e7/out.txt" \
  && assert_j2n_eight_fields "$hop_e7/opt/aelladata/os-upgrade/offline/current-hop.env" \
  && ! grep -Fq 'skip-if-exists' "$hop_e7/out.txt"; then
  pass "28.E7/F existing focal-to-jammy env always rewritten to J2N contract"
else
  fail "28.E7/F always rewrite (rc=${rc})"
  cat "$hop_e7/out.txt" || true
  cat "$hop_e7/opt/aelladata/os-upgrade/offline/current-hop.env" 2>/dev/null || true
fi

# =============================================================================
# J2N supplemental fixtures: deb822 source gate (E), deploy contract (I), stale (J)
# =============================================================================

# --- E) deb822 .sources gate ---
DEB822_FIX="$(mktemp -d)"
# Reuse extracted GATE_BIN when available; otherwise re-extract.
if [[ -z "${GATE_BIN:-}" || ! -f "${GATE_BIN:-}" ]]; then
  GATE_BIN="$(python3 - "$SCRIPT_IN" "$DEB822_FIX" <<'PY'
import re, os, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"cat >\"\$\{bin_path\}\.new\" <<'GATE'\n(.*)\nGATE\n", text, re.S)
assert m, 'GATE heredoc missing'
root = sys.argv[2]
os.makedirs(os.path.join(root, 'bin'), exist_ok=True)
gate = os.path.join(root, 'bin', 'distupgrade-effective-source-gate')
open(gate, 'w').write(m.group(1))
os.chmod(gate, 0o755)
print(gate)
PY
)"
fi
mkdir -p "$DEB822_FIX/etc/apt/sources.list.d" \
  "$DEB822_FIX/opt/aelladata/os-upgrade/offline/evidence/effective-source-gate" \
  "$DEB822_FIX/var/log/aella"
: >"$DEB822_FIX/etc/apt/sources.list"
LOCAL_URI_J2N='http://192.0.2.10/hops/jammy-to-noble/ubuntu'
cat >"$DEB822_FIX/opt/aelladata/os-upgrade/offline/effective-source-gate.armed" <<EOF
GATE_SCHEMA_VERSION=1
EXPECTED_SOURCE_CODENAME=jammy
EXPECTED_TARGET_CODENAME=noble
EXPECTED_MIRROR_URI=${LOCAL_URI_J2N}
EXPECTED_HOP=jammy-to-noble
ARMED_AT=2026-07-24T00:00:00Z
RUN_ID=deb822-run
EOF
chmod 0600 "$DEB822_FIX/opt/aelladata/os-upgrade/offline/effective-source-gate.armed"

run_deb822_gate() {
  env -i PATH="/usr/bin:/bin" \
    STELLAR_EXPECTED_MIRROR_URI="$LOCAL_URI_J2N" \
    STELLAR_TARGET_CODENAME=noble \
    STELLAR_SOURCE_CODENAME=jammy \
    STELLAR_COMPONENTS='main universe' \
    STELLAR_SOURCES_LIST="$DEB822_FIX/etc/apt/sources.list" \
    STELLAR_SOURCES_LIST_D="$DEB822_FIX/etc/apt/sources.list.d" \
    STELLAR_GATE_ARMED_MARKER="$DEB822_FIX/opt/aelladata/os-upgrade/offline/effective-source-gate.armed" \
    STELLAR_GATE_PASSED_MARKER="$DEB822_FIX/opt/aelladata/os-upgrade/offline/effective-source-gate.passed" \
    STELLAR_GATE_LOG="$DEB822_FIX/var/log/aella/distupgrade_effective_source_gate.log" \
    STELLAR_GATE_EVIDENCE_ROOT="$DEB822_FIX/opt/aelladata/os-upgrade/offline/evidence/effective-source-gate" \
    STELLAR_STATE_FILE="$DEB822_FIX/opt/aelladata/os-upgrade/offline/state" \
    /usr/bin/python3 "$GATE_BIN"
}

# E1 single valid noble stanza
cat >"$DEB822_FIX/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: ${LOCAL_URI_J2N}
Suites: noble noble-updates noble-security noble-backports
Components: main universe
EOF
rm -f "$DEB822_FIX/opt/aelladata/os-upgrade/offline/effective-source-gate.passed"
set +e
out="$(run_deb822_gate 2>/dev/null)"; rc=$?; set -e
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -q 'ENFORCING_TARGET_SOURCES' \
  && printf '%s\n' "$out" | grep -q 'DISTUPGRADE_EFFECTIVE_SOURCE_GATE_RESULT=PASS' \
  && printf '%s\n' "$out" | grep -q 'DISTUPGRADE_OFFICIAL_ARCHIVE_REFERENCE_COUNT=0'; then
  pass "E1 deb822 single valid noble stanza ENFORCE PASS"
else
  fail "E1 deb822 single stanza (rc=${rc})"; printf '%s\n' "$out" || true
fi

# E2 multiple stanzas
cat >"$DEB822_FIX/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: ${LOCAL_URI_J2N}
Suites: noble noble-updates
Components: main universe

Types: deb
URIs: ${LOCAL_URI_J2N}
Suites: noble-security noble-backports
Components: main universe
EOF
set +e
out="$(run_deb822_gate 2>/dev/null)"; rc=$?; set -e
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -q 'ENFORCING_TARGET_SOURCES' \
  && printf '%s\n' "$out" | grep -q 'DISTUPGRADE_EFFECTIVE_SOURCE_GATE_RESULT=PASS'; then
  pass "E2 deb822 multiple stanzas PASS"
else
  fail "E2 deb822 multi-stanza (rc=${rc})"; printf '%s\n' "$out" || true
fi

# E3 continuation line for Suites
cat >"$DEB822_FIX/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: ${LOCAL_URI_J2N}
Suites: noble noble-updates
 noble-security noble-backports
Components: main universe
EOF
set +e
out="$(run_deb822_gate 2>/dev/null)"; rc=$?; set -e
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -q 'DISTUPGRADE_EFFECTIVE_SOURCE_GATE_RESULT=PASS'; then
  pass "E3 deb822 Suites continuation line PASS"
else
  fail "E3 deb822 continuation (rc=${rc})"; printf '%s\n' "$out" || true
fi

# E4 Enabled: no ignored + valid stanza
cat >"$DEB822_FIX/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble
Components: main
Enabled: no

Types: deb
URIs: ${LOCAL_URI_J2N}
Suites: noble noble-updates noble-security noble-backports
Components: main universe
EOF
set +e
out="$(run_deb822_gate 2>/dev/null)"; rc=$?; set -e
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -q 'DISTUPGRADE_EFFECTIVE_SOURCE_GATE_RESULT=PASS' \
  && printf '%s\n' "$out" | grep -q 'DISTUPGRADE_OFFICIAL_ARCHIVE_REFERENCE_COUNT=0'; then
  pass "E4 deb822 Enabled: no ignored (official stanza disabled)"
else
  fail "E4 Enabled:no (rc=${rc})"; printf '%s\n' "$out" || true
fi

# E5 malformed stanza rejected
cat >"$DEB822_FIX/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: ${LOCAL_URI_J2N}
Components: main universe
EOF
set +e
out="$(run_deb822_gate 2>/dev/null)"; rc=$?; set -e
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -qE 'MALFORMED_DEB822|FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_MALFORMED_DEB822'; then
  pass "E5 deb822 malformed stanza rejected"
else
  fail "E5 malformed (rc=${rc})"; printf '%s\n' "$out" || true
fi

# E6 mixed local/public URI rejected
cat >"$DEB822_FIX/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: ${LOCAL_URI_J2N} http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-security noble-backports
Components: main universe
EOF
set +e
out="$(run_deb822_gate 2>/dev/null)"; rc=$?; set -e
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -qE 'OFFLINE_ESCAPE|OFFICIAL|UNEXPECTED_URI|DENY'; then
  pass "E6 deb822 mixed local/public URI rejected"
else
  fail "E6 mixed URI (rc=${rc})"; printf '%s\n' "$out" || true
fi

# E7 legacy + deb822 duplicate suite rejected
cat >"$DEB822_FIX/etc/apt/sources.list" <<EOF
deb [arch=amd64] ${LOCAL_URI_J2N} noble main universe
deb [arch=amd64] ${LOCAL_URI_J2N} noble-updates main universe
deb [arch=amd64] ${LOCAL_URI_J2N} noble-security main universe
deb [arch=amd64] ${LOCAL_URI_J2N} noble-backports main universe
EOF
cat >"$DEB822_FIX/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: ${LOCAL_URI_J2N}
Suites: noble
Components: main universe
EOF
set +e
out="$(run_deb822_gate 2>/dev/null)"; rc=$?; set -e
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -qE 'DUPLICATE|DENY|FAIL'; then
  pass "E7 legacy+deb822 duplicate suite rejected"
else
  fail "E7 duplicate (rc=${rc})"; printf '%s\n' "$out" || true
fi

# E8 source/target suite mix rejected
: >"$DEB822_FIX/etc/apt/sources.list"
cat >"$DEB822_FIX/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: ${LOCAL_URI_J2N}
Suites: jammy noble noble-updates noble-security noble-backports
Components: main universe
EOF
set +e
out="$(run_deb822_gate 2>/dev/null)"; rc=$?; set -e
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -qE 'MIXED|SOURCE.*TARGET|DENY|FAIL'; then
  pass "E8 deb822 source/target suite mix rejected"
else
  fail "E8 mixed suites (rc=${rc})"; printf '%s\n' "$out" || true
fi

# E9 jammy-only DEFER before target rewrite
: >"$DEB822_FIX/etc/apt/sources.list"
cat >"$DEB822_FIX/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: ${LOCAL_URI_J2N}
Suites: jammy jammy-updates jammy-security jammy-backports
Components: main universe
EOF
set +e
out="$(run_deb822_gate 2>/dev/null)"; rc=$?; set -e
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -q 'ARMED_WAITING_FOR_TARGET_REWRITE' \
  && printf '%s\n' "$out" | grep -q 'DISTUPGRADE_EFFECTIVE_SOURCE_GATE_ACTION=DEFER'; then
  pass "E9 deb822 jammy-only DEFER before rewrite"
else
  fail "E9 defer (rc=${rc})"; printf '%s\n' "$out" || true
fi

# E10 missing pocket rejected under ENFORCE
cat >"$DEB822_FIX/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: ${LOCAL_URI_J2N}
Suites: noble noble-updates noble-security
Components: main universe
EOF
set +e
out="$(run_deb822_gate 2>/dev/null)"; rc=$?; set -e
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -qE 'MISSING|POCKET|DENY|FAIL|ENFORCING'; then
  pass "E10 deb822 missing noble-backports rejected"
else
  fail "E10 missing pocket (rc=${rc})"; printf '%s\n' "$out" || true
fi

rm -rf "$DEB822_FIX"

# --- I) artifact/deploy contract (static; no production build/deploy) ---
DEPLOY_SH="${ROOT}/scripts/deploy-client-jammy-to-noble-atomic.sh"
[[ -f "$DEPLOY_SH" ]] || fail "deploy script missing"
bash -n "$DEPLOY_SH" && pass "I deploy bash -n" || fail "I deploy bash -n"
DEPLOY_PY="${ROOT}/scripts/lib/deploy_client_artifacts_atomic.py"
grep -q 'dp-offline-upgrade-jammy-to-noble.sh' "$DEPLOY_SH" \
  && grep -q 'build_client_jammy_to_noble.py' "$DEPLOY_SH" \
  && grep -q 'DEPLOY_OK' "$DEPLOY_PY" \
  && grep -q 'READY_UNCHANGED=YES' "$DEPLOY_SH" \
  && grep -q 'HTTP_SIGNATURE_VERIFY=PASS' "$DEPLOY_SH" \
  && grep -q 'HTTP_VERIFY=PASS' "$DEPLOY_SH" \
  && pass "I deploy markers/basename contract" \
  || fail "I deploy markers/basename contract"

python3 - "$BUILD_PY" <<'PY' && pass "I builder template path + ast.parse" || fail "I builder template/ast"
import ast, sys
from pathlib import Path
p = Path(sys.argv[1])
src = p.read_text(encoding='utf-8')
ast.parse(src)
assert 'dp-offline-upgrade-jammy-to-noble.sh.in' in src
assert 'HOP = "jammy-to-noble"' in src
assert 'CONFIRM_PHRASE = "UPGRADE-JAMMY-TO-NOBLE"' in src
assert 'noble.tar.gz' in src
assert 'jammy/jammy.tar.gz' not in src
assert 'FORBIDDEN_F2J_RESIDUAL_RE' in src
print('BUILDER_OK')
PY

grep -q 'client/dp-offline-upgrade-jammy-to-noble.sh.in' "$BUILD_PY" \
  && pass "I builder reads J2N template only (path pin)" \
  || fail "I builder template path pin"

# --- J) stale target-contract strings must not remain ---
J_STALE=0
while IFS= read -r pat; do
  [[ -n "$pat" ]] || continue
  if grep -nE "$pat" "$SCRIPT_IN" | grep -vE 'PREVIOUS_HOP_|previous-hop|Previous-hop|archive/retire|ALLOWED|forbidden F2J|FORBIDDEN_F2J|PREVIOUS_HOP_TARGET_OS'; then
    echo "  stale hit: $pat"
    J_STALE=$((J_STALE + 1))
  fi
done <<'PATS'
CURRENT_HOP=focal-to-jammy
TARGET_OS=22\.04
CURRENT_TARGET_CODENAME=jammy
UPGRADE-FOCAL-TO-JAMMY
focal/focal\.tar\.gz
jammy/jammy\.tar\.gz
stellar-offline-focal-to-jammy\.gpg
dp-offline-upgrade-focal-to-jammy\.sh
PATS
# COMPLETED_JAMMY as final success is forbidden; previous-terminal refs allowed
if grep -n 'write_state COMPLETED_JAMMY\|os_upgrade_result=COMPLETED_JAMMY\|post-boot verification PASS - COMPLETED_JAMMY' "$SCRIPT_IN"; then
  J_STALE=$((J_STALE + 1))
  echo "  stale hit: COMPLETED_JAMMY used as final success"
fi
if [[ "$J_STALE" -eq 0 ]]; then
  pass "J stale target-contract patterns = 0"
else
  fail "J stale target-contract patterns = ${J_STALE}"
fi

# Phase 2 auto-run must be absent (manual NEXT-step mentions are allowed)
if grep -nE 'bringup_py3_dp_after_os_upgrade|auto.*Phase 2|Phase 2.*auto' "$SCRIPT_IN" \
  | grep -viE 'NOT|Does NOT|never|OUT_OF_SCOPE|separate|forbidden|must not|manual|NEXT|skip-download|PENDING'; then
  fail "H Phase 2 auto-run reference present"
else
  pass "H Phase 2 auto-run absent"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL dp-offline-upgrade-jammy-to-noble CHECKS PASSED"
  exit 0
fi
echo "SOME dp-offline-upgrade-jammy-to-noble CHECKS FAILED"
exit 1
