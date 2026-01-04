# Debian System Setup Toolkit

A comprehensive toolkit for Debian 12/13 system initialization including swap configuration, user environment setup, and performance benchmarking.

## Features

- **7 Swap Architectures**: ZRAM, ZSWAP, swap files/partitions, ZFS zvol, and combinations
- **Intelligent Detection**: Automatic RAM, disk, and storage type detection with dynamic sizing
- **Partition Management**: Create swap partitions at end of disk, extend root partition  
- **User Configuration**: Automated setup for nano, Midnight Commander, iftop, htop, bash aliases
- **APT Management**: Modern deb822 format with backports (priority 600) and testing repositories
- **System Configuration**: Journald log retention, Docker installation with modern settings
- **Performance Testing**: Geekbench integration and comprehensive swap benchmarking
- **Real-time Monitoring**: Correct metrics (pgmajfault, writeback ratio, PSI)
- **Telegram Integration**: Automated notifications with FQDN, file attachments, proper formatting

## Quick Start

### Full System Bootstrap (< 10KB)

For complete system initialization on new Debian installations:

```bash
# Basic setup with swap configuration
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | bash

# Full setup with user config, geekbench, and Telegram notifications
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
  SWAP_ARCH=3 SWAP_TOTAL_GB=16 RUN_GEEKBENCH=yes \
  TELEGRAM_BOT_TOKEN=your_token TELEGRAM_CHAT_ID=your_id bash

# With partition-based swap (extend root, create swap at end)
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
  SWAP_ARCH=7 USE_PARTITION=yes EXTEND_ROOT=yes bash
```

### Manual Installation

```bash
# Clone repository
git clone https://github.com/volkb79/vbpub.git
cd vbpub/scripts/debian-install

# Analyze your system first (recommended)
./analyze-memory.sh

# Run swap setup with defaults (ZSWAP + Swap Files, 8 files)
sudo ./setup-swap.sh

# Configure user environments (nano, mc, iftop, htop)
sudo ./configure-users.sh

# Send system info via Telegram
./sysinfo-notify.py --notify --geekbench

# Monitor swap performance
./swap-monitor.sh
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

### 7. ZRAM + Uncompressed Swap Partition

**Best for:** Debian minimal installs with remaining disk space, or when partitions are preferred over files.

```bash
sudo SWAP_ARCH=7 USE_PARTITION=yes SWAP_TOTAL_GB=8 ./setup-swap.sh
```

Features:
- **ZRAM tier:** zstd+zsmalloc compression (priority 100)
- **Partition tier:** Uncompressed disk partition for overflow (priority 10)
- Efficient single-compression path (unlike ZRAM+files decompress→recompress)
- Partition-based swap can be faster than file-based on some systems

Configuration:
```bash
# Use ZRAM with partition overflow
SWAP_ARCH=7 USE_PARTITION=yes SWAP_PARTITION_SIZE_GB=8 ./setup-swap.sh

# With automatic root partition extension (if space available)
SWAP_ARCH=7 USE_PARTITION=yes EXTEND_ROOT=yes ./setup-swap.sh
```

⚠️ **Partition management:** Creating partitions at end of disk and extending root requires careful handling. The script provides guidance for manual partition setup.

**Use case:** 
- Fresh Debian installs with unallocated space
- Systems where partition-based swap is preferred over file-based
- ZRAM memory-only with disk overflow safety

## Configuration Reference

## Swap Configuration Variables

### Understanding Variable Interaction

#### Basic Concept
You specify **how much disk-based swap** you want (`SWAP_TOTAL_GB`), then choose **how it's stored**:
- **File-based**: Multiple files in `/var/swap/` (default)
- **Partition-based**: Dedicated partition(s) at end of disk

#### Variables

**SWAP_TOTAL_GB** (default: `auto`)
- Total size of disk-based swap space
- `auto`: Calculated based on RAM (2x for ≤2GB RAM, 1x for ≤8GB, etc.)
- Example: `SWAP_TOTAL_GB=16` means 16GB of disk-based swap

**USE_PARTITION** (default: `no`)
- `no`: Use swap files in `/var/swap/`
- `yes`: Use dedicated partition at end of disk

**SWAP_FILES** (default: `8`)
- When `USE_PARTITION=no`: Number of swap files to create
  - Each file is `SWAP_TOTAL_GB / SWAP_FILES` in size
  - Multiple files enable I/O parallelism
- When `USE_PARTITION=yes` and `SWAP_BACKING=ext4`: Number of swap files on the partition
- When `USE_PARTITION=yes` and `SWAP_BACKING=direct`: Ignored (single partition)

**SWAP_PARTITION_SIZE_GB** (default: `auto`)
- Only relevant when `USE_PARTITION=yes`
- `auto`: Uses `SWAP_TOTAL_GB` value
- Explicit value: Override partition size

**SWAP_BACKING** (default: `direct`)
- Only relevant when `USE_PARTITION=yes`
- `direct`: Native swap partition (recommended)
- `ext4`: ext4 filesystem with swap files on it (more flexible)

#### Examples

```bash
# Example 1: 16GB swap in 8 files (default behavior)
SWAP_TOTAL_GB=16 SWAP_FILES=8 ./bootstrap.sh
# Result: 8 × 2GB files in /var/swap/

# Example 2: 16GB swap in single partition
SWAP_TOTAL_GB=16 USE_PARTITION=yes ./bootstrap.sh  
# Result: 16GB partition /dev/vdaN formatted as swap

# Example 3: 16GB partition with 4 files on ext4
SWAP_TOTAL_GB=16 USE_PARTITION=yes SWAP_BACKING=ext4 SWAP_FILES=4 ./bootstrap.sh
# Result: 16GB ext4 partition with 4 × 4GB swap files

# Example 4: Auto-sized swap on partition
SWAP_ARCH=3 USE_PARTITION=yes ./bootstrap.sh
# Result: Auto-calculated size based on RAM, single partition
```

### Debug Mode

Enable detailed tracing and verbose debug output:
```bash
DEBUG_MODE=yes ./bootstrap.sh
```

This enables:
- Bash trace mode (`set -x`) - shows every command executed
- Verbose debug output from `log_debug()` calls
- Detailed command execution logs
- Useful for troubleshooting issues or understanding script behavior

Example with debug mode:
```bash
# Debug a specific swap configuration
DEBUG_MODE=yes SWAP_ARCH=3 USE_PARTITION=yes ./setup-swap.sh

# Debug full bootstrap process
DEBUG_MODE=yes SWAP_TOTAL_GB=16 ./bootstrap.sh
```

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
| `ZRAM_COMPRESSOR` | `lz4` | ZRAM compression algorithm |
| `ZRAM_ALLOCATOR` | `zsmalloc` | ZRAM allocator (zsmalloc, z3fold, zbud) |
| `ZFS_POOL` | `tank` | ZFS pool name for zvol (arch 5 & 6) |
| `USE_PARTITION` | `no` | Use partition instead of files (yes/no) |
| `SWAP_PARTITION_SIZE_GB` | `auto` | Size for swap partition |
| `SWAP_BACKING` | `direct` | Swap backing: `direct` (native swap) or `ext4` (filesystem-backed) |
| `EXTEND_ROOT` | `yes` | Extend root partition after creating swap (yes/no) |
| `DEBUG_MODE` | `no` | Enable bash trace mode and verbose debug logging (yes/no) |
| `RUN_GEEKBENCH` | `yes` | Run Geekbench benchmark during bootstrap (yes/no) |
| `RUN_BENCHMARKS` | `yes` | Run swap benchmarks during bootstrap (yes/no) |
| `TELEGRAM_BOT_TOKEN` | - | Telegram bot token for notifications |
| `TELEGRAM_CHAT_ID` | - | Telegram chat ID for notifications |

### Swap File Sizing Formula

**Important:** `SWAP_TOTAL_GB / SWAP_FILES = per-file size`

Examples:
- `SWAP_TOTAL_GB=16 SWAP_FILES=8` → 8 files of 2GB each
- `SWAP_TOTAL_GB=32 SWAP_FILES=8` → 8 files of 4GB each
- `SWAP_TOTAL_GB=8 SWAP_FILES=4` → 4 files of 2GB each

**Why 8 files?** Enables concurrent I/O operations across multiple swap devices, improving performance under high memory pressure. The kernel uses round-robin allocation across equal-priority devices.

### Swap Backing Options

When using partition-based swap (`USE_PARTITION=yes`), you can choose between two backing types:

**Direct Swap (`SWAP_BACKING=direct`)** - Default
- Partition formatted as native swap (type 82/Linux swap)
- Most efficient - no filesystem overhead
- Single partition or multiple partitions
- Best for most use cases

**Ext4-Backed Swap (`SWAP_BACKING=ext4`)**
- Partition formatted as ext4 filesystem
- Multiple swap files created on the ext4 partition
- Provides flexibility (can mix swap and other data)
- Adds filesystem overhead but enables advanced features
- Useful for dynamic swap management

**Example:**
```bash
# Direct swap (single native swap partition)
SWAP_ARCH=3 USE_PARTITION=yes SWAP_BACKING=direct ./setup-swap.sh

# Ext4-backed (multiple swap files on ext4 partition)
SWAP_ARCH=3 USE_PARTITION=yes SWAP_BACKING=ext4 SWAP_FILES=8 ./setup-swap.sh
```

### ZSWAP and Multi-Device I/O Striping

**Important:** ZSWAP automatically benefits from multiple swap devices!

- **ZSWAP uses ALL configured swap devices** for writeback when its compressed pool fills
- **Kernel swap subsystem handles I/O distribution** across devices with equal priority
- **Multiple swap files/partitions = automatic I/O striping** (round-robin)
- **No special ZSWAP configuration needed** - it works transparently
- **Equal priority is key**: All swap devices with the same priority get round-robin I/O

**Performance benefit:**
- 8 swap files/partitions with equal priority → 8 parallel I/O streams
- Improves throughput and reduces latency under memory pressure
- ZSWAP compressed pool + striped backing storage = optimal performance

**Technical details:**
- ZSWAP has no configurable I/O threads - it uses kernel's swap I/O subsystem
- I/O striping happens at the kernel swap layer, transparent to ZSWAP
- Works with files, partitions, or mixed configurations

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

## Bootstrap Options

The bootstrap script orchestrates complete system setup beyond just swap configuration:

### Bootstrap Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RUN_USER_CONFIG` | `yes` | Configure nano, mc, iftop, htop, bash aliases for all users |
| `RUN_APT_CONFIG` | `yes` | Configure APT with deb822 format, backports, testing repos |
| `RUN_JOURNALD_CONFIG` | `yes` | Configure journald log retention (200M max, 12 months) |
| `RUN_DOCKER_INSTALL` | `no` | Install Docker from official repository with modern settings |
| `RUN_GEEKBENCH` | `no` | Run Geekbench 6 and upload results (5-10 min) |
| `RUN_BENCHMARKS` | `no` | Run comprehensive swap benchmarks |
| `SEND_SYSINFO` | `yes` | Send system info to Telegram if configured |

### Bootstrap Execution Flow

1. **Clone/update repository** from GitHub
2. **Swap configuration** using setup-swap.sh
3. **User environment setup** (if RUN_USER_CONFIG=yes)
   - Install nano, mc, iftop, htop
   - Configure for root and existing users
   - Set /etc/skel defaults for future users
   - Add bash aliases (ll, la, l, colored ls/grep)
4. **APT configuration** (if RUN_APT_CONFIG=yes)
   - Configure sources with deb822 format
   - Add main, contrib, non-free, non-free-firmware
   - Add backports with priority 600 (preferred by default)
   - Add testing with priority 100 (visibility only)
   - Configure APT settings (Debug::pkgPolicy, Show-Versions, AutomaticRemove)
5. **Journald configuration** (if RUN_JOURNALD_CONFIG=yes)
   - Set SystemMaxUse=200M, SystemKeepFree=500M
   - Set SystemMaxFileSize=100M
   - Set retention: 12 months, rotation: 1 month
6. **Docker installation** (if RUN_DOCKER_INSTALL=yes)
   - Add Docker official repository
   - Install docker-ce, docker-compose-plugin, buildx
   - Configure daemon.json with log-driver: local
7. **Geekbench** (if RUN_GEEKBENCH=yes)
   - Download latest version for architecture
   - Run CPU and compute benchmarks
   - Upload to Geekbench Browser
   - Extract result URL and claim URL
8. **Swap benchmarks** (if RUN_BENCHMARKS=yes)
   - Test block sizes, compression algorithms, allocators
   - Test concurrency scaling
   - Export optimal configuration
9. **System info report** (if SEND_SYSINFO=yes)
   - Collect hardware specs
   - Compile configuration details
   - Send formatted report via Telegram
   - Attach detailed system info as file
   - Attach bootstrap log as file

### Example: Complete System Setup

```bash
# Full initialization with all features
curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | \
  SWAP_ARCH=3 \
  SWAP_TOTAL_GB=16 \
  RUN_USER_CONFIG=yes \
  RUN_APT_CONFIG=yes \
  RUN_JOURNALD_CONFIG=yes \
  RUN_DOCKER_INSTALL=yes \
  RUN_GEEKBENCH=yes \
  TELEGRAM_BOT_TOKEN=110201543:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw \
  TELEGRAM_CHAT_ID=123456789 \
  bash
```

## System Configuration

### APT Configuration

The `configure-apt.sh` script sets up APT sources using modern deb822 format with proper priorities:

```bash
# Run APT configuration
sudo ./configure-apt.sh
```

**Features:**
- **Main repository (stable)**: Priority 500 (default)
  - Components: main, contrib, non-free, non-free-firmware
  - Includes security updates
- **Backports**: Priority 600 (preferred by default)
  - Packages from backports are automatically used when available
  - No need for `-t backports` flag
- **Testing**: Priority 100 (visibility only)
  - Available for checking upcoming versions
  - Requires explicit `-t testing` to install
- **APT settings**: `/etc/apt/apt.conf.d/99-custom.conf`
  - Debug::pkgPolicy - Show repository priorities
  - APT::Get::Show-Versions - Display version info
  - APT::Get::AutomaticRemove - Clean up unused dependencies

**Usage:**
```bash
# Install normally - will use backports if newer version available
apt-get install package-name

# Check which repository provides a package
apt-cache policy package-name

# Explicitly install from testing
apt-get install -t testing package-name
```

### Journald Configuration

The `configure-journald.sh` script sets up systemd journal log retention:

```bash
# Run journald configuration
sudo ./configure-journald.sh
```

**Settings:**
- SystemMaxUse=200M - Maximum disk space for logs
- SystemKeepFree=500M - Minimum free space to maintain
- SystemMaxFileSize=100M - Maximum size per log file
- MaxRetentionSec=12month - Keep logs for 12 months
- MaxFileSec=1month - Rotate logs monthly

**Benefits:**
- Prevents runaway log growth
- Ensures disk space availability
- Automatic rotation and cleanup

### Docker Installation

The `install-docker.sh` script installs Docker from official repositories:

```bash
# Run Docker installation
sudo ./install-docker.sh
```

**Features:**
- Official Docker repository (not distro packages)
- Includes: docker-ce, docker-compose-plugin, buildx-plugin
- Modern daemon.json configuration:
  - log-driver: local (efficient, rotating logs)
  - Max log size: 10M per container
  - Max log files: 3 per container
  - storage-driver: overlay2
  - live-restore: enabled
  - BuildKit: enabled
  - Metrics endpoint: 127.0.0.1:9323

**Post-install:**
```bash
# Add user to docker group (requires logout/login)
sudo usermod -aG docker username

# Verify installation
docker --version
docker compose version
docker run --rm hello-world
```

## User Configuration

The `configure-users.sh` script sets up consistent environments for command-line tools.

### Configured Applications

**nano** - Text editor
- Tab size: 4 spaces
- Convert tabs to spaces (Python/VSCode compatible)
- Soft wrap long lines
- Line numbers enabled
- Mouse support
- Syntax highlighting

**Midnight Commander** - File manager
- Skin: modarin256-defbg-thin
- Custom panel format: type, name, size, owner, group, permissions, atime
- Both panels in full user format
- Internal viewer and editor enabled

**iftop** - Network monitor
- Bar graphs enabled
- Port resolution on
- DNS resolution off (faster)
- Two-line display
- Sort by total bandwidth

**htop** - Process monitor
- All CPU meters shown
- Memory and swap meters
- Custom columns for detailed process info
- Tree view available
- Mouse support enabled

**bash** - Shell aliases
- `ll` - ls -alF (detailed list)
- `la` - ls -A (show hidden)
- `l` - ls -CF (compact)
- Colored ls, grep, fgrep, egrep
- Human-readable df, du, free

### Application Scope

- **Immediate:** Configures root and all existing users (UID ≥ 1000)
- **Future:** Sets /etc/skel defaults for new user creation
- **Safe:** Non-destructive, only creates new config files

### Manual Execution

```bash
# Run user configuration separately
sudo ./configure-users.sh

# Verify configurations
ls -la ~/.nanorc ~/.config/mc/ ~/.iftoprc ~/.config/htop/
```

## Partition Management

The toolkit includes full partition management supporting two common VM disk layouts.

### Supported Disk Layouts

**1. Minimal Root Layout** (e.g., 9GB root with 500GB free)
- **Starting point:** Root partition uses only a small portion of disk (e.g., 9GB)
- **Goal:** Use FULL disk - extend root partition, place swap at END
- **Strategy:** 
  - Option A: Extend root to use most of disk, reserve space at end for swap
  - Option B: Simply append swap to free space, optionally extend root later
- **Methods:** Dump-modify-write OR classic partition editing (both supported)
- **Advantages:** No filesystem shrinking needed (only extension), safe and fast
- **Example:** Debian minimal install with "small layout for individual use"
- **Result:** Root partition expanded, swap partitions at end of disk

**2. Full Root Layout** (root uses entire disk)
- Root partition takes all available disk space
- No free space after root partition
- **Strategy:** Dump partition table → modify → write back
  1. Dump current partition table to file
  2. Modify in-memory: shrink root partition size, add swap partition entry
  3. Write entire modified table back to disk
  4. Update kernel with partprobe
  5. Shrink root filesystem to match new partition size
- **Requirements:** Filesystem must support shrinking (ext4, btrfs)
- **Not Supported:** XFS (cannot shrink)
- **Why dump-modify-write:** Most reliable method for rewriting partition table on in-use disk

The script automatically detects the layout and applies the appropriate strategy.

### Supported Operations

1. **Create swap partition at end of disk**
   - Auto-detects disk layout (minimal root vs. full root)
   - For minimal root: Appends to free space
   - For full root: Shrinks root, then appends
   - Uses sfdisk for scripted operations
   - Formats as swap with mkswap
   - Activates and adds to /etc/fstab using PARTUUID

2. **Filesystem resizing** (for full root layout)
   - ext4/ext3/ext2: Supports online shrinking with resize2fs
   - btrfs: Supports online resizing
   - XFS: **Not supported** (cannot shrink, must use minimal root layout)

### Partition Management Examples

```bash
# Direct swap partition (native swap, most efficient)
sudo SWAP_ARCH=3 USE_PARTITION=yes SWAP_BACKING=direct SWAP_PARTITION_SIZE_GB=16 ./setup-swap.sh

# Ext4-backed swap (multiple files on ext4 partition)
sudo SWAP_ARCH=3 USE_PARTITION=yes SWAP_BACKING=ext4 SWAP_PARTITION_SIZE_GB=32 SWAP_FILES=8 ./setup-swap.sh

# Minimal root layout - extend root and add swap at end
sudo SWAP_ARCH=3 USE_PARTITION=yes SWAP_PARTITION_SIZE_GB=16 EXTEND_ROOT=yes ./setup-swap.sh

# Full root layout - shrink root and add swap (ext4/btrfs only)
sudo SWAP_ARCH=3 USE_PARTITION=yes SWAP_PARTITION_SIZE_GB=32 ./setup-swap.sh

# Architecture 7: ZRAM + partition overflow with ext4-backed swap
sudo SWAP_ARCH=7 USE_PARTITION=yes SWAP_BACKING=ext4 SWAP_FILES=4 ./setup-swap.sh
```

### Safety Features

- **Automatic layout detection:** Script detects which scenario applies
- **Partition table backup:** Saved before any changes
- **Verification:** Partition table verified after changes
- **PARTUUID usage:** Stable across mkswap calls (UUID changes each time)
- **Error handling:** Detailed error messages and rollback guidance
- **XFS protection:** Refuses to proceed with full root + XFS

### Technical Notes

**sfdisk on in-use disk:**
- Uses `--force --no-reread` flags together
- Always reports: "Re-reading the partition table failed: Device or resource busy"
- This is **expected behavior** when disk is mounted
- Kernel partition table updated with `partprobe` or `partx --update` after
- **For full root scenario:** Uses dump-modify-write approach:
  1. `sfdisk --dump` to save current table
  2. Modify the dump file (change sizes, add partitions)
  3. `sfdisk --force --no-reread < modified.dump` to write entire table
  4. Most reliable for complex changes on in-use disk

**PARTUUID vs UUID:**
- PARTUUID: Partition UUID (stable, doesn't change)
- UUID: Filesystem/swap UUID (changes on each mkswap)
- Use PARTUUID in /etc/fstab for swap partitions

### Manual Partition Operations

The toolkit provides detailed guidance for manual partition operations when automatic execution is not desired:

```bash
# Detect current layout
sudo ./setup-swap.sh --detect-only

# Step-by-step partition creation
# 1. Calculate sizes (sectors to MiB conversion)
# 2. Backup partition table: sfdisk --dump /dev/vda > backup.dump
# 3. Extend root: echo ",490492M" | sfdisk --force /dev/vda -N3
# 4. Add swap: echo ",,S" | sfdisk --force /dev/vda -N4
# 5. Verify: sfdisk --verify /dev/vda
# 6. Update kernel: partprobe /dev/vda
# 7. Resize filesystem: resize2fs /dev/vda3
# 8. Format swap: mkswap /dev/vda4
# 9. Activate: swapon /dev/vda4
# 10. Add to fstab using PARTUUID
```

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

### Telegram Notification Improvements

**FQDN Support**: System identification now uses Fully Qualified Domain Names
```
Before: v1001 (152.53.166.181)
After:  v1001.example.com (152.53.166.181)
```

**Proper Newlines**: Messages now display correctly formatted with line breaks
```
Before: v1001 (152.53.166.181)\n🚀 Starting system setup
After:  v1001.example.com (152.53.166.181)
        🚀 Starting system setup
```

**File Attachments**: System information and logs are sent as downloadable files
- Detailed system info JSON
- Bootstrap execution logs
- Easy archival and sharing

### Logging

All logs are stored in `/var/log/debian-install/`:
```
/var/log/debian-install/
  ├── bootstrap-20260104-221645.log
  ├── bootstrap-20260104-223012.log
  └── ...
```

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
| `setup-swap.sh` | Main swap installation and configuration |
| `configure-users.sh` | User environment setup (nano, mc, htop, iftop, bash aliases) |
| `configure-apt.sh` | APT repository configuration (deb822, backports, testing) |
| `configure-journald.sh` | Journald log retention settings |
| `install-docker.sh` | Docker installation from official repository |
| `analyze-memory.sh` | Pre-installation system analysis |
| `benchmark.py` | Performance testing and comparison |
| `swap-monitor.sh` | Real-time monitoring with correct metrics |
| `sysinfo-notify.py` | System info and Telegram notifications |
| `system_info.py` | System information collection module |
| `telegram_client.py` | Telegram messaging client with FQDN and file attachments |
| `geekbench_runner.py` | Geekbench benchmark runner |
| `ksm-trial.sh` | KSM effectiveness testing |
| `test-improvements.sh` | Test suite for verifying improvements |

## References

- Kernel documentation: [Admin Guide - Swap](https://www.kernel.org/doc/html/latest/admin-guide/mm/swap.html)
- ZRAM: [Admin Guide - ZRAM](https://www.kernel.org/doc/html/latest/admin-guide/blockdev/zram.html)
- ZSWAP: [VM - ZSWAP](https://www.kernel.org/doc/html/latest/vm/zswap.html)
- ZFS on Linux: [OpenZFS Documentation](https://openzfs.github.io/openzfs-docs/)

## Contributing

Found an issue or have a suggestion? Please open an issue at: https://github.com/volkb79/vbpub/issues

## License

See repository LICENSE file.
