#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
DIST_DIR="${SCRIPT_DIR}/dist"
BUNDLE_DIR="${DIST_DIR}/bundle"
CLIENT_DIR="${DIST_DIR}/client"

VERSION="${VERSION:-0.1.0}"
BUILD_DATE="$(date -u +%Y%m%d)"

# Load shared env from repo root (like CIU). Override with PLAYWRIGHT_ENV_FILE.
ENV_FILE="${PLAYWRIGHT_ENV_FILE:-${ROOT_DIR}/.env}"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

log() {
  echo "[INFO] $*"
}

log "Preparing dist directories"
rm -rf "${DIST_DIR}"
mkdir -p "${BUNDLE_DIR}" "${CLIENT_DIR}"

log "Building client wheel"
cd "${SCRIPT_DIR}"
python -m pip wheel . -w "${CLIENT_DIR}"

log "Assembling stack bundle"
cp "${SCRIPT_DIR}/ciu.defaults.toml.j2" "${BUNDLE_DIR}/"
cp "${SCRIPT_DIR}/ciu-global.defaults.toml.j2" "${BUNDLE_DIR}/"
cp "${SCRIPT_DIR}/docker-compose.yml.j2" "${BUNDLE_DIR}/"
cp "${SCRIPT_DIR}/docker-compose.manual.yml" "${BUNDLE_DIR}/"
cp "${SCRIPT_DIR}/README.md" "${BUNDLE_DIR}/"
cp "${SCRIPT_DIR}/.env.sample" "${BUNDLE_DIR}/"
cp -R "${SCRIPT_DIR}/docs" "${BUNDLE_DIR}/docs"
cp -R "${SCRIPT_DIR}/reverse-proxy" "${BUNDLE_DIR}/reverse-proxy"
cp -R "${CLIENT_DIR}" "${BUNDLE_DIR}/client"

log "Creating stack bundle archive"
cd "${DIST_DIR}"
TARBALL="playwright-mcp-stack-bundle-${VERSION}.tar.gz"
tar -czf "${TARBALL}" bundle

log "Building and pushing image tags (version and latest)"
cd "${SCRIPT_DIR}"
export VERSION
export BUILD_DATE

docker buildx bake all --push

log "Done: ${DIST_DIR}/${TARBALL}"
