#!/bin/bash
#
# Journald Configuration Script for Debian Systems
# Configures systemd-journald with log retention and size limits
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_step() {
    echo ""
    echo -e "${GREEN}==>${NC} ${BLUE}$*${NC}"
    echo ""
}

# Configure journald
configure_journald() {
    log_step "Configuring systemd-journald"
    
    # Create drop-in directory
    mkdir -p /etc/systemd/journald.conf.d
    
    # Create custom configuration
    cat > /etc/systemd/journald.conf.d/99-custom.conf <<'EOF'
[Journal]
# Maximum disk space for persistent journal logs
# Default is 10% of filesystem size, capped at 4 GiB
# Setting to 200M to conserve disk space
SystemMaxUse=200M

# Minimum free disk space to leave for other uses
# Avoid running out of disk space due to logs
SystemKeepFree=500M

# Maximum size of individual journal files
SystemMaxFileSize=100M

# Maximum number of journal files to keep
# Note: This is not a standard journald setting, but helps document intent
# Actual number of files is controlled by SystemMaxUse and SystemMaxFileSize
# SystemMaxFiles=1000

# Maximum time to retain journal entries
# 0 means unlimited (subject to space constraints)
# Enforce time-based retention: 12 months
MaxRetentionSec=12month

# Maximum time span covered by a single journal file
# How often to rotate files
MaxFileSec=1month

# Store journal persistently on disk
Storage=persistent

# Compress journal files (default is yes, but being explicit)
Compress=yes

# Forward to syslog (optional, disabled by default)
# ForwardToSyslog=no

# Forward to console (disabled by default)
# ForwardToConsole=no
EOF
    
    log_success "Journald configuration created"
}

# Restart journald service
restart_journald() {
    log_step "Restarting systemd-journald"
    
    systemctl restart systemd-journald
    
    log_success "systemd-journald restarted"
}

# Show journal disk usage
show_journal_usage() {
    log_step "Journal Disk Usage"
    
    echo ""
    journalctl --disk-usage
    echo ""
    
    log_info "Journal files location: /var/log/journal/"
    log_info "To manually vacuum old logs:"
    log_info "  journalctl --vacuum-time=30d"
    log_info "  journalctl --vacuum-size=100M"
}

# Verify configuration
verify_configuration() {
    log_step "Verifying Configuration"
    
    echo ""
    echo "Active journald configuration:"
    systemctl show systemd-journald | grep -E "(SystemMaxUse|SystemKeepFree|SystemMaxFileSize|MaxRetentionSec|MaxFileSec)" || true
    echo ""
}

# Main function
main() {
    log_step "Journald Configuration Script"
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Configure journald
    configure_journald
    
    # Restart service
    restart_journald
    
    # Show usage
    show_journal_usage
    
    # Verify
    verify_configuration
    
    log_step "Configuration Complete"
    log_success "Journald is now configured with:"
    log_info "  • Maximum disk usage: 200M"
    log_info "  • Minimum free space: 500M"
    log_info "  • Max file size: 100M"
    log_info "  • Retention time: 12 months"
    log_info "  • Rotation interval: 1 month"
}

# Run main if not sourced
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
