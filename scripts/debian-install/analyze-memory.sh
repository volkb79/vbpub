#!/bin/bash
#
# analyze-memory.sh - Comprehensive Memory Analysis for Running Systems
#
# Purpose: Analyze current memory usage, working sets, and optimization opportunities
#

set -euo pipefail

# Colors
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

check_damon_availability() {
    log_section "DAMON/DAMO Availability"
    
    # Check if damo is installed
    if command -v damo &>/dev/null; then
        local version=$(damo version 2>/dev/null || echo "unknown")
        log_info "DAMO installed: $version"
    else
        log_warn "DAMO not installed"
        echo "  Install with: pip3 install damo"
        echo ""
    fi
    
    # Check kernel support
    local kernel_version=$(uname -r)
    echo "Kernel: $kernel_version"
    
    if [ -f /boot/config-$kernel_version ]; then
        echo ""
        echo "Kernel DAMON configuration:"
        grep -E 'CONFIG_DAMON' /boot/config-$kernel_version 2>/dev/null || echo "  CONFIG_DAMON not found"
    fi
    
    # Check if DAMON sysfs/debugfs is available
    if [ -d /sys/kernel/mm/damon ]; then
        log_info "DAMON sysfs interface available"
    elif [ -d /sys/kernel/debug/damon ]; then
        log_info "DAMON debugfs interface available"
    else
        log_warn "DAMON interface not available - kernel support may be missing"
    fi
    
    echo ""
}

analyze_ksm() {
    log_section "KSM (Kernel Same-page Merging) Statistics"
    
    local ksm_dir="/sys/kernel/mm/ksm"
    
    if [ ! -d "$ksm_dir" ]; then
        log_warn "KSM not available in kernel"
        return
    fi
    
    # Check if KSM is running
    local run=$(cat $ksm_dir/run)
    if [ "$run" = "1" ]; then
        echo "Status: ${GREEN}RUNNING${NC}"
    else
        echo "Status: ${RED}STOPPED${NC}"
    fi
    
    echo ""
    
    # Get statistics
    local shared=$(cat $ksm_dir/pages_shared 2>/dev/null || echo 0)
    local sharing=$(cat $ksm_dir/pages_sharing 2>/dev/null || echo 0)
    local unshared=$(cat $ksm_dir/pages_unshared 2>/dev/null || echo 0)
    local volatile=$(cat $ksm_dir/pages_volatile 2>/dev/null || echo 0)
    local scans=$(cat $ksm_dir/full_scans 2>/dev/null || echo 0)
    
    echo "Page Statistics:"
    echo "  pages_shared:   $shared ($(($shared * 4 / 1024)) MB) - unique pages being shared"
    echo "  pages_sharing:  $sharing ($(($sharing * 4 / 1024)) MB) - total duplicate references"
    echo "  pages_unshared: $unshared ($(($unshared * 4 / 1024)) MB) - no duplicates found"
    echo "  pages_volatile: $volatile ($(($volatile * 4 / 1024)) MB) - changed during scan"
    echo "  full_scans:     $scans"
    
    echo ""
    
    # Calculate savings
    if [ $shared -gt 0 ]; then
        local saved_kb=$((($sharing - $shared) * 4))
        local saved_mb=$(($saved_kb / 1024))
        local ratio=$(awk "BEGIN {printf \"%.2f\", $sharing / $shared}")
        
        echo "Memory Savings:"
        echo -e "  ${GREEN}Saved: ${saved_mb} MB${NC}"
        echo "  Deduplication ratio: ${ratio}:1"
        
        # Calculate percentage
        local total_kb=$(($sharing * 4))
        if [ $total_kb -gt 0 ]; then
            local pct=$(awk "BEGIN {printf \"%.1f\", ($saved_kb * 100.0) / $total_kb}")
            echo "  Savings percentage: ${pct}%"
        fi
        
        echo ""
        echo "Recommendation:"
        if [ $saved_mb -gt 100 ]; then
            echo -e "  ${GREEN}✅ Keep KSM enabled - significant savings (>100 MB)${NC}"
        elif [ $saved_mb -gt 20 ]; then
            echo -e "  ${YELLOW}⚠️  Consider keeping KSM - moderate savings (20-100 MB)${NC}"
        else
            echo -e "  ${RED}❌ Consider disabling KSM - low savings (<20 MB)${NC}"
        fi
    else
        echo "Memory Savings: None (no pages shared)"
        echo ""
        echo "Recommendation:"
        if [ "$run" = "1" ] && [ $scans -lt 3 ]; then
            echo -e "  ${YELLOW}⚠️  KSM running but scans incomplete - wait for more scans${NC}"
        else
            echo -e "  ${RED}❌ No benefit from KSM for current workload${NC}"
        fi
    fi
    
    echo ""
    
    # Configuration
    if [ "$run" = "1" ]; then
        echo "Scan Configuration:"
        echo "  pages_to_scan:  $(cat $ksm_dir/pages_to_scan) pages per iteration"
        echo "  sleep_millisecs: $(cat $ksm_dir/sleep_millisecs) ms between iterations"
    fi
    
    echo ""
}

analyze_working_set() {
    log_section "Working Set Estimation"
    
    # Method 1: Using referenced pages from smaps (requires processes)
    echo "Top 10 processes by working set (referenced pages):"
    echo ""
    
    local pids=$(ps aux --no-headers | awk '{print $2}' | head -20)
    
    declare -A working_sets
    
    for pid in $pids; do
        if [ -f /proc/$pid/smaps ]; then
            local rss=$(awk '/^Rss:/ {sum+=$2} END {print sum}' /proc/$pid/smaps 2>/dev/null || echo 0)
            local ref=$(awk '/^Referenced:/ {sum+=$2} END {print sum}' /proc/$pid/smaps 2>/dev/null || echo 0)
            
            if [ $ref -gt 0 ]; then
                local cmdline=$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ' | cut -c1-40)
                if [ -z "$cmdline" ]; then
                    cmdline=$(cat /proc/$pid/comm 2>/dev/null)
                fi
                working_sets[$pid]="$ref|$rss|$cmdline"
            fi
        fi
    done
    
    # Sort and display top 10
    for pid in "${!working_sets[@]}"; do
        echo "${working_sets[$pid]}|$pid"
    done | sort -t'|' -k1 -rn | head -10 | while IFS='|' read -r ref rss cmd pid; do
        local ref_mb=$((ref / 1024))
        local rss_mb=$((rss / 1024))
        local pct=0
        if [ $rss -gt 0 ]; then
            pct=$(awk "BEGIN {printf \"%.0f\", ($ref * 100.0) / $rss}")
        fi
        printf "  PID %-6s: %4d MB working / %4d MB RSS (%2d%%) - %s\n" "$pid" "$ref_mb" "$rss_mb" "$pct" "$cmd"
    done
    
    echo ""
    
    # Method 2: System-wide approximation
    echo "System-wide memory analysis:"
    local total_rss=0
    local total_ref=0
    
    for pid in $(ps aux --no-headers | awk '{print $2}'); do
        if [ -f /proc/$pid/smaps ]; then
            total_rss=$((total_rss + $(awk '/^Rss:/ {sum+=$2} END {print sum}' /proc/$pid/smaps 2>/dev/null || echo 0)))
            total_ref=$((total_ref + $(awk '/^Referenced:/ {sum+=$2} END {print sum}' /proc/$pid/smaps 2>/dev/null || echo 0)))
        fi
    done
    
    echo "  Total RSS:        $((total_rss / 1024)) MB"
    echo "  Total Referenced: $((total_ref / 1024)) MB (working set)"
    if [ $total_rss -gt 0 ]; then
        local ws_pct=$(awk "BEGIN {printf \"%.1f\", ($total_ref * 100.0) / $total_rss}")
        echo "  Working set ratio: ${ws_pct}%"
    fi
    
    echo ""
}

analyze_hot_cold_pages() {
    log_section "Hot/Cold Page Analysis Recommendations"
    
    echo "Without DAMON, use these heuristics:"
    echo ""
    
    # Check page faults
    echo "1. Page Fault Activity:"
    local pgfault=$(grep '^pgfault ' /proc/vmstat | awk '{print $2}')
    local pgmajfault=$(grep '^pgmajfault ' /proc/vmstat | awk '{print $2}')
    echo "   Total page faults:      $pgfault"
    echo "   Major faults (disk I/O): $pgmajfault"
    
    # Get rate (approximate by checking again after 1 second)
    sleep 1
    local pgmajfault2=$(grep '^pgmajfault ' /proc/vmstat | awk '{print $2}')
    local majfault_rate=$((pgmajfault2 - pgmajfault))
    
    echo "   Major fault rate:       ${majfault_rate}/sec"
    
    if [ $majfault_rate -gt 100 ]; then
        echo -e "   ${RED}⚠️  High major fault rate - memory pressure${NC}"
    elif [ $majfault_rate -gt 10 ]; then
        echo -e "   ${YELLOW}⚠️  Moderate major fault rate${NC}"
    else
        echo -e "   ${GREEN}✅ Low major fault rate - system healthy${NC}"
    fi
    
    echo ""
    
    # Check swap activity
    if [ -f /proc/swaps ] && [ -s /proc/swaps ]; then
        echo "2. Swap Activity:"
        local pswpin=$(grep '^pswpin ' /proc/vmstat | awk '{print $2}')
        local pswpout=$(grep '^pswpout ' /proc/vmstat | awk '{print $2}')
        echo "   Pages swapped in:  $pswpin"
        echo "   Pages swapped out: $pswpout"
        echo ""
    fi
    
    # Memory pressure (PSI)
    if [ -f /proc/pressure/memory ]; then
        echo "3. Memory Pressure (PSI):"
        cat /proc/pressure/memory | while read line; do
            echo "   $line"
        done
        echo ""
        
        local full_avg10=$(grep '^full' /proc/pressure/memory | awk '{print $2}' | cut -d'=' -f2)
        if [ -n "$full_avg10" ]; then
            if awk -v val="$full_avg10" 'BEGIN {exit !(val > 5.0)}'; then
                echo -e "   ${RED}⚠️  Severe memory pressure (full avg10 > 5%)${NC}"
            elif awk -v val="$full_avg10" 'BEGIN {exit !(val > 2.0)}'; then
                echo -e "   ${YELLOW}⚠️  Significant memory pressure${NC}"
            else
                echo -e "   ${GREEN}✅ Memory pressure normal${NC}"
            fi
        fi
        echo ""
    fi
    
    # Recommendations
    echo "Recommendations:"
    echo ""
    echo "For detailed hot/cold analysis, use DAMON:"
    echo "  1. Install: pip3 install damo"
    echo "  2. Monitor: damo start --all --duration 300s"
    echo "  3. Report:  damo report --hot-cold-ratio --threshold 10"
    echo ""
    echo "Alternative: Run KSM trial to check for deduplication opportunities:"
    echo "  bash /root/ksm-trial.sh"
    echo ""
}

analyze_swap_usage() {
    log_section "Swap Usage Analysis"
    
    if ! swapon --show &>/dev/null || [ -z "$(swapon --show)" ]; then
        log_warn "No swap devices active"
        return
    fi
    
    echo "Active swap devices:"
    swapon --show
    echo ""
    
    # Check ZRAM
    if [ -b /dev/zram0 ]; then
        echo "ZRAM Statistics:"
        if [ -f /sys/block/zram0/mm_stat ]; then
            local mm_stat=$(cat /sys/block/zram0/mm_stat)
            local orig=$(echo $mm_stat | awk '{print $1}')
            local compr=$(echo $mm_stat | awk '{print $2}')
            local mem_used=$(echo $mm_stat | awk '{print $3}')
            local same_pages=$(echo $mm_stat | awk '{print $6}')
            
            echo "  Original data:    $((orig / 1024 / 1024)) MB"
            echo "  Compressed data:  $((compr / 1024 / 1024)) MB"
            echo "  Memory used:      $((mem_used / 1024 / 1024)) MB"
            echo "  Zero pages:       $same_pages"
            
            if [ $compr -gt 0 ]; then
                local ratio=$(awk "BEGIN {printf \"%.2f\", $orig / $compr}")
                echo "  Compression ratio: ${ratio}:1"
            fi
        fi
        echo ""
    fi
    
    # Check ZSWAP
    if [ -f /sys/module/zswap/parameters/enabled ]; then
        local enabled=$(cat /sys/module/zswap/parameters/enabled)
        echo "ZSWAP Status: $([ "$enabled" = "Y" ] && echo 'ENABLED' || echo 'DISABLED')"
        
        if [ "$enabled" = "Y" ]; then
            if [ -d /sys/kernel/debug/zswap ]; then
                echo "ZSWAP Statistics:"
                echo "  Pool total size:  $(cat /sys/kernel/debug/zswap/pool_total_size 2>/dev/null || echo 'N/A')"
                echo "  Stored pages:     $(cat /sys/kernel/debug/zswap/stored_pages 2>/dev/null || echo 'N/A')"
                echo "  Written back:     $(cat /sys/kernel/debug/zswap/written_back_pages 2>/dev/null || echo 'N/A')"
            fi
        fi
        echo ""
    fi
}

print_summary() {
    log_section "Summary and Recommendations"
    
    echo "Key Tools for Memory Analysis:"
    echo ""
    echo "1. DAMON/DAMO - Working set and hot/cold analysis"
    echo "   Install: pip3 install damo"
    echo "   Requires: Kernel 5.15+ with CONFIG_DAMON"
    echo ""
    echo "2. KSM - Page deduplication for identical content"
    echo "   Trial:  bash /root/ksm-trial.sh"
    echo "   Stats:  cat /sys/kernel/mm/ksm/*"
    echo ""
    echo "3. PSI - Memory pressure monitoring"
    echo "   Check:  cat /proc/pressure/memory"
    echo ""
    echo "4. Swap monitoring"
    echo "   Monitor: bash /root/swap-monitor.sh"
    echo ""
}

main() {
    log_section "Memory Analysis for Running System"
    
    check_damon_availability
    analyze_ksm
    analyze_working_set
    analyze_hot_cold_pages
    analyze_swap_usage
    print_summary
}

main "$@"
