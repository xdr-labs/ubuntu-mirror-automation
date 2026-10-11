#!/usr/bin/env python3
"""Read-only fail-closed download origin check for the operator command gate.

This deliberately does NOT execute or evaluate shell expressions. Every curl
or wget source must be pinned literally or use a visibly assigned pinned URL
variable before that invocation.
"""
import re
import shlex
import sys

ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
VARIABLE = re.compile(r"^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(?=/|$)")
VALUE_OPTIONS = {
    "-o", "--output", "-w", "--write-out", "-u", "--user",
    "-H", "--header", "-A", "--user-agent", "-X", "--request",
    "-d", "--data", "--data-raw", "-F", "--form", "-b", "--cookie",
    "-e", "--referer", "-x", "--proxy", "--noproxy",
    "--connect-timeout", "--max-time", "--retry", "--retry-delay",
    "--retry-max-time", "--cacert", "--cert", "--key",
    "--resolve", "--interface", "--limit-rate", "--output-dir",
    "--proto", "--proto-redir", "--proto-default", "--speed-time",
    "--speed-limit", "--range", "-r", "--upload-file", "-T",
}
SAFE_LONG_FLAGS = {
    "--fail", "--fail-with-body", "--silent", "--show-error",
    "--location", "--location-trusted", "--remote-name",
    "--remote-name-all", "--compressed", "--insecure",
    "--head", "--include", "--ipv4", "--ipv6", "--get",
    "--globoff", "--progress-bar", "--disable",
}


def pinned(value, variables, expected):
    """Resolve only visibly assigned URL-prefix variables, never shell code."""
    for _ in range(8):
        match = VARIABLE.match(value)
        if not match:
            break
        name = match.group(1) or match.group(2)
        if name not in variables:
            return False
        value = variables[name] + value[match.end():]
    if VARIABLE.match(value) or "$(" in value or "\x60" in value:
        return False
    return value == expected or value.startswith(expected + "/")


def curl_sources_valid(args, variables, expected):
    checked = 0
    index = 0
    while index < len(args):
        value = args[index]
        if value in ("-K", "--config") or value.startswith("--config="):
            # curl config files can add arbitrary remote URLs.
            return False
        if value in VALUE_OPTIONS:
            index += 2
            if index > len(args):
                return False
            continue
        if value in ("--url",):
            index += 1
            if index >= len(args) or not pinned(args[index], variables, expected):
                return False
            checked += 1
        elif value.startswith("--url="):
            if not pinned(value.partition("=")[2], variables, expected):
                return False
            checked += 1
        elif value == "--":
            for source in args[index + 1:]:
                if not pinned(source, variables, expected):
                    return False
                checked += 1
            break
        elif value.startswith("--"):
            key = value.split("=", 1)[0]
            if key not in SAFE_LONG_FLAGS and key not in VALUE_OPTIONS:
                return False  # unrecognized option could conceal an URL source
        elif value.startswith("-") and value != "-":
            # -fsSLo consumes the following output filename; -fsSLO does not.
            if value.endswith("o") and not value.endswith("O"):
                index += 1
                if index >= len(args):
                    return False
            elif not all(ch in "fsSLOkqvIiG4g" for ch in value[1:]):
                return False
        else:
            if not pinned(value, variables, expected):
                return False
            checked += 1
        index += 1
    return checked > 0


def wget_sources_valid(args, variables, expected):
    """Check wget URL operands independently; reject hidden input files."""
    output_options = {
        "-O", "--output-document", "-o", "--output-file",
        "-P", "--directory-prefix", "-T", "--timeout",
        "-t", "--tries", "-U", "--user-agent",
    }
    safe_options = {
        "-q", "-nv", "-c", "-N", "--quiet", "--no-verbose",
        "--continue", "--timestamping", "--no-check-certificate",
    }
    checked = 0
    index = 0
    while index < len(args):
        value = args[index]
        if value in ("-i", "--input-file", "-e", "--execute", "--config") or \
           value.startswith(("--input-file=", "--execute=", "--config=")):
            return False  # hidden URL sources and commands cannot be verified
        if value in output_options:
            index += 2
            if index > len(args):
                return False
            continue
        if value.startswith("--") and "=" in value:
            if value.split("=", 1)[0] not in output_options:
                return False
        elif value in safe_options or value == "--":
            if value == "--":
                for source in args[index + 1:]:
                    if not pinned(source, variables, expected):
                        return False
                    checked += 1
                break
        elif value.startswith("-"):
            if len(value) <= 2 or not all(ch in "qvncN" for ch in value[1:]):
                return False
        else:
            if not pinned(value, variables, expected):
                return False
            checked += 1
        index += 1
    return checked > 0


def check(text, expected):
    # A single-quoted shell variable does not expand: never trust it as a URL.
    for quoted in re.findall(r"'[^'\n]*'", text):
        if re.search(r"\$[A-Za-z_{]", quoted):
            return False
    lexer = shlex.shlex(text, posix=True, punctuation_chars=";&|\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    lexer.commenters = "#"
    try:
        tokens = list(lexer)
    except ValueError:
        return False
    variables = {}
    group = []
    for token in tokens + ["\n"]:
        if token in (";", "&&", "||", "&", "|", "\n"):
            if not inspect(group, variables, expected):
                return False
            group = []
        else:
            group.append(token)
    return True


def inspect(words, variables, expected):
    if not words:
        return True
    source_at = next((i for i, word in enumerate(words) if word in ("curl", "wget")), -1)
    prefix = words if source_at < 0 else words[:source_at]
    if prefix and prefix[0] == "export":
        prefix = prefix[1:]
    for word in prefix:
        match = ASSIGNMENT.match(word)
        if match:
            variables[match.group(1)] = match.group(2)
        else:
            break
    if source_at < 0:
        return True
    if words[source_at] == "curl":
        return curl_sources_valid(words[source_at + 1:], variables, expected)
    return wget_sources_valid(words[source_at + 1:], variables, expected)


if __name__ == "__main__":
    if len(sys.argv) != 2 or not sys.argv[1].startswith(("http://", "https://")):
        sys.exit(1)
    try:
        sys.exit(0 if check(sys.stdin.read(), sys.argv[1].rstrip("/")) else 1)
    except (OSError, UnicodeError):
        sys.exit(1)
