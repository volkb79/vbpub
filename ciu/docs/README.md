# CIU and CIU Deploy

This directory contains the DST-DNS deployment engine and orchestrator.

## Components

### CIU (ciu)
Single-stack renderer/runner. CIU renders the stack configuration, resolves directives, renders docker-compose.yml, runs hooks, and starts the stack.

**Key responsibilities**:
- Render stack TOML from templates (ciu.defaults.toml.j2 → ciu.toml)
- Merge global and stack config (ciu-global.toml + ciu.toml)
- Resolve secret directives (Vault/local/external)
- Render docker-compose.yml from docker-compose.yml.j2
- Run pre/post compose hooks
- Invoke docker compose for a single stack

**Common usage**:
- Render and run a stack
  - ciu -d infra/db-core
- Render TOML only
  - ciu -d infra/db-core --render-toml
- Dry-run (render without compose)
  - ciu -d infra/db-core --dry-run
- Print merged context (debugging)
  - ciu -d infra/db-core --print-context

**Inputs**:
- ciu-global.toml (rendered global config)
- ciu.toml (rendered stack config)
- docker-compose.yml.j2 (stack template)
- Optional hooks declared in stack config

**Outputs**:
- docker-compose.yml (rendered)
- ciu.toml (rendered)

### CIU Deploy (ciu-deploy)
Multi-stack orchestrator. CIU Deploy sequences multiple stacks using deployment phases/groups defined in ciu-global.toml.

**Key responsibilities**:
- Stop, clean, build, deploy actions
- Phase/group selection and ordering
- Health checks and selftests
- Workspace environment enforcement (.env.workspace)

**Common usage**:
- Default deploy (all enabled phases)
  - ciu-deploy --deploy
- Full restart (stop + clean + deploy)
  - ciu-deploy --stop --clean --deploy
- Build images with Buildx Bake
  - ciu-deploy --build
- List groups
  - ciu-deploy --list-groups
- Deploy selected groups
  - ciu-deploy --groups infra,apps --deploy

**Inputs**:
- ciu-global.toml (rendered global config)
- deployment phases/groups in [deploy.phases] and [deploy.groups]

## Workspace prerequisites

- Run env-workspace-setup-generate.sh and source .env.workspace
- Ensure PYTHON_EXECUTABLE points to the workspace venv
- Build images with docker buildx bake before deploy

## Build & install the CIU package

**Editable install (development)**:
- From repo root (or any location):
  - pip install -e /path/to/vbpub/ciu

**Build a wheel (release/CI)**:
- From the CIU repo root:
  - python -m pip wheel . -w dist
- Output: dist/ciu-*.whl

**Publish a wheel (GitHub Releases)**:
- From the CIU repo root:
  - tools/publish-wheel-release.py
- Requires `CIU_RELEASE_TOKEN` (or `GITHUB_TOKEN`) and `GITHUB_REPOSITORY` (or `CIU_RELEASE_REPO`).
- Publishes a versioned release and a stable `ciu-latest` release asset.

## Running tests

- From the CIU repo root:
  - pytest

## Where CIU is installed in dstdns

CIU is installed as a Python package (not a repo-local script):

- **Devcontainer**: .devcontainer/post-create.sh installs from `CIU_PKG_URL`
- **CI/GitHub Actions**: .github/actions/env-setup.sh installs from `CIU_PKG_URL`
- **Tools base image**: tools/base/Dockerfile.base installs from `CIU_WHEEL_URL`

Required environment variables:
- `CIU_PKG_URL` (wheel artifact URL for devcontainer/CI)
- `CIU_WHEEL_URL` (wheel artifact URL for base image build)

Optional environment variables:
- `CIU_PKG_SHA256` and `CIU_WHEEL_SHA256` for integrity verification
- `CIU_PKG_CACHE_DIR` to control local caching (defaults to `.ci/ciu-dist` and is gitignored)

Recommended distribution:
- Publish the CIU wheel to GitHub Releases and set `CIU_PKG_URL` / `CIU_WHEEL_URL` to the release asset URL.

All dstdns scripts and docs should invoke `ciu` and `ciu-deploy` from the installed package.

## Separation of concerns

- CIU is stack-scoped: one stack per run, no global orchestration.
- CIU Deploy is orchestration-only: no template rendering outside CIU.

## Troubleshooting

- Missing ciu-global.toml: run ciu --render-toml
- Missing images: run docker buildx bake all-services --load
- Missing workspace env: run env-workspace-setup-generate.sh and source .env.workspace

## Detailed Documentation

- Configuration spec: docs/CONFIG.md
- CIU internals: docs/CIU.md
- CIU Deploy internals: docs/CIU-DEPLOY.md

## Tests and Examples

- Tests: tests/
- Hook examples: src/ciu/hooks/examples
