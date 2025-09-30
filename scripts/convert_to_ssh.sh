#!/bin/bash
#
# Convert Git repositories from HTTPS to SSH authentication
# This fixes authentication issues with GitHub Apps
#

set -e

echo "=== Converting Git repositories to SSH authentication ==="
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
    
    # Extract owner/repo from URL (works with both HTTPS formats)
    local ssh_url=""
    if [[ "$current_url" =~ github\.com[:/]([^/]+)/([^/\.]+) ]]; then
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        ssh_url="git@github.com:$owner/$repo.git"
    else
        echo "[ERROR] Could not parse GitHub URL: $current_url"
        return 1
    fi
    
    echo "  New SSH URL: $ssh_url"
    
    # Update the remote URL
    git remote set-url origin "$ssh_url"
    
    # Verify the change
    local new_url=$(git remote get-url origin)
    if [ "$new_url" = "$ssh_url" ]; then
        echo "  [SUCCESS] Remote URL updated"
    else
        echo "  [ERROR] Failed to update remote URL"
        return 1
    fi
    
    echo ""
}

# Test SSH connection first
echo "[INFO] Testing SSH connection to GitHub..."
if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    echo "[SUCCESS] SSH authentication working"
    echo ""
else
    echo "[ERROR] SSH authentication failed!"
    echo ""
    echo "Please add your SSH public key to GitHub:"
    echo "1. Copy this key:"
    echo ""
    cat ~/.ssh/id_ed25519.pub
    echo ""
    echo "2. Go to: https://github.com/settings/ssh/new"
    echo "3. Paste the key and save it"
    echo "4. Run this script again"
    echo ""
    exit 1
fi

# Convert all repositories
for repo in "${REPOS[@]}"; do
    convert_repo "$repo"
done

echo "[SUCCESS] All repositories converted to SSH authentication!"
echo ""
echo "You can now push changes using:"
echo "  git push origin main"
echo ""
echo "Or use VS Code's built-in Git features."