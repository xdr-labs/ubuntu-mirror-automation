#!/usr/bin/env bash
# Targeted contract tests for immutable Phase 1 source DP version evidence.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/client/lib/dp-offline-source-product-version.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
expect_fail() { "$@" && fail "unexpected success: $*" || true; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3 (got=$1 want=$2)"; }
write_log_record() {
  local version="$1" source="${2:-aella_cli}" consistency="${3:-PASS}"
  cat <<EOF
DP_VERSION=${version}
DP_VERSION_SOURCE=${source}
DP_VERSION_DETECT_STATUS=ok
DP_VERSION_CONSISTENCY=${consistency}
EOF
}

export SOURCE_PRODUCT_ENV_DEFAULT_PATH="${TMP}/source-product.env"
export SOURCE_PRODUCT_PHASE1_LOG_DEFAULT="${TMP}/phase1.log"
export SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT="${TMP}/release-image.yml"
export SOURCE_PRODUCT_EVIDENCE_ROOT_DEFAULT="${TMP}/evidence"
export SOURCE_PRODUCT_OS_STATE_FILE="${TMP}/root/state"
export SOURCE_PRODUCT_BRINGUP_RESULT_ENV="${TMP}/root/bringup-result.env"
# shellcheck source=/dev/null
source "$LIB"

echo "=== test_source_product_version ==="

# Xenial-style aella_cli capture: persistent, private, valid evidence.
spv_persist_source_product_env "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" "6.5.0" aella_cli 16.04 xenial run-x \
  || fail "aella_cli capture"
spv_read_source_product_env "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" || fail "read persisted capture"
assert_eq "$SPV_SOURCE_DP_VERSION" 6.5.0 "captured version"
assert_eq "$SPV_SOURCE_DP_VERSION_ORIGIN" aella_cli "captured origin"
assert_eq "$(stat -c %a "$SOURCE_PRODUCT_ENV_DEFAULT_PATH")" 600 "capture mode"
if [[ "$(id -u)" -eq 0 ]]; then
  assert_eq "$(stat -c %U:%G "$SOURCE_PRODUCT_ENV_DEFAULT_PATH")" root:root "root ownership"
else
  echo "SKIP: owner check requires root"
fi
pass "Xenial aella_cli capture has private evidence"

# An interrupted/partial file is never accepted as authoritative PASS.
printf 'SOURCE_DP_VERSION=6.5.0\n' >"${TMP}/partial.env"
expect_fail spv_read_source_product_env "${TMP}/partial.env"
[[ "$SPV_SOURCE_PRODUCT_ENV_STATUS" != PASS ]] || fail "partial write accepted"
pass "partial env is not authoritative"

expect_fail spv_persist_source_product_env "${TMP}/bad.env" "6.5.bad" aella_cli
assert_eq "$SPV_SOURCE_VERSION_CAPTURE_STATUS" REJECTED_INVALID_VERSION "malformed version status"
spv_persist_source_product_env "${TMP}/same.env" 6.5.0 aella_cli
spv_persist_source_product_env "${TMP}/same.env" 6.5.0 aella_cli
assert_eq "$SPV_SOURCE_VERSION_CAPTURE_STATUS" REUSED "same version reuse"
expect_fail spv_persist_source_product_env "${TMP}/same.env" 6.4.0 aella_cli
assert_eq "$SPV_SOURCE_VERSION_CAPTURE_STATUS" VERSION_CONFLICT "conflicting version status"
expect_fail spv_persist_source_product_env "${TMP}/same.env" UNDETERMINED aella_cli
spv_read_source_product_env "${TMP}/same.env" || fail "good record lost after bad update"
assert_eq "$SPV_SOURCE_DP_VERSION" 6.5.0 "bad update did not overwrite PASS"
pass "write validation and fail-closed reuse work"

# Phase 1 recovery only accepts complete consistent PASS records.
mkdir -p "$(dirname "$SOURCE_PRODUCT_OS_STATE_FILE")"
printf 'COMPLETED_NOBLE\n' >"$SOURCE_PRODUCT_OS_STATE_FILE"
rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" "$SOURCE_PRODUCT_BRINGUP_RESULT_ENV"
{ write_log_record 6.5.0; write_log_record 6.5.0; write_log_record 6.5.0; write_log_record UNDETERMINED aella_cli PASS; } >"$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT"
spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" \
  "${TMP}/missing-release.yml" "" 1 recovery 1 || fail "Phase 1 recovery"
assert_eq "$SPV_SOURCE_DP_VERSION" 6.5.0 "recovered version"
assert_eq "$SPV_SOURCE_DP_VERSION_ORIGIN" phase1-log-recovery "recovery origin"
assert_eq "$SPV_PHASE1_LOG_EVIDENCE_UNDETERMINED_COUNT" 1 "later undetermined counted"
pass "Phase 1 recovery retains earlier PASS evidence"

{ write_log_record 6.4.0; write_log_record 6.5.0; } >"$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT"
expect_fail spv_scan_phase1_log_evidence "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" 1
assert_eq "$SPV_PHASE1_LOG_EVIDENCE_STATUS" MULTIPLE_VERSIONS "conflicting Phase 1 evidence"
printf 'DP_VERSION=6.5.0\nDP_VERSION_SOURCE=aella_cli\nDP_VERSION_DETECT_STATUS=ok\n' >"$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT"
expect_fail spv_scan_phase1_log_evidence "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" 1
assert_eq "$SPV_PHASE1_LOG_EVIDENCE_STATUS" NO_COMPLETE_RECORD "incomplete record"
write_log_record 6.5.0 FAKE >"$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT"
expect_fail spv_scan_phase1_log_evidence "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" 1
[[ "$SPV_PHASE1_LOG_EVIDENCE_STATUS" != PASS ]] || fail "fake source accepted in production mode"
pass "incomplete, conflicting, and fake Phase 1 evidence fail closed"

cat >"$SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT" <<'EOF'
aella-cm-master: 6.5.0
aella-cm-worker: 6.5.0-ubuntu1
EOF
spv_detect_from_release_image "$SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT" || fail "valid release image"
assert_eq "$SPV_RELEASE_SELECTED_VERSION" 6.5.0 "release image version"
printf 'aella-cm-master: 6.4.0\naella-cm-worker: 6.5.0\n' >"$SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT"
expect_fail spv_detect_from_release_image "$SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT"
assert_eq "$SPV_RELEASE_IMAGE_STATUS" VERSION_CONFLICT "release conflict"
printf 'unrelated: 6.5.0\n' >"$SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT"
expect_fail spv_detect_from_release_image "$SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT"
assert_eq "$SPV_RELEASE_IMAGE_STATUS" NO_AUTHORITATIVE_KEYS "zero authoritative keys"
printf 'aella-cm-master: nope\naella-cm-worker: 6.5.0\n' >"$SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT"
expect_fail spv_detect_from_release_image "$SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT"
assert_eq "$SPV_RELEASE_IMAGE_STATUS" MALFORMED_AUTHORITATIVE_ENTRY "malformed authoritative key"
pass "release image authority validation works"

# Override validation/conflict and full diagnostic failure remain explicit.
spv_persist_source_product_env "${TMP}/override.env" 6.5.0 aella_cli
expect_fail spv_resolve_source_dp_version "${TMP}/override.env" "${TMP}/none.log" "${TMP}/none.yml" bogus 0 test 1
assert_eq "$SPV_SOURCE_DP_VERSION_FAILURE_REASON" OPERATOR_OVERRIDE_INVALID "invalid override"
expect_fail spv_resolve_source_dp_version "${TMP}/override.env" "${TMP}/none.log" "${TMP}/none.yml" 6.4.0 0 test 1
assert_eq "$SPV_SOURCE_DP_VERSION_FAILURE_REASON" OPERATOR_OVERRIDE_CONFLICT "override conflict"
rm -f "${TMP}/all-absent.env"
expect_fail spv_resolve_source_dp_version "${TMP}/all-absent.env" "${TMP}/none.log" "${TMP}/none.yml" "" 0 test 1
assert_eq "$SPV_SOURCE_DP_VERSION_FAILURE_REASON" NO_VALID_AUTHORITATIVE_SOURCE "all absent diagnostic"
[[ "$SPV_SOURCE_DP_VERSION_FAILURE_REASON" != *FAIL_UNKNOWN* ]] || fail "legacy unknown diagnostic"

# Diagnose/read-only recovery must never write source-product.env.
write_log_record 6.5.0 aella_cli >"$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT"
rm -f "${TMP}/readonly.env"
spv_resolve_source_dp_version "${TMP}/readonly.env" "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" "${TMP}/none.yml" "" 0 readonly 1 \
  || fail "read-only recovery"
[[ ! -e "${TMP}/readonly.env" ]] || fail "read-only diagnosis wrote env"
assert_eq "$SPV_SOURCE_DP_VERSION_RECOVERY" WOULD_WRITE "read-only marker"
pass "diagnostics are read-only"

# Normalize extended release tokens to strict X.Y.Z.
assert_eq "$(spv_normalize_dp_version '6.5.0.7942')" 6.5.0 "normalize build suffix"
assert_eq "$(spv_normalize_dp_version '6.5.0.7942-9ed2e58c1')" 6.5.0 "normalize build+hash"
pass "normalize 6.5.0.7942 forms to 6.5.0"

# Persist failure with allow_write=1 fails resolution (dest parent not a directory).
export SOURCE_PRODUCT_OS_RELEASE_FILE="${TMP}/os-release"
cat >"$SOURCE_PRODUCT_OS_RELEASE_FILE" <<'EOF'
ID=ubuntu
VERSION_ID=24.04
VERSION_CODENAME=noble
EOF
printf 'COMPLETED_NOBLE\n' >"$SOURCE_PRODUCT_OS_STATE_FILE"
rm -f "$SOURCE_PRODUCT_BRINGUP_RESULT_ENV" "$SOURCE_PRODUCT_ENV_DEFAULT_PATH"
write_log_record 6.5.0 aella_cli >"$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT"
touch "${TMP}/blocked-parent"
expect_fail spv_resolve_source_dp_version \
  "${TMP}/blocked-parent/source-product.env" \
  "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" \
  "${TMP}/none.yml" "" 1 persist-fail 1
assert_eq "$SPV_SOURCE_DP_VERSION_FAILURE_REASON" SOURCE_PRODUCT_ENV_WRITE_FAILED \
  "persist failure fail-closed"
pass "persist failure with allow_write=1 fails resolution"

# AMBIGUOUS_NOBLE fail closed (partial noble identity).
cat >"$SOURCE_PRODUCT_OS_RELEASE_FILE" <<'EOF'
VERSION_ID=24.04
VERSION_CODENAME=noble
EOF
rm -f "$SOURCE_PRODUCT_ENV_DEFAULT_PATH" "$SOURCE_PRODUCT_OS_STATE_FILE"
expect_fail spv_resolve_source_dp_version \
  "${TMP}/ambiguous.env" \
  "${TMP}/none.log" \
  "${TMP}/none.yml" "" 0 ambiguous 1
assert_eq "$SPV_SOURCE_DP_VERSION_FAILURE_REASON" AMBIGUOUS_NOBLE_ORIGIN \
  "AMBIGUOUS_NOBLE fail closed"
pass "AMBIGUOUS_NOBLE fail closed"

echo "TEST_SOURCE_PRODUCT_VERSION=PASS"
