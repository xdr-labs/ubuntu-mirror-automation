#!/usr/bin/env bash
# scripts/lib/client_mirror_gates.sh — gates for per-mirror host-pinned clients
# and for Mirror Manager runtime commands.
#
# Generated clients MUST embed the local Mirror HTTP URL. Host A and Host B
# produce different SHA256 digests; that is expected.
#
# shellcheck shell=bash

if [[ -n "${CLIENT_MIRROR_GATES_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
CLIENT_MIRROR_GATES_LOADED=1

client_gate_log_err() {
  printf '%s\n' "$*" >&2
}

client_extract_pin_value() {
  local script="${1:-}" pin_name="${2:-}" line value
  [[ -f "$script" && -n "$pin_name" ]] || return 1
  line="$(grep -m1 -E "^PIN_${pin_name}='" "$script" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 1
  value="${line#PIN_"${pin_name}"=\'}"
  value="${value%\'}"
  printf '%s\n' "$value"
}

client_extract_pin_mirror_base() {
  client_extract_pin_value "$1" "MIRROR_BASE"
}

client_decode_pin_b64_payload() {
  local script="${1:-}" pin_name="${2:-}"
  [[ -f "$script" && -n "$pin_name" ]] || return 1
  python3 - "$script" "$pin_name" <<'PY'
import base64, binascii, sys
script, pin_name = sys.argv[1], sys.argv[2]
text = open(script, "r", encoding="utf-8", errors="replace").read()
token = "PIN_{}='".format(pin_name)
start = text.find(token)
if start < 0:
    sys.exit(1)
start += len(token)
end = text.find("'", start)
if end < 0:
    sys.exit(1)
try:
    sys.stdout.write(
        base64.b64decode("".join(text[start:end].split())).decode("utf-8", "replace")
    )
except (binascii.Error, ValueError):
    sys.exit(1)
PY
}

# client_assert_mirror_base_match <script> <expected-mirror-base>
# Fail closed unless PIN_MIRROR_BASE and embedded meta/manifest use expected URL.
client_assert_mirror_base_match() {
  local script="${1:-}" expected="${2:-}"
  local pin_base sample_deb_url meta_text manifest_text mismatches=0
  expected="${expected%/}"

  if [[ ! -f "$script" ]]; then
    client_gate_log_err "HOST_PIN_GATE=FAIL missing artifact: ${script}"
    return 1
  fi
  if [[ -z "$expected" ]]; then
    client_gate_log_err "HOST_PIN_GATE=FAIL expected mirror base empty"
    return 1
  fi

  pin_base="$(client_extract_pin_mirror_base "$script" || true)"
  pin_base="${pin_base%/}"
  if [[ "$pin_base" != "$expected" ]]; then
    client_gate_log_err "HOST_PIN_GATE=FAIL PIN_MIRROR_BASE='${pin_base}' want='${expected}'"
    mismatches=$((mismatches + 1))
  fi

  # Mirror base is a literal URL, never an ERE: dots in IPv4/FQDN are not wildcards.
  sample_deb_url="$(client_extract_pin_value "$script" "SAMPLE_DEB_URL" || true)"
  if [[ "$sample_deb_url" != "${expected}/"* ]]; then
    client_gate_log_err "HOST_PIN_GATE=FAIL PIN_SAMPLE_DEB_URL does not use ${expected}"
    mismatches=$((mismatches + 1))
  fi

  meta_text="$(client_decode_pin_b64_payload "$script" "META_B64" || true)"
  if [[ -z "$meta_text" ]]; then
    client_gate_log_err "HOST_PIN_GATE=FAIL PIN_META_B64 decode failed"
    mismatches=$((mismatches + 1))
  else
    if ! grep -Fq "${expected}/" <<<"$meta_text"; then
      client_gate_log_err "HOST_PIN_GATE=FAIL embedded meta-release missing ${expected}"
      mismatches=$((mismatches + 1))
    fi
    if grep -Fq '@MIRROR_BASE@' <<<"$meta_text"; then
      client_gate_log_err "HOST_PIN_GATE=FAIL embedded meta-release still has placeholder"
      mismatches=$((mismatches + 1))
    fi
  fi

  manifest_text="$(client_decode_pin_b64_payload "$script" "MANIFEST_B64" || true)"
  if [[ -z "$manifest_text" ]]; then
    client_gate_log_err "HOST_PIN_GATE=FAIL PIN_MANIFEST_B64 decode failed"
    mismatches=$((mismatches + 1))
  else
    if ! grep -Fq "\"mirror_base\": \"${expected}\"" <<<"$manifest_text"; then
      # tolerate compact JSON without spaces
      if ! grep -Fq "\"mirror_base\":\"${expected}\"" <<<"$manifest_text"; then
        client_gate_log_err "HOST_PIN_GATE=FAIL manifest mirror_base != ${expected}"
        mismatches=$((mismatches + 1))
      fi
    fi
  fi

  printf 'HOST_PIN_GATE_MISMATCH_COUNT=%s\n' "$mismatches"
  if [[ "$mismatches" -ne 0 ]]; then
    printf 'HOST_PIN_GATE=FAIL\n'
    return 1
  fi
  printf 'HOST_PIN_GATE=PASS expected=%s\n' "$expected"
  return 0
}

# Backward-compatible name used by older callers; now enforces host pin match
# when an expected URL is provided, otherwise requires a non-empty pin.
client_assert_generic_artifact() {
  local script="${1:-}" expected="${2:-}"
  if [[ -n "$expected" ]]; then
    client_assert_mirror_base_match "$script" "$expected"
    return $?
  fi
  local pin_base
  pin_base="$(client_extract_pin_mirror_base "$script" || true)"
  if [[ -z "$pin_base" ]]; then
    client_gate_log_err "HOST_PIN_GATE=FAIL PIN_MIRROR_BASE empty (host-independent clients are not allowed)"
    return 1
  fi
  printf 'HOST_PIN_GATE=PASS pin=%s\n' "$pin_base"
  return 0
}

# Verify EVERY explicit mirror option token uses the exact literal mirror URL.
# The operator command is not executable here: this is a read-only string check.
# Checking every occurrence matters because the last repeated CLI flag may win.
client_gate_all_mirror_flags_match() {
  local text="$1" option="$2" expected="$3" matches row value
  case "$option" in
    --mirror-base|--mirror-url) ;;
    *) return 1 ;;
  esac
  matches="$(grep -oE -- "(^|[[:space:]])${option}[[:space:]]+[^[:space:]]+" <<<"$text")" || return 1
  [[ -n "$matches" ]] || return 1
  while IFS= read -r row || [[ -n "$row" ]]; do
    value="${row#*"$option"}"
    # Trim whitespace between the flag and its value without interpreting it.
    value="${value#"${value%%[![:space:]]*}"}"
    [[ "$value" == "$expected" ]] || return 1
  done <<<"$matches"
  return 0
}

# client_assert_command_mirror_base <command-text-file-or--> <expected-base>
# Verifies hop commands use the persisted local Mirror URL (optional --mirror-base).
client_assert_command_mirror_base() {
  local src="${1:-}" expected="${2:-}"
  local text
  expected="${expected%/}"
  [[ -n "$expected" ]] || {
    client_gate_log_err "RUNTIME_COMMAND_GATE=FAIL expected mirror base empty"
    return 1
  }
  if [[ "$src" == "-" ]]; then
    text="$(cat)"
  elif [[ -f "$src" ]]; then
    text="$(cat "$src")"
  else
    text="$src"
  fi
  # Prefer explicit --mirror-base when present; otherwise require curl URL host match.
  if grep -q -- '--mirror-base' <<<"$text"; then
    if ! client_gate_all_mirror_flags_match "$text" "--mirror-base" "$expected"; then
      client_gate_log_err "RUNTIME_COMMAND_GATE=FAIL hop command --mirror-base != ${expected}"
      return 1
    fi
  elif ! grep -Fq "${expected}/client/" <<<"$text"; then
    client_gate_log_err "RUNTIME_COMMAND_GATE=FAIL hop command missing ${expected}/client/"
    return 1
  fi
  if grep -q -- 'stage-dp-phase2.sh' <<<"$text"; then
    if grep -q -- '--mirror-url' <<<"$text"; then
      if ! client_gate_all_mirror_flags_match "$text" "--mirror-url" "$expected"; then
        client_gate_log_err "RUNTIME_COMMAND_GATE=FAIL phase2 --mirror-url != ${expected}"
        return 1
      fi
    fi
  fi
  printf 'RUNTIME_COMMAND_GATE=PASS expected=%s\n' "$expected"
  return 0
}
