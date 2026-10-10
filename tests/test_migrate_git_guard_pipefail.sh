#!/usr/bin/env bash
# Hermetic migration Git dirty-worktree guard. Never runs migration or uses
# a real Git repository; only exercises production function with a fake git.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATOR="$ROOT/scripts/migrate-apt-mirror-to-root.sh"
git_is_clean_src="$(awk '
  /^git_is_clean\(\) \{/ {grab=1}
  grab {print}
  grab && /^}/ {exit}
' "$MIGRATOR")"
[[ "$git_is_clean_src" == git_is_clean\(\)* ]] || { echo 'FAIL: Git guard not found' >&2;exit 1; }
eval "$git_is_clean_src"
REPO_ROOT='/never-touch-real-repository'
AUDIT_FAKE_GIT_MODE='clean'
git() {
  case "$AUDIT_FAKE_GIT_MODE" in
    clean) return 0 ;;
    dirty)
      python3 - <<'PY'
print(' M existing-user-file')
print(' M existing-other-file\n' * 18000)
PY
      ;;
    failure) return 128 ;;
  esac
}
git_is_clean || { echo 'FAIL: empty clean repo rejected' >&2; exit 1; }
echo 'PASS: clean repo accepted'
AUDIT_FAKE_GIT_MODE='dirty'
if git_is_clean; then
  echo 'FAIL: many dirty repo entries falsely reported CLEAN under pipefail' >&2
  exit 1
fi
echo 'PASS: large dirty repo blocked'
AUDIT_FAKE_GIT_MODE='failure'
if git_is_clean; then
  echo 'FAIL: git status command error falsely reported CLEAN' >&2
  exit 1
fi
echo 'PASS: git status error fails closed'
