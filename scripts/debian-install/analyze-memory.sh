#!/bin/bash
# Pre-installation memory and system analysis
# Provides recommendations for swap configuration

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_section() { echo -e "${BLUE}=== $* ===${NC}"; }

print_banner() {
    cat <<'EOF'
╔═══════════════════════════════════════════════════════╗
║   Memory and System Analysis                          ║
║   Pre-installation recommendations                    ║
╚═══════════════════════════════════════════════════════╝
EOF
}

# Get system info
get_system_info() {
    RAM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    RAM_GB=$((RAM_TOTAL_KB / 1024 / 1024))
    
    DISK_TOTAL_KB=$(df -k / | tail -1 | awk '{print $2}')
    DISK_AVAIL_KB=$(df -k / | tail -1 | awk '{print $4}')
    DISK_TOTAL_GB=$((DISK_TOTAL_KB / 1024 / 1024))
    DISK_AVAIL_GB=$((DISK_AVAIL_KB / 1024 / 1024))
    
    CPU_CORES=$(nproc)
    
    # Detect storage type
    ROOT_DISK=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's|/dev/||')
    if [ -f "/sys/block/${ROOT_DISK}/queue/rotational" ]; then
        if [ "$(cat /sys/block/${ROOT_DISK}/queue/rotational)" = "0" ]; then
            STORAGE_TYPE="SSD"
        else
            STORAGE_TYPE="HDD"
        fi
    else
        STORAGE_TYPE="Unknown"
    fi
}

# Analyze current memory usage
analyze_memory() {
    log_section "Current Memory Status"
    
    echo ""
    free -h
    echo ""
    
    # Calculate percentages
    MEM_USED_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_AVAILABLE_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    MEM_USED_PERCENT=$(( (MEM_USED_KB - MEM_AVAILABLE_KB) * 100 / MEM_USED_KB ))
    
    log_info "Memory utilization: ${MEM_USED_PERCENT}%"
    
    # Check for memory pressure
    if [ -f /proc/pressure/memory ]; then
        echo ""
        log_info "Memory Pressure (PSI):"
        cat /proc/pressure/memory | while read line; do
            echo "  $line"
        done
    fi
}

# Analyze existing swap
analyze_swap() {
    log_section "Existing Swap Configuration"
    
    echo ""
    if swapon --show | grep -q "/"; then
        swapon --show
        echo ""
        
        # Calculate swap usage
        SWAP_TOTAL_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
        SWAP_FREE_KB=$(grep SwapFree /proc/meminfo | awk '{print $2}')
        SWAP_USED_KB=$((SWAP_TOTAL_KB - SWAP_FREE_KB))
        
        if [ "$SWAP_TOTAL_KB" -gt 0 ]; then
            SWAP_USED_PERCENT=$((SWAP_USED_KB * 100 / SWAP_TOTAL_KB))
            log_info "Swap utilization: ${SWAP_USED_PERCENT}%"
        fi
        
        # Check for ZRAM
        if [ -b /dev/zram0 ]; then
            echo ""
            log_info "ZRAM detected:"
            if [ -f /sys/block/zram0/mm_stat ]; then
                echo "  Statistics:"
                cat /sys/block/zram0/mm_stat | awk '{
                    printf "    Original: %.2f GB\n", $1/1024/1024/1024
                    printf "    Compressed: %.2f GB\n", $2/1024/1024/1024
                    printf "    Ratio: %.2fx\n", $1/$2
                }'
            fi
        fi
        
        # Check for ZSWAP
        if [ -d /sys/module/zswap ] && [ "$(cat /sys/module/zswap/parameters/enabled 2>/dev/null)" = "Y" ]; then
            echo ""
            log_info "ZSWAP enabled:"
            echo "  Pool: $(cat /sys/module/zswap/parameters/max_pool_percent 2>/dev/null)%"
            echo "  Compressor: $(cat /sys/module/zswap/parameters/compressor 2>/dev/null)"
        fi
    else
        log_warn "No swap configured"
    fi
}

# Analyze disk space
analyze_disk() {
    log_section "Disk Space Analysis"
    
    echo ""
    df -h /
    echo ""
    
    log_info "Root filesystem:"
    log_info "  Total: ${DISK_TOTAL_GB}GB"
    log_info "  Available: ${DISK_AVAIL_GB}GB"
    log_info "  Storage type: $STORAGE_TYPE"
    
    # Check for ZFS
    if command -v zfs >/dev/null 2>&1; then
        echo ""
        log_info "ZFS pools:"
        zpool list 2>/dev/null || echo "  No ZFS pools"
    fi
}

# Check memory pressure indicators
check_pressure_indicators() {
    log_section "Memory Pressure Indicators"
    
    echo ""
    
    # Page faults
    PGMAJFAULT=$(grep pgmajfault /proc/vmstat | awk '{print $2}')
    log_info "Major page faults (since boot): $PGMAJFAULT"
    
    # OOM kills
    OOM_KILLS=$(dmesg | grep -i "out of memory" | wc -l)
    if [ "$OOM_KILLS" -gt 0 ]; then
        log_warn "OOM (Out of Memory) events detected: $OOM_KILLS"
    else
        log_info "No OOM events detected"
    fi
    
    # Check current kernel parameters
    echo ""
    log_info "Current kernel parameters:"
    echo "  vm.swappiness = $(sysctl -n vm.swappiness 2>/dev/null || echo 'not set')"
    echo "  vm.page-cluster = $(sysctl -n vm.page-cluster 2>/dev/null || echo 'not set')"
    echo "  vm.vfs_cache_pressure = $(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo 'not set')"
}

# Provide recommendations
provide_recommendations() {
    log_section "Recommendations"
    
    echo ""
    
    # Architecture recommendation
    if [ "$DISK_AVAIL_GB" -lt 30 ]; then
        log_info "Limited disk space (<30GB):"
        echo "  → Recommended: Architecture 1 (ZRAM Only)"
        echo "  → Command: SWAP_ARCH=1 ZRAM_SIZE_GB=4 ./setup-swap.sh"
    elif [ "$RAM_GB" -le 2 ]; then
        log_info "Low RAM system (${RAM_GB}GB):"
        echo "  → Recommended: Architecture 3 (ZSWAP + Swap Files)"
        echo "  → Use zstd compression for better ratio"
        echo "  → Command: SWAP_ARCH=3 ZSWAP_COMPRESSOR=zstd SWAP_TOTAL_GB=4 ./setup-swap.sh"
    else
        log_info "Standard system (${RAM_GB}GB RAM, ${DISK_AVAIL_GB}GB disk):"
        echo "  → Recommended: Architecture 3 (ZSWAP + Swap Files)"
        echo "  → Command: SWAP_ARCH=3 ./setup-swap.sh"
    fi
    
    echo ""
    
    # Swap size recommendation
    if [ "$RAM_GB" -le 2 ]; then
        RECOMMENDED_SWAP=$((RAM_GB * 2))
    elif [ "$RAM_GB" -le 4 ]; then
        RECOMMENDED_SWAP=$((RAM_GB * 3 / 2))
    elif [ "$RAM_GB" -le 8 ]; then
        RECOMMENDED_SWAP=$RAM_GB
    elif [ "$RAM_GB" -le 16 ]; then
        RECOMMENDED_SWAP=$((RAM_GB / 2))
    else
        RECOMMENDED_SWAP=8
    fi
    
    log_info "Recommended swap size: ${RECOMMENDED_SWAP}GB"
    log_info "Recommended swap files: 8 (for concurrency)"
    
    echo ""
    
    # Storage-specific recommendations
    if [ "$STORAGE_TYPE" = "SSD" ]; then
        log_info "SSD detected:"
        echo "  → Use vm.page-cluster=3 (32KB I/O)"
        echo "  → Multiple swap files benefit from concurrent I/O"
    elif [ "$STORAGE_TYPE" = "HDD" ]; then
        log_info "HDD detected:"
        echo "  → Use vm.page-cluster=4 (64KB I/O)"
        echo "  → Larger I/O size better for sequential access"
    fi
    
    echo ""
    
    # ZFS recommendation
    if command -v zfs >/dev/null 2>&1; then
        log_info "ZFS available:"
        echo "  → Consider Architecture 5 (ZFS zvol)"
        echo "  → Integrated compression with ZFS ecosystem"
        echo "  → Command: SWAP_ARCH=5 ZFS_POOL=tank ./setup-swap.sh"
    fi
    
    echo ""
    
    # Memory pressure warning
    if [ "$MEM_USED_PERCENT" -gt 80 ]; then
        log_warn "High memory usage (${MEM_USED_PERCENT}%)!"
        echo "  → Consider adding more RAM"
        echo "  → Use aggressive swap configuration"
        echo "  → Monitor with: ./swap-monitor.sh"
    fi
    
    # Disk space warning
    if [ "$DISK_AVAIL_GB" -lt 10 ]; then
        log_warn "Very low disk space (${DISK_AVAIL_GB}GB)!"
        echo "  → Use ZRAM only (no disk swap)"
        echo "  → Or allocate minimal swap"
    fi
}

# Summary
print_summary() {
    log_section "System Summary"
    
    echo ""
    echo "Hardware:"
    echo "  RAM: ${RAM_GB}GB"
    echo "  CPU Cores: $CPU_CORES"
    echo "  Disk: ${DISK_TOTAL_GB}GB total, ${DISK_AVAIL_GB}GB available"
    echo "  Storage: $STORAGE_TYPE"
    
    echo ""
    echo "Current State:"
    if swapon --show | grep -q "/"; then
        SWAP_TOTAL_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
        SWAP_GB=$((SWAP_TOTAL_KB / 1024 / 1024))
        echo "  Swap: ${SWAP_GB}GB configured"
    else
        echo "  Swap: None configured"
    fi
    echo "  Memory usage: ${MEM_USED_PERCENT}%"
    
    echo ""
}

# Main
main() {
    print_banner
    
    get_system_info
    
    analyze_memory
    echo ""
    
    analyze_swap
    echo ""
    
    analyze_disk
    echo ""
    
    check_pressure_indicators
    echo ""
    
    provide_recommendations
    echo ""
    
    print_summary
    
    log_info "Analysis complete!"
    log_info ""
    log_info "To proceed with setup, run: ./setup-swap.sh"
}

main "$@"
