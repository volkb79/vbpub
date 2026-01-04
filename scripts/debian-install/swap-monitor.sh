#!/bin/bash
# swap-monitor.sh - Real-time swap and memory monitoring
# 
# This script provides comprehensive swap monitoring with CORRECT metrics.
# NOTE: vmstat 'si' is MISLEADING as it includes RAM-based ZSWAP hits.
# Use pswpin/pswpout from /proc/vmstat for actual disk swap I/O.

set -euo pipefail

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_colored() {
    local color=$1
    shift
    echo -e "${color}$*${NC}"
}

# Function to get value from /proc/vmstat
get_vmstat() {
    grep "^$1" /proc/vmstat | awk '{print $2}'
}

# Function to check if ZSWAP is available and enabled
check_zswap() {
    if [ -f /sys/module/zswap/parameters/enabled ]; then
        [ "$(cat /sys/module/zswap/parameters/enabled)" = "Y" ]
        return $?
    fi
    return 1
}

# Function to check if ZRAM is available
check_zram() {
    [ -d /sys/block/zram0 ]
}

# Main monitoring loop
main() {
    print_colored "$BLUE" "=== SWAP MONITORING DASHBOARD ==="
    print_colored "$BLUE" "Press Ctrl+C to exit"
    echo ""
    print_colored "$YELLOW" "NOTE: This uses CORRECT swap metrics (pswpin/pswpout from /proc/vmstat)"
    print_colored "$YELLOW" "      vmstat 'si' is MISLEADING as it counts RAM-based ZSWAP hits too!"
    echo ""
    
    # Store previous values for rate calculation
    local prev_pswpin=$(get_vmstat pswpin)
    local prev_pswpout=$(get_vmstat pswpout)
    local prev_pgmajfault=$(get_vmstat pgmajfault)
    
    while true; do
        clear
        print_colored "$BLUE" "=== SWAP MONITORING DASHBOARD ==="
        echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        
        # Memory overview
        print_colored "$GREEN" "--- Memory Overview ---"
        free -h
        echo ""
        
        # Swap devices
        print_colored "$GREEN" "--- Swap Devices ---"
        swapon --show
        echo ""
        
        # Calculate rates
        sleep 1
        
        local curr_pswpin=$(get_vmstat pswpin)
        local curr_pswpout=$(get_vmstat pswpout)
        local curr_pgmajfault=$(get_vmstat pgmajfault)
        
        local swapin_rate=$((curr_pswpin - prev_pswpin))
        local swapout_rate=$((curr_pswpout - prev_pswpout))
        local majfault_rate=$((curr_pgmajfault - prev_pgmajfault))
        
        # Swap I/O (Disk-specific, NOT including ZSWAP RAM hits)
        print_colored "$GREEN" "--- Swap I/O (Disk-specific) ---"
        echo "Swap-in rate:  $swapin_rate pages/sec ($((swapin_rate * 4)) KB/sec)"
        echo "Swap-out rate: $swapout_rate pages/sec ($((swapout_rate * 4)) KB/sec)"
        echo "Total swap-in:  $curr_pswpin pages ($((curr_pswpin * 4 / 1024)) MB)"
        echo "Total swap-out: $curr_pswpout pages ($((curr_pswpout * 4 / 1024)) MB)"
        echo ""
        
        # Major page faults (disk I/O required)
        print_colored "$GREEN" "--- Major Page Faults ---"
        echo "Rate: $majfault_rate/sec"
        echo "Total: $curr_pgmajfault"
        echo ""
        
        # ZSWAP stats (if available)
        if check_zswap; then
            print_colored "$GREEN" "--- ZSWAP Statistics ---"
            
            if [ -d /sys/kernel/debug/zswap ]; then
                local stored=$(cat /sys/kernel/debug/zswap/stored_pages 2>/dev/null || echo 0)
                local written=$(cat /sys/kernel/debug/zswap/written_back_pages 2>/dev/null || echo 0)
                local pool=$(cat /sys/kernel/debug/zswap/pool_total_size 2>/dev/null || echo 0)
                local pool_limit=$(cat /sys/kernel/debug/zswap/pool_limit_hit 2>/dev/null || echo 0)
                
                local pool_mb=$(awk "BEGIN {printf \"%.2f\", $pool / 1048576}")
                
                echo "Pool size: ${pool_mb} MB"
                echo "Stored pages: $stored"
                echo "Written back to disk: $written"
                echo "Pool limit hits: $pool_limit"
                
                if [ "$stored" -gt 0 ]; then
                    local ratio=$(awk "BEGIN {printf \"%.2f\", $written * 100 / $stored}" 2>/dev/null || echo "0")
                    echo "Writeback ratio: ${ratio}%"
                    
                    # Check if bc is available for comparison
                    if command -v bc &>/dev/null; then
                        if (( $(echo "$ratio > 30" | bc -l 2>/dev/null || echo 0) )); then
                            print_colored "$RED" "⚠️  WARNING: Writeback ratio > 30%, consider increasing max_pool_percent"
                        fi
                    elif (( $(awk "BEGIN {print ($ratio > 30 ? 1 : 0)}") )); then
                        print_colored "$RED" "⚠️  WARNING: Writeback ratio > 30%, consider increasing max_pool_percent"
                    fi
                fi
            else
                echo "Enable debugfs for detailed stats: mount -t debugfs none /sys/kernel/debug"
            fi
            
            echo ""
            echo "Settings:"
            echo "  Enabled: $(cat /sys/module/zswap/parameters/enabled)"
            echo "  Compressor: $(cat /sys/module/zswap/parameters/compressor)"
            echo "  Zpool: $(cat /sys/module/zswap/parameters/zpool)"
            echo "  Max pool: $(cat /sys/module/zswap/parameters/max_pool_percent)%"
            echo ""
        fi
        
        # ZRAM stats (if available)
        if check_zram; then
            print_colored "$GREEN" "--- ZRAM Statistics ---"
            
            if [ -f /sys/block/zram0/mm_stat ]; then
                read -r orig_size compr_size mem_used mem_limit mem_max same_pages pages_compacted huge_pages _ < /sys/block/zram0/mm_stat
                
                local orig_mb=$(awk "BEGIN {printf \"%.2f\", $orig_size / 1048576}")
                local compr_mb=$(awk "BEGIN {printf \"%.2f\", $compr_size / 1048576}")
                local mem_mb=$(awk "BEGIN {printf \"%.2f\", $mem_used / 1048576}")
                
                echo "Original data: ${orig_mb} MB"
                echo "Compressed data: ${compr_mb} MB"
                echo "Memory used: ${mem_mb} MB"
                echo "Zero pages (not stored): $same_pages"
                echo "Incompressible pages: $huge_pages"
                
                if [ "$mem_used" -gt 0 ]; then
                    local comp_ratio=$(awk "BEGIN {printf \"%.2f\", $orig_size / $mem_used}")
                    echo "Compression ratio: ${comp_ratio}:1"
                fi
                
                # Check for writeback support
                if [ -f /sys/block/zram0/backing_dev ]; then
                    local backing=$(cat /sys/block/zram0/backing_dev 2>/dev/null || echo "none")
                    echo "Backing device: $backing"
                    
                    if [ -f /sys/block/zram0/bd_stat ]; then
                        read -r bd_count bd_reads bd_writes < /sys/block/zram0/bd_stat
                        echo "Writeback: $bd_writes writes, $bd_reads reads"
                    fi
                fi
            fi
            echo ""
        fi
        
        # Memory Pressure (PSI)
        if [ -f /proc/pressure/memory ]; then
            print_colored "$GREEN" "--- Memory Pressure (PSI) ---"
            cat /proc/pressure/memory
            
            # Parse and warn
            local full_avg10=$(grep "^full" /proc/pressure/memory | awk '{print $2}' | cut -d= -f2)
            if (( $(echo "$full_avg10 > 5" | bc -l 2>/dev/null || echo 0) )); then
                print_colored "$RED" "⚠️  SEVERE MEMORY PRESSURE: full avg10 > 5"
            fi
            echo ""
        fi
        
        # KSM stats (if available)
        if [ -f /sys/kernel/mm/ksm/pages_sharing ]; then
            print_colored "$GREEN" "--- KSM (Kernel Same-page Merging) ---"
            local pages_shared=$(cat /sys/kernel/mm/ksm/pages_shared)
            local pages_sharing=$(cat /sys/kernel/mm/ksm/pages_sharing)
            local ksm_run=$(cat /sys/kernel/mm/ksm/run)
            
            if [ "$ksm_run" -eq 1 ]; then
                local saved_kb=$(( (pages_sharing - pages_shared) * 4 ))
                local saved_mb=$(awk "BEGIN {printf \"%.2f\", $saved_kb / 1024}")
                
                echo "Status: Running"
                echo "Pages shared: $pages_shared"
                echo "Pages sharing: $pages_sharing"
                echo "Memory saved: ${saved_mb} MB"
            else
                echo "Status: Disabled"
            fi
            echo ""
        fi
        
        # Status interpretation
        print_colored "$GREEN" "--- Status Assessment ---"
        
        if [ "$majfault_rate" -gt 100 ]; then
            print_colored "$RED" "⚠️  HIGH DISK I/O: Major faults > 100/sec (working set exceeds RAM)"
        elif [ "$majfault_rate" -gt 20 ]; then
            print_colored "$YELLOW" "⚠️  MODERATE DISK I/O: Major faults > 20/sec"
        else
            print_colored "$GREEN" "✅ Disk I/O: Normal (major faults < 20/sec)"
        fi
        
        if [ "$swapin_rate" -gt 100 ] || [ "$swapout_rate" -gt 100 ]; then
            print_colored "$RED" "⚠️  HIGH SWAP ACTIVITY: > 100 pages/sec"
        elif [ "$swapin_rate" -gt 20 ] || [ "$swapout_rate" -gt 20 ]; then
            print_colored "$YELLOW" "⚠️  MODERATE SWAP ACTIVITY: > 20 pages/sec"
        else
            print_colored "$GREEN" "✅ Swap activity: Normal"
        fi
        
        echo ""
        print_colored "$BLUE" "Refreshing in 4 seconds... (Ctrl+C to exit)"
        
        # Update previous values
        prev_pswpin=$curr_pswpin
        prev_pswpout=$curr_pswpout
        prev_pgmajfault=$curr_pgmajfault
        
        sleep 4
    done
}

# Run main function
main "$@"
