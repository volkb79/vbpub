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
# Legacy SWAP_ARCH support (now used as configuration presets)
SWAP_ARCH="${SWAP_ARCH:-3}"

# RAM-based swap
SWAP_RAM_SOLUTION="${SWAP_RAM_SOLUTION:-zswap}"
SWAP_RAM_TOTAL_GB="${SWAP_RAM_TOTAL_GB:-auto}"
ZRAM_COMPRESSOR="${ZRAM_COMPRESSOR:-lz4}"
ZRAM_ALLOCATOR="${ZRAM_ALLOCATOR:-zsmalloc}"
ZRAM_PRIORITY="${ZRAM_PRIORITY:-100}"
ZSWAP_POOL_PERCENT="${ZSWAP_POOL_PERCENT:-20}"
ZSWAP_COMPRESSOR="${ZSWAP_COMPRESSOR:-lz4}"
ZSWAP_ZPOOL="${ZSWAP_ZPOOL:-z3fold}"

# Disk-based swap
SWAP_DISK_TOTAL_GB="${SWAP_DISK_TOTAL_GB:-auto}"
SWAP_BACKING_TYPE="${SWAP_BACKING_TYPE:-files_in_root}"
SWAP_STRIPE_WIDTH="${SWAP_STRIPE_WIDTH:-8}"
SWAP_PRIORITY="${SWAP_PRIORITY:-10}"
EXTEND_ROOT="${EXTEND_ROOT:-no}"

# ZFS-specific
ZFS_POOL="${ZFS_POOL:-tank}"



# Bootstrap options
RUN_USER_CONFIG="${RUN_USER_CONFIG:-yes}"
RUN_APT_CONFIG="${RUN_APT_CONFIG:-yes}"
RUN_JOURNALD_CONFIG="${RUN_JOURNALD_CONFIG:-yes}"
RUN_DOCKER_INSTALL="${RUN_DOCKER_INSTALL:-no}"
RUN_GEEKBENCH="${RUN_GEEKBENCH:-yes}"
RUN_BENCHMARKS="${RUN_BENCHMARKS:-yes}"
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

# Collect system summary
get_system_summary() {
    echo "📊 System Summary"
    echo "================"
    echo "Hostname: $(hostname -f 2>/dev/null || hostname)"
    echo "IP: $(hostname -I 2>/dev/null | awk '{print $1}')"
    echo ""
    echo "CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo "CPU Cores: $(nproc)"
    echo "RAM: $(free -h | awk '/^Mem:/{print $2}')"
    echo ""
    echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    echo "Kernel: $(uname -r)"
    echo ""
    echo "Disk Layout:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null || df -h
}

main() {
    mkdir -p "$LOG_DIR"
    log_info "Debian System Setup Bootstrap"
    log_info "Log: $LOG_FILE"
    tg_send "🚀 Starting system setup"
    
    if [ "$EUID" -ne 0 ]; then log_error "Must run as root"; exit 1; fi
    
    # Install git
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
    
    # Export all config (new naming convention)
    export SWAP_ARCH
    export SWAP_RAM_SOLUTION SWAP_RAM_TOTAL_GB
    export ZRAM_COMPRESSOR ZRAM_ALLOCATOR ZRAM_PRIORITY
    export ZSWAP_COMPRESSOR ZSWAP_ZPOOL
    export SWAP_DISK_TOTAL_GB SWAP_BACKING_TYPE SWAP_STRIPE_WIDTH
    export SWAP_PRIORITY EXTEND_ROOT
    export ZFS_POOL
    export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID LOG_FILE
    export DEBUG_MODE
    
    # Send system summary
    log_info "==> Collecting system summary"
    SYSTEM_SUMMARY=$(get_system_summary)
    echo "$SYSTEM_SUMMARY" | tee -a "$LOG_FILE"
    tg_send "$SYSTEM_SUMMARY"
    
    # Run swap setup
    log_info "==> Configuring swap (arch=$SWAP_ARCH)"
    if ./setup-swap.sh 2>&1 | tee -a "$LOG_FILE"; then
        log_info "✓ Swap configured"
        tg_send "✅ Swap configured"
    else
        log_error "✗ Swap config failed"
        tg_send "❌ Swap config failed"
        exit 1
    fi
    
    # Sync and send log file
    sync
    tg_send_file "$LOG_FILE" "📋 Swap Configuration Log"
    
    # User configuration
    if [ "$RUN_USER_CONFIG" = "yes" ]; then
        log_info "==> Configuring users"
        if ./configure-users.sh 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Users configured"
            tg_send "✅ User configs applied"
        else
            log_warn "User config had issues"
        fi
    fi
    
    # APT configuration
    if [ "$RUN_APT_CONFIG" = "yes" ]; then
        log_info "==> Configuring APT repositories"
        if ./configure-apt.sh 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ APT configured"
            tg_send "✅ APT repos configured"
        else
            log_warn "APT config had issues"
        fi
    fi
    
    # Journald configuration
    if [ "$RUN_JOURNALD_CONFIG" = "yes" ]; then
        log_info "==> Configuring journald"
        if ./configure-journald.sh 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Journald configured"
            tg_send "✅ Journald configured"
        else
            log_warn "Journald config had issues"
        fi
    fi
    
    # Docker installation
    if [ "$RUN_DOCKER_INSTALL" = "yes" ]; then
        log_info "==> Installing Docker"
        if ./install-docker.sh 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Docker installed"
            tg_send "✅ Docker installed"
        else
            log_warn "Docker installation had issues"
        fi
    fi
    
    # Geekbench
    if [ "$RUN_GEEKBENCH" = "yes" ]; then
        log_info "==> Running Geekbench (5-10 min)"
        if ./sysinfo-notify.py --geekbench-only 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Geekbench complete"
        else
            log_warn "Geekbench failed"
        fi
    fi
    
    # Benchmarks
    if [ "$RUN_BENCHMARKS" = "yes" ]; then
        log_info "==> Running swap benchmarks"
        if ./benchmark.py --test-all 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Benchmarks complete"
        else
            log_warn "Benchmarks had issues"
        fi
    fi
    
    # System info
    if [ "$SEND_SYSINFO" = "yes" ] && [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        log_info "==> Sending system info"
        # Collect system info to a file
        SYSINFO_FILE="/tmp/system-info-$(date +%Y%m%d-%H%M%S).txt"
        ./system_info.py --collect > "$SYSINFO_FILE" 2>&1 || true
        
        # Send as message
        ./sysinfo-notify.py --notify 2>&1 | tee -a "$LOG_FILE" || true
        
        # Send file as attachment if available
        if [ -f "$SYSINFO_FILE" ]; then
            log_info "Sending system info file as attachment..."
            tg_send_file "$SYSINFO_FILE" "📊 Detailed System Information"
            rm -f "$SYSINFO_FILE"
        fi
    fi
    
    log_info "🎉 System setup complete!"
    log_info "Log: $LOG_FILE"
    
    # Send completion message with log file as attachment
    tg_send "🎉 System setup complete"
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -f "$LOG_FILE" ]; then
        log_info "Sending final log file as attachment..."
        sync
        tg_send_file "$LOG_FILE" "📋 Bootstrap Complete - Full Log"
    fi
}

main "$@"
