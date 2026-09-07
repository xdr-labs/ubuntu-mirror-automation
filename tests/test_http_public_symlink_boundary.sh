#!/usr/bin/env bash
# Public HTTP trees fail closed on unexpected symlinks/specials/hardlinks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
HTTP="${ROOT}/scripts/lib/http_publication_permissions.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=/dev/null
source "$COMMON"
# shellcheck source=/dev/null
source "$HTTP"

CLIENT="${TMP}/client"
PHASE2="${TMP}/dp-phase2/6.6.0"
SELECTIVE="${TMP}/selective"
mkdir -p "$CLIENT" "$PHASE2" "${SELECTIVE}/hops/jammy-to-noble/ubuntu"
chmod 0755 "$CLIENT" "$PHASE2" "$SELECTIVE" "${SELECTIVE}/hops" \
  "${SELECTIVE}/hops/jammy-to-noble" "${SELECTIVE}/hops/jammy-to-noble/ubuntu"

printf '#!/bin/bash\necho ok\n' >"${CLIENT}/stage-dp-phase2.sh"
chmod 0755 "${CLIENT}/stage-dp-phase2.sh"
printf 'TARGET_DP_VERSION=6.6.0\n' >"${PHASE2}/release.env"
chmod 0644 "${PHASE2}/release.env"

# Positive: clean trees
mm_verify_http_public_tree_permissions "$CLIENT" client >"${TMP}/c.ok" 2>&1 \
  || fail "clean client should pass"
grep -q 'HTTP_PUBLIC_UNEXPECTED_SYMLINK_COUNT=0' "${TMP}/c.ok" \
  || fail "client missing symlink count=0"
mm_verify_http_public_tree_permissions "$PHASE2" phase2 >"${TMP}/p.ok" 2>&1 \
  || fail "clean phase2 should pass"
pass "positive: clean client/phase2 accepted"

# Documented selective ubuntu alias allowed
ln -sfn hops/jammy-to-noble/ubuntu "${SELECTIVE}/ubuntu"
mm_normalize_http_public_tree_permissions "$SELECTIVE" selective \
  || fail "selective ubuntu alias should be allowed"
pass "positive: selective ubuntu alias allowed"

# Negative: unexpected symlink in client
ln -sfn /etc/passwd "${CLIENT}/evil-link"
set +e
mm_verify_http_public_tree_permissions "$CLIENT" client >"${TMP}/c.bad" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "client symlink must fail"
grep -q 'unexpected_symlink' "${TMP}/c.bad" || fail "missing unexpected_symlink marker"
rm -f "${CLIENT}/evil-link"
pass "negative: client unexpected symlink rejected"

# Negative: unexpected symlink in phase2
ln -sfn ../.install-cache "${PHASE2}/leak"
set +e
mm_verify_http_public_tree_permissions "$PHASE2" phase2 >"${TMP}/p.bad" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "phase2 symlink must fail"
rm -f "${PHASE2}/leak"
pass "negative: phase2 unexpected symlink rejected"

# Negative: FIFO
mkfifo "${CLIENT}/pipe.fifo"
set +e
mm_verify_http_public_tree_permissions "$CLIENT" client >"${TMP}/fifo.bad" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "FIFO must fail"
rm -f "${CLIENT}/pipe.fifo"
pass "negative: FIFO rejected"

# Negative: hardlink
printf 'x\n' >"${CLIENT}/a.bin"
ln "${CLIENT}/a.bin" "${CLIENT}/b.bin"
set +e
mm_verify_http_public_tree_permissions "$CLIENT" client >"${TMP}/hl.bad" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "hardlink must fail"
grep -q 'unexpected_hardlink' "${TMP}/hl.bad" || fail "missing hardlink marker"
rm -f "${CLIENT}/a.bin" "${CLIENT}/b.bin"
pass "negative: hardlink rejected"

echo "ALL HTTP PUBLIC SYMLINK BOUNDARY TESTS PASSED"
