# DP OS Upgrade — combined-PR full-code regression audit (2026-10-11)

## Scope, boundary, and baseline

- Repository: `xdr-labs/ubuntu-mirror-automation`; development host: `dev-drlink`.
- Source baseline: unmerged **PR #112** (`9079069`) and **PR #114** (`208adf9`), combined **only** in isolated audit worktree at `ff1543f11e65edc788a418169161704feb69199e`; base main `e8dc424`.
- Audit branch: `audit/full-code-regression-20261011`; existing worktrees and both PR branches preserved.
- **No actual DP upgrade, host package modification, production deployment/publication, or PR merge.** All runtime scenarios below are hermetic fixtures.
- Repo-wide tracked inventory: 1,780 files; 435 relevant Bash/Python files (172 outside `tests/`, 263 within), comprising 331 Bash/shell syntactic validations and 104 Python AST checks — **zero syntax failures**.
- ShellCheck `-S error`: 330 Bash targets, 305 PASS, 19 oversized scripts/test scripts exceeding 20-second per-file budget (inconclusive, not failures), and 6 fixture/test-only errors; no additional confirmed small production-source ShellCheck errors. ShellCheck timeouts and test-only errors are **not** counted as PASS.

### Coverage map

| Area | Scanned/validated |
| --- | --- |
| Phase 1 hop 1 | Xenial 16.04 → Bionic 18.04; Python early init, state, generated scripts |
| Phase 1 hop 2 | Bionic 18.04 → Focal 20.04; shared reconciliation, generated scripts |
| Phase 1 hop 3 | Focal 20.04 → Jammy 22.04; dpkg/APT evidence, progress logs |
| Phase 1 hop 4 | Jammy 22.04 → Noble 24.04; shared reconciliation, generated scripts |
| Phase 2 | staging, bringup, cluster CLI, NTP/status, helper generation/hash |
| Mirror Manager | configuration, state, locking, HTTP publication, signed-client generation |
| Install and deployment | offline install, atomic swap, private-key guard, runtime closure |
| Integrity and operations | SHA256, manifest, retries/timeouts, log writers, validation/status |
| Bash/Python inventory | all tracked 435 candidates; syntax/AST and high-risk pattern triage |

## Confirmed regression findings and changes

| Finding | Reproduction / consequence | Minimal remedy | Result |
| --- | --- | --- | --- |
| A1 — package-transition evidence under `pipefail` | Long post-baseline dpkg log with early `startup archives unpack` incorrectly classified `NONE`. Current-run transition/rollback gates can be misclassified. | Make evidence searches consume here-strings rather than `printf | grep -q` in the shared reconciliation helper. | **RED → GREEN**: `test_xenial_package_transition_evidence.sh` |
| A2 — Phase 2 NTP status false negative | Long ntpq/timedatectl output with an early valid sync field returned status 141 (SIGPIPE). | Consume NTP output by here-string, preserving `leap=00` and `synchronized: yes` checks. | **RED → GREEN**: `test_phase2_ntp_pipefail_large_output.sh` |
| A3 — preflight internal JSON fallback | Large valid collector summary could fail the `schema_version` detection pipeline. | Replace early-close pipelines with here-strings and bounded `grep -m1`. | **RED → GREEN**: `test_dp_preflight_internal_json_pipefail.sh` |
| A4 — signed-client mirror pin check | Early correct host pins in long meta-release/manifest/command text were incorrectly rejected. | Eliminate producer-side SIGPIPE on in-memory text matching. | **RED → GREEN**: `test_client_mirror_pin_large_payload.sh` |
| A5 — HTTP private signing key scan | `find | grep -q` intermittently reported no private key when hundreds of matching filenames existed. A private key could pass one pre-publication guard. | `find ... -print -quit` with explicit fail-closed scan-error handling. | **RED → GREEN**: `test_per_mirror_local_signing.sh`; keyring compatibility PASS |
| A6 — Mirror Manager repository key guard | Same early-close `find | grep -q` on `client/` and `config/` could miss filenames and incorrectly mark client-build prerequisites ready. | `find ... -print -quit` plus fail-closed scan error. | Full + Phase 2 only fixture tests GREEN, 650 / 4,000 dummy file trees |
| A7 — Phase 1 evidence export secret path scan | `find | grep -q` returned false-negative in 12/12 trials on 650 dummy `password` paths (isolated old-code pipeline). | Deterministic `find ... -print -quit` plus fail-closed behavior. | Secret-bearing fixture rejected 12/12; clean fixture export PASS |

The findings concern **this repository only**, not upstream Ubuntu or Stellar Cyber product defects. The dummy secret fixtures contain no credentials.

## Tests and verification

- Combined PR gate (before final addition of two independently GREEN registration entries): `PR_GATE_SCHEDULED=33`, `RAN=33`, `PASSED=33`, `FAILED=0`, `SKIPPED=0`, `RESULT=PASS`, duration 269 seconds.
- New targeted standalone tests: Mirror Manager FULL prerequisite secret detection PASS 12/12; Phase 2-only prerequisite secret detection PASS 12/12; OS evidence export secret detection PASS 12/12 and clean export PASS.
- Existing PR #112 tests: Python/four-hop logging `Ran 20 tests`, `OK (skipped=1)`; merged PR gate subset separately PASS.
- Existing PR #114 tests: Phase 2 cluster status EOF/SIGPIPE `43/43 PASS`; helper-generation trust PASS on baseline; post-edit phase2 helper file SHA256 matched its updated generation manifest.
- Additional independent hermetic matrix: `9 PASS / 0 FAIL`, covering install lock handoff, legacy UOM lock handoff, publication mutation locks, concurrent state writers, Phase 2 atomic helper publish, client atomic deploy, runtime manifest closure, staging/bringup gate, and `sync_by_hash`.
- `git diff --check` and changed Bash `bash -n`: PASS. Shared hop reconciliation metadata generation test PASS.

### Follow-on limitations / no overclaim

1. No real 16.04 Python 3.5 VM execution, hardware/cluster OS-upgrade E2E, live network fetch, customer bringup, or production service activity (explicitly excluded by request).
2. Check-in client artifacts may represent previously signed generations; no production client package was regenerated, signed, deployed, or published. Never treat a source-vs-signed-artifact SHA difference alone as a regression without matching generation evidence.
3. ShellCheck inconclusive timeout group and test/fixture-only warnings require separate, bounded follow-up if stricter lint compliance is required.
4. Passing hermetic tests does not prove all possible field scenarios are defect-free; it verifies the listed failure classes and exact demonstrated triggers.
5. The audit combined two draft PRs for analysis only. Do not merge/publish without separate release gates and owner acceptance.

## Evidence locations (development host, not a production artifact)

`/home/aella/dp-os-upgrade-evidence/20261011/full-code-regression/`:

- `inventory.txt`, `syntax_issues.txt`, `risk_candidates.txt`, `shellcheck_errors.txt`
- `red-package-transition-sigpipe.log`, `red-phase2-ntp-sigpipe.log`, `red-preflight-json-original.log`, `red-mirror-pin-original.log`, `red-artifact-secret-scan-sigpipe.log`
- `green-package-transition-sigpipe.log`, `green-os-artifact-secret-scan.log`, `green-mirror-prereq-secret-tree.log`, `green-mirror-phase2-private-tree.log`
- `pr-gate-combined-audit.log`, `matrix-*.log`

The audit branch and this document are **not a release authorization**.
