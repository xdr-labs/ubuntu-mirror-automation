# SANITIZED COMPATIBILITY FIXTURE: production-3af369

**SANITIZED COMPATIBILITY FIXTURE** — not byte-exact ACPS upstream.

This tree holds an environment-IP / credential-scrubbed derivative of the
reviewed ACPS `bringup_py3_dp_after_os_upgrade.sh` generation whose historical
SHA1 was:

    3af369660c3e0dfb0b7421ab455dee1ced365b1d

Current on-disk fixture SHA1 (sanitized bytes):

    0695bd17c6a3e9fca910526779e7b595f79b188c

Use this file for deterministic **patch compatibility** regression only.
Its SHA256 is **NOT** a production provenance pin and must not appear in
`vendor/dp-phase2/approved-upstream-bringup.sha256`.

Production approval digests are SHA256 of the real reviewed ACPS upstream
bytes (see that allowlist). Unknown ACPS generations fail closed until an
engineer intentionally adds their SHA256 after review.
