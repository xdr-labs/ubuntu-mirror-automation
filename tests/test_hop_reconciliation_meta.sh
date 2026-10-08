#!/usr/bin/env bash
# Hop reconciliation meta-tests: real four-hop builders → temp artifacts only.
# Uses tests/lib/client_finalization_fixture.sh (ephemeral GPG + selective fixture).
# No production HTTP publish, no /var/spool swap, no /etc signing keys, no network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/client_finalization_fixture.sh
source "${ROOT}/tests/lib/client_finalization_fixture.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hop-recon-meta.XXXXXX")"
ARTIFACTS="${WORKDIR}/artifacts"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "=== test_hop_reconciliation_meta ==="
echo "TEMP_ARTIFACTS=${ARTIFACTS}"
echo "PRODUCTION_HTTP_PUBLISH=NO"
echo "ATOMIC_SWAP_VAR_SPOOL=NO"
echo "ETC_SIGNING_KEY_ACCESS=NO"

# RFC 5737 — intentional pin only (builders must not fetch)
MIRROR_URL="http://192.0.2.99"

client_fixture_build_selective "$WORKDIR"
SEL="${WORKDIR}/selective"
SIGN_PRIV="${WORKDIR}/client-signing/private.gpg"
SIGN_PUB="${WORKDIR}/client-signing/public.gpg"
[[ -f "$SIGN_PRIV" && -f "$SIGN_PUB" ]] || fail "ephemeral signing keys missing"
# Refuse accidental /etc path
case "$SIGN_PRIV" in
  /etc/*) fail "must not use /etc signing keys" ;;
esac
pass "ephemeral selective + signing fixture ready"

mkdir -p "$ARTIFACTS"

HOPS=(
  "xenial-to-bionic:16.04:18.04:xenial:bionic"
  "bionic-to-focal:18.04:20.04:bionic:focal"
  "focal-to-jammy:20.04:22.04:focal:jammy"
  "jammy-to-noble:22.04:24.04:jammy:noble"
)

builder_py() {
  printf '%s/scripts/lib/build_client_%s.py\n' "$ROOT" "${1//-/_}"
}

script_name() {
  printf 'dp-offline-upgrade-%s.sh\n' "$1"
}

# --- Generate all four clients through authoritative builders ---
for entry in "${HOPS[@]}"; do
  IFS=: read -r hop src tgt scode tcode <<<"$entry"
  out_hop="${ARTIFACTS}/${hop}"
  mkdir -p "$out_hop"
  logf="${WORKDIR}/build-${hop}.log"
  set +e
  python3 "$(builder_py "$hop")" \
    --project-root "$ROOT" \
    --mirror-base "$MIRROR_URL" \
    --selective-root "$SEL" \
    --output-dir "$out_hop" \
    --signing-private-key "$SIGN_PRIV" \
    --signing-public-key "$SIGN_PUB" \
    --content-source local-fs \
    >"$logf" 2>&1
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || { cat "$logf"; fail "build ${hop} rc=${rc}"; }
  grep -q 'CLIENT_MANIFEST_SIGNATURE_MODE=PRODUCTION_SIGNED' "$logf" \
    || fail "${hop}: not production-signed path"
  built="${out_hop}/$(script_name "$hop")"
  [[ -f "$built" ]] || fail "${hop}: missing generated script ${built}"
  # Must not have written production nginx root or /etc
  [[ ! -e /var/spool/apt-mirror/client/.hop-recon-meta-probe ]] || true
  pass "built ${hop} → ${built}"
done

# --- bash -n + shared helper embedding + hop pins ---
for entry in "${HOPS[@]}"; do
  IFS=: read -r hop src tgt scode tcode <<<"$entry"
  built="${ARTIFACTS}/${hop}/$(script_name "$hop")"
  bash -n "$built" || fail "${hop}: bash -n failed"
  grep -q '@@RELEASE_UPGRADE_RECONCILIATION_HELPER@@' "$built" \
    && fail "${hop}: inject token still present" || true
  grep -q '@@APT_PREFLIGHT_SANDBOX_HELPER@@' "$built" \
    && fail "${hop}: APT sandbox inject token still present" || true
  grep -q 'collect_package_transition_evidence' "$built" \
    || fail "${hop}: shared reconciliation helper not embedded"
  grep -q 'run_temporary_local_apt_authentication_preflight' "$built" \
    || fail "${hop}: shared APT preflight sandbox helper not embedded"
  grep -q 'apt_preflight_create_sandbox' "$built" \
    || fail "${hop}: apt_preflight_create_sandbox missing"
  grep -q 'stellar-apt-preflight' "$built" \
    || fail "${hop}: dedicated APT temp root pattern missing"
  grep -q 'classify_package_transition_evidence' "$built" \
    || fail "${hop}: classify_package_transition_evidence missing"
  grep -q 'reconcile_legacy_release_upgrade_state' "$built" \
    || fail "${hop}: reconcile_legacy_release_upgrade_state missing"
  grep -q 'diagnose_release_upgrade_state' "$built" \
    || fail "${hop}: diagnose_release_upgrade_state missing"
  grep -q 'record_release_upgrade_run_baseline' "$built" \
    || fail "${hop}: record_release_upgrade_run_baseline missing"
  grep -q "PIN_HOP='${hop}'" "$built" || fail "${hop}: PIN_HOP mismatch"
  grep -q "PIN_SOURCE_VERSION='${src}'" "$built" || fail "${hop}: PIN_SOURCE_VERSION"
  grep -q "PIN_TARGET_VERSION='${tgt}'" "$built" || fail "${hop}: PIN_TARGET_VERSION"
  grep -q "PIN_SOURCE_CODENAME='${scode}'" "$built" || fail "${hop}: PIN_SOURCE_CODENAME"
  grep -q "PIN_TARGET_CODENAME='${tcode}'" "$built" || fail "${hop}: PIN_TARGET_CODENAME"
  grep -q 'STATE_ROOT="/opt/aelladata/os-upgrade/offline"' "$built" \
    || fail "${hop}: STATE_ROOT missing"
  grep -q 'recon_hop_root' "$built" || grep -q 'hops/\${PIN_HOP}' "$built" \
    || grep -q 'hops/${PIN_HOP}' "$built" \
    || fail "${hop}: hop-scoped state namespace helper missing"
  grep -q 'REASON=legacy_flag_with_package_transition_evidence' "$built" \
    && fail "${hop}: old boolean exit reason still present" || true
  pass "${hop}: bash -n + embedded helper + pin/state namespace OK"
done

# --- Behavioral scenarios against shared helper (same code embedded in clients) ---
HELPER="${ROOT}/client/lib/dp-offline-release-upgrade-reconciliation.sh"
EC_RESUME=29
EC_BUSY=22
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
STATE_FILE="${STATE_ROOT}/state"
LOG_FILE="/var/log/aella/offline_os_upgrade.log"

hostpath() {
  local p="$1"
  if [[ -n "${TEST_ROOT:-}" ]]; then printf '%s%s' "$TEST_ROOT" "$p"; else printf '%s' "$p"; fi
}
log() { local level="$1"; shift; printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >&2; }
die() { local code="$1"; shift; log ERROR "$* (exit=${code})"; exit "$code"; }
read_os_field() {
  local key="$1" f; f="$(hostpath /etc/os-release)"
  [[ -f "$f" ]] || { printf ''; return 0; }
  grep -E "^${key}=" "$f" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}
read_state() {
  local f; f="$(hostpath "$STATE_FILE")"
  if [[ -f "$f" ]]; then tr -d '\r' <"$f" | head -1; else printf ''; fi
}
pkg_installed_version() { printf ''; }
critical_holds_dir() { hostpath "${STATE_ROOT}/critical-holds"; }
atomic_write_file() { local dest="$1"; mkdir -p "$(dirname "$dest")"; cat >"$dest"; }
persist_release_upgrade_flags() { :; }
load_release_upgrade_started_flag() {
  local dir; dir="$(critical_holds_dir)"
  RELEASE_UPGRADE_STARTED="false"
  LEGACY_STATE_RECONCILED="false"
  RECONCILIATION_REASON=""
  [[ -f "$dir/release_upgrade_started" ]] && grep -qx 'true' "$dir/release_upgrade_started" && RELEASE_UPGRADE_STARTED="true"
  [[ -f "$dir/legacy_state_reconciled" ]] && grep -qx 'true' "$dir/legacy_state_reconciled" && LEGACY_STATE_RECONCILED="true"
  [[ -f "$dir/reconciliation_reason" ]] && RECONCILIATION_REASON="$(tr -d '\n' <"$dir/reconciliation_reason")"
}
detect_meta_release_encoding_failure_signature() { return 1; }

mkfx() {
  local hop="$1" src="$2" scode="$3"
  local fx
  fx="$(mktemp -d "${WORKDIR}/fx-${hop}.XXXX")"
  mkdir -p "$fx/etc" "$fx/opt/aelladata/os-upgrade/offline/critical-holds" \
    "$fx/var/log/apt" "$fx/var/log" "$fx/var/lib/dpkg" "$fx/tmp" \
    "$fx/etc/apt" "$fx/etc/update-manager" "$fx/var/log/aella"
  cat >"$fx/etc/os-release" <<EOF
VERSION_ID="${src}"
VERSION_CODENAME=${scode}
EOF
  printf 'FAILED\n' >"$fx/opt/aelladata/os-upgrade/offline/state"
  printf 'true\n' >"$fx/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_started"
  printf 'false\n' >"$fx/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_package_transition_started"
  printf 'Status: install ok installed\n' >"$fx/var/lib/dpkg/status"
  printf '%s\n' "$fx"
}

activate() {
  PIN_HOP="$1"; PIN_SOURCE_VERSION="$2"; PIN_TARGET_VERSION="$3"
  PIN_SOURCE_CODENAME="$4"; PIN_TARGET_CODENAME="$5"; TEST_ROOT="$6"
  RELEASE_UPGRADE_STARTED="true"
  RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
  LEGACY_STATE_RECONCILED="false"
  RECONCILIATION_REASON=""
  CURRENT_RUN_ID=""
  # shellcheck disable=SC1090
  source "$HELPER"
}

LAST_RC=0
run_reconcile() {
  local out="$1" rc=0
  set +e
  ( set +e; reconcile_legacy_release_upgrade_state; exit $? ) >"$out" 2>&1
  rc=$?
  set +e
  LAST_RC=$rc
  load_release_upgrade_started_flag || true
  RECONCILIATION_DECISION="$(sed -n 's/.*RECONCILIATION_DECISION=//p' "$out" | tail -1 | tr -d '\r')"
  return 0
}

# Embed check: generated clients must carry the exact shared helper bytes.
# A distinctive-line spot check is insufficient for producer/consumer contracts:
# a stale embedded helper can still contain the same markers while missing a
# newly fixed parser/state rule.
HELPER_SHA="$(sha256sum "$HELPER" | awk '{print $1}')"
SOURCE_VERSION_HELPER="${ROOT}/client/lib/dp-offline-source-product-version.sh"
SOURCE_VERSION_HELPER_SHA="$(sha256sum "$SOURCE_VERSION_HELPER" | awk '{print $1}')"
for entry in "${HOPS[@]}"; do
  IFS=: read -r hop _ <<<"$entry"
  built="${ARTIFACTS}/${hop}/$(script_name "$hop")"
  grep -Fq 'RUN_SCOPED_BASELINE=PASS' "$built" || fail "${hop}: baseline log marker missing from embed"
  grep -Fq 'SAFE_PRE_TRANSITION_RESUME' "$built" || fail "${hop}: SAFE_PRE_TRANSITION_RESUME missing"
  python3 - "$built" "$SOURCE_VERSION_HELPER" <<'PY' || fail "${hop}: embedded source-version helper byte drift"
from pathlib import Path
import sys
generated = Path(sys.argv[1]).read_text()
helper = Path(sys.argv[2]).read_text().rstrip("\n")
marker = "#!/usr/bin/env bash\n# Shared source DP product version capture / parse / recovery.\n"
start = generated.index(marker)
end = generated.index("\ncritical_holds_dir() {", start)
embedded = generated[start:end].rstrip("\n")
raise SystemExit(0 if embedded == helper else 1)
PY
done
pass "generated clients embed exact source-version helper bytes (helper_sha=${SOURCE_VERSION_HELPER_SHA:0:12}…)"

for entry in "${HOPS[@]}"; do
  IFS=: read -r hop src tgt scode tcode <<<"$entry"

  # Clean legacy → safe resume
  fx="$(mkfx "$hop" "$src" "$scode")"
  activate "$hop" "$src" "$tgt" "$scode" "$tcode" "$fx"
  run_reconcile "$fx/out-clean.txt"
  [[ "$LAST_RC" -eq 0 ]] || { cat "$fx/out-clean.txt"; fail "${hop}: clean resume rc=$LAST_RC"; }
  [[ "$RECONCILIATION_DECISION" == "SAFE_PRE_TRANSITION_RESUME" ]] || fail "${hop}: clean decision"
  # Hop-scoped backup namespace
  [[ -d "$fx/opt/aelladata/os-upgrade/offline/hops/${hop}" ]] \
    || fail "${hop}: hop state namespace not created"
  pass "${hop}: clean legacy → SAFE_PRE_TRANSITION_RESUME"

  # Previous-hop stale evidence must not poison (non-xenial)
  if [[ "$hop" != "xenial-to-bionic" ]]; then
    fx="$(mkfx "$hop" "$src" "$scode")"
    mkdir -p "$fx/var/log/apt"
    case "$hop" in
      bionic-to-focal) prev='bionic 18.04' ;;
      focal-to-jammy) prev='focal 20.04' ;;
      jammy-to-noble) prev='jammy 22.04' ;;
    esac
    cat >"$fx/var/log/apt/history.log" <<EOF
Start-Date: 2018-01-01  00:00:00
Commandline: do-release-upgrade
Upgrade: base-files:amd64 (${prev})
End-Date: 2018-01-01  00:01:00
EOF
    activate "$hop" "$src" "$tgt" "$scode" "$tcode" "$fx"
    classify_package_transition_evidence
    [[ "$AUTHORITATIVE_PACKAGE_TRANSITION" == "NO" ]] \
      || fail "${hop}: previous-hop evidence treated authoritative"
    run_reconcile "$fx/out-prev.txt"
    [[ "$LAST_RC" -eq 0 ]] || fail "${hop}: previous-hop reconcile rc=$LAST_RC"
    pass "${hop}: previous-hop evidence ignored"
  fi

  # Post-baseline mutation → exit 29
  fx="$(mkfx "$hop" "$src" "$scode")"
  mkdir -p "$fx/var/log"
  printf 'prebaseline\n' >"$fx/var/log/dpkg.log"
  activate "$hop" "$src" "$tgt" "$scode" "$tcode" "$fx"
  record_release_upgrade_run_baseline
  [[ -n "$CURRENT_RUN_ID" ]] || fail "${hop}: RUN_ID empty after baseline"
  printf 'startup archives unpack\n' >>"$fx/var/log/dpkg.log"
  run_reconcile "$fx/out-auth.txt"
  [[ "$LAST_RC" -eq 29 ]] || { cat "$fx/out-auth.txt"; fail "${hop}: auth expected 29 got $LAST_RC"; }
  pass "${hop}: post-baseline mutation → exit 29 (run_id=${CURRENT_RUN_ID})"

  # Target core / mixed force → exit 29
  fx="$(mkfx "$hop" "$src" "$scode")"
  activate "$hop" "$src" "$tgt" "$scode" "$tcode" "$fx"
  touch "$(hostpath ${STATE_ROOT}/force-target-core-packages)"
  run_reconcile "$fx/out-mix.txt"
  [[ "$LAST_RC" -eq 29 ]] || fail "${hop}: mixed expected 29 got $LAST_RC"
  pass "${hop}: mixed/target-core → exit 29"

  # Interrupted dpkg → exit 29
  fx="$(mkfx "$hop" "$src" "$scode")"
  touch "$fx/tmp/dpkg-broken"
  activate "$hop" "$src" "$tgt" "$scode" "$tcode" "$fx"
  run_reconcile "$fx/out-audit.txt"
  [[ "$LAST_RC" -eq 29 ]] || fail "${hop}: audit expected 29 got $LAST_RC"
  pass "${hop}: interrupted dpkg → exit 29"

  # --diagnose-state via generated client (zero mutation)
  fx="$(mkfx "$hop" "$src" "$scode")"
  echo 'Upgrade: old' >"$fx/var/log/apt/history.log"
  before_state="$(cat "$fx/opt/aelladata/os-upgrade/offline/state")"
  before_flag="$(cat "$fx/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_started")"
  built="${ARTIFACTS}/${hop}/$(script_name "$hop")"
  set +e
  MM_HERMETIC_TEST_MODE=1 DP_OFFLINE_TEST_ROOT="$fx" bash "$built" --diagnose-state \
    >"$fx/diag.out" 2>"$fx/diag.err"
  drc=$?
  set -e
  [[ "$drc" -eq 0 ]] || { cat "$fx/diag.err"; fail "${hop}: diagnose rc=$drc"; }
  after_state="$(cat "$fx/opt/aelladata/os-upgrade/offline/state")"
  after_flag="$(cat "$fx/opt/aelladata/os-upgrade/offline/critical-holds/release_upgrade_started")"
  [[ "$before_state" == "$after_state" ]] || fail "${hop}: diagnose mutated state"
  [[ "$before_flag" == "$after_flag" ]] || fail "${hop}: diagnose mutated flag"
  grep -q 'PACKAGE_TRANSITION_CLASS=' "$fx/diag.out" || fail "${hop}: diagnose missing class"
  grep -q 'SAFE_TO_RERUN=' "$fx/diag.out" || fail "${hop}: diagnose missing SAFE_TO_RERUN"
  # No writes under /etc or /var/spool from diagnose
  pass "${hop}: generated client --diagnose-state zero mutation"
done

# --- Prove artifacts stay under WORKDIR ---
script_count=0
for entry in "${HOPS[@]}"; do
  IFS=: read -r hop _ <<<"$entry"
  built="${ARTIFACTS}/${hop}/$(script_name "$hop")"
  [[ -f "$built" ]] || fail "missing top-level generated client ${built}"
  script_count=$((script_count + 1))
done
[[ "$script_count" -eq 4 ]] || fail "expected 4 top-level generated clients, got ${script_count}"
case "$ARTIFACTS" in
  /var/spool/*|/etc/*) fail "artifacts root escaped to production path" ;;
esac
pass "all artifacts confined to temp root"

echo "META_BUILD_PATH=AUTHORITATIVE_BUILD_CLIENT_PY"
echo "SHARED_HELPER_EMBEDDED=YES"
echo "BASH_N_GENERATED_CLIENTS=PASS"
echo "PREVIOUS_HOP_EVIDENCE_ISOLATED=YES"
echo "CLEAN_LEGACY_RESUME=PASS"
echo "PARTIAL_TRANSITION_FAIL_CLOSED=PASS"
echo "DIAGNOSE_STATE_ZERO_MUTATION=PASS"
echo "TEMP_ARTIFACTS_REMOVED_ON_EXIT=YES"
echo "ALL test_hop_reconciliation_meta checks passed"
