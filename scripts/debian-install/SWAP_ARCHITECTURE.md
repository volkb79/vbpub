# Swap Architecture - Technical Documentation

Comprehensive guide to Linux swap architectures, comparing different approaches for optimal memory management.

## Architecture Options

### 1. ZRAM Only

**Description:** Compressed RAM-only swap with no disk backing.

**How it works:**
- Creates compressed block device in RAM
- Pages are compressed before storing
- No disk I/O involved
- Limited by available memory

**Best for:**
- Systems with fast CPUs and limited RAM
- Development environments
- Workloads with good compression ratios

**Configuration:**
```bash
modprobe zram
echo lzo-rle > /sys/block/zram0/comp_algorithm
echo 2G > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon /dev/zram0 -p 100
```

---

### 2. ZRAM + Swap Files (Priority-based Tiering)

**Description:** Two-tier swap with fast ZRAM tier and slower disk tier.

**How it works:**
- ZRAM device with high priority (e.g., 100)
- Swap file(s) with lower priority (e.g., 10)
- Kernel fills high-priority swap first
- Falls back to disk when ZRAM is full

**Best for:**
- General-purpose servers
- Mixed workloads
- Systems needing both speed and capacity

**Configuration:**
```bash
# ZRAM tier (high priority)
echo lzo-rle > /sys/block/zram0/comp_algorithm
echo 2G > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon /dev/zram0 -p 100

# Disk tier (low priority)
fallocate -l 8G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile -p 10
```

---

### 3. ZRAM + Writeback (NEW - Kernel 4.14+)

**Description:** ZRAM with backing device for evicting cold pages.

**How it works:**
- ZRAM device backed by disk partition/file
- Cold pages are written to backing device
- **Writes DECOMPRESSED pages** to disk
- Pages are decompressed before writeback

**Pros:**
- Same-page deduplication (zero-filled pages)
- Efficient for repetitive data

**Cons:**
- CPU overhead: decompress on writeback
- Disk space: 1:1 ratio (no compression benefit)
- Less efficient than ZSWAP for disk usage

**Configuration:**
```bash
# Create backing device
fallocate -l 8G /zram-backing
losetup /dev/loop0 /zram-backing

# Setup ZRAM with writeback
modprobe zram
echo /dev/loop0 > /sys/block/zram0/backing_dev
echo lzo-rle > /sys/block/zram0/comp_algorithm
echo 2G > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon /dev/zram0 -p 100

# Enable writeback for idle pages
echo idle > /sys/block/zram0/writeback
```

**Note:** Requires kernel CONFIG_ZRAM_WRITEBACK=y

---

### 4. ZSWAP + Swap Files (RECOMMENDED)

**Description:** Compressed cache in front of swap files.

**How it works:**
- ZSWAP acts as compressed cache in RAM
- When cache is full, writes **COMPRESSED pages** directly to disk
- No decompression/recompression overhead
- Most efficient disk space usage

**Advantages over ZRAM + Writeback:**
- Writes compressed data to disk (2-3x space savings)
- No CPU overhead on writeback (already compressed)
- Better disk I/O efficiency
- Proven stability in production

**Best for:**
- **Production servers** (recommended)
- Systems with disk-backed swap
- Workloads requiring large swap capacity
- Cost-sensitive deployments

**Configuration:**
```bash
# Enable ZSWAP
echo 1 > /sys/module/zswap/parameters/enabled
echo lzo > /sys/module/zswap/parameters/compressor
echo z3fold > /sys/module/zswap/parameters/zpool
echo 20 > /sys/module/zswap/parameters/max_pool_percent

# Setup swap files
for i in {1..8}; do
    fallocate -l 1G /swapfile$i
    chmod 600 /swapfile$i
    mkswap /swapfile$i
    swapon /swapfile$i -p 10
done
```

---

### 5. Swap Files Only

**Description:** Traditional swap without compression.

**How it works:**
- Multiple swap files for I/O parallelization
- Kernel round-robins between equal-priority files
- No compression overhead
- Simple and predictable

**Best for:**
- Systems with slow CPUs
- Workloads with poor compression ratios
- Legacy applications
- Maximum compatibility

**Configuration:**
```bash
# Create 8x 1GB swap files
for i in {1..8}; do
    fallocate -l 1G /swapfile$i
    chmod 600 /swapfile$i
    mkswap /swapfile$i
    swapon /swapfile$i -p 10
done
```

---

### 6. ZFS zvol

**Description:** Native ZFS swap device with deduplication.

**How it works:**
- Create ZFS volume for swap
- Optional compression and deduplication
- Set volblocksize to match vm.page-cluster

**Best for:**
- Systems already using ZFS
- Workloads benefiting from deduplication

**Configuration:**
```bash
# Create ZFS zvol (volblocksize = vm.page-cluster * 4KB)
# Default page-cluster is 3, so 2^3 * 4KB = 32KB
# For better performance, use 64KB or 128KB
zfs create -V 8G -b 64K \
    -o compression=lz4 \
    -o sync=always \
    -o primarycache=metadata \
    -o secondarycache=none \
    rpool/swap

mkswap /dev/zvol/rpool/swap
swapon /dev/zvol/rpool/swap -p 10
```

**Important:** Set `volblocksize` (-b) to match page-cluster for optimal performance.

---

### 7. ZRAM + ZFS zvol

**Description:** ZRAM tier with ZFS backing (NOT RECOMMENDED).

**Why not recommended:**
- Double compression overhead: ZRAM compress → decompress → ZFS compress
- Decompress→recompress cycles waste CPU
- Little benefit over ZSWAP + ZFS

**Better alternative:** Use ZSWAP + ZFS instead
- ZSWAP writes compressed pages
- ZFS compresses again (but only once)
- No decompress→recompress cycles

---

## Comparison: ZRAM Writeback vs ZSWAP

| Aspect | ZRAM + Writeback | ZSWAP + Swap Files |
|--------|------------------|-------------------|
| **Disk write format** | Decompressed (raw pages) | Compressed pages |
| **CPU on writeback** | Must decompress first | None (already compressed) |
| **Disk space efficiency** | 1:1 (no benefit) | 2-3:1 (compressed) |
| **Same-page deduplication** | ✅ Yes (zero pages) | ❌ No |
| **Production ready** | ⚠️ Experimental | ✅ Stable |
| **Kernel requirement** | 4.14+ | 3.11+ |
| **Best use case** | Zero-heavy workloads | General production |

**Recommendation:** Use ZSWAP for production systems unless you have specific requirements for ZRAM writeback (e.g., extensive zero-page handling).

---

## ZRAM Allocators

ZRAM supports different memory allocators with varying efficiency:

### 1. **zsmalloc** (default, ~90% efficiency)
- Most efficient allocator
- Handles arbitrary object sizes well
- Recommended for production

### 2. **z3fold** (~75% efficiency)
- Stores up to 3 compressed pages per physical page
- Good balance between efficiency and simplicity
- Useful for ZSWAP

### 3. **zbud** (~50% efficiency)
- Stores up to 2 compressed pages per physical page
- Simplest allocator
- Lower memory efficiency but more predictable

**Usage:**
```bash
# ZRAM with allocator (implicit - zsmalloc is built-in)
modprobe zram

# ZSWAP with allocator
echo z3fold > /sys/module/zswap/parameters/zpool
```

---

## ZSWAP Zpools

ZSWAP supports three zpool implementations:

1. **zbud** - Default, 50% efficiency, simple
2. **z3fold** - 75% efficiency, better than zbud
3. **zsmalloc** - 90% efficiency, best (kernel 4.12+)

**Configuration:**
```bash
# Check available zpools
cat /sys/module/zswap/parameters/zpool
# Output: [zbud] z3fold zsmalloc

# Change to zsmalloc for best efficiency
echo zsmalloc > /sys/module/zswap/parameters/zpool
```

---

## Zero-Page Prevalence

Zero-filled pages are common in various workloads:

| Workload Type | Typical Zero-Page % | Notes |
|---------------|-------------------|-------|
| **Fresh VM** | 30-60% | Freshly allocated memory |
| **Java Applications** | 10-30% | Heap initialization |
| **Databases** | 5-15% | Mostly data, less zeros |
| **Containers** | 15-35% | Depends on image layers |
| **Desktop/GUI** | 20-40% | Graphics buffers |

**Important Clarification:**
- ZRAM `same_pages` counter **ONLY** handles zero-filled pages
- Does NOT deduplicate arbitrary identical content
- For identical content (e.g., same container images), use **KSM** (Kernel Same-page Merging)

**Check zero-page stats:**
```bash
# ZRAM statistics
cat /sys/block/zram0/mm_stat
# Fields: orig_data_size compr_data_size mem_used_total mem_limit mem_used_max same_pages pages_compacted huge_pages huge_pages_since_boot

# Calculate zero-page percentage
same_pages=$(awk '{print $6}' /sys/block/zram0/mm_stat)
total_pages=$(awk '{print $1/4096}' /sys/block/zram0/mm_stat)
echo "Zero pages: $same_pages / $total_pages ($(( same_pages * 100 / total_pages ))%)"
```

---

## Monitoring: CRITICAL CORRECTIONS

### The vmstat `si` Problem

**⚠️ vmstat `si` (swap-in) is MISLEADING for systems using ZSWAP!**

Why? Because `si` counts **ALL swap-ins**, including:
- ✅ Fast RAM pool hits (ZSWAP cache)
- ✅ Actual disk reads (slow)

This makes `si` useless for identifying disk I/O bottlenecks!

### Better Metrics

| Metric | Source | Meaning | Threshold |
|--------|--------|---------|-----------|
| **pgmajfault rate** | `/proc/vmstat` | Page faults requiring disk I/O | >100/s = concern |
| **ZSWAP writeback ratio** | `/sys/kernel/debug/zswap/` | written_back / stored_pages | >0.3 = pool too small |
| **PSI full avg10** | `/proc/pressure/memory` | % time stalled on memory | >5% = severe |
| **Swap partition await** | `iostat -x` | Disk latency for swap device | >10ms = slow |

### Monitoring Commands

```bash
# Monitor page faults (disk I/O required)
watch -n 1 'grep pgmajfault /proc/vmstat'

# ZSWAP statistics
cat /sys/kernel/debug/zswap/*

# PSI (Pressure Stall Information)
cat /proc/pressure/memory

# Swap device I/O (requires separate partition)
iostat -x 5 /dev/sda3  # adjust device
```

---

## Isolating Swap I/O from Application I/O

### Method 1: Use /proc/vmstat Swap-Specific Counters

```bash
# Swap-specific I/O (pages)
grep -E 'pswpin|pswpout' /proc/vmstat
```

**Counters:**
- `pswpin` - Pages swapped in from disk
- `pswpout` - Pages swapped out to disk

### Method 2: Use Separate Partition for Swap

```bash
# Create dedicated swap partition
mkswap /dev/sda3
swapon /dev/sda3 -p 10

# Monitor swap partition specifically
iostat -x 5 /dev/sda3
```

**Benefits:**
- Clear isolation in iostat output
- Easy to identify swap vs application I/O
- No mixing with root filesystem I/O

### Method 3: Use ZSWAP Writeback Counter

```bash
# Check how much ZSWAP wrote to disk
cat /sys/kernel/debug/zswap/written_back_pages
```

### Method 4: cgroups v2 Per-Service Monitoring

```bash
# Monitor specific service swap usage
cat /sys/fs/cgroup/system.slice/nginx.service/memory.swap.current
cat /sys/fs/cgroup/system.slice/nginx.service/memory.swap.max
```

---

## Dynamic Sizing Recommendations

### RAM-Based Sizing (1GB - 32GB)

| RAM Size | ZRAM/ZSWAP Pool | Swap Files | Total Capacity |
|----------|----------------|------------|----------------|
| 1-2 GB | 512 MB | 2 GB | 2.5 GB |
| 2-4 GB | 1 GB | 4 GB | 5 GB |
| 4-8 GB | 1.5 GB | 6 GB | 7.5 GB |
| 8-16 GB | 2 GB | 8 GB | 10 GB |
| 16-32 GB | 3 GB | 12 GB | 15 GB |

### Disk-Based Constraints (30GB - 1TB)

| Disk Size | Max Swap | Recommendation |
|-----------|----------|----------------|
| 30-50 GB | 4 GB | Conservative |
| 50-100 GB | 8 GB | Standard |
| 100-250 GB | 16 GB | Generous |
| 250-500 GB | 24 GB | Large |
| 500+ GB | 32 GB | Maximum |

### Number of Swap Files

**Recommendation: 8 swap files**

**Why?**
- Parallelizes I/O across files
- Equal priority = kernel round-robins
- Balance: 8 files good for parallelism without overhead
- Each file size = SWAP_TOTAL_GB / SWAP_FILES

**Example:**
- Total: 8 GB swap
- Files: 8
- Per-file: 1 GB each

---

## Kernel Parameters

### Important sysctl Settings

```bash
# Swappiness (0-100, default 60)
# Lower = prefer RAM, Higher = more aggressive swap
vm.swappiness = 10  # Recommended for servers

# Page cluster (0-9, default 3)
# Number of pages to swap in/out at once: 2^value
# Higher = better throughput, more I/O per operation
vm.page-cluster = 3  # 2^3 = 8 pages (32KB)

# VFS cache pressure (default 100)
# Higher = reclaim caches more aggressively
vm.vfs_cache_pressure = 50  # Keep caches longer

# Dirty ratios (for swap file I/O)
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
```

### Apply at Boot

Add to `/etc/sysctl.d/99-swap.conf`:
```ini
vm.swappiness = 10
vm.page-cluster = 3
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
```

---

## Compression Algorithms

Different algorithms offer varying speed/ratio tradeoffs:

| Algorithm | Speed | Ratio | CPU Usage | Best For |
|-----------|-------|-------|-----------|----------|
| **lzo** | Fast | Good | Low | General use |
| **lzo-rle** | Fastest | Good | Lowest | Zero-heavy |
| **lz4** | Very Fast | Good | Low | Modern CPUs |
| **zstd** | Medium | Best | Medium | Balanced |
| **deflate** | Slow | Better | High | High compression |

**Check available:**
```bash
cat /sys/block/zram0/comp_algorithm
# Output: lzo [lzo-rle] lz4 lz4hc 842 zstd
```

**Recommendation:** Use **lzo-rle** or **lz4** for best performance/ratio balance.

---

## Performance Tips

1. **Use ZSWAP for production** - Most reliable and efficient
2. **Use 8 swap files** - Good parallelism without overhead
3. **Set vm.swappiness = 10** - Prefer RAM over swap
4. **Monitor with pgmajfault** - Not vmstat si!
5. **Use separate swap partition** - Easy isolation in iostat
6. **Match ZFS volblocksize** - Align with page-cluster
7. **Enable PSI** - Best indicator of memory pressure
8. **Consider KSM** - For identical container content

---

## Troubleshooting

### High swap usage but no performance impact
- Normal if ZSWAP/ZRAM is used
- Check `pgmajfault` rate, not just swap usage
- Monitor PSI for actual pressure

### Poor swap performance
- Check allocator efficiency (use zsmalloc)
- Verify compression algorithm (use lzo-rle or lz4)
- Monitor disk latency with iostat
- Consider more swap files for parallelism

### ZSWAP not activating
```bash
# Check if enabled
cat /sys/module/zswap/parameters/enabled

# Check pool allocation
grep -r . /sys/kernel/debug/zswap/

# Verify swap is active
swapon --show
```

### ZRAM writeback not working
```bash
# Requires kernel support
grep ZRAM_WRITEBACK /boot/config-$(uname -r)

# Check backing device
cat /sys/block/zram0/backing_dev

# Verify writeback was triggered
cat /sys/block/zram0/bd_stat
```

---

## References

- [Kernel ZRAM documentation](https://www.kernel.org/doc/Documentation/blockdev/zram.txt)
- [ZSWAP documentation](https://www.kernel.org/doc/Documentation/vm/zswap.rst)
- [Memory management parameters](https://www.kernel.org/doc/Documentation/admin-guide/sysctl/vm.rst)
- [PSI documentation](https://facebookmicrosites.github.io/psi/)

---

## Version History

- **v1.0** - Initial comprehensive documentation
- Covers all 7 architecture options
- Includes ZRAM writeback vs ZSWAP comparison
- Documents all allocators and zpools
- Corrects vmstat si monitoring issues
- Provides dynamic sizing recommendations
