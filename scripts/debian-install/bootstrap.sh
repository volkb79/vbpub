#!/bin/bash
# Minimal bootstrap script for Debian swap configuration
# MUST BE UNDER 10KB for netcup init script compatibility
# Usage: curl -fsSL URL | bash
# Or: curl -fsSL URL | SWAP_ARCH=3 SWAP_TOTAL_GB=16 bash

set -euo pipefail

# Configuration
REPO_URL="${REPO_URL:-https://github.com/volkb79/vbpub.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
CLONE_DIR="${CLONE_DIR:-/opt/vbpub}"
SCRIPT_DIR="${CLONE_DIR}/scripts/debian-install"
LOG_DIR="${LOG_DIR:-/var/log/swap-setup}"
LOG_FILE="${LOG_DIR}/bootstrap-$(date +%Y%m%d-%H%M%S).log"

# Swap configuration (passed through to setup-swap.sh)
SWAP_ARCH="${SWAP_ARCH:-3}"
SWAP_TOTAL_GB="${SWAP_TOTAL_GB:-auto}"
SWAP_FILES="${SWAP_FILES:-8}"
SWAP_PRIORITY="${SWAP_PRIORITY:-10}"
ZRAM_SIZE_GB="${ZRAM_SIZE_GB:-auto}"
ZRAM_PRIORITY="${ZRAM_PRIORITY:-100}"
ZSWAP_POOL_PERCENT="${ZSWAP_POOL_PERCENT:-20}"
ZSWAP_COMPRESSOR="${ZSWAP_COMPRESSOR:-lz4}"
ZFS_POOL="${ZFS_POOL:-tank}"

# Telegram (optional)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE" >&2; }

# Get system identification
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
    # Create log directory
    mkdir -p "$LOG_DIR"
    
    log_info "Debian Swap Configuration Bootstrap"
    log_info "Repository: $REPO_URL"
    log_info "Log file: $LOG_FILE"
    
    telegram_send "🚀 Starting swap configuration"
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "Must run as root"
        exit 1
    fi
    
    # Install git if needed
    if ! command -v git >/dev/null 2>&1; then
        log_info "Installing git..."
        apt-get update -qq
        apt-get install -y -qq git
    fi
    
    # Clone or update repository
    if [ -d "$CLONE_DIR/.git" ]; then
        log_info "Updating repository..."
        cd "$CLONE_DIR"
        git fetch origin
        git reset --hard "origin/$REPO_BRANCH"
    else
        log_info "Cloning repository..."
        rm -rf "$CLONE_DIR"
        git clone -b "$REPO_BRANCH" "$REPO_URL" "$CLONE_DIR"
    fi
    
    # Check script exists
    if [ ! -f "$SCRIPT_DIR/setup-swap.sh" ]; then
        log_error "setup-swap.sh not found in $SCRIPT_DIR"
        telegram_send "❌ Bootstrap failed: script not found"
        exit 1
    fi
    
    # Make executable
    chmod +x "$SCRIPT_DIR/setup-swap.sh" "$SCRIPT_DIR/analyze-memory.sh" "$SCRIPT_DIR/swap-monitor.sh" "$SCRIPT_DIR/ksm-trial.sh" 2>/dev/null || true
    chmod +x "$SCRIPT_DIR/benchmark.py" "$SCRIPT_DIR/sysinfo-notify.py" 2>/dev/null || true
    
    # Run setup
    log_info "Running swap setup (arch=$SWAP_ARCH, size=${SWAP_TOTAL_GB}GB, files=$SWAP_FILES)"
    
    cd "$SCRIPT_DIR"
    
    export SWAP_ARCH SWAP_TOTAL_GB SWAP_FILES SWAP_PRIORITY
    export ZRAM_SIZE_GB ZRAM_PRIORITY ZSWAP_POOL_PERCENT ZSWAP_COMPRESSOR
    export ZFS_POOL TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID LOG_FILE
    
    if ./setup-swap.sh 2>&1 | tee -a "$LOG_FILE"; then
        log_info "✓ Swap configuration completed successfully"
        log_info "Log saved to: $LOG_FILE"
        telegram_send "✅ Swap configuration completed\nLog: $LOG_FILE"
    else
        log_error "✗ Swap configuration failed"
        telegram_send "❌ Swap configuration failed\nLog: $LOG_FILE"
        exit 1
    fi
}

main "$@"
