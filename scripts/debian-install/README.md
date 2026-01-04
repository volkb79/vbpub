# Debian Multi-Tier Swap Setup

A comprehensive swap configuration and memory analysis toolkit for Debian systems, designed for optimal performance across various workloads.

## Quick Start - Netcup Bootstrap

For new Netcup VPS installations:

```bash
# 1. Run bootstrap script (sets up basic system + Telegram notifications)
curl -sSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | bash

# 2. Configure swap (choose your architecture)
bash /root/setup-swap.sh

# 3. Monitor system
bash /root/swap-monitor.sh
```

## Architecture Options Overview

This toolkit supports **7 different swap architectures**, each optimized for different use cases:

### 1. **ZRAM Only** (Best for: Small VMs, development)
- Compressed RAM-only swap
- No disk I/O
- Fast but limited by available RAM

### 2. **ZRAM + Swap Files** (Best for: General purpose, balanced workload)
- Priority-based tiering
- Fast ZRAM tier + slower disk tier
- Recommended for most use cases

### 3. **ZRAM + Writeback** (Best for: Kernel 4.14+, experimental)
- ZRAM with backing device
- Writes DECOMPRESSED pages to disk
- Less efficient disk usage than ZSWAP

### 4. **ZSWAP + Swap Files** (Best for: Production, disk-backed)
- **RECOMMENDED** for production systems
- Writes COMPRESSED pages directly to disk
- Most efficient disk space usage
- No decompress→recompress overhead

### 5. **Swap Files Only** (Best for: Traditional setups)
- Simple, well-tested approach
- No compression overhead
- Predictable behavior

### 6. **ZFS zvol** (Best for: ZFS systems)
- Native ZFS swap device
- Deduplication and compression
- Set volblocksize to match vm.page-cluster (e.g., 64k)

### 7. **ZRAM + ZFS zvol** (Caution: Performance overhead)
- Not recommended due to double compression
- Decompress→recompress overhead
- Consider ZSWAP + ZFS instead

## Telegram Notification Setup

### Critical First Step

**⚠️ YOU MUST SEND A MESSAGE TO YOUR BOT FIRST** before `getUpdates` will return your chat ID!

1. Create a bot with [@BotFather](https://t.me/BotFather)
2. Get your bot token (format: `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)
3. **IMPORTANT: Send a message to your bot** (e.g., `/start` or "hello")
4. Get your chat ID:
   ```bash
   curl -s "https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates" | jq
   ```
   Look for `"chat":{"id":123456789,...}` in the response

### Alternative Methods to Get Chat ID

If `getUpdates` doesn't work or you prefer alternatives:

- [@userinfobot](https://t.me/userinfobot) - Send any message, get your ID
- [@getidsbot](https://t.me/getidsbot) - Send `/start` to get your chat ID
- [@RawDataBot](https://t.me/RawDataBot) - Shows complete message data including chat ID

### Usage in Scripts

Add to your environment:
```bash
export TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
export TELEGRAM_CHAT_ID="123456789"
```

## Installation

### Automated Setup

```bash
# Download all scripts
curl -sSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/setup-swap.sh -o setup-swap.sh
chmod +x setup-swap.sh

# Run with desired architecture (default: ZSWAP + Swap Files)
./setup-swap.sh
```

### Manual Setup

1. Clone repository or download scripts
2. Review `SWAP_ARCHITECTURE.md` to choose your architecture
3. Edit `setup-swap.sh` configuration section
4. Run setup script with root privileges
5. Reboot to apply changes

## Tools Included

### Setup and Configuration
- `setup-swap.sh` - Main swap configuration script
- `bootstrap.sh` - Initial system setup for Netcup VPS

### Monitoring and Analysis
- `swap-monitor.sh` - Real-time swap and memory monitoring
- `analyze-memory.sh` - Detailed memory analysis for running systems
- `ksm-trial.sh` - Test KSM (Kernel Same-page Merging) benefits

### Benchmarking and Testing
- `benchmark.py` - Comprehensive swap performance benchmarks
- `sysinfo-notify.py` - System info + Geekbench with Telegram notifications

## Documentation

- [SWAP_ARCHITECTURE.md](./SWAP_ARCHITECTURE.md) - Complete technical documentation
- [MEMORY_ANALYSIS.md](./MEMORY_ANALYSIS.md) - Memory analysis tools and techniques

## Quick Examples

### Monitor Swap Performance
```bash
# Real-time monitoring with correct metrics
./swap-monitor.sh

# Analyze current memory usage
./analyze-memory.sh
```

### Benchmark Different Configurations
```bash
# Test ZRAM vs ZSWAP
python3 benchmark.py --test zram-vs-zswap

# Test different compressors
python3 benchmark.py --test compressors
```

### Test KSM Benefits
```bash
# Run KSM trial (3 full scans)
./ksm-trial.sh

# Apply recommendation
./ksm-trial.sh --apply
```

## System Requirements

- Debian 10+ (Buster or newer)
- Root access
- Kernel 4.14+ (for advanced features like ZRAM writeback)
- Python 3.7+ (for benchmark and notification scripts)

## Performance Tips

1. **Choose the right architecture** - Read SWAP_ARCHITECTURE.md
2. **Monitor regularly** - Use swap-monitor.sh to track performance
3. **Adjust based on workload** - Different workloads need different configs
4. **Consider KSM** - Run ksm-trial.sh to check if beneficial
5. **Use ZSWAP for production** - Best balance of performance and reliability

## Troubleshooting

### High swap usage
```bash
# Check what's using swap
./analyze-memory.sh

# Monitor swap I/O
./swap-monitor.sh
```

### Poor performance
```bash
# Run benchmark to compare configurations
python3 benchmark.py --test all

# Check for disk bottlenecks
iostat -x 5
```

### Memory pressure
```bash
# Check PSI (Pressure Stall Information)
cat /proc/pressure/memory

# Analyze with DAMON (if available)
./analyze-memory.sh --damon
```

## Contributing

Improvements and bug reports are welcome! Please ensure:
- Scripts remain POSIX-compatible where possible
- Documentation is updated for new features
- Testing on clean Debian installation

## License

MIT License - See repository root for details

## Credits

Developed for efficient VPS management with focus on Netcup and similar providers.
