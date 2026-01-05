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
EXTEND_ROOT="${EXTEND_ROOT:-no}"

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

log_info() { echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE" >&2; }

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
    local system_packages="fio sysstat"
    
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
        if ./sysinfo-notify.py --geekbench-only 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Geekbench complete"
            # Geekbench results are automatically sent via telegram by sysinfo-notify.py
        else
            log_warn "Geekbench failed"
        fi
    else
        log_info "==> Geekbench skipped (RUN_GEEKBENCH=$RUN_GEEKBENCH)"
    fi
    
    # System info
    if [ "$SEND_SYSINFO" = "yes" ] && [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        log_info "==> Sending system info"
        # System information is collected using the unified system_info.py module.
        # This module is shared between:
        # - get_system_summary(): Uses system_info.py with --format text for bootstrap summary
        # - sysinfo-notify.py: Uses system_info.py with HTML formatting for telegram notifications
        # This ensures DRY (Don't Repeat Yourself) - single source of truth for system info collection.
        
        # Send formatted notification via telegram
        ./sysinfo-notify.py --notify 2>&1 | tee -a "$LOG_FILE" || true
        
        # Optionally save detailed info to file and send as attachment
        SYSINFO_FILE="/tmp/system-info-$(date +%Y%m%d-%H%M%S).json"
        ./system_info.py --output "$SYSINFO_FILE" 2>&1 || true
        
        if [ -f "$SYSINFO_FILE" ]; then
            log_info "Sending detailed system info as attachment..."
            tg_send_file "$SYSINFO_FILE" "📊 Detailed System Information (JSON)"
            rm -f "$SYSINFO_FILE"
        fi
    fi
    
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
