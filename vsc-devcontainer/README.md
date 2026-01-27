# VSC Devcontainer Base Images

Pre-built devcontainer base images for VS Code workspaces. This replaces live builds from `.devcontainer/Dockerfile` and provides consistent, versioned artifacts.

## Images

Four variants are built:
- Bookworm + Python 3.11
- Bookworm + Python 3.13
- Trixie + Python 3.11
- Trixie + Python 3.13

Base images:
- Bookworm uses `mcr.microsoft.com/devcontainers/python` for VS Code integration.
- Trixie uses official `python:<version>-trixie` images with a `vscode` user created during build.

Each image tag includes Debian version, Python version, and build date:

```
<registry>/<github_username>/vsc-devcontainer:<debian>-py<python>-<YYYYMMDD>
```

Example:
```
ghcr.io/acme/vsc-devcontainer:bookworm-py3.13-20260117
```

## Contents

The image pre-installs:
- Debian System tools from distribution (curl, git, jq, dnsutils, ...)
- Modern tools (latest version) from its own repos (bat, fd, ripgrep, shellcheck, fzf, yq) at system level
- Common CLIs (Consul CLI, Vault, Redis, Postgresql, AWS CLI)
- Python packages installed into a per-user virtualenv at `/home/vscode/.venv`

Python packages are installed directly in the Dockerfile (see the `pip install` list). 

The image sets:
- `VIRTUAL_ENV=/home/vscode/.venv`
- `PATH=/home/vscode/.venv/bin:$PATH`

If CIU wheel inputs are provided at build time, the CIU wheel is downloaded and installed into the same virtualenv (optional SHA256 verification via `CIU_WHEEL_SHA256`).

## Version overrides

Defaults are `latest`. Any variable defined in docker-bake.hcl can be overridden via environment variables when invoking the build.

Additional optional build args:
- `CIU_LATEST_TAG`, `CIU_LATEST_ASSET_NAME`: derive the canonical GitHub Releases URL
	- Latest URL scheme: https://github.com/volkb79-2/vbpub/releases/download/ciu-wheel-latest/ciu-<version>-py3-none-any.whl

Example:

```
B2_VERSION=4.5.0 ./build-images.sh
```

Checksum verification is enabled for HashiCorp binaries, AWS CLI, and B2 CLI downloads during build.

Debian backports are enabled for each Debian release with Pin-Priority 600.

## Manifest

Each image writes a manifest to:

```
/home/vscode/devcontainer-manifest.txt
```

It includes tool versions, Python version, pip package list, and selected Debian package versions.

## Package metadata (GitHub Packages)

The container image publishes OCI labels so the GitHub Packages page shows a useful description and links:

- `org.opencontainers.image.description`
- `org.opencontainers.image.source`
- `org.opencontainers.image.documentation`

This makes the package page readable before download and points to the manifest location inside the image.

## Build

This project uses Buildx Bake. The build date is included in tags via `BUILD_DATE`.

- `docker-bake.hcl` defines 4 targets and an `all` group.
- `./build-images.sh` sets `BUILD_DATE` and builds all variants.

### Shared credentials

`build-images.sh` and `push-images.sh` will load a shared repo-root env file if present:
- vbpub/.env (preferred)
- vsc-devcontainer/.env (fallback)

This lets you store GitHub credentials once for multiple vbpub projects.

## Push to GitHub Artifact Registry

Use `./push-images.sh` (or run Bake with `--push`) after validation. Configure registry owner via environment variables in the script or your shell.

`push-images.sh` also updates the `latest` tag (and per-variant `*-latest` tags) to point at the most recently pushed images.

### GHCR (personal account)

Note: GitHub Packages only supports authentication using a personal access token (classic). See:
https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry


1. Copy `.env.sample` to `.env` and fill in:
	- `GITHUB_USERNAME`
	- `GITHUB_REPO`
	- `GITHUB_PUSH_PAT`
2. Create a GitHub Personal Access Token with:
	- `write:packages` (required for push)
	- `read:packages` (required for pull)
3. Run `./push-images.sh` (the script will login if `GITHUB_PUSH_PAT` is set).

## Usage in other repositories

Reference one of the tags in your `.devcontainer/devcontainer.json` under `image` (do not use `build`).

Example:

```
{
	"image": "ghcr.io/acme/vsc-devcontainer:bookworm-py3.13-20260117",
	"remoteUser": "vscode"
}
```

Counterexample (do NOT do this):

```
{
	"build": {
		"dockerfile": "Dockerfile"
	}
}
```
