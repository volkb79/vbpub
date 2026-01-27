#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."

# Load shared env from repo root (like CIU). Override with PLAYWRIGHT_ENV_FILE.
ENV_FILE="${PLAYWRIGHT_ENV_FILE:-${ROOT_DIR}/.env}"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

export BUILD_DATE="${BUILD_DATE:-$(date -u +%Y%m%d)}"

cd "${SCRIPT_DIR}"

docker buildx bake all --load
