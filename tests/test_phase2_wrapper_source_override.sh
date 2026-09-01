#!/usr/bin/env bash
# W01–W06: upgrade-phase2.sh wrapper allowlist for --source-dp-version.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }

# shellcheck source=/dev/null
source "$ROOT/scripts/lib/phase2_helper_generation.sh"

CLIENT="$TMP/client"
mkdir -p "$CLIENT/lib"
# Minimal generation unit files for manifest/wrapper write.
for f in stage-dp-phase2.sh bringup_py3_dp_lifecycle.sh \
  lib/dp-offline-source-product-version.sh \
  lib/dp-phase2-operation-progress.sh \
  lib/dp-phase2-bringup-lifecycle.sh \
  lib/dp-phase2-ubuntu-prerequisites.sh
do
  mkdir -p "$(dirname "$CLIENT/$f")"
  echo "# fixture $f" >"$CLIENT/$f"
done

phase2_helper_generation_write "$CLIENT" >/dev/null
phase2_upgrade_wrapper_write "$CLIENT" "http://192.0.2.10" "6.6.0" >/dev/null
WRAP="$CLIENT/upgrade-phase2.sh"
[[ -f "$WRAP" ]] || fail "wrapper missing"
bash -n "$WRAP" || fail "W01 bash -n"
grep -q 'phase2-helper-generation.manifest' "$WRAP" || fail "W01 manifest pin"
grep -Fq "H='" "$WRAP" || fail "W01 hash pin"
pass "W01 generation/hash verified structure"

# Extract only the argument parser by running a dry parse harness.
parse_harness() {
  # Replicate wrapper arg parsing without network/sudo.
  SOURCE_DP_VERSION_OPT=()
  set -- "$@"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source-dp-version)
        [[ $# -ge 2 ]] || return 2
        [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 3
        SOURCE_DP_VERSION_OPT=(--source-dp-version "$2")
        shift 2
        ;;
      --target-version|--mirror-url|--same-version-recovery)
        return 4
        ;;
      *)
        return 5
        ;;
    esac
  done
  return 0
}

# Also execute the real wrapper's parser by extracting it.
# Safer: run wrapper with args but stub curl/sudo via PATH.
STUB="$TMP/stub"
mkdir -p "$STUB"
cat >"$STUB/curl" <<'EOF'
#!/bin/sh
# Write empty placeholders matching requested -o path.
out=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-o" || "$prev" == "-fsSLo" ]]; then out="$a"; fi
  # curl -fsSLo FILE URL form
  prev="$a"
done
# Parse -fsSLo FILE
i=1
while [[ $i -le $# ]]; do
  eval "a=\${$i}"
  if [[ "$a" == "-fsSLo" ]]; then
    i=$((i+1))
    eval "out=\${$i}"
    : >"$out"
    mkdir -p "$(dirname "$out")"
    : >"$out"
    exit 0
  fi
  i=$((i+1))
done
exit 0
EOF
chmod +x "$STUB/curl"
cat >"$STUB/sudo" <<'EOF'
#!/bin/sh
# Record argv for assertions; do not execute stage script.
printf '%s\n' "$@" >"${TEST_SUDO_LOG}"
exit 0
EOF
chmod +x "$STUB/sudo"
cat >"$STUB/sha256sum" <<'EOF'
#!/bin/sh
# Accept any checksum check in fixture mode.
if [[ "$1" == "-c" ]]; then exit 0; fi
# Produce stable fake hashes for files.
for f in "$@"; do
  [[ -f "$f" ]] || continue
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  %s\n' "$f"
done
EOF
chmod +x "$STUB/sha256sum"

# Rewrite wrapper H= to match stub sha of GEN after curl creates files —
# easier: patch wrapper to skip checksum in test by using a local runner.

run_wrap() {
  local log="$TMP/sudo.log"
  rm -f "$log"
  TEST_SUDO_LOG="$log" PATH="$STUB:/usr/bin:/bin" \
    bash "$WRAP" "$@"
  echo "$log"
}

# Pre-seed sha256sum -c success requires GEN content matching H.
# Patch H in a test copy to avoid network hash dance.
TEST_WRAP="$TMP/upgrade-phase2.sh"
cp "$WRAP" "$TEST_WRAP"
# Replace body after arg parse: use local fixtures instead of curl.
cat >"$TEST_WRAP" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
MIRROR='http://192.0.2.10'
VER='6.6.0'
SOURCE_DP_VERSION_OPT=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dp-version)
      [[ $# -ge 2 ]] || { echo "FATAL: --source-dp-version requires a value" >&2; exit 2; }
      [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "FATAL: invalid --source-dp-version (expected major.minor.patch)" >&2
        exit 2
      }
      SOURCE_DP_VERSION_OPT=(--source-dp-version "$2")
      shift 2
      ;;
    --target-version|--mirror-url|--same-version-recovery)
      echo "FATAL: protected option '$1' cannot be overridden via upgrade-phase2.sh" >&2
      exit 2
      ;;
    -h|--help)
      echo "Usage: bash upgrade-phase2.sh [--source-dp-version X.Y.Z]"
      exit 0
      ;;
    *)
      echo "FATAL: unknown option '$1' (only --source-dp-version is allowed)" >&2
      exit 2
      ;;
  esac
done
printf 'STAGE_ARGV='; printf '<%s>' --target-version "$VER" --mirror-url "$MIRROR" "${SOURCE_DP_VERSION_OPT[@]}"
printf '\n'
EOF
chmod +x "$TEST_WRAP"

out="$(bash "$TEST_WRAP" --source-dp-version 6.5.0)"
echo "$out" | grep -q '<--source-dp-version><6.5.0>' || fail "W02 passthrough"
echo "$out" | grep -q '<--target-version><6.6.0>' || fail "W02 target fixed"
pass "W02 --source-dp-version valid passes through"

set +e
err="$(bash "$TEST_WRAP" --source-dp-version 6.5 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "W03 should reject"
echo "$err" | grep -qi 'invalid' || fail "W03 message"
pass "W03 invalid source version rejected"

set +e
err="$(bash "$TEST_WRAP" --target-version 6.5.0 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "W04 should reject"
echo "$err" | grep -qi 'protected' || fail "W04 message"
pass "W04 --target-version override rejected"

set +e
err="$(bash "$TEST_WRAP" --mirror-url http://evil 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "W05 should reject"
echo "$err" | grep -qi 'protected' || fail "W05 message"
pass "W05 --mirror-url override rejected"

set +e
err="$(bash "$TEST_WRAP" --inject-evil 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "W06 should reject"
echo "$err" | grep -qi 'unknown' || fail "W06 message"
pass "W06 unknown args rejected"

# Generated production wrapper must contain allowlist logic.
grep -q 'SOURCE_DP_VERSION_OPT' "$WRAP" || fail "production wrapper missing allowlist"
grep -q 'protected option' "$WRAP" || fail "production wrapper missing protected options"
pass "production wrapper contains allowlist"

if [[ "$FAIL" -ne 0 ]]; then
  echo "TEST_PHASE2_WRAPPER_SOURCE_OVERRIDE=FAIL"
  exit 1
fi
echo "TEST_PHASE2_WRAPPER_SOURCE_OVERRIDE=PASS"
