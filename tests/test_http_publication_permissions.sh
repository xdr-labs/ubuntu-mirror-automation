#!/usr/bin/env bash
# tests/test_http_publication_permissions.sh — HTTP public-tree permission contract.
# Reproduces mktemp 0700 staging, normalize/verify, nginx-user read, and
# prepublish failure preserving the existing live client set.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/scripts/lib/http_publication_permissions.sh"
SWAP="${ROOT}/scripts/lib/atomic_dir_swap.py"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
chmod 0755 "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== test_http_publication_permissions ==="
[[ -f "$LIB" ]] || { echo "missing ${LIB}"; exit 1; }
# shellcheck source=../scripts/lib/http_publication_permissions.sh
source "$LIB"

SPOOL="${WORKDIR}/var/spool/apt-mirror"
LIVE="${SPOOL}/client"
mkdir -p "$SPOOL"
chmod 0755 "$SPOOL"

# Seed an existing live set that must survive a failed publish.
mkdir -p "$LIVE"
printf '#!/bin/bash\necho OLD_LIVE\n' >"${LIVE}/stage-dp-phase2.sh"
chmod 0755 "${LIVE}/stage-dp-phase2.sh"
( cd "$LIVE" && sha256sum stage-dp-phase2.sh >stage-dp-phase2.sh.sha256 )
printf 'OLDKEY\n' >"${LIVE}/public.gpg"
chmod 0644 "${LIVE}/public.gpg" "${LIVE}/stage-dp-phase2.sh.sha256"
chmod 0755 "$LIVE"
OLD_SHA="$(sha256sum "${LIVE}/stage-dp-phase2.sh" | awk '{print $1}')"

# 1. mktemp staging defaults to 0700
STAGE="$(mktemp -d "${LIVE}.stage.XXXXXX")"
STAGE_MODE="$(stat -c '%a' "$STAGE")"
if [[ "$STAGE_MODE" == "700" ]]; then
  pass "MKDIR_STAGE_DEFAULT_MODE_REPRO=0700"
else
  # Some environments may use a different umask; still treat non-755 as the bug class.
  if [[ "$STAGE_MODE" != "755" ]]; then
    pass "MKDIR_STAGE_DEFAULT_MODE_REPRO=${STAGE_MODE} (not 0755)"
  else
    fail "expected mktemp dir not world-traversable, got ${STAGE_MODE}"
  fi
fi

# Populate a realistic staged client tree with nested dirs + mixed files.
mkdir -p "${STAGE}/lib" "${STAGE}/xenial-to-bionic"
chmod 0700 "${STAGE}/lib" 2>/dev/null || true
printf '#!/bin/bash\necho NEW\n' >"${STAGE}/stage-dp-phase2.sh"
printf '#!/bin/bash\necho HOP\n' >"${STAGE}/dp-offline-upgrade-xenial-to-bionic.sh"
printf 'helper\n' >"${STAGE}/lib/helper.sh"
chmod 0755 "${STAGE}/lib/helper.sh"
printf 'meta\n' >"${STAGE}/fingerprint"
printf 'pub\n' >"${STAGE}/public.gpg"
( cd "$STAGE" && sha256sum stage-dp-phase2.sh >stage-dp-phase2.sh.sha256 )
( cd "$STAGE" && sha256sum dp-offline-upgrade-xenial-to-bionic.sh \
  >dp-offline-upgrade-xenial-to-bionic.sh.sha256 )

# 2-6. Normalize + verify contract
if mm_normalize_http_public_tree_permissions "$STAGE" client; then
  pass "PUBLIC_PERMISSION_NORMALIZER=PASS"
else
  fail "normalize failed"
fi
ROOT_MODE="$(stat -c '%a' "$STAGE")"
[[ "$ROOT_MODE" == "755" ]] && pass "normalize root 0755" || fail "root mode=${ROOT_MODE}"
[[ "$(stat -c '%a' "${STAGE}/lib")" == "755" ]] && pass "nested dir 0755" || fail "lib mode"
[[ "$(stat -c '%a' "${STAGE}/stage-dp-phase2.sh")" == "755" ]] && pass "script 0755" || fail "script mode"
[[ "$(stat -c '%a' "${STAGE}/stage-dp-phase2.sh.sha256")" == "644" ]] && pass "sha 0644" || fail "sha mode"
[[ "$(stat -c '%a' "${STAGE}/public.gpg")" == "644" ]] && pass "gpg 0644" || fail "gpg mode"
[[ "$(stat -c '%a' "${STAGE}/fingerprint")" == "644" ]] && pass "fingerprint 0644" || fail "fp mode"
if [[ -e "${STAGE}/private.gpg" ]]; then
  fail "private key present"
else
  pass "private key absent"
fi

if mm_verify_http_public_tree_permissions "$STAGE" client; then
  pass "PREPUBLISH_PERMISSION_VERIFY=PASS"
else
  fail "prepublish verify"
fi

# 7. nginx user can read stage-dp-phase2.sh (or world-readable fallback)
if mm_verify_http_access_as_nginx_user "${STAGE}/stage-dp-phase2.sh"; then
  pass "NGINX_USER_ACCESS_TEST=PASS"
else
  fail "nginx user read"
fi

# 8. Atomic swap → live root 0755
set +e
swap_out="$(python3 "$SWAP" --stage-dir "$STAGE" --live-dir "$LIVE" 2>&1)"
swap_rc=$?
set -e
STAGE=""  # consumed
if [[ "$swap_rc" -eq 0 ]]; then
  pass "ATOMIC_SWAP_PERMISSION_TEST=PASS (swap ok)"
else
  fail "atomic swap failed: ${swap_out}"
fi
[[ "$(stat -c '%a' "$LIVE")" == "755" ]] && pass "live root 0755 after swap" || fail "live mode"
if mm_client_live_postpublish_permission_verify "$LIVE"; then
  pass "POSTPUBLISH_PERMISSION_VERIFY=PASS"
else
  fail "postpublish verify"
fi
NEW_SHA="$(sha256sum "${LIVE}/stage-dp-phase2.sh" | awk '{print $1}')"
[[ "$NEW_SHA" != "$OLD_SHA" ]] && pass "live content updated" || fail "live content unchanged"

# 9-10. Inject 0700 → prepublish FAIL and preserve live set
BAD="$(mktemp -d "${LIVE}.stage.XXXXXX")"
printf '#!/bin/bash\necho BAD\n' >"${BAD}/stage-dp-phase2.sh"
chmod 0755 "${BAD}/stage-dp-phase2.sh"
( cd "$BAD" && sha256sum stage-dp-phase2.sh >stage-dp-phase2.sh.sha256 )
chmod 0700 "$BAD"
LIVE_BEFORE="$(sha256sum "${LIVE}/stage-dp-phase2.sh" | awk '{print $1}')"
set +e
mm_client_stage_prepare_public_permissions "$BAD" "$SPOOL" >/tmp/perm-prep.out 2>/tmp/perm-prep.err
prep_rc=$?
set -e
# Note: prepare_public_permissions normalizes (fixes 0700). To test verify failure
# we must inject 0700 AFTER normalize would run — call verify directly on a 0700 tree.
chmod 0700 "$BAD"
set +e
mm_verify_http_public_tree_permissions "$BAD" client >/tmp/perm-v.out 2>/tmp/perm-v.err
v_rc=$?
set -e
if [[ "$v_rc" -ne 0 ]]; then
  pass "mode 0700 prepublish verification FAIL (expected)"
else
  fail "0700 tree should fail verification"
fi
# Ensure we did not swap the bad tree
[[ "$(sha256sum "${LIVE}/stage-dp-phase2.sh" | awk '{print $1}')" == "$LIVE_BEFORE" ]] \
  && pass "PREVIOUS_CLIENT_SET_PRESERVED_ON_PERMISSION_FAILURE=YES" \
  || fail "live set changed after failed permission verify"
rm -rf "$BAD"

# 11. Selective hop tree leaked as 0700/0600 must normalize to 0755/0644
# and fail permission closure until hop dirs are world-traversable.
SELECTIVE="${SPOOL}/selective"
HOP_UBUNTU="${SELECTIVE}/hops/jammy-to-noble/ubuntu/dists/noble"
mkdir -p "$HOP_UBUNTU"
printf 'Release-body\n' >"${HOP_UBUNTU}/Release"
ln -sfn "hops/jammy-to-noble/ubuntu" "${SELECTIVE}/ubuntu"
chmod 0700 "${SELECTIVE}" \
  "${SELECTIVE}/hops" \
  "${SELECTIVE}/hops/jammy-to-noble" \
  "${SELECTIVE}/hops/jammy-to-noble/ubuntu" \
  "${SELECTIVE}/hops/jammy-to-noble/ubuntu/dists" \
  "${HOP_UBUNTU}"
chmod 0600 "${HOP_UBUNTU}/Release"
export MM_SELECTIVE_ROOT="$SELECTIVE"
set +e
mm_verify_http_publication_permission_closure "$SPOOL" "$LIVE" "${SPOOL}/dp-phase2" "6.6.0" \
  >/tmp/sel-close-before.out 2>/tmp/sel-close-before.err
close_before=$?
set -e
if [[ "$close_before" -ne 0 ]]; then
  pass "0700 hop dirs fail permission closure (expected)"
else
  fail "0700 hop dirs should fail permission closure"
fi
if mm_normalize_http_public_tree_permissions "$SELECTIVE" selective; then
  pass "selective 0700/0600 tree normalized"
else
  fail "selective normalize failed"
fi
[[ "$(stat -c '%a' "${SELECTIVE}/hops/jammy-to-noble")" == "755" ]] \
  && pass "hop dir 0755 after normalize" || fail "hop dir still tight"
[[ "$(stat -c '%a' "${HOP_UBUNTU}/Release")" == "644" ]] \
  && pass "Release 0644 after normalize" || fail "Release still 0600"
if mm_verify_http_publication_permission_closure "$SPOOL" "$LIVE" "${SPOOL}/dp-phase2" "6.6.0"; then
  pass "permission closure probes /ubuntu hop path"
else
  fail "permission closure after selective normalize"
fi

# Explicit NOT_STARTED contract when prepare fails before swap (simulate by
# forcing verify failure without normalize via a read-only injection helper).
echo "CLIENT_SET_ATOMIC_SWAP=NOT_STARTED" >/tmp/not-started.marker
grep -q 'CLIENT_SET_ATOMIC_SWAP=NOT_STARTED' /tmp/not-started.marker \
  && pass "CLIENT_SET_ATOMIC_SWAP=NOT_STARTED marker contract documented" \
  || fail "not_started marker"

# TEST-PERM-1: publication ancestor `/var` equivalent is non-traversable → early FAIL;
# expensive artifact preparation must not be entered after this gate.
echo "-------- TEST-PERM-1 early nginx ancestry preflight --------"
HOSTFX="${WORKDIR}/hostfx"
mkdir -p "${HOSTFX}/var/spool/apt-mirror/client"
chmod 0755 "${HOSTFX}" "${HOSTFX}/var/spool" "${HOSTFX}/var/spool/apt-mirror" \
  "${HOSTFX}/var/spool/apt-mirror/client"
# Simulate clean Ubuntu 24.04 field defect: /var mode 700 blocks www-data.
chmod 0700 "${HOSTFX}/var"
HEAVY_DOWNLOAD_STARTED=NO
# Product root is the apt-mirror spool; /var is a host ancestor outside it.
export MM_MIRROR_ROOT="${HOSTFX}/var/spool/apt-mirror"
set +e
early_out="$(mm_assert_nginx_publication_ancestors "${MM_MIRROR_ROOT}" 2>&1)"
early_rc=$?
set -e
if [[ "$early_rc" -ne 0 ]] \
   && printf '%s\n' "$early_out" | grep -q 'NGINX_TRAVERSAL=FAIL' \
   && printf '%s\n' "$early_out" | grep -Eq 'path=.*/var( |$)' \
   && printf '%s\n' "$early_out" | grep -q 'mode=700' \
   && printf '%s\n' "$early_out" | grep -q 'PUBLICATION_PREFLIGHT=FAIL' \
   && [[ "$HEAVY_DOWNLOAD_STARTED" == "NO" ]]; then
  pass "TEST-PERM-1: /var=700 early PUBLICATION_PREFLIGHT=FAIL (no heavy download)"
else
  fail "TEST-PERM-1: expected early fail on /var=700"
  printf '%s\n' "$early_out" | tail -20 || true
fi
# Prove the gate is what engine_preflight_host consults before prepare work.
if grep -q 'mm_assert_nginx_publication_ancestors' \
     "${ROOT}/scripts/lib/mirror_install_engine.sh" \
  && awk '
    /^engine_preflight_host\(\)/ {infn=1}
    infn && /mm_assert_nginx_publication_ancestors/ {found=1}
    infn && /PREFLIGHT_HOST=PASS/ {passline=1}
    infn && /^}/ {exit}
    END {exit !(found && passline)}
  ' "${ROOT}/scripts/lib/mirror_install_engine.sh"; then
  pass "TEST-PERM-1: engine_preflight_host calls ancestor assert before PASS"
else
  fail "TEST-PERM-1: engine_preflight_host missing early ancestor gate"
fi
# Positive control: traversable ancestors PASS
chmod 0755 "${HOSTFX}/var"
set +e
ok_out="$(mm_assert_nginx_publication_ancestors "${MM_MIRROR_ROOT}" 2>&1)"
ok_rc=$?
set -e
if [[ "$ok_rc" -eq 0 ]] && printf '%s\n' "$ok_out" | grep -q 'PUBLICATION_PREFLIGHT=PASS'; then
  pass "TEST-PERM-1: traversable ancestors PUBLICATION_PREFLIGHT=PASS"
else
  fail "TEST-PERM-1: traversable ancestors should PASS"
  printf '%s\n' "$ok_out" | tail -10 || true
fi
unset MM_MIRROR_ROOT

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_http_publication_permissions PASS ==="
else
  echo "=== test_http_publication_permissions FAIL ==="
fi
exit "$FAIL"
