#!/bin/sh
# One-shot offline ext* shrink + repartition during initramfs (before mounting root).
# This prevents the "filesystem larger than device" brick when shrinking the root partition.

set -eu

CONF=/etc/vbpub/offline-repartition.conf
LOG=/run/vbpub-offline-repartition.log

log() {
  echo "[vbpub-offline-repartition] $*" >>"$LOG" 2>/dev/null || true
  echo "[vbpub-offline-repartition] $*" > /dev/kmsg 2>/dev/null || true
}

[ -f "$CONF" ] || exit 0

# shellcheck disable=SC1090
. "$CONF"

: "${ROOT_DISK:?}"
: "${ROOT_PARTITION:?}"
: "${NEW_BLOCKS:?}"
: "${PTABLE_PATH:?}"

attempts_file=/run/vbpub-offline-repartition.attempts
attempts=0
if [ -f "$attempts_file" ]; then
  attempts=$(cat "$attempts_file" 2>/dev/null || echo 0)
fi
attempts=$((attempts + 1))
echo "$attempts" >"$attempts_file" 2>/dev/null || true

if [ "$attempts" -gt 3 ]; then
  log "Too many attempts ($attempts); dropping to shell."
  exit 1
fi

log "Starting offline root shrink + repartition (attempt $attempts)"
log "ROOT_PARTITION=$ROOT_PARTITION NEW_BLOCKS=$NEW_BLOCKS PTABLE_PATH=$PTABLE_PATH"

# Ensure tools exist (hook should include them)
for bin in e2fsck resize2fs sfdisk partx; do
  command -v "$bin" >/dev/null 2>&1 || { log "Missing $bin in initramfs"; exit 1; }
done

# 1) fsck before resize
log "Running e2fsck -f -y on $ROOT_PARTITION (pre-resize)"
e2fsck -f -y "$ROOT_PARTITION" >>"$LOG" 2>&1 || true

# 2) shrink filesystem to NEW_BLOCKS (must be <= device blocks)
log "Running resize2fs $ROOT_PARTITION $NEW_BLOCKS"
resize2fs "$ROOT_PARTITION" "$NEW_BLOCKS" >>"$LOG" 2>&1

# 3) fsck after resize
log "Running e2fsck -f -y on $ROOT_PARTITION (post-resize)"
e2fsck -f -y "$ROOT_PARTITION" >>"$LOG" 2>&1 || true

# 4) apply partition table (root shrink + swap-at-end)
log "Applying partition table via sfdisk"
sfdisk --force --no-reread "/dev/$ROOT_DISK" <"$PTABLE_PATH" >>"$LOG" 2>&1 || true
partx -u "/dev/$ROOT_DISK" >>"$LOG" 2>&1 || true
sync

# 5) remove marker on root fs so we don't run again
mkdir -p /mnt 2>/dev/null || true
if mount -o ro "$ROOT_PARTITION" /mnt 2>/dev/null; then
  rm -f /mnt/etc/vbpub/offline-repartition.conf /mnt/etc/vbpub/offline-ptable.sfdisk 2>/dev/null || true
  umount /mnt 2>/dev/null || true
  log "Cleared marker files on root; offline repartition complete"
else
  log "Could not mount root to clear markers (will retry next boot)"
fi

exit 0
