#!/usr/bin/env bash
# Safe extraction contract for phase2-ubuntu-prerequisites.tar.gz
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=/dev/null
source "${ROOT}/client/lib/dp-phase2-ubuntu-prerequisites.sh"

make_deb() {
  local dest="$1"
  local work="$TMP/debwork"
  rm -rf "$work"
  mkdir -p "$work/DEBIAN"
  cat >"$work/DEBIAN/control" <<'EOF'
Package: phase2-prereq-fixture
Version: 1.0
Architecture: all
Maintainer: test
Description: fixture
EOF
  dpkg-deb -b "$work" "$dest" >/dev/null
}

build_valid() {
  local out="$1"
  local staging="$TMP/valid"
  rm -rf "$staging"
  mkdir -p "$staging/debs"
  make_deb "$staging/debs/phase2-prereq-fixture_1.0_all.deb"
  printf 'phase2-prereq-fixture_1.0_all.deb\n' >"$staging/install-order.txt"
  printf '{"package_count":1}\n' >"$staging/phase2-ubuntu-prerequisites.manifest.json"
  tar -C "$staging" -czf "$out" \
    phase2-ubuntu-prerequisites.manifest.json install-order.txt debs
}

assert_fail() {
  local label="$1"
  shift
  set +e
  "$@" >/dev/null 2>&1
  local rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || { echo "FAIL expected reject: $label"; exit 1; }
  echo "PASS reject $label"
}

VALID="$TMP/valid.tar.gz"
build_valid "$VALID"
dp2_prereq_assert_safe_archive "$VALID"
EXTRACT="$TMP/extract-ok"
mkdir -p "$EXTRACT"
dp2_prereq_safe_extract "$VALID" "$EXTRACT"
[[ -f "$EXTRACT/install-order.txt" ]] || { echo "FAIL extract missing order"; exit 1; }
[[ -f "$EXTRACT/debs/phase2-prereq-fixture_1.0_all.deb" ]] || { echo "FAIL extract missing deb"; exit 1; }
echo "PASS valid archive"

# ../ traversal
BAD="$TMP/trav"
mkdir -p "$BAD/debs"
printf 'x\n' >"$BAD/install-order.txt"
printf '{}\n' >"$BAD/phase2-ubuntu-prerequisites.manifest.json"
printf 'evil\n' >"$BAD/debs/../evil.txt"
# Craft member with .. via python
python3 - <<PY
import tarfile
with tarfile.open("$TMP/trav.tar.gz", "w:gz") as tf:
    for name in ("phase2-ubuntu-prerequisites.manifest.json", "install-order.txt"):
        tf.add("$BAD/"+name, arcname=name)
    info = tarfile.TarInfo(name="../evil.deb")
    data = b"evil"
    info.size = len(data)
    import io
    tf.addfile(info, io.BytesIO(data))
PY
assert_fail traversal dp2_prereq_assert_safe_archive "$TMP/trav.tar.gz"

# absolute path
python3 - <<'PY'
import tarfile, io
with tarfile.open("/tmp/abs-prereq.tar.gz", "w:gz") as tf:
    info = tarfile.TarInfo(name="/etc/evil")
    data = b"x"
    info.size = len(data)
    tf.addfile(info, io.BytesIO(data))
PY
# write under TMP
python3 - <<PY
import tarfile, io
with tarfile.open("$TMP/abs.tar.gz", "w:gz") as tf:
    info = tarfile.TarInfo(name="/etc/evil")
    data = b"x"; info.size=len(data)
    tf.addfile(info, io.BytesIO(data))
PY
assert_fail absolute dp2_prereq_assert_safe_archive "$TMP/abs.tar.gz"

# symlink
python3 - <<PY
import tarfile
with tarfile.open("$TMP/sym.tar.gz", "w:gz") as tf:
    info = tarfile.TarInfo(name="debs/link.deb")
    info.type = tarfile.SYMTYPE
    info.linkname = "/etc/passwd"
    tf.addfile(info)
PY
assert_fail symlink dp2_prereq_assert_safe_archive "$TMP/sym.tar.gz"

# hardlink
python3 - <<PY
import tarfile, io
with tarfile.open("$TMP/hard.tar.gz", "w:gz") as tf:
    info = tarfile.TarInfo(name="debs/a.deb")
    data=b"abc"; info.size=len(data)
    tf.addfile(info, io.BytesIO(data))
    h = tarfile.TarInfo(name="debs/b.deb")
    h.type = tarfile.LNKTYPE
    h.linkname = "debs/a.deb"
    tf.addfile(h)
PY
assert_fail hardlink dp2_prereq_assert_safe_archive "$TMP/hard.tar.gz"

# unexpected member
python3 - <<PY
import tarfile, io
with tarfile.open("$TMP/extra.tar.gz", "w:gz") as tf:
    info = tarfile.TarInfo(name="evil.sh")
    data=b"#!/bin/sh\n"; info.size=len(data); info.mode=0o755
    tf.addfile(info, io.BytesIO(data))
PY
assert_fail unexpected dp2_prereq_assert_safe_archive "$TMP/extra.tar.gz"

# FIFO where supported
python3 - <<PY
import tarfile
with tarfile.open("$TMP/fifo.tar.gz", "w:gz") as tf:
    info = tarfile.TarInfo(name="debs/x.deb")
    info.type = tarfile.FIFOTYPE
    tf.addfile(info)
PY
assert_fail fifo dp2_prereq_assert_safe_archive "$TMP/fifo.tar.gz"

echo "PASS test_phase2_prerequisite_archive_safety"
