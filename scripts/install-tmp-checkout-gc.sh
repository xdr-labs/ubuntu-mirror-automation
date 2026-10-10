#!/usr/bin/env bash
# Install/disable the aella-owned opt-in temporary Git checkout reaper.
# No sudo, no modification of system-wide services, no unmanaged deletions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${ROOT}/scripts/tmp-checkout-gc.py"
INSTALL_DIR="${HOME}/.local/lib/ubuntu-mirror-automation"
DEST="${INSTALL_DIR}/tmp-checkout-gc.py"
SHORTCUT="${HOME}/.local/bin/um-tmp-checkout"
STATE_DIR="${HOME}/.local/state/ubuntu-mirror-automation/tmp-checkout-gc"
BEGIN_MARKER="# BEGIN ubuntu-mirror-automation tmp-checkout-gc"
END_MARKER="# END ubuntu-mirror-automation tmp-checkout-gc"
MODE="${1:---install}"

case "$MODE" in
  --install|--disable) ;;
  *) echo "Usage: $0 [--install|--disable]" >&2; exit 2 ;;
esac

command -v crontab >/dev/null || { echo "CRON_UNAVAILABLE" >&2; exit 1; }
if [[ "$MODE" == "--install" ]]; then
  [[ -f "$SOURCE" ]] || { echo "GC_SOURCE_MISSING" >&2; exit 1; }
  install -d -m 0700 "$INSTALL_DIR" "$STATE_DIR"
  install -d -m 0755 "${HOME}/.local/bin"
  if [[ -e "$SHORTCUT" || -L "$SHORTCUT" ]]; then
    [[ -L "$SHORTCUT" && "$(readlink "$SHORTCUT")" == "$DEST" ]] || {
      echo "SHORTCUT_COLLISION=$SHORTCUT" >&2
      exit 1
    }
  else
    ln -s "$DEST" "$SHORTCUT"
  fi
  install -m 0755 "$SOURCE" "$DEST"
  # Must be able to inspect the installed executable without removing data.
  /usr/bin/python3 "$DEST" status
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
existing="$(crontab -l 2>/dev/null || true)"
# The machine can already have unrelated user cron jobs. Preserve them all.
CRONTAB_EXISTING="$existing" /usr/bin/python3 - "$MODE" "$DEST" "$STATE_DIR" "$BEGIN_MARKER" "$END_MARKER" > "$tmp" <<'PY'
import os
import sys
mode, program, state, start, end = sys.argv[1:]
lines = os.environ.get("CRONTAB_EXISTING", "").splitlines()
if lines.count(start) != lines.count(end) or lines.count(start) > 1:
    raise SystemExit("Refusing ambiguous existing managed cron block")
out = []
inside = False
for line in lines:
    if line == start:
        inside = True
        continue
    if line == end:
        inside = False
        continue
    if not inside:
        out.append(line)
if mode == "--install":
    if out and out[-1].strip():
        out.append("")
    out.extend([start,
                # 18:15 UTC == 03:15 Korea Standard Time, every day.
                "15 18 * * * /usr/bin/python3 %s prune --apply >> %s/cron.log 2>&1" % (program, state),
                end])
print("\n".join(out))
PY

# Store a permission-restricted backup before replacing the user's crontab.
backup="${STATE_DIR}/crontab.before.$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -d "$STATE_DIR" ]]; then
  umask 077
  printf '%s\n' "$existing" > "$backup"
fi
crontab "$tmp"
if [[ "$MODE" == "--install" ]]; then
  echo "TMP_CHECKOUT_GC_INSTALL=PASS"
  echo "SCHEDULE=18:15_UTC_DAILY (03:15_KST)"
  echo "INSTALLED_COMMAND=/usr/bin/python3 $DEST"
else
  echo "TMP_CHECKOUT_GC_SCHEDULE=DISABLED"
  echo "CHECKOUTS_AND_REGISTRY=PRESERVED"
fi
