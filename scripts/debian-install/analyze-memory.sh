#!/bin/bash
#
# analyze-memory.sh - Pre-installation memory state analysis
#
# Analyzes current memory usage, swap configuration, and provides
# recommendations before running setup-swap.sh
#
# Usage:
#   sudo ./analyze-memory.sh
#

set -euo pipefail

# Colors
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

header() {
    echo -e "${BOLD}${CYAN}=== $* ===${NC}"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        warn "This script should be run as root for full analysis"
        echo ""
    fi
}

print_system_info() {
    header "System Information"
    
    echo "Hostname: $(hostname)"
    echo "Kernel: $(uname -r)"
    echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    echo "Uptime: $(uptime -p)"
    echo "CPU: $(nproc) cores"
    
    if command -v lscpu >/dev/null 2>&1; then
        cpu_model=$(lscpu | grep "Model name:" | cut -d: -f2 | xargs)
        cpu_mhz=$(lscpu | grep "CPU MHz:" | cut -d: -f2 | xargs | head -1)
        echo "CPU Model: $cpu_model"
        echo "CPU Speed: ${cpu_mhz} MHz"
    fi
    
    echo ""
}

print_memory_status() {
    header "Memory Status"
    
    free -h
    echo ""
    
    # Parse memory info
    local mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local mem_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    local mem_used=$((mem_total - mem_avail))
    local mem_used_pct=$((mem_used * 100 / mem_total))
    
    echo "Memory usage: ${mem_used_pct}%"
    
    if [ "$mem_used_pct" -lt 50 ]; then
        success "Low memory pressure"
    elif [ "$mem_used_pct" -lt 80 ]; then
        info "Moderate memory usage"
    else
        warn "High memory pressure detected"
    fi
    
    echo ""
}

print_current_swap() {
    header "Current Swap Configuration"
    
    if [ -f /proc/swaps ]; then
        cat /proc/swaps
    else
        error "Cannot read /proc/swaps"
    fi
    
    echo ""
    
    # Check for ZRAM
    if [ -e /sys/block/zram0/disksize ]; then
        info "ZRAM detected"
        if command -v zramctl >/dev/null 2>&1; then
            zramctl
        fi
        echo ""
    fi
    
    # Check for ZSWAP
    if [ -e /sys/module/zswap/parameters/enabled ]; then
        local enabled=$(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo "N")
        if [ "$enabled" = "Y" ]; then
            info "ZSWAP is enabled"
            if [ -e /sys/module/zswap/parameters/compressor ]; then
                echo "  Compressor: $(cat /sys/module/zswap/parameters/compressor)"
                echo "  Zpool: $(cat /sys/module/zswap/parameters/zpool)"
                echo "  Max pool: $(cat /sys/module/zswap/parameters/max_pool_percent)%"
            fi
        else
            info "ZSWAP is disabled"
        fi
        echo ""
    fi
}

print_kernel_parameters() {
    header "Kernel Parameters"
    
    echo "vm.swappiness = $(sysctl -n vm.swappiness)"
    echo "vm.page-cluster = $(sysctl -n vm.page-cluster)"
    echo "vm.vfs_cache_pressure = $(sysctl -n vm.vfs_cache_pressure)"
    
    echo ""
    
    # Recommendations
    local swappiness=$(sysctl -n vm.swappiness)
    
    if [ "$swappiness" -lt 30 ]; then
        info "Low swappiness - prefers keeping data in RAM"
    elif [ "$swappiness" -gt 80 ]; then
        info "High swappiness - aggressive swapping"
    else
        success "Balanced swappiness setting"
    fi
    
    echo ""
}

print_disk_info() {
    header "Disk Space"
    
    df -h / | tail -1
    echo ""
    
    local disk_avail=$(df / | tail -1 | awk '{print $4}')
    local disk_avail_gb=$((disk_avail / 1024 / 1024))
    
    echo "Available for swap: ~${disk_avail_gb}GB"
    echo ""
}

print_memory_pressure() {
    header "Memory Pressure Indicators"
    
    # Page faults
    if [ -f /proc/vmstat ]; then
        local pgmajfault=$(grep "^pgmajfault " /proc/vmstat | awk '{print $2}')
        echo "Total major page faults: $pgmajfault"
        
        if [ "$pgmajfault" -lt 1000 ]; then
            success "Very low disk I/O from paging"
        elif [ "$pgmajfault" -lt 100000 ]; then
            info "Moderate paging activity"
        else
            warn "High paging activity - system has experienced memory pressure"
        fi
    fi
    
    # PSI
    if [ -f /proc/pressure/memory ]; then
        echo ""
        echo "PSI Memory Pressure:"
        cat /proc/pressure/memory
        
        local full_avg=$(grep "full avg10=" /proc/pressure/memory | sed 's/.*avg10=\([^ ]*\).*/\1/')
        if [ -n "$full_avg" ]; then
            echo ""
            if [ "$(echo "$full_avg == 0.00" | bc 2>/dev/null || echo 0)" -eq 1 ]; then
                success "No current memory stalls"
            else
                warn "System experiencing memory pressure"
            fi
        fi
    fi
    
    # OOM events
    echo ""
    local oom_count=$(dmesg | grep -i "out of memory" | wc -l)
    if [ "$oom_count" -gt 0 ]; then
        error "OOM events detected: $oom_count (check dmesg)"
    else
        success "No OOM events in kernel log"
    fi
    
    echo ""
}

print_processes() {
    header "Top 10 Memory Consumers"
    
    ps aux --sort=-%mem | head -11 | tail -10 | awk '{printf "  %6s  %5s%%  %s\n", $2, $4, $11}'
    
    echo ""
}

print_recommendations() {
    header "Recommendations"
    
    # Get system info
    local ram_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local ram_gb=$((ram_total_kb / 1024 / 1024))
    local disk_avail=$(df / | tail -1 | awk '{print $4}')
    local disk_gb=$((disk_avail / 1024 / 1024))
    local cpu_mhz=$(lscpu | grep "CPU MHz" | awk '{print int($3)}' | head -1)
    cpu_mhz=${cpu_mhz:-2000}
    
    echo "System: ${ram_gb}GB RAM, ${disk_gb}GB disk available"
    echo ""
    
    # Architecture recommendation
    if [ "$ram_gb" -ge 32 ]; then
        success "Recommendation: ZRAM-only (sufficient RAM)"
        echo "  SWAP_ARCH=zram-only"
        echo "  ZRAM_SIZE_PERCENT=50"
    elif [ "$ram_gb" -le 2 ]; then
        success "Recommendation: ZSWAP + Swap Files (low RAM, need compression)"
        echo "  SWAP_ARCH=zswap-files"
        echo "  SWAP_TOTAL_GB=$((ram_gb * 4))"
        echo "  ZSWAP_COMP_ALGO=zstd"
        echo "  ZRAM_ALLOCATOR=zsmalloc"
    elif [ "$cpu_mhz" -lt 2000 ] && [ "$ram_gb" -gt 4 ]; then
        success "Recommendation: Swap Files Only (slow CPU, sufficient RAM)"
        echo "  SWAP_ARCH=files-only"
        echo "  SWAP_TOTAL_GB=$((ram_gb * 2))"
    else
        success "Recommendation: ZSWAP + Swap Files (balanced)"
        echo "  SWAP_ARCH=zswap-files"
        echo "  SWAP_TOTAL_GB=$((ram_gb * 2))"
        echo "  SWAP_FILES=8"
        if [ "$cpu_mhz" -gt 3000 ]; then
            echo "  ZSWAP_COMP_ALGO=lz4  # Fast CPU"
        else
            echo "  ZSWAP_COMP_ALGO=zstd  # Balanced"
        fi
    fi
    
    echo ""
    echo "To apply these settings, run:"
    echo "  sudo ./setup-swap.sh"
    echo ""
}

main() {
    clear
    echo -e "${BOLD}=== Memory State Analysis ===${NC}"
    echo "$(date)"
    echo ""
    
    check_root
    print_system_info
    print_memory_status
    print_current_swap
    print_kernel_parameters
    print_disk_info
    print_memory_pressure
    print_processes
    print_recommendations
    
    echo -e "${BOLD}Analysis complete!${NC}"
    echo ""
}

main "$@"
