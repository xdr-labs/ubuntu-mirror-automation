#!/usr/bin/env python3
"""Hermetic Phase 2 shell-recovery and clock-skew regression tests."""
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
STAGE = (ROOT / "client/stage-dp-phase2.sh").read_text()
WRAP = (ROOT / "client/bringup_py3_dp_lifecycle.sh").read_text()
RESTORE = (ROOT / "client/restore-aella-shell.sh").read_text()
TIME = ROOT / "client/lib/dp-phase2-time-readiness.sh"


def check_static():
    marker = "cat >\"$temp_helper\" <<'DP_SHELL_RESTORE_EMBEDDED_SCRIPT'\n"
    assert STAGE.count(marker) == 1, "missing/duplicate embedded recovery"
    embedded = STAGE.split(marker, 1)[1].split(
        "\nDP_SHELL_RESTORE_EMBEDDED_SCRIPT\n", 1
    )[0] + "\n"
    assert embedded == RESTORE, "embedded helper drifted from standalone source"
    main = STAGE.split("\nstage_main() {\n", 1)[1]
    assert main.index("  prepare_phase2_aella_shell_recovery\n") < main.index(
        "  normalize_phase2_aella_login_shell\n"
    ), "recording must precede normalization"
    assert 'local helper="/root/restore-aella-shell.sh"' in STAGE
    assert 'helper="/root/restore-aella-shell.sh"' in WRAP
    assert '[[ ! -L "$helper" ]]' in STAGE
    assert 'if ! grep -qx "DP_UPGRADE_COMPLETE=YES" <<<"$fields"; then' in WRAP
    assert 'p2b_record_cluster_validation "$RECORD_CLUSTER_VALIDATION" || exit $?' in WRAP
    assert 'p2b_record_post_bringup_migration "$RECORD_MIGRATION" || exit $?' in WRAP
    assert 'p2b_try_auto_restore_local_aella_shell' in WRAP
    assert 'if (( EUID != 0 )); then' in RESTORE, "production must remain root-only"
    print("PASS shell helper integrity, capture order and auto-completion gate")


def check_skew():
    script = r"""
set -u
source "$1"
dp_phase2_ntpwait_ok() { return 1; }
dp_phase2_ntpq_selected_peer() { return 1; }
dp_phase2_ntpq_leap_ok() { return 1; }
dp_phase2_timedatectl_synchronized() { return 1; }
classify_ntp_source_class() { NTP_SOURCE_CLASS=UNKNOWN; INTERNAL_NTP_REQUIREMENT=NOT_SATISFIED; }
dp_phase2_clock_skew_from_ntpq_seconds() {
  if [[ "$SCENARIO" == excessive ]]; then printf '377'; return 0; fi
  return 1
}
dp_phase2_clock_skew_from_http_date_seconds() { return 1; }
DP_MAX_CLOCK_SKEW_SECONDS=300
check_ntp_bringup_readiness
printf 'CASE_TIME=%s\nCASE_READY=%s\nCASE_SKEW=%s\n' "$TIME_READINESS" "$BRINGUP_READY" "$CLOCK_SKEW_SECONDS"
if dp_phase2_bringup_time_gate; then echo 'CASE_GATE=PASS'; else echo 'CASE_GATE=FAIL'; fi
"""
    for scenario, state, readiness, gate in (
        ("excessive", "PASS_WITH_WARNING", "YES", "PASS"),
        ("unverifiable", "FAIL_TIME_UNVERIFIABLE", "NO", "FAIL"),
    ):
        result = subprocess.run(
            ["bash", "-c", script, "test", str(TIME)],
            env={**os.environ, "SCENARIO": scenario},
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode == 0, result.stderr
        assert "CASE_TIME=" + state in result.stdout, result.stdout
        assert "CASE_READY=" + readiness in result.stdout, result.stdout
        assert "CASE_GATE=" + gate in result.stdout, result.stdout
        if scenario == "excessive":
            assert "CASE_SKEW=377" in result.stdout
            assert "CLOCK_SKEW_EXCEEDS_TOLERANCE" in result.stdout
        print("PASS time readiness", scenario)


def check_restore():
    with tempfile.TemporaryDirectory(prefix="phase2-shell-test-") as temp:
        d = pathlib.Path(temp)
        bin_dir = d / "bin"
        bin_dir.mkdir()
        passwd = d / "passwd"
        state = d / "shell.state"
        target = d / "aella_cli"
        target.write_text("#!/bin/sh\nexit 0\n")
        target.chmod(0o755)
        passwd.write_text("aella:x:1000:27::/home/aella:/bin/bash\n")
        state.write_text("aella:1000:27:" + str(target) + "\n")
        (bin_dir / "getent").write_text(
            "#!/bin/sh\n[ \"$1\" = passwd ] && [ \"$2\" = aella ] && cat \"$MOCK_PASSWD\"\n"
        )
        (bin_dir / "usermod").write_text(
            "#!/bin/sh\n[ \"$1\" = -s ] && [ \"$3\" = aella ] || exit 2\n"
            "printf 'aella:x:1000:27::/home/aella:%s\\n' \"$2\" > \"$MOCK_PASSWD\"\n"
        )
        (bin_dir / "stat").write_text("#!/bin/sh\n[ \"$1\" = -c ] && echo 0\n")
        for file in bin_dir.iterdir():
            file.chmod(0o755)
        # The fixture drops only the EUID guard and substitutes fixture paths.
        # It never invokes real usermod, touches /etc/passwd or requires root.
        fixture = RESTORE.replace(
            "STATE=/opt/aelladata/os-upgrade/offline/aella-shell-restore.state",
            'STATE="' + str(state) + '"',
        ).replace(
            "if (( EUID != 0 )); then",
            "if false; then",
        ).replace("/usr/bin/aella_cli", str(target))
        fixture_path = d / "restore-fixture.sh"
        fixture_path.write_text(fixture)
        env = {**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
               "MOCK_PASSWD": str(passwd)}

        def run(*args):
            return subprocess.run(
                ["bash", str(fixture_path), *args],
                env=env, capture_output=True, text=True, timeout=10,
            )

        status = run("--status")
        assert status.returncode == 0 and "AELLA_SHELL_CURRENT=/bin/bash" in status.stdout
        assert "AELLA_SHELL_RECORDED=" + str(target) in status.stdout

        done = run("--auto")
        assert done.returncode == 0 and "AELLA_SHELL_RESTORE=PASS" in done.stdout, done.stderr
        assert passwd.read_text().strip().endswith(":" + str(target))

        again = run("--restore")
        assert again.returncode == 0 and "AELLA_SHELL_RESTORE=ALREADY" in again.stdout

        passwd.write_text("aella:x:1001:27::/home/aella:/bin/bash\n")
        drift = run("--restore")
        assert drift.returncode != 0 and "state_identity_mismatch" in drift.stderr
        assert passwd.read_text().strip().endswith(":/bin/bash")

        state.unlink()
        missing = run("--auto")
        assert missing.returncode != 0 and "unknown_original_shell" in missing.stderr
        # Restore the fixture identity before testing explicit operator fallback.
        passwd.write_text("aella:x:1000:27::/home/aella:/bin/bash\n")
        manual = run("--target", str(target))
        assert manual.returncode == 0 and "AELLA_SHELL_RESTORE=PASS" in manual.stdout
        print("PASS shell restore status, restore, idempotence, identity drift, override")


if __name__ == "__main__":
    check_static()
    check_skew()
    check_restore()
    print("PHASE2_SHELL_RECOVERY_SKEW=PASS")
