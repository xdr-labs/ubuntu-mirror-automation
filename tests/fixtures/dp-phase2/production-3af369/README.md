# Production ACPS bringup fixture: 3af369

Exact ACPS `bringup_py3_dp_after_os_upgrade.sh` used in the DP 6.6.0 dark-site
validation.

SHA1:

    3af369660c3e0dfb0b7421ab455dee1ced365b1d

This is an immutable upstream copy. Production still downloads the current
ACPS file; this fixture exists so the deterministic patcher can be regression
tested against that known generation. The SHA is not a forever pin: a newer
ACPS generation must be analyzed the same way and supported only if proven
safe.
