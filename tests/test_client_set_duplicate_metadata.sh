#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/mirror_manager_common.sh"
PY="${ROOT}/scripts/lib/client_build_provenance.py"

assert_py_fail() {
  local label="$1" file="$2"
  set +e
  python3 - <<PY
import sys
sys.path.insert(0, "${ROOT}/scripts/lib")
from client_build_provenance import parse_env_file
try:
    parse_env_file("$file")
except Exception as e:
    print(e)
    sys.exit(2)
sys.exit(0)
PY
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || { echo "FAIL python accepted $label"; exit 1; }
  echo "PASS python reject $label"
}

assert_sh_fail() {
  local label="$1" file="$2"
  set +e
  mm_parse_env_metadata_get "$file" >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || { echo "FAIL shell accepted $label"; exit 1; }
  echo "PASS shell reject $label"
}

GOOD="$TMP/good.env"
cat >"$GOOD" <<'EOF'
CLIENT_SET_GENERATION_ID=gen-1
CLIENT_BUILD_INPUT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CLIENT_MIRROR_BASE_URL=http://192.0.2.10
CLIENT_SIGNING_FINGERPRINT=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
PREPARATION_MODE=FULL
EOF
mm_parse_env_metadata_get "$GOOD" >/dev/null
[[ "$(mm_parse_env_metadata_get "$GOOD" CLIENT_SET_GENERATION_ID)" == "gen-1" ]]
python3 -c "import sys; sys.path.insert(0,'${ROOT}/scripts/lib'); from client_build_provenance import parse_env_file; parse_env_file('$GOOD')"
echo "PASS single valid key set"

DUP_DIFF="$TMP/dup-diff.env"
cat >"$DUP_DIFF" <<'EOF'
CLIENT_SET_GENERATION_ID=A
CLIENT_SET_GENERATION_ID=B
CLIENT_BUILD_INPUT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
assert_py_fail dup_diff "$DUP_DIFF"
assert_sh_fail dup_diff "$DUP_DIFF"

DUP_SAME="$TMP/dup-same.env"
cat >"$DUP_SAME" <<'EOF'
CLIENT_SET_GENERATION_ID=A
CLIENT_SET_GENERATION_ID=A
EOF
assert_py_fail dup_same "$DUP_SAME"
assert_sh_fail dup_same "$DUP_SAME"

MAL="$TMP/mal.env"
printf 'not a kv line\n' >"$MAL"
assert_py_fail malformed "$MAL"
assert_sh_fail malformed "$MAL"

echo "PASS test_client_set_duplicate_metadata"
