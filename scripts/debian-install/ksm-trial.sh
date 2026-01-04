#!/bin/bash
# KSM (Kernel Samepage Merging) Effectiveness Trial
# Tests if KSM would benefit the system
# WARNING: Most applications don't use MADV_MERGEABLE

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

print_banner() {
    cat <<'EOF'
╔═══════════════════════════════════════════════════════╗
║   KSM (Kernel Samepage Merging) Trial                ║
║   Test effectiveness on your system                   ║
╚═══════════════════════════════════════════════════════╝
EOF
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_ksm_available() {
    if [ ! -d /sys/kernel/mm/ksm ]; then
        log_error "KSM not available in this kernel"
        exit 1
    fi
}

print_ksm_stats() {
    local label="$1"
    
    echo ""
    echo -e "${BOLD}$label${NC}"
    
    local pages_shared=$(cat /sys/kernel/mm/ksm/pages_shared 2>/dev/null || echo 0)
    local pages_sharing=$(cat /sys/kernel/mm/ksm/pages_sharing 2>/dev/null || echo 0)
    local pages_unshared=$(cat /sys/kernel/mm/ksm/pages_unshared 2>/dev/null || echo 0)
    local pages_volatile=$(cat /sys/kernel/mm/ksm/pages_volatile 2>/dev/null || echo 0)
    
    echo "  pages_shared:   $pages_shared (unique shared pages)"
    echo "  pages_sharing:  $pages_sharing (total deduplicated instances)"
    echo "  pages_unshared: $pages_unshared (checked but unique)"
    echo "  pages_volatile: $pages_volatile (changed during scan)"
    
    # Calculate memory saved
    if [ "$pages_shared" -gt 0 ] && [ "$pages_sharing" -gt 0 ]; then
        local saved_pages=$((pages_sharing - pages_shared))
        local saved_kb=$((saved_pages * 4))
        local saved_mb=$(echo "scale=2; $saved_kb / 1024" | bc)
        
        echo ""
        echo -e "  ${GREEN}Memory saved: ${saved_mb} MB${NC}"
        echo "  (($pages_sharing - $pages_shared) × 4KB = ${saved_kb}KB)"
    else
        echo ""
        echo -e "  ${YELLOW}No memory saved (no deduplication)${NC}"
    fi
}

# Calculate effectiveness
calculate_effectiveness() {
    local pages_shared=$(cat /sys/kernel/mm/ksm/pages_shared 2>/dev/null || echo 0)
    local pages_sharing=$(cat /sys/kernel/mm/ksm/pages_sharing 2>/dev/null || echo 0)
    
    if [ "$pages_sharing" -eq 0 ]; then
        echo "0.00"
        return
    fi
    
    # Total memory in KB
    local mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    
    # Saved memory in KB
    local saved_pages=$((pages_sharing - pages_shared))
    local saved_kb=$((saved_pages * 4))
    
    # Percentage - use awk instead of bc
    local effectiveness=$(awk "BEGIN {printf \"%.2f\", 100.0 * $saved_kb / $mem_total_kb}")
    echo "$effectiveness"
}

main() {
    print_banner
    
    echo ""
    log_warn "IMPORTANT: KSM only works with applications that use MADV_MERGEABLE"
    log_warn "Most standard applications DON'T use this flag!"
    echo ""
    log_info "Applications that commonly use MADV_MERGEABLE:"
    echo "  ✓ QEMU/KVM virtual machines"
    echo "  ✓ Some container runtimes"
    echo "  ✓ Redis (with patch)"
    echo ""
    log_info "Applications that DON'T use it:"
    echo "  ✗ Databases (MySQL, PostgreSQL)"
    echo "  ✗ Web servers (nginx, Apache)"
    echo "  ✗ Most standard applications"
    echo ""
    
    check_root
    check_ksm_available
    
    # Save original state
    local original_run=$(cat /sys/kernel/mm/ksm/run)
    
    log_step "Saving original KSM state"
    log_info "Original KSM run state: $original_run"
    
    # Get baseline stats
    print_ksm_stats "Baseline (before enabling KSM)"
    
    # Enable KSM
    log_step "Enabling KSM for trial"
    echo 1 > /sys/kernel/mm/ksm/run
    
    # Configure for faster scanning
    log_info "Configuring KSM for trial (aggressive scanning)..."
    echo 1000 > /sys/kernel/mm/ksm/pages_to_scan
    echo 100 > /sys/kernel/mm/ksm/sleep_millisecs
    
    # Wait for scans
    log_step "Running 3 full scans (this may take 30-60 seconds)..."
    
    for i in {1..3}; do
        echo -n "  Scan $i/3..."
        sleep 10
        echo " done"
    done
    
    # Get results
    print_ksm_stats "After KSM Trial (3 scans)"
    
    # Calculate effectiveness
    local effectiveness=$(calculate_effectiveness)
    
    # Validate effectiveness is a valid number
    if ! [[ "$effectiveness" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        effectiveness="0.00"
    fi
    
    echo ""
    log_step "Analysis"
    
    echo ""
    echo "Effectiveness: ${effectiveness}% of total RAM saved"
    echo ""
    
    # Provide recommendation
    if (( $(awk "BEGIN {print ($effectiveness < 0.5)}") )); then
        log_warn "KSM appears INEFFECTIVE (<0.5% memory saved)"
        echo ""
        echo "Recommendation: ${RED}Do NOT enable KSM${NC}"
        echo "  • KSM overhead not worth minimal savings"
        echo "  • Your applications likely don't use MADV_MERGEABLE"
        echo "  • Focus on other memory optimizations (ZSWAP, ZRAM)"
    elif (( $(awk "BEGIN {print ($effectiveness < 2)}") )); then
        log_warn "KSM shows MINIMAL benefit (<2% memory saved)"
        echo ""
        echo "Recommendation: ${YELLOW}KSM probably not worth it${NC}"
        echo "  • Small benefit may not justify overhead"
        echo "  • Consider only if memory is critically constrained"
    elif (( $(awk "BEGIN {print ($effectiveness < 10)}") )); then
        log_info "KSM shows MODERATE benefit (2-10% memory saved)"
        echo ""
        echo "Recommendation: ${YELLOW}Consider enabling KSM${NC}"
        echo "  • Moderate benefit for memory-constrained systems"
        echo "  • Monitor CPU overhead"
    else
        log_info "KSM shows SIGNIFICANT benefit (>10% memory saved)"
        echo ""
        echo "Recommendation: ${GREEN}Enable KSM${NC}"
        echo "  • Substantial memory savings"
        echo "  • You likely have VMs or containers using MADV_MERGEABLE"
    fi
    
    echo ""
    log_step "To enable KSM permanently:"
    echo ""
    echo "  echo 1 > /sys/kernel/mm/ksm/run"
    echo "  echo 100 > /sys/kernel/mm/ksm/sleep_millisecs"
    echo "  echo 1000 > /sys/kernel/mm/ksm/pages_to_scan"
    echo ""
    echo "  # Add to systemd service for persistence"
    echo "  cat > /etc/systemd/system/ksm.service <<EOF"
    echo "  [Unit]"
    echo "  Description=Enable KSM"
    echo "  After=multi-user.target"
    echo ""
    echo "  [Service]"
    echo "  Type=oneshot"
    echo "  ExecStart=/bin/bash -c 'echo 1 > /sys/kernel/mm/ksm/run && echo 1000 > /sys/kernel/mm/ksm/pages_to_scan && echo 100 > /sys/kernel/mm/ksm/sleep_millisecs'"
    echo ""
    echo "  [Install]"
    echo "  WantedBy=multi-user.target"
    echo "  EOF"
    echo ""
    echo "  systemctl enable ksm.service"
    echo "  systemctl start ksm.service"
    echo ""
    
    # Restore original state
    log_step "Restoring original KSM state"
    echo "$original_run" > /sys/kernel/mm/ksm/run
    log_info "KSM state restored to: $original_run"
    
    echo ""
    log_info "Trial complete!"
}

main "$@"
