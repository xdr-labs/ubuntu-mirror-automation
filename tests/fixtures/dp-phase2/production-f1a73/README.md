# SANITIZED COMPATIBILITY FIXTURE: production-f1a73

**SANITIZED COMPATIBILITY FIXTURE** — not byte-exact ACPS upstream.

This tree holds an environment-IP / credential-scrubbed derivative of the
reviewed ACPS `bringup_py3_dp_after_os_upgrade.sh` generation whose historical
SHA1 was:

    f1a73c1d4502e2efcf55197865d2ade345d9c82f

Current on-disk fixture SHA1 (sanitized bytes):

    f57ea3964582322e0dc401fa8dd731c7443622fd

Use this file for deterministic **patch compatibility** regression only.
Its SHA256 is **NOT** a production provenance pin and must not appear in
`vendor/dp-phase2/approved-upstream-bringup.sha256`.

Production approval digests are SHA256 of the real reviewed ACPS upstream
bytes (see that allowlist). Unknown ACPS generations fail closed until an
engineer intentionally adds their SHA256 after review.
