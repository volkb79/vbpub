#!/bin/bash
#
# swap-monitor.sh - Swap and Memory Monitoring with Correct Metrics
#
# Purpose: Monitor swap and memory with accurate metrics, avoiding vmstat si pitfalls
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
INTERVAL=${INTERVAL:-5}
ITERATIONS=${ITERATIONS:-0}  # 0 = infinite

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_header() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Swap Monitor - Correct Metrics${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "IMPORTANT: vmstat 'si' is MISLEADING with ZSWAP!"
    echo "  vmstat si counts ALL swap-ins (including fast RAM hits)"
    echo "  Use pgmajfault for actual disk I/O activity"
    echo ""
    echo "Monitoring interval: ${INTERVAL}s"
    echo "Press Ctrl+C to exit"
    echo ""
}

get_vmstat_value() {
    local key=$1
    grep "^${key} " /proc/vmstat | awk '{print $2}'
}

monitor_loop() {
    local iteration=0
    
    # Initial values for rate calculation
    local prev_pgmajfault=$(get_vmstat_value pgmajfault)
    local prev_pswpin=$(get_vmstat_value pswpin)
    local prev_pswpout=$(get_vmstat_value pswpout)
    local prev_time=$(date +%s)
    
    while true; do
        iteration=$((iteration + 1))
        
        if [ $ITERATIONS -gt 0 ] && [ $iteration -gt $ITERATIONS ]; then
            break
        fi
        
        clear
        print_header
        
        # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        # MEMORY OVERVIEW
        # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        echo -e "${BLUE}=== Memory Overview ===${NC}"
        free -h
        echo ""
        
        # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        # SWAP DEVICES
        # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        echo -e "${BLUE}=== Active Swap Devices ===${NC}"
        if swapon --show 2>/dev/null | grep -q .; then
            swapon --show
        else
            echo "No swap devices active"
        fi
        echo ""
        
        # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        # KEY METRICS (Not vmstat si!)
        # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        echo -e "${BLUE}=== Key Metrics (Correct, Not vmstat si!) ===${NC}"
        
        # Get current values
        local curr_time=$(date +%s)
        local elapsed=$((curr_time - prev_time))
        if [ $elapsed -eq 0 ]; then
            elapsed=1
        fi
        
        local curr_pgmajfault=$(get_vmstat_value pgmajfault)
        local curr_pswpin=$(get_vmstat_value pswpin)
        local curr_pswpout=$(get_vmstat_value pswpout)
        
        # Calculate rates
        local pgmajfault_rate=$(( (curr_pgmajfault - prev_pgmajfault) / elapsed ))
        local pswpin_rate=$(( (curr_pswpin - prev_pswpin) / elapsed ))
        local pswpout_rate=$(( (curr_pswpout - prev_pswpout) / elapsed ))
        
        # Display with color coding
        echo "1. pgmajfault (Disk I/O required):"
        if [ $pgmajfault_rate -gt 100 ]; then
            echo -e "   ${RED}Rate: ${pgmajfault_rate}/s (CONCERN: >100/s)${NC}"
        elif [ $pgmajfault_rate -gt 50 ]; then
            echo -e "   ${YELLOW}Rate: ${pgmajfault_rate}/s (Warning: >50/s)${NC}"
        else
            echo -e "   ${GREEN}Rate: ${pgmajfault_rate}/s (Normal)${NC}"
        fi
        echo "   Total: $curr_pgmajfault"
        echo ""
        
        echo "2. Swap I/O (pages):"
        echo "   Swap-in rate:  ${pswpin_rate}/s (total: $curr_pswpin)"
        echo "   Swap-out rate: ${pswpout_rate}/s (total: $curr_pswpout)"
        echo ""
        
        # Update previous values
        prev_pgmajfault=$curr_pgmajfault
        prev_pswpin=$curr_pswpin
        prev_pswpout=$curr_pswpout
        prev_time=$curr_time
        
        # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        # MEMORY PRESSURE (PSI)
        # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        if [ -f /proc/pressure/memory ]; then
            echo -e "${BLUE}=== Memory Pressure (PSI) ===${NC}"
            
            local some_avg10=$(grep '^some' /proc/pressure/memory | awk '{print $2}' | cut -d'=' -f2)
            local full_avg10=$(grep '^full' /proc/pressure/memory | awk '{print $2}' | cut -d'=' -f2)
            
            echo "Some tasks stalled:"
            cat /proc/pressure/memory | grep '^some'
            
            echo "All tasks stalled:"
            cat /proc/pressure/memory | grep '^full'
            
            # Interpret full avg10
            if [ -n "$full_avg10" ]; then
                local pressure_val=$(echo "$full_avg10" | awk '{printf "%.1f", $1}')
                echo ""
                if (( $(echo "$pressure_val > 5.0" | bc -l 2>/dev/null || echo 0) )); then
                    echo -e "${RED}⚠️  SEVERE memory pressure (full avg10 > 5%)${NC}"
                elif (( $(echo "$pressure_val > 2.0" | bc -l 2>/dev/null || echo 0) )); then
                    echo -e "${YELLOW}⚠️  Significant memory pressure (full avg10 > 2%)${NC}"
                else
                    echo -e "${GREEN}✅ Memory pressure normal${NC}"
                fi
            fi
            echo ""
        fi
        
        # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        # ZSWAP STATISTICS
        # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        if [ -f /sys/module/zswap/parameters/enabled ]; then
            local zswap_enabled=$(cat /sys/module/zswap/parameters/enabled)
            
            if [ "$zswap_enabled" = "Y" ]; then
                echo -e "${BLUE}=== ZSWAP Statistics ===${NC}"
                
                if [ -d /sys/kernel/debug/zswap ]; then
                    local stored=$(cat /sys/kernel/debug/zswap/stored_pages 2>/dev/null || echo 0)
                    local written_back=$(cat /sys/kernel/debug/zswap/written_back_pages 2>/dev/null || echo 0)
                    
                    echo "Pool total size:  $(cat /sys/kernel/debug/zswap/pool_total_size 2>/dev/null || echo 'N/A')"
                    echo "Stored pages:     $stored"
                    echo "Written back:     $written_back"
                    
                    # Calculate writeback ratio
                    if [ $stored -gt 0 ]; then
                        local wb_ratio=$(awk "BEGIN {printf \"%.3f\", $written_back / $stored}")
                        echo "Writeback ratio:  $wb_ratio"
                        
                        if (( $(echo "$wb_ratio > 0.3" | bc -l 2>/dev/null || echo 0) )); then
                            echo -e "${RED}⚠️  Pool too small (writeback ratio > 0.3)${NC}"
                        else
                            echo -e "${GREEN}✅ Pool size adequate${NC}"
                        fi
                    fi
                else
                    echo "ZSWAP debugfs not available (mount debugfs or check permissions)"
                fi
                echo ""
            fi
        fi
        
        # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        # ZRAM STATISTICS
        # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        if [ -b /dev/zram0 ] && [ -f /sys/block/zram0/mm_stat ]; then
            echo -e "${BLUE}=== ZRAM Statistics ===${NC}"
            
            local mm_stat=$(cat /sys/block/zram0/mm_stat)
            local orig=$(echo $mm_stat | awk '{print $1}')
            local compr=$(echo $mm_stat | awk '{print $2}')
            local mem_used=$(echo $mm_stat | awk '{print $3}')
            local same_pages=$(echo $mm_stat | awk '{print $6}')
            
            echo "Original data:    $((orig / 1024 / 1024)) MB"
            echo "Compressed data:  $((compr / 1024 / 1024)) MB"
            echo "Memory used:      $((mem_used / 1024 / 1024)) MB"
            echo "Zero pages:       $same_pages"
            
            if [ $compr -gt 0 ]; then
                local ratio=$(awk "BEGIN {printf \"%.2f\", $orig / $compr}")
                echo "Compression ratio: ${ratio}:1"
            fi
            
            # Note about same_pages
            echo ""
            echo "Note: ZRAM same_pages only counts zero-filled pages"
            echo "      For identical content, use KSM instead"
            echo ""
        fi
        
        # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        # TOP MEMORY CONSUMERS
        # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        echo -e "${BLUE}=== Top Memory Consumers ===${NC}"
        ps aux --sort=-rss | head -6 | awk 'NR==1 || NR<=6 {printf "%-10s %6s %6s %s\n", $1, $4"%", $6/1024"M", $11}'
        echo ""
        
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Next update in ${INTERVAL}s..."
        
        sleep $INTERVAL
    done
}

print_usage() {
    cat <<EOF
Swap Monitor - Correct Metrics

Usage: $0 [OPTIONS]

Options:
  --help              Show this help message
  --interval N        Update interval in seconds (default: 5)
  --iterations N      Number of iterations (default: infinite)

Environment Variables:
  INTERVAL           Update interval (default: 5)
  ITERATIONS         Number of iterations (default: 0 = infinite)

Examples:
  $0                         # Monitor with 5s interval
  $0 --interval 10           # Monitor with 10s interval
  $0 --iterations 12         # Monitor for 12 iterations then exit
  INTERVAL=2 $0              # Monitor with 2s interval

Key Metrics Explained:
  pgmajfault    - Page faults requiring disk I/O (>100/s = concern)
  pswpin/pswpout - Swap I/O from/to disk (swap-specific)
  PSI full avg10 - % time all tasks stalled (>5% = severe)
  ZSWAP writeback ratio - written_back/stored (>0.3 = pool too small)

Why NOT vmstat si:
  vmstat 'si' counts ALL swap-ins including fast ZSWAP RAM pool hits!
  This makes it useless for identifying real disk I/O bottlenecks.
  Use pgmajfault instead for accurate disk activity monitoring.

EOF
}

main() {
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --help)
                print_usage
                exit 0
                ;;
            --interval)
                INTERVAL="$2"
                shift 2
                ;;
            --iterations)
                ITERATIONS="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
    
    # Validate interval
    if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [ "$INTERVAL" -lt 1 ]; then
        echo "Error: Invalid interval: $INTERVAL"
        exit 1
    fi
    
    monitor_loop
}

main "$@"
