#!/bin/bash
#
# APT Configuration Script for Debian Systems
# Configures APT sources with main, contrib, non-free, backports, and testing
# Uses modern deb822 format
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

# Detect Debian release
detect_release() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$VERSION_CODENAME"
    else
        log_error "Cannot detect Debian release"
        exit 1
    fi
}

# Configure APT sources using deb822 format
configure_apt_sources() {
    log_step "Configuring APT sources (deb822 format)"
    
    local release=$(detect_release)
    log_info "Detected Debian release: $release"
    
    # Create sources directory if it doesn't exist
    mkdir -p /etc/apt/sources.list.d
    
    # Backup old sources.list if it exists
    if [ -f /etc/apt/sources.list ]; then
        log_info "Backing up /etc/apt/sources.list"
        cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d_%H%M%S)
        # Comment out old sources
        sed -i 's/^deb/#deb/g' /etc/apt/sources.list
    fi
    
    # Main repository (stable) - Priority: 500 (default)
    log_info "Creating main repository configuration..."
    cat > /etc/apt/sources.list.d/debian.sources <<EOF
# Debian ${release} - Main Repository
# Components: main contrib non-free non-free-firmware
# Priority: 500 (default)
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: ${release} ${release}-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

# Security updates
Types: deb deb-src
URIs: http://deb.debian.org/debian-security
Suites: ${release}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    
    # Backports repository - Priority: 600 (higher than default, will be used automatically)
    log_info "Creating backports repository configuration..."
    cat > /etc/apt/sources.list.d/debian-backports.sources <<EOF
# Debian ${release}-backports
# Components: main contrib non-free non-free-firmware
# Priority: 600 (higher than default - packages will be used automatically)
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: ${release}-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    
    # Testing repository - Priority: 100 (low - for visibility only)
    log_info "Creating testing repository configuration..."
    cat > /etc/apt/sources.list.d/debian-testing.sources <<EOF
# Debian testing (next stable release)
# Components: main contrib non-free non-free-firmware
# Priority: 100 (low - for visibility only, not used automatically)
Types: deb
URIs: http://deb.debian.org/debian
Suites: testing
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    
    # Configure APT preferences (priorities)
    log_info "Configuring APT preferences..."
    cat > /etc/apt/preferences.d/debian-priorities <<EOF
# APT Priorities Configuration
# Default stable: 500
# Backports: 600 (preferred over stable)
# Testing: 100 (low priority, visibility only)

Package: *
Pin: release a=${release}
Pin-Priority: 500

Package: *
Pin: release a=${release}-backports
Pin-Priority: 600

Package: *
Pin: release a=testing
Pin-Priority: 100
EOF
    
    log_success "APT sources configured successfully"
}

# Configure APT settings
configure_apt_settings() {
    log_step "Configuring APT settings"
    
    cat > /etc/apt/apt.conf.d/99-custom.conf <<'EOF'
// Custom APT Configuration
// Debug and display settings

Debug 
{
    // Show policy information (repository priorities)
    pkgPolicy "true";
}

APT
{
    // Options for apt-get
    Get
    {
        // Show package versions in output
        Show-Versions "true";
        
        // Automatically remove unused dependencies
        AutomaticRemove "true";
    };
};
EOF
    
    log_success "APT settings configured"
}

# Update APT cache
update_apt_cache() {
    log_step "Updating APT cache"
    
    apt-get update
    
    log_success "APT cache updated"
}

# Show APT policy
show_apt_policy() {
    log_step "APT Policy Summary"
    
    echo ""
    echo "Repository Priorities:"
    apt-cache policy | head -20
    
    echo ""
    echo "Example: Check specific package policy with:"
    echo "  apt-cache policy <package-name>"
    echo ""
}

# Main function
main() {
    log_step "APT Configuration Script"
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Detect release first
    local release=$(detect_release)
    
    # Configure APT sources
    configure_apt_sources
    
    # Configure APT settings
    configure_apt_settings
    
    # Update cache
    update_apt_cache
    
    # Show policy
    show_apt_policy
    
    log_step "Configuration Complete"
    log_success "APT is now configured with:"
    log_info "  • Main repository (stable): Priority 500"
    log_info "  • Backports: Priority 600 (preferred by default)"
    log_info "  • Testing: Priority 100 (visibility only)"
    log_info ""
    log_info "To install from backports explicitly:"
    log_info "  apt-get install -t ${release}-backports <package>"
    log_info ""
    log_info "To install from testing explicitly:"
    log_info "  apt-get install -t testing <package>"
}

# Run main if not sourced
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
