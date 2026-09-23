#!/usr/bin/env bash
# Publication mutators share one lock; legacy sync publishes prereqs before current.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }

echo "======== test_publication_mutation_lock ========"

COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
DP2="${ROOT}/scripts/download-dp-phase2.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"

grep -q 'MM_LOCK_FILE=.*ubuntu-mirror-publication.lock' "$COMMON" \
  && pass "manager lock is publication lock" \
  || fail "manager lock path drifted"
grep -q 'DP_PHASE2_LOCK_FILE=.*ubuntu-mirror-publication.lock' "$DP2" \
  && pass "legacy phase2 lock is publication lock" \
  || fail "legacy phase2 lock path drifted"
grep -q 'mm_acquire_install_lock' "$ENGINE" \
  && grep -A12 '^engine_enable_http_distribution()' "$ENGINE" | grep -q 'mm_acquire_install_lock' \
  && pass "enable-http takes publication lock" \
  || fail "enable-http missing publication lock"

# Menu 2 holder blocks enable-http acquire (same flock).
export MM_PROJECT_ROOT="$ROOT"
export MM_LOCK_FILE="$TMP/publication.lock"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_HERMETIC_TEST_MODE=1
export MM_SKIP_ROOT_CHECK=1
# shellcheck source=/dev/null
source "$COMMON"
mm_acquire_install_lock >/dev/null
set +e
(
  export MM_PROJECT_ROOT="$ROOT"
  export MM_LOCK_FILE
  export SKIP_MIRROR_HOST_VALIDATE=1
  export MM_HERMETIC_TEST_MODE=1
  export MM_SKIP_ROOT_CHECK=1
  # shellcheck source=/dev/null
  source "$COMMON"
  mm_acquire_install_lock
) >"$TMP/b.out" 2>"$TMP/b.err"
BRC=$?
set -e
[[ "$BRC" -ne 0 ]] && grep -q 'INSTALL_LOCK=BUSY' "$TMP/b.err" \
  && pass "enable-http/menu2 lock excludes a second mutator" \
  || fail "second mutator was not busy rc=${BRC}"

# Legacy sync lock file is the same path: a second flock -n fails.
exec {dfd}>"$MM_LOCK_FILE"
if flock -n "$dfd"; then
  fail "legacy-equivalent flock acquired while menu2 holds publication lock"
else
  pass "legacy phase2 flock shares menu2 publication lock"
fi
eval "exec ${dfd}>&-"
mm_release_install_lock

# Overlapping client finalizers: two processes cannot both hold the publication lock.
mm_acquire_install_lock >/dev/null
set +e
(
  export MM_PROJECT_ROOT="$ROOT"
  export MM_LOCK_FILE
  export SKIP_MIRROR_HOST_VALIDATE=1
  export MM_HERMETIC_TEST_MODE=1
  export MM_SKIP_ROOT_CHECK=1
  # shellcheck source=/dev/null
  source "$COMMON"
  mm_acquire_install_lock
) >"$TMP/c.out" 2>"$TMP/c.err"
CRC=$?
set -e
[[ "$CRC" -ne 0 ]] && grep -q 'INSTALL_LOCK=BUSY' "$TMP/c.err" \
  && pass "overlapping finalizer/mutator blocked" \
  || fail "overlapping mutator not blocked rc=${CRC}"
mm_release_install_lock

# Legacy publish order: prerequisite contract before public pointer.
python3 - "$DP2" <<'PY' && pass "prereq contract precedes publish_atomic" || fail "publish still precedes prereq"
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
idx = text.rfind("cmd_sync() {")
body = text[idx:]
# Stop at the next top-level function.
end = body.find("\ncmd_verify()")
body = body[:end]
pre = body.find("prepare-phase2-ubuntu-prerequisites.sh")
pub = body.find("publish_atomic ")
assert pre > 0 and pub > 0 and pre < pub, (pre, pub)
PY

# verify refuses a generation missing the prerequisite contract.
export DP_PHASE2_LIB_ONLY=1
export DP_PHASE2_ROOT="$TMP/dp"
export DP_PHASE2_VERSION=6.6.0
export DP_PHASE2_SKIP_ROOT_CHECK=1
export DP_PHASE2_LOCK_FILE="$TMP/dp2.lock"
# shellcheck source=/dev/null
source "$DP2"
trap - EXIT
export DP_PHASE2_LOG_FILE="$TMP/dp2.log"
REL="$TMP/dp/6.6.0/releases/r1"
mkdir -p "$REL/extras"
printf 'PHASE2_PREREQ_BUILD=FAIL\nTARGET_DP_VERSION=6.6.0\n' >"$REL/extras/phase2-ubuntu-prerequisites.state"
set +e
(
  trap - EXIT
  verify_release_prereq_contract "$REL"
) >"$TMP/v.out" 2>"$TMP/v.err"
VRC=$?
set -e
[[ "$VRC" -ne 0 ]] && grep -q 'VERIFY=FAIL' "$TMP/v.out" \
  && pass "verify rejects non-PASS prerequisite contract" \
  || fail "verify accepted bad prerequisite contract rc=${VRC}"

rm -f "$REL/extras/phase2-ubuntu-prerequisites.state"
set +e
(
  trap - EXIT
  verify_release_prereq_contract "$REL"
) >"$TMP/v2.out" 2>"$TMP/v2.err"
VRC2=$?
set -e
[[ "$VRC2" -ne 0 ]] && grep -q 'missing prerequisite contract' "$TMP/v2.out" \
  && pass "verify rejects missing prerequisite contract" \
  || fail "missing contract not rejected rc=${VRC2}"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
echo "ALL PASS"
exit 0
