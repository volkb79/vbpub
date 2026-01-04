#!/bin/bash
#
# setup-swap.sh - Multi-tier Swap Configuration Script
#
# Purpose: Configure optimal swap setup based on system resources
# Default: ZSWAP + Swap Files (recommended for production)
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Configuration
ARCHITECTURE="${SWAP_ARCHITECTURE:-zswap}"  # zram, zswap, hybrid, files, zfs
SWAP_FILES="${SWAP_FILES:-8}"
SWAP_DIR="/var/swap"

# Get system info
get_system_info() {
    # RAM in GB
    RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    if [ "$RAM_GB" -eq 0 ]; then
        RAM_GB=1
    fi
    
    # Disk space in GB
    DISK_GB=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    
    log_info "System: ${RAM_GB}GB RAM, ${DISK_GB}GB free disk"
}

# Calculate swap size based on RAM and disk
calculate_swap_size() {
    local ram=$1
    local disk=$2
    
    # RAM-based sizing
    if [ "$ram" -le 2 ]; then
        ZRAM_SIZE="512M"
        SWAP_TOTAL_GB=2
    elif [ "$ram" -le 4 ]; then
        ZRAM_SIZE="1G"
        SWAP_TOTAL_GB=4
    elif [ "$ram" -le 8 ]; then
        ZRAM_SIZE="1536M"
        SWAP_TOTAL_GB=6
    elif [ "$ram" -le 16 ]; then
        ZRAM_SIZE="2G"
        SWAP_TOTAL_GB=8
    elif [ "$ram" -le 32 ]; then
        ZRAM_SIZE="3G"
        SWAP_TOTAL_GB=12
    else
        ZRAM_SIZE="4G"
        SWAP_TOTAL_GB=16
    fi
    
    # Disk constraints
    if [ "$disk" -lt 30 ]; then
        SWAP_TOTAL_GB=2
    elif [ "$disk" -lt 50 ]; then
        SWAP_TOTAL_GB=4
    elif [ "$disk" -lt 100 ]; then
        SWAP_TOTAL_GB=8
    fi
    
    # Calculate per-file size
    SWAP_FILE_SIZE_GB=$((SWAP_TOTAL_GB / SWAP_FILES))
    if [ "$SWAP_FILE_SIZE_GB" -eq 0 ]; then
        SWAP_FILE_SIZE_GB=1
        SWAP_FILES=$((SWAP_TOTAL_GB))
        if [ "$SWAP_FILES" -eq 0 ]; then
            SWAP_FILES=1
        fi
    fi
    
    log_info "Calculated: ZRAM=${ZRAM_SIZE}, Total Swap=${SWAP_TOTAL_GB}GB, ${SWAP_FILES} files × ${SWAP_FILE_SIZE_GB}GB"
}

print_kernel_defaults() {
    log_section "Current Kernel Parameters (BEFORE changes)"
    
    echo "vm.swappiness = $(cat /proc/sys/vm/swappiness)"
    echo "vm.page-cluster = $(cat /proc/sys/vm/page_cluster)"
    echo "vm.vfs_cache_pressure = $(cat /proc/sys/vm/vfs_cache_pressure)"
    echo "vm.dirty_ratio = $(cat /proc/sys/vm/dirty_ratio)"
    echo "vm.dirty_background_ratio = $(cat /proc/sys/vm/dirty_background_ratio)"
    
    if [ -f /sys/module/zswap/parameters/enabled ]; then
        echo "zswap.enabled = $(cat /sys/module/zswap/parameters/enabled)"
        echo "zswap.compressor = $(cat /sys/module/zswap/parameters/compressor 2>/dev/null || echo 'N/A')"
        echo "zswap.zpool = $(cat /sys/module/zswap/parameters/zpool 2>/dev/null || echo 'N/A')"
        echo "zswap.max_pool_percent = $(cat /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || echo 'N/A')"
    fi
    
    echo ""
}

create_swap_files() {
    local num_files=$1
    local file_size_gb=$2
    
    log_info "Creating ${num_files} swap files of ${file_size_gb}GB each..."
    
    mkdir -p "$SWAP_DIR"
    
    for i in $(seq 1 "$num_files"); do
        local swapfile="${SWAP_DIR}/swapfile${i}"
        
        if [ -f "$swapfile" ]; then
            log_warn "Swap file already exists: $swapfile"
            swapoff "$swapfile" 2>/dev/null || true
        fi
        
        log_info "Creating $swapfile (${file_size_gb}GB)..."
        # Use fallocate for better performance
        fallocate -l ${file_size_gb}G "$swapfile"
        chmod 600 "$swapfile"
        mkswap "$swapfile" >/dev/null
        swapon "$swapfile" -p 10
        
        log_info "Activated: $swapfile"
    done
}

setup_zswap() {
    log_section "Configuring ZSWAP + Swap Files"
    
    # Enable ZSWAP
    if [ -f /sys/module/zswap/parameters/enabled ]; then
        echo 1 > /sys/module/zswap/parameters/enabled
        
        # Set compressor (lz4 or lzo)
        if grep -q lz4 /sys/module/zswap/parameters/compressor 2>/dev/null; then
            echo lz4 > /sys/module/zswap/parameters/compressor
        else
            echo lzo > /sys/module/zswap/parameters/compressor
        fi
        
        # Set zpool (prefer zsmalloc, fallback to z3fold)
        if grep -q zsmalloc /sys/module/zswap/parameters/zpool 2>/dev/null; then
            echo zsmalloc > /sys/module/zswap/parameters/zpool
        elif grep -q z3fold /sys/module/zswap/parameters/zpool 2>/dev/null; then
            echo z3fold > /sys/module/zswap/parameters/zpool
        fi
        
        # Set pool size
        echo 20 > /sys/module/zswap/parameters/max_pool_percent
        
        log_info "ZSWAP enabled with compression"
    else
        log_error "ZSWAP not available in kernel"
        exit 1
    fi
    
    # Create swap files
    create_swap_files "$SWAP_FILES" "$SWAP_FILE_SIZE_GB"
}

setup_zram_only() {
    log_section "Configuring ZRAM Only"
    
    modprobe zram
    
    # Configure ZRAM device
    if [ -b /dev/zram0 ]; then
        # Reset if already exists
        swapoff /dev/zram0 2>/dev/null || true
        echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    fi
    
    # Set algorithm (prefer lzo-rle or lz4)
    local algo="lzo"
    if grep -q lzo-rle /sys/block/zram0/comp_algorithm 2>/dev/null; then
        algo="lzo-rle"
    elif grep -q lz4 /sys/block/zram0/comp_algorithm 2>/dev/null; then
        algo="lz4"
    fi
    echo "$algo" > /sys/block/zram0/comp_algorithm
    
    # Set size
    echo "$ZRAM_SIZE" > /sys/block/zram0/disksize
    
    # Initialize swap
    mkswap /dev/zram0 >/dev/null
    swapon /dev/zram0 -p 100
    
    log_info "ZRAM configured: $ZRAM_SIZE with $algo compression"
}

setup_hybrid() {
    log_section "Configuring ZRAM + Swap Files (Hybrid)"
    
    # Setup ZRAM with high priority
    setup_zram_only
    
    # Setup swap files with lower priority
    log_info "Adding swap file tier..."
    create_swap_files "$SWAP_FILES" "$SWAP_FILE_SIZE_GB"
}

setup_files_only() {
    log_section "Configuring Swap Files Only"
    
    create_swap_files "$SWAP_FILES" "$SWAP_FILE_SIZE_GB"
}

configure_sysctl() {
    log_section "Configuring Kernel Parameters"
    
    cat > /etc/sysctl.d/99-swap.conf <<EOF
# Swap configuration
# Generated by setup-swap.sh on $(date)

# Swappiness: Lower = prefer RAM (0-100, default 60)
vm.swappiness = 10

# Page cluster: Pages to swap at once: 2^value (0-9, default 3)
vm.page-cluster = 3

# VFS cache pressure: Higher = reclaim caches faster (default 100)
vm.vfs_cache_pressure = 50

# Dirty ratios for write-back
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF
    
    sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null
    
    log_info "Kernel parameters configured"
}

create_fstab_entries() {
    log_section "Updating /etc/fstab"
    
    # Backup fstab
    cp /etc/fstab /etc/fstab.backup-$(date +%Y%m%d-%H%M%S)
    
    # Remove old swap entries
    sed -i '/# Swap files managed by setup-swap.sh/,/# End swap files/d' /etc/fstab
    
    # Add new entries
    cat >> /etc/fstab <<EOF

# Swap files managed by setup-swap.sh
EOF
    
    if [ "$ARCHITECTURE" = "zram" ] || [ "$ARCHITECTURE" = "hybrid" ]; then
        echo "# ZRAM swap is managed by systemd service, not fstab" >> /etc/fstab
    fi
    
    if [ "$ARCHITECTURE" != "zram" ]; then
        for i in $(seq 1 "$SWAP_FILES"); do
            echo "${SWAP_DIR}/swapfile${i} none swap sw,pri=10 0 0" >> /etc/fstab
        done
    fi
    
    echo "# End swap files" >> /etc/fstab
    
    log_info "/etc/fstab updated"
}

create_systemd_services() {
    if [ "$ARCHITECTURE" = "zram" ] || [ "$ARCHITECTURE" = "hybrid" ]; then
        log_section "Creating systemd services"
        
        cat > /etc/systemd/system/zram-swap.service <<EOF
[Unit]
Description=ZRAM Swap
After=local-fs.target
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'modprobe zram && echo lzo-rle > /sys/block/zram0/comp_algorithm && echo ${ZRAM_SIZE} > /sys/block/zram0/disksize && mkswap /dev/zram0 && swapon /dev/zram0 -p 100'
ExecStop=/bin/sh -c 'swapoff /dev/zram0 && echo 1 > /sys/block/zram0/reset'

[Install]
WantedBy=swap.target
EOF
        
        systemctl daemon-reload
        systemctl enable zram-swap.service
        
        log_info "ZRAM systemd service created and enabled"
    fi
}

print_status() {
    log_section "Swap Configuration Status"
    
    echo "Current swap devices:"
    swapon --show
    
    echo ""
    echo "Memory status:"
    free -h
    
    echo ""
}

print_new_values() {
    log_section "New Kernel Parameters (AFTER changes)"
    
    echo "vm.swappiness = $(cat /proc/sys/vm/swappiness)"
    echo "vm.page-cluster = $(cat /proc/sys/vm/page_cluster)"
    echo "vm.vfs_cache_pressure = $(cat /proc/sys/vm/vfs_cache_pressure)"
    echo "vm.dirty_ratio = $(cat /proc/sys/vm/dirty_ratio)"
    echo "vm.dirty_background_ratio = $(cat /proc/sys/vm/dirty_background_ratio)"
    
    if [ -f /sys/module/zswap/parameters/enabled ]; then
        echo "zswap.enabled = $(cat /sys/module/zswap/parameters/enabled)"
        echo "zswap.compressor = $(cat /sys/module/zswap/parameters/compressor 2>/dev/null || echo 'N/A')"
        echo "zswap.zpool = $(cat /sys/module/zswap/parameters/zpool 2>/dev/null || echo 'N/A')"
        echo "zswap.max_pool_percent = $(cat /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || echo 'N/A')"
    fi
    
    echo ""
}

print_summary() {
    log_section "Setup Complete!"
    
    echo "Architecture: $ARCHITECTURE"
    echo "Total swap: ${SWAP_TOTAL_GB}GB"
    if [ "$ARCHITECTURE" != "files" ]; then
        echo "ZRAM size: $ZRAM_SIZE"
    fi
    if [ "$ARCHITECTURE" != "zram" ]; then
        echo "Swap files: ${SWAP_FILES} × ${SWAP_FILE_SIZE_GB}GB"
    fi
    
    echo ""
    echo "Monitoring commands:"
    echo "  swapon --show          # Show swap devices"
    echo "  free -h                # Memory overview"
    echo "  /root/swap-monitor.sh  # Detailed monitoring"
    
    echo ""
    echo "Configuration persisted to:"
    echo "  /etc/fstab"
    echo "  /etc/sysctl.d/99-swap.conf"
    if [ "$ARCHITECTURE" = "zram" ] || [ "$ARCHITECTURE" = "hybrid" ]; then
        echo "  /etc/systemd/system/zram-swap.service"
    fi
    
    echo ""
    log_info "No reboot required - swap is active now"
}

main() {
    check_root
    
    print_kernel_defaults
    
    get_system_info
    calculate_swap_size "$RAM_GB" "$DISK_GB"
    
    # Turn off existing swap
    log_info "Disabling existing swap..."
    swapoff -a 2>/dev/null || true
    
    # Setup based on architecture
    case "$ARCHITECTURE" in
        zswap)
            setup_zswap
            ;;
        zram)
            setup_zram_only
            ;;
        hybrid)
            setup_hybrid
            ;;
        files)
            setup_files_only
            ;;
        *)
            log_error "Unknown architecture: $ARCHITECTURE"
            log_error "Valid options: zswap, zram, hybrid, files"
            exit 1
            ;;
    esac
    
    configure_sysctl
    create_fstab_entries
    create_systemd_services
    
    print_new_values
    print_status
    print_summary
}

main "$@"
