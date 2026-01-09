# Known Issues and Limitations

This document describes known issues, limitations, and workarounds for the swap configuration toolkit.

## ZSTD Compressor and Kernel Boot Parameters

### Issue: ZSTD Module Not Available at Early Boot

**Severity:** Important  
**Affected:** ZSWAP with zstd compressor via GRUB kernel command line  
**Status:** Documented, workaround implemented

### Problem Description

When using zstd as the ZSWAP compressor, attempting to configure it via GRUB kernel command line parameters (`zswap.compressor=zstd`) does **not work reliably**. This is because:

1. **Module Loading Order:** The zstd compression module (`zstd_compress`) is not built into the kernel on most Debian installations - it's loaded as a module.

2. **Early Boot Timing:** ZSWAP initialization happens very early in the boot process, before the initramfs/initrd has loaded the zstd kernel module.

3. **Initramfs Limitations:** Even adding zstd to the initramfs doesn't guarantee it will be available in time for ZSWAP initialization.

4. **Silent Failure:** When zstd is not available, the kernel silently falls back to the default compressor (lz4) or may fail to enable ZSWAP entirely.

### Evidence

When checking ZSWAP status after boot with `zswap.compressor=zstd` in GRUB:

```bash
# Expected:
cat /sys/module/zswap/parameters/compressor
# Output: zstd

# Actual (on many systems):
cat /sys/module/zswap/parameters/compressor
# Output: lz4 (fallback) or ZSWAP disabled
```

### Failed Approaches

The following approaches do **NOT** work reliably:

1. **GRUB kernel command line only:**
   ```bash
   GRUB_CMDLINE_LINUX_DEFAULT="zswap.enabled=1 zswap.compressor=zstd"
   ```
   - Fails because zstd module not loaded at ZSWAP init time

2. **Adding zstd to initramfs via /etc/initramfs-tools/modules:**
   ```bash
   echo "zstd" >> /etc/initramfs-tools/modules
   echo "zstd_compress" >> /etc/initramfs-tools/modules
   update-initramfs -u
   ```
   - Module may load, but often too late for ZSWAP initialization
   - Initramfs loading order is not guaranteed

3. **DKMS/modprobe configuration:**
   ```bash
   echo "zstd_compress" > /etc/modules-load.d/zstd.conf
   ```
   - These methods run after initramfs, too late for early ZSWAP

### Working Solution: Systemd Service

The only reliable method is to configure ZSWAP **after boot** using a systemd service:

```ini
[Unit]
Description=Configure ZSWAP Parameters
After=local-fs.target
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'echo 1 > /sys/module/zswap/parameters/enabled && \
    echo zstd > /sys/module/zswap/parameters/compressor && \
    echo z3fold > /sys/module/zswap/parameters/zpool && \
    echo 20 > /sys/module/zswap/parameters/max_pool_percent'

[Install]
WantedBy=multi-user.target
```

### Implementation in This Toolkit

This toolkit implements the following strategy:

1. **GRUB Configuration (Conservative):**
   - Only enables ZSWAP via GRUB: `zswap.enabled=1`
   - Does NOT set compressor via GRUB (avoids silent failures)
   - Sets pool percent via GRUB (this works fine)

2. **Systemd Service (Reliable):**
   - `/etc/systemd/system/zswap-config.service` handles compressor configuration
   - Runs after system is fully booted
   - Can use any available compressor (lz4, zstd, lzo-rle)
   - Service is idempotent and can be restarted

3. **Runtime Configuration:**
   - Script applies settings immediately during execution
   - Systemd service ensures settings persist across reboots

### Compressor Recommendations

| Compressor | GRUB Boot Config | Systemd Config | Notes |
|------------|------------------|----------------|-------|
| lz4 | ✅ Works | ✅ Works | Built into kernel, always available |
| lzo-rle | ⚠️ May fail | ✅ Works | Module, may not be in initramfs |
| zstd | ❌ Does NOT work | ✅ Works | Module, requires systemd approach |

### Verification

To verify your ZSWAP compressor is correctly set:

```bash
# Check current compressor
cat /sys/module/zswap/parameters/compressor

# Check if ZSWAP is enabled
cat /sys/module/zswap/parameters/enabled

# Check systemd service status
systemctl status zswap-config.service

# View ZSWAP statistics
cat /sys/kernel/debug/zswap/pool_total_size
```

### Related Files

- `setup-swap.sh`: Main swap configuration script (creates systemd service)
- `/etc/systemd/system/zswap-config.service`: Systemd service for ZSWAP configuration
- `/etc/default/grub`: GRUB configuration (zswap.enabled only)

---

## Other Known Issues

### XFS Root Filesystem Cannot Be Shrunk

**Severity:** Medium  
**Affected:** Partition-based swap on XFS root filesystem

XFS does not support shrinking. If you have an XFS root filesystem that uses the entire disk, you cannot use partition-based swap (SWAP_BACKING_TYPE=partitions_swap) because we cannot shrink the root partition to make room for swap.

**Workaround:** Use file-based swap (SWAP_BACKING_TYPE=files_in_root) instead.

### ZRAM Module Not Built Into Kernel

**Severity:** Low  
**Affected:** ZRAM swap on minimal kernel installations

Some minimal kernel configurations may not include the ZRAM module. The script will fail with "Failed to load zram module" if ZRAM is not available.

**Workaround:** Install the full kernel package or use ZSWAP instead.

---

## Reporting New Issues

If you encounter issues not documented here, please:

1. Check the logs: `/var/log/debian-install/`
2. Run system analysis: `./analyze-memory.sh`
3. Report at: https://github.com/volkb79/vbpub/issues
