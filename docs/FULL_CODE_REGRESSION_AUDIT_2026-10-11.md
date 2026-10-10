# DP OS Upgrade — combined-PR full-code regression audit (2026-10-11)

> **Historical baseline:** Sections through “Evidence locations” below are the preserved report from branch `audit/full-code-regression-20261011`, commit `88b8203`. The follow-up section at the end records the separate PR #115 review candidate and updated verification.

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


---

## PR #115 continuation: independent audit, comparison, and review

**Branch:** `audit/full-code-regression-isolated-20261011` (Draft PR #115).
**Baseline:** common merge `ff1543f` of unmerged PR #112 (`9079069`) and PR #114 (`208adf9`) on main `e8dc424`. Both remain Draft.
**Pre-review source HEAD:** `b112332af6b2d5d5ce7761645a8e62beb788edbf`. A documentation-and-test-only follow-up may change this HEAD; the GitHub PR and CI provide the canonical latest SHA.

### Scope and results beyond the original A1–A7

| Finding | File/safety boundary | RED evidence | GREEN regression |
| --- | --- | --- | --- |
| A8: orphan state hidden | `scripts/lib/dp-os-upgrade-common.sh` — many current `*.log` files misclassified as no orphan evidence | `os-orphan-red.log` | `tests/test_os_orphan_log_scan_pipefail.sh` |
| A9: Python evidence falsely absent | Same file — recorded Python inventory files misreported `false` | `os-python-report-red.log` | `tests/test_os_python_inventory_report_pipefail.sh` |
| A10: NTP false-positive/negative | Same file — long `no association ID` hidden; long valid chronyc/timedatectl readiness lost | `phase1-ntp-large-red.log` | `tests/test_os_ntp_large_output_pipefail.sh` (positive and negative) |
| A11: migration dirty Git false-clean | `scripts/migrate-apt-mirror-to-root.sh` — many uncommitted paths, or Git status error, wrongly classified clean | `migrate-git-guard-red.log` | `tests/test_migrate_git_guard_pipefail.sh` |
| A12: critical package holds missed | `scripts/lib/dp-os-upgrade-common.sh` — 25,000 fake hold entries hide `systemd`, `udev`, `dpkg` | `critical-held-packages-tracked-red.log` | `tests/test_os_critical_holds_pipefail.sh` |

**Comparison with the initial parallel audit:** production A1–A7 fixes were present in both audit branches; PR #115 adds the A8–A12 source changes. The original audit's `test_mirror_prereq_private_scan_pipefail.sh` was accidentally left off PR #115 while a different Phase 2-only prerequisite check remained. Review restored this original **FULL mode** test (650 dummy key filenames ×12) alongside the existing **PHASE2_ONLY** fixture (4,000 dummy filenames ×12), preserving distinct mode coverage.

### Prior exact-head verification at b112332 (before report/test-only review patch)

- Repository inventory: **1,787 tracked files, 445 Bash/Python** (341 Bash parse checks, 104 Python AST, no syntax failures).
- `bash tests/run_pr_gate.sh`: 39 scheduled / 39 passed / 0 failed / 0 skipped, 272 seconds. Includes signed-client generation fixture, 4-hop shared reconciliation and Phase 2 trust.
- Both GitHub Engineering System and fast-pr-gate CI completed SUCCESS at that SHA.
- Full test list: all 190 references existed before restoring Full Mode fixture; 21 direct native Gate test-file references existed.
- Mirror disk migration hermetic fixture: 63 PASS / 0 FAIL. Additional lock/state/manifest/atomic/staging targeted matrix: 8/8 PASS.
- Full-source ShellCheck was **not** fully conclusive: 19 large-script timeouts, 8 pre-existing vendor/test diagnostics under per-file bounds (separate lint qualification backlog, not runtime RED defects).

### Remaining qualification and safety boundary

- The full **User E2E**, actual Xenial Python 3.5 runtime and field DP cluster exercise are not covered by this offline audit and must not be marked PASS based on unit/CI results alone.
- This is an **audit candidate**, not an authorization to merge #112/#114/#115, rebuild the signed production client generation, publish the mirror, or upgrade an actual DP.
- Exact-HEAD native Gate/CI outcomes for the final review patch belong in the PR #115 discussion; evidence files are retained under `/home/aella/dp-os-upgrade-evidence/20261011/full-code-regression/` on `dev-drlink`.


---

## A13 — literal Mirror Host-Pin comparison (2026-10-11 continuation)

**Finding / exact source:** `scripts/lib/client_mirror_gates.sh`, in
`client_assert_mirror_base_match` and `client_assert_command_mirror_base`.
The `PIN_SAMPLE_DEB_URL`, `--mirror-base`, and `--mirror-url` checks inserted
a supposedly exact Mirror URL into an extended regular expression. For example,
expected `http://192.0.2.10` could incorrectly accept the different hostname
`http://192-0-2-10` because `.` was interpreted as a wildcard. An operator
command containing a correct first `--mirror-base` or `--mirror-url` followed
by a wrong duplicate option was also incorrectly reported `PASS`.

**Classification:** HIGH integrity risk in a repository-owned optional
host-pin validation helper. This is a verified validation weakness, **not**
evidence that an attacker published a signed client, exploited a DP, or bypassed
the separate production signing/generation gates.

**Original RED:** `tests/test_client_mirror_pin_gates.sh` extended with five
negative hermetic cases: one wrong `PIN_SAMPLE_DEB_URL`, one wrong hop
`--mirror-base`, one wrong Phase 2 `--mirror-url`, and both kinds of
conflicting duplicated flag. All five were falsely accepted by the original
source. Evidence: `20261011-host-pin-regex-red.log`.

**Minimal fix:** compare the exact extracted sample URL as a literal prefix.
For command flags, extract every explicit option token, compare every parsed
value against the literal expected URL, and reject malformed/conflicting
values; do not interpolate untrusted URLs into regular expressions.
No real network connection, signing, deployment, or OS upgrade is performed
by these regression tests.

**GREEN / compatibility:** the five incorrect cases are rejected, while
the existing correct-host and large-metadata cases remain accepted.
`tests/test_client_mirror_pin_gates.sh` is registered as a permanent
project-native PR Gate step. RED/GREEN logs live under
`/home/aella/dp-os-upgrade-evidence/20261011/full-code-regression/`
on `dev-drlink`.

**Remaining owner/release boundaries:** No actual DP OS upgrade or vendor
bringup, no production mirror publishing, and no PR merge. Surface
Reconciliation, Full User E2E, public smoke and owner release acceptance
are separate gates requiring an approved disposable lab.
