# Swap Architecture - Complete Technical Reference

This document provides comprehensive technical documentation for all swap architectures, mechanisms, and monitoring strategies supported by this toolkit.

## Table of Contents

1. [Architecture Options Overview](#architecture-options-overview)
2. [ZRAM Deep Dive](#zram-deep-dive)
3. [ZSWAP Deep Dive](#zswap-deep-dive)
4. [ZRAM Writeback Configuration](#zram-writeback-configuration)
5. [Allocator Comparison](#allocator-comparison)
6. [Same-page Deduplication](#same-page-deduplication)
7. [Memory Profiling with DAMON](#memory-profiling-with-damon)
8. [KSM Statistics and Usage](#ksm-statistics-and-usage)
9. [Monitoring Best Practices](#monitoring-best-practices)
10. [Isolating Swap I/O](#isolating-swap-io)
11. [Performance Optimization](#performance-optimization)

---

## Architecture Options Overview

### Comparison Table

| Architecture | Compression | Disk Backing | Complexity | RAM Efficiency | Disk I/O | Best For |
|-------------|-------------|--------------|------------|----------------|----------|----------|
| **ZRAM Only** | ✅ | ❌ | Low | High | None | Memory-only, temp workloads |
| **ZRAM + Files** | ✅ | ✅ | Medium | High | Medium | Predictable tiering |
| **ZRAM Writeback** | ✅ | ✅ | Medium | High | Low-Med | Integrated solution |
| **ZSWAP + Files** 🏆 | ✅ | ✅ | Low | High | Low | Production, VPS (RECOMMENDED) |
| **Files Only** | ❌ | ✅ | Low | N/A | High | Simple, ample disk I/O |
| **ZFS zvol** | ✅ | ✅ | High | Medium | Low | ZFS systems |
| **ZRAM + ZFS** | ✅✅ | ✅ | High | Medium | Low | Specific ZFS needs |

### 1. ZRAM Only (Memory-only)

**Description:** Compressed swap in RAM using block device interface.

**Configuration:**
```bash
# Load module
modprobe zram

# Set compression algorithm
echo lz4 > /sys/block/zram0/comp_algorithm

# Set size (e.g., 4GB)
echo 4G > /sys/block/zram0/disksize

# Format and enable
mkswap /dev/zram0
swapon -p 100 /dev/zram0
```

**Pros:**
- Very fast (RAM speeds)
- Good compression ratios (2-3x typical)
- No disk wear
- Simple setup

**Cons:**
- Limited by RAM size
- Memory pressure affects both app and swap
- No persistent storage
- OOM if ZRAM fills up

**Best For:**
- Systems with adequate RAM
- Temporary workloads
- Development/testing environments
- When disk I/O must be avoided

### 2. ZRAM + Swap Files (Priority-based Tiering)

**Description:** ZRAM with high priority (100) as first tier, disk swap files (priority 10) as fallback.

**Configuration:**
```bash
# ZRAM setup (high priority)
modprobe zram
echo lz4 > /sys/block/zram0/comp_algorithm
echo 4G > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0

# Swap files setup (lower priority)
for i in {1..8}; do
    fallocate -l 2G /swapfile$i
    chmod 600 /swapfile$i
    mkswap /swapfile$i
    swapon -p 10 /swapfile$i
done
```

**Pros:**
- Clear tiering (ZRAM fills first)
- Disk available for overflow
- Simple priority-based logic
- Good performance characteristics

**Cons:**
- Two separate systems to manage
- ZRAM must fill before disk swap used
- No automatic rebalancing
- Manual size tuning needed

**Best For:**
- Predictable workloads
- When clear tier separation desired
- Manual control preferred

### 3. ZRAM + Writeback ⭐ NEW (Built-in Disk Overflow)

**Description:** ZRAM with `CONFIG_ZRAM_WRITEBACK` support, providing automatic disk overflow.

**Key Difference:** **ZRAM writeback decompresses pages before writing to disk**, unlike ZSWAP which keeps pages compressed.

**Requirements:**
- Kernel 4.14+ with `CONFIG_ZRAM_WRITEBACK=y`
- Backing device (can be file, partition, or loop device)

**Configuration:**
```bash
# Create backing device (loop device from file)
fallocate -l 16G /var/swap/zram-backing
losetup /dev/loop0 /var/swap/zram-backing

# Setup ZRAM
modprobe zram
echo lz4 > /sys/block/zram0/comp_algorithm
echo 4G > /sys/block/zram0/disksize

# Configure writeback
echo /dev/loop0 > /sys/block/zram0/backing_dev

# Enable swap
mkswap /dev/zram0
swapon -p 100 /dev/zram0

# Trigger writeback (automatic in kernel, or manual)
echo idle > /sys/block/zram0/writeback      # Write idle pages to backing
echo huge > /sys/block/zram0/writeback      # Write incompressible pages
```

**Writeback Triggers:**
- `idle` - Pages not accessed for configured idle time
- `huge` - Incompressible pages (compression ratio < threshold)
- `huge_idle` - Both huge and idle
- Page-specific - `echo 0 > /sys/block/zram0/writeback` (page index)

**Monitoring:**
```bash
# Check writeback stats
cat /sys/block/zram0/bd_stat
# Output: bd_count bd_reads bd_writes

cat /sys/block/zram0/mm_stat
# Column 8: huge_pages (incompressible)
```

**Pros:**
- Integrated solution (one system)
- Automatic overflow management
- Kernel handles idle detection
- Can target incompressible pages

**Cons:**
- Decompresses before write (less space efficient than ZSWAP)
- More complex setup
- Requires kernel support
- Limited kernel version availability

**Best For:**
- Systems where integrated solution preferred
- When automatic management desired
- Kernel 4.14+ available

**Comparison with ZSWAP:**

| Feature | ZRAM Writeback | ZSWAP |
|---------|---------------|--------|
| Pages on disk | Decompressed | Compressed |
| Space efficiency | Lower | Higher |
| CPU on write | Decompress | Keep compressed |
| Integration | Block device | Transparent cache |
| Kernel version | 4.14+ | 3.11+ |

### 4. ZSWAP + Swap Files 🏆 RECOMMENDED (Default)

**Description:** Compressed cache (ZSWAP) in RAM, transparently in front of disk swap files.

**Configuration:**
```bash
# Enable ZSWAP
echo 1 > /sys/module/zswap/parameters/enabled
echo lz4 > /sys/module/zswap/parameters/compressor
echo z3fold > /sys/module/zswap/parameters/zpool
echo 25 > /sys/module/zswap/parameters/max_pool_percent

# Create swap files
for i in {1..8}; do
    fallocate -l 2G /swapfile$i
    chmod 600 /swapfile$i
    mkswap /swapfile$i
    swapon /swapfile$i
done
```

**Pros:**
- Transparent to applications
- Keeps pages compressed on disk writeback
- Automatic pool management
- LRU eviction of cold pages
- Most space-efficient for disk backing
- Wide kernel support (3.11+)

**Cons:**
- Requires understanding of pool sizing
- Pool can fill and cause writeback
- Some CPU overhead for compression

**Best For:**
- Production systems (RECOMMENDED)
- VPS environments
- Most use cases
- When disk backing needed

**Pool Sizing:**
- Default: 20% of RAM
- Recommended: 25-30% for VPS
- Monitor `written_back_pages / stored_pages` ratio
- If ratio > 0.3, increase pool size

### 5. Swap Files Only (Traditional)

**Description:** Standard disk-based swap without compression.

**Configuration:**
```bash
# Create multiple swap files for concurrency
for i in {1..8}; do
    fallocate -l 2G /swapfile$i
    chmod 600 /swapfile$i
    mkswap /swapfile$i
    swapon /swapfile$i
done
```

**Pros:**
- Simple and well-understood
- No CPU overhead
- Predictable behavior
- Wide compatibility

**Cons:**
- No compression (wastes space)
- Slower than RAM-based compression
- More disk I/O
- Disk wear on SSDs

**Best For:**
- Systems with ample disk I/O
- When simplicity preferred
- Legacy compatibility
- CPU-constrained systems

**Note:** Multiple files provide I/O concurrency, NOT striping. vm.page-cluster controls I/O size.

### 6. ZFS zvol (Advanced)

**Description:** ZFS zvol with native ZFS compression as swap device.

**Configuration:**
```bash
# Create zvol with correct block size
zfs create -V 16G \
    -o volblocksize=64k \
    -o compression=lz4 \
    -o sync=always \
    -o primarycache=metadata \
    -o secondarycache=none \
    tank/swap

# Enable swap
mkswap /dev/zvol/tank/swap
swapon /dev/zvol/tank/swap
```

**Important:** `volblocksize=64k` matches `vm.page-cluster=3` (8 pages × 4KB = 32KB, rounded up).

**Pros:**
- ZFS native compression
- ZFS data integrity features
- Snapshots (if desired)
- Integrated with ZFS pool

**Cons:**
- ZFS complexity
- CPU overhead (compression + ZFS)
- Memory overhead (ARC)
- Requires ZFS knowledge

**Best For:**
- Systems already using ZFS
- Advanced users
- When ZFS features needed

### 7. ZRAM + ZFS zvol (Hybrid)

**Description:** ZRAM (high priority) for hot pages, ZFS zvol (low priority) for cold pages.

**Configuration:**
```bash
# ZRAM setup
modprobe zram
echo lz4 > /sys/block/zram0/comp_algorithm
echo 4G > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0

# ZFS zvol setup
zfs create -V 16G -o volblocksize=64k -o compression=lz4 tank/swap
mkswap /dev/zvol/tank/swap
swapon -p 10 /dev/zvol/tank/swap
```

**Pros:**
- Fast ZRAM for hot data
- ZFS for cold data
- ZFS features available

**Cons:**
- **Double compression overhead** (ZRAM compresses, then ZFS compresses)
- Complex configuration
- High CPU usage
- Both systems to manage

**Best For:**
- Specific ZFS requirements only
- Generally NOT recommended (double compression waste)

---

## ZRAM Deep Dive

### Architecture

ZRAM creates a compressed block device in RAM:
```
[Application] → [Page Fault] → [ZRAM Block Device] → [Compressed Memory Pool]
```

### Compression Algorithms

| Algorithm | Speed | Ratio | CPU | Best For |
|-----------|-------|-------|-----|----------|
| **lz4** | Very Fast | 2-3x | Low | General use, default |
| **zstd** | Fast | 3-4x | Medium | Low RAM, better ratio |
| **lzo** | Fast | 2-3x | Low | Legacy compatibility |
| **lzo-rle** | Fast | 2-3x | Low | Similar to lzo |

**Recommendation:** Use `lz4` for most cases, `zstd` for low-RAM systems.

### Statistics (mm_stat)

```bash
cat /sys/block/zram0/mm_stat
```

Format: `orig_data_size compr_data_size mem_used_total mem_limit mem_used_max same_pages pages_compacted huge_pages huge_pages_since_boot`

**Key Metrics:**
- `orig_data_size`: Uncompressed data size
- `compr_data_size`: Compressed size
- `mem_used_total`: Total memory used (including metadata)
- `same_pages`: Zero-filled pages (not stored, counted separately)
- `huge_pages`: Incompressible pages

**Compression Ratio:** `orig_data_size / mem_used_total`

### Same-page Handling

ZRAM's `same_pages` counter **only tracks zero-filled pages**, not arbitrary identical content.

```bash
# Check zero-page count
cat /sys/block/zram0/mm_stat | awk '{print $6}'
```

Zero-page prevalence:
- Fresh VMs: 30-60%
- Java applications: 10-30%
- Database systems: 5-15%

For arbitrary same-page deduplication, use **KSM** (see below).

---

## ZSWAP Deep Dive

### Architecture

ZSWAP is a compressed cache in front of swap:

```
[Application] → [Page Fault] → [ZSWAP Cache] → [Swap Device]
                                    ↓ (eviction)
                               [Disk Swap]
```

### Key Advantage

**ZSWAP keeps pages compressed when writing to disk**, unlike ZRAM writeback which decompresses first.

```
ZSWAP:        Compressed in RAM → Compressed on Disk (more space efficient)
ZRAM WB:      Compressed in RAM → Decompressed on Disk (less efficient)
```

### Pool Management

ZSWAP uses an LRU (Least Recently Used) policy:
- Pool has max size (`max_pool_percent` of RAM)
- When full, LRU pages evicted to disk swap
- Hot pages stay in compressed pool
- Cold pages written to disk (still compressed!)

### Configuration Parameters

```bash
# Enable/disable
/sys/module/zswap/parameters/enabled

# Compression algorithm (lz4, zstd, lzo, lzo-rle)
/sys/module/zswap/parameters/compressor

# Memory allocator (zbud, z3fold, zsmalloc)
/sys/module/zswap/parameters/zpool

# Maximum pool size (% of RAM)
/sys/module/zswap/parameters/max_pool_percent

# Accept threshold (% compression ratio, default 90)
/sys/module/zswap/parameters/accept_threshold_percent
```

### Statistics

```bash
# Pool stats
cat /sys/kernel/debug/zswap/pool_total_size
cat /sys/kernel/debug/zswap/stored_pages
cat /sys/kernel/debug/zswap/written_back_pages

# Calculate writeback ratio
echo "scale=2; $(cat /sys/kernel/debug/zswap/written_back_pages) * 100 / $(cat /sys/kernel/debug/zswap/stored_pages)" | bc
```

**Writeback Ratio Interpretation:**
- < 10%: Pool sized well
- 10-30%: Acceptable, monitor
- > 30%: Pool too small, increase `max_pool_percent`

---

## ZRAM Writeback Configuration

### Detailed Setup

#### 1. Create Backing Device

Option A: File-backed loop device:
```bash
mkdir -p /var/swap
fallocate -l 16G /var/swap/zram-backing
losetup /dev/loop0 /var/swap/zram-backing
```

Option B: Dedicated partition:
```bash
# Use existing partition
# /dev/sda3 for example
```

#### 2. Configure ZRAM with Writeback

```bash
# Load module
modprobe zram

# Set algorithm and size
echo lz4 > /sys/block/zram0/comp_algorithm
echo 4G > /sys/block/zram0/disksize

# IMPORTANT: Set backing device BEFORE mkswap
echo /dev/loop0 > /sys/block/zram0/backing_dev

# Enable swap
mkswap /dev/zram0
swapon -p 100 /dev/zram0
```

#### 3. Configure Idle Detection

```bash
# Set idle time (in seconds, default 300)
echo 300 > /sys/block/zram0/idle_age

# Mark all pages as idle (for testing)
echo all > /sys/block/zram0/idle
```

#### 4. Trigger Writeback

Manual writeback:
```bash
# Write idle pages to backing device
echo idle > /sys/block/zram0/writeback

# Write incompressible (huge) pages
echo huge > /sys/block/zram0/writeback

# Write both idle and huge
echo huge_idle > /sys/block/zram0/writeback
```

Automatic writeback (kernel handles internally based on thresholds).

#### 5. Monitor Writeback

```bash
# Check backing device stats
cat /sys/block/zram0/bd_stat
# Format: bd_count bd_reads bd_writes

# Check overall stats
cat /sys/block/zram0/mm_stat
# Column 8: huge_pages count

# Check incompressible page ratio
HUGE=$(cat /sys/block/zram0/mm_stat | awk '{print $8}')
TOTAL=$(cat /sys/block/zram0/mm_stat | awk '{print $1/4096}')
echo "scale=2; $HUGE * 100 / $TOTAL" | bc
```

### Writeback Strategies

**1. Idle-based (Recommended):**
- Writes cold pages that haven't been accessed
- Preserves hot data in ZRAM
- Requires idle age configuration

**2. Huge-based:**
- Writes incompressible pages
- Frees ZRAM space for compressible data
- Good for mixed workloads

**3. Combined:**
- Writes pages that are both idle AND huge
- Most conservative approach
- Best space utilization

### Use Cases

**When to use ZRAM Writeback:**
- Kernel 4.14+ available
- Integrated solution preferred
- Automatic management desired
- CPU available for decompression

**When NOT to use:**
- Kernel < 4.14
- Space efficiency critical (use ZSWAP)
- CPU-constrained systems
- Simple configuration needed

---

## Allocator Comparison

Memory allocators (zpools) manage compressed pages in memory.

### zbud (50% efficiency)

**Architecture:** Stores at most 2 compressed pages per physical page.

**Characteristics:**
- Simple design
- Low fragmentation
- ~50% memory efficiency (wastes space)
- Fast allocation

**Formula:** Max storage = RAM × 2 (if compression is 4:1, net is 50% of original)

**Best For:**
- Legacy systems
- When simplicity needed
- NOT recommended for production

### z3fold (75% efficiency)

**Architecture:** Stores up to 3 compressed pages per physical page.

**Characteristics:**
- Balanced design
- Moderate complexity
- ~75% memory efficiency
- Good performance
- **RECOMMENDED for ZSWAP**

**Formula:** Max storage = RAM × 3 (if compression is 4:1, net is 75% of original)

**Best For:**
- Production systems (default)
- ZSWAP configurations
- Balanced performance/efficiency

### zsmalloc (90% efficiency)

**Architecture:** Variable-sized page management, stores compressed objects efficiently.

**Characteristics:**
- Complex design
- Minimal fragmentation
- ~90% memory efficiency
- Slightly higher overhead
- **RECOMMENDED for ZRAM**

**Formula:** Max storage ≈ RAM × (compression_ratio × 0.9)

**Best For:**
- ZRAM configurations
- Maximum space efficiency
- Low-RAM systems

### Comparison Table

| Allocator | Efficiency | Pages/Page | Fragmentation | Complexity | Best Use |
|-----------|-----------|------------|---------------|------------|----------|
| zbud | ~50% | 2 | Low | Low | Legacy only |
| z3fold | ~75% | 3 | Medium | Medium | ZSWAP (default) |
| zsmalloc | ~90% | Variable | Very Low | High | ZRAM |

### Recommendations

- **ZSWAP:** Use `z3fold` (default, good balance)
- **ZRAM:** Use `zsmalloc` (maximum efficiency)
- **Low RAM:** Use `zsmalloc` regardless
- **Legacy:** Only use `zbud` if required

---

## Same-page Deduplication

### ZRAM same_pages (Zero-filled Only)

ZRAM's `same_pages` counter only handles **zero-filled pages**, not arbitrary identical content.

```bash
# Check zero-page count
cat /sys/block/zram0/mm_stat | awk '{print $6}'
```

These pages are:
- Not stored at all
- Counted separately
- Recreated on read as zeros
- Very efficient (no memory used)

**Common sources of zero pages:**
- Fresh memory allocations
- Cleared data structures
- Sparse arrays
- Memory-mapped files with holes

### KSM (Kernel Same-page Merging)

For **arbitrary identical page deduplication**, use KSM.

KSM merges identical pages across the system:
```
[Process A Page X] ─┐
                     ├─→ [Single Shared Page] (Copy-on-Write)
[Process B Page Y] ─┘
```

**Common KSM opportunities:**
- Multiple VMs with same OS
- Containerized applications
- Similar application instances
- Shared libraries in memory

See [KSM Statistics and Usage](#ksm-statistics-and-usage) section for details.

---

## Memory Profiling with DAMON

**DAMON** (Data Access MONitor) is a kernel subsystem for memory access pattern analysis.

### Requirements

- Kernel with `CONFIG_DAMON=y`
- DAMO tool: `pip3 install damo`

Check kernel support:
```bash
ls /sys/kernel/mm/damon/ 2>/dev/null && echo "DAMON supported" || echo "DAMON not available"
```

### Installation

```bash
# Install DAMO
pip3 install damo

# Verify installation
damo version
```

### Basic Usage

#### 1. Record Memory Access Patterns

```bash
# Monitor physical memory (requires root)
sudo damo record --target_type=paddr --duration 60

# Monitor specific process
sudo damo record --target $(pidof myapp) --duration 60

# Output saved to damon.data by default
```

#### 2. Analyze Working Set

```bash
# Show working set size over time
sudo damo report wss --input damon.data

# Example output:
# time    size
# 0       2.1 GiB
# 5       2.3 GiB
# 10      2.5 GiB
```

**Working Set Size (WSS):** The amount of memory actively accessed in a time period.

Use this to:
- Size ZRAM/ZSWAP appropriately
- Identify memory leaks
- Understand memory access patterns

#### 3. Heat Map Analysis

```bash
# Show memory access heat map
sudo damo report heats --input damon.data

# Example: Shows hot (frequently accessed) vs cold regions
```

**Hot regions:** Frequently accessed, keep in RAM
**Cold regions:** Rarely accessed, good candidates for swap

#### 4. Access Pattern Analysis

```bash
# Show detailed access patterns
sudo damo report raw --input damon.data

# Custom reports
sudo damo report raw --input damon.data --format json > access_patterns.json
```

### Integration with Swap Decisions

#### Sizing ZRAM/ZSWAP

```bash
# Record for typical workload
sudo damo record --target_type=paddr --duration 300

# Analyze working set
sudo damo report wss --input damon.data

# Size ZRAM to 80-90% of average WSS
# Size ZSWAP pool to 20-30% of average WSS
```

#### Identifying Cold Memory

```bash
# Find cold memory regions
sudo damo report heats --input damon.data | grep -i cold

# These regions are good swap candidates
```

#### Optimizing Swappiness

```bash
# High hot/cold ratio → increase swappiness (be more aggressive)
# Low hot/cold ratio → decrease swappiness (be conservative)
```

### Advanced DAMON Usage

#### Custom Monitoring Schemes

```bash
# Create custom scheme
cat > damon_scheme.json << 'EOF'
{
  "access_pattern": {
    "sz_bytes": {"min": 4096, "max": 1073741824},
    "nr_accesses": {"min": 0, "max": 10},
    "age": {"min": 1000000, "max": 10000000}
  },
  "action": "stat"
}
EOF

sudo damo schemes --apply damon_scheme.json
```

#### Continuous Monitoring

```bash
# Start monitoring daemon
sudo damo start --target_type=paddr

# Check status
sudo damo status

# Stop monitoring
sudo damo stop
```

### Use Cases

1. **Initial System Sizing:**
   - Record typical workload
   - Analyze WSS
   - Size swap appropriately

2. **Performance Troubleshooting:**
   - Identify hot vs cold memory
   - Find unexpected access patterns
   - Detect memory leaks

3. **Optimization:**
   - Adjust swappiness based on patterns
   - Size ZRAM/ZSWAP pools
   - Identify KSM opportunities

4. **Capacity Planning:**
   - Understand memory growth trends
   - Predict future requirements
   - Optimize instance sizing

---

## KSM Statistics and Usage

**KSM** (Kernel Same-page Merging) deduplicates identical memory pages across the system.

### How KSM Works

1. Scans memory for identical pages
2. Merges identical pages into one shared page
3. Marks page as Copy-on-Write (COW)
4. On write, creates separate copy

### Statistics (/sys/kernel/mm/ksm/)

#### Key Counters

```bash
# Unique pages that have been merged
cat /sys/kernel/mm/ksm/pages_shared

# Total references to shared pages
cat /sys/kernel/mm/ksm/pages_sharing

# Pages scanned but found unique
cat /sys/kernel/mm/ksm/pages_unshared

# Pages too volatile to merge (changing too fast)
cat /sys/kernel/mm/ksm/pages_volatile

# Full scan time (milliseconds)
cat /sys/kernel/mm/ksm/full_scans
```

#### Calculate Memory Saved

```bash
PAGES_SHARED=$(cat /sys/kernel/mm/ksm/pages_shared)
PAGES_SHARING=$(cat /sys/kernel/mm/ksm/pages_sharing)

# Memory saved (in KB)
SAVED_KB=$(( ($PAGES_SHARING - $PAGES_SHARED) * 4 ))

# Convert to MB
SAVED_MB=$(echo "scale=2; $SAVED_KB / 1024" | bc)

echo "Memory saved by KSM: ${SAVED_MB} MB"
```

**Formula:** `(pages_sharing - pages_shared) × 4KB`

**Explanation:**
- `pages_shared`: Unique deduplicated pages taking up memory
- `pages_sharing`: Total references to those shared pages
- Difference: Pages that would exist without KSM
- Each page is 4KB

#### Interpretation

Example:
```
pages_shared: 1000
pages_sharing: 5000
Memory saved: (5000 - 1000) × 4KB = 16MB
```

This means:
- 5000 pages are referencing
- Only 1000 unique pages stored
- 4000 duplicate pages eliminated
- 16MB memory saved

### KSM Configuration

#### Enable KSM

```bash
# Start KSM
echo 1 > /sys/kernel/mm/ksm/run

# Set scan rate (pages per scan)
echo 100 > /sys/kernel/mm/ksm/pages_to_scan

# Set sleep time between scans (milliseconds)
echo 20 > /sys/kernel/mm/ksm/sleep_millisecs
```

#### Disable KSM

```bash
# Stop scanning and unmerge all pages
echo 2 > /sys/kernel/mm/ksm/run

# Stop scanning but keep existing merges
echo 0 > /sys/kernel/mm/ksm/run
```

#### Tuning Parameters

```bash
# Aggressive scanning (higher CPU, faster merging)
echo 1000 > /sys/kernel/mm/ksm/pages_to_scan
echo 10 > /sys/kernel/mm/ksm/sleep_millisecs

# Conservative scanning (lower CPU, slower merging)
echo 100 > /sys/kernel/mm/ksm/pages_to_scan
echo 100 > /sys/kernel/mm/ksm/sleep_millisecs
```

### Temporary KSM Testing Procedure

Test KSM effectiveness without permanent commitment:

```bash
#!/bin/bash
# temporary-ksm-test.sh

echo "=== KSM Temporary Test ==="

# 1. Record baseline
echo "1. Recording baseline memory usage..."
BASELINE_FREE=$(free -m | grep "^Mem:" | awk '{print $3}')
echo "   Current memory used: ${BASELINE_FREE} MB"

# 2. Enable KSM with aggressive settings
echo "2. Enabling KSM with aggressive settings..."
echo 1 > /sys/kernel/mm/ksm/run
echo 1000 > /sys/kernel/mm/ksm/pages_to_scan
echo 10 > /sys/kernel/mm/ksm/sleep_millisecs

# 3. Wait for scans
echo "3. Waiting for KSM to scan (120 seconds)..."
sleep 120

# 4. Check results
echo "4. KSM Results:"
PAGES_SHARED=$(cat /sys/kernel/mm/ksm/pages_shared)
PAGES_SHARING=$(cat /sys/kernel/mm/ksm/pages_sharing)
SAVED_KB=$(( ($PAGES_SHARING - $PAGES_SHARED) * 4 ))
SAVED_MB=$(echo "scale=2; $SAVED_KB / 1024" | bc)

echo "   Pages shared: $PAGES_SHARED"
echo "   Pages sharing: $PAGES_SHARING"
echo "   Memory saved: ${SAVED_MB} MB"

# 5. Calculate effectiveness
if [ $PAGES_SHARING -gt 0 ]; then
    EFFECTIVENESS=$(echo "scale=2; ($PAGES_SHARING - $PAGES_SHARED) * 100 / $PAGES_SHARING" | bc)
    echo "   Effectiveness: ${EFFECTIVENESS}%"
else
    echo "   Effectiveness: 0% (no pages merged)"
fi

# 6. Recommendation
if (( $(echo "$SAVED_MB > 100" | bc -l) )); then
    echo "5. Recommendation: KSM is effective, consider keeping enabled"
elif (( $(echo "$SAVED_MB > 20" | bc -l) )); then
    echo "5. Recommendation: KSM shows modest benefit, optional"
else
    echo "5. Recommendation: KSM benefit is minimal, disable to save CPU"
fi

# 7. Ask user
read -p "Keep KSM enabled? (y/N): " KEEP

if [[ ! "$KEEP" =~ ^[Yy]$ ]]; then
    echo "6. Disabling KSM and unmerging pages..."
    echo 2 > /sys/kernel/mm/ksm/run
    echo "   KSM disabled"
else
    echo "6. Keeping KSM enabled"
    # Set to moderate settings
    echo 200 > /sys/kernel/mm/ksm/pages_to_scan
    echo 20 > /sys/kernel/mm/ksm/sleep_millisecs
    echo "   Set to moderate scan settings"
fi
```

### When KSM is Worth the CPU Cost

**High Value Scenarios:**
- Multiple VMs with same OS/applications
- Many containers with similar images
- Replicated services (microservices)
- Development/testing environments

**Effectiveness Thresholds:**
- **> 10% memory saved:** Highly recommended
- **5-10% saved:** Worth considering
- **< 5% saved:** Probably not worth CPU cost

**CPU Impact:**
- Aggressive settings: 0.5-2% CPU constant
- Moderate settings: 0.1-0.5% CPU
- Conservative settings: < 0.1% CPU

### KSM Monitoring Script

```bash
#!/bin/bash
# watch-ksm.sh - Monitor KSM effectiveness

while true; do
    clear
    echo "=== KSM Statistics ==="
    echo "Time: $(date)"
    echo ""
    
    # Read stats
    SHARED=$(cat /sys/kernel/mm/ksm/pages_shared)
    SHARING=$(cat /sys/kernel/mm/ksm/pages_sharing)
    UNSHARED=$(cat /sys/kernel/mm/ksm/pages_unshared)
    VOLATILE=$(cat /sys/kernel/mm/ksm/pages_volatile)
    SCANS=$(cat /sys/kernel/mm/ksm/full_scans)
    
    # Calculate savings
    SAVED_MB=$(echo "scale=2; ($SHARING - $SHARED) * 4 / 1024" | bc)
    
    # Calculate ratio
    if [ $SHARING -gt 0 ]; then
        RATIO=$(echo "scale=2; ($SHARING - $SHARED) * 100 / $SHARING" | bc)
    else
        RATIO=0
    fi
    
    echo "Pages shared:    $SHARED"
    echo "Pages sharing:   $SHARING"
    echo "Pages unshared:  $UNSHARED"
    echo "Pages volatile:  $VOLATILE"
    echo "Full scans:      $SCANS"
    echo ""
    echo "Memory saved:    ${SAVED_MB} MB"
    echo "Dedup ratio:     ${RATIO}%"
    
    sleep 5
done
```

---

## Monitoring Best Practices

### The vmstat 'si' Problem

**Problem:** `vmstat`'s `si` (swap-in) column counts **ALL swap-ins**, including fast ZSWAP RAM hits.

```bash
# This is MISLEADING for disk I/O analysis
vmstat 1
# si column includes both RAM and disk swap-ins
```

**Why it's misleading:**
- ZSWAP swap-ins are from compressed RAM (very fast, <1ms)
- Disk swap-ins are from storage (slow, 1-10ms for SSD, 10-100ms for HDD)
- Lumping them together hides performance issues

### Better Metrics for Swap Monitoring

#### 1. /proc/vmstat Counters (Swap-specific)

```bash
# Monitor swap I/O (disk-specific)
watch -n 1 'grep -E "(pswpin|pswpout)" /proc/vmstat'

# pswpin:  Pages swapped IN from disk
# pswpout: Pages swapped OUT to disk
```

**Rate calculation:**
```bash
# Sample 1 second apart
BEFORE=$(grep pswpin /proc/vmstat | awk '{print $2}')
sleep 1
AFTER=$(grep pswpin /proc/vmstat | awk '{print $2}')
RATE=$(($AFTER - $BEFORE))
echo "Swap-in rate: $RATE pages/sec ($(($RATE * 4)) KB/sec)"
```

These counters represent actual disk I/O, not RAM-based swap.

#### 2. Major Page Faults (pgmajfault)

```bash
# Monitor major page faults (require disk I/O)
watch -n 1 'grep pgmajfault /proc/vmstat'

# pgmajfault: Pages that required disk I/O to resolve
```

**Interpretation:**
- High rate → Working set > available RAM
- Sustained high rate → System thrashing
- Correlates with performance degradation

#### 3. ZSWAP Writeback Ratio

```bash
# Check if ZSWAP pool is adequately sized
STORED=$(cat /sys/kernel/debug/zswap/stored_pages)
WRITTEN_BACK=$(cat /sys/kernel/debug/zswap/written_back_pages)

if [ $STORED -gt 0 ]; then
    RATIO=$(echo "scale=2; $WRITTEN_BACK * 100 / $STORED" | bc)
    echo "ZSWAP writeback ratio: ${RATIO}%"
    
    if (( $(echo "$RATIO > 30" | bc -l) )); then
        echo "WARNING: Pool too small, increase max_pool_percent"
    fi
fi
```

**Thresholds:**
- < 10%: Pool sized well
- 10-30%: Acceptable, monitor
- > 30%: Pool too small, increase size

#### 4. PSI (Pressure Stall Information)

```bash
# Check memory pressure
cat /proc/pressure/memory
# Output:
# some avg10=0.00 avg60=0.00 avg300=0.00 total=0
# full avg10=0.00 avg60=0.00 avg300=0.00 total=0
```

**Metrics:**
- `some`: Some tasks waiting for memory
- `full`: All tasks stalled (severe)
- `avgX`: Average pressure over X seconds
- `total`: Cumulative microseconds

**Thresholds:**
- `full avg10 > 5`: Severe memory pressure
- `full avg60 > 1`: Sustained pressure
- `some avg10 > 20`: Significant contention

#### 5. Per-Process Swap Usage

```bash
# Find processes using most swap
for pid in /proc/[0-9]*; do
    SWAP=$(awk '/^Swap:/ { sum+=$2 } END { print sum }' $pid/smaps 2>/dev/null)
    if [ "$SWAP" -gt 0 ]; then
        CMD=$(cat $pid/cmdline 2>/dev/null | tr '\0' ' ')
        echo -e "$SWAP\t$(basename $pid)\t$CMD"
    fi
done | sort -rn | head -20
```

### Complete Monitoring Dashboard

```bash
#!/bin/bash
# swap-dashboard.sh - Comprehensive swap monitoring

while true; do
    clear
    echo "=== SWAP MONITORING DASHBOARD ==="
    echo "Time: $(date)"
    echo ""
    
    # Memory overview
    echo "--- Memory Overview ---"
    free -h
    echo ""
    
    # Swap-specific I/O (NOT vmstat si!)
    echo "--- Swap I/O (Disk-specific) ---"
    PSWPIN=$(grep pswpin /proc/vmstat | awk '{print $2}')
    PSWPOUT=$(grep pswpout /proc/vmstat | awk '{print $2}')
    sleep 1
    PSWPIN_NOW=$(grep pswpin /proc/vmstat | awk '{print $2}')
    PSWPOUT_NOW=$(grep pswpout /proc/vmstat | awk '{print $2}')
    
    SWAPIN_RATE=$(($PSWPIN_NOW - $PSWPIN))
    SWAPOUT_RATE=$(($PSWPOUT_NOW - $PSWPOUT))
    
    echo "Swap-in rate:  $SWAPIN_RATE pages/sec ($(($SWAPIN_RATE * 4)) KB/sec)"
    echo "Swap-out rate: $SWAPOUT_RATE pages/sec ($(($SWAPOUT_RATE * 4)) KB/sec)"
    echo ""
    
    # Major page faults
    echo "--- Major Page Faults ---"
    PGMAJFAULT=$(grep pgmajfault /proc/vmstat | awk '{print $2}')
    sleep 1
    PGMAJFAULT_NOW=$(grep pgmajfault /proc/vmstat | awk '{print $2}')
    MAJFAULT_RATE=$(($PGMAJFAULT_NOW - $PGMAJFAULT))
    echo "Major faults: $MAJFAULT_RATE/sec"
    echo ""
    
    # ZSWAP stats (if available)
    if [ -d /sys/kernel/debug/zswap ]; then
        echo "--- ZSWAP Stats ---"
        STORED=$(cat /sys/kernel/debug/zswap/stored_pages 2>/dev/null || echo 0)
        WRITTEN=$(cat /sys/kernel/debug/zswap/written_back_pages 2>/dev/null || echo 0)
        POOL=$(cat /sys/kernel/debug/zswap/pool_total_size 2>/dev/null || echo 0)
        
        POOL_MB=$(echo "scale=2; $POOL / 1048576" | bc)
        echo "Pool size: ${POOL_MB} MB"
        echo "Stored pages: $STORED"
        echo "Written back: $WRITTEN"
        
        if [ $STORED -gt 0 ]; then
            RATIO=$(echo "scale=2; $WRITTEN * 100 / $STORED" | bc)
            echo "Writeback ratio: ${RATIO}%"
        fi
        echo ""
    fi
    
    # PSI pressure
    echo "--- Memory Pressure (PSI) ---"
    cat /proc/pressure/memory
    echo ""
    
    # Interpretation
    echo "--- Status ---"
    if [ $MAJFAULT_RATE -gt 100 ]; then
        echo "⚠️  HIGH DISK I/O: Major faults > 100/sec"
    elif [ $MAJFAULT_RATE -gt 20 ]; then
        echo "⚠️  MODERATE DISK I/O: Major faults > 20/sec"
    else
        echo "✅ Disk I/O: Normal"
    fi
    
    sleep 4
done
```

### Metrics Summary

| Metric | Source | What It Measures | When to Worry |
|--------|--------|------------------|---------------|
| pswpin | /proc/vmstat | Disk swap reads | > 100 pages/sec sustained |
| pswpout | /proc/vmstat | Disk swap writes | > 100 pages/sec sustained |
| pgmajfault | /proc/vmstat | Pages requiring disk I/O | > 50/sec sustained |
| ZSWAP writeback ratio | /sys/kernel/debug/zswap/ | Pool fullness | > 30% |
| PSI full avg10 | /proc/pressure/memory | Severe stalls | > 5 |
| vmstat si | vmstat output | ❌ MISLEADING (includes RAM hits) | Don't use for disk I/O |

---

## Isolating Swap I/O

**Problem:** `iostat` on root device includes both application I/O and swap I/O, making it hard to isolate swap-specific disk activity.

### Solutions

#### 1. Use /proc/vmstat Counters (Recommended)

```bash
# These are swap-only, no application I/O
watch -n 1 'grep -E "(pswpin|pswpout)" /proc/vmstat'
```

**Advantages:**
- Swap-specific counters
- No application I/O mixed in
- Always available
- Lightweight

**Limitations:**
- Doesn't show disk-level details (queue depth, latency)
- Page-based, not byte-based

#### 2. Separate Partition for Swap

```bash
# Create dedicated partition for swap
mkfs.ext4 /dev/sdb1  # Or just use raw partition
mkdir -p /var/swap
mount /dev/sdb1 /var/swap

# Create swap files on dedicated partition
for i in {1..8}; do
    fallocate -l 2G /var/swap/swapfile$i
    chmod 600 /var/swap/swapfile$i
    mkswap /var/swap/swapfile$i
    swapon /var/swap/swapfile$i
done

# Monitor swap partition only
iostat -x /dev/sdb1 1
```

**Advantages:**
- Pure swap I/O visibility
- Can use iostat effectively
- Better I/O scheduling possible
- Can use different partition type (no FS overhead)

**Limitations:**
- Requires separate disk/partition
- More complex setup
- May waste space if not sized correctly

#### 3. Cgroups v2 Per-Service Stats

```bash
# Enable cgroup v2 swap accounting
echo 1 > /sys/fs/cgroup/memory.swap.events

# Check per-service swap usage
cat /sys/fs/cgroup/myservice.service/memory.swap.current
cat /sys/fs/cgroup/myservice.service/memory.swap.max

# Swap events (low/high/max)
cat /sys/fs/cgroup/myservice.service/memory.swap.events
```

**Advantages:**
- Per-service visibility
- Fine-grained control
- No separate partition needed
- Modern approach

**Limitations:**
- Requires cgroups v2
- systemd integration needed
- More complex setup

#### 4. Use blktrace (Advanced)

```bash
# Install blktrace
apt-get install blktrace

# Trace swap I/O
blktrace -d /dev/sda -o swap_trace &
TRACE_PID=$!

# Run workload
sleep 60

# Stop trace
kill $TRACE_PID

# Analyze trace
blkparse swap_trace | grep -E "swap"
```

**Advantages:**
- Detailed I/O analysis
- Shows exact patterns
- Can identify issues

**Limitations:**
- High overhead
- Complex analysis
- For troubleshooting only

### Recommendation by Use Case

**General Monitoring:**
- Use `/proc/vmstat` counters (pswpin, pswpout)
- Add pgmajfault for working set analysis
- Simplest and most accurate for swap

**Performance Troubleshooting:**
- Add PSI pressure monitoring
- Use ZSWAP writeback ratio
- Consider separate partition if disk I/O is concern

**Per-Service Limits:**
- Use cgroups v2
- Set per-service swap limits
- Monitor with cgroup stats

**Deep I/O Analysis:**
- Use separate partition
- Add blktrace for patterns
- Combine with iostat

---

## Performance Optimization

### Tuning vm.swappiness

```bash
# Default is 60
cat /proc/sys/vm/swappiness

# Conservative (prefer RAM)
echo 10 > /proc/sys/vm/swappiness

# Balanced
echo 60 > /proc/sys/vm/swappiness

# Aggressive (prefer swap)
echo 100 > /proc/sys/vm/swappiness
```

**Recommendations by System Type:**
- **Desktop/Interactive:** 10-30 (prefer RAM)
- **Server/Batch:** 60-80 (use swap)
- **Low RAM systems:** 80-100 (aggressive swap)

### Tuning vm.page-cluster

```bash
# Default is 3 (reads 8 adjacent pages = 32KB)
cat /proc/sys/vm/page-cluster

# SSD: 0-2 (smaller reads, random access is fine)
echo 1 > /proc/sys/vm/page-cluster

# HDD: 3-4 (larger sequential reads)
echo 3 > /proc/sys/vm/page-cluster
```

**Formula:** Reads 2^page-cluster adjacent pages

### ZSWAP Pool Sizing

```bash
# Monitor writeback ratio
RATIO=$(echo "scale=2; $(cat /sys/kernel/debug/zswap/written_back_pages) * 100 / $(cat /sys/kernel/debug/zswap/stored_pages)" | bc)

if (( $(echo "$RATIO > 30" | bc -l) )); then
    # Increase pool size
    CURRENT=$(cat /sys/module/zswap/parameters/max_pool_percent)
    NEW=$(($CURRENT + 5))
    echo $NEW > /sys/module/zswap/parameters/max_pool_percent
    echo "Increased ZSWAP pool to ${NEW}%"
fi
```

### Optimal Parameters by RAM Size

#### 1GB-2GB RAM (Low)
```bash
vm.swappiness = 80
vm.page-cluster = 1
ZSWAP max_pool_percent = 30
ZSWAP compressor = zstd
ZSWAP zpool = zsmalloc
```

#### 2GB-8GB RAM (Medium)
```bash
vm.swappiness = 60
vm.page-cluster = 2
ZSWAP max_pool_percent = 25
ZSWAP compressor = lz4
ZSWAP zpool = z3fold
```

#### 8GB-32GB RAM (High)
```bash
vm.swappiness = 40
vm.page-cluster = 2
ZSWAP max_pool_percent = 20
ZSWAP compressor = lz4
ZSWAP zpool = z3fold
```

---

## Conclusion

This document provides comprehensive coverage of all swap architectures, mechanisms, and monitoring strategies. Key takeaways:

1. **ZSWAP + Swap Files** is recommended for most production systems
2. **ZRAM writeback** is new and promising but decompresses on write
3. Use **correct metrics** (pswpin, pswpout, pgmajfault) not vmstat si
4. **KSM** is valuable for containers/VMs with similar workloads
5. **DAMON** enables data-driven memory optimization
6. **Isolate swap I/O** using /proc/vmstat or separate partitions

For specific use cases, refer to individual architecture sections above.
