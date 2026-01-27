#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"

LOG_DIR="${PROJECT_ROOT}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/build-images-$(date -u +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "[INFO] Logging to ${LOG_FILE}"

ENV_FILE="${VBPUB_ENV_FILE:-${REPO_ROOT}/.env}"
if [[ -f "${ENV_FILE}" ]]; then
	# shellcheck source=/dev/null
	source "${ENV_FILE}"
elif [[ -f "${PROJECT_ROOT}/.env" ]]; then
	# shellcheck source=/dev/null
	source "${PROJECT_ROOT}/.env"
fi

BUILD_DATE="${BUILD_DATE:-$(date -u +%Y%m%d)}"
export BUILD_DATE

# Example override:
# B2_VERSION=4.5.0 ./build-images.sh

maybe_export() {
	local var_name="$1"
	if [[ -n "${!var_name:-}" ]]; then
		export "${var_name}"
	fi
}

maybe_export REGISTRY
maybe_export GITHUB_USERNAME
maybe_export GITHUB_REPO

maybe_export CIU_LATEST_TAG
maybe_export CIU_LATEST_ASSET_NAME

cd "${PROJECT_ROOT}"

BAKE_SET_ARGS=()
maybe_set_arg() {
	local var_name="$1"
	if [[ -n "${!var_name:-}" ]]; then
		BAKE_SET_ARGS+=("--set" "base.args.${var_name}=${!var_name}")
	fi
}

maybe_set_arg AWSCLI_VERSION
maybe_set_arg B2_VERSION
maybe_set_arg BACKPORTS_URI
maybe_set_arg BAT_VERSION
maybe_set_arg DELTA_VERSION
maybe_set_arg GH_VERSION
maybe_set_arg CONSUL_VERSION
maybe_set_arg FD_VERSION
maybe_set_arg FZF_VERSION
maybe_set_arg POSTGRESQL_CLIENT_VERSION
maybe_set_arg REDIS_TOOLS_VERSION
maybe_set_arg RIPGREP_VERSION
maybe_set_arg RGA_VERSION
maybe_set_arg SHELLCHECK_VERSION
maybe_set_arg VAULT_VERSION
maybe_set_arg YQ_VERSION
maybe_set_arg GITHUB_USERNAME
maybe_set_arg GITHUB_REPO
maybe_set_arg CIU_LATEST_TAG
maybe_set_arg CIU_LATEST_ASSET_NAME
maybe_set_arg OCI_TITLE
maybe_set_arg OCI_DESCRIPTION
maybe_set_arg OCI_SOURCE
maybe_set_arg OCI_DOCUMENTATION
maybe_set_arg OCI_URL
maybe_set_arg OCI_LICENSES
maybe_set_arg OCI_VENDOR
maybe_set_arg OCI_VERSION
maybe_set_arg OCI_REVISION
maybe_set_arg OCI_CREATED

docker buildx bake -f docker-bake.hcl all --load "${BAKE_SET_ARGS[@]}"