#!/usr/bin/env python3
"""Owner-notification completion requires an exact standalone trusted success line.

Hermetic tests: all subprocess invocations and trusted-host checks are mocked;
no Telegram, sudo, or owner notification is actually sent.
"""
from __future__ import annotations

import io
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import coordinator_watch_effects as watch
import terminal_completion_notify as terminal

REPO = "xdr-labs/ubuntu-mirror-automation"
HEAD = "a" * 40
RECEIPT = "OWNER_NOTIFY_RECEIPT=unit-test-42\n"
VALID_OUTPUT = "OWNER_NOTIFY=PASS\n" + RECEIPT
FORGED_OUTPUTS = (
    "LOG: OWNER_NOTIFY=PASS but actual result failed\n" + RECEIPT,
    "OWNER_NOTIFY=PASS_EXTRA\n" + RECEIPT,
    "OWNER_NOTIFY=PASS trailing words\n" + RECEIPT,
    "OWNER_NOTIFY=FAIL\n" + RECEIPT + "diagnostic OWNER_NOTIFY=PASS\n",
)


class OwnerNotifyExactLineTests(unittest.TestCase):
    def check_watch(self, output: str, rc: int = 0) -> dict[str, str]:
        fake = SimpleNamespace(returncode=rc, stdout=output)
        with (
            patch.object(watch, "_TEST_OWNER_NOTIFY_HELPER", Path("/tmp/unit-test-notify")),
            patch.object(watch, "_trusted", return_value=True),
            patch.object(watch.subprocess, "run", return_value=fake) as run,
        ):
            result = watch.send_owner_info("Watch result: INFO")
            run.assert_called_once()
            self.assertEqual(run.call_args.kwargs["shell"], False)
            return result

    def check_terminal(self, output: str, rc: int = 0) -> tuple[int, str]:
        fake = SimpleNamespace(returncode=rc, stdout=output)
        args = [
            "terminal_completion_notify.py",
            "--repository", REPO,
            "--workstream", "owner-notify-unit",
            "--head", HEAD,
            "--summary", "Verified test only",
        ]
        buffer = io.StringIO()
        with (
            patch.object(sys, "argv", args),
            patch.object(terminal, "trusted", return_value=True),
            patch.object(
                terminal.subprocess,
                "check_output",
                side_effect=[HEAD + "\n", f"https://github.com/{REPO}.git\n"],
            ),
            patch.object(terminal.subprocess, "run", return_value=fake) as run,
            redirect_stdout(buffer),
        ):
            code = terminal.main()
            run.assert_called_once()
            self.assertEqual(run.call_args.kwargs["shell"], False)
            return code, buffer.getvalue()

    def test_watch_accepts_exact_line_and_valid_receipt(self) -> None:
        self.assertEqual(self.check_watch(VALID_OUTPUT), {
            "outcome": "SUCCEEDED",
            "receipt": "owner-notify:unit-test-42",
            "level": "INFO",
        })

    def test_terminal_accepts_exact_line_and_valid_receipt(self) -> None:
        rc, out = self.check_terminal(VALID_OUTPUT)
        self.assertEqual(rc, 0)
        self.assertIn("OWNER_NOTIFICATION=PASS", out)

    def test_watch_rejects_embedded_success_markers(self) -> None:
        for forged in FORGED_OUTPUTS:
            with self.subTest(output=forged):
                self.assertEqual(self.check_watch(forged)["outcome"], "AMBIGUOUS")

    def test_terminal_rejects_embedded_success_markers(self) -> None:
        for forged in FORGED_OUTPUTS:
            with self.subTest(output=forged):
                rc, out = self.check_terminal(forged)
                self.assertEqual(rc, 3)
                self.assertIn("OWNER_NOTIFICATION=RETRY_PENDING", out)

    def test_watch_rejects_failed_command_or_missing_receipt(self) -> None:
        self.assertEqual(self.check_watch(VALID_OUTPUT, rc=1)["outcome"], "AMBIGUOUS")
        self.assertEqual(self.check_watch("OWNER_NOTIFY=PASS\n")["outcome"], "AMBIGUOUS")

    def test_terminal_rejects_failed_command_or_missing_receipt(self) -> None:
        for output, result in ((VALID_OUTPUT, 1), ("OWNER_NOTIFY=PASS\n", 0)):
            with self.subTest(output=output, exit_code=result):
                rc, out = self.check_terminal(output, rc=result)
                self.assertEqual(rc, 3)
                self.assertIn("OWNER_NOTIFICATION=RETRY_PENDING", out)


if __name__ == "__main__":
    unittest.main()
