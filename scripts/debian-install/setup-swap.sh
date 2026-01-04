#!/bin/bash
#
# setup-swap.sh - Main swap configuration orchestrator
#
# Detects system, installs dependencies, configures swap based on architecture
# Supports: ZRAM-only, ZRAM+files, ZSWAP+files, files-only, ZFS zvol, ZRAM+ZFS
#
# Usage:
#   sudo ./setup-swap.sh
#   sudo SWAP_ARCH=zswap-files SWAP_TOTAL_GB=64 ./setup-swap.sh
#

set -euo pipefail

# Configuration from environment with defaults
SWAP_ARCH="${SWAP_ARCH:-auto}"
SWAP_TOTAL_GB="${SWAP_TOTAL_GB:-auto}"
SWAP_FILES="${SWAP_FILES:-8}"
ZRAM_SIZE_PERCENT="${ZRAM_SIZE_PERCENT:-50}"
ZRAM_COMP_ALGO="${ZRAM_COMP_ALGO:-auto}"
ZRAM_ALLOCATOR="${ZRAM_ALLOCATOR:-zsmalloc}"
ZSWAP_COMP_ALGO="${ZSWAP_COMP_ALGO:-auto}"
ZSWAP_POOL_PERCENT="${ZSWAP_POOL_PERCENT:-20}"
VM_PAGE_CLUSTER="${VM_PAGE_CLUSTER:-3}"
VM_SWAPPINESS="${VM_SWAPPINESS:-60}"
VM_VFS_CACHE_PRESSURE="${VM_VFS_CACHE_PRESSURE:-100}"
AUTO_BENCHMARK="${AUTO_BENCHMARK:-true}"
SKIP_INSTALL="${SKIP_INSTALL:-false}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Detect system info
RAM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_TOTAL_GB=$((RAM_TOTAL_KB / 1024 / 1024))
DISK_FREE_GB=$(df / | tail -1 | awk '{print int($4/1024/1024)}')
CPU_COUNT=$(nproc)
CPU_MHZ=$(lscpu | grep "CPU MHz" | awk '{print int($3)}' | head -1)
CPU_MHZ=${CPU_MHZ:-2000}

send_telegram() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=$1" \
        -d "parse_mode=HTML" >/dev/null 2>&1 || true
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

print_current_kernel_defaults() {
    log_info "=== Current Kernel Parameters ==="
    echo "vm.swappiness = $(sysctl -n vm.swappiness)"
    echo "vm.page-cluster = $(sysctl -n vm.page-cluster)"
    echo "vm.vfs_cache_pressure = $(sysctl -n vm.vfs_cache_pressure)"
    
    if [ -e /sys/module/zswap/parameters/enabled ]; then
        echo "zswap.enabled = $(cat /sys/module/zswap/parameters/enabled)"
        echo "zswap.compressor = $(cat /sys/module/zswap/parameters/compressor 2>/dev/null || echo 'N/A')"
        echo "zswap.zpool = $(cat /sys/module/zswap/parameters/zpool 2>/dev/null || echo 'N/A')"
        echo "zswap.max_pool_percent = $(cat /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || echo 'N/A')"
    fi
    echo ""
}

install_dependencies() {
    if [ "$SKIP_INSTALL" = "true" ]; then
        log_info "Skipping package installation (SKIP_INSTALL=true)"
        return 0
    fi
    
    log_info "Installing dependencies..."
    apt-get update -qq
    apt-get install -y -qq \
        zstd \
        python3 \
        python3-requests \
        sysstat \
        bc \
        jq \
        util-linux \
        2>/dev/null || true
    log_success "Dependencies installed"
}

detect_compression_algorithms() {
    local type="$1"  # zram or zswap
    local available=""
    
    if [ "$type" = "zram" ]; then
        # Load zram module to check available algorithms
        modprobe zram 2>/dev/null || true
        if [ -e /sys/block/zram0/comp_algorithm ]; then
            available=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "")
        fi
        rmmod zram 2>/dev/null || true
    else
        # ZSWAP algorithms
        if [ -e /sys/module/zswap/parameters/compressor ]; then
            available=$(cat /sys/module/zswap/parameters/compressor 2>/dev/null || echo "")
        fi
    fi
    
    # Parse available algorithms (format: [current] algo1 algo2)
    available=$(echo "$available" | sed 's/\[//g' | sed 's/\]//g')
    
    # Prefer zstd > lz4 > lzo-rle > lzo
    for algo in zstd lz4 lzo-rle lzo; do
        if echo "$available" | grep -q "$algo"; then
            echo "$algo"
            return 0
        fi
    done
    
    # Fallback
    echo "lz4"
}

calculate_swap_size() {
    local ram_gb=$1
    local disk_gb=$2
    local swap_gb
    
    # Base calculation
    if [ "$ram_gb" -le 2 ]; then
        swap_gb=$((ram_gb * 4))
    elif [ "$ram_gb" -le 8 ]; then
        swap_gb=$((ram_gb * 2))
    else
        swap_gb=$((ram_gb * 3 / 2))
    fi
    
    # Cap at 30% of disk
    local max_swap=$((disk_gb * 30 / 100))
    [ "$swap_gb" -gt "$max_swap" ] && swap_gb=$max_swap
    
    # Min 4GB, max 128GB
    [ "$swap_gb" -lt 4 ] && swap_gb=4
    [ "$swap_gb" -gt 128 ] && swap_gb=128
    
    echo "$swap_gb"
}

select_architecture() {
    local ram_gb=$1
    local cpu_mhz=$2
    
    if [ "$ram_gb" -ge 32 ]; then
        echo "zram-only"
    elif [ "$ram_gb" -le 2 ]; then
        echo "zswap-files"
    elif [ "$cpu_mhz" -lt 2000 ] && [ "$ram_gb" -gt 4 ]; then
        echo "files-only"
    else
        echo "zswap-files"
    fi
}

disable_existing_swap() {
    log_info "Disabling existing swap..."
    swapoff -a 2>/dev/null || true
    
    # Remove old swap files
    for i in {0..15}; do
        [ -f "/swapfile.$i" ] && rm -f "/swapfile.$i"
    done
    
    # Stop ZRAM if running
    if systemctl is-active --quiet zram-swap 2>/dev/null; then
        systemctl stop zram-swap
        systemctl disable zram-swap
    fi
    
    # Unload ZRAM module
    rmmod zram 2>/dev/null || true
    
    log_success "Existing swap disabled"
}

create_swap_files() {
    local total_gb=$1
    local num_files=$2
    local size_per_file=$((total_gb / num_files))
    
    log_info "Creating $num_files swap files (${size_per_file}GB each)..."
    
    for i in $(seq 0 $((num_files - 1))); do
        local swapfile="/swapfile.$i"
        log_info "Creating $swapfile (${size_per_file}GB)..."
        
        dd if=/dev/zero of="$swapfile" bs=1M count=$((size_per_file * 1024)) status=progress 2>&1 | tail -1
        chmod 600 "$swapfile"
        mkswap "$swapfile" >/dev/null
        swapon -p 10 "$swapfile"
        
        log_success "$swapfile created and activated"
    done
    
    # Add to fstab
    for i in $(seq 0 $((num_files - 1))); do
        local swapfile="/swapfile.$i"
        if ! grep -q "$swapfile" /etc/fstab; then
            echo "$swapfile none swap sw,pri=10 0 0" >> /etc/fstab
        fi
    done
}

setup_zram() {
    local size_percent=$1
    local comp_algo=$2
    local allocator=$3
    
    log_info "Setting up ZRAM (${size_percent}% of RAM, algo=$comp_algo, allocator=$allocator)..."
    
    # Load module with allocator
    if [ "$allocator" != "zsmalloc" ]; then
        echo "options zram allocator=$allocator" > /etc/modprobe.d/zram.conf
    fi
    
    modprobe zram
    
    # Set compression algorithm
    echo "$comp_algo" > /sys/block/zram0/comp_algorithm
    
    # Calculate size
    local zram_size=$(( (RAM_TOTAL_KB * size_percent / 100) * 1024 ))
    echo "$zram_size" > /sys/block/zram0/disksize
    
    # Create swap
    mkswap /dev/zram0 >/dev/null
    swapon -p 100 /dev/zram0  # Higher priority than disk
    
    # Create systemd service
    cat > /etc/systemd/system/zram-swap.service << EOF
[Unit]
Description=ZRAM Swap
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'modprobe zram && echo $comp_algo > /sys/block/zram0/comp_algorithm && echo $zram_size > /sys/block/zram0/disksize && mkswap /dev/zram0 && swapon -p 100 /dev/zram0'
ExecStop=/bin/sh -c 'swapoff /dev/zram0; rmmod zram'

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable zram-swap
    
    log_success "ZRAM configured and activated"
}

setup_zswap() {
    local pool_percent=$1
    local comp_algo=$2
    local allocator=$3
    
    log_info "Setting up ZSWAP (${pool_percent}% pool, algo=$comp_algo, allocator=$allocator)..."
    
    # Enable ZSWAP
    if [ ! -e /sys/module/zswap/parameters/enabled ]; then
        log_warn "ZSWAP not available in kernel, enabling via boot parameter"
        # Add to grub
        if ! grep -q "zswap.enabled=1" /etc/default/grub; then
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="zswap.enabled=1 zswap.compressor='$comp_algo' zswap.zpool='$allocator' zswap.max_pool_percent='$pool_percent' /' /etc/default/grub
            update-grub
            log_warn "ZSWAP configured in bootloader. Reboot required!"
        fi
    else
        echo 1 > /sys/module/zswap/parameters/enabled
        echo "$comp_algo" > /sys/module/zswap/parameters/compressor 2>/dev/null || log_warn "Could not set compressor"
        echo "$allocator" > /sys/module/zswap/parameters/zpool 2>/dev/null || log_warn "Could not set zpool"
        echo "$pool_percent" > /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || log_warn "Could not set max_pool_percent"
        log_success "ZSWAP configured and activated"
    fi
}

configure_kernel_parameters() {
    log_info "Configuring kernel parameters..."
    
    cat > /etc/sysctl.d/99-swap.conf << EOF
# Swap configuration
vm.swappiness=$VM_SWAPPINESS
vm.page-cluster=$VM_PAGE_CLUSTER
vm.vfs_cache_pressure=$VM_VFS_CACHE_PRESSURE
EOF
    
    sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null
    log_success "Kernel parameters configured"
}

print_new_values() {
    log_info "=== New Kernel Parameters ==="
    echo "vm.swappiness = $(sysctl -n vm.swappiness)"
    echo "vm.page-cluster = $(sysctl -n vm.page-cluster)"
    echo "vm.vfs_cache_pressure = $(sysctl -n vm.vfs_cache_pressure)"
    
    if [ -e /sys/module/zswap/parameters/enabled ]; then
        echo "zswap.enabled = $(cat /sys/module/zswap/parameters/enabled)"
        echo "zswap.compressor = $(cat /sys/module/zswap/parameters/compressor 2>/dev/null || echo 'N/A')"
        echo "zswap.zpool = $(cat /sys/module/zswap/parameters/zpool 2>/dev/null || echo 'N/A')"
        echo "zswap.max_pool_percent = $(cat /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || echo 'N/A')"
    fi
    echo ""
}

install_monitoring_tools() {
    log_info "Installing monitoring tools..."
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Install swap-monitor.sh
    if [ -f "$script_dir/swap-monitor.sh" ]; then
        cp "$script_dir/swap-monitor.sh" /usr/local/bin/
        chmod +x /usr/local/bin/swap-monitor.sh
        log_success "Installed swap-monitor.sh to /usr/local/bin/"
    fi
}

main() {
    log_info "=== Debian Swap Configuration Setup ==="
    log_info "System: ${RAM_TOTAL_GB}GB RAM, ${DISK_FREE_GB}GB disk free, ${CPU_COUNT} CPUs @ ${CPU_MHZ}MHz"
    
    check_root
    print_current_kernel_defaults
    install_dependencies
    
    # Auto-detect algorithms if needed
    if [ "$ZRAM_COMP_ALGO" = "auto" ]; then
        ZRAM_COMP_ALGO=$(detect_compression_algorithms "zram")
        log_info "Auto-detected ZRAM algorithm: $ZRAM_COMP_ALGO"
    fi
    
    if [ "$ZSWAP_COMP_ALGO" = "auto" ]; then
        ZSWAP_COMP_ALGO=$(detect_compression_algorithms "zswap")
        log_info "Auto-detected ZSWAP algorithm: $ZSWAP_COMP_ALGO"
    fi
    
    # Auto-select architecture if needed
    if [ "$SWAP_ARCH" = "auto" ]; then
        SWAP_ARCH=$(select_architecture "$RAM_TOTAL_GB" "$CPU_MHZ")
        log_info "Auto-selected architecture: $SWAP_ARCH"
    fi
    
    # Auto-calculate swap size if needed
    if [ "$SWAP_TOTAL_GB" = "auto" ]; then
        SWAP_TOTAL_GB=$(calculate_swap_size "$RAM_TOTAL_GB" "$DISK_FREE_GB")
        log_info "Auto-calculated swap size: ${SWAP_TOTAL_GB}GB"
    fi
    
    # Disable existing swap
    disable_existing_swap
    
    # Configure based on architecture
    case "$SWAP_ARCH" in
        zram-only)
            log_info "Architecture: ZRAM Only"
            setup_zram "$ZRAM_SIZE_PERCENT" "$ZRAM_COMP_ALGO" "$ZRAM_ALLOCATOR"
            ;;
        
        zram-files)
            log_info "Architecture: ZRAM + Swap Files (Two-Tier)"
            create_swap_files "$SWAP_TOTAL_GB" "$SWAP_FILES"
            setup_zram "$ZRAM_SIZE_PERCENT" "$ZRAM_COMP_ALGO" "$ZRAM_ALLOCATOR"
            ;;
        
        zswap-files)
            log_info "Architecture: ZSWAP + Swap Files (Recommended)"
            setup_zswap "$ZSWAP_POOL_PERCENT" "$ZSWAP_COMP_ALGO" "$ZRAM_ALLOCATOR"
            create_swap_files "$SWAP_TOTAL_GB" "$SWAP_FILES"
            ;;
        
        files-only)
            log_info "Architecture: Swap Files Only"
            create_swap_files "$SWAP_TOTAL_GB" "$SWAP_FILES"
            ;;
        
        zfs-zvol)
            log_error "ZFS zvol setup requires manual configuration"
            log_info "See SWAP_ARCHITECTURE.md for instructions"
            exit 1
            ;;
        
        zram-zfs)
            log_error "ZRAM + ZFS zvol setup requires manual configuration"
            log_info "See SWAP_ARCHITECTURE.md for instructions"
            exit 1
            ;;
        
        *)
            log_error "Unknown architecture: $SWAP_ARCH"
            exit 1
            ;;
    esac
    
    # Configure kernel parameters
    configure_kernel_parameters
    print_new_values
    
    # Install monitoring tools
    install_monitoring_tools
    
    # Show status
    log_info "=== Swap Status ==="
    swapon --show
    free -h
    
    log_success "Setup completed successfully!"
    log_info ""
    log_info "Next steps:"
    log_info "  - Monitor: /usr/local/bin/swap-monitor.sh"
    log_info "  - Check: swapon --show"
    log_info "  - Tune: edit /etc/sysctl.d/99-swap.conf"
    
    send_telegram "✅ <b>Swap setup completed</b>
Architecture: $SWAP_ARCH
Total: ${SWAP_TOTAL_GB}GB
$(swapon --show)"
}

main "$@"
