#!/usr/bin/env bash
# client-setup.sh — Configure an Ubuntu client to use the local offline mirror
# Rewrites archive/old-releases → MIRROR/ubuntu and security → MIRROR/ubuntu-security.
# Points Update Manager meta-release URI/URI_LTS at the local mirror (no changelogs.ubuntu.com).
# Supports classic sources.list and Ubuntu 24.04+ deb822 (.sources) formats.
# Does not require /etc/hosts or external DNS.
set -euo pipefail

MIRROR_URL=""
MIRROR_IP=""
DRY_RUN=0
FORCE=0
WRITE_HOSTS=0
RESTORE=0
# Hop-separated selective snapshot path (optional). Example: xenial-to-bionic
SELECTIVE_HOP="${CLIENT_SETUP_SELECTIVE_HOP:-}"
BACKUP_DIR="/var/backups/ubuntu-mirror-client"
# Test/override: treat this directory as /etc/apt (sources.list, sources.list.d)
APT_ROOT="${CLIENT_SETUP_APT_ROOT:-/etc/apt}"
# Test/override: treat this directory as /etc/update-manager
# When APT_ROOT is a fixture path and UPDATE_MANAGER_ROOT is unset, nest under APT_ROOT.
if [[ -n "${CLIENT_SETUP_UPDATE_MANAGER_ROOT:-}" ]]; then
  UPDATE_MANAGER_ROOT="${CLIENT_SETUP_UPDATE_MANAGER_ROOT}"
elif [[ "${APT_ROOT}" != "/etc/apt" ]]; then
  UPDATE_MANAGER_ROOT="${APT_ROOT}/update-manager"
else
  UPDATE_MANAGER_ROOT="/etc/update-manager"
fi

usage() {
  cat <<'EOF'
Usage: sudo ./client-setup.sh --mirror-url http://MIRROR_IP [--force] [--dry-run]
                              [--write-hosts] [--hop HOP]
       sudo ./client-setup.sh --restore

Detects Ubuntu release and rewrites apt sources to use the local selective mirror.
  - archive / old-releases → http://MIRROR/ubuntu  (or /hops/<hop>/ubuntu)
  - security → http://MIRROR/ubuntu-security (alias of same selective tree)
  - signed-by local selective GPG key (not trusted=yes)
  - Acquire::Languages none; disable Translation/DEP-11/CNF/Contents/Sources indexes
  - meta-release URI/URI_LTS → http://MIRROR/offline/meta-release(-lts)

Options:
  --mirror-url URL   e.g. http://192.0.2.10
  --mirror-ip IP     Alias for building http://IP
  --hop NAME         Use hop snapshot URL /hops/NAME/ubuntu (e.g. xenial-to-bionic)
  --force            Rewrite even when already pointing at a local mirror
  --dry-run          Show changes only
  --write-hosts      Optional: add archive/security/old-releases → mirror IP in /etc/hosts
  --restore          Restore apt sources and meta-release from the latest backup
  --non-interactive  Accepted for CLI compatibility (no prompts today)
  -h, --help

Does not modify ports.ubuntu.com, PPAs, or other third-party repositories.
EOF
}

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mirror-url) MIRROR_URL="${2:-}"; shift 2 ;;
      --mirror-ip) MIRROR_IP="${2:-}"; shift 2 ;;
      --hop) SELECTIVE_HOP="${2:-}"; shift 2 ;;
      --force) FORCE=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --write-hosts) WRITE_HOSTS=1; shift ;;
      --restore) RESTORE=1; shift ;;
      --non-interactive) shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  if [[ "$RESTORE" == "1" ]]; then
    return 0
  fi
  if [[ -z "$MIRROR_URL" ]] && [[ -n "$MIRROR_IP" ]]; then
    MIRROR_URL="http://${MIRROR_IP}"
  fi
  [[ -n "$MIRROR_URL" ]] || die "--mirror-url is required (or use --restore)"
  MIRROR_URL="${MIRROR_URL%/}"
  if [[ -z "$MIRROR_IP" ]]; then
    MIRROR_IP="${MIRROR_URL#http://}"
    MIRROR_IP="${MIRROR_IP#https://}"
    MIRROR_IP="${MIRROR_IP%%/*}"
    MIRROR_IP="${MIRROR_IP%%:*}"
  fi
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root"
}

detect_codename() {
  # shellcheck disable=SC1091
  . /etc/os-release
  printf '%s\n' "${VERSION_CODENAME:-}"
}

backup_path() {
  local path="$1"
  local dest
  mkdir -p "$BACKUP_DIR"
  dest="$BACKUP_DIR/$(basename "$path").$(date '+%Y%m%d').bak"
  if [[ -e "$dest" ]]; then
    dest="$BACKUP_DIR/$(basename "$path").$(date '+%Y%m%d-%H%M%S').bak"
  fi
  cp -a "$path" "$dest"
  log "Backup: $dest"
}

# Rewrite one classic apt .list / sources.list file
rewrite_list_file() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"

  # Rules:
  #  - security.ubuntu.com → MIRROR/ubuntu-security
  #  - archive.ubuntu.com / old-releases.ubuntu.com → MIRROR/ubuntu
  #  - already-managed MIRROR-like /ubuntu or /ubuntu-security → refresh host (IP change)
  #  - never touch ports.ubuntu.com, launchpad PPAs, or other third-party URIs
  local archive_path="/ubuntu"
  local security_path="/ubuntu-security"
  if [[ -n "$SELECTIVE_HOP" ]]; then
    archive_path="/hops/${SELECTIVE_HOP}/ubuntu"
    security_path="/hops/${SELECTIVE_HOP}/ubuntu"
  fi

  awk -v mirror="$MIRROR_URL" -v apath="$archive_path" -v spath="$security_path" '
    {
      line = $0
      if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) { print line; next }
      if (line !~ /^[[:space:]]*deb(-src)?[[:space:]]/) { print line; next }

      n = split(line, tok, /[[:space:]]+/)
      uri_i = 0
      for (i = 1; i <= n; i++) if (tok[i] ~ /^https?:\/\//) { uri_i = i; break }
      if (uri_i == 0) { print line; next }

      uri = tok[uri_i]
      rest = uri; sub(/^https?:\/\//, "", rest)
      host = rest; sub(/\/.*/, "", host)
      path = rest; sub(/^[^\/]*/, "", path)
      if (path == "") path = "/"

      if (host ~ /ports\.ubuntu\.com$/ || host ~ /launchpad\.net/ || host ~ /^ppa\./) {
        print line; next
      }

      newuri = ""
      if (host == "security.ubuntu.com" || path == "/ubuntu-security" || path ~ /^\/ubuntu-security\//) {
        newuri = mirror spath
      } else if (host ~ /(^|\.)(archive|old-releases)\.ubuntu\.com$/ || path == "/ubuntu" || path ~ /^\/ubuntu\// || path ~ /^\/hops\//) {
        # path /ubuntu-ports already excluded via ports host; also guard path
        if (path ~ /^\/ubuntu-ports/) { print line; next }
        # PPA paths look like /user/ppa/ubuntu — not "/ubuntu"
        if (host !~ /(^|\.)(archive|old-releases)\.ubuntu\.com$/ && path != "/ubuntu" && path !~ /^\/ubuntu\// && path !~ /^\/hops\//) {
          print line; next
        }
        if (host !~ /(^|\.)(archive|old-releases)\.ubuntu\.com$/ && path != "/ubuntu" && path !~ /^\/hops\//) {
          # Allow /ubuntu/dists only for completeness; suite form uses path=/ubuntu
          if (path !~ /^\/ubuntu\//) { print line; next }
        }
        newuri = mirror apath
      }

      if (newuri == "") { print line; next }
      tok[uri_i] = newuri
      out = tok[1]
      for (i = 2; i <= n; i++) out = out " " tok[i]
      print out
    }
  ' "$file" >"$tmp"

  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    log "Unchanged: $file"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN would update $file"
    diff -u "$file" "$tmp" || true
    rm -f "$tmp"
    return 0
  fi
  backup_path "$file"
  install -m 0644 "$tmp" "$file"
  rm -f "$tmp"
  log "Updated: $file"
}

# deb822: rewrite URIs: lines based on archive vs security (and Suites hint)
rewrite_sources_deb822() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"
  awk -v mirror="$MIRROR_URL" -v force="$FORCE" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    BEGIN { suite_hint=""; uri_is_security=0 }
    /^Suites:/ {
      suite_hint=$0
      print
      next
    }
    /^URIs:/ {
      line=$0
      rest=line
      sub(/^URIs:[ \t]*/, "", rest)
      rest=trim(rest)
      is_sec=0
      if (rest ~ /security\.ubuntu\.com/ || rest ~ /\/ubuntu-security/) is_sec=1
      if (!is_sec && suite_hint ~ /-security/) is_sec=1
      if (rest ~ /ports\.ubuntu\.com/) { print; next }
      if (rest ~ /archive\.ubuntu\.com/ || rest ~ /old-releases\.ubuntu\.com/ \
          || rest ~ /security\.ubuntu\.com/ \
          || rest ~ /\/ubuntu-security/ || rest ~ /\/ubuntu([[:space:]]|$)/ \
          || force == "1") {
        if (is_sec) print "URIs: " mirror "/ubuntu-security"
        else print "URIs: " mirror "/ubuntu"
        next
      }
      print
      next
    }
    /^$/ { suite_hint=""; print; next }
    { print }
  ' "$file" >"$tmp"

  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    log "Unchanged: $file"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN would update $file"
    diff -u "$file" "$tmp" || true
    rm -f "$tmp"
    return 0
  fi
  backup_path "$file"
  install -m 0644 "$tmp" "$file"
  rm -f "$tmp"
  log "Updated: $file"
}

is_ubuntu_sources_file() {
  local f="$1"
  grep -qiE 'archive\.ubuntu\.com|old-releases\.ubuntu\.com|security\.ubuntu\.com|/ubuntu-security|[[:space:]]/ubuntu[[:space:]]' "$f" 2>/dev/null
}

maybe_write_hosts() {
  [[ "$WRITE_HOSTS" == "1" ]] || return 0
  local hosts="/etc/hosts"
  local marker_begin="# BEGIN ubuntu-mirror-client"
  local marker_end="# END ubuntu-mirror-client"
  local block
  block="$(printf '%s\n%s archive.ubuntu.com\n%s security.ubuntu.com\n%s old-releases.ubuntu.com\n%s\n' \
    "$marker_begin" "$MIRROR_IP" "$MIRROR_IP" "$MIRROR_IP" "$marker_end")"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN would update $hosts with archive/security/old-releases → $MIRROR_IP"
    printf '%s\n' "$block"
    return 0
  fi

  backup_path "$hosts"
  local tmp
  tmp="$(mktemp)"
  if grep -q "$marker_begin" "$hosts" 2>/dev/null; then
    awk -v begin="$marker_begin" -v end="$marker_end" '
      $0 == begin { skip=1; next }
      $0 == end { skip=0; next }
      !skip { print }
    ' "$hosts" >"$tmp"
  else
    cp -a "$hosts" "$tmp"
  fi
  printf '\n%s\n' "$block" >>"$tmp"
  install -m 0644 "$tmp" "$hosts"
  rm -f "$tmp"
  log "Updated $hosts (optional Host compatibility)"
}

sources_have_external_security() {
  local f
  if [[ -f "${APT_ROOT}/sources.list" ]] && grep -q 'security\.ubuntu\.com' "${APT_ROOT}/sources.list"; then
    return 0
  fi
  for f in "${APT_ROOT}/sources.list.d"/*.list "${APT_ROOT}/sources.list.d"/*.sources; do
    [[ -f "$f" ]] || continue
    # Intentionally disabled upgrade leftovers are not active apt sources
    if [[ "$f" == *disabled-by-dp-os-upgrade* ]]; then
      continue
    fi
    if grep -q 'security\.ubuntu\.com' "$f"; then
      return 0
    fi
  done
  return 1
}

# Rewrite /etc/update-manager/meta-release URI / URI_LTS (Ubuntu 16.04–24.04).
# Preserves unrelated options (URI_UNSTABLE_POSTFIX, URI_PROPOSED_POSTFIX, …).
configure_meta_release() {
  local meta="${UPDATE_MANAGER_ROOT}/meta-release"
  local tmp uri uri_lts
  uri="${MIRROR_URL}/offline/meta-release"
  uri_lts="${MIRROR_URL}/offline/meta-release-lts"

  mkdir -p "$UPDATE_MANAGER_ROOT"
  if [[ ! -f "$meta" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "DRY-RUN would create $meta with local URI/URI_LTS"
      return 0
    fi
    cat >"$meta" <<EOF
# default location for the meta-release file

[METARELEASE]
URI = ${uri}
URI_LTS = ${uri_lts}
URI_UNSTABLE_POSTFIX = -development
URI_PROPOSED_POSTFIX = -proposed
EOF
    chmod 0644 "$meta"
    log "Created: $meta"
    return 0
  fi

  tmp="$(mktemp)"
  awk -v uri="$uri" -v uri_lts="$uri_lts" '
    BEGIN { in_sec=0; saw_uri=0; saw_lts=0 }
    /^\[METARELEASE\]/ { in_sec=1; print; next }
    /^\[/ {
      if (in_sec) {
        if (!saw_uri) print "URI = " uri
        if (!saw_lts) print "URI_LTS = " uri_lts
      }
      in_sec=0
      print
      next
    }
    in_sec && /^[[:space:]]*URI[[:space:]]*=/ {
      print "URI = " uri
      saw_uri=1
      next
    }
    in_sec && /^[[:space:]]*URI_LTS[[:space:]]*=/ {
      print "URI_LTS = " uri_lts
      saw_lts=1
      next
    }
    { print }
    END {
      if (in_sec) {
        if (!saw_uri) print "URI = " uri
        if (!saw_lts) print "URI_LTS = " uri_lts
      }
    }
  ' "$meta" >"$tmp"

  if cmp -s "$meta" "$tmp"; then
    rm -f "$tmp"
    log "Unchanged: $meta"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN would update $meta"
    diff -u "$meta" "$tmp" || true
    rm -f "$tmp"
    return 0
  fi
  backup_path "$meta"
  install -m 0644 "$tmp" "$meta"
  rm -f "$tmp"
  log "Updated: $meta (URI/URI_LTS → local offline mirror)"
}

meta_release_has_external() {
  local meta="${UPDATE_MANAGER_ROOT}/meta-release"
  [[ -f "$meta" ]] || return 1
  grep -qiE 'URI(_LTS)?[[:space:]]*=[[:space:]]*https?://(changelogs|archive|security|old-releases)\.ubuntu\.com' "$meta"
}

configure_selective_apt_prefs() {
  # Disable unnecessary index targets and trust local selective key.
  local conf_dir="${APT_ROOT}/apt.conf.d"
  local keyrings="${APT_ROOT}/keyrings"
  local conf="${conf_dir}/99ubuntu-selective-mirror"
  local archive_uri="${MIRROR_URL}/ubuntu"
  local security_uri="${MIRROR_URL}/ubuntu-security"
  if [[ -n "$SELECTIVE_HOP" ]]; then
    archive_uri="${MIRROR_URL}/hops/${SELECTIVE_HOP}/ubuntu"
    security_uri="${MIRROR_URL}/hops/${SELECTIVE_HOP}/ubuntu"
  fi

  mkdir -p "$conf_dir" "$keyrings"
  local body
  body="$(cat <<EOF
Acquire::Languages "none";
Acquire::IndexTargets::deb::Contents-deb::DefaultEnabled "false";
Acquire::IndexTargets::deb::Contents-deb-legacy::DefaultEnabled "false";
Acquire::IndexTargets::deb::Translations::DefaultEnabled "false";
Acquire::IndexTargets::deb::CNF::DefaultEnabled "false";
Acquire::IndexTargets::deb-src::DefaultEnabled "false";
# Local selective mirror only — do not fall back to archive.ubuntu.com
Acquire::AllowInsecureRepositories "false";
EOF
)"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN would write $conf (Languages=none, index targets disabled)"
    log "Archive URI for hop: $archive_uri"
    log "Security URI for hop: $security_uri"
    return 0
  fi
  backup_path "$conf" 2>/dev/null || true
  printf '%s\n' "$body" >"$conf"
  chmod 0644 "$conf"
  log "Wrote selective APT prefs: $conf"

  # Install public key if reachable from mirror
  local key_url="${MIRROR_URL}/keys/ubuntu-mirror-selective.gpg"
  local key_dest="${keyrings}/ubuntu-mirror-selective.gpg"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 10 "$key_url" -o "$key_dest" 2>/dev/null; then
      chmod 0644 "$key_dest"
      log "Installed selective signing key: $key_dest"
    else
      log "NOTE: could not fetch $key_url — add signed-by manually after publish"
    fi
  fi
}

preflight_meta_release_http() {
  # Live check only when targeting real /etc (not fixture APT_ROOT overrides alone)
  [[ "$UPDATE_MANAGER_ROOT" == "/etc/update-manager" ]] || return 0
  local code
  code="$(curl -sS -o /dev/null --max-time 10 -w '%{http_code}' \
    "${MIRROR_URL}/offline/meta-release-lts" 2>/dev/null || echo 000)"
  if [[ "$code" != "200" ]]; then
    die "local meta-release-lts not reachable (HTTP ${code}): ${MIRROR_URL}/offline/meta-release-lts"
  fi
  log "Preflight OK: meta-release-lts HTTP 200"
}

latest_backup_for() {
  local base="$1"
  local f
  f="$(ls -1t "${BACKUP_DIR}/${base}".*.bak 2>/dev/null | head -n1 || true)"
  [[ -n "$f" ]] || return 1
  printf '%s\n' "$f"
}

cmd_restore() {
  mkdir -p "$BACKUP_DIR"
  local src dest
  # Restore meta-release
  if src="$(latest_backup_for meta-release)"; then
    dest="${UPDATE_MANAGER_ROOT}/meta-release"
    if [[ "$DRY_RUN" == "1" ]]; then
      log "DRY-RUN would restore $dest from $src"
    else
      mkdir -p "$UPDATE_MANAGER_ROOT"
      install -m 0644 "$src" "$dest"
      log "Restored: $dest from $src"
    fi
  else
    log "No meta-release backup found under $BACKUP_DIR"
  fi
  # Restore sources.list if backed up
  if src="$(latest_backup_for sources.list)"; then
    dest="${APT_ROOT}/sources.list"
    if [[ "$DRY_RUN" == "1" ]]; then
      log "DRY-RUN would restore $dest from $src"
    else
      install -m 0644 "$src" "$dest"
      log "Restored: $dest from $src"
    fi
  fi
  log "Restore complete"
}

main() {
  parse_args "$@"

  local live_system=0
  if [[ "$APT_ROOT" == "/etc/apt" ]] || [[ "$UPDATE_MANAGER_ROOT" == "/etc/update-manager" ]]; then
    live_system=1
  fi
  if [[ "$DRY_RUN" != "1" ]] && [[ "$live_system" == "1" ]]; then
    require_root
  fi

  if [[ "$APT_ROOT" != "/etc/apt" ]]; then
    BACKUP_DIR="${APT_ROOT}/.backups"
    mkdir -p "$BACKUP_DIR" "${APT_ROOT}/sources.list.d"
  fi
  if [[ "$UPDATE_MANAGER_ROOT" != "/etc/update-manager" ]]; then
    mkdir -p "$UPDATE_MANAGER_ROOT"
    if [[ "$APT_ROOT" != "/etc/apt" ]]; then
      : # backups already under APT_ROOT
    else
      BACKUP_DIR="${UPDATE_MANAGER_ROOT}/.backups"
      mkdir -p "$BACKUP_DIR"
    fi
  fi

  if [[ "$RESTORE" == "1" ]]; then
    cmd_restore
    exit 0
  fi

  local codename
  if [[ -f /etc/os-release ]]; then
    codename="$(detect_codename)"
  else
    codename="unknown"
  fi
  log "Client codename: ${codename:-unknown}"
  log "Mirror URL: ${MIRROR_URL}"
  log "Archive prefix:  ${MIRROR_URL}/ubuntu"
  log "Security prefix: ${MIRROR_URL}/ubuntu-security"
  log "Meta-release:    ${MIRROR_URL}/offline/meta-release-lts"

  local f list_dir="${APT_ROOT}/sources.list.d"
  mkdir -p "$list_dir" 2>/dev/null || true

  for f in "${list_dir}"/*.sources; do
    [[ -f "$f" ]] || continue
    if is_ubuntu_sources_file "$f" || [[ "$FORCE" == "1" ]]; then
      if [[ "$FORCE" != "1" ]] && ! grep -qiE 'ubuntu\.com|/ubuntu' "$f"; then
        continue
      fi
      rewrite_sources_deb822 "$f"
    fi
  done

  if [[ -f "${APT_ROOT}/sources.list" ]]; then
    rewrite_list_file "${APT_ROOT}/sources.list"
  fi

  local list
  for list in "${list_dir}"/*.list; do
    [[ -f "$list" ]] || continue
    if [[ "$list" == *disabled-by-dp-os-upgrade* ]]; then
      log "Skipping disabled file: $list"
      continue
    fi
    if is_ubuntu_sources_file "$list" || [[ "$FORCE" == "1" ]]; then
      if [[ "$FORCE" != "1" ]] && ! grep -qiE 'ubuntu\.com|/ubuntu' "$list"; then
        continue
      fi
      rewrite_list_file "$list"
    fi
  done

  configure_meta_release
  configure_selective_apt_prefs
  maybe_write_hosts

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN complete"
    exit 0
  fi

  if sources_have_external_security; then
    die "external security.ubuntu.com still present in apt sources after rewrite"
  fi
  if meta_release_has_external; then
    die "external changelogs/archive URI still present in ${UPDATE_MANAGER_ROOT}/meta-release"
  fi

  # Skip live apt-get when testing against a fake APT_ROOT
  if [[ "$APT_ROOT" != "/etc/apt" ]]; then
    log "APT_ROOT=${APT_ROOT} — skipping apt-get update (fixture mode)"
    log "Verify sources under ${APT_ROOT}; meta-release under ${UPDATE_MANAGER_ROOT}"
    exit 0
  fi

  preflight_meta_release_http

  log "Running apt-get update"
  if ! apt-get update; then
    die "apt-get update failed"
  fi

  if ! apt-cache policy 2>/dev/null | grep -qE "${MIRROR_IP}|${MIRROR_URL#http://}"; then
    die "apt-cache policy does not show local mirror"
  fi
  if ! apt-cache policy 2>/dev/null | grep -q 'ubuntu-security'; then
    log "WARNING: ubuntu-security not visible in apt-cache policy (check security suite lines)"
  fi

  log "Verify with: ./client-validate.sh --mirror-url ${MIRROR_URL}"
}

main "$@"
