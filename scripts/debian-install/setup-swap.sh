#!/bin/bash
# Debian Swap Configuration Setup Script
# Comprehensive swap orchestrator supporting 7 architectures
# Requires: Debian 12/13, root privileges
#
# Supported Disk Layouts for Partition-Based Swap:
# 1. MINIMAL ROOT: Small root partition (~9GB) with remaining unallocated space
#    - Goal: Use FULL disk - extend root partition, place swap at END of disk
#    - Process: Extend root to use most of disk, reserve space at end for swap
#    - Can use either dump-modify-write OR classic partition editing
#    - No filesystem resizing needed (only extension)
# 2. FULL ROOT: Root partition uses entire disk
#    - Shrinks root partition (partition table + filesystem)
#    - Adds swap partition to reclaimed space at END of disk
#    - Requires filesystem that supports shrinking (ext4, btrfs)
#    - XFS not supported (cannot shrink)
#
# Swap Backing Storage Options:
# - Direct swap partitions: Format partition as swap (type 82/Linux swap)
# - Ext4-backed swap: Format partition as ext4, mount, create swap file on it
#   (provides flexibility but adds filesystem overhead)
#
# ZSWAP Multi-Device I/O:
# - ZSWAP automatically uses ALL configured swap devices for writeback
# - Kernel swap subsystem distributes I/O across devices with EQUAL priority
# - Multiple swap files/partitions = natural I/O striping (round-robin)
# - No special ZSWAP configuration needed - works automatically
# - Benefit: Multiple I/O streams improve concurrency and throughput
#
# Partition Management Notes:
# - Uses sfdisk for scripted partition operations
# - When disk is in-use, sfdisk with --force --no-reread will succeed but report:
#   "Re-reading the partition table failed: Device or resource busy"
#   This is expected behavior, partprobe/partx updates kernel after
# - PARTUUID is used in fstab for swap (stable across mkswap calls)
# - UUID changes on each mkswap call, PARTUUID does not

set -euo pipefail

# Debug mode
DEBUG_MODE="${DEBUG_MODE:-no}"
if [ "$DEBUG_MODE" = "yes" ]; then
    set -x  # Enable bash trace
fi

# Configuration variables with defaults (NEW NAMING CONVENTION)
# Load benchmark-optimized configuration if available
SWAP_BENCHMARK_CONFIG="${SWAP_BENCHMARK_CONFIG:-}"
if [ -n "$SWAP_BENCHMARK_CONFIG" ] && [ -f "$SWAP_BENCHMARK_CONFIG" ]; then
    # Security: Only source files from /tmp with expected name pattern
    case "$SWAP_BENCHMARK_CONFIG" in
        /tmp/benchmark-*.sh)
            echo "[INFO] Loading benchmark-optimized configuration from $SWAP_BENCHMARK_CONFIG"
            # Source the benchmark config which may override defaults
            . "$SWAP_BENCHMARK_CONFIG"
            ;;
        *)
            echo "[WARN] Ignoring SWAP_BENCHMARK_CONFIG from unexpected location: $SWAP_BENCHMARK_CONFIG"
            ;;
    esac
fi

# RAM-based swap configuration
SWAP_RAM_SOLUTION="${SWAP_RAM_SOLUTION:-auto}"  # zram, zswap, none (auto = auto-detect)
SWAP_RAM_TOTAL_GB="${SWAP_RAM_TOTAL_GB:-auto}"  # RAM dedicated to compression (auto = calculated)
ZRAM_COMPRESSOR="${ZRAM_COMPRESSOR:-lz4}"  # lz4, zstd, lzo-rle (can be overridden by benchmark)
ZRAM_ALLOCATOR="${ZRAM_ALLOCATOR:-zsmalloc}"  # zsmalloc, z3fold, zbud (can be overridden by benchmark)
ZRAM_PRIORITY="${ZRAM_PRIORITY:-100}"  # Priority for ZRAM (higher = preferred)
ZSWAP_COMPRESSOR="${ZSWAP_COMPRESSOR:-lz4}"  # lz4, zstd, lzo-rle (can be overridden by benchmark)
ZSWAP_ZPOOL="${ZSWAP_ZPOOL:-z3fold}"  # z3fold, zbud, zsmalloc

# Disk-based swap configuration
SWAP_DISK_TOTAL_GB="${SWAP_DISK_TOTAL_GB:-auto}"  # Total disk-based swap (auto = calculated)
SWAP_BACKING_TYPE="${SWAP_BACKING_TYPE:-auto}"  # files_in_root, partitions_swap, partitions_zvol, files_in_partitions, none (auto = auto-detect)
SWAP_STRIPE_WIDTH="${SWAP_STRIPE_WIDTH:-8}"  # Number of parallel swap devices (for I/O striping)
SWAP_PRIORITY="${SWAP_PRIORITY:-10}"  # Priority for disk swap (lower than RAM)
EXTEND_ROOT="${EXTEND_ROOT:-yes}"  # Extend root partition when creating swap partitions at end of disk

# ZFS-specific
ZFS_POOL="${ZFS_POOL:-tank}"  # ZFS pool name for zvol-based swap

# Telegram
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Directories
SWAP_DIR="/var/swap"
SYSCTL_CONF="/etc/sysctl.d/99-swap.conf"
LOG_FILE="${LOG_FILE:-/dev/null}"  # Fallback if not set by bootstrap

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_debug() { 
    if [ "$DEBUG_MODE" = "yes" ]; then
        echo -e "${CYAN}[DEBUG]${NC} $*"
    fi
}
log_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

# Get system identification
get_system_id() {
    # Get FQDN (fully qualified domain name)
    local hostname=$(hostname -f 2>/dev/null || hostname)
    local ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
    echo "${hostname} (${ip})"
}

# Telegram notification with source attribution
telegram_send() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] && return 0
    [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    local msg="$1"
    local system_id=$(get_system_id)
    # Use actual newline in string, not \n escape
    local prefixed_msg="<b>${system_id}</b>
${msg}"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${prefixed_msg}" \
        -d "parse_mode=HTML" >/dev/null 2>&1 || true
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Print banner
print_banner() {
    cat <<'EOF'
╔═══════════════════════════════════════════════════════╗
║   Debian Swap Configuration Toolkit                   ║
║   Intelligent auto-configuration for optimal swap     ║
╚═══════════════════════════════════════════════════════╝
EOF
}

# Print current kernel defaults BEFORE changes
print_current_config() {
    log_step "Current Kernel Swap Configuration (BEFORE changes)"
    echo ""
    echo "=== Kernel Parameters ==="
    sysctl vm.swappiness 2>/dev/null || echo "vm.swappiness = (not set)"
    sysctl vm.page-cluster 2>/dev/null || echo "vm.page-cluster = (not set)"
    sysctl vm.vfs_cache_pressure 2>/dev/null || echo "vm.vfs_cache_pressure = (not set)"
    sysctl vm.watermark_scale_factor 2>/dev/null || echo "vm.watermark_scale_factor = (not set)"
    sysctl vm.min_free_kbytes 2>/dev/null || echo "vm.min_free_kbytes = (not set)"
    
    echo ""
    echo "=== ZSWAP Configuration ==="
    if [ -d /sys/module/zswap ]; then
        echo "zswap.enabled = $(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo '?')"
        echo "zswap.max_pool_percent = $(cat /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || echo '?')"
        echo "zswap.compressor = $(cat /sys/module/zswap/parameters/compressor 2>/dev/null || echo '?')"
        echo "zswap.zpool = $(cat /sys/module/zswap/parameters/zpool 2>/dev/null || echo '?')"
    else
        echo "ZSWAP module not loaded"
    fi
    
    echo ""
    echo "=== Current Swap Devices ==="
    swapon --show 2>/dev/null || echo "No swap devices active"
    
    echo ""
    echo "=== Memory Status ==="
    free -h
    echo ""
}

# Detect system specifications
detect_system() {
    log_step "Detecting system specifications"
    
    # RAM in GB
    RAM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    RAM_GB=$((RAM_TOTAL_KB / 1024 / 1024))
    log_info "RAM: ${RAM_GB}GB"
    
    # Disk space - get both available space and total capacity
    DISK_AVAIL_KB=$(df -k / | tail -1 | awk '{print $4}')
    DISK_AVAIL_GB=$((DISK_AVAIL_KB / 1024 / 1024))
    log_info "Available disk space: ${DISK_AVAIL_GB}GB"
    
    # Get total disk capacity (not just available space)
    # Find root partition and disk (using temporary variables to avoid conflicts with later usage)
    local detect_root_partition=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
    if [ -n "$detect_root_partition" ]; then
        local detect_root_disk=$(lsblk -no PKNAME "$detect_root_partition" 2>/dev/null | head -1)
        if [ -n "$detect_root_disk" ]; then
            DISK_SIZE_SECTORS=$(blockdev --getsz "/dev/$detect_root_disk" 2>/dev/null || echo "0")
            DISK_TOTAL_GB=$((DISK_SIZE_SECTORS / 2048 / 1024))
            log_info "Total disk capacity: ${DISK_TOTAL_GB}GB"
        else
            DISK_TOTAL_GB=$DISK_AVAIL_GB
            log_warn "Could not determine disk capacity, using available space"
        fi
    else
        DISK_TOTAL_GB=$DISK_AVAIL_GB
        log_warn "Could not determine root partition, using available space"
    fi
    
    # Use DISK_GB for backward compatibility (will be set based on context)
    # For partition-based swap, we'll use DISK_TOTAL_GB
    # For file-based swap, we'll use DISK_AVAIL_GB
    DISK_GB=$DISK_AVAIL_GB
    
    # CPU cores
    CPU_CORES=$(nproc)
    log_info "CPU cores: $CPU_CORES"
    
    # Check for ZFS
    if command -v zfs >/dev/null 2>&1; then
        ZFS_AVAILABLE=1
        log_info "ZFS: Available"
    else
        ZFS_AVAILABLE=0
        log_debug "ZFS: Not available"
    fi
    
    # Check available compressors
    if [ -f /sys/block/zram0/comp_algorithm ]; then
        AVAILABLE_COMPRESSORS=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | tr -d '[]')
    else
        AVAILABLE_COMPRESSORS="lz4 zstd lzo-rle"
    fi
    log_debug "Available compressors: $AVAILABLE_COMPRESSORS"
    
    # Detect storage type (SSD vs HDD) and disk info
    STORAGE_TYPE="unknown"
    ROOT_PARTITION=$(findmnt -n -o SOURCE / 2>/dev/null || echo "unknown")
    ROOT_DISK=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's|/dev/||')
    if [ -f "/sys/block/${ROOT_DISK}/queue/rotational" ]; then
        if [ "$(cat /sys/block/${ROOT_DISK}/queue/rotational)" = "0" ]; then
            STORAGE_TYPE="ssd"
            log_info "Storage: SSD detected"
        else
            STORAGE_TYPE="hdd"
            log_info "Storage: HDD detected"
        fi
    fi
}

# Auto-detect optimal swap configuration based on system characteristics
auto_detect_swap_configuration() {
    log_step "Auto-detecting optimal swap configuration"
    
    # Auto-detect SWAP_RAM_SOLUTION if not set or set to "auto"
    if [ -z "$SWAP_RAM_SOLUTION" ] || [ "$SWAP_RAM_SOLUTION" = "auto" ]; then
        # Decision tree based on RAM and storage type
        if [ "$RAM_GB" -ge 16 ]; then
            # High RAM systems: ZSWAP is optimal (low overhead, good compression)
            SWAP_RAM_SOLUTION="zswap"
            log_info "Auto-selected: ZSWAP (high RAM system ≥16GB)"
        elif [ "$RAM_GB" -ge 4 ]; then
            # Medium RAM: ZSWAP recommended for balanced performance
            SWAP_RAM_SOLUTION="zswap"
            log_info "Auto-selected: ZSWAP (medium RAM system)"
        else
            # Low RAM: ZRAM for maximum compression and performance
            SWAP_RAM_SOLUTION="zram"
            log_info "Auto-selected: ZRAM (low RAM system <4GB, maximizes available memory)"
        fi
    else
        log_info "SWAP_RAM_SOLUTION explicitly set: $SWAP_RAM_SOLUTION"
    fi
    
    # Auto-detect SWAP_BACKING_TYPE if not set or set to "auto"
    if [ -z "$SWAP_BACKING_TYPE" ] || [ "$SWAP_BACKING_TYPE" = "auto" ]; then
        # Decision tree based on available disk space and storage type
        # NEVER select "none" - always have disk overflow protection
        # Use DISK_AVAIL_GB for file-based decisions (needs free space NOW)
        # Use DISK_TOTAL_GB for partition-based decisions (will create space via repartitioning)
        if [ "$DISK_AVAIL_GB" -lt 15 ]; then
            # Very low available space: use partition-based swap (will repartition)
            if [ "$DISK_TOTAL_GB" -ge 50 ]; then
                SWAP_BACKING_TYPE="partitions_swap"
                log_info "Auto-selected: Swap partitions (low available space but adequate total capacity)"
            else
                # Very small disk: use files in root (most flexible)
                SWAP_BACKING_TYPE="files_in_root"
                log_info "Auto-selected: Swap files in root (very low disk space <15GB, but overflow protection required)"
            fi
        elif [ "$ZFS_AVAILABLE" -eq 1 ]; then
            # ZFS available: use zvol for compressed swap
            SWAP_BACKING_TYPE="partitions_zvol"
            log_info "Auto-selected: ZFS zvol swap (ZFS available)"
        elif [ "$STORAGE_TYPE" = "ssd" ] && [ "$DISK_TOTAL_GB" -ge 50 ]; then
            # SSD with sufficient total capacity: prefer partitions for better performance
            SWAP_BACKING_TYPE="partitions_swap"
            log_info "Auto-selected: Swap partitions (SSD with adequate capacity)"
        elif [ "$STORAGE_TYPE" = "hdd" ] && [ "$DISK_TOTAL_GB" -ge 100 ]; then
            # HDD with good capacity: use partitions for better I/O
            SWAP_BACKING_TYPE="partitions_swap"
            log_info "Auto-selected: Swap partitions (HDD with ample capacity)"
        else
            # Default fallback: files in root (safest, most flexible)
            SWAP_BACKING_TYPE="files_in_root"
            log_info "Auto-selected: Swap files in root (default/fallback with overflow protection)"
        fi
    else
        log_info "SWAP_BACKING_TYPE explicitly set: $SWAP_BACKING_TYPE"
    fi
    
    log_info "Final configuration: RAM=$SWAP_RAM_SOLUTION, Backing=$SWAP_BACKING_TYPE"
}

# Calculate dynamic swap sizes
calculate_swap_sizes() {
    log_step "Calculating optimal swap sizes"
    
    # Calculate SWAP_DISK_TOTAL_GB if auto
    # ALWAYS ensure disk-based swap for overflow protection
    if [ "$SWAP_DISK_TOTAL_GB" = "auto" ]; then
        # For partition-based swap, use DISK_TOTAL_GB (will repartition to create space)
        # For file-based swap, use DISK_AVAIL_GB (needs free space now)
        local disk_reference_gb
        if [[ "$SWAP_BACKING_TYPE" == "partitions_swap" || "$SWAP_BACKING_TYPE" == "partitions_zvol" || "$SWAP_BACKING_TYPE" == "files_in_partitions" ]]; then
            disk_reference_gb=$DISK_TOTAL_GB
            log_info "Using total disk capacity (${DISK_TOTAL_GB}GB) for partition-based swap sizing"
        else
            disk_reference_gb=$DISK_AVAIL_GB
            log_info "Using available space (${DISK_AVAIL_GB}GB) for file-based swap sizing"
        fi
        
        if [ "$RAM_GB" -le 2 ]; then
            # For very low RAM, use 2x RAM for disk swap
            SWAP_DISK_TOTAL_GB=$((RAM_GB * 2))
            [ "$SWAP_DISK_TOTAL_GB" -lt 4 ] && SWAP_DISK_TOTAL_GB=4
            log_info "Low RAM system: Using ${SWAP_DISK_TOTAL_GB}GB disk swap (min 4GB)"
        elif [ "$RAM_GB" -le 4 ]; then
            # 4GB disk swap for 2-4GB RAM
            SWAP_DISK_TOTAL_GB=4
            log_info "Using ${SWAP_DISK_TOTAL_GB}GB disk swap"
        elif [ "$RAM_GB" -le 8 ]; then
            # 8GB disk swap for 4-8GB RAM
            SWAP_DISK_TOTAL_GB=8
            log_info "Using ${SWAP_DISK_TOTAL_GB}GB disk swap"
        elif [ "$RAM_GB" -le 16 ]; then
            # 16-32GB disk swap for 8-16GB RAM (scaling)
            SWAP_DISK_TOTAL_GB=$((RAM_GB * 2))
            [ "$SWAP_DISK_TOTAL_GB" -gt 32 ] && SWAP_DISK_TOTAL_GB=32
            log_info "Using ${SWAP_DISK_TOTAL_GB}GB disk swap (scaling to 32GB max)"
        else
            # Cap at 32GB for high RAM systems
            SWAP_DISK_TOTAL_GB=32
            log_info "High RAM system: Using ${SWAP_DISK_TOTAL_GB}GB disk swap (capped)"
        fi
        
        # Check if we have enough space
        if [ "$SWAP_DISK_TOTAL_GB" -gt "$disk_reference_gb" ]; then
            log_warn "Requested swap (${SWAP_DISK_TOTAL_GB}GB) exceeds available capacity (${disk_reference_gb}GB)"
            # Cap at 25% of disk for safety
            SWAP_DISK_TOTAL_GB=$((disk_reference_gb / 4))
            [ "$SWAP_DISK_TOTAL_GB" -lt 2 ] && SWAP_DISK_TOTAL_GB=2
            log_warn "Adjusted disk swap to ${SWAP_DISK_TOTAL_GB}GB (25% of capacity)"
        fi
    fi
    
    # Override backing type to ensure disk swap unless explicitly set to none
    # NEVER auto-select "none" - always have disk overflow
    if [ "$SWAP_BACKING_TYPE" = "auto" ]; then
        # Re-evaluate backing type but never choose "none"
        if [ "$DISK_AVAIL_GB" -lt 20 ]; then
            log_warn "Low available space (<20GB) but disk swap is required for overflow protection"
            log_warn "Using partition-based swap to leverage total disk capacity (${DISK_TOTAL_GB}GB)"
            SWAP_BACKING_TYPE="partitions_swap"
            # Keep swap size as calculated above
        fi
    fi
    
    # Only disable disk swap if EXPLICITLY set to none or 0
    # This prevents accidental OOM situations
    if [ "$SWAP_BACKING_TYPE" = "none" ] || [ "$SWAP_DISK_TOTAL_GB" = "0" ]; then
        if [ "$SWAP_BACKING_TYPE" != "none" ]; then
            SWAP_BACKING_TYPE="none"
        fi
        SWAP_DISK_TOTAL_GB=0
        log_warn "⚠️  Disk-based swap DISABLED - system may run out of memory!"
        log_warn "⚠️  This configuration is NOT recommended for production use"
    else
        log_info "✓ Disk-based swap enabled for overflow protection"
    fi
    
    # Check disk constraints - use appropriate reference
    if [ "$SWAP_DISK_TOTAL_GB" -gt 0 ]; then
        local disk_ref_for_check
        if [[ "$SWAP_BACKING_TYPE" == "partitions_swap" || "$SWAP_BACKING_TYPE" == "partitions_zvol" || "$SWAP_BACKING_TYPE" == "files_in_partitions" ]]; then
            disk_ref_for_check=$DISK_TOTAL_GB
        else
            disk_ref_for_check=$DISK_AVAIL_GB
        fi
        
        if [ "$disk_ref_for_check" -lt 30 ]; then
            log_warn "Limited disk space (${disk_ref_for_check}GB). Adjusting swap configuration if needed"
            if [ "$SWAP_DISK_TOTAL_GB" -gt "$((disk_ref_for_check / 4))" ]; then
                SWAP_DISK_TOTAL_GB=$((disk_ref_for_check / 4))
                [ "$SWAP_DISK_TOTAL_GB" -lt 2 ] && SWAP_DISK_TOTAL_GB=2
                log_warn "Adjusted disk swap to ${SWAP_DISK_TOTAL_GB}GB (25% of disk capacity)"
            fi
        fi
    fi
    
    # Calculate SWAP_RAM_TOTAL_GB if auto
    if [ "$SWAP_RAM_TOTAL_GB" = "auto" ]; then
        SWAP_RAM_TOTAL_GB=$((RAM_GB / 2))
        [ "$SWAP_RAM_TOTAL_GB" -lt 1 ] && SWAP_RAM_TOTAL_GB=1
        [ "$SWAP_RAM_TOTAL_GB" -gt 16 ] && SWAP_RAM_TOTAL_GB=16
        log_info "RAM swap size: ${SWAP_RAM_TOTAL_GB}GB (50% of RAM)"
    fi
    
    # If SWAP_RAM_SOLUTION is none or SWAP_RAM_TOTAL_GB is 0, disable RAM swap
    if [ "$SWAP_RAM_SOLUTION" = "none" ] || [ "$SWAP_RAM_TOTAL_GB" = "0" ]; then
        SWAP_RAM_TOTAL_GB=0
        log_info "RAM-based swap compression disabled"
    fi
    
    # Calculate per-device size for striping
    if [ "$SWAP_DISK_TOTAL_GB" -gt 0 ]; then
        SWAP_DEVICE_SIZE_GB=$((SWAP_DISK_TOTAL_GB / SWAP_STRIPE_WIDTH))
        if [ "$SWAP_DEVICE_SIZE_GB" -lt 1 ]; then
            SWAP_DEVICE_SIZE_GB=1
            SWAP_STRIPE_WIDTH=$SWAP_DISK_TOTAL_GB
            log_warn "Adjusted: $SWAP_STRIPE_WIDTH devices of ${SWAP_DEVICE_SIZE_GB}GB each"
        else
            log_info "Swap striping: $SWAP_STRIPE_WIDTH devices of ${SWAP_DEVICE_SIZE_GB}GB each = ${SWAP_DISK_TOTAL_GB}GB total"
        fi
    fi
    
    # Recommendations for low RAM
    if [ "$RAM_GB" -le 2 ]; then
        log_warn "Low RAM detected. Recommend: ZSWAP_COMPRESSOR=zstd or ZRAM_COMPRESSOR=zstd"
        if [ "$SWAP_RAM_SOLUTION" = "zswap" ] && [ "$ZSWAP_COMPRESSOR" = "lz4" ]; then
            log_warn "Current ZSWAP compressor is lz4. Consider zstd for better compression ratio."
        fi
        if [ "$SWAP_RAM_SOLUTION" = "zram" ] && [ "$ZRAM_COMPRESSOR" = "lz4" ]; then
            log_warn "Current ZRAM compressor is lz4. Consider zstd for better compression ratio."
        fi
    fi
}

# Print system analysis and execution plan
print_system_analysis_and_plan() {
    log_step "System Analysis & Configuration Plan"
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║              SYSTEM ANALYSIS                          ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    echo "Hardware Detected:"
    echo "  RAM:           ${RAM_GB}GB"
    echo "  Disk Total:    ${DISK_TOTAL_GB}GB"
    echo "  Disk Available: ${DISK_AVAIL_GB}GB"
    echo "  CPU Cores:     ${CPU_CORES}"
    echo "  Storage Type:  ${STORAGE_TYPE}"
    if [ "$SWAP_BACKING_TYPE" != "files_in_root" ] && [ "$SWAP_BACKING_TYPE" != "none" ]; then
        echo "  Root Disk:     /dev/${ROOT_DISK}"
        echo "  Root Partition: ${ROOT_PARTITION}"
    fi
    echo ""
    
    echo "Current Swap Status:"
    if swapon --show | grep -q '^/'; then
        swapon --show
    else
        echo "  No active swap"
    fi
    echo ""
    
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║           DERIVED CONFIGURATION                       ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    echo "Configuration Method: Intelligent Auto-Detection"
    echo "  RAM Solution:  $SWAP_RAM_SOLUTION"
    echo "  Backing Type:  $SWAP_BACKING_TYPE"
    echo ""
    # RAM-based swap configuration
    if [ "$SWAP_RAM_SOLUTION" != "none" ] && [ "$SWAP_RAM_TOTAL_GB" -gt 0 ]; then
        echo "RAM-based Swap Configuration:"
        echo "  Solution:      ${SWAP_RAM_SOLUTION}"
        echo "  Size:          ${SWAP_RAM_TOTAL_GB}GB"
        if [ "$SWAP_RAM_SOLUTION" = "zram" ]; then
            echo "  Compressor:    ${ZRAM_COMPRESSOR}"
            echo "  Allocator:     ${ZRAM_ALLOCATOR}"
            echo "  Priority:      ${ZRAM_PRIORITY}"
        elif [ "$SWAP_RAM_SOLUTION" = "zswap" ]; then
            # Calculate actual pool size in GB
            POOL_SIZE_GB=$(awk "BEGIN {printf \"%.1f\", ${RAM_GB} * 0.20}")
            echo "  Pool Size:     20% of RAM (~${POOL_SIZE_GB}GB)"
            echo "  Compressor:    ${ZSWAP_COMPRESSOR}"
            echo "  Zpool:         ${ZSWAP_ZPOOL}"
        fi
        echo ""
    else
        echo "RAM-based Swap: Disabled"
        echo ""
    fi
    
    # Disk-based swap configuration
    if [ "$SWAP_BACKING_TYPE" != "none" ] && [ "$SWAP_DISK_TOTAL_GB" -gt 0 ]; then
        echo "Disk-based Swap Configuration:"
        echo "  Total Size:    ${SWAP_DISK_TOTAL_GB}GB"
        echo "  Backing Type:  ${SWAP_BACKING_TYPE}"
        echo "  Stripe Width:  ${SWAP_STRIPE_WIDTH} devices"
        echo "  Device Size:   ${SWAP_DEVICE_SIZE_GB}GB each"
        echo "  Priority:      ${SWAP_PRIORITY}"
        
        case "$SWAP_BACKING_TYPE" in
            files_in_root)
                echo "  Location:      ${SWAP_DIR}/"
                echo "  Type:          Swap files in root filesystem"
                ;;
            partitions_swap)
                echo "  Type:          Native swap partitions"
                echo "  Partitions:    ${SWAP_STRIPE_WIDTH} × ${SWAP_DEVICE_SIZE_GB}GB"
                ;;
            partitions_zvol)
                echo "  Type:          ZFS zvol partitions"
                echo "  ZFS Pool:      ${ZFS_POOL}"
                echo "  Compression:   lz4 (via ZFS)"
                ;;
            files_in_partitions)
                echo "  Type:          Swap files on ext4 partition"
                echo "  Partition:     ${SWAP_DISK_TOTAL_GB}GB ext4"
                echo "  Files:         ${SWAP_STRIPE_WIDTH} × ${SWAP_DEVICE_SIZE_GB}GB"
                ;;
        esac
        echo ""
    else
        echo "Disk-based Swap: Disabled"
        echo ""
    fi
    
    echo "Kernel Parameters:"
    echo "  vm.swappiness: $([ "$RAM_GB" -le 2 ] && echo "80" || [ "$RAM_GB" -ge 16 ] && echo "10" || echo "60")"
    echo "  vm.page-cluster: $([ "$STORAGE_TYPE" = "hdd" ] && echo "4 (64KB)" || echo "3 (32KB)")"
    echo ""
    
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║              EXECUTION PLAN                           ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    echo "The following changes will be made:"
    echo "  1. Disable any existing swap"
    
    local step=2
    
    # RAM-based swap setup
    if [ "$SWAP_RAM_SOLUTION" = "zram" ] && [ "$SWAP_RAM_TOTAL_GB" -gt 0 ]; then
        echo "  ${step}. Create ZRAM device (${SWAP_RAM_TOTAL_GB}GB compressed)"
        ((step++))
    elif [ "$SWAP_RAM_SOLUTION" = "zswap" ] && [ "$SWAP_RAM_TOTAL_GB" -gt 0 ]; then
        echo "  ${step}. Enable ZSWAP (20% pool, ${ZSWAP_COMPRESSOR} compression)"
        ((step++))
    fi
    
    # Disk-based swap setup
    if [ "$SWAP_BACKING_TYPE" != "none" ] && [ "$SWAP_DISK_TOTAL_GB" -gt 0 ]; then
        case "$SWAP_BACKING_TYPE" in
            files_in_root)
                echo "  ${step}. Create ${SWAP_STRIPE_WIDTH} swap files in ${SWAP_DIR}/"
                ;;
            partitions_swap)
                echo "  ${step}. Create ${SWAP_STRIPE_WIDTH} native swap partitions at end of disk"
                if [ "$EXTEND_ROOT" = "yes" ]; then
                    echo "     - Extend root partition to use remaining space"
                    echo "     - Reserve ${SWAP_DISK_TOTAL_GB}GB at end for swap"
                fi
                ;;
            partitions_zvol)
                echo "  ${step}. Create ZFS zvol for swap (${SWAP_DISK_TOTAL_GB}GB)"
                ;;
            files_in_partitions)
                echo "  ${step}. Create ext4 partition and ${SWAP_STRIPE_WIDTH} swap files on it"
                if [ "$EXTEND_ROOT" = "yes" ]; then
                    echo "     - Extend root partition to use remaining space"
                    echo "     - Reserve ${SWAP_DISK_TOTAL_GB}GB at end for ext4 partition"
                fi
                ;;
        esac
        ((step++))
    fi
    
    echo "  ${step}. Configure kernel parameters in ${SYSCTL_CONF}"
    ((step++))
    echo "  ${step}. Add swap to /etc/fstab for persistence"
    echo ""
    
    # Warnings
    local show_warnings=0
    local warning_msgs=""
    
    # Check available space for file-based swap
    if [ "$SWAP_BACKING_TYPE" = "files_in_root" ] && [ "$DISK_AVAIL_GB" -lt 30 ] && [ "$SWAP_DISK_TOTAL_GB" -gt 0 ]; then
        show_warnings=1
        warning_msgs="${warning_msgs}⚠️  Low available disk space (${DISK_AVAIL_GB}GB)\n"
        warning_msgs="${warning_msgs}⚠️  Consider using partition-based swap to leverage full disk capacity\n"
    fi
    
    # Check for partition-based swap on small total disks
    if [[ "$SWAP_BACKING_TYPE" == "partitions_swap" || "$SWAP_BACKING_TYPE" == "partitions_zvol" || "$SWAP_BACKING_TYPE" == "files_in_partitions" ]]; then
        if [ "$DISK_TOTAL_GB" -lt 50 ]; then
            show_warnings=1
            warning_msgs="${warning_msgs}⚠️  Small total disk capacity (${DISK_TOTAL_GB}GB)\n"
            warning_msgs="${warning_msgs}⚠️  Root partition will be extended, then swap partitions added at end\n"
        fi
    fi
    
    if [ "$RAM_GB" -le 2 ]; then
        show_warnings=1
        warning_msgs="${warning_msgs}⚠️  Low RAM detected (${RAM_GB}GB)\n"
        if [ "$SWAP_RAM_SOLUTION" = "zswap" ]; then
            warning_msgs="${warning_msgs}⚠️  Recommended: ZSWAP_COMPRESSOR=zstd for better compression\n"
        elif [ "$SWAP_RAM_SOLUTION" = "zram" ]; then
            warning_msgs="${warning_msgs}⚠️  Recommended: ZRAM_COMPRESSOR=zstd for better compression\n"
        fi
    fi
    
    if [ "$show_warnings" -eq 1 ]; then
        echo ""
        printf '%b\n' "$warning_msgs"
    fi
    
    # Send configuration plan to Telegram
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        local telegram_msg="🔧 <b>Swap Configuration Plan</b>

📊 <b>System Analysis:</b>
• RAM: ${RAM_GB}GB
• Disk Total: ${DISK_TOTAL_GB}GB
• Disk Available: ${DISK_AVAIL_GB}GB
• Storage: ${STORAGE_TYPE}
• CPU: ${CPU_CORES} cores

⚙️ <b>Auto-Detected Config:</b>"
        
        # RAM Solution details
        if [ "$SWAP_RAM_SOLUTION" != "none" ] && [ "$SWAP_RAM_TOTAL_GB" -gt 0 ]; then
            telegram_msg="${telegram_msg}
• <b>RAM Solution:</b> ${SWAP_RAM_SOLUTION} ($([ "$RAM_GB" -le 4 ] && echo "low RAM system" || [ "$RAM_GB" -ge 16 ] && echo "high RAM system" || echo "medium RAM system"))"
            if [ "$SWAP_RAM_SOLUTION" = "zram" ]; then
                telegram_msg="${telegram_msg}
  - Compressor: ${ZRAM_COMPRESSOR}
  - Allocator: ${ZRAM_ALLOCATOR}
  - Priority: ${ZRAM_PRIORITY}"
            elif [ "$SWAP_RAM_SOLUTION" = "zswap" ]; then
                # Calculate actual pool size in GB
                POOL_SIZE_GB=$(awk "BEGIN {printf \"%.1f\", ${RAM_GB} * 0.20}")
                telegram_msg="${telegram_msg}
  - Compressor: ${ZSWAP_COMPRESSOR}
  - Pool: 20% of RAM (~${POOL_SIZE_GB}GB)
  - Zpool: ${ZSWAP_ZPOOL}"
            fi
        fi
        
        # Disk backing details
        if [ "$SWAP_BACKING_TYPE" != "none" ] && [ "$SWAP_DISK_TOTAL_GB" -gt 0 ]; then
            telegram_msg="${telegram_msg}
• <b>Disk Backing:</b> ${SWAP_BACKING_TYPE}
  - Size: ${SWAP_DISK_TOTAL_GB}GB"
            if [ "$SWAP_BACKING_TYPE" = "files_in_root" ]; then
                telegram_msg="${telegram_msg}
  - Stripe Width: ${SWAP_STRIPE_WIDTH} files × ${SWAP_DEVICE_SIZE_GB}GB
  - Priority: ${SWAP_PRIORITY} (lower than RAM)"
            elif [ "$SWAP_BACKING_TYPE" = "partitions_swap" ]; then
                telegram_msg="${telegram_msg}
  - Partitions: ${SWAP_STRIPE_WIDTH} × ${SWAP_DEVICE_SIZE_GB}GB"
            fi
        fi
        
        # Execution plan
        telegram_msg="${telegram_msg}

📋 <b>Execution Plan:</b>
1. Disable existing swap"
        
        local step=2
        if [ "$SWAP_RAM_SOLUTION" = "zram" ] && [ "$SWAP_RAM_TOTAL_GB" -gt 0 ]; then
            telegram_msg="${telegram_msg}
${step}. Create ZRAM device (${SWAP_RAM_TOTAL_GB}GB compressed)"
            ((step++))
        elif [ "$SWAP_RAM_SOLUTION" = "zswap" ] && [ "$SWAP_RAM_TOTAL_GB" -gt 0 ]; then
            telegram_msg="${telegram_msg}
${step}. Enable ZSWAP (20% pool, ${ZSWAP_COMPRESSOR} compression)"
            ((step++))
        fi
        
        if [ "$SWAP_BACKING_TYPE" != "none" ] && [ "$SWAP_DISK_TOTAL_GB" -gt 0 ]; then
            case "$SWAP_BACKING_TYPE" in
                files_in_root)
                    telegram_msg="${telegram_msg}
${step}. Create ${SWAP_STRIPE_WIDTH} swap files in /var/swap/"
                    ;;
                partitions_swap)
                    telegram_msg="${telegram_msg}
${step}. Create ${SWAP_STRIPE_WIDTH} swap partitions at end of disk"
                    ;;
                partitions_zvol)
                    telegram_msg="${telegram_msg}
${step}. Create ZFS zvol for swap (${SWAP_DISK_TOTAL_GB}GB)"
                    ;;
                files_in_partitions)
                    telegram_msg="${telegram_msg}
${step}. Create ext4 partition and ${SWAP_STRIPE_WIDTH} swap files"
                    ;;
            esac
            ((step++))
        fi
        
        telegram_msg="${telegram_msg}
${step}. Configure kernel parameters
$((step+1)). Add swap to /etc/fstab for persistence"
        
        # Add warnings
        local has_warnings=0
        if [ "$SWAP_BACKING_TYPE" = "files_in_root" ] && [ "$DISK_AVAIL_GB" -lt 30 ] && [ "$SWAP_DISK_TOTAL_GB" -gt 0 ]; then
            if [ "$has_warnings" -eq 0 ]; then
                telegram_msg="${telegram_msg}

⚠️ <b>Warnings:</b>"
                has_warnings=1
            fi
            telegram_msg="${telegram_msg}
• Low available space (${DISK_AVAIL_GB}GB), but total disk is ${DISK_TOTAL_GB}GB"
        fi
        
        if [[ "$SWAP_BACKING_TYPE" == "partitions_swap" || "$SWAP_BACKING_TYPE" == "partitions_zvol" || "$SWAP_BACKING_TYPE" == "files_in_partitions" ]]; then
            if [ "$DISK_TOTAL_GB" -lt 50 ]; then
                if [ "$has_warnings" -eq 0 ]; then
                    telegram_msg="${telegram_msg}

⚠️ <b>Warnings:</b>"
                    has_warnings=1
                fi
                telegram_msg="${telegram_msg}
• Small disk (${DISK_TOTAL_GB}GB) - will repartition to create swap space"
            fi
        fi
        
        if [ "$RAM_GB" -le 2 ]; then
            if [ "$has_warnings" -eq 0 ]; then
                telegram_msg="${telegram_msg}

⚠️ <b>Warnings:</b>"
                has_warnings=1
            fi
            telegram_msg="${telegram_msg}
• Low RAM (${RAM_GB}GB) - recommend zstd compression"
        fi
        
        telegram_send "$telegram_msg"
    fi
    
    log_info "Press Ctrl+C within 5 seconds to cancel, or wait to proceed..."
    sleep 5
    echo ""
}

# Install dependencies
install_dependencies() {
    log_step "Installing dependencies"
    
    export DEBIAN_FRONTEND=noninteractive
    
    apt-get update -qq
    
    # Essential packages
    local packages=(
        util-linux
        gawk
        sysstat
        curl
    )
    
    # Python for scripts
    if ! command -v python3 >/dev/null 2>&1; then
        packages+=(python3)
    fi
    
    # ZFS if needed and not installed
    if [ "$SWAP_BACKING_TYPE" = "partitions_zvol" ]; then
        if [ "$ZFS_AVAILABLE" -eq 0 ]; then
            log_info "Installing ZFS..."
            packages+=(zfsutils-linux)
        fi
    fi
    
    log_info "Installing: ${packages[*]}"
    apt-get install -y -qq "${packages[@]}"
    
    log_info "Dependencies installed"
}

# Disable existing swap
disable_existing_swap() {
    log_step "Disabling existing swap devices"
    
    if swapon --show | grep -q '^/'; then
        log_info "Disabling active swap devices..."
        swapoff -a || log_warn "Some swap devices may not have been disabled"
        
        # Remove from fstab
        if grep -q "swap" /etc/fstab; then
            log_info "Backing up and cleaning /etc/fstab..."
            cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d_%H%M%S)
            sed -i '/swap/d' /etc/fstab
        fi
        
        # Remove old swap files
        if [ -d "$SWAP_DIR" ]; then
            log_info "Removing old swap files from $SWAP_DIR..."
            rm -f "$SWAP_DIR"/swapfile* || true
        fi
        
        log_info "Existing swap disabled"
    else
        log_info "No existing swap devices found"
    fi
}

# Setup ZRAM
setup_zram() {
    log_step "Setting up ZRAM"
    
    # Load module
    modprobe zram || {
        log_error "Failed to load zram module"
        return 1
    }
    
    # Configure ZRAM device
    if [ ! -b /dev/zram0 ]; then
        log_error "ZRAM device /dev/zram0 not found"
        return 1
    fi
    
    # Set algorithm
    log_info "Setting ZRAM compressor: $ZRAM_COMPRESSOR"
    echo "$ZRAM_COMPRESSOR" > /sys/block/zram0/comp_algorithm || {
        log_warn "Failed to set compressor, using default"
    }
    
    # Set size
    local zram_size_bytes=$((SWAP_RAM_TOTAL_GB * 1024 * 1024 * 1024))
    log_info "Setting ZRAM size: ${SWAP_RAM_TOTAL_GB}GB"
    echo "$zram_size_bytes" > /sys/block/zram0/disksize
    
    # Format and activate
    mkswap /dev/zram0
    swapon -p "$ZRAM_PRIORITY" /dev/zram0
    
    log_info "ZRAM setup complete (priority: $ZRAM_PRIORITY)"
    
    # Add to systemd for persistence
    # Use actual values at service creation time
    local comp="$ZRAM_COMPRESSOR"
    local size="$zram_size_bytes"
    local prio="$ZRAM_PRIORITY"
    
    cat > /etc/systemd/system/zram-swap.service <<EOF
[Unit]
Description=ZRAM Swap
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'modprobe zram && echo $comp > /sys/block/zram0/comp_algorithm && echo $size > /sys/block/zram0/disksize && mkswap /dev/zram0 && swapon -p $prio /dev/zram0'
ExecStop=/bin/bash -c 'swapoff /dev/zram0 && rmmod zram'

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable zram-swap.service
}

# Setup ZSWAP
setup_zswap() {
    log_step "Setting up ZSWAP"
    
    # Use fixed 20% pool size
    local ZSWAP_POOL_PERCENT=20
    
    # Enable ZSWAP
    if [ -d /sys/module/zswap ]; then
        log_info "Enabling ZSWAP"
        echo 1 > /sys/module/zswap/parameters/enabled
        
        log_info "Setting ZSWAP pool: ${ZSWAP_POOL_PERCENT}% of RAM"
        echo "$ZSWAP_POOL_PERCENT" > /sys/module/zswap/parameters/max_pool_percent
        
        log_info "Setting ZSWAP compressor: $ZSWAP_COMPRESSOR"
        echo "$ZSWAP_COMPRESSOR" > /sys/module/zswap/parameters/compressor 2>/dev/null || {
            log_warn "Failed to set ZSWAP compressor, using default"
        }
        
        # Set zpool (allocator)
        echo "z3fold" > /sys/module/zswap/parameters/zpool 2>/dev/null || {
            log_warn "Failed to set zpool, using default"
        }
        
        log_info "ZSWAP setup complete"
    else
        log_error "ZSWAP module not available"
        return 1
    fi
    
    # Add kernel parameters for boot
    if ! grep -q "zswap.enabled" /etc/default/grub; then
        log_info "Adding ZSWAP to GRUB config"
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="zswap.enabled=1 zswap.compressor='$ZSWAP_COMPRESSOR' zswap.max_pool_percent='$ZSWAP_POOL_PERCENT' /' /etc/default/grub
        update-grub || log_warn "Failed to update GRUB"
    fi
}

# Create swap files
create_swap_files() {
    log_step "Creating swap files"
    
    # Create directory
    mkdir -p "$SWAP_DIR"
    
    log_info "Creating $SWAP_STRIPE_WIDTH swap files of ${SWAP_DEVICE_SIZE_GB}GB each..."
    
    for i in $(seq 1 "$SWAP_STRIPE_WIDTH"); do
        local swapfile="${SWAP_DIR}/swapfile${i}"
        
        log_debug "Creating $swapfile (${SWAP_DEVICE_SIZE_GB}GB)..."
        
        # Use fallocate for speed (if supported) or dd
        if fallocate -l "${SWAP_DEVICE_SIZE_GB}G" "$swapfile" 2>/dev/null; then
            log_debug "  Created with fallocate"
        else
            log_debug "  Creating with dd (slower)..."
            dd if=/dev/zero of="$swapfile" bs=1M count=$((SWAP_DEVICE_SIZE_GB * 1024)) status=progress
        fi
        
        # Set permissions
        chmod 600 "$swapfile"
        
        # Format as swap
        mkswap "$swapfile"
        
        # Activate
        swapon -p "$SWAP_PRIORITY" "$swapfile"
        
        # Add to fstab
        echo "$swapfile none swap sw,pri=${SWAP_PRIORITY} 0 0" >> /etc/fstab
    done
    
    log_info "Swap files created and activated"
}

# Setup ZFS zvol
setup_zfs_zvol() {
    log_step "Setting up ZFS zvol"
    
    # Check if pool exists
    if ! zpool list "$ZFS_POOL" >/dev/null 2>&1; then
        log_error "ZFS pool '$ZFS_POOL' not found"
        return 1
    fi
    
    local zvol_name="${ZFS_POOL}/swap"
    local zvol_path="/dev/zvol/${zvol_name}"
    
    # Calculate volblocksize based on vm.page-cluster
    local page_cluster=$(sysctl -n vm.page-cluster 2>/dev/null || echo 3)
    local volblocksize
    case $page_cluster in
        0) volblocksize="4k" ;;
        1) volblocksize="8k" ;;
        2) volblocksize="16k" ;;
        3) volblocksize="32k" ;;
        4) volblocksize="64k" ;;
        5) volblocksize="128k" ;;
        *) volblocksize="64k" ;;
    esac
    
    log_info "Creating ZFS zvol: ${SWAP_DISK_TOTAL_GB}GB with volblocksize=$volblocksize"
    
    # Destroy if exists
    if zfs list "$zvol_name" >/dev/null 2>&1; then
        log_warn "Destroying existing zvol: $zvol_name"
        zfs destroy "$zvol_name"
    fi
    
    # Create zvol
    zfs create -V "${SWAP_DISK_TOTAL_GB}G" \
        -o compression=lz4 \
        -o sync=always \
        -o primarycache=metadata \
        -o secondarycache=none \
        -o volblocksize="$volblocksize" \
        "$zvol_name"
    
    # Wait for device
    sleep 2
    
    # Format and activate
    mkswap "$zvol_path"
    swapon -p "$SWAP_PRIORITY" "$zvol_path"
    
    # Add to fstab
    echo "$zvol_path none swap sw,pri=${SWAP_PRIORITY} 0 0" >> /etc/fstab
    
    log_info "ZFS zvol swap setup complete"
}

# Detect disk layout and determine strategy
detect_disk_layout() {
    log_step "Detecting disk layout"
    
    # Find root partition
    ROOT_PARTITION=$(findmnt -n -o SOURCE /)
    ROOT_DISK=$(lsblk -no PKNAME "$ROOT_PARTITION" 2>/dev/null | head -1)
    
    if [ -z "$ROOT_DISK" ]; then
        log_error "Could not determine root disk"
        return 1
    fi
    
    log_info "Root partition: $ROOT_PARTITION"
    log_info "Root disk: /dev/$ROOT_DISK"
    
    # Get disk size using blockdev
    DISK_SIZE_SECTORS=$(blockdev --getsz "/dev/$ROOT_DISK" 2>/dev/null || echo "0")
    DISK_SIZE_GB=$((DISK_SIZE_SECTORS / 2048 / 1024))
    
    log_info "Disk size: ${DISK_SIZE_GB}GB (${DISK_SIZE_SECTORS} sectors)"
    
    # Get root partition info
    ROOT_PART_NUM=$(echo "$ROOT_PARTITION" | grep -oE '[0-9]+$')
    ROOT_START=$(sfdisk -d "/dev/$ROOT_DISK" 2>/dev/null | grep "^$ROOT_PARTITION" | sed -E 's/.*start= *([0-9]+).*/\1/')
    ROOT_SIZE=$(sfdisk -d "/dev/$ROOT_DISK" 2>/dev/null | grep "^$ROOT_PARTITION" | sed -E 's/.*size= *([0-9]+).*/\1/')
    
    log_info "Root partition: start=$ROOT_START, size=$ROOT_SIZE sectors"
    
    # Calculate free space after root partition
    FREE_SECTORS=$((DISK_SIZE_SECTORS - ROOT_START - ROOT_SIZE))
    FREE_GB=$((FREE_SECTORS / 2048 / 1024))
    
    log_info "Free space after root: ${FREE_GB}GB (${FREE_SECTORS} sectors)"
    
    # Determine disk layout type
    if [ "$FREE_GB" -ge 10 ]; then
        DISK_LAYOUT="minimal_root"
        log_info "Disk layout: MINIMAL ROOT (root partition uses partial disk, ${FREE_GB}GB free)"
    else
        DISK_LAYOUT="full_root"
        log_info "Disk layout: FULL ROOT (root partition uses entire disk, need to shrink)"
    fi
    
    return 0
}

# Helper function to update kernel partition table with multiple methods
update_kernel_partition_table() {
    local disk="$1"
    local log_file="${2:-/dev/null}"
    
    log_info "Updating kernel partition table for /dev/$disk..."
    
    # Sync first
    sync
    sleep 2
    
    # Method 1: blockdev --rereadpt (force kernel to re-read partition table)
    if command -v blockdev >/dev/null 2>&1; then
        log_info "Using blockdev --rereadpt..."
        if blockdev --rereadpt "/dev/$disk" 2>&1 | tee -a "$log_file"; then
            log_info "✓ blockdev completed successfully"
        else
            log_warn "blockdev reported errors (expected for in-use disk)"
        fi
    fi
    
    # Method 2: partprobe (most comprehensive)
    if command -v partprobe >/dev/null 2>&1; then
        log_info "Using partprobe..."
        if partprobe "/dev/$disk" 2>&1 | tee -a "$log_file"; then
            log_info "✓ partprobe completed successfully"
        else
            log_warn "partprobe reported errors (expected for in-use disk)"
        fi
    fi
    
    # Method 3: partx (alternative method)
    if command -v partx >/dev/null 2>&1; then
        log_info "Using partx..."
        if partx -u "/dev/$disk" 2>&1 | tee -a "$log_file"; then
            log_info "✓ partx completed successfully"
        else
            log_warn "partx reported errors (expected for in-use disk)"
        fi
    fi
    
    # Settle udev events
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle 2>&1 | tee -a "$log_file" || true
        log_info "Settled udev events"
    fi
    
    # Final sync and wait
    sync
    sleep 3
    
    log_info "✓ Kernel partition table update completed"
}

# Detect disk layout and determine strategy (keeping original function name for compatibility)

# Create swap partition at end of disk using sfdisk
create_swap_partition() {
    log_step "Creating swap partition at end of disk"
    
    # Detect layout first
    if ! detect_disk_layout; then
        log_error "Failed to detect disk layout"
        return 1
    fi
    
    # Calculate swap partition size - now derived internally
    SWAP_DEVICE_SIZE_GB=$((SWAP_DISK_TOTAL_GB / SWAP_STRIPE_WIDTH))
    if [ "$SWAP_DEVICE_SIZE_GB" -lt 1 ]; then
        SWAP_DEVICE_SIZE_GB=1
    fi
    
    # Convert GB to MiB for sfdisk (1GB = 1024 MiB)
    SWAP_SIZE_MIB=$((SWAP_DEVICE_SIZE_GB * 1024))
    
    log_info "Creating ${SWAP_DEVICE_SIZE_GB}GB (${SWAP_SIZE_MIB}MiB) swap partition"
    
    # Backup current partition table
    BACKUP_FILE="/tmp/ptable-backup-$(date +%s).dump"
    sfdisk --dump "/dev/$ROOT_DISK" > "$BACKUP_FILE"
    log_info "Partition table backed up to: $BACKUP_FILE"
    
    # Handle based on disk layout type
    if [ "$DISK_LAYOUT" = "minimal_root" ]; then
        # Scenario 1: Minimal root with free space
        log_info "Layout: Minimal root - managing root extension and swap"
        
        # If EXTEND_ROOT is yes, extend root partition first, then add swap at the end
        if [ "$EXTEND_ROOT" = "yes" ]; then
            log_info "EXTEND_ROOT=yes: Will extend root partition and place swap at end"
            
            # Call the extend_root_partition function which handles both root extension and swap creation
            if ! extend_root_partition; then
                log_error "Failed to extend root partition"
                return 1
            fi
            # extend_root_partition already creates the swap partition at the end
            # So we're done here for this scenario
            return 0
        else
            # EXTEND_ROOT=no: Just append swap partition to the free space
            log_info "EXTEND_ROOT=no: Appending swap to existing free space (root stays as-is)"
        fi
        
        # Check if we have enough free space
        FREE_MIB=$((FREE_SECTORS / 2048))
        if [ "$FREE_MIB" -lt "$SWAP_SIZE_MIB" ]; then
            log_error "Not enough free space: ${FREE_MIB}MiB available, ${SWAP_SIZE_MIB}MiB needed"
            return 1
        fi
        
        # Find next partition number (handles nvme, sd, vd, etc.)
        # Count existing partitions to determine the next partition number
        # Example: 3 existing partitions -> LAST_PART_NUM=3 -> SWAP_PART_NUM=4
        LAST_PART_NUM=$(sfdisk -l "/dev/$ROOT_DISK" 2>/dev/null | grep "^/dev/" | wc -l)
        if [ -z "$LAST_PART_NUM" ] || [ "$LAST_PART_NUM" -eq 0 ]; then
            # Fallback: if no partitions found, start at 1
            LAST_PART_NUM=0
        fi
        SWAP_PART_NUM=$((LAST_PART_NUM + 1))
        
        # Handle device naming (nvme uses p prefix, others don't)
        if [[ "$ROOT_DISK" =~ nvme ]]; then
            SWAP_PARTITION="/dev/${ROOT_DISK}p${SWAP_PART_NUM}"
        else
            SWAP_PARTITION="/dev/${ROOT_DISK}${SWAP_PART_NUM}"
        fi
        
        log_info "Creating partition ${SWAP_PART_NUM} as ${SWAP_PARTITION}"
        
        # Append swap partition using sfdisk
        # Format: ",<size>M,S" for specific size or ",S" for all remaining space
        # Note: Single leading comma means "start at next available location"
        if echo ",${SWAP_SIZE_MIB}M,S" | sfdisk --force --no-reread --append "/dev/$ROOT_DISK" 2>&1 | tee -a "$LOG_FILE"; then
            log_info "Partition table updated (ioctl error is expected for in-use disk)"
        else
            log_warn "sfdisk reported errors - checking partition table"
        fi
        
    else
        # Scenario 2: Full root - need to shrink root and add swap
        # Best practice: Dump partition table, modify it, write it back as a complete unit
        log_info "Layout: Full root - shrinking root partition and adding swap"
        
        # Calculate new root size (total - start - swap space - 2048 sectors buffer)
        SWAP_SIZE_SECTORS=$((SWAP_SIZE_MIB * 2048))
        NEW_ROOT_SIZE_SECTORS=$((DISK_SIZE_SECTORS - ROOT_START - SWAP_SIZE_SECTORS - 2048))
        NEW_ROOT_SIZE_MIB=$((NEW_ROOT_SIZE_SECTORS / 2048))
        
        log_info "Shrinking root partition from ${ROOT_SIZE} to ${NEW_ROOT_SIZE_SECTORS} sectors"
        log_info "New root size: ${NEW_ROOT_SIZE_MIB}MiB"
        
        # Get filesystem type to check if we can shrink
        FS_TYPE=$(findmnt -n -o FSTYPE /)
        log_info "Root filesystem: $FS_TYPE"
        
        # Check if filesystem supports online shrinking
        case "$FS_TYPE" in
            ext4|ext3|ext2)
                log_info "Filesystem supports online/offline resizing"
                ;;
            xfs)
                log_error "XFS does not support shrinking - cannot proceed"
                log_info "Recommendation: Use minimal root layout or backup/reinstall"
                return 1
                ;;
            btrfs)
                log_info "Btrfs supports online resizing"
                ;;
            *)
                log_warn "Unknown filesystem type: $FS_TYPE"
                log_warn "Proceeding with caution..."
                ;;
        esac
        
        # Dump current partition table
        log_info "Step 1: Dumping current partition table..."
        PTABLE_DUMP="/tmp/ptable-current-$(date +%s).dump"
        sfdisk --dump "/dev/$ROOT_DISK" > "$PTABLE_DUMP"
        log_info "Current partition table saved to: $PTABLE_DUMP"
        
        # Create modified partition table
        log_info "Step 2: Creating modified partition table..."
        PTABLE_NEW="/tmp/ptable-new-$(date +%s).dump"
        
        # Parse and modify the partition table
        # Keep header and non-root partitions, modify root partition, add swap partition
        {
            # Copy header lines (label, device, unit, etc.)
            grep -E "^(label|label-id|device|unit|first-lba|last-lba|sector-size):" "$PTABLE_DUMP"
            echo ""
            
            # Process partition entries
            SWAP_PART_NUM=$((ROOT_PART_NUM + 1))
            SWAP_START=$((ROOT_START + NEW_ROOT_SIZE_SECTORS))
            
            while IFS= read -r line; do
                if [[ "$line" =~ ^/dev/ ]]; then
                    # Extract partition number from line
                    PART_NUM=$(echo "$line" | grep -oE '[0-9]+' | head -1)
                    
                    if [ "$PART_NUM" = "$ROOT_PART_NUM" ]; then
                        # Modify root partition - change size
                        echo "$line" | sed -E "s/size= *[0-9]+/size=${NEW_ROOT_SIZE_SECTORS}/"
                    else
                        # Keep other partitions as-is
                        echo "$line"
                    fi
                fi
            done < "$PTABLE_DUMP"
            
            # Add swap partition
            # Format: /dev/vdaN : start=X, size=Y, type=swap-uuid
            SWAP_TYPE="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"  # Linux swap GUID
            echo "${ROOT_PARTITION%[0-9]*}${SWAP_PART_NUM} : start=${SWAP_START}, size=${SWAP_SIZE_SECTORS}, type=${SWAP_TYPE}"
            
        } > "$PTABLE_NEW"
        
        log_info "Modified partition table saved to: $PTABLE_NEW"
        log_info "Changes:"
        log_info "  - Root partition (${ROOT_PART_NUM}): shrunk to ${NEW_ROOT_SIZE_SECTORS} sectors"
        log_info "  - Swap partition (${SWAP_PART_NUM}): added at sector ${SWAP_START}, ${SWAP_SIZE_SECTORS} sectors"
        
        # Write modified partition table
        log_info "Step 3: Writing modified partition table..."
        SWAP_PARTITION="/dev/${ROOT_DISK}${SWAP_PART_NUM}"
        
        if sfdisk --force --no-reread "/dev/$ROOT_DISK" < "$PTABLE_NEW" 2>&1 | tee -a "$LOG_FILE"; then
            log_info "Modified partition table written (ioctl error is expected)"
        else
            log_error "Failed to write modified partition table"
            log_error "Backup available at: $BACKUP_FILE"
            log_info "To restore: sfdisk --force /dev/$ROOT_DISK < $BACKUP_FILE"
            return 1
        fi
    fi
    
    # Verify partition table
    if sfdisk --verify "/dev/$ROOT_DISK" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Partition table verified successfully"
    else
        log_error "Partition table verification failed"
        return 1
    fi
    
    # Sync and wait for disk writes to complete
    log_info "Syncing disk writes..."
    sync
    sleep 2
    
    # Inform kernel of partition table changes
    update_kernel_partition_table "$ROOT_DISK" "$LOG_FILE"
    
    # Additional wait for device node creation
    sleep 2
    
    # If we shrunk root partition, resize the filesystem now
    if [ "$DISK_LAYOUT" = "full_root" ]; then
        log_info "Step 3: Resizing root filesystem to match new partition size..."
        
        case "$FS_TYPE" in
            ext4|ext3|ext2)
                # For ext filesystems, need to check first, then resize
                log_info "Checking ext filesystem integrity..."
                # Online check (read-only, -n flag prevents modifications, -v for verbose)
                e2fsck -n -v "$ROOT_PARTITION" 2>&1 | tee -a "$LOG_FILE" || true
                
                log_info "Resizing ext filesystem to match partition..."
                if resize2fs "$ROOT_PARTITION" 2>&1 | tee -a "$LOG_FILE"; then
                    log_success "Ext filesystem resized successfully"
                else
                    log_error "Failed to resize ext filesystem"
                    log_warn "Partition table changed but filesystem not shrunk!"
                    log_warn "System may be in inconsistent state - restore from backup: $BACKUP_FILE"
                    return 1
                fi
                ;;
            btrfs)
                log_info "Resizing btrfs filesystem..."
                # Calculate target size in bytes
                TARGET_SIZE=$((NEW_ROOT_SIZE_SECTORS * 512))
                if btrfs filesystem resize "${TARGET_SIZE}" / 2>&1 | tee -a "$LOG_FILE"; then
                    log_success "Btrfs filesystem resized successfully"
                else
                    log_error "Failed to resize btrfs filesystem"
                    return 1
                fi
                ;;
            *)
                log_error "Cannot resize filesystem type: $FS_TYPE"
                log_warn "Partition table updated but filesystem not resized!"
                log_warn "Manual intervention required"
                return 1
                ;;
        esac
    fi
    
    # Wait for swap device to appear
    log_info "Waiting for ${SWAP_PARTITION} to appear..."
    count=0
    while [ ! -b "$SWAP_PARTITION" ] && [ "$count" -lt 10 ]; do
        sleep 1
        count=$((count + 1))
    done
    
    if [ ! -b "$SWAP_PARTITION" ]; then
        log_error "Swap partition ${SWAP_PARTITION} did not appear"
        return 1
    fi
    
    # Format and activate based on backing type
    if [ "$SWAP_BACKING" = "ext4" ]; then
        # Ext4-backed swap: format as ext4, mount, create swap files
        log_info "Using ext4-backed swap (filesystem with swap files)"
        
        # Format as ext4
        log_info "Formatting ${SWAP_PARTITION} as ext4..."
        if mkfs.ext4 -L "swap-backing" "$SWAP_PARTITION" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Ext4 filesystem created successfully"
        else
            log_error "Failed to create ext4 filesystem"
            return 1
        fi
        
        # Create mount point
        SWAP_MOUNT="/mnt/swap-backing"
        mkdir -p "$SWAP_MOUNT"
        
        # Mount the partition
        log_info "Mounting ${SWAP_PARTITION} at ${SWAP_MOUNT}..."
        if mount "$SWAP_PARTITION" "$SWAP_MOUNT" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Partition mounted successfully"
        else
            log_error "Failed to mount partition"
            return 1
        fi
        
        # Add to fstab for persistent mount
        SWAP_PARTUUID=$(blkid "$SWAP_PARTITION" | sed -E 's/.*(PARTUUID="[^"]+").*/\1/' | tr -d '"')
        if [ -n "$SWAP_PARTUUID" ] && ! grep -q "$SWAP_PARTUUID" /etc/fstab 2>/dev/null; then
            echo "PARTUUID=$SWAP_PARTUUID ${SWAP_MOUNT} ext4 defaults 0 2" >> /etc/fstab
            log_success "Added mount to /etc/fstab"
        fi
        
        # Create swap files on the ext4 partition
        log_info "Creating ${SWAP_STRIPE_WIDTH} swap files on ext4 partition..."
        local file_size_gb=$((SWAP_DEVICE_SIZE_GB / SWAP_STRIPE_WIDTH))
        if [ "$file_size_gb" -lt 1 ]; then
            file_size_gb=1
        fi
        
        for i in $(seq 1 "$SWAP_STRIPE_WIDTH"); do
            local swapfile="${SWAP_MOUNT}/swapfile${i}"
            
            log_info "Creating ${swapfile} (${file_size_gb}GB)..."
            
            # Use fallocate for speed
            if fallocate -l "${file_size_gb}G" "$swapfile" 2>/dev/null; then
                log_debug "Used fallocate for $swapfile"
            else
                # Fallback to dd if fallocate not supported
                log_debug "Using dd for $swapfile (slower)..."
                dd if=/dev/zero of="$swapfile" bs=1M count=$((file_size_gb * 1024)) status=progress 2>&1 | tee -a "$LOG_FILE"
            fi
            
            # Set permissions
            chmod 600 "$swapfile"
            
            # Format as swap
            mkswap "$swapfile" 2>&1 | tee -a "$LOG_FILE"
            
            # Activate with same priority (enables round-robin I/O striping)
            swapon -p "$SWAP_PRIORITY" "$swapfile" 2>&1 | tee -a "$LOG_FILE"
            
            # Add to fstab
            if ! grep -q "$swapfile" /etc/fstab 2>/dev/null; then
                echo "$swapfile none swap sw,pri=${SWAP_PRIORITY} 0 0" >> /etc/fstab
            fi
            
            log_success "Swap file ${i}/${SWAP_STRIPE_WIDTH} created and activated"
        done
        
        log_success "Ext4-backed swap setup complete: ${SWAP_STRIPE_WIDTH} files on ${SWAP_PARTITION}"
        log_info "Note: All swap files have equal priority (${SWAP_PRIORITY}) for I/O striping"
        
    else
        # Direct swap: format partition as native swap
        log_info "Using direct swap (native swap partition)"
        
        # Format as swap
        # Note: Each mkswap call generates a new UUID for the swap device
        log_info "Formatting ${SWAP_PARTITION} as swap..."
        if mkswap --verbose "$SWAP_PARTITION" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Swap partition formatted successfully"
        else
            log_error "Failed to format swap partition"
            return 1
        fi
        
        # Get PARTUUID for fstab (more stable than UUID which changes on each mkswap)
        # PARTUUID is the partition UUID, UUID is the filesystem/swap UUID
        SWAP_PARTUUID=$(blkid "$SWAP_PARTITION" | sed -E 's/.*(PARTUUID="[^"]+").*/\1/' | tr -d '"')
        
        if [ -z "$SWAP_PARTUUID" ]; then
            log_warn "Could not get PARTUUID, using device path"
            SWAP_PARTUUID="$SWAP_PARTITION"
        else
            log_info "Swap PARTUUID: $SWAP_PARTUUID"
        fi
        
        # Activate swap
        log_info "Activating swap partition..."
        if swapon --verbose -p "$SWAP_PRIORITY" "$SWAP_PARTITION" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Swap partition activated"
        else
            log_error "Failed to activate swap partition"
            return 1
        fi
        
        # Add to fstab using PARTUUID (more stable than UUID which changes on mkswap)
        log_info "Adding swap to /etc/fstab..."
        if echo "$SWAP_PARTUUID" | grep -q "^/dev/"; then
            # Using device path as fallback
            if ! grep -q "$SWAP_PARTITION" /etc/fstab 2>/dev/null; then
                echo "$SWAP_PARTITION none swap sw,pri=${SWAP_PRIORITY} 0 0" >> /etc/fstab
                log_success "Added to /etc/fstab using device path"
            else
                log_info "Already in /etc/fstab"
            fi
        else
            # Using PARTUUID
            if ! grep -q "$SWAP_PARTUUID" /etc/fstab 2>/dev/null; then
                echo "PARTUUID=$SWAP_PARTUUID none swap sw,pri=${SWAP_PRIORITY} 0 0" >> /etc/fstab
                log_success "Added to /etc/fstab using PARTUUID"
            else
                log_info "Already in /etc/fstab"
            fi
        fi
        
        log_success "Direct swap partition setup complete: ${SWAP_PARTITION} (${SWAP_DEVICE_SIZE_GB}GB)"
    fi
    
    return 0
}

# Extend root partition using dump-modify-write method
extend_root_partition() {
    log_step "Extending root partition using dump-modify-write method"
    
    # Detect layout first
    if ! detect_disk_layout; then
        log_error "Failed to detect disk layout"
        return 1
    fi
    
    # Check filesystem type
    FS_TYPE=$(findmnt -n -o FSTYPE /)
    
    log_info "Root filesystem: $FS_TYPE"
    log_info "Root partition: $ROOT_PARTITION"
    log_info "Current root size: $((ROOT_SIZE / 2048))MiB"
    log_info "Unallocated space: $((FREE_SECTORS / 2048))MiB"
    
    # Calculate swap space requirements
    # Total swap space divided by number of devices
    SWAP_DEVICE_SIZE_GB=$((SWAP_DISK_TOTAL_GB / SWAP_STRIPE_WIDTH))
    if [ "$SWAP_DEVICE_SIZE_GB" -lt 1 ]; then
        SWAP_DEVICE_SIZE_GB=1
    fi
    SWAP_SIZE_MIB=$((SWAP_DEVICE_SIZE_GB * 1024))
    SWAP_SIZE_SECTORS=$((SWAP_SIZE_MIB * 2048))
    
    # Calculate total space needed for all swap partitions
    TOTAL_SWAP_SECTORS=$((SWAP_SIZE_SECTORS * SWAP_STRIPE_WIDTH))
    TOTAL_SWAP_MIB=$((SWAP_SIZE_MIB * SWAP_STRIPE_WIDTH))
    
    log_info "Creating ${SWAP_STRIPE_WIDTH} swap partitions of ${SWAP_DEVICE_SIZE_GB}GB each"
    log_info "Total swap space: ${TOTAL_SWAP_MIB}MiB (${SWAP_DISK_TOTAL_GB}GB)"
    
    # Calculate new root size (use most of disk, leaving space for swap at end)
    # Add 2048 sectors buffer for alignment
    NEW_ROOT_SIZE_SECTORS=$((DISK_SIZE_SECTORS - ROOT_START - TOTAL_SWAP_SECTORS - 2048))
    NEW_ROOT_SIZE_MIB=$((NEW_ROOT_SIZE_SECTORS / 2048))
    
    log_info "New root partition size: ${NEW_ROOT_SIZE_MIB}MiB"
    
    if [ "$NEW_ROOT_SIZE_SECTORS" -le "$ROOT_SIZE" ]; then
        log_error "Not enough space to create swap partitions"
        log_error "Current root: $((ROOT_SIZE / 2048))MiB, would be: ${NEW_ROOT_SIZE_MIB}MiB"
        return 1
    fi
    
    # Step 1: Dump current partition table
    log_info "Step 1: Dumping current partition table..."
    PTABLE_DUMP="/tmp/ptable-current-$(date +%s).dump"
    if ! sfdisk --dump "/dev/$ROOT_DISK" > "$PTABLE_DUMP" 2>&1; then
        log_error "Failed to dump partition table"
        return 1
    fi
    log_info "Partition table dumped to: $PTABLE_DUMP"
    
    # Step 2: Create modified partition table
    log_info "Step 2: Creating modified partition table..."
    PTABLE_NEW="/tmp/ptable-new-$(date +%s).dump"
    
    # Linux swap GUID type for GPT
    SWAP_TYPE_GUID="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"
    
    # Parse and modify the partition table
    {
        # Copy header lines (label, device, unit, etc.)
        grep -E "^(label|label-id|device|unit|first-lba|last-lba|sector-size):" "$PTABLE_DUMP"
        echo ""
        
        # Process existing partition entries
        while IFS= read -r line; do
            if [[ "$line" =~ ^/dev/ ]]; then
                # Extract partition number from line
                PART_NUM=$(echo "$line" | grep -oE '[0-9]+' | head -1)
                
                if [ "$PART_NUM" = "$ROOT_PART_NUM" ]; then
                    # Modify root partition - extend its size
                    echo "$line" | sed -E "s/size= *[0-9]+/size=${NEW_ROOT_SIZE_SECTORS}/"
                else
                    # Keep other partitions as-is
                    echo "$line"
                fi
            fi
        done < "$PTABLE_DUMP"
        
        # Add new swap partitions at the end
        SWAP_START=$((ROOT_START + NEW_ROOT_SIZE_SECTORS))
        
        for i in $(seq 1 "$SWAP_STRIPE_WIDTH"); do
            SWAP_PART_NUM=$((ROOT_PART_NUM + i))
            
            # Handle device naming (nvme uses p prefix, others don't)
            if [[ "$ROOT_DISK" =~ nvme ]]; then
                PART_NAME="/dev/${ROOT_DISK}p${SWAP_PART_NUM}"
            else
                PART_NAME="/dev/${ROOT_DISK}${SWAP_PART_NUM}"
            fi
            
            # Add swap partition with proper type GUID
            # Format: /dev/vdaN : start=X, size=Y, type=GUID
            echo "${PART_NAME} : start=${SWAP_START}, size=${SWAP_SIZE_SECTORS}, type=${SWAP_TYPE_GUID}"
            
            # Update start for next partition (maintain 2048-sector alignment)
            SWAP_START=$((SWAP_START + SWAP_SIZE_SECTORS))
            # Align to 2048 sectors
            SWAP_START=$(( (SWAP_START + 2047) / 2048 * 2048 ))
        done
        
    } > "$PTABLE_NEW"
    
    log_info "Modified partition table created at: $PTABLE_NEW"
    log_info "Changes:"
    log_info "  - Root partition (${ROOT_PART_NUM}): extended to ${NEW_ROOT_SIZE_SECTORS} sectors"
    log_info "  - Added ${SWAP_STRIPE_WIDTH} swap partitions of ${SWAP_SIZE_SECTORS} sectors each"
    
    # Step 3: Write modified partition table
    log_info "Step 3: Writing modified partition table..."
    if sfdisk --force "/dev/$ROOT_DISK" < "$PTABLE_NEW" 2>&1 | tee -a "$LOG_FILE"; then
        log_info "Modified partition table written (Device or resource busy is NORMAL)"
    else
        log_error "Failed to write modified partition table"
        log_error "Backup available at: $PTABLE_DUMP"
        log_info "To restore: sfdisk --force /dev/$ROOT_DISK < $PTABLE_DUMP"
        return 1
    fi
    
    # Verify partition table
    if sfdisk --verify "/dev/$ROOT_DISK" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Partition table verified successfully"
    else
        log_error "Partition table verification failed"
        return 1
    fi
    
    # Sync and wait
    sync
    sleep 2
    
    # Step 4: Update kernel partition table using partx
    log_info "Step 4: Updating kernel partition table with partx -u..."
    if partx -u "/dev/$ROOT_DISK" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Kernel partition table updated"
    else
        log_warn "partx reported errors (may be normal for in-use disk)"
    fi
    
    # Additional wait for device nodes
    sleep 2
    
    # Verify the partition is visible to the kernel
    log_info "Verifying partition table update..."
    if lsblk "/dev/$ROOT_DISK" | grep -q "$ROOT_PARTITION"; then
        log_info "✓ Root partition visible in kernel"
    else
        log_warn "⚠ Root partition not immediately visible - may require reboot"
    fi
    
    # Step 5: Resize filesystem online
    log_info "Step 5: Resizing ${FS_TYPE} filesystem online..."
    
    case "$FS_TYPE" in
        ext4|ext3|ext2)
            # Check filesystem first (read-only check on mounted partition)
            log_info "Checking filesystem integrity (read-only)..."
            e2fsck -n -v "$ROOT_PARTITION" 2>&1 | tee -a "$LOG_FILE" || true
            
            # Resize filesystem without size argument = expand to fill partition
            log_info "Expanding filesystem to fill partition..."
            if resize2fs "$ROOT_PARTITION" 2>&1 | tee -a "$LOG_FILE"; then
                log_success "ext4 filesystem resized successfully"
            else
                log_error "Failed to resize ext4 filesystem"
                return 1
            fi
            ;;
        xfs)
            if xfs_growfs / 2>&1 | tee -a "$LOG_FILE"; then
                log_success "XFS filesystem resized successfully"
            else
                log_error "Failed to resize XFS filesystem"
                return 1
            fi
            ;;
        btrfs)
            if btrfs filesystem resize max / 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Btrfs filesystem resized successfully"
            else
                log_error "Failed to resize Btrfs filesystem"
                return 1
            fi
            ;;
        *)
            log_error "Unsupported filesystem type: $FS_TYPE"
            log_info "Manual resize required"
            return 1
            ;;
    esac
    
    log_success "Root partition extended successfully"
    
    # Step 6: Format and enable swap partitions
    log_info "Step 6: Formatting and enabling ${SWAP_STRIPE_WIDTH} swap partitions..."
    
    for i in $(seq 1 "$SWAP_STRIPE_WIDTH"); do
        SWAP_PART_NUM=$((ROOT_PART_NUM + i))
        
        # Handle device naming (nvme uses p prefix, others don't)
        if [[ "$ROOT_DISK" =~ nvme ]]; then
            SWAP_PARTITION="/dev/${ROOT_DISK}p${SWAP_PART_NUM}"
        else
            SWAP_PARTITION="/dev/${ROOT_DISK}${SWAP_PART_NUM}"
        fi
        
        log_info "Processing swap partition ${i}/${SWAP_STRIPE_WIDTH}: ${SWAP_PARTITION}"
        
        # Wait for device node to appear
        for retry in {1..5}; do
            if [ -b "$SWAP_PARTITION" ]; then
                break
            fi
            log_debug "Waiting for ${SWAP_PARTITION} to appear (attempt ${retry}/5)..."
            sleep 1
        done
        
        if [ ! -b "$SWAP_PARTITION" ]; then
            log_error "Swap partition ${SWAP_PARTITION} not found"
            continue
        fi
        
        # Format as swap
        log_info "Formatting ${SWAP_PARTITION} as swap..."
        if mkswap "$SWAP_PARTITION" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Swap partition ${i} formatted"
        else
            log_error "Failed to format swap partition ${i}"
            continue
        fi
        
        # Enable swap
        log_info "Enabling swap partition ${i}..."
        if swapon -p "$SWAP_PRIORITY" "$SWAP_PARTITION" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Swap partition ${i} enabled"
        else
            log_error "Failed to enable swap partition ${i}"
            continue
        fi
        
        # Add to fstab with PARTUUID for stability
        PARTUUID=$(blkid -s PARTUUID -o value "$SWAP_PARTITION" 2>/dev/null)
        if [ -n "$PARTUUID" ]; then
            if ! grep -q "$PARTUUID" /etc/fstab 2>/dev/null; then
                echo "PARTUUID=${PARTUUID} none swap sw,pri=${SWAP_PRIORITY} 0 0" >> /etc/fstab
                log_info "Added swap ${i} to /etc/fstab using PARTUUID"
            fi
        else
            if ! grep -q "$SWAP_PARTITION" /etc/fstab 2>/dev/null; then
                echo "${SWAP_PARTITION} none swap sw,pri=${SWAP_PRIORITY} 0 0" >> /etc/fstab
                log_info "Added swap ${i} to /etc/fstab using device path"
            fi
        fi
        
        log_success "Swap partition ${i}/${SWAP_STRIPE_WIDTH} complete: ${SWAP_PARTITION}"
    done
    
    log_success "Root partition extended and ${SWAP_STRIPE_WIDTH} swap partitions created successfully"
    log_info "All swap partitions have equal priority (${SWAP_PRIORITY}) for I/O striping"
    
    return 0
}

# Setup ZRAM with partition overflow
setup_zram_with_partition() {
    log_step "Setting up ZRAM with uncompressed swap partition overflow"
    
    # First setup ZRAM with higher priority
    setup_zram
    
    # Then setup partition-based swap with lower priority
    if [[ "$SWAP_BACKING_TYPE" == "partitions_swap" || "$SWAP_BACKING_TYPE" == "partitions_zvol" || "$SWAP_BACKING_TYPE" == "files_in_partitions" ]]; then
        log_info "Setting up partition-based swap overflow"
        create_swap_partition
    else
        log_warn "SWAP_BACKING_TYPE not set to partition mode - skipping partition setup"
        log_info "Current SWAP_BACKING_TYPE: $SWAP_BACKING_TYPE"
    fi
}

# Configure kernel parameters
configure_kernel_params() {
    log_step "Configuring kernel parameters"
    
    # Calculate optimal swappiness
    local swappiness=60
    if [ "$RAM_GB" -le 2 ]; then
        swappiness=80  # More aggressive for low RAM
    elif [ "$RAM_GB" -ge 16 ]; then
        swappiness=10  # Less aggressive for high RAM
    fi
    
    # Calculate page-cluster based on storage type or use benchmark result
    local page_cluster=3
    
    # Check if benchmark provided an optimal page-cluster value
    if [ -n "$SWAP_PAGE_CLUSTER" ]; then
        page_cluster=$SWAP_PAGE_CLUSTER
        log_info "Using benchmark-optimized page-cluster: $page_cluster"
    else
        # Default based on storage type
        if [ "$STORAGE_TYPE" = "hdd" ]; then
            page_cluster=4  # 64KB for HDD
        elif [ "$STORAGE_TYPE" = "ssd" ]; then
            page_cluster=3  # 32KB for SSD
        fi
    fi
    
    log_info "Writing kernel parameters to $SYSCTL_CONF"
    
    cat > "$SYSCTL_CONF" <<EOF
# Swap Configuration
# Generated by setup-swap.sh on $(date)
# RAM Solution: $SWAP_RAM_SOLUTION, Backing Type: $SWAP_BACKING_TYPE

# Swappiness: tendency to swap (0-100)
# Lower = prefer RAM, Higher = more aggressive swapping
vm.swappiness = $swappiness

# Page cluster: number of pages to read/write at once (2^n)
# 0=4KB, 1=8KB, 2=16KB, 3=32KB, 4=64KB, 5=128KB
vm.page-cluster = $page_cluster

# Cache pressure: tendency to reclaim cache (100=balanced)
vm.vfs_cache_pressure = 100

# Watermark scale factor: memory reclaim aggressiveness
vm.watermark_scale_factor = 10

# Minimum free memory
vm.min_free_kbytes = 65536
EOF
    
    # Apply settings
    sysctl -p "$SYSCTL_CONF"
    
    log_info "Kernel parameters configured"
}

# Print final configuration
print_final_config() {
    log_step "Final Swap Configuration (AFTER changes)"
    echo ""
    echo "=== Configuration ===" 
    echo "RAM Solution: $SWAP_RAM_SOLUTION"
    echo "Backing Type: $SWAP_BACKING_TYPE"
    
    echo ""
    echo "=== Kernel Parameters ==="
    sysctl vm.swappiness
    sysctl vm.page-cluster
    sysctl vm.vfs_cache_pressure
    
    echo ""
    echo "=== Active Swap Devices ==="
    swapon --show
    
    echo ""
    echo "=== Memory Status ==="
    free -h
    
    if [ "$SWAP_RAM_SOLUTION" = "zram" ]; then
        echo ""
        echo "=== ZRAM Statistics ==="
        if [ -f /sys/block/zram0/mm_stat ]; then
            cat /sys/block/zram0/mm_stat
        fi
    fi
    
    if [ "$SWAP_RAM_SOLUTION" = "zswap" ]; then
        echo ""
        echo "=== ZSWAP Configuration ==="
        if [ -d /sys/module/zswap ]; then
            echo "enabled: $(cat /sys/module/zswap/parameters/enabled)"
            echo "max_pool_percent: $(cat /sys/module/zswap/parameters/max_pool_percent)"
            echo "compressor: $(cat /sys/module/zswap/parameters/compressor)"
        fi
    fi
    
    echo ""
}

# Setup swap based on detected/configured options
setup_swap_solution() {
    log_step "Setting up swap solution"
    log_info "RAM Solution: $SWAP_RAM_SOLUTION, Backing: $SWAP_BACKING_TYPE"
    
    # Setup RAM-based swap if configured
    case "$SWAP_RAM_SOLUTION" in
        zram)
            log_info "Setting up ZRAM"
            setup_zram
            ;;
        zswap)
            log_info "Setting up ZSWAP"
            setup_zswap
            ;;
        none)
            log_info "No RAM-based swap configured"
            ;;
        *)
            log_error "Invalid SWAP_RAM_SOLUTION: $SWAP_RAM_SOLUTION"
            return 1
            ;;
    esac
    
    # Setup disk-based swap if configured
    case "$SWAP_BACKING_TYPE" in
        files_in_root)
            log_info "Setting up swap files in root filesystem"
            create_swap_files
            ;;
        partitions_swap)
            log_info "Setting up native swap partitions"
            create_swap_partition
            ;;
        partitions_zvol)
            log_info "Setting up ZFS zvol swap"
            setup_zfs_zvol
            ;;
        files_in_partitions)
            log_info "Setting up swap files on dedicated partition"
            create_swap_files_on_partition
            ;;
        none)
            log_info "No disk-based swap configured"
            ;;
        *)
            log_error "Invalid SWAP_BACKING_TYPE: $SWAP_BACKING_TYPE"
            return 1
            ;;
    esac
}

# Main function
main() {
    print_banner
    check_root
    
    log_info "Initial Configuration:"
    log_info "  RAM Solution: ${SWAP_RAM_SOLUTION:-auto-detect}"
    log_info "  RAM Total: ${SWAP_RAM_TOTAL_GB}GB"
    log_info "  Disk Total: ${SWAP_DISK_TOTAL_GB}GB"
    log_info "  Backing Type: ${SWAP_BACKING_TYPE:-auto-detect}"
    log_info "  Stripe Width: $SWAP_STRIPE_WIDTH"
    log_info "  Extend Root: $EXTEND_ROOT"
    echo ""
    
    # Print current state
    print_current_config
    
    # Detection and calculation
    detect_system
    
    # Auto-detect optimal configuration if not explicitly set
    auto_detect_swap_configuration
    
    # Calculate sizes based on detected system
    calculate_swap_sizes
    
    # NEW: Show analysis and plan
    print_system_analysis_and_plan
    
    # Install dependencies
    install_dependencies
    
    # Disable existing swap
    disable_existing_swap
    
    # Setup swap solution
    setup_swap_solution
    
    # Configure kernel
    configure_kernel_params
    
    # Print results
    print_final_config
    
    log_info "✓ Swap configuration completed successfully!"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Monitor swap: ./swap-monitor.sh"
    log_info "  2. Check performance: ./benchmark.py"
    log_info "  3. Analyze memory: ./analyze-memory.sh"
}

# Run main function
main "$@"
