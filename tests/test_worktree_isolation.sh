#!/usr/bin/env bash
# tests/test_worktree_isolation.sh — generators/fixtures must not pollute tracked tree
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/worktree_fingerprint.sh
source "${ROOT}/tests/lib/worktree_fingerprint.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
FP_A="${WORKDIR}/fp-a"
FP_B="${WORKDIR}/fp-b"
cleanup() {
  # Best-effort orphan sweep for this suite's synthetic child token
  local pid cmd
  while IFS= read -r pid; do
    [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || continue
    [[ -r "/proc/${pid}/cmdline" ]] || continue
    cmd="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
    case "$cmd" in
      *worktree-isolation-child*) kill "$pid" 2>/dev/null || true ;;
    esac
  done < <(ps -eo pid= 2>/dev/null || true)
  rm -rf "$WORKDIR"
  rm -f "${ROOT}/tests/.worktree-isolation-should-not-exist"
}
trap cleanup EXIT

MIRROR_BASE="${TEST_MIRROR_BASE:-http://192.0.2.10}"
SEL_ROOT="${TEST_SELECTIVE_ROOT:-/var/spool/apt-mirror/selective}"

echo "[test] A. generator isolation (temp output; tracked client/artifacts unchanged)"
worktree_save_fingerprint "$ROOT" "$FP_A"
can_live_build=0
if [[ -f "${SEL_ROOT}/keys/ubuntu-mirror-selective.gpg" \
   && -f "${SEL_ROOT}/state/READY" ]] \
   && curl -fsS --connect-timeout 3 --max-time 5 -o /dev/null \
        "${MIRROR_BASE}/hops/xenial-to-bionic/ubuntu/dists/xenial/Release" 2>/dev/null; then
  can_live_build=1
fi

if [[ "$can_live_build" -eq 1 ]]; then
  for hop_py in \
    build_client_xenial_to_bionic.py \
    build_client_bionic_to_focal.py \
    build_client_focal_to_jammy.py
  do
    out="${WORKDIR}/out-${hop_py%.py}"
    set +e
    python3 "${ROOT}/scripts/lib/${hop_py}" \
      --project-root "$ROOT" \
      --mirror-base "$MIRROR_BASE" \
      --selective-root "$SEL_ROOT" \
      --output-dir "$out" \
      >"${WORKDIR}/build-${hop_py}.log" 2>&1
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      fail "generator ${hop_py} rc=${rc}"
      tail -20 "${WORKDIR}/build-${hop_py}.log" || true
      continue
    fi
    if compgen -G "${out}/dp-offline-upgrade-*.sh" >/dev/null; then
      pass "generator ${hop_py} wrote temp output"
    else
      fail "generator ${hop_py} missing temp script"
    fi
  done
  worktree_save_fingerprint "$ROOT" "$FP_B"
  if worktree_diff_fingerprint "$FP_A" "$FP_B"; then
    pass "tracked client/artifacts unchanged after temp generators"
  else
    fail "generator contaminated tracked tree"
  fi
else
  echo "  SKIP: live selective mirror unavailable for generator isolation"
fi

echo "[test] B. fixture isolation (unsupported-schema copy only)"
FIX="${ROOT}/tests/fixtures/dp-os-upgrade/unsupported-schema/preflight-summary.json"
if [[ -f "$FIX" ]]; then
  before="$(sha256sum "$FIX" | awk '{print $1}')"
  dst="${WORKDIR}/pf-unsupported"
  python3 - <<PY
import json,shutil,pathlib,datetime
src=pathlib.Path("$FIX").parent
dst=pathlib.Path("$dst")
if dst.exists(): shutil.rmtree(dst)
shutil.copytree(src,dst)
p=dst/"preflight-summary.json"
d=json.load(open(p))
d["completed_at_utc"]=datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(d, open(p,"w"), indent=2)
PY
  after="$(sha256sum "$FIX" | awk '{print $1}')"
  [[ "$before" == "$after" ]] && pass "original unsupported-schema fixture hash unchanged" \
    || fail "tracked fixture mutated"
  grep -q 'completed_at_utc' "${dst}/preflight-summary.json" \
    && pass "temp fixture timestamp updated" || fail "temp fixture missing timestamp"
else
  fail "missing unsupported-schema fixture"
fi

echo "[test] C. timeout cleanup (synthetic child + no tracked writes)"
MARKER="${ROOT}/tests/.worktree-isolation-should-not-exist"
rm -f "$MARKER"
child_script="${WORKDIR}/worktree-isolation-child.sh"
cat >"$child_script" <<EOF
#!/usr/bin/env bash
# worktree-isolation-child
set -euo pipefail
sleep 30
printf 'polluted\n' >"$MARKER"
EOF
chmod 0755 "$child_script"
set +e
timeout --signal=TERM --kill-after=2s 1s bash "$child_script"
rc=$?
set -e
[[ "$rc" -eq 124 || "$rc" -eq 137 ]] && pass "synthetic timeout fired" || fail "timeout rc=${rc}"
sleep 0.5
clear_left="$(ps -eo args= | grep -F 'worktree-isolation-child' | grep -v grep || true)"
[[ -z "${clear_left// }" ]] && pass "timeout child/orphan cleared" || fail "orphan remains: ${clear_left}"
[[ ! -e "$MARKER" ]] && pass "tracked marker file not written" || {
  fail "marker file written despite timeout"
  rm -f "$MARKER"
}

echo "[test] D. contamination guard (detect drift; no false positive on baseline)"
mkdir -p "${WORKDIR}/sim-before" "${WORKDIR}/sim-after"
printf 'aaa  path/a\n' >"${WORKDIR}/sim-before/tracked.sha256"
printf 'bbb  path/a\n' >"${WORKDIR}/sim-after/tracked.sha256"
: >"${WORKDIR}/sim-before/untracked.list"
: >"${WORKDIR}/sim-after/untracked.list"
if worktree_diff_fingerprint "${WORKDIR}/sim-before" "${WORKDIR}/sim-after"; then
  fail "sim drift not detected"
else
  pass "guard detects tracked drift"
fi
worktree_save_fingerprint "$ROOT" "${WORKDIR}/base-d"
worktree_save_fingerprint "$ROOT" "${WORKDIR}/after-d"
if worktree_diff_fingerprint "${WORKDIR}/base-d" "${WORKDIR}/after-d"; then
  pass "unchanged baseline not flagged (existing Phase 2 dirty tree OK)"
else
  fail "false positive contamination on unchanged tree"
fi

echo "[test] E. normal completion hygiene"
worktree_save_fingerprint "$ROOT" "${WORKDIR}/base-e"
worktree_save_fingerprint "$ROOT" "${WORKDIR}/after-e"
if worktree_diff_fingerprint "${WORKDIR}/base-e" "${WORKDIR}/after-e"; then
  pass "no additional tracked/untracked drift"
else
  fail "unexpected drift during hygiene check"
fi
orphans="$(ps -eo args= | grep -E 'fixture-dp-offline-upgrade|worktree-isolation-child' | grep -v grep || true)"
[[ -z "${orphans// }" ]] && pass "no related fixture processes" || fail "orphan processes: ${orphans}"

python3 - "${ROOT}/scripts/lib" <<'PY' && pass "builders gate client refresh on production output dir" || fail "builder gate missing"
from pathlib import Path
import sys
root = Path(sys.argv[1])
for name in (
    "build_client_xenial_to_bionic.py",
    "build_client_bionic_to_focal.py",
    "build_client_focal_to_jammy.py",
    "build_client_jammy_to_noble.py",
):
    text = (root / name).read_text()
    assert "is_production_output_dir(project_root, out_dir)" in text, name
PY

# Refuse path may still pass --output-dir artifacts/client expecting FAIL.
# Successful production rebuild into tracked artifacts/client must not remain.
if grep -nE 'pass "production artifacts/client rebuilt|isolated signed rebuild' \
  "${ROOT}/tests/test_client_manifest_signing.sh" | grep -q 'production artifacts/client rebuilt'; then
  fail "signing test still claims tracked artifacts/client rebuild"
elif grep -q 'isolated signed rebuild (tracked client/artifacts unchanged)' \
  "${ROOT}/tests/test_client_manifest_signing.sh"; then
  pass "signing test uses isolated signed rebuild"
else
  fail "signing test missing isolated rebuild assertion"
fi

if grep -nE 'p="\$FIX/unsupported-schema/preflight-summary.json"' \
  "${ROOT}/tests/test_dp_os_upgrade.sh"; then
  fail "os-upgrade test still writes unsupported-schema in place"
else
  pass "os-upgrade unsupported-schema uses fixture copy"
fi

if command -v shellcheck >/dev/null 2>&1; then
  # SC2009: process inventory via ps|grep; SC2016: intentional single-quoted pattern check
  shellcheck -x -e SC1091,SC2015,SC2034,SC2119,SC2120,SC2317,SC2009,SC2016 \
    "${ROOT}/tests/lib/worktree_fingerprint.sh" \
    "${ROOT}/tests/test_worktree_isolation.sh" \
    && pass "shellcheck isolation helpers" || fail "shellcheck isolation"
else
  echo "  SKIP: shellcheck not installed"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL WORKTREE ISOLATION TESTS PASSED"
  exit 0
fi
echo "SOME WORKTREE ISOLATION TESTS FAILED"
exit 1
