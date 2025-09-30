#!/bin/bash
#
# Switch to Writeable GitHub App
# Usage: ./switch_to_writeable_app.sh <APP_ID>
#

if [ $# -ne 1 ]; then
    echo "Usage: $0 <WRITEABLE_APP_ID>"
    echo ""
    echo "Example: $0 1234567"
    echo ""
    echo "To find your App ID:"
    echo "1. Go to https://github.com/settings/apps"
    echo "2. Click on your writeable app"
    echo "3. Copy the App ID from the URL or the page"
    exit 1
fi

WRITEABLE_APP_ID="$1"

# Set environment variables
export WRITEABLE_APP_ID="$WRITEABLE_APP_ID"
export GITHUB_APP_ID="$WRITEABLE_APP_ID"  
export GITHUB_APP_PRIVATE_KEY_PATH="/home/vb/.ssh/github_app_key.pem"

echo "=== Switching to Writeable GitHub App ==="
echo "App ID: $WRITEABLE_APP_ID"
echo "Key Path: $GITHUB_APP_PRIVATE_KEY_PATH"
echo ""

# Verify the key exists
if [ ! -f "$GITHUB_APP_PRIVATE_KEY_PATH" ]; then
    echo "[ERROR] Private key not found at $GITHUB_APP_PRIVATE_KEY_PATH"
    exit 1
fi

echo "[INFO] Private key found ✓"

# Test the configuration by getting app status
echo ""
echo "=== Testing Configuration ==="
cd "$(dirname "$0")"
./github_app_sync.sh --status

if [ $? -eq 0 ]; then
    echo ""
    echo "[SUCCESS] Writeable app configured successfully!"
    echo ""
    echo "To make this permanent, add these to your shell profile:"
    echo "export WRITEABLE_APP_ID=$WRITEABLE_APP_ID"
    echo "export GITHUB_APP_ID=$WRITEABLE_APP_ID"
    echo "export GITHUB_APP_PRIVATE_KEY_PATH=/home/vb/.ssh/github_app_key.pem"
else
    echo ""
    echo "[ERROR] Configuration test failed. Check the App ID and key."
    exit 1
fi