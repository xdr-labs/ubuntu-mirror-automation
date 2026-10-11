# Post-merge A1–A14 regression audit — 2026-10-11

## Scope and authorization

- Repository: `xdr-labs/ubuntu-mirror-automation`, dev host `dev-drlink`.
- Merged baseline: `main` `601d4a27416c530810cc7e966d45aa3ab76f58d2`, parent baseline `e8dc424ee19490ce9a843f973230bc3483f602d9`.
- Diff: 40 changed files, 1,551 insertions and 134 deletions (A1–A14, Phase 1 four hops, Phase 2, Mirror Manager, metadata/signing, test registration).
- Work carried out on separate `fix/postmerge-hostpin-curl-source-20261011` worktree. Dirty unrelated `full-code-regression-20261011` worktree preserved.
- Read-only/hermetic fixtures only. No live DP upgrade, vendor bringup, production Mirror publication, snapshot deletion, PR merge, or release decision.

## Confirmed issues

| Finding | Location / concrete RED | Minimal correction / GREEN |
|---|---|---|
| P2 / A14 follow-on: unrelated valid URL hid unknown curl executable origin | `scripts/lib/client_mirror_gates.sh`: `echo http://192.0.2.10/client/expected.sh; curl -o x.sh "$UNVERIFIED_URL"; bash x.sh --mirror-base http://192.0.2.10` returned `RUNTIME_COMMAND_GATE=PASS`. Added test failed before correction. | Validate **each** curl source independently with `scripts/lib/client_curl_source_guard.py` (read-only shell token analysis, literal pinned URL or previously visible static URL assignment only; fail-closed unknowns/config-file sources). `tests/test_postmerge_hostpin_curl_source.sh` includes unknown vars, second curl, curl --url, foreign host, suffix-host injection and positive direct/variable/braced/Menu7 cases. |
| P1: zombie falsely reported as live process | `tests/test_xenial_bionic_upgrader_env_order.py::_pids_gone` checked only `/proc/<pid>` existence. Original parent-loss test **passed twice** on native dev host, hence Codex's container-only specific failure was not reproduced there. A separate deterministic orphaned/unreaped Linux child with real `/proc/PID/stat` state Z caused a **RED** false live-process verdict. | Change only **test** helper to distinguish a live process from Z/X state, retaining fail-closed read-error behavior. New live-process negative control remains detected. Focused four tests GREEN. No DP runtime upgrade logic changed. |
| A15: signed-client embedded URL/manifest false-PASS | `scripts/lib/client_mirror_gates.sh::client_assert_mirror_base_match`: valid `Release-File` plus foreign-host `UpgradeTool` still passed on baseline. Unpinned `sample_deb_url` and conflicting duplicate `mirror_base` keys could also evade substring check. New test initially RED. | `scripts/lib/client_pin_payload_guard.py` reads decoded metadata and JSON (rejects unpinned URL sources, ambiguous duplicate JSON keys and off-host download fields). Four positive/negative embedded-origin tests GREEN. Existing Host-Pin 18 cases, long payload and manifest signing cases remain passing. |

New source helpers are part of the client-build provenance input closure and Mirror Manager prerequisite inventory. Both synthetic private-key-scan fixtures were updated to include the new required files; their clean and fail-closed cases pass.

## A1–A14 integration audit coverage

| Boundary | Inspection / affected deterministic evidence |
|---|---|
| Phase 1 / four LTS hops | Inspected `client/dp-offline-upgrade-*.sh[.in]` change sites, newline-complete progress-logger byte offsets, Python 3.5 sitecustomize entry ordering and shared dpkg package-transition/hold/NTP paths. Changed Bash variants: syntax PASS. `tests.test_offline_progress_log_lines`, `tests.test_xenial_bionic_upgrader_env_order`, OS hold/NTP/inventory and orphan-log suites exercised. |
| Phase 2 | `dp-phase2-cluster-validation.sh` readiness and EOF status, time-readiness SIGPIPE and generated helper trust: focused tests PASS; `test_phase2_validate_cluster_eof_closure.sh` 43/43 PASS. |
| Signed clients / Mirror Manager | Host-Pin literal and origin checks, encoded metadata/manifest, Menu7 cached open, provenance, private key pre-publish guards and atomic helper generation exercised. No production signing/publishing. |
| Install/migration / recovery | `migrate-apt-mirror-to-root.sh` clean/dirty/error guard, OS artifacts secret scans, repo private tree probes and orphan evidence tested. Existing logic preserved if no new RED reproduction. |
| CI / gate | Original merged candidate 41/41 is **historical only**. Post-merge change adds two permanent PR-gate steps; record exact-HEAD gate and CI in linked PR evidence, not as assumed PASS. |

### Static and verification

- Inspected all 40 changed-file paths and production hunks of the prior integration; new findings listed above are the reproducible actionable additions, not evidence that every theoretical scenario is excluded.
- `bash -n` all 38 changed and new applicable shell sources: PASS. New/changed Python `py_compile`: PASS; `git diff --check`: PASS.
- Targeted PASS: Host Pin 18/18; both added Host-Pin suites; large metadata; Menu7 cached open; signing/manifest signing; client-build provenance; Phase 2 generation trust and cluster status; OS orphan, NTP, holds, Python inventory, dirty-git migration; private-key guards (clean fixture and large private tree rejection).
- Two existing private-scan fixtures initially returned false FAIL due to new mandatory helper source files not being represented in artificial project trees. These test fixtures were corrected without weakening the production file prerequisite guard.

### Qualification not performed

Approved-lab Surface Reconciliation, owner-run destructive Full User E2E, 16.04/Python 3.5 live release-upgrade runtime validation, public smoke, field/customer acceptability and release authority are **NOT RUN**. The owner will run actual DP E2E after source review. PR must remain unmerged.
