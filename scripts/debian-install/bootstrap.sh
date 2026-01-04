#!/bin/bash
# System Setup Bootstrap for Debian
# Full system initialization including swap, user config, benchmarking
# MUST BE UNDER 10KB for netcup init script compatibility
# Usage: curl -fsSL URL | bash
# Or: curl -fsSL URL | SWAP_ARCH=3 RUN_GEEKBENCH=yes bash

set -euo pipefail

# Configuration
REPO_URL="${REPO_URL:-https://github.com/volkb79/vbpub.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
CLONE_DIR="${CLONE_DIR:-/opt/vbpub}"
SCRIPT_DIR="${CLONE_DIR}/scripts/debian-install"
LOG_DIR="${LOG_DIR:-/var/log/swap-setup}"
LOG_FILE="${LOG_DIR}/bootstrap-$(date +%Y%m%d-%H%M%S).log"

# Swap configuration
SWAP_ARCH="${SWAP_ARCH:-3}"
SWAP_TOTAL_GB="${SWAP_TOTAL_GB:-auto}"
SWAP_FILES="${SWAP_FILES:-8}"
SWAP_PRIORITY="${SWAP_PRIORITY:-10}"
ZRAM_SIZE_GB="${ZRAM_SIZE_GB:-auto}"
ZRAM_PRIORITY="${ZRAM_PRIORITY:-100}"
ZSWAP_POOL_PERCENT="${ZSWAP_POOL_PERCENT:-20}"
ZSWAP_COMPRESSOR="${ZSWAP_COMPRESSOR:-lz4}"
ZFS_POOL="${ZFS_POOL:-tank}"
USE_PARTITION="${USE_PARTITION:-no}"
SWAP_PARTITION_SIZE_GB="${SWAP_PARTITION_SIZE_GB:-auto}"
EXTEND_ROOT="${EXTEND_ROOT:-no}"

# Bootstrap options
RUN_USER_CONFIG="${RUN_USER_CONFIG:-yes}"
RUN_GEEKBENCH="${RUN_GEEKBENCH:-no}"
RUN_BENCHMARKS="${RUN_BENCHMARKS:-no}"
SEND_SYSINFO="${SEND_SYSINFO:-yes}"

# Telegram
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE" >&2; }

get_system_id() {
    local hostname=$(hostname)
    local ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
    echo "${hostname} (${ip})"
}

telegram_send() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] && return 0
    [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    local msg="$1"
    local system_id=$(get_system_id)
    local prefixed_msg="<b>${system_id}</b>\n${msg}"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${prefixed_msg}" \
        -d "parse_mode=HTML" >/dev/null 2>&1 || true
}

main() {
    mkdir -p "$LOG_DIR"
    log_info "Debian System Setup Bootstrap"
    log_info "Log: $LOG_FILE"
    telegram_send "🚀 Starting system setup"
    
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
    
    # Export all config
    export SWAP_ARCH SWAP_TOTAL_GB SWAP_FILES SWAP_PRIORITY
    export ZRAM_SIZE_GB ZRAM_PRIORITY ZSWAP_POOL_PERCENT ZSWAP_COMPRESSOR
    export ZFS_POOL USE_PARTITION SWAP_PARTITION_SIZE_GB EXTEND_ROOT
    export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID LOG_FILE
    
    # Run swap setup
    log_info "==> Configuring swap (arch=$SWAP_ARCH)"
    if ./setup-swap.sh 2>&1 | tee -a "$LOG_FILE"; then
        log_info "✓ Swap configured"
        telegram_send "✅ Swap configured"
    else
        log_error "✗ Swap config failed"
        telegram_send "❌ Swap config failed"
        exit 1
    fi
    
    # User configuration
    if [ "$RUN_USER_CONFIG" = "yes" ]; then
        log_info "==> Configuring users"
        if ./configure-users.sh 2>&1 | tee -a "$LOG_FILE"; then
            log_info "✓ Users configured"
            telegram_send "✅ User configs applied"
        else
            log_warn "User config had issues"
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
        ./sysinfo-notify.py --notify 2>&1 | tee -a "$LOG_FILE" || true
    fi
    
    log_info "🎉 System setup complete!"
    log_info "Log: $LOG_FILE"
    telegram_send "🎉 System setup complete\n📋 Log: $LOG_FILE"
}

main "$@"
