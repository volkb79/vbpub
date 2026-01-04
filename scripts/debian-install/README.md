# Debian Multi-Tier Swap Configuration Toolkit

A comprehensive swap setup system for Debian 12/13 optimized for VPS environments (tested on netcup servers). Supports multiple architecture options with automatic detection and benchmarking.

## Quick Start - netcup Bootstrap

For fresh Debian 12/13 installations on netcup or similar VPS:

```bash
# Minimal bootstrap - downloads and runs setup
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | bash
```

With custom configuration:

```bash
# Configure via environment variables
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
  SWAP_TOTAL_GB=64 \
  SWAP_FILES=8 \
  SWAP_ARCH=zswap-files \
  TELEGRAM_BOT_TOKEN="your_token" \
  TELEGRAM_CHAT_ID="your_chat_id" \
  bash
```

## Architecture Options Overview

This toolkit supports 6 distinct swap architectures. See [SWAP_ARCHITECTURE.md](SWAP_ARCHITECTURE.md) for comprehensive technical details.

### 1. ZRAM Only
- **Best for:** Systems with fast CPUs and moderate memory pressure
- **Pros:** Zero disk I/O, fastest swap-in
- **Cons:** Limited by RAM, no persistent swap
- **Use case:** Development servers, workloads with predictable memory usage

### 2. ZRAM + Swap Files (Two-Tier)
- **Best for:** Systems needing both speed and capacity
- **Pros:** Fast L1 cache (ZRAM), fallback to disk
- **Cons:** Decompress→recompress cycle on ZRAM overflow
- **Use case:** General-purpose servers with mixed workloads

### 3. ZSWAP + Swap Files (Recommended)
- **Best for:** Most production environments
- **Pros:** Single compression, efficient disk writes, no double compression
- **Cons:** Slightly more complex setup
- **Use case:** Production VPS, databases, web servers with significant memory pressure

### 4. Swap Files Only
- **Best for:** Very slow CPUs or SSDs with high endurance
- **Pros:** Simple, predictable, no CPU overhead
- **Cons:** No compression benefits, slower than compressed alternatives
- **Use case:** Legacy hardware, specific compatibility requirements

### 5. ZFS Compressed Swap (zvol)
- **Best for:** ZFS-native systems
- **Pros:** Integrated compression, dataset management
- **Cons:** Requires ZFS, block alignment considerations
- **Use case:** ZFS-based deployments, storage-focused systems
- **Note:** Set `volblocksize` to match `vm.page-cluster` (default 4KB = 4K blocksize)

### 6. ZRAM + ZFS zvol
- **Best for:** Maximum compression ratio regardless of efficiency
- **Pros:** Double compression for extreme space savings
- **Cons:** Significant CPU overhead (decompress→recompress), inefficient
- **Use case:** Research/testing, extremely constrained storage
- **Warning:** Not recommended for production due to double compression work

## Configuration Reference

### Environment Variables

```bash
# Core Configuration
SWAP_TOTAL_GB=64           # Total swap space across all files (default: auto-calculated)
SWAP_FILES=8               # Number of swap files for concurrency (default: 8)
SWAP_ARCH=zswap-files      # Architecture: zram-only, zram-files, zswap-files, 
                           #              files-only, zfs-zvol, zram-zfs

# ZRAM/ZSWAP Configuration
ZRAM_SIZE_PERCENT=50       # ZRAM size as % of RAM (default: 50)
ZRAM_COMP_ALGO=zstd        # Compression: lz4, zstd, lzo-rle (default: auto-detected)
ZRAM_ALLOCATOR=zsmalloc    # Allocator: zsmalloc (~90%), z3fold (~75%), zbud (~50%)
ZSWAP_COMP_ALGO=zstd       # ZSWAP compression algorithm
ZSWAP_POOL_PERCENT=20      # ZSWAP pool size as % of RAM

# Kernel Parameters
VM_PAGE_CLUSTER=3          # Swap I/O block size: 0=4KB, 1=8KB, 2=16KB, 3=32KB (default: 3)
VM_SWAPPINESS=60           # Swap tendency: 0-100 (default: 60)
VM_VFS_CACHE_PRESSURE=100  # Cache reclaim pressure (default: 100)

# System Behavior
AUTO_BENCHMARK=true        # Run automatic benchmark to choose best config
SKIP_INSTALL=false         # Skip package installation (for testing)

# Notifications
TELEGRAM_BOT_TOKEN=        # Telegram bot token for notifications
TELEGRAM_CHAT_ID=          # Telegram chat ID or @channel_name
```

### Dynamic Sizing Tables

The toolkit automatically calculates swap sizes based on available RAM and disk space:

| RAM   | Disk   | Default Total | Default Files | Per File | Recommended Arch    |
|-------|--------|---------------|---------------|----------|---------------------|
| 1GB   | 30GB   | 4GB           | 4             | 1GB      | zswap-files (zstd)  |
| 2GB   | 40GB   | 8GB           | 4             | 2GB      | zswap-files (zstd)  |
| 4GB   | 80GB   | 16GB          | 8             | 2GB      | zswap-files         |
| 8GB   | 160GB  | 32GB          | 8             | 4GB      | zswap-files         |
| 16GB  | 320GB  | 64GB          | 8             | 8GB      | zswap-files or zram |
| 32GB+ | 640GB+ | 128GB         | 8             | 16GB     | zram-only or zswap  |

**Important:** `SWAP_TOTAL_GB / SWAP_FILES = per-file size`. For example:
- `SWAP_TOTAL_GB=64 SWAP_FILES=8` → 8 files × 8GB each
- `SWAP_TOTAL_GB=32 SWAP_FILES=4` → 4 files × 8GB each

## Telegram Setup Instructions

To receive system notifications via Telegram:

### Step 1: Create a Bot

1. Open Telegram and search for [@BotFather](https://t.me/BotFather)
2. Send `/newbot` and follow the prompts
3. Save the bot token (format: `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)

### Step 2: Get Your Chat ID

**CRITICAL:** You must send a message to your bot first before the bot can send messages to you!

#### Method A: Using your bot directly
1. Find your bot in Telegram and click "Start" or send any message
2. Get your chat ID using the getUpdates API:
   ```bash
   curl -s "https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates" | jq '.result[0].message.chat.id'
   ```

#### Method B: Using a helper bot (easier)
1. Open [@userinfobot](https://t.me/userinfobot) or [@getidsbot](https://t.me/getidsbot)
2. Send any message - the bot will reply with your chat ID

#### For Channel Notifications
1. Create a channel and add your bot as an administrator
2. Use the channel username with @ prefix: `@your_channel_name`
3. OR post a message in the channel and use getUpdates to get the channel ID

### Step 3: Configure Environment Variables

```bash
export TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
export TELEGRAM_CHAT_ID="123456789"  # or @your_channel_name
```

### Testing Notifications

```bash
# Test your configuration
./sysinfo-notify.py --test

# Send system info without Geekbench
./sysinfo-notify.py

# Full system info with Geekbench
./sysinfo-notify.py --geekbench
```

## Installation

### Manual Installation

```bash
# Clone repository
git clone https://github.com/volkb79/vbpub.git
cd vbpub/scripts/debian-install

# Analyze current memory state (optional)
sudo ./analyze-memory.sh

# Run setup with defaults (auto-detects best configuration)
sudo ./setup-swap.sh

# Run setup with specific architecture
sudo SWAP_ARCH=zswap-files SWAP_TOTAL_GB=64 ./setup-swap.sh

# Run benchmark to find optimal settings
sudo ./benchmark.py --test-all --output results.json
```

### What Gets Installed

- **Packages:** `zstd`, `python3`, `python3-requests`, `sysstat`, `bc`, `jq`
- **Kernel modules:** ZRAM and/or ZSWAP based on selected architecture
- **Configuration files:** `/etc/sysctl.d/99-swap.conf`, `/etc/systemd/system/zram*.service` (if using ZRAM)
- **Swap files:** Created in `/swapfile.{0..N}` with proper permissions
- **Monitoring tools:** `swap-monitor.sh` installed to `/usr/local/bin/`

## Post-Installation Commands

### Verify Setup

```bash
# Check swap configuration
sudo swapon --show

# View ZRAM status (if using ZRAM)
zramctl

# View ZSWAP status (if using ZSWAP)
grep -r . /sys/module/zswap/parameters/ 2>/dev/null

# Check kernel parameters
sysctl vm.swappiness vm.page-cluster vm.vfs_cache_pressure

# View current memory state
free -h

# Detailed swap usage
cat /proc/swaps
```

### Real-Time Monitoring

```bash
# Launch interactive monitor (updates every 5 seconds)
sudo swap-monitor.sh

# One-shot status check
sudo swap-monitor.sh --once

# Export metrics for external monitoring
sudo swap-monitor.sh --json
```

### Performance Analysis

```bash
# Check swap-in/out activity
vmstat 1 10

# View pressure stall information (PSI)
cat /proc/pressure/memory

# Check major page faults (indicator of actual disk I/O)
grep pgmajfault /proc/vmstat

# ZSWAP writeback ratio (lower is better)
echo "scale=2; $(cat /sys/kernel/debug/zswap/written_back_pages) * 100 / $(cat /sys/kernel/debug/zswap/pool_pages)" | bc

# View per-process swap usage
for pid in $(ps -eo pid | tail -n +2); do
    swap=$(grep VmSwap /proc/$pid/status 2>/dev/null | awk '{print $2}')
    if [ "$swap" -gt 0 ] 2>/dev/null; then
        echo "$pid: ${swap}KB - $(ps -p $pid -o comm=)"
    fi
done | sort -t: -k2 -n -r | head -20
```

### Adjust Parameters at Runtime

```bash
# Increase swap aggression
sudo sysctl vm.swappiness=80

# Reduce swap I/O size for random access workloads
sudo sysctl vm.page-cluster=1

# Disable ZSWAP temporarily
echo N | sudo tee /sys/module/zswap/parameters/enabled

# Change ZSWAP algorithm (if available)
echo lz4 | sudo tee /sys/module/zswap/parameters/compressor

# Make changes persistent
sudo nano /etc/sysctl.d/99-swap.conf
```

### Troubleshooting

```bash
# Check for swap errors
sudo dmesg | grep -i swap

# Check ZRAM for errors
sudo dmesg | grep -i zram

# Verify compression algorithms available
cat /sys/block/zram0/comp_algorithm  # ZRAM
cat /sys/module/zswap/parameters/compressor  # ZSWAP

# Test swap performance
sudo dd if=/dev/zero of=/swapfile.0 bs=1M count=1024 oflag=direct
sudo hdparm -t /dev/sda  # or appropriate device

# Check for OOM events
sudo dmesg | grep -i "out of memory"
```

### Remove/Modify Swap

```bash
# Disable all swap
sudo swapoff -a

# Remove specific swap file
sudo swapoff /swapfile.0
sudo rm /swapfile.0

# Disable ZRAM
sudo systemctl stop zram-swap
sudo systemctl disable zram-swap
sudo modprobe -r zram

# Re-run setup with new configuration
sudo SWAP_ARCH=files-only SWAP_TOTAL_GB=32 ./setup-swap.sh
```

## Monitoring Best Practices

**Don't rely solely on `vmstat si` (swap-in) numbers!** The `si` counter includes ZSWAP RAM pool hits, which are NOT actual disk I/O.

### Better Metrics for Detecting "Working Set Too Large"

1. **pgmajfault** - Actual page faults requiring disk I/O
   ```bash
   watch -n 1 "grep pgmajfault /proc/vmstat"
   ```

2. **ZSWAP writeback ratio** - Percentage of compressed pages evicted to disk
   ```bash
   # Lower is better (<1% is excellent, >10% indicates pressure)
   echo "scale=2; $(cat /sys/kernel/debug/zswap/written_back_pages) * 100 / $(cat /sys/kernel/debug/zswap/pool_pages)" | bc
   ```

3. **PSI (Pressure Stall Information)** - Measures actual resource contention
   ```bash
   cat /proc/pressure/memory
   # Watch for "full" pressure > 0 (indicates stalled tasks)
   ```

4. **Swap device await** - I/O latency for swap devices
   ```bash
   iostat -x 1 10 | grep -A5 "^Device"
   # Watch await column for swap devices
   ```

See [SWAP_ARCHITECTURE.md](SWAP_ARCHITECTURE.md) for detailed explanations of these metrics.

## Files Overview

- **README.md** (this file) - Quick start and user guide
- **SWAP_ARCHITECTURE.md** - Comprehensive technical documentation
- **bootstrap.sh** - Minimal bootstrap script for remote deployment
- **setup-swap.sh** - Main orchestrator and configuration script
- **benchmark.py** - Performance testing and algorithm selection
- **swap-monitor.sh** - Real-time monitoring and diagnostics
- **analyze-memory.sh** - Pre-installation memory analysis
- **sysinfo-notify.py** - System information and Telegram notifications

## References

- [Debian Wiki - Swap](https://wiki.debian.org/Swap)
- [Linux Kernel Documentation - ZRAM](https://www.kernel.org/doc/html/latest/admin-guide/blockdev/zram.html)
- [Linux Kernel Documentation - ZSWAP](https://www.kernel.org/doc/Documentation/vm/zswap.txt)
- [vm.page-cluster sysctl](https://www.kernel.org/doc/Documentation/sysctl/vm.txt)

## License

Part of the vbpub repository - see repository LICENSE for details.

## Contributing

Issues and pull requests welcome at: https://github.com/volkb79/vbpub
