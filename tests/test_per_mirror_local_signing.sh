#!/usr/bin/env bash
# Per-mirror local signing + host-pinned client contract tests (RFC 5737 fixtures).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

# shellcheck source=lib/portable_ip_policy.sh
source "${ROOT}/tests/lib/portable_ip_policy.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/local_client_signing.sh"
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/client_mirror_gates.sh"

echo "=== test_per_mirror_local_signing ==="

HOST_A="http://192.0.2.10"
HOST_B="http://192.0.2.20"

# --- 1/5: first install key generation ---
DIR_A="${WORKDIR}/host-a/client-signing"
LOCAL_CLIENT_SIGNING_DIR="$DIR_A"
if local_signing_ensure_keypair; then
  [[ "$LOCAL_SIGNING_KEY_ACTION" == "GENERATED" ]] \
    && pass "Host A first install LOCAL_SIGNING_KEY_ACTION=GENERATED" \
    || fail "Host A expected GENERATED got ${LOCAL_SIGNING_KEY_ACTION}"
  FPR_A="$LOCAL_KEY_FINGERPRINT"
  PRIV_A="$LOCAL_SIGNING_PRIVATE_KEY"
  PUB_A="$LOCAL_SIGNING_PUBLIC_KEY"
else
  fail "Host A key generation failed"
  FPR_A=""; PRIV_A=""; PUB_A=""
fi

# --- 5: reinstall reuses key ---
if local_signing_ensure_keypair; then
  [[ "$LOCAL_SIGNING_KEY_ACTION" == "REUSED" ]] \
    && pass "Host A reinstall LOCAL_SIGNING_KEY_ACTION=REUSED" \
    || fail "Host A expected REUSED got ${LOCAL_SIGNING_KEY_ACTION}"
  [[ "$LOCAL_KEY_FINGERPRINT" == "$FPR_A" ]] \
    && pass "Host A fingerprint stable across reinstall" \
    || fail "Host A fingerprint changed on reuse"
else
  fail "Host A key reuse failed"
fi

# --- 2: Host B separate key ---
DIR_B="${WORKDIR}/host-b/client-signing"
LOCAL_CLIENT_SIGNING_DIR="$DIR_B"
if local_signing_ensure_keypair; then
  [[ "$LOCAL_SIGNING_KEY_ACTION" == "GENERATED" ]] \
    && pass "Host B first install LOCAL_SIGNING_KEY_ACTION=GENERATED" \
    || fail "Host B expected GENERATED"
  FPR_B="$LOCAL_KEY_FINGERPRINT"
  PRIV_B="$LOCAL_SIGNING_PRIVATE_KEY"
else
  fail "Host B key generation failed"
  FPR_B=""; PRIV_B=""
fi

# --- 3: A and B private keys differ ---
if [[ -n "$PRIV_A" && -n "$PRIV_B" ]] && ! cmp -s "$PRIV_A" "$PRIV_B"; then
  pass "Host A and Host B private keys differ"
else
  fail "Host A/B private keys unexpectedly identical or missing"
fi
[[ "$FPR_A" != "$FPR_B" ]] \
  && pass "Host A and Host B fingerprints differ" \
  || fail "Host A/B fingerprints identical"

# --- 6: incomplete key pair fails ---
DIR_BAD="${WORKDIR}/bad-signing"
mkdir -p "$DIR_BAD"
chmod 0700 "$DIR_BAD"
# public only
cp "$PUB_A" "${DIR_BAD}/public.gpg"
LOCAL_CLIENT_SIGNING_DIR="$DIR_BAD"
if local_signing_ensure_keypair 2>/dev/null; then
  fail "incomplete key pair should FAIL"
else
  [[ "$LOCAL_SIGNING_KEY_ACTION" == "FAIL" ]] \
    && pass "incomplete key pair LOCAL_SIGNING_KEY_ACTION=FAIL" \
    || fail "incomplete pair action=${LOCAL_SIGNING_KEY_ACTION}"
fi

# --- 4: host-pinned gate (synthetic clients) ---
make_pinned_client() {
  local out="$1" base="$2"
  local meta="${WORKDIR}/meta-${base##*.}"
  cat >"$meta" <<EOF
Dist: bionic
Release-File: ${base}/hops/xenial-to-bionic/ubuntu/dists/bionic/Release
UpgradeTool: ${base}/offline/release-upgraders/bionic/bionic.tar.gz
UpgradeToolSignature: ${base}/offline/release-upgraders/bionic/bionic.tar.gz.gpg
EOF
  local meta_b64 manifest_b64
  meta_b64="$(base64 -w0 "$meta")"
  printf '{"schema_version":1,"mirror_base":"%s","sample_deb_url":"%s/hops/x/sample.deb"}\n' \
    "$base" "$base" >"${WORKDIR}/manifest.json"
  manifest_b64="$(base64 -w0 "${WORKDIR}/manifest.json")"
  cat >"$out" <<EOF
#!/usr/bin/env bash
PIN_MIRROR_BASE='${base}'
PIN_SAMPLE_DEB_URL='${base}/hops/xenial-to-bionic/ubuntu/pool/main/h/hello/hello.deb'
PIN_META_B64='${meta_b64}'
PIN_MANIFEST_B64='${manifest_b64}'
EOF
}

CLIENT_A="${WORKDIR}/client-a.sh"
CLIENT_B="${WORKDIR}/client-b.sh"
make_pinned_client "$CLIENT_A" "$HOST_A"
make_pinned_client "$CLIENT_B" "$HOST_B"

client_assert_mirror_base_match "$CLIENT_A" "$HOST_A" >/dev/null \
  && pass "Host A client pin gate PASS" || fail "Host A pin gate"
client_assert_mirror_base_match "$CLIENT_B" "$HOST_B" >/dev/null \
  && pass "Host B client pin gate PASS" || fail "Host B pin gate"
if client_assert_mirror_base_match "$CLIENT_A" "$HOST_B" >/dev/null 2>&1; then
  fail "Host A client should not match Host B URL"
else
  pass "cross-host pin mismatch rejected"
fi

sha_a="$(sha256sum "$CLIENT_A" | awk '{print $1}')"
sha_b="$(sha256sum "$CLIENT_B" | awk '{print $1}')"
[[ "$sha_a" != "$sha_b" ]] \
  && pass "Host A and Host B generated client SHA differ (expected)" \
  || fail "Host A/B client SHA unexpectedly identical"

# Empty pin (legacy host-independent) rejected
EMPTY="${WORKDIR}/empty.sh"
cat >"$EMPTY" <<'EOF'
#!/usr/bin/env bash
PIN_MIRROR_BASE=''
PIN_SAMPLE_DEB_PATH='/hops/x/sample.deb'
EOF
if client_assert_generic_artifact "$EMPTY" >/dev/null 2>&1; then
  fail "empty PIN_MIRROR_BASE should be rejected"
else
  pass "empty PIN_MIRROR_BASE rejected (no host-independent clients)"
fi

# --- 12: private key must not be HTTP-published ---
HTTP="${WORKDIR}/http-client"
mkdir -p "$HTTP"
cp "$PUB_A" "${HTTP}/public.gpg"
LOCAL_CLIENT_SIGNING_DIR="$DIR_A"
local_signing_paths
if local_signing_assert_private_not_published "$HTTP"; then
  pass "PRIVATE_KEY_HTTP_PUBLISHED=NO"
else
  fail "false positive private key publish detection"
fi
cp "$PRIV_A" "${HTTP}/private.gpg"
if local_signing_assert_private_not_published "$HTTP" 2>/dev/null; then
  fail "private key in HTTP root should be blocked"
else
  pass "private key HTTP publish blocked"
fi
rm -f "${HTTP}/private.gpg"

# --- GUI command uses local mirror URL (WRAPPER_V1) ---
# Menu 7 pins the published upgrade-<hop>.sh SHA256. The launcher download
# lives inside that wrapper, not in the operator one-liner.
eval "$(awk '
  /^gui_client_wrapper_sha256\(\)/ { in_fn=1 }
  /^gui_client_hop_command_line\(\)/ { in_fn=1 }
  /^gui_client_hop_command_block\(\)/ { in_fn=1 }
  /^gui_client_hop_command\(\)/ { in_fn=1 }
  in_fn { print }
  in_fn && /^}/ { in_fn=0; if (++done >= 4) exit }
' "${ROOT}/scripts/install-dp-upgrade-mirror.sh")"
set +e
cmd_missing="$(gui_client_hop_command_line "$HOST_A" "dp-offline-upgrade-xenial-to-bionic.sh" 2>"${WORKDIR}/menu7.missing.err")"
cmd_missing_rc=$?
set -e
[[ "$cmd_missing_rc" -ne 0 ]] \
  && grep -q 'MENU7_WRAPPER_MISSING=upgrade-xenial-to-bionic.sh' "${WORKDIR}/menu7.missing.err" \
  && pass "missing wrapper prevents Menu 7 hop command" \
  || fail "Menu 7 hop command should fail closed without published wrapper"
export MM_CLIENT_ROOT="${WORKDIR}/published-client"
mkdir -p "$MM_CLIENT_ROOT"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' '# fixture OS-hop wrapper' \
  >"${MM_CLIENT_ROOT}/upgrade-xenial-to-bionic.sh"
if declare -F gui_client_hop_command_line >/dev/null 2>&1; then
  cmd_a="$(gui_client_hop_command_line "$HOST_A" "dp-offline-upgrade-xenial-to-bionic.sh")"
elif declare -F gui_client_hop_command_block >/dev/null 2>&1; then
  cmd_a="$(gui_client_hop_command_block "$HOST_A" "dp-offline-upgrade-xenial-to-bionic.sh")"
else
  cmd_a="$(gui_client_hop_command "$HOST_A" "dp-offline-upgrade-xenial-to-bionic.sh")"
fi
[[ "$cmd_a" == *"MIRROR='${HOST_A}'"* || "$cmd_a" == *"$HOST_A/client/"* ]] \
  && pass "GUI hop command downloads from Host A" \
  || fail "GUI hop command missing Host A URL"
[[ "$cmd_a" == *"upgrade-xenial-to-bionic.sh"* ]] \
  && pass "GUI hop command downloads OS-hop wrapper" \
  || fail "GUI hop command missing wrapper download"
[[ "$cmd_a" != *"dp-launch-xenial-to-bionic.sh"* ]] \
  && pass "GUI hop command does not embed launcher download" \
  || fail "GUI hop command still embeds launcher download"
[[ "$cmd_a" == *"sha256sum -c -"* ]] \
  && pass "GUI hop command pins launcher SHA256" \
  || fail "GUI hop command missing SHA pin"
[[ "$cmd_a" != *"EXPECTED_FPR="* && "$cmd_a" != *"EXPECTED_FINGERPRINT"* ]] \
  && pass "GUI hop command does not expose fingerprint pin" \
  || fail "GUI hop command still exposes fingerprint pin"
[[ "$cmd_a" != *"gpgv"* ]] \
  && pass "GUI hop command does not expose gpgv" \
  || fail "GUI hop command still exposes gpgv"
[[ "$cmd_a" != *"--keyring ./public.gpg"* ]] \
  && pass "GUI hop command does not use armored public.gpg as keyring" \
  || fail "GUI hop command still uses public.gpg as gpgv keyring"

# --- portable IP policy on core builder/signing/gate sources ---
CORE_POLICY_FILES=(
  "${ROOT}/scripts/lib/mirror_host_ip.sh"
  "${ROOT}/scripts/lib/local_client_signing.sh"
  "${ROOT}/scripts/rebuild-publish-clients.sh"
  "${ROOT}/scripts/lib/client_mirror_gates.sh"
)
shopt -s nullglob
CORE_POLICY_FILES+=("${ROOT}/scripts/lib/build_client_"*.py)
CORE_POLICY_FILES+=("${ROOT}/client/"*.in)
CORE_POLICY_FILES+=("${ROOT}/client/"*.inc)
CORE_POLICY_FILES+=("${ROOT}/lib/"*.sh)
shopt -u nullglob
if portable_ip_policy_assert_files "signing-core" "${CORE_POLICY_FILES[@]}"; then
  pass "SOURCE_REAL_SERVER_IP_HARDCODE_COUNT=0 (core paths; portable IP policy)"
else
  fail "non-portable IP literals in core builder/signing sources"
fi

# --- private key not git-tracked pattern ---
if git -C "$ROOT" check-ignore -q /etc/ubuntu-mirror/client-signing/private.gpg 2>/dev/null \
  || grep -q 'private' "${ROOT}/.gitignore"; then
  pass "PRIVATE_KEY_GIT_TRACKED=NO (.gitignore covers private keys)"
else
  fail "gitignore missing private key exclusion"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_per_mirror_local_signing PASS ==="
  exit 0
fi
echo "=== test_per_mirror_local_signing FAIL ==="
exit 1
