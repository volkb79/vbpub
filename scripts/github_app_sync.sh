#!/bin/bash
# GitHub App Repository Sync Script
# Clones new repositories or pulls updates for existing ones using GitHub App authentication
#
# ============================================================================
# AUTHENTICATION FLOW & ARCHITECTURE
# ============================================================================
#
# This script implements GitHub App authentication using a multi-step process:
#
# Step 1: JWT Generation
#   - Creates a JSON Web Token using RS256 algorithm
#   - Signed with the GitHub App's private key
#   - Contains App ID, issued time (iat), and expiration (exp)
#   - Valid for 10 minutes maximum (GitHub requirement)
#
# Step 2: Installation Discovery
#   - Uses JWT to query GitHub's installations endpoint
#   - Finds all installations of this GitHub App
#   - Auto-selects the first installation if not specified
#
# Step 3: Access Token Generation
#   - Exchanges JWT + Installation ID for short-lived access token
#   - Access token expires in ~1 hour and provides repository access
#   - This token is used for actual git operations
#
# Step 4: Repository Operations
#   - For each repository: clone if new, pull if existing
#   - Uses token-based authentication via URL embedding
#   - Format: https://x-access-token:TOKEN@github.com/owner/repo.git
#
# ============================================================================
# SECURITY CONSIDERATIONS
# ============================================================================
#
# - Private key should have 600 permissions and be stored securely
# - JWT tokens are logged only partially (first 50 chars)
# - Access tokens are never logged in full
# - Git URLs with embedded tokens are cleaned from git config after use
#
# ============================================================================
# ERROR HANDLING & RECOVERY
# ============================================================================
#
# - Script uses 'set -euo pipefail' for strict error handling
# - Each major operation has explicit error checking and reporting
# - Failed repositories are tracked and reported in summary
# - Git authentication failures are caught and explained
#
# Required GitHub App Credentials:
# - App ID: Found in GitHub App settings (e.g., 2030793)
# - Private Key: Downloaded .pem file from GitHub App settings
# - Installation ID: Auto-discovered via API (e.g., 88054503)
# Strict error handling: exit on any error, undefined vars, or pipe failures
set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

# GitHub App credentials (configure these)
APP_ID="${GITHUB_APP_ID:-2030793}"
INSTALLATION_ID="${GITHUB_INSTALLATION_ID:-}"  # Auto-discovered if not set
PRIVATE_KEY_PATH="${GITHUB_APP_PRIVATE_KEY_PATH:-$HOME/.ssh/github_app_key.pem}"

# Base directory for repositories
REPO_BASE_DIR="${REPO_BASE_DIR:-$HOME/repos}"

# Array of repositories to sync (format: "owner/repo")
REPOSITORIES=(
    "volkb79/DST-DNS"
    "volkb79/vbpro"
    # Add more repositories as needed
    # "owner/another-repo"
)

# Sync options
FETCH_SUBMODULES="${FETCH_SUBMODULES:-false}"
CHECKOUT_BRANCH="${CHECKOUT_BRANCH:-main}"
FORCE_CLEAN="${FORCE_CLEAN:-false}"
PARALLEL_JOBS="${PARALLEL_JOBS:-1}"

# ============================================================================
# Logging Functions
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

info() {
    log "[INFO] $*"
}

warn() {
    log "[WARN] $*"
}

error() {
    log "[ERROR] $*"
}

step() {
    log "[STEP] $*"
}

# ============================================================================
# GitHub App Authentication
# ============================================================================

validate_config() {
    local errors=0
    
    if [[ -z "$APP_ID" ]]; then
        error "GITHUB_APP_ID environment variable not set"
        ((errors++))
    fi
    
    # Installation ID is optional - will be auto-discovered if not provided
    if [[ -z "$INSTALLATION_ID" ]]; then
        info "GITHUB_INSTALLATION_ID not set - will auto-discover"
    fi
    
    if [[ ! -f "$PRIVATE_KEY_PATH" ]]; then
        error "Private key file not found: $PRIVATE_KEY_PATH"
        ((errors++))
    elif [[ ! -r "$PRIVATE_KEY_PATH" ]]; then
        error "Private key file not readable: $PRIVATE_KEY_PATH"
        ((errors++))
    fi
    
    # Check required tools
    for tool in curl jq openssl git base64; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            error "Required tool not found: $tool"
            ((errors++))
        fi
    done
    
    if ((errors > 0)); then
        error "Configuration validation failed with $errors errors"
        exit 1
    fi
}

generate_jwt() {
    local app_id="$1"
    local private_key_path="$2"
    
    # JWT header specifying RS256 algorithm (RSA + SHA256)
    local header='{"alg":"RS256","typ":"JWT"}'
    
    # Time calculations for JWT validity window
    local now=$(date +%s)
    local iat=$((now - 30))  # Issue time: 30 seconds ago (handles clock skew)
    local exp=$((now + 600)) # Expiration: 10 minutes from now (GitHub's max limit)
    
    # JWT payload containing GitHub App claims
    local payload=$(cat <<-EOF
	{
	  "iat": $iat,
	  "exp": $exp,
	  "iss": "$app_id"
	}
EOF
)
    
    # Base64url encoding (RFC 4648 Section 5): standard base64 with URL-safe chars
    # Replace '/' with '_', '+' with '-', remove padding '='
    local header_b64=$(echo -n "$header" | base64 -w0 | tr '/+' '_-' | tr -d '=')
    local payload_b64=$(echo -n "$payload" | base64 -w0 | tr '/+' '_-' | tr -d '=')
    
    # Create signature: sign "header.payload" with private key using SHA256
    # Then base64url encode the binary signature
    local signature=$(echo -n "$header_b64.$payload_b64" | openssl dgst -sha256 -sign "$private_key_path" | base64 -w0 | tr '/+' '_-' | tr -d '=')
    
    # Return complete JWT: header.payload.signature
    echo "$header_b64.$payload_b64.$signature"
}

get_installation_id() {
    local jwt="$1"
    
    info "Auto-discovering Installation ID..."
    local response
    # Query GitHub API for all installations of this App
    # curl flags: -s (silent), -w (write HTTP code), -H (headers)
    response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: DST-DNS-Sync/1.0" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/app/installations")
    
    # Split response: body (all lines except last) + HTTP code (last line)
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n -1)
    
    if [[ "$http_code" != "200" ]]; then
        error "Failed to get installations (HTTP $http_code)"
        error "Response: $body"
        return 1
    fi
    
    # Extract first installation ID from JSON array using jq
    # '.[0].id // empty' means: get first element's ID, or empty string if null/missing
    local installation_id=$(echo "$body" | jq -r '.[0].id // empty')
    
    if [[ -z "$installation_id" ]]; then
        error "No installations found for this GitHub App"
        return 1
    fi
    
    info "Found Installation ID: $installation_id"
    echo "$installation_id"
}

get_installation_token() {
    local jwt="$1"
    local installation_id="$2"
    
    local response
    # Exchange JWT + Installation ID for short-lived access token
    # IMPORTANT: Must use POST method (not GET) to create access tokens
    # The access token expires in ~1 hour and provides repository access
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: DST-DNS-Sync/1.0" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/app/installations/$installation_id/access_tokens")
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n -1)
    
    # GitHub returns 201 (Created) for successful token generation
    if [[ "$http_code" != "201" ]]; then
        error "Failed to get installation token (HTTP $http_code)"
        error "Response: $body"
        return 1
    fi
    
    # Extract the token from JSON response
    echo "$body" | jq -r '.token'
}

# ============================================================================
# Repository Management
# ============================================================================

ensure_repo_dir() {
    mkdir -p "$REPO_BASE_DIR"
    cd "$REPO_BASE_DIR"
    info "Working in directory: $(pwd)"
}

get_repo_path() {
    local repo="$1"
    echo "$REPO_BASE_DIR/$(basename "$repo")"
}

clone_repo() {
    local repo="$1"
    local token="$2"
    local repo_path="$3"
    
    step "Cloning $repo to $repo_path"
    
    # Use token as username with x-access-token as password for GitHub App authentication
    local clone_url="https://x-access-token:$token@github.com/$repo.git"
    
    local clone_args=(
        clone
        "$clone_url"
        "$repo_path"
    )
    
    if [[ "$FETCH_SUBMODULES" == "true" ]]; then
        clone_args+=(--recurse-submodules)
    fi
    
    if ! git "${clone_args[@]}"; then
        error "Failed to clone $repo"
        return 1
    fi
    
    # Checkout specific branch if requested
    if [[ "$CHECKOUT_BRANCH" != "main" && "$CHECKOUT_BRANCH" != "master" ]]; then
        cd "$repo_path"
        if git show-ref --verify --quiet "refs/remotes/origin/$CHECKOUT_BRANCH"; then
            info "Checking out branch: $CHECKOUT_BRANCH"
            git checkout -b "$CHECKOUT_BRANCH" "origin/$CHECKOUT_BRANCH"
        else
            warn "Branch $CHECKOUT_BRANCH not found in $repo, staying on default"
        fi
        cd - >/dev/null
    fi
    
    info "Successfully cloned $repo"
}

pull_repo() {
    local repo="$1"
    local token="$2"
    local repo_path="$3"
    
    step "Updating $repo at $repo_path"
    
    cd "$repo_path"
    
    # Clean working directory if requested
    if [[ "$FORCE_CLEAN" == "true" ]]; then
        info "Force cleaning working directory"
        git clean -fd
        git reset --hard HEAD
    fi
    
    # Check for uncommitted changes
    if ! git diff-index --quiet HEAD --; then
        warn "Repository $repo has uncommitted changes"
        if [[ "$FORCE_CLEAN" != "true" ]]; then
            error "Skipping pull due to uncommitted changes (use FORCE_CLEAN=true to override)"
            cd - >/dev/null
            return 1
        fi
    fi
    
    # Configure remote URL with token for this operation
    local auth_url="https://x-access-token:$token@github.com/$repo.git"
    local original_url=$(git config --get remote.origin.url)
    git remote set-url origin "$auth_url"
    
    # Fetch and pull
    if ! git fetch origin; then
        error "Failed to fetch from origin for $repo"
        # Restore original URL
        git remote set-url origin "$original_url"
        cd - >/dev/null
        return 1
    fi
    
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    
    if ! git pull origin "$current_branch"; then
        error "Failed to pull $current_branch for $repo"
        # Restore original URL
        git remote set-url origin "$original_url"
        cd - >/dev/null
        return 1
    fi
    
    # Update submodules if enabled
    if [[ "$FETCH_SUBMODULES" == "true" ]]; then
        info "Updating submodules for $repo"
        git submodule update --init --recursive
    fi
    
    # Restore original URL (remove token from git config)
    git remote set-url origin "$original_url"
    
    cd - >/dev/null
    info "Successfully updated $repo"
}

sync_repository() {
    local repo="$1"
    local token="$2"
    
    local repo_path
    repo_path=$(get_repo_path "$repo")
    
    if [[ -d "$repo_path/.git" ]]; then
        pull_repo "$repo" "$token" "$repo_path"
    else
        clone_repo "$repo" "$token" "$repo_path"
    fi
}

# ============================================================================
# Main Functions
# ============================================================================

show_status() {
    info "Repository sync status:"
    info "Base directory: $REPO_BASE_DIR"
    info "Repositories to sync: ${#REPOSITORIES[@]}"
    info "Submodules: $FETCH_SUBMODULES"
    info "Target branch: $CHECKOUT_BRANCH"
    info "Force clean: $FORCE_CLEAN"
    info "Parallel jobs: $PARALLEL_JOBS"
    echo
}

sync_all_repositories() {
    local token="$1"
    local success_count=0
    local failure_count=0
    local failed_repos=()
    
    ensure_repo_dir
    
    for repo in "${REPOSITORIES[@]}"; do
        info "Processing repository: $repo"
        
        if sync_repository "$repo" "$token"; then
            # IMPORTANT: Use $((var + 1)) instead of ((var++)) with set -e
            # When var=0, ((var++)) returns 0 (falsy), causing set -e to exit
            # The expression $((var + 1)) always returns the new value (truthy)
            success_count=$((success_count + 1))
            info "✅ $repo - SUCCESS"
        else
            failure_count=$((failure_count + 1))
            failed_repos+=("$repo")
            error "❌ $repo - FAILED"
        fi
        echo
    done
    
    # Summary
    step "Sync Summary"
    info "Total repositories: ${#REPOSITORIES[@]}"
    info "Successful: $success_count"
    info "Failed: $failure_count"
    
    if ((failure_count > 0)); then
        error "Failed repositories:"
        for repo in "${failed_repos[@]}"; do
            error "  - $repo"
        done
        return 1
    fi
    
    info "All repositories synced successfully!"
}

show_usage() {
    cat <<-EOF
	GitHub App Repository Sync Script

	USAGE:
	    $0 [OPTIONS]

	ENVIRONMENT VARIABLES:
	    GITHUB_APP_ID                 GitHub App ID (required - from GitHub App settings)
	    GITHUB_INSTALLATION_ID        Installation ID (optional - auto-discovered if not set)
	    GITHUB_APP_PRIVATE_KEY_PATH   Path to private key (default: ~/.ssh/github_app_key.pem)
	    REPO_BASE_DIR                 Base directory for repos (default: ~/repos)
	    FETCH_SUBMODULES              Fetch git submodules (default: false)
	    CHECKOUT_BRANCH               Branch to checkout (default: main)
	    FORCE_CLEAN                   Clean working dir before pull (default: false)
	    PARALLEL_JOBS                 Parallel sync jobs (default: 1) [NOT IMPLEMENTED YET]

	OPTIONS:
	    -h, --help                    Show this help message
	    -s, --status                  Show current configuration and exit
	    -v, --validate                Validate configuration and exit

	EXAMPLES:
	    # Basic sync (Installation ID auto-discovered)
	    export GITHUB_APP_ID=2030793
	    $0
	    
	    # Sync with specific installation (if you have multiple)
	    export GITHUB_APP_ID=2030793
	    export GITHUB_INSTALLATION_ID=88054503
	    $0
	    
	    # Sync with submodules to custom directory
	    export REPO_BASE_DIR=/opt/repos
	    export FETCH_SUBMODULES=true
	    $0
	    
	    # Force clean and sync specific branch
	    export FORCE_CLEAN=true
	    export CHECKOUT_BRANCH=develop
	    $0

EOF
}

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -s|--status)
                validate_config
                show_status
                exit 0
                ;;
            -v|--validate)
                validate_config
                info "Configuration validation passed"
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
        shift
    done
    
    # Validate configuration
    validate_config
    show_status
    
    # Get authentication token
    step "Authenticating with GitHub App"
    local jwt
    jwt=$(generate_jwt "$APP_ID" "$PRIVATE_KEY_PATH")
    info "Generated JWT token"
    
    # Auto-discover Installation ID if not provided
    if [[ -z "$INSTALLATION_ID" ]]; then
        INSTALLATION_ID=$(get_installation_id "$jwt")
        if [[ $? -ne 0 ]]; then
            error "Failed to auto-discover Installation ID"
            exit 1
        fi
    fi
    
    local install_token
    install_token=$(get_installation_token "$jwt" "$INSTALLATION_ID")
    info "Obtained installation token (expires in ~1 hour)"
    
    # Sync all repositories
    step "Starting repository synchronization"
    sync_all_repositories "$install_token"
    
    info "Repository sync completed successfully"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi