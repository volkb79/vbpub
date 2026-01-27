#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Always generate the stack bundle during pushes.
bash "${SCRIPT_DIR}/release-stack-bundle.sh"
