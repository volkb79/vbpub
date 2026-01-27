#!/usr/bin/env bash
set -euo pipefail

bash /workspaces/vbpub/playwright-mcp/release-and-upload.sh
bash /workspaces/vbpub/.vscode/publish-and-push.sh
