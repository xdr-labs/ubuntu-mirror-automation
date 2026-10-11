#!/usr/bin/env python3
"""Fail-closed read-only URL integrity for decoded client pin payloads.

Do not execute client code. Meta-release transport URLs are local Mirror
sources; manifest checks only mirror-bearing keys so unrelated provenance
metadata is not incorrectly classified as a download origin.
"""
import json
import re
import sys

META_SOURCE_KEYS = ("Release-File", "UpgradeTool", "UpgradeToolSignature")
URL_RE = re.compile(r"""https?://[^\s"'<>;()]+""")


def pinned(value, expected):
    return isinstance(value, str) and value.startswith(expected + "/")


def check_meta(text, expected):
    if "@MIRROR_BASE@" in text:
        return False
    urls = URL_RE.findall(text)
    if not urls or any(not pinned(url, expected) for url in urls):
        return False
    for line in text.splitlines():
        key, separator, value = line.partition(":")
        if separator and key.strip() in META_SOURCE_KEYS:
            if not pinned(value.strip(), expected):
                return False
    return True


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate manifest JSON key")
        result[key] = value
    return result


def check_manifest(text, expected):
    try:
        data = json.loads(text, object_pairs_hook=unique_keys)
    except (ValueError, TypeError):
        return False
    if not isinstance(data, dict) or data.get("mirror_base") != expected:
        return False
    for key in ("sample_deb_url", "release_file_url", "upgrade_tool_url",
                "upgrade_tool_signature_url"):
        if key in data and not pinned(data[key], expected):
            return False
    return True


def main():
    if len(sys.argv) != 3:
        return 1
    mode, expected = sys.argv[1:]
    expected = expected.rstrip("/")
    if not expected.startswith(("http://", "https://")):
        return 1
    text = sys.stdin.read()
    if mode == "meta":
        return 0 if check_meta(text, expected) else 1
    if mode == "manifest":
        return 0 if check_manifest(text, expected) else 1
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, UnicodeError):
        sys.exit(1)
