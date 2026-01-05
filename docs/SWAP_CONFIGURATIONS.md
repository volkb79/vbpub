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
