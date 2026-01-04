#!/bin/bash
# Debian Swap Configuration Setup Script
# Comprehensive swap orchestrator supporting 7 architectures
# Requires: Debian 12/13, root privileges

set -euo pipefail

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

# Directories
SWAP_DIR="/var/swap"
SYSCTL_CONF="/etc/sysctl.d/99-swap.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_debug() { echo -e "${CYAN}[DEBUG]${NC} $*"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

# Get system identification
get_system_id() {
    local hostname=$(hostname)
    local ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
    echo "${hostname} (${ip})"
}

# Telegram notification with source attribution
telegram_send() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] && return 0
    [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    local msg="$1"
    local system_id=$(get_system_id)
    local prefixed_msg="<b>${system_id}</b>\n${msg}"
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
    
    # Detect storage type (SSD vs HDD)
    STORAGE_TYPE="unknown"
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
            create_swap_files
            ;;
        3)
            log_info "Architecture 3: ZSWAP + Swap Files (Recommended)"
            setup_zswap
            create_swap_files
            ;;
        4)
            log_info "Architecture 4: Swap Files Only"
            create_swap_files
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
            log_error "Architecture 7: Compressed Swap File Alternatives - Not yet implemented"
            log_error "Please use ZSWAP (arch 3) or ZRAM (arch 1) instead"
            exit 1
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
    
    telegram_send "🔧 Starting swap configuration"
    
    # Print current state
    print_current_config
    
    # Detection and calculation
    detect_system
    calculate_swap_sizes
    
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
