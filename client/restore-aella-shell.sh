#!/usr/bin/env bash
# Local aella login-shell restoration after Phase 2 bringup.
# This script is installed before staging changes aella to /bin/bash.
set -euo pipefail
set +x

STATE=/opt/aelladata/os-upgrade/offline/aella-shell-restore.state
mode=restore
override=""
while (($#)); do
  case "$1" in
    --status) mode=status; shift ;;
    --restore) mode=restore; shift ;;
    --auto) mode=auto; shift ;;
    --target)
      if (($# < 2)); then echo "AELLA_SHELL_RESTORE=FAIL reason=missing_target" >&2; exit 2; fi
      override="$2"; shift 2 ;;
    *) echo "Usage: sudo bash $0 [--status|--restore|--auto] [--target /usr/bin/aella_cli]" >&2; exit 2 ;;
  esac
done
if [[ -n "$override" && "$mode" != restore ]]; then
  echo "AELLA_SHELL_RESTORE=FAIL reason=override_requires_manual_mode" >&2
  exit 2
fi
if (( EUID != 0 )); then
  echo "AELLA_SHELL_RESTORE=FAIL reason=root_required" >&2
  exit 1
fi
record="$(getent passwd aella)" || { echo "AELLA_SHELL_RESTORE=FAIL reason=account_missing" >&2; exit 1; }
[[ "$record" != *$'\n'* ]] || { echo "AELLA_SHELL_RESTORE=FAIL reason=invalid_account" >&2; exit 1; }
IFS=: read -r user password uid gid comment home current <<<"$record"
if [[ "$user" != aella || ! "$uid" =~ ^[0-9]+$ || ! "$gid" =~ ^[0-9]+$ ]]; then
  echo "AELLA_SHELL_RESTORE=FAIL reason=invalid_account_identity" >&2
  exit 1
fi

original=""
if [[ -e "$STATE" || -L "$STATE" ]]; then
  if [[ ! -f "$STATE" || -L "$STATE" ]] || [[ "$(stat -c %u "$STATE")" != 0 ]]; then
    echo "AELLA_SHELL_RESTORE=FAIL reason=untrusted_state" >&2
    exit 1
  fi
  saved="$(cat "$STATE")"
  [[ "$saved" != *$'\n'* ]] || { echo "AELLA_SHELL_RESTORE=FAIL reason=state_multiline" >&2; exit 1; }
  IFS=: read -r saved_user saved_uid saved_gid original extra <<<"$saved"
  if [[ "$saved_user" != aella || "$saved_uid" != "$uid" || "$saved_gid" != "$gid" || -n "$extra" ]]; then
    echo "AELLA_SHELL_RESTORE=FAIL reason=state_identity_mismatch" >&2
    exit 1
  fi
fi
if [[ "$mode" == status ]]; then
  printf 'AELLA_SHELL_CURRENT=%s\nAELLA_SHELL_RECORDED=%s\n' "$current" "$original"
  exit 0
fi
target="$original"
if [[ -n "$override" ]]; then target="$override"; fi
case "$target" in
  /usr/bin/aella_cli|/usr/bin/bash|/bin/bash) ;;
  *) echo "AELLA_SHELL_RESTORE=FAIL reason=unknown_original_shell (manual --target required)" >&2; exit 1 ;;
esac
case "$current" in
  /usr/bin/aella_cli|/usr/bin/bash|/bin/bash) ;;
  *) echo "AELLA_SHELL_RESTORE=FAIL reason=unexpected_current_shell" >&2; exit 1 ;;
esac
if [[ ! -x "$target" ]]; then
  echo "AELLA_SHELL_RESTORE=FAIL reason=target_not_executable target=$target" >&2
  exit 1
fi
if [[ "$current" == "$target" ]]; then
  echo "AELLA_SHELL_RESTORE=ALREADY target=$target"
  exit 0
fi
command -v usermod >/dev/null 2>&1 ||
  { echo "AELLA_SHELL_RESTORE=FAIL reason=usermod_missing" >&2; exit 1; }
if ! usermod -s "$target" aella; then
  echo "AELLA_SHELL_RESTORE=FAIL reason=usermod_failed" >&2
  exit 1
fi
after="$(getent passwd aella)" ||
  { echo "AELLA_SHELL_RESTORE=FAIL reason=verify_lookup_failed" >&2; exit 1; }
IFS=: read -r after_user after_pw after_uid after_gid after_gecos after_home after_shell <<<"$after"
if [[ "$after_user" != aella || "$after_uid" != "$uid" || "$after_gid" != "$gid" || "$after_shell" != "$target" ]]; then
  echo "AELLA_SHELL_RESTORE=FAIL reason=verify_mismatch" >&2
  exit 1
fi
echo "AELLA_SHELL_RESTORE=PASS from=$current to=$target"
