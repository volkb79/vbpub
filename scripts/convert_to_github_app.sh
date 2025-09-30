#!/bin/bash
#
# Convert repositories to use HTTPS with GitHub App authentication
# This is the recommended approach over SSH for automation
#

set -e

echo "=== Converting repositories to GitHub App authentication ==="
echo ""

# Detect if running from vbpub/scripts or ~/repos
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$SCRIPT_DIR" == */vbpub/scripts ]]; then
    REPO_BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
else
    REPO_BASE_DIR="$HOME/repos"
fi

REPOS=(
    "DST-DNS"
    "vbpro" 
    "vbpub"
)

echo "[INFO] Script directory: $SCRIPT_DIR"
echo "[INFO] Repository base directory: $REPO_BASE_DIR"

# Function to convert a single repository
convert_repo() {
    local repo_name="$1"
    local repo_dir="$REPO_BASE_DIR/$repo_name"
    
    if [ ! -d "$repo_dir" ]; then
        echo "[WARN] Repository directory not found: $repo_dir"
        return 1
    fi
    
    echo "[INFO] Converting $repo_name..."
    cd "$repo_dir"
    
    # Get current remote URL
    local current_url=$(git remote get-url origin 2>/dev/null || echo "")
    if [ -z "$current_url" ]; then
        echo "[WARN] No origin remote found in $repo_name"
        return 1
    fi
    
    echo "  Current URL: $current_url"
    
    # Extract owner/repo from URL (works with SSH, HTTPS, and token URLs)
    local owner=""
    local repo=""
    
    if [[ "$current_url" =~ github\.com[:/]([^/]+)/([^/\.]+) ]]; then
        owner="${BASH_REMATCH[1]}"
        repo="${BASH_REMATCH[2]}"
    else
        echo "[ERROR] Could not parse GitHub URL: $current_url"
        return 1
    fi
    
    # Create clean HTTPS URL
    local https_url="https://github.com/$owner/$repo.git"
    echo "  New HTTPS URL: $https_url"
    
    # Update the remote URL
    git remote set-url origin "$https_url"
    
    # Verify the change
    local new_url=$(git remote get-url origin)
    if [ "$new_url" = "$https_url" ]; then
        echo "  [SUCCESS] Remote URL updated"
    else
        echo "  [ERROR] Failed to update remote URL"
        return 1
    fi
    
    echo ""
}

# Test GitHub App credential helper
echo "[INFO] Testing GitHub App credential helper..."
if git-credential-github-app get <<< $'protocol=https\nhost=github.com\npath=test\n' >/dev/null 2>&1; then
    echo "[SUCCESS] GitHub App credential helper is working"
    echo ""
else
    echo "[ERROR] GitHub App credential helper failed!"
    echo ""
    echo "Make sure:"
    echo "1. GITHUB_APP_ID is set to: $GITHUB_APP_ID"
    echo "2. Private key exists at: $GITHUB_APP_PRIVATE_KEY_PATH"
    echo "3. The app has access to your repositories"
    echo ""
    exit 1
fi

# Convert all repositories
for repo in "${REPOS[@]}"; do
    convert_repo "$repo"
done

echo "[SUCCESS] All repositories converted to GitHub App authentication!"
echo ""
echo "Benefits of GitHub App authentication:"
echo "✅ Fine-grained permissions (repository-specific)"
echo "✅ Short-lived tokens (automatically refreshed)"
echo "✅ Better audit trail and security"
echo "✅ Higher API rate limits"
echo "✅ Recommended for automation and VS Code"
echo ""
echo "You can now push/pull using Git or VS Code normally!"