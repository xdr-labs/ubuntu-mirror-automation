# Collect DP Upgrade Readiness

## Purpose

`scripts/collect-dp-upgrade-readiness.sh` gathers **read-only evidence** from a Stellar Cyber DP host before Ubuntu LTS hops and DP 6.6.0 Py3 bringup.

It does **not**:

- upgrade the OS or DP
- install, remove, or upgrade packages
- change system configuration
- decide READY / BLOCKED (see `docs/dp-upgrade-preflight.md` / `scripts/dp-upgrade-preflight.sh`)

Use the resulting archive as input for later preflight and upgrade automation.

## Read-only guarantee

Allowed writes are limited to:

- the user-specified `--output-dir`
- a temporary directory under the result tree
- the final `.tar.gz`
- cleanup of the script’s own temporary files

The script must not run `apt-get`/`dpkg` mutating operations, `do-release-upgrade`, `systemctl start|stop|restart|enable|disable`, `mount`/`umount` changes, `chsh`/`usermod`, Docker lifecycle changes, or rewrite `/opt/aelladata` / upgrade state files.

## Supported OS

Minimum execution environment: **Ubuntu 16.04** (Bash 4.3+, stock coreutils/util-linux).

Optional tools (`curl`, `systemctl`, `docker`, `timedatectl`, `chronyc`, `ntpq`, `jq`, Python) are detected with `command -v` and skipped when absent. Missing tools do not abort the whole collection.

## Examples

```bash
# Recommended on a DP (keep unpacked tree + archive)
sudo ./scripts/collect-dp-upgrade-readiness.sh \
  --output-dir /var/tmp \
  --keep-directory

# No external DNS/HTTP probes
sudo ./scripts/collect-dp-upgrade-readiness.sh \
  --output-dir /var/tmp \
  --skip-network

# Deep metadata manifest for /opt/aelladata (metadata only; can be slow)
sudo ./scripts/collect-dp-upgrade-readiness.sh \
  --output-dir /var/tmp \
  --deep-manifest \
  --keep-directory
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--output-dir DIR` | `.` | Parent directory for results |
| `--skip-network` | off | Skip external DNS/HTTP checks |
| `--deep-manifest` | off | Full metadata TSV for `/opt/aelladata` |
| `--keep-directory` | off | Keep result directory after `.tar.gz` |
| `--network-timeout SECONDS` | `10` | Per network probe timeout |
| `--max-log-lines NUMBER` | `2000` | Max lines taken from each log |
| `--help` | | Usage |
| `--version` | | Script version |

## Output layout

Name pattern:

```text
dp-upgrade-readiness-<sanitized-hostname>-<UTC timestamp>
```

Example:

```text
/var/tmp/dp-upgrade-readiness-dp01-20260714T123000Z/
/var/tmp/dp-upgrade-readiness-dp01-20260714T123000Z.tar.gz
```

Important top-level files:

- `summary.json` — machine-readable evidence summary (no READY/BLOCKED verdict)
- `summary.txt` — human-readable summary
- `collection.log` — timestamped INFO/WARN/ERROR log
- `commands.tsv` — every check with return code / status / duration
- `findings.txt` — fact-based observations (not remediations)

Sections include `system/`, `storage/`, `apt/`, `network/`, `services/`, `dp/`, `upgrade/`, `data-preservation/`, `security/`.

If `SUDO_USER` is set, the script attempts to `chown` the archive (and kept directory) back to that user.

## What is collected

- OS / kernel / hostname / locale / CPU / memory
- `root` and `aella` shells and related account metadata
- Filesystem space/inodes for `/`, `/boot`, `/opt/aelladata`
- APT sources (redacted), holds, dpkg audit/status, locks
- Network interfaces/routes, resolvers, optional DNS/HTTP reachability to Ubuntu archives
- NTP / time sync evidence (`timedatectl` / `chronyc` / `ntpq` when present)
- systemd / process / listening ports; Docker inventory without env/secrets
- Multi-source DP version / role / cluster / worker IP evidence
- Existing OS-upgrade state and recent upgrade/apt logs (tailed)
- `aelladeb_py3` bringup bundle presence/summary
- `aelladeb` (legacy non-py3) bundle presence/summary when present
- `/opt/aelladata` preservation metadata (shallow by default)

## Sensitive data handling

Never intentionally collected:

- `/etc/shadow`, SSH/TLS private keys, cloud credentials, API tokens, DB passwords
- full container environments, secret files, cookies, authorization material, DB dumps

Redacted in place when found in otherwise-useful text:

- URL `user:password@`
- proxy credentials
- env/config style `PASSWORD` / `TOKEN` / `SECRET` / `KEY` / `AUTH` values
- `Authorization` headers

Hostnames and IP addresses are **not** redacted (needed for upgrade planning).

See `security/redaction-report.txt` for which files/pattern kinds were redacted (values are not logged).

## Root vs non-root

| | root | non-root |
|--|------|----------|
| Unprivileged facts | collected | collected |
| Privileged reads | direct | `sudo -n` only (no password prompt) |
| Permission failures | rare | logged; collection continues |
| Archive | always attempted | always attempted |

## Runtime expectations

Typical smoke / light host: on the order of **tens of seconds** with `--skip-network`.

With network probes enabled, add roughly `hosts × timeout` (default timeout 10s).

`--deep-manifest` on a large `/opt/aelladata` can take **many minutes** and generate a large TSV. Prefer default shallow mode unless you need full metadata. The deep walk stays on one filesystem (`-xdev`), skips sensitive path name patterns, and applies a timeout safety valve.

## Transferring results safely

1. Prefer the `.tar.gz` over copying a live tree.
2. Transfer over an existing admin channel (scp/sftp); treat the archive as sensitive even after redaction.
3. Restrict filesystem permissions (`umask 077` is applied while collecting).
4. Do not unpack on untrusted shared hosts without access control.

## Next step

After analysis of this archive, run [`scripts/dp-upgrade-preflight.sh`](../scripts/dp-upgrade-preflight.sh) (see [`docs/dp-upgrade-preflight.md`](dp-upgrade-preflight.md)) to turn evidence into READY/BLOCKED decisions and remediation guidance.

This collector **does not perform** OS hops or DP 6.6.0 Py3 bringup.

## Phase separation

This collector gathers evidence for both OS and DP bringup inventory. Phase 1 OS-only preflight (`dp-os-upgrade-preflight.sh`) uses OS readiness fields for READY/BLOCKED. Bringup/Py3 fields are informational until a separate Phase 2 workflow is run after Ubuntu 24.04.
