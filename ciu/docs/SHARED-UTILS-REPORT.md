# CIU Shared Utilities Report (2026-01-28)

## Summary

We centralized workspace-env bootstrap and rendering helpers to reduce duplication between `ciu` and `ciu-deploy`. This report documents the shared move-out work, remaining duplication, and specification gaps.

## Shared Functionality Moved

### Workspace environment bootstrap

**New shared helper:**
- `workspace_env.bootstrap_workspace_env()`
- `workspace_env.resolve_env_root()`

**Moved out from:**
- `engine.main_execution()`
- `deploy.main()`

**Behavior (centralized):**
- Resolve repo root
- Auto-generate `.env.ciu` if missing
- `--generate-env` forces regeneration
- Load `.env.ciu` and validate required keys
- Optional cert permission update

### Rendering helpers

**New shared helper module:**
- `render_utils.py`

**Shared functions:**
- `find_stack_anchor()`
- `load_global_config()`
- `render_global_config_if_missing()`
- `render_global_config()`
- `render_stack_configs()`
- `build_global_config_debug_lines()`

**Moved out from:**
- `deploy.py` (previously had local rendering/anchor logic and inline debug summaries)

## Remaining Shared Candidates

1. **Global config debug dump** (deploy-only)
   - Current: debug summary is implemented inline in deploy.
   - Suggestion: move to `render_utils` or a new `config_utils` module for reuse.

2. **Deployment phase evaluation** (deploy-only)
   - `load_deployment_phases()` contains repeated evaluation logic that could be reused by tests or other tooling.

3. **Config validation utilities**
   - Fail-fast checks are spread across `engine.py` and `deploy.py`.
   - Consider a `validation_utils.py` to unify required-key checks and error format.

## Specification Review (Gaps)

### CIU spec gaps

1. **Stack root key requirement**
   - CIU requires exactly one top-level key (excluding `state`).
   - The spec documents it, but does not explicitly show how to nest `env` and `hooks` under the stack root.
   - **Action:** add a concrete example in `docs/CIU.md` that shows `[stack.env]` and `[stack.hooks]` nested under the root key.

2. **Workspace env auto-generation**
   - Specification now mentions auto-generation, but it lacks a clear precedence/override table.
   - **Action:** add a small table for: missing `.env.ciu` → auto-generate, `--generate-env` → force regenerate, `--define-root` → override location.

3. **Standalone root behavior**
   - `standalone_root = true` behavior is documented but lacks examples for `.env.ciu` location and invocation.
   - **Action:** add a minimal standalone example in `docs/CONFIG.md`.

### CIU Deploy spec gaps

1. **Rendered config dependency**
   - `ciu-deploy` ensures `ciu-global.toml` exists, but the spec does not state the exact ordering: env → render → load.
   - **Action:** add explicit ordering in `docs/CIU-DEPLOY.md` steps.

2. **Render vs “missing only” behavior**
   - `--render-toml` now always forces render (not “missing only”).
   - **Action:** add a single sentence to clarify forced rendering.

## Test Repo Fixture (New)

A synthetic repository is now available at `ciu/test-repo` to support contract tests:

- **Infra**: vault + consul (with demo hooks)
- **Apps**: app-simple (no vault), app-vault (hooked)
- **Standalone**: nested standalone root

This repo enables tests for:
- `.env.ciu` auto-generation
- TOML rendering (global + stack)
- Hook persistence into `ciu.toml`

## Next Steps (Optional)

- Centralize deploy debug output into a shared helper.
- Add spec examples for stack root nesting and standalone usage.
- Extend tests to validate `ciu-deploy --render-toml` and standalone root errors.
