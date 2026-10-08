#!/usr/bin/env python3
"""Owner notification watcher requires an exact standalone trusted success line.

Hermetic tests: watcher subprocess invocations and trusted-host checks are mocked;
no Telegram, sudo, or owner notification is actually sent.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import coordinator_watch_effects as watch

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

    def test_watch_accepts_exact_line_and_valid_receipt(self) -> None:
        self.assertEqual(self.check_watch(VALID_OUTPUT), {
            "outcome": "SUCCEEDED",
            "receipt": "owner-notify:unit-test-42",
            "level": "INFO",
        })

    def test_watch_rejects_embedded_success_markers(self) -> None:
        for forged in FORGED_OUTPUTS:
            with self.subTest(output=forged):
                self.assertEqual(self.check_watch(forged)["outcome"], "AMBIGUOUS")

    def test_watch_rejects_failed_command_or_missing_receipt(self) -> None:
        self.assertEqual(self.check_watch(VALID_OUTPUT, rc=1)["outcome"], "AMBIGUOUS")
        self.assertEqual(self.check_watch("OWNER_NOTIFY=PASS\n")["outcome"], "AMBIGUOUS")



if __name__ == "__main__":
    unittest.main()
