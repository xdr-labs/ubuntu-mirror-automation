#!/usr/bin/env bash
# tests/test_menu7_dialog_no_mouse.sh
# Menu 7 viewer contract: whiptail textbox (same toolkit as main menu),
# mouse-tracking disabled for SSH selection, no dialog/clear/less/pager,
# Return/ESC close only the viewer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

echo "=== test_menu7_dialog_no_mouse (Menu 7 viewer contract) ==="

fn="$(awk '/^mm_menu7_textbox\(\)/,/^}/' "$INSTALLER")"
helpers="$(awk '/^mm_menu7_disable_mouse_tracking\(\)/,/^mm_has_dialog\(\)/' "$INSTALLER")"

printf '%s\n' "$fn" | grep -q 'whiptail' \
  && pass "mm_menu7_textbox uses whiptail" \
  || fail "mm_menu7_textbox missing whiptail"
printf '%s\n' "$fn" | grep -q -- '--textbox' \
  && pass "mm_menu7_textbox uses --textbox" \
  || fail "mm_menu7_textbox missing --textbox"
printf '%s\n' "$fn" | grep -q -- '--ok-button "Return"' \
  && pass "OK button labeled Return" \
  || fail "missing --ok-button Return"
printf '%s\n' "$fn" | grep -q -- '--cancel-button "Return"' \
  && pass "Cancel/ESC button labeled Return" \
  || fail "missing --cancel-button Return"
printf '%s\n' "$fn" | grep -qE '(^|[^a-zA-Z_])dialog([^a-zA-Z_]|$)' \
  && fail "dialog still invoked from mm_menu7_textbox" \
  || pass "no dialog in mm_menu7_textbox"
printf '%s\n' "$fn" | grep -qE '(^|[[:space:]])clear([[:space:]]|$)' \
  && fail "clear still present in mm_menu7_textbox (blank-screen risk)" \
  || pass "no clear in mm_menu7_textbox"
printf '%s\n' "$fn" | grep -qE '\bless\b' \
  && fail "less present in mm_menu7_textbox" \
  || pass "no less in Menu 7 viewer"
printf '%s\n' "$fn" | grep -q 'MENU7_VIEWER_REASON=whiptail_missing' \
  && pass "whiptail_missing error path" \
  || fail "whiptail_missing error path missing"
printf '%s\n' "$helpers" | grep -q '1000l' \
  && pass "mouse-tracking disable CSI present" \
  || fail "mouse-tracking disable helper missing"
printf '%s\n' "$helpers" | grep -q 'mm_menu7_tty_restore' \
  && pass "tty restore helper present" \
  || fail "tty restore helper missing"
# Restore must not clear.
restore_fn="$(awk '/^mm_menu7_tty_restore\(\)/,/^}/' "$INSTALLER")"
printf '%s\n' "$restore_fn" | grep -qE '(^|[[:space:]])clear([[:space:]]|$)' \
  && fail "mm_menu7_tty_restore still clears the screen" \
  || pass "mm_menu7_tty_restore does not clear"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MM_PROJECT_ROOT="$ROOT"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_LOG_DIR="$TMP/logs"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$TMP/config/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$TMP/config/status"
export SCRIPT_DIR="${ROOT}/scripts"
mkdir -p "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$TMP/bin"
: >"$MM_STATUS_FILE"

ARGV_LOG="$TMP/whiptail.argv"
MOUSE_LOG="$TMP/mouse.csi"
cat >"$TMP/bin/whiptail" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"${ARGV_LOG}"
# Simulate Return (OK)
exit 0
EOF
chmod +x "$TMP/bin/whiptail"
# Capture mouse-disable writes to a fake tty sink when /dev/tty unavailable in stubs.
# The function prefers /dev/tty; still verify argv contract below.

LIB="$TMP/installer-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$INSTALLER" >"$LIB"
# shellcheck disable=SC1090
source "$LIB"
trap 'rm -rf "$TMP"' EXIT

HEIGHT=40 WIDTH=100
export PATH="$TMP/bin:/usr/bin:/bin"
SAMPLE="$TMP/sample.txt"
printf 'sample command file\n' >"$SAMPLE"
mm_menu7_textbox "DP Client Upgrade Commands" "$SAMPLE"
[[ -f "$ARGV_LOG" ]] || fail "whiptail stub was not invoked"
grep -q -- '--textbox' "$ARGV_LOG" && pass "stub argv contains --textbox" \
  || fail "stub argv missing --textbox: $(cat "$ARGV_LOG")"
grep -q -- '--ok-button Return\|--ok-button "Return"' "$ARGV_LOG" \
  || grep -q -- '--ok-button' "$ARGV_LOG" \
  && pass "stub argv contains --ok-button" \
  || fail "stub argv missing --ok-button: $(cat "$ARGV_LOG")"
grep -q -- '--title' "$ARGV_LOG" && pass "stub argv contains --title" \
  || fail "stub argv missing --title"
grep -q -- 'dialog' "$ARGV_LOG" && fail "dialog appeared in argv" || pass "stub argv has no dialog"

# whiptail missing → error
rm -f "$TMP/bin/whiptail"
hash -r 2>/dev/null || true
SAVE_PATH="$PATH"
export PATH="/nonexistent"
MSG_LOG="$TMP/msg.log"
mm_has_whiptail() { return 1; }
mm_whiptail_msg() { printf '%s\n' "$*" >"$MSG_LOG"; return 0; }
set +e
mm_menu7_textbox "DP Client Upgrade Commands" "$SAMPLE"
miss_rc=$?
set -e
export PATH="/usr/bin:/bin:${TMP}/bin:${SAVE_PATH}"
hash -r 2>/dev/null || true
[[ "$miss_rc" -ne 0 ]] && pass "whiptail missing returns non-zero" \
  || fail "whiptail missing should fail closed"
grep -q 'MENU7_VIEWER=FAIL' "$MSG_LOG" && pass "error reports MENU7_VIEWER=FAIL" \
  || fail "missing MENU7_VIEWER=FAIL in message"
grep -q 'MENU7_VIEWER_REASON=whiptail_missing' "$MSG_LOG" \
  && pass "error reports whiptail_missing" \
  || fail "missing whiptail_missing reason"

# Main menu: only choice 0 exits
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
