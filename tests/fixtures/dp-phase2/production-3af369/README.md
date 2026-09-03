# Production ACPS bringup fixture: 3af369

Exact ACPS `bringup_py3_dp_after_os_upgrade.sh` used in the DP 6.6.0 dark-site
validation.

SHA1:

    0695bd17c6a3e9fca910526779e7b595f79b188c

This is an immutable upstream copy. Production still downloads the current
ACPS file; this fixture exists so the deterministic patcher can be regression
tested against that known generation. The SHA is not a forever pin: a newer
ACPS generation must be analyzed the same way and supported only if proven
safe. Repository-controlled approval uses SHA256 in
`vendor/dp-phase2/approved-upstream-bringup.sha256`.
