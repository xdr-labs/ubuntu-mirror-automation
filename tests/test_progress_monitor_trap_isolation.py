#!/usr/bin/env python3
"""Regression contract for background progress-monitor lifecycle isolation."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def function_body(path: Path, name: str) -> str:
    text = path.read_text(encoding="utf-8")
    start_match = re.search(rf"(?m)^{re.escape(name)}\(\) \{{\n", text)
    if not start_match:
        raise AssertionError(f"missing function {name} in {path}")
    start = start_match.start()
    next_match = re.search(r"(?m)^[A-Za-z0-9_]+\(\) \{\n", text[start_match.end():])
    end = len(text) if not next_match else start_match.end() + next_match.start()
    return text[start:end]


def require_order(body: str, needles: list[str], label: str) -> None:
    pos = -1
    for needle in needles:
        nxt = body.find(needle, pos + 1)
        if nxt < 0:
            raise AssertionError(f"{label}: missing {needle!r}")
        if nxt <= pos:
            raise AssertionError(f"{label}: wrong ordering for {needle!r}")
        pos = nxt


server_cases = [
    (ROOT / "scripts/lib/acps_acquire.sh", "acps_download_one", "acps-progress-ready", "if curl "),
    (ROOT / "scripts/lib/r2_acquire.sh", "r2_download_package", "r2-progress-ready", "r2_http_download_to_part"),
]
for path, func, ready_name, transfer_anchor in server_cases:
    body = function_body(path, func)
    require_order(
        body,
        [
            ready_name,
            "trap - EXIT RETURN INT TERM",
            ': >"$monitor_ready"',
            "progress_pid=$!",
            'while [[ ! -e "$monitor_ready" ]]',
            transfer_anchor,
        ],
        func,
    )

client_path = ROOT / "client/lib/dp-phase2-operation-progress.sh"
client_cases = [
    ("dp2_run_with_heartbeat", "dp2-hb-ready"),
    ("dp2_run_download_with_progress", "dp2-dl-ready"),
    ("dp2_run_extract_with_progress", "dp2-ex-ready"),
]
for func, ready_name in client_cases:
    body = function_body(client_path, func)
    require_order(
        body,
        [
            ready_name,
            '"$@" &',
            "trap - EXIT RETURN",
            ': >"$monitor_ready"',
            "hb_pid=$!",
            'while [[ ! -e "$monitor_ready" ]]',
            'wait "$child_pid"',
        ],
        func,
    )

print("PROGRESS_MONITOR_TRAP_ISOLATION=PASS")
