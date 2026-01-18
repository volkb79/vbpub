# Devcontainer Image Usage

## Build (local)

Build all four variants:

- `./build-images.sh`

Environment configuration:
- Copy `.env.sample` to `.env` and adjust values as needed.

Optional overrides (environment variables):
- `REGISTRY`, `NAMESPACE`, `IMAGE_NAME`, `BUILD_DATE`, `BACKPORTS_URI`

Any variable in docker-bake.hcl can be overridden for a build.

Example:

```
B2_VERSION=4.5.0 ./build-images.sh
```

## Push (registry)

After validation, push all variants:

- `./push-images.sh`

Ensure you are logged in to the registry (e.g., `docker login ghcr.io`) and that `NAMESPACE` matches your org/user.
If `GITHUB_GHCR_IO_PAT` and `GITHUB_GHCR_IO_USERNAME` are set in `.env`, the push script will log in automatically.

## Use in devcontainer.json

Reference the desired tag under `image` (no `build` section):

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

## Manifest

Each image writes a manifest file at:

```
/home/vscode/devcontainer-manifest.txt
```

This includes tool versions, pip package list, and selected Debian package versions.
