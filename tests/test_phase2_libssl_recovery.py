#!/usr/bin/env python3
"""Bounded SSL recovery: real private APT graph, never host package installs."""
import fcntl
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
LIB = pathlib.Path(os.environ.get(
    "PHASE2_PREREQ_TEST_LIBRARY",
    str(ROOT / "client/lib/dp-phase2-ubuntu-prerequisites.sh")))
OLD = "3.0.13-0ubuntu3.6"
NEW = "3.0.13-0ubuntu3.15"
PIN = "cefc6371d90d953a4cbb35d72d871f057e4b961a3107186f67fe96a88040cdb8"
LEGACY_DEPENDS = {
    "aella-da-cli": "python2.7, python-openssl, python-yaml",
    "aella-da-services": "python2.7, openssl, python-openssl, python-yaml, python-concurrent.futures",
    "aella-uvp": "python, openssl, python-openssl, python-yaml, python-flask, python-concurrent.futures, python-configparser, python-tabulate, python-tornado, python-httplib2, python-requests, python-psutil",
    "aellacm": "python2.7, python-yaml, python-tornado, python-httplib2, python-requests, python-crypto, pypki",
    "kube-tools": "python2.7", "phonehome": "",
    "pypki": "python2.7, openssl, python-configparser, python-tabulate",
}


def record(name, version, depends="", arch="amd64", state="install ok installed"):
    return ("Package: %s\nVersion: %s\nArchitecture: %s\nStatus: %s\n"
            "Maintainer: Fixture <fixture@example.invalid>\nDescription: fixture\n%s\n"
            % (name, version, arch, state,
               "Depends: " + depends + "\n" if depends else ""))


class LibsslRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="phase2-ssl-recovery-test.")
        self.root = pathlib.Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.lifecycle = self.root / "lifecycle"
        self.lifecycle.mkdir()
        for name in ("lock", "artifact-consumer.lock"):
            (self.lifecycle / name).touch()
        (self.lifecycle / "state").write_text("FAILED\n")
        (self.root / "lists/partial").mkdir(parents=True)
        for name in ("empty", "cache", "logs", "state"):
            (self.root / name).mkdir()
        for name in ("empty.conf", "sources.list", "preferences"):
            (self.root / name).write_text("")
        self.status = self.root / "status"
        self.status.write_text(record("libssl3t64", NEW) + record("openssl", NEW) +
                               record("libssl-dev", OLD, "libssl3t64 (= %s)" % OLD))
        self.config = self.root / "apt.conf"
        dirs = {
            "Dir::Etc": "empty", "Dir::Etc::parts": "empty",
            "Dir::Etc::main": "empty.conf", "Dir::Etc::sourcelist": "sources.list",
            "Dir::Etc::sourceparts": "empty", "Dir::Etc::preferences": "preferences",
            "Dir::Etc::preferencesparts": "empty", "Dir::State": "state",
            "Dir::State::status": "status", "Dir::State::lists": "lists",
            "Dir::Cache": "cache", "Dir::Log": "logs",
        }
        self.config.write_text("".join('%s "%s";\n' % (key, self.root / path)
                                       for key, path in dirs.items()) +
                               'Dir::Cache::pkgcache "";\nDir::Cache::srcpkgcache "";\n'
                               'Debug::NoLocking "true";\nAPT::Architecture "amd64";\n')
        self.install_log = self.root / "installed.log"
        self.maintainer = self.root / "maintainer-executed"
        tree = self.root / "build/DEBIAN"
        tree.mkdir(parents=True)
        (tree / "control").write_text(
            "Package: libssl-dev\nVersion: %s\nArchitecture: amd64\n"
            "Maintainer: Fixture <fixture@example.invalid>\n"
            "Depends: libssl3t64 (= %s)\nDescription: fixture\n" % (NEW, NEW))
        postinst = tree / "postinst"
        postinst.write_text("#!/bin/sh\ntouch '%s'\n" % self.maintainer)
        postinst.chmod(0o755)
        self.deb = self.root / "libssl-dev_3.0.13-0ubuntu3.15_amd64.deb"
        subprocess.run(["dpkg-deb", "--build", str(tree.parent), str(self.deb)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.tool("id", """#!/bin/bash
if [[ "${TEST_CASE:-}" == not_root ]]; then echo 1000; else echo 0; fi
""")
        self.tool("pgrep", """#!/bin/bash
case "${TEST_CASE:-}" in
 busy) echo '1234 apt-get install something'; exit 0 ;;
 pgrep_error) exit 2 ;;
 *) exit 1 ;;
esac
""")
        # The synthetic deb cannot have Ubuntu's pinned hash. Only this one
        # integrity command is mocked; metadata and plan hashing stay real.
        self.tool("sha256sum", """#!/bin/bash
if [[ "${@: -1}" == *.deb && "${TEST_CASE:-}" != bad_hash ]]; then
  printf '%s  %s\\n' "$TEST_PIN" "${@: -1}"
else
  exec /usr/bin/sha256sum "$@"
fi
""")
        self.tool("dpkg-query", """#!/usr/bin/python3
import os, pathlib, sys
if os.environ.get('TEST_CASE') == 'query_failed': sys.exit(7)
for paragraph in pathlib.Path(os.environ['TEST_STATUS']).read_text().split('\\n\\n'):
    fields = dict(line.split(': ', 1) for line in paragraph.splitlines() if ': ' in line)
    if fields.get('Package'):
        print('\\t'.join(fields.get(k, '') for k in ('Package', 'Version', 'Architecture', 'Status')))
""")
        self.tool("dpkg", """#!/bin/bash
case "$1" in
 --audit)
   [[ "${TEST_CASE:-}" != audit_error ]] || exit 42
   [[ "${TEST_CASE:-}" != audit_dirty ]] || echo 'half configured package'
   exit 0 ;;
 --print-architecture) echo amd64; exit 0 ;;
 --compare-versions) exec /usr/bin/dpkg "$@" ;;
 -i)
   printf '%s\\n' "$*" >>"$TEST_INSTALL_LOG"
   [[ "${TEST_CASE:-}" != install_error ]] || exit 42
   [[ "${TEST_CASE:-}" != no_install_change ]] || exit 0
   /usr/bin/python3 - <<'PY'
import os, pathlib
p = pathlib.Path(os.environ['TEST_STATUS'])
text = p.read_text().replace('3.0.13-0ubuntu3.6', '3.0.13-0ubuntu3.15')
if os.environ.get('TEST_CASE') == 'post_graph_error':
    text += ('Package: broken-after\\nVersion: 1\\nArchitecture: amd64\\n'
             'Status: install ok installed\\nDescription: test\\nDepends: missing-after\\n\\n')
p.write_text(text)
PY
   exit $? ;;
 *) echo 'Unexpected dpkg invocation' >&2; exit 99 ;;
esac
""")
        self.tool("apt-get", """#!/bin/bash
[[ "${@: -1}" == check ]] || { echo 'Unexpected mutating APT operation' >&2; exit 99; }
exec /usr/bin/apt-get "$@"
""")

    def tearDown(self):
        self.assertFalse(self.maintainer.exists(), "a real maintainer script ran")
        self.temp.cleanup()

    def tool(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def invoke(self, mode="--check-libssl-dev", case="", prelude="", deb=None):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   TEST_ROOT=str(self.root), TEST_STATUS=str(self.status), TEST_CASE=case,
                   TEST_PIN=PIN, TEST_INSTALL_LOG=str(self.install_log),
                   TEST_LIFECYCLE=str(self.lifecycle), TMPDIR=str(self.root),
                   APT_CONFIG=str(self.config), LC_ALL="C")
        script = r'''set -euo pipefail
source "$1"
dp2_legacy_product_transition_environment() { [[ "$TEST_CASE" != wrong_environment ]]; }
dp2_legacy_product_transition_status_path() {
  [[ "$TEST_CASE" != wrong_status ]] || return 1
  printf '%s\n' "$TEST_STATUS"
}
dp2_libssl_recovery_lifecycle_dir() { printf '%s\n' "$TEST_LIFECYCLE"; }
'''
        script += prelude + '\ndp2_libssl_dev_recovery "$2" "$3"\n'
        return subprocess.run(["bash", "-c", script, "recovery-test", str(LIB), mode,
                               str(deb or self.deb)], env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, timeout=30)

    def failure(self, result, reason):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(reason, result.stdout)
        self.assertNotIn("PHASE2_LIBSSL_RECOVERY=PASS", result.stdout)
        self.assertFalse(self.install_log.exists(), result.stdout)

    def test_check_repairs_projection_only(self):
        before = self.status.read_bytes()
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("PHASE2_LIBSSL_RECOVERY=CHECK_PASS", result.stdout)
        self.assertEqual(self.status.read_bytes(), before)
        self.assertFalse(self.install_log.exists())

    def test_explicit_apply_installs_exactly_one_package(self):
        result = self.invoke("--repair-libssl-dev")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("PHASE2_LIBSSL_RECOVERY=PASS", result.stdout)
        calls = self.install_log.read_text().splitlines()
        self.assertEqual(len(calls), 1, calls)
        self.assertTrue(calls[0].startswith("-i "), calls)
        self.assertTrue(calls[0].endswith(self.deb.name), calls)

    def test_already_fixed_does_not_install_again(self):
        self.status.write_text(self.status.read_text().replace(OLD, NEW))
        result = self.invoke("--repair-libssl-dev")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("previous_state=ALREADY_FIXED", result.stdout)
        self.assertFalse(self.install_log.exists())

    def test_known_legacy_py2_is_deferred_explicitly(self):
        with self.status.open("a") as stream:
            stream.write("".join(record(name, "6.2.1ubuntu1", deps)
                                 for name, deps in LEGACY_DEPENDS.items()))
        result = self.invoke("--repair-libssl-dev")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("PHASE2_PREREQ_TRANSACTION_LEGACY=DEFERRED_LEGACY_PY2", result.stdout)
        self.assertIn("APT_DEPENDENCY_CHECK=DEFERRED_LEGACY_PY2", result.stdout)
        self.assertIn("LEGACY_PRODUCT_REPLACEMENT=PENDING", result.stdout)
        self.assertNotIn("APT_DEPENDENCY_CHECK=PASS", result.stdout)
        self.assertIn("PHASE2_LIBSSL_RECOVERY=PASS", result.stdout)
        self.assertEqual(len(self.install_log.read_text().splitlines()), 1)

    def test_reverse_pin_blocks_before_install(self):
        with self.status.open("a") as stream:
            stream.write(record("reverse-pin", "1", "libssl-dev (= %s)" % OLD))
        self.failure(self.invoke("--repair-libssl-dev"), "projected_dependency_graph")

    def test_unrelated_graph_fault_blocks(self):
        with self.status.open("a") as stream:
            stream.write(record("unrelated", "1", "missing-package"))
        self.failure(self.invoke("--repair-libssl-dev"), "projected_dependency_graph")

    def test_required_preconditions(self):
        for case, marker in [("not_root", "root_required"),
                             ("wrong_environment", "ubuntu_noble_amd64_required"),
                             ("wrong_status", "status_path"),
                             ("busy", "active_package_or_bringup_work"),
                             ("pgrep_error", "activity_check_failed"),
                             ("bad_hash", "deb_checksum"),
                             ("audit_error", "dpkg_audit"),
                             ("audit_dirty", "dpkg_audit"),
                             ("query_failed", "package_query")]:
            with self.subTest(case=case):
                self.failure(self.invoke("--repair-libssl-dev", case), marker)

    def test_running_lifecycle_blocks(self):
        (self.lifecycle / "state").write_text("RUNNING\n")
        self.failure(self.invoke("--repair-libssl-dev"), "lifecycle_not_terminal")

    def test_lifecycle_lock_blocks(self):
        for name in ("lock", "artifact-consumer.lock"):
            with self.subTest(name=name), (self.lifecycle / name).open("r") as handle:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.failure(self.invoke("--repair-libssl-dev"), "lifecycle_busy")

    def test_missing_lifecycle_lock_blocks(self):
        (self.lifecycle / "lock").unlink()
        self.failure(self.invoke("--repair-libssl-dev"), "lifecycle_lock_missing")

    def test_unexpected_installed_version_blocks(self):
        self.status.write_text(self.status.read_text().replace(OLD, "3.0.13-0ubuntu3.9"))
        self.failure(self.invoke("--repair-libssl-dev"), "installed_version_libssl-dev")

    def test_foreign_multiarch_blocks(self):
        with self.status.open("a") as stream:
            stream.write(record("libssl3t64", NEW, arch="i386"))
        self.failure(self.invoke("--repair-libssl-dev"), "selected_package_multiarch")

    def test_deb_symlink_blocks(self):
        link = self.root / "candidate.deb"
        link.symlink_to(self.deb)
        self.failure(self.invoke("--repair-libssl-dev", deb=link), "deb_not_regular")

    def test_exact_deb_control_required_even_after_integrity_gate(self):
        control = self.root / "build/DEBIAN/control"
        control.write_text(control.read_text().replace(
            "Depends: libssl3t64 (= %s)" % NEW,
            "Depends: libssl3t64 (= %s)" % OLD))
        subprocess.run(["dpkg-deb", "--build", str(control.parent.parent), str(self.deb)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.failure(self.invoke("--repair-libssl-dev"), "deb_control")

    def test_status_change_before_execution_blocks(self):
        prelude = r'''
dp2_prereq_verify_transaction_snapshot() {
  printf '\n' >>"$TEST_STATUS"
  dp2_prereq_transaction_metadata verify "$1" "$TEST_STATUS"
}
'''
        self.failure(self.invoke("--repair-libssl-dev", prelude=prelude), "status_changed")

    def test_install_failure_preserves_exit(self):
        result = self.invoke("--repair-libssl-dev", "install_error")
        self.assertEqual(result.returncode, 42, result.stdout)
        self.assertIn("reason=dpkg_install rc=42", result.stdout)
        self.assertNotIn("PHASE2_LIBSSL_RECOVERY=PASS", result.stdout)

    def test_install_postconditions(self):
        for case, marker in [("no_install_change", "installed_postcondition"),
                             ("post_graph_error", "dependency_postcondition")]:
            with self.subTest(case=case):
                result = self.invoke("--repair-libssl-dev", case)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(marker, result.stdout)
                self.assertNotIn("PHASE2_LIBSSL_RECOVERY=PASS", result.stdout)

    def test_direct_cli_requires_explicit_supported_mode(self):
        result = subprocess.run(["bash", str(LIB)], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("Usage:", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
