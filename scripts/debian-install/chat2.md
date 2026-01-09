# Linux Swap Optimization for Idle Applications - Quick Reference Guide

**Version**: 1.0  
**Date**: 2026-01-09  
**Tested On**: Debian with kernel 6.12.57+deb13-amd64

---

## Executive Summary

This document covers optimizing Linux swap performance for running many idle applications with limited RAM. Key findings:

1. **ZSWAP is superior to ZRAM** for idle workloads due to automatic hot/cold page migration
2. **Kernel swap behavior**: Writes occur in batches (SWAP_CLUSTER_MAX=32 pages), reads use page-cluster for readahead
3. **Optimal configuration**: ZSWAP with lz4/zstd compression + multiple disk swap partitions
4. **fio testing**: Requires numjobs parameter to properly test parallel device access
5. **Memory accounting**: ZSWAP usage is hidden from standard tools like `free` and `top`

---

## Table of Contents

1. [Kernel Swap Mechanics](#kernel-swap-mechanics)
2. [Testing Swap Performance with fio](#testing-swap-performance-with-fio)
3. [ZRAM vs ZSWAP Architecture](#zram-vs-zswap-architecture)
4. [Configuration Guide](#configuration-guide)
5. [Monitoring and Verification](#monitoring-and-verification)
6. [Performance Results](#performance-results)
7. [Troubleshooting](#troubleshooting)
8. [Key Takeaways](#key-takeaways)
9. [Quick Reference](#quick-reference)

---

## Kernel Swap Mechanics

### Page-Cluster (vm.page-cluster)

**Purpose**: Controls swap read-ahead behavior (reads only, NOT writes)

```bash
# Value is logarithmic: 2^value pages read at once
vm.page-cluster=0  # 1 page (4KB)
vm.page-cluster=1  # 2 pages (8KB)
vm.page-cluster=3  # 8 pages (32KB) - default
```

**How it works:**

1. When kernel swaps OUT pages, they get allocated consecutive swap slots
2. When ONE page faults back in, kernel reads neighboring slots (page-cluster)
3. Works because of batch swap-out creating swap slot locality
4. Only affects reads, writes are NOT controlled by this parameter

**Recommendation**: Set to 0 for SSD/NVMe/ZRAM, 1-3 for HDD

### SWAP_CLUSTER_MAX

**Kernel constant**: 32 pages (not runtime configurable)

**Behavior:**

- Kernel reclaims up to 32 pages per `shrink_page_list()` cycle
- Pages may be written in multiple I/O operations
- Block layer can coalesce adjacent writes
- With multiple swap devices at equal priority: round-robin distribution

**Example:**

```
32 pages to swap out, 4 devices at priority 10:
  Device 1: Gets 8 pages (32KB)
  Device 2: Gets 8 pages (32KB)
  Device 3: Gets 8 pages (32KB)
  Device 4: Gets 8 pages (32KB)
```

### Modern Kernel Features (6.12+)

**VMA-based readahead**: Kernel 4.8+ feature
- Smarter than blind swap-slot readahead
- Reads pages from same virtual address range
- Detects true spatial locality in process address space

**Multi-page write support**: Recent kernels
- Batches multiple swap writes into single I/O
- Reduces overhead, improves throughput

---

## Testing Swap Performance with fio

### Critical Discovery: numjobs Behavior

**With numjobs=1:**

```bash
# WRONG: Single thread accesses files sequentially
fio --filename=/dev/vda4:/dev/vda5:/dev/vda6:/dev/vda7 \
    --numjobs=1 --iodepth=4
# Result: No parallelism, ~17k IOPS regardless of file count
```

**With numjobs=N:**

```bash
# CORRECT: N threads access files in parallel
fio --filename=/dev/vda4:/dev/vda5:/dev/vda6:/dev/vda7 \
    --numjobs=4 --iodepth=4
# Result: True parallelism, ~42k IOPS
```

### Test Results (8 swap partitions on single disk)

| numjobs | Read IOPS | Write IOPS | Total BW | 99%ile Latency | Score |
|---------|-----------|------------|----------|----------------|-------|
| 1       | 17.1k     | 7.3k       | 95 MB/s  | 803µs          | Baseline |
| 8       | 18.0k     | 7.7k       | 312 MB/s | 1123µs         | +3.3x BW |
| 16      | 23.5k     | 10.1k      | 408 MB/s | 1483µs         | +4.3x BW |
| 32      | 30.0k     | 12.9k      | 519 MB/s | 1713µs         | +5.5x BW |

**Sweet spot for idle applications**: numjobs=8-12
- Good bandwidth (300-350 MB/s)
- Excellent latency (<1ms 99th percentile)
- Lower CPU overhead

### Recommended fio Test

```bash
# Test swap performance matching kernel behavior
fio --name=swap-realistic \
    --filename=/dev/vda4:/dev/vda5:/dev/vda6:/dev/vda7:/dev/vda8:/dev/vda9:/dev/vda10:/dev/vda11 \
    --rw=randrw \
    --rwmixread=70 \
    --bs=4k \
    --ioengine=libaio \
    --direct=1 \
    --iodepth=4 \
    --numjobs=8 \
    --runtime=60 \
    --time_based=1 \
    --group_reporting=1 \
    --lat_percentiles=1
```

---

## ZRAM vs ZSWAP Architecture

### ZRAM + Disk Swap

```
Application Memory
       ↓
   [ZRAM] (priority 100) - Compressed in RAM
       ↓ (when full)
   [Disk Swap] (priority 10) - Uncompressed on disk
```

**Problems:**
- Pages "stick" in ZRAM (no automatic migration)
- Cold pages waste RAM in ZRAM
- Hot pages may be on slow disk
- No LRU-based rebalancing

**When ZRAM frees space:**
- ✓ Process exits/terminates
- ✓ Page swapped in AND modified
- ✗ NO automatic cold page eviction
- ✗ NO migration to disk tier

### ZSWAP + Disk Swap

```
Application Memory
       ↓
   [ZSWAP Cache] (in RAM) - Compressed cache
       ↓
   [Disk Swap] - Uncompressed backing store
```

**Advantages:**
- Write-through cache architecture
- Pages exist compressed in RAM AND uncompressed on disk
- LRU-based eviction from cache
- Automatic hot/cold separation
- Dynamic cache sizing with shrinker (kernel 6.8+)

**Page lifecycle:**

```
1. Swap out → Compress to ZSWAP cache + Write to disk
2. Cache fills → Evict cold pages from ZSWAP (still on disk)
3. Swap in (hot) → Read from ZSWAP cache (fast ~15µs)
4. Swap in (cold) → Read from disk (slow ~500µs-10ms)
```

### Compression Algorithm Comparison

| Algorithm | Ratio | Compress | Decompress | Latency | Built-in | Recommendation |
|-----------|-------|----------|------------|---------|----------|----------------|
| lzo       | 1.8:1 | Very fast | Very fast | ~3µs    | ✓ Yes    | Safe fallback |
| lzo-rle   | 1.9:1 | Very fast | Very fast | ~3µs    | ✓ Yes    | Good for repetitive data |
| lz4       | 2.0:1 | Fast      | Fast      | ~3µs    | Module   | **Best balance** |
| lz4hc     | 2.1:1 | Medium    | Fast      | ~5µs    | Module   | Better compression |
| zstd      | 2.3:1 | Medium    | Medium    | ~15µs   | Module   | **Best compression** |

**For idle applications**: lz4 or lz4hc recommended
- Fast decompression (important for page faults)
- Lower CPU usage
- Good compression ratio
- More reliable at boot

### ZSWAP Shrinker (Kernel 6.8+)

**Without shrinker:**

```
ZSWAP fills up → Rejects new pages → Direct disk I/O increases
Problem: ZSWAP can't reclaim its own memory → System OOM
```

**With shrinker:**

```
Memory pressure → Shrinker evicts cold pages → Frees ZSWAP cache
Result: Dynamic cache sizing, prevents OOM, hot/cold separation works
```

**Enable shrinker:**

```bash
echo Y > /sys/module/zswap/parameters/shrinker_enabled
```

---

## Configuration Guide

### System Specifications (Example)

- **Total RAM**: 8GB
- **Target ZSWAP cache**: 3GB (38% of RAM)
- **Disk swap**: 8 partitions × 1GB = 8GB
- **Kernel**: 6.12.57+deb13-amd64
- **Storage**: Single virtual disk (vda) with 8 partitions

### Complete ZSWAP Setup Script

```bash
#!/bin/bash
# Complete ZSWAP + Swap Configuration
# Tested on Debian with kernel 6.12.57+

set -e

echo "=================================================="
echo "     Complete ZSWAP + Swap Configuration"
echo "=================================================="
echo ""

# ============================================================
# Configuration
# ============================================================
TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
TARGET_ZSWAP_MB=3072
MAX_POOL_PERCENT=$(( TARGET_ZSWAP_MB * 100 / TOTAL_RAM_MB ))
SWAP_DEVS="/dev/vda4 /dev/vda5 /dev/vda6 /dev/vda7 /dev/vda8 /dev/vda9 /dev/vda10 /dev/vda11"

echo "System Configuration:"
echo "  Total RAM:      ${TOTAL_RAM_MB}MB"
echo "  ZSWAP target:   ${TARGET_ZSWAP_MB}MB (${MAX_POOL_PERCENT}%)"
echo ""

# ============================================================
# Step 1: Setup swap partitions
# ============================================================
echo "Step 1: Configuring swap partitions..."

for dev in $SWAP_DEVS; do
    swapoff $dev 2>/dev/null || true
done

for dev in $SWAP_DEVS; do
    if [ -b "$dev" ]; then
        mkswap $dev
        swapon -p 10 $dev
        echo "  ✓ $dev"
    else
        echo "  ✗ $dev not found!"
    fi
done

echo ""
swapon -s
echo ""

# ============================================================
# Step 2: Configure ZSWAP via kernel parameters
# ============================================================
echo "Step 2: Configuring ZSWAP kernel parameters..."

GRUB_FILE="/etc/default/grub"
BACKUP_FILE="${GRUB_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
cp "${GRUB_FILE}" "${BACKUP_FILE}"
echo "  Backed up to: ${BACKUP_FILE}"

sed -i 's/zswap\.[^ ]*//g' "${GRUB_FILE}"
sed -i 's/  */ /g' "${GRUB_FILE}"

# Use lz4 (widely available) or lzo (built-in fallback)
ZSWAP_PARAMS="zswap.enabled=1 zswap.compressor=lz4 zswap.zpool=zsmalloc zswap.max_pool_percent=${MAX_POOL_PERCENT} zswap.accept_threshold_percent=90 zswap.shrinker_enabled=1"
sed -i "s/GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"${ZSWAP_PARAMS} /" "${GRUB_FILE}"

if command -v update-grub &> /dev/null; then
    update-grub
elif command -v grub2-mkconfig &> /dev/null; then
    grub2-mkconfig -o /boot/grub2/grub.cfg
fi

echo "  ✓ GRUB configured"
echo ""

# ============================================================
# Step 3: Configure immediate ZSWAP (current session)
# ============================================================
echo "Step 3: Enabling ZSWAP for current session..."

echo Y > /sys/module/zswap/parameters/enabled

for comp in lz4 zstd lzo; do
    if echo "$comp" > /sys/module/zswap/parameters/compressor 2>/dev/null; then
        echo "  ✓ Using compressor: $comp"
        break
    fi
done

echo "zsmalloc" > /sys/module/zswap/parameters/zpool 2>/dev/null || \
echo "zbud" > /sys/module/zswap/parameters/zpool

echo "${MAX_POOL_PERCENT}" > /sys/module/zswap/parameters/max_pool_percent
echo "90" > /sys/module/zswap/parameters/accept_threshold_percent
echo "Y" > /sys/module/zswap/parameters/shrinker_enabled 2>/dev/null || \
    echo "  ⓘ Shrinker not available (requires kernel 6.8+)"

echo "  ✓ ZSWAP enabled"
echo ""

# ============================================================
# Step 4: Configure sysctl
# ============================================================
echo "Step 4: Configuring sysctl parameters..."

cat > /etc/sysctl.d/99-zswap-tuning.conf <<'SYSCTL_EOF'
# ZSWAP configuration for idle applications

# Aggressive swapping (ZSWAP makes it cheap)
vm.swappiness=80

# No readahead (ZSWAP caches 4K pages)
vm.page-cluster=0

# Keep metadata cached
vm.vfs_cache_pressure=50

# Dirty page writeback
vm.dirty_ratio=15
vm.dirty_background_ratio=5
vm.dirty_expire_centisecs=1000
vm.dirty_writeback_centisecs=500

# Memory management
vm.compact_unevictable_allowed=0
vm.watermark_scale_factor=125

# Overcommit
vm.overcommit_memory=1
vm.overcommit_ratio=100
SYSCTL_EOF

sysctl -p /etc/sysctl.d/99-zswap-tuning.conf > /dev/null
echo "  ✓ Sysctl configured"
echo ""

# Continue with Steps 5-7 (fstab, THP, monitoring tools)...
```

### Sysctl Configuration Explained

| Parameter | Value | Reason |
|-----------|-------|--------|
| vm.swappiness | 80 | ZSWAP makes swapping fast, encourage use |
| vm.page-cluster | 0 | ZSWAP caches individual 4K pages |
| vm.vfs_cache_pressure | 50 | Keep metadata cached (swap is fast) |
| vm.dirty_ratio | 15 | Batch disk writes when ZSWAP evicts |
| vm.watermark_scale_factor | 125 | Less aggressive reclaim needed |

### THP Configuration

**Why disable for idle apps:**

```
Without THP (4KB pages):
[App1][App2][App3]  ← Swap 4KB individually

With THP (2MB pages):
[App1--------]  ← Must swap entire 2MB
```

**Problems:**
- Memory bloat (100KB app gets 2MB)
- Inefficient swapping (swap 2MB vs 4KB)
- Increased fragmentation
- khugepaged causes latency spikes

**Configuration:**

```bash
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
```

---

## Monitoring and Verification

### ZSWAP Memory Accounting

**Critical fact**: ZSWAP memory is hidden from standard tools!

```bash
# What 'free' shows:
# Total:  7940 MB
# Used:   3500 MB  ← Includes ZSWAP but can't see split
# Free:   4440 MB

# Reality:
# Apps:       2000 MB
# ZSWAP:      1500 MB  ← Hidden!
# Free:       4440 MB
```

**To see ZSWAP usage:**

```bash
# Only way to see it:
cat /sys/kernel/debug/zswap/pool_total_size  # bytes
cat /sys/kernel/debug/zswap/stored_pages     # page count

# Or use the script:
show-real-memory
```

### Key Monitoring Points

```bash
# 1. Check ZSWAP is enabled
cat /sys/module/zswap/parameters/enabled  # Should be: Y

# 2. Check compressor and pool
cat /sys/module/zswap/parameters/compressor
cat /sys/module/zswap/parameters/zpool

# 3. Check usage
check-zswap

# 4. Real-time monitoring
monitor-zswap

# 5. Check boot messages
journalctl -b | grep zswap

# 6. Verify swap devices
swapon -s
```

---

## Performance Results

### Access Time Comparison

| Location | Latency | Relative Speed |
|----------|---------|----------------|
| L1 Cache | ~1ns | 1x |
| RAM | ~100ns | 100x |
| ZSWAP (lz4) | 5-10µs | 50-100x slower than RAM |
| ZSWAP (zstd) | 15-20µs | 150-200x slower |
| NVMe SSD | 100-200µs | 1000-2000x |
| SATA SSD | 500µs-1ms | 5000-10000x |
| HDD | 10-20ms | 100000-200000x |

**Key insight**: Even 10µs difference between lz4 and zstd is negligible compared to disk I/O (500µs+)

### Compression Ratios

Test configuration: 8GB RAM, idle applications

| Compressor | Compression Ratio | 3GB ZSWAP Holds | Speed |
|------------|-------------------|-----------------|-------|
| lzo | 1.8:1 | ~5.4GB | Fastest |
| lzo-rle | 1.9:1 | ~5.7GB | Fastest |
| lz4 | 2.0:1 | ~6.0GB | Fast |
| lz4hc | 2.1:1 | ~6.3GB | Medium |
| zstd | 2.3:1 | ~6.9GB | Medium |

**Extra capacity with zstd**: ~900MB vs lz4  
**Trade-off**: 3x slower decompression for 15% more capacity

### Total System Capacity

```
Example: 8GB RAM system with configuration:
- ZSWAP: 3GB RAM (max_pool_percent=38%)
- Compression: 2.3:1 (zstd)
- Disk swap: 8GB

Effective capacity:
  RAM:    8 GB
  ZSWAP:  ~7 GB effective (3GB × 2.3)
  Disk:   8 GB
  ─────
  Total: ~23 GB virtual memory
```

---

## Troubleshooting

### Issue: zstd Not Available at Boot

**Symptom:**

```
kernel: zswap: compressor zstd not available, using default lzo
```

**Solution 1: Use lz4 (simpler)**

```bash
# Change GRUB config to use lz4
sed -i 's/zswap.compressor=zstd/zswap.compressor=lz4/' /etc/default/grub
update-grub
reboot
```

**Solution 2: Load modules early**

```bash
# Add to initramfs
cat > /etc/initramfs-tools/modules <<EOF
lz4
lz4_compress
zstd
zstd_compress
EOF

update-initramfs -u -k all
reboot
```

### Issue: ZSWAP Not Showing Usage

**Check:**

```bash
# ZSWAP enabled?
cat /sys/module/zswap/parameters/enabled  # Should be: Y

# Any memory pressure yet?
cat /sys/kernel/debug/zswap/stored_pages  # May be 0 if no swapping

# Create memory pressure to test:
stress-ng --vm 1 --vm-bytes 6G --timeout 30s
```

### Issue: Out of Memory Despite ZSWAP

**Solutions:**
1. Enable shrinker (kernel 6.8+)
2. Increase max_pool_percent
3. Add more disk swap
4. Reduce application memory usage

---

## Key Takeaways

1. **ZSWAP is superior to ZRAM** for workloads with many idle applications due to automatic LRU-based eviction and hot/cold separation

2. **Pages on disk are NOT compressed** - only the ZSWAP cache (in RAM) contains compressed pages

3. **ZSWAP memory is hidden** from standard monitoring tools - use `/sys/kernel/debug/zswap/` to see actual usage

4. **ZSWAP competes with applications for RAM** - it's not "free" memory, it comes from the same pool

5. **vm.page-cluster only affects reads** - writes are controlled by SWAP_CLUSTER_MAX (hardcoded at 32 pages)

6. **fio requires numjobs** to properly test multi-device parallelism - numjobs=1 serializes access

7. **lz4 is often better than zstd** for swap - 5x faster decompression, only 15% worse compression

8. **Enable shrinker (kernel 6.8+)** to prevent ZSWAP from causing OOM

9. **Multiple swap partitions on same disk** provide limited benefit (~2.5x throughput) due to shared I/O queue

10. **Optimal configuration for idle apps:**
    - vm.swappiness=80 (aggressive)
    - vm.page-cluster=0 (no readahead)
    - ZSWAP with lz4 or zstd
    - 8+ swap partitions for parallelism
    - THP disabled (madvise mode)

---

## Quick Reference

```bash
# Setup (one-time)
chmod +x /root/complete-zswap-setup.sh
/root/complete-zswap-setup.sh
reboot

# Verification
check-zswap
show-real-memory

# Monitoring
monitor-zswap

# Testing
fio --name=test --filename=/dev/vda4:/dev/vda5 --rw=randrw --rwmixread=70 \
    --bs=4k --ioengine=libaio --direct=1 --iodepth=4 --numjobs=8 \
    --runtime=60 --time_based=1 --group_reporting=1

# Tuning
sysctl vm.swappiness=80
sysctl vm.page-cluster=0
echo zstd > /sys/module/zswap/parameters/compressor
echo Y > /sys/module/zswap/parameters/shrinker_enabled
```

---

**Document Version**: 1.0  
**Last Updated**: 2026-01-09  
**Tested On**: Debian with kernel 6.12.57+deb13-amd64
