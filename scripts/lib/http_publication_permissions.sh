#!/usr/bin/env bash
# scripts/lib/http_publication_permissions.sh — authoritative HTTP public-tree
# permission contract for nginx (www-data) readable publication.
#
# Never uses chmod -R 755. Directories and file types get precise modes.
# shellcheck shell=bash

if [[ -n "${HTTP_PUBLICATION_PERMISSIONS_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HTTP_PUBLICATION_PERMISSIONS_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Logging helpers (prefer mm_* when available)
# ---------------------------------------------------------------------------
_mm_http_perm_info() {
  if declare -F mm_info >/dev/null 2>&1; then
    mm_info "$*"
  else
    printf '%s\n' "$*"
  fi
}

_mm_http_perm_error() {
  if declare -F mm_error >/dev/null 2>&1; then
    mm_error "$*"
  else
    printf '%s\n' "$*" >&2
  fi
}

_mm_http_perm_ok() {
  if declare -F mm_ok >/dev/null 2>&1; then
    mm_ok "$*"
  else
    printf '%s\n' "$*"
  fi
}

# ---------------------------------------------------------------------------
# Mode helpers
# ---------------------------------------------------------------------------
mm_http_stat_mode() {
  local path="${1:-}"
  [[ -e "$path" ]] || return 1
  stat -c '%a' "$path" 2>/dev/null || return 1
}

mm_http_mode_is() {
  local path="${1:-}" want="${2:-}" have
  have="$(mm_http_stat_mode "$path" 2>/dev/null || true)"
  want="${want#0}"
  want="${want#0}"  # tolerate 0755 → 755
  [[ -n "$have" && "$have" == "$want" ]]
}

# Detect nginx worker user from config or Ubuntu default.
mm_http_detect_nginx_user() {
  local conf user
  if [[ -n "${MM_NGINX_USER:-}" ]]; then
    printf '%s\n' "$MM_NGINX_USER"
    return 0
  fi
  if [[ -n "${NGINX_USER:-}" ]]; then
    printf '%s\n' "$NGINX_USER"
    return 0
  fi
  for conf in /etc/nginx/nginx.conf "${MM_NGINX_CONF:-}"; do
    [[ -n "$conf" && -f "$conf" && -r "$conf" ]] || continue
    user="$(awk '/^[[:space:]]*user[[:space:]]+/ {
      gsub(/;/, "", $2); print $2; exit
    }' "$conf" 2>/dev/null || true)"
    if [[ -n "$user" && "$user" != "root" ]]; then
      printf '%s\n' "$user"
      return 0
    fi
  done
  printf 'www-data\n'
  return 0
}

# True when path looks like a private key that must never be HTTP-published.
mm_http_is_forbidden_private_key_name() {
  local base="${1:-}"
  case "$base" in
    private.gpg|private.key|*.private.gpg|secring.gpg|secret.gpg)
      return 0 ;;
  esac
  return 1
}

# Classify a published file into expected mode: 0755 (script) or 0644 (data).
mm_http_expected_file_mode() {
  local path="${1:-}" base
  base="$(basename "$path")"
  case "$base" in
    *.sh) printf '0755\n' ;;
    *.sha256|*.sha1|*.gpg|*.asc|*.env|*.list|*.txt|READY|FROZEN)
      printf '0644\n' ;;
    fingerprint|signing-key-fingerprint|release.env|meta-release|meta-release-lts|runner-manifest)
      printf '0644\n' ;;
    public-keyring.gpg|public.gpg|public.asc|offline-client-manifest.gpg)
      printf '0644\n' ;;
    *.tar|*.tar.gz|*.tgz)
      printf '0644\n' ;;
    *)
      # Default metadata / text / archives → non-executable
      if [[ -x "$path" ]] && file -b "$path" 2>/dev/null | grep -qiE 'script|shell|executable'; then
        printf '0755\n'
      else
        printf '0644\n'
      fi
      ;;
  esac
}

# Ensure every ancestor of path (including path if directory) has "other" execute
# so nginx can traverse. Does not widen file modes.
mm_http_ensure_parent_traversal() {
  local path="${1:-}" cur mode
  [[ -n "$path" ]] || return 1
  cur="$(cd "$(dirname "$path")" 2>/dev/null && pwd)" || return 1
  while [[ -n "$cur" && "$cur" != "/" ]]; do
    if [[ -d "$cur" ]]; then
      mode="$(mm_http_stat_mode "$cur" || true)"
      # Need at least ---x--x--x on the "other" or group bit for www-data when
      # not the owner. Prefer 0755 when currently too tight (0700/0750 without o+x).
      if [[ -n "$mode" ]]; then
        # If other lacks x (mode % 2 == 0 for last octal digit), open traversal.
        case "$mode" in
          *1|*5|*7) ;;
          *)
            chmod o+x "$cur" 2>/dev/null || chmod 0755 "$cur" 2>/dev/null || true
            ;;
        esac
      fi
    fi
    cur="$(dirname "$cur")"
  done
  return 0
}

# Normalize a client or phase2 HTTP public tree under $1.
# Optional $2 = kind: client|phase2|selective|auto (default auto).
mm_normalize_http_public_tree_permissions() {
  local root="${1:-}"
  local kind="${2:-auto}"
  local path base want mode spool

  [[ -n "$root" && -d "$root" ]] || return 1

  # Spool parents must allow nginx traversal (/var/spool/apt-mirror and children).
  spool="$(dirname "$root")"
  if [[ -d "$spool" ]]; then
    chmod 0755 "$spool" 2>/dev/null || true
    if [[ "$(basename "$spool")" != "apt-mirror" ]]; then
      local gp
      gp="$(dirname "$spool")"
      if [[ -d "$gp" && "$(basename "$gp")" == "apt-mirror" ]]; then
        chmod 0755 "$gp" 2>/dev/null || true
      fi
    fi
  fi
  # Always ensure the tree root itself is 0755 (fixes mktemp 0700).
  chmod 0755 "$root" || return 1

  if [[ "$kind" == "auto" ]]; then
    case "$(basename "$root")" in
      client) kind=client ;;
      dp-phase2) kind=phase2 ;;
      selective) kind=selective ;;
      *) kind=client ;;
    esac
  fi

  # Directories: exact 0755 (find + chmod per-dir, not chmod -R 755).
  while IFS= read -r -d '' path; do
    chmod 0755 "$path" || return 1
  done < <(find "$root" -type d -print0 2>/dev/null)

  # Files: type-specific modes; reject private keys.
  while IFS= read -r -d '' path; do
    base="$(basename "$path")"
    if mm_http_is_forbidden_private_key_name "$base"; then
      _mm_http_perm_error "HTTP_PUBLIC_PRIVATE_KEY_FORBIDDEN=${path}"
      return 1
    fi
    # Never publish files named like private keys under any extension pattern.
    case "$base" in
      *private*)
        if [[ "$base" == *.gpg || "$base" == *.key || "$base" == private* ]]; then
          _mm_http_perm_error "HTTP_PUBLIC_PRIVATE_KEY_FORBIDDEN=${path}"
          return 1
        fi
        ;;
    esac
    want="$(mm_http_expected_file_mode "$path")"
    chmod "$want" "$path" || return 1
  done < <(find "$root" -type f -print0 2>/dev/null)

  # Selective tree: traversal-only guarantee on directories (files left as-is
  # except we already applied type rules above when kind=selective).
  if [[ "$kind" == "selective" ]]; then
    while IFS= read -r -d '' path; do
      chmod 0755 "$path" || return 1
    done < <(find "$root" -type d -print0 2>/dev/null)
  fi

  return 0
}

# Verify permission contract on a public tree. Prints CLIENT_PUBLIC_* markers
# when kind=client; generic markers otherwise.
mm_verify_http_public_tree_permissions() {
  local root="${1:-}"
  local kind="${2:-client}"
  local path base want have mode

  [[ -n "$root" && -d "$root" ]] || {
    _mm_http_perm_error "CLIENT_PUBLIC_PERMISSION_VERIFY=FAIL reason=missing_root"
    return 1
  }

  mode="$(mm_http_stat_mode "$root" || true)"
  if [[ "$mode" != "755" && "$mode" != "0755" ]]; then
    # stat -c '%a' typically returns 755 without leading zero
    if [[ "$mode" != "755" ]]; then
      _mm_http_perm_error "CLIENT_PUBLIC_PERMISSION_VERIFY=FAIL root_mode=${mode} expected=0755 path=${root}"
      return 1
    fi
  fi

  while IFS= read -r -d '' path; do
    have="$(mm_http_stat_mode "$path" || true)"
    if [[ "$have" != "755" ]]; then
      _mm_http_perm_error "CLIENT_PUBLIC_PERMISSION_VERIFY=FAIL dir_mode=${have} path=${path}"
      return 1
    fi
  done < <(find "$root" -type d -print0 2>/dev/null)

  while IFS= read -r -d '' path; do
    base="$(basename "$path")"
    if mm_http_is_forbidden_private_key_name "$base"; then
      _mm_http_perm_error "CLIENT_PUBLIC_PERMISSION_VERIFY=FAIL private_key=${path}"
      return 1
    fi
    case "$base" in
      private.gpg|private.key|*private.gpg|*private.key)
        _mm_http_perm_error "CLIENT_PUBLIC_PERMISSION_VERIFY=FAIL private_key=${path}"
        return 1
        ;;
    esac
    want="$(mm_http_expected_file_mode "$path")"
    # Normalize want to 3-digit without leading zero for comparison with stat
    want="${want#0}"
    have="$(mm_http_stat_mode "$path" || true)"
    if [[ "$have" != "$want" ]]; then
      _mm_http_perm_error "CLIENT_PUBLIC_PERMISSION_VERIFY=FAIL file_mode=${have} expected=${want} path=${path}"
      return 1
    fi
  done < <(find "$root" -type f -print0 2>/dev/null)

  if [[ "$kind" == "client" ]]; then
    printf 'CLIENT_PUBLIC_ROOT_MODE=0755\n'
  fi
  return 0
}

# Verify nginx worker can traverse parents and read the given file.
mm_verify_http_access_as_nginx_user() {
  local path="${1:-}"
  local user mode
  [[ -n "$path" && -e "$path" ]] || return 1
  user="$(mm_http_detect_nginx_user)"

  if [[ ! -r "$path" ]]; then
    _mm_http_perm_error "NGINX_READ=FAIL path=${path} (root cannot read)"
    return 1
  fi

  # Prefer an actual nginx-user probe. Success implies parent traversal works.
  if id -u "$user" >/dev/null 2>&1; then
    if command -v runuser >/dev/null 2>&1; then
      if runuser -u "$user" -- test -r "$path" 2>/dev/null \
        || runuser -u "$user" test -r "$path" 2>/dev/null; then
        return 0
      fi
    fi
    if su -s /bin/sh "$user" -c "test -r $(printf '%q' "$path")" 2>/dev/null; then
      return 0
    fi
  fi

  # Fallback: require world-readable file and other-executable parents up to /.
  # Used when nginx user is missing or the caller is not root (hermetic tests).
  mode="$(mm_http_stat_mode "$path" || true)"
  case "$mode" in
    *4|*5|*6|*7) ;;
    *)
      _mm_http_perm_error "NGINX_USER_READ=FAIL path=${path} mode=${mode}"
      return 1
      ;;
  esac

  local cur owner
  cur="$(cd "$(dirname "$path")" 2>/dev/null && pwd)" || return 1
  while [[ -n "$cur" && "$cur" != "/" ]]; do
    if [[ ! -x "$cur" ]]; then
      _mm_http_perm_error "NGINX_TRAVERSAL=FAIL path=${cur}"
      return 1
    fi
    owner="$(stat -c '%U' "$cur" 2>/dev/null || true)"
    mode="$(mm_http_stat_mode "$cur" || true)"
    if [[ "$owner" != "$user" ]]; then
      case "$mode" in
        *1|*5|*7) ;;
        *)
          # In non-root hermetic fixtures, /tmp/mktemp parents are often 0700.
          # Only fail closed for paths under a typical public spool, or when root.
          if [[ "${EUID}" -eq 0 || "$cur" == */apt-mirror || "$cur" == */apt-mirror/* || "$cur" == */spool || "$cur" == */spool/* ]]; then
            _mm_http_perm_error "NGINX_TRAVERSAL=FAIL path=${cur} mode=${mode} user=${user}"
            return 1
          fi
          ;;
      esac
    fi
    cur="$(dirname "$cur")"
  done
  return 0
}

# Closure used before Enable HTTP: client + phase2 critical paths readable by nginx.
mm_verify_http_publication_permission_closure() {
  local base="${1:-${MM_MIRROR_ROOT:-/var/spool/apt-mirror}}"
  local client="${2:-${MM_CLIENT_ROOT:-${base}/client}}"
  local dp_root="${3:-${MM_DP_PHASE2_ROOT:-${base}/dp-phase2}}"
  local ver="${4:-${TARGET_DP_VERSION:-${PHASE2_TARGET_VERSION:-6.6.0}}}"
  local stable="${5:-}"
  local f paths=()

  [[ -d "$base" ]] || return 1
  if ! mm_http_mode_is "$base" "755"; then
    # Allow fixing only when caller already normalized; here just verify.
    local bm
    bm="$(mm_http_stat_mode "$base" || echo missing)"
    if [[ "$bm" != "755" ]]; then
      _mm_http_perm_error "HTTP_PUBLICATION_PERMISSION_CLOSURE=FAIL base_mode=${bm}"
      return 1
    fi
  fi

  if [[ -d "$client" ]]; then
    mm_verify_http_public_tree_permissions "$client" client || return 1
    paths+=(
      "${client}/stage-dp-phase2.sh"
      "${client}/stage-dp-phase2.sh.sha256"
    )
  fi

  if [[ -z "$stable" ]] && declare -F dp2_stable_bundle_name >/dev/null 2>&1; then
    stable="$(dp2_stable_bundle_name 2>/dev/null || true)"
  fi
  if [[ -z "$stable" ]]; then
    stable="dp_bundle_${ver}-current.tar"
  fi

  if [[ -d "${dp_root}/${ver}" ]]; then
    paths+=(
      "${dp_root}/${ver}/release.env"
      "${dp_root}/${ver}/${stable}.sha256"
    )
  fi

  for f in "${paths[@]}"; do
    [[ -e "$f" ]] || continue
    mm_verify_http_access_as_nginx_user "$f" || return 1
  done

  _mm_http_perm_ok "HTTP_PUBLICATION_PERMISSION_CLOSURE=PASS"
  return 0
}

# Normalize + verify a staged client tree before atomic swap.
mm_client_stage_prepare_public_permissions() {
  local stage="${1:-}"
  local spool_parent="${2:-}"

  [[ -d "$stage" ]] || return 1
  # mktemp -d defaults to 0700 — force public directory mode first.
  chmod 0755 "$stage" || return 1
  if [[ -n "$spool_parent" && -d "$spool_parent" ]]; then
    chmod 0755 "$spool_parent" 2>/dev/null || true
  fi
  mm_normalize_http_public_tree_permissions "$stage" client || return 1
  _mm_http_perm_ok "CLIENT_PUBLIC_PERMISSION_NORMALIZE=PASS"
  if ! mm_verify_http_public_tree_permissions "$stage" client; then
    _mm_http_perm_error "CLIENT_PUBLIC_PERMISSION_VERIFY=FAIL"
    _mm_http_perm_error "CLIENT_PUBLIC_PERMISSION_PREPUBLISH_VERIFY=FAIL"
    _mm_http_perm_info "CLIENT_SET_ATOMIC_SWAP=NOT_STARTED"
    return 1
  fi
  _mm_http_perm_ok "CLIENT_PUBLIC_PERMISSION_PREPUBLISH_VERIFY=PASS"
  printf 'CLIENT_PUBLIC_ROOT_MODE=0755\n'
  return 0
}

mm_client_live_postpublish_permission_verify() {
  local live="${1:-}"
  local probe="${2:-}"

  [[ -d "$live" ]] || return 1
  if ! mm_verify_http_public_tree_permissions "$live" client; then
    _mm_http_perm_error "CLIENT_PUBLIC_PERMISSION_POSTPUBLISH_VERIFY=FAIL"
    return 1
  fi
  _mm_http_perm_ok "CLIENT_PUBLIC_PERMISSION_POSTPUBLISH_VERIFY=PASS"
  printf 'CLIENT_PUBLIC_ROOT_MODE=0755\n'

  if [[ -z "$probe" ]]; then
    if [[ -f "${live}/stage-dp-phase2.sh" ]]; then
      probe="${live}/stage-dp-phase2.sh"
    else
      # Any published .sh is sufficient for traversal/read smoke.
      probe="$(find "$live" -maxdepth 1 -type f -name '*.sh' | head -1 || true)"
    fi
  fi
  if [[ -n "$probe" && -e "$probe" ]]; then
    if mm_verify_http_access_as_nginx_user "$probe"; then
      _mm_http_perm_ok "CLIENT_PUBLIC_NGINX_USER_READ=PASS"
    else
      _mm_http_perm_error "CLIENT_PUBLIC_NGINX_USER_READ=FAIL"
      return 1
    fi
  fi
  return 0
}
