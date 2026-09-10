#!/usr/bin/env python3
"""Render offline-upgrade .sh.in templates for fixture tests.

Injects shared client/lib helpers at their template tokens before leftover pin
stubbing so stubs remain valid single-file bash scripts.
"""
from __future__ import print_function

import argparse
import json
import re
import sys
from pathlib import Path

HELPERS = (
    ("@@HERMETIC_ESCAPES_HELPER@@", "dp-offline-hermetic-escapes.sh"),
    ("@@DESTRUCTIVE_CONFIRMATION_HELPER@@", "dp-offline-destructive-confirmation.sh"),
    ("@@RELEASE_UPGRADE_RECONCILIATION_HELPER@@", "dp-offline-release-upgrade-reconciliation.sh"),
    ("@@APT_PREFLIGHT_SANDBOX_HELPER@@", "dp-offline-apt-preflight-sandbox.sh"),
    ("@@DURABLE_WRITE_HELPER@@", "dp-offline-durable-write.sh"),
    ("@@SOURCE_PRODUCT_HELPER@@", "dp-offline-source-product-version.sh"),
    ("@@LXD_INVENTORY_HELPER@@", "dp-offline-lxd-inventory.sh"),
)


def load_helper(template_path, helper_name):
    helper_path = template_path.resolve().parent / "lib" / helper_name
    if not helper_path.is_file():
        raise SystemExit("missing helper {}: {}".format(helper_name, helper_path))
    return helper_path.read_text(encoding="utf-8").rstrip("\n") + "\n"


def expand_helper_tokens(text, template_path, require_present=False):
    """Replace shared @@*_HELPER@@ tokens. Pin tokens (@@MIRROR_BASE@@ etc.) stay."""
    template_path = Path(template_path)
    for token, helper_name in HELPERS:
        if token not in text:
            if require_present and token != "@@LXD_INVENTORY_HELPER@@":
                raise SystemExit(
                    "template missing {}: {}".format(token, template_path)
                )
            continue
        text = text.replace(token, load_helper(template_path, helper_name))
    return text


def render_template(template_path, pins, leftover="stub"):
    text = template_path.read_text(encoding="utf-8")
    text = expand_helper_tokens(text, template_path, require_present=True)
    for key, val in pins.items():
        token = "@@{}@@".format(key)
        text = text.replace(token, val)
    text = re.sub(r"@@[A-Z0-9_]+@@", leftover, text)
    return text


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("template")
    ap.add_argument("output")
    ap.add_argument(
        "--pins-json",
        default="",
        help="JSON object of pin replacements (@@KEY@@)",
    )
    ap.add_argument(
        "--leftover",
        default="stub",
        help="replacement for any remaining @@TOKEN@@ (default: stub)",
    )
    ap.add_argument(
        "--helpers-only",
        action="store_true",
        help="expand shared helper tokens only; leave pin tokens intact",
    )
    args = ap.parse_args(argv)

    template_path = Path(args.template)
    if args.helpers_only:
        body = expand_helper_tokens(
            template_path.read_text(encoding="utf-8"),
            template_path,
            require_present=True,
        )
    else:
        pins = {}
        if args.pins_json:
            pins = json.loads(args.pins_json)
            if not isinstance(pins, dict):
                raise SystemExit("--pins-json must be a JSON object")
        body = render_template(template_path, pins, leftover=args.leftover)
    out = Path(args.output)
    out.write_text(body, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
