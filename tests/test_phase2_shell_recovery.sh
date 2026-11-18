#!/usr/bin/env bash
# Hermetic per-node aella shell recovery: no host account mutations.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export AELLA_SHELL_RECOVERY_DIR="$TMP/recovery"
export MOCK_AELLA_PASSWD_FILE="$TMP/passwd"
export MOCK_USERMOD_LOG="$TMP/usermod.log"
export PATH="$TMP/bin:$PATH"
touch "$MOCK_USERMOD_LOG"
cat >"$TMP/bin/getent" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == 'passwd aella' ]] || exit 1
cat "$MOCK_AELLA_PASSWD_FILE"
MOCK
cat >"$TMP/bin/id" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  -u) [[ "${MOCK_NONROOT:-NO}" == YES ]] && echo 1000 || echo 0 ;;
  '-u aella') echo 1000 ;;
  '-g aella') echo 27 ;;
  '-gn aella') echo sudo ;;
  *) exec /usr/bin/id "$@" ;;
esac
MOCK
cat >"$TMP/bin/pgrep" <<'MOCK'
#!/usr/bin/env bash
[[ "${MOCK_UPGRADE_ACTIVE:-NO}" == YES ]] || exit 1
echo '123 bash bringup_py3_dp_after_os_upgrade.sh'
MOCK
cat >"$TMP/bin/usermod" <<'MOCK'
#!/usr/bin/env bash
[[ "$#" -eq 3 && "$1" == -s && "$3" == aella ]] || exit 1
[[ "${MOCK_USERMOD_FAIL:-NO}" != YES ]] || exit 1
printf '%s\n' "$*" >>"$MOCK_USERMOD_LOG"
awk -F: -v shell="$2" 'BEGIN {OFS=":"} {$7=shell;print}' \
  "$MOCK_AELLA_PASSWD_FILE" >"$MOCK_AELLA_PASSWD_FILE.new"
mv -f "$MOCK_AELLA_PASSWD_FILE.new" "$MOCK_AELLA_PASSWD_FILE"
MOCK
chmod +x "$TMP/bin/"*
printf 'aella:x:1000:27::/home/aella:/usr/bin/bash\n' >"$MOCK_AELLA_PASSWD_FILE"
DP_PHASE2_STAGE_LIB_ONLY=1 bash -c '
  source "$1"; resolve_aella_ownership
  install_phase2_aella_shell_recovery
  normalize_phase2_aella_login_shell
' _ "$ROOT/client/stage-dp-phase2.sh" >"$TMP/stage.log" 2>&1
script="$AELLA_SHELL_RECOVERY_DIR/restore-aella-shell.sh"
receipt="$AELLA_SHELL_RECOVERY_DIR/original-shell.record"
[[ -f "$script" && -f "$receipt" ]]
[[ "$(stat -c %a "$AELLA_SHELL_RECOVERY_DIR")" == 700 ]]
[[ "$(stat -c %a "$script")" == 700 ]]
[[ "$(stat -c %a "$receipt")" == 600 ]]
grep -qx 'SHELL=/usr/bin/bash' "$receipt"
grep -qx 'aella:x:1000:27::/home/aella:/bin/bash' "$MOCK_AELLA_PASSWD_FILE"
bash -n "$script"
bash "$script" --check >"$TMP/check.log"
grep -qx 'AELLA_SHELL_SAVED=/usr/bin/bash' "$TMP/check.log"
bash "$script" --apply >"$TMP/restored.log"
grep -qx 'AELLA_SHELL_RESTORE=PASS shell=/usr/bin/bash' "$TMP/restored.log"
grep -qx 'aella:x:1000:27::/home/aella:/usr/bin/bash' "$MOCK_AELLA_PASSWD_FILE"
count="$(wc -l <"$MOCK_USERMOD_LOG")"
bash "$script" --apply >"$TMP/idempotent.log"
grep -q 'AELLA_SHELL_RESTORE=ALREADY_RESTORED' "$TMP/idempotent.log"
[[ "$(wc -l <"$MOCK_USERMOD_LOG")" == "$count" ]]

# A rerun after restoration preserves the original receipt.
DP_PHASE2_STAGE_LIB_ONLY=1 bash -c '
 source "$1"; resolve_aella_ownership; install_phase2_aella_shell_recovery
' _ "$ROOT/client/stage-dp-phase2.sh" >"$TMP/restage.log" 2>&1
grep -q 'source=preserved_receipt' "$TMP/restage.log"

printf 'aella:x:1000:27::/home/aella:/bin/bash\n' >"$MOCK_AELLA_PASSWD_FILE"
if MOCK_UPGRADE_ACTIVE=YES bash "$script" --apply >"$TMP/active.log" 2>&1; then
 echo 'FAIL: upgrade-active restore allowed' >&2; exit 1
fi
grep -q 'reason=upgrade_process_active' "$TMP/active.log"
if MOCK_NONROOT=YES bash "$script" --apply >"$TMP/nonroot.log" 2>&1; then
 echo 'FAIL: nonroot restore allowed' >&2; exit 1
fi
grep -q 'reason=root_required' "$TMP/nonroot.log"
printf 'SHELL=/usr/bin/bash\nUID=900\nGID=27\n' >"$receipt"
if bash "$script" --apply >"$TMP/mismatch.log" 2>&1; then
 echo 'FAIL: UID mismatch accepted' >&2; exit 1
fi
grep -q 'reason=receipt_identity_mismatch' "$TMP/mismatch.log"
printf 'SHELL=/bin/sh\nUID=1000\nGID=27\n' >"$receipt"
if bash "$script" --apply >"$TMP/tamper.log" 2>&1; then
 echo 'FAIL: arbitrary shell accepted' >&2; exit 1
fi
grep -q 'reason=original_unknown' "$TMP/tamper.log"
rm -f "$receipt"
bash "$script" --check >"$TMP/no-receipt-check.log"
grep -q 'AELLA_SHELL_SAVED=UNKNOWN' "$TMP/no-receipt-check.log"
if bash "$script" --apply >"$TMP/no-receipt.log" 2>&1; then
 echo 'FAIL: missing receipt accepted' >&2; exit 1
fi
grep -q 'reason=original_unknown' "$TMP/no-receipt.log"
grep -qx 'aella:x:1000:27::/home/aella:/bin/bash' "$MOCK_AELLA_PASSWD_FILE"

# From a known original, usermod failure must leave the account unchanged.
printf 'aella:x:1000:27::/home/aella:/usr/bin/bash\n' >"$MOCK_AELLA_PASSWD_FILE"
DP_PHASE2_STAGE_LIB_ONLY=1 bash -c '
 source "$1"; resolve_aella_ownership; install_phase2_aella_shell_recovery
' _ "$ROOT/client/stage-dp-phase2.sh" >"$TMP/restage2.log" 2>&1
printf 'aella:x:1000:27::/home/aella:/bin/bash\n' >"$MOCK_AELLA_PASSWD_FILE"
if MOCK_USERMOD_FAIL=YES bash "$script" --apply >"$TMP/usermod-fail.log" 2>&1; then
 echo 'FAIL: usermod failure accepted' >&2; exit 1
fi
grep -q 'reason=usermod_failed' "$TMP/usermod-fail.log"
grep -qx 'aella:x:1000:27::/home/aella:/bin/bash' "$MOCK_AELLA_PASSWD_FILE"
echo 'PHASE2_SHELL_RECOVERY_HERMETIC=PASS'
