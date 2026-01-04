# Swap Architecture - Comprehensive Technical Documentation

This document provides deep technical details on swap architectures, memory compression, and performance considerations for Linux systems.

## Table of Contents

1. [Swap Fundamentals](#swap-fundamentals)
2. [Architecture Options](#architecture-options)
3. [ZRAM Deep Dive](#zram-deep-dive)
4. [ZSWAP Deep Dive](#zswap-deep-dive)
5. [ZRAM vs ZSWAP Comparison](#zram-vs-zswap-comparison)
6. [Swap-In Behavior and Metrics](#swap-in-behavior-and-metrics)
7. [ZFS Compression](#zfs-compression)
8. [Dynamic Sizing Recommendations](#dynamic-sizing-recommendations)
9. [Monitoring and Tuning](#monitoring-and-tuning)
10. [Performance Considerations](#performance-considerations)

## Swap Fundamentals

### What is Swap?

Swap space is disk storage used as an extension of physical RAM. When memory pressure occurs, the kernel can move less-frequently-used memory pages from RAM to swap, freeing RAM for active processes.

### Key Concepts

- **Page**: Basic unit of memory (typically 4KB on x86_64)
- **Swap-out**: Moving a page from RAM to swap storage
- **Swap-in**: Loading a page from swap back into RAM
- **Page fault**: When a process tries to access a swapped-out page
- **Major page fault**: Page fault requiring disk I/O
- **Minor page fault**: Page fault resolved without disk I/O

### vm.page-cluster

The `vm.page-cluster` sysctl controls swap I/O size:

```
vm.page-cluster = 0  →  4KB  (1 page)
vm.page-cluster = 1  →  8KB  (2 pages)
vm.page-cluster = 2  → 16KB  (4 pages)
vm.page-cluster = 3  → 32KB  (8 pages, default)
```

**Important:** This controls the I/O transfer size, NOT striping behavior. Striping (distributing pages across devices) happens automatically via round-robin allocation across swap devices with the same priority.

#### When to Adjust

- **Sequential access**: Higher values (2-3) improve throughput
- **Random access**: Lower values (0-1) reduce latency
- **SSD**: Lower values often better due to fast random I/O
- **HDD**: Higher values better for sequential throughput

### Multiple Swap Files and Striping

When you create multiple swap files with the same priority, the kernel automatically stripes pages across them in round-robin fashion:

```bash
# Example: 8 swap files with same priority
swapon -p 10 /swapfile.0
swapon -p 10 /swapfile.1
# ... up to swapfile.7
```

**Benefits:**
- Concurrent I/O operations across multiple files
- Better utilization of I/O parallelism
- Improved throughput when swap is under pressure

**Calculation:**
```
SWAP_TOTAL_GB / SWAP_FILES = per-file size
Example: 64GB / 8 files = 8GB per file
```

## Architecture Options

### 1. ZRAM Only

Pure RAM-based compressed swap with no disk backing.

```
┌──────────────────┐
│   Applications   │
└────────┬─────────┘
         │
    ┌────▼────┐
    │   RAM   │
    └────┬────┘
         │
    ┌────▼──────┐
    │   ZRAM    │ ← Compressed in RAM
    │ (zstd/lz4)│
    └───────────┘
```

**Configuration:**
```bash
SWAP_ARCH=zram-only
ZRAM_SIZE_PERCENT=50
ZRAM_COMP_ALGO=zstd
ZRAM_ALLOCATOR=zsmalloc
```

**Characteristics:**
- ✅ Zero disk I/O
- ✅ Fastest swap-in (decompression only)
- ✅ Simple configuration
- ❌ Limited by available RAM
- ❌ No persistence across reboots
- ❌ Can cause OOM if oversized

**Best for:** Systems with fast CPUs, moderate memory pressure, no heavy swapping

### 2. ZRAM + Swap Files (Two-Tier)

ZRAM as L1 cache with disk swap as L2 backing.

```
┌──────────────────┐
│   Applications   │
└────────┬─────────┘
         │
    ┌────▼────┐
    │   RAM   │
    └────┬────┘
         │
    ┌────▼──────┐
    │   ZRAM    │ ← L1: Compressed in RAM (higher priority)
    │  (zstd)   │
    └────┬──────┘
         │ (overflow)
         │ Decompress → Recompress cycle
         ▼
    ┌───────────┐
    │ Swap Files│ ← L2: Disk backing (lower priority)
    └───────────┘
```

**Configuration:**
```bash
SWAP_ARCH=zram-files
ZRAM_SIZE_PERCENT=25
SWAP_TOTAL_GB=64
SWAP_FILES=8
```

**Characteristics:**
- ✅ Fast access for hot data
- ✅ Disk fallback for cold data
- ✅ Flexible capacity
- ❌ **Decompress→recompress cycle on overflow** (inefficient)
- ❌ Complex two-tier management

**Overflow behavior:** When ZRAM fills up, pages must be:
1. Decompressed from ZRAM
2. Written to disk (possibly with filesystem compression)
3. Removed from ZRAM

This is inefficient compared to ZSWAP.

**Best for:** Workloads with clear hot/cold data separation

### 3. ZSWAP + Swap Files (Recommended)

Transparent RAM-based compression cache for disk swap.

```
┌──────────────────┐
│   Applications   │
└────────┬─────────┘
         │
    ┌────▼────┐
    │   RAM   │
    └────┬────┘
         │
    ┌────▼──────┐
    │  ZSWAP    │ ← Transparent cache (compressed in RAM)
    │  Pool     │   Pages written compressed directly
    └────┬──────┘
         │ (writeback on pressure)
         │ Single compression!
         ▼
    ┌───────────┐
    │ Swap Files│ ← Backing store
    │ (striped) │
    └───────────┘
```

**Configuration:**
```bash
SWAP_ARCH=zswap-files
ZSWAP_POOL_PERCENT=20
ZSWAP_COMP_ALGO=zstd
SWAP_TOTAL_GB=64
SWAP_FILES=8
```

**Characteristics:**
- ✅ **Single compression** (most efficient)
- ✅ Transparent to applications
- ✅ Automatic writeback management
- ✅ Better RAM utilization
- ✅ No decompress→recompress cycle
- ❌ Requires disk backing
- ❌ More complex debugging

**Why more efficient than ZRAM + Files:**

When ZSWAP needs to evict a page to disk:
1. Page is already compressed in ZSWAP pool
2. Compressed page written directly to disk
3. **No decompression step needed!**

Contrast with ZRAM overflow:
1. Page must be decompressed from ZRAM
2. Page written to disk (may be recompressed by filesystem)
3. Wasted CPU cycles

**Best for:** Production servers, databases, web servers, most VPS deployments

### 4. Swap Files Only

Traditional uncompressed disk-based swap.

```
┌──────────────────┐
│   Applications   │
└────────┬─────────┘
         │
    ┌────▼────┐
    │   RAM   │
    └────┬────┘
         │
         │ (direct swap-out)
         ▼
    ┌───────────┐
    │ Swap Files│ ← Multiple files striped
    │ (striped) │
    └───────────┘
```

**Configuration:**
```bash
SWAP_ARCH=files-only
SWAP_TOTAL_GB=64
SWAP_FILES=8
```

**Characteristics:**
- ✅ Simple and predictable
- ✅ No CPU overhead
- ✅ Good for fast SSDs
- ❌ No compression benefits
- ❌ Slower than compressed alternatives
- ❌ More disk I/O

**Best for:** Very slow CPUs, compatibility requirements, high-endurance SSDs

### 5. ZFS Compressed Swap (zvol)

ZFS volume with built-in compression.

```
┌──────────────────┐
│   Applications   │
└────────┬─────────┘
         │
    ┌────▼────┐
    │   RAM   │
    └────┬────┘
         │
         ▼
    ┌───────────────┐
    │  ZFS zvol     │ ← Block device with compression
    │  (compressed) │   volblocksize = page size
    │   /dev/zvol/  │
    └───────────────┘
```

**Configuration:**
```bash
SWAP_ARCH=zfs-zvol
# Create zvol with correct block size
zfs create -V 64G \
    -o compression=zstd \
    -o volblocksize=4K \
    -o sync=always \
    -o primarycache=metadata \
    rpool/swap
mkswap /dev/zvol/rpool/swap
swapon /dev/zvol/rpool/swap
```

**Characteristics:**
- ✅ Integrated with ZFS
- ✅ Compression at block level
- ✅ Dataset management
- ✅ Snapshots (not recommended for swap)
- ❌ Requires ZFS
- ❌ **volblocksize must match page size** (typically 4K)
- ❌ Additional overhead

**Important:** Set `volblocksize=4K` to match the kernel page size and `vm.page-cluster` default. Mismatched block sizes cause inefficiency.

**Best for:** ZFS-native deployments, storage-focused systems

### 6. ZRAM + ZFS zvol (Not Recommended)

Double compression layer (inefficient).

```
┌──────────────────┐
│   Applications   │
└────────┬─────────┘
         │
    ┌────▼────┐
    │   RAM   │
    └────┬────┘
         │
    ┌────▼──────┐
    │   ZRAM    │ ← First compression
    └────┬──────┘
         │ (overflow)
         │ Decompress → Then ZFS compresses again!
         ▼
    ┌───────────────┐
    │  ZFS zvol     │ ← Second compression
    │  (compressed) │
    └───────────────┘
```

**Characteristics:**
- ❌ **Double compression work** (decompress from ZRAM, then compress for ZFS)
- ❌ High CPU overhead
- ❌ Complex debugging
- ❌ Marginal space savings
- ✅ Maximum compression ratio (research only)

**Best for:** Research, testing extreme compression scenarios. **Not recommended for production.**

## ZRAM Deep Dive

### How ZRAM Works

ZRAM creates a compressed block device in RAM. Pages swapped to ZRAM are compressed and stored in memory, providing:
- Effective memory expansion (1.5-3x depending on data)
- Zero disk I/O latency
- Transparent operation

### ZRAM Allocators

ZRAM supports three allocators with different compression ratios and memory overhead:

| Allocator   | Typical Ratio | Memory Overhead | Use Case                          |
|-------------|---------------|-----------------|-----------------------------------|
| **zsmalloc** | ~90%          | Low (~5%)       | **Default, best for most cases**  |
| **z3fold**   | ~75%          | Medium (~10%)   | Balance of ratio and speed        |
| **zbud**     | ~50%          | High (~15%)     | Maximum speed, minimum complexity |

**zsmalloc** (default):
- Best compression density
- More complex allocator
- Slightly slower than zbud
- **Recommended for most deployments**

**z3fold**:
- Middle ground option
- Three pages per allocation unit
- Better speed than zsmalloc
- Moderate memory overhead

**zbud**:
- Simplest allocator
- Two pages per allocation unit
- Fastest allocation/deallocation
- Wastes more memory
- Use only when CPU is critical bottleneck

**Setting allocator:**
```bash
# At module load
modprobe zram allocator=zsmalloc

# Or via module parameter
echo "options zram allocator=zsmalloc" > /etc/modprobe.d/zram.conf
```

### Same-Page Deduplication

ZRAM has a `same_pages` counter, but it's **not** a general deduplication feature:

**What it does:**
- Detects and deduplicates **zero-filled pages only**
- Single reference stored for all identical zero pages
- Extremely efficient storage

**What it doesn't do:**
- Does NOT deduplicate arbitrary identical content
- Does NOT scan for duplicate non-zero pages
- Not a KSM (Kernel Same-page Merging) replacement

**How common are zero pages?**

| Scenario                  | Typical Zero Pages |
|---------------------------|--------------------|
| Fresh VM boot             | 30-60%             |
| After heavy memory use    | 10-30%             |
| Java applications         | 10-30%             |
| Databases                 | 5-20%              |
| File servers              | 15-40%             |
| Build systems             | 20-40%             |

Zero pages come from:
- Newly allocated memory (calloc, zero-initialized)
- Memory cleared for security
- Sparse data structures
- Memory freed and zeroed by kernel

**Viewing same_pages:**
```bash
cat /sys/block/zram0/mm_stat
# Column 6 is same_pages
```

### Compression Algorithms

Available algorithms vary by kernel version:

| Algorithm | Speed      | Ratio  | CPU   | Best For                    |
|-----------|------------|--------|-------|-----------------------------|
| **lz4**   | Very Fast  | ~2.5x  | Low   | Fast CPUs, latency-critical |
| **zstd**  | Fast       | ~3.0x  | Med   | **Balanced (recommended)**  |
| **lzo-rle** | Fast     | ~2.3x  | Low   | Legacy compatibility        |
| **lzo**   | Fast       | ~2.2x  | Low   | Older kernels               |

**For low RAM systems (1-2GB):** Prefer **zstd** for better compression ratio even if CPU is slow. The memory savings outweigh the CPU cost.

**Checking available algorithms:**
```bash
cat /sys/block/zram0/comp_algorithm
# [lz4] lzo lzo-rle zstd
# Brackets indicate current selection
```

### ZRAM Configuration Example

```bash
# Load module with allocator
modprobe zram allocator=zsmalloc

# Create device
echo zstd > /sys/block/zram0/comp_algorithm
echo 2G > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0  # High priority

# Check status
zramctl
cat /sys/block/zram0/mm_stat
```

### ZRAM Memory Accounting

ZRAM memory usage from `/sys/block/zram0/mm_stat`:

```
Column 1: orig_data_size    - Original uncompressed data size
Column 2: compr_data_size   - Compressed data size
Column 3: mem_used_total    - Total memory used (includes metadata)
Column 4: mem_limit         - Memory limit (0 = no limit)
Column 5: mem_used_max      - Peak memory usage
Column 6: same_pages        - Number of deduplicated zero pages
Column 7: pages_compacted   - Pages freed by compaction
```

**Compression ratio calculation:**
```bash
ratio=$(echo "scale=2; $orig_data_size / $compr_data_size" | bc)
```

## ZSWAP Deep Dive

### How ZSWAP Works

ZSWAP is a **cache** between RAM and disk swap. Unlike ZRAM (which is a swap device), ZSWAP transparently caches compressed pages:

1. **Swap-out:** Page compressed and stored in ZSWAP pool (RAM)
2. **On pool full:** Oldest pages written to backing swap device
3. **Swap-in:** Check ZSWAP cache first, then disk if needed

### Why ZSWAP is More Efficient for Disk-Backed Swap

**ZSWAP advantage:** Single compression cycle
```
RAM page → Compress → ZSWAP pool → (if evicted) → Write compressed to disk
```

**ZRAM + disk disadvantage:** Decompress→recompress cycle
```
RAM page → Compress → ZRAM device → (if full) → Decompress → Write to disk
```

**The key difference:** ZSWAP writes compressed pages directly to disk without decompression. ZRAM must decompress before writing to backing swap.

### ZSWAP Components

1. **Compression algorithm:** lz4, zstd, lzo-rle
2. **Allocator (zpool):** zbud, z3fold, zsmalloc
3. **Backing swap:** Disk-based swap files/partitions

**Allocator options (same as ZRAM):**
- **zsmalloc:** ~90% efficiency, best density
- **z3fold:** ~75% efficiency, balanced
- **zbud:** ~50% efficiency, fastest

### ZSWAP Configuration

```bash
# Enable ZSWAP
echo 1 > /sys/module/zswap/parameters/enabled

# Set compression algorithm
echo zstd > /sys/module/zswap/parameters/compressor

# Set allocator
echo zsmalloc > /sys/module/zswap/parameters/zpool

# Set pool size (% of RAM)
echo 20 > /sys/module/zswap/parameters/max_pool_percent

# View current settings
grep -r . /sys/module/zswap/parameters/
```

### ZSWAP Kernel Parameters

**Boot parameters for persistent configuration:**
```
zswap.enabled=1
zswap.compressor=zstd
zswap.zpool=zsmalloc
zswap.max_pool_percent=20
```

Add to `/etc/default/grub`:
```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet zswap.enabled=1 zswap.compressor=zstd zswap.zpool=zsmalloc zswap.max_pool_percent=20"
```

### ZSWAP Monitoring

```bash
# Check ZSWAP statistics
grep -r . /sys/kernel/debug/zswap/

# Key metrics:
pool_total_size         # Total compressed pool size
pool_pages              # Number of pages in pool
stored_pages            # Total pages ever stored
written_back_pages      # Pages evicted to disk
reject_*                # Various rejection reasons

# Writeback ratio (lower is better)
echo "scale=2; $(cat /sys/kernel/debug/zswap/written_back_pages) * 100 / $(cat /sys/kernel/debug/zswap/pool_pages)" | bc
```

### ZSWAP vs ZRAM Comparison

Both support the same allocators with same compression characteristics:

| Feature              | ZRAM                  | ZSWAP                    |
|----------------------|-----------------------|--------------------------|
| **Type**             | Block device          | Transparent cache        |
| **Backing**          | Optional (inefficient)| Required (efficient)     |
| **Compression**      | Yes                   | Yes                      |
| **Allocators**       | zsmalloc, z3fold, zbud| zsmalloc, z3fold, zbud   |
| **RAM-only**         | Excellent             | Good                     |
| **Disk-backed**      | Poor (decomp cycle)   | **Excellent (direct)**   |
| **Swap-in from RAM** | Very fast             | Very fast                |
| **Configuration**    | Block device setup    | Kernel parameters        |
| **Debugging**        | /sys/block/zramN      | /sys/kernel/debug/zswap  |

## ZRAM vs ZSWAP Memory-Only Comparison

Both technologies can provide memory compression. Here's a detailed comparison:

### Memory-Only Compression Efficiency

**Both ZRAM and ZSWAP** can use the same allocators with identical compression characteristics:

| Config           | Allocator  | Typical RAM Savings | Speed      | Recommendation       |
|------------------|------------|---------------------|------------|----------------------|
| ZRAM/ZSWAP       | zsmalloc   | ~2.5-3.0x          | Fast       | **Best default**     |
| ZRAM/ZSWAP       | z3fold     | ~2.0-2.5x          | Faster     | Balanced option      |
| ZRAM/ZSWAP       | zbud       | ~1.5-2.0x          | Fastest    | CPU-constrained      |

**Compression algorithm impact (same for both):**

| Algorithm | RAM Savings | CPU Cost | Best Use Case         |
|-----------|-------------|----------|-----------------------|
| lz4       | ~2.3x       | Low      | Latency-sensitive     |
| zstd      | ~3.0x       | Medium   | **General purpose**   |
| lzo-rle   | ~2.2x       | Low      | Legacy systems        |

### Memory-Only Decision Matrix

**Choose ZRAM when:**
- ✅ No disk-backed swap needed
- ✅ Working set fits in compressed RAM
- ✅ Want simple block device interface
- ✅ Need portable solution (easier to move between systems)

**Choose ZSWAP when:**
- ✅ Need disk-backed swap as safety net
- ✅ Want kernel to manage writeback automatically
- ✅ Prefer transparent caching behavior
- ✅ Better integration with existing swap files

**Memory-only performance: ZRAM ≈ ZSWAP** (same allocator + algorithm)

The primary difference is architectural:
- **ZRAM:** Self-contained block device
- **ZSWAP:** Cache layer requiring backing swap

## Swap-In Behavior and Metrics

### Understanding vmstat `si` (Swap-In)

The `si` counter in `vmstat` is **misleading** for ZSWAP systems:

```bash
vmstat 1
# si column shows ALL swap-ins, including:
# - ZSWAP RAM pool hits (NO disk I/O!)
# - Actual disk reads (real I/O)
```

**Problem:** You cannot distinguish between:
- Fast RAM-based ZSWAP hits
- Slow disk-based swap reads

### Better Metrics for "Working Set Too Large"

| Metric                    | What It Measures                     | How to Check                          | Good Values    |
|---------------------------|--------------------------------------|---------------------------------------|----------------|
| **pgmajfault**            | Page faults requiring disk I/O       | `grep pgmajfault /proc/vmstat`        | <100/sec       |
| **ZSWAP writeback ratio** | % pages evicted from ZSWAP to disk   | See calculation below                 | <1% ideal, <10% acceptable |
| **PSI full**              | % time ALL tasks stalled on memory   | `cat /proc/pressure/memory`           | 0.00 (none)    |
| **swap await**            | Average I/O wait time for swap       | `iostat -x 1 10 \| grep dm-`          | <10ms (SSD)    |
| **si + so rate**          | Swap-in/out pages per second         | `vmstat 1` (si + so columns)          | <1000/sec      |

### Metric Details

#### 1. pgmajfault (Most Reliable)

**What it is:** Page faults that required actual disk I/O

**Why it's reliable:** Unlike `si`, this ONLY counts disk reads

**How to monitor:**
```bash
# Watch in real-time
watch -n 1 "grep pgmajfault /proc/vmstat"

# Calculate rate
prev=$(grep pgmajfault /proc/vmstat | awk '{print $2}')
sleep 5
curr=$(grep pgmajfault /proc/vmstat | awk '{print $2}')
rate=$(( (curr - prev) / 5 ))
echo "Major faults/sec: $rate"
```

**Interpretation:**
- 0-10/sec: Excellent, no memory pressure
- 10-100/sec: Acceptable, minor pressure
- 100-1000/sec: Concerning, investigate
- >1000/sec: Critical, working set exceeds RAM

#### 2. ZSWAP Writeback Ratio

**What it is:** Percentage of ZSWAP pages evicted to disk

**Why it matters:** High writeback means ZSWAP pool is full and spilling to disk frequently

**How to calculate:**
```bash
#!/bin/bash
written_back=$(cat /sys/kernel/debug/zswap/written_back_pages)
pool_pages=$(cat /sys/kernel/debug/zswap/pool_pages)

if [ "$pool_pages" -gt 0 ]; then
    ratio=$(echo "scale=2; $written_back * 100 / $pool_pages" | bc)
    echo "Writeback ratio: ${ratio}%"
else
    echo "No pages in ZSWAP pool"
fi
```

**Interpretation:**
- <0.1%: Excellent, ZSWAP pool not under pressure
- 0.1-1%: Good, occasional writeback
- 1-10%: Acceptable, moderate pressure
- >10%: High pressure, consider increasing pool size

#### 3. PSI (Pressure Stall Information)

**What it is:** Direct measure of resource contention

**Why it's reliable:** Kernel directly tracks time processes spend stalled

**How to check:**
```bash
cat /proc/pressure/memory
# Output:
# some avg10=0.00 avg60=0.00 avg300=0.00 total=1234567
# full avg10=0.00 avg60=0.00 avg300=0.00 total=7654321
```

**Fields:**
- **some:** At least one task stalled on memory
- **full:** ALL tasks stalled on memory (critical!)
- **avgN:** Average pressure over N seconds
- **total:** Total microseconds of stall time

**Interpretation:**
- `full avg10=0.00`: Perfect, no memory stalls
- `full avg10=0.10`: 0.1% of time stalled (acceptable)
- `full avg10=1.00`: 1% of time stalled (investigate)
- `full avg10>5.00`: Critical memory pressure

#### 4. Swap Device Await (I/O Latency)

**What it is:** Average I/O wait time for swap devices

**Why it matters:** High await indicates slow swap I/O

**How to check:**
```bash
iostat -x 1 10
# Look at await column for swap devices
# Example output:
# Device  r/s   w/s   rkB/s   wkB/s  await  svctm  %util
# dm-1    5.2  12.3   20.8    49.2   8.3    2.1    15.2
```

**Interpretation (SSD):**
- <5ms: Excellent
- 5-10ms: Good
- 10-20ms: Acceptable
- >20ms: Slow, check device health

**Interpretation (HDD):**
- <10ms: Excellent
- 10-20ms: Good
- 20-50ms: Acceptable
- >50ms: Slow

### Monitoring Command Summary

```bash
# Quick health check script
#!/bin/bash

echo "=== Memory Pressure Indicators ==="

# 1. Major page faults (per second)
pgmajfault_prev=$(grep pgmajfault /proc/vmstat | awk '{print $2}')
sleep 1
pgmajfault_curr=$(grep pgmajfault /proc/vmstat | awk '{print $2}')
pgmajfault_rate=$((pgmajfault_curr - pgmajfault_prev))
echo "Major page faults: ${pgmajfault_rate}/sec"

# 2. ZSWAP writeback ratio (if available)
if [ -f /sys/kernel/debug/zswap/written_back_pages ]; then
    written_back=$(cat /sys/kernel/debug/zswap/written_back_pages)
    pool_pages=$(cat /sys/kernel/debug/zswap/pool_pages)
    if [ "$pool_pages" -gt 0 ]; then
        ratio=$(echo "scale=2; $written_back * 100 / $pool_pages" | bc)
        echo "ZSWAP writeback: ${ratio}%"
    fi
fi

# 3. PSI memory pressure
if [ -f /proc/pressure/memory ]; then
    full_pressure=$(grep "full avg10" /proc/pressure/memory | awk '{print $2}' | cut -d= -f2)
    echo "PSI full (10s avg): ${full_pressure}%"
fi

# 4. Swap device I/O
echo "Swap device I/O:"
iostat -x 1 2 | grep -A20 "^Device" | tail -10
```

## ZFS Compression

### How ZFS Stores Compressed Blocks

ZFS compresses blocks and stores them in the minimum number of sectors required.

**Example:**
- Page size: 4KB (default)
- Block size (volblocksize): 4KB
- Sector size: 512 bytes (typical)

**Compression example:**
```
Original block: 64KB
Compressed size: 19KB
Storage required: 19KB = 38 sectors of 512 bytes
Sectors used: 38 (not full 128 sectors for 64KB)
```

**ZFS automatically:**
1. Compresses the block
2. Calculates minimum sectors needed
3. Stores only required sectors
4. Maintains metadata for actual size

### volblocksize and vm.page-cluster Alignment

**Critical:** Set `volblocksize` to match kernel page size and I/O patterns:

```bash
# Default kernel page size
getconf PAGESIZE  # Usually 4096 (4KB)

# Default vm.page-cluster
sysctl vm.page-cluster  # Usually 3 (= 8 pages = 32KB I/O)

# For optimal alignment:
# Option 1: Match page size (most common)
zfs create -V 64G -o volblocksize=4K -o compression=zstd rpool/swap

# Option 2: Match vm.page-cluster I/O size
zfs create -V 64G -o volblocksize=32K -o compression=zstd rpool/swap
sysctl vm.page-cluster=3  # 3 = 32KB
```

**Recommendation:** Use 4K volblocksize for swap, as it matches page size and works efficiently with default settings.

### ZFS Compression Algorithms for Swap

| Algorithm | Ratio  | Speed      | CPU   | Recommendation          |
|-----------|--------|------------|-------|-------------------------|
| lz4       | ~2.3x  | Very Fast  | Low   | **Best for swap**       |
| zstd      | ~3.0x  | Fast       | Med   | Good if CPU available   |
| gzip-1    | ~2.5x  | Medium     | High  | Not recommended         |

**For swap, prefer lz4:** Speed is more critical than maximum compression ratio.

## Dynamic Sizing Recommendations

### Sizing Algorithm

The toolkit uses this algorithm:

```python
def calculate_swap_size(ram_gb, disk_free_gb):
    """
    Calculate optimal swap configuration
    """
    # Base calculation: 2-4x RAM depending on system size
    if ram_gb <= 2:
        swap_total = ram_gb * 4  # Small systems need more proportional swap
    elif ram_gb <= 8:
        swap_total = ram_gb * 2
    else:
        swap_total = ram_gb * 1.5
    
    # Cap at 30% of free disk space
    max_swap = disk_free_gb * 0.3
    swap_total = min(swap_total, max_swap)
    
    # Round to reasonable values
    swap_total = max(4, min(128, swap_total))
    
    return swap_total
```

### Complete Sizing Table

| RAM   | Disk Free | Swap Total | Files | Per-File | Architecture        | Rationale                           |
|-------|-----------|------------|-------|----------|---------------------|-------------------------------------|
| 512MB | 20GB      | 2GB        | 2     | 1GB      | zswap-files (zstd)  | Maximum compression for tiny RAM    |
| 1GB   | 30GB      | 4GB        | 4     | 1GB      | zswap-files (zstd)  | Compression critical, zstd for ratio|
| 2GB   | 40GB      | 8GB        | 4     | 2GB      | zswap-files (zstd)  | Still needs good compression        |
| 4GB   | 80GB      | 16GB       | 8     | 2GB      | zswap-files         | Balanced configuration              |
| 8GB   | 160GB     | 32GB       | 8     | 4GB      | zswap-files         | Good for most VPS workloads         |
| 16GB  | 320GB     | 64GB       | 8     | 8GB      | zswap-files/zram    | Either works well                   |
| 32GB  | 640GB     | 128GB      | 8     | 16GB     | zram-only           | Large RAM, use for cache            |
| 64GB+ | 1TB+      | 128GB      | 8     | 16GB     | zram-only or none   | Minimal swapping expected           |

### Architecture Selection Logic

```python
def select_architecture(ram_gb, disk_free_gb, cpu_speed):
    """
    Select optimal swap architecture
    """
    if ram_gb >= 32:
        return "zram-only"  # Sufficient RAM
    
    if ram_gb <= 2:
        # Low RAM systems need maximum compression
        return "zswap-files", {"compressor": "zstd", "allocator": "zsmalloc"}
    
    if cpu_speed < 2000:  # MHz
        # Slow CPU, but still worth compression if RAM is low
        if ram_gb <= 4:
            return "zswap-files", {"compressor": "zstd"}
        else:
            return "files-only"  # Skip compression overhead
    
    # Default: ZSWAP for most systems
    return "zswap-files", {"compressor": "lz4" if cpu_speed > 3000 else "zstd"}
```

## Monitoring and Tuning

### Essential Monitoring Commands

```bash
# 1. Overall memory state
free -h
cat /proc/meminfo

# 2. Swap device status
swapon --show
cat /proc/swaps

# 3. ZRAM status (if using ZRAM)
zramctl
cat /sys/block/zram0/mm_stat

# 4. ZSWAP status (if using ZSWAP)
grep -r . /sys/module/zswap/parameters/
grep -r . /sys/kernel/debug/zswap/

# 5. Kernel parameters
sysctl -a | grep vm.swap
sysctl -a | grep vm.page
sysctl -a | grep vm.vfs_cache_pressure

# 6. Swap activity
vmstat 1 10

# 7. Memory pressure
cat /proc/pressure/memory

# 8. Per-process swap usage
for pid in $(ps -eo pid --no-headers); do
    swap=$(awk '/VmSwap/{print $2}' /proc/$pid/status 2>/dev/null)
    if [ "$swap" -gt 0 ] 2>/dev/null; then
        cmd=$(ps -p $pid -o comm= 2>/dev/null)
        echo "$pid: ${swap}KB - $cmd"
    fi
done | sort -t: -k2 -n -r | head -20
```

### Tuning Parameters

#### vm.swappiness

Controls swap tendency:

```bash
# Current value
sysctl vm.swappiness

# Conservative (prefer RAM)
sysctl vm.swappiness=10

# Balanced (default)
sysctl vm.swappiness=60

# Aggressive (swap more)
sysctl vm.swappiness=100
```

**Recommendations:**
- **Desktop:** 10-20 (keep apps in RAM)
- **Server:** 60 (default, balanced)
- **Database:** 10-30 (avoid swapping working set)
- **Low RAM:** 80-100 (swap aggressively to free RAM)

#### vm.vfs_cache_pressure

Controls cache reclaim:

```bash
# Current value
sysctl vm.vfs_cache_pressure

# Prefer keeping cache
sysctl vm.vfs_cache_pressure=50

# Balanced (default)
sysctl vm.vfs_cache_pressure=100

# Aggressive cache reclaim
sysctl vm.vfs_cache_pressure=200
```

**Recommendations:**
- **File server:** 50 (keep caches)
- **General purpose:** 100 (default)
- **Memory constrained:** 200 (free cache aggressively)

#### vm.page-cluster

Covered earlier - controls swap I/O size.

### Making Changes Persistent

```bash
# Edit sysctl configuration
sudo nano /etc/sysctl.d/99-swap.conf

# Add parameters
vm.swappiness=60
vm.vfs_cache_pressure=100
vm.page-cluster=3

# Apply changes
sudo sysctl -p /etc/sysctl.d/99-swap.conf
```

## Performance Considerations

### CPU vs Memory Trade-offs

| Scenario                  | Recommendation                          |
|---------------------------|-----------------------------------------|
| Fast CPU + Low RAM        | Aggressive compression (zstd, zsmalloc) |
| Slow CPU + Low RAM        | Still compress (memory >> CPU)          |
| Fast CPU + High RAM       | Light compression (lz4, zram-only)      |
| Slow CPU + High RAM       | Minimal/no compression (files-only)     |

### Disk Speed Considerations

| Disk Type | vm.page-cluster | Architecture    | Notes                    |
|-----------|-----------------|-----------------|--------------------------|
| NVMe SSD  | 0-1             | zswap-files     | Low latency random I/O   |
| SATA SSD  | 1-2             | zswap-files     | Good random I/O          |
| HDD       | 2-3             | zswap-files     | Need sequential I/O      |
| Network   | 1-2             | zram-only       | Avoid network swap       |

### Workload-Specific Tuning

#### Web Server
```bash
vm.swappiness=30              # Keep working set in RAM
vm.vfs_cache_pressure=50      # Keep filesystem cache
vm.page-cluster=1             # Small I/O for responsiveness
# Use: zswap-files with lz4
```

#### Database
```bash
vm.swappiness=10              # Avoid swapping database
vm.vfs_cache_pressure=150     # Prioritize database cache
vm.page-cluster=0             # Minimize I/O latency
# Use: zram-only or files-only (avoid swap)
```

#### Build Server
```bash
vm.swappiness=60              # Allow swapping inactive processes
vm.vfs_cache_pressure=100     # Balance caches
vm.page-cluster=2             # Moderate I/O
# Use: zswap-files with zstd
```

#### File Server
```bash
vm.swappiness=10              # Keep apps in RAM
vm.vfs_cache_pressure=50      # Maximize file cache
vm.page-cluster=3             # Sequential reads
# Use: files-only (preserve CPU for I/O)
```

## Summary

### Quick Reference: When to Use Each Architecture

| Use Case                          | Architecture    | Key Parameters                      |
|-----------------------------------|-----------------|-------------------------------------|
| Low RAM (1-2GB), any CPU          | zswap-files     | zstd, zsmalloc, max_pool_percent=20 |
| Moderate RAM (4-8GB), fast CPU    | zswap-files     | lz4, z3fold, max_pool_percent=15    |
| High RAM (16GB+), fast CPU        | zram-only       | zstd, zsmalloc, 50% RAM             |
| Slow CPU, sufficient RAM          | files-only      | vm.page-cluster=3                   |
| ZFS system                        | zfs-zvol        | lz4, volblocksize=4K                |
| Development/testing               | zram-only       | Easy to reset                       |

### Critical Reminders

1. **SWAP_TOTAL_GB / SWAP_FILES = per-file size**
2. **vm.page-cluster controls I/O size, NOT striping**
3. **ZRAM same_pages only deduplicates zero-filled pages**
4. **ZRAM overflow requires decompress→recompress (inefficient)**
5. **ZSWAP writes compressed pages directly (efficient)**
6. **Don't rely on vmstat si alone** - use pgmajfault, PSI, writeback ratio
7. **Low RAM systems: prefer zstd for compression ratio**
8. **volblocksize should match page size (typically 4K)**

---

## References

- [Linux Kernel ZRAM Documentation](https://www.kernel.org/doc/html/latest/admin-guide/blockdev/zram.html)
- [Linux Kernel ZSWAP Documentation](https://www.kernel.org/doc/Documentation/vm/zswap.txt)
- [vm.txt - Linux Kernel Sysctl](https://www.kernel.org/doc/Documentation/sysctl/vm.txt)
- [PSI - Pressure Stall Information](https://www.kernel.org/doc/html/latest/accounting/psi.html)
- [ZFS on Linux Documentation](https://openzfs.github.io/openzfs-docs/)
