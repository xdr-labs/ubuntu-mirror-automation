#!/usr/bin/env bash
# Remaining Phase 2 remote-orchestration hardening contracts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHER="${ROOT}/scripts/lib/patch_dp_phase2_bringup.py"
COMPAT="${ROOT}/scripts/lib/phase2_bringup_patch/fragment_compat.sh"
WRAPPER="${ROOT}/client/bringup_py3_dp_lifecycle.sh"
PREV="${ROOT}/tests/fixtures/dp-phase2/upstream_bringup_unpatched.sh"
F1="${ROOT}/tests/fixtures/dp-phase2/production-f1a73/bringup_py3_dp_after_os_upgrade.sh"
F1_SHA="f57ea3964582322e0dc401fa8dd731c7443622fd"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
export PHASE2_BRINGUP_DIR="${TMP}/lifecycle"
mkdir -p "$PHASE2_BRINGUP_DIR"
trap 'rm -rf "$TMP"' EXIT
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "======== test_phase2_remote_hardening ========"

PREV_GEN="${TMP}/prev.sh"
F1_GEN="${TMP}/f1.sh"
if python3 "$PATCHER" --upstream "$PREV" --output "$PREV_GEN" >"${TMP}/prev.log" \
  && grep -q '^BRINGUP_PATCH_COMPAT=PASS$' "${TMP}/prev.log" \
  && bash -n "$PREV_GEN"; then
  pass "previous upstream patches + bash -n"
else
  fail "previous upstream patch"
  cat "${TMP}/prev.log" 2>/dev/null || true
fi
if [[ "$(sha1sum "$F1" | awk '{print $1}')" == "$F1_SHA" ]] \
  && python3 "$PATCHER" --upstream "$F1" --output "$F1_GEN" >"${TMP}/f1.log" \
  && grep -q '^BRINGUP_PATCH_COMPAT=PASS$' "${TMP}/f1.log" \
  && bash -n "$F1_GEN"; then
  pass "f1a73 upstream patches + bash -n"
else
  fail "f1a73 upstream patch"
  cat "${TMP}/f1.log" 2>/dev/null || true
fi

for marker in validate_remote_role_identity REMOTE_ROLE_IDENTITY validate_local_remote_join_state REMOTE_JOIN_LOCAL_STATE; do
  grep -Fq "$marker" "$PREV_GEN" && grep -Fq "$marker" "$F1_GEN" \
    && pass "generated marker $marker" || fail "generated marker $marker"
done

# The invocation (not the helper definition) must precede the first remote mutation.
for gen in "$PREV_GEN" "$F1_GEN"; do
  gate="$(grep -n 'if ! validate_remote_role_identity "\$worker_ip"' "$gen" | head -1 | cut -d: -f1 || true)"
  mutate="$(grep -n 'sudo mkdir -p \$STAGING_DIR \$AELLADEB_DIR' "$gen" | head -1 | cut -d: -f1 || true)"
  if [[ -n "$gate" && -n "$mutate" && "$gate" -lt "$mutate" ]]; then
    pass "role identity precedes mutation: $(basename "$gen")"
  else
    fail "role identity ordering: $(basename "$gen") gate=${gate:-none} mutate=${mutate:-none}"
  fi
done

if grep -Fq 'validate_local_remote_join_state || die "REMOTE_JOIN_LOCAL_STATE=FAIL"' "$F1_GEN" \
  && grep -Fq 'if [[ "$ROLE" == *worker* || "$ROLE" == "standby" ]]; then' "$F1_GEN" \
  && [[ "$(grep -Fc 'if [[ "$ROLE" == "AIO" || "$ROLE" == *master* ]]; then' "$F1_GEN")" -ge 2 ]]; then
  pass "standalone standby completion semantics"
else
  fail "standalone standby completion semantics"
fi

# Extract generated parse_args for argument-contract tests.
awk '
  /^parse_args\(\)/ {keep=1}
  keep {print}
  keep && /^}$/ {exit}
' "$F1_GEN" >"${TMP}/parse.sh"

run_parse() {
  local err="${TMP}/parse.err"
  : >"$err"
  set +e
  (
    VERSION="" WORKER_IPS="" WORKER_PASSWORD="" STANDBY_IPS="" ROLE=""
    DRY_RUN=false SKIP_DOWNLOAD=false WORKER_MODE=false PRE_UPGRADE_CLEANUP=false
    AUTO_OS_UPGRADE=false RECLAIM_OVERLAY2_ONLY=false RELABEL_ELASTIC_ONLY=false
    WORKER_SSH_KEY=""
    die() { echo "FATAL: $*" >&2; exit 1; }
    log() { echo "$*" >&2; }
    check_version_guard() { return 0; }
    source "$COMPAT"
    source "${TMP}/parse.sh"
    parse_args "$@"
    [[ "${EXPECT_DASH:-0}" != 1 || "$WORKER_PASSWORD" == "--dashpass" ]]
  ) 2>"$err"
  PARSE_RC=$?
  PARSE_ERR="$(cat "$err")"
  set -e
}

run_parse --version 6.6.0 --worker-ips '192.0.2.10,' --worker-password secret
[[ "$PARSE_RC" -ne 0 ]] && grep -q 'reason=empty_ip' <<<"$PARSE_ERR" \
  && pass "trailing empty IP fails closed" || fail "trailing empty IP rc=$PARSE_RC err=$PARSE_ERR"

run_parse --version 6.6.0 --worker-ips 192.0.2.10 --worker-password --skip-download
[[ "$PARSE_RC" -ne 0 ]] && grep -q -- '--worker-password requires a value' <<<"$PARSE_ERR" \
  && pass "vendor password cannot swallow option" || fail "vendor password swallow rc=$PARSE_RC err=$PARSE_ERR"

run_parse --version 6.6.0 --standby --skip-download --worker-password secret
[[ "$PARSE_RC" -ne 0 ]] && grep -q -- '--standby requires a value' <<<"$PARSE_ERR" \
  && pass "vendor standby cannot swallow option" || fail "vendor standby swallow rc=$PARSE_RC err=$PARSE_ERR"

EXPECT_DASH=1
run_parse --version 6.6.0 --worker-ips 192.0.2.10 --worker-password=--dashpass
unset EXPECT_DASH
[[ "$PARSE_RC" -eq 0 ]] && pass "vendor equals-form option-looking password" \
  || fail "vendor equals-form password rc=$PARSE_RC err=$PARSE_ERR"

# Direct helper behavior: role mismatch, master mismatch, alias, and self IP.
# Keep the helper call as the last command in a redirected group so its rc is
# the command-substitution rc; a trailing redirection command must not mask it.
run_role() {
  local expected="$1" actual="$2" self="${3:-NO}" marker="${TMP}/ssh-called"
  rm -f "$marker"
  set +e
  ROLE_OUT="$(
    {
      log() { echo "$*"; }
      source "$COMPAT"
      phase2_is_local_ipv4_address() { [[ "$self" == YES ]]; }
      worker_ssh() { touch "$marker"; echo "$actual"; }
      validate_remote_role_identity 192.0.2.10 "$expected"
    } 2>&1
  )"
  ROLE_RC=$?
  set -e
}
run_role DL-worker DR-worker
[[ "$ROLE_RC" -ne 0 ]] && grep -q 'reason=role_mismatch actual=DR-worker expected=DL-worker' <<<"$ROLE_OUT" \
  && pass "DL-worker rejects DR-worker" || fail "DL/DR mismatch rc=$ROLE_RC out=$ROLE_OUT"
run_role DL-worker DL-master
[[ "$ROLE_RC" -ne 0 ]] && grep -q 'reason=role_mismatch actual=DL-master expected=DL-worker' <<<"$ROLE_OUT" \
  && pass "worker rejects master role" || fail "worker/master mismatch rc=$ROLE_RC out=$ROLE_OUT"
run_role DR-worker DA-worker
[[ "$ROLE_RC" -eq 0 ]] && grep -q 'REMOTE_ROLE_IDENTITY .*result=PASS' <<<"$ROLE_OUT" \
  && pass "DA-worker canonical alias accepted" || fail "DA alias rc=$ROLE_RC out=$ROLE_OUT"
run_role DL-worker DL-worker YES
[[ "$ROLE_RC" -ne 0 ]] && grep -q 'reason=self_ip' <<<"$ROLE_OUT" && [[ ! -e "${TMP}/ssh-called" ]] \
  && pass "self IP rejected before SSH" || fail "self IP rc=$ROLE_RC out=$ROLE_OUT"

# Local worker/standby completion helper with stub systemctl/ip.
BIN="${TMP}/bin"; mkdir -p "$BIN"
cat >"${BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == is-active && "${SYS_ACTIVE:-NO}" == YES ]]
EOF
cat >"${BIN}/ip" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == link && "$2" == show && "${FLANNEL_PRESENT:-NO}" == YES ]]
EOF
chmod +x "${BIN}/systemctl" "${BIN}/ip"
CONF="${TMP}/kubelet.conf"
run_join() {
  local active="$1" conf="$2" flannel="$3"
  rm -f "$CONF"; [[ "$conf" == YES ]] && printf 'apiVersion: v1\n' >"$CONF"
  set +e
  JOIN_OUT="$(
    {
      PATH="${BIN}:$PATH"; SYS_ACTIVE="$active"; FLANNEL_PRESENT="$flannel"
      export PATH SYS_ACTIVE FLANNEL_PRESENT
      ROLE=standby; log() { echo "$*"; }; source "$COMPAT"
      PHASE2_KUBELET_CONF_PATH="$CONF"; PHASE2_FLANNEL_INTERFACE=flannel.1
      validate_local_remote_join_state
    } 2>&1
  )"
  JOIN_RC=$?
  set -e
}
run_join NO YES YES
[[ "$JOIN_RC" -ne 0 ]] && grep -q 'reason=kubelet_inactive' <<<"$JOIN_OUT" \
  && pass "standby rejects inactive kubelet" || fail "kubelet gate rc=$JOIN_RC out=$JOIN_OUT"
run_join YES NO YES
[[ "$JOIN_RC" -ne 0 ]] && grep -q 'reason=kubelet_conf_missing' <<<"$JOIN_OUT" \
  && pass "standby rejects missing kubelet.conf" || fail "conf gate rc=$JOIN_RC out=$JOIN_OUT"
run_join YES YES NO
[[ "$JOIN_RC" -ne 0 ]] && grep -q 'reason=flannel_missing' <<<"$JOIN_OUT" \
  && pass "standby rejects missing flannel" || fail "flannel gate rc=$JOIN_RC out=$JOIN_OUT"
run_join YES YES YES
[[ "$JOIN_RC" -eq 0 ]] && grep -q 'REMOTE_JOIN_LOCAL_STATE=PASS role=standby' <<<"$JOIN_OUT" \
  && pass "standby complete local join passes" || fail "join PASS rc=$JOIN_RC out=$JOIN_OUT"

# Lifecycle wrapper: positional password cannot consume --detach; equals form can
# represent a password that itself begins with -- and must preserve --detach.
set +e
WRAP_BAD="$(
  (
    DP_PHASE2_BRINGUP_LIB_ONLY=1
    source "$WRAPPER"
    parse_args --version 6.6.0 --worker-password --detach
  ) 2>&1
)"
WRAP_BAD_RC=$?
set -e
[[ "$WRAP_BAD_RC" -ne 0 ]] && grep -q -- '--worker-password requires a value' <<<"$WRAP_BAD" \
  && pass "lifecycle password cannot swallow --detach" || fail "lifecycle password swallow rc=$WRAP_BAD_RC out=$WRAP_BAD"

set +e
WRAP_EQ_RC=0
(
  DP_PHASE2_BRINGUP_LIB_ONLY=1
  source "$WRAPPER"
  parse_args --version 6.6.0 --worker-password=--dashpass --detach
  [[ "$ATTACH_MONITOR" -eq 0 ]]
  [[ "${PASSTHRU[2]}" == --worker-password-file ]]
  [[ -f "${PASSTHRU[3]}" ]]
  [[ "$(<"${PASSTHRU[3]}")" == --dashpass ]]
) || WRAP_EQ_RC=$?
set -e
[[ "$WRAP_EQ_RC" -eq 0 ]] && pass "lifecycle equals-form password preserves detach via password file" \
  || fail "lifecycle equals-form rc=$WRAP_EQ_RC"

bash -n "$COMPAT" && bash -n "$WRAPPER" && bash -n "$0" \
  && pass "shell syntax" || fail "shell syntax"
python3 -m py_compile "$PATCHER" && pass "patcher py_compile" || fail "patcher py_compile"

echo "SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]