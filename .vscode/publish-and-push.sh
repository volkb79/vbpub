#!/usr/bin/env bash
set -euo pipefail

PYTHON_BIN="/workspaces/vbpub/.venv/bin/python"

echo "[STEP] Ensure pip is available"
if ! "${PYTHON_BIN}" -m pip --version; then
	"${PYTHON_BIN}" -m ensurepip --upgrade
	"${PYTHON_BIN}" -m pip install --upgrade pip wheel
fi

echo "[STEP] Publish CIU wheel"
"${PYTHON_BIN}" /workspaces/vbpub/ciu/tools/publish-wheel-release.py

echo "[STEP] Build vsc-devcontainer images"
bash /workspaces/vbpub/vsc-devcontainer/build-images.sh

echo "[STEP] Push vsc-devcontainer images"
bash /workspaces/vbpub/vsc-devcontainer/push-images.sh
