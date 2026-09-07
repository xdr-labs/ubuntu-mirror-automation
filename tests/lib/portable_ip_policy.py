#!/usr/bin/env python3
"""Minimal portable-IP policy scanner for Mirror Manager / Menu 7 / client output.

Allowed:
  - RFC 5737: 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24
  - loopback/bind: 127.0.0.0/8, 0.0.0.0
  - broadcast/netmask sentinel: 255.255.255.255
  - explicitly justified public DNS/NTP service addresses

Rejected: environment-specific RFC1918 or other public IP literals.
"""
from __future__ import annotations

import argparse
import ipaddress
import re
import sys

SERVICE_ALLOW = {
    ipaddress.ip_address("1.1.1.1"),
    ipaddress.ip_address("8.8.8.8"),
    ipaddress.ip_address("8.8.4.4"),
    ipaddress.ip_address("9.9.9.9"),
    ipaddress.ip_address("216.239.35.0"),
    ipaddress.ip_address("216.239.35.4"),
    ipaddress.ip_address("216.239.35.8"),
    ipaddress.ip_address("216.239.35.12"),
}

DOC_NETS = (
    ipaddress.ip_network("192.0.2.0/24"),
    ipaddress.ip_network("198.51.100.0/24"),
    ipaddress.ip_network("203.0.113.0/24"),
)

IPV4_RE = re.compile(
    r"(?<![0-9])(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}"
    r"(?:25[0-5]|2[0-4]\d|[01]?\d?\d)(?![0-9])"
)


def allowed(addr: ipaddress.IPv4Address) -> bool:
    if addr in SERVICE_ALLOW:
        return True
    if addr == ipaddress.ip_address("0.0.0.0"):
        return True
    if addr == ipaddress.ip_address("255.255.255.255"):
        return True
    if addr in ipaddress.ip_network("127.0.0.0/8"):
        return True
    return any(addr in net for net in DOC_NETS)


def find_non_portable(text: str) -> list[str]:
    bad: list[str] = []
    seen: set[str] = set()
    for m in IPV4_RE.finditer(text):
        raw = m.group(0)
        if raw in seen:
            continue
        seen.add(raw)
        try:
            addr = ipaddress.ip_address(raw)
        except ValueError:
            continue
        if not isinstance(addr, ipaddress.IPv4Address):
            continue
        if allowed(addr):
            continue
        start = m.start()
        if start > 0 and (text[start - 1].isalpha() or text[start - 1] == "_"):
            continue
        bad.append(raw)
    return sorted(bad)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--label", default="input")
    ap.add_argument(
        "path",
        nargs="?",
        help="File to scan (default: stdin)",
    )
    args = ap.parse_args()
    if args.path:
        with open(args.path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    else:
        text = sys.stdin.read()
    bad = find_non_portable(text)
    if bad:
        print(
            f"PORTABLE_IP_POLICY_FAIL label={args.label} non_portable={','.join(bad)}",
            file=sys.stderr,
        )
        return 1
    print(f"PORTABLE_IP_POLICY_PASS label={args.label}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
