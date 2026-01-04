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

# Configuration variables with defaults
SWAP_ARCH="${SWAP_ARCH:-3}"  # 1-7, default: ZSWAP + Swap Files
SWAP_TOTAL_GB="${SWAP_TOTAL_GB:-auto}"
SWAP_FILES="${SWAP_FILES:-8}"  # Default 8 for concurrency
SWAP_PRIORITY="${SWAP_PRIORITY:-10}"
ZRAM_SIZE_GB="${ZRAM_SIZE_GB:-auto}"
ZRAM_PRIORITY="${ZRAM_PRIORITY:-100}"
ZSWAP_POOL_PERCENT="${ZSWAP_POOL_PERCENT:-20}"
ZSWAP_COMPRESSOR="${ZSWAP_COMPRESSOR:-lz4}"
ZRAM_COMPRESSOR="${ZRAM_COMPRESSOR:-lz4}"
ZRAM_ALLOCATOR="${ZRAM_ALLOCATOR:-zsmalloc}"
ZFS_POOL="${ZFS_POOL:-tank}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
USE_PARTITION="${USE_PARTITION:-no}"  # yes/no - use partition instead of files
SWAP_PARTITION_SIZE_GB="${SWAP_PARTITION_SIZE_GB:-auto}"  # Size for partition-based swap
SWAP_BACKING="${SWAP_BACKING:-direct}"  # direct (native swap) or ext4 (filesystem-backed)
EXTEND_ROOT="${EXTEND_ROOT:-yes}"  # yes/no - extend root partition after creating swap

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
║   Supporting 7 swap architectures                     ║
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
    
    # Disk space in GB
    DISK_AVAIL_KB=$(df -k / | tail -1 | awk '{print $4}')
    DISK_GB=$((DISK_AVAIL_KB / 1024 / 1024))
    log_info "Available disk space: ${DISK_GB}GB"
    
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

# Calculate dynamic swap sizes
calculate_swap_sizes() {
    log_step "Calculating optimal swap sizes"
    
    # Calculate SWAP_TOTAL_GB if auto
    if [ "$SWAP_TOTAL_GB" = "auto" ]; then
        if [ "$RAM_GB" -le 2 ]; then
            SWAP_TOTAL_GB=$((RAM_GB * 2))
            log_info "Low RAM system: Using 2x RAM = ${SWAP_TOTAL_GB}GB swap"
        elif [ "$RAM_GB" -le 4 ]; then
            SWAP_TOTAL_GB=$((RAM_GB * 3 / 2))
            log_info "Using 1.5x RAM = ${SWAP_TOTAL_GB}GB swap"
        elif [ "$RAM_GB" -le 8 ]; then
            SWAP_TOTAL_GB=$RAM_GB
            log_info "Using 1x RAM = ${SWAP_TOTAL_GB}GB swap"
        elif [ "$RAM_GB" -le 16 ]; then
            SWAP_TOTAL_GB=$((RAM_GB / 2))
            log_info "Using 0.5x RAM = ${SWAP_TOTAL_GB}GB swap"
        else
            SWAP_TOTAL_GB=$((RAM_GB / 4))
            [ "$SWAP_TOTAL_GB" -lt 4 ] && SWAP_TOTAL_GB=4
            [ "$SWAP_TOTAL_GB" -gt 16 ] && SWAP_TOTAL_GB=16
            log_info "Using ${SWAP_TOTAL_GB}GB swap (capped)"
        fi
    fi
    
    # Check disk constraints
    if [ "$DISK_GB" -lt 30 ]; then
        log_warn "Low disk space (<30GB). Recommend ZRAM only (arch 1)"
        if [ "$SWAP_ARCH" -ne 1 ] && [ "$SWAP_TOTAL_GB" -gt 4 ]; then
            SWAP_TOTAL_GB=4
            log_warn "Reducing swap to ${SWAP_TOTAL_GB}GB due to disk constraints"
        fi
    fi
    
    # Calculate ZRAM size if auto
    if [ "$ZRAM_SIZE_GB" = "auto" ]; then
        ZRAM_SIZE_GB=$((RAM_GB / 2))
        [ "$ZRAM_SIZE_GB" -lt 1 ] && ZRAM_SIZE_GB=1
        [ "$ZRAM_SIZE_GB" -gt 16 ] && ZRAM_SIZE_GB=16
        log_info "ZRAM size: ${ZRAM_SIZE_GB}GB (50% of RAM)"
    fi
    
    # Calculate per-file size
    SWAP_FILE_SIZE_GB=$((SWAP_TOTAL_GB / SWAP_FILES))
    if [ "$SWAP_FILE_SIZE_GB" -lt 1 ]; then
        SWAP_FILE_SIZE_GB=1
        SWAP_FILES=$SWAP_TOTAL_GB
        log_warn "Adjusted: $SWAP_FILES files of ${SWAP_FILE_SIZE_GB}GB each"
    else
        log_info "Swap files: $SWAP_FILES files of ${SWAP_FILE_SIZE_GB}GB each = ${SWAP_TOTAL_GB}GB total"
    fi
    
    # Recommendations for low RAM
    if [ "$RAM_GB" -le 2 ]; then
        log_warn "Low RAM detected. Recommend: ZSWAP_COMPRESSOR=zstd ZRAM_ALLOCATOR=zsmalloc"
        if [ "$ZSWAP_COMPRESSOR" = "lz4" ]; then
            log_warn "Current compressor is lz4. Consider zstd for better compression ratio."
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
    echo "  Disk Space:    ${DISK_GB}GB available"
    echo "  CPU Cores:     ${CPU_CORES}"
    echo "  Storage Type:  ${STORAGE_TYPE}"
    if [ "$USE_PARTITION" = "yes" ]; then
        echo "  Root Disk:     /dev/${ROOT_DISK}"
        echo "  Root Partition: ${ROOT_PARTITION}"
    fi
    echo ""
    
    echo "Current Swap Status:"
    if swapon --show | grep -q "/"; then
        swapon --show
    else
        echo "  No active swap"
    fi
    echo ""
    
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║           DERIVED CONFIGURATION                       ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    echo "Selected Architecture: $SWAP_ARCH"
    case $SWAP_ARCH in
        1) echo "  Type: ZRAM Only (no disk-based swap)" ;;
        2) echo "  Type: ZRAM + Disk Swap (two-tier)" ;;
        3) echo "  Type: ZSWAP + Disk Swap (recommended)" ;;
        4) echo "  Type: Disk Swap Only" ;;
        5) echo "  Type: ZFS zvol Compressed Swap" ;;
        6) echo "  Type: ZRAM + ZFS zvol" ;;
        7) echo "  Type: ZRAM + Uncompressed Partition" ;;
    esac
    echo ""
    
    if [ "$SWAP_ARCH" -eq 1 ] || [ "$SWAP_ARCH" -eq 2 ] || [ "$SWAP_ARCH" -eq 6 ] || [ "$SWAP_ARCH" -eq 7 ]; then
        echo "ZRAM Configuration:"
        echo "  Size:          ${ZRAM_SIZE_GB}GB"
        echo "  Compressor:    ${ZRAM_COMPRESSOR}"
        echo "  Priority:      ${ZRAM_PRIORITY}"
        echo ""
    fi
    
    if [ "$SWAP_ARCH" -eq 3 ]; then
        echo "ZSWAP Configuration:"
        echo "  Pool Size:     ${ZSWAP_POOL_PERCENT}% of RAM"
        echo "  Compressor:    ${ZSWAP_COMPRESSOR}"
        echo ""
    fi
    
    if [ "$SWAP_ARCH" -ne 1 ]; then
        echo "Disk-based Swap Configuration:"
        echo "  Total Size:    ${SWAP_TOTAL_GB}GB"
        
        if [ "$USE_PARTITION" = "yes" ]; then
            echo "  Backing:       Partition-based"
            if [ "$SWAP_PARTITION_SIZE_GB" = "auto" ]; then
                echo "  Partition Size: ${SWAP_TOTAL_GB}GB (auto)"
            else
                echo "  Partition Size: ${SWAP_PARTITION_SIZE_GB}GB"
            fi
            echo "  Type:          ${SWAP_BACKING}"
            if [ "$SWAP_BACKING" = "ext4" ]; then
                echo "  Files:         ${SWAP_FILES} files on ext4 partition"
            fi
        else
            echo "  Backing:       File-based"
            echo "  Files:         ${SWAP_FILES} × ${SWAP_FILE_SIZE_GB}GB"
            echo "  Location:      ${SWAP_DIR}/"
        fi
        echo "  Priority:      ${SWAP_PRIORITY}"
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
    
    if [ "$SWAP_ARCH" -eq 1 ] || [ "$SWAP_ARCH" -eq 2 ] || [ "$SWAP_ARCH" -eq 6 ] || [ "$SWAP_ARCH" -eq 7 ]; then
        echo "  2. Create ZRAM device (${ZRAM_SIZE_GB}GB compressed)"
    fi
    
    if [ "$SWAP_ARCH" -eq 3 ]; then
        echo "  2. Enable ZSWAP (${ZSWAP_POOL_PERCENT}% pool, ${ZSWAP_COMPRESSOR} compression)"
    fi
    
    if [ "$USE_PARTITION" = "yes" ] && [ "$SWAP_ARCH" -ne 1 ]; then
        echo "  3. Create swap partition at end of disk"
        if [ "$EXTEND_ROOT" = "yes" ]; then
            echo "     - Extend root partition to use remaining space"
            local swap_size="${SWAP_PARTITION_SIZE_GB}"
            [ "$swap_size" = "auto" ] && swap_size="${SWAP_TOTAL_GB}"
            echo "     - Reserve ${swap_size}GB at end for swap"
        fi
        if [ "$SWAP_BACKING" = "ext4" ]; then
            echo "     - Format partition as ext4"
            echo "     - Create ${SWAP_FILES} swap files on partition"
        else
            echo "     - Format partition as native swap"
        fi
    elif [ "$SWAP_ARCH" -ne 1 ]; then
        echo "  3. Create ${SWAP_FILES} swap files in ${SWAP_DIR}/"
    fi
    
    echo "  4. Configure kernel parameters in ${SYSCTL_CONF}"
    echo "  5. Add swap to /etc/fstab for persistence"
    echo ""
    
    if [ "$DISK_GB" -lt 30 ] && [ "$SWAP_ARCH" -ne 1 ]; then
        log_warn "⚠️  Low disk space detected (<30GB)"
        log_warn "⚠️  Consider Architecture 1 (ZRAM only) for minimal disk usage"
        echo ""
    fi
    
    if [ "$RAM_GB" -le 2 ]; then
        log_warn "⚠️  Low RAM detected (${RAM_GB}GB)"
        log_warn "⚠️  Recommended: ZSWAP_COMPRESSOR=zstd for better compression"
        echo ""
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
    if [ "$SWAP_ARCH" -eq 5 ] || [ "$SWAP_ARCH" -eq 6 ]; then
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
    
    if swapon --show | grep -q "/"; then
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
    local zram_size_bytes=$((ZRAM_SIZE_GB * 1024 * 1024 * 1024))
    log_info "Setting ZRAM size: ${ZRAM_SIZE_GB}GB"
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
    
    log_info "Creating $SWAP_FILES swap files of ${SWAP_FILE_SIZE_GB}GB each..."
    
    for i in $(seq 1 "$SWAP_FILES"); do
        local swapfile="${SWAP_DIR}/swapfile${i}"
        
        log_debug "Creating $swapfile (${SWAP_FILE_SIZE_GB}GB)..."
        
        # Use fallocate for speed (if supported) or dd
        if fallocate -l "${SWAP_FILE_SIZE_GB}G" "$swapfile" 2>/dev/null; then
            log_debug "  Created with fallocate"
        else
            log_debug "  Creating with dd (slower)..."
            dd if=/dev/zero of="$swapfile" bs=1M count=$((SWAP_FILE_SIZE_GB * 1024)) status=progress
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
    
    log_info "Creating ZFS zvol: ${SWAP_TOTAL_GB}GB with volblocksize=$volblocksize"
    
    # Destroy if exists
    if zfs list "$zvol_name" >/dev/null 2>&1; then
        log_warn "Destroying existing zvol: $zvol_name"
        zfs destroy "$zvol_name"
    fi
    
    # Create zvol
    zfs create -V "${SWAP_TOTAL_GB}G" \
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

# Create swap partition at end of disk using sfdisk
create_swap_partition() {
    log_step "Creating swap partition at end of disk"
    
    # Detect layout first
    if ! detect_disk_layout; then
        log_error "Failed to detect disk layout"
        return 1
    fi
    
    # Calculate swap partition size
    if [ "$SWAP_PARTITION_SIZE_GB" = "auto" ]; then
        SWAP_PARTITION_SIZE_GB=$SWAP_TOTAL_GB
    fi
    
    # Convert GB to MiB for sfdisk (1GB = 1024 MiB)
    SWAP_SIZE_MIB=$((SWAP_PARTITION_SIZE_GB * 1024))
    
    log_info "Creating ${SWAP_PARTITION_SIZE_GB}GB (${SWAP_SIZE_MIB}MiB) swap partition"
    
    # Backup current partition table
    BACKUP_FILE="/tmp/ptable-backup-$(date +%s).dump"
    sfdisk --dump "/dev/$ROOT_DISK" > "$BACKUP_FILE"
    log_info "Partition table backed up to: $BACKUP_FILE"
    
    # Handle based on disk layout type
    if [ "$DISK_LAYOUT" = "minimal_root" ]; then
        # Scenario 1: Minimal root with free space
        # Just append swap partition to the free space
        log_info "Layout: Minimal root - appending swap to free space"
        
        # Check if we have enough free space
        FREE_MIB=$((FREE_SECTORS / 2048))
        if [ "$FREE_MIB" -lt "$SWAP_SIZE_MIB" ]; then
            log_error "Not enough free space: ${FREE_MIB}MiB available, ${SWAP_SIZE_MIB}MiB needed"
            return 1
        fi
        
        # Find next partition number
        LAST_PART_NUM=$(lsblk -n -o NAME "/dev/$ROOT_DISK" | grep -oE '[0-9]+$' | sort -n | tail -1)
        SWAP_PART_NUM=$((LAST_PART_NUM + 1))
        SWAP_PARTITION="/dev/${ROOT_DISK}${SWAP_PART_NUM}"
        
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
    
    # Inform kernel of partition table changes with multiple methods
    log_info "Informing kernel of partition table changes..."
    
    # Try partprobe first (most comprehensive)
    if command -v partprobe >/dev/null 2>&1; then
        partprobe "/dev/$ROOT_DISK" 2>&1 | tee -a "$LOG_FILE" || true
        log_info "Used partprobe to update kernel partition table"
    fi
    
    # Try partx as well (alternative method)
    if command -v partx >/dev/null 2>&1; then
        partx -a "/dev/$ROOT_DISK" 2>&1 | tee -a "$LOG_FILE" || true
        log_info "Used partx to update kernel partition table"
    fi
    
    # Settle udev events
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle 2>&1 | tee -a "$LOG_FILE" || true
        log_info "Settled udev events"
    fi
    
    # Additional wait for device node creation
    sleep 2
    
    # If we shrunk root partition, resize the filesystem now
    if [ "$DISK_LAYOUT" = "full_root" ]; then
        log_info "Step 3: Resizing root filesystem to match new partition size..."
        
        case "$FS_TYPE" in
            ext4|ext3|ext2)
                # For ext filesystems, need to check first, then resize
                log_info "Checking ext filesystem integrity..."
                # Online check (read-only)
                e2fsck -n -f "$ROOT_PARTITION" 2>&1 | tee -a "$LOG_FILE" || true
                
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
        log_info "Creating ${SWAP_FILES} swap files on ext4 partition..."
        local SWAP_FILE_SIZE_GB=$((SWAP_PARTITION_SIZE_GB / SWAP_FILES))
        
        for i in $(seq 1 "$SWAP_FILES"); do
            local swapfile="${SWAP_MOUNT}/swapfile${i}"
            
            log_info "Creating ${swapfile} (${SWAP_FILE_SIZE_GB}GB)..."
            
            # Use fallocate for speed
            if fallocate -l "${SWAP_FILE_SIZE_GB}G" "$swapfile" 2>/dev/null; then
                log_debug "Used fallocate for $swapfile"
            else
                # Fallback to dd if fallocate not supported
                log_debug "Using dd for $swapfile (slower)..."
                dd if=/dev/zero of="$swapfile" bs=1M count=$((SWAP_FILE_SIZE_GB * 1024)) status=progress 2>&1 | tee -a "$LOG_FILE"
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
            
            log_success "Swap file ${i}/${SWAP_FILES} created and activated"
        done
        
        log_success "Ext4-backed swap setup complete: ${SWAP_FILES} files on ${SWAP_PARTITION}"
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
        
        log_success "Direct swap partition setup complete: ${SWAP_PARTITION} (${SWAP_PARTITION_SIZE_GB}GB)"
    fi
    
    return 0
}

# Extend root partition
extend_root_partition() {
    log_step "Extending root partition"
    
    # Detect layout first
    if ! detect_disk_layout; then
        log_error "Failed to detect disk layout"
        return 1
    fi
    
    # Check filesystem type
    FS_TYPE=$(findmnt -n -o FSTYPE /)
    
    log_info "Root filesystem: $FS_TYPE"
    log_info "Root partition: $ROOT_PARTITION"
    
    # Calculate new size for root partition
    # Formula: Total sectors - start of root - space for swap - 1 (for rounding)
    SWAP_SIZE_MIB=$((SWAP_PARTITION_SIZE_GB * 1024))
    SWAP_SIZE_SECTORS=$((SWAP_SIZE_MIB * 2048))
    
    # Calculate remaining space for root in MiB
    REMAINING_SECTORS=$((DISK_SIZE_SECTORS - ROOT_START - SWAP_SIZE_SECTORS - 1))
    REMAINING_MIB=$((REMAINING_SECTORS / 2048))
    
    log_info "New root partition size: ${REMAINING_MIB}MiB"
    
    if [ "$REMAINING_MIB" -le 0 ]; then
        log_error "No space available for root partition extension"
        return 1
    fi
    
    # Backup current partition table
    BACKUP_FILE="/tmp/ptable-backup-$(date +%s).dump"
    sfdisk --dump "/dev/$ROOT_DISK" > "$BACKUP_FILE"
    log_info "Partition table backed up to: $BACKUP_FILE"
    
    # Resize partition using sfdisk
    # Best practice: Omit start to leave it untouched, just set new size
    # Use --force with --no-reread for in-use disk
    log_info "Resizing root partition ${ROOT_PART_NUM}..."
    if echo ",${REMAINING_MIB}M" | sfdisk --force --no-reread "/dev/$ROOT_DISK" -N"${ROOT_PART_NUM}" 2>&1 | tee -a "$LOG_FILE"; then
        log_info "Root partition resized in partition table (ioctl error is expected)"
    else
        log_warn "sfdisk reported errors - checking partition table"
    fi
    
    # Verify partition table
    if sfdisk --verify "/dev/$ROOT_DISK" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Partition table verified successfully"
    else
        log_error "Partition table verification failed"
        return 1
    fi
    
    # Inform kernel of partition table changes
    log_info "Informing kernel of partition table changes..."
    if command -v partprobe >/dev/null 2>&1; then
        partprobe "/dev/$ROOT_DISK" 2>&1 | tee -a "$LOG_FILE" || true
    else
        partx --update "/dev/$ROOT_DISK" 2>&1 | tee -a "$LOG_FILE" || true
    fi
    
    # Resize filesystem
    log_info "Resizing ${FS_TYPE} filesystem..."
    
    case "$FS_TYPE" in
        ext4|ext3|ext2)
            # Check filesystem first
            log_info "Checking filesystem integrity..."
            e2fsck -f -y "$ROOT_PARTITION" 2>&1 | tee -a "$LOG_FILE" || true
            
            # Resize filesystem
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
    
    return 0
}

# Setup ZRAM with partition overflow
setup_zram_with_partition() {
    log_step "Setting up ZRAM with uncompressed swap partition overflow"
    
    # First setup ZRAM with higher priority
    setup_zram
    
    # Then setup partition-based swap with lower priority
    if [ "$USE_PARTITION" = "yes" ]; then
        log_warn "Partition-based overflow not yet fully automated"
        log_info "To set up manually:"
        log_info "  1. Create partition with create_swap_partition"
        log_info "  2. Format: mkswap /dev/sdXN"
        log_info "  3. Activate with lower priority: swapon -p 10 /dev/sdXN"
        log_info "  4. ZRAM will use priority 100 (higher), partition priority 10 (lower)"
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
    
    # Calculate page-cluster based on storage type
    local page_cluster=3
    if [ "$STORAGE_TYPE" = "hdd" ]; then
        page_cluster=4  # 64KB for HDD
    elif [ "$STORAGE_TYPE" = "ssd" ]; then
        page_cluster=3  # 32KB for SSD
    fi
    
    log_info "Writing kernel parameters to $SYSCTL_CONF"
    
    cat > "$SYSCTL_CONF" <<EOF
# Swap Configuration
# Generated by setup-swap.sh on $(date)
# Architecture: $SWAP_ARCH

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
    echo "=== Architecture ===" 
    echo "Selected: Architecture $SWAP_ARCH"
    
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
    
    if [ "$SWAP_ARCH" -eq 1 ] || [ "$SWAP_ARCH" -eq 2 ] || [ "$SWAP_ARCH" -eq 6 ]; then
        echo ""
        echo "=== ZRAM Statistics ==="
        if [ -f /sys/block/zram0/mm_stat ]; then
            cat /sys/block/zram0/mm_stat
        fi
    fi
    
    if [ "$SWAP_ARCH" -eq 3 ]; then
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

# Architecture-specific setup
setup_architecture() {
    log_step "Setting up Architecture $SWAP_ARCH"
    
    case $SWAP_ARCH in
        1)
            log_info "Architecture 1: ZRAM Only"
            setup_zram
            ;;
        2)
            log_info "Architecture 2: ZRAM + Swap Files (Two-Tier)"
            setup_zram
            if [ "$USE_PARTITION" = "yes" ]; then
                log_info "  Using partition instead of files"
                setup_zram_with_partition
            else
                create_swap_files
            fi
            ;;
        3)
            log_info "Architecture 3: ZSWAP + Swap Files (Recommended)"
            setup_zswap
            if [ "$USE_PARTITION" = "yes" ]; then
                log_info "  Using partition instead of files"
                create_swap_partition
            else
                create_swap_files
            fi
            ;;
        4)
            log_info "Architecture 4: Swap Files Only"
            if [ "$USE_PARTITION" = "yes" ]; then
                log_info "  Using partition instead of files"
                create_swap_partition
            else
                create_swap_files
            fi
            ;;
        5)
            log_info "Architecture 5: ZFS Compressed Swap (zvol)"
            setup_zfs_zvol
            ;;
        6)
            log_info "Architecture 6: ZRAM + ZFS zvol"
            setup_zram
            setup_zfs_zvol
            ;;
        7)
            log_info "Architecture 7: ZRAM + Uncompressed Swap Partition"
            log_info "  ZRAM with zstd+zsmalloc (high priority)"
            log_info "  Partition for overflow (low priority)"
            setup_zram_with_partition
            ;;
        *)
            log_error "Invalid architecture: $SWAP_ARCH (must be 1-7)"
            exit 1
            ;;
    esac
}

# Main function
main() {
    print_banner
    check_root
    
    log_info "Configuration:"
    log_info "  Architecture: $SWAP_ARCH"
    log_info "  Swap Total: ${SWAP_TOTAL_GB}GB"
    log_info "  Swap Files: $SWAP_FILES"
    log_info "  ZRAM Size: ${ZRAM_SIZE_GB}GB"
    log_info "  ZSWAP Pool: ${ZSWAP_POOL_PERCENT}%"
    echo ""
    
    # Print current state
    print_current_config
    
    # Detection and calculation
    detect_system
    calculate_swap_sizes
    
    # NEW: Show analysis and plan
    print_system_analysis_and_plan
    
    # Send telegram notification AFTER showing the plan
    telegram_send "🔧 Starting swap configuration"
    
    # Install dependencies
    install_dependencies
    
    # Disable existing swap
    disable_existing_swap
    
    # Setup architecture
    setup_architecture
    
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
    
    telegram_send "✅ Swap configuration completed"
}

# Run main function
main "$@"
