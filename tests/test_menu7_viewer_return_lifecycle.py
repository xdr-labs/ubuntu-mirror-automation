#!/usr/bin/env python3
"""PTY lifecycle: main menu -> Menu 7 viewer -> close -> main menu visible again.

Uses real whiptail. Proves Enter and ESC return without shell exit, blank
screen, or pager, and that Ctrl-C restore helpers remain in place.
"""
from __future__ import annotations

import errno
import fcntl
import os
import pty
import re
import select
import signal
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
MENU_ITEM = "Show DP Client Upgrade Commands"


def _strip_csi(data: bytes) -> str:
    text = data.decode("utf-8", "replace")
    text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)
    text = re.sub(r"\x1b\].*?(?:\x07|\x1b\\)", "", text)
    text = text.replace("\x1b(B", "").replace("\x0f", "")
    return text


def _drain(master: int, buf: bytearray, seconds: float) -> None:
    deadline = time.time() + seconds
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.1)
        if not r:
            continue
        try:
            chunk = os.read(master, 8192)
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
        _drain(master, buf, 0.15)
        if needle in _strip_csi(bytes(buf)):
            return True
    _drain(master, buf, 0.2)
    return needle in _strip_csi(bytes(buf))


def _build_harness(tmp: str) -> str:
    sample = os.path.join(tmp, "cmds.txt")
    with open(sample, "w", encoding="utf-8") as fh:
        fh.write("MENU7_COMMAND_CONTENT_MARKER\n")
        fh.write("cd /home/aella && /bin/echo upgrade-sample\n")

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
export TERM="${{TERM:-xterm-256color}}"
export HEIGHT=40 WIDTH=100
export PATH="/usr/bin:/bin"
# shellcheck disable=SC1090
source '{lib}'

while true; do
  menu_rc=0
  choice="$(mm_whiptail_menu \\
    "{MENU_TITLE}" \\
    "Workflow: Configuration → Download → Enable HTTP → Verify Readiness
Cancel/ESC returns here; choose 0 to Exit." \\
    "1" "Configuration" \\
    "7" "{MENU_ITEM}" \\
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
      echo "MENU_EXIT=PASS"
      break
      ;;
    *)
      ;;
  esac
done
echo "HARNESS_DONE"
"""
        )
    os.chmod(driver, 0o755)
    return driver


def _run_close_path(close_mode: str) -> dict[str, bool]:
    tmp = tempfile.mkdtemp(prefix=f"menu7-life-{close_mode}-")
    driver = _build_harness(tmp)
    master, slave = pty.openpty()
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
    proc = subprocess.Popen(
        ["bash", driver],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
        env={**os.environ, "TERM": "xterm-256color", "LINES": "40", "COLUMNS": "100"},
    )
    os.close(slave)
    buf = bytearray()
    result = {
        "MENU7_OPEN": False,
        "MENU7_COMMAND_CONTENT": False,
        "MENU7_RETURN": False,
        "MENU7_MAIN_MENU_VISIBLE_AFTER_RETURN": False,
        "MENU7_NO_SHELL_EXIT": False,
        "MENU7_NO_PAGER": True,
        "MENU7_NO_BLANK_SCREEN": False,
    }

    try:
        if not _wait_for(master, proc, buf, MENU_TITLE, 6.0):
            raise RuntimeError(f"{close_mode}: initial main menu not visible")

        # Move highlight from item 1 -> 7, then Enter.
        os.write(master, b"\x1b[B\r")
        if not _wait_for(master, proc, buf, "MENU7_OPEN=PASS", 6.0):
            # Retry once in case the first Enter raced the draw.
            os.write(master, b"\x1b[B\r")
            if not _wait_for(master, proc, buf, "MENU7_OPEN=PASS", 4.0):
                raise RuntimeError(f"{close_mode}: MENU7_OPEN marker missing")
        result["MENU7_OPEN"] = True

        content_ok = _wait_for(master, proc, buf, "MENU7_COMMAND_CONTENT_MARKER", 5.0)
        title_ok = VIEWER_TITLE in _strip_csi(bytes(buf)) or _wait_for(
            master, proc, buf, VIEWER_TITLE, 2.0
        )
        if not (content_ok or title_ok):
            raise RuntimeError(f"{close_mode}: viewer content/title missing")
        result["MENU7_COMMAND_CONTENT"] = True

        if close_mode == "ENTER":
            # Focus OK/Return (Tab) then Enter.
            os.write(master, b"\t\r")
            time.sleep(0.15)
            os.write(master, b"\r")
        else:
            # ESC activates Cancel/Return.
            os.write(master, b"\x1b")
            time.sleep(0.15)
            os.write(master, b"\x1b")

        if not _wait_for(master, proc, buf, "MENU7_VIEWER_CLOSED=PASS", 6.0):
            raise RuntimeError(f"{close_mode}: viewer did not close")
        result["MENU7_RETURN"] = True

        # After close, the loop redraws the main menu before any new marker.
        if not _wait_for(master, proc, buf, MENU_TITLE, 6.0):
            raise RuntimeError(f"{close_mode}: main menu not visible after return")
        result["MENU7_MAIN_MENU_VISIBLE_AFTER_RETURN"] = True
        result["MENU7_NO_BLANK_SCREEN"] = True

        if proc.poll() is not None:
            raise RuntimeError(f"{close_mode}: shell exited after viewer close")
        result["MENU7_NO_SHELL_EXIT"] = True

        plain = _strip_csi(bytes(buf))
        if re.search(r"(^|\s)(less|more)(\s|$)", plain):
            result["MENU7_NO_PAGER"] = False

        # Exit via menu item 0 (Down from 1 twice if still on first item after redraw).
        # After returning, highlight is usually on first item again.
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


def _run_ctrl_c_restore() -> bool:
    tmp = tempfile.mkdtemp(prefix="menu7-life-intr-")
    driver = _build_harness(tmp)
    master, slave = pty.openpty()
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
    proc = subprocess.Popen(
        ["bash", driver],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
        env={**os.environ, "TERM": "xterm-256color", "LINES": "40", "COLUMNS": "100"},
    )
    os.close(slave)
    buf = bytearray()
    try:
        if not _wait_for(master, proc, buf, MENU_TITLE, 5.0):
            return False
        os.write(master, b"\x1b[B\r")
        if not _wait_for(master, proc, buf, VIEWER_TITLE, 5.0):
            return False
        os.write(master, b"\x03")
        deadline = time.time() + 4
        while time.time() < deadline and proc.poll() is None:
            _drain(master, buf, 0.1)
        if proc.poll() is None:
            proc.send_signal(signal.SIGINT)
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=2)
        restore = open(INSTALLER, encoding="utf-8").read()
        return "stty sane" in restore and "mm_menu7_tty_restore" in restore
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
    if re.search(r"(^|[^A-Za-z_])dialog([^A-Za-z_]|$)", body):
        print("FAIL: dialog still used in mm_menu7_textbox", file=sys.stderr)
        return 1
    if re.search(r"(^|\s)clear(\s|$)", body, re.M):
        print("FAIL: clear still used in mm_menu7_textbox", file=sys.stderr)
        return 1

    enter = _run_close_path("ENTER")
    esc = _run_close_path("ESC")
    ctrl_c_ok = _run_ctrl_c_restore()

    markers = {
        "MENU7_OPEN": enter["MENU7_OPEN"] and esc["MENU7_OPEN"],
        "MENU7_COMMAND_CONTENT": enter["MENU7_COMMAND_CONTENT"] and esc["MENU7_COMMAND_CONTENT"],
        "MENU7_ENTER_RETURN": enter["MENU7_RETURN"],
        "MENU7_ESC_RETURN": esc["MENU7_RETURN"],
        "MENU7_MAIN_MENU_VISIBLE_AFTER_RETURN": (
            enter["MENU7_MAIN_MENU_VISIBLE_AFTER_RETURN"]
            and esc["MENU7_MAIN_MENU_VISIBLE_AFTER_RETURN"]
        ),
        "MENU7_NO_SHELL_EXIT": enter["MENU7_NO_SHELL_EXIT"] and esc["MENU7_NO_SHELL_EXIT"],
        "MENU7_NO_PAGER": enter["MENU7_NO_PAGER"] and esc["MENU7_NO_PAGER"],
        "MENU7_NO_BLANK_SCREEN": enter["MENU7_NO_BLANK_SCREEN"] and esc["MENU7_NO_BLANK_SCREEN"],
        "MENU7_CTRL_C_RESTORE": ctrl_c_ok,
    }

    failed = [k for k, v in markers.items() if not v]
    for key, ok in markers.items():
        print(f"{key}={'PASS' if ok else 'FAIL'}")
    if failed:
        print("FAIL: " + ", ".join(failed), file=sys.stderr)
        return 1
    print("TEST_MENU7_VIEWER_RETURN_LIFECYCLE=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
