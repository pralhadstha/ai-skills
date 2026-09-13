#!/usr/bin/env bash
#
# Routine Google Drive -> Nextcloud AIO re-sync.
#
# Runs the safe pipeline: rclone copy (own Drive + shared-with-me) ->
# NFC filename normalisation -> ownership fix -> occ files:scan.
#
# This is for recurring syncs. It is NOT the repair procedure for an already
# corrupted file cache -- see SKILL.md phases 1-3 for that.
#
# Usage:
#   NC_USER=... REMOTE=... HOST_DATA=... nc-drive-sync.sh [--no-shared] [--dry-run]
#
# NC_USER, REMOTE and HOST_DATA are required. Everything else below has a
# default and can be overridden the same way.

set -euo pipefail

NC_CONTAINER="${NC_CONTAINER:-nextcloud-aio-nextcloud}"
NC_USER="${NC_USER:?set NC_USER to the Nextcloud username}"
REMOTE="${REMOTE:?set REMOTE to the rclone remote name}"
HOST_DATA="${HOST_DATA:?set HOST_DATA to the host-side Nextcloud data dir}"
DRIVE_SUBDIR="${DRIVE_SUBDIR:-Drive}"
SHARED_SUBDIR="${SHARED_SUBDIR:-_SharedWithMe}"
LOG_DIR="${LOG_DIR:-/root}"
TRANSFERS="${TRANSFERS:-4}"
CHECKERS="${CHECKERS:-8}"

SYNC_SHARED=1
DRY_RUN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --no-shared) SYNC_SHARED=0 ;;
        --dry-run)   DRY_RUN="--dry-run" ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

DEST="${HOST_DATA}/${NC_USER}/files/${DRIVE_SUBDIR}"
CONTAINER_DEST="/mnt/ncdata/${NC_USER}/files/${DRIVE_SUBDIR}"
STAMP="$(date +%F-%H%M)"

log() { printf '\n=== %s\n' "$*"; }

log "preflight"
command -v rclone >/dev/null || { echo "rclone not found" >&2; exit 1; }
docker exec --user www-data "$NC_CONTAINER" php occ status >/dev/null \
    || { echo "cannot reach $NC_CONTAINER" >&2; exit 1; }

if docker exec "$NC_CONTAINER" ps aux | grep -qE '[c]ron\.php|[o]cc files:scan'; then
    echo "a scan or cron run is already in progress -- wait for it to finish" >&2
    exit 1
fi

df -h "$HOST_DATA"
mkdir -p "$DEST"

log "copying own Drive"
rclone copy "${REMOTE}:" "${DEST}/" \
    $DRY_RUN \
    --drive-skip-shortcuts \
    --fast-list \
    --transfers "$TRANSFERS" \
    --checkers "$CHECKERS" \
    --stats 60s \
    --log-file="${LOG_DIR}/rclone-drive-${STAMP}.log" \
    --log-level NOTICE

if [ "$SYNC_SHARED" -eq 1 ]; then
    log "copying shared-with-me"
    rclone copy "${REMOTE}:" "${DEST}/${SHARED_SUBDIR}/" \
        $DRY_RUN \
        --drive-shared-with-me \
        --drive-skip-shortcuts \
        --fast-list \
        --transfers "$TRANSFERS" \
        --checkers "$CHECKERS" \
        --stats 60s \
        --log-file="${LOG_DIR}/rclone-shared-${STAMP}.log" \
        --log-level NOTICE
fi

if [ -n "$DRY_RUN" ]; then
    log "dry run complete -- no local changes made"
    exit 0
fi

log "checking for recursive loops"
if find "$DEST" -mindepth 15 -type d 2>/dev/null | head -1 | grep -q .; then
    echo "WARNING: paths nested 15+ deep found. Inspect before scanning:" >&2
    find "$DEST" -mindepth 15 -type d 2>/dev/null | head -5 >&2
    exit 1
fi

log "normalising filenames to NFC"
if command -v convmv >/dev/null; then
    convmv -f utf8 -t utf8 --nfc -r --notest "$DEST" || true
else
    python3 - "$DEST" <<'PY'
import os, sys, unicodedata

root = sys.argv[1]
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
fi

log "fixing ownership"
docker exec "$NC_CONTAINER" chown -R www-data:www-data "$CONTAINER_DEST"

log "scanning"
docker exec --user www-data "$NC_CONTAINER" \
    php occ files:scan --path="/${NC_USER}/files/${DRIVE_SUBDIR}"

log "transfer errors"
grep -h 'ERROR' "${LOG_DIR}"/rclone-*-"${STAMP}".log 2>/dev/null \
    | grep -oP 'ERROR : \K[^:]{0,120}' | sort -u || echo "none"

log "done"
