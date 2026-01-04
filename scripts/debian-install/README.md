# Debian Swap Configuration Toolkit

A comprehensive toolkit for configuring and optimizing swap on Debian 12/13 systems with support for ZRAM, ZSWAP, swap files, and ZFS zvol configurations.

## Quick Start

### Netcup Bootstrap (< 10KB)

For minimal netcup VPS bootstrap, use the lightweight bootstrap script:

```bash
# Download and run bootstrap (under 10KB)
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | bash
```

Or with custom configuration:

```bash
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
  SWAP_ARCH=3 SWAP_TOTAL_GB=16 SWAP_FILES=8 bash
```

### Full Installation

```bash
# Clone repository
git clone https://github.com/volkb79/vbpub.git
cd vbpub/scripts/debian-install

# Analyze your system first (recommended)
./analyze-memory.sh

# Run setup with defaults (ZSWAP + Swap Files, 8 files)
sudo ./setup-swap.sh

# Or customize
sudo SWAP_ARCH=3 SWAP_TOTAL_GB=16 SWAP_FILES=8 ./setup-swap.sh
```

## Architecture Options Overview

The toolkit supports 7 different swap architectures. **Default: 8 swap files** for optimal concurrency.

### 1. ZRAM Only (Memory-Only Compression)

**Best for:** Systems that need fast compressed swap without disk I/O, or when disk space is limited.

```bash
sudo SWAP_ARCH=1 SWAP_TOTAL_GB=4 ./setup-swap.sh
```

- ✅ Fastest performance (no disk I/O)
- ✅ Extends RAM capacity 2-3x with compression
- ✅ No disk space required
- ⚠️ Limited by available RAM - data lost if full
- ⚠️ No persistence across reboots

**Use case:** Small VPS with limited disk, workloads that fit in compressed memory.

### 2. ZRAM + Swap Files (Two-Tier)

**Best for:** Fast tier for hot data + disk overflow for cold data.

```bash
sudo SWAP_ARCH=2 SWAP_TOTAL_GB=8 SWAP_FILES=8 ./setup-swap.sh
```

- ✅ Fast compressed RAM tier (priority 100)
- ✅ Disk tier for overflow (priority 10)
- ✅ Good performance with disk safety net
- ⚠️ ZRAM overflow requires decompress→recompress cycle

**Use case:** Systems needing both speed and capacity with tiered priorities.

### 3. ZSWAP + Swap Files (Recommended)

**Best for:** Production systems with moderate to high memory pressure. **DEFAULT RECOMMENDED.**

```bash
sudo SWAP_ARCH=3 SWAP_TOTAL_GB=16 SWAP_FILES=8 ./setup-swap.sh
```

- ✅ Single compression stage (efficient)
- ✅ Automatic writeback to disk when pool full
- ✅ Better for working sets larger than RAM
- ✅ Transparent to applications
- ⚠️ Requires kernel 3.11+ (Debian 12/13 ✓)

**Use case:** General purpose servers, databases, web applications with memory pressure.

### 4. Swap Files Only

**Best for:** Simple setups without compression overhead.

```bash
sudo SWAP_ARCH=4 SWAP_TOTAL_GB=16 SWAP_FILES=8 ./setup-swap.sh
```

- ✅ Simple, well-tested approach
- ✅ Multiple files enable concurrent I/O
- ✅ No CPU overhead for compression
- ⚠️ No compression savings
- ⚠️ Slower than compressed options

**Use case:** Systems with ample disk space, low CPU, or compression incompatible workloads.

### 5. ZFS Compressed Swap (zvol)

**Best for:** Systems already using ZFS with available pool space.

```bash
sudo SWAP_ARCH=5 SWAP_TOTAL_GB=8 ZFS_POOL=tank ./setup-swap.sh
```

- ✅ Leverages ZFS compression (lz4/zstd)
- ✅ Integrated with ZFS ecosystem
- ✅ Single compression stage
- ⚠️ Requires ZFS installed and configured
- ⚠️ Uses `volblocksize=64k` matching vm.page-cluster=4

**Use case:** ZFS-based systems, storage servers, NAS systems.

### 6. ZRAM + ZFS zvol

**Best for:** Maximum compression but with overhead.

```bash
sudo SWAP_ARCH=6 SWAP_TOTAL_GB=8 ZFS_POOL=tank ./setup-swap.sh
```

- ✅ Double compression layer
- ⚠️ **WARNING:** Compress→decompress→recompress inefficiency
- ⚠️ Higher CPU overhead
- ⚠️ May not provide additional benefit

**Use case:** Extreme memory constraints, experimental setups only.

### 7. Compressed Swap File Alternatives

**Best for:** Custom setups or specific use cases.

```bash
sudo SWAP_ARCH=7 SWAP_TYPE=squashfs SWAP_TOTAL_GB=8 ./setup-swap.sh
```

Options:
- **SquashFS loop device:** Read-only compression with loop mount
- **FUSE compressors:** User-space compression layers

⚠️ **Experimental** - prefer ZSWAP/ZRAM for production.

**Use case:** Testing, specific kernel limitations, educational purposes.

## Configuration Reference

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SWAP_ARCH` | `3` | Architecture option (1-7) |
| `SWAP_TOTAL_GB` | `auto` | Total swap size in GB (calculated from RAM if not set) |
| `SWAP_FILES` | `8` | Number of swap files for concurrency (**default: 8**) |
| `SWAP_PRIORITY` | `10` | Priority for swap files (0-32767, higher = preferred) |
| `ZRAM_SIZE_GB` | `auto` | ZRAM size (typically 50% of RAM) |
| `ZRAM_PRIORITY` | `100` | ZRAM priority (higher than disk) |
| `ZSWAP_POOL_PERCENT` | `20` | ZSWAP pool size as % of RAM |
| `ZSWAP_COMPRESSOR` | `lz4` | Compression algorithm (lz4, zstd, lzo-rle) |
| `ZFS_POOL` | `tank` | ZFS pool name for zvol (arch 5 & 6) |
| `TELEGRAM_BOT_TOKEN` | - | Telegram bot token for notifications |
| `TELEGRAM_CHAT_ID` | - | Telegram chat ID for notifications |

### Swap File Sizing Formula

**Important:** `SWAP_TOTAL_GB / SWAP_FILES = per-file size`

Examples:
- `SWAP_TOTAL_GB=16 SWAP_FILES=8` → 8 files of 2GB each
- `SWAP_TOTAL_GB=32 SWAP_FILES=8` → 8 files of 4GB each
- `SWAP_TOTAL_GB=8 SWAP_FILES=4` → 4 files of 2GB each

**Why 8 files?** Enables concurrent I/O operations across multiple swap devices, improving performance under high memory pressure. The kernel uses round-robin allocation across equal-priority devices.

### Dynamic Sizing

When `SWAP_TOTAL_GB` is not set, the script calculates optimal sizing:

| RAM Size | Swap Size | Notes |
|----------|-----------|-------|
| 1-2 GB | 2x RAM | Prefer zstd + zsmalloc for compression |
| 2-4 GB | 1.5x RAM | |
| 4-8 GB | 1x RAM | |
| 8-16 GB | 0.5x RAM | |
| 16-32 GB | 0.25x RAM | Minimum 4GB |
| 32+ GB | 8-16 GB | For hibernation, match RAM |

Disk space constraints:
- Minimum 30GB disk: Use ZRAM only (arch 1) or minimal swap
- 30-100GB disk: Use calculated swap, may reduce if needed
- 100GB+ disk: Full calculated swap size

## Telegram Notifications Setup

### Prerequisites

**CRITICAL:** You must send a message to your bot first before it can message you!

1. **Create bot** with @BotFather on Telegram
2. **Get bot token** (looks like: `110201543:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw`)
3. **Send a message to your bot** - Just type `/start` or any message
4. **Get your chat ID** using one of these methods:

#### Method 1: Using @userinfobot
1. Start a chat with [@userinfobot](https://t.me/userinfobot)
2. Send any message
3. Copy your ID (numbers only)

#### Method 2: Using @getidsbot
1. Start a chat with [@getidsbot](https://t.me/getidsbot)
2. Send any message
3. Copy your ID

#### Method 3: Using Bot API
```bash
# Replace YOUR_BOT_TOKEN with your actual token
curl "https://api.telegram.org/botYOUR_BOT_TOKEN/getUpdates" | jq
# Look for "chat":{"id": YOUR_CHAT_ID in the response
```

### For Channels

If sending to a channel:
1. Add your bot as administrator to the channel
2. Use channel username with @ prefix: `@yourchannel`
3. Or use numeric channel ID (negative number): `-1001234567890`

### Configuration

```bash
export TELEGRAM_BOT_TOKEN="110201543:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"
export TELEGRAM_CHAT_ID="123456789"  # or "@yourchannel"
```

Or pass directly to setup:

```bash
sudo TELEGRAM_BOT_TOKEN="..." TELEGRAM_CHAT_ID="..." ./setup-swap.sh
```

### Testing

Test your configuration:

```bash
./sysinfo-notify.py --test-mode
```

## Post-Installation Commands

### Monitor Swap Status

```bash
# Real-time monitoring (updates every 5 seconds)
./swap-monitor.sh

# Single snapshot
./swap-monitor.sh --once

# JSON output for automation
./swap-monitor.sh --json
```

### Key Metrics to Watch

**Correct metrics for swap monitoring:**

1. **pgmajfault** - Actual disk I/O page faults (important!)
2. **ZSWAP writeback ratio** - % of pages written to disk
   - <1% (green): Excellent, all in compressed pool
   - 1-10% (yellow): Good, minimal disk I/O
   - >10% (red): High pressure, consider more RAM or swap
3. **PSI full** - Pressure Stall Information for memory
4. **swap await** - Average swap I/O latency

⚠️ **Important:** `vmstat si` (swap-in) counts ZSWAP RAM decompression too, not just disk I/O! It's **misleading** for actual disk activity. Use `pgmajfault` instead.

### Monitoring Commands

```bash
# View swap usage per device
swapon --show

# Check ZRAM status and compression ratio
cat /sys/block/zram0/mm_stat

# Check ZSWAP statistics
grep -r . /sys/kernel/debug/zswap/ 2>/dev/null

# Monitor page faults (disk I/O)
vmstat 1 | awk 'NR==1 || NR==2 || $9 > 0'  # Shows major faults

# Check memory pressure (PSI)
cat /proc/pressure/memory

# Top 10 processes using swap
for pid in /proc/[0-9]*; do
  swap=$(grep VmSwap "$pid/status" 2>/dev/null | awk '{print $2}')
  [ -n "$swap" ] && [ "$swap" -gt 0 ] && \
    echo "$swap $(cat "$pid/comm" 2>/dev/null) $(basename "$pid")"
done | sort -rn | head -10
```

### Check Kernel Parameters

```bash
# View current swap-related kernel parameters
sysctl vm.swappiness vm.page-cluster vm.vfs_cache_pressure

# View compression settings
cat /sys/module/zswap/parameters/*
cat /sys/module/zram/parameters/*
```

### Benchmark Your Configuration

```bash
# Test different configurations
sudo ./benchmark.py --test-all

# Test specific block size (matching vm.page-cluster)
sudo ./benchmark.py --block-size 64k

# Test compression algorithms
sudo ./benchmark.py --test-compressors

# Compare ZRAM vs ZSWAP memory-only performance
sudo ./benchmark.py --compare-memory-only
```

### KSM (Kernel Samepage Merging) Testing

```bash
# Test if KSM would be effective
sudo ./ksm-trial.sh

# Note: Most applications DON'T use MADV_MERGEABLE
# KSM typically saves <1% memory unless specifically designed for it
```

## Understanding Swap Behavior

### vm.page-cluster and I/O Size

**Important:** `vm.page-cluster` controls the **number of pages** read/written in a single I/O operation, NOT striping!

- `vm.page-cluster=0` → 4KB per I/O (1 page)
- `vm.page-cluster=1` → 8KB per I/O (2 pages)
- `vm.page-cluster=2` → 16KB per I/O (4 pages)
- `vm.page-cluster=3` → 32KB per I/O (8 pages)
- `vm.page-cluster=4` → 64KB per I/O (16 pages, **default**)
- `vm.page-cluster=5` → 128KB per I/O (32 pages)

**Striping** happens via round-robin allocation across equal-priority swap devices. With 8 swap files at the same priority, the kernel distributes pages across all files.

### Working Set Larger Than Available Memory

Example scenario:
- System: 4GB RAM + 2GB compressed pool capacity
- Application: 6GB working set

**What happens:**
1. Hot data (frequently accessed) stays in RAM + compressed pool
2. Cold data (less frequently accessed) gets evicted to disk
3. When cold data is accessed → **pgmajfault** (disk read)
4. Swap-in from disk is **slow** (milliseconds)
5. ZSWAP decompression from RAM is **fast** (microseconds)

This is why **pgmajfault** and **writeback ratio** are critical metrics!

### ZRAM vs ZSWAP Behavior

**ZRAM overflow (arch 2):**
```
RAM → ZRAM (compress) → ZRAM full → decompress → disk → compress again
```
Inefficient double compression when overflow occurs!

**ZSWAP writeback (arch 3):**
```
RAM → ZSWAP pool (compress) → pool full → write compressed page to disk
```
Efficient single compression stage!

## Troubleshooting

### Check Current Configuration

```bash
# Show all swap devices
swapon -s

# Show memory and swap usage
free -h

# Check if ZRAM is loaded
lsmod | grep zram

# Check if ZSWAP is enabled
cat /sys/module/zswap/parameters/enabled
```

### Common Issues

**Issue:** High swap-in (si) but no disk I/O
- **Cause:** ZSWAP decompression (fast, from RAM)
- **Solution:** This is normal! Check pgmajfault for real disk I/O

**Issue:** High pgmajfault rate
- **Cause:** Working set larger than RAM + compressed pool
- **Solution:** Increase RAM, increase ZSWAP pool, or optimize application

**Issue:** High ZSWAP writeback ratio (>10%)
- **Cause:** ZSWAP pool too small or high memory pressure
- **Solution:** Increase `ZSWAP_POOL_PERCENT` or add more RAM

**Issue:** Swap not activating
- **Cause:** `vm.swappiness=0` or insufficient memory pressure
- **Solution:** Normal if plenty of free memory; adjust swappiness if needed

### Performance Issues

**Slow swap performance:**
1. Check disk I/O: `iostat -x 1`
2. Check swap await: `iostat -x 1 | grep -A1 dm-`
3. Verify concurrent files: `swapon -s` (should show 8 devices)
4. Check compression ratio: ZSWAP/ZRAM statistics
5. Consider faster storage or more RAM

**High CPU from compression:**
1. Switch to lz4 (fastest): `ZSWAP_COMPRESSOR=lz4`
2. Reduce ZSWAP pool size: `ZSWAP_POOL_PERCENT=10`
3. Consider arch 4 (no compression) if CPU-constrained

## Advanced Topics

See [SWAP_ARCHITECTURE.md](SWAP_ARCHITECTURE.md) for comprehensive technical documentation including:

- Swap fundamentals and page fault mechanics
- Deep dives into ZRAM allocators (zsmalloc, z3fold, zbud)
- ZSWAP implementation details
- ZFS volblocksize tuning
- KSM requirements and limitations
- DAMON/DAMO memory profiling
- Compression algorithm comparisons
- Monitoring and tuning strategies

## Files in This Toolkit

| File | Purpose |
|------|---------|
| `README.md` | This user guide |
| `SWAP_ARCHITECTURE.md` | Technical deep-dive documentation |
| `bootstrap.sh` | Minimal bootstrap script (<10KB) |
| `setup-swap.sh` | Main installation and configuration orchestrator |
| `analyze-memory.sh` | Pre-installation system analysis |
| `benchmark.py` | Performance testing and comparison |
| `swap-monitor.sh` | Real-time monitoring with correct metrics |
| `sysinfo-notify.py` | System info and Telegram notifications |
| `ksm-trial.sh` | KSM effectiveness testing |

## References

- Kernel documentation: [Admin Guide - Swap](https://www.kernel.org/doc/html/latest/admin-guide/mm/swap.html)
- ZRAM: [Admin Guide - ZRAM](https://www.kernel.org/doc/html/latest/admin-guide/blockdev/zram.html)
- ZSWAP: [VM - ZSWAP](https://www.kernel.org/doc/html/latest/vm/zswap.html)
- ZFS on Linux: [OpenZFS Documentation](https://openzfs.github.io/openzfs-docs/)

## Contributing

Found an issue or have a suggestion? Please open an issue at: https://github.com/volkb79/vbpub/issues

## License

See repository LICENSE file.
