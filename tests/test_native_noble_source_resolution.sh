#!/usr/bin/env bash
# N01–N14 / P01–P05: Native Noble vs Post-Phase1 source resolution.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/client/lib/dp-offline-source-product-version.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }
assert_eq() { [[ "$1" == "$2" ]] || { fail "$3 (got=$1 want=$2)"; return 1; }; }

export SOURCE_PRODUCT_ENV_DEFAULT_PATH="${TMP}/source-product.env"
export SOURCE_PRODUCT_PHASE1_LOG_DEFAULT="${TMP}/phase1.log"
export SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT="${TMP}/release-image.yml"
export SOURCE_PRODUCT_EVIDENCE_ROOT_DEFAULT="${TMP}/evidence"
export SOURCE_PRODUCT_OS_STATE_FILE="${TMP}/os-state"
export SOURCE_PRODUCT_BRINGUP_RESULT_ENV="${TMP}/bringup-result.env"
export SOURCE_PRODUCT_OS_RELEASE_FILE="${TMP}/os-release"

# shellcheck source=/dev/null
source "$LIB"

write_noble_os() {
  cat >"$SOURCE_PRODUCT_OS_RELEASE_FILE" <<'EOF'
ID=ubuntu
VERSION_ID=24.04
VERSION_CODENAME=noble
EOF
}

write_jammy_os() {
  cat >"$SOURCE_PRODUCT_OS_RELEASE_FILE" <<'EOF'
ID=ubuntu
VERSION_ID=22.04
VERSION_CODENAME=jammy
EOF
}

install_fake_aella_cli() {
  local version="$1"
  local mode="${2:-ok}" # ok|timeout|nonzero|multi|missing-handled
  local bin="$TMP/bin"
  mkdir -p "$bin"
  PATH="$bin:$PATH"
  export PATH
  case "$mode" in
    ok)
      cat >"$bin/aella_cli" <<EOF
#!/bin/sh
cat <<'OUT'
Welcome
DataProcessor(AIO)> show version
${version}
DataProcessor(AIO)> quit
OUT
EOF
      ;;
    multi)
      cat >"$bin/aella_cli" <<EOF
#!/bin/sh
cat <<'OUT'
6.4.0
6.5.0
OUT
EOF
      ;;
    nonzero)
      cat >"$bin/aella_cli" <<'EOF'
#!/bin/sh
echo boom >&2
exit 7
EOF
      ;;
    timeout)
      cat >"$bin/aella_cli" <<'EOF'
#!/bin/sh
sleep 30
EOF
      ;;
  esac
  chmod +x "$bin/aella_cli"
  # Ensure timeout exists (system).
  command -v timeout >/dev/null
}

remove_aella_cli() {
  rm -f "$TMP/bin/aella_cli"
  # Keep PATH but without aella_cli
}

write_release_ok() {
  local ver="$1"
  cat >"$SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT" <<EOF
aella-cm-master: ${ver}
aella-cm-worker: ${ver}
stellar-conf: ${ver}
stellar-controller: ${ver}
EOF
}

echo "=== native noble / post-phase1 source resolution ==="

write_noble_os
rm -f "$SOURCE_PRODUCT_OS_STATE_FILE" "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
  "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" "$SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT"

# N01–N04 live detection for 6.2–6.5
for ver in 6.2.0 6.3.0 6.4.0 6.5.0; do
  rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH"
  install_fake_aella_cli "$ver" ok
  if spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
      "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" "${TMP}/missing.yml" "" 1 "n-$ver" 1; then
    assert_eq "$SPV_PHASE2_ENTRY_MODE" NATIVE_NOBLE "entry mode $ver" || true
    assert_eq "$SPV_AELLA_CLI_VERSION_DETECTION" PASS "cli detect $ver" || true
    assert_eq "$SPV_SOURCE_DP_VERSION" "$ver" "resolved $ver" || true
    assert_eq "$SPV_SOURCE_DP_VERSION_ORIGIN" aella_cli-native-noble "origin $ver" || true
    assert_eq "$SPV_SOURCE_DP_VERSION_RESOLUTION" PASS "resolution $ver" || true
    pass "N live $ver PASS"
  else
    fail "N live $ver resolve failed reason=${SPV_SOURCE_DP_VERSION_FAILURE_REASON}"
  fi
done

# N05 persist schema/mode/origin
rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH"
install_fake_aella_cli 6.5.0 ok
spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
  "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" "${TMP}/missing.yml" "" 1 n05 1 \
  || fail "N05 resolve"
[[ -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" ]] || fail "N05 env missing"
assert_eq "$(stat -c %a "$SOURCE_PRODUCT_ENV_DEFAULT_PATH")" 600 "N05 mode" || true
grep -q 'SOURCE_DP_VERSION_ORIGIN=aella_cli-native-noble' "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
  || fail "N05 origin in file"
grep -q 'SOURCE_PRODUCT_ENV_SCHEMA_VERSION=1' "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
  || fail "N05 schema"
pass "N05 persisted source-product.env"

# N06 reuse persisted (no re-probe required even if CLI removed)
remove_aella_cli
spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
  "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" "${TMP}/missing.yml" "" 1 n06 1 \
  || fail "N06 reuse"
assert_eq "$SPV_SOURCE_DP_VERSION" 6.5.0 "N06 version" || true
assert_eq "$SPV_SOURCE_DP_VERSION_RESOLUTION" PASS "N06 pass" || true
pass "N06 rerun reuses persisted evidence"

# N07 inconsistent multi versions
rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH"
install_fake_aella_cli x multi
if spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
    "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" "${TMP}/missing.yml" "" 1 n07 1; then
  fail "N07 should fail closed on inconsistent CLI"
else
  assert_eq "$SPV_SOURCE_DP_VERSION_FAILURE_REASON" AELLA_CLI_INCONSISTENT_VERSIONS "N07 reason" || true
  pass "N07 inconsistent CLI fail closed"
fi

# N08 timeout → fall through; with no release/operator → fail
rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH"
install_fake_aella_cli 6.5.0 timeout
if spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
    "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" "${TMP}/missing.yml" "" 1 n08 1; then
  fail "N08 unexpected pass without fallback"
else
  [[ "$SPV_AELLA_CLI_VERSION_DETECTION" == "TIMEOUT" ]] \
    || fail "N08 expected TIMEOUT got ${SPV_AELLA_CLI_VERSION_DETECTION}"
  pass "N08 timeout recorded then fail closed"
fi

# N09 nonzero
rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH"
install_fake_aella_cli 6.5.0 nonzero
if spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
    "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" "${TMP}/missing.yml" "" 1 n09 1; then
  fail "N09 unexpected pass"
else
  [[ "$SPV_AELLA_CLI_VERSION_DETECTION" == "NONZERO" ]] || fail "N09 NONZERO"
  pass "N09 nonzero fail path"
fi

# N10 missing CLI + valid release image
rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" "$TMP/bin/aella_cli"
write_release_ok 6.4.0
spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
  "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" "$SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT" "" 1 n10 1 \
  || fail "N10 release fallback"
assert_eq "$SPV_SOURCE_DP_VERSION" 6.4.0 "N10 version" || true
assert_eq "$SPV_SOURCE_DP_VERSION_ORIGIN" release-image.yml "N10 origin" || true
pass "N10 release-image fallback PASS"

# N11 all native sources missing
rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" "$SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT" "$TMP/bin/aella_cli"
if spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
    "${TMP}/none.log" "${TMP}/none.yml" "" 1 n11 1; then
  fail "N11 should fail"
else
  assert_eq "$SPV_SOURCE_DP_VERSION_FAILURE_REASON" NO_VALID_AUTHORITATIVE_SOURCE "N11" || true
  pass "N11 all missing fail closed"
fi

# N12/N13 compatibility are enforced by stage-dp-phase2; spot-check normalize only here.
# Full compat covered in test_dp_phase2_version_compat.sh — add explicit native origin notes:
install_fake_aella_cli 6.1.0 ok
rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH"
spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
  "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" "${TMP}/missing.yml" "" 1 n12 1 \
  || fail "N12 resolve 6.1.0 should still resolve (compat checked later)"
assert_eq "$SPV_SOURCE_DP_VERSION" 6.1.0 "N12 captured unsupported source" || true
pass "N12 source <6.2.0 still captured for later FAIL_UNSUPPORTED"

install_fake_aella_cli 6.7.0 ok
rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH"
spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
  "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" "${TMP}/missing.yml" "" 1 n13 1 \
  || fail "N13 resolve 6.7.0"
assert_eq "$SPV_SOURCE_DP_VERSION" 6.7.0 "N13 captured downgrade source" || true
pass "N13 source >6.6.0 captured for later FAIL_DOWNGRADE"

# N14 already at target captured; stage treats ALREADY_AT_TARGET when not POST_PHASE1
install_fake_aella_cli 6.6.0 ok
rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH"
spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
  "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" "${TMP}/missing.yml" "" 1 n14 1 \
  || fail "N14 resolve 6.6.0"
assert_eq "$SPV_SOURCE_DP_VERSION" 6.6.0 "N14" || true
assert_eq "$SPV_PHASE2_ENTRY_MODE" NATIVE_NOBLE "N14 entry" || true
pass "N14 native 6.6.0 resolved (ALREADY_AT_TARGET at stage)"

# P01 existing env without live CLI
rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH"
printf 'COMPLETED_NOBLE\n' >"$SOURCE_PRODUCT_OS_STATE_FILE"
spv_persist_source_product_env "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" 6.5.0 phase1-log-recovery 24.04 noble p01 \
  || fail "P01 persist"
remove_aella_cli
spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
  "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" "${TMP}/missing.yml" "" 1 p01 1 \
  || fail "P01"
assert_eq "$SPV_PHASE2_ENTRY_MODE" POST_PHASE1_NOBLE "P01 entry" || true
assert_eq "$SPV_SOURCE_DP_VERSION_RESOLUTION" PASS "P01" || true
pass "P01 Post-Phase1 uses env without live CLI"

# P02 Phase1 log recovery
rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" "$SOURCE_PRODUCT_BRINGUP_RESULT_ENV"
cat >"$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" <<'EOF'
DP_VERSION=6.5.0
DP_VERSION_SOURCE=aella_cli
DP_VERSION_DETECT_STATUS=ok
DP_VERSION_CONSISTENCY=PASS
EOF
spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
  "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" "${TMP}/missing.yml" "" 1 p02 1 \
  || fail "P02"
assert_eq "$SPV_SOURCE_DP_VERSION_ORIGIN" phase1-log-recovery "P02 origin" || true
pass "P02 COMPLETED_NOBLE Phase1 log recovery"

# P03 conflicting Phase1 versions
rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH"
cat >"$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" <<'EOF'
DP_VERSION=6.4.0
DP_VERSION_SOURCE=aella_cli
DP_VERSION_DETECT_STATUS=ok
DP_VERSION_CONSISTENCY=PASS
DP_VERSION=6.5.0
DP_VERSION_SOURCE=aella_cli
DP_VERSION_DETECT_STATUS=ok
DP_VERSION_CONSISTENCY=PASS
EOF
if spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
    "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" "${TMP}/missing.yml" "" 1 p03 1; then
  fail "P03 should fail"
else
  assert_eq "$SPV_SOURCE_DP_VERSION_FAILURE_REASON" PHASE1_EVIDENCE_MULTIPLE_VERSIONS "P03" || true
  pass "P03 conflicting Phase1 fail closed"
fi

# P04 Post-Phase1 must NOT trust live CLI over immutable env conflict
rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH"
spv_persist_source_product_env "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" 6.5.0 phase1-log-recovery 24.04 noble p04 \
  || fail "P04 persist"
install_fake_aella_cli 6.4.0 ok
# Still PASS from env; live CLI is skipped on POST_PHASE1 (no conflict path via CLI)
spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
  "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" "${TMP}/missing.yml" "" 1 p04 1 \
  || fail "P04"
assert_eq "$SPV_SOURCE_DP_VERSION" 6.5.0 "P04 keeps immutable" || true
# Env hit returns before setting SKIPPED — ensure version not overwritten by live 6.4.0
[[ "$SPV_SOURCE_DP_VERSION" != "6.4.0" ]] || fail "P04 live CLI overrode immutable"
pass "P04 Post-Phase1 ignores live CLI when env present"

# P05 Phase1 evidence unavailable → release/operator fallback preserved
rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT"
write_release_ok 6.3.0
spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
  "${TMP}/none.log" "$SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT" "" 1 p05 1 \
  || fail "P05"
assert_eq "$SPV_SOURCE_DP_VERSION_ORIGIN" release-image.yml "P05" || true
pass "P05 Post-Phase1 release-image fallback"

# Native conflict: persisted vs live
write_noble_os
rm -f "$SOURCE_PRODUCT_OS_STATE_FILE" "$SOURCE_PRODUCT_ENV_DEFAULT_PATH"
spv_persist_source_product_env "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" 6.5.0 aella_cli-native-noble 24.04 noble nc \
  || fail "native conflict persist"
install_fake_aella_cli 6.4.0 ok
if spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" \
    "${TMP}/none.log" "${TMP}/none.yml" "" 1 nc 1; then
  fail "native conflict should fail"
else
  assert_eq "$SPV_SOURCE_DP_VERSION_FAILURE_REASON" NATIVE_LIVE_CLI_CONFLICT "native conflict" || true
  pass "Native persisted vs live CLI conflict fail closed"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "TEST_NATIVE_NOBLE_SOURCE_RESOLUTION=FAIL"
  exit 1
fi
echo "TEST_NATIVE_NOBLE_SOURCE_RESOLUTION=PASS"
