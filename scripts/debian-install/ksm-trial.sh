#!/bin/bash
#
# ksm-trial.sh - KSM Trial and Recommendation Script
#
# Purpose: Temporarily enable KSM, run scans, report savings, provide recommendation
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

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_ksm_available() {
    local ksm_dir="/sys/kernel/mm/ksm"
    
    if [ ! -d "$ksm_dir" ]; then
        log_error "KSM not available in kernel"
        echo ""
        echo "KSM requires kernel configuration:"
        echo "  CONFIG_KSM=y"
        echo ""
        echo "Check your kernel:"
        echo "  grep CONFIG_KSM /boot/config-\$(uname -r)"
        exit 1
    fi
}

# Variables for saving original settings
ORIG_RUN=""
ORIG_PAGES=""
ORIG_SLEEP=""
RESTORE_ON_EXIT=true

save_original_settings() {
    log_info "Saving original KSM settings..."
    
    ORIG_RUN=$(cat /sys/kernel/mm/ksm/run)
    ORIG_PAGES=$(cat /sys/kernel/mm/ksm/pages_to_scan)
    ORIG_SLEEP=$(cat /sys/kernel/mm/ksm/sleep_millisecs)
    
    echo "  run:              $ORIG_RUN"
    echo "  pages_to_scan:    $ORIG_PAGES"
    echo "  sleep_millisecs:  $ORIG_SLEEP"
    echo ""
}

restore_original_settings() {
    if [ "$RESTORE_ON_EXIT" = "true" ]; then
        log_info "Restoring original KSM settings..."
        echo "$ORIG_RUN" > /sys/kernel/mm/ksm/run
        echo "$ORIG_PAGES" > /sys/kernel/mm/ksm/pages_to_scan
        echo "$ORIG_SLEEP" > /sys/kernel/mm/ksm/sleep_millisecs
        log_info "Settings restored"
    fi
}

cleanup() {
    echo ""
    restore_original_settings
}

trap cleanup EXIT

enable_aggressive_ksm() {
    log_section "Enabling Aggressive KSM"
    
    echo "Configuring KSM for fast scanning..."
    echo "  pages_to_scan:   5000 (high)"
    echo "  sleep_millisecs: 10 (low)"
    echo "  run:             1 (enabled)"
    echo ""
    
    echo 5000 > /sys/kernel/mm/ksm/pages_to_scan
    echo 10 > /sys/kernel/mm/ksm/sleep_millisecs
    echo 1 > /sys/kernel/mm/ksm/run
    
    log_info "KSM enabled with aggressive settings"
}

wait_for_scans() {
    local num_scans=$1
    
    log_section "Waiting for $num_scans Full Scans"
    
    local initial_scans=$(cat /sys/kernel/mm/ksm/full_scans)
    local target_scans=$((initial_scans + num_scans))
    
    echo "Initial scans: $initial_scans"
    echo "Target scans:  $target_scans"
    echo ""
    
    log_info "This may take several minutes depending on memory size..."
    echo ""
    
    local dots=0
    while [ $(cat /sys/kernel/mm/ksm/full_scans) -lt $target_scans ]; do
        local current=$(cat /sys/kernel/mm/ksm/full_scans)
        local completed=$((current - initial_scans))
        
        # Progress indicator
        printf "\r  Progress: %d/%d scans complete" "$completed" "$num_scans"
        
        # Rotating dots
        dots=$(( (dots + 1) % 4 ))
        printf " %s" "$(printf '.%.0s' $(seq 1 $dots))   " | head -c 4
        
        sleep 5
    done
    
    echo ""
    echo ""
    log_info "Scans complete!"
}

analyze_results() {
    log_section "Analyzing Results"
    
    # Get statistics
    local shared=$(cat /sys/kernel/mm/ksm/pages_shared)
    local sharing=$(cat /sys/kernel/mm/ksm/pages_sharing)
    local unshared=$(cat /sys/kernel/mm/ksm/pages_unshared)
    local volatile=$(cat /sys/kernel/mm/ksm/pages_volatile)
    local scans=$(cat /sys/kernel/mm/ksm/full_scans)
    
    echo "KSM Statistics:"
    echo "  pages_shared:   $shared ($(($shared * 4 / 1024)) MB)"
    echo "  pages_sharing:  $sharing ($(($sharing * 4 / 1024)) MB)"
    echo "  pages_unshared: $unshared ($(($unshared * 4 / 1024)) MB)"
    echo "  pages_volatile: $volatile ($(($volatile * 4 / 1024)) MB)"
    echo "  full_scans:     $scans"
    echo ""
    
    if [ $shared -gt 0 ]; then
        local saved_kb=$((($sharing - $shared) * 4))
        local saved_mb=$(($saved_kb / 1024))
        local ratio=$(awk "BEGIN {printf \"%.2f\", $sharing / $shared}")
        
        echo -e "${GREEN}Memory Savings Detected!${NC}"
        echo "  Memory saved:       ${saved_mb} MB"
        echo "  Deduplication ratio: ${ratio}:1"
        
        # Calculate percentage saved
        local total_kb=$(($sharing * 4))
        if [ $total_kb -gt 0 ]; then
            local pct=$(awk "BEGIN {printf \"%.1f\", ($saved_kb * 100.0) / $total_kb}")
            echo "  Savings percentage:  ${pct}%"
        fi
        
        echo ""
        
        # Provide recommendation
        log_section "Recommendation"
        
        if [ $saved_mb -gt 100 ]; then
            echo -e "${GREEN}✅ RECOMMENDATION: Keep KSM enabled${NC}"
            echo ""
            echo "Rationale:"
            echo "  • Significant memory savings detected (>100 MB)"
            echo "  • Benefits outweigh CPU overhead"
            echo "  • Recommended for this workload"
            echo ""
            RECOMMENDATION="keep"
        elif [ $saved_mb -gt 20 ]; then
            echo -e "${YELLOW}⚠️  RECOMMENDATION: Consider keeping KSM enabled${NC}"
            echo ""
            echo "Rationale:"
            echo "  • Moderate memory savings (20-100 MB)"
            echo "  • Evaluate CPU vs memory trade-off"
            echo "  • May be beneficial depending on workload"
            echo ""
            echo "Consider:"
            echo "  • Monitor CPU usage with KSM enabled"
            echo "  • Adjust pages_to_scan and sleep_millisecs for lower overhead"
            echo "  • Re-evaluate after workload changes"
            echo ""
            RECOMMENDATION="consider"
        else
            echo -e "${RED}❌ RECOMMENDATION: Disable KSM${NC}"
            echo ""
            echo "Rationale:"
            echo "  • Low memory savings (<20 MB)"
            echo "  • Not worth CPU overhead"
            echo "  • Workload does not benefit from deduplication"
            echo ""
            RECOMMENDATION="disable"
        fi
    else
        echo -e "${YELLOW}No duplicate pages found${NC}"
        echo ""
        
        log_section "Recommendation"
        
        echo -e "${RED}❌ RECOMMENDATION: Disable KSM${NC}"
        echo ""
        echo "Rationale:"
        echo "  • No memory savings detected"
        echo "  • Your workload does not benefit from page deduplication"
        echo "  • KSM adds CPU overhead without benefit"
        echo ""
        echo "Possible reasons:"
        echo "  • Workload doesn't use mergeable memory (most processes don't)"
        echo "  • No VMs or containers with similar images"
        echo "  • Applications not marking pages as mergeable"
        echo ""
        RECOMMENDATION="disable"
    fi
}

prompt_action() {
    log_section "Action"
    
    echo "What would you like to do?"
    echo ""
    echo "  1. Keep KSM enabled (recommended settings)"
    echo "  2. Keep KSM enabled (aggressive settings - higher CPU)"
    echo "  3. Restore original settings"
    echo ""
    
    read -p "Enter choice [1-3]: " choice
    
    case "$choice" in
        1)
            log_info "Applying recommended KSM settings..."
            echo 1 > /sys/kernel/mm/ksm/run
            echo 1000 > /sys/kernel/mm/ksm/pages_to_scan
            echo 200 > /sys/kernel/mm/ksm/sleep_millisecs
            RESTORE_ON_EXIT=false
            log_info "KSM enabled with balanced settings"
            echo ""
            echo "Settings applied:"
            echo "  run:              1"
            echo "  pages_to_scan:    1000"
            echo "  sleep_millisecs:  200"
            ;;
        2)
            log_info "Keeping aggressive KSM settings..."
            RESTORE_ON_EXIT=false
            log_info "KSM remains with aggressive settings"
            echo ""
            echo "Current settings:"
            echo "  run:              $(cat /sys/kernel/mm/ksm/run)"
            echo "  pages_to_scan:    $(cat /sys/kernel/mm/ksm/pages_to_scan)"
            echo "  sleep_millisecs:  $(cat /sys/kernel/mm/ksm/sleep_millisecs)"
            ;;
        3)
            log_info "Will restore original settings on exit"
            ;;
        *)
            log_warn "Invalid choice - restoring original settings"
            ;;
    esac
    
    echo ""
}

print_usage() {
    cat <<EOF
KSM Trial Script

Usage: $0 [OPTIONS]

Options:
  --help          Show this help message
  --scans N       Number of full scans to perform (default: 3)
  --apply         Automatically apply recommendation without prompting
  --no-restore    Don't restore original settings (keep trial config)

Examples:
  $0                    # Run trial with 3 scans, prompt for action
  $0 --scans 5          # Run 5 scans before analysis
  $0 --apply            # Apply recommendation automatically
  $0 --no-restore       # Keep aggressive settings after trial

EOF
}

main() {
    local num_scans=3
    local auto_apply=false
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --help)
                print_usage
                exit 0
                ;;
            --scans)
                num_scans="$2"
                shift 2
                ;;
            --apply)
                auto_apply=true
                shift
                ;;
            --no-restore)
                RESTORE_ON_EXIT=false
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
    
    log_section "KSM Trial"
    
    echo "This script will:"
    echo "  1. Save current KSM settings"
    echo "  2. Enable aggressive KSM scanning"
    echo "  3. Wait for $num_scans full scans"
    echo "  4. Analyze memory savings"
    echo "  5. Provide recommendation"
    echo "  6. Optionally apply settings"
    echo ""
    
    if [ "$auto_apply" = "false" ]; then
        read -p "Press Enter to continue or Ctrl+C to abort... " dummy
    fi
    
    check_root
    check_ksm_available
    save_original_settings
    enable_aggressive_ksm
    wait_for_scans "$num_scans"
    analyze_results
    
    if [ "$auto_apply" = "true" ]; then
        log_info "Auto-applying recommendation: $RECOMMENDATION"
        case "$RECOMMENDATION" in
            keep|consider)
                echo 1 > /sys/kernel/mm/ksm/run
                echo 1000 > /sys/kernel/mm/ksm/pages_to_scan
                echo 200 > /sys/kernel/mm/ksm/sleep_millisecs
                RESTORE_ON_EXIT=false
                log_info "KSM enabled with recommended settings"
                ;;
            disable)
                log_info "Restoring original settings (likely disabled)"
                ;;
        esac
    else
        prompt_action
    fi
    
    log_section "Trial Complete"
    
    echo "KSM status:"
    echo "  run:              $(cat /sys/kernel/mm/ksm/run)"
    echo "  pages_to_scan:    $(cat /sys/kernel/mm/ksm/pages_to_scan)"
    echo "  sleep_millisecs:  $(cat /sys/kernel/mm/ksm/sleep_millisecs)"
    echo ""
    
    echo "To check KSM statistics later:"
    echo "  cat /sys/kernel/mm/ksm/pages_*"
    echo "  bash /root/analyze-memory.sh"
    echo ""
}

main "$@"
