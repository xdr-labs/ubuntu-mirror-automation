#!/usr/bin/env bash
# Shared helpers for Phase 2 prerequisite identity trust fixtures.
# shellcheck shell=bash

phase2_prereq_write_identity_for_extras() {
  local extras="${1:?extras dir required}"
  local py="${PHASE2_PREREQ_PY:-}"
  if [[ -z "$py" ]]; then
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    py="${root}/scripts/lib/phase2_ubuntu_prerequisites.py"
  fi
  python3 - "$py" "$extras" <<'PY'
import importlib.util, sys
py_path, extras = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location('phase2_ubuntu_prerequisites', py_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
fields, digest = mod.write_prerequisite_identity(extras)
print(digest)
PY
}

phase2_prereq_identity_sha_of() {
  local path="${1:?identity path required}"
  sha256sum "$path" | awk '{print $1}'
}
