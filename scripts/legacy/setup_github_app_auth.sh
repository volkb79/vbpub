#!/bin/bash
#
# Setup GitHub App Authentication
# This script installs the credential helper and configures repositories
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== GitHub App Authentication Setup ==="
echo ""

# Check if we're in vbpub/scripts
if [[ "$SCRIPT_DIR" != */vbpub/scripts ]]; then
    echo "[ERROR] This script must be run from vbpub/scripts directory"
    echo "Current directory: $SCRIPT_DIR"
    exit 1
fi

echo "[INFO] Setting up from: $SCRIPT_DIR"

# Install credential helper
echo "[INFO] Installing GitHub App credential helper..."
mkdir -p "$HOME/bin"
cp "$SCRIPT_DIR/git-credential-github-app" "$HOME/bin/"
chmod +x "$HOME/bin/git-credential-github-app"

# Add ~/bin to PATH if not already there
if ! echo "$PATH" | grep -q "$HOME/bin"; then
    echo "[INFO] Adding ~/bin to PATH in shell profile..."
    for shell_config in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
        if [ -f "$shell_config" ]; then
            if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$shell_config"; then
                echo 'export PATH="$HOME/bin:$PATH"' >> "$shell_config"
                echo "  Added PATH to $shell_config"
            fi
            break
        fi
    done
fi

# Configure Git to use the credential helper
echo "[INFO] Configuring Git to use GitHub App credential helper..."
git config --global credential.helper github-app
git config --global credential."https://github.com".helper github-app

# Test the credential helper
echo "[INFO] Testing GitHub App credential helper..."
export PATH="$HOME/bin:$PATH"
if echo -e 'protocol=https\nhost=github.com\npath=test\n' | git-credential-github-app get >/dev/null 2>&1; then
    echo "[SUCCESS] GitHub App credential helper is working"
else
    echo "[ERROR] GitHub App credential helper failed!"
    echo ""
    echo "Make sure:"
    echo "1. WRITEABLE_APP_ID or GITHUB_APP_ID is set in your shell profile"
    echo "2. Private key exists at: \$GITHUB_APP_PRIVATE_KEY_PATH or ~/.ssh/github_app_key.pem"
    echo "3. The GitHub App has access to your repositories"
    exit 1
fi

echo ""
echo "[SUCCESS] GitHub App authentication setup complete!"
echo ""
echo "Next steps:"
echo "1. Reload your shell: source ~/.zshrc (or restart terminal)"
echo "2. Run: ./convert_to_github_app.sh (to convert repositories)"
echo "3. Test with: git push origin main (from any repository)"
echo ""
echo "The credential helper will automatically:"
echo "✅ Generate GitHub App tokens as needed"
echo "✅ Cache tokens until expiration"
echo "✅ Work with Git and VS Code seamlessly"