#!/usr/bin/env bash
# dp-client-command-runner.sh — authenticated OS-hop client download + execute.
#
# Invoked by the Menu 7 hop launcher after:
#   - EXPECTED_KEYRING_SHA256 matches downloaded public-keyring.gpg bytes
#   - EXPECTED_FPR matches the sole primary key fingerprint
#   - detached runner-manifest signature verifies (gpgv)
#   - runner SHA256 matches the signed manifest / sidecar
#
# This helper never trusts HTTP alone. It independently re-checks the keyring
# SHA256 + fingerprint (exact trust, not "fingerprint exists somewhere"),
# downloads hop artifacts into the current workdir, verifies gpgv + bindings,
# and only then runs: sudo bash ./$SCRIPT --mirror-base $MIRROR
#
# Assumption: Mirror public-keyring.gpg contains exactly one primary signing
# key. Extra attacker keys change the SHA256 pin and/or pub: count.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

MIRROR_BASE=""
HOP=""
SCRIPT=""
EXPECTED_FPR=""
EXPECTED_KEYRING_SHA256=""

usage() {
  cat <<EOF
Usage: bash ${SCRIPT_NAME} --mirror-base URL --hop HOP --script FILE \\
          --expected-fingerprint FPR --expected-keyring-sha256 SHA256
   or: bash ${SCRIPT_NAME} MIRROR_BASE HOP SCRIPT EXPECTED_FPR EXPECTED_KEYRING_SHA256

Downloads and authenticates one OS-hop upgrade client, then executes it.
EOF
}

die() {
  printf '%s\n' "${SCRIPT_NAME}: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mirror-base)
      MIRROR_BASE="${2:-}"
      shift 2
      ;;
    --hop)
      HOP="${2:-}"
      shift 2
      ;;
    --script)
      SCRIPT="${2:-}"
      shift 2
      ;;
    --expected-fingerprint)
      EXPECTED_FPR="${2:-}"
      shift 2
      ;;
    --expected-keyring-sha256)
      EXPECTED_KEYRING_SHA256="${2:-}"
      shift 2
      ;;
    -m)
      MIRROR_BASE="${2:-}"
      shift 2
      ;;
    -p)
      HOP="${2:-}"
      shift 2
      ;;
    -s)
      SCRIPT="${2:-}"
      shift 2
      ;;
    -f)
      EXPECTED_FPR="${2:-}"
      shift 2
      ;;
    -k)
      EXPECTED_KEYRING_SHA256="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

# Positional form used by the hop launcher.
if [[ -z "$MIRROR_BASE" && $# -ge 1 ]]; then
  MIRROR_BASE="$1"
  shift
fi
if [[ -z "$HOP" && $# -ge 1 ]]; then
  HOP="$1"
  shift
fi
if [[ -z "$SCRIPT" && $# -ge 1 ]]; then
  SCRIPT="$1"
  shift
fi
if [[ -z "$EXPECTED_FPR" && $# -ge 1 ]]; then
  EXPECTED_FPR="$1"
  shift
fi
if [[ -z "$EXPECTED_KEYRING_SHA256" && $# -ge 1 ]]; then
  EXPECTED_KEYRING_SHA256="$1"
  shift
fi

[[ -n "$MIRROR_BASE" ]] || die "missing --mirror-base"
[[ -n "$HOP" ]] || die "missing --hop"
[[ -n "$SCRIPT" ]] || die "missing --script"
[[ -n "$EXPECTED_FPR" ]] || die "missing --expected-fingerprint"
[[ -n "$EXPECTED_KEYRING_SHA256" ]] || die "missing --expected-keyring-sha256"
EXPECTED_FPR="${EXPECTED_FPR^^}"
EXPECTED_FPR="${EXPECTED_FPR// /}"
[[ ${#EXPECTED_FPR} -eq 40 ]] || die "EXPECTED_FPR must be 40 hex chars"
EXPECTED_KEYRING_SHA256="$(printf '%s' "$EXPECTED_KEYRING_SHA256" | tr 'A-F' 'a-f' | tr -d '[:space:]')"
[[ ${#EXPECTED_KEYRING_SHA256} -eq 64 ]] || die "EXPECTED_KEYRING_SHA256 must be 64 hex chars"
[[ "$EXPECTED_KEYRING_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "EXPECTED_KEYRING_SHA256 must be hex"

MIRROR_BASE="${MIRROR_BASE%/}"

# Keyring must already be present from the bootstrap (or download fresh).
if [[ ! -s public-keyring.gpg ]]; then
  curl -fsSLo public-keyring.gpg "${MIRROR_BASE}/client/public-keyring.gpg" \
    || die "failed to download public-keyring.gpg"
fi
test -s public-keyring.gpg || die "public-keyring.gpg empty"

GOT_SHA="$(sha256sum ./public-keyring.gpg | awk '{print tolower($1)}')"
if [[ "$GOT_SHA" != "$EXPECTED_KEYRING_SHA256" ]]; then
  die "KEYRING_TRUST=FAIL reason=sha256_mismatch got=${GOT_SHA}"
fi

PUB_COUNT="$(gpg --batch --no-default-keyring --keyring ./public-keyring.gpg \
  --with-colons --list-keys 2>/dev/null \
  | awk -F: '/^pub:/{c++} END{print c+0}')"
if [[ "$PUB_COUNT" -ne 1 ]]; then
  die "KEYRING_TRUST=FAIL reason=unexpected_pub_count count=${PUB_COUNT}"
fi

GOT_FPR="$(gpg --batch --no-default-keyring --keyring ./public-keyring.gpg \
  --with-colons --fingerprint 2>/dev/null \
  | awk -F: '/^fpr:/{print toupper($10); exit}')"
[[ -n "$GOT_FPR" ]] || die "KEYRING_TRUST=FAIL reason=unreadable_fingerprint"
[[ "$GOT_FPR" == "$EXPECTED_FPR" ]] || die "KEYRING_TRUST=FAIL reason=fingerprint_mismatch got=${GOT_FPR}"

# Fail-closed downloads of hop artifacts.
curl -fsSLo client-set.env "${MIRROR_BASE}/client/client-set.env" \
  || die "download client-set.env failed"
curl -fsSLo "${SCRIPT}" "${MIRROR_BASE}/client/${SCRIPT}" \
  || die "download ${SCRIPT} failed"
curl -fsSLo "${SCRIPT}.sha256" "${MIRROR_BASE}/client/${SCRIPT}.sha256" \
  || die "download ${SCRIPT}.sha256 failed"
curl -fsSLo client-manifest.json \
  "${MIRROR_BASE}/client/${HOP}/client-manifest.json" \
  || die "download client-manifest.json failed"
curl -fsSLo client-manifest.json.asc \
  "${MIRROR_BASE}/client/${HOP}/client-manifest.json.asc" \
  || die "download client-manifest.json.asc failed"

test -s "${SCRIPT}" || die "${SCRIPT} empty"
test -s "${SCRIPT}.sha256" || die "${SCRIPT}.sha256 empty"
test -s client-manifest.json || die "client-manifest.json empty"
test -s client-manifest.json.asc || die "client-manifest.json.asc empty"

gpgv --keyring ./public-keyring.gpg client-manifest.json.asc client-manifest.json \
  || die "gpgv client-manifest failed"

MANIFEST_HOP="$(python3 -c 'import json;print(json.load(open("client-manifest.json")).get("hop",""))' 2>/dev/null || true)"
[[ "$MANIFEST_HOP" == "$HOP" ]] || die "manifest hop mismatch got=${MANIFEST_HOP}"

MANIFEST_SCRIPT="$(python3 -c 'import json;print(json.load(open("client-manifest.json")).get("script",""))' 2>/dev/null || true)"
[[ "$MANIFEST_SCRIPT" == "$SCRIPT" ]] || die "manifest script mismatch got=${MANIFEST_SCRIPT}"

CALC="$(sha256sum "${SCRIPT}" | awk '{print $1}')"
MANIFEST_SHA="$(python3 -c 'import json;print(json.load(open("client-manifest.json")).get("script_sha256",""))' 2>/dev/null || true)"
[[ -n "$MANIFEST_SHA" ]] || die "manifest script_sha256 missing"
[[ "$MANIFEST_SHA" == "$CALC" ]] || die "manifest SHA mismatch"

SIDE="$(awk '{print $1; exit}' "${SCRIPT}.sha256")"
[[ "$SIDE" == "$CALC" ]] || die "sidecar SHA mismatch"

# Final execution only after every check passes.
sudo bash "./${SCRIPT}" --mirror-base "${MIRROR_BASE}"
