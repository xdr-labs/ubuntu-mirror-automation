#!/usr/bin/env bash
# tests/test_menu7_dialog_no_mouse.sh
# Menu 7 viewer contract: framed dialog --textbox with --no-mouse,
# no clear/less/pager/raw-terminal viewer, Return/ESC close only the viewer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

echo "=== test_menu7_dialog_no_mouse (Menu 7 viewer contract) ==="

fn="$(awk '/^mm_menu7_textbox\(\)/,/^}/' "$INSTALLER")"
helpers="$(awk '/^mm_menu7_disable_mouse_tracking\(\)/,/^mm_has_dialog\(\)/' "$INSTALLER")"

printf '%s\n' "$fn" | grep -qE '(^|[^a-zA-Z_])dialog([^a-zA-Z_]|$)' \
  && pass "mm_menu7_textbox uses dialog" \
  || fail "mm_menu7_textbox missing dialog"
printf '%s\n' "$fn" | grep -q -- '--textbox' \
  && pass "mm_menu7_textbox uses --textbox" \
  || fail "mm_menu7_textbox missing --textbox"
printf '%s\n' "$fn" | grep -q -- '--no-mouse' \
  && pass "--no-mouse on argv" \
  || fail "missing --no-mouse"
printf '%s\n' "$fn" | grep -q -- '--exit-label "Return"' \
  && pass "Exit labeled Return" \
  || fail "missing --exit-label Return"
printf '%s\n' "$fn" | grep -qE '(^|[^a-zA-Z_])whiptail([^a-zA-Z_]|$)' \
  && fail "whiptail still invoked from mm_menu7_textbox" \
  || pass "no whiptail in mm_menu7_textbox"
printf '%s\n' "$fn" | grep -q 'menu7_scroll_viewer.py' \
  && fail "raw scroll_viewer still production path" \
  || pass "MENU7_RAW_TERMINAL_VIEWER_USED=NO"
printf '%s\n' "$fn" | grep -qE '(^|[[:space:]])clear([[:space:]]|$)' \
  && fail "clear still present in mm_menu7_textbox (blank-screen risk)" \
  || pass "no clear in mm_menu7_textbox"
printf '%s\n' "$fn" | grep -qE '\bless\b' \
  && fail "less present in mm_menu7_textbox" \
  || pass "no less in Menu 7 viewer"
printf '%s\n' "$fn" | grep -q 'MENU7_VIEWER_REASON=dialog_missing' \
  && pass "dialog_missing error path" \
  || fail "dialog_missing error path missing"
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
printf '%s\n' "$restore_fn" | grep -qE '\breset\b' \
  && fail "mm_menu7_tty_restore calls reset" \
  || pass "mm_menu7_tty_restore does not reset"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MM_PROJECT_ROOT="$ROOT"
export MM_HERMETIC_TEST_MODE=1
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_LOG_DIR="$TMP/logs"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$TMP/config/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$TMP/config/status"
export SCRIPT_DIR="${ROOT}/scripts"
mkdir -p "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$TMP/bin"
: >"$MM_STATUS_FILE"

ARGV_LOG="$TMP/dialog.argv"
cat >"$TMP/bin/dialog" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"${ARGV_LOG}"
exit 0
EOF
chmod +x "$TMP/bin/dialog"

LIB="$TMP/installer-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$INSTALLER" >"$LIB"
# shellcheck disable=SC1090
source "$LIB"

HEIGHT=40 WIDTH=100
export PATH="$TMP/bin:/usr/bin:/bin"
SAMPLE="$TMP/sample.txt"
printf 'sample command file\n' >"$SAMPLE"
mm_menu7_textbox "DP Client Upgrade Commands" "$SAMPLE"
[[ -f "$ARGV_LOG" ]] || fail "dialog stub was not invoked"
grep -q -- '--textbox' "$ARGV_LOG" && pass "stub argv contains --textbox" \
  || fail "stub argv missing --textbox: $(cat "$ARGV_LOG")"
grep -q -- '--no-mouse' "$ARGV_LOG" && pass "stub argv contains --no-mouse" \
  || fail "stub argv missing --no-mouse"
grep -q -- 'Return' "$ARGV_LOG" && pass "stub argv contains Return" \
  || fail "stub argv missing Return"
grep -q -- 'whiptail' "$ARGV_LOG" && fail "whiptail in dialog argv" || pass "stub argv has no whiptail"
grep -q 'menu7_scroll_viewer' "$ARGV_LOG" && fail "raw viewer in argv" || pass "stub argv has no raw viewer"

# dialog missing → error
MSG_LOG="$TMP/msg.log"
mm_whiptail_msg() { printf '%s\n' "$*" >"$MSG_LOG"; return 0; }
EMPTY_PATH="$TMP/empty-path"
mkdir -p "$EMPTY_PATH"
export PATH="$EMPTY_PATH"
set +e
mm_menu7_textbox "DP Client Upgrade Commands" "$SAMPLE"
miss_rc=$?
set -e
export PATH="/usr/bin:/bin:${TMP}/bin"
[[ "$miss_rc" -ne 0 ]] && pass "dialog missing returns non-zero" \
  || fail "dialog missing should fail closed"
grep -q 'MENU7_VIEWER=FAIL' "$MSG_LOG" && pass "error reports MENU7_VIEWER=FAIL" \
  || fail "missing MENU7_VIEWER=FAIL in message"
grep -q 'MENU7_VIEWER_REASON=dialog_missing' "$MSG_LOG" \
  && pass "error reports dialog_missing" \
  || fail "missing dialog_missing reason"

grep -q 'GUI_EXITS_ONLY_ON_EXPLICIT_ZERO' "$INSTALLER" \
  && pass "main menu exit path present" || fail "explicit-zero exit marker missing"

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_menu7_dialog_no_mouse PASS ==="
  echo "TEST_MENU7_NO_MOUSE=PASS"
  echo "MENU7_NO_PAGER=PASS"
  echo "MENU7_MOUSE_SELECTION_SAFE=PASS"
  echo "MENU7_GUI_FRAME_VISIBLE=PASS"
  echo "MENU7_RAW_TERMINAL_VIEWER_USED=NO"
  exit 0
fi
echo "=== test_menu7_dialog_no_mouse FAIL ==="
exit 1
