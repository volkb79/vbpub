#!/bin/bash
# GitHub App Configuration Helper
# Helps switch between read-only and writeable GitHub Apps

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

# Configuration
READONLY_APP_ID="2030793"
READONLY_KEY_PATH="$HOME/.ssh/github_app_key.pem.reader"
WRITEABLE_KEY_PATH="$HOME/.ssh/github_app_key.pem"

show_status() {
    echo "GitHub App Configuration Status:"
    echo "================================"
    
    # Check read-only app
    echo -e "\n${BLUE}Read-only App:${NC}"
    echo "  App ID: $READONLY_APP_ID"
    echo "  Key path: $READONLY_KEY_PATH"
    if [[ -f "$READONLY_KEY_PATH" ]]; then
        echo -e "  Status: ${GREEN}✓ Key file exists${NC}"
        echo "  Permissions: $(ls -l "$READONLY_KEY_PATH" | cut -d' ' -f1)"
    else
        echo -e "  Status: ${RED}✗ Key file missing${NC}"
    fi
    
    # Check writeable app
    echo -e "\n${BLUE}Writeable App:${NC}"
    if [[ -n "${WRITEABLE_APP_ID:-}" ]]; then
        echo "  App ID: $WRITEABLE_APP_ID"
    else
        echo -e "  App ID: ${YELLOW}Not configured (set WRITEABLE_APP_ID)${NC}"
    fi
    echo "  Key path: $WRITEABLE_KEY_PATH"
    if [[ -f "$WRITEABLE_KEY_PATH" ]]; then
        echo -e "  Status: ${GREEN}✓ Key file exists${NC}"
        echo "  Permissions: $(ls -l "$WRITEABLE_KEY_PATH" | cut -d' ' -f1)"
    else
        echo -e "  Status: ${RED}✗ Key file missing${NC}"
    fi
    
    # Current configuration
    echo -e "\n${BLUE}Current Environment:${NC}"
    echo "  GITHUB_APP_ID: ${GITHUB_APP_ID:-not set}"
    echo "  WRITEABLE_APP_ID: ${WRITEABLE_APP_ID:-not set}"
    echo "  GITHUB_APP_PRIVATE_KEY_PATH: ${GITHUB_APP_PRIVATE_KEY_PATH:-not set}"
    
    # Recommendation
    echo -e "\n${BLUE}Recommendation:${NC}"
    if [[ -f "$WRITEABLE_KEY_PATH" && -n "${WRITEABLE_APP_ID:-}" ]]; then
        success "Use writeable app for full sync capabilities"
        echo "  export WRITEABLE_APP_ID=$WRITEABLE_APP_ID"
        echo "  export PUSH_CHANGES=true"
    elif [[ -f "$WRITEABLE_KEY_PATH" ]]; then
        warn "Set WRITEABLE_APP_ID to use writeable app"
        echo "  export WRITEABLE_APP_ID=YOUR_NEW_APP_ID"
    elif [[ -f "$READONLY_KEY_PATH" ]]; then
        info "Use read-only app (limited to clone/pull)"
        echo "  export GITHUB_APP_ID=$READONLY_APP_ID"
    else
        error "No GitHub App keys found - setup required"
    fi
}

test_app() {
    local app_id="$1"
    local key_path="$2"
    local app_name="$3"
    
    if [[ ! -f "$key_path" ]]; then
        error "$app_name: Key file not found: $key_path"
        return 1
    fi
    
    info "Testing $app_name (App ID: $app_id)..."
    
    # Test by running the get_installation_id script with these credentials
    export GITHUB_APP_ID="$app_id"
    export GITHUB_APP_PRIVATE_KEY_PATH="$key_path"
    
    local script_dir="$(dirname "${BASH_SOURCE[0]}")"
    if "$script_dir/get_installation_id.sh" >/dev/null 2>&1; then
        success "$app_name authentication successful"
        return 0
    else
        error "$app_name authentication failed"
        return 1
    fi
}

test_all_apps() {
    echo "Testing GitHub App Authentication:"
    echo "=================================="
    
    local success_count=0
    local total_count=0
    
    # Test read-only app
    ((total_count++))
    if test_app "$READONLY_APP_ID" "$READONLY_KEY_PATH" "Read-only App"; then
        ((success_count++))
    fi
    
    # Test writeable app if configured
    if [[ -n "${WRITEABLE_APP_ID:-}" ]]; then
        ((total_count++))
        if test_app "$WRITEABLE_APP_ID" "$WRITEABLE_KEY_PATH" "Writeable App"; then
            ((success_count++))
        fi
    else
        warn "Writeable app not configured (WRITEABLE_APP_ID not set)"
    fi
    
    echo -e "\n${BLUE}Test Results: $success_count/$total_count apps working${NC}"
    return $((total_count - success_count))
}

setup_writeable_app() {
    echo "Setting up Writeable GitHub App:"
    echo "==============================="
    
    read -p "Enter your writeable GitHub App ID: " writeable_id
    
    if [[ -z "$writeable_id" ]]; then
        error "App ID cannot be empty"
        return 1
    fi
    
    info "Configuring writeable app with ID: $writeable_id"
    
    # Check if key file exists
    if [[ ! -f "$WRITEABLE_KEY_PATH" ]]; then
        error "Key file not found: $WRITEABLE_KEY_PATH"
        echo "Please ensure you have:"
        echo "1. Downloaded the private key for your writeable GitHub App"
        echo "2. Saved it as: $WRITEABLE_KEY_PATH"
        echo "3. Set proper permissions: chmod 600 $WRITEABLE_KEY_PATH"
        return 1
    fi
    
    # Test the configuration
    if test_app "$writeable_id" "$WRITEABLE_KEY_PATH" "Writeable App"; then
        success "Writeable app configuration successful!"
        
        echo -e "\n${GREEN}Next steps:${NC}"
        echo "1. Add this to your shell profile (.bashrc, .zshrc, etc.):"
        echo "   export WRITEABLE_APP_ID=$writeable_id"
        echo ""
        echo "2. To use writeable app for sync:"
        echo "   export PUSH_CHANGES=true"
        echo "   ./github_app_sync.sh"
        
        return 0
    else
        error "Writeable app configuration failed"
        return 1
    fi
}

show_usage() {
    cat <<-EOF
	GitHub App Configuration Helper

	USAGE:
	    $0 [COMMAND]

	COMMANDS:
	    status              Show current GitHub App configuration status
	    test               Test authentication for all configured apps
	    setup-writeable    Interactive setup for writeable GitHub App
	    help               Show this help message

	EXAMPLES:
	    $0 status          # Check current configuration
	    $0 test            # Test all app authentications
	    $0 setup-writeable # Configure new writeable app

	ENVIRONMENT VARIABLES:
	    WRITEABLE_APP_ID   Your writeable GitHub App ID (for setup)

EOF
}

main() {
    case "${1:-status}" in
        status|--status|-s)
            show_status
            ;;
        test|--test|-t)
            test_all_apps
            ;;
        setup-writeable|setup)
            setup_writeable_app
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            error "Unknown command: $1"
            show_usage
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi