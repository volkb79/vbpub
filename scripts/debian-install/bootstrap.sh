#!/bin/bash
#
# bootstrap.sh - Minimal Netcup VPS Bootstrap Script
#
# Purpose: Quick setup for new Netcup VPS with Telegram notifications
# Usage: curl -sSL https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install/bootstrap.sh | bash
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

send_telegram() {
    local message="$1"
    
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        if curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=${message}" \
            -d "parse_mode=HTML" >/dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    fi
    return 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

setup_telegram() {
    log_info "Setting up Telegram notifications..."
    
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
        log_warn "TELEGRAM_BOT_TOKEN not set - notifications disabled"
        echo ""
        echo "To enable Telegram notifications:"
        echo "1. Create bot with @BotFather"
        echo "2. Get bot token"
        echo "3. IMPORTANT: Send a message to your bot first!"
        echo "4. Get chat ID: curl -s 'https://api.telegram.org/bot<TOKEN>/getUpdates' | jq"
        echo "   Alternative: @userinfobot, @getidsbot, @RawDataBot"
        echo "5. Export TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID"
        echo ""
        return 1
    fi
    
    if [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        log_warn "TELEGRAM_CHAT_ID not set - notifications disabled"
        return 1
    fi
    
    # Test notification
    if send_telegram "🚀 Bootstrap started on $(hostname)"; then
        log_info "Telegram notifications configured successfully"
        return 0
    else
        log_warn "Telegram test message failed - check credentials"
        return 1
    fi
}

update_system() {
    log_info "Updating system packages..."
    
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get install -y -qq \
        curl \
        wget \
        git \
        htop \
        iotop \
        vim \
        tmux \
        jq \
        sysstat \
        python3 \
        python3-pip \
        build-essential
    
    log_info "System packages updated"
}

configure_basics() {
    log_info "Configuring basic system settings..."
    
    # Enable sysstat
    sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat || true
    systemctl enable sysstat || true
    systemctl start sysstat || true
    
    # Set timezone to UTC
    timedatectl set-timezone UTC || true
    
    log_info "Basic configuration complete"
}

download_scripts() {
    log_info "Downloading swap configuration scripts..."
    
    local base_url="https://raw.githubusercontent.com/volkb79/vbpub/main/scripts/debian-install"
    local scripts=(
        "setup-swap.sh"
        "swap-monitor.sh"
        "analyze-memory.sh"
        "ksm-trial.sh"
        "benchmark.py"
        "sysinfo-notify.py"
    )
    
    mkdir -p /root/swap-tools
    cd /root/swap-tools
    
    for script in "${scripts[@]}"; do
        if curl -sSL -f "${base_url}/${script}" -o "${script}"; then
            chmod +x "${script}"
            log_info "Downloaded: ${script}"
        else
            log_warn "Failed to download: ${script}"
        fi
    done
    
    # Create symlinks in /root for convenience
    for script in "${scripts[@]}"; do
        ln -sf "/root/swap-tools/${script}" "/root/${script}" 2>/dev/null || true
    done
    
    log_info "Scripts downloaded to /root/swap-tools/ (symlinked to /root/)"
}

print_next_steps() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}Bootstrap Complete!${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Configure swap (recommended: ZSWAP + Swap Files):"
    echo "   bash /root/setup-swap.sh"
    echo ""
    echo "2. Monitor system:"
    echo "   bash /root/swap-monitor.sh"
    echo ""
    echo "3. Analyze memory:"
    echo "   bash /root/analyze-memory.sh"
    echo ""
    echo "4. Test KSM benefits:"
    echo "   bash /root/ksm-trial.sh"
    echo ""
    echo "5. Run benchmarks:"
    echo "   python3 /root/benchmark.py"
    echo ""
    echo "Documentation:"
    echo "  https://github.com/volkb79/vbpub/tree/main/scripts/debian-install"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

main() {
    log_info "Starting Netcup VPS bootstrap..."
    
    check_root
    setup_telegram
    
    send_telegram "📦 Installing system packages..." || true
    update_system
    
    send_telegram "⚙️ Configuring system..." || true
    configure_basics
    
    send_telegram "📥 Downloading swap tools..." || true
    download_scripts
    
    send_telegram "✅ Bootstrap complete on $(hostname)" || true
    
    print_next_steps
}

main "$@"
