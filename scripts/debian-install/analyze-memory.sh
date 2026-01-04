#!/bin/bash
# analyze-memory.sh - Basic memory analysis
#
# Provides a quick overview of memory usage and swap configuration

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_section() {
    echo ""
    echo -e "${BLUE}=== $1 ===${NC}"
    echo ""
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_ok() {
    echo -e "${GREEN}✅ $1${NC}"
}

main() {
    echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     Memory and Swap Analysis Report          ║${NC}"
    echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
    echo ""
    echo "Generated: $(date)"
    
    # System information
    print_section "System Information"
    echo "Hostname: $(hostname)"
    echo "Kernel: $(uname -r)"
    echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    
    # Memory overview
    print_section "Memory Overview"
    free -h
    
    # Get memory values for calculations
    local total_mem=$(free -m | grep "^Mem:" | awk '{print $2}')
    local used_mem=$(free -m | grep "^Mem:" | awk '{print $3}')
    local available_mem=$(free -m | grep "^Mem:" | awk '{print $7}')
    local swap_total=$(free -m | grep "^Swap:" | awk '{print $2}')
    local swap_used=$(free -m | grep "^Swap:" | awk '{print $3}')
    
    # Calculate percentages
    local mem_used_pct=$(awk "BEGIN {printf \"%.1f\", $used_mem * 100 / $total_mem}")
    local mem_available_pct=$(awk "BEGIN {printf \"%.1f\", $available_mem * 100 / $total_mem}")
    
    echo ""
    echo "Memory usage: ${mem_used_pct}%"
    echo "Memory available: ${mem_available_pct}%"
    
    # Memory pressure assessment
    if (( $(echo "$mem_available_pct < 10" | bc -l) )); then
        print_error "Critical: Less than 10% memory available"
    elif (( $(echo "$mem_available_pct < 20" | bc -l) )); then
        print_warning "Low memory: Less than 20% available"
    else
        print_ok "Memory availability is healthy"
    fi
    
    # Swap configuration
    print_section "Swap Configuration"
    
    if [ "$swap_total" -eq 0 ]; then
        print_warning "No swap configured"
    else
        echo "Total swap: ${swap_total} MB"
        echo "Used swap: ${swap_used} MB"
        
        if [ "$swap_used" -gt 0 ]; then
            local swap_used_pct=$(awk "BEGIN {printf \"%.1f\", $swap_used * 100 / $swap_total}")
            echo "Swap usage: ${swap_used_pct}%"
        fi
        
        echo ""
        echo "Swap devices:"
        swapon --show
    fi
    
    # Swappiness
    local swappiness=$(cat /proc/sys/vm/swappiness)
    echo ""
    echo "vm.swappiness: $swappiness"
    
    if [ "$swappiness" -lt 30 ]; then
        echo "  → Conservative (prefers RAM over swap)"
    elif [ "$swappiness" -lt 70 ]; then
        echo "  → Balanced"
    else
        echo "  → Aggressive (prefers swap to free RAM)"
    fi
    
    # Page cluster
    local page_cluster=$(cat /proc/sys/vm/page-cluster)
    local read_ahead_kb=$((2 ** page_cluster * 4))
    echo ""
    echo "vm.page-cluster: $page_cluster (reads ${read_ahead_kb} KB per swap-in)"
    
    # ZSWAP
    print_section "ZSWAP Configuration"
    
    if [ -f /sys/module/zswap/parameters/enabled ]; then
        local zswap_enabled=$(cat /sys/module/zswap/parameters/enabled)
        
        if [ "$zswap_enabled" = "Y" ]; then
            print_ok "ZSWAP is enabled"
            echo ""
            echo "Compressor: $(cat /sys/module/zswap/parameters/compressor)"
            echo "Zpool: $(cat /sys/module/zswap/parameters/zpool)"
            echo "Max pool: $(cat /sys/module/zswap/parameters/max_pool_percent)%"
            
            if [ -d /sys/kernel/debug/zswap ]; then
                echo ""
                local stored=$(cat /sys/kernel/debug/zswap/stored_pages 2>/dev/null || echo 0)
                local pool=$(cat /sys/kernel/debug/zswap/pool_total_size 2>/dev/null || echo 0)
                local pool_mb=$(awk "BEGIN {printf \"%.2f\", $pool / 1048576}")
                
                echo "Current pool size: ${pool_mb} MB"
                echo "Pages stored: $stored"
            fi
        else
            print_warning "ZSWAP is available but disabled"
        fi
    else
        echo "ZSWAP not available (module not loaded)"
    fi
    
    # ZRAM
    print_section "ZRAM Configuration"
    
    if [ -d /sys/block/zram0 ]; then
        print_ok "ZRAM device found"
        echo ""
        
        if [ -f /sys/block/zram0/mm_stat ]; then
            read -r orig_size compr_size mem_used mem_limit mem_max same_pages _ < /sys/block/zram0/mm_stat
            
            local orig_mb=$(awk "BEGIN {printf \"%.2f\", $orig_size / 1048576}")
            local mem_mb=$(awk "BEGIN {printf \"%.2f\", $mem_used / 1048576}")
            
            echo "Algorithm: $(cat /sys/block/zram0/comp_algorithm | grep -o '\[.*\]' | tr -d '[]')"
            echo "Disk size: $(cat /sys/block/zram0/disksize | awk '{printf "%.2f GB", $1/1073741824}')"
            echo "Data stored: ${orig_mb} MB"
            echo "Memory used: ${mem_mb} MB"
            
            if [ "$mem_used" -gt 0 ]; then
                local comp_ratio=$(awk "BEGIN {printf \"%.2f\", $orig_size / $mem_used}")
                echo "Compression ratio: ${comp_ratio}:1"
            fi
        fi
    else
        echo "ZRAM not configured"
    fi
    
    # KSM
    print_section "KSM (Kernel Same-page Merging)"
    
    if [ -f /sys/kernel/mm/ksm/pages_sharing ]; then
        local ksm_run=$(cat /sys/kernel/mm/ksm/run)
        
        if [ "$ksm_run" -eq 1 ]; then
            print_ok "KSM is running"
            
            local pages_shared=$(cat /sys/kernel/mm/ksm/pages_shared)
            local pages_sharing=$(cat /sys/kernel/mm/ksm/pages_sharing)
            
            if [ "$pages_sharing" -gt 0 ]; then
                local saved_kb=$(( (pages_sharing - pages_shared) * 4 ))
                local saved_mb=$(awk "BEGIN {printf \"%.2f\", $saved_kb / 1024}")
                
                echo ""
                echo "Pages shared: $pages_shared"
                echo "Pages sharing: $pages_sharing"
                echo "Memory saved: ${saved_mb} MB"
            else
                echo ""
                echo "No pages merged yet"
            fi
        else
            echo "KSM is available but not running"
        fi
    else
        echo "KSM not available"
    fi
    
    # Swap activity
    print_section "Swap Activity"
    
    local pswpin=$(grep pswpin /proc/vmstat | awk '{print $2}')
    local pswpout=$(grep pswpout /proc/vmstat | awk '{print $2}')
    local pgmajfault=$(grep pgmajfault /proc/vmstat | awk '{print $2}')
    
    echo "Swap-ins (from disk): $pswpin pages ($((pswpin * 4 / 1024)) MB)"
    echo "Swap-outs (to disk): $pswpout pages ($((pswpout * 4 / 1024)) MB)"
    echo "Major page faults: $pgmajfault"
    
    if [ "$pswpin" -gt 10000 ] || [ "$pswpout" -gt 10000 ]; then
        echo ""
        print_warning "Significant swap activity detected"
        echo "Run 'swap-monitor.sh' for real-time monitoring"
    fi
    
    # Memory pressure
    if [ -f /proc/pressure/memory ]; then
        print_section "Memory Pressure (PSI)"
        cat /proc/pressure/memory
        
        local full_avg10=$(grep "^full" /proc/pressure/memory | awk '{print $2}' | cut -d= -f2)
        
        echo ""
        if (( $(echo "$full_avg10 > 5" | bc -l 2>/dev/null || echo 0) )); then
            print_error "Severe memory pressure detected (full avg10 > 5)"
        elif (( $(echo "$full_avg10 > 1" | bc -l 2>/dev/null || echo 0) )); then
            print_warning "Moderate memory pressure (full avg10 > 1)"
        else
            print_ok "No significant memory pressure"
        fi
    fi
    
    # Recommendations
    print_section "Recommendations"
    
    if [ "$swap_total" -eq 0 ]; then
        echo "• Configure swap for better memory management"
        echo "  Run: sudo ./setup-swap.sh"
    fi
    
    if [ -f /sys/module/zswap/parameters/enabled ]; then
        local zswap_enabled=$(cat /sys/module/zswap/parameters/enabled)
        if [ "$zswap_enabled" = "N" ]; then
            echo "• Consider enabling ZSWAP for compressed swap cache"
            echo "  Run: sudo ./setup-swap.sh --architecture zswap"
        fi
    fi
    
    if (( $(echo "$mem_available_pct < 20" | bc -l) )); then
        echo "• Low memory available - consider:"
        echo "  - Increasing swap size"
        echo "  - Enabling ZSWAP/ZRAM"
        echo "  - Reducing memory usage"
        echo "  - Adding more RAM"
    fi
    
    if [ "$pswpin" -gt 100000 ] || [ "$pswpout" -gt 100000 ]; then
        echo "• High swap activity - consider:"
        echo "  - Increasing ZSWAP pool size"
        echo "  - Adding ZRAM for hot data"
        echo "  - Optimizing application memory usage"
        echo "  - Adding more RAM"
    fi
    
    echo ""
    print_section "Additional Tools"
    echo "• Real-time monitoring: ./swap-monitor.sh"
    echo "• Comprehensive analysis: ./analyze-running-system.sh"
    echo "• Performance benchmarks: ./benchmark.py"
    echo ""
}

main "$@"
