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

MODE=${MODE:-swap}

if [ "$MODE" = "swap" ]; then
  : "${SWAP_FIRST_NUM:?}"
  : "${SWAP_LAST_NUM:?}"
  : "${SWAP_PRIORITY:?}"
else
  SWAP_FIRST_NUM=${SWAP_FIRST_NUM:-0}
  SWAP_LAST_NUM=${SWAP_LAST_NUM:-0}
  SWAP_PRIORITY=${SWAP_PRIORITY:-10}
fi

part_dev() {
  # nvme0n1p2 / mmcblk0p2 style needs 'p' separator.
  if echo "$ROOT_DISK" | grep -q '[0-9]$'; then
    echo "/dev/${ROOT_DISK}p$1"
  else
    echo "/dev/${ROOT_DISK}$1"
  fi
}

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
log "MODE=$MODE"

# Ensure tools exist (hook should include them)
for bin in e2fsck resize2fs sfdisk partx; do
  command -v "$bin" >/dev/null 2>&1 || { log "Missing $bin in initramfs"; exit 1; }
done

if [ "$MODE" = "swap" ]; then
  for bin in mkswap blkid; do
    command -v "$bin" >/dev/null 2>&1 || { log "Missing $bin in initramfs"; exit 1; }
  done
fi

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

if [ "$MODE" = "swap" ]; then
  # Wait briefly for new partition nodes.
  for i in $(seq 1 30); do
    ok=1
    for p in $(seq "$SWAP_FIRST_NUM" "$SWAP_LAST_NUM"); do
      dev="$(part_dev "$p")"
      [ -b "$dev" ] || ok=0
    done
    [ "$ok" -eq 1 ] && break
    sleep 1
  done

  # 5) Format swap partitions and write stable PARTUUID fstab entries.
  mkdir -p /mnt 2>/dev/null || true
  if mount -o rw "$ROOT_PARTITION" /mnt 2>/dev/null; then
    # Remove prior swap lines (best effort) to avoid duplicates.
    if [ -f /mnt/etc/fstab ]; then
      cp /mnt/etc/fstab "/mnt/etc/fstab.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
      awk '
        /^[[:space:]]*#/ {print; next}
        NF>=3 && $3=="swap" {next}
        {print}
      ' /mnt/etc/fstab > /mnt/etc/fstab.tmp 2>/dev/null && mv /mnt/etc/fstab.tmp /mnt/etc/fstab
    fi

    for p in $(seq "$SWAP_FIRST_NUM" "$SWAP_LAST_NUM"); do
      dev="$(part_dev "$p")"
      if [ -b "$dev" ]; then
        log "Formatting swap: $dev"
        mkswap "$dev" >>"$LOG" 2>&1 || true
        partuuid=$(blkid -s PARTUUID -o value "$dev" 2>/dev/null || true)
        if [ -n "$partuuid" ]; then
          echo "PARTUUID=${partuuid} none swap sw,pri=${SWAP_PRIORITY} 0 0" >> /mnt/etc/fstab
        else
          echo "${dev} none swap sw,pri=${SWAP_PRIORITY} 0 0" >> /mnt/etc/fstab
        fi
      else
        log "Swap device missing: $dev"
      fi
    done

    # Remove markers so we don't run again.
    rm -f /mnt/etc/vbpub/offline-repartition.conf /mnt/etc/vbpub/offline-ptable.sfdisk 2>/dev/null || true
    umount /mnt 2>/dev/null || true
    log "Wrote swap fstab entries and cleared marker files"
  else
    log "Could not mount root rw to update fstab (will retry next boot)"
  fi
else
  # shrink-only: just clear markers if we can mount root rw.
  mkdir -p /mnt 2>/dev/null || true
  if mount -o rw "$ROOT_PARTITION" /mnt 2>/dev/null; then
    rm -f /mnt/etc/vbpub/offline-repartition.conf /mnt/etc/vbpub/offline-ptable.sfdisk 2>/dev/null || true
    umount /mnt 2>/dev/null || true
    log "Shrink-only complete; cleared marker files"
  else
    log "Shrink-only complete; could not mount root rw to clear markers (will retry next boot)"
  fi
fi

exit 0
