#!/usr/bin/env bash
# Generate synthetic preflight/OS fixtures for dp-os-upgrade tests (no customer data).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

utc_now_fresh() {
  # Fresh timestamp within PREFLIGHT_MAX_AGE_SECONDS
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

utc_stale() {
  date -u -d '3 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
    python3 -c 'import datetime; print((datetime.datetime.utcnow()-datetime.timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))'
}

utc_future() {
  date -u -d '2 hours' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
    python3 -c 'import datetime; print((datetime.datetime.utcnow()+datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))'
}

write_preflight() {
  local dir="$1"
  local status="$2"
  local hostname="$3"
  local os_ver="$4"
  local os_code="$5"
  local mode="$6"
  local url="$7"
  local completed="$8"
  local action="$9"
  local hops_json="${10}"
  local warn_ids="${11:-}"
  local snap="${12:-esxi-lab-snapshot-20260716}"
  local dp_ver="${13:-6.5.0}"
  local exit_code=0
  case "$status" in
    READY) exit_code=0 ;;
    READY_WITH_WARNINGS) exit_code=10 ;;
    BLOCKED) exit_code=20 ;;
  esac

  rm -rf "$dir"
  mkdir -p "$dir/source"
  local pfid="dp-upgrade-preflight-${hostname}-synthetic"
  local warn_count=0 blocker_count=0
  [[ "$status" == "READY_WITH_WARNINGS" ]] && warn_count=2
  [[ "$status" == "BLOCKED" ]] && blocker_count=1

  # checks.tsv
  {
    printf 'check_id\tcategory\tstatus\tseverity\tobserved\texpected\treason\tremediation\tevidence_file\tevidence_key\n'
    printf 'INPUT_INTEGRITY\tinput\tPASS\tINFO\to\te\tok\tnone\tsummary.json\tx\n'
    if [[ "$status" == "BLOCKED" ]]; then
      printf 'CRITICAL_HELD_PACKAGES\tapt\tFAIL\tBLOCKER\tsystemd\tnone\theld\tunhold\tapt/held-packages.txt\tx\n'
    fi
    local wid
    for wid in $warn_ids; do
      printf '%s\tstorage\tWARN\tWARNING\to\te\twarn\treview\tnone\tx\n' "$wid"
    done
  } >"$dir/checks.tsv"

  if [[ "$status" == "BLOCKED" ]]; then
    printf 'CRITICAL_HELD_PACKAGES: held\n' >"$dir/blockers.txt"
  else
    printf 'No blockers.\n' >"$dir/blockers.txt"
  fi
  printf 'Warnings\n' >"$dir/warnings.txt"
  for wid in $warn_ids; do printf '%s\n' "$wid" >>"$dir/warnings.txt"; done
  printf '# remediation\n' >"$dir/remediation.md"
  printf 'TARGET_OS_VERSION=24.04\n' >"$dir/policy-effective.conf"
  printf 'collector_path=synthetic\ncollector_type=directory\ncollection_id=synth\nhostname=%s\n' "$hostname" \
    >"$dir/source/collector-reference.txt"

  local phase1=True phase2=False
  [[ "$action" == "NONE" || "$action" == "NO_OS_UPGRADE_REQUIRED" ]] && phase1=False
  [[ "$action" == "RUN_PHASE2" ]] && phase1=False && phase2=True
  [[ "$action" == "RUN_PHASE1_AND_PHASE2" ]] && phase2=True
  local url_py="None"
  [[ -n "$url" ]] && url_py="\"$url\""

  python3 - "$dir/preflight-summary.json" <<PY
import json,sys
path=sys.argv[1]
doc={
  "schema_version":"1.0",
  "script_version":"1.0.0",
  "preflight_id":"$pfid",
  "started_at_utc":"$completed",
  "completed_at_utc":"$completed",
  "duration_seconds":5,
  "input":{"path":"synthetic","type":"directory","collector_script_version":"1.0.2","collector_schema_version":"1.0","collector_status":"complete","collection_id":"synth","integrity_status":"ok"},
  "target":{"hostname":"$hostname","os_version":"$os_ver","os_codename":"$os_code","dp_version_raw":"${dp_ver}ubuntu1","dp_version_normalized":"$dp_ver","role":"AIO","cluster_detected":True,"worker_ips":[]},
  "requested_path":{"package_source_mode":"$mode","package_source_url":$url_py,"bringup_mode":"offline","snapshot_reference_present":True,"backup_reference_present":False,"snapshot_reference":"$snap","backup_reference":None},
  "upgrade_plan":{"supported_start":True,"phase1_required":$phase1,"phase1_hops":json.loads('''$hops_json'''),"phase2_required":$phase2,"target_os":"24.04","target_dp":"6.6.0","recommended_action":"$action","upgrade_required":True},
  "result":{"overall_status":"$status","exit_code":$exit_code,"pass_count":10,"warning_count":$warn_count,"blocker_count":$blocker_count,"unknown_count":0},
  "checks":[]
}
if "$status"=="READY_WITH_WARNINGS":
  for wid in """$warn_ids""".split():
    if wid:
      doc["checks"].append({"check_id":wid,"category":"storage","status":"WARN","severity":"WARNING","observed":"x","expected":"y","reason":"warn","remediation":"accept","evidence_file":"","evidence_key":""})
if "$status"=="BLOCKED":
  doc["checks"].append({"check_id":"CRITICAL_HELD_PACKAGES","category":"apt","status":"FAIL","severity":"BLOCKER","observed":"systemd","expected":"none","reason":"held","remediation":"fix","evidence_file":"","evidence_key":""})
json.dump(doc, open(path,"w"), indent=2)
print("wrote", path)
PY
  printf 'preflight summary\noverall_status: %s\n' "$status" >"$dir/preflight-summary.txt"
}

FRESH="$(utc_now_fresh)"
STALE="$(utc_stale)"
FUTURE="$(utc_future)"

HOPS4='["16.04->18.04","18.04->20.04","20.04->22.04","22.04->24.04"]'
HOPS3='["18.04->20.04","20.04->22.04","22.04->24.04"]'
HOPS2='["20.04->22.04","22.04->24.04"]'
HOPS1='["22.04->24.04"]'
HOPS0='[]'

write_preflight preflight-ready-xenial READY ready-aio 16.04 xenial mirror http://192.0.2.10 "$FRESH" RUN_OS_UPGRADE "$HOPS4" "" "esxi-lab-snapshot-20260716" "6.5.0"
write_preflight preflight-warning-xenial READY_WITH_WARNINGS ready-aio 16.04 xenial direct "" "$FRESH" RUN_OS_UPGRADE "$HOPS4" "AELLADATA_SEPARATE_MOUNT POST_OS_DP_REVALIDATION" "esxi-lab-snapshot-20260716" "6.5.0"
write_preflight preflight-blocked BLOCKED ready-aio 16.04 xenial mirror http://192.0.2.10 "$FRESH" RUN_OS_UPGRADE "$HOPS4" "" "esxi-lab-snapshot-20260716" "6.5.0"
write_preflight stale-preflight READY ready-aio 16.04 xenial mirror http://192.0.2.10 "$STALE" RUN_OS_UPGRADE "$HOPS4"
write_preflight future-preflight READY ready-aio 16.04 xenial mirror http://192.0.2.10 "$FUTURE" RUN_OS_UPGRADE "$HOPS4"
write_preflight hostname-mismatch READY other-host 16.04 xenial mirror http://192.0.2.10 "$FRESH" RUN_OS_UPGRADE "$HOPS4"
write_preflight preflight-ready-bionic READY ready-aio 18.04 bionic mirror http://192.0.2.10 "$FRESH" RUN_OS_UPGRADE "$HOPS3"
write_preflight preflight-ready-focal READY ready-aio 20.04 focal mirror http://192.0.2.10 "$FRESH" RUN_OS_UPGRADE "$HOPS2"
write_preflight preflight-ready-jammy READY ready-aio 22.04 jammy mirror http://192.0.2.10 "$FRESH" RUN_OS_UPGRADE "$HOPS1"
write_preflight preflight-ready-noble READY ready-aio 24.04 noble mirror http://192.0.2.10 "$FRESH" NO_OS_UPGRADE_REQUIRED "$HOPS0"
write_preflight preflight-phase1-and-phase2 READY ready-aio 16.04 xenial mirror http://192.0.2.10 "$FRESH" RUN_PHASE1_AND_PHASE2 "$HOPS4" "" "esxi-lab-snapshot-20260716" "6.4.0"
write_preflight preflight-dp650-xenial READY ready-aio 16.04 xenial mirror http://192.0.2.10 "$FRESH" RUN_OS_UPGRADE "$HOPS4" "" "esxi-lab-snapshot-20260716" "6.5.0"
write_preflight source-mode-mismatch READY ready-aio 16.04 xenial cache http://192.0.2.10:3142 "$FRESH" RUN_OS_UPGRADE "$HOPS4"

# OS root snapshots
for pair in xenial-before:16.04:xenial bionic-after:18.04:bionic focal-after:20.04:focal jammy-after:22.04:jammy noble-after:24.04:noble; do
  name="${pair%%:*}"; rest="${pair#*:}"; ver="${rest%%:*}"; code="${rest##*:}"
  mkdir -p "$name/etc" "$name/opt/aelladata"
  cat >"$name/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION_ID="$ver"
VERSION_CODENAME=$code
ID=ubuntu
EOF
  printf 'lab-cluster\n' >"$name/opt/aelladata/cluster-name"
  printf 'version: 6.5.0\n' >"$name/opt/aelladata/release-metadata.yml"
  printf 'image: synthetic\n' >"$name/opt/aelladata/release-image.yml"
  printf 'ready-aio\n' >"$name/etc/hostname"
done

# Mirror fixtures
mkdir -p mirror-complete/ubuntu/dists/{xenial,bionic,focal,jammy,noble} mirror-complete/offline
for c in xenial bionic focal jammy noble; do
  printf 'Origin: Ubuntu\nLabel: Ubuntu\nSuite: %s\n' "$c" >"mirror-complete/ubuntu/dists/${c}/Release"
  printf 'InRelease\n' >"mirror-complete/ubuntu/dists/${c}/InRelease"
done
printf 'Dist: xenial\nName: Xenial\n' >mirror-complete/offline/meta-release-lts

mkdir -p mirror-xenial-missing/ubuntu/dists/{bionic,focal,jammy,noble} mirror-xenial-missing/offline
for c in bionic focal jammy noble; do
  printf 'Suite: %s\n' "$c" >"mirror-xenial-missing/ubuntu/dists/${c}/Release"
done
printf 'Dist: bionic\n' >mirror-xenial-missing/offline/meta-release-lts

mkdir -p mirror-meta-release-missing/ubuntu/dists/{xenial,bionic,focal,jammy,noble}
for c in xenial bionic focal jammy noble; do
  printf 'Suite: %s\n' "$c" >"mirror-meta-release-missing/ubuntu/dists/${c}/Release"
done

mkdir -p cache-ready direct-ready
printf 'ok\n' >cache-ready/READY
printf 'ok\n' >direct-ready/READY

mkdir -p critical-holds
printf 'systemd\nudev\n' >critical-holds/held-packages.txt

mkdir -p active-apt-lock
printf '1\n' >active-apt-lock/lock.active

mkdir -p insufficient-disk
printf '1024\n' >insufficient-disk/root-avail-bytes

mkdir -p ntp-unsynchronized
printf '0\n' >ntp-unsynchronized/ntp

# State fixtures (minimal)
write_state() {
  local dir="$1" state="$2"
  mkdir -p "$dir"
  cat >"$dir/state.json" <<EOF
{
  "schema_version": "1.0",
  "script_version": "1.0.0",
  "state_revision": 3,
  "current_state": "$state",
  "hostname": "ready-aio",
  "source_os": "16.04",
  "source_codename": "xenial",
  "current_os": "16.04",
  "current_codename": "xenial",
  "target_os": "18.04",
  "target_codename": "bionic",
  "final_target_os": "24.04",
  "final_target_codename": "noble",
  "current_hop": 1,
  "total_hops": 4,
  "attempt": 1,
  "preflight_id": "synth",
  "preflight_completed_at": "$FRESH",
  "snapshot_reference": "esxi-lab-snapshot-20260716",
  "backup_reference": null,
  "package_source_mode": "mirror",
  "package_source_url": "http://192.0.2.10",
  "warning_acceptances": [],
  "last_successful_step": "init",
  "last_error": null,
  "block_reason": null,
  "retryable": $( [[ "$state" == "BLOCKED" ]] && echo true || echo false ),
  "retry_count": 0,
  "next_retry_at_utc": null,
  "pause_requested": false,
  "pause_reason": null,
  "runtime_sha256": "abc",
  "boot_id_at_reboot": null,
  "phase2_executed": false,
  "created_at_utc": "$FRESH",
  "updated_at_utc": "$FRESH"
}
EOF
  sha256sum "$dir/state.json" | awk '{print $1}' >"$dir/state.json.sha256"
}

write_state state-initialized INITIALIZED
write_state state-reboot-required REBOOT_REQUIRED
write_state state-resumed RESUMED
write_state state-blocked-retryable BLOCKED
write_state state-failed FAILED
mkdir -p state-corrupt
printf '{not json' >state-corrupt/state.json
printf 'deadbeef\n' >state-corrupt/state.json.sha256

mkdir -p orphaned-state/hops/hop-01-xenial-to-bionic
printf 'evidence\n' >orphaned-state/hops/hop-01-xenial-to-bionic/result.json

# Malicious archive
python3 - <<'PY'
import tarfile,io,os
path='malicious-preflight-archive/evil.tar.gz'
os.makedirs('malicious-preflight-archive', exist_ok=True)
with tarfile.open(path,'w:gz') as t:
    info=tarfile.TarInfo(name='../../tmp/evil.txt')
    data=b'pwned\n'
    info.size=len(data)
    t.addfile(info, io.BytesIO(data))
print('wrote', path)
PY

# Invalid JSON preflight
mkdir -p invalid-json-preflight/source
printf '{bad' >invalid-json-preflight/preflight-summary.json
printf 'x\n' >invalid-json-preflight/checks.tsv
printf 'x\n' >invalid-json-preflight/blockers.txt
printf 'x\n' >invalid-json-preflight/warnings.txt
printf 'x\n' >invalid-json-preflight/remediation.md
printf 'x=1\n' >invalid-json-preflight/policy-effective.conf
printf 'x\n' >invalid-json-preflight/source/collector-reference.txt

# Unsupported schema
cp -a preflight-ready-xenial unsupported-schema
python3 - <<'PY'
import json
p='unsupported-schema/preflight-summary.json'
d=json.load(open(p)); d['schema_version']='9.9'; json.dump(d, open(p,'w'), indent=2)
PY

echo "fixtures generated under $ROOT"

# Discovery profile fixture (no snapshot)
write_preflight preflight-discovery-xenial READY ready-aio 16.04 xenial mirror http://192.0.2.10 "$FRESH" RUN_OS_UPGRADE "$HOPS4" "" "" "6.5.0"
python3 - <<'PY'
import json, pathlib
p=pathlib.Path("preflight-discovery-xenial/preflight-summary.json")
d=json.loads(p.read_text())
d["requested_path"]["execution_profile"]="discovery"
d["requested_path"]["snapshot_reference"]=None
d["requested_path"]["snapshot_reference_present"]=False
d["upgrade_plan"]["execution_profile"]="discovery"
d["upgrade_plan"]["snapshot_required"]=False
d["rollback"]={"required":False,"snapshot_reference":None,"backup_reference":None,"disposable_vm_acknowledged":False,"risk":"VM may not be recoverable after the OS upgrade"}
p.write_text(json.dumps(d, indent=2))
print("patched discovery fixture")
PY
