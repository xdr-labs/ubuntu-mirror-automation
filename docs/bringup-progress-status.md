# Phase 2 bringup progress and completion

The read-only monitor prints one `BRINGUP_PROGRESS` heartbeat per configured
interval. Repeated guidance is printed only when the observed phase, target,
process state, log activity or image progress changes. Existing fields remain;
additional fields explain the operation:

- `worker_scope=LIFECYCLE_PROCESS` identifies the meaning of legacy `worker=`.
  It is the local lifecycle process, not a DP Worker readiness assertion.
- `target=LOCAL` or a worker IP identifies the source of the observed vendor phase.
- `phase_observed_seconds` measures time since this monitor first observed the
  current phase/target, not the authoritative start time of the vendor operation.
- `log_activity=QUIET` means the monitored log has not changed for at least 300
  seconds. It does not prove a hung process and never terminates bringup.
- `child_processes` lists up to six observed descendant command names. Arguments
  and credentials are never printed. `UNKNOWN` is not a process failure.
- `dp_worker_readiness=NOT_CHECKED` prevents confusing process liveness with
  remote node health.

`IMAGE_IMPORT_RESULT` reports the latest observed outcome per target and
namespace. Only an explicit completion or zero exit code is displayed as PASS.
A failed import retains its error code. Percentages are not synthesized to 100%.
Missing current-run markers or rotated/truncated logs do not reuse old progress.

After bringup, use the public wrapper's `--status` and `--validate-cluster`.
`CLUSTER_RUNTIME_READINESS=READY` describes the collected native status.
`CLUSTER_VALIDATION` describes an operator confirmation bound to the current
run and target. A healthy observation does not write a confirmation receipt.
Existing confirmations are reflected instead of being overwritten in output
with hardcoded PENDING. A paused, failed or incomplete live status cannot display
upgrade completion on the validation surface.

`DP_UPGRADE_COMPLETE=YES` still requires coherent current-run bringup success,
current-run cluster confirmation, and migration PASS or NOT_REQUIRED. Resume,
migration execution and confirmation remain explicit operator actions. No
vendor script, sealed bundle, package-installation order or NTP policy changes
are part of this display correction.
