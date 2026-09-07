# tests/lib/portable_ip_policy.sh — thin wrapper around portable_ip_policy.py
# for Mirror Manager / Menu 7 / client command portable-IP regression checks.

# shellcheck shell=bash

_portable_ip_policy_py() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "${here}/portable_ip_policy.py"
}

# Scan stdin. Usage: ... | portable_ip_policy_scan_text <label>
portable_ip_policy_scan_text() {
  local label="${1:-input}"
  python3 "$(_portable_ip_policy_py)" --label "$label"
}

portable_ip_policy_assert_file() {
  local label="$1"
  local path="$2"
  [[ -f "$path" ]] || {
    echo "PORTABLE_IP_POLICY_FAIL label=${label} missing_file=${path}" >&2
    return 1
  }
  python3 "$(_portable_ip_policy_py)" --label "$label" "$path"
}

portable_ip_policy_assert_files() {
  local label_prefix="$1"
  shift
  local f
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    portable_ip_policy_assert_file "${label_prefix}:$(basename "$f")" "$f" || return 1
  done
  return 0
}
