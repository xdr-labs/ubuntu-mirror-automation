#!/usr/bin/env python3
"""Regression: Phase 1 log monitors do not join half-written lines to heartbeats.

Runs only extracted, read-only monitor helpers against temporary fixture logs.
No DP, mirror, systemd, or package transactions are invoked.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOPS = (
    "xenial-to-bionic",
    "bionic-to-focal",
    "focal-to-jammy",
    "jammy-to-noble",
)


def function_source(text, name):
    head = name + "() {\n"
    start = text.index(head)
    end = text.index("\n}\n", start) + len("\n}")
    return text[start:end] + "\n"


class MonitorCompleteLineTests(unittest.TestCase):
    def test_template_and_checked_in_client_monitor_match(self):
        for hop in HOPS:
            with self.subTest(hop=hop):
                prefix = ROOT / "client" / ("dp-offline-upgrade-" + hop)
                template = Path(str(prefix) + ".sh.in").read_text(encoding="utf-8")
                generated = Path(str(prefix) + ".sh").read_text(encoding="utf-8")
                for func in ("monitor_emit_new_log_bytes", "monitor_print_recent_log"):
                    self.assertEqual(
                        function_source(template, func),
                        function_source(generated, func),
                    )
                self.assertIn('monitor_print_recent_log "$logf" "$recent"', template)
                self.assertIn('monitor_print_recent_log "$logf" "$recent"', generated)

    def test_no_partial_line_or_heartbeat_interleaving_all_hops(self):
        for hop in HOPS:
            with self.subTest(hop=hop), tempfile.TemporaryDirectory() as temp:
                text = (ROOT / "client" / ("dp-offline-upgrade-" + hop + ".sh.in")).read_text()
                helpers = Path(temp) / "helpers.sh"
                helpers.write_text(
                    function_source(text, "monitor_emit_new_log_bytes")
                    + function_source(text, "monitor_print_recent_log")
                )
                log = Path(temp) / "offline_os_upgrade.log"
                script = r"""
set -euo pipefail
source "$1"
log="$2"
printf 'HIST1\nHIST2\nstaging' >"$log"
printf '%s\n' '==RECENT=='
monitor_print_recent_log "$log" 2
[[ "$MONITOR_ATTACH_LOG_OFFSET" -eq "$(wc -c < "$log")" ]]
printf '%s\n' '==PARTIAL=='
monitor_emit_new_log_bytes "$log"
printf '%s\n' '==COMPLETE=='
printf 'done\nUTF8-한글' >>"$log"
monitor_emit_new_log_bytes "$log"
printf '%s\n' '2026-10-10T06:51:07Z [PROGRESS] state=RUNNING'
printf '%s\n' '==MORE=='
printf '완료\n' >>"$log"
monitor_emit_new_log_bytes "$log"
printf '%s\n' '==TRUNCATED=='
printf 'new\n' >"$log"
monitor_emit_new_log_bytes "$log"
printf 'OFFSET=%s\n' "$MONITOR_LOG_OFFSET"
"""
                run = subprocess.run(
                    ["bash", "-c", script, "test", str(helpers), str(log)],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                expected = (
                    "==RECENT==\nHIST1\nHIST2\n"
                    "==PARTIAL==\n==COMPLETE==\nstagingdone\n"
                    "2026-10-10T06:51:07Z [PROGRESS] state=RUNNING\n"
                    "==MORE==\nUTF8-한글완료\n"
                    "==TRUNCATED==\nnew\nOFFSET=4\n"
                )
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual(run.stdout, expected)


if __name__ == "__main__":
    unittest.main()
