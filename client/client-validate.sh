#!/usr/bin/env bash
# client-validate.sh — Client-side mirror connectivity & archive/security checks
set -euo pipefail

MIRROR_URL=""
MIRROR_IP=""
TIMEOUT=10
EXPECT_VERSIONS="xenial bionic focal jammy noble"

usage() {
  cat <<'EOF'
Usage: ./client-validate.sh --mirror-url http://MIRROR_IP
       ./client-validate.sh --mirror-ip 192.0.2.10

Tests ICMP, TCP/80, HTTP Release for archive + security pockets,
meta-release-lts + sample upgrader endpoints, and ensures apt sources
no longer reference archive/security/old-releases.ubuntu.com and
meta-release has no changelogs.ubuntu.com URIs.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mirror-url) MIRROR_URL="${2:-}"; shift 2 ;;
      --mirror-ip) MIRROR_IP="${2:-}"; shift 2 ;;
      --timeout) TIMEOUT="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)
        if [[ -z "$MIRROR_IP" ]] && [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          MIRROR_IP="$1"
          shift
        else
          die "Unknown option: $1"
        fi
        ;;
    esac
  done
  if [[ -z "$MIRROR_URL" ]] && [[ -n "$MIRROR_IP" ]]; then
    MIRROR_URL="http://${MIRROR_IP}"
  fi
  [[ -n "$MIRROR_URL" ]] || die "Provide --mirror-url or --mirror-ip"
  MIRROR_URL="${MIRROR_URL%/}"
  if [[ -z "$MIRROR_IP" ]]; then
    MIRROR_IP="${MIRROR_URL#http://}"
    MIRROR_IP="${MIRROR_IP#https://}"
    MIRROR_IP="${MIRROR_IP%%/*}"
    MIRROR_IP="${MIRROR_IP%%:*}"
  fi
}

PASS=0 WARN=0 FAIL=0
result() {
  local st="$1" name="$2" detail="${3:-}"
  case "$st" in
    PASS) ((PASS++)) || true; printf '[PASS]    %s%s\n' "$name" "${detail:+ — $detail}" ;;
    WARNING) ((WARN++)) || true; printf '[WARNING] %s%s\n' "$name" "${detail:+ — $detail}" ;;
    FAIL) ((FAIL++)) || true; printf '[FAIL]    %s%s\n' "$name" "${detail:+ — $detail}" ;;
  esac
}

http_code() {
  local url="$1"
  local code
  code="$(curl -sS -o /dev/null --max-time "$TIMEOUT" -w '%{http_code}' "$url" 2>/dev/null || true)"
  [[ -z "$code" ]] && code="000"
  printf '%s\n' "$code"
}

sources_external_canonical() {
  local f
  local pat='(archive|security|old-releases)\.ubuntu\.com'
  [[ -f /etc/apt/sources.list ]] && grep -Eq "$pat" /etc/apt/sources.list && return 0
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    [[ "$f" == *disabled-by-dp-os-upgrade* ]] && continue
    grep -Eq "$pat" "$f" && return 0
  done
  return 1
}

meta_release_external() {
  local meta="/etc/update-manager/meta-release"
  [[ -f "$meta" ]] || return 1
  grep -qiE 'URI(_LTS)?[[:space:]]*=[[:space:]]*https?://changelogs\.ubuntu\.com' "$meta"
}

main() {
  parse_args "$@"
  printf 'Testing mirror: %s\n' "$MIRROR_URL"
  printf 'Archive:  %s/ubuntu\n' "$MIRROR_URL"
  printf 'Security: %s/ubuntu-security\n\n' "$MIRROR_URL"

  if ping -c 3 -W 5 "$MIRROR_IP" >/dev/null 2>&1; then
    result PASS "ICMP Ping" "$MIRROR_IP"
  else
    result WARNING "ICMP Ping" "may be blocked by firewall"
  fi

  if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${MIRROR_IP}/80" 2>/dev/null; then
    result PASS "TCP Port 80" "reachable"
  else
    result FAIL "TCP Port 80" "not reachable"
  fi

  local code ver available=0 sec_ok=0
  code="$(http_code "${MIRROR_URL}/ubuntu/dists/noble/Release")"
  if [[ "$code" == "200" ]]; then
    result PASS "HTTP GET archive noble/Release" "200"
  else
    result FAIL "HTTP GET archive noble/Release" "HTTP $code"
  fi

  code="$(http_code "${MIRROR_URL}/ubuntu-security/dists/noble-security/InRelease")"
  if [[ "$code" != "200" ]]; then
    code="$(http_code "${MIRROR_URL}/ubuntu-security/dists/noble-security/Release")"
  fi
  if [[ "$code" == "200" ]]; then
    result PASS "HTTP GET security noble-security" "200"
  else
    result FAIL "HTTP GET security noble-security" "HTTP $code"
  fi

  for ver in $EXPECT_VERSIONS; do
    if [[ "$(http_code "${MIRROR_URL}/ubuntu/dists/${ver}/Release")" == "200" ]]; then
      result PASS "Archive version $ver" "available"
      ((available++)) || true
    else
      result FAIL "Archive version $ver" "NOT available"
    fi
    code="$(http_code "${MIRROR_URL}/ubuntu-security/dists/${ver}-security/InRelease")"
    if [[ "$code" != "200" ]]; then
      code="$(http_code "${MIRROR_URL}/ubuntu-security/dists/${ver}-security/Release")"
    fi
    if [[ "$code" == "200" ]]; then
      result PASS "Security pocket ${ver}-security" "available"
      ((sec_ok++)) || true
    else
      result FAIL "Security pocket ${ver}-security" "HTTP $code"
    fi
  done

  if sources_external_canonical; then
    result FAIL "apt sources" "external archive/security/old-releases.ubuntu.com still present"
  else
    result PASS "apt sources" "no external archive/security/old-releases URLs"
  fi

  code="$(http_code "${MIRROR_URL}/offline/meta-release-lts")"
  if [[ "$code" == "200" ]]; then
    result PASS "HTTP GET meta-release-lts" "200"
  else
    result FAIL "HTTP GET meta-release-lts" "HTTP $code"
  fi

  # Selective READY: profile_name=offline-upgrade-selective (or overall=READY legacy).
  local ready_body=""
  ready_body="$(curl -sS --max-time "$TIMEOUT" "${MIRROR_URL}/offline/READY" 2>/dev/null || true)"
  if [[ -n "$ready_body" ]] && printf '%s\n' "$ready_body" | grep -Eq 'profile_name=offline-upgrade-selective'; then
    result PASS "mirror READY profile" "offline-upgrade-selective"
  elif [[ -n "$ready_body" ]] && printf '%s\n' "$ready_body" | grep -q 'overall=READY'; then
    if printf '%s\n' "$ready_body" | grep -Eq 'profile_name=(offline-upgrade-selective|selective)'; then
      result PASS "mirror READY profile" "offline-upgrade-selective"
    else
      result FAIL "mirror READY profile" "unsupported profile (need offline-upgrade-selective)"
    fi
  elif [[ -n "$ready_body" ]] && printf '%s\n' "$ready_body" | grep -q 'READY'; then
    if printf '%s\n' "$ready_body" | grep -qi 'minimal\|offline-upgrade-full'; then
      result FAIL "mirror READY" "legacy full/minimal READY — migrate to selective"
    else
      result WARNING "mirror READY" "present but missing selective profile_name"
    fi
  else
    result FAIL "mirror READY" "missing — refuse upgrade until publish-selective"
  fi

  code="$(http_code "${MIRROR_URL}/keys/ubuntu-mirror-selective.gpg")"
  if [[ "$code" == "200" ]]; then
    result PASS "selective signing key" "200"
  else
    result WARNING "selective signing key" "HTTP $code"
  fi

  # Prefer hop-separated upgrader paths under shared offline; fall back to dists path.
  local hop
  for hop in bionic focal jammy noble; do
    code="$(http_code "${MIRROR_URL}/offline/release-upgraders/${hop}/${hop}.tar.gz")"
    if [[ "$code" != "200" ]]; then
      code="$(http_code "${MIRROR_URL}/ubuntu/dists/${hop}-updates/main/dist-upgrader-all/current/${hop}.tar.gz")"
    fi
    if [[ "$code" == "200" ]]; then
      result PASS "upgrader ${hop}.tar.gz" "200"
    else
      result FAIL "upgrader ${hop}.tar.gz" "HTTP $code"
    fi
    code="$(http_code "${MIRROR_URL}/offline/release-upgraders/${hop}/${hop}.tar.gz.gpg")"
    if [[ "$code" != "200" ]]; then
      code="$(http_code "${MIRROR_URL}/ubuntu/dists/${hop}-updates/main/dist-upgrader-all/current/${hop}.tar.gz.gpg")"
    fi
    if [[ "$code" == "200" ]]; then
      result PASS "upgrader ${hop}.tar.gz.gpg" "200"
    else
      result FAIL "upgrader ${hop}.tar.gz.gpg" "HTTP $code"
    fi
  done

  # Hop snapshot presence (selective layout)
  local shop
  for shop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
    code="$(http_code "${MIRROR_URL}/hops/${shop}/ubuntu/dists/")"
    if [[ "$code" == "200" ]] || [[ "$code" == "301" ]] || [[ "$code" == "403" ]]; then
      result PASS "hop snapshot $shop" "reachable"
    else
      result WARNING "hop snapshot $shop" "HTTP $code (ok if using /ubuntu convenience link)"
    fi
  done

  if [[ -f /etc/update-manager/meta-release ]]; then
    if meta_release_external; then
      result FAIL "meta-release config" "still points at changelogs.ubuntu.com"
    elif grep -q "${MIRROR_URL}/offline/meta-release-lts" /etc/update-manager/meta-release; then
      result PASS "meta-release config" "URI_LTS local"
    else
      result FAIL "meta-release config" "URI_LTS not pointing at local mirror"
    fi
  else
    result WARNING "meta-release config" "file missing — run client-setup.sh"
  fi

  if command -v apt-cache >/dev/null 2>&1; then
    if apt-cache policy 2>/dev/null | grep -q "$MIRROR_IP"; then
      result PASS "apt-cache policy" "mirror in use"
    else
      result WARNING "apt-cache policy" "mirror IP not seen — run client-setup.sh?"
    fi
    if apt-cache policy 2>/dev/null | grep -q 'ubuntu-security'; then
      result PASS "apt-cache security prefix" "ubuntu-security present"
    else
      result WARNING "apt-cache security prefix" "ubuntu-security not in policy"
    fi
  fi

  printf '\nSummary: PASS=%s WARNING=%s FAIL=%s (archive %s/5, security %s/5)\n' \
    "$PASS" "$WARN" "$FAIL" "$available" "$sec_ok"

  if [[ "$FAIL" -gt 0 ]]; then
    exit 2
  fi
  if [[ "$WARN" -gt 0 ]] || [[ "$available" -lt 5 ]] || [[ "$sec_ok" -lt 5 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
