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

# Raw ACPS upstream copies are private rebuild sources, never public members.
mm_http_is_forbidden_raw_upstream_name() {
  local base="${1:-}"
  case "$base" in
    *.upstream|*.upstream.sha1)
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

# Ensure product-controlled parents under apt-mirror are world-traversable.
# Never chmods system ancestors outside the product spool (e.g. /var, /var/spool).
mm_http_ensure_parent_traversal() {
  local path="${1:-}" cur mode base
  [[ -n "$path" ]] || return 1
  base="${MM_MIRROR_ROOT:-/var/spool/apt-mirror}"
  cur="$(cd "$(dirname "$path")" 2>/dev/null && pwd)" || return 1
  while [[ -n "$cur" && "$cur" != "/" ]]; do
    # Only normalize product-owned publication paths.
    if [[ "$cur" == "$base" || "$cur" == "$base"/* ]]; then
      if [[ -d "$cur" ]]; then
        mode="$(mm_http_stat_mode "$cur" || true)"
        case "$mode" in
          *1|*5|*7) ;;
          *)
            chmod 0755 "$cur" 2>/dev/null || true
            ;;
        esac
      fi
    fi
    [[ "$cur" == "$base" ]] && break
    cur="$(dirname "$cur")"
  done
  return 0
}

# Early host/publication preflight: nginx must be able to traverse host ancestors
# of the public document root (field class: /var mode 700).
# Product-controlled paths under MM_MIRROR_ROOT are skipped here — they may not
# exist yet and are explicitly normalized before HTTP publication.
# Detect-only — never chmods system directories. Fail before expensive downloads.
mm_assert_nginx_publication_ancestors() {
  local pub_root="${1:-${MM_MIRROR_ROOT:-/var/spool/apt-mirror}}"
  local product_root="${MM_MIRROR_ROOT:-$pub_root}"
  local user mode owner cur probe_ok=0
  local -a ancestors=()

  [[ -n "$pub_root" ]] || {
    _mm_http_perm_error "PUBLICATION_PREFLIGHT=FAIL reason=empty_pub_root"
    return 1
  }
  # Normalize to absolute paths when possible (best-effort).
  if [[ -d "$pub_root" ]]; then
    pub_root="$(cd "$pub_root" && pwd)"
  fi
  if [[ -d "$product_root" ]]; then
    product_root="$(cd "$product_root" && pwd)"
  fi
  user="$(mm_http_detect_nginx_user)"
  _mm_http_perm_info "PUBLICATION_PREFLIGHT_BEGIN path=${pub_root} user=${user}"

  cur="$pub_root"
  while true; do
    ancestors+=("$cur")
    [[ "$cur" == "/" ]] && break
    cur="$(dirname "$cur")"
  done

  # Walk root → leaf so the first failure is the true blocking host ancestor
  # (e.g. /var mode 700), not a deeper path that is merely unreachable.
  local i
  for ((i=${#ancestors[@]}-1; i>=0; i--)); do
    cur="${ancestors[$i]}"

    # Product spool + children: created/normalized by this product later.
    if [[ "$cur" == "$product_root" || "$cur" == "$product_root"/* ]]; then
      continue
    fi

    if [[ ! -e "$cur" ]]; then
      # System ancestors required for the default Ubuntu publication layout.
      case "$cur" in
        /|/var|/var/spool)
          _mm_http_perm_error "NGINX_TRAVERSAL=FAIL path=${cur} mode=missing user=${user}"
          _mm_http_perm_error "PUBLICATION_PREFLIGHT=FAIL"
          _mm_http_perm_info "REMEDIATION=fix host ancestor permissions for nginx traversal (do not chmod system dirs from this product blindly); typical Ubuntu: chmod 755 /var"
          return 1
          ;;
        *)
          continue
          ;;
      esac
    fi
    if [[ ! -d "$cur" ]]; then
      _mm_http_perm_error "NGINX_TRAVERSAL=FAIL path=${cur} mode=not_a_directory user=${user}"
      _mm_http_perm_error "PUBLICATION_PREFLIGHT=FAIL"
      return 1
    fi

    mode="$(mm_http_stat_mode "$cur" || echo unknown)"
    owner="$(stat -c '%U' "$cur" 2>/dev/null || echo unknown)"
    probe_ok=0

    # Live nginx-user probe only when we can actually switch users (root).
    # Hermetic non-root tests fall through to deterministic mode checks.
    if [[ "${EUID:-$(id -u)}" -eq 0 ]] && id -u "$user" >/dev/null 2>&1; then
      if command -v runuser >/dev/null 2>&1; then
        if runuser -u "$user" -- test -x "$cur" 2>/dev/null \
          || runuser -u "$user" test -x "$cur" 2>/dev/null; then
          probe_ok=1
        fi
      fi
      if [[ "$probe_ok" -eq 0 ]] \
        && su -s /bin/sh "$user" -c "test -x $(printf '%q' "$cur")" 2>/dev/null; then
        probe_ok=1
      fi
      if [[ "$probe_ok" -eq 0 ]]; then
        _mm_http_perm_error "NGINX_TRAVERSAL=FAIL path=${cur} mode=${mode} user=${user}"
        _mm_http_perm_error "PUBLICATION_PREFLIGHT=FAIL"
        _mm_http_perm_info "REMEDIATION=host ancestor '${cur}' is not traversable by ${user}; restore normal Ubuntu semantics (e.g. chmod 755 /var) — product will not chmod system ancestors"
        return 1
      fi
      continue
    fi

    # Hermetic / non-root fallback: require other-+x unless owned by nginx user.
    if [[ "$owner" == "$user" ]]; then
      continue
    fi
    case "$mode" in
      *1|*5|*7) ;;
      *)
        _mm_http_perm_error "NGINX_TRAVERSAL=FAIL path=${cur} mode=${mode} user=${user}"
        _mm_http_perm_error "PUBLICATION_PREFLIGHT=FAIL"
        _mm_http_perm_info "REMEDIATION=host ancestor '${cur}' lacks other-execute (mode=${mode}); fix host permissions before Download and Prepare"
        return 1
        ;;
    esac
  done

  _mm_http_perm_ok "PUBLICATION_PREFLIGHT=PASS path=${pub_root} user=${user}"
  return 0
}

# Fail closed on unexpected special entries in public HTTP trees.
# Selective may intentionally contain the ubuntu → hops/<known-hop>/ubuntu alias.
# client/ and phase2 version trees must not contain symlinks, hardlinks to
# outside inodes beyond normal files, or device/FIFO/socket nodes.
_mm_http_known_selective_hop() {
  case "$1" in
    xenial-to-bionic|bionic-to-focal|focal-to-jammy|jammy-to-noble) return 0 ;;
    *) return 1 ;;
  esac
}

# Validate selective/ubuntu alias: relative, known hop, canonically contained,
# resolves to <root>/hops/<hop>/ubuntu, and target exists (not broken).
_mm_http_validate_selective_ubuntu_symlink() {
  local root="$1"
  local path="$2"
  local target hop expected resolved root_resolved

  target="$(readlink -n "$path" 2>/dev/null || true)"
  [[ -n "$target" ]] || {
    printf 'empty_ubuntu_symlink_target:%s\n' "$path"
    return 1
  }
  # Reject absolute targets and any lexical ".." traversal.
  case "$target" in
    /*|*".."*)
      printf 'unsafe_ubuntu_symlink_target:%s->%s\n' "$path" "$target"
      return 1
      ;;
  esac
  case "$target" in
    hops/*/ubuntu)
      hop="${target#hops/}"
      hop="${hop%/ubuntu}"
      ;;
    *)
      printf 'unexpected_ubuntu_symlink_target:%s->%s\n' "$path" "$target"
      return 1
      ;;
  esac
  # Single path segment only (no nested hops/a/b/ubuntu).
  if [[ -z "$hop" || "$hop" == */* || "$hop" == *".."* ]]; then
    printf 'unexpected_ubuntu_symlink_hop:%s->%s\n' "$path" "$target"
    return 1
  fi
  _mm_http_known_selective_hop "$hop" || {
    printf 'unknown_ubuntu_symlink_hop:%s->%s\n' "$path" "$target"
    return 1
  }
  # Broken link / missing target fails closed.
  [[ -e "$path" ]] || {
    printf 'broken_ubuntu_symlink:%s->%s\n' "$path" "$target"
    return 1
  }
  root_resolved="$(realpath -m "$root" 2>/dev/null || printf '%s' "$root")"
  root_resolved="${root_resolved%/}"
  # Lexical expected path under the selective root (do not realpath through a
  # malicious hops/<hop>/ubuntu symlink — that would collapse escapes).
  expected="${root_resolved}/hops/${hop}/ubuntu"
  resolved="$(realpath -m "$path" 2>/dev/null || true)"
  [[ -n "$resolved" ]] || {
    printf 'unresolvable_ubuntu_symlink:%s->%s\n' "$path" "$target"
    return 1
  }
  if [[ "$resolved" != "$expected" ]]; then
    printf 'ubuntu_symlink_escape:%s->%s resolved=%s expected=%s\n' \
      "$path" "$target" "$resolved" "$expected"
    return 1
  fi
  return 0
}

mm_http_verify_public_entry_types() {
  local root="${1:-}"
  local kind="${2:-client}"
  local path base target count=0
  local -a bad=()
  local err

  [[ -n "$root" && -d "$root" ]] || return 1

  while IFS= read -r -d '' path; do
    base="$(basename "$path")"
    if [[ "$kind" == "selective" && "$base" == "ubuntu" && "$(dirname "$path")" == "$root" ]]; then
      # Documented alias: selective/ubuntu → hops/<known-hop>/ubuntu
      if [[ -L "$path" ]]; then
        if ! err="$(_mm_http_validate_selective_ubuntu_symlink "$root" "$path")"; then
          bad+=("${err}")
        fi
        continue
      fi
      continue
    fi
    if [[ "$kind" == "selective" ]]; then
      # Other selective symlinks are not part of the current publication contract.
      bad+=("unexpected_symlink:${path}")
      continue
    fi
    bad+=("unexpected_symlink:${path}")
  done < <(find "$root" -type l -print0 2>/dev/null)

  while IFS= read -r -d '' path; do
    bad+=("unexpected_special:${path}")
  done < <(find "$root" \( -type b -o -type c -o -type p -o -type s \) -print0 2>/dev/null)

  # Hardlinks: reject nlink>1 for regular files under client/phase2 (publication
  # contract prefers discrete inode copies; private rebuild sources must not
  # share inodes into the HTTP tree).
  if [[ "$kind" == "client" || "$kind" == "phase2" ]]; then
    while IFS= read -r -d '' path; do
      bad+=("unexpected_hardlink:${path}")
    done < <(find "$root" -type f -links +1 -print0 2>/dev/null)
  fi

  count="${#bad[@]}"
  if [[ "$count" -gt 0 ]]; then
    local b
    for b in "${bad[@]}"; do
      _mm_http_perm_error "HTTP_PUBLIC_ENTRY_TYPE=FAIL ${b}"
    done
    _mm_http_perm_error "HTTP_PUBLIC_UNEXPECTED_SYMLINK_COUNT=${count}"
    return 1
  fi
  if [[ "$kind" == "client" || "$kind" == "phase2" ]]; then
    printf 'HTTP_PUBLIC_UNEXPECTED_SYMLINK_COUNT=0\n'
  fi
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

  mm_http_verify_public_entry_types "$root" "$kind" || return 1

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
    if [[ "$kind" == "phase2" || "$kind" == "client" ]] \
      && mm_http_is_forbidden_raw_upstream_name "$base"; then
      _mm_http_perm_error "HTTP_PUBLIC_RAW_UPSTREAM_FORBIDDEN=${path}"
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

  mm_http_verify_public_entry_types "$root" "$kind" || return 1

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
    if [[ "$kind" == "phase2" || "$kind" == "client" ]] \
      && mm_http_is_forbidden_raw_upstream_name "$base"; then
      _mm_http_perm_error "CLIENT_PUBLIC_PERMISSION_VERIFY=FAIL raw_upstream=${path}"
      return 1
    fi
    case "$base" in
      private.gpg|private.key|*private.gpg|*private.key)
        _mm_http_perm_error "CLIENT_PUBLIC_PERMISSION_VERIFY=FAIL forbidden_public_name=${path}"
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

  # /ubuntu/ is a symlink into hops/<hop>/ubuntu. First-level 0755 on selective
  # is not enough: a leaked umask 077 leaves hop dirs 0700 → HTTP 403.
  local selective="${MM_SELECTIVE_ROOT:-${base}/selective}"
  local hop_root="${selective}/hops"
  local tight hop_file ubuntu_file
  if [[ -d "$hop_root" ]]; then
    tight="$(find "$hop_root" -type d ! -perm -o=x -print -quit 2>/dev/null || true)"
    if [[ -n "$tight" ]]; then
      _mm_http_perm_error "HTTP_PUBLICATION_PERMISSION_CLOSURE=FAIL hop_dir_not_world_traversable=${tight}"
      return 1
    fi
    hop_file="$(find "$hop_root" -type f \( -name Release -o -name InRelease -o -name Packages \) -print -quit 2>/dev/null || true)"
    if [[ -n "$hop_file" ]]; then
      paths+=("$hop_file")
    fi
  fi
  if [[ -e "${selective}/ubuntu" ]]; then
    ubuntu_file="$(find -L "${selective}/ubuntu" -maxdepth 6 -type f \( -name Release -o -name InRelease \) -print -quit 2>/dev/null || true)"
    if [[ -n "$ubuntu_file" ]]; then
      paths+=("$ubuntu_file")
    fi
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
