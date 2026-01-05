#!/bin/bash
#
# Docker Installation Script for Debian Systems
# Installs Docker from official Docker repository
# Based on: https://docs.docker.com/engine/install/debian/
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

# Remove old Docker installations
remove_old_docker() {
    log_step "Removing old Docker installations"
    
    local old_packages=(
        docker.io
        docker-doc
        docker-compose
        podman-docker
        containerd
        runc
    )
    
    for pkg in "${old_packages[@]}"; do
        if dpkg -l | grep -q "^ii.*${pkg}"; then
            log_info "Removing ${pkg}..."
            apt-get remove -y "$pkg" 2>/dev/null || true
        fi
    done
    
    log_success "Old Docker packages removed (if any)"
}

# Install prerequisites
install_prerequisites() {
    log_step "Installing prerequisites"
    
    apt-get update -qq
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    
    log_success "Prerequisites installed"
}

# Add Docker GPG key
add_docker_gpg_key() {
    log_step "Adding Docker GPG key"
    
    # Create directory for apt keyrings
    install -m 0755 -d /etc/apt/keyrings
    
    # Download and install Docker GPG key
    curl -fsSL https://download.docker.com/linux/debian/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    log_success "Docker GPG key added"
}

# Add Docker repository
add_docker_repository() {
    log_step "Adding Docker repository"
    
    # Get Debian version codename
    local codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    local arch=$(dpkg --print-architecture)
    
    log_info "Detected: Debian ${codename}, architecture ${arch}"
    
    # Add Docker repository using deb822 format
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
# Docker Official Repository
# https://docs.docker.com/engine/install/debian/
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${codename}
Components: stable
Signed-By: /etc/apt/keyrings/docker.gpg
Architectures: ${arch}
EOF
    
    log_success "Docker repository added"
}

# Install Docker packages
install_docker() {
    log_step "Installing Docker packages"
    
    # Update apt cache
    apt-get update -qq
    
    # Install Docker Engine, CLI, containerd, and plugins
    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
    
    log_success "Docker packages installed"
}

# Configure Docker daemon
configure_docker_daemon() {
    log_step "Configuring Docker daemon"
    
    # Create Docker configuration directory
    mkdir -p /etc/docker
    
    # Create daemon.json with modern settings
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "live-restore": true,
  "userland-proxy": false,
  "experimental": false,
  "metrics-addr": "127.0.0.1:9323",
  "features": {
    "buildkit": true
  }
}
EOF
    
    log_success "Docker daemon configured"
    log_info "Configuration:"
    log_info "  • Log driver: local (efficient, rotating logs)"
    log_info "  • Max log size: 10M per container"
    log_info "  • Max log files: 3 per container"
    log_info "  • Storage driver: overlay2"
    log_info "  • Live restore: enabled"
    log_info "  • BuildKit: enabled"
    log_info "  • Metrics: enabled on 127.0.0.1:9323"
}

# Enable and start Docker service
enable_docker_service() {
    log_step "Enabling and starting Docker service"
    
    systemctl enable docker
    
    # Try to start Docker service and capture diagnostics on failure
    if ! systemctl restart docker; then
        log_error "Docker service failed to start"
        
        # Capture diagnostics
        local diag_file="/tmp/docker-failure-diagnostics-$(date +%Y%m%d-%H%M%S).txt"
        {
            echo "=== Docker Installation Failure Diagnostics ==="
            echo "Date: $(date)"
            echo ""
            echo "=== systemctl status docker ==="
            systemctl status docker --no-pager || true
            echo ""
            echo "=== journalctl -u docker (last 50 lines) ==="
            journalctl -u docker -n 50 --no-pager || true
            echo ""
            echo "=== Docker version ==="
            docker --version 2>&1 || true
            echo ""
            echo "=== Docker info ==="
            docker info 2>&1 || true
        } > "$diag_file"
        
        log_error "Diagnostics saved to: $diag_file"
        cat "$diag_file"
        
        # Send diagnostics via Telegram if configured
        if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
            log_info "Sending diagnostics to Telegram..."
            local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            if [ -f "$script_dir/telegram_client.py" ]; then
                python3 "$script_dir/telegram_client.py" --send "❌ Docker installation failed. See attached diagnostics." 2>/dev/null || true
                python3 "$script_dir/telegram_client.py" --file "$diag_file" --caption "Docker Failure Diagnostics" 2>/dev/null || true
            fi
        fi
        
        return 1
    fi
    
    log_success "Docker service enabled and started"
}

# Verify Docker installation
verify_docker() {
    log_step "Verifying Docker installation"
    
    echo ""
    docker --version
    docker compose version
    echo ""
    
    log_info "Running hello-world container..."
    if docker run --rm hello-world >/dev/null 2>&1; then
        log_success "Docker is working correctly!"
    else
        log_warn "Docker test failed, but installation appears complete"
    fi
    
    echo ""
    log_info "Docker info:"
    docker info | grep -E "(Server Version|Storage Driver|Logging Driver|Operating System|Architecture)" || true
    echo ""
}

# Show post-installation steps
show_post_install() {
    log_step "Post-Installation Information"
    
    echo ""
    log_info "Docker is now installed and running"
    log_info ""
    log_info "To allow non-root users to run Docker:"
    log_info "  sudo usermod -aG docker <username>"
    log_info "  (user needs to log out and back in)"
    log_info ""
    log_info "Useful Docker commands:"
    log_info "  docker ps                    # List running containers"
    log_info "  docker images                # List images"
    log_info "  docker compose up -d         # Start compose services"
    log_info "  docker system prune -a       # Clean up unused resources"
    log_info ""
    log_info "Docker daemon configuration: /etc/docker/daemon.json"
    log_info "View Docker logs: journalctl -u docker"
    log_info "Container logs location: /var/lib/docker/containers/"
    echo ""
}

# Main function
main() {
    log_step "Docker Installation Script"
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Check if Docker is already installed
    if command -v docker >/dev/null 2>&1; then
        log_warn "Docker appears to be already installed"
        docker --version
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            exit 0
        fi
    fi
    
    # Installation steps
    remove_old_docker
    install_prerequisites
    add_docker_gpg_key
    add_docker_repository
    install_docker
    configure_docker_daemon
    
    # Try to enable and start Docker service
    if ! enable_docker_service; then
        log_error "Docker service failed to start - see diagnostics above"
        return 1
    fi
    
    verify_docker
    show_post_install
    
    log_step "Installation Complete"
    log_success "Docker has been successfully installed!"
}

# Run main if not sourced
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
