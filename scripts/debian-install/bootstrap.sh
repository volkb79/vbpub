#!/bin/bash
# System Setup Bootstrap for Debian
# Full system initialization including swap, user config, benchmarking
# MUST BE UNDER 10KB for netcup init script compatibility
# Usage: curl -fsSL URL | bash
# Or: curl -fsSL URL | SWAP_ARCH=3 RUN_GEEKBENCH=yes bash

set -euo pipefail

# Debug mode
DEBUG_MODE="${DEBUG_MODE:-no}"
if [ "$DEBUG_MODE" = "yes" ]; then
    set -x
fi
# Force Python unbuffered output for benchmark
export PYTHONUNBUFFERED=1

# Configuration
REPO_URL="${REPO_URL:-https://github.com/volkb79/vbpub.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
CLONE_DIR="${CLONE_DIR:-/opt/vbpub}"
SCRIPT_DIR="${CLONE_DIR}/scripts/debian-install"
LOG_DIR="${LOG_DIR:-/var/log/debian-install}"
LOG_FILE="${LOG_DIR}/bootstrap-$(date +%Y%m%d-%H%M%S).log"

# Swap configuration (NEW NAMING CONVENTION)
# RAM-based swap
SWAP_RAM_SOLUTION="${SWAP_RAM_SOLUTION:-auto}"  # zram, zswap, none (auto-detected if not set)
SWAP_RAM_TOTAL_GB="${SWAP_RAM_TOTAL_GB:-auto}"  # RAM dedicated to compression (auto = calculated)
ZRAM_COMPRESSOR="${ZRAM_COMPRESSOR:-zstd}"  # lz4, zstd, lzo-rle
ZRAM_ALLOCATOR="${ZRAM_ALLOCATOR:-zsmalloc}"  # zsmalloc, z3fold, zbud
ZRAM_PRIORITY="${ZRAM_PRIORITY:-100}"  # Priority for ZRAM (higher = preferred)
ZSWAP_COMPRESSOR="${ZSWAP_COMPRESSOR:-zstd}"  # lz4, zstd, lzo-rle
ZSWAP_ZPOOL="${ZSWAP_ZPOOL:-z3fold}"  # z3fold, zbud, zsmalloc

# Disk-based swap
SWAP_BACKING_TYPE="${SWAP_BACKING_TYPE:-auto}"  # files_in_root, partitions_swap, partitions_zvol, files_in_partitions, none (auto-detected if not set)
SWAP_DISK_TOTAL_GB="${SWAP_DISK_TOTAL_GB:-auto}"  # Total disk-based swap (auto = calculated)
SWAP_STRIPE_WIDTH="${SWAP_STRIPE_WIDTH:-8}"  # Number of parallel swap devices (for I/O striping)
SWAP_PRIORITY="${SWAP_PRIORITY:-10}"  # Priority for disk swap (lower than RAM)
EXTEND_ROOT="${EXTEND_ROOT:-yes}"  # Default to yes - expand root partition when using partition-based swap

# ZFS-specific
ZFS_POOL="${ZFS_POOL:-tank}"

# Bootstrap options
RUN_USER_CONFIG="${RUN_USER_CONFIG:-yes}"
RUN_APT_CONFIG="${RUN_APT_CONFIG:-yes}"
RUN_JOURNALD_CONFIG="${RUN_JOURNALD_CONFIG:-yes}"
RUN_DOCKER_INSTALL="${RUN_DOCKER_INSTALL:-yes}"
RUN_GEEKBENCH="${RUN_GEEKBENCH:-yes}"
RUN_BENCHMARKS="${RUN_BENCHMARKS:-yes}"
BENCHMARK_DURATION="${BENCHMARK_DURATION:-5}"  # Duration in seconds for each benchmark test
SEND_SYSINFO="${SEND_SYSINFO:-yes}"

# Telegram
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }
log_debug() { 
    if [ "$DEBUG_MODE" = "yes" ]; then
        echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
    fi
}

# Helper function to run commands with comprehensive logging
run_logged() {
    local cmd="$1"
    local description="${2:-Running command}"
    
    log_debug "==> $description"
    log_debug "Command: $cmd"
    
    local output
    local exit_code
    
    if output=$($cmd 2>&1); then
        exit_code=$?
    else
        exit_code=$?
    fi
    
    if [ "$DEBUG_MODE" = "yes" ]; then
        echo "$output" | tee -a "$LOG_FILE"
    else
        echo "$output" >> "$LOG_FILE"
    fi
    
    log_debug "Exit code: $exit_code"
    
    return $exit_code
}

# Check if root partition needs expansion before main operations
check_and_expand_root_early() {
    log_info "==> Checking if root partition expansion is needed"
    
    # Get available space
    local avail_kb=$(df -k / | tail -1 | awk '{print $4}')
    local avail_gb=$((avail_kb / 1024 / 1024))
    local original_avail_gb=$avail_gb  # Save original value for reporting
    
    log_info "Available disk space: ${avail_gb}GB"
    
    # If we have less than 10GB available, check if we can expand
    if [ "$avail_gb" -lt 10 ]; then
        log_warn "Low available space (${avail_gb}GB) - checking for expansion opportunity"
        
        # Find root partition and disk
        local root_partition=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
        if [ -z "$root_partition" ]; then
            log_warn "Could not determine root partition - skipping early expansion"
            return 0
        fi
        
        local root_disk=$(lsblk -no PKNAME "$root_partition" 2>/dev/null | head -1)
        if [ -z "$root_disk" ]; then
            log_warn "Could not determine root disk - skipping early expansion"
            return 0
        fi
        
        # Get disk and partition sizes
        local disk_size_sectors=$(blockdev --getsz "/dev/$root_disk" 2>/dev/null || echo "0")
        local disk_total_gb=$((disk_size_sectors / 2048 / 1024))
        
        log_info "Total disk capacity: ${disk_total_gb}GB"
        
        # Check if disk is much larger than available space (indicating unexpanded root)
        if [ "$disk_total_gb" -gt $((avail_gb * 3)) ]; then
            log_warn "⚠️  Root partition appears to be unexpanded (${avail_gb}GB used of ${disk_total_gb}GB disk)"
            log_warn "⚠️  Expanding root partition NOW to prevent 'No space left on device' errors"
            
            tg_send "⚠️ <b>Early Root Expansion Required</b>

Root partition is using only ${avail_gb}GB of ${disk_total_gb}GB disk.
Expanding root partition before continuing to prevent space issues..."
            
            # Expand root partition using online filesystem resize
            local fs_type=$(findmnt -n -o FSTYPE /)
            log_info "Root filesystem: $fs_type"
            
            # Get partition number and info
            local root_part_num=$(echo "$root_partition" | grep -oE '[0-9]+$')
            
            # Get current partition layout
            local root_start=$(sfdisk -d "/dev/$root_disk" 2>/dev/null | grep "^$root_partition" | sed -E 's/.*start= *([0-9]+).*/\1/')
            local root_size=$(sfdisk -d "/dev/$root_disk" 2>/dev/null | grep "^$root_partition" | sed -E 's/.*size= *([0-9]+).*/\1/')
            
            # Calculate free space
            local free_sectors=$((disk_size_sectors - root_start - root_size))
            local free_gb=$((free_sectors / 2048 / 1024))
            
            log_info "Unallocated space after root: ${free_gb}GB"
            
            if [ "$free_gb" -ge 5 ]; then
                log_info "Expanding root partition to use most of disk (leaving some space for swap)"
                
                # Calculate new root size - use 90% of remaining disk, leave 10% for swap
                local new_root_size_sectors=$((disk_size_sectors - root_start - (disk_size_sectors / 10)))
                
                # Backup partition table
                local backup_file="/tmp/ptable-early-backup-$(date +%s).dump"
                sfdisk --dump "/dev/$root_disk" > "$backup_file"
                log_info "Partition table backed up to: $backup_file"
                
                # Create modified partition table
                local ptable_new="/tmp/ptable-early-expand-$(date +%s).dump"
                {
                    # Copy header
                    grep -E "^(label|label-id|device|unit|first-lba|last-lba|sector-size):" "$backup_file"
                    echo ""
                    
                    # Process partitions
                    while IFS= read -r line; do
                        if [[ "$line" =~ ^/dev/ ]]; then
                            local part_num=$(echo "$line" | grep -oE '[0-9]+' | head -1)
                            if [ "$part_num" = "$root_part_num" ]; then
                                # Extend root partition
                                echo "$line" | sed -E "s/size= *[0-9]+/size=${new_root_size_sectors}/"
                            else
                                # Keep other partitions
                                echo "$line"
                            fi
                        fi
                    done < "$backup_file"
                } > "$ptable_new"
                
                # Write partition table
                log_info "Writing expanded partition table..."
                if sfdisk --force "/dev/$root_disk" < "$ptable_new" 2>&1 | tee -a "$LOG_FILE"; then
                    log_info "Partition table updated"
                else
                    log_error "Failed to update partition table"
                    return 1
                fi
                
                # Update kernel partition table
                sync
                sleep 2
                partx -u "/dev/$root_disk" 2>&1 | tee -a "$LOG_FILE" || true
                sync
                sleep 2
                
                # Resize filesystem
                log_info "Resizing ${fs_type} filesystem..."
                case "$fs_type" in
                    ext4|ext3|ext2)
                        resize2fs "$root_partition" 2>&1 | tee -a "$LOG_FILE"
                        ;;
                    xfs)
                        xfs_growfs / 2>&1 | tee -a "$LOG_FILE"
                        ;;
                    btrfs)
                        btrfs filesystem resize max / 2>&1 | tee -a "$LOG_FILE"
                        ;;
                    *)
                        log_error "Unsupported filesystem: $fs_type"
                        return 1
                        ;;
                esac
                
                # Check new available space
                avail_kb=$(df -k / | tail -1 | awk '{print $4}')
                avail_gb=$((avail_kb / 1024 / 1024))
                
                log_info "✓ Root partition expanded - now ${avail_gb}GB available"
                tg_send "✅ <b>Root Expansion Complete</b>

Root partition expanded successfully.
Available space: ${avail_gb}GB (was ${original_avail_gb}GB before expansion)"
            else
                log_warn "Not enough unallocated space (${free_gb}GB) to expand - will proceed carefully"
            fi
        else
            log_info "Root partition size appears adequate relative to disk capacity"
        fi
    else
        log_info "Available space (${avail_gb}GB) is adequate - no early expansion needed"
    fi
    
    return 0
}

# Test Telegram connectivity
test_telegram() {
    log_info "Testing Telegram connectivity..."
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        log_warn "Telegram not configured (TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set)"
        return 1
    fi
    
    if [ ! -f "${SCRIPT_DIR}/telegram_client.py" ]; then
        log_error "telegram_client.py not found at ${SCRIPT_DIR}/telegram_client.py"
        return 1
    fi
    
    log_info "Testing bot connection..."
    if python3 "${SCRIPT_DIR}/telegram_client.py" --test 2>&1 | tee -a "$LOG_FILE"; then
        log_info "✓ Telegram test successful!"
        return 0
    else
        log_error "✗ Telegram test failed"
        return 1
    fi
}

# Helper function to send telegram messages using telegram_client.py
tg_send() {
    local msg="$1"
    [ -z "$TELEGRAM_BOT_TOKEN" ] && return 0
    [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    python3 "${SCRIPT_DIR}/telegram_client.py" --send "$msg" 2>/dev/null || true
}

# Helper function to send files via telegram
tg_send_file() {
    local file="$1"
    local caption="${2:-}"
    [ -z "$TELEGRAM_BOT_TOKEN" ] && return 0
    [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    if [ -n "$caption" ]; then
        python3 "${SCRIPT_DIR}/telegram_client.py" --file "$file" --caption "$caption" 2>/dev/null || true
    else
        python3 "${SCRIPT_DIR}/telegram_client.py" --file "$file" 2>/dev/null || true
    fi
}

# Collect system summary using unified system_info.py module
get_system_summary() {
    # Use system_info.py for consistent system information collection
    # This replaces the old bash implementation and uses the same module as sysinfo-notify.py
    if [ -f "${SCRIPT_DIR}/system_info.py" ]; then
        echo "Bootstrap Installation started."
        echo ""
        python3 "${SCRIPT_DIR}/system_info.py" --format text 2>> "$LOG_FILE" || {
            # Fallback to basic info if system_info.py fails
            echo "System: $(hostname -f 2>/dev/null || hostname) ($(hostname -I 2>/dev/null | awk '{print $1}'))"
            echo "RAM: $(free -h | awk '/^Mem:/{print $2}'), Cores: $(nproc)"
            echo "OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
        }
    else
        # Minimal fallback if system_info.py doesn't exist yet
        echo "Bootstrap Installation started."
        echo "System: $(hostname) - $(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
}

# Install essential packages early
install_essential_packages() {
    log_info "==> Installing essential packages"
    
    export DEBIAN_FRONTEND=noninteractive
    
    # Core utilities
    local core_packages="ca-certificates gnupg lsb-release curl wget git vim less jq bash-completion"
    
    # Network tools
    local network_packages="netcat-traditional iputils-ping dnsutils iproute2"
    
    # Additional useful tools
    local additional_packages="ripgrep fd-find tree fzf tldr httpie"
    
    # Benchmark/system tools
    local system_packages="fio sysstat python3-matplotlib"
    
    log_info "Installing core packages..."
    apt-get update -qq
    apt-get install -y -qq $core_packages $network_packages $system_packages || log_warn "Some core packages failed to install"
    
    log_info "Installing additional packages..."
    apt-get install -y -qq $additional_packages 2>/dev/null || log_warn "Some additional packages unavailable (non-critical)"
    
    # Install yq (go-based, not the old Python version)
    if ! command -v yq >/dev/null 2>&1; then
        log_info "Installing yq (go-based) from GitHub..."
        if wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq; then
            chmod +x /usr/local/bin/yq
            log_info "✓ yq installed"
        else
            log_warn "Failed to install yq"
        fi
    fi
    
    log_info "✓ Essential packages installed"
}

print_bootstrap_summary() {
    log_info ""
    log_info "=========================================="
    log_info "  BOOTSTRAP COMPLETE - SUMMARY"
    log_info "=========================================="
    log_info ""
    
    # System info
    local hostname=$(hostname)
    local ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    local ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    log_info "✓ System configured: ${hostname} (${ip})"
    log_info "✓ RAM: ${ram_gb}GB"
    
    # Swap configuration
    if [ -n "${SWAP_RAM_SOLUTION:-}" ]; then
        log_info "✓ Swap: ${SWAP_RAM_SOLUTION}"
    fi
    
    # Docker version
    if command -v docker >/dev/null 2>&1; then
        local docker_version=$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')
        log_info "✓ Docker: ${docker_version}"
    fi
    
    log_info ""
    log_info "Key Reports:"
    
    # Find most recent reports
    local benchmark_summary=$(ls -t /var/log/debian-install/benchmark-summary-*.txt 2>/dev/null | head -1)
    local swap_config=$(ls -t /var/log/debian-install/swap-config-decisions-*.txt 2>/dev/null | head -1)
    
    if [ -n "$benchmark_summary" ] && [ -f "$benchmark_summary" ]; then
        log_info "  • Benchmark: $benchmark_summary"
    fi
    
    if [ -n "$swap_config" ] && [ -f "$swap_config" ]; then
        log_info "  • Swap Config: $swap_config"
    fi
    
    log_info "  • Full Log: $LOG_FILE"
    log_info ""
    log_info "Next Steps:"
    log_info "  1. Review benchmark report for performance insights"
    log_info "  2. Reboot to apply all changes"
    log_info "  3. Monitor: ./swap-monitor.sh (if available)"
    log_info ""
}

main() {
    mkdir -p "$LOG_DIR"
    log_info "Debian System Setup Bootstrap"
    log_info "Log: $LOG_FILE"

    # Send system summary
    log_info "==> Collecting system summary"
    SYSTEM_SUMMARY=$(get_system_summary)
    echo "$SYSTEM_SUMMARY" | tee -a "$LOG_FILE"
    tg_send "$SYSTEM_SUMMARY"
    
    if [ "$EUID" -ne 0 ]; then log_error "Must run as root"; exit 1; fi
    
    # Check and expand root partition if needed BEFORE any apt operations
    # This prevents "No space left on device" errors during bootstrap
    check_and_expand_root_early
    
    # Install git first
    if ! command -v git >/dev/null 2>&1; then
        log_info "Installing git..."
        apt-get update -qq && apt-get install -y -qq git
    fi
    
    # Clone/update repo
    if [ -d "$CLONE_DIR/.git" ]; then
        log_info "Updating repository..."
        cd "$CLONE_DIR" && git fetch origin && git reset --hard "origin/$REPO_BRANCH"
    else
        log_info "Cloning repository..."
        rm -rf "$CLONE_DIR" && git clone -b "$REPO_BRANCH" "$REPO_URL" "$CLONE_DIR"
    fi
    
    # Make scripts executable
    chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.py 2>/dev/null || true
    cd "$SCRIPT_DIR"
    
    # Test Telegram connectivity if configured
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        test_telegram || log_warn "Telegram test failed, but continuing with bootstrap"
        
        # Send BEFORE system info
        log_info "==> Sending system info (BEFORE setup)"
        ./sysinfo-notify.py --notify --caption "📊 System Info (BEFORE setup)" 2>&1 | tee -a "$LOG_FILE" || true
    fi
    
    # Configure APT repositories BEFORE installing packages
    if [ "$RUN_APT_CONFIG" = "yes" ]; then
        log_info "==> Configuring APT repositories (before package installation)"
        if ./configure-apt.sh 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ APT configured"
        else
            log_warn "APT config had issues (non-critical, continuing)"
        fi
    else
        log_info "==> APT configuration skipped (RUN_APT_CONFIG=$RUN_APT_CONFIG)"
    fi
    
    # Install essential packages early (after APT configuration)
    install_essential_packages
    
    # Export all config (new naming convention)
    export SWAP_RAM_SOLUTION SWAP_RAM_TOTAL_GB
    export ZRAM_COMPRESSOR ZRAM_ALLOCATOR ZRAM_PRIORITY
    export ZSWAP_COMPRESSOR ZSWAP_ZPOOL
    export SWAP_DISK_TOTAL_GB SWAP_BACKING_TYPE SWAP_BACKING_TYPE_EXPLICIT SWAP_STRIPE_WIDTH
    export SWAP_PRIORITY EXTEND_ROOT
    export ZFS_POOL
    export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID LOG_FILE
    export DEBUG_MODE

    
    # Run benchmarks BEFORE swap setup for smart auto-configuration
    if [ "$RUN_BENCHMARKS" = "yes" ]; then
        log_info "==> Running system benchmarks (for smart swap auto-configuration)"
        BENCHMARK_DURATION="${BENCHMARK_DURATION:-5}"  # Default to 5 seconds per test
        BENCHMARK_OUTPUT="/tmp/benchmark-results-$(date +%Y%m%d-%H%M%S).json"
        BENCHMARK_CONFIG="/tmp/benchmark-optimal-config.sh"
        
        # Run benchmark with telegram notification if configured, and export optimal config
        if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            BENCHMARK_ARGS="--test-all --duration $BENCHMARK_DURATION --output $BENCHMARK_OUTPUT --shell-config $BENCHMARK_CONFIG --telegram"
        else
            BENCHMARK_ARGS="--test-all --duration $BENCHMARK_DURATION --output $BENCHMARK_OUTPUT --shell-config $BENCHMARK_CONFIG"
        fi
        
        if ./benchmark.py $BENCHMARK_ARGS 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Benchmarks complete"
            # Benchmark results are automatically sent via Telegram if configured
            # Optimal configuration exported to $BENCHMARK_CONFIG for use by setup-swap.sh
            export SWAP_BENCHMARK_CONFIG="$BENCHMARK_CONFIG"
        else
            log_warn "Benchmarks had issues (non-critical, continuing)"
        fi
    else
        log_info "==> Benchmarks skipped (RUN_BENCHMARKS=$RUN_BENCHMARKS)"
    fi

    # Benchmark results will be used by setup-swap.sh to optimize swap configuration
    # (compressor, allocator, stripe width, page-cluster)
    
    # Run swap setup
    log_info "==> Configuring swap"
    if ./setup-swap.sh 2>&1 | tee -a "$LOG_FILE"; then
        log_info "✓ Swap configured"
    else
        log_error "✗ Swap config failed"
    fi
    
    # Sync and send log file
    sync
    tg_send_file "$LOG_FILE" "Swap Configuration Log attached"
    
    # User configuration
    if [ "$RUN_USER_CONFIG" = "yes" ]; then
        log_info "==> Configuring users"
        if ./configure-users.sh 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Users configured"
        else
            log_warn "User config had issues"
        fi
    else
        log_info "==> User configuration skipped (RUN_USER_CONFIG=$RUN_USER_CONFIG)"
    fi
    
    # Journald configuration
    if [ "$RUN_JOURNALD_CONFIG" = "yes" ]; then
        log_info "==> Configuring journald"
        if ./configure-journald.sh 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Journald configured"
        else
            log_warn "Journald config had issues"
        fi
    else
        log_info "==> Journald configuration skipped (RUN_JOURNALD_CONFIG=$RUN_JOURNALD_CONFIG)"
    fi
    
    # Docker installation
    if [ "$RUN_DOCKER_INSTALL" = "yes" ]; then
        log_info "==> Installing Docker"
        if ./install-docker.sh 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Docker installed"
        else
            log_warn "Docker installation had issues"
        fi
    else
        log_info "==> Docker installation skipped (RUN_DOCKER_INSTALL=$RUN_DOCKER_INSTALL)"
    fi
    
    # Geekbench
    if [ "$RUN_GEEKBENCH" = "yes" ]; then
        log_info "==> Running Geekbench (5-10 min)"
        GEEKBENCH_START=$(date +%s)
        if ./sysinfo-notify.py --geekbench-only 2>&1 | tee -a "$LOG_FILE"; then
            GEEKBENCH_END=$(date +%s)
            GEEKBENCH_DURATION=$((GEEKBENCH_END - GEEKBENCH_START))
            log_info "✓ Geekbench complete (took ${GEEKBENCH_DURATION}s)"
            # Geekbench results are automatically sent via telegram by sysinfo-notify.py
        else
            GEEKBENCH_EXIT_CODE=$?
            GEEKBENCH_END=$(date +%s)
            GEEKBENCH_DURATION=$((GEEKBENCH_END - GEEKBENCH_START))
            log_error "✗ Geekbench failed (exit code: $GEEKBENCH_EXIT_CODE, took ${GEEKBENCH_DURATION}s)"
            log_error "Check logs for details: $LOG_FILE"
            
            # Send failure notification via Telegram
            if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
                GEEKBENCH_ERROR_MSG="❌ <b>Geekbench Failed</b>

Exit code: ${GEEKBENCH_EXIT_CODE}
Duration: ${GEEKBENCH_DURATION}s
Log: ${LOG_FILE}

Possible causes:
• Download failure (network/URL issue)
• Extraction failure (corrupt archive)
• Runtime failure (insufficient resources)
• Timeout (benchmark took >15 min)

Check the log file for detailed error messages."
                tg_send "$GEEKBENCH_ERROR_MSG"
            fi
        fi
    else
        log_info "==> Geekbench skipped (RUN_GEEKBENCH=$RUN_GEEKBENCH)"
    fi
    
    # System info (AFTER all modifications)
    if [ "$SEND_SYSINFO" = "yes" ] && [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        log_info "==> Sending system info (AFTER setup)"
        # System information is collected using the unified system_info.py module.
        # This module is shared between:
        # - get_system_summary(): Uses system_info.py with --format text for bootstrap summary
        # - sysinfo-notify.py: Uses system_info.py with HTML formatting for telegram notifications
        # This ensures DRY (Don't Repeat Yourself) - single source of truth for system info collection.
        
        # Send formatted notification via telegram with AFTER caption
        ./sysinfo-notify.py --notify --caption "📊 System Info (AFTER setup - root partition still shows original size before reboot)" 2>&1 | tee -a "$LOG_FILE" || true
        
        # Optionally save detailed info to file and send as attachment
        SYSINFO_FILE="/tmp/system-info-$(date +%Y%m%d-%H%M%S).json"
        ./system_info.py --output "$SYSINFO_FILE" 2>&1 || true
        
        if [ -f "$SYSINFO_FILE" ]; then
            log_info "Sending detailed system info as attachment..."
            tg_send_file "$SYSINFO_FILE" "📊 Detailed System Information (JSON)"
            rm -f "$SYSINFO_FILE"
        fi
    fi
    
    # Print bootstrap summary
    print_bootstrap_summary
    
    log_info "🎉 System setup complete!"
    log_info "Log: $LOG_FILE"
    
    # Send completion message with log file as attachment
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -f "$LOG_FILE" ]; then
        log_info "Sending final log file as attachment..."
        sync
        tg_send_file "$LOG_FILE" "📋 Bootstrap Complete - Full Log"
    fi
}

main "$@"
