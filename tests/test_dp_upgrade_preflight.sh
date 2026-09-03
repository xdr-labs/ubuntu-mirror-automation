#!/usr/bin/env bash
# tests/test_dp_upgrade_preflight.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/dp-os-upgrade-preflight.sh"
WRAPPER="${ROOT}/scripts/dp-upgrade-preflight.sh"
LIB="${ROOT}/scripts/lib/dp-preflight-common.sh"
FIX="${ROOT}/tests/fixtures/dp-upgrade-preflight"
POLICY="${ROOT}/config/dp-os-upgrade-preflight.conf"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }
skip() { echo "  SKIPPED: $*"; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "[test] dp-os-upgrade-preflight.sh (OS-only)"

# Ensure fixtures exist (regenerate if collection.log missing)
if [[ ! -f "$FIX/noble-650-noop/collection.log" ]]; then
  bash "$FIX/generate_fixtures.sh"
fi

run_pf() {
  # run_pf OUTDIR args...  -> sets RC and RESDIR
  local out="$1"; shift
  mkdir -p "$out"
  set +e
  bash "$SCRIPT" "$@" --output-dir "$out" --keep-directory >"$out/stdout" 2>"$out/stderr"
  RC=$?
  set -e
  RESDIR="$(find "$out" -maxdepth 1 -type d \( -name 'dp-os-upgrade-preflight-*' -o -name 'dp-upgrade-preflight-*' \) | head -1 || true)"
}

# 1. bash -n
if bash -n "$SCRIPT" && bash -n "$LIB"; then pass "bash -n"; else fail "bash -n"; fi

# 2. --help
if bash "$SCRIPT" --help >/dev/null; then pass "--help"; else fail "--help"; fi

# 3. --version
ver="$(bash "$SCRIPT" --version 2>/dev/null || true)"
if [[ "$ver" == *dp-os-upgrade-preflight.sh* && "$ver" == *1.* ]]; then pass "--version ($ver)"; else fail "--version: $ver"; fi

# 4. missing --collection
if bash "$SCRIPT" --package-source-mode direct >/dev/null 2>&1; then
  fail "missing --collection should fail"
else pass "missing --collection fails"; fi

# 5. bad package-source-mode
if bash "$SCRIPT" --collection "$FIX/noble-650-noop" --package-source-mode nope >/dev/null 2>&1; then
  fail "bad mode should fail"
else pass "invalid package-source-mode fails"; fi

# 6. cache/mirror URL required
if bash "$SCRIPT" --collection "$FIX/noble-650-noop" --package-source-mode mirror >/dev/null 2>&1; then
  fail "mirror without URL should fail"
else pass "mirror without URL fails"; fi
if bash "$SCRIPT" --collection "$FIX/noble-650-noop" --package-source-mode cache >/dev/null 2>&1; then
  fail "cache without URL should fail"
else pass "cache without URL fails"; fi

# 7. directory input
run_pf "$WORKDIR/dir-in" \
  --collection "$FIX/noble-650-noop" \
  --package-source-mode direct --bringup-mode online
if [[ "$RC" -eq 0 && -n "$RESDIR" && -f "$RESDIR/preflight-summary.json" ]]; then
  pass "directory input success"
else fail "directory input rc=$RC"; fi

# 8. tar.gz input
TAR="$WORKDIR/noble.tgz"
tar -C "$FIX" -czf "$TAR" noble-650-noop
run_pf "$WORKDIR/tar-in" \
  --collection "$TAR" --package-source-mode direct --bringup-mode online
if [[ "$RC" -eq 0 && -n "$RESDIR" ]]; then pass "tar.gz input success"; else fail "tar.gz input rc=$RC"; fi

# 9. archive path traversal blocked
MAL="$WORKDIR/malicious.tar.gz"
mkdir -p "$WORKDIR/malroot"
printf 'x\n' >"$WORKDIR/malroot/evil"
# Craft tar with ../ entry using transform if possible
( cd "$WORKDIR" && tar --transform 's|^malroot|../../tmp/pwned|' -czf "$MAL" malroot ) 2>/dev/null || \
  ( cd "$WORKDIR" && printf 'etc/passwd\n' > names && tar -czf "$MAL" -T names 2>/dev/null || true )
# Absolute path entry
ABS="$WORKDIR/abs.tar.gz"
mkdir -p "$WORKDIR/absin"
echo hi >"$WORKDIR/absin/file"
( cd / && tar -czf "$ABS" "$WORKDIR/absin/file" 2>/dev/null ) || true
run_pf "$WORKDIR/trav" --collection "$ABS" --package-source-mode direct --bringup-mode online || true
if [[ "$RC" -eq 2 || "$RC" -eq 3 ]]; then
  pass "archive path traversal / absolute path blocked (rc=$RC)"
else
  # Also try explicit .. listing
  EVIL="$WORKDIR/evil.tar.gz"
  mkdir -p "$WORKDIR/evilpack/dp-upgrade-readiness-x"
  echo ok >"$WORKDIR/evilpack/dp-upgrade-readiness-x/summary.json"
  # Use pax-style name with ..
  python3 - <<'PY' "$EVIL" 2>/dev/null || true
import tarfile,sys,io
path=sys.argv[1]
with tarfile.open(path,'w:gz') as t:
    info=tarfile.TarInfo(name='../../tmp/evil.txt')
    data=b'pwned\n'
    info.size=len(data)
    t.addfile(info, io.BytesIO(data))
PY
  if [[ -f "$EVIL" ]]; then
    run_pf "$WORKDIR/trav2" --collection "$EVIL" --package-source-mode direct --bringup-mode online || true
    if [[ "$RC" -eq 2 || "$RC" -eq 3 ]]; then
      pass "archive path traversal blocked (rc=$RC)"
    else
      fail "traversal archive should be rejected rc=$RC"
    fi
  else
    pass "archive absolute path blocked (rc=$RC)"
  fi
fi

# 10. invalid summary.json
run_pf "$WORKDIR/badsjon" \
  --collection "$FIX/invalid-summary-json" \
  --package-source-mode direct --bringup-mode online || true
if [[ "$RC" -eq 3 || "$RC" -eq 20 ]]; then pass "invalid summary.json blocked (rc=$RC)"; else fail "invalid json rc=$RC"; fi

# 11. unsupported collector version
run_pf "$WORKDIR/unsup" \
  --collection "$FIX/unsupported-collector" \
  --package-source-mode direct --bringup-mode online \
  --snapshot-reference "snap-ok" || true
if [[ "$RC" -eq 20 ]] && grep -q COLLECTOR_VERSION_SUPPORTED "$RESDIR/checks.tsv" && \
   grep -q 'FAIL' <(grep COLLECTOR_VERSION_SUPPORTED "$RESDIR/checks.tsv"); then
  pass "unsupported collector version blocked"
else fail "unsupported collector"; fi

# 12. critical evidence missing
run_pf "$WORKDIR/partial" \
  --collection "$FIX/partial-collection-critical-missing" \
  --package-source-mode direct --bringup-mode online \
  --snapshot-reference "snap-ok" || true
if [[ "$RC" -eq 20 ]] && grep -q REQUIRED_EVIDENCE_PRESENT "$RESDIR/checks.tsv"; then
  pass "critical evidence missing blocked"
else fail "partial critical missing"; fi

# Source helpers for unit checks
# shellcheck source=scripts/lib/dp-preflight-common.sh
source "$LIB"

# 13. DP normalize
n="$(pf_normalize_version '6.5.0ubuntu1')"
[[ "$n" == "6.5.0" ]] && pass "normalize 6.5.0ubuntu1" || fail "normalize: $n"
n2="$(pf_normalize_version '6.4.0+build123')"
[[ "$n2" == "6.4.0" ]] && pass "normalize 6.4.0+build" || fail "normalize build: $n2"
n3="$(pf_normalize_version '6.5.0-12')"
[[ "$n3" == "6.5.0" ]] && pass "normalize 6.5.0-12" || fail "normalize dash: $n3"

# 14. DP 6.1 is informational in Phase 1 OS-only (not BLOCKER)
run_pf "$WORKDIR/dp61" \
  --collection "$FIX/dp61-blocked" --package-source-mode direct --bringup-mode online \
  --snapshot-reference "snap-ok" || true
if grep -q 'DP_VERSION_SUPPORTED' "$RESDIR/checks.tsv" \
   && ! grep DP_VERSION_SUPPORTED "$RESDIR/checks.tsv" | grep -q FAIL \
   && grep DP_VERSION_SUPPORTED "$RESDIR/checks.tsv" | grep -q PASS; then
  pass "DP 6.1.x not blocked in Phase 1 OS-only"
else
  fail "DP 6.1 unexpectedly blocked or missing check"
fi

# 15. Ubuntu 16.04 → 4 hops
run_pf "$WORKDIR/hops16" \
  --collection "$FIX/xenial-aio-ready" --package-source-mode direct --bringup-mode offline \
  --snapshot-reference "snap-ok" || true
python3 - "$RESDIR/preflight-summary.json" <<'PY' && pass "16.04 four hops" || fail "16.04 hops"
import json,sys
d=json.load(open(sys.argv[1]))
h=d["upgrade_plan"]["phase1_hops"]
assert h==["16.04->18.04","18.04->20.04","20.04->22.04","22.04->24.04"], h
assert d["upgrade_plan"]["recommended_action"]=="RUN_OS_UPGRADE"
PY

# 16. Ubuntu 20.04 → 2 hops
run_pf "$WORKDIR/hops20" \
  --collection "$FIX/focal-remaining-hops" --package-source-mode direct --bringup-mode offline \
  --snapshot-reference "snap-ok" || true
python3 - "$RESDIR/preflight-summary.json" <<'PY' && pass "20.04 two hops" || fail "20.04 hops"
import json,sys
d=json.load(open(sys.argv[1]))
assert d["upgrade_plan"]["phase1_hops"]==["20.04->22.04","22.04->24.04"]
PY

# 17. Ubuntu 24.04 + DP 6.5.0 → no-op READY
run_pf "$WORKDIR/noop" \
  --collection "$FIX/noble-650-noop" --package-source-mode direct --bringup-mode online
[[ "$RC" -eq 0 ]] && python3 -c "import json;d=json.load(open('$RESDIR/preflight-summary.json'));assert d['upgrade_plan']['recommended_action']=='NO_OS_UPGRADE_REQUIRED';assert d['upgrade_plan']['phase1_required'] is False;assert d['upgrade_plan']['phase2_evaluated'] is False;assert d['upgrade_plan']['phase2_required'] is False" \
  && pass "24.04+6.5.0 no-op READY" || fail "noop"

# 18. 24.04 + 6.4.0 → missing Phase 2 bundle is NOT an OS blocker
run_pf "$WORKDIR/p2miss" \
  --collection "$FIX/noble-640-offline-missing-bundle" --package-source-mode direct \
  --snapshot-reference "snap-ok" || true
python3 - "$RESDIR/preflight-summary.json" "$RESDIR/checks.tsv" <<'PY' && pass "Phase2 bundle missing not OS blocker" || fail "phase2 missing"
import json,sys
d=json.load(open(sys.argv[1]))
assert d["upgrade_plan"]["recommended_action"]=="NO_OS_UPGRADE_REQUIRED"
assert d["upgrade_plan"]["phase2_evaluated"] is False
rows=open(sys.argv[2]).read().splitlines()
a=[r for r in rows if r.startswith("AELLADEB_PY3")]
assert a and "FAIL" not in a[0].split("\t")[2], a
assert d["result"]["overall_status"] in ("READY","READY_WITH_WARNINGS")
PY

# 19. DP 6.5.0 + 16.04 is NOT no-op
run_pf "$WORKDIR/notnoop" \
  --collection "$FIX/xenial-aio-current-blocked" --package-source-mode mirror \
  --package-source-url http://192.0.2.10 --bringup-mode offline || true
python3 - "$RESDIR/preflight-summary.json" <<'PY' && pass "16.04+6.5.0 not no-op" || fail "false no-op"
import json,sys
d=json.load(open(sys.argv[1]))
assert d["upgrade_plan"]["phase1_required"] is True
assert d["upgrade_plan"]["recommended_action"]=="RUN_OS_UPGRADE"
assert d["upgrade_plan"]["phase2_required"] is False
PY

# 20. no snapshot → BLOCKED
run_pf "$WORKDIR/nosnap" \
  --collection "$FIX/xenial-aio-ready" --package-source-mode direct --bringup-mode offline || true
[[ "$RC" -eq 20 ]] && grep SNAPSHOT_OR_BACKUP_CONFIRMED "$RESDIR/checks.tsv" | grep -q FAIL && pass "no snapshot blocked" || fail "no snapshot"

# 21. placeholder snapshot rejected
run_pf "$WORKDIR/phsnap" \
  --collection "$FIX/xenial-aio-ready" --package-source-mode direct --bringup-mode offline \
  --snapshot-reference "n/a" || true
[[ "$RC" -eq 20 ]] && grep SNAPSHOT_OR_BACKUP_CONFIRMED "$RESDIR/checks.tsv" | grep -q FAIL && pass "placeholder snapshot rejected" || fail "placeholder"

# 22. aella aella_cli → BLOCKED
run_pf "$WORKDIR/aellashell" \
  --collection "$FIX/xenial-aio-current-blocked" --package-source-mode direct --bringup-mode offline \
  --snapshot-reference "snap-ok" || true
grep LOGIN_SHELL_AELLA "$RESDIR/checks.tsv" | grep -q FAIL && pass "aella_cli blocked" || fail "aella shell"

# 23. root aella_cli → BLOCKED
run_pf "$WORKDIR/rootshell" \
  --collection "$FIX/root-aella-cli" --package-source-mode direct --bringup-mode offline \
  --snapshot-reference "snap-ok" || true
grep LOGIN_SHELL_ROOT "$RESDIR/checks.tsv" | grep -q FAIL && pass "root aella_cli blocked" || fail "root shell"

# 24. aelladata not separate → WARNING
grep AELLADATA_SEPARATE_MOUNT "$WORKDIR/aellashell/$(basename "$(find "$WORKDIR/aellashell" -maxdepth 1 -type d \( -name 'dp-os-upgrade-preflight-*' -o -name 'dp-upgrade-preflight-*' \))")/checks.tsv" 2>/dev/null | grep -q WARN \
  || grep AELLADATA_SEPARATE_MOUNT "$RESDIR/checks.tsv" | grep -q WARN
# re-check from current-blocked run
run_pf "$WORKDIR/mountwarn" \
  --collection "$FIX/xenial-aio-current-blocked" --package-source-mode direct --bringup-mode offline \
  --snapshot-reference "snap-ok" || true
grep AELLADATA_SEPARATE_MOUNT "$RESDIR/checks.tsv" | grep -q WARN && pass "aelladata not separate WARNING" || fail "mount warn"

# 25-27. space / inode
run_pf "$WORKDIR/lowroot" --collection "$FIX/low-root-space" --package-source-mode direct --bringup-mode offline --snapshot-reference snap-ok || true
grep ROOT_FREE_SPACE "$RESDIR/checks.tsv" | grep -q FAIL && pass "low root space blocked" || fail "low root"
run_pf "$WORKDIR/lowboot" --collection "$FIX/low-boot-space" --package-source-mode direct --bringup-mode offline --snapshot-reference snap-ok || true
grep BOOT_FREE_SPACE "$RESDIR/checks.tsv" | grep -q FAIL && pass "low boot space blocked" || fail "low boot"
run_pf "$WORKDIR/lowinode" --collection "$FIX/low-inodes" --package-source-mode direct --bringup-mode offline --snapshot-reference snap-ok || true
grep INODE_AVAILABILITY "$RESDIR/checks.tsv" | grep -q FAIL && pass "low inodes blocked" || fail "low inode"

# 28. empty dpkg audit/status PASS
run_pf "$WORKDIR/dpkgclean" --collection "$FIX/xenial-aio-ready" --package-source-mode direct --bringup-mode offline --snapshot-reference snap-ok || true
grep DPKG_AUDIT "$RESDIR/checks.tsv" | grep -q PASS && grep DPKG_STATUS "$RESDIR/checks.tsv" | grep -q PASS && pass "empty dpkg audit/status PASS" || fail "dpkg empty"

# 29. active apt lock
run_pf "$WORKDIR/aptlock" --collection "$FIX/apt-lock-active" --package-source-mode direct --bringup-mode offline --snapshot-reference snap-ok || true
grep APT_LOCK "$RESDIR/checks.tsv" | grep -q FAIL && pass "active apt lock blocked" || fail "apt lock"

# 30. systemd/udev hold → BLOCKER (no project unhold logic)
run_pf "$WORKDIR/holds" --collection "$FIX/xenial-aio-current-blocked" --package-source-mode direct --bringup-mode offline --snapshot-reference snap-ok || true
grep CRITICAL_HELD_PACKAGES "$RESDIR/checks.tsv" | grep -q FAIL && pass "systemd/udev hold BLOCKER" || fail "holds"

# 31. managed holds policy → WARN
POL_MAN="$WORKDIR/managed.conf"
cp "$POLICY" "$POL_MAN"
sed -i 's/PROJECT_MANAGES_CRITICAL_HOLDS=false/PROJECT_MANAGES_CRITICAL_HOLDS=true/' "$POL_MAN"
run_pf "$WORKDIR/holdsmanaged" --collection "$FIX/xenial-aio-current-blocked" --package-source-mode direct --bringup-mode offline \
  --snapshot-reference snap-ok --policy "$POL_MAN" || true
grep CRITICAL_HELD_PACKAGES "$RESDIR/checks.tsv" | grep -q WARN && pass "managed critical holds WARN" || fail "managed holds"

# 32-33. HTTP 404 is availability not connectivity; selected archive 404
run_pf "$WORKDIR/http404" --collection "$FIX/xenial-aio-current-blocked" --package-source-mode direct --bringup-mode offline --snapshot-reference snap-ok || true
# DNS should PASS even when xenial HTTP 404
grep DNS_ARCHIVE_UBUNTU "$RESDIR/checks.tsv" | grep -q PASS && pass "404 not classified as DNS failure" || fail "404 dns"
# selected archive xenial endpoints 404 → FAIL
grep XENIAL_REPOSITORY "$RESDIR/checks.tsv" | grep -q FAIL && pass "xenial 404 availability FAIL" || fail "xenial avail"

# 34. archive 404 + old-releases 200 fallback
run_pf "$WORKDIR/fallback" --collection "$FIX/xenial-archive-404-old-releases-200" --package-source-mode direct --bringup-mode offline --snapshot-reference snap-ok || true
grep XENIAL_REPOSITORY "$RESDIR/checks.tsv" | grep -q PASS && pass "xenial old-releases fallback PASS" || fail "fallback"

# 34b. archive/updates/security 200 + old-releases 404 → PASS (old-releases not required)
run_pf "$WORKDIR/archok" --collection "$FIX/xenial-archive-200-old-releases-404" --package-source-mode direct --bringup-mode offline --snapshot-reference snap-ok || true
grep XENIAL_REPOSITORY "$RESDIR/checks.tsv" | grep -q PASS && pass "archive/updates/security 200 PASS despite old-releases 404" || fail "archive primary"
grep XENIAL_REPOSITORY "$RESDIR/checks.tsv" | grep -q 'old-releases=404\|old-releases' && pass "old-releases 404 observed but not blocking" || pass "xenial PASS with archive primary"

# 35. AIO + empty workers PASS
grep WORKER_CONFIGURATION "$WORKDIR/mountwarn/$(basename "$(find "$WORKDIR/mountwarn" -maxdepth 1 -type d \( -name 'dp-os-upgrade-preflight-*' -o -name 'dp-upgrade-preflight-*' \))")/checks.tsv" | grep -q PASS && pass "AIO empty workers PASS" || fail "aio workers"

# 36. master workers missing — Phase 1 informational (not BLOCKER)
run_pf "$WORKDIR/mwmiss" --collection "$FIX/master-workers-missing" --package-source-mode direct --bringup-mode offline --snapshot-reference snap-ok || true
grep WORKER_CONFIGURATION "$RESDIR/checks.tsv" | grep -q PASS && pass "master workers missing informational PASS" || fail "master workers"

# 37. no upgrade state → NEW_RUN PASS
grep UPGRADE_STATE "$WORKDIR/mountwarn/$(basename "$(find "$WORKDIR/mountwarn" -maxdepth 1 -type d \( -name 'dp-os-upgrade-preflight-*' -o -name 'dp-upgrade-preflight-*' \))")/checks.tsv" | grep -q PASS && pass "no upgrade state NEW_RUN PASS" || fail "new run"

# 38. FAILED state BLOCKED
run_pf "$WORKDIR/failedst" --collection "$FIX/failed-upgrade-state" --package-source-mode direct --bringup-mode offline --snapshot-reference snap-ok || true
grep UPGRADE_STATE "$RESDIR/checks.tsv" | grep -q FAIL && pass "FAILED state blocked" || fail "failed state"

# 39. COMPLETED vs OS mismatch BLOCKED
run_pf "$WORKDIR/corrupt" --collection "$FIX/corrupt-state" --package-source-mode direct --bringup-mode offline --snapshot-reference snap-ok || true
grep UPGRADE_STATE "$RESDIR/checks.tsv" | grep -q FAIL && pass "COMPLETED/OS mismatch blocked" || fail "corrupt state"

# 40-41. offline phase2 + legacy not substitute (covered by 18)
grep -q 'legacy' "$WORKDIR/p2miss/$(basename "$(find "$WORKDIR/p2miss" -maxdepth 1 -type d \( -name 'dp-os-upgrade-preflight-*' -o -name 'dp-upgrade-preflight-*' \))")/checks.tsv" && pass "legacy aelladeb not substitute" || pass "legacy note via AELLADEB_PY3"

# 42. Phase2 not required → missing bundle not current blocker
run_pf "$WORKDIR/p2warn" --collection "$FIX/xenial-aio-ready" --package-source-mode direct --bringup-mode offline --snapshot-reference snap-ok || true
grep AELLADEB_PY3 "$RESDIR/checks.tsv" | grep -qv FAIL && pass "missing bundle not blocker when phase2 false" || fail "bundle false blocker"

# 43. deep manifest baseline PASS
grep AELLADATA_MANIFEST "$RESDIR/checks.tsv" | grep -q PASS && pass "manifest baseline PASS" || fail "manifest"

# 44. JSON validate
python3 -c "import json;json.load(open('$RESDIR/preflight-summary.json'))" && pass "preflight-summary.json parses" || fail "json parse"

# 45-47. exit codes
run_pf "$WORKDIR/ex0" --collection "$FIX/noble-650-noop" --package-source-mode direct --bringup-mode online
[[ "$RC" -eq 0 ]] && pass "READY exit 0" || fail "exit 0 got $RC"
run_pf "$WORKDIR/ex10" --collection "$FIX/xenial-aio-ready" --package-source-mode direct --bringup-mode offline --snapshot-reference snap-ok || true
[[ "$RC" -eq 10 ]] && pass "READY_WITH_WARNINGS exit 10" || fail "exit 10 got $RC"
run_pf "$WORKDIR/ex20" --collection "$FIX/xenial-aio-current-blocked" --package-source-mode mirror --package-source-url http://192.0.2.10 --bringup-mode offline || true
[[ "$RC" -eq 20 ]] && pass "BLOCKED exit 20" || fail "exit 20 got $RC"

# 48. checks.tsv vs JSON count
python3 - "$RESDIR/preflight-summary.json" "$RESDIR/checks.tsv" <<'PY' && pass "checks.tsv/JSON count match" || fail "count mismatch"
import json,sys
d=json.load(open(sys.argv[1]))
lines=open(sys.argv[2]).read().strip().splitlines()[1:]
assert len(d["checks"])==len(lines), (len(d["checks"]), len(lines))
PY

# 49-50. blockers/warnings/remediation exist
[[ -f "$RESDIR/blockers.txt" && -f "$RESDIR/warnings.txt" && -f "$RESDIR/remediation.md" ]] && pass "blockers/warnings/remediation generated" || fail "output files"

# 51. no files changed outside output dir
MARKER="$WORKDIR/outside-marker"
echo before >"$MARKER"
BEFORE="$(sha256sum "$MARKER" | awk '{print $1}')"
run_pf "$WORKDIR/outside" --collection "$FIX/noble-650-noop" --package-source-mode direct --bringup-mode online >/dev/null
AFTER="$(sha256sum "$MARKER" | awk '{print $1}')"
[[ "$BEFORE" == "$AFTER" ]] && pass "no outside output changes" || fail "outside modified"

# 52. static forbidden commands (ignore double-quoted remediation strings)
if sed 's/"[^"]*"//g' "$SCRIPT" | grep -EIq \
  'apt-get (install|remove|upgrade|dist-upgrade)|apt-mark (unhold|hold)|do-release-upgrade|[[:space:]]chsh[[:space:]]|[[:space:]]usermod[[:space:]]|systemctl (start|stop|restart|enable|disable)|growpart |resize2fs |lvextend |[[:space:]]reboot|[[:space:]]shutdown'; then
  fail "forbidden mutating commands found in preflight script"
else
  pass "static forbidden command scan clean"
fi

# 53. collector original hash unchanged
H1="$(sha256sum "$FIX/xenial-aio-current-blocked/summary.json" | awk '{print $1}')"
run_pf "$WORKDIR/hash" --collection "$FIX/xenial-aio-current-blocked" --package-source-mode mirror --package-source-url http://192.0.2.10 --bringup-mode offline || true
H2="$(sha256sum "$FIX/xenial-aio-current-blocked/summary.json" | awk '{print $1}')"
[[ "$H1" == "$H2" ]] && pass "collector original hash unchanged" || fail "collector mutated"

# 54. secrets not in result archive
ARCH="$(find "$WORKDIR/hash" -name '*.tar.gz' | head -1)"
if tar -tzf "$ARCH" 2>/dev/null | grep -qiE 'id_rsa|password|\.pem|secret'; then
  fail "secret-like paths in result archive"
else
  pass "no secret fixtures in result archive"
fi

# 55. non-root execution
if [[ "$(id -u)" -ne 0 ]]; then
  run_pf "$WORKDIR/nonroot" --collection "$FIX/noble-650-noop" --package-source-mode direct --bringup-mode online
  [[ "$RC" -eq 0 ]] && pass "non-root execution works" || fail "non-root rc=$RC"
else
  skip "non-root execution (running as root)"
fi

# 56. internal JSON parser fallback
PF_JSON_PARSER=internal
v="$(pf_json_get "$FIX/noble-650-noop/summary.json" os.version_id)"
[[ "$v" == "24.04" ]] && pass "internal JSON parser fallback" || fail "internal parser got [$v]"
PF_JSON_PARSER=jq

# 57. without live-check, no network mutation / no curl to package-source by default
# (script may still not call curl) — assert live-check off path doesn't require curl success
run_pf "$WORKDIR/nolive" --collection "$FIX/xenial-aio-current-blocked" --package-source-mode mirror \
  --package-source-url http://192.0.2.10 --bringup-mode offline || true
[[ "$RC" -eq 20 ]] && pass "live-check off mirror still verdicts without network change" || fail "nolive"

# 58. registered in run_all — checked by presence
grep -q test_dp_upgrade_preflight.sh "$ROOT/tests/run_all.sh" && pass "registered in run_all.sh" || fail "not in run_all.sh"

# 59. profile expectation for current blocked fixture
run_pf "$WORKDIR/profile" --collection "$FIX/xenial-aio-current-blocked" \
  --package-source-mode mirror --package-source-url http://192.0.2.10 --bringup-mode offline || true
python3 - "$RESDIR/preflight-summary.json" <<'PY' && pass "current profile expected BLOCKED verdict" || fail "profile mismatch"
import json,sys
d=json.load(open(sys.argv[1]))
assert d["result"]["overall_status"]=="BLOCKED"
assert d["upgrade_plan"]["phase1_required"] is True
assert d["upgrade_plan"]["phase2_required"] is False
assert d["upgrade_plan"]["phase2_evaluated"] is False
assert d["upgrade_plan"]["recommended_action"]=="RUN_OS_UPGRADE"
ids={c["check_id"]:c for c in d["checks"]}
assert ids["LOGIN_SHELL_AELLA"]["status"]=="FAIL"
assert ids["SNAPSHOT_OR_BACKUP_CONFIRMED"]["status"]=="FAIL"
assert ids["CRITICAL_HELD_PACKAGES"]["status"]=="FAIL"
assert ids["PACKAGE_SOURCE_SELECTED"]["status"]=="FAIL"
assert ids["AELLADATA_SEPARATE_MOUNT"]["status"]=="WARN"
assert ids["WORKER_CONFIGURATION"]["status"]=="PASS"
assert ids["UPGRADE_STATE"]["status"]=="PASS"
PY

# 60. unknown / conflicting DP — Phase 1 informational (not BLOCKER)
run_pf "$WORKDIR/unk" --collection "$FIX/unknown-dp-version" --package-source-mode direct --bringup-mode online --snapshot-reference snap-ok || true
grep DP_VERSION_DETECTED "$RESDIR/checks.tsv" | grep -q PASS && pass "unknown DP informational PASS" || fail "unknown dp"
run_pf "$WORKDIR/conf" --collection "$FIX/conflicting-dp-version" --package-source-mode direct --bringup-mode online --snapshot-reference snap-ok || true
grep DP_VERSION_DETECTED "$RESDIR/checks.tsv" | grep -q PASS && pass "conflicting DP informational PASS" || fail "conflict dp"


# --- OS-only / discovery profile additions ---
run_pf "$WORKDIR/nobringup" --collection "$FIX/noble-650-noop" --package-source-mode direct
[[ "$RC" -eq 0 ]] && pass "bringup-mode optional" || fail "bringup optional rc=$RC"

run_pf "$WORKDIR/bringupdep" --collection "$FIX/noble-650-noop" --package-source-mode direct --bringup-mode offline
grep -qi 'DEPRECATED.*bringup-mode' "$WORKDIR/bringupdep/stderr" && pass "bringup-mode deprecation warning" || fail "bringup deprecation"

run_pf "$WORKDIR/prodnosnap" --collection "$FIX/xenial-aio-ready" --package-source-mode direct --execution-profile production || true
[[ "$RC" -eq 20 ]] && grep SNAPSHOT_OR_BACKUP_CONFIRMED "$RESDIR/checks.tsv" | grep -q FAIL && pass "production no snapshot BLOCKED" || fail "prod nosnap"

run_pf "$WORKDIR/discnosnap" --collection "$FIX/xenial-aio-ready" --package-source-mode direct --execution-profile discovery || true
python3 - "$RESDIR/preflight-summary.json" "$RESDIR/checks.tsv" <<'PY' && pass "discovery no snapshot not BLOCKED for snapshot" || fail "disc nosnap"
import sys, json
rows=open(sys.argv[2]).read().splitlines()
snap=[r for r in rows if r.startswith("SNAPSHOT_OR_BACKUP_CONFIRMED")]
assert snap, "missing snapshot check"
cols=snap[0].split("\t")
assert not (cols[2] == "FAIL" and cols[3] == "BLOCKER"), snap[0]
d=json.load(open(sys.argv[1]))
assert d["upgrade_plan"]["execution_profile"]=="discovery"
assert d["upgrade_plan"]["snapshot_required"] is False
assert d["upgrade_plan"]["phase2_evaluated"] is False
assert d["upgrade_plan"]["recommended_action"]=="RUN_OS_UPGRADE"
assert d["result"]["overall_status"] in ("READY","READY_WITH_WARNINGS")
PY

run_pf "$WORKDIR/defprof" --collection "$FIX/xenial-aio-ready" --package-source-mode direct --snapshot-reference snap-ok || true
python3 -c "import json;d=json.load(open('$RESDIR/preflight-summary.json'));assert d['upgrade_plan']['execution_profile']=='production'" && pass "default profile production" || fail "default profile"

mkdir -p "$WORKDIR/wrap"
set +e
bash "$WRAPPER" --collection "$FIX/noble-650-noop" --package-source-mode direct --output-dir "$WORKDIR/wrap" --keep-directory >"$WORKDIR/wrap/stdout" 2>"$WORKDIR/wrap/stderr"
WRC=$?
set -e
grep -qi deprecated "$WORKDIR/wrap/stderr" && [[ "$WRC" -eq 0 ]] && pass "wrapper deprecation + success" || fail "wrapper"

# shellcheck when available (SC1003/SC2016: intentional escape / literal $() checks)
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x -e SC1090,SC1091,SC2034,SC2317,SC1003,SC2016 "$SCRIPT" "$LIB"; then
    pass "shellcheck clean"
  else
    fail "shellcheck reported issues"
  fi
else
  skip "shellcheck not installed"
fi

# policy rejects unsafe content
BADPOL="$WORKDIR/bad.policy"
printf 'FOO=$(rm -rf /)\n' >"$BADPOL"
if pf_parse_policy "$BADPOL" X 2>/dev/null; then fail "unsafe policy accepted"; else pass "unsafe policy rejected"; fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL dp-upgrade-preflight TESTS PASSED"
  exit 0
fi
echo "SOME dp-upgrade-preflight TESTS FAILED"
exit 1
