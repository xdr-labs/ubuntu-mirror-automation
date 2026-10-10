# Developer server — temporary Git checkout garbage collection

The shared dev-drlink server has accumulated large disposable checkouts in /tmp.
Only **explicitly enrolled, standalone Git clones** may be deleted automatically.
Pre-existing unregistered directories (including /tmp/drlink-stage2-d695)
will not be deleted or automatically enrolled.

## Install (aella user, without sudo)

```bash
cd /home/aella/ubuntu-mirror-automation
bash scripts/install-tmp-checkout-gc.sh --install
crontab -l
```

The installer deploys the script to
`~/.local/lib/ubuntu-mirror-automation/tmp-checkout-gc.py` and a convenient
`~/.local/bin/um-tmp-checkout` shortcut.

One user-cron job runs at **18:15 UTC (03:15 KST) daily**. Existing crontab
entries are preserved. Previous crontab content is backed up under:
`~/.local/state/ubuntu-mirror-automation/tmp-checkout-gc/`

No root service, DP, mirror, or existing repository checkout is changed.

## Use

```bash
GC="$HOME/.local/lib/ubuntu-mirror-automation/tmp-checkout-gc.py"
python3 "$GC" create --source /home/aella/ubuntu-mirror-automation
python3 "$GC" register /tmp/explicitly-disposable-standalone-clone
python3 "$GC" status
python3 "$GC" prune          # preview, always non-destructive
python3 "$GC" unregister /tmp/explicitly-disposable-standalone-clone
```

The `create` command creates a self-contained local Git clone below
`/tmp/um-tmp-checkout-*` and registers it. A pre-existing checkout
needs manual `register` approval; age by itself never enables deletion.

Scheduled `prune --apply` only removes registered checkouts if they are at
least **7 days old since enrollment**, no tracked/untracked/ignored files have
changed, and all files have been inactive for at least **24 hours**.

## Refusal conditions

The program preserves repositories when any of these apply:

- unregistered, missing, renamed, symlinked, out-of-scope, or replaced checkout
- linked Git worktrees, nested repositories, mounts, or mismatching ownership
- dirty, untracked, ignored files, stashes, or pending Git operations
- unpublished commits (including branch tips or reflog), missing remote,
  head changes after enrollment, or unexpected repository shape
- live process references via command line, working directory, or open FDs
- file modifications during the quiet period, or incomplete process visibility

An old non-dumpable user process whose command line can be inspected and
predates registration does not indefinitely block unrelated cleanup. Any
newly-started process with unreadable process state remains a blocker.
Deletion revalidates safety a second time and uses a process lock. The method
is not a guarantee against all possible concurrent external races: only
deliberately disposable checkout copies should be registered.

**Never** run indiscriminate /tmp cleanup or Git worktree prune.

## Disable without deleting anything

```bash
bash scripts/install-tmp-checkout-gc.sh --disable
crontab -l
```

This only removes the managed cron block. Registrations and checkouts remain.
Logs appear in
`~/.local/state/ubuntu-mirror-automation/tmp-checkout-gc/cron.log`.
Re-run `--install` after source code updates to refresh the installed copy.
