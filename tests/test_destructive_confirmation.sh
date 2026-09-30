#!/usr/bin/env bash
# tests/test_destructive_confirmation.sh - destructive confirmation UX regression
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/client/lib/dp-offline-destructive-confirmation.sh"
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dp-confirm-test.XXXX")"
trap 'rm -rf "$OUT_DIR"' EXIT

PASS=0
FAIL=0

pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$msg"
  else
    fail "$msg (got='${got}' want='${want}')"
  fi
}

HOPS=(
  "xenial-to-bionic:UPGRADE-XENIAL-TO-BIONIC"
  "bionic-to-focal:UPGRADE-BIONIC-TO-FOCAL"
  "focal-to-jammy:UPGRADE-FOCAL-TO-JAMMY"
  "jammy-to-noble:UPGRADE-JAMMY-TO-NOBLE"
)

builder_for_hop() {
  case "$1" in
    xenial-to-bionic) printf '%s\n' "${ROOT}/scripts/lib/build_client_xenial_to_bionic.py" ;;
    bionic-to-focal) printf '%s\n' "${ROOT}/scripts/lib/build_client_bionic_to_focal.py" ;;
    focal-to-jammy) printf '%s\n' "${ROOT}/scripts/lib/build_client_focal_to_jammy.py" ;;
    jammy-to-noble) printf '%s\n' "${ROOT}/scripts/lib/build_client_jammy_to_noble.py" ;;
    *) return 1 ;;
  esac
}

template_for_hop() {
  printf '%s\n' "${ROOT}/client/dp-offline-upgrade-${1}.sh.in"
}

# ---------------------------------------------------------------------------
# Static wiring: helper token + call site + phrase pins for all hops
# ---------------------------------------------------------------------------
[[ -f "$HELPER" ]] && pass "shared confirmation helper present" || fail "helper missing"

if grep -nE '\$\{[a-zA-Z_][a-zA-Z0-9_]*@|declare -n |mapfile -d |readarray |coproc |&>' "$HELPER" \
  >/dev/null 2>&1; then
  fail "helper may use Bash>4.3-only syntax"
else
  pass "helper avoids Bash>4.3-only syntax (static)"
fi

bash -n "$HELPER" && pass "helper bash -n" || fail "helper bash -n"
python3 -m py_compile "${ROOT}/tests/lib/render_offline_upgrade_stub.py" \
  && pass "stub renderer py_compile" \
  || fail "stub renderer py_compile"

for entry in "${HOPS[@]}"; do
  hop="${entry%%:*}"
  phrase="${entry#*:}"
  tin="$(template_for_hop "$hop")"
  builder="$(builder_for_hop "$hop")"

  if [[ -f "$tin" ]] \
    && grep -q '@@DESTRUCTIVE_CONFIRMATION_HELPER@@' "$tin" \
    && grep -q 'require_destructive_confirmation "\$PIN_CONFIRM_PHRASE"' "$tin" \
    && grep -q "PIN_CONFIRM_PHRASE='@@CONFIRM_PHRASE@@'" "$tin" \
    && ! grep -qE 'IFS= read -r answer' "$tin"; then
    pass "wiring ${hop}: helper token + require_* call"
  else
    fail "wiring ${hop}: template confirmation path"
  fi

  if grep -q "CONFIRM_PHRASE = \"${phrase}\"" "$builder" \
    && grep -q 'DESTRUCTIVE_CONFIRMATION_HELPER' "$builder"; then
    pass "builder ${hop}: phrase + helper inject"
  else
    fail "builder ${hop}: phrase/helper inject"
  fi

  # Hermetic fake confirmation must be non-interactive. An explicitly supplied
  # wrong value is rejected deterministically instead of falling through to read(1).
  if grep -Fq '[[ -n "$TEST_ROOT" && -n "${DP_OFFLINE_FAKE_CONFIRM+x}" ]]' "$tin" \
    && grep -Fq '[[ "${DP_OFFLINE_FAKE_CONFIRM}" == "$PIN_CONFIRM_PHRASE" ]] && return 0' "$tin" \
    && grep -A3 -F '[[ -n "$TEST_ROOT" && -n "${DP_OFFLINE_FAKE_CONFIRM+x}" ]]' "$tin" | grep -Fq 'return 1'; then
    pass "template ${hop}: hermetic fake confirmation rejects mismatch without read"
  else
    fail "template ${hop}: hermetic fake confirmation may fall through to interactive read"
  fi
done

# ---------------------------------------------------------------------------
# Behavioral harness under set -Eeuo pipefail
# ---------------------------------------------------------------------------
run_confirm_case() {
  local expected="$1"
  local stdin_data="$2"
  local out_rc_file="$3"
  local out_log_file="$4"
  local mode="${5:-plain}" # plain | with_next

  local harness="${OUT_DIR}/harness.sh"
  cat >"$harness" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$1"
EXPECTED="$2"
MODE="$3"
# shellcheck source=/dev/null
source "${ROOT_DIR}/client/lib/dp-offline-destructive-confirmation.sh"

LOG_BUF=""
log() {
  local level="$1"; shift
  LOG_BUF+="[${level}] $*"$'\n'
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >&2
}

DESTRUCTIVE_CALLS=0
do_destructive_mutation() {
  DESTRUCTIVE_CALLS=$((DESTRUCTIVE_CALLS + 1))
}

NEXT_STEP_CALLS=0
do_next_step() {
  NEXT_STEP_CALLS=$((NEXT_STEP_CALLS + 1))
}

set +e
require_destructive_confirmation "$EXPECTED"
rc=$?
set -e

if [[ "$rc" -eq 0 && "$MODE" == "with_next" ]]; then
  do_next_step
fi

# Separate interactive prompt stdout from machine-readable fields.
printf '\n'
printf 'RC=%s\n' "$rc"
printf 'DESTRUCTIVE_CALLS=%s\n' "$DESTRUCTIVE_CALLS"
printf 'NEXT_STEP_CALLS=%s\n' "$NEXT_STEP_CALLS"
printf 'LOG<<EOF\n'
printf '%s' "$LOG_BUF"
printf 'EOF\n'
exit "$rc"
EOS

  set +e
  printf '%b' "$stdin_data" | bash "$harness" "$ROOT" "$expected" "$mode" \
    >"$out_rc_file" 2>"$out_log_file"
  local rc=$?
  set -e
  echo "$rc" >"${out_rc_file}.exit"
}

extract_field() {
  local file="$1" key="$2"
  grep -E "^${key}=" "$file" | head -n1 | cut -d= -f2-
}

# Run behavioral matrix once per hop phrase
for entry in "${HOPS[@]}"; do
  hop="${entry%%:*}"
  phrase="${entry#*:}"
  case_dir="${OUT_DIR}/${hop}"
  mkdir -p "$case_dir"

  # 1) exact first try
  run_confirm_case "$phrase" "${phrase}\n" "$case_dir/1.out" "$case_dir/1.err"
  assert_eq "$(cat "$case_dir/1.out.exit")" "0" "${hop}: exact accept rc=0"
  assert_eq "$(extract_field "$case_dir/1.out" RC)" "0" "${hop}: exact RC field"
  if grep -q 'Leading/trailing whitespace was ignored' "$case_dir/1.err"; then
    fail "${hop}: exact must not emit normalization log"
  else
    pass "${hop}: exact no normalization log"
  fi

  # 2) leading spaces
  run_confirm_case "$phrase" "  ${phrase}\n" "$case_dir/2.out" "$case_dir/2.err"
  assert_eq "$(cat "$case_dir/2.out.exit")" "0" "${hop}: leading space accept"
  if grep -q 'Leading/trailing whitespace was ignored' "$case_dir/2.err" \
    && grep -q 'Confirmation accepted' "$case_dir/2.err"; then
    pass "${hop}: leading space normalization log"
  else
    fail "${hop}: leading space normalization log missing"
  fi

  # 3) trailing spaces
  run_confirm_case "$phrase" "${phrase}  \n" "$case_dir/3.out" "$case_dir/3.err"
  assert_eq "$(cat "$case_dir/3.out.exit")" "0" "${hop}: trailing space accept"

  # 4) leading+trailing tabs
  run_confirm_case "$phrase" "\t${phrase}\t\n" "$case_dir/4.out" "$case_dir/4.err"
  assert_eq "$(cat "$case_dir/4.out.exit")" "0" "${hop}: tab trim accept"

  # 5) empty then exact
  run_confirm_case "$phrase" "\n${phrase}\n" "$case_dir/5.out" "$case_dir/5.err"
  assert_eq "$(cat "$case_dir/5.out.exit")" "0" "${hop}: empty then exact"
  if grep -q 'Empty confirmation' "$case_dir/5.err" \
    && grep -q 'Try again (1/3)' "$case_dir/5.err"; then
    pass "${hop}: empty retry warning"
  else
    fail "${hop}: empty retry warning"
  fi

  # 6) typo then exact
  run_confirm_case "$phrase" "wrong-value\n${phrase}\n" "$case_dir/6.out" "$case_dir/6.err"
  assert_eq "$(cat "$case_dir/6.out.exit")" "0" "${hop}: typo then exact"
  if grep -q 'Confirmation mismatch' "$case_dir/6.err" \
    && grep -q 'Try again (1/3)' "$case_dir/6.err"; then
    pass "${hop}: typo retry warning"
  else
    fail "${hop}: typo retry warning"
  fi

  # 7) two typos then exact
  run_confirm_case "$phrase" "a\nb\n${phrase}\n" "$case_dir/7.out" "$case_dir/7.err"
  assert_eq "$(cat "$case_dir/7.out.exit")" "0" "${hop}: two typos then exact"
  if grep -q 'Try again (2/3)' "$case_dir/7.err"; then
    pass "${hop}: second retry counter"
  else
    fail "${hop}: second retry counter"
  fi

  # 8) three typos
  run_confirm_case "$phrase" "a\nb\nc\n" "$case_dir/8.out" "$case_dir/8.err"
  assert_eq "$(cat "$case_dir/8.out.exit")" "21" "${hop}: three typos rc=21"

  # 9) three empties
  run_confirm_case "$phrase" "\n\n\n" "$case_dir/9.out" "$case_dir/9.err"
  assert_eq "$(cat "$case_dir/9.out.exit")" "21" "${hop}: three empties rc=21"

  # 10) interior whitespace
  spaced="${phrase//-/ }"
  run_confirm_case "$phrase" "${spaced}\n${spaced}\n${spaced}\n" \
    "$case_dir/10.out" "$case_dir/10.err"
  assert_eq "$(cat "$case_dir/10.out.exit")" "21" "${hop}: interior spaces rejected"

  # 11) lowercase
  lower="$(printf '%s' "$phrase" | tr '[:upper:]' '[:lower:]')"
  run_confirm_case "$phrase" "${lower}\n${lower}\n${lower}\n" \
    "$case_dir/11.out" "$case_dir/11.err"
  assert_eq "$(cat "$case_dir/11.out.exit")" "21" "${hop}: lowercase rejected"

  # 12) suffix extra
  run_confirm_case "$phrase" "${phrase}-EXTRA\n${phrase}-EXTRA\n${phrase}-EXTRA\n" \
    "$case_dir/12.out" "$case_dir/12.err"
  assert_eq "$(cat "$case_dir/12.out.exit")" "21" "${hop}: suffix extra rejected"

  # 13) EOF immediately
  run_confirm_case "$phrase" "" "$case_dir/13.out" "$case_dir/13.err"
  assert_eq "$(cat "$case_dir/13.out.exit")" "21" "${hop}: EOF rc=21"
  conf_prompts="$(grep -c 'Confirmation>' "$case_dir/13.out" || true)"
  if [[ "${conf_prompts:-0}" -le 1 ]]; then
    pass "${hop}: EOF no retry loop"
  else
    fail "${hop}: EOF looped (prompts=${conf_prompts})"
  fi

  # 14) raw input must not appear in logs (sensitive marker)
  marker="SECRET_CONFIRM_MARKER_9f3a_${hop}"
  run_confirm_case "$phrase" "${marker}\n${marker}\n${marker}\n" \
    "$case_dir/14.out" "$case_dir/14.err"
  if grep -Fq "$marker" "$case_dir/14.err" || grep -Fq "$marker" "$case_dir/14.out"; then
    fail "${hop}: sensitive marker leaked into logs"
  else
    pass "${hop}: sensitive marker not logged"
  fi

  # 15) reject path never calls destructive
  assert_eq "$(extract_field "$case_dir/8.out" DESTRUCTIVE_CALLS)" "0" \
    "${hop}: no destructive on reject"

  # 16) accept then next step once
  run_confirm_case "$phrase" "${phrase}\n" "$case_dir/16.out" "$case_dir/16.err" "with_next"
  assert_eq "$(cat "$case_dir/16.out.exit")" "0" "${hop}: accept+next rc=0"
  assert_eq "$(extract_field "$case_dir/16.out" NEXT_STEP_CALLS)" "1" \
    "${hop}: next step called once after accept"
  assert_eq "$(extract_field "$case_dir/16.out" DESTRUCTIVE_CALLS)" "0" \
    "${hop}: harness destructive not auto-called"

  # whitespace-only counts as empty
  run_confirm_case "$phrase" "   \n${phrase}\n" "$case_dir/ws.out" "$case_dir/ws.err"
  assert_eq "$(cat "$case_dir/ws.out.exit")" "0" "${hop}: whitespace-only as empty then accept"
  if grep -q 'Empty confirmation' "$case_dir/ws.err"; then
    pass "${hop}: whitespace-only treated as empty"
  else
    fail "${hop}: whitespace-only not treated as empty"
  fi

  # CR trim
  run_confirm_case "$phrase" "${phrase}\r\n" "$case_dir/cr.out" "$case_dir/cr.err"
  assert_eq "$(cat "$case_dir/cr.out.exit")" "0" "${hop}: CR trimmed accept"
done

# ---------------------------------------------------------------------------
# trim unit checks
# ---------------------------------------------------------------------------
trim_harness="${OUT_DIR}/trim.sh"
cat >"$trim_harness" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$1"
printf '%s' "$(trim_outer_whitespace "$2")"
EOS

got="$(bash "$trim_harness" "$HELPER" "  ABC  ")"
assert_eq "$got" "ABC" "trim outer spaces"

got="$(bash "$trim_harness" "$HELPER" $'\tABC\t')"
assert_eq "$got" "ABC" "trim outer tabs"

got="$(bash "$trim_harness" "$HELPER" "A B C")"
assert_eq "$got" "A B C" "trim preserves interior spaces"

got="$(bash "$trim_harness" "$HELPER" "   ")"
assert_eq "$got" "" "trim all-whitespace -> empty"

# ---------------------------------------------------------------------------
# Prompt wrapper still dies with confirmation rejected (exit 21)
# ---------------------------------------------------------------------------
wrap="${OUT_DIR}/wrap.sh"
cat >"$wrap" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
EC_CONFIRM=21
log() { printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" >&2; }
die() { local code="$1"; shift; log ERROR "$* (exit=${code})"; exit "$code"; }
# shellcheck source=/dev/null
source "$1"
require_destructive_confirmation "$2" || die "$EC_CONFIRM" "confirmation rejected"
EOS
set +e
printf 'nope\nnope\nnope\n' | bash "$wrap" "$HELPER" "UPGRADE-BIONIC-TO-FOCAL" \
  >"$OUT_DIR/wrap.out" 2>"$OUT_DIR/wrap.err"
rc=$?
set -e
assert_eq "$rc" "21" "wrapper die exit 21"
if grep -q 'confirmation rejected' "$OUT_DIR/wrap.err"; then
  pass "wrapper keeps confirmation rejected message"
else
  fail "wrapper missing confirmation rejected message"
fi

echo
echo "SUMMARY pass=${PASS} fail=${FAIL}"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
exit 0
