#!/bin/bash
# bootstrap.sh - Initial bootstrap script for netcup VPS
#
# This script performs initial system setup for Debian VPS environments

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_colored() {
    local color=$1
    shift
    echo -e "${color}$*${NC}"
}

print_section() {
    echo ""
    print_colored "$BLUE" "=== $1 ==="
    echo ""
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_colored "$RED" "Error: This script must be run as root"
        echo "Run with: sudo $0"
        exit 1
    fi
}

main() {
    print_colored "$BLUE" "╔═══════════════════════════════════════════════════╗"
    print_colored "$BLUE" "║     Netcup VPS Bootstrap Script                  ║"
    print_colored "$BLUE" "╚═══════════════════════════════════════════════════╝"
    echo ""
    
    check_root
    
    print_section "System Information"
    echo "Hostname: $(hostname)"
    echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    echo "Kernel: $(uname -r)"
    echo "Memory: $(free -h | grep "^Mem:" | awk '{print $2}')"
    
    print_section "Updating System"
    apt-get update
    apt-get upgrade -y
    
    print_section "Installing Essential Packages"
    apt-get install -y \
        curl \
        wget \
        git \
        vim \
        htop \
        iotop \
        sysstat \
        bc \
        python3 \
        python3-pip \
        build-essential
    
    print_section "Configuring System"
    
    # Enable sysstat
    if [ -f /etc/default/sysstat ]; then
        sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
        systemctl enable sysstat
        systemctl start sysstat
        print_colored "$GREEN" "✅ Sysstat enabled"
    fi
    
    # Set timezone (optional)
    if [ ! -L /etc/localtime ]; then
        print_colored "$YELLOW" "Timezone not configured"
        echo "Run: timedatectl set-timezone YOUR_TIMEZONE"
        echo "List timezones: timedatectl list-timezones"
    fi
    
    print_section "Installing Swap Configuration Scripts"
    
    # Check if we're already in the repo
    if [ -d "/root/vbpub/scripts/debian-install" ]; then
        print_colored "$GREEN" "✅ Scripts already available"
    else
        # Clone repository
        if [ ! -d "/root/vbpub" ]; then
            git clone https://github.com/volkb79/vbpub.git /root/vbpub
        fi
        
        # Make scripts executable
        chmod +x /root/vbpub/scripts/debian-install/*.sh
        chmod +x /root/vbpub/scripts/debian-install/*.py
        
        # Create symlinks in /usr/local/bin (optional)
        read -p "Create symlinks in /usr/local/bin? (y/N): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            ln -sf /root/vbpub/scripts/debian-install/setup-swap.sh /usr/local/bin/setup-swap
            ln -sf /root/vbpub/scripts/debian-install/swap-monitor.sh /usr/local/bin/swap-monitor
            ln -sf /root/vbpub/scripts/debian-install/analyze-memory.sh /usr/local/bin/analyze-memory
            ln -sf /root/vbpub/scripts/debian-install/analyze-running-system.sh /usr/local/bin/analyze-system
            print_colored "$GREEN" "✅ Symlinks created"
        fi
    fi
    
    print_section "Next Steps"
    
    print_colored "$GREEN" "✅ Bootstrap complete!"
    echo ""
    echo "Recommended next steps:"
    echo ""
    echo "1. Analyze current system:"
    echo "   cd /root/vbpub/scripts/debian-install"
    echo "   ./analyze-memory.sh"
    echo ""
    echo "2. Setup swap configuration:"
    echo "   ./setup-swap.sh"
    echo ""
    echo "3. Monitor swap performance:"
    echo "   ./swap-monitor.sh"
    echo ""
    echo "4. Run comprehensive analysis:"
    echo "   ./analyze-running-system.sh"
    echo ""
    echo "5. Optional: Setup Telegram notifications"
    echo "   ./sysinfo-notify.py --test"
    echo ""
    
    print_colored "$YELLOW" "Note: Review /root/vbpub/scripts/debian-install/README.md for complete documentation"
}

main "$@"
