#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${PROJECT_ROOT}/.env"
if [[ -f "${ENV_FILE}" ]]; then
	# shellcheck source=/dev/null
	source "${ENV_FILE}"
fi

BUILD_DATE="${BUILD_DATE:-$(date -u +%Y%m%d)}"
export BUILD_DATE

maybe_export() {
	local var_name="$1"
	if [[ -n "${!var_name:-}" ]]; then
		export "${var_name}"
	fi
}

if [[ -n "${GITHUB_GHCR_IO_PAT:-}" ]]; then
	if [[ -z "${GITHUB_GHCR_IO_USERNAME:-}" ]]; then
		echo "[ERROR] GITHUB_GHCR_IO_USERNAME is required when GITHUB_GHCR_IO_PAT is set" >&2
		exit 1
	fi
	echo "${GITHUB_GHCR_IO_PAT}" | docker login ghcr.io -u "${GITHUB_GHCR_IO_USERNAME}" --password-stdin
fi

maybe_export REGISTRY
maybe_export NAMESPACE
maybe_export IMAGE_NAME

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
maybe_set_arg CONSUL_VERSION
maybe_set_arg FD_VERSION
maybe_set_arg FZF_VERSION
maybe_set_arg POSTGRESQL_CLIENT_VERSION
maybe_set_arg REDIS_TOOLS_VERSION
maybe_set_arg RIPGREP_VERSION
maybe_set_arg SHELLCHECK_VERSION
maybe_set_arg VAULT_VERSION
maybe_set_arg YQ_VERSION

docker buildx bake -f docker-bake.hcl all --push "${BAKE_SET_ARGS[@]}"