#!/bin/bash

# **What happens on first clone:**
# 1. Git will prompt for GitHub username
# 2. Git will prompt for Personal Access Token (not password)
# 3. Credentials are stored securely in system keyring
# 4. Future Git operations use stored credentials automatically
# Add to ~/.bashrc if desired
install_gcm_latest() {
    echo "🔍 Installing latest Git Credential Manager..."
    
    # Install dependencies if needed
    if ! command -v jq &> /dev/null; then
        echo "📦 Installing jq dependency..."
        sudo apt update && sudo apt install -y jq curl
    fi
    
    # Get and install latest version
    local download_url=$(curl -s https://api.github.com/repos/git-ecosystem/git-credential-manager/releases/latest | \
        jq -r '.assets[] | select(.name | contains("gcm-linux_amd64") and endswith(".deb")) | .browser_download_url')
    
    if [[ -n "$download_url" && "$download_url" != "null" ]]; then
        local filename=$(basename "$download_url")
        curl -LO "$download_url"
        sudo dpkg -i "$filename"
        rm "$filename"
        git config --global credential.helper manager
        echo "✅ Git Credential Manager installed and configured!"
    else
        echo "❌ Failed to find download URL"
        return 1
    fi
}
