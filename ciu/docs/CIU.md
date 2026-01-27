# CIU Engine (ciu)

CIU is the single-stack renderer and runner. It renders TOML templates, resolves directives, executes hooks, renders docker-compose.yml, and starts one stack.

This document is aligned to the current implementation and is sufficient for a clean-room reimplementation.

## Quick Start (User-Facing)

- Render and start a stack:
   - ciu -d infra/db-core
- Render TOML only:
   - ciu -d infra/db-core --render-toml
- Dry run (render only):
   - ciu -d infra/db-core --dry-run
- Print merged config:
   - ciu -d infra/db-core --print-context

## Command-Line Arguments (Authoritative)

### Core options

- -d, --dir PATH
   - Working directory containing service files (default: current directory)
- -f, --file NAME
   - Compose template name (default: docker-compose.yml.j2)
- -y, --yes
   - Non-interactive mode (auto-confirm prompts)

### Render/diagnostics

- --dry-run
   - Skip docker compose execution
- --print-context
   - Print merged configuration as JSON
- --render-toml
   - Render ciu.toml from templates (resets state)

### Workspace env

- --generate-env
   - Generate .env.ciu with autodetected values
- --update-cert-permission
   - Update Let’s Encrypt cert permissions (requires root)

## CIU Global Options

The following options live under `[ciu]` in `ciu-global.defaults.toml.j2`:

- `require_certs` (default: false)
   - When true, CIU validates that the Let’s Encrypt cert/key files from `.env.ciu`
      exist and are readable by `DOCKER_GID` before compose starts.
- `require_fqdn` (default: false)
   - When true, CIU requires `PUBLIC_FQDN` to be present. When false, CIU allows
      `PUBLIC_FQDN` to fall back to the public IP or `localhost` during `.env.ciu` generation.

Optional metadata:
- `standalone_root`
   - Set to true to mark a repository as a standalone CIU project. CIU enforces
      that `REPO_ROOT` matches the directory containing the flag and will fail
      if CIU is executed from a nested path with a mismatched `.env.ciu`.

### Root selection

- --define-root PATH
   - Override repository root directory (no parent walking)
- --root-folder PATH
   - Alias for --define-root

### Skips/cleanup

- --skip-hostdir-check
   - Skip hostdir creation/validation (cleanup mode)
- --skip-hooks
   - Skip pre/post compose hooks
- --skip-secrets
   - Skip secret resolution/validation
- --reset
   - Clean service to fresh state (remove containers, volumes, configs)

## Inputs

- ciu-global.defaults.toml.j2
- ciu-global.toml.j2
- <stack>/ciu.defaults.toml.j2
- <stack>/ciu.toml.j2 (optional; override template)
- <stack>/docker-compose.yml.j2
- Optional hook modules (pre/post compose)

## Outputs

- ciu-global.toml (rendered, repo root)
- <stack>/ciu.toml (rendered)
- <stack>/docker-compose.yml (rendered)

## Execution Pipeline (Authoritative)

The pipeline below matches CIU engine behavior:

```mermaid
flowchart TD
   A["Start (stack dir)"] --> B["Load .env.ciu"]
    B --> C["Render global templates" ]
    C --> D["Render stack templates" ]
    D --> E["Deep merge global + stack" ]
    E --> F["Optional: reset service" ]
    F --> G["Auto-generate build metadata + UID/GID" ]
    G --> H["Create hostdir directories" ]
    H --> I["Determine stack root key" ]
    I --> J["Pre-compose hooks" ]
    J --> K["Resolve secrets + registry auth" ]
    K --> L["Render docker-compose.yml" ]
    L --> M["Build compose env (flatten)" ]
    M --> N["docker compose up -d" ]
    N --> O["Post-compose hooks" ]
    O --> P["END" ]
```

### Step Details

1. **Load workspace env**
   - Reads .env.ciu and validates required keys via ensure_workspace_env.

2. **Render global config**
   - Ensures ciu-global.toml.j2 exists by copying defaults if missing.
   - Jinja2 render → expand env vars ($VAR/${VAR}) → parse TOML.
   - Deep merge defaults + overrides → write ciu-global.toml.

3. **Render stack config**
   - Same render/expand/parse flow for <stack>/ciu.defaults.toml.j2 and <stack>/ciu.toml.j2.
   - Deep merge defaults + overrides → write <stack>/ciu.toml.

4. **Deep merge**
   - Merge global config with stack config; stack wins on conflicts.

5. **Optional reset**
   - If --reset, run stack cleanup (compose down -v, remove vol-* dirs, remove rendered files, orphaned containers).

6. **Auto-generate values**
   - Build version/time from git.
   - UID/GID from deploy.env.shared (CONTAINER_UID, DOCKER_GID).

7. **Hostdir creation**
   - Scans for hostdir sections, generates missing paths (./vol-<service>-<purpose>), creates directories with UID/GID.

8. **Determine stack root key**
   - CIU expects exactly one stack root key (excluding state). This key contains hooks.

9. **Pre-compose hooks**
   - Load and run hooks listed under <stack_key>.hooks.pre_compose.
   - Hook return values can update env and/or persist to ciu.toml.

10. **Secret resolution and registry auth**
    - Resolve directives (Vault/local/external).
    - Validate docker login if deploy.registry.url is set.

11. **Render docker-compose.yml**
    - Jinja2 render from merged config into docker-compose.yml.

12. **Compose env and docker compose up**
    - Flatten merged config into env vars.
    - Run docker compose up -d with injected env.

13. **Post-compose hooks**
    - Run hooks listed under <stack_key>.hooks.post_compose.

## Hook System (Authoritative)

CIU loads hook modules using this precedence:

1. Function hooks:
   - pre_compose_hook(config, env) -> dict
   - post_compose_hook(config, env) -> dict
   - run(config, env) -> dict
2. Class hooks:
   - PreComposeHook / PostComposeHook with run(...)

For class hooks, CIU:
- Instantiates class (env injected if __init__ accepts env)
- Sets hook_instance.config = config
- Calls run(config, env) if accepted, otherwise run(env)

### Hook return formats

Simple env updates:
```
{"VAR": "value"}
```

Metadata updates:
```
{"path.to.key": {"value": "x", "persist": "toml", "apply_to_config": true}}
```

Rules:
- persist=toml writes to the rendered <stack>/ciu.toml
- apply_to_config updates the in-memory merged config

### Hook Flow (Sequence)

```mermaid
sequenceDiagram
    participant CIU as CIU
    participant Hook as Hook module
    participant TOML as stack ciu.toml
    CIU->>Hook: load + execute
    Hook-->>CIU: return updates
    CIU->>CIU: update env + config
    alt persist=toml
        CIU->>TOML: write updates
    end
```

## Compose Environment Flattening

CIU flattens the merged config into env vars:

- Nested keys become UPPER_SNAKE (join with underscores)
- Lists become comma-separated
- [env] keys become ENV_<KEY>
- PWD is injected

Example:
```
db_core.secrets.postgres_superuser_password
→ DB_CORE_SECRETS_POSTGRES_SUPERUSER_PASSWORD

[env]
REDIS_PASSWORD=...
→ ENV_REDIS_PASSWORD
```

## Fail-Fast Behavior

- Missing required .env.ciu keys abort execution.
- Missing deploy.env.shared values required for hostdir creation abort execution.
- Missing stack root key (or multiple root keys) abort execution.
- Registry authentication failures abort execution when registry.url is set.

## Common Edge Cases

- Hyphenated TOML keys break Jinja2 access: use underscores.
- Avoid default() in templates for required values.
- Use ${PWD}/file or ${PHYSICAL_REPO_ROOT}/file for file mounts.
- Let’s Encrypt certs are symlinks; mount the parent directory.

## Developer Notes

- CIU is stack-scoped only; orchestration is handled by CIU Deploy.
- No _template expansion phase exists; use Jinja2 + env expansion in TOML templates.
