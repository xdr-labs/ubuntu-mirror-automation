#!/usr/bin/env bash
# Authoritative clean-room integration test for the redesigned mirror workflow.
# No external services are contacted and no production paths are modified.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
HTTP_PID=""
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }
expect() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

TMP="$(mktemp -d)"
cleanup() {
  [[ -z "$HTTP_PID" ]] || kill "$HTTP_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
chmod 0755 "$TMP"

export MM_PROJECT_ROOT="$ROOT"
export MM_CONFIG_DIR="$TMP/etc/ubuntu-mirror"
export MM_CONFIG_FILE="$MM_CONFIG_DIR/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$MM_CONFIG_DIR/dp-upgrade-mirror.status"
export MM_WORKFLOW_FILE="$MM_CONFIG_DIR/dp-upgrade-workflow.state"
export MM_LOG_DIR="$TMP/var/log/ubuntu-mirror-automation"
export MM_MIRROR_ROOT="$TMP/var/spool/apt-mirror"
export MM_SELECTIVE_ROOT="$MM_MIRROR_ROOT/selective"
export MM_DP_PHASE2_ROOT="$MM_MIRROR_ROOT/dp-phase2"
export MM_CLIENT_ROOT="$MM_MIRROR_ROOT/client"
export LOCAL_CLIENT_SIGNING_DIR="$MM_CONFIG_DIR/client-signing"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_SKIP_HTTP_VALIDATE=1
mkdir -p "$MM_CONFIG_DIR" "$MM_LOG_DIR" "$MM_MIRROR_ROOT"
: >"$MM_STATUS_FILE"

# Install only the authoritative manifest into a snapshot-equivalent runtime.
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/runtime_manifest.sh
source "$ROOT/lib/runtime_manifest.sh"
RUNTIME="$TMP/usr/local/lib/ubuntu-mirror"
um_runtime_install_tree "$ROOT" "$RUNTIME"
expect "runtime dependency closure" um_runtime_verify_dependency_closure "$RUNTIME"
expect "runtime Python dependency closure" \
  um_runtime_verify_python_dependency_closure "$RUNTIME" "$ROOT"
for rel in \
  scripts/lib/client_build_repository.py \
  scripts/lib/atomic_dir_swap.py \
  scripts/lib/mirror_workflow_state.sh \
  client/lib/dp-offline-release-upgrade-reconciliation.sh \
  client/lib/dp-offline-apt-preflight-sandbox.sh
do
  expect "runtime contains $rel" test -f "$RUNTIME/$rel"
done
expect "reconciliation helper parses" \
  bash -n "$RUNTIME/client/lib/dp-offline-release-upgrade-reconciliation.sh"
expect "APT preflight sandbox helper parses" \
  bash -n "$RUNTIME/client/lib/dp-offline-apt-preflight-sandbox.sh"
printf 'RUNTIME_INSTALL_METHOD=um_runtime_install_tree\n'
printf 'RUNTIME_WILDCARD_PYTHON_COPY=NO\n'

# Load the installed production command generators without invoking main.
INSTALLER_LIB="$TMP/installer-lib.sh"
awk -v sd="$RUNTIME/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$RUNTIME/scripts/install-dp-upgrade-mirror.sh" >"$INSTALLER_LIB"
# shellcheck disable=SC1090
source "$INSTALLER_LIB"
# Installed copies are now the active signing/permission/state implementations.
# shellcheck disable=SC1090
source "$RUNTIME/scripts/lib/local_client_signing.sh"
# shellcheck disable=SC1090
source "$RUNTIME/scripts/lib/http_publication_permissions.sh"
# shellcheck disable=SC1090
source "$RUNTIME/scripts/lib/mirror_workflow_state.sh"

# Optional UI dependency: absence is valid in minimal CI.
if command -v dialog >/dev/null 2>&1; then
  pass "optional dialog package available"
else
  printf 'SKIP: optional dialog package is not installed\n'
fi

# Save a FULL-mode operator-confirmed documentation IP through production config.
PREPARATION_MODE=FULL
PHASE2_TARGET_VERSION=6.6.0
TARGET_DP_VERSION=6.6.0
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
ACPS_USERNAME=fixture-user
ACPS_PASSWORD=fixture-password
mm_save_gui_config >/dev/null
expect "FULL mode config persisted" grep -qx 'PREPARATION_MODE=FULL' "$MM_CONFIG_FILE"
expect "operator-confirmed fixture IP persisted" \
  grep -qx 'MIRROR_SERVER_IP=192.0.2.10' "$MM_CONFIG_FILE"

# Drive the production generation-bound state machine.
mm_wf_mark_configured
expect "state CONFIGURED" test "$(mm_wf_state)" = CONFIGURED
mm_wf_mark_prepared os-fixture-1 phase2-fixture-1
expect "state PREPARED" test "$(mm_wf_state)" = PREPARED

# Ephemeral signing identity and four signed fixture clients.
GPG_HOME="$TMP/gnupg"
mkdir -p "$GPG_HOME"
chmod 0700 "$GPG_HOME"
cat >"$GPG_HOME/batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Clean Snapshot Fixture
Name-Email: clean-snapshot@example.invalid
Expire-Date: 0
%no-protection
%commit
EOF
gpg --homedir "$GPG_HOME" --batch --gen-key "$GPG_HOME/batch" >/dev/null 2>&1
mkdir -p "$LOCAL_CLIENT_SIGNING_DIR"
gpg --homedir "$GPG_HOME" --batch --export --armor >"$LOCAL_CLIENT_SIGNING_DIR/public.gpg"
gpg --homedir "$GPG_HOME" --batch --export-secret-keys --armor \
  >"$LOCAL_CLIENT_SIGNING_DIR/private.gpg"
FPR="$(local_signing_fingerprint_of "$LOCAL_CLIENT_SIGNING_DIR/public.gpg")"
printf '%s\n' "$FPR" >"$LOCAL_CLIENT_SIGNING_DIR/fingerprint"
chmod 0700 "$LOCAL_CLIENT_SIGNING_DIR"
chmod 0600 "$LOCAL_CLIENT_SIGNING_DIR/private.gpg"
chmod 0644 "$LOCAL_CLIENT_SIGNING_DIR/public.gpg" "$LOCAL_CLIENT_SIGNING_DIR/fingerprint"
expect "ephemeral signing pair validates" local_signing_validate_pair \
  "$LOCAL_CLIENT_SIGNING_DIR/private.gpg" \
  "$LOCAL_CLIENT_SIGNING_DIR/public.gpg" \
  "$LOCAL_CLIENT_SIGNING_DIR/fingerprint"

SPOOL="$MM_MIRROR_ROOT"
mkdir -p "$SPOOL/client"
printf '#!/usr/bin/env bash\necho old-live\n' >"$SPOOL/client/old.sh"
chmod 0755 "$SPOOL" "$SPOOL/client" "$SPOOL/client/old.sh"
STAGE="$(mktemp -d "$SPOOL/.client.stage.XXXXXX")"
expect "mktemp stage begins non-public" test "$(stat -c '%a' "$STAGE")" = 700

HOPS=(xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble)
for hop in "${HOPS[@]}"; do
  script="dp-offline-upgrade-${hop}.sh"
  mkdir -p "$STAGE/$hop"
  printf '#!/usr/bin/env bash\nprintf "fixture hop %%s\\n" "%s"\n' "$hop" >"$STAGE/$script"
  chmod 0755 "$STAGE/$script"
  sha="$(sha256sum "$STAGE/$script" | awk '{print $1}')"
  printf '%s  %s\n' "$sha" "$script" >"$STAGE/$script.sha256"
  python3 - "$hop" "$script" "$sha" "$STAGE/$hop/client-manifest.json" <<'PY'
import json, sys
hop, script, digest, dest = sys.argv[1:]
with open(dest, "w", encoding="utf-8") as fh:
    json.dump({"hop": hop, "script": script, "script_sha256": digest}, fh)
    fh.write("\n")
PY
  gpg --homedir "$GPG_HOME" --batch --yes --armor --detach-sign \
    -o "$STAGE/$hop/client-manifest.json.asc" "$STAGE/$hop/client-manifest.json"
done
# Phase 2 stage helper + authenticated Menu 7 command-runner.
printf '#!/usr/bin/env bash\nprintf "fixture stage\\n"\n' >"$STAGE/stage-dp-phase2.sh"
chmod 0755 "$STAGE/stage-dp-phase2.sh"
( cd "$STAGE" && sha256sum stage-dp-phase2.sh >stage-dp-phase2.sh.sha256 )
LOCAL_SIGNING_PRIVATE_KEY="$LOCAL_CLIENT_SIGNING_DIR/private.gpg"
LOCAL_SIGNING_PUBLIC_KEY="$LOCAL_CLIENT_SIGNING_DIR/public.gpg"
LOCAL_KEY_FINGERPRINT="$FPR"
expect "command runner staged" \
  local_signing_stage_command_runner "$STAGE" "$ROOT/client/dp-client-command-runner.sh"
python3 "$RUNTIME/scripts/lib/build_client_launchers.py" \
  --project-root "$RUNTIME" \
  --output-dir "$STAGE" \
  --mirror-base-url "$MIRROR_HTTP_URL" \
  --signing-fingerprint "$FPR" >/dev/null
expect "launchers staged" test -f "$STAGE/dp-launch-xenial-to-bionic.sh"
local_signing_stage_http_public_artifacts \
  "$STAGE" "$LOCAL_CLIENT_SIGNING_DIR/public.gpg" "$FPR"
CLIENT_GEN="client-fixture-1"
mm_wf_write_client_set_metadata "$STAGE" "$CLIENT_GEN" "$FPR" \
  "$MIRROR_HTTP_URL" FULL
if mm_verify_http_public_tree_permissions "$STAGE" client >/dev/null 2>&1; then
  fail "0700 prepublish tree was accepted"
else
  pass "0700 prepublish tree rejected"
fi
expect "public permissions normalized" mm_client_stage_prepare_public_permissions "$STAGE" "$SPOOL"
expect "signed four-hop prepublish gate" \
  local_signing_prepublish_keyring_gate "$STAGE" "$FPR" "${HOPS[@]}"
if find "$STAGE" -type d ! -perm 0755 -print -quit | grep -q .; then
  fail "directories not normalized to 0755"
else
  pass "directories normalized to 0755"
fi
expect "data files normalized to 0644" \
  test "$(stat -c '%a' "$STAGE/public-keyring.gpg")" = 644

SWAP_OUT="$TMP/swap.out"
python3 "$RUNTIME/scripts/lib/atomic_dir_swap.py" \
  --stage-dir "$STAGE" --live-dir "$MM_CLIENT_ROOT" >"$SWAP_OUT"
expect "atomic client publication" grep -q 'CLIENT_SET_ATOMIC_SWAP=PASS' "$SWAP_OUT"
expect "live public permissions" \
  mm_client_live_postpublish_permission_verify "$MM_CLIENT_ROOT"
mm_wf_mark_client_set_published "$CLIENT_GEN" "$FPR"
expect "state CLIENT_SET_PUBLISHED" test "$(mm_wf_state)" = CLIENT_SET_PUBLISHED
mm_wf_mark_http_enabled "$CLIENT_GEN"
expect "state HTTP_ENABLED" test "$(mm_wf_state)" = HTTP_ENABLED
mm_wf_mark_readiness_verified
expect "state READINESS_VERIFIED" test "$(mm_wf_state)" = READINESS_VERIFIED

# Generate and atomically publish FULL commands.
COMMAND_TMP="$TMP/commands.new"
COMMAND_LIVE="$MM_LOG_DIR/dp-client-upgrade-commands.txt"
gui_build_client_commands "$MIRROR_HTTP_URL" single "" >"$COMMAND_TMP"
expect "FULL command structure validates" \
  mm_wf_validate_command_file_content "$COMMAND_TMP" FULL
FULL_HOP_COUNT=$(grep -cE '^cd /home/aella && curl -fsSLo dp-launch-' "$COMMAND_TMP" || true)
expect "FULL command has four hops" test "$FULL_HOP_COUNT" = 4
expect "FULL commands use LAUNCHER_V1" grep -q '^DP_OS_HOP_COMMAND_VERSION=LAUNCHER_V1$' "$COMMAND_TMP"
expect "FULL Phase2 still SUBSHELL_V2" grep -q '^DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2$' "$COMMAND_TMP"
expect "FULL hop commands are one-line" \
  test "$(gui_client_hop_command_line "$MIRROR_HTTP_URL" dp-offline-upgrade-xenial-to-bionic.sh | wc -l)" = 1
READY_GEN="$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)"
mm_wf_atomic_publish_command_file "$COMMAND_TMP" "$COMMAND_LIVE" FULL "$READY_GEN" >/dev/null
expect "state COMMANDS_GENERATED" test "$(mm_wf_state)" = COMMANDS_GENERATED

# An empty or malformed replacement must preserve the valid live file.
LIVE_SHA="$(sha256sum "$COMMAND_LIVE" | awk '{print $1}')"
: >"$TMP/empty.commands"
if mm_wf_atomic_publish_command_file "$TMP/empty.commands" "$COMMAND_LIVE" FULL "$READY_GEN" \
  >/dev/null 2>&1; then
  fail "empty command file replacement was accepted"
else
  pass "empty command file replacement rejected"
fi
expect "valid live command file preserved" test \
  "$(sha256sum "$COMMAND_LIVE" | awk '{print $1}')" = "$LIVE_SHA"

# Serve the published set locally, then execute generated Step 2 with sudo stub.
PORT_FILE="$TMP/http.port"
python3 - "$MM_MIRROR_ROOT" "$PORT_FILE" >"$TMP/http.out" 2>"$TMP/http.err" <<'PY' &
import http.server, os, sys
os.chdir(sys.argv[1])
server = http.server.ThreadingHTTPServer(
    ("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler
)
with open(sys.argv[2], "w", encoding="ascii") as fh:
    fh.write(str(server.server_port))
server.serve_forever()
PY
HTTP_PID=$!
for _ in {1..30}; do
  [[ -s "$PORT_FILE" ]] && break
  sleep 0.1
done
PORT="$(<"$PORT_FILE")"
for _ in {1..30}; do
  curl -fsS "http://127.0.0.1:$PORT/client/client-set.env" >/dev/null 2>&1 && break
  sleep 0.1
done
LOCAL_MIRROR="http://127.0.0.1:$PORT"
python3 "$RUNTIME/scripts/lib/build_client_launchers.py" \
  --project-root "$RUNTIME" \
  --output-dir "$MM_CLIENT_ROOT" \
  --mirror-base-url "$LOCAL_MIRROR" \
  --signing-fingerprint "$FPR" >/dev/null
STEP2_SHA=$(sha256sum "$MM_CLIENT_ROOT/dp-launch-xenial-to-bionic.sh" | awk '{print $1}')
STEP2=$(gui_client_hop_command_line "$LOCAL_MIRROR" \
  dp-offline-upgrade-xenial-to-bionic.sh "$STEP2_SHA")
expect "Step 2 generator emits one line" test "$(printf '%s\n' "$STEP2" | wc -l)" = 1
DP_HOME="$TMP/home/aella"
STUB_BIN="$TMP/stub-bin"
RUNS="$TMP/sudo-runs"
mkdir -p "$DP_HOME" "$STUB_BIN"
: >"$RUNS"
cat >"$STUB_BIN/sudo" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$RUNS"
exit 0
EOF
chmod 0755 "$STUB_BIN/sudo"
rewrite_command() {
  sed "s|cd /home/aella|cd '$DP_HOME'|g"
}
printf '%s\n' "$STEP2" | rewrite_command >"$TMP/step2.sh"
env PATH="$STUB_BIN:/usr/bin:/bin" bash "$TMP/step2.sh"
expect "Step 2 executes sudo exactly once" test "$(wc -l <"$RUNS")" = 1

: >"$RUNS"
BAD_STEP2=$(gui_client_hop_command_line "$LOCAL_MIRROR" \
  dp-offline-upgrade-xenial-to-bionic.sh "$(printf '%064d' 1)")
printf '%s\n' "$BAD_STEP2" | rewrite_command >"$TMP/bad-fpr.sh"
if env PATH="$STUB_BIN:/usr/bin:/bin" bash "$TMP/bad-fpr.sh" >/dev/null 2>&1; then
  fail "wrong launcher SHA unexpectedly succeeded"
else
  pass "wrong launcher SHA rejected"
fi
expect "wrong launcher SHA causes zero executions" test "$(wc -l <"$RUNS")" = 0

# Stale config identity blocks Menu 7 preflight.
printf '\nACPS_USERNAME=changed-fixture\n' >>"$MM_CONFIG_FILE"
if mm_wf_commands_preflight; then
  fail "stale CONFIG_SHA256 preflight unexpectedly passed"
else
  expect "stale CONFIG_SHA256 blocks Menu 7" \
    test "$MM_WF_BLOCK_REASON" = STALE_CONFIG_SHA256
fi

# Reinstall detection and preservation report use isolated config/runtime roots.
# shellcheck disable=SC1090
source "$RUNTIME/lib/bootstrap.sh"
export INSTALL_CONF_DIR="$MM_CONFIG_DIR"
export INSTALL_LIB_DIR="$RUNTIME"
expect "reinstall-style install mode detected" \
  test "$(um_bootstrap_detect_install_mode)" = REINSTALL
REPORT="$(um_bootstrap_report_install_outcome REINSTALL DISABLED DISABLED YES)"
expect "reinstall report preserves config" grep -q '^CONFIG_PRESERVED=YES$' <<<"$REPORT"
expect "reinstall report preserves signing key" \
  grep -q '^SIGNING_KEY_PRESERVED=YES$' <<<"$REPORT"

if [[ "$FAIL" -ne 0 ]]; then
  printf 'CLEAN_SNAPSHOT_FULL_WORKFLOW=FAIL\n'
  exit 1
fi
printf 'CLEAN_SNAPSHOT_FULL_WORKFLOW=PASS\n'
