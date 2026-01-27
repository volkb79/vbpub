#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_plan() {
    echo -e "${BLUE}[PLAN]${NC} $*"
}

log_exec() {
    echo -e "${BLUE}[EXEC]${YELLOW} $*${NC}"
}

log_info "pwd: $(pwd)"
WORKSPACE_DIR="/workspaces/vbpub"
PLAN_FILE="${PLAN_FILE:-${WORKSPACE_DIR}/.vscode/copilot-plan.sh}"

if [[ -f "${PLAN_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${PLAN_FILE}"
fi

if [[ -z "${COPILOT_PLAN:-}" || -z "${COPILOT_EXEC:-}" ]]; then
    echo "COPILOT_PLAN or COPILOT_EXEC command not set" >&2
    exit 1
fi

log_plan "${COPILOT_PLAN}"
log_exec "${COPILOT_EXEC}"

cd "${WORKSPACE_DIR}"

eval "${COPILOT_EXEC}"
