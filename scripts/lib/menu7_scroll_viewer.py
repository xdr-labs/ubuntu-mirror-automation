#!/usr/bin/env python3
"""Menu 7 command-file scroll viewer for Mirror Manager SSH sessions.

Plain-terminal viewport (no newt/dialog textbox). Mouse tracking is never
enabled so SSH clients keep native click/drag copy selection. Keyboard:

  Up / Down / PageUp / PageDown / Home / End  — scroll
  Enter / ESC / q                            — return to caller

Does not invoke a pager. Exits 0 on normal return.
"""
from __future__ import annotations

import argparse
import os
import select
import sys
import termios
import tty


def _read_key(fd: int) -> str:
    """Read one logical key. Unknown CSI (including mouse) is ignored as OTHER.

    Bare ESC (no follow-on bytes within a short window) returns ESC.
    """
    ch = os.read(fd, 1).decode("utf-8", "replace")
    if not ch:
        return "ESC"
    if ch in ("\n", "\r"):
        return "ENTER"
    if ch in ("q", "Q"):
        return "QUIT"
    if ch != "\x1b":
        return "OTHER"

    # Collect the rest of an escape sequence without treating mouse CSI as ESC.
    rest = ""
    while select.select([fd], [], [], 0.05)[0]:
        nxt = os.read(fd, 1).decode("utf-8", "replace")
        if not nxt:
            break
        rest += nxt
        # xterm mouse tracking: ESC [ M Cb Cx Cy  (3 bytes after M)
        if rest.startswith("[M"):
            while len(rest) < 5 and select.select([fd], [], [], 0.05)[0]:
                more = os.read(fd, 1).decode("utf-8", "replace")
                if not more:
                    break
                rest += more
            return "OTHER"
        # SGR mouse: ESC [ < ... M/m
        if rest.startswith("[<"):
            while select.select([fd], [], [], 0.05)[0]:
                more = os.read(fd, 1).decode("utf-8", "replace")
                if not more:
                    break
                rest += more
                if more in ("M", "m") or len(rest) > 32:
                    break
            return "OTHER"
        if rest.startswith("[") and rest[-1].isalpha():
            break
        if rest.startswith("O") and len(rest) >= 2:
            break
        if rest.startswith("[") and rest[-1] == "~":
            break
        if len(rest) > 8:
            break

    if rest == "":
        return "ESC"
    if rest in ("[A",):
        return "UP"
    if rest in ("[B",):
        return "DOWN"
    if rest in ("[5~",):
        return "PGUP"
    if rest in ("[6~",):
        return "PGDN"
    if rest in ("[H", "[1~", "OH"):
        return "HOME"
    if rest in ("[F", "[4~", "OF"):
        return "END"
    # Unknown escape sequence: ignore (do not close the viewer).
    return "OTHER"


def _paint(title: str, lines: list[str], top: int, height: int, width: int) -> None:
    view_h = max(3, height - 3)
    total = max(1, len(lines))
    if not lines:
        lines = [""]
    top = max(0, min(top, max(0, total - 1)))
    bottom = min(total, top + view_h)
    # Home + clear screen for in-viewer redraw only.
    sys.stdout.write("\033[H\033[2J")
    hdr = title[: max(1, width - 1)]
    sys.stdout.write(hdr + "\n")
    sys.stdout.write("-" * min(width, max(8, len(hdr))) + "\n")
    for i in range(top, bottom):
        row = lines[i]
        if len(row) > width - 1:
            row = row[: width - 1]
        sys.stdout.write(row + "\n")
    for _ in range(view_h - (bottom - top)):
        sys.stdout.write("\n")
    footer = (
        f"Lines {top + 1}-{bottom} of {total} | "
        f"Up/Down PgUp/PgDn Home/End | Enter/ESC=Return"
    )
    sys.stdout.write(footer[: max(1, width - 1)] + "\n")
    sys.stdout.flush()


def main() -> int:
    ap = argparse.ArgumentParser(description="Menu 7 scrollable command viewer")
    ap.add_argument("--title", required=True)
    ap.add_argument("--file", required=True)
    ap.add_argument("--height", type=int, default=0)
    ap.add_argument("--width", type=int, default=0)
    args = ap.parse_args()

    if not os.path.isfile(args.file):
        print(f"MENU7_VIEWER=FAIL reason=file_missing path={args.file}", file=sys.stderr)
        return 1

    with open(args.file, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()

    height = args.height or int(os.environ.get("LINES", "24") or "24")
    width = args.width or int(os.environ.get("COLUMNS", "80") or "80")
    height = max(12, height)
    width = max(40, width)

    if not sys.stdin.isatty() or not sys.stdout.isatty():
        sys.stdout.write(f"{args.title}\n")
        sys.stdout.write("\n".join(lines) + "\n")
        return 0

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    top = 0
    view_h = max(3, height - 3)
    max_top = max(0, len(lines) - view_h)
    try:
        tty.setcbreak(fd)
        sys.stdout.write("\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1015l")
        sys.stdout.flush()
        while True:
            _paint(args.title, lines, top, height, width)
            key = _read_key(fd)
            if key in ("ENTER", "ESC", "QUIT"):
                break
            if key == "UP":
                top = max(0, top - 1)
            elif key == "DOWN":
                top = min(max_top, top + 1)
            elif key == "PGUP":
                top = max(0, top - view_h)
            elif key == "PGDN":
                top = min(max_top, top + view_h)
            elif key == "HOME":
                top = 0
            elif key == "END":
                top = max_top
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        sys.stdout.write("\033[?25h\033[0m")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
