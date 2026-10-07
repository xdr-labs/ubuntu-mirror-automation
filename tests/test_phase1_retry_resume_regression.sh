#!/usr/bin/env bash
# Regression coverage for Phase 1 mirror retry/HTTP normalization and safe
# pre-package-transition re-entry after interruption.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/phase1-retry-resume.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

HOPS=(
  "xenial-to-bionic:XENIAL:BIONIC"
  "bionic-to-focal:BIONIC:FOCAL"
  "focal-to-jammy:FOCAL:JAMMY"
  "jammy-to-noble:JAMMY:NOBLE"
)

extract_function() {
  local src="$1" fn="$2" out="$3"
  python3 - "$src" "$fn" "$out" <<'PY'
from pathlib import Path
import re, sys
src, fn, out = sys.argv[1:]
text = Path(src).read_text(encoding='utf-8')
pat = re.compile(r'^' + re.escape(fn) + r'\(\) \{\n.*?^\}\n', re.M | re.S)
m = pat.search(text)
if not m:
    raise SystemExit(f"function not found: {fn} in {src}")
Path(out).write_text(m.group(0), encoding='utf-8')
PY
}

# ---------------------------------------------------------------------------
# 1) http_code normalizes transport failure to exactly 000 and retries
#    transient probe/fetch failures up to three attempts.
# ---------------------------------------------------------------------------
for entry in "${HOPS[@]}"; do
  IFS=: read -r hop src tgt <<<"$entry"
  template="${ROOT}/client/dp-offline-upgrade-${hop}.sh.in"
  fx="${TMP}/${hop}-http"
  mkdir -p "$fx/bin"
  funcs="$fx/http-functions.sh"
  extract_function "$template" http_code "$funcs"
  extract_function "$template" http_fetch "$fx/fetch-function.sh"
  cat "$fx/fetch-function.sh" >>"$funcs"

  cat >"$fx/bin/curl" <<'SH'
#!/usr/bin/env bash
set -u
state_dir="${FAKE_CURL_STATE:?}"
url="${!#}"
key=unknown
case "$url" in
  *probe*) key=probe ;;
  *partial*) key=partial ;;
  *dead*) key=dead ;;
  *fetch*) key=fetch ;;
esac
count_file="${state_dir}/${key}.count"
count=0
[[ -f "$count_file" ]] && count="$(cat "$count_file")"
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"

out=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then
    out="$arg"
    prev=""
    continue
  fi
  prev="$arg"
done

case "$key" in
  probe)
    if [[ "$count" -eq 1 ]]; then printf '000'; exit 28; fi
    if [[ "$count" -eq 2 ]]; then printf '503'; exit 0; fi
    printf '200'; exit 0
    ;;
  partial)
    if [[ "$count" -lt 3 ]]; then printf '200'; exit 18; fi
    printf '200'; exit 0
    ;;
  dead)
    printf '000'; exit 7
    ;;
  fetch)
    if [[ "$count" -lt 3 ]]; then exit 7; fi
    [[ -n "$out" ]] || exit 64
    printf 'payload-ok\n' >"$out"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fx/bin/curl"

  cat >"$fx/run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT=""
FAKE_CURL_STATE="${FAKE_CURL_STATE:?}"
LOG="${LOG:?}"
hostpath() { printf '%s' "$1"; }
log() { local level="$1"; shift; printf '%s %s\n' "$level" "$*" >>"$LOG"; }
sleep() { :; }
source "${FUNCS:?}"

probe="$(http_code http://mirror.invalid/probe)"
[[ "$probe" == "200" ]] || { echo "probe=$probe" >&2; exit 10; }
[[ "$(cat "$FAKE_CURL_STATE/probe.count")" == "3" ]] || exit 11

partial="$(http_code http://mirror.invalid/partial)"
[[ "$partial" == "200" ]] || { echo "partial=$partial" >&2; exit 12; }
[[ "$(cat "$FAKE_CURL_STATE/partial.count")" == "3" ]] || exit 13

dead="$(http_code http://mirror.invalid/dead)"
[[ "$dead" == "000" ]] || { echo "dead=$dead" >&2; exit 14; }
[[ "${#dead}" -eq 3 ]] || exit 15
[[ "$(cat "$FAKE_CURL_STATE/dead.count")" == "3" ]] || exit 16

dest="${FAKE_CURL_STATE}/artifact.bin"
http_fetch http://mirror.invalid/fetch "$dest"
grep -qx 'payload-ok' "$dest" || exit 17
[[ "$(cat "$FAKE_CURL_STATE/fetch.count")" == "3" ]] || exit 18

[[ "$(grep -c 'HTTP_PROBE_RETRY' "$LOG")" -eq 6 ]] || exit 19
[[ "$(grep -c 'HTTP_FETCH_RETRY' "$LOG")" -eq 2 ]] || exit 20
SH
  chmod +x "$fx/run.sh"
  mkdir -p "$fx/state"
  : >"$fx/retry.log"

  PATH="$fx/bin:/usr/bin:/bin" \
    FAKE_CURL_STATE="$fx/state" \
    LOG="$fx/retry.log" \
    FUNCS="$funcs" \
    bash "$fx/run.sh" || {
      cat "$fx/retry.log" >&2 || true
      fail "${hop}: HTTP retry/000 normalization regression"
    }
  pass "${hop}: transient HTTP retry + exact 000 normalization"
done

# ---------------------------------------------------------------------------
# 2) Current-hop invocation/spawn markers without package transition are
#    NO_MUTATION. A real transition remains fail-closed.
# ---------------------------------------------------------------------------
for entry in "${HOPS[@]}"; do
  IFS=: read -r hop src tgt <<<"$entry"
  template="${ROOT}/client/dp-offline-upgrade-${hop}.sh.in"

  grep -Fq "CONFIGURING|PREPARING_${src}|UPGRADING_${src}_TO_${tgt})" "$template" \
    || fail "${hop}: UPGRADING state is not routed through stale-safe recovery"
  grep -Fq "REBOOT_PENDING|REBOOTING|POST_BOOT_VERIFY|POST_UPGRADE_VERIFY)" "$template" \
    || fail "${hop}: post-transition/reboot states not kept separate"
  grep -Fq 'Re-run the same client; it will revalidate before continuing.' "$template" \
    || fail "${hop}: safe pre-transition rerun guidance missing"
  grep -Fq 'The package transition had already started. Do not rerun the client' "$template" \
    || fail "${hop}: post-transition fail-closed guidance missing"

  # A stale UPGRADING_* state must not be treated as live solely because of the
  # state token. Liveness wins; if no service/runner/DRO exists, the caller must
  # reach stale-state reconciliation where package-transition evidence decides.
  livefx="${TMP}/${hop}-liveness"
  mkdir -p "$livefx"
  extract_function "$template" detect_upgrade_already_running "$livefx/detect.sh"
  cat >"$livefx/run.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "$livefx/detect.sh"
STATE="UPGRADING_${src}_TO_${tgt}"
LIVE=0
read_state() { printf '%s' "\$STATE"; }
allow_live_systemctl() { return 0; }
live_upgrade_evidence_present() { [[ "\$LIVE" -eq 1 ]]; }
state_is_upgrade_running() { return 0; }
if detect_upgrade_already_running; then
  echo "stale UPGRADING state was treated as live" >&2
  exit 30
fi
LIVE=1
detect_upgrade_already_running || {
  echo "live UPGRADING state was not protected" >&2
  exit 31
}
SH
  chmod +x "$livefx/run.sh"
  bash "$livefx/run.sh" || fail "${hop}: stale UPGRADING liveness routing"
  pass "${hop}: stale UPGRADING reaches reconciliation; live UPGRADING remains protected"

  if [[ "$hop" == "xenial-to-bionic" ]]; then
    grep -Fq 'Invocation/spawn alone is not a transaction' "$template" \
      || fail "${hop}: invocation-only marker policy missing"
    pass "${hop}: invocation-only marker remains non-transactional"
    continue
  fi

  fx="${TMP}/${hop}-state"
  mkdir -p "$fx"
  funcs="$fx/state-functions.sh"
  extract_function "$template" classify_mutation_evidence_ownership "$funcs"
  extract_function "$template" transaction_markers_any_true "$fx/tx-function.sh"
  cat "$fx/tx-function.sh" >>"$funcs"

  cat >"$fx/run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "${FUNCS:?}"

PIN_HOP="${PIN_HOP:?}"
PREVIOUS_HOP_PIN_NAME="previous-hop"
HOLDS_DIR="/unused"
STATE_ROOT="/unused"
TEST_ROOT=""
CURRENT_RUN_ID=""

STATE="CONFIGURING"
TRANSITION=0
PACKAGE_EVIDENCE=0
ANY_MARKER=1

hostpath() { printf '%s' "$1"; }
read_state() { printf '%s' "$STATE"; }
read_live_pins_hop() { printf '%s' "$PIN_HOP"; }
read_live_manifest_hop() { printf '%s' "$PIN_HOP"; }
read_current_hop_field() {
  case "$1" in
    CURRENT_HOP) printf '%s' "$PIN_HOP" ;;
    *) printf '' ;;
  esac
}
marker_meta_field() { printf ''; }
read_os_field() { printf ''; }
transition_marker_true() { [[ "$TRANSITION" -eq 1 ]]; }
any_release_upgrade_marker_true() { [[ "$ANY_MARKER" -eq 1 ]]; }
package_transition_evidence_present() { [[ "$PACKAGE_EVIDENCE" -eq 1 ]]; }

MUTATION_EVIDENCE_CLASS=""
classify_mutation_evidence_ownership
[[ "$MUTATION_EVIDENCE_CLASS" == "NO_MUTATION" ]] || {
  echo "invocation-only class=$MUTATION_EVIDENCE_CLASS" >&2
  exit 20
}
if transaction_markers_any_true; then
  echo "invocation-only markers treated as transaction" >&2
  exit 21
fi

STATE="UPGRADING_TEST_TO_TEST"
MUTATION_EVIDENCE_CLASS=""
classify_mutation_evidence_ownership
[[ "$MUTATION_EVIDENCE_CLASS" == "NO_MUTATION" ]] || {
  echo "pre-transition UPGRADING class=$MUTATION_EVIDENCE_CLASS" >&2
  exit 22
}

STATE="CONFIGURING"
TRANSITION=1
PACKAGE_EVIDENCE=1
MUTATION_EVIDENCE_CLASS=""
classify_mutation_evidence_ownership
[[ "$MUTATION_EVIDENCE_CLASS" == "CURRENT_HOP_MUTATION" ]] || {
  echo "real transition class=$MUTATION_EVIDENCE_CLASS" >&2
  exit 23
}
transaction_markers_any_true || {
  echo "real transition was not blocked" >&2
  exit 24
}
SH
  chmod +x "$fx/run.sh"
  FUNCS="$funcs" PIN_HOP="$hop" bash "$fx/run.sh" \
    || fail "${hop}: deterministic pre-transition re-entry classification"
  pass "${hop}: invocation-only re-entry safe; real package transition fail-closed"
done

echo "PHASE1_RETRY_RESUME_REGRESSION=PASS"
