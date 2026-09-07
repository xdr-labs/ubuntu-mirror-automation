#!/usr/bin/env bash
# Fail-closed contracts for workflow generations, commands, permissions, and trust.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }
expect() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 0755 "$TMP"

export MM_PROJECT_ROOT="$ROOT"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$MM_CONFIG_DIR/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$MM_CONFIG_DIR/status"
export MM_WORKFLOW_FILE="$MM_CONFIG_DIR/workflow.state"
export MM_LOG_DIR="$TMP/logs"
export MM_CLIENT_ROOT="$TMP/mirror/client"
export SKIP_MIRROR_HOST_VALIDATE=1
mkdir -p "$MM_CONFIG_DIR" "$MM_LOG_DIR" "$MM_CLIENT_ROOT/lib"
: >"$MM_STATUS_FILE"
python3 "$ROOT/scripts/lib/build_client_launchers.py" \
  --project-root "$ROOT" \
  --output-dir "$MM_CLIENT_ROOT" \
  --mirror-base-url "http://192.0.2.10" \
  --signing-fingerprint "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" >/dev/null
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/phase2_helper_generation.sh"
install -m 0755 "$ROOT/client/stage-dp-phase2.sh" "$MM_CLIENT_ROOT/stage-dp-phase2.sh"
install -m 0755 "$ROOT/client/bringup_py3_dp_lifecycle.sh" "$MM_CLIENT_ROOT/bringup_py3_dp_lifecycle.sh"
for hf in dp-offline-source-product-version.sh dp-phase2-operation-progress.sh \
  dp-phase2-bringup-lifecycle.sh dp-phase2-ubuntu-prerequisites.sh
do
  install -m 0755 "$ROOT/client/lib/${hf}" "$MM_CLIENT_ROOT/lib/${hf}"
done
phase2_helper_generation_write "$MM_CLIENT_ROOT" >/dev/null
# shellcheck source=lib/phase2_bundle_trust_fixture.sh
source "${ROOT}/tests/lib/phase2_bundle_trust_fixture.sh"
phase2_trust_fixture_export_dp_phase2_root "$TMP" >/dev/null
phase2_trust_fixture_write_bundle_sidecar "$MM_DP_PHASE2_ROOT" "6.6.0" >/dev/null
phase2_upgrade_wrapper_write "$MM_CLIENT_ROOT" "http://192.0.2.10" "6.6.0" >/dev/null

# Load production command generators without running the program entrypoint.
LIB="$TMP/installer-lib.sh"
awk -v sd="$ROOT/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$ROOT/scripts/install-dp-upgrade-mirror.sh" >"$LIB"
# shellcheck disable=SC1090
source "$LIB"
# shellcheck source=../scripts/lib/local_client_signing.sh
source "$ROOT/scripts/lib/local_client_signing.sh"
# shellcheck source=../scripts/lib/http_publication_permissions.sh
source "$ROOT/scripts/lib/http_publication_permissions.sh"

PREPARATION_MODE=FULL
PHASE2_TARGET_VERSION=6.6.0
TARGET_DP_VERSION=6.6.0
MIRROR_SERVER_IP=192.0.2.10
MIRROR_HTTP_URL=http://192.0.2.10
ACPS_USERNAME=fixture
ACPS_PASSWORD=fixture
mm_save_gui_config >/dev/null
mm_wf_mark_configured >/dev/null

# A. Menu 7 must be blocked before HTTP is enabled.
mm_status_set HTTP_DISTRIBUTION DISABLED
mm_status_set UPGRADE_READINESS FAIL
if mm_wf_commands_preflight; then
  fail "A Menu 7 passed while HTTP disabled"
else
  expect "A Menu 7 blocked when HTTP not enabled" \
    test "$MM_WF_BLOCK_REASON" = HTTP_NOT_ENABLED
fi

# Build a valid live FULL file to prove all invalid publishes preserve it.
FPR=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
mm_wf_set_many \
  WORKFLOW_STATE=READINESS_VERIFIED \
  "CONFIG_SHA256=$(mm_wf_config_sha256)" \
  PREPARATION_MODE=FULL \
  MIRROR_SERVER_IP=192.0.2.10 \
  MIRROR_HTTP_URL=http://192.0.2.10 \
  CLIENT_SET_GENERATION_ID=client-gen-1 \
  "CLIENT_SIGNING_FINGERPRINT=$FPR" \
  HTTP_PUBLICATION_GENERATION_ID=client-gen-1 \
  READINESS_VERIFIED_GENERATION_ID=client-gen-1
mm_status_set HTTP_DISTRIBUTION ENABLED
mm_status_set UPGRADE_READINESS PASS
VALID="$TMP/valid-full.txt"
gui_build_client_commands "$MIRROR_HTTP_URL" single "" >"$VALID"
LIVE="$MM_LOG_DIR/dp-client-upgrade-commands.txt"
cp "$VALID" "$LIVE"
chmod 0644 "$LIVE"
LIVE_SHA="$(sha256sum "$LIVE" | awk '{print $1}')"

# B. FULL with no hop assignments fails and cannot replace live.
ZERO_HOPS="$TMP/full-zero-hops.txt"
grep -vE '^cd /home/aella && curl -fsSLo upgrade-(xenial-to-bionic|bionic-to-focal|focal-to-jammy|jammy-to-noble)\.sh' \
  "$VALID" >"$ZERO_HOPS"
set +e
B_OUT="$(mm_wf_atomic_publish_command_file "$ZERO_HOPS" "$LIVE" FULL client-gen-1 2>&1)"
B_RC=$?
set -e
expect "B FULL with zero hops returns failure" test "$B_RC" -ne 0
expect "B emits COMMAND_FILE_BUILD=FAIL" grep -q 'COMMAND_FILE_BUILD=FAIL' <<<"$B_OUT"
expect "B preserves previous command file" test \
  "$(sha256sum "$LIVE" | awk '{print $1}')" = "$LIVE_SHA"

# C. PHASE2_ONLY legitimately contains zero OS hops.
PREPARATION_MODE=PHASE2_ONLY
P2="$TMP/phase2-only.txt"
gui_build_client_commands "$MIRROR_HTTP_URL" single "" >"$P2"
expect "C PHASE2_ONLY with zero hops validates" \
  mm_wf_validate_command_file_content "$P2" PHASE2_ONLY
P2_HOP_COUNT="$(grep -cE \
  '^cd /home/aella && curl -fsSLo upgrade-(xenial-to-bionic|bionic-to-focal|focal-to-jammy|jammy-to-noble)\.sh' \
  "$P2" || true)"
expect "C PHASE2_ONLY has zero OS hops" test "$P2_HOP_COUNT" = 0

# D. Empty content is invalid and must never reach the display path.
EMPTY="$TMP/empty.txt"
: >"$EMPTY"
set +e
D_OUT="$(mm_wf_validate_command_file_content "$EMPTY" PHASE2_ONLY 2>&1)"
D_RC=$?
set -e
expect "D empty command file validation fails" test "$D_RC" -ne 0
expect "D empty evidence emitted" grep -q 'COMMAND_FILE_EMPTY=YES' <<<"$D_OUT"
DISPLAY_CALLS=0
display_if_valid() {
  local file="$1" mode="$2"
  mm_wf_validate_command_file_content "$file" "$mode" >/dev/null 2>&1 || return 1
  DISPLAY_CALLS=$((DISPLAY_CALLS + 1))
}
display_if_valid "$EMPTY" PHASE2_ONLY >/dev/null 2>&1 || true
expect "D empty command file display forbidden" test "$DISPLAY_CALLS" = 0

# E. A republished client generation invalidates readiness generation matching.
PREPARATION_MODE=FULL
mm_wf_set_many \
  WORKFLOW_STATE=READINESS_VERIFIED \
  "CONFIG_SHA256=$(mm_wf_config_sha256)" \
  CLIENT_SET_GENERATION_ID=client-gen-2 \
  "CLIENT_SIGNING_FINGERPRINT=$FPR" \
  HTTP_PUBLICATION_GENERATION_ID=client-gen-2 \
  READINESS_VERIFIED_GENERATION_ID=client-gen-1
mm_status_set HTTP_DISTRIBUTION ENABLED
mm_status_set UPGRADE_READINESS PASS
if mm_wf_commands_preflight; then
  fail "E stale client generation passed readiness"
else
  expect "E stale client generation invalidates readiness" \
    test "$MM_WF_BLOCK_REASON" = READINESS_GENERATION_MISMATCH
fi

# F. A 0700 public root is rejected before publication. The normalizer repairs
# ordinary 0700 staging, but must still fail closed if forbidden key material is
# present; test both parts of that production contract.
BAD_PUBLIC="$(mktemp -d "$TMP/client.stage.XXXXXX")"
printf '#!/bin/bash\n:\n' >"$BAD_PUBLIC/client.sh"
chmod 0755 "$BAD_PUBLIC/client.sh"
if mm_verify_http_public_tree_permissions "$BAD_PUBLIC" client >/dev/null 2>&1; then
  fail "F 0700 public root passed prepublish verifier"
else
  pass "F 0700 public root fails prepublish verifier"
fi
printf 'secret fixture\n' >"$BAD_PUBLIC/private.gpg"
if mm_client_stage_prepare_public_permissions "$BAD_PUBLIC" "$TMP" >/dev/null 2>&1; then
  fail "F permission normalizer accepted forbidden 0700 public fixture"
else
  pass "F permission normalizer fails closed on forbidden public fixture"
fi

# G. Reproduce the ASCII-armored public.gpg-as-keyring failure.
GPG_HOME="$TMP/gnupg"
mkdir -p "$GPG_HOME"
chmod 0700 "$GPG_HOME"
cat >"$GPG_HOME/batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Negative Contract Fixture
Name-Email: negative@example.invalid
Expire-Date: 0
%no-protection
%commit
EOF
gpg --homedir "$GPG_HOME" --batch --gen-key "$GPG_HOME/batch" >/dev/null 2>&1
ASCII_KEY="$TMP/public.gpg"
gpg --homedir "$GPG_HOME" --batch --export --armor >"$ASCII_KEY"
SIGNED="$TMP/signed.txt"
SIG="$SIGNED.asc"
printf 'signed fixture\n' >"$SIGNED"
gpg --homedir "$GPG_HOME" --batch --yes --armor --detach-sign -o "$SIG" "$SIGNED"
if local_signing_verify_binary_keyring "$ASCII_KEY" >/dev/null 2>&1; then
  fail "G ASCII public.gpg accepted as binary gpgv keyring"
else
  pass "G ASCII public.gpg rejected as gpgv keyring"
fi
set +e
gpgv --keyring "$ASCII_KEY" "$SIG" "$SIGNED" >/dev/null 2>&1
GPGV_ASCII_RC=$?
set -e
expect "G direct gpgv ASCII-keyring reproduction fails" test "$GPGV_ASCII_RC" -ne 0

# H. A sidecar/manifest mismatch must prevent sudo execution.
HTTP_ROOT="$TMP/http"
HOP=xenial-to-bionic
SCRIPT="dp-offline-upgrade-$HOP.sh"
mkdir -p "$HTTP_ROOT/client/$HOP"
printf '#!/bin/bash\necho should-not-run\n' >"$HTTP_ROOT/client/$SCRIPT"
chmod 0755 "$HTTP_ROOT/client/$SCRIPT"
REAL_SHA="$(sha256sum "$HTTP_ROOT/client/$SCRIPT" | awk '{print $1}')"
printf '%064d  %s\n' 0 "$SCRIPT" >"$HTTP_ROOT/client/$SCRIPT.sha256"
BINARY_KEY="$HTTP_ROOT/client/public-keyring.gpg"
local_signing_build_binary_keyring "$ASCII_KEY" "$BINARY_KEY"
cp "$ASCII_KEY" "$HTTP_ROOT/client/public.gpg"
printf 'CLIENT_SET_GENERATION_ID=h-fixture\n' >"$HTTP_ROOT/client/client-set.env"
LOCAL_SIGNING_PRIVATE_KEY="$GPG_HOME/../unused"
# Export private for runner staging
gpg --homedir "$GPG_HOME" --batch --export-secret-keys --armor >"$TMP/neg-private.gpg"
LOCAL_SIGNING_PRIVATE_KEY="$TMP/neg-private.gpg"
LOCAL_SIGNING_PUBLIC_KEY="$ASCII_KEY"
LOCAL_KEY_FINGERPRINT="$(local_signing_fingerprint_of "$ASCII_KEY")"
local_signing_stage_command_runner "$HTTP_ROOT/client" \
  "$ROOT/client/dp-client-command-runner.sh"
python3 - "$HOP" "$SCRIPT" "$REAL_SHA" "$HTTP_ROOT/client/$HOP/client-manifest.json" <<'PY'
import json, sys
hop, script, digest, path = sys.argv[1:]
with open(path, "w", encoding="utf-8") as fh:
    json.dump({"hop": hop, "script": script, "script_sha256": digest}, fh)
    fh.write("\n")
PY
gpg --homedir "$GPG_HOME" --batch --yes --armor --detach-sign \
  -o "$HTTP_ROOT/client/$HOP/client-manifest.json.asc" \
  "$HTTP_ROOT/client/$HOP/client-manifest.json"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
H_FPR="$(local_signing_fingerprint_of "$ASCII_KEY")"
python3 "$ROOT/scripts/lib/build_client_launchers.py" \
  --project-root "$ROOT" \
  --output-dir "$HTTP_ROOT/client" \
  --mirror-base-url "http://127.0.0.1:$PORT" \
  --signing-fingerprint "$H_FPR" >/dev/null
H_LAUNCHER_SHA="$(sha256sum "$HTTP_ROOT/client/dp-launch-${HOP}.sh" | awk '{print $1}')"
python3 - "$HTTP_ROOT" "$PORT" >/dev/null 2>"$TMP/http.err" <<'PY' &
import http.server, os, sys
os.chdir(sys.argv[1])
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])),
                                http.server.SimpleHTTPRequestHandler).serve_forever()
PY
HTTP_PID=$!
trap 'kill "$HTTP_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
for _ in {1..30}; do
  curl -fsS "http://127.0.0.1:$PORT/client/client-set.env" >/dev/null 2>&1 && break
  sleep 0.1
done
H_CMD="$(gui_client_hop_command_line "http://127.0.0.1:$PORT" "$SCRIPT" "$H_LAUNCHER_SHA")"
DP_HOME="$TMP/home/aella"
STUB="$TMP/stub"
RUNS="$TMP/runs"
mkdir -p "$DP_HOME" "$STUB"
: >"$RUNS"
cat >"$STUB/sudo" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$RUNS"
exit 0
EOF
chmod 0755 "$STUB/sudo"
printf '%s\n' "$H_CMD" | sed \
  "s|cd /home/aella|cd '$DP_HOME'|g" \
  >"$TMP/h-command.sh"
set +e
env PATH="$STUB:/usr/bin:/bin" bash "$TMP/h-command.sh" >/dev/null 2>&1
H_RC=$?
set -e
expect "H sidecar/manifest mismatch fails command" test "$H_RC" -ne 0
expect "H mismatch causes zero executions" test "$(wc -l <"$RUNS")" = 0

if [[ "$FAIL" -ne 0 ]]; then
  printf 'WORKFLOW_NEGATIVE_CONTRACTS=FAIL\n'
  exit 1
fi
printf 'WORKFLOW_NEGATIVE_CONTRACTS=PASS\n'
