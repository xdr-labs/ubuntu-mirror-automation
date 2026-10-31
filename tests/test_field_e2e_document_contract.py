#!/usr/bin/env python3
"""Keep operator E2E instructions linked and aligned with real Menu 7 flows.

Static documentation contract only: it does not claim actual mirror/DP E2E.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
english = ROOT / "docs/DP_FIELD_E2E_6_6_0.md"
korean = ROOT / "docs/DP_FIELD_E2E_6_6_0.ko.md"
mirror = (ROOT / "docs/deployment/DP_UPGRADE_MIRROR_MANAGER.md").read_text()
readme_en = (ROOT / "README.md").read_text()
readme_kr = (ROOT / "README.ko.md").read_text()
menu = (ROOT / "scripts/install-dp-upgrade-mirror.sh").read_text()
for path in (english, korean):
    assert path.is_file(), path
    text = path.read_text(encoding="utf-8")
    assert "PHASE2_ONLY" in text, path
    assert "FULL" in text, path
    assert "Menu 7" in text, path
    assert "Menu 4" in text, path
    assert "6.6.0" in text, path
    assert "DP_CLUSTER_UPGRADE_COMPLETE" in text, path
    assert "xdr-labs/ubuntu-mirror-automation" in text, path
    assert "RickLee-kr" not in text, path

assert "docs/DP_FIELD_E2E_6_6_0.md" in readme_en
assert "docs/DP_FIELD_E2E_6_6_0.ko.md" in readme_kr
assert "../DP_FIELD_E2E_6_6_0.md" in mirror
assert "github.com/xdr-labs/ubuntu-mirror-automation.git" in mirror
assert "RickLee-kr/ubuntu-mirror-automation" not in mirror

assert "gui_phase2_prerequisite_command_line()" in menu
assert "gui_cluster_bringup_command_line()" in menu
assert "--worker-ips" in menu and "--prompt-worker-password" in menu
assert "STEP 0 — DP PRECHECK" in menu
assert "STEP 10 — VERIFY DP HEALTH" in menu
assert "STEP 7 — VERIFY DP HEALTH" in menu
assert "mm_client_commands_file" in menu
assert "legacy" in (ROOT / "docs/operations.md").read_text().lower()
print("FIELD_E2E_RUNBOOK_CONTRACT=PASS")
