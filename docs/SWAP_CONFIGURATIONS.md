# Swap Configuration Guide

## Overview

This guide documents all possible swap configurations supported by the Debian install scripts. The system uses intelligent auto-detection to choose optimal configurations based on your hardware, but you can override any setting.

## Configuration Matrix

The swap system has two independent dimensions:

1. **RAM-based compression** (SWAP_RAM_SOLUTION)
2. **Disk-based swap** (SWAP_BACKING_TYPE)

### RAM Solutions (SWAP_RAM_SOLUTION)

| Option | Description | Best For |
|--------|-------------|----------|
| `zram` | Compressed RAM block device (in-memory only) | Low RAM systems (<4GB), maximum memory utilization |
| `zswap` | Transparent page cache compression | Medium-high RAM systems (≥4GB), balanced performance |
| `none` | No RAM-based compression | High RAM systems where swap is rarely used |

### Disk Backing Types (SWAP_BACKING_TYPE)

| Option | Description | Best For |
|--------|-------------|----------|
| `files_in_root` | Swap files in root filesystem | SSD systems, flexible sizing, most compatible |
| `partitions_swap` | Native swap partitions | HDD systems, better I/O performance |
| `partitions_zvol` | ZFS zvol with compression | ZFS systems, additional compression layer |
| `files_in_partitions` | Swap files on dedicated ext4 partition | Special use cases, maximum flexibility |
| `none` | No disk-based swap | Systems with ample RAM, low disk space |

## Complete Configuration Combinations

### Total: 15 Combinations (3 × 5)

Below are all possible combinations rated by use case:

---

### ⭐⭐⭐⭐⭐ Excellent Configurations

#### 1. ZSWAP + Swap Files (`zswap` + `files_in_root`)
**Rating:** 5/5  
**Best For:** General purpose servers, SSD-based systems with 4-16GB RAM  
**Auto-selected when:** Medium RAM (4-16GB) + SSD + adequate space

**Pros:**
- Excellent balance of performance and memory savings
- Low CPU overhead for compression
- Flexible swap file management
- Works well with modern SSDs
- Automatic writeback to disk when memory pressure increases

**Cons:**
- Slightly lower compression ratio than ZRAM
- Requires disk space

**Performance:**
- Memory savings: ~30-50% (via compression)
- CPU overhead: Very low (1-3%)
- I/O overhead: Minimal with SSD

**Configuration:**
```bash
SWAP_RAM_SOLUTION=zswap
SWAP_BACKING_TYPE=files_in_root
SWAP_DISK_TOTAL_GB=8
```

---

#### 2. ZRAM + Swap Partitions (`zram` + `partitions_swap`)
**Rating:** 5/5  
**Best For:** Low RAM systems (<4GB) with HDD storage  
**Auto-selected when:** Low RAM + HDD + ample space

**Pros:**
- Maximum memory compression (up to 3:1 ratio)
- Excellent for low-RAM systems
- Partitions provide better I/O than files on HDD
- Two-tier memory management (fast ZRAM, slower disk)

**Cons:**
- Higher CPU usage for compression
- Partitions less flexible than files

**Performance:**
- Memory savings: ~60-70% (via aggressive compression)
- CPU overhead: Low-moderate (3-8%)
- I/O overhead: Optimized for HDD

**Configuration:**
```bash
SWAP_RAM_SOLUTION=zram
SWAP_BACKING_TYPE=partitions_swap
SWAP_DISK_TOTAL_GB=8
EXTEND_ROOT=yes  # Extend root, place swap at end
```

---

#### 3. ZSWAP + Swap Partitions (`zswap` + `partitions_swap`)
**Rating:** 5/5  
**Best For:** Production servers with HDD, balanced workloads  
**Auto-selected when:** Medium RAM + HDD + ample space

**Pros:**
- Balanced CPU/memory tradeoff
- Partitions optimal for HDD I/O patterns
- Good for sustained workloads
- Transparent operation

**Cons:**
- Requires careful partition planning
- Less flexible than files

**Performance:**
- Memory savings: ~30-50%
- CPU overhead: Very low
- I/O overhead: Minimal on HDD with proper striping

**Configuration:**
```bash
SWAP_RAM_SOLUTION=zswap
SWAP_BACKING_TYPE=partitions_swap
SWAP_STRIPE_WIDTH=4  # Multiple partitions for I/O striping
```

---

### ⭐⭐⭐⭐ Very Good Configurations

#### 4. ZRAM + Swap Files (`zram` + `files_in_root`)
**Rating:** 4/5  
**Best For:** Low RAM systems with SSD, development workstations

**Pros:**
- Maximum compression for memory
- Flexible file-based swap
- Easy to adjust sizes

**Cons:**
- Higher CPU usage than ZSWAP
- File overhead on writeback

**Configuration:**
```bash
SWAP_RAM_SOLUTION=zram
SWAP_BACKING_TYPE=files_in_root
```

---

#### 5. ZSWAP + ZFS zvol (`zswap` + `partitions_zvol`)
**Rating:** 4/5  
**Best For:** ZFS-based systems, advanced users

**Pros:**
- Double compression (ZSWAP + ZFS)
- ZFS features (snapshots, checksums)
- Excellent space efficiency

**Cons:**
- Requires ZFS (additional complexity)
- Higher CPU for double compression
- Not suitable for low-end systems

**Configuration:**
```bash
SWAP_RAM_SOLUTION=zswap
SWAP_BACKING_TYPE=partitions_zvol
ZFS_POOL=tank
```

---

#### 6. None + Swap Files (`none` + `files_in_root`)
**Rating:** 4/5  
**Best For:** High RAM systems (32GB+), cloud VMs with limited CPU

**Pros:**
- Zero CPU overhead from compression
- Simple, traditional swap
- Predictable performance

**Cons:**
- No memory savings
- More disk I/O under memory pressure

**Configuration:**
```bash
SWAP_RAM_SOLUTION=none
SWAP_BACKING_TYPE=files_in_root
```

---

### ⭐⭐⭐ Good Configurations

#### 7. ZRAM Only (`zram` + `none`)
**Rating:** 3/5  
**Best For:** Low RAM systems with no available disk space, embedded systems

**Pros:**
- No disk space required
- Maximum memory utilization
- Good for RAM-constrained systems

**Cons:**
- No overflow capacity
- System may OOM if ZRAM fills
- Risky for production

**Configuration:**
```bash
SWAP_RAM_SOLUTION=zram
SWAP_BACKING_TYPE=none
SWAP_RAM_TOTAL_GB=2
```

---

#### 8. ZRAM + ZFS zvol (`zram` + `partitions_zvol`)
**Rating:** 3/5  
**Best For:** ZFS systems with low RAM

**Pros:**
- Maximum compression at all levels
- ZFS benefits

**Cons:**
- Very high CPU usage
- Complex setup
- Diminishing returns from double compression

**Configuration:**
```bash
SWAP_RAM_SOLUTION=zram
SWAP_BACKING_TYPE=partitions_zvol
```

---

#### 9. None + Swap Partitions (`none` + `partitions_swap`)
**Rating:** 3/5  
**Best For:** High RAM systems with HDD, traditional setups

**Pros:**
- Traditional, well-understood
- Good HDD I/O with partitions
- Zero CPU overhead

**Cons:**
- No memory savings
- Requires partition management

**Configuration:**
```bash
SWAP_RAM_SOLUTION=none
SWAP_BACKING_TYPE=partitions_swap
```

---

### ⭐⭐ Acceptable Configurations

#### 10. ZSWAP Only (`zswap` + `none`)
**Rating:** 2/5  
**Best For:** Systems with moderate RAM but no disk space

**Pros:**
- Some memory savings
- Low CPU overhead

**Cons:**
- Limited capacity (20% of RAM)
- No disk overflow
- Risk of OOM

**Use Case:** Limited, mainly for constrained environments

**Configuration:**
```bash
SWAP_RAM_SOLUTION=zswap
SWAP_BACKING_TYPE=none
```

---

#### 11. None + ZFS zvol (`none` + `partitions_zvol`)
**Rating:** 2/5  
**Best For:** ZFS systems with ample RAM

**Pros:**
- ZFS compression on swap
- ZFS reliability features

**Cons:**
- CPU overhead for compression without RAM benefit
- Better alternatives exist

**Configuration:**
```bash
SWAP_RAM_SOLUTION=none
SWAP_BACKING_TYPE=partitions_zvol
```

---

#### 12. ZRAM/ZSWAP + Files in Partitions (Any + `files_in_partitions`)
**Rating:** 2/5  
**Best For:** Very specific use cases, testing

**Pros:**
- Maximum flexibility
- Can isolate swap I/O

**Cons:**
- Added complexity (partition + filesystem + files)
- Extra overhead
- Rarely needed

**Configuration:**
```bash
SWAP_RAM_SOLUTION=zswap
SWAP_BACKING_TYPE=files_in_partitions
```

---

### ⭐ Not Recommended

#### 13. None + None (`none` + `none`)
**Rating:** 1/5  
**Best For:** Systems with massive RAM (128GB+) running specific workloads

**Pros:**
- Zero overhead
- Maximum simplicity

**Cons:**
- No safety net for memory spikes
- OOM kills likely under pressure
- Not suitable for general use

**Configuration:**
```bash
SWAP_RAM_SOLUTION=none
SWAP_BACKING_TYPE=none
```

---

## Auto-Detection Logic

The system automatically selects optimal configuration based on:

### RAM-Based Decision Tree:
```
if RAM >= 16GB:
    → ZSWAP (low overhead, adequate RAM)
elif RAM >= 4GB:
    → ZSWAP (balanced)
else:
    → ZRAM (maximize available memory)
```

### Disk-Based Decision Tree:
```
if disk_space < 20GB:
    → none (insufficient space)
elif ZFS_available:
    → partitions_zvol (leverage ZFS)
elif SSD and disk_space >= 50GB:
    → files_in_root (flexibility)
elif HDD and disk_space >= 100GB:
    → partitions_swap (I/O optimization)
else:
    → files_in_root (safe default)
```

## Auto-Mode Decision Reasoning

This section explains **why** the system makes specific decisions in auto mode, providing the technical rationale behind each configuration choice.

### RAM Solution Selection Logic

#### Why ZSWAP for ≥4GB RAM?
**Decision:** Systems with 4GB+ RAM use ZSWAP by default.

**Reasoning:**
- **Lower CPU overhead**: ZSWAP compresses only pages being evicted to disk, not all swap activity
- **Automatic writeback**: Pages can be written to disk when pool fills, preventing OOM
- **Better for bursty workloads**: Handles temporary memory spikes efficiently
- **Tested sweet spot**: 4GB is where the benefits of ZSWAP outweigh ZRAM's aggressive compression

**Trade-offs accepted:**
- Slightly lower compression ratio (~2:1 vs ZRAM's ~2.5:1)
- Requires disk-backed swap to work optimally

#### Why ZRAM for <4GB RAM?
**Decision:** Low memory systems use ZRAM.

**Reasoning:**
- **Maximum memory utilization**: Every byte counts on low-RAM systems
- **Higher compression ratio**: ZRAM typically achieves 2.5-3:1 compression
- **No disk dependency**: Works even without disk swap configured
- **Faster than disk**: All operations stay in RAM (even if compressed)

**Trade-offs accepted:**
- Higher CPU usage (3-8% vs ZSWAP's 1-3%)
- No automatic overflow to disk (can lead to OOM if swap fills)
- Limited by available RAM (can't exceed physical RAM allocation)

### Disk Backing Selection Logic

#### Why files_in_root for SSD + adequate space?
**Decision:** SSD systems with 50GB+ use swap files in root filesystem.

**Reasoning:**
- **No partitioning needed**: Can be added/resized without repartitioning
- **SSD wear leveling**: Filesystem spreads writes across the SSD
- **Easy management**: Can be created, resized, or removed on the fly
- **Good I/O performance**: Modern SSDs handle file-based I/O efficiently

**Trade-offs accepted:**
- Slightly more filesystem overhead than raw partitions
- Requires sufficient free space in root filesystem

#### Why partitions_swap for HDD + ample space?
**Decision:** HDD systems with 100GB+ use dedicated swap partitions.

**Reasoning:**
- **Sequential I/O**: Partitions at disk end provide better sequential access patterns
- **Reduced fragmentation**: Dedicated partition avoids filesystem fragmentation
- **Consistent performance**: No filesystem overhead for I/O operations
- **Better for HDDs**: Traditional swap partition design optimized for rotational media

**Trade-offs accepted:**
- Requires disk repartitioning (destructive on existing systems)
- Fixed size (can't easily resize)
- Less flexible than files

#### Why partitions_zvol with ZFS?
**Decision:** Systems with ZFS use ZFS zvol for swap.

**Reasoning:**
- **Leverages ZFS**: Uses existing ZFS pool and benefits
- **Compression**: ZFS can add another compression layer
- **ARC integration**: Better memory management with ZFS ARC
- **Snapshots/cloning**: Swap can be part of ZFS management strategy

**Trade-offs accepted:**
- Requires ZFS (overhead if not already using it)
- More complex than simple swap files/partitions

#### Why none for <20GB disk space?
**Decision:** Systems with very limited disk space skip disk-backed swap.

**Reasoning:**
- **Preserve disk space**: 20GB is tight for OS + applications
- **Avoid disk thrashing**: Limited space would cause frequent I/O contention
- **RAM-only safer**: Better to rely on RAM compression than fill disk
- **Performance**: Disk swap on near-full filesystem performs poorly

**Trade-offs accepted:**
- No disk overflow capability
- Increased OOM risk if RAM+ZRAM/ZSWAP fills

### Swap Size Calculation Logic

#### Disk Swap Sizing Formula
```
if RAM ≤ 2GB:    disk_swap = RAM × 2    (need substantial backing)
elif RAM ≤ 4GB:  disk_swap = RAM × 1.5  (balanced approach)
elif RAM ≤ 8GB:  disk_swap = RAM × 1    (equal to RAM)
elif RAM ≤ 16GB: disk_swap = RAM × 0.5  (half of RAM)
else:            disk_swap = RAM × 0.25  (capped at 4-16GB)
```

**Reasoning:**
- **Low RAM systems need more disk swap**: Compensate for limited RAM
- **High RAM systems need less**: Swap is safety net, not primary memory
- **Diminishing returns**: Beyond certain point, more swap doesn't help
- **Disk space efficiency**: Don't waste disk space on rarely-used swap

#### RAM Swap Sizing (ZRAM/ZSWAP)
```
ram_swap = min(RAM × 0.5, 16GB)
```

**Reasoning:**
- **50% rule**: Allocating half of RAM for compressed swap is optimal
- **2:1 compression expectation**: 50% RAM → ~100% effective memory
- **Cap at 16GB**: Beyond this, compression overhead outweighs benefits
- **Safety margin**: Leaves enough RAM for actual processes

### Kernel Parameter Tuning

#### vm.swappiness
```
if RAM ≤ 2GB:   swappiness = 80  (aggressive swapping needed)
elif RAM ≥ 16GB: swappiness = 10  (prefer keeping in RAM)
else:            swappiness = 60  (balanced default)
```

**Reasoning:**
- **Low RAM needs swap early**: Prevent OOM by swapping proactively
- **High RAM can delay**: Keep hot data in RAM longer
- **Default (60) is balanced**: Good for most workloads

#### vm.page-cluster
```
HDD:  page-cluster = 4  (64KB - larger sequential reads)
SSD:  page-cluster = 3  (32KB - balanced for random I/O)
Benchmark-optimized:  page-cluster = best_block_size
```

**Reasoning:**
- **HDDs favor larger blocks**: Amortize seek time over larger transfers
- **SSDs don't care about seeks**: Smaller blocks reduce latency
- **Benchmark overrides**: Actual hardware testing provides best value

#### SWAP_STRIPE_WIDTH
```
Default: 8 parallel swap files
Benchmark-optimized: best_concurrency_test_result
```

**Reasoning:**
- **Parallelism**: Multiple swap files enable parallel I/O
- **Modern CPUs**: 8 files matches typical core counts
- **Diminishing returns**: Beyond 8-16, overhead exceeds benefits
- **Benchmark tunes**: Actual I/O testing finds optimal parallelism

### Benchmark-Driven Optimization

When benchmarks run (`RUN_BENCHMARKS=yes`), the system:

1. **Tests parameter space comprehensively**:
   - Block sizes: 4KB, 8KB, 16KB, 32KB, 64KB, 128KB
   - Compressors: lz4, zstd, lzo-rle
   - Allocators: zsmalloc, z3fold, zbud
   - Concurrency: 1, 2, 4, 8, 16 files

2. **Selects optimal values based on actual performance**:
   - Best compressor (highest compression ratio)
   - Best allocator (most efficient memory usage)
   - Best page-cluster (highest throughput block size)
   - Best stripe width (optimal parallel I/O)

3. **Overrides defaults with measured results**:
   - Generated config file: `/tmp/benchmark-optimal-config.sh`
   - Sourced by `setup-swap.sh` before applying defaults
   - Real hardware measurements trump theoretical defaults

**Why benchmark-driven?**
- **Hardware varies**: Different CPUs/storage have different optimal settings
- **Workload-specific**: Benchmark simulates swap access patterns
- **Measurable improvements**: Can see 20-50% performance gains vs defaults
- **One-time cost**: 5-second benchmarks provide ongoing benefits

### Summary

**Key Principles:**
1. **RAM is precious on low-memory systems** → More aggressive compression (ZRAM)
2. **CPU overhead matters on high-memory systems** → Lighter compression (ZSWAP)
3. **Storage type drives I/O strategy** → Files for SSD, partitions for HDD
4. **Disk space constraints override preferences** → Skip disk swap if tight
5. **Real measurements beat assumptions** → Benchmark when possible

**Default Behavior (auto mode):**
- Conservative and safe: Won't break existing systems
- Performance-oriented: Chooses fastest config for hardware
- Flexible: Can be overridden with environment variables
- Smart: Adapts to actual system characteristics

## Manual Configuration

Override auto-detection by setting environment variables:

```bash
# Example: Force ZRAM + partition swap for low RAM system
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
  SWAP_RAM_SOLUTION=zram \
  SWAP_BACKING_TYPE=partitions_swap \
  SWAP_DISK_TOTAL_GB=4 \
  EXTEND_ROOT=yes \
  bash
```

## Performance Tuning

### Key Parameters:

| Parameter | Default | Low RAM | High RAM |
|-----------|---------|---------|----------|
| vm.swappiness | 60 | 80 | 10 |
| vm.page-cluster | 3 (SSD)<br>4 (HDD) | 2 | 3-4 |
| SWAP_STRIPE_WIDTH | 8 | 4 | 8 |

### Compressor Selection:

| Compressor | Speed | Ratio | CPU | Best For |
|------------|-------|-------|-----|----------|
| lz4 | Fastest | ~2:1 | Lowest | Default, balanced |
| zstd | Fast | ~2.5:1 | Low | Better compression |
| lzo-rle | Medium | ~2:1 | Medium | Legacy compatibility |

## Monitoring

Monitor swap usage:
```bash
# Real-time monitoring
./swap-monitor.sh

# Check swap status
swapon --show
free -h

# View ZRAM stats
cat /sys/block/zram0/mm_stat

# View ZSWAP stats
cat /sys/kernel/debug/zswap/*
```

## Benchmarking

Test different configurations:
```bash
# Run benchmarks with 5 second duration per test
./benchmark.py --test-all --duration 5

# Test specific compressor
./benchmark.py --test-compressors --duration 10
```

## Troubleshooting

### OOM Kills Despite Swap
- Increase swappiness: `sysctl vm.swappiness=80`
- Check swap is enabled: `swapon --show`
- Monitor: `dmesg | grep -i oom`

### High CPU Usage
- Consider switching from ZRAM to ZSWAP
- Try faster compressor (lz4)
- Reduce swap usage with more RAM

### Slow I/O
- For HDD: Use `partitions_swap` instead of `files_in_root`
- Increase `SWAP_STRIPE_WIDTH` for parallel I/O
- For SSD: Ensure TRIM is enabled

## Best Practices

1. **Always have some swap** (even with 32GB+ RAM) - safety net for memory spikes
2. **Use ZSWAP for most cases** - best balance of CPU/memory/performance
3. **Match backing type to storage** - files for SSD, partitions for HDD
4. **Set EXTEND_ROOT=yes** - maximize disk utilization on new installs
5. **Monitor performance** - adjust based on actual workload
6. **Test before production** - run benchmarks with representative workload

## Migration

### From old SWAP_ARCH presets:

| Old Preset | New Configuration |
|------------|-------------------|
| SWAP_ARCH=1 | SWAP_RAM_SOLUTION=zram<br>SWAP_BACKING_TYPE=none |
| SWAP_ARCH=2 | SWAP_RAM_SOLUTION=zram<br>SWAP_BACKING_TYPE=files_in_root |
| SWAP_ARCH=3 | SWAP_RAM_SOLUTION=zswap<br>SWAP_BACKING_TYPE=files_in_root |
| SWAP_ARCH=4 | SWAP_RAM_SOLUTION=none<br>SWAP_BACKING_TYPE=files_in_root |
| SWAP_ARCH=5 | SWAP_RAM_SOLUTION=none<br>SWAP_BACKING_TYPE=partitions_zvol |
| SWAP_ARCH=6 | SWAP_RAM_SOLUTION=zram<br>SWAP_BACKING_TYPE=partitions_zvol |
| SWAP_ARCH=7 | SWAP_RAM_SOLUTION=zram<br>SWAP_BACKING_TYPE=partitions_swap |

## References

- [Linux Kernel Swap Documentation](https://www.kernel.org/doc/html/latest/admin-guide/mm/zswap.html)
- [ZRAM vs ZSWAP Performance](https://wiki.archlinux.org/title/Zram)
- [Swap Management Best Practices](https://www.kernel.org/doc/html/latest/admin-guide/sysctl/vm.html)
