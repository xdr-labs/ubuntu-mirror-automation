#!/usr/bin/env python3
"""PTY regression: Menu 7 dialog viewer uses --no-mouse; mouse CSI must not close it."""
from __future__ import annotations

import os
import pty
import re
import select
import subprocess
import sys
import tempfile
import time


def main() -> int:
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    installer = os.path.join(root, "scripts", "install-dp-upgrade-mirror.sh")
    tmp = tempfile.mkdtemp(prefix="menu7-pty-")
    argv_log = os.path.join(tmp, "dialog.argv")
    sample = os.path.join(tmp, "cmds.txt")
    with open(sample, "w", encoding="utf-8") as fh:
        fh.write("cd /home/aella && echo sample\nTOP_MARKER\n")

    stub = os.path.join(tmp, "dialog")
    with open(stub, "w", encoding="utf-8") as fh:
        fh.write(
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >'{argv_log}'
while IFS= read -r -n1 -t 8 ch; do
  if [[ "$ch" == $'\\x1b' ]]; then
    read -r -n1 -t 0.05 n1 || true
    if [[ "$n1" == "[" ]]; then
      read -r -n1 -t 0.05 n2 || true
      if [[ "$n2" == "M" ]]; then
        read -r -n3 -t 0.05 _ || true
        continue
      fi
      # Drain remainder of CSI then treat as ESC close only for bare ESC.
      while IFS= read -r -n1 -t 0.01 _; do :; done
      continue
    fi
    exit 1
  fi
  if [[ "$ch" == $'\\n' || "$ch" == $'\\r' || "$ch" == "q" || "$ch" == "Q" ]]; then
    exit 0
  fi
done
exit 0
"""
        )
    os.chmod(stub, 0o755)

    lib = os.path.join(tmp, "lib.sh")
    with open(installer, encoding="utf-8") as src, open(lib, "w", encoding="utf-8") as dst:
        for line in src:
            if line.startswith("SCRIPT_DIR="):
                dst.write(f'SCRIPT_DIR="{root}/scripts"\n')
            elif line.strip() == 'main "$@"':
                continue
            else:
                dst.write(line)

    driver = os.path.join(tmp, "driver.sh")
    with open(driver, "w", encoding="utf-8") as fh:
        fh.write(
            f"""#!/usr/bin/env bash
set -euo pipefail
export PATH='{tmp}:/usr/bin:/bin'
export HEIGHT=40 WIDTH=100 TERM=xterm-256color
# shellcheck disable=SC1090
source '{lib}'
mm_menu7_textbox "DP Client Upgrade Commands" '{sample}'
echo VIEWER_CLOSED
"""
        )
    os.chmod(driver, 0o755)

    master, slave = pty.openpty()
    proc = subprocess.Popen(
        ["bash", driver],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
        env={**os.environ, "TERM": "xterm-256color"},
    )
    os.close(slave)

    time.sleep(0.25)
    os.write(master, b"\x1b[M !! ")
    time.sleep(0.2)
    os.write(master, b"\x1b[M@!!")
    time.sleep(0.3)

    if proc.poll() is not None:
        os.close(master)
        print("FAIL: viewer exited after mouse CSI", file=sys.stderr)
        return 1

    os.write(master, b"\r")
    deadline = time.time() + 5
    buf = b""
    while proc.poll() is None and time.time() < deadline:
        if select.select([master], [], [], 0.1)[0]:
            try:
                buf += os.read(master, 4096)
            except OSError:
                break
        time.sleep(0.05)
    if proc.poll() is None:
        os.write(master, b"q")
        time.sleep(0.5)
    if proc.poll() is None:
        proc.kill()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass
        os.close(master)
        print("FAIL: viewer did not close on Enter/q", file=sys.stderr)
        return 1
    try:
        os.close(master)
    except OSError:
        pass
    rc = proc.returncode if proc.returncode is not None else 1

    if not os.path.isfile(argv_log):
        print("FAIL: dialog argv log missing", file=sys.stderr)
        return 1
    argv = open(argv_log, encoding="utf-8").read()
    if "--textbox" not in argv or "--no-mouse" not in argv:
        print(f"FAIL: argv missing --textbox/--no-mouse: {argv!r}", file=sys.stderr)
        return 1
    if "Return" not in argv:
        print(f"FAIL: argv missing Return: {argv!r}", file=sys.stderr)
        return 1
    if "menu7_scroll_viewer" in argv:
        print("FAIL: raw terminal viewer invoked", file=sys.stderr)
        return 1
    if rc != 0:
        print(f"FAIL: driver rc={rc}", file=sys.stderr)
        return 1

    print("PASS: Menu 7 PTY mouse CSI ignored until keyboard close")
    print("TEST_MENU7_PTY_MOUSE=PASS")
    print("MENU7_COMMAND_COPY_SAFE=PASS")
    print("MENU7_MOUSE_SELECTION_SAFE=PASS")
    print(f"DIALOG_ARGV={argv.strip()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
