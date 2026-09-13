# Troubleshooting reference

Error-by-error detail for the Nextcloud scan repair and Drive re-import workflow.

## Scan errors

### `SQLSTATE[22001]: value too long for type character varying(4000)`

`oc_filecache.path` is `varchar(4000)`. Something produced a path longer than
that. Two possible causes:

1. **Recursive directory loop** (overwhelmingly the common one) — a filesystem
   copy followed a Google Drive shortcut that pointed at an ancestor folder.
   The stack trace shows dozens of nested `scanChildren` frames.
2. **A single absurdly long filename** — someone pasted a paragraph into the
   filename field. Rare, but it happens; a 1800-char name a few folders deep is
   still well inside 4000, so this usually only bites on top of other nesting.

Find both with:

```sql
SELECT fileid, length(path) AS len, left(path, 300)
FROM oc_filecache WHERE storage = <SID> ORDER BY len DESC LIMIT 20;
```

### `SQLSTATE[25P02]: current transaction is aborted`

Never the root cause. Postgres aborts the whole transaction after the first
failed statement and rejects everything after it. Fix the 22001 and this
disappears.

### `will not be accessible due to incompatible encoding`

Filename bytes are not what Nextcloud expects. Two distinct sub-cases:

**NFD vs NFC** — macOS stores `é` as `e` + U+0301 (combining acute). Both forms
are valid UTF-8 and render identically, so a `convmv` dry run appears to rename
files to the same name. Fix:

```bash
convmv -f utf8 -t utf8 --nfc -r --notest /path/to/tree
```

python3 fallback when convmv is unavailable:

```bash
python3 - <<'PY'
import os, unicodedata

root = "/path/to/tree"
renamed = skipped = 0
for dirpath, dirnames, filenames in os.walk(root, topdown=False):
    for name in dirnames + filenames:
        nfc = unicodedata.normalize("NFC", name)
        if nfc == name:
            continue
        src, dst = os.path.join(dirpath, name), os.path.join(dirpath, nfc)
        if os.path.exists(dst):
            print("SKIP collision:", src)
            skipped += 1
            continue
        os.rename(src, dst)
        renamed += 1
print(f"renamed={renamed} skipped={skipped}")
PY
```

`topdown=False` is required so files are renamed before their parent
directories; otherwise the walk's paths go stale mid-iteration.

**Latin-1 bytes** — a genuinely non-UTF-8 name, typical of an rsync from an
older filesystem. `ls -b` shows octal escapes rather than accented characters.
Fix:

```bash
convmv -f iso-8859-1 -t utf-8 -r --notest /path/to/tree
```

Run without `--notest` first in both cases.

### Folder size stuck on "pending"

`oc_filecache.size = -1`. The scan never completed, so sizes were never
propagated up the tree. Fixed by a completed scan. To force recomputation of a
specific subtree:

```sql
UPDATE oc_filecache SET size = -1 WHERE fileid = <ID>;
```

then rescan that path.

`--path=` only recomputes up to the path given. To fix the storage root, scan
the whole user: `occ files:scan <USER>`.

`path = ''` remaining `-1` after a full user scan is expected and harmless.

## rclone errors

### `file name too long`

Linux caps one path component at 255 bytes. Nothing rclone can do. Locate it by
distinctive substring:

```bash
rclone lsf <remote>: --recursive --files-only --format "ips" \
  --drive-skip-shortcuts 2>/dev/null | grep -F '<substring>' > /root/found.txt

cut -d';' -f1 /root/found.txt
cut -d';' -f2 /root/found.txt | xargs -d'\n' -n1 dirname
awk -F';' '{print "namelen=" length($2), "size=" $NF}' /root/found.txt
echo "https://drive.google.com/file/d/$(cut -d';' -f1 /root/found.txt)/view"
```

Format string `ips` yields `ID;path;size`. Open the URL to inspect before acting.

Rename at the source so it stays fixed for every future sync:

```bash
SRC=$(rclone lsf <remote>: --recursive --files-only --drive-skip-shortcuts 2>/dev/null \
      | grep -F '<substring>' | head -1)
DIR=$(dirname "$SRC")
rclone moveto "<remote>:$SRC" "<remote>:$DIR/<sane name>.txt"
```

If `dirname` returns something odd the name may contain a literal `/` (Drive
allows it, paths do not). Use the ID instead, which copies locally and leaves
Drive untouched:

```bash
rclone backend copyid <remote>: "<FILE_ID>" "/dest/path/<sane name>.txt"
```

Re-copy just that folder afterwards; `--max-depth 1` if it is at the root.

Note this is a **write to the source**, unlike everything else in the workflow.
Be deliberate about it.

### HTTP 400 / 401 with a giant HTML body on `.xlsx` / `.docx`

Native Google Docs/Sheets/Slides have no byte size until exported; rclone
converts them on the fly. The export endpoint throttles far harder than the file
download endpoint, and concurrency triggers these.

- **401 + sign-in page** — token refused for that file. Often succeeds on retry.
- **400 + "Sorry, unable to open the file"** — broken or too large to export
  server-side. Usually permanent.

Retry pass:

```bash
rclone copy <remote>: <DEST> --drive-skip-shortcuts --fast-list \
  --transfers 1 --tpslimit 2 --retries 5 \
  --log-file=/root/rclone-retry.log --log-level NOTICE
```

`copy` skips what is already present, so this only touches the gaps.

To avoid native docs entirely: `--drive-skip-gdocs`.

Extract a clean failure list without the HTML noise:

```bash
grep 'ERROR' /root/rclone-drive.log | grep -oP 'ERROR : \K[^:]{0,120}' | sort -u
```

The final `Errors: N` line counts permanent failures; `grep -c ERROR` counts
retries too, so the two legitimately differ.

### `403: This file cannot be downloaded by the user., cannotDownloadFile`

The **owner** disabled download/print/copy for viewers. Not the abuse flag —
`--drive-acknowledge-abuse` does not help. There is no API workaround; the owner
must tick "Viewers and commenters can see the option to download, print, copy"
in the share dialog. That control is invisible to non-owners.

### `403: cannotDownloadAbusiveFile`

Google's malware heuristic, which misfires constantly on business PDFs. Add
`--drive-acknowledge-abuse`.

### `Duplicate object found in source - ignoring`

Drive permits two files with the same name in one folder; a filesystem does not.
rclone copies one and skips the other, so a file is silently missing.

```bash
rclone dedupe <remote>: --dedupe-mode list
```

Lists without changing anything. Rename one in the Drive UI, then re-run.

### `NOTICE: Dangling shortcut "..." detected`

Shortcuts pointing at deleted targets. Harmless noise; silence with
`2>/dev/null`.

## Transfer appears stuck

Almost always the SSH session, not rclone. `--progress` repaints continuously,
so a frozen connection is indistinguishable from a stalled copy.

Check out-of-band:

```bash
ps aux | grep '[r]clone'
du -sh <DEST>            # run twice, a minute apart
ls -l --time-style=full-iso /root/rclone-drive.log
df -h <MOUNT>            # if this hangs, the storage mount is the problem
cat /proc/$(pgrep -f 'rclone copy')/status | grep -i state
```

Process state `D` means uninterruptible IO wait — a hung mount, not an rclone
problem.

Prevent frozen sessions from the client side:

```
Host *
  ServerAliveInterval 30
  ServerAliveCountMax 6
```

Display artifacts that are **not** stalls:

- A file showing `transferring` with no percentage — a native Google Doc being
  exported server-side, no size known yet.
- One slot at `0 B/s` while others saturate bandwidth — queued, not dead.

A genuine stall self-heals via `--timeout` (default 5m). If it recurs, add
`--timeout 10m --retries 10 --low-level-retries 20`.

## `du` reports more than rclone transferred

Compare allocated versus apparent size:

```bash
du -sh <DEST>
du -sh --apparent-size <DEST>
```

If apparent-size matches the rclone total, the gap is filesystem block overhead
on many small files. Normal. If both are inflated, something copied twice —
investigate before scanning.
