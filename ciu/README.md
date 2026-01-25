# CIU

CIU is the packaged deployment engine for DST-DNS. It provides two console
entrypoints:

- `ciu` (engine for rendering and running a single stack)
- `ciu-deploy` (orchestrator for multi-stack deployments)

## Usage

```bash
ciu --help
ciu-deploy --help
```

## Requirements

- Python 3.11+
- Target repository includes CIU TOML templates (e.g. `ciu-global.defaults.toml.j2`)

## Installation (local dev)

```bash
pip install -e .
```


