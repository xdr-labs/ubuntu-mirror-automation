#!/usr/bin/env python3
"""Read-only product replacement metadata checks using real synthetic .debs."""
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
LIB = pathlib.Path(os.environ.get(
    "PHASE2_PRODUCT_TEST_LIBRARY",
    str(ROOT / "client/lib/dp-phase2-ubuntu-prerequisites.sh")))
TARGET = "6.6.0"
VERSION = TARGET + "ubuntu1"
META = "aella-uvp-2404"
CHILDREN = ("aella-da-cli", "aella-da-services", "aellacm", "kube-tools",
            "phonehome", "pypki")


class ProductReplacementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="phase2-product-test.")
        self.root = pathlib.Path(self.temp.name)
        self.marker = self.root / "maintainer-ran"
        self.serial = 0

    def tearDown(self):
        self.temp.cleanup()

    def deb(self, name, version=VERSION, architecture="amd64", depends="python3",
            populate=None, extra=""):
        self.serial += 1
        tree = self.root / ("build-%d" % self.serial)
        control = tree / "DEBIAN"
        control.mkdir(parents=True)
        (control / "control").write_text(
            "Package: %s\nVersion: %s\nArchitecture: %s\n"
            "Maintainer: Test <test@example.invalid>\n"
            "%s%sDescription: product metadata test\n" % (
                name, version, architecture,
                "Depends: %s\n" % depends if depends else "", extra))
        postinst = control / "postinst"
        postinst.write_text("#!/bin/sh\ntouch '%s'\n" % self.marker)
        postinst.chmod(0o755)
        if populate:
            populate(tree)
        output = self.root / ("artifact-%d.deb" % self.serial)
        subprocess.run(["dpkg-deb", "--root-owner-group", "--build", str(tree), str(output)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        return output

    def uvp(self, missing=None, altered=None, symlink=None, duplicate=False,
            meta_name=META, meta_version=VERSION, meta_arch="amd64",
            meta_depends="openssl, python3-openssl"):
        altered = altered or {}

        def populate(tree):
            directory = tree / "opt/aelladata/aelladeb"
            directory.mkdir(parents=True)
            for package in CHILDREN:
                if package == missing:
                    continue
                child = self.deb(package, **altered.get(package, {}))
                dest = directory / (package + "_" + VERSION + "_amd64.deb")
                if package == symlink:
                    dest.symlink_to(child)
                else:
                    dest.write_bytes(child.read_bytes())
                if duplicate and package == CHILDREN[0]:
                    (directory / (package + "_6.5.0ubuntu1_amd64.deb")).write_bytes(
                        child.read_bytes())

        return self.deb(meta_name, version=meta_version, architecture=meta_arch,
                        depends=meta_depends, populate=populate)

    def invoke(self, function, *args, env=None):
        run_env = dict(os.environ)
        if env:
            run_env.update(env)
        proc = subprocess.run([
            "bash", "-c",
            'set -euo pipefail; source "$1"; shift; '
            'dp2_prereq_log() { printf "%s\\n" "$*"; }; "$@"',
            "product-test", str(LIB), function] + list(args),
            env=run_env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.assertFalse(self.marker.exists(), "metadata read executed maintainer code")
        return proc

    def artifact(self, **kwargs):
        return self.invoke("dp2_validate_product_replacement_artifact",
                           str(self.uvp(**kwargs)), TARGET)

    def assert_failure(self, result, marker):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(marker, result.stdout)
        self.assertNotIn("=PASS", result.stdout)

    def test_complete_real_archive(self):
        result = self.artifact()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("PRODUCT_REPLACEMENT_ARTIFACT=PASS target=6.6.0 packages=7", result.stdout)

    def test_missing_nested_package(self):
        self.assert_failure(self.artifact(missing="pypki"), "replacement_package_set")

    def test_ambiguous_second_nested_version(self):
        self.assert_failure(self.artifact(duplicate=True), "unexpected_product_deb")

    def test_nested_symlink_never_followed(self):
        self.assert_failure(self.artifact(symlink="pypki"), "nonregular_product_deb_pypki")

    def test_meta_identity_version_architecture(self):
        for args, marker in [
                ({"meta_name": "aella-uvp"}, "package_identity_"),
                ({"meta_version": "6.5.0ubuntu1"}, "package_version_"),
                ({"meta_arch": "arm64"}, "package_architecture_")]:
            with self.subTest(args=args):
                self.assert_failure(self.artifact(**args), marker)

    def test_nested_version_architecture_and_python2_dependency(self):
        for changed, marker in [
                ({"version": "6.2.1ubuntu1"}, "package_version_pypki"),
                ({"architecture": "arm64"}, "package_architecture_pypki"),
                ({"depends": "python3, python-configparser"}, "legacy_python_dependency_"),
                ({"depends": "python3 | python2.7"}, "legacy_python_dependency_")]:
            with self.subTest(changed=changed):
                self.assert_failure(self.artifact(altered={"pypki": changed}), marker)

    def test_meta_python2_dependency(self):
        self.assert_failure(self.artifact(meta_depends="python, openssl"),
                            "legacy_python_dependency_aella-uvp-2404_python")

    def consumers(self, depends="aellacm", altered=None, extra_record="", mutate=False,
                  residue=False):
        def record(package, depends="", version="6.2.1ubuntu1", status="install ok installed"):
            return ("Package: %s\nStatus: %s\nVersion: %s\nArchitecture: amd64\n"
                    "%sDescription: consumer fixture\n" % (
                        package, status, version, "Depends: %s\n" % depends if depends else ""))

        status = self.root / "consumer-live.status"
        rows = [record(package, depends="python2.7") for package in CHILDREN + ("aella-uvp",)]
        rows.append(record("external-consumer", depends=depends, version="1.0"))
        if residue:
            rows.append(record(META, version=VERSION, status="deinstall ok config-files"))
        if extra_record:
            rows.append(extra_record)
        status.write_text("\n".join(rows))
        before = status.read_bytes()
        empty = self.root / "empty"
        empty.mkdir(exist_ok=True)
        (self.root / "lists").mkdir(exist_ok=True)
        (self.root / "cache").mkdir(exist_ok=True)
        (self.root / "sources.list").write_text("")
        (self.root / "empty.conf").write_text("")
        config = self.root / "apt.conf"
        config.write_text(
            'Dir::Etc::parts "%s/empty";\nDir::Etc::main "%s/empty.conf";\n'
            'Dir::Etc::sourcelist "%s/sources.list";\nDir::Etc::sourceparts "%s/empty";\n'
            'Dir::State::lists "%s/lists";\nDir::Cache "%s/cache";\n' % ((self.root,) * 6))
        bindir = self.root / "bin"
        bindir.mkdir(exist_ok=True)
        apt = bindir / "apt-get"
        apt.write_text('#!/bin/sh\n/usr/bin/apt-get "$@"\nrc=$?\n'
                       'if [ "$PRODUCT_TEST_MUTATE" = 1 ]; then printf "\\n" >>"$PRODUCT_TEST_STATUS"; fi\n'
                       'exit "$rc"\n')
        apt.chmod(0o755)
        result = self.invoke("dp2_validate_product_replacement_artifact",
                             str(self.uvp(altered=altered)), TARGET, str(status), env={
                                 "PATH": str(bindir) + os.pathsep + os.environ["PATH"],
                                 "APT_CONFIG": str(config),
                                 "PRODUCT_TEST_STATUS": str(status),
                                 "PRODUCT_TEST_MUTATE": "1" if mutate else "0"})
        if not mutate:
            self.assertEqual(before, status.read_bytes(), "projection changed live status")
        return result

    def test_consumer_unversioned_surviving_package(self):
        result = self.consumers()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("PRODUCT_REPLACEMENT_CONSUMERS=PASS", result.stdout)
        self.assertIn("target_depends=deferred_to_uvp", result.stdout)
        self.assertNotIn("APT_DEPENDENCY_CHECK=PASS", result.stdout)

    def test_consumer_old_version_pin_fails_before_replacement(self):
        result = self.consumers(depends="aellacm (= 6.2.1ubuntu1)")
        self.assert_failure(result, "replacement_consumer_graph_rc_100")
        self.assertIn("external-consumer", result.stdout)

    def test_consumer_old_meta_identity_fails(self):
        self.assert_failure(self.consumers(depends="aella-uvp"),
                            "replacement_consumer_graph_rc_100")

    def test_consumer_target_conflicts_preserved(self):
        self.assert_failure(self.consumers(altered={
            "pypki": {"extra": "Conflicts: external-consumer\n"}}),
            "replacement_consumer_graph_rc_100")

    def test_consumer_target_provides_preserved(self):
        result = self.consumers(depends="new-virtual-product", altered={
            "pypki": {"extra": "Provides: new-virtual-product\n"}})
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_consumer_new_meta_residue_does_not_duplicate_target(self):
        result = self.consumers(residue=True)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_consumer_input_change_fails(self):
        self.assert_failure(self.consumers(mutate=True), "status_changed")

    def installed(self, change=None, old_status=None, missing=None, duplicate=False, rc=0):
        change = change or {}
        rows = []
        for package in (META,) + CHILDREN:
            if package == missing:
                continue
            version, arch, status = change.get(package, (VERSION, "amd64", "install ok installed"))
            rows.append("\t".join((package, version, arch, status)))
        if old_status is not None:
            rows.append("\t".join(("aella-uvp", "6.2.1ubuntu1", "amd64", old_status)))
        if duplicate:
            rows.append(rows[0])
        inventory = self.root / "inventory"
        inventory.write_text("\n".join(rows) + "\n")
        bindir = self.root / "bin"
        bindir.mkdir(exist_ok=True)
        tool = bindir / "dpkg-query"
        tool.write_text('#!/bin/sh\ncat "$PRODUCT_TEST_INVENTORY"\nexit "$PRODUCT_TEST_RC"\n')
        tool.chmod(0o755)
        return self.invoke("dp2_validate_installed_product_replacement", TARGET, env={
            "PATH": str(bindir) + os.pathsep + os.environ["PATH"],
            "PRODUCT_TEST_INVENTORY": str(inventory), "PRODUCT_TEST_RC": str(rc)})

    def test_installed_exact_target(self):
        result = self.installed()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("PRODUCT_REPLACEMENT_PACKAGES=PASS", result.stdout)
        self.assertNotIn("APT_DEPENDENCY_CHECK=PASS", result.stdout)

    def test_installed_old_meta_present(self):
        self.assert_failure(self.installed(old_status="install ok installed"),
                            "legacy_meta_still_present")

    def test_installed_config_files_are_not_installed_old_meta(self):
        result = self.installed(old_status="deinstall ok config-files")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_installed_missing_partial_wrong_target_architecture(self):
        self.assert_failure(self.installed(missing="pypki"), "installed_package_missing_pypki")
        for row, marker in [
                ((VERSION, "amd64", "install ok unpacked"), "installed_status_pypki"),
                (("6.2.1ubuntu1", "amd64", "install ok installed"), "installed_version_pypki"),
                ((VERSION, "arm64", "install ok installed"), "installed_architecture_pypki")]:
            with self.subTest(row=row):
                self.assert_failure(self.installed(change={"pypki": row}), marker)

    def test_failed_inventory_and_duplicate_architecture_fail(self):
        self.assert_failure(self.installed(rc=2), "command_failed_dpkg-query")
        self.assert_failure(self.installed(duplicate=True), "duplicate_installed_package_")


if __name__ == "__main__":
    unittest.main()
