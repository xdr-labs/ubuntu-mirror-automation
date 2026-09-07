#!/usr/bin/env bash
# Installed CLI entrypoint. Delegates all normal commands to the authoritative
# runtime and applies display/status compatibility fixes for operator workflows.
# Canonical generated command files and artifact trust decisions remain unchanged.
set -euo pipefail
set +x

UOM_RUNTIME_ROOT="${UOM_RUNTIME_ROOT:-/usr/local/lib/ubuntu-mirror}"
UOM_CORE_ENTRY="${UOM_CORE_ENTRY:-${UOM_RUNTIME_ROOT}/scripts/ubuntu-offline-mirror.sh}"
UOM_MANAGER_ENTRY="${UOM_MANAGER_ENTRY:-${UOM_RUNTIME_ROOT}/scripts/install-dp-upgrade-mirror.sh}"

uom_format_menu7_file() {
  local input="$1" output="$2"
  [[ -f "$input" ]] || {
    printf 'MENU7_DISPLAY_FORMAT=FAIL reason=input_missing path=%s\n' "$input" >&2
    return 1
  }

  python3 - "$input" "$output" <<'PY'
from pathlib import Path
import re
import sys

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

# Canonical WRAPPER_V1 command written by gui_client_hop_command_line().
# The formatter changes presentation only; it does not change the saved command
# file or any trust decision. Wrapper one-liners are shown as 3 continuation lines.
COPY_ONE_LINE = "Copy and paste the following entire line into the DP terminal:"
COPY_THREE_LINES = "Copy and paste all 3 lines together into the DP terminal:"
hop_pat = re.compile(
    r"^cd /home/aella && curl -fsSLo "
    r"(?P<wrapper>upgrade-(?:xenial-to-bionic|bionic-to-focal|focal-to-jammy|jammy-to-noble)\.sh)\.download "
    r"(?P<url>\S+) && printf '%s  %s\\n' "
    r"'(?P<sha>[0-9A-Fa-f]{64})' "
    r"'(?P=wrapper)\.download' \| sha256sum -c - && "
    r"mv -f (?P=wrapper)\.download (?P=wrapper) && "
    r"bash \./(?P=wrapper)$"
)
phase2_pat = re.compile(
    r"^cd /home/aella && curl -fsSLo "
    r"(?P<wrapper>upgrade-phase2\.sh)\.download "
    r"(?P<url>\S+) && printf '%s  %s\\n' "
    r"'(?P<sha>[0-9A-Fa-f]{64})' "
    r"'(?P=wrapper)\.download' \| sha256sum -c - && "
    r"mv -f (?P=wrapper)\.download (?P=wrapper) && "
    r"bash \./(?P=wrapper)$"
)


def wrapper_display_lines(wrapper, url, sha):
    suffix = f"/client/{wrapper}"
    if not url.endswith(suffix):
        raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=wrapper_url_shape")
    client_base = url[: -len(wrapper)].rstrip("/")
    if not client_base.endswith("/client") or not client_base:
        raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=mirror_url_empty")
    line1 = (
        f"cd /home/aella && F='{wrapper}' && D=\"$F.download\" && "
        f"U='{client_base}' && \\"
    )
    line2 = f"H='{sha}' && curl -fsSLo \"$D\" \"$U/$F\" && \\"
    line3 = (
        "printf '%s  %s\\n' \"$H\" \"$D\" | sha256sum -c - && "
        "mv -f \"$D\" \"$F\" && bash \"./$F\""
    )
    rendered = [line1, line2, line3]
    joined = "\n".join(rendered)
    if re.search(r"curl[^|;]*\|[[:space:]]*(bash|sh)([[:space:]]|$)", joined):
        raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=curl_pipe_bash")
    if ".sha256" in joined or "dp-launch-" in joined:
        raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=trust_leak")
    if "for F in" in joined or "BASH_SUBSHELL" in joined:
        raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=phase2_legacy_bootstrap")
    if not line1.endswith("\\") or not line2.endswith("\\"):
        raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=continuation_missing")
    if line1.rstrip("\\") != line1[:-1] or line2.rstrip("\\") != line2[:-1]:
        raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=continuation_trailing_space")
    if line3.endswith("\\"):
        raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=final_line_continued")
    return rendered


def next_substantive_line(lines, start):
    j = start
    while j < len(lines):
        candidate = lines[j]
        if candidate == "" or candidate == COPY_ONE_LINE:
            j += 1
            continue
        return candidate
    return ""

# FULL-mode safety emphasis. This is intentionally presentation-only: it makes
# the existing mandatory pause instruction impossible to miss without changing
# any generated command, checksum, workflow generation, or trust decision.
pause_heading = "STEP 1 — PAUSE DP SERVICES"
pause_underline = "--------------------------"
pause_completion = "Wait until the pause operation completes."
pause_warning = [
    "",
    "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!",
    "CRITICAL — PAUSE IS MANDATORY. DO NOT SKIP STEP 1.",
    "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!",
    "",
    "The DP MUST be paused before any Ubuntu OS upgrade command is run.",
    "DO NOT start STEP 2 until `aella_cli` -> `pause` has completed successfully.",
    "",
    "Skipping this step can leave DP services running during the OS upgrade.",
    "This may cause severe memory pressure/OOM, upgrade failure, or an unstable DP.",
]
pause_stop_warning = [
    "",
    "STOP: Confirm the pause is fully complete before continuing to STEP 2.",
]

lines = src.read_text(encoding="utf-8").splitlines()
out: list[str] = []
hop_wrapped = 0
phase2_wrapped = 0
pause_emphasized = 0
pause_completion_emphasized = 0
i = 0
while i < len(lines):
    line = lines[i]

    if (
        line == pause_heading
        and i + 1 < len(lines)
        and lines[i + 1] == pause_underline
    ):
        out.extend([line, lines[i + 1], *pause_warning])
        pause_emphasized += 1
        i += 2
        continue

    if line == pause_completion:
        out.append(line)
        out.extend(pause_stop_warning)
        pause_completion_emphasized += 1
        i += 1
        continue

    if line == COPY_ONE_LINE:
        nxt = next_substantive_line(lines, i + 1)
        if hop_pat.match(nxt) or phase2_pat.match(nxt):
            prev = next((item for item in reversed(out) if item), "")
            if prev != COPY_THREE_LINES:
                out.append(COPY_THREE_LINES)
            i += 1
            continue

    m = hop_pat.match(line)
    if m:
        if re.search(r"curl[^|;]*\|[[:space:]]*(bash|sh)([[:space:]]|$)", line):
            raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=curl_pipe_bash")
        out.extend(wrapper_display_lines(m.group("wrapper"), m.group("url"), m.group("sha")))
        hop_wrapped += 1
        i += 1
        continue

    p2 = phase2_pat.match(line)
    if p2:
        if re.search(r"curl[^|;]*\|[[:space:]]*(bash|sh)([[:space:]]|$)", line):
            raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=curl_pipe_bash")
        if "for F in" in line or "BASH_SUBSHELL" in line:
            raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=phase2_legacy_bootstrap")
        out.extend(
            wrapper_display_lines(p2.group("wrapper"), p2.group("url"), p2.group("sha"))
        )
        phase2_wrapped += 1
        i += 1
        continue

    out.append(line)
    i += 1

if hop_wrapped not in (0, 4):
    raise SystemExit(
        f"MENU7_DISPLAY_FORMAT=FAIL reason=unexpected_launcher_count count={hop_wrapped}"
    )
if phase2_wrapped not in (0, 1):
    raise SystemExit(
        f"MENU7_DISPLAY_FORMAT=FAIL reason=unexpected_phase2_count count={phase2_wrapped}"
    )
if pause_emphasized not in (0, 1) or pause_completion_emphasized not in (0, 1):
    raise SystemExit(
        "MENU7_DISPLAY_FORMAT=FAIL reason=unexpected_pause_section_count "
        f"heading={pause_emphasized} completion={pause_completion_emphasized}"
    )
if pause_emphasized != pause_completion_emphasized:
    raise SystemExit(
        "MENU7_DISPLAY_FORMAT=FAIL reason=incomplete_pause_section "
        f"heading={pause_emphasized} completion={pause_completion_emphasized}"
    )

leftover = [
    line
    for line in out
    if re.match(r"^cd /home/aella && curl -fsSLo upgrade-", line)
]
if leftover:
    raise SystemExit(
        "MENU7_DISPLAY_FORMAT=FAIL reason=unwrapped_canonical_command "
        f"count={len(leftover)}"
    )

dst.write_text("\n".join(out) + "\n", encoding="utf-8")
print(
    f"MENU7_DISPLAY_FORMAT=PASS wrapped_launchers={hop_wrapped} "
    f"wrapped_phase2={phase2_wrapped} pause_emphasized={pause_emphasized}",
    file=sys.stderr,
)
PY
}

# Artifact status values written by a successful reuse path are semantically
# equivalent to PASS. Keep the accepted set deliberately narrow: FAIL, blank,
# and unknown values must continue to fail closed.
uom_status_success() {
  case "${1:-}" in
    PASS|REUSED) return 0 ;;
    *) return 1 ;;
  esac
}

# Independent, cheap status checks used by the status screen. These avoid the
# old all-or-nothing MM_WF_DOWNLOAD_COMPLETED coupling, where one OS status
# mismatch incorrectly made the Phase 2 bundle appear NOT READY (and vice versa).
uom_os_upgrade_files_completed() {
  mm_configuration_completed || return 1
  mm_is_phase2_only && return 0
  engine_resolve_paths 2>/dev/null || true
  [[ -d "${MM_SELECTIVE_ROOT}/ubuntu" || -L "${MM_SELECTIVE_ROOT}/ubuntu" ]] || return 1
  uom_status_success "$(mm_status_get OS_MIRROR_READY)" || return 1
  uom_status_success "$(mm_status_get R2_OS_CORE_CHECKSUM)" || return 1
  mm_client_files_ready "${MM_CLIENT_ROOT}" || return 1
  mm_client_set_current_source "${MM_CLIENT_ROOT}" >/dev/null 2>&1 || return 1
  return 0
}

uom_phase2_bundle_completed() {
  local bundle_ck entries
  mm_configuration_completed || return 1
  engine_resolve_paths 2>/dev/null || true
  mm_phase2_paths
  [[ -f "${MM_WF_PHASE2_RELEASE}" ]] || return 1
  [[ -f "${MM_WF_PHASE2_BUNDLE}" ]] || return 1
  [[ -f "${MM_WF_PHASE2_SIDECAR}" ]] || return 1
  bundle_ck="$(mm_status_get PHASE2_BUNDLE_CHECKSUM)"
  entries="$(mm_status_get PHASE2_BUNDLE_ENTRY_COUNT)"
  uom_status_success "$bundle_ck" || return 1
  [[ "$entries" == "9" ]] || return 1
  mm_client_files_ready_phase2 "${MM_CLIENT_ROOT}" || return 1
  return 0
}

# Replacement for gui_show_status(): compute OS Core and Phase 2 readiness
# independently, while the overall progress/readiness still uses the generation-
# bound workflow contract through mm_collect_workflow_status().
# Download completion / fingerprint verification stays on the authoritative
# core mm_download_completed() (fail-closed when DOWNLOAD_ARTIFACT_FINGERPRINT
# is missing; never mint provenance from a read/status path).
uom_gui_show_status() {
  load_mirror_defaults
  mm_load_gui_config
  mm_normalize_preparation_mode
  mm_force_phase2_target
  engine_resolve_paths
  local tmp ver config_state os_state bundle_state http_state ready_state start_os final_os
  ver="${PHASE2_TARGET_VERSION}"
  mm_collect_workflow_status
  if [[ "${MM_WF_CONFIG_COMPLETED}" == "1" ]]; then
    config_state="PASS"
  else
    config_state="FAIL"
  fi
  if mm_is_phase2_only; then
    start_os="Ubuntu 24.04"
    final_os="Ubuntu 24.04"
    os_state="NOT REQUIRED"
  else
    start_os="Ubuntu 16.04"
    final_os="Ubuntu 24.04"
    if uom_os_upgrade_files_completed; then
      os_state="READY"
    else
      os_state="NOT READY"
    fi
  fi
  if uom_phase2_bundle_completed; then
    bundle_state="READY (9 files)"
  else
    bundle_state="NOT READY"
  fi
  if [[ "${MM_WF_HTTP_COMPLETED}" == "1" ]]; then
    http_state="ENABLED"
  else
    http_state="$(mm_status_get HTTP_DISTRIBUTION)"
    [[ -n "$http_state" ]] || http_state="DISABLED"
    [[ "$http_state" == "ENABLED" ]] || http_state="DISABLED"
  fi
  ready_state="$(mm_upgrade_readiness_display)"
  [[ -n "$ready_state" ]] || ready_state="NOT VERIFIED"
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF_STATUS
DP Upgrade Mirror Status
========================

Supported Starting DP Versions: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0
Phase 2 Target: ${ver}
Preparation Mode: $(mm_preparation_mode_label)
Starting OS: ${start_os}
Final OS: ${final_os}
Configuration: ${config_state}
OS Upgrade Files: ${os_state}
DP ${ver} Bundle: ${bundle_state}
HTTP Distribution: ${http_state}
Upgrade Readiness: ${ready_state}
Last Operation: $(mm_status_get LAST_EXECUTION_RESULT)
Log File: $(mm_status_get LOG_PATH)

$(mm_workflow_progress_text)
EOF_STATUS
  mm_whiptail_textbox "Current Status" "$tmp" || true
  rm -f "$tmp"
  return 0
}

uom_install_status_overrides() {
  # Intentionally do NOT override mm_download_completed: the core implementation
  # is authoritative for generation-bound fingerprint verification.
  eval "$(
    declare -f uom_gui_show_status \
      | sed '1s/^uom_gui_show_status[[:space:]]*()/gui_show_status ()/'
  )"
}

uom_run_mirror_manager() {
  [[ -f "$UOM_MANAGER_ENTRY" ]] || {
    printf 'ERROR: Mirror Manager runtime is missing: %s\n' "$UOM_MANAGER_ENTRY" >&2
    exit 1
  }

  local manager_dir manager_lib
  manager_dir="$(cd "$(dirname "$UOM_MANAGER_ENTRY")" && pwd)"
  manager_lib="$(mktemp /tmp/ubuntu-mirror-manager-lib.XXXXXX.sh)"
  trap 'rm -f "${manager_lib:-}"' EXIT

  # Source the installed manager as a library. Pin SCRIPT_DIR to its installed
  # location so its relative library imports remain authoritative.
  awk -v sd="$manager_dir" '
    /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
    /^main "\$@"$/ { next }
    { print }
  ' "$UOM_MANAGER_ENTRY" >"$manager_lib"
  # shellcheck source=/dev/null
  source "$manager_lib"
  rm -f "$manager_lib"
  manager_lib=""

  uom_install_status_overrides

  if ! declare -F mm_menu7_textbox >/dev/null 2>&1; then
    printf 'ERROR: Menu 7 viewer function is unavailable in installed runtime.\n' >&2
    exit 1
  fi

  # Preserve the core viewer and override only its input presentation.
  eval "$(
    declare -f mm_menu7_textbox \
      | sed '1s/^mm_menu7_textbox[[:space:]]*()/_uom_core_menu7_textbox ()/'
  )"

  mm_menu7_textbox() {
    local title="$1" canonical="$2" display rc=0
    display="$(mktemp /tmp/dp-client-upgrade-commands-display.XXXXXX.txt)"
    if uom_format_menu7_file "$canonical" "$display"; then
      _uom_core_menu7_textbox "$title" "$display" || rc=$?
    else
      rm -f "$display"
      return 1
    fi
    rm -f "$display"
    return "$rc"
  }

  main "$@"
}

uom_main() {
  case "${1:-mirror-manager}" in
    --format-menu7)
      [[ $# -eq 3 ]] || {
        printf 'Usage: %s --format-menu7 INPUT OUTPUT\n' "$0" >&2
        exit 2
      }
      uom_format_menu7_file "$2" "$3"
      ;;
    mirror-manager|install-menu)
      uom_run_mirror_manager "$@"
      ;;
    *)
      [[ -x "$UOM_CORE_ENTRY" || -f "$UOM_CORE_ENTRY" ]] || {
        printf 'ERROR: Core runtime entrypoint is missing: %s\n' "$UOM_CORE_ENTRY" >&2
        exit 1
      }
      exec bash "$UOM_CORE_ENTRY" "$@"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  uom_main "$@"
fi
