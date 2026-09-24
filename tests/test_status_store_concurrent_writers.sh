#!/usr/bin/env bash
# Concurrent mm_status_set writers must not lose keys or resurrect stale PASS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
WRITERS="${STATUS_CONCURRENT_WRITERS:-80}"
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }

export MM_PROJECT_ROOT="$ROOT"
export MM_CONFIG_DIR="$TMP/config"
export MM_STATUS_FILE="$MM_CONFIG_DIR/dp-upgrade-mirror.status"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_HERMETIC_TEST_MODE=1
export MM_SKIP_ROOT_CHECK=1
mkdir -p "$MM_CONFIG_DIR"

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"

status_get() {
  local key="$1"
  awk -F= -v k="$key" '$1==k { print substr($0, length($1) + 2); exit }' "$MM_STATUS_FILE" 2>/dev/null || true
}

writer="$TMP/writer.sh"
cat >"$writer" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$1"
STATUS="$2"
KEY="$3"
VAL="$4"
export MM_PROJECT_ROOT="$ROOT"
export MM_STATUS_FILE="$STATUS"
export MM_CONFIG_DIR="$(dirname "$STATUS")"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_HERMETIC_TEST_MODE=1
export MM_SKIP_ROOT_CHECK=1
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
mm_status_set "$KEY" "$VAL"
EOS
chmod 0700 "$writer"

echo "======== test_status_store_concurrent_writers ========"

# Seed a PASS gate that concurrent unique-key writers must not resurrect/erase.
cat >"$MM_STATUS_FILE" <<'EOF'
UPGRADE_READINESS=FAIL
PHASE2_BUNDLE_CHECKSUM=current
EOF
chmod 600 "$MM_STATUS_FILE"

pids=()
for i in $(seq 1 "$WRITERS"); do
  bash "$writer" "$ROOT" "$MM_STATUS_FILE" "KEY_${i}" "VAL_${i}" &
  pids+=("$!")
done
rc_fail=0
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    rc_fail=$((rc_fail + 1))
  fi
done
[[ "$rc_fail" -eq 0 ]] && pass "all ${WRITERS} writers exited 0" || fail "writer failures=${rc_fail}"

actual=0
missing=0
for i in $(seq 1 "$WRITERS"); do
  got="$(status_get "KEY_${i}")"
  if [[ "$got" == "VAL_${i}" ]]; then
    actual=$((actual + 1))
  else
    missing=$((missing + 1))
  fi
done
[[ "$actual" -eq "$WRITERS" && "$missing" -eq 0 ]] \
  && pass "no lost keys EXPECTED=${WRITERS} ACTUAL=${actual} LOST=${missing}" \
  || fail "lost keys EXPECTED=${WRITERS} ACTUAL=${actual} LOST=${missing}"

[[ "$(status_get UPGRADE_READINESS)" == "FAIL" ]] \
  && pass "seeded UPGRADE_READINESS=FAIL preserved (no stale PASS resurrection)" \
  || fail "UPGRADE_READINESS resurrected or lost: $(status_get UPGRADE_READINESS)"
[[ "$(status_get PHASE2_BUNDLE_CHECKSUM)" == "current" ]] \
  && pass "seeded PHASE2_BUNDLE_CHECKSUM preserved" \
  || fail "PHASE2_BUNDLE_CHECKSUM lost: $(status_get PHASE2_BUNDLE_CHECKSUM)"

# mm_state_set inherits the same lock (no lost key vs concurrent mm_status_set).
export MM_STATE_DIR="$TMP/state"
mkdir -p "$MM_STATE_DIR"
: >"${MM_STATE_DIR}/state.env"
bash "$writer" "$ROOT" "$MM_STATUS_FILE" KEY_STATUS status_only &
pid_s=$!
(
  export MM_PROJECT_ROOT="$ROOT"
  export MM_STATUS_FILE
  export MM_CONFIG_DIR="$(dirname "$MM_STATUS_FILE")"
  export MM_STATE_DIR
  export SKIP_MIRROR_HOST_VALIDATE=1
  export MM_HERMETIC_TEST_MODE=1
  export MM_SKIP_ROOT_CHECK=1
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/lib/mirror_manager_common.sh"
  mm_state_set KEY_STATE state_only
) &
pid_t=$!
wait "$pid_s"
wait "$pid_t"
[[ "$(status_get KEY_STATUS)" == "status_only" && "$(status_get KEY_STATE)" == "state_only" ]] \
  && pass "mm_state_set and mm_status_set both applied" \
  || fail "state/status concurrent lost KEY_STATUS=$(status_get KEY_STATUS) KEY_STATE=$(status_get KEY_STATE)"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
echo "ALL PASS"
exit 0
