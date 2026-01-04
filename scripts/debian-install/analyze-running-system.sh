#!/bin/bash
# analyze-running-system.sh - Comprehensive system analysis
#
# This script performs detailed analysis of:
# - Memory state and usage patterns
# - KSM effectiveness testing (temporary enable, measure, report)
# - ZRAM/ZSWAP status and compression ratios
# - Swap activity recording (swap-specific counters only)
# - DAMON integration (if available)
# - Process memory analysis (RSS, swap usage, cold ratio)
# - Automated recommendations

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Output file
REPORT_FILE="/tmp/system-analysis-$(date +%Y%m%d-%H%M%S).txt"

print_section() {
    local msg="=== $1 ==="
    echo ""
    echo -e "${BLUE}${msg}${NC}"
    echo "$msg" >> "$REPORT_FILE"
    echo ""
}

print_colored() {
    local color=$1
    shift
    echo -e "${color}$*${NC}"
    echo "$*" >> "$REPORT_FILE"
}

log_output() {
    echo "$1" | tee -a "$REPORT_FILE"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_colored "$YELLOW" "Note: Some features require root access"
        print_colored "$YELLOW" "      Run with sudo for complete analysis"
        echo ""
    fi
}

analyze_memory_state() {
    print_section "Memory State Analysis"
    
    # Overall memory
    log_output "$(free -h)"
    echo "" | tee -a "$REPORT_FILE"
    
    # Parse memory values
    local total_mem=$(free -m | grep "^Mem:" | awk '{print $2}')
    local used_mem=$(free -m | grep "^Mem:" | awk '{print $3}')
    local available_mem=$(free -m | grep "^Mem:" | awk '{print $7}')
    local swap_total=$(free -m | grep "^Swap:" | awk '{print $2}')
    local swap_used=$(free -m | grep "^Swap:" | awk '{print $3}')
    
    # Calculations
    local mem_used_pct=$(awk "BEGIN {printf \"%.1f\", $used_mem * 100 / $total_mem}")
    local mem_available_pct=$(awk "BEGIN {printf \"%.1f\", $available_mem * 100 / $total_mem}")
    
    log_output "Memory usage: ${mem_used_pct}%"
    log_output "Memory available: ${mem_available_pct}%"
    
    if [ "$swap_total" -gt 0 ] && [ "$swap_used" -gt 0 ]; then
        local swap_used_pct=$(awk "BEGIN {printf \"%.1f\", $swap_used * 100 / $swap_total}")
        log_output "Swap usage: ${swap_used_pct}%"
    fi
    
    # Assessment
    echo "" | tee -a "$REPORT_FILE"
    if (( $(echo "$mem_available_pct < 10" | bc -l) )); then
        print_colored "$RED" "❌ CRITICAL: Less than 10% memory available"
    elif (( $(echo "$mem_available_pct < 20" | bc -l) )); then
        print_colored "$YELLOW" "⚠️  WARNING: Less than 20% memory available"
    else
        print_colored "$GREEN" "✅ Memory availability is healthy"
    fi
}

analyze_swap_config() {
    print_section "Swap Configuration"
    
    # Swap devices
    if swapon --show &>/dev/null; then
        log_output "$(swapon --show)"
    else
        log_output "No swap devices configured"
    fi
    
    echo "" | tee -a "$REPORT_FILE"
    
    # Kernel parameters
    log_output "vm.swappiness: $(cat /proc/sys/vm/swappiness)"
    log_output "vm.page-cluster: $(cat /proc/sys/vm/page-cluster) ($(( 2 ** $(cat /proc/sys/vm/page-cluster) * 4 )) KB read-ahead)"
    log_output "vm.vfs_cache_pressure: $(cat /proc/sys/vm/vfs_cache_pressure)"
}

analyze_zswap() {
    print_section "ZSWAP Analysis"
    
    if [ ! -f /sys/module/zswap/parameters/enabled ]; then
        log_output "ZSWAP module not available"
        return
    fi
    
    local enabled=$(cat /sys/module/zswap/parameters/enabled)
    
    if [ "$enabled" = "N" ]; then
        print_colored "$YELLOW" "ZSWAP is available but disabled"
        return
    fi
    
    print_colored "$GREEN" "✅ ZSWAP is enabled"
    echo "" | tee -a "$REPORT_FILE"
    
    # Configuration
    log_output "Configuration:"
    log_output "  Compressor: $(cat /sys/module/zswap/parameters/compressor)"
    log_output "  Zpool: $(cat /sys/module/zswap/parameters/zpool)"
    log_output "  Max pool: $(cat /sys/module/zswap/parameters/max_pool_percent)%"
    log_output "  Accept threshold: $(cat /sys/module/zswap/parameters/accept_threshold_percent)%"
    
    # Statistics
    if [ -d /sys/kernel/debug/zswap ]; then
        echo "" | tee -a "$REPORT_FILE"
        log_output "Statistics:"
        
        local stored=$(cat /sys/kernel/debug/zswap/stored_pages)
        local written=$(cat /sys/kernel/debug/zswap/written_back_pages)
        local pool=$(cat /sys/kernel/debug/zswap/pool_total_size)
        local pool_limit=$(cat /sys/kernel/debug/zswap/pool_limit_hit)
        local reject_compress=$(cat /sys/kernel/debug/zswap/reject_compress_poor 2>/dev/null || echo 0)
        
        local pool_mb=$(awk "BEGIN {printf \"%.2f\", $pool / 1048576}")
        local stored_mb=$(awk "BEGIN {printf \"%.2f\", $stored * 4 / 1024}")
        
        log_output "  Pool size: ${pool_mb} MB"
        log_output "  Pages stored: $stored (${stored_mb} MB uncompressed)"
        log_output "  Written back to disk: $written"
        log_output "  Pool limit hits: $pool_limit"
        log_output "  Rejected (poor compression): $reject_compress"
        
        # Compression ratio
        if [ "$pool" -gt 0 ] && [ "$stored" -gt 0 ]; then
            local uncompressed=$(( stored * 4096 ))
            local comp_ratio=$(awk "BEGIN {printf \"%.2f\", $uncompressed / $pool}")
            log_output "  Compression ratio: ${comp_ratio}:1"
        fi
        
        # Writeback ratio
        if [ "$stored" -gt 0 ]; then
            local wb_ratio=$(awk "BEGIN {printf \"%.2f\", $written * 100 / $stored}")
            log_output "  Writeback ratio: ${wb_ratio}%"
            
            echo "" | tee -a "$REPORT_FILE"
            if (( $(echo "$wb_ratio > 30" | bc -l) )); then
                print_colored "$RED" "❌ Writeback ratio > 30%: Pool too small"
                log_output "Recommendation: Increase max_pool_percent"
            elif (( $(echo "$wb_ratio > 10" | bc -l) )); then
                print_colored "$YELLOW" "⚠️  Writeback ratio > 10%: Consider increasing pool"
            else
                print_colored "$GREEN" "✅ Writeback ratio is healthy"
            fi
        fi
    else
        echo "" | tee -a "$REPORT_FILE"
        log_output "Detailed statistics not available (debugfs not mounted)"
        log_output "To enable: mount -t debugfs none /sys/kernel/debug"
    fi
}

analyze_zram() {
    print_section "ZRAM Analysis"
    
    if [ ! -d /sys/block/zram0 ]; then
        log_output "ZRAM not configured"
        return
    fi
    
    print_colored "$GREEN" "✅ ZRAM device found"
    echo "" | tee -a "$REPORT_FILE"
    
    # Configuration
    local algorithm=$(cat /sys/block/zram0/comp_algorithm | grep -o '\[.*\]' | tr -d '[]')
    local disksize=$(cat /sys/block/zram0/disksize)
    local disksize_gb=$(awk "BEGIN {printf \"%.2f\", $disksize / 1073741824}")
    
    log_output "Configuration:"
    log_output "  Algorithm: $algorithm"
    log_output "  Disk size: ${disksize_gb} GB"
    
    # Check for writeback support
    if [ -f /sys/block/zram0/backing_dev ]; then
        local backing=$(cat /sys/block/zram0/backing_dev 2>/dev/null || echo "none")
        log_output "  Backing device: $backing"
    fi
    
    # Statistics
    if [ -f /sys/block/zram0/mm_stat ]; then
        echo "" | tee -a "$REPORT_FILE"
        log_output "Statistics:"
        
        read -r orig_size compr_size mem_used mem_limit mem_max same_pages pages_compacted huge_pages _ < /sys/block/zram0/mm_stat
        
        local orig_mb=$(awk "BEGIN {printf \"%.2f\", $orig_size / 1048576}")
        local compr_mb=$(awk "BEGIN {printf \"%.2f\", $compr_size / 1048576}")
        local mem_mb=$(awk "BEGIN {printf \"%.2f\", $mem_used / 1048576}")
        local same_mb=$(awk "BEGIN {printf \"%.2f\", $same_pages * 4 / 1024}")
        
        log_output "  Original data: ${orig_mb} MB"
        log_output "  Compressed data: ${compr_mb} MB"
        log_output "  Memory used: ${mem_mb} MB"
        log_output "  Zero pages (not stored): $same_pages (${same_mb} MB)"
        log_output "  Incompressible pages: $huge_pages"
        
        if [ "$mem_used" -gt 0 ]; then
            local comp_ratio=$(awk "BEGIN {printf \"%.2f\", $orig_size / $mem_used}")
            log_output "  Compression ratio: ${comp_ratio}:1"
        fi
        
        # Writeback stats
        if [ -f /sys/block/zram0/bd_stat ]; then
            read -r bd_count bd_reads bd_writes < /sys/block/zram0/bd_stat
            echo "" | tee -a "$REPORT_FILE"
            log_output "Writeback statistics:"
            log_output "  Pages written to backing: $bd_writes"
            log_output "  Pages read from backing: $bd_reads"
        fi
    fi
}

analyze_ksm() {
    print_section "KSM (Kernel Same-page Merging) Analysis"
    
    if [ ! -f /sys/kernel/mm/ksm/pages_sharing ]; then
        log_output "KSM not available"
        return
    fi
    
    local ksm_run=$(cat /sys/kernel/mm/ksm/run)
    
    if [ "$ksm_run" -eq 1 ]; then
        print_colored "$GREEN" "✅ KSM is running"
        echo "" | tee -a "$REPORT_FILE"
        
        local pages_shared=$(cat /sys/kernel/mm/ksm/pages_shared)
        local pages_sharing=$(cat /sys/kernel/mm/ksm/pages_sharing)
        local pages_unshared=$(cat /sys/kernel/mm/ksm/pages_unshared)
        local pages_volatile=$(cat /sys/kernel/mm/ksm/pages_volatile)
        local full_scans=$(cat /sys/kernel/mm/ksm/full_scans)
        
        log_output "Current statistics:"
        log_output "  Pages shared: $pages_shared"
        log_output "  Pages sharing: $pages_sharing"
        log_output "  Pages unshared: $pages_unshared"
        log_output "  Pages volatile: $pages_volatile"
        log_output "  Full scans: $full_scans"
        
        if [ "$pages_sharing" -gt 0 ]; then
            local saved_kb=$(( (pages_sharing - pages_shared) * 4 ))
            local saved_mb=$(awk "BEGIN {printf \"%.2f\", $saved_kb / 1024}")
            local effectiveness=$(awk "BEGIN {printf \"%.1f\", ($pages_sharing - $pages_shared) * 100 / $pages_sharing}")
            
            echo "" | tee -a "$REPORT_FILE"
            log_output "Memory saved: ${saved_mb} MB"
            log_output "Effectiveness: ${effectiveness}%"
            
            echo "" | tee -a "$REPORT_FILE"
            if (( $(echo "$effectiveness > 10" | bc -l) )); then
                print_colored "$GREEN" "✅ KSM is highly effective (> 10%)"
            elif (( $(echo "$effectiveness > 5" | bc -l) )); then
                print_colored "$YELLOW" "⚠️  KSM shows modest benefit (5-10%)"
            else
                print_colored "$YELLOW" "⚠️  KSM benefit is minimal (< 5%)"
                log_output "Consider disabling to save CPU"
            fi
        fi
    else
        log_output "KSM is available but not running"
        
        # Offer to test KSM
        if [ "$EUID" -eq 0 ]; then
            echo "" | tee -a "$REPORT_FILE"
            read -p "Would you like to test KSM effectiveness? (y/N): " -n 1 -r
            echo ""
            
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                test_ksm_effectiveness
            fi
        else
            echo "" | tee -a "$REPORT_FILE"
            log_output "Run with sudo to enable KSM testing"
        fi
    fi
}

test_ksm_effectiveness() {
    print_section "KSM Effectiveness Test"
    
    log_output "Enabling KSM with aggressive settings..."
    echo 1 > /sys/kernel/mm/ksm/run
    echo 1000 > /sys/kernel/mm/ksm/pages_to_scan
    echo 10 > /sys/kernel/mm/ksm/sleep_millisecs
    
    log_output "Waiting for KSM to scan memory (60 seconds)..."
    sleep 60
    
    local pages_shared=$(cat /sys/kernel/mm/ksm/pages_shared)
    local pages_sharing=$(cat /sys/kernel/mm/ksm/pages_sharing)
    
    echo "" | tee -a "$REPORT_FILE"
    log_output "Test results:"
    log_output "  Pages shared: $pages_shared"
    log_output "  Pages sharing: $pages_sharing"
    
    if [ "$pages_sharing" -gt 0 ]; then
        local saved_kb=$(( (pages_sharing - pages_shared) * 4 ))
        local saved_mb=$(awk "BEGIN {printf \"%.2f\", $saved_kb / 1024}")
        local effectiveness=$(awk "BEGIN {printf \"%.1f\", ($pages_sharing - $pages_shared) * 100 / $pages_sharing}")
        
        log_output "  Memory saved: ${saved_mb} MB"
        log_output "  Effectiveness: ${effectiveness}%"
        
        echo "" | tee -a "$REPORT_FILE"
        if (( $(echo "$saved_mb > 100" | bc -l) )); then
            print_colored "$GREEN" "✅ KSM is highly effective (> 100 MB saved)"
            log_output "Recommendation: Keep KSM enabled"
        elif (( $(echo "$saved_mb > 20" | bc -l) )); then
            print_colored "$YELLOW" "⚠️  KSM shows modest benefit (20-100 MB saved)"
            log_output "Recommendation: Consider keeping enabled"
        else
            print_colored "$YELLOW" "⚠️  KSM benefit is minimal (< 20 MB saved)"
            log_output "Recommendation: Disable to save CPU"
        fi
    else
        log_output "  No pages merged"
        print_colored "$YELLOW" "⚠️  No deduplication opportunities found"
    fi
    
    # Ask to keep enabled
    echo "" | tee -a "$REPORT_FILE"
    read -p "Keep KSM enabled? (y/N): " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_output "KSM kept enabled with moderate settings"
        echo 200 > /sys/kernel/mm/ksm/pages_to_scan
        echo 20 > /sys/kernel/mm/ksm/sleep_millisecs
    else
        log_output "Disabling KSM and unmerging pages..."
        echo 2 > /sys/kernel/mm/ksm/run
    fi
}

analyze_swap_activity() {
    print_section "Swap Activity Analysis"
    
    local pswpin=$(grep pswpin /proc/vmstat | awk '{print $2}')
    local pswpout=$(grep pswpout /proc/vmstat | awk '{print $2}')
    local pgmajfault=$(grep pgmajfault /proc/vmstat | awk '{print $2}')
    
    log_output "Cumulative counters (since boot):"
    log_output "  Swap-ins (from disk): $pswpin pages ($((pswpin * 4 / 1024)) MB)"
    log_output "  Swap-outs (to disk): $pswpout pages ($((pswpout * 4 / 1024)) MB)"
    log_output "  Major page faults: $pgmajfault"
    
    echo "" | tee -a "$REPORT_FILE"
    
    # Record rates over 10 seconds
    log_output "Recording activity rates (10 seconds)..."
    
    local prev_pswpin=$pswpin
    local prev_pswpout=$pswpout
    local prev_pgmajfault=$pgmajfault
    
    sleep 10
    
    local curr_pswpin=$(grep pswpin /proc/vmstat | awk '{print $2}')
    local curr_pswpout=$(grep pswpout /proc/vmstat | awk '{print $2}')
    local curr_pgmajfault=$(grep pgmajfault /proc/vmstat | awk '{print $2}')
    
    local swapin_rate=$(awk "BEGIN {printf \"%.1f\", ($curr_pswpin - $prev_pswpin) / 10}")
    local swapout_rate=$(awk "BEGIN {printf \"%.1f\", ($curr_pswpout - $prev_pswpout) / 10}")
    local majfault_rate=$(awk "BEGIN {printf \"%.1f\", ($curr_pgmajfault - $prev_pgmajfault) / 10}")
    
    log_output "Activity rates (per second):"
    log_output "  Swap-in: ${swapin_rate} pages/sec"
    log_output "  Swap-out: ${swapout_rate} pages/sec"
    log_output "  Major faults: ${majfault_rate}/sec"
    
    echo "" | tee -a "$REPORT_FILE"
    
    # Assessment
    if (( $(echo "$majfault_rate > 50" | bc -l) )); then
        print_colored "$RED" "❌ HIGH disk I/O: Working set exceeds available RAM"
    elif (( $(echo "$majfault_rate > 10" | bc -l) )); then
        print_colored "$YELLOW" "⚠️  MODERATE disk I/O: Monitor memory usage"
    else
        print_colored "$GREEN" "✅ Disk I/O is low"
    fi
}

analyze_memory_pressure() {
    print_section "Memory Pressure (PSI)"
    
    if [ ! -f /proc/pressure/memory ]; then
        log_output "PSI not available (kernel too old)"
        return
    fi
    
    log_output "$(cat /proc/pressure/memory)"
    
    echo "" | tee -a "$REPORT_FILE"
    
    local full_avg10=$(grep "^full" /proc/pressure/memory | awk '{print $2}' | cut -d= -f2)
    local some_avg10=$(grep "^some" /proc/pressure/memory | awk '{print $2}' | cut -d= -f2)
    
    if (( $(echo "$full_avg10 > 5" | bc -l) )); then
        print_colored "$RED" "❌ SEVERE memory pressure (full avg10 > 5)"
        log_output "System is experiencing significant stalls"
    elif (( $(echo "$full_avg10 > 1" | bc -l) )); then
        print_colored "$YELLOW" "⚠️  MODERATE memory pressure (full avg10 > 1)"
        log_output "Some tasks are being delayed"
    elif (( $(echo "$some_avg10 > 20" | bc -l) )); then
        print_colored "$YELLOW" "⚠️  Contention detected (some avg10 > 20)"
    else
        print_colored "$GREEN" "✅ No significant memory pressure"
    fi
}

analyze_process_memory() {
    print_section "Process Memory Analysis (Top 10 by Swap)"
    
    log_output "Finding processes using swap..."
    
    # Create temporary file for process data
    local tmpfile=$(mktemp)
    
    for pid in /proc/[0-9]*; do
        if [ -f "$pid/smaps" ]; then
            local swap=$(awk '/^Swap:/ { sum+=$2 } END { print sum+0 }' "$pid/smaps" 2>/dev/null)
            if [ "$swap" -gt 0 ]; then
                local rss=$(awk '/^Rss:/ { sum+=$2 } END { print sum+0 }' "$pid/smaps" 2>/dev/null)
                local cmd=$(cat "$pid/cmdline" 2>/dev/null | tr '\0' ' ' | cut -c1-50)
                [ -z "$cmd" ] && cmd=$(basename "$pid")
                echo "$swap $rss $(basename $pid) $cmd"
            fi
        fi
    done | sort -rn | head -10 > "$tmpfile"
    
    if [ -s "$tmpfile" ]; then
        printf "%-10s %-10s %-8s %s\n" "SWAP(KB)" "RSS(KB)" "PID" "COMMAND" | tee -a "$REPORT_FILE"
        printf "%-10s %-10s %-8s %s\n" "--------" "--------" "------" "-------" | tee -a "$REPORT_FILE"
        
        while read -r swap rss pid cmd; do
            printf "%-10s %-10s %-8s %s\n" "$swap" "$rss" "$pid" "$cmd" | tee -a "$REPORT_FILE"
        done < "$tmpfile"
    else
        log_output "No processes currently using swap"
    fi
    
    rm -f "$tmpfile"
}

check_damon() {
    print_section "DAMON (Data Access MONitor)"
    
    if [ ! -d /sys/kernel/mm/damon ]; then
        log_output "DAMON not available (kernel not configured with CONFIG_DAMON)"
        return
    fi
    
    print_colored "$GREEN" "✅ DAMON is available"
    echo "" | tee -a "$REPORT_FILE"
    
    # Check if damo is installed
    if command -v damo &>/dev/null; then
        print_colored "$GREEN" "✅ DAMO tool is installed"
        log_output "DAMO version: $(damo version 2>&1 | head -1)"
        
        echo "" | tee -a "$REPORT_FILE"
        log_output "To profile memory access patterns:"
        log_output "  sudo damo record --target_type=paddr --duration 60"
        log_output "  sudo damo report wss"
        log_output "  sudo damo report heats"
    else
        print_colored "$YELLOW" "⚠️  DAMO tool not installed"
        log_output "Install with: pip3 install damo"
    fi
}

generate_recommendations() {
    print_section "Recommendations"
    
    local total_mem=$(free -m | grep "^Mem:" | awk '{print $2}')
    local available_mem=$(free -m | grep "^Mem:" | awk '{print $7}')
    local swap_total=$(free -m | grep "^Swap:" | awk '{print $2}')
    local swap_used=$(free -m | grep "^Swap:" | awk '{print $3}')
    local mem_available_pct=$(awk "BEGIN {printf \"%.1f\", $available_mem * 100 / $total_mem}")
    
    local pswpin=$(grep pswpin /proc/vmstat | awk '{print $2}')
    local pswpout=$(grep pswpout /proc/vmstat | awk '{print $2}')
    
    local has_recommendations=false
    
    # Check swap configuration
    if [ "$swap_total" -eq 0 ]; then
        has_recommendations=true
        log_output "• Configure swap for better memory management"
        log_output "  Run: sudo ./setup-swap.sh --architecture zswap"
        echo "" | tee -a "$REPORT_FILE"
    fi
    
    # Check ZSWAP
    if [ -f /sys/module/zswap/parameters/enabled ]; then
        local zswap_enabled=$(cat /sys/module/zswap/parameters/enabled)
        if [ "$zswap_enabled" = "N" ] && [ "$swap_total" -gt 0 ]; then
            has_recommendations=true
            log_output "• Enable ZSWAP for compressed swap cache"
            log_output "  Run: sudo ./setup-swap.sh --architecture zswap"
            echo "" | tee -a "$REPORT_FILE"
        fi
    fi
    
    # Check memory availability
    if (( $(echo "$mem_available_pct < 20" | bc -l) )); then
        has_recommendations=true
        log_output "• Low memory available (<20%):"
        log_output "  - Increase swap size"
        log_output "  - Enable/tune ZSWAP or ZRAM"
        log_output "  - Identify memory-hungry processes"
        log_output "  - Consider adding more RAM"
        echo "" | tee -a "$REPORT_FILE"
    fi
    
    # Check swap activity
    if [ "$pswpin" -gt 100000 ] || [ "$pswpout" -gt 100000 ]; then
        has_recommendations=true
        log_output "• High swap activity detected:"
        log_output "  - Increase ZSWAP pool size (if using ZSWAP)"
        log_output "  - Add ZRAM for hot data caching"
        log_output "  - Optimize application memory usage"
        log_output "  - Consider adding more RAM"
        echo "" | tee -a "$REPORT_FILE"
    fi
    
    # ZSWAP pool sizing
    if [ -d /sys/kernel/debug/zswap ]; then
        local stored=$(cat /sys/kernel/debug/zswap/stored_pages 2>/dev/null || echo 0)
        local written=$(cat /sys/kernel/debug/zswap/written_back_pages 2>/dev/null || echo 0)
        
        if [ "$stored" -gt 0 ]; then
            local wb_ratio=$(awk "BEGIN {printf \"%.1f\", $written * 100 / $stored}")
            
            if (( $(echo "$wb_ratio > 30" | bc -l) )); then
                has_recommendations=true
                log_output "• ZSWAP pool is too small (writeback ratio ${wb_ratio}%):"
                log_output "  - Increase max_pool_percent from $(cat /sys/module/zswap/parameters/max_pool_percent)% to $(($(cat /sys/module/zswap/parameters/max_pool_percent) + 10))%"
                log_output "  - Edit /etc/sysctl.d/99-swap.conf"
                echo "" | tee -a "$REPORT_FILE"
            fi
        fi
    fi
    
    # KSM recommendations
    if [ -f /sys/kernel/mm/ksm/pages_sharing ]; then
        local ksm_run=$(cat /sys/kernel/mm/ksm/run)
        local pages_sharing=$(cat /sys/kernel/mm/ksm/pages_sharing)
        
        if [ "$ksm_run" -eq 1 ] && [ "$pages_sharing" -gt 0 ]; then
            local pages_shared=$(cat /sys/kernel/mm/ksm/pages_shared)
            local saved_mb=$(awk "BEGIN {printf \"%.2f\", ($pages_sharing - $pages_shared) * 4 / 1024}")
            local effectiveness=$(awk "BEGIN {printf \"%.1f\", ($pages_sharing - $pages_shared) * 100 / $pages_sharing}")
            
            if (( $(echo "$effectiveness < 5" | bc -l) )); then
                has_recommendations=true
                log_output "• KSM benefit is minimal (${effectiveness}%, ${saved_mb} MB):"
                log_output "  - Consider disabling KSM to save CPU"
                log_output "  - Run: echo 2 | sudo tee /sys/kernel/mm/ksm/run"
                echo "" | tee -a "$REPORT_FILE"
            fi
        fi
    fi
    
    if [ "$has_recommendations" = false ]; then
        print_colored "$GREEN" "✅ System configuration looks good"
        log_output "No immediate recommendations"
    fi
}

# Main execution
main() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Comprehensive System Analysis                   ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Report will be saved to: $REPORT_FILE"
    echo ""
    
    # Initialize report file
    echo "System Analysis Report" > "$REPORT_FILE"
    echo "Generated: $(date)" >> "$REPORT_FILE"
    echo "Hostname: $(hostname)" >> "$REPORT_FILE"
    echo "Kernel: $(uname -r)" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    
    check_root
    
    # Run all analyses
    analyze_memory_state
    analyze_swap_config
    analyze_zswap
    analyze_zram
    analyze_ksm
    analyze_swap_activity
    analyze_memory_pressure
    analyze_process_memory
    check_damon
    generate_recommendations
    
    # Summary
    print_section "Analysis Complete"
    print_colored "$GREEN" "✅ Report saved to: $REPORT_FILE"
    echo ""
    log_output "View report: cat $REPORT_FILE"
    log_output "For real-time monitoring: ./swap-monitor.sh"
    log_output "For benchmarking: ./benchmark.py"
}

main "$@"
