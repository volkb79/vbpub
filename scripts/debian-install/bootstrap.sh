#!/bin/bash
#
# bootstrap.sh - Minimal netcup/VPS initialization script
# 
# Downloads vbpub repository and runs setup-swap.sh with configuration
# Designed to be <10KB for quick remote deployment
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | bash
#   
# With configuration:
#   curl -fsSL ... | SWAP_TOTAL_GB=64 SWAP_ARCH=zswap-files bash
#

set -euo pipefail

# Configuration from environment (with defaults)
REPO_URL="${REPO_URL:-https://github.com/volkb79/vbpub.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/tmp/vbpub-install}"
SWAP_ARCH="${SWAP_ARCH:-auto}"
SWAP_TOTAL_GB="${SWAP_TOTAL_GB:-auto}"
SWAP_FILES="${SWAP_FILES:-8}"
AUTO_BENCHMARK="${AUTO_BENCHMARK:-true}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

send_telegram() {
    local message="$1"
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        return 0
    fi
    
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=HTML" \
        >/dev/null 2>&1 || true
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_dependencies() {
    local deps="git curl"
    local missing=""
    
    for cmd in $deps; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done
    
    if [ -n "$missing" ]; then
        log_info "Installing missing dependencies:$missing"
        apt-get update -qq
        apt-get install -y -qq $missing
    fi
}

clone_repository() {
    log_info "Cloning repository from $REPO_URL (branch: $REPO_BRANCH)"
    
    # Clean up if directory exists
    if [ -d "$INSTALL_DIR" ]; then
        log_warn "Removing existing directory: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi
    
    # Clone repository
    if ! git clone --depth=1 --branch="$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR" 2>&1; then
        log_error "Failed to clone repository"
        send_telegram "❌ Bootstrap failed: Could not clone repository"
        exit 1
    fi
    
    log_success "Repository cloned to $INSTALL_DIR"
}

run_setup() {
    local setup_script="$INSTALL_DIR/scripts/debian-install/setup-swap.sh"
    
    if [ ! -f "$setup_script" ]; then
        log_error "Setup script not found: $setup_script"
        send_telegram "❌ Bootstrap failed: Setup script not found"
        exit 1
    fi
    
    # Make script executable
    chmod +x "$setup_script"
    
    log_info "Running setup-swap.sh with configuration:"
    log_info "  SWAP_ARCH=$SWAP_ARCH"
    log_info "  SWAP_TOTAL_GB=$SWAP_TOTAL_GB"
    log_info "  SWAP_FILES=$SWAP_FILES"
    log_info "  AUTO_BENCHMARK=$AUTO_BENCHMARK"
    
    # Export configuration for setup script
    export SWAP_ARCH
    export SWAP_TOTAL_GB
    export SWAP_FILES
    export AUTO_BENCHMARK
    export TELEGRAM_BOT_TOKEN
    export TELEGRAM_CHAT_ID
    
    # Run setup
    send_telegram "🚀 <b>Bootstrap started</b>
System: $(hostname)
Configuration: $SWAP_ARCH, ${SWAP_TOTAL_GB}GB, ${SWAP_FILES} files"
    
    if "$setup_script"; then
        log_success "Setup completed successfully"
        send_telegram "✅ <b>Swap setup completed</b>
$(swapon --show | sed 's/^/  /')"
    else
        log_error "Setup failed with exit code $?"
        send_telegram "❌ <b>Setup failed</b>
Check system logs for details"
        exit 1
    fi
}

main() {
    log_info "=== Debian Swap Configuration Bootstrap ==="
    log_info "Repository: $REPO_URL"
    log_info "Branch: $REPO_BRANCH"
    
    check_root
    check_dependencies
    clone_repository
    run_setup
    
    log_success "Bootstrap completed successfully!"
    log_info ""
    log_info "Next steps:"
    log_info "  - Check swap status: swapon --show"
    log_info "  - Monitor swap: /usr/local/bin/swap-monitor.sh"
    log_info "  - View documentation: $INSTALL_DIR/scripts/debian-install/README.md"
    
    # Optional: Clean up
    if [ "${CLEANUP_REPO:-false}" = "true" ]; then
        log_info "Cleaning up repository..."
        rm -rf "$INSTALL_DIR"
    fi
}

main "$@"
