# Debian Multi-Tier Swap Configuration Toolkit

A comprehensive swap configuration toolkit for Debian 12/13 systems, designed for VPS environments (especially netcup) with optimized memory management strategies.

## Quick Start (Netcup VPS)

### 1. Initial Bootstrap

```bash
# Download and run bootstrap script
curl -sSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | bash

# Or clone repository first
git clone https://github.com/volkb79/vbpub.git
cd vbpub/scripts/debian-install
chmod +x *.sh
./bootstrap.sh
```

### 2. Configure Swap

```bash
# Analyze current system first
./analyze-running-system.sh

# Setup swap with defaults (ZSWAP + Swap Files)
sudo ./setup-swap.sh

# Or specify custom configuration
sudo ./setup-swap.sh --architecture zswap --swap-total 16 --swap-files 8
```

### 3. Monitor Performance

```bash
# Real-time monitoring
./swap-monitor.sh

# Run benchmarks
./benchmark.py
```

## Architecture Overview

This toolkit supports **7 different swap architectures**, each optimized for different use cases:

### 1. **ZRAM Only** (Memory-only, no disk)
- Compressed swap in RAM (lz4/zstd compression)
- Fast but limited by RAM size
- Best for: Systems with adequate RAM, temporary workloads

### 2. **ZRAM + Swap Files** (Priority-based tiering)
- ZRAM (priority 100) + Disk swap (priority 10)
- Separate systems, ZRAM fills first
- Best for: Predictable tiering, simple configuration

### 3. **ZRAM + Writeback** ⭐ NEW (Built-in disk overflow)
- ZRAM with `CONFIG_ZRAM_WRITEBACK` support
- Automatic overflow to backing device
- **Decompresses before writing to disk**
- Best for: Integrated solution, automatic management

### 4. **ZSWAP + Swap Files** 🏆 RECOMMENDED (Default)
- Compressed cache in front of disk swap
- Keeps pages compressed on disk writeback
- Automatic pool management
- Best for: Most production systems, VPS environments

### 5. **Swap Files Only** (Traditional)
- Standard disk-based swap
- Multiple files for concurrency
- Best for: Systems with ample disk I/O, simple setups

### 6. **ZFS zvol** (Advanced)
- ZFS zvol with native compression
- Requires `volblocksize=64k` (matches vm.page-cluster)
- Best for: ZFS-based systems, advanced users

### 7. **ZRAM + ZFS zvol** (Hybrid)
- ZRAM for hot pages, ZFS for cold
- Note: Double compression overhead
- Best for: Specific ZFS requirements

See [SWAP_ARCHITECTURE.md](SWAP_ARCHITECTURE.md) for detailed comparison and configuration guides.

## Telegram Notifications Setup

The `sysinfo-notify.py` script can send system information and benchmark results via Telegram.

### ⚠️ Important: First Message Requirement

**You MUST send a message to your bot before it can send you messages!**

1. **Create Bot:**
   - Message [@BotFather](https://t.me/BotFather)
   - Send `/newbot` and follow prompts
   - Save the bot token (looks like `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)

2. **Get Your Chat ID (Choose Method A or B):**

   **Method A: Send Message First (Required!)**
   ```bash
   # 1. Open Telegram and search for your bot (by username)
   # 2. Click "Start" or send any message (like "Hello")
   # 3. THEN run this command:
   curl https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates
   
   # Look for "chat":{"id":12345678,"first_name":"..."} 
   # The number after "id": is your chat_id
   ```

   **Method B: Use Helper Bots (Easier)**
   - Message [@userinfobot](https://t.me/userinfobot) - It will reply with your user ID
   - Or use [@getidsbot](https://t.me/getidsbot) - Similar functionality

3. **Configure Script:**
   ```bash
   export TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
   export TELEGRAM_CHAT_ID="12345678"
   
   # Or edit the script directly
   vim sysinfo-notify.py
   ```

4. **Test:**
   ```bash
   ./sysinfo-notify.py --test
   ```

## Key Features

### Comprehensive Analysis
- **analyze-running-system.sh**: Analyze current memory usage, swap effectiveness, KSM opportunities
- **benchmark.py**: Compare different swap configurations, allocators, and compression algorithms
- **swap-monitor.sh**: Real-time monitoring with correct swap-specific metrics

### Intelligent Configuration
- **Dynamic sizing** based on system RAM (1GB-32GB supported)
- **Kernel defaults capture** - Shows before/after sysctl changes
- **Multiple swap files** (default 8) for I/O concurrency
- **Optimal parameters** tuned for VPS environments

### Advanced Features
- **KSM (Kernel Same-page Merging)**: Temporary testing and effectiveness measurement
- **DAMON/DAMO integration**: Memory profiling and hot/cold region analysis
- **ZRAM writeback**: Built-in disk overflow (kernel 4.14+)
- **Per-service monitoring**: Cgroups v2 swap tracking

## System Requirements

- **OS**: Debian 12 (Bookworm) or Debian 13 (Trixie)
- **Kernel**: 5.10+ (6.1+ recommended for best ZSWAP support)
- **Memory**: 1GB-32GB RAM (auto-scaling)
- **Disk**: Sufficient space for swap files (typically 1-2x RAM)

### Optional Requirements

- **DAMON/DAMO**: `pip3 install damo` (requires CONFIG_DAMON=y)
- **Geekbench**: For benchmark notifications
- **Telegram**: For automated notifications

## Configuration Options

### Environment Variables

```bash
# Swap configuration
export SWAP_ARCHITECTURE="zswap"      # zram|zram-writeback|zswap|files|zfs|hybrid
export SWAP_TOTAL_GB=16               # Total swap space (divided by SWAP_FILES)
export SWAP_FILES=8                   # Number of swap files (for concurrency)

# ZSWAP settings
export ZSWAP_ENABLED=1
export ZSWAP_COMPRESSOR="lz4"        # lz4|zstd|lzo|lzo-rle
export ZSWAP_MAX_POOL_PERCENT=25
export ZSWAP_ZPOOL="z3fold"          # zbud|z3fold|zsmalloc

# ZRAM settings
export ZRAM_SIZE_GB=4
export ZRAM_COMPRESSOR="lz4"
export ZRAM_WRITEBACK_DEV=""         # For ZRAM writeback mode

# KSM settings
export KSM_ENABLED=0                 # Enable permanently (1) or test only (0)
```

## Documentation

- **[SWAP_ARCHITECTURE.md](SWAP_ARCHITECTURE.md)**: Complete technical reference
  - Architecture comparisons
  - ZRAM writeback deep dive
  - Memory profiling with DAMON
  - KSM statistics and usage
  - Monitoring best practices
  - Isolating swap I/O

## Scripts Reference

### Setup & Configuration
- `bootstrap.sh` - Initial system setup for netcup VPS
- `setup-swap.sh` - Main swap configuration script
- `analyze-memory.sh` - Basic memory analysis

### Analysis & Monitoring
- `analyze-running-system.sh` - Comprehensive system analysis with KSM testing
- `swap-monitor.sh` - Real-time swap and memory monitoring
- `benchmark.py` - Performance benchmarking suite

### Notifications
- `sysinfo-notify.py` - System info and Geekbench results via Telegram

## Quick Reference

### Common Commands

```bash
# Check current swap configuration
swapon --show
cat /proc/swaps

# View ZSWAP status
cat /sys/module/zswap/parameters/*

# View ZRAM status
cat /sys/block/zram*/mm_stat

# Monitor swap activity (correct metrics!)
watch -n 1 'grep -E "(pswpin|pswpout|pgmajfault)" /proc/vmstat'

# Check memory pressure
cat /proc/pressure/memory

# KSM statistics
cat /sys/kernel/mm/ksm/pages_sharing
cat /sys/kernel/mm/ksm/pages_shared
```

### Important Notes

1. **SWAP_TOTAL_GB is divided by SWAP_FILES**: 
   - 64GB total / 8 files = 8GB per file
   - Not 64GB per file!

2. **vm.page-cluster controls I/O size, NOT striping**:
   - Default is 3 (reads 8 adjacent pages = 32KB)
   - Multiple files provide concurrency, not striping

3. **vmstat 'si' is misleading**:
   - Counts ALL swap-ins including fast ZSWAP RAM hits
   - Use `pswpin/pswpout` from /proc/vmstat for disk-specific metrics

4. **ZRAM writeback vs ZSWAP**:
   - ZRAM writeback: Decompresses before writing to disk
   - ZSWAP: Keeps pages compressed on disk
   - ZSWAP is more efficient for disk-backed scenarios

5. **Zero-page deduplication**:
   - ZRAM `same_pages` only handles zero-filled pages
   - For arbitrary content deduplication, use KSM
   - Zero-pages: 30-60% (fresh VMs), 10-30% (Java apps)

## Troubleshooting

### Swap not being used
```bash
# Check swap is enabled
sudo swapon --show

# Check memory pressure
cat /proc/pressure/memory

# Check swappiness
cat /proc/sys/vm/swappiness
```

### ZSWAP not working
```bash
# Check if enabled
cat /sys/module/zswap/parameters/enabled

# Check pool type is loaded
lsmod | grep z3fold

# Check if pool is full
cat /sys/kernel/debug/zswap/*
```

### High swap I/O
```bash
# Check what's swapping
for pid in /proc/[0-9]*; do
    awk '/^Swap:/ { sum+=$2 } END { print sum "\t'$(basename $pid)'" }' $pid/smaps 2>/dev/null
done | sort -n | tail -10

# Consider increasing ZSWAP pool or ZRAM size
```

## Performance Tuning

### Low RAM Systems (1-2GB)
```bash
# Prefer zstd compression (better ratio)
# Use zsmalloc allocator (more efficient)
# Consider enabling KSM for containers
sudo ./setup-swap.sh --architecture zswap --compressor zstd --zpool zsmalloc
```

### High RAM Systems (16GB+)
```bash
# Use lz4 compression (faster)
# Larger ZSWAP pool
sudo ./setup-swap.sh --architecture zswap --compressor lz4 --max-pool-percent 30
```

### I/O Bound Systems
```bash
# Increase ZSWAP pool to reduce disk hits
# Use separate partition for swap files
# Monitor with pswpin/pswpout rates
```

## Contributing

Contributions welcome! Please ensure:
- Scripts are POSIX-compliant where possible
- Include comprehensive error handling
- Update documentation for new features
- Test on Debian 12/13

## License

MIT License - See repository root for details.

## References

- [ZSWAP Documentation](https://www.kernel.org/doc/html/latest/admin-guide/mm/zswap.html)
- [ZRAM Documentation](https://www.kernel.org/doc/html/latest/admin-guide/blockdev/zram.html)
- [DAMON Documentation](https://docs.kernel.org/admin-guide/mm/damon/index.html)
- [KSM Documentation](https://www.kernel.org/doc/html/latest/admin-guide/mm/ksm.html)
- [PSI Documentation](https://www.kernel.org/doc/html/latest/accounting/psi.html)
