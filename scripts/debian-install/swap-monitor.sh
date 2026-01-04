#!/bin/bash
# Real-time swap monitoring with correct metrics
# Focus on: pgmajfault, writeback ratio, PSI, not just vmstat si

set -euo pipefail

# Configuration
INTERVAL=${1:-5}  # Default 5 seconds
MODE="${MODE:-continuous}"  # continuous, once, json

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --once)
            MODE="once"
            shift
            ;;
        --json)
            MODE="json"
            shift
            ;;
        --help)
            cat <<EOF
Usage: $0 [OPTIONS] [INTERVAL]

Monitor swap and memory status with correct metrics.

Options:
  --once          Single snapshot (no continuous monitoring)
  --json          Output in JSON format
  --help          Show this help

Arguments:
  INTERVAL        Update interval in seconds (default: 5)

Examples:
  $0              # Continuous monitoring, 5 second interval
  $0 1            # Continuous monitoring, 1 second interval
  $0 --once       # Single snapshot
  $0 --json       # JSON output for automation

Metrics Explained:
  pgmajfault      - Actual disk I/O page faults (IMPORTANT!)
  vmstat si/so    - Includes RAM decompression (MISLEADING!)
  writeback ratio - % of ZSWAP pages written to disk
  PSI full        - All tasks stalled on memory (CRITICAL!)

Note: vmstat 'si' counts ZSWAP RAM hits too, not just disk I/O!
Use pgmajfault for real disk activity.
EOF
            exit 0
            ;;
        *)
            INTERVAL="$1"
            shift
            ;;
    esac
done

# Get memory info
get_memory_info() {
    MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_AVAILABLE=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    MEM_USED=$((MEM_TOTAL - MEM_AVAILABLE))
    MEM_USED_PCT=$((MEM_USED * 100 / MEM_TOTAL))
    
    SWAP_TOTAL=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    SWAP_FREE=$(grep SwapFree /proc/meminfo | awk '{print $2}')
    SWAP_USED=$((SWAP_TOTAL - SWAP_FREE))
    if [ "$SWAP_TOTAL" -gt 0 ]; then
        SWAP_USED_PCT=$((SWAP_USED * 100 / SWAP_TOTAL))
    else
        SWAP_USED_PCT=0
    fi
}

# Get ZRAM stats
get_zram_stats() {
    ZRAM_ACTIVE=0
    ZRAM_ORIG_SIZE=0
    ZRAM_COMPR_SIZE=0
    ZRAM_RATIO=0
    
    if [ -b /dev/zram0 ] && [ -f /sys/block/zram0/mm_stat ]; then
        ZRAM_ACTIVE=1
        read ZRAM_ORIG_SIZE ZRAM_COMPR_SIZE _ < /sys/block/zram0/mm_stat
        if [ "$ZRAM_COMPR_SIZE" -gt 0 ]; then
            # Use shell arithmetic to avoid bc dependency
            ZRAM_RATIO=$(awk "BEGIN {printf \"%.2f\", $ZRAM_ORIG_SIZE / $ZRAM_COMPR_SIZE}")
        fi
    fi
}

# Get ZSWAP stats
get_zswap_stats() {
    ZSWAP_ACTIVE=0
    ZSWAP_POOL_PAGES=0
    ZSWAP_WRITTEN_BACK=0
    ZSWAP_WRITEBACK_RATIO=0
    
    if [ -d /sys/module/zswap ] && [ "$(cat /sys/module/zswap/parameters/enabled 2>/dev/null)" = "Y" ]; then
        ZSWAP_ACTIVE=1
        
        if [ -f /sys/kernel/debug/zswap/pool_pages ]; then
            ZSWAP_POOL_PAGES=$(cat /sys/kernel/debug/zswap/pool_pages 2>/dev/null || echo 0)
            ZSWAP_WRITTEN_BACK=$(cat /sys/kernel/debug/zswap/written_back_pages 2>/dev/null || echo 0)
            
            if [ "$ZSWAP_POOL_PAGES" -gt 0 ]; then
                # Use awk instead of bc
                ZSWAP_WRITEBACK_RATIO=$(awk "BEGIN {printf \"%.2f\", 100 * $ZSWAP_WRITTEN_BACK / $ZSWAP_POOL_PAGES}")
            fi
        fi
    fi
}

# Get page fault stats (IMPORTANT METRIC!)
get_pgfault_stats() {
    PGMAJFAULT=$(grep pgmajfault /proc/vmstat | awk '{print $2}')
    PGMAJFAULT_RATE=0
    
    if [ -n "$PREV_PGMAJFAULT" ]; then
        PGMAJFAULT_DELTA=$((PGMAJFAULT - PREV_PGMAJFAULT))
        # Use awk instead of bc
        PGMAJFAULT_RATE=$(awk "BEGIN {printf \"%.2f\", $PGMAJFAULT_DELTA / $INTERVAL}")
    fi
    
    PREV_PGMAJFAULT=$PGMAJFAULT
}

# Get PSI (Pressure Stall Information)
get_psi_stats() {
    PSI_SOME_AVG10=0
    PSI_FULL_AVG10=0
    
    if [ -f /proc/pressure/memory ]; then
        PSI_SOME_AVG10=$(grep "^some" /proc/pressure/memory | awk '{print $2}' | cut -d'=' -f2)
        PSI_FULL_AVG10=$(grep "^full" /proc/pressure/memory | awk '{print $2}' | cut -d'=' -f2)
    fi
}

# Get vmstat stats (with caveat!)
get_vmstat_stats() {
    # Note: si includes ZSWAP RAM decompression, not just disk!
    read _ _ _ _ _ _ SI SO _ _ < <(vmstat -n | tail -1)
    VMSTAT_SI=$SI
    VMSTAT_SO=$SO
}

# Color code writeback ratio
color_writeback_ratio() {
    local ratio=$1
    local ratio_int=${ratio%.*}
    
    if [ "$ratio_int" -lt 1 ]; then
        echo -e "${GREEN}${ratio}%${NC}"
    elif [ "$ratio_int" -lt 10 ]; then
        echo -e "${YELLOW}${ratio}%${NC}"
    else
        echo -e "${RED}${ratio}%${NC}"
    fi
}

# Get top swapped processes
get_top_swapped() {
    TOP_SWAPPED=$(for pid in /proc/[0-9]*; do
        if [ -f "$pid/status" ]; then
            swap=$(grep VmSwap "$pid/status" 2>/dev/null | awk '{print $2}')
            if [ -n "$swap" ] && [ "$swap" -gt 0 ]; then
                comm=$(cat "$pid/comm" 2>/dev/null || echo "?")
                echo "$swap|$comm|$(basename $pid)"
            fi
        fi
    done | sort -t'|' -k1 -rn | head -10)
}

# Print header
print_header() {
    clear
    cat <<EOF
╔═══════════════════════════════════════════════════════════════════════════╗
║                         Swap Monitor                                      ║
║  $(date +'%Y-%m-%d %H:%M:%S')                                                         ║
╚═══════════════════════════════════════════════════════════════════════════╝
EOF
}

# Display in human format
display_human() {
    print_header
    
    # Memory overview
    echo -e "${BOLD}Memory Overview${NC}"
    printf "  RAM:  %'10d KB / %'10d KB (%3d%%)\n" $MEM_USED $MEM_TOTAL $MEM_USED_PCT
    printf "  Swap: %'10d KB / %'10d KB (%3d%%)\n" $SWAP_USED $SWAP_TOTAL $SWAP_USED_PCT
    echo ""
    
    # ZRAM status
    if [ "$ZRAM_ACTIVE" -eq 1 ]; then
        echo -e "${BOLD}ZRAM Status${NC}"
        printf "  Original:   %'15d bytes (%.2f GB)\n" $ZRAM_ORIG_SIZE $(awk "BEGIN {printf \"%.2f\", $ZRAM_ORIG_SIZE / 1024 / 1024 / 1024}")
        printf "  Compressed: %'15d bytes (%.2f GB)\n" $ZRAM_COMPR_SIZE $(awk "BEGIN {printf \"%.2f\", $ZRAM_COMPR_SIZE / 1024 / 1024 / 1024}")
        printf "  Ratio:      %.2fx compression\n" $ZRAM_RATIO
        echo ""
    fi
    
    # ZSWAP status
    if [ "$ZSWAP_ACTIVE" -eq 1 ]; then
        echo -e "${BOLD}ZSWAP Status${NC}"
        printf "  Pool pages:       %'10d\n" $ZSWAP_POOL_PAGES
        printf "  Written back:     %'10d\n" $ZSWAP_WRITTEN_BACK
        printf "  Writeback ratio:  "
        color_writeback_ratio "$ZSWAP_WRITEBACK_RATIO"
        echo ""
        echo -e "  ${CYAN}Note: <1%=${GREEN}excellent${CYAN}, 1-10%=${YELLOW}good${CYAN}, >10%=${RED}high pressure${NC}"
        echo ""
    fi
    
    # Swap devices
    echo -e "${BOLD}Swap Devices${NC}"
    swapon --show 2>/dev/null || echo "  No swap devices"
    echo ""
    
    # Critical metrics
    echo -e "${BOLD}Critical Metrics (Disk I/O)${NC}"
    printf "  pgmajfault:     %'10d total, %.2f/sec\n" $PGMAJFAULT $PGMAJFAULT_RATE
    echo -e "  ${CYAN}↑ THIS shows real disk I/O!${NC}"
    echo ""
    
    echo -e "${BOLD}Memory Pressure (PSI)${NC}"
    printf "  Some tasks stalled: %s%%\n" $PSI_SOME_AVG10
    printf "  All tasks stalled:  %s%%\n" $PSI_FULL_AVG10
    if (( $(awk "BEGIN {print ($PSI_FULL_AVG10 > 0)}") )); then
        echo -e "  ${RED}⚠ Memory pressure detected!${NC}"
    fi
    echo ""
    
    # vmstat with caveat
    echo -e "${BOLD}vmstat si/so (WITH CAVEAT!)${NC}"
    printf "  Swap-in:  %'10d KB/s\n" $VMSTAT_SI
    printf "  Swap-out: %'10d KB/s\n" $VMSTAT_SO
    echo -e "  ${YELLOW}⚠ si includes ZSWAP RAM hits (fast), not just disk (slow)!${NC}"
    echo -e "  ${YELLOW}  Use pgmajfault above for real disk I/O${NC}"
    echo ""
    
    # Top swapped processes
    if [ -n "$TOP_SWAPPED" ]; then
        echo -e "${BOLD}Top 10 Swapped Processes${NC}"
        printf "  %-10s %-20s %s\n" "Swap (KB)" "Command" "PID"
        echo "$TOP_SWAPPED" | while IFS='|' read swap comm pid; do
            printf "  %'10d %-20s %s\n" $swap "$comm" "$pid"
        done
    fi
    
    echo ""
    echo -e "${CYAN}Updating every ${INTERVAL}s. Press Ctrl+C to stop.${NC}"
}

# Output JSON
output_json() {
    cat <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "memory": {
    "total_kb": $MEM_TOTAL,
    "used_kb": $MEM_USED,
    "available_kb": $MEM_AVAILABLE,
    "used_percent": $MEM_USED_PCT
  },
  "swap": {
    "total_kb": $SWAP_TOTAL,
    "used_kb": $SWAP_USED,
    "free_kb": $SWAP_FREE,
    "used_percent": $SWAP_USED_PCT
  },
  "zram": {
    "active": $ZRAM_ACTIVE,
    "orig_size_bytes": $ZRAM_ORIG_SIZE,
    "compr_size_bytes": $ZRAM_COMPR_SIZE,
    "ratio": $ZRAM_RATIO
  },
  "zswap": {
    "active": $ZSWAP_ACTIVE,
    "pool_pages": $ZSWAP_POOL_PAGES,
    "written_back_pages": $ZSWAP_WRITTEN_BACK,
    "writeback_ratio_percent": $ZSWAP_WRITEBACK_RATIO
  },
  "metrics": {
    "pgmajfault_total": $PGMAJFAULT,
    "pgmajfault_rate": $PGMAJFAULT_RATE,
    "psi_some_avg10": $PSI_SOME_AVG10,
    "psi_full_avg10": $PSI_FULL_AVG10,
    "vmstat_si": $VMSTAT_SI,
    "vmstat_so": $VMSTAT_SO
  }
}
EOF
}

# Main monitoring loop
monitor() {
    PREV_PGMAJFAULT=""
    
    while true; do
        get_memory_info
        get_zram_stats
        get_zswap_stats
        get_pgfault_stats
        get_psi_stats
        get_vmstat_stats
        get_top_swapped
        
        case $MODE in
            json)
                output_json
                break
                ;;
            once)
                display_human
                break
                ;;
            *)
                display_human
                sleep "$INTERVAL"
                ;;
        esac
    done
}

# Run
monitor
