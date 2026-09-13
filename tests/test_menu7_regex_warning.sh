#!/usr/bin/env bash
# Prove Menu 7 display-format Python emits zero FutureWarning nested-set warnings.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="${ROOT}/scripts/ubuntu-offline-mirror-entrypoint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

# Static: no POSIX [[:space:]] character classes inside the PY heredoc.
py_block="$(awk '/^  python3 - /,/^PY$/' "$ENTRY")"
if printf '%s\n' "$py_block" | grep -q '\[\[:space:\]\]'; then
  fail "POSIX [[:space:]] still present in Menu7 Python formatter"
else
  pass "no POSIX [[:space:]] in Menu7 Python formatter"
fi

MIRROR="http://192.0.2.10"
SHA="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
IN="$TMP/in.txt"
OUT="$TMP/out.txt"
WARN="$TMP/warn.txt"

{
  cat <<'EOF'
DP Client Upgrade Commands
==========================
DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2
DP_OS_HOP_COMMAND_VERSION=WRAPPER_V1
EOF
  for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
    cat <<EOF

STEP — ${hop}

Copy and paste the following entire line into the DP terminal:

cd /home/aella && curl -fsSLo upgrade-${hop}.sh.download ${MIRROR}/client/upgrade-${hop}.sh && printf '%s  %s\\n' '${SHA}' 'upgrade-${hop}.sh.download' | sha256sum -c - && mv -f upgrade-${hop}.sh.download upgrade-${hop}.sh && bash ./upgrade-${hop}.sh
EOF
  done
  cat <<EOF

STEP 6 — STAGE

Copy and paste the following entire line into the DP terminal:

cd /home/aella && curl -fsSLo upgrade-phase2.sh.download ${MIRROR}/client/upgrade-phase2.sh && printf '%s  %s\\n' '${SHA}' 'upgrade-phase2.sh.download' | sha256sum -c - && mv -f upgrade-phase2.sh.download upgrade-phase2.sh && bash ./upgrade-phase2.sh
EOF
} >"$IN"

# Run formatter with warnings treated as captured stderr noise.
set +e
PYTHONWARNINGS=default bash "$ENTRY" --format-menu7 "$IN" "$OUT" 2>"$WARN"
rc=$?
set -e

[[ "$rc" -eq 0 ]] && pass "format-menu7 exit 0" || fail "format-menu7 rc=$rc"
[[ -s "$OUT" ]] && pass "display output written" || fail "display output empty"

WARN_COUNT="$(grep -c 'FutureWarning: Possible nested set' "$WARN" || true)"
[[ "$WARN_COUNT" -eq 0 ]] && pass "MENU7_REGEX_WARNING_COUNT=0" \
  || fail "MENU7_REGEX_WARNING_COUNT=${WARN_COUNT}"

echo "MENU7_REGEX_WARNING_COUNT=${WARN_COUNT}"
if [[ "$FAIL" -ne 0 ]]; then
  echo "TEST_MENU7_REGEX_WARNING=FAIL"
  sed -n '1,40p' "$WARN" >&2 || true
  exit 1
fi
echo "TEST_MENU7_REGEX_WARNING=PASS"
exit 0
