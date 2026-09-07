#!/usr/bin/env bash
# shellcheck shell=bash
# Lifecycle / state helpers for Ubuntu Mirror Server.

# shellcheck disable=SC2317
if [[ -n "${UM_STATE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
UM_STATE_LOADED=1

# States: NOT_INSTALLED | INSTALLED | STARTING | SYNC_RUNNING | SYNC_WAITING |
#         SYNC_STALLED | SYNC_FAILED | SYNC_COMPLETE | FINALIZING | READY | PAUSED

um_state_root() {
  if [[ -n "${UM_STATE_DIR:-}" ]]; then
    printf '%s\n' "$UM_STATE_DIR"
    return
  fi
  if [[ -d /var/lib/ubuntu-mirror ]] || [[ "$(id -u)" -eq 0 ]]; then
    printf '%s\n' "/var/lib/ubuntu-mirror"
  else
    printf '%s\n' "${INSTALL_CONF_DIR:-/tmp/ubuntu-mirror-state}"
  fi
}

um_ensure_state_dir() {
  mkdir -p "$(um_state_root)" 2>/dev/null || true
}

um_state_marker() {
  printf '%s/%s\n' "$(um_state_root)" "$1"
}

um_mark_state() {
  local name="$1"
  um_ensure_state_dir
  date -Is >"$(um_state_marker "$name")" 2>/dev/null || true
}

um_has_marker() {
  [[ -f "$(um_state_marker "$1")" ]]
}

um_clear_marker() {
  rm -f "$(um_state_marker "$1")" 2>/dev/null || true
}

um_offline_ready_path() {
  printf '%s/offline/READY\n' "${BASE_PATH:-/var/spool/apt-mirror}"
}

um_selective_ready_path() {
  local root="${SELECTIVE_MIRROR_ROOT:-${BASE_PATH:-/var/spool/apt-mirror}/selective}"
  printf '%s/state/READY\n' "$root"
}

um_selective_state_dir() {
  local root="${SELECTIVE_MIRROR_ROOT:-${BASE_PATH:-/var/spool/apt-mirror}/selective}"
  printf '%s/state\n' "$root"
}

# Evaluate selective READY gates (read-only). Sets:
#   UM_SELECTIVE_READY=0|1
#   UM_SELECTIVE_READY_REASON=...
#   UM_SELECTIVE_* status fields for mirrorctl
um_evaluate_selective_ready() {
  local root state ready verify publish current published
  local ver_json pub_json plan_json
  UM_SELECTIVE_READY=0
  UM_SELECTIVE_READY_REASON="selective state incomplete"
  UM_SELECTIVE_MATERIALIZE="NOT_RUN"
  UM_SELECTIVE_VERIFY="NOT_RUN"
  UM_SELECTIVE_PUBLISH="NOT_RUN"
  UM_SELECTIVE_POST_HTTP="NOT_RUN"
  UM_SELECTIVE_NGINX_ROOT_GATE="NOT_RUN"
  UM_SELECTIVE_NGINX_CONFIG="NOT_RUN"
  UM_SELECTIVE_NGINX_HTTP="NOT_RUN"
  UM_SELECTIVE_DOWNLOADED=""
  UM_SELECTIVE_EXISTS=""
  UM_SELECTIVE_EXPECTED_DEB=""
  UM_SELECTIVE_VERIFIED_FILES=""
  UM_SELECTIVE_EXPECTED_FILES=""
  UM_SELECTIVE_UNRESOLVED=""
  UM_SELECTIVE_CHECKSUM_FAILS=""
  UM_SELECTIVE_CURRENT_TARGET=""
  UM_SELECTIVE_EFFECTIVE_NGINX_ROOT=""

  root="${SELECTIVE_MIRROR_ROOT:-${BASE_PATH:-/var/spool/apt-mirror}/selective}"
  state="${root}/state"
  ready="${state}/READY"
  verify="${state}/verify-result.json"
  [[ -f "$verify" ]] || verify="${state}/verify.json"
  publish="${state}/publish-result.json"
  [[ -f "$publish" ]] || publish="${state}/publish.json"
  plan_json="${state}/plan.json"
  current="${root}/current"
  published="${root}/published"

  if [[ ! -d "$root" ]]; then
    UM_SELECTIVE_READY_REASON="selective root missing: $root"
    return 1
  fi

  # Parse state JSONs (python keeps bash portable).
  if command -v python3 >/dev/null 2>&1; then
    # shellcheck disable=SC2016
    eval "$(python3 - "$root" "$state" "$ready" "$verify" "$publish" "$plan_json" "$current" "$published" <<'PY'
import json, os, sys
root, state, ready, verify, publish, plan_path, current, published = sys.argv[1:]

def load(path):
    if path and os.path.isfile(path):
        try:
            return json.load(open(path))
        except Exception:
            return {}
    return {}

mat = load(os.path.join(state, 'materialize.json'))
ver = load(verify)
pub = load(publish)
plan = load(plan_path)
stats = mat.get('stats') or {}
gates = pub.get('gates') or {}
counts = plan.get('counts') or {}

def q(s):
    return "'" + str(s).replace("'", "'\"'\"'") + "'"

mat_st = mat.get('validation_result') or 'NOT_RUN'
ver_st = ver.get('validation_result') or 'NOT_RUN'
pub_st = pub.get('validation_result') or 'NOT_RUN'
ver_phase = ver.get('validation_phase') or ver.get('phase') or ''
pub_phase = pub.get('validation_phase') or pub.get('phase') or ''
post = gates.get('post_publish_http') or pub.get('post_publish') or 'NOT_RUN'
if isinstance(post, dict):
    post = post.get('validation_result') or post.get('result') or 'NOT_RUN'
ngx_root_gate = gates.get('nginx_effective_root') or 'NOT_RUN'
ngx_cfg = gates.get('nginx_config') or 'NOT_RUN'
ngx_http = gates.get('nginx_http') or 'NOT_RUN'
downloaded = stats.get('downloaded', '')
exists = stats.get('exists', '')
expected_deb = counts.get('unique_deb_sha256', ver.get('package_count', ''))
verified = ver.get('verified_files', ver.get('verified_deb_count', ''))
expected_files = ver.get('expected_files', verified)
unresolved = ver.get('unresolved_count', counts.get('unresolved_deb_payloads', ''))
cksum_fail = ver.get('checksum_failures', '')
cur_tgt = ''
if os.path.islink(current):
    cur_tgt = os.path.realpath(current)
elif os.path.isdir(published):
    cur_tgt = published

plan_ck = (plan.get('plan_checksum') or plan.get('selective_plan_checksum')
           or '')
ver_plan = ver.get('plan_checksum') or ver.get('selective_plan_checksum') or ''
pub_plan = pub.get('plan_checksum') or pub.get('selective_plan_checksum') or ''
disc = plan.get('discovery_artifact_checksum') or ''
ver_disc = ver.get('discovery_artifact_checksum') or ''
pub_disc = pub.get('discovery_artifact_checksum') or ''
ready_exists = os.path.isfile(ready)
ready_ok_marker = False
if ready_exists:
    try:
        body = open(ready).read()
        ready_ok_marker = body.strip().startswith('READY') or 'profile_name=' in body
    except Exception:
        ready_ok_marker = False

reasons = []
if not ready_exists or not ready_ok_marker:
    reasons.append('READY file missing or invalid')
if ver_st != 'PASS':
    reasons.append('verify validation_result!=PASS')
if ver_phase and ver_phase != 'pre_publish':
    reasons.append('verify phase!=pre_publish')
if not ver_phase:
    reasons.append('verify phase missing')
if pub_st != 'PASS':
    reasons.append('publish validation_result!=PASS')
if pub_phase != 'post_publish':
    reasons.append('publish phase!=post_publish')
if plan_ck and ver_plan and plan_ck != ver_plan:
    reasons.append('plan checksum mismatch (verify)')
if plan_ck and pub_plan and plan_ck != pub_plan:
    reasons.append('plan checksum mismatch (publish)')
if disc and ver_disc and disc != ver_disc:
    reasons.append('discovery checksum mismatch (verify)')
if disc and pub_disc and disc != pub_disc:
    reasons.append('discovery checksum mismatch (publish)')
if not os.path.islink(current):
    reasons.append('current symlink missing')
elif not os.path.isdir(os.path.realpath(current)):
    reasons.append('current target missing')
if not os.path.isdir(published):
    reasons.append('published tree missing')
try:
    ur = int(unresolved) if unresolved not in ('', None) else 0
except Exception:
    ur = -1
if ur != 0:
    reasons.append('unresolved!=0')
if ngx_root_gate != 'PASS':
    reasons.append('nginx effective root gate!=PASS')

ok = (len(reasons) == 0)
reason = 'Selective mirror verified and published' if ok else '; '.join(reasons)

print('UM_SELECTIVE_MATERIALIZE=%s' % q(mat_st))
print('UM_SELECTIVE_VERIFY=%s' % q(ver_st))
print('UM_SELECTIVE_PUBLISH=%s' % q(pub_st))
print('UM_SELECTIVE_POST_HTTP=%s' % q(post))
print('UM_SELECTIVE_NGINX_ROOT_GATE=%s' % q(ngx_root_gate))
print('UM_SELECTIVE_NGINX_CONFIG=%s' % q(ngx_cfg))
print('UM_SELECTIVE_NGINX_HTTP=%s' % q(ngx_http))
print('UM_SELECTIVE_DOWNLOADED=%s' % q(downloaded))
print('UM_SELECTIVE_EXISTS=%s' % q(exists))
print('UM_SELECTIVE_EXPECTED_DEB=%s' % q(expected_deb))
print('UM_SELECTIVE_VERIFIED_FILES=%s' % q(verified))
print('UM_SELECTIVE_EXPECTED_FILES=%s' % q(expected_files))
print('UM_SELECTIVE_UNRESOLVED=%s' % q(unresolved if unresolved != '' else 0))
print('UM_SELECTIVE_CHECKSUM_FAILS=%s' % q(cksum_fail if cksum_fail != '' else 0))
print('UM_SELECTIVE_CURRENT_TARGET=%s' % q(cur_tgt))
print('UM_SELECTIVE_READY=%s' % (1 if ok else 0))
print('UM_SELECTIVE_READY_REASON=%s' % q(reason))
PY
)"
  else
    UM_SELECTIVE_READY_REASON="python3 required to evaluate selective READY"
    return 1
  fi

  UM_SELECTIVE_EFFECTIVE_NGINX_ROOT="${SELECTIVE_NGINX_ROOT:-${root}}"
  if [[ "${UM_SELECTIVE_READY:-0}" == "1" ]]; then
    return 0
  fi
  return 1
}

um_is_selective_profile() {
  case "${MIRROR_MODE:-}" in
    selective|SELECTIVE|offline-upgrade-selective|discovery_exact) return 0 ;;
  esac
  local root="${SELECTIVE_MIRROR_ROOT:-${BASE_PATH:-/var/spool/apt-mirror}/selective}"
  [[ -f "${root}/state/READY" ]] || [[ -f "${root}/state/verify-result.json" ]] \
    || [[ -f "${root}/state/publish-result.json" ]] || [[ -e "${root}/current" ]]
}

um_is_mirror_ready() {
  # Selective profile: require full READY gates (never forge from file alone).
  if um_is_selective_profile 2>/dev/null; then
    um_evaluate_selective_ready 2>/dev/null || true
    [[ "${UM_SELECTIVE_READY:-0}" == "1" ]]
    return
  fi
  # State dir marker (mirrorctl finalize) OR legacy offline READY file.
  if um_has_marker "ready"; then
    return 0
  fi
  [[ -f "$(um_offline_ready_path)" ]]
}

um_ready_field() {
  # um_ready_field <key> — read key=value from selective READY, else offline READY
  local key="$1" f
  f="$(um_selective_ready_path)"
  if [[ ! -f "$f" ]]; then
    f="$(um_offline_ready_path)"
  fi
  [[ -f "$f" ]] || return 1
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$f"
}

um_is_sync_running() {
  if systemctl is-active --quiet apt-mirror.service 2>/dev/null; then
    return 0
  fi
  # Selective materialize / verify / publish
  pgrep -f 'ubuntu-offline-mirror\.sh[[:space:]]+(materialize-selective|verify-selective|publish-selective|plan-selective)' >/dev/null 2>&1 \
    && return 0
  pgrep -f 'selective_mirror\.py[[:space:]]+materialize' >/dev/null 2>&1 \
    && return 0
  # Legacy full apt-mirror (should not run under selective profile)
  pgrep -f '/usr/bin/perl /usr/bin/apt-mirror' >/dev/null 2>&1 \
    || pgrep -f 'ubuntu-offline-mirror\.sh[[:space:]]+sync([[:space:]]|$)' >/dev/null 2>&1 \
    || pgrep -f '/usr/local/lib/ubuntu-mirror/run-apt-mirror\.sh' >/dev/null 2>&1 \
    || pgrep -f 'run-apt-mirror\.sh' >/dev/null 2>&1
}

um_is_installed() {
  [[ -f /etc/apt/mirror.list ]] \
    && [[ -f /etc/systemd/system/apt-mirror.service ]] \
    && [[ -x "${INSTALL_BIN_DIR:-/usr/local/bin}/mirrorctl" ]]
}

um_initial_sync_complete() {
  if um_has_marker "initial-sync-complete"; then
    return 0
  fi
  if um_is_mirror_ready; then
    return 0
  fi
  local noble_release
  noble_release="${DIST_ROOT:-${BASE_PATH:-/var/spool/apt-mirror}/mirror/archive.ubuntu.com/ubuntu/dists}/noble/Release"
  if [[ -f "$noble_release" ]]; then
    if [[ -f "${APT_MIRROR_LOG:-/var/log/apt-mirror.log}" ]] && grep -q 'End time:' "${APT_MIRROR_LOG}" 2>/dev/null; then
      return 0
    fi
    if [[ -f "${APT_MIRROR_INITIAL_LOG:-/var/log/apt-mirror-initial.log}" ]] && grep -q 'End time:' "${APT_MIRROR_INITIAL_LOG}" 2>/dev/null; then
      return 0
    fi
    if [[ -f /var/log/ubuntu-offline-mirror.log ]] && grep -q 'sync complete — READY' /var/log/ubuntu-offline-mirror.log 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

um_detect_lifecycle_state() {
  # Prefer detailed health detection when progress helpers are loaded.
  if declare -F um_detect_sync_health >/dev/null 2>&1; then
    um_detect_sync_health
    printf '%s\n' "${UM_LIFECYCLE_STATE:-INSTALLED}"
    return
  fi

  if ! um_is_installed; then
    printf 'NOT_INSTALLED\n'
    return
  fi
  if um_is_mirror_ready; then
    printf 'READY\n'
    return
  fi
  if um_has_marker "finalizing"; then
    printf 'FINALIZING\n'
    return
  fi
  if um_initial_sync_complete && systemctl is-enabled --quiet apt-mirror.timer 2>/dev/null; then
    printf 'READY\n'
    return
  fi
  if um_is_sync_running; then
    # Coarse fallback without progress.sh: treat active sync as RUNNING
    printf 'SYNC_RUNNING\n'
    return
  fi
  if um_has_marker "sync-failed"; then
    printf 'SYNC_FAILED\n'
    return
  fi
  if um_initial_sync_complete; then
    printf 'SYNC_COMPLETE\n'
    return
  fi
  if um_has_marker "sync-started"; then
    local st
    st="$(systemctl show -p ActiveState --value apt-mirror.service 2>/dev/null || true)"
    if [[ "$st" == "activating" ]]; then
      printf 'STARTING\n'
      return
    fi
  fi
  printf 'INSTALLED\n'
}
