# Swap Architecture - Technical Deep Dive

Comprehensive technical documentation for swap configuration on Debian 12/13 systems.

## Table of Contents

1. [Swap Fundamentals](#1-swap-fundamentals)
2. [Architecture Options](#2-architecture-options)
   - [Option 1: ZRAM Only](#option-1-zram-only)
   - [Option 2: ZRAM + Swap Files (Two-Tier)](#option-2-zram--swap-files-two-tier)
   - [Option 3: ZSWAP + Swap Files (Recommended)](#option-3-zswap--swap-files-recommended)
   - [Option 4: Swap Files Only](#option-4-swap-files-only)
   - [Option 5: ZFS Compressed Swap (zvol)](#option-5-zfs-compressed-swap-zvol)
   - [Option 6: ZRAM + ZFS zvol](#option-6-zram--zfs-zvol)
   - [Option 7: Compressed Swap File Alternatives](#option-7-compressed-swap-file-alternatives)
3. [ZRAM Deep Dive](#3-zram-deep-dive)
4. [ZSWAP Deep Dive](#4-zswap-deep-dive)
5. [ZRAM vs ZSWAP Memory-Only Comparison](#5-zram-vs-zswap-memory-only-comparison)
6. [Swap-In Behavior Explanation](#6-swap-in-behavior-explanation)
7. [ZFS Compression Storage](#7-zfs-compression-storage)
8. [Compressed Swap File Alternatives](#8-compressed-swap-file-alternatives)
9. [Monitoring and Tuning](#9-monitoring-and-tuning)
10. [KSM Section](#10-ksm-section)
11. [DAMON/DAMO Memory Profiling](#11-damondamo-memory-profiling)

---

## 1. Swap Fundamentals

### What is Swap?

Swap is a mechanism that extends physical RAM by using disk storage for less frequently accessed memory pages. The Linux kernel moves inactive pages from RAM to swap space, freeing RAM for active processes.

### Memory Pages

- **Page size:** 4KB on x86_64 systems (standard)
- **Page:** The smallest unit of memory management
- **Page frame:** Physical memory location holding a page
- **Page fault:** Exception when accessing unmapped memory

### Types of Page Faults

1. **Minor fault:** Page is in memory but not mapped to process
   - Fast recovery (microseconds)
   - Just updates page table

2. **Major fault (pgmajfault):** Page must be read from disk
   - Slow recovery (milliseconds)
   - Involves disk I/O
   - **This is what we monitor for real swap pressure!**

### vm.page-cluster Parameter

Controls how many **adjacent pages** are read/written in a single I/O operation:

```
vm.page-cluster = log2(number of pages)
```

| Value | Pages | I/O Size | Use Case |
|-------|-------|----------|----------|
| 0 | 1 | 4KB | Random access, SSD |
| 1 | 2 | 8KB | |
| 2 | 4 | 16KB | |
| 3 | 8 | 32KB | Balanced (SSDs) |
| 4 | 16 | 64KB | **Default** (HDDs) |
| 5 | 32 | 128KB | Sequential, HDD |

**Important:** This controls I/O size, NOT striping! Striping occurs via round-robin across equal-priority devices.

### Swap Priority

- Range: -1 to 32767 (higher = more preferred)
- Equal priority → round-robin allocation (striping)
- Different priority → fill higher priority first
- Default: -2 (lowest)

**Typical setup:**
- ZRAM: priority 100 (highest, in-memory)
- Swap files: priority 10 (lower, on-disk)

---

## 2. Architecture Options

### Option 1: ZRAM Only

**Memory-only compressed swap block device.**

```
┌─────────────────────────────────────┐
│          Physical RAM               │
│  ┌──────────────┐  ┌──────────────┐│
│  │  Active      │  │   ZRAM       ││
│  │  Memory      │  │  (compressed)││
│  │              │  │  Priority 100││
│  └──────────────┘  └──────────────┘│
└─────────────────────────────────────┘
```

**Configuration:**
```bash
SWAP_ARCH=1
ZRAM_SIZE_GB=4  # Typically 50% of RAM
ZRAM_COMPRESSOR=lz4  # or zstd, lzo-rle
ZRAM_ALLOCATOR=zsmalloc  # Best compression ratio
```

**Pros:**
- ✅ Fastest performance (no disk I/O)
- ✅ 2-3x RAM extension with compression
- ✅ Low latency (microseconds)
- ✅ No disk wear

**Cons:**
- ⚠️ Limited by physical RAM
- ⚠️ Data lost if ZRAM full (no overflow to disk)
- ⚠️ Not persistent across reboots
- ⚠️ CPU overhead for compression

**When to use:**
- VPS with limited disk space
- Systems where workload fits in compressed memory
- Temporary/ephemeral workloads
- SSD wear reduction

### Option 2: ZRAM + Swap Files (Two-Tier)

**Fast ZRAM tier with disk overflow.**

```
┌─────────────────────────────────────┐
│          Physical RAM               │
│  ┌──────────────┐  ┌──────────────┐│
│  │  Active      │  │   ZRAM       ││
│  │  Memory      │  │  Priority 100││
│  └──────────────┘  └──────┬───────┘│
└─────────────────────────────┼───────┘
                              │ FULL
                              │ Decompress
                              ↓
                    ┌──────────────────┐
                    │   Swap Files     │
                    │   (8 files)      │
                    │   Priority 10    │
                    │   Recompress     │
                    └──────────────────┘
```

**Configuration:**
```bash
SWAP_ARCH=2
ZRAM_SIZE_GB=2  # RAM tier
SWAP_TOTAL_GB=16  # Disk tier
SWAP_FILES=8
ZRAM_PRIORITY=100  # Higher
SWAP_PRIORITY=10   # Lower
```

**Pros:**
- ✅ Fast tier for hot data
- ✅ Disk overflow for cold data
- ✅ Better than swap-only
- ✅ Safety net prevents OOM

**Cons:**
- ⚠️ **Inefficient overflow:** decompress → disk → compress again
- ⚠️ Higher CPU usage during overflow
- ⚠️ Two-stage process increases latency
- ⚠️ ZRAM writeback feature (kernel 4.14+) can help but not widely used

**When to use:**
- Systems needing speed + capacity
- Workload has clear hot/cold data separation
- Acceptable CPU overhead
- Not recommended vs ZSWAP for most cases

### Option 3: ZSWAP + Swap Files (Recommended)

**Transparent compressed cache in front of swap files.**

```
┌─────────────────────────────────────┐
│          Physical RAM               │
│  ┌──────────────┐  ┌──────────────┐│
│  │  Active      │  │ ZSWAP Pool   ││
│  │  Memory      │  │ (compressed) ││
│  │              │  │ 20% RAM      ││
│  └──────────────┘  └──────┬───────┘│
└─────────────────────────────┼───────┘
                              │ FULL
                              │ Write compressed
                              ↓
                    ┌──────────────────┐
                    │   Swap Files     │
                    │   (8 files)      │
                    │   Store          │
                    │   compressed     │
                    └──────────────────┘
```

**Configuration:**
```bash
SWAP_ARCH=3  # DEFAULT RECOMMENDED
SWAP_TOTAL_GB=16
SWAP_FILES=8
ZSWAP_POOL_PERCENT=20  # 20% of RAM
ZSWAP_COMPRESSOR=lz4
```

**Pros:**
- ✅ **Single compression stage** (efficient!)
- ✅ Automatic writeback when pool full
- ✅ Transparent to applications
- ✅ Better for large working sets
- ✅ Stores compressed pages on disk
- ✅ Kernel handles everything automatically

**Cons:**
- ⚠️ Requires kernel 3.11+ (Debian 12/13 ✓)
- ⚠️ Pool size must be tuned correctly
- ⚠️ CPU overhead for compression

**When to use:**
- **Production systems** (recommended default)
- Working sets larger than RAM
- Database servers
- Web applications
- General purpose servers

**Why better than ZRAM + Files:**
- No decompress→recompress cycle on overflow
- Pages written to disk stay compressed
- Lower CPU overhead during memory pressure
- Better latency characteristics

### Option 4: Swap Files Only

**Traditional swap without compression.**

```
┌─────────────────────────────────────┐
│          Physical RAM               │
│  ┌──────────────────────────────────┤
│  │  Active Memory                   │
│  │                                  │
│  └──────────────────┬───────────────┘
└─────────────────────┼─────────────────┘
                      │ Direct write
                      ↓
            ┌──────────────────────┐
            │   Swap Files (8)     │
            │   2GB each = 16GB    │
            │   Priority 10        │
            │   Round-robin        │
            └──────────────────────┘
```

**Configuration:**
```bash
SWAP_ARCH=4
SWAP_TOTAL_GB=16
SWAP_FILES=8  # Enables concurrency
```

**Pros:**
- ✅ Simple, battle-tested
- ✅ No CPU overhead
- ✅ Predictable behavior
- ✅ Multiple files = concurrent I/O

**Cons:**
- ⚠️ No compression (uses more disk)
- ⚠️ Slower than compressed options
- ⚠️ Full disk I/O for all swapping

**When to use:**
- Ample disk space
- Low CPU availability
- Compression incompatible workloads
- Debugging/testing scenarios
- Legacy compatibility

### Option 5: ZFS Compressed Swap (zvol)

**ZFS volume with native compression.**

```
┌─────────────────────────────────────┐
│          Physical RAM               │
│  ┌──────────────────────────────────┤
│  │  Active Memory                   │
│  └──────────────────┬───────────────┘
└─────────────────────┼─────────────────┘
                      │ Write
                      ↓
            ┌──────────────────────┐
            │   ZFS zvol           │
            │   volblocksize=64k   │
            │   compression=lz4    │
            │   Single pass        │
            └──────────────────────┘
```

**Configuration:**
```bash
SWAP_ARCH=5
ZFS_POOL=tank
SWAP_TOTAL_GB=8
ZFS_COMPRESSOR=lz4  # or zstd
```

**Pros:**
- ✅ Single compression stage
- ✅ Integrated with ZFS
- ✅ ZFS benefits (checksums, snapshots)
- ✅ volblocksize=64k matches vm.page-cluster=4

**Cons:**
- ⚠️ Requires ZFS installed
- ⚠️ ZFS ARC competes for RAM
- ⚠️ More complex setup
- ⚠️ Pool must have space

**When to use:**
- Existing ZFS deployments
- Storage servers
- NAS systems
- Need ZFS features

**Important tuning:**
```bash
# Match volblocksize to page cluster
vm.page-cluster=4  → volblocksize=64k
vm.page-cluster=3  → volblocksize=32k
vm.page-cluster=2  → volblocksize=16k
```

### Option 6: ZRAM + ZFS zvol

**Double compression layer (generally not recommended).**

```
┌─────────────────────────────────────┐
│          Physical RAM               │
│  ┌──────────────┐  ┌──────────────┐│
│  │  Active      │  │   ZRAM       ││
│  │  Memory      │  │  Priority 100││
│  └──────────────┘  └──────┬───────┘│
└─────────────────────────────┼───────┘
                              │ Decompress
                              ↓
                    ┌──────────────────┐
                    │   ZFS zvol       │
                    │   compression=lz4│
                    │   Recompress!    │
                    └──────────────────┘
```

**Configuration:**
```bash
SWAP_ARCH=6
ZRAM_SIZE_GB=2
ZFS_POOL=tank
SWAP_TOTAL_GB=8
```

**Pros:**
- ✅ Maximum compression possibility
- ✅ Both tiers compressed

**Cons:**
- ⚠️ **Double compression overhead**
- ⚠️ **Decompress→recompress inefficiency**
- ⚠️ Higher CPU usage
- ⚠️ May not provide additional benefit
- ⚠️ Increased latency

**When to use:**
- Extreme memory constraints
- Experimental setups
- **Generally not recommended** - use ZSWAP + ZFS instead

### Option 7: Compressed Swap File Alternatives

**Custom compression solutions.**

#### SquashFS Loop Device

```bash
# Create compressed filesystem
mksquashfs /swapfile /swapfile.sqsh -comp lz4
# Mount as loop device
losetup /dev/loop0 /swapfile.sqsh
mkswap /dev/loop0
swapon /dev/loop0
```

**Pros:**
- ✅ Custom compression control
- ✅ Works without kernel modules

**Cons:**
- ⚠️ Read-only compression
- ⚠️ Complex setup
- ⚠️ Not optimized for swap

#### FUSE Compressors

Use FUSE to provide compression layer:
- compFUSEd
- fusecompress
- Custom FUSE implementations

**Cons:**
- ⚠️ User-space overhead
- ⚠️ Higher latency
- ⚠️ Less stable than kernel solutions

**When to use:**
- Testing/educational purposes
- Specific kernel limitations
- Custom requirements
- **Prefer ZSWAP/ZRAM for production**

---

## 3. ZRAM Deep Dive

### What is ZRAM?

ZRAM creates compressed block devices in RAM. Data written to ZRAM is compressed, allowing more data to fit in the same physical memory.

### Compression Allocators

ZRAM supports three memory allocators with different characteristics:

#### 1. zsmalloc (Default, ~90% efficiency)

**Best compression ratio, most complex.**

```
Memory overhead: ~6-12% of compressed size
Compression ratio: ~2.5-3.0x (typical)
```

**Pros:**
- ✅ Best space efficiency
- ✅ 90%+ memory utilization
- ✅ Good for low-RAM systems

**Cons:**
- ⚠️ More CPU overhead
- ⚠️ Complex allocation
- ⚠️ Fragmentation possible

**Configuration:**
```bash
modprobe zram num_devices=1
echo zsmalloc > /sys/block/zram0/comp_algorithm
echo lz4 > /sys/block/zram0/comp_algorithm
echo 2G > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0
```

#### 2. z3fold (~75% efficiency)

**Balanced approach - stores 3 compressed pages per physical page.**

```
Memory overhead: ~25% of compressed size
Compression ratio: ~2.0-2.5x (typical)
```

**Pros:**
- ✅ Lower CPU than zsmalloc
- ✅ Good compression
- ✅ Less fragmentation
- ✅ Simpler than zsmalloc

**Cons:**
- ⚠️ 25% memory overhead
- ⚠️ Not as efficient as zsmalloc

**Use case:** Balance between performance and compression.

#### 3. zbud (~50% efficiency)

**Simplest - stores 2 compressed pages per physical page.**

```
Memory overhead: ~50% of compressed size
Compression ratio: ~1.5-2.0x (typical)
```

**Pros:**
- ✅ Lowest CPU overhead
- ✅ Simplest implementation
- ✅ Fast allocation
- ✅ Minimal fragmentation

**Cons:**
- ⚠️ 50% memory overhead
- ⚠️ Lower compression effectiveness

**Use case:** CPU-constrained systems where speed > compression ratio.

### Same-Page Deduplication

**CRITICAL:** ZRAM same_pages counter **ONLY tracks zero-filled pages**, NOT arbitrary identical content!

```bash
# Check zero page statistics
cat /sys/block/zram0/mm_stat
# Column: same_pages (zero-filled pages)
```

**Common misconception:** Same_pages doesn't deduplicate identical non-zero pages.

**Reality:**
- ✅ Zero-filled pages: Deduplicated
- ❌ Identical non-zero pages: NOT deduplicated

**Zero page statistics:**
- Fresh VMs: 30-60% zero pages (freshly allocated memory)
- Running systems: 10-30% zero pages
- Java applications: 20-40% zero pages (large heaps)
- Databases: 5-15% zero pages (mostly data)

**For arbitrary content deduplication, use KSM** (Kernel Samepage Merging), but:
- ⚠️ Requires applications to use `MADV_MERGEABLE`
- ⚠️ Most applications DON'T use this
- ⚠️ KSM typically ineffective without explicit support

### ZRAM Writeback Feature

**Available since kernel 4.14+**

Allows ZRAM to write out cold pages to backing device (disk).

```bash
# Enable writeback
echo /dev/sda1 > /sys/block/zram0/backing_dev

# Trigger writeback
echo idle > /sys/block/zram0/writeback

# Check writeback stats
cat /sys/block/zram0/bd_stat
```

**Benefits:**
- Keeps hot data in ZRAM
- Moves cold data to disk
- Better than simple priority-based overflow

**Status:** Not widely used, ZSWAP preferred for production.

### ZRAM Statistics

```bash
cat /sys/block/zram0/mm_stat
# Fields:
# orig_data_size  - Original uncompressed size
# compr_data_size - Compressed size
# mem_used_total  - Total memory used (including overhead)
# mem_limit       - Memory limit (0 = no limit)
# mem_used_max    - Peak memory usage
# same_pages      - Zero-filled pages (deduplicated)
# pages_compacted - Pages compacted to reduce fragmentation
# huge_pages      - Incompressible huge pages
```

**Calculate compression ratio:**
```bash
orig=$(cat /sys/block/zram0/mm_stat | awk '{print $1}')
compr=$(cat /sys/block/zram0/mm_stat | awk '{print $2}')
ratio=$(echo "scale=2; $orig / $compr" | bc)
echo "Compression ratio: ${ratio}x"
```

---

## 4. ZSWAP Deep Dive

### What is ZSWAP?

ZSWAP is a compressed cache for swap pages. It sits between memory and swap devices, compressing pages before they go to disk.

**Key advantage:** Single compression stage!

### How ZSWAP Works

```
1. Page selected for swap-out
2. Compressed and stored in ZSWAP pool (RAM)
3. If pool full → write compressed page to disk
4. On swap-in:
   - If in pool → decompress from RAM (fast!)
   - If on disk → read and possibly cache in pool
```

### ZSWAP vs ZRAM Flow

**ZRAM overflow (inefficient):**
```
Memory → ZRAM compress → ZRAM full → decompress → disk write → compress again
                                                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                                    Double work!
```

**ZSWAP (efficient):**
```
Memory → ZSWAP compress → pool full → write compressed to disk
                                      ^^^^^^^^^^^^^^^^^^^^^^^^
                                      Single compression!
```

### Configuration Parameters

```bash
# Enable ZSWAP
echo 1 > /sys/module/zswap/parameters/enabled

# Set maximum pool size (% of RAM)
echo 20 > /sys/module/zswap/parameters/max_pool_percent

# Set compressor
echo lz4 > /sys/module/zswap/parameters/compressor

# Set zpool (allocator)
echo z3fold > /sys/module/zswap/parameters/zpool

# Accept new pages when pool full (writeback mode)
echo 1 > /sys/module/zswap/parameters/accept_threshold_percent
```

### ⚠️ IMPORTANT: Compressor Configuration via GRUB Does NOT Work for zstd

**Critical limitation:** Setting `zswap.compressor=zstd` via GRUB kernel command line parameters **does NOT work reliably**. This is because zstd is a kernel module that may not be loaded at the time ZSWAP initializes during early boot.

| Compressor | GRUB Boot Config | Systemd Config |
|------------|------------------|----------------|
| lz4 | ✅ Works | ✅ Works |
| lzo-rle | ⚠️ May fail | ✅ Works |
| zstd | ❌ Does NOT work | ✅ Works |

**Solution:** Use a systemd service to configure the compressor after boot:

```bash
# /etc/systemd/system/zswap-config.service
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

See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for detailed explanation.

### Compression Algorithms

| Algorithm | Speed | Ratio | CPU | Use Case |
|-----------|-------|-------|-----|----------|
| lz4 | ⚡⚡⚡ | 2.0-2.5x | Low | **Default, balanced** |
| zstd | ⚡⚡ | 2.5-3.5x | Medium | Better compression |
| lzo-rle | ⚡⚡⚡ | 2.0-2.3x | Low | Alternative to lz4 |
| lzo | ⚡⚡ | 2.0-2.5x | Low | Older alternative |
| 842 | ⚡⚡⚡ | 1.5-2.0x | Very Low | IBM POWER |

**Recommended:**
- General use: **lz4** (best speed/ratio balance)
- Low RAM: **zstd** (better compression)
- CPU constrained: **lz4** or **lzo-rle**

### Pool Sizing

```bash
# 20% default is good for most cases
ZSWAP_POOL_PERCENT=20

# Adjust based on workload:
# High memory pressure: 25-30%
# Low memory pressure: 10-15%
# Very tight RAM: 30-40%
```

**Calculation example:**
- 8GB RAM, 20% pool = 1.6GB pool
- With 2.5x compression = 4GB effective capacity
- Plus disk swap for overflow

### Writeback Ratio Monitoring

**Critical metric for ZSWAP effectiveness:**

```bash
pool_pages=$(cat /sys/kernel/debug/zswap/pool_pages)
written_back=$(cat /sys/kernel/debug/zswap/written_back_pages)
ratio=$(echo "scale=2; 100 * $written_back / $pool_pages" | bc)
```

**Interpretation:**
- **<1% (green):** Excellent! Most pages stay in compressed RAM
- **1-10% (yellow):** Good, minimal disk writeback
- **>10% (red):** High pressure, consider:
  - Increasing pool size
  - Adding more RAM
  - Optimizing applications

### ZSWAP Statistics

```bash
# View all ZSWAP stats
grep -r . /sys/kernel/debug/zswap/

# Key statistics:
pool_limit_hit     # Times pool was full
reject_reclaim_fail # Failed to make room
reject_alloc_fail  # Failed to allocate
reject_kmemcache_fail # Kernel cache failure
duplicate_entry    # Duplicate pages
pool_pages         # Pages in pool
stored_pages       # Total pages stored
written_back_pages # Pages written to disk
```

---

## 5. ZRAM vs ZSWAP Memory-Only Comparison

**When no disk backing is needed**, both ZRAM and ZSWAP can operate in memory-only mode. Here's how they compare:

### ZRAM Memory-Only

```bash
# Pure ZRAM setup
modprobe zram
echo lz4 > /sys/block/zram0/comp_algorithm
echo zsmalloc > /sys/block/zram0/mem_pool
echo 4G > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0
```

**Characteristics:**
- Block device approach
- Fixed "disk" size (memory backing)
- Direct swap device
- Hard limit on size

### ZSWAP Memory-Only

```bash
# ZSWAP without swap backing
echo 1 > /sys/module/zswap/parameters/enabled
echo 40 > /sys/module/zswap/parameters/max_pool_percent
# No swap devices activated = memory-only
```

**Characteristics:**
- Cache approach
- Dynamic pool sizing
- Percentage-based limit
- No swap device needed

### Performance Comparison

| Aspect | ZRAM | ZSWAP (no backing) |
|--------|------|-------------------|
| Latency | 10-50 μs | 10-50 μs |
| Throughput | Higher | Similar |
| CPU overhead | Lower (direct) | Slightly higher (cache) |
| Memory efficiency | Excellent with zsmalloc | Good |
| Failure mode | Blocks when full | Reclaims pages |

### Compression Algorithm Testing

Test different algorithms and allocators:

```bash
# ZRAM with different allocators
for alloc in zsmalloc z3fold zbud; do
    echo $alloc > /sys/block/zram0/mem_pool
    # Run benchmark
done

# Test compression algorithms
for comp in lz4 zstd lzo-rle; do
    echo $comp > /sys/block/zram0/comp_algorithm
    # Run benchmark
done
```

### Benchmark Metrics

The `benchmark.py` script includes tests for:

1. **Compression ratio** - achieved compression for different algorithms
2. **Latency** - time to compress/decompress
3. **Throughput** - pages per second
4. **CPU usage** - overhead during operation
5. **Memory efficiency** - effective capacity gained

**Example benchmark command:**
```bash
sudo ./benchmark.py --compare-memory-only \
  --test-compressors \
  --test-allocators \
  --output results.json
```

---

## 6. Swap-In Behavior Explanation

### The vmstat si Misconception

**CRITICAL:** `vmstat si` (swap-in) is **MISLEADING** for disk I/O!

```bash
$ vmstat 1
procs -----------memory---------- ---swap-- -----io----
 r  b   swpd   free   buff  cache   si   so    bi    bo
 1  0 524288  12345  67890 123456  100   50    10     5
                                    ^^^
                                    Counts RAM hits too!
```

**What `si` actually counts:**
- ✅ Decompression from ZSWAP pool (RAM) - **FAST**
- ✅ Reads from swap devices (disk) - **SLOW**
- ⚠️ **Mixes fast and slow operations!**

### Better Metrics

#### 1. pgmajfault - Real Disk I/O

```bash
# Monitor major page faults
vmstat -s | grep "pages paged in"

# Or watch in real-time
watch -n 1 'cat /proc/vmstat | grep pgmajfault'

# Per-process
grep pgmajfault /proc/[PID]/status
```

**Interpretation:**
- Rising pgmajfault = disk I/O happening
- Stable pgmajfault = ZSWAP serving from RAM
- High rate = working set > available memory

#### 2. ZSWAP Writeback Ratio

```bash
# Calculate writeback ratio
pool=$(cat /sys/kernel/debug/zswap/pool_pages)
writeback=$(cat /sys/kernel/debug/zswap/written_back_pages)
echo "scale=2; 100 * $writeback / $pool" | bc
```

**Color coding:**
- 🟢 <1%: Excellent
- 🟡 1-10%: Good  
- 🔴 >10%: High pressure

#### 3. PSI (Pressure Stall Information)

```bash
cat /proc/pressure/memory
some avg10=0.00 avg60=0.00 avg300=0.00 total=12345
full avg10=0.00 avg60=0.00 avg300=0.00 total=67890
     ^^^^
     This is what matters!
```

**Interpretation:**
- `some`: Some tasks stalled on memory
- `full`: **All** non-idle tasks stalled (critical!)
- `avgXX`: Average % of time stalled
- `full > 0`: System under severe memory pressure

#### 4. Swap Await

```bash
# Check swap I/O latency
iostat -x 1 | grep -A1 "^Device"
# Look for await column for swap devices
```

**Interpretation:**
- <1ms: SSD or ZSWAP RAM hits
- 1-5ms: Fast SSD
- 5-10ms: Regular SSD
- >10ms: HDD or heavy load

### Working Set Larger Than Memory Example

**Scenario:**
- 4GB Physical RAM
- 2GB ZSWAP pool (compressed capacity ~5GB)
- 16GB swap on disk
- Application working set: 10GB

**What happens:**

```
┌─────────────────────────────────────┐
│  4GB RAM - Active Working Set       │
│  Hot data: 4GB                      │
└─────────────────┬───────────────────┘
                  │
┌─────────────────▼───────────────────┐
│  ZSWAP Pool - Warm Data             │
│  ~2GB pool, ~5GB compressed         │
│  Warm data: 5GB                     │
└─────────────────┬───────────────────┘
                  │ POOL FULL
                  │ Writeback
┌─────────────────▼───────────────────┐
│  Disk Swap - Cold Data              │
│  Cold data: 1GB (10GB total - 9GB)  │
│  Causes pgmajfault when accessed    │
└─────────────────────────────────────┘
```

**Behavior:**

1. **Hot data** (frequently accessed): Stays in RAM
2. **Warm data** (occasionally accessed): Stays in ZSWAP pool
   - Swap-in from pool: **fast** (microseconds)
   - `vmstat si` increments
   - `pgmajfault` does NOT increment
3. **Cold data** (rarely accessed): Written to disk
   - Swap-in from disk: **slow** (milliseconds)
   - `vmstat si` increments
   - `pgmajfault` DOES increment ⚠️

**Signs of problem:**
- Rising pgmajfault rate
- High swap await (>10ms)
- PSI full > 0
- High writeback ratio (>10%)

**Solutions:**
1. Add more RAM
2. Increase ZSWAP pool (if room)
3. Optimize application memory usage
4. Add faster swap storage (NVMe)

---

## 7. ZFS Compression Storage

### How ZFS Compression Works

ZFS compresses data at the block level before writing to disk.

**Example: 64KB block compression**

```
Uncompressed page: 64KB (vm.page-cluster=4 → 16 pages × 4KB)
                    ↓
         [ZFS Compression (lz4)]
                    ↓
Compressed blocks: 19KB (3.37x ratio)
                    ↓
[Aligned to 4KB sectors]
                    ↓
Disk storage: 20KB (5 sectors × 4KB)
```

### volblocksize Tuning

**Critical:** Match volblocksize to vm.page-cluster!

```bash
vm.page-cluster=4 (default) → volblocksize=64k
vm.page-cluster=3           → volblocksize=32k
vm.page-cluster=2           → volblocksize=16k
```

**Why this matters:**

```
Mismatched (bad):
vm.page-cluster=4 → 64KB I/O requests
volblocksize=8k   → ZFS uses 8KB blocks
Result: 8 separate ZFS operations! (slow)

Matched (good):
vm.page-cluster=4 → 64KB I/O requests
volblocksize=64k  → ZFS uses 64KB blocks
Result: 1 ZFS operation! (fast)
```

### Creating ZFS Swap

```bash
# Create zvol with matching blocksize
zfs create -V 8G \
  -o compression=lz4 \
  -o sync=always \
  -o primarycache=metadata \
  -o secondarycache=none \
  -o volblocksize=64k \
  tank/swap

# Make it swap
mkswap /dev/zvol/tank/swap
swapon -p 10 /dev/zvol/tank/swap
```

### ZFS ARC Tuning

ZFS ARC (Adaptive Replacement Cache) competes with system memory:

```bash
# Limit ARC to prevent memory competition
echo 2147483648 > /sys/module/zfs/parameters/zfs_arc_max  # 2GB
```

**Recommended ARC limits for swap scenarios:**
- 8GB RAM: 1-2GB ARC
- 16GB RAM: 2-4GB ARC
- 32GB RAM: 4-8GB ARC

### Compression Ratios

Typical compression ratios for swap data:

| Data Type | lz4 | zstd | Notes |
|-----------|-----|------|-------|
| Zero pages | 1000:1 | 1000:1 | Nearly free |
| Text/code | 3-4:1 | 4-6:1 | Highly compressible |
| Heap data | 2-3:1 | 3-4:1 | Varies by application |
| Multimedia | 1.1-1.5:1 | 1.2-1.8:1 | Already compressed |
| Random | 1:1 | 1:1 | Incompressible |

**Average for typical workloads:** 2.5-3.0:1 with lz4

---

## 8. Compressed Swap File Alternatives

### SquashFS Loop Device

**Concept:** Use SquashFS compressed filesystem as backing for loop device.

```bash
# Create base swap file
dd if=/dev/zero of=/swapfile bs=1M count=8192

# Compress with SquashFS
mksquashfs /swapfile /swapfile.sqsh -comp lz4 -Xhc

# Setup loop device
losetup /dev/loop0 /swapfile.sqsh

# Make swap (on inner file, not loop device directly)
# This doesn't actually work well - educational only!
```

**Reality:** SquashFS is read-only, not suitable for swap!

### FUSE-based Compressors

#### compFUSEd

```bash
# Mount compressed filesystem
compFUSEd -o compression=lz4 /mnt/compressed /mnt/real

# Create swap in compressed mount
dd if=/dev/zero of=/mnt/compressed/swapfile bs=1M count=8192
mkswap /mnt/compressed/swapfile
swapon /mnt/compressed/swapfile
```

**Problems:**
- High latency (user-space)
- Context switching overhead
- Not optimized for swap workload
- Stability concerns

#### When to Consider

Only for:
- Testing/educational purposes
- Specific kernel limitations
- Custom compression needs
- Research projects

**For production: Use ZSWAP or ZRAM!**

### Why Kernel Solutions Win

| Feature | ZSWAP/ZRAM | FUSE/SquashFS |
|---------|------------|---------------|
| Latency | Microseconds | Milliseconds |
| Overhead | Minimal | High (context switch) |
| Stability | Excellent | Variable |
| Optimization | Swap-specific | General purpose |
| Maintenance | Kernel-supported | User-space project |

---

## 9. Monitoring and Tuning

### Print Current Defaults

**Always print kernel defaults BEFORE making changes!**

```bash
#!/bin/bash
echo "=== Current Kernel Swap Parameters ==="
sysctl vm.swappiness
sysctl vm.page-cluster
sysctl vm.vfs_cache_pressure
sysctl vm.watermark_scale_factor
sysctl vm.min_free_kbytes

echo ""
echo "=== ZSWAP Configuration ==="
cat /sys/module/zswap/parameters/enabled
cat /sys/module/zswap/parameters/max_pool_percent
cat /sys/module/zswap/parameters/compressor
cat /sys/module/zswap/parameters/zpool

echo ""
echo "=== Current Swap Devices ==="
swapon --show

echo ""
echo "=== Memory Status ==="
free -h
```

### Dynamic Sizing Table

**For RAM: 1GB to 32GB**

| RAM | Swap Size | ZSWAP Pool | ZRAM Size | Notes |
|-----|-----------|------------|-----------|-------|
| 1GB | 2GB | 300MB (30%) | 512MB | Use zstd + zsmalloc |
| 2GB | 4GB | 400MB (20%) | 1GB | Critical: max compression |
| 4GB | 4GB | 800MB (20%) | 2GB | Balanced |
| 8GB | 8GB | 1.6GB (20%) | 4GB | Standard setup |
| 16GB | 8GB | 3.2GB (20%) | 8GB | Less swap needed |
| 32GB | 8GB | 6.4GB (20%) | 16GB | Minimal swap |

**For Disk: 30GB to 1TB**

| Disk Size | Swap Limit | Reasoning |
|-----------|------------|-----------|
| <30GB | ZRAM only | Too constrained |
| 30-50GB | 4GB max | Preserve space |
| 50-100GB | 8GB max | Balanced |
| 100-500GB | 16GB max | Standard |
| 500GB-1TB | 32GB max | Ample space |
| >1TB | RAM size | Can match RAM for hibernation |

### Tuning Parameters

```bash
# Swappiness: how aggressively to use swap
# 0 = avoid swap except OOM
# 60 = default (balanced)
# 100 = aggressive swapping
sysctl -w vm.swappiness=60

# Page cluster: I/O size (2^n pages)
# Lower for SSD, higher for HDD
sysctl -w vm.page-cluster=3  # 32KB (SSD)
sysctl -w vm.page-cluster=4  # 64KB (HDD)

# Cache pressure: reclaim cache vs swap
# Lower = prefer keeping cache
# Higher = prefer freeing cache
sysctl -w vm.vfs_cache_pressure=100

# Watermark scale: how early to start reclaim
# Higher = more aggressive memory reclaim
sysctl -w vm.watermark_scale_factor=10
```

### Low RAM Systems (1-2GB)

**Special tuning for constrained systems:**

```bash
# Prefer zstd for better compression
ZSWAP_COMPRESSOR=zstd

# Use zsmalloc for best memory efficiency
ZRAM_ALLOCATOR=zsmalloc

# Larger pools
ZSWAP_POOL_PERCENT=30
ZRAM_SIZE_GB=1  # 50%+ of RAM

# More aggressive swapping
vm.swappiness=80

# Smaller I/O for random access
vm.page-cluster=2  # 16KB
```

### Monitoring Script Example

See `swap-monitor.sh` for complete implementation with:
- Memory overview
- ZRAM/ZSWAP status
- Compression ratios
- **pgmajfault tracking**
- **Writeback ratio with color coding**
- **PSI pressure monitoring**
- Per-process swap usage
- Continuous/once/JSON modes

---

## 10. KSM Section

### What is KSM?

Kernel Samepage Merging (KSM) scans memory for identical pages and merges them.

**CRITICAL LIMITATION:** Requires `MADV_MERGEABLE` flag!

### How KSM Works

```c
// Application must explicitly mark memory regions
madvise(ptr, size, MADV_MERGEABLE);
```

**Without MADV_MERGEABLE:** KSM cannot merge pages!

### Who Uses KSM?

**Applications that commonly use MADV_MERGEABLE:**
- ✅ QEMU/KVM virtual machines (automatic)
- ✅ Some container runtimes
- ✅ Redis with KSM patch
- ✅ Custom applications designed for KSM

**Applications that DON'T use it:**
- ❌ Most standard applications
- ❌ Databases (MySQL, PostgreSQL)
- ❌ Web servers (nginx, Apache)
- ❌ Java applications
- ❌ Python applications
- ❌ Node.js applications

### Testing KSM Effectiveness

```bash
# Run KSM trial script
sudo ./ksm-trial.sh

# Output example:
# Before: pages_shared=0, pages_sharing=0
# After 3 scans: pages_shared=150, pages_sharing=450
# Memory saved: ~1.2MB
# Recommendation: NOT effective (<2% savings)
```

### KSM Statistics

```bash
# Check KSM status
cat /sys/kernel/mm/ksm/run  # 0=off, 1=on

# View statistics
cat /sys/kernel/mm/ksm/pages_shared    # Unique pages
cat /sys/kernel/mm/ksm/pages_sharing   # Total deduplicated
cat /sys/kernel/mm/ksm/pages_unshared  # Checked but unique
cat /sys/kernel/mm/ksm/pages_volatile  # Changed during scan
```

**Memory saved calculation:**
```bash
shared=$(cat /sys/kernel/mm/ksm/pages_shared)
sharing=$(cat /sys/kernel/mm/ksm/pages_sharing)
saved=$((($sharing - $shared) * 4))  # KB
echo "Memory saved: ${saved}KB"
```

### When KSM Actually Helps

**Scenarios where KSM is effective:**

1. **Virtual machine hosts**
   - Multiple VMs with same OS
   - Identical kernel pages
   - Can save 20-40% memory

2. **Container orchestration**
   - Many identical container images
   - Shared libraries
   - Can save 10-20% memory

3. **Specific applications**
   - Redis with KSM support
   - Custom memory-intensive apps
   - Applications designed for KSM

**For typical servers:** KSM saves <1% memory, not worth the overhead!

### KSM Configuration

```bash
# Enable KSM
echo 1 > /sys/kernel/mm/ksm/run

# Scan aggressiveness (pages per scan)
echo 1000 > /sys/kernel/mm/ksm/pages_to_scan

# Sleep between scans (milliseconds)
echo 200 > /sys/kernel/mm/ksm/sleep_millisecs

# Disable KSM
echo 0 > /sys/kernel/mm/ksm/run
```

---

## 11. DAMON/DAMO Memory Profiling

### What is DAMON?

Data Access MONitor (DAMON) - kernel subsystem for monitoring data access patterns.

### Use Cases

1. **Working set analysis**
   - Identify hot vs cold memory regions
   - Determine actual memory requirements
   - Optimize memory allocation

2. **Memory optimization**
   - Find unused allocated memory
   - Detect memory leaks
   - Optimize cache sizes

3. **Proactive reclaim**
   - Identify cold pages for early eviction
   - Reduce memory pressure
   - Improve swap efficiency

### Installing DAMO

```bash
# Install DAMO (DAMON userspace tool)
pip3 install damo

# Or from source
git clone https://github.com/awslabs/damo
cd damo
sudo python3 setup.py install
```

### Basic Usage

```bash
# Record memory access patterns for 10 seconds
sudo damo record -o damon.data

# Analyze recording
sudo damo report heats --heatmap damon.data

# Show hot/cold regions
sudo damo report wss --plot wss.png damon.data
```

### Working Set Size Analysis

```bash
# Record specific process
sudo damo record -p $(pidof myapp) -o myapp.data

# Generate working set report
sudo damo report wss myapp.data

# Output example:
# Working Set Size: 2.3GB
# Hot region (>10 accesses/sec): 1.2GB
# Warm region (1-10 accesses/sec): 0.8GB
# Cold region (<1 access/sec): 0.3GB
```

**Interpretation:**
- Hot region: Keep in RAM
- Warm region: ZSWAP pool target
- Cold region: Swap to disk acceptable

### Memory Access Heatmap

```bash
# Generate heatmap
sudo damo report heats \
  --heatmap heatmap.png \
  --guide \
  damon.data
```

**Heatmap shows:**
- X-axis: Memory address ranges
- Y-axis: Time
- Color: Access frequency (hot = red, cold = blue)

### Proactive Reclaim

DAMON can trigger proactive reclaim of cold pages:

```bash
# Configure proactive reclaim scheme
sudo damo schemes \
  --access_rate 0 100 \  # 0-100% access rate
  --age 120 max \        # At least 120 seconds old
  --action pageout       # Swap out cold pages

# Apply scheme
sudo damo start
```

**Benefits:**
- Reduces sudden memory pressure
- Smooths out swap activity
- Prevents OOM situations

### Integration with Swap Configuration

**Use DAMON to optimize swap setup:**

1. **Profile workload**
   ```bash
   sudo damo record -o baseline.data
   ```

2. **Analyze working set**
   ```bash
   sudo damo report wss baseline.data
   # Shows: Working set = 6.5GB
   ```

3. **Configure swap accordingly**
   ```bash
   # If working set = 6.5GB, RAM = 4GB
   # Need: 6.5GB - 4GB = 2.5GB compressed capacity
   # With 2.5x compression: ~1GB pool
   ZSWAP_POOL_PERCENT=12  # 1GB on 8GB system
   SWAP_TOTAL_GB=8  # Safety margin for cold data
   ```

4. **Validate with monitoring**
   ```bash
   ./swap-monitor.sh
   # Check writeback ratio and pgmajfault
   ```

### DAMON Resources

- Kernel docs: https://www.kernel.org/doc/html/latest/admin-guide/mm/damon/
- DAMO project: https://github.com/awslabs/damo
- AWS blog: https://aws.amazon.com/blogs/opensource/damon-data-access-monitor/

---

## Summary

This technical documentation covers:

1. ✅ 7 architecture options with detailed analysis
2. ✅ ZRAM deep dive with 3 allocators
3. ✅ ZSWAP efficiency advantages
4. ✅ Correct monitoring metrics (pgmajfault, writeback ratio, PSI)
5. ✅ Same-page deduplication limitations (zero pages only)
6. ✅ KSM requirements and limitations (MADV_MERGEABLE)
7. ✅ Dynamic sizing for 1-32GB RAM and 30GB-1TB disk
8. ✅ Working set vs memory capacity examples
9. ✅ ZFS compression and volblocksize tuning
10. ✅ DAMON memory profiling integration

**For practical implementation, see:**
- `README.md` - User guide and quick start
- `setup-swap.sh` - Automated configuration
- `swap-monitor.sh` - Real-time monitoring
- `benchmark.py` - Performance testing
- `analyze-memory.sh` - System analysis

**Recommended defaults:**
- Architecture: Option 3 (ZSWAP + Swap Files)
- Swap files: 8 files for concurrency
- ZSWAP pool: 20% of RAM
- Compressor: lz4 (balanced)
- vm.page-cluster: 3 for SSD, 4 for HDD
