#!/bin/bash
# System Setup Bootstrap for Debian
# Full system initialization including swap, user config, benchmarking
# Note: netcup init-script payloads can be size-limited (~10KB). If you need that,
# use a tiny shim that curls this full bootstrap script.
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
ZSWAP_ZPOOL="${ZSWAP_ZPOOL:-zbud}"  # zbud (most reliable), z3fold, zsmalloc

# Disk-based swap
SWAP_BACKING_TYPE="${SWAP_BACKING_TYPE:-auto}"  # files_in_root, partitions_swap, partitions_zvol, files_in_partitions, none (auto-detected if not set)
SWAP_DISK_TOTAL_GB="${SWAP_DISK_TOTAL_GB:-auto}"  # Total disk-based swap (auto = calculated)
SWAP_STRIPE_WIDTH="${SWAP_STRIPE_WIDTH:-auto}"  # Number of parallel swap devices (for I/O striping)
SWAP_PRIORITY="${SWAP_PRIORITY:-10}"  # Priority for disk swap (lower than RAM)
EXTEND_ROOT="${EXTEND_ROOT:-yes}"

# ZFS-specific
ZFS_POOL="${ZFS_POOL:-tank}"

# Bootstrap options
RUN_USER_CONFIG="${RUN_USER_CONFIG:-yes}"
RUN_APT_CONFIG="${RUN_APT_CONFIG:-yes}"
RUN_JOURNALD_CONFIG="${RUN_JOURNALD_CONFIG:-yes}"
RUN_DOCKER_INSTALL="${RUN_DOCKER_INSTALL:-yes}"
RUN_SSH_SETUP="${RUN_SSH_SETUP:-yes}"  # Generate SSH key for root and send via Telegram
RUN_GEEKBENCH="${RUN_GEEKBENCH:-yes}"
RUN_BENCHMARKS="${RUN_BENCHMARKS:-yes}"
BENCHMARK_DURATION="${BENCHMARK_DURATION:-5}"  # Duration in seconds for each benchmark test
SEND_SYSINFO="${SEND_SYSINFO:-yes}"

# Advanced benchmark options (Phase 2-4) - NOW ENABLED BY DEFAULT
CREATE_SWAP_PARTITIONS="${CREATE_SWAP_PARTITIONS:-yes}"  # Create optimized partitions from matrix test
TEST_ZSWAP_LATENCY="${TEST_ZSWAP_LATENCY:-yes}"  # Run ZSWAP latency tests with real partitions
PRESERVE_ROOT_SIZE_GB="${PRESERVE_ROOT_SIZE_GB:-10}"  # Minimum root partition size (for shrink scenario)

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

log_root_layout() {
    local root_part
    root_part=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
    if [ -z "$root_part" ]; then
        log_warn "Could not determine root partition"
        return 0
    fi

    log_info "Root mount source: $root_part"
    df -h / 2>/dev/null | tee -a "$LOG_FILE" || true

    local root_disk
    root_disk=$(lsblk -no PKNAME "$root_part" 2>/dev/null | head -1 || true)
    if [ -n "$root_disk" ] && [ -b "/dev/$root_disk" ]; then
        log_info "Root disk layout: /dev/$root_disk"
        lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "/dev/$root_disk" 2>/dev/null | tee -a "$LOG_FILE" || true
    else
        log_warn "Could not determine root disk for $root_part"
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
    # Only try to send if the script exists (repo must be cloned first)
    [ ! -f "${SCRIPT_DIR}/telegram_client.py" ] && return 0
    python3 "${SCRIPT_DIR}/telegram_client.py" --send "$msg" 2>/dev/null || true
}

# Helper function to send files via telegram
tg_send_file() {
    local file="$1"
    local caption="${2:-}"
    [ -z "$TELEGRAM_BOT_TOKEN" ] && return 0
    [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    # Only try to send if the script exists (repo must be cloned first)
    [ ! -f "${SCRIPT_DIR}/telegram_client.py" ] && return 0
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
    
    # Core utilities (including python3 which is needed for telegram and benchmarks)
    local core_packages="ca-certificates gnupg lsb-release curl wget git vim less jq bash-completion man-db python3 python3-pip python3-requests"
    
    # Network tools
    local network_packages="netcat-traditional iputils-ping dnsutils iproute2"
    
    # Additional useful tools
    local additional_packages="ripgrep fd-find tree fzf httpie"
    
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
    
    # Install tldr with proper setup
    if ! command -v tldr >/dev/null 2>&1; then
        log_info "Installing tldr (Python-based) system-wide..."
        if pip3 install --system tldr 2>/dev/null || pip3 install tldr; then
            # Update tldr cache for immediate use
            log_info "Updating tldr cache..."
            if tldr --update 2>/dev/null; then
                log_info "✓ tldr installed and cache updated"
            else
                log_warn "tldr installed but cache update failed (run 'tldr --update' manually)"
            fi
        else
            log_warn "Failed to install tldr"
        fi
    else
        # Update cache if tldr already exists
        log_info "Updating tldr cache..."
        tldr --update 2>/dev/null || log_warn "Failed to update tldr cache"
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
    export SWAP_DISK_TOTAL_GB SWAP_BACKING_TYPE SWAP_STRIPE_WIDTH
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
            
            # Phase 2: Create optimized swap partitions based on matrix test results
            if [ "$CREATE_SWAP_PARTITIONS" = "yes" ] && [ -f "$BENCHMARK_OUTPUT" ]; then
                log_info "==> Creating optimized swap partitions from benchmark results"
                log_info "This will modify disk partition table (root may be resized)"

                log_info "==> Root layout BEFORE repartitioning"
                log_root_layout
                
                export PRESERVE_ROOT_SIZE_GB
                if ./create-swap-partitions.sh 2>&1 | tee -a "$LOG_FILE"; then
                    log_info "✓ Swap partitions created successfully"

                    log_info "==> Root layout AFTER repartitioning"
                    log_root_layout
                    
                    # Phase 3: Run ZSWAP latency tests with real partitions
                    if [ "$TEST_ZSWAP_LATENCY" = "yes" ]; then
                        log_info "==> Testing ZSWAP latency with real disk backing"
                        if ./benchmark.py --test-zswap-latency 2>&1 | tee -a "$LOG_FILE"; then
                            log_info "✓ ZSWAP latency test complete"
                        else
                            log_warn "ZSWAP latency test had issues (non-critical)"
                        fi
                    else
                        log_info "==> ZSWAP latency test skipped (TEST_ZSWAP_LATENCY=$TEST_ZSWAP_LATENCY)"
                    fi
                else
                    log_error "✗ Swap partition creation failed"
                    log_warn "Continuing with existing swap configuration"
                fi
            elif [ "$CREATE_SWAP_PARTITIONS" = "yes" ]; then
                log_warn "CREATE_SWAP_PARTITIONS=yes but benchmark results not found"
                log_warn "Skipping partition creation (requires matrix test results)"
            else
                log_info "==> Swap partition creation skipped (CREATE_SWAP_PARTITIONS=$CREATE_SWAP_PARTITIONS)"
            fi
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
        exit 1
    fi
    
    # Sync log file (removed telegram_send for swap configuration)
    sync
    
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
    
    # SSH key generation and setup
    if [ "$RUN_SSH_SETUP" = "yes" ]; then
        log_info "==> Generating SSH key for root user"

        # Use the unified Python tool in server mode (local install + optional Telegram delivery)
        export HOME="/root"
        export NONINTERACTIVE="yes"

        if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            log_info "Telegram configured - will send private key via Telegram"
            if python3 ../ssh-keygen-deploy.py --user root --send-private --non-interactive 2>&1 | tee -a "$LOG_FILE"; then
                log_info "✓ SSH key generated and private key sent via Telegram"
            else
                log_warn "SSH key generation had issues"
            fi
        else
            log_warn "Telegram not configured - SSH key will be generated but not sent"
            if python3 ../ssh-keygen-deploy.py --user root --non-interactive 2>&1 | tee -a "$LOG_FILE"; then
                log_info "✓ SSH key generated (no Telegram delivery)"
            else
                log_warn "SSH key generation had issues"
            fi
        fi
    else
        log_info "==> SSH key generation skipped (RUN_SSH_SETUP=$RUN_SSH_SETUP)"
    fi
    
    # Geekbench (MOVED HERE - after swap configuration to avoid influencing benchmark results)
    if [ "$RUN_GEEKBENCH" = "yes" ]; then
        log_info "==> Running Geekbench (5-10 min)"
        GEEKBENCH_START=$(date +%s)
        
        # Add --notify flag if Telegram is configured
        GEEKBENCH_ARGS="--geekbench-only"
        if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            GEEKBENCH_ARGS="--geekbench --notify"
        fi
        
        # Run geekbench and capture exit code properly
        set +e  # Temporarily disable exit on error
        ./sysinfo-notify.py $GEEKBENCH_ARGS 2>&1 | tee -a "$LOG_FILE"
        GEEKBENCH_EXIT_CODE=${PIPESTATUS[0]}
        set -e  # Re-enable exit on error
        
        GEEKBENCH_END=$(date +%s)
        GEEKBENCH_DURATION=$((GEEKBENCH_END - GEEKBENCH_START))
        
        if [ "$GEEKBENCH_EXIT_CODE" -eq 0 ]; then
            log_info "✓ Geekbench complete (took ${GEEKBENCH_DURATION}s)"
        else
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
    
    # Print bootstrap summary
    print_bootstrap_summary
    
    log_info "🎉 System setup complete!"
    log_info "Log: $LOG_FILE"
    
    # Send comprehensive completion message with log file as attachment
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -f "$LOG_FILE" ]; then
        log_info "Sending final summary and log file..."
        sync
        
        # Build comprehensive completion message
        local completion_msg="🎉 <b>Bootstrap Complete</b>

<b>📊 Final System Status:</b>"
        
        # Add system summary
        local hostname=$(hostname -f 2>/dev/null || hostname)
        local ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        local ram_gb=$(free -g | awk '/^Mem:/{print $2}')
        completion_msg="${completion_msg}
• System: ${hostname} (${ip})
• RAM: ${ram_gb}GB"
        
        # Add swap configuration
        if [ -n "${SWAP_RAM_SOLUTION:-}" ] && [ "${SWAP_RAM_SOLUTION}" != "auto" ]; then
            completion_msg="${completion_msg}
• Swap: ${SWAP_RAM_SOLUTION}"
        fi
        
        # Add Docker if installed
        if command -v docker >/dev/null 2>&1; then
            local docker_version=$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')
            completion_msg="${completion_msg}
• Docker: ${docker_version}"
        fi
        
        completion_msg="${completion_msg}

<b>📝 Log File:</b> See attachment for full details
<b>⏱️ Completed:</b> $(date '+%Y-%m-%d %H:%M:%S')"
        
        # Send message with log as attachment
        tg_send "$completion_msg"
        tg_send_file "$LOG_FILE" "📋 Bootstrap Complete - Full Installation Log"
    fi
}

main "$@"
