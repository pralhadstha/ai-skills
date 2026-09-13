# nextcloud-scan-repair

Diagnose and repair a corrupted Nextcloud file cache, then safely (re-)import
Google Drive.

## What it covers

- `occ files:scan` failing with `SQLSTATE[22001]` / `varchar(4000)` path truncation
- `SQLSTATE[25P02] current transaction is aborted` cascades
- Folder sizes stuck on "pending" (`oc_filecache.size = -1`)
- `will not be accessible due to incompatible encoding` — both NFD and Latin-1 names
- Recursive directory loops created by rsync following Google Drive shortcuts
- Per-user cache surgery without wiping the whole instance
- Correct rclone-based Drive import, including "shared with me" and Shared Drives
- The full catalogue of expected rclone failures and what each one means

Written against Nextcloud AIO on Docker with PostgreSQL. The SQL and the
diagnostic reasoning apply to any Nextcloud; only container names and paths
differ.

## Layout

```
SKILL.md                      phase-by-phase repair procedure
references/troubleshooting.md error-by-error detail
scripts/nc-drive-sync.sh      routine re-sync pipeline
```

## Script

```bash
NC_USER=<user> REMOTE=<rclone-remote> HOST_DATA=<host-data-dir> ./scripts/nc-drive-sync.sh --dry-run
```

Copies own Drive and shared-with-me, normalises filenames to NFC, fixes
ownership to `www-data`, then scans. Refuses to run if a scan or cron job is
already in flight, and aborts before scanning if it finds paths nested 15+ deep.

Flags: `--dry-run`, `--no-shared`. Everything else is configurable by
environment variable — see the header of the script.

For routine re-syncs only. A corrupted cache needs the manual phases 1–3 in
`SKILL.md` first.

## Safety

The skill enforces: back up the database before touching `oc_filecache`; scope
deletions to one user; keep disk deletion and cache-row deletion adjacent; never
`docker stop` AIO containers.
