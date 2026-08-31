# Phase 2 source-version and bringup lifecycle

Phase 2 must know the DP product version that existed before the OS transition.
It must also distinguish a still-running post-upgrade bringup from a completed
one.  Neither decision may be inferred from a generic log phrase or an
unvalidated fallback value.

## Source product version

### Root causes

* Phase 1 historically detected a version transiently from `aella_cli`; later
  hops could no longer query the old product reliably.
* A later failed or `UNDETERMINED` detection could obscure an earlier good
  result.
* Plain environment files and release-image metadata can be incomplete,
  conflicting, or malformed.
* Recovery logic that treats partial log records, test fixtures, or operator
  input as equivalent to authoritative evidence can select the wrong bundle.

### Fixes and invariants

`client/lib/dp-offline-source-product-version.sh` records a successful Phase 1
capture in `source-product.env` with an atomic rename and mode `0600`.  It
parses an allowlisted `KEY=VALUE` schema rather than sourcing the file.  A
valid `PASS` record is immutable: the same normalized version is reused, while
a different version fails closed.  Empty, malformed, fake, `UNKNOWN`, and
`UNDETERMINED` values are never persisted as a pass.

# Resolution order depends on Phase 2 entry mode:

### POST_PHASE1_NOBLE

DP reached Ubuntu 24.04 through this project's Phase 1 OS upgrade
(`COMPLETED_NOBLE`). Product runtime may be intentionally unavailable.

1. valid `source-product.env`;
2. complete Phase 1 structured records, only while the OS state is
   `COMPLETED_NOBLE` and bringup is not complete;
3. consistent authoritative release-image keys;
4. a validated operator override.

Live `aella_cli` is **not** consulted on this path.

### NATIVE_NOBLE

DP was created/already running as Ubuntu 24.04. Phase 1 evidence is naturally
absent and must not be required.

1. valid `source-product.env` (if live `aella_cli` also succeeds and differs →
   fail closed);
2. strict live `aella_cli` product version (origin `aella_cli-native-noble`),
   persisted atomically for retries;
3. consistent authoritative release-image keys;
4. a validated operator override.

A Phase 1 record votes only when it includes `DP_VERSION`,
`DP_VERSION_SOURCE`, `DP_VERSION_DETECT_STATUS=ok`, and
`DP_VERSION_CONSISTENCY=PASS`.  Several matching records may corroborate a
version; multiple versions fail closed.  A later `UNDETERMINED` record does
not erase prior complete PASS evidence.  Diagnostic calls use `allow_write=0`
and report a would-be recovery without creating evidence.

The source helper accepts explicit test/deployment path overrides:
`SOURCE_PRODUCT_ENV_DEFAULT_PATH`, `SOURCE_PRODUCT_PHASE1_LOG_DEFAULT`,
`SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT`,
`SOURCE_PRODUCT_EVIDENCE_ROOT_DEFAULT`, `SOURCE_PRODUCT_OS_STATE_FILE`,
`SOURCE_PRODUCT_BRINGUP_RESULT_ENV`, and `SOURCE_PRODUCT_OS_RELEASE_FILE`.
Production defaults remain under `/opt/aelladata` and `/var/log/aella`.

Operator wrapper `upgrade-phase2.sh` allowlists only `--source-dp-version`;
`--target-version`, `--mirror-url`, and unknown options are rejected. Normal
Native Noble operation does not require the override.

## Progress and staging

Long downloads and staging operations emit explicit `OPERATION_START`,
periodic `OPERATION_PROGRESS`, and `OPERATION_END` records.  Child exit codes
are preserved and heartbeat workers are stopped before returning.  Download
progress uses on-disk bytes and reports `UNKNOWN` when a total is unavailable;
it never invents a content length.  URLs are redacted before display.

Source version resolution is performed before a bundle download or artifact
mutation.  `--diagnose-source-version` is therefore a safe, read-only failure
path for an unresolved source version.

## Bringup lifecycle

### Root causes

* Instructional text such as “Bringup complete:” (including localized
  instructions) can appear before work has completed.
* A detached worker can disappear, its PID can be reused, or a diagnostic
  `pgrep` process can match itself.
* A terminal marker retained from an older attempt must not complete a newer
  attempt.
* `aella_cli` is not expected to exist while image import and bringup are
  still running.

### Fixes and invariants

`client/bringup_py3_dp_lifecycle.sh` and
`client/lib/dp-phase2-bringup-lifecycle.sh` create a lifecycle directory with
a run id, worker identity, state, result, and completion sentinel.  The worker
writes an authoritative completion sentinel only after the vendor script exits
zero.  Status treats a result as terminal only when its `BRINGUP_RUN_ID`
matches the current run id.  PID identity requires a matching command token
and, when available, matching process start ticks; stale and self-matching
diagnostic processes become `STALE_OR_UNKNOWN`.

While running, the status shows import progress and intentionally reports
`AELLA_CLI_AVAILABLE=NOT_CHECKED`.  After a current-run successful sentinel,
the monitor checks for `aella_cli`; absence then becomes
`FAIL_POSTCONDITION`.  `--status` and `--diagnose` only inspect files and logs
and do not alter lifecycle state.

## Publication and regression coverage

The runtime manifest, client rebuild publisher, and phase-2 helper publisher
ship the lifecycle wrapper and all three Phase 2 libraries with checksums.
Targeted regression scripts are:

* `tests/test_source_product_version.sh`
* `tests/test_native_noble_source_resolution.sh`
* `tests/test_phase2_wrapper_source_override.sh`
* `tests/test_config_clear_and_scoped_invalidation.sh`
* `tests/test_bringup_lifecycle.sh`
* `tests/test_phase2_staging_progress.sh`
* `tests/test_bringup_lifecycle.sh`

# Phase 2 source version and bringup lifecycle architecture

## Mirror environments

| Constant | Value | Notes |
|----------|-------|-------|
| DEVELOPMENT_MIRROR_URL | `http://221.139.249.111` | Cursor development mirror — **not deprecated** |
| STELLAR_TEST_MIRROR_URL | `http://221.139.249.112` | Current Stellar field-test mirror |

Reusable product source must not hardcode either IP. Environments sign and
publish independent client generations. Never reuse a `.111` signed Menu 7
command on `.112`.

## Root causes (production observations)

### Source version defect

Phase 1 (especially Xenial→Bionic) successfully detected `DP_VERSION=6.5.0` with
`DP_VERSION_DETECT_STATUS=ok` and `DP_VERSION_CONSISTENCY=PASS`, and logged that
evidence. The result was not reliably persisted as an authoritative immutable
input for Phase 2 (`source-product.env`).

Later OS hops may no longer have `aella_cli`. A later log line
`DP_VERSION=UNDETERMINED` must not erase earlier complete PASS evidence.

`stage-dp-phase2.sh` previously checked only:

1. `source-product.env`
2. `release-image.yml`
3. `--source-dp-version`

It did not recover from structured Phase 1 logs. Generic
`SOURCE_DP_VERSION_CHECK=FAIL_UNKNOWN` concealed which evidence source failed.

### Staging visibility defect

Long staging operations (bundle curl, SHA256, tar list, extraction, copy/chown)
ran with silent curl and no heartbeats, so operators could not distinguish a
live transfer from a hang.

### Bringup lifecycle defect

The vendor bringup wrapper correctly detached for SSH survival, but:

- the interactive wrapper returned immediately with no default foreground monitor
- future `aella_cli` / resume instructions were printed before bringup completion
- there was no authoritative lifecycle state binding PID, run ID, completion, and exit code
- loose `grep 'Bringup complete:'` matched instructional English/Korean text
- `pgrep`-style diagnosis could match the diagnostic command itself
- absence of `aella_cli` during image import was easy to misclassify as failure

### False completion marker match

Instructional lines such as “Completes when the log shows: Bringup complete:”
and Korean text containing `Bringup complete:` are **not** completion events.
Completion requires a machine-readable sentinel bound to the current run ID.

## Fixes

### Authoritative source DP version capture

Shared helper: `client/lib/dp-offline-source-product-version.sh`

- Schema version 1 `source-product.env` with atomic root-only write (mode 0600)
- Never persists UNKNOWN/UNDETERMINED
- Never overwrites a prior PASS with a conflicting version
- Same version is idempotently reused
- Xenial-compatible Bash (no python required for capture)

OS-hop clients inject the shared helper via `@@SOURCE_PRODUCT_HELPER@@` and call
`spv_persist_source_product_env` from `log_product_state_phase1` after a complete
PASS detection, before destructive package mutation. Later hops preserve an
existing PASS capture (idempotent same-version reuse; conflicting versions fail
closed without overwrite).

### Historical recovery priority

1. valid `source-product.env`
2. Phase 1 structured log evidence (COMPLETED_NOBLE, bringup not completed)
3. authoritative `release-image.yml` keys
4. `--source-dp-version`
5. fail closed with source-specific diagnostics (never user-facing `FAIL_UNKNOWN`)

Later `UNDETERMINED` records do not erase earlier complete PASS evidence.
Conflicting complete PASS versions fail closed.

### Staging progress

Shared framework: `client/lib/dp-phase2-operation-progress.sh`

- `OPERATION_START` / `OPERATION_PROGRESS` / `OPERATION_END`
- Default heartbeat 30s (`DP_PHASE2_HEARTBEAT_SECONDS` for tests)
- Download byte progress without fabricating Content-Length
- Exact child exit status preserved; no orphan heartbeats

Source resolution always runs before bundle download or artifact mutation.

### Bringup lifecycle

- Wrapper: `client/bringup_py3_dp_lifecycle.sh` (installed as
  `/home/aella/bringup_py3_dp_after_os_upgrade.sh`)
- Vendor script retained as `bringup_py3_dp_after_os_upgrade.vendor.sh`
- Lifecycle dir: `/opt/aelladata/os-upgrade/offline/phase2-bringup/` (0700/0600)
- Default: detach worker + attach foreground read-only monitor
- `--detach` returns after verified handoff
- Ctrl+C stops monitor only; worker continues
- Completion via run-bound sentinel file — not unanchored log grep
- `aella_cli` checked only after verified completion
- Missing CLI after completion → `FAIL_POSTCONDITION`
- `--status` / `--diagnose` are read-only
- Duplicate bringup while RUNNING attaches to existing worker

## Operator notes

- Original source DP version is intended to be captured at the first OS hop;
  later absence of `aella_cli` during Phase 1 OS-only hops is expected.
- Phase 2 recovers historical source evidence safely when needed.
- Staging prints progress about every 30 seconds.
- Bringup survives SSH disconnect; default monitor is foreground read-only.
- Instructional `Bringup complete:` text is not completion evidence.
- Do not run `aella_cli` until `BRINGUP_RESULT=PASS`.
- `resume` remains manual and conditional after `show status`.
