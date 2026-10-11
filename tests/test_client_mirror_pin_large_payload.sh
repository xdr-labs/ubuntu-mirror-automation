#!/usr/bin/env bash
# Hermetic: large, valid signed-client metadata and runtime command must remain
# accepted; wrong-host pins stay rejected. No publication or signing occurs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/client_mirror_gates.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CLIENT="$TMP/client.sh"
CMD_FILE="$TMP/operator-command.txt"
HOST_A='http://192.0.2.10'
HOST_B='http://192.0.2.20'
python3 - "$CLIENT" "$CMD_FILE" "$HOST_A" <<'PY'
import base64, json, sys
client, cmd_file, mirror = sys.argv[1:]
meta = ("Dist: bionic\nRelease-File: {}/ubuntu/dists/bionic/Release\n"
        "UpgradeTool: {}/offline/bionic.tar.gz\n".format(mirror, mirror)
        + ("# irrelevant meta-release status\n" * 15000))
manifest = json.dumps({"schema_version": 1, "mirror_base": mirror,
                       "padding": ["x" * 60] * 10000}, indent=2)
with open(client, "w") as fp:
    fp.write("#!/usr/bin/env bash\nPIN_MIRROR_BASE='{}'\n".format(mirror))
    fp.write("PIN_SAMPLE_DEB_URL='{}/client/a.deb'\n".format(mirror))
    fp.write("PIN_META_B64='{}'\n".format(base64.b64encode(meta.encode()).decode()))
    fp.write("PIN_MANIFEST_B64='{}'\n".format(base64.b64encode(manifest.encode()).decode()))
with open(cmd_file, "w") as fp:
    fp.write("curl -fsSL {}/client/a.sh && bash ./a.sh --mirror-base {}\n".format(mirror, mirror))
    fp.write("# irrelevant operator history lines\n" * 12000)
PY
client_assert_mirror_base_match "$CLIENT" "$HOST_A" || {
    echo "FAIL: valid large pinned client incorrectly rejected" >&2; exit 1;
}
echo 'PASS: large metadata manifest host pins remain accepted'
if client_assert_mirror_base_match "$CLIENT" "$HOST_B" >/dev/null 2>&1; then
    echo 'FAIL: wrong-host pin accepted' >&2
    exit 1
fi
echo 'PASS: wrong-host metadata fails closed'
client_assert_command_mirror_base "$CMD_FILE" "$HOST_A" || {
    echo 'FAIL: valid long operator command incorrectly rejected' >&2; exit 1;
}
echo 'PASS: long operator command stays accepted'
if client_assert_command_mirror_base "$CMD_FILE" "$HOST_B" >/dev/null 2>&1; then
    echo 'FAIL: wrong host operator command accepted' >&2
    exit 1
fi
echo 'PASS: wrong-host operator command fails closed'
