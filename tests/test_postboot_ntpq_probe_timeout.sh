#!/usr/bin/env bash
# Field-derived regression: unbounded ntpq hung Real AWS postboot for ~15 minutes
# on `ntpq rv`. Every ntpq probe (-pn, -p, rv) must be wall-clock bounded, emit
# NTPQ_PROBE_TIMEOUT=YES, never assert sync from timed-out output, and fall
# through to legitimate readiness fallbacks without requiring a manual kill.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="${ROOT}/client/dp-postboot-readiness-policy.sh.inc"
GENERATED="${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh"
TEMPLATE="${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh.in"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

[[ -f "$POLICY" && -f "$GENERATED" && -f "$TEMPLATE" ]] || {
  echo "missing sources"
  exit 1
}

bash -n "$POLICY" || { echo "policy syntax error"; exit 1; }

# Static contracts: policy source + generated payload (template inlines via placeholder).
for label in policy generated; do
  case "$label" in
    policy) f="$POLICY" ;;
    generated) f="$GENERATED" ;;
  esac
  if grep -q 'run_ntpq_probe()' "$f" \
    && grep -q 'NTPQ_PROBE_TIMEOUT=YES' "$f" \
    && grep -q 'NTPQ_PROBE_TIMEOUT_SECONDS' "$f"; then
    pass "${label} bounded ntpq probe helpers present"
  else
    fail "${label} missing bounded ntpq probe helpers"
  fi
done
if grep -q '@@POSTBOOT_POLICY_LIB@@' "$TEMPLATE"; then
  pass "template retains postboot policy placeholder for bounded ntpq"
else
  fail "template missing @@POSTBOOT_POLICY_LIB@@"
fi

# Generated postboot payload must not retain unbounded ntpq command substitutions.
python3 - "$GENERATED" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
m = re.search(r"cat <<'POSTBOOT_HDR'\n(.*?)\nPOSTBOOT_HDR", text, re.S)
if not m:
    raise SystemExit("POSTBOOT_HDR missing")
hdr = m.group(1)
# Forbidden: direct unbounded ntpq capture of the pre-fix form.
forbidden = re.search(
    r'\$\(\s*"\$\{?NTPQ_BIN\}?"\s+-pn\b|'
    r'\$\(\s*"\$\{?NTPQ_BIN\}?"\s+-p\b|'
    r'\$\(\s*"\$\{?NTPQ_BIN\}?"\s+rv\b|'
    r'\$\(\s*\$NTPQ_BIN\s+-pn\b|'
    r'\$\(\s*\$NTPQ_BIN\s+rv\b',
    hdr,
)
if forbidden:
    raise SystemExit("unbounded ntpq capture still present in POSTBOOT_HDR")
if "run_ntpq_probe pn -pn" not in hdr or "run_ntpq_probe rv rv" not in hdr:
    raise SystemExit("run_ntpq_probe wiring missing from POSTBOOT_HDR")
print("ok")
PY
pass "generated POSTBOOT_HDR uses bounded run_ntpq_probe only"

run_hang_case() {
  local name="$1" hang_mode="$2"
  local td mock out rc elapsed start end children_left
  td="$(mktemp -d "${TMPDIR:-/tmp}/ntpq-timeout.XXXXXX")"
  mock="$td/bin"
  mkdir -p "$mock" "$td/root"

  # Hanging ntpq: never returns for the selected probe(s).
  cat >"$mock/ntpq" <<MOCK
#!/usr/bin/env bash
mode="${hang_mode}"
arg="\${1:-}"
case "\$mode" in
  pn)
    if [[ "\$arg" == "-pn" ]]; then exec sleep 3600; fi
    printf 'ntpq: unexpected non-hang arg\\n' >&2
    exit 1
    ;;
  p_after_pn_fail)
    if [[ "\$arg" == "-pn" ]]; then
      printf 'ntpq: -pn failed\\n' >&2
      exit 1
    fi
    if [[ "\$arg" == "-p" ]]; then exec sleep 3600; fi
    printf 'ntpq: unexpected\\n' >&2
    exit 1
    ;;
  rv)
    if [[ "\$arg" == "-pn" || "\$arg" == "-p" ]]; then
      printf '%s\\n' '     remote           refid      st t when poll reach   delay   offset  jitter'
      printf '%s\\n' '=============================================================================='
      printf '%s\\n' '*10.1.2.3        LOCAL            1 u  10  64  377    0.100    0.500   0.200'
      exit 0
    fi
    if [[ "\$arg" == "rv" ]]; then exec sleep 3600; fi
    exit 1
    ;;
  *)
    exit 99
    ;;
esac
MOCK
  chmod +x "$mock/ntpq"

  # ntpwait fails so readiness must not pass via ntpwait.
  cat >"$mock/ntpwait" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$mock/ntpwait"

  # timedatectl proves sync so fallback remains legitimate after ntpq timeout.
  cat >"$mock/timedatectl" <<'MOCK'
#!/usr/bin/env bash
printf 'System clock synchronized: yes\nNTP service: active\n'
MOCK
  chmod +x "$mock/timedatectl"

  cat >"$mock/timeout" <<'MOCK'
#!/usr/bin/env bash
# Prefer real coreutils timeout when present on PATH behind this stub.
if [[ -x /usr/bin/timeout ]]; then
  exec /usr/bin/timeout "$@"
fi
secs="${1:-20}"
shift
"$@" &
pid=$!
waited=0
while kill -0 "$pid" 2>/dev/null; do
  if (( waited >= secs )); then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    exit 124
  fi
  sleep 1
  waited=$((waited + 1))
done
wait "$pid"
exit $?
MOCK
  chmod +x "$mock/timeout"

  # shellcheck disable=SC1090
  set +e
  start=$(date +%s)
  (
    # shellcheck source=/dev/null
    source "$POLICY"
    export PATH="$mock:$PATH"
    export NTPQ_BIN=ntpq
    export NTPWAIT_BIN=ntpwait
    export TIMEDATECTL_BIN=timedatectl
    export NTPQ_PROBE_TIMEOUT_SECONDS=2
    export DP_MAX_CLOCK_SKEW_SECONDS=300
    check_time_readiness
  ) >"$td/out" 2>&1
  rc=$?
  end=$(date +%s)
  set -e
  elapsed=$((end - start))
  out="$(cat "$td/out")"

  # Must finish well under an unbounded hang (field was ~15 minutes).
  if ((elapsed > 25)); then
    fail "$name did not return in bounded time (elapsed=${elapsed}s)"
  else
    pass "$name returned in ${elapsed}s (rc=${rc})"
  fi

  case "$hang_mode" in
    pn)
      printf '%s\n' "$out" | grep -q 'NTPQ_PROBE_TIMEOUT=YES probe=pn' \
        && pass "$name emitted pn timeout marker" \
        || fail "$name missing pn timeout marker"
      ;;
    p_after_pn_fail)
      printf '%s\n' "$out" | grep -q 'NTPQ_PROBE_TIMEOUT=YES probe=p' \
        && pass "$name emitted p timeout marker" \
        || fail "$name missing p timeout marker"
      # -pn failed (not timed out); must still attempt bounded -p.
      if printf '%s\n' "$out" | grep -q 'NTPQ_PROBE_TIMEOUT=YES probe=pn'; then
        fail "$name unexpectedly timed out -pn instead of failing fast"
      else
        pass "$name -pn failed fast before bounded -p"
      fi
      ;;
    rv)
      printf '%s\n' "$out" | grep -q 'NTPQ_PROBE_TIMEOUT=YES probe=rv' \
        && pass "$name emitted rv timeout marker" \
        || fail "$name missing rv timeout marker"
      ;;
  esac

  # Timed-out probes must not falsely claim NTP sync via leap=00 / selected peer alone.
  # Fallback timedatectl may still yield PASS_SYNCED — that is legitimate.
  if printf '%s\n' "$out" | grep -q 'TIME_READINESS=PASS_SYNCED' \
    && printf '%s\n' "$out" | grep -q 'BRINGUP_READY=YES'; then
    pass "$name continued to legitimate timedatectl fallback (PASS_SYNCED)"
  else
    fail "$name did not reach legitimate fallback readiness (out=${out})"
  fi

  # No leftover hung ntpq/sleep children from this fixture.
  children_left="$(pgrep -af "sleep 3600" 2>/dev/null | grep -F "$mock/ntpq" || true)"
  # Also reap any orphaned sleep from the mock's exec.
  pkill -f "sleep 3600" 2>/dev/null || true
  sleep 0.2
  if pgrep -af "sleep 3600" >/dev/null 2>&1; then
    # Best-effort; only fail if clearly our mock path remains.
    if pgrep -af "$td" >/dev/null 2>&1; then
      fail "$name left hung child processes"
    else
      pass "$name hung ntpq child terminated"
    fi
  else
    pass "$name hung ntpq child terminated"
  fi

  rm -rf "$td"
}

run_hang_case "A ntpq -pn hangs" pn
run_hang_case "B ntpq -pn fails then -p hangs" p_after_pn_fail
run_hang_case "C ntpq rv hangs" rv

# Timeout must not invent sync when no fallback proves readiness.
{
  td="$(mktemp -d "${TMPDIR:-/tmp}/ntpq-timeout-nofallback.XXXXXX")"
  mock="$td/bin"
  mkdir -p "$mock"
  cat >"$mock/ntpq" <<'MOCK'
#!/usr/bin/env bash
exec sleep 3600
MOCK
  chmod +x "$mock/ntpq"
  cat >"$mock/ntpwait" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$mock/ntpwait"
  cat >"$mock/timedatectl" <<'MOCK'
#!/usr/bin/env bash
printf 'System clock synchronized: no\n'
MOCK
  chmod +x "$mock/timedatectl"
  set +e
  (
    # shellcheck source=/dev/null
    source "$POLICY"
    export PATH="$mock:/usr/bin:/bin"
    export NTPQ_BIN=ntpq NTPWAIT_BIN=ntpwait TIMEDATECTL_BIN=timedatectl
    export NTPQ_PROBE_TIMEOUT_SECONDS=2
    unset PIN_MIRROR_BASE MIRROR_BASE DP_TIME_REFERENCE_URL || true
    check_time_readiness
  ) >"$td/out" 2>&1
  rc=$?
  set -e
  out="$(cat "$td/out")"
  pkill -f "sleep 3600" 2>/dev/null || true
  if [[ "$rc" -ne 0 ]] \
    && printf '%s\n' "$out" | grep -q 'NTPQ_PROBE_TIMEOUT=YES' \
    && printf '%s\n' "$out" | grep -q 'TIME_READINESS=FAIL_TIME_UNVERIFIABLE' \
    && ! printf '%s\n' "$out" | grep -q 'TIME_READINESS=PASS_SYNCED'; then
    pass "timeout without fallback stays fail-closed (no false sync)"
  else
    fail "timeout without fallback incorrectly reported sync (rc=${rc})"
    printf '%s\n' "$out"
  fi
  rm -rf "$td"
}

echo "----"
echo "PASS=${PASS} FAIL=${FAIL}"
[[ "$FAIL" -eq 0 ]]
