#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
DIST_DIR="${SCRIPT_DIR}/dist"

# Load shared env from repo root (like CIU). Override with PLAYWRIGHT_ENV_FILE.
ENV_FILE="${PLAYWRIGHT_ENV_FILE:-${ROOT_DIR}/.env}"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

if [[ -z "${GH_TOKEN:-}" && -n "${GITHUB_PUSH_PAT:-}" ]]; then
  export GH_TOKEN="${GITHUB_PUSH_PAT}"
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "[ERROR] GH_TOKEN or GITHUB_PUSH_PAT is required" >&2
  exit 1
fi

VERSION="${VERSION:-0.1.0}"
BUNDLE_NAME="playwright-mcp-stack-bundle"
TAG="${BUNDLE_NAME}-${VERSION}"
LATEST_TAG="${BUNDLE_NAME}-latest"
REPO="volkb79-2/vbpub"

VERSIONED_ARCHIVE="${DIST_DIR}/${BUNDLE_NAME}-${VERSION}.tar.gz"
LEGACY_ASSET_NAME="${BUNDLE_NAME}-latest.tar.gz"

if [[ ! -f "${VERSIONED_ARCHIVE}" ]]; then
  echo "[ERROR] Missing bundle: ${VERSIONED_ARCHIVE}" >&2
  exit 1
fi

if ! gh release view "${TAG}" --repo "${REPO}" >/dev/null 2>&1; then
  gh release create "${TAG}" --repo "${REPO}" --title "${TAG}" --notes "Playwright MCP bundle ${TAG}" \
    "${VERSIONED_ARCHIVE}"
  exit 0
fi

LEGACY_ASSET_ID=$(gh release view "${TAG}" --repo "${REPO}" --json assets --jq ".assets[] | select(.name == \"${LEGACY_ASSET_NAME}\") | .id" 2>/dev/null || true)
if [[ -n "${LEGACY_ASSET_ID}" ]]; then
  gh api -X DELETE "/repos/volkb79-2/vbpub/releases/assets/${LEGACY_ASSET_ID}" >/dev/null
fi

gh release upload "${TAG}" --repo "${REPO}" --clobber "${VERSIONED_ARCHIVE}"

if ! gh release view "${LATEST_TAG}" --repo "${REPO}" >/dev/null 2>&1; then
  gh release create "${LATEST_TAG}" --repo "${REPO}" --title "${LATEST_TAG}" --notes "Playwright MCP bundle latest" \
    "${VERSIONED_ARCHIVE}"
  exit 0
fi

LEGACY_LATEST_ASSET_ID=$(gh release view "${LATEST_TAG}" --repo "${REPO}" --json assets --jq ".assets[] | select(.name == \"${LEGACY_ASSET_NAME}\") | .id" 2>/dev/null || true)
if [[ -n "${LEGACY_LATEST_ASSET_ID}" ]]; then
  gh api -X DELETE "/repos/volkb79-2/vbpub/releases/assets/${LEGACY_LATEST_ASSET_ID}" >/dev/null
fi

gh release upload "${LATEST_TAG}" --repo "${REPO}" --clobber "${VERSIONED_ARCHIVE}"
