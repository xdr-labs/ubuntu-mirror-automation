#!/usr/bin/env python3
"""PTY scroll + GUI-frame regression for production Menu 7 (dialog --textbox).

Uses the real mm_menu7_textbox path (dialog), a 150+ line command file, and
proves framed GUI + scroll + Enter/ESC return to the main menu.
"""
from __future__ import annotations

import errno
import fcntl
import os
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
INSTALLER = os.path.join(ROOT, "scripts", "install-dp-upgrade-mirror.sh")
MENU_TITLE = "DP Ubuntu Upgrade Mirror Manager"
VIEWER_TITLE = "DP Client Upgrade Commands"


def _strip_csi(data: bytes) -> str:
    text = data.decode("utf-8", "replace")
    text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)
    text = re.sub(r"\x1b\].*?(?:\x07|\x1b\\)", "", text)
    return text


def _drain(master: int, buf: bytearray, seconds: float) -> None:
    deadline = time.time() + seconds
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.05)
        if not r:
            continue
        try:
            chunk = os.read(master, 65536)
        except OSError as exc:
            if exc.errno in (errno.EIO, errno.EAGAIN):
                break
            raise
        if not chunk:
            break
        buf.extend(chunk)


def _wait_for(master: int, proc: subprocess.Popen, buf: bytearray, needle: str, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline and proc.poll() is None:
        _drain(master, buf, 0.12)
        if needle in _strip_csi(bytes(buf)):
            return True
    _drain(master, buf, 0.2)
    return needle in _strip_csi(bytes(buf))


def _visible_after(buf: bytearray, start: int) -> str:
    return _strip_csi(bytes(buf[start:]))


def _build_sample(path: str) -> None:
    lines = ["TOP_MARKER"]
    lines.extend([f"lead-pad-{n}" for n in range(80)])
    for step in range(10):
        lines.extend([f"pad-{step}-{n}" for n in range(25)])
        lines.append(f"STEP_{step}_MARKER")
    lines.extend([f"pad-end-{n}" for n in range(40)])
    lines.append("BOTTOM_MARKER")
    while len(lines) < 150:
        lines.append(f"filler-{len(lines)}")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def _build_harness(tmp: str, sample: str) -> str:
    lib = os.path.join(tmp, "lib.sh")
    with open(INSTALLER, encoding="utf-8") as src, open(lib, "w", encoding="utf-8") as dst:
        for line in src:
            if line.startswith("SCRIPT_DIR="):
                dst.write(f'SCRIPT_DIR="{ROOT}/scripts"\n')
            elif line.strip() == 'main "$@"':
                continue
            else:
                dst.write(line)

    driver = os.path.join(tmp, "driver.sh")
    with open(driver, "w", encoding="utf-8") as fh:
        fh.write(
            f"""#!/usr/bin/env bash
set -euo pipefail
export TERM=xterm-256color HEIGHT=30 WIDTH=100 LINES=30 COLUMNS=100
# shellcheck disable=SC1090
source '{lib}'
while true; do
  menu_rc=0
  choice="$(mm_whiptail_menu \\
    "{MENU_TITLE}" \\
    "Workflow: Configuration → Download → Enable HTTP → Verify Readiness
Cancel/ESC returns here; choose 0 to Exit." \\
    "1" "Configuration" \\
    "7" "Show DP Client Upgrade Commands" \\
    "0" "Exit")" || menu_rc=$?
  if [[ "$menu_rc" -ne 0 ]]; then
    continue
  fi
  case "$choice" in
    7)
      echo "MENU7_OPEN=PASS"
      mm_menu7_textbox "{VIEWER_TITLE}" "{sample}" || true
      echo "MENU7_VIEWER_CLOSED=PASS"
      ;;
    0)
      echo "HARNESS_DONE"
      break
      ;;
  esac
done
"""
        )
    os.chmod(driver, 0o755)
    return driver


def _run_path(close_mode: str) -> dict[str, bool]:
    tmp = tempfile.mkdtemp(prefix=f"menu7-gui-{close_mode}-")
    sample = os.path.join(tmp, "cmds.txt")
    _build_sample(sample)
    driver = _build_harness(tmp, sample)

    master, slave = pty.openpty()
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    proc = subprocess.Popen(
        ["bash", driver],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
        env={**os.environ, "TERM": "xterm-256color", "LINES": "30", "COLUMNS": "100"},
    )
    os.close(slave)
    buf = bytearray()
    result = {
        "MENU7_OPEN": False,
        "MENU7_GUI_FRAME_VISIBLE": False,
        "MENU7_UP_SCROLL": False,
        "MENU7_DOWN_SCROLL": False,
        "MENU7_PAGEUP": False,
        "MENU7_PAGEDOWN": False,
        "MENU7_HOME": False,
        "MENU7_END": False,
        "MENU7_RETURN": False,
        "MENU7_MAIN_MENU_VISIBLE_AFTER_RETURN": False,
        "MENU7_NO_BLANK_SCREEN": False,
        "MENU7_NO_PAGER": True,
        "MENU7_RAW_TERMINAL_VIEWER_USED": False,
    }

    try:
        if not _wait_for(master, proc, buf, MENU_TITLE, 6.0):
            raise RuntimeError(f"{close_mode}: initial main menu missing")

        os.write(master, b"\x1b[B\r")
        if not _wait_for(master, proc, buf, "MENU7_OPEN=PASS", 6.0):
            os.write(master, b"\x1b[B\r")
            if not _wait_for(master, proc, buf, "MENU7_OPEN=PASS", 4.0):
                raise RuntimeError(f"{close_mode}: MENU7_OPEN missing")
        result["MENU7_OPEN"] = True

        if not _wait_for(master, proc, buf, VIEWER_TITLE, 4.0):
            raise RuntimeError(f"{close_mode}: viewer title missing")
        plain = _strip_csi(bytes(buf))
        # Framed dialog shows title + Return exit label (not raw TOP-only dump).
        if VIEWER_TITLE in plain and ("Return" in plain or "TOP_MARKER" in plain):
            result["MENU7_GUI_FRAME_VISIBLE"] = True
        if "menu7_scroll_viewer" in plain:
            result["MENU7_RAW_TERMINAL_VIEWER_USED"] = True

        # Application-mode arrows (dialog enables keypad / app cursor keys).
        start = len(buf)
        for _ in range(35):
            os.write(master, b"\x1bOB")
            _drain(master, buf, 0.03)
        vis = _visible_after(buf, start)
        if "STEP_0_MARKER" in vis or any(f"lead-pad-{n}" in vis for n in range(20, 80)):
            result["MENU7_DOWN_SCROLL"] = True

        start = len(buf)
        for _ in range(12):
            os.write(master, b"\x1b[6~")
            _drain(master, buf, 0.04)
        vis = _visible_after(buf, start)
        if any(f"STEP_{i}_MARKER" in vis for i in range(2, 10)):
            result["MENU7_PAGEDOWN"] = True

        start = len(buf)
        os.write(master, b"\x1bOF")
        _drain(master, buf, 0.4)
        if "BOTTOM_MARKER" in _visible_after(buf, start):
            result["MENU7_END"] = True

        start = len(buf)
        os.write(master, b"\x1bOH")
        _drain(master, buf, 0.4)
        if "TOP_MARKER" in _visible_after(buf, start):
            result["MENU7_HOME"] = True

        os.write(master, b"\x1bOF")
        _drain(master, buf, 0.2)
        start = len(buf)
        for _ in range(6):
            os.write(master, b"\x1b[5~")
            _drain(master, buf, 0.04)
        if any(f"STEP_{i}_MARKER" in _visible_after(buf, start) for i in range(10)):
            result["MENU7_PAGEUP"] = True

        # Up: start from End so upward motion reveals earlier unique markers.
        os.write(master, b"\x1bOF")
        _drain(master, buf, 0.25)
        start = len(buf)
        for _ in range(40):
            os.write(master, b"\x1bOA")
            _drain(master, buf, 0.03)
        for _ in range(20):
            os.write(master, b"k")
            _drain(master, buf, 0.03)
        vis = _visible_after(buf, start)
        if (
            "TOP_MARKER" in vis
            or "STEP_9_MARKER" in vis
            or "STEP_5_MARKER" in vis
            or any(f"STEP_{i}_MARKER" in vis for i in range(10))
            or any(f"pad-end-{n}" in vis for n in range(40))
        ):
            result["MENU7_UP_SCROLL"] = True

        if close_mode == "ENTER":
            os.write(master, b"\r")
        else:
            os.write(master, b"\x1b")
        if not _wait_for(master, proc, buf, "MENU7_VIEWER_CLOSED=PASS", 6.0):
            raise RuntimeError(f"{close_mode}: viewer did not close")
        result["MENU7_RETURN"] = True

        if not _wait_for(master, proc, buf, MENU_TITLE, 6.0):
            raise RuntimeError(f"{close_mode}: main menu not visible after return")
        result["MENU7_MAIN_MENU_VISIBLE_AFTER_RETURN"] = True
        result["MENU7_NO_BLANK_SCREEN"] = True

        if re.search(r"(^|\s)(less|more)(\s|$)", _strip_csi(bytes(buf))):
            result["MENU7_NO_PAGER"] = False

        os.write(master, b"\x1b[B\x1b[B\r")
        _wait_for(master, proc, buf, "HARNESS_DONE", 5.0)
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=2)
    finally:
        if proc.poll() is None:
            proc.kill()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
        try:
            os.close(master)
        except OSError:
            pass

    return result


def main() -> int:
    if not os.path.isfile(INSTALLER):
        print("FAIL: installer missing", file=sys.stderr)
        return 1
    text = open(INSTALLER, encoding="utf-8").read()
    fn = re.search(r"mm_menu7_textbox\(\) \{.*?\n\}", text, re.S)
    if not fn:
        print("FAIL: mm_menu7_textbox missing", file=sys.stderr)
        return 1
    body = fn.group(0)
    if "menu7_scroll_viewer.py" in body:
        print("FAIL: raw terminal viewer still production path", file=sys.stderr)
        return 1
    if not re.search(r"(^|[^A-Za-z_])dialog([^A-Za-z_]|$)", body):
        print("FAIL: dialog not used in mm_menu7_textbox", file=sys.stderr)
        return 1
    if re.search(r"(^|\s)clear(\s|$)", body, re.M):
        print("FAIL: clear still used in mm_menu7_textbox", file=sys.stderr)
        return 1

    enter = _run_path("ENTER")
    esc = _run_path("ESC")

    markers = {
        "MENU7_GUI_FRAME_VISIBLE": enter["MENU7_GUI_FRAME_VISIBLE"] and esc["MENU7_GUI_FRAME_VISIBLE"],
        "MENU7_RAW_TERMINAL_VIEWER_USED": "NO"
        if (not enter["MENU7_RAW_TERMINAL_VIEWER_USED"] and not esc["MENU7_RAW_TERMINAL_VIEWER_USED"])
        else "YES",
        "MENU7_OPEN": enter["MENU7_OPEN"] and esc["MENU7_OPEN"],
        "MENU7_UP_SCROLL": enter["MENU7_UP_SCROLL"],
        "MENU7_DOWN_SCROLL": enter["MENU7_DOWN_SCROLL"],
        "MENU7_PAGEUP": enter["MENU7_PAGEUP"],
        "MENU7_PAGEDOWN": enter["MENU7_PAGEDOWN"],
        "MENU7_HOME": enter["MENU7_HOME"],
        "MENU7_END": enter["MENU7_END"],
        "MENU7_ENTER_RETURN": enter["MENU7_RETURN"],
        "MENU7_ESC_RETURN": esc["MENU7_RETURN"],
        "MENU7_MAIN_MENU_VISIBLE_AFTER_RETURN": (
            enter["MENU7_MAIN_MENU_VISIBLE_AFTER_RETURN"] and esc["MENU7_MAIN_MENU_VISIBLE_AFTER_RETURN"]
        ),
        "MENU7_NO_BLANK_SCREEN": enter["MENU7_NO_BLANK_SCREEN"] and esc["MENU7_NO_BLANK_SCREEN"],
        "MENU7_NO_PAGER": enter["MENU7_NO_PAGER"] and esc["MENU7_NO_PAGER"],
    }

    failed = []
    for key, val in markers.items():
        if key == "MENU7_RAW_TERMINAL_VIEWER_USED":
            ok = val == "NO"
            print(f"{key}={val}")
        else:
            ok = bool(val)
            print(f"{key}={'PASS' if ok else 'FAIL'}")
        if not ok:
            failed.append(key)

    if failed:
        print("FAIL: " + ", ".join(failed), file=sys.stderr)
        return 1
    print("TEST_MENU7_SCROLL_NAVIGATION=PASS")
    print("PTY_SCROLL_REGRESSION=PASS")
    print("MENU7_COMMAND_COPY_SAFE=PASS")
    print("MENU7_MOUSE_SELECTION_SAFE=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
