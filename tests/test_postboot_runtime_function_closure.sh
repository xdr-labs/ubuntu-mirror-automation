#!/usr/bin/env bash
# Regression: installed/generated Jammy→Noble postboot must be self-contained.
# Field bug: refreshed postboot called dp_offline_hermetic_fixtures_enabled but
# that helper lived only in the outer wrapper/runner — producing
# "command not found" at check_basic_network_route runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh.in"
GENERATED="${ROOT}/client/dp-offline-upgrade-jammy-to-noble.sh"
RENDER="${ROOT}/tests/lib/render_offline_upgrade_stub.py"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

[[ -f "$TEMPLATE" && -f "$GENERATED" && -f "$RENDER" ]] || {
  echo "missing sources"
  exit 1
}

TMP="$(mktemp -d /tmp/postboot-fn-closure.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Template must embed hermetic escapes inside POSTBOOT_HDR (not only outer wrapper).
python3 - "$TEMPLATE" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
m = re.search(r"cat <<'POSTBOOT_HDR'\n(.*?)\nPOSTBOOT_HDR", text, re.S)
if not m:
    raise SystemExit("POSTBOOT_HDR missing from template")
hdr = m.group(1)
if "@@HERMETIC_ESCAPES_HELPER@@" not in hdr:
    raise SystemExit("POSTBOOT_HDR missing @@HERMETIC_ESCAPES_HELPER@@")
if "dp_offline_hermetic_fixtures_enabled" not in hdr:
    raise SystemExit("POSTBOOT_HDR missing hermetic fixtures call site")
# Outer wrapper still has its own copy; runner also has one — require >=1 in HDR.
print("ok")
PY
pass "template POSTBOOT_HDR embeds hermetic escapes token"

extract_postboot_payload() {
  local src="$1" dest="$2"
  python3 - "$src" "$dest" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
dest = Path(sys.argv[2])

def body(marker):
    m = re.search(r"<<'POSTBOOT_%s'\n" % marker, text)
    if not m:
        return None
    start = m.end()
    c = re.search(r"(?m)^POSTBOOT_%s\s*$" % marker, text[start:])
    if not c:
        raise SystemExit("unclosed POSTBOOT_" + marker)
    return text[start:start + c.start()]

hdr = body("HDR")
main = body("MAIN")
if hdr is None or main is None:
    raise SystemExit("POSTBOOT_HDR/MAIN missing in " + sys.argv[1])
dest.write_text(hdr + main, encoding="utf-8")
PY
  chmod 0755 "$dest"
}

# --- Static closure on generated client payload --------------------------------
extract_postboot_payload "$GENERATED" "$TMP/postboot.generated.sh"
bash -n "$TMP/postboot.generated.sh" || {
  fail "generated postboot payload syntax error"
  echo "PASS=${PASS} FAIL=${FAIL}"
  exit 1
}

if grep -q 'dp_offline_hermetic_fixtures_enabled()' "$TMP/postboot.generated.sh" \
  && grep -q 'dp_offline_hermetic_test_mode()' "$TMP/postboot.generated.sh"; then
  pass "generated postboot defines hermetic fixture helpers"
else
  fail "generated postboot missing hermetic fixture helper definitions"
fi

# No unresolved build tokens in installed payload.
if grep -E '@@[A-Z0-9_]+@@' "$TMP/postboot.generated.sh"; then
  fail "generated postboot still has unresolved @@ tokens"
else
  pass "generated postboot has no unresolved placeholders"
fi

# Audit shell-function closure on the postboot path (ignore embedded python/awk).
python3 - "$TMP/postboot.generated.sh" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")

# Strip comment lines and single-quoted heredoc bodies (embedded python helpers).
lines = []
in_sq_heredoc = None
for line in text.splitlines():
    if in_sq_heredoc is not None:
        if line.strip() == in_sq_heredoc:
            in_sq_heredoc = None
        continue
    m = re.search(r"<<-?\s*'([^']+)'", line)
    if m:
        in_sq_heredoc = m.group(1)
        lines.append(line)
        continue
    if line.lstrip().startswith("#"):
        continue
    lines.append(line)
shell = "\n".join(lines)

defs = set(re.findall(r"(?m)^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{", shell))
defs.update(re.findall(r"(?m)^([A-Za-z_][A-Za-z0-9_]*)\s+\(\)\s*\{", shell))

# Field-critical references that must resolve inside the installed payload.
required_refs = [
    "dp_offline_hermetic_fixtures_enabled",
    "dp_offline_hermetic_test_mode",
    "check_basic_network_route",
    "check_time_readiness",
    "run_ntpq_probe",
    "run_ntpwait_probe",
    "check_and_repair_dns_resolver",
    "detect_aws_upgrade_profile",
    "validate_aws_post_hop_kernel_gate",
    "validate_generic_running_kernel_postboot",
    "write_state",
    "durable_atomic_write",
]
missing = [n for n in required_refs if n not in defs]
# Ensure call sites exist for hermetic + route + ntpq.
for needle in (
    "dp_offline_hermetic_fixtures_enabled",
    "check_basic_network_route",
    "run_ntpq_probe",
):
    if needle not in shell:
        missing.append("call:" + needle)
missing = sorted(set(missing))
if missing:
    raise SystemExit("POSTBOOT_RUNTIME_FUNCTION_CLOSURE=FAIL missing=" + ",".join(missing))
print(
    "POSTBOOT_RUNTIME_FUNCTION_CLOSURE=PASS defs=%d required=%d"
    % (len(defs), len(required_refs))
)
PY
pass "generated postboot runtime function closure PASS"

# --- Production path: no command-not-found; real route validation -------------
{
  root="$TMP/prod-root"
  mkdir -p "$root/var/log/aella" "$root/opt/aelladata/os-upgrade/offline" "$root/usr/bin"
  # Fake ip that returns a default route without needing real networking.
  cat >"$root/usr/bin/ip" <<'IP'
#!/usr/bin/env bash
if [[ "${1:-}" == "-4" && "${2:-}" == "route" && "${3:-}" == "show" && "${4:-}" == "default" ]]; then
  printf 'default via 192.0.2.1 dev eth0 proto dhcp metric 100\n'
  exit 0
fi
exit 0
IP
  chmod +x "$root/usr/bin/ip"

  # Extract helper defs only (drop shebang/set/exec/main so sourcing is safe).
  python3 - "$TMP/postboot.generated.sh" "$TMP/route_helpers.sh" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text(encoding="utf-8")
lines = text.splitlines(True)
out = []
for line in lines:
    if line.startswith("#!"):
        continue
    if line.startswith("set -"):
        continue
    if line.startswith("exec >>"):
        continue
    if re.match(r"^main\(\)", line):
        break
    out.append(line)
Path(sys.argv[2]).write_text("".join(out), encoding="utf-8")
PY

  set +e
  out="$(
    # shellcheck disable=SC1090
    source "$TMP/route_helpers.sh"
    LOG_FILE="$root/var/log/aella/offline_os_upgrade.log"
    log() { printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2"; }
    PATH="$root/usr/bin:$PATH"
    unset MM_HERMETIC_TEST_MODE STELLAR_OFFLINE_FAKE_DEFAULT_ROUTE || true
    check_basic_network_route 2>&1
  )"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]] \
    && ! printf '%s\n' "$out" | grep -qi 'command not found' \
    && printf '%s\n' "$out" | grep -q 'DEFAULT_ROUTE_CHECK=PASS'; then
    pass "production route validation works without command-not-found"
  else
    fail "production route validation failed (rc=${rc} out=${out})"
  fi
}

# --- Hermetic fake-route fixture still works ----------------------------------
{
  set +e
  out="$(
    # shellcheck disable=SC1090
    source "$TMP/route_helpers.sh"
    log() { printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2"; }
    export MM_HERMETIC_TEST_MODE=1
    export STELLAR_OFFLINE_FAKE_DEFAULT_ROUTE=1
    check_basic_network_route 2>&1
  )"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]] && ! printf '%s\n' "$out" | grep -qi 'command not found'; then
    pass "hermetic fake default route fixture works"
  else
    fail "hermetic fake route fixture failed (rc=${rc} out=${out})"
  fi

  set +e
  out="$(
    # shellcheck disable=SC1090
    source "$TMP/route_helpers.sh"
    log() { printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2"; }
    export MM_HERMETIC_TEST_MODE=1
    export STELLAR_OFFLINE_FAKE_DEFAULT_ROUTE=0
    check_basic_network_route 2>&1
  )"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]] && ! printf '%s\n' "$out" | grep -qi 'command not found'; then
    pass "hermetic fake route=0 fails closed without command-not-found"
  else
    fail "hermetic fake route=0 semantics broken (rc=${rc})"
  fi
}

# Production without hermetic mode must ignore STELLAR_OFFLINE_FAKE_DEFAULT_ROUTE.
{
  set +e
  out="$(
    # shellcheck disable=SC1090
    source "$TMP/route_helpers.sh"
    log() { printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2"; }
    unset MM_HERMETIC_TEST_MODE || true
    export STELLAR_OFFLINE_FAKE_DEFAULT_ROUTE=1
    # No fake ip success path if hermetic ignored — provide real ip fake still.
    PATH="$TMP/prod-root/usr/bin:$PATH"
    check_basic_network_route 2>&1
  )"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]] \
    && printf '%s\n' "$out" | grep -q 'DEFAULT_ROUTE_CHECK=PASS' \
    && ! printf '%s\n' "$out" | grep -qi 'command not found'; then
    pass "production ignores fake-route env without hermetic mode"
  else
    fail "production hermetic escape leak or command-not-found (rc=${rc} out=${out})"
  fi
}

echo "----"
echo "POSTBOOT_RUNTIME_FUNCTION_CLOSURE=PASS"
echo "PASS=${PASS} FAIL=${FAIL}"
[[ "$FAIL" -eq 0 ]]
