#!/bin/sh
# initramfs-tools hook: include required binaries + marker/config for vbpub offline repartition.

set -eu

PREREQ=""
prereqs() { echo "$PREREQ"; }

case "${1:-}" in
  prereqs)
    prereqs
    exit 0
    ;;
esac

. /usr/share/initramfs-tools/hook-functions

copy_exec_resolved() {
  name="$1"
  dest="$2"
  path=$(command -v "$name" 2>/dev/null || true)
  if [ -z "$path" ] || [ ! -x "$path" ]; then
    echo "E: vbpub-offline-repartition: missing required binary: $name" >&2
    exit 1
  fi
  copy_exec "$path" "$dest"
}

# Core tools
copy_exec_resolved e2fsck /sbin
copy_exec_resolved resize2fs /sbin
copy_exec_resolved sfdisk /sbin
copy_exec_resolved partx /sbin
copy_exec_resolved mkswap /sbin
copy_exec_resolved blkid /sbin

# Config + partition table (optional)
if [ -f /etc/vbpub/offline-repartition.conf ]; then
  mkdir -p "${DESTDIR}/etc/vbpub" 2>/dev/null || true
  cp -a /etc/vbpub/offline-repartition.conf "${DESTDIR}/etc/vbpub/offline-repartition.conf"
fi
if [ -f /etc/vbpub/offline-ptable.sfdisk ]; then
  mkdir -p "${DESTDIR}/etc/vbpub" 2>/dev/null || true
  cp -a /etc/vbpub/offline-ptable.sfdisk "${DESTDIR}/etc/vbpub/offline-ptable.sfdisk"
fi
