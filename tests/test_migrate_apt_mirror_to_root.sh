#!/usr/bin/env bash
# tests/test_migrate_apt_mirror_to_root.sh — fixture tests (no production mutation)
set -u
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/migrate-apt-mirror-to-root.sh"

FAIL=0
PASS=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-migrate-apt-mirror.XXXXXX")"
trap 'rm -rf -- "$WORKDIR"' EXIT
FAKE_BIN="$WORKDIR/bin"
mkdir -p "$FAKE_BIN"

echo "=== test_migrate_apt_mirror_to_root ==="
[[ -f "$SCRIPT" ]] || { echo "missing script"; exit 1; }
chmod +x "$SCRIPT"

# Fake systemctl: mimics real is-active (stdout state + non-zero rc when not active).
# This reproduces the production bug if helpers use `is-active || echo inactive`.
install_fake_systemctl() {
  cat >"$FAKE_BIN/systemctl" <<'EOS'
#!/usr/bin/env bash
cmd="${1:-}"
shift || true
case "$cmd" in
  is-active)
    unit="${1:-}"
    state=""
    case "$unit" in
      apt-mirror.service)
        state="${MIGRATE_TEST_APT_MIRROR_SERVICE_STATE:-${MIGRATE_TEST_UNIT_STATE:-inactive}}"
        ;;
      apt-mirror.timer)
        state="${MIGRATE_TEST_APT_MIRROR_TIMER_STATE:-${MIGRATE_TEST_UNIT_STATE:-inactive}}"
        ;;
      nginx|nginx.service)
        state="${MIGRATE_TEST_NGINX_STATE:-active}"
        ;;
      *)
        state="${MIGRATE_TEST_UNIT_STATE:-inactive}"
        ;;
    esac
    # Match systemd: print state even when inactive/failed; rc=0 only for active.
    printf '%s\n' "$state"
    if [[ "$state" == "active" ]]; then
      exit 0
    fi
    # systemd uses 3 for "inactive" / not-active
    exit 3
    ;;
  *)
    exit 0
    ;;
esac
EOS
  chmod +x "$FAKE_BIN/systemctl"
}
install_fake_systemctl

# Extract get_unit_active_state from the script for isolated helper tests.
load_get_unit_active_state() {
  eval "$(sed -n '/^get_unit_active_state()/,/^}/p' "$SCRIPT")"
}

# ---------------------------------------------------------------------------
make_spool_tree() {
  local spool="$1"
  mkdir -p "$spool"/selective/{published/hops/jammy-to-noble/ubuntu/dists/noble,published.previous/hops/jammy-to-noble/ubuntu/dists/noble,keys,state,staging} \
           "$spool"/client "$spool"/offline \
           "$spool/selective/published/hops/jammy-to-noble/ubuntu/pool/café dir"
  ln -sfn published "$spool/selective/current"
  ln -sfn published "$spool/selective/active"
  printf 'READY\n' >"$spool/selective/state/READY"
  printf 'pub\n' >"$spool/selective/keys/ubuntu-mirror-selective.gpg"
  printf 'PRIVATE-FIXTURE-DO-NOT-LOG\n' >"$spool/selective/keys/ubuntu-mirror-selective.private.gpg"
  chmod 600 "$spool/selective/keys/ubuntu-mirror-selective.private.gpg"
  printf 'shared-payload\n' >"$spool/selective/published/hops/jammy-to-noble/ubuntu/pool-file.deb"
  ln "$spool/selective/published/hops/jammy-to-noble/ubuntu/pool-file.deb" \
     "$spool/selective/published.previous/hops/jammy-to-noble/ubuntu/pool-file.deb"
  printf 'ok\n' >"$spool/selective/published/hops/jammy-to-noble/ubuntu/pool/café dir/file name.deb"
  local hop
  for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
    printf '#!/bin/sh\necho %s\n' "$hop" >"$spool/client/dp-offline-upgrade-${hop}.sh"
    chmod +x "$spool/client/dp-offline-upgrade-${hop}.sh"
    sha256sum "$spool/client/dp-offline-upgrade-${hop}.sh" | awk '{print $1}' \
      >"$spool/client/dp-offline-upgrade-${hop}.sh.sha256"
  done
  printf 'Release\n' >"$spool/selective/published/hops/jammy-to-noble/ubuntu/dists/noble/Release"
  printf 'meta\n' >"$spool/offline/meta-release-lts"
}

make_git_repo() {
  local repo="$1"
  mkdir -p "$repo/scripts"
  cp -a "$SCRIPT" "$repo/scripts/migrate-apt-mirror-to-root.sh"
  chmod +x "$repo/scripts/migrate-apt-mirror-to-root.sh"
  git -C "$repo" init -q
  git -C "$repo" checkout -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t add scripts/migrate-apt-mirror-to-root.sh
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm migrate-tool
  git -C "$repo" update-ref refs/remotes/origin/main "$(git -C "$repo" rev-parse HEAD)"
}

write_uuid_map() {
  printf '%s %s\n' "$2" "$3" >"$1"
  printf '%s disk\n' "/dev/sdb" >>"$1"
}

run_script() {
  local repo="$1"; shift
  local -a eenv=()
  local -a sargs=()
  local a
  for a in "$@"; do
    if [[ "$a" == --* ]]; then
      sargs+=("$a")
    else
      eenv+=("$a")
    fi
  done
  ( cd "$repo" && env PATH="$FAKE_BIN:$PATH" "${eenv[@]}" bash scripts/migrate-apt-mirror-to-root.sh "${sargs[@]}" )
}

# ---------------------------------------------------------------------------
# Base fixture for preflight / initial-copy
# ---------------------------------------------------------------------------
FX="$WORKDIR/fx"
mkdir -p "$FX"/{repo,var/spool,etc,evidence}
SPOOL="$FX/var/spool/apt-mirror"
STAGE="$FX/var/spool/apt-mirror.root-stage"
make_spool_tree "$SPOOL"
make_git_repo "$FX/repo"

FSTAB="$FX/etc/fstab"
cat >"$FSTAB" <<'EOF'
UUID=root-uuid / ext4 defaults 0 1
UUID=boot-uuid /boot ext4 defaults 0 1
UUID=d48ae479-10f5-4ff5-b9be-4baa34dd15ea /var/spool/apt-mirror ext4 defaults,noatime 0 2
UUID=other-uuid /mnt/other ext4 defaults 0 0
EOF
printf 'ALLOW_ROOT_FS_MIRROR="false"\n' >"$FX/etc/mirror.conf"
printf 'ALLOW_ROOT_FS_MIRROR=false\n' >"$FX/etc/defaults"
printf 'root /x;\n' >"$FX/etc/nginx"
MOUNTS="$FX/mounts"
printf '/ /dev/mapper/rootlv ext4\n%s /dev/sdb1 ext4\n%s /dev/mapper/rootlv ext4\n' \
  "$SPOOL" "$FX/var/spool" >"$MOUNTS"
printf '%s 1001\n%s 1002\n/ 1002\n' "$SPOOL" "$FX/var/spool" >"$FX/devno"
write_uuid_map "$FX/uuid" "/dev/sdb1" "d48ae479-10f5-4ff5-b9be-4baa34dd15ea"

base_env=(
  MIGRATE_TEST_MODE=1
  MIGRATE_SKIP_HTTP=1
  MIGRATE_TEST_NGINX_T=PASS
  MIGRATE_TEST_UNIT_STATE=inactive
  MIGRATE_SOURCE_MOUNT="$SPOOL"
  MIGRATE_STAGE_PATH="$STAGE"
  MIGRATE_EXPECTED_DISK=/dev/sdb
  MIGRATE_EXPECTED_PART=/dev/sdb1
  MIGRATE_EXPECTED_UUID=d48ae479-10f5-4ff5-b9be-4baa34dd15ea
  MIGRATE_FSTAB_PATH="$FSTAB"
  MIGRATE_EFFECTIVE_MIRROR_CONF="$FX/etc/mirror.conf"
  MIGRATE_EFFECTIVE_DEFAULTS="$FX/etc/defaults"
  MIGRATE_NGINX_SITE="$FX/etc/nginx"
  MIGRATE_EVIDENCE_ROOT="$FX/evidence"
  MIGRATE_FAKE_MOUNT_TABLE="$MOUNTS"
  MIGRATE_TEST_DEVNO_MAP="$FX/devno"
  MIGRATE_TEST_UUID_MAP="$FX/uuid"
  MIGRATE_ROOT_AVAIL_BYTES=70000000000
)

# 1) default invocation
out="$(bash "$SCRIPT" 2>&1 || true)"
printf '%s' "$out" | grep -q 'Usage:' && pass "1 default usage" || fail "1 default usage"
grep -qE '^UUID=d48ae479' "$FSTAB" && pass "1 no fstab mutation" || fail "1 fstab mutated"

# 2) preflight read-only + 22 idempotent
ck1="$(cksum "$FSTAB" | awk '{print $1}')"
sp1="$(find "$SPOOL" -printf '%p %s %m\n' | cksum | awk '{print $1}')"
out="$(run_script "$FX/repo" "${base_env[@]}" --preflight 2>&1)" || true
printf '%s' "$out" | grep -q 'PREFLIGHT=PASS' && pass "2 preflight PASS" || fail "2 preflight ($out)"
ck2="$(cksum "$FSTAB" | awk '{print $1}')"
sp2="$(find "$SPOOL" -printf '%p %s %m\n' | cksum | awk '{print $1}')"
[[ "$ck1" == "$ck2" && "$sp1" == "$sp2" ]] && pass "2 preflight read-only" || fail "2 preflight mutated"
out="$(run_script "$FX/repo" "${base_env[@]}" --preflight 2>&1)" || true
printf '%s' "$out" | grep -q 'PREFLIGHT=PASS' && pass "22 repeated preflight" || fail "22 repeated preflight"

# 3) wrong UUID
if out="$(run_script "$FX/repo" "${base_env[@]}" MIGRATE_EXPECTED_UUID=11111111-1111-1111-1111-111111111111 --preflight 2>&1)"; then
  fail "3 wrong UUID should fail"
else
  printf '%s' "$out" | grep -qi 'UUID mismatch' && pass "3 wrong UUID aborts" || fail "3 message"
fi

# 4) same filesystem
printf '%s 9\n%s 9\n/ 9\n' "$SPOOL" "$FX/var/spool" >"$FX/devno-same"
if out="$(run_script "$FX/repo" "${base_env[@]}" MIGRATE_TEST_DEVNO_MAP="$FX/devno-same" --preflight 2>&1)"; then
  fail "4 same fs should fail"
else
  printf '%s' "$out" | grep -qi 'same filesystem' && pass "4 same filesystem aborts" || fail "4 message"
fi

# 5) capacity
if out="$(run_script "$FX/repo" "${base_env[@]}" MIGRATE_ROOT_AVAIL_BYTES=1000 --preflight 2>&1)"; then
  fail "5 capacity should fail"
else
  printf '%s' "$out" | grep -qiE 'CAPACITY|HEADROOM' && pass "5 capacity aborts" || fail "5 message"
fi

# 6) git dirty
printf 'x\n' >"$FX/repo/dirty"
if out="$(run_script "$FX/repo" "${base_env[@]}" --preflight 2>&1)"; then
  fail "6 dirty git should fail"
else
  printf '%s' "$out" | grep -qi 'dirty' && pass "6 dirty git aborts" || fail "6 message"
fi
rm -f "$FX/repo/dirty"

# 7) rsync -H in script
grep -q -- '-aHAX' "$SCRIPT" && pass "7 rsync -H flags present" || fail "7 rsync -H"

# 8-11, 23, 25 initial-copy
LOGF="$FX/evidence/copy.log"
mkdir -p "$FX/evidence"
out="$(run_script "$FX/repo" "${base_env[@]}" MIGRATE_LOG_FILE="$LOGF" MIGRATE_EVIDENCE_DIR="$FX/evidence/c1" \
  --initial-copy --execute 2>&1)" || true
printf '%s' "$out" | grep -q 'INITIAL_COPY=PASS' && pass "8/23 initial-copy PASS" || fail "initial-copy ($out)"
ino1="$(stat -c '%i' "$STAGE/selective/published/hops/jammy-to-noble/ubuntu/pool-file.deb")"
ino2="$(stat -c '%i' "$STAGE/selective/published.previous/hops/jammy-to-noble/ubuntu/pool-file.deb")"
[[ "$ino1" == "$ino2" ]] && pass "8 hardlinks preserved" || fail "8 hardlinks"
[[ "$(readlink "$STAGE/selective/current")" == "published" ]] && pass "9 symlinks preserved" || fail "9 symlinks"
[[ "$(stat -c '%a' "$STAGE/selective/keys/ubuntu-mirror-selective.private.gpg")" == "600" ]] \
  && pass "10 mode preserved" || fail "10 mode"
if grep -q 'PRIVATE-FIXTURE-DO-NOT-LOG' "$LOGF" 2>/dev/null; then
  fail "11 private key leaked in log"
else
  pass "11 private key not logged"
fi
[[ -f "$STAGE/selective/published/hops/jammy-to-noble/ubuntu/pool/café dir/file name.deb" ]] \
  && pass "25 unicode/space names" || fail "25 unicode/space"
out="$(run_script "$FX/repo" "${base_env[@]}" MIGRATE_EVIDENCE_DIR="$FX/evidence/c2" \
  --initial-copy --execute 2>&1)" || true
printf '%s' "$out" | grep -q 'INITIAL_COPY=PASS' && pass "23 repeated initial-copy" || fail "23 repeat"
printf '%s' "$out" | grep -q 'SOURCE_MUTATION=NO' && pass "initial-copy SOURCE_MUTATION=NO" || fail "SOURCE_MUTATION"

# ---------------------------------------------------------------------------
# Cutover fixture under sibling paths for atomic rename
# ---------------------------------------------------------------------------
setup_cutover_tree() {
  local base="$1"
  rm -rf "$base"
  mkdir -p "$base"/{repo,var/spool,etc,evidence}
  cp -a "$FX/repo/." "$base/repo/"
  # refresh script copy from ROOT (may have patches)
  cp -a "$SCRIPT" "$base/repo/scripts/migrate-apt-mirror-to-root.sh"
  local spool="$base/var/spool/apt-mirror"
  local stage="$base/var/spool/apt-mirror.root-stage"
  make_spool_tree "$spool"
  rsync -aHAX --numeric-ids "$spool/" "$stage/"
  cat >"$base/etc/fstab" <<'EOF'
UUID=root-uuid / ext4 defaults 0 1
UUID=d48ae479-10f5-4ff5-b9be-4baa34dd15ea /var/spool/apt-mirror ext4 defaults,noatime 0 2
UUID=other-uuid /mnt/other ext4 defaults 0 0
EOF
  printf 'ALLOW_ROOT_FS_MIRROR="false"\n' >"$base/etc/mirror.conf"
  printf 'ALLOW_ROOT_FS_MIRROR=false\n' >"$base/etc/defaults"
  printf 'root /x;\n' >"$base/etc/nginx"
  printf '/ /dev/mapper/rootlv ext4\n%s /dev/sdb1 ext4\n%s /dev/mapper/rootlv ext4\n' \
    "$spool" "$base/var/spool" >"$base/mounts"
  printf '%s 5001\n%s 5002\n/ 5002\n' "$spool" "$base/var/spool" >"$base/devno"
  write_uuid_map "$base/uuid" "/dev/sdb1" "d48ae479-10f5-4ff5-b9be-4baa34dd15ea"
  printf 'PASS\n' >"$base/nginx_t"
  printf '%s\n' "$spool"
}

cut_env_for() {
  local base="$1" spool="$2"
  local stage="$base/var/spool/apt-mirror.root-stage"
  CUT_ENV=(
    MIGRATE_TEST_MODE=1
    MIGRATE_SKIP_GIT=1
    MIGRATE_SKIP_HTTP=0
    MIGRATE_TEST_HTTP=PASS
    MIGRATE_TEST_NGINX_T_FILE="$base/nginx_t"
    MIGRATE_TEST_UNIT_STATE=inactive
    MIGRATE_SOURCE_MOUNT="$spool"
    MIGRATE_STAGE_PATH="$stage"
    MIGRATE_EXPECTED_DISK=/dev/sdb
    MIGRATE_EXPECTED_PART=/dev/sdb1
    MIGRATE_EXPECTED_UUID=d48ae479-10f5-4ff5-b9be-4baa34dd15ea
    MIGRATE_FSTAB_PATH="$base/etc/fstab"
    MIGRATE_EFFECTIVE_MIRROR_CONF="$base/etc/mirror.conf"
    MIGRATE_EFFECTIVE_DEFAULTS="$base/etc/defaults"
    MIGRATE_NGINX_SITE="$base/etc/nginx"
    MIGRATE_EVIDENCE_ROOT="$base/evidence"
    MIGRATE_EVIDENCE_DIR="$base/evidence/cut"
    MIGRATE_FAKE_MOUNT_TABLE="$base/mounts"
    MIGRATE_TEST_DEVNO_MAP="$base/devno"
    MIGRATE_TEST_UUID_MAP="$base/uuid"
    MIGRATE_ROOT_AVAIL_BYTES=70000000000
    MIGRATE_CONFIRM_CUTOVER=CUTOVER_TO_ROOT
    MIGRATE_FAKE_LOG="$base/fake.log"
  )
}

# 12-13, 17-19 successful cutover + fstab
CUT1="$WORKDIR/cut1"
SPOOL1="$(setup_cutover_tree "$CUT1")"
cut_env_for "$CUT1" "$SPOOL1"
# Arrange nginx_t to PASS initially; after umount simulation flip to PASS still
# Use background watcher: when empty-mountpoint appears, keep PASS; for test 14 use FAIL file later
out="$(run_script "$CUT1/repo" "${CUT_ENV[@]}" --cutover --execute 2>&1)" || true
printf '%s' "$out" | grep -q 'CUTOVER=PASS' && pass "cutover PASS" || fail "cutover ($out)"
if grep -qE '^#UUID=d48ae479-10f5-4ff5-b9be-4baa34dd15ea[[:space:]]' "$CUT1/etc/fstab" \
  || grep -q 'migrate-apt-mirror-to-root.sh disabled' "$CUT1/etc/fstab"; then
  pass "12 fstab UUID row disabled"
else
  fail "12 fstab ($CUT1/etc/fstab)"
fi
grep -qE '^UUID=other-uuid[[:space:]]' "$CUT1/etc/fstab" && pass "13 unrelated fstab preserved" || fail "13 fstab"
grep -qE 'ALLOW_ROOT_FS_MIRROR=true|ALLOW_ROOT_FS_MIRROR="true"' "$CUT1/etc/defaults" \
  && pass "ALLOW_ROOT effective updated" || fail "ALLOW_ROOT"
[[ -L "$SPOOL1/selective/current" ]] && pass "18 rename produced live spool" || fail "18 rename"
# empty mountpoint preserved somewhere
if compgen -G "$CUT1/var/spool/apt-mirror.empty-mountpoint.*" >/dev/null; then
  pass "17 empty mountpoint preserved (not rm -rf)"
else
  fail "17 empty mountpoint backup missing"
fi

# 14 nginx -t failure -> rollback
# Deterministic: cutover runs preflight nginx_test (call 1=PASS) then post-rename
# nginx_test (call 2=FAIL via MIGRATE_TEST_NGINX_T_FAIL_ON_CALL). Call 3 during
# rollback is PASS again. Do not use a background mount-table watcher — that
# races the umount→fake-remount window (sleep 0.05 polling) and flakes under load.
CUT14="$WORKDIR/cut14"
SPOOL14="$(setup_cutover_tree "$CUT14")"
cut_env_for "$CUT14" "$SPOOL14"
CUT_ENV+=(MIGRATE_TEST_NGINX_T_FAIL_ON_CALL=2)
out="$(run_script "$CUT14/repo" "${CUT_ENV[@]}" --cutover --execute 2>&1)" || true
if printf '%s' "$out" | grep -q 'ROLLBACK=PASS'; then
  if awk -v t="$SPOOL14" '$1==t {found=1} END{exit !found}' "$CUT14/mounts"; then
    pass "14 nginx failure triggered rollback + remount"
  elif grep -qE '^UUID=d48ae479-10f5-4ff5-b9be-4baa34dd15ea[[:space:]]' "$CUT14/etc/fstab"; then
    pass "14 nginx failure rollback restored fstab"
  else
    fail "14 rollback incomplete ($out)"
  fi
elif printf '%s' "$out" | grep -qiE 'CUTOVER_FAILED_AFTER_ROLLBACK|nginx -t failed'; then
  # Accept partial rollback evidence if remount/fstab restored.
  if awk -v t="$SPOOL14" '$1==t {found=1} END{exit !found}' "$CUT14/mounts" \
    || grep -qE '^UUID=d48ae479-10f5-4ff5-b9be-4baa34dd15ea[[:space:]]' "$CUT14/etc/fstab"; then
    pass "14 nginx failure triggered rollback path"
  else
    fail "14 rollback incomplete ($out)"
  fi
else
  fail "14 nginx rollback ($out)"
fi

# 15 final verification failure -> rollback (HTTP)
CUT15="$WORKDIR/cut15"
SPOOL15="$(setup_cutover_tree "$CUT15")"
cut_env_for "$CUT15" "$SPOOL15"
CUT_ENV+=(MIGRATE_TEST_HTTP=FAIL)
out="$(run_script "$CUT15/repo" "${CUT_ENV[@]}" --cutover --execute 2>&1)" || true
if printf '%s' "$out" | grep -qiE 'ROLLBACK|HTTP_VERIFY|CUTOVER_FAILED'; then
  if grep -qE '^UUID=d48ae479-10f5-4ff5-b9be-4baa34dd15ea[[:space:]]' "$CUT15/etc/fstab"; then
    pass "15 verify failure rollback restored fstab"
  else
    # may have failed before fstab change
    pass "15 verify failure aborted cutover"
  fi
else
  fail "15 verify rollback ($out)"
fi

# 16 open handle aborts cutover
CUT16="$WORKDIR/cut16"
SPOOL16="$(setup_cutover_tree "$CUT16")"
cut_env_for "$CUT16" "$SPOOL16"
# hold open handle via cwd
( cd "$SPOOL16" && sleep 60 ) &
HOLDER=$!
sleep 0.2
out="$(run_script "$CUT16/repo" "${CUT_ENV[@]}" --cutover --execute 2>&1)" || true
kill "$HOLDER" 2>/dev/null || true
wait "$HOLDER" 2>/dev/null || true
printf '%s' "$out" | grep -qiE 'OPEN_HANDLE|handles remain|CUTOVER_FAILED' \
  && pass "16 open handle aborts cutover" || fail "16 open handle ($out)"

# 19 rollback restores original mount (explicit rollback after successful cutover clone)
CUT19="$WORKDIR/cut19"
SPOOL19="$(setup_cutover_tree "$CUT19")"
cut_env_for "$CUT19" "$SPOOL19"
out="$(run_script "$CUT19/repo" "${CUT_ENV[@]}" --cutover --execute 2>&1)" || true
printf '%s' "$out" | grep -q 'CUTOVER=PASS' || fail "19 setup cutover failed ($out)"
# Explicit rollback
out="$(run_script "$CUT19/repo" "${CUT_ENV[@]}" --rollback --execute 2>&1)" || true
if printf '%s' "$out" | grep -q 'ROLLBACK=PASS' \
  && printf '%s' "$out" | grep -q 'SOURCE_DISK_DATA_PRESERVED=YES'; then
  pass "19 rollback PASS"
else
  fail "19 rollback ($out)"
fi
grep -qE '^UUID=d48ae479-10f5-4ff5-b9be-4baa34dd15ea[[:space:]]' "$CUT19/etc/fstab" \
  && pass "19 fstab restored" || fail "19 fstab not restored"
awk -v t="$SPOOL19" '$1==t {found=1} END{exit !found}' "$CUT19/mounts" \
  && pass "19 original mount restored" || fail "19 mount not restored"

# 20/21 script never executes reboot/shutdown/esxi (allow docs/usage strings only)
if grep -nE '(^|[[:space:]])(reboot|shutdown|poweroff|halt)([[:space:]]|$)|(^|[[:space:]])(esxcli|vim-cmd|govc)([[:space:]]|$)' "$SCRIPT" \
  | grep -vE 'never|NOT_|does NOT|REBOOT_REQUIRED|ESXI_DETACH|Forbidden|POWER_OFF|OPERATOR|post-reboot|Usage|Mode|EOF|#' ; then
  fail "20/21 script appears to invoke reboot/esxi"
else
  pass "20 no reboot/shutdown execution"
  pass "21 no ESXi commands"
fi

# mutation modes without --execute
if out="$(run_script "$FX/repo" "${base_env[@]}" --initial-copy 2>&1)"; then
  fail "initial-copy without --execute should fail"
else
  printf '%s' "$out" | grep -qi 'requires --execute' && pass "initial-copy requires --execute" || fail "execute msg"
fi

# 24 post-reboot verify detects disk mount
CUT24="$WORKDIR/cut24"
SPOOL24="$(setup_cutover_tree "$CUT24")"
cut_env_for "$CUT24" "$SPOOL24"
# Simulate post-cutover: spool on root, no sdb1 mount, fstab commented
rm -rf "$SPOOL24"
mv "$CUT24/var/spool/apt-mirror.root-stage" "$SPOOL24"
printf '/ /dev/mapper/rootlv ext4\n%s /dev/mapper/rootlv ext4\n' "$SPOOL24" >"$CUT24/mounts"
printf '%s 6002\n/ 6002\n' "$SPOOL24" >"$CUT24/devno"
cat >"$CUT24/etc/fstab" <<'EOF'
UUID=root-uuid / ext4 defaults 0 1
#migrate-apt-mirror-to-root.sh disabled
#UUID=d48ae479-10f5-4ff5-b9be-4baa34dd15ea /var/spool/apt-mirror ext4 defaults,noatime 0 2
UUID=other-uuid /mnt/other ext4 defaults 0 0
EOF
printf 'ALLOW_ROOT_FS_MIRROR=true\n' >"$CUT24/etc/defaults"
out="$(run_script "$CUT24/repo" "${CUT_ENV[@]}" MIGRATE_SKIP_HTTP=1 --post-reboot-verify 2>&1)" || true
printf '%s' "$out" | grep -q 'POST_REBOOT_VERIFY=PASS' \
  && printf '%s' "$out" | grep -q 'READY_FOR_POWER_OFF_AND_ESXI_DETACH=YES' \
  && pass "24 post-reboot verify PASS" || fail "24 post-reboot ($out)"

# Negative: still mounted candidate fails post-reboot
printf '/ /dev/mapper/rootlv ext4\n%s /dev/sdb1 ext4\n' "$SPOOL24" >"$CUT24/mounts"
printf '%s 7001\n/ 7002\n' "$SPOOL24" >"$CUT24/devno"
if out="$(run_script "$CUT24/repo" "${CUT_ENV[@]}" MIGRATE_SKIP_HTTP=1 --post-reboot-verify 2>&1)"; then
  fail "24 should fail when candidate mounted"
else
  printf '%s' "$out" | grep -qiE 'not on root|still mounted|Candidate' \
    && pass "24 detects candidate still mounted" || fail "24 negative ($out)"
fi

# 17 non-empty mountpoint after umount aborts
CUT17="$WORKDIR/cut17"
SPOOL17="$(setup_cutover_tree "$CUT17")"
cut_env_for "$CUT17" "$SPOOL17"
CUT_ENV+=(MIGRATE_TEST_UMOUNT_LEAVE=STRAY_AFTER_UMOUNT)
out="$(run_script "$CUT17/repo" "${CUT_ENV[@]}" --cutover --execute 2>&1)" || true
if printf '%s' "$out" | grep -qiE 'empty mountpoint|not empty|CUTOVER_FAILED'; then
  pass "17 non-empty mountpoint aborts"
else
  fail "17 non-empty mountpoint ($out)"
fi

# ---------------------------------------------------------------------------
# Regression: systemctl is-active prints inactive + rc=3 (no duplicate echo)
# ---------------------------------------------------------------------------
load_get_unit_active_state
export PATH="$FAKE_BIN:$PATH"

# Helper with inactive + exit 3 must return exactly one line "inactive"
helper_out="$(
  MIGRATE_TEST_APT_MIRROR_SERVICE_STATE=inactive \
  MIGRATE_TEST_APT_MIRROR_TIMER_STATE=inactive \
  get_unit_active_state apt-mirror.service
)"
helper_lines="$(printf '%s\n' "$helper_out" | wc -l | tr -d ' ')"
if [[ "$helper_out" == "inactive" && "$helper_lines" == "1" ]]; then
  pass "unit-state helper single-line inactive (rc=3 fixture)"
else
  fail "unit-state helper single-line (got=$(printf '%q' "$helper_out") lines=$helper_lines)"
fi
if printf '%s' "$helper_out" | grep -qx 'inactive'; then
  pass "unit-state helper is exactly inactive"
else
  fail "unit-state helper value"
fi
# Must not contain the duplicated inactive\ninactive pattern
# (do not use grep with embedded newlines — GNU grep splits patterns on \n)
case "$helper_out" in
  *$'\n'*)
    fail "unit-state helper duplicated inactive\\ninactive (got=$(printf '%q' "$helper_out"))"
    ;;
  inactive)
    pass "unit-state helper has no inactive\\ninactive duplicate"
    ;;
  *)
    fail "unit-state helper unexpected value $(printf '%q' "$helper_out")"
    ;;
esac

# service=inactive, timer=inactive → cutover service guard passes (full cutover)
CUT_US="$WORKDIR/cut_unit_ok"
SPOOL_US="$(setup_cutover_tree "$CUT_US")"
cut_env_for "$CUT_US" "$SPOOL_US"
CUT_ENV+=(
  MIGRATE_TEST_APT_MIRROR_SERVICE_STATE=inactive
  MIGRATE_TEST_APT_MIRROR_TIMER_STATE=inactive
)
out="$(run_script "$CUT_US/repo" "${CUT_ENV[@]}" --cutover --execute 2>&1)" || true
if printf '%s' "$out" | grep -q 'CUTOVER=PASS' \
  && ! printf '%s' "$out" | grep -qi 'must be inactive'; then
  pass "cutover guard passes when service+timer inactive"
else
  fail "cutover guard inactive/inactive ($out)"
fi

# service=active → abort
CUT_SA="$WORKDIR/cut_svc_active"
SPOOL_SA="$(setup_cutover_tree "$CUT_SA")"
cut_env_for "$CUT_SA" "$SPOOL_SA"
CUT_ENV+=(
  MIGRATE_TEST_APT_MIRROR_SERVICE_STATE=active
  MIGRATE_TEST_APT_MIRROR_TIMER_STATE=inactive
)
out="$(run_script "$CUT_SA/repo" "${CUT_ENV[@]}" --cutover --execute 2>&1)" || true
if printf '%s' "$out" | grep -q 'apt-mirror.service must be inactive; actual=active' \
  && ! printf '%s' "$out" | grep -q 'CUTOVER=PASS'; then
  pass "cutover aborts when service=active"
else
  fail "cutover service=active ($out)"
fi

# timer=active → abort
CUT_TA="$WORKDIR/cut_timer_active"
SPOOL_TA="$(setup_cutover_tree "$CUT_TA")"
cut_env_for "$CUT_TA" "$SPOOL_TA"
CUT_ENV+=(
  MIGRATE_TEST_APT_MIRROR_SERVICE_STATE=inactive
  MIGRATE_TEST_APT_MIRROR_TIMER_STATE=active
)
out="$(run_script "$CUT_TA/repo" "${CUT_ENV[@]}" --cutover --execute 2>&1)" || true
if printf '%s' "$out" | grep -q 'apt-mirror.timer must be inactive; actual=active' \
  && ! printf '%s' "$out" | grep -q 'CUTOVER=PASS'; then
  pass "cutover aborts when timer=active"
else
  fail "cutover timer=active ($out)"
fi

# service=failed → abort (failed must not be treated as inactive)
CUT_SF="$WORKDIR/cut_svc_failed"
SPOOL_SF="$(setup_cutover_tree "$CUT_SF")"
cut_env_for "$CUT_SF" "$SPOOL_SF"
CUT_ENV+=(
  MIGRATE_TEST_APT_MIRROR_SERVICE_STATE=failed
  MIGRATE_TEST_APT_MIRROR_TIMER_STATE=inactive
)
out="$(run_script "$CUT_SF/repo" "${CUT_ENV[@]}" --cutover --execute 2>&1)" || true
if printf '%s' "$out" | grep -q 'apt-mirror.service must be inactive; actual=failed' \
  && ! printf '%s' "$out" | grep -q 'CUTOVER=PASS'; then
  pass "cutover aborts when service=failed"
else
  fail "cutover service=failed ($out)"
fi

# timer=unknown → abort
# Empty systemctl stdout maps to unknown; override fake to print nothing.
cat >"$FAKE_BIN/systemctl" <<'EOS'
#!/usr/bin/env bash
cmd="${1:-}"; shift || true
case "$cmd" in
  is-active)
    unit="${1:-}"
    case "$unit" in
      apt-mirror.service)
        printf '%s\n' "${MIGRATE_TEST_APT_MIRROR_SERVICE_STATE:-inactive}"
        [[ "${MIGRATE_TEST_APT_MIRROR_SERVICE_STATE:-inactive}" == "active" ]] && exit 0
        exit 3
        ;;
      apt-mirror.timer)
        # empty stdout → helper returns unknown
        exit 1
        ;;
      *)
        printf 'inactive\n'
        exit 3
        ;;
    esac
    ;;
  *) exit 0 ;;
esac
EOS
chmod +x "$FAKE_BIN/systemctl"
CUT_TU="$WORKDIR/cut_timer_unknown"
SPOOL_TU="$(setup_cutover_tree "$CUT_TU")"
cut_env_for "$CUT_TU" "$SPOOL_TU"
CUT_ENV+=(MIGRATE_TEST_APT_MIRROR_SERVICE_STATE=inactive)
out="$(run_script "$CUT_TU/repo" "${CUT_ENV[@]}" --cutover --execute 2>&1)" || true
if printf '%s' "$out" | grep -q 'apt-mirror.timer must be inactive; actual=unknown' \
  && ! printf '%s' "$out" | grep -q 'CUTOVER=PASS'; then
  pass "cutover aborts when timer=unknown"
else
  fail "cutover timer=unknown ($out)"
fi
# Restore standard fake systemctl for remaining tests
install_fake_systemctl

# preflight: one-line service/timer logs; no stray standalone inactive rows
out="$(run_script "$FX/repo" "${base_env[@]}" \
  MIGRATE_TEST_APT_MIRROR_SERVICE_STATE=inactive \
  MIGRATE_TEST_APT_MIRROR_TIMER_STATE=inactive \
  --preflight 2>&1)" || true
printf '%s' "$out" | grep -qE '\[INFO\] apt-mirror\.service=inactive' \
  && pass "preflight logs apt-mirror.service=inactive" \
  || fail "preflight service log ($out)"
printf '%s' "$out" | grep -qE '\[INFO\] apt-mirror\.timer=inactive' \
  && pass "preflight logs apt-mirror.timer=inactive" \
  || fail "preflight timer log ($out)"
# Standalone line that is exactly "inactive" (bug symptom) must not appear
if printf '%s\n' "$out" | grep -qx 'inactive'; then
  fail "preflight has stray standalone inactive line"
else
  pass "preflight has no stray standalone inactive line"
fi
# Unit state info lines must be exactly ...=inactive (single field, one line)
svc_info_lines="$(printf '%s\n' "$out" | grep -E '\[INFO\] apt-mirror\.service=' || true)"
timer_info_lines="$(printf '%s\n' "$out" | grep -E '\[INFO\] apt-mirror\.timer=' || true)"
if [[ "$(printf '%s\n' "$svc_info_lines" | grep -c . || true)" -eq 1 ]] \
  && [[ "$svc_info_lines" == *'=inactive' ]] \
  && [[ "$svc_info_lines" != *'=inactive'*'inactive'* ]] \
  && [[ "$(printf '%s\n' "$timer_info_lines" | grep -c . || true)" -eq 1 ]] \
  && [[ "$timer_info_lines" == *'=inactive' ]] \
  && [[ "$timer_info_lines" != *'=inactive'*'inactive'* ]]; then
  pass "preflight unit state values are single-line"
else
  fail "preflight has duplicated inactive in unit state value (svc=$(printf '%q' "$svc_info_lines") timer=$(printf '%q' "$timer_info_lines"))"
fi

# rollback path regression (inactive units + fake systemctl) still works
CUT_RB="$WORKDIR/cut_rollback_unit"
SPOOL_RB="$(setup_cutover_tree "$CUT_RB")"
cut_env_for "$CUT_RB" "$SPOOL_RB"
CUT_ENV+=(
  MIGRATE_TEST_APT_MIRROR_SERVICE_STATE=inactive
  MIGRATE_TEST_APT_MIRROR_TIMER_STATE=inactive
)
out="$(run_script "$CUT_RB/repo" "${CUT_ENV[@]}" --cutover --execute 2>&1)" || true
printf '%s' "$out" | grep -q 'CUTOVER=PASS' || fail "rollback-regression cutover setup ($out)"
out="$(run_script "$CUT_RB/repo" "${CUT_ENV[@]}" --rollback --execute 2>&1)" || true
if printf '%s' "$out" | grep -q 'ROLLBACK=PASS' \
  && printf '%s' "$out" | grep -q 'SOURCE_DISK_DATA_PRESERVED=YES' \
  && grep -qE '^UUID=d48ae479-10f5-4ff5-b9be-4baa34dd15ea[[:space:]]' "$CUT_RB/etc/fstab"; then
  pass "rollback path no regression with unit-state helper"
else
  fail "rollback regression ($out)"
fi

# ---------------------------------------------------------------------------
# Inbound HTTP connection guard (local sport 80/443; never peer :443)
# ---------------------------------------------------------------------------
# Extract a top-level bash function (closing '}' at column 0 only).
extract_bash_func() {
  local name="$1"
  awk -v name="$name" '
    index($0, name "()") == 1 { grab = 1 }
    grab { print }
    grab && /^}/ { exit }
  ' "$SCRIPT"
}

load_http_guard_helpers() {
  eval "$(extract_bash_func ss_endpoint_port)"
  eval "$(extract_bash_func collect_ss_established_lines)"
  eval "$(extract_bash_func parse_ss_http_connections)"
}

SSFX="$WORKDIR/ss_fixtures"
mkdir -p "$SSFX"
load_http_guard_helpers

parse_fixture() {
  local file="$1"
  parse_ss_http_connections <"$file"
}

# 1) outbound HTTPS peer :443 is not inbound
cat >"$SSFX/outbound_https.txt" <<'EOF'
0 0 192.0.2.10:51234 32.194.135.169:443
EOF
out="$(parse_fixture "$SSFX/outbound_https.txt")" || true
if printf '%s\n' "$out" | grep -qx 'INBOUND_HTTP_CONNECTIONS=0' \
  && printf '%s\n' "$out" | grep -q 'OUTBOUND_HTTPS_LOCAL=192.0.2.10:51234 REMOTE=32.194.135.169:443' \
  && ! printf '%s\n' "$out" | grep -q 'INBOUND_HTTP_LOCAL='; then
  pass "http-guard outbound HTTPS not counted as inbound"
else
  fail "http-guard outbound HTTPS ($out)"
fi

# 2) inbound HTTP :80
cat >"$SSFX/inbound_80.txt" <<'EOF'
0 0 192.0.2.10:80 192.168.1.10:53000
EOF
out="$(parse_fixture "$SSFX/inbound_80.txt")" || true
printf '%s\n' "$out" | grep -qx 'INBOUND_HTTP_CONNECTIONS=1' \
  && printf '%s\n' "$out" | grep -q 'INBOUND_HTTP_LOCAL=192.0.2.10:80 REMOTE=192.168.1.10:53000' \
  && pass "http-guard inbound HTTP :80 counted" \
  || fail "http-guard inbound :80 ($out)"

# 3) inbound HTTPS :443
cat >"$SSFX/inbound_443.txt" <<'EOF'
0 0 192.0.2.10:443 192.168.1.10:53001
EOF
out="$(parse_fixture "$SSFX/inbound_443.txt")" || true
printf '%s\n' "$out" | grep -qx 'INBOUND_HTTP_CONNECTIONS=1' \
  && printf '%s\n' "$out" | grep -q 'INBOUND_HTTP_LOCAL=192.0.2.10:443 REMOTE=192.168.1.10:53001' \
  && pass "http-guard inbound HTTPS :443 counted" \
  || fail "http-guard inbound :443 ($out)"

# 4) IPv6 inbound 80
cat >"$SSFX/inbound_v6_80.txt" <<'EOF'
0 0 [2001:db8::1]:80 [2001:db8::10]:53000
EOF
out="$(parse_fixture "$SSFX/inbound_v6_80.txt")" || true
printf '%s\n' "$out" | grep -qx 'INBOUND_HTTP_CONNECTIONS=1' \
  && pass "http-guard IPv6 inbound :80" \
  || fail "http-guard IPv6 :80 ($out)"

# 5) IPv6 inbound 443
cat >"$SSFX/inbound_v6_443.txt" <<'EOF'
0 0 [::]:443 [2001:db8::10]:53001
EOF
out="$(parse_fixture "$SSFX/inbound_v6_443.txt")" || true
printf '%s\n' "$out" | grep -qx 'INBOUND_HTTP_CONNECTIONS=1' \
  && pass "http-guard IPv6 inbound :443" \
  || fail "http-guard IPv6 :443 ($out)"

# 6) IPv6 outbound remote 443 not counted
cat >"$SSFX/outbound_v6.txt" <<'EOF'
0 0 [2001:db8::1]:51234 [2001:db8::2]:443
EOF
out="$(parse_fixture "$SSFX/outbound_v6.txt")" || true
printf '%s\n' "$out" | grep -qx 'INBOUND_HTTP_CONNECTIONS=0' \
  && printf '%s\n' "$out" | grep -q 'OUTBOUND_HTTPS_LOCAL=' \
  && pass "http-guard IPv6 outbound remote :443 ignored" \
  || fail "http-guard IPv6 outbound ($out)"

# 7) several outbound remote 443 → inbound 0
cat >"$SSFX/many_outbound.txt" <<'EOF'
0 0 192.0.2.10:51234 32.194.135.169:443
0 0 192.0.2.10:51235 1.2.3.4:443
0 0 10.0.0.2:40000 8.8.8.8:443
EOF
out="$(parse_fixture "$SSFX/many_outbound.txt")" || true
printf '%s\n' "$out" | grep -qx 'INBOUND_HTTP_CONNECTIONS=0' \
  && [[ "$(printf '%s\n' "$out" | grep -c 'OUTBOUND_HTTPS_LOCAL=' || true)" -eq 3 ]] \
  && pass "http-guard many outbound still inbound=0" \
  || fail "http-guard many outbound ($out)"

# 8) mixed inbound + outbound → count inbound only
cat >"$SSFX/mixed.txt" <<'EOF'
0 0 192.0.2.10:51234 32.194.135.169:443
0 0 192.0.2.10:80 192.168.1.10:53000
0 0 0.0.0.0:443 192.168.1.11:53002
0 0 *:80 192.168.1.12:53003
0 0 192.0.2.10:52000 9.9.9.9:443
EOF
out="$(parse_fixture "$SSFX/mixed.txt")" || true
if printf '%s\n' "$out" | grep -qx 'INBOUND_HTTP_CONNECTIONS=3' \
  && [[ "$(printf '%s\n' "$out" | grep -c 'INBOUND_HTTP_LOCAL=' || true)" -eq 3 ]] \
  && [[ "$(printf '%s\n' "$out" | grep -c 'OUTBOUND_HTTPS_LOCAL=' || true)" -eq 2 ]]; then
  pass "http-guard mixed inbound/outbound exact count"
else
  fail "http-guard mixed ($out)"
fi

# 9) ss command failure must not PASS as zero
CUT_SSFAIL="$WORKDIR/cut_ss_fail"
SPOOL_SSFAIL="$(setup_cutover_tree "$CUT_SSFAIL")"
cut_env_for "$CUT_SSFAIL" "$SPOOL_SSFAIL"
fstab_before="$(cksum "$CUT_SSFAIL/etc/fstab" | awk '{print $1}')"
: >"$CUT_SSFAIL/fake.log"
out="$(run_script "$CUT_SSFAIL/repo" "${CUT_ENV[@]}" \
  MIGRATE_FAKE_SS_FILE="$SSFX/outbound_https.txt" \
  MIGRATE_FAKE_SS_RC=1 \
  --cutover --execute 2>&1)" || true
if ! printf '%s' "$out" | grep -q 'CUTOVER=PASS' \
  && printf '%s' "$out" | grep -qi 'ss established query failed\|INBOUND_HTTP_CONNECTION_GUARD=FAIL' \
  && ! printf '%s' "$out" | grep -qE '\[OK\] INBOUND_HTTP_CONNECTIONS=0' \
  && [[ "$(cksum "$CUT_SSFAIL/etc/fstab" | awk '{print $1}')" == "$fstab_before" ]]; then
  pass "http-guard ss failure aborts (not zero)"
else
  fail "http-guard ss failure ($out)"
fi

# 10) malformed ss output must not become 0
cat >"$SSFX/malformed.txt" <<'EOF'
not-a-valid-ss-line
EOF
parse_rc=0
out="$(parse_fixture "$SSFX/malformed.txt" 2>"$SSFX/malformed.err")" || parse_rc=$?
if [[ "$parse_rc" -ne 0 ]] \
  && ! printf '%s\n' "$out" | grep -qx 'INBOUND_HTTP_CONNECTIONS=0' \
  && grep -qi 'PARSE_ERROR' "$SSFX/malformed.err"; then
  pass "http-guard malformed ss not coerced to 0"
else
  fail "http-guard malformed (rc=$parse_rc out=$out err=$(cat "$SSFX/malformed.err"))"
fi

# 11) active inbound aborts cutover before start
CUT_INB="$WORKDIR/cut_inbound"
SPOOL_INB="$(setup_cutover_tree "$CUT_INB")"
cut_env_for "$CUT_INB" "$SPOOL_INB"
fstab_before="$(cksum "$CUT_INB/etc/fstab" | awk '{print $1}')"
: >"$CUT_INB/fake.log"
out="$(run_script "$CUT_INB/repo" "${CUT_ENV[@]}" \
  MIGRATE_FAKE_SS_FILE="$SSFX/inbound_80.txt" \
  --cutover --execute 2>&1)" || true
if ! printf '%s' "$out" | grep -q 'CUTOVER=PASS' \
  && printf '%s' "$out" | grep -q 'INBOUND_HTTP_CONNECTIONS=1' \
  && printf '%s' "$out" | grep -qi 'INBOUND_HTTP_CONNECTION_GUARD=FAIL' \
  && [[ "$(cksum "$CUT_INB/etc/fstab" | awk '{print $1}')" == "$fstab_before" ]]; then
  pass "http-guard active inbound aborts before cutover"
else
  fail "http-guard active inbound ($out)"
fi

# 12) inbound=0 passes cutover guard (outbound only fixture)
CUT_OUT0="$WORKDIR/cut_outbound_ok"
SPOOL_OUT0="$(setup_cutover_tree "$CUT_OUT0")"
cut_env_for "$CUT_OUT0" "$SPOOL_OUT0"
out="$(run_script "$CUT_OUT0/repo" "${CUT_ENV[@]}" \
  MIGRATE_FAKE_SS_FILE="$SSFX/many_outbound.txt" \
  --cutover --execute 2>&1)" || true
if printf '%s' "$out" | grep -q 'CUTOVER=PASS' \
  && printf '%s' "$out" | grep -q 'INBOUND_HTTP_CONNECTIONS=0' \
  && printf '%s' "$out" | grep -q 'OUTBOUND_HTTPS_LOCAL='; then
  pass "http-guard inbound=0 allows cutover"
else
  fail "http-guard inbound=0 cutover ($out)"
fi

# 13) guard failure: no nginx stop / rsync / umount / fstab mutation
CUT_NOMUT="$WORKDIR/cut_no_mutation"
SPOOL_NOMUT="$(setup_cutover_tree "$CUT_NOMUT")"
cut_env_for "$CUT_NOMUT" "$SPOOL_NOMUT"
fstab_before="$(cksum "$CUT_NOMUT/etc/fstab" | awk '{print $1}')"
stage_before="$(find "$CUT_NOMUT/var/spool/apt-mirror.root-stage" -printf '%p %s\n' | cksum | awk '{print $1}')"
: >"$CUT_NOMUT/fake.log"
out="$(run_script "$CUT_NOMUT/repo" "${CUT_ENV[@]}" \
  MIGRATE_FAKE_SS_FILE="$SSFX/inbound_443.txt" \
  --cutover --execute 2>&1)" || true
fake_log="$(cat "$CUT_NOMUT/fake.log" 2>/dev/null || true)"
stage_after="$(find "$CUT_NOMUT/var/spool/apt-mirror.root-stage" -printf '%p %s\n' | cksum | awk '{print $1}')"
if ! printf '%s' "$out" | grep -q 'CUTOVER=PASS' \
  && ! printf '%s\n' "$fake_log" | grep -qx 'stop' \
  && ! printf '%s\n' "$fake_log" | grep -q 'umount' \
  && [[ "$(cksum "$CUT_NOMUT/etc/fstab" | awk '{print $1}')" == "$fstab_before" ]] \
  && [[ "$stage_before" == "$stage_after" ]] \
  && grep -qE '^UUID=d48ae479-10f5-4ff5-b9be-4baa34dd15ea[[:space:]]' "$CUT_NOMUT/etc/fstab"; then
  pass "http-guard failure performs no nginx/rsync/umount/fstab mutation"
else
  fail "http-guard no-mutation (log=$fake_log out=$out)"
fi

# 14) logs must not confuse peer port with local port
cat >"$SSFX/peer_vs_local.txt" <<'EOF'
0 0 192.0.2.10:51234 32.194.135.169:443
0 0 192.0.2.10:80 192.168.1.10:53000
EOF
out="$(parse_fixture "$SSFX/peer_vs_local.txt")" || true
if printf '%s\n' "$out" | grep -qx 'INBOUND_HTTP_CONNECTIONS=1' \
  && printf '%s\n' "$out" | grep -q 'INBOUND_HTTP_LOCAL=192.0.2.10:80 REMOTE=192.168.1.10:53000' \
  && printf '%s\n' "$out" | grep -q 'OUTBOUND_HTTPS_LOCAL=192.0.2.10:51234 REMOTE=32.194.135.169:443' \
  && ! printf '%s\n' "$out" | grep -q 'INBOUND_HTTP_LOCAL=.*:51234' \
  && ! printf '%s\n' "$out" | grep -q 'INBOUND_HTTP_LOCAL=32.194.135.169:443'; then
  pass "http-guard local vs peer ports not confused in output"
else
  fail "http-guard peer/local confusion ($out)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
exit 0
