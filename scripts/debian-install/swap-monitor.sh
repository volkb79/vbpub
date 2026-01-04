#!/bin/bash
#
# swap-monitor.sh - Real-time swap and memory monitoring
#
# Shows memory overview, ZRAM/ZSWAP status with compression ratios,
# swap device usage, correct pressure metrics, and top swapped processes
#
# Usage:
#   ./swap-monitor.sh           # Continuous monitoring (5s refresh)
#   ./swap-monitor.sh --once    # Single snapshot
#   ./swap-monitor.sh --json    # JSON output for external monitoring
#

set -euo pipefail

# Configuration
REFRESH_INTERVAL="${REFRESH_INTERVAL:-5}"
MODE="${1:-continuous}"

# Colors
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

header() {
    echo -e "${BOLD}${CYAN}$*${NC}"
}

print_memory_overview() {
    header "=== Memory Overview ==="
    free -h | grep -v "Swap:" || true
    echo ""
}

print_zram_status() {
    if [ ! -e /sys/block/zram0/disksize ]; then
        return 0
    fi
    
    header "=== ZRAM Status ==="
    
    # Basic info
    if command -v zramctl >/dev/null 2>&1; then
        zramctl
    fi
    
    # Detailed stats
    if [ -f /sys/block/zram0/mm_stat ]; then
        echo ""
        read -r orig_size comp_size mem_used mem_limit mem_max same_pages pages_compacted rest < /sys/block/zram0/mm_stat
        
        orig_mb=$((orig_size / 1024 / 1024))
        comp_mb=$((comp_size / 1024 / 1024))
        mem_mb=$((mem_used / 1024 / 1024))
        
        if [ "$comp_size" -gt 0 ]; then
            ratio=$(echo "scale=2; $orig_size / $comp_size" | bc)
        else
            ratio="N/A"
        fi
        
        echo "Original data: ${orig_mb}MB"
        echo "Compressed: ${comp_mb}MB"
        echo "Memory used: ${mem_mb}MB"
        echo "Compression ratio: ${ratio}x"
        echo "Same pages (zero): $same_pages"
        
        # Compression efficiency
        if [ "$orig_size" -gt 0 ]; then
            efficiency=$(echo "scale=2; (1 - $comp_size / $orig_size) * 100" | bc)
            echo "Space saved: ${efficiency}%"
        fi
    fi
    
    echo ""
}

print_zswap_status() {
    if [ ! -e /sys/module/zswap/parameters/enabled ]; then
        return 0
    fi
    
    local enabled=$(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo "N")
    
    if [ "$enabled" != "Y" ]; then
        return 0
    fi
    
    header "=== ZSWAP Status ==="
    
    echo "Enabled: $enabled"
    
    if [ -e /sys/module/zswap/parameters/compressor ]; then
        echo "Compressor: $(cat /sys/module/zswap/parameters/compressor 2>/dev/null || echo 'N/A')"
        echo "Zpool: $(cat /sys/module/zswap/parameters/zpool 2>/dev/null || echo 'N/A')"
        echo "Max pool: $(cat /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || echo 'N/A')%"
    fi
    
    # Debug stats if available
    if [ -d /sys/kernel/debug/zswap ]; then
        echo ""
        local pool_total=$(cat /sys/kernel/debug/zswap/pool_total_size 2>/dev/null || echo "0")
        local pool_pages=$(cat /sys/kernel/debug/zswap/pool_pages 2>/dev/null || echo "0")
        local stored_pages=$(cat /sys/kernel/debug/zswap/stored_pages 2>/dev/null || echo "0")
        local writeback=$(cat /sys/kernel/debug/zswap/written_back_pages 2>/dev/null || echo "0")
        
        pool_mb=$((pool_total / 1024 / 1024))
        
        echo "Pool size: ${pool_mb}MB"
        echo "Pool pages: $pool_pages"
        echo "Stored pages: $stored_pages"
        echo "Written back: $writeback"
        
        # Writeback ratio
        if [ "$pool_pages" -gt 0 ]; then
            writeback_ratio=$(echo "scale=2; $writeback * 100 / $pool_pages" | bc)
            echo "Writeback ratio: ${writeback_ratio}%"
            
            # Color code the ratio
            if [ "$(echo "$writeback_ratio < 1" | bc)" -eq 1 ]; then
                echo -e "  ${GREEN}✓ Excellent (<1%)${NC}"
            elif [ "$(echo "$writeback_ratio < 10" | bc)" -eq 1 ]; then
                echo -e "  ${YELLOW}○ Acceptable (1-10%)${NC}"
            else
                echo -e "  ${RED}✗ High pressure (>10%)${NC}"
            fi
        fi
    fi
    
    echo ""
}

print_swap_devices() {
    header "=== Swap Devices ==="
    swapon --show
    echo ""
    
    # Per-device stats
    if [ -f /proc/swaps ]; then
        echo "Detailed usage:"
        tail -n +2 /proc/swaps | while read -r filename type size used priority; do
            if [ "$size" -gt 0 ]; then
                used_pct=$((used * 100 / size))
                printf "  %-20s  %6s KB / %6s KB  (%3d%%)\n" \
                    "$filename" "$used" "$size" "$used_pct"
            fi
        done
        echo ""
    fi
}

print_pressure_metrics() {
    header "=== Memory Pressure Metrics (Use These!) ==="
    
    # 1. Major page faults
    if [ -f /proc/vmstat ]; then
        local pgmajfault=$(grep "^pgmajfault " /proc/vmstat | awk '{print $2}')
        echo "Major page faults: $pgmajfault (cumulative)"
        
        if [ -n "${PREV_PGMAJFAULT:-}" ]; then
            local delta=$((pgmajfault - PREV_PGMAJFAULT))
            local rate=$((delta / REFRESH_INTERVAL))
            echo "  Rate: ${rate}/sec"
            
            if [ "$rate" -lt 10 ]; then
                echo -e "  ${GREEN}✓ Excellent${NC}"
            elif [ "$rate" -lt 100 ]; then
                echo -e "  ${YELLOW}○ Acceptable${NC}"
            else
                echo -e "  ${RED}✗ High disk I/O${NC}"
            fi
        fi
        export PREV_PGMAJFAULT=$pgmajfault
    fi
    
    # 2. PSI (Pressure Stall Information)
    if [ -f /proc/pressure/memory ]; then
        echo ""
        echo "PSI Memory Pressure:"
        cat /proc/pressure/memory | while read -r line; do
            echo "  $line"
        done
        
        # Extract full pressure
        local full_avg=$(grep "full avg10=" /proc/pressure/memory | sed 's/.*avg10=\([^ ]*\).*/\1/')
        if [ -n "$full_avg" ]; then
            if [ "$(echo "$full_avg < 0.1" | bc 2>/dev/null || echo 0)" -eq 1 ]; then
                echo -e "  ${GREEN}✓ No memory stalls${NC}"
            elif [ "$(echo "$full_avg < 1" | bc 2>/dev/null || echo 0)" -eq 1 ]; then
                echo -e "  ${YELLOW}○ Minor stalls${NC}"
            else
                echo -e "  ${RED}✗ Significant stalls${NC}"
            fi
        fi
    fi
    
    # 3. vmstat swap activity (note the caveat)
    echo ""
    echo "Swap activity (vmstat):"
    echo "  NOTE: 'si' includes ZSWAP RAM hits (not just disk I/O)!"
    vmstat 1 2 | tail -1 | awk '{printf "  swap-in: %s KB/s, swap-out: %s KB/s\n", $7, $8}'
    
    echo ""
}

print_top_swapped_processes() {
    header "=== Top 10 Swapped Processes ==="
    
    {
        for pid in $(ps -eo pid --no-headers 2>/dev/null); do
            if [ -f "/proc/$pid/status" ]; then
                swap=$(awk '/^VmSwap:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")
                if [ "$swap" -gt 0 ] 2>/dev/null; then
                    cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
                    echo "$swap $pid $cmd"
                fi
            fi
        done
    } | sort -rn | head -10 | while read -r swap pid cmd; do
        swap_mb=$((swap / 1024))
        printf "  %6d MB  PID %-6s  %s\n" "$swap_mb" "$pid" "$cmd"
    done
    
    echo ""
}

print_json() {
    # JSON output for external monitoring
    cat << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "memory": $(free -b | awk '/^Mem:/ {printf "{\"total\":%d,\"used\":%d,\"free\":%d}", $2, $3, $4}'),
  "swap": $(free -b | awk '/^Swap:/ {printf "{\"total\":%d,\"used\":%d,\"free\":%d}", $2, $3, $4}'),
  "pgmajfault": $(grep "^pgmajfault " /proc/vmstat | awk '{print $2}'),
  "psi_memory": $(cat /proc/pressure/memory 2>/dev/null | grep "full avg10=" | sed 's/.*avg10=\([^ ]*\).*/\1/' || echo "null")
}
EOF
}

show_once() {
    clear
    echo "=== Swap Monitor - $(date) ==="
    echo ""
    print_memory_overview
    print_zram_status
    print_zswap_status
    print_swap_devices
    print_pressure_metrics
    print_top_swapped_processes
}

show_continuous() {
    while true; do
        show_once
        echo "Press Ctrl+C to exit. Refreshing in ${REFRESH_INTERVAL}s..."
        sleep "$REFRESH_INTERVAL"
    done
}

main() {
    case "$MODE" in
        --once)
            show_once
            ;;
        --json)
            print_json
            ;;
        continuous|*)
            show_continuous
            ;;
    esac
}

main
