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

# Core tools
copy_exec /sbin/e2fsck /sbin
copy_exec /sbin/resize2fs /sbin
copy_exec /sbin/sfdisk /sbin
copy_exec /sbin/partx /sbin

# Config + partition table (optional)
if [ -f /etc/vbpub/offline-repartition.conf ]; then
  mkdir -p "${DESTDIR}/etc/vbpub" 2>/dev/null || true
  cp -a /etc/vbpub/offline-repartition.conf "${DESTDIR}/etc/vbpub/offline-repartition.conf"
fi
if [ -f /etc/vbpub/offline-ptable.sfdisk ]; then
  mkdir -p "${DESTDIR}/etc/vbpub" 2>/dev/null || true
  cp -a /etc/vbpub/offline-ptable.sfdisk "${DESTDIR}/etc/vbpub/offline-ptable.sfdisk"
fi
