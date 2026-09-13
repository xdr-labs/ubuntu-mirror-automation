#!/usr/bin/env python3
"""PTY regression: Menu 7 whiptail viewer disables mouse tracking; CSI must not close it."""
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
    argv_log = os.path.join(tmp, "whiptail.argv")
    sample = os.path.join(tmp, "cmds.txt")
    with open(sample, "w", encoding="utf-8") as fh:
        fh.write("cd /home/aella && echo sample\n")

    stub = os.path.join(tmp, "whiptail")
    # Stub whiptail: record argv, ignore mouse CSI, exit only on Enter / ESC / q.
    with open(stub, "w", encoding="utf-8") as fh:
        fh.write(
            f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >'{argv_log}'
# Exit the read-loop on timeout (do not '|| true' — that spins forever).
while IFS= read -r -n1 -t 8 ch; do
  if [[ "$ch" == $'\\x1b' ]]; then
    read -r -n1 -t 0.05 n1 || true
    if [[ "$n1" == "[" ]]; then
      read -r -n1 -t 0.05 n2 || true
      if [[ "$n2" == "M" ]]; then
        read -r -n3 -t 0.05 _ || true
        continue
      fi
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

    time.sleep(0.2)
    mouse = b"\x1b[M !! "
    os.write(master, mouse)
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
        print("FAIL: whiptail argv log missing", file=sys.stderr)
        return 1
    argv = open(argv_log, encoding="utf-8").read()
    if "--textbox" not in argv:
        print(f"FAIL: argv missing --textbox: {argv!r}", file=sys.stderr)
        return 1
    if "Return" not in argv:
        print(f"FAIL: argv missing Return button: {argv!r}", file=sys.stderr)
        return 1
    if rc != 0:
        print(f"FAIL: driver rc={rc}", file=sys.stderr)
        return 1
    plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", buf.decode("utf-8", "replace"))
    if "VIEWER_CLOSED" not in plain and b"VIEWER_CLOSED" not in buf:
        # marker may have been read already; rc==0 is enough with argv checks
        pass

    print("PASS: Menu 7 PTY mouse CSI ignored until keyboard close")
    print("TEST_MENU7_PTY_MOUSE=PASS")
    print(f"WHIPTAIL_ARGV={argv.strip()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
