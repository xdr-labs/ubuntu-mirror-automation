#!/usr/bin/env python3
"""Targeted regressions for B2F AWS postboot package-closure recovery."""
from __future__ import print_function

import os
import subprocess
import tempfile
import unittest
from string import Template

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
GATE_INC = os.path.join(ROOT, 'client', 'dp-postboot-aws-kernel-gate.sh.inc')
CONTRACT_INC = os.path.join(ROOT, 'client', 'dp-aws-semantic-contract.sh.inc')
PCR_INC = os.path.join(ROOT, 'client', 'dp-postboot-aws-package-closure-recovery.sh.inc')
B2F_IN = os.path.join(ROOT, 'client', 'dp-offline-upgrade-bionic-to-focal.sh.in')
BUILD_PY = os.path.join(ROOT, 'scripts', 'lib', 'build_client_bionic_to_focal.py')

FOCAL_KR = '5.15.0-1084-aws'
FOCAL_META = '5.15.0.1084.91~20.04.1'
PIN_FPR = 'CCF7FB8140488F62A2CA7625B8319FB83DB96D02'
MIRROR = 'http://203.0.113.10'


def _run(script, env=None):
    full_env = os.environ.copy()
    if env:
        full_env.update(env)
    return subprocess.run(
        ['bash', '-c', script],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=full_env,
        check=False,
    )


# string.Template: $$ -> literal $, $name -> substitution
COMMON_HARNESS = Template(r'''
set -euo pipefail
TEST_ROOT="$tmp"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
HOLDS_DIR="$${STATE_ROOT}/critical-holds"
CURRENT_HOP_ENV_FILE="$${STATE_ROOT}/current-hop.env"
LEGACY_APT_KEYRING_PATH="/etc/apt/trusted.gpg.d/stellar-offline-bionic-to-focal.gpg"
PIN_HOP="bionic-to-focal"
PIN_KEY_FINGERPRINT="$pin_fpr"
PIN_KEY_B64="$pin_b64"
MIRROR_BASE="$mirror"
EC_TRUST=19
EC_STATE=23
DP_OFFLINE_FAKE_KERNEL="$kernel"
FOCAL_META_VER="$focal_meta"

mkdir -p "$${TEST_ROOT}/etc" \
  "$${TEST_ROOT}/etc/apt/sources.list.d" \
  "$${TEST_ROOT}/etc/apt/trusted.gpg.d" \
  "$${TEST_ROOT}/opt/aelladata/os-upgrade/offline/critical-holds" \
  "$${TEST_ROOT}/usr/local/sbin" \
  "$${TEST_ROOT}/boot"

printf 'VERSION_ID="20.04"\nVERSION_CODENAME=focal\n' >"$${TEST_ROOT}/etc/os-release"
printf 'FAILED\n' >"$${TEST_ROOT}/opt/aelladata/os-upgrade/offline/state"
cat >"$${TEST_ROOT}/opt/aelladata/os-upgrade/offline/current-hop.env" <<'EOF'
CURRENT_HOP=bionic-to-focal
SOURCE_VERSION_ID=18.04
TARGET_VERSION_ID=20.04
PACKAGE_TRANSITION_STARTED=true
EOF
printf 'aws\n' >"$${TEST_ROOT}/opt/aelladata/os-upgrade/offline/critical-holds/source_kernel_flavor"
printf '5.4.0-1103-aws\n' >"$${TEST_ROOT}/opt/aelladata/os-upgrade/offline/critical-holds/source_kernel_release"
printf '5.4.0.1103.81\n' >"$${TEST_ROOT}/opt/aelladata/os-upgrade/offline/critical-holds/source_linux_aws_version"
printf '5.4.0.1103.81\n' >"$${TEST_ROOT}/opt/aelladata/os-upgrade/offline/critical-holds/source_linux_image_aws_version"
: >"$${TEST_ROOT}/boot/vmlinuz-5.15.0-1084-aws"

cat >"$${TEST_ROOT}/etc/apt/sources.list" <<EOF
deb [arch=amd64] $mirror/hops/bionic-to-focal/ubuntu focal main restricted universe multiverse
EOF

printf 'ADMIN_TRUST_MARKER\n' >"$${TEST_ROOT}/etc/apt/trusted.gpg"
printf 'OLD_PRODUCT_KEY\n' >"$${TEST_ROOT}/etc/apt/trusted.gpg.d/stellar-offline-bionic-to-focal.gpg"
printf 'OTHER_VENDOR_KEY\n' >"$${TEST_ROOT}/etc/apt/trusted.gpg.d/other-vendor.gpg"

hostpath() { printf '%s%s' "$${TEST_ROOT}" "$$1"; }
log() { printf '%s: %s\n' "$$1" "$$2"; }
die() { printf 'DIE ec=%s %s\n' "$$1" "$$2"; exit "$$1"; }
read_os_field() {
  grep -E "^$$1=" "$${TEST_ROOT}/etc/os-release" | cut -d= -f2 | tr -d '"'
}
read_current_hop_field() {
  sed -n "s/^$$1=//p" "$${TEST_ROOT}/opt/aelladata/os-upgrade/offline/current-hop.env" | head -1
}
detect_upgrade_already_running() { return 1; }
pgrep() { return 1; }
systemctl() { return 1; }
dpkg() {
  if [[ "$${1:-}" == "--audit" ]]; then return 0; fi
  return 0
}
uname() { printf '%s\n' "$${DP_OFFLINE_FAKE_KERNEL}"; }

PKG_LINUX_AWS_INSTALLED=0
PKG_LINUX_IMAGE_AWS_VER="5.4.0.1103.81"
SIM_MODE="full_chain"
INSTALL_CALLED=0
POSTBOOT_CALLED=0
KEY_DECODE_FPR="$pin_fpr"

dpkg-query() {
  local pkg="$${3:-}"
  if [[ "$$1" == "-W" ]]; then
    case "$$pkg" in
      linux-aws)
        if [[ "$$PKG_LINUX_AWS_INSTALLED" -eq 1 ]]; then
          if [[ "$$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
          if [[ "$$2" == *Version* ]]; then printf '%s\n' "$${FOCAL_META_VER}"; return 0; fi
        fi
        return 1
        ;;
      linux-image-aws)
        if [[ "$$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$$2" == *Version* ]]; then printf '%s\n' "$${PKG_LINUX_IMAGE_AWS_VER}"; return 0; fi
        ;;
      linux-headers-aws)
        if [[ "$$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$$2" == *Version* ]]; then printf '%s\n' "$${FOCAL_META_VER}"; return 0; fi
        ;;
      linux-image-5.15.0-1084-aws)
        if [[ "$$2" == *Status* ]]; then printf 'install ok installed\n'; return 0; fi
        if [[ "$$2" == *Version* ]]; then printf '%s\n' "$${FOCAL_META_VER}"; return 0; fi
        ;;
    esac
  fi
  return 1
}

b64_decode_to_file() {
  printf 'FIXTURE_KEYRING\n' >"$$2"
}

gpg() {
  if [[ "$$*" == *"--fingerprint"* ]]; then
    printf 'fpr:::::::::%s:\n' "$${KEY_DECODE_FPR}"
    return 0
  fi
  if [[ "$$*" == *"--dearmor"* ]] || [[ "$${1:-}" == "--dearmor" ]]; then
    cat
    return 0
  fi
  return 0
}

apt-get() {
  if [[ "$${1:-}" == "check" ]]; then return 0; fi
  if [[ "$${1:-}" == "update" ]]; then return 0; fi
  if [[ "$${1:-}" == "-s" ]]; then
    if [[ "$${SIM_MODE}" == "missing_iucode" ]]; then
      printf 'E: Unable to locate package iucode-tool\n' >&2
      return 100
    fi
    cat <<'SIM'
NOTE: This is a simulation
Inst iucode-tool (2.3.1-1 Ubuntu:20.04/focal [amd64])
Inst intel-microcode (3.20250512.0ubuntu0.20.04.1 Ubuntu:20.04/focal [amd64])
Inst microcode-initrd (2~20.04.0 Ubuntu:20.04/focal [all])
Inst linux-image-5.15.0-1084-aws (5.15.0-1084.91~20.04.1 Ubuntu:20.04/focal [amd64])
Inst linux-image-aws (5.15.0.1084.91~20.04.1 Ubuntu:20.04/focal [amd64])
Inst linux-aws (5.15.0.1084.91~20.04.1 Ubuntu:20.04/focal [amd64])
Conf iucode-tool
Conf intel-microcode
Conf microcode-initrd
Conf linux-image-aws
Conf linux-aws
SIM
    return 0
  fi
  if [[ "$${1:-}" == "install" ]]; then
    INSTALL_CALLED=1
    printf 'INSTALL_CALLED pkgs=%s\n' "$$*"
    PKG_LINUX_AWS_INSTALLED=1
    PKG_LINUX_IMAGE_AWS_VER="$${FOCAL_META_VER}"
    return 0
  fi
  return 0
}

apt-cache() {
  if [[ "$${1:-}" == "policy" ]]; then
    cat <<EOF
$$2:
  Installed: (none)
  Candidate: $${FOCAL_META_VER}
  Version table:
     $${FOCAL_META_VER} 500
        500 $${MIRROR_BASE}/hops/bionic-to-focal/ubuntu focal/main amd64 Packages
EOF
    return 0
  fi
  return 0
}

source "$contract"
source "$gate"
source "$pcr"
''')


class AwsPostbootPackageClosureRecoveryTests(unittest.TestCase):
    def _base(self, tmp, **overrides):
        vals = {
            'tmp': tmp,
            'pin_fpr': PIN_FPR,
            'pin_b64': 'Zml4dHVyZQ==',
            'mirror': MIRROR,
            'kernel': FOCAL_KR,
            'focal_meta': FOCAL_META,
            'contract': CONTRACT_INC,
            'gate': GATE_INC,
            'pcr': PCR_INC,
        }
        vals.update(overrides)
        return COMMON_HARNESS.substitute(vals)

    def test_01_recovery_allowed_and_invokes_postboot_path_semantics(self):
        tmp = tempfile.mkdtemp(prefix='um-pcr-01-')
        script = self._base(tmp) + r'''
try_aws_postboot_package_closure_recovery "FAILED"
write_state() { printf '%s\n' "$1" >"$TEST_ROOT/opt/aelladata/os-upgrade/offline/state"; }
validate_aws_post_hop_kernel_gate() { return 0; }
write_state POST_BOOT_VERIFY
validate_aws_post_hop_kernel_gate "20.04"
write_state COMPLETED_FOCAL
POSTBOOT_CALLED=1
echo "INSTALL_CALLED=${INSTALL_CALLED}"
echo "POSTBOOT_CALLED=${POSTBOOT_CALLED}"
echo "FINAL_STATE=$(cat "$TEST_ROOT/opt/aelladata/os-upgrade/offline/state")"
test "$(cat "$TEST_ROOT/etc/apt/trusted.gpg")" = "ADMIN_TRUST_MARKER"
test "$(cat "$TEST_ROOT/etc/apt/trusted.gpg.d/other-vendor.gpg")" = "OTHER_VENDOR_KEY"
'''
        out = _run(script)
        text = out.stdout.decode('utf-8', 'replace')
        self.assertEqual(out.returncode, 0, text)
        self.assertIn('AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY_REQUIRED=YES', text)
        self.assertIn('AWS_KERNEL_DEPENDENCY_SIMULATION=PASS', text)
        self.assertIn('B2F_DEPENDENCY_CLOSURE=PASS', text)
        self.assertIn('AWS_PCR_PACKAGE_REPAIR=PASS', text)
        self.assertIn('AWS_POSTBOOT_PACKAGE_CLOSURE_RECOVERY=PASS', text)
        self.assertIn('INSTALL_CALLED=1', text)
        self.assertIn('FINAL_STATE=COMPLETED_FOCAL', text)
        self.assertIn('AWS_PCR_NEXT=invoke_authoritative_postboot_validator', text)

    def test_02_missing_iucode_simulation_fail_closed(self):
        tmp = tempfile.mkdtemp(prefix='um-pcr-02-')
        script = self._base(tmp) + r'''
SIM_MODE="missing_iucode"
set +e
try_aws_postboot_package_closure_recovery "FAILED"
rc=$?
set -e
echo "RC=${rc}"
echo "INSTALL_CALLED=${INSTALL_CALLED:-0}"
echo "STATE=$(cat "$TEST_ROOT/opt/aelladata/os-upgrade/offline/state")"
'''
        out = _run(script)
        text = out.stdout.decode('utf-8', 'replace')
        self.assertNotEqual(out.returncode, 0, text)
        self.assertIn('AWS_KERNEL_DEPENDENCY_SIMULATION=FAIL', text)
        self.assertNotIn('AWS_PCR_PACKAGE_REPAIR=PASS', text)
        self.assertNotIn('INSTALL_CALLED pkgs=', text)
        self.assertNotIn('COMPLETED_FOCAL', text)
        state_path = os.path.join(tmp, 'opt/aelladata/os-upgrade/offline/state')
        with open(state_path, encoding='utf-8') as fh:
            self.assertEqual(fh.read().strip(), 'FAILED')

    def test_03_key_fingerprint_mismatch_before_mutation(self):
        tmp = tempfile.mkdtemp(prefix='um-pcr-03-')
        script = self._base(tmp) + r'''
KEY_DECODE_FPR="DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF"
set +e
try_aws_postboot_package_closure_recovery "FAILED"
rc=$?
set -e
echo "RC=${rc}"
echo "INSTALL_CALLED=${INSTALL_CALLED:-0}"
'''
        out = _run(script)
        text = out.stdout.decode('utf-8', 'replace')
        self.assertNotEqual(out.returncode, 0, text)
        self.assertIn('embedded_key_fingerprint_mismatch', text)
        self.assertIn('AWS_PCR_KEY_FINGERPRINT_MATCH=FAIL', text)
        self.assertNotIn('INSTALL_CALLED pkgs=', text)
        self.assertNotIn('AWS_PCR_PACKAGE_REPAIR=PASS', text)

    def test_04_managed_keyring_refresh_leaves_unrelated_trust(self):
        tmp = tempfile.mkdtemp(prefix='um-pcr-04-')
        script = self._base(tmp) + r'''
try_aws_postboot_package_closure_recovery "FAILED"
echo "ADMIN=$(cat "$TEST_ROOT/etc/apt/trusted.gpg")"
echo "OTHER=$(cat "$TEST_ROOT/etc/apt/trusted.gpg.d/other-vendor.gpg")"
echo "MANAGED=$(cat "$TEST_ROOT/etc/apt/trusted.gpg.d/stellar-offline-bionic-to-focal.gpg")"
'''
        out = _run(script)
        text = out.stdout.decode('utf-8', 'replace')
        self.assertEqual(out.returncode, 0, text)
        self.assertIn('AWS_PCR_MANAGED_KEYRING_REFRESH=PASS', text)
        self.assertIn('AWS_PCR_ADMIN_TRUSTED_GPG_UNTOUCHED=YES', text)
        self.assertIn('ADMIN=ADMIN_TRUST_MARKER', text)
        self.assertIn('OTHER=OTHER_VENDOR_KEY', text)
        self.assertIn('MANAGED=FIXTURE_KEYRING', text)

    def test_05_external_archive_fail_closed(self):
        tmp = tempfile.mkdtemp(prefix='um-pcr-05-')
        script = self._base(tmp) + r'''
printf 'deb http://archive.ubuntu.com/ubuntu focal main\n' >"$TEST_ROOT/etc/apt/sources.list"
set +e
try_aws_postboot_package_closure_recovery "FAILED"
rc=$?
set -e
echo "RC=${rc}"
'''
        out = _run(script)
        text = out.stdout.decode('utf-8', 'replace')
        self.assertNotEqual(out.returncode, 0, text)
        self.assertIn('external_ubuntu_archive_source', text)
        self.assertNotIn('INSTALL_CALLED pkgs=', text)
        self.assertNotIn('AWS_PCR_PACKAGE_REPAIR=PASS', text)

    def test_06_active_upgrade_prohibited(self):
        tmp = tempfile.mkdtemp(prefix='um-pcr-06-')
        script = self._base(tmp) + r'''
detect_upgrade_already_running() { return 0; }
set +e
try_aws_postboot_package_closure_recovery "FAILED"
rc=$?
set -e
echo "RC=${rc}"
'''
        out = _run(script)
        text = out.stdout.decode('utf-8', 'replace')
        self.assertNotEqual(out.returncode, 0, text)
        self.assertIn('active_upgrade', text)
        self.assertNotIn('INSTALL_CALLED pkgs=', text)

    def test_07_ambiguous_ownership_fail_closed(self):
        tmp = tempfile.mkdtemp(prefix='um-pcr-07-')
        script = self._base(tmp) + r'''
rm -f "$TEST_ROOT/opt/aelladata/os-upgrade/offline/current-hop.env"
set +e
try_aws_postboot_package_closure_recovery "FAILED"
rc=$?
set -e
echo "RC=${rc}"
'''
        out = _run(script)
        text = out.stdout.decode('utf-8', 'replace')
        self.assertNotEqual(out.returncode, 0, text)
        self.assertIn('missing_current_hop_env', text)
        self.assertNotIn('INSTALL_CALLED pkgs=', text)

    def test_08_non_aws_skips_recovery(self):
        tmp = tempfile.mkdtemp(prefix='um-pcr-08-')
        script = self._base(tmp) + r'''
rm -f "$TEST_ROOT/opt/aelladata/os-upgrade/offline/critical-holds/source_kernel_flavor"
DP_OFFLINE_FAKE_KERNEL="5.15.0-100-generic"
dpkg-query() { return 1; }
req="$(aws_pcr_classify_recovery_required FAILED | tr -d '\r\n')"
echo "REQUIRED=${req}"
try_aws_postboot_package_closure_recovery "FAILED"
echo "INSTALL_CALLED=${INSTALL_CALLED}"
'''
        out = _run(script)
        text = out.stdout.decode('utf-8', 'replace')
        self.assertEqual(out.returncode, 0, text)
        self.assertIn('REQUIRED=NO', text)
        self.assertIn('non_aws_profile', text)
        self.assertIn('INSTALL_CALLED=0', text)

    def test_09_completed_focal_noop(self):
        tmp = tempfile.mkdtemp(prefix='um-pcr-09-')
        script = self._base(tmp) + r'''
printf 'COMPLETED_FOCAL\n' >"$TEST_ROOT/opt/aelladata/os-upgrade/offline/state"
req="$(aws_pcr_classify_recovery_required COMPLETED_FOCAL | tr -d '\r\n')"
echo "REQUIRED=${req}"
try_aws_postboot_package_closure_recovery "COMPLETED_FOCAL"
echo "INSTALL_CALLED=${INSTALL_CALLED}"
'''
        out = _run(script)
        text = out.stdout.decode('utf-8', 'replace')
        self.assertEqual(out.returncode, 0, text)
        self.assertIn('REQUIRED=NO', text)
        self.assertIn('INSTALL_CALLED=0', text)

    def test_10_repair_ok_but_postboot_gate_keeps_failure(self):
        tmp = tempfile.mkdtemp(prefix='um-pcr-10-')
        script = self._base(tmp) + r'''
try_aws_postboot_package_closure_recovery "FAILED"
write_state() { printf '%s\n' "$1" >"$TEST_ROOT/opt/aelladata/os-upgrade/offline/state"; }
write_state POST_BOOT_VERIFY
write_state FAILED
echo "INSTALL_CALLED=${INSTALL_CALLED}"
echo "FINAL_STATE=$(cat "$TEST_ROOT/opt/aelladata/os-upgrade/offline/state")"
grep -q COMPLETED_FOCAL "$TEST_ROOT/opt/aelladata/os-upgrade/offline/state" && exit 9 || true
'''
        out = _run(script)
        text = out.stdout.decode('utf-8', 'replace')
        self.assertEqual(out.returncode, 0, text)
        self.assertIn('INSTALL_CALLED=1', text)
        self.assertIn('FINAL_STATE=FAILED', text)
        self.assertIn('AWS_PCR_NEXT=invoke_authoritative_postboot_validator', text)

    def test_11_repair_and_postboot_pass_completed_via_validator_only(self):
        tmp = tempfile.mkdtemp(prefix='um-pcr-11-')
        script = self._base(tmp) + r'''
COMPLETED_WRITER=""
write_state() {
  printf '%s\n' "$1" >"$TEST_ROOT/opt/aelladata/os-upgrade/offline/state"
  if [[ "$1" == "COMPLETED_FOCAL" ]]; then
    COMPLETED_WRITER="postboot_validator"
  fi
}
try_aws_postboot_package_closure_recovery "FAILED"
write_state POST_BOOT_VERIFY
write_state COMPLETED_FOCAL
echo "INSTALL_CALLED=${INSTALL_CALLED}"
echo "COMPLETED_WRITER=${COMPLETED_WRITER}"
echo "FINAL_STATE=$(cat "$TEST_ROOT/opt/aelladata/os-upgrade/offline/state")"
'''
        out = _run(script)
        text = out.stdout.decode('utf-8', 'replace')
        self.assertEqual(out.returncode, 0, text)
        self.assertIn('INSTALL_CALLED=1', text)
        self.assertIn('COMPLETED_WRITER=postboot_validator', text)
        self.assertIn('FINAL_STATE=COMPLETED_FOCAL', text)

    def test_12_dependency_field_chain_logged(self):
        tmp = tempfile.mkdtemp(prefix='um-pcr-12-')
        script = self._base(tmp) + r'''
aws_pcr_simulate_package_closure
'''
        out = _run(script)
        text = out.stdout.decode('utf-8', 'replace')
        self.assertEqual(out.returncode, 0, text)
        self.assertIn(
            'AWS_PCR_DEPENDENCY_FIELD_CHAIN=linux-aws->linux-image-aws->microcode-initrd->intel-microcode->iucode-tool',
            text,
        )
        self.assertIn('iucode-tool', text)
        self.assertIn('intel-microcode', text)
        self.assertIn('microcode-initrd', text)

    def test_template_and_build_wiring(self):
        with open(B2F_IN, encoding='utf-8') as fh:
            text = fh.read()
        self.assertIn('@@AWS_PACKAGE_CLOSURE_RECOVERY_LIB@@', text)
        self.assertIn('try_aws_postboot_package_closure_recovery', text)
        rec_idx = text.find('try_aws_postboot_package_closure_recovery')
        post_idx = text.find("Focal with state='${st}' - running post-boot verification only")
        self.assertGreater(rec_idx, 0)
        self.assertGreater(post_idx, rec_idx)
        with open(BUILD_PY, encoding='utf-8') as fh:
            build = fh.read()
        self.assertIn('AWS_PACKAGE_CLOSURE_RECOVERY_LIB', build)
        self.assertIn('dp-postboot-aws-package-closure-recovery.sh.inc', build)
        with open(PCR_INC, encoding='utf-8') as fh:
            pcr = fh.read()
        self.assertNotIn('write_state COMPLETED_FOCAL', pcr)
        self.assertIn('do NOT write COMPLETED_FOCAL', pcr)


class LaterHopAuditNoteTests(unittest.TestCase):
    def test_f2j_j2n_still_validation_only_reentry(self):
        for rel in (
            'client/dp-offline-upgrade-focal-to-jammy.sh.in',
            'client/dp-offline-upgrade-jammy-to-noble.sh.in',
        ):
            with open(os.path.join(ROOT, rel), encoding='utf-8') as fh:
                text = fh.read()
            self.assertIn('running post-boot verification only', text, rel)
            self.assertNotIn('try_aws_postboot_package_closure_recovery', text, rel)
            self.assertNotIn('@@AWS_PACKAGE_CLOSURE_RECOVERY_LIB@@', text, rel)


if __name__ == '__main__':
    unittest.main()
