#!/usr/bin/env bash
# scripts/lib/phase2_helper_generation.sh — generation-bound Phase 2 helper unit
# shellcheck shell=bash

if [[ -n "${PHASE2_HELPER_GENERATION_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
PHASE2_HELPER_GENERATION_LOADED=1

PHASE2_HELPER_GENERATION_MANIFEST_NAME="phase2-helper-generation.manifest"

phase2_helper_generation_files() {
  printf '%s\n' \
    stage-dp-phase2.sh \
    bringup_py3_dp_lifecycle.sh \
    lib/dp-offline-source-product-version.sh \
    lib/dp-phase2-operation-progress.sh \
    lib/dp-phase2-bringup-lifecycle.sh \
    lib/dp-phase2-ubuntu-prerequisites.sh
}

phase2_helper_generation_write() {
  local root="${1:?client root required}"
  local dest="${2:-${root}/${PHASE2_HELPER_GENERATION_MANIFEST_NAME}}"
  local tmp f
  [[ -d "$root" ]] || return 1
  tmp="$(mktemp "${dest}.tmp.XXXXXX")"
  (
    cd "$root" || exit 1
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      [[ -f "$f" ]] || {
        printf 'PHASE2_HELPER_GENERATION=FAIL missing=%s\n' "$f" >&2
        exit 1
      }
      sha256sum "$f"
    done < <(phase2_helper_generation_files)
  ) >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  chmod 0644 "$tmp"
  mv -f "$tmp" "$dest"
  printf '%s\n' "$dest"
}

phase2_helper_generation_sha256() {
  local man="${1:?manifest path required}"
  [[ -f "$man" ]] || return 1
  sha256sum "$man" | awk '{print $1}'
}

phase2_helper_generation_verify() {
  local root="${1:?client root required}"
  local man="${root}/${PHASE2_HELPER_GENERATION_MANIFEST_NAME}"
  local f listed
  [[ -f "$man" ]] || {
    printf 'PHASE2_HELPER_GENERATION=FAIL reason=manifest_missing\n' >&2
    return 1
  }
  [[ -s "$man" ]] || {
    printf 'PHASE2_HELPER_GENERATION=FAIL reason=manifest_empty\n' >&2
    return 1
  }
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    listed="$(awk -v p="$f" '$2 == p {print $1; exit}' "$man")"
    [[ -n "$listed" && "$listed" =~ ^[0-9a-fA-F]{64}$ ]] || {
      printf 'PHASE2_HELPER_GENERATION=FAIL reason=required_file_unlisted path=%s\n' "$f" >&2
      return 1
    }
  done < <(phase2_helper_generation_files)
  if ! (cd "$root" && sha256sum -c "$PHASE2_HELPER_GENERATION_MANIFEST_NAME" >/dev/null); then
    printf 'PHASE2_HELPER_GENERATION=FAIL reason=hash_mismatch\n' >&2
    return 1
  fi
  return 0
}

# Operator-facing Phase 2 bootstrap wrapper. Literal generation-manifest SHA256
# remains the inner trust anchor. Menu 7 separately pins this wrapper's SHA256.
phase2_upgrade_wrapper_write() {
  local root="${1:?client root required}"
  local mirror="${2:?mirror URL required}"
  local ver="${3:-6.6.0}"
  local dest="${root}/upgrade-phase2.sh"
  local man="${root}/${PHASE2_HELPER_GENERATION_MANIFEST_NAME}"
  local sha
  mirror="${mirror%/}"
  [[ -n "$mirror" && "$mirror" != *__UNREPLACED__* ]] || {
    printf 'PHASE2_UPGRADE_WRAPPER=FAIL reason=mirror_missing\n' >&2
    return 1
  }
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'PHASE2_UPGRADE_WRAPPER=FAIL reason=target_version_invalid\n' >&2
    return 1
  }
  sha="$(phase2_helper_generation_sha256 "$man")" || {
    printf 'PHASE2_UPGRADE_WRAPPER=FAIL reason=generation_sha_missing\n' >&2
    return 1
  }
  [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]] || {
    printf 'PHASE2_UPGRADE_WRAPPER=FAIL reason=generation_sha_invalid\n' >&2
    return 1
  }
  cat >"$dest" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd /home/aella
MIRROR='${mirror}'
VER='${ver}'
SCRIPT='stage-dp-phase2.sh'
GEN='phase2-helper-generation.manifest'
H='${sha}'
# Allowlisted operator passthrough only. Target/mirror/trust anchors are fixed.
SOURCE_DP_VERSION_OPT=()
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --source-dp-version)
      [[ \$# -ge 2 ]] || { echo "FATAL: --source-dp-version requires a value" >&2; exit 2; }
      case "\$2" in
        ''|*[^0-9.]*|*.*.*.*)
          echo "FATAL: invalid --source-dp-version (expected major.minor.patch)" >&2
          exit 2
          ;;
      esac
      [[ "\$2" =~ ^[0-9]+\\.[0-9]+\\.[0-9]+\$ ]] || {
        echo "FATAL: invalid --source-dp-version (expected major.minor.patch)" >&2
        exit 2
      }
      SOURCE_DP_VERSION_OPT=(--source-dp-version "\$2")
      shift 2
      ;;
    --target-version|--mirror-url|--same-version-recovery)
      echo "FATAL: protected option '\$1' cannot be overridden via upgrade-phase2.sh" >&2
      exit 2
      ;;
    -h|--help)
      echo "Usage: bash upgrade-phase2.sh [--source-dp-version X.Y.Z]"
      echo "Target ${ver} and mirror URL are fixed by Mirror Manager publication."
      echo "Normal upgrades do NOT enable same-version recovery."
      echo "For authorized recovery only, use upgrade-phase2-same-version-recovery.sh"
      exit 0
      ;;
    *)
      echo "FATAL: unknown option '\$1' (only --source-dp-version is allowed)" >&2
      exit 2
      ;;
  esac
done
W=\$(mktemp -d)
trap 'rm -rf "\$W"' EXIT
cd "\$W"
mkdir -p lib
for F in "\$GEN" "\$SCRIPT" bringup_py3_dp_lifecycle.sh lib/dp-{offline-source-product-version,phase2-operation-progress,phase2-bringup-lifecycle,phase2-ubuntu-prerequisites}.sh; do
  curl -fsSLo "\$F" "\$MIRROR/client/\$F" || exit 1
done
printf '%s  %s\\n' "\$H" "\$GEN" | sha256sum -c -
sha256sum -c "\$GEN"
# Normal path: never force --same-version-recovery. Healthy source==target
# must yield ALREADY_AT_TARGET / same-version gate without destructive recovery.
sudo bash "./\$SCRIPT" --target-version "\$VER" --mirror-url "\$MIRROR" "\${SOURCE_DP_VERSION_OPT[@]}"
EOF
  chmod 0644 "$dest"
  bash -n "$dest" || {
    printf 'PHASE2_UPGRADE_WRAPPER=FAIL reason=bash_n\n' >&2
    rm -f "$dest"
    return 1
  }
  ( cd "$root" && sha256sum upgrade-phase2.sh >upgrade-phase2.sh.sha256 ) || return 1
  chmod 0644 "${dest}.sha256"

  # Explicit recovery wrapper only. Requires CONFIRM_SAME_VERSION_RECOVERY=YES.
  local recovery="${root}/upgrade-phase2-same-version-recovery.sh"
  cat >"$recovery" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd /home/aella
MIRROR='${mirror}'
VER='${ver}'
SCRIPT='stage-dp-phase2.sh'
GEN='phase2-helper-generation.manifest'
H='${sha}'
if [[ "\${CONFIRM_SAME_VERSION_RECOVERY:-}" != "YES" ]]; then
  echo "FATAL: same-version recovery requires CONFIRM_SAME_VERSION_RECOVERY=YES" >&2
  echo "Use upgrade-phase2.sh for normal upgrades (source < target)." >&2
  exit 2
fi
SOURCE_DP_VERSION_OPT=()
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --source-dp-version)
      [[ \$# -ge 2 ]] || { echo "FATAL: --source-dp-version requires a value" >&2; exit 2; }
      [[ "\$2" =~ ^[0-9]+\\.[0-9]+\\.[0-9]+\$ ]] || {
        echo "FATAL: invalid --source-dp-version (expected major.minor.patch)" >&2
        exit 2
      }
      SOURCE_DP_VERSION_OPT=(--source-dp-version "\$2")
      shift 2
      ;;
    --target-version|--mirror-url|--same-version-recovery)
      echo "FATAL: protected option '\$1' cannot be overridden" >&2
      exit 2
      ;;
    -h|--help)
      echo "Usage: CONFIRM_SAME_VERSION_RECOVERY=YES bash upgrade-phase2-same-version-recovery.sh [--source-dp-version X.Y.Z]"
      exit 0
      ;;
    *)
      echo "FATAL: unknown option '\$1'" >&2
      exit 2
      ;;
  esac
done
W=\$(mktemp -d)
trap 'rm -rf "\$W"' EXIT
cd "\$W"
mkdir -p lib
for F in "\$GEN" "\$SCRIPT" bringup_py3_dp_lifecycle.sh lib/dp-{offline-source-product-version,phase2-operation-progress,phase2-bringup-lifecycle,phase2-ubuntu-prerequisites}.sh; do
  curl -fsSLo "\$F" "\$MIRROR/client/\$F" || exit 1
done
printf '%s  %s\\n' "\$H" "\$GEN" | sha256sum -c -
sha256sum -c "\$GEN"
sudo bash "./\$SCRIPT" --target-version "\$VER" --same-version-recovery --mirror-url "\$MIRROR" "\${SOURCE_DP_VERSION_OPT[@]}"
EOF
  chmod 0644 "$recovery"
  bash -n "$recovery" || {
    printf 'PHASE2_RECOVERY_WRAPPER=FAIL reason=bash_n\n' >&2
    rm -f "$recovery"
    return 1
  }
  ( cd "$root" && sha256sum upgrade-phase2-same-version-recovery.sh \
    >upgrade-phase2-same-version-recovery.sh.sha256 ) || return 1
  chmod 0644 "${recovery}.sha256"
  printf '%s\n' "$dest"
}
