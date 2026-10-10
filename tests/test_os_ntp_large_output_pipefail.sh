#!/usr/bin/env bash
# Hermetic Phase 1 NTP: large status data cannot hide a negative condition
# or mask positive NTP readiness due to grep -q/printf SIGPIPE under pipefail.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/dp-os-upgrade-common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
pad=('unrelated ntp peer data\n' * 16000)
(p/'ntpq').write_text(
 'no association ID\n'
 '*192.168.1.1    .LOCL.  1 u 831 1024 377 58.750 1.476 1.977\n' +pad)
(p/'chronyc').write_text('Leap status     : Normal\n'+pad)
(p/'timedatectl').write_text('System clock synchronized: yes\n'+pad)
PY
ntpq_payload="$(cat "$TMP/ntpq")"
if osu_ntp_parse_ntpq_output "$ntpq_payload"; then
 echo 'FAIL: invalid no-association ID output overruled by fake selected peer' >&2
 exit 1
fi
echo 'PASS: no-association ID never appears synchronized'
chronyc() {
  case "${1:-}" in tracking) cat "$TMP/chronyc";; sources) printf 'remote sources unavailable\n';; esac
}
osu_ntp_probe_chronyc || {
 echo 'FAIL: valid early chronyc Normal status lost in long output' >&2
 exit 1
}
[[ "$OSU_NTP_SYNCHRONIZED" == true ]] || { echo 'FAIL: chronyc not synchronized' >&2; exit 1; }
echo 'PASS: chronyc Normal retained across long output'
timedatectl() {
  case "${1:-}" in status) cat "$TMP/timedatectl";; show) printf '\n';; esac
}
osu_ntp_probe_timedatectl || {
 echo 'FAIL: valid early timedatectl yes lost in long output' >&2
 exit 1
}
[[ "$OSU_NTP_SYNCHRONIZED" == true ]] || { echo 'FAIL: timedatectl not synchronized' >&2; exit 1; }
echo 'PASS: timedatectl yes retained across long output'
valid_ntpq="$(tail -n +2 "$TMP/ntpq")"
osu_ntp_parse_ntpq_output "$valid_ntpq" || {
  echo 'FAIL: healthy selected peer was lost in long ntpq output' >&2
  exit 1
}
echo 'PASS: healthy selected ntpq peer remains synchronized'
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
pad=('unrelated ntp peer data\n' * 16000)
(p/'chronyc').write_text('Leap status     : Not synchronised\n'+pad)
(p/'timedatectl').write_text('System clock synchronized: no\n'+pad)
PY
set +e
osu_ntp_probe_chronyc
rc=$?
set -e
[[ "$rc" -eq 1 && "$OSU_NTP_SYNCHRONIZED" == false ]] || {
  echo "FAIL: chronyc unsynchronized status not classified as failed (rc=$rc)" >&2
  exit 1
}
echo 'PASS: long chronyc Not synchronised fails closed'
set +e
osu_ntp_probe_timedatectl
rc=$?
set -e
[[ "$rc" -eq 1 && "$OSU_NTP_SYNCHRONIZED" == false ]] || {
  echo "FAIL: timedatectl unsynchronized status not classified as failed (rc=$rc)" >&2
  exit 1
}
echo 'PASS: long timedatectl no fails closed'
