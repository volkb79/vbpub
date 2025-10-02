AGENTS_DOC_VERSION: 2025-10-01

# AGENTS.md — Developer & Agent Guide

Purpose: Extended developer and agent guidance (VS Code, venv, dependency management, CI, troubleshooting).

This document contains the expanded guidance referenced from `.github/copilot-instructions.md`.

## Virtualenv / Editor (detailed)

- Always create and define a project virtual environment (venv) and configure VS Code to use it for the workspace. This ensures the language server (Pylance/Pyright) resolves imports and that developers run code in a reproducible environment.
- Minimum venv expectations:
  - venv located in the project root (convention: `.venv` or `venv`).
  - Include a `requirements.txt` (or Poetry `pyproject.toml`) that lists required runtime and editor helper packages.
  - At minimum install packages required by the editor/language server for this project (example below).

### Minimum packages
- PyYAML==6.0  # required for compose-init scripts and Pylance to resolve `import yaml`
- Add other runtime or dev dependencies to `requirements.txt` (or manage them in Poetry / pyproject.toml).

### Quick recommended setup
```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip setuptools
pip install -r requirements.txt
```

### VS Code workspace guidance
- Select the venv interpreter (Command Palette → Python: Select Interpreter → choose `.venv/bin/python`).
- Optionally add `.vscode/settings.json` in each project folder to pin interpreter paths:
```json
{
  "python.defaultInterpreterPath": "${workspaceFolder}/.venv/bin/python"
}
```

## Multi-project workspace guidance

- For repositories that contain multiple projects (for example `projects/controller`, `projects/common-config`, `vbpub`, `vbpro`), ensure each project folder defines its preferred interpreter so VS Code and Pylance resolve imports correctly.
- Patterns:
  - Add a `.vscode/settings.json` into each project folder containing the interpreter path for that project (see example above).
  - Or create workspace-level settings in the multi-root workspace file that map interpreter paths per folder.
  - When opening a multi-root workspace via Remote‑SSH, verify the interpreter for each folder (Command Palette → Python: Select Interpreter) and reload the window if needed.

## PyYAML / system packages vs venv

- Debian apt package `python3-yaml` provides PyYAML at system level (safe and managed by apt). Virtual environments are isolated by default — they will not see system packages unless created with `--system-site-packages`.
- Recommended: install PyYAML into the project venv (or manage via Poetry) and pin it in `requirements.txt` so editor/CI resolve imports consistently.

## Poetry vs requirements.txt

- If you plan to adopt Poetry, use `pyproject.toml` as source of truth. For CI or tools that expect `requirements.txt`, export it from Poetry:
  - `poetry export -f requirements.txt --output requirements.txt --without-hashes`
- Until Poetry is fully adopted, a minimal `requirements.txt` with editor helper packages (e.g., PyYAML) is helpful.

## Editor / CI checks (suggested)
- Add a lightweight CI job to install `requirements.txt` and run a static check (pyright/pylint/flake8) to catch missing deps early.

## Troubleshooting
- If the language server reports `Import 'yaml' could not be resolved`, ensure VS Code uses the same interpreter where PyYAML is installed. Check `python.defaultInterpreterPath` and run `python -c "import yaml; print(yaml.__file__)"` in that interpreter.

## Cross-linking and versions
- This file is the long-form developer guide referenced by `.github/copilot-instructions.md` (machine-checkable: `AGENTS_DOC_VERSION`).

## Migration note: strict-flag refactor policy

- When updating behavior related to strict checks (for example, replacing legacy
- COMPINIT_<NAME>_STRICT variables with the canonical COMPINIT_STRICT_<NAME> names),
- do NOT implement runtime fallbacks that check for both old and new names. Instead,
- perform a complete repository-wide refactor that updates code, tests, docs, and
- CI configuration to reference only the new COMPINIT_STRICT_<NAME> variables.

- Minimal checklist for such refactors:
  - Update all code to read only COMPINIT_STRICT_<NAME> values.
  - Update `.env.sample`, READMEs, and any developer docs to remove legacy names.
  - Add unit/integration tests that assert the new behavior and prevent regressions.
  - Add CI or lint checks where feasible to detect leftover legacy references.

This ensures consistent behavior across agents and human contributors and prevents
accidental reintroduction of deprecated compatibility shims.
