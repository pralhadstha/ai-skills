---
name: nextcloud-scan-repair
description: Diagnose and repair a corrupted Nextcloud file cache, then safely re-import Google Drive. Use when `occ files:scan` fails or hangs, a folder size shows "pending" forever, or the logs show "value too long for type character varying(4000)", SQLSTATE 22001, SQLSTATE 25P02 "current transaction is aborted", or "will not be accessible due to incompatible encoding" — typically after an rsync import from Google Drive created a recursive directory loop. Also use when asked to import or re-sync a Google Drive into Nextcloud without corrupting the file cache.
---

# Nextcloud Scan Repair & Safe Drive Re-import

Diagnose and repair a corrupted Nextcloud file cache, then re-populate the data
from Google Drive without recreating the problem.

## When this applies

Symptoms that point here:

| Symptom | Meaning |
|---|---|
| `SQLSTATE[22001] ... value too long for type character varying(4000)` | A path exceeded `oc_filecache.path`. Almost always a recursive directory loop. |
| `SQLSTATE[25P02] ... current transaction is aborted` | Collateral damage from the above — every later statement in the scan dies. |
| Folder size stuck on "pending" in the web UI | `oc_filecache.size = -1`; the scan never completed so it was never recomputed. |
| `will not be accessible due to incompatible encoding` | Filename bytes are NFD or Latin-1 where Nextcloud expects NFC UTF-8. Independent of the loop. |
| Deep `scanChildren` recursion in the stack trace (dozens of frames) | Confirms the loop. Read the repeated path segment to find its root. |

The classic cause: `rsync` (or any filesystem-level copy) over a FUSE-mounted
Google Drive. A Drive *shortcut* looks like a real directory to the filesystem,
so the copy descends into it forever, writing real duplicated data.

## Rules

- **Never wipe the whole instance to fix one user.** Scope to the affected user's subtree.
- **Always `pg_dump` before touching `oc_filecache`.** It is the only undo.
- **Disk deletion and cache-row deletion must happen back to back.** The gap between them is when a cron scan can land and recreate the mess.
- **Never `docker stop`/`restart` Nextcloud AIO containers by hand** — the mastercontainer manages lifecycle. Use `docker exec` only.
- **Never commit or push** anything as part of this work.
- Maintenance mode is usually **not** needed for a single user. It is needed only if (a) sync clients are connected — they will propagate the deletion and destroy local copies — or (b) the `rm -rf` will take long enough that a cron run could land mid-window.

## Phase 1 — Identify the environment

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}'
```

Nextcloud AIO uses fixed names:

- App container: `nextcloud-aio-nextcloud` (**not** `-apache`, that is the proxy)
- Database: `nextcloud-aio-database`
- Data directory: `/mnt/ncdata` inside the container

Verify and find the host-side bind mount:

```bash
docker exec --user www-data -it nextcloud-aio-nextcloud php occ status
docker exec --user www-data -it nextcloud-aio-nextcloud php occ config:system:get datadirectory
docker exec -it nextcloud-aio-nextcloud ls /mnt/ncdata
```

Never hardcode DB credentials — read them from the container's own env:

```bash
docker exec -i nextcloud-aio-database sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
\dt oc_*
SQL
```

Confirm no scan or cron is already running (AIO runs cron inside the app container
via supervisord, not as a host crontab):

```bash
docker exec -it nextcloud-aio-nextcloud ps aux | grep -E 'cron.php|occ'
```

## Phase 2 — Confirm the diagnosis

Get the affected user's **numeric storage id**. Do not read it from the stack
trace — the integer in `scanChildren(...)` frames is the scanner's `reuse`
bitmask, not a storage id.

```bash
docker exec -i nextcloud-aio-database sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
SELECT numeric_id, id FROM oc_storages WHERE id = 'home::<USER>';
SQL
```

Find the runaway paths:

```sql
SELECT fileid, length(path) AS len, left(path, 300)
FROM oc_filecache WHERE storage = <SID> ORDER BY len DESC LIMIT 5;
```

Scope check before deleting anything — a nonsense total (e.g. 9738 GB on a 750 GB
folder) is the loop double-counting folder sizes up the chain, and confirms it:

```sql
SELECT count(*), pg_size_pretty(COALESCE(sum(size),0)::bigint)
FROM oc_filecache
WHERE storage = <SID> AND (path = 'files/<DIR>' OR path LIKE 'files/<DIR>/%');
```

## Phase 3 — Repair

Back up first:

```bash
docker exec nextcloud-aio-database sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' \
  | gzip > /root/nc-$(date +%F).sql.gz
```

**Never write the dump inside the data directory** — it would get scanned into
Nextcloud. Check `pwd` first if unsure.

Record which shares will break (fileids are not stable across a re-scan):

```sql
SELECT s.id, s.share_type, s.token, s.share_with, f.path
FROM oc_share s JOIN oc_filecache f ON f.fileid = s.file_source
WHERE f.storage = <SID> AND f.path LIKE 'files/<DIR>%';
```

Delete on disk, then immediately purge the rows:

```bash
docker exec -it nextcloud-aio-nextcloud rm -rf /mnt/ncdata/<USER>/files/<DIR>
docker exec -it nextcloud-aio-nextcloud rm -rf /mnt/ncdata/<USER>/files_versions/<DIR>
```

```sql
DELETE FROM oc_filecache
WHERE storage = <SID> AND (path = 'files/<DIR>' OR path LIKE 'files/<DIR>/%');

UPDATE oc_filecache SET size = -1
WHERE storage = <SID> AND path IN ('files', '');
```

Skip `du -sh` on a looped tree — it takes longer than the delete and the number
is meaningless. `rm -rf` handles arbitrary depth via `openat`; there is no
PATH_MAX limit.

```bash
docker exec --user www-data -it nextcloud-aio-nextcloud php occ files:cleanup
docker exec --user www-data -it nextcloud-aio-nextcloud php occ files:scan <USER>
```

## Phase 4 — Re-import from Google Drive, correctly

**Use rclone against the Drive API. Never rsync over a FUSE mount.** rclone walks
folder *IDs*, and with `--drive-skip-shortcuts` the shortcut entries are never
emitted at all — no symlink exists for anything to follow, so recursion is
impossible regardless of nesting.

Survey first:

```bash
rclone listremotes
rclone lsd <remote>: --drive-skip-shortcuts 2>/dev/null
rclone size <remote>: --drive-skip-shortcuts 2>/dev/null
df -h <HOST_DATA_MOUNT>
```

`rclone size` over-reports versus what `copy` actually moves, because `size`
counts shortcut targets. The `copy` total is the real one.

Own Drive, in tmux:

```bash
rclone copy <remote>: <HOST_DATA>/<USER>/files/Drive/ \
  --drive-skip-shortcuts --fast-list --progress \
  --transfers 4 --checkers 8 \
  --log-file=/root/rclone-drive.log --log-level NOTICE
```

"Shared with me" is a **separate namespace** — not under the remote's root, so
the pass above will not include it. Copy it into its own subfolder; shared items
routinely collide with the user's own top-level folder names.

```bash
rclone copy <remote>: <HOST_DATA>/<USER>/files/Drive/_SharedWithMe/ \
  --drive-shared-with-me --drive-skip-shortcuts --fast-list --progress \
  --transfers 4 --log-file=/root/rclone-shared.log --log-level NOTICE
```

Shared Drives (Team Drives) are a third namespace: `rclone backend drives
<remote>:` to list, then `--drive-team-drive <ID>` per drive.

Run passes sequentially, never in parallel — they share one API quota.

Use `--log-level NOTICE`; failed Google Docs exports dump entire HTML pages into
the log at INFO and make it unreadable.

## Phase 5 — Post-copy hygiene (all three, in order)

```bash
convmv -f utf8 -t utf8 --nfc -r --notest <HOST_DATA>/<USER>/files/Drive
docker exec -it nextcloud-aio-nextcloud chown -R www-data:www-data /mnt/ncdata/<USER>/files/Drive
docker exec --user www-data -it nextcloud-aio-nextcloud php occ files:scan --path="/<USER>/files/Drive"
```

- **convmv** — collaborators on macOS produce NFD filenames (`é` as `e` +
  combining acute). Valid UTF-8, but Nextcloud normalizes to NFC and then cannot
  find the file. Run without `--notest` first to preview. If convmv is
  unavailable, `dnf install -y epel-release && dnf install -y convmv`, or use the
  python3 fallback in `references/troubleshooting.md`.
- **chown** — rclone runs as root; Nextcloud runs as `www-data` (UID 33) and
  cannot read root-owned files. Host-side equivalent: `chown -R 33:33`. On RHEL
  hosts `www-data` often does not exist as a name, so run it inside the container
  or use the numeric UID.
- **scan** — must report `Errors: 0`.

## Phase 6 — Verify

```sql
SELECT max(length(path)) AS longest FROM oc_filecache WHERE storage = <SID>;
SELECT path, size FROM oc_filecache
WHERE storage = <SID> AND path IN ('', 'files', 'files/Drive');
```

- `longest` should be in the hundreds, not thousands
- `files` and `files/Drive` must be positive, not `-1`
- `path = ''` staying `-1` is **normal and harmless** — the storage root
  aggregates `files_versions/`, `files_trashbin/`, `cache/`, which the scanner
  does not fully traverse. It is never shown in the UI and is not used for quota.

Then load the user's Files page and confirm sizes render instead of "pending".

Finally, sweep for any residual loop:

```bash
find <HOST_DATA>/<USER>/files/Drive -mindepth 15 -type d | head
```

## Expected non-fatal errors

See `references/troubleshooting.md` for the full table. Summary:

| Error | Action |
|---|---|
| `file name too long` | A filename over 255 bytes. Rename at the source, then re-copy that folder. |
| HTTP 400/401 on `.xlsx`/`.docx` | Native Google Docs export throttling. Retry with `--transfers 1 --tpslimit 2`; most succeed. |
| `403 cannotDownloadFile` | Owner disabled download for viewers. Unfixable via API — the owner must change it. |
| `403 cannotDownloadAbusiveFile` | Add `--drive-acknowledge-abuse`. |
| `Duplicate object found in source` | Drive allows same-name files in one folder; a filesystem does not. `rclone dedupe <remote>: --dedupe-mode list`. |
| `Dangling shortcut ... detected` | Pure noise. Silence with `2>/dev/null`. |

## Long-running transfers

Always tmux. `--progress` repaints constantly, so a dead SSH session looks
exactly like a stalled transfer — this misdiagnosis is common. Verify liveness
out-of-band instead:

```bash
ps aux | grep '[r]clone'
du -sh <DEST>
ls -l --time-style=full-iso /root/rclone-drive.log
```

Do not use `--tpslimit` on the main pass: it throttles *listing* as well as
transfers, so walking 20k objects at 2 calls/sec takes hours before a single byte
moves. Reserve it for small retry passes.

## Scripted path

`scripts/nc-drive-sync.sh` runs the recurring Phase 4–6 sync (copy → convmv →
chown → scan). It is for routine re-syncs, not for the one-time repair.
