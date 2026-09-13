#!/usr/bin/env bash
# tests/test_menu7_dialog_no_mouse.sh
# Menu 7 viewer contract: custom scroll viewer (no whiptail/dialog textbox),
# mouse-tracking disabled for SSH selection, no clear/less/pager.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
VIEWER="${ROOT}/scripts/lib/menu7_scroll_viewer.py"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

echo "=== test_menu7_dialog_no_mouse (Menu 7 viewer contract) ==="

[[ -f "$VIEWER" ]] && pass "menu7_scroll_viewer.py present" \
  || fail "menu7_scroll_viewer.py missing"

fn="$(awk '/^mm_menu7_textbox\(\)/,/^}/' "$INSTALLER")"
helpers="$(awk '/^mm_menu7_disable_mouse_tracking\(\)/,/^mm_has_dialog\(\)/' "$INSTALLER")"

printf '%s\n' "$fn" | grep -q 'menu7_scroll_viewer.py' \
  && pass "mm_menu7_textbox uses scroll viewer" \
  || fail "mm_menu7_textbox missing scroll viewer"
printf '%s\n' "$fn" | grep -qE '(^|[^a-zA-Z_])whiptail([^a-zA-Z_]|$)' \
  && fail "whiptail still invoked from mm_menu7_textbox" \
  || pass "no whiptail in mm_menu7_textbox"
printf '%s\n' "$fn" | grep -qE '(^|[^a-zA-Z_])dialog([^a-zA-Z_]|$)' \
  && fail "dialog still invoked from mm_menu7_textbox" \
  || pass "no dialog in mm_menu7_textbox"
printf '%s\n' "$fn" | grep -qE '(^|[[:space:]])clear([[:space:]]|$)' \
  && fail "clear still present in mm_menu7_textbox (blank-screen risk)" \
  || pass "no clear in mm_menu7_textbox"
printf '%s\n' "$fn" | grep -qE '\bless\b' \
  && fail "less present in mm_menu7_textbox" \
  || pass "no less in Menu 7 viewer"
printf '%s\n' "$fn" | grep -q 'MENU7_VIEWER_REASON=scroll_viewer_missing' \
  && pass "scroll_viewer_missing error path" \
  || fail "scroll_viewer_missing error path missing"
printf '%s\n' "$helpers" | grep -q '1000l' \
  && pass "mouse-tracking disable CSI present" \
  || fail "mouse-tracking disable helper missing"
printf '%s\n' "$helpers" | grep -q 'mm_menu7_tty_restore' \
  && pass "tty restore helper present" \
  || fail "tty restore helper missing"
restore_fn="$(awk '/^mm_menu7_tty_restore\(\)/,/^}/' "$INSTALLER")"
printf '%s\n' "$restore_fn" | grep -qE '(^|[[:space:]])clear([[:space:]]|$)' \
  && fail "mm_menu7_tty_restore still clears the screen" \
  || pass "mm_menu7_tty_restore does not clear"

# Viewer source must never enable mouse tracking.
if grep -qE '1000h|1002h|1003h' "$VIEWER"; then
  fail "scroll viewer enables mouse tracking"
else
  pass "scroll viewer does not enable mouse tracking"
fi
grep -q 'Enter/ESC=Return' "$VIEWER" \
  && pass "viewer documents Enter/ESC return" \
  || fail "viewer missing Enter/ESC guidance"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MM_PROJECT_ROOT="$ROOT"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_LOG_DIR="$TMP/logs"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$TMP/config/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$TMP/config/status"
export SCRIPT_DIR="${ROOT}/scripts"
mkdir -p "$MM_LOG_DIR" "$MM_CONFIG_DIR"
: >"$MM_STATUS_FILE"

LIB="$TMP/installer-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$INSTALLER" >"$LIB"
# shellcheck disable=SC1090
source "$LIB"

HEIGHT=40 WIDTH=100
SAMPLE="$TMP/sample.txt"
printf 'sample command file\nTOP_MARKER\n' >"$SAMPLE"

# Missing viewer path → fail closed
MSG_LOG="$TMP/msg.log"
mm_whiptail_msg() { printf '%s\n' "$*" >"$MSG_LOG"; return 0; }
set +e
(
  SCRIPT_DIR="$TMP/missing-scripts"
  mm_menu7_textbox "DP Client Upgrade Commands" "$SAMPLE"
)
miss_rc=$?
set -e
[[ "$miss_rc" -ne 0 ]] && pass "missing viewer returns non-zero" \
  || fail "missing viewer should fail closed"
grep -q 'MENU7_VIEWER=FAIL' "$MSG_LOG" && pass "error reports MENU7_VIEWER=FAIL" \
  || fail "missing MENU7_VIEWER=FAIL in message"
grep -q 'MENU7_VIEWER_REASON=scroll_viewer_missing' "$MSG_LOG" \
  && pass "error reports scroll_viewer_missing" \
  || fail "missing scroll_viewer_missing reason"

grep -q 'GUI_EXITS_ONLY_ON_EXPLICIT_ZERO' "$INSTALLER" \
  && pass "main menu exit path present" || fail "explicit-zero exit marker missing"
grep -A80 'cmd_mirror_manager()' "$INSTALLER" | grep -qE '^[[:space:]]*0\)' \
  && pass "explicit main-menu 0 remains exit" \
  || fail "main-menu 0 exit missing"

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_menu7_dialog_no_mouse PASS ==="
  echo "TEST_MENU7_NO_MOUSE=PASS"
  echo "MENU7_NO_PAGER=PASS"
  echo "MENU7_MOUSE_SELECTION_SAFE=PASS"
  exit 0
fi
echo "=== test_menu7_dialog_no_mouse FAIL ==="
exit 1
