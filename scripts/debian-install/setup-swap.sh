#!/bin/bash
# setup-swap.sh - Main swap configuration script
#
# Configures swap with support for multiple architectures:
# - ZRAM only
# - ZRAM + Swap Files (priority-based)
# - ZRAM + Writeback
# - ZSWAP + Swap Files (RECOMMENDED)
# - Swap Files only
# - ZFS zvol
# - ZRAM + ZFS zvol

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default configuration
ARCHITECTURE="zswap"
SWAP_TOTAL_GB=0  # Auto-calculate
SWAP_FILES=8
SWAP_DIR="/var/swap"

# ZSWAP settings
ZSWAP_ENABLED=1
ZSWAP_COMPRESSOR="lz4"
ZSWAP_ZPOOL="z3fold"
ZSWAP_MAX_POOL_PERCENT=25
ZSWAP_ACCEPT_THRESHOLD=90

# ZRAM settings
ZRAM_SIZE_GB=0  # Auto-calculate
ZRAM_COMPRESSOR="lz4"
ZRAM_WRITEBACK_DEV=""

# VM settings
VM_SWAPPINESS=60
VM_PAGE_CLUSTER=2
VM_VFS_CACHE_PRESSURE=100

# Flags
DRY_RUN=0
SHOW_DEFAULTS=0

print_colored() {
    local color=$1
    shift
    echo -e "${color}$*${NC}"
}

print_section() {
    echo ""
    print_colored "$BLUE" "=== $1 ==="
    echo ""
}

print_error() {
    print_colored "$RED" "❌ $1"
}

print_success() {
    print_colored "$GREEN" "✅ $1"
}

print_warning() {
    print_colored "$YELLOW" "⚠️  $1"
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Setup swap configuration for Debian 12/13 systems.

OPTIONS:
    --architecture ARCH    Swap architecture (default: zswap)
                          zram | zram-files | zram-writeback | zswap | files | zfs | hybrid
    
    --swap-total GB       Total swap space in GB (default: auto)
    --swap-files N        Number of swap files for concurrency (default: 8)
    --swap-dir DIR        Directory for swap files (default: /var/swap)
    
    --zswap-compressor    lz4 | zstd | lzo | lzo-rle (default: lz4)
    --zswap-zpool         zbud | z3fold | zsmalloc (default: z3fold)
    --zswap-pool-percent  Max pool size as % of RAM (default: 25)
    
    --zram-size GB        ZRAM size in GB (default: auto)
    --zram-compressor     lz4 | zstd | lzo | lzo-rle (default: lz4)
    --zram-backing DEV    Backing device for ZRAM writeback
    
    --swappiness N        vm.swappiness value 0-100 (default: 60)
    --page-cluster N      vm.page-cluster value 0-4 (default: 2)
    
    --dry-run             Show what would be done without making changes
    --show-defaults       Show kernel defaults before changes
    --help                Show this help message

ARCHITECTURES:
    zram              ZRAM only (memory-only compression)
    zram-files        ZRAM + swap files (priority-based tiering)
    zram-writeback    ZRAM with disk writeback support
    zswap             ZSWAP + swap files (RECOMMENDED)
    files             Swap files only (traditional)
    zfs               ZFS zvol
    hybrid            ZRAM + ZFS zvol

EXAMPLES:
    # Default setup (ZSWAP + swap files)
    $0
    
    # Custom ZSWAP configuration
    $0 --architecture zswap --swap-total 16 --zswap-pool-percent 30
    
    # ZRAM only (memory-only)
    $0 --architecture zram --zram-size 4
    
    # ZRAM with writeback
    $0 --architecture zram-writeback --zram-backing /dev/sdb1
    
    # Show what would be done
    $0 --dry-run

EOF
    exit 0
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        echo "Run with: sudo $0"
        exit 1
    fi
}

get_total_memory_gb() {
    local total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    echo $((total_kb / 1024 / 1024))
}

calculate_swap_size() {
    local mem_gb=$(get_total_memory_gb)
    
    # Auto-calculate swap size based on RAM
    if [ "$mem_gb" -le 2 ]; then
        echo $((mem_gb * 2))  # 2x RAM for low memory
    elif [ "$mem_gb" -le 8 ]; then
        echo "$mem_gb"  # 1x RAM
    elif [ "$mem_gb" -le 16 ]; then
        echo $((mem_gb * 3 / 4))  # 0.75x RAM
    else
        echo 8  # Max 8GB for high memory systems
    fi
}

calculate_zram_size() {
    local mem_gb=$(get_total_memory_gb)
    
    # ZRAM size: typically 0.5x RAM
    if [ "$mem_gb" -le 2 ]; then
        echo "$mem_gb"  # 1x for low memory
    elif [ "$mem_gb" -le 8 ]; then
        echo $((mem_gb / 2))  # 0.5x
    else
        echo 4  # Max 4GB
    fi
}

show_kernel_defaults() {
    print_section "Current Kernel Parameters"
    
    echo "vm.swappiness: $(cat /proc/sys/vm/swappiness)"
    echo "vm.page-cluster: $(cat /proc/sys/vm/page-cluster)"
    echo "vm.vfs_cache_pressure: $(cat /proc/sys/vm/vfs_cache_pressure)"
    
    if [ -f /sys/module/zswap/parameters/enabled ]; then
        echo ""
        echo "ZSWAP status:"
        echo "  enabled: $(cat /sys/module/zswap/parameters/enabled)"
        echo "  compressor: $(cat /sys/module/zswap/parameters/compressor)"
        echo "  zpool: $(cat /sys/module/zswap/parameters/zpool)"
        echo "  max_pool_percent: $(cat /sys/module/zswap/parameters/max_pool_percent)"
    fi
    
    echo ""
    echo "Current swap devices:"
    swapon --show || echo "  None configured"
}

remove_existing_swap() {
    print_section "Removing Existing Swap Configuration"
    
    # Disable all swap
    if swapon --show &>/dev/null; then
        swapoff -a
        print_success "Disabled all swap devices"
    fi
    
    # Remove ZRAM
    if [ -d /sys/block/zram0 ]; then
        rmmod zram 2>/dev/null || true
        print_success "Removed ZRAM"
    fi
    
    # Disable ZSWAP
    if [ -f /sys/module/zswap/parameters/enabled ]; then
        echo N > /sys/module/zswap/parameters/enabled 2>/dev/null || true
        print_success "Disabled ZSWAP"
    fi
    
    # Remove swap files
    if [ -d "$SWAP_DIR" ]; then
        rm -f "$SWAP_DIR"/swapfile* 2>/dev/null || true
        print_success "Removed swap files from $SWAP_DIR"
    fi
    
    # Clean up fstab
    if grep -q "swapfile" /etc/fstab 2>/dev/null; then
        sed -i '/swapfile/d' /etc/fstab
        print_success "Cleaned /etc/fstab"
    fi
    
    # Clean up systemd services
    rm -f /etc/systemd/system/zram.service 2>/dev/null || true
    rm -f /etc/systemd/system/zswap.service 2>/dev/null || true
    systemctl daemon-reload
}

setup_zram() {
    local size_gb=$1
    local compressor=$2
    local backing_dev=${3:-}
    
    print_section "Setting up ZRAM"
    
    # Load module
    modprobe zram
    
    # Set compression algorithm
    echo "$compressor" > /sys/block/zram0/comp_algorithm
    print_success "Set compression: $compressor"
    
    # Set backing device if provided
    if [ -n "$backing_dev" ]; then
        echo "$backing_dev" > /sys/block/zram0/backing_dev
        print_success "Set backing device: $backing_dev"
    fi
    
    # Set size
    local size_bytes=$((size_gb * 1024 * 1024 * 1024))
    echo "$size_bytes" > /sys/block/zram0/disksize
    print_success "Set ZRAM size: ${size_gb}GB"
    
    # Make swap
    mkswap /dev/zram0
    swapon -p 100 /dev/zram0
    print_success "ZRAM swap enabled"
    
    # Create systemd service
    local backing_param=""
    if [ -n "$backing_dev" ]; then
        backing_param="ExecStart=/bin/sh -c 'echo $backing_dev > /sys/block/zram0/backing_dev'"
    fi
    
    cat > /etc/systemd/system/zram.service << EOF
[Unit]
Description=ZRAM Swap
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/sbin/modprobe zram
ExecStart=/bin/sh -c 'echo $compressor > /sys/block/zram0/comp_algorithm'
${backing_param}
ExecStart=/bin/sh -c 'echo $size_bytes > /sys/block/zram0/disksize'
ExecStart=/sbin/mkswap /dev/zram0
ExecStart=/sbin/swapon -p 100 /dev/zram0
ExecStop=/sbin/swapoff /dev/zram0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable zram.service
    print_success "Created ZRAM systemd service"
}

setup_zswap() {
    local compressor=$1
    local zpool=$2
    local max_pool=$3
    
    print_section "Setting up ZSWAP"
    
    # Enable ZSWAP
    echo Y > /sys/module/zswap/parameters/enabled
    print_success "Enabled ZSWAP"
    
    # Set compressor
    echo "$compressor" > /sys/module/zswap/parameters/compressor
    print_success "Set compressor: $compressor"
    
    # Set zpool
    echo "$zpool" > /sys/module/zswap/parameters/zpool
    print_success "Set zpool: $zpool"
    
    # Set max pool
    echo "$max_pool" > /sys/module/zswap/parameters/max_pool_percent
    print_success "Set max pool: ${max_pool}%"
    
    # Set accept threshold
    echo "$ZSWAP_ACCEPT_THRESHOLD" > /sys/module/zswap/parameters/accept_threshold_percent
    
    # Make persistent via kernel parameters
    if ! grep -q "zswap.enabled=1" /etc/default/grub; then
        # Create backup
        cp /etc/default/grub /etc/default/grub.backup
        
        # Check if GRUB_CMDLINE_LINUX_DEFAULT exists
        if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub; then
            # Remove any existing zswap parameters first
            sed -i 's/zswap\.[a-z_]*=[^ "]* //g' /etc/default/grub
            
            # Add new zswap parameters
            sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"zswap.enabled=1 zswap.compressor=$compressor zswap.zpool=$zpool zswap.max_pool_percent=$max_pool /" /etc/default/grub
        else
            # Create new line
            echo "GRUB_CMDLINE_LINUX_DEFAULT=\"zswap.enabled=1 zswap.compressor=$compressor zswap.zpool=$zpool zswap.max_pool_percent=$max_pool\"" >> /etc/default/grub
        fi
        
        update-grub
        print_success "Updated GRUB configuration"
    fi
}

setup_swap_files() {
    local total_gb=$1
    local num_files=$2
    local dir=$3
    
    print_section "Setting up Swap Files"
    
    # Create directory
    mkdir -p "$dir"
    
    # Calculate size per file
    local size_per_file=$((total_gb * 1024 / num_files))
    
    print_colored "$CYAN" "Creating $num_files swap files of ${size_per_file}MB each in $dir"
    
    for i in $(seq 1 "$num_files"); do
        local swapfile="$dir/swapfile$i"
        
        # Create file
        fallocate -l "${size_per_file}M" "$swapfile"
        chmod 600 "$swapfile"
        
        # Make swap
        mkswap "$swapfile"
        swapon "$swapfile"
        
        # Add to fstab
        if ! grep -q "$swapfile" /etc/fstab; then
            echo "$swapfile none swap sw 0 0" >> /etc/fstab
        fi
        
        echo -n "."
    done
    echo ""
    
    print_success "Created $num_files swap files totaling ${total_gb}GB"
}

configure_vm_parameters() {
    print_section "Configuring VM Parameters"
    
    # Create sysctl configuration
    cat > /etc/sysctl.d/99-swap.conf << EOF
# Swap configuration
# Generated by setup-swap.sh on $(date)

# How aggressively to swap (0-100, higher = more aggressive)
vm.swappiness = $VM_SWAPPINESS

# Number of pages to read ahead on swap-in (2^N pages)
vm.page-cluster = $VM_PAGE_CLUSTER

# Tendency to reclaim inode/dentry caches vs page cache
vm.vfs_cache_pressure = $VM_VFS_CACHE_PRESSURE

EOF
    
    # Apply settings
    sysctl -p /etc/sysctl.d/99-swap.conf
    
    print_success "VM parameters configured"
    echo "  vm.swappiness = $VM_SWAPPINESS"
    echo "  vm.page-cluster = $VM_PAGE_CLUSTER"
    echo "  vm.vfs_cache_pressure = $VM_VFS_CACHE_PRESSURE"
}

setup_architecture() {
    local arch=$1
    
    case "$arch" in
        zram)
            [ "$ZRAM_SIZE_GB" -eq 0 ] && ZRAM_SIZE_GB=$(calculate_zram_size)
            setup_zram "$ZRAM_SIZE_GB" "$ZRAM_COMPRESSOR"
            ;;
        
        zram-files)
            [ "$ZRAM_SIZE_GB" -eq 0 ] && ZRAM_SIZE_GB=$(calculate_zram_size)
            [ "$SWAP_TOTAL_GB" -eq 0 ] && SWAP_TOTAL_GB=$(calculate_swap_size)
            setup_zram "$ZRAM_SIZE_GB" "$ZRAM_COMPRESSOR"
            setup_swap_files "$SWAP_TOTAL_GB" "$SWAP_FILES" "$SWAP_DIR"
            ;;
        
        zram-writeback)
            if [ -z "$ZRAM_WRITEBACK_DEV" ]; then
                print_error "ZRAM writeback requires --zram-backing device"
                exit 1
            fi
            [ "$ZRAM_SIZE_GB" -eq 0 ] && ZRAM_SIZE_GB=$(calculate_zram_size)
            setup_zram "$ZRAM_SIZE_GB" "$ZRAM_COMPRESSOR" "$ZRAM_WRITEBACK_DEV"
            ;;
        
        zswap)
            [ "$SWAP_TOTAL_GB" -eq 0 ] && SWAP_TOTAL_GB=$(calculate_swap_size)
            setup_zswap "$ZSWAP_COMPRESSOR" "$ZSWAP_ZPOOL" "$ZSWAP_MAX_POOL_PERCENT"
            setup_swap_files "$SWAP_TOTAL_GB" "$SWAP_FILES" "$SWAP_DIR"
            ;;
        
        files)
            [ "$SWAP_TOTAL_GB" -eq 0 ] && SWAP_TOTAL_GB=$(calculate_swap_size)
            setup_swap_files "$SWAP_TOTAL_GB" "$SWAP_FILES" "$SWAP_DIR"
            ;;
        
        *)
            print_error "Unknown architecture: $arch"
            exit 1
            ;;
    esac
}

show_summary() {
    print_section "Configuration Summary"
    
    echo "Architecture: $ARCHITECTURE"
    echo ""
    
    # Memory info
    local mem_gb=$(get_total_memory_gb)
    echo "System RAM: ${mem_gb}GB"
    
    # Swap devices
    echo ""
    echo "Swap devices:"
    swapon --show
    
    # ZSWAP status
    if [ -f /sys/module/zswap/parameters/enabled ]; then
        local zswap_enabled=$(cat /sys/module/zswap/parameters/enabled)
        if [ "$zswap_enabled" = "Y" ]; then
            echo ""
            echo "ZSWAP configuration:"
            echo "  Enabled: Yes"
            echo "  Compressor: $(cat /sys/module/zswap/parameters/compressor)"
            echo "  Zpool: $(cat /sys/module/zswap/parameters/zpool)"
            echo "  Max pool: $(cat /sys/module/zswap/parameters/max_pool_percent)%"
        fi
    fi
    
    # ZRAM status
    if [ -d /sys/block/zram0 ]; then
        echo ""
        echo "ZRAM configuration:"
        echo "  Device: /dev/zram0"
        echo "  Algorithm: $(cat /sys/block/zram0/comp_algorithm | grep -o '\[.*\]' | tr -d '[]')"
        echo "  Size: $(cat /sys/block/zram0/disksize | awk '{printf "%.2f GB", $1/1073741824}')"
    fi
    
    # VM parameters
    echo ""
    echo "VM parameters:"
    echo "  vm.swappiness: $(cat /proc/sys/vm/swappiness)"
    echo "  vm.page-cluster: $(cat /proc/sys/vm/page-cluster)"
    echo "  vm.vfs_cache_pressure: $(cat /proc/sys/vm/vfs_cache_pressure)"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --architecture)
            ARCHITECTURE="$2"
            shift 2
            ;;
        --swap-total)
            SWAP_TOTAL_GB="$2"
            shift 2
            ;;
        --swap-files)
            SWAP_FILES="$2"
            shift 2
            ;;
        --swap-dir)
            SWAP_DIR="$2"
            shift 2
            ;;
        --zswap-compressor)
            ZSWAP_COMPRESSOR="$2"
            shift 2
            ;;
        --zswap-zpool)
            ZSWAP_ZPOOL="$2"
            shift 2
            ;;
        --zswap-pool-percent)
            ZSWAP_MAX_POOL_PERCENT="$2"
            shift 2
            ;;
        --zram-size)
            ZRAM_SIZE_GB="$2"
            shift 2
            ;;
        --zram-compressor)
            ZRAM_COMPRESSOR="$2"
            shift 2
            ;;
        --zram-backing)
            ZRAM_WRITEBACK_DEV="$2"
            shift 2
            ;;
        --swappiness)
            VM_SWAPPINESS="$2"
            shift 2
            ;;
        --page-cluster)
            VM_PAGE_CLUSTER="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --show-defaults)
            SHOW_DEFAULTS=1
            shift
            ;;
        --help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Main execution
main() {
    print_colored "$CYAN" "╔═══════════════════════════════════════════════════╗"
    print_colored "$CYAN" "║        Swap Configuration Setup                  ║"
    print_colored "$CYAN" "╚═══════════════════════════════════════════════════╝"
    echo ""
    
    check_root
    
    if [ "$SHOW_DEFAULTS" -eq 1 ]; then
        show_kernel_defaults
        exit 0
    fi
    
    if [ "$DRY_RUN" -eq 1 ]; then
        print_warning "DRY RUN MODE - No changes will be made"
        echo ""
    fi
    
    # Show current state
    show_kernel_defaults
    
    if [ "$DRY_RUN" -eq 1 ]; then
        print_section "Would configure:"
        echo "Architecture: $ARCHITECTURE"
        echo "Swap total: ${SWAP_TOTAL_GB}GB (0 = auto)"
        echo "Swap files: $SWAP_FILES"
        exit 0
    fi
    
    # Confirm
    echo ""
    print_warning "This will reconfigure swap. Existing configuration will be removed."
    read -p "Continue? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_colored "$YELLOW" "Aborted"
        exit 0
    fi
    
    # Execute setup
    remove_existing_swap
    setup_architecture "$ARCHITECTURE"
    configure_vm_parameters
    
    # Show results
    show_summary
    
    print_section "Setup Complete"
    print_success "Swap configuration successful!"
    echo ""
    echo "Next steps:"
    echo "  • Monitor: ./swap-monitor.sh"
    echo "  • Analyze: ./analyze-running-system.sh"
    echo "  • Benchmark: ./benchmark.py"
    echo ""
    print_colored "$YELLOW" "Note: Some settings require reboot to take full effect"
}

main "$@"
