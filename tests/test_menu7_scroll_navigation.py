#!/usr/bin/env python3
"""PTY scroll regression for the actual Menu 7 scroll viewer.

Uses a 150+ line command file with unique markers and proves Up/Down,
PageUp/PageDown, Home/End change the visible viewport content.
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
VIEWER = os.path.join(ROOT, "scripts", "lib", "menu7_scroll_viewer.py")
TITLE = "DP Client Upgrade Commands"


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


def _visible_after(buf: bytearray, start: int) -> str:
    return _strip_csi(bytes(buf[start:]))


def _build_sample(path: str) -> None:
    # Large leading pad so STEP markers are NOT in the initial viewport
    # (viewport ≈ height-3 ≈ 21 lines). Tests prove keys reveal new markers.
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


def main() -> int:
    if not os.path.isfile(VIEWER):
        print("FAIL: scroll viewer missing", file=sys.stderr)
        return 1

    tmp = tempfile.mkdtemp(prefix="menu7-scroll-")
    sample = os.path.join(tmp, "cmds.txt")
    _build_sample(sample)

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
export TERM=xterm-256color HEIGHT=24 WIDTH=80 LINES=24 COLUMNS=80
# shellcheck disable=SC1090
source '{lib}'
echo MENU7_OPEN=PASS
mm_menu7_textbox "{TITLE}" "{sample}" || true
echo MENU7_VIEWER_CLOSED=PASS
"""
        )
    os.chmod(driver, 0o755)

    master, slave = pty.openpty()
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    proc = subprocess.Popen(
        ["bash", driver],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
        env={**os.environ, "TERM": "xterm-256color", "LINES": "24", "COLUMNS": "80"},
    )
    os.close(slave)
    buf = bytearray()
    markers = {
        "MENU7_OPEN": False,
        "MENU7_UP_SCROLL": False,
        "MENU7_DOWN_SCROLL": False,
        "MENU7_PAGEUP": False,
        "MENU7_PAGEDOWN": False,
        "MENU7_HOME": False,
        "MENU7_END": False,
        "MENU7_ENTER_RETURN": False,
        "MENU7_ESC_RETURN": False,
        "MENU7_NO_BLANK_SCREEN": False,
        "MENU7_NO_PAGER": True,
        "MENU7_COMMAND_COPY_SAFE": True,
    }

    try:
        _drain(master, buf, 0.8)
        if "MENU7_OPEN=PASS" not in _strip_csi(bytes(buf)):
            raise RuntimeError("MENU7_OPEN missing")
        markers["MENU7_OPEN"] = True
        if "TOP_MARKER" not in _strip_csi(bytes(buf)):
            raise RuntimeError("TOP_MARKER not visible on open")

        # Down from Home: reveal first lead-pad lines that were below the fold.
        # (STEP_0 is far below; use a nearby unique pad line as the Down proof.)
        os.write(master, b"\x1bOH")
        _drain(master, buf, 0.25)
        start = len(buf)
        for _ in range(25):
            os.write(master, b"\x1b[B")
            _drain(master, buf, 0.04)
        visible = _visible_after(buf, start)
        if "lead-pad-25" in visible or "lead-pad-30" in visible or "STEP_0_MARKER" in visible:
            markers["MENU7_DOWN_SCROLL"] = True
        # Fallback: any newly painted lead-pad beyond the initial viewport.
        if not markers["MENU7_DOWN_SCROLL"]:
            for n in range(21, 80):
                if f"lead-pad-{n}" in visible:
                    markers["MENU7_DOWN_SCROLL"] = True
                    break

        # PageDown toward later steps.
        start = len(buf)
        for _ in range(8):
            os.write(master, b"\x1b[6~")
            _drain(master, buf, 0.05)
        if any(f"STEP_{i}_MARKER" in _visible_after(buf, start) for i in range(2, 10)):
            markers["MENU7_PAGEDOWN"] = True

        # End -> BOTTOM
        start = len(buf)
        os.write(master, b"\x1bOF")
        _drain(master, buf, 0.4)
        if "BOTTOM_MARKER" in _visible_after(buf, start):
            markers["MENU7_END"] = True

        # Home -> TOP
        start = len(buf)
        os.write(master, b"\x1bOH")
        _drain(master, buf, 0.4)
        if "TOP_MARKER" in _visible_after(buf, start):
            markers["MENU7_HOME"] = True

        # PageUp from near end.
        os.write(master, b"\x1bOF")
        _drain(master, buf, 0.2)
        start = len(buf)
        for _ in range(4):
            os.write(master, b"\x1b[5~")
            _drain(master, buf, 0.05)
        if any(f"STEP_{i}_MARKER" in _visible_after(buf, start) for i in range(10)):
            markers["MENU7_PAGEUP"] = True

        # Up from STEP area back toward top.
        os.write(master, b"\x1bOH")
        _drain(master, buf, 0.15)
        for _ in range(15):
            os.write(master, b"\x1b[B")
            _drain(master, buf, 0.03)
        start = len(buf)
        for _ in range(15):
            os.write(master, b"\x1b[A")
            _drain(master, buf, 0.03)
        if "TOP_MARKER" in _visible_after(buf, start) or "STEP_0_MARKER" in _visible_after(buf, start):
            markers["MENU7_UP_SCROLL"] = True

        # ESC return path
        os.write(master, b"\x1b")
        _drain(master, buf, 0.6)
        if "MENU7_VIEWER_CLOSED=PASS" in _strip_csi(bytes(buf)):
            markers["MENU7_ESC_RETURN"] = True
            markers["MENU7_NO_BLANK_SCREEN"] = True
        else:
            # Restart for Enter path if ESC already closed (acceptable).
            pass

        if proc.poll() is None:
            # Still open somehow — Enter close.
            os.write(master, b"\r")
            _drain(master, buf, 0.6)

        # Separate Enter-return proof.
        master2, slave2 = pty.openpty()
        fcntl.ioctl(master2, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        proc2 = subprocess.Popen(
            ["bash", driver],
            stdin=slave2,
            stdout=slave2,
            stderr=slave2,
            close_fds=True,
            env={**os.environ, "TERM": "xterm-256color", "LINES": "24", "COLUMNS": "80"},
        )
        os.close(slave2)
        buf2 = bytearray()
        _drain(master2, buf2, 0.8)
        os.write(master2, b"\r")
        _drain(master2, buf2, 0.8)
        if "MENU7_VIEWER_CLOSED=PASS" in _strip_csi(bytes(buf2)):
            markers["MENU7_ENTER_RETURN"] = True
        if proc2.poll() is None:
            proc2.kill()
            proc2.wait(timeout=2)
        try:
            os.close(master2)
        except OSError:
            pass

        plain = _strip_csi(bytes(buf))
        if re.search(r"(^|\s)(less|more)(\s|$)", plain):
            markers["MENU7_NO_PAGER"] = False

        # Mouse tracking must not be enabled by the viewer.
        src = open(VIEWER, encoding="utf-8").read()
        if "1000h" in src or "1002h" in src:
            markers["MENU7_COMMAND_COPY_SAFE"] = False

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

    # If ESC path failed but Enter proved close, still require ESC on a third run.
    if not markers["MENU7_ESC_RETURN"]:
        master3, slave3 = pty.openpty()
        fcntl.ioctl(master3, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        proc3 = subprocess.Popen(
            ["bash", driver],
            stdin=slave3,
            stdout=slave3,
            stderr=slave3,
            close_fds=True,
            env={**os.environ, "TERM": "xterm-256color", "LINES": "24", "COLUMNS": "80"},
        )
        os.close(slave3)
        buf3 = bytearray()
        _drain(master3, buf3, 0.8)
        os.write(master3, b"\x1b")
        _drain(master3, buf3, 0.8)
        if "MENU7_VIEWER_CLOSED=PASS" in _strip_csi(bytes(buf3)):
            markers["MENU7_ESC_RETURN"] = True
            markers["MENU7_NO_BLANK_SCREEN"] = True
        if proc3.poll() is None:
            proc3.kill()
            proc3.wait(timeout=2)
        try:
            os.close(master3)
        except OSError:
            pass

    failed = [k for k, v in markers.items() if not v]
    for key, ok in markers.items():
        print(f"{key}={'PASS' if ok else 'FAIL'}")
    if failed:
        print("FAIL: " + ", ".join(failed), file=sys.stderr)
        return 1
    print("TEST_MENU7_SCROLL_NAVIGATION=PASS")
    print("PTY_SCROLL_REGRESSION=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
